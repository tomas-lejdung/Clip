import CryptoKit
import Foundation

/// Native Clip-to-Clip protocol additions. The browser protocol remains v1.
public enum ClipLiveShareNativeV2 {
  public static let version = 2
  public static let protocolIdentifier = "clip-live-share-native"

  public static let identityPublicKeyByteCount = 65
  public static let identitySignatureByteCount = 64
  public static let fingerprintByteCount = 32
  public static let rendezvousIDByteCount = 32
  public static let sourceInstanceIDByteCount = 16
  public static let friendRequestIDByteCount = 16
  public static let revocationIDByteCount = 16
  public static let digestByteCount = 32
  public static let challengeByteCount = 32
  /// Clip exposes four concurrent host source slots. Native control decoding
  /// enforces that product contract for both snapshots and incremental state.
  public static let maximumConcurrentVideoSources = 4

  /// Session descriptors are intentionally short-lived even when a contact's
  /// rendezvous identifier is persistent.
  public static let maximumSessionDescriptorLifetimeMilliseconds: Int64 = 5 * 60 * 1_000
  public static let maximumChallengeLifetimeMilliseconds: Int64 = 60 * 1_000
  public static let maximumControlHelloLifetimeMilliseconds: Int64 = 60 * 1_000
  public static let maximumFriendRequestLifetimeMilliseconds: Int64 = 10 * 60 * 1_000
  /// Bounded tolerance for ordinary clock differences between two Macs. It
  /// applies only to future-issued timestamps; expiry remains strict.
  public static let maximumClockSkewMilliseconds: Int64 = 30 * 1_000
}

public enum ClipLiveShareNativeV2Error: Error, Equatable, Sendable {
  case invalidBinaryValue(name: String, expectedBytes: Int)
  case invalidTimestamp
  case invalidLifetime
  case invalidStateRevision
  case invalidText(name: String)
  case identityMismatch
  case invalidSignature
  case expired
  case notYetValid
  case contextMismatch
  case replayed
  case staleStateRevision(expectedGreaterThan: UInt64, actual: UInt64)
}

extension ClipLiveShareNativeV2Error: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .invalidBinaryValue(name, expectedBytes):
      "The \(name) must contain exactly \(expectedBytes) bytes."
    case .invalidTimestamp:
      "The native Live Share timestamp is invalid."
    case .invalidLifetime:
      "The native Live Share lifetime is invalid."
    case .invalidStateRevision:
      "The native Live Share state revision must be positive."
    case let .invalidText(name):
      "The native Live Share \(name) is invalid."
    case .identityMismatch:
      "The native Live Share identity does not match the expected contact."
    case .invalidSignature:
      "The native Live Share signature is invalid."
    case .expired:
      "The native Live Share resource has expired."
    case .notYetValid:
      "The native Live Share resource is not valid yet."
    case .contextMismatch:
      "The native Live Share proof belongs to a different context."
    case .replayed:
      "The native Live Share resource has already been accepted."
    case let .staleStateRevision(expected, actual):
      "Expected a state revision greater than \(expected), received \(actual)."
    }
  }
}

public struct ClipLiveShareIdentityFingerprint: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareNativeV2.fingerprintByteCount else {
      throw ClipLiveShareNativeV2Error.invalidBinaryValue(
        name: "identity fingerprint",
        expectedBytes: ClipLiveShareNativeV2.fingerprintByteCount
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

public struct ClipLiveShareIdentityPublicKey: Codable, Equatable, Hashable, Sendable {
  public let x963Representation: Data

  public init(x963Representation: Data) throws {
    guard
      x963Representation.count == ClipLiveShareNativeV2.identityPublicKeyByteCount,
      (try? P256.Signing.PublicKey(x963Representation: x963Representation)) != nil
    else {
      throw ClipLiveShareProtocolError.invalidPublicKey
    }
    self.x963Representation = x963Representation
  }

  public init(rawValue: String) throws {
    guard let bytes = ClipLiveShareBase64URL.decode(rawValue) else {
      throw ClipLiveShareProtocolError.invalidBase64URL
    }
    try self.init(x963Representation: bytes)
  }

  public var rawValue: String { ClipLiveShareBase64URL.encode(x963Representation) }

  public var fingerprint: ClipLiveShareIdentityFingerprint {
    try! ClipLiveShareIdentityFingerprint(
      bytes: Data(SHA256.hash(data: x963Representation))
    )
  }

  public func isValidSignature(
    _ signature: ClipLiveShareIdentitySignature,
    for canonicalRepresentation: Data
  ) -> Bool {
    guard
      let key = try? P256.Signing.PublicKey(x963Representation: x963Representation),
      let value = try? P256.Signing.ECDSASignature(
        rawRepresentation: signature.rawRepresentation
      )
    else {
      return false
    }
    return key.isValidSignature(value, for: canonicalRepresentation)
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

public struct ClipLiveShareIdentitySignature: Codable, Equatable, Hashable, Sendable {
  public let rawRepresentation: Data

  public init(rawRepresentation: Data) throws {
    guard
      rawRepresentation.count == ClipLiveShareNativeV2.identitySignatureByteCount,
      (try? P256.Signing.ECDSASignature(rawRepresentation: rawRepresentation)) != nil
    else {
      throw ClipLiveShareNativeV2Error.invalidBinaryValue(
        name: "P-256 identity signature",
        expectedBytes: ClipLiveShareNativeV2.identitySignatureByteCount
      )
    }
    self.rawRepresentation = rawRepresentation
  }

  public init(rawValue: String) throws {
    guard let bytes = ClipLiveShareBase64URL.decode(rawValue) else {
      throw ClipLiveShareProtocolError.invalidBase64URL
    }
    try self.init(rawRepresentation: bytes)
  }

  public var rawValue: String { ClipLiveShareBase64URL.encode(rawRepresentation) }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// An app-owned Keychain or Secure Enclave wrapper can conform without
/// exposing private key bytes to this package.
public protocol ClipLiveShareIdentitySigner: Sendable {
  var publicKey: ClipLiveShareIdentityPublicKey { get }
  func signature(for canonicalRepresentation: Data) throws -> ClipLiveShareIdentitySignature
}

/// In-memory implementation for tests and callers that manage persistence
/// themselves. Production persistence belongs in the app's Keychain layer.
public struct ClipLiveShareSoftwareIdentitySigner: ClipLiveShareIdentitySigner, Sendable {
  private let privateKey: P256.Signing.PrivateKey

  public init() {
    privateKey = P256.Signing.PrivateKey()
  }

  public init(rawRepresentation: Data) throws {
    privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
  }

  public var publicKey: ClipLiveShareIdentityPublicKey {
    try! ClipLiveShareIdentityPublicKey(
      x963Representation: privateKey.publicKey.x963Representation
    )
  }

  public func signature(
    for canonicalRepresentation: Data
  ) throws -> ClipLiveShareIdentitySignature {
    try ClipLiveShareIdentitySignature(
      rawRepresentation: privateKey.signature(for: canonicalRepresentation).rawRepresentation
    )
  }
}

public struct ClipLiveShareRendezvousID: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareNativeV2.rendezvousIDByteCount else {
      throw ClipLiveShareNativeV2Error.invalidBinaryValue(
        name: "rendezvous identifier",
        expectedBytes: ClipLiveShareNativeV2.rendezvousIDByteCount
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
    var generator = SystemRandomNumberGenerator()
    return random(using: &generator)
  }

  public static func random<R: RandomNumberGenerator>(using generator: inout R) -> Self {
    try! Self(
      bytes: Data(
        (0..<ClipLiveShareNativeV2.rendezvousIDByteCount).map { _ in
          UInt8.random(in: .min ... .max, using: &generator)
        }
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

public struct ClipLiveShareSourceInstanceID: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareNativeV2.sourceInstanceIDByteCount else {
      throw ClipLiveShareNativeV2Error.invalidBinaryValue(
        name: "source instance identifier",
        expectedBytes: ClipLiveShareNativeV2.sourceInstanceIDByteCount
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
      bytes: nativeV2SecureRandomData(count: ClipLiveShareNativeV2.sourceInstanceIDByteCount))
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

public struct ClipLiveShareFriendRequestID: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareNativeV2.friendRequestIDByteCount else {
      throw ClipLiveShareNativeV2Error.invalidBinaryValue(
        name: "friend request identifier",
        expectedBytes: ClipLiveShareNativeV2.friendRequestIDByteCount
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
      bytes: nativeV2SecureRandomData(count: ClipLiveShareNativeV2.friendRequestIDByteCount))
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

public struct ClipLiveShareRevocationID: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareNativeV2.revocationIDByteCount else {
      throw ClipLiveShareNativeV2Error.invalidBinaryValue(
        name: "revocation identifier",
        expectedBytes: ClipLiveShareNativeV2.revocationIDByteCount
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
    try! Self(bytes: nativeV2SecureRandomData(count: ClipLiveShareNativeV2.revocationIDByteCount))
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

public struct ClipLiveShareNativeDigest: Codable, Equatable, Hashable, Sendable {
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareNativeV2.digestByteCount else {
      throw ClipLiveShareNativeV2Error.invalidBinaryValue(
        name: "native protocol digest",
        expectedBytes: ClipLiveShareNativeV2.digestByteCount
      )
    }
    self.bytes = bytes
  }

  public init(hashing data: Data) {
    bytes = Data(SHA256.hash(data: data))
  }

  public init(rawValue: String) throws {
    guard let bytes = ClipLiveShareBase64URL.decode(rawValue) else {
      throw ClipLiveShareProtocolError.invalidBase64URL
    }
    try self.init(bytes: bytes)
  }

  public var rawValue: String { ClipLiveShareBase64URL.encode(bytes) }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct ClipLiveShareNativeTimestamp: Codable, Equatable, Hashable, Comparable, Sendable {
  public let millisecondsSince1970: Int64

  public init(millisecondsSince1970: Int64) throws {
    guard millisecondsSince1970 >= 0 else {
      throw ClipLiveShareNativeV2Error.invalidTimestamp
    }
    self.millisecondsSince1970 = millisecondsSince1970
  }

  public init(date: Date) throws {
    let milliseconds = date.timeIntervalSince1970 * 1_000
    guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= Double(Int64.max) else {
      throw ClipLiveShareNativeV2Error.invalidTimestamp
    }
    try self.init(millisecondsSince1970: Int64(milliseconds.rounded(.down)))
  }

  public var date: Date {
    Date(timeIntervalSince1970: Double(millisecondsSince1970) / 1_000)
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.millisecondsSince1970 < rhs.millisecondsSince1970
  }

  public func adding(milliseconds: Int64) throws -> Self {
    let (value, overflow) = millisecondsSince1970.addingReportingOverflow(milliseconds)
    guard !overflow else { throw ClipLiveShareNativeV2Error.invalidTimestamp }
    return try Self(millisecondsSince1970: value)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(millisecondsSince1970: container.decode(Int64.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(millisecondsSince1970)
  }
}

public struct ClipLiveShareStateRevision: Codable, Equatable, Hashable, Comparable, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) throws {
    guard rawValue > 0 else { throw ClipLiveShareNativeV2Error.invalidStateRevision }
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

/// Strictly monotonic admission for session and stream-state updates.
public struct ClipLiveShareStateRevisionGuard: Equatable, Sendable {
  public private(set) var latestAcceptedRevision: ClipLiveShareStateRevision?

  public init(latestAcceptedRevision: ClipLiveShareStateRevision? = nil) {
    self.latestAcceptedRevision = latestAcceptedRevision
  }

  public mutating func accept(_ revision: ClipLiveShareStateRevision) throws {
    if let latestAcceptedRevision, revision <= latestAcceptedRevision {
      throw ClipLiveShareNativeV2Error.staleStateRevision(
        expectedGreaterThan: latestAcceptedRevision.rawValue,
        actual: revision.rawValue
      )
    }
    latestAcceptedRevision = revision
  }
}

/// Stable sorted-key JSON for the v2 wire models. Signatures never depend on
/// JSON formatting; every signed value has a separate canonical binary form.
public enum ClipLiveShareNativeV2MessageCodec {
  public static func encode<T: Encodable>(
    _ value: T,
    maximumBytes: Int = ClipLiveShareV1.maximumInnerMessageBytes
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try validateSize(data, maximumBytes: maximumBytes)
    return data
  }

  public static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    maximumBytes: Int = ClipLiveShareV1.maximumInnerMessageBytes
  ) throws -> T {
    try validateSize(data, maximumBytes: maximumBytes)
    return try JSONDecoder().decode(type, from: data)
  }

  private static func validateSize(_ data: Data, maximumBytes: Int) throws {
    guard maximumBytes > 0 else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native message size limit must be positive"
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

struct ClipLiveShareNativeV2CanonicalEncoder {
  private(set) var data = Data()

  init(domain: String) {
    append(domain)
    append(UInt64(ClipLiveShareNativeV2.version))
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

func nativeV2SecureRandomData(count: Int) -> Data {
  var generator = SystemRandomNumberGenerator()
  return Data(
    (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  )
}

func validateNativeV2Lifetime(
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
    throw ClipLiveShareNativeV2Error.invalidLifetime
  }
}

func validateNativeV2ValidityWindow(
  issuedAt: ClipLiveShareNativeTimestamp,
  expiresAt: ClipLiveShareNativeTimestamp,
  now: ClipLiveShareNativeTimestamp
) throws {
  try validateNativeV2TimestampIsNotTooFarInFuture(issuedAt, relativeTo: now)
  guard now < expiresAt else { throw ClipLiveShareNativeV2Error.expired }
}

func validateNativeV2TimestampIsNotTooFarInFuture(
  _ timestamp: ClipLiveShareNativeTimestamp,
  relativeTo now: ClipLiveShareNativeTimestamp
) throws {
  let (latestAllowed, overflow) = now.millisecondsSince1970.addingReportingOverflow(
    ClipLiveShareNativeV2.maximumClockSkewMilliseconds
  )
  guard overflow || timestamp.millisecondsSince1970 <= latestAllowed else {
    throw ClipLiveShareNativeV2Error.notYetValid
  }
}

func nativeV2Timestamp(
  _ timestamp: ClipLiveShareNativeTimestamp,
  isNoEarlierThan reference: ClipLiveShareNativeTimestamp
) -> Bool {
  let (latestTolerated, overflow) = timestamp.millisecondsSince1970
    .addingReportingOverflow(ClipLiveShareNativeV2.maximumClockSkewMilliseconds)
  return overflow || latestTolerated >= reference.millisecondsSince1970
}

func validateNativeV2Text(
  _ value: String,
  name: String,
  maximumUTF8Bytes: Int,
  allowsEmpty: Bool = false
) throws {
  let count = value.utf8.count
  guard count <= maximumUTF8Bytes, allowsEmpty || count > 0 else {
    throw ClipLiveShareNativeV2Error.invalidText(name: name)
  }
}
