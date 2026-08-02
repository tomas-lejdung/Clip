import ClipLiveShare
import Foundation
import Testing
@testable import ClipLiveShareWebRTC

@Suite("Clip server-room v4 transport")
struct ClipLiveShareServerRoomV4TransportTests {
  @Test("HTTP discovery, room lifecycle, and v4 capabilities are strict")
  func httpLifecycle() async throws {
    let fixture = try V4TransportFixture()
    let http = V4TestHTTPTransport { request, index in
      switch index {
      case 0:
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/.well-known/clip-native-rendezvous")
        return .init(statusCode: 200, data: fixture.capabilitiesData)
      case 1:
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == fixture.roomPath)
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(
          with: body
        ) as? [String: String])
        #expect(object == [
          "ownerToken": fixture.owner.rawValue,
          "creatorHandle": fixture.creator.rawValue,
          "descriptor": fixture.creatorDescriptor.rawValue,
        ])
        return .init(statusCode: 201, data: fixture.leaseData)
      case 2:
        #expect(request.httpMethod == "GET")
        return .init(statusCode: 200, data: try v4JSON([
          "roomId": fixture.roomID.rawValue,
          "state": "active",
          "rosterRevision": 2,
          "memberCount": 1,
        ]))
      case 3:
        #expect(request.httpMethod == "DELETE")
        #expect(request.value(forHTTPHeaderField: "Authorization")
          == "Bearer \(fixture.owner.rawValue)")
        return .init(statusCode: 204, data: Data())
      default:
        Issue.record("Unexpected HTTP request \(index)")
        return .init(statusCode: 500, data: Data())
      }
    }
    let client = ClipLiveShareServerRoomV4HTTPClient(transport: http)

    let capabilities = try await client.discover(at: fixture.endpoint)
    #expect(capabilities == fixture.capabilities)
    #expect(capabilities.webRTCICEServers == [
      .init(urlStrings: ["stun:stun.example.test:3478"])
    ])
    #expect(try capabilities.roomURL(for: fixture.target).path == fixture.roomPath)
    #expect(try capabilities.roomWebSocketURL(for: fixture.target).absoluteString
      == "wss://room.example.test\(fixture.roomPath)/socket")

    let lease = try await client.create(
      target: fixture.target,
      ownerCapability: fixture.owner,
      creatorHandle: fixture.creator,
      descriptor: fixture.creatorDescriptor,
      capabilities: capabilities
    )
    #expect(lease.roomID == fixture.roomID)
    #expect(lease.creatorHandle == fixture.creator)
    #expect(lease.leaseDurationSeconds == 300)
    #expect(try await client.status(
      target: fixture.target,
      capabilities: capabilities
    ).state == .active)
    try await client.delete(
      target: fixture.target,
      ownerCapability: fixture.owner,
      capabilities: capabilities
    )
    #expect(await http.recordedRequests().count == 4)
  }

  @Test("discovery rejects extensions, legacy versions, and malformed ICE")
  func strictCapabilities() async throws {
    let fixture = try V4TransportFixture()
    var extensionObject = try #require(try JSONSerialization.jsonObject(
      with: fixture.capabilitiesData
    ) as? [String: Any])
    extensionObject["extension"] = true
    let extended = try v4JSON(extensionObject)
    let extensionClient = ClipLiveShareServerRoomV4HTTPClient(
      transport: V4TestHTTPTransport { _, _ in .init(statusCode: 200, data: extended) }
    )
    await #expect(throws: ClipLiveShareServerRoomV4TransportError.invalidResponse) {
      try await extensionClient.discover(at: fixture.endpoint)
    }

    var legacyObject = try #require(try JSONSerialization.jsonObject(
      with: fixture.capabilitiesData
    ) as? [String: Any])
    legacyObject["apiVersion"] = 3
    let legacy = try v4JSON(legacyObject)
    let legacyClient = ClipLiveShareServerRoomV4HTTPClient(
      transport: V4TestHTTPTransport { _, _ in .init(statusCode: 200, data: legacy) }
    )
    await #expect(throws: ClipLiveShareServerRoomV4TransportError.invalidCapabilities) {
      try await legacyClient.discover(at: fixture.endpoint)
    }

    var invalidICEObject = try #require(try JSONSerialization.jsonObject(
      with: fixture.capabilitiesData
    ) as? [String: Any])
    invalidICEObject["iceServers"] = [["urls": ["https://example.test"]]]
    let invalidICE = try v4JSON(invalidICEObject)
    let invalidICEClient = ClipLiveShareServerRoomV4HTTPClient(
      transport: V4TestHTTPTransport { _, _ in .init(statusCode: 200, data: invalidICE) }
    )
    await #expect(throws: ClipLiveShareServerRoomV4TransportError.invalidCapabilities) {
      try await invalidICEClient.discover(at: fixture.endpoint)
    }
  }

  @Test("candidate is promoted in place and reconnects with its stable capability")
  func candidatePromotionAndReconnect() async throws {
    let fixture = try V4TransportFixture()
    let first = V4TestWebSocket()
    let second = V4TestWebSocket()
    let factory = V4TestWebSocketFactory(results: [.success(first), .success(second)])
    let transport = ClipLiveShareServerRoomV4Transport(
      webSocketFactory: factory,
      reconnectPolicy: .init(delaysMilliseconds: [0]),
      reconnectSleeper: V4TestSleeper()
    )
    let recorder = V4TestEventRecorder()
    let eventTask = Task {
      for await event in await transport.events() { await recorder.append(event) }
    }
    defer { eventTask.cancel() }

    try await transport.connect(
      to: fixture.target,
      capabilities: fixture.capabilities,
      authentication: .freshCandidate
    )
    let firstRequest = try #require(await factory.recordedRequests().first)
    #expect(firstRequest.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(firstRequest.value(forHTTPHeaderField: "X-Clip-Member-Handle") == nil)

    let knock = try ClipLiveShareServerRoomV4OpaqueJoinKnock(
      ciphertext: Data(repeating: 11, count: 32)
    )
    await #expect(throws: ClipLiveShareServerRoomV4TransportError.invalidMessage) {
      try await transport.sendJoinKnock(sequence: 1, payload: knock)
    }

    await first.enqueue(.text(try fixture.text(.candidateOpened(
      candidateHandle: fixture.candidate,
      roomDescriptor: fixture.creatorDescriptor
    ))))
    try await v4Eventually {
      await recorder.snapshot().contains(.message(.candidateOpened(
        candidateHandle: fixture.candidate,
        roomDescriptor: fixture.creatorDescriptor
      )))
    }
    try await transport.sendJoinKnock(sequence: 1, payload: knock)
    await first.enqueue(.text(try fixture.text(.memberAdmitted(
      memberHandle: fixture.member,
      reconnectCapability: fixture.reconnect,
      roster: fixture.roster
    ))))
    try await v4Eventually {
      await transport.admittedMemberCredentials() == .init(
        handle: fixture.member,
        reconnectCapability: fixture.reconnect
      )
    }

    let signal = try ClipLiveShareServerRoomV4PairSignalEnvelope(
      from: nil,
      to: fixture.creator,
      pairID: fixture.pairID,
      sequence: 1,
      ciphertext: Data(repeating: 9, count: 29)
    )
    try await transport.sendPairSignal(signal)
    let sent = try #require(await first.sentPayloads().last)
    guard case .text(let sentText) = sent else {
      Issue.record("Expected a text pair signal")
      return
    }
    let sentObject = try #require(try JSONSerialization.jsonObject(
      with: Data(sentText.utf8)
    ) as? [String: Any])
    #expect(sentObject["from"] == nil)
    #expect(sentObject["to"] as? String == fixture.creator.rawValue)

    await first.failReceive()
    try await v4Eventually { await factory.recordedRequests().count == 2 }
    let reconnectRequest = try #require(await factory.recordedRequests().last)
    #expect(reconnectRequest.value(forHTTPHeaderField: "Authorization")
      == "Reconnect \(fixture.reconnect.rawValue)")
    #expect(reconnectRequest.value(forHTTPHeaderField: "X-Clip-Member-Handle")
      == fixture.member.rawValue)

    await second.enqueue(.text(try fixture.text(.memberAdmitted(
      memberHandle: fixture.member,
      reconnectCapability: nil,
      roster: fixture.roster
    ))))
    try await v4Eventually {
      await recorder.snapshot().contains(.connected(role: .member, attempt: 1))
    }
    #expect(await transport.admittedMemberCredentials()?.reconnectCapability
      == fixture.reconnect)
    await transport.close()
  }

  @Test("fresh candidate failure is terminal and never creates another identity")
  func candidateFailureDoesNotReconnect() async throws {
    let fixture = try V4TransportFixture()
    let socket = V4TestWebSocket()
    let factory = V4TestWebSocketFactory(results: [.success(socket)])
    let transport = ClipLiveShareServerRoomV4Transport(
      webSocketFactory: factory,
      reconnectPolicy: .persistentExponential,
      reconnectSleeper: V4TestSleeper()
    )
    let recorder = V4TestEventRecorder()
    let eventTask = Task {
      for await event in await transport.events() { await recorder.append(event) }
    }
    defer { eventTask.cancel() }

    try await transport.connect(
      to: fixture.target,
      capabilities: fixture.capabilities,
      authentication: .freshCandidate
    )
    await socket.failReceive()
    try await v4Eventually {
      await recorder.snapshot().contains(.failed(.candidateDisconnectedBeforeAdmission))
    }
    #expect(await factory.recordedRequests().count == 1)
    #expect(await transport.currentAuthentication() == nil)
  }

  @Test("creator and member authentication headers remain role specific")
  func authenticationHeaders() async throws {
    let fixture = try V4TransportFixture()
    let creatorSocket = V4TestWebSocket()
    let creatorFactory = V4TestWebSocketFactory(results: [.success(creatorSocket)])
    let creatorTransport = ClipLiveShareServerRoomV4Transport(
      webSocketFactory: creatorFactory,
      reconnectPolicy: .disabled
    )
    try await creatorTransport.connect(
      to: fixture.target,
      capabilities: fixture.capabilities,
      authentication: .creator(ownerCapability: fixture.owner)
    )
    #expect(await creatorFactory.recordedRequests().first?
      .value(forHTTPHeaderField: "Authorization") == "Bearer \(fixture.owner.rawValue)")
    await creatorTransport.close()

    let memberSocket = V4TestWebSocket()
    let memberFactory = V4TestWebSocketFactory(results: [.success(memberSocket)])
    let memberTransport = ClipLiveShareServerRoomV4Transport(
      webSocketFactory: memberFactory,
      reconnectPolicy: .disabled
    )
    try await memberTransport.connect(
      to: fixture.target,
      capabilities: fixture.capabilities,
      authentication: .member(
        handle: fixture.member,
        reconnectCapability: fixture.reconnect
      )
    )
    let request = try #require(await memberFactory.recordedRequests().first)
    #expect(request.value(forHTTPHeaderField: "Authorization")
      == "Reconnect \(fixture.reconnect.rawValue)")
    #expect(request.value(forHTTPHeaderField: "X-Clip-Member-Handle")
      == fixture.member.rawValue)
    await memberTransport.close()
  }

  @Test("concurrent transport sends are serialized on the underlying socket")
  func sendsAreSerialized() async throws {
    let fixture = try V4TransportFixture()
    let firstGate = V4TestGate()
    let secondGate = V4TestGate()
    let socket = V4TestWebSocket(sendGates: [firstGate, secondGate])
    let transport = ClipLiveShareServerRoomV4Transport(
      webSocketFactory: V4TestWebSocketFactory(results: [.success(socket)]),
      reconnectPolicy: .disabled
    )
    try await transport.connect(
      to: fixture.target,
      capabilities: fixture.capabilities,
      authentication: .creator(ownerCapability: fixture.owner)
    )
    let first = Task {
      try await transport.denyCandidate(fixture.candidate, reason: "first")
    }
    try await v4Eventually { await socket.sentPayloads().count == 1 }
    let secondHandle = try ClipLiveShareServerRoomV4CandidateHandle(
      bytes: Data(repeating: 7, count: 16)
    )
    let second = Task {
      try await transport.denyCandidate(secondHandle, reason: "second")
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(await socket.sentPayloads().count == 1)
    await firstGate.open()
    try await v4Eventually { await socket.sentPayloads().count == 2 }
    await secondGate.open()
    try await first.value
    try await second.value
    await transport.close()
  }
}

private struct V4TransportFixture: Sendable {
  let endpoint = URL(string: "https://room.example.test")!
  let roomID: ClipLiveShareServerRoomV4RoomID
  let target: ClipLiveShareServerRoomV4Target
  let owner: ClipLiveShareServerRoomV4OwnerCapability
  let creator: ClipLiveShareServerRoomV4MemberHandle
  let member: ClipLiveShareServerRoomV4MemberHandle
  let candidate: ClipLiveShareServerRoomV4CandidateHandle
  let reconnect: ClipLiveShareServerRoomV4ReconnectCapability
  let creatorDescriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord
  let memberDescriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord
  let pairID: ClipLiveShareServerRoomV4PairID
  let capabilities: ClipLiveShareServerRoomV4Capabilities
  let capabilitiesData: Data
  let leaseData: Data

  var roomPath: String { "/api/native/v4/rooms/\(roomID.rawValue)" }

  init() throws {
    roomID = try .init(bytes: Data(repeating: 1, count: 32))
    owner = try .init(bytes: Data(repeating: 2, count: 32))
    creator = try .init(bytes: Data(repeating: 3, count: 16))
    candidate = try .init(bytes: Data(repeating: 4, count: 16))
    member = candidate.admittedMemberHandle
    reconnect = try .init(bytes: Data(repeating: 5, count: 32))
    creatorDescriptor = try .init(ciphertext: Data(repeating: 6, count: 32))
    memberDescriptor = try .init(ciphertext: Data(repeating: 7, count: 32))
    pairID = try .init(bytes: Data(repeating: 8, count: 32))
    target = try .init(endpoint: endpoint, roomID: roomID)
    capabilities = try .init(
      serverVersion: "test-v4",
      maximumRooms: 100,
      iceServers: [try .init(urls: ["stun:stun.example.test:3478"])]
    )
    capabilitiesData = try v4JSON([
      "protocol": "clip-native-room",
      "apiVersion": 4,
      "messageVersion": 4,
      "serverVersion": "test-v4",
      "roomPathTemplate": "/api/native/v4/rooms/{room}",
      "roomWebSocketPathTemplate": "/api/native/v4/rooms/{room}/socket",
      "maximumMessageBytes": ClipLiveShareServerRoomV4.maximumWireMessageBytes,
      "maximumDescriptorBytes": ClipLiveShareServerRoomV4.maximumOpaqueDescriptorBytes,
      "maximumOpaquePayloadBytes": ClipLiveShareServerRoomV4.maximumPairSignalCiphertextBytes,
      "maximumPendingCandidates": 8,
      "maximumRoomMembers": 4,
      "maximumRooms": 100,
      "iceServers": [["urls": ["stun:stun.example.test:3478"]]],
    ])
    leaseData = try v4JSON([
      "roomId": roomID.rawValue,
      "creatorHandle": creator.rawValue,
      "leaseDurationSeconds": 300,
    ])
  }

  var roster: ClipLiveShareServerRoomV4RosterSnapshot {
    get throws {
      try .init(
        revision: .init(rawValue: 2),
        creatorHandle: creator,
        members: [
          .init(handle: creator, descriptor: creatorDescriptor, connected: true),
          .init(handle: member, descriptor: memberDescriptor, connected: true),
        ]
      )
    }
  }

  func text(_ message: ClipLiveShareServerRoomV4WireMessage) throws -> String {
    let data = try ClipLiveShareServerRoomV4WireCodec.encode(message)
    return try #require(String(data: data, encoding: .utf8))
  }
}

private actor V4TestHTTPTransport: ClipLiveShareHTTPTransport {
  typealias Handler = @Sendable (URLRequest, Int) async throws -> ClipLiveShareHTTPResult
  private let handler: Handler
  private var requests: [URLRequest] = []

  init(handler: @escaping Handler) { self.handler = handler }

  func execute(_ request: URLRequest) async throws -> ClipLiveShareHTTPResult {
    let index = requests.count
    requests.append(request)
    return try await handler(request, index)
  }

  func recordedRequests() -> [URLRequest] { requests }
}

private enum V4TestSocketError: Error, Sendable { case closed }

private actor V4TestWebSocket: ClipLiveShareWebSocketConnection {
  private let sendGates: [V4TestGate]
  private var didResume = false
  private var didClose = false
  private var sent: [ClipLiveShareWebSocketPayload] = []
  private var received: [Result<ClipLiveShareWebSocketPayload, V4TestSocketError>] = []
  private var waiters: [
    CheckedContinuation<Result<ClipLiveShareWebSocketPayload, V4TestSocketError>, Never>
  ] = []

  init(sendGates: [V4TestGate] = []) { self.sendGates = sendGates }

  func resume() throws {
    guard !didClose else { throw V4TestSocketError.closed }
    didResume = true
  }

  func send(_ payload: ClipLiveShareWebSocketPayload) async throws {
    guard didResume, !didClose else { throw V4TestSocketError.closed }
    let index = sent.count
    sent.append(payload)
    if index < sendGates.count { await sendGates[index].wait() }
  }

  func receive() async throws -> ClipLiveShareWebSocketPayload {
    guard didResume, !didClose else { throw V4TestSocketError.closed }
    let result: Result<ClipLiveShareWebSocketPayload, V4TestSocketError>
    if !received.isEmpty {
      result = received.removeFirst()
    } else {
      result = await withCheckedContinuation { waiters.append($0) }
    }
    return try result.get()
  }

  func close() {
    guard !didClose else { return }
    didClose = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume(returning: .failure(.closed)) }
  }

  func enqueue(_ payload: ClipLiveShareWebSocketPayload) {
    enqueueResult(.success(payload))
  }

  func failReceive() { enqueueResult(.failure(.closed)) }

  func sentPayloads() -> [ClipLiveShareWebSocketPayload] { sent }

  private func enqueueResult(
    _ result: Result<ClipLiveShareWebSocketPayload, V4TestSocketError>
  ) {
    if !waiters.isEmpty {
      waiters.removeFirst().resume(returning: result)
    } else {
      received.append(result)
    }
  }
}

private actor V4TestWebSocketFactory: ClipLiveShareWebSocketFactory {
  private var results: [Result<V4TestWebSocket, V4TestSocketError>]
  private var requests: [URLRequest] = []

  init(results: [Result<V4TestWebSocket, V4TestSocketError>]) {
    self.results = results
  }

  func makeConnection(
    for request: URLRequest
  ) async throws -> any ClipLiveShareWebSocketConnection {
    requests.append(request)
    guard !results.isEmpty else { throw V4TestSocketError.closed }
    return try results.removeFirst().get()
  }

  func recordedRequests() -> [URLRequest] { requests }
}

private actor V4TestSleeper: ClipLiveShareReconnectSleeper {
  private var durations: [Duration] = []
  func sleep(for duration: Duration) async throws { durations.append(duration) }
}

private actor V4TestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

private actor V4TestEventRecorder {
  private var events: [ClipLiveShareServerRoomV4TransportEvent] = []
  func append(_ event: ClipLiveShareServerRoomV4TransportEvent) { events.append(event) }
  func snapshot() -> [ClipLiveShareServerRoomV4TransportEvent] { events }
}

private func v4Eventually(
  iterations: Int = 2_000,
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<iterations {
    if await condition() { return }
    await Task.yield()
  }
  Issue.record("Condition did not become true")
}

private func v4JSON(_ object: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
