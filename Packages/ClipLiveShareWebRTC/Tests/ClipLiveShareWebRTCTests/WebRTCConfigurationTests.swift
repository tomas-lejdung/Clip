import Testing
@testable import ClipLiveShareWebRTC

@Suite("WebRTC adapter package")
struct WebRTCConfigurationTests {
    @Test("the adapter links the pinned WebRTC framework")
    func frameworkLinks() {
        #expect(WebRTCRuntimeIdentity.frameworkName == "WebRTC")
    }

    @Test("receiver limits are normalized to Clip's four-window contract")
    func receiverLimitsNormalize() {
        #expect(WebRTCPeerResourceLimits(
            maximumVideoTracks: 99
        ).normalized.maximumVideoTracks
            == WebRTCRuntimeIdentity.maximumVideoSlots)
        #expect(WebRTCPeerResourceLimits(
            maximumVideoTracks: 0
        ).normalized.maximumVideoTracks == 1)
    }

    @Test("offer policy bounds audio, control, and unknown media sections")
    func offerPolicyBoundsEveryMediaKind() {
        let limits = WebRTCPeerResourceLimits.clipDefault
        #expect(
            throws:
                ClipLiveShareNativeV3WebRTCPeerLinkError
                .invalidSessionDescriptionKind
        ) {
            try WebRTCOfferMediaSectionPolicy.validate(
                "m=audio 9 RTP/AVP 111\r\nm=audio 9 RTP/AVP 111",
                resourceLimits: limits
            )
        }
        #expect(
            throws:
                ClipLiveShareNativeV3WebRTCPeerLinkError
                .invalidSessionDescriptionKind
        ) {
            try WebRTCOfferMediaSectionPolicy.validate(
                "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
                    + "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
                resourceLimits: limits
            )
        }
        #expect(
            throws:
                ClipLiveShareNativeV3WebRTCPeerLinkError
                .invalidSessionDescriptionKind
        ) {
            try WebRTCOfferMediaSectionPolicy.validate(
                "m=message 9 TCP/MSRP *",
                resourceLimits: limits
            )
        }
    }
}
