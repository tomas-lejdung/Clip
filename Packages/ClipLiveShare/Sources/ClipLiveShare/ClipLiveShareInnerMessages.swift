import Foundation

public struct ClipLiveShareAuthChallenge: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let challenge: Data
  public let accessCodeRequired: Bool

  public init(
    sessionID: ClipLiveShareSessionID,
    challenge: Data,
    accessCodeRequired: Bool
  ) throws {
    guard challenge.count == ClipLiveShareV1.challengeByteCount else {
      throw ClipLiveShareProtocolError.invalidResource("auth challenge must contain 32 bytes")
    }
    self.sessionID = sessionID
    self.challenge = challenge
    self.accessCodeRequired = accessCodeRequired
  }

  public static func random(
    sessionID: ClipLiveShareSessionID,
    accessCodeRequired: Bool
  ) -> Self {
    var generator = SystemRandomNumberGenerator()
    let challenge = Data(
      (0..<ClipLiveShareV1.challengeByteCount).map { _ in
        UInt8.random(in: .min ... .max, using: &generator)
      }
    )
    return try! Self(
      sessionID: sessionID,
      challenge: challenge,
      accessCodeRequired: accessCodeRequired
    )
  }
}

public struct ClipLiveShareAuthResponse: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let proof: Data?

  public init(sessionID: ClipLiveShareSessionID, proof: Data?) throws {
    guard proof == nil || proof?.count == 32 else {
      throw ClipLiveShareProtocolError.invalidAccessCodeProof
    }
    self.sessionID = sessionID
    self.proof = proof
  }
}

public struct ClipLiveShareAuthResult: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let allowed: Bool
  public let reason: String?

  public init(sessionID: ClipLiveShareSessionID, allowed: Bool, reason: String? = nil) throws {
    try ClipLiveShareMessageValidation.validateOptionalText(reason, field: "auth reason", maximum: 512)
    self.sessionID = sessionID
    self.allowed = allowed
    self.reason = reason
  }
}

public struct ClipLiveShareSessionDescription: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let negotiationID: ClipLiveShareNegotiationID
  public let sdp: String

  public init(
    sessionID: ClipLiveShareSessionID,
    negotiationID: ClipLiveShareNegotiationID,
    sdp: String
  ) throws {
    try ClipLiveShareMessageValidation.validateText(
      sdp,
      field: "session description",
      maximum: 190_000
    )
    self.sessionID = sessionID
    self.negotiationID = negotiationID
    self.sdp = sdp
  }
}

public struct ClipLiveShareICECandidate: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let negotiationID: ClipLiveShareNegotiationID
  public let candidate: String
  public let sdpMid: String?
  public let sdpMLineIndex: Int

  public init(
    sessionID: ClipLiveShareSessionID,
    negotiationID: ClipLiveShareNegotiationID,
    candidate: String,
    sdpMid: String? = nil,
    sdpMLineIndex: Int
  ) throws {
    guard candidate.utf8.count <= 16_384 else {
      throw ClipLiveShareProtocolError.invalidResource("ICE candidate is too large")
    }
    try ClipLiveShareMessageValidation.validateOptionalText(
      sdpMid,
      field: "SDP mid",
      maximum: 256
    )
    guard (0...1_024).contains(sdpMLineIndex) else {
      throw ClipLiveShareProtocolError.invalidResource("invalid SDP m-line index")
    }
    self.sessionID = sessionID
    self.negotiationID = negotiationID
    self.candidate = candidate
    self.sdpMid = sdpMid
    self.sdpMLineIndex = sdpMLineIndex
  }
}

public struct ClipLiveShareStreamDescriptor: Codable, Equatable, Hashable, Sendable {
  public let id: ClipLiveShareStreamID
  public let mediaTrackID: ClipLiveShareMediaTrackID
  public let active: Bool
  public let focused: Bool
  public let appName: String
  public let windowName: String
  public let width: Int
  public let height: Int
  public let order: Int

  public init(
    id: ClipLiveShareStreamID,
    mediaTrackID: ClipLiveShareMediaTrackID,
    active: Bool,
    focused: Bool,
    appName: String,
    windowName: String,
    width: Int,
    height: Int,
    order: Int
  ) throws {
    try ClipLiveShareMessageValidation.validateBoundedText(
      appName,
      field: "application name",
      maximum: 512
    )
    try ClipLiveShareMessageValidation.validateBoundedText(
      windowName,
      field: "window name",
      maximum: 1_024
    )
    guard (1...32_768).contains(width), (1...32_768).contains(height) else {
      throw ClipLiveShareProtocolError.invalidResource("stream dimensions are out of bounds")
    }
    guard (0...65_535).contains(order) else {
      throw ClipLiveShareProtocolError.invalidResource("stream order is out of bounds")
    }
    guard !focused || active else {
      throw ClipLiveShareProtocolError.invalidResource("an inactive stream cannot be focused")
    }
    self.id = id
    self.mediaTrackID = mediaTrackID
    self.active = active
    self.focused = focused
    self.appName = appName
    self.windowName = windowName
    self.width = width
    self.height = height
    self.order = order
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case mediaTrackID = "mediaTrackId"
    case active
    case focused
    case appName
    case windowName
    case width
    case height
    case order
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(ClipLiveShareStreamID.self, forKey: .id),
      mediaTrackID: container.decode(ClipLiveShareMediaTrackID.self, forKey: .mediaTrackID),
      active: container.decode(Bool.self, forKey: .active),
      focused: container.decode(Bool.self, forKey: .focused),
      appName: container.decode(String.self, forKey: .appName),
      windowName: container.decode(String.self, forKey: .windowName),
      width: container.decode(Int.self, forKey: .width),
      height: container.decode(Int.self, forKey: .height),
      order: container.decode(Int.self, forKey: .order)
    )
  }
}

public struct ClipLiveShareStreamManifest: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let streams: [ClipLiveShareStreamDescriptor]

  public init(
    sessionID: ClipLiveShareSessionID,
    streams: [ClipLiveShareStreamDescriptor],
    maximumStreams: Int = 64
  ) throws {
    guard streams.count <= maximumStreams else {
      throw ClipLiveShareProtocolError.invalidResource("stream manifest exceeds its bound")
    }
    guard Set(streams.map(\.id)).count == streams.count else {
      throw ClipLiveShareProtocolError.invalidResource("stream manifest contains duplicate IDs")
    }
    guard Set(streams.map(\.mediaTrackID)).count == streams.count else {
      throw ClipLiveShareProtocolError.invalidResource("stream manifest contains duplicate media tracks")
    }
    guard Set(streams.map(\.order)).count == streams.count else {
      throw ClipLiveShareProtocolError.invalidResource("stream manifest contains duplicate order values")
    }
    guard streams.filter(\.focused).count <= 1 else {
      throw ClipLiveShareProtocolError.invalidResource("stream manifest has multiple focused streams")
    }
    self.sessionID = sessionID
    self.streams = streams
  }
}

public struct ClipLiveShareStreamState: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let streamID: ClipLiveShareStreamID
  public let active: Bool

  public init(sessionID: ClipLiveShareSessionID, streamID: ClipLiveShareStreamID, active: Bool) {
    self.sessionID = sessionID
    self.streamID = streamID
    self.active = active
  }
}

public struct ClipLiveShareFocus: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let streamID: ClipLiveShareStreamID?

  public init(sessionID: ClipLiveShareSessionID, streamID: ClipLiveShareStreamID?) {
    self.sessionID = sessionID
    self.streamID = streamID
  }
}

public struct ClipLiveShareGeometry: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let streamID: ClipLiveShareStreamID
  public let width: Int
  public let height: Int

  public init(
    sessionID: ClipLiveShareSessionID,
    streamID: ClipLiveShareStreamID,
    width: Int,
    height: Int
  ) throws {
    guard (1...32_768).contains(width), (1...32_768).contains(height) else {
      throw ClipLiveShareProtocolError.invalidResource("stream dimensions are out of bounds")
    }
    self.sessionID = sessionID
    self.streamID = streamID
    self.width = width
    self.height = height
  }
}

public struct ClipLiveShareCursor: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let streamID: ClipLiveShareStreamID
  /// Horizontal position as a percentage in the closed range 0...100.
  public let x: Double
  /// Vertical position as a percentage in the closed range 0...100.
  public let y: Double
  public let inView: Bool

  public init(
    sessionID: ClipLiveShareSessionID,
    streamID: ClipLiveShareStreamID,
    x: Double,
    y: Double,
    inView: Bool
  ) throws {
    guard x.isFinite, y.isFinite, (0...100).contains(x), (0...100).contains(y) else {
      throw ClipLiveShareProtocolError.invalidResource("cursor percentages are out of bounds")
    }
    self.sessionID = sessionID
    self.streamID = streamID
    self.x = x
    self.y = y
    self.inView = inView
  }
}

public struct ClipLiveShareSharingState: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let sharing: Bool

  public init(sessionID: ClipLiveShareSessionID, sharing: Bool) {
    self.sessionID = sessionID
    self.sharing = sharing
  }
}

/// Authoritative availability for the pre-negotiated system-audio sender.
///
/// The Opus track exists for the lifetime of a peer so audio can be toggled
/// without renegotiation. Track existence therefore cannot tell a viewer
/// whether Clip is actively capturing and sending audio.
public struct ClipLiveShareSystemAudioState: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let enabled: Bool

  public init(sessionID: ClipLiveShareSessionID, enabled: Bool) {
    self.sessionID = sessionID
    self.enabled = enabled
  }
}

public struct ClipLiveShareSessionClosing: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let reason: String?

  public init(sessionID: ClipLiveShareSessionID, reason: String? = nil) throws {
    try ClipLiveShareMessageValidation.validateOptionalText(reason, field: "closing reason", maximum: 512)
    self.sessionID = sessionID
    self.reason = reason
  }
}

public struct ClipLiveShareInnerProtocolFailure: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let failure: ClipLiveShareProtocolFailure

  public init(sessionID: ClipLiveShareSessionID, failure: ClipLiveShareProtocolFailure) {
    self.sessionID = sessionID
    self.failure = failure
  }
}

public enum ClipLiveShareInnerMessage: Equatable, Hashable, Sendable {
  case authChallenge(ClipLiveShareAuthChallenge)
  case authResponse(ClipLiveShareAuthResponse)
  case authResult(ClipLiveShareAuthResult)
  case offer(ClipLiveShareSessionDescription)
  case answer(ClipLiveShareSessionDescription)
  case ice(ClipLiveShareICECandidate)
  case manifest(ClipLiveShareStreamManifest)
  case streamState(ClipLiveShareStreamState)
  case focus(ClipLiveShareFocus)
  case geometry(ClipLiveShareGeometry)
  case cursor(ClipLiveShareCursor)
  case sharingState(ClipLiveShareSharingState)
  case systemAudioState(ClipLiveShareSystemAudioState)
  case codecOffer(ClipLiveShareSessionDescription)
  case codecAnswer(ClipLiveShareSessionDescription)
  case codecICE(ClipLiveShareICECandidate)
  case sessionClosing(ClipLiveShareSessionClosing)
  case error(ClipLiveShareInnerProtocolFailure)

  public var type: String {
    switch self {
    case .authChallenge: "auth-challenge"
    case .authResponse: "auth-response"
    case .authResult: "auth-result"
    case .offer: "offer"
    case .answer: "answer"
    case .ice: "ice"
    case .manifest: "manifest"
    case .streamState: "stream-state"
    case .focus: "focus"
    case .geometry: "geometry"
    case .cursor: "cursor"
    case .sharingState: "sharing-state"
    case .systemAudioState: "system-audio-state"
    case .codecOffer: "codec-offer"
    case .codecAnswer: "codec-answer"
    case .codecICE: "codec-ice"
    case .sessionClosing: "session-closing"
    case .error: "error"
    }
  }

  public var sessionID: ClipLiveShareSessionID {
    switch self {
    case let .authChallenge(value): value.sessionID
    case let .authResponse(value): value.sessionID
    case let .authResult(value): value.sessionID
    case let .offer(value), let .answer(value), let .codecOffer(value), let .codecAnswer(value):
      value.sessionID
    case let .ice(value), let .codecICE(value): value.sessionID
    case let .manifest(value): value.sessionID
    case let .streamState(value): value.sessionID
    case let .focus(value): value.sessionID
    case let .geometry(value): value.sessionID
    case let .cursor(value): value.sessionID
    case let .sharingState(value): value.sessionID
    case let .systemAudioState(value): value.sessionID
    case let .sessionClosing(value): value.sessionID
    case let .error(value): value.sessionID
    }
  }
}

extension ClipLiveShareInnerMessage: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case version
    case sessionID = "sessionId"
    case challenge
    case accessCodeRequired
    case proof
    case allowed
    case reason
    case negotiationID = "negotiationId"
    case sdp
    case candidate
    case sdpMid
    case sdpMLineIndex
    case streams
    case streamID = "streamId"
    case active
    case width
    case height
    case x
    case y
    case inView
    case sharing
    case enabled
    case code
    case message
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ClipLiveShareV1.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    let type = try container.decode(String.self, forKey: .type)
    let sessionID = try container.decode(ClipLiveShareSessionID.self, forKey: .sessionID)

    switch type {
    case "auth-challenge":
      self = .authChallenge(
        try ClipLiveShareAuthChallenge(
          sessionID: sessionID,
          challenge: Self.decodeBase64URL(container, forKey: .challenge),
          accessCodeRequired: container.decode(Bool.self, forKey: .accessCodeRequired)
        )
      )
    case "auth-response":
      self = .authResponse(
        try ClipLiveShareAuthResponse(
          sessionID: sessionID,
          proof: Self.decodeOptionalBase64URL(container, forKey: .proof)
        )
      )
    case "auth-result":
      self = .authResult(
        try ClipLiveShareAuthResult(
          sessionID: sessionID,
          allowed: container.decode(Bool.self, forKey: .allowed),
          reason: container.decodeIfPresent(String.self, forKey: .reason)
        )
      )
    case "offer":
      self = .offer(try Self.decodeDescription(container, sessionID: sessionID))
    case "answer":
      self = .answer(try Self.decodeDescription(container, sessionID: sessionID))
    case "ice":
      self = .ice(try Self.decodeCandidate(container, sessionID: sessionID))
    case "manifest":
      self = .manifest(
        try ClipLiveShareStreamManifest(
          sessionID: sessionID,
          streams: container.decode([ClipLiveShareStreamDescriptor].self, forKey: .streams)
        )
      )
    case "stream-state":
      self = .streamState(
        ClipLiveShareStreamState(
          sessionID: sessionID,
          streamID: try container.decode(ClipLiveShareStreamID.self, forKey: .streamID),
          active: try container.decode(Bool.self, forKey: .active)
        )
      )
    case "focus":
      self = .focus(
        ClipLiveShareFocus(
          sessionID: sessionID,
          streamID: try container.decodeIfPresent(ClipLiveShareStreamID.self, forKey: .streamID)
        )
      )
    case "geometry":
      self = .geometry(
        try ClipLiveShareGeometry(
          sessionID: sessionID,
          streamID: container.decode(ClipLiveShareStreamID.self, forKey: .streamID),
          width: container.decode(Int.self, forKey: .width),
          height: container.decode(Int.self, forKey: .height)
        )
      )
    case "cursor":
      self = .cursor(
        try ClipLiveShareCursor(
          sessionID: sessionID,
          streamID: container.decode(ClipLiveShareStreamID.self, forKey: .streamID),
          x: container.decode(Double.self, forKey: .x),
          y: container.decode(Double.self, forKey: .y),
          inView: container.decode(Bool.self, forKey: .inView)
        )
      )
    case "sharing-state":
      self = .sharingState(
        ClipLiveShareSharingState(
          sessionID: sessionID,
          sharing: try container.decode(Bool.self, forKey: .sharing)
        )
      )
    case "system-audio-state":
      self = .systemAudioState(
        ClipLiveShareSystemAudioState(
          sessionID: sessionID,
          enabled: try container.decode(Bool.self, forKey: .enabled)
        )
      )
    case "codec-offer":
      self = .codecOffer(try Self.decodeDescription(container, sessionID: sessionID))
    case "codec-answer":
      self = .codecAnswer(try Self.decodeDescription(container, sessionID: sessionID))
    case "codec-ice":
      self = .codecICE(try Self.decodeCandidate(container, sessionID: sessionID))
    case "session-closing":
      self = .sessionClosing(
        try ClipLiveShareSessionClosing(
          sessionID: sessionID,
          reason: container.decodeIfPresent(String.self, forKey: .reason)
        )
      )
    case "error":
      self = .error(
        ClipLiveShareInnerProtocolFailure(
          sessionID: sessionID,
          failure: try ClipLiveShareProtocolFailure(
            code: container.decode(String.self, forKey: .code),
            message: container.decode(String.self, forKey: .message)
          )
        )
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown Clip Live Share inner message type: \(type)"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encode(ClipLiveShareV1.version, forKey: .version)
    try container.encode(sessionID, forKey: .sessionID)

    switch self {
    case let .authChallenge(value):
      try container.encode(ClipLiveShareBase64URL.encode(value.challenge), forKey: .challenge)
      try container.encode(value.accessCodeRequired, forKey: .accessCodeRequired)
    case let .authResponse(value):
      if let proof = value.proof {
        try container.encode(ClipLiveShareBase64URL.encode(proof), forKey: .proof)
      }
    case let .authResult(value):
      try container.encode(value.allowed, forKey: .allowed)
      try container.encodeIfPresent(value.reason, forKey: .reason)
    case let .offer(value), let .answer(value), let .codecOffer(value), let .codecAnswer(value):
      try Self.encodeDescription(value, into: &container)
    case let .ice(value), let .codecICE(value):
      try Self.encodeCandidate(value, into: &container)
    case let .manifest(value):
      try container.encode(value.streams, forKey: .streams)
    case let .streamState(value):
      try container.encode(value.streamID, forKey: .streamID)
      try container.encode(value.active, forKey: .active)
    case let .focus(value):
      if let streamID = value.streamID {
        try container.encode(streamID, forKey: .streamID)
      } else {
        try container.encodeNil(forKey: .streamID)
      }
    case let .geometry(value):
      try container.encode(value.streamID, forKey: .streamID)
      try container.encode(value.width, forKey: .width)
      try container.encode(value.height, forKey: .height)
    case let .cursor(value):
      try container.encode(value.streamID, forKey: .streamID)
      try container.encode(value.x, forKey: .x)
      try container.encode(value.y, forKey: .y)
      try container.encode(value.inView, forKey: .inView)
    case let .sharingState(value):
      try container.encode(value.sharing, forKey: .sharing)
    case let .systemAudioState(value):
      try container.encode(value.enabled, forKey: .enabled)
    case let .sessionClosing(value):
      try container.encodeIfPresent(value.reason, forKey: .reason)
    case let .error(value):
      try container.encode(value.failure.code, forKey: .code)
      try container.encode(value.failure.message, forKey: .message)
    }
  }

  private static func decodeDescription(
    _ container: KeyedDecodingContainer<CodingKeys>,
    sessionID: ClipLiveShareSessionID
  ) throws -> ClipLiveShareSessionDescription {
    try ClipLiveShareSessionDescription(
      sessionID: sessionID,
      negotiationID: container.decode(ClipLiveShareNegotiationID.self, forKey: .negotiationID),
      sdp: container.decode(String.self, forKey: .sdp)
    )
  }

  private static func encodeDescription(
    _ value: ClipLiveShareSessionDescription,
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    try container.encode(value.negotiationID, forKey: .negotiationID)
    try container.encode(value.sdp, forKey: .sdp)
  }

  private static func decodeCandidate(
    _ container: KeyedDecodingContainer<CodingKeys>,
    sessionID: ClipLiveShareSessionID
  ) throws -> ClipLiveShareICECandidate {
    try ClipLiveShareICECandidate(
      sessionID: sessionID,
      negotiationID: container.decode(ClipLiveShareNegotiationID.self, forKey: .negotiationID),
      candidate: container.decode(String.self, forKey: .candidate),
      sdpMid: container.decodeIfPresent(String.self, forKey: .sdpMid),
      sdpMLineIndex: container.decode(Int.self, forKey: .sdpMLineIndex)
    )
  }

  private static func encodeCandidate(
    _ value: ClipLiveShareICECandidate,
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    try container.encode(value.negotiationID, forKey: .negotiationID)
    try container.encode(value.candidate, forKey: .candidate)
    try container.encodeIfPresent(value.sdpMid, forKey: .sdpMid)
    try container.encode(value.sdpMLineIndex, forKey: .sdpMLineIndex)
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

  private static func decodeOptionalBase64URL(
    _ container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> Data? {
    guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
    return try decodeBase64URL(container, forKey: key)
  }
}

extension ClipLiveShareMessageValidation {
  static func validateBoundedText(_ value: String, field: String, maximum: Int) throws {
    guard value.utf8.count <= maximum else {
      throw ClipLiveShareProtocolError.invalidResource(
        "\(field) exceeds \(maximum) UTF-8 bytes"
      )
    }
  }
}
