import ClipLiveShare
import Foundation
import Synchronization
import Testing
@testable import ClipLiveShareWebRTC

@Suite("GoPeep v1 signaling transport")
struct GoPeepV1SignalingTransportTests {
    @Test("reservation POST is exact and decodes credentials")
    func reservesRoom() async throws {
        let payload = Data(#"{"room":"CRISP-FROG-042","secret":"host-secret"}"#.utf8)
        let http = MockHTTPTransport(result: .success(.init(statusCode: 200, data: payload)))
        let client = makeClient(http: http)

        let reservation = try await client.reserveRoom()

        #expect(reservation.room.rawValue == "CRISP-FROG-042")
        #expect(reservation.secret == "host-secret")
        let requests = await http.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].url == URL(string: "https://signal.example/api/reserve"))
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(requests[0].httpBody == nil)
        #expect(requests[0].timeoutInterval == 5)
    }

    @Test("reservation failures are typed and redact transport details")
    func reservationFailuresAreSafe() async throws {
        let rejectedHTTP = MockHTTPTransport(
            result: .success(.init(statusCode: 503, data: Data("password=leak".utf8)))
        )
        let rejectedClient = makeClient(http: rejectedHTTP)
        await #expect(throws: GoPeepV1SignalingError.reservationRejected(statusCode: 503)) {
            try await rejectedClient.reserveRoom()
        }

        let malformedHTTP = MockHTTPTransport(
            result: .success(.init(statusCode: 200, data: Data(#"{"secret":"leak"}"#.utf8)))
        )
        let malformedClient = makeClient(http: malformedHTTP)
        await #expect(throws: GoPeepV1SignalingError.invalidReservationResponse) {
            try await malformedClient.reserveRoom()
        }

        let failedHTTP = MockHTTPTransport(result: .failure(.containingSecret("secret-value")))
        let failedClient = makeClient(http: failedHTTP)
        do {
            _ = try await failedClient.reserveRoom()
            Issue.record("Expected reservation failure")
        } catch {
            #expect(error as? GoPeepV1SignalingError == .reservationRequestFailed)
            #expect(!String(describing: error).contains("secret-value"))
        }

        let oversizedHTTP = MockHTTPTransport(result: .success(.init(
            statusCode: 200,
            data: Data(
                repeating: 0x78,
                count: GoPeepV1SignalingResourceLimits.maximumReservationResponseBytes + 1
            )
        )))
        let oversizedClient = makeClient(http: oversizedHTTP)
        await #expect(throws: GoPeepV1SignalingError.invalidReservationResponse) {
            try await oversizedClient.reserveRoom()
        }
    }

    @Test("connect uses the room URL and sends sharer join before receiving")
    func connectsAndJoins() async throws {
        let socket = MockWebSocket()
        let factory = MockWebSocketFactory(results: [.success(socket)])
        let logs = Mutex<[GoPeepV1SignalingLogEntry]>([])
        let client = makeClient(factory: factory) { entry in
            logs.withLock { $0.append(entry) }
        }
        let eventRecorder = await recordEvents(from: client)

        try await client.connect(room: try makeRoom(secret: "host-secret", password: "viewer-pass"))

        #expect(await socket.resumeCount() == 1)
        #expect(await factory.requestedURLs() == [URL(string: "wss://signal.example/ws/CRISP-FROG-042")!])
        let sent = await socket.sentPayloads()
        #expect(sent.count == 1)
        let join = try decode(sent[0])
        #expect(join.type == .join)
        #expect(join.role == .sharer)
        #expect(join.room.isEmpty)
        #expect(join.secret == "host-secret")
        #expect(join.password == "viewer-pass")

        try await eventually {
            await eventRecorder.snapshot().count == 2
        }
        let events = await eventRecorder.snapshot()
        #expect(events == [
            .connecting(room: try roomCode(), reconnectAttempt: 0),
            .connected(room: try roomCode(), reconnectAttempt: 0),
        ])

        let logDescriptions = logs.withLock { $0.map(\.description).joined(separator: "\n") }
        #expect(!logDescriptions.contains("host-secret"))
        #expect(!logDescriptions.contains("viewer-pass"))
        #expect(!logDescriptions.contains("CRISP-FROG-042"))
        await client.stop()
    }

    @Test("text and binary messages produce typed events; malformed JSON does not kill the socket")
    func receivesTypedMessages() async throws {
        let socket = MockWebSocket()
        let client = makeClient(factory: MockWebSocketFactory(results: [.success(socket)]))
        let recorder = await recordEvents(from: client)
        try await client.connect(room: try makeRoom())

        let viewerJoined = GoPeepV1Message(type: .viewerJoined)
        await socket.enqueue(.text(String(decoding: try JSONEncoder().encode(viewerJoined), as: UTF8.self)))
        await socket.enqueue(.data(try JSONEncoder().encode(
            GoPeepV1Message(type: .answer, sdp: "answer-sdp", peerID: "peer-1")
        )))
        await socket.enqueue(.text("{not-json"))

        try await eventually {
            await recorder.snapshot().count >= 5
        }
        let events = await recorder.snapshot()
        #expect(events.contains(.message(viewerJoined)))
        #expect(events.contains(.message(
            GoPeepV1Message(type: .answer, sdp: "answer-sdp", peerID: "peer-1")
        )))
        #expect(events.contains(.invalidMessageReceived))

        try await client.send(GoPeepV1Message(type: .ice, candidate: "candidate", peerID: "peer-1"))
        #expect(await socket.sentPayloads().count == 2)
        await client.stop()
    }

    @Test("oversized signaling payloads are rejected without poisoning later receives")
    func signalingPayloadLimits() async throws {
        let socket = MockWebSocket()
        let client = makeClient(factory: MockWebSocketFactory(results: [.success(socket)]))
        let recorder = await recordEvents(from: client)
        try await client.connect(room: try makeRoom())

        await socket.enqueue(.data(Data(
            repeating: 0x78,
            count: GoPeepV1SignalingResourceLimits.maximumMessagePayloadBytes + 1
        )))
        let valid = GoPeepV1Message(type: .viewerJoined, peerID: "peer-after-limit")
        await socket.enqueue(.data(try JSONEncoder().encode(valid)))

        try await eventually {
            let events = await recorder.snapshot()
            return events.contains(.invalidMessageReceived) && events.contains(.message(valid))
        }

        await #expect(throws: GoPeepV1SignalingError.sendFailed) {
            try await client.send(GoPeepV1Message(
                type: .offer,
                sdp: String(
                    repeating: "x",
                    count: GoPeepV1SignalingResourceLimits.maximumMessagePayloadBytes
                ),
                peerID: "peer-1"
            ))
        }
        #expect(await socket.sentPayloads().count == 1)
    }

    @Test("observer queue overflow is bounded and explicit instead of silently losing signaling")
    func eventQueueOverflowFailsClosed() async throws {
        let socket = MockWebSocket()
        let client = makeClient(factory: MockWebSocketFactory(results: [.success(socket)]))
        let stream = await client.events()
        try await client.connect(room: try makeRoom())

        let payload = GoPeepV1WebSocketPayload.data(try JSONEncoder().encode(
            GoPeepV1Message(type: .viewerJoined)
        ))
        for _ in 0..<150 {
            await socket.enqueue(payload)
        }
        try await eventually {
            await socket.receiveCount() >= 130
        }

        var observed: [GoPeepV1SignalingEvent] = []
        for await event in stream {
            observed.append(event)
        }
        #expect(observed.count <= 128)
        #expect(observed.last == .eventBufferOverflow)
        await client.stop()
    }

    @Test("control messages cannot accidentally leak onto the signaling socket")
    func rejectsControlMessages() async throws {
        let socket = MockWebSocket()
        let client = makeClient(factory: MockWebSocketFactory(results: [.success(socket)]))
        try await client.connect(room: try makeRoom())

        let message = GoPeepV1Message(type: .cursorPosition, cursorX: 40, cursorY: 20)
        await #expect(
            throws: GoPeepV1SignalingError.controlMessageRequiresDataChannel(type: .cursorPosition)
        ) {
            try await client.send(message)
        }
        #expect(await socket.sentPayloads().count == 1)
        await client.stop()
    }

    @Test("connection loss reconnects with fresh socket and repeats the credentialed join")
    func reconnects() async throws {
        let first = MockWebSocket()
        let second = MockWebSocket()
        let factory = MockWebSocketFactory(results: [.success(first), .success(second)])
        let sleeper = ImmediateReconnectSleeper()
        let client = makeClient(
            factory: factory,
            reconnectPolicy: .init(delaysMilliseconds: [17]),
            sleeper: sleeper
        )
        let recorder = await recordEvents(from: client)
        try await client.connect(room: try makeRoom(secret: "rejoin-secret", password: "rejoin-pass"))
        try await client.send(GoPeepV1Message(type: .passwordUpdate, password: "updated-pass"))

        await first.failReceive()
        try await eventually {
            let requestedURLs = await factory.requestedURLs()
            let sentPayloads = await second.sentPayloads()
            return requestedURLs.count == 2 && sentPayloads.count == 1
        }

        #expect(await sleeper.recordedDurations() == [.milliseconds(17)])
        let rejoin = try decode(await second.sentPayloads()[0])
        #expect(rejoin.type == .join)
        #expect(rejoin.secret == "rejoin-secret")
        #expect(rejoin.password == "updated-pass")
        try await eventually {
            await recorder.snapshot().contains(
                .connected(room: try! roomCode(), reconnectAttempt: 1)
            )
        }
        let events = await recorder.snapshot()
        #expect(events.contains(.disconnected(reason: .connectionLost, willReconnect: true)))
        #expect(events.contains(.reconnectScheduled(attempt: 1, delay: .milliseconds(17))))
        #expect(events.contains(.connected(room: try roomCode(), reconnectAttempt: 1)))
        await client.stop()
    }

    @Test("retry exhaustion is visible and does not loop forever")
    func retryExhaustion() async throws {
        let first = MockWebSocket()
        let factory = MockWebSocketFactory(results: [
            .success(first),
            .failure(.connectionFailed),
            .failure(.connectionFailed),
        ])
        let client = makeClient(
            factory: factory,
            reconnectPolicy: .init(delaysMilliseconds: [0, 0]),
            sleeper: ImmediateReconnectSleeper()
        )
        let recorder = await recordEvents(from: client)
        try await client.connect(room: try makeRoom())

        await first.failReceive()
        try await eventually {
            await recorder.snapshot().contains(
                .disconnected(reason: .reconnectExhausted, willReconnect: false)
            )
        }
        #expect(await factory.requestedURLs().count == 3)
    }

    @Test("stop closes the socket and suppresses reconnect")
    func stopsCleanly() async throws {
        let socket = MockWebSocket()
        let factory = MockWebSocketFactory(results: [.success(socket)])
        let client = makeClient(
            factory: factory,
            reconnectPolicy: .init(delaysMilliseconds: [0]),
            sleeper: ImmediateReconnectSleeper()
        )
        let recorder = await recordEvents(from: client)
        try await client.connect(room: try makeRoom())
        await client.stop()

        #expect(await socket.closeCount() == 1)
        #expect(await factory.requestedURLs().count == 1)
        try await eventually {
            await recorder.snapshot().last == .stopped
        }
        #expect(await recorder.snapshot().last == .stopped)
        await #expect(throws: GoPeepV1SignalingError.notConnected) {
            try await client.send(GoPeepV1Message(type: .ice, candidate: "candidate"))
        }
    }

    @Test("a delayed initial socket cannot replace a newer session after stop")
    func delayedInitialSocketCannotReplaceNewSession() async throws {
        let staleSocket = MockWebSocket()
        let replacementSocket = MockWebSocket()
        let staleFactoryGate = AsyncGate()
        let factory = DelayedWebSocketFactory(steps: [
            .afterGate(staleFactoryGate, staleSocket),
            .immediate(replacementSocket),
        ])
        let client = makeClient(factory: factory)
        let recorder = await recordEvents(from: client)

        let staleConnect = Task {
            try await client.connect(room: makeRoom(secret: "stale-secret"))
        }
        try await eventually {
            await factory.requestedURLs().count == 1
        }

        await client.stop()
        try await client.connect(room: makeRoom(secret: "replacement-secret"))
        await staleFactoryGate.open()

        do {
            try await staleConnect.value
            Issue.record("Expected the superseded connect to fail")
        } catch {
            #expect(error as? GoPeepV1SignalingError == .connectionFailed)
        }

        #expect(await staleSocket.resumeCount() == 0)
        #expect(await staleSocket.sentPayloads().isEmpty)
        #expect(await staleSocket.closeCount() == 1)
        #expect(await replacementSocket.resumeCount() == 1)
        let replacementJoin = try decode(await replacementSocket.sentPayloads()[0])
        #expect(replacementJoin.secret == "replacement-secret")

        try await client.send(
            GoPeepV1Message(type: .ice, candidate: "replacement-candidate", peerID: "peer-1")
        )
        #expect(await replacementSocket.sentPayloads().count == 2)
        #expect(await staleSocket.sentPayloads().isEmpty)

        let events = await recorder.snapshot()
        let connectedEvents = events.filter {
            if case .connected = $0 { return true }
            return false
        }
        #expect(connectedEvents.count == 1)
        await client.stop()
    }

    @Test("stop invalidates a reconnect suspended in the socket factory")
    func stopInvalidatesDelayedReconnectFactory() async throws {
        let firstSocket = MockWebSocket()
        let staleReconnectSocket = MockWebSocket()
        let reconnectFactoryGate = AsyncGate()
        let factory = DelayedWebSocketFactory(steps: [
            .immediate(firstSocket),
            .afterGate(reconnectFactoryGate, staleReconnectSocket),
        ])
        let client = makeClient(
            factory: factory,
            reconnectPolicy: .init(delaysMilliseconds: [0]),
            sleeper: ImmediateReconnectSleeper()
        )
        let recorder = await recordEvents(from: client)
        try await client.connect(room: makeRoom(secret: "reconnect-secret"))

        await firstSocket.failReceive()
        try await eventually {
            await factory.requestedURLs().count == 2
        }
        await client.stop()
        await reconnectFactoryGate.open()

        try await eventually {
            await staleReconnectSocket.closeCount() == 1
        }
        #expect(await staleReconnectSocket.resumeCount() == 0)
        #expect(await staleReconnectSocket.sentPayloads().isEmpty)
        #expect(await staleReconnectSocket.closeCount() == 1)

        let events = await recorder.snapshot()
        #expect(events.last == .stopped)
        #expect(!events.contains(.connected(room: try roomCode(), reconnectAttempt: 1)))
        await #expect(throws: GoPeepV1SignalingError.notConnected) {
            try await client.send(GoPeepV1Message(type: .ice, candidate: "candidate"))
        }
    }
}

private func makeClient(
    http: any GoPeepV1HTTPTransport = MockHTTPTransport(
        result: .success(.init(statusCode: 200, data: Data()))
    ),
    factory: any GoPeepV1WebSocketFactory = MockWebSocketFactory(results: []),
    reconnectPolicy: GoPeepV1ReconnectPolicy = .disabled,
    sleeper: any GoPeepV1ReconnectSleeper = ImmediateReconnectSleeper(),
    logger: @escaping GoPeepV1SignalingClient.Logger = { _ in }
) -> GoPeepV1SignalingClient {
    GoPeepV1SignalingClient(
        server: try! GoPeepV1ServerConfiguration(
            signalingServerURL: URL(string: "wss://signal.example")!
        ),
        httpTransport: http,
        webSocketFactory: factory,
        reconnectPolicy: reconnectPolicy,
        reconnectSleeper: sleeper,
        logger: logger
    )
}

private func makeRoom(
    secret: String = "secret",
    password: String? = nil
) throws -> GoPeepV1RoomConfiguration {
    GoPeepV1RoomConfiguration(
        reservation: try GoPeepV1RoomReservationResponse(room: roomCode(), secret: secret),
        password: password
    )
}

private func roomCode() throws -> GoPeepV1RoomCode {
    try GoPeepV1RoomCode(rawValue: "CRISP-FROG-042")
}

private func decode(_ payload: GoPeepV1WebSocketPayload) throws -> GoPeepV1Message {
    let data: Data = switch payload {
    case .text(let text): Data(text.utf8)
    case .data(let data): data
    }
    return try JSONDecoder().decode(GoPeepV1Message.self, from: data)
}

private actor EventRecorder {
    private var events: [GoPeepV1SignalingEvent] = []

    func append(_ event: GoPeepV1SignalingEvent) {
        events.append(event)
    }

    func snapshot() -> [GoPeepV1SignalingEvent] {
        events
    }
}

private func recordEvents(from client: GoPeepV1SignalingClient) async -> EventRecorder {
    let recorder = EventRecorder()
    let stream = await client.events()
    Task {
        for await event in stream {
            await recorder.append(event)
        }
    }
    return recorder
}

private func eventually(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for asynchronous signaling state")
}

private enum MockFailure: Error, Sendable {
    case connectionFailed
    case containingSecret(String)
}

private actor MockHTTPTransport: GoPeepV1HTTPTransport {
    private let result: Result<GoPeepV1HTTPResult, MockFailure>
    private var requests: [URLRequest] = []

    init(result: Result<GoPeepV1HTTPResult, MockFailure>) {
        self.result = result
    }

    func execute(_ request: URLRequest) throws -> GoPeepV1HTTPResult {
        requests.append(request)
        return try result.get()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private actor MockWebSocket: GoPeepV1WebSocketConnection {
    private var resumes = 0
    private var receives = 0
    private var sends: [GoPeepV1WebSocketPayload] = []
    private var closes = 0
    private var queuedReceives: [Result<GoPeepV1WebSocketPayload, MockFailure>] = []
    private var receiveContinuation: CheckedContinuation<GoPeepV1WebSocketPayload, any Error>?

    func resume() {
        resumes += 1
    }

    func send(_ payload: GoPeepV1WebSocketPayload) {
        sends.append(payload)
    }

    func receive() async throws -> GoPeepV1WebSocketPayload {
        receives += 1
        if !queuedReceives.isEmpty {
            return try queuedReceives.removeFirst().get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func close() {
        closes += 1
        receiveContinuation?.resume(throwing: MockFailure.connectionFailed)
        receiveContinuation = nil
    }

    func enqueue(_ payload: GoPeepV1WebSocketPayload) {
        if let receiveContinuation {
            self.receiveContinuation = nil
            receiveContinuation.resume(returning: payload)
        } else {
            queuedReceives.append(.success(payload))
        }
    }

    func failReceive() {
        if let receiveContinuation {
            self.receiveContinuation = nil
            receiveContinuation.resume(throwing: MockFailure.connectionFailed)
        } else {
            queuedReceives.append(.failure(.connectionFailed))
        }
    }

    func resumeCount() -> Int { resumes }
    func receiveCount() -> Int { receives }
    func sentPayloads() -> [GoPeepV1WebSocketPayload] { sends }
    func closeCount() -> Int { closes }
}

private actor MockWebSocketFactory: GoPeepV1WebSocketFactory {
    private var results: [Result<MockWebSocket, MockFailure>]
    private var urls: [URL] = []

    init(results: [Result<MockWebSocket, MockFailure>]) {
        self.results = results
    }

    func makeConnection(for url: URL) throws -> any GoPeepV1WebSocketConnection {
        urls.append(url)
        guard !results.isEmpty else { throw MockFailure.connectionFailed }
        return try results.removeFirst().get()
    }

    func requestedURLs() -> [URL] {
        urls
    }
}

private enum DelayedWebSocketFactoryStep: Sendable {
    case immediate(MockWebSocket)
    case afterGate(AsyncGate, MockWebSocket)
}

/// A factory whose individual calls can be suspended independently. This models the
/// production URLSession boundary where DNS/TLS/WebSocket creation can outlive Stop.
private actor DelayedWebSocketFactory: GoPeepV1WebSocketFactory {
    private var steps: [DelayedWebSocketFactoryStep]
    private var urls: [URL] = []

    init(steps: [DelayedWebSocketFactoryStep]) {
        self.steps = steps
    }

    func makeConnection(for url: URL) async throws -> any GoPeepV1WebSocketConnection {
        urls.append(url)
        guard !steps.isEmpty else { throw MockFailure.connectionFailed }
        let step = steps.removeFirst()
        switch step {
        case .immediate(let socket):
            return socket
        case .afterGate(let gate, let socket):
            await gate.wait()
            return socket
        }
    }

    func requestedURLs() -> [URL] {
        urls
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor ImmediateReconnectSleeper: GoPeepV1ReconnectSleeper {
    private var durations: [Duration] = []

    func sleep(for duration: Duration) {
        durations.append(duration)
    }

    func recordedDurations() -> [Duration] {
        durations
    }
}
