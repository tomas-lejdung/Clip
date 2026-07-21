import Foundation

public struct ClipLiveShareNativeRendezvousContext: Codable, Equatable, Hashable, Sendable {
  public let endpoint: ClipLiveShareServerEndpoint
  public let room: ClipLiveShareRoomName
  public let rendezvousID: ClipLiveShareRendezvousID

  public init(
    endpoint: ClipLiveShareServerEndpoint,
    room: ClipLiveShareRoomName,
    rendezvousID: ClipLiveShareRendezvousID
  ) {
    self.endpoint = endpoint
    self.room = room
    self.rendezvousID = rendezvousID
  }

  private enum CodingKeys: String, CodingKey {
    case endpoint
    case room
    case rendezvousID = "rendezvousId"
  }
}

public struct ClipLiveShareNativeSessionDescriptor: Codable, Equatable, Hashable, Sendable {
  public let endpoint: ClipLiveShareServerEndpoint
  public let room: ClipLiveShareRoomName
  public let rendezvousID: ClipLiveShareRendezvousID
  public let hostIdentity: ClipLiveShareIdentityPublicKey
  public let roomPublicKey: ClipLiveShareKeyAgreementPublicKey
  public let sessionID: ClipLiveShareSessionID
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp
  public let stateRevision: ClipLiveShareStateRevision

  public init(
    endpoint: ClipLiveShareServerEndpoint,
    room: ClipLiveShareRoomName,
    rendezvousID: ClipLiveShareRendezvousID,
    hostIdentity: ClipLiveShareIdentityPublicKey,
    roomPublicKey: ClipLiveShareKeyAgreementPublicKey,
    sessionID: ClipLiveShareSessionID,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp,
    stateRevision: ClipLiveShareStateRevision
  ) throws {
    try validateNativeV2Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV2.maximumSessionDescriptorLifetimeMilliseconds
    )
    self.endpoint = endpoint
    self.room = room
    self.rendezvousID = rendezvousID
    self.hostIdentity = hostIdentity
    self.roomPublicKey = roomPublicKey
    self.sessionID = sessionID
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.stateRevision = stateRevision
  }

  /// Deterministic, length-delimited representation covered by the host
  /// identity signature. JSON member ordering and URL spelling cannot affect
  /// the signature context.
  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/session-descriptor"
    )
    encoder.append(endpoint.rootURL.absoluteString)
    encoder.append(room.rawValue)
    encoder.append(rendezvousID.bytes)
    encoder.append(hostIdentity.x963Representation)
    encoder.append(roomPublicKey.x963Representation)
    encoder.append(sessionID.rawValue)
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    encoder.append(stateRevision.rawValue)
    return encoder.data
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  public var rendezvousContext: ClipLiveShareNativeRendezvousContext {
    ClipLiveShareNativeRendezvousContext(
      endpoint: endpoint,
      room: room,
      rendezvousID: rendezvousID
    )
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case endpoint
    case room
    case rendezvousID = "rendezvousId"
    case hostIdentity
    case roomPublicKey
    case sessionID = "sessionId"
    case issuedAt
    case expiresAt
    case stateRevision
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard try container.decode(Int.self, forKey: .version) == ClipLiveShareNativeV2.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(
        try container.decode(Int.self, forKey: .version)
      )
    }
    try self.init(
      endpoint: container.decode(ClipLiveShareServerEndpoint.self, forKey: .endpoint),
      room: container.decode(ClipLiveShareRoomName.self, forKey: .room),
      rendezvousID: container.decode(ClipLiveShareRendezvousID.self, forKey: .rendezvousID),
      hostIdentity: container.decode(ClipLiveShareIdentityPublicKey.self, forKey: .hostIdentity),
      roomPublicKey: container.decode(
        ClipLiveShareKeyAgreementPublicKey.self,
        forKey: .roomPublicKey
      ),
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      issuedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .issuedAt),
      expiresAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .expiresAt),
      stateRevision: container.decode(ClipLiveShareStateRevision.self, forKey: .stateRevision)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ClipLiveShareNativeV2.version, forKey: .version)
    try container.encode(endpoint, forKey: .endpoint)
    try container.encode(room, forKey: .room)
    try container.encode(rendezvousID, forKey: .rendezvousID)
    try container.encode(hostIdentity, forKey: .hostIdentity)
    try container.encode(roomPublicKey, forKey: .roomPublicKey)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(issuedAt, forKey: .issuedAt)
    try container.encode(expiresAt, forKey: .expiresAt)
    try container.encode(stateRevision, forKey: .stateRevision)
  }
}

public struct ClipLiveShareSignedNativeSessionDescriptor: Codable, Equatable, Hashable, Sendable {
  public let descriptor: ClipLiveShareNativeSessionDescriptor
  public let signature: ClipLiveShareIdentitySignature

  public init(
    descriptor: ClipLiveShareNativeSessionDescriptor,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.descriptor = descriptor
    self.signature = signature
  }

  public init(
    signing descriptor: ClipLiveShareNativeSessionDescriptor,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    guard signer.publicKey == descriptor.hostIdentity else {
      throw ClipLiveShareNativeV2Error.identityMismatch
    }
    self.descriptor = descriptor
    signature = try signer.signature(for: descriptor.canonicalRepresentation)
  }

  public func verify(
    expectedIdentity: ClipLiveShareIdentityPublicKey,
    expectedContext: ClipLiveShareNativeRendezvousContext,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    guard descriptor.hostIdentity == expectedIdentity else {
      throw ClipLiveShareNativeV2Error.identityMismatch
    }
    guard descriptor.rendezvousContext == expectedContext else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }
    try validateNativeV2ValidityWindow(
      issuedAt: descriptor.issuedAt,
      expiresAt: descriptor.expiresAt,
      now: now
    )
    guard
      expectedIdentity.isValidSignature(
        signature,
        for: descriptor.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV2Error.invalidSignature
    }
  }
}

public struct ClipLiveShareNativeViewerChallenge: Codable, Equatable, Hashable, Sendable {
  public let sessionDescriptorDigest: ClipLiveShareNativeDigest
  public let sessionID: ClipLiveShareSessionID
  public let routeID: ClipLiveShareRouteID
  public let viewerEphemeralPublicKey: ClipLiveShareKeyAgreementPublicKey
  public let challenge: Data
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp
  public let stateRevision: ClipLiveShareStateRevision

  public init(
    sessionDescriptorDigest: ClipLiveShareNativeDigest,
    sessionID: ClipLiveShareSessionID,
    routeID: ClipLiveShareRouteID,
    viewerEphemeralPublicKey: ClipLiveShareKeyAgreementPublicKey,
    challenge: Data,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp,
    stateRevision: ClipLiveShareStateRevision
  ) throws {
    guard challenge.count == ClipLiveShareNativeV2.challengeByteCount else {
      throw ClipLiveShareNativeV2Error.invalidBinaryValue(
        name: "viewer challenge",
        expectedBytes: ClipLiveShareNativeV2.challengeByteCount
      )
    }
    try validateNativeV2Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV2.maximumChallengeLifetimeMilliseconds
    )
    self.sessionDescriptorDigest = sessionDescriptorDigest
    self.sessionID = sessionID
    self.routeID = routeID
    self.viewerEphemeralPublicKey = viewerEphemeralPublicKey
    self.challenge = challenge
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.stateRevision = stateRevision
  }

  public static func random(
    sessionDescriptorDigest: ClipLiveShareNativeDigest,
    sessionID: ClipLiveShareSessionID,
    routeID: ClipLiveShareRouteID,
    viewerEphemeralPublicKey: ClipLiveShareKeyAgreementPublicKey,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp,
    stateRevision: ClipLiveShareStateRevision
  ) throws -> Self {
    try Self(
      sessionDescriptorDigest: sessionDescriptorDigest,
      sessionID: sessionID,
      routeID: routeID,
      viewerEphemeralPublicKey: viewerEphemeralPublicKey,
      challenge: nativeV2SecureRandomData(count: ClipLiveShareNativeV2.challengeByteCount),
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      stateRevision: stateRevision
    )
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/viewer-proof"
    )
    encoder.append(sessionDescriptorDigest.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(routeID.rawValue)
    encoder.append(viewerEphemeralPublicKey.x963Representation)
    encoder.append(challenge)
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    encoder.append(stateRevision.rawValue)
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case sessionDescriptorDigest
    case sessionID = "sessionId"
    case routeID = "routeId"
    case viewerEphemeralPublicKey
    case challenge
    case issuedAt
    case expiresAt
    case stateRevision
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let challengeValue = try container.decode(String.self, forKey: .challenge)
    guard let challenge = ClipLiveShareBase64URL.decode(challengeValue) else {
      throw ClipLiveShareProtocolError.invalidBase64URL
    }
    try self.init(
      sessionDescriptorDigest: container.decode(
        ClipLiveShareNativeDigest.self,
        forKey: .sessionDescriptorDigest
      ),
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      routeID: container.decode(ClipLiveShareRouteID.self, forKey: .routeID),
      viewerEphemeralPublicKey: container.decode(
        ClipLiveShareKeyAgreementPublicKey.self,
        forKey: .viewerEphemeralPublicKey
      ),
      challenge: challenge,
      issuedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .issuedAt),
      expiresAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .expiresAt),
      stateRevision: container.decode(ClipLiveShareStateRevision.self, forKey: .stateRevision)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionDescriptorDigest, forKey: .sessionDescriptorDigest)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(routeID, forKey: .routeID)
    try container.encode(viewerEphemeralPublicKey, forKey: .viewerEphemeralPublicKey)
    try container.encode(ClipLiveShareBase64URL.encode(challenge), forKey: .challenge)
    try container.encode(issuedAt, forKey: .issuedAt)
    try container.encode(expiresAt, forKey: .expiresAt)
    try container.encode(stateRevision, forKey: .stateRevision)
  }
}

public struct ClipLiveShareSignedNativeViewerProof: Codable, Equatable, Hashable, Sendable {
  public let challenge: ClipLiveShareNativeViewerChallenge
  public let viewerIdentity: ClipLiveShareIdentityPublicKey
  public let signature: ClipLiveShareIdentitySignature

  public init(
    challenge: ClipLiveShareNativeViewerChallenge,
    viewerIdentity: ClipLiveShareIdentityPublicKey,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.challenge = challenge
    self.viewerIdentity = viewerIdentity
    self.signature = signature
  }

  public init(
    signing challenge: ClipLiveShareNativeViewerChallenge,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    self.challenge = challenge
    viewerIdentity = signer.publicKey
    signature = try signer.signature(
      for: Self.canonicalProofRepresentation(
        challenge: challenge,
        viewerIdentity: signer.publicKey
      )
    )
  }

  public var canonicalRepresentation: Data {
    Self.canonicalProofRepresentation(
      challenge: challenge,
      viewerIdentity: viewerIdentity
    )
  }

  public var digest: ClipLiveShareNativeDigest {
    // Replay identity is the signed statement, not its ECDSA encoding. ECDSA
    // signatures must never create multiple replay identities for one proof.
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  public func verify(
    expectedChallenge: ClipLiveShareNativeViewerChallenge,
    expectedIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    guard challenge == expectedChallenge else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }
    guard viewerIdentity == expectedIdentity else {
      throw ClipLiveShareNativeV2Error.identityMismatch
    }
    try validateNativeV2ValidityWindow(
      issuedAt: challenge.issuedAt,
      expiresAt: challenge.expiresAt,
      now: now
    )
    guard viewerIdentity.isValidSignature(signature, for: canonicalRepresentation) else {
      throw ClipLiveShareNativeV2Error.invalidSignature
    }
  }

  private static func canonicalProofRepresentation(
    challenge: ClipLiveShareNativeViewerChallenge,
    viewerIdentity: ClipLiveShareIdentityPublicKey
  ) -> Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/signed-viewer-proof"
    )
    encoder.append(challenge.canonicalRepresentation)
    encoder.append(viewerIdentity.x963Representation)
    return encoder.data
  }
}

public enum ClipLiveShareNativeControlCapability: String, Codable, CaseIterable, Equatable,
  Hashable, Sendable
{
  case streamLifecycle = "stream-lifecycle"
  case friends
}

/// The first native-only message sent on an established control DataChannel.
/// It lets the host distinguish a native Clip viewer from the browser v1
/// protocol before sending native stream lifecycle messages.
public struct ClipLiveShareNativeControlHello: Codable, Equatable, Hashable, Sendable {
  public static let currentCapabilities: Set<ClipLiveShareNativeControlCapability> = [
    .streamLifecycle,
    .friends,
  ]

  public let sessionID: ClipLiveShareSessionID
  public let viewerIdentity: ClipLiveShareIdentityPublicKey
  public let deviceName: String
  public let capabilities: Set<ClipLiveShareNativeControlCapability>
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    sessionID: ClipLiveShareSessionID,
    viewerIdentity: ClipLiveShareIdentityPublicKey,
    deviceName: String,
    capabilities: Set<ClipLiveShareNativeControlCapability> = Self.currentCapabilities,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    try validateNativeV2Text(
      deviceName,
      name: "native viewer device name",
      maximumUTF8Bytes: 128
    )
    guard !capabilities.isEmpty else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native control hello must advertise at least one capability"
      )
    }
    try validateNativeV2Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV2.maximumControlHelloLifetimeMilliseconds
    )
    self.sessionID = sessionID
    self.viewerIdentity = viewerIdentity
    self.deviceName = deviceName
    self.capabilities = capabilities
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/control-hello"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(viewerIdentity.x963Representation)
    encoder.append(deviceName)
    let sortedCapabilities = capabilities.sorted { $0.rawValue < $1.rawValue }
    encoder.append(UInt64(sortedCapabilities.count))
    for capability in sortedCapabilities { encoder.append(capability.rawValue) }
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case viewerIdentity
    case deviceName
    case capabilities
    case issuedAt
    case expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedCapabilities = try container.decode(
      [ClipLiveShareNativeControlCapability].self,
      forKey: .capabilities
    )
    let capabilities = Set(decodedCapabilities)
    guard capabilities.count == decodedCapabilities.count else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native control hello contains duplicate capabilities"
      )
    }
    try self.init(
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      viewerIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .viewerIdentity
      ),
      deviceName: container.decode(String.self, forKey: .deviceName),
      capabilities: capabilities,
      issuedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .issuedAt),
      expiresAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .expiresAt)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(viewerIdentity, forKey: .viewerIdentity)
    try container.encode(deviceName, forKey: .deviceName)
    try container.encode(
      capabilities.sorted { $0.rawValue < $1.rawValue },
      forKey: .capabilities
    )
    try container.encode(issuedAt, forKey: .issuedAt)
    try container.encode(expiresAt, forKey: .expiresAt)
  }
}

public struct ClipLiveShareSignedNativeControlHello: Codable, Equatable, Hashable, Sendable {
  public static let messageType = "native-control-hello"

  public let hello: ClipLiveShareNativeControlHello
  public let signature: ClipLiveShareIdentitySignature

  public init(
    hello: ClipLiveShareNativeControlHello,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.hello = hello
    self.signature = signature
  }

  public init(
    signing hello: ClipLiveShareNativeControlHello,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    guard signer.publicKey == hello.viewerIdentity else {
      throw ClipLiveShareNativeV2Error.identityMismatch
    }
    self.hello = hello
    signature = try signer.signature(for: hello.canonicalRepresentation)
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: hello.canonicalRepresentation)
  }

  /// Verifies a previously unknown native viewer's self-asserted identity and
  /// binds it to this control session. Trust remains an app policy decision.
  public func verify(
    expectedSessionID: ClipLiveShareSessionID,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    guard hello.sessionID == expectedSessionID else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }
    try validateNativeV2ValidityWindow(
      issuedAt: hello.issuedAt,
      expiresAt: hello.expiresAt,
      now: now
    )
    guard
      hello.viewerIdentity.isValidSignature(
        signature,
        for: hello.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV2Error.invalidSignature
    }
  }

  /// Adds pinned-contact verification when the host already knows the viewer.
  public func verify(
    expectedSessionID: ClipLiveShareSessionID,
    expectedIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    guard hello.viewerIdentity == expectedIdentity else {
      throw ClipLiveShareNativeV2Error.identityMismatch
    }
    try verify(expectedSessionID: expectedSessionID, at: now)
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case type
    case payload
    case signature
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ClipLiveShareNativeV2.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    let type = try container.decode(String.self, forKey: .type)
    guard type == Self.messageType else {
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown native control message type: \(type)"
      )
    }
    hello = try container.decode(ClipLiveShareNativeControlHello.self, forKey: .payload)
    signature = try container.decode(ClipLiveShareIdentitySignature.self, forKey: .signature)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ClipLiveShareNativeV2.version, forKey: .version)
    try container.encode(Self.messageType, forKey: .type)
    try container.encode(hello, forKey: .payload)
    try container.encode(signature, forKey: .signature)
  }
}

/// Bounded in-memory one-time-use guard. Cryptographic verification remains a
/// separate explicit step so callers cannot accidentally treat replay state as
/// identity verification.
public struct ClipLiveShareNativeReplayGuard: Equatable, Sendable {
  private struct Record: Equatable, Sendable {
    let digest: ClipLiveShareNativeDigest
    let expiresAt: ClipLiveShareNativeTimestamp
  }

  private var records: [Record] = []
  public let maximumRecords: Int

  public init(maximumRecords: Int = 256) throws {
    guard maximumRecords > 0 else {
      throw ClipLiveShareProtocolError.invalidResource("replay guard capacity must be positive")
    }
    self.maximumRecords = maximumRecords
  }

  public mutating func accept(
    digest: ClipLiveShareNativeDigest,
    expiresAt: ClipLiveShareNativeTimestamp,
    now: ClipLiveShareNativeTimestamp
  ) throws {
    records.removeAll { $0.expiresAt <= now }
    guard !records.contains(where: { $0.digest == digest }) else {
      throw ClipLiveShareNativeV2Error.replayed
    }
    if records.count == maximumRecords {
      records.removeFirst()
    }
    records.append(Record(digest: digest, expiresAt: expiresAt))
  }

  public mutating func accept(
    _ descriptor: ClipLiveShareSignedNativeSessionDescriptor,
    expectedIdentity: ClipLiveShareIdentityPublicKey,
    expectedContext: ClipLiveShareNativeRendezvousContext,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try descriptor.verify(
      expectedIdentity: expectedIdentity,
      expectedContext: expectedContext,
      at: now
    )
    try accept(
      digest: descriptor.descriptor.digest,
      expiresAt: descriptor.descriptor.expiresAt,
      now: now
    )
  }

  public mutating func accept(
    _ proof: ClipLiveShareSignedNativeViewerProof,
    expectedChallenge: ClipLiveShareNativeViewerChallenge,
    expectedIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try proof.verify(
      expectedChallenge: expectedChallenge,
      expectedIdentity: expectedIdentity,
      at: now
    )
    try accept(digest: proof.digest, expiresAt: proof.challenge.expiresAt, now: now)
  }

  public mutating func accept(
    _ hello: ClipLiveShareSignedNativeControlHello,
    expectedSessionID: ClipLiveShareSessionID,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try hello.verify(expectedSessionID: expectedSessionID, at: now)
    try accept(digest: hello.digest, expiresAt: hello.hello.expiresAt, now: now)
  }

  public mutating func accept(
    _ hello: ClipLiveShareSignedNativeControlHello,
    expectedSessionID: ClipLiveShareSessionID,
    expectedIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try hello.verify(
      expectedSessionID: expectedSessionID,
      expectedIdentity: expectedIdentity,
      at: now
    )
    try accept(digest: hello.digest, expiresAt: hello.hello.expiresAt, now: now)
  }
}
