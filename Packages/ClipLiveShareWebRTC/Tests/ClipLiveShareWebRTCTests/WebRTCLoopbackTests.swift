import ClipCapture
import ClipLiveShare
import CoreMedia
import CoreVideo
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import ClipLiveShareWebRTC

extension NativeMediaResourceTests {
@Suite("Native WebRTC loopback", .serialized)
struct WebRTCLoopbackTests {
    @Test("idle peer renegotiates H264 to VP8 without replacing transports")
    func idleCodecRenegotiation() async throws {
        let bridge = LoopbackBridge()
        let host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                resourceLimits: .init(answerTimeout: 5),
                videoCodec: .h264
            ),
            eventQueue: bridge.eventQueue,
            eventHandler: { event in bridge.receive(hostEvent: event) }
        )
        bridge.host = host
        defer { host.close() }

        let initialOffer = try await host.createOffer(for: "loopback-viewer")
        let receiver = try LoopbackReceiver(bridge: bridge)
        defer { receiver.close() }
        bridge.receiver = receiver.connection
        let initialAnswer = try await receiver.answer(offer: initialOffer.sdp)
        bridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(initialAnswer, for: "loopback-viewer")
        bridge.hostCanAcceptCandidates()
        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.isConnectedAndControlOpen
        })

        let switchToVP8 = Task { try await host.updateVideoCodec(.vp8) }
        #expect(await waitUntil(timeout: .seconds(2)) { host.videoCodec == .vp8 })
        let offer = try await host.createReoffer(for: "loopback-viewer")
        #expect(offer.sdp.contains(" VP8/90000"))
        let answer = try await receiver.answer(offer: offer.sdp)
        try await host.setRemoteAnswer(answer, for: "loopback-viewer")
        try await switchToVP8.value

        #expect(host.videoCodec == .vp8)
        #expect(host.viewerIDs == ["loopback-viewer"])
        #expect(bridge.controlChannelLabel == WebRTCRuntimeIdentity.controlDataChannelLabel)
    }

    @Test("viewer joining during codec switch is included in the transaction")
    func viewerJoinsDuringCodecSwitch() async throws {
        let firstBridge = LoopbackBridge(viewerID: "viewer-a")
        let joiningBridge = LoopbackBridge(viewerID: "viewer-b")
        let completion = CodecSwitchCompletionProbe()
        let host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                resourceLimits: .init(answerTimeout: 5),
                videoCodec: .h264
            ),
            eventQueue: firstBridge.eventQueue,
            eventHandler: { event in
                firstBridge.receive(hostEvent: event)
                joiningBridge.receive(hostEvent: event)
            }
        )
        firstBridge.host = host
        joiningBridge.host = host
        defer { host.close() }

        let firstReceiver = try LoopbackReceiver(bridge: firstBridge)
        defer { firstReceiver.close() }
        firstBridge.receiver = firstReceiver.connection
        let initialOffer = try await host.createOffer(for: "viewer-a")
        let initialAnswer = try await firstReceiver.answer(offer: initialOffer.sdp)
        firstBridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(initialAnswer, for: "viewer-a")
        firstBridge.hostCanAcceptCandidates()
        #expect(await waitUntil(timeout: .seconds(5)) {
            firstBridge.isConnectedAndControlOpen
        })

        let switchTask = Task {
            do {
                try await host.updateVideoCodec(.vp8)
                await completion.finished()
            } catch {
                await completion.finished(error: error.localizedDescription)
                throw error
            }
        }
        #expect(await waitUntil(timeout: .seconds(2)) { host.videoCodec == .vp8 })
        let firstReoffer = try await host.createReoffer(for: "viewer-a")
        #expect(firstReoffer.sdp.contains(" VP8/90000"))

        // This peer did not exist when updateVideoCodec began. Its initial
        // target-codec answer must nevertheless be part of the transaction.
        let joiningReceiver = try LoopbackReceiver(bridge: joiningBridge)
        defer { joiningReceiver.close() }
        joiningBridge.receiver = joiningReceiver.connection
        let joiningOffer = try await host.createOffer(for: "viewer-b")
        #expect(joiningOffer.sdp.contains(" VP8/90000"))
        let joiningAnswer = try await joiningReceiver.answer(offer: joiningOffer.sdp)
        joiningBridge.receiverCanAcceptCandidates()

        try await host.setRemoteAnswer(
            try await firstReceiver.answer(offer: firstReoffer.sdp),
            for: "viewer-a"
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(!(await completion.isFinished))

        try await host.setRemoteAnswer(joiningAnswer, for: "viewer-b")
        joiningBridge.hostCanAcceptCandidates()
        try await switchTask.value

        #expect(await completion.errorDescription == nil)
        #expect(host.videoCodec == .vp8)
        #expect(host.viewerIDs == ["viewer-a", "viewer-b"])
        #expect(await waitUntil(timeout: .seconds(5)) {
            joiningBridge.isConnectedAndControlOpen
        })
    }

    @Test("failed codec switch rolls back an in-flight peer before reoffering")
    func codecSwitchRollbackReoffersNegotiatingPeer() async throws {
        let firstBridge = LoopbackBridge(viewerID: "viewer-a")
        let secondBridge = LoopbackBridge(viewerID: "viewer-b")
        let host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                resourceLimits: .init(answerTimeout: 5),
                videoCodec: .h264
            ),
            eventQueue: firstBridge.eventQueue,
            eventHandler: { event in
                firstBridge.receive(hostEvent: event)
                secondBridge.receive(hostEvent: event)
            }
        )
        firstBridge.host = host
        secondBridge.host = host
        defer { host.close() }

        let firstReceiver = try LoopbackReceiver(bridge: firstBridge)
        defer { firstReceiver.close() }
        firstBridge.receiver = firstReceiver.connection
        let firstInitialOffer = try await host.createOffer(for: "viewer-a")
        let firstInitialAnswer = try await firstReceiver.answer(
            offer: firstInitialOffer.sdp
        )
        firstBridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(firstInitialAnswer, for: "viewer-a")
        firstBridge.hostCanAcceptCandidates()

        let secondReceiver = try LoopbackReceiver(bridge: secondBridge)
        defer { secondReceiver.close() }
        secondBridge.receiver = secondReceiver.connection
        let secondInitialOffer = try await host.createOffer(for: "viewer-b")
        let secondInitialAnswer = try await secondReceiver.answer(
            offer: secondInitialOffer.sdp
        )
        secondBridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(secondInitialAnswer, for: "viewer-b")
        secondBridge.hostCanAcceptCandidates()
        #expect(await waitUntil(timeout: .seconds(5)) {
            firstBridge.isConnectedAndControlOpen
                && secondBridge.isConnectedAndControlOpen
        })

        let switchTask = Task { try await host.updateVideoCodec(.vp8) }
        #expect(await waitUntil(timeout: .seconds(2)) { host.videoCodec == .vp8 })
        let firstReoffer = try await host.createReoffer(for: "viewer-a")
        let secondReoffer = try await host.createReoffer(for: "viewer-b")
        #expect(firstReoffer.sdp.contains(" VP8/90000"))
        #expect(secondReoffer.sdp.contains(" VP8/90000"))
        try await Task.sleep(for: .milliseconds(100))
        secondBridge.resetNegotiationNeededCount()

        // A malformed answer makes viewer-a fail the codec-switch transaction.
        // viewer-b is deliberately left in have-local-offer to exercise the
        // SDP rollback path before its restoration reoffer.
        do {
            try await host.setRemoteAnswer(
                .init(kind: .answer, sdp: "not a valid session description"),
                for: "viewer-a"
            )
            Issue.record("The malformed codec answer unexpectedly succeeded")
        } catch {}
        do {
            try await switchTask.value
            Issue.record("The transactional codec switch unexpectedly succeeded")
        } catch {}

        #expect(host.videoCodec == .h264)
        await #expect(throws: WebRTCPeerHostError.videoCodecSwitchInProgress(
            from: .vp8,
            to: .h264
        )) {
            try await host.updateVideoCodec(.vp8)
        }
        #expect(await waitUntil(timeout: .seconds(2)) {
            secondBridge.negotiationNeededCount > 0
        })
        let restoredOffer = try await host.createReoffer(for: "viewer-b")
        #expect(restoredOffer.sdp.contains(" H264/90000"))
        #expect(!restoredOffer.sdp.contains(" VP8/90000"))
        try await host.setRemoteAnswer(
            try await secondReceiver.answer(offer: restoredOffer.sdp),
            for: "viewer-b"
        )
        host.removePeer("viewer-a")

        #expect(host.viewerIDs == ["viewer-b"])
        #expect(secondBridge.isConnectedAndControlOpen)

        // Both restoration answers/departures have now completed, so a fresh
        // transaction can start and finish normally on the surviving peer.
        let retrySwitch = Task { try await host.updateVideoCodec(.vp8) }
        #expect(await waitUntil(timeout: .seconds(2)) { host.videoCodec == .vp8 })
        let retryOffer = try await host.createReoffer(for: "viewer-b")
        #expect(retryOffer.sdp.contains(" VP8/90000"))
        try await host.setRemoteAnswer(
            try await secondReceiver.answer(offer: retryOffer.sdp),
            for: "viewer-b"
        )
        try await retrySwitch.value
        #expect(host.videoCodec == .vp8)
    }

    @Test("VP8 screensharing encoder delivers captured pixel buffers")
    func vp8FrameLoopback() async throws {
        let bridge = LoopbackBridge()
        let host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                senderPolicy: .init(
                    maximumBitrateBps: 2_000_000,
                    maximumFramesPerSecond: 30,
                    maintainsResolution: true
                ),
                resourceLimits: .init(answerTimeout: 5),
                videoCodec: .vp8
            ),
            eventQueue: bridge.eventQueue,
            eventHandler: { event in bridge.receive(hostEvent: event) }
        )
        bridge.host = host
        defer { host.close() }

        let offer = try await host.createOffer(for: "loopback-viewer")
        let receiver = try LoopbackReceiver(bridge: bridge)
        defer { receiver.close() }
        bridge.receiver = receiver.connection
        let answer = try await receiver.answer(offer: offer.sdp)
        bridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(answer, for: "loopback-viewer")
        bridge.hostCanAcceptCandidates()
        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.isConnectedAndControlOpen
        })

        try host.activateSlot(0, metadata: GoPeepV1StreamInfo(
            trackID: "video0",
            windowName: "VP8 fixture",
            appName: "Clip tests",
            isFocused: true,
            width: 320,
            height: 180
        ))
        for index in 0 ..< 45 {
            #expect(host.send(
                try makeFixtureFrame(index: index, width: 320, height: 180),
                toSlot: 0
            ) == .accepted)
            try await Task.sleep(for: .milliseconds(12))
        }
        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.receivedVideoFrameCount > 0
        })
        #expect(bridge.receivedVideoSize == .init(width: 320, height: 180))
        let outbound = try await host.outboundSenderStatisticsSnapshot()
        let slot = try #require(outbound[slot: 0])
        #expect(slot.bytesSent > 0)
        #expect(slot.framesEncoded > 0)
        #expect(slot.framesSent > 0)
    }

    @Test(
        "VP9 and AV1 screensharing encoders deliver captured pixel buffers",
        arguments: [WebRTCVideoCodec.vp9, .av1]
    )
    func optionalSoftwareCodecFrameLoopback(codec: WebRTCVideoCodec) async throws {
        try await assertSoftwareCodecFrameLoopback(
            preferredCodec: codec,
            decoderFactory: RTCDefaultVideoDecoderFactory(),
            expectedCodecName: codec.rtcName
        )
    }

    @Test(
        "VP9 and AV1 fall back to VP8 for a VP8-only viewer",
        arguments: [WebRTCVideoCodec.vp9, .av1]
    )
    func optionalSoftwareCodecVP8Fallback(codec: WebRTCVideoCodec) async throws {
        try await assertSoftwareCodecFrameLoopback(
            preferredCodec: codec,
            decoderFactory: VP8OnlyVideoDecoderFactory(),
            expectedCodecName: WebRTCVideoCodec.vp8.rtcName
        )
    }

    @Test(
        "VP9 and AV1 serve capable and VP8-only viewers simultaneously",
        arguments: [WebRTCVideoCodec.vp9, .av1]
    )
    func optionalSoftwareCodecMixedViewerLoopback(
        codec: WebRTCVideoCodec
    ) async throws {
        let capableViewerID = "preferred-codec-viewer"
        let fallbackViewerID = "vp8-only-viewer"
        let viewerIDs = [capableViewerID, fallbackViewerID]
        let capableBridge = LoopbackBridge(viewerID: capableViewerID)
        let fallbackBridge = LoopbackBridge(viewerID: fallbackViewerID)
        let host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                senderPolicy: .init(
                    maximumBitrateBps: 2_000_000,
                    maximumFramesPerSecond: 30,
                    maintainsResolution: true
                ),
                resourceLimits: .init(answerTimeout: 5),
                videoCodec: codec
            ),
            eventQueue: capableBridge.eventQueue,
            eventHandler: { event in
                capableBridge.receive(hostEvent: event)
                fallbackBridge.receive(hostEvent: event)
            }
        )
        capableBridge.host = host
        fallbackBridge.host = host
        defer { host.close() }

        let initialSlot = try #require(host.slotSnapshots.first)
        let stableTrackID = initialSlot.trackID
        let stableStreamID = initialSlot.streamID
        #expect(stableTrackID == "video0")
        #expect(stableStreamID == "gopeep-stream-0")

        let capableOffer = try await host.createOffer(for: capableViewerID)
        #expect(capableOffer.sdp.localizedCaseInsensitiveContains(
            " \(codec.rtcName)/90000"
        ))
        #expect(capableOffer.sdp.contains(" VP8/90000"))
        let capableReceiver = try LoopbackReceiver(bridge: capableBridge)
        defer { capableReceiver.close() }
        capableBridge.receiver = capableReceiver.connection
        let capableAnswer = try await capableReceiver.answer(offer: capableOffer.sdp)
        #expect(capableAnswer.sdp.localizedCaseInsensitiveContains(
            " \(codec.rtcName)/90000"
        ))
        capableBridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(capableAnswer, for: capableViewerID)
        capableBridge.hostCanAcceptCandidates()

        let fallbackOffer = try await host.createOffer(for: fallbackViewerID)
        #expect(fallbackOffer.sdp.localizedCaseInsensitiveContains(
            " \(codec.rtcName)/90000"
        ))
        #expect(fallbackOffer.sdp.contains(" VP8/90000"))
        let fallbackReceiver = try LoopbackReceiver(
            bridge: fallbackBridge,
            decoderFactory: VP8OnlyVideoDecoderFactory()
        )
        defer { fallbackReceiver.close() }
        fallbackBridge.receiver = fallbackReceiver.connection
        let fallbackAnswer = try await fallbackReceiver.answer(offer: fallbackOffer.sdp)
        #expect(fallbackAnswer.sdp.contains(" VP8/90000"))
        #expect(!fallbackAnswer.sdp.localizedCaseInsensitiveContains(
            " \(codec.rtcName)/90000"
        ))
        fallbackBridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(fallbackAnswer, for: fallbackViewerID)
        fallbackBridge.hostCanAcceptCandidates()

        #expect(await waitUntil(timeout: .seconds(5)) {
            capableBridge.isConnectedAndControlOpen
                && fallbackBridge.isConnectedAndControlOpen
        })
        #expect(host.viewerIDs == viewerIDs)
        #expect(host.viewerSnapshots.map(\.viewerID) == viewerIDs)
        #expect(host.connectedViewerCount == 2)
        #expect(
            capableBridge.controlChannelLabel
                == WebRTCRuntimeIdentity.controlDataChannelLabel
        )
        #expect(
            fallbackBridge.controlChannelLabel
                == WebRTCRuntimeIdentity.controlDataChannelLabel
        )

        let control = Data(#"{"type":"mixed-codec-loopback"}"#.utf8)
        let delivery = host.broadcastControl(control)
        #expect(delivery.deliveredViewerIDs == viewerIDs)
        #expect(delivery.unavailableViewerIDs.isEmpty)
        #expect(await waitUntil(timeout: .seconds(2)) {
            capableBridge.lastControlMessage == control
                && fallbackBridge.lastControlMessage == control
        })

        try host.activateSlot(0, metadata: GoPeepV1StreamInfo(
            trackID: stableTrackID,
            windowName: "\(codec.rtcName) mixed-viewer fixture",
            appName: "Clip tests",
            isFocused: true,
            width: 320,
            height: 180
        ))
        for index in 0 ..< 60 {
            #expect(host.send(
                try makeFixtureFrame(index: index, width: 320, height: 180),
                toSlot: 0
            ) == .accepted)
            try await Task.sleep(for: .milliseconds(12))
        }
        #expect(await waitUntil(timeout: .seconds(8)) {
            capableBridge.receivedVideoFrameCount > 0
                && fallbackBridge.receivedVideoFrameCount > 0
        })
        let capableFrames = capableBridge.receivedVideoFrameCount
        let fallbackFrames = fallbackBridge.receivedVideoFrameCount

        for index in 60 ..< 120 {
            #expect(host.send(
                try makeFixtureFrame(index: index, width: 320, height: 180),
                toSlot: 0
            ) == .accepted)
            try await Task.sleep(for: .milliseconds(12))
        }
        #expect(await waitUntil(timeout: .seconds(8)) {
            capableBridge.receivedVideoFrameCount > capableFrames
                && fallbackBridge.receivedVideoFrameCount > fallbackFrames
        })
        #expect(capableBridge.receivedVideoSize == .init(width: 320, height: 180))
        #expect(fallbackBridge.receivedVideoSize == .init(width: 320, height: 180))

        var outbound = try await host.outboundSenderStatisticsSnapshot()
        let clock = ContinuousClock()
        let statisticsDeadline = clock.now.advanced(by: .seconds(3))
        while clock.now < statisticsDeadline {
            let outboundCodecs = Set(
                outbound[slot: 0]?.viewers.compactMap(\.codec).map {
                    $0.uppercased()
                } ?? []
            )
            if outboundCodecs == Set([codec.rtcName, WebRTCVideoCodec.vp8.rtcName]) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
            outbound = try await host.outboundSenderStatisticsSnapshot()
        }

        let slot = try #require(outbound[slot: 0])
        let codecsByViewer = Dictionary(uniqueKeysWithValues: slot.viewers.compactMap {
            viewer in
            viewer.codec.map { (viewer.viewerID, $0.uppercased()) }
        })
        #expect(outbound.viewerCount == 2)
        #expect(outbound.connectedViewerCount == 2)
        #expect(slot.trackID == stableTrackID)
        #expect(slot.viewers.map(\.viewerID) == viewerIDs)
        #expect(Set(slot.codecs.map { $0.uppercased() }) == Set([
            codec.rtcName,
            WebRTCVideoCodec.vp8.rtcName,
        ]))
        #expect(codecsByViewer[capableViewerID] == codec.rtcName)
        #expect(codecsByViewer[fallbackViewerID] == WebRTCVideoCodec.vp8.rtcName)
        #expect(slot.viewers.allSatisfy { $0.framesSent > 0 })
        #expect(slot.viewers.allSatisfy { $0.framesEncoded > 0 })

        let finalSlot = try #require(host.slotSnapshots.first)
        #expect(host.viewerIDs == viewerIDs)
        #expect(finalSlot.trackID == stableTrackID)
        #expect(finalSlot.streamID == stableStreamID)
        #expect(finalSlot.metadata?.trackID == stableTrackID)
        #expect(
            capableBridge.controlChannelLabel
                == WebRTCRuntimeIdentity.controlDataChannelLabel
        )
        #expect(
            fallbackBridge.controlChannelLabel
                == WebRTCRuntimeIdentity.controlDataChannelLabel
        )
    }

    private func assertSoftwareCodecFrameLoopback(
        preferredCodec: WebRTCVideoCodec,
        decoderFactory: any RTCVideoDecoderFactory,
        expectedCodecName: String
    ) async throws {
        let bridge = LoopbackBridge()
        let host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                senderPolicy: .init(
                    maximumBitrateBps: 2_000_000,
                    maximumFramesPerSecond: 30,
                    maintainsResolution: true
                ),
                resourceLimits: .init(answerTimeout: 5),
                videoCodec: preferredCodec
            ),
            eventQueue: bridge.eventQueue,
            eventHandler: { event in bridge.receive(hostEvent: event) }
        )
        bridge.host = host
        defer { host.close() }

        let offer = try await host.createOffer(for: "loopback-viewer")
        #expect(offer.sdp.localizedCaseInsensitiveContains(
            " \(preferredCodec.rtcName)/90000"
        ))
        #expect(offer.sdp.contains(" VP8/90000"))
        #expect(!offer.sdp.contains(" H264/90000"))
        let receiver = try LoopbackReceiver(
            bridge: bridge,
            decoderFactory: decoderFactory
        )
        defer { receiver.close() }
        bridge.receiver = receiver.connection
        let answer = try await receiver.answer(offer: offer.sdp)
        #expect(answer.sdp.localizedCaseInsensitiveContains(
            " \(expectedCodecName)/90000"
        ))
        if expectedCodecName == WebRTCVideoCodec.vp8.rtcName {
            #expect(!answer.sdp.localizedCaseInsensitiveContains(
                " \(preferredCodec.rtcName)/90000"
            ))
        }
        bridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(answer, for: "loopback-viewer")
        bridge.hostCanAcceptCandidates()
        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.isConnectedAndControlOpen
        })

        try host.activateSlot(0, metadata: GoPeepV1StreamInfo(
            trackID: "video0",
            windowName: "\(preferredCodec.rtcName) fixture",
            appName: "Clip tests",
            isFocused: true,
            width: 320,
            height: 180
        ))
        for index in 0 ..< 60 {
            #expect(host.send(
                try makeFixtureFrame(index: index, width: 320, height: 180),
                toSlot: 0
            ) == .accepted)
            try await Task.sleep(for: .milliseconds(12))
        }
        #expect(await waitUntil(timeout: .seconds(8)) {
            bridge.receivedVideoFrameCount > 0
        })
        #expect(bridge.receivedVideoSize == .init(width: 320, height: 180))
        let outbound = try await host.outboundSenderStatisticsSnapshot()
        let slot = try #require(outbound[slot: 0])
        #expect(slot.bytesSent > 0)
        #expect(slot.framesEncoded > 0)
        #expect(slot.framesSent > 0)
        #expect(slot.codecs.contains(expectedCodecName))
    }

    @Test("native Retina-sized windows encode and render at source resolution")
    func nativeResolutionLoopback() async throws {
        for size in [
            CGSize(width: 1_258, height: 934),
            CGSize(width: 1_280, height: 1_202),
            CGSize(width: 2_762, height: 1_202),
        ] {
            try await assertNativeResolution(size)
        }
    }

    @Test(
        "VP9 and AV1 preserve a Retina-sized source",
        arguments: [WebRTCVideoCodec.vp9, .av1]
    )
    func optionalCodecNativeResolution(codec: WebRTCVideoCodec) async throws {
        try await assertNativeResolution(
            CGSize(width: 2_762, height: 1_202),
            codec: codec,
            frameCount: 20
        )
    }

    @Test("host negotiates, sends control data, and delivers a captured pixel buffer")
    func nativeLoopback() async throws {
        let bridge = LoopbackBridge()
        let host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                senderPolicy: .init(
                    maximumBitrateBps: 2_000_000,
                    maximumFramesPerSecond: 30,
                    maintainsResolution: true
                ),
                resourceLimits: .init(answerTimeout: 0.05)
            ),
            eventQueue: bridge.eventQueue,
            eventHandler: { event in bridge.receive(hostEvent: event) }
        )
        bridge.host = host
        defer { host.close() }

        let offer = try await host.createOffer(for: "loopback-viewer")
        let receiver = try LoopbackReceiver(bridge: bridge)
        defer { receiver.close() }
        bridge.receiver = receiver.connection

        let answer = try await receiver.answer(offer: offer.sdp)
        bridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(answer, for: "loopback-viewer")
        bridge.hostCanAcceptCandidates()
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.viewerIDs == ["loopback-viewer"])

        let connected = await waitUntil(timeout: .seconds(5)) {
            bridge.isConnectedAndControlOpen
        }
        #expect(connected)
        #expect(host.connectedViewerCount == 1)
        #expect(host.viewerSnapshots.first?.isConnected == true)
        #expect(bridge.controlChannelLabel == WebRTCRuntimeIdentity.controlDataChannelLabel)
        #expect(bridge.controlChannelIsOrdered)

        let control = Data(#"{"type":"sharer-started"}"#.utf8)
        let delivery = host.broadcastControl(control)
        #expect(delivery.deliveredViewerIDs == ["loopback-viewer"])
        #expect(delivery.unavailableViewerIDs.isEmpty)
        #expect(await waitUntil(timeout: .seconds(2)) {
            bridge.lastControlMessage == control
        })

        try host.activateSlot(0, metadata: GoPeepV1StreamInfo(
            trackID: "video0",
            windowName: "Deterministic fixture",
            appName: "Clip tests",
            isFocused: true,
            width: 320,
            height: 180
        ))
        let baselineStatistics = try await host.outboundSenderStatisticsSnapshot()
        #expect(baselineStatistics.viewerCount == 1)
        #expect(baselineStatistics[slot: 0]?.aggregateBitrateBps == nil)
        // Real application windows commonly have odd native dimensions. The
        // bundled H.264 path crops only the final unmatched row/column.
        for index in 0 ..< 45 {
            let frame = try makeFixtureFrame(index: index, width: 321, height: 181)
            #expect(host.send(frame, toSlot: 0) == .accepted)
            try await Task.sleep(for: .milliseconds(12))
        }

        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.receivedVideoFrameCount > 0
        })
        #expect(bridge.receivedVideoSize == .init(width: 320, height: 180))

        let outbound = try await host.outboundSenderStatisticsSnapshot()
        let slot = try #require(outbound[slot: 0])
        #expect(slot.bytesSent > 0)
        #expect(slot.packetsSent > 0)
        #expect(slot.framesSent > 0)
        #expect(slot.framesEncoded > 0)
        #expect((slot.aggregateBitrateBps ?? 0) > 0)
        #expect((slot.averageFramesPerSecond ?? 0) > 0)
        #expect(slot.viewers.count == 1)
    }

    @Test("active peer switches every codec without replacing its tracks")
    func liveCodecSwitchLoopback() async throws {
        let bridge = LoopbackBridge()
        let host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                senderPolicy: .init(
                    maximumBitrateBps: 4_000_000,
                    maximumFramesPerSecond: 30,
                    maintainsResolution: true
                ),
                resourceLimits: .init(answerTimeout: 5),
                videoCodec: .h264
            ),
            eventQueue: bridge.eventQueue,
            eventHandler: { event in bridge.receive(hostEvent: event) }
        )
        bridge.host = host
        defer { host.close() }

        let initialOffer = try await host.createOffer(for: "loopback-viewer")
        #expect(initialOffer.sdp.contains(" H264/90000"))
        #expect(!initialOffer.sdp.contains(" VP8/90000"))
        let receiver = try LoopbackReceiver(bridge: bridge)
        defer { receiver.close() }
        bridge.receiver = receiver.connection
        let initialAnswer = try await receiver.answer(offer: initialOffer.sdp)
        bridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(initialAnswer, for: "loopback-viewer")
        bridge.hostCanAcceptCandidates()
        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.isConnectedAndControlOpen
        })

        try host.activateSlot(0, metadata: GoPeepV1StreamInfo(
            trackID: "video0",
            windowName: "Codec switch fixture",
            appName: "Clip tests",
            isFocused: true,
            width: 320,
            height: 180
        ))
        for index in 0 ..< 30 {
            #expect(host.send(
                try makeFixtureFrame(index: index, width: 320, height: 180),
                toSlot: 0
            ) == .accepted)
            try await Task.sleep(for: .milliseconds(12))
        }
        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.receivedVideoFrameCount > 0
        })
        let framesBeforeVP8 = bridge.receivedVideoFrameCount

        let switchToVP8 = Task { try await host.updateVideoCodec(.vp8) }
        #expect(await waitUntil(timeout: .seconds(2)) { host.videoCodec == .vp8 })
        let vp8Offer = try await host.createReoffer(for: "loopback-viewer")
        #expect(vp8Offer.sdp.contains(" VP8/90000"))
        #expect(!vp8Offer.sdp.contains(" H264/90000"))
        try await host.setRemoteAnswer(
            try await receiver.answer(offer: vp8Offer.sdp),
            for: "loopback-viewer"
        )
        try await switchToVP8.value
        #expect(host.videoCodec == .vp8)

        for index in 30 ..< 60 {
            #expect(host.send(
                try makeFixtureFrame(index: index, width: 320, height: 180),
                toSlot: 0
            ) == .accepted)
            try await Task.sleep(for: .milliseconds(12))
        }
        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.receivedVideoFrameCount > framesBeforeVP8
        })
        var nextFrameIndex = 60
        for codec in [WebRTCVideoCodec.vp9, .av1] {
            let framesBeforeSwitch = bridge.receivedVideoFrameCount
            let switchCodec = Task { try await host.updateVideoCodec(codec) }
            #expect(await waitUntil(timeout: .seconds(2)) {
                host.videoCodec == codec
            })
            let offer = try await host.createReoffer(for: "loopback-viewer")
            #expect(offer.sdp.localizedCaseInsensitiveContains(
                " \(codec.rtcName)/90000"
            ))
            #expect(offer.sdp.contains(" VP8/90000"))
            #expect(!offer.sdp.contains(" H264/90000"))
            try await host.setRemoteAnswer(
                try await receiver.answer(offer: offer.sdp),
                for: "loopback-viewer"
            )
            try await switchCodec.value
            #expect(host.videoCodec == codec)

            for index in nextFrameIndex ..< nextFrameIndex + 30 {
                #expect(host.send(
                    try makeFixtureFrame(index: index, width: 320, height: 180),
                    toSlot: 0
                ) == .accepted)
                try await Task.sleep(for: .milliseconds(12))
            }
            nextFrameIndex += 30
            #expect(await waitUntil(timeout: .seconds(8)) {
                bridge.receivedVideoFrameCount > framesBeforeSwitch
            })
        }
        let framesBeforeH264 = bridge.receivedVideoFrameCount

        let switchToH264 = Task { try await host.updateVideoCodec(.h264) }
        #expect(await waitUntil(timeout: .seconds(2)) { host.videoCodec == .h264 })
        let h264Offer = try await host.createReoffer(for: "loopback-viewer")
        #expect(h264Offer.sdp.contains(" H264/90000"))
        #expect(!h264Offer.sdp.contains(" VP8/90000"))
        #expect(h264Offer.sdp.contains("profile-level-id=640c34"))
        try await host.setRemoteAnswer(
            try await receiver.answer(offer: h264Offer.sdp),
            for: "loopback-viewer"
        )
        try await switchToH264.value
        #expect(host.videoCodec == .h264)

        for index in nextFrameIndex ..< nextFrameIndex + 30 {
            #expect(host.send(
                try makeFixtureFrame(index: index, width: 320, height: 180),
                toSlot: 0
            ) == .accepted)
            try await Task.sleep(for: .milliseconds(12))
        }
        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.receivedVideoFrameCount > framesBeforeH264
        })
        #expect(bridge.controlChannelLabel == WebRTCRuntimeIdentity.controlDataChannelLabel)
        #expect(bridge.receivedVideoSize == .init(width: 320, height: 180))
        #expect(host.viewerIDs == ["loopback-viewer"])
    }

    @Test("viewer joining an idle source receives its latest frame")
    func lateViewerFrameReplay() async throws {
        let bridge = LoopbackBridge()
        let host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                senderPolicy: .init(
                    maximumBitrateBps: 2_000_000,
                    maximumFramesPerSecond: 30,
                    maintainsResolution: true
                ),
                resourceLimits: .init(answerTimeout: 0.05)
            ),
            eventQueue: bridge.eventQueue,
            eventHandler: { event in bridge.receive(hostEvent: event) }
        )
        bridge.host = host
        defer { host.close() }

        try host.activateSlot(0, metadata: GoPeepV1StreamInfo(
            trackID: "video0",
            windowName: "Idle fixture",
            appName: "Clip tests",
            isFocused: true,
            width: 320,
            height: 180
        ))
        #expect(host.send(
            try makeFixtureFrame(index: 1, width: 320, height: 180),
            toSlot: 0
        ) == .accepted)

        let offer = try await host.createOffer(for: "loopback-viewer")
        let receiver = try LoopbackReceiver(bridge: bridge)
        defer { receiver.close() }
        bridge.receiver = receiver.connection
        let answer = try await receiver.answer(offer: offer.sdp)
        bridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(answer, for: "loopback-viewer")
        bridge.hostCanAcceptCandidates()

        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.isConnectedAndControlOpen
        })
        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.receivedVideoFrameCount > 0
        })
        #expect(bridge.receivedVideoSize == .init(width: 320, height: 180))

        let outbound = try await host.outboundSenderStatisticsSnapshot()
        let slot = try #require(outbound[slot: 0])
        #expect(slot.bytesSent > 0)
        #expect(slot.framesEncoded > 0)
        #expect(slot.framesSent > 0)
    }

    private func assertNativeResolution(
        _ size: CGSize,
        codec: WebRTCVideoCodec = .h264,
        frameCount: Int = 30
    ) async throws {
        let width = Int(size.width)
        let height = Int(size.height)
        let viewerID = "retina-\(codec.rawValue)-loopback-viewer"
        let bridge = LoopbackBridge(viewerID: viewerID)
        let host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                senderPolicy: .init(
                    maximumBitrateBps: 12_000_000,
                    maximumFramesPerSecond: 30,
                    maintainsResolution: true
                ),
                resourceLimits: .init(answerTimeout: 5),
                videoCodec: codec
            ),
            eventQueue: bridge.eventQueue,
            eventHandler: { event in bridge.receive(hostEvent: event) }
        )
        bridge.host = host
        defer { host.close() }

        let offer = try await host.createOffer(for: viewerID)
        if codec == .h264 {
            #expect(offer.sdp.contains("profile-level-id=640c34"))
        } else {
            #expect(offer.sdp.localizedCaseInsensitiveContains(
                " \(codec.rtcName)/90000"
            ))
        }
        let receiver = try LoopbackReceiver(bridge: bridge)
        defer { receiver.close() }
        bridge.receiver = receiver.connection

        let answer = try await receiver.answer(offer: offer.sdp)
        bridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(answer, for: viewerID)
        bridge.hostCanAcceptCandidates()
        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.isConnectedAndControlOpen
        })

        try host.activateSlot(0, metadata: GoPeepV1StreamInfo(
            trackID: "video0",
            windowName: "Retina fixture \(width)x\(height)",
            appName: "Clip tests",
            isFocused: true,
            width: width,
            height: height
        ))
        for index in 0 ..< frameCount {
            let frame = try makeFixtureFrame(
                index: index,
                width: width,
                height: height
            )
            #expect(host.send(frame, toSlot: 0) == .accepted)
            try await Task.sleep(for: .milliseconds(18))
        }

        #expect(await waitUntil(timeout: .seconds(8)) {
            bridge.receivedVideoFrameCount > 0
        })
        #expect(bridge.receivedVideoSize == size)
        let outbound = try await host.outboundSenderStatisticsSnapshot()
        let slot = try #require(outbound[slot: 0])
        #expect(slot.bytesSent > 0)
        #expect(slot.framesEncoded > 0)
        #expect(slot.framesSent > 0)
        #expect(slot.codecs.contains(codec.rtcName))
    }
}
}

private final class LoopbackBridge: @unchecked Sendable {
    let eventQueue = DispatchQueue(label: "com.tomaslejdung.clip.tests.webrtc-events")

    private let viewerID: String
    private let lock = NSLock()
    private weak var storedHost: WebRTCPeerHost?
    private var storedReceiver: RTCPeerConnection?
    private var pendingForHost: [WebRTCICECandidate] = []
    private var pendingForReceiver: [WebRTCICECandidate] = []
    private var hostCandidateReady = false
    private var receiverCandidateReady = false
    private var hostConnected = false
    private var receiverConnected = false
    private var hostControlOpen = false
    private var storedControlLabel: String?
    private var storedControlOrdered = false
    private var storedControlMessage: Data?
    private var storedFrameCount = 0
    private var storedVideoSize = CGSize.zero
    private var storedNegotiationNeededCount = 0

    init(viewerID: String = "loopback-viewer") {
        self.viewerID = viewerID
    }

    var host: WebRTCPeerHost? {
        get { lock.withLock { storedHost } }
        set { lock.withLock { storedHost = newValue } }
    }

    var receiver: RTCPeerConnection? {
        get { lock.withLock { storedReceiver } }
        set { lock.withLock { storedReceiver = newValue } }
    }

    var isConnectedAndControlOpen: Bool {
        lock.withLock { hostConnected && receiverConnected && hostControlOpen }
    }

    var controlChannelLabel: String? { lock.withLock { storedControlLabel } }
    var controlChannelIsOrdered: Bool { lock.withLock { storedControlOrdered } }
    var lastControlMessage: Data? { lock.withLock { storedControlMessage } }
    var receivedVideoFrameCount: Int { lock.withLock { storedFrameCount } }
    var receivedVideoSize: CGSize { lock.withLock { storedVideoSize } }
    var negotiationNeededCount: Int {
        lock.withLock { storedNegotiationNeededCount }
    }

    func resetNegotiationNeededCount() {
        lock.withLock { storedNegotiationNeededCount = 0 }
    }

    func receive(hostEvent: WebRTCPeerHostEvent) {
        switch hostEvent {
        case .localICECandidate(let eventViewerID, let candidate)
            where eventViewerID == viewerID:
            deliverToReceiver(candidate)
        case .connectionStateChanged(let eventViewerID, let state)
            where eventViewerID == viewerID:
            lock.withLock { hostConnected = state == .connected }
        case .controlDataChannelStateChanged(let eventViewerID, let state)
            where eventViewerID == viewerID:
            lock.withLock { hostControlOpen = state == .open }
        case .negotiationNeeded(let eventViewerID) where eventViewerID == viewerID:
            lock.withLock { storedNegotiationNeededCount += 1 }
        default:
            break
        }
    }

    func receive(receiverCandidate: WebRTCICECandidate) {
        let host: WebRTCPeerHost? = lock.withLock {
            guard hostCandidateReady else {
                pendingForHost.append(receiverCandidate)
                return nil
            }
            return storedHost
        }
        guard let host else { return }
        Task { try? await host.addRemoteICECandidate(receiverCandidate, for: viewerID) }
    }

    func receiverCanAcceptCandidates() {
        let pending: ([WebRTCICECandidate], RTCPeerConnection?) = lock.withLock {
            receiverCandidateReady = true
            defer { pendingForReceiver.removeAll() }
            return (pendingForReceiver, storedReceiver)
        }
        guard let receiver = pending.1 else { return }
        for candidate in pending.0 {
            add(candidate, to: receiver)
        }
    }

    func hostCanAcceptCandidates() {
        let pending: ([WebRTCICECandidate], WebRTCPeerHost?) = lock.withLock {
            hostCandidateReady = true
            defer { pendingForHost.removeAll() }
            return (pendingForHost, storedHost)
        }
        guard let host = pending.1 else { return }
        for candidate in pending.0 {
            Task { try? await host.addRemoteICECandidate(candidate, for: viewerID) }
        }
    }

    func receiverConnectionChanged(_ state: RTCPeerConnectionState) {
        lock.withLock { receiverConnected = state == .connected }
    }

    func receiverOpened(_ channel: RTCDataChannel) {
        lock.withLock {
            storedControlLabel = channel.label
            storedControlOrdered = channel.isOrdered
        }
    }

    func receiverControlMessage(_ data: Data) {
        lock.withLock { storedControlMessage = data }
    }

    func receiverRenderedFrame(size: CGSize) {
        lock.withLock {
            storedFrameCount += 1
            storedVideoSize = size
        }
    }

    private func deliverToReceiver(_ candidate: WebRTCICECandidate) {
        let receiver: RTCPeerConnection? = lock.withLock {
            guard receiverCandidateReady else {
                pendingForReceiver.append(candidate)
                return nil
            }
            return storedReceiver
        }
        guard let receiver else { return }
        add(candidate, to: receiver)
    }

    private func add(_ candidate: WebRTCICECandidate, to receiver: RTCPeerConnection) {
        receiver.add(RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )) { _ in }
    }
}

private actor CodecSwitchCompletionProbe {
    private(set) var isFinished = false
    private(set) var errorDescription: String?

    func finished(error: String? = nil) {
        isFinished = true
        errorDescription = error
    }
}

private final class VP8OnlyVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    func supportedCodecs() -> [RTCVideoCodecInfo] {
        RTCVideoDecoderVP8.supportedCodecs()
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        guard info.name.caseInsensitiveCompare(WebRTCVideoCodec.vp8.rtcName) == .orderedSame
        else { return nil }
        return RTCVideoDecoderVP8.vp8Decoder()
    }
}

private final class LoopbackReceiver: NSObject, RTCPeerConnectionDelegate,
    RTCDataChannelDelegate, RTCVideoRenderer, @unchecked Sendable
{
    private let bridge: LoopbackBridge
    private let sslLease: WebRTCSSLRuntimeLease
    private let factory: RTCPeerConnectionFactory
    let connection: RTCPeerConnection
    private var controlChannel: RTCDataChannel?
    private var videoTracks: [RTCVideoTrack] = []

    init(
        bridge: LoopbackBridge,
        decoderFactory: any RTCVideoDecoderFactory = RTCDefaultVideoDecoderFactory()
    ) throws {
        self.bridge = bridge
        sslLease = try WebRTCSSLRuntimeLease()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: decoderFactory
        )
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.iceServers = []
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let connection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: nil
        ) else {
            throw WebRTCPeerHostError.peerConnectionCreationFailed("loopback receiver")
        }
        self.connection = connection
        super.init()
        connection.delegate = self
    }

    func answer(offer: String) async throws -> WebRTCSessionDescription {
        try await setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer))
        let answer = try await createAnswer()
        try await setLocalDescription(answer)
        return .init(kind: .answer, sdp: answer.sdp)
    }

    func close() {
        connection.delegate = nil
        controlChannel?.delegate = nil
        controlChannel?.close()
        for track in videoTracks { track.remove(self) }
        videoTracks.removeAll()
        connection.close()
    }

    private func setRemoteDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func createAnswer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            )
            connection.answer(for: constraints) { description, error in
                if let error { continuation.resume(throwing: error) }
                else if let description { continuation.resume(returning: description) }
                else {
                    continuation.resume(throwing:
                        WebRTCPeerHostError.localDescriptionCreationFailed("loopback answer"))
                }
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        bridge.receive(receiverCandidate: WebRTCICECandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        ))
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {
        controlChannel = dataChannel
        dataChannel.delegate = self
        bridge.receiverOpened(dataChannel)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        bridge.receiverConnectionChanged(newState)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        guard let track = rtpReceiver.track as? RTCVideoTrack,
              track.trackId == "video0" else { return }
        videoTracks.append(track)
        track.add(self)
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    func dataChannel(
        _ dataChannel: RTCDataChannel,
        didReceiveMessageWith buffer: RTCDataBuffer
    ) {
        bridge.receiverControlMessage(buffer.data)
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        bridge.receiverRenderedFrame(size: CGSize(
            width: CGFloat(frame.width),
            height: CGFloat(frame.height)
        ))
    }
}

private func waitUntil(
    timeout: Duration,
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func makeFixtureFrame(
    index: Int,
    width: Int,
    height: Int
) throws -> BorrowedCaptureVideoFrame {
    var pixelBuffer: CVPixelBuffer?
    let attributes: CFDictionary = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    guard CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes,
        &pixelBuffer
    ) == kCVReturnSuccess,
        let pixelBuffer else {
        throw WebRTCPeerHostError.localDescriptionCreationFailed("pixel buffer")
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(base, Int32(index & 0xff), CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    var formatDescription: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    ) == noErr,
        let formatDescription else {
        throw WebRTCPeerHostError.localDescriptionCreationFailed("format description")
    }
    let presentationTime = CMTime(value: CMTimeValue(index), timescale: 30)
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    ) == noErr,
        let sampleBuffer else {
        throw WebRTCPeerHostError.localDescriptionCreationFailed("sample buffer")
    }
    return BorrowedCaptureVideoFrame(
        sampleBuffer: sampleBuffer,
        pixelBuffer: pixelBuffer,
        presentationTime: presentationTime
    )
}
