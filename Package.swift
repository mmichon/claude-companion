// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeCompanion",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CompanionShared", targets: ["CompanionShared"]),
        .executable(name: "claude-companiond", targets: ["claude-companiond"]),
    ],
    targets: [
        .target(name: "CompanionShared"),
        .executableTarget(name: "claude-companiond", dependencies: ["CompanionShared"]),
    ]
)
