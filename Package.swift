// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeCompanion",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CompanionShared", targets: ["CompanionShared"]),
        .executable(name: "companiond", targets: ["companiond"]),
    ],
    targets: [
        .target(name: "CompanionShared"),
        .executableTarget(name: "companiond", dependencies: ["CompanionShared"]),
    ]
)
