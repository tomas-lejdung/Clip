import Testing
@testable import ClipLiveShareWebRTC

@Suite("WebRTC peer bandwidth envelope")
struct WebRTCPeerBandwidthEnvelopeTests {
    @Test("active sender policies form one peer-wide envelope")
    func aggregateActivePolicies() throws {
        let envelope = try #require(WebRTCPeerBandwidthEnvelope.make(
            activeVideoPolicies: [
                .init(
                    maximumBitrateBps: 8_000_000,
                    minimumBitrateBps: 2_000_000
                ),
                .init(
                    maximumBitrateBps: 2_000_000,
                    minimumBitrateBps: nil
                ),
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
        let belowFloor = try #require(WebRTCPeerBandwidthEnvelope.make(
            activeVideoPolicies: policies,
            preferredInitialVideoBitrateBps: 1_000_000
        ))
        let aboveCeiling = try #require(WebRTCPeerBandwidthEnvelope.make(
            activeVideoPolicies: policies,
            preferredInitialVideoBitrateBps: 20_000_000
        ))

        #expect(belowFloor.initialBitrateBps == 3_000_000)
        #expect(aboveCeiling.initialBitrateBps == 8_000_000)
    }

    @Test("empty and unbounded video policies do not consume a BWE seed")
    func unavailableEnvelope() {
        #expect(WebRTCPeerBandwidthEnvelope.make(
            activeVideoPolicies: [],
            preferredInitialVideoBitrateBps: 20_000_000
        ) == nil)
        #expect(WebRTCPeerBandwidthEnvelope.make(
            activeVideoPolicies: [.init(maximumBitrateBps: nil)],
            preferredInitialVideoBitrateBps: 20_000_000
        ) == nil)

        let state = WebRTCPeerBandwidthApplicationState()
        #expect(state.transition(
            to: nil,
            seedCurrentEstimate: true
        ) == nil)
        #expect(!state.hasSeededCurrentEstimate)
    }

    @Test("aggregate arithmetic saturates at native WebRTC integer bounds")
    func saturatingAggregation() throws {
        let envelope = try #require(WebRTCPeerBandwidthEnvelope.make(
            activeVideoPolicies: [
                .init(
                    maximumBitrateBps: .max,
                    minimumBitrateBps: .max
                ),
                .init(
                    maximumBitrateBps: .max,
                    minimumBitrateBps: .max
                ),
            ],
            preferredInitialVideoBitrateBps: .max,
            auxiliaryBitrateBps: .max
        ))

        #expect(
            envelope.minimumBitrateBps
                == WebRTCPeerBandwidthEnvelope.nativeMaximumBitrateBps
        )
        #expect(
            envelope.initialBitrateBps
                == WebRTCPeerBandwidthEnvelope.nativeMaximumBitrateBps
        )
        #expect(
            envelope.maximumBitrateBps
                == WebRTCPeerBandwidthEnvelope.nativeMaximumBitrateBps
        )
    }

    @Test("first active envelope seeds once and commits transactionally")
    func initialSeed() {
        let envelope = WebRTCPeerBandwidthEnvelope(
            minimumBitrateBps: 0,
            preferredInitialBitrateBps: 20_000_000,
            maximumBitrateBps: 50_000_000
        )
        var state = WebRTCPeerBandwidthApplicationState()
        let transition = state.transition(
            to: envelope,
            seedCurrentEstimate: true
        )

        #expect(transition?.update == WebRTCPeerBandwidthUpdate(
            minimumBitrateBps: 0,
            currentBitrateBps: 20_000_000,
            maximumBitrateBps: 50_000_000
        ))
        #expect(!state.hasSeededCurrentEstimate)
        state.commit(transition!)
        #expect(state.hasSeededCurrentEstimate)
        #expect(state.lastAppliedEnvelope == envelope)
        #expect(state.transition(
            to: envelope,
            seedCurrentEstimate: false
        ) == nil)
    }

    @Test("ordinary bound changes preserve the learned estimate")
    func boundChangeDoesNotReseed() throws {
        let original = WebRTCPeerBandwidthEnvelope(
            minimumBitrateBps: 0,
            preferredInitialBitrateBps: 20_000_000,
            maximumBitrateBps: 50_000_000
        )
        let updated = WebRTCPeerBandwidthEnvelope(
            minimumBitrateBps: 4_000_000,
            preferredInitialBitrateBps: 8_000_000,
            maximumBitrateBps: 20_000_000
        )
        var state = WebRTCPeerBandwidthApplicationState()
        state.commit(try #require(state.transition(
            to: original,
            seedCurrentEstimate: true
        )))

        let transition = try #require(state.transition(
            to: updated,
            seedCurrentEstimate: false
        ))
        #expect(transition.update == WebRTCPeerBandwidthUpdate(
            minimumBitrateBps: 4_000_000,
            currentBitrateBps: nil,
            maximumBitrateBps: 20_000_000
        ))
        state.commit(transition)
        #expect(state.transition(
            to: updated,
            seedCurrentEstimate: false
        ) == nil)
    }

    @Test("bounds can be installed without forcing the learned estimate")
    func boundsWithoutSeed() throws {
        let envelope = WebRTCPeerBandwidthEnvelope(
            minimumBitrateBps: 0,
            preferredInitialBitrateBps: 20_000_000,
            maximumBitrateBps: 50_000_000
        )
        var state = WebRTCPeerBandwidthApplicationState()
        let bounds = try #require(state.transition(
            to: envelope,
            seedCurrentEstimate: false
        ))
        #expect(bounds.update == WebRTCPeerBandwidthUpdate(
            minimumBitrateBps: 0,
            currentBitrateBps: nil,
            maximumBitrateBps: 50_000_000
        ))
        state.commit(bounds)
        #expect(!state.hasSeededCurrentEstimate)

        let qualitySeed = try #require(state.transition(
            to: envelope,
            seedCurrentEstimate: true
        ))
        #expect(qualitySeed.update == WebRTCPeerBandwidthUpdate(
            minimumBitrateBps: nil,
            currentBitrateBps: 20_000_000,
            maximumBitrateBps: nil
        ))
    }

    @Test("returning a requested floor to Auto sends an explicit zero")
    func clearsRequestedFloor() throws {
        let requestedFloor = WebRTCPeerBandwidthEnvelope(
            minimumBitrateBps: 12_500_000,
            preferredInitialBitrateBps: 50_000_000,
            maximumBitrateBps: 50_000_000
        )
        let automaticFloor = WebRTCPeerBandwidthEnvelope(
            minimumBitrateBps: 0,
            preferredInitialBitrateBps: 50_000_000,
            maximumBitrateBps: 50_000_000
        )
        var state = WebRTCPeerBandwidthApplicationState()
        state.commit(try #require(state.transition(
            to: requestedFloor,
            seedCurrentEstimate: true
        )))

        let transition = try #require(state.transition(
            to: automaticFloor,
            seedCurrentEstimate: false
        ))
        #expect(transition.update == WebRTCPeerBandwidthUpdate(
            minimumBitrateBps: 0,
            currentBitrateBps: nil,
            maximumBitrateBps: 50_000_000
        ))
    }

    @Test("explicit reseed resets only the current estimate")
    func explicitReseed() throws {
        let envelope = WebRTCPeerBandwidthEnvelope(
            minimumBitrateBps: 0,
            preferredInitialBitrateBps: 20_000_000,
            maximumBitrateBps: 50_000_000
        )
        var state = WebRTCPeerBandwidthApplicationState()
        state.commit(try #require(state.transition(
            to: envelope,
            seedCurrentEstimate: true
        )))

        let transition = try #require(state.transition(
            to: envelope,
            seedCurrentEstimate: true
        ))
        #expect(transition.update == WebRTCPeerBandwidthUpdate(
            minimumBitrateBps: nil,
            currentBitrateBps: 20_000_000,
            maximumBitrateBps: nil
        ))
    }

    @Test("source-free reset remains pending until native acceptance")
    func sourceFreeResetIsTransactional() {
        var state = WebRTCPeerSourceFreeBandwidthResetState()

        state.request()
        #expect(state.isPending)

        state.acknowledge(accepted: false)
        #expect(state.isPending)

        state.acknowledge(accepted: true)
        #expect(!state.isPending)
    }

    @Test("a returning source cancels its obsolete source-free reset")
    func sourceFreeResetCanBeCancelled() {
        var state = WebRTCPeerSourceFreeBandwidthResetState()

        state.request()
        state.cancel()

        #expect(!state.isPending)
    }
}
