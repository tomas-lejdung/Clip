import AppKit
import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import OSLog

@MainActor
final class LiveShareCoordinator {
    nonisolated private static let logger = Logger(
        subsystem: ApplicationDirectories.bundleIdentifier,
        category: "live-share"
    )

    private let settingsRepository: LiveShareSettingsRepository
    private let server: GoPeepV1ServerConfiguration
    private let signaling: GoPeepV1SignalingClient
    private let discovery: any CaptureContentDiscovering
    private let showsClickHighlights: () -> Bool
    private let onSessionEnded: () -> Void
    private let onMenuBarStatusChanged: (LiveShareMenuBarStatus) -> Void

    private var state = LiveShareStateMachine()
    private var settings = LiveShareSettings.default
    private var slotAllocation = LiveShareTrackSlotAllocation()
    private var accessCode: String?
    private var accessCodeIsUpdating = false
    private var accessCodeError: String?
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
    private var settingsSaveTask: Task<Void, Never>?
    private var sourceTransitionTask: Task<Void, Never>?
    private var sourceTransitionTaskID: UUID?
    private var sourceTransitionGeneration = 0
    private var latestAutomaticWindowID: LiveShareWindowID?
    private var fullscreenRequestGate = LiveShareFullscreenRequestGate()
    private var retryTask: Task<Void, Never>?
    private var isRetrying = false
    private var isEnding = false
    private var didNotifyEnd = false
    private var nextViewerNumber = 1
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
            setAdaptiveBitrateEnabled: { [weak self] enabled in
                self?.setAdaptiveBitrateEnabled(enabled)
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
        applicationSupportDirectory: URL,
        server: GoPeepV1ServerConfiguration = .goPeepRemote,
        discovery: any CaptureContentDiscovering = ScreenCaptureContentDiscovery(),
        showsClickHighlights: @escaping () -> Bool,
        onSessionEnded: @escaping () -> Void,
        onMenuBarStatusChanged: @escaping (LiveShareMenuBarStatus) -> Void = { _ in }
    ) throws {
        settingsRepository = try LiveShareSettingsRepository(
            applicationSupportDirectory: applicationSupportDirectory
        )
        self.server = server
        self.discovery = discovery
        self.showsClickHighlights = showsClickHighlights
        self.onSessionEnded = onSessionEnded
        self.onMenuBarStatusChanged = onMenuBarStatusChanged
        signaling = GoPeepV1SignalingClient(
            server: server,
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
        peerHost?.close()
        let pipeline = capturePipeline
        capturePipeline = nil
        capturePressure.removeAll()
        Task {
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
        publish()

        do {
            settings = try await settingsRepository.load()
        } catch {
            settings = .default
            Self.logger.error(
                "Could not load Live Share settings: \(error.localizedDescription, privacy: .public)"
            )
        }
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
            let reservation = try await signaling.reserveRoom()
            guard !Task.isCancelled, !isEnding else { return }
            try state.receiveReservation(reservation, password: accessCode)
            try installNativeRuntime()
            publish()
            focusedWindowMonitor.start()
            startSourceRefreshLoop()
            startStatisticsLoop()
            guard let room = state.snapshot.room else {
                throw LiveShareTransitionError.invalidTransition(
                    from: state.snapshot.phase,
                    operation: "missingRoomAfterReservation"
                )
            }
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
        peerHost?.close()
        let configuration = WebRTCPeerHostConfiguration(
            iceServers: server.iceServers.map {
                WebRTCICEServerConfiguration(
                    urlStrings: $0.urls,
                    username: $0.username,
                    credential: $0.credential
                )
            },
            forcesRelay: server.forceRelay,
            senderPolicy: LiveShareCoordinatorPolicy.senderPolicy(for: settings)
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

    private func handleSignalingEvent(_ event: GoPeepV1SignalingEvent) async {
        guard !isEnding else { return }
        switch event {
        case let .connecting(_, reconnectAttempt):
            if state.snapshot.phase == .reconnecting, reconnectAttempt > 0 {
                try? state.scheduleReconnect(attempt: reconnectAttempt)
                publish()
            }

        case .connected:
            // The WebSocket has only accepted the join frame. `joined` below is
            // the server-authoritative transition to Ready.
            break

        case let .message(message):
            await handleSignalingMessage(message)

        case .invalidMessageReceived:
            Self.logger.error("The signaling server sent invalid JSON")

        case let .disconnected(reason, willReconnect):
            for viewerID in peerHost?.viewerIDs ?? [] {
                peerHost?.removePeer(viewerID)
            }
            peerNegotiation.removeAll()
            cancelAuthoritativeControlReplay()
            viewerConnectedAt.removeAll()
            try? state.updateViewerCount(0)
            if willReconnect {
                if state.snapshot.phase != .reconnecting {
                    try? state.markConnectionLost()
                }
                publish()
            } else if reason == .reconnectExhausted {
                fail(
                    code: .connectionLost,
                    technicalDescription: "Signaling reconnect attempts were exhausted."
                )
            }

        case let .reconnectScheduled(attempt, _):
            if state.snapshot.phase == .reconnecting {
                try? state.scheduleReconnect(attempt: attempt)
                publish()
            }

        case .eventBufferOverflow:
            fail(
                code: .signalingFailed,
                technicalDescription: "The signaling event queue overflowed."
            )

        case .stopped:
            break
        }
    }

    private func handleSignalingMessage(_ message: GoPeepV1Message) async {
        switch message.type {
        case .joined:
            guard message.role == .sharer else { return }
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

        case .viewerJoined:
            let viewerID = "viewer-\(nextViewerNumber)"
            nextViewerNumber += 1
            await sendOffer(to: viewerID, reoffer: false)

        case .viewerReoffer:
            guard !message.peerID.isEmpty else { return }
            // GoPeep emits viewer-reoffer when the browser has created a new
            // RTCPeerConnection but wants to retain its peer ID. A fresh native
            // peer/data channel is required; renegotiating the stale connection
            // would send media to the browser instance that already went away.
            peerHost?.removePeer(message.peerID, notifies: false)
            peerNegotiation.remove(message.peerID)
            authoritativeControlDelivery.remove(message.peerID)
            viewerConnectedAt[message.peerID] = nil
            await sendOffer(to: message.peerID, reoffer: false)

        case .answer, .renegotiateAnswer:
            guard !message.peerID.isEmpty, !message.sdp.isEmpty else { return }
            guard let peerHost,
                  let offerToken = peerNegotiation.tokenAwaitingAnswer(
                for: message.peerID
            ) else { return }
            do {
                try await peerHost.setRemoteAnswer(message.sdp, for: message.peerID)
                guard let pendingCandidates = peerNegotiation.completeAnswer(
                    for: message.peerID,
                    token: offerToken
                ) else { return }
                for candidate in pendingCandidates {
                    guard peerNegotiation.contains(
                        offerToken,
                        for: message.peerID
                    ) else { return }
                    try await peerHost.addRemoteICECandidate(
                        candidate,
                        for: message.peerID
                    )
                }
            } catch {
                guard peerNegotiation.remove(
                    message.peerID,
                    token: offerToken
                ) else { return }
                peerHost.removePeer(message.peerID)
                logPeerFailure(error, viewerID: message.peerID)
            }

        case .ice:
            guard !message.peerID.isEmpty,
                  let data = message.candidate.data(using: .utf8) else { return }
            do {
                let candidate = try JSONDecoder().decode(WebRTCICECandidate.self, from: data)
                if let candidate = peerNegotiation.receiveRemoteICE(
                    candidate,
                    for: message.peerID
                ) {
                    try await peerHost?.addRemoteICECandidate(candidate, for: message.peerID)
                }
            } catch {
                logPeerFailure(error, viewerID: message.peerID)
            }

        case .error:
            fail(
                code: .signalingFailed,
                technicalDescription: LiveShareCoordinatorPolicy
                    .redactedSignalingFailureDescription(
                        serverMessage: message.errorMessage
                    )
            )

        default:
            break
        }
    }

    private func sendOffer(to viewerID: String, reoffer: Bool) async {
        guard let peerHost,
              let offerToken = peerNegotiation.beginOffer(for: viewerID) else { return }
        do {
            let offer = try await (reoffer
                ? peerHost.createReoffer(for: viewerID)
                : peerHost.createOffer(for: viewerID))
            guard peerNegotiation.markOfferAnswerEligible(
                for: viewerID,
                token: offerToken
            ) else { return }
            try await signaling.send(GoPeepV1Message(
                type: .offer,
                sdp: offer.sdp,
                peerID: viewerID
            ))
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
        guard !isEnding else { return }
        switch event {
        case .viewerAdded:
            publish()

        case let .viewerRemoved(viewerID):
            peerNegotiation.remove(viewerID)
            authoritativeControlDelivery.remove(viewerID)
            viewerConnectedAt[viewerID] = nil
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
                sendInitialControlState(to: viewerID)
            }
            publish()

        case let .controlDataChannelDrained(viewerID):
            // A durable snapshot exhausted its short retry budget while the
            // native channel was saturated. The low-water callback grants one
            // fresh bounded replay of current state; no app payload is queued.
            authoritativeControlDelivery.recordNativeControlDrain(viewerID)
            scheduleAuthoritativeControlReplay()

        case .controlMessageReceived:
            // GoPeep v1 control messages are host-to-viewer only. Ignore an
            // unsolicited viewer payload rather than giving it authority.
            break

        case let .negotiationNeeded(viewerID):
            await sendOffer(to: viewerID, reoffer: true)

        case let .error(viewerID, error):
            logPeerFailure(error, viewerID: viewerID)
        }
    }

    private func sendLocalICECandidate(
        _ candidate: WebRTCICECandidate,
        viewerID: String
    ) async throws {
        let data = try JSONEncoder().encode(candidate)
        guard let encoded = String(data: data, encoding: .utf8) else { return }
        try await signaling.send(GoPeepV1Message(
            type: .ice,
            candidate: encoded,
            peerID: viewerID
        ))
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
                requestedIdentifier: requestedIdentifier
            )
        }
    }

    private func performShareWindow(
        _ targetWindow: ShareableCaptureWindow,
        requestedIdentifier: String?
    ) async {
        guard !isEnding,
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing else { return }
        let windowID = LiveShareWindowID(rawValue: targetWindow.id)
        let sourceID = LiveShareSourceID.window(windowID)
        if let requestedIdentifier,
           requestedIdentifier != LiveShareCoordinatorPolicy.sourceIdentifier(sourceID) {
            return
        }
        if state.snapshot.sources.contains(sourceID) {
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
        let source = LiveShareSource.window(LiveShareWindowSource(
            id: windowID,
            windowName: targetWindow.title,
            appName: targetWindow.applicationName
        ))
        _ = await startSource(source, window: targetWindow, display: nil)
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

    /// Serializes user and auto-share source transitions across suspension
    /// points. Per-source guards are insufficient because a fifth focused
    /// window may reuse the slot of a different source whose capture start is
    /// still suspended.
    private func enqueueSourceTransition(
        _ operation: @escaping @MainActor (LiveShareCoordinator) async -> Void
    ) {
        let previous = sourceTransitionTask
        let taskID = UUID()
        let generation = sourceTransitionGeneration
        sourceTransitionTaskID = taskID
        sourceTransitionTask = Task { @MainActor [weak self] in
            await previous?.value
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
        failsSessionWhenNoSources: Bool = true
    ) async -> Bool {
        let sourceID = source.id
        guard !sourceOperationIDs.contains(sourceID),
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing else {
            return false
        }
        sourceOperationIDs.insert(sourceID)
        defer { sourceOperationIDs.remove(sourceID) }

        let oldAllocation = slotAllocation
        let change = state.addSource(source)
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
            broadcastAuthoritativeControlMutation(GoPeepV1Message(
                type: .streamActivated,
                streamActivated: streamInfo(for: slot)
            ))
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
        broadcastAuthoritativeControlMutation(GoPeepV1Message(type: .sharerStarted))
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

        let stream = GoPeepV1StreamInfo(
            trackID: slot.trackID,
            windowName: windowName,
            appName: appName,
            isFocused: slot.isFocused,
            width: LiveShareCoordinatorPolicy.videoEncoderCompatibleDimension(width),
            height: LiveShareCoordinatorPolicy.videoEncoderCompatibleDimension(height)
        )
        return LiveShareCaptureDescriptor(
            source: source,
            target: target,
            video: CaptureVideoConfiguration(
                width: width,
                height: height,
                framesPerSecond: settings.frameRate.rawValue,
                showsCursor: true,
                showsClickHighlights: showsClickHighlights()
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
        let trackID = "video\(slot)"
        broadcastAuthoritativeControlMutation(GoPeepV1Message(
            type: .streamDeactivated,
            streamDeactivated: trackID
        ))
        sourceStatuses[source.id] = nil
        captureDescriptors[source.id] = nil
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

        let activeSlots = slotAllocation.activeSlots
        captureGenerations.removeAll()
        await capturePipeline?.stopAll()
        for slot in activeSlots {
            broadcastAuthoritativeControlMutation(GoPeepV1Message(
                type: .streamDeactivated,
                streamDeactivated: slot.trackID
            ))
        }
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
        broadcastAuthoritativeControlMutation(GoPeepV1Message(
            type: .streamDeactivated,
            streamDeactivated: slot.trackID
        ))
        if state.snapshot.sources.isEmpty {
            fail(code: .captureFailed, technicalDescription: message)
        } else {
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
              let room = state.snapshot.room,
              [.ready, .starting, .sharing].contains(state.snapshot.phase) else { return }
        accessCodeIsUpdating = true
        accessCodeError = nil
        publish()
        do {
            let updatedCode = enabled ? try LiveShareAccessCode.generate() : nil
            try await signaling.send(GoPeepV1Message(
                type: .passwordUpdate,
                password: updatedCode ?? "",
                secret: room.secret
            ))
            guard !isEnding else { return }
            settings.accessCodeEnabled = enabled
            accessCode = updatedCode
            persistSettings()
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

    private func setFrameRate(_ frameRate: LiveShareFrameRate) {
        guard availableFrameRates.contains(frameRate) else { return }
        let oldFrameRate = settings.frameRate
        settings.frameRate = frameRate
        applySenderPolicyAndPersist()
        if oldFrameRate != frameRate, !state.snapshot.sources.isEmpty {
            scheduleActiveCaptureRestart()
        }
    }

    private func setAdaptiveBitrateEnabled(_ enabled: Bool) {
        settings.adaptiveBitrateEnabled = enabled
        applySenderPolicyAndPersist()
    }

    private func setEncodingMode(_ mode: LiveShareEncodingMode) {
        settings.encodingMode = mode
        applySenderPolicyAndPersist()
    }

    private func setAutoShareEnabled(_ enabled: Bool) {
        settings.autoShareFocusedWindows = enabled
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
        let fallback = LiveShareCoordinatorPolicy.senderPolicy(
            for: settings,
            isFocused: false
        )
        let policies = Dictionary(uniqueKeysWithValues: slotAllocation.slots.map { slot in
            (
                slot.index,
                LiveShareCoordinatorPolicy.senderPolicy(
                    for: settings,
                    isFocused: slot.isFocused || state.snapshot.sources.fullscreen != nil
                )
            )
        })
        peerHost?.updateSenderPolicies(policies, fallback: fallback)
    }

    private func persistSettings() {
        let repository = settingsRepository
        let value = settings
        let previous = settingsSaveTask
        settingsSaveTask = Task {
            await previous?.value
            do {
                try await repository.save(value)
            } catch {
                Self.logger.error(
                    "Could not save Live Share settings: \(error.localizedDescription, privacy: .public)"
                )
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
            var descriptor = oldDescriptor
            let video = CaptureVideoConfiguration(
                width: oldDescriptor.video.width,
                height: oldDescriptor.video.height,
                framesPerSecond: settings.frameRate.rawValue,
                showsCursor: oldDescriptor.video.showsCursor,
                showsClickHighlights: oldDescriptor.video.showsClickHighlights,
                sourceRect: oldDescriptor.video.sourceRect
            )
            descriptor = LiveShareCaptureDescriptor(
                source: oldDescriptor.source,
                target: oldDescriptor.target,
                video: video,
                stream: oldDescriptor.stream
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
        failureCleanupTask?.cancel()
        failureCleanupTask = nil
        cancelAuthoritativeControlReplay()
        focusedWindowMonitor.stop()
        await capturePipeline?.stopAll()
        capturePipeline = nil
        peerHost?.close()
        peerHost = nil
        await signaling.stop()
        state.disconnect()
        slotAllocation.clear()
        captureDescriptors.removeAll()
        captureGenerations.removeAll()
        sourceStatuses.removeAll()
        sourceOperationIDs.removeAll()
        viewerConnectedAt.removeAll()
        peerNegotiation.removeAll()
        latestStatistics = .init()
        capturePressure.removeAll()
        nextViewerNumber = 1
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

        if !state.snapshot.sources.isEmpty {
            _ = try? peerHost?.broadcastControl(GoPeepV1Message(type: .sharerStopped))
        }
        captureGenerations.removeAll()
        await capturePipeline?.stopAll()
        capturePipeline = nil
        peerHost?.close()
        peerHost = nil
        await signaling.stop()
        await settingsSaveTask?.value
        settingsSaveTask = nil
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
            $0.frame.width >= 100 && $0.frame.height >= 100
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
                      descriptor.video.width != window.pixelWidth
                        || descriptor.video.height != window.pixelHeight else {
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
                      descriptor.video.width != display.pixelWidth
                        || descriptor.video.height != display.pixelHeight else {
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
            broadcastAuthoritativeControlMutation(GoPeepV1Message(
                type: .sizeChange,
                trackID: slot.trackID,
                width: descriptor.stream.width,
                height: descriptor.stream.height
            ))
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
                    bytesSent: Int64(clamping: outboundSlot.bytesSent),
                    captureDeliveredFrames: captureStatistics?.deliveredFrames ?? 0,
                    captureBackpressureDrops: captureStatistics?.backpressureDrops ?? 0,
                    isFocused: slot.isFocused
                )
            }
            latestStatistics = LiveShareStatisticsViewSnapshot(
                uptime: startedAt.map { Date().timeIntervalSince($0) } ?? 0,
                streams: streams
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
        _ = try? peerHost?.broadcastControl(GoPeepV1Message(
            type: .cursorPosition,
            trackID: focusedSlot.trackID,
            cursorX: position.xPercent,
            cursorY: position.yPercent,
            cursorInView: position.isInView
        ))
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

    private func broadcastAuthoritativeControlMutation(_ message: GoPeepV1Message) {
        guard let peerHost else { return }
        do {
            let delivery = try peerHost.broadcastControl(message)
            authoritativeControlDelivery.recordLifecycleDelivery(delivery)
        } catch {
            authoritativeControlDelivery.markDirty(peerHost.viewerIDs)
            Self.logger.debug(
                "Could not encode Live Share control state: \(error.localizedDescription, privacy: .public)"
            )
        }
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
        let streams = slotAllocation.activeSlots.compactMap { streamInfo(for: $0) }
        var messages = [GoPeepV1Message(type: .streamsInfo, streams: streams)]

        // GoPeep's current viewer treats activation/deactivation as the fast
        // path that mutates its active-track set. Replaying all four stable
        // slots makes the streams-info snapshot authoritative even if an older
        // delta was lost.
        for slot in slotAllocation.slots {
            if let info = streamInfo(for: slot) {
                messages.append(GoPeepV1Message(
                    type: .streamActivated,
                    streamActivated: info
                ))
            } else {
                messages.append(GoPeepV1Message(
                    type: .streamDeactivated,
                    streamDeactivated: slot.trackID
                ))
            }
        }
        if !streams.isEmpty {
            messages.append(GoPeepV1Message(type: .sharerStarted))
        }
        messages.append(GoPeepV1Message(
            type: .focusChange,
            focusedTrack: slotAllocation.activeSlots
                .first(where: { $0.isFocused })?.trackID ?? ""
        ))

        var delivered = true
        for message in messages {
            do {
                let wasDelivered = try peerHost.sendControl(message, to: viewerID)
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
        let focusedTrack = slotAllocation.activeSlots.first(where: { $0.isFocused })?.trackID ?? ""
        broadcastAuthoritativeControlMutation(GoPeepV1Message(
            type: .focusChange,
            focusedTrack: focusedTrack
        ))
    }

    private func streamInfo(for slot: LiveShareTrackSlot) -> GoPeepV1StreamInfo? {
        guard let source = slot.source,
              let descriptor = captureDescriptors[source.id] else { return nil }
        return GoPeepV1StreamInfo(
            trackID: slot.trackID,
            windowName: descriptor.stream.windowName,
            appName: descriptor.stream.appName,
            isFocused: slot.isFocused,
            width: descriptor.stream.width,
            height: descriptor.stream.height
        )
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
        statisticsTask?.cancel()
        statisticsTask = nil
        cursorTask?.cancel()
        cursorTask = nil
        signalingEventTask?.cancel()
        signalingEventTask = nil
        cancelAuthoritativeControlReplay()
        if !state.snapshot.sources.isEmpty {
            _ = try? peerHost?.broadcastControl(GoPeepV1Message(type: .sharerStopped))
        }
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
                    attempt: domain.reconnectAttempt,
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
                viewerURL: server.viewerURL(for: $0.room),
                roomCode: $0.room.rawValue
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
                codec: .init(),
                adaptiveBitrate: settings.adaptiveBitrateEnabled,
                mode: settings.encodingMode,
                autoShareFocusedWindows: settings.autoShareFocusedWindows,
                canChangeQuality: canChangeSettings,
                canChangeFrameRate: canChangeSettings,
                availableFrameRates: availableFrameRates,
                canChangeAdaptiveBitrate: canChangeSettings,
                canChangeMode: canChangeSettings,
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
