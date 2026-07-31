import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation

enum MeshParticipantRoomConnectionPhase: Equatable, Sendable {
    case idle
    case publishingInvite
    case joining
    case accessWordRequired
    case awaitingApproval
    case preparingPeerLinks
    case active
    case rejected(ClipLiveShareNativeV3BootstrapRejectionReason)
    case timedOut
    case failed(String)
    case closed
}

struct MeshParticipantRoomMediaComponents: Sendable {
    let factory: ClipLiveShareNativeV3WebRTCTransportFactory
    let peerLinkManager: ClipLiveShareNativeV3MeshPeerLinkManager
}

/// Fully authenticated application handoff produced by both creator and
/// candidate entry. There is deliberately no owner/candidate role in this value.
struct MeshParticipantRoomActivation: Sendable {
    let context: MeshParticipantLaunchContext
    let bootstrap: any MeshParticipantBootstrapRouting
    let media: MeshParticipantRoomMediaComponents?
}

enum MeshParticipantRoomConnectionEvent: Sendable {
    case phaseChanged(MeshParticipantRoomConnectionPhase)
    case inviteChanged(ClipLiveShareNativeV3Invite?)
    case accessWordRequirementChanged(Bool)
    case admissionRequested(ClipLiveShareNativeV3Participant)
    case activationReady(MeshParticipantRoomActivation)
    case membershipUpdateReady(MeshParticipantBootstrapLaunchContext)
    case admissionFailed(String)
    case inviteRefreshFailed(String)
    case rejected(ClipLiveShareNativeV3BootstrapRejectionReason)
    case failed(String)
    case closed
}

struct MeshParticipantRoomConnectionSnapshot: Equatable, Sendable {
    let phase: MeshParticipantRoomConnectionPhase
    let invite: ClipLiveShareNativeV3Invite?
    let accessWordRequired: Bool?
    let pendingAdmission: ClipLiveShareNativeV3Participant?
    let membershipRevision: ClipLiveShareNativeV3MembershipRevision?
    let leaderParticipantID: ClipLiveShareNativeV3ParticipantID?
}

/// Closure-backed owner route used so the room owner can be tested without a
/// server while production still owns the real signed encrypted rendezvous.
struct MeshParticipantRoomOwnerRoute: Sendable {
    let invite: ClipLiveShareNativeV3Invite
    var events: @Sendable () async
        -> AsyncStream<MeshParticipantEncryptedRendezvousEvent>
    var start: @Sendable () async throws -> Void
    var send: @Sendable (
        ClipLiveShareNativeV3BootstrapEnvelope,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    var closeRoute: @Sendable (
        ClipLiveShareNativeV3ParticipantID,
        String?
    ) async -> Void
    var stop: @Sendable (Bool) async -> Void

    static func live(
        _ owner: MeshParticipantEncryptedRendezvousOwner
    ) -> Self {
        Self(
            invite: owner.invite,
            events: { await owner.events() },
            start: { try await owner.start() },
            send: { envelope, participantID in
                try await owner.send(envelope, to: participantID)
            },
            closeRoute: { participantID, reason in
                await owner.closeRoute(
                    for: participantID,
                    reason: reason
                )
            },
            stop: { remove in
                await owner.stop(removeRendezvous: remove)
            }
        )
    }
}

struct MeshParticipantRoomCandidateRoute: Sendable {
    var events: @Sendable () async
        -> AsyncStream<MeshParticipantEncryptedRendezvousEvent>
    var start: @Sendable () async throws -> Void
    var send: @Sendable (
        ClipLiveShareNativeV3BootstrapEnvelope,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    var stop: @Sendable () async -> Void
    var accessWordRequired: @Sendable () async -> Bool?

    init(
        events: @escaping @Sendable () async
            -> AsyncStream<MeshParticipantEncryptedRendezvousEvent>,
        start: @escaping @Sendable () async throws -> Void,
        send: @escaping @Sendable (
            ClipLiveShareNativeV3BootstrapEnvelope,
            ClipLiveShareNativeV3ParticipantID
        ) async throws -> Void,
        stop: @escaping @Sendable () async -> Void,
        accessWordRequired: @escaping @Sendable () async -> Bool? = {
            nil
        }
    ) {
        self.events = events
        self.start = start
        self.send = send
        self.stop = stop
        self.accessWordRequired = accessWordRequired
    }

    static func live(
        _ candidate: MeshParticipantEncryptedRendezvousCandidate
    ) -> Self {
        Self(
            events: { await candidate.events() },
            start: { try await candidate.start() },
            send: { envelope, participantID in
                try await candidate.send(envelope, to: participantID)
            },
            stop: { await candidate.stop() },
            accessWordRequired: {
                await candidate.accessWordRequired()
            }
        )
    }
}

struct MeshParticipantRoomOwnerRouteConfiguration: Sendable {
    let endpoint: URL
    let sessionID: ClipLiveShareSessionID
    let foundingCreatorIdentity: ClipLiveShareIdentityPublicKey
    let leaderParticipantID: ClipLiveShareNativeV3ParticipantID
    let leaderSigner: any ClipLiveShareIdentitySigner
    let accessWordRequired: Bool

    init(
        endpoint: URL,
        sessionID: ClipLiveShareSessionID,
        foundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
        leaderParticipantID: ClipLiveShareNativeV3ParticipantID,
        leaderSigner: any ClipLiveShareIdentitySigner,
        accessWordRequired: Bool = false
    ) {
        self.endpoint = endpoint
        self.sessionID = sessionID
        self.foundingCreatorIdentity = foundingCreatorIdentity
        self.leaderParticipantID = leaderParticipantID
        self.leaderSigner = leaderSigner
        self.accessWordRequired = accessWordRequired
    }
}

struct MeshParticipantRoomConnectionRouteFactory: Sendable {
    typealias MakeOwner = @Sendable (
        MeshParticipantRoomOwnerRouteConfiguration
    ) throws -> MeshParticipantRoomOwnerRoute
    typealias MakeCandidate = @Sendable (
        ClipLiveShareNativeV3Invite,
        ClipLiveShareNativeV3ParticipantID
    ) -> MeshParticipantRoomCandidateRoute

    var makeOwner: MakeOwner
    var makeCandidate: MakeCandidate

    static let live = Self(
        makeOwner: { configuration in
            try .live(MeshParticipantEncryptedRendezvousOwner(
                endpoint: configuration.endpoint,
                sessionID: configuration.sessionID,
                foundingCreatorIdentity:
                    configuration.foundingCreatorIdentity,
                leaderParticipantID:
                    configuration.leaderParticipantID,
                leaderSigner: configuration.leaderSigner,
                accessWordRequired:
                    configuration.accessWordRequired
            ))
        },
        makeCandidate: { invite, participantID in
            .live(MeshParticipantEncryptedRendezvousCandidate(
                invite: invite,
                participantID: participantID
            ))
        }
    )
}

/// Owns the one provisional peer-link adapter used before and after membership
/// commit. Production construction shares its manager/factory with the
/// eventual participant runtime, so promotion never creates a second link.
struct MeshParticipantRoomPeerLinks: Sendable {
    typealias Bind = @Sendable (
        MeshParticipantBootstrapCoordinator,
        @escaping @Sendable (String) -> Void
    ) async -> Void

    let pairHooks: MeshParticipantBootstrapPairHooks
    let media: MeshParticipantRoomMediaComponents?
    var bind: Bind
    var sendForward: @Sendable (
        ClipLiveShareNativeV3BootstrapForward,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    var sendMembership: @Sendable (
        ClipLiveShareSignedNativeV3MembershipSnapshot,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    var close: @Sendable () async -> Void

    static func production(
        localParticipantID: ClipLiveShareNativeV3ParticipantID,
        localSigner: any ClipLiveShareIdentitySigner,
        initiallyCommittedParticipantIDs:
            Set<ClipLiveShareNativeV3ParticipantID>,
        configuration: ClipLiveShareNativeV3WebRTCConfiguration =
            .clipDefault
    ) throws -> Self {
        let factory = try ClipLiveShareNativeV3WebRTCTransportFactory(
            configuration: configuration
        )
        let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
            localParticipantID: localParticipantID,
            transportFactory: factory
        )
        let adapter = try MeshParticipantProvisionalPeerLinkAdapter(
            localParticipantID: localParticipantID,
            localSigner: localSigner,
            committedParticipantIDs: initiallyCommittedParticipantIDs,
            manager: manager
        )
        return Self(
            pairHooks: adapter.makePairHooks(),
            media: .init(
                factory: factory,
                peerLinkManager: manager
            ),
            bind: { coordinator, reportFailure in
                await adapter.installCallbacks(.init(
                    sendRelay: { payload, participantID in
                        try await coordinator.relayPairPayload(
                            payload,
                            to: participantID
                        )
                    },
                    markReady: { participantID, now in
                        try await coordinator.markPeerLinkReady(
                            with: participantID,
                            at: now
                        )
                    },
                    reportFailure: reportFailure
                ))
            },
            sendForward: { forward, participantID in
                try await manager.sendControlMessage(
                    ClipLiveShareNativeV3ControlCodec.encode(
                        .bootstrapForward(forward)
                    ),
                    to: participantID
                )
            },
            sendMembership: { membership, participantID in
                try await manager.sendControlMessage(
                    ClipLiveShareNativeV3ControlCodec.encode(
                        .membershipSnapshot(membership)
                    ),
                    to: participantID
                )
            },
            close: {
                await adapter.close()
                await manager.close()
                factory.close()
            }
        )
    }

    static func testing(
        pairHooks: MeshParticipantBootstrapPairHooks = .init(),
        bind: @escaping Bind = { _, _ in },
        sendForward: @escaping @Sendable (
            ClipLiveShareNativeV3BootstrapForward,
            ClipLiveShareNativeV3ParticipantID
        ) async throws -> Void = { _, _ in },
        sendMembership: @escaping @Sendable (
            ClipLiveShareSignedNativeV3MembershipSnapshot,
            ClipLiveShareNativeV3ParticipantID
        ) async throws -> Void = { _, _ in },
        close: @escaping @Sendable () async -> Void = {}
    ) -> Self {
        Self(
            pairHooks: pairHooks,
            media: nil,
            bind: bind,
            sendForward: sendForward,
            sendMembership: sendMembership,
            close: close
        )
    }
}

/// Direct native-v3 room connection owner.
///
/// It owns only encrypted rendezvous, bounded admission, provisional links and
/// the activation boundary. AppKit/popover state is intentionally outside this
/// actor. Once activated, `MeshParticipantCoordinator` owns room media and
/// leadership; it calls back here for forwarded admission messages and for a
/// freshly advertised invite after certified leadership succession.
actor MeshParticipantRoomConnectionSession {
    private enum Entry: Sendable {
        case creator(MeshParticipantRoomOwnerRoute)
        case candidate(
            invite: ClipLiveShareNativeV3Invite,
            route: MeshParticipantRoomCandidateRoute,
            accessWord: String?
        )
    }

    private let localParticipant: ClipLiveShareNativeV3Participant
    private let localSigner: any ClipLiveShareIdentitySigner
    private let endpoint: URL
    private let admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy
    private let routeFactory: MeshParticipantRoomConnectionRouteFactory
    private let peerLinks: MeshParticipantRoomPeerLinks
    private let now: @Sendable () throws -> ClipLiveShareNativeTimestamp
    private let timeoutSleeper: any ClipLiveShareReconnectSleeper
    private let runtimeBootstrapRoute = MeshParticipantRoomBootstrapRoute()

    private var entry: Entry
    private var requiredAccessWord: String?
    private var committedContext: MeshParticipantBootstrapLaunchContext?
    private var roomAvailability:
        MeshParticipantBootstrapRoomAvailability = .active
    private var phase: MeshParticipantRoomConnectionPhase = .idle
    private var invite: ClipLiveShareNativeV3Invite?
    private var pendingAdmission: ClipLiveShareNativeV3Participant?
    private var candidateAccessWordRequired: Bool?
    private var candidateRendezvousProof:
        ClipLiveShareNativeV3RendezvousProof?
    private var activeBootstrap: MeshParticipantBootstrapCoordinator?
    private var activeCandidateID: ClipLiveShareNativeV3ParticipantID?
    private var activeAdmissionDigest: ClipLiveShareNativeDigest?
    private var pendingInviteRefresh = false
    private var rendezvousTask: Task<Void, Never>?
    private var isRendezvousRouteActive = false
    private var bootstrapTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var didStart = false
    private var isClosed = false
    private var continuations: [
        UUID: AsyncStream<MeshParticipantRoomConnectionEvent>.Continuation
    ] = [:]

    private init(
        localParticipant: ClipLiveShareNativeV3Participant,
        localSigner: any ClipLiveShareIdentitySigner,
        endpoint: URL,
        admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy,
        entry: Entry,
        requiredAccessWord: String?,
        committedContext: MeshParticipantBootstrapLaunchContext?,
        routeFactory: MeshParticipantRoomConnectionRouteFactory,
        peerLinks: MeshParticipantRoomPeerLinks,
        now: @escaping @Sendable () throws -> ClipLiveShareNativeTimestamp,
        timeoutSleeper: any ClipLiveShareReconnectSleeper
    ) {
        self.localParticipant = localParticipant
        self.localSigner = localSigner
        self.endpoint = endpoint
        self.admissionPolicy = admissionPolicy
        self.entry = entry
        self.requiredAccessWord = requiredAccessWord
            .map(ClipLiveShareNativeV3AccessWordProof.normalize)
            .flatMap { $0.isEmpty ? nil : $0 }
        self.committedContext = committedContext
        self.routeFactory = routeFactory
        self.peerLinks = peerLinks
        self.now = now
        self.timeoutSleeper = timeoutSleeper
    }

    static func creator(
        endpoint: URL,
        sessionID: ClipLiveShareSessionID,
        participant: ClipLiveShareNativeV3Participant,
        signer: any ClipLiveShareIdentitySigner,
        admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy =
            .productDefault,
        requiredAccessWord: String? = nil,
        routeFactory: MeshParticipantRoomConnectionRouteFactory = .live,
        peerLinks injectedPeerLinks: MeshParticipantRoomPeerLinks? = nil,
        webRTCConfiguration: ClipLiveShareNativeV3WebRTCConfiguration =
            .clipDefault,
        now: @escaping @Sendable () throws
            -> ClipLiveShareNativeTimestamp = {
                try .init(date: Date())
            },
        timeoutSleeper: any ClipLiveShareReconnectSleeper =
            ContinuousClipLiveShareReconnectSleeper()
    ) throws -> MeshParticipantRoomConnectionSession {
        let timestamp = try now()
        let context = try MeshParticipantBootstrapCoordinator.creatorGenesis(
            sessionID: sessionID,
            creator: participant,
            creatorSigner: signer,
            admissionPolicy: admissionPolicy,
            at: timestamp
        )
        let route = try routeFactory.makeOwner(.init(
            endpoint: endpoint,
            sessionID: sessionID,
            foundingCreatorIdentity: participant.identity,
            leaderParticipantID: participant.participantID,
            leaderSigner: signer,
            accessWordRequired:
                Self.normalizedAccessWord(requiredAccessWord) != nil
        ))
        let links = try injectedPeerLinks ?? .production(
            localParticipantID: participant.participantID,
            localSigner: signer,
            initiallyCommittedParticipantIDs: [participant.participantID],
            configuration: webRTCConfiguration
        )
        let session = MeshParticipantRoomConnectionSession(
            localParticipant: participant,
            localSigner: signer,
            endpoint: endpoint,
            admissionPolicy: admissionPolicy,
            entry: .creator(route),
            requiredAccessWord: requiredAccessWord,
            committedContext: context,
            routeFactory: routeFactory,
            peerLinks: links,
            now: now,
            timeoutSleeper: timeoutSleeper
        )
        return session
    }

    static func candidate(
        invite: ClipLiveShareNativeV3Invite,
        participant: ClipLiveShareNativeV3Participant,
        signer: any ClipLiveShareIdentitySigner,
        accessWord: String? = nil,
        admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy =
            .productDefault,
        routeFactory: MeshParticipantRoomConnectionRouteFactory = .live,
        peerLinks injectedPeerLinks: MeshParticipantRoomPeerLinks? = nil,
        webRTCConfiguration: ClipLiveShareNativeV3WebRTCConfiguration =
            .clipDefault,
        now: @escaping @Sendable () throws
            -> ClipLiveShareNativeTimestamp = {
                try .init(date: Date())
            },
        timeoutSleeper: any ClipLiveShareReconnectSleeper =
            ContinuousClipLiveShareReconnectSleeper()
    ) throws -> MeshParticipantRoomConnectionSession {
        guard participant.identity == signer.publicKey else {
            throw MeshParticipantRuntimeError.localIdentityMismatch
        }
        let links = try injectedPeerLinks ?? .production(
            localParticipantID: participant.participantID,
            localSigner: signer,
            initiallyCommittedParticipantIDs: [participant.participantID],
            configuration: webRTCConfiguration
        )
        return MeshParticipantRoomConnectionSession(
            localParticipant: participant,
            localSigner: signer,
            endpoint: invite.endpoint,
            admissionPolicy: admissionPolicy,
            entry: .candidate(
                invite: invite,
                route: routeFactory.makeCandidate(
                    invite,
                    participant.participantID
                ),
                accessWord: accessWord
            ),
            requiredAccessWord: nil,
            committedContext: nil,
            routeFactory: routeFactory,
            peerLinks: links,
            now: now,
            timeoutSleeper: timeoutSleeper
        )
    }

    private func setRequiredAccessWord(_ value: String?) {
        requiredAccessWord = Self.normalizedAccessWord(value)
    }

    private static func normalizedAccessWord(
        _ value: String?
    ) -> String? {
        value
            .map(ClipLiveShareNativeV3AccessWordProof.normalize)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    func events() -> AsyncStream<MeshParticipantRoomConnectionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: MeshParticipantRoomConnectionEvent.self,
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

    func snapshot() -> MeshParticipantRoomConnectionSnapshot {
        let isLocalLeader =
            committedContext?.signedMembership.snapshot
                .leaderParticipantID
                == localParticipant.participantID
        return .init(
            phase: phase,
            invite: invite,
            accessWordRequired: candidateAccessWordRequired
                ?? (isLocalLeader ? requiredAccessWord != nil : nil),
            pendingAdmission: pendingAdmission,
            membershipRevision:
                committedContext?.signedMembership.snapshot
                    .membershipRevision,
            leaderParticipantID:
                committedContext?.signedMembership.snapshot
                    .leaderParticipantID
        )
    }

    func start() async throws {
        guard !isClosed else {
            throw MeshParticipantBootstrapError.closed
        }
        guard !didStart else {
            throw MeshParticipantEncryptedRendezvousError.alreadyStarted
        }
        didStart = true
        await runtimeBootstrapRoute.setOutbound { [weak self] envelope, id in
            guard let self else { throw CancellationError() }
            try await self.routeBootstrap(envelope, to: id)
        }

        switch entry {
        case let .creator(route):
            setPhase(.publishingInvite)
            listen(to: route)
            do {
                try await route.start()
                isRendezvousRouteActive = true
                invite = route.invite
                emit(.inviteChanged(route.invite))
                guard let committedContext else {
                    throw MeshParticipantBootstrapError.missingAdmission
                }
                emitActivation(committedContext)
                setPhase(.active)
            } catch {
                await failAndClose(error.localizedDescription)
                throw error
            }

        case let .candidate(_, route, _):
            setPhase(.joining)
            listen(to: route)
            do {
                try await route.start()
                isRendezvousRouteActive = true
            } catch {
                await failAndClose(error.localizedDescription)
                throw error
            }
        }
    }

    func approveAdmission(
        _ participantID: ClipLiveShareNativeV3ParticipantID,
        at timestamp: ClipLiveShareNativeTimestamp? = nil
    ) async throws {
        guard roomAvailability == .active else {
            throw MeshParticipantBootstrapError.roomAuthorityUnavailable
        }
        guard participantID == activeCandidateID,
              let activeBootstrap else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        try await activeBootstrap.approveAdmission(
            at: try timestamp ?? now()
        )
    }

    func denyAdmission(
        _ participantID: ClipLiveShareNativeV3ParticipantID,
        reason: ClipLiveShareNativeV3BootstrapRejectionReason = .denied
    ) async throws {
        guard participantID == activeCandidateID,
              let activeBootstrap else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        do {
            try await activeBootstrap.denyAdmission(reason: reason)
        } catch {
            await finishRejectedTransactionIfNeeded(
                activeBootstrap
            )
            throw error
        }
        await finishRejectedTransactionIfNeeded(activeBootstrap)
    }

    /// Deterministic seam used by the timeout task and unattended tests.
    func expireAdmission(
        at timestamp: ClipLiveShareNativeTimestamp
    ) async throws {
        if let activeBootstrap {
            try await activeBootstrap.expire(at: timestamp)
            let snapshot = await activeBootstrap.snapshot()
            if snapshot.phase == .timedOut
                || snapshot.phase == .rejected(.timedOut) {
                emit(.rejected(.timedOut))
                await finishRejectedAdmission(.timedOut)
                return
            }
        }
        guard activeCandidateID != nil
                || candidateRendezvousProof != nil
        else { return }
        await timeoutAdmission()
    }

    /// Receives a bootstrap-forward control value after the runtime has
    /// authenticated its direct sender.
    @discardableResult
    func receiveBootstrapForward(
        _ forward: ClipLiveShareNativeV3BootstrapForward,
        from directSenderID: ClipLiveShareNativeV3ParticipantID,
        at timestamp: ClipLiveShareNativeTimestamp? = nil
    ) async throws -> Bool {
        guard let context = committedContext,
              forward.sessionID
                == context.signedMembership.snapshot.sessionID
        else {
            throw MeshParticipantRuntimeError.invalidBootstrapForward
        }
        if activeBootstrap == nil {
            guard
                directSenderID
                    == context.signedMembership.snapshot
                    .leaderParticipantID,
                case let .hello(hello) = forward.envelope
            else {
                throw MeshParticipantRuntimeError.invalidBootstrapForward
            }
            try await beginMemberAdmission(
                candidateID: hello.hello.participantID,
                proof: nil
            )
        }
        guard let activeBootstrap else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        try await activeBootstrap.receive(
            forward.envelope,
            from: directSenderID,
            at: try timestamp ?? now()
        )
        return true
    }

    /// Existing members receive the final admission snapshot over their
    /// authenticated direct leader link rather than the public rendezvous.
    /// Returning true means the active bootstrap transaction consumed it and
    /// promoted the already-created provisional transport.
    @discardableResult
    func receiveCommittedMembership(
        _ membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
        from leaderParticipantID: ClipLiveShareNativeV3ParticipantID,
        at timestamp: ClipLiveShareNativeTimestamp? = nil
    ) async throws -> Bool {
        guard let activeBootstrap else { return false }
        guard await activeBootstrap.canConsumeCommittedMembership(
            membership,
            from: leaderParticipantID
        ) else {
            return false
        }
        try await activeBootstrap.receive(
            .admitted(membership),
            from: leaderParticipantID,
            at: try timestamp ?? now()
        )
        if let context = await activeBootstrap.launchContext(),
           self.activeBootstrap === activeBootstrap {
            await completeMembershipUpdate(context)
        }
        return true
    }

    /// Called after the participant lifecycle commits an ordinary membership
    /// or a certified leadership transition. A successor allocates a fresh
    /// encrypted route; the crashed/departed leader's server lease is never
    /// inherited.
    func applyCommittedContext(
        _ context: MeshParticipantBootstrapLaunchContext,
        availability: MeshParticipantBootstrapRoomAvailability = .active,
        refreshInviteIfLocalLeader: Bool
    ) async throws {
        // Admission is transactional against one exact committed membership.
        // An ordinary refresh, removal, or leadership change must not leave a
        // same-leader bootstrap alive on an older revision: that transaction
        // could later commit stale state or reintroduce a removed member.
        //
        // The only safe overlap is the admission transaction delivering its
        // own completed launch context before `finishAdmission()` has resumed.
        // Preserve that exact transaction; abort every other in-flight one
        // before publishing the newer committed context.
        let committedMembershipChanged =
            committedContext?.signedMembership != context.signedMembership
                || committedContext?.authorityChain != context.authorityChain
        if committedMembershipChanged, let transaction = activeBootstrap {
            let completed = await transaction.launchContext()
            let isCompletingThisTransaction =
                completed?.signedMembership == context.signedMembership
                    && completed?.authorityChain == context.authorityChain
            if !isCompletingThisTransaction,
               activeBootstrap === transaction {
                await abortAdmission(
                    message:
                        "Admission was cancelled because room membership changed."
                )
            }
        }
        committedContext = context
        roomAvailability = availability
        guard availability == .active else {
            pendingInviteRefresh = false
            if activeBootstrap != nil {
                await abortAdmission(
                    message:
                        "Admission was cancelled because room authority is locked."
                )
            }
            await stopOwnerRoute(removeRendezvous: true)
            invite = nil
            emit(.inviteChanged(nil))
            return
        }
        let isLeader =
            context.signedMembership.snapshot.leaderParticipantID
                == localParticipant.participantID
        if isLeader {
            if activeBootstrap != nil {
                pendingInviteRefresh =
                    pendingInviteRefresh
                        || refreshInviteIfLocalLeader
                return
            }
            if refreshInviteIfLocalLeader || !isRendezvousRouteActive {
                try await refreshLeaderInvite()
            }
        } else {
            pendingInviteRefresh = false
            if activeBootstrap != nil {
                await abortAdmission(
                    message:
                        "Admission was cancelled because room leadership changed."
                )
            }
            await stopOwnerRoute(removeRendezvous: true)
            invite = nil
            emit(.inviteChanged(nil))
        }
    }

    /// Rotates the encrypted invite route when the requirement changes so
    /// every candidate sees an authenticated requirement bit before hello.
    func updateRequiredAccessWord(_ value: String?) async throws {
        guard roomAvailability == .active else {
            throw MeshParticipantBootstrapError.roomAuthorityUnavailable
        }
        let wasRequired = requiredAccessWord != nil
        setRequiredAccessWord(value)
        guard didStart,
              wasRequired != (requiredAccessWord != nil),
              committedContext?.signedMembership.snapshot
                .leaderParticipantID
                == localParticipant.participantID
        else { return }
        if activeBootstrap != nil {
            pendingInviteRefresh = true
            return
        }
        try await refreshLeaderInvite()
    }

    /// Explicit New Invite action. Rotation is queued while an admission owns
    /// the rendezvous so an approved candidate is never stranded mid-flight.
    func refreshInvite() async throws {
        guard roomAvailability == .active else {
            throw MeshParticipantBootstrapError.roomAuthorityUnavailable
        }
        guard committedContext?.signedMembership.snapshot
            .leaderParticipantID == localParticipant.participantID
        else {
            throw MeshParticipantBootstrapError.invalidRole
        }
        if activeBootstrap != nil {
            pendingInviteRefresh = true
            return
        }
        try await refreshLeaderInvite()
    }

    /// Resumes a candidate that paused after its signed descriptor announced
    /// that the room requires an Access Word.
    func provideAccessWord(_ value: String) async throws {
        guard case let .candidate(invite, route, _) = entry else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        guard activeBootstrap == nil else {
            throw MeshParticipantEncryptedRendezvousError.alreadyStarted
        }
        let normalized = Self.normalizedAccessWord(value)
        guard normalized != nil else {
            throw MeshParticipantBootstrapError.invalidAccessWord
        }
        entry = .candidate(
            invite: invite,
            route: route,
            accessWord: normalized
        )
        guard let proof = candidateRendezvousProof else { return }
        try await beginCandidateAdmission(
            invite: invite,
            accessWord: normalized,
            proof: proof
        )
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        didStart = false
        timeoutTask?.cancel()
        timeoutTask = nil
        bootstrapTask?.cancel()
        bootstrapTask = nil
        rendezvousTask?.cancel()
        rendezvousTask = nil
        await activeBootstrap?.close()
        activeBootstrap = nil
        if isRendezvousRouteActive {
            isRendezvousRouteActive = false
            switch entry {
            case let .creator(route):
                await route.stop(true)
            case let .candidate(_, route, _):
                await route.stop()
            }
        }
        await runtimeBootstrapRoute.finish()
        await peerLinks.close()
        setPhase(.closed)
        emit(.closed)
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll(keepingCapacity: false)
    }

    // MARK: - Rendezvous

    private func listen(to route: MeshParticipantRoomOwnerRoute) {
        rendezvousTask?.cancel()
        rendezvousTask = Task { [weak self] in
            let stream = await route.events()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handleOwnerEvent(event)
            }
        }
    }

    private func listen(to route: MeshParticipantRoomCandidateRoute) {
        rendezvousTask?.cancel()
        rendezvousTask = Task { [weak self] in
            let stream = await route.events()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handleCandidateEvent(event)
            }
        }
    }

    private func handleOwnerEvent(
        _ event: MeshParticipantEncryptedRendezvousEvent
    ) async {
        await finishCompletedAdmissionIfNeeded()
        guard !Task.isCancelled else { return }
        switch event {
        case let .routeReady(participantID, proof):
            guard activeBootstrap == nil else {
                await currentOwnerRoute?.closeRoute(
                    participantID,
                    "v3-room-busy"
                )
                return
            }
            do {
                try await beginMemberAdmission(
                    candidateID: participantID,
                    proof: proof
                )
            } catch {
                await currentOwnerRoute?.closeRoute(
                    participantID,
                    "v3-admission-rejected"
                )
                emit(.admissionFailed(error.localizedDescription))
            }

        case let .envelope(envelope, participantID):
            guard participantID == activeCandidateID else {
                if let activeBootstrap,
                   case let .hello(hello) = envelope {
                    do {
                        try await activeBootstrap.rejectConcurrentJoin(
                            hello,
                            authenticatedRendezvousProof:
                                hello.hello.rendezvousProof,
                            from: participantID,
                            at: try now()
                        )
                    } catch {
                        // A malformed or undeliverable competing route is
                        // isolated from the active admission transaction.
                    }
                }
                await currentOwnerRoute?.closeRoute(
                    participantID,
                    "v3-room-busy"
                )
                return
            }
            guard let activeBootstrap else {
                await currentOwnerRoute?.closeRoute(
                    participantID,
                    "v3-admission-unavailable"
                )
                return
            }
            do {
                try await activeBootstrap.receive(
                    envelope,
                    from: participantID,
                    at: try now()
                )
            } catch {
                await abortAdmission(message: error.localizedDescription)
            }

        case let .routeClosed(participantID, reason):
            if participantID == activeCandidateID {
                await abortAdmission(
                    message: reason ?? "The admission route closed."
                )
            }

        case let .failed(message):
            invite = nil
            emit(.inviteChanged(nil))
            if activeBootstrap != nil {
                await abortAdmission(message: message)
            } else {
                emit(.inviteRefreshFailed(message))
            }

        case .stopped:
            break
        }
    }

    private func handleCandidateEvent(
        _ event: MeshParticipantEncryptedRendezvousEvent
    ) async {
        do {
            switch event {
            case let .routeReady(_, proof):
                guard case let .candidate(invite, route, accessWord) = entry,
                      activeBootstrap == nil else { return }
                let requiresWord =
                    await route.accessWordRequired() ?? false
                candidateAccessWordRequired = requiresWord
                candidateRendezvousProof = proof
                emit(.accessWordRequirementChanged(requiresWord))
                scheduleTimeout()
                if requiresWord,
                   Self.normalizedAccessWord(accessWord) == nil {
                    setPhase(.accessWordRequired)
                    return
                }
                try await beginCandidateAdmission(
                    invite: invite,
                    accessWord: accessWord,
                    proof: proof
                )
            case let .envelope(envelope, participantID):
                guard let activeBootstrap else {
                    throw MeshParticipantBootstrapError.missingAdmission
                }
                try await activeBootstrap.receive(
                    envelope,
                    from: participantID,
                    at: now()
                )
            case let .routeClosed(_, reason):
                await abortAdmission(
                    message: reason ?? "The admission route closed."
                )
            case let .failed(message):
                await abortAdmission(message: message)
            case .stopped:
                break
            }
        } catch {
            await abortAdmission(message: error.localizedDescription)
        }
    }

    private func beginMemberAdmission(
        candidateID: ClipLiveShareNativeV3ParticipantID,
        proof: ClipLiveShareNativeV3RendezvousProof?
    ) async throws {
        guard roomAvailability == .active else {
            throw MeshParticipantBootstrapError.roomAuthorityUnavailable
        }
        guard let context = committedContext else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        let isLeader =
            context.signedMembership.snapshot.leaderParticipantID
                == localParticipant.participantID
        guard isLeader == (proof != nil) else {
            throw MeshParticipantBootstrapError.missingRendezvousProof
        }
        let coordinator = try MeshParticipantBootstrapCoordinator(
            memberContext: context,
            rendezvousProof: proof,
            availability: roomAvailability,
            requiredAccessWord: isLeader ? requiredAccessWord : nil,
            send: { [weak self] envelope, participantID in
                guard let self else { throw CancellationError() }
                try await self.routeBootstrap(envelope, to: participantID)
            },
            pairHooks: peerLinks.pairHooks
        )
        activeCandidateID = candidateID
        try await install(coordinator)
        scheduleTimeout()
    }

    private func beginCandidateAdmission(
        invite: ClipLiveShareNativeV3Invite,
        accessWord: String?,
        proof: ClipLiveShareNativeV3RendezvousProof
    ) async throws {
        let coordinator = try MeshParticipantBootstrapCoordinator(
            candidateSessionID: invite.sessionID,
            candidate: localParticipant,
            candidateSigner: localSigner,
            admissionLeaderParticipantID:
                invite.leaderParticipantID,
            expectedFoundingCreatorIdentity:
                invite.foundingCreatorIdentity,
            rendezvousProof: proof,
            admissionPolicy: admissionPolicy,
            accessWord: accessWord,
            send: { [weak self] envelope, participantID in
                guard let self else {
                    throw CancellationError()
                }
                try await self.routeBootstrap(
                    envelope,
                    to: participantID
                )
            },
            pairHooks: peerLinks.pairHooks
        )
        activeCandidateID = localParticipant.participantID
        try await install(coordinator)
        try await coordinator.requestJoin(at: now())
    }

    private func install(
        _ coordinator: MeshParticipantBootstrapCoordinator
    ) async throws {
        activeBootstrap = coordinator
        await peerLinks.bind(coordinator) { [weak self] message in
            Task { await self?.abortAdmission(message: message) }
        }
        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            let stream = await coordinator.events()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handleBootstrapEvent(event)
            }
        }
    }

    private func handleBootstrapEvent(
        _ event: MeshParticipantBootstrapEvent
    ) async {
        guard activeBootstrap != nil else { return }
        switch event {
        case let .phaseChanged(next):
            switch next {
            case .awaitingApproval:
                setPhase(.awaitingApproval)
            case .provingIdentity, .preparingPeerLinks,
                 .awaitingMembershipCommit:
                setPhase(.preparingPeerLinks)
            case let .rejected(reason):
                if committedContext == nil {
                    setPhase(.rejected(reason))
                }
            case .timedOut:
                if committedContext == nil {
                    setPhase(.timedOut)
                }
            case .ready:
                setPhase(.active)
            case .idle, .awaitingAdmission, .closed:
                break
            }
        case let .candidateDiscovered(participant):
            pendingAdmission = participant
            activeCandidateID = participant.participantID
            emit(.admissionRequested(participant))
        case let .provisionalPairReady(pair):
            activeAdmissionDigest = pair.admissionDigest
        case let .launchReady(context):
            await completeLaunch(context)
        case let .membershipUpdateReady(context):
            await completeMembershipUpdate(context)
        case let .rejected(reason):
            emit(.rejected(reason))
            await finishRejectedAdmission(reason)
        case let .failed(message):
            await abortAdmission(message: message)
        }
    }

    // MARK: - Routing

    private func routeBootstrap(
        _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
        to destination: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        if case let .candidate(invite, route, _) = entry,
           committedContext == nil {
            try await route.send(envelope, invite.leaderParticipantID)
            return
        }
        guard let context = committedContext else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        let membership = context.signedMembership.snapshot
        let isLeader =
            membership.leaderParticipantID
                == localParticipant.participantID

        if isLeader {
            if !membership.participantIDs.contains(destination) {
                guard let route = currentOwnerRoute else {
                    throw MeshParticipantEncryptedRendezvousError.notStarted
                }
                try await route.send(envelope, destination)
                return
            }
            if case let .admitted(membership) = envelope {
                try await peerLinks.sendMembership(
                    membership,
                    destination
                )
                return
            }
            let forward = try makeForward(
                envelope,
                destination: destination
            )
            try await peerLinks.sendForward(forward, destination)
            return
        }

        let leader = membership.leaderParticipantID
        let forward = try makeForward(
            envelope,
            destination: destination
        )
        try await peerLinks.sendForward(forward, leader)
    }

    private func makeForward(
        _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
        destination: ClipLiveShareNativeV3ParticipantID
    ) throws -> ClipLiveShareNativeV3BootstrapForward {
        guard let context = committedContext else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        let sessionID = context.signedMembership.snapshot.sessionID
        let digest: ClipLiveShareNativeDigest
        let origin: ClipLiveShareNativeV3ParticipantID
        let target: ClipLiveShareNativeV3ParticipantID
        switch envelope {
        case let .hello(value):
            digest = value.hello.digest
            origin = value.hello.participantID
            target = destination
        case let .provisionalAdmission(value):
            digest = value.admission.digest
            origin = value.admission.currentMembership.snapshot
                .leaderParticipantID
            target = destination
        case let .relay(value):
            digest = value.admissionDigest
            origin = value.originParticipantID
            target = value.targetParticipantID
        case let .linkReadiness(value):
            digest = value.readiness.admissionDigest
            origin = value.readiness.reporterParticipantID
            target = activeCandidateID ?? destination
        case let .admitted(value):
            digest = value.snapshot.digest
            origin = value.snapshot.leaderParticipantID
            target = destination
        case let .rejected(value):
            digest = activeAdmissionDigest
                ?? value.rendezvousProof.digest
            origin = context.signedMembership.snapshot.leaderParticipantID
            target = destination
        }
        return try .init(
            sessionID: sessionID,
            admissionDigest: digest,
            originParticipantID: origin,
            targetParticipantID: target,
            envelope: envelope
        )
    }

    // MARK: - Lifecycle

    private var currentOwnerRoute: MeshParticipantRoomOwnerRoute? {
        guard case let .creator(route) = entry else { return nil }
        return route
    }

    private func refreshLeaderInvite() async throws {
        guard roomAvailability == .active else {
            throw MeshParticipantBootstrapError.roomAuthorityUnavailable
        }
        guard let context = committedContext else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        invite = nil
        emit(.inviteChanged(nil))
        await stopOwnerRoute(removeRendezvous: true)
        do {
            let route = try routeFactory.makeOwner(.init(
                endpoint: endpoint,
                sessionID:
                    context.signedMembership.snapshot.sessionID,
                foundingCreatorIdentity:
                    context.expectedFoundingCreatorIdentity,
                leaderParticipantID:
                    localParticipant.participantID,
                leaderSigner: localSigner,
                accessWordRequired: requiredAccessWord != nil
            ))
            entry = .creator(route)
            listen(to: route)
            try await route.start()
            isRendezvousRouteActive = true
            invite = route.invite
            emit(.inviteChanged(route.invite))
        } catch {
            isRendezvousRouteActive = false
            rendezvousTask?.cancel()
            rendezvousTask = nil
            invite = nil
            emit(.inviteChanged(nil))
            emit(.inviteRefreshFailed(error.localizedDescription))
            throw error
        }
    }

    private func stopOwnerRoute(removeRendezvous: Bool) async {
        guard isRendezvousRouteActive,
              case let .creator(route) = entry else { return }
        isRendezvousRouteActive = false
        rendezvousTask?.cancel()
        rendezvousTask = nil
        await route.stop(removeRendezvous)
    }

    private func stopCandidateRoute() async {
        guard isRendezvousRouteActive,
              case let .candidate(_, route, _) = entry else { return }
        isRendezvousRouteActive = false
        rendezvousTask?.cancel()
        rendezvousTask = nil
        await route.stop()
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, timeoutSleeper] in
            do {
                try await timeoutSleeper.sleep(
                    for: .milliseconds(
                        ClipLiveShareNativeV3Bootstrap
                            .maximumLifetimeMilliseconds
                    )
                )
                guard let self else { return }
                try await self.expireAdmission(at: self.now())
            } catch is CancellationError {
                return
            } catch {
                await self?.emitFailure(error.localizedDescription)
            }
        }
    }

    private func timeoutAdmission() async {
        emit(.rejected(.timedOut))
        if let candidate = activeCandidateID,
           let route = currentOwnerRoute {
            await route.closeRoute(candidate, "timed-out")
        } else {
            await stopCandidateRoute()
        }
        await finishAdmission()
        if committedContext != nil {
            setPhase(.active)
        } else {
            setPhase(.timedOut)
        }
    }

    /// Bootstrap publishes its ready context before the surrounding stream
    /// task necessarily gets a turn. Checking at the next owner event prevents
    /// a rapid sequential join from observing the prior transaction as busy.
    private func finishCompletedAdmissionIfNeeded() async {
        guard let activeBootstrap,
              let context = await activeBootstrap.launchContext()
        else { return }
        if committedContext == nil {
            await completeLaunch(context)
        } else {
            await completeMembershipUpdate(context)
        }
    }

    private func finishRejectedTransactionIfNeeded(
        _ transaction: MeshParticipantBootstrapCoordinator
    ) async {
        guard activeBootstrap === transaction else { return }
        let transactionPhase = await transaction.snapshot().phase
        let reason: ClipLiveShareNativeV3BootstrapRejectionReason
        switch transactionPhase {
        case let .rejected(value):
            reason = value
        case .timedOut:
            reason = .timedOut
        default:
            return
        }
        emit(.rejected(reason))
        await finishRejectedAdmission(reason)
    }

    private func completeLaunch(
        _ context: MeshParticipantBootstrapLaunchContext
    ) async {
        guard activeBootstrap != nil else { return }
        committedContext = context
        emitActivation(context)
        await stopCandidateRoute()
        await finishAdmission()
        setPhase(.active)
    }

    private func completeMembershipUpdate(
        _ context: MeshParticipantBootstrapLaunchContext
    ) async {
        guard activeBootstrap != nil else { return }
        guard roomAvailability == .active else {
            await abortAdmission(
                message:
                    "Admission was cancelled because room authority is locked."
            )
            return
        }
        committedContext = context
        emit(.membershipUpdateReady(context))
        await finishAdmission()
        setPhase(.active)
    }

    private func finishRejectedAdmission(
        _ reason: ClipLiveShareNativeV3BootstrapRejectionReason
    ) async {
        if let candidate = activeCandidateID,
           let route = currentOwnerRoute {
            await route.closeRoute(candidate, reason.rawValue)
        } else {
            await stopCandidateRoute()
        }
        await finishAdmission()
        if committedContext != nil {
            setPhase(.active)
        } else {
            setPhase(
                reason == .timedOut
                    ? .timedOut
                    : .rejected(reason)
            )
        }
    }

    private func finishAdmission() async {
        timeoutTask?.cancel()
        timeoutTask = nil
        bootstrapTask?.cancel()
        bootstrapTask = nil
        await activeBootstrap?.close()
        activeBootstrap = nil
        activeCandidateID = nil
        activeAdmissionDigest = nil
        pendingAdmission = nil
        candidateRendezvousProof = nil

        let shouldRefresh =
            pendingInviteRefresh
                && !isClosed
                && roomAvailability == .active
                && committedContext?.signedMembership.snapshot
                    .leaderParticipantID
                    == localParticipant.participantID
        pendingInviteRefresh = false
        if shouldRefresh {
            do {
                try await refreshLeaderInvite()
            } catch {
                // The room remains live without an invite. The UI receives a
                // scoped failure and may offer New Invite again.
            }
        }
    }

    private func abortAdmission(message: String) async {
        guard activeBootstrap != nil
                || activeCandidateID != nil
                || candidateRendezvousProof != nil
        else {
            if committedContext == nil {
                emitFailure(message)
            } else {
                emit(.admissionFailed(message))
            }
            return
        }
        if let candidate = activeCandidateID,
           let route = currentOwnerRoute {
            await route.closeRoute(candidate, "v3-admission-aborted")
        } else {
            await stopCandidateRoute()
        }
        await finishAdmission()
        if committedContext != nil {
            setPhase(.active)
            emit(.admissionFailed(message))
        } else {
            emitFailure(message)
        }
    }

    private func emitActivation(
        _ context: MeshParticipantBootstrapLaunchContext
    ) {
        emit(.activationReady(.init(
            context: .init(context),
            bootstrap: runtimeBootstrapRoute,
            media: peerLinks.media
        )))
    }

    private func failAndClose(_ message: String) async {
        emitFailure(message)
        await close()
    }

    private func emitFailure(_ message: String) {
        setPhase(.failed(message))
        emit(.failed(message))
    }

    private func setPhase(
        _ next: MeshParticipantRoomConnectionPhase
    ) {
        guard phase != next else { return }
        phase = next
        emit(.phaseChanged(next))
    }

    private func emit(_ event: MeshParticipantRoomConnectionEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

/// Runtime-facing bootstrap path for the rare period where direct control is
/// not open yet. It belongs to the v3 room session and carries no legacy
/// owner/candidate message vocabulary.
private actor MeshParticipantRoomBootstrapRoute:
    MeshParticipantBootstrapRouting
{
    typealias Outbound = @Sendable (
        ClipLiveShareNativeV3BootstrapEnvelope,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void

    private var outbound: Outbound?
    private var isClosed = false
    private var continuations: [
        UUID: AsyncStream<MeshParticipantBootstrapRouteEvent>.Continuation
    ] = [:]

    func setOutbound(_ outbound: @escaping Outbound) {
        guard !isClosed else { return }
        self.outbound = outbound
    }

    func events() -> AsyncStream<MeshParticipantBootstrapRouteEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: MeshParticipantBootstrapRouteEvent.self,
            bufferingPolicy: .bufferingNewest(64)
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

    func send(
        _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        guard !isClosed, let outbound else {
            throw MeshParticipantBootstrapError.closed
        }
        try await outbound(envelope, participantID)
    }

    func close() {
        finish()
    }

    func finish() {
        guard !isClosed else { return }
        isClosed = true
        outbound = nil
        for continuation in continuations.values {
            continuation.yield(.closed)
            continuation.finish()
        }
        continuations.removeAll(keepingCapacity: false)
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
