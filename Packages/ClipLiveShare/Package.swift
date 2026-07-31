// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClipLiveShare",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ClipLiveShare", targets: ["ClipLiveShare"]),
    ],
    targets: [
        .target(name: "ClipLiveShare"),
        .testTarget(
            name: "ClipLiveShareTests",
            dependencies: ["ClipLiveShare"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
