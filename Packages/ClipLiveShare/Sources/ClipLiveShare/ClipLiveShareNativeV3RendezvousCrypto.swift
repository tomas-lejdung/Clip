import CryptoKit
import Foundation

/// Ephemeral key-agreement identity used only for one native-v3 invitation.
///
/// The current leader publishes the public half in the signed invite. A
/// candidate creates a fresh identity for its admission route. Long-term
/// participant identity uses the separate signing key.
public struct ClipLiveShareNativeV3RendezvousIdentity: Sendable {
  fileprivate let privateKey: P256.KeyAgreement.PrivateKey

  public init() {
    privateKey = P256.KeyAgreement.PrivateKey()
  }

  init(rawRepresentation: Data) throws {
    privateKey = try P256.KeyAgreement.PrivateKey(
      rawRepresentation: rawRepresentation
    )
  }

  public var publicKey: ClipLiveShareKeyAgreementPublicKey {
    try! ClipLiveShareKeyAgreementPublicKey(
      x963Representation: privateKey.publicKey.x963Representation
    )
  }
}

public struct ClipLiveShareNativeV3RelayEnvelope:
  Codable, Equatable, Hashable, Sendable
{
  public let routeID: ClipLiveShareRouteID?
  public let sequence: UInt64
  public let nonce: Data
  public let ciphertext: Data

  public init(
    routeID: ClipLiveShareRouteID?,
    sequence: UInt64,
    nonce: Data,
    ciphertext: Data
  ) throws {
    guard sequence > 0 else {
      throw ClipLiveShareProtocolError.invalidSequence(
        expected: 1,
        actual: sequence
      )
    }
    guard nonce.count == ClipLiveShareNativeV3RendezvousCrypto.nonceByteCount
    else {
      throw ClipLiveShareProtocolError.invalidNonceLength(nonce.count)
    }
    guard ciphertext.count >= ClipLiveShareNativeV3RendezvousCrypto.tagByteCount,
      ciphertext.count
        <= ClipLiveShareNativeV3RendezvousCrypto.maximumCiphertextBytes
    else {
      throw ClipLiveShareProtocolError.authenticationFailed
    }
    self.routeID = routeID
    self.sequence = sequence
    self.nonce = nonce
    self.ciphertext = ciphertext
  }

  private enum CodingKeys: String, CodingKey {
    case routeID = "routeId"
    case sequence
    case nonce
    case ciphertext
  }
}

enum ClipLiveShareNativeV3RendezvousCrypto {
  static let nonceByteCount = 12
  static let tagByteCount = 16
  /// Bootstrap packets are deliberately smaller than both the native control
  /// channel and the rendezvous service's opaque transport allowance.
  static let maximumPlaintextBytes = 128 * 1_024
  static let maximumCiphertextBytes =
    maximumPlaintextBytes + tagByteCount

  enum EndpointRole: Sendable {
    case leader
    case candidate
  }

  enum Direction: String, Sendable {
    case leaderToCandidate = "leader-to-candidate"
    case candidateToLeader = "candidate-to-leader"
  }
}

/// Pairwise encrypted native-v3 bootstrap channel.
///
/// The key schedule and every authenticated envelope bind the v3 protocol
/// version, session, invitation rendezvous, route, direction, and sequence.
/// A packet authenticated for any other session, invitation, route, direction,
/// or sequence cannot be replayed or interpreted here.
public struct ClipLiveShareNativeV3EncryptedRendezvousChannel: Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let rendezvousID: ClipLiveShareNativeV3RendezvousID
  public let routeID: ClipLiveShareRouteID

  private let role: ClipLiveShareNativeV3RendezvousCrypto.EndpointRole
  private let outboundKey: SymmetricKey
  private let inboundKey: SymmetricKey
  private let outboundDirection:
    ClipLiveShareNativeV3RendezvousCrypto.Direction
  private let inboundDirection:
    ClipLiveShareNativeV3RendezvousCrypto.Direction
  public private(set) var lastOutboundSequence: UInt64 = 0
  public private(set) var lastInboundSequence: UInt64 = 0

  public init(
    leader identity: ClipLiveShareNativeV3RendezvousIdentity,
    candidatePublicKey: ClipLiveShareKeyAgreementPublicKey,
    sessionID: ClipLiveShareSessionID,
    rendezvousID: ClipLiveShareNativeV3RendezvousID,
    routeID: ClipLiveShareRouteID
  ) throws {
    let remoteKey = try P256.KeyAgreement.PublicKey(
      x963Representation: candidatePublicKey.x963Representation
    )
    let secret = try identity.privateKey.sharedSecretFromKeyAgreement(
      with: remoteKey
    )
    self = Self(
      sharedSecret: secret,
      sessionID: sessionID,
      rendezvousID: rendezvousID,
      routeID: routeID,
      role: .leader
    )
  }

  public init(
    candidate identity: ClipLiveShareNativeV3RendezvousIdentity,
    leaderPublicKey: ClipLiveShareKeyAgreementPublicKey,
    sessionID: ClipLiveShareSessionID,
    rendezvousID: ClipLiveShareNativeV3RendezvousID,
    routeID: ClipLiveShareRouteID
  ) throws {
    let remoteKey = try P256.KeyAgreement.PublicKey(
      x963Representation: leaderPublicKey.x963Representation
    )
    let secret = try identity.privateKey.sharedSecretFromKeyAgreement(
      with: remoteKey
    )
    self = Self(
      sharedSecret: secret,
      sessionID: sessionID,
      rendezvousID: rendezvousID,
      routeID: routeID,
      role: .candidate
    )
  }

  private init(
    sharedSecret: SharedSecret,
    sessionID: ClipLiveShareSessionID,
    rendezvousID: ClipLiveShareNativeV3RendezvousID,
    routeID: ClipLiveShareRouteID,
    role: ClipLiveShareNativeV3RendezvousCrypto.EndpointRole
  ) {
    let leaderToCandidate = Self.deriveKey(
      sharedSecret: sharedSecret,
      sessionID: sessionID,
      rendezvousID: rendezvousID,
      routeID: routeID,
      direction: .leaderToCandidate
    )
    let candidateToLeader = Self.deriveKey(
      sharedSecret: sharedSecret,
      sessionID: sessionID,
      rendezvousID: rendezvousID,
      routeID: routeID,
      direction: .candidateToLeader
    )
    self.sessionID = sessionID
    self.rendezvousID = rendezvousID
    self.routeID = routeID
    self.role = role
    switch role {
    case .leader:
      outboundKey = leaderToCandidate
      inboundKey = candidateToLeader
      outboundDirection = .leaderToCandidate
      inboundDirection = .candidateToLeader
    case .candidate:
      outboundKey = candidateToLeader
      inboundKey = leaderToCandidate
      outboundDirection = .candidateToLeader
      inboundDirection = .leaderToCandidate
    }
  }

  public mutating func seal(
    _ envelope: ClipLiveShareNativeV3BootstrapEnvelope
  ) throws -> ClipLiveShareNativeV3RelayEnvelope {
    try seal(
      envelope,
      nonce: Data(AES.GCM.Nonce())
    )
  }

  mutating func seal(
    _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
    nonce: Data
  ) throws -> ClipLiveShareNativeV3RelayEnvelope {
    let plaintext = try ClipLiveShareNativeV3BootstrapCodec.encode(
      envelope,
      maximumBytes:
        ClipLiveShareNativeV3RendezvousCrypto.maximumPlaintextBytes
    )
    return try sealOpaquePayload(plaintext, nonce: nonce)
  }

  public mutating func open(
    _ relay: ClipLiveShareNativeV3RelayEnvelope
  ) throws -> ClipLiveShareNativeV3BootstrapEnvelope {
    let plaintext = try openOpaquePayload(relay)
    return try ClipLiveShareNativeV3BootstrapCodec.decode(
      plaintext,
      maximumBytes:
        ClipLiveShareNativeV3RendezvousCrypto.maximumPlaintextBytes
    )
  }

  mutating func sealOpaquePayload(
    _ payload: Data,
    nonce: Data
  ) throws -> ClipLiveShareNativeV3RelayEnvelope {
    guard lastOutboundSequence < UInt64.max else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native-v3 rendezvous sequence exhausted"
      )
    }
    guard nonce.count
      == ClipLiveShareNativeV3RendezvousCrypto.nonceByteCount
    else {
      throw ClipLiveShareProtocolError.invalidNonceLength(nonce.count)
    }
    guard
      payload.count
        <= ClipLiveShareNativeV3RendezvousCrypto.maximumPlaintextBytes
    else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum:
          ClipLiveShareNativeV3RendezvousCrypto.maximumPlaintextBytes,
        actual: payload.count
      )
    }
    let sequence = lastOutboundSequence + 1
    let sealed = try AES.GCM.seal(
      payload,
      using: outboundKey,
      nonce: try AES.GCM.Nonce(data: nonce),
      authenticating: authenticatedData(
        direction: outboundDirection,
        sequence: sequence
      )
    )
    var ciphertext = sealed.ciphertext
    ciphertext.append(sealed.tag)
    let relay = try ClipLiveShareNativeV3RelayEnvelope(
      routeID: role == .leader ? routeID : nil,
      sequence: sequence,
      nonce: nonce,
      ciphertext: ciphertext
    )
    lastOutboundSequence = sequence
    return relay
  }

  mutating func openOpaquePayload(
    _ relay: ClipLiveShareNativeV3RelayEnvelope
  ) throws -> Data {
    guard relay.routeID == routeID else {
      throw ClipLiveShareProtocolError.routeMismatch(
        expected: routeID,
        actual: relay.routeID
      )
    }
    let expected = lastInboundSequence + 1
    guard relay.sequence == expected else {
      throw ClipLiveShareProtocolError.invalidSequence(
        expected: expected,
        actual: relay.sequence
      )
    }
    guard relay.ciphertext.count
      >= ClipLiveShareNativeV3RendezvousCrypto.tagByteCount
    else {
      throw ClipLiveShareProtocolError.authenticationFailed
    }
    let ciphertext = relay.ciphertext.dropLast(
      ClipLiveShareNativeV3RendezvousCrypto.tagByteCount
    )
    let tag = relay.ciphertext.suffix(
      ClipLiveShareNativeV3RendezvousCrypto.tagByteCount
    )
    let sealedBox: AES.GCM.SealedBox
    do {
      sealedBox = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: relay.nonce),
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
        authenticating: authenticatedData(
          direction: inboundDirection,
          sequence: relay.sequence
        )
      )
    } catch {
      throw ClipLiveShareProtocolError.authenticationFailed
    }
    guard
      plaintext.count
        <= ClipLiveShareNativeV3RendezvousCrypto.maximumPlaintextBytes
    else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum:
          ClipLiveShareNativeV3RendezvousCrypto.maximumPlaintextBytes,
        actual: plaintext.count
      )
    }
    lastInboundSequence = relay.sequence
    return plaintext
  }

  private static func deriveKey(
    sharedSecret: SharedSecret,
    sessionID: ClipLiveShareSessionID,
    rendezvousID: ClipLiveShareNativeV3RendezvousID,
    routeID: ClipLiveShareRouteID,
    direction: ClipLiveShareNativeV3RendezvousCrypto.Direction
  ) -> SymmetricKey {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/rendezvous-key-salt"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(rendezvousID.bytes)
    encoder.append(routeID.rawValue)
    let salt = Data(SHA256.hash(data: encoder.data))
    return sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: salt,
      sharedInfo: Data(
        ("clip-live-share-native-v3/rendezvous/"
          + direction.rawValue).utf8
      ),
      outputByteCount: 32
    )
  }

  private func authenticatedData(
    direction: ClipLiveShareNativeV3RendezvousCrypto.Direction,
    sequence: UInt64
  ) -> Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/rendezvous-envelope"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(rendezvousID.bytes)
    encoder.append(routeID.rawValue)
    encoder.append(direction.rawValue)
    encoder.append(sequence)
    return encoder.data
  }
}
