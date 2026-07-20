import ClipLiveShare
import Foundation
import Testing
@testable import ClipLiveShareWebRTC

extension NativeMediaResourceTests {
@Suite("Native WebRTC peer host", .serialized)
struct WebRTCPeerHostTests {
    @Test("four stable GoPeep slots are preallocated")
    func stableSlots() throws {
        let host = try WebRTCPeerHost(eventQueue: .global())
        defer { host.close() }

        #expect(host.slotSnapshots.map(\.trackID) == [
            "video0", "video1", "video2", "video3",
        ])
        #expect(host.slotSnapshots.map(\.streamID) == [
            "gopeep-stream-0", "gopeep-stream-1",
            "gopeep-stream-2", "gopeep-stream-3",
        ])
        #expect(host.slotSnapshots.allSatisfy { !$0.isActive })
    }

    @Test("slot activation validates bounds and stable track identity")
    func slotActivation() throws {
        let host = try WebRTCPeerHost(eventQueue: .global())
        defer { host.close() }
        let metadata = Self.metadata(slot: 1)

        try host.activateSlot(1, metadata: metadata)
        #expect(host.slotSnapshots[1].metadata == metadata)
        #expect(throws: WebRTCPeerHostError.slotAlreadyActive(1)) {
            try host.activateSlot(1, metadata: metadata)
        }
        #expect(throws: WebRTCPeerHostError.slotTrackMismatch(
            slot: 2,
            expected: "video2",
            actual: "video1"
        )) {
            try host.activateSlot(2, metadata: metadata)
        }
        #expect(throws: WebRTCPeerHostError.invalidSlot(4)) {
            try host.activateSlot(4, metadata: Self.metadata(slot: 4))
        }

        host.deactivateSlot(1)
        #expect(host.slotSnapshots[1].metadata == nil)
    }

    @Test("offer contains all stable streams, H264, and the data channel")
    func goPeepOfferShape() async throws {
        let encoderFormats = WebRTCH264EncoderFactory().supportedCodecs()
        #expect(encoderFormats.map { $0.parameters["profile-level-id"] } == [
            "640c34", "42e034",
        ])
        let host = try WebRTCPeerHost(eventQueue: .global())
        defer { host.close() }

        let offer = try await host.createOffer(for: "viewer-fixture")

        #expect(offer.kind == .offer)
        #expect(Self.occurrences(of: "m=video", in: offer.sdp) == 4)
        for slot in 0 ..< 4 {
            #expect(offer.sdp.contains("gopeep-stream-\(slot) video\(slot)"))
        }
        #expect(offer.sdp.contains(" H264/90000"))
        #expect(offer.sdp.contains("profile-level-id=640c34"))
        #expect(offer.sdp.contains("profile-level-id=42e034"))
        #expect(!offer.sdp.contains("profile-level-id=640c1f"))
        #expect(!offer.sdp.contains("profile-level-id=42e01f"))
        #expect(!offer.sdp.contains(" VP8/90000"))
        #expect(!offer.sdp.contains(" VP9/90000"))
        #expect(offer.sdp.contains("m=application"))
        #expect(host.viewerIDs == ["viewer-fixture"])
        await #expect(throws: WebRTCPeerHostError.duplicateViewer("viewer-fixture")) {
            try await host.createOffer(for: "viewer-fixture")
        }
    }

    @Test("composite encoder factory exposes H264 and VP8 in selected order")
    func compositeEncoderFactoryCodecOrder() {
        let h264First = WebRTCVideoEncoderFactory(preferredCodec: .h264)
            .supportedCodecs().map(\.name)
        let vp8First = WebRTCVideoEncoderFactory(preferredCodec: .vp8)
            .supportedCodecs().map(\.name)

        #expect(h264First.first == "H264")
        #expect(vp8First.first == "VP8")
        #expect(h264First.contains("VP8"))
        #expect(vp8First.contains("H264"))
    }

    @Test("VP8 host offers VP8 exclusively while retaining stable stream IDs")
    func vp8OfferShape() async throws {
        let host = try WebRTCPeerHost(
            configuration: .init(iceServers: [], videoCodec: .vp8),
            eventQueue: .global()
        )
        defer { host.close() }

        let offer = try await host.createOffer(for: "vp8-viewer")

        #expect(Self.occurrences(of: "m=video", in: offer.sdp) == 4)
        #expect(offer.sdp.contains(" VP8/90000"))
        #expect(!offer.sdp.contains(" H264/90000"))
        for slot in 0 ..< 4 {
            #expect(offer.sdp.contains("gopeep-stream-\(slot) video\(slot)"))
        }
    }

    @Test("trickle candidate JSON matches the browser shape")
    func candidateJSON() throws {
        let candidate = WebRTCICECandidate(
            candidate: "candidate:1 1 UDP 1 192.0.2.1 12345 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        let data = try JSONEncoder().encode(candidate)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["candidate"] as? String == candidate.candidate)
        #expect(object["sdpMid"] as? String == "0")
        #expect(object["sdpMLineIndex"] as? Int == 0)
    }

    @Test("candidate validation rejects oversized, malformed, and out-of-range input")
    func candidateValidation() throws {
        let limits = WebRTCPeerResourceLimits(
            maximumViewerCount: 1,
            answerTimeout: 1,
            maximumICECandidatesPerPeer: 2,
            maximumICECandidatePayloadBytes: 256,
            maximumViewerIDBytes: 32
        )
        try WebRTCICECandidate(
            candidate: "candidate:1 1 UDP 2122260223 192.0.2.1 41000 typ host generation 0",
            sdpMid: "0",
            sdpMLineIndex: 0
        ).validate(resourceLimits: limits)
        try WebRTCICECandidate(
            candidate: "candidate:2 1 tcp 1518280447 2001:db8::1 9 typ relay tcptype active",
            sdpMid: "4",
            sdpMLineIndex: 4
        ).validate(resourceLimits: limits)

        #expect(throws: WebRTCICECandidateValidationError.payloadTooLarge(
            maximumBytes: 256
        )) {
            try WebRTCICECandidate(
                candidate: String(repeating: "x", count: 257),
                sdpMid: "0",
                sdpMLineIndex: 0
            ).validate(resourceLimits: limits)
        }
        #expect(throws: WebRTCICECandidateValidationError.invalidMediaLineIndex(5)) {
            try WebRTCICECandidate(
                candidate: "candidate:1 1 udp 1 192.0.2.1 41000 typ host",
                sdpMid: "5",
                sdpMLineIndex: 5
            ).validate(resourceLimits: limits)
        }
        #expect(throws: WebRTCICECandidateValidationError.malformedCandidate) {
            try WebRTCICECandidate(
                candidate: "candidate:1 1 udp 1 192.0.2.1 41000 host",
                sdpMid: "0",
                sdpMLineIndex: 0
            ).validate(resourceLimits: limits)
        }
        #expect(throws: WebRTCICECandidateValidationError.malformedCandidate) {
            try WebRTCICECandidate(
                candidate: "candidate:1 1 udp 1 192.0.2.1 41000 typ host\nspoofed",
                sdpMid: "0",
                sdpMLineIndex: 0
            ).validate(resourceLimits: limits)
        }
    }

    @Test("control channel applies payload and buffered high-water limits")
    func controlBufferPolicy() {
        let policy = WebRTCControlBufferPolicy(resourceLimits: .init(
            maximumControlMessagePayloadBytes: 1_024,
            maximumControlBufferedAmountBytes: 65_536
        ))
        #expect(policy.permits(payloadByteCount: 1_024, bufferedAmountBytes: 64_512))
        #expect(!policy.permits(payloadByteCount: 1_025, bufferedAmountBytes: 0))
        #expect(!policy.permits(payloadByteCount: 1_024, bufferedAmountBytes: 64_513))
        #expect(policy.hasDrained(bufferedAmountBytes: 32_768))
        #expect(!policy.hasDrained(bufferedAmountBytes: 32_769))

        let normalized = WebRTCPeerResourceLimits(
            maximumControlMessagePayloadBytes: 400_000,
            maximumControlBufferedAmountBytes: 1
        ).normalized
        #expect(normalized.maximumControlMessagePayloadBytes == 262_144)
        #expect(normalized.maximumControlBufferedAmountBytes == 262_144)
    }

    @Test("viewer admission is capped before allocating another peer")
    func viewerAdmissionLimit() async throws {
        let configuration = WebRTCPeerHostConfiguration(
            iceServers: [],
            resourceLimits: .init(
                maximumViewerCount: 1,
                answerTimeout: 5,
                maximumICECandidatesPerPeer: 8,
                maximumICECandidatePayloadBytes: 1_024,
                maximumViewerIDBytes: 32
            )
        )
        let host = try WebRTCPeerHost(configuration: configuration, eventQueue: .global())
        defer { host.close() }

        _ = try await host.createOffer(for: "viewer-1")
        await #expect(throws: WebRTCPeerHostError.viewerCapacityReached(maximum: 1)) {
            try await host.createOffer(for: "viewer-2")
        }
        await #expect(throws: WebRTCPeerHostError.invalidViewerID(maximumBytes: 32)) {
            try await host.createOffer(for: String(repeating: "x", count: 33))
        }

        host.removePeer("viewer-1")
        _ = try await host.createOffer(for: "viewer-2")
        #expect(host.viewerIDs == ["viewer-2"])
    }

    @Test("an unanswered offer releases its peer after the deadline")
    func answerTimeout() async throws {
        let configuration = WebRTCPeerHostConfiguration(
            iceServers: [],
            resourceLimits: .init(
                maximumViewerCount: 1,
                answerTimeout: 0.05,
                maximumICECandidatesPerPeer: 8,
                maximumICECandidatePayloadBytes: 1_024,
                maximumViewerIDBytes: 32
            )
        )
        let host = try WebRTCPeerHost(configuration: configuration, eventQueue: .global())
        defer { host.close() }

        _ = try await host.createOffer(for: "stale-viewer")
        #expect(host.viewerIDs == ["stale-viewer"])
        try await Task.sleep(for: .milliseconds(150))
        #expect(host.viewerIDs.isEmpty)

        // Capacity is immediately reusable after cleanup.
        _ = try await host.createOffer(for: "replacement")
        #expect(host.viewerIDs == ["replacement"])
    }

    @Test("remote ICE attempts have a per-peer upper bound")
    func remoteCandidateLimit() async throws {
        let configuration = WebRTCPeerHostConfiguration(
            iceServers: [],
            resourceLimits: .init(
                maximumViewerCount: 1,
                answerTimeout: 5,
                maximumICECandidatesPerPeer: 1,
                maximumICECandidatePayloadBytes: 1_024,
                maximumViewerIDBytes: 32
            )
        )
        let host = try WebRTCPeerHost(configuration: configuration, eventQueue: .global())
        defer { host.close() }
        _ = try await host.createOffer(for: "viewer-1")

        let first = WebRTCICECandidate(
            candidate: "candidate:1 1 udp 2122260223 192.0.2.1 41000 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        // libwebrtc may reject this before a remote description exists; it is
        // still counted because repeatedly failing native parses are work.
        try? await host.addRemoteICECandidate(first, for: "viewer-1")
        await #expect(throws: WebRTCPeerHostError.iceCandidateLimitReached(
            viewerID: "viewer-1",
            maximum: 1
        )) {
            try await host.addRemoteICECandidate(first, for: "viewer-1")
        }

        let malformed = WebRTCICECandidate(
            candidate: "not-an-ice-candidate",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        await #expect(throws: WebRTCPeerHostError.invalidICECandidate(
            WebRTCICECandidateValidationError.malformedCandidate.localizedDescription
        )) {
            host.removePeer("viewer-1")
            _ = try await host.createOffer(for: "viewer-1")
            try await host.addRemoteICECandidate(malformed, for: "viewer-1")
        }
    }

    @Test("remote session descriptions have a hard allocation bound")
    func remoteSessionDescriptionLimit() async throws {
        let configuration = WebRTCPeerHostConfiguration(
            iceServers: [],
            resourceLimits: .init(
                maximumViewerCount: 1,
                answerTimeout: 5,
                maximumICECandidatesPerPeer: 8,
                maximumICECandidatePayloadBytes: 1_024,
                maximumViewerIDBytes: 32,
                maximumSDPPayloadBytes: 4_096
            )
        )
        let host = try WebRTCPeerHost(configuration: configuration, eventQueue: .global())
        defer { host.close() }
        _ = try await host.createOffer(for: "viewer-1")

        await #expect(throws: WebRTCPeerHostError.sessionDescriptionPayloadTooLarge(
            maximumBytes: 4_096
        )) {
            try await host.setRemoteAnswer(
                .init(kind: .answer, sdp: String(repeating: "x", count: 4_097)),
                for: "viewer-1"
            )
        }
    }

    @Test("closed hosts reject new work and close is idempotent")
    func idempotentClose() async throws {
        let host = try WebRTCPeerHost(eventQueue: .global())
        host.close()
        host.close()

        await #expect(throws: WebRTCPeerHostError.hostClosed) {
            try await host.createOffer(for: "late-viewer")
        }
        #expect(throws: WebRTCPeerHostError.hostClosed) {
            try host.activateSlot(0, metadata: Self.metadata(slot: 0))
        }
    }

    @Test("SDP operation generations reject stale offer and answer callbacks")
    func sdpOperationGenerations() {
        var generation = WebRTCPeerOperationGeneration()

        let firstOffer = generation.beginLocalDescription()
        #expect(generation.hasLocalDescriptionInFlight)
        #expect(generation.contains(firstOffer))
        let firstAnswer = generation.beginRemoteDescription()
        #expect(generation.contains(firstAnswer))

        let replacementAnswer = generation.beginRemoteDescription()
        #expect(!generation.contains(firstAnswer))
        #expect(generation.contains(replacementAnswer))

        let replacementOffer = generation.beginLocalDescription()
        #expect(!generation.contains(firstOffer))
        #expect(!generation.contains(replacementAnswer))
        #expect(generation.contains(replacementOffer))

        // Completing a stale callback cannot mark a newer local-description
        // operation idle. This is the state used by updateVideoCodec's gate.
        generation.finishLocalDescription(firstOffer)
        #expect(generation.hasLocalDescriptionInFlight)
        generation.finishLocalDescription(replacementOffer)
        #expect(!generation.hasLocalDescriptionInFlight)

        _ = generation.beginLocalDescription()
        #expect(generation.hasLocalDescriptionInFlight)
        generation.invalidateLocalDescriptions()
        #expect(!generation.hasLocalDescriptionInFlight)
    }

    @Test("sender and ICE defaults are explicit and injectable")
    func configurationPolicy() throws {
        #expect(WebRTCPeerHostConfiguration.goPeepDefault.senderPolicy == .goPeepDefault)
        #expect(WebRTCSenderPolicy.goPeepDefault.maintainsResolution)
        #expect(WebRTCSenderPolicy.goPeepDefault.bitratePriority == 1)
        #expect(WebRTCSenderPolicy.goPeepDefault.maximumFramesPerSecond == 30)
        #expect(WebRTCSenderPolicy.goPeepDefault.maximumBitrateBps == 12_000_000)
        #expect(WebRTCPeerHostConfiguration.goPeepDefault.iceServers.count == 3)
        #expect(WebRTCPeerHostConfiguration.goPeepDefault.resourceLimits == .goPeepDefault)
        #expect(WebRTCPeerResourceLimits.goPeepDefault.maximumViewerCount == 8)
        #expect(WebRTCPeerResourceLimits.goPeepDefault.answerTimeout == 15)
        let hardMaximums = WebRTCPeerResourceLimits(
            maximumViewerCount: .max,
            answerTimeout: .infinity,
            maximumICECandidatesPerPeer: .max,
            maximumICECandidatePayloadBytes: .max,
            maximumViewerIDBytes: .max,
            maximumSDPPayloadBytes: .max,
            maximumControlMessagePayloadBytes: .max,
            maximumControlBufferedAmountBytes: .max
        ).normalized
        #expect(hardMaximums.maximumViewerCount == 32)
        #expect(hardMaximums.answerTimeout == 15)
        #expect(hardMaximums.maximumICECandidatesPerPeer == 1_024)
        #expect(hardMaximums.maximumICECandidatePayloadBytes == 16_384)
        #expect(hardMaximums.maximumViewerIDBytes == 512)
        #expect(hardMaximums.maximumSDPPayloadBytes == 1_048_576)
        #expect(hardMaximums.maximumControlMessagePayloadBytes == 262_144)
        #expect(hardMaximums.maximumControlBufferedAmountBytes == 4_194_304)

        let custom = WebRTCPeerHostConfiguration(
            iceServers: [.init(
                urlStrings: ["turns:relay.example.test:5349"],
                username: "viewer",
                credential: "secret"
            )],
            forcesRelay: true,
            senderPolicy: .init(
                maximumBitrateBps: 4_000_000,
                maximumFramesPerSecond: 24,
                maintainsResolution: true
            ),
            videoEncodingMode: .performance
        )
        #expect(custom.forcesRelay)
        #expect(custom.senderPolicy.maximumFramesPerSecond == 24)
        #expect(custom.videoEncodingMode == .performance)

        let host = try WebRTCPeerHost(configuration: custom, eventQueue: .global())
        defer { host.close() }
        #expect(host.videoEncodingMode == .performance)
        host.updateVideoEncodingMode(.quality)
        #expect(host.videoEncodingMode == .quality)
        let updated = WebRTCSenderPolicy(
            maximumBitrateBps: 8_000_000,
            maximumFramesPerSecond: 30,
            maintainsResolution: true
        )
        host.updateSenderPolicy(updated)
        #expect(host.senderPolicy == updated)

        let background = WebRTCSenderPolicy(
            maximumBitrateBps: 2_000_000,
            maximumFramesPerSecond: 30,
            maintainsResolution: true
        )
        host.updateSenderPolicies([1: background], fallback: updated)
        #expect(host.senderPolicy == updated)
        #expect(host.senderPolicy(forSlot: 0) == updated)
        #expect(host.senderPolicy(forSlot: 1) == background)
    }

    private static func metadata(slot: Int) -> GoPeepV1StreamInfo {
        GoPeepV1StreamInfo(
            trackID: "video\(slot)",
            windowName: "Fixture",
            appName: "Tests",
            isFocused: slot == 0,
            width: 1_280,
            height: 720
        )
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
}
