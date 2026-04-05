// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeBar",
            path: "ClaudeBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
