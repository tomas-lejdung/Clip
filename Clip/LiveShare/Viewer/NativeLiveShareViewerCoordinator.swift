import AppKit
import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import OSLog

enum NativeViewerSurfaceBindingError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let streamID):
            "The remote video stream \(streamID) is not available."
        }
    }
}

enum NativeViewerDeploymentConfigurationError: LocalizedError {
    case incompatibleServer

    var errorDescription: String? {
        String(localized: "The saved friend's server did not provide a valid WebRTC configuration.")
    }
}

enum NativeViewerDeploymentConfigurationResolver {
    static func load(
        endpoint: ClipLiveShareServerEndpoint,
        transport: any ClipLiveShareHTTPTransport = URLSessionClipLiveShareHTTPTransport()
    ) async throws -> WebRTCPeerViewerConfiguration {
        var request = URLRequest(url: endpoint.capabilitiesURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: ClipLiveShareHTTPResult
        do {
            response = try await transport.execute(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NativeViewerDeploymentConfigurationError.incompatibleServer
        }
        guard response.statusCode == 200,
              !response.data.isEmpty,
              response.data.count <= ClipLiveShareSignalingResourceLimits
                .maximumCapabilitiesBytes,
              let capabilities = try? JSONDecoder().decode(
                ClipLiveShareCapabilities.self,
                from: response.data
              ) else {
            throw NativeViewerDeploymentConfigurationError.incompatibleServer
        }
        return configuration(for: capabilities)
    }

    static func configuration(
        for capabilities: ClipLiveShareCapabilities
    ) -> WebRTCPeerViewerConfiguration {
        WebRTCPeerViewerConfiguration(
            iceServers: capabilities.iceServers.map {
                WebRTCICEServerConfiguration(
                    urlStrings: $0.urls,
                    username: $0.username,
                    credential: $0.credential
                )
            }
        )
    }
}

enum NativeLiveShareViewerJoinMode: Equatable, Sendable {
    case invite(String)
    case friend(NativeFriendRecord)
    case recovery(NativeFriendRecord)

    var ownerName: String {
        switch self {
        case .invite:
            String(localized: "Live Share Viewer")
        case .friend(let friend), .recovery(let friend):
            friend.displayName
        }
    }

    var ownerDeviceName: String? {
        switch self {
        case .invite:
            nil
        case .friend(let friend), .recovery(let friend):
            friend.deviceName
        }
    }

    var initialFriendship: NativeViewerFriendshipState {
        switch self {
        case .invite: .unavailable
        case .friend: .friends
        case .recovery: .pending
        }
    }

    var sendsNativeControlHello: Bool {
        switch self {
        case .invite: true
        case .friend, .recovery: false
        }
    }

    var acceptsAccessCode: Bool {
        switch self {
        case .invite: true
        case .friend, .recovery: false
        }
    }

    var permitsRequesterHandshakeRecovery: Bool {
        switch self {
        case .invite, .recovery: true
        case .friend: false
        }
    }
}

enum NativeViewerTransportPhaseEvent: Equatable, Sendable {
    case connecting
    case awaitingHostApproval
    case connected
    case disconnected
    case connectionFailed
    case controlOpened
    case controlClosed
    case closed
}

enum NativeViewerTransportPhasePolicy {
    static func phase(
        after event: NativeViewerTransportPhaseEvent,
        current: NativeViewerSessionPhase
    ) -> NativeViewerSessionPhase {
        switch event {
        case .connecting:
            .connecting
        case .awaitingHostApproval:
            .waitingForHostApproval
        case .connected:
            current == .live || current == .reconnecting ? .live : .connecting
        case .disconnected:
            .reconnecting
        case .connectionFailed:
            .failed(message: String(localized: "The peer connection closed."))
        case .controlOpened:
            .live
        case .controlClosed:
            current == .live ? .reconnecting : current
        case .closed:
            .ended(message: nil)
        }
    }
}

enum NativeViewerFriendRequestSendPolicy {
    static func shouldRollback(
        sentRequest: ClipLiveShareNativeFriendRequest,
        pendingRequest: ClipLiveShareNativeFriendRequest?,
        committedRequest: ClipLiveShareNativeFriendRequest? = nil
    ) -> Bool {
        pendingRequest?.requestID == sentRequest.requestID
            && committedRequest?.requestID != sentRequest.requestID
    }
}

enum NativeViewerFriendResponseVerifier {
    static func validateAcceptance(
        _ signed: ClipLiveShareSignedNativeFriendMessage,
        acceptance: ClipLiveShareNativeFriendAcceptance,
        request: ClipLiveShareNativeFriendRequest,
        host: ClipLiveShareNativeSessionDescriptor,
        at now: ClipLiveShareNativeTimestamp,
        replayGuard: inout ClipLiveShareNativeFriendReplayGuard
    ) throws {
        try acceptance.validate(
            for: request,
            expectedSessionDescriptor: host,
            at: now
        )
        try replayGuard.acceptSignatureOnce(
            signed,
            expectedIdentity: host.hostIdentity
        )
    }

    static func validateDecline(
        _ signed: ClipLiveShareSignedNativeFriendMessage,
        decline: ClipLiveShareNativeFriendDecline,
        request: ClipLiveShareNativeFriendRequest,
        host: ClipLiveShareNativeSessionDescriptor,
        at now: ClipLiveShareNativeTimestamp,
        replayGuard: inout ClipLiveShareNativeFriendReplayGuard
    ) throws {
        try decline.validate(for: request, at: now)
        try replayGuard.acceptSignatureOnce(
            signed,
            expectedIdentity: host.hostIdentity
        )
    }
}

@MainActor
enum NativeViewerFriendAcceptanceCommitBuilder {
    static func signedAcknowledgement(
        acceptance: ClipLiveShareNativeFriendAcceptance,
        request: ClipLiveShareNativeFriendRequest,
        signer: any ClipLiveShareIdentitySigner,
        acknowledgedAt: ClipLiveShareNativeTimestamp,
        persist: (
            ClipLiveShareSignedNativeFriendMessage
        ) async throws -> Void
    ) async throws -> ClipLiveShareSignedNativeFriendMessage {
        let acknowledgement = try ClipLiveShareNativeFriendAcceptanceAcknowledgement(
            acknowledging: acceptance,
            for: request,
            acknowledgedAt: acknowledgedAt
        )
        let signed = try ClipLiveShareSignedNativeFriendMessage(
            signing: .acceptanceAcknowledged(acknowledgement),
            with: signer
        )
        // Signing creates no external state. Persist the exact statement and
        // hidden contact atomically before this value can be sent remotely.
        try await persist(signed)
        return signed
    }
}

enum NativeViewerFriendAcceptanceSendPolicy {
    static func isRetransmission(
        receivedDigest: ClipLiveShareNativeDigest,
        committedDigest: ClipLiveShareNativeDigest
    ) -> Bool {
        receivedDigest == committedDigest
    }

    static func shouldClearPendingRequest(commitReceiptAccepted: Bool) -> Bool {
        commitReceiptAccepted
    }
}

enum NativeViewerFriendCommitReceiptVerifier {
    static func validate(
        _ signed: ClipLiveShareSignedNativeFriendMessage,
        receipt: ClipLiveShareNativeFriendCommitReceipt,
        acknowledgement: ClipLiveShareNativeFriendAcceptanceAcknowledgement,
        signedAcknowledgementDigest: ClipLiveShareNativeDigest,
        acceptance: ClipLiveShareNativeFriendAcceptance,
        request: ClipLiveShareNativeFriendRequest,
        host: ClipLiveShareNativeSessionDescriptor,
        at now: ClipLiveShareNativeTimestamp
    ) throws {
        try receipt.validate(
            for: acknowledgement,
            acknowledgementDigest: signedAcknowledgementDigest,
            acceptance: acceptance,
            request: request,
            expectedSessionDescriptor: host,
            at: now
        )
        try signed.verifySignature(expectedIdentity: host.hostIdentity)
    }
}

enum NativeViewerFriendCommitReceiptValidationPolicy {
    static func validationTime(
        for receipt: ClipLiveShareNativeFriendCommitReceipt,
        isRecovery: Bool,
        wallClock: ClipLiveShareNativeTimestamp
    ) -> ClipLiveShareNativeTimestamp {
        // Recovery replays an immutable statement from the original
        // handshake. The local journal applies the separate current-time TTL.
        isRecovery ? receipt.committedAt : wallClock
    }
}

enum NativeViewerDescriptorPresentationPolicy {
    static func requiresWindowReinstallation(
        previous: ClipLiveShareNativeSessionDescriptor?,
        incoming: ClipLiveShareNativeSessionDescriptor
    ) -> Bool {
        guard let previous else { return true }
        return previous.hostIdentity != incoming.hostIdentity
            || previous.sessionID != incoming.sessionID
    }
}

enum NativeViewerSourceAuthorityPolicy {
    static func usesNativeLifecycle(
        _ state: ClipLiveShareNativeStreamLifecycleState?
    ) -> Bool {
        state?.revisionGuard.latestAcceptedRevision != nil
    }
}

private struct NativeViewerCommittedFriendAcceptance {
    let signedAcceptanceDigest: ClipLiveShareNativeDigest
    let hostDescriptor: ClipLiveShareNativeSessionDescriptor
    let request: ClipLiveShareNativeFriendRequest
    let acceptance: ClipLiveShareNativeFriendAcceptance
    let acknowledgement: ClipLiveShareNativeFriendAcceptanceAcknowledgement
    let signedAcknowledgementDigest: ClipLiveShareNativeDigest
    let friendID: String
    let handshakeID: String
    let isRecovery: Bool
    let acknowledgementData: Data
}

@MainActor
final class NativeLiveShareViewerCoordinator {
    nonisolated private static let logger = Logger(
        subsystem: ApplicationDirectories.bundleIdentifier,
        category: "live-share-viewer"
    )

    private let joinMode: NativeLiveShareViewerJoinMode
    private let identityRepository: NativeDeviceIdentityRepository
    private let nativeFriends: NativeFriendModel?
    private let localServerEndpoint: ClipLiveShareServerEndpoint
    private let onSessionEnded: () -> Void
    private let onMenuBarStatusChanged: (LiveShareMenuBarStatus) -> Void
    private var inviteSession: ClipLiveShareV1ViewerSession?
    private var friendSession: ClipLiveShareNativeFriendViewerSession?
    private var connectionTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var friendAcknowledgementRetryTask: Task<Void, Never>?
    private var resolvedInvite: ClipLiveShareV1ViewerInvite?
    private var controlState: NativeViewerV1ControlState?
    private var nativeControlState: ClipLiveShareNativeStreamLifecycleState?
    private var signedHostDescriptor: ClipLiveShareSignedNativeSessionDescriptor?
    private var localIdentity: NativeDeviceIdentity?
    private var pendingFriendRequest: ClipLiveShareNativeFriendRequest?
    private var pendingSignedFriendRequest: ClipLiveShareSignedNativeFriendMessage?
    private var committedFriendAcceptance: NativeViewerCommittedFriendAcceptance?
    private var acceptedFriendCommitReceiptDigest: ClipLiveShareNativeDigest?
    private var friendReplayGuard = try! ClipLiveShareNativeFriendReplayGuard()
    private var windowCoordinator: NativeViewerWindowCoordinator?
    private var remoteStreams: [String: WebRTCRemoteVideoStream] = [:]
    private var phase: NativeViewerSessionPhase = .connecting
    private var route: NativeViewerTransportRoute = .unknown
    private var audioTrackAvailable = false
    private var hostSystemAudioEnabled = false
    private var systemAudioEnabled = true
    private var volume = 1.0
    private var scaleMode = NativeViewerScaleMode.automatic
    private var latestStatistics = NativeViewerStatisticsSnapshot()
    private var priorStatistics: WebRTCInboundStatisticsSnapshot?
    private var isEnding = false
    private var didNotifyEnd = false
    private var friendship = NativeViewerFriendshipState.unavailable
    private var operationID = UUID()

    private(set) lazy var presentationModel = NativeViewerPresentationModel(
        snapshot: makeSnapshot(),
        actions: NativeViewerPresentationActions(
            submitAccessCode: { [weak self] value in
                self?.submitAccessCode(value)
            },
            setSystemAudioEnabled: { [weak self] enabled in
                self?.setSystemAudioEnabled(enabled)
            },
            setVolume: { [weak self] volume in self?.setVolume(volume) },
            setScaleMode: { [weak self] mode in self?.setScaleMode(mode) },
            setSourceVisible: { [weak self] id, visible in
                self?.setSourceVisible(id, visible: visible)
            },
            showAll: { [weak self] in self?.showAll() },
            requestFriendship: { [weak self] in self?.requestFriendship() },
            retry: { [weak self] in self?.retry() },
            leave: { [weak self] in self?.requestLeave() }
        )
    )

    init(
        invite: String,
        identityRepository: NativeDeviceIdentityRepository = .init(),
        nativeFriends: NativeFriendModel? = nil,
        localServerEndpoint: ClipLiveShareServerEndpoint = .official,
        onSessionEnded: @escaping () -> Void,
        onMenuBarStatusChanged: @escaping (LiveShareMenuBarStatus) -> Void = { _ in }
    ) {
        joinMode = .invite(invite)
        self.identityRepository = identityRepository
        self.nativeFriends = nativeFriends
        self.localServerEndpoint = localServerEndpoint
        self.onSessionEnded = onSessionEnded
        self.onMenuBarStatusChanged = onMenuBarStatusChanged
        friendship = joinMode.initialFriendship
    }

    init(
        friend: NativeFriendRecord,
        identityRepository: NativeDeviceIdentityRepository = .init(),
        nativeFriends: NativeFriendModel? = nil,
        localServerEndpoint: ClipLiveShareServerEndpoint = .official,
        onSessionEnded: @escaping () -> Void,
        onMenuBarStatusChanged: @escaping (LiveShareMenuBarStatus) -> Void = { _ in }
    ) {
        joinMode = friend.trustState == .pendingCommit
            ? .recovery(friend)
            : .friend(friend)
        self.identityRepository = identityRepository
        self.nativeFriends = nativeFriends
        self.localServerEndpoint = localServerEndpoint
        self.onSessionEnded = onSessionEnded
        self.onMenuBarStatusChanged = onMenuBarStatusChanged
        friendship = joinMode.initialFriendship
    }

    var isActive: Bool {
        (connectionTask != nil || eventTask != nil) && !isEnding
    }

    func start() {
        guard connectionTask == nil, eventTask == nil, !isEnding else { return }
        let operationID = UUID()
        self.operationID = operationID
        connectionTask = Task { @MainActor [weak self] in
            await self?.connect(operationID: operationID)
        }
    }

    func endForApplicationTermination() async {
        await endSession(notifyApplication: false)
    }

    func hideForApplicationTermination() {
        windowCoordinator?.tearDown()
    }

    func cancelForApplicationStop() {
        isEnding = true
        operationID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        eventTask?.cancel()
        eventTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
        friendAcknowledgementRetryTask?.cancel()
        friendAcknowledgementRetryTask = nil
        windowCoordinator?.tearDown()
        windowCoordinator = nil
        let inviteSession = inviteSession
        let friendSession = friendSession
        self.inviteSession = nil
        self.friendSession = nil
        Task {
            await inviteSession?.close()
            await friendSession?.close()
        }
    }

    private func connect(operationID: UUID) async {
        guard !isEnding, self.operationID == operationID else { return }
        defer {
            if self.operationID == operationID { connectionTask = nil }
        }
        phase = NativeViewerTransportPhasePolicy.phase(
            after: .connecting,
            current: phase
        )
        route = .unknown
        publish()
        do {
            switch joinMode {
            case .invite(let rawValue):
                guard let url = URL(string: rawValue) else {
                    throw ClipLiveShareV1ViewerSessionError.invalidInvite
                }
                let session = ClipLiveShareV1ViewerSession()
                inviteSession = session
                let events = await session.events()
                guard self.operationID == operationID, !Task.isCancelled else { return }
                eventTask = Task { @MainActor [weak self] in
                    for await event in events {
                        guard !Task.isCancelled else { return }
                        await self?.handle(event, operationID: operationID)
                    }
                }
                try await session.start(inviteURL: url)

            case .friend(let friend), .recovery(let friend):
                let identity = try await identityRepository.loadOrCreate()
                guard self.operationID == operationID, !Task.isCancelled else { return }
                localIdentity = identity
                let viewerConfiguration = try await
                    NativeViewerDeploymentConfigurationResolver.load(
                        endpoint: friend.endpoint
                    )
                guard self.operationID == operationID, !Task.isCancelled else { return }
                let target = try ClipNativeRendezvousTarget(
                    endpoint: friend.endpoint.rootURL,
                    rendezvousID: friend.rendezvousID.bytes
                )
                let session = ClipLiveShareNativeFriendViewerSession(
                    target: target,
                    expectedHostIdentity: friend.identity,
                    viewerIdentitySigner: identity.signer,
                    viewerDeviceName: Host.current().localizedName
                        ?? String(localized: "Mac"),
                    viewerConfiguration: viewerConfiguration
                )
                friendSession = session
                let events = await session.events()
                guard self.operationID == operationID, !Task.isCancelled else { return }
                eventTask = Task { @MainActor [weak self] in
                    for await event in events {
                        guard !Task.isCancelled else { return }
                        await self?.handle(event, operationID: operationID)
                    }
                }
                try await session.start()
            }
        } catch let error as ClipLiveShareV1ViewerSessionError {
            guard self.operationID == operationID, !Task.isCancelled else { return }
            fail(message: error.localizedDescription)
        } catch let error as ClipLiveShareNativeFriendViewerSessionError {
            guard self.operationID == operationID, !Task.isCancelled else { return }
            fail(message: error.localizedDescription)
        } catch is CancellationError {
            return
        } catch {
            guard self.operationID == operationID, !Task.isCancelled else { return }
            fail(message: error.localizedDescription)
        }
    }

    private func handle(
        _ event: ClipLiveShareV1ViewerSessionEvent,
        operationID: UUID
    ) async {
        guard !isEnding, self.operationID == operationID else { return }
        switch event {
        case .connecting:
            phase = NativeViewerTransportPhasePolicy.phase(
                after: .connecting,
                current: phase
            )
            publish()

        case .signalingConnected(let invite):
            resolvedInvite = invite
            publish()

        case .accessCodeRequired:
            phase = .waitingForAccessCode
            publish()

        case .authenticated(let sessionID):
            phase = .connecting
            controlState = NativeViewerV1ControlState(sessionID: sessionID)
            nativeControlState = ClipLiveShareNativeStreamLifecycleState(
                sessionID: sessionID
            )
            do {
                localIdentity = try await identityRepository.loadOrCreate()
            } catch {
                Self.logger.error(
                    "Could not load native viewer identity: \(error.localizedDescription, privacy: .public)"
                )
            }
            installWindowCoordinator(sessionID: sessionID)
            reconcileWindows()

        case .connectionStateChanged(let connectionState):
            applyConnectionState(connectionState)

        case .controlDataChannelStateChanged(let channelState):
            await applyControlChannelState(channelState)

        case .signalingHandoffCompleted:
            publish()

        case .controlMessage(let message):
            applyControlMessage(message)

        case .nativeControlMessage(let data):
            await handleNativeControlMessage(data)

        case .remoteVideoStreamAdded(let stream),
             .remoteVideoStreamUpdated(let stream):
            remoteStreams[stream.id.rawValue] = stream
            reconcileWindows()

        case .remoteVideoStreamRemoved(let streamID):
            remoteStreams[streamID.rawValue] = nil
            reconcileWindows()

        case .systemAudioTrackAvailable:
            audioTrackAvailable = true
            publish()

        case .systemAudioTrackRemoved:
            audioTrackAvailable = false
            publish()

        case .failed(let error):
            fail(message: error.localizedDescription)

        case .closed:
            if !isEnding {
                phase = NativeViewerTransportPhasePolicy.phase(
                    after: .closed,
                    current: phase
                )
                publish()
            }
        }
    }

    private func handle(
        _ event: ClipLiveShareNativeFriendViewerSessionEvent,
        operationID: UUID
    ) async {
        guard !isEnding, self.operationID == operationID else { return }
        switch event {
        case .connecting:
            phase = NativeViewerTransportPhasePolicy.phase(
                after: .connecting,
                current: phase
            )
            publish()

        case .rendezvousConnected:
            publish()

        case .descriptorAccepted(let descriptor):
            signedHostDescriptor = descriptor
            if joinMode.permitsRequesterHandshakeRecovery {
                friendship = .pending
                await resumeRequesterHandshakeIfPresent(for: descriptor)
            } else {
                friendship = .friends
            }
            publish()

        case .awaitingHostApproval:
            phase = NativeViewerTransportPhasePolicy.phase(
                after: .awaitingHostApproval,
                current: phase
            )
            publish()

        case .authenticated(let sessionID):
            phase = .connecting
            controlState = NativeViewerV1ControlState(sessionID: sessionID)
            nativeControlState = ClipLiveShareNativeStreamLifecycleState(
                sessionID: sessionID
            )
            installWindowCoordinator(sessionID: sessionID)
            reconcileWindows()

        case .connectionStateChanged(let connectionState):
            applyConnectionState(connectionState)

        case .controlDataChannelStateChanged(let channelState):
            await applyControlChannelState(channelState)

        case .rendezvousHandoffCompleted:
            publish()

        case .controlMessage(let message):
            applyControlMessage(message)

        case .nativeControlMessage(let data):
            await handleNativeControlMessage(data)

        case .remoteVideoStreamAdded(let stream),
             .remoteVideoStreamUpdated(let stream):
            remoteStreams[stream.id.rawValue] = stream
            reconcileWindows()

        case .remoteVideoStreamRemoved(let streamID):
            remoteStreams[streamID.rawValue] = nil
            reconcileWindows()

        case .systemAudioTrackAvailable:
            audioTrackAvailable = true
            publish()

        case .systemAudioTrackRemoved:
            audioTrackAvailable = false
            publish()

        case .failed(let error):
            fail(message: error.localizedDescription)

        case .closed:
            if !isEnding {
                phase = NativeViewerTransportPhasePolicy.phase(
                    after: .closed,
                    current: phase
                )
                publish()
            }
        }
    }

    private func applyConnectionState(_ connectionState: WebRTCPeerConnectionState) {
        let event: NativeViewerTransportPhaseEvent?
        switch connectionState {
        case .connected:
            event = .connected
        case .disconnected:
            event = .disconnected
        case .failed, .closed:
            event = .connectionFailed
        case .new, .connecting:
            event = nil
        }
        guard let event else { return }
        phase = NativeViewerTransportPhasePolicy.phase(after: event, current: phase)
        if event == .disconnected || event == .connectionFailed {
            windowCoordinator?.markDisconnected()
        } else if event == .connected {
            // The authoritative source lifecycle remains connected while ICE
            // is recovering. Reapply it so locally grayed windows recover even
            // when the DataChannel never emits another `.open` transition.
            reconcileWindows()
            return
        }
        publish()
    }

    private func applyControlChannelState(
        _ channelState: WebRTCControlDataChannelState
    ) async {
        switch channelState {
        case .open:
            phase = NativeViewerTransportPhasePolicy.phase(
                after: .controlOpened,
                current: phase
            )
            startStatisticsLoop()
            if joinMode.sendsNativeControlHello {
                await sendNativeControlHello()
            }
            if let committedFriendAcceptance {
                await sendFriendAcceptanceAcknowledgement(
                    committedFriendAcceptance
                )
            }
            if case .friend(let friend) = joinMode {
                nativeFriends?.markConnected(id: friend.id)
            }
            reconcileWindows()
        case .closed:
            let nextPhase = NativeViewerTransportPhasePolicy.phase(
                after: .controlClosed,
                current: phase
            )
            if nextPhase == .reconnecting { windowCoordinator?.markDisconnected() }
            phase = nextPhase
        case .connecting, .closing:
            break
        }
        publish()
    }

    private func applyControlMessage(_ message: ClipLiveShareInnerMessage) {
        guard var controlState else { return }
        do {
            let effect = try controlState.apply(message)
            self.controlState = controlState
            switch effect {
            case .sourcesChanged:
                reconcileWindows()
            case .cursorChanged(let cursor):
                windowCoordinator?.setCursor(
                    streamID: cursor.streamID,
                    normalizedX: cursor.normalizedX,
                    normalizedY: cursor.normalizedY
                )
            case .sharingChanged(let sharing):
                if !sharing { windowCoordinator?.markDisconnected() }
            case .systemAudioChanged(let enabled):
                hostSystemAudioEnabled = enabled
                publish()
            case .sessionClosed(let reason):
                phase = .ended(message: reason)
                windowCoordinator?.markDisconnected()
                publish()
            case .ignored:
                break
            }
        } catch {
            fail(message: error.localizedDescription)
        }
    }

    private func handleNativeControlMessage(_ data: Data) async {
        if let message = try? ClipLiveShareNativeV2MessageCodec.decode(
            ClipLiveShareNativeStreamLifecycleMessage.self,
            from: data
        ) {
            applyNativeLifecycle(message)
            return
        }
        if let descriptor = try? ClipLiveShareNativeV2MessageCodec.decode(
            ClipLiveShareSignedNativeSessionDescriptor.self,
            from: data
        ) {
            await acceptHostDescriptor(descriptor)
            return
        }
        if let friend = try? ClipLiveShareNativeV2MessageCodec.decode(
            ClipLiveShareSignedNativeFriendMessage.self,
            from: data
        ) {
            await acceptFriendMessage(friend)
            return
        }
        Self.logger.error("Rejected an unknown native Live Share control payload")
    }

    private func sendNativeControlHello() async {
        guard let sessionID = controlState?.sessionID,
              let localIdentity else { return }
        do {
            let now = try ClipLiveShareNativeTimestamp(date: Date())
            let hello = try ClipLiveShareNativeControlHello(
                sessionID: sessionID,
                viewerIdentity: localIdentity.publicKey,
                deviceName: Host.current().localizedName ?? String(localized: "Mac"),
                issuedAt: now,
                expiresAt: try now.adding(
                    milliseconds: ClipLiveShareNativeV2
                        .maximumControlHelloLifetimeMilliseconds
                )
            )
            let signed = try ClipLiveShareSignedNativeControlHello(
                signing: hello,
                with: localIdentity.signer
            )
            let encoded = try ClipLiveShareNativeV2MessageCodec.encode(signed)
            guard await inviteSession?.sendNativeControl(encoded) == true else {
                throw ClipLiveShareV1ViewerSessionError.controlChannelUnavailable
            }
        } catch {
            Self.logger.error(
                "Could not identify native viewer: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func acceptHostDescriptor(
        _ signed: ClipLiveShareSignedNativeSessionDescriptor
    ) async {
        guard let resolvedInvite,
              let sessionID = controlState?.sessionID else { return }
        do {
            let descriptor = signed.descriptor
            let now = try ClipLiveShareNativeTimestamp(date: Date())
            let expectedHostIdentity = signedHostDescriptor?.descriptor.hostIdentity
                ?? descriptor.hostIdentity
            try signed.verify(
                expectedIdentity: expectedHostIdentity,
                expectedContext: descriptor.rendezvousContext,
                at: now
            )
            guard descriptor.endpoint == resolvedInvite.endpoint,
                  descriptor.room == resolvedInvite.room,
                  descriptor.roomPublicKey == resolvedInvite.fragment.publicKey,
                  descriptor.sessionID == sessionID else {
                throw ClipLiveShareNativeV2Error.contextMismatch
            }
            let requiresWindowReinstallation =
                NativeViewerDescriptorPresentationPolicy.requiresWindowReinstallation(
                    previous: signedHostDescriptor?.descriptor,
                    incoming: descriptor
                )
            signedHostDescriptor = signed
            let existingFriend = nativeFriends?.book.records.first {
                $0.identity == descriptor.hostIdentity
            }
            if existingFriend?.trustState == .trusted {
                friendship = .friends
            } else if existingFriend?.trustState == .blocked {
                friendship = .unavailable
            } else if existingFriend?.trustState == .pendingCommit {
                friendship = .pending
            } else {
                friendship = .available
            }
            if requiresWindowReinstallation {
                reinstallWindowCoordinatorForVerifiedHost()
            }
            await resumeRequesterHandshakeIfPresent(for: signed)
            publish()
        } catch {
            Self.logger.error(
                "Rejected native host identity: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func resumeRequesterHandshakeIfPresent(
        for currentSignedDescriptor: ClipLiveShareSignedNativeSessionDescriptor
    ) async {
        guard joinMode.permitsRequesterHandshakeRecovery,
              committedFriendAcceptance == nil,
              let nativeFriends,
              let localIdentity else { return }

        let currentDescriptor = currentSignedDescriptor.descriptor
        guard let recovery = nativeFriends.requesterHandshakeRecoveries.last(where: {
            $0.counterpartyIdentity == currentDescriptor.hostIdentity
                && $0.acceptance.accepterEndpoint == currentDescriptor.endpoint
                && $0.acceptance.rendezvousID == currentDescriptor.rendezvousID
        }) else { return }

        do {
            let now = try ClipLiveShareNativeTimestamp(date: Date())
            try recovery.validate(localIdentity: localIdentity.publicKey, at: now)
            let friendID = recovery.counterpartyIdentity.fingerprint.rawValue

            // The receipt may have reached durable storage immediately before
            // process failure. Finish publication without recreating any
            // protocol statement.
            if let signedReceipt = recovery.signedCommitReceipt {
                try await nativeFriends.completeRequesterHandshakeDurably(
                    friendID: friendID,
                    handshakeID: recovery.id
                )
                acceptedFriendCommitReceiptDigest = signedReceipt.digest
                pendingFriendRequest = nil
                pendingSignedFriendRequest = nil
                friendship = .friends
                nativeFriends.markConnected(id: friendID)
                windowCoordinator?.setOwnerName(resolvedOwnerName)
                return
            }

            let acknowledgementData = try ClipLiveShareNativeV2MessageCodec
                .encode(recovery.signedAcknowledgement)
            pendingFriendRequest = recovery.request
            pendingSignedFriendRequest = recovery.signedRequest
            let commit = NativeViewerCommittedFriendAcceptance(
                signedAcceptanceDigest: recovery.signedAcceptance.digest,
                hostDescriptor: recovery.signedSessionDescriptor.descriptor,
                request: recovery.request,
                acceptance: recovery.acceptance,
                acknowledgement: recovery.acknowledgement,
                signedAcknowledgementDigest: recovery.signedAcknowledgement.digest,
                friendID: friendID,
                handshakeID: recovery.id,
                isRecovery: true,
                acknowledgementData: acknowledgementData
            )
            committedFriendAcceptance = commit
            friendship = .pending
            await sendFriendAcceptanceAcknowledgement(commit)
        } catch {
            Self.logger.error(
                "Could not resume friendship commit: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func applyNativeLifecycle(
        _ message: ClipLiveShareNativeStreamLifecycleMessage
    ) {
        guard var nativeControlState else { return }
        do {
            try nativeControlState.apply(message)
            self.nativeControlState = nativeControlState
            if case let .systemAudio(enabled) = message.event {
                hostSystemAudioEnabled = enabled
            }
            reconcileWindows()
        } catch {
            Self.logger.error(
                "Rejected native stream state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func acceptFriendMessage(
        _ signed: ClipLiveShareSignedNativeFriendMessage
    ) async {
        do {
            switch signed.message {
            case let .accepted(acceptance):
                guard let host = signedHostDescriptor?.descriptor,
                      let nativeFriends,
                      let localIdentity,
                      let request = pendingFriendRequest
                        ?? committedFriendAcceptance?.request else { return }
                let now = try ClipLiveShareNativeTimestamp(date: Date())
                // Context and signature checks intentionally precede replay
                // bookkeeping. Invalid cross-session responses cannot poison
                // the replay guard for a later valid host response.
                try acceptance.validate(
                    for: request,
                    expectedSessionDescriptor: host,
                    at: now
                )
                try signed.verifySignature(expectedIdentity: host.hostIdentity)

                if let committedFriendAcceptance {
                    guard NativeViewerFriendAcceptanceSendPolicy.isRetransmission(
                        receivedDigest: signed.digest,
                        committedDigest: committedFriendAcceptance
                            .signedAcceptanceDigest
                    ) else {
                        throw ClipLiveShareNativeV2Error.contextMismatch
                    }
                    await sendFriendAcceptanceAcknowledgement(
                        committedFriendAcceptance
                    )
                    return
                }

                guard let signedRequest = pendingSignedFriendRequest,
                      case .request(let signedRequestValue) = signedRequest.message,
                      signedRequestValue == request,
                      let signedDescriptor = signedHostDescriptor else {
                    throw ClipLiveShareNativeV2Error.contextMismatch
                }

                let record = NativeFriendRecord(
                    identity: host.hostIdentity,
                    displayName: acceptance.accepterDisplayName,
                    deviceName: acceptance.accepterDeviceName,
                    endpoint: acceptance.accepterEndpoint,
                    rendezvousID: acceptance.rendezvousID,
                    trustState: .pendingCommit
                )
                var stagedEntry: NativeFriendHandshakeJournalEntry?
                let acknowledgement = try await
                    NativeViewerFriendAcceptanceCommitBuilder.signedAcknowledgement(
                        acceptance: acceptance,
                        request: request,
                        signer: localIdentity.signer,
                        acknowledgedAt: now,
                        persist: { signedAcknowledgement in
                            let entry = try NativeFriendHandshakeJournalEntry(
                                role: .requester,
                                signedSessionDescriptor: signedDescriptor,
                                signedRequest: signedRequest,
                                signedAcceptance: signed,
                                signedAcknowledgement: signedAcknowledgement
                            )
                            try await nativeFriends
                                .stageRequesterHandshakeDurably(
                                    record: record,
                                    entry: entry
                                )
                            stagedEntry = entry
                        }
                    )
                // Only a fully validated response that has been durably
                // accepted and converted to an ACK consumes replay state.
                try friendReplayGuard.acceptSignatureOnce(
                    signed,
                    expectedIdentity: host.hostIdentity
                )
                guard case let .acceptanceAcknowledged(acknowledgementValue)
                        = acknowledgement.message,
                      let stagedEntry else {
                    throw ClipLiveShareNativeV2Error.contextMismatch
                }
                let commit = NativeViewerCommittedFriendAcceptance(
                    signedAcceptanceDigest: signed.digest,
                    hostDescriptor: host,
                    request: request,
                    acceptance: acceptance,
                    acknowledgement: acknowledgementValue,
                    signedAcknowledgementDigest: acknowledgement.digest,
                    friendID: record.id,
                    handshakeID: stagedEntry.id,
                    isRecovery: false,
                    acknowledgementData: try ClipLiveShareNativeV2MessageCodec
                        .encode(acknowledgement)
                )
                committedFriendAcceptance = commit
                await sendFriendAcceptanceAcknowledgement(commit)

            case let .commitReceipt(receipt):
                try await acceptFriendCommitReceipt(
                    signed,
                    receipt: receipt
                )

            case let .declined(decline):
                guard committedFriendAcceptance == nil,
                      let request = pendingFriendRequest,
                      let host = signedHostDescriptor?.descriptor else { return }
                let now = try ClipLiveShareNativeTimestamp(date: Date())
                try NativeViewerFriendResponseVerifier.validateDecline(
                    signed,
                    decline: decline,
                    request: request,
                    host: host,
                    at: now,
                    replayGuard: &friendReplayGuard
                )
                pendingFriendRequest = nil
                pendingSignedFriendRequest = nil
                friendAcknowledgementRetryTask?.cancel()
                friendAcknowledgementRetryTask = nil
                friendship = .declined
                publish()

            case .request, .acceptanceAcknowledged, .revoked:
                break
            }
        } catch {
            Self.logger.error(
                "Rejected native friendship response: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func sendFriendAcceptanceAcknowledgement(
        _ commit: NativeViewerCommittedFriendAcceptance
    ) async {
        friendAcknowledgementRetryTask?.cancel()
        friendAcknowledgementRetryTask = nil
        let sent = await sendActiveNativeControl(commit.acknowledgementData)
        guard committedFriendAcceptance?.signedAcceptanceDigest
                == commit.signedAcceptanceDigest else { return }
        guard sent else {
            scheduleFriendAcknowledgementRetry(commit)
            return
        }
        publish()
    }

    private func scheduleFriendAcknowledgementRetry(
        _ commit: NativeViewerCommittedFriendAcceptance
    ) {
        let operationID = operationID
        friendAcknowledgementRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { friendAcknowledgementRetryTask = nil }
            for delay in [250, 500, 1_000, 2_000, 4_000, 8_000] {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }
                guard self.operationID == operationID,
                      !isEnding,
                      committedFriendAcceptance?.signedAcceptanceDigest
                        == commit.signedAcceptanceDigest else { return }
                if await sendActiveNativeControl(commit.acknowledgementData) {
                    publish()
                    return
                }
            }
            Self.logger.error(
                "Could not send the native friendship commit acknowledgement"
            )
        }
    }

    private func sendActiveNativeControl(_ data: Data) async -> Bool {
        if let inviteSession {
            return await inviteSession.sendNativeControl(data)
        }
        if let friendSession {
            return await friendSession.sendNativeControl(data)
        }
        return false
    }

    private func acceptFriendCommitReceipt(
        _ signed: ClipLiveShareSignedNativeFriendMessage,
        receipt: ClipLiveShareNativeFriendCommitReceipt
    ) async throws {
        guard let commit = committedFriendAcceptance,
              let host = signedHostDescriptor?.descriptor,
              let nativeFriends else { return }
        let now = try ClipLiveShareNativeTimestamp(date: Date())
        let validationTime =
            NativeViewerFriendCommitReceiptValidationPolicy.validationTime(
                for: receipt,
                isRecovery: commit.isRecovery,
                wallClock: now
            )
        try NativeViewerFriendCommitReceiptVerifier.validate(
            signed,
            receipt: receipt,
            acknowledgement: commit.acknowledgement,
            signedAcknowledgementDigest: commit.signedAcknowledgementDigest,
            acceptance: commit.acceptance,
            request: commit.request,
            host: commit.hostDescriptor,
            at: validationTime
        )

        if let acceptedFriendCommitReceiptDigest {
            guard acceptedFriendCommitReceiptDigest == signed.digest else {
                throw ClipLiveShareNativeV2Error.contextMismatch
            }
            _ = try friendReplayGuard.acceptCommitReceiptIdempotently(
                signed,
                expectedIdentity: host.hostIdentity
            )
            return
        }

        // Persist the signed receipt before the atomic publish/removal. A
        // process crash between these writes is completed from the validated
        // journal at startup instead of leaving a hidden friend forever.
        try await nativeFriends.storeCommitReceiptDurably(
            signed,
            handshakeID: commit.handshakeID
        )
        try await nativeFriends.completeRequesterHandshakeDurably(
            friendID: commit.friendID,
            handshakeID: commit.handshakeID
        )
        _ = try friendReplayGuard.acceptCommitReceiptIdempotently(
            signed,
            expectedIdentity: host.hostIdentity
        )
        acceptedFriendCommitReceiptDigest = signed.digest
        friendAcknowledgementRetryTask?.cancel()
        friendAcknowledgementRetryTask = nil
        if NativeViewerFriendAcceptanceSendPolicy.shouldClearPendingRequest(
            commitReceiptAccepted: true
        ), pendingFriendRequest?.requestID == commit.request.requestID {
            pendingFriendRequest = nil
        }
        pendingSignedFriendRequest = nil
        friendship = .friends
        nativeFriends.markConnected(id: commit.friendID)
        windowCoordinator?.setOwnerName(resolvedOwnerName)
        publish()
    }

    private func installWindowCoordinator(
        sessionID: ClipLiveShareSessionID,
        ownerName: String? = nil,
        ownerIdentity: Data? = nil
    ) {
        guard windowCoordinator == nil,
              let resolvedOwnerIdentity = ownerIdentity ?? self.resolvedOwnerIdentity else {
            return
        }
        let coordinator = NativeViewerWindowCoordinator(
            sessionID: sessionID.rawValue,
            ownerName: ownerName ?? resolvedOwnerName,
            ownerPublicIdentity: resolvedOwnerIdentity,
            surfaceFactory: { [weak self] in
                let videoView = WebRTCRemoteVideoView(frame: .zero)
                let adapter = NativeViewerVideoSurfaceAdapter(
                    view: videoView,
                    bind: { [weak self, weak videoView] source in
                        guard let self,
                              let videoView,
                              let stream = remoteStreams[source.streamID] else {
                            throw NativeViewerSurfaceBindingError.unavailable(
                                source.streamID
                            )
                        }
                        videoView.bind(to: stream)
                    },
                    teardown: { [weak videoView] in videoView?.teardown() }
                )
                videoView.onDecodedPixelSizeChange = { [weak adapter] size in
                    adapter?.decodedPixelSizeDidChange(size)
                }
                return adapter
            }
        )
        coordinator.confirmLeaveWhenLastWindowCloses = {
            let alert = NSAlert()
            alert.messageText = String(localized: "Leave this Live Share?")
            alert.informativeText = String(
                localized: "You are closing the final visible shared window."
            )
            alert.addButton(withTitle: String(localized: "Leave"))
            alert.addButton(withTitle: String(localized: "Keep Viewing"))
            return alert.runModal() == .alertFirstButtonReturn
        }
        coordinator.onLeaveRequested = { [weak self] in self?.requestLeave() }
        coordinator.setScaleMode(scaleMode)
        windowCoordinator = coordinator
    }

    private func reconcileWindows() {
        guard let windowCoordinator else {
            publish()
            return
        }
        // Only expose a source after its negotiated media track is available.
        // Manifest-first and track-first ordering therefore converge without a
        // blank native window.
        let authoritativeSources: [NativeViewerSourceSnapshot]
        if NativeViewerSourceAuthorityPolicy.usesNativeLifecycle(
            nativeControlState
        ), let nativeControlState {
            authoritativeSources = nativeSourceSnapshots(nativeControlState)
        } else {
            authoritativeSources = controlState?.sourceSnapshots ?? []
        }
        let sources = authoritativeSources.filter {
            remoteStreams[$0.streamID] != nil
        }
        do {
            try windowCoordinator.reconcile(sources)
        } catch {
            fail(message: error.localizedDescription)
            return
        }
        publish()
    }

    private func submitAccessCode(_ value: String) {
        guard joinMode.acceptsAccessCode, let inviteSession else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            phase = .connecting
            publish()
            do {
                try await inviteSession.submitAccessCode(value)
            } catch let error as ClipLiveShareV1ViewerSessionError {
                fail(message: error.localizedDescription)
            } catch {
                fail(message: error.localizedDescription)
            }
        }
    }

    private func setSystemAudioEnabled(_ enabled: Bool) {
        systemAudioEnabled = enabled
        let inviteSession = inviteSession
        let friendSession = friendSession
        Task {
            await inviteSession?.setSystemAudioPlaybackEnabled(enabled)
            await friendSession?.setSystemAudioPlaybackEnabled(enabled)
        }
        publish()
    }

    private func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        let volume = volume
        let inviteSession = inviteSession
        let friendSession = friendSession
        Task {
            await inviteSession?.setSystemAudioVolume(volume)
            await friendSession?.setSystemAudioVolume(volume)
        }
        publish()
    }

    private func setScaleMode(_ mode: NativeViewerScaleMode) {
        scaleMode = mode
        windowCoordinator?.setScaleMode(mode)
        publish()
    }

    private func setSourceVisible(_ id: String, visible: Bool) {
        windowCoordinator?.setSourceVisible(visible, sourceInstanceID: id)
        publish()
    }

    private func showAll() {
        windowCoordinator?.showAll()
        publish()
    }

    private func requestFriendship() {
        guard case .invite = joinMode,
              friendship == .available,
              pendingFriendRequest == nil,
              let host = signedHostDescriptor?.descriptor,
              let localIdentity,
              let inviteSession else { return }
        do {
            let now = try ClipLiveShareNativeTimestamp(date: Date())
            let request = try ClipLiveShareNativeFriendRequest(
                requestID: .random(),
                sessionID: host.sessionID,
                sessionDescriptorDigest: host.digest,
                requestedHostFingerprint: host.hostIdentity.fingerprint,
                requesterIdentity: localIdentity.publicKey,
                requesterEndpoint: localServerEndpoint,
                requesterRendezvousID: localIdentity.rendezvousID,
                requesterDeviceName: Host.current().localizedName
                    ?? String(localized: "Mac"),
                issuedAt: now,
                expiresAt: try now.adding(
                    milliseconds: ClipLiveShareNativeV2
                        .maximumFriendRequestLifetimeMilliseconds
                )
            )
            let signed = try ClipLiveShareSignedNativeFriendMessage(
                signing: .request(request),
                with: localIdentity.signer
            )
            let data = try ClipLiveShareNativeV2MessageCodec.encode(signed)
            // Publish the pending request before crossing the actor boundary.
            // A same-machine peer can answer while sendNativeControl is still
            // suspended, and that response must not be dropped as unsolicited.
            pendingFriendRequest = request
            pendingSignedFriendRequest = signed
            friendship = .pending
            publish()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let sent = await inviteSession.sendNativeControl(data)
                guard !sent,
                      NativeViewerFriendRequestSendPolicy.shouldRollback(
                        sentRequest: request,
                        pendingRequest: pendingFriendRequest,
                        committedRequest: committedFriendAcceptance?.request
                      ) else {
                    return
                }
                pendingFriendRequest = nil
                pendingSignedFriendRequest = nil
                friendship = .available
                publish()
            }
        } catch {
            Self.logger.error(
                "Could not send friendship request: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func retry() {
        guard phase.isTerminal, !isEnding else { return }
        operationID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        eventTask?.cancel()
        eventTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
        friendAcknowledgementRetryTask?.cancel()
        friendAcknowledgementRetryTask = nil
        windowCoordinator?.tearDown()
        windowCoordinator = nil
        remoteStreams.removeAll()
        controlState = nil
        nativeControlState = nil
        signedHostDescriptor = nil
        pendingFriendRequest = nil
        pendingSignedFriendRequest = nil
        committedFriendAcceptance = nil
        acceptedFriendCommitReceiptDigest = nil
        friendship = joinMode.initialFriendship
        audioTrackAvailable = false
        hostSystemAudioEnabled = false
        latestStatistics = .init()
        priorStatistics = nil
        let inviteSession = inviteSession
        let friendSession = friendSession
        self.inviteSession = nil
        self.friendSession = nil
        Task { @MainActor [weak self] in
            await inviteSession?.close()
            await friendSession?.close()
            self?.start()
        }
    }

    private func requestLeave() {
        Task { @MainActor [weak self] in
            await self?.endSession(notifyApplication: true)
        }
    }

    private func endSession(notifyApplication: Bool) async {
        guard !isEnding else { return }
        isEnding = true
        operationID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        eventTask?.cancel()
        eventTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
        friendAcknowledgementRetryTask?.cancel()
        friendAcknowledgementRetryTask = nil
        windowCoordinator?.tearDown()
        windowCoordinator = nil
        let inviteSession = inviteSession
        let friendSession = friendSession
        self.inviteSession = nil
        self.friendSession = nil
        await inviteSession?.close()
        await friendSession?.close()
        remoteStreams.removeAll()
        controlState = nil
        nativeControlState = nil
        signedHostDescriptor = nil
        pendingFriendRequest = nil
        pendingSignedFriendRequest = nil
        committedFriendAcceptance = nil
        acceptedFriendCommitReceiptDigest = nil
        if notifyApplication, !didNotifyEnd {
            didNotifyEnd = true
            onSessionEnded()
        }
    }

    private func fail(message: String) {
        guard !isEnding else { return }
        phase = .failed(message: message)
        windowCoordinator?.markDisconnected()
        statisticsTask?.cancel()
        statisticsTask = nil
        friendAcknowledgementRetryTask?.cancel()
        friendAcknowledgementRetryTask = nil
        publish()
    }

    private func startStatisticsLoop() {
        guard statisticsTask == nil else { return }
        let operationID = operationID
        statisticsTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard self.operationID == operationID else { return }
                await refreshStatistics(operationID: operationID)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshStatistics(operationID: UUID) async {
        guard self.operationID == operationID, phase == .live else { return }
        let snapshot: WebRTCInboundStatisticsSnapshot?
        switch joinMode {
        case .invite:
            snapshot = try? await inviteSession?.inboundStatisticsSnapshot()
        case .friend, .recovery:
            snapshot = try? await friendSession?.inboundStatisticsSnapshot()
        }
        guard self.operationID == operationID, let snapshot else { return }
        let currentBytes = snapshot.tracks.reduce(UInt64(0)) { partial, track in
            partial &+ track.bytesReceived
        }
        var bitsPerSecond = 0
        if let previous = priorStatistics {
            let previousBytes = previous.tracks.reduce(UInt64(0)) { partial, track in
                partial &+ track.bytesReceived
            }
            let interval = snapshot.capturedAt.timeIntervalSince(previous.capturedAt)
            if currentBytes >= previousBytes, interval > 0 {
                bitsPerSecond = Int(
                    (Double(currentBytes - previousBytes) * 8 / interval).rounded()
                )
            }
        }
        priorStatistics = snapshot
        let video = snapshot.tracks.filter { $0.kind == .video }
        latestStatistics = NativeViewerStatisticsSnapshot(
            bitsPerSecond: bitsPerSecond,
            framesPerSecond: video.compactMap(\.framesPerSecond).reduce(0, +),
            packetsLost: snapshot.tracks.reduce(Int64(0)) { $0 + $1.packetsLost },
            codec: video.compactMap(\.codec).first
        )
        route = switch snapshot.route {
        case .unknown: .unknown
        case .direct: .peerToPeer
        case .relay: .turn
        }
        publish()
    }

    private var resolvedSavedHost: NativeFriendRecord? {
        guard let identity = signedHostDescriptor?.descriptor.hostIdentity else {
            switch joinMode {
            case .friend(let friend), .recovery(let friend): return friend
            case .invite: return nil
            }
        }
        if let record = nativeFriends?.book.records.first(where: {
            $0.identity == identity && $0.trustState == .trusted
        }) { return record }
        switch joinMode {
        case .friend(let friend):
            return friend.identity == identity ? friend : nil
        case .recovery(let friend):
            return friend.identity == identity ? friend : nil
        case .invite:
            return nil
        }
    }

    private var resolvedOwnerName: String {
        if let friend = resolvedSavedHost { return friend.displayName }
        switch joinMode {
        case .friend(let friend), .recovery(let friend): return friend.displayName
        case .invite: break
        }
        return resolvedInvite?.room.rawValue ?? joinMode.ownerName
    }

    private var resolvedOwnerDeviceName: String? {
        resolvedSavedHost?.deviceName ?? joinMode.ownerDeviceName
    }

    private var resolvedOwnerIdentity: Data? {
        if let identity = signedHostDescriptor?.descriptor.hostIdentity {
            return identity.x963Representation
        }
        switch joinMode {
        case .invite:
            return resolvedInvite?.fragment.publicKey.x963Representation
        case .friend(let friend), .recovery(let friend):
            return friend.identity.x963Representation
        }
    }

    private func makeSnapshot() -> NativeViewerViewSnapshot {
        let sourceSnapshots = windowCoordinator?.windowSnapshots.map { window in
            NativeViewerSourceViewSnapshot(
                id: window.source.sourceInstanceID,
                applicationName: window.source.applicationName,
                windowName: window.source.windowName,
                pixelWidth: Int(window.source.pixelSize.width.rounded()),
                pixelHeight: Int(window.source.pixelSize.height.rounded()),
                isVisible: window.isVisible,
                isFocused: window.source.isFocused,
                isConnected: window.source.isConnected
            )
        } ?? []
        return NativeViewerViewSnapshot(
            phase: phase,
            ownerName: resolvedOwnerName,
            ownerDeviceName: resolvedOwnerDeviceName,
            route: route,
            sources: sourceSnapshots,
            systemAudioAvailable: audioTrackAvailable && hostSystemAudioEnabled,
            systemAudioEnabled: systemAudioEnabled,
            volume: volume,
            scaleMode: scaleMode,
            friendship: friendship,
            statistics: latestStatistics
        )
    }

    private func publish() {
        presentationModel.update(makeSnapshot())
        switch phase {
        case .live:
            onMenuBarStatusChanged(.live)
        case .reconnecting:
            onMenuBarStatusChanged(.reconnecting)
        case .failed:
            onMenuBarStatusChanged(.failed)
        default:
            onMenuBarStatusChanged(.ready)
        }
    }

    private func nativeSourceSnapshots(
        _ state: ClipLiveShareNativeStreamLifecycleState
    ) -> [NativeViewerSourceSnapshot] {
        state.streams.values
            .filter(\.stream.active)
            .sorted { lhs, rhs in
                if lhs.stream.order != rhs.stream.order {
                    return lhs.stream.order < rhs.stream.order
                }
                return lhs.sourceInstanceID.rawValue
                    < rhs.sourceInstanceID.rawValue
            }
            .map { descriptor in
                NativeViewerSourceSnapshot(
                    sourceInstanceID: descriptor.sourceInstanceID.rawValue,
                    streamID: descriptor.stream.id.rawValue,
                    applicationName: descriptor.stream.appName,
                    windowName: descriptor.stream.windowName,
                    pixelSize: CGSize(
                        width: descriptor.stream.width,
                        height: descriptor.stream.height
                    ),
                    sourcePointSize: descriptor.stream.sourcePointSize,
                    isFocused: state.focusedSourceInstanceID
                        == descriptor.sourceInstanceID,
                    isConnected: true,
                    stateRevision: state.revisionGuard
                        .latestAcceptedRevision?.rawValue ?? 1,
                    mode: descriptor.presentationMode == .followsFocusedWindow
                        ? .followsFocusedWindow
                        : .manual
                )
            }
    }

    private func reinstallWindowCoordinatorForVerifiedHost() {
        guard let host = signedHostDescriptor?.descriptor,
              let sessionID = controlState?.sessionID else { return }
        let existingScaleMode = scaleMode
        windowCoordinator?.tearDown()
        windowCoordinator = nil
        installWindowCoordinator(
            sessionID: sessionID,
            ownerName: resolvedOwnerName,
            ownerIdentity: host.hostIdentity.x963Representation
        )
        windowCoordinator?.setScaleMode(existingScaleMode)
        reconcileWindows()
    }
}
