import Foundation

public enum AudioCaptureMode: String, Codable, CaseIterable, Sendable {
    case off
    case microphone
    case system
    case microphoneAndSystem

    public var capturesMicrophone: Bool {
        self == .microphone || self == .microphoneAndSystem
    }

    public var capturesSystemAudio: Bool {
        self == .system || self == .microphoneAndSystem
    }
}

public enum MediaExportPreset: String, Codable, CaseIterable, Sendable {
    case compact
    case crisp
    case smallest
}

public enum MediaVideoQuality {
    /// Converts the user-facing 1...100 scale into VideoToolbox's normalized
    /// 0...1 quality value. Callers own the selected value; ClipMedia does not
    /// alter or reorder quality presets.
    public static func normalized(percent: Int) -> Double {
        precondition((1...100).contains(percent))
        return Double(percent) / 100
    }

    public static func percent(normalized: Double) -> Int {
        precondition(normalized.isFinite && (0...1).contains(normalized))
        return Int((normalized * 100).rounded())
    }
}

public struct RecordingConfiguration: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    /// VideoToolbox's normalized quality control. No average or hard data-rate
    /// limit is paired with it; the encoder chooses the resulting byte rate.
    public var videoQuality: Double
    public var showsCursor: Bool
    public var audioMode: AudioCaptureMode

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int = 30,
        videoQuality: Double = 0.98,
        showsCursor: Bool = true,
        audioMode: AudioCaptureMode = .off
    ) {
        precondition(width > 0 && height > 0)
        precondition(framesPerSecond == 30 || framesPerSecond == 60)
        precondition(videoQuality.isFinite && (0...1).contains(videoQuality))
        self.width = width.roundedDownToEven
        self.height = height.roundedDownToEven
        self.framesPerSecond = framesPerSecond
        self.videoQuality = videoQuality
        self.showsCursor = showsCursor
        self.audioMode = audioMode
    }

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int = 30,
        videoQualityPercent: Int,
        showsCursor: Bool = true,
        audioMode: AudioCaptureMode = .off
    ) {
        self.init(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            videoQuality: MediaVideoQuality.normalized(percent: videoQualityPercent),
            showsCursor: showsCursor,
            audioMode: audioMode
        )
    }
}

public struct MediaExportConfiguration: Equatable, Sendable {
    public var preset: MediaExportPreset
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    /// VideoToolbox's normalized quality control. It is the only video-size
    /// policy applied by an export preset.
    public var videoQuality: Double
    /// The quality used to create the managed source, when known. Crisp can
    /// reuse source bytes only when this matches `videoQuality`.
    public var sourceVideoQuality: Double?
    public var audioBitRate: Int
    public var includesAudio: Bool

    public init(
        preset: MediaExportPreset,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        videoQuality: Double,
        sourceVideoQuality: Double? = nil,
        audioBitRate: Int = 128_000,
        includesAudio: Bool = true
    ) {
        self.preset = preset
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.videoQuality = videoQuality
        self.sourceVideoQuality = sourceVideoQuality
        self.audioBitRate = audioBitRate
        self.includesAudio = includesAudio
    }

    public init(
        preset: MediaExportPreset,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        videoQualityPercent: Int,
        sourceVideoQualityPercent: Int? = nil,
        audioBitRate: Int = 128_000,
        includesAudio: Bool = true
    ) {
        self.init(
            preset: preset,
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            videoQuality: MediaVideoQuality.normalized(percent: videoQualityPercent),
            sourceVideoQuality: sourceVideoQualityPercent.map(MediaVideoQuality.normalized),
            audioBitRate: audioBitRate,
            includesAudio: includesAudio
        )
    }
}

public enum MediaExportConfigurationFactory {
    /// Creates a quality-only export configuration. Every preset preserves the
    /// source's exact encoded geometry and durable capture cadence. The caller
    /// supplies the quality rung instead of the preset silently imposing a
    /// resolution, frame-rate, bitrate, or target-size policy.
    public static func make(
        preset: MediaExportPreset,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFramesPerSecond: Int,
        videoQuality: Double,
        sourceVideoQuality: Double? = nil,
        includesAudio: Bool = true
    ) -> MediaExportConfiguration {
        precondition(sourceWidth > 0 && sourceHeight > 0)
        precondition(sourceFramesPerSecond > 0)
        precondition(videoQuality.isFinite && (0...1).contains(videoQuality))
        precondition(
            sourceVideoQuality.map { $0.isFinite && (0...1).contains($0) } ?? true
        )

        return MediaExportConfiguration(
            preset: preset,
            width: sourceWidth,
            height: sourceHeight,
            framesPerSecond: sourceFramesPerSecond,
            videoQuality: videoQuality,
            sourceVideoQuality: sourceVideoQuality,
            audioBitRate: 128_000,
            includesAudio: includesAudio
        )
    }

    public static func make(
        preset: MediaExportPreset,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFramesPerSecond: Int,
        videoQualityPercent: Int,
        sourceVideoQualityPercent: Int? = nil,
        includesAudio: Bool = true
    ) -> MediaExportConfiguration {
        make(
            preset: preset,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceFramesPerSecond: sourceFramesPerSecond,
            videoQuality: MediaVideoQuality.normalized(percent: videoQualityPercent),
            sourceVideoQuality: sourceVideoQualityPercent.map(MediaVideoQuality.normalized),
            includesAudio: includesAudio
        )
    }
}

private extension Int {
    var roundedDownToEven: Int {
        isMultiple(of: 2) ? self : self - 1
    }
}
