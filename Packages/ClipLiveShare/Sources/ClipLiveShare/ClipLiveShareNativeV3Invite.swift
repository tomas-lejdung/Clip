import CryptoKit
import Foundation

/// Invitation resources for a native-v3 participant room.
///
/// The HTTPS rendezvous endpoint is an opaque introduction service; every
/// room starts directly in the participant mesh.
public enum ClipLiveShareNativeV3InviteProtocol {
  public static let version = 3
  public static let fragmentKey = "clip-native-v3"
  public static let rendezvousIDByteCount = 32
  public static let maximumInviteBytes = 4_096
  public static let maximumDescriptorBytes = 16_384
  public static let maximumKnockBytes = 2_048
  public static let maximumSealedKnockBytes = maximumKnockBytes + 64
  public static let maximumDescriptorLifetimeMilliseconds: Int64 = 10 * 60 * 1_000
}

public enum ClipLiveShareNativeV3InviteError: Error, Equatable, Sendable,
  LocalizedError
{
  case invalidEndpoint
  case invalidRendezvousID
  case invalidInvite
  case invalidDescriptor
  case descriptorMismatch
  case invalidKnock
  case invalidKnockAuthentication

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "The native-v3 room endpoint is invalid."
    case .invalidRendezvousID:
      "The native-v3 rendezvous identifier is invalid."
    case .invalidInvite:
      "The native-v3 room invitation is invalid."
    case .invalidDescriptor:
      "The native-v3 room descriptor is invalid."
    case .descriptorMismatch:
      "The native-v3 room descriptor does not match this invitation."
    case .invalidKnock:
      "The native-v3 admission knock is invalid."
    case .invalidKnockAuthentication:
      "The native-v3 admission knock failed authentication."
    }
  }
}

/// Random, session-scoped address at the opaque rendezvous service.
public struct ClipLiveShareNativeV3RendezvousID: Codable, Equatable, Hashable,
  Sendable, CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count
      == ClipLiveShareNativeV3InviteProtocol.rendezvousIDByteCount
    else {
      throw ClipLiveShareNativeV3InviteError.invalidRendezvousID
    }
    self.bytes = bytes
  }

  public init(rawValue: String) throws {
    guard let bytes = ClipLiveShareBase64URL.decode(rawValue) else {
      throw ClipLiveShareNativeV3InviteError.invalidRendezvousID
    }
    try self.init(bytes: bytes)
  }

  public static func random() -> Self {
    try! Self(
      bytes: nativeV3SecureRandomData(
        count: ClipLiveShareNativeV3InviteProtocol.rendezvousIDByteCount
      )
    )
  }

  public var rawValue: String { ClipLiveShareBase64URL.encode(bytes) }
  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Copyable native-v3 invite. The admission capability lives only in the URL
/// fragment, so an HTTPS rendezvous service never receives it.
public struct ClipLiveShareNativeV3Invite: Equatable, Hashable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let endpoint: URL
  public let rendezvousID: ClipLiveShareNativeV3RendezvousID
  public let sessionID: ClipLiveShareSessionID
  public let foundingCreatorIdentity: ClipLiveShareIdentityPublicKey
  public let leaderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let leaderIdentity: ClipLiveShareIdentityPublicKey
  public let leaderRendezvousPublicKey:
    ClipLiveShareKeyAgreementPublicKey
  public let admissionCapability: ClipLiveShareNativeV3AdmissionCapability

  public init(
    endpoint: URL,
    rendezvousID: ClipLiveShareNativeV3RendezvousID,
    sessionID: ClipLiveShareSessionID,
    foundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
    leaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    leaderIdentity: ClipLiveShareIdentityPublicKey,
    leaderRendezvousPublicKey: ClipLiveShareKeyAgreementPublicKey,
    admissionCapability: ClipLiveShareNativeV3AdmissionCapability
  ) throws {
    self.endpoint = try Self.validatedEndpoint(endpoint)
    self.rendezvousID = rendezvousID
    self.sessionID = sessionID
    self.foundingCreatorIdentity = foundingCreatorIdentity
    self.leaderParticipantID = leaderParticipantID
    self.leaderIdentity = leaderIdentity
    self.leaderRendezvousPublicKey = leaderRendezvousPublicKey
    self.admissionCapability = admissionCapability
  }

  public init(url: URL) throws {
    guard let fragment = url.fragment,
      fragment.hasPrefix(
        ClipLiveShareNativeV3InviteProtocol.fragmentKey + "="
      )
    else {
      throw ClipLiveShareNativeV3InviteError.invalidInvite
    }
    let encoded = String(
      fragment.dropFirst(
        ClipLiveShareNativeV3InviteProtocol.fragmentKey.utf8.count + 1
      )
    )
    guard
      let data = ClipLiveShareBase64URL.decode(encoded),
      !data.isEmpty,
      data.count <= ClipLiveShareNativeV3InviteProtocol.maximumInviteBytes
    else {
      throw ClipLiveShareNativeV3InviteError.invalidInvite
    }
    try Self.requireExactKeys(
      data,
      expected: [
        "version",
        "rendezvousId",
        "sessionId",
        "foundingCreatorIdentity",
        "leaderParticipantId",
        "leaderIdentity",
        "leaderRendezvousPublicKey",
        "admissionCapability",
      ],
      error: .invalidInvite
    )
    let payload: Payload
    do {
      payload = try JSONDecoder().decode(Payload.self, from: data)
    } catch {
      throw ClipLiveShareNativeV3InviteError.invalidInvite
    }
    guard payload.version == ClipLiveShareNativeV3InviteProtocol.version else {
      throw ClipLiveShareNativeV3InviteError.invalidInvite
    }
    var components = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false
    )
    components?.fragment = nil
    guard let endpoint = components?.url else {
      throw ClipLiveShareNativeV3InviteError.invalidEndpoint
    }
    try self.init(
      endpoint: endpoint,
      rendezvousID: payload.rendezvousID,
      sessionID: payload.sessionID,
      foundingCreatorIdentity: payload.foundingCreatorIdentity,
      leaderParticipantID: payload.leaderParticipantID,
      leaderIdentity: payload.leaderIdentity,
      leaderRendezvousPublicKey:
        payload.leaderRendezvousPublicKey,
      admissionCapability: payload.admissionCapability
    )
  }

  public var url: URL {
    get throws {
      let payload = Payload(
        version: ClipLiveShareNativeV3InviteProtocol.version,
        rendezvousID: rendezvousID,
        sessionID: sessionID,
        foundingCreatorIdentity: foundingCreatorIdentity,
        leaderParticipantID: leaderParticipantID,
        leaderIdentity: leaderIdentity,
        leaderRendezvousPublicKey: leaderRendezvousPublicKey,
        admissionCapability: admissionCapability
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(payload)
      guard data.count
        <= ClipLiveShareNativeV3InviteProtocol.maximumInviteBytes
      else {
        throw ClipLiveShareNativeV3InviteError.invalidInvite
      }
      var components = URLComponents(
        url: endpoint,
        resolvingAgainstBaseURL: false
      )
      components?.fragment =
        ClipLiveShareNativeV3InviteProtocol.fragmentKey
        + "="
        + ClipLiveShareBase64URL.encode(data)
      guard let url = components?.url else {
        throw ClipLiveShareNativeV3InviteError.invalidInvite
      }
      return url
    }
  }

  public var description: String {
    "ClipLiveShareNativeV3Invite(endpoint: \(endpoint), "
      + "rendezvousID: \(rendezvousID), sessionID: \(sessionID), "
      + "secrets: <redacted>)"
  }

  public var debugDescription: String { description }

  private struct Payload: Codable {
    let version: Int
    let rendezvousID: ClipLiveShareNativeV3RendezvousID
    let sessionID: ClipLiveShareSessionID
    let foundingCreatorIdentity: ClipLiveShareIdentityPublicKey
    let leaderParticipantID: ClipLiveShareNativeV3ParticipantID
    let leaderIdentity: ClipLiveShareIdentityPublicKey
    let leaderRendezvousPublicKey:
      ClipLiveShareKeyAgreementPublicKey
    let admissionCapability: ClipLiveShareNativeV3AdmissionCapability

    enum CodingKeys: String, CodingKey {
      case version
      case rendezvousID = "rendezvousId"
      case sessionID = "sessionId"
      case foundingCreatorIdentity
      case leaderParticipantID = "leaderParticipantId"
      case leaderIdentity
      case leaderRendezvousPublicKey
      case admissionCapability
    }
  }

  private static func validatedEndpoint(_ endpoint: URL) throws -> URL {
    guard
      let components = URLComponents(
        url: endpoint,
        resolvingAgainstBaseURL: false
      ),
      let scheme = components.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      components.host != nil,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.path.isEmpty || components.path == "/"
    else {
      throw ClipLiveShareNativeV3InviteError.invalidEndpoint
    }
    return endpoint
  }

  fileprivate static func requireExactKeys(
    _ data: Data,
    expected: Set<String>,
    error: ClipLiveShareNativeV3InviteError
  ) throws {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any],
      Set(dictionary.keys) == expected
    else {
      throw error
    }
  }
}

/// Public descriptor published at the opaque rendezvous before a candidate
/// route opens. Its signature prevents the service from swapping the current
/// leader, room encryption key, or session context.
public struct ClipLiveShareSignedNativeV3RoomDescriptor: Codable, Equatable,
  Hashable, Sendable
{
  public let descriptor: ClipLiveShareNativeV3RoomDescriptor
  public let signature: ClipLiveShareIdentitySignature

  public init(
    descriptor: ClipLiveShareNativeV3RoomDescriptor,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.descriptor = descriptor
    self.signature = signature
  }

  public init(
    signing descriptor: ClipLiveShareNativeV3RoomDescriptor,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    guard signer.publicKey == descriptor.leaderIdentity else {
      throw ClipLiveShareNativeV3Error.identityMismatch
    }
    self.descriptor = descriptor
    signature = try signer.signature(
      for: descriptor.canonicalRepresentation
    )
  }

  public func verify(
    matching invite: ClipLiveShareNativeV3Invite,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    guard
      descriptor.rendezvousID == invite.rendezvousID,
      descriptor.sessionID == invite.sessionID,
      descriptor.foundingCreatorIdentity
        == invite.foundingCreatorIdentity,
      descriptor.leaderParticipantID == invite.leaderParticipantID,
      descriptor.leaderIdentity == invite.leaderIdentity,
      descriptor.leaderRendezvousPublicKey
        == invite.leaderRendezvousPublicKey
    else {
      throw ClipLiveShareNativeV3InviteError.descriptorMismatch
    }
    try validateNativeV3Lifetime(
      issuedAt: descriptor.issuedAt,
      expiresAt: descriptor.expiresAt,
      maximumMilliseconds:
        ClipLiveShareNativeV3InviteProtocol
        .maximumDescriptorLifetimeMilliseconds
    )
    guard now >= descriptor.issuedAt, now < descriptor.expiresAt else {
      throw now < descriptor.issuedAt
        ? ClipLiveShareNativeV3Error.notYetValid
        : ClipLiveShareNativeV3Error.expired
    }
    guard
      descriptor.leaderIdentity.isValidSignature(
        signature,
        for: descriptor.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV3Error.invalidSignature
    }
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard data.count
      <= ClipLiveShareNativeV3InviteProtocol.maximumDescriptorBytes
    else {
      throw ClipLiveShareNativeV3InviteError.invalidDescriptor
    }
    return data
  }

  public static func decode(_ data: Data) throws -> Self {
    guard
      !data.isEmpty,
      data.count <= ClipLiveShareNativeV3InviteProtocol.maximumDescriptorBytes
    else {
      throw ClipLiveShareNativeV3InviteError.invalidDescriptor
    }
    try ClipLiveShareNativeV3Invite.requireExactKeys(
      data,
      expected: ["descriptor", "signature"],
      error: .invalidDescriptor
    )
    do {
      return try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw ClipLiveShareNativeV3InviteError.invalidDescriptor
    }
  }
}

public struct ClipLiveShareNativeV3RoomDescriptor: Codable, Equatable,
  Hashable, Sendable
{
  public let version: Int
  public let rendezvousID: ClipLiveShareNativeV3RendezvousID
  public let sessionID: ClipLiveShareSessionID
  public let foundingCreatorIdentity: ClipLiveShareIdentityPublicKey
  public let leaderParticipantID: ClipLiveShareNativeV3ParticipantID
  public let leaderIdentity: ClipLiveShareIdentityPublicKey
  public let leaderRendezvousPublicKey:
    ClipLiveShareKeyAgreementPublicKey
  /// Signed admission hint. The secret itself is never placed in the
  /// descriptor or invite; this bit only lets a candidate ask for it before
  /// transmitting its authenticated bootstrap hello.
  public let accessWordRequired: Bool
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    rendezvousID: ClipLiveShareNativeV3RendezvousID,
    sessionID: ClipLiveShareSessionID,
    foundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
    leaderParticipantID: ClipLiveShareNativeV3ParticipantID,
    leaderIdentity: ClipLiveShareIdentityPublicKey,
    leaderRendezvousPublicKey: ClipLiveShareKeyAgreementPublicKey,
    accessWordRequired: Bool = false,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    try validateNativeV3Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds:
        ClipLiveShareNativeV3InviteProtocol
        .maximumDescriptorLifetimeMilliseconds
    )
    version = ClipLiveShareNativeV3InviteProtocol.version
    self.rendezvousID = rendezvousID
    self.sessionID = sessionID
    self.foundingCreatorIdentity = foundingCreatorIdentity
    self.leaderParticipantID = leaderParticipantID
    self.leaderIdentity = leaderIdentity
    self.leaderRendezvousPublicKey = leaderRendezvousPublicKey
    self.accessWordRequired = accessWordRequired
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/room-descriptor"
    )
    encoder.append(UInt64(version))
    encoder.append(rendezvousID.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(foundingCreatorIdentity.x963Representation)
    encoder.append(leaderParticipantID.bytes)
    encoder.append(leaderIdentity.x963Representation)
    encoder.append(leaderRendezvousPublicKey.x963Representation)
    encoder.append(accessWordRequired)
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case version
    case rendezvousID = "rendezvousId"
    case sessionID = "sessionId"
    case foundingCreatorIdentity
    case leaderParticipantID = "leaderParticipantId"
    case leaderIdentity
    case leaderRendezvousPublicKey
    case accessWordRequired
    case issuedAt
    case expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      Set(container.allKeys)
        == Set(CodingKeys.allCases),
      try container.decode(Int.self, forKey: .version)
        == ClipLiveShareNativeV3InviteProtocol.version
    else {
      throw ClipLiveShareNativeV3InviteError.invalidDescriptor
    }
    try self.init(
      rendezvousID: container.decode(
        ClipLiveShareNativeV3RendezvousID.self,
        forKey: .rendezvousID
      ),
      sessionID: container.decode(
        ClipLiveShareSessionID.self,
        forKey: .sessionID
      ),
      foundingCreatorIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .foundingCreatorIdentity
      ),
      leaderParticipantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .leaderParticipantID
      ),
      leaderIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .leaderIdentity
      ),
      leaderRendezvousPublicKey: container.decode(
        ClipLiveShareKeyAgreementPublicKey.self,
        forKey: .leaderRendezvousPublicKey
      ),
      accessWordRequired: container.decode(
        Bool.self,
        forKey: .accessWordRequired
      ),
      issuedAt: container.decode(
        ClipLiveShareNativeTimestamp.self,
        forKey: .issuedAt
      ),
      expiresAt: container.decode(
        ClipLiveShareNativeTimestamp.self,
        forKey: .expiresAt
      )
    )
  }
}

/// Authenticated cleartext preface used only to tell the room leader which
/// ephemeral P-256 key should decrypt the immediately following v3 envelope.
/// The key is public; the HMAC prevents a relay from substituting it.
public struct ClipLiveShareNativeV3RendezvousKnock: Codable, Equatable,
  Hashable, Sendable
{
  public let version: Int
  public let sessionID: ClipLiveShareSessionID
  public let rendezvousID: ClipLiveShareNativeV3RendezvousID
  public let routeID: ClipLiveShareRouteID
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let ephemeralPublicKey: ClipLiveShareKeyAgreementPublicKey
  public let authentication: ClipLiveShareNativeDigest

  public init(
    sessionID: ClipLiveShareSessionID,
    rendezvousID: ClipLiveShareNativeV3RendezvousID,
    routeID: ClipLiveShareRouteID,
    participantID: ClipLiveShareNativeV3ParticipantID,
    ephemeralPublicKey: ClipLiveShareKeyAgreementPublicKey,
    admissionCapability: ClipLiveShareNativeV3AdmissionCapability
  ) {
    version = ClipLiveShareNativeV3InviteProtocol.version
    self.sessionID = sessionID
    self.rendezvousID = rendezvousID
    self.routeID = routeID
    self.participantID = participantID
    self.ephemeralPublicKey = ephemeralPublicKey
    authentication = Self.authentication(
      sessionID: sessionID,
      rendezvousID: rendezvousID,
      routeID: routeID,
      participantID: participantID,
      ephemeralPublicKey: ephemeralPublicKey,
      admissionCapability: admissionCapability
    )
  }

  public func verify(
    expectedSessionID: ClipLiveShareSessionID,
    expectedRendezvousID: ClipLiveShareNativeV3RendezvousID,
    expectedRouteID: ClipLiveShareRouteID,
    admissionCapability: ClipLiveShareNativeV3AdmissionCapability
  ) throws {
    guard
      version == ClipLiveShareNativeV3InviteProtocol.version,
      sessionID == expectedSessionID,
      rendezvousID == expectedRendezvousID,
      routeID == expectedRouteID
    else {
      throw ClipLiveShareNativeV3InviteError.invalidKnock
    }
    let expected = Self.authentication(
      sessionID: sessionID,
      rendezvousID: rendezvousID,
      routeID: routeID,
      participantID: participantID,
      ephemeralPublicKey: ephemeralPublicKey,
      admissionCapability: admissionCapability
    )
    guard expected == authentication else {
      throw ClipLiveShareNativeV3InviteError.invalidKnockAuthentication
    }
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(self)
    guard data.count
      <= ClipLiveShareNativeV3InviteProtocol.maximumKnockBytes
    else {
      throw ClipLiveShareNativeV3InviteError.invalidKnock
    }
    return data
  }

  /// Encrypts the key-agreement preface with the invitation capability. The
  /// rendezvous service therefore sees only a packet kind and ciphertext,
  /// never the candidate identity or ephemeral public key.
  public func sealed(
    with admissionCapability: ClipLiveShareNativeV3AdmissionCapability
  ) throws -> Data {
    let plaintext = try encoded()
    let context = Self.sealingContext(
      sessionID: sessionID,
      rendezvousID: rendezvousID,
      routeID: routeID
    )
    let key = Self.sealingKey(
      admissionCapability: admissionCapability,
      rendezvousID: rendezvousID,
      context: context
    )
    let sealed = try AES.GCM.seal(
      plaintext,
      using: key,
      authenticating: context
    )
    guard
      let combined = sealed.combined,
      combined.count
        <= ClipLiveShareNativeV3InviteProtocol.maximumSealedKnockBytes
    else {
      throw ClipLiveShareNativeV3InviteError.invalidKnock
    }
    return combined
  }

  public static func openSealed(
    _ data: Data,
    expectedSessionID: ClipLiveShareSessionID,
    expectedRendezvousID: ClipLiveShareNativeV3RendezvousID,
    expectedRouteID: ClipLiveShareRouteID,
    admissionCapability: ClipLiveShareNativeV3AdmissionCapability
  ) throws -> Self {
    guard
      data.count >= 12 + 16,
      data.count
        <= ClipLiveShareNativeV3InviteProtocol.maximumSealedKnockBytes
    else {
      throw ClipLiveShareNativeV3InviteError.invalidKnock
    }
    let context = sealingContext(
      sessionID: expectedSessionID,
      rendezvousID: expectedRendezvousID,
      routeID: expectedRouteID
    )
    let key = sealingKey(
      admissionCapability: admissionCapability,
      rendezvousID: expectedRendezvousID,
      context: context
    )
    let plaintext: Data
    do {
      plaintext = try AES.GCM.open(
        AES.GCM.SealedBox(combined: data),
        using: key,
        authenticating: context
      )
    } catch {
      throw ClipLiveShareNativeV3InviteError
        .invalidKnockAuthentication
    }
    let knock = try decode(plaintext)
    try knock.verify(
      expectedSessionID: expectedSessionID,
      expectedRendezvousID: expectedRendezvousID,
      expectedRouteID: expectedRouteID,
      admissionCapability: admissionCapability
    )
    return knock
  }

  public static func decode(_ data: Data) throws -> Self {
    guard
      !data.isEmpty,
      data.count <= ClipLiveShareNativeV3InviteProtocol.maximumKnockBytes
    else {
      throw ClipLiveShareNativeV3InviteError.invalidKnock
    }
    try ClipLiveShareNativeV3Invite.requireExactKeys(
      data,
      expected: [
        "version",
        "sessionId",
        "rendezvousId",
        "routeId",
        "participantId",
        "ephemeralPublicKey",
        "authentication",
      ],
      error: .invalidKnock
    )
    do {
      return try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw ClipLiveShareNativeV3InviteError.invalidKnock
    }
  }

  private static func authentication(
    sessionID: ClipLiveShareSessionID,
    rendezvousID: ClipLiveShareNativeV3RendezvousID,
    routeID: ClipLiveShareRouteID,
    participantID: ClipLiveShareNativeV3ParticipantID,
    ephemeralPublicKey: ClipLiveShareKeyAgreementPublicKey,
    admissionCapability: ClipLiveShareNativeV3AdmissionCapability
  ) -> ClipLiveShareNativeDigest {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/rendezvous-knock"
    )
    encoder.append(UInt64(ClipLiveShareNativeV3InviteProtocol.version))
    encoder.append(sessionID.rawValue)
    encoder.append(rendezvousID.bytes)
    encoder.append(routeID.rawValue)
    encoder.append(participantID.bytes)
    encoder.append(ephemeralPublicKey.x963Representation)
    let code = HMAC<SHA256>.authenticationCode(
      for: encoder.data,
      using: SymmetricKey(data: admissionCapability.keyMaterial)
    )
    return try! .init(bytes: Data(code))
  }

  private static func sealingContext(
    sessionID: ClipLiveShareSessionID,
    rendezvousID: ClipLiveShareNativeV3RendezvousID,
    routeID: ClipLiveShareRouteID
  ) -> Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/rendezvous-knock-seal"
    )
    encoder.append(UInt64(ClipLiveShareNativeV3InviteProtocol.version))
    encoder.append(sessionID.rawValue)
    encoder.append(rendezvousID.bytes)
    encoder.append(routeID.rawValue)
    return encoder.data
  }

  private static func sealingKey(
    admissionCapability: ClipLiveShareNativeV3AdmissionCapability,
    rendezvousID: ClipLiveShareNativeV3RendezvousID,
    context: Data
  ) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(
        data: admissionCapability.keyMaterial
      ),
      salt: rendezvousID.bytes,
      info: context,
      outputByteCount: 32
    )
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case sessionID = "sessionId"
    case rendezvousID = "rendezvousId"
    case routeID = "routeId"
    case participantID = "participantId"
    case ephemeralPublicKey
    case authentication
  }
}
