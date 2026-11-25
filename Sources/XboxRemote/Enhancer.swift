import Cocoa
import AVFoundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreImage

enum EnhanceMode: Int { case off = 0, upscale = 1, upscaleAndInterpolate = 2 }

/// 疊在主視窗上方的透明子視窗,顯示處理後的畫面。滑鼠事件穿透,輸入仍由下方 WKWebView 處理。
final class OverlayWindow: NSWindow {
    let display = AVSampleBufferDisplayLayer()
    let hud = CATextLayer()

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        contentView = v
        display.videoGravity = .resizeAspect
        display.frame = v.bounds
        display.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer!.addSublayer(display)
        hud.fontSize = 12
        hud.foregroundColor = NSColor.green.cgColor
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        hud.frame = CGRect(x: 8, y: 8, width: 360, height: 20)
        hud.contentsScale = 2
        hud.isHidden = true
        v.layer!.addSublayer(hud)
    }

    func present(_ pb: CVPixelBuffer) {
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
        guard let fd else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb,
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
              CFArrayGetCount(att) > 0 else { return }
        let d = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        if display.status == .failed { display.flush() }
        display.enqueue(sb)
    }
}

struct CapturedFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let pts: Double
    let arrival: UInt64   // 單調時鐘 ns
}

@inline(__always) func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// 擷取主視窗 → (補幀 @720p) → 超解析度 720p→1080p → 疊加顯示。
@available(macOS 26.0, *)
final class Enhancer: NSObject, SCStreamOutput, SCStreamDelegate {
    static let inW = 1280, inH = 720

    private weak var window: NSWindow?
    let overlay = OverlayWindow()
    private(set) var mode: EnhanceMode = .off
    var showStats = false { didSet { overlay.hud.isHidden = !showStats } }

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "xr.capture", qos: .userInteractive)
    private var continuation: AsyncStream<CapturedFrame>.Continuation?
    private var worker: Task<Void, Never>?
    private var resizeObs: NSObjectProtocol?

    private var srProc: VTFrameProcessor?, fiProc: VTFrameProcessor?
    private var srCfg: VTLowLatencySuperResolutionScalerConfiguration?
    private var fiCfg: VTLowLatencyFrameInterpolationConfiguration?
    private var srPool: CVPixelBufferPool?, fiPool: CVPixelBufferPool?

    // 統計
    private var capCount = 0, shownCount = 0, interpCount = 0
    private var procMsSum = 0.0, procN = 0
    private var statsTimer: Timer?
    private let dump = ProcessInfo.processInfo.environment["XR_DUMP"]
    private var dumped = 0

    init(window: NSWindow) {
        self.window = window
        super.init()
    }

    // MARK: 開關
    func setMode(_ m: EnhanceMode) async {
        if m == mode { return }
        if m == .off { await stop(); return }
        if mode == .off {
            guard await start() else { return }
        }
        mode = m
        log("mode = \(m)")
    }

    private func start() async -> Bool {
        guard let window else { return false }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            await MainActor.run {
                let a = NSAlert()
                a.messageText = "需要「螢幕錄製」權限"
                a.informativeText = "請到「系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製」勾選 XboxRemote,然後重新開啟 App。\n(用來擷取串流畫面做放大與補幀;影像只在本機處理,不會離開這台電腦。)"
                a.runModal()
            }
            return false
        }
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported,
              VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            await alert("這台 Mac 不支援 VideoToolbox 低延遲放大/補幀"); return false
        }
        do {
            // 1) 處理器
            let sc = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: Self.inW, frameHeight: Self.inH, scaleFactor: 1.5)
            guard let fc = VTLowLatencyFrameInterpolationConfiguration(frameWidth: Self.inW, frameHeight: Self.inH, numberOfInterpolatedFrames: 1) else {
                throw NSError(domain: "xr", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法建立補幀設定"])
            }
            let sp = VTFrameProcessor(), fp = VTFrameProcessor()
            try sp.startSession(configuration: sc)
            try fp.startSession(configuration: fc)
            srCfg = sc; fiCfg = fc; srProc = sp; fiProc = fp
            CVPixelBufferPoolCreate(nil, nil, sc.destinationPixelBufferAttributes as CFDictionary, &srPool)
            CVPixelBufferPoolCreate(nil, nil, fc.destinationPixelBufferAttributes as CFDictionary, &fiPool)

            // 2) 擷取主視窗
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scw = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw NSError(domain: "xr", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到要擷取的視窗"])
            }
            let filter = SCContentFilter(desktopIndependentWindow: scw)
            let cfg = SCStreamConfiguration()
            cfg.width = Self.inW; cfg.height = Self.inH
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.queueDepth = 5
            cfg.showsCursor = false
            cfg.scalesToFit = true
            cfg.ignoreShadowsSingleWindow = true
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

            // 3) 處理迴圈(只保留最新一幀,慢了就丟舊的,避免延遲堆積)
            var cont: AsyncStream<CapturedFrame>.Continuation!
            let frames = AsyncStream<CapturedFrame>(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
            continuation = cont
            worker = Task { [weak self] in await self?.run(frames) }

            // 4) 疊加視窗
            await MainActor.run {
                overlay.setFrame(window.frame, display: true)
                window.addChildWindow(overlay, ordered: .above)
                overlay.orderFront(nil)
                resizeObs = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    guard let self, let w = self.window else { return }
                    self.overlay.setFrame(w.frame, display: true)
                }
                statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickStats() }
            }
            try await s.startCapture()
            stream = s
            return true
        } catch {
            await alert("啟動畫質增強失敗:\(error.localizedDescription)")
            await stop()
            return false
        }
    }

    func stop() async {
        mode = .off
        let s = stream; stream = nil
        try? await s?.stopCapture()
        continuation?.finish(); continuation = nil
        worker?.cancel(); worker = nil
        srProc?.endSession(); fiProc?.endSession(); srProc = nil; fiProc = nil
        await MainActor.run {
            statsTimer?.invalidate(); statsTimer = nil
            if let o = resizeObs { NotificationCenter.default.removeObserver(o); resizeObs = nil }
            window?.removeChildWindow(overlay)
            overlay.orderOut(nil)
            overlay.display.flushAndRemoveImage()
        }
        log("stopped")
    }

    // MARK: SCStream
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let st = arr.first?[.status] as? Int, st == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        capCount += 1
        continuation?.yield(CapturedFrame(buffer: pb, pts: CMSampleBufferGetPresentationTimeStamp(sb).seconds, arrival: nowNs()))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream error: \(error)")
        Task { await self.stop() }
    }

    // MARK: 處理管線
    private var prev: VTFrameProcessorFrame?
    private var lastPTS = 0.0

    private func run(_ frames: AsyncStream<CapturedFrame>) async {
        for await f in frames {
            if Task.isCancelled { break }
            let t0 = nowNs()
            guard let cur = VTFrameProcessorFrame(buffer: f.buffer, presentationTimeStamp: CMTime(seconds: f.pts, preferredTimescale: 600)) else { continue }
            let dt = f.pts - lastPTS
            let doFI = mode == .upscaleAndInterpolate && prev != nil && dt > 0.022 && dt < 0.12
            do {
                if doFI, let p = prev {
                    let mid = try await interpolate(p, cur, at: f.pts - dt / 2)
                    let midHD = try await upscale(mid)
                    show(midHD); interpCount += 1
                    let curHD = try await upscale(cur)
                    let target = f.arrival + UInt64(min(dt / 2, 0.05) * 1e9)
                    let wait = target > nowNs() ? Double(target - nowNs()) / 1e9 : 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.show(curHD) }
                } else {
                    show(try await upscale(cur))
                }
            } catch {
                log("process error: \(error)")
                show(f.buffer)   // 失敗時退回原始畫面
            }
            prev = cur; lastPTS = f.pts
            let ms = Double(nowNs() - t0) / 1e6
            DispatchQueue.main.async { self.procMsSum += ms; self.procN += 1 }
            if let dump, dumped == 0, capCount > 90 { dumped = 1; saveDebug(f.buffer, to: dump + "-captured.png") }
        }
    }

    private func upscale(_ src: VTFrameProcessorFrame) async throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, srPool!, &out)
        guard let out else { throw NSError(domain: "xr", code: 3, userInfo: [NSLocalizedDescriptionKey: "pool exhausted"]) }
        let df = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: src.presentationTimeStamp)!
        _ = try await srProc!.process(parameters: VTLowLatencySuperResolutionScalerParameters(sourceFrame: src, destinationFrame: df))
        tag709(out)
        return out
    }

    private func interpolate(_ prev: VTFrameProcessorFrame, _ cur: VTFrameProcessorFrame, at t: Double) async throws -> VTFrameProcessorFrame {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, fiPool!, &out)
        guard let out else { throw NSError(domain: "xr", code: 4, userInfo: [NSLocalizedDescriptionKey: "pool exhausted"]) }
        let df = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 600))!
        _ = try await fiProc!.process(parameters: VTLowLatencyFrameInterpolationParameters(sourceFrame: cur, previousFrame: prev, interpolationPhase: [0.5], destinationFrames: [df])!)
        tag709(out)
        return df
    }

    private func show(_ pb: CVPixelBuffer) {
        DispatchQueue.main.async { [weak self] in
            self?.shownCount += 1
            self?.overlay.present(pb)
        }
        if let dump, dumped == 1 { dumped = 2; saveDebug(pb, to: dump + "-output.png") }
    }

    private func tag709(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }

    // MARK: 統計 / 除錯
    private func tickStats() {
        let avg = procN > 0 ? procMsSum / Double(procN) : 0
        let line = String(format: "擷取 %d fps · 顯示 %d fps · 補幀 %d/s · 處理 %.1f ms", capCount, shownCount, interpCount, avg)
        overlay.hud.string = line
        if ProcessInfo.processInfo.environment["XR_DEBUG"] != nil { log(line) }
        capCount = 0; shownCount = 0; interpCount = 0; procMsSum = 0; procN = 0
    }

    private func saveDebug(_ pb: CVPixelBuffer, to path: String) {
        let ci = CIImage(cvPixelBuffer: pb)
        let rep = NSBitmapImageRep(ciImage: ci)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        log("saved \(path)")
    }

    private func alert(_ msg: String) async {
        await MainActor.run { let a = NSAlert(); a.messageText = msg; a.runModal() }
    }
}

func log(_ s: String) { FileHandle.standardError.write(Data(("[XR] " + s + "\n").utf8)) }
