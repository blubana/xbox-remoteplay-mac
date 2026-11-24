// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XboxRemote",
    platforms: [.macOS("12.3")],
    targets: [
        .executableTarget(name: "XboxRemote", path: "Sources/XboxRemote")
    ]
)
