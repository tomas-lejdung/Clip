# Clip WebRTC source patches

Clip uses the M150 WebRTC source revision
`1f975dfd761af6e5d76d28333191973b258d82a8`. The public Objective-C capture
surface does not preserve `CVPixelBuffer` color information when it constructs
the native `VideoFrame`; libaom also leaves AV1 sequence-header CICP values
unspecified.

`0001-clip-rec709-color-signaling.patch` makes the existing Clip capture,
bitstream, and native rendering contract explicit:

- `420v` is Rec.709 limited range.
- `420f` is Rec.709 full range.
- other formats remain untagged, preserving WebRTC's existing behavior.
- AV1 writes the native frame's CICP values into its sequence header as well
  as WebRTC's negotiated color-space RTP extension.
- decoded color metadata crosses the C++/Objective-C frame bridge.
- the macOS Metal renderer selects Rec.709 video- or full-range conversion
  instead of treating every I420 frame as legacy full-range BT.601.

Apply the patch from the WebRTC source root before building the framework:

```sh
git checkout 1f975dfd761af6e5d76d28333191973b258d82a8
git apply /path/to/Clip/Packages/ClipLiveShareWebRTC/WebRTCPatches/0001-clip-rec709-color-signaling.patch
```

The patch adds color metadata to WebRTC's Objective-C frame ABI. Clip can
validate a local framework through the ignored `Vendor/WebRTC.xcframework`
path. Releases resolve the separately published immutable binary declared in
`Package.swift` and verify its archive, executable, normalized payload, source
patch, architecture, and complete generated license bundle.
