import ClipLiveShare
import Foundation
import Synchronization
import Testing
@testable import ClipLiveShareWebRTC

@Suite("Clip Live Share native signaling transport")
struct ClipLiveShareSignalingTransportTests {
    @Test("capabilities are discovered and a colliding preferred room is retried")
    func capabilitiesAndRoomCollision() async throws {
        let capabilities = ClipLiveShareCapabilities.v1Default
        let preferred = try ClipLiveShareRoomName(rawValue: "CRISP-OTTER-042")
        let http = NativeMockHTTPTransport { request, index in
            switch index {
            case 0:
                return .init(statusCode: 200, data: try encodeJSON(capabilities))
            case 1:
                #expect(request.url?.path == "/api/v1/rooms/CRISP-OTTER-042")
                return .init(statusCode: 409, data: Data())
            default:
                let room = try ClipLiveShareRoomName(
                    rawValue: try #require(request.url?.lastPathComponent)
                )
                return .init(
                    statusCode: 201,
                    data: try encodeJSON(ClipLiveShareRoomAdvertisement(
                        room: room,
                        leaseDurationSeconds: 300
                    ))
                )
            }
        }
        let client = makeNativeClient(http: http)

        let room = try await client.createRoom(
            at: .localDevelopment,
            preferredRoomName: preferred,
            maximumNameAttempts: 2
        )

        #expect(room.room != preferred)
        #expect(room.capabilities == capabilities)
        let requests = await http.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests[0].url == URL(string:
            "http://localhost:8080/.well-known/clip-live-share"
        ))
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[1].httpMethod == "PUT")
        #expect(requests[2].httpMethod == "PUT")
        let firstBody = try JSONDecoder().decode(
            ClipLiveShareAdvertiseRoomRequest.self,
            from: try #require(requests[1].httpBody)
        )
        let secondBody = try JSONDecoder().decode(
            ClipLiveShareAdvertiseRoomRequest.self,
            from: try #require(requests[2].httpBody)
        )
        #expect(firstBody.ownerToken == room.ownerToken)
        #expect(secondBody.ownerToken == room.ownerToken)
    }

    @Test("stop racing a successful room advertisement removes the new lease")
    func stopDuringRoomAdvertisementDeletesLease() async throws {
        let capabilities = ClipLiveShareCapabilities.v1Default
        let preferred = try ClipLiveShareRoomName(rawValue: "CRISP-OTTER-042")
        let putGate = NativeAsyncGate()
        let http = NativeMockHTTPTransport { request, index in
            switch index {
            case 0:
                return .init(statusCode: 200, data: try encodeJSON(capabilities))
            case 1:
                #expect(request.httpMethod == "PUT")
                await putGate.wait()
                return .init(
                    statusCode: 201,
                    data: try encodeJSON(ClipLiveShareRoomAdvertisement(
                        room: preferred,
                        leaseDurationSeconds: 300
                    ))
                )
            default:
                #expect(request.httpMethod == "DELETE")
                return .init(statusCode: 204, data: Data())
            }
        }
        let client = makeNativeClient(http: http)
        let creation = Task {
            try await client.createRoom(
                at: .localDevelopment,
                preferredRoomName: preferred,
                maximumNameAttempts: 1
            )
        }
        try await eventuallyNative { await http.recordedRequests().count == 2 }

        await client.stop()
        await putGate.open()
        await #expect(throws: ClipLiveShareNetworkError.connectionFailed) {
            try await creation.value
        }
        try await eventuallyNative { await http.recordedRequests().count == 3 }

        let requests = await http.recordedRequests()
        let put = requests[1]
        let delete = requests[2]
        let advertised = try JSONDecoder().decode(
            ClipLiveShareAdvertiseRoomRequest.self,
            from: try #require(put.httpBody)
        )
        #expect(delete.url == put.url)
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.value(forHTTPHeaderField: "Authorization")
            == advertised.ownerToken.authorizationHeaderValue)
        #expect(delete.httpBody == nil)
    }

    @Test("host WebSocket uses the capability path and owner bearer token")
    func bearerHostConnection() async throws {
        let socket = NativeMockWebSocket()
        let factory = NativeMockWebSocketFactory(results: [.success(socket)])
        let room = makeNativeRoom()
        let client = makeNativeClient(factory: factory)
        let recorder = await recordNativeEvents(from: client)

        try await client.connect(room: room)

        #expect(await socket.resumeCount() == 1)
        let requests = await factory.recordedRequests()
        let request = try #require(requests.first)
        let expectedHostURL = try room.hostWebSocketURL
        #expect(request.url == expectedHostURL)
        #expect(request.value(forHTTPHeaderField: "Authorization")
            == room.ownerToken.authorizationHeaderValue)
        try await eventuallyNative {
            await recorder.snapshot().contains(.connected(
                room: room.room,
                reconnectAttempt: 0
            ))
        }

        await client.stop(removeAdvertisement: false)
        #expect(await socket.closeCount() == 1)
    }

    @Test("route traffic is encrypted in both directions and close removes only introduction state")
    func encryptedRouteRoundTripAndClose() async throws {
        let socket = NativeMockWebSocket()
        let client = makeNativeClient(
            factory: NativeMockWebSocketFactory(results: [.success(socket)])
        )
        let room = makeNativeRoom()
        let recorder = await recordNativeEvents(from: client)
        try await client.connect(room: room)

        let routeID = ClipLiveShareRouteID.random()
        let viewer = ClipLiveShareViewerIdentity()
        await socket.enqueue(try outerPayload(.routeOpened(.init(
            routeID: routeID,
            viewerKey: viewer.publicKey
        ))))
        try await eventuallyNative {
            await recorder.snapshot().contains(.routeOpened(routeID: routeID))
        }

        var viewerChannel = try ClipLiveShareEncryptedChannel(
            viewer: viewer,
            roomPublicKey: room.identity.publicKey,
            room: room.room,
            routeID: routeID
        )
        let sessionID = ClipLiveShareSessionID.random()
        let fromViewer = ClipLiveShareInnerMessage.sharingState(.init(
            sessionID: sessionID,
            sharing: true
        ))
        await socket.enqueue(try outerPayload(.relay(
            forwardedToHost(try viewerChannel.seal(fromViewer), routeID: routeID)
        )))
        try await eventuallyNative {
            await recorder.snapshot().contains(.message(
                routeID: routeID,
                message: fromViewer
            ))
        }

        let toViewer = ClipLiveShareInnerMessage.authResult(try .init(
            sessionID: sessionID,
            allowed: true
        ))
        try await client.send(toViewer, to: routeID)
        let relays = try await socket.decodedOuterMessages().compactMap { message in
            if case .relay(let envelope) = message { return envelope }
            return nil
        }
        #expect(relays.count == 1)
        #expect(try viewerChannel.open(try #require(relays.first)) == toViewer)

        await client.closeRoute(routeID)
        let sent = try await socket.decodedOuterMessages()
        #expect(sent.contains(.closeRoute(routeID)))
        await #expect(throws: ClipLiveShareNetworkError.routeNotFound) {
            try await client.send(toViewer, to: routeID)
        }
        await client.stop(removeAdvertisement: false)
    }

    @Test("concurrent encrypted sends stay ordered and a concurrent close cannot resurrect route state")
    func concurrentSendsAndCloseSerializeRouteState() async throws {
        let firstSendGate = NativeAsyncGate()
        let secondSendGate = NativeAsyncGate()
        let socket = NativeMockWebSocket(sendGates: [firstSendGate, secondSendGate])
        let client = makeNativeClient(
            factory: NativeMockWebSocketFactory(results: [.success(socket)])
        )
        let room = makeNativeRoom()
        let recorder = await recordNativeEvents(from: client)
        try await client.connect(room: room)

        let routeID = ClipLiveShareRouteID.random()
        let viewer = ClipLiveShareViewerIdentity()
        await socket.enqueue(try outerPayload(.routeOpened(.init(
            routeID: routeID,
            viewerKey: viewer.publicKey
        ))))
        try await eventuallyNative {
            await recorder.snapshot().contains(.routeOpened(routeID: routeID))
        }

        let sessionID = ClipLiveShareSessionID.random()
        let firstMessage = ClipLiveShareInnerMessage.sharingState(.init(
            sessionID: sessionID,
            sharing: true
        ))
        let secondMessage = ClipLiveShareInnerMessage.focus(.init(
            sessionID: sessionID,
            streamID: nil
        ))
        let firstSend = Task { try await client.send(firstMessage, to: routeID) }
        try await eventuallyNative { await socket.sentPayloads().count == 1 }

        let secondSend = Task { try await client.send(secondMessage, to: routeID) }
        await firstSendGate.open()
        try await eventuallyNative { await socket.sentPayloads().count == 2 }

        // `closeRoute` clears the actor's route state before awaiting its queued
        // socket send. Release the second relay from another task so close and
        // the suspended send genuinely interleave.
        let releaseSecond = Task {
            try await Task.sleep(for: .milliseconds(10))
            await secondSendGate.open()
        }
        await client.closeRoute(routeID)
        try await releaseSecond.value
        try await firstSend.value
        try await secondSend.value

        let sent = try await socket.decodedOuterMessages()
        let relays = sent.compactMap { message -> ClipLiveShareRelayEnvelope? in
            guard case .relay(let envelope) = message else { return nil }
            return envelope
        }
        #expect(relays.map(\.sequence) == [1, 2])
        #expect(sent.last == .closeRoute(routeID))

        var viewerChannel = try ClipLiveShareEncryptedChannel(
            viewer: viewer,
            roomPublicKey: room.identity.publicKey,
            room: room.room,
            routeID: routeID
        )
        #expect(try viewerChannel.open(relays[0]) == firstMessage)
        #expect(try viewerChannel.open(relays[1]) == secondMessage)
        await #expect(throws: ClipLiveShareNetworkError.routeNotFound) {
            try await client.send(firstMessage, to: routeID)
        }
        await client.stop(removeAdvertisement: false)
    }

    @Test("tampered encrypted traffic fails closed for its route without killing the host socket")
    func tamperRejectsRoute() async throws {
        let fixture = try await connectedEncryptedRoute()
        defer { Task { await fixture.client.stop(removeAdvertisement: false) } }

        var viewerChannel = fixture.viewerChannel
        let message = ClipLiveShareInnerMessage.sharingState(.init(
            sessionID: .random(),
            sharing: true
        ))
        let valid = try viewerChannel.seal(message)
        var ciphertext = valid.ciphertext
        ciphertext[ciphertext.startIndex] ^= 0x80
        let tampered = try ClipLiveShareRelayEnvelope(
            routeID: fixture.routeID,
            sequence: valid.sequence,
            nonce: valid.nonce,
            ciphertext: ciphertext
        )
        await fixture.socket.enqueue(try outerPayload(.relay(tampered)))

        try await eventuallyNative {
            await fixture.recorder.snapshot().contains(.routeRejected(
                routeID: fixture.routeID,
                reason: "encrypted-message-rejected"
            ))
        }
        await #expect(throws: ClipLiveShareNetworkError.routeNotFound) {
            try await fixture.client.send(message, to: fixture.routeID)
        }
        #expect(await fixture.socket.closeCount() == 0)
    }

    @Test("replayed encrypted traffic is rejected by the monotonic route sequence")
    func replayRejectsRoute() async throws {
        let fixture = try await connectedEncryptedRoute()
        defer { Task { await fixture.client.stop(removeAdvertisement: false) } }

        var viewerChannel = fixture.viewerChannel
        let message = ClipLiveShareInnerMessage.sharingState(.init(
            sessionID: .random(),
            sharing: true
        ))
        let relay = forwardedToHost(
            try viewerChannel.seal(message),
            routeID: fixture.routeID
        )
        let payload = try outerPayload(.relay(relay))
        await fixture.socket.enqueue(payload)
        try await eventuallyNative {
            await fixture.recorder.snapshot().contains(.message(
                routeID: fixture.routeID,
                message: message
            ))
        }
        await fixture.socket.enqueue(payload)
        try await eventuallyNative {
            await fixture.recorder.snapshot().contains(.routeRejected(
                routeID: fixture.routeID,
                reason: "encrypted-message-rejected"
            ))
        }
    }

    @Test("connection loss re-advertises the lease and reconnects with a fresh bearer socket")
    func reconnectsAndRenewsLease() async throws {
        let first = NativeMockWebSocket()
        let second = NativeMockWebSocket()
        let factory = NativeMockWebSocketFactory(results: [
            .success(first), .success(second),
        ])
        let room = makeNativeRoom()
        let http = NativeMockHTTPTransport { request, _ in
            let advertisedRoom = try ClipLiveShareRoomName(
                rawValue: try #require(request.url?.lastPathComponent)
            )
            return .init(statusCode: 200, data: try encodeJSON(
                ClipLiveShareRoomAdvertisement(
                    room: advertisedRoom,
                    leaseDurationSeconds: 300
                )
            ))
        }
        let sleeper = NativeImmediateSleeper()
        let client = makeNativeClient(
            http: http,
            factory: factory,
            reconnectPolicy: .init(delaysMilliseconds: [17]),
            sleeper: sleeper
        )
        let recorder = await recordNativeEvents(from: client)
        try await client.connect(room: room)

        await first.failReceive()
        try await eventuallyNative {
            let requestCount = await factory.recordedRequests().count
            let events = await recorder.snapshot()
            return requestCount == 2
                && events.contains(.connected(
                    room: room.room,
                    reconnectAttempt: 1
                ))
        }

        #expect(await sleeper.recordedDurations() == [.milliseconds(17)])
        #expect(await http.recordedRequests().count == 1)
        let secondRequest = try #require(await factory.recordedRequests().last)
        #expect(secondRequest.value(forHTTPHeaderField: "Authorization")
            == room.ownerToken.authorizationHeaderValue)
        await client.stop(removeAdvertisement: false)
    }

    @Test("persistent recovery outlives its initial backoff and reconnects after service restore")
    func persistentRecoverySurvivesRetryHorizon() async throws {
        let first = NativeMockWebSocket()
        let restored = NativeMockWebSocket()
        let factory = NativeMockWebSocketFactory(results: [
            .success(first),
            .failure(.connectionFailed),
            .failure(.connectionFailed),
            .success(restored),
        ])
        let room = makeNativeRoom()
        let http = NativeMockHTTPTransport { request, _ in
            let advertisedRoom = try ClipLiveShareRoomName(
                rawValue: try #require(request.url?.lastPathComponent)
            )
            return .init(statusCode: 200, data: try encodeJSON(
                ClipLiveShareRoomAdvertisement(
                    room: advertisedRoom,
                    leaseDurationSeconds: 300
                )
            ))
        }
        let sleeper = NativeImmediateSleeper()
        let client = makeNativeClient(
            http: http,
            factory: factory,
            reconnectPolicy: .init(
                delaysMilliseconds: [0, 1],
                repeatsLastDelay: true
            ),
            sleeper: sleeper
        )
        let recorder = await recordNativeEvents(from: client)
        try await client.connect(room: room)

        await first.failReceive()
        try await eventuallyNative {
            await recorder.snapshot().contains(.connected(
                room: room.room,
                reconnectAttempt: 3
            ))
        }

        #expect(await sleeper.recordedDurations() == [
            .milliseconds(0), .milliseconds(1), .milliseconds(1),
        ])
        #expect(await factory.recordedRequests().count == 4)
        #expect(await http.recordedRequests().count == 3)
        let events = await recorder.snapshot()
        #expect(!events.contains(.disconnected(
            reason: .reconnectExhausted,
            willReconnect: false
        )))
        await client.stop(removeAdvertisement: false)
    }

    @Test("stop invalidates a reconnect suspended in the socket factory")
    func stopInvalidatesDelayedReconnect() async throws {
        let first = NativeMockWebSocket()
        let stale = NativeMockWebSocket()
        let gate = NativeAsyncGate()
        let factory = NativeDelayedWebSocketFactory(steps: [
            .immediate(first), .afterGate(gate, stale),
        ])
        let room = makeNativeRoom()
        let http = NativeMockHTTPTransport { request, _ in
            let advertisedRoom = try ClipLiveShareRoomName(
                rawValue: try #require(request.url?.lastPathComponent)
            )
            return .init(statusCode: 200, data: try encodeJSON(
                ClipLiveShareRoomAdvertisement(
                    room: advertisedRoom,
                    leaseDurationSeconds: 300
                )
            ))
        }
        let client = makeNativeClient(
            http: http,
            factory: factory,
            reconnectPolicy: .init(delaysMilliseconds: [0]),
            sleeper: NativeImmediateSleeper()
        )
        let recorder = await recordNativeEvents(from: client)
        try await client.connect(room: room)
        await first.failReceive()
        try await eventuallyNative { await factory.recordedRequests().count == 2 }

        await client.stop(removeAdvertisement: false)
        await gate.open()
        try await eventuallyNative { await stale.closeCount() == 1 }

        #expect(await stale.resumeCount() == 0)
        #expect(await stale.sentPayloads().isEmpty)
        let events = await recorder.snapshot()
        #expect(!events.contains(.connected(
            room: room.room,
            reconnectAttempt: 1
        )))
    }

    @Test("HTTP and WebSocket allocation limits reject oversized input without poisoning receive")
    func resourceLimits() async throws {
        let oversizedHTTP = NativeMockHTTPTransport { _, _ in
            .init(
                statusCode: 200,
                data: Data(
                    repeating: 0x78,
                    count: ClipLiveShareSignalingResourceLimits.maximumCapabilitiesBytes + 1
                )
            )
        }
        let oversizedClient = makeNativeClient(http: oversizedHTTP)
        await #expect(throws: ClipLiveShareNetworkError.responseTooLarge) {
            try await oversizedClient.fetchCapabilities(from: .localDevelopment)
        }

        let socket = NativeMockWebSocket()
        let client = makeNativeClient(
            factory: NativeMockWebSocketFactory(results: [.success(socket)])
        )
        let room = makeNativeRoom()
        let recorder = await recordNativeEvents(from: client)
        try await client.connect(room: room)
        await socket.enqueue(.data(Data(
            repeating: 0x78,
            count: ClipLiveShareSignalingResourceLimits.maximumMessageBytes + 1
        )))
        await socket.enqueue(try outerPayload(.error(try .init(
            code: "after-limit",
            message: "still connected"
        ))))
        try await eventuallyNative {
            let events = await recorder.snapshot()
            return events.contains(.invalidMessageReceived)
                && events.contains(.serverError(code: "after-limit"))
        }
        #expect(ClipLiveShareSignalingResourceLimits.maximumMessageBytes == 262_144)
        #expect(ClipLiveShareSignalingResourceLimits.maximumDecryptedMessageBytes == 196_400)
        await client.stop(removeAdvertisement: false)
    }

    @Test("negotiated low message ceiling isolates oversized send and receive to one viewer")
    func negotiatedMessageCeiling() async throws {
        let capabilities = try nativeCapabilities(maximumMessageBytes: 512)
        let socket = NativeMockWebSocket()
        let client = makeNativeClient(
            factory: NativeMockWebSocketFactory(results: [.success(socket)])
        )
        let room = makeNativeRoom(capabilities: capabilities)
        let recorder = await recordNativeEvents(from: client)
        try await client.connect(room: room)

        let oversizedRoute = ClipLiveShareRouteID.random()
        let healthyRoute = ClipLiveShareRouteID.random()
        let oversizedViewer = ClipLiveShareViewerIdentity()
        let healthyViewer = ClipLiveShareViewerIdentity()
        for (routeID, viewer) in [
            (oversizedRoute, oversizedViewer),
            (healthyRoute, healthyViewer),
        ] {
            await socket.enqueue(try outerPayload(.routeOpened(.init(
                routeID: routeID,
                viewerKey: viewer.publicKey
            ))))
        }
        try await eventuallyNative {
            let events = await recorder.snapshot()
            return events.contains(.routeOpened(routeID: oversizedRoute))
                && events.contains(.routeOpened(routeID: healthyRoute))
        }

        let sessionID = ClipLiveShareSessionID.random()
        let negotiationID = ClipLiveShareNegotiationID.random()
        let oversizedOffer = ClipLiveShareInnerMessage.offer(
            try ClipLiveShareSessionDescription(
                sessionID: sessionID,
                negotiationID: negotiationID,
                sdp: String(repeating: "x", count: 1_024)
            )
        )
        await #expect(throws: ClipLiveShareNetworkError.messageTooLarge(
            maximumBytes: 512
        )) {
            try await client.send(oversizedOffer, to: oversizedRoute)
        }
        await #expect(throws: ClipLiveShareNetworkError.routeNotFound) {
            try await client.send(oversizedOffer, to: oversizedRoute)
        }

        var healthyChannel = try ClipLiveShareEncryptedChannel(
            viewer: healthyViewer,
            roomPublicKey: room.identity.publicKey,
            room: room.room,
            routeID: healthyRoute
        )
        let healthyMessage = ClipLiveShareInnerMessage.sharingState(.init(
            sessionID: sessionID,
            sharing: true
        ))
        try await client.send(healthyMessage, to: healthyRoute)

        let oversizedInbound = try ClipLiveShareRelayEnvelope(
            routeID: healthyRoute,
            sequence: 1,
            nonce: Data(repeating: 0x11, count: ClipLiveShareV1.nonceByteCount),
            ciphertext: Data(repeating: 0x22, count: 400)
        )
        let oversizedPayload = try outerPayload(.relay(oversizedInbound))
        #expect(oversizedPayload.byteCount > 512)
        await socket.enqueue(oversizedPayload)

        let fromHealthyViewer = forwardedToHost(
            try healthyChannel.seal(healthyMessage),
            routeID: healthyRoute
        )
        await socket.enqueue(try outerPayload(.relay(fromHealthyViewer)))
        try await eventuallyNative {
            let events = await recorder.snapshot()
            return events.contains(.invalidMessageReceived)
                && events.contains(.message(
                    routeID: healthyRoute,
                    message: healthyMessage
                ))
        }

        let sent = try await socket.decodedOuterMessages()
        #expect(sent.contains(.closeRoute(oversizedRoute)))
        #expect(sent.contains { message in
            if case .relay(let envelope) = message {
                return envelope.routeID == healthyRoute
            }
            return false
        })
        #expect(await socket.closeCount() == 0)
        await client.stop(removeAdvertisement: false)
    }

    @Test("hostile invalid relay bursts are bounded and preserve an established route")
    func hostileRelayBurstIsCoalesced() async throws {
        let fixture = try await connectedEncryptedRoute()
        defer { Task { await fixture.client.stop(removeAdvertisement: false) } }

        for _ in 0..<200 {
            let unknown = try ClipLiveShareRelayEnvelope(
                routeID: .random(),
                sequence: 1,
                nonce: Data(repeating: 0x11, count: ClipLiveShareV1.nonceByteCount),
                ciphertext: Data(repeating: 0x22, count: 16)
            )
            await fixture.socket.enqueue(try outerPayload(.relay(unknown)))
            await fixture.socket.enqueue(.text("{malformed"))
            await fixture.socket.enqueue(try outerPayload(.error(try .init(
                code: "hostile",
                message: "ignored duplicate"
            ))))
        }

        var viewerChannel = fixture.viewerChannel
        let healthyMessage = ClipLiveShareInnerMessage.sharingState(.init(
            sessionID: .random(),
            sharing: true
        ))
        await fixture.socket.enqueue(try outerPayload(.relay(forwardedToHost(
            try viewerChannel.seal(healthyMessage),
            routeID: fixture.routeID
        ))))
        try await eventuallyNative {
            await fixture.recorder.snapshot().contains(.message(
                routeID: fixture.routeID,
                message: healthyMessage
            ))
        }

        let events = await fixture.recorder.snapshot()
        #expect(events.filter { $0 == .invalidMessageReceived }.count == 1)
        #expect(events.filter { $0 == .serverError(code: "hostile") }.count == 1)
        #expect(!events.contains { event in
            if case .routeRejected(let routeID, _) = event {
                return routeID != fixture.routeID
            }
            return false
        })
        let closes = try await fixture.socket.decodedOuterMessages().filter {
            if case .closeRoute = $0 { return true }
            return false
        }
        #expect(closes.count <= 16)
        #expect(await fixture.socket.closeCount() == 0)
    }

    @Test("observer overflow terminates explicitly without affecting the host socket")
    func eventBufferOverflow() async throws {
        let socket = NativeMockWebSocket()
        let client = makeNativeClient(
            factory: NativeMockWebSocketFactory(results: [.success(socket)])
        )
        let stream = await client.events()
        let room = makeNativeRoom()
        try await client.connect(room: room)
        let routeID = ClipLiveShareRouteID.random()
        let viewer = ClipLiveShareViewerIdentity()
        await socket.enqueue(try outerPayload(.routeOpened(.init(
            routeID: routeID,
            viewerKey: viewer.publicKey
        ))))
        var viewerChannel = try ClipLiveShareEncryptedChannel(
            viewer: viewer,
            roomPublicKey: room.identity.publicKey,
            room: room.room,
            routeID: routeID
        )
        for _ in 0..<150 {
            let message = ClipLiveShareInnerMessage.sharingState(.init(
                sessionID: .random(),
                sharing: true
            ))
            await socket.enqueue(try outerPayload(.relay(forwardedToHost(
                try viewerChannel.seal(message),
                routeID: routeID
            ))))
        }
        try await eventuallyNative { await socket.receiveCount() >= 151 }

        var observed: [ClipLiveShareSignalingEvent] = []
        for await event in stream { observed.append(event) }
        #expect(observed.count <= 128)
        #expect(observed.last == .eventBufferOverflow)
        await client.stop(removeAdvertisement: false)
    }
}

private struct ConnectedEncryptedRouteFixture {
    let client: ClipLiveShareSignalingClient
    let socket: NativeMockWebSocket
    let recorder: NativeEventRecorder
    let routeID: ClipLiveShareRouteID
    let viewerChannel: ClipLiveShareEncryptedChannel
}

private func connectedEncryptedRoute() async throws -> ConnectedEncryptedRouteFixture {
    let socket = NativeMockWebSocket()
    let client = makeNativeClient(
        factory: NativeMockWebSocketFactory(results: [.success(socket)])
    )
    let room = makeNativeRoom()
    let recorder = await recordNativeEvents(from: client)
    try await client.connect(room: room)
    let routeID = ClipLiveShareRouteID.random()
    let viewer = ClipLiveShareViewerIdentity()
    await socket.enqueue(try outerPayload(.routeOpened(.init(
        routeID: routeID,
        viewerKey: viewer.publicKey
    ))))
    try await eventuallyNative {
        await recorder.snapshot().contains(.routeOpened(routeID: routeID))
    }
    return ConnectedEncryptedRouteFixture(
        client: client,
        socket: socket,
        recorder: recorder,
        routeID: routeID,
        viewerChannel: try ClipLiveShareEncryptedChannel(
            viewer: viewer,
            roomPublicKey: room.identity.publicKey,
            room: room.room,
            routeID: routeID
        )
    )
}

private func makeNativeClient(
    http: any ClipLiveShareHTTPTransport = NativeMockHTTPTransport { _, _ in
        .init(statusCode: 204, data: Data())
    },
    factory: any ClipLiveShareWebSocketFactory = NativeMockWebSocketFactory(results: []),
    reconnectPolicy: ClipLiveShareReconnectPolicy = .disabled,
    sleeper: any ClipLiveShareReconnectSleeper = NativeImmediateSleeper()
) -> ClipLiveShareSignalingClient {
    ClipLiveShareSignalingClient(
        httpTransport: http,
        webSocketFactory: factory,
        reconnectPolicy: reconnectPolicy,
        reconnectSleeper: sleeper
    )
}

private func makeNativeRoom(
    capabilities: ClipLiveShareCapabilities = .v1Default
) -> ClipLiveShareRoomConfiguration {
    ClipLiveShareRoomConfiguration(
        endpoint: .localDevelopment,
        capabilities: capabilities,
        room: try! ClipLiveShareRoomName(rawValue: "CRISP-OTTER-042"),
        ownerToken: try! ClipLiveShareOwnerToken(bytes: Data(repeating: 0x2a, count: 32)),
        identity: ClipLiveShareRoomIdentity()
    )
}

private func nativeCapabilities(
    maximumMessageBytes: Int
) throws -> ClipLiveShareCapabilities {
    let defaults = ClipLiveShareCapabilities.v1Default
    return try ClipLiveShareCapabilities(
        protocolIdentifier: defaults.protocolIdentifier,
        versions: defaults.versions,
        serverVersion: defaults.serverVersion,
        viewerPathTemplate: defaults.viewerPathTemplate,
        hostWebSocketPathTemplate: defaults.hostWebSocketPathTemplate,
        viewerWebSocketPathTemplate: defaults.viewerWebSocketPathTemplate,
        iceServers: defaults.iceServers,
        limits: try .init(
            maximumMessageBytes: maximumMessageBytes,
            maximumPendingViewersPerRoom:
                defaults.limits.maximumPendingViewersPerRoom
        )
    )
}

private func forwardedToHost(
    _ envelope: ClipLiveShareRelayEnvelope,
    routeID: ClipLiveShareRouteID
) -> ClipLiveShareRelayEnvelope {
    try! ClipLiveShareRelayEnvelope(
        routeID: routeID,
        sequence: envelope.sequence,
        nonce: envelope.nonce,
        ciphertext: envelope.ciphertext
    )
}

private func outerPayload(
    _ message: ClipLiveShareOuterMessage
) throws -> ClipLiveShareWebSocketPayload {
    .data(try ClipLiveShareMessageCodec.encodeOuter(message))
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    try JSONEncoder().encode(value)
}

private extension ClipLiveShareWebSocketPayload {
    var byteCount: Int {
        switch self {
        case .text(let value): value.utf8.count
        case .data(let value): value.count
        }
    }
}

private actor NativeEventRecorder {
    private var events: [ClipLiveShareSignalingEvent] = []
    func append(_ event: ClipLiveShareSignalingEvent) { events.append(event) }
    func snapshot() -> [ClipLiveShareSignalingEvent] { events }
}

private func recordNativeEvents(
    from client: ClipLiveShareSignalingClient
) async -> NativeEventRecorder {
    let recorder = NativeEventRecorder()
    let stream = await client.events()
    Task {
        for await event in stream { await recorder.append(event) }
    }
    return recorder
}

private func eventuallyNative(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<400 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for native signaling state")
}

private enum NativeMockFailure: Error, Sendable {
    case connectionFailed
}

private actor NativeMockHTTPTransport: ClipLiveShareHTTPTransport {
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

private actor NativeMockWebSocket: ClipLiveShareWebSocketConnection {
    private var resumes = 0
    private var receives = 0
    private var sends: [ClipLiveShareWebSocketPayload] = []
    private var closes = 0
    private var sendGates: [NativeAsyncGate]
    private var queued: [Result<ClipLiveShareWebSocketPayload, NativeMockFailure>] = []
    private var waiter: CheckedContinuation<ClipLiveShareWebSocketPayload, any Error>?

    init(sendGates: [NativeAsyncGate] = []) {
        self.sendGates = sendGates
    }

    func resume() { resumes += 1 }

    func send(_ payload: ClipLiveShareWebSocketPayload) async throws {
        sends.append(payload)
        if !sendGates.isEmpty {
            let gate = sendGates.removeFirst()
            await gate.wait()
        }
    }

    func receive() async throws -> ClipLiveShareWebSocketPayload {
        receives += 1
        if !queued.isEmpty { return try queued.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        closes += 1
        waiter?.resume(throwing: NativeMockFailure.connectionFailed)
        waiter = nil
    }

    func enqueue(_ payload: ClipLiveShareWebSocketPayload) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: payload)
        } else {
            queued.append(.success(payload))
        }
    }

    func failReceive() {
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: NativeMockFailure.connectionFailed)
        } else {
            queued.append(.failure(.connectionFailed))
        }
    }

    func resumeCount() -> Int { resumes }
    func receiveCount() -> Int { receives }
    func sentPayloads() -> [ClipLiveShareWebSocketPayload] { sends }
    func closeCount() -> Int { closes }

    func decodedOuterMessages() throws -> [ClipLiveShareOuterMessage] {
        try sends.map { payload in
            let data: Data = switch payload {
            case .text(let text): Data(text.utf8)
            case .data(let data): data
            }
            return try ClipLiveShareMessageCodec.decodeOuter(data)
        }
    }
}

private actor NativeMockWebSocketFactory: ClipLiveShareWebSocketFactory {
    private var results: [Result<NativeMockWebSocket, NativeMockFailure>]
    private var requests: [URLRequest] = []

    init(results: [Result<NativeMockWebSocket, NativeMockFailure>]) {
        self.results = results
    }

    func makeConnection(
        for request: URLRequest
    ) throws -> any ClipLiveShareWebSocketConnection {
        requests.append(request)
        guard !results.isEmpty else { throw NativeMockFailure.connectionFailed }
        return try results.removeFirst().get()
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private enum NativeDelayedWebSocketFactoryStep: Sendable {
    case immediate(NativeMockWebSocket)
    case afterGate(NativeAsyncGate, NativeMockWebSocket)
}

private actor NativeDelayedWebSocketFactory: ClipLiveShareWebSocketFactory {
    private var steps: [NativeDelayedWebSocketFactoryStep]
    private var requests: [URLRequest] = []

    init(steps: [NativeDelayedWebSocketFactoryStep]) { self.steps = steps }

    func makeConnection(
        for request: URLRequest
    ) async throws -> any ClipLiveShareWebSocketConnection {
        requests.append(request)
        guard !steps.isEmpty else { throw NativeMockFailure.connectionFailed }
        switch steps.removeFirst() {
        case .immediate(let socket):
            return socket
        case .afterGate(let gate, let socket):
            await gate.wait()
            return socket
        }
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private actor NativeAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor NativeImmediateSleeper: ClipLiveShareReconnectSleeper {
    private var durations: [Duration] = []
    func sleep(for duration: Duration) { durations.append(duration) }
    func recordedDurations() -> [Duration] { durations }
}
