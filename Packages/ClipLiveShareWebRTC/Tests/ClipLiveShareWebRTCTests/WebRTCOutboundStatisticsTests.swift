import Foundation
import Testing
@testable import ClipLiveShareWebRTC

@Suite("WebRTC outbound statistics")
struct WebRTCOutboundStatisticsTests {
    @Test("rates are measured from counter deltas and aggregate across viewers")
    func measuredRatesAndAggregation() throws {
        var previous: [WebRTCOutboundCounterKey: WebRTCOutboundCounter] = [:]
        let slots = (0 ..< 4).map {
            WebRTCStreamSlotSnapshot(
                index: $0,
                trackID: "video\($0)",
                streamID: "gopeep-stream-\($0)",
                metadata: nil
            )
        }
        let first = [
            Self.sample(viewer: "a", timestamp: 1_000_000, bytes: 100, frames: 5),
            Self.sample(viewer: "b", timestamp: 1_000_000, bytes: 200, frames: 8),
        ]
        let baseline = WebRTCOutboundStatisticsAggregator.makeSnapshot(
            samples: first,
            slots: slots,
            connectedViewerCount: 2,
            previous: &previous,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let baselineSlot = try #require(baseline[slot: 0])
        #expect(baselineSlot.bytesSent == 300)
        #expect(baselineSlot.aggregateBitrateBps == nil)
        #expect(baselineSlot.averageFramesPerSecond == nil)

        let second = [
            Self.sample(viewer: "a", timestamp: 2_000_000, bytes: 1_100, frames: 35),
            Self.sample(viewer: "b", timestamp: 2_000_000, bytes: 2_200, frames: 38),
        ]
        let measured = WebRTCOutboundStatisticsAggregator.makeSnapshot(
            samples: second,
            slots: slots,
            connectedViewerCount: 2,
            previous: &previous,
            capturedAt: Date(timeIntervalSince1970: 2)
        )
        let slot = try #require(measured[slot: 0])
        #expect(slot.bytesSent == 3_300)
        #expect(slot.framesSent == 73)
        #expect(slot.aggregateBitrateBps == 24_000)
        #expect(slot.averageFramesPerSecond == 30)
        #expect(slot.viewers.map(\.viewerID) == ["a", "b"])
        #expect(measured.viewerCount == 2)
        #expect(measured.connectedViewerCount == 2)
        #expect(measured.slots.count == 4)
    }

    @Test("counter resets never produce fabricated negative rates")
    func counterReset() throws {
        var previous: [WebRTCOutboundCounterKey: WebRTCOutboundCounter] = [
            .init(viewerID: "a", slot: 0): .init(
                timestampMicroseconds: 2_000_000,
                bytesSent: 1_000,
                framesSent: 30
            ),
        ]
        let snapshot = WebRTCOutboundStatisticsAggregator.makeSnapshot(
            samples: [Self.sample(
                viewer: "a",
                timestamp: 3_000_000,
                bytes: 10,
                frames: 1
            )],
            slots: [.init(
                index: 0,
                trackID: "video0",
                streamID: "gopeep-stream-0",
                metadata: nil
            )],
            connectedViewerCount: 1,
            previous: &previous,
            capturedAt: Date()
        )
        let slot = try #require(snapshot[slot: 0])
        #expect(slot.aggregateBitrateBps == nil)
        #expect(slot.averageFramesPerSecond == nil)
    }

    private static func sample(
        viewer: String,
        timestamp: Double,
        bytes: UInt64,
        frames: UInt64
    ) -> WebRTCRawOutboundStatistics {
        .init(
            viewerID: viewer,
            slot: 0,
            trackID: "video0",
            timestampMicroseconds: timestamp,
            bytesSent: bytes,
            packetsSent: frames,
            framesSent: frames,
            framesEncoded: frames,
            reportedFramesPerSecond: nil
        )
    }
}
