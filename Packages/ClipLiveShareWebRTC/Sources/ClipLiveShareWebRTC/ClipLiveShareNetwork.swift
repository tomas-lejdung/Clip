import Foundation

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
    private let maximumResponseBytes: Int

    public init(
        session: URLSession = .shared,
        maximumResponseBytes: Int = 65_536
    ) {
        self.session = session
        self.maximumResponseBytes = max(1, maximumResponseBytes)
    }

    public func execute(
        _ request: URLRequest
    ) async throws -> ClipLiveShareHTTPResult {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClipLiveShareNetworkError.invalidHTTPResponse
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            throw ClipLiveShareNetworkError.responseTooLarge
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(
                min(maximumResponseBytes, Int(response.expectedContentLength))
            )
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw ClipLiveShareNetworkError.responseTooLarge
            }
            data.append(byte)
        }
        return ClipLiveShareHTTPResult(
            statusCode: response.statusCode,
            data: data
        )
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

public struct URLSessionClipLiveShareWebSocketFactory:
    ClipLiveShareWebSocketFactory
{
    private let session: URLSession
    private let maximumMessageBytes: Int

    public init(
        session: URLSession = .shared,
        maximumMessageBytes: Int = 262_144
    ) {
        self.session = session
        self.maximumMessageBytes = max(1, maximumMessageBytes)
    }

    public func makeConnection(
        for request: URLRequest
    ) async throws -> any ClipLiveShareWebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageBytes
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
        guard !didClose else {
            throw ClipLiveShareNetworkError.connectionFailed
        }
        guard !didResume else { return }
        didResume = true
        task.resume()
    }

    func send(_ payload: ClipLiveShareWebSocketPayload) async throws {
        guard didResume, !didClose else {
            throw ClipLiveShareNetworkError.notConnected
        }
        switch payload {
        case let .text(value):
            try await task.send(.string(value))
        case let .data(value):
            try await task.send(.data(value))
        }
    }

    func receive() async throws -> ClipLiveShareWebSocketPayload {
        guard didResume, !didClose else {
            throw ClipLiveShareNetworkError.notConnected
        }
        switch try await task.receive() {
        case let .string(value):
            return .text(value)
        case let .data(value):
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

public enum ClipLiveShareNetworkError: Error, Equatable, Sendable {
    case invalidHTTPResponse
    case responseTooLarge
    case connectionFailed
    case notConnected
    case unsupportedWebSocketPayload
}

public protocol ClipLiveShareReconnectSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousClipLiveShareReconnectSleeper:
    ClipLiveShareReconnectSleeper
{
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
        guard repeatsLastDelay, let finalDelay = delaysMilliseconds.last else {
            return nil
        }
        return .milliseconds(finalDelay)
    }

    public static let boundedExponential = Self(
        delaysMilliseconds: [250, 500, 1_000, 2_000, 4_000]
    )

    public static let persistentExponential = Self(
        delaysMilliseconds: [250, 500, 1_000, 2_000, 4_000, 8_000, 15_000],
        repeatsLastDelay: true
    )

    public static let disabled = Self(delaysMilliseconds: [])
}
