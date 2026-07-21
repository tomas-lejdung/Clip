import Foundation

public actor ClipNativeRendezvousViewerTransport {
    private let http: ClipNativeRendezvousHTTPClient
    private let webSocketFactory: any ClipLiveShareWebSocketFactory
    private let reconnectPolicy: ClipLiveShareReconnectPolicy
    private let sleeper: any ClipLiveShareReconnectSleeper

    private var generation: UInt64 = 0
    private var target: ClipNativeRendezvousTarget?
    private var capabilities: ClipNativeRendezvousCapabilities?
    private var opening: (
        id: UUID,
        generation: UInt64,
        socket: ClipNativeRendezvousSerializedSocket
    )?
    private var connection: (
        id: UUID,
        generation: UInt64,
        socket: ClipNativeRendezvousSerializedSocket
    )?
    private var routeID: String?
    private var descriptor: Data?
    private var outboundSequence: UInt64 = 0
    private var inboundSequence: UInt64 = 0
    private var completedIntroduction = false
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectToken: UUID?
    private var didEmitInvalidMessage = false
    private var didEmitServerError = false
    private var continuations: [
        UUID: AsyncStream<ClipNativeRendezvousEvent>.Continuation
    ] = [:]

    public init(
        httpTransport: any ClipLiveShareHTTPTransport = URLSessionClipLiveShareHTTPTransport(),
        webSocketFactory: any ClipLiveShareWebSocketFactory = URLSessionClipLiveShareWebSocketFactory(),
        reconnectPolicy: ClipLiveShareReconnectPolicy = .boundedExponential,
        reconnectSleeper: any ClipLiveShareReconnectSleeper = ContinuousClipLiveShareReconnectSleeper()
    ) {
        http = ClipNativeRendezvousHTTPClient(transport: httpTransport)
        self.webSocketFactory = webSocketFactory
        self.reconnectPolicy = reconnectPolicy
        sleeper = reconnectSleeper
    }

    public func events() -> AsyncStream<ClipNativeRendezvousEvent> {
        let id = UUID()
        let pair = clipNativeRendezvousEventStream()
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return pair.stream
    }

    @discardableResult
    public func attachViewer(
        _ target: ClipNativeRendezvousTarget
    ) async throws -> ClipNativeRendezvousCapabilities {
        guard self.target == nil,
              capabilities == nil,
              opening == nil,
              connection == nil else {
            throw ClipNativeRendezvousError.connectionAlreadyActive
        }
        generation &+= 1
        let expectedGeneration = generation
        self.target = target
        completedIntroduction = false
        do {
            let capabilities = try await http.discover(at: target.endpoint)
            guard isCurrentSession(expectedGeneration) else {
                throw ClipNativeRendezvousError.operationSuperseded
            }
            let status = try await http.status(target, capabilities: capabilities)
            guard status.state == .active else {
                throw ClipNativeRendezvousError.rendezvousNotLive
            }
            guard isCurrentSession(expectedGeneration) else {
                throw ClipNativeRendezvousError.operationSuperseded
            }
            self.capabilities = capabilities
            try await openConnection(
                target: target,
                capabilities: capabilities,
                reconnectAttempt: 0,
                expectedGeneration: expectedGeneration
            )
            return capabilities
        } catch {
            if generation == expectedGeneration, connection == nil, opening == nil {
                self.target = nil
                capabilities = nil
            }
            throw map(error)
        }
    }

    public func send(_ payload: Data) async throws {
        guard let capabilities else {
            throw ClipNativeRendezvousError.notConnected
        }
        guard !payload.isEmpty,
              payload.count <= capabilities.maximumOpaquePayloadBytes else {
            throw ClipNativeRendezvousError.invalidOpaquePayload
        }
        guard let active = connection else {
            throw ClipNativeRendezvousError.notConnected
        }
        guard let routeID else {
            throw ClipNativeRendezvousError.routeNotFound
        }
        let sequence = outboundSequence &+ 1
        guard sequence > 0 else {
            await closeRoute(reason: "sequence-exhausted")
            throw ClipNativeRendezvousError.routeNotFound
        }
        outboundSequence = sequence
        let message = ClipNativeRendezvousWireMessage(
            type: .relay,
            version: capabilities.messageVersion,
            sequence: sequence,
            payload: ClipNativeRendezvousBase64URL.encode(payload)
        )
        do {
            try await active.socket.send(try ClipNativeRendezvousWireCodec.encode(
                message,
                maximumBytes: capabilities.maximumMessageBytes
            ))
            guard isCurrentConnection(active.id, expectedGeneration: active.generation),
                  self.routeID == routeID else {
                throw ClipNativeRendezvousError.routeNotFound
            }
        } catch let error as ClipNativeRendezvousError {
            if case .messageTooLarge = error {
                await closeRoute(reason: "message-too-large")
                throw error
            }
            if error == .routeNotFound { throw error }
            await connectionDidFail(
                id: active.id,
                expectedGeneration: active.generation
            )
            throw ClipNativeRendezvousError.sendFailed
        } catch {
            await connectionDidFail(
                id: active.id,
                expectedGeneration: active.generation
            )
            throw ClipNativeRendezvousError.sendFailed
        }
    }

    /// Ends only the server-assisted introduction. A WebRTC connection already
    /// established from the opaque exchange remains peer-to-peer.
    public func closeRoute(reason: String? = nil) async {
        guard let routeID else { return }
        let active = connection
        let capabilities = self.capabilities
        completedIntroduction = true
        self.routeID = nil
        descriptor = nil
        outboundSequence = 0
        inboundSequence = 0
        connection = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectToken = nil
        emit(.routeClosed(routeID: routeID, reason: reason))
        guard let active, let capabilities else { return }
        if ClipNativeRendezvousWireCodec.validReason(reason) {
            let message = ClipNativeRendezvousWireMessage(
                type: .closeRoute,
                version: capabilities.messageVersion,
                reason: reason
            )
            try? await active.socket.send(try ClipNativeRendezvousWireCodec.encode(
                message,
                maximumBytes: capabilities.maximumMessageBytes
            ))
        }
        await active.socket.close()
    }

    public func teardown() async {
        generation &+= 1
        let opening = self.opening
        let active = connection
        target = nil
        capabilities = nil
        self.opening = nil
        connection = nil
        if let routeID {
            emit(.routeClosed(routeID: routeID, reason: "transport-stopped"))
        }
        routeID = nil
        descriptor = nil
        outboundSequence = 0
        inboundSequence = 0
        completedIntroduction = false
        reconnectToken = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        resetPerConnectionState()
        if let opening { await opening.socket.close() }
        if let active { await active.socket.close() }
        emit(.stopped)
    }

    private func openConnection(
        target: ClipNativeRendezvousTarget,
        capabilities: ClipNativeRendezvousCapabilities,
        reconnectAttempt: Int,
        expectedGeneration: UInt64
    ) async throws {
        guard isCurrentSession(expectedGeneration), !completedIntroduction else {
            throw ClipNativeRendezvousError.operationSuperseded
        }
        emit(.connecting(role: .viewer, reconnectAttempt: reconnectAttempt))
        var request = URLRequest(
            url: try capabilities.viewerWebSocketURL(for: target)
        )
        request.timeoutInterval = 10
        let underlying: any ClipLiveShareWebSocketConnection
        do {
            underlying = try await webSocketFactory.makeConnection(for: request)
        } catch {
            throw ClipNativeRendezvousError.connectionFailed
        }
        let socket = ClipNativeRendezvousSerializedSocket(base: underlying)
        guard isCurrentSession(expectedGeneration), !completedIntroduction else {
            await socket.close()
            throw ClipNativeRendezvousError.operationSuperseded
        }
        let id = UUID()
        opening = (id, expectedGeneration, socket)
        do {
            try await socket.resume()
            guard isCurrentOpening(id, expectedGeneration: expectedGeneration) else {
                throw ClipNativeRendezvousError.operationSuperseded
            }
        } catch {
            if isCurrentOpening(id, expectedGeneration: expectedGeneration) {
                opening = nil
            }
            await socket.close()
            throw map(error)
        }
        opening = nil
        connection = (id, expectedGeneration, socket)
        routeID = nil
        descriptor = nil
        outboundSequence = 0
        inboundSequence = 0
        resetPerConnectionState()
        emit(.connected(role: .viewer, reconnectAttempt: reconnectAttempt))
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(
                socket: socket,
                id: id,
                expectedGeneration: expectedGeneration
            )
        }
    }

    private func receiveLoop(
        socket: ClipNativeRendezvousSerializedSocket,
        id: UUID,
        expectedGeneration: UInt64
    ) async {
        do {
            while !Task.isCancelled {
                let payload = try await socket.receive()
                guard isCurrentConnection(
                    id,
                    expectedGeneration: expectedGeneration
                ) else { return }
                await handle(
                    payload,
                    socket: socket,
                    id: id,
                    expectedGeneration: expectedGeneration
                )
            }
        } catch {
            guard !Task.isCancelled else { return }
            await connectionDidFail(
                id: id,
                expectedGeneration: expectedGeneration
            )
        }
    }

    private func handle(
        _ payload: ClipLiveShareWebSocketPayload,
        socket: ClipNativeRendezvousSerializedSocket,
        id: UUID,
        expectedGeneration: UInt64
    ) async {
        guard let capabilities else { return }
        let decoded: (
            message: ClipNativeRendezvousWireMessage,
            decodedPayload: Data?
        )
        do {
            decoded = try ClipNativeRendezvousWireCodec.decode(
                payload,
                role: .viewer,
                capabilities: capabilities
            )
        } catch {
            rejectInvalidMessage()
            return
        }
        let message = decoded.message
        switch message.type {
        case .routeOpened:
            guard routeID == nil,
                  let routeID = message.routeID,
                  let descriptor = decoded.decodedPayload else {
                rejectInvalidMessage()
                return
            }
            self.routeID = routeID
            self.descriptor = descriptor
            outboundSequence = 0
            inboundSequence = 0
            emit(.routeOpened(routeID: routeID, descriptor: descriptor))

        case .relay:
            guard let currentRoute = routeID,
                  message.routeID == currentRoute,
                  let sequence = message.sequence,
                  sequence == inboundSequence &+ 1,
                  let opaque = decoded.decodedPayload else {
                await rejectCurrentRoute(reason: "relay-sequence-rejected", socket: socket)
                return
            }
            inboundSequence = sequence
            emit(.relay(routeID: currentRoute, payload: opaque, sequence: sequence))

        case .routeClosed:
            guard let currentRoute = routeID,
                  message.routeID == currentRoute else { return }
            completedIntroduction = true
            routeID = nil
            descriptor = nil
            outboundSequence = 0
            inboundSequence = 0
            connection = nil
            receiveTask?.cancel()
            receiveTask = nil
            emit(.routeClosed(routeID: currentRoute, reason: message.reason))
            await socket.close()

        case .hostUnavailable:
            await connectionDidFail(
                id: id,
                expectedGeneration: expectedGeneration
            )

        case .error:
            guard !didEmitServerError, let code = message.code else { return }
            didEmitServerError = true
            emit(.serverError(code: code))

        case .closeRoute:
            rejectInvalidMessage()
        }
    }

    private func rejectCurrentRoute(
        reason: String,
        socket: ClipNativeRendezvousSerializedSocket
    ) async {
        guard let currentRoute = routeID, let capabilities else {
            rejectInvalidMessage()
            return
        }
        completedIntroduction = true
        routeID = nil
        descriptor = nil
        outboundSequence = 0
        inboundSequence = 0
        let message = ClipNativeRendezvousWireMessage(
            type: .closeRoute,
            version: capabilities.messageVersion,
            reason: reason
        )
        try? await socket.send(try ClipNativeRendezvousWireCodec.encode(
            message,
            maximumBytes: capabilities.maximumMessageBytes
        ))
        emit(.routeClosed(routeID: currentRoute, reason: reason))
    }

    private func connectionDidFail(
        id: UUID,
        expectedGeneration: UInt64
    ) async {
        guard let active = connection,
              active.id == id,
              active.generation == expectedGeneration,
              isCurrentSession(expectedGeneration) else { return }
        connection = nil
        receiveTask?.cancel()
        receiveTask = nil
        if let routeID {
            emit(.routeClosed(
                routeID: routeID,
                reason: "signaling-connection-lost"
            ))
        }
        routeID = nil
        descriptor = nil
        outboundSequence = 0
        inboundSequence = 0
        resetPerConnectionState()
        await active.socket.close()
        guard !completedIntroduction else { return }
        scheduleReconnect(attempt: 1, expectedGeneration: expectedGeneration)
    }

    private func scheduleReconnect(
        attempt: Int,
        expectedGeneration: UInt64
    ) {
        guard isCurrentSession(expectedGeneration), !completedIntroduction else { return }
        guard let delay = reconnectPolicy.delay(forAttempt: attempt) else {
            reconnectToken = nil
            reconnectTask = nil
            emit(.disconnected(reason: .reconnectExhausted, willReconnect: false))
            return
        }
        let token = UUID()
        reconnectToken = token
        emit(.disconnected(reason: .connectionLost, willReconnect: true))
        emit(.reconnectScheduled(attempt: attempt, delay: delay))
        reconnectTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.sleeper.sleep(for: delay)
                await self.performReconnect(
                    attempt: attempt,
                    token: token,
                    expectedGeneration: expectedGeneration
                )
            } catch {
                // Teardown and superseded retries intentionally cancel sleep.
            }
        }
    }

    private func performReconnect(
        attempt: Int,
        token: UUID,
        expectedGeneration: UInt64
    ) async {
        guard reconnectToken == token,
              isCurrentSession(expectedGeneration),
              !completedIntroduction,
              let target,
              let capabilities else { return }
        reconnectToken = nil
        reconnectTask = nil
        do {
            let status = try await http.status(target, capabilities: capabilities)
            guard status.state == .active else {
                throw ClipNativeRendezvousError.rendezvousNotLive
            }
            try await openConnection(
                target: target,
                capabilities: capabilities,
                reconnectAttempt: attempt,
                expectedGeneration: expectedGeneration
            )
        } catch {
            await closeCurrentConnectionWithoutScheduling(
                expectedGeneration: expectedGeneration
            )
            scheduleReconnect(
                attempt: attempt + 1,
                expectedGeneration: expectedGeneration
            )
        }
    }

    private func closeCurrentConnectionWithoutScheduling(
        expectedGeneration: UInt64
    ) async {
        guard let active = connection,
              active.generation == expectedGeneration else { return }
        connection = nil
        receiveTask?.cancel()
        receiveTask = nil
        routeID = nil
        descriptor = nil
        outboundSequence = 0
        inboundSequence = 0
        resetPerConnectionState()
        await active.socket.close()
    }

    private func resetPerConnectionState() {
        didEmitInvalidMessage = false
        didEmitServerError = false
    }

    private func rejectInvalidMessage() {
        guard !didEmitInvalidMessage else { return }
        didEmitInvalidMessage = true
        emit(.invalidMessageReceived)
    }

    private func emit(_ event: ClipNativeRendezvousEvent) {
        var terminated: [UUID] = []
        for (id, continuation) in continuations {
            switch continuation.yield(event) {
            case .enqueued:
                break
            case .dropped:
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

    private func isCurrentSession(_ expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration && target != nil
    }

    private func isCurrentOpening(
        _ id: UUID,
        expectedGeneration: UInt64
    ) -> Bool {
        guard isCurrentSession(expectedGeneration), let opening else { return false }
        return opening.id == id && opening.generation == expectedGeneration
    }

    private func isCurrentConnection(
        _ id: UUID,
        expectedGeneration: UInt64
    ) -> Bool {
        guard isCurrentSession(expectedGeneration), let connection else { return false }
        return connection.id == id && connection.generation == expectedGeneration
    }

    private func map(_ error: any Error) -> ClipNativeRendezvousError {
        if let error = error as? ClipNativeRendezvousError { return error }
        return .connectionFailed
    }
}
