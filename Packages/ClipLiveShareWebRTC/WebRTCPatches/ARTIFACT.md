# Clip WebRTC M150 native-color artifact 3

This dependency release contains Clip's macOS arm64 WebRTC M150 XCFramework.
It is built from upstream commit
`1f975dfd761af6e5d76d28333191973b258d82a8` with
`0001-clip-rec709-color-signaling.patch` applied.

## Integrity

- Asset: `WebRTC-150.0.0-clip-native-color-macos-arm64.xcframework.zip`
- SwiftPM/archive SHA-256:
  `07807d9d8f246da5b6eebbb62cc1acfeb594b2974c62e47cb36bdd03f5256d5a`
- Source patch SHA-256:
  `e58f6bc5f0dda361000081d6868ca1cf0a791a48576f92b850a1f5df6820cb6a`
- Framework executable SHA-256:
  `99312b0656b329102d17fde07f2934ef03ea6bd906fbc61025a9c92e2e6b137a`
- Normalized arm64 payload SHA-256:
  `b84186f57c0dbefb04e1bbb3da43fe5f8eb4871c03c1342ad8d9333ba3e695df`
- Generated WebRTC license bundle SHA-256:
  `5b08f62df6d3d7cf1191586b30386055596a1971d4d5fad8974e496096ff4e07`

The generated license bundle contains WebRTC and all 23 linked third-party
library notices. The ZIP excludes macOS resource-fork metadata so SwiftPM
resolves exactly one framework. This is an application dependency release, not
a Clip app release, and must not be marked as GitHub's latest release.
