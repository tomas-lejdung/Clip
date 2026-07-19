import Testing
@testable import ClipCapture

@Suite("Capture geometry and delivery policy")
struct CaptureGeometryTests {
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
