import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Clip Live Share native v2 identity protocol")
struct ClipLiveShareNativeV2Tests {
  @Test("persistent identity and rendezvous values are canonical and high entropy")
  func identityAndRendezvousValues() throws {
    let fixture = try NativeV2Fixture()

    #expect(fixture.hostSigner.publicKey.x963Representation.count == 65)
    #expect(fixture.hostSigner.publicKey.fingerprint.bytes.count == 32)
    #expect(
      fixture.hostSigner.publicKey.fingerprint.rawValue
        == "JWsb4ydF0dHJ1JEhzIe8RRxPLfp1bYm0yRCvrrYliuA"
    )
    #expect(fixture.rendezvousID.bytes.count == 32)
    #expect(fixture.rendezvousID.rawValue == "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8")
    #expect(
      try ClipLiveShareRendezvousID(rawValue: fixture.rendezvousID.rawValue)
        == fixture.rendezvousID
    )
    #expect(throws: ClipLiveShareNativeV2Error.self) {
      try ClipLiveShareRendezvousID(bytes: Data(repeating: 0, count: 16))
    }
    #expect(throws: ClipLiveShareProtocolError.invalidBase64URL) {
      try ClipLiveShareIdentityFingerprint(rawValue: "not+canonical")
    }
  }

  @Test("signed session descriptor has a stable canonical vector and JSON schema")
  func sessionDescriptorCanonicalVector() throws {
    let fixture = try NativeV2Fixture()
    let signed = try ClipLiveShareSignedNativeSessionDescriptor(
      signing: fixture.sessionDescriptor,
      with: fixture.hostSigner
    )

    try signed.verify(
      expectedIdentity: fixture.hostSigner.publicKey,
      expectedContext: fixture.sessionDescriptor.rendezvousContext,
      at: fixture.now
    )
    #expect(
      ClipLiveShareBase64URL.encode(fixture.sessionDescriptor.canonicalRepresentation)
        == "AAAALGNsaXAtbGl2ZS1zaGFyZS1uYXRpdmUtdjIvc2Vzc2lvbi1kZXNjcmlwdG9yAAAAAAAAAAIAAAAbaHR0cHM6Ly9jbGlwLnRpbmVlc3R1ZGlvLnNlAAAADkNBTE0tT1RURVItMDQyAAAAICAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4_AAAAQQRv8DuUkkHOHa3UNRnmlg4KhbQaaaBcMoEDqivOFZTKFjxPdTpVvwHcU_bAsMfu54tAxv99JaluIoK5ic73HBRKAAAAQQRzED7DCzzPV9quCOk1NK7xRKNZQM9ru6EqDPfL1dZaZNgsjJnp08RfkkW6myeYLJrqjsHblLGcRHlZQsDrIqoyAAAADm5hdGl2ZS1zZXNzaW9uAAABl3Qg3AAAAAGXdCKwwAAAAAAAAAAH"
    )
    #expect(
      fixture.sessionDescriptor.digest.rawValue
        == "6WgAIyWivQsjOvxJPC1pFA6uusH6_4NIVjo3VWPm4yo"
    )

    let encoded = try ClipLiveShareNativeV2MessageCodec.encode(signed)
    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(text.contains("\"version\":2"))
    #expect(text.contains("\"stateRevision\":7"))
    #expect(!text.contains("private"))
    let decoded = try ClipLiveShareNativeV2MessageCodec.decode(
      ClipLiveShareSignedNativeSessionDescriptor.self,
      from: encoded
    )
    #expect(decoded == signed)
    #expect(
      decoded.descriptor.canonicalRepresentation
        == fixture.sessionDescriptor.canonicalRepresentation)
    #expect(
      throws: ClipLiveShareProtocolError.messageTooLarge(
        maximum: 1,
        actual: encoded.count
      )
    ) {
      try ClipLiveShareNativeV2MessageCodec.decode(
        ClipLiveShareSignedNativeSessionDescriptor.self,
        from: encoded,
        maximumBytes: 1
      )
    }
  }

  @Test("session signatures reject tamper, identity substitution, expiry, and future use")
  func sessionDescriptorSecurity() throws {
    let fixture = try NativeV2Fixture()
    let signed = try ClipLiveShareSignedNativeSessionDescriptor(
      signing: fixture.sessionDescriptor,
      with: fixture.hostSigner
    )

    let alteredDescriptors = try [
      fixture.makeSessionDescriptor(
        endpoint: ClipLiveShareServerEndpoint(userInput: "https://other.example")
      ),
      fixture.makeSessionDescriptor(
        room: ClipLiveShareRoomName(rawValue: "OTHER-ROOM-001")
      ),
      fixture.makeSessionDescriptor(
        rendezvousID: ClipLiveShareRendezvousID(bytes: Data(repeating: 0x91, count: 32))
      ),
      fixture.makeSessionDescriptor(
        roomPublicKey: ClipLiveShareRoomIdentity().publicKey
      ),
      fixture.makeSessionDescriptor(
        sessionID: ClipLiveShareSessionID(rawValue: "another-session")
      ),
      fixture.makeSessionDescriptor(
        expiresAt: fixture.issuedAt.adding(milliseconds: 119_999)
      ),
      fixture.makeSessionDescriptor(
        stateRevision: ClipLiveShareStateRevision(rawValue: 8)
      ),
    ]

    for descriptor in alteredDescriptors {
      let tampered = ClipLiveShareSignedNativeSessionDescriptor(
        descriptor: descriptor,
        signature: signed.signature
      )
      #expect(throws: ClipLiveShareNativeV2Error.invalidSignature) {
        try tampered.verify(
          expectedIdentity: fixture.hostSigner.publicKey,
          expectedContext: descriptor.rendezvousContext,
          at: fixture.now
        )
      }
    }

    let validOtherContextDescriptor = try fixture.makeSessionDescriptor(
      room: ClipLiveShareRoomName(rawValue: "OTHER-ROOM-002")
    )
    let validOtherContext = try ClipLiveShareSignedNativeSessionDescriptor(
      signing: validOtherContextDescriptor,
      with: fixture.hostSigner
    )
    #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
      try validOtherContext.verify(
        expectedIdentity: fixture.hostSigner.publicKey,
        expectedContext: fixture.sessionDescriptor.rendezvousContext,
        at: fixture.now
      )
    }

    #expect(throws: ClipLiveShareNativeV2Error.identityMismatch) {
      try signed.verify(
        expectedIdentity: fixture.viewerSigner.publicKey,
        expectedContext: fixture.sessionDescriptor.rendezvousContext,
        at: fixture.now
      )
    }
    let toleratedClockSkew = try ClipLiveShareNativeTimestamp(
      millisecondsSince1970: fixture.issuedAt.millisecondsSince1970
        - ClipLiveShareNativeV2.maximumClockSkewMilliseconds
    )
    try signed.verify(
      expectedIdentity: fixture.hostSigner.publicKey,
      expectedContext: fixture.sessionDescriptor.rendezvousContext,
      at: toleratedClockSkew
    )
    #expect(throws: ClipLiveShareNativeV2Error.notYetValid) {
      try signed.verify(
        expectedIdentity: fixture.hostSigner.publicKey,
        expectedContext: fixture.sessionDescriptor.rendezvousContext,
        at: try ClipLiveShareNativeTimestamp(
          millisecondsSince1970: fixture.issuedAt.millisecondsSince1970
            - ClipLiveShareNativeV2.maximumClockSkewMilliseconds - 1
        )
      )
    }
    #expect(throws: ClipLiveShareNativeV2Error.expired) {
      try signed.verify(
        expectedIdentity: fixture.hostSigner.publicKey,
        expectedContext: fixture.sessionDescriptor.rendezvousContext,
        at: fixture.expiresAt
      )
    }
    #expect(throws: ClipLiveShareNativeV2Error.invalidLifetime) {
      try fixture.makeSessionDescriptor(
        expiresAt: fixture.issuedAt.adding(
          milliseconds: ClipLiveShareNativeV2.maximumSessionDescriptorLifetimeMilliseconds + 1
        )
      )
    }
  }

  @Test("session descriptor replay is accepted exactly once")
  func sessionReplay() throws {
    let fixture = try NativeV2Fixture()
    let signed = try ClipLiveShareSignedNativeSessionDescriptor(
      signing: fixture.sessionDescriptor,
      with: fixture.hostSigner
    )
    var guardState = try ClipLiveShareNativeReplayGuard(maximumRecords: 2)

    try guardState.accept(
      signed,
      expectedIdentity: fixture.hostSigner.publicKey,
      expectedContext: fixture.sessionDescriptor.rendezvousContext,
      at: fixture.now
    )
    #expect(throws: ClipLiveShareNativeV2Error.replayed) {
      try guardState.accept(
        signed,
        expectedIdentity: fixture.hostSigner.publicKey,
        expectedContext: fixture.sessionDescriptor.rendezvousContext,
        at: fixture.now
      )
    }
  }

  @Test("viewer proof binds route, session descriptor, ephemeral key, identity, and revision")
  func viewerProofSecurity() throws {
    let fixture = try NativeV2Fixture()
    let challenge = try fixture.makeViewerChallenge()
    let proof = try ClipLiveShareSignedNativeViewerProof(
      signing: challenge,
      with: fixture.viewerSigner
    )

    try proof.verify(
      expectedChallenge: challenge,
      expectedIdentity: fixture.viewerSigner.publicKey,
      at: fixture.now
    )

    let otherRoute = try ClipLiveShareRouteID(bytes: Data(repeating: 0xF0, count: 16))
    let wrongRoute = try fixture.makeViewerChallenge(routeID: otherRoute)
    #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
      try proof.verify(
        expectedChallenge: wrongRoute,
        expectedIdentity: fixture.viewerSigner.publicKey,
        at: fixture.now
      )
    }

    let changedChallenge = try fixture.makeViewerChallenge(
      challenge: Data(repeating: 0xCC, count: 32)
    )
    let tampered = ClipLiveShareSignedNativeViewerProof(
      challenge: changedChallenge,
      viewerIdentity: proof.viewerIdentity,
      signature: proof.signature
    )
    #expect(throws: ClipLiveShareNativeV2Error.invalidSignature) {
      try tampered.verify(
        expectedChallenge: changedChallenge,
        expectedIdentity: fixture.viewerSigner.publicKey,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV2Error.identityMismatch) {
      try proof.verify(
        expectedChallenge: challenge,
        expectedIdentity: fixture.otherSigner.publicKey,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV2Error.expired) {
      try proof.verify(
        expectedChallenge: challenge,
        expectedIdentity: fixture.viewerSigner.publicKey,
        at: challenge.expiresAt
      )
    }

    var replayGuard = try ClipLiveShareNativeReplayGuard()
    try replayGuard.accept(
      proof,
      expectedChallenge: challenge,
      expectedIdentity: fixture.viewerSigner.publicKey,
      at: fixture.now
    )
    #expect(throws: ClipLiveShareNativeV2Error.replayed) {
      try replayGuard.accept(
        proof,
        expectedChallenge: challenge,
        expectedIdentity: fixture.viewerSigner.publicKey,
        at: fixture.now
      )
    }
  }

  @Test("native control hello identifies capabilities and rejects tamper or replay")
  func nativeControlHello() throws {
    let fixture = try NativeV2Fixture()
    let hello = try ClipLiveShareNativeControlHello(
      sessionID: fixture.sessionID,
      viewerIdentity: fixture.viewerSigner.publicKey,
      deviceName: "Viewer Mac",
      issuedAt: fixture.issuedAt,
      expiresAt: fixture.issuedAt.adding(milliseconds: 30_000)
    )
    let signed = try ClipLiveShareSignedNativeControlHello(
      signing: hello,
      with: fixture.viewerSigner
    )

    try signed.verify(expectedSessionID: fixture.sessionID, at: fixture.now)
    try signed.verify(
      expectedSessionID: fixture.sessionID,
      expectedIdentity: fixture.viewerSigner.publicKey,
      at: fixture.now
    )
    #expect(
      hello.capabilities == [
        ClipLiveShareNativeControlCapability.streamLifecycle,
        .friends,
      ]
    )

    let encoded = try ClipLiveShareNativeV2MessageCodec.encode(signed)
    let object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(object["version"] as? Int == 2)
    #expect(object["type"] as? String == "native-control-hello")
    let payload = try #require(object["payload"] as? [String: Any])
    #expect(payload["sessionId"] as? String == fixture.sessionID.rawValue)
    #expect(
      payload["capabilities"] as? [String] == ["friends", "stream-lifecycle"]
    )
    #expect(
      try ClipLiveShareNativeV2MessageCodec.decode(
        ClipLiveShareSignedNativeControlHello.self,
        from: encoded
      ) == signed
    )

    let changedDevice = try ClipLiveShareNativeControlHello(
      sessionID: hello.sessionID,
      viewerIdentity: hello.viewerIdentity,
      deviceName: "Changed Device",
      capabilities: hello.capabilities,
      issuedAt: hello.issuedAt,
      expiresAt: hello.expiresAt
    )
    let tamperedDevice = ClipLiveShareSignedNativeControlHello(
      hello: changedDevice,
      signature: signed.signature
    )
    #expect(throws: ClipLiveShareNativeV2Error.invalidSignature) {
      try tamperedDevice.verify(expectedSessionID: fixture.sessionID, at: fixture.now)
    }

    let changedCapabilities = try ClipLiveShareNativeControlHello(
      sessionID: hello.sessionID,
      viewerIdentity: hello.viewerIdentity,
      deviceName: hello.deviceName,
      capabilities: [.streamLifecycle],
      issuedAt: hello.issuedAt,
      expiresAt: hello.expiresAt
    )
    let tamperedCapabilities = ClipLiveShareSignedNativeControlHello(
      hello: changedCapabilities,
      signature: signed.signature
    )
    #expect(throws: ClipLiveShareNativeV2Error.invalidSignature) {
      try tamperedCapabilities.verify(expectedSessionID: fixture.sessionID, at: fixture.now)
    }

    #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
      try signed.verify(
        expectedSessionID: ClipLiveShareSessionID(rawValue: "another-session"),
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV2Error.identityMismatch) {
      try signed.verify(
        expectedSessionID: fixture.sessionID,
        expectedIdentity: fixture.otherSigner.publicKey,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV2Error.expired) {
      try signed.verify(expectedSessionID: fixture.sessionID, at: hello.expiresAt)
    }
    #expect(throws: ClipLiveShareProtocolError.self) {
      try ClipLiveShareNativeControlHello(
        sessionID: fixture.sessionID,
        viewerIdentity: fixture.viewerSigner.publicKey,
        deviceName: "Viewer Mac",
        capabilities: [],
        issuedAt: fixture.issuedAt,
        expiresAt: hello.expiresAt
      )
    }

    var duplicateCapabilityObject = object
    var duplicateCapabilityPayload = payload
    duplicateCapabilityPayload["capabilities"] = ["friends", "friends"]
    duplicateCapabilityObject["payload"] = duplicateCapabilityPayload
    let duplicateCapabilityWire = try JSONSerialization.data(
      withJSONObject: duplicateCapabilityObject
    )
    #expect(throws: ClipLiveShareProtocolError.self) {
      try ClipLiveShareNativeV2MessageCodec.decode(
        ClipLiveShareSignedNativeControlHello.self,
        from: duplicateCapabilityWire
      )
    }

    var replayGuard = try ClipLiveShareNativeReplayGuard()
    try replayGuard.accept(
      signed,
      expectedSessionID: fixture.sessionID,
      at: fixture.now
    )
    #expect(throws: ClipLiveShareNativeV2Error.replayed) {
      try replayGuard.accept(
        signed,
        expectedSessionID: fixture.sessionID,
        at: fixture.now
      )
    }
  }

  @Test(
    "friend request, accept, acknowledgement, decline, and revocation are signed context-bound messages"
  )
  func friendMessages() throws {
    let fixture = try NativeV2Fixture()
    let request = try fixture.makeFriendRequest()
    let signedRequest = try ClipLiveShareSignedNativeFriendMessage(
      signing: .request(request),
      with: fixture.viewerSigner
    )
    try signedRequest.verifySignature(expectedIdentity: fixture.viewerSigner.publicKey)
    try request.validate(
      expectedSessionDescriptor: fixture.sessionDescriptor,
      expectedHostIdentity: fixture.hostSigner.publicKey,
      at: fixture.now
    )
    #expect(request.requesterEndpoint == fixture.requesterEndpoint)
    #expect(request.requesterRendezvousID == fixture.requesterRendezvousID)

    let acceptance = fixture.makeFriendAcceptance(for: request)
    let signedAcceptance = try ClipLiveShareSignedNativeFriendMessage(
      signing: .accepted(acceptance),
      with: fixture.hostSigner
    )
    try signedAcceptance.verifySignature(expectedIdentity: fixture.hostSigner.publicKey)
    try acceptance.validate(
      for: request,
      expectedSessionDescriptor: fixture.sessionDescriptor,
      at: fixture.now
    )
    #expect(acceptance.accepterEndpoint == fixture.endpoint)
    #expect(acceptance.accepterDisplayName == "Host Person")
    #expect(acceptance.accepterDeviceName == "Host Mac")

    let acknowledgement = try fixture.makeFriendAcceptanceAcknowledgement(
      for: acceptance,
      request: request
    )
    let signedAcknowledgement = try ClipLiveShareSignedNativeFriendMessage(
      signing: .acceptanceAcknowledged(acknowledgement),
      with: fixture.viewerSigner
    )
    try signedAcknowledgement.verifySignature(
      expectedIdentity: fixture.viewerSigner.publicKey
    )
    try acknowledgement.validate(
      for: acceptance,
      request: request,
      expectedSessionDescriptor: fixture.sessionDescriptor,
      at: fixture.now
    )
    #expect(acknowledgement.acceptanceDigest == acceptance.digest)
    #expect(acknowledgement.requesterEndpoint == fixture.requesterEndpoint)
    #expect(acknowledgement.accepterEndpoint == fixture.endpoint)

    let receipt = try ClipLiveShareNativeFriendCommitReceipt(
      committing: acknowledgement,
      acknowledgementDigest: signedAcknowledgement.digest,
      acceptance: acceptance,
      request: request,
      committedAt: fixture.now
    )
    let signedReceipt = try ClipLiveShareSignedNativeFriendMessage(
      signing: .commitReceipt(receipt),
      with: fixture.hostSigner
    )
    try signedReceipt.verifySignature(expectedIdentity: fixture.hostSigner.publicKey)
    try receipt.validate(
      for: acknowledgement,
      acknowledgementDigest: signedAcknowledgement.digest,
      acceptance: acceptance,
      request: request,
      expectedSessionDescriptor: fixture.sessionDescriptor,
      at: fixture.now
    )

    let decline = try fixture.makeFriendDecline(for: request)
    let signedDecline = try ClipLiveShareSignedNativeFriendMessage(
      signing: .declined(decline),
      with: fixture.hostSigner
    )
    try signedDecline.verifySignature(expectedIdentity: fixture.hostSigner.publicKey)
    try decline.validate(for: request, at: fixture.now)

    let revocation = try fixture.makeFriendRevocation()
    let signedRevocation = try ClipLiveShareSignedNativeFriendMessage(
      signing: .revoked(revocation),
      with: fixture.hostSigner
    )
    try signedRevocation.verifySignature(expectedIdentity: fixture.hostSigner.publicKey)
    try revocation.validate(
      expectedIssuer: fixture.hostSigner.publicKey,
      expectedRevokedIdentity: fixture.viewerSigner.publicKey.fingerprint,
      expectedRendezvousID: fixture.rendezvousID,
      at: fixture.now
    )

    for message in [
      signedRequest,
      signedAcceptance,
      signedAcknowledgement,
      signedReceipt,
      signedDecline,
      signedRevocation,
    ] {
      let encoded = try ClipLiveShareNativeV2MessageCodec.encode(message)
      #expect(
        try ClipLiveShareNativeV2MessageCodec.decode(
          ClipLiveShareSignedNativeFriendMessage.self,
          from: encoded
        ) == message
      )
    }

    let requestWire = try #require(
      JSONSerialization.jsonObject(
        with: ClipLiveShareNativeV2MessageCodec.encode(signedRequest)
      ) as? [String: Any]
    )
    let requestEnvelope = try #require(requestWire["message"] as? [String: Any])
    let requestPayload = try #require(requestEnvelope["payload"] as? [String: Any])
    let requesterEndpoint = try #require(
      requestPayload["requesterEndpoint"] as? [String: Any]
    )
    #expect(
      requesterEndpoint["rootURL"] as? String
        == fixture.requesterEndpoint.rootURL.absoluteString
    )
    #expect(
      requestPayload["requesterRendezvousId"] as? String
        == fixture.requesterRendezvousID.rawValue
    )

    let acceptanceWire = try #require(
      JSONSerialization.jsonObject(
        with: ClipLiveShareNativeV2MessageCodec.encode(signedAcceptance)
      ) as? [String: Any]
    )
    let acceptanceEnvelope = try #require(
      acceptanceWire["message"] as? [String: Any]
    )
    let acceptancePayload = try #require(
      acceptanceEnvelope["payload"] as? [String: Any]
    )
    let accepterEndpoint = try #require(
      acceptancePayload["accepterEndpoint"] as? [String: Any]
    )
    #expect(
      accepterEndpoint["rootURL"] as? String == fixture.endpoint.rootURL.absoluteString
    )

    let acknowledgementWire = try #require(
      JSONSerialization.jsonObject(
        with: ClipLiveShareNativeV2MessageCodec.encode(signedAcknowledgement)
      ) as? [String: Any]
    )
    let acknowledgementEnvelope = try #require(
      acknowledgementWire["message"] as? [String: Any]
    )
    #expect(
      acknowledgementEnvelope["type"] as? String
        == "add-friend-acceptance-acknowledged"
    )
    let acknowledgementPayload = try #require(
      acknowledgementEnvelope["payload"] as? [String: Any]
    )
    #expect(
      acknowledgementPayload["acceptanceDigest"] as? String
        == acceptance.digest.rawValue
    )

    var replayGuard = try ClipLiveShareNativeFriendReplayGuard()
    try replayGuard.acceptSignatureOnce(
      signedAcceptance,
      expectedIdentity: fixture.hostSigner.publicKey
    )
    #expect(throws: ClipLiveShareNativeV2Error.replayed) {
      try replayGuard.acceptSignatureOnce(
        signedAcceptance,
        expectedIdentity: fixture.hostSigner.publicKey
      )
    }

    var acknowledgementReplayGuard = try ClipLiveShareNativeFriendReplayGuard()
    #expect(
      try acknowledgementReplayGuard.acceptAcknowledgementIdempotently(
        signedAcknowledgement,
        expectedIdentity: fixture.viewerSigner.publicKey
      ) == .firstSeen
    )
    #expect(
      try acknowledgementReplayGuard.acceptAcknowledgementIdempotently(
        signedAcknowledgement,
        expectedIdentity: fixture.viewerSigner.publicKey
      ) == .duplicate
    )
    #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
      try acknowledgementReplayGuard.acceptAcknowledgementIdempotently(
        signedAcceptance,
        expectedIdentity: fixture.hostSigner.publicKey
      )
    }
  }

  @Test("decoded native friendship payloads enforce text and lifetime bounds")
  func decodedFriendPayloadConstraints() throws {
    let fixture = try NativeV2Fixture()
    let request = try fixture.makeFriendRequest()
    let acceptance = fixture.makeFriendAcceptance(for: request)
    let acknowledgement = try fixture.makeFriendAcceptanceAcknowledgement(
      for: acceptance,
      request: request
    )
    let signedAcknowledgement = try ClipLiveShareSignedNativeFriendMessage(
      signing: .acceptanceAcknowledged(acknowledgement),
      with: fixture.viewerSigner
    )
    let receipt = try ClipLiveShareNativeFriendCommitReceipt(
      committing: acknowledgement,
      acknowledgementDigest: signedAcknowledgement.digest,
      acceptance: acceptance,
      request: request,
      committedAt: fixture.now
    )
    let decline = try fixture.makeFriendDecline(for: request)
    let revocation = try fixture.makeFriendRevocation()
    let oversized = String(repeating: "x", count: 257)

    let oversizedRequest = try nativeV2MutatedJSON(request) {
      $0["requesterDeviceName"] = oversized
    }
    #expect(throws: ClipLiveShareNativeV2Error.self) {
      try JSONDecoder().decode(
        ClipLiveShareNativeFriendRequest.self,
        from: oversizedRequest
      )
    }

    let excessiveRequestLifetime = try nativeV2MutatedJSON(request) {
      $0["expiresAt"] = request.issuedAt.millisecondsSince1970
        + ClipLiveShareNativeV2.maximumFriendRequestLifetimeMilliseconds + 1
    }
    #expect(throws: ClipLiveShareNativeV2Error.invalidLifetime) {
      try JSONDecoder().decode(
        ClipLiveShareNativeFriendRequest.self,
        from: excessiveRequestLifetime
      )
    }

    let oversizedAcceptance = try nativeV2MutatedJSON(acceptance) {
      $0["accepterDisplayName"] = oversized
    }
    #expect(throws: ClipLiveShareNativeV2Error.self) {
      try JSONDecoder().decode(
        ClipLiveShareNativeFriendAcceptance.self,
        from: oversizedAcceptance
      )
    }

    let excessiveAcknowledgementLifetime = try nativeV2MutatedJSON(acknowledgement) {
      $0["expiresAt"] = acknowledgement.acknowledgedAt.millisecondsSince1970
        + ClipLiveShareNativeV2.maximumFriendRequestLifetimeMilliseconds + 1
    }
    #expect(throws: ClipLiveShareNativeV2Error.invalidLifetime) {
      try JSONDecoder().decode(
        ClipLiveShareNativeFriendAcceptanceAcknowledgement.self,
        from: excessiveAcknowledgementLifetime
      )
    }

    let excessiveReceiptLifetime = try nativeV2MutatedJSON(receipt) {
      $0["expiresAt"] = receipt.committedAt.millisecondsSince1970
        + ClipLiveShareNativeV2.maximumFriendRequestLifetimeMilliseconds + 1
    }
    #expect(throws: ClipLiveShareNativeV2Error.invalidLifetime) {
      try JSONDecoder().decode(
        ClipLiveShareNativeFriendCommitReceipt.self,
        from: excessiveReceiptLifetime
      )
    }

    let oversizedDecline = try nativeV2MutatedJSON(decline) {
      $0["reason"] = oversized
    }
    #expect(throws: ClipLiveShareNativeV2Error.self) {
      try JSONDecoder().decode(
        ClipLiveShareNativeFriendDecline.self,
        from: oversizedDecline
      )
    }

    let oversizedRevocation = try nativeV2MutatedJSON(revocation) {
      $0["reason"] = String(repeating: "x", count: 257)
    }
    #expect(throws: ClipLiveShareNativeV2Error.self) {
      try JSONDecoder().decode(
        ClipLiveShareNativeFriendRevocation.self,
        from: oversizedRevocation
      )
    }
  }

  @Test("friend acceptance acknowledgement binds every persistence context")
  func friendAcceptanceAcknowledgementSecurity() throws {
    let fixture = try NativeV2Fixture()
    let request = try fixture.makeFriendRequest()
    let acceptance = fixture.makeFriendAcceptance(for: request)
    let acknowledgement = try fixture.makeFriendAcceptanceAcknowledgement(
      for: acceptance,
      request: request
    )
    let signed = try ClipLiveShareSignedNativeFriendMessage(
      signing: .acceptanceAcknowledged(acknowledgement),
      with: fixture.viewerSigner
    )

    let changedAccepterEndpoint = try ClipLiveShareServerEndpoint(
      userInput: "https://other-host.example/"
    )
    let changedRequesterEndpoint = try ClipLiveShareServerEndpoint(
      userInput: "https://other-viewer.example/"
    )
    let changedAccepterRendezvousID = try ClipLiveShareRendezvousID(
      bytes: Data(repeating: 0x91, count: 32)
    )
    let changedRequesterRendezvousID = try ClipLiveShareRendezvousID(
      bytes: Data(repeating: 0x92, count: 32)
    )
    let changedRequestID = try ClipLiveShareFriendRequestID(
      bytes: Data(repeating: 0x93, count: 16)
    )
    let changedSessionID = try ClipLiveShareSessionID(rawValue: "changed-session")
    let changedDigest = try ClipLiveShareNativeDigest(
      bytes: Data(repeating: 0x94, count: 32)
    )
    let changedRevision = try ClipLiveShareStateRevision(rawValue: 8)

    let contextSubstitutions = try [
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        requestID: changedRequestID
      ),
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        sessionID: changedSessionID
      ),
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        requestDigest: changedDigest
      ),
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        acceptanceDigest: changedDigest
      ),
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        requesterIdentity: fixture.otherSigner.publicKey
      ),
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        accepterIdentity: fixture.otherSigner.publicKey
      ),
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        requesterEndpoint: changedRequesterEndpoint
      ),
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        requesterRendezvousID: changedRequesterRendezvousID
      ),
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        accepterEndpoint: changedAccepterEndpoint
      ),
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        accepterRendezvousID: changedAccepterRendezvousID
      ),
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        stateRevision: changedRevision
      ),
      fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        expiresAt: try request.expiresAt.adding(milliseconds: -1)
      ),
    ]

    for substitution in contextSubstitutions {
      #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
        try substitution.validate(
          for: acceptance,
          request: request,
          expectedSessionDescriptor: fixture.sessionDescriptor,
          at: fixture.now
        )
      }
    }

    let signatureTamper = ClipLiveShareSignedNativeFriendMessage(
      message: .acceptanceAcknowledged(contextSubstitutions[8]),
      signature: signed.signature
    )
    #expect(throws: ClipLiveShareNativeV2Error.invalidSignature) {
      try signatureTamper.verifySignature(expectedIdentity: fixture.viewerSigner.publicKey)
    }

    let otherAcceptance = fixture.makeFriendAcceptance(
      for: request,
      rendezvousID: changedAccepterRendezvousID
    )
    #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
      try acknowledgement.validate(
        for: otherAcceptance,
        request: request,
        expectedSessionDescriptor: fixture.sessionDescriptor,
        at: fixture.now
      )
    }

    var oneShotReplayGuard = try ClipLiveShareNativeFriendReplayGuard()
    try oneShotReplayGuard.acceptSignatureOnce(
      signed,
      expectedIdentity: fixture.viewerSigner.publicKey
    )
    #expect(throws: ClipLiveShareNativeV2Error.replayed) {
      try oneShotReplayGuard.acceptSignatureOnce(
        signed,
        expectedIdentity: fixture.viewerSigner.publicKey
      )
    }
  }

  @Test("friend acceptance acknowledgement enforces expiry and bounded clock skew")
  func friendAcceptanceAcknowledgementTimeBounds() throws {
    let fixture = try NativeV2Fixture()
    let request = try fixture.makeFriendRequest()
    let acceptance = fixture.makeFriendAcceptance(for: request)

    let exactClockSkew = try fixture.makeFriendAcceptanceAcknowledgement(
      for: acceptance,
      request: request,
      acknowledgedAt: fixture.now.adding(
        milliseconds: ClipLiveShareNativeV2.maximumClockSkewMilliseconds
      )
    )
    try exactClockSkew.validate(
      for: acceptance,
      request: request,
      expectedSessionDescriptor: fixture.sessionDescriptor,
      at: fixture.now
    )

    let excessiveClockSkew = try fixture.makeFriendAcceptanceAcknowledgement(
      for: acceptance,
      request: request,
      acknowledgedAt: fixture.now.adding(
        milliseconds: ClipLiveShareNativeV2.maximumClockSkewMilliseconds + 1
      )
    )
    #expect(throws: ClipLiveShareNativeV2Error.notYetValid) {
      try excessiveClockSkew.validate(
        for: acceptance,
        request: request,
        expectedSessionDescriptor: fixture.sessionDescriptor,
        at: fixture.now
      )
    }

    let futureAcceptedAt = try fixture.now.adding(milliseconds: 40_000)
    let laterAcceptance = try ClipLiveShareNativeFriendAcceptance(
      requestID: request.requestID,
      sessionID: request.sessionID,
      requestDigest: request.digest,
      accepterIdentity: fixture.hostSigner.publicKey,
      requesterFingerprint: request.requesterIdentity.fingerprint,
      accepterDisplayName: "Host Person",
      accepterDeviceName: "Host Mac",
      accepterEndpoint: fixture.endpoint,
      rendezvousID: fixture.rendezvousID,
      acceptedAt: futureAcceptedAt,
      stateRevision: fixture.sessionDescriptor.stateRevision
    )
    let tooEarlyForAcceptance = try fixture.makeFriendAcceptanceAcknowledgement(
      for: laterAcceptance,
      request: request,
      acknowledgedAt: fixture.now
    )
    #expect(throws: ClipLiveShareNativeV2Error.notYetValid) {
      try tooEarlyForAcceptance.validate(
        for: laterAcceptance,
        request: request,
        expectedSessionDescriptor: fixture.sessionDescriptor,
        at: futureAcceptedAt
      )
    }

    let valid = try fixture.makeFriendAcceptanceAcknowledgement(
      for: acceptance,
      request: request
    )
    #expect(throws: ClipLiveShareNativeV2Error.expired) {
      try valid.validate(
        for: acceptance,
        request: request,
        expectedSessionDescriptor: fixture.sessionDescriptor,
        at: request.expiresAt
      )
    }
    #expect(throws: ClipLiveShareNativeV2Error.invalidLifetime) {
      try fixture.makeFriendAcceptanceAcknowledgement(
        for: acceptance,
        request: request,
        acknowledgedAt: request.expiresAt
      )
    }
  }

  @Test("friend decisions reject tamper, other requests, expiry, and stale revocations")
  func friendMessageSecurity() throws {
    let fixture = try NativeV2Fixture()
    let request = try fixture.makeFriendRequest()
    let acceptance = fixture.makeFriendAcceptance(for: request)
    let signed = try ClipLiveShareSignedNativeFriendMessage(
      signing: .accepted(acceptance),
      with: fixture.hostSigner
    )

    let signedRequest = try ClipLiveShareSignedNativeFriendMessage(
      signing: .request(request),
      with: fixture.viewerSigner
    )
    let requestWithChangedEndpoint = try fixture.makeFriendRequest(
      requesterEndpoint: ClipLiveShareServerEndpoint(
        userInput: "https://attacker.example/"
      )
    )
    let tamperedRequestEndpoint = ClipLiveShareSignedNativeFriendMessage(
      message: .request(requestWithChangedEndpoint),
      signature: signedRequest.signature
    )
    #expect(throws: ClipLiveShareNativeV2Error.invalidSignature) {
      try tamperedRequestEndpoint.verifySignature(
        expectedIdentity: fixture.viewerSigner.publicKey
      )
    }

    let requestWithChangedRendezvous = try fixture.makeFriendRequest(
      requesterRendezvousID: ClipLiveShareRendezvousID(
        bytes: Data(repeating: 0xD1, count: 32)
      )
    )
    let tamperedRequestRendezvous = ClipLiveShareSignedNativeFriendMessage(
      message: .request(requestWithChangedRendezvous),
      signature: signedRequest.signature
    )
    #expect(throws: ClipLiveShareNativeV2Error.invalidSignature) {
      try tamperedRequestRendezvous.verifySignature(
        expectedIdentity: fixture.viewerSigner.publicKey
      )
    }

    let changedRendezvous = try ClipLiveShareRendezvousID(
      bytes: Data(repeating: 0xE1, count: 32)
    )
    let tamperedAcceptance = try ClipLiveShareNativeFriendAcceptance(
      requestID: acceptance.requestID,
      sessionID: acceptance.sessionID,
      requestDigest: acceptance.requestDigest,
      accepterIdentity: acceptance.accepterIdentity,
      requesterFingerprint: acceptance.requesterFingerprint,
      accepterDisplayName: acceptance.accepterDisplayName,
      accepterDeviceName: acceptance.accepterDeviceName,
      accepterEndpoint: acceptance.accepterEndpoint,
      rendezvousID: changedRendezvous,
      acceptedAt: acceptance.acceptedAt,
      stateRevision: acceptance.stateRevision
    )
    let tampered = ClipLiveShareSignedNativeFriendMessage(
      message: .accepted(tamperedAcceptance),
      signature: signed.signature
    )
    #expect(throws: ClipLiveShareNativeV2Error.invalidSignature) {
      try tampered.verifySignature(expectedIdentity: fixture.hostSigner.publicKey)
    }

    let acceptanceWithChangedEndpoint = try fixture.makeFriendAcceptance(
      for: request,
      accepterEndpoint: ClipLiveShareServerEndpoint(
        userInput: "https://unrelated.example/"
      )
    )
    let tamperedEndpoint = ClipLiveShareSignedNativeFriendMessage(
      message: .accepted(acceptanceWithChangedEndpoint),
      signature: signed.signature
    )
    #expect(throws: ClipLiveShareNativeV2Error.invalidSignature) {
      try tamperedEndpoint.verifySignature(expectedIdentity: fixture.hostSigner.publicKey)
    }

    let signedWrongEndpoint = try ClipLiveShareSignedNativeFriendMessage(
      signing: .accepted(acceptanceWithChangedEndpoint),
      with: fixture.hostSigner
    )
    try signedWrongEndpoint.verifySignature(expectedIdentity: fixture.hostSigner.publicKey)
    #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
      try acceptanceWithChangedEndpoint.validate(
        for: request,
        expectedSessionDescriptor: fixture.sessionDescriptor,
        at: fixture.now
      )
    }

    let otherRendezvousID = try ClipLiveShareRendezvousID(
      bytes: Data(repeating: 0xE2, count: 32)
    )
    let acceptanceWithWrongRendezvous = fixture.makeFriendAcceptance(
      for: request,
      rendezvousID: otherRendezvousID
    )
    let signedWrongRendezvous = try ClipLiveShareSignedNativeFriendMessage(
      signing: .accepted(acceptanceWithWrongRendezvous),
      with: fixture.hostSigner
    )
    try signedWrongRendezvous.verifySignature(
      expectedIdentity: fixture.hostSigner.publicKey
    )
    #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
      try acceptanceWithWrongRendezvous.validate(
        for: request,
        expectedSessionDescriptor: fixture.sessionDescriptor,
        at: fixture.now
      )
    }

    let acceptanceWithWrongRevision = fixture.makeFriendAcceptance(
      for: request,
      stateRevision: try ClipLiveShareStateRevision(rawValue: 8)
    )
    let signedWrongRevision = try ClipLiveShareSignedNativeFriendMessage(
      signing: .accepted(acceptanceWithWrongRevision),
      with: fixture.hostSigner
    )
    try signedWrongRevision.verifySignature(
      expectedIdentity: fixture.hostSigner.publicKey
    )
    #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
      try acceptanceWithWrongRevision.validate(
        for: request,
        expectedSessionDescriptor: fixture.sessionDescriptor,
        at: fixture.now
      )
    }

    let otherRequest = try fixture.makeFriendRequest(
      requestID: ClipLiveShareFriendRequestID(bytes: Data(repeating: 0x77, count: 16))
    )
    #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
      try acceptance.validate(
        for: otherRequest,
        expectedSessionDescriptor: fixture.sessionDescriptor,
        at: fixture.now
      )
    }
    let otherSessionDescriptor = try fixture.makeSessionDescriptor(
      sessionID: ClipLiveShareSessionID(rawValue: "unrelated-session")
    )
    #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
      try request.validate(
        expectedSessionDescriptor: otherSessionDescriptor,
        expectedHostIdentity: fixture.hostSigner.publicKey,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV2Error.expired) {
      try request.validate(at: request.expiresAt)
    }

    var revisions = ClipLiveShareStateRevisionGuard()
    try revisions.accept(try ClipLiveShareStateRevision(rawValue: 11))
    #expect(
      throws: ClipLiveShareNativeV2Error.staleStateRevision(
        expectedGreaterThan: 11,
        actual: 11
      )
    ) {
      try revisions.accept(try ClipLiveShareStateRevision(rawValue: 11))
    }
  }

  @Test("native stream lifecycle rejects stale state and isolates reused sender slots")
  func nativeStreamLifecycle() throws {
    let fixture = try NativeV2Fixture()
    let first = try fixture.makeNativeStream(sourceByte: 0x11, appName: "Arc")
    let second = try fixture.makeNativeStream(sourceByte: 0x22, appName: "Messages")
    var state = ClipLiveShareNativeStreamLifecycleState(sessionID: fixture.sessionID)

    try state.apply(
      ClipLiveShareNativeStreamLifecycleMessage(
        sessionID: fixture.sessionID,
        stateRevision: ClipLiveShareStateRevision(rawValue: 1),
        event: .snapshot([first])
      )
    )
    try state.apply(
      ClipLiveShareNativeStreamLifecycleMessage(
        sessionID: fixture.sessionID,
        stateRevision: ClipLiveShareStateRevision(rawValue: 2),
        event: .removed(first.sourceInstanceID)
      )
    )
    try state.apply(
      ClipLiveShareNativeStreamLifecycleMessage(
        sessionID: fixture.sessionID,
        stateRevision: ClipLiveShareStateRevision(rawValue: 3),
        event: .upsert(second)
      )
    )
    // A delayed removal names the old capture generation, not the reused
    // stream/track slot, so it cannot remove the second source.
    try state.apply(
      ClipLiveShareNativeStreamLifecycleMessage(
        sessionID: fixture.sessionID,
        stateRevision: ClipLiveShareStateRevision(rawValue: 4),
        event: .removed(first.sourceInstanceID)
      )
    )
    #expect(state.streams[second.sourceInstanceID] == second)
    #expect(state.streams.count == 1)

    #expect(throws: ClipLiveShareNativeV2Error.self) {
      try state.apply(
        ClipLiveShareNativeStreamLifecycleMessage(
          sessionID: fixture.sessionID,
          stateRevision: ClipLiveShareStateRevision(rawValue: 4),
          event: .sharing(true)
        )
      )
    }
    #expect(state.revisionGuard.latestAcceptedRevision?.rawValue == 4)

    let otherSession = try ClipLiveShareSessionID(rawValue: "other-session")
    #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
      try state.apply(
        ClipLiveShareNativeStreamLifecycleMessage(
          sessionID: otherSession,
          stateRevision: ClipLiveShareStateRevision(rawValue: 5),
          event: .sharing(true)
        )
      )
    }
    #expect(state.revisionGuard.latestAcceptedRevision?.rawValue == 4)
  }

  @Test("native stream lifecycle enforces Clip's four-source contract")
  func nativeStreamLifecycleFourSourceLimit() throws {
    let fixture = try NativeV2Fixture()
    let descriptors = try (0..<5).map { index in
      ClipLiveShareNativeStreamDescriptor(
        sourceInstanceID: try ClipLiveShareSourceInstanceID(
          bytes: Data(repeating: UInt8(0x60 + index), count: 16)
        ),
        presentationMode: .manual,
        stream: try ClipLiveShareStreamDescriptor(
          id: ClipLiveShareStreamID(rawValue: "slot-\(index)"),
          mediaTrackID: ClipLiveShareMediaTrackID(rawValue: "track-\(index)"),
          active: true,
          focused: index == 0,
          appName: "App \(index)",
          windowName: "Window \(index)",
          width: 1_280,
          height: 720,
          order: index
        )
      )
    }

    let oversizedWire = try ClipLiveShareNativeV2MessageCodec.encode(
      ClipLiveShareNativeStreamLifecycleMessage(
        sessionID: fixture.sessionID,
        stateRevision: ClipLiveShareStateRevision(rawValue: 1),
        event: .snapshot(descriptors),
        maximumStreams: 5
      )
    )
    #expect(throws: ClipLiveShareProtocolError.self) {
      try ClipLiveShareNativeV2MessageCodec.decode(
        ClipLiveShareNativeStreamLifecycleMessage.self,
        from: oversizedWire
      )
    }

    var state = ClipLiveShareNativeStreamLifecycleState(sessionID: fixture.sessionID)
    for index in 0..<4 {
      try state.apply(
        ClipLiveShareNativeStreamLifecycleMessage(
          sessionID: fixture.sessionID,
          stateRevision: ClipLiveShareStateRevision(rawValue: UInt64(index + 1)),
          event: .upsert(descriptors[index])
        )
      )
    }
    #expect(state.streams.count == 4)
    #expect(throws: ClipLiveShareProtocolError.self) {
      try state.apply(
        ClipLiveShareNativeStreamLifecycleMessage(
          sessionID: fixture.sessionID,
          stateRevision: ClipLiveShareStateRevision(rawValue: 5),
          event: .upsert(descriptors[4])
        )
      )
    }
    #expect(state.streams.count == 4)
    #expect(state.revisionGuard.latestAcceptedRevision?.rawValue == 4)
  }

  @Test("upserting the focused source as unfocused clears reducer focus")
  func nativeStreamUpsertClearsFocus() throws {
    let fixture = try NativeV2Fixture()
    let sourceID = try ClipLiveShareSourceInstanceID(
      bytes: Data(repeating: 0x7A, count: 16)
    )
    func descriptor(focused: Bool) throws -> ClipLiveShareNativeStreamDescriptor {
      ClipLiveShareNativeStreamDescriptor(
        sourceInstanceID: sourceID,
        presentationMode: .manual,
        stream: try ClipLiveShareStreamDescriptor(
          id: ClipLiveShareStreamID(rawValue: "focus-slot"),
          mediaTrackID: ClipLiveShareMediaTrackID(rawValue: "focus-track"),
          active: true,
          focused: focused,
          appName: "Arc",
          windowName: "Window",
          width: 800,
          height: 600,
          order: 0
        )
      )
    }
    var state = ClipLiveShareNativeStreamLifecycleState(sessionID: fixture.sessionID)
    try state.apply(ClipLiveShareNativeStreamLifecycleMessage(
      sessionID: fixture.sessionID,
      stateRevision: ClipLiveShareStateRevision(rawValue: 1),
      event: .upsert(try descriptor(focused: true))
    ))
    #expect(state.focusedSourceInstanceID == sourceID)

    try state.apply(ClipLiveShareNativeStreamLifecycleMessage(
      sessionID: fixture.sessionID,
      stateRevision: ClipLiveShareStateRevision(rawValue: 2),
      event: .upsert(try descriptor(focused: false))
    ))
    #expect(state.focusedSourceInstanceID == nil)
    #expect(state.streams[sourceID]?.stream.focused == false)
  }

  @Test("source presentation mode is wire-visible and bound to canonical authentication")
  func nativeSourcePresentationMode() throws {
    let fixture = try NativeV2Fixture()
    let manual = try fixture.makeNativeStream(
      sourceByte: 0x30,
      appName: "Arc",
      presentationMode: .manual
    )
    let automatic = try fixture.makeNativeStream(
      sourceByte: 0x30,
      appName: "Arc",
      presentationMode: .followsFocusedWindow
    )

    #expect(manual.sourceInstanceID == automatic.sourceInstanceID)
    #expect(manual.stream == automatic.stream)
    #expect(manual.canonicalRepresentation != automatic.canonicalRepresentation)

    let automaticSignature = try fixture.hostSigner.signature(
      for: automatic.canonicalRepresentation
    )
    #expect(
      fixture.hostSigner.publicKey.isValidSignature(
        automaticSignature,
        for: automatic.canonicalRepresentation
      )
    )
    #expect(
      !fixture.hostSigner.publicKey.isValidSignature(
        automaticSignature,
        for: manual.canonicalRepresentation
      )
    )

    let message = try ClipLiveShareNativeStreamLifecycleMessage(
      sessionID: fixture.sessionID,
      stateRevision: ClipLiveShareStateRevision(rawValue: 1),
      event: .upsert(automatic)
    )
    let encoded = try ClipLiveShareNativeV2MessageCodec.encode(message)
    let object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let stream = try #require(object["stream"] as? [String: Any])
    #expect(stream["presentationMode"] as? String == "follows-focused-window")
    #expect(
      try ClipLiveShareNativeV2MessageCodec.decode(
        ClipLiveShareNativeStreamLifecycleMessage.self,
        from: encoded
      ) == message
    )

    var unknownModeObject = object
    var unknownModeStream = stream
    unknownModeStream["presentationMode"] = "popup"
    unknownModeObject["stream"] = unknownModeStream
    let unknownModeWire = try JSONSerialization.data(withJSONObject: unknownModeObject)
    #expect(throws: DecodingError.self) {
      try ClipLiveShareNativeV2MessageCodec.decode(
        ClipLiveShareNativeStreamLifecycleMessage.self,
        from: unknownModeWire
      )
    }
  }

  @Test("all native stream lifecycle variants have canonical v2 wire forms")
  func nativeStreamWireForms() throws {
    let fixture = try NativeV2Fixture()
    let stream = try fixture.makeNativeStream(sourceByte: 0x31, appName: "Clip")
    let events: [ClipLiveShareNativeStreamLifecycleEvent] = [
      .snapshot([stream]),
      .upsert(stream),
      .removed(stream.sourceInstanceID),
      .focus(stream.sourceInstanceID),
      .focus(nil),
      .sharing(true),
      .systemAudio(true),
    ]

    for (offset, event) in events.enumerated() {
      let message = try ClipLiveShareNativeStreamLifecycleMessage(
        sessionID: fixture.sessionID,
        stateRevision: ClipLiveShareStateRevision(rawValue: UInt64(offset + 1)),
        event: event
      )
      let encoded = try ClipLiveShareNativeV2MessageCodec.encode(message)
      let decoded = try ClipLiveShareNativeV2MessageCodec.decode(
        ClipLiveShareNativeStreamLifecycleMessage.self,
        from: encoded
      )
      #expect(decoded == message)
      #expect(decoded.canonicalRepresentation == message.canonicalRepresentation)
      let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      )
      #expect(object["version"] as? Int == 2)
      #expect(object["stateRevision"] as? Int == offset + 1)
    }

    #expect(throws: ClipLiveShareProtocolError.self) {
      try ClipLiveShareNativeStreamLifecycleMessage(
        sessionID: fixture.sessionID,
        stateRevision: ClipLiveShareStateRevision(rawValue: 10),
        event: .snapshot([stream, stream])
      )
    }
  }

  @Test("native additions do not change the v1 wire contract")
  func v1WireCompatibility() throws {
    let sessionID = try ClipLiveShareSessionID(rawValue: "fixture-session")
    let message = ClipLiveShareInnerMessage.authResult(
      try ClipLiveShareAuthResult(sessionID: sessionID, allowed: true)
    )
    let encoded = try ClipLiveShareMessageCodec.encodeInner(message)

    #expect(ClipLiveShareV1.version == 1)
    #expect(ClipLiveShareNativeV2.version == 2)
    #expect(
      String(data: encoded, encoding: .utf8)
        == #"{"allowed":true,"sessionId":"fixture-session","type":"auth-result","version":1}"#
    )
  }
}

private func nativeV2MutatedJSON<Value: Encodable>(
  _ value: Value,
  mutate: (inout [String: Any]) -> Void
) throws -> Data {
  var object = try JSONSerialization.jsonObject(
    with: JSONEncoder().encode(value)
  ) as! [String: Any]
  mutate(&object)
  return try JSONSerialization.data(withJSONObject: object)
}

private struct NativeV2Fixture {
  let hostSigner: ClipLiveShareSoftwareIdentitySigner
  let viewerSigner: ClipLiveShareSoftwareIdentitySigner
  let otherSigner: ClipLiveShareSoftwareIdentitySigner
  let endpoint: ClipLiveShareServerEndpoint
  let requesterEndpoint: ClipLiveShareServerEndpoint
  let room: ClipLiveShareRoomName
  let rendezvousID: ClipLiveShareRendezvousID
  let requesterRendezvousID: ClipLiveShareRendezvousID
  let roomPublicKey: ClipLiveShareKeyAgreementPublicKey
  let viewerEphemeralPublicKey: ClipLiveShareKeyAgreementPublicKey
  let sessionID: ClipLiveShareSessionID
  let routeID: ClipLiveShareRouteID
  let issuedAt: ClipLiveShareNativeTimestamp
  let now: ClipLiveShareNativeTimestamp
  let expiresAt: ClipLiveShareNativeTimestamp
  let sessionDescriptor: ClipLiveShareNativeSessionDescriptor

  init() throws {
    hostSigner = try ClipLiveShareSoftwareIdentitySigner(
      rawRepresentation: Data(repeating: 1, count: 32)
    )
    viewerSigner = try ClipLiveShareSoftwareIdentitySigner(
      rawRepresentation: Data(repeating: 2, count: 32)
    )
    otherSigner = try ClipLiveShareSoftwareIdentitySigner(
      rawRepresentation: Data(repeating: 3, count: 32)
    )
    endpoint = .official
    requesterEndpoint = try ClipLiveShareServerEndpoint(
      userInput: "https://friends.example/"
    )
    room = try ClipLiveShareRoomName(rawValue: "CALM-OTTER-042")
    rendezvousID = try ClipLiveShareRendezvousID(bytes: Data(0x20...0x3F))
    requesterRendezvousID = try ClipLiveShareRendezvousID(bytes: Data(0x60...0x7F))
    roomPublicKey = try ClipLiveShareRoomIdentity(
      privateKeyRawRepresentation: Data(repeating: 4, count: 32)
    ).publicKey
    viewerEphemeralPublicKey = try ClipLiveShareViewerIdentity(
      privateKeyRawRepresentation: Data(repeating: 5, count: 32)
    ).publicKey
    sessionID = try ClipLiveShareSessionID(rawValue: "native-session")
    routeID = try ClipLiveShareRouteID(bytes: Data(0...15))
    issuedAt = try ClipLiveShareNativeTimestamp(millisecondsSince1970: 1_750_000_000_000)
    now = try issuedAt.adding(milliseconds: 1_000)
    expiresAt = try issuedAt.adding(milliseconds: 120_000)
    sessionDescriptor = try ClipLiveShareNativeSessionDescriptor(
      endpoint: endpoint,
      room: room,
      rendezvousID: rendezvousID,
      hostIdentity: hostSigner.publicKey,
      roomPublicKey: roomPublicKey,
      sessionID: sessionID,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      stateRevision: ClipLiveShareStateRevision(rawValue: 7)
    )
  }

  func makeSessionDescriptor(
    endpoint: ClipLiveShareServerEndpoint? = nil,
    room: ClipLiveShareRoomName? = nil,
    rendezvousID: ClipLiveShareRendezvousID? = nil,
    roomPublicKey: ClipLiveShareKeyAgreementPublicKey? = nil,
    sessionID: ClipLiveShareSessionID? = nil,
    expiresAt: ClipLiveShareNativeTimestamp? = nil,
    stateRevision: ClipLiveShareStateRevision? = nil
  ) throws -> ClipLiveShareNativeSessionDescriptor {
    try ClipLiveShareNativeSessionDescriptor(
      endpoint: endpoint ?? self.endpoint,
      room: room ?? self.room,
      rendezvousID: rendezvousID ?? self.rendezvousID,
      hostIdentity: hostSigner.publicKey,
      roomPublicKey: roomPublicKey ?? self.roomPublicKey,
      sessionID: sessionID ?? self.sessionID,
      issuedAt: issuedAt,
      expiresAt: expiresAt ?? self.expiresAt,
      stateRevision: stateRevision ?? ClipLiveShareStateRevision(rawValue: 7)
    )
  }

  func makeViewerChallenge(
    routeID: ClipLiveShareRouteID? = nil,
    challenge: Data = Data(repeating: 0xAB, count: 32)
  ) throws -> ClipLiveShareNativeViewerChallenge {
    try ClipLiveShareNativeViewerChallenge(
      sessionDescriptorDigest: sessionDescriptor.digest,
      sessionID: sessionID,
      routeID: routeID ?? self.routeID,
      viewerEphemeralPublicKey: viewerEphemeralPublicKey,
      challenge: challenge,
      issuedAt: issuedAt,
      expiresAt: issuedAt.adding(milliseconds: 30_000),
      stateRevision: ClipLiveShareStateRevision(rawValue: 7)
    )
  }

  func makeFriendRequest(
    requestID: ClipLiveShareFriendRequestID? = nil,
    requesterEndpoint: ClipLiveShareServerEndpoint? = nil,
    requesterRendezvousID: ClipLiveShareRendezvousID? = nil
  ) throws -> ClipLiveShareNativeFriendRequest {
    try ClipLiveShareNativeFriendRequest(
      requestID: requestID ?? ClipLiveShareFriendRequestID(bytes: Data(0x40...0x4F)),
      sessionID: sessionID,
      sessionDescriptorDigest: sessionDescriptor.digest,
      requestedHostFingerprint: hostSigner.publicKey.fingerprint,
      requesterIdentity: viewerSigner.publicKey,
      requesterEndpoint: requesterEndpoint ?? self.requesterEndpoint,
      requesterRendezvousID: requesterRendezvousID ?? self.requesterRendezvousID,
      requesterDeviceName: "Viewer Mac",
      issuedAt: issuedAt,
      expiresAt: issuedAt.adding(milliseconds: 300_000)
    )
  }

  func makeFriendAcceptance(
    for request: ClipLiveShareNativeFriendRequest,
    accepterEndpoint: ClipLiveShareServerEndpoint? = nil,
    rendezvousID: ClipLiveShareRendezvousID? = nil,
    stateRevision: ClipLiveShareStateRevision? = nil
  ) -> ClipLiveShareNativeFriendAcceptance {
    try! ClipLiveShareNativeFriendAcceptance(
      requestID: request.requestID,
      sessionID: request.sessionID,
      requestDigest: request.digest,
      accepterIdentity: hostSigner.publicKey,
      requesterFingerprint: request.requesterIdentity.fingerprint,
      accepterDisplayName: "Host Person",
      accepterDeviceName: "Host Mac",
      accepterEndpoint: accepterEndpoint ?? endpoint,
      rendezvousID: rendezvousID ?? self.rendezvousID,
      acceptedAt: now,
      stateRevision: stateRevision ?? sessionDescriptor.stateRevision
    )
  }

  func makeFriendAcceptanceAcknowledgement(
    for acceptance: ClipLiveShareNativeFriendAcceptance,
    request: ClipLiveShareNativeFriendRequest,
    requestID: ClipLiveShareFriendRequestID? = nil,
    sessionID: ClipLiveShareSessionID? = nil,
    requestDigest: ClipLiveShareNativeDigest? = nil,
    acceptanceDigest: ClipLiveShareNativeDigest? = nil,
    requesterIdentity: ClipLiveShareIdentityPublicKey? = nil,
    accepterIdentity: ClipLiveShareIdentityPublicKey? = nil,
    requesterEndpoint: ClipLiveShareServerEndpoint? = nil,
    requesterRendezvousID: ClipLiveShareRendezvousID? = nil,
    accepterEndpoint: ClipLiveShareServerEndpoint? = nil,
    accepterRendezvousID: ClipLiveShareRendezvousID? = nil,
    stateRevision: ClipLiveShareStateRevision? = nil,
    acknowledgedAt: ClipLiveShareNativeTimestamp? = nil,
    expiresAt: ClipLiveShareNativeTimestamp? = nil
  ) throws -> ClipLiveShareNativeFriendAcceptanceAcknowledgement {
    try ClipLiveShareNativeFriendAcceptanceAcknowledgement(
      requestID: requestID ?? request.requestID,
      sessionID: sessionID ?? request.sessionID,
      requestDigest: requestDigest ?? request.digest,
      acceptanceDigest: acceptanceDigest ?? acceptance.digest,
      requesterIdentity: requesterIdentity ?? request.requesterIdentity,
      accepterIdentity: accepterIdentity ?? acceptance.accepterIdentity,
      requesterEndpoint: requesterEndpoint ?? request.requesterEndpoint,
      requesterRendezvousID: requesterRendezvousID ?? request.requesterRendezvousID,
      accepterEndpoint: accepterEndpoint ?? acceptance.accepterEndpoint,
      accepterRendezvousID: accepterRendezvousID ?? acceptance.rendezvousID,
      stateRevision: stateRevision ?? acceptance.stateRevision,
      acknowledgedAt: acknowledgedAt ?? now,
      expiresAt: expiresAt ?? request.expiresAt
    )
  }

  func makeFriendDecline(
    for request: ClipLiveShareNativeFriendRequest
  ) throws -> ClipLiveShareNativeFriendDecline {
    try ClipLiveShareNativeFriendDecline(
      requestID: request.requestID,
      sessionID: request.sessionID,
      requestDigest: request.digest,
      declinerIdentity: hostSigner.publicKey,
      requesterFingerprint: request.requesterIdentity.fingerprint,
      declinedAt: now,
      reason: "user-declined"
    )
  }

  func makeFriendRevocation() throws -> ClipLiveShareNativeFriendRevocation {
    try ClipLiveShareNativeFriendRevocation(
      revocationID: ClipLiveShareRevocationID(bytes: Data(0x50...0x5F)),
      issuerIdentity: hostSigner.publicKey,
      revokedIdentityFingerprint: viewerSigner.publicKey.fingerprint,
      rendezvousID: rendezvousID,
      stateRevision: ClipLiveShareStateRevision(rawValue: 11),
      issuedAt: now,
      reason: "removed-by-host"
    )
  }

  func makeNativeStream(
    sourceByte: UInt8,
    appName: String,
    presentationMode: ClipLiveShareNativeSourcePresentationMode = .manual
  ) throws -> ClipLiveShareNativeStreamDescriptor {
    ClipLiveShareNativeStreamDescriptor(
      sourceInstanceID: try ClipLiveShareSourceInstanceID(
        bytes: Data(repeating: sourceByte, count: 16)
      ),
      presentationMode: presentationMode,
      stream: try ClipLiveShareStreamDescriptor(
        id: ClipLiveShareStreamID(rawValue: "shared-slot-zero"),
        mediaTrackID: ClipLiveShareMediaTrackID(rawValue: "shared-track-zero"),
        active: true,
        focused: false,
        appName: appName,
        windowName: "Window",
        width: 1_920,
        height: 1_080,
        order: 0
      )
    )
  }
}
