import AppKit
import ClipCore
import ClipLiveShare
import SwiftUI

enum DeterministicUIScenarioCoordinatorError: LocalizedError, Equatable {
    case unavailableOutsideUITesting
    case missingIsolatedStateRoot

    var errorDescription: String? {
        switch self {
        case .unavailableOutsideUITesting:
            String(
                localized: "Deterministic UI scenarios are available only in isolated UI-test launches."
            )
        case .missingIsolatedStateRoot:
            String(
                localized: "The deterministic UI scenario did not receive an isolated state directory."
            )
        }
    }
}

/// Presents production SwiftUI surfaces using fixed, inert state. This coordinator deliberately
/// has no `AppDependencies`: constructing it cannot initialize ScreenCaptureKit, inspect live
/// displays, register global shortcuts/login items, touch the pasteboard, or query/request a
/// privacy permission.
@MainActor
final class DeterministicUIScenarioCoordinator {
    private let launchConfiguration: AppLaunchConfiguration
    private let directories: ApplicationDirectories
    private let settings: AppSettingsModel
    private let liveSharePreferences: LiveSharePreferencesModel
    private let liveShareIdentity: NativeDeviceIdentityRepository
    private let statusBar: NSStatusBar
    private let popover = NSPopover()

    private var statusItem: NSStatusItem?
    private var windowController: NSWindowController?
    private var initialScrollTask: Task<Void, Never>?

    init(
        launchConfiguration: AppLaunchConfiguration,
        statusBar: NSStatusBar = .system
    ) throws {
        guard launchConfiguration.launchesDeterministicUIScenario else {
            throw DeterministicUIScenarioCoordinatorError.unavailableOutsideUITesting
        }
        guard let isolatedStateRoot = launchConfiguration.isolatedStateRoot else {
            throw DeterministicUIScenarioCoordinatorError.missingIsolatedStateRoot
        }

        let fileSystem = LiveFileSystem()
        if fileSystem.fileExists(at: isolatedStateRoot) {
            try fileSystem.removeItem(at: isolatedStateRoot)
        }
        directories = try ApplicationDirectories.resolve(
            applicationSupportRoot: isolatedStateRoot
                .appendingPathComponent("Application Support", isDirectory: true),
            cachesRoot: isolatedStateRoot.appendingPathComponent("Caches", isDirectory: true),
            bundleIdentifier: ApplicationDirectories.bundleIdentifier,
            fileSystem: fileSystem
        )
        _ = try launchConfiguration.makeUserDefaults()

        let homeDirectory = isolatedStateRoot.appendingPathComponent("Home", isDirectory: true)
        var initialSettings = ClipSettings.defaults(homeDirectory: homeDirectory)
        initialSettings.launchAtLogin = false
        initialSettings.showInDock = false
        initialSettings.audio = .none
        settings = try AppSettingsModel(
            applicationSupportDirectory: directories.applicationSupport,
            homeDirectory: homeDirectory,
            initialSettings: initialSettings,
            directoryBookmarks: DeterministicDirectoryBookmarkService()
        )
        liveSharePreferences = try LiveSharePreferencesModel(
            applicationSupportDirectory: directories.applicationSupport
        )
        liveShareIdentity = NativeDeviceIdentityRepository(
            storage: try DeterministicNativeDeviceIdentityStorage()
        )
        self.launchConfiguration = launchConfiguration
        self.statusBar = statusBar
    }

    func start() {
        guard statusItem == nil, windowController == nil else { return }

        switch launchConfiguration.uiScenarioRequest {
        case .none:
            return
        case .invalid:
            presentWindow(
                rootView: wrapped(
                    DeterministicFailureScenarioView(),
                    identifier: "clip.uiScenario.invalid"
                ),
                size: NSSize(width: 480, height: 280)
            )
        case let .scenario(scenario):
            if scenario == .menuPopover {
                presentMenuPopover()
            } else {
                presentWindow(
                    rootView: content(for: scenario),
                    size: windowSize(for: scenario)
                )
            }
        }
    }

    func stop() {
        initialScrollTask?.cancel()
        initialScrollTask = nil
        popover.close()
        windowController?.close()
        windowController = nil
        if let statusItem {
            statusBar.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func presentMenuPopover() {
        let statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else {
            statusBar.removeStatusItem(statusItem)
            return
        }
        self.statusItem = statusItem

        let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Clip")
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel("Clip")
        button.setAccessibilityIdentifier("clip.uiScenario.statusItem")

        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = MenuBarPopoverView.contentSize
        popover.contentViewController = NSHostingController(
            rootView: wrapped(
                MenuBarPopoverView(
                    model: Self.menuModel(),
                    actions: Self.inertMenuActions
                ),
                identifier: DeterministicUIScenario.menuPopover.accessibilityIdentifier
            )
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func presentWindow(
        rootView: AnyView,
        size: NSSize,
        scrollsContentToBottom: Bool = false
    ) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clip"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)
        window.center()
        let windowController = NSWindowController(window: window)
        self.windowController = windowController
        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()

        guard scrollsContentToBottom else { return }
        initialScrollTask = Task { @MainActor [weak self, weak window] in
            // SwiftUI installs the lazy scroll document over the next two main-actor turns.
            // Moving its clip view is deterministic and does not synthesize input or move the
            // user's pointer.
            await Task.yield()
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  let window,
                  self.windowController?.window === window,
                  let contentView = window.contentView else { return }
            contentView.layoutSubtreeIfNeeded()
            self.scrollLargestScrollViewToBottom(in: contentView)
            contentView.layoutSubtreeIfNeeded()
            contentView.displayIfNeeded()
        }
    }

    private func scrollLargestScrollViewToBottom(in rootView: NSView) {
        guard let scrollView = allScrollViews(in: rootView).max(by: {
            verticalScrollRange(of: $0) < verticalScrollRange(of: $1)
        }),
        let documentView = scrollView.documentView else { return }

        let clipView = scrollView.contentView
        let documentBounds = documentView.bounds
        let bottomOffset = documentView.isFlipped
            ? NSMaxY(documentBounds) - clipView.bounds.height
            : NSMinY(documentBounds)
        let clampedOffset = max(
            NSMinY(documentBounds),
            min(bottomOffset, NSMaxY(documentBounds) - clipView.bounds.height)
        )
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: clampedOffset))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func allScrollViews(in view: NSView) -> [NSScrollView] {
        var result = view is NSScrollView ? [view as! NSScrollView] : []
        for child in view.subviews {
            result.append(contentsOf: allScrollViews(in: child))
        }
        return result
    }

    private func verticalScrollRange(of scrollView: NSScrollView) -> CGFloat {
        guard let documentView = scrollView.documentView else { return 0 }
        return max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
    }

    private func content(for scenario: DeterministicUIScenario) -> AnyView {
        switch scenario {
        case .onboarding:
            return wrapped(
                OnboardingView(
                    viewModel: OnboardingViewModel(
                        initialStep: .welcome,
                        currentScreenPermission: { .notDetermined },
                        requestScreenPermission: { .notDetermined },
                        completion: {}
                    ),
                    settings: settings
                ),
                identifier: scenario.accessibilityIdentifier
            )

        case .menuPopover:
            // Menu is hosted in a real status-item popover by `presentMenuPopover()`.
            return wrapped(EmptyView(), identifier: scenario.accessibilityIdentifier)

        case .permissionsDenied:
            return wrapped(
                OnboardingView(
                    viewModel: OnboardingViewModel(
                        initialStep: .screenRecording,
                        currentScreenPermission: { .denied },
                        requestScreenPermission: { .denied },
                        completion: {}
                    ),
                    settings: settings
                ),
                identifier: scenario.accessibilityIdentifier
            )

        case .recording:
            return wrapped(
                RecordingStatusView(model: .demo(.demoRecording)),
                identifier: scenario.accessibilityIdentifier
            )

        case .paused:
            return wrapped(
                RecordingStatusView(model: .demo(.demoPaused)),
                identifier: scenario.accessibilityIdentifier
            )

        case .preview:
            return wrapped(
                PreviewView(
                    viewModel: PreviewViewModel(
                        recording: .demo(),
                        actions: .demo
                    )
                ),
                identifier: scenario.accessibilityIdentifier
            )

        case .history, .historyExports:
            let index = HistoryDemoData.index()
            let exports = HistoryDemoData.exports()
            return wrapped(
                HistoryView(
                    viewModel: HistoryViewModel(
                        index: index,
                        exportInventory: exports,
                        actions: .demo(for: index, exports: exports)
                    ),
                    initialTab: scenario == .historyExports ? .exports : .recordings
                ),
                identifier: scenario.accessibilityIdentifier
            )

        case .settings,
             .settingsRecording,
             .settingsLiveShare,
             .settingsExport,
             .settingsStorage,
             .settingsPermissions:
            let permissions = DeterministicPermissionService(statuses: [
                .screenRecording: .granted,
                .microphone: .denied,
                .systemAudio: .restricted,
            ])
            let audio = DeterministicAudioService(defaultInputName: "Studio Microphone")
            let shortcuts = GlobalShortcutService(
                registrar: DeterministicGlobalHotKeyRegistrar()
            )
            let storageSnapshot = SettingsStorageSnapshot(
                recordingCount: 3,
                indexedMasterByteCount: 13_300_000,
                directoryMP4ByteCount: 14_500_000,
                cleanupCandidateByteCount: 1_200_000,
                untrackedMP4ByteCount: 400_000
            )
            return wrapped(
                SettingsView(
                    model: settings,
                    liveSharePreferences: liveSharePreferences,
                    liveShareIdentity: liveShareIdentity,
                    shortcuts: shortcuts,
                    permissions: permissions,
                    audio: audio,
                    historyDirectory: directories.recordings,
                    storageActions: SettingsStorageActions(
                        loadUsage: { storageSnapshot },
                        clearHistory: {
                            SettingsStorageSnapshot(
                                recordingCount: 0,
                                indexedMasterByteCount: 0,
                                directoryMP4ByteCount: 400_000,
                                cleanupCandidateByteCount: 0,
                                untrackedMP4ByteCount: 400_000
                            )
                        },
                        revealHistory: {}
                    ),
                    externalActions: .inert,
                    initialTab: scenario.settingsTab ?? .general
                ),
                identifier: scenario.accessibilityIdentifier
            )

        case .failure:
            return wrapped(
                DeterministicFailureScenarioView(),
                identifier: scenario.accessibilityIdentifier
            )
        }
    }

    private func windowSize(for scenario: DeterministicUIScenario) -> NSSize {
        switch scenario {
        case .onboarding, .permissionsDenied:
            NSSize(width: 610, height: 440)
        case .recording, .paused:
            NSSize(width: 340, height: 360)
        case .preview:
            NSSize(width: 820, height: 650)
        case .history, .historyExports:
            NSSize(width: 860, height: 560)
        case .settings,
             .settingsRecording,
             .settingsLiveShare,
             .settingsExport,
             .settingsStorage,
             .settingsPermissions:
            SettingsView.contentSize
        case .failure, .menuPopover:
            NSSize(width: 480, height: 280)
        }
    }

    private func wrapped<Content: View>(
        _ content: Content,
        identifier: String
    ) -> AnyView {
        AnyView(
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
        )
    }

    private static func menuModel() -> MenuBarPopoverModel {
        MenuBarPopoverModel(
            displays: [
                MenuBarDisplayRow(
                    id: 1,
                    name: "Built-in Display",
                    pixelWidth: 3_024,
                    pixelHeight: 1_964
                ),
                MenuBarDisplayRow(
                    id: 2,
                    name: "Studio Display",
                    pixelWidth: 5_120,
                    pixelHeight: 2_880
                ),
            ],
            preparedDisplayID: 2,
            microphone: MenuBarAudioState(
                isEnabled: false,
                isAvailable: true,
                detail: "Studio Microphone"
            ),
            systemAudio: MenuBarAudioState(
                isEnabled: false,
                isAvailable: false,
                detail: "Permission denied"
            ),
            showClickHighlights: true,
            recentRecordings: [
                MenuBarRecentRecordingRow(
                    id: RecordingID(
                        UUID(uuidString: "A2C47771-A127-4873-8FD7-F47553283C80")!
                    ),
                    filename: "clip-20260717-104218",
                    byteCount: 3_800_000
                ),
                MenuBarRecentRecordingRow(
                    id: RecordingID(
                        UUID(uuidString: "B07D5DF4-CE93-4E76-A64C-6F7F8241789C")!
                    ),
                    filename: "dashboard-filters",
                    byteCount: 7_100_000
                ),
            ],
            isLastAreaAvailable: true,
            isFullscreenAvailable: true
        )
    }

    private static let inertMenuActions = MenuBarActions(
        captureArea: {},
        lastArea: {},
        fullscreen: {},
        captureApplication: {},
        prepareDisplay: { _ in },
        recordPreparedDisplay: { _ in },
        setMicrophoneEnabled: { _ in },
        setSystemAudioEnabled: { _ in },
        setClickHighlightsEnabled: { _ in },
        openRecentRecording: { _ in },
        openHistory: {},
        openSettings: {},
        quit: {}
    )
}

private extension DeterministicUIScenario {
    var accessibilityIdentifier: String {
        "clip.uiScenario.\(rawValue)"
    }

    var settingsTab: SettingsTab? {
        switch self {
        case .settings:
            .general
        case .settingsRecording:
            .recording
        case .settingsLiveShare:
            .liveShare
        case .settingsExport:
            .export
        case .settingsStorage:
            .storage
        case .settingsPermissions:
            .permissions
        case .onboarding,
             .menuPopover,
             .permissionsDenied,
             .recording,
             .paused,
             .preview,
             .history,
             .historyExports,
             .failure:
            nil
        }
    }
}

private struct DeterministicFailureScenarioView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Clip could not start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(UserFacingErrorPresentation.genericMessage)
                .accessibilityIdentifier("clip.failure.message")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("clip.failure")
    }
}

private final class DeterministicNativeDeviceIdentityStorage:
    NativeDeviceIdentitySecureStorage, @unchecked Sendable
{
    private struct StoredIdentityFixture: Encodable {
        let version: Int
        let signingPrivateKey: Data
    }

    private let lock = NSLock()
    private var data: Data?

    init() throws {
        data = try JSONEncoder().encode(StoredIdentityFixture(
            version: 3,
            signingPrivateKey: deterministicPrivateKey(seed: 1)
        ))
    }

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func insert(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        data = nil
    }
}

private func deterministicPrivateKey(seed: UInt8) -> Data {
    precondition(seed > 0)
    var data = Data(repeating: 0, count: 32)
    data[data.index(before: data.endIndex)] = seed
    return data
}

@MainActor
private final class DeterministicPermissionService: PermissionServicing {
    private var statuses: [ClipPermission: PermissionState]

    init(statuses: [ClipPermission: PermissionState]) {
        self.statuses = statuses
    }

    func currentStatus(for permission: ClipPermission) -> PermissionState {
        statuses[permission] ?? .notDetermined
    }

    func request(_ permission: ClipPermission) async -> PermissionState {
        currentStatus(for: permission)
    }
}

@MainActor
private final class DeterministicAudioService: AudioServicing {
    let defaultInputName: String?

    init(defaultInputName: String?) {
        self.defaultInputName = defaultInputName
    }

    func refreshDevices() async {}
}

@MainActor
private final class DeterministicDirectoryBookmarkService: DirectoryBookmarkServicing {
    func isDirectory(_ url: URL) -> Bool {
        url.isFileURL
    }

    func makeSecurityScopedBookmark(for url: URL) throws -> Data {
        Data(url.path(percentEncoded: false).utf8)
    }

    func resolveSecurityScopedBookmark(_ data: Data) throws -> ResolvedDirectoryBookmark {
        let path = String(decoding: data, as: UTF8.self)
        return ResolvedDirectoryBookmark(
            url: URL(fileURLWithPath: path, isDirectory: true),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool { true }
    nonisolated func stopAccessing(_ url: URL) {}
}

@MainActor
private final class DeterministicGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    func replace(
        registrations: [GlobalHotKeyRegistration],
        handler: @escaping @MainActor (GlobalShortcutAction) -> Void
    ) throws {}

    func unregisterAll() {}
}
