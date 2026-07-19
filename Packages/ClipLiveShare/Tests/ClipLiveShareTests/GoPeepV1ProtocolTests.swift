import Foundation
import Testing

@testable import ClipLiveShare

@Suite("GoPeep v1 protocol compatibility")
struct GoPeepV1ProtocolTests {
  private static let messageFixtures = [
    "join-sharer",
    "join-viewer",
    "joined",
    "viewer-joined",
    "viewer-reoffer",
    "offer",
    "answer",
    "renegotiate-answer",
    "ice",
    "error",
    "password-update",
    "password-required",
    "password-invalid",
    "sharer-ready",
    "streams-info",
    "focus-change",
    "stream-added",
    "stream-removed",
    "stream-activated",
    "stream-deactivated",
    "size-change",
    "cursor-position",
    "sharer-started",
    "sharer-stopped",
  ]

  @Test("Every GoPeep signaling and control fixture round-trips without schema drift")
  func fixtureRoundTrips() throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    for fixture in Self.messageFixtures {
      let original = try fixtureData(fixture)
      let message = try decoder.decode(GoPeepV1Message.self, from: original)
      let reencoded = try encoder.encode(message)
      #expect(
        try jsonObjectsAreEqual(original, reencoded),
        "Fixture \(fixture) changed after a Codable round trip."
      )
    }
  }

  @Test("Signaling fixture fields match GoPeep's envelope")
  func signalingFields() throws {
    let decoder = JSONDecoder()

    let sharerJoin = try decoder.decode(
      GoPeepV1Message.self,
      from: fixtureData("join-sharer")
    )
    #expect(sharerJoin.type == .join)
    #expect(sharerJoin.role == .sharer)
    #expect(sharerJoin.room == "CRISP-FROG-042")
    #expect(sharerJoin.password == "tiger-42")
    #expect(sharerJoin.secret == "0123456789abcdef0123456789abcdef")

    let offer = try decoder.decode(
      GoPeepV1Message.self,
      from: fixtureData("offer")
    )
    #expect(offer.type == .offer)
    #expect(offer.peerID == "viewer-1")
    #expect(offer.sdp.hasPrefix("v=0\r\n"))

    let ice = try decoder.decode(
      GoPeepV1Message.self,
      from: fixtureData("ice")
    )
    #expect(ice.candidate.contains("typ host"))
  }

  @Test("Multi-stream and cursor fixtures retain required values")
  func controlFields() throws {
    let decoder = JSONDecoder()
    let streams = try decoder.decode(
      GoPeepV1Message.self,
      from: fixtureData("streams-info")
    )
    #expect(streams.type == .streamsInfo)
    #expect(streams.streams.count == 2)
    #expect(streams.streams[0].trackID == "video0")
    #expect(streams.streams[0].isFocused)
    #expect(!streams.streams[1].isFocused)

    let cursor = try decoder.decode(
      GoPeepV1Message.self,
      from: fixtureData("cursor-position")
    )
    #expect(cursor.trackID == "video0")
    #expect(cursor.cursorX == 42.5)
    #expect(cursor.cursorY == 67.25)
    #expect(cursor.cursorInView)
  }

  @Test("Cursor messages preserve exact top-left edge values")
  func cursorZeroValuesAreRequired() throws {
    let data = try JSONEncoder().encode(
      GoPeepV1Message(
        type: .cursorPosition,
        streams: [],
        width: 0,
        height: 0,
        cursorX: 0,
        cursorY: 0,
        cursorInView: false
      )
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object.count == 4)
    #expect(object["type"] as? String == "cursor-position")
    #expect(object["cursorX"] as? Double == 0)
    #expect(object["cursorY"] as? Double == 0)
    #expect(object["cursorInView"] as? Bool == false)
  }

  @Test("StreamInfo does not omit false and zero because Go's fields are required")
  func streamInfoRequiredFields() throws {
    let info = GoPeepV1StreamInfo(
      trackID: "video3",
      windowName: "",
      appName: "",
      isFocused: false,
      width: 0,
      height: 0
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any]
    )
    #expect(object.keys.count == 6)
    #expect(object["isFocused"] as? Bool == false)
    #expect(object["width"] as? Int == 0)
    #expect(object["height"] as? Int == 0)
  }

  @Test("Unknown message and role strings remain decodable for forward compatibility")
  func unknownDiscriminators() throws {
    let data = Data(#"{"type":"future-message","role":"future-role"}"#.utf8)
    let decoded = try JSONDecoder().decode(GoPeepV1Message.self, from: data)
    #expect(decoded.type.rawValue == "future-message")
    #expect(decoded.type.intendedTransport == nil)
    #expect(decoded.role?.rawValue == "future-role")
    #expect(try jsonObjectsAreEqual(data, JSONEncoder().encode(decoded)))
  }

  @Test("Known messages are assigned to their actual GoPeep transport")
  func transportClassification() {
    #expect(GoPeepV1MessageType.offer.intendedTransport == .signalingWebSocket)
    #expect(GoPeepV1MessageType.ice.intendedTransport == .signalingWebSocket)
    #expect(GoPeepV1MessageType.streamsInfo.intendedTransport == .controlDataChannel)
    #expect(GoPeepV1MessageType.sharerStopped.intendedTransport == .controlDataChannel)
  }

  @Test("Room reservation response exactly matches the GoPeep HTTP payload")
  func reservationResponse() throws {
    let original = try fixtureData("reserve-room-response")
    let response = try JSONDecoder().decode(
      GoPeepV1RoomReservationResponse.self,
      from: original
    )
    #expect(response.room.rawValue == "CRISP-FROG-042")
    #expect(response.secret.count == 32)
    #expect(try jsonObjectsAreEqual(original, JSONEncoder().encode(response)))
  }

  @Test("Room-code normalization and validation match GoPeep")
  func roomCodeRules() throws {
    #expect(try GoPeepV1RoomCode(rawValue: " crisp-frog-42 ").rawValue == "CRISP-FROG-42")
    #expect(try GoPeepV1RoomCode(rawValue: "crisp-frog-042").rawValue == "CRISP-FROG-042")
    #expect(throws: GoPeepV1ProtocolError.invalidRoomCode("CRISP-FROG-4")) {
      try GoPeepV1RoomCode(rawValue: "CRISP-FROG-4")
    }
    #expect(throws: GoPeepV1ProtocolError.invalidRoomCode("CRISP-FROG-0042")) {
      try GoPeepV1RoomCode(rawValue: "CRISP-FROG-0042")
    }
    #expect(throws: GoPeepV1ProtocolError.invalidRoomCode("CRISP-FROG-AA")) {
      try GoPeepV1RoomCode(rawValue: "CRISP-FROG-AA")
    }
    #expect(throws: GoPeepV1ProtocolError.invalidRoomCode("CRISP-FROG-٤٢")) {
      try GoPeepV1RoomCode(rawValue: "CRISP-FROG-٤٢")
    }
  }

  @Test("GoPeep server defaults and derived endpoints are exact")
  func serverConfiguration() throws {
    let remote = GoPeepV1ServerConfiguration.goPeepRemote
    #expect(remote.signalingServerURL.absoluteString == "wss://gopeep.tineestudio.se")
    #expect(remote.reservationURL.absoluteString == "https://gopeep.tineestudio.se/api/reserve")
    #expect(
      remote.iceServers.map(\.urls) == [
        ["stun:stun.l.google.com:19302"],
        ["stun:stun1.l.google.com:19302"],
        ["stun:stun2.l.google.com:19302"],
      ])

    let room = try GoPeepV1RoomCode(rawValue: "CRISP-FROG-042")
    #expect(
      remote.signalingURL(for: room).absoluteString
        == "wss://gopeep.tineestudio.se/ws/CRISP-FROG-042"
    )
    #expect(
      remote.viewerURL(for: room).absoluteString
        == "https://gopeep.tineestudio.se/CRISP-FROG-042"
    )

    let local = GoPeepV1ServerConfiguration.localDevelopment
    #expect(local.reservationURL.absoluteString == "http://localhost:8080/api/reserve")
  }

  @Test("Invalid dependency-free transport configuration is rejected")
  func invalidConfiguration() throws {
    let badSignalURL = try #require(URL(string: "https://example.com"))
    #expect(throws: GoPeepV1ProtocolError.invalidSignalingServerURL(badSignalURL)) {
      try GoPeepV1ServerConfiguration(signalingServerURL: badSignalURL)
    }
    #expect(throws: GoPeepV1ProtocolError.emptyICEServerURLs) {
      try GoPeepV1ICEServer(urls: [])
    }
  }
}
