// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeQuotaBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ClaudeQuotaBar", path: "Sources/ClaudeQuotaBar")
    ]
)
