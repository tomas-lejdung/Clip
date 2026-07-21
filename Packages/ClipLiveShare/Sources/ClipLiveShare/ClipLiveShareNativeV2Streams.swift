import Foundation

/// Tells a native viewer whether a source owns a manually selected window or
/// feeds the one stable window used by Auto-share as application focus moves.
public enum ClipLiveShareNativeSourcePresentationMode: String, Codable, Equatable, Hashable,
  Sendable
{
  case manual
  case followsFocusedWindow = "follows-focused-window"
}

/// A capture-source generation. Unlike a reusable WebRTC stream or sender
/// slot, this value changes whenever Clip starts sharing a different source.
public struct ClipLiveShareNativeStreamDescriptor: Codable, Equatable, Hashable, Sendable {
  public let sourceInstanceID: ClipLiveShareSourceInstanceID
  public let presentationMode: ClipLiveShareNativeSourcePresentationMode
  public let stream: ClipLiveShareStreamDescriptor

  public init(
    sourceInstanceID: ClipLiveShareSourceInstanceID,
    presentationMode: ClipLiveShareNativeSourcePresentationMode,
    stream: ClipLiveShareStreamDescriptor
  ) {
    self.sourceInstanceID = sourceInstanceID
    self.presentationMode = presentationMode
    self.stream = stream
  }

  var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/stream-descriptor"
    )
    encoder.append(sourceInstanceID.bytes)
    encoder.append(presentationMode.rawValue)
    encoder.append(stream.id.rawValue)
    encoder.append(stream.mediaTrackID.rawValue)
    encoder.append(stream.active)
    encoder.append(stream.focused)
    encoder.append(stream.appName)
    encoder.append(stream.windowName)
    encoder.append(UInt64(stream.width))
    encoder.append(UInt64(stream.height))
    encoder.append(UInt64(stream.order))
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case sourceInstanceID = "sourceInstanceId"
    case presentationMode
    case stream
  }
}

public enum ClipLiveShareNativeStreamLifecycleEvent: Equatable, Hashable, Sendable {
  case snapshot([ClipLiveShareNativeStreamDescriptor])
  case upsert(ClipLiveShareNativeStreamDescriptor)
  case removed(ClipLiveShareSourceInstanceID)
  case focus(ClipLiveShareSourceInstanceID?)
  case sharing(Bool)
  case systemAudio(Bool)

  public var type: String {
    switch self {
    case .snapshot: "stream-snapshot"
    case .upsert: "stream-upsert"
    case .removed: "stream-removed"
    case .focus: "stream-focus"
    case .sharing: "sharing-state"
    case .systemAudio: "system-audio-state"
    }
  }
}

/// Native stream lifecycle updates are independent of v1 inner messages.
/// Every update is session-bound and strictly ordered by `stateRevision`.
public struct ClipLiveShareNativeStreamLifecycleMessage: Codable, Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let stateRevision: ClipLiveShareStateRevision
  public let event: ClipLiveShareNativeStreamLifecycleEvent

  public init(
    sessionID: ClipLiveShareSessionID,
    stateRevision: ClipLiveShareStateRevision,
    event: ClipLiveShareNativeStreamLifecycleEvent,
    maximumStreams: Int = ClipLiveShareNativeV2.maximumConcurrentVideoSources
  ) throws {
    try Self.validate(event, sessionID: sessionID, maximumStreams: maximumStreams)
    self.sessionID = sessionID
    self.stateRevision = stateRevision
    self.event = event
  }

  public var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV2CanonicalEncoder(
      domain: "clip-live-share-native-v2/stream-lifecycle"
    )
    encoder.append(sessionID.rawValue)
    encoder.append(stateRevision.rawValue)
    encoder.append(event.type)
    switch event {
    case let .snapshot(streams):
      encoder.append(UInt64(streams.count))
      for stream in streams { encoder.append(stream.canonicalRepresentation) }
    case let .upsert(stream):
      encoder.append(stream.canonicalRepresentation)
    case let .removed(sourceInstanceID):
      encoder.append(sourceInstanceID.bytes)
    case let .focus(sourceInstanceID):
      encoder.append(sourceInstanceID != nil)
      if let sourceInstanceID { encoder.append(sourceInstanceID.bytes) }
    case let .sharing(sharing):
      encoder.append(sharing)
    case let .systemAudio(enabled):
      encoder.append(enabled)
    }
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case type
    case sessionID = "sessionId"
    case stateRevision
    case streams
    case stream
    case sourceInstanceID = "sourceInstanceId"
    case focusedSourceInstanceID = "focusedSourceInstanceId"
    case sharing
    case enabled
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ClipLiveShareNativeV2.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    let sessionID = try container.decode(ClipLiveShareSessionID.self, forKey: .sessionID)
    let stateRevision = try container.decode(
      ClipLiveShareStateRevision.self,
      forKey: .stateRevision
    )
    let event: ClipLiveShareNativeStreamLifecycleEvent
    switch try container.decode(String.self, forKey: .type) {
    case "stream-snapshot":
      event = .snapshot(
        try container.decode([ClipLiveShareNativeStreamDescriptor].self, forKey: .streams)
      )
    case "stream-upsert":
      event = .upsert(
        try container.decode(ClipLiveShareNativeStreamDescriptor.self, forKey: .stream)
      )
    case "stream-removed":
      event = .removed(
        try container.decode(ClipLiveShareSourceInstanceID.self, forKey: .sourceInstanceID)
      )
    case "stream-focus":
      event = .focus(
        try container.decodeIfPresent(
          ClipLiveShareSourceInstanceID.self,
          forKey: .focusedSourceInstanceID
        )
      )
    case "sharing-state":
      event = .sharing(try container.decode(Bool.self, forKey: .sharing))
    case "system-audio-state":
      event = .systemAudio(try container.decode(Bool.self, forKey: .enabled))
    case let type:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown native stream lifecycle type: \(type)"
      )
    }
    try self.init(sessionID: sessionID, stateRevision: stateRevision, event: event)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ClipLiveShareNativeV2.version, forKey: .version)
    try container.encode(event.type, forKey: .type)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(stateRevision, forKey: .stateRevision)
    switch event {
    case let .snapshot(streams):
      try container.encode(streams, forKey: .streams)
    case let .upsert(stream):
      try container.encode(stream, forKey: .stream)
    case let .removed(sourceInstanceID):
      try container.encode(sourceInstanceID, forKey: .sourceInstanceID)
    case let .focus(sourceInstanceID):
      if let sourceInstanceID {
        try container.encode(sourceInstanceID, forKey: .focusedSourceInstanceID)
      } else {
        try container.encodeNil(forKey: .focusedSourceInstanceID)
      }
    case let .sharing(sharing):
      try container.encode(sharing, forKey: .sharing)
    case let .systemAudio(enabled):
      try container.encode(enabled, forKey: .enabled)
    }
  }

  private static func validate(
    _ event: ClipLiveShareNativeStreamLifecycleEvent,
    sessionID: ClipLiveShareSessionID,
    maximumStreams: Int
  ) throws {
    guard maximumStreams > 0 else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native stream manifest limit must be positive"
      )
    }
    guard case let .snapshot(streams) = event else { return }
    guard Set(streams.map(\.sourceInstanceID)).count == streams.count else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native stream snapshot contains duplicate source instances"
      )
    }
    _ = try ClipLiveShareStreamManifest(
      sessionID: sessionID,
      streams: streams.map(\.stream),
      maximumStreams: maximumStreams
    )
  }
}

/// Applies only strictly increasing native lifecycle messages for one session.
/// The source-instance set prevents a delayed removal for an old capture from
/// removing a new capture that happens to reuse the same sender slot.
public struct ClipLiveShareNativeStreamLifecycleState: Equatable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let maximumStreams: Int
  public private(set) var streams:
    [ClipLiveShareSourceInstanceID: ClipLiveShareNativeStreamDescriptor]
  public private(set) var focusedSourceInstanceID: ClipLiveShareSourceInstanceID?
  public private(set) var sharing: Bool
  public private(set) var systemAudioEnabled: Bool
  public private(set) var revisionGuard: ClipLiveShareStateRevisionGuard

  public init(
    sessionID: ClipLiveShareSessionID,
    maximumStreams: Int = ClipLiveShareNativeV2.maximumConcurrentVideoSources
  ) {
    precondition(maximumStreams > 0, "native stream state limit must be positive")
    self.sessionID = sessionID
    self.maximumStreams = maximumStreams
    streams = [:]
    focusedSourceInstanceID = nil
    sharing = false
    systemAudioEnabled = false
    revisionGuard = ClipLiveShareStateRevisionGuard()
  }

  public mutating func apply(_ message: ClipLiveShareNativeStreamLifecycleMessage) throws {
    guard message.sessionID == sessionID else {
      throw ClipLiveShareNativeV2Error.contextMismatch
    }

    var next = self
    try next.revisionGuard.accept(message.stateRevision)
    switch message.event {
    case let .snapshot(descriptors):
      guard descriptors.count <= maximumStreams else {
        throw ClipLiveShareProtocolError.invalidResource(
          "native stream snapshot exceeds the active source limit"
        )
      }
      next.streams = Dictionary(
        uniqueKeysWithValues: descriptors.map {
          ($0.sourceInstanceID, $0)
        })
      next.focusedSourceInstanceID =
        descriptors.first(where: { $0.stream.focused })?
        .sourceInstanceID
    case let .upsert(descriptor):
      guard next.streams[descriptor.sourceInstanceID] != nil
        || next.streams.count < maximumStreams
      else {
        throw ClipLiveShareProtocolError.invalidResource(
          "native stream update exceeds the active source limit"
        )
      }
      try next.ensureNoSlotCollision(for: descriptor)
      if descriptor.stream.focused {
        guard !next.streams.values.contains(where: {
          $0.sourceInstanceID != descriptor.sourceInstanceID && $0.stream.focused
        }) else {
          throw ClipLiveShareProtocolError.invalidResource(
            "native stream update would create multiple focused sources"
          )
        }
      }
      next.streams[descriptor.sourceInstanceID] = descriptor
      if descriptor.stream.focused {
        next.focusedSourceInstanceID = descriptor.sourceInstanceID
      } else if next.focusedSourceInstanceID == descriptor.sourceInstanceID {
        next.focusedSourceInstanceID = nil
      }
    case let .removed(sourceInstanceID):
      next.streams.removeValue(forKey: sourceInstanceID)
      if next.focusedSourceInstanceID == sourceInstanceID {
        next.focusedSourceInstanceID = nil
      }
    case let .focus(sourceInstanceID):
      if let sourceInstanceID, next.streams[sourceInstanceID] == nil {
        throw ClipLiveShareNativeV2Error.contextMismatch
      }
      next.focusedSourceInstanceID = sourceInstanceID
    case let .sharing(sharing):
      next.sharing = sharing
    case let .systemAudio(enabled):
      next.systemAudioEnabled = enabled
    }
    self = next
  }

  private func ensureNoSlotCollision(
    for descriptor: ClipLiveShareNativeStreamDescriptor
  ) throws {
    let otherStreams = streams.values.filter {
      $0.sourceInstanceID != descriptor.sourceInstanceID
    }
    guard
      !otherStreams.contains(where: {
        $0.stream.id == descriptor.stream.id
          || $0.stream.mediaTrackID == descriptor.stream.mediaTrackID
          || $0.stream.order == descriptor.stream.order
      })
    else {
      throw ClipLiveShareProtocolError.invalidResource(
        "native stream update collides with another active sender slot"
      )
    }
  }
}
