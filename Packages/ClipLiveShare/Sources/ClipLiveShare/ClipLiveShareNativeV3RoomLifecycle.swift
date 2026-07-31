import Foundation

/// App-neutral lifecycle for one participant in a native-v3 room.
///
/// Media and rendezvous transports deliberately live outside this type. The
/// lifecycle consumes authenticated control values and produces explicit
/// effects for the app to broadcast, clean up, or use to advertise a successor
/// invite. All state transitions are transactional: validation and local mesh
/// readiness complete before any committed state is replaced.
public enum ClipLiveShareNativeV3RoomLifecyclePhase: String, Codable, Equatable,
  Hashable, Sendable
{
  case active
  case electing
  case leaderlessLocked
  case ended
}

public enum ClipLiveShareNativeV3RoomLifecycleError: Error, Equatable, Sendable {
  case roomEnded
  case invalidPhase(
    expected: ClipLiveShareNativeV3RoomLifecyclePhase,
    actual: ClipLiveShareNativeV3RoomLifecyclePhase
  )
  case localParticipantIsNotLeader
  case localParticipantIsLeader
  case localParticipantIsNotCandidate
  case noEligibleSuccessor
  case leaderStillReachable
  case missingLocalParticipant
  case peerLinksNotReady([ClipLiveShareNativeV3ParticipantID])
  case conflictingElection
  case missingLeadershipProposal
  case missingLeadershipTransferRequest
  case leadershipQuorumNotReached(required: Int, actual: Int)
  case participantCannotVote(ClipLiveShareNativeV3ParticipantID)
  case invalidSuccessorMembership
}

extension ClipLiveShareNativeV3RoomLifecycleError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .roomEnded:
      "The native-v3 room has ended."
    case let .invalidPhase(expected, actual):
      "Expected room phase \(expected.rawValue), found \(actual.rawValue)."
    case .localParticipantIsNotLeader:
      "Only the current room leader may perform this operation."
    case .localParticipantIsLeader:
      "The current room leader must transfer authority before leaving."
    case .localParticipantIsNotCandidate:
      "Only the elected candidate may perform this operation."
    case .noEligibleSuccessor:
      "The room has no eligible successor."
    case .leaderStillReachable:
      "A recovery election cannot begin while the current leader is reachable."
    case .missingLocalParticipant:
      "The local participant is not present in the committed membership."
    case let .peerLinksNotReady(participantIDs):
      "The membership cannot commit until \(participantIDs.count) local peer links are ready."
    case .conflictingElection:
      "The leadership message conflicts with the election already in progress."
    case .missingLeadershipProposal:
      "No leadership proposal is currently being collected."
    case .missingLeadershipTransferRequest:
      "The graceful leadership proposal has no verified transfer request."
    case let .leadershipQuorumNotReached(required, actual):
      "Leadership requires \(required) votes; only \(actual) are available."
    case let .participantCannotVote(participantID):
      "Participant \(participantID) is not eligible to vote in this election."
    case .invalidSuccessorMembership:
      "The successor membership does not preserve the certified surviving quorum."
    }
  }
}

public enum ClipLiveShareNativeV3RoomLifecycleEvent: Equatable, Sendable {
  /// The app should establish these local pair links before retrying a
  /// membership commit.
  case peerLinksRequired([ClipLiveShareNativeV3ParticipantID])
  case membershipCommitted(
    ClipLiveShareSignedNativeV3MembershipSnapshot,
    admitted: [ClipLiveShareNativeV3ParticipantID],
    removed: [ClipLiveShareNativeV3ParticipantID]
  )
  /// All per-participant media, collaboration, diagnostics, and link state for
  /// this exact participant must be removed.
  case cleanupParticipant(ClipLiveShareNativeV3ParticipantID)
  case localParticipantRemoved
  case phaseChanged(ClipLiveShareNativeV3RoomLifecyclePhase)
  case broadcastTransferRequest(
    ClipLiveShareSignedNativeV3LeadershipTransferRequest
  )
  case broadcastLeadershipProposal(
    ClipLiveShareSignedNativeV3LeadershipProposal
  )
  case broadcastLeadershipVote(ClipLiveShareSignedNativeV3LeadershipVote)
  case leadershipCertificateReady(
    ClipLiveShareNativeV3LeadershipCertificate
  )
  case leadershipCommitted(
    term: ClipLiveShareNativeV3LeadershipTerm,
    leaderParticipantID: ClipLiveShareNativeV3ParticipantID
  )
  /// A successor owns room authority but does not inherit the old rendezvous
  /// lease. It must advertise a freshly allocated invite.
  case newInviteRequired
  case broadcastRoomTermination(ClipLiveShareSignedNativeV3RoomTermination)
  case roomEnded(ClipLiveShareNativeV3RoomTerminationReason)
}

public enum ClipLiveShareNativeV3AuthorityReconciliation:
  Equatable, Sendable
{
  /// The peer confirmed the exact authority already committed locally.
  case identical
  /// The peer is behind this participant's committed authority.
  case stale
  /// A cryptographically complete strict extension was adopted atomically.
  case adopted([ClipLiveShareNativeV3RoomLifecycleEvent])
}

private struct ClipLiveShareNativeV3PendingElection: Sendable {
  let reason: ClipLiveShareNativeV3LeadershipTransitionReason
  let candidateParticipantID: ClipLiveShareNativeV3ParticipantID
  let reachableParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  var transferRequest: ClipLiveShareSignedNativeV3LeadershipTransferRequest?
  var signedProposal: ClipLiveShareSignedNativeV3LeadershipProposal?
  var votes:
    [ClipLiveShareNativeV3ParticipantID: ClipLiveShareSignedNativeV3LeadershipVote]
}

public struct ClipLiveShareNativeV3RoomLifecycleCoordinator: Sendable {
  public let localParticipantID: ClipLiveShareNativeV3ParticipantID
  public let localIdentity: ClipLiveShareIdentityPublicKey
  public let admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy

  public private(set) var phase: ClipLiveShareNativeV3RoomLifecyclePhase
  public private(set) var authorityChain: ClipLiveShareNativeV3RoomAuthorityChain
  public private(set) var signedMembership:
    ClipLiveShareSignedNativeV3MembershipSnapshot
  public private(set) var currentTerm: ClipLiveShareNativeV3LeadershipTerm
  public private(set) var currentLeaderParticipantID:
    ClipLiveShareNativeV3ParticipantID
  public private(set) var currentLeaderIdentity: ClipLiveShareIdentityPublicKey
  public private(set) var establishedPeerParticipantIDs:
    Set<ClipLiveShareNativeV3ParticipantID>

  private let localSigner: any ClipLiveShareIdentitySigner
  private var membershipLedger: ClipLiveShareNativeV3MembershipRevisionLedger
  private var voteLedger: ClipLiveShareNativeV3LeadershipVoteLedger
  private var terminationLedger: ClipLiveShareNativeV3RoomTerminationLedger
  private var pendingElection: ClipLiveShareNativeV3PendingElection?

  public init(
    localParticipantID: ClipLiveShareNativeV3ParticipantID,
    localSigner: any ClipLiveShareIdentitySigner,
    authorityChain: ClipLiveShareNativeV3RoomAuthorityChain,
    expectedSessionID: ClipLiveShareSessionID,
    expectedFoundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
    admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy = .productDefault,
    establishedPeerParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try authorityChain.verify(
      expectedSessionID: expectedSessionID,
      expectedFoundingCreatorIdentity: expectedFoundingCreatorIdentity,
      at: now
    )
    let membership = authorityChain.currentMembership
    guard let localParticipant = membership.snapshot.participants.first(where: {
      $0.participantID == localParticipantID
    }) else {
      throw ClipLiveShareNativeV3RoomLifecycleError.missingLocalParticipant
    }
    guard localParticipant.identity == localSigner.publicKey else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    guard membership.snapshot.participants.count <= admissionPolicy.maximumParticipants else {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: admissionPolicy.maximumParticipants,
        actual: membership.snapshot.participants.count
      )
    }
    let requiredPeers = membership.snapshot.participantIDs
      .subtracting([localParticipantID])
    let missing = requiredPeers.subtracting(establishedPeerParticipantIDs).sorted()
    guard missing.isEmpty else {
      throw ClipLiveShareNativeV3RoomLifecycleError.peerLinksNotReady(missing)
    }

    self.localParticipantID = localParticipantID
    localIdentity = localSigner.publicKey
    self.localSigner = localSigner
    self.admissionPolicy = admissionPolicy
    phase = .active
    self.authorityChain = authorityChain
    signedMembership = membership
    currentTerm = authorityChain.currentTerm
    currentLeaderParticipantID = authorityChain.currentLeaderParticipantID
    currentLeaderIdentity = authorityChain.currentLeaderIdentity
    self.establishedPeerParticipantIDs = establishedPeerParticipantIDs
      .intersection(membership.snapshot.participantIDs)
      .subtracting([localParticipantID])
    membershipLedger = ClipLiveShareNativeV3MembershipRevisionLedger(
      latestAcceptedRevision: membership.snapshot.membershipRevision
    )
    voteLedger = ClipLiveShareNativeV3LeadershipVoteLedger(
      committedTerm: authorityChain.currentTerm
    )
    terminationLedger = ClipLiveShareNativeV3RoomTerminationLedger()
    pendingElection = nil
  }

  public var sessionID: ClipLiveShareSessionID {
    signedMembership.snapshot.sessionID
  }

  public var isLocalLeader: Bool {
    phase != .ended && currentLeaderParticipantID == localParticipantID
  }

  public var participantIDs: Set<ClipLiveShareNativeV3ParticipantID> {
    signedMembership.snapshot.participantIDs
  }

  public var pendingCandidateParticipantID:
    ClipLiveShareNativeV3ParticipantID?
  {
    pendingElection?.candidateParticipantID
  }

  public mutating func markPeerLinkReady(
    with participantID: ClipLiveShareNativeV3ParticipantID
  ) {
    guard participantID != localParticipantID else { return }
    establishedPeerParticipantIDs.insert(participantID)
  }

  public mutating func markPeerLinkUnavailable(
    with participantID: ClipLiveShareNativeV3ParticipantID
  ) {
    establishedPeerParticipantIDs.remove(participantID)
  }

  /// Cancels an uncommitted recovery election when the certified current
  /// leader reconnects. A graceful transfer is deliberate and cannot be
  /// cancelled merely by observing that leader's link.
  public mutating func currentLeaderBecameReachable()
    throws -> [ClipLiveShareNativeV3RoomLifecycleEvent]
  {
    try requireNotEnded()
    guard !isLocalLeader else {
      throw ClipLiveShareNativeV3RoomLifecycleError.localParticipantIsLeader
    }
    guard
      phase == .leaderlessLocked
        || (
          phase == .electing
            && pendingElection?.reason == .recoveryElection
        )
    else {
      throw ClipLiveShareNativeV3RoomLifecycleError.invalidPhase(
        expected: .leaderlessLocked,
        actual: phase
      )
    }
    establishedPeerParticipantIDs.insert(currentLeaderParticipantID)
    pendingElection = nil
    phase = .active
    return [.phaseChanged(.active)]
  }

  /// A leader may exercise room authority only while its ready direct links,
  /// together with itself, confirm a strict majority of the exact committed
  /// membership. Media remains live while authority is locked.
  public mutating func localLeaderLostQuorum()
    throws -> [ClipLiveShareNativeV3RoomLifecycleEvent]
  {
    try requireNotEnded()
    guard isLocalLeader else {
      throw ClipLiveShareNativeV3RoomLifecycleError.localParticipantIsNotLeader
    }
    if phase == .leaderlessLocked { return [] }
    guard phase == .active else {
      throw ClipLiveShareNativeV3RoomLifecycleError.invalidPhase(
        expected: .active,
        actual: phase
      )
    }
    pendingElection = nil
    phase = .leaderlessLocked
    return [.phaseChanged(.leaderlessLocked)]
  }

  /// Restores a locally led room only for the exact authority epoch whose
  /// quorum was just observed. A delayed liveness callback therefore cannot
  /// overwrite a newer authority chain adopted after a partition heals.
  public mutating func localLeaderQuorumRestored(
    expectedTerm: ClipLiveShareNativeV3LeadershipTerm,
    expectedMembershipDigest: ClipLiveShareNativeDigest
  ) throws -> [ClipLiveShareNativeV3RoomLifecycleEvent] {
    try requireNotEnded()
    guard
      phase == .leaderlessLocked,
      isLocalLeader,
      currentTerm == expectedTerm,
      signedMembership.snapshot.digest == expectedMembershipDigest
    else {
      throw ClipLiveShareNativeV3RoomLifecycleError.invalidPhase(
        expected: .leaderlessLocked,
        actual: phase
      )
    }
    pendingElection = nil
    phase = .active
    return [.phaseChanged(.active)]
  }

  /// Reconciles a complete authority chain received on an authenticated
  /// participant link. Exact confirmation and a valid older prefix are
  /// harmless. Only a cryptographically valid strict extension of the local
  /// history is adopted; forks and rollbacks fail without changing state.
  public mutating func reconcileAuthorityChain(
    _ incoming: ClipLiveShareNativeV3RoomAuthorityChain,
    from participantID: ClipLiveShareNativeV3ParticipantID,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> ClipLiveShareNativeV3AuthorityReconciliation {
    try requireNotEnded()
    try incoming.verify(
      expectedSessionID: sessionID,
      expectedFoundingCreatorIdentity:
        authorityChain.foundingCreatorIdentity,
      localCapabilities: .current,
      at: now
    )
    try validateAdmissionLimit(in: incoming)

    if incoming == authorityChain {
      guard participantIDs.contains(participantID) else {
        throw ClipLiveShareNativeV3Error.invalidAuthorityChain
      }
      return .identical
    }
    if Self.isStrictAuthorityExtension(
      incoming,
      baseMembership: incoming.currentMembership,
      candidate: authorityChain
    ) {
      guard participantIDs.contains(participantID) else {
        throw ClipLiveShareNativeV3Error.invalidAuthorityChain
      }
      return .stale
    }
    guard Self.isStrictAuthorityExtension(
      authorityChain,
      baseMembership: signedMembership,
      candidate: incoming
    ) else {
      throw ClipLiveShareNativeV3Error.invalidAuthorityChain
    }
    guard participantID == incoming.currentLeaderParticipantID else {
      throw ClipLiveShareNativeV3Error.invalidAuthorityChain
    }

    let nextMembership = incoming.currentMembership
    if let localParticipant = nextMembership.snapshot.participants.first(
      where: { $0.participantID == localParticipantID }
    ) {
      guard localParticipant.identity == localIdentity else {
        throw ClipLiveShareNativeV3Error.identityMismatch
      }
      let missing = requiredLocalPeers(
        for: nextMembership.snapshot.participantIDs
      )
      guard missing.isEmpty else {
        throw ClipLiveShareNativeV3RoomLifecycleError.peerLinksNotReady(
          missing
        )
      }
    }
    try validateStableIdentities(nextMembership.snapshot)

    let previousIDs = participantIDs
    let nextIDs = nextMembership.snapshot.participantIDs
    let admitted = nextIDs.subtracting(previousIDs).sorted()
    let removed = previousIDs.subtracting(nextIDs).sorted()
    let previousTerm = currentTerm
    let previousLeader = currentLeaderParticipantID
    let nextPhase: ClipLiveShareNativeV3RoomLifecyclePhase =
      nextIDs.contains(localParticipantID) ? .active : .ended
    let retainedVotes = voteLedger.votedProposalDigests.filter {
      $0.key > incoming.currentTerm
    }

    authorityChain = incoming
    signedMembership = nextMembership
    currentTerm = incoming.currentTerm
    currentLeaderParticipantID = incoming.currentLeaderParticipantID
    currentLeaderIdentity = incoming.currentLeaderIdentity
    membershipLedger = ClipLiveShareNativeV3MembershipRevisionLedger(
      latestAcceptedRevision:
        nextMembership.snapshot.membershipRevision
    )
    voteLedger = ClipLiveShareNativeV3LeadershipVoteLedger(
      committedTerm: incoming.currentTerm,
      votedProposalDigests: retainedVotes
    )
    pendingElection = nil
    establishedPeerParticipantIDs.formIntersection(
      nextIDs.subtracting([localParticipantID])
    )
    phase = nextPhase

    var events = removed.map {
      ClipLiveShareNativeV3RoomLifecycleEvent.cleanupParticipant($0)
    }
    events.append(
      .membershipCommitted(
        nextMembership,
        admitted: admitted,
        removed: removed
      )
    )
    if incoming.currentTerm != previousTerm
      || incoming.currentLeaderParticipantID != previousLeader
    {
      events.append(
        .leadershipCommitted(
          term: incoming.currentTerm,
          leaderParticipantID:
            incoming.currentLeaderParticipantID
        )
      )
    }
    events.append(.phaseChanged(nextPhase))
    if nextPhase == .ended {
      events.append(.localParticipantRemoved)
    } else if incoming.currentLeaderParticipantID == localParticipantID,
      incoming.currentTerm != previousTerm
        || previousLeader != localParticipantID
    {
      events.append(.newInviteRequired)
    }
    return .adopted(events)
  }

  /// Builds an ordinary next membership revision. The caller establishes all
  /// newly required local links, distributes this leader-signed snapshot, then
  /// calls `commitMembershipSnapshot` locally through the same transactional
  /// path used by every other participant.
  public func makeMembershipSnapshot(
    participants: [ClipLiveShareNativeV3Participant],
    at now: ClipLiveShareNativeTimestamp
  ) throws -> ClipLiveShareSignedNativeV3MembershipSnapshot {
    try requireActive()
    guard isLocalLeader else {
      throw ClipLiveShareNativeV3RoomLifecycleError.localParticipantIsNotLeader
    }
    return try makeSignedMembership(
      participants: participants,
      leaderParticipantID: localParticipantID,
      leaderIdentity: localIdentity,
      signer: localSigner,
      revision: nextMembershipRevision(),
      at: now
    )
  }

  /// Commits a current-leader membership revision only after every direct link
  /// needed by this local participant is ready. On any error no lifecycle state
  /// changes.
  public mutating func commitMembershipSnapshot(
    _ incoming: ClipLiveShareSignedNativeV3MembershipSnapshot,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> [ClipLiveShareNativeV3RoomLifecycleEvent] {
    try requireActive()
    try incoming.verify(
      expectedSessionID: sessionID,
      expectedLeaderParticipantID: currentLeaderParticipantID,
      expectedLeaderIdentity: currentLeaderIdentity,
      at: now
    )
    guard incoming.snapshot.participants.count <= admissionPolicy.maximumParticipants else {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: admissionPolicy.maximumParticipants,
        actual: incoming.snapshot.participants.count
      )
    }

    var nextLedger = membershipLedger
    try nextLedger.accept(incoming.snapshot.membershipRevision)
    try validateStableIdentities(incoming.snapshot)
    let incomingIDs = incoming.snapshot.participantIDs
    if incomingIDs.contains(localParticipantID) {
      let missing = requiredLocalPeers(for: incomingIDs)
      guard missing.isEmpty else {
        throw ClipLiveShareNativeV3RoomLifecycleError.peerLinksNotReady(missing)
      }
    }

    let previousIDs = participantIDs
    let admitted = incomingIDs.subtracting(previousIDs).sorted()
    let removed = previousIDs.subtracting(incomingIDs).sorted()
    let nextAuthority = try ClipLiveShareNativeV3RoomAuthorityChain(
      foundingCreatorParticipantID:
        authorityChain.foundingCreatorParticipantID,
      foundingCreatorIdentity: authorityChain.foundingCreatorIdentity,
      genesisMembership: authorityChain.genesisMembership,
      checkpoints: authorityChain.checkpoints,
      latestMembership: incoming
    )
    try nextAuthority.verify(
      expectedSessionID: sessionID,
      expectedFoundingCreatorIdentity: authorityChain.foundingCreatorIdentity,
      at: now
    )
    authorityChain = nextAuthority
    signedMembership = incoming
    membershipLedger = nextLedger
    establishedPeerParticipantIDs.formIntersection(
      incomingIDs.subtracting([localParticipantID])
    )

    var events: [ClipLiveShareNativeV3RoomLifecycleEvent] = [
      .membershipCommitted(incoming, admitted: admitted, removed: removed)
    ]
    events.append(contentsOf: removed.map {
      .cleanupParticipant($0)
    })
    if !incomingIDs.contains(localParticipantID) {
      phase = .ended
      pendingElection = nil
      events.append(.localParticipantRemoved)
      events.append(.phaseChanged(.ended))
    }
    return events
  }

  /// Creates the authenticated request used by an ordinary participant's
  /// "Leave Room" action. The requester deliberately stays connected until
  /// it receives and applies the leader's newer membership without itself.
  public func makeParticipantLeaveRequest(
    at now: ClipLiveShareNativeTimestamp
  ) throws -> ClipLiveShareSignedNativeV3ParticipantLeaveRequest {
    try requireActive()
    guard !isLocalLeader else {
      throw ClipLiveShareNativeV3RoomLifecycleError.localParticipantIsLeader
    }
    let request = try ClipLiveShareNativeV3ParticipantLeaveRequest(
      sessionID: sessionID,
      leaderTerm: currentTerm,
      leaderParticipantID: currentLeaderParticipantID,
      membershipRevision: signedMembership.snapshot.membershipRevision,
      membershipDigest: signedMembership.snapshot.digest,
      participantID: localParticipantID,
      participantIdentity: localIdentity,
      issuedAt: now,
      expiresAt: now.adding(
        milliseconds:
          ClipLiveShareNativeV3
            .maximumParticipantLeaveRequestLifetimeMilliseconds
      )
    )
    return try ClipLiveShareSignedNativeV3ParticipantLeaveRequest(
      signing: request,
      with: localSigner
    )
  }

  /// Validates a participant's leave request and creates the exact next
  /// leader-signed membership. The caller broadcasts and then commits this
  /// value through `commitMembershipSnapshot`, preserving the same
  /// transactional cleanup path as every other removal.
  public func makeMembershipSnapshot(
    accepting signedRequest:
      ClipLiveShareSignedNativeV3ParticipantLeaveRequest,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> ClipLiveShareSignedNativeV3MembershipSnapshot {
    try requireActive()
    guard isLocalLeader else {
      throw ClipLiveShareNativeV3RoomLifecycleError.localParticipantIsNotLeader
    }
    try signedRequest.verify(
      against: signedMembership,
      expectedLeaderTerm: currentTerm,
      expectedLeaderParticipantID: currentLeaderParticipantID,
      expectedLeaderIdentity: currentLeaderIdentity,
      at: now
    )
    let remaining = signedMembership.snapshot.participants.filter {
      $0.participantID != signedRequest.request.participantID
    }
    guard remaining.count < signedMembership.snapshot.participants.count else {
      throw ClipLiveShareNativeV3Error.unknownParticipant(
        signedRequest.request.participantID
      )
    }
    return try makeSignedMembership(
      participants: remaining,
      leaderParticipantID: localParticipantID,
      leaderIdentity: localIdentity,
      signer: localSigner,
      revision: nextMembershipRevision(),
      at: now
    )
  }

  /// Starts a deliberate leader handoff. The successor is deterministic among
  /// the peers this leader can currently reach: the smallest ready participant
  /// ID other than the departing leader. Selecting from the whole membership
  /// could choose a disconnected peer and permanently stall an otherwise
  /// healthy graceful departure.
  public mutating func beginGracefulLeaderLeave(
    at now: ClipLiveShareNativeTimestamp
  ) throws -> [ClipLiveShareNativeV3RoomLifecycleEvent] {
    try requireActive()
    guard isLocalLeader else {
      throw ClipLiveShareNativeV3RoomLifecycleError.localParticipantIsNotLeader
    }
    guard let successor = deterministicReadySuccessor() else {
      throw ClipLiveShareNativeV3RoomLifecycleError.noEligibleSuccessor
    }
    let nextTerm = try nextLeadershipTerm()
    let request = try ClipLiveShareNativeV3LeadershipTransferRequest(
      sessionID: sessionID,
      currentTerm: currentTerm,
      nextTerm: nextTerm,
      currentLeaderParticipantID: currentLeaderParticipantID,
      currentLeaderIdentity: currentLeaderIdentity,
      successorParticipantID: successor,
      lastCommittedMembershipRevision: signedMembership.snapshot.membershipRevision,
      lastCommittedMembershipDigest: signedMembership.snapshot.digest,
      issuedAt: now,
      expiresAt: now.adding(
        milliseconds:
          ClipLiveShareNativeV3.maximumLeadershipProposalLifetimeMilliseconds
      )
    )
    let signed = try ClipLiveShareSignedNativeV3LeadershipTransferRequest(
      signing: request,
      with: localSigner
    )
    let reachable = participantIDs
    pendingElection = ClipLiveShareNativeV3PendingElection(
      reason: .gracefulTransfer,
      candidateParticipantID: successor,
      reachableParticipantIDs: reachable,
      transferRequest: signed,
      signedProposal: nil,
      votes: [:]
    )
    phase = .electing
    return [
      .phaseChanged(.electing),
      .broadcastTransferRequest(signed),
    ]
  }

  /// Accepts a verified old-leader transfer request. The designated successor
  /// immediately authors the proposal and its own vote; all other participants
  /// enter the same election and wait for that proposal.
  public mutating func receiveLeadershipTransferRequest(
    _ signedRequest: ClipLiveShareSignedNativeV3LeadershipTransferRequest,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> [ClipLiveShareNativeV3RoomLifecycleEvent] {
    try requireNotEnded()
    try signedRequest.verify(
      lastCommittedMembership: signedMembership,
      currentTerm: currentTerm,
      currentLeaderParticipantID: currentLeaderParticipantID,
      currentLeaderIdentity: currentLeaderIdentity,
      at: now
    )
    // The old leader is the only authority that chooses a graceful successor.
    // Its signed request has already been verified against the committed
    // membership above. Receivers intentionally do not recompute this from
    // their potentially different local liveness observations.
    if let pendingElection {
      guard
        pendingElection.reason == .gracefulTransfer,
        pendingElection.candidateParticipantID
          == signedRequest.request.successorParticipantID,
        pendingElection.transferRequest == nil
          || pendingElection.transferRequest == signedRequest
      else {
        throw ClipLiveShareNativeV3RoomLifecycleError.conflictingElection
      }
    }
    pendingElection = ClipLiveShareNativeV3PendingElection(
      reason: .gracefulTransfer,
      candidateParticipantID: signedRequest.request.successorParticipantID,
      reachableParticipantIDs: participantIDs,
      transferRequest: signedRequest,
      signedProposal: pendingElection?.signedProposal,
      votes: pendingElection?.votes ?? [:]
    )
    let wasElecting = phase == .electing
    phase = .electing
    var events: [ClipLiveShareNativeV3RoomLifecycleEvent] =
      wasElecting ? [] : [.phaseChanged(.electing)]
    if localParticipantID == signedRequest.request.successorParticipantID {
      events.append(
        contentsOf: try authorAndAcceptLocalProposal(
          reason: .gracefulTransfer,
          transferRequest: signedRequest,
          at: now
        )
      )
    }
    return events
  }

  /// Begins or retries a strict-majority recovery election. Reachability is
  /// local liveness evidence only; the certified electorate remains the exact
  /// last committed membership. A two-person room therefore cannot replace a
  /// crashed leader: one survivor is not a majority of two.
  public mutating func beginUnexpectedLeaderLoss(
    reachableParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> [ClipLiveShareNativeV3RoomLifecycleEvent] {
    try requireNotEnded()
    guard phase == .active || phase == .leaderlessLocked else {
      throw ClipLiveShareNativeV3RoomLifecycleError.invalidPhase(
        expected: .active,
        actual: phase
      )
    }
    guard !reachableParticipantIDs.contains(currentLeaderParticipantID) else {
      throw ClipLiveShareNativeV3RoomLifecycleError.leaderStillReachable
    }
    guard reachableParticipantIDs.contains(localParticipantID) else {
      throw ClipLiveShareNativeV3RoomLifecycleError.missingLocalParticipant
    }
    let survivors = reachableParticipantIDs
      .intersection(participantIDs)
      .subtracting([currentLeaderParticipantID])
    let required = ClipLiveShareNativeV3LeadershipCertificate.requiredQuorum(
      participantCount: participantIDs.count
    )
    guard survivors.count >= required else {
      pendingElection = nil
      phase = .leaderlessLocked
      return [.phaseChanged(.leaderlessLocked)]
    }
    guard
      let candidate = deterministicSuccessor(),
      survivors.contains(candidate)
    else {
      pendingElection = nil
      phase = .leaderlessLocked
      return [.phaseChanged(.leaderlessLocked)]
    }

    pendingElection = ClipLiveShareNativeV3PendingElection(
      reason: .recoveryElection,
      candidateParticipantID: candidate,
      reachableParticipantIDs: survivors,
      transferRequest: nil,
      signedProposal: nil,
      votes: [:]
    )
    phase = .electing
    var events: [ClipLiveShareNativeV3RoomLifecycleEvent] = [
      .phaseChanged(.electing)
    ]
    if localParticipantID == candidate {
      events.append(
        contentsOf: try authorAndAcceptLocalProposal(
          reason: .recoveryElection,
          transferRequest: nil,
          at: now
        )
      )
    }
    return events
  }

  /// Validates the exact next-term deterministic candidate and signs at most
  /// one proposal in that term.
  public mutating func receiveLeadershipProposal(
    _ signedProposal: ClipLiveShareSignedNativeV3LeadershipProposal,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> [ClipLiveShareNativeV3RoomLifecycleEvent] {
    try requireNotEnded()
    try validateProposal(signedProposal, at: now)
    guard var pendingElection else {
      throw ClipLiveShareNativeV3RoomLifecycleError.invalidPhase(
        expected: .electing,
        actual: phase
      )
    }
    let proposal = signedProposal.proposal
    guard
      pendingElection.reason == proposal.reason,
      pendingElection.candidateParticipantID == proposal.candidateParticipantID,
      pendingElection.signedProposal == nil
        || pendingElection.signedProposal == signedProposal
    else {
      throw ClipLiveShareNativeV3RoomLifecycleError.conflictingElection
    }
    pendingElection.signedProposal = signedProposal

    if let existing = pendingElection.votes[localParticipantID] {
      self.pendingElection = pendingElection
      return [.broadcastLeadershipVote(existing)]
    }
    guard pendingElection.reachableParticipantIDs.contains(localParticipantID) else {
      throw ClipLiveShareNativeV3RoomLifecycleError.participantCannotVote(
        localParticipantID
      )
    }
    try voteLedger.recordVote(for: proposal)
    let vote = try ClipLiveShareNativeV3LeadershipVote(
      proposal: proposal,
      voterParticipantID: localParticipantID,
      voterIdentity: localIdentity
    )
    let signedVote = try ClipLiveShareSignedNativeV3LeadershipVote(
      signing: vote,
      with: localSigner
    )
    pendingElection.votes[localParticipantID] = signedVote
    self.pendingElection = pendingElection
    return [.broadcastLeadershipVote(signedVote)]
  }

  /// Collects one authenticated vote. Once a strict majority is present, the
  /// candidate emits a certificate. Delayed or conflicting votes never mutate
  /// state.
  public mutating func receiveLeadershipVote(
    _ signedVote: ClipLiveShareSignedNativeV3LeadershipVote,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> [ClipLiveShareNativeV3RoomLifecycleEvent] {
    try requireNotEnded()
    guard var pendingElection, let signedProposal = pendingElection.signedProposal else {
      throw ClipLiveShareNativeV3RoomLifecycleError.missingLeadershipProposal
    }
    guard localParticipantID == pendingElection.candidateParticipantID else {
      throw ClipLiveShareNativeV3RoomLifecycleError.localParticipantIsNotCandidate
    }
    let proposal = signedProposal.proposal
    try validateNativeV3ValidityWindow(
      issuedAt: proposal.issuedAt,
      expiresAt: proposal.expiresAt,
      now: now
    )
    guard let participant = signedMembership.snapshot.participants.first(where: {
      $0.participantID == signedVote.vote.voterParticipantID
    }) else {
      throw ClipLiveShareNativeV3Error.unknownParticipant(
        signedVote.vote.voterParticipantID
      )
    }
    try signedVote.verify(proposal: proposal, participant: participant)
    guard
      pendingElection.reachableParticipantIDs
        .contains(signedVote.vote.voterParticipantID)
    else {
      throw ClipLiveShareNativeV3RoomLifecycleError.participantCannotVote(
        signedVote.vote.voterParticipantID
      )
    }
    if let existing = pendingElection.votes[signedVote.vote.voterParticipantID] {
      guard existing == signedVote else {
        throw ClipLiveShareNativeV3Error.conflictingLeadershipVote
      }
    } else {
      pendingElection.votes[signedVote.vote.voterParticipantID] = signedVote
    }
    self.pendingElection = pendingElection

    let required = ClipLiveShareNativeV3LeadershipCertificate.requiredQuorum(
      participantCount: participantIDs.count
    )
    guard pendingElection.votes.count >= required else { return [] }
    let certificate = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: signedProposal,
      signedTransferRequest: pendingElection.transferRequest,
      votes: Array(pendingElection.votes.values)
    )
    try certificate.verify(
      lastCommittedMembership: signedMembership,
      currentTerm: currentTerm,
      currentLeaderParticipantID: currentLeaderParticipantID,
      currentLeaderIdentity: currentLeaderIdentity,
      at: now
    )
    return [.leadershipCertificateReady(certificate)]
  }

  /// The certified successor authors the bridge membership under its own
  /// identity. The departed leader is always removed. All surviving voters
  /// remain, preserving evidence that a majority crossed the authority bridge.
  public func makeSuccessorMembership(
    for certificate: ClipLiveShareNativeV3LeadershipCertificate,
    retainingParticipantIDs requestedParticipantIDs:
      Set<ClipLiveShareNativeV3ParticipantID>,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> ClipLiveShareSignedNativeV3MembershipSnapshot {
    guard
      certificate.newLeaderParticipantID == localParticipantID,
      certificate.newLeaderIdentity == localIdentity
    else {
      throw ClipLiveShareNativeV3RoomLifecycleError.localParticipantIsNotCandidate
    }
    try certificate.verify(
      lastCommittedMembership: signedMembership,
      currentTerm: currentTerm,
      currentLeaderParticipantID: currentLeaderParticipantID,
      currentLeaderIdentity: currentLeaderIdentity,
      at: now
    )
    let requiredSurvivors = Set(
      certificate.votes.map(\.vote.voterParticipantID)
    ).subtracting([currentLeaderParticipantID])
    var retained = requestedParticipantIDs
      .intersection(participantIDs)
      .subtracting([currentLeaderParticipantID])
    retained.formUnion(requiredSurvivors)
    retained.insert(localParticipantID)
    let participants = signedMembership.snapshot.participants.filter {
      retained.contains($0.participantID)
    }
    return try makeSignedMembership(
      participants: participants,
      leaderParticipantID: localParticipantID,
      leaderIdentity: localIdentity,
      signer: localSigner,
      revision: nextMembershipRevision(),
      at: now
    )
  }

  /// Atomically crosses an authority checkpoint and its successor membership.
  public mutating func commitLeadershipTransition(
    certificate: ClipLiveShareNativeV3LeadershipCertificate,
    successorMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> [ClipLiveShareNativeV3RoomLifecycleEvent] {
    try requireNotEnded()
    try certificate.verifySuccessorMembership(
      successorMembership,
      after: signedMembership,
      currentTerm: currentTerm,
      currentLeaderParticipantID: currentLeaderParticipantID,
      currentLeaderIdentity: currentLeaderIdentity,
      at: now
    )
    let successorIDs = successorMembership.snapshot.participantIDs
    guard !successorIDs.contains(currentLeaderParticipantID) else {
      throw ClipLiveShareNativeV3RoomLifecycleError.invalidSuccessorMembership
    }
    let requiredSurvivingVoters = Set(
      certificate.votes.map(\.vote.voterParticipantID)
    ).subtracting([currentLeaderParticipantID])
    guard requiredSurvivingVoters.isSubset(of: successorIDs) else {
      throw ClipLiveShareNativeV3RoomLifecycleError.invalidSuccessorMembership
    }
    if successorIDs.contains(localParticipantID) {
      let missing = requiredLocalPeers(for: successorIDs)
      guard missing.isEmpty else {
        throw ClipLiveShareNativeV3RoomLifecycleError.peerLinksNotReady(missing)
      }
    }
    let authorityBridgeMembership =
      authorityChain.checkpoints.last?.successorMembership
      ?? authorityChain.genesisMembership
    let explicitPredecessor =
      signedMembership == authorityBridgeMembership
      ? nil
      : signedMembership
    let nextCheckpoint = ClipLiveShareNativeV3AuthorityCheckpoint(
      predecessorMembership: explicitPredecessor,
      certificate: certificate,
      successorMembership: successorMembership
    )
    let nextAuthority = try ClipLiveShareNativeV3RoomAuthorityChain(
      foundingCreatorParticipantID:
        authorityChain.foundingCreatorParticipantID,
      foundingCreatorIdentity: authorityChain.foundingCreatorIdentity,
      genesisMembership: authorityChain.genesisMembership,
      checkpoints: authorityChain.checkpoints + [nextCheckpoint],
      latestMembership: nil
    )
    try nextAuthority.verify(
      expectedSessionID: sessionID,
      expectedFoundingCreatorIdentity: authorityChain.foundingCreatorIdentity,
      at: now
    )
    var nextVoteLedger = voteLedger
    try nextVoteLedger.commit(certificate)
    var nextMembershipLedger = membershipLedger
    try nextMembershipLedger.accept(
      successorMembership.snapshot.membershipRevision
    )

    let removed = participantIDs.subtracting(successorIDs).sorted()
    authorityChain = nextAuthority
    signedMembership = successorMembership
    currentTerm = certificate.term
    currentLeaderParticipantID = certificate.newLeaderParticipantID
    currentLeaderIdentity = certificate.newLeaderIdentity
    membershipLedger = nextMembershipLedger
    voteLedger = nextVoteLedger
    pendingElection = nil
    establishedPeerParticipantIDs.formIntersection(
      successorIDs.subtracting([localParticipantID])
    )
    phase = successorIDs.contains(localParticipantID) ? .active : .ended

    var events: [ClipLiveShareNativeV3RoomLifecycleEvent] = removed.map {
      .cleanupParticipant($0)
    }
    events.append(
      .membershipCommitted(
        successorMembership,
        admitted: [],
        removed: removed
      )
    )
    events.append(
      .leadershipCommitted(
        term: currentTerm,
        leaderParticipantID: currentLeaderParticipantID
      )
    )
    events.append(.phaseChanged(phase))
    if phase == .ended {
      events.append(.localParticipantRemoved)
    } else if isLocalLeader {
      events.append(.newInviteRequired)
    }
    return events
  }

  public func makeRoomTermination(
    reason: ClipLiveShareNativeV3RoomTerminationReason = .endedByLeader,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> ClipLiveShareSignedNativeV3RoomTermination {
    try requireNotEnded()
    guard isLocalLeader else {
      throw ClipLiveShareNativeV3RoomLifecycleError.localParticipantIsNotLeader
    }
    let previousRevision =
      terminationLedger.latestAcceptedRevision?.rawValue ?? 0
    let (nextRevisionRawValue, overflow) =
      previousRevision.addingReportingOverflow(1)
    guard !overflow else {
      throw ClipLiveShareNativeV3Error.invalidRevision(
        name: "room termination"
      )
    }
    let nextRevision = try ClipLiveShareNativeV3RoomTerminationRevision(
      rawValue: nextRevisionRawValue
    )
    let termination = ClipLiveShareNativeV3RoomTermination(
      sessionID: sessionID,
      leaderTerm: currentTerm,
      leaderParticipantID: currentLeaderParticipantID,
      leaderIdentity: currentLeaderIdentity,
      membershipRevision: signedMembership.snapshot.membershipRevision,
      membershipDigest: signedMembership.snapshot.digest,
      terminationRevision: nextRevision,
      issuedAt: now,
      reason: reason
    )
    return try ClipLiveShareSignedNativeV3RoomTermination(
      signing: termination,
      with: localSigner
    )
  }

  public mutating func endRoomForEveryone(
    reason: ClipLiveShareNativeV3RoomTerminationReason = .endedByLeader,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> [ClipLiveShareNativeV3RoomLifecycleEvent] {
    let signed = try makeRoomTermination(reason: reason, at: now)
    var events: [ClipLiveShareNativeV3RoomLifecycleEvent] = [
      .broadcastRoomTermination(signed)
    ]
    events.append(contentsOf: try receiveRoomTermination(signed, at: now))
    return events
  }

  public mutating func receiveRoomTermination(
    _ signedTermination: ClipLiveShareSignedNativeV3RoomTermination,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> [ClipLiveShareNativeV3RoomLifecycleEvent] {
    try requireNotEnded()
    try signedTermination.verify(
      against: signedMembership,
      expectedLeaderTerm: currentTerm,
      expectedLeaderParticipantID: currentLeaderParticipantID,
      expectedLeaderIdentity: currentLeaderIdentity,
      at: now
    )
    var nextLedger = terminationLedger
    try nextLedger.accept(signedTermination.termination.terminationRevision)
    terminationLedger = nextLedger
    pendingElection = nil
    phase = .ended
    let remoteIDs = participantIDs.subtracting([localParticipantID]).sorted()
    establishedPeerParticipantIDs.removeAll()
    var events = remoteIDs.map {
      ClipLiveShareNativeV3RoomLifecycleEvent.cleanupParticipant($0)
    }
    events.append(.roomEnded(signedTermination.termination.reason))
    events.append(.phaseChanged(.ended))
    return events
  }

  // MARK: - Private

  private static func isStrictAuthorityExtension(
    _ base: ClipLiveShareNativeV3RoomAuthorityChain,
    baseMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    candidate: ClipLiveShareNativeV3RoomAuthorityChain
  ) -> Bool {
    guard
      candidate.foundingCreatorParticipantID
        == base.foundingCreatorParticipantID,
      candidate.foundingCreatorIdentity
        == base.foundingCreatorIdentity,
      candidate.genesisMembership == base.genesisMembership,
      candidate.checkpoints.count >= base.checkpoints.count,
      Array(candidate.checkpoints.prefix(base.checkpoints.count))
        == base.checkpoints
    else { return false }

    if candidate.checkpoints.count == base.checkpoints.count {
      return candidate.currentTerm == base.currentTerm
        && candidate.currentLeaderParticipantID
          == base.currentLeaderParticipantID
        && candidate.currentLeaderIdentity
          == base.currentLeaderIdentity
        && candidate.currentMembership.snapshot.membershipRevision
          > baseMembership.snapshot.membershipRevision
    }

    let authorityBridgeMembership =
      base.checkpoints.last?.successorMembership
        ?? base.genesisMembership
    let expectedPredecessor =
      baseMembership == authorityBridgeMembership
        ? nil
        : baseMembership
    return candidate.checkpoints[base.checkpoints.count]
      .predecessorMembership == expectedPredecessor
  }

  private func validateAdmissionLimit(
    in chain: ClipLiveShareNativeV3RoomAuthorityChain
  ) throws {
    var memberships = [chain.genesisMembership]
    for checkpoint in chain.checkpoints {
      if let predecessor = checkpoint.predecessorMembership {
        memberships.append(predecessor)
      }
      memberships.append(checkpoint.successorMembership)
    }
    if let latest = chain.latestMembership {
      memberships.append(latest)
    }
    for membership in memberships where
      membership.snapshot.participants.count
        > admissionPolicy.maximumParticipants
    {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: admissionPolicy.maximumParticipants,
        actual: membership.snapshot.participants.count
      )
    }
  }

  private func requireNotEnded() throws {
    guard phase != .ended else {
      throw ClipLiveShareNativeV3RoomLifecycleError.roomEnded
    }
  }

  private func requireActive() throws {
    try requireNotEnded()
    guard phase == .active else {
      throw ClipLiveShareNativeV3RoomLifecycleError.invalidPhase(
        expected: .active,
        actual: phase
      )
    }
  }

  private func deterministicSuccessor()
    -> ClipLiveShareNativeV3ParticipantID?
  {
    participantIDs
      .subtracting([currentLeaderParticipantID])
      .min()
  }

  private func deterministicReadySuccessor()
    -> ClipLiveShareNativeV3ParticipantID?
  {
    establishedPeerParticipantIDs
      .intersection(participantIDs)
      .subtracting([currentLeaderParticipantID])
      .min()
  }

  private func nextLeadershipTerm() throws
    -> ClipLiveShareNativeV3LeadershipTerm
  {
    let (rawValue, overflow) = currentTerm.rawValue.addingReportingOverflow(1)
    guard !overflow else {
      throw ClipLiveShareNativeV3Error.invalidLeadershipTerm
    }
    return try ClipLiveShareNativeV3LeadershipTerm(rawValue: rawValue)
  }

  private func nextMembershipRevision() throws
    -> ClipLiveShareNativeV3MembershipRevision
  {
    let (rawValue, overflow) =
      signedMembership.snapshot.membershipRevision.rawValue
      .addingReportingOverflow(1)
    guard !overflow else {
      throw ClipLiveShareNativeV3Error.invalidRevision(name: "membership")
    }
    return try ClipLiveShareNativeV3MembershipRevision(rawValue: rawValue)
  }

  private func requiredLocalPeers(
    for participantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  ) -> [ClipLiveShareNativeV3ParticipantID] {
    participantIDs
      .subtracting([localParticipantID])
      .subtracting(establishedPeerParticipantIDs)
      .sorted()
  }

  private func validateStableIdentities(
    _ incoming: ClipLiveShareNativeV3MembershipSnapshot
  ) throws {
    let previous = Dictionary(
      uniqueKeysWithValues: signedMembership.snapshot.participants.map {
        ($0.participantID, $0.identity)
      }
    )
    for participant in incoming.participants {
      if let identity = previous[participant.participantID],
        identity != participant.identity
      {
        throw ClipLiveShareNativeV3Error.participantIdentityChanged(
          participant.participantID
        )
      }
    }
  }

  private func makeSignedMembership(
    participants: [ClipLiveShareNativeV3Participant],
    leaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    leaderIdentity: ClipLiveShareIdentityPublicKey,
    signer: any ClipLiveShareIdentitySigner,
    revision: ClipLiveShareNativeV3MembershipRevision,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> ClipLiveShareSignedNativeV3MembershipSnapshot {
    guard participants.count <= admissionPolicy.maximumParticipants else {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: admissionPolicy.maximumParticipants,
        actual: participants.count
      )
    }
    let snapshotExpiry = try now.adding(milliseconds: 120_000)
    let credentialExpiry = try now.adding(milliseconds: 180_000)
    let credentials = try participants.map { participant in
      let credential = try ClipLiveShareNativeV3MembershipCredential(
        sessionID: sessionID,
        leaderParticipantID: leaderParticipantID,
        leaderIdentity: leaderIdentity,
        participant: participant,
        membershipRevision: revision,
        issuedAt: now,
        expiresAt: credentialExpiry
      )
      return try ClipLiveShareSignedNativeV3MembershipCredential(
        signing: credential,
        with: signer
      )
    }
    let snapshot = try ClipLiveShareNativeV3MembershipSnapshot(
      sessionID: sessionID,
      leaderParticipantID: leaderParticipantID,
      leaderIdentity: leaderIdentity,
      membershipRevision: revision,
      credentials: credentials,
      issuedAt: now,
      expiresAt: snapshotExpiry,
      maximumParticipants: admissionPolicy.maximumParticipants
    )
    return try ClipLiveShareSignedNativeV3MembershipSnapshot(
      signing: snapshot,
      with: signer
    )
  }

  private mutating func authorAndAcceptLocalProposal(
    reason: ClipLiveShareNativeV3LeadershipTransitionReason,
    transferRequest: ClipLiveShareSignedNativeV3LeadershipTransferRequest?,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> [ClipLiveShareNativeV3RoomLifecycleEvent] {
    guard localParticipantID == pendingElection?.candidateParticipantID else {
      throw ClipLiveShareNativeV3RoomLifecycleError.localParticipantIsNotCandidate
    }
    let proposal = try ClipLiveShareNativeV3LeadershipProposal(
      sessionID: sessionID,
      term: nextLeadershipTerm(),
      reason: reason,
      previousLeaderParticipantID: currentLeaderParticipantID,
      candidateParticipantID: localParticipantID,
      candidateIdentity: localIdentity,
      lastCommittedMembershipRevision:
        signedMembership.snapshot.membershipRevision,
      lastCommittedMembershipDigest: signedMembership.snapshot.digest,
      transferRequestDigest: transferRequest?.request.digest,
      electorate: participantIDs,
      issuedAt: now,
      expiresAt: now.adding(
        milliseconds:
          ClipLiveShareNativeV3.maximumLeadershipProposalLifetimeMilliseconds
      )
    )
    let signed = try ClipLiveShareSignedNativeV3LeadershipProposal(
      signing: proposal,
      with: localSigner
    )
    let voteEvents = try receiveLeadershipProposal(signed, at: now)
    return [.broadcastLeadershipProposal(signed)] + voteEvents
  }

  private func validateProposal(
    _ signedProposal: ClipLiveShareSignedNativeV3LeadershipProposal,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try signedProposal.verifyCandidateSignature()
    let proposal = signedProposal.proposal
    let expectedTerm = try nextLeadershipTerm()
    guard
      proposal.sessionID == sessionID,
      proposal.term == expectedTerm,
      proposal.previousLeaderParticipantID == currentLeaderParticipantID,
      proposal.lastCommittedMembershipRevision
        == signedMembership.snapshot.membershipRevision,
      proposal.lastCommittedMembershipDigest == signedMembership.snapshot.digest,
      Set(proposal.electorate) == participantIDs,
      proposal.candidateParticipantID == expectedCandidate(for: proposal.reason),
      let candidate = signedMembership.snapshot.participants.first(where: {
        $0.participantID == proposal.candidateParticipantID
      }),
      candidate.identity == proposal.candidateIdentity
    else {
      throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
    }
    try validateNativeV3ValidityWindow(
      issuedAt: proposal.issuedAt,
      expiresAt: proposal.expiresAt,
      now: now
    )
    guard let pendingElection else {
      throw ClipLiveShareNativeV3RoomLifecycleError.invalidPhase(
        expected: .electing,
        actual: phase
      )
    }
    guard
      pendingElection.reason == proposal.reason,
      pendingElection.candidateParticipantID == proposal.candidateParticipantID,
      pendingElection.reachableParticipantIDs.count
        >= ClipLiveShareNativeV3LeadershipCertificate.requiredQuorum(
          participantCount: participantIDs.count
        )
    else {
      throw ClipLiveShareNativeV3RoomLifecycleError.conflictingElection
    }
    switch proposal.reason {
    case .gracefulTransfer:
      guard
        let request = pendingElection.transferRequest,
        proposal.transferRequestDigest == request.request.digest
      else {
        throw ClipLiveShareNativeV3RoomLifecycleError
          .missingLeadershipTransferRequest
      }
    case .recoveryElection:
      guard
        proposal.transferRequestDigest == nil,
        !pendingElection.reachableParticipantIDs
          .contains(currentLeaderParticipantID)
      else {
        throw ClipLiveShareNativeV3RoomLifecycleError.conflictingElection
      }
    }
  }

  private func expectedCandidate(
    for reason: ClipLiveShareNativeV3LeadershipTransitionReason
  ) -> ClipLiveShareNativeV3ParticipantID? {
    switch reason {
    case .gracefulTransfer:
      pendingElection?.transferRequest?.request.successorParticipantID
    case .recoveryElection:
      deterministicSuccessor()
    }
  }
}
