@preconcurrency import AVFoundation
@preconcurrency import VideoToolbox
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ClipMedia

@Suite("Native media pipeline", .serialized)
struct NativeMediaPipelineTests {
    @Test("Native and scaled CRF processing preserve variable timing and full source")
    func processesNativeAndScaledRecording() async throws {
        let source = temporaryURL(named: "processor-source")
        let directory = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: directory) }
        try await writeIrregularSyntheticVideo(to: source)
        let original = try Data(contentsOf: source)
        let originalTimes = try await videoPresentationTimes(in: source)
        let processor = RecordingProcessor(executableURL: try recordingEncoderForTests())
        let sourceInfo = try await MediaInspector.inspect(source)
        for scale in [100, 75, 50, 25] {
            let output = directory.appendingPathComponent("\(scale).mp4")
            let configuration = RecordingProcessingConfiguration(scalePercent: scale)
            let result = try await processor.process(sourceURL: source, destinationURL: output,
                                                     configuration: configuration)
            let size = try configuration.dimensions(width: sourceInfo.width, height: sourceInfo.height)
            #expect(result.inspection.videoCodec == kCMVideoCodecType_H264)
            #expect(result.inspection.width == size.width && result.inspection.height == size.height)
            #expect(result.processingSeconds >= result.encodingSeconds)
            let actualTimes = try await videoPresentationTimes(in: output)
            #expect(actualTimes.count == originalTimes.count)
            for (before, after) in zip(originalTimes, actualTimes) { #expect(abs(before - after) < 0.000020) }
            #expect(try Data(contentsOf: source) == original)
        }
    }

    @Test("Processed H.264 supports arbitrary-frame trim and independent copies")
    func trimsProcessedRecordingWithoutQualityLoss() async throws {
        let source = temporaryURL(named: "processor-trim-source")
        let processed = temporaryURL(named: "processor-trim-master")
        let trimmed = temporaryURL(named: "processor-trim-output")
        let full = temporaryURL(named: "processor-copy-output")
        defer { for url in [source, processed, trimmed, full] { try? FileManager.default.removeItem(at: url) } }
        try await writeSyntheticVideo(to: source, width: 320, height: 180, frameCount: 60, framesPerSecond: 30)
        _ = try await RecordingProcessor(executableURL: recordingEncoderForTests())
            .process(sourceURL: source, destinationURL: processed)
        let original = try Data(contentsOf: processed)
        let configuration = MediaExportConfiguration(width: 320, height: 180, framesPerSecond: 30)
        _ = try await NativeAssetExporter().export(sourceURL: processed, destinationURL: full,
                                                  timeRange: nil, configuration: configuration)
        #expect(try Data(contentsOf: full) == original)
        for range in [
            CMTimeRange(start: CMTime(value: 7, timescale: 30), duration: CMTime(value: 23, timescale: 30)),
            CMTimeRange(start: CMTime(value: 247, timescale: 1000), duration: CMTime(value: 743, timescale: 1000)),
        ] {
            _ = try await NativeAssetExporter().export(sourceURL: processed, destinationURL: trimmed,
                                                      timeRange: range, configuration: configuration)
            let before = try await MediaFrameVerifier.pixels(asset: AVURLAsset(url: processed), at: range.start)
            let after = try await MediaFrameVerifier.pixels(asset: AVURLAsset(url: trimmed), at: .zero)
            #expect(before == after)
            #expect(abs(try await MediaInspector.inspect(trimmed).duration - range.duration.seconds) < 0.002)
        }
        #expect(try Data(contentsOf: processed) == original)
    }

    @Test("Repeated trims inside long static holds preserve the selected first frame")
    func repeatedlyTrimsStaticScreenHolds() async throws {
        let source = temporaryURL(named: "static-trim-capture")
        let processed = temporaryURL(named: "static-trim-source")
        let output = temporaryURL(named: "static-trim-output")
        defer { for url in [source, processed, output] { try? FileManager.default.removeItem(at: url) } }
        let writer = try AssetWriterSession(outputURL: source,
            configuration: .init(width: 320, height: 180))
        try writer.start()
        let times = [0.0, 3.0, 9.0, 15.0, 20.0]
        for (index, time) in times.enumerated() {
            try appendWithRetry(makeVideoSample(width: 320, height: 180, frameIndex: index,
                framesPerSecond: 30, pattern: .animatedScreen,
                presentationTime: CMTime(seconds: time, preferredTimescale: 60000),
                sampleDuration: CMTime(seconds: index + 1 < times.count ? times[index + 1] - time : 0.1,
                    preferredTimescale: 60000)), to: writer)
        }
        _ = try await writer.finish()
        _ = try await RecordingProcessor(executableURL: recordingEncoderForTests())
            .process(sourceURL: source, destinationURL: processed)
        let sourceBytes = try Data(contentsOf: processed)
        let configuration = MediaExportConfiguration(width: 320, height: 180, framesPerSecond: 30)
        for (start, end) in [(1.3725, 18.9201), (4.17, 8.81), (10.32, 18.89), (2.9999, 18.9), (0.07, 19.99)] {
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                end: CMTime(seconds: end, preferredTimescale: 60000))
            _ = try await NativeAssetExporter().export(sourceURL: processed, destinationURL: output,
                timeRange: range, configuration: configuration)
            let before = try await MediaFrameVerifier.pixels(asset: AVURLAsset(url: processed), at: range.start)
            let after = try await MediaFrameVerifier.pixels(asset: AVURLAsset(url: output), at: .zero)
            #expect(before == after)
            #expect(abs(try await MediaInspector.inspect(output).duration - range.duration.seconds) < 0.002)
        }
        #expect(try Data(contentsOf: processed) == sourceBytes)
    }

    @Test("Initial processing mixes system and microphone once; export can remove audio")
    func processesRecordedAudio() async throws {
        let source = temporaryURL(named: "processor-audio-source")
        let output = temporaryURL(named: "processor-audio-master")
        let silent = temporaryURL(named: "processor-audio-silent")
        defer { for url in [source, output, silent] { try? FileManager.default.removeItem(at: url) } }
        try await writeSyntheticVideoWithAudio(to: source)
        let result = try await RecordingProcessor(executableURL: recordingEncoderForTests())
            .process(sourceURL: source, destinationURL: output)
        #expect(result.inspection.audioTrackCount == 1)
        let alignment = try await audioVideoAlignment(in: output)
        #expect(alignment.maximumStartDelta <= 0.05)
        #expect(alignment.maximumEndDelta <= 0.05)
        _ = try await NativeAssetExporter().export(sourceURL: output, destinationURL: silent, timeRange: nil,
            configuration: .init(width: 320, height: 180, framesPerSecond: 30, includesAudio: false))
        #expect(try await MediaInspector.inspect(silent).audioTrackCount == 0)
    }

    @Test("Export clamps only a sub-tick endpoint rounding error")
    func preservesFractionalFinalEndpoint() async throws {
        let source = temporaryURL(named: "fractional-endpoint-source")
        let output = temporaryURL(named: "fractional-endpoint-output")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        try await writeIrregularSyntheticVideo(to: source)
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let info = try await MediaInspector.inspect(source)
        let configuration = MediaExportConfiguration(width: info.width, height: info.height, framesPerSecond: 30)
        let original = try Data(contentsOf: source)
        let roundedEnd = duration + CMTime(value: 1, timescale: 90_000)
        _ = try await NativeAssetExporter().export(sourceURL: source, destinationURL: output,
            timeRange: CMTimeRange(start: .zero, end: roundedEnd), configuration: configuration)
        #expect(try Data(contentsOf: output) == original)
        let start = CMTime(value: 77, timescale: 1000)
        _ = try await NativeAssetExporter().export(sourceURL: source, destinationURL: output,
            timeRange: CMTimeRange(start: start, end: roundedEnd), configuration: configuration)
        #expect(abs(try await MediaInspector.inspect(output).duration - (duration - start).seconds) < 0.002)
        let before = try await MediaFrameVerifier.pixels(asset: asset, at: start)
        let after = try await MediaFrameVerifier.pixels(asset: AVURLAsset(url: output), at: .zero)
        #expect(before == after)
        await #expect(throws: NativeAssetExporterError.invalidTimeRange) {
            try await NativeAssetExporter().export(sourceURL: source, destinationURL: output,
                timeRange: CMTimeRange(start: start, end: duration + CMTime(value: 2, timescale: 60_000)),
                configuration: configuration)
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test("Processing preserves a long final static hold without MP4 timebase overflow")
    func processesLongStaticHold() async throws {
        let source = temporaryURL(named: "processor-static-source")
        let output = temporaryURL(named: "processor-static-output")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let writer = try AssetWriterSession(outputURL: source,
            configuration: .init(width: 320, height: 180))
        try writer.start()
        try appendWithRetry(makeVideoSample(width: 320, height: 180, frameIndex: 0,
            framesPerSecond: 30, presentationTime: CMTime(seconds: 100, preferredTimescale: 60000)), to: writer)
        _ = try await writer.finish(at: CMTime(seconds: 112, preferredTimescale: 60000))
        let result = try await RecordingProcessor(executableURL: recordingEncoderForTests())
            .process(sourceURL: source, destinationURL: output)
        #expect(abs(result.inspection.duration - 12) < 0.002)
        let originalTimes = try await videoPresentationTimes(in: source)
        let outputTimes = try await videoPresentationTimes(in: output)
        #expect(originalTimes == outputTimes)
        #expect(outputTimes.last! > 11.9)
    }

    @Test("Audio mixing preserves a delayed microphone start and a dropped-buffer gap", arguments: [48_000, 44_100])
    func preservesAudioContentTiming(sampleRate: Int) async throws {
        let source = temporaryURL(named: "processor-staggered-source")
        let output = temporaryURL(named: "processor-staggered-output")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let writer = try AssetWriterSession(outputURL: source,
            configuration: .init(width: 320, height: 180, audioMode: .microphoneAndSystem))
        try writer.start()
        let audioFramesPerVideoFrame = sampleRate / 30
        for frame in 0..<60 {
            try appendWithRetry(makeVideoSample(width: 320, height: 180,
                frameIndex: frame, framesPerSecond: 30), to: writer)
            try appendWithRetry(makeAudioSample(startFrame: frame * audioFramesPerVideoFrame,
                frameCount: audioFramesPerVideoFrame, frequency: 440, sampleRate: Double(sampleRate)), kind: .systemAudio, to: writer)
            if frame >= 15 && !(30..<39).contains(frame) {
                try appendWithRetry(makeAudioSample(startFrame: frame * audioFramesPerVideoFrame,
                    frameCount: audioFramesPerVideoFrame, frequency: 880, sampleRate: Double(sampleRate)), kind: .microphone, to: writer)
            }
        }
        _ = try await writer.finish()
        let captured = try await decodedAudioChannel(source, trackIndex: 1)
        #expect(toneAmplitude(captured, frequency: 880, start: 1.1, end: 1.2) < 0.003)
        _ = try await RecordingProcessor(executableURL: recordingEncoderForTests())
            .process(sourceURL: source, destinationURL: output)
        let samples = try await decodedAudioChannel(output)
        // Read audible content, not merely matching container start/end times.
        #expect(toneAmplitude(samples, frequency: 880, start: 0.2, end: 0.3) < 0.003)
        #expect(toneAmplitude(samples, frequency: 880, start: 0.65, end: 0.75) > 0.03)
        #expect(toneAmplitude(samples, frequency: 880, start: 1.1, end: 1.2) < 0.003)
        #expect(toneAmplitude(samples, frequency: 880, start: 1.5, end: 1.6) > 0.03)
    }

    @Test("Cancelled processing preserves an existing output and its original")
    func cancellationPreservesMedia() async throws {
        let source = temporaryURL(named: "processor-cancel-source")
        let output = temporaryURL(named: "processor-cancel-output")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        try await writeSyntheticVideo(to: source, width: 320, height: 180, frameCount: 30, framesPerSecond: 30)
        let before = try Data(contentsOf: source)
        let sentinel = Data("existing complete candidate".utf8)
        try sentinel.write(to: output)
        let helper = source.deletingLastPathComponent().appendingPathComponent("encoder-cancel-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: helper) }
        // An actual child process emits progress, then remains alive until
        // cancellation. exec avoids leaving a grandchild behind after SIGTERM.
        try Data("#!/bin/sh\nprintf 'out_time_us=100000\\n'\nexec /bin/sleep 30\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let processor = RecordingProcessor(executableURL: helper)
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { continuation.finish() }
            return try await processor.process(sourceURL: source, destinationURL: output) { progress in
                if (progress.fraction ?? 0) > 0 { continuation.yield(()); continuation.finish() }
            }
        }
        for await _ in events { break }
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ProcessInfo.processInfo.systemUptime - cancelledAt < 3)
        #expect(try Data(contentsOf: source) == before)
        #expect(try Data(contentsOf: output) == sentinel)
    }

    @Test("Synthetic frames produce an inspectable HEVC MP4")
    func writesSyntheticMP4() async throws {
        let outputURL = temporaryURL(named: "writer")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try await writeSyntheticVideo(
            to: outputURL,
            width: 320,
            height: 180,
            frameCount: 30,
            framesPerSecond: 30
        )

        let inspection = try await MediaInspector.inspect(outputURL)
        #expect(inspection.fileSize > 0)
        #expect(inspection.videoTrackCount == 1)
        #expect(inspection.audioTrackCount == 0)
        #expect(inspection.width == 320)
        #expect(inspection.height == 180)
        #expect(abs(inspection.duration - 1) <= (1.0 / 30.0))
        #expect(inspection.videoCodec == kCMVideoCodecType_HEVC)
    }

    @Test("The writer produces playable HEVC across a two-hour synthetic timestamp span")
    func writesMultiHourSyntheticTimeline() async throws {
        let outputURL = temporaryURL(named: "writer-two-hour-soak")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let framesPerSecond = 30
        let writer = try AssetWriterSession(
            outputURL: outputURL,
            configuration: RecordingConfiguration(
                width: 160,
                height: 90,
                framesPerSecond: framesPerSecond,
                showsCursor: false,
                audioMode: .off
            )
        )
        try writer.start()
        for minute in 0...120 {
            let timestampFrame = minute * 60 * framesPerSecond
            try appendWithRetry(
                makeVideoSample(
                    width: 160,
                    height: 90,
                    frameIndex: timestampFrame,
                    framesPerSecond: framesPerSecond
                ),
                to: writer
            )
        }
        _ = try await writer.finish()

        let inspection = try await MediaInspector.inspect(outputURL)
        #expect(inspection.videoCodec == kCMVideoCodecType_HEVC)
        #expect(inspection.width == 160)
        #expect(inspection.height == 90)
        #expect(inspection.duration >= 2 * 60 * 60)
        #expect(inspection.duration < 2 * 60 * 60 + 1)
        #expect(try await countVideoSamples(in: outputURL) == 121)
    }

    @Test("Queued audio before first video and nonmonotonic input timestamps are dropped")
    func dropsQueuedAudioPrerollAndNonmonotonicTimestamps() async throws {
        let outputURL = temporaryURL(named: "queued-audio-preroll")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let writer = try AssetWriterSession(
            outputURL: outputURL,
            configuration: RecordingConfiguration(
                width: 320,
                height: 180,
                framesPerSecond: 30,
                showsCursor: false,
                audioMode: .system
            )
        )
        try writer.start()

        // The first video source timestamp defines output time zero.
        try appendWithRetry(
            makeVideoSample(
                width: 320,
                height: 180,
                frameIndex: 30,
                framesPerSecond: 30
            ),
            to: writer
        )

        // These callbacks were captured before video but delivered after the
        // writer session opened. Neither may be clamped and appended at zero.
        #expect(try !writer.append(
            makeAudioSample(startFrame: 47_000, frameCount: 240, frequency: 440),
            kind: .systemAudio
        ))
        #expect(try !writer.append(
            makeAudioSample(startFrame: 47_500, frameCount: 240, frequency: 440),
            kind: .systemAudio
        ))

        try appendWithRetry(
            makeAudioSample(startFrame: 48_000, frameCount: 480, frequency: 440),
            kind: .systemAudio,
            to: writer
        )
        try appendWithRetry(
            makeAudioSample(startFrame: 48_960, frameCount: 480, frequency: 440),
            kind: .systemAudio,
            to: writer
        )

        // Duplicate and backwards PTS on the same input are rejected before
        // AVAssetWriter can enter a terminal state.
        #expect(try !writer.append(
            makeAudioSample(startFrame: 48_960, frameCount: 240, frequency: 440),
            kind: .systemAudio
        ))
        #expect(try !writer.append(
            makeAudioSample(startFrame: 48_480, frameCount: 240, frequency: 440),
            kind: .systemAudio
        ))

        for frameIndex in 31...33 {
            try appendWithRetry(
                makeVideoSample(
                    width: 320,
                    height: 180,
                    frameIndex: frameIndex,
                    framesPerSecond: 30
                ),
                to: writer
            )
        }
        _ = try await writer.finish()

        let inspection = try await MediaInspector.inspect(outputURL)
        #expect(inspection.videoTrackCount == 1)
        #expect(inspection.audioTrackCount == 1)
        #expect(inspection.duration > 0)
    }

    @Test("Video timestamp failures are visible while pause and optional-audio drops stay classified")
    func classifiesLiveWriterTimestampOutcomes() async throws {
        let outputURL = temporaryURL(named: "classified-writer-timestamps")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let framesPerSecond = 30
        let writer = try AssetWriterSession(
            outputURL: outputURL,
            configuration: RecordingConfiguration(
                width: 320,
                height: 180,
                framesPerSecond: framesPerSecond,
                showsCursor: false,
                audioMode: .system
            )
        )
        try writer.start()

        #expect(try writer.appendClassified(
            makeAudioSample(startFrame: 47_000, frameCount: 240, frequency: 440),
            kind: .systemAudio
        ) == .intentionallyDropped(.preRoll))

        let firstVideo = try makeVideoSample(
            width: 320,
            height: 180,
            frameIndex: 30,
            framesPerSecond: framesPerSecond
        )
        #expect(try writer.appendClassified(firstVideo, kind: .video) == .appended)

        do {
            _ = try writer.appendClassified(firstVideo, kind: .video)
            Issue.record("Expected a duplicate complete video timestamp to fail")
        } catch AssetWriterSessionError.appendFailed(let message) {
            #expect(message == "The screen frame presentation timestamp did not advance.")
        }

        do {
            _ = try writer.appendClassified(
                makeVideoSample(
                    width: 320,
                    height: 180,
                    frameIndex: 29,
                    framesPerSecond: framesPerSecond
                ),
                kind: .video
            )
            Issue.record("Expected delayed pre-anchor video to fail")
        } catch AssetWriterSessionError.appendFailed(let message) {
            #expect(
                message
                    == "The screen frame presentation timestamp preceded the recording anchor."
            )
        }

        let firstAudio = try makeAudioSample(
            startFrame: 48_000,
            frameCount: 480,
            frequency: 440
        )
        #expect(try writer.appendClassified(firstAudio, kind: .systemAudio) == .appended)
        #expect(try writer.appendClassified(
            firstAudio,
            kind: .systemAudio
        ) == .intentionallyDropped(.optionalAudioNonmonotonic))

        try writer.pause(at: CMTime(value: 32, timescale: 30))
        #expect(try writer.appendClassified(
            makeVideoSample(
                width: 320,
                height: 180,
                frameIndex: 32,
                framesPerSecond: framesPerSecond
            ),
            kind: .video
        ) == .intentionallyDropped(.paused))
        try writer.resume(at: CMTime(value: 33, timescale: 30))

        for frameIndex in [31, 33, 34] {
            #expect(try writer.appendClassified(
                makeVideoSample(
                    width: 320,
                    height: 180,
                    frameIndex: frameIndex,
                    framesPerSecond: framesPerSecond
                ),
                kind: .video
            ) == .appended)
        }
        _ = try await writer.finish()

        let inspection = try await MediaInspector.inspect(outputURL)
        #expect(inspection.videoTrackCount == 1)
        #expect(inspection.audioTrackCount == 1)
    }

    @Test("The direct live encoder preserves every irregular 60 FPS source timestamp")
    func preservesIrregularSixtyFPSTimestamps() async throws {
        let outputURL = temporaryURL(named: "writer-irregular-60fps-timestamps")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let framesPerSecond = 60
        let sourceMilliseconds: [Int64] = [10_000, 10_016, 10_051, 10_067]
        let writer = try AssetWriterSession(
            outputURL: outputURL,
            configuration: RecordingConfiguration(
                width: 320,
                height: 180,
                framesPerSecond: framesPerSecond,
                showsCursor: false,
                audioMode: .off
            )
        )
        try writer.start()

        for (frameIndex, milliseconds) in sourceMilliseconds.enumerated() {
            #expect(try writer.appendClassified(
                makeVideoSample(
                    width: 320,
                    height: 180,
                    frameIndex: frameIndex,
                    framesPerSecond: framesPerSecond,
                    pattern: .complex,
                    presentationTime: CMTime(
                        value: CMTimeValue(milliseconds),
                        timescale: 1_000
                    )
                ),
                kind: .video
            ) == .appended)
        }
        _ = try await writer.finish()

        let outputTimes = try await videoPresentationTimes(in: outputURL)
        let originalTimes = sourceMilliseconds.map {
            Double($0 - sourceMilliseconds[0]) / 1_000
        }
        let heldTime = originalTimes[1] + (1.0 / Double(framesPerSecond))
        let expectedTimes = [
            originalTimes[0],
            originalTimes[1],
            heldTime,
            originalTimes[2],
            originalTimes[3],
        ]
        #expect(outputTimes.count == expectedTimes.count)
        for (output, expected) in zip(outputTimes, expectedTimes) {
            #expect(abs(output - expected) <= 0.001)
        }

        // This includes the same 35 ms source gap seen at 60 FPS. The bounded
        // held frame bridges it, while every original PTS remains unchanged.
        for originalTime in originalTimes {
            #expect(outputTimes.contains { abs($0 - originalTime) <= 0.001 })
        }
        let outputGaps = zip(outputTimes, outputTimes.dropFirst()).map { $1 - $0 }
        #expect(outputGaps.count == sourceMilliseconds.count)
        #expect(
            (outputGaps.max() ?? 0)
                <= (2.0 / Double(framesPerSecond)) + 0.001
        )
    }

    @Test(
        "Pause seams hold one prior frame without moving original 30/60 FPS timestamps",
        arguments: [30, 60]
    )
    func completesPauseResumeCadenceSeam(framesPerSecond: Int) async throws {
        let outputURL = temporaryURL(
            named: "writer-pause-seam-\(framesPerSecond)fps"
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let writer = try AssetWriterSession(
            outputURL: outputURL,
            configuration: RecordingConfiguration(
                width: 320,
                height: 180,
                framesPerSecond: framesPerSecond,
                showsCursor: false,
                audioMode: .off
            )
        )
        let tenthsOfAFrameScale = CMTimeScale(framesPerSecond * 10)
        let firstSourceTime = CMTime(
            value: CMTimeValue(framesPerSecond * 100),
            timescale: tenthsOfAFrameScale
        )
        let pauseSourceTime = firstSourceTime + CMTime(
            value: 5,
            timescale: tenthsOfAFrameScale
        )
        let resumeSourceTime = pauseSourceTime + CMTime(
            value: CMTimeValue(tenthsOfAFrameScale),
            timescale: tenthsOfAFrameScale
        )
        // After pause removal this lands 2.1 nominal intervals after the
        // retained pre-pause frame, matching the observed 70/35 ms seams.
        let firstResumedSourceTime = resumeSourceTime + CMTime(
            value: 16,
            timescale: tenthsOfAFrameScale
        )
        let followingSourceTime = firstResumedSourceTime + CMTime(
            value: 10,
            timescale: tenthsOfAFrameScale
        )

        try writer.start()
        #expect(try writer.appendClassified(
            makeVideoSample(
                width: 320,
                height: 180,
                frameIndex: 0,
                framesPerSecond: framesPerSecond,
                pattern: .complex,
                presentationTime: firstSourceTime
            ),
            kind: .video
        ) == .appended)

        try writer.pause(at: pauseSourceTime)
        #expect(try writer.appendClassified(
            makeVideoSample(
                width: 320,
                height: 180,
                frameIndex: 1,
                framesPerSecond: framesPerSecond,
                pattern: .complex,
                presentationTime: pauseSourceTime + CMTime(
                    value: 1,
                    timescale: tenthsOfAFrameScale
                )
            ),
            kind: .video
        ) == .intentionallyDropped(.paused))
        try writer.resume(at: resumeSourceTime)

        for (frameIndex, presentationTime) in [
            firstResumedSourceTime,
            followingSourceTime,
        ].enumerated() {
            #expect(try writer.appendClassified(
                makeVideoSample(
                    width: 320,
                    height: 180,
                    frameIndex: frameIndex + 2,
                    framesPerSecond: framesPerSecond,
                    pattern: .complex,
                    presentationTime: presentationTime
                ),
                kind: .video
            ) == .appended)
        }
        _ = try await writer.finish()

        let outputTimes = try await videoPresentationTimes(in: outputURL)
        let interval = 1.0 / Double(framesPerSecond)
        let expectedTimes = [0, interval, 2.1 * interval, 3.1 * interval]
        #expect(outputTimes.count == expectedTimes.count)
        for (output, expected) in zip(outputTimes, expectedTimes) {
            #expect(abs(output - expected) <= 0.001)
        }

        let maximumGap = zip(outputTimes, outputTimes.dropFirst())
            .map { $1 - $0 }
            .max() ?? 0
        #expect(maximumGap <= (2 * interval) + 0.001)

        // The inserted held frame is additional; every original accepted PTS
        // remains present as an exact subsequence after pause retiming.
        let originalOutputTimes = [0, 2.1 * interval, 3.1 * interval]
        for originalTime in originalOutputTimes {
            #expect(outputTimes.contains { abs($0 - originalTime) <= 0.001 })
        }
    }

    @Test("Concurrent finish callers share the same failure")
    func concurrentFinishCallersShareFailure() async throws {
        let outputURL = temporaryURL(named: "coalesced-finish-failure")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let writer = try AssetWriterSession(
            outputURL: outputURL,
            configuration: RecordingConfiguration(
                width: 320,
                height: 180,
                framesPerSecond: 30,
                showsCursor: false,
                audioMode: .off
            )
        )
        try writer.start()

        let messages = await withTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        _ = try await writer.finish()
                        return "unexpected success"
                    } catch {
                        return error.localizedDescription
                    }
                }
            }
            var messages: [String] = []
            for await message in group {
                messages.append(message)
            }
            return messages
        }

        #expect(messages.count == 8)
        #expect(Set(messages) == ["The video encoder produced no video samples."])
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test("Cancellation during a shared finish fails every waiter and removes output")
    func cancellationDuringSharedFinish() async throws {
        let outputURL = temporaryURL(named: "cancel-shared-finish")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let finalizationStarted = AsyncStream<Void>.makeStream()
        let mayContinueFinalization = DispatchSemaphore(value: 0)
        let writer = try AssetWriterSession(
            outputURL: outputURL,
            configuration: RecordingConfiguration(
                width: 320,
                height: 180,
                framesPerSecond: 30,
                showsCursor: false,
                audioMode: .off
            ),
            finalizationBarrier: {
                finalizationStarted.continuation.yield()
                mayContinueFinalization.wait()
            }
        )
        try writer.start()

        func finishMessage() async -> String {
            do {
                _ = try await writer.finish()
                return "unexpected success"
            } catch {
                return error.localizedDescription
            }
        }

        let first = Task { await finishMessage() }
        var finalizationEvents = finalizationStarted.stream.makeAsyncIterator()
        _ = await finalizationEvents.next()
        let second = Task { await finishMessage() }
        await Task.yield()
        writer.cancelAndRemoveOutput()
        mayContinueFinalization.signal()

        let messages = await [first.value, second.value]
        #expect(messages == [
            "Recording finalization was cancelled.",
            "Recording finalization was cancelled.",
        ])
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        #expect(await finishMessage() == "Recording finalization was cancelled.")
    }

    @Test("A pause before first video anchors in the adjusted writer timeline")
    func acceptsFirstVideoAfterEarlyPauseAndResume() async throws {
        let outputURL = temporaryURL(named: "writer-early-pause")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let framesPerSecond = 30
        let writer = try AssetWriterSession(
            outputURL: outputURL,
            configuration: RecordingConfiguration(
                width: 320,
                height: 180,
                framesPerSecond: framesPerSecond,
                showsCursor: false,
                audioMode: .off
            )
        )
        try writer.start()
        try writer.pause(at: CMTime(seconds: 1, preferredTimescale: 600))
        try writer.resume(at: CMTime(seconds: 2, preferredTimescale: 600))

        for frameIndex in 60...62 {
            try appendWithRetry(
                makeVideoSample(
                    width: 320,
                    height: 180,
                    frameIndex: frameIndex,
                    framesPerSecond: framesPerSecond
                ),
                to: writer
            )
        }
        _ = try await writer.finish()

        let inspection = try await MediaInspector.inspect(outputURL)
        #expect(inspection.videoTrackCount == 1)
        #expect(try await countVideoSamples(in: outputURL) == 3)
        #expect(inspection.duration > 0)
        #expect(inspection.duration < 0.2)
    }

    @Test("Live capture sustains exact 5120 x 1440 at 30 FPS using hardware HEVC")
    func sustainsNativeUltrawideHEVCFallback() async throws {
        let sourceURL = temporaryURL(named: "native-ultrawide-hevc-source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let width = 5_120
        let height = 1_440
        let framesPerSecond = 30
        let frameCount = 60
        try await writePacedSyntheticVideo(
            to: sourceURL,
            width: width,
            height: height,
            frameCount: frameCount,
            framesPerSecond: framesPerSecond
        )

        let source = try await MediaInspector.inspect(sourceURL)
        #expect(source.videoCodec == kCMVideoCodecType_HEVC)
        #expect(source.width == width)
        #expect(source.height == height)
        #expect(abs(source.nominalFramesPerSecond - Double(framesPerSecond)) <= 0.1)
        #expect(try await countVideoSamples(in: sourceURL) == frameCount)
        let presentationTimes = try await videoPresentationTimes(in: sourceURL)
        let maximumGap = zip(presentationTimes, presentationTimes.dropFirst())
            .map { $1 - $0 }
            .max() ?? 0
        #expect(maximumGap <= (2.0 / Double(framesPerSecond)) + 0.001)
    }

    @Test("Native export applies trim without re-encoding video")
    func exportsConfiguredTrimmedMP4() async throws {
        let sourceURL = temporaryURL(named: "source")
        let exportURL = temporaryURL(named: "trimmed")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: exportURL)
        }

        try await writeSyntheticVideo(
            to: sourceURL,
            width: 320,
            height: 180,
            frameCount: 60,
            framesPerSecond: 30
        )
        let sourceBeforeExport = try await MediaInspector.inspect(sourceURL)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let configuration = MediaExportConfiguration(
            width: 320,
            height: 180,
            framesPerSecond: 30
        )

        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            timeRange: CMTimeRange(
                start: CMTime(seconds: 0.5, preferredTimescale: 600),
                duration: CMTime(seconds: 0.5, preferredTimescale: 600)
            ),
            configuration: configuration
        )

        let sourceAfterExport = try await MediaInspector.inspect(sourceURL)
        let exported = try await MediaInspector.inspect(exportURL)
        #expect(sourceAfterExport == sourceBeforeExport)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        #expect(exported.fileSize > 0)
        #expect(exported.videoTrackCount == 1)
        #expect(exported.audioTrackCount == 0)
        #expect(exported.width == configuration.width)
        #expect(exported.height == configuration.height)
        #expect(exported.videoCodec == sourceBeforeExport.videoCodec)
        #expect(abs(exported.nominalFramesPerSecond - 30) <= 0.1)
        let frameCount = try await countVideoSamples(in: exportURL)
        #expect(frameCount >= 14)
        #expect(frameCount <= 16)
        #expect(abs(exported.duration - 0.5) <= (1.0 / 30.0))
        #expect(try await hasRec709VideoDescription(exportURL))
    }

    @Test("Export preserves independently recorded AAC tracks without recompression")
    func preservesCapturedAudioTracks() async throws {
        let sourceURL = temporaryURL(named: "two-audio-tracks")
        let exportURL = temporaryURL(named: "mixed-audio")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: exportURL)
        }

        try await writeSyntheticVideoWithAudio(to: sourceURL)
        let source = try await MediaInspector.inspect(sourceURL)
        #expect(source.videoTrackCount == 1)
        #expect(source.audioTrackCount == 2)

        let configuration = MediaExportConfiguration(
            width: source.width,
            height: source.height,
            framesPerSecond: 30
        )
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            timeRange: nil,
            configuration: configuration
        )

        let exported = try await MediaInspector.inspect(exportURL)
        #expect(exported.videoTrackCount == 1)
        #expect(exported.audioTrackCount == 2)
        #expect(abs(exported.duration - 1) <= (1.0 / 30.0))
        #expect(try await firstCodec(in: exportURL, mediaType: .audio) == kAudioFormatMPEG4AAC)
        let audioDataRate = try await firstEstimatedDataRate(in: exportURL, mediaType: .audio)
        #expect(audioDataRate == (try await firstEstimatedDataRate(in: sourceURL, mediaType: .audio)))
        #expect(try Data(contentsOf: exportURL) == Data(contentsOf: sourceURL))
    }

    @Test("Export audio can be removed or restored without mutating the managed master")
    func exportsWithAndWithoutAudioNonDestructively() async throws {
        let sourceURL = temporaryURL(named: "audio-preference-source")
        let audibleURL = temporaryURL(named: "audio-preference-keep")
        let silentURL = temporaryURL(named: "audio-preference-remove")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: audibleURL)
            try? FileManager.default.removeItem(at: silentURL)
        }

        try await writeSyntheticVideoWithAudio(to: sourceURL)
        let originalBytes = try Data(contentsOf: sourceURL)
        let source = try await MediaInspector.inspect(sourceURL)
        #expect(source.audioTrackCount == 2)

        var configuration = MediaExportConfiguration(
            width: source.width,
            height: source.height,
            framesPerSecond: 30,
            includesAudio: true
        )
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: audibleURL,
            timeRange: nil,
            configuration: configuration
        )

        configuration.includesAudio = false
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: silentURL,
            timeRange: nil,
            configuration: configuration
        )

        let audible = try await MediaInspector.inspect(audibleURL)
        let silent = try await MediaInspector.inspect(silentURL)
        #expect(audible.videoTrackCount == 1)
        #expect(audible.audioTrackCount == 2)
        #expect(silent.videoTrackCount == 1)
        #expect(silent.audioTrackCount == 0)
        #expect(abs(audible.duration - silent.duration) <= (1.0 / 30.0))
        #expect(try Data(contentsOf: silentURL) != originalBytes)
        #expect(try Data(contentsOf: sourceURL) == originalBytes)
        #expect(try await MediaInspector.inspect(sourceURL) == source)
    }

    @Test("A microphone-only master and export retain one aligned AAC track")
    func preservesMicrophoneOnlyAudio() async throws {
        try await assertSingleAudioSourcePipeline(
            mode: .microphone,
            sampleKind: .microphone,
            frequency: 660,
            name: "microphone-only"
        )
    }

    @Test("A system-audio-only master and export retain one aligned AAC track")
    func preservesSystemAudioOnly() async throws {
        try await assertSingleAudioSourcePipeline(
            mode: .system,
            sampleKind: .systemAudio,
            frequency: 440,
            name: "system-audio-only"
        )
    }

    @Test("Pause removal keeps video and mixed audio aligned within 50 ms")
    func keepsAudioVideoSynchronizedAcrossPause() async throws {
        let sourceURL = temporaryURL(named: "paused-av-source")
        let exportURL = temporaryURL(named: "paused-av-export")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: exportURL)
        }

        try await writePausedSyntheticVideoWithAudio(to: sourceURL)

        let source = try await MediaInspector.inspect(sourceURL)
        #expect(source.videoTrackCount == 1)
        #expect(source.audioTrackCount == 2)
        #expect(abs(source.duration - 2) <= (1.0 / 30.0))
        let sourceAlignment = try await audioVideoAlignment(in: sourceURL)
        #expect(sourceAlignment.audioTrackCount == 2)
        #expect(sourceAlignment.maximumStartDelta <= 0.05)
        #expect(sourceAlignment.maximumEndDelta <= 0.05)
        let sourceVideoTimes = try await videoPresentationTimes(in: sourceURL)
        let maximumSourceVideoGap = zip(
            sourceVideoTimes,
            sourceVideoTimes.dropFirst()
        ).map { $1 - $0 }.max() ?? 0
        #expect(maximumSourceVideoGap <= (2.0 / 30.0) + 0.001)

        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            timeRange: nil,
            configuration: MediaExportConfiguration(
                width: source.width,
                height: source.height,
                framesPerSecond: 30
            )
        )

        let exported = try await MediaInspector.inspect(exportURL)
        #expect(exported.videoTrackCount == 1)
        #expect(exported.audioTrackCount == 2)
        #expect(abs(exported.duration - 2) <= (1.0 / 30.0))
        let exportedAlignment = try await audioVideoAlignment(in: exportURL)
        #expect(exportedAlignment.audioTrackCount == 2)
        #expect(exportedAlignment.maximumStartDelta <= 0.05)
        #expect(exportedAlignment.maximumEndDelta <= 0.05)
        let exportedVideoTimes = try await videoPresentationTimes(in: exportURL)
        let maximumExportedVideoGap = zip(
            exportedVideoTimes,
            exportedVideoTimes.dropFirst()
        ).map { $1 - $0 }.max() ?? 0
        #expect(maximumExportedVideoGap <= (2.0 / 30.0) + 0.001)
    }

    @Test("Microphone loss preserves video, system audio, and earlier microphone samples")
    func continuesAfterMicrophoneLoss() async throws {
        let sourceURL = temporaryURL(named: "microphone-loss-source")
        let exportURL = temporaryURL(named: "microphone-loss-export")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: exportURL)
        }

        let framesPerSecond = 30
        let audioFramesPerVideoFrame = 48_000 / framesPerSecond
        let writer = try AssetWriterSession(
            outputURL: sourceURL,
            configuration: RecordingConfiguration(
                width: 320,
                height: 180,
                framesPerSecond: framesPerSecond,
                showsCursor: false,
                audioMode: .microphoneAndSystem
            )
        )
        try writer.start()

        for frameIndex in 0..<framesPerSecond {
            try appendWithRetry(
                makeVideoSample(
                    width: 320,
                    height: 180,
                    frameIndex: frameIndex,
                    framesPerSecond: framesPerSecond
                ),
                kind: .video,
                to: writer
            )
            let audioStartFrame = frameIndex * audioFramesPerVideoFrame
            try appendWithRetry(
                makeAudioSample(
                    startFrame: audioStartFrame,
                    frameCount: audioFramesPerVideoFrame,
                    frequency: 440
                ),
                kind: .systemAudio,
                to: writer
            )

            if frameIndex < 10 {
                try appendWithRetry(
                    makeAudioSample(
                        startFrame: audioStartFrame,
                        frameCount: audioFramesPerVideoFrame,
                        frequency: 660
                    ),
                    kind: .microphone,
                    to: writer
                )
            } else if frameIndex == 10 {
                #expect(writer.disableAudioSource(.microphone))
                #expect(!writer.disableAudioSource(.microphone))
                let ignoredSample = try makeAudioSample(
                    startFrame: audioStartFrame,
                    frameCount: audioFramesPerVideoFrame,
                    frequency: 660
                )
                let didAppendIgnoredSample = try writer.append(
                    ignoredSample,
                    kind: .microphone
                )
                #expect(!didAppendIgnoredSample)
            }
        }
        _ = try await writer.finish()

        let source = try await MediaInspector.inspect(sourceURL)
        #expect(source.videoTrackCount == 1)
        #expect(source.audioTrackCount == 2)
        #expect(abs(source.duration - 1) <= (1.0 / 30.0))

        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            timeRange: nil,
            configuration: MediaExportConfiguration(
                width: source.width,
                height: source.height,
                framesPerSecond: 30
            )
        )
        let exported = try await MediaInspector.inspect(exportURL)
        #expect(exported.videoTrackCount == 1)
        #expect(exported.audioTrackCount == 2)
        #expect(abs(exported.duration - 1) <= (1.0 / 30.0))
    }

    @Test("An audio source disabled before samples creates no empty track")
    func unavailableAudioWithoutSamplesIsOmitted() async throws {
        let outputURL = temporaryURL(named: "missing-system-audio")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let framesPerSecond = 30
        let audioFramesPerVideoFrame = 48_000 / framesPerSecond
        let writer = try AssetWriterSession(
            outputURL: outputURL,
            configuration: RecordingConfiguration(
                width: 320,
                height: 180,
                framesPerSecond: framesPerSecond,
                showsCursor: false,
                audioMode: .microphoneAndSystem
            )
        )
        try writer.start()
        #expect(writer.disableAudioSource(.systemAudio))

        for frameIndex in 0..<framesPerSecond {
            try appendWithRetry(
                makeVideoSample(
                    width: 320,
                    height: 180,
                    frameIndex: frameIndex,
                    framesPerSecond: framesPerSecond
                ),
                kind: .video,
                to: writer
            )
            try appendWithRetry(
                makeAudioSample(
                    startFrame: frameIndex * audioFramesPerVideoFrame,
                    frameCount: audioFramesPerVideoFrame,
                    frequency: 660
                ),
                kind: .microphone,
                to: writer
            )
        }
        _ = try await writer.finish()

        let inspection = try await MediaInspector.inspect(outputURL)
        #expect(inspection.videoTrackCount == 1)
        #expect(inspection.audioTrackCount == 1)
        #expect(abs(inspection.duration - 1) <= (1.0 / 30.0))
    }

    @Test("Concurrent exports atomically publish complete files at one destination")
    func publishesConcurrentExportsAtomically() async throws {
        let sourceURL = temporaryURL(named: "concurrent-source")
        let destinationURL = temporaryURL(named: "shared-destination")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }

        try await writeSyntheticVideo(
            to: sourceURL,
            width: 320,
            height: 180,
            frameCount: 30,
            framesPerSecond: 30
        )
        let sourceBytes = try Data(contentsOf: sourceURL)
        try Data("existing destination remains until publish".utf8).write(to: destinationURL)

        let small = MediaExportConfiguration(
            width: 320,
            height: 180,
            framesPerSecond: 30
        )
        let large = MediaExportConfiguration(
            width: 320,
            height: 180,
            framesPerSecond: 30
        )

        async let first = NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            timeRange: nil,
            configuration: small
        )
        async let second = NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            timeRange: nil,
            configuration: large
        )
        let (firstResult, secondResult) = try await (first, second)
        #expect(firstResult == destinationURL)
        #expect(secondResult == destinationURL)

        let final = try await MediaInspector.inspect(destinationURL)
        #expect(final.videoCodec == kCMVideoCodecType_HEVC)
        #expect(final.width == 320)
        #expect(final.height == 180)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)

        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: destinationURL.deletingLastPathComponent().path
        )
        #expect(!siblingNames.contains { name in
            name.hasPrefix(".\(destinationURL.lastPathComponent).clip-export-")
        })
    }

    @Test("Rejected export preserves both source and an existing destination")
    func preservesFilesWhenExportIsRejected() async throws {
        let sourceURL = temporaryURL(named: "rejected-source")
        let destinationURL = temporaryURL(named: "preserved-destination")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }

        try await writeSyntheticVideo(
            to: sourceURL,
            width: 320,
            height: 180,
            frameCount: 30,
            framesPerSecond: 30
        )
        let sourceBytes = try Data(contentsOf: sourceURL)
        let destinationBytes = Data("do not replace me".utf8)
        try destinationBytes.write(to: destinationURL)
        let configuration = MediaExportConfiguration(
            width: 320,
            height: 180,
            framesPerSecond: 30
        )

        await #expect(throws: NativeAssetExporterError.invalidTimeRange) {
            try await NativeAssetExporter().export(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: 2, preferredTimescale: 600),
                    duration: CMTime(seconds: 1, preferredTimescale: 600)
                ),
                configuration: configuration
            )
        }
        await #expect(throws: NativeAssetExporterError.sourceAndDestinationMustDiffer) {
            try await NativeAssetExporter().export(
                sourceURL: sourceURL,
                destinationURL: sourceURL,
                timeRange: nil,
                configuration: configuration
            )
        }

        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        #expect(try Data(contentsOf: destinationURL) == destinationBytes)
    }
}

private enum SyntheticFramePattern {
    case flat
    case complex
    case animatedScreen
}

private func recordingEncoderForTests() throws -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let url = root.appendingPathComponent(".build/recording-encoder/install/bin/ffmpeg")
    try #require(FileManager.default.isExecutableFile(atPath: url.path),
                 "Run scripts/build-recording-encoder.sh before media integration tests")
    return url
}

private func decodedAudioChannel(_ url: URL, trackIndex: Int = 0) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let track = try #require(tracks.indices.contains(trackIndex) ? tracks[trackIndex] : nil)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    try #require(reader.startReading())
    var channel = [Float](repeating: 0, count: 48_000 * 3)
    while let sample = output.copyNextSampleBuffer() {
        guard sample.numSamples > 0, let block = sample.dataBuffer else { continue }
        var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        let status = values.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        try #require(status == noErr)
        let start = Int((sample.presentationTimeStamp.seconds * 48_000).rounded())
        for index in 0..<(values.count / 2) where (0..<channel.count).contains(start + index) {
            channel[start + index] = values[index * 2]
        }
    }
    try #require(reader.status == .completed)
    return channel
}

private func toneAmplitude(_ samples: [Float], frequency: Double, start: Double, end: Double) -> Double {
    let lower = Int(start * 48_000), upper = Int(end * 48_000)
    var sine = 0.0, cosine = 0.0
    for index in lower..<upper {
        let phase = 2 * Double.pi * frequency * Double(index) / 48_000
        sine += Double(samples[index]) * sin(phase)
        cosine += Double(samples[index]) * cos(phase)
    }
    return 2 * sqrt(sine * sine + cosine * cosine) / Double(upper - lower)
}

private func writeSyntheticVideo(
    to outputURL: URL,
    width: Int,
    height: Int,
    frameCount: Int,
    framesPerSecond: Int,
    pattern: SyntheticFramePattern = .flat
) async throws {
    let configuration = RecordingConfiguration(
        width: width,
        height: height,
        framesPerSecond: framesPerSecond,
        showsCursor: false,
        audioMode: .off
    )
    let writer = try AssetWriterSession(
        outputURL: outputURL,
        configuration: configuration
    )
    try writer.start()

    for index in 0..<frameCount {
        let sample = try makeVideoSample(
            width: width,
            height: height,
            frameIndex: index,
            framesPerSecond: framesPerSecond,
            pattern: pattern
        )
        try appendWithRetry(sample, to: writer)
    }
    _ = try await writer.finish()
}

private func writePacedSyntheticVideo(
    to outputURL: URL,
    width: Int,
    height: Int,
    frameCount: Int,
    framesPerSecond: Int
) async throws {
    let writer = try AssetWriterSession(
        outputURL: outputURL,
        configuration: RecordingConfiguration(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            showsCursor: false,
            audioMode: .off
        )
    )
    try writer.start()

    for frameIndex in 0..<frameCount {
        if frameIndex > 0 {
            try await Task.sleep(for: .milliseconds(33))
        }
        try appendWithRetry(
            makeVideoSample(
                width: width,
                height: height,
                frameIndex: frameIndex,
                framesPerSecond: framesPerSecond,
                pattern: .animatedScreen
            ),
            to: writer
        )
    }
    _ = try await writer.finish()
}

private func writeSyntheticVideoWithAudio(to outputURL: URL) async throws {
    let framesPerSecond = 30
    let audioFramesPerVideoFrame = 48_000 / framesPerSecond
    let writer = try AssetWriterSession(
        outputURL: outputURL,
        configuration: RecordingConfiguration(
            width: 320,
            height: 180,
            framesPerSecond: framesPerSecond,
            showsCursor: false,
            audioMode: .microphoneAndSystem
        )
    )
    try writer.start()

    for frameIndex in 0..<framesPerSecond {
        try appendWithRetry(
            makeVideoSample(
                width: 320,
                height: 180,
                frameIndex: frameIndex,
                framesPerSecond: framesPerSecond
            ),
            kind: .video,
            to: writer
        )
        let audioStartFrame = frameIndex * audioFramesPerVideoFrame
        try appendWithRetry(
            makeAudioSample(
                startFrame: audioStartFrame,
                frameCount: audioFramesPerVideoFrame,
                frequency: 440
            ),
            kind: .systemAudio,
            to: writer
        )
        try appendWithRetry(
            makeAudioSample(
                startFrame: audioStartFrame,
                frameCount: audioFramesPerVideoFrame,
                frequency: 660
            ),
            kind: .microphone,
            to: writer
        )
    }
    _ = try await writer.finish()
}

private func assertSingleAudioSourcePipeline(
    mode: AudioCaptureMode,
    sampleKind: CapturedSampleKind,
    frequency: Double,
    name: String
) async throws {
    let sourceURL = temporaryURL(named: "\(name)-source")
    let exportURL = temporaryURL(named: "\(name)-export")
    defer {
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: exportURL)
    }

    let framesPerSecond = 30
    let audioFramesPerVideoFrame = 48_000 / framesPerSecond
    let writer = try AssetWriterSession(
        outputURL: sourceURL,
        configuration: RecordingConfiguration(
            width: 320,
            height: 180,
            framesPerSecond: framesPerSecond,
            showsCursor: false,
            audioMode: mode
        )
    )
    try writer.start()

    for frameIndex in 0..<framesPerSecond {
        try appendWithRetry(
            makeVideoSample(
                width: 320,
                height: 180,
                frameIndex: frameIndex,
                framesPerSecond: framesPerSecond
            ),
            kind: .video,
            to: writer
        )
        try appendWithRetry(
            makeAudioSample(
                startFrame: frameIndex * audioFramesPerVideoFrame,
                frameCount: audioFramesPerVideoFrame,
                frequency: frequency
            ),
            kind: sampleKind,
            to: writer
        )
    }
    _ = try await writer.finish()

    let source = try await MediaInspector.inspect(sourceURL)
    #expect(source.videoTrackCount == 1)
    #expect(source.audioTrackCount == 1)
    #expect(abs(source.duration - 1) <= (1.0 / Double(framesPerSecond)))
    let sourceAlignment = try await audioVideoAlignment(in: sourceURL)
    #expect(sourceAlignment.audioTrackCount == 1)
    #expect(sourceAlignment.maximumStartDelta <= 0.05)
    #expect(sourceAlignment.maximumEndDelta <= 0.05)

    _ = try await NativeAssetExporter().export(
        sourceURL: sourceURL,
        destinationURL: exportURL,
        timeRange: nil,
        configuration: MediaExportConfiguration(
            width: source.width,
            height: source.height,
            framesPerSecond: framesPerSecond
        )
    )

    let exported = try await MediaInspector.inspect(exportURL)
    #expect(exported.videoTrackCount == 1)
    #expect(exported.audioTrackCount == 1)
    #expect(try await firstCodec(in: exportURL, mediaType: .audio) == kAudioFormatMPEG4AAC)
    let exportedAlignment = try await audioVideoAlignment(in: exportURL)
    #expect(exportedAlignment.audioTrackCount == 1)
    #expect(exportedAlignment.maximumStartDelta <= 0.05)
    #expect(exportedAlignment.maximumEndDelta <= 0.05)
}

private func writePausedSyntheticVideoWithAudio(to outputURL: URL) async throws {
    let framesPerSecond = 30
    let audioSampleRate = 48_000
    let audioFramesPerVideoFrame = audioSampleRate / framesPerSecond
    let writer = try AssetWriterSession(
        outputURL: outputURL,
        configuration: RecordingConfiguration(
            width: 320,
            height: 180,
            framesPerSecond: framesPerSecond,
            showsCursor: false,
            audioMode: .microphoneAndSystem
        )
    )
    try writer.start()

    func appendSegment(_ sourceVideoFrames: Range<Int>) throws {
        for sourceFrame in sourceVideoFrames {
            try appendWithRetry(
                makeVideoSample(
                    width: 320,
                    height: 180,
                    frameIndex: sourceFrame,
                    framesPerSecond: framesPerSecond
                ),
                kind: .video,
                to: writer
            )
            let audioStartFrame = sourceFrame * audioFramesPerVideoFrame
            try appendWithRetry(
                makeAudioSample(
                    startFrame: audioStartFrame,
                    frameCount: audioFramesPerVideoFrame,
                    frequency: 440
                ),
                kind: .systemAudio,
                to: writer
            )
            try appendWithRetry(
                makeAudioSample(
                    startFrame: audioStartFrame,
                    frameCount: audioFramesPerVideoFrame,
                    frequency: 660
                ),
                kind: .microphone,
                to: writer
            )
        }
    }

    try appendSegment(0..<framesPerSecond)
    try writer.pause(at: CMTime(seconds: 1, preferredTimescale: 600))
    try writer.resume(at: CMTime(seconds: 3, preferredTimescale: 600))
    try appendSegment((framesPerSecond * 3)..<(framesPerSecond * 4))
    _ = try await writer.finish()
}

private func appendWithRetry(
    _ sample: CMSampleBuffer,
    kind: CapturedSampleKind = .video,
    to writer: AssetWriterSession
) throws {
    for _ in 0..<1_000 {
        if try writer.append(sample, kind: kind) {
            return
        }
        Thread.sleep(forTimeInterval: 0.001)
    }
    throw SyntheticMediaError.writerBackPressureTimeout
}

private func makeVideoSample(
    width: Int,
    height: Int,
    frameIndex: Int,
    framesPerSecond: Int,
    pattern: SyntheticFramePattern = .flat,
    presentationTime: CMTime? = nil,
    sampleDuration: CMTime? = nil
) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    let pixelStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )
    guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
        throw SyntheticMediaError.cannotCreatePixelBuffer(pixelStatus)
    }

    CVBufferSetAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey,
        CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        switch pattern {
        case .flat:
            memset(baseAddress, Int32((frameIndex * 7) % 255), bytesPerRow * height)
        case .complex:
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * bytesPerRow) + (x * 4)
                    let seed = UInt32(truncatingIfNeeded:
                        (x &* 73_856_093)
                            ^ (y &* 19_349_663)
                            ^ (frameIndex &* 83_492_791)
                    )
                    bytes[offset] = UInt8(truncatingIfNeeded: seed)
                    bytes[offset + 1] = UInt8(truncatingIfNeeded: seed >> 8)
                    bytes[offset + 2] = UInt8(truncatingIfNeeded: seed >> 16)
                    bytes[offset + 3] = 255
                }
            }
        case .animatedScreen:
            memset(baseAddress, 24, bytesPerRow * height)
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let barWidth = max(16, width / 64)
            let barStart = (frameIndex * max(1, width / 120)) % width
            for y in 0..<height {
                for xOffset in 0..<barWidth {
                    let x = (barStart + xOffset) % width
                    let offset = (y * bytesPerRow) + (x * 4)
                    bytes[offset] = 64
                    bytes[offset + 1] = 208
                    bytes[offset + 2] = 255
                    bytes[offset + 3] = 255
                }
            }
            let lineY = (frameIndex * 7) % height
            for x in 0..<width {
                let offset = (lineY * bytesPerRow) + (x * 4)
                bytes[offset] = 255
                bytes[offset + 1] = 255
                bytes[offset + 2] = 255
                bytes[offset + 3] = 255
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
        throw SyntheticMediaError.cannotCreateFormatDescription(formatStatus)
    }

    let duration = sampleDuration
        ?? CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
    var timing = CMSampleTimingInfo(
        duration: duration,
        presentationTimeStamp: presentationTime
            ?? CMTime(
                value: CMTimeValue(frameIndex),
                timescale: CMTimeScale(framesPerSecond)
            ),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
        throw SyntheticMediaError.cannotCreateSampleBuffer(sampleStatus)
    }
    return sampleBuffer
}

private func makeAudioSample(
    startFrame: Int,
    frameCount: Int,
    frequency: Double,
    sampleRate: Double = 48_000
) throws -> CMSampleBuffer {
    let channels = 2
    var samples = [Float](repeating: 0, count: frameCount * channels)
    for frameOffset in 0..<frameCount {
        let time = Double(startFrame + frameOffset) / sampleRate
        let value = Float(sin(2 * .pi * frequency * time) * 0.08)
        for channel in 0..<channels {
            samples[(frameOffset * channels) + channel] = value
        }
    }

    let byteCount = samples.count * MemoryLayout<Float>.size
    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
        throw SyntheticMediaError.cannotCreateBlockBuffer(blockStatus)
    }
    let replaceStatus = samples.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }
    guard replaceStatus == kCMBlockBufferNoErr else {
        throw SyntheticMediaError.cannotFillBlockBuffer(replaceStatus)
    }

    let bytesPerFrame = UInt32(channels * MemoryLayout<Float>.size)
    var streamDescription = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &streamDescription,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
        throw SyntheticMediaError.cannotCreateFormatDescription(formatStatus)
    }

    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: frameCount,
        presentationTimeStamp: CMTime(
            value: CMTimeValue(startFrame),
            timescale: CMTimeScale(sampleRate)
        ),
        packetDescriptions: nil,
        sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
        throw SyntheticMediaError.cannotCreateSampleBuffer(sampleStatus)
    }
    return sampleBuffer
}

private func temporaryURL(named name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("clip-\(name)-\(UUID().uuidString)")
        .appendingPathExtension("mp4")
}

private func writeIrregularSyntheticVideo(to url: URL) async throws {
    let writer = try AssetWriterSession(
        outputURL: url,
        configuration: RecordingConfiguration(
            width: 320,
            height: 180,
            framesPerSecond: 30,
            showsCursor: false,
            audioMode: .off
        )
    )
    let milliseconds = [0, 20, 60, 80, 120, 160]
    try writer.start()
    for (index, value) in milliseconds.enumerated() {
        let nextValue = index + 1 < milliseconds.count
            ? milliseconds[index + 1]
            : value + 40
        try appendWithRetry(
            makeVideoSample(
                width: 320,
                height: 180,
                frameIndex: index,
                framesPerSecond: 30,
                pattern: .complex,
                presentationTime: CMTime(value: CMTimeValue(value), timescale: 1_000),
                sampleDuration: CMTime(
                    value: CMTimeValue(nextValue - value),
                    timescale: 1_000
                )
            ),
            to: writer
        )
    }
    _ = try await writer.finish()
}

private func countVideoSamples(in url: URL) async throws -> Int {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        return 0
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw SyntheticMediaError.cannotAddReaderOutput }
    reader.add(output)
    guard reader.startReading() else { throw SyntheticMediaError.cannotStartReader }

    var count = 0
    while let sample = output.copyNextSampleBuffer() {
        count += CMSampleBufferGetNumSamples(sample)
    }
    guard reader.status == .completed else { throw SyntheticMediaError.readerFailed }
    return count
}

private func videoPresentationTimes(in url: URL) async throws -> [TimeInterval] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        return []
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw SyntheticMediaError.cannotAddReaderOutput }
    reader.add(output)
    guard reader.startReading() else { throw SyntheticMediaError.cannotStartReader }

    var times: [TimeInterval] = []
    while let sample = output.copyNextSampleBuffer() {
        times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
    }
    guard reader.status == .completed else { throw SyntheticMediaError.readerFailed }
    return times
}

private func firstCodec(in url: URL, mediaType: AVMediaType) async throws -> FourCharCode? {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
        return nil
    }
    return try await track.load(.formatDescriptions).first.map(
        CMFormatDescriptionGetMediaSubType
    )
}

private func firstEstimatedDataRate(
    in url: URL,
    mediaType: AVMediaType
) async throws -> Double {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
        return 0
    }
    return Double(try await track.load(.estimatedDataRate))
}

private func hasRec709VideoDescription(_ url: URL) async throws -> Bool {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first,
          let description = try await track.load(.formatDescriptions).first else {
        return false
    }
    guard let rawExtensions = CMFormatDescriptionGetExtensions(description) else {
        return false
    }
    let extensions = rawExtensions as NSDictionary
    return (extensions[kCVImageBufferColorPrimariesKey] as? String)
        == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        && (extensions[kCVImageBufferTransferFunctionKey] as? String)
            == (kCVImageBufferTransferFunction_sRGB as String)
        && (extensions[kCVImageBufferYCbCrMatrixKey] as? String)
            == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
}

private struct AudioVideoAlignment {
    let audioTrackCount: Int
    let maximumStartDelta: TimeInterval
    let maximumEndDelta: TimeInterval
}

private func audioVideoAlignment(in url: URL) async throws -> AudioVideoAlignment {
    let asset = AVURLAsset(url: url)
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
        throw SyntheticMediaError.missingVideoTrack
    }
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard !audioTracks.isEmpty else {
        throw SyntheticMediaError.missingAudioTrack
    }

    let videoRange = try await videoTrack.load(.timeRange)
    let videoStart = videoRange.start.seconds
    let videoEnd = CMTimeRangeGetEnd(videoRange).seconds
    var maximumStartDelta: TimeInterval = 0
    var maximumEndDelta: TimeInterval = 0

    for audioTrack in audioTracks {
        let audioRange = try await audioTrack.load(.timeRange)
        maximumStartDelta = max(
            maximumStartDelta,
            abs(audioRange.start.seconds - videoStart)
        )
        maximumEndDelta = max(
            maximumEndDelta,
            abs(CMTimeRangeGetEnd(audioRange).seconds - videoEnd)
        )
    }

    return AudioVideoAlignment(
        audioTrackCount: audioTracks.count,
        maximumStartDelta: maximumStartDelta,
        maximumEndDelta: maximumEndDelta
    )
}

private enum SyntheticMediaError: Error {
    case cannotCreatePixelBuffer(CVReturn)
    case cannotCreateFormatDescription(OSStatus)
    case cannotCreateSampleBuffer(OSStatus)
    case cannotCreateBlockBuffer(OSStatus)
    case cannotFillBlockBuffer(OSStatus)
    case cannotAddReaderOutput
    case cannotStartReader
    case cannotAddWriterInput
    case cannotStartWriter
    case writerAppendFailed
    case writerFinishFailed
    case readerFailed
    case writerBackPressureTimeout
    case missingVideoTrack
    case missingAudioTrack
}
