# Clip WebRTC source patches

Clip uses the M150 WebRTC source revision
`1f975dfd761af6e5d76d28333191973b258d82a8`. The public Objective-C capture
surface does not preserve `CVPixelBuffer` color information when it constructs
the native `VideoFrame`; libaom also leaves AV1 sequence-header CICP values
unspecified.

`0001-clip-rec709-color-signaling.patch` makes the existing Clip capture,
bitstream, and native rendering contract explicit:

- `420v` is video range and `420f` is full range. Their CoreVideo primaries,
  transfer, and matrix attachments are converted to the corresponding CICP
  values, with Rec.709 as the fallback when redundant attachments are absent.
- Packed BGRA/ARGB preserves its CoreVideo primaries and transfer function,
  including sRGB and Display P3. If those string attachments are absent, the
  patch recognizes the image buffer's named sRGB, Display P3, or ITU-R BT.709
  `CGColorSpace`; unknown RGB defaults to sRGB. WebRTC converts these buffers
  through libyuv's `ARGBToI420`/`BGRAToI420`, so their physical I420 matrix
  and range are always described as BT.601/SMPTE 170M limited range.
- Other formats remain untagged, preserving WebRTC's existing behavior.
- AV1 writes the native frame's CICP values into its sequence header as well
  as WebRTC's negotiated color-space RTP extension.
- decoded color metadata crosses the C++/Objective-C frame bridge.
- the macOS Metal renderer independently selects BT.601 or Rec.709 video/full
  range conversion. A Display P3 frame carrying a BT.709 transfer is converted
  from BT.709 nonlinear RGB to sRGB nonlinear RGB before the output is marked
  Display P3; native P3/sRGB frames remain direct. Metal output is then marked
  as sRGB, Display P3, or ITU-R BT.709 for Core Animation's final display
  conversion.

Clip's custom VideoToolbox H.264 encoder remains intentionally normalized to
Rec.709 video range. WebRTC's metadata writer normally copies the input
`VideoFrame` color space onto the encoded image and may rewrite the H.264 SPS
from it. The patch replaces that copied value with explicit Rec.709
primaries/transfer/matrix and limited range for H.264 before the SPS rewrite,
keeping RTP metadata and VideoToolbox's Rec.709 VUI consistent.

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
