// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "VTBench",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "VTBench", path: "Sources/VTBench")]
)
