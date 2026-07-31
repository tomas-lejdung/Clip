import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation

/// The temporary authenticated path used while a new pair is establishing its
/// direct WebRTC control channel.
///
/// Native-v3 media is never relayed through this path. It carries only
/// pair-scoped possession and SDP/ICE envelopes until the reliable direct data
/// channel is open. An admitted participant can use the rendezvous connection
/// to the current room leader; an existing participant can relay the opaque
/// target-bound envelope over its already-established mesh links.
enum MeshParticipantBootstrapRouteEvent: Equatable, Sendable {
    case envelope(
        ClipLiveShareNativeV3BootstrapEnvelope,
        from: ClipLiveShareNativeV3ParticipantID
    )
    case failed(String)
    case closed
}

protocol MeshParticipantBootstrapRouting: Sendable {
    func events() async -> AsyncStream<MeshParticipantBootstrapRouteEvent>
    func send(
        _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws
    func close() async
}

/// Closure-backed production integration seam for the existing authenticated
/// rendezvous transports. Keeping the adapter explicit prevents the mesh
/// runtime from silently treating the public signaling service as a media
/// relay or as a trusted source of membership state.
final class MeshParticipantBootstrapAdapter:
    MeshParticipantBootstrapRouting,
    @unchecked Sendable
{
    typealias EventStream = @Sendable () async
        -> AsyncStream<MeshParticipantBootstrapRouteEvent>
    typealias Send = @Sendable (
        ClipLiveShareNativeV3BootstrapEnvelope,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    typealias Close = @Sendable () async -> Void

    private let eventStream: EventStream
    private let sendAction: Send
    private let closeAction: Close

    init(
        events: @escaping EventStream,
        send: @escaping Send,
        close: @escaping Close
    ) {
        eventStream = events
        sendAction = send
        closeAction = close
    }

    func events() async -> AsyncStream<MeshParticipantBootstrapRouteEvent> {
        await eventStream()
    }

    func send(
        _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await sendAction(envelope, participantID)
    }

    func close() async {
        await closeAction()
    }
}

enum MeshParticipantRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case alreadyStarted
    case closed
    case localParticipantMissing
    case localIdentityMismatch
    case incompletePossessionProofs
    case missingTransportNonce(ClipLiveShareNativeV3ParticipantID)
    case unexpectedSender
    case negotiationRevisionUnavailable(ClipLiveShareNativeV3ParticipantID)
    case negotiationRevisionExhausted(ClipLiveShareNativeV3ParticipantID)
    case staleNegotiationRevision
    case staleICESequence
    case sourceBeforeMembershipCommit
    case sourceOwnerMismatch
    case invalidBootstrapRelay
    case invalidBootstrapForward
    case unsupportedVideoCodec(String)
    case codecChangeInProgress(ClipLiveShareNativeV3ParticipantID)
    case codecUpdateFailed([String])

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "The participant mesh runtime is already started."
        case .closed:
            "The participant mesh runtime is closed."
        case .localParticipantMissing:
            "The signed room membership does not contain this participant."
        case .localIdentityMismatch:
            "The local signer does not match this participant’s room identity."
        case .incompletePossessionProofs:
            "Every direct peer must prove possession of its signed identity before WebRTC starts."
        case let .missingTransportNonce(participantID):
            "The direct link to \(participantID) has no authenticated transport nonce."
        case .unexpectedSender:
            "The native-v3 control message came from a different participant."
        case let .negotiationRevisionUnavailable(participantID):
            "The direct link to \(participantID) has no active negotiation revision."
        case let .negotiationRevisionExhausted(participantID):
            "The direct link to \(participantID) exhausted its negotiation revision space."
        case .staleNegotiationRevision:
            "The native-v3 peer negotiation revision is stale."
        case .staleICESequence:
            "The native-v3 ICE candidate sequence is stale."
        case .sourceBeforeMembershipCommit:
            "A participant published media before its membership was committed."
        case .sourceOwnerMismatch:
            "A participant attempted to publish another participant’s source."
        case .invalidBootstrapRelay:
            "The native-v3 bootstrap relay is not scoped to this participant pair."
        case .invalidBootstrapForward:
            "The native-v3 bootstrap message is not valid for this leader-routed direct link."
        case let .unsupportedVideoCodec(value):
            "The peer requested unsupported video codec “\(value)”."
        case let .codecChangeInProgress(participantID):
            "The direct link to \(participantID) is already changing video codec."
        case let .codecUpdateFailed(participants):
            "Video codec update failed for: \(participants.joined(separator: ", "))."
        }
    }
}

struct MeshParticipantLaunchContext: Sendable {
    let localParticipantID: ClipLiveShareNativeV3ParticipantID
    let localIdentitySigner: any ClipLiveShareIdentitySigner
    let signedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot
    let authorityChain: ClipLiveShareNativeV3RoomAuthorityChain
    let expectedFoundingCreatorIdentity: ClipLiveShareIdentityPublicKey
    /// Pair-scoped bootstrap admission digests. A later admission has a fresh
    /// digest, so this cannot be a single immutable room-wide value.
    let bootstrapAdmissionDigests:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeDigest]
    /// A nonce is accepted here only after the bootstrap path has verified a
    /// fresh possession challenge against the peer's signed credential.
    let verifiedPeerTransportNonces:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3TransportNonce]
    let admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy

    init(
        localParticipantID: ClipLiveShareNativeV3ParticipantID,
        localIdentitySigner: any ClipLiveShareIdentitySigner,
        signedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
        authorityChain: ClipLiveShareNativeV3RoomAuthorityChain,
        expectedFoundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
        bootstrapAdmissionDigest: ClipLiveShareNativeDigest,
        verifiedPeerTransportNonces:
            [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3TransportNonce],
        admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy = .productDefault
    ) {
        self.localParticipantID = localParticipantID
        self.localIdentitySigner = localIdentitySigner
        self.signedMembership = signedMembership
        self.authorityChain = authorityChain
        self.expectedFoundingCreatorIdentity =
            expectedFoundingCreatorIdentity
        bootstrapAdmissionDigests = Dictionary(
            uniqueKeysWithValues:
                signedMembership.snapshot.participantIDs
                .subtracting([localParticipantID])
                .map { ($0, bootstrapAdmissionDigest) }
        )
        self.verifiedPeerTransportNonces = verifiedPeerTransportNonces
        self.admissionPolicy = admissionPolicy
    }

    init(
        localParticipantID: ClipLiveShareNativeV3ParticipantID,
        localIdentitySigner: any ClipLiveShareIdentitySigner,
        signedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
        authorityChain: ClipLiveShareNativeV3RoomAuthorityChain,
        expectedFoundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
        bootstrapAdmissionDigests:
            [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeDigest],
        verifiedPeerTransportNonces:
            [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3TransportNonce],
        admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy = .productDefault
    ) {
        self.localParticipantID = localParticipantID
        self.localIdentitySigner = localIdentitySigner
        self.signedMembership = signedMembership
        self.authorityChain = authorityChain
        self.expectedFoundingCreatorIdentity =
            expectedFoundingCreatorIdentity
        self.bootstrapAdmissionDigests = bootstrapAdmissionDigests
        self.verifiedPeerTransportNonces = verifiedPeerTransportNonces
        self.admissionPolicy = admissionPolicy
    }
}

struct MeshParticipantRuntimeSnapshot: Equatable, Sendable {
    let signedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot
    let links: ClipLiveShareNativeV3MeshPeerLinkManagerSnapshot
    let sourceSnapshots:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3SourceSnapshot]
    let audioTrackIDs: [ClipLiveShareNativeV3ParticipantID: String]
    let statistics:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3PeerStatistics]
    let collaboration:
        [ClipLiveShareNativeV3SourceKey: ClipLiveShareNativeV3CollaborationState]

    var isLocallyComplete: Bool { links.isLocallyComplete }
}

enum MeshParticipantRuntimeEvent: Equatable, Sendable {
    case snapshotChanged(MeshParticipantRuntimeSnapshot)
    case membershipReceived(
        ClipLiveShareSignedNativeV3MembershipSnapshot,
        from: ClipLiveShareNativeV3ParticipantID
    )
    case roomControlReceived(
        ClipLiveShareNativeV3ControlEnvelope,
        from: ClipLiveShareNativeV3ParticipantID
    )
    case bootstrapForwardReceived(
        ClipLiveShareNativeV3BootstrapForward,
        from: ClipLiveShareNativeV3ParticipantID
    )
    case remoteVideoTrackChanged(
        participantID: ClipLiveShareNativeV3ParticipantID,
        mediaTrackID: ClipLiveShareMediaTrackID,
        isAvailable: Bool
    )
    case sourceCursorReceived(
        ClipLiveShareNativeV3SourceCursor,
        from: ClipLiveShareNativeV3ParticipantID
    )
    /// One direct edge is unavailable. This is deliberately non-terminal:
    /// every other participant link and local publication remains active.
    case peerDegraded(
        participantID: ClipLiveShareNativeV3ParticipantID,
        message: String
    )
    case failed(String)
    case closed
}

/// Symmetric native-v3 session core shared by creators and joiners.
///
/// This actor owns exactly one mesh-link manager. The concrete manager in turn
/// owns one bidirectional PeerConnection per remote participant, all backed by
/// the single participant media factory supplied by the app coordinator.
actor MeshParticipantRuntime {
    private struct NegotiationState: Sendable {
        var activeRevision: ClipLiveShareNativeV3PeerLinkRevision?
        var nextRevisionRawValue: UInt64 = 1
        var nextOutgoingICESequence: UInt32 = 0
        var latestIncomingICESequence: UInt32?
        var forcedOutgoingOfferRevision:
            ClipLiveShareNativeV3PeerLinkRevision?
        var requestedIncomingOfferRevision:
            ClipLiveShareNativeV3PeerLinkRevision?
        var latestHandledRenegotiationRequest:
            ClipLiveShareNativeV3PeerLinkRevision?
    }

    private struct PendingCodecChange: Sendable {
        let previous: WebRTCVideoCodec
        let requested: WebRTCVideoCodec
        let negotiationRevision: ClipLiveShareNativeV3PeerLinkRevision
        let previousNegotiationRevision:
            ClipLiveShareNativeV3PeerLinkRevision?
    }

    private let context: MeshParticipantLaunchContext
    private let manager: ClipLiveShareNativeV3MeshPeerLinkManager
    private let bootstrap: any MeshParticipantBootstrapRouting
    private let initialVideoCodec: WebRTCVideoCodec
    private var desiredVideoCodec: WebRTCVideoCodec

    private var signedMembership:
        ClipLiveShareSignedNativeV3MembershipSnapshot
    private var authorityChain: ClipLiveShareNativeV3RoomAuthorityChain
    private var verifiedPeerTransportNonces:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3TransportNonce]
    private var bootstrapAdmissionDigests:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeDigest]
    private var negotiation:
        [ClipLiveShareNativeV3ParticipantID: NegotiationState] = [:]
    private var activeVideoCodecByPeer:
        [ClipLiveShareNativeV3ParticipantID: WebRTCVideoCodec] = [:]
    private var pendingCodecChanges:
        [ClipLiveShareNativeV3ParticipantID: PendingCodecChange] = [:]
    private var sourceSnapshots:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3SourceSnapshot] = [:]
    /// Membership is committed independently on every participant. A retained
    /// peer can therefore re-issue its source manifest for revision N + 1
    /// immediately before this runtime commits that same signed membership.
    /// Keep at most one such next-revision manifest per current participant;
    /// stale revisions and snapshots that skip a revision are still rejected.
    private var deferredSourceSnapshots:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3SourceSnapshot] = [:]
    private var sourceRevisionLedger = ClipLiveShareNativeV3SourceRevisionLedger()
    private var nextLocalSourceRevisionRawValue: UInt64 = 1
    private var audioTrackIDs: [ClipLiveShareNativeV3ParticipantID: String] = [:]
    private var remoteVideoTrackIDs:
        [ClipLiveShareNativeV3ParticipantID: Set<ClipLiveShareMediaTrackID>] = [:]
    private var statistics:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3PeerStatistics] = [:]
    private var collaboration:
        [ClipLiveShareNativeV3SourceKey: ClipLiveShareNativeV3CollaborationState] = [:]
    private var cursorSequenceBySource:
        [ClipLiveShareNativeV3SourceKey: UInt64] = [:]
    /// Peers that have received the current local source snapshot since their
    /// reliable control channel most recently opened.
    private var sourceSynchronizedPeers:
        Set<ClipLiveShareNativeV3ParticipantID> = []
    /// A malformed control stream or unavailable transport removes only that
    /// direct edge from participant-facing state. The signed room membership
    /// remains authoritative while leader recovery decides whether to retain
    /// or remove the participant.
    private var degradedPeerIDs:
        Set<ClipLiveShareNativeV3ParticipantID> = []
    /// A transport that exhausts its in-place ICE restart budget gets one
    /// completely fresh pair transport. A second exhaustion without ever
    /// reaching ready state remains quarantined until membership changes or
    /// the leader removes that participant. This keeps recovery pair-scoped
    /// and prevents an unreachable peer from creating an unbounded reconnect
    /// loop.
    private var freshLinkRecoveryAttempts:
        [ClipLiveShareNativeV3ParticipantID: Int] = [:]

    private var managerTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var isStarted = false
    private var isClosed = false
    private var continuations:
        [UUID: AsyncStream<MeshParticipantRuntimeEvent>.Continuation] = [:]

    init(
        context: MeshParticipantLaunchContext,
        manager: ClipLiveShareNativeV3MeshPeerLinkManager,
        bootstrap: any MeshParticipantBootstrapRouting,
        initialVideoCodec: WebRTCVideoCodec = .h264
    ) {
        self.context = context
        self.manager = manager
        self.bootstrap = bootstrap
        self.initialVideoCodec = initialVideoCodec
        desiredVideoCodec = initialVideoCodec
        signedMembership = context.signedMembership
        authorityChain = context.authorityChain
        bootstrapAdmissionDigests = context.bootstrapAdmissionDigests
        verifiedPeerTransportNonces = context.verifiedPeerTransportNonces
        activeVideoCodecByPeer = Dictionary(
            uniqueKeysWithValues:
                context.signedMembership.snapshot.participantIDs
                .subtracting([context.localParticipantID])
                .map { ($0, initialVideoCodec) }
        )
    }

    func events() -> AsyncStream<MeshParticipantRuntimeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: MeshParticipantRuntimeEvent.self,
            bufferingPolicy: .bufferingNewest(256)
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

    func start(at now: ClipLiveShareNativeTimestamp) async throws {
        guard !isClosed else { throw MeshParticipantRuntimeError.closed }
        guard !isStarted else {
            throw MeshParticipantRuntimeError.alreadyStarted
        }
        try validateLaunchContext(at: now)

        let managerEvents = await manager.events()
        let bootstrapEvents = await bootstrap.events()
        managerTask = Task { [weak self] in
            for await event in managerEvents {
                guard !Task.isCancelled else { return }
                await self?.handleManagerEvent(event)
            }
        }
        bootstrapTask = Task { [weak self] in
            for await event in bootstrapEvents {
                guard !Task.isCancelled else { return }
                await self?.handleBootstrapEvent(event)
            }
        }
        isStarted = true
        do {
            try await manager.reconcileParticipants(
                signedMembership.snapshot.participantIDs
            )
            let linkSnapshot = await manager.snapshot()
            replayReceiverState(from: linkSnapshot)
            for link in linkSnapshot.links {
                try await synchronizeLocalSourcesIfNeeded(to: link)
            }
            await publishSnapshot()
        } catch {
            isStarted = false
            managerTask?.cancel()
            bootstrapTask?.cancel()
            managerTask = nil
            bootstrapTask = nil
            throw error
        }
    }

    /// Commits a leader-authorized membership only after all new peers have
    /// completed possession proof and every local WebRTC edge has been
    /// constructed. If transport reconciliation fails, the prior membership
    /// remains authoritative.
    func commitMembership(
        _ incoming: ClipLiveShareSignedNativeV3MembershipSnapshot,
        validatedAuthorityChain:
            ClipLiveShareNativeV3RoomAuthorityChain,
        verifiedNonces:
            [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3TransportNonce],
        bootstrapAdmissionDigests:
            [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeDigest],
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        guard !isClosed else { throw MeshParticipantRuntimeError.closed }
        try validatedAuthorityChain.verify(
            expectedSessionID: signedMembership.snapshot.sessionID,
            expectedFoundingCreatorIdentity:
                context.expectedFoundingCreatorIdentity,
            localCapabilities: .current,
            at: now
        )
        guard validatedAuthorityChain.currentMembership == incoming else {
            throw ClipLiveShareNativeV3Error.invalidAuthorityChain
        }
        guard incoming.snapshot.participantIDs.contains(context.localParticipantID) else {
            throw MeshParticipantRuntimeError.localParticipantMissing
        }
        guard incoming.snapshot.participants.count
            <= context.admissionPolicy.maximumParticipants else {
            throw ClipLiveShareNativeV3Error.participantLimit(
                maximum: context.admissionPolicy.maximumParticipants,
                actual: incoming.snapshot.participants.count
            )
        }
        try validateStableIdentities(incoming)
        try validateVerifiedNonces(
            participantIDs: incoming.snapshot.participantIDs,
            nonces: verifiedNonces
        )
        try validateBootstrapAdmissionDigests(
            participantIDs: incoming.snapshot.participantIDs,
            digests: bootstrapAdmissionDigests
        )

        try await manager.reconcileParticipants(incoming.snapshot.participantIDs)

        let priorLocalSnapshot =
            sourceSnapshots[context.localParticipantID]
        signedMembership = incoming
        authorityChain = validatedAuthorityChain
        verifiedPeerTransportNonces = verifiedNonces
        self.bootstrapAdmissionDigests = bootstrapAdmissionDigests
        // A source snapshot is bound to one exact membership revision. Never
        // retain a remote participant's old-revision manifest. Re-issue the
        // local manifest at the new revision without restarting capture.
        sourceSnapshots.removeAll(keepingCapacity: true)
        if let priorLocalSnapshot {
            sourceSnapshots[context.localParticipantID] =
                try makeLocalSourceSnapshot(priorLocalSnapshot.sources)
        }
        sourceRevisionLedger.retainParticipants(incoming.snapshot.participantIDs)
        let deferredSnapshots = deferredSourceSnapshots
        deferredSourceSnapshots = deferredSourceSnapshots.filter {
            incoming.snapshot.participantIDs.contains($0.key)
                && $0.value.membershipRevision
                    > incoming.snapshot.membershipRevision
        }
        for participantID in deferredSnapshots.keys.sorted() {
            guard
                incoming.snapshot.participantIDs.contains(participantID),
                let snapshot = deferredSnapshots[participantID],
                snapshot.membershipRevision
                    == incoming.snapshot.membershipRevision
            else { continue }
            do {
                try receive(snapshot, from: participantID)
            } catch {
                await degradePeer(
                    participantID,
                    message: error.localizedDescription,
                    disconnect: true
                )
            }
        }
        audioTrackIDs = audioTrackIDs.filter {
            incoming.snapshot.participantIDs.contains($0.key)
        }
        remoteVideoTrackIDs = remoteVideoTrackIDs.filter {
            incoming.snapshot.participantIDs.contains($0.key)
        }
        statistics = statistics.filter {
            incoming.snapshot.participantIDs.contains($0.key)
        }
        collaboration = collaboration.mapValues { state in
            var state = state
            state.retainParticipants(incoming.snapshot.participantIDs)
            return state
        }
        pruneStateForPublishedSources()
        negotiation = negotiation.filter {
            incoming.snapshot.participantIDs.contains($0.key)
        }
        activeVideoCodecByPeer = Dictionary(
            uniqueKeysWithValues:
                incoming.snapshot.participantIDs
                .subtracting([context.localParticipantID])
                .map {
                    (
                        $0,
                        activeVideoCodecByPeer[$0]
                            ?? desiredVideoCodec
                    )
                }
        )
        pendingCodecChanges = pendingCodecChanges.filter {
            incoming.snapshot.participantIDs.contains($0.key)
        }
        degradedPeerIDs.formIntersection(
            incoming.snapshot.participantIDs
        )
        // A newly leader-authorized membership starts a fresh bounded
        // recovery window for every retained participant.
        freshLinkRecoveryAttempts.removeAll(keepingCapacity: true)
        sourceSynchronizedPeers.removeAll(keepingCapacity: true)
        let linkSnapshot = await manager.snapshot()
        replayReceiverState(from: linkSnapshot)
        if sourceSnapshots[context.localParticipantID] != nil {
            for link in linkSnapshot.links {
                do {
                    try await synchronizeLocalSourcesIfNeeded(to: link)
                } catch {
                    await degradePeer(
                        link.remoteParticipantID,
                        message: error.localizedDescription,
                        disconnect: false
                    )
                }
            }
        }
        await publishSnapshot()
    }

    func publishLocalSources(
        _ sources: [ClipLiveShareNativeV3PublishedSource]
    ) async throws {
        guard !isClosed else { throw MeshParticipantRuntimeError.closed }
        let snapshot = try makeLocalSourceSnapshot(sources)
        sourceSnapshots[context.localParticipantID] = snapshot
        pruneStateForPublishedSources()
        try await broadcastToReadyPeers(
            .sourceSnapshot(snapshot),
            requireAllSucceeded: false
        )
        await publishSnapshot()
    }

    func broadcastCollaboration(
        _ event: ClipLiveShareNativeV3CollaborationEvent
    ) async throws {
        guard event.context.participantID == context.localParticipantID else {
            throw MeshParticipantRuntimeError.unexpectedSender
        }
        try applyCollaboration(
            event,
            from: context.localParticipantID,
            at: try currentTimestamp()
        )
        try await broadcastToReadyPeers(
            .collaboration(event),
            requireAllSucceeded: false
        )
        await publishSnapshot()
    }

    func setParticipantAudioEnabled(
        _ enabled: Bool,
        participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        guard isCommittedParticipant(participantID) else {
            throw ClipLiveShareNativeV3Error.unknownParticipant(
                participantID
            )
        }
        try await manager.setRemoteParticipantAudioPlaybackEnabled(
            enabled,
            for: participantID
        )
    }

    func setParticipantVolume(
        _ volume: Double,
        participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        guard isCommittedParticipant(participantID) else {
            throw ClipLiveShareNativeV3Error.unknownParticipant(
                participantID
            )
        }
        try await manager.setRemoteParticipantAudioVolume(
            volume,
            for: participantID
        )
    }

    func remoteVideoStream(
        for descriptor: ClipLiveShareStreamDescriptor,
        participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws -> WebRTCRemoteVideoStream? {
        guard isUsableParticipant(participantID) else {
            throw ClipLiveShareNativeV3Error.unknownParticipant(
                participantID
            )
        }
        return try await manager.remoteVideoStream(
            for: descriptor,
            from: participantID
        )
    }

    func refreshStatistics() async throws {
        let values = try await manager.statistics().filter {
            isCommittedParticipant($0.remoteParticipantID)
        }
        statistics = Dictionary(
            uniqueKeysWithValues: values.map {
                ($0.remoteParticipantID, $0)
            }
        )
        await publishSnapshot()
    }

    func updateSenderPolicy(
        _ policy: WebRTCSenderPolicy
    ) async {
        await manager.updateSenderPolicy(policy)
    }

    /// Applies one participant codec preference to every direct pair. The
    /// lower-ID endpoint remains the sole offerer. An upper-ID endpoint sends
    /// a signed, pair/revision/membership-bound request over the already
    /// authenticated direct control channel.
    func updateVideoCodec(
        _ codec: WebRTCVideoCodec,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        guard !isClosed else { throw MeshParticipantRuntimeError.closed }
        let peers = signedMembership.snapshot.participantIDs
            .subtracting([context.localParticipantID])
            .sorted()
        desiredVideoCodec = codec
        var failures: [ClipLiveShareNativeV3ParticipantID] = []
        for participantID in peers {
            do {
                if pendingCodecChanges[participantID] != nil {
                    throw MeshParticipantRuntimeError
                        .codecChangeInProgress(participantID)
                }
                let previous =
                    activeVideoCodecByPeer[participantID]
                    ?? initialVideoCodec
                guard previous != codec else { continue }
                try await manager.updateVideoCodecPreference(
                    codec,
                    for: participantID,
                    rollbackTo: previous
                )
                var state = negotiation[participantID] ?? NegotiationState()
                let revision = try reserveNegotiationRevision(
                    for: participantID,
                    state: &state
                )
                pendingCodecChanges[participantID] = .init(
                    previous: previous,
                    requested: codec,
                    negotiationRevision: revision,
                    previousNegotiationRevision: state.activeRevision
                )

                let key = try ClipLiveShareNativeV3PeerLinkKey(
                    context.localParticipantID,
                    participantID
                )
                if context.localParticipantID == key.lowerParticipantID {
                    state.forcedOutgoingOfferRevision = revision
                    negotiation[participantID] = state
                    try await manager.requestNegotiation(
                        with: participantID
                    )
                } else {
                    state.requestedIncomingOfferRevision = revision
                    negotiation[participantID] = state
                    let requestContext = try negotiationContext(
                        participantID: participantID,
                        revision: revision,
                        nonce: try transportNonce(for: participantID)
                    )
                    let request =
                        try ClipLiveShareNativeV3PeerLinkRenegotiationRequest(
                            context: requestContext,
                            membershipDigest:
                                signedMembership.snapshot.digest,
                            preferredVideoCodec: codec.rawValue,
                            issuedAt: now,
                            expiresAt: now.adding(
                                milliseconds:
                                    ClipLiveShareNativeV3
                                    .maximumPeerLinkRenegotiationRequestLifetimeMilliseconds
                            )
                        )
                    let signed =
                        try ClipLiveShareSignedNativeV3PeerLinkRenegotiationRequest(
                            signing: request,
                            with: context.localIdentitySigner,
                            membership: signedMembership
                        )
                    try await manager.sendControlMessage(
                        ClipLiveShareNativeV3ControlCodec.encode(
                            .peerLinkRenegotiationRequest(signed)
                        ),
                        to: participantID
                    )
                }
            } catch {
                await rollbackPendingCodecChange(for: participantID)
                failures.append(participantID)
                await degradePeer(
                    participantID,
                    message: error.localizedDescription,
                    disconnect: false
                )
            }
        }
        guard failures.isEmpty else {
            throw MeshParticipantRuntimeError.codecUpdateFailed(
                failures.sorted().map(\.rawValue)
            )
        }
    }

    func sendRoomControl(
        _ envelope: ClipLiveShareNativeV3ControlEnvelope
    ) async throws {
        try await broadcast(envelope)
    }

    /// Carries one closed bootstrap envelope over an already-authenticated
    /// participant link. The current room leader is the only hub: leaders may
    /// forward candidate traffic to an existing member, while an existing
    /// member may return pair establishment traffic only to that leader.
    func sendBootstrapForward(
        _ forward: ClipLiveShareNativeV3BootstrapForward,
        toDirectParticipantID participantID:
            ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try validateOutboundBootstrapForward(
            forward,
            directRecipientID: participantID
        )
        try await manager.sendControlMessage(
            ClipLiveShareNativeV3ControlCodec.encode(
                .bootstrapForward(forward)
            ),
            to: participantID
        )
    }

    func snapshot() async -> MeshParticipantRuntimeSnapshot {
        await makeSnapshot()
    }

    /// Removes one authenticated but misbehaving participant edge without
    /// changing signed room membership or interrupting healthy direct peers.
    func quarantineParticipant(
        _ participantID: ClipLiveShareNativeV3ParticipantID,
        reason: String
    ) async {
        guard isCommittedParticipant(participantID),
              participantID != context.localParticipantID else { return }
        await degradePeer(
            participantID,
            message: reason,
            disconnect: true
        )
        await publishSnapshot()
    }

    @discardableResult
    func pruneExpiredCollaboration(
        at now: ClipLiveShareNativeTimestamp
    ) async -> Bool {
        var didChange = false
        for key in collaboration.keys {
            didChange =
                collaboration[key]?.pruneExpired(at: now) == true
                || didChange
        }
        guard didChange else { return false }
        await publishSnapshot()
        return true
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        isStarted = false
        managerTask?.cancel()
        bootstrapTask?.cancel()
        managerTask = nil
        bootstrapTask = nil
        await manager.close()
        await bootstrap.close()
        emit(.closed)
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll(keepingCapacity: false)
    }

    private func validateLaunchContext(
        at now: ClipLiveShareNativeTimestamp
    ) throws {
        let membership = signedMembership.snapshot
        try authorityChain.verify(
            expectedSessionID: membership.sessionID,
            expectedFoundingCreatorIdentity:
                context.expectedFoundingCreatorIdentity,
            localCapabilities: .current,
            at: now
        )
        guard authorityChain.currentMembership == signedMembership else {
            throw ClipLiveShareNativeV3Error.invalidAuthorityChain
        }
        try signedMembership.verify(
            expectedSessionID: membership.sessionID,
            expectedLeaderParticipantID: membership.leaderParticipantID,
            expectedLeaderIdentity: membership.leaderIdentity,
            localCapabilities: .current,
            at: now
        )
        guard
            let local = membership.participants.first(where: {
                $0.participantID == context.localParticipantID
            })
        else {
            throw MeshParticipantRuntimeError.localParticipantMissing
        }
        guard local.identity == context.localIdentitySigner.publicKey else {
            throw MeshParticipantRuntimeError.localIdentityMismatch
        }
        guard membership.participants.count
            <= context.admissionPolicy.maximumParticipants else {
            throw ClipLiveShareNativeV3Error.participantLimit(
                maximum: context.admissionPolicy.maximumParticipants,
                actual: membership.participants.count
            )
        }
        try validateVerifiedNonces(
            participantIDs: membership.participantIDs,
            nonces: verifiedPeerTransportNonces
        )
        try validateBootstrapAdmissionDigests(
            participantIDs: membership.participantIDs,
            digests: bootstrapAdmissionDigests
        )
    }

    private func validateStableIdentities(
        _ incoming: ClipLiveShareSignedNativeV3MembershipSnapshot
    ) throws {
        let current = Dictionary(
            uniqueKeysWithValues: signedMembership.snapshot.participants.map {
                ($0.participantID, $0.identity)
            }
        )
        for participant in incoming.snapshot.participants {
            if let identity = current[participant.participantID],
               identity != participant.identity {
                throw ClipLiveShareNativeV3Error.participantIdentityChanged(
                    participant.participantID
                )
            }
        }
    }

    private func validateVerifiedNonces(
        participantIDs: Set<ClipLiveShareNativeV3ParticipantID>,
        nonces:
            [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3TransportNonce]
    ) throws {
        let peers = participantIDs.subtracting([context.localParticipantID])
        guard Set(nonces.keys) == peers else {
            throw MeshParticipantRuntimeError.incompletePossessionProofs
        }
    }

    private func validateBootstrapAdmissionDigests(
        participantIDs: Set<ClipLiveShareNativeV3ParticipantID>,
        digests:
            [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeDigest]
    ) throws {
        let peers = participantIDs.subtracting([context.localParticipantID])
        guard Set(digests.keys) == peers else {
            throw MeshParticipantRuntimeError.invalidBootstrapRelay
        }
    }

    private func handleManagerEvent(
        _ event: ClipLiveShareNativeV3MeshPeerLinkManagerEvent
    ) async {
        do {
            switch event {
            case let .targetedNegotiation(targeted):
                let participantID = targeted.targetParticipantID
                let hasRecoverableLink = await manager.snapshot().links
                    .contains {
                        $0.remoteParticipantID == participantID
                    }
                // A reconnecting pair must be allowed to route its
                // authenticated SDP/ICE bootstrap while the participant
                // remains degraded.
                // Remote control/media stays quarantined until the replacement
                // link itself reaches ready state.
                guard isCommittedParticipant(participantID),
                      isUsableParticipant(participantID)
                        || hasRecoverableLink
                else { break }
                do {
                    try await routeLocalNegotiation(targeted)
                } catch {
                    await degradePeer(
                        participantID,
                        message: error.localizedDescription,
                        disconnect: false
                    )
                }
            case let .controlMessageReceived(participantID, data):
                guard isUsableParticipant(participantID) else { break }
                do {
                    try await handleControlData(data, from: participantID)
                } catch {
                    await degradePeer(
                        participantID,
                        message: error.localizedDescription,
                        disconnect: true
                    )
                }
            case let .remoteVideoTrackAdded(participantID, trackID):
                guard isUsableParticipant(participantID) else { break }
                if remoteVideoTrackIDs[participantID, default: []]
                    .insert(trackID).inserted {
                    emit(.remoteVideoTrackChanged(
                        participantID: participantID,
                        mediaTrackID: trackID,
                        isAvailable: true
                    ))
                }
            case let .remoteVideoTrackRemoved(participantID, trackID):
                guard isUsableParticipant(participantID) else { break }
                if remoteVideoTrackIDs[participantID]?.remove(trackID) != nil {
                    emit(.remoteVideoTrackChanged(
                        participantID: participantID,
                        mediaTrackID: trackID,
                        isAvailable: false
                    ))
                }
            case let .remoteParticipantAudioAvailable(participantID, trackID):
                guard isUsableParticipant(participantID) else { break }
                audioTrackIDs[participantID] = trackID
            case let .remoteParticipantAudioRemoved(participantID, _):
                guard isUsableParticipant(participantID) else { break }
                audioTrackIDs[participantID] = nil
            case let .statisticsUpdated(value):
                guard isUsableParticipant(
                    value.remoteParticipantID
                ) else { break }
                statistics[value.remoteParticipantID] = value
            case let .linkFailed(_, participantID, message):
                await rollbackPendingCodecChange(for: participantID)
                guard isCommittedParticipant(participantID) else { break }
                await degradePeer(
                    participantID,
                    message: message,
                    disconnect: false
                )
            case let .reconnectExhausted(_, participantID):
                await rollbackPendingCodecChange(for: participantID)
                guard isCommittedParticipant(participantID) else { break }
                await recoverExhaustedPeer(participantID)
            case .closed:
                break
            case let .linkAdded(link), let .linkUpdated(link):
                guard isCommittedParticipant(
                    link.remoteParticipantID
                ) else { break }
                if link.isReady {
                    degradedPeerIDs.remove(link.remoteParticipantID)
                    freshLinkRecoveryAttempts[link.remoteParticipantID] = nil
                    replayReceiverState(from: await manager.snapshot())
                }
                guard isUsableParticipant(
                    link.remoteParticipantID
                ) else { break }
                do {
                    try await synchronizeLocalSourcesIfNeeded(to: link)
                } catch {
                    await degradePeer(
                        link.remoteParticipantID,
                        message: error.localizedDescription,
                        disconnect: false
                    )
                }
            case let .linkRemoved(_, participantID):
                await rollbackPendingCodecChange(for: participantID)
                markPeerMediaUnavailable(participantID)
            case .negotiationNeeded, .reconnectScheduled:
                break
            }
            await publishSnapshot()
        } catch {
            emit(.failed(error.localizedDescription))
        }
    }

    private func degradePeer(
        _ participantID: ClipLiveShareNativeV3ParticipantID,
        message: String,
        disconnect: Bool
    ) async {
        await rollbackPendingCodecChange(for: participantID)
        degradedPeerIDs.insert(participantID)
        markPeerMediaUnavailable(participantID)
        if disconnect {
            do {
                try await manager.disconnectParticipant(participantID)
            } catch {
                // The manager may already have removed an exhausted edge. The
                // runtime's logical quarantine remains authoritative either
                // way, and no other participant is affected.
            }
        }
        emit(.peerDegraded(
            participantID: participantID,
            message: message
        ))
    }

    /// Replaces exactly one exhausted pair transport while preserving the
    /// signed room membership and every healthy edge. Source synchronization
    /// is deliberately left pending until the fresh control channel reaches
    /// ready state.
    private func recoverExhaustedPeer(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) async {
        let message = String(
            localized: "Connection could not be restored."
        )
        let attempts = freshLinkRecoveryAttempts[participantID, default: 0]
        await degradePeer(
            participantID,
            message: message,
            disconnect: true
        )
        guard attempts == 0, !isClosed else { return }
        freshLinkRecoveryAttempts[participantID] = attempts + 1
        do {
            try await manager.reconcileParticipants(
                signedMembership.snapshot.participantIDs
            )
        } catch {
            emit(.peerDegraded(
                participantID: participantID,
                message: error.localizedDescription
            ))
        }
    }

    private func markPeerMediaUnavailable(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) {
        sourceSynchronizedPeers.remove(participantID)
        for trackID in remoteVideoTrackIDs.removeValue(
            forKey: participantID
        ) ?? [] {
            emit(.remoteVideoTrackChanged(
                participantID: participantID,
                mediaTrackID: trackID,
                isAvailable: false
            ))
        }
        audioTrackIDs[participantID] = nil
        statistics[participantID] = nil
    }

    private func handleBootstrapEvent(
        _ event: MeshParticipantBootstrapRouteEvent
    ) async {
        switch event {
        case let .envelope(envelope, participantID):
            do {
                try await handleBootstrapEnvelope(
                    envelope,
                    from: participantID
                )
            } catch {
                await degradePeer(
                    participantID,
                    message: error.localizedDescription,
                    disconnect: true
                )
            }
        case let .failed(message):
            // Failure of the shared rendezvous/bootstrap service is a room
            // transport failure, unlike one participant's invalid envelope.
            emit(.failed(message))
        case .closed:
            break
        }
    }

    /// Replays receiver state retained by the manager. Pair transports exist
    /// before membership promotion, so their one-shot WebRTC track callbacks
    /// may occur while the runtime is intentionally quarantining the peer.
    /// Inserting into the local sets first makes the promotion transition
    /// exactly-once even if a live manager event races this snapshot.
    private func replayReceiverState(
        from snapshot: ClipLiveShareNativeV3MeshPeerLinkManagerSnapshot
    ) {
        for link in snapshot.links
            where isCommittedParticipant(link.remoteParticipantID) {
            let participantID = link.remoteParticipantID
            for trackID in link.remoteVideoTrackIDs.sorted(by: {
                $0.rawValue < $1.rawValue
            }) {
                if remoteVideoTrackIDs[participantID, default: []]
                    .insert(trackID).inserted {
                    emit(.remoteVideoTrackChanged(
                        participantID: participantID,
                        mediaTrackID: trackID,
                        isAvailable: true
                    ))
                }
            }
            if let trackID = link.remoteParticipantAudioTrackID {
                audioTrackIDs[participantID] = trackID
            }
        }
    }

    private func handleControlData(
        _ data: Data,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        let envelope = try ClipLiveShareNativeV3ControlCodec.decode(data)
        switch envelope {
        case let .peerLinkOffer(signed):
            try await receive(signed, from: participantID)
        case let .peerLinkAnswer(signed):
            try await receive(signed, from: participantID)
        case let .peerLinkICE(signed):
            try await receive(signed, from: participantID)
        case let .peerLinkRenegotiationRequest(signed):
            try await receive(signed, from: participantID)
        case let .sourceSnapshot(snapshot):
            try receiveOrDefer(snapshot, from: participantID)
        case let .membershipSnapshot(snapshot):
            emit(.membershipReceived(snapshot, from: participantID))
        case let .sourceCursor(cursor):
            try receive(cursor, from: participantID)
            emit(.sourceCursorReceived(cursor, from: participantID))
        case let .collaboration(event):
            try applyCollaboration(
                event,
                from: participantID,
                at: try currentTimestamp()
            )
        case let .bootstrapForward(forward):
            try validateInboundBootstrapForward(
                forward,
                directSenderID: participantID
            )
            emit(.bootstrapForwardReceived(
                forward,
                from: participantID
            ))
        case let .possessionChallenge(challenge):
            guard challenge.proverParticipantID == context.localParticipantID,
                  challenge.verifierParticipantID == participantID else {
                throw MeshParticipantRuntimeError.unexpectedSender
            }
            let proof = try ClipLiveShareSignedNativeV3PossessionProof(
                signing: challenge,
                with: context.localIdentitySigner
            )
            try await sendPairEstablishment(
                .possessionProof(proof),
                to: participantID
            )
        case .possessionProof, .roomAuthority,
             .leadershipTransferRequest, .leadershipProposal,
             .leadershipVote, .leadershipCertificate,
             .participantLeaveRequest, .roomTermination:
            emit(.roomControlReceived(envelope, from: participantID))
        }
        await publishSnapshot()
    }

    private func handleBootstrapEnvelope(
        _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
        from routeParticipantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        guard case let .relay(relay) = envelope else {
            // Hello/admission/readiness are consumed by the admission owner
            // before a MeshParticipantRuntime exists.
            throw MeshParticipantRuntimeError.invalidBootstrapRelay
        }
        guard
            relay.sessionID == signedMembership.snapshot.sessionID,
            relay.admissionDigest
                == bootstrapAdmissionDigests[relay.originParticipantID],
            relay.targetParticipantID == context.localParticipantID,
            relay.payload.peerLinkKey.participantIDs
                == Set([
                    relay.originParticipantID,
                    context.localParticipantID,
                ]),
            signedMembership.snapshot.participantIDs.contains(
                relay.originParticipantID
            ),
            routeParticipantID == relay.originParticipantID
                || routeParticipantID == signedMembership.snapshot.leaderParticipantID
        else {
            throw MeshParticipantRuntimeError.invalidBootstrapRelay
        }
        let directLink = await manager.snapshot().links.first {
            $0.remoteParticipantID == relay.originParticipantID
        }
        guard directLink?.controlChannelState != .open else {
            // Once the authenticated direct path is available, accepting the
            // same pair's SDP/ICE over rendezvous would reintroduce a second
            // ordering domain and allow delayed bootstrap replay.
            throw MeshParticipantRuntimeError.invalidBootstrapRelay
        }
        let control: ClipLiveShareNativeV3ControlEnvelope = switch relay.payload {
        case let .possessionChallenge(value):
            .possessionChallenge(value)
        case let .possessionProof(value):
            .possessionProof(value)
        case let .offer(value):
            .peerLinkOffer(value)
        case let .answer(value):
            .peerLinkAnswer(value)
        case let .ice(value):
            .peerLinkICE(value)
        }
        try await handleControlEnvelope(
            control,
            from: relay.originParticipantID
        )
    }

    private func handleControlEnvelope(
        _ envelope: ClipLiveShareNativeV3ControlEnvelope,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await handleControlData(
            ClipLiveShareNativeV3ControlCodec.encode(envelope),
            from: participantID
        )
    }

    private func routeLocalNegotiation(
        _ targeted: ClipLiveShareNativeV3TargetedNegotiation
    ) async throws {
        let participantID = targeted.targetParticipantID
        guard
            let nonce = verifiedPeerTransportNonces[participantID],
            signedMembership.snapshot.participantIDs.contains(participantID)
        else {
            throw MeshParticipantRuntimeError.missingTransportNonce(participantID)
        }

        var state = negotiation[participantID] ?? NegotiationState()
        let payload: ClipLiveShareNativeV3ControlEnvelope
        switch targeted.payload {
        case let .sessionDescription(description):
            switch description.kind {
            case .offer:
                let revision: ClipLiveShareNativeV3PeerLinkRevision
                if let forced = state.forcedOutgoingOfferRevision {
                    revision = forced
                    state.forcedOutgoingOfferRevision = nil
                    try advanceNegotiationRevision(
                        past: forced,
                        for: participantID,
                        state: &state
                    )
                } else {
                    revision = try reserveNegotiationRevision(
                        for: participantID,
                        state: &state
                    )
                }
                state.activeRevision = revision
                state.nextOutgoingICESequence = 0
                state.latestIncomingICESequence = nil
                let linkContext = try negotiationContext(
                    participantID: participantID,
                    revision: revision,
                    nonce: nonce
                )
                let offer = try ClipLiveShareNativeV3PeerLinkOffer(
                    context: linkContext,
                    sdp: description.sdp
                )
                payload = .peerLinkOffer(
                    try ClipLiveShareSignedNativeV3PeerLinkOffer(
                        signing: offer,
                        with: context.localIdentitySigner,
                        senderIdentity: context.localIdentitySigner.publicKey
                    )
                )
            case .answer:
                guard let revision = state.activeRevision else {
                    throw MeshParticipantRuntimeError
                        .negotiationRevisionUnavailable(participantID)
                }
                let linkContext = try negotiationContext(
                    participantID: participantID,
                    revision: revision,
                    nonce: nonce
                )
                let answer = try ClipLiveShareNativeV3PeerLinkAnswer(
                    context: linkContext,
                    sdp: description.sdp
                )
                payload = .peerLinkAnswer(
                    try ClipLiveShareSignedNativeV3PeerLinkAnswer(
                        signing: answer,
                        with: context.localIdentitySigner,
                        senderIdentity: context.localIdentitySigner.publicKey
                    )
                )
            }
        case let .iceCandidate(candidate):
            guard let revision = state.activeRevision else {
                throw MeshParticipantRuntimeError
                    .negotiationRevisionUnavailable(participantID)
            }
            let linkContext = try negotiationContext(
                participantID: participantID,
                revision: revision,
                nonce: nonce
            )
            let ice = try ClipLiveShareNativeV3PeerLinkICECandidate(
                context: linkContext,
                candidateSequence: state.nextOutgoingICESequence,
                candidate: candidate.candidate,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: Int(candidate.sdpMLineIndex)
            )
            state.nextOutgoingICESequence &+= 1
            payload = .peerLinkICE(
                try ClipLiveShareSignedNativeV3PeerLinkICECandidate(
                    signing: ice,
                    with: context.localIdentitySigner,
                    senderIdentity: context.localIdentitySigner.publicKey
                )
            )
        }
        negotiation[participantID] = state
        do {
            try await sendPairEstablishment(payload, to: participantID)
            if case .peerLinkAnswer = payload,
               let pending = pendingCodecChanges[participantID],
               pending.negotiationRevision == state.activeRevision {
                activeVideoCodecByPeer[participantID] =
                    pending.requested
                pendingCodecChanges[participantID] = nil
            }
        } catch {
            await rollbackPendingCodecChange(for: participantID)
            throw error
        }
    }

    private func receive(
        _ signed: ClipLiveShareSignedNativeV3PeerLinkOffer,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        let offer = signed.offer
        try validateIncomingContext(offer.context, from: participantID)
        let nonce = try transportNonce(for: participantID)
        try signed.verify(
            against: signedMembership,
            expectedTransportNonce: nonce
        )
        var state = negotiation[participantID] ?? NegotiationState()
        if let active = state.activeRevision,
           offer.context.negotiationRevision <= active {
            throw MeshParticipantRuntimeError.staleNegotiationRevision
        }
        if let requested = state.requestedIncomingOfferRevision {
            guard offer.context.negotiationRevision == requested else {
                throw MeshParticipantRuntimeError
                    .staleNegotiationRevision
            }
            state.requestedIncomingOfferRevision = nil
        }
        state.activeRevision = offer.context.negotiationRevision
        try advanceNegotiationRevision(
            past: offer.context.negotiationRevision,
            for: participantID,
            state: &state
        )
        state.nextOutgoingICESequence = 0
        state.latestIncomingICESequence = nil
        negotiation[participantID] = state
        do {
            try await manager.applyRemoteNegotiation(
                .init(
                    peerLinkKey: offer.context.peerLinkKey,
                    targetParticipantID: context.localParticipantID,
                    payload: .sessionDescription(
                        .init(kind: .offer, sdp: offer.sdp)
                    )
                ),
                from: participantID
            )
        } catch {
            await rollbackPendingCodecChange(for: participantID)
            throw error
        }
    }

    private func receive(
        _ signed: ClipLiveShareSignedNativeV3PeerLinkAnswer,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        let answer = signed.answer
        try validateIncomingContext(answer.context, from: participantID)
        try signed.verify(
            against: signedMembership,
            expectedTransportNonce: try transportNonce(for: participantID)
        )
        guard negotiation[participantID]?.activeRevision
            == answer.context.negotiationRevision else {
            throw MeshParticipantRuntimeError.staleNegotiationRevision
        }
        do {
            try await manager.applyRemoteNegotiation(
                .init(
                    peerLinkKey: answer.context.peerLinkKey,
                    targetParticipantID: context.localParticipantID,
                    payload: .sessionDescription(
                        .init(kind: .answer, sdp: answer.sdp)
                    )
                ),
                from: participantID
            )
            if let pending = pendingCodecChanges[participantID],
               pending.negotiationRevision
                == answer.context.negotiationRevision {
                activeVideoCodecByPeer[participantID] =
                    pending.requested
                pendingCodecChanges[participantID] = nil
            }
        } catch {
            await rollbackPendingCodecChange(for: participantID)
            throw error
        }
    }

    private func receive(
        _ signed: ClipLiveShareSignedNativeV3PeerLinkICECandidate,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        let ice = signed.ice
        try validateIncomingContext(ice.context, from: participantID)
        try signed.verify(
            against: signedMembership,
            expectedTransportNonce: try transportNonce(for: participantID)
        )
        guard var state = negotiation[participantID],
              state.activeRevision == ice.context.negotiationRevision else {
            throw MeshParticipantRuntimeError.staleNegotiationRevision
        }
        if let latest = state.latestIncomingICESequence,
           ice.candidateSequence <= latest {
            throw MeshParticipantRuntimeError.staleICESequence
        }
        state.latestIncomingICESequence = ice.candidateSequence
        negotiation[participantID] = state
        try await manager.applyRemoteNegotiation(
            .init(
                peerLinkKey: ice.context.peerLinkKey,
                targetParticipantID: context.localParticipantID,
                payload: .iceCandidate(
                    .init(
                        candidate: ice.candidate,
                        sdpMid: ice.sdpMid,
                        sdpMLineIndex: Int32(ice.sdpMLineIndex)
                    )
                )
            ),
            from: participantID
        )
    }

    private func receive(
        _ signed:
            ClipLiveShareSignedNativeV3PeerLinkRenegotiationRequest,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        let request = signed.request
        try validateIncomingContext(
            request.context,
            from: participantID
        )
        let key = request.context.peerLinkKey
        guard
            context.localParticipantID == key.lowerParticipantID,
            participantID == key.upperParticipantID
        else {
            throw MeshParticipantRuntimeError.unexpectedSender
        }
        try signed.verify(
            against: signedMembership,
            expectedTransportNonce: try transportNonce(
                for: participantID
            ),
            at: try currentTimestamp()
        )
        guard let codec = WebRTCVideoCodec(
            rawValue: request.preferredVideoCodec
        ) else {
            throw MeshParticipantRuntimeError.unsupportedVideoCodec(
                request.preferredVideoCodec
            )
        }

        var state = negotiation[participantID] ?? NegotiationState()
        let revision = request.context.negotiationRevision
        if state.latestHandledRenegotiationRequest == revision {
            // A repeated signed request is idempotent and cannot create a
            // second offer while the first negotiation is in flight.
            let acceptedCodec =
                pendingCodecChanges[participantID]?.requested
                ?? activeVideoCodecByPeer[participantID]
                ?? initialVideoCodec
            guard acceptedCodec == codec else {
                throw ClipLiveShareNativeV3Error.contextMismatch
            }
            return
        }
        if let latest = state.latestHandledRenegotiationRequest,
           revision < latest {
            throw MeshParticipantRuntimeError.staleNegotiationRevision
        }
        if let active = state.activeRevision, revision <= active {
            throw MeshParticipantRuntimeError.staleNegotiationRevision
        }
        if pendingCodecChanges[participantID] != nil {
            throw MeshParticipantRuntimeError.codecChangeInProgress(
                participantID
            )
        }
        state.latestHandledRenegotiationRequest = revision
        state.forcedOutgoingOfferRevision = revision
        try advanceNegotiationRevision(
            past: revision,
            for: participantID,
            state: &state
        )
        negotiation[participantID] = state

        let previous =
            activeVideoCodecByPeer[participantID]
            ?? initialVideoCodec
        do {
            try await manager.updateVideoCodecPreference(
                codec,
                for: participantID,
                rollbackTo: previous
            )
            pendingCodecChanges[participantID] = .init(
                previous: previous,
                requested: codec,
                negotiationRevision: revision,
                previousNegotiationRevision: state.activeRevision
            )
            try await manager.requestNegotiation(
                with: participantID
            )
        } catch {
            await rollbackPendingCodecChange(for: participantID)
            throw error
        }
    }

    private func receive(
        _ snapshot: ClipLiveShareNativeV3SourceSnapshot,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) throws {
        guard
            signedMembership.snapshot.participantIDs.contains(participantID)
        else {
            throw MeshParticipantRuntimeError.sourceBeforeMembershipCommit
        }
        guard snapshot.ownerParticipantID == participantID else {
            throw MeshParticipantRuntimeError.sourceOwnerMismatch
        }
        guard
            snapshot.sessionID == signedMembership.snapshot.sessionID,
            snapshot.membershipRevision
                == signedMembership.snapshot.membershipRevision
        else {
            throw ClipLiveShareNativeV3Error.contextMismatch
        }
        guard snapshot.sources.count
            <= context.admissionPolicy.maximumActiveSourcesPerParticipant else {
            throw ClipLiveShareNativeV3Error.participantLimit(
                maximum:
                    context.admissionPolicy.maximumActiveSourcesPerParticipant,
                actual: snapshot.sources.count
            )
        }
        try sourceRevisionLedger.accept(
            snapshot.sourceRevision,
            from: participantID
        )
        sourceSnapshots[participantID] = snapshot
        pruneStateForPublishedSources()
    }

    private func receiveOrDefer(
        _ snapshot: ClipLiveShareNativeV3SourceSnapshot,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) throws {
        let current = signedMembership.snapshot
        guard current.participantIDs.contains(participantID) else {
            throw MeshParticipantRuntimeError.sourceBeforeMembershipCommit
        }
        guard snapshot.ownerParticipantID == participantID else {
            throw MeshParticipantRuntimeError.sourceOwnerMismatch
        }
        guard snapshot.sessionID == current.sessionID else {
            throw ClipLiveShareNativeV3Error.contextMismatch
        }
        if snapshot.membershipRevision == current.membershipRevision {
            try receive(snapshot, from: participantID)
            return
        }
        let (nextRevision, overflow) =
            current.membershipRevision.rawValue.addingReportingOverflow(1)
        guard
            !overflow,
            snapshot.membershipRevision.rawValue == nextRevision,
            snapshot.sources.count
                <= context.admissionPolicy.maximumActiveSourcesPerParticipant
        else {
            throw ClipLiveShareNativeV3Error.contextMismatch
        }
        if let pending = deferredSourceSnapshots[participantID],
           pending.sourceRevision >= snapshot.sourceRevision {
            return
        }
        deferredSourceSnapshots[participantID] = snapshot
    }

    private func receive(
        _ cursor: ClipLiveShareNativeV3SourceCursor,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) throws {
        guard
            cursor.sessionID == signedMembership.snapshot.sessionID,
            cursor.participantID == participantID,
            cursor.sourceKey.ownerParticipantID == participantID,
            let source = sourceSnapshots[participantID]?.sources.first(
                where: { $0.key == cursor.sourceKey }
            ),
            source.descriptor.stream.id == cursor.streamID
        else {
            throw ClipLiveShareNativeV3Error.contextMismatch
        }
        guard cursor.sequence
            > cursorSequenceBySource[cursor.sourceKey, default: 0] else {
            throw ClipLiveShareNativeV3CollaborationError.staleSequence(
                expectedGreaterThan:
                    cursorSequenceBySource[cursor.sourceKey, default: 0],
                actual: cursor.sequence
            )
        }
        cursorSequenceBySource[cursor.sourceKey] = cursor.sequence
    }

    private func applyCollaboration(
        _ event: ClipLiveShareNativeV3CollaborationEvent,
        from participantID: ClipLiveShareNativeV3ParticipantID,
        at now: ClipLiveShareNativeTimestamp
    ) throws {
        let sourceKey = event.context.sourceKey
        guard
            signedMembership.snapshot.participantIDs.contains(participantID),
            sourceSnapshots[sourceKey.ownerParticipantID]?.sources.contains(
                where: { $0.key == sourceKey }
            ) == true
        else {
            throw MeshParticipantRuntimeError.sourceBeforeMembershipCommit
        }
        var state = collaboration[sourceKey]
        if state == nil {
            state = ClipLiveShareNativeV3CollaborationState(
                sessionID: signedMembership.snapshot.sessionID,
                sourceKey: sourceKey
            )
        }
        try state?.apply(
            event,
            authenticatedParticipantID: participantID,
            at: now,
            mayClearEntireSource: participantID == sourceKey.ownerParticipantID
        )
        collaboration[sourceKey] = state
    }

    /// Collaboration and cursor ledgers are scoped to a random publication
    /// instance, not to a reusable logical window identifier. Removing a
    /// publication therefore removes every sequence ledger and overlay state
    /// for that exact source key. A delayed event is then rejected by
    /// `applyCollaboration` because its source is no longer in the committed
    /// source inventory, while a republished window receives a fresh random
    /// source instance and can begin again at sequence one.
    private func pruneStateForPublishedSources() {
        let activeSourceKeys = Set(
            sourceSnapshots.values.flatMap { snapshot in
                snapshot.sources.map(\.key)
            }
        )
        collaboration = collaboration.filter {
            activeSourceKeys.contains($0.key)
        }
        cursorSequenceBySource = cursorSequenceBySource.filter {
            activeSourceKeys.contains($0.key)
        }
    }

    private func broadcast(
        _ envelope: ClipLiveShareNativeV3ControlEnvelope
    ) async throws {
        let ready = Set(
            await manager.snapshot().links.compactMap { link in
                link.controlChannelState == .open
                    && isUsableParticipant(link.remoteParticipantID)
                    ? link.remoteParticipantID
                    : nil
            }
        )
        try await broadcast(envelope, to: ready)
    }

    /// Sends room traffic to the reachable subset selected by the caller.
    /// Per-edge delivery failure degrades only that edge. In particular,
    /// leadership succession must be able to commit a quorum membership after
    /// the former leader has crashed instead of waiting for the dead link.
    func sendRoomControl(
        _ envelope: ClipLiveShareNativeV3ControlEnvelope,
        to participantIDs: Set<ClipLiveShareNativeV3ParticipantID>
    ) async throws {
        try await broadcast(
            envelope,
            to: participantIDs.intersection(
                signedMembership.snapshot.participantIDs
            ).subtracting([context.localParticipantID])
        )
    }

    private func broadcast(
        _ envelope: ClipLiveShareNativeV3ControlEnvelope,
        to peers: Set<ClipLiveShareNativeV3ParticipantID>
    ) async throws {
        let data = try ClipLiveShareNativeV3ControlCodec.encode(envelope)
        let manager = manager
        let failures = await withTaskGroup(
            of: (ClipLiveShareNativeV3ParticipantID, String?).self,
            returning: [(ClipLiveShareNativeV3ParticipantID, String)].self
        ) { group in
            for participantID in peers.sorted() {
                group.addTask {
                    do {
                        try await manager.sendControlMessage(
                            data,
                            to: participantID
                        )
                        return (participantID, nil)
                    } catch {
                        return (participantID, error.localizedDescription)
                    }
                }
            }
            var result:
                [(ClipLiveShareNativeV3ParticipantID, String)] = []
            for await (participantID, message) in group {
                if let message {
                    result.append((participantID, message))
                }
            }
            return result.sorted { $0.0 < $1.0 }
        }
        for (participantID, message) in failures {
            await degradePeer(
                participantID,
                message: message,
                disconnect: false
            )
        }
    }

    /// Replicated source/collaboration state is delivered to every currently
    /// open direct channel. A joining or reconnecting peer is synchronized
    /// when that channel opens, so an unavailable participant cannot roll
    /// back an otherwise healthy local capture.
    private func broadcastToReadyPeers(
        _ envelope: ClipLiveShareNativeV3ControlEnvelope,
        requireAllSucceeded _: Bool = true
    ) async throws {
        let ready = Set(
            await manager.snapshot().links.compactMap { link in
                link.controlChannelState == .open
                    && isUsableParticipant(link.remoteParticipantID)
                    ? link.remoteParticipantID
                    : nil
            }
        )
        guard !ready.isEmpty else { return }
        let data = try ClipLiveShareNativeV3ControlCodec.encode(envelope)
        let manager = manager
        let failures = await withTaskGroup(
            of: (ClipLiveShareNativeV3ParticipantID, String?).self,
            returning: [(ClipLiveShareNativeV3ParticipantID, String)].self
        ) { group in
            for participantID in ready.sorted() {
                group.addTask {
                    do {
                        try await manager.sendControlMessage(
                            data,
                            to: participantID
                        )
                        return (participantID, nil)
                    } catch {
                        return (participantID, error.localizedDescription)
                    }
                }
            }
            var result:
                [(ClipLiveShareNativeV3ParticipantID, String)] = []
            for await (participantID, message) in group {
                if let message {
                    result.append((participantID, message))
                }
            }
            return result.sorted { $0.0 < $1.0 }
        }
        for (participantID, message) in failures {
            await degradePeer(
                participantID,
                message: message,
                disconnect: false
            )
        }
    }

    private func synchronizeLocalSourcesIfNeeded(
        to link: ClipLiveShareNativeV3PeerLinkSnapshot
    ) async throws {
        let participantID = link.remoteParticipantID
        guard isCommittedParticipant(participantID) else { return }
        guard link.controlChannelState == .open else {
            sourceSynchronizedPeers.remove(participantID)
            return
        }
        guard sourceSynchronizedPeers.insert(participantID).inserted else {
            return
        }
        guard let snapshot = sourceSnapshots[context.localParticipantID] else {
            return
        }
        do {
            try await manager.sendControlMessage(
                ClipLiveShareNativeV3ControlCodec.encode(
                    .sourceSnapshot(snapshot)
                ),
                to: participantID
            )
        } catch {
            sourceSynchronizedPeers.remove(participantID)
            throw error
        }
    }

    private func isCommittedParticipant(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) -> Bool {
        signedMembership.snapshot.participantIDs.contains(participantID)
    }

    private func isUsableParticipant(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) -> Bool {
        isCommittedParticipant(participantID)
            && !degradedPeerIDs.contains(participantID)
    }

    private func makeLocalSourceSnapshot(
        _ sources: [ClipLiveShareNativeV3PublishedSource]
    ) throws -> ClipLiveShareNativeV3SourceSnapshot {
        let revision = try ClipLiveShareNativeV3SourceRevision(
            rawValue: nextLocalSourceRevisionRawValue
        )
        let snapshot = try ClipLiveShareNativeV3SourceSnapshot(
            sessionID: signedMembership.snapshot.sessionID,
            membershipRevision: signedMembership.snapshot.membershipRevision,
            ownerParticipantID: context.localParticipantID,
            sourceRevision: revision,
            sources: sources,
            maximumSources:
                context.admissionPolicy.maximumActiveSourcesPerParticipant
        )
        nextLocalSourceRevisionRawValue &+= 1
        return snapshot
    }

    private func sendPairEstablishment(
        _ envelope: ClipLiveShareNativeV3ControlEnvelope,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        let link = await manager.snapshot().links.first {
            $0.remoteParticipantID == participantID
        }
        if link?.controlChannelState == .open {
            try await manager.sendControlMessage(
                ClipLiveShareNativeV3ControlCodec.encode(envelope),
                to: participantID
            )
            return
        }
        let payload: ClipLiveShareNativeV3BootstrapRelayPayload
        switch envelope {
        case let .possessionChallenge(value):
            payload = .possessionChallenge(value)
        case let .possessionProof(value):
            payload = .possessionProof(value)
        case let .peerLinkOffer(value):
            payload = .offer(value)
        case let .peerLinkAnswer(value):
            payload = .answer(value)
        case let .peerLinkICE(value):
            payload = .ice(value)
        default:
            throw MeshParticipantRuntimeError.invalidBootstrapRelay
        }
        try await bootstrap.send(
            .relay(
                try .init(
                    sessionID: signedMembership.snapshot.sessionID,
                    admissionDigest: try bootstrapAdmissionDigest(
                        for: participantID
                    ),
                    originParticipantID: context.localParticipantID,
                    targetParticipantID: participantID,
                    payload: payload
                )
            ),
            to: participantID
        )
    }

    private func bootstrapAdmissionDigest(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) throws -> ClipLiveShareNativeDigest {
        guard let digest = bootstrapAdmissionDigests[participantID] else {
            throw MeshParticipantRuntimeError.invalidBootstrapRelay
        }
        return digest
    }

    private func validateOutboundBootstrapForward(
        _ forward: ClipLiveShareNativeV3BootstrapForward,
        directRecipientID: ClipLiveShareNativeV3ParticipantID
    ) throws {
        let membership = signedMembership.snapshot
        guard
            forward.sessionID == membership.sessionID,
            membership.participantIDs.contains(
                context.localParticipantID
            ),
            membership.participantIDs.contains(directRecipientID),
            directRecipientID != context.localParticipantID
        else {
            throw MeshParticipantRuntimeError.invalidBootstrapForward
        }

        if context.localParticipantID
            == membership.leaderParticipantID {
            guard
                directRecipientID != membership.leaderParticipantID,
                forward.targetParticipantID == directRecipientID,
                isLeaderToExistingBootstrapForward(
                    forward,
                    membership: membership
                )
            else {
                throw MeshParticipantRuntimeError.invalidBootstrapForward
            }
        } else {
            guard
                directRecipientID == membership.leaderParticipantID,
                forward.originParticipantID
                    == context.localParticipantID,
                !membership.participantIDs.contains(
                    forward.targetParticipantID
                ),
                isExistingToLeaderBootstrapForward(forward)
            else {
                throw MeshParticipantRuntimeError.invalidBootstrapForward
            }
        }
    }

    private func validateInboundBootstrapForward(
        _ forward: ClipLiveShareNativeV3BootstrapForward,
        directSenderID: ClipLiveShareNativeV3ParticipantID
    ) throws {
        let membership = signedMembership.snapshot
        guard
            forward.sessionID == membership.sessionID,
            membership.participantIDs.contains(directSenderID),
            directSenderID != context.localParticipantID
        else {
            throw MeshParticipantRuntimeError.invalidBootstrapForward
        }

        if context.localParticipantID
            == membership.leaderParticipantID {
            guard
                directSenderID == forward.originParticipantID,
                !membership.participantIDs.contains(
                    forward.targetParticipantID
                ),
                isExistingToLeaderBootstrapForward(forward)
            else {
                throw MeshParticipantRuntimeError.invalidBootstrapForward
            }
        } else {
            guard
                directSenderID == membership.leaderParticipantID,
                forward.targetParticipantID
                    == context.localParticipantID,
                isLeaderToExistingBootstrapForward(
                    forward,
                    membership: membership
                )
            else {
                throw MeshParticipantRuntimeError.invalidBootstrapForward
            }
        }
    }

    private func isLeaderToExistingBootstrapForward(
        _ forward: ClipLiveShareNativeV3BootstrapForward,
        membership: ClipLiveShareNativeV3MembershipSnapshot
    ) -> Bool {
        switch forward.envelope {
        case let .hello(value):
            return
                value.hello.participantID
                    == forward.originParticipantID
                && !membership.participantIDs.contains(
                    value.hello.participantID
                )
        case let .provisionalAdmission(value):
            let admission = value.admission
            return
                forward.originParticipantID
                    == membership.leaderParticipantID
                && admission.currentMembership == signedMembership
                && admission.currentMembership.snapshot
                    .leaderParticipantID
                    == membership.leaderParticipantID
                && !membership.participantIDs.contains(
                    admission.candidateParticipantID
                )
        case let .relay(value):
            return
                value.originParticipantID
                    == forward.originParticipantID
                && !membership.participantIDs.contains(
                    value.originParticipantID
                )
        case .linkReadiness, .admitted, .rejected:
            return false
        }
    }

    private func isExistingToLeaderBootstrapForward(
        _ forward: ClipLiveShareNativeV3BootstrapForward
    ) -> Bool {
        switch forward.envelope {
        case let .relay(value):
            value.originParticipantID == forward.originParticipantID
        case let .linkReadiness(value):
            value.readiness.reporterParticipantID
                == forward.originParticipantID
        case .hello, .provisionalAdmission, .admitted, .rejected:
            false
        }
    }

    private func negotiationContext(
        participantID: ClipLiveShareNativeV3ParticipantID,
        revision: ClipLiveShareNativeV3PeerLinkRevision,
        nonce: ClipLiveShareNativeV3TransportNonce
    ) throws -> ClipLiveShareNativeV3PeerLinkContext {
        try ClipLiveShareNativeV3PeerLinkContext(
            sessionID: signedMembership.snapshot.sessionID,
            membershipRevision:
                signedMembership.snapshot.membershipRevision,
            peerLinkKey: ClipLiveShareNativeV3PeerLinkKey(
                context.localParticipantID,
                participantID
            ),
            negotiationRevision: revision,
            senderParticipantID: context.localParticipantID,
            receiverParticipantID: participantID,
            transportNonce: nonce
        )
    }

    private func validateIncomingContext(
        _ incoming: ClipLiveShareNativeV3PeerLinkContext,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) throws {
        guard
            incoming.senderParticipantID == participantID,
            incoming.receiverParticipantID == context.localParticipantID
        else {
            throw MeshParticipantRuntimeError.unexpectedSender
        }
    }

    private func transportNonce(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) throws -> ClipLiveShareNativeV3TransportNonce {
        guard let value = verifiedPeerTransportNonces[participantID] else {
            throw MeshParticipantRuntimeError.missingTransportNonce(
                participantID
            )
        }
        return value
    }

    private func reserveNegotiationRevision(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        state: inout NegotiationState
    ) throws -> ClipLiveShareNativeV3PeerLinkRevision {
        guard state.nextRevisionRawValue < UInt64.max else {
            throw MeshParticipantRuntimeError.negotiationRevisionExhausted(
                participantID
            )
        }
        let revision = try ClipLiveShareNativeV3PeerLinkRevision(
            rawValue: state.nextRevisionRawValue
        )
        state.nextRevisionRawValue += 1
        return revision
    }

    private func advanceNegotiationRevision(
        past revision: ClipLiveShareNativeV3PeerLinkRevision,
        for participantID: ClipLiveShareNativeV3ParticipantID,
        state: inout NegotiationState
    ) throws {
        guard revision.rawValue < UInt64.max else {
            throw MeshParticipantRuntimeError.negotiationRevisionExhausted(
                participantID
            )
        }
        state.nextRevisionRawValue = max(
            state.nextRevisionRawValue,
            revision.rawValue + 1
        )
    }

    private func rollbackPendingCodecChange(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async {
        guard let pending = pendingCodecChanges.removeValue(
            forKey: participantID
        ) else { return }
        try? await manager.updateVideoCodecPreference(
            pending.previous,
            for: participantID,
            rollbackTo: pending.requested
        )
        if var state = negotiation[participantID] {
            if state.forcedOutgoingOfferRevision
                == pending.negotiationRevision {
                state.forcedOutgoingOfferRevision = nil
            }
            if state.requestedIncomingOfferRevision
                == pending.negotiationRevision {
                state.requestedIncomingOfferRevision = nil
            }
            if state.activeRevision == pending.negotiationRevision {
                state.activeRevision =
                    pending.previousNegotiationRevision
                state.nextOutgoingICESequence = 0
                state.latestIncomingICESequence = nil
            }
            if state.latestHandledRenegotiationRequest
                == pending.negotiationRevision {
                state.latestHandledRenegotiationRequest = nil
            }
            negotiation[participantID] = state
        }
    }

    private func publishSnapshot() async {
        emit(.snapshotChanged(await makeSnapshot()))
    }

    private func makeSnapshot() async -> MeshParticipantRuntimeSnapshot {
        let committedParticipantIDs =
            signedMembership.snapshot.participantIDs
                .subtracting(degradedPeerIDs)
        return MeshParticipantRuntimeSnapshot(
            signedMembership: signedMembership,
            links: await manager.snapshot().retainingParticipants(
                committedParticipantIDs
            ),
            sourceSnapshots: sourceSnapshots,
            audioTrackIDs: audioTrackIDs,
            statistics: statistics,
            collaboration: collaboration
        )
    }

    private func emit(_ event: MeshParticipantRuntimeEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func currentTimestamp() throws -> ClipLiveShareNativeTimestamp {
        try ClipLiveShareNativeTimestamp(date: Date())
    }
}
