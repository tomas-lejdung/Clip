import AppKit
import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import OSLog

private struct LiveShareCaptureGeometrySnapshot {
    let sourceID: LiveShareSourceID
    let slot: Int
    let generation: UUID
    let descriptor: LiveShareCaptureDescriptor
}

private struct LiveSharePendingViewerRoute {
    let routeID: ClipLiveShareRouteID
    let sessionID: ClipLiveShareSessionID
    let challenge: ClipLiveShareAuthChallenge
    let accessCode: String?
    var progress = LiveShareViewerAdmissionProgress()
}

enum LiveShareCaptureGeometryTransitionError: LocalizedError {
    case rollbackFailed(change: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case let .rollbackFailed(change, rollback):
            "Capture geometry update failed (\(change)) and its rollback failed (\(rollback))."
        }
    }
}

enum LiveShareCaptureGeometryFailurePolicy {
    static func requiresSessionFailure(after error: any Error) -> Bool {
        if error is LiveShareCaptureGeometryTransitionError { return true }
        guard let pipelineError = error as? LiveShareCapturePipelineError else {
            return false
        }
        if case .updateRollbackFailed = pipelineError { return true }
        return false
    }
}

@MainActor
final class LiveShareCoordinator {
    nonisolated private static let logger = Logger(
        subsystem: ApplicationDirectories.bundleIdentifier,
        category: "live-share"
    )

    private let preferences: LiveSharePreferencesModel
    private let serverEndpoint: ClipLiveShareServerEndpoint
    private let signaling: ClipLiveShareSignalingClient
    private let discovery: any CaptureContentDiscovering
    private let onSessionEnded: () -> Void
    private let onMenuBarStatusChanged: (LiveShareMenuBarStatus) -> Void

    private var state = LiveShareStateMachine()
    private var settings = LiveShareSettings.default
    private var persistedSettingsBaseline = LiveShareSettings.default
    private var slotAllocation = LiveShareTrackSlotAllocation()
    private var accessCode: String?
    private var accessCodeIsUpdating = false
    private var accessCodeError: String?
    private var roomConfiguration: ClipLiveShareRoomConfiguration?
    private var signalingIsAvailable = false
    private var pendingViewerRoutes: [
        ClipLiveShareRouteID: LiveSharePendingViewerRoute
    ] = [:]
    private var admissionTimeoutTasks: [
        ClipLiveShareRouteID: Task<Void, Never>
    ] = [:]
    private var viewerSessionIDs: [String: ClipLiveShareSessionID] = [:]
    private var negotiationIDs: [String: ClipLiveShareNegotiationID] = [:]
    private var establishedControlViewerIDs: Set<String> = []
    private var pendingSessionClosingViewerIDs: Set<String> = []
    private var peerHost: WebRTCPeerHost?
    private var capturePipeline: LiveShareCapturePipeline?
    private var signalingEventTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var cursorTask: Task<Void, Never>?
    private var sourceRefreshTask: Task<Void, Never>?
    private var failureCleanupTask: Task<Void, Never>?
    private var captureRestartTask: Task<Void, Never>?
    private var captureRestartRequestID: UUID?
    private var codecChangeTask: Task<Void, Never>?
    private var systemAudioReconcileTask: Task<Void, Never>?
    private var systemAudioReconcileTaskID: UUID?
    private var sourceTransitionTask: Task<Void, Never>?
    private var sourceTransitionTaskID: UUID?
    private var sourceTransitionGeneration = 0
    private var latestAutomaticWindowID: LiveShareWindowID?
    private var fullscreenRequestGate = LiveShareFullscreenRequestGate()
    private var retryTask: Task<Void, Never>?
    private var isRetrying = false
    private var isEnding = false
    private var didNotifyEnd = false
    private var startedAt: Date?
    private var viewerConnectedAt: [String: Date] = [:]
    private var focusedWindow: FocusedLiveShareWindow?
    private var windowsByID: [LiveShareWindowID: ShareableCaptureWindow] = [:]
    private var availableWindows: [ShareableCaptureWindow] = []
    private var applicationPathsByWindowID: [LiveShareWindowID: String] = [:]
    private var displayFramesByID: [LiveShareDisplayID: CGRect] = [:]
    private var captureDescriptors: [LiveShareSourceID: LiveShareCaptureDescriptor] = [:]
    private var captureGenerations: [LiveShareSourceID: UUID] = [:]
    private var sourceStatuses: [LiveShareSourceID: LiveShareSourceViewStatus] = [:]
    private var sourceOperationIDs: Set<LiveShareSourceID> = []
    private var latestStatistics = LiveShareStatisticsViewSnapshot()
    private var capturePressure = LiveShareCapturePressureLedger()
    private var peerNegotiation = LiveSharePeerNegotiationLedger()
    private var authoritativeControlDelivery = LiveShareAuthoritativeControlDeliveryLedger()
    private var controlReplayTask: Task<Void, Never>?
    private var controlReplayTaskID: UUID?
    private var publishedMenuBarStatus: LiveShareMenuBarStatus?
    private let systemAudioRequestIdentifier = UUID()
    private var desiredSystemAudioRequest: CaptureAudioSessionRequest?
    /// Mirrors completed ScreenCaptureKit audio reconciliation, not merely the
    /// user's preference or the lifetime of the pre-negotiated Opus track.
    private var systemAudioIsActive = false

    private lazy var focusedWindowMonitor = LiveShareFocusedWindowMonitor(
        discovery: discovery,
        excludedBundleIdentifier: ApplicationDirectories.bundleIdentifier,
        handler: { [weak self] focusedWindow in
            self?.focusedWindowDidChange(focusedWindow)
        }
    )

    private lazy var focusedWindowOverlay = FocusedWindowShareOverlayController(
        actions: FocusedWindowShareOverlayActions(
            share: { [weak self] identifier in
                self?.shareFocusedWindow(requestedIdentifier: identifier)
            },
            stop: { [weak self] identifier in
                self?.stopSource(identifier: identifier)
            }
        )
    )

    private lazy var statusHUD = LiveShareStatusHUDController(
        actions: LiveShareStatusHUDActions(
            setFullscreenEnabled: { [weak self] enabled in
                self?.setFullscreenEnabled(enabled)
            },
            stopAllMedia: { [weak self] in
                self?.requestStopAllMedia()
            }
        )
    )

    private(set) lazy var presentationModel = LiveSharePresentationModel(
        snapshot: makeViewSnapshot(),
        actions: LiveSharePresentationActions(
            copyText: { value in Self.copyToPasteboard(value) },
            setAccessCodeEnabled: { [weak self] enabled in
                self?.setAccessCodeEnabled(enabled)
            },
            replaceAccessCode: { [weak self] in
                self?.replaceAccessCode()
            },
            shareFocusedWindow: { [weak self] in
                self?.shareFocusedWindow(requestedIdentifier: nil)
            },
            shareWindow: { [weak self] identifier in
                self?.shareWindow(identifier: identifier)
            },
            stopSource: { [weak self] identifier in
                self?.stopSource(identifier: identifier)
            },
            setFullscreenEnabled: { [weak self] enabled in
                self?.setFullscreenEnabled(enabled)
            },
            setQuality: { [weak self] quality in self?.setQuality(quality) },
            setFrameRate: { [weak self] frameRate in self?.setFrameRate(frameRate) },
            setCodec: { [weak self] codec in
                self?.requestVideoCodecChange(codec)
            },
            setSystemAudioEnabled: { [weak self] enabled in
                self?.setSystemAudioEnabled(enabled)
            },
            setPrioritizeFocusedWindow: { [weak self] enabled in
                self?.setPrioritizeFocusedWindow(enabled)
            },
            setMode: { [weak self] mode in self?.setEncodingMode(mode) },
            setAutoShareEnabled: { [weak self] enabled in
                self?.setAutoShareEnabled(enabled)
            },
            stopAllMedia: { [weak self] in self?.requestStopAllMedia() },
            retry: { [weak self] in self?.retry() },
            stopSession: { [weak self] in self?.requestEndSession() }
        )
    )

    init(
        preferences: LiveSharePreferencesModel,
        serverEndpoint: ClipLiveShareServerEndpoint = .official,
        discovery: any CaptureContentDiscovering = ScreenCaptureContentDiscovery(),
        onSessionEnded: @escaping () -> Void,
        onMenuBarStatusChanged: @escaping (LiveShareMenuBarStatus) -> Void = { _ in }
    ) {
        self.preferences = preferences
        self.serverEndpoint = serverEndpoint
        self.discovery = discovery
        self.onSessionEnded = onSessionEnded
        self.onMenuBarStatusChanged = onMenuBarStatusChanged
        signaling = ClipLiveShareSignalingClient(
            logger: { entry in
                Self.logger.debug("\(entry.description, privacy: .public)")
            }
        )
    }

    var isActive: Bool {
        state.snapshot.phase != .idle || startupTask != nil || isEnding
    }

    func start() {
        guard startupTask == nil, !isEnding else { return }
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await beginSession()
            startupTask = nil
        }
    }

    func endForApplicationTermination() async {
        await endSession(notifyApplication: false)
    }

    func hideForApplicationTermination() {
        focusedWindowMonitor.stop()
        focusedWindowOverlay.tearDown()
        statusHUD.tearDown()
    }

    func cancelForApplicationStop() {
        fullscreenRequestGate.invalidate()
        startupTask?.cancel()
        startupTask = nil
        signalingEventTask?.cancel()
        signalingEventTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
        cursorTask?.cancel()
        cursorTask = nil
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        failureCleanupTask?.cancel()
        failureCleanupTask = nil
        captureRestartTask?.cancel()
        captureRestartTask = nil
        captureRestartRequestID = nil
        retryTask?.cancel()
        retryTask = nil
        isRetrying = false
        cancelAuthoritativeControlReplay()
        invalidateSourceTransitions()
        focusedWindowMonitor.stop()
        focusedWindowOverlay.tearDown()
        statusHUD.tearDown()
        codecChangeTask?.cancel()
        codecChangeTask = nil
        let systemAudioTask = cancelSystemAudioReconciliation()
        peerHost?.close()
        let pipeline = capturePipeline
        capturePipeline = nil
        capturePressure.removeAll()
        roomConfiguration = nil
        signalingIsAvailable = false
        cancelAdmissionTimeouts()
        pendingViewerRoutes.removeAll()
        viewerSessionIDs.removeAll()
        negotiationIDs.removeAll()
        establishedControlViewerIDs.removeAll()
        pendingSessionClosingViewerIDs.removeAll()
        Task {
            await systemAudioTask?.value
            await pipeline?.stopAll()
            await signaling.stop()
        }
        state.disconnect()
    }

    private func beginSession() async {
        do {
            try state.beginRoomReservation()
        } catch {
            return
        }
        isEnding = false
        didNotifyEnd = false
        signalingIsAvailable = false
        publish()

        settings = preferences.settings
        persistedSettingsBaseline = settings
        slotAllocation = LiveShareTrackSlotAllocation()
        do {
            accessCode = settings.accessCodeEnabled
                ? try LiveShareAccessCode.generate()
                : nil
        } catch {
            fail(code: .reservationFailed, error: error)
            return
        }
        publish()

        let events = await signaling.events()
        signalingEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                await handleSignalingEvent(event)
            }
        }

        do {
            let room = try await signaling.createRoom(at: serverEndpoint)
            guard !Task.isCancelled, !isEnding else {
                await signaling.stop()
                return
            }
            roomConfiguration = room
            try state.receiveRoom(ClipLiveSharePublicRoom(
                name: room.room,
                viewerURL: try room.viewerURL
            ))
            try installNativeRuntime()
            publish()
            focusedWindowMonitor.start()
            startSourceRefreshLoop()
            startStatisticsLoop()
            try await signaling.connect(room: room)
        } catch {
            guard !Task.isCancelled, !isEnding else { return }
            let code: LiveShareFailureCode = state.snapshot.phase == .reservingRoom
                ? .reservationFailed
                : (error is WebRTCPeerHostError ? .encoderFailed : .signalingFailed)
            fail(code: code, error: error)
        }
    }

    private func installNativeRuntime() throws {
        cancelAuthoritativeControlReplay()
        _ = cancelSystemAudioReconciliation()
        desiredSystemAudioRequest = nil
        peerHost?.close()
        guard let roomConfiguration else {
            throw LiveShareTransitionError.invalidTransition(
                from: state.snapshot.phase,
                operation: "missingRoomConfiguration"
            )
        }
        let configuration = WebRTCPeerHostConfiguration(
            iceServers: roomConfiguration.capabilities.iceServers.map {
                WebRTCICEServerConfiguration(
                    urlStrings: $0.urls,
                    username: $0.username,
                    credential: $0.credential
                )
            },
            forcesRelay: false,
            senderPolicy: LiveShareCoordinatorPolicy.senderPolicy(for: settings),
            videoCodec: webRTCVideoCodec(settings.videoCodec),
            videoEncodingMode: settings.encodingMode
        )
        let host = try WebRTCPeerHost(
            configuration: configuration,
            eventQueue: .main,
            eventHandler: { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handlePeerEvent(event)
                }
            }
        )
        peerHost = host
        capturePipeline = LiveShareCapturePipeline(
            host: host,
            eventHandler: { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handleCapturePipelineEvent(event)
                }
            }
        )
    }

    private func handleSignalingEvent(_ event: ClipLiveShareSignalingEvent) async {
        guard !isEnding else { return }
        switch event {
        case let .connecting(_, reconnectAttempt):
            if state.snapshot.phase == .reconnecting, reconnectAttempt > 0 {
                try? state.scheduleReconnect(attempt: reconnectAttempt)
                publish()
            }

        case .connected:
            signalingIsAvailable = true
            do {
                if state.snapshot.phase == .reconnecting {
                    try state.markReconnected()
                    try reconcileSharingStartIfReady()
                } else if state.snapshot.phase == .connecting {
                    try state.markSignalingConnected()
                }
                publish()
                if settings.autoShareFocusedWindows,
                   state.snapshot.sources.fullscreen == nil,
                   focusedWindow != nil {
                    shareFocusedWindow(requestedIdentifier: nil, isAutomatic: true)
                }
            } catch {
                fail(code: .signalingFailed, error: error)
            }

        case let .routeOpened(routeID):
            await beginViewerAdmission(routeID: routeID)

        case let .message(routeID, message):
            await handleSignalingMessage(message, routeID: routeID)

        case let .routeClosed(routeID, reason):
            if reason == "viewer completed signaling" {
                // The browser can observe its DataChannel opening a few
                // milliseconds before the host callback reaches MainActor.
                // A relay-controlled close reason is not proof that the host
                // channel opened. Preserve both the peer and Clip's admission
                // timeout until the native DataChannel callback confirms it.
                if var route = pendingViewerRoutes[routeID] {
                    route.progress.receiveSignalingHandoff()
                    pendingViewerRoutes[routeID] = route
                }
            } else {
                await removePendingRoute(routeID, removesPeer: true)
            }

        case let .routeRejected(routeID, _):
            await removePendingRoute(routeID, removesPeer: true)

        case let .serverError(code):
            Self.logger.error(
                "The signaling server rejected a request: \(code, privacy: .public)"
            )

        case .invalidMessageReceived:
            Self.logger.error("The signaling server sent an invalid protocol message")

        case let .disconnected(reason, willReconnect):
            signalingIsAvailable = false
            // The server routes only pending introductions. Established peers
            // continue over their encrypted WebRTC control channels.
            for routeID in pendingViewerRoutes.keys {
                let viewerID = routeID.rawValue
                peerHost?.removePeer(viewerID)
                peerNegotiation.remove(viewerID)
                negotiationIDs[viewerID] = nil
                viewerSessionIDs[viewerID] = nil
            }
            cancelAdmissionTimeouts()
            pendingViewerRoutes.removeAll()
            if willReconnect {
                // Signaling availability is independent from media state once
                // the room has connected. Keep ready/starting/sharing/stopping
                // intact so capture and P2P control remain fully operable. The
                // reconnecting domain phase is reserved for initial setup.
                if state.snapshot.phase == .connecting {
                    try? state.markConnectionLost()
                }
                publish()
            } else if reason == .reconnectExhausted {
                // A custom bounded transport may exhaust its retry policy. Do
                // not tear down an established P2P session merely because its
                // rendezvous service is unavailable; media and control already
                // travel over WebRTC. Production uses a persistent capped retry
                // policy, so it can also admit viewers after the server returns.
                if establishedControlViewerIDs.isEmpty {
                    fail(
                        code: .connectionLost,
                        technicalDescription: "Signaling reconnect attempts were exhausted."
                    )
                } else {
                    publish()
                }
            }

        case let .reconnectScheduled(attempt, _):
            if state.snapshot.phase == .reconnecting {
                try? state.scheduleReconnect(attempt: attempt)
                publish()
            }

        case .eventBufferOverflow:
            // Signaling is an admission rendezvous, not the media transport.
            // A hostile or slow introduction route must never tear down healthy
            // P2P viewers. Pending routes are already bounded and independently
            // retired by the signaling client; keep established media alive.
            Self.logger.error("The signaling event observer fell behind")
            publish()

        case .stopped:
            break
        }
    }

    private func beginViewerAdmission(routeID: ClipLiveShareRouteID) async {
        let maximumViewers = WebRTCPeerResourceLimits.clipDefault.maximumViewerCount
        guard LiveShareViewerAdmissionCapacity.canBegin(
            routeID: routeID.rawValue,
            allocatedViewerIDs: peerHost?.viewerIDs ?? [],
            pendingRouteIDs: pendingViewerRoutes.keys.map(\.rawValue),
            maximumViewers: maximumViewers
        ) else {
            await signaling.closeRoute(routeID)
            return
        }
        let sessionID = ClipLiveShareSessionID.random()
        let code = accessCode
        let challenge = ClipLiveShareAuthChallenge.random(
            sessionID: sessionID,
            accessCodeRequired: code != nil
        )
        pendingViewerRoutes[routeID] = LiveSharePendingViewerRoute(
            routeID: routeID,
            sessionID: sessionID,
            challenge: challenge,
            accessCode: code
        )
        scheduleAdmissionTimeout(for: routeID)
        do {
            try await signaling.send(.authChallenge(challenge), to: routeID)
        } catch {
            await removePendingRoute(routeID, removesPeer: true)
        }
    }

    private func handleSignalingMessage(
        _ message: ClipLiveShareInnerMessage,
        routeID: ClipLiveShareRouteID
    ) async {
        guard let route = pendingViewerRoutes[routeID],
              message.sessionID == route.sessionID else {
            await signaling.closeRoute(routeID)
            await removePendingRoute(routeID, removesPeer: true)
            return
        }
        let viewerID = routeID.rawValue
        switch message {
        case .authResponse(let response):
            await handleAuthResponse(response, route: route)

        case .answer(let answer):
            await applyRemoteAnswer(answer, viewerID: viewerID)

        case .ice(let candidate):
            await applyRemoteICE(candidate, viewerID: viewerID)

        case .sessionClosing:
            await removePendingRoute(routeID, removesPeer: true)

        default:
            await signaling.closeRoute(routeID)
            await removePendingRoute(routeID, removesPeer: true)
        }
    }

    private func handleAuthResponse(
        _ response: ClipLiveShareAuthResponse,
        route: LiveSharePendingViewerRoute
    ) async {
        let isAllowed: Bool
        if let code = route.accessCode {
            isAllowed = response.proof.map {
                ClipLiveShareAccessCodeProof.verify(
                    $0,
                    accessCode: code,
                    challenge: route.challenge.challenge,
                    sessionID: route.sessionID
                )
            } ?? false
        } else {
            isAllowed = response.proof == nil
        }

        do {
            try await signaling.send(
                .authResult(try ClipLiveShareAuthResult(
                    sessionID: route.sessionID,
                    allowed: isAllowed,
                    reason: isAllowed ? nil : "invalid-access-code"
                )),
                to: route.routeID
            )
        } catch {
            await removePendingRoute(route.routeID, removesPeer: true)
            return
        }
        guard isAllowed else {
            await signaling.closeRoute(route.routeID)
            await removePendingRoute(route.routeID, removesPeer: true)
            return
        }

        let viewerID = route.routeID.rawValue
        guard viewerSessionIDs[viewerID] == nil else {
            await signaling.closeRoute(route.routeID)
            await removePendingRoute(route.routeID, removesPeer: true)
            return
        }
        viewerSessionIDs[viewerID] = route.sessionID
        await sendOffer(to: viewerID, reoffer: false)
    }

    private func applyRemoteAnswer(
        _ answer: ClipLiveShareSessionDescription,
        viewerID: String
    ) async {
        guard answer.sessionID == viewerSessionIDs[viewerID] else {
            await rejectViewerProtocol(viewerID)
            return
        }
        // Candidates and answers from the superseded negotiation can already
        // be queued when a codec switch starts. The ordered control channel
        // makes them harmless; only the current generation may mutate WebRTC.
        guard answer.negotiationID == negotiationIDs[viewerID],
              let peerHost,
              let offerToken = peerNegotiation.tokenAwaitingAnswer(for: viewerID)
        else { return }
        do {
            try await peerHost.setRemoteAnswer(answer.sdp, for: viewerID)
            guard let pendingCandidates = peerNegotiation.completeAnswer(
                for: viewerID,
                token: offerToken
            ) else { return }
            for candidate in pendingCandidates {
                guard peerNegotiation.contains(offerToken, for: viewerID) else { return }
                try await peerHost.addRemoteICECandidate(candidate, for: viewerID)
            }
        } catch {
            guard peerNegotiation.remove(viewerID, token: offerToken) else { return }
            peerHost.removePeer(viewerID)
            logPeerFailure(error, viewerID: viewerID)
        }
    }

    private func applyRemoteICE(
        _ value: ClipLiveShareICECandidate,
        viewerID: String
    ) async {
        guard value.sessionID == viewerSessionIDs[viewerID] else {
            await rejectViewerProtocol(viewerID)
            return
        }
        guard value.negotiationID == negotiationIDs[viewerID] else { return }
        guard let lineIndex = Int32(exactly: value.sdpMLineIndex) else {
            await rejectViewerProtocol(viewerID)
            return
        }
        let candidate = WebRTCICECandidate(
            candidate: value.candidate,
            sdpMid: value.sdpMid,
            sdpMLineIndex: lineIndex
        )
        do {
            switch peerNegotiation.receiveRemoteICE(candidate, for: viewerID) {
            case .buffered:
                return
            case .ready(let ready):
                try await peerHost?.addRemoteICECandidate(ready, for: viewerID)
            case .rejected:
                await rejectViewerProtocol(viewerID)
            }
        } catch {
            logPeerFailure(error, viewerID: viewerID)
            await rejectViewerProtocol(viewerID)
        }
    }

    private func sendOffer(to viewerID: String, reoffer: Bool) async {
        guard let peerHost,
              let sessionID = viewerSessionIDs[viewerID],
              let offerToken = peerNegotiation.beginOffer(for: viewerID) else { return }
        let negotiationID = ClipLiveShareNegotiationID.random()
        negotiationIDs[viewerID] = negotiationID
        do {
            let offer = try await (reoffer
                ? peerHost.createReoffer(for: viewerID)
                : peerHost.createOffer(for: viewerID))
            guard peerNegotiation.markOfferAnswerEligible(
                for: viewerID,
                token: offerToken
            ) else { return }
            let description = try ClipLiveShareSessionDescription(
                sessionID: sessionID,
                negotiationID: negotiationID,
                sdp: offer.sdp
            )
            try await sendNegotiationMessage(
                establishedControlViewerIDs.contains(viewerID)
                    ? .codecOffer(description)
                    : .offer(description),
                viewerID: viewerID
            )
            guard let pendingCandidates = peerNegotiation.markOfferSent(
                for: viewerID,
                token: offerToken
            ) else { return }
            for candidate in pendingCandidates {
                guard peerNegotiation.contains(offerToken, for: viewerID) else { return }
                try await sendLocalICECandidate(candidate, viewerID: viewerID)
            }
        } catch {
            guard peerNegotiation.remove(viewerID, token: offerToken) else { return }
            peerHost.removePeer(viewerID)
            logPeerFailure(error, viewerID: viewerID)
        }
    }

    private func handlePeerEvent(_ event: WebRTCPeerHostEvent) async {
        if isEnding {
            switch event {
            case let .controlMessageReceived(viewerID, data, isBinary):
                handleClosingControlAcknowledgement(
                    viewerID: viewerID,
                    data: data,
                    isBinary: isBinary
                )
            case let .viewerRemoved(viewerID):
                pendingSessionClosingViewerIDs.remove(viewerID)
            default:
                break
            }
            return
        }
        switch event {
        case .viewerAdded:
            publish()

        case let .viewerRemoved(viewerID):
            peerNegotiation.remove(viewerID)
            authoritativeControlDelivery.remove(viewerID)
            viewerConnectedAt[viewerID] = nil
            negotiationIDs[viewerID] = nil
            viewerSessionIDs[viewerID] = nil
            establishedControlViewerIDs.remove(viewerID)
            pendingSessionClosingViewerIDs.remove(viewerID)
            if let routeID = try? ClipLiveShareRouteID(rawValue: viewerID),
               pendingViewerRoutes[routeID] != nil {
                admissionTimeoutTasks.removeValue(forKey: routeID)?.cancel()
                pendingViewerRoutes[routeID] = nil
                await signaling.closeRoute(routeID)
            }
            updateViewerCount()
            publish()

        case let .localICECandidate(viewerID, candidate):
            if let candidate = peerNegotiation.receiveLocalICE(
                candidate,
                for: viewerID
            ) {
                do {
                    try await sendLocalICECandidate(candidate, viewerID: viewerID)
                } catch {
                    logPeerFailure(error, viewerID: viewerID)
                }
            }

        case let .connectionStateChanged(viewerID, connectionState):
            if connectionState == .connected {
                viewerConnectedAt[viewerID] = viewerConnectedAt[viewerID] ?? Date()
            } else if connectionState == .failed || connectionState == .closed {
                viewerConnectedAt[viewerID] = nil
                peerNegotiation.remove(viewerID)
                peerHost?.removePeer(viewerID)
            }
            updateViewerCount()
            publish()

        case let .controlDataChannelStateChanged(viewerID, channelState):
            if channelState == .open {
                if let routeID = try? ClipLiveShareRouteID(rawValue: viewerID),
                   var route = pendingViewerRoutes[routeID] {
                    route.progress.openControlDataChannel()
                    if !route.progress.remainsPending {
                        admissionTimeoutTasks.removeValue(forKey: routeID)?.cancel()
                        pendingViewerRoutes[routeID] = nil
                    }
                }
                establishedControlViewerIDs.insert(viewerID)
                sendInitialControlState(to: viewerID)
                // The browser retires the introduction route from its own
                // DataChannel-open callback. Waiting for that remote readiness
                // signal avoids closing signaling before WebKit has installed
                // its control channel.
            }
            publish()

        case let .controlDataChannelDrained(viewerID):
            // A durable snapshot exhausted its short retry budget while the
            // native channel was saturated. The low-water callback grants one
            // fresh bounded replay of current state; no app payload is queued.
            authoritativeControlDelivery.recordNativeControlDrain(viewerID)
            scheduleAuthoritativeControlReplay()

        case let .controlMessageReceived(viewerID, data, isBinary):
            await handleViewerControlMessage(
                viewerID: viewerID,
                data: data,
                isBinary: isBinary
            )

        case let .negotiationNeeded(viewerID):
            await sendOffer(to: viewerID, reoffer: true)

        case .videoCodecChanged:
            publish()

        case let .error(viewerID, error):
            logPeerFailure(error, viewerID: viewerID)
        }
    }

    private func sendLocalICECandidate(
        _ candidate: WebRTCICECandidate,
        viewerID: String
    ) async throws {
        guard let sessionID = viewerSessionIDs[viewerID],
              let negotiationID = negotiationIDs[viewerID] else { return }
        let message = try ClipLiveShareICECandidate(
            sessionID: sessionID,
            negotiationID: negotiationID,
            candidate: candidate.candidate,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int(candidate.sdpMLineIndex)
        )
        try await sendNegotiationMessage(
            establishedControlViewerIDs.contains(viewerID)
                ? .codecICE(message)
                : .ice(message),
            viewerID: viewerID
        )
    }

    private func sendNegotiationMessage(
        _ message: ClipLiveShareInnerMessage,
        viewerID: String
    ) async throws {
        if establishedControlViewerIDs.contains(viewerID) {
            let data = try ClipLiveShareMessageCodec.encodeInner(message)
            guard peerHost?.sendControl(data, to: viewerID) == true else {
                throw ClipLiveShareNetworkError.sendFailed
            }
            return
        }
        guard let routeID = try? ClipLiveShareRouteID(rawValue: viewerID),
              pendingViewerRoutes[routeID] != nil else {
            throw ClipLiveShareNetworkError.routeNotFound
        }
        try await signaling.send(message, to: routeID)
    }

    private func handleViewerControlMessage(
        viewerID: String,
        data: Data,
        isBinary: Bool
    ) async {
        guard !isBinary,
              data.count <= ClipLiveShareV1.maximumInnerMessageBytes,
              let sessionID = viewerSessionIDs[viewerID],
              let message = try? ClipLiveShareMessageCodec.decodeInner(data),
              message.sessionID == sessionID else {
            peerHost?.removePeer(viewerID)
            return
        }
        switch message {
        case .codecAnswer(let answer):
            await applyRemoteAnswer(answer, viewerID: viewerID)
        case .codecICE(let candidate):
            await applyRemoteICE(candidate, viewerID: viewerID)
        case .sessionClosing:
            if pendingSessionClosingViewerIDs.remove(viewerID) == nil {
                peerHost?.removePeer(viewerID)
            }
        default:
            peerHost?.removePeer(viewerID)
        }
    }

    private func handleClosingControlAcknowledgement(
        viewerID: String,
        data: Data,
        isBinary: Bool
    ) {
        guard !isBinary,
              pendingSessionClosingViewerIDs.contains(viewerID),
              let sessionID = viewerSessionIDs[viewerID],
              let message = try? ClipLiveShareMessageCodec.decodeInner(data),
              message.sessionID == sessionID,
              case .sessionClosing = message else { return }
        pendingSessionClosingViewerIDs.remove(viewerID)
    }

    private func removePendingRoute(
        _ routeID: ClipLiveShareRouteID,
        removesPeer: Bool
    ) async {
        admissionTimeoutTasks.removeValue(forKey: routeID)?.cancel()
        pendingViewerRoutes[routeID] = nil
        let viewerID = routeID.rawValue
        guard !establishedControlViewerIDs.contains(viewerID) else { return }
        peerNegotiation.remove(viewerID)
        negotiationIDs[viewerID] = nil
        viewerSessionIDs[viewerID] = nil
        if removesPeer {
            peerHost?.removePeer(viewerID)
        }
    }

    private func rejectViewerProtocol(_ viewerID: String) async {
        peerHost?.removePeer(viewerID)
        guard let routeID = try? ClipLiveShareRouteID(rawValue: viewerID),
              pendingViewerRoutes[routeID] != nil else { return }
        await signaling.closeRoute(routeID)
        await removePendingRoute(routeID, removesPeer: false)
    }

    private func scheduleAdmissionTimeout(for routeID: ClipLiveShareRouteID) {
        admissionTimeoutTasks.removeValue(forKey: routeID)?.cancel()
        admissionTimeoutTasks[routeID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard let self,
                  pendingViewerRoutes[routeID] != nil,
                  !establishedControlViewerIDs.contains(routeID.rawValue) else { return }
            await signaling.closeRoute(routeID)
            await removePendingRoute(routeID, removesPeer: true)
        }
    }

    private func cancelAdmissionTimeouts() {
        for task in admissionTimeoutTasks.values { task.cancel() }
        admissionTimeoutTasks.removeAll()
    }

    private func handleCapturePipelineEvent(_ event: LiveShareCapturePipelineEvent) async {
        switch event {
        case let .sourceStarted(_, source, generation):
            guard captureGenerations[source.id] == generation else { return }
            sourceStatuses[source.id] = .live
            do {
                try reconcileSharingStartIfReady()
            } catch {
                fail(code: .captureFailed, error: error)
                return
            }
            publish()

        case let .sourceStopped(_, source, generation):
            guard captureGenerations[source.id] == generation else { return }
            sourceStatuses[source.id] = nil
            publish()

        case let .sourceFailed(_, source, generation, message):
            guard captureGenerations[source.id] == generation else { return }
            await handleUnexpectedSourceFailure(source, message: message)

        case let .systemAudioFailed(message):
            await handleSystemAudioFailure(message)
        }
    }

    private func focusedWindowDidChange(_ value: FocusedLiveShareWindow?) {
        focusedWindow = value
        if let value {
            let windowID = LiveShareWindowID(rawValue: value.window.id)
            windowsByID[windowID] = value.window
            applicationPathsByWindowID[windowID] = NSRunningApplication(
                processIdentifier: value.window.processID
            )?.bundleURL?.path
        }

        guard state.snapshot.sources.fullscreen == nil else {
            publish()
            return
        }

        let sourceID = value.map {
            LiveShareSourceID.window(LiveShareWindowID(rawValue: $0.window.id))
        }
        if let sourceID, state.snapshot.sources.contains(sourceID) {
            if case let .window(windowID) = sourceID {
                let change = state.markWindowAsMostRecentlyUsed(windowID)
                _ = try? slotAllocation.apply(change)
            }
            slotAllocation.focus(sourceID)
            broadcastFocusChange()
        } else {
            slotAllocation.focus(nil)
            broadcastFocusChange()
        }
        publish()

        if settings.autoShareFocusedWindows, let value {
            shareFocusedWindow(
                requestedIdentifier: LiveShareCoordinatorPolicy.sourceIdentifier(
                    .window(LiveShareWindowID(rawValue: value.window.id))
                ),
                isAutomatic: true
            )
        }
    }

    private func shareFocusedWindow(
        requestedIdentifier: String?,
        isAutomatic: Bool = false
    ) {
        guard !isEnding,
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing,
              let focusedWindow else { return }
        requestShareWindow(
            focusedWindow.window,
            requestedIdentifier: requestedIdentifier,
            isAutomatic: isAutomatic
        )
    }

    private func shareWindow(identifier: String) {
        guard case let .window(windowID)? = LiveShareCoordinatorPolicy.sourceID(
            from: identifier
        ), let targetWindow = windowsByID[windowID] else { return }
        requestShareWindow(
            targetWindow,
            requestedIdentifier: identifier,
            isAutomatic: false
        )
    }

    private func requestShareWindow(
        _ targetWindow: ShareableCaptureWindow,
        requestedIdentifier: String?,
        isAutomatic: Bool
    ) {
        let windowID = LiveShareWindowID(rawValue: targetWindow.id)
        if isAutomatic {
            latestAutomaticWindowID = windowID
        }
        enqueueSourceTransition { coordinator in
            if isAutomatic, coordinator.latestAutomaticWindowID != windowID {
                return
            }
            await coordinator.performShareWindow(
                targetWindow,
                requestedIdentifier: requestedIdentifier,
                isAutomatic: isAutomatic
            )
        }
    }

    private func performShareWindow(
        _ targetWindow: ShareableCaptureWindow,
        requestedIdentifier: String?,
        isAutomatic: Bool
    ) async {
        guard !isEnding,
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing,
              ShareableApplicationWindowEligibility.isEligible(
                  targetWindow,
                  minimumPointSize: CGSize(width: 100, height: 100)
              ) else { return }
        let windowID = LiveShareWindowID(rawValue: targetWindow.id)
        let sourceID = LiveShareSourceID.window(windowID)
        if let requestedIdentifier,
           requestedIdentifier != LiveShareCoordinatorPolicy.sourceIdentifier(sourceID) {
            return
        }
        if isAutomatic {
            guard settings.autoShareFocusedWindows,
                  latestAutomaticWindowID == windowID,
                  state.snapshot.sources.fullscreen == nil else { return }
        }
        let source = LiveShareSource.window(LiveShareWindowSource(
            id: windowID,
            windowName: targetWindow.title,
            appName: targetWindow.applicationName
        ))
        if state.snapshot.sources.contains(sourceID) {
            if isAutomatic {
                await retainOnlyAutomaticWindow(source)
            }
            slotAllocation.focus(sourceID)
            broadcastFocusChange()
            publish()
            return
        }
        guard permitsWindowShare(sourceID) else {
            NSSound.beep()
            publish()
            return
        }
        if let fullscreen = state.snapshot.sources.fullscreen {
            await stopSource(.fullscreen(fullscreen.id))
        }
        guard !isEnding,
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing else { return }
        _ = await startSource(
            source,
            window: targetWindow,
            display: nil,
            replacesExistingWindows: isAutomatic
        )
    }

    private func retainOnlyAutomaticWindow(_ source: LiveShareSource) async {
        guard case let .window(window) = source else { return }
        let oldAllocation = slotAllocation
        let change = state.replaceWindows(with: window)
        guard change.changed else { return }
        do {
            try slotAllocation.apply(change)
        } catch {
            fail(code: .captureFailed, error: error)
            return
        }
        for removed in change.removed {
            if let oldSlot = oldAllocation.slot(for: removed.id) {
                await stopCaptureOnly(source: removed, slot: oldSlot.index)
            }
        }
    }

    private func permitsWindowShare(_ sourceID: LiveShareSourceID) -> Bool {
        let sources = state.snapshot.sources
        return LiveShareCoordinatorPolicy.permitsWindowShare(
            isAlreadyShared: sources.contains(sourceID),
            hasFullscreenSource: sources.fullscreen != nil,
            activeWindowCount: sources.windows.count,
            autoShareEnabled: settings.autoShareFocusedWindows
        )
    }

    /// Serializes manual additions and exclusive auto-share replacements across
    /// suspension points so capture teardown and stable slot reuse cannot race.
    private func enqueueSourceTransition(
        _ operation: @escaping @MainActor (LiveShareCoordinator) async -> Void
    ) {
        let previous = sourceTransitionTask
        let pendingCodecChange = codecChangeTask
        let taskID = UUID()
        let generation = sourceTransitionGeneration
        sourceTransitionTaskID = taskID
        sourceTransitionTask = Task { @MainActor [weak self] in
            await previous?.value
            await pendingCodecChange?.value
            guard let self,
                  !Task.isCancelled,
                  sourceTransitionGeneration == generation,
                  !isEnding else { return }
            await operation(self)
            if sourceTransitionTaskID == taskID {
                sourceTransitionTaskID = nil
                sourceTransitionTask = nil
            }
        }
    }

    private func invalidateSourceTransitions() {
        sourceTransitionGeneration &+= 1
        sourceTransitionTask?.cancel()
        sourceTransitionTask = nil
        sourceTransitionTaskID = nil
        latestAutomaticWindowID = nil
    }

    private func setFullscreenEnabled(_ enabled: Bool) {
        let request = fullscreenRequestGate.begin(isEnabled: enabled)
        enqueueSourceTransition { coordinator in
            defer {
                coordinator.fullscreenRequestGate.finish(request)
            }
            guard coordinator.fullscreenRequestGate.contains(request) else { return }
            if enabled {
                await coordinator.startFullscreen(request: request)
            } else if let fullscreen = coordinator.state.snapshot.sources.fullscreen {
                await coordinator.stopSource(.fullscreen(fullscreen.id))
                guard coordinator.fullscreenRequestGate.contains(request) else { return }
                if coordinator.settings.autoShareFocusedWindows,
                   coordinator.focusedWindow != nil {
                    coordinator.shareFocusedWindow(
                        requestedIdentifier: nil,
                        isAutomatic: true
                    )
                }
            }
        }
    }

    private func startFullscreen(
        request: LiveShareFullscreenRequestGate.Request
    ) async {
        guard !isEnding,
              fullscreenRequestGate.contains(request),
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing else { return }
        do {
            let content = try await discovery.shareableContent(
                excludingBundleIdentifier: ApplicationDirectories.bundleIdentifier
            )
            guard fullscreenRequestGate.contains(request), !isEnding else { return }
            guard let display = LiveShareCoordinatorPolicy.preferredFullscreenDisplay(
                from: content.displays,
                focusedWindowFrame: focusedWindow?.window.frame,
                primaryDisplayID: CGMainDisplayID()
            ) else {
                throw CaptureSessionError.displayUnavailable(CGMainDisplayID())
            }

            var knownWindows = windowsByID
            for window in content.windows {
                knownWindows[LiveShareWindowID(rawValue: window.id)] = window
            }
            let rollbackPlan = LiveShareCoordinatorPolicy.fullscreenRollbackPlan(
                sources: state.snapshot.sources,
                slots: slotAllocation,
                knownWindows: knownWindows
            )
            let previousStartedAt = startedAt
            let hadActiveSources = !state.snapshot.sources.isEmpty
            if !state.snapshot.sources.isEmpty {
                await stopAllMedia()
            }
            guard !isEnding else { return }
            switch fullscreenRequestGate.actionAfterDestructiveStop(for: request) {
            case .continueToFullscreen:
                break
            case .restoreWindows:
                await completeFullscreenRollback(
                    from: rollbackPlan,
                    request: request,
                    previousStartedAt: previousStartedAt,
                    hadActiveSources: hadActiveSources
                )
                return
            case .abandon:
                return
            }

            let displayID = LiveShareDisplayID(rawValue: display.id)
            let displayName = screen(for: display.id)?.localizedName
                ?? String(localized: "Main Display")
            let source = LiveShareSource.fullscreen(LiveShareDisplaySource(
                id: displayID,
                displayName: displayName
            ))
            displayFramesByID[displayID] = screen(for: display.id)?.frame ?? display.frame
            let didStart = await startSource(
                source,
                window: nil,
                display: display,
                failsSessionWhenNoSources: false
            )
            guard !isEnding else { return }
            let postStartAction = fullscreenRequestGate.actionAfterDestructiveStop(
                for: request
            )
            if didStart {
                if postStartAction == .restoreWindows {
                    await stopSource(source.id)
                    await completeFullscreenRollback(
                        from: rollbackPlan,
                        request: request,
                        previousStartedAt: previousStartedAt,
                        hadActiveSources: hadActiveSources
                    )
                }
                return
            }

            guard state.snapshot.phase != .failed else { return }
            switch postStartAction {
            case .continueToFullscreen:
                if hadActiveSources {
                    await completeFullscreenRollback(
                        from: rollbackPlan,
                        request: request,
                        previousStartedAt: previousStartedAt,
                        hadActiveSources: true
                    )
                } else {
                    fail(
                        code: .captureFailed,
                        technicalDescription: "Fullscreen capture could not start."
                    )
                }
            case .restoreWindows:
                await completeFullscreenRollback(
                    from: rollbackPlan,
                    request: request,
                    previousStartedAt: previousStartedAt,
                    hadActiveSources: hadActiveSources
                )
            case .abandon:
                return
            }
        } catch {
            guard fullscreenRequestGate.contains(request) else { return }
            // Discovery and target selection happen before any existing media
            // is stopped. Keep those healthy sources live when fullscreen
            // cannot even be prepared.
            if state.snapshot.sources.isEmpty {
                fail(code: .captureFailed, error: error)
            } else {
                Self.logger.error(
                    "Fullscreen capture could not be prepared: \(error.localizedDescription, privacy: .public)"
                )
                NSSound.beep()
                publish()
            }
        }
    }

    private func completeFullscreenRollback(
        from plan: LiveShareFullscreenRollbackPlan,
        request: LiveShareFullscreenRequestGate.Request,
        previousStartedAt: Date?,
        hadActiveSources: Bool
    ) async {
        guard hadActiveSources,
              fullscreenRequestGate.permitsWindowRollback(for: request),
              !isEnding else { return }
        let didRestore = await restoreWindowShares(
            from: plan,
            request: request,
            previousStartedAt: previousStartedAt
        )
        guard fullscreenRequestGate.permitsWindowRollback(for: request),
              !isEnding else { return }
        if !didRestore {
            fail(
                code: .captureFailed,
                technicalDescription: "Fullscreen capture failed and the previous window shares could not be restored."
            )
        }
    }

    private func restoreWindowShares(
        from plan: LiveShareFullscreenRollbackPlan,
        request: LiveShareFullscreenRequestGate.Request,
        previousStartedAt: Date?
    ) async -> Bool {
        guard !plan.isEmpty else { return false }
        var restoredAny = false
        for entry in plan.windows {
            guard fullscreenRequestGate.permitsWindowRollback(for: request), !isEnding else {
                return restoredAny
            }
            let restored = await startSource(
                .window(entry.source),
                window: entry.window,
                display: nil,
                failsSessionWhenNoSources: false
            )
            guard fullscreenRequestGate.permitsWindowRollback(for: request), !isEnding else {
                return restoredAny || restored
            }
            restoredAny = restoredAny || restored
        }

        guard restoredAny else { return false }
        if let focusedSourceID = plan.focusedSourceID,
           state.snapshot.sources.contains(focusedSourceID) {
            slotAllocation.focus(focusedSourceID)
        }
        startedAt = previousStartedAt ?? startedAt
        broadcastFocusChange()
        updateCursorLoop()
        publish()
        return true
    }

    @discardableResult
    private func startSource(
        _ source: LiveShareSource,
        window: ShareableCaptureWindow?,
        display: ShareableCaptureDisplay?,
        failsSessionWhenNoSources: Bool = true,
        replacesExistingWindows: Bool = false
    ) async -> Bool {
        let sourceID = source.id
        guard !sourceOperationIDs.contains(sourceID),
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing else {
            return false
        }
        sourceOperationIDs.insert(sourceID)
        defer { sourceOperationIDs.remove(sourceID) }

        let oldAllocation = slotAllocation
        let change: LiveShareSourceChange
        if replacesExistingWindows, case let .window(windowSource) = source {
            change = state.replaceWindows(with: windowSource)
        } else {
            change = state.addSource(source)
        }
        do {
            try slotAllocation.apply(change)
        } catch {
            _ = state.removeSource(sourceID)
            if failsSessionWhenNoSources && state.snapshot.sources.isEmpty {
                fail(code: .captureFailed, error: error)
            } else {
                Self.logger.error(
                    "A Live Share source could not be allocated: \(error.localizedDescription, privacy: .public)"
                )
                publish()
            }
            return false
        }

        for removed in change.removed {
            if let oldSlot = oldAllocation.slot(for: removed.id) {
                await stopCaptureOnly(source: removed, slot: oldSlot.index)
            }
        }

        guard let slot = slotAllocation.slot(for: sourceID) else {
            _ = state.removeSource(sourceID)
            if failsSessionWhenNoSources && state.snapshot.sources.isEmpty {
                fail(
                    code: .captureFailed,
                    technicalDescription: "No stable WebRTC slot was assigned."
                )
            } else {
                Self.logger.error("No stable WebRTC slot was assigned.")
                publish()
            }
            return false
        }

        let generation = UUID()
        captureGenerations[sourceID] = generation
        do {
            let descriptor = try makeDescriptor(
                for: source,
                slot: slot,
                window: window,
                display: display
            )
            captureDescriptors[sourceID] = descriptor
            sourceStatuses[sourceID] = .starting
            if state.snapshot.phase == .ready {
                try state.beginSharing()
            }
            publish()
            try await capturePipeline?.start(
                descriptor,
                inSlot: slot.index,
                generation: generation
            )
            guard captureGenerations[sourceID] == generation else { return false }
            sourceStatuses[sourceID] = .live
            slotAllocation.focus(sourceID)
            try reconcileSharingStartIfReady()
            broadcastAuthoritativeControlMutation()
            broadcastFocusChange()
            updateCursorLoop()
            publish()
            return true
        } catch {
            guard captureGenerations[sourceID] == generation,
                  state.snapshot.sources.contains(sourceID) else {
                return false
            }
            captureGenerations[sourceID] = nil
            captureDescriptors[sourceID] = nil
            sourceStatuses[sourceID] = nil
            let removal = state.removeSource(sourceID)
            _ = try? slotAllocation.apply(removal)
            if failsSessionWhenNoSources && state.snapshot.sources.isEmpty {
                fail(code: .captureFailed, error: error)
            } else {
                Self.logger.error(
                    "A Live Share source failed: \(error.localizedDescription, privacy: .public)"
                )
                publish()
            }
            return false
        }
    }

    /// Completes the first-source transition only when capture is actually
    /// live. This keeps reconnect-during-start distinct from an established
    /// share and also reconsiders the latest focus that may have changed while
    /// source startup was suspended.
    private func reconcileSharingStartIfReady() throws {
        guard state.snapshot.phase == .starting,
              sourceStatuses.values.contains(.live) else { return }
        try state.markSharingStarted()
        startedAt = startedAt ?? Date()
        broadcastAuthoritativeControlMutation()
        if settings.autoShareFocusedWindows,
           state.snapshot.sources.fullscreen == nil,
           focusedWindow != nil {
            shareFocusedWindow(requestedIdentifier: nil, isAutomatic: true)
        }
    }

    private func makeDescriptor(
        for source: LiveShareSource,
        slot: LiveShareTrackSlot,
        window: ShareableCaptureWindow?,
        display: ShareableCaptureDisplay?
    ) throws -> LiveShareCaptureDescriptor {
        let width: Int
        let height: Int
        let target: CaptureTarget
        let windowName: String
        let appName: String

        switch source {
        case let .window(windowSource):
            guard let window, window.id == windowSource.id.rawValue else {
                throw CaptureSessionError.windowUnavailable(windowSource.id.rawValue)
            }
            width = window.pixelWidth
            height = window.pixelHeight
            target = .window(id: window.id)
            windowName = windowSource.windowName
            appName = windowSource.appName
            windowsByID[windowSource.id] = window

        case let .fullscreen(displaySource):
            guard let display, display.id == displaySource.id.rawValue else {
                throw CaptureSessionError.displayUnavailable(displaySource.id.rawValue)
            }
            width = display.pixelWidth
            height = display.pixelHeight
            target = .display(
                id: display.id,
                excludedBundleIdentifier: ApplicationDirectories.bundleIdentifier
            )
            windowName = displaySource.displayName
            appName = String(localized: "Fullscreen")
        }

        let geometry = LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: width,
            sourceHeight: height,
            codec: settings.videoCodec,
            framesPerSecond: settings.frameRate.rawValue
        )
        let streamGeometry = LiveShareCoordinatorPolicy.streamGeometry(
            captureGeometry: geometry,
            codec: settings.videoCodec
        )
        guard let browserTrackID = peerHost?.slotSnapshots
            .first(where: { $0.index == slot.index })?.trackID else {
            throw LiveShareTransitionError.invalidTransition(
                from: state.snapshot.phase,
                operation: "missingWebRTCTrack"
            )
        }
        let stream = try ClipLiveShareStreamDescriptor(
            id: slot.streamIdentity,
            mediaTrackID: ClipLiveShareMediaTrackID(rawValue: browserTrackID),
            active: true,
            focused: slot.isFocused,
            appName: appName,
            windowName: windowName,
            width: streamGeometry.width,
            height: streamGeometry.height,
            order: slot.index
        )
        return LiveShareCaptureDescriptor(
            source: source,
            target: target,
            sourcePixelWidth: width,
            sourcePixelHeight: height,
            video: LiveShareCoordinatorPolicy.captureVideoConfiguration(
                width: geometry.width,
                height: geometry.height,
                framesPerSecond: settings.frameRate.rawValue,
                showsCursor: true
            ),
            stream: stream
        )
    }

    private func stopSource(identifier: String) {
        guard let sourceID = LiveShareCoordinatorPolicy.sourceID(from: identifier) else { return }
        enqueueSourceTransition { coordinator in
            await coordinator.stopSource(sourceID)
        }
    }

    private func stopSource(_ sourceID: LiveShareSourceID) async {
        guard sourceStatuses[sourceID] != .stopping,
              let slot = slotAllocation.slot(for: sourceID),
              let source = slot.source else { return }
        sourceOperationIDs.insert(sourceID)
        sourceStatuses[sourceID] = .stopping
        publish()
        captureGenerations[sourceID] = nil
        await stopCaptureOnly(source: source, slot: slot.index)
        let change = state.removeSource(sourceID)
        _ = try? slotAllocation.apply(change)
        sourceStatuses[sourceID] = nil
        captureDescriptors[sourceID] = nil
        sourceOperationIDs.remove(sourceID)

        if state.snapshot.sources.isEmpty {
            startedAt = nil
            latestStatistics = .init()
        } else {
            slotAllocation.focus(slotAllocation.activeSlots.first?.source?.id)
            broadcastFocusChange()
        }
        updateCursorLoop()
        publish()
    }

    private func stopCaptureOnly(source: LiveShareSource, slot: Int) async {
        captureGenerations[source.id] = nil
        try? await capturePipeline?.stop(slot: slot)
        sourceStatuses[source.id] = nil
        captureDescriptors[source.id] = nil
        broadcastAuthoritativeControlMutation()
    }

    private func requestStopAllMedia() {
        fullscreenRequestGate.invalidate()
        latestAutomaticWindowID = nil
        enqueueSourceTransition { coordinator in
            await coordinator.stopAllMedia()
        }
    }

    private func stopAllMedia() async {
        guard !state.snapshot.sources.isEmpty else { return }
        if state.snapshot.phase == .starting || state.snapshot.phase == .sharing {
            try? state.beginStopping()
        }
        for slot in slotAllocation.activeSlots {
            if let source = slot.source { sourceStatuses[source.id] = .stopping }
        }
        publish()

        captureGenerations.removeAll()
        await capturePipeline?.stopAll()
        if state.snapshot.phase == .stopping {
            try? state.completeStopping()
        } else {
            _ = state.clearSources()
        }
        slotAllocation.clear()
        captureDescriptors.removeAll()
        captureGenerations.removeAll()
        sourceStatuses.removeAll()
        sourceOperationIDs.removeAll()
        startedAt = nil
        latestStatistics = .init()
        broadcastAuthoritativeControlMutation()
        updateCursorLoop()
        publish()
    }

    private func handleUnexpectedSourceFailure(
        _ source: LiveShareSource,
        message: String
    ) async {
        guard let slot = slotAllocation.slot(for: source.id) else { return }
        captureGenerations[source.id] = nil
        try? await capturePipeline?.stop(slot: slot.index)
        let removal = state.removeSource(source.id)
        _ = try? slotAllocation.apply(removal)
        sourceStatuses[source.id] = nil
        captureDescriptors[source.id] = nil
        broadcastAuthoritativeControlMutation()
        if state.snapshot.sources.isEmpty {
            fail(code: .captureFailed, technicalDescription: message)
        } else {
            if !slotAllocation.activeSlots.contains(where: \.isFocused) {
                slotAllocation.focus(slotAllocation.activeSlots.first?.source?.id)
            }
            broadcastFocusChange()
            Self.logger.error("A Live Share capture stopped: \(message, privacy: .public)")
            publish()
        }
    }

    private func setAccessCodeEnabled(_ enabled: Bool) {
        Task { @MainActor [weak self] in
            await self?.updateAccessCode(enabled: enabled)
        }
    }

    private func replaceAccessCode() {
        Task { @MainActor [weak self] in
            await self?.updateAccessCode(enabled: true)
        }
    }

    private func updateAccessCode(enabled: Bool) async {
        guard !isEnding,
              !accessCodeIsUpdating,
              state.snapshot.room != nil,
              [.ready, .starting, .sharing].contains(state.snapshot.phase) else { return }
        accessCodeIsUpdating = true
        accessCodeError = nil
        publish()
        do {
            let updatedCode = enabled ? try LiveShareAccessCode.generate() : nil
            guard !isEnding else { return }
            settings.accessCodeEnabled = enabled
            accessCode = updatedCode
            persistSettings()
            // Replacing or disabling the code is a revocation boundary for
            // viewers still in admission. Established P2P viewers remain;
            // pending browsers reconnect and receive a fresh challenge using
            // the new setting.
            for routeID in Array(pendingViewerRoutes.keys) {
                await signaling.closeRoute(routeID)
                await removePendingRoute(routeID, removesPeer: true)
            }
        } catch {
            accessCodeError = String(localized: "Couldn’t update the access code. Try again.")
            Self.logger.error(
                "Could not update the Live Share access code: \(error.localizedDescription, privacy: .public)"
            )
        }
        accessCodeIsUpdating = false
        publish()
    }

    private func setQuality(_ quality: LiveShareQualityPreset) {
        settings.quality = quality
        applySenderPolicyAndPersist()
    }

    private func setSystemAudioEnabled(_ enabled: Bool) {
        settings.systemAudioEnabled = enabled
        persistSettings()
        publish()
    }

    private func scheduleSystemAudioReconciliation() {
        guard let pipeline = capturePipeline else {
            desiredSystemAudioRequest = nil
            return
        }
        let domain = state.snapshot
        let supportsActiveCapture = !isEnding && [
            LiveSharePhase.ready,
            .starting,
            .sharing,
            .reconnecting,
        ].contains(domain.phase)
        let request = LiveShareCoordinatorPolicy.captureAudioRequest(
            systemAudioEnabled: settings.systemAudioEnabled && supportsActiveCapture,
            sources: domain.sources,
            knownWindows: windowsByID,
            filterDisplayID: CGMainDisplayID(),
            clipBundleIdentifier: ApplicationDirectories.bundleIdentifier,
            requestIdentifier: systemAudioRequestIdentifier
        )
        guard request != desiredSystemAudioRequest else { return }
        desiredSystemAudioRequest = request

        let previous = systemAudioReconcileTask
        let taskID = UUID()
        systemAudioReconcileTaskID = taskID
        systemAudioReconcileTask = Task { @MainActor [weak self] in
            // Enabling and filter changes stay ordered, but a disable must
            // preempt an in-flight ScreenCaptureKit start/update immediately.
            // The pipeline's retirement gate then drains that older operation
            // without allowing another audio sample onto the sender.
            if request != nil {
                await previous?.value
            }
            guard let self,
                  !Task.isCancelled,
                  systemAudioReconcileTaskID == taskID,
                  desiredSystemAudioRequest == request,
                  capturePipeline === pipeline else { return }
            if request == nil {
                setAuthoritativeSystemAudioActive(false)
            }
            do {
                try await pipeline.setSystemAudio(request)
                guard systemAudioReconcileTaskID == taskID,
                      desiredSystemAudioRequest == request,
                      capturePipeline === pipeline else { return }
                setAuthoritativeSystemAudioActive(request != nil)
            } catch {
                guard systemAudioReconcileTaskID == taskID,
                      desiredSystemAudioRequest == request else { return }
                await handleSystemAudioFailure(error.localizedDescription)
            }
            if systemAudioReconcileTaskID == taskID {
                systemAudioReconcileTaskID = nil
                systemAudioReconcileTask = nil
            }
        }
    }

    private func handleSystemAudioFailure(_ message: String) async {
        Self.logger.error(
            "Live Share system audio stopped: \(message, privacy: .public)"
        )
        guard settings.systemAudioEnabled else { return }
        settings.systemAudioEnabled = false
        desiredSystemAudioRequest = nil
        setAuthoritativeSystemAudioActive(false)
        try? await capturePipeline?.setSystemAudio(nil)
        persistSettings()
        NSSound.beep()
        publish()
    }

    private func setAuthoritativeSystemAudioActive(_ isActive: Bool) {
        guard systemAudioIsActive != isActive else { return }
        systemAudioIsActive = isActive
        broadcastAuthoritativeControlMutation()
    }

    @discardableResult
    private func cancelSystemAudioReconciliation() -> Task<Void, Never>? {
        let task = systemAudioReconcileTask
        task?.cancel()
        systemAudioReconcileTask = nil
        systemAudioReconcileTaskID = nil
        desiredSystemAudioRequest = nil
        systemAudioIsActive = false
        return task
    }

    private func setFrameRate(_ frameRate: LiveShareFrameRate) {
        guard codecChangeTask == nil,
              availableFrameRates.contains(frameRate) else { return }
        let oldFrameRate = settings.frameRate
        settings.frameRate = frameRate
        applySenderPolicyAndPersist()
        if oldFrameRate != frameRate, !state.snapshot.sources.isEmpty {
            scheduleActiveCaptureRestart()
        }
    }

    private func requestVideoCodecChange(_ codec: LiveShareVideoCodec) {
        guard codec != settings.videoCodec, codecChangeTask == nil else { return }
        guard let host = peerHost else {
            settings.videoCodec = codec
            persistSettings()
            publish()
            return
        }

        let previousCodec = settings.videoCodec
        let pendingSourceTransition = sourceTransitionTask
        let pendingCaptureRestart = captureRestartTask
        codecChangeTask = Task { @MainActor [weak self, weak host] in
            await pendingSourceTransition?.value
            await pendingCaptureRestart?.value
            guard let self, let host else { return }
            guard !Task.isCancelled,
                  !isEnding,
                  peerHost === host,
                  settings.videoCodec == previousCodec else {
                codecChangeTask = nil
                publish()
                return
            }
            let reservedSourceIDs = Set(slotAllocation.activeSlots.compactMap(\.source?.id))
            sourceOperationIDs.formUnion(reservedSourceIDs)
            defer {
                sourceOperationIDs.subtract(reservedSourceIDs)
                if captureDescriptors.values.contains(where: {
                    $0.video.framesPerSecond != settings.frameRate.rawValue
                }) {
                    scheduleActiveCaptureRestart()
                }
            }
            do {
                try await performVideoCodecChange(
                    from: previousCodec,
                    to: codec,
                    host: host
                )
                guard !Task.isCancelled,
                      !isEnding,
                      peerHost === host else { return }
                settings.videoCodec = codec
                persistSettings()
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.error(
                    "Could not change the Live Share codec: \(error.localizedDescription, privacy: .public)"
                )
                if LiveShareCaptureGeometryFailurePolicy.requiresSessionFailure(
                    after: error
                ) {
                    // A failed rollback means codec and capture geometry can
                    // no longer be proven coherent. Quiesce the complete room
                    // instead of leaving an oversized buffer on H.264 and
                    // presenting another black-screen session as live.
                    fail(code: .captureFailed, error: error)
                }
            }
            codecChangeTask = nil
            publish()
        }
        publish()
    }

    /// Couples codec renegotiation to ScreenCaptureKit geometry without ever
    /// presenting an unsupported 5K/6K buffer to VideoToolbox. The safe order
    /// differs by direction: cap before enabling H.264; enable any software
    /// codec before restoring native pixels. Either failure returns capture
    /// and codec to the previous coherent pair.
    private func performVideoCodecChange(
        from previousCodec: LiveShareVideoCodec,
        to codec: LiveShareVideoCodec,
        host: WebRTCPeerHost
    ) async throws {
        if previousCodec != .h264, codec == .h264 {
            let previousGeometry = try await transitionActiveCaptureGeometry(to: .h264)
            do {
                try await host.updateVideoCodec(.h264)
            } catch {
                do {
                    try await restoreCaptureGeometry(previousGeometry)
                } catch let rollbackError {
                    throw LiveShareCaptureGeometryTransitionError.rollbackFailed(
                        change: error.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
                }
                throw error
            }
        } else if previousCodec == .h264, codec != .h264 {
            try await host.updateVideoCodec(webRTCVideoCodec(codec))
            do {
                _ = try await transitionActiveCaptureGeometry(to: codec)
            } catch {
                do {
                    try await host.updateVideoCodec(.h264)
                } catch let rollbackError {
                    throw LiveShareCaptureGeometryTransitionError.rollbackFailed(
                        change: error.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
                }
                throw error
            }
        } else {
            try await host.updateVideoCodec(webRTCVideoCodec(codec))
        }
    }

    /// Reconfigures active ScreenCaptureKit streams in place and returns the
    /// exact descriptors needed by a later codec-negotiation rollback.
    private func transitionActiveCaptureGeometry(
        to codec: LiveShareVideoCodec
    ) async throws -> [LiveShareCaptureGeometrySnapshot] {
        guard let pipeline = capturePipeline else { return [] }
        let changes = slotAllocation.activeSlots.compactMap {
            slot -> (LiveShareCaptureGeometrySnapshot, LiveShareCaptureDescriptor)? in
            guard let source = slot.source,
                  let generation = captureGenerations[source.id],
                  let current = captureDescriptors[source.id] else { return nil }
            let requested = descriptor(
                current,
                using: codec,
                framesPerSecond: settings.frameRate.rawValue
            )
            guard current != requested else { return nil }
            return (
                LiveShareCaptureGeometrySnapshot(
                    sourceID: source.id,
                    slot: slot.index,
                    generation: generation,
                    descriptor: current
                ),
                requested
            )
        }
        guard !changes.isEmpty else { return [] }

        var applied: [LiveShareCaptureGeometrySnapshot] = []
        do {
            for (previous, requested) in changes {
                try await pipeline.update(
                    requested,
                    inSlot: previous.slot,
                    expectedGeneration: previous.generation
                )
                guard captureGenerations[previous.sourceID] == previous.generation,
                      slotAllocation.slot(for: previous.sourceID)?.index == previous.slot,
                      !isEnding else {
                    throw LiveShareCapturePipelineError.superseded(previous.slot)
                }
                captureDescriptors[previous.sourceID] = requested
                applied.append(previous)
            }
        } catch {
            do {
                try await restoreCaptureGeometry(applied.reversed())
            } catch let rollbackError {
                throw LiveShareCaptureGeometryTransitionError.rollbackFailed(
                    change: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }

        broadcastSizeChanges(for: changes.map { $0.1 })
        publish()
        return changes.map { $0.0 }
    }

    private func restoreCaptureGeometry<S: Sequence>(
        _ snapshots: S
    ) async throws where S.Element == LiveShareCaptureGeometrySnapshot {
        guard let pipeline = capturePipeline else { return }
        var restored: [LiveShareCaptureDescriptor] = []
        for snapshot in snapshots {
            guard captureGenerations[snapshot.sourceID] == snapshot.generation,
                  slotAllocation.slot(for: snapshot.sourceID)?.index == snapshot.slot,
                  !isEnding else {
                throw LiveShareCapturePipelineError.superseded(snapshot.slot)
            }
            try await pipeline.update(
                snapshot.descriptor,
                inSlot: snapshot.slot,
                expectedGeneration: snapshot.generation
            )
            captureDescriptors[snapshot.sourceID] = snapshot.descriptor
            restored.append(snapshot.descriptor)
        }
        broadcastSizeChanges(for: restored)
        publish()
    }

    private func descriptor(
        _ descriptor: LiveShareCaptureDescriptor,
        using codec: LiveShareVideoCodec,
        framesPerSecond: Int
    ) -> LiveShareCaptureDescriptor {
        let geometry = LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: descriptor.sourcePixelWidth,
            sourceHeight: descriptor.sourcePixelHeight,
            codec: codec,
            framesPerSecond: framesPerSecond
        )
        let streamGeometry = LiveShareCoordinatorPolicy.streamGeometry(
            captureGeometry: geometry,
            codec: codec
        )
        return LiveShareCaptureDescriptor(
            source: descriptor.source,
            target: descriptor.target,
            sourcePixelWidth: descriptor.sourcePixelWidth,
            sourcePixelHeight: descriptor.sourcePixelHeight,
            video: LiveShareCoordinatorPolicy.captureVideoConfiguration(
                width: geometry.width,
                height: geometry.height,
                framesPerSecond: framesPerSecond,
                showsCursor: descriptor.video.showsCursor,
                sourceRect: descriptor.video.sourceRect
            ),
            stream: try! ClipLiveShareStreamDescriptor(
                id: descriptor.stream.id,
                mediaTrackID: descriptor.stream.mediaTrackID,
                active: descriptor.stream.active,
                focused: descriptor.stream.focused,
                appName: descriptor.stream.appName,
                windowName: descriptor.stream.windowName,
                width: streamGeometry.width,
                height: streamGeometry.height,
                order: descriptor.stream.order
            )
        )
    }

    private func broadcastSizeChanges(
        for descriptors: [LiveShareCaptureDescriptor]
    ) {
        guard !descriptors.isEmpty else { return }
        broadcastAuthoritativeControlMutation()
    }

    private func setPrioritizeFocusedWindow(_ enabled: Bool) {
        settings.prioritizeFocusedWindow = enabled
        applySenderPolicyAndPersist()
    }

    private func setEncodingMode(_ mode: LiveShareEncodingMode) {
        guard codecChangeTask == nil else { return }
        settings.encodingMode = mode
        peerHost?.updateVideoEncodingMode(mode)
        applySenderPolicyAndPersist()
    }

    private func setAutoShareEnabled(_ enabled: Bool) {
        settings.autoShareFocusedWindows = enabled
        if !enabled {
            latestAutomaticWindowID = nil
        }
        persistSettings()
        publish()
        if enabled, state.snapshot.sources.fullscreen == nil, focusedWindow != nil {
            shareFocusedWindow(requestedIdentifier: nil, isAutomatic: true)
        }
    }

    private func applySenderPolicyAndPersist() {
        applyRuntimeSenderPolicies()
        persistSettings()
        publish()
    }

    private func applyRuntimeSenderPolicies() {
        let fallback = LiveShareCoordinatorPolicy.senderPolicy(for: settings)
        let policies = LiveShareCoordinatorPolicy.senderPolicies(
            for: settings,
            slots: slotAllocation
        )
        peerHost?.updateSenderPolicies(policies, fallback: fallback)
    }

    private func webRTCVideoCodec(_ codec: LiveShareVideoCodec) -> WebRTCVideoCodec {
        switch codec {
        case .h264: .h264
        case .vp8: .vp8
        case .vp9: .vp9
        case .av1: .av1
        }
    }

    private func persistSettings() {
        let value = settings
        let baseline = persistedSettingsBaseline
        persistedSettingsBaseline = value
        preferences.updateSettings { stored in
            if baseline.quality != value.quality {
                stored.quality = value.quality
            }
            if baseline.frameRate != value.frameRate {
                stored.frameRate = value.frameRate
            }
            if baseline.encodingMode != value.encodingMode {
                stored.encodingMode = value.encodingMode
            }
            if baseline.videoCodec != value.videoCodec {
                stored.videoCodec = value.videoCodec
            }
            if baseline.systemAudioEnabled != value.systemAudioEnabled {
                stored.systemAudioEnabled = value.systemAudioEnabled
            }
            if baseline.prioritizeFocusedWindow != value.prioritizeFocusedWindow {
                stored.prioritizeFocusedWindow = value.prioritizeFocusedWindow
            }
            if baseline.autoShareFocusedWindows != value.autoShareFocusedWindows {
                stored.autoShareFocusedWindows = value.autoShareFocusedWindows
            }
            if baseline.accessCodeEnabled != value.accessCodeEnabled {
                stored.accessCodeEnabled = value.accessCodeEnabled
            }
        }
    }

    private func scheduleActiveCaptureRestart() {
        let previous = captureRestartTask
        let requestID = UUID()
        captureRestartRequestID = requestID
        captureRestartTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self,
                  !Task.isCancelled,
                  captureRestartRequestID == requestID else { return }
            await restartActiveCaptures(requestID: requestID)
            if captureRestartRequestID == requestID {
                captureRestartRequestID = nil
                captureRestartTask = nil
            }
        }
    }

    private func restartActiveCaptures(requestID: UUID) async {
        guard let pipeline = capturePipeline else { return }
        let active = slotAllocation.activeSlots
        for slot in active {
            guard captureRestartRequestID == requestID, !isEnding else { return }
            guard let source = slot.source,
                  let oldDescriptor = captureDescriptors[source.id],
                  !sourceOperationIDs.contains(source.id) else { continue }
            sourceOperationIDs.insert(source.id)
            defer { sourceOperationIDs.remove(source.id) }
            let descriptor = descriptor(
                oldDescriptor,
                using: settings.videoCodec,
                framesPerSecond: settings.frameRate.rawValue
            )
            sourceStatuses[source.id] = .starting
            publish()
            guard let generation = captureGenerations[source.id] else { continue }
            do {
                try await pipeline.update(
                    descriptor,
                    inSlot: slot.index,
                    expectedGeneration: generation
                )
                guard captureGenerations[source.id] == generation,
                      slotAllocation.slot(for: source.id)?.index == slot.index,
                      state.snapshot.sources.contains(source.id),
                      !isEnding else { continue }
                captureDescriptors[source.id] = descriptor
                sourceStatuses[source.id] = .live
                if descriptor.stream.width != oldDescriptor.stream.width
                    || descriptor.stream.height != oldDescriptor.stream.height
                {
                    broadcastSizeChanges(for: [descriptor])
                }
            } catch {
                guard captureGenerations[source.id] == generation else { continue }
                await handleUnexpectedSourceFailure(
                    source,
                    message: error.localizedDescription
                )
            }
        }
        publish()
    }

    private func retry() {
        guard state.snapshot.phase == .failed, retryTask == nil else { return }
        isRetrying = true
        publish()
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await failureCleanupTask?.value
            failureCleanupTask = nil
            guard !Task.isCancelled else { return }
            await resetRuntimeForRetry()
            guard !Task.isCancelled else { return }
            isRetrying = false
            retryTask = nil
            start()
        }
    }

    private func resetRuntimeForRetry() async {
        fullscreenRequestGate.invalidate()
        invalidateSourceTransitions()
        startupTask?.cancel()
        startupTask = nil
        signalingEventTask?.cancel()
        signalingEventTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
        cursorTask?.cancel()
        cursorTask = nil
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        captureRestartTask?.cancel()
        captureRestartTask = nil
        captureRestartRequestID = nil
        codecChangeTask?.cancel()
        codecChangeTask = nil
        let systemAudioTask = cancelSystemAudioReconciliation()
        failureCleanupTask?.cancel()
        failureCleanupTask = nil
        cancelAuthoritativeControlReplay()
        focusedWindowMonitor.stop()
        await systemAudioTask?.value
        await capturePipeline?.stopAll()
        capturePipeline = nil
        peerHost?.close()
        peerHost = nil
        await signaling.stop()
        state.disconnect()
        roomConfiguration = nil
        signalingIsAvailable = false
        cancelAdmissionTimeouts()
        pendingViewerRoutes.removeAll()
        viewerSessionIDs.removeAll()
        negotiationIDs.removeAll()
        establishedControlViewerIDs.removeAll()
        pendingSessionClosingViewerIDs.removeAll()
        slotAllocation.clear()
        captureDescriptors.removeAll()
        captureGenerations.removeAll()
        sourceStatuses.removeAll()
        sourceOperationIDs.removeAll()
        viewerConnectedAt.removeAll()
        peerNegotiation.removeAll()
        latestStatistics = .init()
        capturePressure.removeAll()
        startedAt = nil
        isEnding = false
        publish()
    }

    private func requestEndSession() {
        Task { @MainActor [weak self] in
            await self?.endSession(notifyApplication: true)
        }
    }

    private func endSession(notifyApplication: Bool) async {
        guard !isEnding else { return }
        isEnding = true
        fullscreenRequestGate.invalidate()
        invalidateSourceTransitions()
        startupTask?.cancel()
        startupTask = nil
        publish()
        focusedWindowMonitor.stop()
        statisticsTask?.cancel()
        statisticsTask = nil
        cursorTask?.cancel()
        cursorTask = nil
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        captureRestartTask?.cancel()
        captureRestartTask = nil
        captureRestartRequestID = nil
        codecChangeTask?.cancel()
        codecChangeTask = nil
        let systemAudioTask = cancelSystemAudioReconciliation()
        retryTask?.cancel()
        retryTask = nil
        isRetrying = false
        signalingEventTask?.cancel()
        signalingEventTask = nil
        let failureCleanup = failureCleanupTask
        failureCleanupTask = nil
        failureCleanup?.cancel()
        await failureCleanup?.value
        cancelAuthoritativeControlReplay()
        await systemAudioTask?.value

        await sendSessionClosing(reason: "host-ended-session")
        captureGenerations.removeAll()
        await capturePipeline?.stopAll()
        capturePipeline = nil
        peerHost?.close()
        peerHost = nil
        await signaling.stop()
        focusedWindowOverlay.tearDown()
        statusHUD.tearDown()
        state.disconnect()
        slotAllocation.clear()
        captureDescriptors.removeAll()
        captureGenerations.removeAll()
        sourceStatuses.removeAll()
        sourceOperationIDs.removeAll()
        viewerConnectedAt.removeAll()
        peerNegotiation.removeAll()
        roomConfiguration = nil
        signalingIsAvailable = false
        cancelAdmissionTimeouts()
        pendingViewerRoutes.removeAll()
        viewerSessionIDs.removeAll()
        negotiationIDs.removeAll()
        establishedControlViewerIDs.removeAll()
        pendingSessionClosingViewerIDs.removeAll()
        startedAt = nil
        latestStatistics = .init()
        capturePressure.removeAll()
        isEnding = false
        publish()

        if notifyApplication, !didNotifyEnd {
            didNotifyEnd = true
            onSessionEnded()
        }
    }

    private func startStatisticsLoop() {
        statisticsTask?.cancel()
        statisticsTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await refreshStatistics()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func startSourceRefreshLoop() {
        sourceRefreshTask?.cancel()
        sourceRefreshTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await refreshActiveSources()
                do {
                    try await Task.sleep(for: .milliseconds(750))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshActiveSources() async {
        guard !isEnding else { return }
        let content: ShareableCaptureContent
        do {
            content = try await discovery.shareableContent(
                excludingBundleIdentifier: ApplicationDirectories.bundleIdentifier
            )
        } catch {
            Self.logger.debug(
                "Could not refresh active Live Share sources: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard !Task.isCancelled, !isEnding else { return }

        let refreshedWindows = content.windows.filter {
            ShareableApplicationWindowEligibility.isEligible(
                $0,
                minimumPointSize: CGSize(width: 100, height: 100)
            )
        }
        for window in refreshedWindows {
            let windowID = LiveShareWindowID(rawValue: window.id)
            windowsByID[windowID] = window
            applicationPathsByWindowID[windowID] = NSRunningApplication(
                processIdentifier: window.processID
            )?.bundleURL?.path
        }
        if availableWindows != refreshedWindows {
            availableWindows = refreshedWindows
            publish()
        }
        guard !slotAllocation.activeSlots.isEmpty else { return }

        for slot in slotAllocation.activeSlots {
            guard let source = slot.source,
                  slotAllocation.slot(for: source.id)?.index == slot.index,
                  !sourceOperationIDs.contains(source.id) else { continue }
            switch source {
            case let .window(windowSource):
                guard let window = content.windows.first(where: {
                    $0.id == windowSource.id.rawValue
                }) else {
                    await stopSource(source.id)
                    continue
                }
                windowsByID[windowSource.id] = window
                applicationPathsByWindowID[windowSource.id] = NSRunningApplication(
                    processIdentifier: window.processID
                )?.bundleURL?.path
                guard let descriptor = captureDescriptors[source.id],
                      descriptor.sourcePixelWidth != window.pixelWidth
                        || descriptor.sourcePixelHeight != window.pixelHeight else {
                    continue
                }
                await restartSourceForGeometryChange(
                    source,
                    slot: slot,
                    window: window,
                    display: nil
                )

            case let .fullscreen(displaySource):
                guard let display = content.displays.first(where: {
                    $0.id == displaySource.id.rawValue
                }) else {
                    await stopSource(source.id)
                    continue
                }
                displayFramesByID[displaySource.id] = screen(for: display.id)?.frame
                    ?? display.frame
                guard let descriptor = captureDescriptors[source.id],
                      descriptor.sourcePixelWidth != display.pixelWidth
                        || descriptor.sourcePixelHeight != display.pixelHeight else {
                    continue
                }
                await restartSourceForGeometryChange(
                    source,
                    slot: slot,
                    window: nil,
                    display: display
                )
            }
        }
    }

    private func restartSourceForGeometryChange(
        _ source: LiveShareSource,
        slot: LiveShareTrackSlot,
        window: ShareableCaptureWindow?,
        display: ShareableCaptureDisplay?
    ) async {
        guard !sourceOperationIDs.contains(source.id),
              let pipeline = capturePipeline,
              let generation = captureGenerations[source.id] else { return }
        sourceOperationIDs.insert(source.id)
        defer { sourceOperationIDs.remove(source.id) }

        do {
            let descriptor = try makeDescriptor(
                for: source,
                slot: slot,
                window: window,
                display: display
            )
            captureDescriptors[source.id] = descriptor
            sourceStatuses[source.id] = .starting
            publish()
            try await pipeline.update(
                descriptor,
                inSlot: slot.index,
                expectedGeneration: generation
            )
            guard captureGenerations[source.id] == generation,
                  slotAllocation.slot(for: source.id)?.index == slot.index,
                  state.snapshot.sources.contains(source.id),
                  !isEnding else { return }
            sourceStatuses[source.id] = .live
            broadcastAuthoritativeControlMutation()
            publish()
            if descriptor.video.framesPerSecond != settings.frameRate.rawValue {
                scheduleActiveCaptureRestart()
            }
        } catch {
            guard captureGenerations[source.id] == generation else { return }
            await handleUnexpectedSourceFailure(
                source,
                message: error.localizedDescription
            )
        }
    }

    private func refreshStatistics() async {
        await refreshCaptureDeliveryStatistics()
        guard let peerHost else {
            latestStatistics = .init()
            publish()
            return
        }
        do {
            let outbound = try await peerHost.outboundSenderStatisticsSnapshot()
            let streams = slotAllocation.activeSlots.compactMap { slot -> LiveShareStreamStatisticsViewSnapshot? in
                guard let source = slot.source,
                      let descriptor = captureDescriptors[source.id],
                      let outboundSlot = outbound.slots.first(where: { $0.slot == slot.index }) else {
                    return nil
                }
                let captureStatistics = capturePressure.statistics(
                    for: source.id,
                    generation: captureGenerations[source.id]
                )
                let senderPolicy = peerHost.senderPolicy(forSlot: slot.index)
                return LiveShareStreamStatisticsViewSnapshot(
                    id: slot.trackID,
                    name: descriptor.stream.appName,
                    width: descriptor.stream.width,
                    height: descriptor.stream.height,
                    deliveredFramesPerSecond: outboundSlot.deliveredFramesPerSecond ?? 0,
                    bitsPerSecond: max(
                        0,
                        Int((outboundSlot.aggregateBitrateBps ?? 0).rounded())
                    ),
                    targetBitsPerSecond: outboundSlot.aggregateTargetBitrateBps.map {
                        max(0, Int($0.rounded()))
                    },
                    configuredBitrateCeiling: LiveShareCoordinatorPolicy
                        .aggregateConfiguredBitrateCeiling(
                            perViewer: senderPolicy.maximumBitrateBps ?? 0,
                            viewerCount: outboundSlot.viewers.count
                        ),
                    bytesSent: Int64(clamping: outboundSlot.bytesSent),
                    captureDeliveredFrames: captureStatistics?.deliveredFrames ?? 0,
                    captureBackpressureDrops: capturePressure.latestBackpressureDrops(
                        for: source.id,
                        generation: captureGenerations[source.id]
                    ),
                    encoderDroppedFrames: outboundSlot.encoderDroppedFrames,
                    averageEncodeTimeMilliseconds: outboundSlot
                        .averageEncodeTimeMilliseconds,
                    averagePacketSendDelayMilliseconds: outboundSlot
                        .averagePacketSendDelayMilliseconds,
                    qualityLimitationReasons: outboundSlot.qualityLimitationReasons,
                    codec: outboundSlot.codecs.isEmpty
                        ? nil
                        : outboundSlot.codecs.sorted().joined(separator: " / "),
                    isFocused: slot.isFocused
                )
            }
            latestStatistics = LiveShareStatisticsViewSnapshot(
                uptime: startedAt.map { Date().timeIntervalSince($0) } ?? 0,
                streams: streams,
                h264SubmissionBackpressureDrops:
                    outbound.h264SubmissionBackpressureDrops
            )
        } catch {
            Self.logger.debug(
                "Could not read WebRTC statistics: \(error.localizedDescription, privacy: .public)"
            )
        }
        updateViewerCount()
        publish()
    }

    private func refreshCaptureDeliveryStatistics() async {
        guard let pipeline = capturePipeline else {
            capturePressure.removeAll()
            return
        }
        let snapshots = await pipeline.deliveryStatisticsSnapshots()
        guard !Task.isCancelled, !isEnding, capturePipeline === pipeline else { return }

        let activeGenerations: [LiveShareSourceID: UUID] = Dictionary(
            uniqueKeysWithValues: slotAllocation.activeSlots.compactMap { slot in
                guard let source = slot.source,
                      let generation = captureGenerations[source.id] else {
                    return nil
                }
                return (source.id, generation)
            }
        )
        let currentSnapshots = snapshots.filter { snapshot in
            guard activeGenerations[snapshot.source.id] == snapshot.generation,
                  let slot = slotAllocation.slot(for: snapshot.source.id) else {
                return false
            }
            return slot.index == snapshot.slot && slot.source == snapshot.source
        }
        capturePressure.update(
            currentSnapshots,
            activeGenerations: activeGenerations
        )
    }

    private func updateCursorLoop() {
        let shouldRun = !slotAllocation.activeSlots.isEmpty
        if !shouldRun {
            cursorTask?.cancel()
            cursorTask = nil
            return
        }
        guard cursorTask == nil else { return }
        cursorTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                broadcastCursorPosition()
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }
        }
    }

    private func broadcastCursorPosition() {
        guard let focusedSlot = slotAllocation.activeSlots.first(where: { $0.isFocused }),
              let source = focusedSlot.source,
              let frame = appKitFrame(for: source.id) else { return }
        let position = LiveShareCursorNormalization.position(
            appKitCursor: NSEvent.mouseLocation,
            appKitWindowFrame: frame
        )
        guard let peerHost else { return }
        for viewerID in establishedControlViewerIDs {
            guard let sessionID = viewerSessionIDs[viewerID],
                  let message = try? ClipLiveShareInnerMessage.cursor(
                    ClipLiveShareCursor(
                        sessionID: sessionID,
                        streamID: focusedSlot.streamIdentity,
                        x: position.xPercent,
                        y: position.yPercent,
                        inView: position.isInView
                    )
                  ),
                  let data = try? ClipLiveShareMessageCodec.encodeInner(message)
            else { continue }
            _ = peerHost.sendEphemeralControl(data, to: viewerID)
        }
    }

    private func appKitFrame(for sourceID: LiveShareSourceID) -> CGRect? {
        switch sourceID {
        case let .window(windowID):
            if focusedWindow?.window.id == windowID.rawValue {
                return focusedWindow?.appKitFrame
            }
            return nil
        case let .fullscreen(displayID):
            return displayFramesByID[displayID]
        }
    }

    private func sendInitialControlState(to viewerID: String) {
        authoritativeControlDelivery.markDirty(viewerID)
        scheduleAuthoritativeControlReplay()
    }

    private func broadcastAuthoritativeControlMutation() {
        guard let peerHost else { return }
        authoritativeControlDelivery.markDirty(peerHost.viewerIDs)
        scheduleAuthoritativeControlReplay()
    }

    private func scheduleAuthoritativeControlReplay() {
        guard controlReplayTask == nil,
              !authoritativeControlDelivery.dirtyViewerIDs.isEmpty else { return }
        let taskID = UUID()
        controlReplayTaskID = taskID
        controlReplayTask = Task { @MainActor [weak self] in
            await self?.runAuthoritativeControlReplay(taskID: taskID)
        }
    }

    private func runAuthoritativeControlReplay(taskID: UUID) async {
        defer {
            if controlReplayTaskID == taskID {
                controlReplayTask = nil
                controlReplayTaskID = nil
            }
        }

        var isFirstAttempt = true
        while !Task.isCancelled,
              controlReplayTaskID == taskID,
              let peerHost {
            if !isFirstAttempt {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
            }
            isFirstAttempt = false

            let openViewerIDs = Set(peerHost.viewerSnapshots.compactMap { viewer in
                viewer.controlDataChannelState == .open ? viewer.viewerID : nil
            })
            let viewerIDs = authoritativeControlDelivery.dirtyViewerIDs.filter {
                openViewerIDs.contains($0)
                    && authoritativeControlDelivery.canReplay(to: $0)
            }
            guard !viewerIDs.isEmpty else { return }

            for viewerID in viewerIDs {
                guard !Task.isCancelled,
                      controlReplayTaskID == taskID,
                      authoritativeControlDelivery.beginReplay(for: viewerID) else {
                    continue
                }
                if sendAuthoritativeControlState(to: viewerID, using: peerHost) {
                    authoritativeControlDelivery.markReplayDelivered(to: viewerID)
                }
            }
        }
    }

    private func sendAuthoritativeControlState(
        to viewerID: String,
        using peerHost: WebRTCPeerHost
    ) -> Bool {
        guard let sessionID = viewerSessionIDs[viewerID] else { return false }
        let streams = slotAllocation.activeSlots.compactMap { streamDescriptor(for: $0) }
        let messages: [ClipLiveShareInnerMessage]
        do {
            messages = [
                .manifest(try ClipLiveShareStreamManifest(
                    sessionID: sessionID,
                    streams: streams,
                    maximumStreams: LiveShareTrackSlotAllocation.slotCount
                )),
                .sharingState(ClipLiveShareSharingState(
                    sessionID: sessionID,
                    sharing: !streams.isEmpty
                )),
                .systemAudioState(ClipLiveShareSystemAudioState(
                    sessionID: sessionID,
                    enabled: systemAudioIsActive
                )),
                .focus(ClipLiveShareFocus(
                    sessionID: sessionID,
                    streamID: slotAllocation.activeSlots
                        .first(where: { $0.isFocused })?.streamIdentity
                )),
            ]
        } catch {
            Self.logger.error(
                "Could not construct Live Share state: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        var delivered = true
        for message in messages {
            do {
                let data = try ClipLiveShareMessageCodec.encodeInner(message)
                let wasDelivered = peerHost.sendControl(data, to: viewerID)
                if !wasDelivered {
                    delivered = false
                }
            } catch {
                delivered = false
            }
        }
        return delivered
    }

    private func cancelAuthoritativeControlReplay() {
        controlReplayTaskID = nil
        controlReplayTask?.cancel()
        controlReplayTask = nil
        authoritativeControlDelivery.removeAll()
    }

    private func broadcastFocusChange() {
        applyRuntimeSenderPolicies()
        broadcastAuthoritativeControlMutation()
    }

    private func streamDescriptor(
        for slot: LiveShareTrackSlot
    ) -> ClipLiveShareStreamDescriptor? {
        guard let source = slot.source,
              let descriptor = captureDescriptors[source.id] else { return nil }
        return try? ClipLiveShareStreamDescriptor(
            id: slot.streamIdentity,
            mediaTrackID: descriptor.stream.mediaTrackID,
            active: true,
            focused: slot.isFocused,
            appName: descriptor.stream.appName,
            windowName: descriptor.stream.windowName,
            width: descriptor.stream.width,
            height: descriptor.stream.height,
            order: slot.index
        )
    }

    private func sendSessionClosing(reason: String) async {
        guard let peerHost else { return }
        let openViewerIDs = Set(peerHost.viewerSnapshots.compactMap { viewer in
            viewer.controlDataChannelState == .open ? viewer.viewerID : nil
        })
        pendingSessionClosingViewerIDs = establishedControlViewerIDs
            .intersection(openViewerIDs)
        for viewerID in Array(pendingSessionClosingViewerIDs) {
            guard let sessionID = viewerSessionIDs[viewerID],
                  let closing = try? ClipLiveShareSessionClosing(
                    sessionID: sessionID,
                    reason: reason
                  ),
                  let data = try? ClipLiveShareMessageCodec.encodeInner(
                    .sessionClosing(closing)
                  ) else { continue }
            if !peerHost.sendControl(data, to: viewerID) {
                pendingSessionClosingViewerIDs.remove(viewerID)
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while !pendingSessionClosingViewerIDs.isEmpty, clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                break
            }
        }
        pendingSessionClosingViewerIDs.removeAll()
    }

    private func updateViewerCount() {
        try? state.updateViewerCount(peerHost?.connectedViewerCount ?? 0)
    }

    private func fail(code: LiveShareFailureCode, error: any Error) {
        fail(code: code, technicalDescription: error.localizedDescription)
    }

    private func fail(code: LiveShareFailureCode, technicalDescription: String) {
        Self.logger.error("Live Share failed: \(technicalDescription, privacy: .public)")
        invalidateSourceTransitions()
        state.fail(LiveShareFailure(
            code: code,
            technicalDescription: technicalDescription
        ))
        publish()
        guard failureCleanupTask == nil else { return }
        failureCleanupTask = Task { @MainActor [weak self] in
            await self?.quiesceFailedRuntime()
            self?.failureCleanupTask = nil
        }
    }

    private func quiesceFailedRuntime() async {
        fullscreenRequestGate.invalidate()
        invalidateSourceTransitions()
        focusedWindowMonitor.stop()
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        captureRestartTask?.cancel()
        captureRestartTask = nil
        captureRestartRequestID = nil
        codecChangeTask?.cancel()
        codecChangeTask = nil
        let systemAudioTask = cancelSystemAudioReconciliation()
        statisticsTask?.cancel()
        statisticsTask = nil
        cursorTask?.cancel()
        cursorTask = nil
        signalingEventTask?.cancel()
        signalingEventTask = nil
        cancelAuthoritativeControlReplay()
        await systemAudioTask?.value
        await sendSessionClosing(reason: "host-failed")
        captureGenerations.removeAll()
        await capturePipeline?.stopAll()
        capturePipeline = nil
        peerHost?.close()
        peerHost = nil
        await signaling.stop()
        focusedWindowOverlay.tearDown()
        statusHUD.tearDown()
        _ = state.clearSources()
        slotAllocation.clear()
        captureDescriptors.removeAll()
        sourceStatuses.removeAll()
        sourceOperationIDs.removeAll()
        viewerConnectedAt.removeAll()
        peerNegotiation.removeAll()
        roomConfiguration = nil
        signalingIsAvailable = false
        cancelAdmissionTimeouts()
        pendingViewerRoutes.removeAll()
        viewerSessionIDs.removeAll()
        negotiationIDs.removeAll()
        establishedControlViewerIDs.removeAll()
        pendingSessionClosingViewerIDs.removeAll()
        latestStatistics = .init()
        capturePressure.removeAll()
        startedAt = nil
        publish()
    }

    private func logPeerFailure(_ error: any Error, viewerID: String?) {
        if let viewerID {
            Self.logger.error(
                "Viewer \(viewerID, privacy: .private(mask: .hash)) failed: \(error.localizedDescription, privacy: .public)"
            )
        } else {
            Self.logger.error(
                "A WebRTC peer failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        publish()
    }

    private func publish() {
        scheduleSystemAudioReconciliation()
        let snapshot = makeViewSnapshot()
        presentationModel.update(snapshot)
        renderOverlays(snapshot)
        let menuBarStatus = LiveShareCoordinatorPolicy.menuBarStatus(for: snapshot.phase)
        if publishedMenuBarStatus != menuBarStatus {
            publishedMenuBarStatus = menuBarStatus
            onMenuBarStatusChanged(menuBarStatus)
        }
    }

    private func makeViewSnapshot() -> LiveShareViewSnapshot {
        let domain = state.snapshot
        let now = Date()
        let phase: LiveShareViewPhase
        if isEnding {
            phase = .stopping
        } else if isRetrying {
            phase = .connecting
        } else {
            switch domain.phase {
            case .idle:
                phase = .inactive
            case .reservingRoom:
                phase = .reservingRoom
            case .connecting:
                phase = .connecting
            case .ready:
                phase = .ready
            case .starting:
                phase = .starting
            case .sharing:
                phase = .live(elapsedSeconds: startedAt.map { now.timeIntervalSince($0) } ?? 0)
            case .reconnecting:
                phase = .reconnecting(
                    attempt: min(
                        domain.reconnectAttempt,
                        LiveShareCoordinatorPolicy.maximumReconnectAttempts
                    ),
                    maximumAttempts: LiveShareCoordinatorPolicy.maximumReconnectAttempts
                )
            case .stopping:
                phase = .stopping
            case .failed:
                phase = .failed(message: LiveShareCoordinatorPolicy.userFacingFailure(domain.failure))
            }
        }

        let roomIsClaimed = [.ready, .starting, .sharing, .reconnecting, .stopping]
            .contains(domain.phase)
        let room = roomIsClaimed ? domain.room.map {
            LiveShareRoomViewSnapshot(
                viewerURL: $0.viewerURL,
                roomCode: $0.name.rawValue,
                isAvailable: signalingIsAvailable
            )
        } : nil
        let sources = slotAllocation.activeSlots.compactMap { slot -> LiveShareSourceViewSnapshot? in
            guard case let .window(windowSource)? = slot.source else { return nil }
            return LiveShareSourceViewSnapshot(
                id: LiveShareCoordinatorPolicy.sourceIdentifier(.window(windowSource.id)),
                slotIndex: slot.index,
                applicationName: windowSource.appName,
                windowTitle: windowSource.windowName,
                applicationPath: applicationPathsByWindowID[windowSource.id],
                status: sourceStatuses[.window(windowSource.id)] ?? .live,
                isFocused: slot.isFocused,
                canStop: sourceStatuses[.window(windowSource.id)] != .stopping
            )
        }
        let slots = slotAllocation.slots.map { slot in
            LiveShareSourceSlotViewSnapshot(
                index: slot.index,
                state: slot.source.map {
                    sourceStatuses[$0.id] == .starting ? .starting : .live
                } ?? .empty
            )
        }
        let fullscreenSource = domain.sources.fullscreen
        let fullscreen = LiveShareFullscreenViewSnapshot(
            isOn: fullscreenSource != nil,
            displayName: fullscreenSource?.displayName
                ?? preferredOverlayScreen()?.localizedName
                ?? String(localized: "Main Display"),
            isEnabled: [.ready, .sharing].contains(domain.phase) && !isEnding,
            detail: !domain.sources.windows.isEmpty
                ? String(localized: "Starting fullscreen stops the current window shares.")
                : nil
        )
        let focusedDescription = focusedWindow.map {
            [$0.window.applicationName, $0.window.title]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        let viewerSnapshots = peerHost?.viewerSnapshots ?? []
        let viewers = viewerSnapshots.map { viewer in
            LiveShareViewerViewSnapshot(
                id: viewer.viewerID,
                connection: LiveShareCoordinatorPolicy.viewerConnection(
                    from: viewer.connectionState,
                    route: viewer.route
                ),
                connectedDuration: viewerConnectedAt[viewer.viewerID].map {
                    now.timeIntervalSince($0)
                }
            )
        }
        let canOperateSources = !isEnding && [.ready, .sharing].contains(domain.phase)
        let canChangeSettings = !isEnding
            && [.ready, .starting, .sharing].contains(domain.phase)
        let activeWindowIDs = Set(domain.sources.windows.map(\.id))
        let focusedSourceID = focusedWindow.map {
            LiveShareSourceID.window(LiveShareWindowID(rawValue: $0.window.id))
        }
        let availableWindowSnapshots = availableWindows
            .filter { !activeWindowIDs.contains(LiveShareWindowID(rawValue: $0.id)) }
            .map { window in
                LiveShareAvailableWindowViewSnapshot(
                    id: LiveShareCoordinatorPolicy.sourceIdentifier(
                        .window(LiveShareWindowID(rawValue: window.id))
                    ),
                    applicationName: window.applicationName,
                    windowTitle: window.title.isEmpty
                        ? String(localized: "Untitled Window")
                        : window.title,
                    applicationPath: NSRunningApplication(
                        processIdentifier: window.processID
                    )?.bundleURL?.path
                )
            }
        let overloadedSourceNames = slotAllocation.activeSlots.compactMap { slot -> String? in
            guard let source = slot.source,
                  capturePressure.isOverloaded(
                    source.id,
                    generation: captureGenerations[source.id]
                  ) else {
                return nil
            }
            switch source {
            case let .window(window):
                return window.appName
            case let .fullscreen(display):
                return display.displayName
            }
        }
        let capturePressureWarning = overloadedSourceNames.isEmpty
            ? nil
            : LiveShareCapturePressureWarningSnapshot(sourceNames: overloadedSourceNames)
        return LiveShareViewSnapshot(
            phase: phase,
            room: room,
            accessCodeEnabled: settings.accessCodeEnabled,
            accessCode: accessCode,
            canChangeAccessCode: [.ready, .starting, .sharing].contains(domain.phase)
                && !isEnding
                && !accessCodeIsUpdating
                && room != nil,
            accessCodeError: accessCodeError,
            sources: sources,
            slots: slots,
            fullscreen: fullscreen,
            canShareFocusedWindow: canOperateSources
                && focusedSourceID.map(permitsWindowShare) == true,
            focusedWindowDescription: focusedDescription,
            availableWindows: availableWindowSnapshots,
            canAddWindow: canOperateSources
                && !settings.autoShareFocusedWindows
                && !availableWindowSnapshots.isEmpty
                && (fullscreenSource != nil
                    || domain.sources.windows.count < LiveShareSourceSelection.maximumWindowCount),
            settings: LiveShareSettingsViewSnapshot(
                quality: settings.quality,
                frameRate: settings.frameRate,
                codec: .init(
                    codec: settings.videoCodec,
                    acceleration: settings.videoCodec == .h264 ? .hardware : .software
                ),
                systemAudioEnabled: settings.systemAudioEnabled,
                prioritizeFocusedWindow: settings.prioritizeFocusedWindow,
                mode: settings.encodingMode,
                autoShareFocusedWindows: settings.autoShareFocusedWindows,
                canChangeQuality: canChangeSettings,
                canChangeFrameRate: canChangeSettings && codecChangeTask == nil,
                availableFrameRates: availableFrameRates,
                canChangeCodec: canChangeSettings && codecChangeTask == nil,
                canChangeSystemAudio: canChangeSettings,
                canChangePrioritizeFocusedWindow: canChangeSettings,
                canChangeMode: canChangeSettings && codecChangeTask == nil,
                canChangeAutoShare: canOperateSources && fullscreenSource == nil
            ),
            viewers: viewers,
            connectedViewerCount: peerHost?.connectedViewerCount ?? 0,
            statistics: latestStatistics,
            capturePressureWarning: capturePressureWarning
        )
    }

    private var availableFrameRates: Set<LiveShareFrameRate> {
        var result: Set<LiveShareFrameRate> = [.fifteen, .thirty]
        if NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 30 >= 60 {
            result.insert(.sixty)
        }
        return result
    }

    private func renderOverlays(_ snapshot: LiveShareViewSnapshot) {
        let showsSessionOverlays: Bool
        switch snapshot.phase {
        case .ready, .starting, .live, .reconnecting:
            showsSessionOverlays = true
        default:
            showsSessionOverlays = false
        }
        guard showsSessionOverlays,
              let visibleFrame = preferredOverlayScreen()?.visibleFrame else {
            focusedWindowOverlay.hide()
            statusHUD.hide()
            return
        }
        statusHUD.show(
            snapshot: LiveShareStatusHUDSnapshot(viewSnapshot: snapshot),
            visibleScreenFrame: visibleFrame
        )

        let showsFocusedWindowControl: Bool
        switch snapshot.phase {
        case .ready, .starting, .live:
            showsFocusedWindowControl = true
        default:
            showsFocusedWindowControl = false
        }
        guard showsFocusedWindowControl,
              !snapshot.fullscreen.isOn,
              let focusedWindow else {
            focusedWindowOverlay.hide()
            return
        }
        let sourceID = LiveShareSourceID.window(
            LiveShareWindowID(rawValue: focusedWindow.window.id)
        )
        guard permitsWindowShare(sourceID) else {
            focusedWindowOverlay.hide()
            return
        }
        let overlayState: FocusedWindowShareOverlayState
        switch sourceStatuses[sourceID] {
        case .starting:
            overlayState = .starting
        case .stopping:
            overlayState = .stopping
        case .live, .failed:
            overlayState = .live
        case nil:
            overlayState = state.snapshot.sources.contains(sourceID) ? .live : .shareable
        }
        let targetScreen = screen(containing: focusedWindow.appKitFrame)
        focusedWindowOverlay.show(
            snapshot: FocusedWindowShareOverlaySnapshot(
                sourceID: LiveShareCoordinatorPolicy.sourceIdentifier(sourceID),
                applicationName: focusedWindow.window.applicationName,
                windowTitle: focusedWindow.window.title,
                state: overlayState
            ),
            targetWindowFrame: focusedWindow.appKitFrame,
            visibleScreenFrame: targetScreen?.visibleFrame ?? visibleFrame
        )
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
    }

    private func preferredOverlayScreen() -> NSScreen? {
        if let fullscreen = state.snapshot.sources.fullscreen,
           let sharedScreen = screen(for: fullscreen.id.rawValue) {
            return sharedScreen
        }
        if let focusedWindow,
           let focusedScreen = screen(containing: focusedWindow.appKitFrame) {
            return focusedScreen
        }
        return screen(for: CGMainDisplayID()) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func screen(containing frame: CGRect) -> NSScreen? {
        let candidate = NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.frame, frame) < intersectionArea(rhs.frame, frame)
        }
        guard let candidate, intersectionArea(candidate.frame, frame) > 0 else { return nil }
        return candidate
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.standardized.intersection(rhs.standardized)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
