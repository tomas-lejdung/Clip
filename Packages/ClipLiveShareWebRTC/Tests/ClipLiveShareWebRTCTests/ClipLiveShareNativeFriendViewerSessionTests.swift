import ClipLiveShare
import Foundation
import Testing

@testable import ClipLiveShareWebRTC

@Suite("Clip native saved-friend viewer session")
struct ClipLiveShareNativeFriendViewerSessionTests {
  @Test("a descriptor signed by another identity fails before viewer hello")
  func descriptorIdentityMismatch() async throws {
    let fixture = try NativeFriendViewerFixture()
    let wrongHost = ClipLiveShareSoftwareIdentitySigner()
    let wrongDescriptor = try fixture.signedDescriptor(signer: wrongHost)
    let harness = fixture.makeHarness()
    let recording = await harness.recordEvents()
    defer { recording.cancel() }

    try await harness.session.start()
    await harness.transport.emit(
      .routeOpened(
        routeID: fixture.routeID.rawValue,
        descriptor: try ClipLiveShareNativeV2MessageCodec.encode(wrongDescriptor)
      )
    )

    try await nativeFriendViewerEventually {
      await harness.recorder.failures().contains(.descriptorRejected)
    }
    #expect(await harness.transport.sentPayloads().isEmpty)
    #expect(harness.peerFactory.makeCount() == 0)
  }

  @Test("a descriptor with a tampered signature fails closed")
  func descriptorSignatureTamper() async throws {
    let fixture = try NativeFriendViewerFixture()
    let descriptor = try fixture.descriptor(hostIdentity: fixture.hostSigner.publicKey)
    let wrongSigner = ClipLiveShareSoftwareIdentitySigner()
    let tampered = ClipLiveShareSignedNativeSessionDescriptor(
      descriptor: descriptor,
      signature: try wrongSigner.signature(for: descriptor.canonicalRepresentation)
    )
    let harness = fixture.makeHarness()
    let recording = await harness.recordEvents()
    defer { recording.cancel() }

    try await harness.session.start()
    await harness.transport.emit(
      .routeOpened(
        routeID: fixture.routeID.rawValue,
        descriptor: try ClipLiveShareNativeV2MessageCodec.encode(tampered)
      )
    )

    try await nativeFriendViewerEventually {
      await harness.recorder.failures().contains(.descriptorRejected)
    }
    #expect(await harness.transport.teardownCount() == 2)
    #expect(harness.peer.closeCount() == 0)
  }

  @Test("a fresh signed room is accepted without persisting per-share room state")
  func freshSignedRoomAccepted() async throws {
    let fixture = try NativeFriendViewerFixture()
    let freshRoom = try ClipLiveShareRoomName(rawValue: "FRESH-ROOM-007")
    let signed = try fixture.signedDescriptor(room: freshRoom)
    let harness = fixture.makeHarness()
    let recording = await harness.recordEvents()
    defer { recording.cancel() }

    try await harness.session.start()
    await harness.transport.emit(
      .routeOpened(
        routeID: fixture.routeID.rawValue,
        descriptor: try ClipLiveShareNativeV2MessageCodec.encode(signed)
      )
    )

    try await nativeFriendViewerEventually {
      await harness.transport.sentPayloads().count == 1
    }
    #expect(await harness.recorder.failures().isEmpty)
    #expect(harness.peerFactory.makeCount() == 1)
    await harness.session.close()
  }

  @Test("signed endpoint and rendezvous mismatches are rejected")
  func descriptorSavedRouteMismatch() async throws {
    let fixture = try NativeFriendViewerFixture()
    let otherEndpoint = try ClipLiveShareServerEndpoint(
      userInput: "https://other.example"
    )
    let endpointMismatch = try fixture.signedDescriptor(endpoint: otherEndpoint)
    let endpointHarness = fixture.makeHarness()
    let endpointRecording = await endpointHarness.recordEvents()
    defer { endpointRecording.cancel() }
    try await endpointHarness.session.start()
    await endpointHarness.transport.emit(
      .routeOpened(
        routeID: fixture.routeID.rawValue,
        descriptor: try ClipLiveShareNativeV2MessageCodec.encode(endpointMismatch)
      )
    )
    try await nativeFriendViewerEventually {
      await endpointHarness.recorder.failures().contains(.descriptorRejected)
    }

    let otherRendezvous = try ClipLiveShareRendezvousID(
      bytes: Data(repeating: 0x99, count: ClipLiveShareNativeV2.rendezvousIDByteCount)
    )
    let rendezvousMismatch = try fixture.signedDescriptor(
      rendezvousID: otherRendezvous
    )
    let rendezvousHarness = fixture.makeHarness()
    let rendezvousRecording = await rendezvousHarness.recordEvents()
    defer { rendezvousRecording.cancel() }
    try await rendezvousHarness.session.start()
    await rendezvousHarness.transport.emit(
      .routeOpened(
        routeID: fixture.routeID.rawValue,
        descriptor: try ClipLiveShareNativeV2MessageCodec.encode(rendezvousMismatch)
      )
    )
    try await nativeFriendViewerEventually {
      await rendezvousHarness.recorder.failures().contains(.descriptorRejected)
    }
    #expect(await endpointHarness.transport.sentPayloads().isEmpty)
    #expect(await rendezvousHarness.transport.sentPayloads().isEmpty)
  }

  @Test("a repeated descriptor event is rejected as replay")
  func descriptorReplay() async throws {
    let fixture = try NativeFriendViewerFixture()
    let harness = fixture.makeHarness()
    let recording = await harness.recordEvents()
    defer { recording.cancel() }

    try await harness.session.start()
    let data = try ClipLiveShareNativeV2MessageCodec.encode(fixture.signedDescriptor())
    await harness.transport.emit(
      .routeOpened(routeID: fixture.routeID.rawValue, descriptor: data)
    )
    try await nativeFriendViewerEventually {
      await harness.transport.sentPayloads().count == 1
    }
    await harness.transport.emit(
      .routeOpened(routeID: fixture.routeID.rawValue, descriptor: data)
    )

    try await nativeFriendViewerEventually {
      await harness.recorder.failures().contains(.descriptorReplayed)
    }
    #expect(harness.peer.closeCount() == 1)
  }

  @Test("challenge context mismatch is rejected before a persistent proof is sent")
  func challengeContextMismatch() async throws {
    let fixture = try NativeFriendViewerFixture()
    let harness = fixture.makeHarness()
    let recording = await harness.recordEvents()
    defer { recording.cancel() }

    try await harness.session.start()
    let hello = try await harness.openRoute(fixture: fixture)
    var hostChannel = try fixture.hostChannel(viewerKey: hello.viewerKey)
    let otherRoute = try ClipLiveShareRouteID(
      bytes: Data(repeating: 0x91, count: ClipLiveShareV1.routeIDByteCount)
    )
    let mismatched = try fixture.challenge(
      viewerKey: hello.viewerKey,
      routeID: otherRoute
    )
    try await harness.sendHostOpaque(
      hostChannel.sealOpaquePayload(
        try ClipLiveShareNativeV2MessageCodec.encode(mismatched)
      ),
      fixture: fixture
    )

    try await nativeFriendViewerEventually {
      await harness.recorder.failures().contains(.challengeRejected)
    }
    #expect(await harness.transport.sentPayloads().count == 1)
    #expect(harness.peer.closeCount() == 1)
  }

  @Test("tampered encrypted challenge fails closed")
  func encryptedChallengeTamper() async throws {
    let fixture = try NativeFriendViewerFixture()
    let harness = fixture.makeHarness()
    let recording = await harness.recordEvents()
    defer { recording.cancel() }

    try await harness.session.start()
    let hello = try await harness.openRoute(fixture: fixture)
    var hostChannel = try fixture.hostChannel(viewerKey: hello.viewerKey)
    let challenge = try fixture.challenge(viewerKey: hello.viewerKey)
    let sealed = try hostChannel.sealOpaquePayload(
      ClipLiveShareNativeV2MessageCodec.encode(challenge)
    )
    var ciphertext = sealed.ciphertext
    ciphertext[ciphertext.startIndex] ^= 0x01
    let tampered = try ClipLiveShareRelayEnvelope(
      routeID: fixture.routeID,
      sequence: sealed.sequence,
      nonce: sealed.nonce,
      ciphertext: ciphertext
    )
    try await harness.sendHostOpaque(tampered, fixture: fixture)

    try await nativeFriendViewerEventually {
      await harness.recorder.failures().contains(.invalidSignalingMessage)
    }
    #expect(harness.peer.closeCount() == 1)
  }

  @Test("an explicit host denial stays typed and tears down WebRTC")
  func hostDenial() async throws {
    let fixture = try NativeFriendViewerFixture()
    let harness = fixture.makeHarness()
    let recording = await harness.recordEvents()
    defer { recording.cancel() }

    try await harness.session.start()
    let hello = try await harness.openRoute(fixture: fixture)
    var hostChannel = try fixture.hostChannel(viewerKey: hello.viewerKey)
    let challenge = try fixture.challenge(viewerKey: hello.viewerKey)
    try await harness.sendHostOpaque(
      hostChannel.sealOpaquePayload(
        try ClipLiveShareNativeV2MessageCodec.encode(challenge)
      ),
      fixture: fixture
    )
    let proof = try await harness.awaitAndOpenProof(
      hostChannel: &hostChannel,
      fixture: fixture
    )
    try proof.verify(
      expectedChallenge: challenge,
      expectedIdentity: fixture.viewerSigner.publicKey,
      at: fixture.now
    )

    try await harness.sendHostInner(
      hostChannel.seal(
        .authResult(
          try .init(
            sessionID: fixture.sessionID,
            allowed: false,
            reason: "not-now"
          )
        )
      ),
      fixture: fixture
    )

    try await nativeFriendViewerEventually {
      await harness.recorder.failures().contains(.admissionRejected("not-now"))
    }
    #expect(harness.peer.closeCount() == 1)
    #expect(await harness.transport.teardownCount() == 2)
  }

  @Test("approved viewer closes rendezvous only after the P2P control channel opens")
  func approvedHandoff() async throws {
    let fixture = try NativeFriendViewerFixture()
    let harness = fixture.makeHarness()
    let recording = await harness.recordEvents()
    defer { recording.cancel() }

    try await harness.session.start()
    let hello = try await harness.openRoute(fixture: fixture)
    var hostChannel = try fixture.hostChannel(viewerKey: hello.viewerKey)
    let challenge = try fixture.challenge(viewerKey: hello.viewerKey)
    try await harness.sendHostOpaque(
      hostChannel.sealOpaquePayload(
        try ClipLiveShareNativeV2MessageCodec.encode(challenge)
      ),
      fixture: fixture
    )
    _ = try await harness.awaitAndOpenProof(
      hostChannel: &hostChannel,
      fixture: fixture
    )
    try await harness.sendHostInner(
      hostChannel.seal(
        .authResult(
          try .init(sessionID: fixture.sessionID, allowed: true)
        )
      ),
      fixture: fixture
    )
    try await nativeFriendViewerEventually {
      await harness.recorder.authenticatedSessionID() == fixture.sessionID
    }

    let offer = try ClipLiveShareSessionDescription(
      sessionID: fixture.sessionID,
      negotiationID: fixture.negotiationID,
      sdp: "v=0\r\no=host 1 1 IN IP4 127.0.0.1\r\n"
    )
    try await harness.sendHostInner(
      hostChannel.seal(.offer(offer)),
      fixture: fixture
    )
    try await nativeFriendViewerEventually {
      let payloadCount = await harness.transport.sentPayloads().count
      return harness.peer.answerCount() == 1 && payloadCount == 3
    }
    let answerEnvelope = try await harness.sentRelay(at: 2)
    guard case .answer(let answer) = try hostChannel.open(answerEnvelope) else {
      Issue.record("Expected an encrypted WebRTC answer")
      return
    }
    #expect(answer.sessionID == fixture.sessionID)
    #expect(answer.negotiationID == fixture.negotiationID)

    #expect(await harness.transport.closeReasons().isEmpty)
    harness.peer.emit(.controlDataChannelStateChanged(.open))
    try await nativeFriendViewerEventually {
      let handoffCount = await harness.recorder.handoffCount()
      let closeCount = await harness.transport.closeReasons().count
      return handoffCount == 1 && closeCount == 1
    }
    #expect(
      await harness.transport.closeReasons()
        == ["viewer completed signaling"]
    )

    let controls = harness.peer.controls()
    let helloData = try #require(controls.first?.0)
    #expect(controls.first?.1 == false)
    let signedHello = try ClipLiveShareNativeV2MessageCodec.decode(
      ClipLiveShareSignedNativeControlHello.self,
      from: helloData
    )
    try signedHello.verify(
      expectedSessionID: fixture.sessionID,
      expectedIdentity: fixture.viewerSigner.publicKey,
      at: fixture.now
    )

    let failuresBeforeDisconnect = await harness.recorder.failures()
    await harness.transport.emit(
      .disconnected(reason: .connectionLost, willReconnect: false)
    )
    await harness.transport.emit(.invalidMessageReceived)
    await harness.transport.emit(.stopped)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await harness.recorder.failures() == failuresBeforeDisconnect)
    #expect(harness.peer.closeCount() == 0)

    await harness.session.close()
    #expect(harness.peer.closeCount() == 1)
  }

  @Test("signaling loss after the answer preserves the admitted peer")
  func signalingLossAfterAnswerPreservesPeer() async throws {
    try await verifyPostAnswerRouteCloseRace(
      reason: "signaling-connection-lost"
    )
  }

  @Test("host handoff close before local DataChannel open preserves the peer")
  func hostHandoffCloseBeforeLocalControlOpenPreservesPeer() async throws {
    try await verifyPostAnswerRouteCloseRace(
      reason: "viewer completed signaling"
    )
  }

  private func verifyPostAnswerRouteCloseRace(
    reason: String
  ) async throws {
    let fixture = try NativeFriendViewerFixture()
    let harness = fixture.makeHarness()
    let recording = await harness.recordEvents()
    defer { recording.cancel() }

    try await harness.session.start()
    try await harness.negotiateThroughInitialAnswer(fixture: fixture)
    await harness.transport.emit(
      .routeClosed(
        routeID: fixture.routeID.rawValue,
        reason: reason
      )
    )

    try await nativeFriendViewerEventually {
      await harness.transport.teardownCount() == 2
    }
    #expect(await harness.recorder.failures().isEmpty)
    #expect(harness.peer.closeCount() == 0)

    harness.peer.emit(.controlDataChannelStateChanged(.open))
    try await nativeFriendViewerEventually {
      await harness.recorder.handoffCount() == 1
    }
    #expect(await harness.recorder.failures().isEmpty)
    #expect(harness.peer.closeCount() == 0)

    await harness.session.close()
    #expect(harness.peer.closeCount() == 1)
  }

  @Test("close supersedes an in-flight rendezvous attach")
  func closeSupersedesAttach() async throws {
    let fixture = try NativeFriendViewerFixture()
    let gate = NativeFriendViewerTestGate()
    let transport = NativeFriendViewerTestTransport(attachGate: gate)
    let peer = NativeFriendViewerTestPeer()
    let factory = NativeFriendViewerTestPeerFactory(peer: peer)
    let session = ClipLiveShareNativeFriendViewerSession(
      target: fixture.target,
      expectedHostIdentity: fixture.hostSigner.publicKey,
      viewerIdentitySigner: fixture.viewerSigner,
      viewerDeviceName: "Tomas Mac",
      transport: transport,
      peerViewerFactory: factory,
      now: { fixture.now }
    )
    let starting = Task { try await session.start() }
    try await nativeFriendViewerEventually {
      await transport.attachCount() == 1
    }

    await session.close()
    await gate.open()
    await #expect(throws: CancellationError.self) {
      try await starting.value
    }
    await transport.emit(
      .routeOpened(
        routeID: fixture.routeID.rawValue,
        descriptor: try ClipLiveShareNativeV2MessageCodec.encode(
          fixture.signedDescriptor()
        )
      )
    )
    try await Task.sleep(for: .milliseconds(20))
    #expect(await transport.sentPayloads().isEmpty)
    #expect(factory.makeCount() == 0)
  }
}

private struct NativeFriendViewerFixture: Sendable {
  let endpoint: ClipLiveShareServerEndpoint
  let target: ClipNativeRendezvousTarget
  let room: ClipLiveShareRoomName
  let roomIdentity: ClipLiveShareRoomIdentity
  let hostSigner: ClipLiveShareSoftwareIdentitySigner
  let viewerSigner: ClipLiveShareSoftwareIdentitySigner
  let rendezvousID: ClipLiveShareRendezvousID
  let routeID: ClipLiveShareRouteID
  let sessionID: ClipLiveShareSessionID
  let negotiationID: ClipLiveShareNegotiationID
  let revision: ClipLiveShareStateRevision
  let now: ClipLiveShareNativeTimestamp

  init() throws {
    endpoint = try ClipLiveShareServerEndpoint(userInput: "https://share.example")
    let idBytes = Data(repeating: 0x51, count: ClipLiveShareNativeV2.rendezvousIDByteCount)
    rendezvousID = try ClipLiveShareRendezvousID(bytes: idBytes)
    target = try ClipNativeRendezvousTarget(
      endpoint: endpoint.rootURL,
      rendezvousID: idBytes
    )
    room = try ClipLiveShareRoomName(rawValue: "AMBER-PINE-119")
    roomIdentity = ClipLiveShareRoomIdentity()
    hostSigner = ClipLiveShareSoftwareIdentitySigner()
    viewerSigner = ClipLiveShareSoftwareIdentitySigner()
    routeID = try ClipLiveShareRouteID(
      bytes: Data(repeating: 0x42, count: ClipLiveShareV1.routeIDByteCount)
    )
    sessionID = try ClipLiveShareSessionID(rawValue: "native-friend-session")
    negotiationID = try ClipLiveShareNegotiationID(rawValue: "native-friend-negotiation")
    revision = try ClipLiveShareStateRevision(rawValue: 7)
    now = try ClipLiveShareNativeTimestamp(millisecondsSince1970: 1_000_000)
  }

  func descriptor(
    hostIdentity: ClipLiveShareIdentityPublicKey,
    endpoint: ClipLiveShareServerEndpoint? = nil,
    room: ClipLiveShareRoomName? = nil,
    rendezvousID: ClipLiveShareRendezvousID? = nil
  ) throws -> ClipLiveShareNativeSessionDescriptor {
    try .init(
      endpoint: endpoint ?? self.endpoint,
      room: room ?? self.room,
      rendezvousID: rendezvousID ?? self.rendezvousID,
      hostIdentity: hostIdentity,
      roomPublicKey: roomIdentity.publicKey,
      sessionID: sessionID,
      issuedAt: now,
      expiresAt: now.adding(milliseconds: 300_000),
      stateRevision: revision
    )
  }

  func signedDescriptor(
    signer: ClipLiveShareSoftwareIdentitySigner? = nil,
    endpoint: ClipLiveShareServerEndpoint? = nil,
    room: ClipLiveShareRoomName? = nil,
    rendezvousID: ClipLiveShareRendezvousID? = nil
  ) throws -> ClipLiveShareSignedNativeSessionDescriptor {
    let signer = signer ?? hostSigner
    return try .init(
      signing: descriptor(
        hostIdentity: signer.publicKey,
        endpoint: endpoint,
        room: room,
        rendezvousID: rendezvousID
      ),
      with: signer
    )
  }

  func challenge(
    viewerKey: ClipLiveShareKeyAgreementPublicKey,
    routeID: ClipLiveShareRouteID? = nil
  ) throws -> ClipLiveShareNativeViewerChallenge {
    try .init(
      sessionDescriptorDigest: signedDescriptor().descriptor.digest,
      sessionID: sessionID,
      routeID: routeID ?? self.routeID,
      viewerEphemeralPublicKey: viewerKey,
      challenge: Data(repeating: 0xA5, count: ClipLiveShareNativeV2.challengeByteCount),
      issuedAt: now,
      expiresAt: now.adding(milliseconds: 60_000),
      stateRevision: revision
    )
  }

  func hostChannel(
    viewerKey: ClipLiveShareKeyAgreementPublicKey
  ) throws -> ClipLiveShareEncryptedChannel {
    try .init(
      host: roomIdentity,
      viewerPublicKey: viewerKey,
      room: room,
      routeID: routeID
    )
  }

  func makeHarness() -> NativeFriendViewerHarness {
    let transport = NativeFriendViewerTestTransport()
    let peer = NativeFriendViewerTestPeer()
    let peerFactory = NativeFriendViewerTestPeerFactory(peer: peer)
    let recorder = NativeFriendViewerEventRecorder()
    let session = ClipLiveShareNativeFriendViewerSession(
      target: target,
      expectedHostIdentity: hostSigner.publicKey,
      viewerIdentitySigner: viewerSigner,
      viewerDeviceName: "Tomas Mac",
      transport: transport,
      peerViewerFactory: peerFactory,
      eventQueue: DispatchQueue(label: "clip.native-friend-viewer-tests"),
      now: { now }
    )
    return .init(
      session: session,
      transport: transport,
      peer: peer,
      peerFactory: peerFactory,
      recorder: recorder
    )
  }
}

private struct NativeFriendViewerHarness: Sendable {
  let session: ClipLiveShareNativeFriendViewerSession
  let transport: NativeFriendViewerTestTransport
  let peer: NativeFriendViewerTestPeer
  let peerFactory: NativeFriendViewerTestPeerFactory
  let recorder: NativeFriendViewerEventRecorder

  func recordEvents() async -> Task<Void, Never> {
    let stream = await session.events()
    return Task {
      for await event in stream { await recorder.append(event) }
    }
  }

  func openRoute(
    fixture: NativeFriendViewerFixture
  ) async throws -> ClipLiveShareViewerHello {
    await transport.emit(
      .routeOpened(
        routeID: fixture.routeID.rawValue,
        descriptor: try ClipLiveShareNativeV2MessageCodec.encode(
          fixture.signedDescriptor()
        )
      )
    )
    try await nativeFriendViewerEventually {
      await transport.sentPayloads().count == 1
    }
    let messages = try await transport.decodedOuterMessages()
    guard case .viewerHello(let hello) = try #require(messages.first) else {
      Issue.record("Expected a native viewer hello")
      throw NativeFriendViewerTestError.invalidFixture
    }
    return hello
  }

  func negotiateThroughInitialAnswer(
    fixture: NativeFriendViewerFixture
  ) async throws {
    let hello = try await openRoute(fixture: fixture)
    var hostChannel = try fixture.hostChannel(viewerKey: hello.viewerKey)
    let challenge = try fixture.challenge(viewerKey: hello.viewerKey)
    try await sendHostOpaque(
      hostChannel.sealOpaquePayload(
        try ClipLiveShareNativeV2MessageCodec.encode(challenge)
      ),
      fixture: fixture
    )
    _ = try await awaitAndOpenProof(
      hostChannel: &hostChannel,
      fixture: fixture
    )
    try await sendHostInner(
      hostChannel.seal(
        .authResult(
          try .init(sessionID: fixture.sessionID, allowed: true)
        )
      ),
      fixture: fixture
    )
    try await nativeFriendViewerEventually {
      await recorder.authenticatedSessionID() == fixture.sessionID
    }
    let offer = try ClipLiveShareSessionDescription(
      sessionID: fixture.sessionID,
      negotiationID: fixture.negotiationID,
      sdp: "v=0\r\no=host 1 1 IN IP4 127.0.0.1\r\n"
    )
    try await sendHostInner(
      hostChannel.seal(.offer(offer)),
      fixture: fixture
    )
    try await nativeFriendViewerEventually {
      let payloadCount = await transport.sentPayloads().count
      return peer.answerCount() == 1 && payloadCount == 3
    }
  }

  func sendHostOpaque(
    _ envelope: ClipLiveShareRelayEnvelope,
    fixture: NativeFriendViewerFixture
  ) async throws {
    let payload = try ClipLiveShareMessageCodec.encodeOuter(.relay(envelope))
    await transport.emit(
      .relay(
        routeID: fixture.routeID.rawValue,
        payload: payload,
        sequence: envelope.sequence
      )
    )
  }

  func sendHostInner(
    _ envelope: ClipLiveShareRelayEnvelope,
    fixture: NativeFriendViewerFixture
  ) async throws {
    try await sendHostOpaque(envelope, fixture: fixture)
  }

  func awaitAndOpenProof(
    hostChannel: inout ClipLiveShareEncryptedChannel,
    fixture: NativeFriendViewerFixture
  ) async throws -> ClipLiveShareSignedNativeViewerProof {
    try await nativeFriendViewerEventually {
      await transport.sentPayloads().count == 2
    }
    let envelope = try await sentRelay(at: 1)
    #expect(envelope.routeID == fixture.routeID)
    let data = try hostChannel.openOpaquePayload(envelope)
    return try ClipLiveShareNativeV2MessageCodec.decode(
      ClipLiveShareSignedNativeViewerProof.self,
      from: data
    )
  }

  func sentRelay(at index: Int) async throws -> ClipLiveShareRelayEnvelope {
    let messages = try await transport.decodedOuterMessages()
    guard messages.indices.contains(index), case .relay(let envelope) = messages[index] else {
      Issue.record("Expected native encrypted relay at index \(index)")
      throw NativeFriendViewerTestError.invalidFixture
    }
    return envelope
  }
}

private actor NativeFriendViewerTestTransport:
  ClipLiveShareNativeFriendViewerTransport
{
  private let attachGate: NativeFriendViewerTestGate?
  private var continuation: AsyncStream<ClipNativeRendezvousEvent>.Continuation?
  private var sent: [Data] = []
  private var closeRouteReasons: [String?] = []
  private var teardowns = 0
  private var attaches = 0

  init(attachGate: NativeFriendViewerTestGate? = nil) {
    self.attachGate = attachGate
  }

  func nativeFriendEvents() -> AsyncStream<ClipNativeRendezvousEvent> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: ClipNativeRendezvousEvent.self,
      bufferingPolicy: .bufferingNewest(128)
    )
    self.continuation = continuation
    return stream
  }

  func nativeFriendAttachViewer(
    _ target: ClipNativeRendezvousTarget
  ) async throws -> ClipNativeRendezvousCapabilities {
    attaches += 1
    await attachGate?.wait()
    continuation?.yield(.connected(role: .viewer, reconnectAttempt: 0))
    return try .init(serverVersion: "native-friend-test")
  }

  func nativeFriendSend(_ payload: Data) throws { sent.append(payload) }

  func nativeFriendCloseRoute(reason: String?) {
    closeRouteReasons.append(reason)
  }

  func nativeFriendTeardown() { teardowns += 1 }

  func emit(_ event: ClipNativeRendezvousEvent) {
    continuation?.yield(event)
  }

  func sentPayloads() -> [Data] { sent }

  func decodedOuterMessages() throws -> [ClipLiveShareOuterMessage] {
    try sent.map { try ClipLiveShareMessageCodec.decodeOuter($0) }
  }

  func closeReasons() -> [String?] { closeRouteReasons }
  func teardownCount() -> Int { teardowns }
  func attachCount() -> Int { attaches }
}

private final class NativeFriendViewerTestPeer:
  ClipLiveShareNativeFriendPeerViewer, @unchecked Sendable
{
  private let lock = NSLock()
  private var handler: WebRTCPeerViewer.EventHandler?
  private var receivedOffers: [WebRTCSessionDescription] = []
  private var candidates: [WebRTCICECandidate] = []
  private var sentControls: [(Data, Bool)] = []
  private var closes = 0
  private var isClosed = false

  var remoteVideoStreams: [WebRTCRemoteVideoStream] { [] }

  var snapshot: WebRTCPeerViewerSnapshot {
    lock.withLock {
      .init(
        connectionState: isClosed ? .closed : .new,
        controlDataChannelState: isClosed ? .closed : .connecting,
        route: .unknown,
        negotiatedVideoTrackIDs: [],
        boundStreams: [],
        systemAudioTrackID: nil,
        isSystemAudioPlaybackEnabled: true,
        systemAudioVolume: 1,
        isClosed: isClosed
      )
    }
  }

  func install(_ handler: @escaping WebRTCPeerViewer.EventHandler) {
    lock.withLock { self.handler = handler }
  }

  func answer(
    _ offer: WebRTCSessionDescription
  ) async throws -> WebRTCSessionDescription {
    lock.withLock { receivedOffers.append(offer) }
    return .init(
      kind: .answer,
      sdp: "v=0\r\no=viewer 2 2 IN IP4 127.0.0.1\r\n"
    )
  }

  func addRemoteICECandidate(_ candidate: WebRTCICECandidate) async throws {
    lock.withLock { candidates.append(candidate) }
  }

  func applyRemoteStreamManifest(_ manifest: ClipLiveShareStreamManifest) {}

  func sendControl(_ data: Data, isBinary: Bool) -> Bool {
    lock.withLock {
      guard !isClosed else { return false }
      sentControls.append((data, isBinary))
      return true
    }
  }

  func setSystemAudioPlaybackEnabled(_ enabled: Bool) {}
  func setSystemAudioVolume(_ volume: Double) {}

  func inboundStatisticsSnapshot() async throws -> WebRTCInboundStatisticsSnapshot {
    .init(
      capturedAt: Date(timeIntervalSince1970: 0),
      route: .unknown,
      tracks: []
    )
  }

  func close() {
    lock.withLock {
      guard !isClosed else { return }
      isClosed = true
      closes += 1
    }
  }

  func emit(_ event: WebRTCPeerViewerEvent) {
    lock.withLock { handler }?(event)
  }

  func answerCount() -> Int { lock.withLock { receivedOffers.count } }
  func controls() -> [(Data, Bool)] { lock.withLock { sentControls } }
  func closeCount() -> Int { lock.withLock { closes } }
}

private final class NativeFriendViewerTestPeerFactory:
  ClipLiveShareNativeFriendPeerViewerFactory, @unchecked Sendable
{
  private let lock = NSLock()
  private let peer: NativeFriendViewerTestPeer
  private var makes = 0

  init(peer: NativeFriendViewerTestPeer) { self.peer = peer }

  func makeViewer(
    configuration: WebRTCPeerViewerConfiguration,
    eventQueue: DispatchQueue,
    eventHandler: @escaping WebRTCPeerViewer.EventHandler
  ) throws -> any ClipLiveShareNativeFriendPeerViewer {
    lock.withLock { makes += 1 }
    peer.install(eventHandler)
    return peer
  }

  func makeCount() -> Int { lock.withLock { makes } }
}

private actor NativeFriendViewerEventRecorder {
  private var events: [ClipLiveShareNativeFriendViewerSessionEvent] = []

  func append(_ event: ClipLiveShareNativeFriendViewerSessionEvent) {
    events.append(event)
  }

  func failures() -> [ClipLiveShareNativeFriendViewerSessionError] {
    events.compactMap { event in
      if case .failed(let error) = event { return error }
      return nil
    }
  }

  func authenticatedSessionID() -> ClipLiveShareSessionID? {
    for case .authenticated(let sessionID) in events { return sessionID }
    return nil
  }

  func handoffCount() -> Int {
    events.count { event in
      if case .rendezvousHandoffCompleted = event { return true }
      return false
    }
  }
}

private actor NativeFriendViewerTestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let current = waiters
    waiters.removeAll()
    for waiter in current { waiter.resume() }
  }
}

private enum NativeFriendViewerTestError: Error { case invalidFixture, timeout }

private func nativeFriendViewerEventually(
  _ predicate: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<400 {
    if await predicate() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for native friend viewer session state")
  throw NativeFriendViewerTestError.timeout
}
