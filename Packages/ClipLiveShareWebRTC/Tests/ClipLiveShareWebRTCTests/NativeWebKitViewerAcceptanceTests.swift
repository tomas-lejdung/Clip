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
        #expect(await harness.completedBidirectionalICEExchange)
        #expect(await harness.offerContainsSystemAudioTrack)
        #expect(await harness.closedServerIntroductionRoute)

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

private func javaScriptStringLiteral(_ value: String) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let literal = String(data: data, encoding: .utf8) else {
        throw NativeWebKitAcceptanceError.invalidBrowserSnapshot
    }
    return literal
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
