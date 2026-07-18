import CoreMedia
import Testing
@testable import ClipMedia

@Suite("Media export configuration")
struct MediaConfigurationTests {
    @Test("Recording preserves pixel-aligned dimensions and caller quality")
    func recordingConfiguration() {
        let configuration = RecordingConfiguration(
            width: 1_441,
            height: 901,
            framesPerSecond: 60,
            videoQuality: 0.93
        )

        #expect(configuration.width == 1_440)
        #expect(configuration.height == 900)
        #expect(configuration.framesPerSecond == 60)
        #expect(configuration.videoQuality == 0.93)
    }

    @Test("Percent quality conversion is exact on the settings scale")
    func qualityPercentConversion() {
        #expect(MediaVideoQuality.normalized(percent: 98) == 0.98)
        #expect(MediaVideoQuality.normalized(percent: 90) == 0.90)
        #expect(MediaVideoQuality.normalized(percent: 85) == 0.85)
        #expect(MediaVideoQuality.percent(normalized: 0.98) == 98)

        let recording = RecordingConfiguration(
            width: 1_920,
            height: 1_080,
            videoQualityPercent: 91
        )
        #expect(recording.videoQuality == 0.91)
    }

    @Test("Every preset preserves native geometry and durable cadence")
    func presetsPreserveSourceFormat() {
        for preset in MediaExportPreset.allCases {
            let configuration = MediaExportConfigurationFactory.make(
                preset: preset,
                sourceWidth: 5_120,
                sourceHeight: 2_880,
                sourceFramesPerSecond: 60,
                videoQuality: 0.87,
                sourceVideoQuality: 0.98
            )

            #expect(configuration.width == 5_120)
            #expect(configuration.height == 2_880)
            #expect(configuration.framesPerSecond == 60)
            #expect(configuration.videoQuality == 0.87)
            #expect(configuration.sourceVideoQuality == 0.98)
            #expect(configuration.audioBitRate == 128_000)
        }
    }

    @Test("Factory does not impose preset quality values")
    func qualityIsCallerProvided() {
        let requestedQualities: [(MediaExportPreset, Int)] = [
            (.crisp, 98),
            (.compact, 90),
            (.smallest, 85),
        ]

        for (preset, percent) in requestedQualities {
            let configuration = MediaExportConfigurationFactory.make(
                preset: preset,
                sourceWidth: 2_560,
                sourceHeight: 1_440,
                sourceFramesPerSecond: 30,
                videoQualityPercent: percent,
                sourceVideoQualityPercent: 98
            )
            #expect(configuration.videoQuality == Double(percent) / 100)
            #expect(configuration.width == 2_560)
            #expect(configuration.height == 1_440)
            #expect(configuration.framesPerSecond == 30)
            #expect(configuration.audioBitRate == 128_000)
        }
    }

    @Test("Direct export configuration never silently rounds geometry")
    func directConfigurationKeepsExactGeometry() {
        let configuration = MediaExportConfiguration(
            preset: .compact,
            width: 1_441,
            height: 901,
            framesPerSecond: 29,
            videoQuality: 0.90
        )

        #expect(configuration.width == 1_441)
        #expect(configuration.height == 901)
        #expect(configuration.framesPerSecond == 29)
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
