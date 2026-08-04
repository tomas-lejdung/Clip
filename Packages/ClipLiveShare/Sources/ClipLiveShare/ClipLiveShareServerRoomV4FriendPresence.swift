import CryptoKit
import Foundation

/// Directional, per-friend online-room discovery for native room v4.
///
/// Every committed friendship owns two independent locators: one mailbox this
/// device publishes and the other friend reads, and one in the reverse
/// direction. Reusing one locator for several friends would let the rendezvous
/// service correlate the publisher's friend graph and is therefore forbidden
/// by the app persistence model.
public enum ClipLiveShareServerRoomV4FriendPresence {
  public static let maximumLifetimeMilliseconds: Int64 = 5 * 60 * 1_000
  public static let maximumCiphertextBytes = 16 * 1_024
}

public enum ClipLiveShareServerRoomV4FriendPresenceError: Error, Equatable,
  Sendable, LocalizedError
{
  case invalidRevision
  case invalidLifetime
  case expired
  case notYetValid
  case identityMismatch
  case invalidSignature
  case authenticationFailed
  case staleRevision
  case invalidInvite
  case payloadTooLarge

  public var errorDescription: String? {
    switch self {
    case .invalidRevision: "The friend presence revision is invalid."
    case .invalidLifetime: "The friend presence lifetime is invalid."
    case .expired: "The friend presence has expired."
    case .notYetValid: "The friend presence is not valid yet."
    case .identityMismatch: "The friend presence identity does not match."
    case .invalidSignature: "The friend presence signature is invalid."
    case .authenticationFailed: "The friend presence could not be decrypted."
    case .staleRevision: "The friend presence revision is stale."
    case .invalidInvite: "The friend presence contains an invalid room invite."
    case .payloadTooLarge: "The friend presence payload is too large."
    }
  }
}

public struct ClipLiveShareServerRoomV4FriendPresencePublication: Codable,
  Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let revision: UInt64
  public let publisherIdentity: ClipLiveShareIdentityPublicKey
  public let recipientFingerprint: ClipLiveShareIdentityFingerprint
  public let inviteURL: URL
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    revision: UInt64,
    publisherIdentity: ClipLiveShareIdentityPublicKey,
    recipientIdentity: ClipLiveShareIdentityPublicKey,
    invite: ClipLiveShareServerRoomV4Invite,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    try self.init(
      revision: revision,
      publisherIdentity: publisherIdentity,
      recipientFingerprint: recipientIdentity.fingerprint,
      inviteURL: invite.url,
      issuedAt: issuedAt,
      expiresAt: expiresAt
    )
    guard invite.creatorIdentity == publisherIdentity else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.identityMismatch
    }
  }

  public func validate(
    expectedPublisherIdentity: ClipLiveShareIdentityPublicKey,
    recipientIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> ClipLiveShareServerRoomV4Invite {
    try validateLifetime(at: now)
    guard
      publisherIdentity == expectedPublisherIdentity,
      recipientFingerprint == recipientIdentity.fingerprint
    else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.identityMismatch
    }
    let invite: ClipLiveShareServerRoomV4Invite
    do {
      invite = try ClipLiveShareServerRoomV4Invite(url: inviteURL)
      guard
        invite.creatorIdentity == publisherIdentity,
        try invite.url.absoluteString == inviteURL.absoluteString
      else {
        throw ClipLiveShareServerRoomV4FriendPresenceError.invalidInvite
      }
    } catch let error as ClipLiveShareServerRoomV4FriendPresenceError {
      throw error
    } catch {
      throw ClipLiveShareServerRoomV4FriendPresenceError.invalidInvite
    }
    return invite
  }

  public var description: String {
    "ClipLiveShareServerRoomV4FriendPresencePublication(revision: \(revision), "
      + "identities-and-invite: <redacted>)"
  }
  public var debugDescription: String { description }

  fileprivate var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/friend-presence-publication"
    )
    encoder.append(revision)
    encoder.append(publisherIdentity.x963Representation)
    encoder.append(recipientFingerprint.bytes)
    encoder.append(inviteURL.absoluteString)
    encoder.append(UInt64(bitPattern: issuedAt.millisecondsSince1970))
    encoder.append(UInt64(bitPattern: expiresAt.millisecondsSince1970))
    return encoder.data
  }

  private init(
    revision: UInt64,
    publisherIdentity: ClipLiveShareIdentityPublicKey,
    recipientFingerprint: ClipLiveShareIdentityFingerprint,
    inviteURL: URL,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    guard revision > 0 else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.invalidRevision
    }
    try Self.validateLifetime(issuedAt: issuedAt, expiresAt: expiresAt)
    self.revision = revision
    self.publisherIdentity = publisherIdentity
    self.recipientFingerprint = recipientFingerprint
    self.inviteURL = inviteURL
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  private enum CodingKeys: String, CodingKey {
    case revision, publisherIdentity, recipientFingerprint, inviteURL
    case issuedAt, expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      revision: container.decode(UInt64.self, forKey: .revision),
      publisherIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .publisherIdentity
      ),
      recipientFingerprint: container.decode(
        ClipLiveShareIdentityFingerprint.self,
        forKey: .recipientFingerprint
      ),
      inviteURL: container.decode(URL.self, forKey: .inviteURL),
      issuedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .issuedAt),
      expiresAt: container.decode(
        ClipLiveShareNativeTimestamp.self,
        forKey: .expiresAt
      )
    )
  }

  private func validateLifetime(at now: ClipLiveShareNativeTimestamp) throws {
    try Self.validateLifetime(issuedAt: issuedAt, expiresAt: expiresAt)
    let (latestIssuedAt, overflow) = now.millisecondsSince1970.addingReportingOverflow(
      ClipLiveShareNativeV3.maximumClockSkewMilliseconds
    )
    if !overflow, issuedAt.millisecondsSince1970 > latestIssuedAt {
      throw ClipLiveShareServerRoomV4FriendPresenceError.notYetValid
    }
    guard now < expiresAt else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.expired
    }
  }

  private static func validateLifetime(
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    let (maximumExpiry, overflow) = issuedAt.millisecondsSince1970
      .addingReportingOverflow(
        ClipLiveShareServerRoomV4FriendPresence.maximumLifetimeMilliseconds
      )
    guard
      !overflow,
      expiresAt > issuedAt,
      expiresAt.millisecondsSince1970 <= maximumExpiry
    else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.invalidLifetime
    }
  }
}

public struct ClipLiveShareServerRoomV4SignedFriendPresence: Codable,
  Equatable, Hashable, Sendable
{
  public let publication: ClipLiveShareServerRoomV4FriendPresencePublication
  public let signerIdentity: ClipLiveShareIdentityPublicKey
  public let signature: ClipLiveShareIdentitySignature

  public init(
    signing publication: ClipLiveShareServerRoomV4FriendPresencePublication,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    guard publication.publisherIdentity == signer.publicKey else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.identityMismatch
    }
    self.publication = publication
    signerIdentity = signer.publicKey
    signature = try signer.signature(for: publication.canonicalRepresentation)
  }

  public func verify() throws {
    guard
      signerIdentity == publication.publisherIdentity,
      signerIdentity.isValidSignature(
        signature,
        for: publication.canonicalRepresentation
      )
    else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.invalidSignature
    }
  }
}

public struct ClipLiveShareServerRoomV4EncryptedFriendPresence: Equatable,
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  public let routingID: ClipLiveShareServerRoomV4FriendRoutingID
  public let revision: UInt64
  public let expiresAtMilliseconds: Int64
  public let ciphertext: Data

  public init(
    routingID: ClipLiveShareServerRoomV4FriendRoutingID,
    revision: UInt64,
    expiresAtMilliseconds: Int64,
    ciphertext: Data
  ) throws {
    guard revision > 0 else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.invalidRevision
    }
    guard expiresAtMilliseconds > 0 else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.invalidLifetime
    }
    guard
      ciphertext.count > ClipLiveShareServerRoomV4.nonceByteCount
        + ClipLiveShareServerRoomV4.authenticationTagByteCount,
      ciphertext.count <= ClipLiveShareServerRoomV4FriendPresence.maximumCiphertextBytes
    else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.payloadTooLarge
    }
    self.routingID = routingID
    self.revision = revision
    self.expiresAtMilliseconds = expiresAtMilliseconds
    self.ciphertext = ciphertext
  }

  public var description: String {
    "ClipLiveShareServerRoomV4EncryptedFriendPresence(routing: \(routingID), "
      + "revision: \(revision), ciphertext: <redacted>)"
  }
  public var debugDescription: String { description }
}

/// Exact opaque HTTP body stored by the rendezvous service.
public struct ClipLiveShareServerRoomV4FriendPresenceRecord: Codable,
  Equatable, Sendable
{
  public let revision: UInt64
  public let expiresAtMilliseconds: Int64
  public let payload: String

  public init(encryptedPresence: ClipLiveShareServerRoomV4EncryptedFriendPresence) {
    revision = encryptedPresence.revision
    expiresAtMilliseconds = encryptedPresence.expiresAtMilliseconds
    payload = ClipLiveShareBase64URL.encode(encryptedPresence.ciphertext)
  }

  public func encryptedPresence(
    routingID: ClipLiveShareServerRoomV4FriendRoutingID
  ) throws -> ClipLiveShareServerRoomV4EncryptedFriendPresence {
    guard let ciphertext = ClipLiveShareBase64URL.decode(payload) else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.authenticationFailed
    }
    return try .init(
      routingID: routingID,
      revision: revision,
      expiresAtMilliseconds: expiresAtMilliseconds,
      ciphertext: ciphertext
    )
  }
}

public enum ClipLiveShareServerRoomV4FriendPresenceCrypto {
  public static func seal(
    invite: ClipLiveShareServerRoomV4Invite,
    revision: UInt64,
    publisherSigner: any ClipLiveShareIdentitySigner,
    recipientIdentity: ClipLiveShareIdentityPublicKey,
    locator: ClipLiveShareServerRoomV4FriendLocator,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws -> ClipLiveShareServerRoomV4EncryptedFriendPresence {
    try seal(
      invite: invite,
      revision: revision,
      publisherSigner: publisherSigner,
      recipientIdentity: recipientIdentity,
      locator: locator,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      nonce: Data(AES.GCM.Nonce())
    )
  }

  static func seal(
    invite: ClipLiveShareServerRoomV4Invite,
    revision: UInt64,
    publisherSigner: any ClipLiveShareIdentitySigner,
    recipientIdentity: ClipLiveShareIdentityPublicKey,
    locator: ClipLiveShareServerRoomV4FriendLocator,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp,
    nonce: Data
  ) throws -> ClipLiveShareServerRoomV4EncryptedFriendPresence {
    guard nonce.count == ClipLiveShareServerRoomV4.nonceByteCount else {
      throw ClipLiveShareProtocolError.invalidNonceLength(nonce.count)
    }
    let publication = try ClipLiveShareServerRoomV4FriendPresencePublication(
      revision: revision,
      publisherIdentity: publisherSigner.publicKey,
      recipientIdentity: recipientIdentity,
      invite: invite,
      issuedAt: issuedAt,
      expiresAt: expiresAt
    )
    let signed = try ClipLiveShareServerRoomV4SignedFriendPresence(
      signing: publication,
      with: publisherSigner
    )
    let plaintext = try serverRoomV4StrictEncode(
      signed,
      maximumBytes: ClipLiveShareServerRoomV4FriendPresence.maximumCiphertextBytes
    )
    let sealed = try AES.GCM.seal(
      plaintext,
      using: encryptionKey(locator: locator),
      nonce: try AES.GCM.Nonce(data: nonce),
      authenticating: authenticatedData(
        routingID: locator.routingID,
        revision: revision,
        expiresAtMilliseconds: expiresAt.millisecondsSince1970
      )
    )
    var ciphertext = nonce
    ciphertext.append(sealed.ciphertext)
    ciphertext.append(sealed.tag)
    return try .init(
      routingID: locator.routingID,
      revision: revision,
      expiresAtMilliseconds: expiresAt.millisecondsSince1970,
      ciphertext: ciphertext
    )
  }

  public static func open(
    _ encrypted: ClipLiveShareServerRoomV4EncryptedFriendPresence,
    locator: ClipLiveShareServerRoomV4FriendLocator,
    expectedPublisherIdentity: ClipLiveShareIdentityPublicKey,
    recipientIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp,
    afterRevision: UInt64? = nil
  ) throws -> ClipLiveShareServerRoomV4Invite {
    guard encrypted.routingID == locator.routingID else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.authenticationFailed
    }
    if let afterRevision, encrypted.revision <= afterRevision {
      throw ClipLiveShareServerRoomV4FriendPresenceError.staleRevision
    }
    guard now.millisecondsSince1970 < encrypted.expiresAtMilliseconds else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.expired
    }
    let nonce = encrypted.ciphertext.prefix(ClipLiveShareServerRoomV4.nonceByteCount)
    let body = encrypted.ciphertext.dropFirst(ClipLiveShareServerRoomV4.nonceByteCount)
    let signed: ClipLiveShareServerRoomV4SignedFriendPresence
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce),
        ciphertext: body.dropLast(ClipLiveShareServerRoomV4.authenticationTagByteCount),
        tag: body.suffix(ClipLiveShareServerRoomV4.authenticationTagByteCount)
      )
      let plaintext = try AES.GCM.open(
        box,
        using: encryptionKey(locator: locator),
        authenticating: authenticatedData(
          routingID: locator.routingID,
          revision: encrypted.revision,
          expiresAtMilliseconds: encrypted.expiresAtMilliseconds
        )
      )
      try serverRoomV4RequireExactKeys(
        plaintext,
        expected: ["publication", "signature", "signerIdentity"]
      )
      guard
        let root = try JSONSerialization.jsonObject(with: plaintext)
          as? [String: Any],
        let publication = root["publication"] as? [String: Any],
        Set(publication.keys) == [
          "expiresAt", "inviteURL", "issuedAt", "publisherIdentity",
          "recipientFingerprint", "revision",
        ]
      else {
        throw ClipLiveShareServerRoomV4FriendPresenceError.authenticationFailed
      }
      signed = try serverRoomV4StrictDecode(
        ClipLiveShareServerRoomV4SignedFriendPresence.self,
        from: plaintext,
        maximumBytes: ClipLiveShareServerRoomV4FriendPresence.maximumCiphertextBytes
      )
    } catch {
      throw ClipLiveShareServerRoomV4FriendPresenceError.authenticationFailed
    }
    guard
      signed.publication.revision == encrypted.revision,
      signed.publication.expiresAt.millisecondsSince1970
        == encrypted.expiresAtMilliseconds
    else {
      throw ClipLiveShareServerRoomV4FriendPresenceError.authenticationFailed
    }
    do {
      try signed.verify()
    } catch {
      throw ClipLiveShareServerRoomV4FriendPresenceError.invalidSignature
    }
    return try signed.publication.validate(
      expectedPublisherIdentity: expectedPublisherIdentity,
      recipientIdentity: recipientIdentity,
      at: now
    )
  }

  private static func encryptionKey(
    locator: ClipLiveShareServerRoomV4FriendLocator
  ) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: locator.presenceSecret.keyMaterial),
      salt: Data("clip-live-share-server-room-v4/friend-presence/salt".utf8),
      info: locator.routingID.bytes,
      outputByteCount: 32
    )
  }

  private static func authenticatedData(
    routingID: ClipLiveShareServerRoomV4FriendRoutingID,
    revision: UInt64,
    expiresAtMilliseconds: Int64
  ) -> Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/friend-presence-ciphertext"
    )
    encoder.append(routingID.bytes)
    encoder.append(revision)
    encoder.append(UInt64(bitPattern: expiresAtMilliseconds))
    return encoder.data
  }
}
