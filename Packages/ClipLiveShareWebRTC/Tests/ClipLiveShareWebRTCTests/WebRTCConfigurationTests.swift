import Testing
@testable import ClipLiveShareWebRTC

@Suite("WebRTC adapter package")
struct WebRTCConfigurationTests {
    @Test("the adapter links the pinned WebRTC framework")
    func frameworkLinks() {
        #expect(WebRTCRuntimeIdentity.frameworkName == "WebRTC")
        #expect(WebRTCRuntimeIdentity.controlDataChannelLabel == "clip-control-v1")
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

    @Test("receiver bookkeeping is bounded across duplicates and hostile media")
    func inboundReceiverBookkeepingIsBounded() {
        var policy = WebRTCInboundReceiverAdmissionPolicy(
            maximumVideoTracks: 99
        )
        for index in 0 ..< WebRTCRuntimeIdentity.maximumVideoSlots {
            #expect(policy.admit(
                receiverID: "video-\(index)",
                kind: .video
            ) == .accepted)
        }
        #expect(policy.admit(
            receiverID: "video-0",
            kind: .video
        ) == .duplicateCallback)
        #expect(policy.admit(
            receiverID: "video-extra",
            kind: .video
        ) == .videoLimitReached)
        #expect(policy.admit(
            receiverID: "audio-0",
            kind: .systemAudio
        ) == .accepted)
        #expect(policy.admit(
            receiverID: "audio-extra",
            kind: .systemAudio
        ) == .duplicateSystemAudio)
        for index in 0 ..< 100 {
            #expect(policy.admit(
                receiverID: "unsupported-\(index)",
                kind: .unsupported
            ) == .unsupported)
        }
        #expect(policy.retainedReceiverCount
            == WebRTCRuntimeIdentity.maximumVideoSlots + 1)

        policy.remove(receiverID: "video-0")
        #expect(policy.admit(
            receiverID: "video-replacement",
            kind: .video
        ) == .accepted)
        #expect(policy.retainedReceiverCount
            == WebRTCRuntimeIdentity.maximumVideoSlots + 1)
    }

    @Test("offer policy bounds audio, control, and unknown media sections")
    func offerPolicyBoundsEveryMediaKind() {
        let limits = WebRTCPeerResourceLimits.clipDefault
        #expect(throws: WebRTCPeerViewerError.invalidOfferMediaSections(
            maximumVideoTracks: WebRTCRuntimeIdentity.maximumVideoSlots
        )) {
            try WebRTCOfferMediaSectionPolicy.validate(
                "m=audio 9 RTP/AVP 111\r\nm=audio 9 RTP/AVP 111",
                resourceLimits: limits
            )
        }
        #expect(throws: WebRTCPeerViewerError.invalidOfferMediaSections(
            maximumVideoTracks: WebRTCRuntimeIdentity.maximumVideoSlots
        )) {
            try WebRTCOfferMediaSectionPolicy.validate(
                "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
                    + "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
                resourceLimits: limits
            )
        }
        #expect(throws: WebRTCPeerViewerError.invalidOfferMediaSections(
            maximumVideoTracks: WebRTCRuntimeIdentity.maximumVideoSlots
        )) {
            try WebRTCOfferMediaSectionPolicy.validate(
                "m=message 9 TCP/MSRP *",
                resourceLimits: limits
            )
        }
    }
}
