import ClipLiveShare
import Foundation

/// Fully authenticated state handed from native-v3 admission to the symmetric
/// participant runtime. The same value is used for a candidate's first launch
/// and an existing member's transactional membership update.
struct MeshParticipantBootstrapLaunchContext: Sendable {
    let localParticipantID: ClipLiveShareNativeV3ParticipantID
    let localIdentitySigner: any ClipLiveShareIdentitySigner
    let signedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot
    let authorityChain: ClipLiveShareNativeV3RoomAuthorityChain
    let expectedFoundingCreatorIdentity: ClipLiveShareIdentityPublicKey
    let bootstrapAdmissionDigests:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeDigest]
    let verifiedPeerTransportNonces:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3TransportNonce]
    let admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy
}

extension MeshParticipantLaunchContext {
    init(_ bootstrap: MeshParticipantBootstrapLaunchContext) {
        self.init(
            localParticipantID: bootstrap.localParticipantID,
            localIdentitySigner: bootstrap.localIdentitySigner,
            signedMembership: bootstrap.signedMembership,
            authorityChain: bootstrap.authorityChain,
            expectedFoundingCreatorIdentity:
                bootstrap.expectedFoundingCreatorIdentity,
            bootstrapAdmissionDigests:
                bootstrap.bootstrapAdmissionDigests,
            verifiedPeerTransportNonces:
                bootstrap.verifiedPeerTransportNonces,
            admissionPolicy: bootstrap.admissionPolicy
        )
    }
}

enum MeshParticipantBootstrapRoomAvailability: Equatable, Sendable {
    case active
    case leaderlessLocked
    case ended
}

enum MeshParticipantBootstrapPhase: Equatable, Sendable {
    /// No signed native-v3 join request has been sent or accepted.
    case idle
    case awaitingAdmission
    case awaitingApproval
    case provingIdentity
    case preparingPeerLinks
    case awaitingMembershipCommit
    case ready
    case rejected(ClipLiveShareNativeV3BootstrapRejectionReason)
    case timedOut
    case closed
}

enum MeshParticipantBootstrapError: Error, Equatable, LocalizedError, Sendable {
    case closed
    case invalidRole
    case unexpectedEnvelope
    case unexpectedSender
    case joinNotRequested
    case missingRendezvousProof
    case invalidAccessWord
    case conflictingAdmission
    case missingAdmission
    case invalidPair
    case possessionNotVerified
    case peerLinkNotReady
    case membershipAlreadyCommitted
    case roomAuthorityUnavailable
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .closed:
            "The native-v3 bootstrap transaction is closed."
        case .invalidRole:
            "This participant cannot perform that bootstrap operation."
        case .unexpectedEnvelope:
            "The native-v3 bootstrap message is not valid in this phase."
        case .unexpectedSender:
            "The native-v3 bootstrap message came from an unexpected route."
        case .joinNotRequested:
            "Native-v3 admission cannot start before an explicit signed hello."
        case .missingRendezvousProof:
            "The secure native-v3 rendezvous proof is unavailable."
        case .invalidAccessWord:
            "Enter the room's Access Word before joining."
        case .conflictingAdmission:
            "A different native-v3 admission is already in progress."
        case .missingAdmission:
            "The native-v3 provisional admission is missing."
        case .invalidPair:
            "The bootstrap relay is not scoped to a candidate/member pair."
        case .possessionNotVerified:
            "The peer must prove possession of its identity before link preparation."
        case .peerLinkNotReady:
            "The direct peer link is not ready."
        case .membershipAlreadyCommitted:
            "This bootstrap membership was already committed."
        case .roomAuthorityUnavailable:
            "Room membership is locked until leadership quorum is restored."
        case let .sendFailed(message):
            "Native-v3 bootstrap delivery failed: \(message)"
        }
    }
}

struct MeshParticipantBootstrapProvisionalPair: Sendable {
    let localParticipantID: ClipLiveShareNativeV3ParticipantID
    let remoteParticipantID: ClipLiveShareNativeV3ParticipantID
    let admission: ClipLiveShareSignedNativeV3ProvisionalAdmission
    let transportNonce: ClipLiveShareNativeV3TransportNonce
    let admissionDigest: ClipLiveShareNativeDigest
}

struct MeshParticipantBootstrapPairHooks: Sendable {
    typealias Prepare = @Sendable (
        MeshParticipantBootstrapProvisionalPair
    ) async throws -> Void
    typealias ReceiveRelay = @Sendable (
        ClipLiveShareNativeV3BootstrapRelayPayload,
        ClipLiveShareNativeV3ParticipantID,
        MeshParticipantBootstrapProvisionalPair
    ) async throws -> Void
    typealias Abort = @Sendable (
        ClipLiveShareNativeV3ParticipantID
    ) async -> Void
    /// Atomically removes the provisional quarantine after the complete
    /// leader-signed membership has been verified. Production supplies the
    /// same peer-link manager that is handed to `MeshParticipantRuntime`, so
    /// this is a control-path takeover rather than a second connection.
    typealias Promote = @Sendable (
        MeshParticipantBootstrapLaunchContext
    ) async throws -> Void

    var prepare: Prepare
    var receiveRelay: ReceiveRelay
    var abort: Abort
    var promote: Promote

    init(
        prepare: @escaping Prepare = { _ in },
        receiveRelay: @escaping ReceiveRelay = { _, _, _ in },
        abort: @escaping Abort = { _ in },
        promote: @escaping Promote = { _ in }
    ) {
        self.prepare = prepare
        self.receiveRelay = receiveRelay
        self.abort = abort
        self.promote = promote
    }
}

enum MeshParticipantBootstrapEvent: Sendable {
    case phaseChanged(MeshParticipantBootstrapPhase)
    case candidateDiscovered(ClipLiveShareNativeV3Participant)
    case provisionalPairReady(MeshParticipantBootstrapProvisionalPair)
    case launchReady(MeshParticipantBootstrapLaunchContext)
    case membershipUpdateReady(MeshParticipantBootstrapLaunchContext)
    case rejected(ClipLiveShareNativeV3BootstrapRejectionReason)
    case failed(String)
}

struct MeshParticipantBootstrapSnapshot: Equatable, Sendable {
    let phase: MeshParticipantBootstrapPhase
    let candidateParticipantID: ClipLiveShareNativeV3ParticipantID?
    let verifiedPeerParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>
    let readyPeerLinkKeys: Set<ClipLiveShareNativeV3PeerLinkKey>
    let readinessReporterParticipantIDs:
        Set<ClipLiveShareNativeV3ParticipantID>
    let hasCommittedMembership: Bool
}

/// One authenticated native-v3 admission transaction.
///
/// The secure invite/signaling route only transports these typed messages.
/// Room admission begins with a signed native-v3 hello and requires explicit
/// leader approval. Pair links created here are provisional and quarantined by
/// the injected hooks: SDP/ICE and possession messages may flow, but room
/// control and media publication are forbidden until the leader's complete
/// membership snapshot is committed.
actor MeshParticipantBootstrapCoordinator {
    typealias RendezvousSend = @Sendable (
        ClipLiveShareNativeV3BootstrapEnvelope,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    typealias NonceGenerator = @Sendable ()
        -> ClipLiveShareNativeV3TransportNonce
    typealias ChallengeGenerator = @Sendable () -> Data

    private enum Role: Sendable {
        case member(MeshParticipantBootstrapLaunchContext)
        case candidate
    }

    private struct ChallengeDirection: Hashable, Sendable {
        let verifier: ClipLiveShareNativeV3ParticipantID
        let prover: ClipLiveShareNativeV3ParticipantID
    }

    private let role: Role
    private let sessionID: ClipLiveShareSessionID
    private let localParticipant: ClipLiveShareNativeV3Participant
    private let localSigner: any ClipLiveShareIdentitySigner
    private let expectedFoundingCreatorIdentity:
        ClipLiveShareIdentityPublicKey
    private let rendezvousProof: ClipLiveShareNativeV3RendezvousProof?
    private let admissionLeaderParticipantID:
        ClipLiveShareNativeV3ParticipantID
    private let admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy
    /// Present only on the admission leader. Existing members never receive
    /// the human-readable value or re-evaluate the leader's decision.
    private let requiredAccessWord: String?
    /// Candidate-side input used to build the route-bound v3 proof.
    private let candidateAccessWord: String?
    private let sendRendezvous: RendezvousSend
    private let pairHooks: MeshParticipantBootstrapPairHooks
    private let nonceGenerator: NonceGenerator
    private let challengeGenerator: ChallengeGenerator

    private var availability: MeshParticipantBootstrapRoomAvailability
    private var phase: MeshParticipantBootstrapPhase = .idle
    private var signedHello: ClipLiveShareSignedNativeV3BootstrapHello?
    private var admission:
        ClipLiveShareSignedNativeV3ProvisionalAdmission?
    private var issuedChallenges:
        [ChallengeDirection: ClipLiveShareNativeV3PossessionChallenge] = [:]
    private var pairNonces:
        [ClipLiveShareNativeV3ParticipantID:
            ClipLiveShareNativeV3TransportNonce] = [:]
    private var verifiedPeers:
        Set<ClipLiveShareNativeV3ParticipantID> = []
    private var preparedPeers:
        Set<ClipLiveShareNativeV3ParticipantID> = []
    private var readyPeerLinkKeys:
        Set<ClipLiveShareNativeV3PeerLinkKey> = []
    private var readinessByReporter:
        [ClipLiveShareNativeV3ParticipantID:
            ClipLiveShareSignedNativeV3BootstrapLinkReadiness] = [:]
    private var localReadinessSent = false
    private var completedContext: MeshParticipantBootstrapLaunchContext?
    private var committedMembership = false
    private var continuations:
        [UUID: AsyncStream<MeshParticipantBootstrapEvent>.Continuation] = [:]

    init(
        memberContext: MeshParticipantBootstrapLaunchContext,
        rendezvousProof: ClipLiveShareNativeV3RendezvousProof? = nil,
        availability: MeshParticipantBootstrapRoomAvailability = .active,
        requiredAccessWord: String? = nil,
        send: @escaping RendezvousSend,
        pairHooks: MeshParticipantBootstrapPairHooks = .init(),
        nonceGenerator: @escaping NonceGenerator = {
            try! ClipLiveShareNativeV3TransportNonce(
                bytes: nativeBootstrapRandomData(
                    count: ClipLiveShareNativeV3.transportNonceByteCount
                )
            )
        },
        challengeGenerator: @escaping ChallengeGenerator = {
            nativeBootstrapRandomData(
                count: ClipLiveShareNativeV3.possessionChallengeByteCount
            )
        }
    ) throws {
        role = .member(memberContext)
        sessionID = memberContext.signedMembership.snapshot.sessionID
        guard let participant =
            memberContext.signedMembership.snapshot.participants.first(where: {
                $0.participantID == memberContext.localParticipantID
            })
        else {
            throw MeshParticipantRuntimeError.localParticipantMissing
        }
        guard
            participant.identity
                == memberContext.localIdentitySigner.publicKey
        else {
            throw MeshParticipantRuntimeError.localIdentityMismatch
        }
        localParticipant = participant
        localSigner = memberContext.localIdentitySigner
        expectedFoundingCreatorIdentity =
            memberContext.expectedFoundingCreatorIdentity
        self.rendezvousProof = rendezvousProof
        admissionLeaderParticipantID =
            memberContext.signedMembership.snapshot.leaderParticipantID
        guard
            participant.participantID != admissionLeaderParticipantID
                || rendezvousProof != nil
        else {
            throw MeshParticipantBootstrapError.missingRendezvousProof
        }
        admissionPolicy = memberContext.admissionPolicy
        self.requiredAccessWord = requiredAccessWord
            .map(ClipLiveShareNativeV3AccessWordProof.normalize)
            .flatMap { $0.isEmpty ? nil : $0 }
        candidateAccessWord = nil
        self.availability = availability
        sendRendezvous = send
        self.pairHooks = pairHooks
        self.nonceGenerator = nonceGenerator
        self.challengeGenerator = challengeGenerator
    }

    init(
        candidateSessionID: ClipLiveShareSessionID,
        candidate: ClipLiveShareNativeV3Participant,
        candidateSigner: any ClipLiveShareIdentitySigner,
        admissionLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
        expectedFoundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
        rendezvousProof: ClipLiveShareNativeV3RendezvousProof,
        admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy = .productDefault,
        accessWord: String? = nil,
        send: @escaping RendezvousSend,
        pairHooks: MeshParticipantBootstrapPairHooks = .init(),
        nonceGenerator: @escaping NonceGenerator = {
            try! ClipLiveShareNativeV3TransportNonce(
                bytes: nativeBootstrapRandomData(
                    count: ClipLiveShareNativeV3.transportNonceByteCount
                )
            )
        },
        challengeGenerator: @escaping ChallengeGenerator = {
            nativeBootstrapRandomData(
                count: ClipLiveShareNativeV3.possessionChallengeByteCount
            )
        }
    ) throws {
        guard candidate.identity == candidateSigner.publicKey else {
            throw MeshParticipantRuntimeError.localIdentityMismatch
        }
        role = .candidate
        sessionID = candidateSessionID
        localParticipant = candidate
        localSigner = candidateSigner
        self.expectedFoundingCreatorIdentity =
            expectedFoundingCreatorIdentity
        self.rendezvousProof = rendezvousProof
        self.admissionLeaderParticipantID = admissionLeaderParticipantID
        self.admissionPolicy = admissionPolicy
        requiredAccessWord = nil
        candidateAccessWord = accessWord
            .map(ClipLiveShareNativeV3AccessWordProof.normalize)
            .flatMap { $0.isEmpty ? nil : $0 }
        availability = .active
        sendRendezvous = send
        self.pairHooks = pairHooks
        self.nonceGenerator = nonceGenerator
        self.challengeGenerator = challengeGenerator
    }

    static func creatorGenesis(
        sessionID: ClipLiveShareSessionID,
        creator: ClipLiveShareNativeV3Participant,
        creatorSigner: any ClipLiveShareIdentitySigner,
        admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy = .productDefault,
        at now: ClipLiveShareNativeTimestamp
    ) throws -> MeshParticipantBootstrapLaunchContext {
        guard creator.identity == creatorSigner.publicKey else {
            throw ClipLiveShareNativeV3Error.identityMismatch
        }
        let revision = try ClipLiveShareNativeV3MembershipRevision(rawValue: 1)
        let credential = try ClipLiveShareNativeV3MembershipCredential(
            sessionID: sessionID,
            leaderParticipantID: creator.participantID,
            leaderIdentity: creator.identity,
            participant: creator,
            membershipRevision: revision,
            issuedAt: now,
            expiresAt: now.adding(milliseconds: 180_000)
        )
        let signedCredential =
            try ClipLiveShareSignedNativeV3MembershipCredential(
                signing: credential,
                with: creatorSigner
            )
        let snapshot = try ClipLiveShareNativeV3MembershipSnapshot(
            sessionID: sessionID,
            leaderParticipantID: creator.participantID,
            leaderIdentity: creator.identity,
            membershipRevision: revision,
            credentials: [signedCredential],
            issuedAt: now,
            expiresAt: now.adding(milliseconds: 120_000),
            maximumParticipants: admissionPolicy.maximumParticipants
        )
        let signedMembership =
            try ClipLiveShareSignedNativeV3MembershipSnapshot(
                signing: snapshot,
                with: creatorSigner
            )
        let authority = try ClipLiveShareNativeV3RoomAuthorityChain(
            foundingCreatorParticipantID: creator.participantID,
            foundingCreatorIdentity: creator.identity,
            genesisMembership: signedMembership,
            checkpoints: []
        )
        return MeshParticipantBootstrapLaunchContext(
            localParticipantID: creator.participantID,
            localIdentitySigner: creatorSigner,
            signedMembership: signedMembership,
            authorityChain: authority,
            expectedFoundingCreatorIdentity: creator.identity,
            bootstrapAdmissionDigests: [:],
            verifiedPeerTransportNonces: [:],
            admissionPolicy: admissionPolicy
        )
    }

    func events() -> AsyncStream<MeshParticipantBootstrapEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: MeshParticipantBootstrapEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    func snapshot() -> MeshParticipantBootstrapSnapshot {
        MeshParticipantBootstrapSnapshot(
            phase: phase,
            candidateParticipantID:
                admission?.admission.candidateParticipantID
                    ?? signedHello?.hello.participantID,
            verifiedPeerParticipantIDs: verifiedPeers,
            readyPeerLinkKeys: readyPeerLinkKeys,
            readinessReporterParticipantIDs: Set(readinessByReporter.keys),
            hasCommittedMembership: committedMembership
        )
    }

    func launchContext() -> MeshParticipantBootstrapLaunchContext? {
        completedContext
    }

    /// Membership delivery shares the runtime control channel with ordinary
    /// renewal, removal and leadership snapshots. Only the exact participant
    /// set proposed by this admission may be consumed by bootstrap.
    func canConsumeCommittedMembership(
        _ membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
        from sender: ClipLiveShareNativeV3ParticipantID
    ) -> Bool {
        guard
            phase != .closed,
            completedContext == nil,
            let admission,
            sender == admissionLeaderParticipantID,
            membership.snapshot.sessionID == sessionID,
            membership.snapshot.leaderParticipantID
                == admissionLeaderParticipantID,
            membership.snapshot.participantIDs
                == Set(admission.admission.proposedParticipantIDs),
            membership.snapshot.membershipRevision
                > admission.admission.currentMembership.snapshot
                    .membershipRevision
        else { return false }
        return true
    }

    /// Candidate-only explicit join. Until called, the v3 rendezvous sends
    /// nothing and cannot create a provisional peer link.
    func requestJoin(at now: ClipLiveShareNativeTimestamp) async throws {
        try requireOpen()
        guard case .candidate = role, phase == .idle else {
            throw MeshParticipantBootstrapError.invalidRole
        }
        guard let rendezvousProof else {
            throw MeshParticipantBootstrapError.missingRendezvousProof
        }
        let hello = try ClipLiveShareNativeV3BootstrapHello(
            sessionID: sessionID,
            participantID: localParticipant.participantID,
            identity: localParticipant.identity,
            displayName: localParticipant.displayName,
            capabilities: localParticipant.capabilities,
            rendezvousProof: rendezvousProof,
            accessWordProof: try candidateAccessWord.map {
                try ClipLiveShareNativeV3AccessWordProof(
                    accessWord: $0,
                    sessionID: sessionID,
                    participantID: localParticipant.participantID,
                    identity: localParticipant.identity,
                    rendezvousProof: rendezvousProof
                )
            },
            issuedAt: now,
            expiresAt: now.adding(
                milliseconds:
                    ClipLiveShareNativeV3Bootstrap.maximumLifetimeMilliseconds
            )
        )
        let signed = try ClipLiveShareSignedNativeV3BootstrapHello(
            signing: hello,
            with: localSigner
        )
        signedHello = signed
        try await send(.hello(signed), to: admissionLeaderParticipantID)
        setPhase(.awaitingAdmission)
    }

    /// Leader-only explicit approval. Receiving a valid signed hello merely
    /// exposes the candidate to the room UI; no credentials, peer links, or
    /// SDP are produced until this method is called.
    func approveAdmission(at now: ClipLiveShareNativeTimestamp) async throws {
        try requireOpen()
        guard
            isLocalLeader,
            phase == .awaitingApproval,
            let hello = signedHello,
            let rendezvousProof
        else {
            throw MeshParticipantBootstrapError.invalidRole
        }
        try hello.verify(
            expectedSessionID: sessionID,
            expectedRendezvousProof: rendezvousProof,
            at: now
        )
        let current = try requireMemberContext()
        guard current.signedMembership.snapshot.participants.count
            < admissionPolicy.maximumParticipants
        else {
            try await rejectCandidate(
                hello.hello.participantID,
                reason: .roomFull
            )
            return
        }
        switch availability {
        case .leaderlessLocked:
            try await rejectCandidate(
                hello.hello.participantID,
                reason: .roomLocked
            )
            return
        case .ended:
            try await rejectCandidate(
                hello.hello.participantID,
                reason: .roomEnded
            )
            return
        case .active:
            break
        }

        let provisional = try makeProvisionalAdmission(
            hello: hello,
            context: current,
            at: now
        )
        admission = provisional

        // Existing members receive the candidate's signed rendezvous proof
        // before the leader-signed provisional admission that binds its
        // digest. They never need to trust the rendezvous service.
        for participantID in current.signedMembership.snapshot.participantIDs
            .subtracting([localParticipant.participantID]).sorted()
        {
            try await send(.hello(hello), to: participantID)
        }
        for participantID in provisional.admission.proposedParticipantIDs
            where participantID != localParticipant.participantID
        {
            try await send(
                .provisionalAdmission(provisional),
                to: participantID
            )
        }
        try await activateProvisionalAdmission(provisional, at: now)
    }

    func receive(
        _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
        from authenticatedParticipantID:
            ClipLiveShareNativeV3ParticipantID,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        try requireOpen()
        switch envelope {
        case let .hello(hello):
            try await receiveHello(
                hello,
                from: authenticatedParticipantID,
                at: now
            )
        case let .provisionalAdmission(value):
            try await receiveProvisionalAdmission(
                value,
                from: authenticatedParticipantID,
                at: now
            )
        case let .relay(relay):
            try await receiveRelay(
                relay,
                from: authenticatedParticipantID,
                at: now
            )
        case let .linkReadiness(readiness):
            try await receiveReadiness(
                readiness,
                from: authenticatedParticipantID,
                at: now
            )
        case let .admitted(membership):
            try await receiveCommittedMembership(
                membership,
                from: authenticatedParticipantID,
                at: now
            )
        case let .rejected(rejection):
            try await receiveRejection(
                rejection,
                from: authenticatedParticipantID
            )
        }
    }

    /// Routes a provisional manager's signed SDP/ICE payload. Room state and
    /// media are intentionally not representable by the bootstrap payload.
    func relayPairPayload(
        _ payload: ClipLiveShareNativeV3BootstrapRelayPayload,
        to remoteParticipantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try requireOpen()
        guard let admission else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        try validateRequiredPair(
            payload.peerLinkKey,
            admission: admission,
            expectedPeer: remoteParticipantID
        )
        guard verifiedPeers.contains(remoteParticipantID) else {
            throw MeshParticipantBootstrapError.possessionNotVerified
        }
        switch payload {
        case .offer, .answer, .ice:
            break
        case .possessionChallenge, .possessionProof:
            throw MeshParticipantBootstrapError.unexpectedEnvelope
        }
        try await sendRelay(payload, to: remoteParticipantID)
    }

    /// Called by the provisional peer-link adapter after its reliable direct
    /// channel is open. Readiness is signed only after possession proof and all
    /// locally required candidate/member links are ready.
    func markPeerLinkReady(
        with remoteParticipantID: ClipLiveShareNativeV3ParticipantID,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        try requireOpen()
        guard let admission else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        guard
            verifiedPeers.contains(remoteParticipantID),
            preparedPeers.contains(remoteParticipantID)
        else {
            throw MeshParticipantBootstrapError.possessionNotVerified
        }
        let key = try ClipLiveShareNativeV3PeerLinkKey(
            localParticipant.participantID,
            remoteParticipantID
        )
        try validateRequiredPair(
            key,
            admission: admission,
            expectedPeer: remoteParticipantID
        )
        readyPeerLinkKeys.insert(key)
        try await sendLocalReadinessIfComplete(at: now)
    }

    func denyAdmission(
        reason: ClipLiveShareNativeV3BootstrapRejectionReason = .denied
    ) async throws {
        try requireOpen()
        guard isLocalLeader, let candidateID = signedHello?.hello.participantID
        else {
            throw MeshParticipantBootstrapError.invalidRole
        }
        try await rejectCandidate(candidateID, reason: reason)
    }

    /// Rejects a second authenticated rendezvous route while this coordinator
    /// owns the room's single bounded admission slot. The route multiplexer
    /// supplies the proof derived from that second secure transport; it is
    /// verified before a route-scoped `busy` response is emitted.
    func rejectConcurrentJoin(
        _ hello: ClipLiveShareSignedNativeV3BootstrapHello,
        authenticatedRendezvousProof:
            ClipLiveShareNativeV3RendezvousProof,
        from sender: ClipLiveShareNativeV3ParticipantID,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        try requireOpen()
        guard
            isLocalLeader,
            signedHello != nil,
            sender == hello.hello.participantID
        else {
            throw MeshParticipantBootstrapError.invalidRole
        }
        try hello.verify(
            expectedSessionID: sessionID,
            expectedRendezvousProof: authenticatedRendezvousProof,
            at: now
        )
        try await sendRejection(
            to: hello.hello.participantID,
            reason: .busy,
            rendezvousProof: authenticatedRendezvousProof
        )
    }

    func setRoomAvailability(
        _ availability: MeshParticipantBootstrapRoomAvailability
    ) {
        self.availability = availability
    }

    func expire(at now: ClipLiveShareNativeTimestamp) async throws {
        try requireOpen()
        let expiry =
            admission?.admission.expiresAt
                ?? signedHello?.hello.expiresAt
        guard let expiry, now >= expiry else { return }
        if isLocalLeader, let candidateID = signedHello?.hello.participantID {
            try await rejectCandidate(candidateID, reason: .timedOut)
        } else {
            await abortProvisionalPairs()
            setPhase(.timedOut)
            emit(.rejected(.timedOut))
        }
    }

    func close() async {
        guard phase != .closed else { return }
        if completedContext == nil {
            await abortProvisionalPairs()
        }
        setPhase(.closed)
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll(keepingCapacity: false)
    }

    // MARK: - Admission

    private var memberContext: MeshParticipantBootstrapLaunchContext? {
        guard case let .member(context) = role else { return nil }
        return context
    }

    private var isLocalLeader: Bool {
        memberContext?.signedMembership.snapshot.leaderParticipantID
            == localParticipant.participantID
    }

    private func receiveHello(
        _ hello: ClipLiveShareSignedNativeV3BootstrapHello,
        from sender: ClipLiveShareNativeV3ParticipantID,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        guard case .member = role else {
            throw MeshParticipantBootstrapError.unexpectedEnvelope
        }
        let senderIsCandidate = sender == hello.hello.participantID
        let senderIsLeader = sender == admissionLeaderParticipantID
        guard senderIsCandidate || senderIsLeader else {
            throw MeshParticipantBootstrapError.unexpectedSender
        }
        do {
            if isLocalLeader {
                guard let rendezvousProof else {
                    throw MeshParticipantBootstrapError
                        .missingRendezvousProof
                }
                try hello.verify(
                    expectedSessionID: sessionID,
                    expectedRendezvousProof: rendezvousProof,
                    at: now
                )
            } else {
                try hello.verify(
                    expectedSessionID: sessionID,
                    at: now
                )
            }
        } catch {
            if isLocalLeader, senderIsCandidate {
                try? await rejectCandidate(
                    hello.hello.participantID,
                    reason: .incompatible
                )
            }
            throw error
        }
        if isLocalLeader, senderIsCandidate, let requiredAccessWord {
            guard let proof = hello.hello.accessWordProof else {
                try await rejectCandidate(
                    hello.hello.participantID,
                    reason: .accessWordRequired
                )
                return
            }
            guard proof.verify(
                accessWord: requiredAccessWord,
                sessionID: sessionID,
                participantID: hello.hello.participantID,
                identity: hello.hello.identity,
                rendezvousProof: hello.hello.rendezvousProof
            ) else {
                try await rejectCandidate(
                    hello.hello.participantID,
                    reason: .invalidAccessWord
                )
                return
            }
        }
        if let pendingHello = signedHello, pendingHello != hello {
            if isLocalLeader, senderIsCandidate {
                try await sendRejection(
                    to: hello.hello.participantID,
                    reason: .busy
                )
                return
            }
            throw MeshParticipantBootstrapError.conflictingAdmission
        }
        signedHello = hello
        emit(.candidateDiscovered(hello.hello.participant))
        guard isLocalLeader else {
            guard senderIsLeader else {
                throw MeshParticipantBootstrapError.unexpectedSender
            }
            setPhase(.awaitingAdmission)
            return
        }
        guard senderIsCandidate else {
            throw MeshParticipantBootstrapError.unexpectedSender
        }
        switch availability {
        case .leaderlessLocked:
            try await rejectCandidate(
                hello.hello.participantID,
                reason: .roomLocked
            )
            return
        case .ended:
            try await rejectCandidate(
                hello.hello.participantID,
                reason: .roomEnded
            )
            return
        case .active:
            break
        }
        let current = try requireMemberContext()
        guard current.signedMembership.snapshot.participants.count
            < admissionPolicy.maximumParticipants
        else {
            try await rejectCandidate(
                hello.hello.participantID,
                reason: .roomFull
            )
            return
        }
        guard !current.signedMembership.snapshot.participantIDs.contains(
            hello.hello.participantID
        ) else {
            try await rejectCandidate(
                hello.hello.participantID,
                reason: .denied
            )
            return
        }
        setPhase(.awaitingApproval)
    }

    private func receiveProvisionalAdmission(
        _ provisional: ClipLiveShareSignedNativeV3ProvisionalAdmission,
        from sender: ClipLiveShareNativeV3ParticipantID,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        guard sender == admissionLeaderParticipantID else {
            throw MeshParticipantBootstrapError.unexpectedSender
        }
        guard let hello = signedHello else {
            throw MeshParticipantBootstrapError.joinNotRequested
        }
        try provisional.verify(
            expectedHello: hello,
            expectedFoundingCreatorIdentity:
                expectedFoundingCreatorIdentity,
            at: now
        )
        if let memberContext {
            guard
                provisional.admission.currentMembership
                    == memberContext.signedMembership,
                provisional.admission.authorityChain
                    == memberContext.authorityChain
            else {
                throw MeshParticipantBootstrapError.conflictingAdmission
            }
        } else {
            guard
                provisional.admission.candidateParticipantID
                    == localParticipant.participantID
            else {
                throw MeshParticipantBootstrapError.unexpectedEnvelope
            }
        }
        guard admission == nil || admission == provisional else {
            throw MeshParticipantBootstrapError.conflictingAdmission
        }
        admission = provisional
        try await activateProvisionalAdmission(provisional, at: now)
    }

    private func activateProvisionalAdmission(
        _ provisional: ClipLiveShareSignedNativeV3ProvisionalAdmission,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        setPhase(.provingIdentity)
        let peers = requiredPeersForLocal(admission: provisional)
        guard !peers.isEmpty else {
            throw MeshParticipantBootstrapError.invalidPair
        }
        for peer in peers {
            let key = try ClipLiveShareNativeV3PeerLinkKey(
                localParticipant.participantID,
                peer
            )
            guard key.lowerParticipantID == localParticipant.participantID
            else { continue }
            let nonce = nonceGenerator()
            pairNonces[peer] = nonce
            let challenge = try makeChallenge(
                verifier: localParticipant.participantID,
                prover: peer,
                nonce: nonce,
                admission: provisional,
                at: now
            )
            issuedChallenges[
                ChallengeDirection(
                    verifier: localParticipant.participantID,
                    prover: peer
                )
            ] = challenge
            try await sendRelay(.possessionChallenge(challenge), to: peer)
        }
    }

    private func makeProvisionalAdmission(
        hello: ClipLiveShareSignedNativeV3BootstrapHello,
        context: MeshParticipantBootstrapLaunchContext,
        at now: ClipLiveShareNativeTimestamp
    ) throws -> ClipLiveShareSignedNativeV3ProvisionalAdmission {
        let current = context.signedMembership.snapshot
        let nextRevision = try nextMembershipRevision(
            after: current.membershipRevision
        )
        let candidateCredential =
            try ClipLiveShareNativeV3MembershipCredential(
                sessionID: sessionID,
                leaderParticipantID: current.leaderParticipantID,
                leaderIdentity: current.leaderIdentity,
                participant: hello.hello.participant,
                membershipRevision: nextRevision,
                issuedAt: now,
                expiresAt: now.adding(
                    milliseconds:
                        ClipLiveShareNativeV3Bootstrap.maximumLifetimeMilliseconds
                )
            )
        let signedCredential =
            try ClipLiveShareSignedNativeV3MembershipCredential(
                signing: candidateCredential,
                with: localSigner
            )
        let value = try ClipLiveShareNativeV3ProvisionalAdmission(
            sessionID: sessionID,
            rendezvousProof: hello.hello.rendezvousProof,
            helloDigest: hello.hello.digest,
            candidateCredential: signedCredential,
            currentMembership: context.signedMembership,
            authorityChain: context.authorityChain,
            proposedParticipantIDs:
                current.participantIDs.union([hello.hello.participantID]),
            issuedAt: now,
            expiresAt: now.adding(
                milliseconds:
                    ClipLiveShareNativeV3Bootstrap.maximumLifetimeMilliseconds
            )
        )
        return try ClipLiveShareSignedNativeV3ProvisionalAdmission(
            signing: value,
            with: localSigner
        )
    }

    // MARK: - Possession and provisional relay

    private func receiveRelay(
        _ relay: ClipLiveShareNativeV3BootstrapRelay,
        from sender: ClipLiveShareNativeV3ParticipantID,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        guard let admission else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        guard
            relay.sessionID == sessionID,
            relay.admissionDigest == admission.admission.digest
        else {
            throw ClipLiveShareNativeV3BootstrapError.invalidRelay
        }
        try validateRelayPair(relay, admission: admission)

        if isLocalLeader, relay.targetParticipantID
            != localParticipant.participantID
        {
            guard sender == relay.originParticipantID else {
                throw MeshParticipantBootstrapError.unexpectedSender
            }
            try await send(.relay(relay), to: relay.targetParticipantID)
            return
        }

        guard relay.targetParticipantID == localParticipant.participantID else {
            throw ClipLiveShareNativeV3BootstrapError.invalidRelay
        }
        guard
            sender == relay.originParticipantID
                || sender == admissionLeaderParticipantID
        else {
            throw MeshParticipantBootstrapError.unexpectedSender
        }
        let remote = relay.originParticipantID
        switch relay.payload {
        case let .possessionChallenge(challenge):
            try await receiveChallenge(
                challenge,
                from: remote,
                admission: admission,
                at: now
            )
        case let .possessionProof(proof):
            try await receiveProof(
                proof,
                from: remote,
                admission: admission,
                at: now
            )
        case .offer, .answer, .ice:
            guard verifiedPeers.contains(remote),
                  let descriptor = provisionalPair(
                    remote: remote,
                    admission: admission
                  )
            else {
                throw MeshParticipantBootstrapError.possessionNotVerified
            }
            try await pairHooks.receiveRelay(
                relay.payload,
                remote,
                descriptor
            )
        }
    }

    private func receiveChallenge(
        _ challenge: ClipLiveShareNativeV3PossessionChallenge,
        from remote: ClipLiveShareNativeV3ParticipantID,
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        let localCredential = try credential(
            for: localParticipant.participantID,
            admission: admission
        )
        guard
            challenge.sessionID == sessionID,
            challenge.peerLinkKey.participantIDs
                == Set([remote, localParticipant.participantID]),
            challenge.verifierParticipantID == remote,
            challenge.proverParticipantID
                == localParticipant.participantID,
            challenge.credentialDigest
                == localCredential.credential.digest,
            challenge.membershipRevision
                == admission.admission.candidateCredential.credential
                    .membershipRevision
        else {
            throw ClipLiveShareNativeV3Error.contextMismatch
        }
        try validateBootstrapChallenge(challenge, at: now)

        let key = challenge.peerLinkKey
        if key.lowerParticipantID == remote {
            if let existing = pairNonces[remote],
               existing != challenge.transportNonce {
                throw ClipLiveShareNativeV3Error.contextMismatch
            }
            pairNonces[remote] = challenge.transportNonce
        } else {
            guard pairNonces[remote] == challenge.transportNonce else {
                throw ClipLiveShareNativeV3Error.contextMismatch
            }
        }

        let proof = try ClipLiveShareSignedNativeV3PossessionProof(
            signing: challenge,
            with: localSigner
        )
        try await sendRelay(.possessionProof(proof), to: remote)

        // The upper endpoint responds to the lower endpoint's nonce-bearing
        // challenge with a reverse challenge using that exact nonce. Both
        // directions therefore prove identity while deriving one shared,
        // high-entropy transport context.
        if key.upperParticipantID == localParticipant.participantID {
            let direction = ChallengeDirection(
                verifier: localParticipant.participantID,
                prover: remote
            )
            if issuedChallenges[direction] == nil {
                let reverse = try makeChallenge(
                    verifier: localParticipant.participantID,
                    prover: remote,
                    nonce: challenge.transportNonce,
                    admission: admission,
                    at: now
                )
                issuedChallenges[direction] = reverse
                try await sendRelay(
                    .possessionChallenge(reverse),
                    to: remote
                )
            }
        }
    }

    private func receiveProof(
        _ proof: ClipLiveShareSignedNativeV3PossessionProof,
        from remote: ClipLiveShareNativeV3ParticipantID,
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        let direction = ChallengeDirection(
            verifier: localParticipant.participantID,
            prover: remote
        )
        guard let expected = issuedChallenges[direction] else {
            throw ClipLiveShareNativeV3Error.contextMismatch
        }
        let remoteCredential = try credential(
            for: remote,
            admission: admission
        )
        try proof.verify(
            expectedChallenge: expected,
            proverCredential: remoteCredential,
            at: now
        )
        guard pairNonces[remote] == expected.transportNonce else {
            throw ClipLiveShareNativeV3Error.contextMismatch
        }
        verifiedPeers.insert(remote)
        try await preparePairIfNeeded(
            remote: remote,
            admission: admission
        )
    }

    private func preparePairIfNeeded(
        remote: ClipLiveShareNativeV3ParticipantID,
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission
    ) async throws {
        guard !preparedPeers.contains(remote),
              let descriptor = provisionalPair(
                remote: remote,
                admission: admission
              )
        else { return }
        try await pairHooks.prepare(descriptor)
        preparedPeers.insert(remote)
        setPhase(.preparingPeerLinks)
        emit(.provisionalPairReady(descriptor))
    }

    private func sendRelay(
        _ payload: ClipLiveShareNativeV3BootstrapRelayPayload,
        to remoteParticipantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        guard let admission else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        let relay = try ClipLiveShareNativeV3BootstrapRelay(
            sessionID: sessionID,
            admissionDigest: admission.admission.digest,
            originParticipantID: localParticipant.participantID,
            targetParticipantID: remoteParticipantID,
            payload: payload
        )
        let routeTarget =
            isLocalLeader
                ? remoteParticipantID
                : admissionLeaderParticipantID
        try await send(.relay(relay), to: routeTarget)
    }

    // MARK: - Readiness and commit

    private func sendLocalReadinessIfComplete(
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        guard let admission else {
            throw MeshParticipantBootstrapError.missingAdmission
        }
        let requiredKeys = try requiredLocalPairKeys(admission: admission)
        guard
            !localReadinessSent,
            !requiredKeys.isEmpty,
            requiredKeys.isSubset(of: readyPeerLinkKeys)
        else { return }
        let readiness = try ClipLiveShareNativeV3BootstrapLinkReadiness(
            sessionID: sessionID,
            admissionDigest: admission.admission.digest,
            reporterParticipantID: localParticipant.participantID,
            reporterIdentity: localParticipant.identity,
            readyPeerLinkKeys: requiredKeys
        )
        let signed =
            try ClipLiveShareSignedNativeV3BootstrapLinkReadiness(
                signing: readiness,
                with: localSigner
            )
        localReadinessSent = true
        setPhase(.awaitingMembershipCommit)
        if isLocalLeader {
            try await receiveReadiness(
                signed,
                from: localParticipant.participantID,
                at: now
            )
        } else {
            try await send(
                .linkReadiness(signed),
                to: admissionLeaderParticipantID
            )
        }
    }

    private func receiveReadiness(
        _ signed: ClipLiveShareSignedNativeV3BootstrapLinkReadiness,
        from sender: ClipLiveShareNativeV3ParticipantID,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        guard isLocalLeader, let admission else {
            throw MeshParticipantBootstrapError.invalidRole
        }
        guard sender == signed.readiness.reporterParticipantID else {
            throw MeshParticipantBootstrapError.unexpectedSender
        }
        try validateNativeV3AdmissionFresh(admission, at: now)
        try signed.verify(admission: admission)
        if let previous =
            readinessByReporter[signed.readiness.reporterParticipantID]
        {
            guard
                Set(previous.readiness.readyPeerLinkKeys)
                    .isSubset(of: Set(signed.readiness.readyPeerLinkKeys))
            else {
                throw ClipLiveShareNativeV3BootstrapError.invalidReadiness
            }
        }
        readinessByReporter[signed.readiness.reporterParticipantID] =
            signed
        try await commitIfEveryPairIsReady(at: now)
    }

    private func commitIfEveryPairIsReady(
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        guard isLocalLeader, let admission, !committedMembership else {
            return
        }
        let candidate = admission.admission.candidateParticipantID
        let currentIDs =
            admission.admission.currentMembership.snapshot.participantIDs
        for existing in currentIDs {
            let key = try ClipLiveShareNativeV3PeerLinkKey(
                existing,
                candidate
            )
            for reporter in [existing, candidate] {
                guard
                    readinessByReporter[reporter]
                        .map({
                            Set($0.readiness.readyPeerLinkKeys)
                                .contains(key)
                        }) == true
                else { return }
            }
        }
        let committed = try makeCommittedMembership(
            admission: admission,
            at: now
        )
        // Promote this participant's already-established provisional manager
        // before advertising the membership. No room control or media can
        // traverse a candidate link before this exact signed commit.
        try await receiveCommittedMembership(
            committed,
            from: localParticipant.participantID,
            at: now
        )
        for participantID in committed.snapshot.participantIDs
            where participantID != localParticipant.participantID
        {
            try await send(.admitted(committed), to: participantID)
        }
    }

    private func receiveCommittedMembership(
        _ membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
        from sender: ClipLiveShareNativeV3ParticipantID,
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        guard sender == admissionLeaderParticipantID
                || (
                    isLocalLeader
                        && sender == localParticipant.participantID
                ),
              let admission
        else {
            throw MeshParticipantBootstrapError.unexpectedSender
        }
        if completedContext != nil {
            guard completedContext?.signedMembership == membership else {
                throw MeshParticipantBootstrapError.membershipAlreadyCommitted
            }
            return
        }
        let proposedIDs = Set(admission.admission.proposedParticipantIDs)
        let current = admission.admission.currentMembership.snapshot
        try membership.verify(
            expectedSessionID: sessionID,
            expectedLeaderParticipantID: current.leaderParticipantID,
            expectedLeaderIdentity: current.leaderIdentity,
            at: now
        )
        guard
            membership.snapshot.membershipRevision
                > current.membershipRevision,
            membership.snapshot.participantIDs == proposedIDs,
            membership.snapshot.participants.first(where: {
                $0.participantID
                    == admission.admission.candidateParticipantID
            }) == admission.admission.candidateCredential.credential
                .participant
        else {
            throw ClipLiveShareNativeV3BootstrapError
                .invalidProvisionalAdmission
        }
        let required = try requiredLocalPairKeys(admission: admission)
        guard required.isSubset(of: readyPeerLinkKeys) else {
            throw MeshParticipantBootstrapError.peerLinkNotReady
        }
        let authority = try ClipLiveShareNativeV3RoomAuthorityChain(
            foundingCreatorParticipantID:
                admission.admission.authorityChain
                    .foundingCreatorParticipantID,
            foundingCreatorIdentity:
                admission.admission.authorityChain
                    .foundingCreatorIdentity,
            genesisMembership:
                admission.admission.authorityChain.genesisMembership,
            checkpoints: admission.admission.authorityChain.checkpoints,
            latestMembership: membership
        )
        try authority.verify(
            expectedSessionID: sessionID,
            expectedFoundingCreatorIdentity:
                expectedFoundingCreatorIdentity,
            at: now
        )
        let context = try makeCompletedContext(
            membership: membership,
            authority: authority,
            admission: admission
        )
        try await pairHooks.promote(context)
        completedContext = context
        committedMembership = true
        setPhase(.ready)
        switch role {
        case .candidate:
            emit(.launchReady(context))
        case .member:
            emit(.membershipUpdateReady(context))
        }
    }

    // MARK: - Rejection and timeout

    private func receiveRejection(
        _ rejection: ClipLiveShareNativeV3BootstrapRejection,
        from sender: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        guard
            sender == admissionLeaderParticipantID,
            rejection.sessionID == sessionID,
            rendezvousProof.map({
                rejection.rendezvousProof == $0
            }) == true
        else {
            throw MeshParticipantBootstrapError.unexpectedSender
        }
        await abortProvisionalPairs()
        setPhase(
            rejection.reason == .timedOut
                ? .timedOut
                : .rejected(rejection.reason)
        )
        emit(.rejected(rejection.reason))
    }

    private func rejectCandidate(
        _ candidateID: ClipLiveShareNativeV3ParticipantID,
        reason: ClipLiveShareNativeV3BootstrapRejectionReason
    ) async throws {
        var deliveryError: (any Error)?
        do {
            try await sendRejection(to: candidateID, reason: reason)
        } catch {
            deliveryError = error
        }
        await abortProvisionalPairs()
        setPhase(
            reason == .timedOut
                ? .timedOut
                : .rejected(reason)
        )
        emit(.rejected(reason))
        if let deliveryError {
            throw deliveryError
        }
    }

    private func sendRejection(
        to candidateID: ClipLiveShareNativeV3ParticipantID,
        reason: ClipLiveShareNativeV3BootstrapRejectionReason,
        rendezvousProof:
            ClipLiveShareNativeV3RendezvousProof? = nil
    ) async throws {
        guard let proof = rendezvousProof ?? self.rendezvousProof else {
            throw MeshParticipantBootstrapError.missingRendezvousProof
        }
        let rejection = ClipLiveShareNativeV3BootstrapRejection(
            sessionID: sessionID,
            rendezvousProof: proof,
            reason: reason
        )
        try await send(.rejected(rejection), to: candidateID)
    }

    private func abortProvisionalPairs() async {
        let peers: Set<ClipLiveShareNativeV3ParticipantID>
        if let admission {
            peers = Set(requiredPeersForLocal(admission: admission))
        } else if let candidate = signedHello?.hello.participantID,
                  candidate != localParticipant.participantID {
            peers = [candidate]
        } else {
            peers = Set(preparedPeers)
        }
        for peer in peers {
            await pairHooks.abort(peer)
        }
    }

    // MARK: - Validation and construction

    private func requireOpen() throws {
        guard phase != .closed else {
            throw MeshParticipantBootstrapError.closed
        }
    }

    private func requireMemberContext()
        throws -> MeshParticipantBootstrapLaunchContext
    {
        guard let memberContext else {
            throw MeshParticipantBootstrapError.invalidRole
        }
        return memberContext
    }

    private func requiredPeersForLocal(
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission
    ) -> [ClipLiveShareNativeV3ParticipantID] {
        let candidate = admission.admission.candidateParticipantID
        if localParticipant.participantID == candidate {
            return admission.admission.currentMembership.snapshot
                .participantIDs.sorted()
        }
        guard admission.admission.currentMembership.snapshot.participantIDs
            .contains(localParticipant.participantID)
        else { return [] }
        return [candidate]
    }

    private func requiredLocalPairKeys(
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission
    ) throws -> Set<ClipLiveShareNativeV3PeerLinkKey> {
        let candidate = admission.admission.candidateParticipantID
        if localParticipant.participantID == candidate {
            return try Set(
                admission.admission.currentMembership.snapshot.participantIDs
                    .map {
                        try ClipLiveShareNativeV3PeerLinkKey(candidate, $0)
                    }
            )
        }
        return [
            try ClipLiveShareNativeV3PeerLinkKey(
                localParticipant.participantID,
                candidate
            )
        ]
    }

    private func validateRequiredPair(
        _ key: ClipLiveShareNativeV3PeerLinkKey,
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission,
        expectedPeer: ClipLiveShareNativeV3ParticipantID
    ) throws {
        let candidate = admission.admission.candidateParticipantID
        let expected = Set([
            localParticipant.participantID,
            expectedPeer,
        ])
        guard
            key.participantIDs == expected,
            key.contains(candidate),
            let existingMember = key.otherParticipant(than: candidate),
            admission.admission.currentMembership.snapshot.participantIDs
                .contains(existingMember)
        else {
            throw MeshParticipantBootstrapError.invalidPair
        }
    }

    /// Validates a routed provisional relay against its actual endpoints.
    ///
    /// The admission leader is only a courier when neither endpoint is the
    /// leader. Validating that forwarded message as `leader <-> origin` rejects
    /// a legitimate `existing member <-> candidate` pair whenever the existing
    /// member initiated negotiation. The signed relay therefore names the
    /// authoritative endpoint pair; the leader must not substitute itself.
    private func validateRelayPair(
        _ relay: ClipLiveShareNativeV3BootstrapRelay,
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission
    ) throws {
        let key = relay.payload.peerLinkKey
        let candidate = admission.admission.candidateParticipantID
        let expected = Set([
            relay.originParticipantID,
            relay.targetParticipantID,
        ])
        guard
            key.participantIDs == expected,
            key.contains(candidate),
            let existingMember = key.otherParticipant(than: candidate),
            admission.admission.currentMembership.snapshot.participantIDs
                .contains(existingMember)
        else {
            throw MeshParticipantBootstrapError.invalidPair
        }
    }

    private func credential(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission
    ) throws -> ClipLiveShareSignedNativeV3MembershipCredential {
        if participantID == admission.admission.candidateParticipantID {
            return admission.admission.candidateCredential
        }
        guard let credential =
            admission.admission.currentMembership.snapshot.credentials
                .first(where: {
                    $0.credential.participant.participantID
                        == participantID
                })
        else {
            throw ClipLiveShareNativeV3Error
                .unknownParticipant(participantID)
        }
        return credential
    }

    private func makeChallenge(
        verifier: ClipLiveShareNativeV3ParticipantID,
        prover: ClipLiveShareNativeV3ParticipantID,
        nonce: ClipLiveShareNativeV3TransportNonce,
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission,
        at now: ClipLiveShareNativeTimestamp
    ) throws -> ClipLiveShareNativeV3PossessionChallenge {
        let proverCredential = try credential(
            for: prover,
            admission: admission
        )
        return try ClipLiveShareNativeV3PossessionChallenge(
            sessionID: sessionID,
            membershipRevision:
                admission.admission.candidateCredential.credential
                    .membershipRevision,
            peerLinkKey: ClipLiveShareNativeV3PeerLinkKey(
                verifier,
                prover
            ),
            verifierParticipantID: verifier,
            proverParticipantID: prover,
            credentialDigest: proverCredential.credential.digest,
            transportNonce: nonce,
            challenge: challengeGenerator(),
            issuedAt: now,
            expiresAt: admission.admission.expiresAt
        )
    }

    private func provisionalPair(
        remote: ClipLiveShareNativeV3ParticipantID,
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission
    ) -> MeshParticipantBootstrapProvisionalPair? {
        guard let nonce = pairNonces[remote] else { return nil }
        return MeshParticipantBootstrapProvisionalPair(
            localParticipantID: localParticipant.participantID,
            remoteParticipantID: remote,
            admission: admission,
            transportNonce: nonce,
            admissionDigest: admission.admission.digest
        )
    }

    private func makeCommittedMembership(
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission,
        at now: ClipLiveShareNativeTimestamp
    ) throws -> ClipLiveShareSignedNativeV3MembershipSnapshot {
        let current = admission.admission.currentMembership.snapshot
        let participants =
            current.participants
                + [admission.admission.candidateCredential.credential
                    .participant]
        let revision = try nextMembershipRevision(
            after: current.membershipRevision
        )
        let credentialExpiry = try now.adding(milliseconds: 180_000)
        let credentials = try participants.map { participant in
            let value = try ClipLiveShareNativeV3MembershipCredential(
                sessionID: sessionID,
                leaderParticipantID: current.leaderParticipantID,
                leaderIdentity: current.leaderIdentity,
                participant: participant,
                membershipRevision: revision,
                issuedAt: now,
                expiresAt: credentialExpiry
            )
            return try ClipLiveShareSignedNativeV3MembershipCredential(
                signing: value,
                with: localSigner
            )
        }
        let snapshot = try ClipLiveShareNativeV3MembershipSnapshot(
            sessionID: sessionID,
            leaderParticipantID: current.leaderParticipantID,
            leaderIdentity: current.leaderIdentity,
            membershipRevision: revision,
            credentials: credentials,
            issuedAt: now,
            expiresAt: now.adding(milliseconds: 120_000),
            maximumParticipants: admissionPolicy.maximumParticipants
        )
        return try ClipLiveShareSignedNativeV3MembershipSnapshot(
            signing: snapshot,
            with: localSigner
        )
    }

    private func makeCompletedContext(
        membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
        authority: ClipLiveShareNativeV3RoomAuthorityChain,
        admission: ClipLiveShareSignedNativeV3ProvisionalAdmission
    ) throws -> MeshParticipantBootstrapLaunchContext {
        let candidate = admission.admission.candidateParticipantID
        let previousDigests =
            memberContext?.bootstrapAdmissionDigests ?? [:]
        let previousNonces =
            memberContext?.verifiedPeerTransportNonces ?? [:]
        var digests = previousDigests
        var nonces = previousNonces
        if localParticipant.participantID == candidate {
            for peer in admission.admission.currentMembership.snapshot
                .participantIDs
            {
                guard let nonce = pairNonces[peer] else {
                    throw MeshParticipantBootstrapError
                        .possessionNotVerified
                }
                digests[peer] = admission.admission.digest
                nonces[peer] = nonce
            }
        } else {
            guard let nonce = pairNonces[candidate] else {
                throw MeshParticipantBootstrapError
                    .possessionNotVerified
            }
            digests[candidate] = admission.admission.digest
            nonces[candidate] = nonce
        }
        let expectedPeers = membership.snapshot.participantIDs
            .subtracting([localParticipant.participantID])
        guard Set(digests.keys) == expectedPeers,
              Set(nonces.keys) == expectedPeers
        else {
            throw MeshParticipantBootstrapError.possessionNotVerified
        }
        return MeshParticipantBootstrapLaunchContext(
            localParticipantID: localParticipant.participantID,
            localIdentitySigner: localSigner,
            signedMembership: membership,
            authorityChain: authority,
            expectedFoundingCreatorIdentity:
                expectedFoundingCreatorIdentity,
            bootstrapAdmissionDigests: digests,
            verifiedPeerTransportNonces: nonces,
            admissionPolicy: admissionPolicy
        )
    }

    private func nextMembershipRevision(
        after revision: ClipLiveShareNativeV3MembershipRevision
    ) throws -> ClipLiveShareNativeV3MembershipRevision {
        let (raw, overflow) = revision.rawValue.addingReportingOverflow(1)
        guard !overflow else {
            throw ClipLiveShareNativeV3Error.invalidRevision(
                name: "membership"
            )
        }
        return try ClipLiveShareNativeV3MembershipRevision(rawValue: raw)
    }

    private func send(
        _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        do {
            try await sendRendezvous(envelope, participantID)
        } catch {
            emit(.failed(error.localizedDescription))
            throw MeshParticipantBootstrapError.sendFailed(
                error.localizedDescription
            )
        }
    }

    private func setPhase(_ phase: MeshParticipantBootstrapPhase) {
        guard self.phase != phase else { return }
        self.phase = phase
        emit(.phaseChanged(phase))
    }

    private func emit(_ event: MeshParticipantBootstrapEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

private func validateBootstrapChallenge(
    _ challenge: ClipLiveShareNativeV3PossessionChallenge,
    at now: ClipLiveShareNativeTimestamp
) throws {
    guard challenge.challenge.count
        == ClipLiveShareNativeV3.possessionChallengeByteCount
    else {
        throw ClipLiveShareNativeV3Error.invalidBinaryValue(
            name: "possession challenge",
            expectedBytes:
                ClipLiveShareNativeV3.possessionChallengeByteCount
        )
    }
    guard challenge.issuedAt <= now, now < challenge.expiresAt else {
        if now >= challenge.expiresAt {
            throw ClipLiveShareNativeV3Error.expired
        }
        throw ClipLiveShareNativeV3Error.notYetValid
    }
}

private func validateNativeV3AdmissionFresh(
    _ admission: ClipLiveShareSignedNativeV3ProvisionalAdmission,
    at now: ClipLiveShareNativeTimestamp
) throws {
    guard admission.admission.issuedAt <= now,
          now < admission.admission.expiresAt
    else {
        if now >= admission.admission.expiresAt {
            throw ClipLiveShareNativeV3Error.expired
        }
        throw ClipLiveShareNativeV3Error.notYetValid
    }
}

private func nativeBootstrapRandomData(count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    for index in bytes.indices {
        bytes[index] = UInt8.random(in: .min ... .max)
    }
    return Data(bytes)
}
