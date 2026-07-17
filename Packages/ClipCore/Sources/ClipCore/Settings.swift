import Foundation

public enum CaptureMode: String, CaseIterable, Codable, Hashable, Sendable {
    case captureArea
    case lastArea
    case fullscreen
    case captureApplication
}

public enum CaptureFrameRate: Int, CaseIterable, Codable, Hashable, Sendable {
    case thirty = 30
    case sixty = 60

    public var framesPerSecond: Int { rawValue }
}

public enum CountdownDuration: Int, CaseIterable, Codable, Hashable, Sendable {
    case off = 0
    case oneSecond = 1
    case threeSeconds = 3
    case fiveSeconds = 5

    public var seconds: Int { rawValue }
}

public struct AudioConfiguration: Codable, Equatable, Hashable, Sendable {
    public var microphoneEnabled: Bool
    public var systemAudioEnabled: Bool

    public init(microphoneEnabled: Bool, systemAudioEnabled: Bool) {
        self.microphoneEnabled = microphoneEnabled
        self.systemAudioEnabled = systemAudioEnabled
    }

    public static let none = Self(microphoneEnabled: false, systemAudioEnabled: false)
    public static let microphoneOnly = Self(microphoneEnabled: true, systemAudioEnabled: false)
    public static let systemAudioOnly = Self(microphoneEnabled: false, systemAudioEnabled: true)
    public static let microphoneAndSystemAudio = Self(
        microphoneEnabled: true,
        systemAudioEnabled: true
    )
}

/// The settings that materially define a capture session.
///
/// Capture targets are persisted separately on each history item. Keeping this
/// snapshot deliberately smaller than ``ClipSettings`` prevents unrelated
/// preferences (such as History retention or keyboard shortcuts) from becoming
/// part of Retake while still preserving every setting consumed by countdown
/// and native capture.
public struct CaptureSessionSnapshot: Codable, Equatable, Hashable, Sendable {
    public let frameRate: CaptureFrameRate
    public let showCursor: Bool
    public let audio: AudioConfiguration
    public let countdown: CountdownDuration

    public init(
        frameRate: CaptureFrameRate,
        showCursor: Bool,
        audio: AudioConfiguration,
        countdown: CountdownDuration
    ) {
        self.frameRate = frameRate
        self.showCursor = showCursor
        self.audio = audio
        self.countdown = countdown
    }

    public init(settings: ClipSettings) {
        self.init(
            frameRate: settings.frameRate,
            showCursor: settings.showCursor,
            audio: settings.audio,
            countdown: settings.countdown
        )
    }

    /// Restores the persisted capture values without rolling back preferences
    /// that do not affect capture.
    public func applying(to settings: ClipSettings) -> ClipSettings {
        var result = settings
        result.frameRate = frameRate
        result.showCursor = showCursor
        result.audio = audio
        result.countdown = countdown
        return result
    }
}

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let shift = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)

    public static let supported: Self = [.command, .option, .shift, .control]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(UInt8.self)
        guard rawValue & ~Self.supported.rawValue == 0 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Shortcut contains unsupported modifier bits."
            )
        }
        self.init(rawValue: rawValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum KeyboardShortcutError: Error, Equatable, Sendable {
    case keyMustBeOneCharacter
    case keyContainsControlCharacter
    case modifiersRequired
}

public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public let key: String
    public let modifiers: ShortcutModifiers

    public init(key: String, modifiers: ShortcutModifiers) throws {
        let normalizedKey = key.lowercased()
        guard normalizedKey.count == 1 else {
            throw KeyboardShortcutError.keyMustBeOneCharacter
        }
        guard !normalizedKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw KeyboardShortcutError.keyContainsControlCharacter
        }
        guard !modifiers.isEmpty else {
            throw KeyboardShortcutError.modifiersRequired
        }
        self.key = normalizedKey
        self.modifiers = modifiers
    }

    private enum CodingKeys: CodingKey {
        case key
        case modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        let modifiers = try container.decode(ShortcutModifiers.self, forKey: .modifiers)
        do {
            try self.init(key: key, modifiers: modifiers)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .key,
                in: container,
                debugDescription: "Invalid keyboard shortcut: \(error)"
            )
        }
    }
}

public enum GlobalShortcutAction: String, CaseIterable, Codable, Hashable, Sendable {
    case capture
    case finish
    case pauseOrResume
}

public struct ShortcutConflict: Codable, Equatable, Hashable, Sendable {
    public let shortcut: KeyboardShortcut
    public let actions: Set<GlobalShortcutAction>

    public init(shortcut: KeyboardShortcut, actions: Set<GlobalShortcutAction>) {
        self.shortcut = shortcut
        self.actions = actions
    }
}

public struct ShortcutConfiguration: Codable, Equatable, Sendable {
    public var capture: KeyboardShortcut
    public var finish: KeyboardShortcut
    public var pauseOrResume: KeyboardShortcut

    public init(
        capture: KeyboardShortcut,
        finish: KeyboardShortcut,
        pauseOrResume: KeyboardShortcut
    ) {
        self.capture = capture
        self.finish = finish
        self.pauseOrResume = pauseOrResume
    }

    public static var defaults: Self {
        // These literals are guaranteed by tests and cannot fail unless their source is edited.
        Self(
            capture: try! KeyboardShortcut(key: "r", modifiers: [.option, .command]),
            finish: try! KeyboardShortcut(key: "s", modifiers: [.option, .command]),
            pauseOrResume: try! KeyboardShortcut(key: "p", modifiers: [.option, .command])
        )
    }

    public subscript(action: GlobalShortcutAction) -> KeyboardShortcut {
        get {
            switch action {
            case .capture: capture
            case .finish: finish
            case .pauseOrResume: pauseOrResume
            }
        }
        set {
            switch action {
            case .capture: capture = newValue
            case .finish: finish = newValue
            case .pauseOrResume: pauseOrResume = newValue
            }
        }
    }

    public var conflicts: [ShortcutConflict] {
        let pairs = GlobalShortcutAction.allCases.map { ($0, self[$0]) }
        let grouped = Dictionary(grouping: pairs, by: \.1)
        return grouped.compactMap { shortcut, entries in
            let actions = Set(entries.map(\.0))
            guard actions.count > 1 else { return nil }
            return ShortcutConflict(shortcut: shortcut, actions: actions)
        }
        .sorted { lhs, rhs in
            if lhs.shortcut.modifiers.rawValue != rhs.shortcut.modifiers.rawValue {
                return lhs.shortcut.modifiers.rawValue < rhs.shortcut.modifiers.rawValue
            }
            return lhs.shortcut.key < rhs.shortcut.key
        }
    }
}

public struct ClipSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var launchAtLogin: Bool
    public var showInDock: Bool
    public var defaultCaptureMode: CaptureMode
    /// The last capture mode the user explicitly invoked. Older settings files
    /// decode this as nil and fall back to `defaultCaptureMode`.
    public var mostRecentCaptureMode: CaptureMode?
    public var rememberLastArea: Bool
    public var frameRate: CaptureFrameRate
    public var showCursor: Bool
    public var audio: AudioConfiguration
    public var countdown: CountdownDuration
    public var historyRetention: HistoryRetentionPolicy
    public var exportConfiguration: ExportConfiguration
    public var defaultFilenameTemplate: RecordingFilenameTemplate
    public var automaticallyClosePreviewAfterCopy: Bool
    public var keepOriginalAfterExport: Bool
    public var defaultSaveDirectory: URL
    public var shortcuts: ShortcutConfiguration

    public init(
        schemaVersion: Int = ClipSettings.currentSchemaVersion,
        launchAtLogin: Bool,
        showInDock: Bool,
        defaultCaptureMode: CaptureMode,
        mostRecentCaptureMode: CaptureMode? = nil,
        rememberLastArea: Bool,
        frameRate: CaptureFrameRate,
        showCursor: Bool,
        audio: AudioConfiguration,
        countdown: CountdownDuration,
        historyRetention: HistoryRetentionPolicy,
        exportConfiguration: ExportConfiguration,
        defaultFilenameTemplate: RecordingFilenameTemplate = .default,
        automaticallyClosePreviewAfterCopy: Bool,
        keepOriginalAfterExport: Bool,
        defaultSaveDirectory: URL,
        shortcuts: ShortcutConfiguration
    ) {
        self.schemaVersion = schemaVersion
        self.launchAtLogin = launchAtLogin
        self.showInDock = showInDock
        self.defaultCaptureMode = defaultCaptureMode
        self.mostRecentCaptureMode = mostRecentCaptureMode
        self.rememberLastArea = rememberLastArea
        self.frameRate = frameRate
        self.showCursor = showCursor
        self.audio = audio
        self.countdown = countdown
        self.historyRetention = historyRetention
        self.exportConfiguration = exportConfiguration
        self.defaultFilenameTemplate = defaultFilenameTemplate
        self.automaticallyClosePreviewAfterCopy = automaticallyClosePreviewAfterCopy
        self.keepOriginalAfterExport = keepOriginalAfterExport
        self.defaultSaveDirectory = defaultSaveDirectory
        self.shortcuts = shortcuts
    }

    public static func defaults(homeDirectory: URL) -> Self {
        Self(
            launchAtLogin: false,
            showInDock: false,
            defaultCaptureMode: .captureArea,
            mostRecentCaptureMode: nil,
            rememberLastArea: true,
            frameRate: .thirty,
            showCursor: true,
            audio: .none,
            countdown: .threeSeconds,
            historyRetention: .sevenDays,
            exportConfiguration: .compact,
            defaultFilenameTemplate: .default,
            automaticallyClosePreviewAfterCopy: false,
            keepOriginalAfterExport: true,
            defaultSaveDirectory: homeDirectory.appending(path: "Movies", directoryHint: .isDirectory),
            shortcuts: .defaults
        )
    }

    /// Capture is initially driven by the configured default, then follows the
    /// mode the user most recently chose from Clip's capture controls.
    public var captureModeForNextInvocation: CaptureMode {
        mostRecentCaptureMode ?? defaultCaptureMode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case launchAtLogin
        case showInDock
        case defaultCaptureMode
        case mostRecentCaptureMode
        case rememberLastArea
        case frameRate
        case showCursor
        case audio
        case countdown
        case historyRetention
        case exportConfiguration
        case defaultFilenameTemplate
        case automaticallyClosePreviewAfterCopy
        case keepOriginalAfterExport
        case defaultSaveDirectory
        case shortcuts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedSchemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? 1
        guard (1...Self.currentSchemaVersion).contains(persistedSchemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported Clip settings schema \(persistedSchemaVersion)."
            )
        }

        // Schema 1 did not persist a filename template. Decoding it as the
        // product default is an in-memory migration; the next settings write
        // persists schema 2 without requiring a separate migration file.
        schemaVersion = Self.currentSchemaVersion
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        showInDock = try container.decode(Bool.self, forKey: .showInDock)
        defaultCaptureMode = try container.decode(CaptureMode.self, forKey: .defaultCaptureMode)
        mostRecentCaptureMode = try container.decodeIfPresent(
            CaptureMode.self,
            forKey: .mostRecentCaptureMode
        )
        rememberLastArea = try container.decode(Bool.self, forKey: .rememberLastArea)
        frameRate = try container.decode(CaptureFrameRate.self, forKey: .frameRate)
        showCursor = try container.decode(Bool.self, forKey: .showCursor)
        audio = try container.decode(AudioConfiguration.self, forKey: .audio)
        countdown = try container.decode(CountdownDuration.self, forKey: .countdown)
        historyRetention = try container.decode(
            HistoryRetentionPolicy.self,
            forKey: .historyRetention
        )
        exportConfiguration = try container.decode(
            ExportConfiguration.self,
            forKey: .exportConfiguration
        )
        defaultFilenameTemplate = try container.decodeIfPresent(
            RecordingFilenameTemplate.self,
            forKey: .defaultFilenameTemplate
        ) ?? .default
        automaticallyClosePreviewAfterCopy = try container.decode(
            Bool.self,
            forKey: .automaticallyClosePreviewAfterCopy
        )
        keepOriginalAfterExport = try container.decode(
            Bool.self,
            forKey: .keepOriginalAfterExport
        )
        defaultSaveDirectory = try container.decode(URL.self, forKey: .defaultSaveDirectory)
        shortcuts = try container.decode(ShortcutConfiguration.self, forKey: .shortcuts)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(showInDock, forKey: .showInDock)
        try container.encode(defaultCaptureMode, forKey: .defaultCaptureMode)
        try container.encodeIfPresent(mostRecentCaptureMode, forKey: .mostRecentCaptureMode)
        try container.encode(rememberLastArea, forKey: .rememberLastArea)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(showCursor, forKey: .showCursor)
        try container.encode(audio, forKey: .audio)
        try container.encode(countdown, forKey: .countdown)
        try container.encode(historyRetention, forKey: .historyRetention)
        try container.encode(exportConfiguration, forKey: .exportConfiguration)
        try container.encode(defaultFilenameTemplate, forKey: .defaultFilenameTemplate)
        try container.encode(
            automaticallyClosePreviewAfterCopy,
            forKey: .automaticallyClosePreviewAfterCopy
        )
        try container.encode(keepOriginalAfterExport, forKey: .keepOriginalAfterExport)
        try container.encode(defaultSaveDirectory, forKey: .defaultSaveDirectory)
        try container.encode(shortcuts, forKey: .shortcuts)
    }
}
