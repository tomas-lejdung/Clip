import ClipCore
import ClipMedia
import CoreGraphics
import Foundation

struct PreparedCaptureTarget: Equatable, Sendable {
    let domainTarget: ClipCore.CaptureTarget
    let displayID: CGDirectDisplayID
    /// ScreenCaptureKit display-local source rectangle in points. Nil captures the display.
    let sourceRect: CGRect?
    let outputWidth: Int
    let outputHeight: Int
    /// When non-nil, native capture includes only this application's windows.
    let includedApplicationBundleIdentifier: String?

    init(
        domainTarget: ClipCore.CaptureTarget,
        displayID: CGDirectDisplayID,
        sourceRect: CGRect?,
        outputWidth: Int,
        outputHeight: Int,
        includedApplicationBundleIdentifier: String? = nil
    ) {
        self.domainTarget = domainTarget
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.includedApplicationBundleIdentifier = includedApplicationBundleIdentifier
    }
}

struct RecordingArtifact: Equatable, Sendable {
    let id: RecordingID
    let fileURL: URL
    let duration: TimeInterval
    let pixelSize: PixelSize
    let frameRate: CaptureFrameRate
    let audioConfiguration: AudioConfiguration
    let captureTarget: ClipCore.CaptureTarget
}

@MainActor
protocol CaptureServicing: AnyObject {
    /// StreamRecorder lifecycle events consumed by the application coordinator. Keeping the
    /// stream on the protocol prevents deterministic compositions from requiring the concrete
    /// ScreenCaptureKit-backed service.
    var events: AsyncStream<ScreenRecorderEvent> { get }
    func prepare(_ target: PreparedCaptureTarget) async throws
    func start(recordingID: RecordingID, settings: ClipSettings) async throws
    func pause() async throws
    func resume() async throws
    func finish() async throws -> RecordingArtifact
    func cancel() async
}

@MainActor
protocol AudioServicing: AnyObject {
    var defaultInputName: String? { get }
    func refreshDevices() async
}

@MainActor
protocol PermissionServicing: AnyObject {
    func currentStatus(for permission: ClipPermission) -> PermissionState
    func request(_ permission: ClipPermission) async -> PermissionState
}

enum ClipPermission: Hashable, Sendable {
    case screenRecording
    case microphone
    case systemAudio
}

enum PermissionState: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted
}

protocol ClockServicing: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

protocol FileSystemServicing: Sendable {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func removeItem(at url: URL) throws
    func writeAtomically(_ data: Data, to url: URL) throws
}

@MainActor
protocol PasteboardServicing: AnyObject {
    func placeFile(at url: URL) throws
}

@MainActor
protocol ShortcutServicing: AnyObject {
    var registrationError: String? { get }
    func registerShortcuts(
        _ configuration: ShortcutConfiguration,
        handler: @escaping @MainActor (GlobalShortcutAction) -> Void
    ) throws
    func unregisterShortcuts()
}

@MainActor
protocol DisplayServicing: AnyObject {
    func availableDisplays() async throws -> [ClipDisplay]
}

struct ClipDisplay: Equatable, Sendable, Identifiable {
    let id: CGDirectDisplayID
    /// Stable CoreGraphics display identity used in persisted capture targets.
    /// `id` is the live ScreenCaptureKit/CGDirectDisplayID for this session and
    /// may change after a display is disconnected and reconnected.
    let stableIdentifier: String
    let name: String
    let frame: CGRect
    let scaleFactor: CGFloat
}

@MainActor
protocol ExportServicing: AnyObject {
    func export(_ artifact: RecordingArtifact, to destination: URL) async throws -> URL
}

struct AppDependencies {
    let launchConfiguration: AppLaunchConfiguration
    let directories: ApplicationDirectories
    let defaults: UserDefaults
    let fileSystem: any FileSystemServicing
    let clock: any ClockServicing
    let settings: AppSettingsModel
    let permissions: any PermissionServicing
    let audio: any AudioServicing
    let pasteboard: any PasteboardServicing
    let displays: any DisplayServicing
    let capture: any CaptureServicing
    let exports: PreviewExportCoordinator
    let sharing: PreviewSharingService
    let history: ManagedHistoryRepository
    let shortcuts: GlobalShortcutService

    @MainActor
    static func live(
        launchConfiguration: AppLaunchConfiguration = .current()
    ) throws -> AppDependencies {
        let fileSystem = LiveFileSystem()
        let directories: ApplicationDirectories
        if let isolatedStateRoot = launchConfiguration.isolatedStateRoot {
            // The path is stable for each UI-test lane, but every app launch starts
            // empty. This makes reruns reproducible without requiring a test-only
            // environment variable or retaining data from a failed previous run.
            if launchConfiguration.resetsIsolatedStateOnLaunch,
               fileSystem.fileExists(at: isolatedStateRoot) {
                try fileSystem.removeItem(at: isolatedStateRoot)
            }
            directories = try ApplicationDirectories.resolve(
                applicationSupportRoot: isolatedStateRoot
                    .appendingPathComponent("Application Support", isDirectory: true),
                cachesRoot: isolatedStateRoot
                    .appendingPathComponent("Caches", isDirectory: true),
                bundleIdentifier: ApplicationDirectories.bundleIdentifier,
                fileSystem: fileSystem
            )
        } else {
            directories = try ApplicationDirectories.resolve(fileSystem: fileSystem)
        }
        let defaults = try launchConfiguration.makeUserDefaults()
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let settings = try AppSettingsModel(
            applicationSupportDirectory: directories.applicationSupport,
            homeDirectory: homeDirectory,
            initialSettings: launchConfiguration.initialSettings(
                homeDirectory: homeDirectory
            )
        )
        let permissions = LivePermissionService(defaults: defaults)
        let audio = LiveAudioService()
        let pasteboard = LivePasteboardService()
        let displays = LiveDisplayService()
        let capture = NativeCaptureService(
            recordingsDirectory: directories.recordings
        )
        let exports = PreviewExportCoordinator(exportsDirectory: directories.exports)
        let sharing = PreviewSharingService(
            exports: exports,
            pasteboard: pasteboard,
            settings: settings
        )
        let history = try ManagedHistoryRepository(
            applicationSupportDirectory: directories.applicationSupport,
            recordingsDirectory: directories.recordings
        )
        let shortcuts = GlobalShortcutService()
        return AppDependencies(
            launchConfiguration: launchConfiguration,
            directories: directories,
            defaults: defaults,
            fileSystem: fileSystem,
            clock: SystemClock(),
            settings: settings,
            permissions: permissions,
            audio: audio,
            pasteboard: pasteboard,
            displays: displays,
            capture: capture,
            exports: exports,
            sharing: sharing,
            history: history,
            shortcuts: shortcuts
        )
    }
}
