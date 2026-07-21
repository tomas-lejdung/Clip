import Foundation

public struct ClipLiveShareViewerHello: Equatable, Hashable, Sendable {
  public let version: Int
  public let viewerKey: ClipLiveShareKeyAgreementPublicKey

  public init(version: Int = ClipLiveShareV1.version, viewerKey: ClipLiveShareKeyAgreementPublicKey) throws {
    guard version == ClipLiveShareV1.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    self.version = version
    self.viewerKey = viewerKey
  }
}

public struct ClipLiveShareRouteOpened: Equatable, Hashable, Sendable {
  public let routeID: ClipLiveShareRouteID
  /// Present on the host copy and omitted on the viewer copy of `route-opened`.
  public let viewerKey: ClipLiveShareKeyAgreementPublicKey?

  public init(
    routeID: ClipLiveShareRouteID,
    viewerKey: ClipLiveShareKeyAgreementPublicKey? = nil
  ) {
    self.routeID = routeID
    self.viewerKey = viewerKey
  }
}

public struct ClipLiveShareRelayEnvelope: Equatable, Hashable, Sendable {
  /// A viewer may omit this when sending to the server. Forwarded and host-sent relays include it.
  public let routeID: ClipLiveShareRouteID?
  public let sequence: UInt64
  public let nonce: Data
  /// AES-GCM ciphertext followed by the 16-byte authentication tag. The nonce is separate.
  public let ciphertext: Data

  public init(
    routeID: ClipLiveShareRouteID?,
    sequence: UInt64,
    nonce: Data,
    ciphertext: Data
  ) throws {
    guard sequence > 0 else {
      throw ClipLiveShareProtocolError.invalidResource("relay sequence must begin at one")
    }
    guard nonce.count == ClipLiveShareV1.nonceByteCount else {
      throw ClipLiveShareProtocolError.invalidNonceLength(nonce.count)
    }
    guard ciphertext.count >= 16 else {
      throw ClipLiveShareProtocolError.invalidResource("relay ciphertext is shorter than its tag")
    }
    let maximumCiphertextBytes = ClipLiveShareV1.maximumInnerMessageBytes + 16
    guard ciphertext.count <= maximumCiphertextBytes else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum: maximumCiphertextBytes,
        actual: ciphertext.count
      )
    }
    self.routeID = routeID
    self.sequence = sequence
    self.nonce = nonce
    self.ciphertext = ciphertext
  }
}

public struct ClipLiveShareRouteClosed: Equatable, Hashable, Sendable {
  public let routeID: ClipLiveShareRouteID
  public let reason: String?

  public init(routeID: ClipLiveShareRouteID, reason: String? = nil) throws {
    try ClipLiveShareMessageValidation.validateOptionalText(reason, field: "reason", maximum: 512)
    self.routeID = routeID
    self.reason = reason
  }
}

public struct ClipLiveShareProtocolFailure: Equatable, Hashable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) throws {
    try ClipLiveShareMessageValidation.validateText(code, field: "error code", maximum: 64)
    try ClipLiveShareMessageValidation.validateText(message, field: "error message", maximum: 256)
    guard code.utf8.allSatisfy({
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        || $0 == 45 || $0 == 95
    }) else {
      throw ClipLiveShareProtocolError.invalidResource("error code must be ASCII alphanumeric")
    }
    self.code = code
    self.message = message
  }
}

public enum ClipLiveShareOuterMessage: Equatable, Hashable, Sendable {
  case viewerHello(ClipLiveShareViewerHello)
  case routeOpened(ClipLiveShareRouteOpened)
  case relay(ClipLiveShareRelayEnvelope)
  case routeClosed(ClipLiveShareRouteClosed)
  case closeRoute(ClipLiveShareRouteID)
  case hostUnavailable
  case error(ClipLiveShareProtocolFailure)

  public var type: String {
    switch self {
    case .viewerHello: "viewer-hello"
    case .routeOpened: "route-opened"
    case .relay: "relay"
    case .routeClosed: "route-closed"
    case .closeRoute: "close-route"
    case .hostUnavailable: "host-unavailable"
    case .error: "error"
    }
  }
}

extension ClipLiveShareOuterMessage: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case version
    case viewerKey
    case routeID = "routeId"
    case sequence
    case nonce
    case ciphertext
    case reason
    case code
    case message
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "viewer-hello":
      self = .viewerHello(
        try ClipLiveShareViewerHello(
          version: container.decode(Int.self, forKey: .version),
          viewerKey: container.decode(ClipLiveShareKeyAgreementPublicKey.self, forKey: .viewerKey)
        )
      )
    case "route-opened":
      self = .routeOpened(
        ClipLiveShareRouteOpened(
          routeID: try container.decode(ClipLiveShareRouteID.self, forKey: .routeID),
          viewerKey: try container.decodeIfPresent(
            ClipLiveShareKeyAgreementPublicKey.self,
            forKey: .viewerKey
          )
        )
      )
    case "relay":
      let nonce = try Self.decodeBase64URL(container, forKey: .nonce)
      let ciphertext = try Self.decodeBase64URL(container, forKey: .ciphertext)
      self = .relay(
        try ClipLiveShareRelayEnvelope(
          routeID: container.decodeIfPresent(ClipLiveShareRouteID.self, forKey: .routeID),
          sequence: container.decode(UInt64.self, forKey: .sequence),
          nonce: nonce,
          ciphertext: ciphertext
        )
      )
    case "route-closed":
      self = .routeClosed(
        try ClipLiveShareRouteClosed(
          routeID: container.decode(ClipLiveShareRouteID.self, forKey: .routeID),
          reason: container.decodeIfPresent(String.self, forKey: .reason)
        )
      )
    case "close-route":
      self = .closeRoute(try container.decode(ClipLiveShareRouteID.self, forKey: .routeID))
    case "host-unavailable":
      self = .hostUnavailable
    case "error":
      self = .error(
        try ClipLiveShareProtocolFailure(
          code: container.decode(String.self, forKey: .code),
          message: container.decode(String.self, forKey: .message)
        )
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown Clip Live Share outer message type: \(type)"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    switch self {
    case let .viewerHello(message):
      try container.encode(message.version, forKey: .version)
      try container.encode(message.viewerKey, forKey: .viewerKey)
    case let .routeOpened(message):
      try container.encode(message.routeID, forKey: .routeID)
      try container.encodeIfPresent(message.viewerKey, forKey: .viewerKey)
    case let .relay(message):
      try container.encodeIfPresent(message.routeID, forKey: .routeID)
      try container.encode(message.sequence, forKey: .sequence)
      try container.encode(ClipLiveShareBase64URL.encode(message.nonce), forKey: .nonce)
      try container.encode(ClipLiveShareBase64URL.encode(message.ciphertext), forKey: .ciphertext)
    case let .routeClosed(message):
      try container.encode(message.routeID, forKey: .routeID)
      try container.encodeIfPresent(message.reason, forKey: .reason)
    case let .closeRoute(routeID):
      try container.encode(routeID, forKey: .routeID)
    case .hostUnavailable:
      break
    case let .error(error):
      try container.encode(error.code, forKey: .code)
      try container.encode(error.message, forKey: .message)
    }
  }

  private static func decodeBase64URL(
    _ container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> Data {
    let value = try container.decode(String.self, forKey: key)
    guard let data = ClipLiveShareBase64URL.decode(value) else {
      throw DecodingError.dataCorruptedError(
        forKey: key,
        in: container,
        debugDescription: "Expected canonical unpadded base64url."
      )
    }
    return data
  }
}

enum ClipLiveShareMessageValidation {
  static func validateText(_ value: String, field: String, maximum: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximum else {
      throw ClipLiveShareProtocolError.invalidResource(
        "\(field) must contain 1...\(maximum) UTF-8 bytes"
      )
    }
  }

  static func validateOptionalText(_ value: String?, field: String, maximum: Int) throws {
    guard let value else { return }
    try validateText(value, field: field, maximum: maximum)
  }
}

public enum ClipLiveShareMessageCodec {
  public static func encodeOuter(
    _ message: ClipLiveShareOuterMessage,
    maximumBytes: Int = ClipLiveShareV1.maximumWebSocketMessageBytes
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(message)
    try validateSize(data, maximum: maximumBytes)
    return data
  }

  public static func decodeOuter(
    _ data: Data,
    maximumBytes: Int = ClipLiveShareV1.maximumWebSocketMessageBytes
  ) throws -> ClipLiveShareOuterMessage {
    try validateSize(data, maximum: maximumBytes)
    return try JSONDecoder().decode(ClipLiveShareOuterMessage.self, from: data)
  }

  public static func encodeInner(
    _ message: ClipLiveShareInnerMessage,
    maximumBytes: Int = ClipLiveShareV1.maximumInnerMessageBytes
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(message)
    try validateSize(data, maximum: maximumBytes)
    return data
  }

  public static func decodeInner(
    _ data: Data,
    maximumBytes: Int = ClipLiveShareV1.maximumInnerMessageBytes
  ) throws -> ClipLiveShareInnerMessage {
    try validateSize(data, maximum: maximumBytes)
    return try JSONDecoder().decode(ClipLiveShareInnerMessage.self, from: data)
  }

  private static func validateSize(_ data: Data, maximum: Int) throws {
    guard maximum > 0 else {
      throw ClipLiveShareProtocolError.invalidResource("message size limit must be positive")
    }
    guard data.count <= maximum else {
      throw ClipLiveShareProtocolError.messageTooLarge(maximum: maximum, actual: data.count)
    }
  }
}
