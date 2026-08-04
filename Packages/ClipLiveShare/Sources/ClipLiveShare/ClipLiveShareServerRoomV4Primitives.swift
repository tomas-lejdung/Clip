import CryptoKit
import Foundation

/// Clean-slate protocol primitives for the server-coordinated native mesh.
///
/// The service owns only opaque routing state. Participant identity, room
/// metadata, admission material, signaling, and media remain end-to-end
/// protected between Clip clients.
public enum ClipLiveShareServerRoomV4 {
  public static let version = 4
  public static let protocolIdentifier = "clip-native-room"
  /// Canonical browser-compatible invite fields. These names deliberately
  /// match Clip's original secure app/web link grammar; the v4 values and
  /// cryptography are clean-slate and carry no v1/v2 compatibility behavior.
  public static let inviteFragmentKey = "v"
  public static let invitePayloadFragmentKey = "key"
  public static let inviteAdmissionFragmentKey = "join"
  public static let roomCodeLength = 8

  public static let maximumParticipants = 4
  public static let maximumWireMessageBytes = 262_144
  public static let maximumOpaqueDescriptorBytes = 16 * 1_024
  public static let maximumOpaqueAdmissionBytes = 16 * 1_024
  public static let maximumOpaqueKnockBytes = 16 * 1_024
  public static let maximumPairSignalCiphertextBytes = 196_000
  public static let maximumPairSignalPlaintextBytes = 72 * 1_024
  public static let maximumSDPBytes = 64 * 1_024
  public static let maximumICECandidateBytes = 4 * 1_024
  public static let maximumDisplayNameBytes = 160
  public static let maximumProtocolErrorBytes = 256

  static let roomIDByteCount = 32
  static let memberHandleByteCount = 16
  static let candidateHandleByteCount = 16
  static let secretByteCount = 32
  static let pairIDByteCount = 32
  static let nonceByteCount = 12
  static let authenticationTagByteCount = 16
}

/// Human-readable, presentation-only path component of one v4 invitation.
///
/// This is intentionally distinct from the 256-bit opaque API room ID. The
/// room service routes only by the latter after a client opens the encrypted
/// fragment payload; knowing or enumerating this short code grants no room
/// access and does not reveal which opaque API room it names.
public struct ClipLiveShareServerRoomV4RoomCode: Codable, Equatable, Hashable,
  Comparable, Sendable, CustomStringConvertible
{
  private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
  private static let unbiasedByteLimit = UInt8((256 / alphabet.count) * alphabet.count)

  public let rawValue: String

  public init(rawValue: String) throws {
    let normalized = rawValue.uppercased(with: Locale(identifier: "en_US_POSIX"))
    let bytes = Array(normalized.utf8)
    guard
      bytes.count == ClipLiveShareServerRoomV4.roomCodeLength,
      bytes.allSatisfy({ Self.alphabet.contains($0) })
    else {
      throw ClipLiveShareServerRoomV4Error.invalidIdentifier("room code")
    }
    self.rawValue = normalized
  }

  public static func random() -> Self {
    var result = [UInt8]()
    result.reserveCapacity(ClipLiveShareServerRoomV4.roomCodeLength)
    while result.count < ClipLiveShareServerRoomV4.roomCodeLength {
      for byte in serverRoomV4SecureRandomData(count: 16)
      where byte < unbiasedByteLimit {
        result.append(alphabet[Int(byte) % alphabet.count])
        if result.count == ClipLiveShareServerRoomV4.roomCodeLength { break }
      }
    }
    return try! Self(rawValue: String(decoding: result, as: UTF8.self))
  }

  public var description: String { rawValue }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
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

public enum ClipLiveShareServerRoomV4Error: Error, Equatable, Sendable,
  LocalizedError
{
  case invalidEndpoint
  case invalidInvite
  case invalidIdentifier(String)
  case invalidSecret(String)
  case invalidRevision(String)
  case invalidRoster(String)
  case invalidPairContext
  case selfPair
  case notPairMember
  case invalidOpaqueValue(String)
  case invalidWireMessage(String)
  case unknownWireMessage(String)
  case invalidSignalingMessage(String)
  case invalidSignature
  case sequenceExhausted

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "The server-room endpoint is invalid."
    case .invalidInvite:
      "The server-room invitation is invalid."
    case .invalidIdentifier(let name):
      "The server-room \(name) is invalid."
    case .invalidSecret(let name):
      "The server-room \(name) is invalid."
    case .invalidRevision(let name):
      "The server-room \(name) must be nonzero."
    case .invalidRoster(let reason):
      "The server-room roster is invalid: \(reason)"
    case .invalidPairContext:
      "The server-room pair context is invalid."
    case .selfPair:
      "A server-room peer pair requires two different members."
    case .notPairMember:
      "The local member does not belong to the asserted pair."
    case .invalidOpaqueValue(let name):
      "The opaque server-room \(name) is invalid."
    case .invalidWireMessage(let reason):
      "The server-room wire message is invalid: \(reason)"
    case .unknownWireMessage(let type):
      "The server-room wire message type '\(type)' is unsupported."
    case .invalidSignalingMessage(let reason):
      "The server-room pair signal is invalid: \(reason)"
    case .invalidSignature:
      "The server-room signature is invalid."
    case .sequenceExhausted:
      "The server-room signaling sequence is exhausted."
    }
  }
}

private protocol ClipLiveShareServerRoomV4FixedIdentifier {
  static var byteCount: Int { get }
  static var name: String { get }
  var bytes: Data { get }
  init(validatedBytes: Data)
}

extension ClipLiveShareServerRoomV4FixedIdentifier {
  fileprivate static func validate(_ bytes: Data) throws -> Self {
    guard bytes.count == byteCount else {
      throw ClipLiveShareServerRoomV4Error.invalidIdentifier(name)
    }
    return Self(validatedBytes: bytes)
  }

  fileprivate static func decode(_ rawValue: String) throws -> Self {
    guard let bytes = ClipLiveShareBase64URL.decode(rawValue) else {
      throw ClipLiveShareServerRoomV4Error.invalidIdentifier(name)
    }
    return try validate(bytes)
  }
}

public struct ClipLiveShareServerRoomV4RoomID: Codable, Equatable, Hashable,
  Comparable, Sendable, CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    self = try Self.validate(bytes)
  }

  public init(rawValue: String) throws {
    self = try Self.decode(rawValue)
  }

  public static func random() -> Self {
    try! Self(bytes: serverRoomV4SecureRandomData(count: Self.byteCount))
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

extension ClipLiveShareServerRoomV4RoomID:
  ClipLiveShareServerRoomV4FixedIdentifier
{
  fileprivate static let byteCount = ClipLiveShareServerRoomV4.roomIDByteCount
  fileprivate static let name = "room identifier"
  fileprivate init(validatedBytes: Data) { bytes = validatedBytes }
}

public struct ClipLiveShareServerRoomV4MemberHandle: Codable, Equatable,
  Hashable, Comparable, Sendable, CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws { self = try Self.validate(bytes) }
  public init(rawValue: String) throws { self = try Self.decode(rawValue) }
  public static func random() -> Self {
    try! Self(bytes: serverRoomV4SecureRandomData(count: Self.byteCount))
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

extension ClipLiveShareServerRoomV4MemberHandle:
  ClipLiveShareServerRoomV4FixedIdentifier
{
  fileprivate static let byteCount = ClipLiveShareServerRoomV4.memberHandleByteCount
  fileprivate static let name = "member handle"
  fileprivate init(validatedBytes: Data) { bytes = validatedBytes }
}

public struct ClipLiveShareServerRoomV4CandidateHandle: Codable, Equatable,
  Hashable, Comparable, Sendable, CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws { self = try Self.validate(bytes) }
  public init(rawValue: String) throws { self = try Self.decode(rawValue) }
  public static func random() -> Self {
    try! Self(bytes: serverRoomV4SecureRandomData(count: Self.byteCount))
  }
  public var rawValue: String { ClipLiveShareBase64URL.encode(bytes) }
  /// The room service promotes this exact routing handle on admission.
  public var admittedMemberHandle: ClipLiveShareServerRoomV4MemberHandle {
    try! .init(bytes: bytes)
  }
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

extension ClipLiveShareServerRoomV4CandidateHandle:
  ClipLiveShareServerRoomV4FixedIdentifier
{
  fileprivate static let byteCount = ClipLiveShareServerRoomV4.candidateHandleByteCount
  fileprivate static let name = "candidate handle"
  fileprivate init(validatedBytes: Data) { bytes = validatedBytes }
}

public struct ClipLiveShareServerRoomV4PairID: Codable, Equatable, Hashable,
  Comparable, Sendable, CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws { self = try Self.validate(bytes) }
  public init(rawValue: String) throws { self = try Self.decode(rawValue) }
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

extension ClipLiveShareServerRoomV4PairID:
  ClipLiveShareServerRoomV4FixedIdentifier
{
  fileprivate static let byteCount = ClipLiveShareServerRoomV4.pairIDByteCount
  fileprivate static let name = "pair identifier"
  fileprivate init(validatedBytes: Data) { bytes = validatedBytes }
}

protocol ClipLiveShareServerRoomV4SecretValue {
  static var name: String { get }
  var keyMaterial: Data { get }
  init(validatedKeyMaterial: Data)
}

extension ClipLiveShareServerRoomV4SecretValue {
  fileprivate static func validate(_ bytes: Data) throws -> Self {
    guard bytes.count == ClipLiveShareServerRoomV4.secretByteCount else {
      throw ClipLiveShareServerRoomV4Error.invalidSecret(name)
    }
    return Self(validatedKeyMaterial: bytes)
  }

  fileprivate static func decode(_ rawValue: String) throws -> Self {
    guard let bytes = ClipLiveShareBase64URL.decode(rawValue) else {
      throw ClipLiveShareServerRoomV4Error.invalidSecret(name)
    }
    return try validate(bytes)
  }
}

public struct ClipLiveShareServerRoomV4AdmissionCapability: Codable, Equatable,
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  let keyMaterial: Data
  public init(bytes: Data) throws { self = try Self.validate(bytes) }
  public init(rawValue: String) throws { self = try Self.decode(rawValue) }
  public static func random() -> Self {
    try! Self(bytes: serverRoomV4SecureRandomData(count: ClipLiveShareServerRoomV4.secretByteCount))
  }
  public var rawValue: String { ClipLiveShareBase64URL.encode(keyMaterial) }
  public var description: String { "<redacted admission capability>" }
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

extension ClipLiveShareServerRoomV4AdmissionCapability:
  ClipLiveShareServerRoomV4SecretValue
{
  static let name = "admission capability"
  init(validatedKeyMaterial: Data) { keyMaterial = validatedKeyMaterial }
}

public struct ClipLiveShareServerRoomV4RoomAgreementSecret: Codable, Equatable,
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  let keyMaterial: Data
  public init(bytes: Data) throws { self = try Self.validate(bytes) }
  public init(rawValue: String) throws { self = try Self.decode(rawValue) }
  public static func random() -> Self {
    try! Self(bytes: serverRoomV4SecureRandomData(count: ClipLiveShareServerRoomV4.secretByteCount))
  }
  public var rawValue: String { ClipLiveShareBase64URL.encode(keyMaterial) }
  public var description: String { "<redacted room agreement secret>" }
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

extension ClipLiveShareServerRoomV4RoomAgreementSecret:
  ClipLiveShareServerRoomV4SecretValue
{
  static let name = "room agreement secret"
  init(validatedKeyMaterial: Data) { keyMaterial = validatedKeyMaterial }
}

public struct ClipLiveShareServerRoomV4OwnerCapability: Codable, Equatable,
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  let keyMaterial: Data
  public init(bytes: Data) throws { self = try Self.validate(bytes) }
  public init(rawValue: String) throws { self = try Self.decode(rawValue) }
  public static func random() -> Self {
    try! Self(bytes: serverRoomV4SecureRandomData(count: ClipLiveShareServerRoomV4.secretByteCount))
  }
  public var rawValue: String { ClipLiveShareBase64URL.encode(keyMaterial) }
  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: keyMaterial)
  }
  public var description: String { "<redacted owner capability>" }
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

extension ClipLiveShareServerRoomV4OwnerCapability:
  ClipLiveShareServerRoomV4SecretValue
{
  static let name = "owner capability"
  init(validatedKeyMaterial: Data) { keyMaterial = validatedKeyMaterial }
}

public struct ClipLiveShareServerRoomV4ReconnectCapability: Codable, Equatable,
  Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  let keyMaterial: Data
  public init(bytes: Data) throws { self = try Self.validate(bytes) }
  public init(rawValue: String) throws { self = try Self.decode(rawValue) }
  public static func random() -> Self {
    try! Self(bytes: serverRoomV4SecureRandomData(count: ClipLiveShareServerRoomV4.secretByteCount))
  }
  public var rawValue: String { ClipLiveShareBase64URL.encode(keyMaterial) }
  public var digest: ClipLiveShareNativeDigest {
    ClipLiveShareNativeDigest(hashing: keyMaterial)
  }
  public var description: String { "<redacted reconnect capability>" }
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

extension ClipLiveShareServerRoomV4ReconnectCapability:
  ClipLiveShareServerRoomV4SecretValue
{
  static let name = "reconnect capability"
  init(validatedKeyMaterial: Data) { keyMaterial = validatedKeyMaterial }
}

public struct ClipLiveShareServerRoomV4RosterRevision: Codable, Equatable,
  Hashable, Comparable, Sendable
{
  public let rawValue: UInt64
  public init(rawValue: UInt64) throws {
    guard rawValue > 0 else {
      throw ClipLiveShareServerRoomV4Error.invalidRevision("roster revision")
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

public struct ClipLiveShareServerRoomV4PairEpoch: Codable, Equatable, Hashable,
  Comparable, Sendable
{
  public let rawValue: UInt64
  public init(rawValue: UInt64) throws {
    guard rawValue > 0 else {
      throw ClipLiveShareServerRoomV4Error.invalidRevision("pair negotiation epoch")
    }
    self.rawValue = rawValue
  }
  public func next() throws -> Self {
    guard rawValue < UInt64.max else {
      throw ClipLiveShareServerRoomV4Error.sequenceExhausted
    }
    return try Self(rawValue: rawValue + 1)
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

public struct ClipLiveShareServerRoomV4OpaqueValue: Codable, Equatable,
  Hashable, Sendable
{
  public let bytes: Data

  public init(bytes: Data, name: String, maximumBytes: Int) throws {
    guard maximumBytes > 0, !bytes.isEmpty, bytes.count <= maximumBytes else {
      throw ClipLiveShareServerRoomV4Error.invalidOpaqueValue(name)
    }
    self.bytes = bytes
  }

  public var rawValue: String { ClipLiveShareBase64URL.encode(bytes) }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    guard let bytes = ClipLiveShareBase64URL.decode(rawValue), !bytes.isEmpty else {
      throw ClipLiveShareServerRoomV4Error.invalidOpaqueValue("value")
    }
    self.bytes = bytes
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ClipLiveShareServerRoomV4KeyAgreementIdentity: Sendable {
  let privateKey: P256.KeyAgreement.PrivateKey

  public init() { privateKey = P256.KeyAgreement.PrivateKey() }
  init(rawRepresentation: Data) throws {
    privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
  }
  public var publicKey: ClipLiveShareKeyAgreementPublicKey {
    try! ClipLiveShareKeyAgreementPublicKey(
      x963Representation: privateKey.publicKey.x963Representation
    )
  }
}

struct ClipLiveShareServerRoomV4CanonicalEncoder {
  private(set) var data = Data()

  init(domain: String) {
    append(domain)
    append(UInt64(ClipLiveShareServerRoomV4.version))
  }

  mutating func append(_ value: String) { append(Data(value.utf8)) }
  mutating func append(_ value: Data) {
    precondition(value.count <= Int(UInt32.max))
    append(UInt32(value.count))
    data.append(value)
  }
  mutating func append(_ value: Bool) { data.append(value ? 1 : 0) }
  mutating func append(_ value: UInt32) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  }
  mutating func append(_ value: UInt64) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  }
}

func serverRoomV4SecureRandomData(count: Int) -> Data {
  var generator = SystemRandomNumberGenerator()
  return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}
