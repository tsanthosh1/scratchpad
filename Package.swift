// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScratchPad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ScratchPad",
            path: "Sources/ScratchPad"
        ),
    ]
)
