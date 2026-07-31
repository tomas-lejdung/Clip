// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "ClipNativeV3AcceptanceValidator",
  platforms: [
    .macOS(.v15),
  ],
  dependencies: [
    .package(path: "../../Packages/ClipLiveShare"),
  ],
  targets: [
    .executableTarget(
      name: "ClipNativeV3AcceptanceValidator",
      dependencies: [
        .product(name: "ClipLiveShare", package: "ClipLiveShare"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
