import ClipCapture
import ClipLiveShare
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import ClipLiveShareWebRTC

extension NativeMediaResourceTests {
@Suite("Native WebRTC peer host", .serialized)
struct WebRTCPeerHostTests {
    @Test("four stable slots receive opaque per-session WebRTC identities")
    func stableSlots() throws {
        let host = try WebRTCPeerHost(eventQueue: .global())
        defer { host.close() }

        let trackIDs = host.slotSnapshots.map(\.trackID)
        let streamIDs = host.slotSnapshots.map(\.streamID)
        #expect(Set(trackIDs).count == 4)
        #expect(Set(streamIDs).count == 4)
        #expect(trackIDs.allSatisfy { ClipLiveShareBase64URL.decode($0)?.count == 16 })
        #expect(streamIDs.allSatisfy { ClipLiveShareBase64URL.decode($0)?.count == 16 })
        #expect(host.slotSnapshots.allSatisfy { !$0.isActive })
    }

    @Test("valid audio before the first viewer is accepted without retaining backlog")
    func preViewerSystemAudioDoesNotBacklog() throws {
        let host = try WebRTCPeerHost(eventQueue: .global())
        defer { host.close() }
        host.setSystemAudioEnabled(true)

        let frameCount = 960
        #expect(host.send(BorrowedCaptureAudioSample(
            sampleBuffer: try makeSystemAudioFixture(frameCount: frameCount)
        )))
        let snapshot = host.systemAudioSnapshot
        #expect(snapshot.acceptedFrameCount == 0)
        #expect(snapshot.droppedFrameCount == frameCount)
        #expect(snapshot.queuedFrameCount == 0)
    }

    @Test("system audio caps the Opus sender at its music-quality allocation")
    func systemAudioSenderPolicy() {
        let encoding = RTCRtpEncodingParameters()

        WebRTCPeerHost.applySystemAudioEncodingPolicy(to: encoding)

        #expect(encoding.minBitrateBps == nil)
        #expect(encoding.maxBitrateBps?.intValue == 128_000)
        #expect(encoding.bitratePriority == 1)
        #expect(encoding.networkPriority == .high)
    }

    @Test("advanced sender policy maps every live RTP field")
    func advancedSenderPolicy() {
        #expect(WebRTCPeerHost.rtcDegradationPreference(for: .resolution)
            == .maintainResolution)
        #expect(WebRTCPeerHost.rtcDegradationPreference(for: .balanced)
            == .balanced)
        #expect(WebRTCPeerHost.rtcDegradationPreference(for: .framerate)
            == .maintainFramerate)
        #expect(WebRTCPeerHost.rtcDegradationPreference(for: .disabled)
            == .disabled)

        let encoding = RTCRtpEncodingParameters()
        WebRTCPeerHost.applyVideoSenderPolicy(
            WebRTCSenderPolicy(
                maximumBitrateBps: 8_000_000,
                minimumBitrateBps: 2_000_000,
                maximumFramesPerSecond: 24,
                degradationStrategy: .balanced,
                temporalLayerCount: 3,
                resolutionScale: 1.5,
                bitratePriority: 1.25
            ),
            to: encoding
        )

        #expect(encoding.maxBitrateBps?.intValue == 8_000_000)
        #expect(encoding.minBitrateBps?.intValue == 2_000_000)
        #expect(encoding.maxFramerate?.intValue == 24)
        #expect(encoding.numTemporalLayers?.intValue == 3)
        #expect(encoding.scaleResolutionDownBy?.doubleValue == 1.5)
        #expect(encoding.bitratePriority == 1.25)
        #expect(encoding.networkPriority == .high)
    }

    @Test("slot activation validates bounds and stable track identity")
    func slotActivation() throws {
        let host = try WebRTCPeerHost(eventQueue: .global())
        defer { host.close() }
        let metadata = Self.metadata(for: host.slotSnapshots[1])

        try host.activateSlot(1, metadata: metadata)
        #expect(host.slotSnapshots[1].metadata == metadata)
        #expect(throws: WebRTCPeerHostError.slotAlreadyActive(1)) {
            try host.activateSlot(1, metadata: metadata)
        }
        #expect(throws: WebRTCPeerHostError.slotTrackMismatch(
            slot: 2,
            expected: host.slotSnapshots[2].trackID,
            actual: host.slotSnapshots[1].trackID
        )) {
            try host.activateSlot(2, metadata: metadata)
        }
        #expect(throws: WebRTCPeerHostError.invalidSlot(4)) {
            try host.activateSlot(
                4,
                metadata: ClipLiveShareWebRTCTestFixtures.streamDescriptor(
                    mediaTrackID: "out-of-range-track"
                )
            )
        }

        host.deactivateSlot(1)
        #expect(host.slotSnapshots[1].metadata == nil)
    }

    @Test("offer contains all stable streams, H264, and the data channel")
    func clipOfferShape() async throws {
        let encoderFormats = WebRTCH264EncoderFactory().supportedCodecs()
        #expect(encoderFormats.map { $0.parameters["profile-level-id"] } == [
            "640c34", "42e034",
        ])
        let host = try WebRTCPeerHost(eventQueue: .global())
        defer { host.close() }

        let offer = try await host.createOffer(for: "viewer-fixture")

        #expect(offer.kind == .offer)
        #expect(Self.occurrences(of: "m=video", in: offer.sdp) == 4)
        for slot in host.slotSnapshots {
            #expect(offer.sdp.contains("\(slot.streamID) \(slot.trackID)"))
        }
        #expect(offer.sdp.contains(" H264/90000"))
        #expect(offer.sdp.contains("profile-level-id=640c34"))
        #expect(offer.sdp.contains("profile-level-id=42e034"))
        #expect(!offer.sdp.contains("profile-level-id=640c1f"))
        #expect(!offer.sdp.contains("profile-level-id=42e01f"))
        #expect(!offer.sdp.contains(" VP8/90000"))
        #expect(!offer.sdp.contains(" VP9/90000"))
        #expect(!offer.sdp.contains(" AV1/90000"))
        #expect(Self.occurrences(of: "m=audio", in: offer.sdp) == 1)
        #expect(offer.sdp.localizedCaseInsensitiveContains(" opus/48000/2"))
        #expect(offer.sdp.contains("stereo=1"))
        #expect(offer.sdp.contains("sprop-stereo=1"))
        #expect(offer.sdp.contains("maxaveragebitrate=128000"))
        #expect(offer.sdp.contains("usedtx=0"))
        let audio = host.systemAudioSnapshot
        #expect(offer.sdp.contains("\(audio.streamID) \(audio.trackID)"))
        #expect(offer.sdp.contains("m=application"))
        #expect(host.viewerIDs == ["viewer-fixture"])
        await #expect(throws: WebRTCPeerHostError.duplicateViewer("viewer-fixture")) {
            try await host.createOffer(for: "viewer-fixture")
        }
    }

    @Test("video codec model maps every persisted value to its RTC name")
    func videoCodecModel() throws {
        #expect(WebRTCVideoCodec.allCases == [.h264, .vp8, .vp9, .av1])
        #expect(WebRTCVideoCodec.allCases.map(\.rawValue) == [
            "h264", "vp8", "vp9", "av1",
        ])
        #expect(WebRTCVideoCodec.allCases.map(\.rtcName) == [
            "H264", "VP8", "VP9", "AV1",
        ])

        for codec in WebRTCVideoCodec.allCases {
            let data = try JSONEncoder().encode(codec)
            let decoded = try JSONDecoder().decode(
                WebRTCVideoCodec.self,
                from: data
            )
            #expect(decoded == codec)
        }
    }

    @Test("composite encoder factory exposes available codecs in selected order")
    func compositeEncoderFactoryCodecOrder() {
        let supportedKinds = WebRTCVideoCodec.allCases.filter { codec in
            switch codec {
            case .h264, .vp8:
                true
            case .vp9:
                RTCVideoEncoderVP9.isSupported()
            case .av1:
                RTCVideoEncoderAV1.isSupported()
            }
        }

        for preferredCodec in supportedKinds {
            let factory = WebRTCVideoEncoderFactory(
                preferredCodec: preferredCodec
            )
            let codecNames = factory.supportedCodecs().map(\.name)

            #expect(codecNames.first == preferredCodec.rtcName)
            for codec in supportedKinds {
                #expect(codecNames.contains(codec.rtcName))
            }

            let vp9Formats = factory.supportedCodecs().filter {
                $0.name == WebRTCVideoCodec.vp9.rtcName
            }
            #expect(vp9Formats.allSatisfy {
                $0.parameters["profile-id"] == "0"
            })
        }
    }

    @Test("software codec runtime guards control advertising and creation")
    func softwareCodecRuntimeGuards() {
        let unsupportedFactory = WebRTCVideoEncoderFactory(
            preferredCodec: .vp9,
            supportsVP9: false,
            supportsAV1: false
        )

        #expect(!unsupportedFactory.supportedCodecs().contains {
            $0.name == WebRTCVideoCodec.vp9.rtcName
        })
        #expect(!unsupportedFactory.supportedCodecs().contains {
            $0.name == WebRTCVideoCodec.av1.rtcName
        })
        #expect(unsupportedFactory.createEncoder(
            RTCVideoCodecInfo(name: WebRTCVideoCodec.vp9.rtcName)
        ) == nil)
        #expect(unsupportedFactory.createEncoder(
            RTCVideoCodecInfo(name: WebRTCVideoCodec.av1.rtcName)
        ) == nil)

        let supportedFactory = WebRTCVideoEncoderFactory(
            preferredCodec: .vp9,
            supportsVP9: true,
            supportsAV1: true
        )
        #expect(supportedFactory.supportedCodecs().contains {
            $0.name == WebRTCVideoCodec.vp9.rtcName
        })
        #expect(supportedFactory.supportedCodecs().contains {
            $0.name == WebRTCVideoCodec.av1.rtcName
        })
        #expect(supportedFactory.createEncoder(
            RTCVideoCodecInfo(name: WebRTCVideoCodec.vp9.rtcName)
        ) != nil)
        #expect(supportedFactory.createEncoder(RTCVideoCodecInfo(
            name: WebRTCVideoCodec.vp9.rtcName,
            parameters: ["profile-id": "2"]
        )) == nil)
        #expect(supportedFactory.createEncoder(
            RTCVideoCodecInfo(name: WebRTCVideoCodec.av1.rtcName)
        ) != nil)
        #expect(supportedFactory.createEncoder(
            RTCVideoCodecInfo(name: WebRTCVideoCodec.vp8.rtcName)
        ) != nil)
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
        #expect(!offer.sdp.contains(" VP9/90000"))
        #expect(!offer.sdp.contains(" AV1/90000"))
        for slot in host.slotSnapshots {
            #expect(offer.sdp.contains("\(slot.streamID) \(slot.trackID)"))
        }
    }

    @Test(
        "optional software codec offers prefer the selection and retain VP8 fallback",
        arguments: [WebRTCVideoCodec.vp9, .av1]
    )
    func optionalSoftwareCodecOfferShape(codec: WebRTCVideoCodec) async throws {
        let isSupported = switch codec {
        case .vp9: RTCVideoEncoderVP9.isSupported()
        case .av1: RTCVideoEncoderAV1.isSupported()
        case .h264, .vp8: true
        }
        #expect(isSupported)
        guard isSupported else { return }

        let host = try WebRTCPeerHost(
            configuration: .init(iceServers: [], videoCodec: codec),
            eventQueue: .global()
        )
        defer { host.close() }

        let offer = try await host.createOffer(for: "\(codec.rawValue)-viewer")
        #expect(Self.occurrences(of: "m=video", in: offer.sdp) == 4)
        let selected = try #require(offer.sdp.range(
            of: " \(codec.rtcName)/90000",
            options: .caseInsensitive
        ))
        let fallback = try #require(offer.sdp.range(of: " VP8/90000"))
        #expect(selected.lowerBound < fallback.lowerBound)
        #expect(!offer.sdp.contains(" H264/90000"))
        if codec == .vp9 {
            #expect(offer.sdp.contains("profile-id=0"))
            #expect(!offer.sdp.contains("profile-id=2"))
        } else {
            let vp9Fallback = try #require(offer.sdp.range(of: " VP9/90000"))
            #expect(selected.lowerBound < vp9Fallback.lowerBound)
            #expect(vp9Fallback.lowerBound < fallback.lowerBound)
            #expect(offer.sdp.contains("level-idx=5"))
            #expect(offer.sdp.contains("profile=0"))
            #expect(offer.sdp.contains("tier=0"))
            #expect(offer.sdp.contains(
                "http://www.webrtc.org/experiments/rtp-hdrext/color-space"
            ))
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
        try WebRTCICECandidate(
            candidate: "candidate:3 1 udp 1 192.0.2.1 41001 typ host",
            sdpMid: "5",
            sdpMLineIndex: 5
        ).validate(resourceLimits: limits)
        #expect(throws: WebRTCICECandidateValidationError.invalidMediaLineIndex(6)) {
            try WebRTCICECandidate(
                candidate: "candidate:1 1 udp 1 192.0.2.1 41000 typ host",
                sdpMid: "6",
                sdpMLineIndex: 6
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
        #expect(normalized.maximumControlMessagePayloadBytes == 196_400)
        #expect(normalized.maximumControlBufferedAmountBytes == 196_400)
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
                maximumViewerCount: 2,
                answerTimeout: 15,
                maximumICECandidatesPerPeer: 1,
                maximumICECandidatePayloadBytes: 1_024,
                maximumViewerIDBytes: 32
            )
        )
        let host = try WebRTCPeerHost(configuration: configuration, eventQueue: .global())
        defer { host.close() }
        _ = try await host.createOffer(for: "healthy-viewer")
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
        #expect(host.viewerIDs == ["healthy-viewer"])

        let malformed = WebRTCICECandidate(
            candidate: "not-an-ice-candidate",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        await #expect(throws: WebRTCPeerHostError.invalidICECandidate(
            WebRTCICECandidateValidationError.malformedCandidate.localizedDescription
        )) {
            _ = try await host.createOffer(for: "viewer-1")
            try await host.addRemoteICECandidate(malformed, for: "viewer-1")
        }
        #expect(host.viewerIDs == ["healthy-viewer"])
        _ = try await host.createReoffer(for: "healthy-viewer")
    }

    @Test("remote session descriptions have a hard allocation bound")
    func remoteSessionDescriptionLimit() async throws {
        let configuration = WebRTCPeerHostConfiguration(
            iceServers: [],
            resourceLimits: .init(
                maximumViewerCount: 2,
                answerTimeout: 15,
                maximumICECandidatesPerPeer: 8,
                maximumICECandidatePayloadBytes: 1_024,
                maximumViewerIDBytes: 32,
                maximumSDPPayloadBytes: 4_096
            )
        )
        let host = try WebRTCPeerHost(configuration: configuration, eventQueue: .global())
        defer { host.close() }
        _ = try await host.createOffer(for: "healthy-viewer")
        _ = try await host.createOffer(for: "viewer-1")

        await #expect(throws: WebRTCPeerHostError.sessionDescriptionPayloadTooLarge(
            maximumBytes: 4_096
        )) {
            try await host.setRemoteAnswer(
                .init(kind: .answer, sdp: String(repeating: "x", count: 4_097)),
                for: "viewer-1"
            )
        }
        #expect(host.viewerIDs == ["healthy-viewer"])
        _ = try await host.createReoffer(for: "healthy-viewer")
    }

    @Test("oversized remote control data removes only the sending peer")
    func remoteControlPayloadIsolation() async throws {
        let configuration = WebRTCPeerHostConfiguration(
            iceServers: [],
            resourceLimits: .init(
                maximumViewerCount: 2,
                answerTimeout: 15,
                maximumICECandidatesPerPeer: 8,
                maximumICECandidatePayloadBytes: 1_024,
                maximumViewerIDBytes: 32,
                maximumSDPPayloadBytes: 4_096,
                maximumControlMessagePayloadBytes: 1_024
            )
        )
        let host = try WebRTCPeerHost(configuration: configuration, eventQueue: .global())
        defer { host.close() }
        _ = try await host.createOffer(for: "healthy-viewer")
        _ = try await host.createOffer(for: "hostile-viewer")

        host.receiveRemoteControlMessage(
            Data(repeating: 0x41, count: 1_025),
            from: "hostile-viewer"
        )

        #expect(host.viewerIDs == ["healthy-viewer"])
        _ = try await host.createReoffer(for: "healthy-viewer")
    }

    @Test("closed hosts reject new work and close is idempotent")
    func idempotentClose() async throws {
        let host = try WebRTCPeerHost(eventQueue: .global())
        let metadata = Self.metadata(for: host.slotSnapshots[0])
        host.close()
        host.close()

        await #expect(throws: WebRTCPeerHostError.hostClosed) {
            try await host.createOffer(for: "late-viewer")
        }
        #expect(throws: WebRTCPeerHostError.hostClosed) {
            try host.activateSlot(0, metadata: metadata)
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
        #expect(WebRTCPeerHostConfiguration.clipDefault.senderPolicy == .clipDefault)
        #expect(WebRTCSenderPolicy.clipDefault.maintainsResolution)
        #expect(WebRTCSenderPolicy.clipDefault.degradationStrategy == .resolution)
        #expect(WebRTCSenderPolicy.clipDefault.minimumBitrateBps == nil)
        #expect(WebRTCSenderPolicy.clipDefault.temporalLayerCount == nil)
        #expect(WebRTCSenderPolicy.clipDefault.resolutionScale == 1)
        #expect(WebRTCSenderPolicy.clipDefault.bitratePriority == 1)
        #expect(WebRTCSenderPolicy.clipDefault.maximumFramesPerSecond == 30)
        #expect(WebRTCSenderPolicy.clipDefault.maximumBitrateBps == 12_000_000)
        #expect(WebRTCPeerHostConfiguration.clipDefault.iceServers.count == 3)
        #expect(WebRTCPeerHostConfiguration.clipDefault.resourceLimits == .clipDefault)
        #expect(WebRTCPeerResourceLimits.clipDefault.maximumViewerCount == 8)
        #expect(WebRTCPeerResourceLimits.clipDefault.answerTimeout == 15)
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
        #expect(hardMaximums.maximumControlMessagePayloadBytes == 196_400)
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
        #expect(custom.advancedVideoConfigurations == .clipDefault)

        let host = try WebRTCPeerHost(configuration: custom, eventQueue: .global())
        defer { host.close() }
        #expect(host.videoEncodingMode == .performance)
        host.updateVideoEncodingMode(.quality)
        #expect(host.videoEncodingMode == .quality)
        let h264Advanced = WebRTCH264AdvancedConfiguration(
            maximumQuantizer: 35,
            qualityFraction: 0.95,
            keyFrameIntervalSeconds: 4
        )
        host.updateAdvancedVideoConfiguration(.h264(h264Advanced))
        #expect(host.advancedVideoConfigurations.h264 == h264Advanced)
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

    private static func metadata(
        for slot: WebRTCStreamSlotSnapshot
    ) -> ClipLiveShareStreamDescriptor {
        ClipLiveShareWebRTCTestFixtures.streamDescriptor(
            for: slot,
            focused: slot.index == 0,
            appName: "Tests"
        )
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
}
