import Foundation

/// Clean-slate friendship messages carried only by an authenticated v4 pair's
/// reliable DataChannel. They are deliberately independent from room
/// admission: becoming friends never changes membership in the active room.
public enum ClipLiveShareServerRoomV4Friends {
  public static let maximumHandshakeLifetimeMilliseconds: Int64 = 5 * 60 * 1_000
  public static let maximumRecoveryRetentionMilliseconds: Int64 =
    7 * 24 * 60 * 60 * 1_000
  public static let maximumMessageBytes = 32 * 1_024
  public static let maximumDisplayNameBytes = 160
  public static let maximumDeviceNameBytes = 160
}

public struct ClipLiveShareServerRoomV4FriendRequestID: Codable, Equatable,
  Hashable, Sendable, CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == 16 else {
      throw ClipLiveShareServerRoomV4FriendError.invalidIdentifier
    }
    self.bytes = bytes
  }

  public init(rawValue: String) throws {
    guard let bytes = ClipLiveShareBase64URL.decode(rawValue) else {
      throw ClipLiveShareProtocolError.invalidBase64URL
    }
    try self.init(bytes: bytes)
  }

  public static func random() -> Self {
    try! Self(bytes: serverRoomV4SecureRandomData(count: 16))
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

/// Opaque stable locator exchanged only between friends.
///
/// A future presence service may route by this random value. It is not an
/// identity fingerprint, display name, room ID, or invite secret, so the
/// service cannot derive whom it represents from the locator itself.
public struct ClipLiveShareServerRoomV4FriendRoutingID: Codable, Equatable,
  Hashable, Sendable, CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == 32 else {
      throw ClipLiveShareServerRoomV4FriendError.invalidIdentifier
    }
    self.bytes = bytes
  }

  public init(rawValue: String) throws {
    guard let bytes = ClipLiveShareBase64URL.decode(rawValue) else {
      throw ClipLiveShareProtocolError.invalidBase64URL
    }
    try self.init(bytes: bytes)
  }

  public static func random() -> Self {
    try! Self(bytes: serverRoomV4SecureRandomData(count: 32))
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

/// Friend-only key material used to encrypt and authenticate presence state.
/// The rendezvous service receives the routing ID and ciphertext but never
/// this value, persistent identity, display name, or room invite.
public struct ClipLiveShareServerRoomV4FriendPresenceSecret: Codable,
  Equatable, Hashable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let keyMaterial: Data

  public init(keyMaterial: Data) throws {
    guard keyMaterial.count == 32 else {
      throw ClipLiveShareServerRoomV4FriendError.invalidIdentifier
    }
    self.keyMaterial = keyMaterial
  }

  public init(rawValue: String) throws {
    guard let bytes = ClipLiveShareBase64URL.decode(rawValue) else {
      throw ClipLiveShareProtocolError.invalidBase64URL
    }
    try self.init(keyMaterial: bytes)
  }

  public static func random() -> Self {
    try! Self(keyMaterial: serverRoomV4SecureRandomData(count: 32))
  }

  public var rawValue: String { ClipLiveShareBase64URL.encode(keyMaterial) }
  public var description: String { "<redacted>" }
  public var debugDescription: String { description }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ClipLiveShareServerRoomV4FriendLocator: Codable, Equatable,
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  public let routingID: ClipLiveShareServerRoomV4FriendRoutingID
  public let presenceSecret: ClipLiveShareServerRoomV4FriendPresenceSecret

  public init(
    routingID: ClipLiveShareServerRoomV4FriendRoutingID,
    presenceSecret: ClipLiveShareServerRoomV4FriendPresenceSecret
  ) {
    self.routingID = routingID
    self.presenceSecret = presenceSecret
  }

  public static func random() -> Self {
    .init(routingID: .random(), presenceSecret: .random())
  }

  public var description: String {
    "ClipLiveShareServerRoomV4FriendLocator(routing: \(routingID), secret: <redacted>)"
  }
  public var debugDescription: String { description }
}

public struct ClipLiveShareServerRoomV4FriendProfile: Codable, Equatable,
  Hashable, Sendable
{
  public let identity: ClipLiveShareIdentityPublicKey
  public let displayName: String
  public let deviceName: String
  /// Presence is per friendship and may be hosted independently from the
  /// room where the friendship was established. This validated endpoint is
  /// signed end-to-end with the profile and is never inferred from the
  /// current participant's configured service.
  public let presenceServiceEndpoint: ClipLiveShareRendezvousEndpoint
  public let locator: ClipLiveShareServerRoomV4FriendLocator

  public init(
    identity: ClipLiveShareIdentityPublicKey,
    displayName: String,
    deviceName: String,
    presenceServiceEndpoint: ClipLiveShareRendezvousEndpoint = .official,
    locator: ClipLiveShareServerRoomV4FriendLocator
  ) throws {
    try serverRoomV4FriendValidateText(
      displayName,
      maximumBytes: ClipLiveShareServerRoomV4Friends.maximumDisplayNameBytes
    )
    try serverRoomV4FriendValidateText(
      deviceName,
      maximumBytes: ClipLiveShareServerRoomV4Friends.maximumDeviceNameBytes
    )
    self.identity = identity
    self.displayName = displayName
    self.deviceName = deviceName
    self.presenceServiceEndpoint = presenceServiceEndpoint
    self.locator = locator
  }

  fileprivate var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/friend-profile"
    )
    encoder.append(identity.x963Representation)
    encoder.append(displayName)
    encoder.append(deviceName)
    encoder.append(presenceServiceEndpoint.rootURL.absoluteString)
    encoder.append(locator.routingID.bytes)
    encoder.append(locator.presenceSecret.keyMaterial)
    return encoder.data
  }

  fileprivate func validate() throws {
    try serverRoomV4FriendValidateText(
      displayName,
      maximumBytes: ClipLiveShareServerRoomV4Friends.maximumDisplayNameBytes
    )
    try serverRoomV4FriendValidateText(
      deviceName,
      maximumBytes: ClipLiveShareServerRoomV4Friends.maximumDeviceNameBytes
    )
  }
}

public struct ClipLiveShareServerRoomV4FriendRequest: Codable, Equatable,
  Hashable, Sendable
{
  public let requestID: ClipLiveShareServerRoomV4FriendRequestID
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let requesterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let accepterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let requester: ClipLiveShareServerRoomV4FriendProfile
  public let expectedAccepterFingerprint: ClipLiveShareIdentityFingerprint
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    requestID: ClipLiveShareServerRoomV4FriendRequestID = .random(),
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    requesterParticipantID: ClipLiveShareNativeV3ParticipantID,
    accepterParticipantID: ClipLiveShareNativeV3ParticipantID,
    requester: ClipLiveShareServerRoomV4FriendProfile,
    expectedAccepterFingerprint: ClipLiveShareIdentityFingerprint,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    guard requesterParticipantID != accepterParticipantID else {
      throw ClipLiveShareServerRoomV4FriendError.contextMismatch
    }
    try serverRoomV4FriendValidateLifetime(issuedAt: issuedAt, expiresAt: expiresAt)
    self.requestID = requestID
    self.roomID = roomID
    self.sessionID = sessionID
    self.requesterParticipantID = requesterParticipantID
    self.accepterParticipantID = accepterParticipantID
    self.requester = requester
    self.expectedAccepterFingerprint = expectedAccepterFingerprint
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var digest: ClipLiveShareNativeDigest {
    .init(hashing: canonicalRepresentation)
  }

  public func validate(at now: ClipLiveShareNativeTimestamp) throws {
    try requester.validate()
    try serverRoomV4FriendValidateLifetime(issuedAt: issuedAt, expiresAt: expiresAt)
    try serverRoomV4FriendValidateWindow(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      now: now
    )
  }

  fileprivate var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/friend-request"
    )
    appendFriendContext(self, to: &encoder)
    encoder.append(requester.canonicalRepresentation)
    encoder.append(expectedAccepterFingerprint.bytes)
    encoder.append(UInt64(bitPattern: issuedAt.millisecondsSince1970))
    encoder.append(UInt64(bitPattern: expiresAt.millisecondsSince1970))
    return encoder.data
  }
}

public struct ClipLiveShareServerRoomV4FriendAcceptance: Codable, Equatable,
  Hashable, Sendable
{
  public let requestID: ClipLiveShareServerRoomV4FriendRequestID
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let requesterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let accepterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let requestDigest: ClipLiveShareNativeDigest
  public let requesterFingerprint: ClipLiveShareIdentityFingerprint
  public let accepter: ClipLiveShareServerRoomV4FriendProfile
  public let acceptedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    accepting request: ClipLiveShareServerRoomV4FriendRequest,
    accepter: ClipLiveShareServerRoomV4FriendProfile,
    acceptedAt: ClipLiveShareNativeTimestamp
  ) throws {
    try accepter.validate()
    guard accepter.identity.fingerprint == request.expectedAccepterFingerprint else {
      throw ClipLiveShareServerRoomV4FriendError.identityMismatch
    }
    guard acceptedAt >= request.issuedAt, acceptedAt < request.expiresAt else {
      throw ClipLiveShareServerRoomV4FriendError.invalidLifetime
    }
    requestID = request.requestID
    roomID = request.roomID
    sessionID = request.sessionID
    requesterParticipantID = request.requesterParticipantID
    accepterParticipantID = request.accepterParticipantID
    requestDigest = request.digest
    requesterFingerprint = request.requester.identity.fingerprint
    self.accepter = accepter
    self.acceptedAt = acceptedAt
    expiresAt = request.expiresAt
  }

  public var digest: ClipLiveShareNativeDigest {
    .init(hashing: canonicalRepresentation)
  }

  public func validate(
    for request: ClipLiveShareServerRoomV4FriendRequest,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try accepter.validate()
    guard
      requestID == request.requestID,
      roomID == request.roomID,
      sessionID == request.sessionID,
      requesterParticipantID == request.requesterParticipantID,
      accepterParticipantID == request.accepterParticipantID,
      requestDigest == request.digest,
      requesterFingerprint == request.requester.identity.fingerprint,
      accepter.identity.fingerprint == request.expectedAccepterFingerprint,
      expiresAt == request.expiresAt,
      acceptedAt >= request.issuedAt,
      acceptedAt < expiresAt
    else {
      throw ClipLiveShareServerRoomV4FriendError.contextMismatch
    }
    try request.validate(at: now)
  }

  fileprivate var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/friend-acceptance"
    )
    appendFriendContext(self, to: &encoder)
    encoder.append(requestDigest.bytes)
    encoder.append(requesterFingerprint.bytes)
    encoder.append(accepter.canonicalRepresentation)
    encoder.append(UInt64(bitPattern: acceptedAt.millisecondsSince1970))
    encoder.append(UInt64(bitPattern: expiresAt.millisecondsSince1970))
    return encoder.data
  }
}

/// Signed deterministic response when the recipient declines a request.
///
/// A decline deliberately carries no friend locator. It is valid for the
/// bounded recovery window so an ambiguous DataChannel send can replay the
/// exact response without leaving the requester pending forever.
public struct ClipLiveShareServerRoomV4FriendDecline: Codable, Equatable,
  Hashable, Sendable
{
  public let requestID: ClipLiveShareServerRoomV4FriendRequestID
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let requesterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let accepterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let requestDigest: ClipLiveShareNativeDigest
  public let requesterFingerprint: ClipLiveShareIdentityFingerprint
  public let accepterIdentity: ClipLiveShareIdentityPublicKey
  public let declinedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    declining request: ClipLiveShareServerRoomV4FriendRequest,
    accepterIdentity: ClipLiveShareIdentityPublicKey,
    declinedAt: ClipLiveShareNativeTimestamp
  ) throws {
    guard accepterIdentity.fingerprint == request.expectedAccepterFingerprint else {
      throw ClipLiveShareServerRoomV4FriendError.identityMismatch
    }
    guard declinedAt >= request.issuedAt, declinedAt < request.expiresAt else {
      throw ClipLiveShareServerRoomV4FriendError.invalidLifetime
    }
    requestID = request.requestID
    roomID = request.roomID
    sessionID = request.sessionID
    requesterParticipantID = request.requesterParticipantID
    accepterParticipantID = request.accepterParticipantID
    requestDigest = request.digest
    requesterFingerprint = request.requester.identity.fingerprint
    self.accepterIdentity = accepterIdentity
    self.declinedAt = declinedAt
    expiresAt = try declinedAt.adding(
      milliseconds:
        ClipLiveShareServerRoomV4Friends.maximumRecoveryRetentionMilliseconds
    )
  }

  public func validate(
    for request: ClipLiveShareServerRoomV4FriendRequest,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    // The original request only had to be live when the user declined it.
    // The signed decision itself remains replayable for bounded recovery.
    try request.validate(at: declinedAt)
    guard
      requestID == request.requestID,
      roomID == request.roomID,
      sessionID == request.sessionID,
      requesterParticipantID == request.requesterParticipantID,
      accepterParticipantID == request.accepterParticipantID,
      requestDigest == request.digest,
      requesterFingerprint == request.requester.identity.fingerprint,
      accepterIdentity.fingerprint == request.expectedAccepterFingerprint
    else {
      throw ClipLiveShareServerRoomV4FriendError.contextMismatch
    }
    let (maximumExpiry, overflow) = declinedAt.millisecondsSince1970
      .addingReportingOverflow(
        ClipLiveShareServerRoomV4Friends.maximumRecoveryRetentionMilliseconds
      )
    guard !overflow,
          expiresAt.millisecondsSince1970 <= maximumExpiry else {
      throw ClipLiveShareServerRoomV4FriendError.invalidLifetime
    }
    try serverRoomV4FriendValidateEventWindow(
      eventAt: declinedAt,
      expiresAt: expiresAt,
      now: now
    )
  }

  fileprivate var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/friend-decline"
    )
    appendFriendContext(self, to: &encoder)
    encoder.append(requestDigest.bytes)
    encoder.append(requesterFingerprint.bytes)
    encoder.append(accepterIdentity.x963Representation)
    encoder.append(UInt64(bitPattern: declinedAt.millisecondsSince1970))
    encoder.append(UInt64(bitPattern: expiresAt.millisecondsSince1970))
    return encoder.data
  }
}

public struct ClipLiveShareServerRoomV4FriendAcknowledgement: Codable,
  Equatable, Hashable, Sendable
{
  public let requestID: ClipLiveShareServerRoomV4FriendRequestID
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let requesterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let accepterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let requestDigest: ClipLiveShareNativeDigest
  public let acceptanceDigest: ClipLiveShareNativeDigest
  public let requesterFingerprint: ClipLiveShareIdentityFingerprint
  public let accepterFingerprint: ClipLiveShareIdentityFingerprint
  public let acknowledgedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    acknowledging acceptance: ClipLiveShareServerRoomV4FriendAcceptance,
    request: ClipLiveShareServerRoomV4FriendRequest,
    acknowledgedAt: ClipLiveShareNativeTimestamp
  ) throws {
    guard acknowledgedAt >= acceptance.acceptedAt,
          acknowledgedAt < acceptance.expiresAt else {
      throw ClipLiveShareServerRoomV4FriendError.invalidLifetime
    }
    requestID = request.requestID
    roomID = request.roomID
    sessionID = request.sessionID
    requesterParticipantID = request.requesterParticipantID
    accepterParticipantID = request.accepterParticipantID
    requestDigest = request.digest
    acceptanceDigest = acceptance.digest
    requesterFingerprint = request.requester.identity.fingerprint
    accepterFingerprint = acceptance.accepter.identity.fingerprint
    self.acknowledgedAt = acknowledgedAt
    expiresAt = acceptance.expiresAt
  }

  public var digest: ClipLiveShareNativeDigest {
    .init(hashing: canonicalRepresentation)
  }

  public func validate(
    request: ClipLiveShareServerRoomV4FriendRequest,
    acceptance: ClipLiveShareServerRoomV4FriendAcceptance,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try acceptance.validate(for: request, at: now)
    guard
      requestID == request.requestID,
      roomID == request.roomID,
      sessionID == request.sessionID,
      requesterParticipantID == request.requesterParticipantID,
      accepterParticipantID == request.accepterParticipantID,
      requestDigest == request.digest,
      acceptanceDigest == acceptance.digest,
      requesterFingerprint == request.requester.identity.fingerprint,
      accepterFingerprint == acceptance.accepter.identity.fingerprint,
      expiresAt == acceptance.expiresAt,
      acknowledgedAt >= acceptance.acceptedAt,
      acknowledgedAt < expiresAt
    else {
      throw ClipLiveShareServerRoomV4FriendError.contextMismatch
    }
  }

  fileprivate var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/friend-acknowledgement"
    )
    appendFriendContext(self, to: &encoder)
    encoder.append(requestDigest.bytes)
    encoder.append(acceptanceDigest.bytes)
    encoder.append(requesterFingerprint.bytes)
    encoder.append(accepterFingerprint.bytes)
    encoder.append(UInt64(bitPattern: acknowledgedAt.millisecondsSince1970))
    encoder.append(UInt64(bitPattern: expiresAt.millisecondsSince1970))
    return encoder.data
  }
}

public struct ClipLiveShareServerRoomV4FriendCommitReceipt: Codable,
  Equatable, Hashable, Sendable
{
  public let requestID: ClipLiveShareServerRoomV4FriendRequestID
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let requesterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let accepterParticipantID: ClipLiveShareNativeV3ParticipantID
  public let requestDigest: ClipLiveShareNativeDigest
  public let acceptanceDigest: ClipLiveShareNativeDigest
  public let acknowledgementDigest: ClipLiveShareNativeDigest
  public let requesterFingerprint: ClipLiveShareIdentityFingerprint
  public let accepterFingerprint: ClipLiveShareIdentityFingerprint
  public let committedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    committing acknowledgement: ClipLiveShareServerRoomV4FriendAcknowledgement,
    committedAt: ClipLiveShareNativeTimestamp
  ) throws {
    guard committedAt >= acknowledgement.acknowledgedAt,
          committedAt < acknowledgement.expiresAt else {
      throw ClipLiveShareServerRoomV4FriendError.invalidLifetime
    }
    let recoveryExpiry = try committedAt.adding(
      milliseconds:
        ClipLiveShareServerRoomV4Friends.maximumRecoveryRetentionMilliseconds
    )
    requestID = acknowledgement.requestID
    roomID = acknowledgement.roomID
    sessionID = acknowledgement.sessionID
    requesterParticipantID = acknowledgement.requesterParticipantID
    accepterParticipantID = acknowledgement.accepterParticipantID
    requestDigest = acknowledgement.requestDigest
    acceptanceDigest = acknowledgement.acceptanceDigest
    acknowledgementDigest = acknowledgement.digest
    requesterFingerprint = acknowledgement.requesterFingerprint
    accepterFingerprint = acknowledgement.accepterFingerprint
    self.committedAt = committedAt
    expiresAt = recoveryExpiry
  }

  public var digest: ClipLiveShareNativeDigest {
    .init(hashing: canonicalRepresentation)
  }

  public func validate(
    request: ClipLiveShareServerRoomV4FriendRequest,
    acceptance: ClipLiveShareServerRoomV4FriendAcceptance,
    acknowledgement: ClipLiveShareServerRoomV4FriendAcknowledgement,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    // The acknowledgement itself had to be valid when it was created. A
    // commit receipt remains replayable during the bounded recovery window so
    // a crash after the accepter's durable commit cannot silently leave the
    // requester pending forever.
    try acknowledgement.validate(
      request: request,
      acceptance: acceptance,
      at: acknowledgement.acknowledgedAt
    )
    guard
      requestID == request.requestID,
      roomID == request.roomID,
      sessionID == request.sessionID,
      requesterParticipantID == request.requesterParticipantID,
      accepterParticipantID == request.accepterParticipantID,
      requestDigest == request.digest,
      acceptanceDigest == acceptance.digest,
      acknowledgementDigest == acknowledgement.digest,
      requesterFingerprint == request.requester.identity.fingerprint,
      accepterFingerprint == acceptance.accepter.identity.fingerprint,
      committedAt >= acknowledgement.acknowledgedAt,
      committedAt < acknowledgement.expiresAt
    else {
      throw ClipLiveShareServerRoomV4FriendError.contextMismatch
    }
    let (maximumRecoveryExpiry, overflow) = committedAt
      .millisecondsSince1970.addingReportingOverflow(
        ClipLiveShareServerRoomV4Friends.maximumRecoveryRetentionMilliseconds
      )
    guard !overflow,
          expiresAt.millisecondsSince1970 <= maximumRecoveryExpiry else {
      throw ClipLiveShareServerRoomV4FriendError.invalidLifetime
    }
    try serverRoomV4FriendValidateEventWindow(
      eventAt: committedAt,
      expiresAt: expiresAt,
      now: now
    )
  }

  fileprivate var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/friend-commit-receipt"
    )
    appendFriendContext(self, to: &encoder)
    encoder.append(requestDigest.bytes)
    encoder.append(acceptanceDigest.bytes)
    encoder.append(acknowledgementDigest.bytes)
    encoder.append(requesterFingerprint.bytes)
    encoder.append(accepterFingerprint.bytes)
    encoder.append(UInt64(bitPattern: committedAt.millisecondsSince1970))
    encoder.append(UInt64(bitPattern: expiresAt.millisecondsSince1970))
    return encoder.data
  }
}

public enum ClipLiveShareServerRoomV4FriendMessage: Codable, Equatable,
  Hashable, Sendable
{
  case request(ClipLiveShareServerRoomV4FriendRequest)
  case acceptance(ClipLiveShareServerRoomV4FriendAcceptance)
  case decline(ClipLiveShareServerRoomV4FriendDecline)
  case acknowledgement(ClipLiveShareServerRoomV4FriendAcknowledgement)
  case commitReceipt(ClipLiveShareServerRoomV4FriendCommitReceipt)

  public var requestID: ClipLiveShareServerRoomV4FriendRequestID {
    switch self {
    case .request(let value): value.requestID
    case .acceptance(let value): value.requestID
    case .decline(let value): value.requestID
    case .acknowledgement(let value): value.requestID
    case .commitReceipt(let value): value.requestID
    }
  }

  public var roomID: ClipLiveShareServerRoomV4RoomID {
    switch self {
    case .request(let value): value.roomID
    case .acceptance(let value): value.roomID
    case .decline(let value): value.roomID
    case .acknowledgement(let value): value.roomID
    case .commitReceipt(let value): value.roomID
    }
  }

  public var sessionID: ClipLiveShareSessionID {
    switch self {
    case .request(let value): value.sessionID
    case .acceptance(let value): value.sessionID
    case .decline(let value): value.sessionID
    case .acknowledgement(let value): value.sessionID
    case .commitReceipt(let value): value.sessionID
    }
  }

  public var authorParticipantID: ClipLiveShareNativeV3ParticipantID {
    switch self {
    case .request(let value): value.requesterParticipantID
    case .acceptance(let value): value.accepterParticipantID
    case .decline(let value): value.accepterParticipantID
    case .acknowledgement(let value): value.requesterParticipantID
    case .commitReceipt(let value): value.accepterParticipantID
    }
  }

  public var recipientParticipantID: ClipLiveShareNativeV3ParticipantID {
    switch self {
    case .request(let value): value.accepterParticipantID
    case .acceptance(let value): value.requesterParticipantID
    case .decline(let value): value.requesterParticipantID
    case .acknowledgement(let value): value.accepterParticipantID
    case .commitReceipt(let value): value.requesterParticipantID
    }
  }

  public var authorIdentity: ClipLiveShareIdentityPublicKey? {
    switch self {
    case .request(let value): value.requester.identity
    case .acceptance(let value): value.accepter.identity
    case .decline(let value): value.accepterIdentity
    case .acknowledgement, .commitReceipt: nil
    }
  }

  fileprivate var canonicalRepresentation: Data {
    switch self {
    case .request(let value): value.canonicalRepresentation
    case .acceptance(let value): value.canonicalRepresentation
    case .decline(let value): value.canonicalRepresentation
    case .acknowledgement(let value): value.canonicalRepresentation
    case .commitReceipt(let value): value.canonicalRepresentation
    }
  }

  private enum CodingKeys: String, CodingKey { case type, payload }
  private enum Kind: String, Codable {
    case request
    case acceptance
    case decline
    case acknowledgement
    case commitReceipt = "commit-receipt"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .request:
      self = .request(try container.decode(
        ClipLiveShareServerRoomV4FriendRequest.self, forKey: .payload))
    case .acceptance:
      self = .acceptance(try container.decode(
        ClipLiveShareServerRoomV4FriendAcceptance.self, forKey: .payload))
    case .decline:
      self = .decline(try container.decode(
        ClipLiveShareServerRoomV4FriendDecline.self, forKey: .payload))
    case .acknowledgement:
      self = .acknowledgement(try container.decode(
        ClipLiveShareServerRoomV4FriendAcknowledgement.self, forKey: .payload))
    case .commitReceipt:
      self = .commitReceipt(try container.decode(
        ClipLiveShareServerRoomV4FriendCommitReceipt.self, forKey: .payload))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .request(let value):
      try container.encode(Kind.request, forKey: .type)
      try container.encode(value, forKey: .payload)
    case .acceptance(let value):
      try container.encode(Kind.acceptance, forKey: .type)
      try container.encode(value, forKey: .payload)
    case .decline(let value):
      try container.encode(Kind.decline, forKey: .type)
      try container.encode(value, forKey: .payload)
    case .acknowledgement(let value):
      try container.encode(Kind.acknowledgement, forKey: .type)
      try container.encode(value, forKey: .payload)
    case .commitReceipt(let value):
      try container.encode(Kind.commitReceipt, forKey: .type)
      try container.encode(value, forKey: .payload)
    }
  }
}

public struct ClipLiveShareServerRoomV4SignedFriendMessage: Codable,
  Equatable, Hashable, Sendable
{
  public let message: ClipLiveShareServerRoomV4FriendMessage
  public let signerIdentity: ClipLiveShareIdentityPublicKey
  public let signature: ClipLiveShareIdentitySignature

  public init(
    signing message: ClipLiveShareServerRoomV4FriendMessage,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    if let assertedIdentity = message.authorIdentity,
       assertedIdentity != signer.publicKey {
      throw ClipLiveShareServerRoomV4FriendError.identityMismatch
    }
    self.message = message
    signerIdentity = signer.publicKey
    signature = try signer.signature(for: message.canonicalRepresentation)
  }

  public func verify() throws {
    if let assertedIdentity = message.authorIdentity,
       assertedIdentity != signerIdentity {
      throw ClipLiveShareServerRoomV4FriendError.identityMismatch
    }
    guard signerIdentity.isValidSignature(
      signature,
      for: message.canonicalRepresentation
    ) else {
      throw ClipLiveShareServerRoomV4FriendError.invalidSignature
    }
  }

  /// Verifies both the persistent signature and the room-scoped identity
  /// binding supplied by the authenticated direct peer link. A valid device
  /// signature alone is never enough to inject a friend message into an
  /// unrelated room or impersonate another participant incarnation.
  public func verifyTransportContext(
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    authorParticipantID: ClipLiveShareNativeV3ParticipantID,
    recipientParticipantID: ClipLiveShareNativeV3ParticipantID,
    authorIdentity: ClipLiveShareIdentityPublicKey,
    recipientIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try verify()
    guard
      message.roomID == roomID,
      message.sessionID == sessionID,
      message.authorParticipantID == authorParticipantID,
      message.recipientParticipantID == recipientParticipantID,
      signerIdentity == authorIdentity
    else {
      throw ClipLiveShareServerRoomV4FriendError.contextMismatch
    }

    switch message {
    case .request(let value):
      guard
        value.requester.identity == authorIdentity,
        value.expectedAccepterFingerprint == recipientIdentity.fingerprint
      else {
        throw ClipLiveShareServerRoomV4FriendError.identityMismatch
      }
      try value.validate(at: now)

    case .acceptance(let value):
      guard
        value.accepter.identity == authorIdentity,
        value.requesterFingerprint == recipientIdentity.fingerprint
      else {
        throw ClipLiveShareServerRoomV4FriendError.identityMismatch
      }
      try serverRoomV4FriendValidateEventWindow(
        eventAt: value.acceptedAt,
        expiresAt: value.expiresAt,
        now: now
      )

    case .decline(let value):
      guard
        value.accepterIdentity == authorIdentity,
        value.requesterFingerprint == recipientIdentity.fingerprint
      else {
        throw ClipLiveShareServerRoomV4FriendError.identityMismatch
      }
      try serverRoomV4FriendValidateEventWindow(
        eventAt: value.declinedAt,
        expiresAt: value.expiresAt,
        now: now
      )

    case .acknowledgement(let value):
      guard
        value.requesterFingerprint == authorIdentity.fingerprint,
        value.accepterFingerprint == recipientIdentity.fingerprint
      else {
        throw ClipLiveShareServerRoomV4FriendError.identityMismatch
      }
      try serverRoomV4FriendValidateEventWindow(
        eventAt: value.acknowledgedAt,
        expiresAt: value.expiresAt,
        now: now
      )

    case .commitReceipt(let value):
      guard
        value.accepterFingerprint == authorIdentity.fingerprint,
        value.requesterFingerprint == recipientIdentity.fingerprint
      else {
        throw ClipLiveShareServerRoomV4FriendError.identityMismatch
      }
      try serverRoomV4FriendValidateEventWindow(
        eventAt: value.committedAt,
        expiresAt: value.expiresAt,
        now: now
      )
    }
  }
}

public enum ClipLiveShareServerRoomV4FriendMessageCodec {
  public static func encode(
    _ message: ClipLiveShareServerRoomV4SignedFriendMessage,
    maximumBytes: Int = ClipLiveShareServerRoomV4Friends.maximumMessageBytes
  ) throws -> Data {
    guard maximumBytes > 0 else {
      throw ClipLiveShareServerRoomV4FriendError.messageTooLarge
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(message)
    guard data.count <= maximumBytes else {
      throw ClipLiveShareServerRoomV4FriendError.messageTooLarge
    }
    return data
  }

  public static func decode(
    _ data: Data,
    maximumBytes: Int = ClipLiveShareServerRoomV4Friends.maximumMessageBytes
  ) throws -> ClipLiveShareServerRoomV4SignedFriendMessage {
    guard maximumBytes > 0, data.count <= maximumBytes else {
      throw ClipLiveShareServerRoomV4FriendError.messageTooLarge
    }
    return try JSONDecoder().decode(
      ClipLiveShareServerRoomV4SignedFriendMessage.self,
      from: data
    )
  }
}

public enum ClipLiveShareServerRoomV4FriendError: Error, Equatable,
  Sendable, LocalizedError
{
  case invalidIdentifier
  case invalidText
  case invalidLifetime
  case expired
  case notYetValid
  case contextMismatch
  case identityMismatch
  case invalidSignature
  case messageTooLarge
  case replayedRequest
  case invalidHandshakeStage

  public var errorDescription: String? {
    switch self {
    case .invalidIdentifier: "The friend request identifier is invalid."
    case .invalidText: "The friend profile text is invalid."
    case .invalidLifetime: "The friend request validity window is invalid."
    case .expired: "The friend request has expired."
    case .notYetValid: "The friend request is not valid yet."
    case .contextMismatch: "The friend request belongs to another room or participant pair."
    case .identityMismatch: "The friend request identity does not match the room participant."
    case .invalidSignature: "The friend request signature is invalid."
    case .messageTooLarge: "The friend request message is too large."
    case .replayedRequest: "The friend request was already completed or rejected."
    case .invalidHandshakeStage: "The friend request arrived out of sequence."
    }
  }
}

private protocol ServerRoomV4FriendContext {
  var requestID: ClipLiveShareServerRoomV4FriendRequestID { get }
  var roomID: ClipLiveShareServerRoomV4RoomID { get }
  var sessionID: ClipLiveShareSessionID { get }
  var requesterParticipantID: ClipLiveShareNativeV3ParticipantID { get }
  var accepterParticipantID: ClipLiveShareNativeV3ParticipantID { get }
}

extension ClipLiveShareServerRoomV4FriendRequest: ServerRoomV4FriendContext {}
extension ClipLiveShareServerRoomV4FriendAcceptance: ServerRoomV4FriendContext {}
extension ClipLiveShareServerRoomV4FriendDecline: ServerRoomV4FriendContext {}
extension ClipLiveShareServerRoomV4FriendAcknowledgement: ServerRoomV4FriendContext {}
extension ClipLiveShareServerRoomV4FriendCommitReceipt: ServerRoomV4FriendContext {}

private func appendFriendContext(
  _ value: some ServerRoomV4FriendContext,
  to encoder: inout ClipLiveShareServerRoomV4CanonicalEncoder
) {
  encoder.append(value.requestID.bytes)
  encoder.append(value.roomID.bytes)
  encoder.append(value.sessionID.rawValue)
  encoder.append(value.requesterParticipantID.bytes)
  encoder.append(value.accepterParticipantID.bytes)
}

private func serverRoomV4FriendValidateText(
  _ value: String,
  maximumBytes: Int
) throws {
  let byteCount = value.utf8.count
  guard (1...maximumBytes).contains(byteCount) else {
    throw ClipLiveShareServerRoomV4FriendError.invalidText
  }
}

private func serverRoomV4FriendValidateLifetime(
  issuedAt: ClipLiveShareNativeTimestamp,
  expiresAt: ClipLiveShareNativeTimestamp
) throws {
  let (maximumExpiry, overflow) = issuedAt.millisecondsSince1970
    .addingReportingOverflow(
      ClipLiveShareServerRoomV4Friends.maximumHandshakeLifetimeMilliseconds
    )
  guard !overflow,
        expiresAt > issuedAt,
        expiresAt.millisecondsSince1970 <= maximumExpiry else {
    throw ClipLiveShareServerRoomV4FriendError.invalidLifetime
  }
}

private func serverRoomV4FriendValidateWindow(
  issuedAt: ClipLiveShareNativeTimestamp,
  expiresAt: ClipLiveShareNativeTimestamp,
  now: ClipLiveShareNativeTimestamp
) throws {
  let (latestAllowed, overflow) = now.millisecondsSince1970
    .addingReportingOverflow(ClipLiveShareNativeV3.maximumClockSkewMilliseconds)
  if !overflow, issuedAt.millisecondsSince1970 > latestAllowed {
    throw ClipLiveShareServerRoomV4FriendError.notYetValid
  }
  guard now < expiresAt else {
    throw ClipLiveShareServerRoomV4FriendError.expired
  }
}

private func serverRoomV4FriendValidateEventWindow(
  eventAt: ClipLiveShareNativeTimestamp,
  expiresAt: ClipLiveShareNativeTimestamp,
  now: ClipLiveShareNativeTimestamp
) throws {
  guard eventAt < expiresAt else {
    throw ClipLiveShareServerRoomV4FriendError.invalidLifetime
  }
  try serverRoomV4FriendValidateWindow(
    issuedAt: eventAt,
    expiresAt: expiresAt,
    now: now
  )
}
