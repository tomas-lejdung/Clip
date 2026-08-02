import Foundation

/// Native Clip-to-Clip protocol primitives for participant meshes.
///
/// Signatures use native-v3-specific canonical domains so values from another
/// protocol cannot be interpreted as valid participant-mesh messages.
public enum ClipLiveShareNativeV3 {
  public static let version = 3
  public static let protocolIdentifier = "clip-live-share-native"
  public static let controlDataChannelLabel = "clip-native-control-v3"
  /// Bounds every native-v3 room-control payload. The value leaves comfortable
  /// headroom for WebRTC DataChannel framing while still accommodating a
  /// complete four-participant membership, four source descriptors per
  /// participant, ICE batches, and bounded collaboration strokes.
  public static let maximumControlMessageBytes = 196_400

  public static let participantIDByteCount = 16
  /// Each peer connection reserves four deterministic video slots. This is a
  /// native-v3 wire invariant rather than an alias to another protocol.
  public static let reservedVideoSlotsPerParticipant = 4
  public static let maximumSourcesPerParticipant = reservedVideoSlotsPerParticipant
  /// Product and protocol expose all four deterministic video slots. This
  /// preserves Clip's existing four-source Live Share contract for every mesh
  /// participant instead of making the symmetric room a functional downgrade.
  public static let defaultMaximumActiveSourcesPerParticipant =
    reservedVideoSlotsPerParticipant

  /// The wire protocol is intentionally bounded because a complete mesh has
  /// O(n²) peer links. Four participants require six links.
  public static let maximumProtocolParticipants = 4

  /// The product release gate exercises the complete four-participant graph:
  /// six direct peer links, while every process owns only its three incident
  /// connections.
  public static let defaultProductAdmissionLimit = 4

  public static let transportNonceByteCount = 32
  public static let maximumClockSkewMilliseconds: Int64 = 30 * 1_000
}

public enum ClipLiveShareNativeV3Error: Error, Equatable, Sendable {
  case invalidParticipantID
  case invalidText(name: String)
  case invalidRevision(name: String)
  case staleMembershipRevision(expectedGreaterThan: UInt64, actual: UInt64)
  case staleSourceRevision(
    participantID: ClipLiveShareNativeV3ParticipantID,
    expectedGreaterThan: UInt64,
    actual: UInt64
  )
  case stalePeerLinkRevision(
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    expectedGreaterThan: UInt64,
    actual: UInt64
  )
  case invalidBinaryValue(name: String, expectedBytes: Int)
  case invalidPeerLinkContext
  case unknownControlMessageType(String)
  case staleRoomAdmissionPolicyRevision(
    expectedGreaterThan: UInt64,
    actual: UInt64
  )
  case staleRoomTerminationRevision(expectedGreaterThan: UInt64, actual: UInt64)
  case selfPeerLink
  case participantLimit(maximum: Int, actual: Int)
  case duplicateParticipant
  case duplicateIdentity
  case duplicateSource
  case unknownParticipant(ClipLiveShareNativeV3ParticipantID)
  case participantIdentityChanged(ClipLiveShareNativeV3ParticipantID)
  case invalidSourceOwnership
  case invalidTopology
  case contextMismatch
  case identityMismatch
  case invalidSignature
  case invalidLifetime
  case expired
  case notYetValid
}

extension ClipLiveShareNativeV3Error: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidParticipantID:
      "A native v3 participant identifier must contain exactly 16 bytes."
    case let .invalidText(name):
      "The native v3 \(name) is invalid."
    case let .invalidRevision(name):
      "The native v3 \(name) revision must be positive."
    case let .staleMembershipRevision(expected, actual):
      "Expected a membership revision greater than \(expected), received \(actual)."
    case let .staleSourceRevision(participantID, expected, actual):
      "Expected source revision greater than \(expected) for \(participantID), received \(actual)."
    case let .stalePeerLinkRevision(peerLinkKey, expected, actual):
      "Expected peer-link revision greater than \(expected) for \(peerLinkKey), received \(actual)."
    case let .invalidBinaryValue(name, expectedBytes):
      "The native v3 \(name) must contain exactly \(expectedBytes) bytes."
    case .invalidPeerLinkContext:
      "The native v3 peer-link message does not match its asserted participant pair."
    case let .unknownControlMessageType(type):
      "The native v3 control message type '\(type)' is unsupported."
    case let .staleRoomAdmissionPolicyRevision(expected, actual):
      "Expected a room-admission-policy revision greater than \(expected), received \(actual)."
    case let .staleRoomTerminationRevision(expected, actual):
      "Expected a room-termination revision greater than \(expected), received \(actual)."
    case .selfPeerLink:
      "A native v3 peer link requires two different participants."
    case let .participantLimit(maximum, actual):
      "The native v3 mesh allows at most \(maximum) participants; received \(actual)."
    case .duplicateParticipant:
      "The native v3 membership contains a duplicate participant."
    case .duplicateIdentity:
      "The native v3 membership assigns one identity to multiple participants."
    case .duplicateSource:
      "The native v3 source snapshot contains a duplicate source."
    case let .unknownParticipant(participantID):
      "The native v3 mesh does not contain participant \(participantID)."
    case let .participantIdentityChanged(participantID):
      "Native v3 participant \(participantID) cannot change identity within a room."
    case .invalidSourceOwnership:
      "A native v3 source may only be published by its owning participant."
    case .invalidTopology:
      "The native v3 peer topology is not a complete mesh."
    case .contextMismatch:
      "The native v3 value belongs to a different session or membership."
    case .identityMismatch:
      "The native v3 signing identity does not match the asserted identity."
    case .invalidSignature:
      "The native v3 signature is invalid."
    case .invalidLifetime:
      "The native v3 validity window is invalid."
    case .expired:
      "The native v3 value has expired."
    case .notYetValid:
      "The native v3 value is not valid yet."
    }
  }
}

/// A random, session-scoped participant identifier. It is intentionally not an
/// identity fingerprint, preventing the wire identifier from becoming a
/// cross-room tracking identifier. The encrypted server-room descriptor binds
/// it to the participant's persistent native identity for one room lifetime.
public struct ClipLiveShareNativeV3ParticipantID: Codable, Equatable, Hashable, Comparable,
  Sendable, CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareNativeV3.participantIDByteCount else {
      throw ClipLiveShareNativeV3Error.invalidParticipantID
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
    try! Self(
      bytes: nativeV3SecureRandomData(
        count: ClipLiveShareNativeV3.participantIDByteCount
      )
    )
  }

  public var rawValue: String { ClipLiveShareBase64URL.encode(bytes) }
  public var description: String { rawValue }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Globally identifies one published source inside the room. Source instance
/// identifiers are only unique within their owner, so the owner must always be
/// part of maps, messages, and UI identity.
public struct ClipLiveShareNativeV3SourceKey: Codable, Equatable, Hashable, Comparable, Sendable {
  public let ownerParticipantID: ClipLiveShareNativeV3ParticipantID
  public let sourceInstanceID: ClipLiveShareSourceInstanceID

  public init(
    ownerParticipantID: ClipLiveShareNativeV3ParticipantID,
    sourceInstanceID: ClipLiveShareSourceInstanceID
  ) {
    self.ownerParticipantID = ownerParticipantID
    self.sourceInstanceID = sourceInstanceID
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.ownerParticipantID != rhs.ownerParticipantID {
      return lhs.ownerParticipantID < rhs.ownerParticipantID
    }
    return lhs.sourceInstanceID.bytes.lexicographicallyPrecedes(rhs.sourceInstanceID.bytes)
  }

  private enum CodingKeys: String, CodingKey {
    case ownerParticipantID = "ownerParticipantId"
    case sourceInstanceID = "sourceInstanceId"
  }
}

/// Canonical unordered identity for one peer connection. Ordering the
/// endpoints means every participant independently derives the same key.
public struct ClipLiveShareNativeV3PeerLinkKey: Codable, Equatable, Hashable, Comparable, Sendable {
  public let lowerParticipantID: ClipLiveShareNativeV3ParticipantID
  public let upperParticipantID: ClipLiveShareNativeV3ParticipantID

  public init(
    _ first: ClipLiveShareNativeV3ParticipantID,
    _ second: ClipLiveShareNativeV3ParticipantID
  ) throws {
    guard first != second else { throw ClipLiveShareNativeV3Error.selfPeerLink }
    if first < second {
      lowerParticipantID = first
      upperParticipantID = second
    } else {
      lowerParticipantID = second
      upperParticipantID = first
    }
  }

  public var participantIDs: Set<ClipLiveShareNativeV3ParticipantID> {
    [lowerParticipantID, upperParticipantID]
  }

  public func contains(_ participantID: ClipLiveShareNativeV3ParticipantID) -> Bool {
    lowerParticipantID == participantID || upperParticipantID == participantID
  }

  public func otherParticipant(
    than participantID: ClipLiveShareNativeV3ParticipantID
  ) -> ClipLiveShareNativeV3ParticipantID? {
    if lowerParticipantID == participantID { return upperParticipantID }
    if upperParticipantID == participantID { return lowerParticipantID }
    return nil
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.lowerParticipantID != rhs.lowerParticipantID {
      return lhs.lowerParticipantID < rhs.lowerParticipantID
    }
    return lhs.upperParticipantID < rhs.upperParticipantID
  }

  private enum CodingKeys: String, CodingKey {
    case lowerParticipantID = "lowerParticipantId"
    case upperParticipantID = "upperParticipantId"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      container.decode(ClipLiveShareNativeV3ParticipantID.self, forKey: .lowerParticipantID),
      container.decode(ClipLiveShareNativeV3ParticipantID.self, forKey: .upperParticipantID)
    )
  }
}

/// Randomly identifies one concrete WebRTC transport attempt for a participant
/// pair. A negotiation revision prevents stale ordering while this nonce keeps
/// proofs and ICE from being transplanted to a different transport created at
/// the same revision in another process.
public struct ClipLiveShareNativeV3TransportNonce: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareNativeV3.transportNonceByteCount else {
      throw ClipLiveShareNativeV3Error.invalidBinaryValue(
        name: "transport nonce",
        expectedBytes: ClipLiveShareNativeV3.transportNonceByteCount
      )
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
    try! Self(
      bytes: nativeV3SecureRandomData(
        count: ClipLiveShareNativeV3.transportNonceByteCount
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

public struct ClipLiveShareNativeV3MembershipRevision: Codable, Equatable, Hashable, Comparable,
  Sendable
{
  public let rawValue: UInt64

  public init(rawValue: UInt64) throws {
    guard rawValue > 0 else {
      throw ClipLiveShareNativeV3Error.invalidRevision(name: "membership")
    }
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(UInt64.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ClipLiveShareNativeV3SourceRevision: Codable, Equatable, Hashable, Comparable,
  Sendable
{
  public let rawValue: UInt64

  public init(rawValue: UInt64) throws {
    guard rawValue > 0 else {
      throw ClipLiveShareNativeV3Error.invalidRevision(name: "source")
    }
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(UInt64.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ClipLiveShareNativeV3PeerLinkRevision: Codable, Equatable, Hashable, Comparable,
  Sendable
{
  public let rawValue: UInt64

  public init(rawValue: UInt64) throws {
    guard rawValue > 0 else {
      throw ClipLiveShareNativeV3Error.invalidRevision(name: "peer-link negotiation")
    }
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(UInt64.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Sorted-key JSON support for foundation tests and future envelope assembly.
///
/// This is deliberately module-internal and is not the native-v3 wire
/// boundary. Runtime integration must expose a closed, versioned v3 envelope
/// so unrelated values cannot be encoded through a generic public API.
enum ClipLiveShareNativeV3FoundationJSONCodec {
  static func encode<T: Encodable>(
    _ value: T,
    maximumBytes: Int = ClipLiveShareNativeV3.maximumControlMessageBytes
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try validateSize(data, maximumBytes: maximumBytes)
    return data
  }

  static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    maximumBytes: Int = ClipLiveShareNativeV3.maximumControlMessageBytes
  ) throws -> T {
    try validateSize(data, maximumBytes: maximumBytes)
    return try JSONDecoder().decode(type, from: data)
  }

  private static func validateSize(_ data: Data, maximumBytes: Int) throws {
    guard maximumBytes > 0 else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 message size limit must be positive"
      )
    }
    guard data.count <= maximumBytes else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum: maximumBytes,
        actual: data.count
      )
    }
  }
}

struct ClipLiveShareNativeV3CanonicalEncoder {
  private(set) var data = Data()

  init(domain: String) {
    append(domain)
    append(UInt64(ClipLiveShareNativeV3.version))
  }

  mutating func append(_ value: String) {
    append(Data(value.utf8))
  }

  mutating func append(_ value: Data) {
    precondition(value.count <= Int(UInt32.max))
    append(UInt32(value.count))
    data.append(value)
  }

  mutating func append(_ value: Bool) {
    data.append(value ? 1 : 0)
  }

  mutating func append(_ value: UInt32) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }

  mutating func append(_ value: UInt64) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }

  mutating func append(_ value: Int64) {
    append(UInt64(bitPattern: value))
  }
}

func nativeV3SecureRandomData(count: Int) -> Data {
  var generator = SystemRandomNumberGenerator()
  return Data(
    (0..<count).map { _ in
      UInt8.random(in: .min ... .max, using: &generator)
    }
  )
}

func validateNativeV3Lifetime(
  issuedAt: ClipLiveShareNativeTimestamp,
  expiresAt: ClipLiveShareNativeTimestamp,
  maximumMilliseconds: Int64
) throws {
  let (maximumExpiry, overflow) = issuedAt.millisecondsSince1970.addingReportingOverflow(
    maximumMilliseconds
  )
  guard
    !overflow,
    expiresAt > issuedAt,
    expiresAt.millisecondsSince1970 <= maximumExpiry
  else {
    throw ClipLiveShareNativeV3Error.invalidLifetime
  }
}

func validateNativeV3ValidityWindow(
  issuedAt: ClipLiveShareNativeTimestamp,
  expiresAt: ClipLiveShareNativeTimestamp,
  now: ClipLiveShareNativeTimestamp
) throws {
  let (latestAllowed, overflow) = now.millisecondsSince1970.addingReportingOverflow(
    ClipLiveShareNativeV3.maximumClockSkewMilliseconds
  )
  guard overflow || issuedAt.millisecondsSince1970 <= latestAllowed else {
    throw ClipLiveShareNativeV3Error.notYetValid
  }
  guard now < expiresAt else { throw ClipLiveShareNativeV3Error.expired }
}

func validateNativeV3Text(
  _ value: String,
  name: String,
  maximumUTF8Bytes: Int,
  allowsEmpty: Bool = false
) throws {
  let count = value.utf8.count
  guard count <= maximumUTF8Bytes, allowsEmpty || count > 0 else {
    throw ClipLiveShareNativeV3Error.invalidText(name: name)
  }
}
