import CryptoKit
import Foundation

/// Bounded messages used while a native-v3 participant joins a room over an
/// authenticated rendezvous route.
///
/// This is deliberately separate from the established v3 peer-link control
/// channel:
///
/// - established mesh links never accept bootstrap admission messages; and
/// - the rendezvous service relays opaque bytes and never becomes a room
///   membership or media authority.
public enum ClipLiveShareNativeV3Bootstrap {
  public static let version = 3
  public static let protocolIdentifier = "clip-live-share-native-bootstrap"
  public static let maximumMessageBytes = 256 * 1_024
  public static let maximumLifetimeMilliseconds: Int64 = 60 * 1_000
}

public enum ClipLiveShareNativeV3BootstrapError: Error, Equatable, Sendable,
  LocalizedError
{
  case unknownMessageType(String)
  case unexpectedFields
  case rendezvousProofMismatch
  case invalidProvisionalAdmission
  case invalidRelay
  case invalidReadiness

  public var errorDescription: String? {
    switch self {
    case let .unknownMessageType(type):
      "The native-v3 bootstrap message type '\(type)' is unsupported."
    case .unexpectedFields:
      "The native-v3 bootstrap envelope contains unexpected fields."
    case .rendezvousProofMismatch:
      "The native-v3 bootstrap message belongs to another admission route."
    case .invalidProvisionalAdmission:
      "The native-v3 provisional membership is invalid."
    case .invalidRelay:
      "The native-v3 bootstrap relay is not scoped to its asserted peer pair."
    case .invalidReadiness:
      "The native-v3 bootstrap readiness statement is invalid."
    }
  }
}

/// Public proof that a native-v3 admission belongs to one authenticated
/// rendezvous
/// route.
///
/// The invite/signaling layer remains only an opaque byte transport. Once it
/// has authenticated its admission capability and encrypted route, both
/// endpoints derive this value from the same rendezvous, route, founding
/// identity, and secure
/// transport transcript. The candidate signs the proof as part of its v3
/// hello, so a message copied from another route cannot be replayed here.
public struct ClipLiveShareNativeV3RendezvousProof: Codable, Equatable,
  Hashable, Sendable
{
  public let digest: ClipLiveShareNativeDigest

  public init(
    sessionID: ClipLiveShareSessionID,
    rendezvousID: ClipLiveShareNativeV3RendezvousID,
    routeID: ClipLiveShareRouteID,
    foundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
    admissionCapability: ClipLiveShareNativeV3AdmissionCapability
  ) {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/rendezvous-proof"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(rendezvousID.bytes)
    encoder.append(routeID.rawValue)
    encoder.append(foundingCreatorIdentity.x963Representation)
    let authenticationCode = HMAC<SHA256>.authenticationCode(
      for: encoder.data,
      using: SymmetricKey(data: admissionCapability.keyMaterial)
    )
    digest = try! .init(bytes: Data(authenticationCode))
  }
}

/// Optional human-readable admission secret for one encrypted native-v3
/// rendezvous route.
///
/// The mandatory invite capability still authenticates and encrypts the route.
/// This proof is an independent owner-controlled gate. It is bound to the
/// route-specific rendezvous proof and candidate identity, so a proof copied
/// from another route or participant cannot be replayed. The rendezvous
/// service never sees it because the bootstrap hello is already encrypted.
public struct ClipLiveShareNativeV3AccessWordProof: Codable, Equatable,
  Hashable, Sendable
{
  public let digest: ClipLiveShareNativeDigest

  public init(
    accessWord: String,
    sessionID: ClipLiveShareSessionID,
    participantID: ClipLiveShareNativeV3ParticipantID,
    identity: ClipLiveShareIdentityPublicKey,
    rendezvousProof: ClipLiveShareNativeV3RendezvousProof
  ) throws {
    let normalized = Self.normalize(accessWord)
    guard !normalized.isEmpty else {
      throw ClipLiveShareProtocolError.accessCodeRequired
    }
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/access-word-proof"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(participantID.bytes)
    encoder.append(identity.x963Representation)
    encoder.append(rendezvousProof.digest.bytes)
    let authenticationCode = HMAC<SHA256>.authenticationCode(
      for: encoder.data,
      using: SymmetricKey(data: Data(normalized.utf8))
    )
    digest = try .init(bytes: Data(authenticationCode))
  }

  public func verify(
    accessWord: String,
    sessionID: ClipLiveShareSessionID,
    participantID: ClipLiveShareNativeV3ParticipantID,
    identity: ClipLiveShareIdentityPublicKey,
    rendezvousProof: ClipLiveShareNativeV3RendezvousProof
  ) -> Bool {
    guard
      let expected = try? Self(
        accessWord: accessWord,
        sessionID: sessionID,
        participantID: participantID,
        identity: identity,
        rendezvousProof: rendezvousProof
      )
    else { return false }
    return digest == expected.digest
  }

  public static func normalize(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
  }
}

public struct ClipLiveShareNativeV3BootstrapHello: Codable, Equatable, Hashable,
  Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let identity: ClipLiveShareIdentityPublicKey
  public let displayName: String
  public let capabilities: ClipLiveShareNativeV3Capabilities
  public let rendezvousProof: ClipLiveShareNativeV3RendezvousProof
  public let accessWordProof: ClipLiveShareNativeV3AccessWordProof?
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    sessionID: ClipLiveShareSessionID,
    participantID: ClipLiveShareNativeV3ParticipantID,
    identity: ClipLiveShareIdentityPublicKey,
    displayName: String,
    capabilities: ClipLiveShareNativeV3Capabilities = .current,
    rendezvousProof: ClipLiveShareNativeV3RendezvousProof,
    accessWordProof: ClipLiveShareNativeV3AccessWordProof? = nil,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    try validateNativeV3Text(
      displayName,
      name: "bootstrap participant display name",
      maximumUTF8Bytes: 128
    )
    try capabilities.validateNativeV3Baseline()
    try validateNativeV3Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV3Bootstrap.maximumLifetimeMilliseconds
    )
    self.sessionID = sessionID
    self.participantID = participantID
    self.identity = identity
    self.displayName = displayName
    self.capabilities = capabilities
    self.rendezvousProof = rendezvousProof
    self.accessWordProof = accessWordProof
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var participant: ClipLiveShareNativeV3Participant {
    try! .init(
      participantID: participantID,
      identity: identity,
      displayName: displayName,
      capabilities: capabilities
    )
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/bootstrap-hello"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(participantID.bytes)
    encoder.append(identity.x963Representation)
    encoder.append(displayName)
    encoder.append(capabilities.canonicalRepresentation)
    encoder.append(rendezvousProof.digest.bytes)
    encoder.append(accessWordProof?.digest.bytes ?? Data())
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case participantID = "participantId"
    case identity
    case displayName
    case capabilities
    case rendezvousProof
    case accessWordProof
    case issuedAt
    case expiresAt
  }
}

public struct ClipLiveShareSignedNativeV3BootstrapHello: Codable, Equatable,
  Hashable, Sendable
{
  public let hello: ClipLiveShareNativeV3BootstrapHello
  public let signature: ClipLiveShareIdentitySignature

  public init(
    hello: ClipLiveShareNativeV3BootstrapHello,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.hello = hello
    self.signature = signature
  }

  public init(
    signing hello: ClipLiveShareNativeV3BootstrapHello,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    guard signer.publicKey == hello.identity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.hello = hello
    signature = try signer.signature(for: hello.canonicalRepresentation)
  }

  public func verify(
    expectedSessionID: ClipLiveShareSessionID,
    expectedRendezvousProof: ClipLiveShareNativeV3RendezvousProof,
    localCapabilities: ClipLiveShareNativeV3Capabilities = .current,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try verify(
      expectedSessionID: expectedSessionID,
      localCapabilities: localCapabilities,
      at: now
    )
    guard hello.rendezvousProof == expectedRendezvousProof else {
      throw ClipLiveShareNativeV3BootstrapError.rendezvousProofMismatch
    }
  }

  /// Verifies candidate identity, freshness, and capabilities without claiming
  /// local possession of the candidate's secure rendezvous capability.
  ///
  /// Existing room members use this when the leader forwards a hello. The
  /// subsequent leader-signed provisional admission binds this exact hello
  /// digest and rendezvous proof to the current authority chain.
  public func verify(
    expectedSessionID: ClipLiveShareSessionID,
    localCapabilities: ClipLiveShareNativeV3Capabilities = .current,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    guard hello.sessionID == expectedSessionID else {
      throw ClipLiveShareNativeV3Error.contextMismatch
    }
    try validateNativeV3ValidityWindow(
      issuedAt: hello.issuedAt,
      expiresAt: hello.expiresAt,
      now: now
    )
    try localCapabilities.validateCompatibility(with: hello.capabilities)
    guard
      hello.identity.isValidSignature(signature, for: hello.canonicalRepresentation)
    else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

/// The leader's signed, non-authoritative preparation for adding one
/// participant. It gives the candidate enough authenticated room context to
/// establish direct links, but it does not make the candidate a member.
/// Membership changes only when a newer signed complete snapshot is received.
public struct ClipLiveShareNativeV3ProvisionalAdmission: Codable, Equatable,
  Hashable, Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let rendezvousProof: ClipLiveShareNativeV3RendezvousProof
  public let helloDigest: ClipLiveShareNativeDigest
  public let candidateCredential: ClipLiveShareSignedNativeV3MembershipCredential
  public let currentMembership: ClipLiveShareSignedNativeV3MembershipSnapshot
  public let authorityChain: ClipLiveShareNativeV3RoomAuthorityChain
  public let proposedParticipantIDs: [ClipLiveShareNativeV3ParticipantID]
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    sessionID: ClipLiveShareSessionID,
    rendezvousProof: ClipLiveShareNativeV3RendezvousProof,
    helloDigest: ClipLiveShareNativeDigest,
    candidateCredential: ClipLiveShareSignedNativeV3MembershipCredential,
    currentMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    authorityChain: ClipLiveShareNativeV3RoomAuthorityChain,
    proposedParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    guard
      !proposedParticipantIDs.isEmpty,
      proposedParticipantIDs.count <=
        ClipLiveShareNativeV3.defaultProductAdmissionLimit
    else {
      throw ClipLiveShareNativeV3Error.participantLimit(
        maximum: ClipLiveShareNativeV3.defaultProductAdmissionLimit,
        actual: proposedParticipantIDs.count
      )
    }
    try validateNativeV3Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV3Bootstrap.maximumLifetimeMilliseconds
    )
    self.sessionID = sessionID
    self.rendezvousProof = rendezvousProof
    self.helloDigest = helloDigest
    self.candidateCredential = candidateCredential
    self.currentMembership = currentMembership
    self.authorityChain = authorityChain
    self.proposedParticipantIDs = proposedParticipantIDs.sorted()
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var candidateParticipantID: ClipLiveShareNativeV3ParticipantID {
    candidateCredential.credential.participant.participantID
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/provisional-admission"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(rendezvousProof.digest.bytes)
    encoder.append(helloDigest.bytes)
    encoder.append(candidateCredential.credential.canonicalRepresentation)
    encoder.append(currentMembership.snapshot.canonicalRepresentation)
    encoder.append(
      ClipLiveShareNativeDigest(
        hashing: try! ClipLiveShareNativeV3FoundationJSONCodec.encode(authorityChain)
      ).bytes
    )
    encoder.append(UInt64(proposedParticipantIDs.count))
    for participantID in proposedParticipantIDs {
      encoder.append(participantID.bytes)
    }
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case rendezvousProof
    case helloDigest
    case candidateCredential
    case currentMembership
    case authorityChain
    case proposedParticipantIDs = "proposedParticipantIds"
    case issuedAt
    case expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let participantIDs = try container.decode(
      [ClipLiveShareNativeV3ParticipantID].self,
      forKey: .proposedParticipantIDs
    )
    guard Set(participantIDs).count == participantIDs.count else {
      throw ClipLiveShareNativeV3Error.duplicateParticipant
    }
    try self.init(
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      rendezvousProof: container.decode(
        ClipLiveShareNativeV3RendezvousProof.self,
        forKey: .rendezvousProof
      ),
      helloDigest: container.decode(
        ClipLiveShareNativeDigest.self,
        forKey: .helloDigest
      ),
      candidateCredential: container.decode(
        ClipLiveShareSignedNativeV3MembershipCredential.self,
        forKey: .candidateCredential
      ),
      currentMembership: container.decode(
        ClipLiveShareSignedNativeV3MembershipSnapshot.self,
        forKey: .currentMembership
      ),
      authorityChain: container.decode(
        ClipLiveShareNativeV3RoomAuthorityChain.self,
        forKey: .authorityChain
      ),
      proposedParticipantIDs: Set(participantIDs),
      issuedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .issuedAt),
      expiresAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .expiresAt)
    )
  }
}

public struct ClipLiveShareSignedNativeV3ProvisionalAdmission: Codable,
  Equatable, Hashable, Sendable
{
  public let admission: ClipLiveShareNativeV3ProvisionalAdmission
  public let signature: ClipLiveShareIdentitySignature

  public init(
    admission: ClipLiveShareNativeV3ProvisionalAdmission,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.admission = admission
    self.signature = signature
  }

  public init(
    signing admission: ClipLiveShareNativeV3ProvisionalAdmission,
    with leaderSigner: any ClipLiveShareIdentitySigner
  ) throws {
    guard
      leaderSigner.publicKey ==
        admission.currentMembership.snapshot.leaderIdentity
    else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.admission = admission
    signature = try leaderSigner.signature(for: admission.canonicalRepresentation)
  }

  public func verify(
    expectedHello: ClipLiveShareSignedNativeV3BootstrapHello,
    expectedFoundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
    localCapabilities: ClipLiveShareNativeV3Capabilities = .current,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    let current = admission.currentMembership.snapshot
    try admission.authorityChain.verify(
      expectedSessionID: admission.sessionID,
      expectedFoundingCreatorIdentity: expectedFoundingCreatorIdentity,
      localCapabilities: localCapabilities,
      at: now
    )
    guard
      admission.sessionID == expectedHello.hello.sessionID,
      admission.rendezvousProof == expectedHello.hello.rendezvousProof,
      admission.helloDigest == expectedHello.hello.digest,
      admission.candidateParticipantID == expectedHello.hello.participantID,
      admission.candidateCredential.credential.participant ==
        expectedHello.hello.participant,
      current.sessionID == admission.sessionID,
      current.leaderParticipantID ==
        admission.authorityChain.currentLeaderParticipantID,
      current.leaderIdentity == admission.authorityChain.currentLeaderIdentity,
      admission.proposedParticipantIDs ==
        current.participantIDs.union([admission.candidateParticipantID]).sorted(),
      !current.participantIDs.contains(admission.candidateParticipantID)
    else {
      throw ClipLiveShareNativeV3BootstrapError.invalidProvisionalAdmission
    }
    let (nextRevision, overflow) =
      current.membershipRevision.rawValue.addingReportingOverflow(1)
    guard
      !overflow,
      admission.candidateCredential.credential.membershipRevision.rawValue ==
        nextRevision,
      admission.candidateCredential.credential.leaderParticipantID ==
        current.leaderParticipantID,
      admission.candidateCredential.credential.leaderIdentity ==
        current.leaderIdentity
    else {
      throw ClipLiveShareNativeV3BootstrapError.invalidProvisionalAdmission
    }
    try validateNativeV3ValidityWindow(
      issuedAt: admission.issuedAt,
      expiresAt: admission.expiresAt,
      now: now
    )
    try admission.candidateCredential.verify(
      expectedSessionID: admission.sessionID,
      expectedLeaderParticipantID: current.leaderParticipantID,
      expectedLeaderIdentity: current.leaderIdentity,
      localCapabilities: localCapabilities,
      at: now
    )
    try admission.currentMembership.verify(
      expectedSessionID: admission.sessionID,
      expectedLeaderParticipantID: current.leaderParticipantID,
      expectedLeaderIdentity: current.leaderIdentity,
      localCapabilities: localCapabilities,
      at: now
    )
    guard
      current.leaderIdentity.isValidSignature(
        signature,
        for: admission.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

/// Only pair establishment messages may be forwarded through the admission
/// leader. Source state, annotations, membership mutation, leadership votes
/// and media must use established direct peer links.
public enum ClipLiveShareNativeV3BootstrapRelayPayload: Codable, Equatable,
  Hashable, Sendable
{
  case possessionChallenge(ClipLiveShareNativeV3PossessionChallenge)
  case possessionProof(ClipLiveShareSignedNativeV3PossessionProof)
  case offer(ClipLiveShareSignedNativeV3PeerLinkOffer)
  case answer(ClipLiveShareSignedNativeV3PeerLinkAnswer)
  case ice(ClipLiveShareSignedNativeV3PeerLinkICECandidate)

  public var peerLinkKey: ClipLiveShareNativeV3PeerLinkKey {
    switch self {
    case let .possessionChallenge(value): value.peerLinkKey
    case let .possessionProof(value): value.challenge.peerLinkKey
    case let .offer(value): value.offer.context.peerLinkKey
    case let .answer(value): value.answer.context.peerLinkKey
    case let .ice(value): value.ice.context.peerLinkKey
    }
  }

  private enum CodingKeys: String, CodingKey { case type, payload }
  private enum Kind: String, Codable {
    case possessionChallenge = "possession-challenge"
    case possessionProof = "possession-proof"
    case offer
    case answer
    case ice
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .possessionChallenge:
      self = .possessionChallenge(
        try container.decode(
          ClipLiveShareNativeV3PossessionChallenge.self,
          forKey: .payload
        )
      )
    case .possessionProof:
      self = .possessionProof(
        try container.decode(
          ClipLiveShareSignedNativeV3PossessionProof.self,
          forKey: .payload
        )
      )
    case .offer:
      self = .offer(
        try container.decode(
          ClipLiveShareSignedNativeV3PeerLinkOffer.self,
          forKey: .payload
        )
      )
    case .answer:
      self = .answer(
        try container.decode(
          ClipLiveShareSignedNativeV3PeerLinkAnswer.self,
          forKey: .payload
        )
      )
    case .ice:
      self = .ice(
        try container.decode(
          ClipLiveShareSignedNativeV3PeerLinkICECandidate.self,
          forKey: .payload
        )
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .possessionChallenge(value):
      try container.encode(Kind.possessionChallenge, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .possessionProof(value):
      try container.encode(Kind.possessionProof, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .offer(value):
      try container.encode(Kind.offer, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .answer(value):
      try container.encode(Kind.answer, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .ice(value):
      try container.encode(Kind.ice, forKey: .type)
      try container.encode(value, forKey: .payload)
    }
  }
}

public struct ClipLiveShareNativeV3BootstrapRelay: Codable, Equatable, Hashable,
  Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let admissionDigest: ClipLiveShareNativeDigest
  public let originParticipantID: ClipLiveShareNativeV3ParticipantID
  public let targetParticipantID: ClipLiveShareNativeV3ParticipantID
  public let payload: ClipLiveShareNativeV3BootstrapRelayPayload

  public init(
    sessionID: ClipLiveShareSessionID,
    admissionDigest: ClipLiveShareNativeDigest,
    originParticipantID: ClipLiveShareNativeV3ParticipantID,
    targetParticipantID: ClipLiveShareNativeV3ParticipantID,
    payload: ClipLiveShareNativeV3BootstrapRelayPayload
  ) throws {
    guard
      originParticipantID != targetParticipantID,
      payload.peerLinkKey.participantIDs ==
        Set([originParticipantID, targetParticipantID])
    else {
      throw ClipLiveShareNativeV3BootstrapError.invalidRelay
    }
    self.sessionID = sessionID
    self.admissionDigest = admissionDigest
    self.originParticipantID = originParticipantID
    self.targetParticipantID = targetParticipantID
    self.payload = payload
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case admissionDigest
    case originParticipantID = "originParticipantId"
    case targetParticipantID = "targetParticipantId"
    case payload
  }
}

public struct ClipLiveShareNativeV3BootstrapLinkReadiness: Codable, Equatable,
  Hashable, Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let admissionDigest: ClipLiveShareNativeDigest
  public let reporterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let reporterIdentity: ClipLiveShareIdentityPublicKey
  public let readyPeerLinkKeys: [ClipLiveShareNativeV3PeerLinkKey]

  public init(
    sessionID: ClipLiveShareSessionID,
    admissionDigest: ClipLiveShareNativeDigest,
    reporterParticipantID: ClipLiveShareNativeV3ParticipantID,
    reporterIdentity: ClipLiveShareIdentityPublicKey,
    readyPeerLinkKeys: Set<ClipLiveShareNativeV3PeerLinkKey>
  ) throws {
    guard
      !readyPeerLinkKeys.isEmpty,
      readyPeerLinkKeys.allSatisfy({ $0.contains(reporterParticipantID) })
    else {
      throw ClipLiveShareNativeV3BootstrapError.invalidReadiness
    }
    self.sessionID = sessionID
    self.admissionDigest = admissionDigest
    self.reporterParticipantID = reporterParticipantID
    self.reporterIdentity = reporterIdentity
    self.readyPeerLinkKeys = readyPeerLinkKeys.sorted()
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/bootstrap-link-readiness"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(admissionDigest.bytes)
    encoder.append(reporterParticipantID.bytes)
    encoder.append(reporterIdentity.x963Representation)
    encoder.append(UInt64(readyPeerLinkKeys.count))
    for key in readyPeerLinkKeys {
      encoder.append(key.lowerParticipantID.bytes)
      encoder.append(key.upperParticipantID.bytes)
    }
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case admissionDigest
    case reporterParticipantID = "reporterParticipantId"
    case reporterIdentity
    case readyPeerLinkKeys
  }
}

public struct ClipLiveShareSignedNativeV3BootstrapLinkReadiness: Codable,
  Equatable, Hashable, Sendable
{
  public let readiness: ClipLiveShareNativeV3BootstrapLinkReadiness
  public let signature: ClipLiveShareIdentitySignature

  public init(
    readiness: ClipLiveShareNativeV3BootstrapLinkReadiness,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.readiness = readiness
    self.signature = signature
  }

  public init(
    signing readiness: ClipLiveShareNativeV3BootstrapLinkReadiness,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    guard signer.publicKey == readiness.reporterIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.readiness = readiness
    signature = try signer.signature(for: readiness.canonicalRepresentation)
  }

  public func verify(
    admission: ClipLiveShareSignedNativeV3ProvisionalAdmission
  ) throws {
    let participants = admission.admission.currentMembership.snapshot.participants
      + [admission.admission.candidateCredential.credential.participant]
    guard
      readiness.sessionID == admission.admission.sessionID,
      readiness.admissionDigest == admission.admission.digest,
      participants.contains(where: {
        $0.participantID == readiness.reporterParticipantID
          && $0.identity == readiness.reporterIdentity
      }),
      readiness.readyPeerLinkKeys.allSatisfy({
        admission.admission.proposedParticipantIDs.contains(
          $0.lowerParticipantID
        )
          && admission.admission.proposedParticipantIDs.contains(
            $0.upperParticipantID
          )
      })
    else {
      throw ClipLiveShareNativeV3BootstrapError.invalidReadiness
    }
    guard
      readiness.reporterIdentity.isValidSignature(
        signature,
        for: readiness.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

public enum ClipLiveShareNativeV3BootstrapRejectionReason: String, Codable,
  Equatable, Hashable, Sendable
{
  case incompatible = "incompatible"
  case accessWordRequired = "access-word-required"
  case invalidAccessWord = "invalid-access-word"
  case denied
  case roomFull = "room-full"
  case busy
  case timedOut = "timed-out"
  case roomLocked = "room-locked"
  case roomEnded = "room-ended"
}

public struct ClipLiveShareNativeV3BootstrapRejection: Codable, Equatable,
  Hashable, Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let rendezvousProof: ClipLiveShareNativeV3RendezvousProof
  public let reason: ClipLiveShareNativeV3BootstrapRejectionReason

  public init(
    sessionID: ClipLiveShareSessionID,
    rendezvousProof: ClipLiveShareNativeV3RendezvousProof,
    reason: ClipLiveShareNativeV3BootstrapRejectionReason
  ) {
    self.sessionID = sessionID
    self.rendezvousProof = rendezvousProof
    self.reason = reason
  }
}

public enum ClipLiveShareNativeV3BootstrapEnvelope: Codable, Equatable,
  Hashable, Sendable
{
  case hello(ClipLiveShareSignedNativeV3BootstrapHello)
  case provisionalAdmission(ClipLiveShareSignedNativeV3ProvisionalAdmission)
  case relay(ClipLiveShareNativeV3BootstrapRelay)
  case linkReadiness(ClipLiveShareSignedNativeV3BootstrapLinkReadiness)
  case admitted(ClipLiveShareSignedNativeV3MembershipSnapshot)
  case rejected(ClipLiveShareNativeV3BootstrapRejection)

  private enum CodingKeys: String, CodingKey { case version, type, payload }
  private enum Kind: String, Codable {
    case hello
    case provisionalAdmission = "provisional-admission"
    case relay
    case linkReadiness = "link-readiness"
    case admitted
    case rejected
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ClipLiveShareNativeV3Bootstrap.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    let rawKind = try container.decode(String.self, forKey: .type)
    guard let kind = Kind(rawValue: rawKind) else {
      throw ClipLiveShareNativeV3BootstrapError.unknownMessageType(rawKind)
    }
    switch kind {
    case .hello:
      self = .hello(
        try container.decode(
          ClipLiveShareSignedNativeV3BootstrapHello.self,
          forKey: .payload
        )
      )
    case .provisionalAdmission:
      self = .provisionalAdmission(
        try container.decode(
          ClipLiveShareSignedNativeV3ProvisionalAdmission.self,
          forKey: .payload
        )
      )
    case .relay:
      self = .relay(
        try container.decode(
          ClipLiveShareNativeV3BootstrapRelay.self,
          forKey: .payload
        )
      )
    case .linkReadiness:
      self = .linkReadiness(
        try container.decode(
          ClipLiveShareSignedNativeV3BootstrapLinkReadiness.self,
          forKey: .payload
        )
      )
    case .admitted:
      self = .admitted(
        try container.decode(
          ClipLiveShareSignedNativeV3MembershipSnapshot.self,
          forKey: .payload
        )
      )
    case .rejected:
      self = .rejected(
        try container.decode(
          ClipLiveShareNativeV3BootstrapRejection.self,
          forKey: .payload
        )
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ClipLiveShareNativeV3Bootstrap.version, forKey: .version)
    switch self {
    case let .hello(value):
      try container.encode(Kind.hello.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .provisionalAdmission(value):
      try container.encode(Kind.provisionalAdmission.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .relay(value):
      try container.encode(Kind.relay.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .linkReadiness(value):
      try container.encode(Kind.linkReadiness.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .admitted(value):
      try container.encode(Kind.admitted.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .rejected(value):
      try container.encode(Kind.rejected.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    }
  }
}

public enum ClipLiveShareNativeV3BootstrapCodec {
  public static func encode(
    _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
    maximumBytes: Int = ClipLiveShareNativeV3Bootstrap.maximumMessageBytes
  ) throws -> Data {
    guard maximumBytes > 0 else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native-v3 bootstrap size limit must be positive"
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(envelope)
    guard data.count <= maximumBytes else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum: maximumBytes,
        actual: data.count
      )
    }
    return data
  }

  public static func decode(
    _ data: Data,
    maximumBytes: Int = ClipLiveShareNativeV3Bootstrap.maximumMessageBytes
  ) throws -> ClipLiveShareNativeV3BootstrapEnvelope {
    guard data.count <= maximumBytes else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum: maximumBytes,
        actual: data.count
      )
    }
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any],
      Set(dictionary.keys) == ["version", "type", "payload"]
    else {
      throw ClipLiveShareNativeV3BootstrapError.unexpectedFields
    }
    return try JSONDecoder().decode(
      ClipLiveShareNativeV3BootstrapEnvelope.self,
      from: data
    )
  }
}
