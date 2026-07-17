@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Foundation

enum MP4Validator {
    private struct AudioSignalMetrics {
        let sampleCount: Int64
        let peakAmplitude: Double
        let rmsAmplitude: Double

        static let empty = AudioSignalMetrics(
            sampleCount: 0,
            peakAmplitude: 0,
            rmsAmplitude: 0
        )
    }

    private struct VideoEvidenceMetrics {
        let decodedFrameCount: Int
        let deterministicFixtureFrameCount: Int
        let maximumFixtureColorFamilyCount: Int

        static let empty = VideoEvidenceMetrics(
            decodedFrameCount: 0,
            deterministicFixtureFrameCount: 0,
            maximumFixtureColorFamilyCount: 0
        )
    }

    private struct VideoTimelineMetrics {
        let sampleCount: Int
        let firstPresentationTime: Double
        let lastPresentationTime: Double
        let maximumTimestampGap: Double

        static let empty = VideoTimelineMetrics(
            sampleCount: 0,
            firstPresentationTime: 0,
            lastPresentationTime: 0,
            maximumTimestampGap: 0
        )
    }

    static func validate(_ url: URL) async -> MP4ValidationReport {
        do {
            guard url.isFileURL else {
                return rejectedReport(url, failure: "Expected a local file URL.")
            }
            guard url.pathExtension.lowercased() == "mp4" else {
                return rejectedReport(url, failure: "Expected a file with the .mp4 extension.")
            }

            let resourceValues = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isReadableKey,
            ])
            guard resourceValues.isRegularFile == true else {
                return rejectedReport(url, failure: "The URL is not a regular file.")
            }
            guard resourceValues.isReadable == true else {
                return rejectedReport(url, failure: "The MP4 file is not readable.")
            }

            let asset = AVURLAsset(url: url)
            async let durationValue = asset.load(.duration)
            async let playableValue = asset.load(.isPlayable)
            async let videoTracksValue = asset.loadTracks(withMediaType: .video)
            async let audioTracksValue = asset.loadTracks(withMediaType: .audio)

            let (duration, isPlayable, videoTracks, audioTracks) = try await (
                durationValue,
                playableValue,
                videoTracksValue,
                audioTracksValue
            )

            let durationSeconds = duration.seconds
            let fileSize = Int64(resourceValues.fileSize ?? 0)
            guard isPlayable else {
                return rejectedReport(url, failure: "AVFoundation does not consider the asset playable.")
            }
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                return rejectedReport(url, failure: "The asset has no positive finite duration.")
            }
            guard let videoTrack = videoTracks.first else {
                return rejectedReport(url, failure: "The asset contains no video track.")
            }

            async let naturalSizeValue = videoTrack.load(.naturalSize)
            async let preferredTransformValue = videoTrack.load(.preferredTransform)
            async let nominalFrameRateValue = videoTrack.load(.nominalFrameRate)
            async let formatDescriptionsValue = videoTrack.load(.formatDescriptions)
            let (naturalSize, transform, nominalFrameRate, formatDescriptions) = try await (
                naturalSizeValue,
                preferredTransformValue,
                nominalFrameRateValue,
                formatDescriptionsValue
            )
            let displayedSize = naturalSize.applying(transform)
            let codec = formatDescriptions.first.map {
                fourCharacterCode(CMFormatDescriptionGetMediaSubType($0))
            }
            let h264ProfileIDC = formatDescriptions.first.flatMap(h264ProfileIDC)
            let hasRec709ColorDescription = formatDescriptions.first.map(
                hasRec709ColorDescription
            ) ?? false
            var audioTrackReports: [AudioTrackValidationReport] = []
            for (index, audioTrack) in audioTracks.enumerated() {
                async let audioTimeRangeValue = audioTrack.load(.timeRange)
                async let audioDataRateValue = audioTrack.load(.estimatedDataRate)
                let (audioTimeRange, audioDataRate) = try await (
                    audioTimeRangeValue,
                    audioDataRateValue
                )
                let loadedDuration = audioTimeRange.duration.seconds
                let signal = (try? inspectAudioSignal(
                    asset: asset,
                    track: audioTrack
                )) ?? .empty
                audioTrackReports.append(AudioTrackValidationReport(
                    trackIndex: index,
                    durationSeconds: loadedDuration.isFinite ? loadedDuration : 0,
                    estimatedDataRate: Double(audioDataRate),
                    sampleCount: signal.sampleCount,
                    peakAmplitude: signal.peakAmplitude,
                    rmsAmplitude: signal.rmsAmplitude
                ))
            }
            let firstAudioTrack = audioTrackReports.first
            let audioCodec = try await audioTracks.first?.load(.formatDescriptions)
                .first
                .map { fourCharacterCode(CMFormatDescriptionGetMediaSubType($0)) }
            let videoEvidence = (try? inspectVideoEvidence(
                asset: asset,
                track: videoTrack
            )) ?? .empty
            let videoTimeline = (try? inspectVideoTimeline(
                asset: asset,
                track: videoTrack
            )) ?? .empty

            return MP4ValidationReport(
                protocolVersion: 2,
                valid: fileSize > 0,
                fileURL: url.absoluteString,
                fileSizeBytes: fileSize,
                durationSeconds: durationSeconds,
                videoTrackCount: videoTracks.count,
                audioTrackCount: audioTracks.count,
                audioDurationSeconds: firstAudioTrack?.durationSeconds ?? 0,
                audioEstimatedDataRate: firstAudioTrack?.estimatedDataRate ?? 0,
                audioSampleCount: firstAudioTrack?.sampleCount ?? 0,
                audioPeakAmplitude: firstAudioTrack?.peakAmplitude ?? 0,
                audioRMSAmplitude: firstAudioTrack?.rmsAmplitude ?? 0,
                audioTracks: audioTrackReports,
                width: Int(abs(displayedSize.width).rounded()),
                height: Int(abs(displayedSize.height).rounded()),
                nominalFramesPerSecond: Double(nominalFrameRate),
                videoCodec: codec,
                h264ProfileIDC: h264ProfileIDC,
                hasRec709ColorDescription: hasRec709ColorDescription,
                videoSampleCount: videoTimeline.sampleCount,
                firstVideoPresentationTimeSeconds: videoTimeline.firstPresentationTime,
                lastVideoPresentationTimeSeconds: videoTimeline.lastPresentationTime,
                maximumVideoTimestampGapSeconds: videoTimeline.maximumTimestampGap,
                audioCodec: audioCodec,
                decodedVideoFrameCount: videoEvidence.decodedFrameCount,
                deterministicFixtureFrameCount: videoEvidence.deterministicFixtureFrameCount,
                deterministicFixtureColorFamilyCount:
                    videoEvidence.maximumFixtureColorFamilyCount,
                failure: fileSize > 0 ? nil : "The MP4 file is empty."
            )
        } catch {
            return rejectedReport(url, failure: error.localizedDescription)
        }
    }

    static func rejectedReport(_ url: URL, failure: String) -> MP4ValidationReport {
        MP4ValidationReport(
            protocolVersion: 2,
            valid: false,
            fileURL: url.absoluteString,
            fileSizeBytes: 0,
            durationSeconds: 0,
            videoTrackCount: 0,
            audioTrackCount: 0,
            audioDurationSeconds: 0,
            audioEstimatedDataRate: 0,
            audioSampleCount: 0,
            audioPeakAmplitude: 0,
            audioRMSAmplitude: 0,
            audioTracks: [],
            width: 0,
            height: 0,
            nominalFramesPerSecond: 0,
            videoCodec: nil,
            h264ProfileIDC: nil,
            hasRec709ColorDescription: false,
            videoSampleCount: 0,
            firstVideoPresentationTimeSeconds: 0,
            lastVideoPresentationTimeSeconds: 0,
            maximumVideoTimestampGapSeconds: 0,
            audioCodec: nil,
            decodedVideoFrameCount: 0,
            deterministicFixtureFrameCount: 0,
            deterministicFixtureColorFamilyCount: 0,
            failure: failure
        )
    }

    private static func fourCharacterCode(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", value)
    }

    private static func h264ProfileIDC(_ description: CMFormatDescription) -> Int? {
        guard let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary?,
              let atoms = extensions[
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
              ] as? NSDictionary else {
            return nil
        }
        let configuration = (atoms["avcC"] as? Data)
            ?? (atoms["avcC"] as? NSData).map { $0 as Data }
        guard let configuration, configuration.count > 1 else { return nil }
        return Int(configuration[configuration.index(configuration.startIndex, offsetBy: 1)])
    }

    private static func hasRec709ColorDescription(
        _ description: CMFormatDescription
    ) -> Bool {
        guard let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary?
        else { return false }
        return (extensions[kCVImageBufferColorPrimariesKey] as? String)
            == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            && (extensions[kCVImageBufferTransferFunctionKey] as? String)
                == (kCVImageBufferTransferFunction_ITU_R_709_2 as String)
            && (extensions[kCVImageBufferYCbCrMatrixKey] as? String)
                == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    private static func inspectVideoTimeline(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> VideoTimelineMetrics {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .empty }
        reader.add(output)
        guard reader.startReading() else { return .empty }

        var sampleCount = 0
        var first: Double?
        var last: Double?
        var maximumGap = 0.0
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            guard count > 0, presentationTime.isNumeric else { continue }
            let seconds = presentationTime.seconds
            guard seconds.isFinite else { continue }
            if let last {
                maximumGap = max(maximumGap, seconds - last)
            } else {
                first = seconds
            }
            last = seconds
            sampleCount += count
        }
        guard reader.status == .completed else { return .empty }
        return VideoTimelineMetrics(
            sampleCount: sampleCount,
            firstPresentationTime: first ?? 0,
            lastPresentationTime: last ?? 0,
            maximumTimestampGap: maximumGap
        )
    }

    /// Decodes the first audio track to interleaved Float32 PCM and measures
    /// its actual signal. Track metadata alone can report a valid AAC track
    /// even when every encoded sample is silence.
    private static func inspectAudioSignal(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> AudioSignalMetrics {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .empty }
        reader.add(output)
        guard reader.startReading() else { return .empty }

        var sampleCount: Int64 = 0
        var peakAmplitude = 0.0
        var sumOfSquares = 0.0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = byteCount / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }

            var samples = Array(repeating: Float.zero, count: floatCount)
            let copyStatus = samples.withUnsafeMutableBytes { bytes in
                guard let destination = bytes.baseAddress else { return OSStatus(-1) }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: floatCount * MemoryLayout<Float>.size,
                    destination: destination
                )
            }
            guard copyStatus == noErr else { continue }

            for sample in samples where sample.isFinite {
                let amplitude = abs(Double(sample))
                peakAmplitude = max(peakAmplitude, amplitude)
                sumOfSquares += amplitude * amplitude
                sampleCount += 1
            }
        }

        guard reader.status == .completed, sampleCount > 0 else { return .empty }
        return AudioSignalMetrics(
            sampleCount: sampleCount,
            peakAmplitude: peakAmplitude,
            rmsAmplitude: sqrt(sumOfSquares / Double(sampleCount))
        )
    }

    /// Decodes several actual video frames and looks for the fixture's stable
    /// visual fingerprint: its saturated seven-color calibration bar plus the
    /// large light/dark checkerboard. Track metadata alone could validate an
    /// unrelated or blank screen recording, so real acceptance asserts these
    /// decoded-pixel fields as well as dimensions and codec.
    private static func inspectVideoEvidence(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> VideoEvidenceMetrics {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .empty }
        reader.add(output)
        guard reader.startReading() else { return .empty }
        defer { reader.cancelReading() }

        let maximumFrames = 8
        var decodedFrameCount = 0
        var fixtureFrameCount = 0
        var maximumColorFamilyCount = 0

        while decodedFrameCount < maximumFrames,
              let sampleBuffer = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            decodedFrameCount += 1
            let evidence = inspectFixturePixels(pixelBuffer)
            maximumColorFamilyCount = max(
                maximumColorFamilyCount,
                evidence.colorFamilyCount
            )
            if evidence.matchesFixture {
                fixtureFrameCount += 1
            }
        }

        return VideoEvidenceMetrics(
            decodedFrameCount: decodedFrameCount,
            deterministicFixtureFrameCount: fixtureFrameCount,
            maximumFixtureColorFamilyCount: maximumColorFamilyCount
        )
    }

    private static func inspectFixturePixels(
        _ pixelBuffer: CVPixelBuffer
    ) -> (matchesFixture: Bool, colorFamilyCount: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return (false, 0)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            return (false, 0)
        }

        // Roughly 30k–70k samples per frame across typical Retina capture
        // sizes. That is dense enough to survive H.264 chroma subsampling but
        // bounded enough for an acceptance helper process.
        let stride = max(1, min(width, height) / 180)
        var familyCounts = Array(repeating: 0, count: 7)
        var lightNeutralCount = 0
        var darkNeutralCount = 0
        var sampledPixelCount = 0
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

        for y in Swift.stride(from: 0, to: height, by: stride) {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let offset = x * 4
                let blue = Int(row[offset])
                let green = Int(row[offset + 1])
                let red = Int(row[offset + 2])
                sampledPixelCount += 1

                if red > 160, red > green + 50, red > blue + 50, green < 140 {
                    familyCounts[0] += 1 // red
                }
                if red > 180, green > 70, green < 190, blue < 105,
                   red > green + 35, green > blue + 30 {
                    familyCounts[1] += 1 // orange
                }
                if red > 170, green > 150, blue < 130, abs(red - green) < 105 {
                    familyCounts[2] += 1 // yellow
                }
                if green > 130, green > red + 30, green > blue + 20 {
                    familyCounts[3] += 1 // green
                }
                if green > 135, blue > 135, red < 155, abs(green - blue) < 110 {
                    familyCounts[4] += 1 // cyan
                }
                if blue > 140, blue > red + 40, blue > green + 25 {
                    familyCounts[5] += 1 // blue
                }
                if red > 100, blue > 130, green < 145,
                   red > green + 20, blue > green + 35 {
                    familyCounts[6] += 1 // purple
                }

                let maximum = max(red, green, blue)
                let minimum = min(red, green, blue)
                if minimum > 180, maximum - minimum < 50 {
                    lightNeutralCount += 1
                } else if maximum < 80, maximum - minimum < 35 {
                    darkNeutralCount += 1
                }
            }
        }

        guard sampledPixelCount > 0 else { return (false, 0) }
        let familyThreshold = max(4, sampledPixelCount / 5_000)
        let colorFamilyCount = familyCounts.count(where: { $0 >= familyThreshold })
        let neutralThreshold = max(20, sampledPixelCount / 20)
        return (
            colorFamilyCount >= 6
                && lightNeutralCount >= neutralThreshold
                && darkNeutralCount >= neutralThreshold,
            colorFamilyCount
        )
    }
}

@MainActor
enum FileURLPasteboardResolver {
    static func firstFileURL(in pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        )?.compactMap { object in
            (object as? NSURL).map { $0 as URL }
        }.first
    }
}
