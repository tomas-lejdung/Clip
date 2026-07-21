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
    private let liveSharePreferences: LiveSharePreferencesModel
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
                    size: windowSize(for: scenario),
                    scrollsContentToBottom: scenario == .liveShareLiveBottom
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

        case .liveShareReady,
             .liveShareLive,
             .liveShareLiveBottom,
             .liveShareReconnecting,
             .liveShareFailed:
            guard let snapshot = DeterministicLiveShareDemo.snapshot(for: scenario) else {
                return wrapped(
                    DeterministicFailureScenarioView(),
                    identifier: scenario.accessibilityIdentifier
                )
            }
            return wrapped(
                LiveSharePopoverView(
                    model: LiveSharePresentationModel(
                        snapshot: snapshot,
                        actions: .noOp
                    ),
                    initiallyExpandsStatistics: scenario == .liveShareLiveBottom
                ),
                identifier: scenario.accessibilityIdentifier
            )

        case .liveShareOverlays:
            return wrapped(
                DeterministicLiveShareOverlayScenarioView(),
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
        case .liveShareReady,
             .liveShareLive,
             .liveShareLiveBottom,
             .liveShareReconnecting,
             .liveShareFailed:
            LiveSharePopoverView.contentSize
        case .liveShareOverlays:
            NSSize(width: 700, height: 430)
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
             .liveShareReady,
             .liveShareLive,
             .liveShareLiveBottom,
             .liveShareReconnecting,
             .liveShareFailed,
             .liveShareOverlays,
             .failure:
            nil
        }
    }
}

/// Permission-free, fixed Live Share data used by UI-source and visual regression tests.
/// Keeping it next to the deterministic coordinator makes it impossible for a scenario launch
/// to accidentally instantiate signaling, ScreenCaptureKit, WebRTC, or a permission service.
enum DeterministicLiveShareDemo {
    static func snapshot(for scenario: DeterministicUIScenario) -> LiveShareViewSnapshot? {
        switch scenario {
        case .liveShareReady:
            readySnapshot()
        case .liveShareLive, .liveShareLiveBottom:
            liveSnapshot()
        case .liveShareReconnecting:
            reconnectingSnapshot()
        case .liveShareFailed:
            failedSnapshot()
        default:
            nil
        }
    }

    private static let room = LiveShareRoomViewSnapshot(
        viewerURL: URL(string: "https://clip.tineestudio.se/CRISP-FROG-042#v=1&key=fixture")!,
        roomCode: "CRISP-FROG-042"
    )

    private static let availableWindows = [
        LiveShareAvailableWindowViewSnapshot(
            id: "window-slack",
            applicationName: "Slack",
            windowTitle: "#clip-development",
            applicationPath: nil
        ),
        LiveShareAvailableWindowViewSnapshot(
            id: "window-terminal",
            applicationName: "Terminal",
            windowTitle: "Clip — swift test",
            applicationPath: nil
        ),
        LiveShareAvailableWindowViewSnapshot(
            id: "window-notes",
            applicationName: "Notes",
            windowTitle: "Release checklist",
            applicationPath: nil
        ),
    ]

    private static let sources = [
        LiveShareSourceViewSnapshot(
            id: "window-safari",
            slotIndex: 0,
            applicationName: "Safari",
            windowTitle: "Clip pull request",
            status: .live,
            isFocused: true
        ),
        LiveShareSourceViewSnapshot(
            id: "window-xcode",
            slotIndex: 1,
            applicationName: "Xcode",
            windowTitle: "LiveShareCoordinator.swift",
            status: .starting
        ),
        LiveShareSourceViewSnapshot(
            id: "window-keynote",
            slotIndex: 2,
            applicationName: "Keynote",
            windowTitle: "Product roadmap",
            status: .live
        ),
    ]

    private static let slots = [
        LiveShareSourceSlotViewSnapshot(index: 0, state: .live),
        LiveShareSourceSlotViewSnapshot(index: 1, state: .starting),
        LiveShareSourceSlotViewSnapshot(index: 2, state: .live),
        LiveShareSourceSlotViewSnapshot(index: 3, state: .empty),
    ]

    private static let viewers = [
        LiveShareViewerViewSnapshot(
            id: "viewer-4F8A",
            connection: .peerToPeer,
            connectedDuration: 84
        ),
        LiveShareViewerViewSnapshot(
            id: "viewer-92D1",
            connection: .turn,
            connectedDuration: 37
        ),
        LiveShareViewerViewSnapshot(
            id: "viewer-A071",
            connection: .connecting,
            connectedDuration: nil
        ),
    ]

    private static let statistics = LiveShareStatisticsViewSnapshot(
        uptime: 94,
        streams: [
            LiveShareStreamStatisticsViewSnapshot(
                id: "stream-safari",
                name: "Safari · Clip pull request",
                width: 1_920,
                height: 1_080,
                deliveredFramesPerSecond: 29.9,
                bitsPerSecond: 5_800_000,
                bytesSent: 58_400_000,
                isFocused: true
            ),
            LiveShareStreamStatisticsViewSnapshot(
                id: "stream-xcode",
                name: "Xcode · LiveShareCoordinator.swift",
                width: 1_728,
                height: 1_117,
                deliveredFramesPerSecond: 27.8,
                bitsPerSecond: 4_200_000,
                bytesSent: 32_100_000
            ),
            LiveShareStreamStatisticsViewSnapshot(
                id: "stream-keynote",
                name: "Keynote · Product roadmap",
                width: 1_600,
                height: 900,
                deliveredFramesPerSecond: 30,
                bitsPerSecond: 3_600_000,
                bytesSent: 27_900_000
            ),
        ]
    )

    private static func readySnapshot() -> LiveShareViewSnapshot {
        LiveShareViewSnapshot(
            phase: .ready,
            room: room,
            accessCodeEnabled: false,
            sources: [],
            fullscreen: .init(isOn: false, displayName: "Studio Display"),
            canShareFocusedWindow: true,
            focusedWindowDescription: "Safari · Clip pull request",
            availableWindows: availableWindows,
            canAddWindow: true,
            settings: .init(
                quality: .veryHigh,
                frameRate: .thirty,
                codec: .init(codec: .h264, acceleration: .hardware),
                prioritizeFocusedWindow: true,
                mode: .quality,
                autoShareFocusedWindows: false
            )
        )
    }

    private static func liveSnapshot() -> LiveShareViewSnapshot {
        LiveShareViewSnapshot(
            phase: .live(elapsedSeconds: 94),
            room: room,
            accessCodeEnabled: true,
            accessCode: "orbit-mint-72",
            sources: sources,
            slots: slots,
            fullscreen: .init(isOn: false, displayName: "Studio Display"),
            canShareFocusedWindow: true,
            focusedWindowDescription: "Safari · Clip pull request",
            availableWindows: availableWindows,
            canAddWindow: true,
            settings: .init(
                quality: .ultra,
                frameRate: .thirty,
                codec: .init(codec: .h264, acceleration: .hardware),
                prioritizeFocusedWindow: true,
                mode: .quality,
                autoShareFocusedWindows: false
            ),
            viewers: viewers,
            statistics: statistics
        )
    }

    private static func reconnectingSnapshot() -> LiveShareViewSnapshot {
        LiveShareViewSnapshot(
            phase: .reconnecting(attempt: 2, maximumAttempts: 5),
            room: room,
            accessCodeEnabled: true,
            accessCode: "orbit-mint-72",
            canChangeAccessCode: false,
            sources: sources.map {
                LiveShareSourceViewSnapshot(
                    id: $0.id,
                    slotIndex: $0.slotIndex,
                    applicationName: $0.applicationName,
                    windowTitle: $0.windowTitle,
                    status: .starting,
                    isFocused: $0.isFocused,
                    canStop: false
                )
            },
            slots: slots.map {
                LiveShareSourceSlotViewSnapshot(
                    index: $0.index,
                    state: $0.state == .empty ? .empty : .starting
                )
            },
            fullscreen: .init(
                isOn: false,
                displayName: "Studio Display",
                isEnabled: false,
                detail: "Fullscreen controls resume after reconnecting."
            ),
            canShareFocusedWindow: false,
            focusedWindowDescription: "Safari · Clip pull request",
            availableWindows: availableWindows,
            canAddWindow: false,
            settings: disabledSettings(),
            viewers: [
                .init(id: "viewer-4F8A", connection: .connecting, connectedDuration: nil),
                .init(id: "viewer-92D1", connection: .disconnected, connectedDuration: nil),
            ],
            statistics: statistics
        )
    }

    private static func failedSnapshot() -> LiveShareViewSnapshot {
        LiveShareViewSnapshot(
            phase: .failed(message: "The signaling service is unavailable."),
            room: room,
            accessCodeEnabled: true,
            accessCode: "orbit-mint-72",
            canChangeAccessCode: false,
            accessCodeError: "The access code could not be refreshed while offline.",
            sources: [
                LiveShareSourceViewSnapshot(
                    id: "window-safari",
                    slotIndex: 0,
                    applicationName: "Safari",
                    windowTitle: "Clip pull request",
                    status: .failed,
                    isFocused: true,
                    canStop: false
                ),
            ],
            slots: [.init(index: 0, state: .starting)],
            fullscreen: .init(
                isOn: false,
                displayName: "Studio Display",
                isEnabled: false
            ),
            focusedWindowDescription: "Safari · Clip pull request",
            availableWindows: availableWindows,
            settings: disabledSettings(),
            viewers: [
                .init(id: "viewer-4F8A", connection: .disconnected, connectedDuration: nil),
            ],
            statistics: statistics
        )
    }

    private static func disabledSettings() -> LiveShareSettingsViewSnapshot {
        LiveShareSettingsViewSnapshot(
            quality: .ultra,
            frameRate: .thirty,
            codec: .init(codec: .h264, acceleration: .hardware),
            prioritizeFocusedWindow: true,
            mode: .quality,
            autoShareFocusedWindows: false,
            canChangeQuality: false,
            canChangeFrameRate: false,
            canChangeCodec: false,
            canChangePrioritizeFocusedWindow: false,
            canChangeMode: false,
            canChangeAutoShare: false
        )
    }
}

@MainActor
private struct DeterministicLiveShareOverlayScenarioView: View {
    private let activeHUD = LiveShareStatusHUDSnapshot(
        slots: [
            .init(index: 0, state: .live),
            .init(index: 1, state: .starting),
            .init(index: 2, state: .live),
        ],
        connectedViewerCount: 2,
        fullscreen: .init(isOn: false, displayName: "Studio Display")
    )

    private let fullscreenHUD = LiveShareStatusHUDSnapshot(
        slots: [.init(index: 0, state: .live)],
        connectedViewerCount: 3,
        fullscreen: .init(isOn: true, displayName: "Studio Display")
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Live Share overlays")
                .font(.title2.weight(.semibold))

            HStack(alignment: .top, spacing: 54) {
                preview(title: "Focused window · available") {
                    FocusedWindowShareOverlayView(
                        snapshot: .init(
                            sourceID: "window-safari",
                            applicationName: "Safari",
                            windowTitle: "Clip pull request",
                            state: .shareable
                        ),
                        side: .left,
                        primaryAction: {},
                        toggleSide: {}
                    )
                }
                .accessibilityIdentifier("clip.liveShare.fixture.focused.shareable")

                preview(title: "Focused window · live") {
                    FocusedWindowShareOverlayView(
                        snapshot: .init(
                            sourceID: "window-xcode",
                            applicationName: "Xcode",
                            windowTitle: "LiveShareCoordinator.swift",
                            state: .live
                        ),
                        side: .right,
                        primaryAction: {},
                        toggleSide: {}
                    )
                }
                .accessibilityIdentifier("clip.liveShare.fixture.focused.live")
            }

            HStack(alignment: .top, spacing: 48) {
                preview(title: "Window sources") {
                    LiveShareStatusHUDView(snapshot: activeHUD, actions: .init())
                }
                .accessibilityIdentifier("clip.liveShare.fixture.hud.windows")

                preview(title: "Fullscreen") {
                    LiveShareStatusHUDView(snapshot: fullscreenHUD, actions: .init())
                }
                .accessibilityIdentifier("clip.liveShare.fixture.hud.fullscreen")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.liveShare.fixture.overlays")
    }

    private func preview<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
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
