@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Darwin
import Foundation

public enum NativeAssetExporterError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration
    case invalidTimeRange
    case missingVideoTrack
    case sourceAndDestinationMustDiffer
    case exportFailed(String)
    case publishFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The recording's format does not match the export."
        case .invalidTimeRange: "Choose a trim within the recording."
        case .missingVideoTrack: "The recording has no video."
        case .sourceAndDestinationMustDiffer: "The export must be separate from its Source."
        case let .exportFailed(message), let .publishFailed(message): message
        }
    }
}

public protocol MediaExporting: Sendable {
    func export(sourceURL: URL, destinationURL: URL, timeRange: CMTimeRange?,
                configuration: MediaExportConfiguration) async throws -> URL
}

/// Exports independently owned copies, or compressed trim/audio edits. This
/// service never changes quality, dimensions, cadence, or the full stored Source.
public struct NativeAssetExporter: MediaExporting {
    public init() {}

    public func export(sourceURL: URL, destinationURL: URL, timeRange: CMTimeRange?,
                       configuration: MediaExportConfiguration) async throws -> URL {
        guard sourceURL.resolvingSymlinksInPath().standardizedFileURL !=
                destinationURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw NativeAssetExporterError.sourceAndDestinationMustDiffer
        }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL)
        let original = try await MediaInspector.inspect(sourceURL)
        guard original.videoTrackCount == 1 else { throw NativeAssetExporterError.missingVideoTrack }
        guard original.width == configuration.width, original.height == configuration.height,
              configuration.framesPerSecond > 0,
              original.nominalFramesPerSecond <= Double(configuration.framesPerSecond) + 0.1 else {
            throw NativeAssetExporterError.invalidConfiguration
        }
        let sourceDuration = try await asset.load(.duration)
        var range = timeRange ?? CMTimeRange(start: .zero, duration: sourceDuration)
        guard range.start.isNumeric, range.duration.isNumeric, range.start >= .zero,
              range.duration > .zero, range.end.isNumeric, range.start < sourceDuration else {
            throw NativeAssetExporterError.invalidTimeRange
        }
        // Preview stores seconds; converting a legacy Source's timebase to the
        // 60,000-tick export clock may round its selected endpoint one tick up.
        // Clamp only that conversion error, never a genuinely out-of-range trim.
        if range.end > sourceDuration {
            guard range.end - sourceDuration <= CMTime(value: 1, timescale: 60_000) else {
                throw NativeAssetExporterError.invalidTimeRange
            }
            range.duration = sourceDuration - range.start
        }
        let temporary = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).export.mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fullRange = range.start == .zero && range.duration == sourceDuration
        if fullRange && (configuration.includesAudio || original.audioTrackCount == 0) {
            try FileManager.default.copyItem(at: sourceURL, to: temporary)
        } else {
            let composition = AVMutableComposition()
            var expectedAudioCount = 0
            for type in [AVMediaType.video, .audio] {
                if type == .audio && !configuration.includesAudio { continue }
                for track in try await asset.loadTracks(withMediaType: type) {
                    let intersection = CMTimeRangeGetIntersection(range, otherRange: try await track.load(.timeRange))
                    guard intersection.duration > .zero else { continue }
                    guard let output = composition.addMutableTrack(withMediaType: type,
                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw NativeAssetExporterError.exportFailed("The export track could not be created.")
                    }
                    try output.insertTimeRange(intersection, of: track, at: intersection.start - range.start)
                    if type == .video { output.preferredTransform = try await track.load(.preferredTransform) }
                    else { expectedAudioCount += 1 }
                }
            }
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw NativeAssetExporterError.exportFailed("This recording cannot be exported without recompression.")
            }
            exporter.timeRange = CMTimeRange(start: .zero, duration: range.duration)
            exporter.shouldOptimizeForNetworkUse = true
            try await exporter.export(to: temporary, as: .mp4)
            try Task.checkCancellation()
            let output = try await MediaInspector.inspect(temporary)
            guard output.width == original.width, output.height == original.height,
                  output.videoCodec == original.videoCodec, output.audioTrackCount == expectedAudioCount,
                  abs(output.duration - range.duration.seconds) <= 0.002 else {
                throw NativeAssetExporterError.exportFailed("The export could not preserve the selected trim. Your Source is unchanged.")
            }
            // A valid MP4 duration does not prove that its edit list hides the
            // preceding keyframe. Verify the first displayed frame natively.
            let before = try await MediaFrameVerifier.pixels(asset: asset, at: range.start)
            let after = try await MediaFrameVerifier.pixels(asset: AVURLAsset(url: temporary), at: .zero)
            guard before == after else {
                throw NativeAssetExporterError.exportFailed("The export could not preserve the selected first frame. Your Source is unchanged.")
            }
        }
        try Task.checkCancellation()
        try MediaFilePublisher.publish(temporary, replacing: destinationURL)
        return destinationURL
    }
}

enum MediaFrameVerifier {
    static func pixels(asset: AVAsset, at time: CMTime) async throws -> Data {
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: time).image
        guard image.width > 0, image.height > 0, image.width <= 70_000_000 / image.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw NativeAssetExporterError.exportFailed("The recording's verification frame is unsupported.")
        }
        var pixels = Data(count: image.width * image.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw NativeAssetExporterError.exportFailed("The verification frame could not be read.") }
        return pixels
    }
}

enum MediaFilePublisher {
    static func publish(_ sourceURL: URL, replacing destinationURL: URL) throws {
        var result: Int32 = -1
        var failure: Int32 = 0
        let represented = sourceURL.withUnsafeFileSystemRepresentation { source in
            destinationURL.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return false }
                result = Darwin.rename(source, destination)
                failure = errno
                return true
            }
        }
        guard represented, result == 0 else {
            throw NativeAssetExporterError.publishFailed(represented
                ? String(cString: strerror(failure)) : "The export path is invalid.")
        }
    }
}
