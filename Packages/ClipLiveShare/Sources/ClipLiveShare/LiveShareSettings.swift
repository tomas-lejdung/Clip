import Foundation

public enum LiveShareQualityPreset: Int, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case low = 0
    case medium
    case high
    case veryHigh
    case ultra
    case extreme
    case max
    case insane

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .veryHigh: "Very High"
        case .ultra: "Ultra"
        case .extreme: "Extreme"
        case .max: "Max"
        case .insane: "Insane"
        }
    }

    public var maximumBitrateBitsPerSecond: Int {
        switch self {
        case .low: 500_000
        case .medium: 1_500_000
        case .high: 3_000_000
        case .veryHigh: 6_000_000
        case .ultra: 10_000_000
        case .extreme: 15_000_000
        case .max: 20_000_000
        case .insane: 50_000_000
        }
    }
}

public enum LiveShareFrameRate: Int, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case fifteen = 15
    case thirty = 30
    case sixty = 60

    public var id: Int { rawValue }
}

public enum LiveShareEncodingMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case performance
    case quality

    public var id: String { rawValue }
}

public enum LiveShareVideoCodec: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case h264
    case vp8
    case vp9
    case av1

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .vp8: "VP8"
        case .vp9: "VP9"
        case .av1: "AV1"
        }
    }
}

/// Independent from recording/export quality. The selected preset is one
/// viewer's video-bandwidth budget; transport congestion control can still
/// reduce the effective rate to protect latency.
public struct LiveShareSettings: Codable, Equatable, Sendable {
    public var quality: LiveShareQualityPreset
    public var frameRate: LiveShareFrameRate
    public var encodingMode: LiveShareEncodingMode
    public var videoCodec: LiveShareVideoCodec
    public var systemAudioEnabled: Bool
    public var prioritizeFocusedWindow: Bool
    public var autoShareFocusedWindows: Bool
    public var accessCodeEnabled: Bool

    public init(
        quality: LiveShareQualityPreset = .veryHigh,
        frameRate: LiveShareFrameRate = .thirty,
        encodingMode: LiveShareEncodingMode = .quality,
        videoCodec: LiveShareVideoCodec = .vp8,
        systemAudioEnabled: Bool = false,
        prioritizeFocusedWindow: Bool = true,
        autoShareFocusedWindows: Bool = false,
        accessCodeEnabled: Bool = false
    ) {
        self.quality = quality
        self.frameRate = frameRate
        self.encodingMode = encodingMode
        self.videoCodec = videoCodec
        self.systemAudioEnabled = systemAudioEnabled
        self.prioritizeFocusedWindow = prioritizeFocusedWindow
        self.autoShareFocusedWindows = autoShareFocusedWindows
        self.accessCodeEnabled = accessCodeEnabled
    }

    public static let `default` = Self()

    private enum CodingKeys: String, CodingKey {
        case quality
        case frameRate
        case encodingMode
        case videoCodec
        case systemAudioEnabled
        case prioritizeFocusedWindow
        case adaptiveBitrateEnabled
        case autoShareFocusedWindows
        case accessCodeEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = try container.decodeIfPresent(LiveShareQualityPreset.self, forKey: .quality) ?? .veryHigh
        frameRate = try container.decodeIfPresent(LiveShareFrameRate.self, forKey: .frameRate) ?? .thirty
        encodingMode = try container.decodeIfPresent(LiveShareEncodingMode.self, forKey: .encodingMode) ?? .quality
        videoCodec = try container.decodeIfPresent(LiveShareVideoCodec.self, forKey: .videoCodec) ?? .vp8
        systemAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled) ?? false
        prioritizeFocusedWindow = try container.decodeIfPresent(Bool.self, forKey: .prioritizeFocusedWindow)
            ?? container.decodeIfPresent(Bool.self, forKey: .adaptiveBitrateEnabled)
            ?? true
        autoShareFocusedWindows = try container.decodeIfPresent(Bool.self, forKey: .autoShareFocusedWindows) ?? false
        accessCodeEnabled = try container.decodeIfPresent(Bool.self, forKey: .accessCodeEnabled) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quality, forKey: .quality)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(encodingMode, forKey: .encodingMode)
        try container.encode(videoCodec, forKey: .videoCodec)
        try container.encode(systemAudioEnabled, forKey: .systemAudioEnabled)
        try container.encode(prioritizeFocusedWindow, forKey: .prioritizeFocusedWindow)
        try container.encode(autoShareFocusedWindows, forKey: .autoShareFocusedWindows)
        try container.encode(accessCodeEnabled, forKey: .accessCodeEnabled)
    }
}
