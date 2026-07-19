import ClipLiveShare
import Foundation
import Testing
@testable import ClipLiveShareWebRTC

/// Exercises the production transports against the unmodified GoPeep v1 Go server.
///
/// The ordinary package suite leaves this test dormant because it owns an external
/// process. `scripts/run-gopeep-interop-acceptance.sh` builds that server from the
/// sibling GoPeep checkout, starts it on loopback, and supplies the opt-in variables.
@Suite("Local GoPeep server interoperability", .serialized)
struct LocalGoPeepServerInteropTests {
    @Test("real server reserves, authenticates, and routes signaling frames")
    func routesProductionProtocol() async throws {
        guard ProcessInfo.processInfo.environment["CLIP_RUN_GOPEEP_INTEROP"] == "1" else {
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let signalingURL = try #require(
            environment["CLIP_GOPEEP_INTEROP_SIGNAL_URL"].flatMap(URL.init(string:))
        )
        let server = try GoPeepV1ServerConfiguration(
            signalingServerURL: signalingURL,
            iceServers: []
        )
        let sharer = GoPeepV1SignalingClient(
            server: server,
            reconnectPolicy: .disabled
        )
        let events = await LocalInteropEventRecorder.record(client: sharer)
        defer {
            Task { await sharer.stop() }
        }

        let reservation = try await sharer.reserveRoom()
        #expect(!reservation.secret.isEmpty)
        #expect(reservation.room.rawValue.split(separator: "-").count == 3)

        let impostor = try await URLSessionGoPeepV1WebSocketFactory().makeConnection(
            for: server.signalingURL(for: reservation.room)
        )
        try await impostor.resume()
        try await impostor.send(message: GoPeepV1Message(
            type: .join,
            role: .sharer,
            secret: "not-the-reservation-secret"
        ))
        let rejectedImpostor = try await impostor.receiveMessage()
        #expect(rejectedImpostor.type == .error)
        #expect(rejectedImpostor.errorMessage == "Invalid room secret")
        await impostor.close()

        let initialPassword = "clip-interop-initial"
        try await sharer.connect(room: GoPeepV1RoomConfiguration(
            reservation: reservation,
            password: initialPassword
        ))
        try await events.waitForMessage(type: .joined) { message in
            message.role == .sharer && message.room == reservation.room.rawValue
        }

        let viewerPage = try await URLSession.shared.data(from: server.viewerURL(for: reservation.room))
        let viewerResponse = try #require(viewerPage.1 as? HTTPURLResponse)
        let viewerHTML = String(decoding: viewerPage.0, as: UTF8.self)
        #expect(viewerResponse.statusCode == 200)
        #expect(viewerHTML.contains("new RTCPeerConnection"))
        #expect(viewerHTML.contains("gopeep-control"))

        let viewer = try await URLSessionGoPeepV1WebSocketFactory().makeConnection(
            for: server.signalingURL(for: reservation.room)
        )
        try await viewer.resume()
        defer {
            Task { await viewer.close() }
        }

        try await viewer.send(message: GoPeepV1Message(type: .join, role: .viewer))
        #expect(try await viewer.receiveMessage().type == .passwordRequired)

        try await viewer.send(message: GoPeepV1Message(
            type: .join,
            role: .viewer,
            password: "incorrect"
        ))
        #expect(try await viewer.receiveMessage().type == .passwordInvalid)

        try await viewer.send(message: GoPeepV1Message(
            type: .join,
            role: .viewer,
            password: initialPassword
        ))
        let viewerJoined = try await viewer.receiveMessage()
        #expect(viewerJoined.type == .joined)
        #expect(viewerJoined.role == .viewer)
        #expect(viewerJoined.room == reservation.room.rawValue)
        try await events.waitForMessage(type: .viewerJoined)

        let peerID = "clip-native-fixture-peer"
        let offerSDP = "v=0\r\no=clip 1 1 IN IP4 127.0.0.1\r\ns=Clip interop offer\r\nt=0 0\r\n"
        try await sharer.send(GoPeepV1Message(
            type: .offer,
            sdp: offerSDP,
            peerID: peerID
        ))
        let routedOffer = try await viewer.receiveMessage()
        #expect(routedOffer.type == .offer)
        #expect(routedOffer.peerID == peerID)
        #expect(routedOffer.sdp == offerSDP)

        let answerSDP = "v=0\r\no=viewer 2 2 IN IP4 127.0.0.1\r\ns=GoPeep interop answer\r\nt=0 0\r\n"
        try await viewer.send(message: GoPeepV1Message(
            type: .answer,
            sdp: answerSDP,
            peerID: peerID
        ))
        try await events.waitForMessage(type: .answer) { message in
            message.peerID == peerID && message.sdp == answerSDP
        }

        let hostCandidate = "candidate:host-fixture 1 udp 2122260223 127.0.0.1 41000 typ host"
        try await sharer.send(GoPeepV1Message(
            type: .ice,
            candidate: hostCandidate,
            peerID: peerID
        ))
        let routedHostICE = try await viewer.receiveMessage()
        #expect(routedHostICE.type == .ice)
        #expect(routedHostICE.peerID == peerID)
        #expect(routedHostICE.candidate == hostCandidate)

        let viewerCandidate = "candidate:viewer-fixture 1 udp 2122260223 127.0.0.1 42000 typ host"
        try await viewer.send(message: GoPeepV1Message(
            type: .ice,
            candidate: viewerCandidate
        ))
        try await events.waitForMessage(type: .ice) { message in
            message.peerID == peerID && message.candidate == viewerCandidate
        }

        let replacementPassword = "clip-interop-replaced"
        try await sharer.send(GoPeepV1Message(
            type: .passwordUpdate,
            password: replacementPassword,
            secret: reservation.secret
        ))

        let replacementViewer = try await URLSessionGoPeepV1WebSocketFactory().makeConnection(
            for: server.signalingURL(for: reservation.room)
        )
        try await replacementViewer.resume()
        defer {
            Task { await replacementViewer.close() }
        }
        try await replacementViewer.send(message: GoPeepV1Message(
            type: .join,
            role: .viewer,
            password: initialPassword
        ))
        #expect(try await replacementViewer.receiveMessage().type == .passwordInvalid)
        try await replacementViewer.send(message: GoPeepV1Message(
            type: .join,
            role: .viewer,
            password: replacementPassword
        ))
        #expect(try await replacementViewer.receiveMessage().type == .joined)

        await viewer.close()
        await replacementViewer.close()
        await sharer.stop()
        try await events.waitForEvent(.stopped)
    }
}

private actor LocalInteropEventRecorder {
    private var events: [GoPeepV1SignalingEvent] = []

    static func record(client: GoPeepV1SignalingClient) async -> LocalInteropEventRecorder {
        let recorder = LocalInteropEventRecorder()
        let stream = await client.events()
        Task {
            for await event in stream {
                await recorder.append(event)
            }
        }
        return recorder
    }

    func append(_ event: GoPeepV1SignalingEvent) {
        events.append(event)
    }

    func contains(_ event: GoPeepV1SignalingEvent) -> Bool {
        events.contains(event)
    }

    func waitForEvent(_ expected: GoPeepV1SignalingEvent) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if events.contains(expected) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for GoPeep signaling event \(expected)")
    }

    func waitForMessage(
        type: GoPeepV1MessageType,
        matching predicate: @escaping @Sendable (GoPeepV1Message) -> Bool = { _ in true }
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if events.contains(where: { event in
                guard case .message(let message) = event, message.type == type else {
                    return false
                }
                return predicate(message)
            }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for GoPeep signaling message \(type.rawValue)")
    }
}

private extension GoPeepV1WebSocketConnection {
    func send(message: GoPeepV1Message) async throws {
        let data = try JSONEncoder().encode(message)
        try await send(.text(String(decoding: data, as: UTF8.self)))
    }

    func receiveMessage() async throws -> GoPeepV1Message {
        let payload = try await receive()
        let data: Data = switch payload {
        case .text(let text): Data(text.utf8)
        case .data(let data): data
        }
        return try JSONDecoder().decode(GoPeepV1Message.self, from: data)
    }
}
