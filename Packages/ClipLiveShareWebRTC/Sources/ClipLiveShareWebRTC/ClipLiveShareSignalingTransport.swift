import ClipLiveShare
import Foundation

// MARK: - Injectable network boundaries

public struct ClipLiveShareHTTPResult: Equatable, Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol ClipLiveShareHTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> ClipLiveShareHTTPResult
}

public struct URLSessionClipLiveShareHTTPTransport: ClipLiveShareHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: URLRequest) async throws -> ClipLiveShareHTTPResult {
        let maximumBytes = Self.maximumResponseBytes(for: request)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClipLiveShareNetworkError.invalidHTTPResponse
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw ClipLiveShareNetworkError.responseTooLarge
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(maximumBytes, Int(response.expectedContentLength)))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw ClipLiveShareNetworkError.responseTooLarge
            }
            data.append(byte)
        }
        return ClipLiveShareHTTPResult(statusCode: response.statusCode, data: data)
    }

    private static func maximumResponseBytes(for request: URLRequest) -> Int {
        if request.url?.path == "/.well-known/clip-live-share" {
            return ClipLiveShareSignalingResourceLimits.maximumCapabilitiesBytes
        }
        return ClipLiveShareSignalingResourceLimits.maximumRoomResponseBytes
    }
}

public enum ClipLiveShareWebSocketPayload: Equatable, Sendable {
    case text(String)
    case data(Data)
}

public protocol ClipLiveShareWebSocketConnection: Sendable {
    func resume() async throws
    func send(_ payload: ClipLiveShareWebSocketPayload) async throws
    func receive() async throws -> ClipLiveShareWebSocketPayload
    func close() async
}

public protocol ClipLiveShareWebSocketFactory: Sendable {
    func makeConnection(
        for request: URLRequest
    ) async throws -> any ClipLiveShareWebSocketConnection
}

public struct URLSessionClipLiveShareWebSocketFactory: ClipLiveShareWebSocketFactory {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func makeConnection(
        for request: URLRequest
    ) async throws -> any ClipLiveShareWebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = ClipLiveShareSignalingResourceLimits.maximumMessageBytes
        return URLSessionClipLiveShareWebSocketConnection(task: task)
    }
}

private actor URLSessionClipLiveShareWebSocketConnection:
    ClipLiveShareWebSocketConnection
{
    private let task: URLSessionWebSocketTask
    private var didResume = false
    private var didClose = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() throws {
        guard !didClose else { throw ClipLiveShareNetworkError.connectionFailed }
        guard !didResume else { return }
        didResume = true
        task.resume()
    }

    func send(_ payload: ClipLiveShareWebSocketPayload) async throws {
        guard didResume, !didClose else {
            throw ClipLiveShareNetworkError.notConnected
        }
        switch payload {
        case .text(let value):
            try await task.send(.string(value))
        case .data(let value):
            try await task.send(.data(value))
        }
    }

    func receive() async throws -> ClipLiveShareWebSocketPayload {
        guard didResume, !didClose else {
            throw ClipLiveShareNetworkError.notConnected
        }
        switch try await task.receive() {
        case .string(let value):
            return .text(value)
        case .data(let value):
            return .data(value)
        @unknown default:
            throw ClipLiveShareNetworkError.unsupportedWebSocketPayload
        }
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Preserves WebSocket message order across actor reentrancy. A signaling
/// client can generate several ICE candidates while an earlier socket send is
/// suspended; chaining the sends prevents those independent tasks from racing
/// the transport implementation.
private actor ClipLiveShareSerializedWebSocketConnection:
    ClipLiveShareWebSocketConnection
{
    private let base: any ClipLiveShareWebSocketConnection
    private var sendTail: (id: UUID, task: Task<Void, any Error>)?

    init(base: any ClipLiveShareWebSocketConnection) {
        self.base = base
    }

    func resume() async throws {
        try await base.resume()
    }

    func send(_ payload: ClipLiveShareWebSocketPayload) async throws {
        let predecessor = sendTail?.task
        let id = UUID()
        let base = base
        let task = Task {
            try await predecessor?.value
            try Task.checkCancellation()
            try await base.send(payload)
        }
        sendTail = (id, task)
        defer {
            if sendTail?.id == id { sendTail = nil }
        }
        try await task.value
    }

    func receive() async throws -> ClipLiveShareWebSocketPayload {
        try await base.receive()
    }

    func close() async {
        sendTail?.task.cancel()
        sendTail = nil
        await base.close()
    }
}

public enum ClipLiveShareSignalingResourceLimits {
    public static let maximumCapabilitiesBytes = 65_536
    public static let maximumRoomResponseBytes = 16_384
    public static let maximumMessageBytes = ClipLiveShareV1.maximumWebSocketMessageBytes
    public static let maximumDecryptedMessageBytes = ClipLiveShareV1.maximumInnerMessageBytes
}

public enum ClipLiveShareNetworkError: Error, Equatable, Sendable, LocalizedError {
    case invalidHTTPResponse
    case requestFailed
    case responseTooLarge
    case messageTooLarge(maximumBytes: Int)
    case incompatibleServer
    case rejected(statusCode: Int)
    case roomNameTaken
    case connectionAlreadyActive
    case connectionFailed
    case notConnected
    case sendFailed
    case unsupportedWebSocketPayload
    case invalidMessage
    case eventBufferOverflow
    case invalidCapabilities
    case invalidRoomResponse
    case roomCreationExhausted
    case routeNotFound
    case routeRejected

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            "The Live Share server returned an invalid HTTP response."
        case .requestFailed:
            "Clip could not contact the Live Share server."
        case .responseTooLarge:
            "The Live Share server response exceeded Clip’s safety limit."
        case .messageTooLarge(let maximumBytes):
            "The Live Share signaling message exceeds the server’s \(maximumBytes)-byte limit."
        case .incompatibleServer:
            "This server does not support Clip Live Share Protocol v1."
        case .rejected(let statusCode):
            "The Live Share server rejected the request (HTTP \(statusCode))."
        case .roomNameTaken:
            "That Live Share room name is already in use."
        case .connectionAlreadyActive:
            "A Live Share signaling connection is already active."
        case .connectionFailed:
            "Clip could not connect to the Live Share server."
        case .notConnected:
            "The Live Share signaling connection is not active."
        case .sendFailed:
            "Clip could not send a Live Share signaling message."
        case .unsupportedWebSocketPayload:
            "The Live Share server sent an unsupported WebSocket payload."
        case .invalidMessage:
            "The Live Share server sent an invalid routing message."
        case .eventBufferOverflow:
            "The Live Share signaling event queue overflowed."
        case .invalidCapabilities:
            "The server returned an invalid Clip Live Share capability document."
        case .invalidRoomResponse:
            "The server returned an invalid room advertisement."
        case .roomCreationExhausted:
            "Clip could not find an available Live Share room name."
        case .routeNotFound:
            "The viewer signaling route is no longer available."
        case .routeRejected:
            "The viewer signaling route was rejected."
        }
    }
}

public protocol ClipLiveShareReconnectSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousClipLiveShareReconnectSleeper: ClipLiveShareReconnectSleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public struct ClipLiveShareReconnectPolicy: Equatable, Sendable {
    public let delaysMilliseconds: [Int64]
    public let repeatsLastDelay: Bool

    public init(
        delaysMilliseconds: [Int64],
        repeatsLastDelay: Bool = false
    ) {
        self.delaysMilliseconds = delaysMilliseconds.filter { $0 >= 0 }
        self.repeatsLastDelay = repeatsLastDelay
    }

    public func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt > 0, !delaysMilliseconds.isEmpty else { return nil }
        if attempt <= delaysMilliseconds.count {
            return .milliseconds(delaysMilliseconds[attempt - 1])
        }
        guard repeatsLastDelay, let finalDelay = delaysMilliseconds.last else { return nil }
        return .milliseconds(finalDelay)
    }

    public static let boundedExponential = Self(
        delaysMilliseconds: [250, 500, 1_000, 2_000, 4_000]
    )

    /// Production signaling remains recoverable for the lifetime of the P2P
    /// session. After the short interactive retries, attempts settle at a low
    /// fixed frequency so a restarted service can accept new viewers without
    /// interrupting established WebRTC media or control channels.
    public static let persistentExponential = Self(
        delaysMilliseconds: [250, 500, 1_000, 2_000, 4_000, 8_000, 15_000],
        repeatsLastDelay: true
    )

    public static let disabled = Self(delaysMilliseconds: [])
}

// MARK: - Clip Live Share host signaling

public enum ClipLiveShareSignalingDisconnectReason: Equatable, Sendable {
    case connectionLost
    case reconnectExhausted
}

public enum ClipLiveShareSignalingEvent: Equatable, Sendable {
    case connecting(room: ClipLiveShareRoomName, reconnectAttempt: Int)
    case connected(room: ClipLiveShareRoomName, reconnectAttempt: Int)
    case routeOpened(routeID: ClipLiveShareRouteID)
    case message(routeID: ClipLiveShareRouteID, message: ClipLiveShareInnerMessage)
    case routeClosed(routeID: ClipLiveShareRouteID, reason: String?)
    case routeRejected(routeID: ClipLiveShareRouteID, reason: String)
    case serverError(code: String)
    case invalidMessageReceived
    case disconnected(reason: ClipLiveShareSignalingDisconnectReason, willReconnect: Bool)
    case reconnectScheduled(attempt: Int, delay: Duration)
    case eventBufferOverflow
    case stopped
}

public enum ClipLiveShareSignalingLogEntry: Equatable, Sendable,
    CustomStringConvertible
{
    case capabilitiesLoaded
    case roomAdvertised(ClipLiveShareRoomName)
    case connecting(ClipLiveShareRoomName, attempt: Int)
    case connected(ClipLiveShareRoomName, attempt: Int)
    case routeOpened(ClipLiveShareRouteID)
    case routeClosed(ClipLiveShareRouteID)
    case invalidMessage
    case reconnectScheduled(attempt: Int)
    case stopped

    public var description: String {
        switch self {
        case .capabilitiesLoaded:
            "Clip Live Share server capabilities loaded"
        case .roomAdvertised(let room):
            "Clip Live Share room advertised: \(room.rawValue)"
        case .connecting(let room, let attempt):
            "Connecting Clip Live Share room \(room.rawValue), attempt \(attempt)"
        case .connected(let room, let attempt):
            "Connected Clip Live Share room \(room.rawValue), attempt \(attempt)"
        case .routeOpened:
            "Encrypted Clip Live Share viewer route opened"
        case .routeClosed:
            "Encrypted Clip Live Share viewer route closed"
        case .invalidMessage:
            "Rejected an invalid Clip Live Share signaling message"
        case .reconnectScheduled(let attempt):
            "Scheduled Clip Live Share signaling reconnect attempt \(attempt)"
        case .stopped:
            "Stopped Clip Live Share signaling"
        }
    }
}

/// Owns the authenticated host WebSocket and its short-lived encrypted viewer
/// routes. Access codes, SDP, ICE, stream metadata, and peer state exist only
/// inside the encrypted inner messages delivered by this actor.
public actor ClipLiveShareSignalingClient {
    public typealias Logger = @Sendable (ClipLiveShareSignalingLogEntry) -> Void

    private let httpTransport: any ClipLiveShareHTTPTransport
    private let webSocketFactory: any ClipLiveShareWebSocketFactory
    private let reconnectPolicy: ClipLiveShareReconnectPolicy
    private let reconnectSleeper: any ClipLiveShareReconnectSleeper
    private let logger: Logger

    private var sessionGeneration: UInt64 = 0
    private var advertisedRoomConfiguration: ClipLiveShareRoomConfiguration?
    private var roomConfiguration: ClipLiveShareRoomConfiguration?
    private var openingConnection: (
        id: UUID,
        generation: UInt64,
        socket: any ClipLiveShareWebSocketConnection
    )?
    private var connection: (
        id: UUID,
        generation: UInt64,
        socket: any ClipLiveShareWebSocketConnection
    )?
    private var encryptedRoutes: [
        ClipLiveShareRouteID: ClipLiveShareEncryptedChannel
    ] = [:]
    /// Retired/invalid routes are remembered for the lifetime of one host
    /// socket. A hostile relay replay therefore produces at most one bounded
    /// close response and never a stream of coordinator events.
    private var rejectedRouteIDs: Set<ClipLiveShareRouteID> = []
    private var rejectedRouteOrder: [ClipLiveShareRouteID] = []
    private var didEmitInvalidMessage = false
    private var didEmitServerError = false
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectToken: UUID?
    private var continuations: [
        UUID: AsyncStream<ClipLiveShareSignalingEvent>.Continuation
    ] = [:]

    public init(
        httpTransport: any ClipLiveShareHTTPTransport = URLSessionClipLiveShareHTTPTransport(),
        webSocketFactory: any ClipLiveShareWebSocketFactory = URLSessionClipLiveShareWebSocketFactory(),
        reconnectPolicy: ClipLiveShareReconnectPolicy = .persistentExponential,
        reconnectSleeper: any ClipLiveShareReconnectSleeper = ContinuousClipLiveShareReconnectSleeper(),
        logger: @escaping Logger = { _ in }
    ) {
        self.httpTransport = httpTransport
        self.webSocketFactory = webSocketFactory
        self.reconnectPolicy = reconnectPolicy
        self.reconnectSleeper = reconnectSleeper
        self.logger = logger
    }

    public func events() -> AsyncStream<ClipLiveShareSignalingEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: ClipLiveShareSignalingEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    public func fetchCapabilities(
        from endpoint: ClipLiveShareServerEndpoint
    ) async throws -> ClipLiveShareCapabilities {
        var request = URLRequest(url: endpoint.capabilitiesURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let result: ClipLiveShareHTTPResult
        do {
            result = try await httpTransport.execute(request)
        } catch let error as ClipLiveShareNetworkError {
            throw error
        } catch {
            throw ClipLiveShareNetworkError.requestFailed
        }
        guard result.statusCode == 200 else {
            throw ClipLiveShareNetworkError.rejected(statusCode: result.statusCode)
        }
        guard !result.data.isEmpty,
              result.data.count <= ClipLiveShareSignalingResourceLimits.maximumCapabilitiesBytes
        else {
            throw ClipLiveShareNetworkError.responseTooLarge
        }
        do {
            let capabilities = try JSONDecoder().decode(
                ClipLiveShareCapabilities.self,
                from: result.data
            )
            logger(.capabilitiesLoaded)
            return capabilities
        } catch {
            throw ClipLiveShareNetworkError.invalidCapabilities
        }
    }

    /// Creates a client-owned room identity and claims an available memorable
    /// room name. Neither private room key nor owner token is persisted by the
    /// signaling service.
    public func createRoom(
        at endpoint: ClipLiveShareServerEndpoint = .official,
        preferredRoomName: ClipLiveShareRoomName? = nil,
        maximumNameAttempts: Int = 12
    ) async throws -> ClipLiveShareRoomConfiguration {
        guard advertisedRoomConfiguration == nil,
              roomConfiguration == nil,
              connection == nil,
              openingConnection == nil else {
            throw ClipLiveShareNetworkError.connectionAlreadyActive
        }
        let creationGeneration = sessionGeneration
        let capabilities = try await fetchCapabilities(from: endpoint)
        guard sessionGeneration == creationGeneration else {
            throw ClipLiveShareNetworkError.connectionFailed
        }
        let ownerToken = ClipLiveShareOwnerToken.random()
        let identity = ClipLiveShareRoomIdentity()
        let attempts = min(32, max(1, maximumNameAttempts))

        for attempt in 0..<attempts {
            let room = attempt == 0 ? (preferredRoomName ?? .random()) : .random()
            let configuration = ClipLiveShareRoomConfiguration(
                endpoint: endpoint,
                capabilities: capabilities,
                room: room,
                ownerToken: ownerToken,
                identity: identity
            )
            do {
                _ = try await advertise(
                    configuration,
                    expectedGeneration: creationGeneration
                )
                return configuration
            } catch ClipLiveShareNetworkError.roomNameTaken {
                continue
            }
        }
        throw ClipLiveShareNetworkError.roomCreationExhausted
    }

    @discardableResult
    public func advertise(
        _ room: ClipLiveShareRoomConfiguration
    ) async throws -> ClipLiveShareRoomAdvertisement {
        try await advertise(room, expectedGeneration: nil)
    }

    private func advertise(
        _ room: ClipLiveShareRoomConfiguration,
        expectedGeneration: UInt64?
    ) async throws -> ClipLiveShareRoomAdvertisement {
        var request = URLRequest(url: room.advertiseURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ClipLiveShareAdvertiseRoomRequest(ownerToken: room.ownerToken)
        )

        let result: ClipLiveShareHTTPResult
        do {
            result = try await httpTransport.execute(request)
        } catch let error as ClipLiveShareNetworkError {
            throw error
        } catch {
            throw ClipLiveShareNetworkError.requestFailed
        }
        if result.statusCode == 409 {
            throw ClipLiveShareNetworkError.roomNameTaken
        }
        guard result.statusCode == 200 || result.statusCode == 201 else {
            throw ClipLiveShareNetworkError.rejected(statusCode: result.statusCode)
        }
        guard !result.data.isEmpty,
              result.data.count <= ClipLiveShareSignalingResourceLimits.maximumRoomResponseBytes
        else {
            throw ClipLiveShareNetworkError.invalidRoomResponse
        }
        do {
            let advertisement = try JSONDecoder().decode(
                ClipLiveShareRoomAdvertisement.self,
                from: result.data
            )
            guard advertisement.room == room.room else {
                throw ClipLiveShareNetworkError.invalidRoomResponse
            }
            if let expectedGeneration,
               sessionGeneration != expectedGeneration {
                // A stop can interleave while the PUT is awaiting its HTTP
                // response. Remove the just-created lease with its owner
                // capability instead of orphaning it on the service.
                try? await removeAdvertisement(for: room)
                throw ClipLiveShareNetworkError.connectionFailed
            }
            advertisedRoomConfiguration = room
            logger(.roomAdvertised(room.room))
            return advertisement
        } catch let error as ClipLiveShareNetworkError {
            throw error
        } catch {
            throw ClipLiveShareNetworkError.invalidRoomResponse
        }
    }

    public func connect(room: ClipLiveShareRoomConfiguration) async throws {
        guard connection == nil,
              openingConnection == nil,
              reconnectTask == nil,
              roomConfiguration == nil,
              advertisedRoomConfiguration.map({
                  $0.room == room.room
                    && $0.endpoint == room.endpoint
                    && $0.ownerToken == room.ownerToken
              }) ?? true else {
            throw ClipLiveShareNetworkError.connectionAlreadyActive
        }
        advertisedRoomConfiguration = room
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
            if isCurrentSession(generation) {
                roomConfiguration = nil
            }
            throw ClipLiveShareNetworkError.connectionFailed
        }
    }

    public func send(
        _ message: ClipLiveShareInnerMessage,
        to routeID: ClipLiveShareRouteID
    ) async throws {
        guard let activeConnection = connection else {
            throw ClipLiveShareNetworkError.notConnected
        }
        guard var channel = encryptedRoutes[routeID] else {
            throw ClipLiveShareNetworkError.routeNotFound
        }
        do {
            let envelope = try channel.seal(message)
            let payload = try encodedOuterPayload(
                .relay(envelope),
                maximumBytes: negotiatedMaximumMessageBytes
            )
            // Commit the sequence before the await. Actor reentrancy can admit
            // another ICE send or a route close while the socket is suspended;
            // no later operation may reuse or resurrect this channel state.
            encryptedRoutes[routeID] = channel
            try await activeConnection.socket.send(payload)
            guard isCurrentConnection(
                activeConnection.id,
                generation: activeConnection.generation
            ) else {
                throw ClipLiveShareNetworkError.notConnected
            }
        } catch let error as ClipLiveShareNetworkError {
            if case .messageTooLarge = error {
                // This viewer negotiated through a server whose frame ceiling
                // cannot carry its offer/relay. Retire only that introduction;
                // the authenticated host socket and other viewers stay live.
                await rejectRoute(
                    routeID,
                    reason: "message-too-large",
                    socket: activeConnection.socket
                )
                throw error
            }
            await connectionDidFail(
                id: activeConnection.id,
                generation: activeConnection.generation
            )
            throw ClipLiveShareNetworkError.sendFailed
        } catch ClipLiveShareProtocolError.messageTooLarge(let maximum, _) {
            await rejectRoute(
                routeID,
                reason: "message-too-large",
                socket: activeConnection.socket
            )
            throw ClipLiveShareNetworkError.messageTooLarge(maximumBytes: maximum)
        } catch {
            await connectionDidFail(
                id: activeConnection.id,
                generation: activeConnection.generation
            )
            throw ClipLiveShareNetworkError.sendFailed
        }
    }

    /// Ends only the server-assisted introduction. The established WebRTC peer
    /// and its control DataChannel continue independently.
    public func closeRoute(_ routeID: ClipLiveShareRouteID) async {
        encryptedRoutes[routeID] = nil
        rememberRejectedRoute(routeID)
        guard let activeConnection = connection else { return }
        do {
            try await sendOuter(.closeRoute(routeID), over: activeConnection.socket)
            logger(.routeClosed(routeID))
        } catch ClipLiveShareNetworkError.messageTooLarge {
            // A server advertising an unusably small frame limit cannot accept
            // even the idempotent close. Keep the host socket and P2P peers.
        } catch {
            await connectionDidFail(
                id: activeConnection.id,
                generation: activeConnection.generation
            )
        }
    }

    /// Stops signaling and removes the room advertisement. Existing P2P media
    /// is expected to be closed by the coordinator before this call.
    public func stop(removeAdvertisement removesAdvertisement: Bool = true) async {
        sessionGeneration &+= 1
        let room = roomConfiguration ?? advertisedRoomConfiguration
        let opening = openingConnection
        let active = connection
        openingConnection = nil
        connection = nil
        roomConfiguration = nil
        advertisedRoomConfiguration = nil
        encryptedRoutes.removeAll()
        resetPerConnectionRejectionState()
        reconnectToken = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        emit(.stopped)
        logger(.stopped)
        if let opening { await opening.socket.close() }
        if let active { await active.socket.close() }
        if removesAdvertisement, let room {
            try? await removeAdvertisement(for: room)
        }
    }

    private func removeAdvertisement(
        for room: ClipLiveShareRoomConfiguration
    ) async throws {
        var request = URLRequest(url: room.advertiseURL)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(
            room.ownerToken.authorizationHeaderValue,
            forHTTPHeaderField: "Authorization"
        )
        let result = try await httpTransport.execute(request)
        guard result.statusCode == 204 || result.statusCode == 404 else {
            throw ClipLiveShareNetworkError.rejected(statusCode: result.statusCode)
        }
    }

    private func openConnection(
        room: ClipLiveShareRoomConfiguration,
        reconnectAttempt: Int,
        generation: UInt64
    ) async throws {
        guard isCurrentSession(generation) else {
            throw ClipLiveShareNetworkError.connectionFailed
        }
        if reconnectAttempt > 0 {
            // A process restart loses the in-memory lease. Re-advertising with
            // the same owner capability is also an idempotent lease renewal.
            _ = try await advertise(room, expectedGeneration: generation)
            guard isCurrentSession(generation) else {
                throw ClipLiveShareNetworkError.connectionFailed
            }
        }

        emit(.connecting(room: room.room, reconnectAttempt: reconnectAttempt))
        logger(.connecting(room.room, attempt: reconnectAttempt))
        var request = URLRequest(url: try room.hostWebSocketURL)
        request.timeoutInterval = 10
        request.setValue(
            room.ownerToken.authorizationHeaderValue,
            forHTTPHeaderField: "Authorization"
        )
        let underlyingSocket = try await webSocketFactory.makeConnection(for: request)
        let socket = ClipLiveShareSerializedWebSocketConnection(base: underlyingSocket)
        guard isCurrentSession(generation) else {
            await socket.close()
            throw ClipLiveShareNetworkError.connectionFailed
        }

        let id = UUID()
        openingConnection = (id, generation, socket)
        do {
            try await socket.resume()
            guard isCurrentOpeningConnection(id, generation: generation) else {
                throw ClipLiveShareNetworkError.connectionFailed
            }
        } catch {
            await closeOpeningConnectionIfOwned(id, generation: generation)
            throw ClipLiveShareNetworkError.connectionFailed
        }

        openingConnection = nil
        connection = (id, generation, socket)
        resetPerConnectionRejectionState()
        emit(.connected(room: room.room, reconnectAttempt: reconnectAttempt))
        logger(.connected(room.room, attempt: reconnectAttempt))
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket, id: id, generation: generation)
        }
    }

    private func sendOuter(
        _ message: ClipLiveShareOuterMessage,
        over socket: any ClipLiveShareWebSocketConnection
    ) async throws {
        try await socket.send(try encodedOuterPayload(
            message,
            maximumBytes: negotiatedMaximumMessageBytes
        ))
    }

    private func encodedOuterPayload(
        _ message: ClipLiveShareOuterMessage,
        maximumBytes: Int
    ) throws -> ClipLiveShareWebSocketPayload {
        let data: Data
        do {
            data = try ClipLiveShareMessageCodec.encodeOuter(
                message,
                maximumBytes: maximumBytes
            )
        } catch ClipLiveShareProtocolError.messageTooLarge {
            throw ClipLiveShareNetworkError.messageTooLarge(
                maximumBytes: maximumBytes
            )
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw ClipLiveShareNetworkError.sendFailed
        }
        return .text(value)
    }

    private var negotiatedMaximumMessageBytes: Int {
        roomConfiguration?.capabilities.limits.maximumMessageBytes
            ?? advertisedRoomConfiguration?.capabilities.limits.maximumMessageBytes
            ?? ClipLiveShareSignalingResourceLimits.maximumMessageBytes
    }

    private func receiveLoop(
        socket: any ClipLiveShareWebSocketConnection,
        id: UUID,
        generation: UInt64
    ) async {
        do {
            while !Task.isCancelled {
                let payload = try await socket.receive()
                guard isCurrentConnection(id, generation: generation) else { return }
                await decodeAndEmit(payload, socket: socket)
            }
        } catch {
            guard !Task.isCancelled else { return }
            await connectionDidFail(id: id, generation: generation)
        }
    }

    private func decodeAndEmit(
        _ payload: ClipLiveShareWebSocketPayload,
        socket: any ClipLiveShareWebSocketConnection
    ) async {
        let data: Data = switch payload {
        case .text(let value): Data(value.utf8)
        case .data(let value): value
        }
        let maximumBytes = negotiatedMaximumMessageBytes
        guard data.count <= maximumBytes else {
            rejectInvalidMessage()
            return
        }

        let outer: ClipLiveShareOuterMessage
        do {
            outer = try ClipLiveShareMessageCodec.decodeOuter(
                data,
                maximumBytes: maximumBytes
            )
        } catch {
            rejectInvalidMessage()
            return
        }

        switch outer {
        case .routeOpened(let opened):
            await acceptRoute(opened, socket: socket)

        case .relay(let envelope):
            await openRelay(envelope, socket: socket)

        case .routeClosed(let closed):
            guard encryptedRoutes.removeValue(forKey: closed.routeID) != nil else {
                return
            }
            rememberRejectedRoute(closed.routeID)
            emit(.routeClosed(routeID: closed.routeID, reason: closed.reason))
            logger(.routeClosed(closed.routeID))

        case .hostUnavailable:
            // A host socket should never receive this viewer-only message.
            rejectInvalidMessage()

        case .error(let failure):
            guard !didEmitServerError else { return }
            didEmitServerError = true
            emit(.serverError(code: failure.code))

        case .viewerHello, .closeRoute:
            rejectInvalidMessage()
        }
    }

    private func acceptRoute(
        _ opened: ClipLiveShareRouteOpened,
        socket: any ClipLiveShareWebSocketConnection
    ) async {
        guard let room = roomConfiguration else { return }
        // A duplicate route-opened must never delete the legitimate channel
        // that already owns this route ID.
        guard encryptedRoutes[opened.routeID] == nil,
              !rejectedRouteIDs.contains(opened.routeID) else { return }
        guard let viewerKey = opened.viewerKey,
              encryptedRoutes.count
                < room.capabilities.limits.maximumPendingViewersPerRoom else {
            await rejectUnknownRouteOnce(opened.routeID, socket: socket)
            return
        }
        do {
            encryptedRoutes[opened.routeID] = try ClipLiveShareEncryptedChannel(
                host: room.identity,
                viewerPublicKey: viewerKey,
                room: room.room,
                routeID: opened.routeID
            )
            emit(.routeOpened(routeID: opened.routeID))
            logger(.routeOpened(opened.routeID))
        } catch {
            await rejectUnknownRouteOnce(opened.routeID, socket: socket)
        }
    }

    private func openRelay(
        _ envelope: ClipLiveShareRelayEnvelope,
        socket: any ClipLiveShareWebSocketConnection
    ) async {
        guard let routeID = envelope.routeID else {
            rejectInvalidMessage()
            return
        }
        guard var channel = encryptedRoutes[routeID] else {
            // Viewer and host sockets are independently ordered. A relay that
            // was already in flight can arrive just after Clip closes the
            // introduction route; close it idempotently without destabilizing
            // the authenticated host connection.
            await rejectUnknownRouteOnce(routeID, socket: socket)
            return
        }
        do {
            let message = try channel.open(envelope)
            encryptedRoutes[routeID] = channel
            emit(.message(routeID: routeID, message: message))
        } catch {
            encryptedRoutes[routeID] = nil
            await rejectRoute(routeID, reason: "encrypted-message-rejected", socket: socket)
        }
    }

    private func rejectRoute(
        _ routeID: ClipLiveShareRouteID,
        reason: String,
        socket: any ClipLiveShareWebSocketConnection
    ) async {
        encryptedRoutes[routeID] = nil
        rememberRejectedRoute(routeID)
        try? await sendOuter(.closeRoute(routeID), over: socket)
        emit(.routeRejected(routeID: routeID, reason: reason))
    }

    private func rejectUnknownRouteOnce(
        _ routeID: ClipLiveShareRouteID,
        socket: any ClipLiveShareWebSocketConnection
    ) async {
        guard rememberRejectedRoute(routeID) else { return }
        // Unknown routes never reached the coordinator, so emitting a
        // route-level event only gives a hostile server an event-buffer DoS.
        try? await sendOuter(.closeRoute(routeID), over: socket)
    }

    @discardableResult
    private func rememberRejectedRoute(_ routeID: ClipLiveShareRouteID) -> Bool {
        guard !rejectedRouteIDs.contains(routeID) else { return false }
        let maximumRemembered = min(
            64,
            max(8, (roomConfiguration?.capabilities.limits.maximumPendingViewersPerRoom ?? 8) * 2)
        )
        guard rejectedRouteOrder.count < maximumRemembered else { return false }
        rejectedRouteIDs.insert(routeID)
        rejectedRouteOrder.append(routeID)
        return true
    }

    private func resetPerConnectionRejectionState() {
        rejectedRouteIDs.removeAll(keepingCapacity: false)
        rejectedRouteOrder.removeAll(keepingCapacity: false)
        didEmitInvalidMessage = false
        didEmitServerError = false
    }

    private func rejectInvalidMessage() {
        guard !didEmitInvalidMessage else { return }
        didEmitInvalidMessage = true
        logger(.invalidMessage)
        emit(.invalidMessageReceived)
    }

    private func connectionDidFail(id: UUID, generation: UInt64) async {
        guard let active = connection,
              active.id == id,
              active.generation == generation,
              sessionGeneration == generation else { return }
        connection = nil
        receiveTask?.cancel()
        receiveTask = nil
        let routes = encryptedRoutes.keys.sorted { $0.rawValue < $1.rawValue }
        encryptedRoutes.removeAll()
        resetPerConnectionRejectionState()
        await active.socket.close()
        for routeID in routes {
            emit(.routeClosed(routeID: routeID, reason: "signaling-connection-lost"))
        }
        guard let room = roomConfiguration else {
            emit(.disconnected(reason: .connectionLost, willReconnect: false))
            return
        }
        scheduleReconnect(room: room, attempt: 1, generation: generation)
    }

    private func scheduleReconnect(
        room: ClipLiveShareRoomConfiguration,
        attempt: Int,
        generation: UInt64
    ) {
        guard isCurrentSession(generation) else { return }
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
        logger(.reconnectScheduled(attempt: attempt))
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
                // Cancellation is an intentional stop or superseded retry.
            }
        }
    }

    private func performReconnect(
        room: ClipLiveShareRoomConfiguration,
        attempt: Int,
        token: UUID,
        generation: UInt64
    ) async {
        guard reconnectToken == token, isCurrentSession(generation) else { return }
        reconnectTask = nil
        reconnectToken = nil
        do {
            try await openConnection(
                room: room,
                reconnectAttempt: attempt,
                generation: generation
            )
        } catch {
            guard isCurrentSession(generation) else { return }
            scheduleReconnect(
                room: room,
                attempt: attempt + 1,
                generation: generation
            )
        }
    }

    private func isCurrentSession(_ generation: UInt64) -> Bool {
        sessionGeneration == generation && roomConfiguration != nil
    }

    private func isCurrentOpeningConnection(
        _ id: UUID,
        generation: UInt64
    ) -> Bool {
        guard isCurrentSession(generation), let openingConnection else { return false }
        return openingConnection.id == id
            && openingConnection.generation == generation
    }

    private func isCurrentConnection(_ id: UUID, generation: UInt64) -> Bool {
        guard sessionGeneration == generation, let connection else { return false }
        return connection.id == id && connection.generation == generation
    }

    private func closeOpeningConnectionIfOwned(
        _ id: UUID,
        generation: UInt64
    ) async {
        guard let openingConnection,
              openingConnection.id == id,
              openingConnection.generation == generation else { return }
        self.openingConnection = nil
        await openingConnection.socket.close()
    }

    private func emit(_ event: ClipLiveShareSignalingEvent) {
        var terminated: [UUID] = []
        for (id, continuation) in continuations {
            switch continuation.yield(event) {
            case .enqueued:
                break
            case .dropped:
                // Preserve an explicit terminal marker instead of silently
                // losing routing state. The coordinator treats this as an
                // admission-path failure and keeps established P2P peers.
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
        for id in terminated { continuations.removeValue(forKey: id) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
