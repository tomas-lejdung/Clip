// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClipLiveShareWebRTC",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "ClipLiveShareWebRTC",
            targets: ["ClipLiveShareWebRTC"]
        ),
    ],
    dependencies: [
        .package(path: "../ClipCapture"),
        .package(path: "../ClipLiveShare"),
        .package(
            url: "https://github.com/stasel/WebRTC.git",
            exact: "150.0.0"
        ),
    ],
    targets: [
        .target(
            name: "ClipLiveShareWebRTC",
            dependencies: [
                "ClipCapture",
                "ClipLiveShare",
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .testTarget(
            name: "ClipLiveShareWebRTCTests",
            dependencies: [
                "ClipLiveShareWebRTC",
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
