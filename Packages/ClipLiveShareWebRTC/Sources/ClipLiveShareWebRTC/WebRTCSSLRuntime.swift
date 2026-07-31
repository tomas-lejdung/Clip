import Foundation
@preconcurrency import WebRTC

public enum WebRTCRuntimeError: Error, Equatable, Sendable {
    case sslInitializationFailed
}

/// Reference-counts libwebrtc's process-global SSL adapter. Each participant
/// transport keeps a lease for its full lifetime, so cleanup cannot race a
/// live peer factory.
final class WebRTCSSLRuntimeLease: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var leaseCount = 0

    init() throws {
        try Self.lock.withLock {
            if Self.leaseCount == 0, !RTCInitializeSSL() {
                throw WebRTCRuntimeError.sslInitializationFailed
            }
            Self.leaseCount += 1
        }
    }

    deinit {
        Self.lock.withLock {
            precondition(Self.leaseCount > 0)
            Self.leaseCount -= 1
            if Self.leaseCount == 0 {
                _ = RTCCleanupSSL()
            }
        }
    }
}
