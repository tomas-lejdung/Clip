import Foundation
@preconcurrency import WebRTC

/// Reference-counts libwebrtc's process-global SSL adapter. Each host keeps a
/// lease for its full lifetime, so cleanup cannot race a live peer factory.
final class WebRTCSSLRuntimeLease: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var leaseCount = 0

    init() throws {
        try Self.lock.withLock {
            if Self.leaseCount == 0, !RTCInitializeSSL() {
                throw WebRTCPeerHostError.sslInitializationFailed
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
