# Local WebRTC validation artifact

Clip normally resolves the immutable WebRTC artifact declared in
`Package.swift`. During development of a WebRTC source patch, place a complete
`WebRTC.xcframework` beside this file. The package manifest detects it and uses
the local binary target instead of downloading the release artifact.

The framework directory is ignored by Git. This prevents the binary from
inflating the application repository and prevents an unreviewed local build
from silently becoming a release dependency.

Install a local build with:

```sh
./scripts/use-local-webrtc.sh /path/to/WebRTC.xcframework
```

SwiftPM caches evaluated manifests independently of files beside them. Direct
`swift build` and `swift test` commands must therefore include
`--manifest-cache none` after installing or removing the override. Clip's
scripts already do this for this package.

`package-dmg.sh` rejects this override and always resolves the reviewed remote
artifact from a fresh dependency cache before producing a public DMG.
