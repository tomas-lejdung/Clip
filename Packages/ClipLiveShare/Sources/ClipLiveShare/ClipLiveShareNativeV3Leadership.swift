import Foundation

public struct ClipLiveShareNativeV3LeadershipTerm: Codable, Equatable, Hashable, Comparable,
  Sendable
{
  public let rawValue: UInt64

  public init(rawValue: UInt64) throws {
    guard rawValue > 0 else {
      throw ClipLiveShareNativeV3Error.invalidLeadershipTerm
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

public enum ClipLiveShareNativeV3LeadershipTransitionReason: String, Codable, Equatable,
  Hashable, Sendable
{
  /// The current leader is still connected and votes for its successor before
  /// leaving.
  case gracefulTransfer = "graceful-transfer"
  /// The current leader disappeared and the surviving majority elects a
  /// successor from the last committed membership.
  case recoveryElection = "recovery-election"
}

/// A graceful transfer starts with this old-leader-signed intent. Candidate
/// proposals bind its digest, so a participant can distinguish a deliberate
/// handoff from an attacker merely requesting votes for a new term.
public struct ClipLiveShareNativeV3LeadershipTransferRequest: Codable, Equatable, Hashable,
  Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let currentTerm: ClipLiveShareNativeV3LeadershipTerm
  public let nextTerm: ClipLiveShareNativeV3LeadershipTerm
  public let currentLeaderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let currentLeaderIdentity: ClipLiveShareIdentityPublicKey
  public let successorParticipantID: ClipLiveShareNativeV3ParticipantID
  public let lastCommittedMembershipRevision: ClipLiveShareNativeV3MembershipRevision
  public let lastCommittedMembershipDigest: ClipLiveShareNativeDigest
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    sessionID: ClipLiveShareSessionID,
    currentTerm: ClipLiveShareNativeV3LeadershipTerm,
    nextTerm: ClipLiveShareNativeV3LeadershipTerm,
    currentLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    currentLeaderIdentity: ClipLiveShareIdentityPublicKey,
    successorParticipantID: ClipLiveShareNativeV3ParticipantID,
    lastCommittedMembershipRevision: ClipLiveShareNativeV3MembershipRevision,
    lastCommittedMembershipDigest: ClipLiveShareNativeDigest,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    let (expectedNextTerm, overflow) = currentTerm.rawValue.addingReportingOverflow(1)
    guard
      !overflow,
      nextTerm.rawValue == expectedNextTerm,
      successorParticipantID != currentLeaderParticipantID
    else {
      throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
    }
    try validateNativeV3Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds:
        ClipLiveShareNativeV3.maximumLeadershipProposalLifetimeMilliseconds
    )
    self.sessionID = sessionID
    self.currentTerm = currentTerm
    self.nextTerm = nextTerm
    self.currentLeaderParticipantID = currentLeaderParticipantID
    self.currentLeaderIdentity = currentLeaderIdentity
    self.successorParticipantID = successorParticipantID
    self.lastCommittedMembershipRevision = lastCommittedMembershipRevision
    self.lastCommittedMembershipDigest = lastCommittedMembershipDigest
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/leadership-transfer-request"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(currentTerm.rawValue)
    encoder.append(nextTerm.rawValue)
    encoder.append(currentLeaderParticipantID.bytes)
    encoder.append(currentLeaderIdentity.x963Representation)
    encoder.append(successorParticipantID.bytes)
    encoder.append(lastCommittedMembershipRevision.rawValue)
    encoder.append(lastCommittedMembershipDigest.bytes)
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case currentTerm
    case nextTerm
    case currentLeaderParticipantID = "currentLeaderParticipantId"
    case currentLeaderIdentity
    case successorParticipantID = "successorParticipantId"
    case lastCommittedMembershipRevision
    case lastCommittedMembershipDigest
    case issuedAt
    case expiresAt
  }
}

public struct ClipLiveShareSignedNativeV3LeadershipTransferRequest: Codable, Equatable,
  Hashable, Sendable
{
  public let request: ClipLiveShareNativeV3LeadershipTransferRequest
  public let signature: ClipLiveShareIdentitySignature

  public init(
    request: ClipLiveShareNativeV3LeadershipTransferRequest,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.request = request
    self.signature = signature
  }

  public init(
    signing request: ClipLiveShareNativeV3LeadershipTransferRequest,
    with leaderSigner: any ClipLiveShareIdentitySigner
  ) throws {
    guard leaderSigner.publicKey == request.currentLeaderIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.request = request
    signature = try leaderSigner.signature(for: request.canonicalRepresentation)
  }

  public func verify(
    lastCommittedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    currentTerm: ClipLiveShareNativeV3LeadershipTerm,
    currentLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    currentLeaderIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    let snapshot = lastCommittedMembership.snapshot
    try lastCommittedMembership.verifyAsEstablished(
      expectedSessionID: snapshot.sessionID,
      expectedLeaderParticipantID: currentLeaderParticipantID,
      expectedLeaderIdentity: currentLeaderIdentity
    )
    guard
      request.sessionID == snapshot.sessionID,
      request.currentTerm == currentTerm,
      request.currentLeaderParticipantID == currentLeaderParticipantID,
      request.currentLeaderIdentity == currentLeaderIdentity,
      request.lastCommittedMembershipRevision == snapshot.membershipRevision,
      request.lastCommittedMembershipDigest == snapshot.digest,
      snapshot.participantIDs.contains(request.successorParticipantID)
    else {
      throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
    }
    try validateNativeV3ValidityWindow(
      issuedAt: request.issuedAt,
      expiresAt: request.expiresAt,
      now: now
    )
    guard
      currentLeaderIdentity.isValidSignature(
        signature,
        for: request.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

/// Candidate-authored statement for the next leadership term. It is bound to
/// the exact last committed membership digest and its complete electorate, so
/// votes cannot be replayed after any join, removal, or identity change.
public struct ClipLiveShareNativeV3LeadershipProposal: Codable, Equatable, Hashable,
  Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let term: ClipLiveShareNativeV3LeadershipTerm
  public let reason: ClipLiveShareNativeV3LeadershipTransitionReason
  public let previousLeaderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let candidateParticipantID: ClipLiveShareNativeV3ParticipantID
  public let candidateIdentity: ClipLiveShareIdentityPublicKey
  public let lastCommittedMembershipRevision: ClipLiveShareNativeV3MembershipRevision
  public let lastCommittedMembershipDigest: ClipLiveShareNativeDigest
  public let transferRequestDigest: ClipLiveShareNativeDigest?
  public let electorate: [ClipLiveShareNativeV3ParticipantID]
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    sessionID: ClipLiveShareSessionID,
    term: ClipLiveShareNativeV3LeadershipTerm,
    reason: ClipLiveShareNativeV3LeadershipTransitionReason,
    previousLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    candidateParticipantID: ClipLiveShareNativeV3ParticipantID,
    candidateIdentity: ClipLiveShareIdentityPublicKey,
    lastCommittedMembershipRevision: ClipLiveShareNativeV3MembershipRevision,
    lastCommittedMembershipDigest: ClipLiveShareNativeDigest,
    transferRequestDigest: ClipLiveShareNativeDigest? = nil,
    electorate: Set<ClipLiveShareNativeV3ParticipantID>,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    guard
      !electorate.isEmpty,
      electorate.count <= ClipLiveShareNativeV3.maximumProtocolParticipants
    else {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: ClipLiveShareNativeV3.maximumProtocolParticipants,
        actual: electorate.count
      )
    }
    guard
      previousLeaderParticipantID != candidateParticipantID,
      electorate.contains(previousLeaderParticipantID),
      electorate.contains(candidateParticipantID),
      (reason == .gracefulTransfer) == (transferRequestDigest != nil)
    else {
      throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
    }
    try validateNativeV3Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds:
        ClipLiveShareNativeV3.maximumLeadershipProposalLifetimeMilliseconds
    )
    self.sessionID = sessionID
    self.term = term
    self.reason = reason
    self.previousLeaderParticipantID = previousLeaderParticipantID
    self.candidateParticipantID = candidateParticipantID
    self.candidateIdentity = candidateIdentity
    self.lastCommittedMembershipRevision = lastCommittedMembershipRevision
    self.lastCommittedMembershipDigest = lastCommittedMembershipDigest
    self.transferRequestDigest = transferRequestDigest
    self.electorate = electorate.sorted()
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/leadership-proposal"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(term.rawValue)
    encoder.append(reason.rawValue)
    encoder.append(previousLeaderParticipantID.bytes)
    encoder.append(candidateParticipantID.bytes)
    encoder.append(candidateIdentity.x963Representation)
    encoder.append(lastCommittedMembershipRevision.rawValue)
    encoder.append(lastCommittedMembershipDigest.bytes)
    encoder.append(transferRequestDigest != nil)
    if let transferRequestDigest { encoder.append(transferRequestDigest.bytes) }
    encoder.append(UInt64(electorate.count))
    for participantID in electorate { encoder.append(participantID.bytes) }
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case term
    case reason
    case previousLeaderParticipantID = "previousLeaderParticipantId"
    case candidateParticipantID = "candidateParticipantId"
    case candidateIdentity
    case lastCommittedMembershipRevision
    case lastCommittedMembershipDigest
    case transferRequestDigest
    case electorate
    case issuedAt
    case expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let electorate = try container.decode(
      [ClipLiveShareNativeV3ParticipantID].self,
      forKey: .electorate
    )
    guard Set(electorate).count == electorate.count else {
      throw ClipLiveShareNativeV3Error.duplicateParticipant
    }
    try self.init(
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      term: container.decode(
        ClipLiveShareNativeV3LeadershipTerm.self,
        forKey: .term
      ),
      reason: container.decode(
        ClipLiveShareNativeV3LeadershipTransitionReason.self,
        forKey: .reason
      ),
      previousLeaderParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .previousLeaderParticipantID
      ),
      candidateParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .candidateParticipantID
      ),
      candidateIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .candidateIdentity
      ),
      lastCommittedMembershipRevision: container.decode(
        ClipLiveShareNativeV3MembershipRevision.self,
        forKey: .lastCommittedMembershipRevision
      ),
      lastCommittedMembershipDigest: container.decode(
        ClipLiveShareNativeDigest.self,
        forKey: .lastCommittedMembershipDigest
      ),
      transferRequestDigest: container.decodeIfPresent(
        ClipLiveShareNativeDigest.self,
        forKey: .transferRequestDigest
      ),
      electorate: Set(electorate),
      issuedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .issuedAt),
      expiresAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .expiresAt)
    )
  }
}

public struct ClipLiveShareSignedNativeV3LeadershipProposal: Codable, Equatable, Hashable,
  Sendable
{
  public let proposal: ClipLiveShareNativeV3LeadershipProposal
  public let signature: ClipLiveShareIdentitySignature

  public init(
    proposal: ClipLiveShareNativeV3LeadershipProposal,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.proposal = proposal
    self.signature = signature
  }

  public init(
    signing proposal: ClipLiveShareNativeV3LeadershipProposal,
    with candidateSigner: any ClipLiveShareIdentitySigner
  ) throws {
    guard candidateSigner.publicKey == proposal.candidateIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.proposal = proposal
    signature = try candidateSigner.signature(for: proposal.canonicalRepresentation)
  }

  public func verifyCandidateSignature() throws {
    guard
      proposal.candidateIdentity.isValidSignature(
        signature,
        for: proposal.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

/// One participant's single vote for one candidate-authored proposal.
public struct ClipLiveShareNativeV3LeadershipVote: Codable, Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let term: ClipLiveShareNativeV3LeadershipTerm
  public let proposalDigest: ClipLiveShareNativeDigest
  public let candidateParticipantID: ClipLiveShareNativeV3ParticipantID
  public let lastCommittedMembershipDigest: ClipLiveShareNativeDigest
  public let voterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let voterIdentity: ClipLiveShareIdentityPublicKey

  public init(
    proposal: ClipLiveShareNativeV3LeadershipProposal,
    voterParticipantID: ClipLiveShareNativeV3ParticipantID,
    voterIdentity: ClipLiveShareIdentityPublicKey
  ) throws {
    guard proposal.electorate.contains(voterParticipantID) else {
      throw ClipLiveShareNativeV3Error.unknownParticipant(voterParticipantID)
    }
    sessionID = proposal.sessionID
    term = proposal.term
    proposalDigest = proposal.digest
    candidateParticipantID = proposal.candidateParticipantID
    lastCommittedMembershipDigest = proposal.lastCommittedMembershipDigest
    self.voterParticipantID = voterParticipantID
    self.voterIdentity = voterIdentity
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/leadership-vote"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(term.rawValue)
    encoder.append(proposalDigest.bytes)
    encoder.append(candidateParticipantID.bytes)
    encoder.append(lastCommittedMembershipDigest.bytes)
    encoder.append(voterParticipantID.bytes)
    encoder.append(voterIdentity.x963Representation)
    return encoder.data
  }

  public func matches(_ proposal: ClipLiveShareNativeV3LeadershipProposal) -> Bool {
    sessionID == proposal.sessionID
      && term == proposal.term
      && proposalDigest == proposal.digest
      && candidateParticipantID == proposal.candidateParticipantID
      && lastCommittedMembershipDigest == proposal.lastCommittedMembershipDigest
      && proposal.electorate.contains(voterParticipantID)
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case term
    case proposalDigest
    case candidateParticipantID = "candidateParticipantId"
    case lastCommittedMembershipDigest
    case voterParticipantID = "voterParticipantId"
    case voterIdentity
  }
}

public struct ClipLiveShareSignedNativeV3LeadershipVote: Codable, Equatable, Hashable,
  Sendable
{
  public let vote: ClipLiveShareNativeV3LeadershipVote
  public let signature: ClipLiveShareIdentitySignature

  public init(
    vote: ClipLiveShareNativeV3LeadershipVote,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.vote = vote
    self.signature = signature
  }

  public init(
    signing vote: ClipLiveShareNativeV3LeadershipVote,
    with voterSigner: any ClipLiveShareIdentitySigner
  ) throws {
    guard voterSigner.publicKey == vote.voterIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.vote = vote
    signature = try voterSigner.signature(for: vote.canonicalRepresentation)
  }

  public func verify(
    proposal: ClipLiveShareNativeV3LeadershipProposal,
    participant: ClipLiveShareNativeV3Participant
  ) throws {
    guard vote.matches(proposal) else {
      throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
    }
    guard
      vote.voterParticipantID == participant.participantID,
      vote.voterIdentity == participant.identity
    else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    guard
      participant.identity.isValidSignature(
        signature,
        for: vote.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

/// Candidate proposal plus a strict-majority certificate from the exact last
/// committed membership. Majority intersection prevents two honest quorums
/// from electing different leaders in one term; `LeadershipVoteLedger`
/// prevents this participant from signing both sides of that intersection.
public struct ClipLiveShareNativeV3LeadershipCertificate: Codable, Equatable, Hashable,
  Sendable
{
  public let signedProposal: ClipLiveShareSignedNativeV3LeadershipProposal
  public let signedTransferRequest:
    ClipLiveShareSignedNativeV3LeadershipTransferRequest?
  public let votes: [ClipLiveShareSignedNativeV3LeadershipVote]

  public init(
    signedProposal: ClipLiveShareSignedNativeV3LeadershipProposal,
    signedTransferRequest:
      ClipLiveShareSignedNativeV3LeadershipTransferRequest? = nil,
    votes: [ClipLiveShareSignedNativeV3LeadershipVote]
  ) throws {
    guard
      Set(votes.map(\.vote.voterParticipantID)).count == votes.count
    else {
      throw ClipLiveShareNativeV3Error.duplicateLeadershipVote
    }
    self.signedProposal = signedProposal
    self.signedTransferRequest = signedTransferRequest
    self.votes = votes.sorted {
      $0.vote.voterParticipantID < $1.vote.voterParticipantID
    }
  }

  public var newLeaderParticipantID: ClipLiveShareNativeV3ParticipantID {
    signedProposal.proposal.candidateParticipantID
  }

  public var newLeaderIdentity: ClipLiveShareIdentityPublicKey {
    signedProposal.proposal.candidateIdentity
  }

  public var term: ClipLiveShareNativeV3LeadershipTerm {
    signedProposal.proposal.term
  }

  public static func requiredQuorum(participantCount: Int) -> Int {
    participantCount / 2 + 1
  }

  public func verify(
    lastCommittedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    currentTerm: ClipLiveShareNativeV3LeadershipTerm,
    currentLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    currentLeaderIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try lastCommittedMembership.verifyAsEstablished(
      expectedSessionID: lastCommittedMembership.snapshot.sessionID,
      expectedLeaderParticipantID: currentLeaderParticipantID,
      expectedLeaderIdentity: currentLeaderIdentity
    )
    let snapshot = lastCommittedMembership.snapshot
    let proposal = signedProposal.proposal
    let (expectedNextTerm, termOverflow) =
      currentTerm.rawValue.addingReportingOverflow(1)
    guard !termOverflow, proposal.term.rawValue == expectedNextTerm else {
      throw ClipLiveShareNativeV3Error.staleLeadershipTerm(
        expectedGreaterThan: currentTerm.rawValue,
        actual: proposal.term.rawValue
      )
    }
    guard
      proposal.sessionID == snapshot.sessionID,
      proposal.previousLeaderParticipantID == currentLeaderParticipantID,
      proposal.lastCommittedMembershipRevision == snapshot.membershipRevision,
      proposal.lastCommittedMembershipDigest == snapshot.digest,
      Set(proposal.electorate) == snapshot.participantIDs,
      let candidate = snapshot.participants.first(where: {
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
    try signedProposal.verifyCandidateSignature()

    let participants = Dictionary(
      uniqueKeysWithValues: snapshot.participants.map {
        ($0.participantID, $0)
      }
    )
    for signedVote in votes {
      guard let participant = participants[signedVote.vote.voterParticipantID] else {
        throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
      }
      try signedVote.verify(proposal: proposal, participant: participant)
    }
    guard votes.contains(where: {
      $0.vote.voterParticipantID == proposal.candidateParticipantID
    }) else {
      throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
    }
    if proposal.reason == .gracefulTransfer {
      guard
        let signedTransferRequest,
        proposal.transferRequestDigest == signedTransferRequest.request.digest,
        signedTransferRequest.request.nextTerm == proposal.term
      else {
        throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
      }
      try signedTransferRequest.verify(
        lastCommittedMembership: lastCommittedMembership,
        currentTerm: currentTerm,
        currentLeaderParticipantID: currentLeaderParticipantID,
        currentLeaderIdentity: currentLeaderIdentity,
        at: now
      )
      guard
        signedTransferRequest.request.successorParticipantID
          == proposal.candidateParticipantID,
        votes.contains(where: {
        $0.vote.voterParticipantID == currentLeaderParticipantID
      })
      else {
        throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
      }
    } else if signedTransferRequest != nil || proposal.transferRequestDigest != nil {
      throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
    }

    let required = Self.requiredQuorum(
      participantCount: snapshot.participants.count
    )
    guard votes.count >= required else {
      throw ClipLiveShareNativeV3Error.insufficientLeadershipQuorum(
        required: required,
        actual: votes.count
      )
    }
  }

  /// Verifies the first membership committed by the successor. That snapshot
  /// may remove unavailable members but cannot add or rebind identities during
  /// the authority transition; ordinary leader-signed revisions may do joins
  /// after this bridge snapshot is committed.
  public func verifySuccessorMembership(
    _ successor: ClipLiveShareSignedNativeV3MembershipSnapshot,
    after previous: ClipLiveShareSignedNativeV3MembershipSnapshot,
    currentTerm: ClipLiveShareNativeV3LeadershipTerm,
    currentLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    currentLeaderIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try verify(
      lastCommittedMembership: previous,
      currentTerm: currentTerm,
      currentLeaderParticipantID: currentLeaderParticipantID,
      currentLeaderIdentity: currentLeaderIdentity,
      at: now
    )
    try successor.verify(
      expectedSessionID: previous.snapshot.sessionID,
      expectedLeaderParticipantID: newLeaderParticipantID,
      expectedLeaderIdentity: newLeaderIdentity,
      at: now
    )
    guard
      successor.snapshot.membershipRevision
        > previous.snapshot.membershipRevision,
      successor.snapshot.participantIDs.contains(newLeaderParticipantID)
    else {
      throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
    }
    let previousIdentities = Dictionary(
      uniqueKeysWithValues: previous.snapshot.participants.map {
        ($0.participantID, $0.identity)
      }
    )
    for participant in successor.snapshot.participants {
      guard previousIdentities[participant.participantID] == participant.identity else {
        throw ClipLiveShareNativeV3Error.invalidLeadershipCertificate
      }
    }
  }
}

/// Local anti-equivocation state. A participant may sign at most one proposal
/// digest in each term, even if two candidates race after a leader loss.
public struct ClipLiveShareNativeV3LeadershipVoteLedger: Equatable, Sendable {
  public private(set) var committedTerm: ClipLiveShareNativeV3LeadershipTerm
  public private(set) var votedProposalDigests:
    [ClipLiveShareNativeV3LeadershipTerm: ClipLiveShareNativeDigest]

  public init(
    committedTerm: ClipLiveShareNativeV3LeadershipTerm,
    votedProposalDigests:
      [ClipLiveShareNativeV3LeadershipTerm: ClipLiveShareNativeDigest] = [:]
  ) {
    self.committedTerm = committedTerm
    self.votedProposalDigests = votedProposalDigests
  }

  public mutating func recordVote(
    for proposal: ClipLiveShareNativeV3LeadershipProposal
  ) throws {
    guard proposal.term > committedTerm else {
      throw ClipLiveShareNativeV3Error.staleLeadershipTerm(
        expectedGreaterThan: committedTerm.rawValue,
        actual: proposal.term.rawValue
      )
    }
    if let existing = votedProposalDigests[proposal.term] {
      guard existing == proposal.digest else {
        throw ClipLiveShareNativeV3Error.conflictingLeadershipVote
      }
      return
    }
    votedProposalDigests[proposal.term] = proposal.digest
  }

  public mutating func commit(
    _ certificate: ClipLiveShareNativeV3LeadershipCertificate
  ) throws {
    guard certificate.term > committedTerm else {
      throw ClipLiveShareNativeV3Error.staleLeadershipTerm(
        expectedGreaterThan: committedTerm.rawValue,
        actual: certificate.term.rawValue
      )
    }
    committedTerm = certificate.term
    votedProposalDigests = votedProposalDigests.filter {
      $0.key > committedTerm
    }
  }
}
