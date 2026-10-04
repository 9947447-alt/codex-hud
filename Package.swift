// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexHUD",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexHUDCore", targets: ["CodexHUDCore"]),
        .executable(name: "CodexHUD", targets: ["CodexHUD"]),
    ],
    targets: [
        .target(
            name: "CodexHUDCore",
            resources: [
                .copy("Resources/o200k_base.tiktoken"),
                .copy("Resources/o200k_base.LICENSE"),
            ]
        ),
        .executableTarget(name: "CodexHUD", dependencies: ["CodexHUDCore"]),
        .testTarget(name: "CodexHUDTests", dependencies: ["CodexHUD"]),
        .testTarget(name: "CodexHUDCoreTests", dependencies: ["CodexHUDCore"]),
    ]
)
