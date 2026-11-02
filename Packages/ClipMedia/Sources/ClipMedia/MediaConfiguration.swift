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

public struct RecordingConfiguration: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    /// Average HEVC recording bitrate in bits per second. This applies only
    /// when starting a recording; processing quality is a separate x264 CRF.
    public var targetAverageBitRate: Int
    public var showsCursor: Bool
    public var showsClickHighlights: Bool
    public var audioMode: AudioCaptureMode

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int = 30,
        targetAverageBitRate: Int = 10_000_000,
        showsCursor: Bool = true,
        showsClickHighlights: Bool = false,
        audioMode: AudioCaptureMode = .off
    ) {
        precondition(width >= 2 && height >= 2)
        precondition(framesPerSecond == 30 || framesPerSecond == 60)
        precondition((1_000_000...100_000_000).contains(targetAverageBitRate))
        self.width = width.roundedDownToEven
        self.height = height.roundedDownToEven
        self.framesPerSecond = framesPerSecond
        self.targetAverageBitRate = targetAverageBitRate
        self.showsCursor = showsCursor
        self.showsClickHighlights = showsClickHighlights
        self.audioMode = audioMode
    }
}

/// Export edits the stored video without changing its encoded quality or size.
public struct MediaExportConfiguration: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var includesAudio: Bool

    public init(width: Int, height: Int, framesPerSecond: Int, includesAudio: Bool = true) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.includesAudio = includesAudio
    }
}

private extension Int {
    var roundedDownToEven: Int {
        isMultiple(of: 2) ? self : self - 1
    }
}
