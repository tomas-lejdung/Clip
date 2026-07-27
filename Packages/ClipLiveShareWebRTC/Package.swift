// swift-tools-version: 6.2

import Foundation
import PackageDescription

// Release builds use the immutable, checksummed artifact below. WebRTC source
// changes may first be exercised with the ignored local XCFramework; release
// packaging rejects that override and resolves the public artifact afresh.
let localWebRTCPath = "Vendor/WebRTC.xcframework"
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let usesLocalWebRTC = FileManager.default.fileExists(
    atPath: packageDirectory.appending(path: localWebRTCPath).path
)

let webRTCTargetName = "ClipPatchedWebRTC"
let webRTCTargetDependency: Target.Dependency = .target(name: webRTCTargetName)

var packageTargets: [Target] = [
    .target(
        name: "ClipLiveShareWebRTCAudioBridge",
        dependencies: [webRTCTargetDependency],
        publicHeadersPath: "include",
        linkerSettings: [
            .linkedFramework("AudioToolbox"),
            .linkedFramework("CoreMedia"),
        ]
    ),
    .target(
        name: "ClipLiveShareWebRTC",
        dependencies: [
            "ClipCapture",
            "ClipLiveShare",
            "ClipLiveShareWebRTCAudioBridge",
            webRTCTargetDependency,
        ]
    ),
    .testTarget(
        name: "ClipLiveShareWebRTCTests",
        dependencies: [
            "ClipLiveShareWebRTC",
            webRTCTargetDependency,
        ],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("WebKit"),
        ]
    ),
]
if usesLocalWebRTC {
    packageTargets.insert(
        .binaryTarget(name: webRTCTargetName, path: localWebRTCPath),
        at: 0
    )
} else {
    packageTargets.insert(
        .binaryTarget(
            name: webRTCTargetName,
            url: "https://github.com/tomas-lejdung/Clip/releases/download/webrtc-m150-clip-native-color-2/WebRTC-150.0.0-clip-native-color-macos-arm64.xcframework.zip",
            checksum: "a4d8b211049ac38074d9120e0f1eec87625118e29e835b9bea40f7dcab9abbe9"
        ),
        at: 0
    )
}

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
    ],
    targets: packageTargets,
    swiftLanguageModes: [.v6]
)
