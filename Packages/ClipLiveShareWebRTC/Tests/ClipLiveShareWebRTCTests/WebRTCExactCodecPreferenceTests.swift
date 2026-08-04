import Testing

@testable import ClipLiveShareWebRTC

@Suite("Exact WebRTC video codec contract")
struct WebRTCExactCodecPreferenceTests {
  @Test("each room codec advertises only itself")
  func exactSelectedCodec() {
    for codec in WebRTCVideoCodec.allCases {
      #expect(
        ClipLiveShareNativeV3WebRTCPeerLinkTransport
          .videoCodecPreferenceNames(for: codec) == [codec.rtcName]
      )
    }
  }

  @Test("AV1 and VP9 never advertise legacy fallback codecs")
  func noFallbackOrDoubleEncoding() {
    let av1 = ClipLiveShareNativeV3WebRTCPeerLinkTransport
      .videoCodecPreferenceNames(for: .av1)
    #expect(av1 == ["AV1"])
    #expect(!av1.contains("VP9"))
    #expect(!av1.contains("VP8"))

    let vp9 = ClipLiveShareNativeV3WebRTCPeerLinkTransport
      .videoCodecPreferenceNames(for: .vp9)
    #expect(vp9 == ["VP9"])
    #expect(!vp9.contains("VP8"))
  }

  @Test("native peers preserve the pre-Web one-encoder codec ladder")
  func nativeCompatibilityPreferenceOrder() {
    let names = { (codec: WebRTCVideoCodec) in
      ClipLiveShareNativeV3WebRTCPeerLinkTransport.videoCodecPreferenceNames(
        for: codec,
        policy: .nativeCompatible
      )
    }
    #expect(names(.av1) == ["AV1", "VP9", "VP8"])
    #expect(names(.vp9) == ["VP9", "VP8"])
    #expect(names(.vp8) == ["VP8"])
    #expect(names(.h264) == ["H264"])
  }
}
