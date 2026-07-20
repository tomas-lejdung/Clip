import ClipLiveShare
import Foundation

typealias LiveShareQualityPreset = ClipLiveShare.LiveShareQualityPreset
typealias LiveShareFrameRate = ClipLiveShare.LiveShareFrameRate
typealias LiveShareEncodingMode = ClipLiveShare.LiveShareEncodingMode
typealias LiveShareVideoCodec = ClipLiveShare.LiveShareVideoCodec

enum LiveShareViewPhase: Equatable, Sendable {
    case inactive
    case reservingRoom
    case connecting
    case ready
    case starting
    case live(elapsedSeconds: TimeInterval)
    case reconnecting(attempt: Int, maximumAttempts: Int)
    case stopping
    case failed(message: String)

    var statusText: String {
        switch self {
        case .inactive:
            String(localized: "Not connected")
        case .reservingRoom:
            String(localized: "Creating share link…")
        case .connecting:
            String(localized: "Connecting…")
        case .ready:
            String(localized: "Ready to share")
        case .starting:
            String(localized: "Starting…")
        case let .live(elapsedSeconds):
            String(localized: "Live · \(LiveShareDurationFormatting.string(elapsedSeconds))")
        case let .reconnecting(attempt, maximumAttempts):
            String(localized: "Reconnecting \(max(1, attempt))/\(max(1, maximumAttempts))…")
        case .stopping:
            String(localized: "Stopping…")
        case let .failed(message):
            message
        }
    }

    var showsLiveIndicator: Bool {
        switch self {
        case .starting, .live:
            true
        default:
            false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct LiveShareRoomViewSnapshot: Equatable, Sendable {
    let viewerURL: URL
    let roomCode: String
}

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

struct LiveShareSourceViewSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let slotIndex: Int
    let applicationName: String
    let windowTitle: String
    let applicationPath: String?
    let status: LiveShareSourceViewStatus
    let isFocused: Bool
    let canStop: Bool

    init(
        id: String,
        slotIndex: Int,
        applicationName: String,
        windowTitle: String,
        applicationPath: String? = nil,
        status: LiveShareSourceViewStatus,
        isFocused: Bool = false,
        canStop: Bool = true
    ) {
        self.id = id
        self.slotIndex = min(max(0, slotIndex), 3)
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.applicationPath = applicationPath
        self.status = status
        self.isFocused = isFocused
        self.canStop = canStop
    }
}

struct LiveShareAvailableWindowViewSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let applicationName: String
    let windowTitle: String
    let applicationPath: String?
}

enum LiveShareSourceSlotState: String, Equatable, Sendable {
    case empty
    case starting
    case live
}

struct LiveShareSourceSlotViewSnapshot: Equatable, Identifiable, Sendable {
    let index: Int
    let state: LiveShareSourceSlotState

    var id: Int { index }
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
        codec: LiveShareVideoCodec = .vp8,
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
    let systemAudioEnabled: Bool
    let prioritizeFocusedWindow: Bool
    let mode: LiveShareEncodingMode
    let autoShareFocusedWindows: Bool
    let canChangeQuality: Bool
    let canChangeFrameRate: Bool
    let availableFrameRates: Set<LiveShareFrameRate>
    let canChangeCodec: Bool
    let canChangeSystemAudio: Bool
    let canChangePrioritizeFocusedWindow: Bool
    let canChangeMode: Bool
    let canChangeAutoShare: Bool

    init(
        quality: LiveShareQualityPreset = .veryHigh,
        frameRate: LiveShareFrameRate = .thirty,
        codec: LiveShareCodecViewSnapshot = .init(),
        systemAudioEnabled: Bool = false,
        prioritizeFocusedWindow: Bool = true,
        mode: LiveShareEncodingMode = .quality,
        autoShareFocusedWindows: Bool = false,
        canChangeQuality: Bool = true,
        canChangeFrameRate: Bool = true,
        availableFrameRates: Set<LiveShareFrameRate> = Set(LiveShareFrameRate.allCases),
        canChangeCodec: Bool = true,
        canChangeSystemAudio: Bool = true,
        canChangePrioritizeFocusedWindow: Bool = true,
        canChangeMode: Bool = true,
        canChangeAutoShare: Bool = true
    ) {
        self.quality = quality
        self.frameRate = frameRate
        self.codec = codec
        self.systemAudioEnabled = systemAudioEnabled
        self.prioritizeFocusedWindow = prioritizeFocusedWindow
        self.mode = mode
        self.autoShareFocusedWindows = autoShareFocusedWindows
        self.canChangeQuality = canChangeQuality
        self.canChangeFrameRate = canChangeFrameRate
        self.availableFrameRates = availableFrameRates
        self.canChangeCodec = canChangeCodec
        self.canChangeSystemAudio = canChangeSystemAudio
        self.canChangePrioritizeFocusedWindow = canChangePrioritizeFocusedWindow
        self.canChangeMode = canChangeMode
        self.canChangeAutoShare = canChangeAutoShare
    }
}

enum LiveShareViewerConnection: String, Equatable, Sendable {
    case connecting
    case connected
    case peerToPeer
    case turn
    case disconnected

    var title: String {
        switch self {
        case .connecting: String(localized: "Connecting")
        case .connected: String(localized: "Connected")
        case .peerToPeer: "P2P"
        case .turn: "TURN"
        case .disconnected: String(localized: "Disconnected")
        }
    }

    var isConnected: Bool {
        self == .connected || self == .peerToPeer || self == .turn
    }
}

struct LiveShareViewerViewSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let connection: LiveShareViewerConnection
    let connectedDuration: TimeInterval?
}

struct LiveShareStreamStatisticsViewSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let deliveredFramesPerSecond: Double
    let bitsPerSecond: Int
    let targetBitsPerSecond: Int?
    let configuredBitrateCeiling: Int
    let bytesSent: Int64
    let captureDeliveredFrames: UInt64
    let captureBackpressureDrops: UInt64
    let encoderDroppedFrames: UInt64
    let averageEncodeTimeMilliseconds: Double?
    let averagePacketSendDelayMilliseconds: Double?
    let qualityLimitationReasons: [String]
    let codec: String?
    let isFocused: Bool

    init(
        id: String,
        name: String,
        width: Int,
        height: Int,
        deliveredFramesPerSecond: Double,
        bitsPerSecond: Int,
        targetBitsPerSecond: Int? = nil,
        configuredBitrateCeiling: Int = 0,
        bytesSent: Int64,
        captureDeliveredFrames: UInt64 = 0,
        captureBackpressureDrops: UInt64 = 0,
        encoderDroppedFrames: UInt64 = 0,
        averageEncodeTimeMilliseconds: Double? = nil,
        averagePacketSendDelayMilliseconds: Double? = nil,
        qualityLimitationReasons: [String] = [],
        codec: String? = nil,
        isFocused: Bool = false
    ) {
        self.id = id
        self.name = name
        self.width = max(0, width)
        self.height = max(0, height)
        self.deliveredFramesPerSecond = max(0, deliveredFramesPerSecond)
        self.bitsPerSecond = max(0, bitsPerSecond)
        self.targetBitsPerSecond = targetBitsPerSecond.map { max(0, $0) }
        self.configuredBitrateCeiling = max(0, configuredBitrateCeiling)
        self.bytesSent = max(0, bytesSent)
        self.captureDeliveredFrames = captureDeliveredFrames
        self.captureBackpressureDrops = captureBackpressureDrops
        self.encoderDroppedFrames = encoderDroppedFrames
        self.averageEncodeTimeMilliseconds = averageEncodeTimeMilliseconds.map {
            max(0, $0)
        }
        self.averagePacketSendDelayMilliseconds = averagePacketSendDelayMilliseconds.map {
            max(0, $0)
        }
        self.qualityLimitationReasons = qualityLimitationReasons
        self.codec = codec
        self.isFocused = isFocused
    }
}

struct LiveShareStatisticsViewSnapshot: Equatable, Sendable {
    let uptime: TimeInterval
    let streams: [LiveShareStreamStatisticsViewSnapshot]
    let h264SubmissionBackpressureDrops: UInt64

    init(
        uptime: TimeInterval = 0,
        streams: [LiveShareStreamStatisticsViewSnapshot] = [],
        h264SubmissionBackpressureDrops: UInt64 = 0
    ) {
        self.uptime = max(0, uptime)
        self.streams = streams
        self.h264SubmissionBackpressureDrops = h264SubmissionBackpressureDrops
    }
}

struct LiveShareCapturePressureWarningSnapshot: Equatable, Sendable {
    let sourceNames: [String]

    init(sourceNames: [String]) {
        var seen = Set<String>()
        self.sourceNames = sourceNames.compactMap { rawName in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    var title: String {
        String(localized: "Capture is dropping frames")
    }

    var message: String {
        switch sourceNames.count {
        case 1:
            String(
                localized: "Clip is dropping many frames from \(sourceNames[0]). Lower the frame rate or quality."
            )
        case 2...:
            String(
                localized: "Clip is dropping many frames from \(sourceNames.count) sources. Lower the frame rate or quality."
            )
        default:
            String(localized: "Clip is dropping many capture frames. Lower the frame rate or quality.")
        }
    }
}

struct LiveShareViewSnapshot: Equatable, Sendable {
    let phase: LiveShareViewPhase
    let room: LiveShareRoomViewSnapshot?
    let accessCodeEnabled: Bool
    let accessCode: String?
    let canChangeAccessCode: Bool
    let accessCodeError: String?
    let sources: [LiveShareSourceViewSnapshot]
    let slots: [LiveShareSourceSlotViewSnapshot]
    let fullscreen: LiveShareFullscreenViewSnapshot
    let canShareFocusedWindow: Bool
    let focusedWindowDescription: String?
    let availableWindows: [LiveShareAvailableWindowViewSnapshot]
    let canAddWindow: Bool
    let settings: LiveShareSettingsViewSnapshot
    let viewers: [LiveShareViewerViewSnapshot]
    let connectedViewerCount: Int
    let statistics: LiveShareStatisticsViewSnapshot
    let capturePressureWarning: LiveShareCapturePressureWarningSnapshot?

    init(
        phase: LiveShareViewPhase,
        room: LiveShareRoomViewSnapshot? = nil,
        accessCodeEnabled: Bool = false,
        accessCode: String? = nil,
        canChangeAccessCode: Bool = true,
        accessCodeError: String? = nil,
        sources: [LiveShareSourceViewSnapshot] = [],
        slots: [LiveShareSourceSlotViewSnapshot] = [],
        fullscreen: LiveShareFullscreenViewSnapshot = .init(
            isOn: false,
            displayName: String(localized: "Main Display"),
            isEnabled: true
        ),
        canShareFocusedWindow: Bool = false,
        focusedWindowDescription: String? = nil,
        availableWindows: [LiveShareAvailableWindowViewSnapshot] = [],
        canAddWindow: Bool = false,
        settings: LiveShareSettingsViewSnapshot = .init(),
        viewers: [LiveShareViewerViewSnapshot] = [],
        connectedViewerCount: Int? = nil,
        statistics: LiveShareStatisticsViewSnapshot = .init(),
        capturePressureWarning: LiveShareCapturePressureWarningSnapshot? = nil
    ) {
        self.phase = phase
        self.room = room
        self.accessCodeEnabled = accessCodeEnabled
        self.accessCode = accessCode
        self.canChangeAccessCode = canChangeAccessCode
        self.accessCodeError = accessCodeError
        self.sources = sources
        self.slots = Self.normalizedSlots(slots)
        self.fullscreen = fullscreen
        self.canShareFocusedWindow = canShareFocusedWindow
        self.focusedWindowDescription = focusedWindowDescription
        self.availableWindows = availableWindows
        self.canAddWindow = canAddWindow
        self.settings = settings
        self.viewers = viewers
        self.connectedViewerCount = max(
            0,
            connectedViewerCount ?? viewers.count(where: { $0.connection.isConnected })
        )
        self.statistics = statistics
        self.capturePressureWarning = capturePressureWarning
    }

    var hasActiveMedia: Bool {
        fullscreen.isOn || slots.contains { $0.state != .empty }
    }

    var canStopSession: Bool {
        phase != .inactive && phase != .stopping
    }

    private static func normalizedSlots(
        _ supplied: [LiveShareSourceSlotViewSnapshot]
    ) -> [LiveShareSourceSlotViewSnapshot] {
        let states = Dictionary(
            supplied.filter { (0..<4).contains($0.index) }.map { ($0.index, $0.state) },
            uniquingKeysWith: { _, newest in newest }
        )
        return (0..<4).map {
            LiveShareSourceSlotViewSnapshot(index: $0, state: states[$0] ?? .empty)
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
