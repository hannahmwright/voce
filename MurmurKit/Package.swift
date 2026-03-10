// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MurmurKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "MurmurKit",
            targets: ["MurmurKit"]
        ),
        .library(
            name: "MurmurKitTestSupport",
            targets: ["MurmurKitTestSupport"]
        ),
        .executable(
            name: "MurmurBenchmarkCLI",
            targets: ["MurmurBenchmarkCLI"]
        ),
    ],
    targets: [
        .target(
            name: "MurmurKit"
        ),
        .target(
            name: "MurmurBenchmarkCore",
            dependencies: ["MurmurKit"]
        ),
        .target(
            name: "MurmurKitTestSupport",
            dependencies: ["MurmurKit"]
        ),
        .executableTarget(
            name: "MurmurBenchmarkCLI",
            dependencies: ["MurmurBenchmarkCore"]
        ),
        .testTarget(
            name: "MurmurKitTests",
            dependencies: ["MurmurKit", "MurmurKitTestSupport"]
        ),
        .testTarget(
            name: "MurmurBenchmarkCoreTests",
            dependencies: ["MurmurBenchmarkCore"]
        ),
    ]
)
