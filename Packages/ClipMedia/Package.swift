// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClipMedia",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ClipMedia", targets: ["ClipMedia"]),
        .executable(
            name: "ClipMediaPerformanceBenchmark",
            targets: ["ClipMediaPerformanceBenchmark"]
        ),
    ],
    dependencies: [
        .package(path: "../ClipCapture"),
    ],
    targets: [
        .target(
            name: "ClipMedia",
            dependencies: [
                .product(name: "ClipCapture", package: "ClipCapture"),
            ]
        ),
        .executableTarget(
            name: "ClipMediaPerformanceBenchmark",
            dependencies: ["ClipMedia"],
            path: "Benchmarks/ClipMediaPerformanceBenchmark"
        ),
        .testTarget(
            name: "ClipMediaTests",
            dependencies: ["ClipMedia"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
