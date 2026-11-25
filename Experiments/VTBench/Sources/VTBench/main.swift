// 階段 0 可行性實驗:不需要螢幕錄製權限,用合成畫面實測
// VideoToolbox 低延遲「超解析度」與「補幀」的單幀處理時間。
import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
setvbuf(stdout, nil, _IONBF, 0)

func ms(_ t: UInt64) -> Double { Double(t) / 1_000_000 }
func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func makeBuffer(_ attrs: [String: Any], _ w: Int, _ h: Int, frame: Int = -1) -> CVPixelBuffer {
    var a = attrs
    a[kCVPixelBufferWidthKey as String] = w
    a[kCVPixelBufferHeightKey as String] = h
    var pb: CVPixelBuffer?
    let fmt = (a[kCVPixelBufferPixelFormatTypeKey as String] as? [NSNumber])?.first?.uint32Value
        ?? (a[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
        ?? kCVPixelFormatType_32BGRA
    a[kCVPixelBufferPixelFormatTypeKey as String] = fmt
    let st = CVPixelBufferCreate(nil, w, h, fmt, a as CFDictionary, &pb)
    precondition(st == kCVReturnSuccess, "CVPixelBufferCreate failed \(st)")
    let buf = pb!
    if frame >= 0 {   // 填入會移動的圖樣,避免全黑被優化
        CVPixelBufferLockBaseAddress(buf, [])
        let planes = max(1, CVPixelBufferGetPlaneCount(buf))
        for p in 0..<planes {
            let base = planes == 1 ? CVPixelBufferGetBaseAddress(buf)! : CVPixelBufferGetBaseAddressOfPlane(buf, p)!
            let bpr = planes == 1 ? CVPixelBufferGetBytesPerRow(buf) : CVPixelBufferGetBytesPerRowOfPlane(buf, p)
            let rows = planes == 1 ? CVPixelBufferGetHeight(buf) : CVPixelBufferGetHeightOfPlane(buf, p)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for r in 0..<rows { for c in 0..<bpr { ptr[r*bpr+c] = UInt8(truncatingIfNeeded: (c/4 + frame*6) ^ (r/8)) } }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
    }
    return buf
}

func stats(_ name: String, _ xs: [Double]) {
    let s = xs.sorted()
    let avg = s.reduce(0,+)/Double(s.count)
    print(String(format: "  %-34@ avg %6.2f ms | p50 %6.2f | p95 %6.2f | max %6.2f  (n=%d)",
                 name as NSString, avg, s[s.count/2], s[Int(Double(s.count)*0.95)], s.last!, s.count))
}

func pts(_ i: Int) -> CMTime { CMTime(value: CMTimeValue(i), timescale: 30) }

// MARK: - 環境資訊
let inW = 1280, inH = 720
print("=== 環境 ===")
print("SR  supported:", VTLowLatencySuperResolutionScalerConfiguration.isSupported)
print("FI  supported:", VTLowLatencyFrameInterpolationConfiguration.isSupported)
let mx = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions
let mn = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions
print("SR  dims min \(mn?.width ?? 0)x\(mn?.height ?? 0)  max \(mx?.width ?? 0)x\(mx?.height ?? 0)")
print("SR  scale factors @720p:", VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: inW, frameHeight: inH))

let N = 200

// MARK: - 超解析度
func benchSR(scale: Float) async throws -> (CVPixelBuffer, [Double]) {
    guard let cfg = Optional(VTLowLatencySuperResolutionScalerConfiguration(frameWidth: inW, frameHeight: inH, scaleFactor: scale)) else { fatalError() }
    let outW = Int(Float(inW) * scale), outH = Int(Float(inH) * scale)
    let proc = VTFrameProcessor()
    let t0 = now()
    try proc.startSession(configuration: cfg)
    print(String(format: "SR x%.2f 啟動 session: %.1f ms", scale, ms(now()-t0)))
    var times: [Double] = []
    var last: CVPixelBuffer!
    for i in 0..<(N+5) {
        let src = makeBuffer(cfg.sourcePixelBufferAttributes, inW, inH, frame: i)
        let dst = makeBuffer(cfg.destinationPixelBufferAttributes, outW, outH)
        let sf = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: pts(i))!
        let df = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: pts(i))!
        let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sf, destinationFrame: df)
        let t = now()
        _ = try await proc.process(parameters: params)
        let d = ms(now()-t)
        if i == 0 { print(String(format: "  第一幀(含模型載入): %.1f ms", d)) }
        if i >= 5 { times.append(d) }
        last = dst
    }
    proc.endSession()
    return (last, times)
}

// MARK: - 補幀
func benchFI(w: Int, h: Int) async throws -> [Double] {
    guard let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: 1) else {
        print("FI \(w)x\(h) 不支援"); return []
    }
    let proc = VTFrameProcessor()
    let t0 = now()
    try proc.startSession(configuration: cfg)
    print("FI \(w)x\(h) 啟動 session: \(String(format: "%.1f", ms(now()-t0))) ms")
    var prev = VTFrameProcessorFrame(buffer: makeBuffer(cfg.sourcePixelBufferAttributes, w, h, frame: 0), presentationTimeStamp: pts(0))!
    var times: [Double] = []
    for i in 1..<(N+6) {
        let cur = VTFrameProcessorFrame(buffer: makeBuffer(cfg.sourcePixelBufferAttributes, w, h, frame: i), presentationTimeStamp: pts(i))!
        let dst = VTFrameProcessorFrame(buffer: makeBuffer(cfg.destinationPixelBufferAttributes, w, h), presentationTimeStamp: CMTimeAdd(pts(i-1), CMTime(value: 1, timescale: 60)))!
        let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: cur, previousFrame: prev, interpolationPhase: [0.5], destinationFrames: [dst])!
        let t = now()
        _ = try await proc.process(parameters: params)
        let d = ms(now()-t)
        if i == 1 { print(String(format: "  第一幀(含模型載入): %.1f ms", d)) }
        if i >= 6 { times.append(d) }
        prev = cur
    }
    proc.endSession()
    return times
}

print("\n=== 超解析度 720p → 1080p ===")
let (_, sr15) = try await benchSR(scale: 1.5)
stats("SR 1280x720 → 1920x1080 (x1.5)", sr15)
print("(x2 在 720p 不支援,已略過)")
print("\n=== 補幀 (30→60,每次插 1 幀) ===")
let fi720 = try await benchFI(w: 1280, h: 720)
if !fi720.isEmpty { stats("FI 1280x720", fi720) }
let fi1080 = try await benchFI(w: 1920, h: 1080)
if !fi1080.isEmpty { stats("FI 1920x1080", fi1080) }

print("\n=== 判讀 ===")
let budget30 = 1000.0/30
let sr = sr15.sorted()[sr15.count/2], fi = (fi1080.isEmpty ? 0 : fi1080.sorted()[fi1080.count/2])
print(String(format: "30fps 幀預算 %.1f ms;SR p50=%.2f ms, FI@1080p p50=%.2f ms, 合計=%.2f ms", budget30, sr, fi, sr+fi))
print("額外管線延遲 ≈ SR + 等待下一幀(33.3 ms,補幀必須) + FI 處理")
print(String(format: "  → 估計新增延遲約 %.0f ms(不含擷取與顯示)", sr + 33.3 + fi))
