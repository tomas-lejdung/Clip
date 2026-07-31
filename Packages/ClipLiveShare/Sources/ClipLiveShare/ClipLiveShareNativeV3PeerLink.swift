import Foundation

/// Context shared by every offer, answer, and ICE candidate for one direct
/// participant link. The unordered pair key and explicit direction are both
/// present so a relayed message cannot be transplanted to another peer or
/// reflected back to its sender.
public struct ClipLiveShareNativeV3PeerLinkContext: Codable, Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let membershipRevision: ClipLiveShareNativeV3MembershipRevision
  public let peerLinkKey: ClipLiveShareNativeV3PeerLinkKey
  public let negotiationRevision: ClipLiveShareNativeV3PeerLinkRevision
  public let senderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let receiverParticipantID: ClipLiveShareNativeV3ParticipantID
  public let transportNonce: ClipLiveShareNativeV3TransportNonce
  /// Present only while this pair is quarantined behind a provisional
  /// admission. Committed direct-control messages must omit it, which gives
  /// bootstrap SDP/ICE a separate signed replay domain even though the
  /// eventual membership uses the same N+1 revision and transport nonce.
  public let provisionalAdmissionDigest: ClipLiveShareNativeDigest?

  public init(
    sessionID: ClipLiveShareSessionID,
    membershipRevision: ClipLiveShareNativeV3MembershipRevision,
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    negotiationRevision: ClipLiveShareNativeV3PeerLinkRevision,
    senderParticipantID: ClipLiveShareNativeV3ParticipantID,
    receiverParticipantID: ClipLiveShareNativeV3ParticipantID,
    transportNonce: ClipLiveShareNativeV3TransportNonce,
    provisionalAdmissionDigest: ClipLiveShareNativeDigest? = nil
  ) throws {
    guard
      senderParticipantID != receiverParticipantID,
      peerLinkKey.participantIDs == [senderParticipantID, receiverParticipantID]
    else {
      throw ClipLiveShareNativeV3Error.invalidPeerLinkContext
    }
    self.sessionID = sessionID
    self.membershipRevision = membershipRevision
    self.peerLinkKey = peerLinkKey
    self.negotiationRevision = negotiationRevision
    self.senderParticipantID = senderParticipantID
    self.receiverParticipantID = receiverParticipantID
    self.transportNonce = transportNonce
    self.provisionalAdmissionDigest = provisionalAdmissionDigest
  }

  var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/peer-link-context"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(membershipRevision.rawValue)
    encoder.append(peerLinkKey.lowerParticipantID.bytes)
    encoder.append(peerLinkKey.upperParticipantID.bytes)
    encoder.append(negotiationRevision.rawValue)
    encoder.append(senderParticipantID.bytes)
    encoder.append(receiverParticipantID.bytes)
    encoder.append(transportNonce.bytes)
    if let provisionalAdmissionDigest {
      encoder.append("provisional-admission")
      encoder.append(provisionalAdmissionDigest.bytes)
    }
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case membershipRevision
    case peerLinkKey
    case negotiationRevision
    case senderParticipantID = "senderParticipantId"
    case receiverParticipantID = "receiverParticipantId"
    case transportNonce
    case provisionalAdmissionDigest
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      membershipRevision: container.decode(
        ClipLiveShareNativeV3MembershipRevision.self,
        forKey: .membershipRevision
      ),
      peerLinkKey: container.decode(
        ClipLiveShareNativeV3PeerLinkKey.self,
        forKey: .peerLinkKey
      ),
      negotiationRevision: container.decode(
        ClipLiveShareNativeV3PeerLinkRevision.self,
        forKey: .negotiationRevision
      ),
      senderParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .senderParticipantID
      ),
      receiverParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .receiverParticipantID
      ),
      transportNonce: container.decode(
        ClipLiveShareNativeV3TransportNonce.self,
        forKey: .transportNonce
      ),
      provisionalAdmissionDigest: container.decodeIfPresent(
        ClipLiveShareNativeDigest.self,
        forKey: .provisionalAdmissionDigest
      )
    )
  }
}

/// The lower participant ID deterministically creates the offer. This removes
/// glare and ensures every peer derives the same initiator without another
/// mutable role bit.
public struct ClipLiveShareNativeV3PeerLinkOffer: Codable, Equatable, Hashable, Sendable {
  public let context: ClipLiveShareNativeV3PeerLinkContext
  public let sdp: String

  public init(
    context: ClipLiveShareNativeV3PeerLinkContext,
    sdp: String
  ) throws {
    guard context.senderParticipantID == context.peerLinkKey.lowerParticipantID else {
      throw ClipLiveShareNativeV3Error.invalidPeerLinkContext
    }
    try ClipLiveShareMessageValidation.validateText(
      sdp,
      field: "native v3 peer-link offer",
      maximum: 190_000
    )
    self.context = context
    self.sdp = sdp
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/peer-link-offer"
    )
    encoder.append(context.canonicalRepresentation)
    encoder.append(sdp)
    return encoder.data
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      context: container.decode(
        ClipLiveShareNativeV3PeerLinkContext.self,
        forKey: .context
      ),
      sdp: container.decode(String.self, forKey: .sdp)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case context
    case sdp
  }
}

public struct ClipLiveShareSignedNativeV3PeerLinkOffer: Codable, Equatable, Hashable, Sendable {
  public let offer: ClipLiveShareNativeV3PeerLinkOffer
  public let signature: ClipLiveShareIdentitySignature

  public init(
    offer: ClipLiveShareNativeV3PeerLinkOffer,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.offer = offer
    self.signature = signature
  }

  public init(
    signing offer: ClipLiveShareNativeV3PeerLinkOffer,
    with signer: any ClipLiveShareIdentitySigner,
    senderIdentity: ClipLiveShareIdentityPublicKey
  ) throws {
    guard signer.publicKey == senderIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.offer = offer
    signature = try signer.signature(for: offer.canonicalRepresentation)
  }

  public func verify(
    against membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    expectedTransportNonce: ClipLiveShareNativeV3TransportNonce
  ) throws {
    let identity = try validateNativeV3PeerLinkContext(
      offer.context,
      against: membership,
      expectedTransportNonce: expectedTransportNonce
    )
    guard identity.isValidSignature(signature, for: offer.canonicalRepresentation) else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }

  /// Verifies a pair-establishment offer while the candidate is still
  /// quarantined behind a leader-signed provisional admission.
  ///
  /// A normal membership snapshot deliberately cannot authenticate this
  /// message: the candidate is not a room member until every required direct
  /// link is ready and the leader commits revision N+1. The provisional
  /// admission is nevertheless sufficient to authenticate exactly one
  /// candidate-to-member pair because it binds the candidate credential,
  /// current membership, proposed participant set and leader signature.
  public func verify(
    againstProvisionalAdmission admission:
      ClipLiveShareSignedNativeV3ProvisionalAdmission,
    expectedTransportNonce: ClipLiveShareNativeV3TransportNonce
  ) throws {
    let identity = try validateNativeV3ProvisionalPeerLinkContext(
      offer.context,
      against: admission,
      expectedTransportNonce: expectedTransportNonce
    )
    guard identity.isValidSignature(signature, for: offer.canonicalRepresentation) else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

/// The upper participant ID answers the deterministic lower-ID offerer.
public struct ClipLiveShareNativeV3PeerLinkAnswer: Codable, Equatable, Hashable, Sendable {
  public let context: ClipLiveShareNativeV3PeerLinkContext
  public let sdp: String

  public init(
    context: ClipLiveShareNativeV3PeerLinkContext,
    sdp: String
  ) throws {
    guard context.senderParticipantID == context.peerLinkKey.upperParticipantID else {
      throw ClipLiveShareNativeV3Error.invalidPeerLinkContext
    }
    try ClipLiveShareMessageValidation.validateText(
      sdp,
      field: "native v3 peer-link answer",
      maximum: 190_000
    )
    self.context = context
    self.sdp = sdp
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/peer-link-answer"
    )
    encoder.append(context.canonicalRepresentation)
    encoder.append(sdp)
    return encoder.data
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      context: container.decode(
        ClipLiveShareNativeV3PeerLinkContext.self,
        forKey: .context
      ),
      sdp: container.decode(String.self, forKey: .sdp)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case context
    case sdp
  }
}

public struct ClipLiveShareSignedNativeV3PeerLinkAnswer: Codable, Equatable, Hashable, Sendable {
  public let answer: ClipLiveShareNativeV3PeerLinkAnswer
  public let signature: ClipLiveShareIdentitySignature

  public init(
    answer: ClipLiveShareNativeV3PeerLinkAnswer,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.answer = answer
    self.signature = signature
  }

  public init(
    signing answer: ClipLiveShareNativeV3PeerLinkAnswer,
    with signer: any ClipLiveShareIdentitySigner,
    senderIdentity: ClipLiveShareIdentityPublicKey
  ) throws {
    guard signer.publicKey == senderIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.answer = answer
    signature = try signer.signature(for: answer.canonicalRepresentation)
  }

  public func verify(
    against membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    expectedTransportNonce: ClipLiveShareNativeV3TransportNonce
  ) throws {
    let identity = try validateNativeV3PeerLinkContext(
      answer.context,
      against: membership,
      expectedTransportNonce: expectedTransportNonce
    )
    guard identity.isValidSignature(signature, for: answer.canonicalRepresentation) else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }

  public func verify(
    againstProvisionalAdmission admission:
      ClipLiveShareSignedNativeV3ProvisionalAdmission,
    expectedTransportNonce: ClipLiveShareNativeV3TransportNonce
  ) throws {
    let identity = try validateNativeV3ProvisionalPeerLinkContext(
      answer.context,
      against: admission,
      expectedTransportNonce: expectedTransportNonce
    )
    guard identity.isValidSignature(signature, for: answer.canonicalRepresentation) else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

public struct ClipLiveShareNativeV3PeerLinkICECandidate: Codable, Equatable, Hashable,
  Sendable
{
  public let context: ClipLiveShareNativeV3PeerLinkContext
  public let candidateSequence: UInt32
  public let candidate: String
  public let sdpMid: String?
  public let sdpMLineIndex: Int

  public init(
    context: ClipLiveShareNativeV3PeerLinkContext,
    candidateSequence: UInt32,
    candidate: String,
    sdpMid: String?,
    sdpMLineIndex: Int
  ) throws {
    guard candidate.utf8.count <= 16_384 else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 ICE candidate is too large"
      )
    }
    try ClipLiveShareMessageValidation.validateOptionalText(
      sdpMid,
      field: "native v3 SDP mid",
      maximum: 256
    )
    guard (0...1_024).contains(sdpMLineIndex) else {
      throw ClipLiveShareProtocolError.invalidResource(
        "invalid native v3 SDP m-line index"
      )
    }
    self.context = context
    self.candidateSequence = candidateSequence
    self.candidate = candidate
    self.sdpMid = sdpMid
    self.sdpMLineIndex = sdpMLineIndex
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/peer-link-ice"
    )
    encoder.append(context.canonicalRepresentation)
    encoder.append(candidateSequence)
    encoder.append(candidate)
    encoder.append(sdpMid != nil)
    if let sdpMid { encoder.append(sdpMid) }
    encoder.append(UInt64(sdpMLineIndex))
    return encoder.data
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      context: container.decode(
        ClipLiveShareNativeV3PeerLinkContext.self,
        forKey: .context
      ),
      candidateSequence: container.decode(UInt32.self, forKey: .candidateSequence),
      candidate: container.decode(String.self, forKey: .candidate),
      sdpMid: container.decodeIfPresent(String.self, forKey: .sdpMid),
      sdpMLineIndex: container.decode(Int.self, forKey: .sdpMLineIndex)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case context
    case candidateSequence
    case candidate
    case sdpMid
    case sdpMLineIndex
  }
}

public struct ClipLiveShareSignedNativeV3PeerLinkICECandidate: Codable, Equatable, Hashable,
  Sendable
{
  public let ice: ClipLiveShareNativeV3PeerLinkICECandidate
  public let signature: ClipLiveShareIdentitySignature

  public init(
    ice: ClipLiveShareNativeV3PeerLinkICECandidate,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.ice = ice
    self.signature = signature
  }

  public init(
    signing ice: ClipLiveShareNativeV3PeerLinkICECandidate,
    with signer: any ClipLiveShareIdentitySigner,
    senderIdentity: ClipLiveShareIdentityPublicKey
  ) throws {
    guard signer.publicKey == senderIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.ice = ice
    signature = try signer.signature(for: ice.canonicalRepresentation)
  }

  public func verify(
    against membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    expectedTransportNonce: ClipLiveShareNativeV3TransportNonce
  ) throws {
    let identity = try validateNativeV3PeerLinkContext(
      ice.context,
      against: membership,
      expectedTransportNonce: expectedTransportNonce
    )
    guard identity.isValidSignature(signature, for: ice.canonicalRepresentation) else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }

  public func verify(
    againstProvisionalAdmission admission:
      ClipLiveShareSignedNativeV3ProvisionalAdmission,
    expectedTransportNonce: ClipLiveShareNativeV3TransportNonce
  ) throws {
    let identity = try validateNativeV3ProvisionalPeerLinkContext(
      ice.context,
      against: admission,
      expectedTransportNonce: expectedTransportNonce
    )
    guard identity.isValidSignature(signature, for: ice.canonicalRepresentation) else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

/// A signed request asking the deterministic lower-ID endpoint to create the
/// next offer for this pair. The upper endpoint can need renegotiation after a
/// local codec preference change, but it is never permitted to author an
/// offer itself.
public struct ClipLiveShareNativeV3PeerLinkRenegotiationRequest: Codable,
  Equatable, Hashable, Sendable
{
  public let context: ClipLiveShareNativeV3PeerLinkContext
  public let membershipDigest: ClipLiveShareNativeDigest
  public let preferredVideoCodec: String
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    context: ClipLiveShareNativeV3PeerLinkContext,
    membershipDigest: ClipLiveShareNativeDigest,
    preferredVideoCodec: String,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    guard
      context.provisionalAdmissionDigest == nil,
      context.senderParticipantID == context.peerLinkKey.upperParticipantID,
      context.receiverParticipantID == context.peerLinkKey.lowerParticipantID
    else {
      throw ClipLiveShareNativeV3Error.invalidPeerLinkContext
    }
    try ClipLiveShareMessageValidation.validateText(
      preferredVideoCodec,
      field: "native v3 preferred video codec",
      maximum: 16
    )
    try validateNativeV3Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds:
        ClipLiveShareNativeV3
          .maximumPeerLinkRenegotiationRequestLifetimeMilliseconds
    )
    self.context = context
    self.membershipDigest = membershipDigest
    self.preferredVideoCodec = preferredVideoCodec
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/peer-link-renegotiation-request"
    )
    encoder.append(context.canonicalRepresentation)
    encoder.append(membershipDigest.bytes)
    encoder.append(preferredVideoCodec)
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }
}

public struct ClipLiveShareSignedNativeV3PeerLinkRenegotiationRequest: Codable,
  Equatable, Hashable, Sendable
{
  public let request: ClipLiveShareNativeV3PeerLinkRenegotiationRequest
  public let signature: ClipLiveShareIdentitySignature

  public init(
    request: ClipLiveShareNativeV3PeerLinkRenegotiationRequest,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.request = request
    self.signature = signature
  }

  public init(
    signing request: ClipLiveShareNativeV3PeerLinkRenegotiationRequest,
    with signer: any ClipLiveShareIdentitySigner,
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot
  ) throws {
    guard membership.snapshot.participants.contains(where: {
      $0.participantID == request.context.senderParticipantID
        && $0.identity == signer.publicKey
    }) else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.request = request
    signature = try signer.signature(for: request.canonicalRepresentation)
  }

  public func verify(
    against membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    expectedTransportNonce: ClipLiveShareNativeV3TransportNonce,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    let senderIdentity = try validateNativeV3PeerLinkContext(
      request.context,
      against: membership,
      expectedTransportNonce: expectedTransportNonce
    )
    guard
      request.membershipDigest == membership.snapshot.digest,
      request.context.senderParticipantID
        == request.context.peerLinkKey.upperParticipantID,
      request.context.receiverParticipantID
        == request.context.peerLinkKey.lowerParticipantID
    else {
      throw ClipLiveShareNativeV3Error.contextMismatch
    }
    try validateNativeV3ValidityWindow(
      issuedAt: request.issuedAt,
      expiresAt: request.expiresAt,
      now: now
    )
    guard senderIdentity.isValidSignature(
      signature,
      for: request.canonicalRepresentation
    ) else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

/// One side's fresh challenge requiring the other participant to prove control
/// of the identity bound into its leader-signed membership credential.
public struct ClipLiveShareNativeV3PossessionChallenge: Codable, Equatable, Hashable,
  Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let membershipRevision: ClipLiveShareNativeV3MembershipRevision
  public let peerLinkKey: ClipLiveShareNativeV3PeerLinkKey
  public let verifierParticipantID: ClipLiveShareNativeV3ParticipantID
  public let proverParticipantID: ClipLiveShareNativeV3ParticipantID
  public let credentialDigest: ClipLiveShareNativeDigest
  public let transportNonce: ClipLiveShareNativeV3TransportNonce
  public let challenge: Data
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    sessionID: ClipLiveShareSessionID,
    membershipRevision: ClipLiveShareNativeV3MembershipRevision,
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    verifierParticipantID: ClipLiveShareNativeV3ParticipantID,
    proverParticipantID: ClipLiveShareNativeV3ParticipantID,
    credentialDigest: ClipLiveShareNativeDigest,
    transportNonce: ClipLiveShareNativeV3TransportNonce,
    challenge: Data,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    guard
      peerLinkKey.participantIDs == [
        verifierParticipantID,
        proverParticipantID,
      ],
      verifierParticipantID != proverParticipantID
    else {
      throw ClipLiveShareNativeV3Error.invalidPeerLinkContext
    }
    guard challenge.count == ClipLiveShareNativeV3.possessionChallengeByteCount else {
      throw ClipLiveShareNativeV3Error.invalidBinaryValue(
        name: "possession challenge",
        expectedBytes: ClipLiveShareNativeV3.possessionChallengeByteCount
      )
    }
    try validateNativeV3Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds:
        ClipLiveShareNativeV3.maximumPossessionChallengeLifetimeMilliseconds
    )
    self.sessionID = sessionID
    self.membershipRevision = membershipRevision
    self.peerLinkKey = peerLinkKey
    self.verifierParticipantID = verifierParticipantID
    self.proverParticipantID = proverParticipantID
    self.credentialDigest = credentialDigest
    self.transportNonce = transportNonce
    self.challenge = challenge
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public static func random(
    sessionID: ClipLiveShareSessionID,
    membershipRevision: ClipLiveShareNativeV3MembershipRevision,
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    verifierParticipantID: ClipLiveShareNativeV3ParticipantID,
    proverCredential: ClipLiveShareSignedNativeV3MembershipCredential,
    transportNonce: ClipLiveShareNativeV3TransportNonce,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws -> Self {
    try Self(
      sessionID: sessionID,
      membershipRevision: membershipRevision,
      peerLinkKey: peerLinkKey,
      verifierParticipantID: verifierParticipantID,
      proverParticipantID: proverCredential.credential.participant.participantID,
      credentialDigest: proverCredential.credential.digest,
      transportNonce: transportNonce,
      challenge: nativeV3SecureRandomData(
        count: ClipLiveShareNativeV3.possessionChallengeByteCount
      ),
      issuedAt: issuedAt,
      expiresAt: expiresAt
    )
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/possession-challenge"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(membershipRevision.rawValue)
    encoder.append(peerLinkKey.lowerParticipantID.bytes)
    encoder.append(peerLinkKey.upperParticipantID.bytes)
    encoder.append(verifierParticipantID.bytes)
    encoder.append(proverParticipantID.bytes)
    encoder.append(credentialDigest.bytes)
    encoder.append(transportNonce.bytes)
    encoder.append(challenge)
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case membershipRevision
    case peerLinkKey
    case verifierParticipantID = "verifierParticipantId"
    case proverParticipantID = "proverParticipantId"
    case credentialDigest
    case transportNonce
    case challenge
    case issuedAt
    case expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let encodedChallenge = try container.decode(String.self, forKey: .challenge)
    guard let challenge = ClipLiveShareBase64URL.decode(encodedChallenge) else {
      throw ClipLiveShareProtocolError.invalidBase64URL
    }
    try self.init(
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      membershipRevision: container.decode(
        ClipLiveShareNativeV3MembershipRevision.self,
        forKey: .membershipRevision
      ),
      peerLinkKey: container.decode(
        ClipLiveShareNativeV3PeerLinkKey.self,
        forKey: .peerLinkKey
      ),
      verifierParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .verifierParticipantID
      ),
      proverParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .proverParticipantID
      ),
      credentialDigest: container.decode(
        ClipLiveShareNativeDigest.self,
        forKey: .credentialDigest
      ),
      transportNonce: container.decode(
        ClipLiveShareNativeV3TransportNonce.self,
        forKey: .transportNonce
      ),
      challenge: challenge,
      issuedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .issuedAt),
      expiresAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .expiresAt)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(membershipRevision, forKey: .membershipRevision)
    try container.encode(peerLinkKey, forKey: .peerLinkKey)
    try container.encode(verifierParticipantID, forKey: .verifierParticipantID)
    try container.encode(proverParticipantID, forKey: .proverParticipantID)
    try container.encode(credentialDigest, forKey: .credentialDigest)
    try container.encode(transportNonce, forKey: .transportNonce)
    try container.encode(ClipLiveShareBase64URL.encode(challenge), forKey: .challenge)
    try container.encode(issuedAt, forKey: .issuedAt)
    try container.encode(expiresAt, forKey: .expiresAt)
  }
}

public struct ClipLiveShareSignedNativeV3PossessionProof: Codable, Equatable, Hashable,
  Sendable
{
  public let challenge: ClipLiveShareNativeV3PossessionChallenge
  public let proverIdentity: ClipLiveShareIdentityPublicKey
  public let signature: ClipLiveShareIdentitySignature

  public init(
    challenge: ClipLiveShareNativeV3PossessionChallenge,
    proverIdentity: ClipLiveShareIdentityPublicKey,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.challenge = challenge
    self.proverIdentity = proverIdentity
    self.signature = signature
  }

  public init(
    signing challenge: ClipLiveShareNativeV3PossessionChallenge,
    with proverSigner: any ClipLiveShareIdentitySigner
  ) throws {
    self.challenge = challenge
    proverIdentity = proverSigner.publicKey
    signature = try proverSigner.signature(
      for: Self.canonicalRepresentation(
        challenge: challenge,
        proverIdentity: proverSigner.publicKey
      )
    )
  }

  public var canonicalRepresentation: Data {
    Self.canonicalRepresentation(
      challenge: challenge,
      proverIdentity: proverIdentity
    )
  }

  private static func canonicalRepresentation(
    challenge: ClipLiveShareNativeV3PossessionChallenge,
    proverIdentity: ClipLiveShareIdentityPublicKey
  ) -> Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/possession-proof"
    )
    encoder.append(challenge.canonicalRepresentation)
    encoder.append(proverIdentity.x963Representation)
    return encoder.data
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  /// Verifies possession against the exact challenge retained by the verifier
  /// and the credential from the already-verified membership snapshot.
  public func verify(
    expectedChallenge: ClipLiveShareNativeV3PossessionChallenge,
    proverCredential: ClipLiveShareSignedNativeV3MembershipCredential,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    guard challenge == expectedChallenge else {
      throw ClipLiveShareNativeV3Error.contextMismatch
    }
    let credential = proverCredential.credential
    guard
      challenge.sessionID == credential.sessionID,
      challenge.membershipRevision >= credential.membershipRevision,
      challenge.proverParticipantID == credential.participant.participantID,
      challenge.credentialDigest == credential.digest
    else {
      throw ClipLiveShareNativeV3Error.contextMismatch
    }
    guard proverIdentity == credential.participant.identity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    try validateNativeV3ValidityWindow(
      issuedAt: challenge.issuedAt,
      expiresAt: challenge.expiresAt,
      now: now
    )
    guard proverIdentity.isValidSignature(signature, for: canonicalRepresentation) else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }
}

private func validateNativeV3PeerLinkContext(
  _ context: ClipLiveShareNativeV3PeerLinkContext,
  against membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
  expectedTransportNonce: ClipLiveShareNativeV3TransportNonce
) throws -> ClipLiveShareIdentityPublicKey {
  let snapshot = membership.snapshot
  guard
    context.sessionID == snapshot.sessionID,
    context.membershipRevision == snapshot.membershipRevision,
    context.transportNonce == expectedTransportNonce,
    context.provisionalAdmissionDigest == nil,
    snapshot.participantIDs.isSuperset(of: context.peerLinkKey.participantIDs)
  else {
    throw ClipLiveShareNativeV3Error.contextMismatch
  }
  guard
    let sender = snapshot.participants.first(where: {
      $0.participantID == context.senderParticipantID
    }),
    snapshot.participantIDs.contains(context.receiverParticipantID)
  else {
    throw ClipLiveShareNativeV3Error.invalidPeerLinkContext
  }
  return sender.identity
}

private func validateNativeV3ProvisionalPeerLinkContext(
  _ context: ClipLiveShareNativeV3PeerLinkContext,
  against signedAdmission: ClipLiveShareSignedNativeV3ProvisionalAdmission,
  expectedTransportNonce: ClipLiveShareNativeV3TransportNonce
) throws -> ClipLiveShareIdentityPublicKey {
  let admission = signedAdmission.admission
  let candidateCredential = admission.candidateCredential.credential
  let candidate = candidateCredential.participant
  let current = admission.currentMembership.snapshot
  let participants = current.participants + [candidate]

  guard
    context.sessionID == admission.sessionID,
    context.membershipRevision == candidateCredential.membershipRevision,
    context.transportNonce == expectedTransportNonce,
    context.provisionalAdmissionDigest == admission.digest,
    admission.proposedParticipantIDs == Set(participants.map(\.participantID)).sorted(),
    context.peerLinkKey.contains(candidate.participantID),
    context.peerLinkKey.participantIDs.isSubset(of: Set(admission.proposedParticipantIDs)),
    let existingParticipantID =
      context.peerLinkKey.otherParticipant(than: candidate.participantID),
    current.participantIDs.contains(existingParticipantID),
    context.peerLinkKey.participantIDs ==
      Set([context.senderParticipantID, context.receiverParticipantID]),
    let sender = participants.first(where: {
      $0.participantID == context.senderParticipantID
    }),
    participants.contains(where: {
      $0.participantID == context.receiverParticipantID
    })
  else {
    throw ClipLiveShareNativeV3Error.contextMismatch
  }
  return sender.identity
}
