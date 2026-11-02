// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeCompanion",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CompanionShared", targets: ["CompanionShared"]),
        .executable(name: "claude-companiond", targets: ["claude-companiond"]),
        .executable(name: "claude-companion-keys", targets: ["claude-companion-keys"]),
    ],
    targets: [
        .target(name: "CompanionShared"),
        .executableTarget(name: "claude-companiond", dependencies: ["CompanionShared"]),
        // No dependencies on purpose: see its main.swift.
        .executableTarget(name: "claude-companion-keys"),
    ]
)
