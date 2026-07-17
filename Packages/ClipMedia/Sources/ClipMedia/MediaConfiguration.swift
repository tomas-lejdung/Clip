import CoreGraphics
import CoreMedia
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

public struct RecordingConfiguration: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    /// The high-fidelity master rate used while recording. Export presets can
    /// reduce this later, but they cannot recover interface detail discarded by
    /// an undersized capture encode.
    public var videoBitRate: Int
    public var showsCursor: Bool
    public var audioMode: AudioCaptureMode

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int = 30,
        showsCursor: Bool = true,
        audioMode: AudioCaptureMode = .off
    ) {
        precondition(width > 0 && height > 0)
        precondition(framesPerSecond == 30 || framesPerSecond == 60)
        self.width = width.roundedDownToEven
        self.height = height.roundedDownToEven
        self.framesPerSecond = framesPerSecond
        self.videoBitRate = Self.masterVideoBitRate(
            width: self.width,
            height: self.height,
            framesPerSecond: framesPerSecond
        )
        self.showsCursor = showsCursor
        self.audioMode = audioMode
    }

    /// Masters use 0.22 bits per pixel per frame with an 8 Mbps floor. There
    /// is deliberately no app-level upper rate or resolution envelope: the
    /// rate continues to follow the actual capture pixel count and cadence so
    /// a later Crisp export has source detail to preserve.
    private static func masterVideoBitRate(
        width: Int,
        height: Int,
        framesPerSecond: Int
    ) -> Int {
        let calculated = Int(
            (Double(width) * Double(height) * Double(framesPerSecond) * 0.22).rounded()
        )
        return max(calculated, 8_000_000)
    }
}

public struct MediaExportConfiguration: Equatable, Sendable {
    public var preset: MediaExportPreset
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var videoBitRate: Int
    public var audioBitRate: Int
    public var includesAudio: Bool
    public var approximateTargetBytes: Int64?

    public init(
        preset: MediaExportPreset,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        videoBitRate: Int,
        audioBitRate: Int = 128_000,
        includesAudio: Bool = true,
        approximateTargetBytes: Int64? = nil
    ) {
        self.preset = preset
        self.width = width.roundedDownToEven
        self.height = height.roundedDownToEven
        self.framesPerSecond = framesPerSecond
        self.videoBitRate = videoBitRate
        self.audioBitRate = audioBitRate
        self.includesAudio = includesAudio
        self.approximateTargetBytes = approximateTargetBytes
    }
}

public enum MediaExportConfigurationFactory {
    public static func make(
        preset: MediaExportPreset,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFramesPerSecond: Int,
        duration: TimeInterval,
        approximateTargetMegabytes: Double? = nil,
        includesAudio: Bool = true
    ) -> MediaExportConfiguration {
        switch preset {
        case .compact:
            let dimensions = fit(
                width: sourceWidth,
                height: sourceHeight,
                insideWidth: 1_920,
                insideHeight: 1_080
            )
            let fps = min(max(sourceFramesPerSecond, 1), 30)
            let bitRate = boundedBitRate(
                width: dimensions.width,
                height: dimensions.height,
                fps: fps,
                bitsPerPixel: 0.055,
                minimum: 1_500_000,
                maximum: 6_000_000
            )
            return MediaExportConfiguration(
                preset: preset,
                width: dimensions.width,
                height: dimensions.height,
                framesPerSecond: fps,
                videoBitRate: bitRate,
                includesAudio: includesAudio
            )

        case .crisp:
            precondition(sourceWidth > 0 && sourceHeight > 0)
            let fps = min(max(sourceFramesPerSecond, 1), 60)
            // RecordingConfiguration already makes the managed master
            // H.264-safe (even-sized). Passing its inspected dimensions
            // through here preserves arbitrary landscape, portrait, square,
            // and ultrawide capture geometry without a 4K landscape clamp.
            let bitRate = unboundedBitRate(
                width: sourceWidth,
                height: sourceHeight,
                fps: fps,
                bitsPerPixel: 0.20,
                minimum: 8_000_000
            )
            return MediaExportConfiguration(
                preset: preset,
                width: sourceWidth,
                height: sourceHeight,
                framesPerSecond: fps,
                videoBitRate: bitRate,
                audioBitRate: 192_000,
                includesAudio: includesAudio
            )

        case .smallest:
            let dimensions = fit(
                width: sourceWidth,
                height: sourceHeight,
                insideWidth: 1_920,
                insideHeight: 1_080
            )
            let requestedMegabytes = min(max(approximateTargetMegabytes ?? 10, 1), 500)
            let targetBytes = Int64((requestedMegabytes * 1_000_000).rounded())
            let fps = min(max(sourceFramesPerSecond, 1), 24)
            let safeDuration = max(duration, 0.25)
            let totalBitsPerSecond = Int((Double(targetBytes) * 8 / safeDuration).rounded(.down))
            let audioBitRate = 96_000
            let effectiveAudioBitRate = includesAudio ? audioBitRate : 0
            let videoBitRate = min(
                max(totalBitsPerSecond - effectiveAudioBitRate, 350_000),
                6_000_000
            )
            return MediaExportConfiguration(
                preset: preset,
                width: dimensions.width,
                height: dimensions.height,
                framesPerSecond: fps,
                videoBitRate: videoBitRate,
                audioBitRate: audioBitRate,
                includesAudio: includesAudio,
                approximateTargetBytes: targetBytes
            )
        }
    }

    private static func boundedBitRate(
        width: Int,
        height: Int,
        fps: Int,
        bitsPerPixel: Double,
        minimum: Int,
        maximum: Int
    ) -> Int {
        let calculated = Int(
            (Double(width) * Double(height) * Double(fps) * bitsPerPixel).rounded()
        )
        return min(max(calculated, minimum), maximum)
    }

    private static func unboundedBitRate(
        width: Int,
        height: Int,
        fps: Int,
        bitsPerPixel: Double,
        minimum: Int
    ) -> Int {
        let calculated = Int(
            (Double(width) * Double(height) * Double(fps) * bitsPerPixel).rounded()
        )
        return max(calculated, minimum)
    }

    private static func fit(
        width: Int,
        height: Int,
        insideWidth maximumWidth: Int,
        insideHeight maximumHeight: Int
    ) -> (width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        let scale = min(
            1,
            min(Double(maximumWidth) / Double(width), Double(maximumHeight) / Double(height))
        )
        return (
            max(2, Int((Double(width) * scale).rounded(.down)).roundedDownToEven),
            max(2, Int((Double(height) * scale).rounded(.down)).roundedDownToEven)
        )
    }
}

private extension Int {
    var roundedDownToEven: Int {
        isMultiple(of: 2) ? self : self - 1
    }
}
