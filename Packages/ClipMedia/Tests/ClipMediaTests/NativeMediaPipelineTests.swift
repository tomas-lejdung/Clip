@preconcurrency import AVFoundation
@preconcurrency import VideoToolbox
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ClipMedia

@Suite("Native media pipeline", .serialized)
struct NativeMediaPipelineTests {
    @Test("Synthetic frames produce an inspectable H.264 MP4")
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
        #expect(inspection.videoCodec == kCMVideoCodecType_H264)
    }

    @Test("Compact always applies its quality export policy")
    func compactDoesNotReuseMasterBytes() async throws {
        let sourceURL = temporaryURL(named: "compact-reuse-source")
        let exportURL = temporaryURL(named: "compact-reuse-output")
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
        let source = try await MediaInspector.inspect(sourceURL)
        let configuration = MediaExportConfigurationFactory.make(
            preset: .compact,
            sourceWidth: source.width,
            sourceHeight: source.height,
            sourceFramesPerSecond: 30,
            videoQuality: 0.90,
            sourceVideoQuality: 0.98
        )

        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            timeRange: nil,
            configuration: configuration
        )

        #expect(try Data(contentsOf: exportURL) != Data(contentsOf: sourceURL))
        let exported = try await MediaInspector.inspect(exportURL)
        #expect(exported.videoCodec == kCMVideoCodecType_H264)
        #expect(exported.width == source.width)
        #expect(exported.height == source.height)
    }

    @Test("Crisp reuses a fully compatible master without another lossy encode")
    func reusesCompatibleMasterForCrisp() async throws {
        let sourceURL = temporaryURL(named: "crisp-reuse-source")
        let exportURL = temporaryURL(named: "crisp-reuse-output")
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
        let source = try await MediaInspector.inspect(sourceURL)
        let configuration = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: source.width,
            sourceHeight: source.height,
            sourceFramesPerSecond: 30,
            videoQuality: 0.98,
            sourceVideoQuality: 0.98
        )

        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            timeRange: nil,
            configuration: configuration
        )

        #expect(try Data(contentsOf: exportURL) == Data(contentsOf: sourceURL))
        #expect(try await MediaInspector.inspect(exportURL) == source)
    }

    @Test("Crisp transcodes an HEVC master to H.264 instead of reusing source bytes")
    func transcodesHEVCMasterToH264ForCrisp() async throws {
        let sourceURL = temporaryURL(named: "crisp-hevc-source")
        let exportURL = temporaryURL(named: "crisp-hevc-output")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: exportURL)
        }

        try await writeSyntheticHEVCVideo(
            to: sourceURL,
            width: 640,
            height: 360,
            frameCount: 12,
            framesPerSecond: 30
        )
        let source = try await MediaInspector.inspect(sourceURL)
        #expect(source.videoCodec == kCMVideoCodecType_HEVC)

        let configuration = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: source.width,
            sourceHeight: source.height,
            sourceFramesPerSecond: 30,
            videoQuality: 0.98,
            sourceVideoQuality: 0.98
        )
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            timeRange: nil,
            configuration: configuration
        )

        let exported = try await MediaInspector.inspect(exportURL)
        #expect(exported.videoCodec == kCMVideoCodecType_H264)
        #expect(exported.width == source.width)
        #expect(exported.height == source.height)
        #expect(abs(exported.nominalFramesPerSecond - source.nominalFramesPerSecond) <= 0.1)
        #expect(try Data(contentsOf: exportURL) != Data(contentsOf: sourceURL))
    }

    @Test("Crisp reuses a compatible VFR master below its rounded FPS ceiling")
    func reusesCompatibleVariableFrameRateMasterForCrisp() async throws {
        let sourceURL = temporaryURL(named: "crisp-vfr-reuse-source")
        let exportURL = temporaryURL(named: "crisp-vfr-reuse-output")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: exportURL)
        }

        try await writeIrregularSyntheticVideo(to: sourceURL)
        let source = try await MediaInspector.inspect(sourceURL)
        let roundedCeiling = max(1, Int(source.nominalFramesPerSecond.rounded()))
        #expect(source.nominalFramesPerSecond <= Double(roundedCeiling) + 0.1)
        let configuration = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: source.width,
            sourceHeight: source.height,
            sourceFramesPerSecond: roundedCeiling,
            videoQuality: 0.98,
            sourceVideoQuality: 0.98
        )

        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            timeRange: nil,
            configuration: configuration
        )

        #expect(try Data(contentsOf: exportURL) == Data(contentsOf: sourceURL))
        #expect(try await MediaInspector.inspect(exportURL) == source)
    }

    @Test("Compatible reuse rejects quality, trim, dimension, FPS, and audio transforms")
    func compatibleReusePolicyRejectsRequiredTransforms() {
        let configuration = MediaExportConfiguration(
            preset: .compact,
            width: 1_440,
            height: 900,
            framesPerSecond: 30,
            videoQuality: 0.90,
            sourceVideoQuality: 0.98,
            audioBitRate: 128_000
        )
        let eligible = CompatibleSourceReuseFacts(
            isFullRange: true,
            videoTrackCount: 1,
            videoCodec: kCMVideoCodecType_H264,
            width: 1_440,
            height: 900,
            framesPerSecond: 30,
            hasRec709ColorDescription: true,
            audioTrackCount: 0,
            audioCodec: nil,
            audioDataRate: nil,
            audioSampleRate: nil,
            audioChannelCount: nil
        )
        #expect(!CompatibleSourceReusePolicy.canReuse(eligible, for: configuration))

        var crispConfiguration = configuration
        crispConfiguration.preset = .crisp
        #expect(!CompatibleSourceReusePolicy.canReuse(eligible, for: crispConfiguration))
        crispConfiguration.videoQuality = 0.98
        #expect(CompatibleSourceReusePolicy.canReuse(eligible, for: crispConfiguration))

        var unknownSourceQuality = crispConfiguration
        unknownSourceQuality.sourceVideoQuality = nil
        #expect(!CompatibleSourceReusePolicy.canReuse(eligible, for: unknownSourceQuality))

        var hevcMaster = eligible
        hevcMaster.videoCodec = kCMVideoCodecType_HEVC
        #expect(!CompatibleSourceReusePolicy.canReuse(hevcMaster, for: crispConfiguration))

        var trimmed = eligible
        trimmed.isFullRange = false
        #expect(!CompatibleSourceReusePolicy.canReuse(trimmed, for: crispConfiguration))

        var resized = eligible
        resized.width = 1_280
        #expect(!CompatibleSourceReusePolicy.canReuse(resized, for: crispConfiguration))

        var frameRateReduced = eligible
        frameRateReduced.framesPerSecond = 60
        #expect(!CompatibleSourceReusePolicy.canReuse(frameRateReduced, for: crispConfiguration))

        var roundedVariableFrameRate = eligible
        roundedVariableFrameRate.framesPerSecond = 28.29
        var roundedConfiguration = crispConfiguration
        roundedConfiguration.framesPerSecond = 30
        #expect(
            CompatibleSourceReusePolicy.canReuse(
                roundedVariableFrameRate,
                for: roundedConfiguration
            )
        )

        var aboveFrameRateCeiling = roundedVariableFrameRate
        aboveFrameRateCeiling.framesPerSecond = 30.2
        #expect(
            !CompatibleSourceReusePolicy.canReuse(
                aboveFrameRateCeiling,
                for: roundedConfiguration
            )
        )

        var mixedAudioRequired = eligible
        mixedAudioRequired.audioTrackCount = 2
        #expect(!CompatibleSourceReusePolicy.canReuse(mixedAudioRequired, for: crispConfiguration))

        var audibleSource = eligible
        audibleSource.audioTrackCount = 1
        audibleSource.audioCodec = kAudioFormatMPEG4AAC
        audibleSource.audioDataRate = 64_000
        audibleSource.audioSampleRate = 48_000
        audibleSource.audioChannelCount = 2
        var silentConfiguration = configuration
        silentConfiguration.includesAudio = false
        silentConfiguration.preset = .crisp
        #expect(!CompatibleSourceReusePolicy.canReuse(audibleSource, for: silentConfiguration))
    }

    @Test("Offline presets use native controls supported by their H.264 encoder")
    func offlineVideoEncodingPolicies() throws {
        let compact = MediaExportConfiguration(
            preset: .compact,
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            videoQuality: 0.90
        )
        let crisp = MediaExportConfiguration(
            preset: .crisp,
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            videoQuality: 0.98
        )
        let smallest = MediaExportConfiguration(
            preset: .smallest,
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            videoQuality: 0.70
        )

        let compactPolicy = NativeVideoEncodingPolicy(configuration: compact)
        let crispPolicy = NativeVideoEncodingPolicy(configuration: crisp)
        let smallestPolicy = NativeVideoEncodingPolicy(configuration: smallest)

        #expect(compactPolicy.quality == 0.90)
        #expect(crispPolicy.quality == 0.98)
        #expect(smallestPolicy.quality == 0.70)
        #expect(compactPolicy.rateControl == .quality(0.90))
        #expect(crispPolicy.rateControl == .quality(0.98))
        #expect(smallestPolicy.rateControl == .quality(0.70))
        for policy in [compactPolicy, crispPolicy, smallestPolicy] {
            #expect(!policy.isRealTime)
            #expect(!policy.prioritizesEncodingSpeedOverQuality)
            #expect(policy.allowsFrameReordering)
        }

        let exporter = NativeAssetExporter()
        let compactProperties = try #require(
            exporter.videoSettings(configuration: compact)[AVVideoCompressionPropertiesKey]
                as? [String: Any]
        )
        let crispProperties = try #require(
            exporter.videoSettings(configuration: crisp)[AVVideoCompressionPropertiesKey]
                as? [String: Any]
        )
        let smallestProperties = try #require(
            exporter.videoSettings(configuration: smallest)[AVVideoCompressionPropertiesKey]
                as? [String: Any]
        )

        #expect(compactProperties[AVVideoAverageBitRateKey] == nil)
        #expect(compactProperties[kVTCompressionPropertyKey_Quality as String] as? Double == 0.90)
        #expect(compactProperties[kVTCompressionPropertyKey_DataRateLimits as String] == nil)
        #expect(crispProperties[AVVideoAverageBitRateKey] == nil)
        #expect(crispProperties[kVTCompressionPropertyKey_Quality as String] as? Double == 0.98)
        #expect(crispProperties[kVTCompressionPropertyKey_DataRateLimits as String] == nil)
        #expect(smallestProperties[AVVideoAverageBitRateKey] == nil)
        #expect(smallestProperties[kVTCompressionPropertyKey_Quality as String] as? Double == 0.70)
        #expect(smallestProperties[kVTCompressionPropertyKey_DataRateLimits as String] == nil)
        for properties in [compactProperties, crispProperties, smallestProperties] {
            #expect(properties[kVTCompressionPropertyKey_RealTime as String] as? Bool == false)
            #expect(
                properties[
                    kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String
                ] as? Bool == false
            )
            #expect(properties[AVVideoAllowFrameReorderingKey] as? Bool == true)
        }

        let compactEncoderSpecification = try #require(
            exporter.videoSettings(configuration: compact)[AVVideoEncoderSpecificationKey]
                as? [String: Any]
        )
        #expect(
            compactEncoderSpecification[
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String
            ] as? Bool == true
        )
        #expect(
            compactEncoderSpecification[
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String
            ] as? Bool == true
        )

        let oversizedCompact = MediaExportConfiguration(
            preset: .compact,
            width: 5_120,
            height: 1_440,
            framesPerSecond: 30,
            videoQuality: 0.90
        )
        let oversizedCrisp = MediaExportConfiguration(
            preset: .crisp,
            width: 5_120,
            height: 1_440,
            framesPerSecond: 30,
            videoQuality: 0.98
        )
        let oversizedSmallest = MediaExportConfiguration(
            preset: .smallest,
            width: 5_120,
            height: 1_440,
            framesPerSecond: 30,
            videoQuality: 0.70
        )
        let oversizedPolicies = [
            NativeVideoEncodingPolicy(configuration: oversizedCrisp),
            NativeVideoEncodingPolicy(configuration: oversizedCompact),
            NativeVideoEncodingPolicy(configuration: oversizedSmallest),
        ]
        #expect(oversizedPolicies[0].rateControl == .averageBitRate(65_292_771))
        #expect(oversizedPolicies[1].rateControl == .averageBitRate(46_476_056))
        #expect(oversizedPolicies[2].rateControl == .averageBitRate(17_078_048))

        let oversizedConfigurations = [
            oversizedCrisp,
            oversizedCompact,
            oversizedSmallest,
        ]
        for configuration in oversizedConfigurations {
            let settings = exporter.videoSettings(configuration: configuration)
            #expect(settings[AVVideoWidthKey] as? Int == 5_120)
            #expect(settings[AVVideoHeightKey] as? Int == 1_440)

            let properties = try #require(
                settings[AVVideoCompressionPropertiesKey] as? [String: Any]
            )
            #expect(properties[AVVideoAverageBitRateKey] as? Int != nil)
            #expect(properties[kVTCompressionPropertyKey_Quality as String] == nil)
            #expect(
                properties[
                    kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String
                ] == nil
            )
            #expect(properties[kVTCompressionPropertyKey_DataRateLimits as String] == nil)

            let encoderSpecification = try #require(
                settings[AVVideoEncoderSpecificationKey] as? [String: Any]
            )
            #expect(
                encoderSpecification[
                    kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String
                ] as? Bool == true
            )
            #expect(
                encoderSpecification[
                    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String
                ] == nil
            )
        }

        #expect(NativeH264HardwareGeometry.supports(width: 4_096, height: 2_304))
        #expect(NativeH264HardwareGeometry.supports(width: 2_304, height: 4_096))
        #expect(!NativeH264HardwareGeometry.supports(width: 5_120, height: 1_440))
        #expect(!NativeH264HardwareGeometry.supports(width: 4_096, height: 2_306))
    }

    @Test("The writer produces playable H.264 across a two-hour synthetic timestamp span")
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
        #expect(inspection.videoCodec == kCMVideoCodecType_H264)
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

    @Test("Live capture sustains exact 5120 x 1440 at 30 FPS using hardware HEVC fallback")
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

    @Test("Crisp converts an exact-size 5K HEVC live master to H.264")
    func exportsNativeFiveKHEVCMasterAsH264() async throws {
        let sourceURL = temporaryURL(named: "native-5k60-hevc-source")
        let exportURL = temporaryURL(named: "native-5k60-h264-crisp")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: exportURL)
        }

        let width = 5_120
        let height = 2_880
        let framesPerSecond = 60
        try await writeSyntheticVideo(
            to: sourceURL,
            width: width,
            height: height,
            frameCount: 3,
            framesPerSecond: framesPerSecond
        )

        let source = try await MediaInspector.inspect(sourceURL)
        #expect(source.videoCodec == kCMVideoCodecType_HEVC)
        #expect(source.width == width)
        #expect(source.height == height)
        #expect(abs(source.nominalFramesPerSecond - Double(framesPerSecond)) <= 0.1)

        let configuration = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: source.width,
            sourceHeight: source.height,
            sourceFramesPerSecond: framesPerSecond,
            videoQuality: 0.98,
            sourceVideoQuality: 0.98
        )
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            timeRange: nil,
            configuration: configuration
        )

        let exported = try await MediaInspector.inspect(exportURL)
        #expect(exported.videoCodec == kCMVideoCodecType_H264)
        #expect(exported.width == width)
        #expect(exported.height == height)
        #expect(abs(exported.nominalFramesPerSecond - Double(framesPerSecond)) <= 0.1)
        #expect(try await countVideoSamples(in: exportURL) == 3)
        #expect(try Data(contentsOf: exportURL) != Data(contentsOf: sourceURL))
    }

    @Test("Crisp preserves decoded frame order and visual fidelity")
    func preservesDecodedFrameOrderAndQuality() async throws {
        let sourceURL = temporaryURL(named: "ordered-quality-source")
        let exportURL = temporaryURL(named: "ordered-quality-crisp")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: exportURL)
        }

        let frameCount = 12
        try await writeSyntheticVideo(
            to: sourceURL,
            width: 320,
            height: 180,
            frameCount: frameCount,
            framesPerSecond: 30,
            pattern: .complex
        )
        let source = try await MediaInspector.inspect(sourceURL)
        let configuration = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: source.width,
            sourceHeight: source.height,
            sourceFramesPerSecond: 30,
            videoQuality: 0.98,
            sourceVideoQuality: 0.98
        )
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            timeRange: nil,
            configuration: configuration
        )

        let sourceFrames = try await decodeSampledRGBFrames(in: sourceURL)
        let exportedFrames = try await decodeSampledRGBFrames(in: exportURL)
        #expect(sourceFrames.count == frameCount)
        #expect(exportedFrames.count == frameCount)

        var peakSignalToNoiseRatios: [Double] = []
        for frameIndex in 0..<min(sourceFrames.count, exportedFrames.count) {
            let exportedFrame = exportedFrames[frameIndex]
            let candidateErrors = sourceFrames.map {
                meanSquaredError($0, exportedFrame)
            }
            let bestSourceIndex = candidateErrors.enumerated().min {
                $0.element < $1.element
            }?.offset
            #expect(bestSourceIndex == frameIndex)

            let sameFrameError = candidateErrors[frameIndex]
            peakSignalToNoiseRatios.append(
                sameFrameError == 0
                    ? 100
                    : 10 * log10((255 * 255) / sameFrameError)
            )
        }

        #expect(peakSignalToNoiseRatios.count == frameCount)
        #expect(peakSignalToNoiseRatios.min() ?? 0 >= 24)
        #expect(
            peakSignalToNoiseRatios.reduce(0, +)
                / Double(max(peakSignalToNoiseRatios.count, 1)) >= 28
        )
    }

    @Test("Every quality preset preserves irregular source timing")
    func preservesVariableFrameTimingForEveryPreset() async throws {
        let sourceURL = temporaryURL(named: "vfr-source")
        let crispURL = temporaryURL(named: "vfr-crisp")
        let compactURL = temporaryURL(named: "vfr-compact")
        let smallestURL = temporaryURL(named: "vfr-smallest")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: crispURL)
            try? FileManager.default.removeItem(at: compactURL)
            try? FileManager.default.removeItem(at: smallestURL)
        }

        try await writeIrregularSyntheticVideo(to: sourceURL)
        let source = try await MediaInspector.inspect(sourceURL)
        #expect(source.nominalFramesPerSecond > 15.1)
        #expect(source.nominalFramesPerSecond <= 30.1)

        let asset = AVURLAsset(url: sourceURL)
        let sourceDuration = try await asset.load(.duration)
        let trimStart = CMTime(value: 20, timescale: 1_000)
        let trimRange = CMTimeRange(
            start: trimStart,
            duration: sourceDuration - trimStart
        )
        let crispConfiguration = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: source.width,
            sourceHeight: source.height,
            sourceFramesPerSecond: 30,
            videoQuality: 0.98,
            sourceVideoQuality: 0.98
        )
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: crispURL,
            timeRange: trimRange,
            configuration: crispConfiguration
        )

        let sourceTimes = try await videoPresentationTimes(in: sourceURL)
            .filter { $0 >= trimStart.seconds - 0.0005 }
            .map { $0 - trimStart.seconds }
        let crispTimes = try await videoPresentationTimes(in: crispURL)
        #expect(crispTimes.count == sourceTimes.count)
        for index in 0..<min(crispTimes.count, sourceTimes.count) {
            #expect(abs(crispTimes[index] - sourceTimes[index]) <= 0.001)
        }

        let compactConfiguration = MediaExportConfiguration(
            preset: .compact,
            width: source.width,
            height: source.height,
            framesPerSecond: 30,
            videoQuality: 0.90,
            sourceVideoQuality: 0.98,
            audioBitRate: crispConfiguration.audioBitRate
        )
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: compactURL,
            timeRange: trimRange,
            configuration: compactConfiguration
        )

        let compactTimes = try await videoPresentationTimes(in: compactURL)
        #expect(compactTimes.count == sourceTimes.count)
        for index in 0..<min(compactTimes.count, sourceTimes.count) {
            #expect(abs(compactTimes[index] - sourceTimes[index]) <= 0.001)
        }

        let smallestConfiguration = MediaExportConfiguration(
            preset: .smallest,
            width: source.width,
            height: source.height,
            framesPerSecond: 30,
            videoQuality: 0.85,
            sourceVideoQuality: 0.98,
            audioBitRate: 128_000
        )
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: smallestURL,
            timeRange: trimRange,
            configuration: smallestConfiguration
        )

        let smallestTimes = try await videoPresentationTimes(in: smallestURL)
        #expect(smallestTimes.count == sourceTimes.count)
        for index in 0..<min(smallestTimes.count, sourceTimes.count) {
            #expect(abs(smallestTimes[index] - sourceTimes[index]) <= 0.001)
        }
    }

    @Test("Native export applies trim while preserving dimensions, cadence, and Rec.709 H.264")
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
            preset: .crisp,
            width: 320,
            height: 180,
            framesPerSecond: 30,
            videoQuality: 0.98,
            sourceVideoQuality: 0.98,
            audioBitRate: 64_000
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
        #expect(exported.videoCodec == kCMVideoCodecType_H264)
        #expect(abs(exported.nominalFramesPerSecond - 30) <= 0.1)
        let frameCount = try await countVideoSamples(in: exportURL)
        #expect(frameCount >= 14)
        #expect(frameCount <= 16)
        #expect(abs(exported.duration - 0.5) <= (1.0 / 30.0))
        #expect(try await hasRec709VideoDescription(exportURL))
    }

    @Test("System and microphone tracks are mixed into one exported AAC track")
    func mixesCapturedAudioTracks() async throws {
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
            preset: .crisp,
            width: source.width,
            height: source.height,
            framesPerSecond: 30,
            videoQuality: 0.98,
            audioBitRate: 64_000
        )
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: exportURL,
            timeRange: nil,
            configuration: configuration
        )

        let exported = try await MediaInspector.inspect(exportURL)
        #expect(exported.videoTrackCount == 1)
        #expect(exported.audioTrackCount == 1)
        #expect(abs(exported.duration - 1) <= (1.0 / 30.0))
        #expect(try await firstCodec(in: exportURL, mediaType: .audio) == kAudioFormatMPEG4AAC)
        let audioDataRate = try await firstEstimatedDataRate(in: exportURL, mediaType: .audio)
        #expect(audioDataRate >= 45_000)
        #expect(audioDataRate <= 80_000)
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
            preset: .crisp,
            width: source.width,
            height: source.height,
            framesPerSecond: 30,
            videoQuality: 0.98,
            audioBitRate: 64_000,
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
        #expect(audible.audioTrackCount == 1)
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
                preset: .crisp,
                width: source.width,
                height: source.height,
                framesPerSecond: 30,
                videoQuality: 0.98,
                audioBitRate: 64_000
            )
        )

        let exported = try await MediaInspector.inspect(exportURL)
        #expect(exported.videoTrackCount == 1)
        #expect(exported.audioTrackCount == 1)
        #expect(abs(exported.duration - 2) <= (1.0 / 30.0))
        let exportedAlignment = try await audioVideoAlignment(in: exportURL)
        #expect(exportedAlignment.audioTrackCount == 1)
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
                preset: .crisp,
                width: source.width,
                height: source.height,
                framesPerSecond: 30,
                videoQuality: 0.98,
                audioBitRate: 64_000
            )
        )
        let exported = try await MediaInspector.inspect(exportURL)
        #expect(exported.videoTrackCount == 1)
        #expect(exported.audioTrackCount == 1)
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

    @Test("Quality rungs preserve source format without a target-size contract")
    func qualityRungsPreserveSourceFormat() async throws {
        let sourceURL = temporaryURL(named: "complex-source")
        let crispURL = temporaryURL(named: "quality-crisp")
        let smallestURL = temporaryURL(named: "quality-smallest")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: crispURL)
            try? FileManager.default.removeItem(at: smallestURL)
        }

        try await writeSyntheticVideo(
            to: sourceURL,
            width: 320,
            height: 180,
            frameCount: 60,
            framesPerSecond: 30,
            pattern: .complex
        )

        let crispConfiguration = MediaExportConfiguration(
            preset: .crisp,
            width: 320,
            height: 180,
            framesPerSecond: 30,
            videoQuality: 0.98
        )
        let smallestConfiguration = MediaExportConfiguration(
            preset: .smallest,
            width: 320,
            height: 180,
            framesPerSecond: 30,
            videoQuality: 0.70
        )

        async let crispExport = NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: crispURL,
            timeRange: nil,
            configuration: crispConfiguration
        )
        async let smallestExport = NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: smallestURL,
            timeRange: nil,
            configuration: smallestConfiguration
        )
        _ = try await (crispExport, smallestExport)

        let crisp = try await MediaInspector.inspect(crispURL)
        let smallest = try await MediaInspector.inspect(smallestURL)
        for inspection in [crisp, smallest] {
            #expect(inspection.width == 320)
            #expect(inspection.height == 180)
            #expect(abs(inspection.nominalFramesPerSecond - 30) <= 0.1)
            #expect(inspection.videoCodec == kCMVideoCodecType_H264)
        }
        #expect(try Data(contentsOf: crispURL) != Data(contentsOf: smallestURL))
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
            preset: .compact,
            width: 320,
            height: 180,
            framesPerSecond: 30,
            videoQuality: 0.85
        )
        let large = MediaExportConfiguration(
            preset: .crisp,
            width: 320,
            height: 180,
            framesPerSecond: 30,
            videoQuality: 0.98
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
        #expect(final.videoCodec == kCMVideoCodecType_H264)
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
            preset: .compact,
            width: 320,
            height: 180,
            framesPerSecond: 30,
            videoQuality: 0.90
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
            videoQuality: 0.98,
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

private func writeSyntheticHEVCVideo(
    to outputURL: URL,
    width: Int,
    height: Int,
    frameCount: Int,
    framesPerSecond: Int
) async throws {
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                AVVideoAllowFrameReorderingKey: true,
                kVTCompressionPropertyKey_RealTime as String: false,
                kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: false,
                kVTCompressionPropertyKey_Quality as String: 0.98,
            ],
        ]
    )
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
        throw SyntheticMediaError.cannotAddWriterInput
    }
    writer.add(input)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
    )
    guard writer.startWriting() else {
        throw SyntheticMediaError.cannotStartWriter
    }
    writer.startSession(atSourceTime: .zero)

    for frameIndex in 0..<frameCount {
        for _ in 0..<2_000 where !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard input.isReadyForMoreMediaData else {
            writer.cancelWriting()
            throw SyntheticMediaError.writerBackPressureTimeout
        }
        let sample = try makeVideoSample(
            width: width,
            height: height,
            frameIndex: frameIndex,
            framesPerSecond: framesPerSecond
        )
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
              adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(
                    value: CMTimeValue(frameIndex),
                    timescale: CMTimeScale(framesPerSecond)
                )
              ) else {
            writer.cancelWriting()
            throw SyntheticMediaError.writerAppendFailed
        }
    }

    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw SyntheticMediaError.writerFinishFailed
    }
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
            preset: .crisp,
            width: source.width,
            height: source.height,
            framesPerSecond: framesPerSecond,
            videoQuality: 0.98,
            audioBitRate: 64_000
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
    frequency: Double
) throws -> CMSampleBuffer {
    let sampleRate = 48_000.0
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

private func decodeSampledRGBFrames(in url: URL) async throws -> [[UInt8]] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw SyntheticMediaError.missingVideoTrack
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

    var frames: [[UInt8]] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { continue }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var frame: [UInt8] = []
        frame.reserveCapacity(((width + 7) / 8) * ((height + 7) / 8) * 3)
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let offset = (y * bytesPerRow) + (x * 4)
                frame.append(bytes[offset + 2])
                frame.append(bytes[offset + 1])
                frame.append(bytes[offset])
            }
        }
        frames.append(frame)
    }
    guard reader.status == .completed else { throw SyntheticMediaError.readerFailed }
    return frames
}

private func meanSquaredError(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
    let squaredError = zip(lhs, rhs).reduce(0.0) { partial, samples in
        let difference = Double(Int(samples.0) - Int(samples.1))
        return partial + (difference * difference)
    }
    return squaredError / Double(lhs.count)
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
            == (kCVImageBufferTransferFunction_ITU_R_709_2 as String)
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
