import Testing
@testable import ClipLiveShareWebRTC

@Suite("Opus music negotiation")
struct WebRTCOpusMusicSDPTests {
    @Test("existing Opus fmtp becomes stereo full-band music without losing capabilities")
    func upgradesExistingFormat() {
        let source = """
        v=0\r
        m=audio 9 UDP/TLS/RTP/SAVPF 111 0\r
        a=rtpmap:111 opus/48000/2\r
        a=fmtp:111 minptime=10;useinbandfec=1;stereo=0;maxaveragebitrate=32000\r
        a=rtpmap:0 PCMU/8000\r

        """

        let upgraded = WebRTCOpusMusicSDP.applying(to: source)

        #expect(upgraded.contains("minptime=10"))
        #expect(upgraded.contains("useinbandfec=1"))
        #expect(upgraded.contains("stereo=1"))
        #expect(upgraded.contains("sprop-stereo=1"))
        #expect(upgraded.contains("maxaveragebitrate=128000"))
        #expect(upgraded.contains("usedtx=0"))
        #expect(!upgraded.contains("stereo=0"))
        #expect(!upgraded.contains("maxaveragebitrate=32000"))
        #expect(upgraded.contains("a=rtpmap:0 PCMU/8000"))
        #expect(upgraded.contains("\r\n"))
    }

    @Test("missing Opus fmtp is inserted once and applying the profile is idempotent")
    func insertsMissingFormatIdempotently() {
        let source = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 109
        a=rtpmap:109 OPUS/48000/2
        a=sendonly
        """

        let upgraded = WebRTCOpusMusicSDP.applying(to: source)
        let reapplied = WebRTCOpusMusicSDP.applying(to: upgraded)

        #expect(upgraded == reapplied)
        #expect(upgraded.contains(
            "a=fmtp:109 stereo=1;sprop-stereo=1;maxaveragebitrate=128000;usedtx=0"
        ))
    }

    @Test("non-Opus descriptions are unchanged")
    func ignoresOtherCodecs() {
        let source = "v=0\r\nm=audio 9 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n"
        #expect(WebRTCOpusMusicSDP.applying(to: source) == source)
    }

    @Test("payload IDs reused by video and audio are rewritten only in the audio section")
    func scopesPayloadsToAudioMediaSection() {
        let source = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 111
        a=rtpmap:111 H264/90000
        a=fmtp:111 profile-level-id=640c34;packetization-mode=1
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=rtpmap:111 opus/48000/2
        a=fmtp:111 minptime=10;useinbandfec=1

        """

        let upgraded = WebRTCOpusMusicSDP.applying(to: source)
        let sections = upgraded.components(separatedBy: "m=audio")

        #expect(sections.count == 2)
        #expect(sections[0].contains(
            "a=fmtp:111 profile-level-id=640c34;packetization-mode=1"
        ))
        #expect(!sections[0].contains("stereo=1"))
        #expect(!sections[0].contains("maxaveragebitrate"))
        #expect(sections[1].contains("minptime=10"))
        #expect(sections[1].contains("useinbandfec=1"))
        #expect(sections[1].contains("stereo=1"))
        #expect(sections[1].contains("sprop-stereo=1"))
        #expect(sections[1].contains("maxaveragebitrate=128000"))
        #expect(sections[1].contains("usedtx=0"))
    }
}
