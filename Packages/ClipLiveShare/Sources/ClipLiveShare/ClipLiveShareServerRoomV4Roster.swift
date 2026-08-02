import CryptoKit
import Foundation

public struct ClipLiveShareServerRoomV4OpaqueJoinKnock: Codable, Equatable,
  Hashable, Sendable
{
  public let ciphertext: Data
  public var rawValue: String { ClipLiveShareBase64URL.encode(ciphertext) }
  public init(ciphertext: Data) throws {
    try serverRoomV4ValidateOpaqueCiphertext(
      ciphertext,
      name: "join knock",
      maximum: ClipLiveShareServerRoomV4.maximumOpaqueKnockBytes
    )
    self.ciphertext = ciphertext
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let bytes = ClipLiveShareBase64URL.decode(try container.decode(String.self)) else {
      throw ClipLiveShareServerRoomV4Error.invalidOpaqueValue("join knock")
    }
    try self.init(ciphertext: bytes)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(ClipLiveShareBase64URL.encode(ciphertext))
  }
}

public struct ClipLiveShareServerRoomV4OpaqueAdmissionRecord: Codable,
  Equatable, Hashable, Sendable
{
  public let ciphertext: Data
  public var rawValue: String { ClipLiveShareBase64URL.encode(ciphertext) }
  public init(ciphertext: Data) throws {
    try serverRoomV4ValidateOpaqueCiphertext(
      ciphertext,
      name: "admission record",
      maximum: ClipLiveShareServerRoomV4.maximumOpaqueAdmissionBytes
    )
    self.ciphertext = ciphertext
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let bytes = ClipLiveShareBase64URL.decode(try container.decode(String.self)) else {
      throw ClipLiveShareServerRoomV4Error.invalidOpaqueValue("admission record")
    }
    try self.init(ciphertext: bytes)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(ClipLiveShareBase64URL.encode(ciphertext))
  }
}

/// Service-visible member state. The member handle and socket presence are
/// routing metadata; all participant identity and display data stays inside
/// the creator-certified encrypted admission record.
public struct ClipLiveShareServerRoomV4RosterMember: Codable, Equatable,
  Hashable, Sendable
{
  public let handle: ClipLiveShareServerRoomV4MemberHandle
  public let descriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord
  public let connected: Bool

  public init(
    handle: ClipLiveShareServerRoomV4MemberHandle,
    descriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord,
    connected: Bool
  ) {
    self.handle = handle
    self.descriptor = descriptor
    self.connected = connected
  }

  enum CodingKeys: String, CodingKey {
    case handle
    case descriptor
    case connected
  }
}

/// Complete, service-ordered room membership. Initializers normalize member
/// ordering so snapshots delivered in different array orders reconcile to the
/// same pair graph.
public struct ClipLiveShareServerRoomV4RosterSnapshot: Codable, Equatable,
  Hashable, Sendable
{
  public let revision: ClipLiveShareServerRoomV4RosterRevision
  public let creatorHandle: ClipLiveShareServerRoomV4MemberHandle
  public let members: [ClipLiveShareServerRoomV4RosterMember]

  public init(
    revision: ClipLiveShareServerRoomV4RosterRevision,
    creatorHandle: ClipLiveShareServerRoomV4MemberHandle,
    members: [ClipLiveShareServerRoomV4RosterMember]
  ) throws {
    guard (1...ClipLiveShareServerRoomV4.maximumParticipants).contains(members.count) else {
      throw ClipLiveShareServerRoomV4Error.invalidRoster("participant count")
    }
    let handles = members.map(\.handle)
    guard Set(handles).count == handles.count else {
      throw ClipLiveShareServerRoomV4Error.invalidRoster("duplicate member handle")
    }
    guard handles.contains(creatorHandle) else {
      throw ClipLiveShareServerRoomV4Error.invalidRoster("creator is absent")
    }
    self.revision = revision
    self.creatorHandle = creatorHandle
    self.members = members.sorted { $0.handle < $1.handle }
  }

  public func member(
    with handle: ClipLiveShareServerRoomV4MemberHandle
  ) -> ClipLiveShareServerRoomV4RosterMember? {
    members.first { $0.handle == handle }
  }

  enum CodingKeys: String, CodingKey {
    case revision
    case creatorHandle
    case members
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      revision: container.decode(ClipLiveShareServerRoomV4RosterRevision.self, forKey: .revision),
      creatorHandle: container.decode(
        ClipLiveShareServerRoomV4MemberHandle.self, forKey: .creatorHandle),
      members: container.decode([ClipLiveShareServerRoomV4RosterMember].self, forKey: .members)
    )
  }
}

/// Client-only descriptor encrypted inside admission messages and rosters.
public struct ClipLiveShareServerRoomV4MemberDescriptor: Codable, Equatable,
  Hashable, Sendable
{
  /// Random room-scoped incarnation ID chosen before admission. It is not the
  /// persistent identity fingerprint and therefore cannot link rooms. Existing
  /// source/media ownership can use it before the service assigns a handle.
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let identity: ClipLiveShareIdentityPublicKey
  public let pairSignalingPublicKey: ClipLiveShareKeyAgreementPublicKey
  public let displayName: String
  public let deviceName: String

  public init(
    participantID: ClipLiveShareNativeV3ParticipantID,
    identity: ClipLiveShareIdentityPublicKey,
    pairSignalingPublicKey: ClipLiveShareKeyAgreementPublicKey,
    displayName: String,
    deviceName: String
  ) throws {
    try serverRoomV4ValidateText(
      displayName,
      name: "display name",
      maximum: ClipLiveShareServerRoomV4.maximumDisplayNameBytes
    )
    try serverRoomV4ValidateText(
      deviceName,
      name: "device name",
      maximum: ClipLiveShareServerRoomV4.maximumDisplayNameBytes
    )
    self.participantID = participantID
    self.identity = identity
    self.pairSignalingPublicKey = pairSignalingPublicKey
    self.displayName = displayName
    self.deviceName = deviceName
  }

  var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/member-descriptor"
    )
    encoder.append(participantID.bytes)
    encoder.append(identity.x963Representation)
    encoder.append(pairSignalingPublicKey.x963Representation)
    encoder.append(displayName)
    encoder.append(deviceName)
    return encoder.data
  }
}

public struct ClipLiveShareServerRoomV4JoinKnock: Codable, Equatable, Hashable,
  Sendable
{
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let descriptor: ClipLiveShareServerRoomV4MemberDescriptor
  public let admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability
  public let accessWordProof: ClipLiveShareNativeDigest?
  /// Requests an explicit decision from the room creator after all normal
  /// invite and access-word checks succeed. Friend-presence joins set this so
  /// a saved friend never enters silently, even when the room's general
  /// `askBeforeJoining` policy is disabled. The value is signed and encrypted
  /// with the rest of the knock; the rendezvous service cannot observe it.
  public let requiresCreatorApproval: Bool
  public let nonce: Data

  public init(
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    descriptor: ClipLiveShareServerRoomV4MemberDescriptor,
    admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability,
    accessWordProof: ClipLiveShareNativeDigest?,
    requiresCreatorApproval: Bool = false
  ) throws {
    try self.init(
      roomID: roomID,
      sessionID: sessionID,
      descriptor: descriptor,
      admissionCapability: admissionCapability,
      accessWordProof: accessWordProof,
      requiresCreatorApproval: requiresCreatorApproval,
      nonce: serverRoomV4SecureRandomData(count: 32)
    )
  }

  init(
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    descriptor: ClipLiveShareServerRoomV4MemberDescriptor,
    admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability,
    accessWordProof: ClipLiveShareNativeDigest?,
    requiresCreatorApproval: Bool = false,
    nonce: Data
  ) throws {
    guard nonce.count == 32 else {
      throw ClipLiveShareServerRoomV4Error.invalidSignalingMessage("join nonce")
    }
    self.roomID = roomID
    self.sessionID = sessionID
    self.descriptor = descriptor
    self.admissionCapability = admissionCapability
    self.accessWordProof = accessWordProof
    self.requiresCreatorApproval = requiresCreatorApproval
    self.nonce = nonce
  }

  var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/join-knock"
    )
    encoder.append(roomID.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(descriptor.canonicalRepresentation)
    encoder.append(admissionCapability.keyMaterial)
    encoder.append(accessWordProof != nil)
    if let accessWordProof { encoder.append(accessWordProof.bytes) }
    encoder.append(requiresCreatorApproval)
    encoder.append(nonce)
    return encoder.data
  }
}

public struct ClipLiveShareServerRoomV4SignedJoinKnock: Codable, Equatable,
  Hashable, Sendable
{
  public let knock: ClipLiveShareServerRoomV4JoinKnock
  public let signature: ClipLiveShareIdentitySignature

  public init(
    signing knock: ClipLiveShareServerRoomV4JoinKnock,
    with signer: any ClipLiveShareIdentitySigner
  ) throws {
    guard signer.publicKey == knock.descriptor.identity else {
      throw ClipLiveShareServerRoomV4Error.invalidSignature
    }
    self.knock = knock
    signature = try signer.signature(for: knock.canonicalRepresentation)
  }

  public init(
    knock: ClipLiveShareServerRoomV4JoinKnock,
    signature: ClipLiveShareIdentitySignature
  ) {
    self.knock = knock
    self.signature = signature
  }

  public func verify(
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability
  ) throws {
    guard
      knock.roomID == roomID,
      knock.sessionID == sessionID,
      knock.admissionCapability == admissionCapability
    else {
      throw ClipLiveShareServerRoomV4Error.invalidPairContext
    }
    guard
      knock.descriptor.identity.isValidSignature(
        signature,
        for: knock.canonicalRepresentation
      )
    else {
      throw ClipLiveShareServerRoomV4Error.invalidSignature
    }
  }
}

/// Creator-signed binding between one server-assigned handle and the opaque
/// participant descriptor. This prevents the service from fabricating or
/// swapping identities in a roster snapshot.
public struct ClipLiveShareServerRoomV4AdmissionRecord: Codable, Equatable,
  Hashable, Sendable
{
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  public let memberHandle: ClipLiveShareServerRoomV4MemberHandle
  public let descriptor: ClipLiveShareServerRoomV4MemberDescriptor

  public init(
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    memberHandle: ClipLiveShareServerRoomV4MemberHandle,
    descriptor: ClipLiveShareServerRoomV4MemberDescriptor
  ) {
    self.roomID = roomID
    self.sessionID = sessionID
    self.memberHandle = memberHandle
    self.descriptor = descriptor
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/admission-record"
    )
    encoder.append(roomID.bytes)
    encoder.append(sessionID.rawValue)
    encoder.append(memberHandle.bytes)
    encoder.append(descriptor.canonicalRepresentation)
    return encoder.data
  }
}

public struct ClipLiveShareServerRoomV4SignedAdmissionRecord: Codable,
  Equatable, Hashable, Sendable
{
  public let record: ClipLiveShareServerRoomV4AdmissionRecord
  public let creatorSignature: ClipLiveShareIdentitySignature

  public init(
    signing record: ClipLiveShareServerRoomV4AdmissionRecord,
    with creatorSigner: any ClipLiveShareIdentitySigner
  ) throws {
    self.record = record
    creatorSignature = try creatorSigner.signature(for: record.canonicalRepresentation)
  }

  public init(
    record: ClipLiveShareServerRoomV4AdmissionRecord,
    creatorSignature: ClipLiveShareIdentitySignature
  ) {
    self.record = record
    self.creatorSignature = creatorSignature
  }

  public func verify(
    creatorIdentity: ClipLiveShareIdentityPublicKey,
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    expectedHandle: ClipLiveShareServerRoomV4MemberHandle
  ) throws {
    guard
      record.roomID == roomID,
      record.sessionID == sessionID,
      record.memberHandle == expectedHandle
    else {
      throw ClipLiveShareServerRoomV4Error.invalidPairContext
    }
    guard
      creatorIdentity.isValidSignature(
        creatorSignature,
        for: record.canonicalRepresentation
      )
    else {
      throw ClipLiveShareServerRoomV4Error.invalidSignature
    }
  }
}

/// Group-authenticated encryption for opaque descriptors, knocks, and
/// creator-certified admission records. Each payload has a separate domain so
/// ciphertext from one resource cannot be interpreted as another.
public struct ClipLiveShareServerRoomV4RoomCipher: Sendable {
  public let roomID: ClipLiveShareServerRoomV4RoomID
  public let sessionID: ClipLiveShareSessionID
  private let key: SymmetricKey

  public init(
    roomID: ClipLiveShareServerRoomV4RoomID,
    sessionID: ClipLiveShareSessionID,
    roomAgreementSecret: ClipLiveShareServerRoomV4RoomAgreementSecret
  ) {
    self.roomID = roomID
    self.sessionID = sessionID
    key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: roomAgreementSecret.keyMaterial),
      salt: roomID.bytes,
      info: Data("clip-live-share-server-room-v4/room-cipher".utf8),
      outputByteCount: 32
    )
  }

  public func sealJoinKnock(
    _ knock: ClipLiveShareServerRoomV4SignedJoinKnock
  ) throws -> ClipLiveShareServerRoomV4OpaqueJoinKnock {
    try sealJoinKnock(knock, nonce: Data(AES.GCM.Nonce()))
  }

  func sealJoinKnock(
    _ knock: ClipLiveShareServerRoomV4SignedJoinKnock,
    nonce: Data
  ) throws -> ClipLiveShareServerRoomV4OpaqueJoinKnock {
    let plaintext = try serverRoomV4StrictEncode(
      knock,
      maximumBytes: ClipLiveShareServerRoomV4.maximumOpaqueKnockBytes
    )
    return try .init(ciphertext: seal(plaintext, domain: "join-knock", nonce: nonce))
  }

  public func openJoinKnock(
    _ opaque: ClipLiveShareServerRoomV4OpaqueJoinKnock
  ) throws -> ClipLiveShareServerRoomV4SignedJoinKnock {
    let plaintext = try open(opaque.ciphertext, domain: "join-knock")
    return try serverRoomV4StrictDecode(
      ClipLiveShareServerRoomV4SignedJoinKnock.self,
      from: plaintext,
      maximumBytes: ClipLiveShareServerRoomV4.maximumOpaqueKnockBytes
    )
  }

  public func sealAdmissionRecord(
    _ record: ClipLiveShareServerRoomV4SignedAdmissionRecord
  ) throws -> ClipLiveShareServerRoomV4OpaqueAdmissionRecord {
    try sealAdmissionRecord(record, nonce: Data(AES.GCM.Nonce()))
  }

  func sealAdmissionRecord(
    _ record: ClipLiveShareServerRoomV4SignedAdmissionRecord,
    nonce: Data
  ) throws -> ClipLiveShareServerRoomV4OpaqueAdmissionRecord {
    let plaintext = try serverRoomV4StrictEncode(
      record,
      maximumBytes: ClipLiveShareServerRoomV4.maximumOpaqueAdmissionBytes
    )
    return try .init(ciphertext: seal(plaintext, domain: "admission-record", nonce: nonce))
  }

  public func openAdmissionRecord(
    _ opaque: ClipLiveShareServerRoomV4OpaqueAdmissionRecord
  ) throws -> ClipLiveShareServerRoomV4SignedAdmissionRecord {
    let plaintext = try open(opaque.ciphertext, domain: "admission-record")
    return try serverRoomV4StrictDecode(
      ClipLiveShareServerRoomV4SignedAdmissionRecord.self,
      from: plaintext,
      maximumBytes: ClipLiveShareServerRoomV4.maximumOpaqueAdmissionBytes
    )
  }

  private func seal(_ plaintext: Data, domain: String, nonce: Data) throws -> Data {
    guard nonce.count == ClipLiveShareServerRoomV4.nonceByteCount else {
      throw ClipLiveShareProtocolError.invalidNonceLength(nonce.count)
    }
    let sealed = try AES.GCM.seal(
      plaintext,
      using: key,
      nonce: try AES.GCM.Nonce(data: nonce),
      authenticating: authenticatedData(domain: domain)
    )
    var output = nonce
    output.append(sealed.ciphertext)
    output.append(sealed.tag)
    return output
  }

  private func open(_ payload: Data, domain: String) throws -> Data {
    let overhead =
      ClipLiveShareServerRoomV4.nonceByteCount
      + ClipLiveShareServerRoomV4.authenticationTagByteCount
    guard payload.count > overhead else {
      throw ClipLiveShareProtocolError.authenticationFailed
    }
    do {
      let nonce = payload.prefix(ClipLiveShareServerRoomV4.nonceByteCount)
      let body = payload.dropFirst(ClipLiveShareServerRoomV4.nonceByteCount)
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce),
        ciphertext: body.dropLast(ClipLiveShareServerRoomV4.authenticationTagByteCount),
        tag: body.suffix(ClipLiveShareServerRoomV4.authenticationTagByteCount)
      )
      return try AES.GCM.open(
        box,
        using: key,
        authenticating: authenticatedData(domain: domain)
      )
    } catch {
      throw ClipLiveShareProtocolError.authenticationFailed
    }
  }

  private func authenticatedData(domain: String) -> Data {
    var encoder = ClipLiveShareServerRoomV4CanonicalEncoder(
      domain: "clip-live-share-server-room-v4/room-cipher/\(domain)"
    )
    encoder.append(roomID.bytes)
    encoder.append(sessionID.rawValue)
    return encoder.data
  }
}

private func serverRoomV4ValidateOpaqueCiphertext(
  _ bytes: Data,
  name: String,
  maximum: Int
) throws {
  let minimum =
    ClipLiveShareServerRoomV4.nonceByteCount
    + ClipLiveShareServerRoomV4.authenticationTagByteCount + 1
  guard bytes.count >= minimum, bytes.count <= maximum else {
    throw ClipLiveShareServerRoomV4Error.invalidOpaqueValue(name)
  }
}

private func serverRoomV4ValidateText(
  _ value: String,
  name: String,
  maximum: Int
) throws {
  guard !value.isEmpty, value.utf8.count <= maximum else {
    throw ClipLiveShareServerRoomV4Error.invalidSignalingMessage(name)
  }
}
