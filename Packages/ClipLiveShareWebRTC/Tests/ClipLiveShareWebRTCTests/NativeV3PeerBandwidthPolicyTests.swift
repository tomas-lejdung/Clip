import Testing
@testable import ClipLiveShareWebRTC

@Suite("Native-v3 peer bandwidth policy")
struct NativeV3PeerBandwidthPolicyTests {
  @Test("active sender policies form one peer-wide envelope")
  func aggregateActivePolicies() throws {
    let envelope = try #require(NativeV3PeerBandwidthEnvelope.make(
      activeVideoPolicies: [
        .init(
          maximumBitrateBps: 8_000_000,
          minimumBitrateBps: 2_000_000
        ),
        .init(maximumBitrateBps: 2_000_000),
      ],
      preferredInitialVideoBitrateBps: 6_000_000,
      auxiliaryBitrateBps: 128_000
    ))

    #expect(envelope.minimumBitrateBps == 2_000_000)
    #expect(envelope.initialBitrateBps == 6_128_000)
    #expect(envelope.maximumBitrateBps == 10_128_000)
  }

  @Test("initial estimate is clamped between aggregate floor and ceiling")
  func initialEstimateClamping() throws {
    let policies = [
      WebRTCSenderPolicy(
        maximumBitrateBps: 8_000_000,
        minimumBitrateBps: 3_000_000
      ),
    ]
    let belowFloor = try #require(NativeV3PeerBandwidthEnvelope.make(
      activeVideoPolicies: policies,
      preferredInitialVideoBitrateBps: 1_000_000
    ))
    let aboveCeiling = try #require(NativeV3PeerBandwidthEnvelope.make(
      activeVideoPolicies: policies,
      preferredInitialVideoBitrateBps: 20_000_000
    ))

    #expect(belowFloor.initialBitrateBps == 3_000_000)
    #expect(aboveCeiling.initialBitrateBps == 8_000_000)
  }

  @Test("first quality envelope seeds once and commits transactionally")
  func initialSeed() throws {
    let envelope = NativeV3PeerBandwidthEnvelope(
      minimumBitrateBps: 0,
      preferredInitialBitrateBps: 20_000_000,
      maximumBitrateBps: 50_000_000
    )
    var state = NativeV3PeerBandwidthApplicationState()
    let transition = try #require(state.transition(
      to: envelope,
      seedCurrentEstimate: true
    ))

    #expect(transition.update == NativeV3PeerBandwidthUpdate(
      minimumBitrateBps: 0,
      currentBitrateBps: 20_000_000,
      maximumBitrateBps: 50_000_000
    ))
    #expect(!state.hasSeededCurrentEstimate)
    state.commit(transition)
    #expect(state.hasSeededCurrentEstimate)
    #expect(state.transition(
      to: envelope,
      seedCurrentEstimate: false
    ) == nil)
  }

  @Test("ordinary bound changes preserve the learned estimate")
  func boundChangeDoesNotReseed() throws {
    let original = NativeV3PeerBandwidthEnvelope(
      minimumBitrateBps: 0,
      preferredInitialBitrateBps: 20_000_000,
      maximumBitrateBps: 50_000_000
    )
    let updated = NativeV3PeerBandwidthEnvelope(
      minimumBitrateBps: 4_000_000,
      preferredInitialBitrateBps: 8_000_000,
      maximumBitrateBps: 20_000_000
    )
    var state = NativeV3PeerBandwidthApplicationState()
    state.commit(try #require(state.transition(
      to: original,
      seedCurrentEstimate: true
    )))

    let transition = try #require(state.transition(
      to: updated,
      seedCurrentEstimate: false
    ))
    #expect(transition.update == NativeV3PeerBandwidthUpdate(
      minimumBitrateBps: 4_000_000,
      currentBitrateBps: nil,
      maximumBitrateBps: 20_000_000
    ))
  }

  @Test("explicit quality reseed changes only the current estimate")
  func explicitReseed() throws {
    let envelope = NativeV3PeerBandwidthEnvelope(
      minimumBitrateBps: 0,
      preferredInitialBitrateBps: 20_000_000,
      maximumBitrateBps: 50_000_000
    )
    var state = NativeV3PeerBandwidthApplicationState()
    state.commit(try #require(state.transition(
      to: envelope,
      seedCurrentEstimate: true
    )))

    let transition = try #require(state.transition(
      to: envelope,
      seedCurrentEstimate: true
    ))
    #expect(transition.update == NativeV3PeerBandwidthUpdate(
      minimumBitrateBps: nil,
      currentBitrateBps: 20_000_000,
      maximumBitrateBps: nil
    ))
  }

  @Test("source and connection callback order converge")
  func readinessOrder() {
    let sourceFirst = NativeV3PeerBandwidthConditions(
      isConnected: false,
      outboundMediaEnabled: true,
      activeVideoSourceCount: 1,
      videoEncodingMode: .quality
    )
    let connectionFirst = NativeV3PeerBandwidthConditions(
      isConnected: true,
      outboundMediaEnabled: true,
      activeVideoSourceCount: 0,
      videoEncodingMode: .quality
    )
    let ready = NativeV3PeerBandwidthConditions(
      isConnected: true,
      outboundMediaEnabled: true,
      activeVideoSourceCount: 1,
      videoEncodingMode: .quality
    )

    #expect(!sourceFirst.canApply)
    #expect(!connectionFirst.canApply)
    #expect(ready.canApply)
    #expect(ready.shouldSeed(
      seedPending: true,
      hasSeededCurrentEstimate: false
    ))
  }

  @Test("disabled outbound media and non-quality mode never seed")
  func seedingGuard() {
    let disabled = NativeV3PeerBandwidthConditions(
      isConnected: true,
      outboundMediaEnabled: false,
      activeVideoSourceCount: 1,
      videoEncodingMode: .quality
    )
    let performance = NativeV3PeerBandwidthConditions(
      isConnected: true,
      outboundMediaEnabled: true,
      activeVideoSourceCount: 1,
      videoEncodingMode: .performance
    )

    #expect(!disabled.canApply)
    #expect(!disabled.shouldSeed(
      seedPending: true,
      hasSeededCurrentEstimate: false
    ))
    #expect(performance.canApply)
    #expect(!performance.shouldSeed(
      seedPending: true,
      hasSeededCurrentEstimate: false
    ))
  }
}
