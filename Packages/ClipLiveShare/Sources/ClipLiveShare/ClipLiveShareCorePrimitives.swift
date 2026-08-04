import CryptoKit
import Foundation

enum ClipLiveShareCoreLimits {
  static let admissionCapabilityByteCount = 32
  static let routeIDByteCount = 16
  static let publicKeyByteCount = 65
}

enum ClipLiveShareMessageValidation {
  static func validateText(
    _ value: String,
    field: String,
    maximum: Int
  ) throws {
    guard !value.isEmpty, value.utf8.count <= maximum else {
      throw ClipLiveShareProtocolError.invalidResource(
        "\(field) must contain 1...\(maximum) UTF-8 bytes"
      )
    }
  }

  static func validateOptionalText(
    _ value: String?,
    field: String,
    maximum: Int
  ) throws {
    guard let value else { return }
    try validateText(value, field: field, maximum: maximum)
  }

  static func validateBoundedText(
    _ value: String,
    field: String,
    maximum: Int
  ) throws {
    guard value.utf8.count <= maximum else {
      throw ClipLiveShareProtocolError.invalidResource(
        "\(field) exceeds \(maximum) UTF-8 bytes"
      )
    }
  }
}

public enum ClipLiveShareProtocolError: Error, Equatable, Sendable {
  case invalidAdmissionCapability
  case invalidRouteID
  case invalidOpaqueIdentifier(String)
  case invalidPublicKey
  case invalidBase64URL
  case invalidEndpoint(String)
  case invalidPathTemplate(String)
  case invalidCapabilities(String)
  case invalidResource(String)
  case unsupportedVersion(Int)
  case messageTooLarge(maximum: Int, actual: Int)
  case routeMismatch(expected: ClipLiveShareRouteID, actual: ClipLiveShareRouteID?)
  case invalidSequence(expected: UInt64, actual: UInt64)
  case invalidNonceLength(Int)
  case authenticationFailed
  case accessCodeRequired
  case invalidAccessCodeProof
}

extension ClipLiveShareProtocolError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidAdmissionCapability:
      "The admission capability must contain exactly 32 random bytes."
    case .invalidRouteID:
      "The route identifier must contain exactly 16 random bytes."
    case let .invalidOpaqueIdentifier(name):
      "The \(name) identifier is invalid."
    case .invalidPublicKey:
      "The P-256 public key is not a valid X9.63 representation."
    case .invalidBase64URL:
      "The value is not canonical unpadded base64url."
    case let .invalidEndpoint(reason):
      "The Clip Live Share endpoint is invalid: \(reason)"
    case let .invalidPathTemplate(template):
      "The Clip Live Share path template is invalid: \(template)"
    case let .invalidCapabilities(reason):
      "The Clip Live Share capabilities are incompatible: \(reason)"
    case let .invalidResource(reason):
      "The Clip Live Share resource is invalid: \(reason)"
    case let .unsupportedVersion(version):
      "Clip Live Share protocol version \(version) is unsupported."
    case let .messageTooLarge(maximum, actual):
      "The message is \(actual) bytes; the maximum is \(maximum) bytes."
    case let .routeMismatch(expected, actual):
      "The encrypted envelope route does not match \(expected.rawValue); received \(actual?.rawValue ?? "none")."
    case let .invalidSequence(expected, actual):
      "Expected encrypted sequence \(expected), received \(actual)."
    case let .invalidNonceLength(length):
      "An AES-GCM nonce must contain 12 bytes; received \(length)."
    case .authenticationFailed:
      "The encrypted message failed authentication."
    case .accessCodeRequired:
      "An Access Word is required."
    case .invalidAccessCodeProof:
      "The access-code proof is invalid."
    }
  }
}

public struct ClipLiveShareNativeV3AdmissionCapability:
  Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let bytes: Data

  public init(bytes: Data) throws {
    guard
      bytes.count == ClipLiveShareCoreLimits.admissionCapabilityByteCount
    else {
      throw ClipLiveShareProtocolError.invalidAdmissionCapability
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
      bytes: Data.random(
        count: ClipLiveShareCoreLimits.admissionCapabilityByteCount,
        using: &generator
      )
    )
  }

  public var rawValue: String { ClipLiveShareBase64URL.encode(bytes) }
  var keyMaterial: Data { bytes }
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

public struct ClipLiveShareRouteID: Codable, Equatable, Hashable,
  Sendable, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) throws {
    guard
      let bytes = ClipLiveShareBase64URL.decode(rawValue),
      bytes.count == ClipLiveShareCoreLimits.routeIDByteCount
    else {
      throw ClipLiveShareProtocolError.invalidRouteID
    }
    self.rawValue = rawValue
  }

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareCoreLimits.routeIDByteCount else {
      throw ClipLiveShareProtocolError.invalidRouteID
    }
    self.rawValue = ClipLiveShareBase64URL.encode(bytes)
  }

  public static func random() -> Self {
    var generator = SystemRandomNumberGenerator()
    return random(using: &generator)
  }

  public static func random<R: RandomNumberGenerator>(using generator: inout R) -> Self {
    try! Self(
      bytes: Data.random(
        count: ClipLiveShareCoreLimits.routeIDByteCount,
        using: &generator
      )
    )
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var description: String { rawValue }
}

public struct ClipLiveShareSessionID: Codable, Equatable, Hashable,
  Sendable, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) throws {
    try ClipLiveShareOpaqueIdentifier.validate(rawValue, name: "session")
    self.rawValue = rawValue
  }

  public static func random() -> Self {
    try! Self(rawValue: ClipLiveShareBase64URL.encode(.secureRandom(count: 16)))
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var description: String { rawValue }
}

public struct ClipLiveShareStreamID: Codable, Equatable, Hashable,
  Sendable, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) throws {
    try ClipLiveShareOpaqueIdentifier.validate(rawValue, name: "stream")
    self.rawValue = rawValue
  }

  public static func random() -> Self {
    try! Self(rawValue: ClipLiveShareBase64URL.encode(.secureRandom(count: 16)))
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var description: String { rawValue }
}

public struct ClipLiveShareMediaTrackID: Codable, Equatable, Hashable,
  Sendable, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) throws {
    try ClipLiveShareOpaqueIdentifier.validate(rawValue, name: "media track")
    self.rawValue = rawValue
  }

  public static func random() -> Self {
    try! Self(rawValue: ClipLiveShareBase64URL.encode(.secureRandom(count: 16)))
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var description: String { rawValue }
}

public struct ClipLiveShareKeyAgreementPublicKey: Codable, Equatable, Hashable, Sendable {
  public let x963Representation: Data

  public init(x963Representation: Data) throws {
    guard
      x963Representation.count == ClipLiveShareCoreLimits.publicKeyByteCount,
      (try? P256.KeyAgreement.PublicKey(x963Representation: x963Representation)) != nil
    else {
      throw ClipLiveShareProtocolError.invalidPublicKey
    }
    self.x963Representation = x963Representation
  }

  public init(rawValue: String) throws {
    guard let data = ClipLiveShareBase64URL.decode(rawValue) else {
      throw ClipLiveShareProtocolError.invalidBase64URL
    }
    try self.init(x963Representation: data)
  }

  public var rawValue: String { ClipLiveShareBase64URL.encode(x963Representation) }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum ClipLiveShareBase64URL {
  public static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func decode(_ string: String) -> Data? {
    guard
      !string.isEmpty,
      string.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
          || $0 == 45 || $0 == 95
      })
    else {
      return nil
    }

    var base64 = string.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.utf8.count % 4
    guard remainder != 1 else { return nil }
    if remainder > 0 {
      base64.append(String(repeating: "=", count: 4 - remainder))
    }
    guard let data = Data(base64Encoded: base64) else { return nil }
    return encode(data) == string ? data : nil
  }
}

private enum ClipLiveShareOpaqueIdentifier {
  static func validate(_ value: String, name: String) throws {
    let bytes = Array(value.utf8)
    guard
      (1...128).contains(bytes.count),
      bytes.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
          || $0 == 45 || $0 == 95
      })
    else {
      throw ClipLiveShareProtocolError.invalidOpaqueIdentifier(name)
    }
  }
}

extension Data {
  fileprivate static func secureRandom(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return random(count: count, using: &generator)
  }

  fileprivate static func random<R: RandomNumberGenerator>(
    count: Int,
    using generator: inout R
  ) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
  }
}
