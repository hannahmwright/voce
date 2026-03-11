// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VoceKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "VoceKit",
            targets: ["VoceKit"]
        ),
        .library(
            name: "VoceKitTestSupport",
            targets: ["VoceKitTestSupport"]
        ),
        .executable(
            name: "VoceBenchmarkCLI",
            targets: ["VoceBenchmarkCLI"]
        ),
    ],
    targets: [
        .target(
            name: "VoceKit"
        ),
        .target(
            name: "VoceBenchmarkCore",
            dependencies: ["VoceKit"]
        ),
        .target(
            name: "VoceKitTestSupport",
            dependencies: ["VoceKit"]
        ),
        .executableTarget(
            name: "VoceBenchmarkCLI",
            dependencies: ["VoceBenchmarkCore"]
        ),
        .testTarget(
            name: "VoceKitTests",
            dependencies: ["VoceKit", "VoceKitTestSupport"]
        ),
        .testTarget(
            name: "VoceBenchmarkCoreTests",
            dependencies: ["VoceBenchmarkCore"]
        ),
    ]
)
