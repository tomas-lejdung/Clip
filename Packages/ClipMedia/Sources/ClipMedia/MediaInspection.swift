@preconcurrency import AVFoundation
import CoreMedia
import Foundation

public struct MediaInspection: Equatable, Sendable {
    public let duration: TimeInterval
    public let fileSize: Int64
    public let videoTrackCount: Int
    public let audioTrackCount: Int
    public let width: Int
    public let height: Int
    public let nominalFramesPerSecond: Double
    public let videoCodec: FourCharCode?

    public init(
        duration: TimeInterval,
        fileSize: Int64,
        videoTrackCount: Int,
        audioTrackCount: Int,
        width: Int,
        height: Int,
        nominalFramesPerSecond: Double,
        videoCodec: FourCharCode?
    ) {
        self.duration = duration
        self.fileSize = fileSize
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
        self.width = width
        self.height = height
        self.nominalFramesPerSecond = nominalFramesPerSecond
        self.videoCodec = videoCodec
    }
}

public enum MediaInspector {
    public static func inspect(_ url: URL) async throws -> MediaInspection {
        let asset = AVURLAsset(url: url)
        async let durationValue = asset.load(.duration)
        async let videoTracksValue = asset.loadTracks(withMediaType: .video)
        async let audioTracksValue = asset.loadTracks(withMediaType: .audio)

        let (duration, videoTracks, audioTracks) = try await (
            durationValue,
            videoTracksValue,
            audioTracksValue
        )

        let fileSize = Int64(
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )

        guard let videoTrack = videoTracks.first else {
            return MediaInspection(
                duration: duration.seconds,
                fileSize: fileSize,
                videoTrackCount: 0,
                audioTrackCount: audioTracks.count,
                width: 0,
                height: 0,
                nominalFramesPerSecond: 0,
                videoCodec: nil
            )
        }

        async let naturalSizeValue = videoTrack.load(.naturalSize)
        async let transformValue = videoTrack.load(.preferredTransform)
        async let frameRateValue = videoTrack.load(.nominalFrameRate)
        async let formatDescriptionsValue = videoTrack.load(.formatDescriptions)

        let (naturalSize, transform, nominalFrameRate, formatDescriptions) = try await (
            naturalSizeValue,
            transformValue,
            frameRateValue,
            formatDescriptionsValue
        )
        let displayedSize = naturalSize.applying(transform)
        let codec = formatDescriptions.first.map(CMFormatDescriptionGetMediaSubType)

        return MediaInspection(
            duration: duration.seconds,
            fileSize: fileSize,
            videoTrackCount: videoTracks.count,
            audioTrackCount: audioTracks.count,
            width: Int(abs(displayedSize.width).rounded()),
            height: Int(abs(displayedSize.height).rounded()),
            nominalFramesPerSecond: Double(nominalFrameRate),
            videoCodec: codec
        )
    }
}
