// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClipCapture",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ClipCapture", targets: ["ClipCapture"]),
    ],
    targets: [
        .target(name: "ClipCapture"),
        .testTarget(
            name: "ClipCaptureTests",
            dependencies: ["ClipCapture"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
