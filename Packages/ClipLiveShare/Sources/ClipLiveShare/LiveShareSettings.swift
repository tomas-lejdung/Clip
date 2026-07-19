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

/// Independent from recording/export quality. WebRTC congestion control owns
/// actual rate; this preset supplies a sender ceiling and degradation policy.
public struct LiveShareSettings: Codable, Equatable, Sendable {
    public var quality: LiveShareQualityPreset
    public var frameRate: LiveShareFrameRate
    public var encodingMode: LiveShareEncodingMode
    public var adaptiveBitrateEnabled: Bool
    public var autoShareFocusedWindows: Bool
    public var accessCodeEnabled: Bool

    public init(
        quality: LiveShareQualityPreset = .veryHigh,
        frameRate: LiveShareFrameRate = .thirty,
        encodingMode: LiveShareEncodingMode = .quality,
        adaptiveBitrateEnabled: Bool = true,
        autoShareFocusedWindows: Bool = false,
        accessCodeEnabled: Bool = false
    ) {
        self.quality = quality
        self.frameRate = frameRate
        self.encodingMode = encodingMode
        self.adaptiveBitrateEnabled = adaptiveBitrateEnabled
        self.autoShareFocusedWindows = autoShareFocusedWindows
        self.accessCodeEnabled = accessCodeEnabled
    }

    public static let `default` = Self()
}
