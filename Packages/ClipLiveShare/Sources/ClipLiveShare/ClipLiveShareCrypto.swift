import CryptoKit
import Foundation

public struct ClipLiveShareRoomIdentity: Sendable {
  fileprivate let privateKey: P256.KeyAgreement.PrivateKey

  public init() {
    privateKey = P256.KeyAgreement.PrivateKey()
  }

  init(privateKeyRawRepresentation: Data) throws {
    privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRawRepresentation)
  }

  public var publicKey: ClipLiveShareKeyAgreementPublicKey {
    try! ClipLiveShareKeyAgreementPublicKey(
      x963Representation: privateKey.publicKey.x963Representation
    )
  }
}

public struct ClipLiveShareViewerIdentity: Sendable {
  fileprivate let privateKey: P256.KeyAgreement.PrivateKey

  public init() {
    privateKey = P256.KeyAgreement.PrivateKey()
  }

  init(privateKeyRawRepresentation: Data) throws {
    privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRawRepresentation)
  }

  public var publicKey: ClipLiveShareKeyAgreementPublicKey {
    try! ClipLiveShareKeyAgreementPublicKey(
      x963Representation: privateKey.publicKey.x963Representation
    )
  }
}

public struct ClipLiveShareViewerFragment: Equatable, Hashable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let version: Int
  public let publicKey: ClipLiveShareKeyAgreementPublicKey
  public let joinCapability: ClipLiveShareJoinCapability

  public init(
    version: Int = ClipLiveShareV1.version,
    publicKey: ClipLiveShareKeyAgreementPublicKey,
    joinCapability: ClipLiveShareJoinCapability
  ) throws {
    guard version == ClipLiveShareV1.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    self.version = version
    self.publicKey = publicKey
    self.joinCapability = joinCapability
  }

  public init(fragment: String) throws {
    let value = fragment.hasPrefix("#") ? String(fragment.dropFirst()) : fragment
    guard !value.isEmpty, value.utf8.count <= 1_024 else {
      throw ClipLiveShareProtocolError.invalidResource("invalid viewer URL fragment")
    }
    var fields: [String: String] = [:]
    for component in value.split(separator: "&", omittingEmptySubsequences: false) {
      let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else {
        throw ClipLiveShareProtocolError.invalidResource("invalid viewer URL fragment")
      }
      let key = String(pair[0])
      let fieldValue = String(pair[1])
      guard
        ["v", "key", "join"].contains(key),
        fields.updateValue(fieldValue, forKey: key) == nil
      else {
        throw ClipLiveShareProtocolError.invalidResource("invalid viewer URL fragment fields")
      }
    }
    guard fields.count == 3, let versionValue = fields["v"], let version = Int(versionValue) else {
      throw ClipLiveShareProtocolError.invalidResource("incomplete viewer URL fragment")
    }
    guard let keyValue = fields["key"], let joinValue = fields["join"] else {
      throw ClipLiveShareProtocolError.invalidResource(
        "viewer URL fragment has no key or join capability"
      )
    }
    try self.init(
      version: version,
      publicKey: ClipLiveShareKeyAgreementPublicKey(rawValue: keyValue),
      joinCapability: ClipLiveShareJoinCapability(rawValue: joinValue)
    )
  }

  public init(url: URL) throws {
    guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment else {
      throw ClipLiveShareProtocolError.invalidResource("viewer URL has no fragment")
    }
    try self.init(fragment: fragment)
  }

  public var rawValue: String {
    "v=\(version)&key=\(publicKey.rawValue)&join=\(joinCapability.rawValue)"
  }
  public var description: String { "<redacted viewer fragment>" }
  public var debugDescription: String { description }

  public func adding(to url: URL) throws -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw ClipLiveShareProtocolError.invalidResource("invalid viewer URL")
    }
    guard components.fragment == nil else {
      throw ClipLiveShareProtocolError.invalidResource("viewer URL already has a fragment")
    }
    components.percentEncodedFragment = rawValue
    guard let result = components.url else {
      throw ClipLiveShareProtocolError.invalidResource("could not construct viewer URL")
    }
    return result
  }
}

public enum ClipLiveShareAdmissionProof {
  private static let joinDomain = "clip-live-share-v1/join-proof"
  private static let accessCodeDomain = "clip-live-share-v1/access-code-proof"

  public static func normalizeAccessCode(_ accessCode: String) -> String {
    accessCode
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased(with: Locale(identifier: "en_US_POSIX"))
  }

  public static func makeJoinProof(
    joinCapability: ClipLiveShareJoinCapability,
    challenge: Data,
    room: ClipLiveShareRoomName,
    sessionID: ClipLiveShareSessionID,
    routeID: ClipLiveShareRouteID,
    viewerPublicKey: ClipLiveShareKeyAgreementPublicKey
  ) throws -> Data {
    let authenticatedData = try authenticatedData(
      domain: joinDomain,
      challenge: challenge,
      room: room,
      sessionID: sessionID,
      routeID: routeID,
      viewerPublicKey: viewerPublicKey
    )
    let key = SymmetricKey(data: joinCapability.keyMaterial)
    return Data(HMAC<SHA256>.authenticationCode(for: authenticatedData, using: key))
  }

  public static func verifyJoinProof(
    _ proof: Data,
    joinCapability: ClipLiveShareJoinCapability,
    challenge: Data,
    room: ClipLiveShareRoomName,
    sessionID: ClipLiveShareSessionID,
    routeID: ClipLiveShareRouteID,
    viewerPublicKey: ClipLiveShareKeyAgreementPublicKey
  ) -> Bool {
    guard proof.count == SHA256.byteCount else { return false }
    guard
      let authenticatedData = try? authenticatedData(
        domain: joinDomain,
        challenge: challenge,
        room: room,
        sessionID: sessionID,
        routeID: routeID,
        viewerPublicKey: viewerPublicKey
      )
    else { return false }
    let key = SymmetricKey(data: joinCapability.keyMaterial)
    return HMAC<SHA256>.isValidAuthenticationCode(
      proof,
      authenticating: authenticatedData,
      using: key
    )
  }

  public static func makeAccessCodeProof(
    accessCode: String,
    challenge: Data,
    room: ClipLiveShareRoomName,
    sessionID: ClipLiveShareSessionID,
    routeID: ClipLiveShareRouteID,
    viewerPublicKey: ClipLiveShareKeyAgreementPublicKey
  ) throws -> Data {
    let normalized = normalizeAccessCode(accessCode)
    guard !normalized.isEmpty else {
      throw ClipLiveShareProtocolError.accessCodeRequired
    }
    let authenticatedData = try authenticatedData(
      domain: accessCodeDomain,
      challenge: challenge,
      room: room,
      sessionID: sessionID,
      routeID: routeID,
      viewerPublicKey: viewerPublicKey
    )
    let digest = SHA256.hash(data: Data(normalized.utf8))
    let key = SymmetricKey(data: Data(digest))
    return Data(HMAC<SHA256>.authenticationCode(for: authenticatedData, using: key))
  }

  public static func verifyAccessCodeProof(
    _ proof: Data,
    accessCode: String,
    challenge: Data,
    room: ClipLiveShareRoomName,
    sessionID: ClipLiveShareSessionID,
    routeID: ClipLiveShareRouteID,
    viewerPublicKey: ClipLiveShareKeyAgreementPublicKey
  ) -> Bool {
    guard proof.count == SHA256.byteCount else { return false }
    let normalized = normalizeAccessCode(accessCode)
    guard !normalized.isEmpty else { return false }
    guard
      let authenticatedData = try? authenticatedData(
        domain: accessCodeDomain,
        challenge: challenge,
        room: room,
        sessionID: sessionID,
        routeID: routeID,
        viewerPublicKey: viewerPublicKey
      )
    else { return false }
    let digest = SHA256.hash(data: Data(normalized.utf8))
    let key = SymmetricKey(data: Data(digest))
    return HMAC<SHA256>.isValidAuthenticationCode(
      proof,
      authenticating: authenticatedData,
      using: key
    )
  }

  public static func response(
    to challenge: ClipLiveShareAuthChallenge,
    joinCapability: ClipLiveShareJoinCapability,
    accessCode: String?,
    room: ClipLiveShareRoomName,
    routeID: ClipLiveShareRouteID,
    viewerPublicKey: ClipLiveShareKeyAgreementPublicKey
  ) throws -> ClipLiveShareAuthResponse {
    let joinProof = try makeJoinProof(
      joinCapability: joinCapability,
      challenge: challenge.challenge,
      room: room,
      sessionID: challenge.sessionID,
      routeID: routeID,
      viewerPublicKey: viewerPublicKey
    )
    let accessCodeProof: Data?
    if challenge.accessCodeRequired {
      guard let accessCode else { throw ClipLiveShareProtocolError.accessCodeRequired }
      accessCodeProof = try makeAccessCodeProof(
        accessCode: accessCode,
        challenge: challenge.challenge,
        room: room,
        sessionID: challenge.sessionID,
        routeID: routeID,
        viewerPublicKey: viewerPublicKey
      )
    } else {
      accessCodeProof = nil
    }
    return try ClipLiveShareAuthResponse(
      sessionID: challenge.sessionID,
      joinProof: joinProof,
      accessCodeProof: accessCodeProof
    )
  }

  public static func verify(
    _ response: ClipLiveShareAuthResponse,
    challenge: ClipLiveShareAuthChallenge,
    joinCapability: ClipLiveShareJoinCapability,
    accessCode: String?,
    room: ClipLiveShareRoomName,
    routeID: ClipLiveShareRouteID,
    viewerPublicKey: ClipLiveShareKeyAgreementPublicKey
  ) -> Bool {
    guard response.sessionID == challenge.sessionID else { return false }
    let configuredAccessCode = accessCode.map(normalizeAccessCode).flatMap {
      $0.isEmpty ? nil : $0
    }
    guard challenge.accessCodeRequired == (configuredAccessCode != nil) else { return false }
    guard verifyJoinProof(
      response.joinProof,
      joinCapability: joinCapability,
      challenge: challenge.challenge,
      room: room,
      sessionID: challenge.sessionID,
      routeID: routeID,
      viewerPublicKey: viewerPublicKey
    ) else { return false }

    if challenge.accessCodeRequired {
      guard
        let configuredAccessCode,
        let accessCodeProof = response.accessCodeProof
      else { return false }
      return verifyAccessCodeProof(
        accessCodeProof,
        accessCode: configuredAccessCode,
        challenge: challenge.challenge,
        room: room,
        sessionID: challenge.sessionID,
        routeID: routeID,
        viewerPublicKey: viewerPublicKey
      )
    }
    return response.accessCodeProof == nil
  }

  private static func authenticatedData(
    domain: String,
    challenge: Data,
    room: ClipLiveShareRoomName,
    sessionID: ClipLiveShareSessionID,
    routeID: ClipLiveShareRouteID,
    viewerPublicKey: ClipLiveShareKeyAgreementPublicKey
  ) throws -> Data {
    guard challenge.count == ClipLiveShareV1.challengeByteCount else {
      throw ClipLiveShareProtocolError.invalidResource("auth challenge must contain 32 bytes")
    }
    let fields = [
      Data(domain.utf8),
      Data(room.rawValue.utf8),
      Data(sessionID.rawValue.utf8),
      Data(routeID.rawValue.utf8),
      viewerPublicKey.x963Representation,
      challenge,
    ]
    var data = Data()
    for field in fields {
      var length = UInt32(field.count).bigEndian
      withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
      data.append(field)
    }
    return data
  }
}

public enum ClipLiveShareChannelRole: String, Codable, Equatable, Hashable, Sendable {
  case host
  case viewer
}

public enum ClipLiveShareEncryptionDirection: String, Codable, Equatable, Hashable, Sendable {
  case hostToViewer = "host-to-viewer"
  case viewerToHost = "viewer-to-host"
}

public struct ClipLiveShareEncryptedChannel: Sendable {
  public let room: ClipLiveShareRoomName
  public let routeID: ClipLiveShareRouteID
  public let role: ClipLiveShareChannelRole

  private let outboundKey: SymmetricKey
  private let inboundKey: SymmetricKey
  private let outboundDirection: ClipLiveShareEncryptionDirection
  private let inboundDirection: ClipLiveShareEncryptionDirection
  public private(set) var lastOutboundSequence: UInt64 = 0
  public private(set) var lastInboundSequence: UInt64 = 0

  public init(
    host identity: ClipLiveShareRoomIdentity,
    viewerPublicKey: ClipLiveShareKeyAgreementPublicKey,
    room: ClipLiveShareRoomName,
    routeID: ClipLiveShareRouteID
  ) throws {
    let remoteKey = try P256.KeyAgreement.PublicKey(
      x963Representation: viewerPublicKey.x963Representation
    )
    let secret = try identity.privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
    try self.init(sharedSecret: secret, room: room, routeID: routeID, role: .host)
  }

  public init(
    viewer identity: ClipLiveShareViewerIdentity,
    roomPublicKey: ClipLiveShareKeyAgreementPublicKey,
    room: ClipLiveShareRoomName,
    routeID: ClipLiveShareRouteID
  ) throws {
    let remoteKey = try P256.KeyAgreement.PublicKey(
      x963Representation: roomPublicKey.x963Representation
    )
    let secret = try identity.privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
    try self.init(sharedSecret: secret, room: room, routeID: routeID, role: .viewer)
  }

  private init(
    sharedSecret: SharedSecret,
    room: ClipLiveShareRoomName,
    routeID: ClipLiveShareRouteID,
    role: ClipLiveShareChannelRole
  ) throws {
    let hostToViewer = Self.deriveKey(
      sharedSecret: sharedSecret,
      room: room,
      routeID: routeID,
      direction: .hostToViewer
    )
    let viewerToHost = Self.deriveKey(
      sharedSecret: sharedSecret,
      room: room,
      routeID: routeID,
      direction: .viewerToHost
    )

    self.room = room
    self.routeID = routeID
    self.role = role
    switch role {
    case .host:
      outboundKey = hostToViewer
      inboundKey = viewerToHost
      outboundDirection = .hostToViewer
      inboundDirection = .viewerToHost
    case .viewer:
      outboundKey = viewerToHost
      inboundKey = hostToViewer
      outboundDirection = .viewerToHost
      inboundDirection = .hostToViewer
    }
  }

  public mutating func seal(_ message: ClipLiveShareInnerMessage) throws
    -> ClipLiveShareRelayEnvelope
  {
    try seal(message, nonce: Data(AES.GCM.Nonce()))
  }

  /// Encrypts an opaque application payload with the same route, direction,
  /// ordering, and replay guarantees as the v1 signaling messages.
  ///
  /// Native rendezvous uses this for its signed challenge/proof exchange. The
  /// signaling service can relay the envelope but cannot identify or decode
  /// the payload carried inside it.
  public mutating func sealOpaquePayload(_ payload: Data) throws
    -> ClipLiveShareRelayEnvelope
  {
    try sealOpaquePayload(payload, nonce: Data(AES.GCM.Nonce()))
  }

  func derivedKeyBytes(for direction: ClipLiveShareEncryptionDirection) -> Data {
    let key = direction == outboundDirection ? outboundKey : inboundKey
    return key.withUnsafeBytes { Data($0) }
  }

  mutating func seal(
    _ message: ClipLiveShareInnerMessage,
    nonce: Data
  ) throws -> ClipLiveShareRelayEnvelope {
    let plaintext = try ClipLiveShareMessageCodec.encodeInner(message)
    return try sealOpaquePayload(plaintext, nonce: nonce)
  }

  mutating func sealOpaquePayload(
    _ payload: Data,
    nonce: Data
  ) throws -> ClipLiveShareRelayEnvelope {
    guard lastOutboundSequence < UInt64.max else {
      throw ClipLiveShareProtocolError.invalidResource("encrypted sequence exhausted")
    }
    guard nonce.count == ClipLiveShareV1.nonceByteCount else {
      throw ClipLiveShareProtocolError.invalidNonceLength(nonce.count)
    }
    guard payload.count <= ClipLiveShareV1.maximumInnerMessageBytes else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum: ClipLiveShareV1.maximumInnerMessageBytes,
        actual: payload.count
      )
    }

    let sequence = lastOutboundSequence + 1
    let authenticatedData = additionalAuthenticatedData(
      direction: outboundDirection,
      sequence: sequence
    )
    let sealed = try AES.GCM.seal(
      payload,
      using: outboundKey,
      nonce: try AES.GCM.Nonce(data: nonce),
      authenticating: authenticatedData
    )
    var ciphertext = sealed.ciphertext
    ciphertext.append(sealed.tag)
    let envelope = try ClipLiveShareRelayEnvelope(
      routeID: role == .host ? routeID : nil,
      sequence: sequence,
      nonce: nonce,
      ciphertext: ciphertext
    )
    lastOutboundSequence = sequence
    return envelope
  }

  public mutating func open(_ envelope: ClipLiveShareRelayEnvelope) throws
    -> ClipLiveShareInnerMessage
  {
    let plaintext = try decryptOpaquePayload(envelope)
    let message = try ClipLiveShareMessageCodec.decodeInner(plaintext)
    lastInboundSequence = envelope.sequence
    return message
  }

  /// Decrypts an opaque application payload and advances the inbound replay
  /// counter only after successful authentication.
  public mutating func openOpaquePayload(_ envelope: ClipLiveShareRelayEnvelope) throws
    -> Data
  {
    let plaintext = try decryptOpaquePayload(envelope)
    lastInboundSequence = envelope.sequence
    return plaintext
  }

  private func decryptOpaquePayload(_ envelope: ClipLiveShareRelayEnvelope) throws -> Data {
    guard envelope.routeID == routeID else {
      throw ClipLiveShareProtocolError.routeMismatch(expected: routeID, actual: envelope.routeID)
    }
    let expected = lastInboundSequence + 1
    guard envelope.sequence == expected else {
      throw ClipLiveShareProtocolError.invalidSequence(expected: expected, actual: envelope.sequence)
    }
    guard envelope.ciphertext.count >= 16 else {
      throw ClipLiveShareProtocolError.authenticationFailed
    }

    let ciphertext = envelope.ciphertext.dropLast(16)
    let tag = envelope.ciphertext.suffix(16)
    let sealedBox: AES.GCM.SealedBox
    do {
      sealedBox = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: envelope.nonce),
        ciphertext: ciphertext,
        tag: tag
      )
    } catch {
      throw ClipLiveShareProtocolError.authenticationFailed
    }

    let plaintext: Data
    do {
      plaintext = try AES.GCM.open(
        sealedBox,
        using: inboundKey,
        authenticating: additionalAuthenticatedData(
          direction: inboundDirection,
          sequence: envelope.sequence
        )
      )
    } catch {
      throw ClipLiveShareProtocolError.authenticationFailed
    }
    guard plaintext.count <= ClipLiveShareV1.maximumInnerMessageBytes else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum: ClipLiveShareV1.maximumInnerMessageBytes,
        actual: plaintext.count
      )
    }

    return plaintext
  }

  private static func deriveKey(
    sharedSecret: SharedSecret,
    room: ClipLiveShareRoomName,
    routeID: ClipLiveShareRouteID,
    direction: ClipLiveShareEncryptionDirection
  ) -> SymmetricKey {
    let saltMaterial = Data(
      "\(ClipLiveShareV1.protocolIdentifier)|\(ClipLiveShareV1.version)|\(room.rawValue)|\(routeID.rawValue)".utf8
    )
    let salt = Data(SHA256.hash(data: saltMaterial))
    return sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: salt,
      sharedInfo: Data(direction.rawValue.utf8),
      outputByteCount: 32
    )
  }

  private func additionalAuthenticatedData(
    direction: ClipLiveShareEncryptionDirection,
    sequence: UInt64
  ) -> Data {
    Data(
      "\(ClipLiveShareV1.protocolIdentifier)|\(ClipLiveShareV1.version)|\(room.rawValue)|\(routeID.rawValue)|\(direction.rawValue)|\(sequence)".utf8
    )
  }
}
