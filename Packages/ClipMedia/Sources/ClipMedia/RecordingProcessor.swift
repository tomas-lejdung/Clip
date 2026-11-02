@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation

public struct RecordingProcessingConfiguration: Equatable, Sendable {
    public let scalePercent: Int
    public let crf: Int
    public init(scalePercent: Int = 100, crf: Int = 24) {
        self.scalePercent = scalePercent
        self.crf = crf
    }

    public func dimensions(width: Int, height: Int) throws -> (width: Int, height: Int) {
        guard [100, 75, 50, 25].contains(scalePercent), (1...51).contains(crf),
              width >= 2, height >= 2 else { throw RecordingProcessingError.invalidConfiguration }
        let result = (Int(Double(width) * Double(scalePercent) / 100) / 2 * 2,
                      Int(Double(height) * Double(scalePercent) / 100) / 2 * 2)
        guard result.0 >= 2, result.1 >= 2 else { throw RecordingProcessingError.invalidConfiguration }
        return result
    }
}

public struct RecordingProcessingProgress: Sendable {
    public enum Phase: Sendable { case preparing, encoding, validating }
    public let phase: Phase
    public let fraction: Double?
    public init(phase: Phase, fraction: Double?) { self.phase = phase; self.fraction = fraction }
}

public struct ProcessedRecording: Sendable {
    public let inspection: MediaInspection
    public let processingSeconds: TimeInterval
    public let encodingSeconds: TimeInterval
    public let configuration: RecordingProcessingConfiguration
}

public enum RecordingProcessingError: LocalizedError, Sendable {
    case invalidConfiguration
    case encoderUnavailable
    case unsupportedSource(String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Choose a supported resolution and a CRF from 1 to 51."
        case .encoderUnavailable: "Clip's recording encoder is missing. Reinstall the complete application."
        case let .unsupportedSource(message), let .failed(message): message
        }
    }
}

/// Full-duration HEVC → x264 processing. The supplied original is read-only;
/// only a validated sibling staging file may replace the candidate destination.
public struct RecordingProcessor: Sendable {
    public let executableURL: URL
    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/ffmpeg")
    }

    public func process(sourceURL: URL, destinationURL: URL,
                        configuration: RecordingProcessingConfiguration = .init(),
                        progress: @escaping @Sendable (RecordingProcessingProgress) -> Void = { _ in }) async throws -> ProcessedRecording {
        let began = ProcessInfo.processInfo.systemUptime
        try Task.checkCancellation()
        guard sourceURL.resolvingSymlinksInPath().standardizedFileURL !=
                destinationURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw RecordingProcessingError.failed("The processed file must be separate from its original.")
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw RecordingProcessingError.encoderUnavailable
        }
        progress(.init(phase: .preparing, fraction: nil))
        let facts = try await ProcessingSourceFacts.read(sourceURL)
        let dimensions = try configuration.dimensions(width: facts.inspection.width, height: facts.inspection.height)
        let temporary = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).processing.mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let args = Self.arguments(source: sourceURL, destination: temporary, configuration: configuration,
                                  width: dimensions.width, height: dimensions.height, facts: facts)
        let encoder = EncoderProcess()
        let encodingBegan = ProcessInfo.processInfo.systemUptime
        progress(.init(phase: .encoding, fraction: 0))
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try encoder.run(executable: executableURL, arguments: args) { seconds in
                    progress(.init(phase: .encoding, fraction: min(0.99, max(0, seconds / facts.inspection.duration))))
                }
            }.value
            try Task.checkCancellation()
        } onCancel: { encoder.cancel() }
        let encodingSeconds = ProcessInfo.processInfo.systemUptime - encodingBegan
        progress(.init(phase: .validating, fraction: nil))
        let output = try await ProcessingSourceFacts.read(temporary)
        guard output.inspection.videoCodec == kCMVideoCodecType_H264,
              output.inspection.width == dimensions.width, output.inspection.height == dimensions.height,
              output.inspection.audioTrackCount == min(1, facts.inspection.audioTrackCount),
              output.sampleCount == facts.sampleCount,
              abs(output.inspection.duration - facts.inspection.duration) <= 0.002,
              abs(output.lastPresentation - facts.lastPresentation) <= 0.000_020,
              abs(output.lastDuration - facts.lastDuration) <= 0.000_020,
              output.transfer == facts.transfer else {
            throw RecordingProcessingError.failed("The processed video did not preserve the recording's format or timing. The original was retained.")
        }
        // Native decoding, rather than ffmpeg alone, establishes that the file
        // can be previewed by AVPlayer. Full decode comparison lives in tests.
        _ = try await MediaFrameVerifier.pixels(asset: AVURLAsset(url: temporary), at: .zero)
        _ = try await MediaFrameVerifier.pixels(asset: AVURLAsset(url: temporary),
                    at: CMTime(seconds: output.lastPresentation, preferredTimescale: 1_000_000_000))
        try Task.checkCancellation()
        try MediaFilePublisher.publish(temporary, replacing: destinationURL)
        return ProcessedRecording(inspection: output.inspection,
            processingSeconds: ProcessInfo.processInfo.systemUptime - began,
            encodingSeconds: encodingSeconds, configuration: configuration)
    }

    private static func arguments(source: URL, destination: URL,
                                  configuration: RecordingProcessingConfiguration,
                                  width: Int, height: Int, facts: ProcessingSourceFacts) -> [String] {
        var filters = ["setpts=PTS-STARTPTS", "hwdownload", "format=nv12"]
        if width != facts.inspection.width || height != facts.inspection.height {
            filters.append("scale=w=\(width):h=\(height):in_color_matrix=bt709:out_color_matrix=bt709:in_range=tv:out_range=tv:flags=lanczos+accurate_rnd+full_chroma_int")
        }
        filters += ["format=yuv420p", "setsar=1"]
        var args = ["-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-filter_threads", "1",
                    "-stats_period", "0.2", "-progress", "pipe:1", "-threads", "4", "-copyts",
                    "-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld",
                    "-i", source.path, "-map", "0:v:0"]
        if facts.inspection.audioTrackCount > 1 {
            // amix consumes secondary inputs from FIFOs rather than aligning
            // their timestamps. Materialize late starts and dropped-buffer
            // gaps as silence on the shared zero-origin recording timeline.
            let aligned = (0..<facts.inspection.audioTrackCount).map {
                "[0:a:\($0)]aresample=async=1:first_pts=0:min_hard_comp=0.001[aligned\($0)]"
            }
            let inputs = (0..<facts.inspection.audioTrackCount).map { "[aligned\($0)]" }.joined()
            let graph = (aligned + ["\(inputs)amix=inputs=\(facts.inspection.audioTrackCount):normalize=0[audio]"]).joined(separator: ";")
            args += ["-filter_complex", graph,
                     "-map", "[audio]", "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2"]
        }
        else if facts.inspection.audioTrackCount > 0 { args += ["-map", "0:a", "-c:a", "copy"] }
        else { args += ["-an"] }
        args += ["-sn", "-dn", "-vf", filters.joined(separator: ","), "-c:v", "libx264",
                 "-preset", "veryfast", "-crf", String(configuration.crf), "-threads", "4",
                 "-bf", "0", "-refs", "1", "-profile:v", "high", "-pix_fmt", "yuv420p",
                 "-fps_mode", "passthrough", "-enc_time_base:v", "demux",
                 "-bsf:v", "setts=duration=if(eq(N\\,\(facts.sampleCount - 1))\\,\(facts.finalSampleTicks)\\,DURATION)",
                 // MP4 sample deltas are UInt32. A nanosecond timescale
                 // overflows on a static hold longer than 4.29 seconds.
                 "-video_track_timescale", "60000", "-avoid_negative_ts", "disabled",
                 "-color_primaries", "bt709", "-color_trc", facts.transfer,
                 "-colorspace", "bt709", "-color_range", "tv", "-movflags", "+faststart",
                 "-f", "mp4", destination.path]
        return args
    }
}

private struct ProcessingSourceFacts: Sendable {
    let inspection: MediaInspection
    let transfer: String
    let sampleCount: Int
    let lastPresentation: Double
    let lastDuration: Double
    let finalSampleTicks: Int64

    static func read(_ url: URL) async throws -> Self {
        let inspection = try await MediaInspector.inspect(url)
        guard inspection.fileSize > 0, inspection.videoTrackCount == 1,
              inspection.duration.isFinite, inspection.duration > 0,
              [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264].contains(inspection.videoCodec ?? 0) else {
            throw RecordingProcessingError.unsupportedSource("The original is not a readable H.264 or HEVC recording.")
        }
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let transform = try await track.load(.preferredTransform)
        let range = try await track.load(.timeRange)
        let timeScale = try await track.load(.naturalTimeScale)
        guard transform.isIdentity, abs(range.start.seconds) < 0.000_001 else {
            throw RecordingProcessingError.unsupportedSource("The original must use upright pixels and a zero-origin video timeline.")
        }
        guard let description = try await track.load(.formatDescriptions).first else {
            throw RecordingProcessingError.unsupportedSource("The original has no video format description.")
        }
        guard let extensionValues = CMFormatDescriptionGetExtensions(description) else {
            throw RecordingProcessingError.unsupportedSource("The original has no color information.")
        }
        let extensions = extensionValues as NSDictionary
        guard extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
              extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String else {
            throw RecordingProcessingError.unsupportedSource("The original does not use the supported SDR color format.")
        }
        let nativeTransfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        let transfer: String
        if nativeTransfer == kCMFormatDescriptionTransferFunction_sRGB as String { transfer = "iec61966-2-1" }
        else if nativeTransfer == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String { transfer = "bt709" }
        else { throw RecordingProcessingError.unsupportedSource("The original uses an unsupported color transfer function.") }
        for audio in try await asset.loadTracks(withMediaType: .audio) {
            guard try await audio.load(.formatDescriptions).allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }) else {
                throw RecordingProcessingError.unsupportedSource("The original's audio cannot be preserved without recompression.")
            }
        }
        // Read compressed sample metadata only, with bounded memory. No decoded
        // frames or per-frame arrays are retained for long recordings.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingProcessingError.failed("The original's timing could not be read.") }
        reader.add(output)
        guard reader.startReading() else { throw RecordingProcessingError.failed("The original's timing could not be read.") }
        var count = 0
        var lastPTS = CMTime.invalid
        var lastDuration = CMTime.invalid
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            // AVAssetReader may emit zero-sample edit-boundary markers. They
            // describe the container timeline, not encoded video pictures.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isNumeric, !lastPTS.isValid || pts > lastPTS else {
                reader.cancelReading()
                throw RecordingProcessingError.unsupportedSource("The original contains unordered video timestamps.")
            }
            lastPTS = pts
            lastDuration = CMSampleBufferGetDuration(sample)
            count += 1
        }
        guard reader.status == .completed, count > 0, lastDuration.isNumeric, lastDuration > .zero else {
            throw RecordingProcessingError.failed("The original's complete timing could not be read.")
        }
        return Self(inspection: inspection, transfer: transfer, sampleCount: count,
            lastPresentation: lastPTS.seconds, lastDuration: lastDuration.seconds,
            finalSampleTicks: CMTimeConvertScale(lastDuration, timescale: timeScale, method: .roundHalfAwayFromZero).value)
    }
}

/// Process cancellation is synchronized with launch. The pipe reader drains
/// stdout continuously, stderr is a bounded diagnostic tail, and cancellation
/// joins the child before callers can delete its output.
private final class EncoderProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        let active: Process? = lock.withLock { cancelled = true; return process }
        if let active, active.isRunning {
            active.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if active.isRunning { Darwin.kill(active.processIdentifier, SIGKILL) }
            }
        }
    }

    func run(executable: URL, arguments: [String], progress: @escaping @Sendable (Double) -> Void) throws {
        let child = Process()
        let pipe = Pipe()
        let errors = Pipe()
        let diagnostics = EncoderDiagnostics()
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in diagnostics.append(handle.availableData) }
        defer { errors.fileHandleForReading.readabilityHandler = nil }
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            process = child
            try child.run()
        }
        var buffer = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                if line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)) {
                    progress(micros / 1_000_000)
                }
            }
        }
        child.waitUntilExit()
        let wasCancelled = lock.withLock { process = nil; return cancelled }
        if wasCancelled { throw CancellationError() }
        guard child.terminationStatus == 0 else {
            throw RecordingProcessingError.failed("Video processing failed. \(diagnostics.message)")
        }
    }
}

private final class EncoderDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Data()
    func append(_ data: Data) { lock.withLock { tail.append(data); if tail.count > 4096 { tail = tail.suffix(4096) } } }
    var message: String { lock.withLock { String(decoding: tail, as: UTF8.self) } }
}
