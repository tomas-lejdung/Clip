import Foundation

/// A signed request from an ordinary participant asking the current leader to
/// remove it from the committed membership.
///
/// The request is bound to the exact leader term and membership snapshot. It
/// does not remove the sender by itself: the leader validates it, commits the
/// next signed membership, and the requester closes only after applying that
/// authoritative removal. A stale request therefore cannot remove a later
/// rejoined participant or mutate a successor's room.
public struct ClipLiveShareNativeV3ParticipantLeaveRequest: Codable, Equatable,
  Hashable, Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let leaderTerm: ClipLiveShareNativeV3LeadershipTerm
  public let leaderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let membershipRevision: ClipLiveShareNativeV3MembershipRevision
  public let membershipDigest: ClipLiveShareNativeDigest
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let participantIdentity: ClipLiveShareIdentityPublicKey
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    sessionID: ClipLiveShareSessionID,
    leaderTerm: ClipLiveShareNativeV3LeadershipTerm,
    leaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    membershipRevision: ClipLiveShareNativeV3MembershipRevision,
    membershipDigest: ClipLiveShareNativeDigest,
    participantID: ClipLiveShareNativeV3ParticipantID,
    participantIdentity: ClipLiveShareIdentityPublicKey,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    guard participantID != leaderParticipantID else {
      throw ClipLiveShareNativeV3Error.invalidLeader
    }
    try validateNativeV3Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds:
        ClipLiveShareNativeV3.maximumParticipantLeaveRequestLifetimeMilliseconds
    )
    self.sessionID = sessionID
    self.leaderTerm = leaderTerm
    self.leaderParticipantID = leaderParticipantID
    self.membershipRevision = membershipRevision
    self.membershipDigest = membershipDigest
    self.participantID = participantID
    self.participantIdentity = participantIdentity
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/participant-leave-request"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(leaderTerm.rawValue)
    encoder.append(leaderParticipantID.bytes)
    encoder.append(membershipRevision.rawValue)
    encoder.append(membershipDigest.bytes)
    encoder.append(participantID.bytes)
    encoder.append(participantIdentity.x963Representation)
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case leaderTerm
    case leaderParticipantID = "leaderParticipantId"
    case membershipRevision
    case membershipDigest
    case participantID = "participantId"
    case participantIdentity
    case issuedAt
    case expiresAt
  }
}

public struct ClipLiveShareSignedNativeV3ParticipantLeaveRequest: Codable,
  Equatable, Hashable, Sendable
{
  public let request: ClipLiveShareNativeV3ParticipantLeaveRequest
  public let signature: ClipLiveShareIdentitySignature

  public init(
    request: ClipLiveShareNativeV3ParticipantLeaveRequest,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.request = request
    self.signature = signature
  }

  public init(
    signing request: ClipLiveShareNativeV3ParticipantLeaveRequest,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    guard signer.publicKey == request.participantIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.request = request
    signature = try signer.signature(for: request.canonicalRepresentation)
  }

  public func verify(
    against membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    expectedLeaderTerm: ClipLiveShareNativeV3LeadershipTerm,
    expectedLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    expectedLeaderIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    let snapshot = membership.snapshot
    try membership.verifyAsEstablished(
      expectedSessionID: snapshot.sessionID,
      expectedLeaderParticipantID: expectedLeaderParticipantID,
      expectedLeaderIdentity: expectedLeaderIdentity
    )
    guard
      request.sessionID == snapshot.sessionID,
      request.leaderTerm == expectedLeaderTerm,
      request.leaderParticipantID == expectedLeaderParticipantID,
      request.membershipRevision == snapshot.membershipRevision,
      request.membershipDigest == snapshot.digest,
      request.participantID != expectedLeaderParticipantID,
      snapshot.participants.contains(where: {
        $0.participantID == request.participantID
          && $0.identity == request.participantIdentity
      })
    else {
      throw ClipLiveShareNativeV3Error.contextMismatch
    }
    try validateNativeV3ValidityWindow(
      issuedAt: request.issuedAt,
      expiresAt: request.expiresAt,
      now: now
    )
    guard
      request.participantIdentity.isValidSignature(
        signature,
        for: request.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

public struct ClipLiveShareNativeV3RoomTerminationRevision: Codable, Equatable, Hashable,
  Comparable, Sendable
{
  public let rawValue: UInt64

  public init(rawValue: UInt64) throws {
    guard rawValue > 0 else {
      throw ClipLiveShareNativeV3Error.invalidRevision(name: "room termination")
    }
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(UInt64.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum ClipLiveShareNativeV3RoomTerminationReason: String, Codable, Equatable,
  Hashable, Sendable
{
  case endedByLeader = "ended-by-leader"
  case expired = "expired"
  case securityRevocation = "security-revocation"
}

/// Terminal leader assertion used by "End Room for Everyone". Ordinary leave
/// is not terminal and must never be encoded as this message.
public struct ClipLiveShareNativeV3RoomTermination: Codable, Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let leaderTerm: ClipLiveShareNativeV3LeadershipTerm
  public let leaderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let leaderIdentity: ClipLiveShareIdentityPublicKey
  public let membershipRevision: ClipLiveShareNativeV3MembershipRevision
  public let membershipDigest: ClipLiveShareNativeDigest
  public let terminationRevision: ClipLiveShareNativeV3RoomTerminationRevision
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let reason: ClipLiveShareNativeV3RoomTerminationReason

  public init(
    sessionID: ClipLiveShareSessionID,
    leaderTerm: ClipLiveShareNativeV3LeadershipTerm,
    leaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    leaderIdentity: ClipLiveShareIdentityPublicKey,
    membershipRevision: ClipLiveShareNativeV3MembershipRevision,
    membershipDigest: ClipLiveShareNativeDigest,
    terminationRevision: ClipLiveShareNativeV3RoomTerminationRevision,
    issuedAt: ClipLiveShareNativeTimestamp,
    reason: ClipLiveShareNativeV3RoomTerminationReason
  ) {
    self.sessionID = sessionID
    self.leaderTerm = leaderTerm
    self.leaderParticipantID = leaderParticipantID
    self.leaderIdentity = leaderIdentity
    self.membershipRevision = membershipRevision
    self.membershipDigest = membershipDigest
    self.terminationRevision = terminationRevision
    self.issuedAt = issuedAt
    self.reason = reason
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/room-termination"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(leaderTerm.rawValue)
    encoder.append(leaderParticipantID.bytes)
    encoder.append(leaderIdentity.x963Representation)
    encoder.append(membershipRevision.rawValue)
    encoder.append(membershipDigest.bytes)
    encoder.append(terminationRevision.rawValue)
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(reason.rawValue)
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case leaderTerm
    case leaderParticipantID = "leaderParticipantId"
    case leaderIdentity
    case membershipRevision
    case membershipDigest
    case terminationRevision
    case issuedAt
    case reason
  }
}

public struct ClipLiveShareSignedNativeV3RoomTermination: Codable, Equatable, Hashable,
  Sendable
{
  public let termination: ClipLiveShareNativeV3RoomTermination
  public let signature: ClipLiveShareIdentitySignature

  public init(
    termination: ClipLiveShareNativeV3RoomTermination,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.termination = termination
    self.signature = signature
  }

  public init(
    signing termination: ClipLiveShareNativeV3RoomTermination,
    with leaderSigner: any ClipLiveShareIdentitySigner
  ) throws {
    guard leaderSigner.publicKey == termination.leaderIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.termination = termination
    signature = try leaderSigner.signature(for: termination.canonicalRepresentation)
  }

  public func verify(
    against membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    expectedLeaderTerm: ClipLiveShareNativeV3LeadershipTerm,
    expectedLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    expectedLeaderIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    let snapshot = membership.snapshot
    try membership.verifyAsEstablished(
      expectedSessionID: snapshot.sessionID,
      expectedLeaderParticipantID: expectedLeaderParticipantID,
      expectedLeaderIdentity: expectedLeaderIdentity
    )
    guard
      termination.sessionID == snapshot.sessionID,
      termination.leaderTerm == expectedLeaderTerm,
      termination.leaderParticipantID == expectedLeaderParticipantID,
      termination.leaderIdentity == expectedLeaderIdentity,
      termination.membershipRevision == snapshot.membershipRevision,
      termination.membershipDigest == snapshot.digest
    else {
      throw ClipLiveShareNativeV3Error.contextMismatch
    }
    let (latestAllowed, overflow) = now.millisecondsSince1970.addingReportingOverflow(
      ClipLiveShareNativeV3.maximumClockSkewMilliseconds
    )
    guard overflow || termination.issuedAt.millisecondsSince1970 <= latestAllowed else {
      throw ClipLiveShareNativeV3Error.notYetValid
    }
    let (latestFreshTime, freshnessOverflow) =
      termination.issuedAt.millisecondsSince1970.addingReportingOverflow(
        ClipLiveShareNativeV3.maximumParticipantLeaveRequestLifetimeMilliseconds
      )
    guard
      !freshnessOverflow,
      now.millisecondsSince1970 < latestFreshTime
    else {
      throw ClipLiveShareNativeV3Error.expired
    }
    guard
      expectedLeaderIdentity.isValidSignature(
        signature,
        for: termination.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

public struct ClipLiveShareNativeV3RoomTerminationLedger: Equatable, Sendable {
  public private(set) var latestAcceptedRevision:
    ClipLiveShareNativeV3RoomTerminationRevision?

  public init(
    latestAcceptedRevision: ClipLiveShareNativeV3RoomTerminationRevision? = nil
  ) {
    self.latestAcceptedRevision = latestAcceptedRevision
  }

  public mutating func accept(
    _ revision: ClipLiveShareNativeV3RoomTerminationRevision
  ) throws {
    if let latestAcceptedRevision, revision <= latestAcceptedRevision {
      throw ClipLiveShareNativeV3Error.staleRoomTerminationRevision(
        expectedGreaterThan: latestAcceptedRevision.rawValue,
        actual: revision.rawValue
      )
    }
    latestAcceptedRevision = revision
  }
}

/// One certified leader transition and the first membership snapshot signed by
/// that successor.
///
/// `predecessorMembership` is present when the current leader admitted or
/// removed participants after the previous authority checkpoint. A leadership
/// certificate is bound to that exact latest membership digest, not
/// necessarily to the first snapshot signed by the current leader.
public struct ClipLiveShareNativeV3AuthorityCheckpoint: Codable, Equatable, Hashable,
  Sendable
{
  public let predecessorMembership:
    ClipLiveShareSignedNativeV3MembershipSnapshot?
  public let certificate: ClipLiveShareNativeV3LeadershipCertificate
  public let successorMembership: ClipLiveShareSignedNativeV3MembershipSnapshot

  public init(
    predecessorMembership:
      ClipLiveShareSignedNativeV3MembershipSnapshot? = nil,
    certificate: ClipLiveShareNativeV3LeadershipCertificate,
    successorMembership: ClipLiveShareSignedNativeV3MembershipSnapshot
  ) {
    self.predecessorMembership = predecessorMembership
    self.certificate = certificate
    self.successorMembership = successorMembership
  }
}

/// Bounded proof from the creator identity embedded in the invite to the
/// current leader.
///
/// Ordinary membership commits and authority transitions are separate:
///
/// - a leader may issue newer membership snapshots while retaining its term;
/// - a checkpoint certifies a transition against the exact latest snapshot
///   named by its certificate; and
/// - `latestMembership` carries admissions/removals performed after the final
///   transition.
///
/// This prevents a late join from seeing only the genesis/bridge membership,
/// and lets a leader be replaced after ordinary joins without pretending the
/// older checkpoint membership was still current. Historical checkpoints are
/// verified at their transition timestamps; only the latest membership must
/// still be fresh at join time.
public struct ClipLiveShareNativeV3RoomAuthorityChain: Codable, Equatable, Hashable,
  Sendable
{
  public let foundingCreatorParticipantID: ClipLiveShareNativeV3ParticipantID
  public let foundingCreatorIdentity: ClipLiveShareIdentityPublicKey
  public let genesisMembership: ClipLiveShareSignedNativeV3MembershipSnapshot
  public let checkpoints: [ClipLiveShareNativeV3AuthorityCheckpoint]
  public let latestMembership:
    ClipLiveShareSignedNativeV3MembershipSnapshot?

  public init(
    foundingCreatorParticipantID: ClipLiveShareNativeV3ParticipantID,
    foundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
    genesisMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    checkpoints: [ClipLiveShareNativeV3AuthorityCheckpoint],
    latestMembership:
      ClipLiveShareSignedNativeV3MembershipSnapshot? = nil
  ) throws {
    guard checkpoints.count <= ClipLiveShareNativeV3.maximumAuthorityTransitions else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 authority chain exceeds its transition limit"
      )
    }
    self.foundingCreatorParticipantID = foundingCreatorParticipantID
    self.foundingCreatorIdentity = foundingCreatorIdentity
    self.genesisMembership = genesisMembership
    self.checkpoints = checkpoints
    self.latestMembership = latestMembership
  }

  public var currentMembership: ClipLiveShareSignedNativeV3MembershipSnapshot {
    latestMembership
      ?? checkpoints.last?.successorMembership
      ?? genesisMembership
  }

  public var currentTerm: ClipLiveShareNativeV3LeadershipTerm {
    if let last = checkpoints.last {
      return last.certificate.term
    }
    return try! ClipLiveShareNativeV3LeadershipTerm(rawValue: 1)
  }

  public var currentLeaderParticipantID: ClipLiveShareNativeV3ParticipantID {
    currentMembership.snapshot.leaderParticipantID
  }

  public var currentLeaderIdentity: ClipLiveShareIdentityPublicKey {
    currentMembership.snapshot.leaderIdentity
  }

  public func verify(
    expectedSessionID: ClipLiveShareSessionID,
    expectedFoundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
    localCapabilities: ClipLiveShareNativeV3Capabilities = .current,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    guard
      foundingCreatorIdentity == expectedFoundingCreatorIdentity,
      genesisMembership.snapshot.sessionID == expectedSessionID,
      genesisMembership.snapshot.leaderParticipantID
        == foundingCreatorParticipantID,
      genesisMembership.snapshot.leaderIdentity == foundingCreatorIdentity
    else {
      throw ClipLiveShareNativeV3Error.invalidAuthorityChain
    }
    try genesisMembership.verify(
      expectedSessionID: expectedSessionID,
      expectedLeaderParticipantID: foundingCreatorParticipantID,
      expectedLeaderIdentity: foundingCreatorIdentity,
      localCapabilities: localCapabilities,
      at: genesisMembership.snapshot.issuedAt
    )

    var previous = genesisMembership
    var term = try ClipLiveShareNativeV3LeadershipTerm(rawValue: 1)
    var leaderParticipantID = foundingCreatorParticipantID
    var leaderIdentity = foundingCreatorIdentity
    for checkpoint in checkpoints {
      let proposalIssuedAt =
        checkpoint.certificate.signedProposal.proposal.issuedAt
      if let explicitPredecessor = checkpoint.predecessorMembership {
        try Self.verifyMembershipUpdate(
          explicitPredecessor,
          after: previous,
          expectedSessionID: expectedSessionID,
          expectedLeaderParticipantID: leaderParticipantID,
          expectedLeaderIdentity: leaderIdentity,
          localCapabilities: localCapabilities,
          at: proposalIssuedAt
        )
        previous = explicitPredecessor
      }
      let successorIssuedAt = checkpoint.successorMembership.snapshot.issuedAt
      let transitionTime = max(proposalIssuedAt, successorIssuedAt)
      try checkpoint.certificate.verifySuccessorMembership(
        checkpoint.successorMembership,
        after: previous,
        currentTerm: term,
        currentLeaderParticipantID: leaderParticipantID,
        currentLeaderIdentity: leaderIdentity,
        at: transitionTime
      )
      previous = checkpoint.successorMembership
      term = checkpoint.certificate.term
      leaderParticipantID = checkpoint.certificate.newLeaderParticipantID
      leaderIdentity = checkpoint.certificate.newLeaderIdentity
    }

    if let latestMembership {
      try Self.verifyMembershipUpdate(
        latestMembership,
        after: previous,
        expectedSessionID: expectedSessionID,
        expectedLeaderParticipantID: leaderParticipantID,
        expectedLeaderIdentity: leaderIdentity,
        localCapabilities: localCapabilities,
        at: now
      )
    } else {
      try previous.verify(
        expectedSessionID: expectedSessionID,
        expectedLeaderParticipantID: leaderParticipantID,
        expectedLeaderIdentity: leaderIdentity,
        localCapabilities: localCapabilities,
        at: now
      )
    }
  }

  private static func verifyMembershipUpdate(
    _ incoming: ClipLiveShareSignedNativeV3MembershipSnapshot,
    after previous: ClipLiveShareSignedNativeV3MembershipSnapshot,
    expectedSessionID: ClipLiveShareSessionID,
    expectedLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    expectedLeaderIdentity: ClipLiveShareIdentityPublicKey,
    localCapabilities: ClipLiveShareNativeV3Capabilities,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try incoming.verify(
      expectedSessionID: expectedSessionID,
      expectedLeaderParticipantID: expectedLeaderParticipantID,
      expectedLeaderIdentity: expectedLeaderIdentity,
      localCapabilities: localCapabilities,
      at: now
    )
    if incoming != previous {
      guard
        incoming.snapshot.membershipRevision
          > previous.snapshot.membershipRevision
      else {
        throw ClipLiveShareNativeV3Error.invalidAuthorityChain
      }
    }
    let previousIdentities = Dictionary(
      uniqueKeysWithValues: previous.snapshot.participants.map {
        ($0.participantID, $0.identity)
      }
    )
    for participant in incoming.snapshot.participants {
      if let previousIdentity =
        previousIdentities[participant.participantID],
        previousIdentity != participant.identity
      {
        throw ClipLiveShareNativeV3Error.participantIdentityChanged(
          participant.participantID
        )
      }
    }
  }
}
