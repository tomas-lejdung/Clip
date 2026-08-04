import Foundation

/// Metadata for one encoded video stream carried by a native-v3 peer link.
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
  /// Logical source dimensions in AppKit points. Native-v3 requires this
  /// geometry for both windows and displays so viewers never infer scale from
  /// encoded pixels or fall back to legacy density behavior.
  public let sourcePointWidth: Int
  public let sourcePointHeight: Int

  public init(
    id: ClipLiveShareStreamID,
    mediaTrackID: ClipLiveShareMediaTrackID,
    active: Bool,
    focused: Bool,
    appName: String,
    windowName: String,
    width: Int,
    height: Int,
    order: Int,
    sourcePointWidth: Int,
    sourcePointHeight: Int
  ) throws {
    try validateLiveShareText(
      appName,
      field: "application name",
      maximumUTF8Bytes: 512
    )
    try validateLiveShareText(
      windowName,
      field: "window name",
      maximumUTF8Bytes: 1_024
    )
    guard (1...32_768).contains(width), (1...32_768).contains(height) else {
      throw ClipLiveShareProtocolError.invalidResource(
        "stream dimensions are out of bounds"
      )
    }
    guard (0...65_535).contains(order) else {
      throw ClipLiveShareProtocolError.invalidResource(
        "stream order is out of bounds"
      )
    }
    guard
      (1...32_768).contains(sourcePointWidth),
      (1...32_768).contains(sourcePointHeight)
    else {
      throw ClipLiveShareProtocolError.invalidResource(
        "source point dimensions are out of bounds"
      )
    }
    guard !focused || active else {
      throw ClipLiveShareProtocolError.invalidResource(
        "an inactive stream cannot be focused"
      )
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
    self.sourcePointWidth = sourcePointWidth
    self.sourcePointHeight = sourcePointHeight
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
    case sourcePointWidth
    case sourcePointHeight
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(ClipLiveShareStreamID.self, forKey: .id),
      mediaTrackID: container.decode(
        ClipLiveShareMediaTrackID.self,
        forKey: .mediaTrackID
      ),
      active: container.decode(Bool.self, forKey: .active),
      focused: container.decode(Bool.self, forKey: .focused),
      appName: container.decode(String.self, forKey: .appName),
      windowName: container.decode(String.self, forKey: .windowName),
      width: container.decode(Int.self, forKey: .width),
      height: container.decode(Int.self, forKey: .height),
      order: container.decode(Int.self, forKey: .order),
      sourcePointWidth: container.decode(
        Int.self,
        forKey: .sourcePointWidth
      ),
      sourcePointHeight: container.decode(
        Int.self,
        forKey: .sourcePointHeight
      )
    )
  }
}

public struct ClipLiveShareStreamManifest: Equatable, Hashable, Sendable {
  public let sessionID: ClipLiveShareSessionID
  public let streams: [ClipLiveShareStreamDescriptor]

  public init(
    sessionID: ClipLiveShareSessionID,
    streams: [ClipLiveShareStreamDescriptor],
    maximumStreams: Int = ClipLiveShareNativeV3.maximumSourcesPerParticipant
  ) throws {
    guard maximumStreams > 0, streams.count <= maximumStreams else {
      throw ClipLiveShareProtocolError.invalidResource(
        "stream manifest exceeds its bound"
      )
    }
    guard Set(streams.map(\.id)).count == streams.count else {
      throw ClipLiveShareProtocolError.invalidResource(
        "stream manifest contains duplicate IDs"
      )
    }
    guard Set(streams.map(\.mediaTrackID)).count == streams.count else {
      throw ClipLiveShareProtocolError.invalidResource(
        "stream manifest contains duplicate media tracks"
      )
    }
    guard Set(streams.map(\.order)).count == streams.count else {
      throw ClipLiveShareProtocolError.invalidResource(
        "stream manifest contains duplicate order values"
      )
    }
    guard streams.filter(\.focused).count <= 1 else {
      throw ClipLiveShareProtocolError.invalidResource(
        "stream manifest has multiple focused streams"
      )
    }
    self.sessionID = sessionID
    self.streams = streams
  }
}

/// A capture-source generation. This changes whenever a participant starts
/// sharing a different source, even when a stable WebRTC sender slot is reused.
public struct ClipLiveShareNativeV3StreamDescriptor:
  Codable, Equatable, Hashable, Sendable
{
  public let sourceInstanceID: ClipLiveShareSourceInstanceID
  public let stream: ClipLiveShareStreamDescriptor

  public init(
    sourceInstanceID: ClipLiveShareSourceInstanceID,
    stream: ClipLiveShareStreamDescriptor
  ) {
    self.sourceInstanceID = sourceInstanceID
    self.stream = stream
  }

  var canonicalRepresentation: Data {
    var encoder = ClipLiveShareNativeV3CanonicalEncoder(
      domain: "clip-live-share-native-v3/stream-descriptor"
    )
    encoder.append(sourceInstanceID.bytes)
    encoder.append(stream.id.rawValue)
    encoder.append(stream.mediaTrackID.rawValue)
    encoder.append(stream.active)
    encoder.append(stream.focused)
    encoder.append(stream.appName)
    encoder.append(stream.windowName)
    encoder.append(UInt64(stream.width))
    encoder.append(UInt64(stream.height))
    encoder.append(UInt64(stream.order))
    encoder.append(UInt64(stream.sourcePointWidth))
    encoder.append(UInt64(stream.sourcePointHeight))
    return encoder.data
  }

  private enum CodingKeys: String, CodingKey {
    case sourceInstanceID = "sourceInstanceId"
    case stream
  }
}

private func validateLiveShareText(
  _ value: String,
  field: String,
  maximumUTF8Bytes: Int
) throws {
  guard value.utf8.count <= maximumUTF8Bytes,
    value.unicodeScalars.allSatisfy({
      !CharacterSet.controlCharacters.contains($0)
    })
  else {
    throw ClipLiveShareProtocolError.invalidResource(
      "\(field) is invalid"
    )
  }
}
