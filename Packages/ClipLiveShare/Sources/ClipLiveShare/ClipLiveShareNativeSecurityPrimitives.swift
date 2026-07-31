import CryptoKit
import Foundation

private enum ClipLiveShareNativeSecurityLimits {
  static let identityPublicKeyByteCount = 65
  static let identitySignatureByteCount = 64
  static let fingerprintByteCount = 32
  static let sourceInstanceIDByteCount = 16
  static let digestByteCount = 32
}

public struct ClipLiveShareIdentityFingerprint: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareNativeSecurityLimits.fingerprintByteCount else {
      throw ClipLiveShareNativeV3Error.invalidBinaryValue(
        name: "identity fingerprint",
        expectedBytes: ClipLiveShareNativeSecurityLimits.fingerprintByteCount
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
      x963Representation.count
        == ClipLiveShareNativeSecurityLimits.identityPublicKeyByteCount,
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
      rawRepresentation.count
        == ClipLiveShareNativeSecurityLimits.identitySignatureByteCount,
      (try? P256.Signing.ECDSASignature(rawRepresentation: rawRepresentation)) != nil
    else {
      throw ClipLiveShareNativeV3Error.invalidBinaryValue(
        name: "P-256 identity signature",
        expectedBytes:
          ClipLiveShareNativeSecurityLimits.identitySignatureByteCount
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

public struct ClipLiveShareSourceInstanceID: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count
      == ClipLiveShareNativeSecurityLimits.sourceInstanceIDByteCount
    else {
      throw ClipLiveShareNativeV3Error.invalidBinaryValue(
        name: "source instance identifier",
        expectedBytes:
          ClipLiveShareNativeSecurityLimits.sourceInstanceIDByteCount
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
        count: ClipLiveShareNativeSecurityLimits.sourceInstanceIDByteCount
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

public struct ClipLiveShareNativeDigest: Codable, Equatable, Hashable, Sendable {
  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareNativeSecurityLimits.digestByteCount else {
      throw ClipLiveShareNativeV3Error.invalidBinaryValue(
        name: "native protocol digest",
        expectedBytes: ClipLiveShareNativeSecurityLimits.digestByteCount
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
      throw ClipLiveShareNativeV3Error.invalidLifetime
    }
    self.millisecondsSince1970 = millisecondsSince1970
  }

  public init(date: Date) throws {
    let milliseconds = date.timeIntervalSince1970 * 1_000
    guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= Double(Int64.max) else {
      throw ClipLiveShareNativeV3Error.invalidLifetime
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
    guard !overflow else { throw ClipLiveShareNativeV3Error.invalidLifetime }
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
