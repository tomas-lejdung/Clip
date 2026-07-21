import Foundation

public actor ClipNativeRendezvousHostTransport {
    private let http: ClipNativeRendezvousHTTPClient
    private let webSocketFactory: any ClipLiveShareWebSocketFactory
    private let reconnectPolicy: ClipLiveShareReconnectPolicy
    private let sleeper: any ClipLiveShareReconnectSleeper
    private let attachmentRetryDelaysMilliseconds: [Int64]
    private let lifecycle = ClipNativeRendezvousOperationSequencer()

    private var generation: UInt64 = 0
    private var owner: ClipNativeRendezvousOwner?
    private var capabilities: ClipNativeRendezvousCapabilities?
    private var desiredDescriptor: Data?
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
    private var routes: Set<String> = []
    private var outboundSequences: [String: UInt64] = [:]
    private var inboundSequences: [String: UInt64] = [:]
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
        reconnectSleeper: any ClipLiveShareReconnectSleeper = ContinuousClipLiveShareReconnectSleeper(),
        attachmentRetryDelaysMilliseconds: [Int64] = [25, 50, 100, 200]
    ) {
        http = ClipNativeRendezvousHTTPClient(transport: httpTransport)
        self.webSocketFactory = webSocketFactory
        self.reconnectPolicy = reconnectPolicy
        sleeper = reconnectSleeper
        self.attachmentRetryDelaysMilliseconds = attachmentRetryDelaysMilliseconds
            .filter { $0 >= 0 }
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
    public func attachHost(
        _ owner: ClipNativeRendezvousOwner
    ) async throws -> ClipNativeRendezvousCapabilities {
        guard self.owner == nil,
              capabilities == nil,
              opening == nil,
              connection == nil else {
            throw ClipNativeRendezvousError.connectionAlreadyActive
        }
        generation &+= 1
        let expectedGeneration = generation
        self.owner = owner
        do {
            let capabilities = try await http.discover(at: owner.target.endpoint)
            guard isCurrentSession(expectedGeneration) else {
                throw ClipNativeRendezvousError.operationSuperseded
            }
            _ = try await http.claim(owner, capabilities: capabilities)
            guard isCurrentSession(expectedGeneration) else {
                throw ClipNativeRendezvousError.operationSuperseded
            }
            self.capabilities = capabilities
            try await openConnection(
                owner: owner,
                capabilities: capabilities,
                reconnectAttempt: 0,
                expectedGeneration: expectedGeneration
            )
            return capabilities
        } catch {
            if generation == expectedGeneration, connection == nil, opening == nil {
                self.owner = nil
                capabilities = nil
            }
            throw map(error)
        }
    }

    public func publishSession(descriptor: Data) async throws {
        guard let capabilities,
              !descriptor.isEmpty,
              descriptor.count <= capabilities.maximumDescriptorBytes else {
            throw ClipNativeRendezvousError.invalidDescriptor
        }
        let expectedGeneration = generation
        try await lifecycle.run { [weak self] in
            guard let self else {
                throw ClipNativeRendezvousError.operationSuperseded
            }
            try await self.performPublish(
                descriptor,
                expectedGeneration: expectedGeneration
            )
        }
    }

    public func stopSharing() async throws {
        let expectedGeneration = generation
        try await lifecycle.run { [weak self] in
            guard let self else {
                throw ClipNativeRendezvousError.operationSuperseded
            }
            try await self.performStopSharing(expectedGeneration: expectedGeneration)
        }
    }

    public func send(_ payload: Data, to routeID: String) async throws {
        guard let capabilities else {
            throw ClipNativeRendezvousError.notConnected
        }
        guard !payload.isEmpty,
              payload.count <= capabilities.maximumOpaquePayloadBytes else {
            throw ClipNativeRendezvousError.invalidOpaquePayload
        }
        guard ClipNativeRendezvousWireCodec.validRouteID(routeID) else {
            throw ClipNativeRendezvousError.invalidRouteID
        }
        guard let active = connection else {
            throw ClipNativeRendezvousError.notConnected
        }
        guard routes.contains(routeID) else {
            throw ClipNativeRendezvousError.routeNotFound
        }
        let sequence = (outboundSequences[routeID] ?? 0) &+ 1
        guard sequence > 0 else {
            await closeRoute(routeID, reason: "sequence-exhausted")
            throw ClipNativeRendezvousError.routeNotFound
        }
        outboundSequences[routeID] = sequence
        let message = ClipNativeRendezvousWireMessage(
            type: .relay,
            version: capabilities.messageVersion,
            routeID: routeID,
            sequence: sequence,
            payload: ClipNativeRendezvousBase64URL.encode(payload)
        )
        do {
            try await active.socket.send(try ClipNativeRendezvousWireCodec.encode(
                message,
                maximumBytes: capabilities.maximumMessageBytes
            ))
            guard isCurrentConnection(active.id, expectedGeneration: active.generation),
                  routes.contains(routeID) else {
                throw ClipNativeRendezvousError.routeNotFound
            }
        } catch let error as ClipNativeRendezvousError {
            if case .messageTooLarge = error {
                await closeRoute(routeID, reason: "message-too-large")
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

    public func closeRoute(_ routeID: String, reason: String? = nil) async {
        guard routes.remove(routeID) != nil else { return }
        outboundSequences[routeID] = nil
        inboundSequences[routeID] = nil
        emit(.routeClosed(routeID: routeID, reason: reason))
        guard let active = connection,
              let capabilities,
              ClipNativeRendezvousWireCodec.validReason(reason) else { return }
        let message = ClipNativeRendezvousWireMessage(
            type: .closeRoute,
            version: capabilities.messageVersion,
            routeID: routeID,
            reason: reason
        )
        do {
            try await active.socket.send(try ClipNativeRendezvousWireCodec.encode(
                message,
                maximumBytes: capabilities.maximumMessageBytes
            ))
        } catch {
            await connectionDidFail(
                id: active.id,
                expectedGeneration: active.generation
            )
        }
    }

    public func teardown(removeRendezvous: Bool = false) async {
        generation &+= 1
        let owner = self.owner
        let capabilities = self.capabilities
        let opening = self.opening
        let active = connection
        self.owner = nil
        self.capabilities = nil
        self.opening = nil
        connection = nil
        desiredDescriptor = nil
        reconnectToken = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        retireAllRoutes(reason: "transport-stopped")
        resetPerConnectionState()
        if let opening { await opening.socket.close() }
        if let active { await active.socket.close() }

        if let owner, let capabilities {
            try? await lifecycle.run { [http] in
                try? await http.stopSession(for: owner, capabilities: capabilities)
                if removeRendezvous {
                    try? await http.delete(owner, capabilities: capabilities)
                }
            }
        }
        emit(.stopped)
    }

    private func performPublish(
        _ descriptor: Data,
        expectedGeneration: UInt64
    ) async throws {
        guard isCurrentSession(expectedGeneration),
              connection != nil,
              let owner,
              let capabilities else {
            throw ClipNativeRendezvousError.notConnected
        }
        var retryIndex = 0
        while true {
            do {
                try await http.publishSession(
                    descriptor: descriptor,
                    for: owner,
                    capabilities: capabilities
                )
                break
            } catch ClipNativeRendezvousError.hostOffline {
                guard retryIndex < attachmentRetryDelaysMilliseconds.count else {
                    throw ClipNativeRendezvousError.hostOffline
                }
                let delay = Duration.milliseconds(
                    attachmentRetryDelaysMilliseconds[retryIndex]
                )
                retryIndex += 1
                try await sleeper.sleep(for: delay)
                guard isCurrentSession(expectedGeneration), connection != nil else {
                    throw ClipNativeRendezvousError.operationSuperseded
                }
            }
        }
        guard isCurrentSession(expectedGeneration), connection != nil else {
            throw ClipNativeRendezvousError.operationSuperseded
        }
        desiredDescriptor = descriptor
        retireAllRoutes(reason: "session-rotated")
        emit(.hostActive)
    }

    private func performStopSharing(expectedGeneration: UInt64) async throws {
        guard isCurrentSession(expectedGeneration),
              let owner,
              let capabilities else {
            throw ClipNativeRendezvousError.notConnected
        }
        try await http.stopSession(for: owner, capabilities: capabilities)
        guard isCurrentSession(expectedGeneration) else {
            throw ClipNativeRendezvousError.operationSuperseded
        }
        desiredDescriptor = nil
        retireAllRoutes(reason: "sharing-stopped")
        if connection != nil {
            emit(.hostPreparing(reconnectAttempt: 0))
        }
    }

    private func openConnection(
        owner: ClipNativeRendezvousOwner,
        capabilities: ClipNativeRendezvousCapabilities,
        reconnectAttempt: Int,
        expectedGeneration: UInt64
    ) async throws {
        guard isCurrentSession(expectedGeneration) else {
            throw ClipNativeRendezvousError.operationSuperseded
        }
        emit(.connecting(role: .host, reconnectAttempt: reconnectAttempt))
        var request = URLRequest(
            url: try capabilities.hostWebSocketURL(for: owner.target)
        )
        request.timeoutInterval = 10
        request.setValue(
            owner.authorizationHeaderValue,
            forHTTPHeaderField: "Authorization"
        )
        let underlying: any ClipLiveShareWebSocketConnection
        do {
            underlying = try await webSocketFactory.makeConnection(for: request)
        } catch {
            throw ClipNativeRendezvousError.connectionFailed
        }
        let socket = ClipNativeRendezvousSerializedSocket(base: underlying)
        guard isCurrentSession(expectedGeneration) else {
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
        resetPerConnectionState()
        emit(.connected(role: .host, reconnectAttempt: reconnectAttempt))
        emit(.hostPreparing(reconnectAttempt: reconnectAttempt))
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
                await handle(payload, socket: socket)
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
        socket: ClipNativeRendezvousSerializedSocket
    ) async {
        guard let capabilities else { return }
        let decoded: (
            message: ClipNativeRendezvousWireMessage,
            decodedPayload: Data?
        )
        do {
            decoded = try ClipNativeRendezvousWireCodec.decode(
                payload,
                role: .host,
                capabilities: capabilities
            )
        } catch {
            rejectInvalidMessage()
            return
        }
        let message = decoded.message
        switch message.type {
        case .routeOpened:
            guard let routeID = message.routeID else { return }
            guard routes.count < capabilities.maximumPendingRoutes,
                  !routes.contains(routeID) else {
                await rejectRoute(routeID, reason: "route-rejected", socket: socket)
                return
            }
            routes.insert(routeID)
            outboundSequences[routeID] = 0
            inboundSequences[routeID] = 0
            emit(.routeOpened(routeID: routeID, descriptor: nil))

        case .relay:
            guard let routeID = message.routeID,
                  routes.contains(routeID),
                  let sequence = message.sequence,
                  sequence == (inboundSequences[routeID] ?? 0) &+ 1,
                  let opaque = decoded.decodedPayload else {
                if let routeID = message.routeID {
                    await rejectRoute(
                        routeID,
                        reason: "relay-sequence-rejected",
                        socket: socket
                    )
                } else {
                    rejectInvalidMessage()
                }
                return
            }
            inboundSequences[routeID] = sequence
            emit(.relay(routeID: routeID, payload: opaque, sequence: sequence))

        case .routeClosed:
            guard let routeID = message.routeID,
                  routes.remove(routeID) != nil else { return }
            outboundSequences[routeID] = nil
            inboundSequences[routeID] = nil
            emit(.routeClosed(routeID: routeID, reason: message.reason))

        case .error:
            guard !didEmitServerError, let code = message.code else { return }
            didEmitServerError = true
            emit(.serverError(code: code))

        case .hostUnavailable, .closeRoute:
            rejectInvalidMessage()
        }
    }

    private func rejectRoute(
        _ routeID: String,
        reason: String,
        socket: ClipNativeRendezvousSerializedSocket
    ) async {
        routes.remove(routeID)
        outboundSequences[routeID] = nil
        inboundSequences[routeID] = nil
        guard let capabilities else { return }
        let message = ClipNativeRendezvousWireMessage(
            type: .closeRoute,
            version: capabilities.messageVersion,
            routeID: routeID,
            reason: reason
        )
        try? await socket.send(try ClipNativeRendezvousWireCodec.encode(
            message,
            maximumBytes: capabilities.maximumMessageBytes
        ))
        emit(.routeClosed(routeID: routeID, reason: reason))
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
        retireAllRoutes(reason: "signaling-connection-lost")
        resetPerConnectionState()
        await active.socket.close()
        scheduleReconnect(attempt: 1, expectedGeneration: expectedGeneration)
    }

    private func scheduleReconnect(
        attempt: Int,
        expectedGeneration: UInt64
    ) {
        guard isCurrentSession(expectedGeneration) else { return }
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
              let owner,
              let capabilities else { return }
        reconnectToken = nil
        reconnectTask = nil
        do {
            _ = try await http.renew(owner, capabilities: capabilities)
            guard isCurrentSession(expectedGeneration) else {
                throw ClipNativeRendezvousError.operationSuperseded
            }
            try await openConnection(
                owner: owner,
                capabilities: capabilities,
                reconnectAttempt: attempt,
                expectedGeneration: expectedGeneration
            )
            if let descriptor = desiredDescriptor {
                try await lifecycle.run { [weak self] in
                    guard let self else {
                        throw ClipNativeRendezvousError.operationSuperseded
                    }
                    try await self.performPublish(
                        descriptor,
                        expectedGeneration: expectedGeneration
                    )
                }
            }
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
        retireAllRoutes(reason: "signaling-connection-lost")
        resetPerConnectionState()
        await active.socket.close()
    }

    private func retireAllRoutes(reason: String) {
        let activeRoutes = routes.sorted()
        routes.removeAll()
        outboundSequences.removeAll()
        inboundSequences.removeAll()
        for routeID in activeRoutes {
            emit(.routeClosed(routeID: routeID, reason: reason))
        }
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
        generation == expectedGeneration && owner != nil
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
