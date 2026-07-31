import Foundation

/// Hard wire and state limits for native-v3 collaboration traffic.
///
/// Pointer and ink messages share the authenticated, ordered pair DataChannel.
/// They deliberately remain small enough that drawing cannot starve membership,
/// source-state, or peer-link control messages.
public enum ClipLiveShareNativeV3CollaborationLimits {
  public static let maximumParticipantNameUTF8Bytes = 128
  public static let maximumPointsPerStrokeChunk = 128
  public static let maximumPointsPerStroke = 2_048
  public static let maximumActiveStrokesPerSource = 64
  public static let maximumActivePingsPerSource = 16
  public static let maximumStrokeLifetimeMilliseconds: Int64 = 60_000
  public static let maximumPingLifetimeMilliseconds: Int64 = 10_000
  public static let maximumFutureEventSkewMilliseconds: Int64 = 30_000
}

public enum ClipLiveShareNativeV3CollaborationError: Error, Equatable, Sendable {
  case unsupportedVersion(Int)
  case unknownMessageType(String)
  case invalidCoordinate
  case invalidSequence
  case invalidTimestamp
  case invalidLifetime
  case invalidColor
  case emptyPoints
  case pointLimit(maximum: Int, actual: Int)
  case strokeLimit(maximum: Int, actual: Int)
  case pingLimit(maximum: Int, actual: Int)
  case staleSequence(expectedGreaterThan: UInt64, actual: UInt64)
  case staleClearEpoch(expectedAtLeast: UInt64, actual: UInt64)
  case sourceMismatch
  case participantMismatch
  case unknownStroke
  case duplicateStroke
  case expired
}

extension ClipLiveShareNativeV3CollaborationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .unsupportedVersion(version):
      "Unsupported native-v3 collaboration version \(version)."
    case let .unknownMessageType(type):
      "Unsupported native-v3 collaboration message '\(type)'."
    case .invalidCoordinate:
      "Collaboration coordinates must be finite normalized source coordinates."
    case .invalidSequence:
      "Collaboration sequence numbers must be positive."
    case .invalidTimestamp:
      "The collaboration timestamp is invalid."
    case .invalidLifetime:
      "The collaboration event lifetime is invalid."
    case .invalidColor:
      "The collaboration color is invalid."
    case .emptyPoints:
      "A collaboration stroke chunk must contain at least one point."
    case let .pointLimit(maximum, actual):
      "A collaboration stroke allows at most \(maximum) points; received \(actual)."
    case let .strokeLimit(maximum, actual):
      "A source allows at most \(maximum) active strokes; received \(actual)."
    case let .pingLimit(maximum, actual):
      "A source allows at most \(maximum) active pings; received \(actual)."
    case let .staleSequence(expectedGreaterThan, actual):
      "Expected a collaboration sequence greater than \(expectedGreaterThan); received \(actual)."
    case let .staleClearEpoch(expectedAtLeast, actual):
      "Expected a clear epoch of at least \(expectedAtLeast); received \(actual)."
    case .sourceMismatch:
      "The collaboration event belongs to a different source."
    case .participantMismatch:
      "The collaboration event does not belong to its authenticated sender."
    case .unknownStroke:
      "The collaboration stroke is unknown or has already ended."
    case .duplicateStroke:
      "The collaboration stroke already exists."
    case .expired:
      "The collaboration event has expired."
    }
  }
}

/// Resolution-independent coordinates in the publisher's source pixel space.
///
/// A receiver maps these values through the exact video content rect after
/// Fit/Native/Follow cropping. This keeps annotations stable across Retina,
/// non-Retina, fullscreen, and independently resized viewer windows.
public struct ClipLiveShareNativeV3NormalizedPoint: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) throws {
    guard
      x.isFinite,
      y.isFinite,
      (0...1).contains(x),
      (0...1).contains(y)
    else {
      throw ClipLiveShareNativeV3CollaborationError.invalidCoordinate
    }
    self.x = x
    self.y = y
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      x: container.decode(Double.self, forKey: .x),
      y: container.decode(Double.self, forKey: .y)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case x
    case y
  }
}

public struct ClipLiveShareNativeV3CollaborationColor:
  Codable, Equatable, Hashable, Sendable
{
  public let red: UInt8
  public let green: UInt8
  public let blue: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8) throws {
    guard red > 15 || green > 15 || blue > 15 else {
      throw ClipLiveShareNativeV3CollaborationError.invalidColor
    }
    self.red = red
    self.green = green
    self.blue = blue
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      red: container.decode(UInt8.self, forKey: .red),
      green: container.decode(UInt8.self, forKey: .green),
      blue: container.decode(UInt8.self, forKey: .blue)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case red
    case green
    case blue
  }
}

public struct ClipLiveShareNativeV3StrokeID:
  Codable, Equatable, Hashable, Comparable, Sendable, CustomStringConvertible
{
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue.uuidString.lowercased() }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.description < rhs.description
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let value = UUID(uuidString: try container.decode(String.self)) else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native v3 collaboration stroke identifier is invalid"
      )
    }
    self.init(rawValue: value)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}

/// Context carried by every collaboration message. `participantID` is still
/// checked against the identity authenticated by the peer link; it is never
/// trusted merely because the payload contains it.
public struct ClipLiveShareNativeV3CollaborationContext:
  Codable, Equatable, Hashable, Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let sourceKey: ClipLiveShareNativeV3SourceKey
  public let sequence: UInt64
  public let sentAt: ClipLiveShareNativeTimestamp

  public init(
    sessionID: ClipLiveShareSessionID,
    participantID: ClipLiveShareNativeV3ParticipantID,
    sourceKey: ClipLiveShareNativeV3SourceKey,
    sequence: UInt64,
    sentAt: ClipLiveShareNativeTimestamp
  ) throws {
    guard sequence > 0 else {
      throw ClipLiveShareNativeV3CollaborationError.invalidSequence
    }
    self.sessionID = sessionID
    self.participantID = participantID
    self.sourceKey = sourceKey
    self.sequence = sequence
    self.sentAt = sentAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      sessionID: container.decode(ClipLiveShareSessionID.self, forKey: .sessionID),
      participantID: container.decode(
        ClipLiveShareNativeV3ParticipantID.self,
        forKey: .participantID
      ),
      sourceKey: container.decode(
        ClipLiveShareNativeV3SourceKey.self,
        forKey: .sourceKey
      ),
      sequence: container.decode(UInt64.self, forKey: .sequence),
      sentAt: container.decode(ClipLiveShareNativeTimestamp.self, forKey: .sentAt)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case participantID = "participantId"
    case sourceKey
    case sequence
    case sentAt
  }
}

public struct ClipLiveShareNativeV3PointerEvent:
  Codable, Equatable, Hashable, Sendable
{
  public let context: ClipLiveShareNativeV3CollaborationContext
  public let position: ClipLiveShareNativeV3NormalizedPoint?

  public init(
    context: ClipLiveShareNativeV3CollaborationContext,
    position: ClipLiveShareNativeV3NormalizedPoint?
  ) {
    self.context = context
    self.position = position
  }
}

public struct ClipLiveShareNativeV3PingEvent:
  Codable, Equatable, Hashable, Sendable
{
  public let context: ClipLiveShareNativeV3CollaborationContext
  public let position: ClipLiveShareNativeV3NormalizedPoint
  public let color: ClipLiveShareNativeV3CollaborationColor
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    context: ClipLiveShareNativeV3CollaborationContext,
    position: ClipLiveShareNativeV3NormalizedPoint,
    color: ClipLiveShareNativeV3CollaborationColor,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    try validateCollaborationLifetime(
      sentAt: context.sentAt,
      expiresAt: expiresAt,
      maximumMilliseconds:
        ClipLiveShareNativeV3CollaborationLimits.maximumPingLifetimeMilliseconds
    )
    self.context = context
    self.position = position
    self.color = color
    self.expiresAt = expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      context: container.decode(
        ClipLiveShareNativeV3CollaborationContext.self,
        forKey: .context
      ),
      position: container.decode(
        ClipLiveShareNativeV3NormalizedPoint.self,
        forKey: .position
      ),
      color: container.decode(
        ClipLiveShareNativeV3CollaborationColor.self,
        forKey: .color
      ),
      expiresAt: container.decode(
        ClipLiveShareNativeTimestamp.self,
        forKey: .expiresAt
      )
    )
  }

  private enum CodingKeys: String, CodingKey {
    case context
    case position
    case color
    case expiresAt
  }
}

public struct ClipLiveShareNativeV3StrokeBeginEvent:
  Codable, Equatable, Hashable, Sendable
{
  public let context: ClipLiveShareNativeV3CollaborationContext
  public let strokeID: ClipLiveShareNativeV3StrokeID
  public let point: ClipLiveShareNativeV3NormalizedPoint
  public let color: ClipLiveShareNativeV3CollaborationColor
  public let expiresAt: ClipLiveShareNativeTimestamp

  public init(
    context: ClipLiveShareNativeV3CollaborationContext,
    strokeID: ClipLiveShareNativeV3StrokeID,
    point: ClipLiveShareNativeV3NormalizedPoint,
    color: ClipLiveShareNativeV3CollaborationColor,
    expiresAt: ClipLiveShareNativeTimestamp
  ) throws {
    try validateCollaborationLifetime(
      sentAt: context.sentAt,
      expiresAt: expiresAt,
      maximumMilliseconds:
        ClipLiveShareNativeV3CollaborationLimits.maximumStrokeLifetimeMilliseconds
    )
    self.context = context
    self.strokeID = strokeID
    self.point = point
    self.color = color
    self.expiresAt = expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      context: container.decode(
        ClipLiveShareNativeV3CollaborationContext.self,
        forKey: .context
      ),
      strokeID: container.decode(
        ClipLiveShareNativeV3StrokeID.self,
        forKey: .strokeID
      ),
      point: container.decode(
        ClipLiveShareNativeV3NormalizedPoint.self,
        forKey: .point
      ),
      color: container.decode(
        ClipLiveShareNativeV3CollaborationColor.self,
        forKey: .color
      ),
      expiresAt: container.decode(
        ClipLiveShareNativeTimestamp.self,
        forKey: .expiresAt
      )
    )
  }

  private enum CodingKeys: String, CodingKey {
    case context
    case strokeID = "strokeId"
    case point
    case color
    case expiresAt
  }
}

public struct ClipLiveShareNativeV3StrokePointsEvent:
  Codable, Equatable, Hashable, Sendable
{
  public let context: ClipLiveShareNativeV3CollaborationContext
  public let strokeID: ClipLiveShareNativeV3StrokeID
  public let points: [ClipLiveShareNativeV3NormalizedPoint]

  public init(
    context: ClipLiveShareNativeV3CollaborationContext,
    strokeID: ClipLiveShareNativeV3StrokeID,
    points: [ClipLiveShareNativeV3NormalizedPoint]
  ) throws {
    guard !points.isEmpty else {
      throw ClipLiveShareNativeV3CollaborationError.emptyPoints
    }
    guard
      points.count <= ClipLiveShareNativeV3CollaborationLimits.maximumPointsPerStrokeChunk
    else {
      throw ClipLiveShareNativeV3CollaborationError.pointLimit(
        maximum:
          ClipLiveShareNativeV3CollaborationLimits.maximumPointsPerStrokeChunk,
        actual: points.count
      )
    }
    self.context = context
    self.strokeID = strokeID
    self.points = points
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      context: container.decode(
        ClipLiveShareNativeV3CollaborationContext.self,
        forKey: .context
      ),
      strokeID: container.decode(
        ClipLiveShareNativeV3StrokeID.self,
        forKey: .strokeID
      ),
      points: container.decode(
        [ClipLiveShareNativeV3NormalizedPoint].self,
        forKey: .points
      )
    )
  }

  private enum CodingKeys: String, CodingKey {
    case context
    case strokeID = "strokeId"
    case points
  }
}

public struct ClipLiveShareNativeV3StrokeEndEvent:
  Codable, Equatable, Hashable, Sendable
{
  public let context: ClipLiveShareNativeV3CollaborationContext
  public let strokeID: ClipLiveShareNativeV3StrokeID

  public init(
    context: ClipLiveShareNativeV3CollaborationContext,
    strokeID: ClipLiveShareNativeV3StrokeID
  ) {
    self.context = context
    self.strokeID = strokeID
  }
}

public enum ClipLiveShareNativeV3ClearScope: String, Codable, Equatable, Hashable, Sendable {
  /// Clears only annotations owned by the authenticated participant.
  case participant
  /// Clears all annotations for the source. Authorization is checked by the
  /// room/session layer before this event reaches the collaboration state.
  case source
}

public struct ClipLiveShareNativeV3ClearEvent:
  Codable, Equatable, Hashable, Sendable
{
  public let context: ClipLiveShareNativeV3CollaborationContext
  public let clearEpoch: UInt64
  public let scope: ClipLiveShareNativeV3ClearScope

  public init(
    context: ClipLiveShareNativeV3CollaborationContext,
    clearEpoch: UInt64,
    scope: ClipLiveShareNativeV3ClearScope
  ) throws {
    guard clearEpoch > 0 else {
      throw ClipLiveShareNativeV3CollaborationError.invalidSequence
    }
    self.context = context
    self.clearEpoch = clearEpoch
    self.scope = scope
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      context: container.decode(
        ClipLiveShareNativeV3CollaborationContext.self,
        forKey: .context
      ),
      clearEpoch: container.decode(UInt64.self, forKey: .clearEpoch),
      scope: container.decode(ClipLiveShareNativeV3ClearScope.self, forKey: .scope)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case context
    case clearEpoch
    case scope
  }
}

/// Closed collaboration payload. Unknown cases fail decoding instead of being
/// partially interpreted as another control message.
public enum ClipLiveShareNativeV3CollaborationEvent:
  Codable, Equatable, Hashable, Sendable
{
  case pointer(ClipLiveShareNativeV3PointerEvent)
  case ping(ClipLiveShareNativeV3PingEvent)
  case strokeBegin(ClipLiveShareNativeV3StrokeBeginEvent)
  case strokePoints(ClipLiveShareNativeV3StrokePointsEvent)
  case strokeEnd(ClipLiveShareNativeV3StrokeEndEvent)
  case clear(ClipLiveShareNativeV3ClearEvent)

  public var context: ClipLiveShareNativeV3CollaborationContext {
    switch self {
    case let .pointer(value): value.context
    case let .ping(value): value.context
    case let .strokeBegin(value): value.context
    case let .strokePoints(value): value.context
    case let .strokeEnd(value): value.context
    case let .clear(value): value.context
    }
  }

  private enum MessageType: String, Codable {
    case pointer
    case ping
    case strokeBegin = "stroke-begin"
    case strokePoints = "stroke-points"
    case strokeEnd = "stroke-end"
    case clear
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case type
    case payload
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ClipLiveShareNativeV3.version else {
      throw ClipLiveShareNativeV3CollaborationError.unsupportedVersion(version)
    }
    let rawType = try container.decode(String.self, forKey: .type)
    guard let type = MessageType(rawValue: rawType) else {
      throw ClipLiveShareNativeV3CollaborationError.unknownMessageType(rawType)
    }
    switch type {
    case .pointer:
      self = .pointer(
        try container.decode(
          ClipLiveShareNativeV3PointerEvent.self,
          forKey: .payload
        )
      )
    case .ping:
      self = .ping(
        try container.decode(
          ClipLiveShareNativeV3PingEvent.self,
          forKey: .payload
        )
      )
    case .strokeBegin:
      self = .strokeBegin(
        try container.decode(
          ClipLiveShareNativeV3StrokeBeginEvent.self,
          forKey: .payload
        )
      )
    case .strokePoints:
      self = .strokePoints(
        try container.decode(
          ClipLiveShareNativeV3StrokePointsEvent.self,
          forKey: .payload
        )
      )
    case .strokeEnd:
      self = .strokeEnd(
        try container.decode(
          ClipLiveShareNativeV3StrokeEndEvent.self,
          forKey: .payload
        )
      )
    case .clear:
      self = .clear(
        try container.decode(
          ClipLiveShareNativeV3ClearEvent.self,
          forKey: .payload
        )
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ClipLiveShareNativeV3.version, forKey: .version)
    switch self {
    case let .pointer(value):
      try container.encode(MessageType.pointer.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .ping(value):
      try container.encode(MessageType.ping.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .strokeBegin(value):
      try container.encode(MessageType.strokeBegin.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .strokePoints(value):
      try container.encode(MessageType.strokePoints.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .strokeEnd(value):
      try container.encode(MessageType.strokeEnd.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    case let .clear(value):
      try container.encode(MessageType.clear.rawValue, forKey: .type)
      try container.encode(value, forKey: .payload)
    }
  }
}

public struct ClipLiveShareNativeV3PointerState: Equatable, Hashable, Sendable {
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let position: ClipLiveShareNativeV3NormalizedPoint
  public let sentAt: ClipLiveShareNativeTimestamp
}

public struct ClipLiveShareNativeV3PingState: Equatable, Hashable, Sendable {
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let position: ClipLiveShareNativeV3NormalizedPoint
  public let color: ClipLiveShareNativeV3CollaborationColor
  public let expiresAt: ClipLiveShareNativeTimestamp
}

public struct ClipLiveShareNativeV3StrokeState: Equatable, Hashable, Sendable {
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let strokeID: ClipLiveShareNativeV3StrokeID
  public let color: ClipLiveShareNativeV3CollaborationColor
  public let expiresAt: ClipLiveShareNativeTimestamp
  public fileprivate(set) var points: [ClipLiveShareNativeV3NormalizedPoint]
  public fileprivate(set) var isComplete: Bool
}

/// Transactional, participant-scoped collaboration state for one remote
/// source. Callers must supply the participant authenticated by the pair link.
public struct ClipLiveShareNativeV3CollaborationState: Equatable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let sourceKey: ClipLiveShareNativeV3SourceKey
  public private(set) var pointers:
    [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeV3PointerState] = [:]
  public private(set) var pings: [ClipLiveShareNativeV3PingState] = []
  public private(set) var strokes:
    [ClipLiveShareNativeV3StrokeID: ClipLiveShareNativeV3StrokeState] = [:]
  public private(set) var sourceClearEpoch: UInt64 = 0

  private var latestSequences:
    [ClipLiveShareNativeV3ParticipantID: UInt64] = [:]
  private var participantClearEpochs:
    [ClipLiveShareNativeV3ParticipantID: UInt64] = [:]

  public init(
    sessionID: ClipLiveShareSessionID,
    sourceKey: ClipLiveShareNativeV3SourceKey
  ) {
    self.sessionID = sessionID
    self.sourceKey = sourceKey
  }

  public mutating func apply(
    _ event: ClipLiveShareNativeV3CollaborationEvent,
    authenticatedParticipantID: ClipLiveShareNativeV3ParticipantID,
    at now: ClipLiveShareNativeTimestamp,
    mayClearEntireSource: Bool = false
  ) throws {
    let context = event.context
    guard context.sessionID == sessionID, context.sourceKey == sourceKey else {
      throw ClipLiveShareNativeV3CollaborationError.sourceMismatch
    }
    guard context.participantID == authenticatedParticipantID else {
      throw ClipLiveShareNativeV3CollaborationError.participantMismatch
    }
    guard
      context.sentAt.millisecondsSince1970
        <= now.millisecondsSince1970
          + ClipLiveShareNativeV3CollaborationLimits.maximumFutureEventSkewMilliseconds
    else {
      throw ClipLiveShareNativeV3CollaborationError.invalidTimestamp
    }
    let latestSequence = latestSequences[authenticatedParticipantID] ?? 0
    guard context.sequence > latestSequence else {
      throw ClipLiveShareNativeV3CollaborationError.staleSequence(
        expectedGreaterThan: latestSequence,
        actual: context.sequence
      )
    }

    var candidate = self
    try candidate.applyValidated(
      event,
      participantID: authenticatedParticipantID,
      at: now,
      mayClearEntireSource: mayClearEntireSource
    )
    candidate.latestSequences[authenticatedParticipantID] = context.sequence
    self = candidate
  }

  public mutating func retainParticipants(
    _ participantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  ) {
    pointers = pointers.filter { participantIDs.contains($0.key) }
    pings.removeAll { !participantIDs.contains($0.participantID) }
    strokes = strokes.filter { participantIDs.contains($0.value.participantID) }
    latestSequences = latestSequences.filter { participantIDs.contains($0.key) }
    participantClearEpochs = participantClearEpochs.filter {
      participantIDs.contains($0.key)
    }
  }

  @discardableResult
  public mutating func pruneExpired(
    at now: ClipLiveShareNativeTimestamp
  ) -> Bool {
    let priorPings = pings.count
    let priorStrokes = strokes.count
    pings.removeAll { $0.expiresAt < now }
    strokes = strokes.filter { $0.value.expiresAt >= now }
    return pings.count != priorPings || strokes.count != priorStrokes
  }

  private mutating func applyValidated(
    _ event: ClipLiveShareNativeV3CollaborationEvent,
    participantID: ClipLiveShareNativeV3ParticipantID,
    at now: ClipLiveShareNativeTimestamp,
    mayClearEntireSource: Bool
  ) throws {
    pruneExpired(at: now)
    switch event {
    case let .pointer(value):
      if let position = value.position {
        pointers[participantID] = ClipLiveShareNativeV3PointerState(
          participantID: participantID,
          position: position,
          sentAt: value.context.sentAt
        )
      } else {
        pointers[participantID] = nil
      }

    case let .ping(value):
      guard value.expiresAt >= now else {
        throw ClipLiveShareNativeV3CollaborationError.expired
      }
      guard
        pings.count
          < ClipLiveShareNativeV3CollaborationLimits.maximumActivePingsPerSource
      else {
        throw ClipLiveShareNativeV3CollaborationError.pingLimit(
          maximum:
            ClipLiveShareNativeV3CollaborationLimits.maximumActivePingsPerSource,
          actual: pings.count + 1
        )
      }
      pings.append(
        ClipLiveShareNativeV3PingState(
          participantID: participantID,
          position: value.position,
          color: value.color,
          expiresAt: value.expiresAt
        )
      )

    case let .strokeBegin(value):
      guard value.expiresAt >= now else {
        throw ClipLiveShareNativeV3CollaborationError.expired
      }
      guard strokes[value.strokeID] == nil else {
        throw ClipLiveShareNativeV3CollaborationError.duplicateStroke
      }
      guard
        strokes.count
          < ClipLiveShareNativeV3CollaborationLimits.maximumActiveStrokesPerSource
      else {
        throw ClipLiveShareNativeV3CollaborationError.strokeLimit(
          maximum:
            ClipLiveShareNativeV3CollaborationLimits.maximumActiveStrokesPerSource,
          actual: strokes.count + 1
        )
      }
      strokes[value.strokeID] = ClipLiveShareNativeV3StrokeState(
        participantID: participantID,
        strokeID: value.strokeID,
        color: value.color,
        expiresAt: value.expiresAt,
        points: [value.point],
        isComplete: false
      )

    case let .strokePoints(value):
      guard var stroke = strokes[value.strokeID],
        stroke.participantID == participantID,
        !stroke.isComplete
      else {
        throw ClipLiveShareNativeV3CollaborationError.unknownStroke
      }
      let count = stroke.points.count + value.points.count
      guard
        count <= ClipLiveShareNativeV3CollaborationLimits.maximumPointsPerStroke
      else {
        throw ClipLiveShareNativeV3CollaborationError.pointLimit(
          maximum: ClipLiveShareNativeV3CollaborationLimits.maximumPointsPerStroke,
          actual: count
        )
      }
      stroke.points.append(contentsOf: value.points)
      strokes[value.strokeID] = stroke

    case let .strokeEnd(value):
      guard var stroke = strokes[value.strokeID],
        stroke.participantID == participantID,
        !stroke.isComplete
      else {
        throw ClipLiveShareNativeV3CollaborationError.unknownStroke
      }
      stroke.isComplete = true
      strokes[value.strokeID] = stroke

    case let .clear(value):
      switch value.scope {
      case .participant:
        let priorEpoch = participantClearEpochs[participantID] ?? 0
        guard value.clearEpoch > priorEpoch else {
          throw ClipLiveShareNativeV3CollaborationError.staleClearEpoch(
            expectedAtLeast: priorEpoch + 1,
            actual: value.clearEpoch
          )
        }
        pointers[participantID] = nil
        pings.removeAll { $0.participantID == participantID }
        strokes = strokes.filter { $0.value.participantID != participantID }
        participantClearEpochs[participantID] = value.clearEpoch
      case .source:
        guard mayClearEntireSource else {
          throw ClipLiveShareNativeV3CollaborationError.participantMismatch
        }
        guard value.clearEpoch > sourceClearEpoch else {
          throw ClipLiveShareNativeV3CollaborationError.staleClearEpoch(
            expectedAtLeast: sourceClearEpoch + 1,
            actual: value.clearEpoch
          )
        }
        pointers.removeAll()
        pings.removeAll()
        strokes.removeAll()
        sourceClearEpoch = value.clearEpoch
      }
    }
  }
}

private func validateCollaborationLifetime(
  sentAt: ClipLiveShareNativeTimestamp,
  expiresAt: ClipLiveShareNativeTimestamp,
  maximumMilliseconds: Int64
) throws {
  let lifetime = expiresAt.millisecondsSince1970 - sentAt.millisecondsSince1970
  guard lifetime > 0, lifetime <= maximumMilliseconds else {
    throw ClipLiveShareNativeV3CollaborationError.invalidLifetime
  }
}
