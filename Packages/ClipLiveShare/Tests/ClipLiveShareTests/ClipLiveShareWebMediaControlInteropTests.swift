import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Swift and Web media-control interoperability")
struct ClipLiveShareWebMediaControlInteropTests {
  @Test("Swift media-control bytes match the frozen Web fixture")
  func frozenMediaControlFixture() throws {
    let fixtureData = try Data(contentsOf: Self.fixtureURL)
    let root = try #require(
      JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
    )
    let messages = try Self.messages()

    for (key, expected) in messages {
      let object = try #require(root[key])
      let bytes = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      #expect(try ClipLiveShareMeshMediaControlCodec.encode(expected) == bytes)
      #expect(try ClipLiveShareMeshMediaControlCodec.decode(bytes) == expected)
    }
  }

  private static var fixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/web-media-control.json")
  }

  private static func messages() throws
    -> [String: ClipLiveShareMeshMediaControlMessage]
  {
    let sessionID = try ClipLiveShareSessionID(
      rawValue: "web-media-control-fixture"
    )
    let nativeID = try ClipLiveShareNativeV3ParticipantID(
      bytes: Data(repeating: 0x11, count: 16)
    )
    let webID = try ClipLiveShareNativeV3ParticipantID(
      bytes: Data(repeating: 0x22, count: 16)
    )
    let sourceID = try ClipLiveShareSourceInstanceID(
      bytes: Data(repeating: 0x33, count: 16)
    )
    let sourceKey = ClipLiveShareNativeV3SourceKey(
      ownerParticipantID: nativeID,
      sourceInstanceID: sourceID
    )
    let stream = try ClipLiveShareStreamDescriptor(
      id: ClipLiveShareStreamID(rawValue: "native-stream-0"),
      mediaTrackID: ClipLiveShareMediaTrackID(rawValue: "native-video-0"),
      active: true,
      focused: true,
      appName: "Fixture App",
      windowName: "Fixture Window",
      width: 2_560,
      height: 1_440,
      order: 0,
      sourcePointWidth: 1_280,
      sourcePointHeight: 720
    )
    let publishedSource = try ClipLiveShareNativeV3PublishedSource(
      key: sourceKey,
      descriptor: .init(sourceInstanceID: sourceID, stream: stream)
    )
    let nativeSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
      sessionID: sessionID,
      membershipRevision: .init(rawValue: 1),
      ownerParticipantID: nativeID,
      sourceRevision: .init(rawValue: 7),
      sources: [publishedSource]
    )
    let webSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
      sessionID: sessionID,
      membershipRevision: .init(rawValue: 1),
      ownerParticipantID: webID,
      sourceRevision: .init(rawValue: 3),
      sources: []
    )
    let cursor = try ClipLiveShareNativeV3SourceCursor(
      sessionID: sessionID,
      participantID: nativeID,
      sourceKey: sourceKey,
      streamID: stream.id,
      sequence: 9,
      position: .init(x: 0.75, y: 0.25)
    )
    return [
      "nativeSourceSnapshot": .sourceSnapshot(nativeSnapshot),
      "webEmptySourceSnapshot": .sourceSnapshot(webSnapshot),
      "nativeSourceCursor": .sourceCursor(cursor),
    ]
  }
}
