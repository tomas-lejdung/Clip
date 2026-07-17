// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClipCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ClipCore", targets: ["ClipCore"]),
    ],
    targets: [
        .target(name: "ClipCore"),
        .testTarget(
            name: "ClipCoreTests",
            dependencies: ["ClipCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
