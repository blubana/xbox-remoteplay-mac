import Cocoa
import WebKit
import IOKit.pwr_mgt
import GameController

let startURL = URL(string: "https://play.xbox.com/remoteplay")!

final class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var sleepAssertion: IOPMAssertionID = 0
    var enhancerBox: AnyObject?   // Enhancer(macOS 26+)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()                      // 保留登入狀態
        config.mediaTypesRequiringUserActionForPlayback = []      // 允許自動播放影音
        config.preferences.isElementFullscreenEnabled = true      // 網頁內全螢幕
        // 讓網站把它視為 Safari(預設 WKWebView 的 UA 沒有 Safari 標記)
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

        if let url = Bundle.main.url(forResource: "gamepad-shim", withExtension: "js"),
           let js = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Xbox Remote Play"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = webView
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.setFrameAutosaveName("MainWindow")
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        webView.load(URLRequest(url: startURL))
        preventSleep()
        if let m = ProcessInfo.processInfo.environment["XR_AUTOENHANCE"], let n = Int(m), let mode = EnhanceMode(rawValue: n) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.setEnhance(mode) }
            if let q = ProcessInfo.processInfo.environment["XR_QUIT_AFTER"], let secs = Double(q) {
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: 畫質增強
    @objc func enhanceOff() { setEnhance(.off) }
    @objc func enhanceUp() { setEnhance(.upscale) }
    @objc func enhanceUpFI() { setEnhance(.upscaleAndInterpolate) }
    @objc func toggleStats() {
        if #available(macOS 26.0, *), let e = enhancerBox as? Enhancer { e.showStats.toggle() }
    }
    func setEnhance(_ mode: EnhanceMode) {
        guard #available(macOS 26.0, *) else {
            let a = NSAlert(); a.messageText = "畫質增強需要 macOS 26 或更新版本"; a.runModal(); return
        }
        if enhancerBox == nil { enhancerBox = Enhancer(window: window) }
        let e = enhancerBox as! Enhancer
        Task { await e.setMode(mode) }
    }

    // MARK: 手把
    @objc func togglePad() { webView.evaluateJavaScript("window.__vpad && (window.__vpad.on = !window.__vpad.on)") }
    @objc func toggleLook() {
        webView.evaluateJavaScript("window.__vpad && (window.__vpad.look = !window.__vpad.look)")
    }
    @objc func showControllers() {
        let list = GCController.controllers()
        let a = NSAlert()
        a.messageText = list.isEmpty ? "沒有偵測到實體手把" : "已連接 \(list.count) 支手把"
        a.informativeText = (list.map { "• \($0.vendorName ?? "Unknown") (\($0.productCategory))" }.joined(separator: "\n"))
            + "\n\n鍵盤模擬:WASD 左搖桿、IJKL/滑鼠右搖桿、空白=A、C=B、E=X、Q=Y、Z/X=LB/RB、Shift/F=LT/RT、方向鍵=十字鍵、Tab=Back、Enter=Start、F8 開關"
        a.runModal()
    }

    // 串流時避免螢幕/系統休眠
    func preventSleep() {
        IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Xbox Remote Play streaming" as CFString,
                                    &sleepAssertion)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // 登入流程會開 popup,直接在同一個 view 載入
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // 麥克風(語音聊天)權限
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    // MARK: Menu
    func setupMenu() {
        let main = NSMenu()
        NSApp.mainMenu = main

        func add(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(); main.addItem(item)
            let m = NSMenu(title: title); item.submenu = m
            items.forEach { m.addItem($0) }
        }
        func mi(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }

        add("App", [
            mi("關於 Xbox Remote Play", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            mi("隱藏", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            mi("結束", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let reload = mi("重新載入", #selector(reload), "r"); reload.target = self
        let home = mi("回到 Remote Play 首頁", #selector(goHome), "h", [.command, .shift]); home.target = self
        let clear = mi("清除登入資料…", #selector(clearData)); clear.target = self
        add("頁面", [reload, home, .separator(), clear])
        let o0 = mi("關閉", #selector(enhanceOff), "0"); o0.target = self
        let o1 = mi("放大 720p→1080p", #selector(enhanceUp), "1"); o1.target = self
        let o2 = mi("放大 + 補幀 (×2)", #selector(enhanceUpFI), "2"); o2.target = self
        let o3 = mi("顯示統計", #selector(toggleStats), "i"); o3.target = self
        add("畫質增強", [o0, o1, o2, .separator(), o3])
        let g1 = mi("開關鍵盤模擬手把 (F8)", #selector(togglePad)); g1.target = self
        let g2 = mi("切換滑鼠視角(點一下畫面鎖定)", #selector(toggleLook)); g2.target = self
        let g3 = mi("手把狀態與鍵位…", #selector(showControllers)); g3.target = self
        add("手把", [g1, g2, g3])
        add("檢視", [mi("切換全螢幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        add("視窗", [
            mi("縮到最小", #selector(NSWindow.performMiniaturize(_:)), "m"),
            mi("關閉", #selector(NSWindow.performClose(_:)), "w"),
        ])
    }

    @objc func reload() { webView.reload() }
    @objc func goHome() { webView.load(URLRequest(url: startURL)) }
    @objc func clearData() {
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                modifiedSince: .distantPast) { self.goHome() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
