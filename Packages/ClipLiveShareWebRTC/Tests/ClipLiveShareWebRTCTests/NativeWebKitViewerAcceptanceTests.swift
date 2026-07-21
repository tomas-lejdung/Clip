import AppKit
import ClipCapture
import ClipLiveShare
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
import WebKit
@testable import ClipLiveShareWebRTC

/// A real browser-process acceptance lane for the complete Clip v1 path.
///
/// Ordinary package tests leave this dormant. The repository acceptance
/// wrapper starts the in-repository Go service and supplies its loopback root
/// URL explicitly, so this test never reaches a public deployment by default.
extension NativeMediaResourceTests {
@Suite("Clip v1 native WebKit acceptance", .serialized)
struct NativeWebKitViewerAcceptanceTests {
    @MainActor
    @Test("encrypted admission hands a live opaque stream and audio track to WebKit")
    func encryptedViewerFlow() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CLIP_RUN_NATIVE_WEBKIT_ACCEPTANCE"] == "1" else {
            return
        }
        let endpointInput = try #require(
            environment["CLIP_LIVE_SHARE_ACCEPTANCE_ENDPOINT"],
            "Set CLIP_LIVE_SHARE_ACCEPTANCE_ENDPOINT to the local server root URL."
        )
        let endpoint = try ClipLiveShareServerEndpoint(userInput: endpointInput)
        let harness = try NativeWebKitHostHarness(endpoint: endpoint)
        let viewerURL = try await harness.start()
        defer { Task { await harness.stop() } }

        let expectedVideoTrackID = await harness.videoTrackID
        let expectedAudioTrackID = await harness.systemAudioTrackID

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            configuration: configuration
        )
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        // WebKit throttles media in a detached view. Keep its real rendering
        // path active offscreen without taking focus from the developer.
        window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
        window.orderFrontRegardless()
        defer {
            webView.stopLoading()
            window.orderOut(nil)
            window.close()
        }

        webView.load(URLRequest(url: viewerURL))
        let documentLoaded = try await waitForNativeWebKitSnapshot(
            webView: webView,
            expectedVideoTrackID: expectedVideoTrackID,
            expectedAudioTrackID: expectedAudioTrackID,
            timeout: .seconds(10)
        ) { $0.readyState == "complete" }
        guard documentLoaded else {
            Issue.record("The embedded Clip viewer did not finish loading.")
            return
        }

        let controlOpen = await harness.waitUntilControlOpen(timeout: .seconds(15))
        guard controlOpen else {
            let failure = await harness.failureDescription ?? "no host-side failure"
            Issue.record(
                "The encrypted Clip v1/WebRTC flow did not open clip-control-v1: \(failure)"
            )
            return
        }
        #expect(await harness.completedEncryptedAdmission)
        // The data channel can open before the actor has consumed the final
        // trickled-candidate callback. Wait for the same strict evidence
        // instead of racing its bookkeeping immediately after control-open.
        #expect(await harness.waitUntilBidirectionalICEExchange(
            timeout: .seconds(3)
        ))
        #expect(await harness.offerContainsSystemAudioTrack)
        #expect(await harness.closedServerIntroductionRoute)
        let opusNegotiation = await harness.opusNegotiationSnapshot
        #expect(opusNegotiation.offerRtpmap.contains("opus/48000/2"))
        #expect(
            opusFmtpParameter("stereo", in: opusNegotiation.offerFmtp) == "1",
            Comment(rawValue:
                "The host offered speech-oriented mono Opus: "
                    + opusNegotiation.description)
        )
        #expect(
            opusFmtpParameter("stereo", in: opusNegotiation.answerFmtp) == "1",
            Comment(rawValue:
                "WebKit did not negotiate stereo Opus: "
                    + opusNegotiation.description)
        )
        #expect(opusFmtpParameter(
            "sprop-stereo",
            in: opusNegotiation.offerFmtp
        ) == "1")
        #expect(opusFmtpParameter(
            "sprop-stereo",
            in: opusNegotiation.answerFmtp
        ) == "1")
        #expect(opusFmtpParameter(
            "maxaveragebitrate",
            in: opusNegotiation.offerFmtp
        ) == "128000")
        #expect(opusFmtpParameter(
            "maxaveragebitrate",
            in: opusNegotiation.answerFmtp
        ) == "128000")
        #expect(opusFmtpParameter("usedtx", in: opusNegotiation.offerFmtp) == "0")
        #expect(opusFmtpParameter("usedtx", in: opusNegotiation.answerFmtp) == "0")

        // The audio transceiver is intentionally present in the initial offer,
        // but that must not imply that ScreenCaptureKit audio is active. The
        // host's explicit authoritative state owns the browser controls.
        var snapshot = try await nativeWebKitViewerSnapshot(
            webView,
            expectedVideoTrackID: expectedVideoTrackID,
            expectedAudioTrackID: expectedAudioTrackID
        )
        #expect(!snapshot.audioControlEnabled)

        try await harness.activateFixtureSlot()

        var firstDecodedFrameCount: Int?
        snapshot = try await nativeWebKitViewerSnapshot(
            webView,
            expectedVideoTrackID: expectedVideoTrackID,
            expectedAudioTrackID: expectedAudioTrackID
        )
        for index in 0..<240 {
            try await harness.sendFixtureFrame(index: index)
            try await Task.sleep(for: .milliseconds(16))

            if index.isMultiple(of: 8) {
                snapshot = try await nativeWebKitViewerSnapshot(
                    webView,
                    expectedVideoTrackID: expectedVideoTrackID,
                    expectedAudioTrackID: expectedAudioTrackID
                )
                if snapshot.decodedFrames > 0, firstDecodedFrameCount == nil {
                    firstDecodedFrameCount = snapshot.decodedFrames
                }
                if let firstDecodedFrameCount,
                   snapshot.decodedFrames >= firstDecodedFrameCount + 3,
                   snapshot.manifestTrackBound,
                   snapshot.audioTrackVisible {
                    break
                }
            }
        }

        snapshot = try await nativeWebKitViewerSnapshot(
            webView,
            expectedVideoTrackID: expectedVideoTrackID,
            expectedAudioTrackID: expectedAudioTrackID
        )
        let firstFrames = firstDecodedFrameCount ?? 0
        #expect(snapshot.statusText == "Connected")
        #expect(snapshot.manifestTrackBound)
        #expect(snapshot.videoWidth == NativeWebKitHostHarness.fixtureWidth)
        #expect(snapshot.videoHeight == NativeWebKitHostHarness.fixtureHeight)
        #expect(snapshot.decodedFrames >= firstFrames + 3)
        #expect(snapshot.audioTrackVisible)
        #expect(snapshot.audioControlEnabled)

        // Make cursor consumption externally observable. In native scale the
        // fixture is larger than the offscreen viewport, so a cursor near the
        // lower-right corner must pan the bound opaque stream.
        try await selectNativeScale(in: webView)
        try await Task.sleep(for: .milliseconds(250))
        try await harness.sendCursor(x: 96, y: 94)
        let cursorConsumed = try await waitForNativeWebKitSnapshot(
            webView: webView,
            expectedVideoTrackID: expectedVideoTrackID,
            expectedAudioTrackID: expectedAudioTrackID,
            timeout: .seconds(3)
        ) { $0.cursorTransformApplied }
        snapshot = try await nativeWebKitViewerSnapshot(
            webView,
            expectedVideoTrackID: expectedVideoTrackID,
            expectedAudioTrackID: expectedAudioTrackID
        )
        #expect(cursorConsumed)
        #expect(snapshot.manifestTrackBound)
        #expect(snapshot.cursorTransformApplied)

        try await harness.setSystemAudioSharingEnabled(false)
        let audioDisabled = try await waitForNativeWebKitSnapshot(
            webView: webView,
            expectedVideoTrackID: expectedVideoTrackID,
            expectedAudioTrackID: expectedAudioTrackID,
            timeout: .seconds(2)
        ) { !$0.audioControlEnabled }
        #expect(audioDisabled)

        try await harness.setSystemAudioSharingEnabled(true)
        let audioReenabled = try await waitForNativeWebKitSnapshot(
            webView: webView,
            expectedVideoTrackID: expectedVideoTrackID,
            expectedAudioTrackID: expectedAudioTrackID,
            timeout: .seconds(2)
        ) { $0.audioTrackVisible && $0.audioControlEnabled }
        #expect(audioReenabled)

        // Track presence and inbound byte counters cannot distinguish valid
        // music from a mono, starved, clipped, or otherwise damaged stream.
        // Analyse decoded PCM in WebKit while routing the probe through a
        // zero-gain node so this unattended lane never reaches the speakers.
        let probeStarted = try await startNativeWebKitAudioQualityProbe(in: webView)
        #expect(probeStarted)

        let batchFrames = 25_200
        var firstFrame = 0
        // Prime the Opus path and the browser jitter buffer before measuring.
        for _ in 0..<2 {
            try await harness.sendAudioQualityFixture(
                firstFrame: firstFrame,
                frameCount: batchFrames
            )
            firstFrame += batchFrames
            try await Task.sleep(for: .milliseconds(480))
        }
        try await resetNativeWebKitAudioQualityProbe(in: webView)

        let deliveryBefore = await harness.systemAudioDeliverySnapshot
        for _ in 0..<6 {
            try await harness.sendAudioQualityFixture(
                firstFrame: firstFrame,
                frameCount: batchFrames
            )
            firstFrame += batchFrames
            try await Task.sleep(for: .milliseconds(480))
        }
        let deliveryAfter = await harness.systemAudioDeliverySnapshot
        let quality = try await nativeWebKitAudioQualitySnapshot(webView)
        if ProcessInfo.processInfo.environment["CLIP_LIVE_SHARE_AUDIO_DIAGNOSTICS"] == "1" {
            print("CLIP_AUDIO_OPUS \(opusNegotiation.description)")
            print(
                "CLIP_AUDIO_QUALITY context=\(quality.contextState) "
                    + "sampleRate=\(quality.sampleRate) "
                    + "channels=\(quality.channelCount) "
                    + "samples=\(quality.sampleCount) "
                    + "silentBlocks=\(quality.silentBlockRatio) "
                    + "clippedSamples=\(quality.clippedSampleRatio) "
                    + "leftRMS=\(quality.leftRMS) rightRMS=\(quality.rightRMS) "
                    + "leftToneRatio=\(quality.leftDesiredToneRatio) "
                    + "rightToneRatio=\(quality.rightDesiredToneRatio) "
                    + "leftSeparationDB=\(quality.leftSeparationDB) "
                    + "rightSeparationDB=\(quality.rightSeparationDB) "
                    + "leftFrequencyHz=\(quality.leftDominantFrequencyHz) "
                    + "rightFrequencyHz=\(quality.rightDominantFrequencyHz) "
                    + "measurementMs=\(quality.measurementMilliseconds) "
                    + "inboundBitrateBps=\(String(describing: quality.inboundBitrateBps)) "
                    + "inboundCodec=\(String(describing: quality.inboundCodec)) "
                    + "statsMs="
                    + "\(String(describing: quality.inboundStatisticsMilliseconds)) "
                    + "bytesDelta="
                    + "\(String(describing: quality.inboundBytesReceivedDelta)) "
                    + "packetsDelta="
                    + "\(String(describing: quality.inboundPacketsReceivedDelta)) "
                    + "packetsPerSecond="
                    + "\(String(describing: quality.inboundPacketsPerSecond)) "
                    + "samplesDelta="
                    + "\(String(describing: quality.inboundTotalSamplesDelta)) "
                    + "samplesPerSecond="
                    + "\(String(describing: quality.inboundSamplesPerSecond)) "
                    + "concealedDelta="
                    + "\(String(describing: quality.inboundConcealedSamplesDelta)) "
                    + "silentConcealedDelta="
                    + "\(String(describing: quality.inboundSilentConcealedSamplesDelta)) "
                    + "packetLossPercent="
                    + "\(String(describing: quality.inboundPacketLossPercent)) "
                    + "concealedSamplePercent="
                    + "\(String(describing: quality.inboundConcealedSamplePercent)) "
                    + "insertedSamples="
                    + "\(String(describing: quality.inboundInsertedSamples)) "
                    + "removedSamples="
                    + "\(String(describing: quality.inboundRemovedSamples))"
            )
            print("CLIP_AUDIO_DELIVERY before=\(deliveryBefore) after=\(deliveryAfter)")
        }
        try await stopNativeWebKitAudioQualityProbe(in: webView)

        #expect(deliveryAfter.acceptedFrameCount - deliveryBefore.acceptedFrameCount
            == UInt64(batchFrames * 6))
        #expect(deliveryAfter.droppedFrameCount == deliveryBefore.droppedFrameCount)
        #expect(deliveryAfter.underflowFrameCount == deliveryBefore.underflowFrameCount)
        #expect(deliveryAfter.deliveryErrorCount == deliveryBefore.deliveryErrorCount)
        let deliveredCallbacks = deliveryAfter.deliveryCallbackCount
            - deliveryBefore.deliveryCallbackCount
        let deliveredFrames = deliveryAfter.deliveredFrameCount
            - deliveryBefore.deliveredFrameCount
        #expect(deliveredFrames == deliveredCallbacks * 480)
        #expect(deliveredFrames >= 96_000)

        // These generous bounds reject the original half-buffer/mono failure
        // and audible starvation while leaving ample room for ordinary Opus
        // loss, WebKit clock correction, and scheduler variance.
        #expect(quality.contextState == "running")
        #expect(quality.channelCount >= 2)
        #expect(quality.sampleCount >= 96_000)
        #expect(quality.silentBlockRatio < 0.08)
        #expect(quality.clippedSampleRatio < 0.001)
        #expect(quality.leftRMS > 0.03 && quality.leftRMS < 0.16)
        #expect(quality.rightRMS > 0.03 && quality.rightRMS < 0.16)
        #expect(quality.leftDesiredToneRatio > 0.65)
        #expect(quality.rightDesiredToneRatio > 0.65)
        #expect(quality.leftSeparationDB > 8)
        #expect(quality.rightSeparationDB > 8)
        #expect(abs(quality.leftDominantFrequencyHz - 440) < 15)
        #expect(abs(quality.rightDominantFrequencyHz - 997) < 20)

        // RTCStats fields are not mandatory in every WebKit release. When
        // present, validate cadence and concealment over the same measured
        // interval instead of relying on lifetime counters.
        if let codec = quality.inboundCodec {
            #expect(codec.lowercased() == "audio/opus")
        }
        if let bitrate = quality.inboundBitrateBps {
            #expect(bitrate > 96_000 && bitrate < 160_000)
        }
        if let packetsPerSecond = quality.inboundPacketsPerSecond {
            #expect(packetsPerSecond > 40 && packetsPerSecond < 60)
        }
        if let samplesPerSecond = quality.inboundSamplesPerSecond {
            #expect(samplesPerSecond > 45_000 && samplesPerSecond < 51_000)
        }
        if let loss = quality.inboundPacketLossPercent {
            #expect(loss < 1)
        }
        if let concealment = quality.inboundConcealedSamplePercent {
            #expect(concealment < 1)
        }
        if let sampleCount = quality.inboundTotalSamplesDelta {
            let inserted = quality.inboundInsertedSamples ?? 0
            let removed = quality.inboundRemovedSamples ?? 0
            #expect(inserted + removed < sampleCount * 0.02)
        }
    }
}
}

private actor NativeWebKitHostHarness {
    static let fixtureWidth = 960
    static let fixtureHeight = 540

    private let endpoint: ClipLiveShareServerEndpoint
    private let signaling: ClipLiveShareSignalingClient
    private let peerHost: WebRTCPeerHost
    private var eventTask: Task<Void, Never>?
    private var room: ClipLiveShareRoomConfiguration?
    private var routeID: ClipLiveShareRouteID?
    private var viewerID: String?
    private var sessionID: ClipLiveShareSessionID?
    private var negotiationID: ClipLiveShareNegotiationID?
    private var pendingLocalICE: [WebRTCICECandidate] = []
    private var pendingRemoteICE: [ClipLiveShareICECandidate] = []
    private var offerWasSent = false
    private var answerWasApplied = false
    private var localICEMessageCount = 0
    private var remoteICEMessageCount = 0
    private var controlIsOpen = false
    private var encryptedAdmissionCompleted = false
    private var serverRouteCloseRequested = false
    private var offerSDP = ""
    private var answerSDP = ""
    private var fixtureDescriptor: ClipLiveShareStreamDescriptor?
    private var failure: String?
    private var isStopping = false

    init(endpoint: ClipLiveShareServerEndpoint) throws {
        self.endpoint = endpoint
        signaling = ClipLiveShareSignalingClient(reconnectPolicy: .disabled)

        let eventQueue = DispatchQueue(
            label: "com.tomaslejdung.clip.tests.native-webkit-peer-events"
        )
        let bridge = NativeWebKitPeerEventBridge()
        peerHost = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                senderPolicy: .init(
                    maximumBitrateBps: 12_000_000,
                    maximumFramesPerSecond: 30,
                    maintainsResolution: true
                ),
                resourceLimits: .init(answerTimeout: 15),
                videoCodec: .vp8
            ),
            eventQueue: eventQueue,
            eventHandler: { event in bridge.receive(event) }
        )
        bridge.harness = self
        peerHost.setSystemAudioEnabled(false)
    }

    var videoTrackID: String {
        peerHost.slotSnapshots[0].trackID
    }

    var systemAudioTrackID: String {
        peerHost.systemAudioSnapshot.trackID
    }

    var completedEncryptedAdmission: Bool { encryptedAdmissionCompleted }
    var completedBidirectionalICEExchange: Bool {
        let localCandidateWasExchanged = localICEMessageCount > 0
            || offerSDP.contains("a=candidate:")
        let remoteCandidateWasExchanged = remoteICEMessageCount > 0
            || answerSDP.contains("a=candidate:")
        return localCandidateWasExchanged && remoteCandidateWasExchanged
    }
    var offerContainsSystemAudioTrack: Bool {
        offerSDP.contains(peerHost.systemAudioSnapshot.trackID)
    }
    var closedServerIntroductionRoute: Bool { serverRouteCloseRequested }
    var failureDescription: String? { failure }
    var systemAudioDeliverySnapshot: WebRTCSystemAudioSnapshot {
        peerHost.systemAudioSnapshot
    }
    var opusNegotiationSnapshot: NativeWebKitOpusNegotiationSnapshot {
        NativeWebKitOpusNegotiationSnapshot(
            offerRtpmap: opusRtpmap(in: offerSDP),
            offerFmtp: opusFmtp(in: offerSDP),
            answerRtpmap: opusRtpmap(in: answerSDP),
            answerFmtp: opusFmtp(in: answerSDP)
        )
    }

    func start() async throws -> URL {
        let events = await signaling.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.receiveSignalingEvent(event)
            }
        }

        let room = try await signaling.createRoom(at: endpoint)
        self.room = room
        try await signaling.connect(room: room)
        return try room.viewerURL
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        eventTask?.cancel()
        eventTask = nil
        peerHost.close()
        await signaling.stop()
    }

    func waitUntilControlOpen(timeout: Duration) async -> Bool {
        await waitUntil(timeout: timeout) { controlIsOpen || failure != nil }
            && controlIsOpen
    }

    func waitUntilBidirectionalICEExchange(timeout: Duration) async -> Bool {
        await waitUntil(timeout: timeout) {
            completedBidirectionalICEExchange || failure != nil
        } && completedBidirectionalICEExchange
    }

    func activateFixtureSlot() throws {
        if let failure {
            throw NativeWebKitAcceptanceError.runtime(failure)
        }
        guard controlIsOpen, let viewerID, let sessionID else {
            throw NativeWebKitAcceptanceError.runtime(
                "The Clip control channel is unavailable."
            )
        }
        let slot = peerHost.slotSnapshots[0]
        let descriptor = try ClipLiveShareStreamDescriptor(
            id: .random(),
            mediaTrackID: try ClipLiveShareMediaTrackID(rawValue: slot.trackID),
            active: true,
            focused: true,
            appName: "Clip Acceptance",
            windowName: "Deterministic WebKit Fixture",
            width: Self.fixtureWidth,
            height: Self.fixtureHeight,
            order: 0
        )
        try peerHost.activateSlot(0, metadata: descriptor)
        fixtureDescriptor = descriptor

        peerHost.setSystemAudioEnabled(true)
        try sendControl(
            .systemAudioState(ClipLiveShareSystemAudioState(
                sessionID: sessionID,
                enabled: true
            )),
            to: viewerID
        )

        try sendControl(
            .manifest(try ClipLiveShareStreamManifest(
                sessionID: sessionID,
                streams: [descriptor]
            )),
            to: viewerID
        )
        try sendControl(
            .focus(ClipLiveShareFocus(
                sessionID: sessionID,
                streamID: descriptor.id
            )),
            to: viewerID
        )
        try sendCursor(x: 25, y: 75)
        try sendControl(
            .sharingState(ClipLiveShareSharingState(
                sessionID: sessionID,
                sharing: true
            )),
            to: viewerID
        )
    }

    func setSystemAudioSharingEnabled(_ enabled: Bool) throws {
        if let failure {
            throw NativeWebKitAcceptanceError.runtime(failure)
        }
        guard controlIsOpen, let viewerID, let sessionID else {
            throw NativeWebKitAcceptanceError.runtime(
                "The Clip control channel is unavailable."
            )
        }
        peerHost.setSystemAudioEnabled(enabled)
        try sendControl(
            .systemAudioState(ClipLiveShareSystemAudioState(
                sessionID: sessionID,
                enabled: enabled
            )),
            to: viewerID
        )
    }

    func sendAudioQualityFixture(
        firstFrame: Int,
        frameCount: Int
    ) throws {
        if let failure {
            throw NativeWebKitAcceptanceError.runtime(failure)
        }
        let sample = try makeNativeWebKitStereoAudioFixture(
            firstFrame: firstFrame,
            frameCount: frameCount
        )
        guard peerHost.send(BorrowedCaptureAudioSample(sampleBuffer: sample)) else {
            throw NativeWebKitAcceptanceError.runtime(
                "The native host rejected deterministic system audio."
            )
        }
    }

    func sendFixtureFrame(index: Int) throws {
        if let failure {
            throw NativeWebKitAcceptanceError.runtime(failure)
        }
        let frame = try makeNativeWebKitFixtureFrame(
            index: index,
            width: Self.fixtureWidth,
            height: Self.fixtureHeight
        )
        guard peerHost.send(frame, toSlot: 0) == .accepted else {
            throw NativeWebKitAcceptanceError.runtime(
                "The native host rejected a deterministic fixture frame."
            )
        }
    }

    func sendCursor(x: Double, y: Double) throws {
        guard let viewerID, let sessionID, let descriptor = fixtureDescriptor else {
            throw NativeWebKitAcceptanceError.runtime(
                "The fixture stream is not active."
            )
        }
        let message = ClipLiveShareInnerMessage.cursor(
            try ClipLiveShareCursor(
                sessionID: sessionID,
                streamID: descriptor.id,
                x: x,
                y: y,
                inView: true
            )
        )
        let payload = try ClipLiveShareMessageCodec.encodeInner(message)
        guard peerHost.sendEphemeralControl(payload, to: viewerID) else {
            throw NativeWebKitAcceptanceError.runtime(
                "The native host could not deliver cursor state."
            )
        }
    }

    private func waitUntil(
        timeout: Duration,
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func receiveSignalingEvent(_ event: ClipLiveShareSignalingEvent) async {
        do {
            switch event {
            case .routeOpened(let openedRouteID):
                try await beginEncryptedAdmission(on: openedRouteID)

            case .message(let messageRouteID, let message):
                try await receiveEncryptedMessage(
                    message,
                    routeID: messageRouteID
                )

            case .routeClosed(let closedRouteID, _),
                 .routeRejected(let closedRouteID, _):
                if closedRouteID == routeID, !controlIsOpen {
                    throw NativeWebKitAcceptanceError.runtime(
                        "The server introduction route closed before WebRTC was ready."
                    )
                }

            case .serverError(let code):
                if !controlIsOpen {
                    throw NativeWebKitAcceptanceError.runtime(
                        "The local Clip server rejected signaling: \(code)."
                    )
                }

            case .invalidMessageReceived, .eventBufferOverflow:
                throw NativeWebKitAcceptanceError.runtime(
                    "The local Clip server produced invalid signaling."
                )

            case .disconnected(let reason, let willReconnect):
                if !isStopping, !controlIsOpen || willReconnect {
                    throw NativeWebKitAcceptanceError.runtime(
                        "Clip signaling disconnected before handoff: \(reason)."
                    )
                }

            case .connecting, .connected, .reconnectScheduled, .stopped:
                break
            }
        } catch {
            guard !isStopping else { return }
            failure = error.localizedDescription
        }
    }

    private func beginEncryptedAdmission(
        on openedRouteID: ClipLiveShareRouteID
    ) async throws {
        guard routeID == nil else {
            await signaling.closeRoute(openedRouteID)
            throw NativeWebKitAcceptanceError.runtime(
                "The acceptance room unexpectedly received a second viewer."
            )
        }
        let sessionID = ClipLiveShareSessionID.random()
        routeID = openedRouteID
        viewerID = openedRouteID.rawValue
        self.sessionID = sessionID
        try await signaling.send(
            .authChallenge(.random(
                sessionID: sessionID,
                accessCodeRequired: false
            )),
            to: openedRouteID
        )
    }

    private func receiveEncryptedMessage(
        _ message: ClipLiveShareInnerMessage,
        routeID messageRouteID: ClipLiveShareRouteID
    ) async throws {
        guard messageRouteID == routeID,
              message.sessionID == sessionID else {
            throw NativeWebKitAcceptanceError.runtime(
                "Encrypted signaling arrived for another route or session."
            )
        }
        switch message {
        case .authResponse(let response):
            guard response.proof == nil else {
                throw NativeWebKitAcceptanceError.runtime(
                    "The no-code acceptance viewer sent an unexpected proof."
                )
            }
            try await admitViewer(on: messageRouteID)

        case .answer(let answer):
            try await applyAnswer(answer)

        case .ice(let candidate):
            try await applyOrQueueRemoteICE(candidate)

        case .error(let failure):
            throw NativeWebKitAcceptanceError.runtime(
                "The browser rejected encrypted signaling: \(failure.failure.message)."
            )

        default:
            throw NativeWebKitAcceptanceError.runtime(
                "The browser sent an unexpected encrypted \(message.type) message."
            )
        }
    }

    private func admitViewer(on routeID: ClipLiveShareRouteID) async throws {
        guard !encryptedAdmissionCompleted,
              let sessionID,
              let viewerID else {
            throw NativeWebKitAcceptanceError.runtime(
                "The viewer repeated or bypassed encrypted admission."
            )
        }
        try await signaling.send(
            .authResult(try ClipLiveShareAuthResult(
                sessionID: sessionID,
                allowed: true
            )),
            to: routeID
        )
        encryptedAdmissionCompleted = true

        let negotiationID = ClipLiveShareNegotiationID.random()
        self.negotiationID = negotiationID
        let offer = try await peerHost.createOffer(for: viewerID)
        offerSDP = offer.sdp
        try await signaling.send(
            .offer(try ClipLiveShareSessionDescription(
                sessionID: sessionID,
                negotiationID: negotiationID,
                sdp: offer.sdp
            )),
            to: routeID
        )
        offerWasSent = true
        try await flushPendingLocalICE()
    }

    private func applyAnswer(
        _ answer: ClipLiveShareSessionDescription
    ) async throws {
        guard answer.negotiationID == negotiationID,
              let viewerID else {
            throw NativeWebKitAcceptanceError.runtime(
                "The WebKit answer did not match the active negotiation."
            )
        }
        answerSDP = answer.sdp
        try await peerHost.setRemoteAnswer(answer.sdp, for: viewerID)
        answerWasApplied = true
        let queued = pendingRemoteICE
        pendingRemoteICE.removeAll(keepingCapacity: false)
        for candidate in queued {
            try await peerHost.addRemoteICECandidate(
                webRTCCandidate(candidate),
                for: viewerID
            )
        }
    }

    private func applyOrQueueRemoteICE(
        _ candidate: ClipLiveShareICECandidate
    ) async throws {
        guard candidate.negotiationID == negotiationID,
              let viewerID else {
            throw NativeWebKitAcceptanceError.runtime(
                "Browser ICE did not match the active negotiation."
            )
        }
        remoteICEMessageCount += 1
        if answerWasApplied {
            try await peerHost.addRemoteICECandidate(
                webRTCCandidate(candidate),
                for: viewerID
            )
        } else {
            pendingRemoteICE.append(candidate)
        }
    }

    private func webRTCCandidate(
        _ candidate: ClipLiveShareICECandidate
    ) -> WebRTCICECandidate {
        WebRTCICECandidate(
            candidate: candidate.candidate,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int32(candidate.sdpMLineIndex)
        )
    }

    private func sendLocalICE(_ candidate: WebRTCICECandidate) async throws {
        guard let routeID, let sessionID, let negotiationID else {
            throw NativeWebKitAcceptanceError.runtime(
                "Native ICE was produced without an active encrypted route."
            )
        }
        try await signaling.send(
            .ice(try ClipLiveShareICECandidate(
                sessionID: sessionID,
                negotiationID: negotiationID,
                candidate: candidate.candidate,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: Int(candidate.sdpMLineIndex)
            )),
            to: routeID
        )
        localICEMessageCount += 1
    }

    private func flushPendingLocalICE() async throws {
        let queued = pendingLocalICE
        pendingLocalICE.removeAll(keepingCapacity: false)
        for candidate in queued {
            try await sendLocalICE(candidate)
        }
    }

    fileprivate func receivePeerEvent(_ event: WebRTCPeerHostEvent) async {
        do {
            switch event {
            case .localICECandidate(let eventViewerID, let candidate):
                guard eventViewerID == viewerID else { return }
                if controlIsOpen {
                    return
                } else if offerWasSent {
                    try await sendLocalICE(candidate)
                } else {
                    pendingLocalICE.append(candidate)
                }

            case .controlDataChannelStateChanged(let eventViewerID, let state):
                guard eventViewerID == viewerID, state == .open else { return }
                controlIsOpen = true
                if let sessionID, let viewerID {
                    try sendControl(
                        .systemAudioState(ClipLiveShareSystemAudioState(
                            sessionID: sessionID,
                            enabled: false
                        )),
                        to: viewerID
                    )
                }
                if let routeID {
                    await signaling.closeRoute(routeID)
                    serverRouteCloseRequested = true
                }

            case .connectionStateChanged(_, let state):
                if state == .failed {
                    throw NativeWebKitAcceptanceError.runtime(
                        "The native-to-WebKit peer connection failed."
                    )
                }

            case .error(_, let error):
                throw error

            case .viewerRemoved(let removedViewerID):
                if !isStopping, removedViewerID == viewerID {
                    throw NativeWebKitAcceptanceError.runtime(
                        "The native WebRTC peer disappeared during acceptance."
                    )
                }

            case .viewerAdded, .controlDataChannelDrained,
                 .controlMessageReceived, .negotiationNeeded,
                 .videoCodecChanged:
                break
            }
        } catch {
            guard !isStopping else { return }
            failure = error.localizedDescription
        }
    }

    private func sendControl(
        _ message: ClipLiveShareInnerMessage,
        to viewerID: String
    ) throws {
        let payload = try ClipLiveShareMessageCodec.encodeInner(message)
        guard peerHost.sendControl(payload, to: viewerID) else {
            throw NativeWebKitAcceptanceError.runtime(
                "The native host could not deliver \(message.type) control state."
            )
        }
    }
}

private final class NativeWebKitPeerEventBridge: @unchecked Sendable {
    weak var harness: NativeWebKitHostHarness?

    func receive(_ event: WebRTCPeerHostEvent) {
        Task { [weak harness] in
            await harness?.receivePeerEvent(event)
        }
    }
}

private struct NativeWebKitViewerSnapshot: Decodable {
    let readyState: String
    let statusText: String
    let videoWidth: Int
    let videoHeight: Int
    let decodedFrames: Int
    let manifestTrackBound: Bool
    let audioTrackVisible: Bool
    let audioControlEnabled: Bool
    let cursorTransformApplied: Bool
}

@MainActor
private func nativeWebKitViewerSnapshot(
    _ webView: WKWebView,
    expectedVideoTrackID: String,
    expectedAudioTrackID: String
) async throws -> NativeWebKitViewerSnapshot {
    let videoTrackLiteral = try javaScriptStringLiteral(expectedVideoTrackID)
    let audioTrackLiteral = try javaScriptStringLiteral(expectedAudioTrackID)
    let script = #"""
    (() => {
      const video = document.getElementById("main-video");
      const audio = document.getElementById("system-audio");
      if (!window.__clipNativeAcceptanceFrameProbe) {
        const probe = { presentedFrames: 0 };
        window.__clipNativeAcceptanceFrameProbe = probe;
        if (video && typeof video.requestVideoFrameCallback === "function") {
          const observe = () => {
            probe.presentedFrames += 1;
            video.requestVideoFrameCallback(observe);
          };
          video.requestVideoFrameCallback(observe);
        }
      }
      const playback = video && typeof video.getVideoPlaybackQuality === "function"
        ? video.getVideoPlaybackQuality() : null;
      const decoded = playback && Number.isFinite(playback.totalVideoFrames)
        ? playback.totalVideoFrames
        : (video && Number.isFinite(video.webkitDecodedFrameCount)
            ? video.webkitDecodedFrameCount : 0);
      const videoTrack = video?.srcObject?.getVideoTracks?.()[0] || null;
      const audioTrack = audio?.srcObject?.getAudioTracks?.()[0] || null;
      const transform = document.getElementById("pan-zoom-content")?.style?.transform || "";
      const zeroTransforms = new Set([
        "",
        "translate3d(0px, 0px, 0px)",
        "translate3d(0px, 0px, 0)",
      ]);
      return JSON.stringify({
        readyState: document.readyState,
        statusText: document.getElementById("status-text")?.textContent || "",
        videoWidth: video?.videoWidth || 0,
        videoHeight: video?.videoHeight || 0,
        decodedFrames: Math.max(
          decoded || 0,
          window.__clipNativeAcceptanceFrameProbe?.presentedFrames || 0,
        ),
        manifestTrackBound: videoTrack?.id === \#(videoTrackLiteral),
        audioTrackVisible: audioTrack?.id === \#(audioTrackLiteral),
        audioControlEnabled: document.getElementById("btn-audio")?.disabled === false,
        cursorTransformApplied: !zeroTransforms.has(transform),
      });
    })()
    """#
    let result = try await webView.evaluateJavaScript(script)
    guard let json = result as? String,
          let data = json.data(using: .utf8) else {
        throw NativeWebKitAcceptanceError.invalidBrowserSnapshot
    }
    return try JSONDecoder().decode(NativeWebKitViewerSnapshot.self, from: data)
}

@MainActor
private func waitForNativeWebKitSnapshot(
    webView: WKWebView,
    expectedVideoTrackID: String,
    expectedAudioTrackID: String,
    timeout: Duration,
    predicate: (NativeWebKitViewerSnapshot) -> Bool
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        do {
            let snapshot = try await nativeWebKitViewerSnapshot(
                webView,
                expectedVideoTrackID: expectedVideoTrackID,
                expectedAudioTrackID: expectedAudioTrackID
            )
            if predicate(snapshot) { return true }
        } catch {
            // Navigation temporarily replaces the JavaScript context.
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    return predicate(try await nativeWebKitViewerSnapshot(
        webView,
        expectedVideoTrackID: expectedVideoTrackID,
        expectedAudioTrackID: expectedAudioTrackID
    ))
}

@MainActor
private func selectNativeScale(in webView: WKWebView) async throws {
    let selected = try await webView.evaluateJavaScript(#"""
    (() => {
      const button = document.querySelector('.scale-btn[data-scale="native"]');
      if (!button) return false;
      button.click();
      return true;
    })()
    """#)
    guard selected as? Bool == true else {
        throw NativeWebKitAcceptanceError.runtime(
            "The embedded viewer did not expose its native-scale control."
        )
    }
}

private struct NativeWebKitAudioQualitySnapshot: Decodable {
    let contextState: String
    let sampleRate: Double
    let channelCount: Int
    let sampleCount: Int
    let silentBlockRatio: Double
    let clippedSampleRatio: Double
    let leftRMS: Double
    let rightRMS: Double
    let leftDesiredToneRatio: Double
    let rightDesiredToneRatio: Double
    let leftSeparationDB: Double
    let rightSeparationDB: Double
    let leftDominantFrequencyHz: Double
    let rightDominantFrequencyHz: Double
    let measurementMilliseconds: Double
    let inboundBitrateBps: Double?
    let inboundCodec: String?
    let inboundStatisticsMilliseconds: Double?
    let inboundBytesReceivedDelta: Double?
    let inboundPacketsReceivedDelta: Double?
    let inboundPacketsPerSecond: Double?
    let inboundTotalSamplesDelta: Double?
    let inboundSamplesPerSecond: Double?
    let inboundConcealedSamplesDelta: Double?
    let inboundSilentConcealedSamplesDelta: Double?
    let inboundPacketLossPercent: Double?
    let inboundConcealedSamplePercent: Double?
    let inboundInsertedSamples: Double?
    let inboundRemovedSamples: Double?
}

@MainActor
private func startNativeWebKitAudioQualityProbe(in webView: WKWebView) async throws -> Bool {
    let result = try await webView.evaluateJavaScript(#"""
    (() => {
      if (window.__clipNativeAcceptanceAudioProbe) return true;
      const element = document.getElementById("system-audio");
      const track = element?.srcObject?.getAudioTracks?.()[0] || null;
      const Context = window.AudioContext || window.webkitAudioContext;
      if (!track || !Context) return false;

      let context;
      try {
        context = new Context({ latencyHint: "interactive", sampleRate: 48000 });
      } catch (_) {
        context = new Context();
      }
      const source = context.createMediaStreamSource(new MediaStream([track]));
      const processor = context.createScriptProcessor(2048, 2, 2);
      const silentOutput = context.createGain();
      silentOutput.gain.value = 0;
      const previousElementMuted = element.muted;
      element.muted = true;

      const makeChannel = () => ({
        samples: 0,
        sumSquares: 0,
        clipped: 0,
        positiveCrossings: 0,
        previousSample: 0,
        toneRatios: [],
        separationDB: [],
      });
      const probe = {
        context,
        source,
        processor,
        silentOutput,
        element,
        previousElementMuted,
        channelCount: 0,
        blocks: 0,
        silentBlocks: 0,
        channels: [makeChannel(), makeChannel()],
        reset() {
          const diagnostics = window.__clipLiveShareAudioDiagnostics;
          const inbound = diagnostics?.tracks?.[0];
          const counter = (value) => Number.isFinite(value) ? value : null;
          this.channelCount = 0;
          this.blocks = 0;
          this.silentBlocks = 0;
          this.channels = [makeChannel(), makeChannel()];
          this.startedAt = performance.now();
          this.inboundStart = {
            updatedAt: counter(diagnostics?.updatedAt),
            trackIdentifier: typeof inbound?.trackIdentifier === "string"
              ? inbound.trackIdentifier : null,
            bytesReceived: counter(inbound?.bytesReceived),
            packetsReceived: counter(inbound?.packetsReceived),
            packetsLost: counter(inbound?.packetsLost),
            totalSamplesReceived: counter(inbound?.totalSamplesReceived),
            concealedSamples: counter(inbound?.concealedSamples),
            silentConcealedSamples: counter(inbound?.silentConcealedSamples),
            insertedSamplesForDeceleration:
              counter(inbound?.insertedSamplesForDeceleration),
            removedSamplesForAcceleration:
              counter(inbound?.removedSamplesForAcceleration),
          };
        },
      };

      processor.onaudioprocess = (event) => {
        const input = event.inputBuffer;
        probe.channelCount = Math.max(probe.channelCount, input.numberOfChannels);
        const channelData = [
          input.getChannelData(0),
          input.getChannelData(Math.min(1, input.numberOfChannels - 1)),
        ];
        let blockSquares = 0;
        for (let channelIndex = 0; channelIndex < 2; channelIndex += 1) {
          const samples = channelData[channelIndex];
          const state = probe.channels[channelIndex];
          const desiredFrequency = channelIndex === 0 ? 440 : 997;
          const wrongFrequency = channelIndex === 0 ? 997 : 440;
          let desiredCos = 0;
          let desiredSin = 0;
          let wrongCos = 0;
          let wrongSin = 0;
          let windowSum = 0;
          let channelBlockSquares = 0;
          for (let index = 0; index < samples.length; index += 1) {
            const value = samples[index];
            const window = samples.length > 1
              ? 0.5 - 0.5 * Math.cos(2 * Math.PI * index / (samples.length - 1))
              : 1;
            const desiredPhase = 2 * Math.PI * desiredFrequency
              * index / input.sampleRate;
            const wrongPhase = 2 * Math.PI * wrongFrequency
              * index / input.sampleRate;
            state.sumSquares += value * value;
            channelBlockSquares += value * value;
            blockSquares += value * value;
            if (Math.abs(value) >= 0.999) state.clipped += 1;
            if (state.previousSample <= 0 && value > 0) {
              state.positiveCrossings += 1;
            }
            state.previousSample = value;
            desiredCos += value * window * Math.cos(desiredPhase);
            desiredSin += value * window * Math.sin(desiredPhase);
            wrongCos += value * window * Math.cos(wrongPhase);
            wrongSin += value * window * Math.sin(wrongPhase);
            windowSum += window;
          }
          const blockRMS = Math.sqrt(channelBlockSquares / samples.length);
          if (blockRMS >= 0.005) {
            const desiredAmplitude = 2 * Math.hypot(desiredCos, desiredSin)
              / Math.max(1, windowSum);
            const wrongAmplitude = 2 * Math.hypot(wrongCos, wrongSin)
              / Math.max(1, windowSum);
            state.toneRatios.push(
              desiredAmplitude / Math.max(1e-9, Math.SQRT2 * blockRMS),
            );
            state.separationDB.push(20 * Math.log10(
              Math.max(1e-9, desiredAmplitude) / Math.max(1e-9, wrongAmplitude),
            ));
          }
          state.samples += samples.length;
        }
        probe.blocks += 1;
        const blockSampleCount = channelData[0].length * 2;
        if (Math.sqrt(blockSquares / Math.max(1, blockSampleCount)) < 0.005) {
          probe.silentBlocks += 1;
        }
      };

      source.connect(processor);
      processor.connect(silentOutput);
      silentOutput.connect(context.destination);
      window.__clipNativeAcceptanceAudioProbe = probe;
      context.resume().catch(() => {});
      return true;
    })()
    """#)
    return result as? Bool == true
}

@MainActor
private func resetNativeWebKitAudioQualityProbe(in webView: WKWebView) async throws {
    let reset = try await webView.evaluateJavaScript(#"""
    (() => {
      const probe = window.__clipNativeAcceptanceAudioProbe;
      if (!probe) return false;
      probe.reset();
      return true;
    })()
    """#)
    guard reset as? Bool == true else {
        throw NativeWebKitAcceptanceError.runtime(
            "The WebKit decoded-audio quality probe was unavailable."
        )
    }
}

@MainActor
private func stopNativeWebKitAudioQualityProbe(in webView: WKWebView) async throws {
    let stopped = try await webView.evaluateJavaScript(#"""
    (() => {
      const probe = window.__clipNativeAcceptanceAudioProbe;
      if (!probe) return false;
      probe.processor.onaudioprocess = null;
      probe.source.disconnect();
      probe.processor.disconnect();
      probe.silentOutput.disconnect();
      probe.element.muted = probe.previousElementMuted;
      probe.context.close().catch(() => {});
      delete window.__clipNativeAcceptanceAudioProbe;
      return true;
    })()
    """#)
    guard stopped as? Bool == true else {
        throw NativeWebKitAcceptanceError.runtime(
            "The WebKit decoded-audio quality probe could not be stopped."
        )
    }
}

@MainActor
private func nativeWebKitAudioQualitySnapshot(
    _ webView: WKWebView
) async throws -> NativeWebKitAudioQualitySnapshot {
    let result = try await webView.evaluateJavaScript(#"""
    (() => {
      const probe = window.__clipNativeAcceptanceAudioProbe;
      if (!probe) return null;
      const median = (values) => {
        if (!Array.isArray(values) || values.length === 0) return 0;
        const sorted = [...values].sort((left, right) => left - right);
        const middle = Math.floor(sorted.length / 2);
        return sorted.length % 2 === 0
          ? (sorted[middle - 1] + sorted[middle]) / 2
          : sorted[middle];
      };
      const metrics = probe.channels.map((channel) => {
        const count = Math.max(1, channel.samples);
        const rms = Math.sqrt(channel.sumSquares / count);
        return {
          rms,
          clippedRatio: channel.clipped / count,
          desiredRatio: median(channel.toneRatios),
          separationDB: median(channel.separationDB),
          dominantFrequencyHz: channel.positiveCrossings
            * probe.context.sampleRate / count,
        };
      });
      const diagnostics = window.__clipLiveShareAudioDiagnostics;
      const inbound = diagnostics?.tracks?.find((track) =>
        !probe.inboundStart?.trackIdentifier
          || track.trackIdentifier === probe.inboundStart.trackIdentifier
      ) || diagnostics?.tracks?.[0] || null;
      const measurementMilliseconds = performance.now() - probe.startedAt;
      const counter = (value) => Number.isFinite(value) ? value : null;
      const counterDelta = (end, start) => {
        const current = counter(end);
        const previous = counter(start);
        return current !== null && previous !== null && current >= previous
          ? current - previous : null;
      };
      const inboundStatisticsMilliseconds =
        counter(diagnostics?.updatedAt) !== null
        && counter(probe.inboundStart?.updatedAt) !== null
        && diagnostics.updatedAt > probe.inboundStart.updatedAt
          ? diagnostics.updatedAt - probe.inboundStart.updatedAt : null;
      const inboundBytesReceivedDelta = counterDelta(
        inbound?.bytesReceived,
        probe.inboundStart?.bytesReceived,
      );
      const inboundPacketsReceivedDelta = counterDelta(
        inbound?.packetsReceived,
        probe.inboundStart?.packetsReceived,
      );
      const inboundPacketsLostDelta = counterDelta(
        inbound?.packetsLost,
        probe.inboundStart?.packetsLost,
      );
      const inboundTotalSamplesDelta = counterDelta(
        inbound?.totalSamplesReceived,
        probe.inboundStart?.totalSamplesReceived,
      );
      const inboundConcealedSamplesDelta = counterDelta(
        inbound?.concealedSamples,
        probe.inboundStart?.concealedSamples,
      );
      const inboundSilentConcealedSamplesDelta = counterDelta(
        inbound?.silentConcealedSamples,
        probe.inboundStart?.silentConcealedSamples,
      );
      const inboundInsertedSamplesDelta = counterDelta(
        inbound?.insertedSamplesForDeceleration,
        probe.inboundStart?.insertedSamplesForDeceleration,
      );
      const inboundRemovedSamplesDelta = counterDelta(
        inbound?.removedSamplesForAcceleration,
        probe.inboundStart?.removedSamplesForAcceleration,
      );
      const statisticsSeconds = inboundStatisticsMilliseconds === null
        ? null : inboundStatisticsMilliseconds / 1000;
      const packetDenominator = inboundPacketsReceivedDelta !== null
        && inboundPacketsLostDelta !== null
          ? inboundPacketsReceivedDelta + Math.max(0, inboundPacketsLostDelta)
          : null;
      return JSON.stringify({
        contextState: probe.context.state,
        sampleRate: probe.context.sampleRate,
        channelCount: probe.channelCount,
        sampleCount: Math.min(
          probe.channels[0].samples,
          probe.channels[1].samples,
        ),
        silentBlockRatio: probe.silentBlocks / Math.max(1, probe.blocks),
        clippedSampleRatio: Math.max(
          metrics[0].clippedRatio,
          metrics[1].clippedRatio,
        ),
        leftRMS: metrics[0].rms,
        rightRMS: metrics[1].rms,
        leftDesiredToneRatio: metrics[0].desiredRatio,
        rightDesiredToneRatio: metrics[1].desiredRatio,
        leftSeparationDB: metrics[0].separationDB,
        rightSeparationDB: metrics[1].separationDB,
        leftDominantFrequencyHz: metrics[0].dominantFrequencyHz,
        rightDominantFrequencyHz: metrics[1].dominantFrequencyHz,
        measurementMilliseconds,
        inboundBitrateBps: inboundBytesReceivedDelta === null
          || statisticsSeconds === null
          ? null
          : inboundBytesReceivedDelta * 8 / statisticsSeconds,
        inboundCodec: typeof inbound?.codec === "string" ? inbound.codec : null,
        inboundStatisticsMilliseconds,
        inboundBytesReceivedDelta,
        inboundPacketsReceivedDelta,
        inboundPacketsPerSecond: inboundPacketsReceivedDelta === null
          || statisticsSeconds === null
          ? null : inboundPacketsReceivedDelta / statisticsSeconds,
        inboundTotalSamplesDelta,
        inboundSamplesPerSecond: inboundTotalSamplesDelta === null
          || statisticsSeconds === null
          ? null : inboundTotalSamplesDelta / statisticsSeconds,
        inboundConcealedSamplesDelta,
        inboundSilentConcealedSamplesDelta,
        inboundPacketLossPercent: inboundPacketsLostDelta === null
          || packetDenominator === null || packetDenominator <= 0
          ? null : inboundPacketsLostDelta * 100 / packetDenominator,
        inboundConcealedSamplePercent: inboundConcealedSamplesDelta === null
          || inboundTotalSamplesDelta === null || inboundTotalSamplesDelta <= 0
          ? null : inboundConcealedSamplesDelta * 100 / inboundTotalSamplesDelta,
        inboundInsertedSamples: inboundInsertedSamplesDelta,
        inboundRemovedSamples: inboundRemovedSamplesDelta,
      });
    })()
    """#)
    guard let json = result as? String,
          let data = json.data(using: .utf8) else {
        throw NativeWebKitAcceptanceError.runtime(
            "WebKit did not return decoded-audio quality measurements."
        )
    }
    return try JSONDecoder().decode(NativeWebKitAudioQualitySnapshot.self, from: data)
}

private func javaScriptStringLiteral(_ value: String) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let literal = String(data: data, encoding: .utf8) else {
        throw NativeWebKitAcceptanceError.invalidBrowserSnapshot
    }
    return literal
}

private struct NativeWebKitOpusNegotiationSnapshot: Sendable {
    let offerRtpmap: String
    let offerFmtp: String
    let answerRtpmap: String
    let answerFmtp: String

    var description: String {
        "offer=[\(offerRtpmap); \(offerFmtp)] "
            + "answer=[\(answerRtpmap); \(answerFmtp)]"
    }
}

private func opusRtpmap(in sdp: String) -> String {
    sdp.components(separatedBy: .newlines).first {
        $0.localizedCaseInsensitiveContains("opus/48000")
            && $0.hasPrefix("a=rtpmap:")
    }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "<missing>"
}

private func opusFmtp(in sdp: String) -> String {
    let rtpmap = opusRtpmap(in: sdp)
    guard rtpmap != "<missing>",
          let payload = rtpmap
            .dropFirst("a=rtpmap:".count)
            .split(separator: " ")
            .first else {
        return "<missing>"
    }
    let prefix = "a=fmtp:\(payload)"
    return sdp.components(separatedBy: .newlines).first {
        $0.hasPrefix(prefix)
    }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "<missing>"
}

private func opusFmtpParameter(_ name: String, in line: String) -> String? {
    let components = line.split(separator: " ", maxSplits: 1)
    guard components.count == 2 else { return nil }
    let parameters = components[1]
    for parameter in parameters.split(separator: ";") {
        let pair = parameter.split(separator: "=", maxSplits: 1)
        guard pair.count == 2 else { continue }
        if pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            == name.lowercased() {
            return pair[1].trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

private enum NativeWebKitAudioFixtureError: Error {
    case blockBuffer(OSStatus)
    case fillBlockBuffer(OSStatus)
    case format(OSStatus)
    case sample(OSStatus)
}

/// Phase-continuous stereo music surrogate: the independent frequencies make
/// mono collapse and cross-channel corruption objectively visible after Opus.
private func makeNativeWebKitStereoAudioFixture(
    firstFrame: Int,
    frameCount: Int
) throws -> CMSampleBuffer {
    let channels = 2
    let sampleRate = 48_000.0
    var samples = [Float](repeating: 0, count: frameCount * channels)
    for frame in 0..<frameCount {
        let absoluteFrame = firstFrame + frame
        samples[frame * channels] = Float(
            sin(2 * .pi * 440 * Double(absoluteFrame) / sampleRate) * 0.1
        )
        samples[frame * channels + 1] = Float(
            sin(2 * .pi * 997 * Double(absoluteFrame) / sampleRate) * 0.1
        )
    }

    let byteCount = samples.count * MemoryLayout<Float>.size
    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
        throw NativeWebKitAudioFixtureError.blockBuffer(blockStatus)
    }
    let fillStatus = samples.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }
    guard fillStatus == kCMBlockBufferNoErr else {
        throw NativeWebKitAudioFixtureError.fillBlockBuffer(fillStatus)
    }

    let bytesPerFrame = UInt32(channels * MemoryLayout<Float>.size)
    var description = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var format: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &description,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &format
    )
    guard formatStatus == noErr, let format else {
        throw NativeWebKitAudioFixtureError.format(formatStatus)
    }

    var sample: CMSampleBuffer?
    let sampleStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: format,
        sampleCount: frameCount,
        presentationTimeStamp: CMTime(
            value: CMTimeValue(firstFrame),
            timescale: 48_000
        ),
        packetDescriptions: nil,
        sampleBufferOut: &sample
    )
    guard sampleStatus == noErr, let sample else {
        throw NativeWebKitAudioFixtureError.sample(sampleStatus)
    }
    return sample
}

private enum NativeWebKitAcceptanceError: Error, LocalizedError {
    case invalidBrowserSnapshot
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .invalidBrowserSnapshot:
            "WebKit returned an invalid Clip viewer snapshot."
        case .runtime(let message):
            message
        }
    }
}

private func makeNativeWebKitFixtureFrame(
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
        throw NativeWebKitAcceptanceError.runtime(
            "Could not create the deterministic fixture pixel buffer."
        )
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
          let context = CGContext(
              data: baseAddress,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                  | CGImageAlphaInfo.premultipliedFirst.rawValue
          ) else {
        throw NativeWebKitAcceptanceError.runtime(
            "Could not draw the deterministic fixture frame."
        )
    }

    context.setFillColor(CGColor(gray: 0.08, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let tile = 60
    for y in stride(from: 0, to: height, by: tile) {
        for x in stride(from: 0, to: width, by: tile) where (x / tile + y / tile).isMultiple(of: 2) {
            context.setFillColor(CGColor(gray: 0.88, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: tile, height: tile))
        }
    }
    context.setFillColor(CGColor(red: 0.1, green: 0.85, blue: 0.45, alpha: 1))
    context.fill(CGRect(
        x: (index * 11) % max(1, width - 140),
        y: height / 2 - 35,
        width: 140,
        height: 70
    ))
    context.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.3, alpha: 1))
    context.setLineWidth(1)
    context.stroke(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))

    var formatDescription: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    ) == noErr,
        let formatDescription else {
        throw NativeWebKitAcceptanceError.runtime(
            "Could not describe the deterministic fixture frame."
        )
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
        throw NativeWebKitAcceptanceError.runtime(
            "Could not create the deterministic fixture sample buffer."
        )
    }
    return BorrowedCaptureVideoFrame(
        sampleBuffer: sampleBuffer,
        pixelBuffer: pixelBuffer,
        presentationTime: presentationTime
    )
}
