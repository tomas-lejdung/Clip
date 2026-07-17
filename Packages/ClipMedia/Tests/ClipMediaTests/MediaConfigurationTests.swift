import CoreMedia
import Testing
@testable import ClipMedia

@Suite("Media export configuration")
struct MediaConfigurationTests {
    @Test("Recording dimensions are H.264-safe even values")
    func evenDimensions() {
        let configuration = RecordingConfiguration(width: 1_441, height: 901)
        #expect(configuration.width == 1_440)
        #expect(configuration.height == 900)
        #expect(configuration.videoBitRate == 8_553_600)
    }

    @Test("Capture master bitrate continues to scale for a later Crisp export")
    func highFidelityCaptureMaster() {
        let configuration = RecordingConfiguration(
            width: 3_840,
            height: 2_160,
            framesPerSecond: 60
        )

        #expect(configuration.videoBitRate == 109_486_080)
    }

    @Test("Compact uses the Full HD, 30 FPS, 6 Mbps envelope")
    func compactCaps() {
        let configuration = MediaExportConfigurationFactory.make(
            preset: .compact,
            sourceWidth: 5_120,
            sourceHeight: 2_880,
            sourceFramesPerSecond: 60,
            duration: 30
        )
        #expect(configuration.width == 1_920)
        #expect(configuration.height == 1_080)
        #expect(configuration.framesPerSecond == 30)
        #expect(configuration.videoBitRate == 3_421_440)
    }

    @Test("Crisp preserves detail with native dimensions, 60 FPS, and a much higher rate")
    func crispPreservesFrameRate() {
        let configuration = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: 2_560,
            sourceHeight: 1_440,
            sourceFramesPerSecond: 60,
            duration: 30
        )
        #expect(configuration.width == 2_560)
        #expect(configuration.height == 1_440)
        #expect(configuration.framesPerSecond == 60)
        #expect(configuration.videoBitRate == 44_236_800)
        #expect(configuration.audioBitRate == 192_000)
    }

    @Test("Crisp stays materially above Compact for a common interface recording")
    func crispIsMateriallyHigherQuality() {
        let compact = MediaExportConfigurationFactory.make(
            preset: .compact,
            sourceWidth: 1_440,
            sourceHeight: 900,
            sourceFramesPerSecond: 30,
            duration: 30
        )
        let crisp = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: 1_440,
            sourceHeight: 900,
            sourceFramesPerSecond: 30,
            duration: 30
        )

        #expect(compact.width == crisp.width)
        #expect(compact.height == crisp.height)
        #expect(compact.videoBitRate == 2_138_400)
        #expect(crisp.videoBitRate == 8_000_000)
        #expect(crisp.videoBitRate >= compact.videoBitRate * 3)
    }

    @Test("Crisp preserves arbitrary native geometry and pixel-scaled bitrate")
    func crispPreservesArbitraryNativeGeometry() {
        let fiveK = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: 5_120,
            sourceHeight: 2_880,
            sourceFramesPerSecond: 60,
            duration: 30
        )

        let portrait = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: 720,
            sourceHeight: 5_120,
            sourceFramesPerSecond: 30,
            duration: 30
        )
        let ultrawide = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: 6_000,
            sourceHeight: 800,
            sourceFramesPerSecond: 30,
            duration: 30
        )

        #expect(fiveK.width == 5_120)
        #expect(fiveK.height == 2_880)
        #expect(fiveK.framesPerSecond == 60)
        #expect(fiveK.videoBitRate == 176_947_200)

        #expect(portrait.width == 720)
        #expect(portrait.height == 5_120)
        #expect(portrait.videoBitRate == 22_118_400)

        #expect(ultrawide.width == 6_000)
        #expect(ultrawide.height == 800)
        #expect(ultrawide.videoBitRate == 28_800_000)
    }

    @Test("Smallest clamps custom targets")
    func smallestTargetClamping() {
        let low = MediaExportConfigurationFactory.make(
            preset: .smallest,
            sourceWidth: 1_920,
            sourceHeight: 1_080,
            sourceFramesPerSecond: 30,
            duration: 60,
            approximateTargetMegabytes: -10
        )
        let high = MediaExportConfigurationFactory.make(
            preset: .smallest,
            sourceWidth: 1_920,
            sourceHeight: 1_080,
            sourceFramesPerSecond: 30,
            duration: 60,
            approximateTargetMegabytes: 900
        )
        #expect(low.approximateTargetBytes == 1_000_000)
        #expect(high.approximateTargetBytes == 500_000_000)
        #expect(low.framesPerSecond == 24)
    }

    @Test("Size estimate follows effective stream rates and selected duration")
    func outputSizeEstimateFollowsRateAndDuration() {
        let configuration = MediaExportConfigurationFactory.make(
            preset: .compact,
            sourceWidth: 1_440,
            sourceHeight: 900,
            sourceFramesPerSecond: 30,
            duration: 10
        )
        let full = MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: 10,
            includesAudio: false
        )
        let half = MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: 5,
            includesAudio: false
        )

        #expect(full.effectiveVideoBitRate == 2_138_400)
        #expect(full.effectiveAudioBitRate == 0)
        #expect(full.estimatedContainerBitRate == 21_384)
        #expect(full.byteCount == 2_699_730)
        #expect(half.byteCount * 2 == full.byteCount)
        #expect(full.width == 1_440)
        #expect(full.height == 900)
        #expect(full.framesPerSecond == 30)
    }

    @Test("Size estimate includes one encoded AAC track when source has audio")
    func outputSizeEstimateIncludesAudio() {
        let configuration = MediaExportConfigurationFactory.make(
            preset: .compact,
            sourceWidth: 1_440,
            sourceHeight: 900,
            sourceFramesPerSecond: 30,
            duration: 10
        )
        let silent = MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: 10,
            includesAudio: false
        )
        let withAudio = MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: 10,
            includesAudio: true
        )

        #expect(withAudio.effectiveAudioBitRate == 128_000)
        #expect(withAudio.byteCount > silent.byteCount)
    }

    @Test("Size estimate is calibrated by the managed master's observed size")
    func outputSizeEstimateUsesObservedSourceRate() {
        let configuration = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: 2_480,
            sourceHeight: 1_202,
            sourceFramesPerSecond: 30,
            duration: 44.423333
        )

        let full = MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: 44.423333,
            includesAudio: true,
            sourceByteCount: 6_764_697,
            sourceDuration: 44.423333
        )
        let half = MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: 22.2116665,
            includesAudio: true,
            sourceByteCount: 6_764_697,
            sourceDuration: 44.423333
        )
        let withoutAudio = MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: 44.423333,
            includesAudio: false,
            sourceByteCount: 6_764_697,
            sourceDuration: 44.423333,
            sourceIncludesAudio: true
        )

        #expect(full.byteCount == 6_764_697)
        #expect(half.byteCount == 3_382_349)
        #expect(withoutAudio.byteCount == 5_698_537)
        #expect(full.effectiveVideoBitRate > 15_000_000)
    }

    @Test("Invalid or unavailable source observations preserve the rate-plan estimate")
    func outputSizeEstimateFallsBackToRatePlan() {
        let configuration = MediaExportConfigurationFactory.make(
            preset: .compact,
            sourceWidth: 1_440,
            sourceHeight: 900,
            sourceFramesPerSecond: 30,
            duration: 10
        )
        let baseline = MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: 10,
            includesAudio: false
        )
        let invalid = MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: 10,
            includesAudio: false,
            sourceByteCount: 1_000,
            sourceDuration: 0
        )

        #expect(invalid == baseline)
    }

    @Test("Crisp estimate follows a compatible master even above its nominal rate plan")
    func crispEstimateUsesHigherObservedSourceSize() {
        let configuration = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: 2_028,
            sourceHeight: 1_220,
            sourceFramesPerSecond: 30,
            duration: 21.598333
        )
        let planned = MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: 21.598333,
            includesAudio: true
        )
        let observedSourceBytes = planned.byteCount + 2_000_000
        let calibrated = MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: 21.598333,
            includesAudio: true,
            sourceByteCount: observedSourceBytes,
            sourceDuration: 21.598333,
            sourceIncludesAudio: true
        )

        #expect(calibrated.byteCount == observedSourceBytes)
        #expect(calibrated.byteCount > planned.byteCount)
    }

    @Test("Smallest estimate uses the exporter's soft target limiter and bitrate caps")
    func smallestEstimateUsesEffectiveRate() {
        let attainable = MediaExportConfigurationFactory.make(
            preset: .smallest,
            sourceWidth: 1_920,
            sourceHeight: 1_080,
            sourceFramesPerSecond: 30,
            duration: 60,
            approximateTargetMegabytes: 10
        )
        let attainableEstimate = MediaExportSizeEstimator.estimate(
            configuration: attainable,
            duration: 60,
            includesAudio: true
        )

        let capped = MediaExportConfigurationFactory.make(
            preset: .smallest,
            sourceWidth: 1_920,
            sourceHeight: 1_080,
            sourceFramesPerSecond: 30,
            duration: 1,
            approximateTargetMegabytes: 10
        )
        let cappedEstimate = MediaExportSizeEstimator.estimate(
            configuration: capped,
            duration: 1,
            includesAudio: true
        )

        #expect(attainableEstimate.byteCount == 9_999_998)
        #expect(attainableEstimate.effectiveVideoBitRate == 1_221_333)
        #expect(cappedEstimate.effectiveVideoBitRate == 6_000_000)
        #expect(cappedEstimate.byteCount < 1_000_000)
    }
}

@Suite("Sample timeline")
struct SampleTimelineTests {
    private let tick = CMTime(value: 1, timescale: 600)

    private func time(_ seconds: Int64) -> CMTime {
        CMTime(value: seconds * 600, timescale: 600)
    }

    @Test("Delayed callbacks inside a completed pause are still dropped")
    func delayedCallbacksAreDropped() throws {
        var timeline = SampleTimeline()
        try timeline.pause(at: time(3))

        // A callback delivered while capture is actively paused is dropped.
        #expect(timeline.outputTime(for: time(4)) == nil)
        try timeline.resume(at: time(8))

        // A resumed video callback may arrive before older audio/video
        // callbacks. Arrival order must not allow paused samples through.
        #expect(timeline.outputTime(for: time(10)) == time(5))
        #expect(timeline.outputTime(for: time(4)) == nil)
        #expect(timeline.outputTime(for: time(7)) == nil)

        // A delayed pre-pause callback is retained without subtracting a pause
        // that had not happened at its source timestamp.
        #expect(timeline.outputTime(for: time(2)) == time(2))
        #expect(timeline.accumulatedPauseDuration == time(5))
    }

    @Test("Pause intervals use half-open boundary semantics")
    func exactBoundaries() throws {
        var timeline = SampleTimeline()
        try timeline.pause(at: time(3))
        try timeline.resume(at: time(8))

        #expect(timeline.outputTime(for: time(3) - tick) == time(3) - tick)
        #expect(timeline.outputTime(for: time(3)) == nil)
        #expect(timeline.outputTime(for: time(8) - tick) == nil)
        #expect(timeline.outputTime(for: time(8)) == time(3))

        // A zero-duration pause is an empty half-open interval and therefore
        // drops no timestamp.
        try timeline.pause(at: time(10))
        try timeline.resume(at: time(10))
        #expect(timeline.outputTime(for: time(10)) == time(5))
        #expect(timeline.accumulatedPauseDuration == time(5))
    }

    @Test("Multiple pauses map samples using only preceding intervals")
    func multiplePauses() throws {
        var timeline = SampleTimeline()
        try timeline.pause(at: time(3))
        try timeline.resume(at: time(5))
        try timeline.pause(at: time(8))
        try timeline.resume(at: time(11))

        #expect(timeline.outputTime(for: time(2)) == time(2))
        #expect(timeline.outputTime(for: time(3)) == nil)
        #expect(timeline.outputTime(for: time(4)) == nil)
        #expect(timeline.outputTime(for: time(5)) == time(3))
        #expect(timeline.outputTime(for: time(7)) == time(5))
        #expect(timeline.outputTime(for: time(8)) == nil)
        #expect(timeline.outputTime(for: time(10)) == nil)
        #expect(timeline.outputTime(for: time(11)) == time(6))
        #expect(timeline.outputTime(for: time(12)) == time(7))

        // Start a third pause and verify active-window and delayed lookups.
        try timeline.pause(at: time(14))
        #expect(timeline.outputTime(for: time(14)) == nil)
        #expect(timeline.outputTime(for: time(20)) == nil)
        #expect(timeline.outputTime(for: time(12)) == time(7))
        #expect(timeline.outputTime(for: time(9)) == nil)
    }

    @Test("Kept output timestamps remain monotonic across many pauses")
    func monotonicOutputs() throws {
        var timeline = SampleTimeline()
        for index in 0..<128 {
            let pause = Int64(index * 4 + 2)
            try timeline.pause(at: time(pause))
            try timeline.resume(at: time(pause + 2))
        }

        var previousOutput: CMTime?
        for sourceSecond in 0...512 {
            let sourceTime = time(Int64(sourceSecond))
            guard let outputTime = timeline.outputTime(for: sourceTime) else {
                continue
            }
            if let previousOutput {
                #expect(outputTime >= previousOutput)
            }
            previousOutput = outputTime
        }

        #expect(timeline.accumulatedPauseDuration == time(256))
        #expect(timeline.outputTime(for: time(512)) == time(256))
    }

    @Test("Invalid pause transitions fail")
    func invalidTransitions() throws {
        var timeline = SampleTimeline()
        #expect(throws: SampleTimelineError.notPaused) {
            try timeline.resume(at: .zero)
        }
        #expect(throws: SampleTimelineError.invalidSourceTime) {
            try timeline.pause(at: .invalid)
        }

        try timeline.pause(at: time(5))
        #expect(throws: SampleTimelineError.alreadyPaused) {
            try timeline.pause(at: time(6))
        }
        #expect(throws: SampleTimelineError.resumeBeforePause) {
            try timeline.resume(at: time(4))
        }
        #expect(throws: SampleTimelineError.invalidSourceTime) {
            try timeline.resume(at: .indefinite)
        }

        // Failed resumes do not mutate the active pause.
        #expect(timeline.isPaused)
        try timeline.resume(at: time(8))
        #expect(!timeline.isPaused)

        // Completed intervals must remain chronological and non-overlapping.
        #expect(throws: SampleTimelineError.pauseBeforePreviousResume) {
            try timeline.pause(at: time(7))
        }
        #expect(!timeline.isPaused)
        #expect(timeline.accumulatedPauseDuration == time(3))
        #expect(timeline.outputTime(for: .invalid) == nil)
    }
}
