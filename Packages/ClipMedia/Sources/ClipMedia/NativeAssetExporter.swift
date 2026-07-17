@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

public enum NativeAssetExporterError: Error, Equatable, Sendable {
    case cannotCreateReader(String)
    case cannotCreateWriter(String)
    case cannotAddReaderOutput(String)
    case cannotAddWriterInput(String)
    case cannotStartReading(String)
    case cannotStartWriting(String)
    case invalidConfiguration
    case invalidTimeRange
    case missingVideoTrack
    case sourceAndDestinationMustDiffer
    case exportFailed(String)
    case publishFailed(String)
}

public protocol MediaExporting: Sendable {
    func export(
        sourceURL: URL,
        destinationURL: URL,
        timeRange: CMTimeRange?,
        configuration: MediaExportConfiguration
    ) async throws -> URL
}

/// A controlled, native AVFoundation transcode pipeline.
///
/// Unlike `AVAssetExportSession` presets, this pipeline applies every value in
/// `MediaExportConfiguration`: video dimensions, frame cadence, H.264 quality
/// and rate policy, AAC bitrate, and the optional soft file-size target. Source
/// files are opened read-only. A complete MP4 is first written beside the
/// destination and then atomically renamed into place, so a failed or
/// concurrent export never makes a partially written destination visible.
public struct NativeAssetExporter: MediaExporting {
    public init() {}

    public func export(
        sourceURL: URL,
        destinationURL: URL,
        timeRange: CMTimeRange?,
        configuration: MediaExportConfiguration
    ) async throws -> URL {
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            throw NativeAssetExporterError.sourceAndDestinationMustDiffer
        }
        try validate(configuration)

        let asset = AVURLAsset(url: sourceURL)
        let sourceDuration = try await asset.load(.duration)
        let exportRange = timeRange ?? CMTimeRange(start: .zero, duration: sourceDuration)
        guard exportRange.start.isNumeric,
              exportRange.duration.isNumeric,
              exportRange.start >= .zero,
              exportRange.duration > .zero,
              exportRange.end <= sourceDuration else {
            throw NativeAssetExporterError.invalidTimeRange
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw NativeAssetExporterError.missingVideoTrack
        }
        let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        let exportedAudioTracks = configuration.includesAudio ? sourceAudioTracks : []

        let temporaryURL = temporarySibling(of: destinationURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            if try await canReuseCompatibleSource(
                videoTracks: videoTracks,
                audioTracks: sourceAudioTracks,
                sourceDuration: sourceDuration,
                exportRange: exportRange,
                configuration: configuration
            ) {
                // A compatible full-range Crisp master is higher fidelity than
                // a second lossy H.264 generation. Copy beside the destination,
                // validate that temporary MP4, then retain the exporter's
                // atomic publication contract.
                try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
                try await validateReusableOutput(
                    at: temporaryURL,
                    configuration: configuration,
                    expectedAudioTrackCount: sourceAudioTracks.count
                )
            } else {
                try await transcode(
                    asset: asset,
                    videoTrack: videoTrack,
                    audioTracks: exportedAudioTracks,
                    outputURL: temporaryURL,
                    timeRange: exportRange,
                    configuration: configuration
                )
            }
            try AtomicFilePublisher.publish(temporaryURL, replacing: destinationURL)
            return destinationURL
        } catch let error as NativeAssetExporterError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NativeAssetExporterError.exportFailed(error.localizedDescription)
        }
    }

    private func canReuseCompatibleSource(
        videoTracks: [AVAssetTrack],
        audioTracks: [AVAssetTrack],
        sourceDuration: CMTime,
        exportRange: CMTimeRange,
        configuration: MediaExportConfiguration
    ) async throws -> Bool {
        guard videoTracks.count == 1, let videoTrack = videoTracks.first else { return false }

        async let naturalSizeValue = videoTrack.load(.naturalSize)
        async let transformValue = videoTrack.load(.preferredTransform)
        async let frameRateValue = videoTrack.load(.nominalFrameRate)
        async let dataRateValue = videoTrack.load(.estimatedDataRate)
        async let descriptionsValue = videoTrack.load(.formatDescriptions)
        let (naturalSize, transform, frameRate, dataRate, descriptions) = try await (
            naturalSizeValue,
            transformValue,
            frameRateValue,
            dataRateValue,
            descriptionsValue
        )
        let displayedSize = naturalSize.applying(transform)
        let videoDescription = descriptions.first

        var facts = CompatibleSourceReuseFacts(
            isFullRange: exportRange.start == .zero && exportRange.duration == sourceDuration,
            videoTrackCount: videoTracks.count,
            videoCodec: videoDescription.map(CMFormatDescriptionGetMediaSubType),
            width: Int(abs(displayedSize.width).rounded()),
            height: Int(abs(displayedSize.height).rounded()),
            framesPerSecond: Double(frameRate),
            videoDataRate: Double(dataRate),
            hasRec709ColorDescription: videoDescription.map(hasRec709Description) ?? false,
            audioTrackCount: audioTracks.count,
            audioCodec: nil,
            audioDataRate: nil,
            audioSampleRate: nil,
            audioChannelCount: nil
        )

        if audioTracks.count == 1, let audioTrack = audioTracks.first {
            async let audioDataRateValue = audioTrack.load(.estimatedDataRate)
            async let audioDescriptionsValue = audioTrack.load(.formatDescriptions)
            let (audioDataRate, audioDescriptions) = try await (
                audioDataRateValue,
                audioDescriptionsValue
            )
            if let audioDescription = audioDescriptions.first {
                facts.audioCodec = CMFormatDescriptionGetMediaSubType(audioDescription)
                facts.audioDataRate = Double(audioDataRate)
                if let stream = CMAudioFormatDescriptionGetStreamBasicDescription(
                    audioDescription
                )?.pointee {
                    facts.audioSampleRate = stream.mSampleRate
                    facts.audioChannelCount = Int(stream.mChannelsPerFrame)
                }
            }
        }

        return CompatibleSourceReusePolicy.canReuse(facts, for: configuration)
    }

    private func validateReusableOutput(
        at url: URL,
        configuration: MediaExportConfiguration,
        expectedAudioTrackCount: Int
    ) async throws {
        let inspection = try await MediaInspector.inspect(url)
        guard inspection.fileSize > 0,
              inspection.videoTrackCount == 1,
              inspection.audioTrackCount == expectedAudioTrackCount,
              inspection.width == configuration.width,
              inspection.height == configuration.height,
              inspection.nominalFramesPerSecond <= Double(configuration.framesPerSecond) + 0.1,
              inspection.videoCodec == kCMVideoCodecType_H264 else {
            throw NativeAssetExporterError.exportFailed(
                "An eligible source failed temporary-output validation"
            )
        }
    }

    private func hasRec709Description(_ description: CMFormatDescription) -> Bool {
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

    private func transcode(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        audioTracks: [AVAssetTrack],
        outputURL: URL,
        timeRange: CMTimeRange,
        configuration: MediaExportConfiguration
    ) async throws {
        let sourceNominalFramesPerSecond = Double(try await videoTrack.load(.nominalFrameRate))
        let shouldLimitFrameRate = sourceNominalFramesPerSecond.isFinite
            && sourceNominalFramesPerSecond
                > Double(configuration.framesPerSecond) + 0.1

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw NativeAssetExporterError.cannotCreateReader(error.localizedDescription)
        }
        reader.timeRange = timeRange

        let videoOutput = try await makeVideoOutput(
            track: videoTrack,
            timeRange: timeRange,
            configuration: configuration,
            shouldLimitFrameRate: shouldLimitFrameRate
        )
        guard reader.canAdd(videoOutput) else {
            throw NativeAssetExporterError.cannotAddReaderOutput("video")
        }
        reader.add(videoOutput)

        let audioOutput = makeAudioOutput(tracks: audioTracks)
        if let audioOutput {
            guard reader.canAdd(audioOutput) else {
                throw NativeAssetExporterError.cannotAddReaderOutput("audio mix")
            }
            reader.add(audioOutput)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw NativeAssetExporterError.cannotCreateWriter(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        let effectiveVideoBitRate = MediaExportSizeEstimator.effectiveVideoBitRate(
            configuration: configuration,
            duration: timeRange.duration.seconds,
            includesAudio: audioOutput != nil
        )
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings(
                configuration: configuration,
                effectiveBitRate: effectiveVideoBitRate
            )
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw NativeAssetExporterError.cannotAddWriterInput("H.264 video")
        }
        writer.add(videoInput)

        let audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioSettings(bitRate: configuration.audioBitRate)
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw NativeAssetExporterError.cannotAddWriterInput("AAC audio")
            }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw NativeAssetExporterError.cannotStartWriting(
                writer.error?.localizedDescription ?? "AVAssetWriter rejected startWriting"
            )
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw NativeAssetExporterError.cannotStartReading(
                reader.error?.localizedDescription ?? "AVAssetReader rejected startReading"
            )
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try await copySamples(
                reader: reader,
                writer: writer,
                videoOutput: videoOutput,
                videoInput: videoInput,
                audioOutput: audioOutput,
                audioInput: audioInput,
                sourceStart: timeRange.start,
                shouldLimitFrameRate: shouldLimitFrameRate,
                maximumFramesPerSecond: configuration.framesPerSecond
            )
            writer.endSession(atSourceTime: timeRange.duration)
            await writer.finishWriting()

            guard reader.status == .completed else {
                throw NativeAssetExporterError.exportFailed(
                    reader.error?.localizedDescription ?? "AVAssetReader did not complete"
                )
            }
            guard writer.status == .completed else {
                throw NativeAssetExporterError.exportFailed(
                    writer.error?.localizedDescription ?? "AVAssetWriter did not complete"
                )
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    /// Interleaving the two offline outputs keeps AVAssetReader's bounded
    /// decoder queues draining without introducing Sendability-unsafe media
    /// objects into detached tasks. Yielding only happens when the encoder is
    /// applying backpressure.
    private func copySamples(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderAudioMixOutput?,
        audioInput: AVAssetWriterInput?,
        sourceStart: CMTime,
        shouldLimitFrameRate: Bool,
        maximumFramesPerSecond: Int
    ) async throws {
        var videoFinished = false
        var audioFinished = audioOutput == nil
        var lastVideoPresentationTime: CMTime?
        let minimumVideoFrameDuration = shouldLimitFrameRate
            ? CMTime(value: 1, timescale: CMTimeScale(maximumFramesPerSecond))
            : nil

        while !videoFinished || !audioFinished {
            try Task.checkCancellation()
            if reader.status == .failed || reader.status == .cancelled {
                throw NativeAssetExporterError.exportFailed(
                    reader.error?.localizedDescription ?? "AVAssetReader stopped unexpectedly"
                )
            }
            if writer.status == .failed || writer.status == .cancelled {
                throw NativeAssetExporterError.exportFailed(
                    writer.error?.localizedDescription ?? "AVAssetWriter stopped unexpectedly"
                )
            }

            var madeProgress = false
            if !videoFinished, videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    let retimed = try sample.retimed(relativeTo: sourceStart)
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(retimed)
                    let mayAppend: Bool
                    if let lastVideoPresentationTime, let minimumVideoFrameDuration {
                        // Allow half a millisecond for rational-timescale rounding.
                        let tolerance = CMTime(value: 1, timescale: 2_000)
                        mayAppend = presentationTime + tolerance
                            >= lastVideoPresentationTime + minimumVideoFrameDuration
                    } else {
                        // Preserve every source sample, including legitimate
                        // VFR/jittered samples closer together than the nominal
                        // cadence, unless this preset actually lowers source FPS.
                        mayAppend = true
                    }
                    if mayAppend {
                        guard videoInput.append(retimed) else {
                            throw NativeAssetExporterError.exportFailed(
                                writer.error?.localizedDescription
                                    ?? "H.264 encoder rejected a frame"
                            )
                        }
                        lastVideoPresentationTime = presentationTime
                    }
                } else {
                    videoInput.markAsFinished()
                    videoFinished = true
                }
                madeProgress = true
            }

            if !audioFinished,
               let audioOutput,
               let audioInput,
               audioInput.isReadyForMoreMediaData {
                if let sample = audioOutput.copyNextSampleBuffer() {
                    let retimed = try sample.retimed(relativeTo: sourceStart)
                    guard audioInput.append(retimed) else {
                        throw NativeAssetExporterError.exportFailed(
                            writer.error?.localizedDescription ?? "AAC encoder rejected a sample"
                        )
                    }
                } else {
                    audioInput.markAsFinished()
                    audioFinished = true
                }
                madeProgress = true
            }

            if !madeProgress {
                await Task.yield()
            }
        }
    }

    private func makeVideoOutput(
        track: AVAssetTrack,
        timeRange: CMTimeRange,
        configuration: MediaExportConfiguration,
        shouldLimitFrameRate: Bool
    ) async throws -> AVAssetReaderOutput {
        async let naturalSizeValue = track.load(.naturalSize)
        async let preferredTransformValue = track.load(.preferredTransform)
        let (naturalSize, preferredTransform) = try await (
            naturalSizeValue,
            preferredTransformValue
        )

        let pixelBufferSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        // Region captures have identity orientation and Compact preserves their
        // dimensions when they already fit inside 1080p. Avoiding a no-op video
        // composition here removes a full compositor pass while retaining the
        // controlled H.264 transcode, frame-rate limiting, trim, and bitrate.
        // Rotated or resized sources continue through the composition path.
        if preferredTransform.isIdentity,
           Int(naturalSize.width.rounded()) == configuration.width,
           Int(naturalSize.height.rounded()) == configuration.height {
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: pixelBufferSettings
            )
            output.alwaysCopiesSampleData = false
            return output
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(
            width: configuration.width,
            height: configuration.height
        )
        videoComposition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.framesPerSecond)
        )
        if !shouldLimitFrameRate {
            // Derive composition requests from the source track so resizing or
            // orientation correction preserves its exact VFR sample cadence.
            // A fixed frameDuration here would turn (for example) a 28.29 FPS
            // screen recording into a synthetic 30 FPS schedule even though
            // the selected export does not request a frame-rate reduction.
            videoComposition.sourceTrackIDForFrameTiming = track.trackID
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        instruction.backgroundColor = CGColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1
        )
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(
            fittedTransform(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                outputSize: videoComposition.renderSize
            ),
            at: timeRange.start
        )
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: pixelBufferSettings
        )
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        return output
    }

    private func makeAudioOutput(tracks: [AVAssetTrack]) -> AVAssetReaderAudioMixOutput? {
        guard !tracks.isEmpty else { return nil }

        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            // Keep overlapping microphone and system signals below clipping.
            parameters.setVolume(tracks.count > 1 ? 0.8 : 1, at: .zero)
            return parameters
        }
        output.audioMix = mix
        output.alwaysCopiesSampleData = false
        return output
    }

    func videoSettings(
        configuration: MediaExportConfiguration,
        effectiveBitRate: Int
    ) -> [String: Any] {
        let policy = NativeVideoEncodingPolicy(
            configuration: configuration,
            effectiveBitRate: effectiveBitRate
        )
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: effectiveBitRate,
            AVVideoExpectedSourceFrameRateKey: configuration.framesPerSecond,
            AVVideoMaxKeyFrameIntervalKey: configuration.framesPerSecond * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: policy.allowsFrameReordering,
            kVTCompressionPropertyKey_RealTime as String: policy.isRealTime,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String:
                policy.prioritizesEncodingSpeedOverQuality,
        ]
        if let quality = policy.quality {
            compressionProperties[kVTCompressionPropertyKey_Quality as String] = quality
        }
        if let hardDataRateLimit = policy.hardDataRateLimitBytesPerSecond {
            compressionProperties[kVTCompressionPropertyKey_DataRateLimits as String] = [
                hardDataRateLimit,
                1,
            ]
        }
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compressionProperties,
        ]
    }

    private func audioSettings(bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitRate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    private func fittedTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        outputSize: CGSize
    ) -> CGAffineTransform {
        let sourceRect = CGRect(origin: .zero, size: naturalSize)
        let orientedRect = sourceRect.applying(preferredTransform)
        let orientedWidth = max(abs(orientedRect.width), 1)
        let orientedHeight = max(abs(orientedRect.height), 1)
        let scale = min(
            outputSize.width / orientedWidth,
            outputSize.height / orientedHeight
        )

        // Multiplying each component scales the transformed coordinates. This
        // avoids the easy-to-misread order semantics of affine concatenation.
        var result = CGAffineTransform(
            a: preferredTransform.a * scale,
            b: preferredTransform.b * scale,
            c: preferredTransform.c * scale,
            d: preferredTransform.d * scale,
            tx: preferredTransform.tx * scale,
            ty: preferredTransform.ty * scale
        )
        let scaledRect = sourceRect.applying(result)
        result.tx += ((outputSize.width - scaledRect.width) / 2) - scaledRect.minX
        result.ty += ((outputSize.height - scaledRect.height) / 2) - scaledRect.minY
        return result
    }

    private func validate(_ configuration: MediaExportConfiguration) throws {
        guard configuration.width >= 2,
              configuration.height >= 2,
              configuration.width.isMultiple(of: 2),
              configuration.height.isMultiple(of: 2),
              (1...240).contains(configuration.framesPerSecond),
              configuration.videoBitRate > 0,
              configuration.audioBitRate > 0,
              configuration.approximateTargetBytes.map({ $0 > 0 }) ?? true else {
            throw NativeAssetExporterError.invalidConfiguration
        }
    }

    private func temporarySibling(of destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).clip-export-\(UUID().uuidString).mp4"
        )
    }
}

struct CompatibleSourceReuseFacts: Equatable {
    var isFullRange: Bool
    var videoTrackCount: Int
    var videoCodec: FourCharCode?
    var width: Int
    var height: Int
    var framesPerSecond: Double
    var videoDataRate: Double
    var hasRec709ColorDescription: Bool
    var audioTrackCount: Int
    var audioCodec: FourCharCode?
    var audioDataRate: Double?
    var audioSampleRate: Double?
    var audioChannelCount: Int?
}

enum CompatibleSourceReusePolicy {
    static func canReuse(
        _ facts: CompatibleSourceReuseFacts,
        for configuration: MediaExportConfiguration
    ) -> Bool {
        guard configuration.preset == .crisp,
              facts.isFullRange,
              facts.videoTrackCount == 1,
              facts.videoCodec == kCMVideoCodecType_H264,
              facts.width == configuration.width,
              facts.height == configuration.height,
              facts.framesPerSecond > 0,
              // `nominalFrameRate` is derived from real sample timing and can
              // be below the durable 30/60 capture ceiling (for example 28.29
              // FPS on a 30 FPS timeline). Reuse is safe whenever the source
              // does not exceed that ceiling; requiring equality needlessly
              // re-encoded full-range Crisp exports.
              facts.framesPerSecond <= Double(configuration.framesPerSecond) + 0.1,
              facts.hasRec709ColorDescription else {
            return false
        }

        if !configuration.includesAudio {
            // Copying an otherwise compatible source would preserve its audio.
            // A silent export therefore reuses only an already-silent source.
            return facts.audioTrackCount == 0
        }

        guard facts.audioTrackCount <= 1 else { return false }
        guard facts.audioTrackCount == 1 else { return true }
        return facts.audioCodec == kAudioFormatMPEG4AAC
            && facts.audioDataRate.map { $0 > 0 && $0 <= Double(configuration.audioBitRate) }
                == true
            && facts.audioSampleRate == 48_000
            && facts.audioChannelCount == 2
    }
}

/// VideoToolbox policy for a single offline export generation. Compact and
/// Crisp retain their resolution/FPS-derived average bitrate as a soft target,
/// but quality is the primary control and no hard byte-rate limit is installed.
/// Smallest keeps constrained ABR and allows ten percent burst headroom so the
/// encoder can preserve difficult frames without drifting far from its target.
struct NativeVideoEncodingPolicy: Equatable, Sendable {
    static let smallestHardLimitHeadroom = 1.10

    let quality: Double?
    let hardDataRateLimitBytesPerSecond: Int?
    let isRealTime: Bool
    let prioritizesEncodingSpeedOverQuality: Bool
    let allowsFrameReordering: Bool

    init(
        configuration: MediaExportConfiguration,
        effectiveBitRate: Int
    ) {
        switch configuration.preset {
        case .compact:
            quality = 0.85
            hardDataRateLimitBytesPerSecond = nil
        case .crisp:
            quality = 0.98
            hardDataRateLimitBytesPerSecond = nil
        case .smallest:
            quality = nil
            hardDataRateLimitBytesPerSecond = max(
                1,
                Int(
                    (Double(effectiveBitRate)
                        * Self.smallestHardLimitHeadroom / 8).rounded(.up)
                )
            )
        }
        isRealTime = false
        prioritizesEncodingSpeedOverQuality = false
        allowsFrameReordering = true
    }
}

private enum AtomicFilePublisher {
    static func publish(_ sourceURL: URL, replacing destinationURL: URL) throws {
        var publishResult: Int32 = -1
        var publishError: Int32 = 0
        let represented = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return false }
                publishResult = Darwin.rename(sourcePath, destinationPath)
                publishError = errno
                return true
            }
        }
        guard represented, publishResult == 0 else {
            let message: String
            if represented {
                message = String(cString: strerror(publishError))
            } else {
                message = "The destination path cannot be represented by the file system"
            }
            throw NativeAssetExporterError.publishFailed(message)
        }
    }
}

private extension CMSampleBuffer {
    func retimed(relativeTo sourceStart: CMTime) throws -> CMSampleBuffer {
        var timingCount = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            self,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        guard countStatus == noErr, timingCount > 0 else {
            throw NativeAssetExporterError.exportFailed(
                "Cannot read sample timing (OSStatus \(countStatus))"
            )
        }

        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingCount
        )
        let fillStatus = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                self,
                entryCount: timingCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: &timingCount
            )
        }
        guard fillStatus == noErr else {
            throw NativeAssetExporterError.exportFailed(
                "Cannot copy sample timing (OSStatus \(fillStatus))"
            )
        }

        for index in timing.indices {
            if timing[index].presentationTimeStamp.isNumeric {
                timing[index].presentationTimeStamp = max(
                    .zero,
                    timing[index].presentationTimeStamp - sourceStart
                )
            }
            if timing[index].decodeTimeStamp.isNumeric {
                timing[index].decodeTimeStamp = max(
                    .zero,
                    timing[index].decodeTimeStamp - sourceStart
                )
            }
        }

        var output: CMSampleBuffer?
        let copyStatus = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: self,
                sampleTimingEntryCount: timingCount,
                sampleTimingArray: buffer.baseAddress,
                sampleBufferOut: &output
            )
        }
        guard copyStatus == noErr, let output else {
            throw NativeAssetExporterError.exportFailed(
                "Cannot retime sample (OSStatus \(copyStatus))"
            )
        }
        return output
    }
}
