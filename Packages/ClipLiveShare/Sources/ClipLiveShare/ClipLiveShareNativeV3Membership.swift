import Foundation

/// Public, leader-certified information about one mesh participant.
public struct ClipLiveShareNativeV3Participant: Codable, Equatable, Hashable, Sendable {
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let identity: ClipLiveShareIdentityPublicKey
  public let displayName: String
  public let capabilities: ClipLiveShareNativeV3Capabilities

  public init(
    participantID: ClipLiveShareNativeV3ParticipantID,
    identity: ClipLiveShareIdentityPublicKey,
    displayName: String,
    capabilities: ClipLiveShareNativeV3Capabilities
  ) throws {
    try validateNativeV3Text(
      displayName,
      name: "participant display name",
      maximumUTF8Bytes: 128
    )
    try capabilities.validateNativeV3Baseline()
    self.participantID = participantID
    self.identity = identity
    self.displayName = displayName
    self.capabilities = capabilities
  }

  var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/participant"
    )
    encoder.append(participantID.bytes)
    encoder.append(identity.x963Representation)
    encoder.append(displayName)
    encoder.append(capabilities.canonicalRepresentation)
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case participantID = "participantId"
    case identity
    case displayName
    case capabilities
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      participantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .participantID
      ),
      identity: container.decode(ClipLiveShareIdentityPublicKey.self, forKey: .identity),
      displayName: container.decode(String.self, forKey: .displayName),
      capabilities: container.decode(
        ClipLiveShareNativeV3Capabilities.self,
        forKey: .capabilities
      )
    )
  }
}

/// A leader assertion binding a session-scoped participant ID to one
/// persistent native identity and capability manifest. Peers present this
/// credential to each other while creating their direct mesh link.
public struct ClipLiveShareNativeV3MembershipCredential: Codable, Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let leaderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let leaderIdentity: ClipLiveShareIdentityPublicKey
  public let participant: ClipLiveShareNativeV3Participant
  public let membershipRevision: ClipLiveShareNativeV3MembershipRevision
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    sessionID: ClipLiveShareSessionID,
    leaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    leaderIdentity: ClipLiveShareIdentityPublicKey,
    participant: ClipLiveShareNativeV3Participant,
    membershipRevision: ClipLiveShareNativeV3MembershipRevision,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    try validateNativeV3Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds:
        ClipLiveShareNativeV3.maximumMembershipCredentialLifetimeMilliseconds
    )
    if participant.participantID == leaderParticipantID,
      participant.identity != leaderIdentity
    {
      throw ClipLiveShareNativeV3Error.invalidLeader
    }
    self.sessionID = sessionID
    self.leaderParticipantID = leaderParticipantID
    self.leaderIdentity = leaderIdentity
    self.participant = participant
    self.membershipRevision = membershipRevision
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/membership-credential"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(leaderParticipantID.bytes)
    encoder.append(leaderIdentity.x963Representation)
    encoder.append(participant.canonicalRepresentation)
    encoder.append(membershipRevision.rawValue)
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case sessionID = "sessionId"
    case leaderParticipantID = "leaderParticipantId"
    case leaderIdentity
    case participant
    case membershipRevision
    case issuedAt
    case expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ClipLiveShareNativeV3.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    try self.init(
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      leaderParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .leaderParticipantID
      ),
      leaderIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .leaderIdentity
      ),
      participant: container.decode(
        ClipLiveShareNativeV3Participant.self,
        forKey: .participant
      ),
      membershipRevision: container.decode(
        ClipLiveShareNativeV3MembershipRevision.self,
        forKey: .membershipRevision
      ),
      issuedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .issuedAt),
      expiresAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .expiresAt)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ClipLiveShareNativeV3.version, forKey: .version)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(leaderParticipantID, forKey: .leaderParticipantID)
    try container.encode(leaderIdentity, forKey: .leaderIdentity)
    try container.encode(participant, forKey: .participant)
    try container.encode(membershipRevision, forKey: .membershipRevision)
    try container.encode(issuedAt, forKey: .issuedAt)
    try container.encode(expiresAt, forKey: .expiresAt)
  }
}

public struct ClipLiveShareSignedNativeV3MembershipCredential: Codable, Equatable, Hashable,
  Sendable
{
  public let credential: ClipLiveShareNativeV3MembershipCredential
  public let signature: ClipLiveShareIdentitySignature

  public init(
    credential: ClipLiveShareNativeV3MembershipCredential,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.credential = credential
    self.signature = signature
  }

  public init(
    signing credential: ClipLiveShareNativeV3MembershipCredential,
    with leaderSigner: any ClipLiveShareIdentitySigner
  ) throws {
    guard leaderSigner.publicKey == credential.leaderIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.credential = credential
    signature = try leaderSigner.signature(for: credential.canonicalRepresentation)
  }

  public func verify(
    expectedSessionID: ClipLiveShareSessionID,
    expectedLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    expectedLeaderIdentity: ClipLiveShareIdentityPublicKey,
    localCapabilities: ClipLiveShareNativeV3Capabilities = .current,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    guard
      credential.sessionID == expectedSessionID,
      credential.leaderParticipantID == expectedLeaderParticipantID
    else {
      throw ClipLiveShareNativeV3Error.contextMismatch
    }
    guard credential.leaderIdentity == expectedLeaderIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    try validateNativeV3ValidityWindow(
      issuedAt: credential.issuedAt,
      expiresAt: credential.expiresAt,
      now: now
    )
    try localCapabilities.validateCompatibility(with: credential.participant.capabilities)
    guard
      expectedLeaderIdentity.isValidSignature(
        signature,
        for: credential.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

/// An authoritative, complete membership view. Removal is represented by
/// absence from a newer leader-signed snapshot; no unsigned leave message can
/// evict another participant.
public struct ClipLiveShareNativeV3MembershipSnapshot: Codable, Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let leaderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let leaderIdentity: ClipLiveShareIdentityPublicKey
  public let membershipRevision: ClipLiveShareNativeV3MembershipRevision
  public let credentials: [ClipLiveShareSignedNativeV3MembershipCredential]
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    sessionID: ClipLiveShareSessionID,
    leaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    leaderIdentity: ClipLiveShareIdentityPublicKey,
    membershipRevision: ClipLiveShareNativeV3MembershipRevision,
    credentials: [ClipLiveShareSignedNativeV3MembershipCredential],
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp,
    maximumParticipants: Int = ClipLiveShareNativeV3.maximumProtocolParticipants
  ) throws {
    try validateNativeV3Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV3.maximumMembershipSnapshotLifetimeMilliseconds
    )
    try Self.validate(
      credentials,
      sessionID: sessionID,
      leaderParticipantID: leaderParticipantID,
      leaderIdentity: leaderIdentity,
      membershipRevision: membershipRevision,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumParticipants: maximumParticipants
    )
    self.sessionID = sessionID
    self.leaderParticipantID = leaderParticipantID
    self.leaderIdentity = leaderIdentity
    self.membershipRevision = membershipRevision
    self.credentials = credentials.sorted {
      $0.credential.participant.participantID
        < $1.credential.participant.participantID
    }
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var participants: [ClipLiveShareNativeV3Participant] {
    credentials.map(\.credential.participant)
  }

  public var participantIDs: Set<ClipLiveShareNativeV3ParticipantID> {
    Set(participants.map(\.participantID))
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/membership-snapshot"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(leaderParticipantID.bytes)
    encoder.append(leaderIdentity.x963Representation)
    encoder.append(membershipRevision.rawValue)
    encoder.append(UInt64(credentials.count))
    for credential in credentials {
      encoder.append(credential.credential.canonicalRepresentation)
    }
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case sessionID = "sessionId"
    case leaderParticipantID = "leaderParticipantId"
    case leaderIdentity
    case membershipRevision
    case credentials
    case issuedAt
    case expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ClipLiveShareNativeV3.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    try self.init(
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      leaderParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .leaderParticipantID
      ),
      leaderIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .leaderIdentity
      ),
      membershipRevision: container.decode(
        ClipLiveShareNativeV3MembershipRevision.self,
        forKey: .membershipRevision
      ),
      credentials: container.decode(
        [ClipLiveShareSignedNativeV3MembershipCredential].self,
        forKey: .credentials
      ),
      issuedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .issuedAt),
      expiresAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .expiresAt)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ClipLiveShareNativeV3.version, forKey: .version)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(leaderParticipantID, forKey: .leaderParticipantID)
    try container.encode(leaderIdentity, forKey: .leaderIdentity)
    try container.encode(membershipRevision, forKey: .membershipRevision)
    try container.encode(credentials, forKey: .credentials)
    try container.encode(issuedAt, forKey: .issuedAt)
    try container.encode(expiresAt, forKey: .expiresAt)
  }

  private static func validate(
    _ credentials: [ClipLiveShareSignedNativeV3MembershipCredential],
    sessionID: ClipLiveShareSessionID,
    leaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    leaderIdentity: ClipLiveShareIdentityPublicKey,
    membershipRevision: ClipLiveShareNativeV3MembershipRevision,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp,
    maximumParticipants: Int
  ) throws {
    guard
      (1...ClipLiveShareNativeV3.maximumProtocolParticipants).contains(maximumParticipants)
    else {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: ClipLiveShareNativeV3.maximumProtocolParticipants,
        actual: maximumParticipants
      )
    }
    guard !credentials.isEmpty, credentials.count <= maximumParticipants else {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: maximumParticipants,
        actual: credentials.count
      )
    }

    let participants = credentials.map(\.credential.participant)
    guard Set(participants.map(\.participantID)).count == participants.count else {
      throw ClipLiveShareNativeV3Error.duplicateParticipant
    }
    guard Set(participants.map(\.identity.fingerprint)).count == participants.count else {
      throw ClipLiveShareNativeV3Error.duplicateIdentity
    }
    guard
      participants.contains(where: {
        $0.participantID == leaderParticipantID && $0.identity == leaderIdentity
      })
    else {
      throw ClipLiveShareNativeV3Error.invalidLeader
    }

    for signedCredential in credentials {
      let credential = signedCredential.credential
      guard
        credential.sessionID == sessionID,
        credential.leaderParticipantID == leaderParticipantID,
        credential.leaderIdentity == leaderIdentity,
        credential.membershipRevision <= membershipRevision,
        credential.issuedAt <= issuedAt,
        credential.expiresAt >= expiresAt
      else {
        throw ClipLiveShareNativeV3Error.invalidMembership
      }
    }

    let capabilities = participants.map(\.capabilities)
    for index in capabilities.indices {
      try capabilities[index].validateNativeV3Baseline()
      for peerIndex in capabilities.indices where peerIndex > index {
        try capabilities[index].validateCompatibility(with: capabilities[peerIndex])
      }
    }
  }
}

public struct ClipLiveShareSignedNativeV3MembershipSnapshot: Codable, Equatable, Hashable,
  Sendable
{
  public let snapshot: ClipLiveShareNativeV3MembershipSnapshot
  public let signature: ClipLiveShareIdentitySignature

  public init(
    snapshot: ClipLiveShareNativeV3MembershipSnapshot,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.snapshot = snapshot
    self.signature = signature
  }

  public init(
    signing snapshot: ClipLiveShareNativeV3MembershipSnapshot,
    with leaderSigner: any ClipLiveShareIdentitySigner
  ) throws {
    guard leaderSigner.publicKey == snapshot.leaderIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.snapshot = snapshot
    signature = try leaderSigner.signature(for: snapshot.canonicalRepresentation)
  }

  public func verify(
    expectedSessionID: ClipLiveShareSessionID,
    expectedLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    expectedLeaderIdentity: ClipLiveShareIdentityPublicKey,
    localCapabilities: ClipLiveShareNativeV3Capabilities = .current,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    guard
      snapshot.sessionID == expectedSessionID,
      snapshot.leaderParticipantID == expectedLeaderParticipantID
    else {
      throw ClipLiveShareNativeV3Error.contextMismatch
    }
    guard snapshot.leaderIdentity == expectedLeaderIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    try validateNativeV3ValidityWindow(
      issuedAt: snapshot.issuedAt,
      expiresAt: snapshot.expiresAt,
      now: now
    )
    guard
      expectedLeaderIdentity.isValidSignature(
        signature,
        for: snapshot.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }

    for credential in snapshot.credentials {
      try credential.verify(
        expectedSessionID: expectedSessionID,
        expectedLeaderParticipantID: expectedLeaderParticipantID,
        expectedLeaderIdentity: expectedLeaderIdentity,
        localCapabilities: localCapabilities,
        at: now
      )
    }
    for participant in snapshot.participants {
      try localCapabilities.validateCompatibility(with: participant.capabilities)
    }
  }

  /// Revalidates a membership that this process already accepted while it was
  /// fresh.
  ///
  /// Membership expiry bounds *admission* and prevents a newly connecting peer
  /// from trusting an arbitrarily old room view. It does not revoke an
  /// established participant after a few minutes. Room-control messages remain
  /// bound to this exact membership digest and carry their own fresh validity
  /// window.
  ///
  /// Callers must only use this for their locally committed membership, never
  /// for an untrusted membership arriving from the network for the first time.
  public func verifyAsEstablished(
    expectedSessionID: ClipLiveShareSessionID,
    expectedLeaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    expectedLeaderIdentity: ClipLiveShareIdentityPublicKey,
    localCapabilities: ClipLiveShareNativeV3Capabilities = .current
  ) throws {
    try verify(
      expectedSessionID: expectedSessionID,
      expectedLeaderParticipantID: expectedLeaderParticipantID,
      expectedLeaderIdentity: expectedLeaderIdentity,
      localCapabilities: localCapabilities,
      at: snapshot.issuedAt
    )
  }
}
