import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Clip Live Share encrypted channel")
struct ClipLiveShareCryptoTests {
  @Test("access-code normalization and proof match the browser vector")
  func accessCodeProofVector() throws {
    let session = try ClipLiveShareSessionID(rawValue: "fixture-session")
    let challenge = Data(repeating: 0, count: 32)
    let proof = try ClipLiveShareAccessCodeProof.make(
      accessCode: " abcd ",
      challenge: challenge,
      sessionID: session
    )

    #expect(ClipLiveShareAccessCodeProof.normalize(" abcd \n") == "ABCD")
    #expect(
      ClipLiveShareBase64URL.encode(proof)
        == "GGxWyuqbYQE6wenANE1t82NMizAF8LnO51AUwwOLLR0"
    )
    #expect(
      ClipLiveShareAccessCodeProof.verify(
        proof,
        accessCode: "ABCD",
        challenge: challenge,
        sessionID: session
      )
    )
    #expect(
      !ClipLiveShareAccessCodeProof.verify(
        proof,
        accessCode: "ABCE",
        challenge: challenge,
        sessionID: session
      )
    )
  }

  @Test("host and viewer derive matching directional keys and exchange both ways")
  func directionalRoundTrip() throws {
    let fixture = try Fixture()
    var host = fixture.hostChannel
    var viewer = fixture.viewerChannel
    let challenge = ClipLiveShareInnerMessage.authChallenge(
      try ClipLiveShareAuthChallenge(
        sessionID: fixture.session,
        challenge: Data(repeating: 9, count: 32),
        accessCodeRequired: false
      )
    )

    let hostEnvelope = try host.seal(challenge)
    #expect(try viewer.open(hostEnvelope) == challenge)
    #expect(host.lastOutboundSequence == 1)
    #expect(viewer.lastInboundSequence == 1)

    let response = ClipLiveShareInnerMessage.authResponse(
      try ClipLiveShareAuthResponse(sessionID: fixture.session, proof: nil)
    )
    let viewerEnvelope = try viewer.seal(response)
    #expect(viewerEnvelope.routeID == nil)
    let forwardedViewerEnvelope = try ClipLiveShareRelayEnvelope(
      routeID: fixture.route,
      sequence: viewerEnvelope.sequence,
      nonce: viewerEnvelope.nonce,
      ciphertext: viewerEnvelope.ciphertext
    )
    #expect(try host.open(forwardedViewerEnvelope) == response)
    #expect(viewer.lastOutboundSequence == 1)
    #expect(host.lastInboundSequence == 1)
  }

  @Test("duplicate, skipped, and decreasing sequences are rejected")
  func replayProtection() throws {
    let fixture = try Fixture()
    var host = fixture.hostChannel
    var viewer = fixture.viewerChannel
    let message = try fixture.authResult()
    let first = try host.seal(message, nonce: Data(repeating: 0xA0, count: 12))
    #expect(try viewer.open(first) == message)

    #expect(throws: ClipLiveShareProtocolError.invalidSequence(expected: 2, actual: 1)) {
      try viewer.open(first)
    }

    let second = try host.seal(message, nonce: Data(repeating: 0xA1, count: 12))
    let skipped = try ClipLiveShareRelayEnvelope(
      routeID: second.routeID,
      sequence: 3,
      nonce: second.nonce,
      ciphertext: second.ciphertext
    )
    #expect(throws: ClipLiveShareProtocolError.invalidSequence(expected: 2, actual: 3)) {
      try viewer.open(skipped)
    }
    #expect(try viewer.open(second) == message)
  }

  @Test("tamper, wrong direction, and route substitution fail authentication")
  func tamperAndRouteBinding() throws {
    let fixture = try Fixture()
    var host = fixture.hostChannel
    var viewer = fixture.viewerChannel
    let message = try fixture.authResult()
    let envelope = try host.seal(message, nonce: Data(repeating: 0xB0, count: 12))

    var damagedCiphertext = envelope.ciphertext
    damagedCiphertext[damagedCiphertext.startIndex] ^= 1
    let tampered = try ClipLiveShareRelayEnvelope(
      routeID: envelope.routeID,
      sequence: envelope.sequence,
      nonce: envelope.nonce,
      ciphertext: damagedCiphertext
    )
    #expect(throws: ClipLiveShareProtocolError.authenticationFailed) {
      try viewer.open(tampered)
    }
    #expect(viewer.lastInboundSequence == 0)

    var wrongDirection = fixture.hostChannel
    #expect(throws: ClipLiveShareProtocolError.authenticationFailed) {
      try wrongDirection.open(envelope)
    }

    let otherRoute = try ClipLiveShareRouteID(bytes: Data(repeating: 8, count: 16))
    let substituted = try ClipLiveShareRelayEnvelope(
      routeID: otherRoute,
      sequence: envelope.sequence,
      nonce: envelope.nonce,
      ciphertext: envelope.ciphertext
    )
    #expect(
      throws: ClipLiveShareProtocolError.routeMismatch(
        expected: fixture.route,
        actual: otherRoute
      )
    ) {
      try viewer.open(substituted)
    }

    #expect(try viewer.open(envelope) == message)
  }

  @Test("a fresh route derives new keys and resets both counters")
  func freshRoute() throws {
    let fixture = try Fixture()
    let secondRoute = try ClipLiveShareRouteID(bytes: Data(repeating: 5, count: 16))
    let secondHost = try ClipLiveShareEncryptedChannel(
      host: fixture.roomIdentity,
      viewerPublicKey: fixture.viewerIdentity.publicKey,
      room: fixture.room,
      routeID: secondRoute
    )

    #expect(
      fixture.hostChannel.derivedKeyBytes(for: .hostToViewer)
        != secondHost.derivedKeyBytes(for: .hostToViewer)
    )
    #expect(secondHost.lastOutboundSequence == 0)
    #expect(secondHost.lastInboundSequence == 0)
  }

  @Test("P-256, HKDF, JSON, and AES-GCM deterministic vector")
  func deterministicEncryptionVector() throws {
    let fixture = try Fixture()
    var host = fixture.hostChannel
    let message = try fixture.authResult()
    let envelope = try host.seal(
      message,
      nonce: Data([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB])
    )

    #expect(
      fixture.roomIdentity.publicKey.rawValue
        == "BG_wO5SSQc4drdQ1GeaWDgqFtBppoFwygQOqK84VlMoWPE91OlW_AdxT9sCwx-7ni0DG_30lqW4igrmJzvccFEo"
    )
    #expect(
      fixture.viewerIdentity.publicKey.rawValue
        == "BFUPRxAD89-Xw99QaseX9nIfsaH7e49vg9IkSYplyI4kE2CT1wEuUJpzcVy9CwCjzA_0tcAbP_oZarH7MnA2uOY"
    )
    #expect(
      fixture.hostChannel.derivedKeyBytes(for: .hostToViewer).hex
        == "1a2db081d105ec0c95e7e9f1226a6732cb1e541fcc3fe4186ac7e3ec96d78de4"
    )
    #expect(
      fixture.hostChannel.derivedKeyBytes(for: .viewerToHost).hex
        == "1ae5cae8606f9d8626c13708d699cc5fc89ea155f9d3ba1bafbb372eee7cc690"
    )
    #expect(
      ClipLiveShareBase64URL.encode(envelope.ciphertext)
        == "9JVD38RQnClfiXquPZMiWfXvNU-sE4fTg07AgPczQd7ZMq7Q-uN75i0yciFsuYhMxaZt2KQqkMU1UXxBzLmRL-NFL2uNspEeZigvLFAFcNwh56BF2l_px6Ncs26U44c"
    )
    #expect(envelope.sequence == 1)
    #expect(envelope.routeID == fixture.route)
  }
}

private struct Fixture {
  let roomIdentity: ClipLiveShareRoomIdentity
  let viewerIdentity: ClipLiveShareViewerIdentity
  let room: ClipLiveShareRoomName
  let route: ClipLiveShareRouteID
  let session: ClipLiveShareSessionID
  let hostChannel: ClipLiveShareEncryptedChannel
  let viewerChannel: ClipLiveShareEncryptedChannel

  init() throws {
    roomIdentity = try ClipLiveShareRoomIdentity(
      privateKeyRawRepresentation: Data(repeating: 1, count: 32)
    )
    viewerIdentity = try ClipLiveShareViewerIdentity(
      privateKeyRawRepresentation: Data(repeating: 2, count: 32)
    )
    room = try ClipLiveShareRoomName(rawValue: "CALM-OTTER-042")
    route = try ClipLiveShareRouteID(bytes: Data(0...15))
    session = try ClipLiveShareSessionID(rawValue: "fixture-session")
    hostChannel = try ClipLiveShareEncryptedChannel(
      host: roomIdentity,
      viewerPublicKey: viewerIdentity.publicKey,
      room: room,
      routeID: route
    )
    viewerChannel = try ClipLiveShareEncryptedChannel(
      viewer: viewerIdentity,
      roomPublicKey: roomIdentity.publicKey,
      room: room,
      routeID: route
    )
  }

  func authResult() throws -> ClipLiveShareInnerMessage {
    .authResult(try ClipLiveShareAuthResult(sessionID: session, allowed: true))
  }
}

private extension Data {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}
