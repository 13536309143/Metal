// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetalViewer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MetalViewer",
            path: "Sources/MetalViewer"
        )
    ]
)
