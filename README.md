# XboxRemote

<img src="Resources/icon-1024.png" width="128" align="right">

A tiny (~100 KB) native macOS wrapper around the web version of
[Xbox Remote Play](https://play.xbox.com/remoteplay), built with Swift and `WKWebView`.
No Chromium, no browser chrome — just a window that streams from your console.

## Features
- Native window (16:9, remembers size), full-screen support
- Persistent login (cookies kept between launches)
- Presents itself as Safari so the site accepts it
- Microphone permission auto-granted for voice chat
- Prevents display sleep while the app is running
- Menu: reload (⌘R), home (⇧⌘H), full screen (⌃⌘F), clear login data

## Video enhancement (experimental, macOS 26+)
Captures the app window with ScreenCaptureKit, optionally interpolates 30→60 fps at 720p
(`VTLowLatencyFrameInterpolation`), upscales 720p→1080p (`VTLowLatencySuperResolutionScaler`),
and shows the result in a click-through overlay window. Menu **畫質增強**: ⌘0 off, ⌘1 upscale, ⌘2 upscale + interpolate, ⌘I stats.
Needs the *Screen Recording* permission. Benchmarks: `docs/stage0-findings.md`.

## Keyboard as gamepad
A virtual standard gamepad is injected into the page (`Resources/gamepad-shim.js`): WASD = left stick,
IJKL / mouse (pointer lock) = right stick, Space/C/E/Q = A/B/X/Y, Z/X = LB/RB, Shift/F = LT/RT,
arrows = D-pad, Tab/Enter = Back/Start, F8 toggles. Real controllers keep working alongside it.

## Build & install
Requires macOS 12.3+ and the Swift toolchain (Xcode Command Line Tools is enough).

```bash
./build.sh            # produces build/XboxRemote.app
./build.sh install    # also copies it to /Applications
```

## Known limitations
- **Passkeys (Touch ID / iCloud Keychain) are not available.** WebKit only exposes the
  platform authenticator to `WKWebView` apps holding Apple's restricted
  `com.apple.developer.web-browser.public-key-credential` entitlement, which must be
  granted by Apple. Sign in with password + authenticator app instead.
- Ad-hoc signed; not notarized.

## Hacking
Everything lives in `Sources/XboxRemote/main.swift`. Inject JS with `WKUserScript`,
talk back to Swift with `WKScriptMessageHandler`.

## Disclaimer
Unofficial project, not affiliated with or endorsed by Microsoft. "Xbox" is a
trademark of Microsoft. You need your own console and Microsoft account.

## License
MIT
