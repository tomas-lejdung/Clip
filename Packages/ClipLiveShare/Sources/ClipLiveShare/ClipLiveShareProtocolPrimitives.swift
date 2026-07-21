import CryptoKit
import Foundation

public enum ClipLiveShareV1 {
  public static let protocolIdentifier = "clip-live-share"
  public static let version = 1
  public static let controlDataChannelLabel = "clip-control-v1"

  public static let maximumWebSocketMessageBytes = 262_144
  /// Leaves sufficient base64url and JSON envelope headroom inside the 262,144-byte frame bound.
  public static let maximumInnerMessageBytes = 196_400
  public static let maximumICECandidatesPerPeerAndDirection = 256
  public static let maximumPendingRoutesPerRoom = 8
  public static let maximumConnectedViewers = 8
  public static let initialAnswerTimeoutSeconds = 15

  public static let ownerTokenByteCount = 32
  public static let routeIDByteCount = 16
  public static let challengeByteCount = 32
  public static let nonceByteCount = 12
  public static let publicKeyByteCount = 65
}

public enum ClipLiveShareProtocolError: Error, Equatable, Sendable {
  case invalidRoomName(String)
  case invalidOwnerToken
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
    case let .invalidRoomName(value):
      "Invalid Clip Live Share room name: \(value)"
    case .invalidOwnerToken:
      "The room owner token must contain exactly 32 random bytes."
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
      "An access code is required."
    case .invalidAccessCodeProof:
      "The access-code proof is invalid."
    }
  }
}

public struct ClipLiveShareRoomName: Codable, Equatable, Hashable,
  Sendable, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) throws {
    let normalized = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased(with: Locale(identifier: "en_US_POSIX"))

    let bytes = Array(normalized.utf8)
    let validLength = (3...64).contains(bytes.count)
    let validCharacters = bytes.allSatisfy {
      (65...90).contains($0) || (48...57).contains($0) || $0 == 45
    }
    let hasInteriorHyphensOnly = bytes.first != 45 && bytes.last != 45

    guard validLength, validCharacters, hasInteriorHyphensOnly else {
      throw ClipLiveShareProtocolError.invalidRoomName(normalized)
    }
    self.rawValue = normalized
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

  public static func random() -> Self {
    var generator = SystemRandomNumberGenerator()
    return random(using: &generator)
  }

  public static func random<R: RandomNumberGenerator>(using generator: inout R) -> Self {
    let adjective = adjectives.randomElement(using: &generator) ?? "BRIGHT"
    let noun = nouns.randomElement(using: &generator) ?? "OTTER"
    let number = Int.random(in: 0...999, using: &generator)
    // All source words and the numeric suffix are valid by construction.
    return try! Self(rawValue: "\(adjective)-\(noun)-\(String(format: "%03d", number))")
  }

  private static let adjectives = [
    "AMBER", "BRAVE", "BRIGHT", "CALM", "CLEAR", "CORAL", "CRISP", "EAGER",
    "EMBER", "FAIR", "FROSTY", "GENTLE", "GOLDEN", "HAPPY", "JADE", "KEEN",
    "LIVELY", "LUCID", "MELLOW", "MINT", "NIMBLE", "NOBLE", "PLUM", "QUICK",
    "QUIET", "RAPID", "SILVER", "SOLAR", "SWIFT", "TIDY", "VIVID", "WARM",
  ]

  private static let nouns = [
    "BADGER", "BEAR", "BISON", "CEDAR", "COMET", "CRANE", "DOLPHIN", "FALCON",
    "FERN", "FINCH", "FOX", "GECKO", "HERON", "IBIS", "KOALA", "LARK",
    "LYNX", "MAPLE", "MARTEN", "MOON", "ORCA", "OTTER", "OWL", "PANDA",
    "PINE", "RAVEN", "ROBIN", "SEAL", "SPARROW", "TIGER", "WILLOW", "WREN",
  ]
}

public struct ClipLiveShareOwnerToken: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareV1.ownerTokenByteCount else {
      throw ClipLiveShareProtocolError.invalidOwnerToken
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
    try! Self(bytes: Data.random(count: ClipLiveShareV1.ownerTokenByteCount, using: &generator))
  }

  public var rawValue: String { ClipLiveShareBase64URL.encode(bytes) }
  public var sha256Digest: Data { Data(SHA256.hash(data: bytes)) }
  public var authorizationHeaderValue: String { "Bearer \(rawValue)" }
  public var description: String { "<redacted owner token>" }
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
      bytes.count == ClipLiveShareV1.routeIDByteCount
    else {
      throw ClipLiveShareProtocolError.invalidRouteID
    }
    self.rawValue = rawValue
  }

  public init(bytes: Data) throws {
    guard bytes.count == ClipLiveShareV1.routeIDByteCount else {
      throw ClipLiveShareProtocolError.invalidRouteID
    }
    self.rawValue = ClipLiveShareBase64URL.encode(bytes)
  }

  public static func random() -> Self {
    var generator = SystemRandomNumberGenerator()
    return random(using: &generator)
  }

  public static func random<R: RandomNumberGenerator>(using generator: inout R) -> Self {
    try! Self(bytes: Data.random(count: ClipLiveShareV1.routeIDByteCount, using: &generator))
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

public struct ClipLiveShareNegotiationID: Codable, Equatable, Hashable,
  Sendable, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) throws {
    try ClipLiveShareOpaqueIdentifier.validate(rawValue, name: "negotiation")
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
      x963Representation.count == ClipLiveShareV1.publicKeyByteCount,
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

public struct ClipLiveShareProtocolResourceLimits: Codable, Equatable, Hashable, Sendable {
  public var maximumWebSocketMessageBytes: Int
  public var maximumInnerMessageBytes: Int
  public var maximumICECandidatesPerPeerAndDirection: Int
  public var maximumPendingRoutesPerRoom: Int
  public var maximumConnectedViewers: Int
  public var initialAnswerTimeoutSeconds: Int
  public var maximumManifestStreams: Int

  public init(
    maximumWebSocketMessageBytes: Int = ClipLiveShareV1.maximumWebSocketMessageBytes,
    maximumInnerMessageBytes: Int = ClipLiveShareV1.maximumInnerMessageBytes,
    maximumICECandidatesPerPeerAndDirection: Int = ClipLiveShareV1.maximumICECandidatesPerPeerAndDirection,
    maximumPendingRoutesPerRoom: Int = ClipLiveShareV1.maximumPendingRoutesPerRoom,
    maximumConnectedViewers: Int = ClipLiveShareV1.maximumConnectedViewers,
    initialAnswerTimeoutSeconds: Int = ClipLiveShareV1.initialAnswerTimeoutSeconds,
    maximumManifestStreams: Int = 64
  ) throws {
    let positiveValues = [
      maximumWebSocketMessageBytes,
      maximumInnerMessageBytes,
      maximumICECandidatesPerPeerAndDirection,
      maximumPendingRoutesPerRoom,
      maximumConnectedViewers,
      initialAnswerTimeoutSeconds,
      maximumManifestStreams,
    ]
    guard positiveValues.allSatisfy({ $0 > 0 }) else {
      throw ClipLiveShareProtocolError.invalidResource("all resource limits must be positive")
    }
    guard maximumInnerMessageBytes <= maximumWebSocketMessageBytes else {
      throw ClipLiveShareProtocolError.invalidResource(
        "the inner-message limit cannot exceed the WebSocket-frame limit"
      )
    }

    self.maximumWebSocketMessageBytes = maximumWebSocketMessageBytes
    self.maximumInnerMessageBytes = maximumInnerMessageBytes
    self.maximumICECandidatesPerPeerAndDirection = maximumICECandidatesPerPeerAndDirection
    self.maximumPendingRoutesPerRoom = maximumPendingRoutesPerRoom
    self.maximumConnectedViewers = maximumConnectedViewers
    self.initialAnswerTimeoutSeconds = initialAnswerTimeoutSeconds
    self.maximumManifestStreams = maximumManifestStreams
  }

  public static let v1 = try! Self()
}

public struct ClipLiveShareCandidateBudget: Equatable, Hashable, Sendable {
  public let maximum: Int
  public private(set) var acceptedCount: Int

  public init(
    maximum: Int = ClipLiveShareV1.maximumICECandidatesPerPeerAndDirection,
    acceptedCount: Int = 0
  ) throws {
    guard maximum > 0, (0...maximum).contains(acceptedCount) else {
      throw ClipLiveShareProtocolError.invalidResource("invalid ICE candidate budget")
    }
    self.maximum = maximum
    self.acceptedCount = acceptedCount
  }

  public mutating func accept() throws {
    guard acceptedCount < maximum else {
      throw ClipLiveShareProtocolError.invalidResource("ICE candidate limit exceeded")
    }
    acceptedCount += 1
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
