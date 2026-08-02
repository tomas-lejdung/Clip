// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "ClipServerRoomV4Acceptance",
  platforms: [
    .macOS(.v15),
  ],
  dependencies: [
    .package(path: "../../Packages/ClipLiveShare"),
    .package(path: "../../Packages/ClipLiveShareWebRTC"),
  ],
  targets: [
    .executableTarget(
      name: "ClipServerRoomV4Acceptance",
      dependencies: [
        .product(name: "ClipLiveShare", package: "ClipLiveShare"),
        .product(name: "ClipLiveShareWebRTC", package: "ClipLiveShareWebRTC"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
