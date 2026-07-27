import Foundation

/// Peer-wide bitrate bounds passed to libwebrtc's bandwidth estimator.
///
/// `WebRTCSenderPolicy` remains the per-track contract. A peer connection has
/// one shared estimator, so its envelope is the sum of only the video policies
/// that are currently active for that peer plus reserved auxiliary-media
/// headroom. Reserving the negotiated Opus maximum even while muted lets audio
/// toggle on without stealing from the selected video budget or reseeding BWE.
struct WebRTCPeerBandwidthEnvelope: Equatable, Sendable {
    static let nativeMaximumBitrateBps = Int(Int32.max)

    let minimumBitrateBps: Int
    let initialBitrateBps: Int
    let maximumBitrateBps: Int

    init(
        minimumBitrateBps: Int,
        preferredInitialBitrateBps: Int,
        maximumBitrateBps: Int
    ) {
        let maximum = min(
            Self.nativeMaximumBitrateBps,
            max(0, maximumBitrateBps)
        )
        let minimum = min(maximum, max(0, minimumBitrateBps))
        self.minimumBitrateBps = minimum
        initialBitrateBps = min(
            maximum,
            max(minimum, preferredInitialBitrateBps)
        )
        self.maximumBitrateBps = maximum
    }

    static func make(
        activeVideoPolicies: [WebRTCSenderPolicy],
        preferredInitialVideoBitrateBps: Int,
        auxiliaryBitrateBps: Int = 0
    ) -> Self? {
        guard !activeVideoPolicies.isEmpty,
              activeVideoPolicies.allSatisfy({
                  ($0.maximumBitrateBps ?? 0) > 0
              }) else {
            return nil
        }
        let auxiliary = min(
            nativeMaximumBitrateBps,
            max(0, auxiliaryBitrateBps)
        )
        let videoMinimum = saturatingSum(
            activeVideoPolicies.compactMap(\.minimumBitrateBps)
        )
        let videoMaximum = saturatingSum(
            activeVideoPolicies.compactMap(\.maximumBitrateBps)
        )
        return Self(
            // Opus has no requested sender floor. Reserve audio only in the
            // connection ceiling so an enabled audio track cannot consume the
            // video budget or turn Auto into a hidden congestion floor.
            minimumBitrateBps: videoMinimum,
            preferredInitialBitrateBps: saturatingAdd(
                max(0, preferredInitialVideoBitrateBps),
                auxiliary
            ),
            maximumBitrateBps: saturatingAdd(videoMaximum, auxiliary)
        )
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { result, value in
            saturatingAdd(result, max(0, value))
        }
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let remaining = nativeMaximumBitrateBps - min(
            nativeMaximumBitrateBps,
            max(0, lhs)
        )
        return min(nativeMaximumBitrateBps, max(0, lhs) + min(remaining, max(0, rhs)))
    }
}

/// Optional fields map directly to `RTCPeerConnection.setBwe...`. Omitting
/// `currentBitrateBps` is important: setting it resets libwebrtc's learned
/// estimate, so ordinary policy and focus changes must update only the bounds.
struct WebRTCPeerBandwidthUpdate: Equatable, Sendable {
    let minimumBitrateBps: Int?
    let currentBitrateBps: Int?
    let maximumBitrateBps: Int?
}

struct WebRTCPeerBandwidthTransition: Equatable, Sendable {
    let envelope: WebRTCPeerBandwidthEnvelope
    let update: WebRTCPeerBandwidthUpdate
    fileprivate let seedsCurrentEstimate: Bool
}

/// Transactional per-peer state. The host asks for a transition, applies it to
/// the native connection, and commits only after libwebrtc accepts the update.
struct WebRTCPeerBandwidthApplicationState: Equatable, Sendable {
    private(set) var lastAppliedEnvelope: WebRTCPeerBandwidthEnvelope?
    private(set) var hasSeededCurrentEstimate = false

    func transition(
        to envelope: WebRTCPeerBandwidthEnvelope?,
        seedCurrentEstimate: Bool
    ) -> WebRTCPeerBandwidthTransition? {
        guard let envelope else { return nil }
        let envelopeChanged = envelope != lastAppliedEnvelope
        let seedsCurrentEstimate = seedCurrentEstimate
        guard envelopeChanged || seedsCurrentEstimate else { return nil }
        return WebRTCPeerBandwidthTransition(
            envelope: envelope,
            update: WebRTCPeerBandwidthUpdate(
                minimumBitrateBps: envelopeChanged
                    ? envelope.minimumBitrateBps
                    : nil,
                currentBitrateBps: seedsCurrentEstimate
                    ? envelope.initialBitrateBps
                    : nil,
                maximumBitrateBps: envelopeChanged
                    ? envelope.maximumBitrateBps
                    : nil
            ),
            seedsCurrentEstimate: seedsCurrentEstimate
        )
    }

    mutating func commit(_ transition: WebRTCPeerBandwidthTransition) {
        lastAppliedEnvelope = transition.envelope
        if transition.seedsCurrentEstimate {
            hasSeededCurrentEstimate = true
        }
    }
}

/// Tracks the source-free BWE reset separately from the last accepted video
/// envelope. A disconnected peer cannot apply the reset yet, and libwebrtc can
/// reject an update, so only a native acceptance clears the pending request.
struct WebRTCPeerSourceFreeBandwidthResetState: Equatable, Sendable {
    private(set) var isPending = false

    mutating func request() {
        isPending = true
    }

    mutating func acknowledge(accepted: Bool) {
        if accepted {
            isPending = false
        }
    }

    mutating func cancel() {
        isPending = false
    }
}
