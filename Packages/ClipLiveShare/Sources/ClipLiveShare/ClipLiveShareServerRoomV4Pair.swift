import CryptoKit
import Foundation

/// Stable identity for one unordered direct WebRTC pair. It depends only on
/// room/session and the two routing handles, never on roster revision.
public struct ClipLiveShareServerRoomV4PairContext: Codable, Equatable,
  Hashable, Sendable
{
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let lowerHandle: ClipLiveShareServerRoomV4MemberHandle
  public let upperHandle: ClipLiveShareServerRoomV4MemberHandle
  public let lowerParticipantID: ClipLiveShareNativeV3ParticipantID
  public let upperParticipantID: ClipLiveShareNativeV3ParticipantID
  public let pairID: ClipLiveShareServerRoomV4PairID

  public init(
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    firstHandle: ClipLiveShareServerRoomV4MemberHandle,
    firstParticipantID: ClipLiveShareNativeV3ParticipantID,
    secondHandle: ClipLiveShareServerRoomV4MemberHandle,
    secondParticipantID: ClipLiveShareNativeV3ParticipantID
  ) throws {
    guard firstHandle != secondHandle else {
      throw ClipLiveShareServerRoomV4Error.selfPair
    }
    guard firstParticipantID != secondParticipantID else {
      throw ClipLiveShareServerRoomV4Error.invalidPairContext
    }
    self.roomID = roomID
    self.sessionID = sessionID
    // The Go service sorts the canonical base64url handle strings. Base64url
    // ASCII order is not raw-byte order (`-` sorts before letters despite
    // encoding a high six-bit value), so this comparison must stay textual.
    if firstHandle.rawValue < secondHandle.rawValue {
      lowerHandle = firstHandle
      upperHandle = secondHandle
      lowerParticipantID = firstParticipantID
      upperParticipantID = secondParticipantID
    } else {
      lowerHandle = secondHandle
      upperHandle = firstHandle
      lowerParticipantID = secondParticipantID
      upperParticipantID = firstParticipantID
    }
    pairID = try Self.derivePairID(
      roomID: roomID,
      lowerHandle: lowerHandle,
      upperHandle: upperHandle
    )
  }

  /// Existing concrete WebRTC transport elects the lower room-scoped
  /// participant ID, not the lower service routing handle. The associated
  /// handle is returned so signaling can still be routed by the service.
  public var initialOfferer: ClipLiveShareServerRoomV4MemberHandle {
    lowerParticipantID < upperParticipantID ? lowerHandle : upperHandle
  }
  public var initialOffererParticipantID: ClipLiveShareNativeV3ParticipantID {
    min(lowerParticipantID, upperParticipantID)
  }
  public var memberHandles: Set<ClipLiveShareServerRoomV4MemberHandle> {
    [lowerHandle, upperHandle]
  }
  public func contains(_ handle: ClipLiveShareServerRoomV4MemberHandle) -> Bool {
    handle == lowerHandle || handle == upperHandle
  }
  public func remoteHandle(
    for localHandle: ClipLiveShareServerRoomV4MemberHandle
  ) throws -> ClipLiveShareServerRoomV4MemberHandle {
    if localHandle == lowerHandle { return upperHandle }
    if localHandle == upperHandle { return lowerHandle }
    throw ClipLiveShareServerRoomV4Error.notPairMember
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let roomID = try container.decode(ClipLiveShareServerRoomV4RoomID.self, forKey: .roomID)
    let sessionID = try container.decode(ClipLiveShareSessionID.self, forKey: .sessionID)
    let lower = try container.decode(
      ClipLiveShareServerRoomV4MemberHandle.self, forKey: .lowerHandle)
    let upper = try container.decode(
      ClipLiveShareServerRoomV4MemberHandle.self, forKey: .upperHandle)
    let lowerParticipantID = try container.decode(
      ClipLiveShareNativeV3ParticipantID.self,
      forKey: .lowerParticipantID
    )
    let upperParticipantID = try container.decode(
      ClipLiveShareNativeV3ParticipantID.self,
      forKey: .upperParticipantID
    )
    let asserted = try container.decode(ClipLiveShareServerRoomV4PairID.self, forKey: .pairID)
    let value = try Self(
      roomID: roomID,
      sessionID: sessionID,
      firstHandle: lower,
      firstParticipantID: lowerParticipantID,
      secondHandle: upper,
      secondParticipantID: upperParticipantID
    )
    guard value.lowerHandle == lower, value.upperHandle == upper, value.pairID == asserted else {
      throw ClipLiveShareServerRoomV4Error.invalidPairContext
    }
    self = value
  }

  enum CodingKeys: String, CodingKey {
    case roomID = "roomId"
    case sessionID = "sessionId"
    case lowerHandle
    case upperHandle
    case lowerParticipantID = "lowerParticipantId"
    case upperParticipantID = "upperParticipantId"
    case pairID = "pairId"
  }

  var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/pair-context"
    )
    encoder.append(roomID.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(lowerHandle.bytes)
    encoder.append(upperHandle.bytes)
    encoder.append(lowerParticipantID.bytes)
    encoder.append(upperParticipantID.bytes)
    encoder.append(pairID.bytes)
    return encoder.data
  }

  private static func derivePairID(
    roomID: ClipLiveShareServerRoomV4RoomID,
    lowerHandle: ClipLiveShareServerRoomV4MemberHandle,
    upperHandle: ClipLiveShareServerRoomV4MemberHandle
  ) throws -> ClipLiveShareServerRoomV4PairID {
    // Cross-language server contract. Do not replace this with the canonical
    // field encoder: the Go room service validates this exact byte vector.
    let bytes = Data(
      ("clip-native-room-v4-pair\0" + roomID.rawValue + "\0"
        + lowerHandle.rawValue + "\0" + upperHandle.rawValue).utf8
    )
    return try ClipLiveShareServerRoomV4PairID(
      bytes: Data(SHA256.hash(data: bytes))
    )
  }
}

public struct ClipLiveShareServerRoomV4PairReconciliationPlan: Equatable,
  Sendable
{
  public let rosterRevision: ClipLiveShareServerRoomV4RosterRevision
  public let added: Set<ClipLiveShareServerRoomV4MemberHandle>
  public let retained: Set<ClipLiveShareServerRoomV4MemberHandle>
  public let removed: Set<ClipLiveShareServerRoomV4MemberHandle>

  public init(
    existingPeers: Set<ClipLiveShareServerRoomV4MemberHandle>,
    localHandle: ClipLiveShareServerRoomV4MemberHandle,
    snapshot: ClipLiveShareServerRoomV4RosterSnapshot
  ) throws {
    guard snapshot.member(with: localHandle) != nil else {
      throw ClipLiveShareServerRoomV4Error.invalidRoster("local member is absent")
    }
    let desired = Set(snapshot.members.map(\.handle)).subtracting([localHandle])
    rosterRevision = snapshot.revision
    added = desired.subtracting(existingPeers)
    retained = desired.intersection(existingPeers)
    removed = existingPeers.subtracting(desired)
  }
}

/// Per-pair negotiation state. Roster application never mutates this value;
/// only an explicit initial negotiation or ICE restart advances its epoch.
public struct ClipLiveShareServerRoomV4PairNegotiationState: Equatable,
  Hashable, Sendable
{
  public let context: ClipLiveShareServerRoomV4PairContext
  public private(set) var epoch: ClipLiveShareServerRoomV4PairEpoch

  public init(
    context: ClipLiveShareServerRoomV4PairContext,
    epoch: ClipLiveShareServerRoomV4PairEpoch
  ) {
    self.context = context
    self.epoch = epoch
  }

  @discardableResult
  public mutating func advanceEpoch() throws -> ClipLiveShareServerRoomV4PairEpoch {
    epoch = try epoch.next()
    return epoch
  }
}

public enum ClipLiveShareServerRoomV4PairSignalPayload: Equatable, Hashable,
  Sendable
{
  case offer(epoch: ClipLiveShareServerRoomV4PairEpoch, sdp: String)
  case answer(epoch: ClipLiveShareServerRoomV4PairEpoch, sdp: String)
  case iceCandidate(
    epoch: ClipLiveShareServerRoomV4PairEpoch,
    candidate: String,
    mediaID: String?,
    mediaLineIndex: UInt32?
  )
  case iceRestart(epoch: ClipLiveShareServerRoomV4PairEpoch)
  case renegotiationRequest(epoch: ClipLiveShareServerRoomV4PairEpoch)
  /// Encrypted pair-local request for the canonical offerer to put one exact
  /// participant-selected codec first before creating its next offer. This is
  /// deliberately separate from generic ICE/transport recovery negotiation.
  case codecRenegotiationRequest(
    epoch: ClipLiveShareServerRoomV4PairEpoch,
    codec: LiveShareVideoCodec
  )
  /// The exact codec requested for this Native-Web edge is unsupported by the
  /// browser. The deterministic offerer rolls back instead of leaving an
  /// unanswered offer in flight; no fallback codec is negotiated.
  case codecRenegotiationRejected(
    epoch: ClipLiveShareServerRoomV4PairEpoch,
    codec: LiveShareVideoCodec
  )
  case close

  public var epoch: ClipLiveShareServerRoomV4PairEpoch? {
    switch self {
    case .offer(let epoch, _), .answer(let epoch, _),
      .iceCandidate(let epoch, _, _, _), .iceRestart(let epoch),
      .renegotiationRequest(let epoch),
      .codecRenegotiationRequest(let epoch, _),
      .codecRenegotiationRejected(let epoch, _):
      epoch
    case .close:
      nil
    }
  }

  var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/pair-signal-payload"
    )
    switch self {
    case .offer(let epoch, let sdp):
      encoder.append("offer")
      encoder.append(epoch.rawValue)
      encoder.append(sdp)
    case .answer(let epoch, let sdp):
      encoder.append("answer")
      encoder.append(epoch.rawValue)
      encoder.append(sdp)
    case .iceCandidate(let epoch, let candidate, let mediaID, let mediaLineIndex):
      encoder.append("ice-candidate")
      encoder.append(epoch.rawValue)
      encoder.append(candidate)
      encoder.append(mediaID != nil)
      if let mediaID { encoder.append(mediaID) }
      encoder.append(mediaLineIndex != nil)
      if let mediaLineIndex { encoder.append(UInt64(mediaLineIndex)) }
    case .iceRestart(let epoch):
      encoder.append("ice-restart")
      encoder.append(epoch.rawValue)
    case .renegotiationRequest(let epoch):
      encoder.append("renegotiation-request")
      encoder.append(epoch.rawValue)
    case .codecRenegotiationRequest(let epoch, let codec):
      encoder.append("codec-renegotiation-request")
      encoder.append(epoch.rawValue)
      encoder.append(codec.rawValue)
    case .codecRenegotiationRejected(let epoch, let codec):
      encoder.append("codec-renegotiation-rejected")
      encoder.append(epoch.rawValue)
      encoder.append(codec.rawValue)
    case .close:
      encoder.append("close")
    }
    return encoder.data
  }
}

extension ClipLiveShareServerRoomV4PairSignalPayload: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case epoch
    case sdp
    case candidate
    case mediaID = "mediaId"
    case mediaLineIndex
    case codec
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "offer":
      let epoch = try container.decode(ClipLiveShareServerRoomV4PairEpoch.self, forKey: .epoch)
      let sdp = try container.decode(String.self, forKey: .sdp)
      try Self.validateSDP(sdp)
      self = .offer(epoch: epoch, sdp: sdp)
    case "answer":
      let epoch = try container.decode(ClipLiveShareServerRoomV4PairEpoch.self, forKey: .epoch)
      let sdp = try container.decode(String.self, forKey: .sdp)
      try Self.validateSDP(sdp)
      self = .answer(epoch: epoch, sdp: sdp)
    case "ice-candidate":
      let candidate = try container.decode(String.self, forKey: .candidate)
      guard candidate.utf8.count <= ClipLiveShareServerRoomV4.maximumICECandidateBytes else {
        throw ClipLiveShareServerRoomV4Error.invalidSignalingMessage("ICE candidate")
      }
      let mediaID = try container.decodeIfPresent(String.self, forKey: .mediaID)
      if let mediaID, mediaID.utf8.count > 256 {
        throw ClipLiveShareServerRoomV4Error.invalidSignalingMessage("ICE media ID")
      }
      self = .iceCandidate(
        epoch: try container.decode(ClipLiveShareServerRoomV4PairEpoch.self, forKey: .epoch),
        candidate: candidate,
        mediaID: mediaID,
        mediaLineIndex: try container.decodeIfPresent(UInt32.self, forKey: .mediaLineIndex)
      )
    case "ice-restart":
      self = .iceRestart(
        epoch: try container.decode(ClipLiveShareServerRoomV4PairEpoch.self, forKey: .epoch)
      )
    case "renegotiation-request":
      self = .renegotiationRequest(
        epoch: try container.decode(ClipLiveShareServerRoomV4PairEpoch.self, forKey: .epoch)
      )
    case "codec-renegotiation-request":
      self = .codecRenegotiationRequest(
        epoch: try container.decode(
          ClipLiveShareServerRoomV4PairEpoch.self,
          forKey: .epoch
        ),
        codec: try container.decode(LiveShareVideoCodec.self, forKey: .codec)
      )
    case "codec-renegotiation-rejected":
      self = .codecRenegotiationRejected(
        epoch: try container.decode(
          ClipLiveShareServerRoomV4PairEpoch.self,
          forKey: .epoch
        ),
        codec: try container.decode(LiveShareVideoCodec.self, forKey: .codec)
      )
    case "close":
      self = .close
    default:
      throw ClipLiveShareServerRoomV4Error.invalidSignalingMessage(type)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .offer(let epoch, let sdp):
      try Self.validateSDP(sdp)
      try container.encode("offer", forKey: .type)
      try container.encode(epoch, forKey: .epoch)
      try container.encode(sdp, forKey: .sdp)
    case .answer(let epoch, let sdp):
      try Self.validateSDP(sdp)
      try container.encode("answer", forKey: .type)
      try container.encode(epoch, forKey: .epoch)
      try container.encode(sdp, forKey: .sdp)
    case .iceCandidate(let epoch, let candidate, let mediaID, let mediaLineIndex):
      guard candidate.utf8.count <= ClipLiveShareServerRoomV4.maximumICECandidateBytes,
        mediaID?.utf8.count ?? 0 <= 256
      else {
        throw ClipLiveShareServerRoomV4Error.invalidSignalingMessage("ICE candidate")
      }
      try container.encode("ice-candidate", forKey: .type)
      try container.encode(epoch, forKey: .epoch)
      try container.encode(candidate, forKey: .candidate)
      try container.encodeIfPresent(mediaID, forKey: .mediaID)
      try container.encodeIfPresent(mediaLineIndex, forKey: .mediaLineIndex)
    case .iceRestart(let epoch):
      try container.encode("ice-restart", forKey: .type)
      try container.encode(epoch, forKey: .epoch)
    case .renegotiationRequest(let epoch):
      try container.encode("renegotiation-request", forKey: .type)
      try container.encode(epoch, forKey: .epoch)
    case .codecRenegotiationRequest(let epoch, let codec):
      try container.encode("codec-renegotiation-request", forKey: .type)
      try container.encode(epoch, forKey: .epoch)
      try container.encode(codec, forKey: .codec)
    case .codecRenegotiationRejected(let epoch, let codec):
      try container.encode("codec-renegotiation-rejected", forKey: .type)
      try container.encode(epoch, forKey: .epoch)
      try container.encode(codec, forKey: .codec)
    case .close:
      try container.encode("close", forKey: .type)
    }
  }

  fileprivate static func expectedKeys(
    for type: String
  ) -> (required: Set<String>, allowed: Set<String>)? {
    switch type {
    case "offer", "answer":
      let keys: Set<String> = ["type", "epoch", "sdp"]
      return (keys, keys)
    case "ice-candidate":
      return (
        ["type", "epoch", "candidate"],
        ["type", "epoch", "candidate", "mediaId", "mediaLineIndex"]
      )
    case "ice-restart", "renegotiation-request":
      let keys: Set<String> = ["type", "epoch"]
      return (keys, keys)
    case "codec-renegotiation-request", "codec-renegotiation-rejected":
      let keys: Set<String> = ["type", "epoch", "codec"]
      return (keys, keys)
    case "close":
      let keys: Set<String> = ["type"]
      return (keys, keys)
    default: return nil
    }
  }

  private static func validateSDP(_ sdp: String) throws {
    guard !sdp.isEmpty, sdp.utf8.count <= ClipLiveShareServerRoomV4.maximumSDPBytes else {
      throw ClipLiveShareServerRoomV4Error.invalidSignalingMessage("SDP")
    }
  }
}

public struct ClipLiveShareServerRoomV4PairSignalEnvelope: Codable, Equatable,
  Hashable, Sendable
{
  /// Omitted client-to-server; the service authenticates the socket and fills
  /// this field before forwarding to the peer.
  public let from: ClipLiveShareServerRoomV4MemberHandle?
  public let to: ClipLiveShareServerRoomV4MemberHandle
  public let pairID: ClipLiveShareServerRoomV4PairID
  public let sequence: UInt64
  public let ciphertext: Data

  public init(
    from: ClipLiveShareServerRoomV4MemberHandle?,
    to: ClipLiveShareServerRoomV4MemberHandle,
    pairID: ClipLiveShareServerRoomV4PairID,
    sequence: UInt64,
    ciphertext: Data
  ) throws {
    guard from != to else { throw ClipLiveShareServerRoomV4Error.selfPair }
    guard sequence > 0 else {
      throw ClipLiveShareProtocolError.invalidSequence(expected: 1, actual: sequence)
    }
    let minimum =
      ClipLiveShareServerRoomV4.nonceByteCount
      + ClipLiveShareServerRoomV4.authenticationTagByteCount + 1
    guard ciphertext.count >= minimum,
      ciphertext.count <= ClipLiveShareServerRoomV4.maximumPairSignalCiphertextBytes
    else {
      throw ClipLiveShareServerRoomV4Error.invalidOpaqueValue("pair signal")
    }
    self.from = from
    self.to = to
    self.pairID = pairID
    self.sequence = sequence
    self.ciphertext = ciphertext
  }

  public func routedFrom(
    _ authenticatedSender: ClipLiveShareServerRoomV4MemberHandle
  ) throws -> Self {
    guard from == nil else {
      throw ClipLiveShareServerRoomV4Error.invalidPairContext
    }
    return try Self(
      from: authenticatedSender,
      to: to,
      pairID: pairID,
      sequence: sequence,
      ciphertext: ciphertext
    )
  }

  enum CodingKeys: String, CodingKey {
    case from
    case to
    case pairID = "pairId"
    case sequence
    case ciphertext
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try container.decode(String.self, forKey: .ciphertext)
    guard let ciphertext = ClipLiveShareBase64URL.decode(raw) else {
      throw ClipLiveShareServerRoomV4Error.invalidOpaqueValue("pair signal")
    }
    try self.init(
      from: container.decodeIfPresent(ClipLiveShareServerRoomV4MemberHandle.self, forKey: .from),
      to: container.decode(ClipLiveShareServerRoomV4MemberHandle.self, forKey: .to),
      pairID: container.decode(ClipLiveShareServerRoomV4PairID.self, forKey: .pairID),
      sequence: container.decode(UInt64.self, forKey: .sequence),
      ciphertext: ciphertext
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(from, forKey: .from)
    try container.encode(to, forKey: .to)
    try container.encode(pairID, forKey: .pairID)
    try container.encode(sequence, forKey: .sequence)
    try container.encode(ClipLiveShareBase64URL.encode(ciphertext), forKey: .ciphertext)
  }
}

private struct ClipLiveShareServerRoomV4SignedPairSignal: Codable, Equatable,
  Sendable
{
  let payload: ClipLiveShareServerRoomV4PairSignalPayload
  let signature: ClipLiveShareIdentitySignature
}

/// Stateful, direction-separated signaling channel for one direct pair.
/// Signaling is signed by the persistent identity from the admission record,
/// encrypted using the ephemeral pair keys, and bound to the stable pair
/// context plus strict per-direction sequence.
public struct ClipLiveShareServerRoomV4EncryptedPairSignalingChannel: Sendable {
  public let context: ClipLiveShareServerRoomV4PairContext
  public let localHandle: ClipLiveShareServerRoomV4MemberHandle
  public let remoteHandle: ClipLiveShareServerRoomV4MemberHandle
  public private(set) var lastOutboundSequence: UInt64 = 0
  public private(set) var lastInboundSequence: UInt64 = 0

  private let localSigner: any ClipLiveShareIdentitySigner
  private let remoteIdentity: ClipLiveShareIdentityPublicKey
  private let outboundKey: SymmetricKey
  private let inboundKey: SymmetricKey

  public init(
    context: ClipLiveShareServerRoomV4PairContext,
    localHandle: ClipLiveShareServerRoomV4MemberHandle,
    localKeyAgreementIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity,
    localIdentitySigner: any ClipLiveShareIdentitySigner,
    remoteKeyAgreementPublicKey: ClipLiveShareKeyAgreementPublicKey,
    remoteIdentity: ClipLiveShareIdentityPublicKey
  ) throws {
    guard context.contains(localHandle) else {
      throw ClipLiveShareServerRoomV4Error.notPairMember
    }
    let remoteHandle = try context.remoteHandle(for: localHandle)
    let remoteKey = try P256.KeyAgreement.PublicKey(
      x963Representation: remoteKeyAgreementPublicKey.x963Representation
    )
    let sharedSecret = try localKeyAgreementIdentity.privateKey.sharedSecretFromKeyAgreement(
      with: remoteKey
    )
    self.context = context
    self.localHandle = localHandle
    self.remoteHandle = remoteHandle
    localSigner = localIdentitySigner
    self.remoteIdentity = remoteIdentity
    outboundKey = Self.deriveKey(
      sharedSecret: sharedSecret,
      context: context,
      from: localHandle,
      to: remoteHandle
    )
    inboundKey = Self.deriveKey(
      sharedSecret: sharedSecret,
      context: context,
      from: remoteHandle,
      to: localHandle
    )
  }

  public mutating func seal(
    _ payload: ClipLiveShareServerRoomV4PairSignalPayload
  ) throws -> ClipLiveShareServerRoomV4PairSignalEnvelope {
    try seal(payload, nonce: Data(AES.GCM.Nonce()))
  }

  mutating func seal(
    _ payload: ClipLiveShareServerRoomV4PairSignalPayload,
    nonce: Data
  ) throws -> ClipLiveShareServerRoomV4PairSignalEnvelope {
    guard lastOutboundSequence < UInt64.max else {
      throw ClipLiveShareServerRoomV4Error.sequenceExhausted
    }
    guard nonce.count == ClipLiveShareServerRoomV4.nonceByteCount else {
      throw ClipLiveShareProtocolError.invalidNonceLength(nonce.count)
    }
    let sequence = lastOutboundSequence + 1
    let canonical = signatureCanonicalRepresentation(
      payload: payload,
      from: localHandle,
      to: remoteHandle,
      sequence: sequence
    )
    let signed = ClipLiveShareServerRoomV4SignedPairSignal(
      payload: payload,
      signature: try localSigner.signature(for: canonical)
    )
    let plaintext = try Self.encodeSignedSignal(signed)
    let sealed = try AES.GCM.seal(
      plaintext,
      using: outboundKey,
      nonce: try AES.GCM.Nonce(data: nonce),
      authenticating: authenticatedData(
        from: localHandle,
        to: remoteHandle,
        sequence: sequence
      )
    )
    var ciphertext = nonce
    ciphertext.append(sealed.ciphertext)
    ciphertext.append(sealed.tag)
    let envelope = try ClipLiveShareServerRoomV4PairSignalEnvelope(
      from: nil,
      to: remoteHandle,
      pairID: context.pairID,
      sequence: sequence,
      ciphertext: ciphertext
    )
    lastOutboundSequence = sequence
    return envelope
  }

  public mutating func open(
    _ envelope: ClipLiveShareServerRoomV4PairSignalEnvelope
  ) throws -> ClipLiveShareServerRoomV4PairSignalPayload {
    guard
      envelope.from == remoteHandle,
      envelope.to == localHandle,
      envelope.pairID == context.pairID
    else {
      throw ClipLiveShareServerRoomV4Error.invalidPairContext
    }
    guard envelope.sequence > lastInboundSequence else {
      throw ClipLiveShareProtocolError.invalidSequence(
        expected: lastInboundSequence + 1,
        actual: envelope.sequence
      )
    }
    do {
      let nonce = envelope.ciphertext.prefix(ClipLiveShareServerRoomV4.nonceByteCount)
      let body = envelope.ciphertext.dropFirst(ClipLiveShareServerRoomV4.nonceByteCount)
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce),
        ciphertext: body.dropLast(ClipLiveShareServerRoomV4.authenticationTagByteCount),
        tag: body.suffix(ClipLiveShareServerRoomV4.authenticationTagByteCount)
      )
      let plaintext = try AES.GCM.open(
        box,
        using: inboundKey,
        authenticating: authenticatedData(
          from: remoteHandle,
          to: localHandle,
          sequence: envelope.sequence
        )
      )
      let signed = try Self.decodeSignedSignal(plaintext)
      guard
        remoteIdentity.isValidSignature(
          signed.signature,
          for: signatureCanonicalRepresentation(
            payload: signed.payload,
            from: remoteHandle,
            to: localHandle,
            sequence: envelope.sequence
          )
        )
      else {
        throw ClipLiveShareServerRoomV4Error.invalidSignature
      }
      lastInboundSequence = envelope.sequence
      return signed.payload
    } catch let error as ClipLiveShareServerRoomV4Error {
      throw error
    } catch let error as ClipLiveShareProtocolError {
      throw error
    } catch {
      throw ClipLiveShareProtocolError.authenticationFailed
    }
  }

  private static func encodeSignedSignal(
    _ value: ClipLiveShareServerRoomV4SignedPairSignal
  ) throws -> Data {
    try serverRoomV4StrictEncode(
      value,
      maximumBytes: ClipLiveShareServerRoomV4.maximumPairSignalPlaintextBytes
    )
  }

  private static func decodeSignedSignal(
    _ data: Data
  ) throws -> ClipLiveShareServerRoomV4SignedPairSignal {
    try serverRoomV4RequireExactKeys(data, expected: ["payload", "signature"])
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let payload = root["payload"] as? [String: Any],
      let type = payload["type"] as? String,
      let expected = ClipLiveShareServerRoomV4PairSignalPayload.expectedKeys(for: type),
      expected.required.isSubset(of: Set(payload.keys)),
      Set(payload.keys).isSubset(of: expected.allowed)
    else {
      throw ClipLiveShareServerRoomV4Error.invalidSignalingMessage("payload shape")
    }
    return try serverRoomV4StrictDecode(
      ClipLiveShareServerRoomV4SignedPairSignal.self,
      from: data,
      maximumBytes: ClipLiveShareServerRoomV4.maximumPairSignalPlaintextBytes
    )
  }

  private static func deriveKey(
    sharedSecret: SharedSecret,
    context: ClipLiveShareServerRoomV4PairContext,
    from: ClipLiveShareServerRoomV4MemberHandle,
    to: ClipLiveShareServerRoomV4MemberHandle
  ) -> SymmetricKey {
    let salt = Data(SHA256.hash(data: context.canonicalRepresentation))
    var info = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/pair-key"
    )
    info.append(from.bytes)
    info.append(to.bytes)
    return sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: salt,
      sharedInfo: info.data,
      outputByteCount: 32
    )
  }

  private func authenticatedData(
    from: ClipLiveShareServerRoomV4MemberHandle,
    to: ClipLiveShareServerRoomV4MemberHandle,
    sequence: UInt64
  ) -> Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/pair-envelope"
    )
    encoder.append(context.canonicalRepresentation)
    encoder.append(from.bytes)
    encoder.append(to.bytes)
    encoder.append(sequence)
    return encoder.data
  }

  private func signatureCanonicalRepresentation(
    payload: ClipLiveShareServerRoomV4PairSignalPayload,
    from: ClipLiveShareServerRoomV4MemberHandle,
    to: ClipLiveShareServerRoomV4MemberHandle,
    sequence: UInt64
  ) -> Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/pair-signal-signature"
    )
    encoder.append(context.canonicalRepresentation)
    encoder.append(from.bytes)
    encoder.append(to.bytes)
    encoder.append(sequence)
    encoder.append(payload.canonicalRepresentation)
    return encoder.data
  }
}
