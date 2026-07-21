import Foundation

actor ClipNativeRendezvousSerializedSocket: ClipLiveShareWebSocketConnection {
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

actor ClipNativeRendezvousOperationSequencer {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let predecessor = tail
        let task = Task<T, any Error> {
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }
}

func clipNativeRendezvousEventStream(
    bufferingLimit: Int = 256
) -> (
    stream: AsyncStream<ClipNativeRendezvousEvent>,
    continuation: AsyncStream<ClipNativeRendezvousEvent>.Continuation
) {
    AsyncStream.makeStream(
        of: ClipNativeRendezvousEvent.self,
        bufferingPolicy: .bufferingNewest(bufferingLimit)
    )
}
