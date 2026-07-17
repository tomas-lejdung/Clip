import ClipCore
import Foundation

enum AppLaunchMode: Equatable, Sendable {
    case standard
    case uiTesting
    case realCaptureAcceptance
}

/// Production views that can be launched with deterministic, inert state for UI-source
/// coverage. The argument is intentionally honored only alongside `--ui-testing` and never
/// alongside the permission-backed real-capture lane.
enum DeterministicUIScenario: String, CaseIterable, Equatable, Sendable {
    case onboarding
    case menuPopover = "menu-popover"
    case permissionsDenied = "permissions-denied"
    case recording
    case paused
    case preview
    case history
    case settings
    case failure

    static let argumentPrefix = "--ui-scenario="

    var launchArgument: String {
        Self.argumentPrefix + rawValue
    }
}

enum DeterministicUIScenarioRequest: Equatable, Sendable {
    case none
    case scenario(DeterministicUIScenario)
    /// Invalid and ambiguous values fail closed into an inert diagnostic fixture instead of
    /// falling through to the production coordinator and its live platform services.
    case invalid
}

/// Narrow, test-only settings used by the owner-approved real-Mac lanes. Every override is
/// ignored unless both `--ui-testing` and `--real-capture-acceptance` are present. File-system
/// destinations are additionally constrained to the process temporary directory.
struct RealCaptureAcceptanceOverrides: Equatable, Sendable {
    var frameRate: CaptureFrameRate?
    var showsCursor: Bool?
    var remembersLastArea: Bool
    var historyRetention: HistoryRetentionPolicy?
    var defaultSaveDirectory: URL?
    var preservesIsolatedState: Bool

    static let none = RealCaptureAcceptanceOverrides(
        frameRate: nil,
        showsCursor: nil,
        remembersLastArea: false,
        historyRetention: nil,
        defaultSaveDirectory: nil,
        preservesIsolatedState: false
    )
}

/// Resolves process launch flags once, before any persistent application state is opened.
/// UI tests receive their own temporary file hierarchy and defaults suite so a test run
/// cannot read or mutate the user's settings, History, Last Area, or permission bookkeeping.
struct AppLaunchConfiguration: Equatable, Sendable {
    static let uiTestingArgument = "--ui-testing"
    static let realCaptureAcceptanceArgument = "--real-capture-acceptance"
    static let realMicrophoneAcceptanceArgument = "--real-capture-audio=microphone"
    static let realSystemAudioAcceptanceArgument = "--real-capture-audio=system"
    static let realCombinedAudioAcceptanceArgument = "--real-capture-audio=both"
    static let realFrameRateArgumentPrefix = "--real-capture-frame-rate="
    static let realCursorArgumentPrefix = "--real-capture-cursor="
    static let realRememberLastAreaArgument = "--real-capture-remember-last-area"
    static let realRetentionArgumentPrefix = "--real-capture-retention="
    static let realSaveDirectoryArgumentPrefix = "--real-capture-save-directory="
    static let realStateIdentifierArgumentPrefix = "--real-capture-state-id="
    static let realPreserveStateArgument = "--real-capture-preserve-state"

    let mode: AppLaunchMode
    let isolatedStateRoot: URL?
    let defaultsSuiteName: String?
    /// Test-only audio override. It is resolved only when both UI-test and
    /// real-capture flags are present, so these arguments cannot alter a
    /// normal app launch.
    let realCaptureAudioConfiguration: AudioConfiguration?
    let realCaptureOverrides: RealCaptureAcceptanceOverrides
    let uiScenarioRequest: DeterministicUIScenarioRequest

    static func current(
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default
    ) -> AppLaunchConfiguration {
        let arguments = processInfo.arguments
        let isolationIdentifier = isolationIdentifier(for: arguments)
        return resolve(
            arguments: arguments,
            temporaryDirectory: fileManager.temporaryDirectory,
            isolationIdentifier: isolationIdentifier
        )
    }

    static func resolve(
        arguments: [String],
        temporaryDirectory: URL,
        isolationIdentifier: String
    ) -> AppLaunchConfiguration {
        guard arguments.contains(uiTestingArgument) else {
            return AppLaunchConfiguration(
                mode: .standard,
                isolatedStateRoot: nil,
                defaultsSuiteName: nil,
                realCaptureAudioConfiguration: nil,
                realCaptureOverrides: .none,
                uiScenarioRequest: .none
            )
        }

        let isRealCaptureAcceptance = arguments.contains(realCaptureAcceptanceArgument)
        let uiScenarioRequest = resolveUIScenarioRequest(
            arguments: arguments,
            isRealCaptureAcceptance: isRealCaptureAcceptance
        )
        let mode: AppLaunchMode = isRealCaptureAcceptance
            ? .realCaptureAcceptance
            : .uiTesting
        let realCaptureAudioConfiguration: AudioConfiguration?
        if isRealCaptureAcceptance,
           arguments.contains(realCombinedAudioAcceptanceArgument),
           !arguments.contains(realMicrophoneAcceptanceArgument),
           !arguments.contains(realSystemAudioAcceptanceArgument) {
            realCaptureAudioConfiguration = .microphoneAndSystemAudio
        } else if isRealCaptureAcceptance,
           arguments.contains(realMicrophoneAcceptanceArgument),
           !arguments.contains(realSystemAudioAcceptanceArgument),
           !arguments.contains(realCombinedAudioAcceptanceArgument) {
            realCaptureAudioConfiguration = .microphoneOnly
        } else if isRealCaptureAcceptance,
                  arguments.contains(realSystemAudioAcceptanceArgument),
                  !arguments.contains(realMicrophoneAcceptanceArgument),
                  !arguments.contains(realCombinedAudioAcceptanceArgument) {
            realCaptureAudioConfiguration = .systemAudioOnly
        } else {
            realCaptureAudioConfiguration = nil
        }
        let realCaptureOverrides = isRealCaptureAcceptance
            ? resolveRealCaptureOverrides(
                arguments: arguments,
                temporaryDirectory: temporaryDirectory
            )
            : .none
        let stateRoot = temporaryDirectory
            .appendingPathComponent("Clip-UI-Testing", isDirectory: true)
            .appendingPathComponent(isolationIdentifier, isDirectory: true)
        return AppLaunchConfiguration(
            mode: mode,
            isolatedStateRoot: stateRoot,
            defaultsSuiteName: "\(ApplicationDirectories.bundleIdentifier).ui-testing.\(isolationIdentifier)",
            realCaptureAudioConfiguration: realCaptureAudioConfiguration,
            realCaptureOverrides: realCaptureOverrides,
            uiScenarioRequest: uiScenarioRequest
        )
    }

    static func isolationIdentifier(for arguments: [String]) -> String {
        guard arguments.contains(uiTestingArgument) else { return "ui-testing" }
        guard !arguments.contains(realCaptureAcceptanceArgument) else {
            if let identifier = realCaptureStateIdentifier(in: arguments) {
                return "real-capture-\(identifier)"
            }
            return "real-capture-acceptance"
        }

        switch resolveUIScenarioRequest(
            arguments: arguments,
            isRealCaptureAcceptance: false
        ) {
        case .none:
            return "ui-testing"
        case let .scenario(scenario):
            return "ui-scenario-\(scenario.rawValue)"
        case .invalid:
            return "ui-scenario-invalid"
        }
    }

    private static func resolveUIScenarioRequest(
        arguments: [String],
        isRealCaptureAcceptance: Bool
    ) -> DeterministicUIScenarioRequest {
        guard !isRealCaptureAcceptance else { return .none }
        let scenarioArguments = arguments.filter {
            $0 == "--ui-scenario" || $0.hasPrefix(DeterministicUIScenario.argumentPrefix)
        }
        guard !scenarioArguments.isEmpty else { return .none }
        guard scenarioArguments.count == 1,
              scenarioArguments[0].hasPrefix(DeterministicUIScenario.argumentPrefix) else {
            return .invalid
        }

        let rawValue = String(
            scenarioArguments[0].dropFirst(DeterministicUIScenario.argumentPrefix.count)
        )
        guard let scenario = DeterministicUIScenario(rawValue: rawValue) else {
            return .invalid
        }
        return .scenario(scenario)
    }

    private static func resolveRealCaptureOverrides(
        arguments: [String],
        temporaryDirectory: URL
    ) -> RealCaptureAcceptanceOverrides {
        let frameRate: CaptureFrameRate?
        switch uniqueValue(for: realFrameRateArgumentPrefix, in: arguments) {
        case "30": frameRate = .thirty
        case "60": frameRate = .sixty
        default: frameRate = nil
        }

        let showsCursor: Bool?
        switch uniqueValue(for: realCursorArgumentPrefix, in: arguments) {
        case "on": showsCursor = true
        case "off": showsCursor = false
        default: showsCursor = nil
        }

        let retention: HistoryRetentionPolicy?
        switch uniqueValue(for: realRetentionArgumentPrefix, in: arguments) {
        case "indefinitely": retention = .indefinitely
        case "do-not-retain": retention = .doNotRetainAfterExport
        default: retention = nil
        }

        let defaultSaveDirectory = uniqueValue(
            for: realSaveDirectoryArgumentPrefix,
            in: arguments
        ).flatMap { rawPath -> URL? in
            guard !rawPath.isEmpty else { return nil }
            let candidate = URL(fileURLWithPath: rawPath, isDirectory: true)
                .standardizedFileURL
            let temporaryRoot = temporaryDirectory.standardizedFileURL
            let rootPath = temporaryRoot.path.hasSuffix("/")
                ? temporaryRoot.path
                : temporaryRoot.path + "/"
            guard candidate.path == temporaryRoot.path
                    || candidate.path.hasPrefix(rootPath) else {
                return nil
            }
            return candidate
        }

        let hasDedicatedState = realCaptureStateIdentifier(in: arguments) != nil
        return RealCaptureAcceptanceOverrides(
            frameRate: frameRate,
            showsCursor: showsCursor,
            remembersLastArea: arguments.contains(realRememberLastAreaArgument),
            historyRetention: retention,
            defaultSaveDirectory: defaultSaveDirectory,
            preservesIsolatedState: hasDedicatedState
                && arguments.contains(realPreserveStateArgument)
        )
    }

    private static func uniqueValue(
        for prefix: String,
        in arguments: [String]
    ) -> String? {
        let values = arguments.compactMap { argument -> String? in
            guard argument.hasPrefix(prefix) else { return nil }
            return String(argument.dropFirst(prefix.count))
        }
        guard values.count == 1 else { return nil }
        return values[0]
    }

    private static func realCaptureStateIdentifier(in arguments: [String]) -> String? {
        guard let value = uniqueValue(
            for: realStateIdentifierArgumentPrefix,
            in: arguments
        ), (1...64).contains(value.count) else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    var isUITesting: Bool { mode != .standard }
    var completesOnboarding: Bool { mode == .realCaptureAcceptance }
    var uiScenario: DeterministicUIScenario? {
        guard case let .scenario(scenario) = uiScenarioRequest else { return nil }
        return scenario
    }

    var launchesDeterministicUIScenario: Bool {
        guard mode == .uiTesting else { return false }
        return uiScenarioRequest != .none
    }

    /// UI tests must not register a login item or global hot keys. Those APIs affect
    /// system-wide state and can conflict with an installed copy of Clip.
    var allowsSystemIntegrations: Bool { mode == .standard }

    var resetsIsolatedStateOnLaunch: Bool {
        !realCaptureOverrides.preservesIsolatedState
    }

    func makeUserDefaults() throws -> UserDefaults {
        guard let defaultsSuiteName else { return .standard }
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw AppLaunchConfigurationError.unavailableDefaultsSuite(defaultsSuiteName)
        }
        if resetsIsolatedStateOnLaunch {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        return defaults
    }

    func initialSettings(homeDirectory: URL) -> ClipSettings? {
        guard mode == .realCaptureAcceptance else { return nil }

        var settings = ClipSettings.defaults(homeDirectory: homeDirectory)
        settings.launchAtLogin = false
        settings.showInDock = false
        settings.defaultCaptureMode = .fullscreen
        settings.mostRecentCaptureMode = .fullscreen
        settings.rememberLastArea = realCaptureOverrides.remembersLastArea
        settings.frameRate = realCaptureOverrides.frameRate ?? .thirty
        settings.showCursor = realCaptureOverrides.showsCursor ?? true
        settings.audio = realCaptureAudioConfiguration ?? .none
        settings.countdown = .oneSecond
        settings.historyRetention = realCaptureOverrides.historyRetention ?? .indefinitely
        settings.exportConfiguration = .compact
        settings.automaticallyClosePreviewAfterCopy = false
        settings.keepOriginalAfterExport = true
        if let defaultSaveDirectory = realCaptureOverrides.defaultSaveDirectory {
            settings.defaultSaveDirectory = defaultSaveDirectory
        }
        return settings
    }
}

enum AppLaunchConfigurationError: LocalizedError, Equatable {
    case unavailableDefaultsSuite(String)

    var errorDescription: String? {
        switch self {
        case let .unavailableDefaultsSuite(suiteName):
            "Clip could not create its isolated UI-test defaults suite \(suiteName)."
        }
    }
}

struct ApplicationDirectories: Equatable, Sendable {
    static let bundleIdentifier = "com.tomaslejdung.clip"

    let applicationSupport: URL
    let recordings: URL
    let exports: URL
    let caches: URL

    static func resolve(
        fileManager: FileManager = .default,
        fileSystem: any FileSystemServicing
    ) throws -> ApplicationDirectories {
        guard let applicationSupportRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ApplicationDirectoryError.missingApplicationSupportDirectory
        }

        guard let cachesRoot = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw ApplicationDirectoryError.missingCachesDirectory
        }

        return try resolve(
            applicationSupportRoot: applicationSupportRoot,
            cachesRoot: cachesRoot,
            bundleIdentifier: bundleIdentifier,
            fileSystem: fileSystem
        )
    }

    static func resolve(
        applicationSupportRoot: URL,
        cachesRoot: URL,
        bundleIdentifier: String,
        fileSystem: any FileSystemServicing
    ) throws -> ApplicationDirectories {
        let applicationSupport = applicationSupportRoot
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        let recordings = applicationSupport
            .appendingPathComponent("Recordings", isDirectory: true)
        let caches = cachesRoot
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        let exports = caches
            .appendingPathComponent("Exports", isDirectory: true)

        for directory in [applicationSupport, recordings, exports, caches] {
            try fileSystem.createDirectory(at: directory)
        }

        return ApplicationDirectories(
            applicationSupport: applicationSupport,
            recordings: recordings,
            exports: exports,
            caches: caches
        )
    }
}

enum ApplicationDirectoryError: LocalizedError {
    case missingApplicationSupportDirectory
    case missingCachesDirectory

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupportDirectory:
            String(localized: "The Application Support directory is unavailable.")
        case .missingCachesDirectory:
            String(localized: "The Caches directory is unavailable.")
        }
    }
}
