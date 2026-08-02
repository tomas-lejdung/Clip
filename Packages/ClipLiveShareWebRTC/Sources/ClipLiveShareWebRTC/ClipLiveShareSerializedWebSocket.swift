import Foundation

/// Serializes writes to one WebSocket connection while leaving receive and
/// lifecycle ownership with the room transport.
///
/// URLSession does not provide an ordering contract for independently
/// scheduled asynchronous sends. One tail task preserves the v4 room wire's
/// message order without coupling this transport primitive to a room version.
actor ClipLiveShareSerializedWebSocket: ClipLiveShareWebSocketConnection {
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
