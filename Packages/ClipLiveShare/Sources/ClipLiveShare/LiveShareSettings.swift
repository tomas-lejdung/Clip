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

/// Selects how ScreenCaptureKit normalizes color before WebRTC encoding.
/// Every mode currently produces an 8-bit SDR stream; this does not select
/// chroma subsampling or codec bit depth.
public enum LiveShareColorMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    /// Rec.709 with conventional video-range YCbCr for maximum compatibility.
    case compatibleRec709

    /// Rec.709 with full-range YCbCr for screen content and UI contrast.
    case fullRangeRec709

    /// Preserve ScreenCaptureKit's display-native color conversion. Encoded
    /// color signalling is viewer-dependent, so this remains experimental.
    case nativeDisplay

    public var id: String { rawValue }
}

public enum LiveShareDegradationPreference: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case automatic
    case preserveResolution
    case balanced
    case preserveFrameRate
    case disabled

    public var id: String { rawValue }
}

/// Optional encoder overrides for one codec. `nil` means that WebRTC or the
/// capture runtime chooses the value automatically.
public struct LiveShareCodecAdvancedSettings: Codable, Equatable, Sendable {
    public static let h264MaximumQuantizerRange = 0 ... 51
    public static let minimumBitratePercentRange = 0 ... 100
    public static let temporalLayerCountRange = 1 ... 3
    public static let scaleResolutionDownByRange = 1.0 ... 4.0
    public static let h264QualityPercentRange = 1 ... 100
    public static let h264KeyFrameIntervalSecondsRange = 1 ... 10

    /// H.264-only VideoToolbox QP ceiling. The bundled VP8, VP9, and AV1
    /// encoders do not expose a configurable quantizer through WebRTC's public
    /// factory API.
    public var maximumQuantizer: Int?
    public var minimumBitratePercent: Int?
    public var degradationPreference: LiveShareDegradationPreference
    public var temporalLayerCount: Int?
    public var scaleResolutionDownBy: Double?
    public var h264QualityPercent: Int?
    public var h264KeyFrameIntervalSeconds: Int?

    public init(
        maximumQuantizer: Int? = nil,
        minimumBitratePercent: Int? = nil,
        degradationPreference: LiveShareDegradationPreference = .automatic,
        temporalLayerCount: Int? = nil,
        scaleResolutionDownBy: Double? = nil,
        h264QualityPercent: Int? = nil,
        h264KeyFrameIntervalSeconds: Int? = nil
    ) {
        self.maximumQuantizer = maximumQuantizer
        self.minimumBitratePercent = minimumBitratePercent
        self.degradationPreference = degradationPreference
        self.temporalLayerCount = temporalLayerCount
        self.scaleResolutionDownBy = scaleResolutionDownBy
        self.h264QualityPercent = h264QualityPercent
        self.h264KeyFrameIntervalSeconds = h264KeyFrameIntervalSeconds
    }

    public static let `default` = Self()

    /// Returns a copy constrained to values accepted by Clip's advanced UI
    /// and sender runtime. Codec-specific H.264 values are discarded for
    /// other codecs.
    public func normalized(for codec: LiveShareVideoCodec) -> Self {
        var value = self
        value.minimumBitratePercent = value.minimumBitratePercent.map {
            Self.clamp($0, to: Self.minimumBitratePercentRange)
        }
        value.temporalLayerCount = value.temporalLayerCount.map {
            Self.clamp($0, to: Self.temporalLayerCountRange)
        }
        value.scaleResolutionDownBy = value.scaleResolutionDownBy.map {
            guard !$0.isNaN else { return Self.scaleResolutionDownByRange.lowerBound }
            return Self.clamp($0, to: Self.scaleResolutionDownByRange)
        }

        if codec == .h264 {
            value.maximumQuantizer = value.maximumQuantizer.map {
                Self.clamp($0, to: Self.h264MaximumQuantizerRange)
            }
            value.h264QualityPercent = value.h264QualityPercent.map {
                Self.clamp($0, to: Self.h264QualityPercentRange)
            }
            value.h264KeyFrameIntervalSeconds = value.h264KeyFrameIntervalSeconds.map {
                Self.clamp($0, to: Self.h264KeyFrameIntervalSecondsRange)
            }
        } else {
            value.maximumQuantizer = nil
            value.h264QualityPercent = nil
            value.h264KeyFrameIntervalSeconds = nil
        }

        return value
    }

    public mutating func normalize(for codec: LiveShareVideoCodec) {
        self = normalized(for: codec)
    }

    private static func clamp<Value: Comparable>(_ value: Value, to range: ClosedRange<Value>) -> Value {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case maximumQuantizer
        case minimumBitratePercent
        case degradationPreference
        case temporalLayerCount
        case scaleResolutionDownBy
        case h264QualityPercent
        case h264KeyFrameIntervalSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maximumQuantizer = try container.decodeIfPresent(Int.self, forKey: .maximumQuantizer)
        minimumBitratePercent = try container.decodeIfPresent(Int.self, forKey: .minimumBitratePercent)
        degradationPreference = try container.decodeIfPresent(
            LiveShareDegradationPreference.self,
            forKey: .degradationPreference
        ) ?? .automatic
        temporalLayerCount = try container.decodeIfPresent(Int.self, forKey: .temporalLayerCount)
        scaleResolutionDownBy = try container.decodeIfPresent(Double.self, forKey: .scaleResolutionDownBy)
        h264QualityPercent = try container.decodeIfPresent(Int.self, forKey: .h264QualityPercent)
        h264KeyFrameIntervalSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .h264KeyFrameIntervalSeconds
        )
    }
}

/// Keeps overrides separate because supported parameters and valid ranges can
/// differ by codec.
public struct LiveShareAdvancedVideoSettings: Codable, Equatable, Sendable {
    public var h264: LiveShareCodecAdvancedSettings
    public var vp8: LiveShareCodecAdvancedSettings
    public var vp9: LiveShareCodecAdvancedSettings
    public var av1: LiveShareCodecAdvancedSettings

    public init(
        h264: LiveShareCodecAdvancedSettings = .default,
        vp8: LiveShareCodecAdvancedSettings = .default,
        vp9: LiveShareCodecAdvancedSettings = .default,
        av1: LiveShareCodecAdvancedSettings = .default
    ) {
        self.h264 = h264
        self.vp8 = vp8
        self.vp9 = vp9
        self.av1 = av1
    }

    public static let `default` = Self()

    public subscript(codec: LiveShareVideoCodec) -> LiveShareCodecAdvancedSettings {
        get {
            switch codec {
            case .h264: h264
            case .vp8: vp8
            case .vp9: vp9
            case .av1: av1
            }
        }
        set {
            switch codec {
            case .h264: h264 = newValue
            case .vp8: vp8 = newValue
            case .vp9: vp9 = newValue
            case .av1: av1 = newValue
            }
        }
    }

    public func settings(for codec: LiveShareVideoCodec) -> LiveShareCodecAdvancedSettings {
        self[codec]
    }

    public mutating func set(_ settings: LiveShareCodecAdvancedSettings, for codec: LiveShareVideoCodec) {
        self[codec] = settings
    }

    public func normalized() -> Self {
        var value = self
        for codec in LiveShareVideoCodec.allCases {
            value[codec] = value[codec].normalized(for: codec)
        }
        return value
    }

    public mutating func normalize() {
        self = normalized()
    }

    private enum CodingKeys: String, CodingKey {
        case h264
        case vp8
        case vp9
        case av1
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        h264 = try container.decodeIfPresent(LiveShareCodecAdvancedSettings.self, forKey: .h264) ?? .default
        vp8 = try container.decodeIfPresent(LiveShareCodecAdvancedSettings.self, forKey: .vp8) ?? .default
        vp9 = try container.decodeIfPresent(LiveShareCodecAdvancedSettings.self, forKey: .vp9) ?? .default
        av1 = try container.decodeIfPresent(LiveShareCodecAdvancedSettings.self, forKey: .av1) ?? .default
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
    public var colorMode: LiveShareColorMode
    public var systemAudioEnabled: Bool
    public var cursorUpdatesMatchFrameRate: Bool
    public var prioritizeFocusedWindow: Bool
    public var autoShareFocusedWindows: Bool
    public var accessCodeEnabled: Bool
    public var advancedVideoSettings: LiveShareAdvancedVideoSettings

    public init(
        quality: LiveShareQualityPreset = .veryHigh,
        frameRate: LiveShareFrameRate = .thirty,
        encodingMode: LiveShareEncodingMode = .quality,
        videoCodec: LiveShareVideoCodec = .vp8,
        colorMode: LiveShareColorMode = .compatibleRec709,
        systemAudioEnabled: Bool = false,
        cursorUpdatesMatchFrameRate: Bool = false,
        prioritizeFocusedWindow: Bool = true,
        autoShareFocusedWindows: Bool = false,
        accessCodeEnabled: Bool = false,
        advancedVideoSettings: LiveShareAdvancedVideoSettings = .default
    ) {
        self.quality = quality
        self.frameRate = frameRate
        self.encodingMode = encodingMode
        self.videoCodec = videoCodec
        self.colorMode = colorMode
        self.systemAudioEnabled = systemAudioEnabled
        self.cursorUpdatesMatchFrameRate = cursorUpdatesMatchFrameRate
        self.prioritizeFocusedWindow = prioritizeFocusedWindow
        self.autoShareFocusedWindows = autoShareFocusedWindows
        self.accessCodeEnabled = accessCodeEnabled
        self.advancedVideoSettings = advancedVideoSettings.normalized()
    }

    public static let `default` = Self()

    private enum CodingKeys: String, CodingKey {
        case quality
        case frameRate
        case encodingMode
        case videoCodec
        case colorMode
        case systemAudioEnabled
        case cursorUpdatesMatchFrameRate
        case prioritizeFocusedWindow
        case adaptiveBitrateEnabled
        case autoShareFocusedWindows
        case accessCodeEnabled
        case advancedVideoSettings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = try container.decodeIfPresent(LiveShareQualityPreset.self, forKey: .quality) ?? .veryHigh
        frameRate = try container.decodeIfPresent(LiveShareFrameRate.self, forKey: .frameRate) ?? .thirty
        encodingMode = try container.decodeIfPresent(LiveShareEncodingMode.self, forKey: .encodingMode) ?? .quality
        videoCodec = try container.decodeIfPresent(LiveShareVideoCodec.self, forKey: .videoCodec) ?? .vp8
        colorMode = try container.decodeIfPresent(LiveShareColorMode.self, forKey: .colorMode) ?? .compatibleRec709
        systemAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemAudioEnabled) ?? false
        cursorUpdatesMatchFrameRate = try container.decodeIfPresent(
            Bool.self,
            forKey: .cursorUpdatesMatchFrameRate
        ) ?? false
        prioritizeFocusedWindow = try container.decodeIfPresent(Bool.self, forKey: .prioritizeFocusedWindow)
            ?? container.decodeIfPresent(Bool.self, forKey: .adaptiveBitrateEnabled)
            ?? true
        autoShareFocusedWindows = try container.decodeIfPresent(Bool.self, forKey: .autoShareFocusedWindows) ?? false
        accessCodeEnabled = try container.decodeIfPresent(Bool.self, forKey: .accessCodeEnabled) ?? false
        advancedVideoSettings = try container.decodeIfPresent(
            LiveShareAdvancedVideoSettings.self,
            forKey: .advancedVideoSettings
        )?.normalized() ?? .default
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quality, forKey: .quality)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(encodingMode, forKey: .encodingMode)
        try container.encode(videoCodec, forKey: .videoCodec)
        try container.encode(colorMode, forKey: .colorMode)
        try container.encode(systemAudioEnabled, forKey: .systemAudioEnabled)
        try container.encode(cursorUpdatesMatchFrameRate, forKey: .cursorUpdatesMatchFrameRate)
        try container.encode(prioritizeFocusedWindow, forKey: .prioritizeFocusedWindow)
        try container.encode(autoShareFocusedWindows, forKey: .autoShareFocusedWindows)
        try container.encode(accessCodeEnabled, forKey: .accessCodeEnabled)
        try container.encode(advancedVideoSettings, forKey: .advancedVideoSettings)
    }
}
