// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ANEForge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ANEForge",
            path: "Sources/ANEForge"
        )
    ]
)
