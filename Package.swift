// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageTide",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ClaudeUsageTide", path: "Sources/ClaudeUsageTide")
    ]
)
