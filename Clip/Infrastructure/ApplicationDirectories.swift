import ClipCore
import Foundation

enum AppLaunchMode: Equatable, Sendable {
    case standard
    case uiTesting
    case realCaptureAcceptance
    case nativeV3MeshAcceptance
}

enum NativeV3MeshAcceptanceRequest: Equatable, Sendable {
    case none
    case participant(String)
    case invalid
}

struct NativeV3MeshAcceptanceReportingRequest: Equatable, Sendable {
    let runIdentifier: String
    let processLabel: String
    let runDirectory: URL

    var reportsDirectory: URL {
        runDirectory.appendingPathComponent("reports", isDirectory: true)
    }

    var terminationRequestURL: URL {
        runDirectory
            .appendingPathComponent("control", isDirectory: true)
            .appendingPathComponent("terminate.request", isDirectory: false)
    }
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
    case historyExports = "history-exports"
    case settings
    case settingsRecording = "settings-recording"
    case settingsLiveShare = "settings-live-share"
    case settingsExport = "settings-export"
    case settingsStorage = "settings-storage"
    case settingsPermissions = "settings-permissions"
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
    static let nativeV3MeshAcceptanceArgument = "--native-v3-mesh-acceptance"
    static let nativeV3MeshAcceptanceAcknowledgementArgument =
        "--acknowledge-native-v3-mesh-acceptance"
    static let nativeV3MeshParticipantArgumentPrefix =
        "--native-v3-mesh-participant="
    static let nativeV3MeshReportRunArgumentPrefix =
        "--native-v3-mesh-report-run="
    static let nativeV3MeshReportDirectoryArgumentPrefix =
        "--native-v3-mesh-report-directory="
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
    let nativeV3MeshAcceptanceRequest: NativeV3MeshAcceptanceRequest
    let nativeV3MeshAcceptanceReportingRequest:
        NativeV3MeshAcceptanceReportingRequest?

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
                uiScenarioRequest: .none,
                nativeV3MeshAcceptanceRequest: .none,
                nativeV3MeshAcceptanceReportingRequest: nil
            )
        }

        let isRealCaptureAcceptance = arguments.contains(realCaptureAcceptanceArgument)
        var nativeV3MeshAcceptanceRequest = resolveNativeV3MeshAcceptanceRequest(
            arguments: arguments,
            isRealCaptureAcceptance: isRealCaptureAcceptance
        )
        let nativeV3MeshAcceptanceReportingRequest:
            NativeV3MeshAcceptanceReportingRequest?
        do {
            nativeV3MeshAcceptanceReportingRequest =
                try resolveNativeV3MeshAcceptanceReportingRequest(
                    arguments: arguments,
                    temporaryDirectory: temporaryDirectory,
                    nativeV3MeshAcceptanceRequest:
                        nativeV3MeshAcceptanceRequest
                )
        } catch {
            nativeV3MeshAcceptanceRequest = .invalid
            nativeV3MeshAcceptanceReportingRequest = nil
        }
        let uiScenarioRequest = resolveUIScenarioRequest(
            arguments: arguments,
            isRealCaptureAcceptance: isRealCaptureAcceptance,
            nativeV3MeshAcceptanceRequest: nativeV3MeshAcceptanceRequest
        )
        let mode: AppLaunchMode
        if isRealCaptureAcceptance {
            mode = .realCaptureAcceptance
        } else if case .participant = nativeV3MeshAcceptanceRequest {
            mode = .nativeV3MeshAcceptance
        } else {
            mode = .uiTesting
        }
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
            uiScenarioRequest: uiScenarioRequest,
            nativeV3MeshAcceptanceRequest: nativeV3MeshAcceptanceRequest,
            nativeV3MeshAcceptanceReportingRequest:
                nativeV3MeshAcceptanceReportingRequest
        )
    }

    static func isolationIdentifier(for arguments: [String]) -> String {
        guard arguments.contains(uiTestingArgument) else { return "ui-testing" }
        let nativeV3MeshRequest = resolveNativeV3MeshAcceptanceRequest(
            arguments: arguments,
            isRealCaptureAcceptance: arguments.contains(realCaptureAcceptanceArgument)
        )
        switch nativeV3MeshRequest {
        case let .participant(identifier):
            return "native-v3-mesh-\(identifier)"
        case .invalid:
            return "native-v3-mesh-invalid"
        case .none:
            break
        }
        guard !arguments.contains(realCaptureAcceptanceArgument) else {
            if let identifier = realCaptureStateIdentifier(in: arguments) {
                return "real-capture-\(identifier)"
            }
            return "real-capture-acceptance"
        }

        switch resolveUIScenarioRequest(
            arguments: arguments,
            isRealCaptureAcceptance: false,
            nativeV3MeshAcceptanceRequest: .none
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
        isRealCaptureAcceptance: Bool,
        nativeV3MeshAcceptanceRequest: NativeV3MeshAcceptanceRequest
    ) -> DeterministicUIScenarioRequest {
        guard !isRealCaptureAcceptance,
              nativeV3MeshAcceptanceRequest == .none else {
            return .none
        }
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

    private static func resolveNativeV3MeshAcceptanceRequest(
        arguments: [String],
        isRealCaptureAcceptance: Bool
    ) -> NativeV3MeshAcceptanceRequest {
        let modeArguments = arguments.filter {
            $0 == nativeV3MeshAcceptanceArgument
        }
        let acknowledgementArguments = arguments.filter {
            $0 == nativeV3MeshAcceptanceAcknowledgementArgument
        }
        let participantArguments = arguments.filter {
            $0 == "--native-v3-mesh-participant"
                || $0.hasPrefix(nativeV3MeshParticipantArgumentPrefix)
        }
        let includesAnyMeshArgument = !modeArguments.isEmpty
            || !acknowledgementArguments.isEmpty
            || !participantArguments.isEmpty
        guard includesAnyMeshArgument else { return .none }
        guard !isRealCaptureAcceptance,
              arguments.filter({ $0 == uiTestingArgument }).count == 1,
              modeArguments.count == 1,
              acknowledgementArguments.count == 1,
              participantArguments.count == 1,
              participantArguments[0].hasPrefix(nativeV3MeshParticipantArgumentPrefix) else {
            return .invalid
        }

        let identifier = String(
            participantArguments[0].dropFirst(
                nativeV3MeshParticipantArgumentPrefix.count
            )
        )
        guard isValidNativeV3MeshParticipantIdentifier(identifier) else {
            return .invalid
        }
        return .participant(identifier)
    }

    private static func resolveNativeV3MeshAcceptanceReportingRequest(
        arguments: [String],
        temporaryDirectory: URL,
        nativeV3MeshAcceptanceRequest: NativeV3MeshAcceptanceRequest
    ) throws -> NativeV3MeshAcceptanceReportingRequest? {
        let runArguments = arguments.filter {
            $0 == "--native-v3-mesh-report-run"
                || $0.hasPrefix(nativeV3MeshReportRunArgumentPrefix)
        }
        let directoryArguments = arguments.filter {
            $0 == "--native-v3-mesh-report-directory"
                || $0.hasPrefix(
                    nativeV3MeshReportDirectoryArgumentPrefix
                )
        }
        guard !runArguments.isEmpty || !directoryArguments.isEmpty else {
            return nil
        }
        guard
            case let .participant(processLabel) =
                nativeV3MeshAcceptanceRequest,
            runArguments.count == 1,
            directoryArguments.count == 1,
            runArguments[0].hasPrefix(
                nativeV3MeshReportRunArgumentPrefix
            ),
            directoryArguments[0].hasPrefix(
                nativeV3MeshReportDirectoryArgumentPrefix
            )
        else {
            throw AppLaunchConfigurationError
                .invalidNativeV3MeshAcceptanceRequest
        }

        let runIdentifier = String(
            runArguments[0].dropFirst(
                nativeV3MeshReportRunArgumentPrefix.count
            )
        )
        let allowedRunCharacters = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
        )
        guard
            (16...128).contains(runIdentifier.count),
            runIdentifier.unicodeScalars.allSatisfy(
                allowedRunCharacters.contains
            )
        else {
            throw AppLaunchConfigurationError
                .invalidNativeV3MeshAcceptanceRequest
        }

        let rawDirectory = String(
            directoryArguments[0].dropFirst(
                nativeV3MeshReportDirectoryArgumentPrefix.count
            )
        )
        guard rawDirectory.hasPrefix("/") else {
            throw AppLaunchConfigurationError
                .invalidNativeV3MeshAcceptanceRequest
        }
        let directory = URL(
            fileURLWithPath: rawDirectory,
            isDirectory: true
        ).standardizedFileURL
        let temporaryRoot = temporaryDirectory.standardizedFileURL
        let rootPath = temporaryRoot.path.hasSuffix("/")
            ? temporaryRoot.path
            : temporaryRoot.path + "/"
        guard
            directory.path != temporaryRoot.path,
            directory.path.hasPrefix(rootPath)
        else {
            throw AppLaunchConfigurationError
                .invalidNativeV3MeshAcceptanceRequest
        }
        return NativeV3MeshAcceptanceReportingRequest(
            runIdentifier: runIdentifier,
            processLabel: processLabel,
            runDirectory: directory
        )
    }

    private static func isValidNativeV3MeshParticipantIdentifier(
        _ identifier: String
    ) -> Bool {
        let asciiLetters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        let asciiNumbers = CharacterSet(charactersIn: "0123456789")
        let allowed = asciiLetters
            .union(asciiNumbers)
            .union(CharacterSet(charactersIn: "-"))
        guard (1...32).contains(identifier.count),
              let first = identifier.unicodeScalars.first,
              let last = identifier.unicodeScalars.last,
              asciiLetters.contains(first),
              asciiLetters.union(asciiNumbers).contains(last) else {
            return false
        }
        return identifier.unicodeScalars.allSatisfy(allowed.contains)
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
    var completesOnboarding: Bool {
        mode == .realCaptureAcceptance || mode == .nativeV3MeshAcceptance
    }
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
        switch mode {
        case .nativeV3MeshAcceptance:
            false
        case .standard, .uiTesting, .realCaptureAcceptance:
            !realCaptureOverrides.preservesIsolatedState
        }
    }

    var nativeV3MeshAcceptanceParticipantIdentifier: String? {
        guard case let .participant(identifier) = nativeV3MeshAcceptanceRequest else {
            return nil
        }
        return identifier
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
        settings.exportConfiguration = .crisp
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
    case invalidNativeV3MeshAcceptanceRequest

    var errorDescription: String? {
        switch self {
        case let .unavailableDefaultsSuite(suiteName):
            "Clip could not create its isolated UI-test defaults suite \(suiteName)."
        case .invalidNativeV3MeshAcceptanceRequest:
            "Clip rejected an invalid native-v3 mesh acceptance launch request."
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
