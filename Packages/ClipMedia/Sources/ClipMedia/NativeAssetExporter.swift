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
/// `MediaExportConfiguration`: native video dimensions and cadence, H.264
/// quality, and AAC bitrate. Source
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
        try await validateSourceFormat(videoTrack, configuration: configuration)
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
        async let descriptionsValue = videoTrack.load(.formatDescriptions)
        let (naturalSize, transform, frameRate, descriptions) = try await (
            naturalSizeValue,
            transformValue,
            frameRateValue,
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

    private func validateSourceFormat(
        _ videoTrack: AVAssetTrack,
        configuration: MediaExportConfiguration
    ) async throws {
        async let naturalSizeValue = videoTrack.load(.naturalSize)
        async let transformValue = videoTrack.load(.preferredTransform)
        async let frameRateValue = videoTrack.load(.nominalFrameRate)
        let (naturalSize, transform, frameRate) = try await (
            naturalSizeValue,
            transformValue,
            frameRateValue
        )
        let displayedSize = naturalSize.applying(transform)
        let sourceWidth = Int(abs(displayedSize.width).rounded())
        let sourceHeight = Int(abs(displayedSize.height).rounded())
        let sourceFramesPerSecond = Double(frameRate)

        guard sourceWidth == configuration.width,
              sourceHeight == configuration.height,
              sourceFramesPerSecond.isFinite,
              sourceFramesPerSecond > 0,
              sourceFramesPerSecond <= Double(configuration.framesPerSecond) + 0.1 else {
            throw NativeAssetExporterError.invalidConfiguration
        }
    }

    private func transcode(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        audioTracks: [AVAssetTrack],
        outputURL: URL,
        timeRange: CMTimeRange,
        configuration: MediaExportConfiguration
    ) async throws {
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
            configuration: configuration
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

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings(configuration: configuration)
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
                sourceStart: timeRange.start
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
        sourceStart: CMTime
    ) async throws {
        var videoFinished = false
        var audioFinished = audioOutput == nil

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
                    guard videoInput.append(retimed) else {
                        throw NativeAssetExporterError.exportFailed(
                            writer.error?.localizedDescription
                                ?? "H.264 encoder rejected a frame"
                        )
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
        configuration: MediaExportConfiguration
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

        // Region captures have identity orientation and preserve their native
        // dimensions. Avoiding a no-op compositor pass retains exact source
        // sample timing. Rotated sources continue through the composition path.
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
        // Derive composition requests from the source track so orientation
        // correction preserves exact VFR sample cadence. A fixed synthetic
        // schedule would corrupt durable source timing such as 28.29 FPS.
        videoComposition.sourceTrackIDForFrameTiming = track.trackID

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

    func videoSettings(configuration: MediaExportConfiguration) -> [String: Any] {
        let policy = NativeVideoEncodingPolicy(configuration: configuration)
        var compressionProperties: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: configuration.framesPerSecond,
            AVVideoMaxKeyFrameIntervalKey: configuration.framesPerSecond * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: policy.allowsFrameReordering,
            kVTCompressionPropertyKey_RealTime as String: policy.isRealTime,
        ]
        var encoderSpecification: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
        ]
        switch policy.rateControl {
        case let .quality(value):
            // Quality and quality-over-speed are supported by Apple's hardware
            // H.264 encoder. Requiring hardware prevents AVFoundation from
            // silently selecting a software encoder that rejects these keys
            // with an uncaught Objective-C exception.
            encoderSpecification[
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String
            ] = true
            compressionProperties[kVTCompressionPropertyKey_Quality as String] = value
            compressionProperties[
                kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String
            ] = false

        case let .averageBitRate(bitsPerSecond):
            // Apple's native software H.264 encoder is required beyond the
            // hardware geometry envelope. It exposes AverageBitRate but not
            // Quality or PrioritizeEncodingSpeedOverQuality, so keep the exact
            // dimensions and use a soft rate target without a hard limit.
            compressionProperties[AVVideoAverageBitRateKey] = bitsPerSecond
        }
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoEncoderSpecificationKey: encoderSpecification,
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
              configuration.videoQuality.isFinite,
              (0...1).contains(configuration.videoQuality),
              configuration.sourceVideoQuality.map({
                  $0.isFinite && (0...1).contains($0)
              }) ?? true,
              configuration.audioBitRate > 0 else {
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
              configuration.sourceVideoQuality.map({
                  abs($0 - configuration.videoQuality) <= 1e-9
              }) == true,
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

/// VideoToolbox policy for a single offline export generation. Hardware H.264
/// consumes the selected quality directly. Exact oversized software H.264
/// maps that same value to its supported soft average-rate control; neither
/// path installs a hard data-rate limit.
struct NativeVideoEncodingPolicy: Equatable, Sendable {
    enum RateControl: Equatable, Sendable {
        case quality(Double)
        case averageBitRate(Int)
    }

    let quality: Double
    let isRealTime: Bool
    let prioritizesEncodingSpeedOverQuality: Bool
    let allowsFrameReordering: Bool
    let rateControl: RateControl

    init(configuration: MediaExportConfiguration) {
        quality = configuration.videoQuality
        isRealTime = false
        prioritizesEncodingSpeedOverQuality = false
        allowsFrameReordering = true
        if NativeH264HardwareGeometry.supports(
            width: configuration.width,
            height: configuration.height
        ) {
            rateControl = .quality(configuration.videoQuality)
        } else {
            rateControl = .averageBitRate(
                Self.softwareAverageBitRate(configuration: configuration)
            )
        }
    }

    /// Maps Clip's 1...100 quality ladder to the only supported native control
    /// on Apple's oversized software H.264 encoder. The curve gives the upper
    /// rungs progressively more bits for fine screen text while remaining a
    /// soft average target; VideoToolbox is free to vary the actual file size.
    private static func softwareAverageBitRate(
        configuration: MediaExportConfiguration
    ) -> Int {
        let pixelRate = Double(configuration.width)
            * Double(configuration.height)
            * Double(configuration.framesPerSecond)
        let qualityCurve = 0.0005 + (0.3195 * pow(configuration.videoQuality, 4))
        let target = pixelRate * qualityCurve
        return Int(min(target.rounded(), Double(Int.max)))
    }
}

/// Apple's hardware H.264 path on the supported Apple-Silicon baseline accepts
/// up to a 4,096-pixel coded side and the 4,096x2,304 luma-sample envelope.
/// Larger exact geometries use the native software H.264 export fallback.
enum NativeH264HardwareGeometry {
    static let maximumCodedDimension = 4_096
    static let maximumLumaSamples = 4_096 * 2_304

    static func supports(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        return max(width, height) <= maximumCodedDimension
            && width <= maximumLumaSamples / height
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
