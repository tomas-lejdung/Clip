import ClipLiveShare
import Foundation
import Testing

@testable import ClipLiveShareWebRTC

@Suite("Clip Live Share v1 viewer session")
struct ClipLiveShareV1ViewerSessionTests {
  @Test("invite discovery uses capability paths and rejects incomplete invites")
  func inviteDiscovery() async throws {
    let fixture = try V1ViewerSessionFixture()
    let socket = V1ViewerSessionTestWebSocket()
    let http = V1ViewerSessionTestHTTP { request, index in
      #expect(index == 0)
      #expect(request.httpMethod == "GET")
      #expect(request.url?.absoluteString == "https://share.example/.well-known/clip-live-share")
      #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
      return .init(statusCode: 200, data: fixture.capabilitiesData)
    }
    let webSocketFactory = V1ViewerSessionTestWebSocketFactory(socket: socket)
    let peer = V1ViewerSessionTestPeer()
    let peerFactory = V1ViewerSessionTestPeerFactory(peer: peer)
    let session = ClipLiveShareV1ViewerSession(
      httpTransport: http,
      webSocketFactory: webSocketFactory,
      peerViewerFactory: peerFactory,
      eventQueue: DispatchQueue(label: "clip.viewer-session.invite-test")
    )
    let recorder = V1ViewerSessionEventRecorder()
    let stream = await session.events()
    let recording = Task {
      for await event in stream { await recorder.append(event) }
    }
    defer { recording.cancel() }

    try await session.start(inviteURL: fixture.inviteURL)

    let request = try #require(await webSocketFactory.recordedRequest())
    #expect(request.url?.scheme == "wss")
    #expect(request.url?.host == "share.example")
    #expect(request.url?.path == "/socket/viewer/AMBER-PINE-119")
    #expect(await socket.resumeCount() == 1)
    #expect(peerFactory.makeCount() == 1)
    try await v1ViewerEventually {
      await recorder.connectedInvite() != nil
    }
    let connected = try #require(await recorder.connectedInvite())
    #expect(connected.originalURL == fixture.inviteURL)
    #expect(connected.endpoint == fixture.endpoint)
    #expect(connected.room == fixture.room)
    #expect(connected.fragment == fixture.fragment)

    let sent = try await socket.decodedOuterMessages()
    guard case let .viewerHello(hello) = try #require(sent.first) else {
      Issue.record("Expected viewer-hello as the first socket message")
      return
    }
    #expect(hello.version == ClipLiveShareV1.version)

    await session.close()

    let invalidHTTP = V1ViewerSessionTestHTTP { _, _ in
      Issue.record("An incomplete invite must fail before HTTP discovery")
      return .init(statusCode: 500, data: Data())
    }
    let invalidFactory = V1ViewerSessionTestWebSocketFactory(
      socket: V1ViewerSessionTestWebSocket()
    )
    let invalidPeerFactory = V1ViewerSessionTestPeerFactory(
      peer: V1ViewerSessionTestPeer()
    )
    let invalidSession = ClipLiveShareV1ViewerSession(
      httpTransport: invalidHTTP,
      webSocketFactory: invalidFactory,
      peerViewerFactory: invalidPeerFactory,
      eventQueue: DispatchQueue(label: "clip.viewer-session.invalid-invite-test")
    )
    await #expect(throws: ClipLiveShareV1ViewerSessionError.invalidInvite) {
      try await invalidSession.start(inviteURL: fixture.inviteURLWithoutFragment)
    }
    #expect(await invalidHTTP.requestCount() == 0)
    #expect(await invalidFactory.recordedRequest() == nil)
    #expect(invalidPeerFactory.makeCount() == 0)
  }

  @Test("an ICE-server gathering failure allows candidate fallback")
  func iceServerGatheringFailureIsNonterminal() async throws {
    let fixture = try V1ViewerSessionFixture()
    let socket = V1ViewerSessionTestWebSocket()
    let peer = V1ViewerSessionTestPeer()
    let session = ClipLiveShareV1ViewerSession(
      httpTransport: fixture.http,
      webSocketFactory: V1ViewerSessionTestWebSocketFactory(socket: socket),
      peerViewerFactory: V1ViewerSessionTestPeerFactory(peer: peer),
      eventQueue: DispatchQueue(label: "clip.viewer-session.ice-fallback-test")
    )
    let recorder = V1ViewerSessionEventRecorder()
    let stream = await session.events()
    let recording = Task {
      for await event in stream { await recorder.append(event) }
    }
    defer { recording.cancel() }

    try await session.start(inviteURL: fixture.inviteURL)
    peer.emit(.error(.iceGatheringFailed(
      code: 701,
      url: "stun:stun.l.google.com:19302",
      message: "STUN binding request timed out"
    )))
    try await Task.sleep(for: .milliseconds(20))

    #expect(await recorder.failures().isEmpty)
    #expect(peer.closeCount() == 0)

    peer.emit(.connectionStateChanged(.failed))
    try await v1ViewerEventually {
      await recorder.failures().contains(
        .peerFailure("The WebRTC connection closed.")
      )
    }
    #expect(peer.closeCount() == 1)
  }

  @Test("viewer hello, route crypto, access code, offer, handoff, and teardown complete")
  func authenticatedHandoff() async throws {
    let fixture = try V1ViewerSessionFixture()
    let socket = V1ViewerSessionTestWebSocket()
    let sessionPeer = V1ViewerSessionTestPeer()
    let session = ClipLiveShareV1ViewerSession(
      httpTransport: fixture.http,
      webSocketFactory: V1ViewerSessionTestWebSocketFactory(socket: socket),
      peerViewerFactory: V1ViewerSessionTestPeerFactory(peer: sessionPeer),
      eventQueue: DispatchQueue(label: "clip.viewer-session.flow-test")
    )
    let recorder = V1ViewerSessionEventRecorder()
    let stream = await session.events()
    let recording = Task {
      for await event in stream { await recorder.append(event) }
    }
    defer { recording.cancel() }

    try await session.start(inviteURL: fixture.inviteURL)
    let helloMessages = try await socket.decodedOuterMessages()
    guard case let .viewerHello(hello) = try #require(helloMessages.first) else {
      Issue.record("Expected viewer hello")
      return
    }

    var hostChannel = try ClipLiveShareEncryptedChannel(
      host: fixture.roomIdentity,
      viewerPublicKey: hello.viewerKey,
      room: fixture.room,
      routeID: fixture.routeID
    )
    try await socket.enqueueOuter(
      .routeOpened(.init(routeID: fixture.routeID))
    )
    try await v1ViewerEventually {
      await socket.receiveCount() >= 2
    }

    let challenge = try ClipLiveShareAuthChallenge(
      sessionID: fixture.sessionID,
      challenge: Data(repeating: 0xA5, count: ClipLiveShareV1.challengeByteCount),
      accessCodeRequired: true
    )
    try await socket.enqueueOuter(.relay(hostChannel.seal(.authChallenge(challenge))))
    try await v1ViewerEventually {
      await recorder.accessCodeRequestCount() == 1
    }
    #expect(await socket.sentPayloadCount() == 1)

    await #expect(throws: ClipLiveShareV1ViewerSessionError.accessCodeRequired) {
      try await session.submitAccessCode("   \n")
    }
    try await session.submitAccessCode("  sky-42 \n")
    try await v1ViewerEventually {
      await socket.sentPayloadCount() == 2
    }

    let responseMessages = try await socket.decodedOuterMessages()
    guard case let .relay(responseEnvelope) = try #require(responseMessages.last),
      case let .authResponse(response) = try hostChannel.open(
        responseEnvelope.forwarded(to: fixture.routeID)
      )
    else {
      Issue.record("Expected encrypted auth response")
      return
    }
    #expect(response.sessionID == fixture.sessionID)
    #expect(
      ClipLiveShareAccessCodeProof.verify(
        try #require(response.proof),
        accessCode: "SKY-42",
        challenge: challenge.challenge,
        sessionID: fixture.sessionID
      )
    )

    try await socket.enqueueOuter(
      .relay(
        hostChannel.seal(
          .authResult(
            try .init(sessionID: fixture.sessionID, allowed: true)
          )))
    )
    try await v1ViewerEventually {
      await recorder.authenticatedSessionID() == fixture.sessionID
    }

    let offer = try ClipLiveShareSessionDescription(
      sessionID: fixture.sessionID,
      negotiationID: fixture.negotiationID,
      sdp: "v=0\r\no=clip 1 1 IN IP4 127.0.0.1\r\n"
    )
    try await socket.enqueueOuter(.relay(hostChannel.seal(.offer(offer))))
    try await v1ViewerEventually {
      let answerCount = sessionPeer.answerCount()
      let payloadCount = await socket.sentPayloadCount()
      return answerCount == 1 && payloadCount == 3
    }
    #expect(sessionPeer.offers() == [.init(kind: .offer, sdp: offer.sdp)])

    let answerMessages = try await socket.decodedOuterMessages()
    guard case let .relay(answerEnvelope) = try #require(answerMessages.last),
      case let .answer(answer) = try hostChannel.open(
        answerEnvelope.forwarded(to: fixture.routeID)
      )
    else {
      Issue.record("Expected encrypted SDP answer")
      return
    }
    #expect(answer.sessionID == fixture.sessionID)
    #expect(answer.negotiationID == fixture.negotiationID)
    #expect(answer.sdp == V1ViewerSessionTestPeer.answerSDP)

    let candidate = try ClipLiveShareICECandidate(
      sessionID: fixture.sessionID,
      negotiationID: fixture.negotiationID,
      candidate: "candidate:1 1 UDP 2122260223 192.0.2.1 5000 typ host",
      sdpMid: "0",
      sdpMLineIndex: 0
    )
    try await socket.enqueueOuter(.relay(hostChannel.seal(.ice(candidate))))
    try await v1ViewerEventually {
      sessionPeer.remoteCandidates().count == 1
    }

    sessionPeer.emit(.controlDataChannelStateChanged(.open))
    try await v1ViewerEventually {
      let handoffCount = await recorder.handoffCount()
      let closeCount = await socket.closeCount()
      return handoffCount == 1 && closeCount == 1
    }
    let handoffMessages = try await socket.decodedOuterMessages()
    guard case let .closeRoute(closedRoute) = try #require(handoffMessages.last) else {
      Issue.record("Expected signaling route closure after DataChannel handoff")
      return
    }
    #expect(closedRoute == fixture.routeID)

    let descriptorData = try ClipLiveShareNativeV2MessageCodec.encode(
      fixture.signedNativeDescriptor()
    )
    sessionPeer.emit(
      .controlMessageReceived(data: descriptorData, isBinary: false)
    )
    try await v1ViewerEventually {
      await recorder.nativeControlMessages() == [descriptorData]
    }
    #expect(await recorder.failures().isEmpty)

    await session.close()
    await session.close()
    try await v1ViewerEventually { await recorder.closedCount() == 1 }
    #expect(sessionPeer.closeCount() == 1)
    #expect(await recorder.closedCount() == 1)
    #expect(await socket.closeCount() == 1)
  }

  @Test("cross-route and malformed signaling fail closed")
  func malformedAndCrossRouteRejection() async throws {
    let fixture = try V1ViewerSessionFixture()
    let crossRouteSocket = V1ViewerSessionTestWebSocket()
    let crossRoutePeer = V1ViewerSessionTestPeer()
    let crossRouteSession = ClipLiveShareV1ViewerSession(
      httpTransport: fixture.http,
      webSocketFactory: V1ViewerSessionTestWebSocketFactory(socket: crossRouteSocket),
      peerViewerFactory: V1ViewerSessionTestPeerFactory(peer: crossRoutePeer),
      eventQueue: DispatchQueue(label: "clip.viewer-session.cross-route-test")
    )
    let crossRouteRecorder = V1ViewerSessionEventRecorder()
    let crossRouteStream = await crossRouteSession.events()
    let crossRouteRecording = Task {
      for await event in crossRouteStream { await crossRouteRecorder.append(event) }
    }
    defer { crossRouteRecording.cancel() }

    try await crossRouteSession.start(inviteURL: fixture.inviteURL)
    let messages = try await crossRouteSocket.decodedOuterMessages()
    guard case let .viewerHello(hello) = try #require(messages.first) else {
      Issue.record("Expected viewer hello")
      return
    }
    try await crossRouteSocket.enqueueOuter(
      .routeOpened(.init(routeID: fixture.routeID))
    )
    try await v1ViewerEventually { await crossRouteSocket.receiveCount() >= 2 }

    let otherRoute = try ClipLiveShareRouteID(bytes: Data(repeating: 0x7E, count: 16))
    var wrongChannel = try ClipLiveShareEncryptedChannel(
      host: fixture.roomIdentity,
      viewerPublicKey: hello.viewerKey,
      room: fixture.room,
      routeID: otherRoute
    )
    let wrongChallenge = try ClipLiveShareAuthChallenge(
      sessionID: fixture.sessionID,
      challenge: Data(repeating: 0x11, count: ClipLiveShareV1.challengeByteCount),
      accessCodeRequired: false
    )
    try await crossRouteSocket.enqueueOuter(
      .relay(wrongChannel.seal(.authChallenge(wrongChallenge)))
    )
    try await v1ViewerEventually {
      await crossRouteRecorder.failures().contains(.invalidSignalingMessage)
    }
    #expect(await crossRouteSocket.closeCount() == 1)
    #expect(crossRoutePeer.closeCount() == 1)

    let malformedSocket = V1ViewerSessionTestWebSocket()
    let malformedPeer = V1ViewerSessionTestPeer()
    let malformedSession = ClipLiveShareV1ViewerSession(
      httpTransport: fixture.http,
      webSocketFactory: V1ViewerSessionTestWebSocketFactory(socket: malformedSocket),
      peerViewerFactory: V1ViewerSessionTestPeerFactory(peer: malformedPeer),
      eventQueue: DispatchQueue(label: "clip.viewer-session.malformed-test")
    )
    let malformedRecorder = V1ViewerSessionEventRecorder()
    let malformedStream = await malformedSession.events()
    let malformedRecording = Task {
      for await event in malformedStream { await malformedRecorder.append(event) }
    }
    defer { malformedRecording.cancel() }

    try await malformedSession.start(inviteURL: fixture.inviteURL)
    await malformedSocket.enqueue(.text("{not-json"))
    try await v1ViewerEventually {
      await malformedRecorder.failures().contains(.invalidSignalingMessage)
    }
    #expect(await malformedSocket.closeCount() == 1)
    #expect(malformedPeer.closeCount() == 1)
  }

  @Test("authentication rejection stays typed instead of becoming malformed signaling")
  func accessCodeRejected() async throws {
    let fixture = try V1ViewerSessionFixture()
    let socket = V1ViewerSessionTestWebSocket()
    let peer = V1ViewerSessionTestPeer()
    let session = ClipLiveShareV1ViewerSession(
      httpTransport: fixture.http,
      webSocketFactory: V1ViewerSessionTestWebSocketFactory(socket: socket),
      peerViewerFactory: V1ViewerSessionTestPeerFactory(peer: peer),
      eventQueue: DispatchQueue(label: "clip.viewer-session.auth-rejection-test")
    )
    let recorder = V1ViewerSessionEventRecorder()
    let stream = await session.events()
    let recording = Task {
      for await event in stream { await recorder.append(event) }
    }
    defer { recording.cancel() }

    try await session.start(inviteURL: fixture.inviteURL, accessCode: "wrong")
    let messages = try await socket.decodedOuterMessages()
    guard case let .viewerHello(hello) = try #require(messages.first) else {
      Issue.record("Expected viewer hello")
      return
    }
    var hostChannel = try ClipLiveShareEncryptedChannel(
      host: fixture.roomIdentity,
      viewerPublicKey: hello.viewerKey,
      room: fixture.room,
      routeID: fixture.routeID
    )
    try await socket.enqueueOuter(.routeOpened(.init(routeID: fixture.routeID)))
    try await v1ViewerEventually { await socket.receiveCount() >= 2 }
    let challenge = try ClipLiveShareAuthChallenge(
      sessionID: fixture.sessionID,
      challenge: Data(repeating: 0x33, count: ClipLiveShareV1.challengeByteCount),
      accessCodeRequired: true
    )
    try await socket.enqueueOuter(.relay(hostChannel.seal(.authChallenge(challenge))))
    try await v1ViewerEventually { await socket.sentPayloadCount() == 2 }
    let responseMessages = try await socket.decodedOuterMessages()
    guard case let .relay(responseEnvelope) = try #require(responseMessages.last) else {
      Issue.record("Expected access-code response")
      return
    }
    _ = try hostChannel.open(responseEnvelope.forwarded(to: fixture.routeID))

    try await socket.enqueueOuter(
      .relay(
        hostChannel.seal(
          .authResult(
            try .init(
              sessionID: fixture.sessionID,
              allowed: false,
              reason: "bad-code"
            ))))
    )
    try await v1ViewerEventually {
      await recorder.failures().contains(.accessCodeRejected)
    }
    let failures = await recorder.failures()
    #expect(!failures.contains(.invalidSignalingMessage))
    #expect(await socket.closeCount() == 1)
    #expect(peer.closeCount() == 1)
  }

  @Test("close supersedes an in-flight invite without reviving stale resources")
  func closeSupersedesStart() async throws {
    let fixture = try V1ViewerSessionFixture()
    let gate = V1ViewerSessionTestGate()
    let http = V1ViewerSessionTestHTTP { _, _ in
      await gate.wait()
      return .init(statusCode: 200, data: fixture.capabilitiesData)
    }
    let socketFactory = V1ViewerSessionTestWebSocketFactory(
      socket: V1ViewerSessionTestWebSocket()
    )
    let peerFactory = V1ViewerSessionTestPeerFactory(peer: V1ViewerSessionTestPeer())
    let session = ClipLiveShareV1ViewerSession(
      httpTransport: http,
      webSocketFactory: socketFactory,
      peerViewerFactory: peerFactory,
      eventQueue: DispatchQueue(label: "clip.viewer-session.close-race-test")
    )
    let recorder = V1ViewerSessionEventRecorder()
    let stream = await session.events()
    let recording = Task {
      for await event in stream { await recorder.append(event) }
    }
    defer { recording.cancel() }

    let starting = Task {
      try await session.start(inviteURL: fixture.inviteURL)
    }
    try await v1ViewerEventually { await http.requestCount() == 1 }
    await session.close()
    await gate.open()

    await #expect(throws: CancellationError.self) {
      try await starting.value
    }
    #expect(peerFactory.makeCount() == 0)
    #expect(await socketFactory.recordedRequest() == nil)
    #expect(await recorder.closedCount() == 1)
  }
}

private struct V1ViewerSessionFixture: Sendable {
  let endpoint: ClipLiveShareServerEndpoint
  let room: ClipLiveShareRoomName
  let roomIdentity: ClipLiveShareRoomIdentity
  let fragment: ClipLiveShareViewerFragment
  let inviteURL: URL
  let inviteURLWithoutFragment: URL
  let capabilities: ClipLiveShareCapabilities
  let capabilitiesData: Data
  let routeID: ClipLiveShareRouteID
  let sessionID: ClipLiveShareSessionID
  let negotiationID: ClipLiveShareNegotiationID

  init() throws {
    endpoint = try ClipLiveShareServerEndpoint(userInput: "https://share.example")
    room = try ClipLiveShareRoomName(rawValue: "AMBER-PINE-119")
    roomIdentity = ClipLiveShareRoomIdentity()
    fragment = try ClipLiveShareViewerFragment(publicKey: roomIdentity.publicKey)
    inviteURLWithoutFragment = try #require(
      URL(string: "https://share.example/watch/AMBER-PINE-119")
    )
    inviteURL = try fragment.adding(to: inviteURLWithoutFragment)
    capabilities = try ClipLiveShareCapabilities(
      protocolIdentifier: ClipLiveShareV1.protocolIdentifier,
      versions: [1],
      serverVersion: "viewer-test",
      viewerPathTemplate: "/watch/{room}",
      hostWebSocketPathTemplate: "/socket/host/{room}",
      viewerWebSocketPathTemplate: "/socket/viewer/{room}",
      iceServers: [],
      limits: .init(
        maximumMessageBytes: ClipLiveShareV1.maximumWebSocketMessageBytes,
        maximumPendingViewersPerRoom: 8
      )
    )
    capabilitiesData = try JSONEncoder().encode(capabilities)
    routeID = try ClipLiveShareRouteID(bytes: Data(repeating: 0x42, count: 16))
    sessionID = try ClipLiveShareSessionID(rawValue: "viewer-session")
    negotiationID = try ClipLiveShareNegotiationID(rawValue: "initial-negotiation")
  }

  var http: V1ViewerSessionTestHTTP {
    let data = capabilitiesData
    return V1ViewerSessionTestHTTP { _, _ in
      .init(statusCode: 200, data: data)
    }
  }

  func signedNativeDescriptor() throws -> ClipLiveShareSignedNativeSessionDescriptor {
    let signer = ClipLiveShareSoftwareIdentitySigner()
    let issuedAt = try ClipLiveShareNativeTimestamp(millisecondsSince1970: 1_000_000)
    let descriptor = try ClipLiveShareNativeSessionDescriptor(
      endpoint: endpoint,
      room: room,
      rendezvousID: ClipLiveShareRendezvousID(
        bytes: Data(repeating: 0x51, count: ClipLiveShareNativeV2.rendezvousIDByteCount)
      ),
      hostIdentity: signer.publicKey,
      roomPublicKey: roomIdentity.publicKey,
      sessionID: sessionID,
      issuedAt: issuedAt,
      expiresAt: issuedAt.adding(milliseconds: 300_000),
      stateRevision: ClipLiveShareStateRevision(rawValue: 1)
    )
    return try .init(signing: descriptor, with: signer)
  }
}

private enum V1ViewerSessionTestFailure: Error, Sendable {
  case closed
  case timeout
}

private actor V1ViewerSessionTestHTTP: ClipLiveShareHTTPTransport {
  typealias Handler = @Sendable (URLRequest, Int) async throws -> ClipLiveShareHTTPResult

  private let handler: Handler
  private var requests: [URLRequest] = []

  init(_ handler: @escaping Handler) {
    self.handler = handler
  }

  func execute(_ request: URLRequest) async throws -> ClipLiveShareHTTPResult {
    let index = requests.count
    requests.append(request)
    return try await handler(request, index)
  }

  func requestCount() -> Int { requests.count }
}

private actor V1ViewerSessionTestWebSocket: ClipLiveShareWebSocketConnection {
  private var didResume = false
  private var didClose = false
  private var resumes = 0
  private var receives = 0
  private var closes = 0
  private var sent: [ClipLiveShareWebSocketPayload] = []
  private var queued: [ClipLiveShareWebSocketPayload] = []
  private var waiter: CheckedContinuation<ClipLiveShareWebSocketPayload, any Error>?

  func resume() throws {
    guard !didClose else { throw V1ViewerSessionTestFailure.closed }
    guard !didResume else { return }
    didResume = true
    resumes += 1
  }

  func send(_ payload: ClipLiveShareWebSocketPayload) throws {
    guard didResume, !didClose else { throw V1ViewerSessionTestFailure.closed }
    sent.append(payload)
  }

  func receive() async throws -> ClipLiveShareWebSocketPayload {
    guard didResume, !didClose else { throw V1ViewerSessionTestFailure.closed }
    receives += 1
    if !queued.isEmpty { return queued.removeFirst() }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }

  func close() {
    guard !didClose else { return }
    didClose = true
    closes += 1
    waiter?.resume(throwing: V1ViewerSessionTestFailure.closed)
    waiter = nil
  }

  func enqueue(_ payload: ClipLiveShareWebSocketPayload) {
    guard !didClose else { return }
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: payload)
    } else {
      queued.append(payload)
    }
  }

  func enqueueOuter(_ message: ClipLiveShareOuterMessage) throws {
    let data = try ClipLiveShareMessageCodec.encodeOuter(message)
    guard let text = String(data: data, encoding: .utf8) else {
      throw V1ViewerSessionTestFailure.closed
    }
    enqueue(.text(text))
  }

  func decodedOuterMessages() throws -> [ClipLiveShareOuterMessage] {
    try sent.map { payload in
      let data: Data =
        switch payload {
        case .text(let text): Data(text.utf8)
        case .data(let data): data
        }
      return try ClipLiveShareMessageCodec.decodeOuter(data)
    }
  }

  func resumeCount() -> Int { resumes }
  func receiveCount() -> Int { receives }
  func sentPayloadCount() -> Int { sent.count }
  func closeCount() -> Int { closes }
}

private actor V1ViewerSessionTestWebSocketFactory: ClipLiveShareWebSocketFactory {
  private let socket: V1ViewerSessionTestWebSocket
  private var request: URLRequest?

  init(socket: V1ViewerSessionTestWebSocket) {
    self.socket = socket
  }

  func makeConnection(
    for request: URLRequest
  ) throws -> any ClipLiveShareWebSocketConnection {
    self.request = request
    return socket
  }

  func recordedRequest() -> URLRequest? { request }
}

private final class V1ViewerSessionTestPeer: ClipLiveShareV1PeerViewer,
  @unchecked Sendable
{
  static let answerSDP = "v=0\r\no=viewer 2 2 IN IP4 127.0.0.1\r\n"

  private let lock = NSLock()
  private var handler: WebRTCPeerViewer.EventHandler?
  private var receivedOffers: [WebRTCSessionDescription] = []
  private var candidates: [WebRTCICECandidate] = []
  private var controls: [(Data, Bool)] = []
  private var manifests: [ClipLiveShareStreamManifest] = []
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
    return .init(kind: .answer, sdp: Self.answerSDP)
  }

  func addRemoteICECandidate(_ candidate: WebRTCICECandidate) async throws {
    lock.withLock { candidates.append(candidate) }
  }

  func applyRemoteStreamManifest(_ manifest: ClipLiveShareStreamManifest) {
    lock.withLock { manifests.append(manifest) }
  }

  func sendControl(_ data: Data, isBinary: Bool) -> Bool {
    lock.withLock {
      guard !isClosed else { return false }
      controls.append((data, isBinary))
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
    let handler = lock.withLock { self.handler }
    handler?(event)
  }

  func answerCount() -> Int { lock.withLock { receivedOffers.count } }
  func offers() -> [WebRTCSessionDescription] { lock.withLock { receivedOffers } }
  func remoteCandidates() -> [WebRTCICECandidate] { lock.withLock { candidates } }
  func closeCount() -> Int { lock.withLock { closes } }
}

private final class V1ViewerSessionTestPeerFactory:
  ClipLiveShareV1PeerViewerFactory, @unchecked Sendable
{
  private let lock = NSLock()
  private let peer: V1ViewerSessionTestPeer
  private var makes = 0

  init(peer: V1ViewerSessionTestPeer) {
    self.peer = peer
  }

  func makeViewer(
    configuration: WebRTCPeerViewerConfiguration,
    eventQueue: DispatchQueue,
    eventHandler: @escaping WebRTCPeerViewer.EventHandler
  ) throws -> any ClipLiveShareV1PeerViewer {
    lock.withLock { makes += 1 }
    peer.install(eventHandler)
    return peer
  }

  func makeCount() -> Int { lock.withLock { makes } }
}

private actor V1ViewerSessionEventRecorder {
  private var events: [ClipLiveShareV1ViewerSessionEvent] = []

  func append(_ event: ClipLiveShareV1ViewerSessionEvent) {
    events.append(event)
  }

  func connectedInvite() -> ClipLiveShareV1ViewerInvite? {
    for case let .signalingConnected(invite) in events { return invite }
    return nil
  }

  func accessCodeRequestCount() -> Int {
    events.count { event in
      if case .accessCodeRequired = event { return true }
      return false
    }
  }

  func authenticatedSessionID() -> ClipLiveShareSessionID? {
    for case let .authenticated(sessionID) in events { return sessionID }
    return nil
  }

  func handoffCount() -> Int {
    events.count { event in
      if case .signalingHandoffCompleted = event { return true }
      return false
    }
  }

  func failures() -> [ClipLiveShareV1ViewerSessionError] {
    events.compactMap { event in
      if case let .failed(error) = event { return error }
      return nil
    }
  }

  func nativeControlMessages() -> [Data] {
    events.compactMap { event in
      if case let .nativeControlMessage(data) = event { return data }
      return nil
    }
  }

  func closedCount() -> Int {
    events.count { event in
      if case .closed = event { return true }
      return false
    }
  }
}

private actor V1ViewerSessionTestGate {
  private var openState = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !openState else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    guard !openState else { return }
    openState = true
    let current = waiters
    waiters.removeAll()
    for waiter in current { waiter.resume() }
  }
}

private func v1ViewerEventually(
  _ predicate: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<400 {
    if await predicate() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for v1 viewer session state")
  throw V1ViewerSessionTestFailure.timeout
}

extension ClipLiveShareRelayEnvelope {
  fileprivate func forwarded(to routeID: ClipLiveShareRouteID) throws -> Self {
    try Self(
      routeID: routeID,
      sequence: sequence,
      nonce: nonce,
      ciphertext: ciphertext
    )
  }
}
