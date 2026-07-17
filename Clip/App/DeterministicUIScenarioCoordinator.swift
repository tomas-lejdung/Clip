import AppKit
import ClipCore
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
    private let statusBar: NSStatusBar
    private let popover = NSPopover()

    private var statusItem: NSStatusItem?
    private var windowController: NSWindowController?

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
        popover.contentSize = NSSize(width: 330, height: 620)
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

    private func presentWindow(rootView: AnyView, size: NSSize) {
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

        case .history:
            let index = HistoryDemoData.index()
            return wrapped(
                HistoryView(
                    viewModel: HistoryViewModel(
                        index: index,
                        actions: .demo(for: index)
                    )
                ),
                identifier: scenario.accessibilityIdentifier
            )

        case .settings:
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
                    externalActions: .inert
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
        case .history:
            NSSize(width: 860, height: 560)
        case .settings:
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
