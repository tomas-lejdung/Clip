import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation

enum ServerCoordinatedMeshAdmissionDenialReason {
    /// Stable machine-readable reason routed only to the candidate. The room
    /// still sends no Access Word or verifier material through the service.
    static let accessWordRequired = "clip-access-word-required-v1"
}

/// HTTP control plane used only for capability discovery and creator room
/// creation. All identity, admission, pair signaling, source state and media
/// remain end-to-end authenticated above the service.
struct ServerCoordinatedMeshRoomControlPlaneClient: Sendable {
    let discover: @Sendable (URL) async throws
        -> ClipLiveShareServerRoomV4Capabilities
    let create: @Sendable (
        ClipLiveShareServerRoomV4Target,
        ClipLiveShareServerRoomV4CreateRequest,
        ClipLiveShareServerRoomV4Capabilities
    ) async throws -> Void

    init(
        discover: @escaping @Sendable (URL) async throws
            -> ClipLiveShareServerRoomV4Capabilities,
        create: @escaping @Sendable (
            ClipLiveShareServerRoomV4Target,
            ClipLiveShareServerRoomV4CreateRequest,
            ClipLiveShareServerRoomV4Capabilities
        ) async throws -> Void
    ) {
        self.discover = discover
        self.create = create
    }

    static func live(
        _ client: ClipLiveShareServerRoomV4HTTPClient = .init()
    ) -> Self {
        Self(
            discover: { endpoint in
                try await client.discover(at: endpoint)
            },
            create: { target, request, capabilities in
                _ = try await client.create(
                    target: target,
                    ownerCapability: request.ownerToken,
                    creatorHandle: request.creatorHandle,
                    descriptor: request.descriptor,
                    capabilities: capabilities
                )
            }
        )
    }
}

/// Type-erased transport seam. Production wraps the v4 WebSocket transport;
/// focused app tests can drive the same session actor without opening sockets.
struct ServerCoordinatedMeshRoomTransportClient: Sendable {
    let events: @Sendable () async
        -> AsyncStream<ClipLiveShareServerRoomV4TransportEvent>
    let connect: @Sendable (
        ClipLiveShareServerRoomV4Target,
        ClipLiveShareServerRoomV4Capabilities,
        ClipLiveShareServerRoomV4SessionAuthentication
    ) async throws -> Void
    let sendJoinKnock: @Sendable (
        UInt64,
        ClipLiveShareServerRoomV4OpaqueJoinKnock
    ) async throws -> Void
    let admitCandidate: @Sendable (
        ClipLiveShareServerRoomV4CandidateHandle,
        ClipLiveShareServerRoomV4OpaqueAdmissionRecord
    ) async throws -> Void
    let denyCandidate: @Sendable (
        ClipLiveShareServerRoomV4CandidateHandle,
        String
    ) async throws -> Void
    let sendPairSignal: @Sendable (
        ClipLiveShareServerRoomV4PairSignalEnvelope
    ) async throws -> Void
    let removeMember: @Sendable (
        ClipLiveShareServerRoomV4MemberHandle
    ) async throws -> Void
    let leave: @Sendable () async -> Void
    let close: @Sendable () async -> Void

    init(_ transport: ClipLiveShareServerRoomV4Transport) {
        events = { await transport.events() }
        connect = { target, capabilities, authentication in
            try await transport.connect(
                to: target,
                capabilities: capabilities,
                authentication: authentication
            )
        }
        sendJoinKnock = { sequence, payload in
            try await transport.sendJoinKnock(
                sequence: sequence,
                payload: payload
            )
        }
        admitCandidate = { handle, descriptor in
            try await transport.admitCandidate(handle, descriptor: descriptor)
        }
        denyCandidate = { handle, reason in
            try await transport.denyCandidate(handle, reason: reason)
        }
        sendPairSignal = { envelope in
            try await transport.sendPairSignal(envelope)
        }
        removeMember = { handle in
            try await transport.removeMember(handle)
        }
        leave = { await transport.leave() }
        close = { await transport.close() }
    }

    init(
        events: @escaping @Sendable () async
            -> AsyncStream<ClipLiveShareServerRoomV4TransportEvent>,
        connect: @escaping @Sendable (
            ClipLiveShareServerRoomV4Target,
            ClipLiveShareServerRoomV4Capabilities,
            ClipLiveShareServerRoomV4SessionAuthentication
        ) async throws -> Void,
        sendJoinKnock: @escaping @Sendable (
            UInt64,
            ClipLiveShareServerRoomV4OpaqueJoinKnock
        ) async throws -> Void,
        admitCandidate: @escaping @Sendable (
            ClipLiveShareServerRoomV4CandidateHandle,
            ClipLiveShareServerRoomV4OpaqueAdmissionRecord
        ) async throws -> Void,
        denyCandidate: @escaping @Sendable (
            ClipLiveShareServerRoomV4CandidateHandle,
            String
        ) async throws -> Void,
        sendPairSignal: @escaping @Sendable (
            ClipLiveShareServerRoomV4PairSignalEnvelope
        ) async throws -> Void,
        removeMember: @escaping @Sendable (
            ClipLiveShareServerRoomV4MemberHandle
        ) async throws -> Void,
        leave: @escaping @Sendable () async -> Void,
        close: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        self.connect = connect
        self.sendJoinKnock = sendJoinKnock
        self.admitCandidate = admitCandidate
        self.denyCandidate = denyCandidate
        self.sendPairSignal = sendPairSignal
        self.removeMember = removeMember
        self.leave = leave
        self.close = close
    }
}

/// Type-erased media runtime seam. This retains the existing capture,
/// encoding and concrete WebRTC manager; v4 changes only room membership and
/// encrypted pair-signaling orchestration.
struct ServerCoordinatedMeshMediaClient: Sendable {
    let events: @Sendable () async
        -> AsyncStream<ServerCoordinatedMeshMediaRuntimeEvent>
    let snapshot: @Sendable () async throws
        -> ServerCoordinatedMeshMediaRuntimeSnapshot
    let start: @Sendable (ServerCoordinatedMeshVerifiedRoster) async throws
        -> Void
    let applyRoster: @Sendable (
        ServerCoordinatedMeshVerifiedRoster
    ) async throws -> Void
    let receivePairSignal: @Sendable (
        ServerCoordinatedMeshAuthenticatedPairSignal
    ) async throws -> Void
    let publishLocalSources: @Sendable (
        [ClipLiveShareNativeV3PublishedSource]
    ) async throws -> Void
    let broadcastSourceCursor: @Sendable (
        ClipLiveShareNativeV3SourceCursor
    ) async throws -> Void
    let broadcastCollaboration: @Sendable (
        ClipLiveShareNativeV3CollaborationEvent
    ) async throws -> Void
    let sendFriendshipMessage: @Sendable (
        ClipLiveShareServerRoomV4SignedFriendMessage,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    let pruneExpiredCollaboration: @Sendable (
        ClipLiveShareNativeTimestamp
    ) async -> Bool
    let remoteVideoStream: @Sendable (
        ClipLiveShareStreamDescriptor,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> WebRTCRemoteVideoStream?
    let setRemoteAudioPlayback: @Sendable (
        Bool,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    let setRemoteAudioVolume: @Sendable (
        Double,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    let setOutboundMediaEnabled: @Sendable (
        Bool,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    let updateSenderPolicy: @Sendable (WebRTCSenderPolicy) async throws -> Void
    let updateSenderPolicies: @Sendable (
        [Int: WebRTCSenderPolicy],
        WebRTCSenderPolicy,
        LiveShareEncodingMode
    ) async throws -> Void
    let updateVideoCodec: @Sendable (
        WebRTCVideoCodec,
        ClipLiveShareNativeV3ParticipantID,
        WebRTCVideoCodec
    ) async throws -> Void
    let rollbackLocalOffer: @Sendable (
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    let retryPairConnection: @Sendable (
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    let refreshStatistics: @Sendable () async throws
        -> [ClipLiveShareNativeV3PeerStatistics]
    let close: @Sendable () async -> Void

    init(_ runtime: ServerCoordinatedMeshMediaRuntime) {
        events = { await runtime.events() }
        snapshot = { try await runtime.snapshot() }
        start = { roster in try await runtime.start(roster: roster) }
        applyRoster = { roster in try await runtime.applyRoster(roster) }
        receivePairSignal = { signal in
            try await runtime.receiveAuthenticatedPairSignal(signal)
        }
        publishLocalSources = { sources in
            try await runtime.publishLocalSources(sources)
        }
        broadcastSourceCursor = { cursor in
            try await runtime.broadcastSourceCursor(cursor)
        }
        broadcastCollaboration = { event in
            try await runtime.broadcastCollaboration(event)
        }
        sendFriendshipMessage = { message, participantID in
            try await runtime.sendFriendshipMessage(
                message,
                to: participantID
            )
        }
        pruneExpiredCollaboration = { timestamp in
            await runtime.pruneExpiredCollaboration(at: timestamp)
        }
        remoteVideoStream = { descriptor, participantID in
            try await runtime.remoteVideoStream(
                for: descriptor,
                from: participantID
            )
        }
        setRemoteAudioPlayback = { enabled, participantID in
            try await runtime.setRemoteParticipantAudioPlaybackEnabled(
                enabled,
                for: participantID
            )
        }
        setRemoteAudioVolume = { volume, participantID in
            try await runtime.setRemoteParticipantAudioVolume(
                volume,
                for: participantID
            )
        }
        setOutboundMediaEnabled = { enabled, participantID in
            try await runtime.setOutboundMediaEnabled(
                enabled,
                for: participantID
            )
        }
        updateSenderPolicy = { policy in
            try await runtime.updateSenderPolicy(policy)
        }
        updateSenderPolicies = { policies, fallback, mode in
            try await runtime.updateSenderPolicies(
                policies,
                fallback: fallback,
                videoEncodingMode: mode
            )
        }
        updateVideoCodec = { codec, participantID, previousCodec in
            try await runtime.updateVideoCodecPreference(
                codec,
                for: participantID,
                rollbackTo: previousCodec
            )
        }
        rollbackLocalOffer = { participantID in
            try await runtime.rollbackLocalOfferIfNeeded(for: participantID)
        }
        retryPairConnection = { participantID in
            try await runtime.retryPairConnection(participantID)
        }
        refreshStatistics = { try await runtime.refreshStatistics() }
        close = { await runtime.close() }
    }
}

enum ServerCoordinatedMeshRoomSessionBootstrap: Sendable {
    case creator(
        room: ClipLiveShareServerRoomV4ClientRoom,
        createRequest: ClipLiveShareServerRoomV4CreateRequest,
        invite: ClipLiveShareServerRoomV4Invite
    )
    case candidate(
        room: ClipLiveShareServerRoomV4ClientRoom,
        joinKnock: ClipLiveShareServerRoomV4OpaqueJoinKnock,
        invite: ClipLiveShareServerRoomV4Invite
    )

    init(_ bootstrap: ClipLiveShareServerRoomV4CreatorBootstrap) {
        self = .creator(
            room: bootstrap.room,
            createRequest: bootstrap.createRequest,
            invite: bootstrap.invite
        )
    }

    init(
        _ bootstrap: ClipLiveShareServerRoomV4CandidateBootstrap,
        invite: ClipLiveShareServerRoomV4Invite
    ) {
        self = .candidate(
            room: bootstrap.room,
            joinKnock: bootstrap.joinKnock,
            invite: invite
        )
    }
}

enum ServerCoordinatedMeshRoomSessionPhase: Equatable, Sendable {
    case idle
    case connecting
    case waitingForAdmission
    case active
    case ended(reason: String)
}

struct ServerCoordinatedMeshRoomSessionSnapshot: Equatable, Sendable {
    let phase: ServerCoordinatedMeshRoomSessionPhase
    let role: ClipLiveShareServerRoomV4ClientRole
    let invite: ClipLiveShareServerRoomV4Invite?
    let room: ClipLiveShareServerRoomV4ClientRoomSnapshot
    /// The exact creator-verified, decrypted roster/pair projection. No app
    /// code re-opens server-visible ciphertext or reconstructs crypto state.
    let verifiedRoom: ClipLiveShareServerRoomV4ClientVerifiedRoomState?
    let media: ServerCoordinatedMeshMediaRuntimeSnapshot?
}

enum ServerCoordinatedMeshRoomSessionEvent: Equatable, Sendable {
    case snapshotChanged(ServerCoordinatedMeshRoomSessionSnapshot)
    case pendingJoin(ClipLiveShareServerRoomV4PendingJoin)
    case friendshipMessageReceived(
        ClipLiveShareServerRoomV4SignedFriendMessage,
        from: ClipLiveShareNativeV3ParticipantID
    )
    case pairFailed(
        participantID: ClipLiveShareNativeV3ParticipantID,
        message: String
    )
    case pairRecovered(participantID: ClipLiveShareNativeV3ParticipantID)
    case roomEnded(reason: String)
    case accessWordRequired
    case admissionDenied(reason: String)
    case failed(message: String)
    case closed
}

enum ServerCoordinatedMeshRoomSessionError:
    Error, Equatable, LocalizedError, Sendable
{
    case alreadyStarted
    case notStarted
    case creatorOperationRequired
    case terminal
    case missingVerifiedRoster
    case invalidVerifiedRoster
    case pairSignalBufferFull
    case accessWordRequired
    case admissionDenied(String)
    case roomEnded(String)
    case protocolFailure(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "The server-coordinated room session is already started."
        case .notStarted:
            "The server-coordinated room session has not started."
        case .creatorOperationRequired:
            "Only the room creator can perform this operation."
        case .terminal:
            "The server-coordinated room session has ended."
        case .missingVerifiedRoster:
            "The room has not supplied a verified roster yet."
        case .invalidVerifiedRoster:
            "The verified room roster cannot be mapped to the media mesh."
        case .pairSignalBufferFull:
            "The bounded pre-roster pair-signaling buffer is full."
        case .accessWordRequired:
            "The room requires an Access Word."
        case .admissionDenied(let reason):
            reason.isEmpty ? "The room denied admission." : reason
        case .roomEnded(let reason):
            reason.isEmpty ? "The room creator ended the room." : reason
        case .protocolFailure(let code, let message):
            message.isEmpty ? code : "\(code): \(message)"
        }
    }
}

/// Clean-slate app lifecycle for a service-rostered full WebRTC mesh.
///
/// There is intentionally no distributed authority, leader election, quorum,
/// provisional member state, or v3 compatibility. The service supplies the
/// complete routing roster. The creator leaving terminates the room. Every
/// pair failure remains pair-local and does not mutate room membership.
actor ServerCoordinatedMeshRoomSession {
    typealias MediaFactory = @Sendable (
        ClipLiveShareServerRoomV4Capabilities,
        @escaping ServerCoordinatedMeshMediaRuntime.SendPairSignal
    ) async throws -> ServerCoordinatedMeshMediaClient

    private static let maximumPendingPairSignals = 128
    private static let maximumRecentPairTransmissions = 128

    private typealias PairTransmissionResultStream =
        AsyncThrowingStream<Void, any Error>

    private enum PendingAdmissionTransmission: Sendable {
        case admit(ClipLiveShareServerRoomV4AdmissionCommand)
        case deny(
            ClipLiveShareServerRoomV4CandidateHandle,
            reason: String
        )

        var candidateHandle: ClipLiveShareServerRoomV4CandidateHandle {
            switch self {
            case .admit(let command): command.candidateHandle
            case .deny(let handle, _): handle
            }
        }
    }

    private struct PendingPairTransmission: Sendable {
        let context: ClipLiveShareServerRoomV4PairContext
        let payload: ClipLiveShareServerRoomV4PairSignalPayload
        let remoteHandle: ClipLiveShareServerRoomV4MemberHandle
        /// Sealed exactly once when the transmission enters the outbox. A
        /// WebSocket write can fail after the service accepted it, so retrying
        /// must reuse this sequence and ciphertext rather than minting a second
        /// valid envelope for the same SDP/ICE payload.
        let envelope: ClipLiveShareServerRoomV4PairSignalEnvelope
        /// Every media callback owns its result. The drain is shared only for
        /// serialization: a permanent failure for A must not make a queued,
        /// successfully delivered B callback report the same error.
        let completion: PairTransmissionResultStream.Continuation
    }

    private struct SentPairTransmissionKey: Hashable, Sendable {
        let pairID: ClipLiveShareServerRoomV4PairID
        let sequence: UInt64
    }

    private let controlPlane: ServerCoordinatedMeshRoomControlPlaneClient
    private let transport: ServerCoordinatedMeshRoomTransportClient
    private let mediaFactory: MediaFactory
    private let bootstrap: ServerCoordinatedMeshRoomSessionBootstrap
    private var room: ClipLiveShareServerRoomV4ClientRoom
    private let initialInvite: ClipLiveShareServerRoomV4Invite
    private let createRequest: ClipLiveShareServerRoomV4CreateRequest?
    private let candidateJoinKnock: ClipLiveShareServerRoomV4OpaqueJoinKnock?
    private var media: ServerCoordinatedMeshMediaClient?
    private var hasStartedMedia = false
    private var capabilities: ClipLiveShareServerRoomV4Capabilities?
    private var phase: ServerCoordinatedMeshRoomSessionPhase = .idle
    private var pendingPairSignals:
        [ClipLiveShareServerRoomV4PairSignalEnvelope] = []
    private var pendingAdmissions:
        [ClipLiveShareServerRoomV4CandidateHandle:
            PendingAdmissionTransmission] = [:]
    private var pendingPairTransmissions: [PendingPairTransmission] = []
    /// Actor reentrancy permits another media callback while a transport send
    /// is suspended. One nonthrowing drain serializes writes; individual
    /// callers await the completion attached to their own sealed envelope.
    private var pairTransmissionDrainTask: Task<Void, Never>?
    private var recentPairTransmissions:
        [SentPairTransmissionKey: PendingPairTransmission] = [:]
    private var recentPairTransmissionOrder: [SentPairTransmissionKey] = []
    private var nextJoinSequence: UInt64 = 1
    private var isTransportConnected = false
    private var transportTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var continuations: [
        UUID: AsyncStream<ServerCoordinatedMeshRoomSessionEvent>.Continuation
    ] = [:]
    private var isStarted = false
    private var isTerminal = false

    init(
        bootstrap: ServerCoordinatedMeshRoomSessionBootstrap,
        controlPlane: ServerCoordinatedMeshRoomControlPlaneClient = .live(),
        transport: ServerCoordinatedMeshRoomTransportClient = .init(
            ClipLiveShareServerRoomV4Transport()
        ),
        mediaFactory: @escaping MediaFactory
    ) {
        self.bootstrap = bootstrap
        self.controlPlane = controlPlane
        self.transport = transport
        self.mediaFactory = mediaFactory
        switch bootstrap {
        case let .creator(room, request, invite):
            self.room = room
            createRequest = request
            initialInvite = invite
            candidateJoinKnock = nil
        case let .candidate(room, knock, invite):
            self.room = room
            createRequest = nil
            initialInvite = invite
            candidateJoinKnock = knock
        }
    }

    func events() -> AsyncStream<ServerCoordinatedMeshRoomSessionEvent> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: ServerCoordinatedMeshRoomSessionEvent.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        guard !isTerminal else {
            pair.continuation.finish()
            return pair.stream
        }
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return pair.stream
    }

    func snapshot() async -> ServerCoordinatedMeshRoomSessionSnapshot {
        await makeSnapshot()
    }

    func start() async throws {
        guard !isStarted else {
            throw ServerCoordinatedMeshRoomSessionError.alreadyStarted
        }
        guard !isTerminal else {
            throw ServerCoordinatedMeshRoomSessionError.terminal
        }
        isStarted = true
        phase = .connecting
        await publishSnapshot()

        do {
            // Discovery deliberately precedes media construction so the one
            // concrete WebRTC manager receives the server-validated STUN/TURN
            // configuration. ApplicationCoordinator must not rediscover or
            // guess a different traversal policy.
            let capabilities = try await controlPlane.discover(
                initialInvite.serviceEndpoint
            )
            self.capabilities = capabilities
            let media = try await mediaFactory(capabilities) {
                [weak self] context, payload, remote in
                guard let self else {
                    throw ServerCoordinatedMeshRoomSessionError.terminal
                }
                try await self.sendPairSignal(
                    context: context,
                    payload: payload,
                    remoteHandle: remote
                )
            }
            self.media = media
            // Install both streams before opening the socket. A fresh
            // candidate can receive `candidate-opened` immediately after the
            // WebSocket handshake; missing it would leave the join knock
            // unsent forever.
            await observeTransport()
            await observeMedia(media)

            let target = try ClipLiveShareServerRoomV4Target(
                endpoint: initialInvite.serviceEndpoint,
                roomID: initialInvite.roomID
            )
            switch bootstrap {
            case .creator:
                guard let createRequest else {
                    throw ServerCoordinatedMeshRoomSessionError
                        .creatorOperationRequired
                }
                try await controlPlane.create(
                    target,
                    createRequest,
                    capabilities
                )
                try await transport.connect(
                    target,
                    capabilities,
                    .creator(ownerCapability: createRequest.ownerToken)
                )
                isTransportConnected = true
            case .candidate:
                try await transport.connect(
                    target,
                    capabilities,
                    .freshCandidate
                )
                isTransportConnected = true
            }
        } catch {
            await fail(error)
            throw error
        }
    }

    func setAdmissionPolicy(
        _ policy: ClipLiveShareServerRoomV4AdmissionPolicy
    ) async throws {
        try requireCreator()
        try room.setAdmissionPolicy(policy)
        await publishSnapshot()
    }

    /// The invite stays byte-for-byte stable through joins, disconnects and
    /// roster growth. This is the only session operation that rotates its
    /// admission capability.
    @discardableResult
    func rotateInvite() async throws -> ClipLiveShareServerRoomV4Invite {
        try requireCreator()
        let invite = try room.rotateInvite()
        await publishSnapshot()
        return invite
    }

    func approve(
        _ candidateHandle: ClipLiveShareServerRoomV4CandidateHandle
    ) async throws {
        try requireCreator()
        let command = try room.approve(candidateHandle: candidateHandle)
        pendingAdmissions[candidateHandle] = .admit(command)
        try await flushPendingAdmission(candidateHandle)
        await publishSnapshot()
    }

    func deny(
        _ candidateHandle: ClipLiveShareServerRoomV4CandidateHandle,
        reason: String = ""
    ) async throws {
        try requireCreator()
        _ = try room.deny(candidateHandle: candidateHandle)
        pendingAdmissions[candidateHandle] = .deny(
            candidateHandle,
            reason: reason
        )
        try await flushPendingAdmission(candidateHandle)
        await publishSnapshot()
    }

    func removeMember(
        _ handle: ClipLiveShareServerRoomV4MemberHandle
    ) async throws {
        try requireCreator()
        try await transport.removeMember(handle)
    }

    func publishLocalSources(
        _ sources: [ClipLiveShareNativeV3PublishedSource]
    ) async throws {
        try await requireMedia().publishLocalSources(sources)
    }

    func broadcastSourceCursor(
        _ cursor: ClipLiveShareNativeV3SourceCursor
    ) async throws {
        try await requireMedia().broadcastSourceCursor(cursor)
    }

    func broadcastCollaboration(
        _ event: ClipLiveShareNativeV3CollaborationEvent
    ) async throws {
        try await requireMedia().broadcastCollaboration(event)
    }

    func sendFriendshipMessage(
        _ message: ClipLiveShareServerRoomV4SignedFriendMessage,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await requireMedia().sendFriendshipMessage(message, participantID)
    }

    @discardableResult
    func pruneExpiredCollaboration(
        at timestamp: ClipLiveShareNativeTimestamp
    ) async throws -> Bool {
        return try await requireMedia().pruneExpiredCollaboration(timestamp)
    }

    func remoteVideoStream(
        for descriptor: ClipLiveShareStreamDescriptor,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws -> WebRTCRemoteVideoStream? {
        try await requireMedia().remoteVideoStream(descriptor, participantID)
    }

    func setRemoteParticipantAudioPlaybackEnabled(
        _ enabled: Bool,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await requireMedia().setRemoteAudioPlayback(enabled, participantID)
    }

    func setRemoteParticipantAudioVolume(
        _ volume: Double,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await requireMedia().setRemoteAudioVolume(volume, participantID)
    }

    func setOutboundMediaEnabled(
        _ enabled: Bool,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await requireMedia().setOutboundMediaEnabled(enabled, participantID)
    }

    func updateSenderPolicy(_ policy: WebRTCSenderPolicy) async throws {
        try await requireMedia().updateSenderPolicy(policy)
    }

    func updateSenderPolicies(
        _ policies: [Int: WebRTCSenderPolicy],
        fallback: WebRTCSenderPolicy,
        videoEncodingMode: LiveShareEncodingMode
    ) async throws {
        try await requireMedia().updateSenderPolicies(
            policies,
            fallback,
            videoEncodingMode
        )
    }

    func updateVideoCodecPreference(
        _ codec: WebRTCVideoCodec,
        for participantID: ClipLiveShareNativeV3ParticipantID,
        rollbackTo previousCodec: WebRTCVideoCodec
    ) async throws {
        try await requireMedia().updateVideoCodec(
            codec,
            participantID,
            previousCodec
        )
    }

    func rollbackLocalOfferIfNeeded(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await requireMedia().rollbackLocalOffer(participantID)
    }

    func retryPairConnection(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await requireMedia().retryPairConnection(participantID)
    }

    @discardableResult
    func refreshStatistics() async throws
        -> [ClipLiveShareNativeV3PeerStatistics]
    {
        try await requireMedia().refreshStatistics()
    }

    /// Creator leave intentionally ends the room. Participant leave removes
    /// only that participant. There is no election or leaderless state.
    func leave() async {
        guard !isTerminal else { return }
        let reason = room.role == .creator
            ? "The room creator ended the room."
            : "You left the room."
        await finish(reason: reason, emitRoomEnded: room.role == .creator)
        await transport.leave()
    }

    func close() async {
        guard !isTerminal else { return }
        await finish(reason: "The room session closed.", emitRoomEnded: false)
        await transport.close()
    }

    private func observeTransport() async {
        let stream = await transport.events()
        transportTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handleTransportEvent(event)
            }
        }
    }

    private func observeMedia(
        _ media: ServerCoordinatedMeshMediaClient
    ) async {
        let stream = await media.events()
        mediaTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handleMediaEvent(event)
            }
        }
    }

    private func handleTransportEvent(
        _ event: ClipLiveShareServerRoomV4TransportEvent
    ) async {
        guard !isTerminal else { return }
        do {
            switch event {
            case .connecting, .reconnecting:
                isTransportConnected = false
                if phase != .active { phase = .connecting }
                await publishSnapshot()
            case .connected:
                isTransportConnected = true
                try await replayPendingTransmissions()
                await publishSnapshot()
            case .message(let message):
                try await handleWireMessage(message)
            case .failed(let error):
                await fail(error)
            case .closed:
                if !isTerminal {
                    await finish(
                        reason: "The room connection closed.",
                        emitRoomEnded: false
                    )
                }
            }
        } catch {
            await fail(error)
        }
    }

    private func handleWireMessage(
        _ message: ClipLiveShareServerRoomV4WireMessage
    ) async throws {
        switch message {
        case .candidateOpened:
            guard room.role == .participant,
                  let candidateJoinKnock else { return }
            guard nextJoinSequence < UInt64.max else {
                throw ClipLiveShareServerRoomV4Error.sequenceExhausted
            }
            let sequence = nextJoinSequence
            nextJoinSequence += 1
            do {
                try await transport.sendJoinKnock(sequence, candidateJoinKnock)
            } catch {
                guard isTransientTransportSendError(error) else { throw error }
                isTransportConnected = false
                if phase != .active { phase = .connecting }
                await publishSnapshot()
                return
            }
            phase = .waitingForAdmission
            await publishSnapshot()

        case let .joinKnock(candidateHandle, _, payload):
            // A malformed or stale invitation belongs to this candidate, not
            // to the creator's room session. The service has already bounded
            // the opaque payload, so reject it with a deliberately generic
            // reason and keep every established P2P link alive. Only a
            // failure to send the denial itself is a transport/session error.
            guard let candidateHandle else { return }
            let decision: ClipLiveShareServerRoomV4JoinDecision
            do {
                decision = try room.consumeForwardedJoinKnock(
                    candidateHandle: candidateHandle,
                    payload: payload
                )
            } catch let error as ClipLiveShareServerRoomV4ClientRoomError {
                pendingAdmissions[candidateHandle] = .deny(
                    candidateHandle,
                    reason: candidateDenialReason(for: error)
                )
                try await flushPendingAdmission(candidateHandle)
                await publishSnapshot()
                return
            } catch {
                pendingAdmissions[candidateHandle] = .deny(
                    candidateHandle,
                    reason: "This invitation or access proof is not valid."
                )
                try await flushPendingAdmission(candidateHandle)
                await publishSnapshot()
                return
            }
            switch decision {
            case .pendingApproval(let pending):
                emit(.pendingJoin(pending))
                await publishSnapshot()
            case .admit(let command):
                pendingAdmissions[command.candidateHandle] = .admit(command)
                try await flushPendingAdmission(command.candidateHandle)
            }

        case let .memberAdmitted(handle, reconnect, roster):
            _ = try room.consumeMemberAdmitted(
                memberHandle: handle,
                reconnectCapability: reconnect,
                roster: roster
            )
            clearConfirmedAdmissions()
            try await applyVerifiedRoomToMedia()
            await drainPendingPairSignals()

        case .rosterSnapshot(let roster):
            if room.localHandle == nil {
                // Admission always carries a complete authoritative roster.
                // A speculative pre-admission snapshot has no local binding
                // and is intentionally ignored rather than cached as state.
                return
            }
            _ = try room.consumeRosterSnapshot(roster)
            clearConfirmedAdmissions()
            try await applyVerifiedRoomToMedia()
            await drainPendingPairSignals()

        case .pairSignal(let envelope):
            await receivePairSignalEnvelope(envelope)

        case .denyCandidate(let candidateHandle, let reason):
            if room.role == .creator, let candidateHandle {
                _ = try room.forgetCandidate(
                    candidateHandle: candidateHandle
                )
                pendingAdmissions[candidateHandle] = nil
                await publishSnapshot()
            } else {
                if reason == ServerCoordinatedMeshAdmissionDenialReason
                    .accessWordRequired {
                    throw ServerCoordinatedMeshRoomSessionError
                        .accessWordRequired
                }
                throw ServerCoordinatedMeshRoomSessionError
                    .admissionDenied(reason)
            }

        case .roomEnded(let reason):
            await finish(reason: reason, emitRoomEnded: true)

        case .protocolError(let code, let message, let pair):
            if await handleRecoverableProtocolError(
                code: code,
                message: message,
                pair: pair
            ) {
                return
            }
            throw ServerCoordinatedMeshRoomSessionError.protocolFailure(
                code: code,
                message: message
            )

        case .admitCandidate, .leaveRoom, .removeMember:
            throw ClipLiveShareServerRoomV4Error.invalidWireMessage(
                "server direction"
            )
        }
    }

    private func receivePairSignalEnvelope(
        _ envelope: ClipLiveShareServerRoomV4PairSignalEnvelope
    ) async {
        do {
            try await openAndDeliverPairSignal(envelope)
        } catch ClipLiveShareServerRoomV4ClientRoomError.pairUnavailable {
            if pendingPairSignals.count < Self.maximumPendingPairSignals {
                pendingPairSignals.append(envelope)
            } else {
                await reportRejectedPairSignal(envelope)
            }
        } catch {
            await reportRejectedPairSignal(envelope)
        }
    }

    private func drainPendingPairSignals() async {
        guard !pendingPairSignals.isEmpty else { return }
        var remaining: [ClipLiveShareServerRoomV4PairSignalEnvelope] = []
        for envelope in pendingPairSignals {
            do {
                try await openAndDeliverPairSignal(envelope)
            } catch ClipLiveShareServerRoomV4ClientRoomError.pairUnavailable {
                remaining.append(envelope)
            } catch {
                await reportRejectedPairSignal(envelope)
            }
        }
        pendingPairSignals = remaining
    }

    private func reportRejectedPairSignal(
        _ envelope: ClipLiveShareServerRoomV4PairSignalEnvelope
    ) async {
        guard let sender = envelope.from,
              let participantID = room.clientVerifiedState?.members.first(
                where: { $0.handle == sender }
              )?.descriptor.participantID else {
            // Unknown and pre-admission senders have no authenticated pair to
            // fail. Dropping their message is safer than affecting the room.
            return
        }
        if let media,
           let snapshot = try? await media.snapshot(),
           snapshot.links.links.contains(where: {
               $0.remoteParticipantID == participantID && $0.isReady
           }) {
            // Old, duplicated or malformed signaling can arrive after this
            // pair has already recovered. It must never replace a verified
            // ready state with a permanent orange warning. The direct link
            // remains authoritative; just discard the stale control packet.
            return
        }
        emit(.pairFailed(
            participantID: participantID,
            message: "A direct participant signal was rejected."
        ))
        await publishSnapshot()
    }

    private func candidateDenialReason(
        for error: ClipLiveShareServerRoomV4ClientRoomError
    ) -> String {
        if error == .invalidAccessWord {
            return ServerCoordinatedMeshAdmissionDenialReason
                .accessWordRequired
        }
        if error == .roomIsFull {
            return "The room cannot accept another participant."
        }
        return "This invitation or access proof is not valid."
    }

    private func flushPendingAdmission(
        _ candidateHandle: ClipLiveShareServerRoomV4CandidateHandle
    ) async throws {
        guard isTransportConnected,
              let transmission = pendingAdmissions[candidateHandle] else {
            return
        }
        do {
            switch transmission {
            case .admit(let command):
                try await transport.admitCandidate(
                    command.candidateHandle,
                    command.descriptor
                )
                // An admission stays replayable until an authoritative roster
                // contains its deterministic promoted member handle. A socket
                // write can succeed locally before its server-side result is
                // observable.
            case .deny(let handle, let reason):
                try await transport.denyCandidate(handle, reason)
                pendingAdmissions[handle] = nil
            }
        } catch {
            guard isTransientTransportSendError(error) else { throw error }
            isTransportConnected = false
        }
    }

    private func replayPendingTransmissions() async throws {
        for handle in pendingAdmissions.keys.sorted() {
            try await flushPendingAdmission(handle)
            guard isTransportConnected else { return }
        }
        startPairTransmissionDrainIfNeeded()
    }

    private func clearConfirmedAdmissions() {
        guard let verified = room.clientVerifiedState else { return }
        let handles = Set(verified.members.map(\.handle))
        pendingAdmissions = pendingAdmissions.filter { handle, value in
            switch value {
            case .admit:
                !handles.contains(handle.admittedMemberHandle)
            case .deny:
                true
            }
        }
        let validRemoteHandles = Set(verified.pairs.map(\.remoteHandle))
        failPendingPairTransmissions(
            where: { !validRemoteHandles.contains($0.remoteHandle) },
            throwing: ServerCoordinatedMeshRoomSessionError
                .invalidVerifiedRoster
        )
        let invalidRecentKeys = recentPairTransmissions.compactMap {
            key, transmission in
            validRemoteHandles.contains(transmission.remoteHandle) ? nil : key
        }
        for key in invalidRecentKeys { recentPairTransmissions[key] = nil }
        recentPairTransmissionOrder.removeAll {
            recentPairTransmissions[$0] == nil
        }
    }

    private func startPairTransmissionDrainIfNeeded() {
        guard isTransportConnected else { return }
        guard pairTransmissionDrainTask == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainPendingPairTransmissions()
        }
        pairTransmissionDrainTask = task
    }

    private func drainPendingPairTransmissions() async {
        defer { pairTransmissionDrainTask = nil }
        while let transmission = pendingPairTransmissions.first {
            do {
                try await transport.sendPairSignal(transmission.envelope)
                // The authoritative roster can remove this peer while the
                // transport send is suspended. Remove only the exact element
                // this drain sent; never consume a newer queue head.
                if removePendingPairTransmission(transmission) {
                    rememberSentPairTransmission(transmission)
                    transmission.completion.finish()
                }
            } catch {
                guard isTransientTransportSendError(error) else {
                    if removePendingPairTransmission(transmission) {
                        transmission.completion.finish(throwing: error)
                    }
                    // A later callback may already be queued behind this
                    // failed pair while the send was suspended. Keep draining
                    // it, but do not attribute this envelope's error to it.
                    continue
                }
                isTransportConnected = false
                return
            }
        }
    }

    @discardableResult
    private func removePendingPairTransmission(
        _ transmission: PendingPairTransmission
    ) -> Bool {
        guard let index = pendingPairTransmissions.firstIndex(where: {
            $0.envelope.pairID == transmission.envelope.pairID
                && $0.envelope.sequence == transmission.envelope.sequence
        }) else { return false }
        pendingPairTransmissions.remove(at: index)
        return true
    }

    private func failPendingPairTransmissions(
        where shouldFail: (PendingPairTransmission) -> Bool,
        throwing error: any Error
    ) {
        var retained: [PendingPairTransmission] = []
        retained.reserveCapacity(pendingPairTransmissions.count)
        for transmission in pendingPairTransmissions {
            if shouldFail(transmission) {
                transmission.completion.finish(throwing: error)
            } else {
                retained.append(transmission)
            }
        }
        pendingPairTransmissions = retained
    }

    private func rememberSentPairTransmission(
        _ transmission: PendingPairTransmission
    ) {
        let envelope = transmission.envelope
        let key = SentPairTransmissionKey(
            pairID: envelope.pairID,
            sequence: envelope.sequence
        )
        recentPairTransmissions[key] = transmission
        recentPairTransmissionOrder.removeAll { $0 == key }
        recentPairTransmissionOrder.append(key)
        while recentPairTransmissionOrder.count
            > Self.maximumRecentPairTransmissions
        {
            let expired = recentPairTransmissionOrder.removeFirst()
            recentPairTransmissions[expired] = nil
        }
    }

    private func handleRecoverableProtocolError(
        code: String,
        message: String,
        pair: ClipLiveShareServerRoomV4ProtocolErrorPair?
    ) async -> Bool {
        if code == "candidate_unavailable" {
            // Candidate disconnect/expiry is also routed with its opaque
            // handle when known. Even an older service without that cleanup
            // message must not terminate established participant pairs.
            return true
        }
        guard [
            "sequence_rejected",
            "member_unavailable",
            "route_backpressure",
        ].contains(code) else { return false }

        // Older v4 services did not attach a pair correlation. Preserve the
        // healthy room even then, but only retry/warn when the authenticated
        // route is explicit so one error can never be applied to every link.
        guard let pair,
              let verified = room.clientVerifiedState,
              verified.pairs.contains(where: {
                  $0.context.pairID == pair.pairID
                      && $0.remoteHandle == pair.remoteHandle
              }),
              let participantID = verified.members.first(where: {
                  $0.handle == pair.remoteHandle
              })?.descriptor.participantID else {
            return true
        }

        let key = SentPairTransmissionKey(
            pairID: pair.pairID,
            sequence: pair.sequence
        )
        if code == "sequence_rejected" {
            // The router may have delivered this SDP/ICE payload before its
            // acknowledgment was lost. Never duplicate it under a new
            // envelope sequence. If the direct link still is not ready, ask
            // that one peer-link to produce a fresh negotiation instead.
            recentPairTransmissions[key] = nil
            recentPairTransmissionOrder.removeAll { $0 == key }
            if !(await isPairReady(participantID)) {
                try? await media?.retryPairConnection(participantID)
            }
            await publishSnapshot()
            return true
        }

        if code == "route_backpressure" {
            if let transmission = recentPairTransmissions.removeValue(forKey: key) {
                recentPairTransmissionOrder.removeAll { $0 == key }
                let retryResult = PairTransmissionResultStream.makeStream()
                let retryTransmission = PendingPairTransmission(
                    context: transmission.context,
                    payload: transmission.payload,
                    remoteHandle: transmission.remoteHandle,
                    envelope: transmission.envelope,
                    completion: retryResult.continuation
                )
                let alreadyPending = pendingPairTransmissions.contains {
                    $0.envelope.pairID == transmission.envelope.pairID
                        && $0.envelope.sequence
                            == transmission.envelope.sequence
                }
                if !alreadyPending {
                    pendingPairTransmissions.insert(retryTransmission, at: 0)
                }
                try? await Task.sleep(for: .milliseconds(100))
                startPairTransmissionDrainIfNeeded()
                if !alreadyPending {
                    // Do not await this result on the transport event loop. A
                    // transient retry failure needs that same loop to process
                    // `connected` and replay the exact queued envelope.
                    Task { [weak self] in
                        do {
                            for try await _ in retryResult.stream {}
                        } catch {
                            await self?.reportPairTransmissionRetryFailure(
                                participantID: participantID,
                                message: message
                            )
                        }
                    }
                }
            }
            await publishSnapshot()
            return true
        }

        // A missing signaling target is pair-local. Do not tear down any
        // other edge; ask the media runtime to recover just this participant.
        if !(await isPairReady(participantID)) {
            emit(.pairFailed(participantID: participantID, message: message))
            try? await media?.retryPairConnection(participantID)
            await publishSnapshot()
        }
        return true
    }

    private func reportPairTransmissionRetryFailure(
        participantID: ClipLiveShareNativeV3ParticipantID,
        message: String
    ) {
        guard !isTerminal else { return }
        emit(.pairFailed(participantID: participantID, message: message))
    }

    private func isPairReady(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) async -> Bool {
        guard let media,
              let mediaSnapshot = try? await media.snapshot() else {
            return false
        }
        return mediaSnapshot.links.links.contains {
            $0.remoteParticipantID == participantID && $0.isReady
        }
    }

    private func isTransientTransportSendError(_ error: any Error) -> Bool {
        guard let error = error as? ClipLiveShareServerRoomV4TransportError
        else { return false }
        return switch error {
        case .sendFailed, .operationSuperseded, .notConnected:
            true
        default:
            false
        }
    }

    private func openAndDeliverPairSignal(
        _ envelope: ClipLiveShareServerRoomV4PairSignalEnvelope
    ) async throws {
        guard let sender = envelope.from else {
            throw ClipLiveShareServerRoomV4Error.invalidPairContext
        }
        let payload = try room.openPairSignal(envelope)
        try await requireMedia().receivePairSignal(.init(
            pairID: envelope.pairID,
            senderHandle: sender,
            sequence: envelope.sequence,
            payload: payload
        ))
        await publishSnapshot()
    }

    private func applyVerifiedRoomToMedia() async throws {
        guard let verified = room.clientVerifiedState else {
            throw ServerCoordinatedMeshRoomSessionError.missingVerifiedRoster
        }
        let roster = try mediaRoster(from: verified)
        guard let media else {
            throw ServerCoordinatedMeshRoomSessionError.notStarted
        }
        if hasStartedMedia {
            try await media.applyRoster(roster)
        } else {
            try await media.start(roster)
            hasStartedMedia = true
        }
        phase = .active
        await publishSnapshot()
    }

    private func mediaRoster(
        from verified: ClipLiveShareServerRoomV4ClientVerifiedRoomState
    ) throws -> ServerCoordinatedMeshVerifiedRoster {
        guard let local = verified.members.first(where: \.isLocal) else {
            throw ServerCoordinatedMeshRoomSessionError.invalidVerifiedRoster
        }
        let members = verified.members.map {
            ServerCoordinatedMeshVerifiedMember(
                handle: $0.handle,
                participantID: $0.descriptor.participantID,
                descriptor: $0.descriptor
            )
        }
        let byHandle = Dictionary(
            uniqueKeysWithValues: verified.members.map { ($0.handle, $0) }
        )
        let pairs = try verified.pairs.map { pair in
            guard let remote = byHandle[pair.remoteHandle],
                  pair.context.roomID == verified.roomID,
                  pair.context.sessionID == verified.sessionID,
                  pair.context.contains(verified.localHandle),
                  try pair.context.remoteHandle(for: verified.localHandle)
                    == pair.remoteHandle else {
                throw ServerCoordinatedMeshRoomSessionError
                    .invalidVerifiedRoster
            }
            return ServerCoordinatedMeshVerifiedPair(
                context: pair.context,
                epoch: pair.epoch,
                remoteParticipantID: remote.descriptor.participantID
            )
        }
        return try .init(
            roomID: verified.roomID,
            sessionID: verified.sessionID,
            revision: verified.rosterRevision,
            localHandle: verified.localHandle,
            localParticipantID: local.descriptor.participantID,
            members: members,
            pairs: pairs
        )
    }

    private func sendPairSignal(
        context: ClipLiveShareServerRoomV4PairContext,
        payload: ClipLiveShareServerRoomV4PairSignalPayload,
        remoteHandle: ClipLiveShareServerRoomV4MemberHandle
    ) async throws {
        guard !isTerminal else {
            throw ServerCoordinatedMeshRoomSessionError.terminal
        }
        guard room.clientVerifiedState?.pairs.contains(where: {
            $0.remoteHandle == remoteHandle && $0.context == context
        }) == true else {
            throw ServerCoordinatedMeshRoomSessionError.invalidVerifiedRoster
        }
        guard pendingPairTransmissions.count
                < Self.maximumPendingPairSignals else {
            throw ServerCoordinatedMeshRoomSessionError.pairSignalBufferFull
        }
        let envelope = try room.sealPairSignal(
            to: remoteHandle,
            payload: payload
        )
        guard envelope.pairID == context.pairID else {
            throw ServerCoordinatedMeshRoomSessionError.invalidVerifiedRoster
        }
        let result = PairTransmissionResultStream.makeStream()
        pendingPairTransmissions.append(.init(
            context: context,
            payload: payload,
            remoteHandle: remoteHandle,
            envelope: envelope,
            completion: result.continuation
        ))
        startPairTransmissionDrainIfNeeded()
        for try await _ in result.stream {}
        await publishSnapshot()
    }

    private func handleMediaEvent(
        _ event: ServerCoordinatedMeshMediaRuntimeEvent
    ) async {
        guard !isTerminal else { return }
        switch event {
        case .snapshotChanged:
            await publishSnapshot()
        case .sourceCursorReceived:
            break
        case let .friendshipMessageReceived(message, participantID):
            emit(.friendshipMessageReceived(message, from: participantID))
        case let .pairFailed(participantID, message):
            // A-B failure must not remove C or mutate the server roster.
            emit(.pairFailed(
                participantID: participantID,
                message: message
            ))
            await publishSnapshot()
        case let .pairRecovered(participantID):
            emit(.pairRecovered(participantID: participantID))
            await publishSnapshot()
        case .closed:
            break
        }
    }

    private func requireCreator() throws {
        guard !isTerminal else {
            throw ServerCoordinatedMeshRoomSessionError.terminal
        }
        guard room.role == .creator else {
            throw ServerCoordinatedMeshRoomSessionError
                .creatorOperationRequired
        }
    }

    private func requireMedia() throws -> ServerCoordinatedMeshMediaClient {
        guard !isTerminal else {
            throw ServerCoordinatedMeshRoomSessionError.terminal
        }
        guard isStarted, let media else {
            throw ServerCoordinatedMeshRoomSessionError.notStarted
        }
        return media
    }

    private func makeSnapshot() async
        -> ServerCoordinatedMeshRoomSessionSnapshot
    {
        let mediaSnapshot: ServerCoordinatedMeshMediaRuntimeSnapshot?
        // A signaling reconnect does not suspend or replace established P2P
        // media. Keep the last live media/source snapshot visible throughout
        // the bounded service reconnect grace; otherwise the UI would tear
        // down healthy remote windows merely because the roster socket is
        // reconnecting.
        if let media {
            mediaSnapshot = try? await media.snapshot()
        } else {
            mediaSnapshot = nil
        }
        return .init(
            phase: phase,
            role: room.role,
            // Candidates cannot issue or rotate invitations, so their room
            // state intentionally has no `currentInvite`. Retain the exact
            // invitation that authenticated this session for canonical room
            // identity and future web/app parity; presentation still gates
            // Copy/Rotate to the creator role.
            invite: room.currentInvite ?? initialInvite,
            room: room.snapshot,
            verifiedRoom: room.clientVerifiedState,
            media: mediaSnapshot
        )
    }

    private func publishSnapshot() async {
        emit(.snapshotChanged(await makeSnapshot()))
    }

    private func fail(_ error: any Error) async {
        guard !isTerminal else { return }
        if let roomError = error as? ServerCoordinatedMeshRoomSessionError {
            switch roomError {
            case .accessWordRequired:
                emit(.accessWordRequired)
            case let .admissionDenied(reason):
                emit(.admissionDenied(reason: reason))
            default:
                emit(.failed(message: error.localizedDescription))
            }
        } else {
            emit(.failed(message: error.localizedDescription))
        }
        await finish(reason: error.localizedDescription, emitRoomEnded: false)
        await transport.close()
    }

    private func finish(reason: String, emitRoomEnded: Bool) async {
        guard !isTerminal else { return }
        isTerminal = true
        phase = .ended(reason: reason)
        pendingPairSignals.removeAll(keepingCapacity: false)
        pendingAdmissions.removeAll(keepingCapacity: false)
        failPendingPairTransmissions(
            where: { _ in true },
            throwing: ServerCoordinatedMeshRoomSessionError.terminal
        )
        pairTransmissionDrainTask?.cancel()
        pairTransmissionDrainTask = nil
        recentPairTransmissions.removeAll(keepingCapacity: false)
        recentPairTransmissionOrder.removeAll(keepingCapacity: false)
        transportTask?.cancel()
        transportTask = nil
        mediaTask?.cancel()
        mediaTask = nil
        await media?.close()
        let finalSnapshot = await makeSnapshot()
        emit(.snapshotChanged(finalSnapshot))
        if emitRoomEnded { emit(.roomEnded(reason: reason)) }
        emit(.closed)
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll(keepingCapacity: false)
    }

    private func emit(_ event: ServerCoordinatedMeshRoomSessionEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
