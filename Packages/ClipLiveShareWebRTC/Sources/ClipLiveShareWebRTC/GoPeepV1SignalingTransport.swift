import ClipLiveShare
import Foundation

// MARK: - Injectable transport boundaries

/// The HTTP result needed by the GoPeep reservation endpoint.
///
/// Keeping `HTTPURLResponse` out of this boundary makes deterministic tests small and
/// avoids carrying nonessential response state across concurrency domains.
public struct GoPeepV1HTTPResult: Equatable, Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol GoPeepV1HTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> GoPeepV1HTTPResult
}

/// Production reservation transport backed by `URLSession`.
public struct URLSessionGoPeepV1HTTPTransport: GoPeepV1HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: URLRequest) async throws -> GoPeepV1HTTPResult {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GoPeepV1SignalingError.invalidHTTPResponse
        }
        return GoPeepV1HTTPResult(statusCode: response.statusCode, data: data)
    }
}

public enum GoPeepV1WebSocketPayload: Equatable, Sendable {
    case text(String)
    case data(Data)
}

/// Hard transport ceilings applied before JSON decoding or socket writes.
/// They are deliberately above normal four-track GoPeep v1 messages while
/// preventing an untrusted signaling endpoint from driving unbounded buffers.
public enum GoPeepV1SignalingResourceLimits {
    public static let maximumReservationResponseBytes = 16_384
    public static let maximumMessagePayloadBytes = 262_144
}

public protocol GoPeepV1WebSocketConnection: Sendable {
    func resume() async throws
    func send(_ payload: GoPeepV1WebSocketPayload) async throws
    func receive() async throws -> GoPeepV1WebSocketPayload
    func close() async
}

public protocol GoPeepV1WebSocketFactory: Sendable {
    func makeConnection(for url: URL) async throws -> any GoPeepV1WebSocketConnection
}

/// Production WebSocket factory backed by `URLSessionWebSocketTask`.
public struct URLSessionGoPeepV1WebSocketFactory: GoPeepV1WebSocketFactory {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func makeConnection(for url: URL) async throws -> any GoPeepV1WebSocketConnection {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = GoPeepV1SignalingResourceLimits.maximumMessagePayloadBytes
        return URLSessionGoPeepV1WebSocketConnection(task: task)
    }
}

private actor URLSessionGoPeepV1WebSocketConnection: GoPeepV1WebSocketConnection {
    private let task: URLSessionWebSocketTask
    private var didResume = false
    private var didClose = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() throws {
        guard !didClose else {
            throw GoPeepV1SignalingError.connectionFailed
        }
        guard !didResume else { return }
        didResume = true
        task.resume()
    }

    func send(_ payload: GoPeepV1WebSocketPayload) async throws {
        let message: URLSessionWebSocketTask.Message = switch payload {
        case .text(let text):
            .string(text)
        case .data(let data):
            .data(data)
        }
        try await task.send(message)
    }

    func receive() async throws -> GoPeepV1WebSocketPayload {
        switch try await task.receive() {
        case .string(let text):
            return .text(text)
        case .data(let data):
            return .data(data)
        @unknown default:
            throw GoPeepV1SignalingError.unsupportedWebSocketPayload
        }
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        task.cancel(with: .normalClosure, reason: nil)
    }
}

public protocol GoPeepV1ReconnectSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousGoPeepV1ReconnectSleeper: GoPeepV1ReconnectSleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

// MARK: - Reconnect and observable state

/// A deterministic, bounded retry schedule. An empty schedule disables reconnects.
public struct GoPeepV1ReconnectPolicy: Equatable, Sendable {
    public let delaysMilliseconds: [Int64]

    public init(delaysMilliseconds: [Int64]) {
        self.delaysMilliseconds = delaysMilliseconds.filter { $0 >= 0 }
    }

    public func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt > 0, attempt <= delaysMilliseconds.count else { return nil }
        return .milliseconds(delaysMilliseconds[attempt - 1])
    }

    public static let boundedExponential = Self(
        delaysMilliseconds: [250, 500, 1_000, 2_000, 4_000]
    )

    public static let disabled = Self(delaysMilliseconds: [])
}

/// Transport errors deliberately carry no URL query, SDP, ICE, password, or room secret.
public enum GoPeepV1SignalingError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidHTTPResponse
    case reservationRequestFailed
    case reservationRejected(statusCode: Int)
    case invalidReservationResponse
    case connectionAlreadyActive
    case connectionFailed
    case notConnected
    case sendFailed
    case unsupportedWebSocketPayload
    case controlMessageRequiresDataChannel(type: GoPeepV1MessageType)

    public var description: String {
        switch self {
        case .invalidHTTPResponse:
            "The reservation server returned an invalid HTTP response."
        case .reservationRequestFailed:
            "Clip could not contact the room reservation server."
        case .reservationRejected(let statusCode):
            "The room reservation server rejected the request (HTTP \(statusCode))."
        case .invalidReservationResponse:
            "The room reservation server returned invalid room credentials."
        case .connectionAlreadyActive:
            "A signaling connection is already active."
        case .connectionFailed:
            "Clip could not connect to the signaling server."
        case .notConnected:
            "The signaling connection is not active."
        case .sendFailed:
            "Clip could not send a signaling message."
        case .unsupportedWebSocketPayload:
            "The signaling server sent an unsupported WebSocket payload."
        case .controlMessageRequiresDataChannel(let type):
            "The \(type.rawValue) message belongs on the WebRTC control data channel."
        }
    }
}

public enum GoPeepV1SignalingDisconnectReason: Equatable, Sendable {
    case connectionLost
    case reconnectExhausted
}

public enum GoPeepV1SignalingEvent: Equatable, Sendable {
    case connecting(room: GoPeepV1RoomCode, reconnectAttempt: Int)
    /// The socket resumed and accepted the join frame for sending. The server's
    /// authoritative acknowledgement arrives separately as `.message(.joined)`.
    case connected(room: GoPeepV1RoomCode, reconnectAttempt: Int)
    case message(GoPeepV1Message)
    case invalidMessageReceived
    case disconnected(reason: GoPeepV1SignalingDisconnectReason, willReconnect: Bool)
    case reconnectScheduled(attempt: Int, delay: Duration)
    /// The bounded observer queue could not retain every signaling event. The
    /// session must fail closed because dropping an offer, answer, or lifecycle
    /// message would leave peers in an unknowable state.
    case eventBufferOverflow
    case stopped
}

/// Structured logs intentionally expose only noncredential protocol metadata.
public enum GoPeepV1SignalingLogEntry: Equatable, Sendable, CustomStringConvertible {
    case reservationRequested
    case reservationSucceeded(room: GoPeepV1RoomCode)
    case connecting(room: GoPeepV1RoomCode, reconnectAttempt: Int)
    case connected(room: GoPeepV1RoomCode, reconnectAttempt: Int)
    case messageSent(type: GoPeepV1MessageType)
    case messageReceived(type: GoPeepV1MessageType)
    case invalidMessageReceived
    case reconnectScheduled(room: GoPeepV1RoomCode, attempt: Int)
    case stopped

    public var description: String {
        switch self {
        case .reservationRequested:
            "Requesting a GoPeep room reservation."
        case .reservationSucceeded:
            "Reserved a GoPeep room."
        case .connecting(_, let attempt):
            "Connecting signaling (reconnect attempt \(attempt))."
        case .connected(_, let attempt):
            "Connected signaling (reconnect attempt \(attempt))."
        case .messageSent(let type):
            "Sent signaling message \(type.rawValue)."
        case .messageReceived(let type):
            "Received signaling message \(type.rawValue)."
        case .invalidMessageReceived:
            "Received an invalid signaling message."
        case .reconnectScheduled(_, let attempt):
            "Scheduled signaling reconnect, attempt \(attempt)."
        case .stopped:
            "Stopped signaling."
        }
    }
}

// MARK: - Signaling client

/// GoPeep v1 reservation and host-signaling client.
///
/// The actor serializes connection replacement and generation-checks every receive loop,
/// preventing a stale socket from tearing down a newly reconnected session.
public actor GoPeepV1SignalingClient {
    public typealias Logger = @Sendable (GoPeepV1SignalingLogEntry) -> Void

    private let server: GoPeepV1ServerConfiguration
    private let httpTransport: any GoPeepV1HTTPTransport
    private let webSocketFactory: any GoPeepV1WebSocketFactory
    private let reconnectPolicy: GoPeepV1ReconnectPolicy
    private let reconnectSleeper: any GoPeepV1ReconnectSleeper
    private let logger: Logger

    /// Invalidates every suspended connect/reconnect operation when the client is stopped
    /// or a later logical session starts. Actor isolation alone is insufficient here:
    /// `await` permits `stop()` and a replacement `connect(room:)` to run while a socket
    /// factory, resume, or join send is still suspended.
    private var sessionGeneration: UInt64 = 0
    private var roomConfiguration: GoPeepV1RoomConfiguration?
    private var openingConnection: (
        id: UUID,
        generation: UInt64,
        socket: any GoPeepV1WebSocketConnection
    )?
    private var connection: (
        id: UUID,
        generation: UInt64,
        socket: any GoPeepV1WebSocketConnection
    )?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectToken: UUID?
    private var continuations: [UUID: AsyncStream<GoPeepV1SignalingEvent>.Continuation] = [:]

    public init(
        server: GoPeepV1ServerConfiguration = .goPeepRemote,
        httpTransport: any GoPeepV1HTTPTransport = URLSessionGoPeepV1HTTPTransport(),
        webSocketFactory: any GoPeepV1WebSocketFactory = URLSessionGoPeepV1WebSocketFactory(),
        reconnectPolicy: GoPeepV1ReconnectPolicy = .boundedExponential,
        reconnectSleeper: any GoPeepV1ReconnectSleeper = ContinuousGoPeepV1ReconnectSleeper(),
        logger: @escaping Logger = { _ in }
    ) {
        self.server = server
        self.httpTransport = httpTransport
        self.webSocketFactory = webSocketFactory
        self.reconnectPolicy = reconnectPolicy
        self.reconnectSleeper = reconnectSleeper
        self.logger = logger
    }

    public func events() -> AsyncStream<GoPeepV1SignalingEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: GoPeepV1SignalingEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    public func reserveRoom() async throws -> GoPeepV1RoomReservationResponse {
        logger(.reservationRequested)
        var request = URLRequest(url: server.reservationURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let result: GoPeepV1HTTPResult
        do {
            result = try await httpTransport.execute(request)
        } catch let error as GoPeepV1SignalingError where error == .invalidHTTPResponse {
            throw error
        } catch {
            throw GoPeepV1SignalingError.reservationRequestFailed
        }

        guard result.statusCode == 200 else {
            throw GoPeepV1SignalingError.reservationRejected(statusCode: result.statusCode)
        }
        guard result.data.count <= GoPeepV1SignalingResourceLimits.maximumReservationResponseBytes else {
            throw GoPeepV1SignalingError.invalidReservationResponse
        }

        let reservation: GoPeepV1RoomReservationResponse
        do {
            reservation = try JSONDecoder().decode(
                GoPeepV1RoomReservationResponse.self,
                from: result.data
            )
        } catch {
            throw GoPeepV1SignalingError.invalidReservationResponse
        }
        logger(.reservationSucceeded(room: reservation.room))
        return reservation
    }

    /// Opens the WebSocket and sends GoPeep's sharer join as the first frame.
    public func connect(room: GoPeepV1RoomConfiguration) async throws {
        guard connection == nil, reconnectTask == nil, roomConfiguration == nil else {
            throw GoPeepV1SignalingError.connectionAlreadyActive
        }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        roomConfiguration = room
        do {
            try await openConnection(
                room: room,
                reconnectAttempt: 0,
                generation: generation
            )
        } catch {
            // A delayed older connect must not clear the room installed by a newer
            // session after Stop -> Connect.
            if isCurrentSession(generation, room: room) {
                roomConfiguration = nil
            }
            throw GoPeepV1SignalingError.connectionFailed
        }
    }

    public func send(_ message: GoPeepV1Message) async throws {
        if message.type.intendedTransport == .controlDataChannel {
            throw GoPeepV1SignalingError.controlMessageRequiresDataChannel(type: message.type)
        }
        guard let activeConnection = connection else {
            throw GoPeepV1SignalingError.notConnected
        }

        do {
            try await sendEncoded(message, over: activeConnection.socket)
            guard isCurrentConnection(
                activeConnection.id,
                generation: activeConnection.generation
            ) else {
                throw GoPeepV1SignalingError.notConnected
            }
            if message.type == .passwordUpdate {
                rememberUpdatedPassword(message.password)
            }
            logger(.messageSent(type: message.type))
        } catch {
            await connectionDidFail(
                id: activeConnection.id,
                generation: activeConnection.generation
            )
            throw GoPeepV1SignalingError.sendFailed
        }
    }

    /// Stops the socket and pending retry. The same client may connect again later.
    public func stop() async {
        // Invalidate suspended factory/resume/send awaits before this method performs
        // its own first await. A stale open can then only close its socket, never install it.
        sessionGeneration &+= 1
        let openingConnection = openingConnection
        let activeConnection = connection
        self.openingConnection = nil
        connection = nil
        roomConfiguration = nil
        reconnectToken = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        // Publish the logical stop before awaiting physical socket closure. Otherwise a
        // concurrently requested replacement session could emit Connected and then be
        // followed by this older session's late Stopped event.
        emit(.stopped)
        logger(.stopped)
        if let openingConnection {
            await openingConnection.socket.close()
        }
        if let activeConnection {
            await activeConnection.socket.close()
        }
    }

    private func openConnection(
        room: GoPeepV1RoomConfiguration,
        reconnectAttempt: Int,
        generation: UInt64
    ) async throws {
        guard isCurrentSession(generation, room: room) else {
            throw GoPeepV1SignalingError.connectionFailed
        }
        let connectionURL = server.signalingURL(for: room.room)
        emit(.connecting(room: room.room, reconnectAttempt: reconnectAttempt))
        logger(.connecting(room: room.room, reconnectAttempt: reconnectAttempt))

        let socket = try await webSocketFactory.makeConnection(for: connectionURL)
        guard isCurrentSession(generation, room: room) else {
            await socket.close()
            throw GoPeepV1SignalingError.connectionFailed
        }

        let id = UUID()
        openingConnection = (id, generation, socket)
        do {
            try await socket.resume()
            guard isCurrentOpeningConnection(id, generation: generation, room: room) else {
                throw GoPeepV1SignalingError.connectionFailed
            }
            try await sendJoin(room, over: socket)
            guard isCurrentOpeningConnection(id, generation: generation, room: room) else {
                throw GoPeepV1SignalingError.connectionFailed
            }
        } catch {
            await closeOpeningConnectionIfOwned(id, generation: generation)
            throw GoPeepV1SignalingError.connectionFailed
        }

        openingConnection = nil
        connection = (id, generation, socket)
        emit(.connected(room: room.room, reconnectAttempt: reconnectAttempt))
        logger(.connected(room: room.room, reconnectAttempt: reconnectAttempt))
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket, id: id, generation: generation)
        }
    }

    private func sendJoin(
        _ room: GoPeepV1RoomConfiguration,
        over socket: any GoPeepV1WebSocketConnection
    ) async throws {
        let message = GoPeepV1Message(
            type: .join,
            role: .sharer,
            password: room.password ?? "",
            secret: room.secret
        )
        try await sendEncoded(message, over: socket)
        logger(.messageSent(type: .join))
    }

    private func sendEncoded(
        _ message: GoPeepV1Message,
        over socket: any GoPeepV1WebSocketConnection
    ) async throws {
        let data = try JSONEncoder().encode(message)
        guard data.count <= GoPeepV1SignalingResourceLimits.maximumMessagePayloadBytes else {
            throw GoPeepV1SignalingError.sendFailed
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GoPeepV1SignalingError.sendFailed
        }
        try await socket.send(.text(text))
    }

    private func receiveLoop(
        socket: any GoPeepV1WebSocketConnection,
        id: UUID,
        generation: UInt64
    ) async {
        do {
            while !Task.isCancelled {
                let payload = try await socket.receive()
                guard isCurrentConnection(id, generation: generation) else { return }
                decodeAndEmit(payload)
            }
        } catch {
            guard !Task.isCancelled else { return }
            await connectionDidFail(id: id, generation: generation)
        }
    }

    private func decodeAndEmit(_ payload: GoPeepV1WebSocketPayload) {
        let data: Data = switch payload {
        case .text(let text):
            Data(text.utf8)
        case .data(let data):
            data
        }

        guard data.count <= GoPeepV1SignalingResourceLimits.maximumMessagePayloadBytes else {
            emit(.invalidMessageReceived)
            logger(.invalidMessageReceived)
            return
        }

        do {
            let message = try JSONDecoder().decode(GoPeepV1Message.self, from: data)
            emit(.message(message))
            logger(.messageReceived(type: message.type))
        } catch {
            emit(.invalidMessageReceived)
            logger(.invalidMessageReceived)
        }
    }

    private func connectionDidFail(id: UUID, generation: UInt64) async {
        guard let activeConnection = connection,
              activeConnection.id == id,
              activeConnection.generation == generation,
              sessionGeneration == generation else {
            return
        }
        connection = nil
        receiveTask?.cancel()
        receiveTask = nil
        await activeConnection.socket.close()

        guard let room = roomConfiguration else {
            emit(.disconnected(reason: .connectionLost, willReconnect: false))
            return
        }
        scheduleReconnect(room: room, attempt: 1, generation: generation)
    }

    private func scheduleReconnect(
        room: GoPeepV1RoomConfiguration,
        attempt: Int,
        generation: UInt64
    ) {
        guard isCurrentSession(generation, room: room) else { return }
        guard let delay = reconnectPolicy.delay(forAttempt: attempt) else {
            roomConfiguration = nil
            reconnectToken = nil
            reconnectTask = nil
            emit(.disconnected(reason: .reconnectExhausted, willReconnect: false))
            return
        }

        let token = UUID()
        reconnectToken = token
        emit(.disconnected(reason: .connectionLost, willReconnect: true))
        emit(.reconnectScheduled(attempt: attempt, delay: delay))
        logger(.reconnectScheduled(room: room.room, attempt: attempt))
        reconnectTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.reconnectSleeper.sleep(for: delay)
                await self.performReconnect(
                    room: room,
                    attempt: attempt,
                    token: token,
                    generation: generation
                )
            } catch {
                // Cancellation is an intentional stop or superseded reconnect.
            }
        }
    }

    private func performReconnect(
        room: GoPeepV1RoomConfiguration,
        attempt: Int,
        token: UUID,
        generation: UInt64
    ) async {
        guard reconnectToken == token,
              isCurrentSession(generation, room: room) else {
            return
        }
        reconnectTask = nil
        reconnectToken = nil
        do {
            try await openConnection(
                room: room,
                reconnectAttempt: attempt,
                generation: generation
            )
        } catch {
            guard isCurrentSession(generation, room: room) else { return }
            scheduleReconnect(
                room: room,
                attempt: attempt + 1,
                generation: generation
            )
        }
    }

    private func isCurrentSession(
        _ generation: UInt64,
        room: GoPeepV1RoomConfiguration
    ) -> Bool {
        sessionGeneration == generation && roomConfiguration == room
    }

    private func isCurrentOpeningConnection(
        _ id: UUID,
        generation: UInt64,
        room: GoPeepV1RoomConfiguration
    ) -> Bool {
        guard isCurrentSession(generation, room: room),
              let openingConnection else {
            return false
        }
        return openingConnection.id == id && openingConnection.generation == generation
    }

    private func isCurrentConnection(_ id: UUID, generation: UInt64) -> Bool {
        guard sessionGeneration == generation, let connection else { return false }
        return connection.id == id && connection.generation == generation
    }

    private func closeOpeningConnectionIfOwned(_ id: UUID, generation: UInt64) async {
        guard let openingConnection,
              openingConnection.id == id,
              openingConnection.generation == generation else {
            // Stop may already have detached and closed this socket.
            return
        }
        self.openingConnection = nil
        await openingConnection.socket.close()
    }

    private func rememberUpdatedPassword(_ password: String) {
        guard let current = roomConfiguration,
              let reservation = try? GoPeepV1RoomReservationResponse(
                  room: current.room,
                  secret: current.secret
              ) else {
            return
        }
        roomConfiguration = GoPeepV1RoomConfiguration(
            reservation: reservation,
            password: password
        )
    }

    private func emit(_ event: GoPeepV1SignalingEvent) {
        var terminated: [UUID] = []
        for (id, continuation) in continuations {
            switch continuation.yield(event) {
            case .enqueued:
                break
            case .dropped:
                // `.bufferingNewest` guarantees this sentinel replaces another
                // buffered value rather than being rejected. Finishing retains
                // buffered values, so the consumer deterministically observes
                // the overflow and can fail the room instead of silently
                // continuing with a corrupted protocol sequence.
                _ = continuation.yield(.eventBufferOverflow)
                continuation.finish()
                terminated.append(id)
            case .terminated:
                terminated.append(id)
            @unknown default:
                continuation.finish()
                terminated.append(id)
            }
        }
        for id in terminated {
            continuations.removeValue(forKey: id)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
