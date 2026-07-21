import Foundation

public struct ClipLiveShareNativeFriendRequest: Codable, Equatable, Hashable, Sendable {
  public let requestID: ClipLiveShareFriendRequestID
  public let sessionID: ClipLiveShareSessionID
  public let sessionDescriptorDigest: ClipLiveShareNativeDigest
  public let requestedHostFingerprint: ClipLiveShareIdentityFingerprint
  public let requesterIdentity: ClipLiveShareIdentityPublicKey
  public let requesterEndpoint: ClipLiveShareServerEndpoint
  public let requesterRendezvousID: ClipLiveShareRendezvousID
  public let requesterDeviceName: String
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    requestID: ClipLiveShareFriendRequestID,
    sessionID: ClipLiveShareSessionID,
    sessionDescriptorDigest: ClipLiveShareNativeDigest,
    requestedHostFingerprint: ClipLiveShareIdentityFingerprint,
    requesterIdentity: ClipLiveShareIdentityPublicKey,
    requesterEndpoint: ClipLiveShareServerEndpoint,
    requesterRendezvousID: ClipLiveShareRendezvousID,
    requesterDeviceName: String,
    issuedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    try validateNativeV2Text(
      requesterDeviceName,
      name: "requester device name",
      maximumUTF8Bytes: 128
    )
    try validateNativeV2Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV2.maximumFriendRequestLifetimeMilliseconds
    )
    self.requestID = requestID
    self.sessionID = sessionID
    self.sessionDescriptorDigest = sessionDescriptorDigest
    self.requestedHostFingerprint = requestedHostFingerprint
    self.requesterIdentity = requesterIdentity
    self.requesterEndpoint = requesterEndpoint
    self.requesterRendezvousID = requesterRendezvousID
    self.requesterDeviceName = requesterDeviceName
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/add-friend-request"
    )
    encoder.append(requestID.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(sessionDescriptorDigest.bytes)
    encoder.append(requestedHostFingerprint.bytes)
    encoder.append(requesterIdentity.x963Representation)
    encoder.append(requesterEndpoint.rootURL.absoluteString)
    encoder.append(requesterRendezvousID.bytes)
    encoder.append(requesterDeviceName)
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  public func validate(at now: ClipLiveShareNativeTimestamp) throws {
    try validateNativeV2Text(
      requesterDeviceName,
      name: "requester device name",
      maximumUTF8Bytes: 128
    )
    try validateNativeV2Lifetime(
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV2.maximumFriendRequestLifetimeMilliseconds
    )
    try validateNativeV2ValidityWindow(issuedAt: issuedAt, expiresAt: expiresAt, now: now)
  }

  public func validate(
    expectedSessionDescriptor: ClipLiveShareNativeSessionDescriptor,
    expectedHostIdentity: ClipLiveShareIdentityPublicKey,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    guard
      sessionID == expectedSessionDescriptor.sessionID,
      sessionDescriptorDigest == expectedSessionDescriptor.digest,
      requestedHostFingerprint == expectedHostIdentity.fingerprint,
      expectedSessionDescriptor.hostIdentity == expectedHostIdentity
    else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }
    try validate(at: now)
  }

  private enum CodingKeys: String, CodingKey {
    case requestID = "requestId"
    case sessionID = "sessionId"
    case sessionDescriptorDigest
    case requestedHostFingerprint
    case requesterIdentity
    case requesterEndpoint
    case requesterRendezvousID = "requesterRendezvousId"
    case requesterDeviceName
    case issuedAt
    case expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      requestID: container.decode(ClipLiveShareFriendRequestID.self, forKey: .requestID),
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      sessionDescriptorDigest: container.decode(
        ClipLiveShareNativeDigest.self,
        forKey: .sessionDescriptorDigest
      ),
      requestedHostFingerprint: container.decode(
        ClipLiveShareIdentityFingerprint.self,
        forKey: .requestedHostFingerprint
      ),
      requesterIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .requesterIdentity
      ),
      requesterEndpoint: container.decode(
        ClipLiveShareServerEndpoint.self,
        forKey: .requesterEndpoint
      ),
      requesterRendezvousID: container.decode(
        ClipLiveShareRendezvousID.self,
        forKey: .requesterRendezvousID
      ),
      requesterDeviceName: container.decode(String.self, forKey: .requesterDeviceName),
      issuedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .issuedAt),
      expiresAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .expiresAt)
    )
  }
}

public struct ClipLiveShareNativeFriendAcceptance: Codable, Equatable, Hashable, Sendable {
  public let requestID: ClipLiveShareFriendRequestID
  public let sessionID: ClipLiveShareSessionID
  public let requestDigest: ClipLiveShareNativeDigest
  public let accepterIdentity: ClipLiveShareIdentityPublicKey
  public let requesterFingerprint: ClipLiveShareIdentityFingerprint
  public let accepterDisplayName: String
  public let accepterDeviceName: String
  public let accepterEndpoint: ClipLiveShareServerEndpoint
  public let rendezvousID: ClipLiveShareRendezvousID
  public let acceptedAt: ClipLiveShareNativeTimestamp
  public let stateRevision: ClipLiveShareStateRevision

  public init(
    requestID: ClipLiveShareFriendRequestID,
    sessionID: ClipLiveShareSessionID,
    requestDigest: ClipLiveShareNativeDigest,
    accepterIdentity: ClipLiveShareIdentityPublicKey,
    requesterFingerprint: ClipLiveShareIdentityFingerprint,
    accepterDisplayName: String,
    accepterDeviceName: String,
    accepterEndpoint: ClipLiveShareServerEndpoint,
    rendezvousID: ClipLiveShareRendezvousID,
    acceptedAt: ClipLiveShareNativeTimestamp,
    stateRevision: ClipLiveShareStateRevision
  ) throws {
    try validateNativeV2Text(
      accepterDisplayName,
      name: "accepter display name",
      maximumUTF8Bytes: 128
    )
    try validateNativeV2Text(
      accepterDeviceName,
      name: "accepter device name",
      maximumUTF8Bytes: 128
    )
    self.requestID = requestID
    self.sessionID = sessionID
    self.requestDigest = requestDigest
    self.accepterIdentity = accepterIdentity
    self.requesterFingerprint = requesterFingerprint
    self.accepterDisplayName = accepterDisplayName
    self.accepterDeviceName = accepterDeviceName
    self.accepterEndpoint = accepterEndpoint
    self.rendezvousID = rendezvousID
    self.acceptedAt = acceptedAt
    self.stateRevision = stateRevision
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/add-friend-accept"
    )
    encoder.append(requestID.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(requestDigest.bytes)
    encoder.append(accepterIdentity.x963Representation)
    encoder.append(requesterFingerprint.bytes)
    encoder.append(accepterDisplayName)
    encoder.append(accepterDeviceName)
    encoder.append(accepterEndpoint.rootURL.absoluteString)
    encoder.append(rendezvousID.bytes)
    encoder.append(acceptedAt.millisecondsSince1970)
    encoder.append(stateRevision.rawValue)
    return encoder.data
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  public func validate(
    for request: ClipLiveShareNativeFriendRequest,
    expectedSessionDescriptor: ClipLiveShareNativeSessionDescriptor,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try validateNativeV2Text(
      accepterDisplayName,
      name: "accepter display name",
      maximumUTF8Bytes: 128
    )
    try validateNativeV2Text(
      accepterDeviceName,
      name: "accepter device name",
      maximumUTF8Bytes: 128
    )
    guard
      requestID == request.requestID,
      sessionID == request.sessionID,
      requestDigest == request.digest,
      requesterFingerprint == request.requesterIdentity.fingerprint,
      accepterIdentity.fingerprint == request.requestedHostFingerprint,
      expectedSessionDescriptor.endpoint == accepterEndpoint,
      expectedSessionDescriptor.rendezvousID == rendezvousID,
      expectedSessionDescriptor.stateRevision == stateRevision
    else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }
    try request.validate(
      expectedSessionDescriptor: expectedSessionDescriptor,
      expectedHostIdentity: accepterIdentity,
      at: now
    )
    guard nativeV2Timestamp(acceptedAt, isNoEarlierThan: request.issuedAt) else {
      throw ClipLiveShareNativeV2Error.notYetValid
    }
    try validateNativeV2TimestampIsNotTooFarInFuture(acceptedAt, relativeTo: now)
    guard acceptedAt < request.expiresAt else { throw ClipLiveShareNativeV2Error.expired }
  }

  private enum CodingKeys: String, CodingKey {
    case requestID = "requestId"
    case sessionID = "sessionId"
    case requestDigest
    case accepterIdentity
    case requesterFingerprint
    case accepterDisplayName
    case accepterDeviceName
    case accepterEndpoint
    case rendezvousID = "rendezvousId"
    case acceptedAt
    case stateRevision
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      requestID: container.decode(ClipLiveShareFriendRequestID.self, forKey: .requestID),
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      requestDigest: container.decode(ClipLiveShareNativeDigest.self, forKey: .requestDigest),
      accepterIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .accepterIdentity
      ),
      requesterFingerprint: container.decode(
        ClipLiveShareIdentityFingerprint.self,
        forKey: .requesterFingerprint
      ),
      accepterDisplayName: container.decode(String.self, forKey: .accepterDisplayName),
      accepterDeviceName: container.decode(String.self, forKey: .accepterDeviceName),
      accepterEndpoint: container.decode(
        ClipLiveShareServerEndpoint.self,
        forKey: .accepterEndpoint
      ),
      rendezvousID: container.decode(ClipLiveShareRendezvousID.self, forKey: .rendezvousID),
      acceptedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .acceptedAt),
      stateRevision: container.decode(ClipLiveShareStateRevision.self, forKey: .stateRevision)
    )
  }
}

/// Host-signed proof that the requester's exact acknowledgement was accepted
/// only after the host durably stored the friendship. The requester keeps its
/// local record hidden until this receipt validates and is durably promoted.
public struct ClipLiveShareNativeFriendCommitReceipt: Codable, Equatable, Hashable, Sendable {
  public let requestID: ClipLiveShareFriendRequestID
  public let sessionID: ClipLiveShareSessionID
  public let requestDigest: ClipLiveShareNativeDigest
  public let acceptanceDigest: ClipLiveShareNativeDigest
  public let acknowledgementDigest: ClipLiveShareNativeDigest
  public let requesterIdentity: ClipLiveShareIdentityPublicKey
  public let accepterIdentity: ClipLiveShareIdentityPublicKey
  public let requesterEndpoint: ClipLiveShareServerEndpoint
  public let requesterRendezvousID: ClipLiveShareRendezvousID
  public let accepterEndpoint: ClipLiveShareServerEndpoint
  public let accepterRendezvousID: ClipLiveShareRendezvousID
  public let stateRevision: ClipLiveShareStateRevision
  public let committedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    requestID: ClipLiveShareFriendRequestID,
    sessionID: ClipLiveShareSessionID,
    requestDigest: ClipLiveShareNativeDigest,
    acceptanceDigest: ClipLiveShareNativeDigest,
    acknowledgementDigest: ClipLiveShareNativeDigest,
    requesterIdentity: ClipLiveShareIdentityPublicKey,
    accepterIdentity: ClipLiveShareIdentityPublicKey,
    requesterEndpoint: ClipLiveShareServerEndpoint,
    requesterRendezvousID: ClipLiveShareRendezvousID,
    accepterEndpoint: ClipLiveShareServerEndpoint,
    accepterRendezvousID: ClipLiveShareRendezvousID,
    stateRevision: ClipLiveShareStateRevision,
    committedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    try validateNativeV2Lifetime(
      issuedAt: committedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV2.maximumFriendRequestLifetimeMilliseconds
    )
    self.requestID = requestID
    self.sessionID = sessionID
    self.requestDigest = requestDigest
    self.acceptanceDigest = acceptanceDigest
    self.acknowledgementDigest = acknowledgementDigest
    self.requesterIdentity = requesterIdentity
    self.accepterIdentity = accepterIdentity
    self.requesterEndpoint = requesterEndpoint
    self.requesterRendezvousID = requesterRendezvousID
    self.accepterEndpoint = accepterEndpoint
    self.accepterRendezvousID = accepterRendezvousID
    self.stateRevision = stateRevision
    self.committedAt = committedAt
    self.expiresAt = expiresAt
  }

  public init(
    committing acknowledgement: ClipLiveShareNativeFriendAcceptanceAcknowledgement,
    acknowledgementDigest: ClipLiveShareNativeDigest,
    acceptance: ClipLiveShareNativeFriendAcceptance,
    request: ClipLiveShareNativeFriendRequest,
    committedAt: ClipLiveShareNativeTimestamp
  ) throws {
    try self.init(
      requestID: request.requestID,
      sessionID: request.sessionID,
      requestDigest: request.digest,
      acceptanceDigest: acceptance.digest,
      acknowledgementDigest: acknowledgementDigest,
      requesterIdentity: request.requesterIdentity,
      accepterIdentity: acceptance.accepterIdentity,
      requesterEndpoint: request.requesterEndpoint,
      requesterRendezvousID: request.requesterRendezvousID,
      accepterEndpoint: acceptance.accepterEndpoint,
      accepterRendezvousID: acceptance.rendezvousID,
      stateRevision: acceptance.stateRevision,
      committedAt: committedAt,
      expiresAt: acknowledgement.expiresAt
    )
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/add-friend-commit-receipt"
    )
    encoder.append(requestID.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(requestDigest.bytes)
    encoder.append(acceptanceDigest.bytes)
    encoder.append(acknowledgementDigest.bytes)
    encoder.append(requesterIdentity.x963Representation)
    encoder.append(accepterIdentity.x963Representation)
    encoder.append(requesterEndpoint.rootURL.absoluteString)
    encoder.append(requesterRendezvousID.bytes)
    encoder.append(accepterEndpoint.rootURL.absoluteString)
    encoder.append(accepterRendezvousID.bytes)
    encoder.append(stateRevision.rawValue)
    encoder.append(committedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: canonicalRepresentation)
  }

  public func validate(
    for acknowledgement: ClipLiveShareNativeFriendAcceptanceAcknowledgement,
    acknowledgementDigest signedAcknowledgementDigest: ClipLiveShareNativeDigest,
    acceptance: ClipLiveShareNativeFriendAcceptance,
    request: ClipLiveShareNativeFriendRequest,
    expectedSessionDescriptor: ClipLiveShareNativeSessionDescriptor,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try validateNativeV2Lifetime(
      issuedAt: committedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV2.maximumFriendRequestLifetimeMilliseconds
    )
    guard
      requestID == request.requestID,
      sessionID == request.sessionID,
      requestDigest == request.digest,
      acceptanceDigest == acceptance.digest,
      acknowledgementDigest == signedAcknowledgementDigest,
      requesterIdentity == request.requesterIdentity,
      accepterIdentity == acceptance.accepterIdentity,
      requesterEndpoint == request.requesterEndpoint,
      requesterRendezvousID == request.requesterRendezvousID,
      accepterEndpoint == acceptance.accepterEndpoint,
      accepterRendezvousID == acceptance.rendezvousID,
      stateRevision == acceptance.stateRevision,
      expiresAt == acknowledgement.expiresAt
    else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }
    try acknowledgement.validate(
      for: acceptance,
      request: request,
      expectedSessionDescriptor: expectedSessionDescriptor,
      at: now
    )
    guard nativeV2Timestamp(committedAt, isNoEarlierThan: acknowledgement.acknowledgedAt) else {
      throw ClipLiveShareNativeV2Error.notYetValid
    }
    try validateNativeV2ValidityWindow(
      issuedAt: committedAt,
      expiresAt: expiresAt,
      now: now
    )
  }

  private enum CodingKeys: String, CodingKey {
    case requestID = "requestId"
    case sessionID = "sessionId"
    case requestDigest
    case acceptanceDigest
    case acknowledgementDigest
    case requesterIdentity
    case accepterIdentity
    case requesterEndpoint
    case requesterRendezvousID = "requesterRendezvousId"
    case accepterEndpoint
    case accepterRendezvousID = "accepterRendezvousId"
    case stateRevision
    case committedAt
    case expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      requestID: container.decode(ClipLiveShareFriendRequestID.self, forKey: .requestID),
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      requestDigest: container.decode(ClipLiveShareNativeDigest.self, forKey: .requestDigest),
      acceptanceDigest: container.decode(
        ClipLiveShareNativeDigest.self,
        forKey: .acceptanceDigest
      ),
      acknowledgementDigest: container.decode(
        ClipLiveShareNativeDigest.self,
        forKey: .acknowledgementDigest
      ),
      requesterIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .requesterIdentity
      ),
      accepterIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .accepterIdentity
      ),
      requesterEndpoint: container.decode(
        ClipLiveShareServerEndpoint.self,
        forKey: .requesterEndpoint
      ),
      requesterRendezvousID: container.decode(
        ClipLiveShareRendezvousID.self,
        forKey: .requesterRendezvousID
      ),
      accepterEndpoint: container.decode(
        ClipLiveShareServerEndpoint.self,
        forKey: .accepterEndpoint
      ),
      accepterRendezvousID: container.decode(
        ClipLiveShareRendezvousID.self,
        forKey: .accepterRendezvousID
      ),
      stateRevision: container.decode(ClipLiveShareStateRevision.self, forKey: .stateRevision),
      committedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .committedAt),
      expiresAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .expiresAt)
    )
  }
}

/// Requester-signed confirmation that it validated and durably accepted the
/// host's exact friendship acceptance. Hosts can defer their own contact write
/// until this acknowledgement arrives, then treat retransmission of the same
/// canonical statement idempotently.
public struct ClipLiveShareNativeFriendAcceptanceAcknowledgement: Codable, Equatable, Hashable,
  Sendable
{
  public let requestID: ClipLiveShareFriendRequestID
  public let sessionID: ClipLiveShareSessionID
  public let requestDigest: ClipLiveShareNativeDigest
  public let acceptanceDigest: ClipLiveShareNativeDigest
  public let requesterIdentity: ClipLiveShareIdentityPublicKey
  public let accepterIdentity: ClipLiveShareIdentityPublicKey
  public let requesterEndpoint: ClipLiveShareServerEndpoint
  public let requesterRendezvousID: ClipLiveShareRendezvousID
  public let accepterEndpoint: ClipLiveShareServerEndpoint
  public let accepterRendezvousID: ClipLiveShareRendezvousID
  public let stateRevision: ClipLiveShareStateRevision
  public let acknowledgedAt: ClipLiveShareNativeTimestamp
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    requestID: ClipLiveShareFriendRequestID,
    sessionID: ClipLiveShareSessionID,
    requestDigest: ClipLiveShareNativeDigest,
    acceptanceDigest: ClipLiveShareNativeDigest,
    requesterIdentity: ClipLiveShareIdentityPublicKey,
    accepterIdentity: ClipLiveShareIdentityPublicKey,
    requesterEndpoint: ClipLiveShareServerEndpoint,
    requesterRendezvousID: ClipLiveShareRendezvousID,
    accepterEndpoint: ClipLiveShareServerEndpoint,
    accepterRendezvousID: ClipLiveShareRendezvousID,
    stateRevision: ClipLiveShareStateRevision,
    acknowledgedAt: ClipLiveShareNativeTimestamp,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    try validateNativeV2Lifetime(
      issuedAt: acknowledgedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV2.maximumFriendRequestLifetimeMilliseconds
    )
    self.requestID = requestID
    self.sessionID = sessionID
    self.requestDigest = requestDigest
    self.acceptanceDigest = acceptanceDigest
    self.requesterIdentity = requesterIdentity
    self.accepterIdentity = accepterIdentity
    self.requesterEndpoint = requesterEndpoint
    self.requesterRendezvousID = requesterRendezvousID
    self.accepterEndpoint = accepterEndpoint
    self.accepterRendezvousID = accepterRendezvousID
    self.stateRevision = stateRevision
    self.acknowledgedAt = acknowledgedAt
    self.expiresAt = expiresAt
  }

  public init(
    acknowledging acceptance: ClipLiveShareNativeFriendAcceptance,
    for request: ClipLiveShareNativeFriendRequest,
    acknowledgedAt: ClipLiveShareNativeTimestamp
  ) throws {
    try self.init(
      requestID: request.requestID,
      sessionID: request.sessionID,
      requestDigest: request.digest,
      acceptanceDigest: acceptance.digest,
      requesterIdentity: request.requesterIdentity,
      accepterIdentity: acceptance.accepterIdentity,
      requesterEndpoint: request.requesterEndpoint,
      requesterRendezvousID: request.requesterRendezvousID,
      accepterEndpoint: acceptance.accepterEndpoint,
      accepterRendezvousID: acceptance.rendezvousID,
      stateRevision: acceptance.stateRevision,
      acknowledgedAt: acknowledgedAt,
      expiresAt: request.expiresAt
    )
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/add-friend-acceptance-acknowledgement"
    )
    encoder.append(requestID.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(requestDigest.bytes)
    encoder.append(acceptanceDigest.bytes)
    encoder.append(requesterIdentity.x963Representation)
    encoder.append(accepterIdentity.x963Representation)
    encoder.append(requesterEndpoint.rootURL.absoluteString)
    encoder.append(requesterRendezvousID.bytes)
    encoder.append(accepterEndpoint.rootURL.absoluteString)
    encoder.append(accepterRendezvousID.bytes)
    encoder.append(stateRevision.rawValue)
    encoder.append(acknowledgedAt.millisecondsSince1970)
    encoder.append(expiresAt.millisecondsSince1970)
    return encoder.data
  }

  public func validate(
    for acceptance: ClipLiveShareNativeFriendAcceptance,
    request: ClipLiveShareNativeFriendRequest,
    expectedSessionDescriptor: ClipLiveShareNativeSessionDescriptor,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    try validateNativeV2Lifetime(
      issuedAt: acknowledgedAt,
      expiresAt: expiresAt,
      maximumMilliseconds: ClipLiveShareNativeV2.maximumFriendRequestLifetimeMilliseconds
    )
    guard
      requestID == request.requestID,
      sessionID == request.sessionID,
      requestDigest == request.digest,
      acceptanceDigest == acceptance.digest,
      requesterIdentity == request.requesterIdentity,
      accepterIdentity == acceptance.accepterIdentity,
      requesterEndpoint == request.requesterEndpoint,
      requesterRendezvousID == request.requesterRendezvousID,
      accepterEndpoint == acceptance.accepterEndpoint,
      accepterRendezvousID == acceptance.rendezvousID,
      stateRevision == acceptance.stateRevision,
      expiresAt == request.expiresAt
    else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }
    try acceptance.validate(
      for: request,
      expectedSessionDescriptor: expectedSessionDescriptor,
      at: now
    )
    guard nativeV2Timestamp(acknowledgedAt, isNoEarlierThan: acceptance.acceptedAt) else {
      throw ClipLiveShareNativeV2Error.notYetValid
    }
    try validateNativeV2ValidityWindow(
      issuedAt: acknowledgedAt,
      expiresAt: expiresAt,
      now: now
    )
  }

  private enum CodingKeys: String, CodingKey {
    case requestID = "requestId"
    case sessionID = "sessionId"
    case requestDigest
    case acceptanceDigest
    case requesterIdentity
    case accepterIdentity
    case requesterEndpoint
    case requesterRendezvousID = "requesterRendezvousId"
    case accepterEndpoint
    case accepterRendezvousID = "accepterRendezvousId"
    case stateRevision
    case acknowledgedAt
    case expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      requestID: container.decode(ClipLiveShareFriendRequestID.self, forKey: .requestID),
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      requestDigest: container.decode(ClipLiveShareNativeDigest.self, forKey: .requestDigest),
      acceptanceDigest: container.decode(
        ClipLiveShareNativeDigest.self,
        forKey: .acceptanceDigest
      ),
      requesterIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .requesterIdentity
      ),
      accepterIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .accepterIdentity
      ),
      requesterEndpoint: container.decode(
        ClipLiveShareServerEndpoint.self,
        forKey: .requesterEndpoint
      ),
      requesterRendezvousID: container.decode(
        ClipLiveShareRendezvousID.self,
        forKey: .requesterRendezvousID
      ),
      accepterEndpoint: container.decode(
        ClipLiveShareServerEndpoint.self,
        forKey: .accepterEndpoint
      ),
      accepterRendezvousID: container.decode(
        ClipLiveShareRendezvousID.self,
        forKey: .accepterRendezvousID
      ),
      stateRevision: container.decode(ClipLiveShareStateRevision.self, forKey: .stateRevision),
      acknowledgedAt: container.decode(
        ClipLiveShareNativeTimestamp.self,
        forKey: .acknowledgedAt
      ),
      expiresAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .expiresAt)
    )
  }
}

public struct ClipLiveShareNativeFriendDecline: Codable, Equatable, Hashable, Sendable {
  public let requestID: ClipLiveShareFriendRequestID
  public let sessionID: ClipLiveShareSessionID
  public let requestDigest: ClipLiveShareNativeDigest
  public let declinerIdentity: ClipLiveShareIdentityPublicKey
  public let requesterFingerprint: ClipLiveShareIdentityFingerprint
  public let declinedAt: ClipLiveShareNativeTimestamp
  public let reason: String?

  public init(
    requestID: ClipLiveShareFriendRequestID,
    sessionID: ClipLiveShareSessionID,
    requestDigest: ClipLiveShareNativeDigest,
    declinerIdentity: ClipLiveShareIdentityPublicKey,
    requesterFingerprint: ClipLiveShareIdentityFingerprint,
    declinedAt: ClipLiveShareNativeTimestamp,
    reason: String? = nil
  ) throws {
    if let reason {
      try validateNativeV2Text(
        reason,
        name: "friend decline reason",
        maximumUTF8Bytes: 128
      )
    }
    self.requestID = requestID
    self.sessionID = sessionID
    self.requestDigest = requestDigest
    self.declinerIdentity = declinerIdentity
    self.requesterFingerprint = requesterFingerprint
    self.declinedAt = declinedAt
    self.reason = reason
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/add-friend-decline"
    )
    encoder.append(requestID.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(requestDigest.bytes)
    encoder.append(declinerIdentity.x963Representation)
    encoder.append(requesterFingerprint.bytes)
    encoder.append(declinedAt.millisecondsSince1970)
    encoder.append(reason != nil)
    if let reason { encoder.append(reason) }
    return encoder.data
  }

  public func validate(
    for request: ClipLiveShareNativeFriendRequest,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    if let reason {
      try validateNativeV2Text(
        reason,
        name: "friend decline reason",
        maximumUTF8Bytes: 128
      )
    }
    guard
      requestID == request.requestID,
      sessionID == request.sessionID,
      requestDigest == request.digest,
      requesterFingerprint == request.requesterIdentity.fingerprint,
      declinerIdentity.fingerprint == request.requestedHostFingerprint
    else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }
    try request.validate(at: now)
    guard nativeV2Timestamp(declinedAt, isNoEarlierThan: request.issuedAt) else {
      throw ClipLiveShareNativeV2Error.notYetValid
    }
    try validateNativeV2TimestampIsNotTooFarInFuture(declinedAt, relativeTo: now)
    guard declinedAt < request.expiresAt else { throw ClipLiveShareNativeV2Error.expired }
  }

  private enum CodingKeys: String, CodingKey {
    case requestID = "requestId"
    case sessionID = "sessionId"
    case requestDigest
    case declinerIdentity
    case requesterFingerprint
    case declinedAt
    case reason
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      requestID: container.decode(ClipLiveShareFriendRequestID.self, forKey: .requestID),
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      requestDigest: container.decode(ClipLiveShareNativeDigest.self, forKey: .requestDigest),
      declinerIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .declinerIdentity
      ),
      requesterFingerprint: container.decode(
        ClipLiveShareIdentityFingerprint.self,
        forKey: .requesterFingerprint
      ),
      declinedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .declinedAt),
      reason: container.decodeIfPresent(String.self, forKey: .reason)
    )
  }
}

public struct ClipLiveShareNativeFriendRevocation: Codable, Equatable, Hashable, Sendable {
  public let revocationID: ClipLiveShareRevocationID
  public let issuerIdentity: ClipLiveShareIdentityPublicKey
  public let revokedIdentityFingerprint: ClipLiveShareIdentityFingerprint
  public let rendezvousID: ClipLiveShareRendezvousID
  public let stateRevision: ClipLiveShareStateRevision
  public let issuedAt: ClipLiveShareNativeTimestamp
  public let reason: String?

  public init(
    revocationID: ClipLiveShareRevocationID,
    issuerIdentity: ClipLiveShareIdentityPublicKey,
    revokedIdentityFingerprint: ClipLiveShareIdentityFingerprint,
    rendezvousID: ClipLiveShareRendezvousID,
    stateRevision: ClipLiveShareStateRevision,
    issuedAt: ClipLiveShareNativeTimestamp,
    reason: String? = nil
  ) throws {
    if let reason {
      try validateNativeV2Text(
        reason,
        name: "friend revocation reason",
        maximumUTF8Bytes: 256
      )
    }
    self.revocationID = revocationID
    self.issuerIdentity = issuerIdentity
    self.revokedIdentityFingerprint = revokedIdentityFingerprint
    self.rendezvousID = rendezvousID
    self.stateRevision = stateRevision
    self.issuedAt = issuedAt
    self.reason = reason
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/friend-revocation"
    )
    encoder.append(revocationID.bytes)
    encoder.append(issuerIdentity.x963Representation)
    encoder.append(revokedIdentityFingerprint.bytes)
    encoder.append(rendezvousID.bytes)
    encoder.append(stateRevision.rawValue)
    encoder.append(issuedAt.millisecondsSince1970)
    encoder.append(reason != nil)
    if let reason { encoder.append(reason) }
    return encoder.data
  }

  public func validate(
    expectedIssuer: ClipLiveShareIdentityPublicKey,
    expectedRevokedIdentity: ClipLiveShareIdentityFingerprint,
    expectedRendezvousID: ClipLiveShareRendezvousID,
    at now: ClipLiveShareNativeTimestamp
  ) throws {
    if let reason {
      try validateNativeV2Text(
        reason,
        name: "friend revocation reason",
        maximumUTF8Bytes: 256
      )
    }
    guard issuerIdentity == expectedIssuer else {
      throw ClipLiveShareNativeV2Error.identityMismatch
    }
    guard
      revokedIdentityFingerprint == expectedRevokedIdentity,
      rendezvousID == expectedRendezvousID
    else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }
    try validateNativeV2TimestampIsNotTooFarInFuture(issuedAt, relativeTo: now)
  }

  private enum CodingKeys: String, CodingKey {
    case revocationID = "revocationId"
    case issuerIdentity
    case revokedIdentityFingerprint
    case rendezvousID = "rendezvousId"
    case stateRevision
    case issuedAt
    case reason
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      revocationID: container.decode(ClipLiveShareRevocationID.self, forKey: .revocationID),
      issuerIdentity: container.decode(
        ClipLiveShareIdentityPublicKey.self,
        forKey: .issuerIdentity
      ),
      revokedIdentityFingerprint: container.decode(
        ClipLiveShareIdentityFingerprint.self,
        forKey: .revokedIdentityFingerprint
      ),
      rendezvousID: container.decode(ClipLiveShareRendezvousID.self, forKey: .rendezvousID),
      stateRevision: container.decode(ClipLiveShareStateRevision.self, forKey: .stateRevision),
      issuedAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .issuedAt),
      reason: container.decodeIfPresent(String.self, forKey: .reason)
    )
  }
}

public enum ClipLiveShareNativeFriendMessage: Equatable, Hashable, Sendable {
  case request(ClipLiveShareNativeFriendRequest)
  case accepted(ClipLiveShareNativeFriendAcceptance)
  case acceptanceAcknowledged(ClipLiveShareNativeFriendAcceptanceAcknowledgement)
  case commitReceipt(ClipLiveShareNativeFriendCommitReceipt)
  case declined(ClipLiveShareNativeFriendDecline)
  case revoked(ClipLiveShareNativeFriendRevocation)

  public var type: String {
    switch self {
    case .request: "add-friend-request"
    case .accepted: "add-friend-accepted"
    case .acceptanceAcknowledged: "add-friend-acceptance-acknowledged"
    case .commitReceipt: "add-friend-commit-receipt"
    case .declined: "add-friend-declined"
    case .revoked: "friend-revoked"
    }
  }

  public var signingIdentity: ClipLiveShareIdentityPublicKey {
    switch self {
    case let .request(value): value.requesterIdentity
    case let .accepted(value): value.accepterIdentity
    case let .acceptanceAcknowledged(value): value.requesterIdentity
    case let .commitReceipt(value): value.accepterIdentity
    case let .declined(value): value.declinerIdentity
    case let .revoked(value): value.issuerIdentity
    }
  }

  public var canonicalRepresentation: Data {
    switch self {
    case let .request(value): value.canonicalRepresentation
    case let .accepted(value): value.canonicalRepresentation
    case let .acceptanceAcknowledged(value): value.canonicalRepresentation
    case let .commitReceipt(value): value.canonicalRepresentation
    case let .declined(value): value.canonicalRepresentation
    case let .revoked(value): value.canonicalRepresentation
    }
  }
}

extension ClipLiveShareNativeFriendMessage: Codable {
  private enum CodingKeys: String, CodingKey {
    case version
    case type
    case payload
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ClipLiveShareNativeV2.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    switch try container.decode(String.self, forKey: .type) {
    case "add-friend-request":
      self = .request(
        try container.decode(ClipLiveShareNativeFriendRequest.self, forKey: .payload)
      )
    case "add-friend-accepted":
      self = .accepted(
        try container.decode(ClipLiveShareNativeFriendAcceptance.self, forKey: .payload)
      )
    case "add-friend-acceptance-acknowledged":
      self = .acceptanceAcknowledged(
        try container.decode(
          ClipLiveShareNativeFriendAcceptanceAcknowledgement.self,
          forKey: .payload
        )
      )
    case "add-friend-commit-receipt":
      self = .commitReceipt(
        try container.decode(
          ClipLiveShareNativeFriendCommitReceipt.self,
          forKey: .payload
        )
      )
    case "add-friend-declined":
      self = .declined(
        try container.decode(ClipLiveShareNativeFriendDecline.self, forKey: .payload)
      )
    case "friend-revoked":
      self = .revoked(
        try container.decode(ClipLiveShareNativeFriendRevocation.self, forKey: .payload)
      )
    case let type:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown native friend message type: \(type)"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ClipLiveShareNativeV2.version, forKey: .version)
    try container.encode(type, forKey: .type)
    switch self {
    case let .request(value): try container.encode(value, forKey: .payload)
    case let .accepted(value): try container.encode(value, forKey: .payload)
    case let .acceptanceAcknowledged(value): try container.encode(value, forKey: .payload)
    case let .commitReceipt(value): try container.encode(value, forKey: .payload)
    case let .declined(value): try container.encode(value, forKey: .payload)
    case let .revoked(value): try container.encode(value, forKey: .payload)
    }
  }
}

public struct ClipLiveShareSignedNativeFriendMessage: Codable, Equatable, Hashable, Sendable {
  public let message: ClipLiveShareNativeFriendMessage
  public let signature: ClipLiveShareIdentitySignature

  public init(
    message: ClipLiveShareNativeFriendMessage,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.message = message
    self.signature = signature
  }

  public init(
    signing message: ClipLiveShareNativeFriendMessage,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    guard signer.publicKey == message.signingIdentity else {
      throw ClipLiveShareNativeV2Error.identityMismatch
    }
    self.message = message
    signature = try signer.signature(for: message.canonicalRepresentation)
  }

  public var digest: ClipLiveShareNativeDigest {
    // Key replay protection by the signed statement rather than the ECDSA
    // byte representation, which is not itself the semantic identity.
    ClipLiveShareNativeDigest(hashing: message.canonicalRepresentation)
  }

  public func verifySignature(expectedIdentity: ClipLiveShareIdentityPublicKey) throws {
    guard message.signingIdentity == expectedIdentity else {
      throw ClipLiveShareNativeV2Error.identityMismatch
    }
    guard
      expectedIdentity.isValidSignature(
        signature,
        for: message.canonicalRepresentation
      )
    else {
      throw ClipLiveShareNativeV2Error.invalidSignature
    }
  }
}

public struct ClipLiveShareNativeFriendReplayGuard: Equatable, Sendable {
  private var acceptedDigests: [ClipLiveShareNativeDigest] = []
  public let maximumRecords: Int

  public init(maximumRecords: Int = 256) throws {
    guard maximumRecords > 0 else {
      throw ClipLiveShareProtocolError.invalidResource(
        "friend replay guard capacity must be positive"
      )
    }
    self.maximumRecords = maximumRecords
  }

  /// Verifies signer authenticity and one-time use only. Call the selected
  /// payload's context validator before mutating contact state.
  public mutating func acceptSignatureOnce(
    _ message: ClipLiveShareSignedNativeFriendMessage,
    expectedIdentity: ClipLiveShareIdentityPublicKey
  ) throws {
    try message.verifySignature(expectedIdentity: expectedIdentity)
    guard !acceptedDigests.contains(message.digest) else {
      throw ClipLiveShareNativeV2Error.replayed
    }
    if acceptedDigests.count == maximumRecords {
      acceptedDigests.removeFirst()
    }
    acceptedDigests.append(message.digest)
  }

  /// Verifies a friendship acceptance acknowledgement and returns whether its
  /// canonical statement is new. A retransmitted acknowledgement is a safe
  /// duplicate instead of a second contact mutation; all other friend message
  /// variants remain one-shot through `acceptSignatureOnce`.
  public mutating func acceptAcknowledgementIdempotently(
    _ message: ClipLiveShareSignedNativeFriendMessage,
    expectedIdentity: ClipLiveShareIdentityPublicKey
  ) throws -> ClipLiveShareNativeFriendAcknowledgementAdmission {
    guard case .acceptanceAcknowledged = message.message else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }
    try message.verifySignature(expectedIdentity: expectedIdentity)
    if acceptedDigests.contains(message.digest) {
      return .duplicate
    }
    if acceptedDigests.count == maximumRecords {
      acceptedDigests.removeFirst()
    }
    acceptedDigests.append(message.digest)
    return .firstSeen
  }

  /// Verifies a host commit receipt while allowing retransmission of the exact
  /// same canonical receipt. A distinct receipt remains a separate statement
  /// whose request/acknowledgement context must be rejected by the caller.
  public mutating func acceptCommitReceiptIdempotently(
    _ message: ClipLiveShareSignedNativeFriendMessage,
    expectedIdentity: ClipLiveShareIdentityPublicKey
  ) throws -> ClipLiveShareNativeFriendCommitReceiptAdmission {
    guard case .commitReceipt = message.message else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }
    try message.verifySignature(expectedIdentity: expectedIdentity)
    if acceptedDigests.contains(message.digest) {
      return .duplicate
    }
    if acceptedDigests.count == maximumRecords {
      acceptedDigests.removeFirst()
    }
    acceptedDigests.append(message.digest)
    return .firstSeen
  }
}

public enum ClipLiveShareNativeFriendAcknowledgementAdmission: Equatable, Sendable {
  case firstSeen
  case duplicate
}

public enum ClipLiveShareNativeFriendCommitReceiptAdmission: Equatable, Sendable {
  case firstSeen
  case duplicate
}
