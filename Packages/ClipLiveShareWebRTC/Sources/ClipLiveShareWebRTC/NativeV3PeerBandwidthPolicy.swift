import ClipLiveShare
import Foundation

/// Peer-wide bitrate bounds passed to libwebrtc's bandwidth estimator.
///
/// `WebRTCSenderPolicy` remains the per-track contract. A peer connection has
/// one shared estimator, so its envelope is the sum of only the video policies
/// that are currently active plus reserved participant-audio headroom.
struct NativeV3PeerBandwidthEnvelope: Equatable, Sendable {
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
      activeVideoPolicies.allSatisfy({ ($0.maximumBitrateBps ?? 0) > 0 })
    else { return nil }

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
      // connection ceiling and initial estimate.
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
    let normalizedLeft = min(nativeMaximumBitrateBps, max(0, lhs))
    let remaining = nativeMaximumBitrateBps - normalizedLeft
    return normalizedLeft + min(remaining, max(0, rhs))
  }
}

/// Optional fields map directly to `RTCPeerConnection.setBwe...`. Omitting
/// `currentBitrateBps` is essential: setting it resets libwebrtc's learned
/// estimate, so ordinary source and policy changes update only bounds.
struct NativeV3PeerBandwidthUpdate: Equatable, Sendable {
  let minimumBitrateBps: Int?
  let currentBitrateBps: Int?
  let maximumBitrateBps: Int?
}

struct NativeV3PeerBandwidthTransition: Equatable, Sendable {
  let envelope: NativeV3PeerBandwidthEnvelope
  let update: NativeV3PeerBandwidthUpdate
  fileprivate let seedsCurrentEstimate: Bool
}

/// Transactional per-peer BWE state. Native acceptance is committed only
/// after `setBweMinBitrateBps` succeeds.
struct NativeV3PeerBandwidthApplicationState: Equatable, Sendable {
  private(set) var lastAppliedEnvelope: NativeV3PeerBandwidthEnvelope?
  private(set) var hasSeededCurrentEstimate = false

  func transition(
    to envelope: NativeV3PeerBandwidthEnvelope?,
    seedCurrentEstimate: Bool
  ) -> NativeV3PeerBandwidthTransition? {
    guard let envelope else { return nil }
    let envelopeChanged = envelope != lastAppliedEnvelope
    guard envelopeChanged || seedCurrentEstimate else { return nil }
    return NativeV3PeerBandwidthTransition(
      envelope: envelope,
      update: .init(
        minimumBitrateBps: envelopeChanged
          ? envelope.minimumBitrateBps : nil,
        currentBitrateBps: seedCurrentEstimate
          ? envelope.initialBitrateBps : nil,
        maximumBitrateBps: envelopeChanged
          ? envelope.maximumBitrateBps : nil
      ),
      seedsCurrentEstimate: seedCurrentEstimate
    )
  }

  mutating func commit(_ transition: NativeV3PeerBandwidthTransition) {
    lastAppliedEnvelope = transition.envelope
    if transition.seedsCurrentEstimate {
      hasSeededCurrentEstimate = true
    }
  }

  mutating func reset() {
    self = .init()
  }
}

/// Readiness for applying the peer-wide bandwidth envelope. Keeping this gate
/// independent from callback ordering makes source-before-connection and
/// connection-before-source converge on the same result.
struct NativeV3PeerBandwidthConditions: Equatable, Sendable {
  let isConnected: Bool
  let outboundMediaEnabled: Bool
  let activeVideoSourceCount: Int
  let videoEncodingMode: LiveShareEncodingMode

  var canApply: Bool {
    isConnected && outboundMediaEnabled && activeVideoSourceCount > 0
  }

  func shouldSeed(
    seedPending: Bool,
    hasSeededCurrentEstimate: Bool
  ) -> Bool {
    canApply && videoEncodingMode == .quality
      && (seedPending || !hasSeededCurrentEstimate)
  }
}
