import Foundation

/// Direct peer-to-peer media metadata carried by the server-coordinated mesh.
///
/// Room admission, membership, and WebRTC negotiation belong to the v4 room
/// protocol and never travel through this channel. Keeping this vocabulary
/// closed prevents an authenticated media peer from smuggling control-plane
/// operations into a data-channel message.
public enum ClipLiveShareMeshMediaControlMessageKind: String, Codable,
  CaseIterable, Equatable, Hashable, Sendable
{
  case sourceSnapshot = "source-snapshot"
  case sourceCursor = "source-cursor"
  case collaboration
  case friendship
}

/// Ephemeral native cursor context for one exact published source.
///
/// Source instance and stream identity prevent a late cursor update from
/// moving a replacement window. The direct peer link authenticates the sender;
/// receivers still verify that `participantID` owns `sourceKey`.
public struct ClipLiveShareNativeV3SourceCursor: Codable, Equatable, Hashable,
  Sendable
{
  public let sessionID: ClipLiveShareSessionID
  public let participantID: ClipLiveShareNativeV3ParticipantID
  public let sourceKey: ClipLiveShareNativeV3SourceKey
  public let streamID: ClipLiveShareStreamID
  public let sequence: UInt64
  public let position: ClipLiveShareNativeV3NormalizedPoint?

  public init(
    sessionID: ClipLiveShareSessionID,
    participantID: ClipLiveShareNativeV3ParticipantID,
    sourceKey: ClipLiveShareNativeV3SourceKey,
    streamID: ClipLiveShareStreamID,
    sequence: UInt64,
    position: ClipLiveShareNativeV3NormalizedPoint?
  ) throws {
    guard participantID == sourceKey.ownerParticipantID, sequence > 0 else {
      throw ClipLiveShareNativeV3Error.contextMismatch
    }
    self.sessionID = sessionID
    self.participantID = participantID
    self.sourceKey = sourceKey
    self.streamID = streamID
    self.sequence = sequence
    self.position = position
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "sessionId"
    case participantID = "participantId"
    case sourceKey
    case streamID = "streamId"
    case sequence
    case position
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
      streamID: container.decode(ClipLiveShareStreamID.self, forKey: .streamID),
      sequence: container.decode(UInt64.self, forKey: .sequence),
      position: container.decodeIfPresent(
        ClipLiveShareNativeV3NormalizedPoint.self,
        forKey: .position
      )
    )
  }
}

public enum ClipLiveShareMeshMediaControlMessage: Codable, Equatable, Hashable,
  Sendable
{
  case sourceSnapshot(ClipLiveShareNativeV3SourceSnapshot)
  case sourceCursor(ClipLiveShareNativeV3SourceCursor)
  case collaboration(ClipLiveShareNativeV3CollaborationEvent)
  case friendship(ClipLiveShareServerRoomV4SignedFriendMessage)

  public var kind: ClipLiveShareMeshMediaControlMessageKind {
    switch self {
    case .sourceSnapshot: .sourceSnapshot
    case .sourceCursor: .sourceCursor
    case .collaboration: .collaboration
    case .friendship: .friendship
    }
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case type
    case payload
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == ClipLiveShareServerRoomV4.version else {
      throw ClipLiveShareProtocolError.unsupportedVersion(version)
    }
    let rawType = try container.decode(String.self, forKey: .type)
    guard
      let kind = ClipLiveShareMeshMediaControlMessageKind(rawValue: rawType)
    else {
      throw ClipLiveShareMeshMediaControlError.unknownMessageType(rawType)
    }
    switch kind {
    case .sourceSnapshot:
      self = .sourceSnapshot(
        try container.decode(
          ClipLiveShareNativeV3SourceSnapshot.self,
          forKey: .payload
        )
      )
    case .sourceCursor:
      self = .sourceCursor(
        try container.decode(
          ClipLiveShareNativeV3SourceCursor.self,
          forKey: .payload
        )
      )
    case .collaboration:
      self = .collaboration(
        try container.decode(
          ClipLiveShareNativeV3CollaborationEvent.self,
          forKey: .payload
        )
      )
    case .friendship:
      self = .friendship(
        try container.decode(
          ClipLiveShareServerRoomV4SignedFriendMessage.self,
          forKey: .payload
        )
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ClipLiveShareServerRoomV4.version, forKey: .version)
    try container.encode(kind.rawValue, forKey: .type)
    switch self {
    case let .sourceSnapshot(value):
      try container.encode(value, forKey: .payload)
    case let .sourceCursor(value):
      try container.encode(value, forKey: .payload)
    case let .collaboration(value):
      try container.encode(value, forKey: .payload)
    case let .friendship(value):
      try container.encode(value, forKey: .payload)
    }
  }
}

public enum ClipLiveShareMeshMediaControlError: Error, Equatable, Sendable,
  LocalizedError
{
  case unknownMessageType(String)

  public var errorDescription: String? {
    switch self {
    case let .unknownMessageType(type):
      "Unsupported mesh media-control message '\(type)'."
    }
  }
}

/// Strict JSON boundary for direct peer media metadata.
public enum ClipLiveShareMeshMediaControlCodec {
  public static let maximumMessageBytes = 196_400

  public static func encode(
    _ message: ClipLiveShareMeshMediaControlMessage,
    maximumBytes: Int = maximumMessageBytes
  ) throws -> Data {
    guard maximumBytes > 0 else {
      throw ClipLiveShareProtocolError.invalidResource(
        "mesh media-control message size limit must be positive"
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(message)
    guard data.count <= maximumBytes else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum: maximumBytes,
        actual: data.count
      )
    }
    return data
  }

  public static func decode(
    _ data: Data,
    maximumBytes: Int = maximumMessageBytes
  ) throws -> ClipLiveShareMeshMediaControlMessage {
    guard maximumBytes > 0 else {
      throw ClipLiveShareProtocolError.invalidResource(
        "mesh media-control message size limit must be positive"
      )
    }
    guard data.count <= maximumBytes else {
      throw ClipLiveShareProtocolError.messageTooLarge(
        maximum: maximumBytes,
        actual: data.count
      )
    }
    let object = try JSONSerialization.jsonObject(
      with: data,
      options: [.fragmentsAllowed]
    )
    guard let dictionary = object as? [String: Any] else {
      throw ClipLiveShareProtocolError.invalidResource(
        "mesh media-control message must be a JSON object"
      )
    }
    let expectedKeys: Set<String> = ["version", "type", "payload"]
    guard Set(dictionary.keys) == expectedKeys else {
      throw ClipLiveShareProtocolError.invalidResource(
        "mesh media-control message has unexpected fields"
      )
    }
    guard
      let version = dictionary["version"] as? NSNumber,
      version.intValue == ClipLiveShareServerRoomV4.version,
      version.doubleValue == Double(version.intValue)
    else {
      let unsupportedVersion =
        (dictionary["version"] as? NSNumber)?.intValue ?? -1
      throw ClipLiveShareProtocolError.unsupportedVersion(unsupportedVersion)
    }
    guard let rawType = dictionary["type"] as? String else {
      throw ClipLiveShareProtocolError.invalidResource(
        "mesh media-control message type is invalid"
      )
    }
    guard ClipLiveShareMeshMediaControlMessageKind(rawValue: rawType) != nil else {
      throw ClipLiveShareMeshMediaControlError.unknownMessageType(rawType)
    }
    return try JSONDecoder().decode(
      ClipLiveShareMeshMediaControlMessage.self,
      from: data
    )
  }
}
