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
                streamID: "clip-stream-\($0)",
                metadata: nil
            )
        }
        let first = [
            Self.sample(
                viewer: "a",
                timestamp: 1_000_000,
                bytes: 100,
                frames: 5,
                encodedWidth: 1920,
                encodedHeight: 1080,
                qpSum: 100,
                targetBitrate: 2_000_000,
                encoderDrops: 1,
                encodeTime: 0.05,
                packetSendDelay: 0.01,
                limitation: "bandwidth",
                resolutionChanges: 1,
                codec: "VP8"
            ),
            Self.sample(
                viewer: "b",
                timestamp: 1_000_000,
                bytes: 200,
                frames: 8,
                encodedWidth: 1920,
                encodedHeight: 1080,
                qpSum: 160,
                targetBitrate: 2_000_000,
                encoderDrops: 2,
                encodeTime: 0.08,
                packetSendDelay: 0.016,
                limitation: "bandwidth",
                resolutionChanges: 2,
                codec: "VP8"
            ),
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
        #expect(baselineSlot.encodedFrameWidth == 1920)
        #expect(baselineSlot.encodedFrameHeight == 1080)
        #expect(baselineSlot.averageQuantizer == nil)

        let second = [
            Self.sample(
                viewer: "a",
                timestamp: 2_000_000,
                bytes: 1_100,
                frames: 35,
                encodedWidth: 1920,
                encodedHeight: 1080,
                qpSum: 700,
                targetBitrate: 2_000_000,
                encoderDrops: 3,
                encodeTime: 0.35,
                packetSendDelay: 0.04,
                limitation: "bandwidth",
                resolutionChanges: 2,
                codec: "VP8"
            ),
            Self.sample(
                viewer: "b",
                timestamp: 2_000_000,
                bytes: 2_200,
                frames: 38,
                encodedWidth: 1920,
                encodedHeight: 1080,
                qpSum: 760,
                targetBitrate: 2_000_000,
                encoderDrops: 3,
                encodeTime: 0.38,
                packetSendDelay: 0.046,
                limitation: "bandwidth",
                resolutionChanges: 4,
                codec: "VP8"
            ),
        ]
        let measured = WebRTCOutboundStatisticsAggregator.makeSnapshot(
            samples: second,
            slots: slots,
            connectedViewerCount: 2,
            previous: &previous,
            capturedAt: Date(timeIntervalSince1970: 2),
            h264SubmissionBackpressureDrops: 4
        )
        let slot = try #require(measured[slot: 0])
        #expect(slot.bytesSent == 3_300)
        #expect(slot.framesSent == 73)
        #expect(slot.aggregateBitrateBps == 24_000)
        #expect(slot.averageFramesPerSecond == 30)
        #expect(slot.aggregateTargetBitrateBps == 4_000_000)
        #expect(slot.encodedFrameWidth == 1920)
        #expect(slot.encodedFrameHeight == 1080)
        #expect(slot.hasMixedEncodedFrameDimensions == false)
        #expect(slot.averageQuantizer == 20)
        #expect(slot.averageEncodeTimeMilliseconds == 10)
        #expect(slot.averagePacketSendDelayMilliseconds == 1)
        #expect(slot.encoderDroppedFrames == 3)
        #expect(slot.qualityLimitationReasons == ["bandwidth"])
        #expect(slot.qualityLimitationResolutionChanges == 6)
        #expect(slot.codecs == ["VP8"])
        #expect(slot.viewers.map(\.viewerID) == ["a", "b"])
        #expect(measured.viewerCount == 2)
        #expect(measured.connectedViewerCount == 2)
        #expect(measured.slots.count == 4)
        #expect(measured.h264SubmissionBackpressureDrops == 4)
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
                streamID: "clip-stream-0",
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

    @Test("independently adapted viewers report mixed encoded dimensions")
    func mixedEncodedDimensions() throws {
        var previous: [WebRTCOutboundCounterKey: WebRTCOutboundCounter] = [:]
        let snapshot = WebRTCOutboundStatisticsAggregator.makeSnapshot(
            samples: [
                Self.sample(
                    viewer: "a",
                    timestamp: 1_000_000,
                    bytes: 100,
                    frames: 5,
                    encodedWidth: 1920,
                    encodedHeight: 1080
                ),
                Self.sample(
                    viewer: "b",
                    timestamp: 1_000_000,
                    bytes: 100,
                    frames: 5,
                    encodedWidth: 1280,
                    encodedHeight: 720
                ),
            ],
            slots: [.init(
                index: 0,
                trackID: "video0",
                streamID: "clip-stream-0",
                metadata: nil
            )],
            connectedViewerCount: 2,
            previous: &previous,
            capturedAt: Date()
        )
        let slot = try #require(snapshot[slot: 0])
        #expect(slot.encodedFrameWidth == nil)
        #expect(slot.encodedFrameHeight == nil)
        #expect(slot.hasMixedEncodedFrameDimensions)
    }

    @Test("quantizer averages use matching encoded frame deltas")
    func quantizerDelta() throws {
        var previous: [WebRTCOutboundCounterKey: WebRTCOutboundCounter] = [:]
        let slot = WebRTCStreamSlotSnapshot(
            index: 0,
            trackID: "video0",
            streamID: "clip-stream-0",
            metadata: nil
        )
        _ = WebRTCOutboundStatisticsAggregator.makeSnapshot(
            samples: [Self.sample(
                viewer: "a",
                timestamp: 1_000_000,
                bytes: 100,
                frames: 10,
                qpSum: 250
            )],
            slots: [slot],
            connectedViewerCount: 1,
            previous: &previous,
            capturedAt: Date()
        )
        let measured = WebRTCOutboundStatisticsAggregator.makeSnapshot(
            samples: [Self.sample(
                viewer: "a",
                timestamp: 2_000_000,
                bytes: 1_100,
                frames: 30,
                qpSum: 650
            )],
            slots: [slot],
            connectedViewerCount: 1,
            previous: &previous,
            capturedAt: Date()
        )
        #expect(measured[slot: 0]?.averageQuantizer == 20)

        let reset = WebRTCOutboundStatisticsAggregator.makeSnapshot(
            samples: [Self.sample(
                viewer: "a",
                timestamp: 3_000_000,
                bytes: 2_100,
                frames: 50,
                qpSum: 50
            )],
            slots: [slot],
            connectedViewerCount: 1,
            previous: &previous,
            capturedAt: Date()
        )
        #expect(reset[slot: 0]?.averageQuantizer == nil)
    }

    private static func sample(
        viewer: String,
        timestamp: Double,
        bytes: UInt64,
        frames: UInt64,
        encodedWidth: Int? = nil,
        encodedHeight: Int? = nil,
        qpSum: UInt64? = nil,
        targetBitrate: Double? = nil,
        encoderDrops: UInt64? = nil,
        encodeTime: Double? = nil,
        packetSendDelay: Double? = nil,
        limitation: String? = nil,
        resolutionChanges: UInt64? = nil,
        codec: String? = nil
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
            encodedFrameWidth: encodedWidth,
            encodedFrameHeight: encodedHeight,
            qpSum: qpSum,
            reportedFramesPerSecond: nil,
            targetBitrateBps: targetBitrate,
            framesDroppedByEncoder: encoderDrops,
            totalEncodeTimeSeconds: encodeTime,
            totalPacketSendDelaySeconds: packetSendDelay,
            qualityLimitationReason: limitation,
            qualityLimitationResolutionChanges: resolutionChanges,
            codec: codec
        )
    }
}
