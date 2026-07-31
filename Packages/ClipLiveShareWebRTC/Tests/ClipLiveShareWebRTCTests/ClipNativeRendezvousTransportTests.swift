import Foundation
import Testing
@testable import ClipLiveShareWebRTC

@Suite("Clip native rendezvous transport")
struct ClipNativeRendezvousTransportTests {
    @Test("HTTP discovery and ownership lifecycle use strict primitive boundaries")
    func httpLifecycle() async throws {
        let fixture = try RendezvousTestFixture()
        let http = RendezvousTestHTTPTransport { request, index in
            switch index {
            case 0:
                #expect(request.httpMethod == "GET")
                #expect(request.url?.path == "/.well-known/clip-native-rendezvous")
                return .init(statusCode: 200, data: fixture.capabilitiesData)
            case 1, 2:
                #expect(request.httpMethod == "PUT")
                #expect(request.url?.path == fixture.rendezvousPath)
                let body = try #require(request.httpBody)
                let object = try #require(try JSONSerialization.jsonObject(
                    with: body
                ) as? [String: String])
                #expect(object == ["ownerToken": fixture.owner.ownerTokenString])
                return .init(
                    statusCode: index == 1 ? 201 : 200,
                    data: try rendezvousTestJSON([
                        "rendezvousId": fixture.target.rendezvousIDString,
                        "leaseDurationSeconds": 300,
                    ])
                )
            case 3:
                #expect(request.httpMethod == "GET")
                return .init(statusCode: 200, data: try rendezvousTestJSON([
                    "rendezvousId": fixture.target.rendezvousIDString,
                    "state": "active",
                ]))
            case 4:
                #expect(request.httpMethod == "PUT")
                #expect(request.url?.path == fixture.rendezvousPath + "/session")
                #expect(request.value(forHTTPHeaderField: "Authorization")
                    == fixture.owner.authorizationHeaderValue)
                let body = try #require(request.httpBody)
                let object = try #require(try JSONSerialization.jsonObject(
                    with: body
                ) as? [String: String])
                #expect(object == [
                    "descriptor": ClipNativeRendezvousBase64URL.encode(Data("signed".utf8)),
                ])
                return .init(statusCode: 204, data: Data())
            case 5, 6:
                #expect(request.httpMethod == "DELETE")
                #expect(request.value(forHTTPHeaderField: "Authorization")
                    == fixture.owner.authorizationHeaderValue)
                return .init(statusCode: 204, data: Data())
            default:
                Issue.record("Unexpected HTTP request \(index): \(request)")
                return .init(statusCode: 500, data: Data())
            }
        }
        let client = ClipNativeRendezvousHTTPClient(transport: http)

        let capabilities = try await client.discover(at: fixture.endpoint)
        #expect(capabilities == fixture.capabilities)
        #expect(capabilities.iceServers == [
            try .init(urls: ["stun:stun.l.google.com:19302"])
        ])
        #expect(capabilities.webRTCICEServers == [
            .init(urlStrings: ["stun:stun.l.google.com:19302"])
        ])
        #expect(try capabilities.rendezvousURL(for: fixture.target).path
            == fixture.rendezvousPath)
        #expect(try capabilities.ownerWebSocketURL(for: fixture.target).scheme == "ws")
        #expect(try capabilities.candidateWebSocketURL(for: fixture.target).scheme == "ws")

        let claimed = try await client.claim(
            fixture.owner,
            capabilities: capabilities
        )
        #expect(claimed.rendezvousID == fixture.target.rendezvousID)
        #expect(claimed.leaseDurationSeconds == 300)
        _ = try await client.renew(fixture.owner, capabilities: capabilities)
        #expect(try await client.status(
            fixture.target,
            capabilities: capabilities
        ).state == .active)
        try await client.publishSession(
            descriptor: Data("signed".utf8),
            for: fixture.owner,
            capabilities: capabilities
        )
        try await client.stopSession(for: fixture.owner, capabilities: capabilities)
        try await client.delete(fixture.owner, capabilities: capabilities)
        #expect(await http.recordedRequests().count == 7)
    }

    @Test("strict discovery rejects extensions and malformed canonical values")
    func strictValidation() async throws {
        let fixture = try RendezvousTestFixture()
        var object = try #require(try JSONSerialization.jsonObject(
            with: fixture.capabilitiesData
        ) as? [String: Any])
        object["unexpected"] = true
        let responseData = try rendezvousTestJSON(object)
        let http = RendezvousTestHTTPTransport { _, _ in
            .init(statusCode: 200, data: responseData)
        }
        let client = ClipNativeRendezvousHTTPClient(transport: http)
        await #expect(throws: ClipNativeRendezvousError.invalidResponse) {
            try await client.discover(at: fixture.endpoint)
        }

        var invalidICE = try #require(try JSONSerialization.jsonObject(
            with: fixture.capabilitiesData
        ) as? [String: Any])
        invalidICE["iceServers"] = [[
            "urls": ["https://not-an-ice-server.example"],
        ]]
        let invalidICEData = try rendezvousTestJSON(invalidICE)
        let invalidICEHTTP = RendezvousTestHTTPTransport { _, _ in
            .init(statusCode: 200, data: invalidICEData)
        }
        let invalidICEClient = ClipNativeRendezvousHTTPClient(
            transport: invalidICEHTTP
        )
        await #expect(throws: ClipNativeRendezvousError.invalidCapabilities) {
            try await invalidICEClient.discover(at: fixture.endpoint)
        }

        var extendedICE = try #require(try JSONSerialization.jsonObject(
            with: fixture.capabilitiesData
        ) as? [String: Any])
        extendedICE["iceServers"] = [[
            "urls": ["stun:stun.example.test:3478"],
            "secretExtension": true,
        ]]
        let extendedICEData = try rendezvousTestJSON(extendedICE)
        let extendedICEHTTP = RendezvousTestHTTPTransport { _, _ in
            .init(statusCode: 200, data: extendedICEData)
        }
        let extendedICEClient = ClipNativeRendezvousHTTPClient(
            transport: extendedICEHTTP
        )
        await #expect(throws: ClipNativeRendezvousError.invalidCapabilities) {
            try await extendedICEClient.discover(at: fixture.endpoint)
        }

        var legacyCapabilities = try #require(try JSONSerialization.jsonObject(
            with: fixture.capabilitiesData
        ) as? [String: Any])
        legacyCapabilities["apiVersion"] = 1
        legacyCapabilities["messageVersion"] = 2
        legacyCapabilities["hostWebSocketPathTemplate"] =
            "/api/native/v1/rendezvous/{rendezvous}/host"
        legacyCapabilities["viewerWebSocketPathTemplate"] =
            "/api/native/v1/rendezvous/{rendezvous}/viewer"
        legacyCapabilities.removeValue(forKey: "ownerWebSocketPathTemplate")
        legacyCapabilities.removeValue(forKey: "candidateWebSocketPathTemplate")
        let legacyCapabilitiesData = try rendezvousTestJSON(legacyCapabilities)
        let legacyHTTP = RendezvousTestHTTPTransport { _, _ in
            .init(statusCode: 200, data: legacyCapabilitiesData)
        }
        let legacyClient = ClipNativeRendezvousHTTPClient(transport: legacyHTTP)
        await #expect(throws: ClipNativeRendezvousError.invalidResponse) {
            try await legacyClient.discover(at: fixture.endpoint)
        }

        var legacyVersions = try #require(try JSONSerialization.jsonObject(
            with: fixture.capabilitiesData
        ) as? [String: Any])
        legacyVersions["apiVersion"] = 1
        legacyVersions["messageVersion"] = 2
        let legacyVersionsData = try rendezvousTestJSON(legacyVersions)
        let legacyVersionsHTTP = RendezvousTestHTTPTransport { _, _ in
            .init(statusCode: 200, data: legacyVersionsData)
        }
        let legacyVersionsClient = ClipNativeRendezvousHTTPClient(
            transport: legacyVersionsHTTP
        )
        await #expect(throws: ClipNativeRendezvousError.invalidCapabilities) {
            try await legacyVersionsClient.discover(at: fixture.endpoint)
        }

        #expect(throws: ClipNativeRendezvousError.invalidMessage) {
            try ClipNativeRendezvousWireCodec.decode(
                .text("""
                {"type":"native-host-unavailable","version":2}
                """),
                role: .candidate,
                capabilities: fixture.capabilities
            )
        }
        #expect(throws: ClipNativeRendezvousError.invalidMessage) {
            try ClipNativeRendezvousWireCodec.decode(
                .text("""
                {"type":"native-owner-unavailable","version":2}
                """),
                role: .candidate,
                capabilities: fixture.capabilities
            )
        }

        #expect(ClipNativeRendezvousBase64URL.decodeCanonical(
            "YQ==",
            minimumBytes: 1,
            maximumBytes: 4
        ) == nil)
        #expect(ClipNativeRendezvousBase64URL.decodeCanonical(
            "YQ",
            minimumBytes: 1,
            maximumBytes: 4
        ) == Data("a".utf8))
        #expect(ClipNativeRendezvousBase64URL.decodeCanonical(
            "Y+Q",
            minimumBytes: 1,
            maximumBytes: 4
        ) == nil)
        #expect(throws: ClipNativeRendezvousError.invalidRendezvousID) {
            try ClipNativeRendezvousTarget(
                endpoint: fixture.endpoint,
                rendezvousID: Data(repeating: 0, count: 31)
            )
        }
        #expect(throws: ClipNativeRendezvousError.invalidEndpoint) {
            try ClipNativeRendezvousTarget(
                endpoint: URL(string: "https://example.test/path")!,
                rendezvousID: fixture.target.rendezvousID
            )
        }
    }

    @Test("owner attaches preparing, retries activation, rotates, stops, and deletes")
    func ownerLifecycle() async throws {
        let fixture = try RendezvousTestFixture()
        let socket = RendezvousTestWebSocket()
        let factory = RendezvousTestWebSocketFactory(results: [.success(socket)])
        let sleeper = RendezvousTestSleeper()
        let http = RendezvousTestHTTPTransport { request, index in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/.well-known/clip-native-rendezvous"):
                return .init(statusCode: 200, data: fixture.capabilitiesData)
            case ("PUT", fixture.rendezvousPath):
                return .init(statusCode: 201, data: fixture.leaseData)
            case ("PUT", fixture.rendezvousPath + "/session"):
                let sessionRequestIndex = index - 2
                return .init(
                    statusCode: sessionRequestIndex == 0 ? 409 : 204,
                    data: Data()
                )
            case ("DELETE", _):
                return .init(statusCode: 204, data: Data())
            default:
                Issue.record("Unexpected request: \(request)")
                return .init(statusCode: 500, data: Data())
            }
        }
        let owner = ClipNativeRendezvousOwnerTransport(
            httpTransport: http,
            webSocketFactory: factory,
            reconnectPolicy: .disabled,
            reconnectSleeper: sleeper,
            attachmentRetryDelaysMilliseconds: [7]
        )
        let recorder = await RendezvousTestEventRecorder.record(owner.events())

        _ = try await owner.attachOwner(fixture.owner)
        #expect(await socket.resumeCount() == 1)
        let websocketRequest = try #require(await factory.recordedRequests().first)
        #expect(websocketRequest.url?.path == fixture.rendezvousPath + "/owner")
        #expect(websocketRequest.value(forHTTPHeaderField: "Authorization")
            == fixture.owner.authorizationHeaderValue)

        let firstDescriptor = Data("descriptor-one".utf8)
        try await owner.publishSession(descriptor: firstDescriptor)
        #expect(await sleeper.recordedDurations() == [.milliseconds(7)])

        let routeID = fixture.routeID
        await socket.enqueue(try fixture.wire(.init(
            type: .routeOpened,
            routeID: routeID
        )))
        try await rendezvousEventually {
            await recorder.snapshot().contains(.routeOpened(
                routeID: routeID,
                descriptor: nil
            ))
        }

        try await owner.publishSession(descriptor: Data("descriptor-two".utf8))
        try await rendezvousEventually {
            await recorder.snapshot().contains(.routeClosed(
                routeID: routeID,
                reason: "session-rotated"
            ))
        }
        try await owner.stopSharing()
        await owner.teardown(removeRendezvous: true)

        let requests = await http.recordedRequests()
        #expect(requests.filter {
            $0.httpMethod == "PUT" && $0.url?.path == fixture.rendezvousPath + "/session"
        }.count == 3)
        #expect(requests.contains {
            $0.httpMethod == "DELETE" && $0.url?.path == fixture.rendezvousPath
        })
        #expect(await socket.closeCount() == 1)
        try await rendezvousEventually {
            await recorder.snapshot().last == .stopped
        }
        let events = await recorder.snapshot()
        #expect(events.contains(.ownerPreparing(reconnectAttempt: 0)))
        #expect(events.filter { $0 == .ownerActive }.count == 2)
        #expect(events.last == .stopped)
    }

    @Test("ordinary teardown preserves a persistent claim racing attachment")
    func teardownPreservesClaim() async throws {
        let fixture = try RendezvousTestFixture()
        let claimGate = RendezvousTestGate()
        let http = RendezvousTestHTTPTransport { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/.well-known/clip-native-rendezvous"):
                return .init(statusCode: 200, data: fixture.capabilitiesData)
            case ("PUT", fixture.rendezvousPath):
                await claimGate.wait()
                return .init(statusCode: 201, data: fixture.leaseData)
            default:
                Issue.record("Persistent claim must not be deleted: \(request)")
                return .init(statusCode: 500, data: Data())
            }
        }
        let factory = RendezvousTestWebSocketFactory(results: [])
        let owner = ClipNativeRendezvousOwnerTransport(
            httpTransport: http,
            webSocketFactory: factory,
            reconnectPolicy: .disabled,
            reconnectSleeper: RendezvousTestSleeper()
        )
        let attachment = Task { try await owner.attachOwner(fixture.owner) }
        try await rendezvousEventually { await http.recordedRequests().count == 2 }

        await owner.teardown(removeRendezvous: false)
        await claimGate.open()
        await #expect(throws: ClipNativeRendezvousError.operationSuperseded) {
            try await attachment.value
        }
        #expect(await http.recordedRequests().count == 2)
        #expect(await factory.recordedRequests().isEmpty)
    }

    @Test("owner relays opaque messages in strict per-route order")
    func ownerOrderedRelay() async throws {
        let fixture = try RendezvousTestFixture()
        let firstGate = RendezvousTestGate()
        let secondGate = RendezvousTestGate()
        let socket = RendezvousTestWebSocket(sendGates: [firstGate, secondGate])
        let owner = ClipNativeRendezvousOwnerTransport(
            httpTransport: fixture.activeOwnerHTTP,
            webSocketFactory: RendezvousTestWebSocketFactory(results: [.success(socket)]),
            reconnectPolicy: .disabled,
            reconnectSleeper: RendezvousTestSleeper()
        )
        let recorder = await RendezvousTestEventRecorder.record(owner.events())
        _ = try await owner.attachOwner(fixture.owner)

        await socket.enqueue(try fixture.wire(.init(
            type: .routeOpened,
            routeID: fixture.routeID
        )))
        try await rendezvousEventually {
            await recorder.snapshot().contains(.routeOpened(
                routeID: fixture.routeID,
                descriptor: nil
            ))
        }

        let first = Task { try await owner.send(Data("one".utf8), to: fixture.routeID) }
        try await rendezvousEventually { await socket.sentPayloads().count == 1 }
        let second = Task { try await owner.send(Data("two".utf8), to: fixture.routeID) }
        await firstGate.open()
        try await rendezvousEventually { await socket.sentPayloads().count == 2 }
        await secondGate.open()
        try await first.value
        try await second.value

        let sent = try await socket.decodedMessages()
        #expect(sent.map(\.sequence) == [1, 2])
        #expect(sent.map(\.routeID) == [fixture.routeID, fixture.routeID])
        #expect(sent.compactMap(\.payload).map {
            ClipNativeRendezvousBase64URL.decodeCanonical(
                $0,
                minimumBytes: 1,
                maximumBytes: 32
            )
        } == [Data("one".utf8), Data("two".utf8)])

        await socket.enqueue(try fixture.wire(.init(
            type: .relay,
            routeID: fixture.routeID,
            sequence: 1,
            payload: ClipNativeRendezvousBase64URL.encode(Data("answer".utf8))
        )))
        try await rendezvousEventually {
            await recorder.snapshot().contains(.relay(
                routeID: fixture.routeID,
                payload: Data("answer".utf8),
                sequence: 1
            ))
        }
        await owner.closeRoute(fixture.routeID, reason: "complete")
        let closed = try #require(try await socket.decodedMessages().last)
        #expect(closed.type == .closeRoute)
        #expect(closed.routeID == fixture.routeID)
        await #expect(throws: ClipNativeRendezvousError.routeNotFound) {
            try await owner.send(Data("late".utf8), to: fixture.routeID)
        }
        await owner.teardown()
    }

    @Test("candidate requires active state and relays through its implicit route")
    func candidateActiveGateAndRelay() async throws {
        let fixture = try RendezvousTestFixture()
        let inactiveFactory = RendezvousTestWebSocketFactory(results: [])
        let inactive = ClipNativeRendezvousCandidateTransport(
            httpTransport: fixture.candidateHTTP(state: .preparing),
            webSocketFactory: inactiveFactory,
            reconnectPolicy: .disabled,
            reconnectSleeper: RendezvousTestSleeper()
        )
        await #expect(throws: ClipNativeRendezvousError.rendezvousNotLive) {
            try await inactive.attachCandidate(fixture.target)
        }
        #expect(await inactiveFactory.recordedRequests().isEmpty)

        let socket = RendezvousTestWebSocket()
        let factory = RendezvousTestWebSocketFactory(results: [.success(socket)])
        let candidate = ClipNativeRendezvousCandidateTransport(
            httpTransport: fixture.candidateHTTP(state: .active),
            webSocketFactory: factory,
            reconnectPolicy: .disabled,
            reconnectSleeper: RendezvousTestSleeper()
        )
        let recorder = await RendezvousTestEventRecorder.record(candidate.events())
        _ = try await candidate.attachCandidate(fixture.target)
        #expect((try #require(await factory.recordedRequests().first)).url?.path
            == fixture.rendezvousPath + "/candidate")

        let descriptor = Data("signed-session".utf8)
        await socket.enqueue(try fixture.wire(.init(
            type: .routeOpened,
            routeID: fixture.routeID,
            payload: ClipNativeRendezvousBase64URL.encode(descriptor)
        )))
        try await rendezvousEventually {
            await recorder.snapshot().contains(.routeOpened(
                routeID: fixture.routeID,
                descriptor: descriptor
            ))
        }

        try await candidate.send(Data("offer".utf8))
        let outbound = try #require(try await socket.decodedMessages().first)
        #expect(outbound.type == .relay)
        #expect(outbound.routeID == nil)
        #expect(outbound.sequence == 1)

        await socket.enqueue(try fixture.wire(.init(
            type: .relay,
            routeID: fixture.routeID,
            sequence: 1,
            payload: ClipNativeRendezvousBase64URL.encode(Data("answer".utf8))
        )))
        try await rendezvousEventually {
            await recorder.snapshot().contains(.relay(
                routeID: fixture.routeID,
                payload: Data("answer".utf8),
                sequence: 1
            ))
        }

        await candidate.closeRoute(reason: "peer-connected")
        let close = try #require(try await socket.decodedMessages().last)
        #expect(close.type == .closeRoute)
        #expect(close.routeID == nil)
        #expect(close.reason == "peer-connected")
        #expect(await socket.closeCount() == 1)
        await candidate.teardown()
    }

    @Test("owner reconnect reclaims, republishes, and exhausts its bounded policy")
    func ownerReconnectAndExhaustion() async throws {
        let fixture = try RendezvousTestFixture()
        let first = RendezvousTestWebSocket()
        let restored = RendezvousTestWebSocket()
        let factory = RendezvousTestWebSocketFactory(results: [
            .success(first),
            .success(restored),
            .failure(.connectionFailed),
        ])
        let sleeper = RendezvousTestSleeper()
        let owner = ClipNativeRendezvousOwnerTransport(
            httpTransport: fixture.activeOwnerHTTP,
            webSocketFactory: factory,
            reconnectPolicy: .init(delaysMilliseconds: [3]),
            reconnectSleeper: sleeper
        )
        let recorder = await RendezvousTestEventRecorder.record(owner.events())
        _ = try await owner.attachOwner(fixture.owner)
        try await owner.publishSession(descriptor: Data("current".utf8))

        await first.failReceive()
        try await rendezvousEventually {
            let events = await recorder.snapshot()
            return await restored.resumeCount() == 1
                && events.contains(.connected(role: .owner, reconnectAttempt: 1))
                && events.filter { $0 == .ownerActive }.count == 2
        }

        await restored.failReceive()
        try await rendezvousEventually {
            await recorder.snapshot().contains(.disconnected(
                reason: .reconnectExhausted,
                willReconnect: false
            ))
        }
        #expect(await sleeper.recordedDurations() == [
            .milliseconds(3), .milliseconds(3),
        ])
        #expect(await factory.recordedRequests().count == 3)
        await owner.teardown()
    }

    @Test("invalid receive bursts are coalesced and do not poison valid traffic")
    func invalidReceiveCoalescing() async throws {
        let fixture = try RendezvousTestFixture()
        let socket = RendezvousTestWebSocket()
        let owner = ClipNativeRendezvousOwnerTransport(
            httpTransport: fixture.activeOwnerHTTP,
            webSocketFactory: RendezvousTestWebSocketFactory(results: [.success(socket)]),
            reconnectPolicy: .disabled,
            reconnectSleeper: RendezvousTestSleeper()
        )
        let recorder = await RendezvousTestEventRecorder.record(owner.events())
        _ = try await owner.attachOwner(fixture.owner)

        await socket.enqueue(.text("{malformed"))
        await socket.enqueue(.data(Data(
            repeating: 0x78,
            count: ClipNativeRendezvousLimits.maximumMessageBytes + 1
        )))
        await socket.enqueue(try fixture.wire(.init(
            type: .error,
            code: "still-connected",
            message: "valid after invalid"
        )))
        try await rendezvousEventually {
            let events = await recorder.snapshot()
            return events.contains(.invalidMessageReceived)
                && events.contains(.serverError(code: "still-connected"))
        }
        let events = await recorder.snapshot()
        #expect(events.filter { $0 == .invalidMessageReceived }.count == 1)
        #expect(await socket.closeCount() == 0)
        await owner.teardown()
    }
}

private struct RendezvousTestFixture: Sendable {
    let endpoint = URL(string: "http://127.0.0.1:8080")!
    let target: ClipNativeRendezvousTarget
    let owner: ClipNativeRendezvousOwner
    let capabilities: ClipNativeRendezvousCapabilities
    let capabilitiesData: Data
    let leaseData: Data
    let rendezvousPath: String
    let routeID: String

    init() throws {
        target = try ClipNativeRendezvousTarget(
            endpoint: endpoint,
            rendezvousID: Data(repeating: 0x11, count: 32)
        )
        owner = try ClipNativeRendezvousOwner(
            target: target,
            ownerToken: Data(repeating: 0x22, count: 32)
        )
        capabilities = try ClipNativeRendezvousCapabilities(serverVersion: "test")
        rendezvousPath = "/api/native/v3/rendezvous/\(target.rendezvousIDString)"
        routeID = ClipNativeRendezvousBase64URL.encode(
            Data(repeating: 0x33, count: 16)
        )
        capabilitiesData = try rendezvousTestJSON([
            "protocol": "clip-native-rendezvous",
            "apiVersion": 3,
            "messageVersion": 3,
            "serverVersion": "test",
            "rendezvousPathTemplate": "/api/native/v3/rendezvous/{rendezvous}",
            "ownerWebSocketPathTemplate": "/api/native/v3/rendezvous/{rendezvous}/owner",
            "candidateWebSocketPathTemplate": "/api/native/v3/rendezvous/{rendezvous}/candidate",
            "maximumMessageBytes": 262_144,
            "maximumDescriptorBytes": 16_384,
            "maximumOpaquePayloadBytes": 196_000,
            "maximumPendingRoutes": 8,
            "maximumRendezvous": 1_024,
            "iceServers": [
                ["urls": ["stun:stun.l.google.com:19302"]]
            ],
        ])
        leaseData = try rendezvousTestJSON([
            "rendezvousId": target.rendezvousIDString,
            "leaseDurationSeconds": 300,
        ])
    }

    var activeOwnerHTTP: RendezvousTestHTTPTransport {
        RendezvousTestHTTPTransport { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/.well-known/clip-native-rendezvous"):
                return .init(statusCode: 200, data: capabilitiesData)
            case ("PUT", rendezvousPath):
                return .init(statusCode: 200, data: leaseData)
            case ("PUT", rendezvousPath + "/session"):
                return .init(statusCode: 204, data: Data())
            case ("DELETE", _):
                return .init(statusCode: 204, data: Data())
            default:
                Issue.record("Unexpected owner HTTP request: \(request)")
                return .init(statusCode: 500, data: Data())
            }
        }
    }

    func candidateHTTP(
        state: ClipNativeRendezvousState
    ) -> RendezvousTestHTTPTransport {
        RendezvousTestHTTPTransport { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/.well-known/clip-native-rendezvous"):
                return .init(statusCode: 200, data: capabilitiesData)
            case ("GET", rendezvousPath):
                return .init(statusCode: 200, data: try rendezvousTestJSON([
                    "rendezvousId": target.rendezvousIDString,
                    "state": state.rawValue,
                ]))
            default:
                Issue.record("Unexpected candidate HTTP request: \(request)")
                return .init(statusCode: 500, data: Data())
            }
        }
    }

    func wire(
        _ message: ClipNativeRendezvousWireMessage
    ) throws -> ClipLiveShareWebSocketPayload {
        try ClipNativeRendezvousWireCodec.encode(
            message,
            maximumBytes: capabilities.maximumMessageBytes
        )
    }
}

private enum RendezvousTestFailure: Error, Sendable {
    case connectionFailed
}

private actor RendezvousTestHTTPTransport: ClipLiveShareHTTPTransport {
    typealias Handler = @Sendable (
        URLRequest,
        Int
    ) async throws -> ClipLiveShareHTTPResult

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

    func recordedRequests() -> [URLRequest] { requests }
}

private actor RendezvousTestWebSocket: ClipLiveShareWebSocketConnection {
    private var resumes = 0
    private var sends: [ClipLiveShareWebSocketPayload] = []
    private var closes = 0
    private var sendGates: [RendezvousTestGate]
    private var queued: [Result<ClipLiveShareWebSocketPayload, RendezvousTestFailure>] = []
    private var waiter: CheckedContinuation<ClipLiveShareWebSocketPayload, any Error>?

    init(sendGates: [RendezvousTestGate] = []) {
        self.sendGates = sendGates
    }

    func resume() { resumes += 1 }

    func send(_ payload: ClipLiveShareWebSocketPayload) async throws {
        sends.append(payload)
        if !sendGates.isEmpty {
            await sendGates.removeFirst().wait()
        }
    }

    func receive() async throws -> ClipLiveShareWebSocketPayload {
        if !queued.isEmpty { return try queued.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        closes += 1
        waiter?.resume(throwing: RendezvousTestFailure.connectionFailed)
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
            waiter.resume(throwing: RendezvousTestFailure.connectionFailed)
        } else {
            queued.append(.failure(.connectionFailed))
        }
    }

    func resumeCount() -> Int { resumes }
    func sentPayloads() -> [ClipLiveShareWebSocketPayload] { sends }
    func closeCount() -> Int { closes }

    func decodedMessages() throws -> [ClipNativeRendezvousWireMessage] {
        try sends.map { payload in
            let data: Data = switch payload {
            case .text(let text): Data(text.utf8)
            case .data(let data): data
            }
            return try JSONDecoder().decode(
                ClipNativeRendezvousWireMessage.self,
                from: data
            )
        }
    }
}

private actor RendezvousTestWebSocketFactory: ClipLiveShareWebSocketFactory {
    private var results: [
        Result<RendezvousTestWebSocket, RendezvousTestFailure>
    ]
    private var requests: [URLRequest] = []

    init(results: [Result<RendezvousTestWebSocket, RendezvousTestFailure>]) {
        self.results = results
    }

    func makeConnection(
        for request: URLRequest
    ) throws -> any ClipLiveShareWebSocketConnection {
        requests.append(request)
        guard !results.isEmpty else { throw RendezvousTestFailure.connectionFailed }
        return try results.removeFirst().get()
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private actor RendezvousTestSleeper: ClipLiveShareReconnectSleeper {
    private var durations: [Duration] = []
    func sleep(for duration: Duration) { durations.append(duration) }
    func recordedDurations() -> [Duration] { durations }
}

private actor RendezvousTestGate {
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

private actor RendezvousTestEventRecorder {
    private var events: [ClipNativeRendezvousEvent] = []

    static func record(
        _ stream: AsyncStream<ClipNativeRendezvousEvent>
    ) -> RendezvousTestEventRecorder {
        let recorder = RendezvousTestEventRecorder()
        Task {
            for await event in stream { await recorder.append(event) }
        }
        return recorder
    }

    func append(_ event: ClipNativeRendezvousEvent) { events.append(event) }
    func snapshot() -> [ClipNativeRendezvousEvent] { events }
}

private func rendezvousTestJSON(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func rendezvousEventually(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<400 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for native rendezvous state")
}
