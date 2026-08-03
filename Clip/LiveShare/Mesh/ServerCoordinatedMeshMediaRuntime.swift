import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
#if DEBUG
import OSLog
#endif

/// One creator-certified, decrypted roster member. The service never sees
/// these values in plaintext; the room-session layer constructs them only
/// after opening and verifying the opaque admission record.
struct ServerCoordinatedMeshVerifiedMember: Equatable, Sendable {
    let handle: ClipLiveShareServerRoomV4MemberHandle
    /// The complete descriptor is mandatory after creator certification and
    /// decryption. Runtime capability decisions must never infer a profile
    /// from missing data or from user-controlled display fields.
    let descriptor: ClipLiveShareServerRoomV4MemberDescriptor

    var participantID: ClipLiveShareNativeV3ParticipantID {
        descriptor.participantID
    }

    var displayName: String { descriptor.displayName }
    var deviceName: String { descriptor.deviceName }

    init(
        handle: ClipLiveShareServerRoomV4MemberHandle,
        descriptor: ClipLiveShareServerRoomV4MemberDescriptor
    ) {
        self.handle = handle
        self.descriptor = descriptor
    }
}

private extension ClipLiveShareServerRoomV4PairSignalPayload {
    var isSessionDescription: Bool {
        switch self {
        case .offer, .answer:
            true
        case .iceCandidate, .iceRestart, .renegotiationRequest,
             .codecRenegotiationRequest, .codecRenegotiationRejected, .close:
            false
        }
    }
}

/// Stable, pair-local context supplied by the verified room session.
struct ServerCoordinatedMeshVerifiedPair: Equatable, Sendable {
    let context: ClipLiveShareServerRoomV4PairContext
    let epoch: ClipLiveShareServerRoomV4PairEpoch
    let remoteParticipantID: ClipLiveShareNativeV3ParticipantID

    var pairID: ClipLiveShareServerRoomV4PairID { context.pairID }
}

/// Media-runtime input adapted from one complete authenticated server roster.
/// Pair identity and epoch are independent from `revision`; adding C must not
/// mutate the A-B binding.
struct ServerCoordinatedMeshVerifiedRoster: Equatable, Sendable {
    let roomID: ClipLiveShareServerRoomV4RoomID
    let sessionID: ClipLiveShareSessionID
    let revision: ClipLiveShareServerRoomV4RosterRevision
    let localHandle: ClipLiveShareServerRoomV4MemberHandle
    let localParticipantID: ClipLiveShareNativeV3ParticipantID
    let members: [ServerCoordinatedMeshVerifiedMember]
    let pairsByParticipant:
        [ClipLiveShareNativeV3ParticipantID: ServerCoordinatedMeshVerifiedPair]

    init(
        roomID: ClipLiveShareServerRoomV4RoomID,
        sessionID: ClipLiveShareSessionID,
        revision: ClipLiveShareServerRoomV4RosterRevision,
        localHandle: ClipLiveShareServerRoomV4MemberHandle,
        localParticipantID: ClipLiveShareNativeV3ParticipantID,
        members: [ServerCoordinatedMeshVerifiedMember],
        pairs: [ServerCoordinatedMeshVerifiedPair]
    ) throws {
        guard
            (1...ClipLiveShareServerRoomV4.maximumParticipants).contains(
                members.count
            ),
            Set(members.map(\.handle)).count == members.count,
            Set(members.map(\.participantID)).count == members.count,
            members.contains(where: {
                $0.handle == localHandle
                    && $0.participantID == localParticipantID
            })
        else {
            throw ClipLiveShareServerRoomV4Error.invalidRoster(
                "verified members"
            )
        }
        let membersByParticipant = Dictionary(
            uniqueKeysWithValues: members.map { ($0.participantID, $0) }
        )
        let remoteParticipantIDs = Set(membersByParticipant.keys).subtracting([
            localParticipantID
        ])
        let groupedPairs = Dictionary(grouping: pairs, by: \.remoteParticipantID)
        guard
            Set(groupedPairs.keys) == remoteParticipantIDs,
            groupedPairs.values.allSatisfy({ $0.count == 1 }),
            Set(pairs.map(\.pairID)).count == pairs.count
        else {
            throw ClipLiveShareServerRoomV4Error.invalidRoster(
                "verified pair bindings"
            )
        }
        for pair in pairs {
            guard
                pair.context.roomID == roomID,
                pair.context.sessionID == sessionID,
                pair.context.contains(localHandle),
                try pair.context.remoteHandle(for: localHandle)
                    == membersByParticipant[pair.remoteParticipantID]?.handle,
                Set([
                    pair.context.lowerParticipantID,
                    pair.context.upperParticipantID,
                ]) == [localParticipantID, pair.remoteParticipantID]
            else {
                throw ClipLiveShareServerRoomV4Error.invalidPairContext
            }
        }
        self.roomID = roomID
        self.sessionID = sessionID
        self.revision = revision
        self.localHandle = localHandle
        self.localParticipantID = localParticipantID
        self.members = members.sorted { $0.handle < $1.handle }
        pairsByParticipant = groupedPairs.mapValues { $0[0] }
    }

    var participantIDs: Set<ClipLiveShareNativeV3ParticipantID> {
        Set(members.map(\.participantID))
    }

    func member(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> ServerCoordinatedMeshVerifiedMember? {
        members.first { $0.participantID == participantID }
    }

    func member(
        for handle: ClipLiveShareServerRoomV4MemberHandle
    ) -> ServerCoordinatedMeshVerifiedMember? {
        members.first { $0.handle == handle }
    }
}

/// Authenticated/decrypted pair signal delivered by the room-session layer.
/// This runtime still verifies the pair, sender and epoch before touching
/// WebRTC; authentication alone is not authorization for another pair.
struct ServerCoordinatedMeshAuthenticatedPairSignal: Equatable, Sendable {
    let pairID: ClipLiveShareServerRoomV4PairID
    let senderHandle: ClipLiveShareServerRoomV4MemberHandle
    /// The authenticated envelope sequence. The encrypted room-session
    /// channel has already verified this value, but retaining it here lets the
    /// media runtime safely buffer roster/signaling races without reordering
    /// or replaying WebRTC negotiations.
    let sequence: UInt64
    let payload: ClipLiveShareServerRoomV4PairSignalPayload
}

protocol ServerCoordinatedMeshMediaLinkManaging: Sendable {
    func events() async
        -> AsyncStream<ClipLiveShareNativeV3MeshPeerLinkManagerEvent>
    func applyRoster(
        _ roster: ServerCoordinatedMeshVerifiedRoster
    ) async throws -> ClipLiveShareServerMeshReconciliationResult
    func reconciliationSnapshot() async
        -> ClipLiveShareServerMeshPeerReconcilerSnapshot
    func linkSnapshot() async
        -> ClipLiveShareNativeV3MeshPeerLinkManagerSnapshot
    func requestNegotiation(
        with participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func applyRemoteNegotiation(
        _ targeted: ClipLiveShareNativeV3TargetedNegotiation,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func restartLink(
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func recreateLink(
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func disconnect(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func sendReliable(
        _ data: Data,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func sendEphemeral(
        _ data: Data,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async -> Bool
    func remoteVideoStream(
        for descriptor: ClipLiveShareStreamDescriptor,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws -> WebRTCRemoteVideoStream?
    func setRemoteParticipantAudioPlaybackEnabled(
        _ enabled: Bool,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func setRemoteParticipantAudioVolume(
        _ volume: Double,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func setOutboundMediaEnabled(
        _ enabled: Bool,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func updateSenderPolicy(_ policy: WebRTCSenderPolicy) async
    func updateSenderPolicies(
        _ policiesBySlot: [Int: WebRTCSenderPolicy],
        fallback: WebRTCSenderPolicy,
        videoEncodingMode: LiveShareEncodingMode
    ) async
    func updateVideoCodecPreference(
        _ codec: WebRTCVideoCodec,
        for participantID: ClipLiveShareNativeV3ParticipantID,
        rollbackTo previousCodec: WebRTCVideoCodec
    ) async throws
    func restoreVideoCodecPreference(
        _ codec: WebRTCVideoCodec,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func currentVideoCodecPreference(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws -> WebRTCVideoCodec?
    func rollbackLocalOfferIfNeeded(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func refreshStatistics() async throws
        -> [ClipLiveShareNativeV3PeerStatistics]
    func close() async
}

/// Production bridge retaining the existing capture/media transport manager
/// while replacing authority/election membership with pure server-roster
/// reconciliation.
actor ServerCoordinatedMeshMediaLinkAdapter:
    ServerCoordinatedMeshMediaLinkManaging
{
    private let manager: ClipLiveShareNativeV3MeshPeerLinkManager
    private let reconciler: ClipLiveShareServerMeshPeerReconciler

    init(
        manager: ClipLiveShareNativeV3MeshPeerLinkManager,
        reconciler: ClipLiveShareServerMeshPeerReconciler
    ) {
        self.manager = manager
        self.reconciler = reconciler
    }

    func events() async
        -> AsyncStream<ClipLiveShareNativeV3MeshPeerLinkManagerEvent>
    {
        await reconciler.peerLinkEvents()
    }

    func applyRoster(
        _ roster: ServerCoordinatedMeshVerifiedRoster
    ) async throws -> ClipLiveShareServerMeshReconciliationResult {
        // The creator-certified descriptor, not user-agent text, chooses the
        // media contract before any new transport creates its first offer.
        // Native edges advertise one-encoder compatibility preferences; Web
        // viewer edges remain exact and can never trigger fallback encoding.
        await manager.setVideoCodecNegotiationPolicies(
            Dictionary(uniqueKeysWithValues: roster.members.compactMap {
                member in
                guard member.participantID != roster.localParticipantID else {
                    return nil
                }
                let policy: WebRTCVideoCodecNegotiationPolicy =
                    member.descriptor.clientKind == .webViewer
                        && member.descriptor.capabilityProfile == .webViewerV1
                    ? .exact
                    : .nativeCompatible
                return (member.participantID, policy)
            })
        )
        return try await reconciler.applyRoster(
            .init(
                revision: roster.revision,
                participantIDs: roster.participantIDs,
                localPairs: Set(roster.pairsByParticipant.values.map {
                    .init(
                        pairID: $0.pairID,
                        epoch: $0.epoch,
                        remoteParticipantID: $0.remoteParticipantID
                    )
                })
            )
        )
    }

    func reconciliationSnapshot() async
        -> ClipLiveShareServerMeshPeerReconcilerSnapshot
    {
        await reconciler.snapshot()
    }

    func linkSnapshot() async
        -> ClipLiveShareNativeV3MeshPeerLinkManagerSnapshot
    {
        await manager.snapshot()
    }

    func requestNegotiation(
        with participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await manager.requestNegotiation(with: participantID)
    }

    func applyRemoteNegotiation(
        _ targeted: ClipLiveShareNativeV3TargetedNegotiation,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await manager.applyRemoteNegotiation(
            targeted,
            from: participantID
        )
    }

    func restartLink(
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await manager.restartLink(to: participantID)
    }

    func recreateLink(
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await reconciler.recreatePair(with: participantID)
    }

    func disconnect(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await manager.disconnectParticipant(participantID)
    }

    func sendReliable(
        _ data: Data,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await manager.sendControlMessage(data, to: participantID)
    }

    func sendEphemeral(
        _ data: Data,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async -> Bool {
        await manager.sendEphemeralControlMessage(data, to: participantID)
    }

    func remoteVideoStream(
        for descriptor: ClipLiveShareStreamDescriptor,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws -> WebRTCRemoteVideoStream? {
        try await manager.remoteVideoStream(
            for: descriptor,
            from: participantID
        )
    }

    func setRemoteParticipantAudioPlaybackEnabled(
        _ enabled: Bool,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await manager.setRemoteParticipantAudioPlaybackEnabled(
            enabled,
            for: participantID
        )
    }

    func setRemoteParticipantAudioVolume(
        _ volume: Double,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await manager.setRemoteParticipantAudioVolume(
            volume,
            for: participantID
        )
    }

    func setOutboundMediaEnabled(
        _ enabled: Bool,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await manager.setOutboundMediaEnabled(
            enabled,
            for: participantID
        )
    }

    func updateSenderPolicy(_ policy: WebRTCSenderPolicy) async {
        await manager.updateSenderPolicy(policy)
    }

    func updateSenderPolicies(
        _ policiesBySlot: [Int: WebRTCSenderPolicy],
        fallback: WebRTCSenderPolicy,
        videoEncodingMode: LiveShareEncodingMode
    ) async {
        await manager.updateSenderPolicies(
            policiesBySlot,
            fallback: fallback,
            videoEncodingMode: videoEncodingMode
        )
    }

    func updateVideoCodecPreference(
        _ codec: WebRTCVideoCodec,
        for participantID: ClipLiveShareNativeV3ParticipantID,
        rollbackTo previousCodec: WebRTCVideoCodec
    ) async throws {
        try await manager.updateVideoCodecPreference(
            codec,
            for: participantID,
            rollbackTo: previousCodec
        )
    }

    func restoreVideoCodecPreference(
        _ codec: WebRTCVideoCodec,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await manager.restoreVideoCodecPreference(
            codec,
            for: participantID
        )
    }

    func currentVideoCodecPreference(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws -> WebRTCVideoCodec? {
        try await manager.currentVideoCodecPreference(for: participantID)
    }

    func rollbackLocalOfferIfNeeded(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await manager.rollbackLocalOfferIfNeeded(for: participantID)
    }

    func refreshStatistics() async throws
        -> [ClipLiveShareNativeV3PeerStatistics]
    {
        try await manager.statistics()
    }

    func close() async {
        await reconciler.close()
    }
}

struct ServerCoordinatedMeshMediaRuntimeSnapshot: Equatable, Sendable {
    let roster: ServerCoordinatedMeshVerifiedRoster
    let reconciliation: ClipLiveShareServerMeshPeerReconcilerSnapshot
    let links: ClipLiveShareNativeV3MeshPeerLinkManagerSnapshot
    let sourceSnapshots:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3SourceSnapshot]
    let remoteVideoTrackIDs:
        [ClipLiveShareNativeV3ParticipantID: Set<ClipLiveShareMediaTrackID>]
    let audioTrackIDs: [ClipLiveShareNativeV3ParticipantID: String]
    let statistics:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3PeerStatistics]
    let sourceCursors:
        [ClipLiveShareNativeV3SourceKey: ClipLiveShareNativeV3SourceCursor]
    let collaboration:
        [ClipLiveShareNativeV3SourceKey: ClipLiveShareNativeV3CollaborationState]
}

enum ServerCoordinatedMeshMediaRuntimeEvent: Equatable, Sendable {
    case snapshotChanged(ServerCoordinatedMeshMediaRuntimeSnapshot)
    case sourceCursorReceived(
        ClipLiveShareNativeV3SourceCursor,
        from: ClipLiveShareNativeV3ParticipantID
    )
    /// A signature-verified friendship handshake message received on the
    /// authenticated pair's reliable ordered DataChannel. Persistence and
    /// user consent remain app concerns; the media runtime only enforces the
    /// exact room, participant-incarnation, and persistent-identity binding.
    case friendshipMessageReceived(
        ClipLiveShareServerRoomV4SignedFriendMessage,
        from: ClipLiveShareNativeV3ParticipantID
    )
    case pairFailed(
        participantID: ClipLiveShareNativeV3ParticipantID,
        message: String
    )
    /// Emitted only after the latest local source manifest has crossed this
    /// pair's reliable channel. A connected ICE state alone is not proof that
    /// the peer has caught up with room-control state.
    case pairRecovered(participantID: ClipLiveShareNativeV3ParticipantID)
    case closed
}

enum ServerCoordinatedMeshMediaRuntimeError:
    Error, Equatable, LocalizedError, Sendable
{
    case alreadyStarted
    case notStarted
    case closed
    case staleRoster
    case unknownParticipant
    case invalidPairSignal
    case stalePairEpoch
    case stalePairSignal
    case pairSignalBufferFull
    case unexpectedControlMessage
    case sourceOwnerMismatch
    case staleSourceRevision
    case sourceNotPublished
    case invalidICECandidate
    case unsupportedParticipantCapability

    var errorDescription: String? {
        switch self {
        case .alreadyStarted: "The server-coordinated media runtime is already started."
        case .notStarted: "The server-coordinated media runtime has not started."
        case .closed: "The server-coordinated media runtime is closed."
        case .staleRoster: "The server-coordinated media roster is stale."
        case .unknownParticipant: "The participant is not in the verified roster."
        case .invalidPairSignal: "The authenticated signal belongs to another pair."
        case .stalePairEpoch: "The authenticated signal uses the wrong pair epoch."
        case .stalePairSignal: "The authenticated pair signal is stale, duplicated, or out of order."
        case .pairSignalBufferFull: "The bounded pair-signaling buffer is full."
        case .unexpectedControlMessage: "The direct peer sent an unsupported control message."
        case .sourceOwnerMismatch: "The source snapshot does not belong to its authenticated sender."
        case .staleSourceRevision: "The source snapshot revision is stale."
        case .sourceNotPublished: "The collaboration event refers to an unpublished source."
        case .invalidICECandidate: "The pair signal contains an invalid ICE candidate."
        case .unsupportedParticipantCapability:
            "The participant profile does not allow this operation."
        }
    }
}

/// Clean-slate app media runtime for a service-coordinated full mesh.
///
/// It has no creator authority, election, quorum, provisional participant or
/// negotiation handoff. The service session supplies a verified complete
/// roster and transports opaque encrypted pair signaling; all source/audio/
/// collaboration state stays on direct reliable or ephemeral DataChannels.
actor ServerCoordinatedMeshMediaRuntime {
    typealias SendPairSignal = @Sendable (
        ClipLiveShareServerRoomV4PairContext,
        ClipLiveShareServerRoomV4PairSignalPayload,
        ClipLiveShareServerRoomV4MemberHandle
    ) async throws -> Void

    private static let mediaMembershipRevision = try!
        ClipLiveShareNativeV3MembershipRevision(rawValue: 1)
#if DEBUG
    private static let pointerTransportLogger = Logger(
        subsystem: ApplicationDirectories.bundleIdentifier,
        category: "collaboration-pointer"
    )

    private struct EphemeralBroadcastDiagnostics: Sendable {
        let acceptedPeerCount: Int
        let droppedPeerCount: Int
    }
#endif
    /// Signaling normally arrives over an ordered WebSocket, so a handful of
    /// messages is ample to cover the brief interval between a roster update
    /// and local pair allocation. Bounds prevent an authenticated but stale
    /// sender from retaining unbounded data.
    private static let maximumPendingSignalPairs =
        ClipLiveShareServerRoomV4.maximumParticipants * 2
    private static let maximumPendingSignalsPerPair = 64
    private static let sourceSyncRetryDelays: [Duration] = [
        .milliseconds(50),
        .milliseconds(150),
        .milliseconds(350),
        .milliseconds(750),
        .seconds(1),
    ]
    private static let pairRecoveryRetryDelays: [Duration] = [
        .milliseconds(100),
        .milliseconds(300),
        .milliseconds(750),
    ]
    /// The answerer asks the canonical offerer to originate each recovery
    /// exchange. Give the final encrypted request time to produce and apply its
    /// offer before reporting that the bounded recovery sequence was exhausted.
    private static let pairRecoveryFinalGrace: Duration = .seconds(1)

    private struct PendingPairSignalKey: Hashable, Sendable {
        let pairID: ClipLiveShareServerRoomV4PairID
        let senderHandle: ClipLiveShareServerRoomV4MemberHandle
    }

    private let links: any ServerCoordinatedMeshMediaLinkManaging
    private let sendPairSignalAction: SendPairSignal
    private let now: @Sendable () -> ClipLiveShareNativeTimestamp
    private var roster: ServerCoordinatedMeshVerifiedRoster?
    private var sourceSnapshots:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3SourceSnapshot] = [:]
    private var remoteVideoTrackIDs:
        [ClipLiveShareNativeV3ParticipantID: Set<ClipLiveShareMediaTrackID>] = [:]
    private var audioTrackIDs:
        [ClipLiveShareNativeV3ParticipantID: String] = [:]
    private var statistics:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3PeerStatistics] = [:]
    private var sourceCursors:
        [ClipLiveShareNativeV3SourceKey: ClipLiveShareNativeV3SourceCursor] = [:]
    private var collaboration:
        [ClipLiveShareNativeV3SourceKey: ClipLiveShareNativeV3CollaborationState] = [:]
    private var synchronizedSourceRevisionByPeer:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3SourceRevision] = [:]
    /// Sending over the pair actor suspends this actor. Multiple ready-link
    /// events can therefore re-enter source synchronization before the first
    /// send records its revision. Keep one source manifest in flight per peer
    /// so a connection transition cannot publish duplicate manifests or race
    /// an older revision over a newer one.
    private var sourceSyncInFlightTokens:
        [ClipLiveShareNativeV3ParticipantID: UUID] = [:]
    private var sourceSyncRetryTasks:
        [ClipLiveShareNativeV3ParticipantID: Task<Void, Never>] = [:]
    private var sourceSyncRetryTokens:
        [ClipLiveShareNativeV3ParticipantID: UUID] = [:]
    private var pairRecoveryTasks:
        [ClipLiveShareNativeV3ParticipantID: Task<Void, Never>] = [:]
    private var pairRecoveryTokens:
        [ClipLiveShareNativeV3ParticipantID: UUID] = [:]
    private var pendingPairSignals:
        [PendingPairSignalKey: [ServerCoordinatedMeshAuthenticatedPairSignal]] = [:]
    private var drainingPairSignalKeys: Set<PendingPairSignalKey> = []
    /// A failed SDP exchange invalidates every ICE candidate from that
    /// generation. Keep dropping candidates for this pair until a fresh offer
    /// or answer is successfully applied to the replacement transport.
    private var pairsAwaitingFreshSessionDescription:
        Set<PendingPairSignalKey> = []
    /// Web codec rejection rolls signaling back without negotiating a fallback.
    /// Keep that edge media-disabled until a later supported exact-codec
    /// exchange completes successfully.
    private var codecRejectedParticipants:
        Set<ClipLiveShareNativeV3ParticipantID> = []
    private var lastAppliedPairSignalSequence:
        [ClipLiveShareServerRoomV4PairID: UInt64] = [:]
    private var highestObservedPairSignalSequence:
        [PendingPairSignalKey: UInt64] = [:]
    private var knownMemberHandles:
        Set<ClipLiveShareServerRoomV4MemberHandle> = []
    private var nextLocalSourceRevisionRawValue: UInt64 = 0
    private var eventTask: Task<Void, Never>?
    private var continuations: [
        UUID: AsyncStream<ServerCoordinatedMeshMediaRuntimeEvent>.Continuation
    ] = [:]
    private var isStarted = false
    /// Actor reentrancy lets pair/link events arrive while the reconciler is
    /// still applying a server roster. Queued SDP must wait for that
    /// transaction to finish; otherwise pair-scoped structural recovery would
    /// race the reconciler and fail with `reconciliationInProgress`.
    private var isApplyingRoster = false
    private var isClosed = false

    init(
        links: any ServerCoordinatedMeshMediaLinkManaging,
        sendPairSignal: @escaping SendPairSignal,
        now: @escaping @Sendable () -> ClipLiveShareNativeTimestamp = {
            try! ClipLiveShareNativeTimestamp(date: Date())
        }
    ) {
        self.links = links
        sendPairSignalAction = sendPairSignal
        self.now = now
    }

    func events() -> AsyncStream<ServerCoordinatedMeshMediaRuntimeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: ServerCoordinatedMeshMediaRuntimeEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        guard !isClosed else {
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    func snapshot() async throws
        -> ServerCoordinatedMeshMediaRuntimeSnapshot
    {
        try requireActive()
        return try await makeSnapshot()
    }

    func start(
        roster: ServerCoordinatedMeshVerifiedRoster
    ) async throws {
        guard !isClosed else { throw ServerCoordinatedMeshMediaRuntimeError.closed }
        guard !isStarted else {
            throw ServerCoordinatedMeshMediaRuntimeError.alreadyStarted
        }
        isStarted = true
        let stream = await links.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handleLinkEvent(event)
            }
        }
        try await applyRoster(roster)
    }

    func applyRoster(
        _ incoming: ServerCoordinatedMeshVerifiedRoster
    ) async throws {
        try requireActive()
        let replacedParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>
        if let roster {
            guard incoming.roomID == roster.roomID,
                  incoming.sessionID == roster.sessionID,
                  incoming.localHandle == roster.localHandle,
                  incoming.localParticipantID == roster.localParticipantID
            else {
                throw ServerCoordinatedMeshMediaRuntimeError.staleRoster
            }
            if incoming.revision == roster.revision, incoming != roster {
                throw ServerCoordinatedMeshMediaRuntimeError.staleRoster
            }
            guard incoming.revision >= roster.revision else {
                throw ServerCoordinatedMeshMediaRuntimeError.staleRoster
            }
            replacedParticipantIDs = Set(incoming.members.compactMap { member in
                guard member.participantID != incoming.localParticipantID,
                      let previous = roster.member(
                          for: member.participantID
                      ),
                      previous.handle != member.handle else { return nil }
                return member.participantID
            })
        } else {
            replacedParticipantIDs = []
        }
        // The service roster is authoritative even when one pair allocation
        // fails. Reconciliation returns those failures independently.
        roster = incoming
        knownMemberHandles.formUnion(incoming.members.map(\.handle))
        isApplyingRoster = true
        let result: ClipLiveShareServerMeshReconciliationResult
        do {
            result = try await links.applyRoster(incoming)
        } catch {
            isApplyingRoster = false
            throw error
        }
        isApplyingRoster = false
        // A deliberate leave/rejoin keeps the participant's cryptographic
        // identity but receives a new opaque service handle and pair context.
        // Source revisions begin at one in the new app runtime, so retaining
        // the departed incarnation's revision would reject the replacement's
        // first manifest as stale and leave its windows missing indefinitely.
        for participantID in replacedParticipantIDs {
            resetRemoteParticipantIncarnation(participantID)
        }
        pruneState(to: incoming.participantIDs)
        await enforceReceiveOnlyWebProfiles(in: incoming)
        for failure in result.failedPairs {
            emit(.pairFailed(
                participantID: failure.remoteParticipantID,
                message: failure.message
            ))
        }
        let linkSnapshot = await links.linkSnapshot()
        await drainPendingPairSignals(using: result.snapshot)
        replayReceiverState(from: linkSnapshot)
        for link in linkSnapshot.links where link.isReady {
            await synchronizeLocalSourcesIfNeeded(to: link)
        }
        await publishSnapshot()
    }

    func publishLocalSources(
        _ sources: [ClipLiveShareNativeV3PublishedSource]
    ) async throws {
        try requireActive()
        let roster = try currentRoster()
        guard !isReceiveOnlyWebParticipant(
            roster.localParticipantID,
            in: roster
        ) || sources.isEmpty else {
            throw ServerCoordinatedMeshMediaRuntimeError
                .unsupportedParticipantCapability
        }
        guard nextLocalSourceRevisionRawValue < UInt64.max else {
            throw ClipLiveShareServerRoomV4Error.sequenceExhausted
        }
        nextLocalSourceRevisionRawValue += 1
        let snapshot = try ClipLiveShareNativeV3SourceSnapshot(
            sessionID: roster.sessionID,
            membershipRevision: Self.mediaMembershipRevision,
            ownerParticipantID: roster.localParticipantID,
            sourceRevision: .init(rawValue: nextLocalSourceRevisionRawValue),
            sources: sources
        )
        sourceSnapshots[roster.localParticipantID] = snapshot
        synchronizedSourceRevisionByPeer.removeAll(keepingCapacity: true)
        for link in (await links.linkSnapshot()).links where link.isReady {
            await synchronizeLocalSourcesIfNeeded(to: link)
        }
        pruneSourceScopedState()
        await publishSnapshot()
    }

    func broadcastSourceCursor(
        _ cursor: ClipLiveShareNativeV3SourceCursor
    ) async throws {
        try requireActive()
        let roster = try currentRoster()
        guard !isReceiveOnlyWebParticipant(
            roster.localParticipantID,
            in: roster
        ) else {
            throw ServerCoordinatedMeshMediaRuntimeError
                .unsupportedParticipantCapability
        }
        guard cursor.sessionID == roster.sessionID,
              cursor.participantID == roster.localParticipantID,
              cursor.sourceKey.ownerParticipantID == roster.localParticipantID,
              sourceSnapshots[roster.localParticipantID]?.sources.contains(
                where: { $0.key == cursor.sourceKey }
              ) == true else {
            throw ServerCoordinatedMeshMediaRuntimeError.sourceOwnerMismatch
        }
        sourceCursors[cursor.sourceKey] = cursor
        let data = try ClipLiveShareMeshMediaControlCodec.encode(
            .sourceCursor(cursor)
        )
        await broadcastEphemeral(data)
        emit(.sourceCursorReceived(cursor, from: roster.localParticipantID))
        await publishSnapshot()
    }

    func broadcastCollaboration(
        _ event: ClipLiveShareNativeV3CollaborationEvent
    ) async throws {
        try requireActive()
        let roster = try currentRoster()
        guard !isReceiveOnlyWebParticipant(
            roster.localParticipantID,
            in: roster
        ) else {
            throw ServerCoordinatedMeshMediaRuntimeError
                .unsupportedParticipantCapability
        }
        guard event.context.sessionID == roster.sessionID,
              event.context.participantID == roster.localParticipantID,
              sourceExists(event.context.sourceKey) else {
            throw ServerCoordinatedMeshMediaRuntimeError.sourceNotPublished
        }
        try applyCollaboration(
            event,
            authenticatedParticipantID: roster.localParticipantID
        )
        let data = try ClipLiveShareMeshMediaControlCodec.encode(
            .collaboration(event)
        )
        switch event {
        case .pointer:
            // Pointer positions are replaceable. Never queue old mouse samples
            // behind durable room/annotation state when a pair is pressured.
#if DEBUG
            if case let .pointer(pointer) = event {
                let diagnostics = await broadcastEphemeralWithDiagnostics(
                    data,
                    excludingReceiveOnlyWebParticipants: true
                )
                let visibility = pointer.position == nil ? "hide" : "visible"
                Self.pointerTransportLogger.debug(
                    "Pointer broadcast sequence=\(pointer.context.sequence, privacy: .public) state=\(visibility, privacy: .public) acceptedPeers=\(diagnostics.acceptedPeerCount, privacy: .public) droppedPeers=\(diagnostics.droppedPeerCount, privacy: .public)"
                )
            }
#else
            await broadcastEphemeral(
                data,
                excludingReceiveOnlyWebParticipants: true
            )
#endif
        case .ping, .strokeBegin, .strokePoints, .strokeEnd, .clear:
            // Ink and commands form an ordered state machine. Losing or
            // reordering any member would corrupt the annotation state.
            await broadcastReliable(
                data,
                excludingReceiveOnlyWebParticipants: true
            )
        }
        await publishSnapshot()
    }

    func sendFriendshipMessage(
        _ message: ClipLiveShareServerRoomV4SignedFriendMessage,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try requireActive()
        let roster = try currentRoster()
        guard
            let local = roster.member(for: roster.localParticipantID),
            let remote = roster.member(for: participantID)
        else {
            throw ServerCoordinatedMeshMediaRuntimeError.unknownParticipant
        }
        guard !isReceiveOnlyWebParticipant(local),
              !isReceiveOnlyWebParticipant(remote) else {
            throw ServerCoordinatedMeshMediaRuntimeError
                .unsupportedParticipantCapability
        }
        try message.verifyTransportContext(
            roomID: roster.roomID,
            sessionID: roster.sessionID,
            authorParticipantID: roster.localParticipantID,
            recipientParticipantID: participantID,
            authorIdentity: local.descriptor.identity,
            recipientIdentity: remote.descriptor.identity,
            at: now()
        )
        let data = try ClipLiveShareMeshMediaControlCodec.encode(
            .friendship(message)
        )
        try await links.sendReliable(data, to: participantID)
    }

    /// Prunes source-scoped pointer, ping, and ink values after their bounded
    /// authenticated lifetime. Expiry is local presentation state and never
    /// changes membership or renegotiates a peer connection.
    @discardableResult
    func pruneExpiredCollaboration(
        at timestamp: ClipLiveShareNativeTimestamp
    ) async -> Bool {
#if DEBUG
        let pointerCountBeforePrune = collaboration.values.reduce(0) {
            $0 + $1.pointers.count
        }
#endif
        var didChange = false
        for key in collaboration.keys {
            didChange =
                collaboration[key]?.pruneExpired(at: timestamp) == true
                || didChange
        }
#if DEBUG
        let pointerCountAfterPrune = collaboration.values.reduce(0) {
            $0 + $1.pointers.count
        }
        let removedPointerCount =
            pointerCountBeforePrune - pointerCountAfterPrune
        if removedPointerCount > 0 {
            Self.pointerTransportLogger.debug(
                "Pointer prune removed=\(removedPointerCount, privacy: .public)"
            )
        }
#endif
        guard didChange else { return false }
        await publishSnapshot()
        return true
    }

    /// Returns the existing pair-local receiver stream without changing any
    /// capture or encoder behavior. Room/session code uses this seam to keep
    /// native viewer windows independent from v4 membership orchestration.
    func remoteVideoStream(
        for descriptor: ClipLiveShareStreamDescriptor,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws -> WebRTCRemoteVideoStream? {
        try requireKnownRemoteParticipant(participantID)
        guard let roster,
              !isReceiveOnlyWebParticipant(participantID, in: roster) else {
            return nil
        }
        return try await links.remoteVideoStream(
            for: descriptor,
            from: participantID
        )
    }

    func setRemoteParticipantAudioPlaybackEnabled(
        _ enabled: Bool,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try requireKnownRemoteParticipant(participantID)
        if let roster,
           isReceiveOnlyWebParticipant(participantID, in: roster) {
            try await links.setRemoteParticipantAudioPlaybackEnabled(
                false,
                for: participantID
            )
            return
        }
        try await links.setRemoteParticipantAudioPlaybackEnabled(
            enabled,
            for: participantID
        )
    }

    func setRemoteParticipantAudioVolume(
        _ volume: Double,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try requireKnownRemoteParticipant(participantID)
        if let roster,
           isReceiveOnlyWebParticipant(participantID, in: roster) {
            try await links.setRemoteParticipantAudioPlaybackEnabled(
                false,
                for: participantID
            )
            return
        }
        try await links.setRemoteParticipantAudioVolume(
            volume,
            for: participantID
        )
    }

    func setOutboundMediaEnabled(
        _ enabled: Bool,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try requireKnownRemoteParticipant(participantID)
        try await links.setOutboundMediaEnabled(enabled, for: participantID)
    }

    func setOutboundMediaEnabledForAllPeers(_ enabled: Bool) async {
        guard let roster else { return }
        for participantID in roster.pairsByParticipant.keys {
            do {
                try await links.setOutboundMediaEnabled(
                    enabled,
                    for: participantID
                )
            } catch {
                emit(.pairFailed(
                    participantID: participantID,
                    message: error.localizedDescription
                ))
            }
        }
    }

    func updateSenderPolicy(_ policy: WebRTCSenderPolicy) async throws {
        try requireActive()
        await links.updateSenderPolicy(policy)
    }

    func updateSenderPolicies(
        _ policiesBySlot: [Int: WebRTCSenderPolicy],
        fallback: WebRTCSenderPolicy,
        videoEncodingMode: LiveShareEncodingMode
    ) async throws {
        try requireActive()
        await links.updateSenderPolicies(
            policiesBySlot,
            fallback: fallback,
            videoEncodingMode: videoEncodingMode
        )
    }

    func updateVideoCodecPreference(
        _ codec: WebRTCVideoCodec,
        for participantID: ClipLiveShareNativeV3ParticipantID,
        rollbackTo previousCodec: WebRTCVideoCodec
    ) async throws {
        try requireKnownRemoteParticipant(participantID)
        let authoritativePreviousCodec =
            try await links.currentVideoCodecPreference(for: participantID)
            ?? previousCodec
        try await links.updateVideoCodecPreference(
            codec,
            for: participantID,
            rollbackTo: authoritativePreviousCodec
        )
        guard let roster,
              let pair = roster.pairsByParticipant[participantID],
              let member = roster.member(for: participantID) else {
            throw ServerCoordinatedMeshMediaRuntimeError.unknownParticipant
        }
        // setCodecPreferences does not reliably raise negotiation-needed in
        // libwebrtc. Start one explicit canonical exchange instead: the fixed
        // offerer creates the offer, while an answerer sends one authenticated
        // request to that offerer. This keeps the change pair-local and avoids
        // duplicate offers/glare across the complete mesh.
        do {
            if pair.context.initialOfferer == roster.localHandle {
                try await links.requestNegotiation(with: participantID)
            } else {
                try await sendPairSignalAction(
                    pair.context,
                    .codecRenegotiationRequest(
                        epoch: pair.epoch,
                        codec: MeshParticipantMediaSettingsPolicy
                            .liveShareVideoCodec(codec)
                    ),
                    member.handle
                )
            }
        } catch {
            try? await links.rollbackLocalOfferIfNeeded(
                for: participantID
            )
            try? await links.restoreVideoCodecPreference(
                authoritativePreviousCodec,
                for: participantID
            )
            throw error
        }
    }

    func rollbackLocalOfferIfNeeded(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try requireKnownRemoteParticipant(participantID)
        try await links.rollbackLocalOfferIfNeeded(for: participantID)
    }

    /// Restarts exactly one failed edge. Membership, captures, encoders and
    /// unrelated peer connections remain untouched.
    func retryPairConnection(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try requireKnownRemoteParticipant(participantID)
        pairRecoveryTasks.removeValue(forKey: participantID)?.cancel()
        pairRecoveryTokens[participantID] = nil
        try await beginPairRecovery(for: participantID)
    }

    @discardableResult
    func refreshStatistics() async throws
        -> [ClipLiveShareNativeV3PeerStatistics]
    {
        try requireActive()
        let values = try await links.refreshStatistics()
        statistics = Dictionary(
            uniqueKeysWithValues: values.map { ($0.remoteParticipantID, $0) }
        )
        await publishSnapshot()
        return values
    }

    func receiveAuthenticatedPairSignal(
        _ signal: ServerCoordinatedMeshAuthenticatedPairSignal
    ) async throws {
        guard !isClosed else {
            throw ServerCoordinatedMeshMediaRuntimeError.closed
        }
        guard signal.sequence > 0 else {
            throw ServerCoordinatedMeshMediaRuntimeError.stalePairSignal
        }
        try enqueuePairSignal(signal)

        // Pair signaling is allowed to beat both initial startup and a later
        // roster revision. It remains pair-local in the bounded queue until
        // the exact verified pair context and its WebRTC transport exist.
        guard isStarted, roster != nil, !isApplyingRoster else { return }
        await drainPendingPairSignalsForCurrentRoster()
    }

    private func requireKnownRemoteParticipant(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) throws {
        try requireActive()
        guard let roster,
              participantID != roster.localParticipantID,
              roster.pairsByParticipant[participantID] != nil else {
            throw ServerCoordinatedMeshMediaRuntimeError.unknownParticipant
        }
    }

    private func applyPairSignal(
        _ signal: ServerCoordinatedMeshAuthenticatedPairSignal,
        member: ServerCoordinatedMeshVerifiedMember,
        pair: ServerCoordinatedMeshVerifiedPair,
        roster: ServerCoordinatedMeshVerifiedRoster
    ) async throws {
        let key = try ClipLiveShareNativeV3PeerLinkKey(
            roster.localParticipantID,
            member.participantID
        )
        switch signal.payload {
        case let .offer(_, sdp):
            try await links.applyRemoteNegotiation(
                .init(
                    peerLinkKey: key,
                    targetParticipantID: roster.localParticipantID,
                    payload: .sessionDescription(.init(kind: .offer, sdp: sdp))
                ),
                from: member.participantID
            )
        case let .answer(_, sdp):
            try await links.applyRemoteNegotiation(
                .init(
                    peerLinkKey: key,
                    targetParticipantID: roster.localParticipantID,
                    payload: .sessionDescription(.init(kind: .answer, sdp: sdp))
                ),
                from: member.participantID
            )
        case let .iceCandidate(_, candidate, mediaID, mediaLineIndex):
            guard
                let index = mediaLineIndex.flatMap(Int32.init(exactly:))
                    ?? (mediaLineIndex == nil ? 0 : nil)
            else {
                throw ServerCoordinatedMeshMediaRuntimeError.invalidICECandidate
            }
            try await links.applyRemoteNegotiation(
                .init(
                    peerLinkKey: key,
                    targetParticipantID: roster.localParticipantID,
                    payload: .iceCandidate(.init(
                        candidate: candidate,
                        sdpMid: mediaID,
                        sdpMLineIndex: index
                    ))
                ),
                from: member.participantID
            )
        case .iceRestart:
            try await links.restartLink(to: member.participantID)
        case .renegotiationRequest:
            guard pair.context.initialOfferer == roster.localHandle else {
                throw ServerCoordinatedMeshMediaRuntimeError.invalidPairSignal
            }
            // A peer can request a clean exchange after replacing its local
            // transport. Cancel any unanswered offer from the old exchange
            // before originating the canonical replacement offer.
            try? await links.rollbackLocalOfferIfNeeded(
                for: member.participantID
            )
            try await links.requestNegotiation(with: member.participantID)
        case let .codecRenegotiationRequest(_, codec):
            guard pair.context.initialOfferer == roster.localHandle,
                  member.descriptor.clientKind == .nativeApp,
                  member.descriptor.capabilityProfile == .nativeV1 else {
                throw ServerCoordinatedMeshMediaRuntimeError.invalidPairSignal
            }
            let requestedCodec = MeshParticipantMediaSettingsPolicy.videoCodec(
                codec
            )
            let authoritativePreviousCodec =
                try await links.currentVideoCodecPreference(
                    for: member.participantID
                ) ?? requestedCodec
            // A codec request is distinct from generic pair recovery: apply
            // the encrypted participant choice to the canonical offerer before
            // it creates the one offer. Both Native endpoints then answer with
            // the same negotiated codec without rebuilding capture or adding
            // another encoder.
            try? await links.rollbackLocalOfferIfNeeded(
                for: member.participantID
            )
            do {
                try await links.updateVideoCodecPreference(
                    requestedCodec,
                    for: member.participantID,
                    rollbackTo: authoritativePreviousCodec
                )
                try await links.requestNegotiation(with: member.participantID)
            } catch {
                try? await links.rollbackLocalOfferIfNeeded(
                    for: member.participantID
                )
                try? await links.restoreVideoCodecPreference(
                    authoritativePreviousCodec,
                    for: member.participantID
                )
                throw error
            }
        case let .codecRenegotiationRejected(_, codec):
            guard member.descriptor.clientKind == .webViewer,
                  member.descriptor.capabilityProfile == .webViewerV1 else {
                throw ServerCoordinatedMeshMediaRuntimeError.invalidPairSignal
            }
            let rejectedCodec = MeshParticipantMediaSettingsPolicy.videoCodec(
                codec
            )
            let currentCodec = try await links.currentVideoCodecPreference(
                for: member.participantID
            ) ?? rejectedCodec
            try await links.rollbackLocalOfferIfNeeded(
                for: member.participantID
            )
            try await links.setOutboundMediaEnabled(
                false,
                for: member.participantID
            )
            codecRejectedParticipants.insert(member.participantID)
            // A second user selection can supersede the rejected offer before
            // its authenticated response arrives. Roll that old offer back,
            // keep media disabled, and immediately negotiate the newer exact
            // codec rather than failing/recreating the otherwise healthy edge.
            if currentCodec != rejectedCodec {
                if pair.context.initialOfferer == roster.localHandle {
                    try await links.requestNegotiation(
                        with: member.participantID
                    )
                } else {
                    try await sendPairSignalAction(
                        pair.context,
                        .codecRenegotiationRequest(
                            epoch: pair.epoch,
                            codec: MeshParticipantMediaSettingsPolicy
                                .liveShareVideoCodec(currentCodec)
                        ),
                        member.handle
                    )
                }
            }
        case .close:
            try await links.disconnect(member.participantID)
        }
    }

    private func enqueuePairSignal(
        _ signal: ServerCoordinatedMeshAuthenticatedPairSignal
    ) throws {
        let key = PendingPairSignalKey(
            pairID: signal.pairID,
            senderHandle: signal.senderHandle
        )
        let highestObserved = max(
            lastAppliedPairSignalSequence[signal.pairID] ?? 0,
            highestObservedPairSignalSequence[key] ?? 0
        )
        guard signal.sequence > highestObserved else {
            throw ServerCoordinatedMeshMediaRuntimeError.stalePairSignal
        }
        if pendingPairSignals[key] == nil,
           pendingPairSignals.count >= Self.maximumPendingSignalPairs {
            throw ServerCoordinatedMeshMediaRuntimeError.pairSignalBufferFull
        }
        guard (pendingPairSignals[key]?.count ?? 0)
            < Self.maximumPendingSignalsPerPair else {
            throw ServerCoordinatedMeshMediaRuntimeError.pairSignalBufferFull
        }
        highestObservedPairSignalSequence[key] = signal.sequence
        pendingPairSignals[key, default: []].append(signal)
    }

    private func drainPendingPairSignalsForCurrentRoster() async {
        guard roster != nil, !isApplyingRoster else { return }
        await drainPendingPairSignals(using: await links.reconciliationSnapshot())
    }

    /// Drains only pairs that exist in both the verified roster and the local
    /// reconciler. This is what makes signal-before-roster and
    /// signal-before-transport harmless without making one pair failure a room
    /// failure.
    private func drainPendingPairSignals(
        using linkState: ClipLiveShareServerMeshPeerReconcilerSnapshot
    ) async {
        guard let roster else { return }
        for key in Array(pendingPairSignals.keys) {
            await drainPendingPairSignals(
                for: key,
                roster: roster,
                linkState: linkState
            )
        }
    }

    private func drainPendingPairSignals(
        for key: PendingPairSignalKey,
        roster: ServerCoordinatedMeshVerifiedRoster,
        linkState: ClipLiveShareServerMeshPeerReconcilerSnapshot
    ) async {
        guard drainingPairSignalKeys.insert(key).inserted else { return }
        defer { drainingPairSignalKeys.remove(key) }

        let binding: (
            member: ServerCoordinatedMeshVerifiedMember,
            pair: ServerCoordinatedMeshVerifiedPair
        )
        do {
            guard let value = try verifiedPairBinding(for: key, roster: roster)
            else { return }
            binding = value
        } catch {
            pendingPairSignals[key] = nil
            return
        }
        guard linkState.pairs.contains(where: {
            $0.pairID == binding.pair.pairID
                && $0.epoch == binding.pair.epoch
                && $0.link.remoteParticipantID == binding.member.participantID
        }) else { return }

        // Removing each batch before awaiting lets concurrently arriving
        // messages append to a fresh queue. The loop then picks up that next
        // batch without allowing a second drain to race the first one.
        while let signals = pendingPairSignals.removeValue(forKey: key),
              !signals.isEmpty {
            var lastSequence = lastAppliedPairSignalSequence[key.pairID] ?? 0
            for signal in signals {
                guard signal.sequence > lastSequence else {
                    // The encrypted sender can consume a sequence before an
                    // ambiguous WebSocket write is lost. Strictly increasing
                    // delivery rejects replays without wedging the pair on a
                    // harmless sequence gap.
                    continue
                }
                if let epoch = signal.payload.epoch,
                   epoch != binding.pair.epoch {
                    lastSequence = signal.sequence
                    lastAppliedPairSignalSequence[key.pairID] = lastSequence
                    continue
                }
                if pairsAwaitingFreshSessionDescription.contains(key),
                   !signal.payload.isSessionDescription {
                    lastSequence = signal.sequence
                    lastAppliedPairSignalSequence[key.pairID] = lastSequence
                    continue
                }
                do {
                    guard let currentRoster = self.roster,
                          let currentBinding = try verifiedPairBinding(
                            for: key,
                            roster: currentRoster
                          ),
                          currentBinding.pair == binding.pair else {
                        pendingPairSignals[key] = Array(
                            signals.drop { $0.sequence < signal.sequence }
                        ) + (pendingPairSignals[key] ?? [])
                        return
                    }
                    try await applyPairSignal(
                        signal,
                        member: binding.member,
                        pair: binding.pair,
                        roster: currentRoster
                    )
                    if signal.payload.isSessionDescription,
                       codecRejectedParticipants.contains(
                        binding.member.participantID
                       ) {
                        try await links.setOutboundMediaEnabled(
                            true,
                            for: binding.member.participantID
                        )
                        codecRejectedParticipants.remove(
                            binding.member.participantID
                        )
                    }
                    if signal.payload.isSessionDescription {
                        pairsAwaitingFreshSessionDescription.remove(key)
                    }
                    lastSequence = signal.sequence
                    lastAppliedPairSignalSequence[key.pairID] = lastSequence
                } catch {
                    // Consume the signal that failed. Once SDP fails, every
                    // candidate already queued behind it belongs to the
                    // discarded description generation; retain only a later
                    // session description, which establishes the next one.
                    lastAppliedPairSignalSequence[key.pairID] = signal.sequence
                    let remaining = signals.filter {
                        $0.sequence > signal.sequence
                    }
                    let retained: [ServerCoordinatedMeshAuthenticatedPairSignal]
                    if signal.payload.isSessionDescription {
                        pairsAwaitingFreshSessionDescription.insert(key)
                        var foundReplacementDescription = false
                        retained = (remaining + (pendingPairSignals[key] ?? []))
                            .filter { candidate in
                                if candidate.payload.isSessionDescription {
                                    foundReplacementDescription = true
                                    return true
                                }
                                return foundReplacementDescription
                            }
                    } else {
                        retained = remaining + (pendingPairSignals[key] ?? [])
                    }
                    if !retained.isEmpty {
                        pendingPairSignals[key] = retained
                    } else {
                        pendingPairSignals[key] = nil
                    }
                    let message: String
                    if signal.payload.isSessionDescription {
                        do {
                            markPairUnavailable(binding.member.participantID)
                            try await links.recreateLink(
                                to: binding.member.participantID
                            )
                            if binding.pair.context.initialOfferer
                                != roster.localHandle {
                                try await sendPairSignalAction(
                                    binding.pair.context,
                                    .renegotiationRequest(
                                        epoch: binding.pair.epoch
                                    ),
                                    binding.member.handle
                                )
                            }
                            message = error.localizedDescription
                        } catch let recoveryError {
                            message = "\(error.localizedDescription) "
                                + "Pair recreation failed: "
                                + recoveryError.localizedDescription
                        }
                    } else {
                        message = error.localizedDescription
                    }
                    emit(.pairFailed(
                        participantID: binding.member.participantID,
                        message: message
                    ))
                    return
                }
            }
        }
    }

    private func verifiedPairBinding(
        for key: PendingPairSignalKey,
        roster: ServerCoordinatedMeshVerifiedRoster
    ) throws -> (
        member: ServerCoordinatedMeshVerifiedMember,
        pair: ServerCoordinatedMeshVerifiedPair
    )? {
        guard let member = roster.member(for: key.senderHandle) else {
            // A genuinely new participant's authenticated signaling may beat
            // its roster snapshot. A handle observed in an older roster is a
            // departed participant, however, and must not be buffered again.
            if knownMemberHandles.contains(key.senderHandle) {
                throw ServerCoordinatedMeshMediaRuntimeError.invalidPairSignal
            }
            return nil
        }
        guard let pair = roster.pairsByParticipant[member.participantID],
              pair.pairID == key.pairID,
              try pair.context.remoteHandle(for: roster.localHandle)
                == key.senderHandle else {
            throw ServerCoordinatedMeshMediaRuntimeError.invalidPairSignal
        }
        return (member, pair)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        eventTask?.cancel()
        eventTask = nil
        sourceSyncRetryTasks.values.forEach { $0.cancel() }
        sourceSyncRetryTasks.removeAll(keepingCapacity: false)
        sourceSyncRetryTokens.removeAll(keepingCapacity: false)
        sourceSyncInFlightTokens.removeAll(keepingCapacity: false)
        pairRecoveryTasks.values.forEach { $0.cancel() }
        pairRecoveryTasks.removeAll(keepingCapacity: false)
        pairRecoveryTokens.removeAll(keepingCapacity: false)
        pendingPairSignals.removeAll(keepingCapacity: false)
        pairsAwaitingFreshSessionDescription.removeAll(keepingCapacity: false)
        codecRejectedParticipants.removeAll(keepingCapacity: false)
        lastAppliedPairSignalSequence.removeAll(keepingCapacity: false)
        highestObservedPairSignalSequence.removeAll(keepingCapacity: false)
        await links.close()
        emit(.closed)
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll(keepingCapacity: false)
    }

    private func handleLinkEvent(
        _ event: ClipLiveShareNativeV3MeshPeerLinkManagerEvent
    ) async {
        guard !isClosed, let roster else { return }
        do {
            switch event {
            case let .targetedNegotiation(targeted):
                guard let pair = roster.pairsByParticipant[
                    targeted.targetParticipantID
                ] else { return }
                let payload: ClipLiveShareServerRoomV4PairSignalPayload
                switch targeted.payload {
                case let .sessionDescription(description):
                    payload = description.kind == .offer
                        ? .offer(epoch: pair.epoch, sdp: description.sdp)
                        : .answer(epoch: pair.epoch, sdp: description.sdp)
                case let .iceCandidate(candidate):
                    guard candidate.sdpMLineIndex >= 0 else {
                        throw ServerCoordinatedMeshMediaRuntimeError
                            .invalidICECandidate
                    }
                    payload = .iceCandidate(
                        epoch: pair.epoch,
                        candidate: candidate.candidate,
                        mediaID: candidate.sdpMid,
                        mediaLineIndex: UInt32(candidate.sdpMLineIndex)
                    )
                }
                try await sendPairSignalAction(
                    pair.context,
                    payload,
                    try pair.context.remoteHandle(for: roster.localHandle)
                )
            case let .negotiationNeeded(_, participantID):
                guard let pair = roster.pairsByParticipant[participantID]
                else { return }
                if pair.context.initialOfferer == roster.localHandle {
                    try await links.requestNegotiation(with: participantID)
                } else {
                    try await sendPairSignalAction(
                        pair.context,
                        .renegotiationRequest(epoch: pair.epoch),
                        try pair.context.remoteHandle(for: roster.localHandle)
                    )
                }
            case let .controlMessageReceived(participantID, data):
                do {
                    try handleControlData(data, from: participantID)
                } catch {
                    // The signed web-v1 profile is receive-only. Malformed
                    // or otherwise forbidden control traffic from that peer
                    // is a pair-local protocol violation, not evidence that
                    // ICE or SDP needs recovery. In particular, never enter
                    // the generic recovery loop for a browser attempting to
                    // publish state it is not allowed to own.
                    if isReceiveOnlyWebParticipant(
                        participantID,
                        in: roster
                    ) {
                        // Ignore this pair's invalid Web control frame. A
                        // warning would remain stuck because recovery is
                        // intentionally not started for a capability breach.
                        // The authoritative roster and the healthy transport
                        // stay usable for later valid receive-only control.
                        break
                    } else {
                        throw error
                    }
                }
            case let .remoteVideoTrackAdded(participantID, trackID):
                guard !isReceiveOnlyWebParticipant(
                    participantID,
                    in: roster
                ) else {
                    remoteVideoTrackIDs[participantID] = nil
                    break
                }
                remoteVideoTrackIDs[participantID, default: []].insert(trackID)
            case let .remoteVideoTrackRemoved(participantID, trackID):
                remoteVideoTrackIDs[participantID]?.remove(trackID)
            case let .remoteParticipantAudioAvailable(participantID, trackID):
                if isReceiveOnlyWebParticipant(participantID, in: roster) {
                    audioTrackIDs[participantID] = nil
                    try? await links.setRemoteParticipantAudioPlaybackEnabled(
                        false,
                        for: participantID
                    )
                } else {
                    audioTrackIDs[participantID] = trackID
                }
            case let .remoteParticipantAudioRemoved(participantID, _):
                audioTrackIDs[participantID] = nil
            case let .statisticsUpdated(value):
                statistics[value.remoteParticipantID] = value
            case let .linkFailed(_, participantID, message):
                emit(.pairFailed(participantID: participantID, message: message))
                // Only the canonical offerer is allowed to originate an ICE
                // restart. If this endpoint alone observes the failure and is
                // the answerer, the manager intentionally does not restart.
                // Ask the offerer over the independently encrypted server
                // signaling channel instead. The task is pair-local and
                // coalesces repeated WebRTC failure callbacks.
                if isLocalAnswerer(for: participantID) {
                    schedulePairRecovery(for: participantID)
                }
            case let .reconnectExhausted(_, participantID):
                emit(.pairFailed(
                    participantID: participantID,
                    message: "The direct pair exhausted ICE recovery."
                ))
                schedulePairRecovery(for: participantID)
            case let .linkAdded(link), let .linkUpdated(link):
                replayReceiverState(from: await links.linkSnapshot())
                await drainPendingPairSignalsForCurrentRoster()
                if link.isReady {
                    pairRecoveryTasks.removeValue(
                        forKey: link.remoteParticipantID
                    )?.cancel()
                    pairRecoveryTokens[link.remoteParticipantID] = nil
                    // Link recovery is independent of publication state. A
                    // participant sharing no windows (or whose latest empty
                    // manifest is already synchronized) must still clear a
                    // stale pair warning as soon as its direct P2P media and
                    // reliable-control channels are verified ready.
                    emit(.pairRecovered(
                        participantID: link.remoteParticipantID
                    ))
                    await synchronizeLocalSourcesIfNeeded(to: link)
                } else if (link.connectionState == .disconnected
                            || link.connectionState == .failed),
                          isLocalAnswerer(for: link.remoteParticipantID) {
                    // `connectionStateChanged` is the only callback guaranteed
                    // for an ICE path failure; some libwebrtc failures do not
                    // also emit the transport's generic `.failed` event.
                    schedulePairRecovery(for: link.remoteParticipantID)
                }
            case let .linkRemoved(_, participantID):
                markPairUnavailable(participantID)
            case .reconnectScheduled:
                break
            case .closed:
                break
            }
            await publishSnapshot()
        } catch {
            let participantID = participantID(for: event, roster: roster)
                ?? roster.localParticipantID
            if participantID != roster.localParticipantID {
                try? await links.rollbackLocalOfferIfNeeded(
                    for: participantID
                )
                schedulePairRecovery(for: participantID)
            }
            emit(.pairFailed(
                participantID: participantID,
                message: error.localizedDescription
            ))
        }
    }

    private func handleControlData(
        _ data: Data,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) throws {
        let roster = try currentRoster()
        guard roster.participantIDs.contains(participantID),
              participantID != roster.localParticipantID else {
            throw ServerCoordinatedMeshMediaRuntimeError.unknownParticipant
        }
        let receiveOnlyWeb = isReceiveOnlyWebParticipant(
            participantID,
            in: roster
        )
        switch try ClipLiveShareMeshMediaControlCodec.decode(data) {
        case let .sourceSnapshot(snapshot):
            // Web-v1 publishes one authenticated empty manifest so reliable
            // control synchronization has the same completion semantics as a
            // Native pair. It can never own a media source. Ignore a validly
            // decoded nonempty manifest before it can mutate presentation or
            // trigger recovery on this otherwise healthy edge.
            guard !receiveOnlyWeb || snapshot.sources.isEmpty else { return }
            guard snapshot.sessionID == roster.sessionID,
                  snapshot.membershipRevision == Self.mediaMembershipRevision,
                  snapshot.ownerParticipantID == participantID else {
                throw ServerCoordinatedMeshMediaRuntimeError.sourceOwnerMismatch
            }
            if let current = sourceSnapshots[participantID] {
                if snapshot.sourceRevision < current.sourceRevision {
                    throw ServerCoordinatedMeshMediaRuntimeError
                        .staleSourceRevision
                }
                if snapshot.sourceRevision == current.sourceRevision {
                    guard snapshot == current else {
                        throw ServerCoordinatedMeshMediaRuntimeError
                            .staleSourceRevision
                    }
                    // A recovered reliable channel deliberately replays its
                    // latest manifest. Identical state is idempotent; only a
                    // conflicting value at the same revision is suspicious.
                    return
                }
            }
            sourceSnapshots[participantID] = snapshot
            pruneSourceScopedState()
        case let .sourceCursor(cursor):
            guard !receiveOnlyWeb else { return }
            guard cursor.sessionID == roster.sessionID,
                  cursor.participantID == participantID,
                  cursor.sourceKey.ownerParticipantID == participantID,
                  sourceExists(cursor.sourceKey),
                  (sourceCursors[cursor.sourceKey]?.sequence ?? 0)
                    < cursor.sequence else {
                throw ServerCoordinatedMeshMediaRuntimeError.sourceOwnerMismatch
            }
            sourceCursors[cursor.sourceKey] = cursor
            emit(.sourceCursorReceived(cursor, from: participantID))
        case let .collaboration(event):
            guard !receiveOnlyWeb else { return }
            guard event.context.sessionID == roster.sessionID,
                  sourceExists(event.context.sourceKey) else {
                throw ServerCoordinatedMeshMediaRuntimeError.sourceNotPublished
            }
            try applyCollaboration(
                event,
                authenticatedParticipantID: participantID
            )
#if DEBUG
            if case let .pointer(pointer) = event {
                let visibility = pointer.position == nil ? "hide" : "visible"
                Self.pointerTransportLogger.debug(
                    "Pointer receiver applied sequence=\(pointer.context.sequence, privacy: .public) state=\(visibility, privacy: .public)"
                )
            }
#endif
        case let .friendship(message):
            guard !receiveOnlyWeb else { return }
            guard
                let remote = roster.member(for: participantID),
                let local = roster.member(for: roster.localParticipantID)
            else {
                throw ServerCoordinatedMeshMediaRuntimeError.unknownParticipant
            }
            try message.verifyTransportContext(
                roomID: roster.roomID,
                sessionID: roster.sessionID,
                authorParticipantID: participantID,
                recipientParticipantID: roster.localParticipantID,
                authorIdentity: remote.descriptor.identity,
                recipientIdentity: local.descriptor.identity,
                at: now()
            )
            emit(.friendshipMessageReceived(message, from: participantID))
        }
    }

    @discardableResult
    private func synchronizeLocalSourcesIfNeeded(
        to link: ClipLiveShareNativeV3PeerLinkSnapshot,
        scheduleRetry: Bool = true
    ) async -> Bool {
        guard let roster,
              let snapshot = sourceSnapshots[roster.localParticipantID],
              synchronizedSourceRevisionByPeer[link.remoteParticipantID]
                != snapshot.sourceRevision else { return true }
        guard sourceSyncInFlightTokens[link.remoteParticipantID] == nil else {
            return false
        }
        let token = UUID()
        sourceSyncInFlightTokens[link.remoteParticipantID] = token
        do {
            let data = try ClipLiveShareMeshMediaControlCodec.encode(
                .sourceSnapshot(snapshot)
            )
            try await links.sendReliable(data, to: link.remoteParticipantID)
            guard sourceSyncInFlightTokens[link.remoteParticipantID] == token,
                  roster.participantIDs.contains(link.remoteParticipantID)
            else { return false }
            sourceSyncInFlightTokens[link.remoteParticipantID] = nil
            synchronizedSourceRevisionByPeer[link.remoteParticipantID]
                = snapshot.sourceRevision
            // Publication can advance while the reliable send is suspended.
            // Finish the newest revision immediately, still serialized behind
            // the manifest that the ordered DataChannel has just accepted.
            if sourceSnapshots[roster.localParticipantID]?.sourceRevision
                != snapshot.sourceRevision
            {
                return await synchronizeLocalSourcesIfNeeded(
                    to: link,
                    scheduleRetry: scheduleRetry
                )
            }
            sourceSyncRetryTasks[link.remoteParticipantID]?.cancel()
            sourceSyncRetryTasks[link.remoteParticipantID] = nil
            sourceSyncRetryTokens[link.remoteParticipantID] = nil
            emit(.pairRecovered(participantID: link.remoteParticipantID))
            return true
        } catch {
            if sourceSyncInFlightTokens[link.remoteParticipantID] == token {
                sourceSyncInFlightTokens[link.remoteParticipantID] = nil
            }
            emit(.pairFailed(
                participantID: link.remoteParticipantID,
                message: error.localizedDescription
            ))
            if scheduleRetry {
                scheduleSourceSynchronizationRetry(
                    for: link.remoteParticipantID
                )
            }
            return false
        }
    }

    /// Coalesces every failed publication to the newest local revision. There
    /// is at most one bounded retry task per pair, so a flapping participant
    /// cannot create an unbounded queue or delay unrelated A-C/B-C links.
    private func scheduleSourceSynchronizationRetry(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) {
        guard sourceSyncRetryTasks[participantID] == nil else { return }
        let token = UUID()
        sourceSyncRetryTokens[participantID] = token
        sourceSyncRetryTasks[participantID] = Task { [weak self] in
            for delay in Self.sourceSyncRetryDelays {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self else { return }
                if await self.retrySourceSynchronization(
                    for: participantID,
                    token: token
                ) {
                    return
                }
            }
            await self?.sourceSynchronizationRetryExhausted(
                for: participantID,
                token: token
            )
        }
    }

    private func retrySourceSynchronization(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        token: UUID
    ) async -> Bool {
        guard !isClosed,
              sourceSyncRetryTokens[participantID] == token,
              roster?.participantIDs.contains(participantID) == true
        else { return true }
        guard let link = (await links.linkSnapshot()).links.first(where: {
            $0.remoteParticipantID == participantID && $0.isReady
        }) else { return false }
        return await synchronizeLocalSourcesIfNeeded(
            to: link,
            scheduleRetry: false
        )
    }

    private func sourceSynchronizationRetryExhausted(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        token: UUID
    ) {
        guard sourceSyncRetryTokens[participantID] == token else { return }
        sourceSyncRetryTasks[participantID] = nil
        sourceSyncRetryTokens[participantID] = nil
    }

    private func schedulePairRecovery(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) {
        guard pairRecoveryTasks[participantID] == nil,
              roster?.pairsByParticipant[participantID] != nil else { return }
        let token = UUID()
        pairRecoveryTokens[participantID] = token
        pairRecoveryTasks[participantID] = Task { [weak self] in
            for delay in Self.pairRecoveryRetryDelays {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self else { return }
                if await self.attemptPairRecovery(
                    for: participantID,
                    token: token
                ) {
                    return
                }
            }
            do {
                try await Task.sleep(for: Self.pairRecoveryFinalGrace)
            } catch {
                return
            }
            guard let self else { return }
            if await self.finishPairRecoveryIfReady(
                for: participantID,
                token: token
            ) {
                return
            }
            await self.pairRecoveryExhausted(
                for: participantID,
                token: token
            )
        }
    }

    private func attemptPairRecovery(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        token: UUID
    ) async -> Bool {
        guard !isClosed,
              pairRecoveryTokens[participantID] == token,
              roster?.pairsByParticipant[participantID] != nil else {
            return true
        }
        if await finishPairRecoveryIfReady(
            for: participantID,
            token: token
        ) {
            return true
        }
        do {
            let localOriginatesOffer = try await beginPairRecovery(
                for: participantID
            )
            // The offerer's restart has its own bounded manager retries. The
            // answerer's request stays alive until the pair is actually ready,
            // allowing a lost signaling write to be retried without creating
            // more than one task for this edge.
            guard localOriginatesOffer else { return false }
            pairRecoveryTasks[participantID] = nil
            pairRecoveryTokens[participantID] = nil
            return true
        } catch {
            return false
        }
    }

    /// Begins one recovery exchange without changing the roster or touching an
    /// unrelated peer connection. The permanent canonical offerer creates the
    /// offer. An answerer only prepares its local ICE state and sends an
    /// authenticated, end-to-end encrypted renegotiation request through the
    /// room service.
    @discardableResult
    private func beginPairRecovery(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws -> Bool {
        guard let roster,
              let pair = roster.pairsByParticipant[participantID],
              let member = roster.member(for: participantID) else {
            throw ServerCoordinatedMeshMediaRuntimeError.unknownParticipant
        }
        let localOriginatesOffer =
            pair.context.initialOfferer == roster.localHandle
        if localOriginatesOffer {
            try? await links.rollbackLocalOfferIfNeeded(for: participantID)
        }
        try await links.restartLink(to: participantID)
        if !localOriginatesOffer {
            try await sendPairSignalAction(
                pair.context,
                .renegotiationRequest(epoch: pair.epoch),
                member.handle
            )
        }
        return localOriginatesOffer
    }

    private func isLocalAnswerer(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> Bool {
        guard let roster,
              let pair = roster.pairsByParticipant[participantID] else {
            return false
        }
        return pair.context.initialOfferer != roster.localHandle
    }

    private func finishPairRecoveryIfReady(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        token: UUID
    ) async -> Bool {
        guard pairRecoveryTokens[participantID] == token else { return true }
        let isReady = (await links.linkSnapshot()).links.contains {
            $0.remoteParticipantID == participantID && $0.isReady
        }
        guard isReady else { return false }
        pairRecoveryTasks[participantID] = nil
        pairRecoveryTokens[participantID] = nil
        return true
    }

    private func pairRecoveryExhausted(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        token: UUID
    ) {
        guard pairRecoveryTokens[participantID] == token else { return }
        pairRecoveryTasks[participantID] = nil
        pairRecoveryTokens[participantID] = nil
        emit(.pairFailed(
            participantID: participantID,
            message: "The direct participant connection could not restart."
        ))
    }

    private func broadcastEphemeral(
        _ data: Data,
        excludingReceiveOnlyWebParticipants: Bool = false
    ) async {
        guard let roster else { return }
        await withTaskGroup(of: Void.self) { group in
            for participantID in roster.participantIDs
            where participantID != roster.localParticipantID
                && (!excludingReceiveOnlyWebParticipants
                    || !isReceiveOnlyWebParticipant(
                        participantID,
                        in: roster
                    )) {
                group.addTask { [links] in
                    _ = await links.sendEphemeral(data, to: participantID)
                }
            }
        }
    }

#if DEBUG
    private func broadcastEphemeralWithDiagnostics(
        _ data: Data,
        excludingReceiveOnlyWebParticipants: Bool = false
    ) async -> EphemeralBroadcastDiagnostics {
        guard let roster else {
            return .init(acceptedPeerCount: 0, droppedPeerCount: 0)
        }
        return await withTaskGroup(
            of: Bool.self,
            returning: EphemeralBroadcastDiagnostics.self
        ) { group in
            for participantID in roster.participantIDs
            where participantID != roster.localParticipantID
                && (!excludingReceiveOnlyWebParticipants
                    || !isReceiveOnlyWebParticipant(
                        participantID,
                        in: roster
                    )) {
                group.addTask { [links] in
                    await links.sendEphemeral(data, to: participantID)
                }
            }
            var acceptedPeerCount = 0
            var droppedPeerCount = 0
            for await wasAccepted in group {
                if wasAccepted {
                    acceptedPeerCount += 1
                } else {
                    droppedPeerCount += 1
                }
            }
            return .init(
                acceptedPeerCount: acceptedPeerCount,
                droppedPeerCount: droppedPeerCount
            )
        }
    }
#endif

    private func broadcastReliable(
        _ data: Data,
        excludingReceiveOnlyWebParticipants: Bool = false
    ) async {
        guard let roster else { return }
        for participantID in roster.participantIDs.sorted()
        where participantID != roster.localParticipantID
            && (!excludingReceiveOnlyWebParticipants
                || !isReceiveOnlyWebParticipant(
                    participantID,
                    in: roster
                )) {
            do {
                try await links.sendReliable(data, to: participantID)
            } catch {
                // Reliability failure is scoped to this one P2P edge. The
                // authoritative roster and every other live pair remain
                // untouched.
                emit(.pairFailed(
                    participantID: participantID,
                    message: error.localizedDescription
                ))
            }
        }
    }

    private func applyCollaboration(
        _ event: ClipLiveShareNativeV3CollaborationEvent,
        authenticatedParticipantID: ClipLiveShareNativeV3ParticipantID
    ) throws {
        let key = event.context.sourceKey
        guard sourceExists(key) else {
            throw ServerCoordinatedMeshMediaRuntimeError.sourceNotPublished
        }
        var state = collaboration[key]
            ?? .init(sessionID: event.context.sessionID, sourceKey: key)
        try state.apply(
            event,
            authenticatedParticipantID: authenticatedParticipantID,
            at: now(),
            mayClearEntireSource:
                authenticatedParticipantID == key.ownerParticipantID
        )
        collaboration[key] = state
    }

    private func sourceExists(
        _ key: ClipLiveShareNativeV3SourceKey
    ) -> Bool {
        sourceSnapshots[key.ownerParticipantID]?.sources.contains {
            $0.key == key
        } == true
    }

    /// The creator-certified descriptor is the sole capability authority.
    /// Runtime behavior never falls back to a user-agent, display name, or
    /// implicit Native profile.
    private func isReceiveOnlyWebParticipant(
        _ participantID: ClipLiveShareNativeV3ParticipantID,
        in roster: ServerCoordinatedMeshVerifiedRoster
    ) -> Bool {
        guard let member = roster.member(for: participantID) else {
            return false
        }
        return isReceiveOnlyWebParticipant(member)
    }

    private func isReceiveOnlyWebParticipant(
        _ member: ServerCoordinatedMeshVerifiedMember
    ) -> Bool {
        member.descriptor.clientKind == .webViewer
            && member.descriptor.capabilityProfile == .webViewerV1
    }

    /// Enforces the receive-only profile after every authoritative roster
    /// transaction. This also removes stale state if a test or future
    /// migration changes a participant descriptor while retaining its room
    /// identity. The production profile is immutable for an incarnation.
    private func enforceReceiveOnlyWebProfiles(
        in roster: ServerCoordinatedMeshVerifiedRoster
    ) async {
        let webParticipantIDs = roster.members.reduce(
            into: Set<ClipLiveShareNativeV3ParticipantID>()
        ) { result, member in
            if isReceiveOnlyWebParticipant(member) {
                result.insert(member.participantID)
            }
        }
        for participantID in webParticipantIDs {
            if sourceSnapshots[participantID]?.sources.isEmpty == false {
                sourceSnapshots[participantID] = nil
            }
            remoteVideoTrackIDs[participantID] = nil
            audioTrackIDs[participantID] = nil
            sourceCursors = sourceCursors.filter {
                $0.key.ownerParticipantID != participantID
            }
            collaboration = collaboration.filter {
                $0.key.ownerParticipantID != participantID
            }
            // The underlying WebRTC receiver defaults participant audio on.
            // Persist an explicit disabled preference before a malicious Web
            // endpoint can surface an unsolicited audio track.
            try? await links.setRemoteParticipantAudioPlaybackEnabled(
                false,
                for: participantID
            )
        }
    }

    private func pruneState(
        to participantIDs: Set<ClipLiveShareNativeV3ParticipantID>
    ) {
        sourceSnapshots = sourceSnapshots.filter {
            participantIDs.contains($0.key)
        }
        remoteVideoTrackIDs = remoteVideoTrackIDs.filter {
            participantIDs.contains($0.key)
        }
        audioTrackIDs = audioTrackIDs.filter {
            participantIDs.contains($0.key)
        }
        statistics = statistics.filter {
            participantIDs.contains($0.key)
        }
        codecRejectedParticipants = codecRejectedParticipants.filter {
            participantIDs.contains($0)
        }
        synchronizedSourceRevisionByPeer =
            synchronizedSourceRevisionByPeer.filter {
                participantIDs.contains($0.key)
            }
        sourceSyncInFlightTokens = sourceSyncInFlightTokens.filter {
            participantIDs.contains($0.key)
        }
        for participantID in Array(sourceSyncRetryTasks.keys)
        where !participantIDs.contains(participantID) {
            sourceSyncRetryTasks.removeValue(forKey: participantID)?.cancel()
            sourceSyncRetryTokens[participantID] = nil
        }
        for participantID in Array(pairRecoveryTasks.keys)
        where !participantIDs.contains(participantID) {
            pairRecoveryTasks.removeValue(forKey: participantID)?.cancel()
            pairRecoveryTokens[participantID] = nil
        }
        for key in collaboration.keys {
            collaboration[key]?.retainParticipants(participantIDs)
        }
        pruneSourceScopedState()
    }

    private func pruneSourceScopedState() {
        let publishedKeys = Set(sourceSnapshots.values.flatMap {
            $0.sources.map(\.key)
        })
        sourceCursors = sourceCursors.filter { publishedKeys.contains($0.key) }
        collaboration = collaboration.filter { publishedKeys.contains($0.key) }
    }

    private func replayReceiverState(
        from snapshot: ClipLiveShareNativeV3MeshPeerLinkManagerSnapshot
    ) {
        guard let roster else { return }
        for link in snapshot.links {
            guard !isReceiveOnlyWebParticipant(
                link.remoteParticipantID,
                in: roster
            ) else {
                remoteVideoTrackIDs[link.remoteParticipantID] = nil
                audioTrackIDs[link.remoteParticipantID] = nil
                continue
            }
            remoteVideoTrackIDs[link.remoteParticipantID, default: []]
                .formUnion(link.remoteVideoTrackIDs)
            if let audioTrackID = link.remoteParticipantAudioTrackID {
                audioTrackIDs[link.remoteParticipantID] = audioTrackID
            }
        }
    }

    private func markPairUnavailable(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) {
        remoteVideoTrackIDs[participantID] = nil
        audioTrackIDs[participantID] = nil
        statistics[participantID] = nil
        synchronizedSourceRevisionByPeer[participantID] = nil
        sourceSyncInFlightTokens[participantID] = nil
        sourceSyncRetryTasks.removeValue(forKey: participantID)?.cancel()
        sourceSyncRetryTokens[participantID] = nil
        pairRecoveryTasks.removeValue(forKey: participantID)?.cancel()
        pairRecoveryTokens[participantID] = nil
    }

    private func resetRemoteParticipantIncarnation(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) {
        codecRejectedParticipants.remove(participantID)
        sourceSnapshots[participantID] = nil
        markPairUnavailable(participantID)
        sourceCursors = sourceCursors.filter {
            $0.key.ownerParticipantID != participantID
        }
        collaboration = collaboration.filter {
            $0.key.ownerParticipantID != participantID
        }
    }

    private func participantID(
        for event: ClipLiveShareNativeV3MeshPeerLinkManagerEvent,
        roster: ServerCoordinatedMeshVerifiedRoster
    ) -> ClipLiveShareNativeV3ParticipantID? {
        switch event {
        case let .targetedNegotiation(value): value.targetParticipantID
        case let .negotiationNeeded(_, value),
             let .controlMessageReceived(value, _),
             let .remoteVideoTrackAdded(value, _),
             let .remoteVideoTrackRemoved(value, _),
             let .remoteParticipantAudioAvailable(value, _),
             let .remoteParticipantAudioRemoved(value, _),
             let .reconnectScheduled(_, value, _, _),
             let .reconnectExhausted(_, value),
             let .linkFailed(_, value, _),
             let .linkRemoved(_, value): value
        case let .statisticsUpdated(value): value.remoteParticipantID
        case let .linkAdded(value), let .linkUpdated(value):
            value.remoteParticipantID
        case .closed: nil
        }
    }

    private func publishSnapshot() async {
        guard let snapshot = try? await makeSnapshot() else { return }
        emit(.snapshotChanged(snapshot))
    }

    private func makeSnapshot() async throws
        -> ServerCoordinatedMeshMediaRuntimeSnapshot
    {
        let roster = try currentRoster()
        return .init(
            roster: roster,
            reconciliation: await links.reconciliationSnapshot(),
            links: await links.linkSnapshot(),
            sourceSnapshots: sourceSnapshots,
            remoteVideoTrackIDs: remoteVideoTrackIDs,
            audioTrackIDs: audioTrackIDs,
            statistics: statistics,
            sourceCursors: sourceCursors,
            collaboration: collaboration
        )
    }

    private func currentRoster() throws
        -> ServerCoordinatedMeshVerifiedRoster
    {
        guard let roster else {
            throw ServerCoordinatedMeshMediaRuntimeError.notStarted
        }
        return roster
    }

    private func requireActive() throws {
        guard !isClosed else {
            throw ServerCoordinatedMeshMediaRuntimeError.closed
        }
        guard isStarted else {
            throw ServerCoordinatedMeshMediaRuntimeError.notStarted
        }
    }

    private func emit(_ event: ServerCoordinatedMeshMediaRuntimeEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
