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
  CustomStringConvertible
{
  public let version: Int
  public let publicKey: ClipLiveShareKeyAgreementPublicKey

  public init(
    version: Int = ClipLiveShareV1.version,
    publicKey: ClipLiveShareKeyAgreementPublicKey
  ) throws {
    guard version == ClipLiveShareV1.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    self.version = version
    self.publicKey = publicKey
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
      guard ["v", "key"].contains(key), fields.updateValue(fieldValue, forKey: key) == nil else {
        throw ClipLiveShareProtocolError.invalidResource("invalid viewer URL fragment fields")
      }
    }
    guard fields.count == 2, let versionValue = fields["v"], let version = Int(versionValue) else {
      throw ClipLiveShareProtocolError.invalidResource("incomplete viewer URL fragment")
    }
    guard let keyValue = fields["key"] else {
      throw ClipLiveShareProtocolError.invalidResource("viewer URL fragment has no key")
    }
    try self.init(version: version, publicKey: ClipLiveShareKeyAgreementPublicKey(rawValue: keyValue))
  }

  public init(url: URL) throws {
    guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment else {
      throw ClipLiveShareProtocolError.invalidResource("viewer URL has no fragment")
    }
    try self.init(fragment: fragment)
  }

  public var rawValue: String { "v=\(version)&key=\(publicKey.rawValue)" }
  public var description: String { "#\(rawValue)" }

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

public enum ClipLiveShareAccessCodeProof {
  public static func normalize(_ accessCode: String) -> String {
    accessCode
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased(with: Locale(identifier: "en_US_POSIX"))
  }

  public static func make(
    accessCode: String,
    challenge: Data,
    sessionID: ClipLiveShareSessionID
  ) throws -> Data {
    guard challenge.count == ClipLiveShareV1.challengeByteCount else {
      throw ClipLiveShareProtocolError.invalidResource("auth challenge must contain 32 bytes")
    }
    let normalized = normalize(accessCode)
    guard !normalized.isEmpty else {
      throw ClipLiveShareProtocolError.accessCodeRequired
    }

    let digest = SHA256.hash(data: Data(normalized.utf8))
    let key = SymmetricKey(data: Data(digest))
    var authenticatedData = challenge
    authenticatedData.append(Data(sessionID.rawValue.utf8))
    return Data(HMAC<SHA256>.authenticationCode(for: authenticatedData, using: key))
  }

  public static func verify(
    _ proof: Data,
    accessCode: String,
    challenge: Data,
    sessionID: ClipLiveShareSessionID
  ) -> Bool {
    guard
      proof.count == 32,
      challenge.count == ClipLiveShareV1.challengeByteCount,
      !normalize(accessCode).isEmpty
    else {
      return false
    }
    let digest = SHA256.hash(data: Data(normalize(accessCode).utf8))
    let key = SymmetricKey(data: Data(digest))
    var authenticatedData = challenge
    authenticatedData.append(Data(sessionID.rawValue.utf8))
    return HMAC<SHA256>.isValidAuthenticationCode(
      proof,
      authenticating: authenticatedData,
      using: key
    )
  }

  public static func response(
    to challenge: ClipLiveShareAuthChallenge,
    accessCode: String?
  ) throws -> ClipLiveShareAuthResponse {
    if challenge.accessCodeRequired {
      guard let accessCode else { throw ClipLiveShareProtocolError.accessCodeRequired }
      return try ClipLiveShareAuthResponse(
        sessionID: challenge.sessionID,
        proof: make(
          accessCode: accessCode,
          challenge: challenge.challenge,
          sessionID: challenge.sessionID
        )
      )
    }
    return try ClipLiveShareAuthResponse(sessionID: challenge.sessionID, proof: nil)
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

  func derivedKeyBytes(for direction: ClipLiveShareEncryptionDirection) -> Data {
    let key = direction == outboundDirection ? outboundKey : inboundKey
    return key.withUnsafeBytes { Data($0) }
  }

  mutating func seal(
    _ message: ClipLiveShareInnerMessage,
    nonce: Data
  ) throws -> ClipLiveShareRelayEnvelope {
    guard lastOutboundSequence < UInt64.max else {
      throw ClipLiveShareProtocolError.invalidResource("encrypted sequence exhausted")
    }
    guard nonce.count == ClipLiveShareV1.nonceByteCount else {
      throw ClipLiveShareProtocolError.invalidNonceLength(nonce.count)
    }

    let plaintext = try ClipLiveShareMessageCodec.encodeInner(message)
    let sequence = lastOutboundSequence + 1
    let authenticatedData = additionalAuthenticatedData(
      direction: outboundDirection,
      sequence: sequence
    )
    let sealed = try AES.GCM.seal(
      plaintext,
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

    let message = try ClipLiveShareMessageCodec.decodeInner(plaintext)
    lastInboundSequence = envelope.sequence
    return message
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
