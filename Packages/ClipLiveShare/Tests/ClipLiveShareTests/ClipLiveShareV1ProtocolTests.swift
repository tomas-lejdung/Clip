import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Clip Live Share v1 protocol")
struct ClipLiveShareV1ProtocolTests {
  @Test("room names normalize, validate, and are generated entirely client-side")
  func roomNames() throws {
    #expect(try ClipLiveShareRoomName(rawValue: " calm-otter-042 \n").rawValue == "CALM-OTTER-042")

    for invalid in ["AB", "-ROOM", "ROOM-", "room name", "RØØM", String(repeating: "A", count: 65)] {
      #expect(throws: ClipLiveShareProtocolError.self) {
        try ClipLiveShareRoomName(rawValue: invalid)
      }
    }

    var generator = SeededRandomNumberGenerator(state: 42)
    var secondGenerator = SeededRandomNumberGenerator(state: 42)
    let generated = ClipLiveShareRoomName.random(using: &generator)
    #expect(generated == ClipLiveShareRoomName.random(using: &secondGenerator))
    #expect(try ClipLiveShareRoomName(rawValue: generated.rawValue) == generated)
  }

  @Test("owner and route secrets use exact canonical base64url resources")
  func binaryIdentifiers() throws {
    let owner = try ClipLiveShareOwnerToken(bytes: Data(repeating: 0, count: 32))
    #expect(owner.rawValue == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    #expect(owner.authorizationHeaderValue == "Bearer \(owner.rawValue)")
    #expect(owner.sha256Digest.hex == "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925")
    #expect(try ClipLiveShareOwnerToken(rawValue: owner.rawValue) == owner)

    let route = try ClipLiveShareRouteID(bytes: Data(0...15))
    #expect(route.rawValue == "AAECAwQFBgcICQoLDA0ODw")
    #expect(try ClipLiveShareRouteID(rawValue: route.rawValue) == route)

    #expect(throws: ClipLiveShareProtocolError.invalidOwnerToken) {
      try ClipLiveShareOwnerToken(bytes: Data(repeating: 0, count: 31))
    }
    #expect(throws: ClipLiveShareProtocolError.invalidRouteID) {
      try ClipLiveShareRouteID(rawValue: "AA")
    }
    #expect(ClipLiveShareBase64URL.decode("AA==") == nil)
    #expect(ClipLiveShareBase64URL.decode("+/8") == nil)
  }

  @Test("official and development endpoints derive all v1 resources")
  func endpoints() throws {
    let room = try ClipLiveShareRoomName(rawValue: "CALM-OTTER-042")
    #expect(ClipLiveShareServerEndpoint.official.rootURL.absoluteString == "https://clip.tineestudio.se")
    #expect(
      ClipLiveShareServerEndpoint.official.capabilitiesURL.absoluteString
        == "https://clip.tineestudio.se/.well-known/clip-live-share"
    )
    #expect(
      ClipLiveShareServerEndpoint.official.advertiseRoomURL(room).absoluteString
        == "https://clip.tineestudio.se/api/v1/rooms/CALM-OTTER-042"
    )
    #expect(
      ClipLiveShareServerEndpoint.official.standardHostWebSocketURL(room).absoluteString
        == "wss://clip.tineestudio.se/api/v1/rooms/CALM-OTTER-042/host"
    )
    #expect(
      ClipLiveShareServerEndpoint.localDevelopment.standardViewerWebSocketURL(room).absoluteString
        == "ws://localhost:8080/api/v1/rooms/CALM-OTTER-042/viewer"
    )
    #expect(
      try ClipLiveShareServerEndpoint(userInput: "WSS://EXAMPLE.com/").rootURL.absoluteString
        == "https://example.com"
    )

    #expect(throws: ClipLiveShareProtocolError.self) {
      try ClipLiveShareServerEndpoint(userInput: "http://example.com")
    }
    #expect(throws: ClipLiveShareProtocolError.self) {
      try ClipLiveShareServerEndpoint(userInput: "https://example.com/subpath")
    }

    let encoded = try JSONEncoder().encode(ClipLiveShareServerEndpoint.official)
    #expect(
      try JSONDecoder().decode(ClipLiveShareServerEndpoint.self, from: encoded)
        == .official
    )
    for persisted in [
      #"{"rootURL":"http://example.com"}"#,
      #"{"rootURL":"https://example.com/subpath"}"#,
      #"{"rootURL":"https://user:secret@example.com"}"#,
    ] {
      #expect(throws: ClipLiveShareProtocolError.self) {
        try JSONDecoder().decode(
          ClipLiveShareServerEndpoint.self,
          from: Data(persisted.utf8)
        )
      }
    }
  }

  @Test("capabilities decode the authoritative well-known schema")
  func capabilities() throws {
    let json = try fixtureData("capabilities-v1")
    let decoded = try JSONDecoder().decode(ClipLiveShareCapabilities.self, from: json)
    #expect(decoded == .v1Default)
    #expect(try jsonObjectsAreEqual(json, JSONEncoder().encode(decoded)))

    let incompatible = Data(
      #"{"protocol":"other","versions":[1],"serverVersion":"development","viewerPathTemplate":"/{room}","hostWebSocketPathTemplate":"/api/v1/rooms/{room}/host","viewerWebSocketPathTemplate":"/api/v1/rooms/{room}/viewer","iceServers":[],"limits":{"maximumMessageBytes":262144,"maximumPendingViewersPerRoom":8}}"#.utf8
    )
    #expect(throws: ClipLiveShareProtocolError.self) {
      try JSONDecoder().decode(ClipLiveShareCapabilities.self, from: incompatible)
    }
  }

  @Test("room advertisement request and response have stable field names")
  func advertisementSchema() throws {
    let room = try ClipLiveShareRoomName(rawValue: "CALM-OTTER-042")
    let owner = try ClipLiveShareOwnerToken(bytes: Data(repeating: 7, count: 32))
    let request = ClipLiveShareAdvertiseRoomRequest(ownerToken: owner)
    let response = try ClipLiveShareRoomAdvertisement(room: room, leaseDurationSeconds: 30)

    let requestObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    )
    let responseObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
    )
    #expect(requestObject["ownerToken"] as? String == owner.rawValue)
    #expect(responseObject["room"] as? String == room.rawValue)
    #expect(responseObject["leaseDurationSeconds"] as? Int == 30)
  }

  @Test("viewer fragment round-trips without exposing key material to HTTP")
  func viewerFragment() throws {
    let identity = try ClipLiveShareRoomIdentity(
      privateKeyRawRepresentation: Data(repeating: 1, count: 32)
    )
    let fragment = try ClipLiveShareViewerFragment(publicKey: identity.publicKey)
    let base = URL(string: "https://clip.example/CALM-OTTER-042")!
    let url = try fragment.adding(to: base)

    #expect(url.absoluteString.hasPrefix("https://clip.example/CALM-OTTER-042#v=1&key="))
    #expect(try ClipLiveShareViewerFragment(url: url) == fragment)
    #expect(url.path == "/CALM-OTTER-042")
    #expect(url.query == nil)
    #expect(throws: ClipLiveShareProtocolError.self) {
      try ClipLiveShareViewerFragment(fragment: "v=2&key=\(identity.publicKey.rawValue)")
    }
  }

  @Test("outer routing messages round-trip with no session plaintext")
  func outerMessages() throws {
    let identity = try ClipLiveShareViewerIdentity(
      privateKeyRawRepresentation: Data(repeating: 2, count: 32)
    )
    let route = try ClipLiveShareRouteID(bytes: Data(0...15))
    let messages: [ClipLiveShareOuterMessage] = [
      .viewerHello(try ClipLiveShareViewerHello(viewerKey: identity.publicKey)),
      .routeOpened(ClipLiveShareRouteOpened(routeID: route, viewerKey: identity.publicKey)),
      .routeOpened(ClipLiveShareRouteOpened(routeID: route)),
      .relay(
        try ClipLiveShareRelayEnvelope(
          routeID: route,
          sequence: 1,
          nonce: Data(repeating: 3, count: 12),
          ciphertext: Data(repeating: 4, count: 16)
        )
      ),
      .routeClosed(try ClipLiveShareRouteClosed(routeID: route, reason: "left")),
      .closeRoute(route),
      .hostUnavailable,
      .error(try ClipLiveShareProtocolFailure(code: "room-full", message: "Try again later.")),
    ]

    for message in messages {
      let encoded = try ClipLiveShareMessageCodec.encodeOuter(message)
      #expect(try ClipLiveShareMessageCodec.decodeOuter(encoded) == message)
      let text = try #require(String(data: encoded, encoding: .utf8))
      #expect(!text.contains("sdp"))
      #expect(!text.contains("candidate"))
      #expect(!text.contains("password"))
    }
  }

  @Test("all encrypted inner message schemas round-trip")
  func innerMessages() throws {
    let session = try ClipLiveShareSessionID(rawValue: "fixture-session")
    let negotiation = try ClipLiveShareNegotiationID(rawValue: "negotiation-1")
    let streamID = try ClipLiveShareStreamID(rawValue: "opaque-stream")
    let trackID = try ClipLiveShareMediaTrackID(rawValue: "opaque-track")
    let descriptor = try ClipLiveShareStreamDescriptor(
      id: streamID,
      mediaTrackID: trackID,
      active: true,
      focused: true,
      appName: "Arc",
      windowName: "Documentation",
      width: 1_920,
      height: 1_080,
      order: 0
    )
    let description = try ClipLiveShareSessionDescription(
      sessionID: session,
      negotiationID: negotiation,
      sdp: "v=0\r\n"
    )
    let candidate = try ClipLiveShareICECandidate(
      sessionID: session,
      negotiationID: negotiation,
      candidate: "candidate:fixture",
      sdpMid: "0",
      sdpMLineIndex: 0
    )
    let messages: [ClipLiveShareInnerMessage] = [
      .authChallenge(
        try ClipLiveShareAuthChallenge(
          sessionID: session,
          challenge: Data(repeating: 0, count: 32),
          accessCodeRequired: true
        )
      ),
      .authResponse(
        try ClipLiveShareAuthResponse(sessionID: session, proof: Data(repeating: 1, count: 32))
      ),
      .authResult(try ClipLiveShareAuthResult(sessionID: session, allowed: true)),
      .offer(description),
      .answer(description),
      .ice(candidate),
      .manifest(try ClipLiveShareStreamManifest(sessionID: session, streams: [descriptor])),
      .streamState(ClipLiveShareStreamState(sessionID: session, streamID: streamID, active: false)),
      .focus(ClipLiveShareFocus(sessionID: session, streamID: nil)),
      .geometry(
        try ClipLiveShareGeometry(sessionID: session, streamID: streamID, width: 1_280, height: 720)
      ),
      .cursor(
        try ClipLiveShareCursor(sessionID: session, streamID: streamID, x: 0, y: 100, inView: true)
      ),
      .sharingState(ClipLiveShareSharingState(sessionID: session, sharing: true)),
      .systemAudioState(ClipLiveShareSystemAudioState(sessionID: session, enabled: true)),
      .codecOffer(description),
      .codecAnswer(description),
      .codecICE(candidate),
      .sessionClosing(try ClipLiveShareSessionClosing(sessionID: session, reason: "host-ended")),
      .error(
        ClipLiveShareInnerProtocolFailure(
          sessionID: session,
          failure: try ClipLiveShareProtocolFailure(code: "auth-failed", message: "Denied")
        )
      ),
    ]

    for message in messages {
      let encoded = try ClipLiveShareMessageCodec.encodeInner(message)
      #expect(try ClipLiveShareMessageCodec.decodeInner(encoded) == message)
      let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      )
      #expect(object["version"] as? Int == 1)
      #expect(object["sessionId"] as? String == session.rawValue)
      #expect(object["type"] as? String == message.type)
    }
  }

  @Test("manifest and message resource bounds are enforced before use")
  func resourceBounds() throws {
    let session = try ClipLiveShareSessionID(rawValue: "fixture-session")
    let descriptor = try ClipLiveShareStreamDescriptor(
      id: ClipLiveShareStreamID(rawValue: "stream"),
      mediaTrackID: ClipLiveShareMediaTrackID(rawValue: "track"),
      active: true,
      focused: true,
      appName: "App",
      windowName: "Window",
      width: 100,
      height: 100,
      order: 0
    )
    #expect(throws: ClipLiveShareProtocolError.self) {
      try ClipLiveShareStreamManifest(sessionID: session, streams: [descriptor, descriptor])
    }
    #expect(throws: ClipLiveShareProtocolError.messageTooLarge(maximum: 4, actual: 5)) {
      try ClipLiveShareMessageCodec.decodeOuter(Data("12345".utf8), maximumBytes: 4)
    }

    var budget = try ClipLiveShareCandidateBudget(maximum: 2)
    try budget.accept()
    try budget.accept()
    #expect(throws: ClipLiveShareProtocolError.self) {
      try budget.accept()
    }
  }

  @Test("stream source point dimensions round-trip and remain legacy compatible")
  func streamSourcePointDimensions() throws {
    let descriptor = try ClipLiveShareStreamDescriptor(
      id: ClipLiveShareStreamID(rawValue: "stream"),
      mediaTrackID: ClipLiveShareMediaTrackID(rawValue: "track"),
      active: true,
      focused: true,
      appName: "App",
      windowName: "Window",
      width: 2_000,
      height: 1_200,
      order: 0,
      sourcePointWidth: 1_000,
      sourcePointHeight: 600
    )
    let encoded = try JSONEncoder().encode(descriptor)
    #expect(
      try JSONDecoder().decode(ClipLiveShareStreamDescriptor.self, from: encoded)
        == descriptor
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(object["sourcePointWidth"] as? Int == 1_000)
    #expect(object["sourcePointHeight"] as? Int == 600)

    let legacy = Data(
      #"{"id":"stream","mediaTrackId":"track","active":true,"focused":true,"appName":"App","windowName":"Window","width":2000,"height":1200,"order":0}"#.utf8
    )
    let legacyDescriptor = try JSONDecoder().decode(
      ClipLiveShareStreamDescriptor.self,
      from: legacy
    )
    #expect(legacyDescriptor.sourcePointWidth == nil)
    #expect(legacyDescriptor.sourcePointHeight == nil)
    let legacyReencoded = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyDescriptor))
        as? [String: Any]
    )
    #expect(legacyReencoded["sourcePointWidth"] == nil)
    #expect(legacyReencoded["sourcePointHeight"] == nil)
  }

  @Test("stream source point dimensions require a complete in-bounds pair")
  func invalidStreamSourcePointDimensions() throws {
    let id = try ClipLiveShareStreamID(rawValue: "stream")
    let trackID = try ClipLiveShareMediaTrackID(rawValue: "track")

    let invalidDimensions: [(Int?, Int?)] = [
      (1_000, nil), (nil, 600), (0, 600), (1_000, 32_769),
    ]
    for dimensions in invalidDimensions {
      #expect(throws: ClipLiveShareProtocolError.self) {
        try ClipLiveShareStreamDescriptor(
          id: id,
          mediaTrackID: trackID,
          active: true,
          focused: true,
          appName: "App",
          windowName: "Window",
          width: 2_000,
          height: 1_200,
          order: 0,
          sourcePointWidth: dimensions.0,
          sourcePointHeight: dimensions.1
        )
      }
    }

    let incompleteWire = Data(
      #"{"id":"stream","mediaTrackId":"track","active":true,"focused":true,"appName":"App","windowName":"Window","width":2000,"height":1200,"order":0,"sourcePointWidth":1000}"#.utf8
    )
    #expect(throws: ClipLiveShareProtocolError.self) {
      try JSONDecoder().decode(ClipLiveShareStreamDescriptor.self, from: incompleteWire)
    }
  }

  @Test("maximum inner payload retains room for the worst-case outer relay envelope")
  func relayEnvelopeHeadroom() throws {
    let route = try ClipLiveShareRouteID(bytes: Data(repeating: 0xFF, count: 16))
    let relay = try ClipLiveShareRelayEnvelope(
      routeID: route,
      sequence: .max,
      nonce: Data(repeating: 0xFF, count: 12),
      ciphertext: Data(
        repeating: 0xFF,
        count: ClipLiveShareV1.maximumInnerMessageBytes + 16
      )
    )
    let encoded = try ClipLiveShareMessageCodec.encodeOuter(.relay(relay))

    #expect(encoded.count <= ClipLiveShareV1.maximumWebSocketMessageBytes)
    #expect(ClipLiveShareV1.maximumInnerMessageBytes == 196_400)
  }
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}

private extension Data {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
