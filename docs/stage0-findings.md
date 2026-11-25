# Stage 0 findings (M2, macOS 27.2, synthetic frames)

Benchmark: `Experiments/VTBench` (`swift build -c release && .build/release/VTBench`)

| Item | Result |
|---|---|
| VTLowLatencySuperResolutionScaler | supported; input 96..1280 px; 720p supports **only x1.5** (→1080p) |
| SR 1280x720 → 1920x1080 | p50 2.9 ms, p95 5.2 ms |
| VTLowLatencyFrameInterpolation 720p | p50 4.0 ms |
| VTLowLatencyFrameInterpolation 1080p | p50 14.2 ms (first session start ~1 s) |
| Recommended order | interpolate at 720p, then upscale (≈4 + 2×2.9 ≈ 10 ms GPU per source frame) |
| Unmeasured | ScreenCaptureKit capture latency, display path, GPU contention with WebKit decode, visual quality |

Keyboard → gamepad: `Experiments/KeyPad/gamepad-shim.js` (virtual standard Gamepad injected via WKUserScript).
Verified in WKWebView with synthetic key/mouse events; not yet verified against the real Xbox web client.
