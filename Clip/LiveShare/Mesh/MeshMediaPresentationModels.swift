import ClipLiveShare
import Foundation

typealias LiveShareQualityPreset = ClipLiveShare.LiveShareQualityPreset
typealias LiveShareFrameRate = ClipLiveShare.LiveShareFrameRate
typealias LiveShareEncodingMode = ClipLiveShare.LiveShareEncodingMode
typealias LiveShareVideoCodec = ClipLiveShare.LiveShareVideoCodec
typealias LiveShareColorMode = ClipLiveShare.LiveShareColorMode
typealias LiveShareCodecAdvancedSettings = ClipLiveShare.LiveShareCodecAdvancedSettings
typealias LiveShareDegradationPreference = ClipLiveShare.LiveShareDegradationPreference

enum LiveShareSourceViewStatus: String, Equatable, Sendable {
    case starting
    case live
    case stopping
    case failed

    var title: String {
        switch self {
        case .starting:
            String(localized: "Starting")
        case .live:
            String(localized: "Live")
        case .stopping:
            String(localized: "Stopping")
        case .failed:
            String(localized: "Failed")
        }
    }
}

struct LiveShareAvailableWindowViewSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let applicationName: String
    let windowTitle: String
    let applicationPath: String?
}

/// One application that can be excluded from Fullscreen's system-audio mix.
/// Bundle identifiers are stable across process restarts, so `id` deliberately
/// matches `bundleIdentifier` and can also persist as the user's selection.
struct LiveShareAudioApplicationViewSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let applicationPath: String?

    init(
        id: String,
        name: String,
        bundleIdentifier: String,
        applicationPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
    }
}

struct LiveShareFullscreenViewSnapshot: Equatable, Sendable {
    let isOn: Bool
    let displayName: String
    let isEnabled: Bool
    let detail: String?

    init(
        isOn: Bool,
        displayName: String,
        isEnabled: Bool = true,
        detail: String? = nil
    ) {
        self.isOn = isOn
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.detail = detail
    }
}

extension LiveShareQualityPreset {
    var title: String {
        switch self {
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .veryHigh: String(localized: "Very High")
        case .ultra: String(localized: "Ultra")
        case .extreme: String(localized: "Extreme")
        case .max: String(localized: "Max")
        case .insane: String(localized: "Insane")
        }
    }

    var bitsPerSecond: Int { maximumBitrateBitsPerSecond }

    var bitrateText: String {
        if bitsPerSecond < 1_000_000 {
            return String(localized: "\(bitsPerSecond / 1_000) kbps")
        }
        let megabits = Double(bitsPerSecond) / 1_000_000
        if megabits.rounded() == megabits {
            return String(localized: "\(Int(megabits)) Mbps")
        }
        return String(localized: "\(megabits.formatted(.number.precision(.fractionLength(1)))) Mbps")
    }
}

extension LiveShareFrameRate {
    var title: String { String(localized: "\(rawValue) FPS") }
}

extension LiveShareEncodingMode {
    var title: String {
        switch self {
        case .performance: String(localized: "Performance")
        case .quality: String(localized: "Quality")
        }
    }
}

enum LiveShareCodecAcceleration: Equatable, Sendable {
    case unknown
    case hardware
    case software
}

struct LiveShareCodecViewSnapshot: Equatable, Sendable {
    let codec: LiveShareVideoCodec
    let acceleration: LiveShareCodecAcceleration

    init(
        codec: LiveShareVideoCodec = .av1,
        acceleration: LiveShareCodecAcceleration = .unknown
    ) {
        self.codec = codec
        self.acceleration = acceleration
    }

    var name: String { codec.displayName }

    var detail: String {
        switch acceleration {
        case .unknown:
            String(localized: "Encoder selected automatically")
        case .hardware:
            String(localized: "Hardware accelerated")
        case .software:
            String(localized: "Software encoding")
        }
    }
}

struct LiveShareSettingsViewSnapshot: Equatable, Sendable {
    let quality: LiveShareQualityPreset
    let frameRate: LiveShareFrameRate
    let codec: LiveShareCodecViewSnapshot
    let colorMode: LiveShareColorMode
    let systemAudioEnabled: Bool
    let audioExclusionApplications: [LiveShareAudioApplicationViewSnapshot]
    let excludedAudioApplicationIDs: Set<String>
    let cursorUpdatesMatchFrameRate: Bool
    let prioritizeFocusedWindow: Bool
    let mode: LiveShareEncodingMode
    let advancedVideoSettings: LiveShareAdvancedVideoSettings
    let autoShareFocusedWindows: Bool
    let canChangeQuality: Bool
    let canChangeFrameRate: Bool
    let availableFrameRates: Set<LiveShareFrameRate>
    let canChangeCodec: Bool
    let canChangeColorMode: Bool
    let canChangeSystemAudio: Bool
    let canChangeAudioExclusions: Bool
    let canChangeCursorUpdateRate: Bool
    let canChangePrioritizeFocusedWindow: Bool
    let canChangeMode: Bool
    let canChangeAutoShare: Bool

    init(
        quality: LiveShareQualityPreset = .max,
        frameRate: LiveShareFrameRate = .thirty,
        codec: LiveShareCodecViewSnapshot = .init(),
        colorMode: LiveShareColorMode = .nativeDisplay,
        systemAudioEnabled: Bool = false,
        audioExclusionApplications: [LiveShareAudioApplicationViewSnapshot] = [],
        excludedAudioApplicationIDs: Set<String> = [],
        cursorUpdatesMatchFrameRate: Bool = false,
        prioritizeFocusedWindow: Bool = true,
        mode: LiveShareEncodingMode = .quality,
        advancedVideoSettings: LiveShareAdvancedVideoSettings = .init(),
        autoShareFocusedWindows: Bool = false,
        canChangeQuality: Bool = true,
        canChangeFrameRate: Bool = true,
        availableFrameRates: Set<LiveShareFrameRate> = Set(LiveShareFrameRate.allCases),
        canChangeCodec: Bool = true,
        canChangeColorMode: Bool = true,
        canChangeSystemAudio: Bool = true,
        canChangeAudioExclusions: Bool = false,
        canChangeCursorUpdateRate: Bool = true,
        canChangePrioritizeFocusedWindow: Bool = true,
        canChangeMode: Bool = true,
        canChangeAutoShare: Bool = true
    ) {
        self.quality = quality
        self.frameRate = frameRate
        self.codec = codec
        self.colorMode = colorMode
        self.systemAudioEnabled = systemAudioEnabled
        self.audioExclusionApplications = audioExclusionApplications
        self.excludedAudioApplicationIDs = excludedAudioApplicationIDs
        self.cursorUpdatesMatchFrameRate = cursorUpdatesMatchFrameRate
        self.prioritizeFocusedWindow = prioritizeFocusedWindow
        self.mode = mode
        self.advancedVideoSettings = advancedVideoSettings
        self.autoShareFocusedWindows = autoShareFocusedWindows
        self.canChangeQuality = canChangeQuality
        self.canChangeFrameRate = canChangeFrameRate
        self.availableFrameRates = availableFrameRates
        self.canChangeCodec = canChangeCodec
        self.canChangeColorMode = canChangeColorMode
        self.canChangeSystemAudio = canChangeSystemAudio
        self.canChangeAudioExclusions = canChangeAudioExclusions
        self.canChangeCursorUpdateRate = canChangeCursorUpdateRate
        self.canChangePrioritizeFocusedWindow = canChangePrioritizeFocusedWindow
        self.canChangeMode = canChangeMode
        self.canChangeAutoShare = canChangeAutoShare
    }
}

extension LiveShareSettingsViewSnapshot {
    var audioExclusionSummary: String {
        guard !excludedAudioApplicationIDs.isEmpty else {
            return String(localized: "None")
        }

        if excludedAudioApplicationIDs.count == 1 {
            if let application = audioExclusionApplications.first(
                where: { excludedAudioApplicationIDs.contains($0.id) }
            ) {
                return application.name
            }
            return String(localized: "1 App")
        }

        return String(localized: "\(excludedAudioApplicationIDs.count) Apps")
    }
}

extension LiveShareColorMode {
    var title: String {
        switch self {
        case .compatibleRec709:
            String(localized: "Compatible Rec.709")
        case .fullRangeRec709:
            String(localized: "Full-range Rec.709")
        case .nativeDisplay:
            String(localized: "Native Display")
        }
    }

    func detail(for codec: LiveShareVideoCodec) -> String {
        switch self {
        case .compatibleRec709:
            String(localized: "SDR · 8-bit · video range")
        case .fullRangeRec709 where codec == .h264:
            String(localized: "SDR · H.264 uses its standard range")
        case .fullRangeRec709:
            String(localized: "SDR · 8-bit · full range")
        case .nativeDisplay where codec == .h264:
            String(localized: "Display input · H.264 outputs Rec.709")
        case .nativeDisplay:
            String(localized: "Source display color · 8-bit SDR")
        }
    }
}

enum LiveShareDurationFormatting {
    static func string(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
