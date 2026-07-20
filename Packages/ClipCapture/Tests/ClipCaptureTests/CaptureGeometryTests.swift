@preconcurrency import ScreenCaptureKit
import CoreMedia
import Testing
@testable import ClipCapture

@Suite("Capture geometry and delivery policy")
struct CaptureGeometryTests {
    @Test("the first ScreenCaptureKit frame is deliverable for a static source")
    func initialFrameStatusPolicy() {
        #expect(ScreenCaptureSession.liveQueueDepth == 2)
        #expect(ScreenCaptureSession.isDeliverableFrameStatus(SCFrameStatus.started.rawValue))
        #expect(ScreenCaptureSession.isDeliverableFrameStatus(SCFrameStatus.complete.rawValue))

        #expect(!ScreenCaptureSession.isDeliverableFrameStatus(SCFrameStatus.idle.rawValue))
        #expect(!ScreenCaptureSession.isDeliverableFrameStatus(SCFrameStatus.blank.rawValue))
        #expect(!ScreenCaptureSession.isDeliverableFrameStatus(SCFrameStatus.suspended.rawValue))
        #expect(!ScreenCaptureSession.isDeliverableFrameStatus(SCFrameStatus.stopped.rawValue))
        #expect(!ScreenCaptureSession.isDeliverableFrameStatus(nil))
        #expect(!ScreenCaptureSession.isDeliverableFrameStatus(Int.max))
    }

    @Test("frames older than two capture intervals are stale")
    func frameFreshnessPolicy() {
        let now = CMTime(seconds: 100, preferredTimescale: 60_000)
        #expect(!CaptureFrameFreshnessPolicy.isStale(
            presentationTime: CMTime(seconds: 99.95, preferredTimescale: 60_000),
            hostTime: now,
            framesPerSecond: 30
        ))
        #expect(CaptureFrameFreshnessPolicy.isStale(
            presentationTime: CMTime(seconds: 99.90, preferredTimescale: 60_000),
            hostTime: now,
            framesPerSecond: 30
        ))
        #expect(CaptureFrameFreshnessPolicy.isStale(
            presentationTime: CMTime(seconds: 99.96, preferredTimescale: 60_000),
            hostTime: now,
            framesPerSecond: 60
        ))
    }

    @Test("invalid or incomparable clocks are delivered rather than guessed stale")
    func incomparableFrameTimestamps() {
        let now = CMTime(seconds: 100, preferredTimescale: 600)
        #expect(!CaptureFrameFreshnessPolicy.isStale(
            presentationTime: .invalid,
            hostTime: now,
            framesPerSecond: 30
        ))
        #expect(!CaptureFrameFreshnessPolicy.isStale(
            presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
            hostTime: now,
            framesPerSecond: 30
        ))
    }

    @Test("exact dimensions are accepted")
    func exactDimensions() throws {
        try CaptureFrameDimensionValidator.validate(
            actualWidth: 3_456,
            actualHeight: 2_234,
            expectedWidth: 3_456,
            expectedHeight: 2_234
        )
    }

    @Test("dimension mismatches are never silently rescaled")
    func mismatch() {
        #expect(throws: CaptureSessionError.invalidFrameDimensions(
            expectedWidth: 3_456,
            expectedHeight: 2_234,
            actualWidth: 1_728,
            actualHeight: 1_117
        )) {
            try CaptureFrameDimensionValidator.validate(
                actualWidth: 1_728,
                actualHeight: 1_117,
                expectedWidth: 3_456,
                expectedHeight: 2_234
            )
        }
    }

    @Test("an in-place resize accepts only its exact old and new dimensions")
    func resizeHandoff() throws {
        try CaptureFrameDimensionValidator.validate(
            actualWidth: 1_920,
            actualHeight: 1_080,
            expectedWidth: 1_920,
            expectedHeight: 1_080,
            alternateExpectedWidth: 2_560,
            alternateExpectedHeight: 1_440
        )
        try CaptureFrameDimensionValidator.validate(
            actualWidth: 2_560,
            actualHeight: 1_440,
            expectedWidth: 1_920,
            expectedHeight: 1_080,
            alternateExpectedWidth: 2_560,
            alternateExpectedHeight: 1_440
        )
        #expect(throws: CaptureSessionError.invalidFrameDimensions(
            expectedWidth: 1_920,
            expectedHeight: 1_080,
            actualWidth: 1_280,
            actualHeight: 720
        )) {
            try CaptureFrameDimensionValidator.validate(
                actualWidth: 1_280,
                actualHeight: 720,
                expectedWidth: 1_920,
                expectedHeight: 1_080,
                alternateExpectedWidth: 2_560,
                alternateExpectedHeight: 1_440
            )
        }
    }

    @Test("a late native 5K frame is dropped during the bounded H.264 handoff")
    func native5KToH264Handoff() throws {
        let commitTime = CMTime(seconds: 100, preferredTimescale: 60_000)
        var transition = CaptureFrameDimensionTransitionState()
        transition.commit(
            previousWidth: 5_120,
            previousHeight: 1_440,
            currentWidth: 4_096,
            currentHeight: 1_152,
            commitPresentationTime: commitTime,
            framesPerSecond: 60
        )

        #expect(try transition.classify(
            actualWidth: 4_096,
            actualHeight: 1_152,
            presentationTime: commitTime + CMTime(value: 1, timescale: 60),
            currentWidth: 4_096,
            currentHeight: 1_152
        ) == .deliver)
        #expect(try transition.classify(
            actualWidth: 5_120,
            actualHeight: 1_440,
            presentationTime: commitTime + CMTime(value: 2, timescale: 60),
            currentWidth: 4_096,
            currentHeight: 1_152
        ) == .dropRetired)

        #expect(throws: CaptureSessionError.invalidFrameDimensions(
            expectedWidth: 4_096,
            expectedHeight: 1_152,
            actualWidth: 5_120,
            actualHeight: 1_440
        )) {
            try transition.classify(
                actualWidth: 5_120,
                actualHeight: 1_440,
                presentationTime: commitTime + CMTime(value: 3, timescale: 60),
                currentWidth: 4_096,
                currentHeight: 1_152
            )
        }
        #expect(!transition.hasRetiredGeometry)
    }

    @Test("a one-pixel alignment frame is dropped rather than killing a codec switch")
    func oddWidthH264Handoff() throws {
        let commitTime = CMTime(seconds: 200, preferredTimescale: 60_000)
        var transition = CaptureFrameDimensionTransitionState()
        transition.commit(
            previousWidth: 1_605,
            previousHeight: 1_108,
            currentWidth: 1_604,
            currentHeight: 1_108,
            commitPresentationTime: commitTime,
            framesPerSecond: 30
        )

        #expect(try transition.classify(
            actualWidth: 1_605,
            actualHeight: 1_108,
            presentationTime: commitTime + CMTime(value: 1, timescale: 30),
            currentWidth: 1_604,
            currentHeight: 1_108
        ) == .dropRetired)
        #expect(try transition.classify(
            actualWidth: 1_604,
            actualHeight: 1_108,
            presentationTime: commitTime + CMTime(value: 2, timescale: 30),
            currentWidth: 1_604,
            currentHeight: 1_108
        ) == .deliver)
    }

    @Test("an unrelated third geometry remains fatal during a resize handoff")
    func unknownGeometryDuringHandoff() {
        let commitTime = CMTime(seconds: 300, preferredTimescale: 60_000)
        var transition = CaptureFrameDimensionTransitionState()
        transition.commit(
            previousWidth: 5_120,
            previousHeight: 1_440,
            currentWidth: 4_096,
            currentHeight: 1_152,
            commitPresentationTime: commitTime,
            framesPerSecond: 60
        )

        #expect(throws: CaptureSessionError.invalidFrameDimensions(
            expectedWidth: 4_096,
            expectedHeight: 1_152,
            actualWidth: 3_840,
            actualHeight: 1_080
        )) {
            try transition.classify(
                actualWidth: 3_840,
                actualHeight: 1_080,
                presentationTime: commitTime + CMTime(value: 1, timescale: 60),
                currentWidth: 4_096,
                currentHeight: 1_152
            )
        }
        #expect(transition.hasRetiredGeometry)
    }

    @Test("a subsequent commit replaces or clears the retired geometry")
    func handoffReplacementAndReset() throws {
        let commitTime = CMTime(seconds: 400, preferredTimescale: 60_000)
        var transition = CaptureFrameDimensionTransitionState()
        transition.commit(
            previousWidth: 5_120,
            previousHeight: 1_440,
            currentWidth: 4_096,
            currentHeight: 1_152,
            commitPresentationTime: commitTime,
            framesPerSecond: 60
        )
        transition.commit(
            previousWidth: 4_096,
            previousHeight: 1_152,
            currentWidth: 1_604,
            currentHeight: 1_108,
            commitPresentationTime: commitTime + CMTime(seconds: 1, preferredTimescale: 60_000),
            framesPerSecond: 30
        )

        #expect(throws: CaptureSessionError.invalidFrameDimensions(
            expectedWidth: 1_604,
            expectedHeight: 1_108,
            actualWidth: 5_120,
            actualHeight: 1_440
        )) {
            try transition.classify(
                actualWidth: 5_120,
                actualHeight: 1_440,
                presentationTime: commitTime + CMTime(seconds: 1.01, preferredTimescale: 60_000),
                currentWidth: 1_604,
                currentHeight: 1_108
            )
        }
        #expect(try transition.classify(
            actualWidth: 4_096,
            actualHeight: 1_152,
            presentationTime: commitTime + CMTime(seconds: 1.01, preferredTimescale: 60_000),
            currentWidth: 1_604,
            currentHeight: 1_108
        ) == .dropRetired)

        transition.commit(
            previousWidth: 1_604,
            previousHeight: 1_108,
            currentWidth: 1_604,
            currentHeight: 1_108,
            commitPresentationTime: commitTime + CMTime(seconds: 2, preferredTimescale: 60_000),
            framesPerSecond: 30
        )
        #expect(!transition.hasRetiredGeometry)
    }

    @Test("accepted and pressure-dropped frames are observable")
    func counter() {
        var counter = CaptureBackpressureCounter()
        counter.record(.accepted)
        counter.record(.accepted)
        counter.record(.droppedBackpressure)

        #expect(counter.statistics.deliveredFrames == 2)
        #expect(counter.statistics.backpressureDrops == 1)
    }

    @Test("bounded capture pressure does not surface as sustained overload")
    func transientBackpressure() {
        var monitor = CaptureBackpressureMonitor()
        var statistics = CaptureDeliveryStatistics()
        #expect(monitor.observe(statistics) == .nominal)

        // Four one-second samples at 50% drops remain below the production
        // five-sample sustained threshold.
        for _ in 0..<4 {
            statistics.deliveredFrames += 10
            statistics.backpressureDrops += 10
            #expect(monitor.observe(statistics) == .nominal)
        }

        // A healthy sample breaks the streak rather than merely pausing it.
        statistics.deliveredFrames += 20
        #expect(monitor.observe(statistics) == .nominal)
        statistics.deliveredFrames += 10
        statistics.backpressureDrops += 10
        #expect(monitor.observe(statistics) == .nominal)
    }

    @Test("five pressured samples warn and three healthy samples recover")
    func sustainedBackpressureAndRecovery() {
        var monitor = CaptureBackpressureMonitor()
        var statistics = CaptureDeliveryStatistics()
        _ = monitor.observe(statistics)

        for sample in 1...5 {
            statistics.deliveredFrames += 20
            statistics.backpressureDrops += 10
            let expected: CaptureBackpressureHealth = sample == 5
                ? .sustainedOverload
                : .nominal
            #expect(monitor.observe(statistics) == expected)
        }

        for sample in 1...3 {
            statistics.deliveredFrames += 30
            let expected: CaptureBackpressureHealth = sample == 3
                ? .nominal
                : .sustainedOverload
            #expect(monitor.observe(statistics) == expected)
        }
    }

    @Test("undersampled intervals do not create or clear overload")
    func undersampledBackpressure() {
        var monitor = CaptureBackpressureMonitor()
        var statistics = CaptureDeliveryStatistics()
        _ = monitor.observe(statistics)

        for _ in 0..<8 {
            statistics.deliveredFrames += 1
            statistics.backpressureDrops += 1
            #expect(monitor.observe(statistics) == .nominal)
        }

        for _ in 0..<5 {
            statistics.deliveredFrames += 20
            statistics.backpressureDrops += 10
            _ = monitor.observe(statistics)
        }
        #expect(monitor.health == .sustainedOverload)

        statistics.deliveredFrames += 2
        #expect(monitor.observe(statistics) == .sustainedOverload)
    }

    @Test("a cumulative counter reset cannot carry overload into a new session")
    func counterResetClearsOverload() {
        var monitor = CaptureBackpressureMonitor()
        var statistics = CaptureDeliveryStatistics()
        _ = monitor.observe(statistics)
        for _ in 0..<5 {
            statistics.deliveredFrames += 20
            statistics.backpressureDrops += 10
            _ = monitor.observe(statistics)
        }
        #expect(monitor.health == .sustainedOverload)

        #expect(monitor.observe(.init(deliveredFrames: 1, backpressureDrops: 0)) == .nominal)
    }

    @Test("configuration clamps invalid dimensions and cadence")
    func configurationClamping() {
        let value = CaptureVideoConfiguration(
            width: 0,
            height: -10,
            framesPerSecond: 0
        )
        #expect(value.width == 1)
        #expect(value.height == 1)
        #expect(value.framesPerSecond == 1)
    }
}
