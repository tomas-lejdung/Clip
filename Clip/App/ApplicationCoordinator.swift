import AppKit
import ClipCore
import ClipMedia
import Combine
import SwiftUI

struct UserFacingErrorDetails: Equatable, Sendable {
    let message: String
    let technicalDescription: String
}

/// Keeps implementation details in diagnostics while presenting only messages
/// deliberately authored for people using Clip. System and media-framework
/// errors do not opt into `LocalizedError`, so their often technical text is
/// replaced with one concise recovery message.
enum UserFacingErrorPresentation {
    static let genericMessage = String(
        localized: "Clip couldn’t complete this action. Try again."
    )

    static func details(for error: any Error) -> UserFacingErrorDetails {
        let technicalDescription = (error as? any TechnicalErrorDescriptionProviding)?
            .technicalDescriptionForLogging ?? error.localizedDescription
        let intentionalDescription = (error as? any LocalizedError)?
            .errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = if let intentionalDescription, !intentionalDescription.isEmpty {
            intentionalDescription
        } else {
            genericMessage
        }
        return UserFacingErrorDetails(
            message: message,
            technicalDescription: technicalDescription
        )
    }
}

private protocol TechnicalErrorDescriptionProviding {
    var technicalDescriptionForLogging: String { get }
}

enum ShareCompletionFormatting {
    static func copiedStatus(for outputURL: URL) -> String {
        copiedStatus(byteCount: fileByteCount(at: outputURL))
    }

    static func copiedStatus(byteCount: Int64?) -> String {
        let title = String(localized: "✓ Video copied")
        guard let byteCount, byteCount >= 0 else { return title }
        return "\(title) — \(formattedByteCount(byteCount))"
    }

    static func fileByteCount(at url: URL) -> Int64? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            return nil
        }
        return Int64(fileSize)
    }

    static func formattedByteCount(_ byteCount: Int64) -> String {
        MenuBarFormatting.byteCount(byteCount)
    }
}

enum CaptureSelectionPresentationPolicy {
    static func permitsSelection(
        recordingPhase: RecordingPhase,
        hasVisiblePreview: Bool
    ) -> Bool {
        _ = hasVisiblePreview
        return [.idle, .canceled, .failed, .preview].contains(recordingPhase)
    }
}

enum RecordingTerminationPlan: Equatable {
    /// Finalization is attempted even when the coordinator has not consumed
    /// the recorder's first-frame event yet. The capture service remains the
    /// authority: its writer rejects and removes a genuinely empty output.
    case finalize(markFrameForServiceAuthoritativeAttempt: Bool)
    case cancelSelectionOrCountdown
    case noAction
}

enum RecordingTerminationPolicy {
    static func plan(
        recordingPhase: RecordingPhase,
        hasObservedVideoFrame: Bool
    ) -> RecordingTerminationPlan {
        switch recordingPhase {
        case .recording:
            .finalize(
                markFrameForServiceAuthoritativeAttempt: !hasObservedVideoFrame
            )
        case .paused:
            .finalize(markFrameForServiceAuthoritativeAttempt: false)
        case .selecting, .countdown:
            .cancelSelectionOrCountdown
        default:
            .noAction
        }
    }
}

enum RecordingCompletionFailureDisposition: Equatable {
    case recordingFailed
    case recordingSavedPreviewDeferred
}

enum RecordingCompletionPolicy {
    static func failureDisposition(
        recordingWasImported: Bool
    ) -> RecordingCompletionFailureDisposition {
        recordingWasImported ? .recordingSavedPreviewDeferred : .recordingFailed
    }
}

@MainActor
enum PeriodicStorageMaintenanceLoop {
    static let interval: Duration = .seconds(60 * 60)

    static func run(
        clock: any ClockServicing,
        operation: @escaping @MainActor () async throws -> Void,
        reportFailure: @escaping @MainActor (any Error) -> Void
    ) async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try await operation()
            } catch {
                reportFailure(error)
            }
        }
    }
}

@MainActor
final class ApplicationCoordinator: NSObject, NSPopoverDelegate, ApplicationTerminationHandling {
    private let dependencies: AppDependencies
    private let statusBar: NSStatusBar
    private let popover = NSPopover()
    private let lastAreaStore: LastAreaStore
    private let applicationBehavior = ApplicationBehaviorService()
    private let menuBarModel = MenuBarPopoverModel()
    private let onboardingStore: OnboardingStore
    private let regionOutlineController = CaptureRegionOutlineController()
    private let applicationUpdater: any ApplicationUpdateServicing

    private var statusItem: NSStatusItem?
    private var selectionController: CaptureSelectionController?
    private var applicationSelectionController: ApplicationCaptureSelectionController?
    private var countdownController: SilentCountdownController?
    private var recordingPresentationModel: RecordingPresentationModel?
    private var settingsWindowController: NSWindowController?
    private var previewWindowController: NSWindowController?
    private var previewWindowDelegate: PreviewWindowDelegate?
    private var previewViewModel: PreviewViewModel?
    private var previewLifecycleContext: PreviewLifecycleContext?
    private var historyWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?
    private var liveShareCoordinator: LiveShareCoordinator?
    private var isStartingLiveShare = false
    private var isPreparingCapture = false
    private var startupTask: Task<Void, Never>?
    private var captureEventTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var settingsObservation: AnyCancellable?
    private var recordingState = RecordingStateMachine()
    private var activeRecordingID: RecordingID?
    private var activeCaptureSettings: ClipSettings?
    private var unavailableRecordingAudioSources: Set<CapturedAudioSource> = []
    private var recordingAudioNotice: String?
    private var sessionSettingsByRecordingID: [RecordingID: ClipSettings] = [:]
    private var pendingRetake: PendingRetake?
    private var isPreparingForTermination = false

    init(
        dependencies: AppDependencies,
        applicationUpdater: any ApplicationUpdateServicing,
        statusBar: NSStatusBar = .system
    ) {
        self.dependencies = dependencies
        self.applicationUpdater = applicationUpdater
        self.statusBar = statusBar
        lastAreaStore = LastAreaStore(defaults: dependencies.defaults)
        onboardingStore = OnboardingStore(defaults: dependencies.defaults)
        super.init()
        if dependencies.launchConfiguration.completesOnboarding {
            onboardingStore.markCompleted()
        }
    }

    func start() {
        guard statusItem == nil, !isPreparingForTermination else { return }
        installStatusItem()
        statusItem?.button?.isEnabled = false
        monitorCaptureEvents()

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { startupTask = nil }
            await dependencies.settings.load()
            guard !Task.isCancelled, !isPreparingForTermination else { return }
            await dependencies.liveSharePreferences.load()
            guard !Task.isCancelled, !isPreparingForTermination else { return }
            await dependencies.audio.refreshDevices()
            guard !Task.isCancelled, !isPreparingForTermination else { return }
            installIdlePopover()
            observeSettings()
            await applySettings(dependencies.settings.settings)
            guard !Task.isCancelled, !isPreparingForTermination else { return }
            statusItem?.button?.isEnabled = true
            do {
                let recovery = try await dependencies.history.recoverInterruptedRecordings()
                for recovered in recovery.recovered {
                    sessionSettingsByRecordingID[recovered.item.id] = recovered.settings
                }
                for failure in recovery.retainedFailures {
                    ClipLog.storage.error(
                        "Interrupted recording retained but could not be recovered at \(failure.fileURL.path, privacy: .private): \(failure.reason, privacy: .public)"
                    )
                }
                _ = try await dependencies.history.reconcile()
                _ = try await dependencies.history.applyRetentionCleanup(
                    policy: dependencies.settings.settings.historyRetention
                )
                _ = try await dependencies.exports.removeStaleExports(
                    olderThan: dependencies.clock.now.addingTimeInterval(
                        -PreviewExportCoordinator.staleExportLifetime
                    )
                )
                _ = try await dependencies.history.removeStaleTransactionArtifacts(
                    olderThan: dependencies.clock.now.addingTimeInterval(
                        -ManagedHistoryRepository.staleTransactionArtifactLifetime
                    )
                )
            } catch {
                ClipLog.storage.error(
                    "History startup maintenance failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            guard !Task.isCancelled, !isPreparingForTermination else { return }
            await refreshMenuBarModel()
            presentOnboardingIfNeeded()
            startMaintenanceLoop()
        }
    }

    func stop() {
        stop(preservingLiveShareForTermination: false)
    }

    private func stop(preservingLiveShareForTermination: Bool) {
        if preservingLiveShareForTermination {
            liveShareCoordinator?.hideForApplicationTermination()
        } else {
            liveShareCoordinator?.cancelForApplicationStop()
            liveShareCoordinator = nil
        }
        startupTask?.cancel()
        startupTask = nil
        captureEventTask?.cancel()
        captureEventTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        settingsObservation?.cancel()
        settingsObservation = nil
        dependencies.shortcuts.unregisterShortcuts()
        countdownController?.stopWithoutCallback()
        countdownController = nil
        selectionController?.dismissWithoutCallback()
        selectionController = nil
        applicationSelectionController?.dismissWithoutCallback()
        applicationSelectionController = nil
        regionOutlineController.hide()
        recordingPresentationModel?.cancelPendingAction()
        recordingPresentationModel = nil
        settingsWindowController?.close()
        settingsWindowController = nil
        onboardingWindowController?.close()
        onboardingWindowController = nil
        previewWindowDelegate?.allowClose = true
        previewWindowController?.window?.orderOut(nil)
        previewWindowController?.close()
        previewWindowController = nil
        previewWindowDelegate = nil
        historyWindowController?.close()
        historyWindowController = nil
        popover.close()
        if let statusItem {
            statusBar.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    func closeForTermination() {
        isPreparingForTermination = true
        stop(preservingLiveShareForTermination: true)
    }

    /// Flushes user-visible state before AppKit allows process termination.
    /// An active writer gets the opportunity to finalize even when its
    /// first-frame UI event is still queued; the service discards a genuinely
    /// empty output. Selection/countdown captures are canceled, and an
    /// in-progress Retake is canceled so its original draft stays authoritative.
    func prepareForTermination() async {
        isPreparingForTermination = true
        maintenanceTask?.cancel()
        maintenanceTask = nil

        if let liveShareCoordinator {
            await liveShareCoordinator.endForApplicationTermination()
            self.liveShareCoordinator = nil
        }

        if pendingRetake != nil, recordingState.phase == .finishing {
            // The in-flight replacement may still finish into History, but the
            // original Preview remains authoritative when Quit interrupts the
            // Retake handoff.
            cancelPendingRetake()
        }

        if pendingRetake != nil, recordingState.phase != .finishing {
            switch recordingState.phase {
            case .recording, .paused:
                await cancelRecording()
            case .selecting, .countdown:
                cancelSelectionOrCountdown()
            default:
                cancelPendingRetake()
            }
        } else {
            switch RecordingTerminationPolicy.plan(
                recordingPhase: recordingState.phase,
                hasObservedVideoFrame: recordingState.timeline.hasFrames
            ) {
            case let .finalize(markFrameForServiceAuthoritativeAttempt):
                if markFrameForServiceAuthoritativeAttempt {
                    do {
                        _ = try recordingState.acceptFrame(at: currentInstant())
                    } catch {
                        ClipLog.lifecycle.error(
                            "Could not prepare an in-flight first frame for termination finalization: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                do {
                    try await finishRecording()
                } catch {
                    await dependencies.capture.cancel()
                    resetAfterTerminalState()
                }
            case .cancelSelectionOrCountdown:
                cancelSelectionOrCountdown()
            case .noAction:
                break
            }
        }

        await waitForTerminalOperationHandoff()
        await persistAndReleasePreviewForTermination()
        await dependencies.settings.flushPendingPersistence()
        await dependencies.liveSharePreferences.flushPendingPersistence()
    }

    private func waitForTerminalOperationHandoff() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            let retakeIsSettling = pendingRetake != nil
                || previewViewModel?.operation == .retaking
            guard recordingState.phase == .finishing || retakeIsSettling else { return }
            try? await clock.sleep(for: .milliseconds(50))
        }
        ClipLog.lifecycle.error("Timed out while waiting for a terminal recording handoff")
    }

    private func persistAndReleasePreviewForTermination() async {
        guard let viewModel = previewViewModel,
              let context = previewLifecycleContext else {
            return
        }

        await viewModel.settleForTermination()
        guard previewLifecycleContext === context else { return }
        do {
            let session = await context.currentSession()
            try await Self.persist(
                viewModel.snapshotForPersistence(),
                session: session,
                in: dependencies.history
            )
            let closeResult = try await dependencies.history.endPreviewSession(session)
            logPreviewCleanupFailure(closeResult.cleanupFailure)
            closePreviewWindow(context: context)
        } catch {
            ClipLog.storage.error(
                "Could not flush Preview during termination: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func installStatusItem() {
        guard !isPreparingForTermination else { return }
        let statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        updateStatusIcon(symbol: "record.circle", description: String(localized: "Clip"))
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.toolTip = String(localized: "Clip")
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func installIdlePopover() {
        guard !isPreparingForTermination else { return }
        let actions = MenuBarActions(
            startLiveShare: { [weak self] in self?.startLiveShare() },
            captureArea: { [weak self] in self?.requestSelection(mode: .captureArea) },
            lastArea: { [weak self] in self?.requestSelection(mode: .lastArea) },
            fullscreen: { [weak self] in self?.requestSelection(mode: .fullscreen) },
            captureApplication: { [weak self] in
                self?.requestSelection(mode: .captureApplication)
            },
            prepareDisplay: { _ in },
            recordPreparedDisplay: { [weak self] displayID in
                self?.recordPreparedDisplay(displayID)
            },
            setMicrophoneEnabled: { [weak self] enabled in
                self?.setAudioEnabled(.microphone, enabled: enabled)
            },
            setSystemAudioEnabled: { [weak self] enabled in
                self?.setAudioEnabled(.systemAudio, enabled: enabled)
            },
            setClickHighlightsEnabled: { [weak self] enabled in
                self?.setClickHighlightsEnabled(enabled)
            },
            openRecentRecording: { [weak self] recordingID in
                self?.openRecentRecording(recordingID)
            },
            openHistory: { [weak self] in self?.openHistory() },
            openSettings: { [weak self] in self?.openSettings() },
            checkForUpdates: { [weak self] in self?.checkForUpdates() },
            quit: { NSApp.terminate(nil) }
        )
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 300, height: 360)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(model: menuBarModel, actions: actions)
        )
    }

    private func checkForUpdates() {
        guard !isPreparingForTermination else { return }
        popover.performClose(nil)
        guard applicationUpdater.canCheckForUpdates else {
            NSSound.beep()
            return
        }
        applicationUpdater.checkForUpdates()
    }

    private func installRecordingPopover(model: RecordingPresentationModel) {
        guard !isPreparingForTermination else { return }
        popover.contentSize = NSSize(width: 330, height: 285)
        popover.contentViewController = NSHostingController(
            rootView: RecordingStatusView(model: model)
        )
    }

    private func installLiveSharePopover(model: LiveSharePresentationModel) {
        guard !isPreparingForTermination else { return }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = LiveSharePopoverView.contentSize
        popover.contentViewController = NSHostingController(
            rootView: LiveSharePopoverView(model: model)
        )
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        guard !isPreparingForTermination, dependencies.settings.isLoaded else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverWillShow(_ notification: Notification) {
        guard !isPreparingForTermination,
              recordingPresentationModel == nil,
              liveShareCoordinator == nil else { return }
        Task { @MainActor [weak self] in
            await self?.refreshMenuBarModel()
        }
    }

    private func startLiveShare() {
        popover.performClose(nil)
        Task { @MainActor [weak self] in
            guard let self,
                  !isStartingLiveShare,
                  !isPreparingCapture,
                  liveShareCoordinator == nil,
                  recordingPresentationModel == nil,
                  [.idle, .canceled, .failed, .preview].contains(recordingState.phase) else {
                NSSound.beep()
                return
            }
            isStartingLiveShare = true
            defer { isStartingLiveShare = false }
            guard await ensureLiveShareScreenRecordingPermission() else { return }
            guard liveShareCoordinator == nil,
                  recordingPresentationModel == nil,
                  [.idle, .canceled, .failed, .preview].contains(recordingState.phase),
                  !isPreparingCapture,
                  !isPreparingForTermination else {
                NSSound.beep()
                return
            }
            let coordinator = LiveShareCoordinator(
                preferences: dependencies.liveSharePreferences,
                serverEndpoint: dependencies.liveSharePreferences.serverEndpoint,
                onSessionEnded: { [weak self] in
                    self?.liveShareDidEnd()
                },
                onMenuBarStatusChanged: { [weak self] status in
                    self?.updateLiveShareStatusIcon(status)
                }
            )
            liveShareCoordinator = coordinator
            installLiveSharePopover(model: coordinator.presentationModel)
            updateLiveShareStatusIcon(.ready)
            coordinator.start()
            if let button = statusItem?.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func liveShareDidEnd() {
        guard !isPreparingForTermination else { return }
        liveShareCoordinator = nil
        installIdlePopover()
        updateStatusIcon(symbol: "record.circle", description: String(localized: "Clip"))
        Task { @MainActor [weak self] in
            await self?.refreshMenuBarModel()
        }
    }

    private func recordPreparedDisplay(_ displayID: CGDirectDisplayID) {
        guard liveShareCoordinator == nil, !isStartingLiveShare, !isPreparingCapture else {
            NSSound.beep()
            return
        }
        isPreparingCapture = true
        popover.performClose(nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isPreparingCapture = false }
            guard liveShareCoordinator == nil, !isStartingLiveShare else {
                NSSound.beep()
                return
            }
            guard CaptureSelectionPresentationPolicy.permitsSelection(
                recordingPhase: recordingState.phase,
                hasVisiblePreview: previewWindowController?.window?.isVisible == true
            ) else {
                NSSound.beep()
                return
            }
            await rememberCaptureMode(.fullscreen)
            guard await ensureScreenRecordingPermission() else {
                await refreshMenuBarModel()
                return
            }

            do {
                let displays = try await dependencies.displays.availableDisplays()
                guard let display = displays.first(where: { $0.id == displayID }) else {
                    throw MenuCaptureCoordinatorError.displayUnavailable
                }
                try recordingState.beginSelection(mode: .fullscreen)
                let pixelWidth = max(
                    2,
                    Int((display.frame.width * display.scaleFactor).rounded())
                )
                let pixelHeight = max(
                    2,
                    Int((display.frame.height * display.scaleFactor).rounded())
                )
                let selectionDisplay = CaptureSelectionDisplay(
                    id: display.stableIdentifier,
                    displayID: display.id,
                    name: display.name,
                    frameInGlobalPoints: display.frame,
                    pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
                    scaleFactor: display.scaleFactor,
                    isMain: display.id == CGMainDisplayID()
                )
                let captureSettings = await resolvedCaptureSettings(
                    dependencies.settings.settings
                )
                handleSelection(
                    .fullscreen(selectionDisplay),
                    mode: .fullscreen,
                    captureSettings: captureSettings
                )
            } catch {
                try? failRecording(code: .captureUnavailable, error: error)
                resetAfterTerminalState()
                presentError(title: "Couldn’t Prepare Display Recording", error: error)
            }
        }
    }

    private func setAudioEnabled(_ permission: ClipPermission, enabled: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if enabled,
               dependencies.permissions.currentStatus(for: permission) != .granted,
               await dependencies.permissions.request(permission) != .granted {
                await refreshMenuBarModel()
                return
            }

            await dependencies.settings.update { settings in
                switch permission {
                case .microphone:
                    settings.audio.microphoneEnabled = enabled
                case .systemAudio:
                    settings.audio.systemAudioEnabled = enabled
                case .screenRecording:
                    break
                }
            }
            await dependencies.audio.refreshDevices()
            await refreshMenuBarModel()
        }
    }

    private func setClickHighlightsEnabled(_ enabled: Bool) {
        dependencies.settings.updateImmediately { settings in
            settings.showClickHighlights = enabled
        }
    }

    private func openRecentRecording(_ recordingID: RecordingID) {
        popover.performClose(nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let item = try await dependencies.history.item(id: recordingID) else {
                    await refreshMenuBarModel()
                    throw MenuCaptureCoordinatorError.recordingUnavailable
                }
                try await presentPreview(item)
            } catch {
                presentError(title: "Couldn’t Open Recording", error: error)
            }
        }
    }

    private func refreshMenuBarModel() async {
        let displayRows = NSScreen.screens.compactMap { screen -> MenuBarDisplayRow? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let nativeWidth = Int(CGDisplayPixelsWide(displayID))
            let nativeHeight = Int(CGDisplayPixelsHigh(displayID))
            return MenuBarDisplayRow(
                id: displayID,
                name: screen.localizedName,
                pixelWidth: nativeWidth > 0
                    ? nativeWidth
                    : Int((screen.frame.width * screen.backingScaleFactor).rounded()),
                pixelHeight: nativeHeight > 0
                    ? nativeHeight
                    : Int((screen.frame.height * screen.backingScaleFactor).rounded())
            )
        }
        menuBarModel.replaceDisplays(displayRows)
        menuBarModel.setLastAreaAvailable(lastAreaStore.load() != nil)

        let settings = dependencies.settings.settings
        let microphonePermission = dependencies.permissions.currentStatus(for: .microphone)
        let microphoneAvailable = microphonePermission != .denied
            && microphonePermission != .restricted
            && (microphonePermission != .granted || dependencies.audio.defaultInputName != nil)
        menuBarModel.setMicrophone(
            MenuBarAudioState(
                isEnabled: settings.audio.microphoneEnabled,
                isAvailable: microphoneAvailable,
                detail: microphonePermission == .granted
                    ? dependencies.audio.defaultInputName
                    : permissionDetail(microphonePermission)
            )
        )

        let systemAudioPermission = dependencies.permissions.currentStatus(for: .systemAudio)
        menuBarModel.setSystemAudio(
            MenuBarAudioState(
                isEnabled: settings.audio.systemAudioEnabled,
                isAvailable: systemAudioPermission != .denied
                    && systemAudioPermission != .restricted,
                detail: permissionDetail(systemAudioPermission)
            )
        )
        menuBarModel.setClickHighlightsEnabled(settings.showClickHighlights)

        do {
            let index = try await dependencies.history.load()
            menuBarModel.replaceRecentRecordings(
                index.items.map(MenuBarRecentRecordingRow.init(item:))
            )
        } catch {
            menuBarModel.replaceRecentRecordings([])
            ClipLog.storage.error(
                "Could not refresh recent recordings: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func permissionDetail(_ state: PermissionState) -> String? {
        switch state {
        case .notDetermined:
            String(localized: "Permission requested when enabled")
        case .granted:
            nil
        case .denied:
            String(localized: "Permission denied")
        case .restricted:
            String(localized: "Permission restricted")
        }
    }

    private func presentOnboardingIfNeeded() {
        guard !isPreparingForTermination,
              !onboardingStore.isCompleted,
              onboardingWindowController == nil else {
            return
        }

        let viewModel = OnboardingViewModel(
            store: onboardingStore,
            currentScreenPermission: { [weak self] in
                self?.dependencies.permissions.currentStatus(for: .screenRecording)
                    ?? .notDetermined
            },
            requestScreenPermission: { [weak self] in
                guard let self else { return .notDetermined }
                let result = await dependencies.permissions.request(.screenRecording)
                await refreshMenuBarModel()
                return result
            },
            configureShortcuts: { [weak self] in
                self?.openSettings()
            },
            completion: { [weak self] in
                self?.onboardingWindowController?.close()
                self?.onboardingWindowController = nil
            }
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 610, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to Clip")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(
                viewModel: viewModel,
                settings: dependencies.settings
            )
        )
        let controller = NSWindowController(window: window)
        onboardingWindowController = controller
        controller.showWindow(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestSelection(mode: CaptureMode) {
        guard liveShareCoordinator == nil, !isStartingLiveShare, !isPreparingCapture else {
            NSSound.beep()
            return
        }
        isPreparingCapture = true
        popover.performClose(nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isPreparingCapture = false }
            await rememberCaptureMode(mode)
            await presentSelection(mode: mode)
        }
    }

    private func rememberCaptureMode(_ mode: CaptureMode) async {
        guard dependencies.settings.settings.mostRecentCaptureMode != mode else { return }
        await dependencies.settings.update { settings in
            settings.mostRecentCaptureMode = mode
        }
    }

    private func handleGlobalShortcut(_ action: GlobalShortcutAction) {
        guard liveShareCoordinator == nil, !isStartingLiveShare else {
            NSSound.beep()
            return
        }
        switch action {
        case .capture:
            guard [.idle, .canceled, .failed, .preview].contains(recordingState.phase) else {
                NSSound.beep()
                return
            }
            if let preparedDisplayID = menuBarModel.preparedDisplayID {
                recordPreparedDisplay(preparedDisplayID)
            } else {
                requestSelection(
                    mode: dependencies.settings.settings.captureModeForNextInvocation
                )
            }

        case .finish:
            guard (recordingState.phase == .recording || recordingState.phase == .paused),
                  recordingState.timeline.hasFrames else {
                NSSound.beep()
                return
            }
            Task { @MainActor [weak self] in
                do {
                    try await self?.finishRecording()
                } catch {
                    // finishRecording presents the actionable finalization error.
                }
            }

        case .pauseOrResume:
            switch recordingState.phase {
            case .recording:
                guard recordingState.timeline.hasFrames else {
                    NSSound.beep()
                    return
                }
                Task { @MainActor [weak self] in
                    do {
                        try await self?.pauseRecording()
                    } catch {
                        self?.presentError(title: "Recording Couldn’t Pause", error: error)
                    }
                }
            case .paused:
                Task { @MainActor [weak self] in
                    do {
                        try await self?.resumeRecording()
                    } catch {
                        self?.presentError(title: "Recording Couldn’t Resume", error: error)
                    }
                }
            default:
                NSSound.beep()
            }
        }
    }

    private func presentSelection(mode: CaptureMode) async {
        guard CaptureSelectionPresentationPolicy.permitsSelection(
            recordingPhase: recordingState.phase,
            hasVisiblePreview: previewWindowController?.window?.isVisible == true
        ) else {
            NSSound.beep()
            return
        }
        guard await ensureScreenRecordingPermission() else { return }

        do {
            try recordingState.beginSelection(mode: mode)
        } catch {
            presentError(title: "Couldn’t Start Capture Mode", error: error)
            return
        }

        let captureSettings = await resolvedCaptureSettings(
            dependencies.settings.settings
        )
        if mode == .captureApplication {
            await presentApplicationSelection(captureSettings: captureSettings)
            return
        }
        let audio = captureSettings.audio
        let configuration = CaptureSelectionConfiguration(
            microphoneStatus: audio.microphoneEnabled ? "Microphone: On" : "Microphone: Off",
            systemAudioStatus: audio.systemAudioEnabled ? "System Audio: On" : "System Audio: Off"
        )
        let controller = CaptureSelectionController(
            configuration: configuration,
            onComplete: { [weak self] result in
                self?.selectionController = nil
                self?.handleSelection(
                    result,
                    mode: mode,
                    captureSettings: captureSettings
                )
            },
            onCancel: { [weak self] in
                self?.selectionController = nil
                self?.cancelSelectionOrCountdown()
            }
        )
        selectionController = controller

        switch mode {
        case .captureArea:
            controller.presentAreaSelection()
        case .lastArea:
            controller.presentAreaSelection(restoring: lastAreaStore.load())
        case .fullscreen:
            controller.presentFullscreenSelection()
        case .captureApplication:
            break
        }
    }

    private func presentApplicationSelection(captureSettings: ClipSettings) async {
        do {
            let windows = try await CaptureApplicationDiscovery()
                .visibleApplicationWindows(
                    excludingBundleIdentifier: ApplicationDirectories.bundleIdentifier
                )
            let controller = ApplicationCaptureSelectionController(
                onComplete: { [weak self] selection in
                    self?.applicationSelectionController = nil
                    self?.handleApplicationSelection(
                        selection,
                        captureSettings: captureSettings
                    )
                },
                onCancel: { [weak self] in
                    self?.applicationSelectionController = nil
                    self?.cancelSelectionOrCountdown()
                }
            )
            applicationSelectionController = controller
            guard controller.present(windows: windows) else {
                applicationSelectionController = nil
                throw ApplicationCaptureCoordinatorError.noVisibleApplications
            }
        } catch {
            try? failRecording(code: .captureUnavailable, error: error)
            resetAfterTerminalState()
            presentError(title: "Couldn’t Choose an Application", error: error)
        }
    }

    private func handleApplicationSelection(
        _ selection: SelectedCaptureApplication,
        captureSettings: ClipSettings
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let preparedTarget = try CaptureSelectionAdapter.preparedTarget(from: selection)
                try recordingState.prepare(
                    target: preparedTarget.domainTarget,
                    mode: .captureApplication
                )
                try await dependencies.capture.prepare(preparedTarget)
                activeCaptureSettings = captureSettings
                _ = try recordingState.start(
                    countdown: captureSettings.countdown,
                    at: currentInstant()
                )
                beginApplicationCountdown(selection)
            } catch {
                try? failRecording(code: .captureUnavailable, error: error)
                presentError(title: "Couldn’t Prepare Application Recording", error: error)
                resetAfterTerminalState()
            }
        }
    }

    private func beginApplicationCountdown(_ selection: SelectedCaptureApplication) {
        let seconds = (activeCaptureSettings ?? dependencies.settings.settings).countdown.seconds
        let screen = matchingScreen(displayID: selection.display.displayID)
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let anchor = selection.rectangleInDisplayPoints.offsetBy(
            dx: selection.display.frameInGlobalPoints.minX,
            dy: selection.display.frameInGlobalPoints.minY
        )
        let controller = SilentCountdownController(
            onFinished: { [weak self] in
                await self?.startNativeCapture()
            },
            onCancelled: { [weak self] in
                self?.cancelSelectionOrCountdown()
            }
        )
        countdownController = controller
        updateStatusIcon(symbol: "timer", description: String(localized: "Clip countdown"))
        controller.start(
            seconds: seconds,
            anchorRectangleInGlobalPoints: anchor,
            screen: screen,
            targetDescription: selection.applicationName
        )
    }

    private func handleSelection(
        _ result: CaptureSelectionResult,
        mode: CaptureMode,
        captureSettings: ClipSettings
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let preparedTarget = try CaptureSelectionAdapter.preparedTarget(from: result)
                if case let .area(area) = result,
                   dependencies.settings.settings.rememberLastArea {
                    try lastAreaStore.save(area)
                }
                try recordingState.prepare(target: preparedTarget.domainTarget, mode: mode)
                try await dependencies.capture.prepare(preparedTarget)
                activeCaptureSettings = captureSettings
                _ = try recordingState.start(
                    countdown: activeCaptureSettings?.countdown ?? .off,
                    at: currentInstant()
                )
                beginCountdown(for: result)
            } catch {
                try? failRecording(code: .captureUnavailable, error: error)
                presentError(title: "Couldn’t Prepare Recording", error: error)
                resetAfterTerminalState()
            }
        }
    }

    private func beginCountdown(for result: CaptureSelectionResult) {
        let seconds = (activeCaptureSettings ?? dependencies.settings.settings).countdown.seconds
        let screen: NSScreen
        let anchor: CGRect
        let targetDescription: String
        let outlineRectangle: CGRect?

        switch result {
        case let .area(area):
            screen = matchingScreen(displayID: area.display.displayID) ?? NSScreen.main ?? NSScreen.screens[0]
            anchor = area.rectangleInDisplayPoints.offsetBy(
                dx: area.display.frameInGlobalPoints.minX,
                dy: area.display.frameInGlobalPoints.minY
            )
            targetDescription = String(localized: "Selected Area")
            outlineRectangle = anchor
        case let .fullscreen(display):
            screen = matchingScreen(displayID: display.displayID) ?? NSScreen.main ?? NSScreen.screens[0]
            anchor = display.frameInGlobalPoints
            targetDescription = display.name
            outlineRectangle = nil
        }

        let controller = SilentCountdownController(
            onFinished: { [weak self] in
                await self?.startNativeCapture(
                    outlineRectangleInGlobalPoints: outlineRectangle
                )
            },
            onCancelled: { [weak self] in
                self?.cancelSelectionOrCountdown()
            }
        )
        countdownController = controller
        updateStatusIcon(symbol: "timer", description: String(localized: "Clip countdown"))
        controller.start(
            seconds: seconds,
            anchorRectangleInGlobalPoints: anchor,
            screen: screen,
            targetDescription: targetDescription
        )
    }

    private func startNativeCapture(
        outlineRectangleInGlobalPoints: CGRect? = nil
    ) async {
        countdownController = nil
        do {
            if recordingState.phase == .countdown {
                _ = try recordingState.advanceCountdown(to: currentInstant())
            }
            guard recordingState.phase == .recording else { return }
            unavailableRecordingAudioSources.removeAll()
            recordingAudioNotice = nil
            let model = RecordingPresentationModel(
                snapshot: makeRecordingSnapshot(notice: String(localized: "Waiting for the first video frame…")),
                actions: RecordingPresentationActions(
                    pause: { [weak self] in try await self?.pauseRecording() },
                    resume: { [weak self] in try await self?.resumeRecording() },
                    finish: { [weak self] in try await self?.finishRecording() },
                    cancel: { [weak self] in await self?.cancelRecording() }
                )
            )
            recordingPresentationModel = model
            installRecordingPopover(model: model)
            updateStatusIcon(
                symbol: "record.circle.fill",
                description: String(localized: "Clip is recording")
            )
            // Install the waiting UI before capture starts. ScreenCaptureKit can
            // deliver frame zero while start() is suspended, and the event must
            // have a model to update.
            let recordingID = RecordingID()
            let captureSettings = activeCaptureSettings ?? dependencies.settings.settings
            activeRecordingID = recordingID
            if let outlineRectangleInGlobalPoints {
                regionOutlineController.show(
                    rectangleInGlobalPoints: outlineRectangleInGlobalPoints
                )
            }
            try await dependencies.capture.start(
                recordingID: recordingID,
                settings: captureSettings
            )
            updateRecordingPresentation()
        } catch {
            activeRecordingID = nil
            try? failRecording(code: .captureUnavailable, error: error)
            failPendingRetake(error)
            presentError(title: "Recording Couldn’t Start", error: error)
            resetAfterTerminalState()
        }
    }

    private func pauseRecording() async throws {
        guard recordingState.timeline.hasFrames else {
            throw RecordingTransitionError.noFramesAvailable
        }
        try await dependencies.capture.pause()
        try recordingState.pause(at: currentInstant())
        updateRecordingPresentation()
        updateStatusIcon(symbol: "pause.circle.fill", description: String(localized: "Clip is paused"))
    }

    private func resumeRecording() async throws {
        try await dependencies.capture.resume()
        try recordingState.resume(at: currentInstant())
        updateRecordingPresentation()
        updateStatusIcon(
            symbol: "record.circle.fill",
            description: String(localized: "Clip is recording")
        )
    }

    private func finishRecording() async throws {
        let commands = try recordingState.requestFinish(at: currentInstant())
        guard commands.contains(.stopAndFinalize) else {
            await dependencies.capture.cancel()
            let error = NativeCaptureServiceError.zeroDurationOutput
            presentError(title: "Recording Has No Video", error: error)
            resetAfterTerminalState()
            throw error
        }
        regionOutlineController.hide()
        updateRecordingPresentation()

        var completedItem: RecordingHistoryItem?
        do {
            let completedCaptureSettings = activeCaptureSettings ?? dependencies.settings.settings
            defer {
                activeRecordingID = nil
                activeCaptureSettings = nil
                unavailableRecordingAudioSources.removeAll()
                recordingAudioNotice = nil
            }
            let artifact = try await dependencies.capture.finish()
            let item = try await importArtifact(
                artifact,
                captureSettings: completedCaptureSettings
            )
            completedItem = item
            sessionSettingsByRecordingID[item.id] = completedCaptureSettings
            _ = try recordingState.completeFinish(recordingID: item.id)
        } catch {
            let recordingWasImported = completedItem != nil
            handleRecordingCompletionFailure(
                error,
                recordingWasImported: recordingWasImported
            )
            guard !recordingWasImported else { return }
            throw error
        }

        guard let item = completedItem else { return }

        recordingPresentationModel = nil
        guard !isPreparingForTermination else { return }
        installIdlePopover()
        await refreshMenuBarModel()
        updateStatusIcon(symbol: "record.circle", description: String(localized: "Clip"))

        do {
            if pendingRetake != nil {
                try await completePendingRetake(with: item)
            } else {
                try await presentPreview(item)
            }
        } catch {
            handleRecordingCompletionFailure(
                error,
                recordingWasImported: true
            )
        }
    }

    private func handleRecordingCompletionFailure(
        _ error: any Error,
        recordingWasImported: Bool
    ) {
        switch RecordingCompletionPolicy.failureDisposition(
            recordingWasImported: recordingWasImported
        ) {
        case .recordingFailed:
            try? failRecording(code: .encodingFailed, error: error)
            resetAfterTerminalState()
            failPendingRetake(error)
            presentError(title: "Recording Couldn’t Finish", error: error)

        case .recordingSavedPreviewDeferred:
            if recordingState.phase == .finishing {
                // The MP4 is already durable in History. Recover coordinator
                // bookkeeping without reclassifying that recording as failed.
                try? failRecording(code: .encodingFailed, error: error)
                resetAfterTerminalState()
            }
            failPendingRetake(error)
            presentError(
                title: "Recording Saved",
                error: RecordingSavedPreviewDeferredError(
                    technicalDescription: error.localizedDescription
                )
            )
        }
    }

    private func cancelRecording() async {
        do {
            _ = try recordingState.requestCancel(at: currentInstant())
            if recordingState.isCancellationConfirmationPending {
                _ = try recordingState.resolveCancellation(
                    confirmed: true,
                    at: currentInstant()
                )
            }
        } catch {
            ClipLog.capture.error(
                "Recording cancellation state failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        activeRecordingID = nil
        activeCaptureSettings = nil
        await dependencies.capture.cancel()
        resetAfterTerminalState()
        cancelPendingRetake()
    }

    private func cancelSelectionOrCountdown() {
        countdownController?.stopWithoutCallback()
        countdownController = nil
        do {
            if [.selecting, .countdown].contains(recordingState.phase) {
                _ = try recordingState.requestCancel(at: currentInstant())
            }
        } catch {
            ClipLog.capture.error(
                "Capture selection cancellation failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        resetAfterTerminalState()
        cancelPendingRetake()
    }

    private func monitorCaptureEvents() {
        let events = dependencies.capture.events
        captureEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                handleCaptureEvent(event)
            }
        }
    }

    private func startMaintenanceLoop() {
        maintenanceTask?.cancel()
        let clock = dependencies.clock
        maintenanceTask = Task { @MainActor [weak self] in
            await PeriodicStorageMaintenanceLoop.run(
                clock: clock,
                operation: { [weak self] in
                    guard let self else { return }
                    _ = try await dependencies.history.applyRetentionCleanup(
                        policy: dependencies.settings.settings.historyRetention
                    )
                    _ = try await dependencies.exports.removeStaleExports(
                        olderThan: clock.now.addingTimeInterval(
                            -PreviewExportCoordinator.staleExportLifetime
                        )
                    )
                    _ = try await dependencies.history.removeStaleTransactionArtifacts(
                        olderThan: clock.now.addingTimeInterval(
                            -ManagedHistoryRepository.staleTransactionArtifactLifetime
                        )
                    )
                    await refreshMenuBarModel()
                },
                reportFailure: { error in
                    ClipLog.storage.error(
                        "Periodic storage maintenance failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            )
        }
    }

    private func handleCaptureEvent(_ event: ScreenRecorderEvent) {
        switch event {
        case let .firstVideoSample(sessionIdentifier, _):
            guard activeRecordingID?.rawValue == sessionIdentifier else { return }
            guard recordingState.phase == .recording,
                  !recordingState.timeline.hasFrames else { return }
            do {
                _ = try recordingState.acceptFrame(at: currentInstant())
                updateRecordingPresentation()
            } catch {
                ClipLog.capture.error(
                    "Could not accept first capture frame: \(error.localizedDescription, privacy: .public)"
                )
            }

        case let .audioSourceUnavailable(sessionIdentifier, source, message):
            guard activeRecordingID?.rawValue == sessionIdentifier else { return }
            guard recordingState.phase == .recording || recordingState.phase == .paused else { return }
            unavailableRecordingAudioSources.insert(source)
            recordingAudioNotice = audioLossNotice()
            ClipLog.capture.warning(
                "Optional audio source became unavailable; video capture continues: \(message, privacy: .public)"
            )
            updateRecordingPresentation()

        case let .failure(sessionIdentifier, message):
            guard activeRecordingID?.rawValue == sessionIdentifier else { return }
            guard recordingState.phase == .recording || recordingState.phase == .paused else { return }
            let failure = RecordingFailure(code: .streamFailed, technicalDescription: message)
            let presentationError = CaptureStoppedError(message: message)
            let commands: [RecordingCommand]
            do {
                commands = try recordingState.fail(failure, at: currentInstant())
            } catch {
                ClipLog.capture.error(
                    "Could not enter capture recovery: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The event matched when it was dequeued, but this task may run
                // after cancellation and a later capture have replaced it.
                guard activeRecordingID?.rawValue == sessionIdentifier else { return }
                guard commands.contains(.attemptFinalizePlayableOutput) else {
                    activeRecordingID = nil
                    await dependencies.capture.cancel()
                    failPendingRetake(presentationError)
                    resetAfterTerminalState()
                    presentError(title: "Recording Stopped Unexpectedly", error: presentationError)
                    return
                }
                do {
                    let completedCaptureSettings = activeCaptureSettings
                        ?? dependencies.settings.settings
                    defer {
                        activeRecordingID = nil
                        activeCaptureSettings = nil
                    }
                    let artifact = try await dependencies.capture.finish()
                    let item = try await importArtifact(
                        artifact,
                        captureSettings: completedCaptureSettings
                    )
                    sessionSettingsByRecordingID[item.id] = completedCaptureSettings
                    _ = try recordingState.recoverPlayableOutput(recordingID: item.id)
                    recordingPresentationModel = nil
                    installIdlePopover()
                    await refreshMenuBarModel()
                    updateStatusIcon(symbol: "record.circle", description: String(localized: "Clip"))
                    if pendingRetake != nil {
                        try await completePendingRetake(with: item)
                    } else {
                        try await presentPreview(item)
                    }
                    presentError(title: "Recording Ended Early", error: presentationError)
                } catch {
                    failPendingRetake(error)
                    resetAfterTerminalState()
                    presentError(title: "Recording Stopped Unexpectedly", error: error)
                }
            }
        }
    }

    private func importArtifact(
        _ artifact: RecordingArtifact,
        captureSettings: ClipSettings
    ) async throws -> RecordingHistoryItem {
        let createdAt = Date()
        return try await dependencies.history.importFinalizedRecording(
            FinalizedRecordingImport(
                id: artifact.id,
                sourceURL: artifact.fileURL,
                createdAt: createdAt,
                filenameTemplate: captureSettings.defaultFilenameTemplate,
                duration: artifact.duration,
                pixelSize: artifact.pixelSize,
                frameRate: artifact.frameRate,
                audioConfiguration: artifact.audioConfiguration,
                captureTarget: artifact.captureTarget,
                captureSessionSnapshot: CaptureSessionSnapshot(settings: captureSettings),
                exportConfiguration: dependencies.settings.settings.exportConfiguration
            )
        )
    }

    private func presentPreview(_ item: RecordingHistoryItem) async throws {
        guard !isPreparingForTermination else { return }
        if let existingWindow = previewWindowController?.window {
            guard let existingViewModel = previewViewModel,
                  let existingContext = previewLifecycleContext else {
                existingWindow.close()
                previewWindowController = nil
                previewWindowDelegate = nil
                previewViewModel = nil
                previewLifecycleContext = nil
                return try await presentPreview(item)
            }
            if existingViewModel.recording.id == item.id {
                existingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            guard !existingViewModel.isBusy else {
                throw PreviewPresentationError.operationInProgress
            }

            let existingSession = await existingContext.currentSession()
            try await Self.persist(
                existingViewModel.snapshotForPersistence(),
                session: existingSession,
                in: dependencies.history
            )
            let closeResult = try await dependencies.history.endPreviewSession(existingSession)
            logPreviewCleanupFailure(closeResult.cleanupFailure)
            closePreviewWindow(context: existingContext)
        }
        let sourceURL = try await dependencies.history.masterURL(for: item.id)
        let retakePlan = PreviewRetakePlan(
            historyItem: item,
            currentSettings: dependencies.settings.settings,
            inMemorySessionSettings: sessionSettingsByRecordingID[item.id]
        )
        let recording = try PreviewRecording(
            id: item.id,
            sourceURL: sourceURL,
            duration: item.recordingDuration,
            pixelSize: item.pixelSize,
            frameRate: item.frameRate,
            audioConfiguration: item.audioConfiguration,
            filename: item.filename,
            trimRange: item.trimRange,
            exportConfiguration: item.exportConfiguration,
            exportQualities: dependencies.settings.settings.exportQualities,
            sourceVideoQualityPercent: item.managedMasterVideoQualityPercent,
            exportAudioPreference: item.exportAudioPreference,
            approximateExportByteCount: item.managedByteCount,
            retakePlan: retakePlan
        )
        let previewSession = try await dependencies.history.beginPreviewSession(id: item.id)
        let lifecycleContext = PreviewLifecycleContext(session: previewSession)
        let actions = makePreviewActions(context: lifecycleContext)
        let viewModel = PreviewViewModel(recording: recording, actions: actions)
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 820, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = item.filename.fileName
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(
            rootView: PreviewView(viewModel: viewModel)
        )
        let controller = NSWindowController(window: panel)
        let windowDelegate = PreviewWindowDelegate(viewModel: viewModel)
        panel.delegate = windowDelegate
        previewWindowController = controller
        previewWindowDelegate = windowDelegate
        previewViewModel = viewModel
        previewLifecycleContext = lifecycleContext
        controller.showWindow(nil)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePreviewActions(context: PreviewLifecycleContext) -> PreviewActions {
        let history = dependencies.history
        let exports = dependencies.exports
        let pasteboard = dependencies.pasteboard
        let sharing = dependencies.sharing
        let settingsModel = dependencies.settings
        let currentSharePreferences: @MainActor @Sendable () -> SharePreferences = {
            SharePreferences(settings: settingsModel.settings)
        }

        return PreviewActions(
            export: { request in
                let preferences = await currentSharePreferences()
                let session = await context.currentSession()
                try await Self.persist(request, session: session, in: history)
                let publication = try await exports.exportForPublication(request)
                let outputURL = publication.outputURL
                let publicationWarning = await Self.publishManagedExport(
                    request,
                    lease: publication,
                    through: exports
                )
                return await Self.registerPreviewShare(
                    id: request.recordingID,
                    outputURL: outputURL,
                    videoQualityPercent: request.videoQualityPercent,
                    preferences: preferences,
                    previewSession: session,
                    history: history,
                    priorWarning: publicationWarning
                )
            },
            copy: { request in
                let preferences = currentSharePreferences()
                let session = await context.currentSession()
                try await Self.persist(request, session: session, in: history)
                let publication = try await exports.exportForPublication(request)
                let outputURL = publication.outputURL
                do {
                    try pasteboard.placeFile(at: outputURL)
                } catch {
                    await exports.cancelPublication(publication)
                    throw error
                }
                let publicationWarning = await Self.publishManagedExport(
                    request,
                    lease: publication,
                    through: exports
                )
                return await Self.registerPreviewShare(
                    id: request.recordingID,
                    outputURL: outputURL,
                    videoQualityPercent: request.videoQualityPercent,
                    preferences: preferences,
                    previewSession: session,
                    history: history,
                    shouldClosePreview: preferences.closePreviewAfterCopy,
                    priorWarning: publicationWarning
                )
            },
            save: { request in
                let preferences = currentSharePreferences()
                let session = await context.currentSession()
                try await Self.persist(request, session: session, in: history)
                guard let outputURL = try await sharing.saveAs(request) else { return nil }
                return await Self.registerPreviewShare(
                    id: request.recordingID,
                    outputURL: outputURL,
                    videoQualityPercent: request.videoQualityPercent,
                    preferences: preferences,
                    previewSession: session,
                    history: history
                )
            },
            retake: { [weak self] recording in
                try await self?.beginRetake(recording, context: context)
            },
            done: { [weak self] recording in
                let session = await context.currentSession()
                try await Self.persist(recording, session: session, in: history)
                let closeResult = try await history.endPreviewSession(session)
                self?.logPreviewCleanupFailure(closeResult.cleanupFailure)
                self?.closePreviewWindow(context: context)
            },
            delete: { [weak self] recording in
                let session = await context.currentSession()
                _ = try await history.delete(
                    id: recording.id,
                    previewSession: session
                )
                let closeResult = try await history.endPreviewSession(session)
                self?.logPreviewCleanupFailure(closeResult.cleanupFailure)
                self?.closePreviewWindow(context: context)
            },
            reveal: { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        )
    }

    private func beginRetake(
        _ recording: PreviewRecording,
        context: PreviewLifecycleContext
    ) async throws -> PreviewRetakeResult? {
        guard liveShareCoordinator == nil, !isStartingLiveShare else {
            throw PreviewRetakeCoordinatorError.liveShareActive
        }
        guard !isPreparingCapture else {
            throw PreviewRetakeCoordinatorError.retakeAlreadyActive
        }
        isPreparingCapture = true
        defer { isPreparingCapture = false }
        guard pendingRetake == nil else {
            throw PreviewRetakeCoordinatorError.retakeAlreadyActive
        }
        guard let plan = recording.retakePlan else {
            throw PreviewRetakeCoordinatorError.missingCapturePlan
        }
        guard await ensureScreenRecordingPermission() else { return nil }
        guard liveShareCoordinator == nil, !isStartingLiveShare else {
            throw PreviewRetakeCoordinatorError.liveShareActive
        }

        let prepared = try await preparedRetakeTarget(for: plan.target)
        let retakeSettings = await resolvedCaptureSettings(plan.settings)
        let mode: CaptureMode
        switch plan.target {
        case .fullscreen:
            mode = .fullscreen
        case .region:
            // This is deliberately not Last Area. Retake uses the recording's
            // saved normalized target without mutating the user's Last Area.
            mode = .captureArea
        case .application:
            mode = .captureApplication
        }

        try recordingState.prepare(target: prepared.domainTarget, mode: mode)
        try await dependencies.capture.prepare(prepared)
        activeCaptureSettings = retakeSettings
        _ = try recordingState.start(
            countdown: retakeSettings.countdown,
            at: currentInstant()
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRetake = PendingRetake(
                originalRecording: recording,
                context: context,
                continuation: continuation
            )
            previewWindowController?.window?.orderBack(nil)
            beginRetakeCountdown(
                target: prepared,
                seconds: retakeSettings.countdown.seconds
            )
        }
    }

    private func preparedRetakeTarget(
        for target: ClipCore.CaptureTarget
    ) async throws -> PreparedCaptureTarget {
        let displays = try await dependencies.displays.availableDisplays()
        let displayID: DisplayID
        switch target {
        case let .fullscreen(id): displayID = id
        case let .region(selection): displayID = selection.displayID
        case let .application(application): displayID = application.displayID
        }
        guard let display = displays.first(where: { $0.stableIdentifier == displayID.rawValue }) else {
            throw PreviewRetakeCoordinatorError.displayUnavailable(displayID.rawValue)
        }

        let selectionDisplay = CaptureSelectionDisplay(
            id: display.stableIdentifier,
            displayID: display.id,
            name: display.name,
            frameInGlobalPoints: display.frame,
            pixelSize: CGSize(
                width: display.frame.width * display.scaleFactor,
                height: display.frame.height * display.scaleFactor
            ),
            scaleFactor: display.scaleFactor,
            isMain: display.id == CGMainDisplayID()
        )

        switch target {
        case .fullscreen:
            return try CaptureSelectionAdapter.preparedTarget(
                from: .fullscreen(selectionDisplay)
            )

        case let .region(selection):
            return try CaptureSelectionAdapter.preparedTarget(
                from: selection,
                on: selectionDisplay
            )

        case let .application(application):
            let windows = try await CaptureApplicationDiscovery()
                .visibleApplicationWindows(
                    excludingBundleIdentifier: ApplicationDirectories.bundleIdentifier
                )
            let segments = ApplicationCaptureSelectionLayout.segments(
                for: selectionDisplay,
                quartzDisplayFrame: CGDisplayBounds(display.id),
                windows: windows
            )
            guard let selection = ApplicationCaptureSelectionLayout.selection(
                bundleIdentifier: application.bundleIdentifier,
                display: selectionDisplay,
                segments: segments
            ) else {
                throw PreviewRetakeCoordinatorError.applicationUnavailable(
                    application.applicationName
                )
            }
            return try CaptureSelectionAdapter.preparedTarget(from: selection)
        }
    }

    private func beginRetakeCountdown(target: PreparedCaptureTarget, seconds: Int) {
        let screen = matchingScreen(displayID: target.displayID) ?? NSScreen.main ?? NSScreen.screens[0]
        let anchor: CGRect
        let description: String
        let outlineRectangle: CGRect?
        if case let .application(application) = target.domainTarget,
           let sourceRect = target.sourceRect {
            anchor = CGRect(
                x: screen.frame.minX + sourceRect.minX,
                y: screen.frame.minY + screen.frame.height - sourceRect.maxY,
                width: sourceRect.width,
                height: sourceRect.height
            )
            description = application.applicationName
            outlineRectangle = nil
        } else if let sourceRect = target.sourceRect {
            anchor = CGRect(
                x: screen.frame.minX + sourceRect.minX,
                y: screen.frame.minY + screen.frame.height - sourceRect.maxY,
                width: sourceRect.width,
                height: sourceRect.height
            )
            description = String(localized: "Previous Area")
            outlineRectangle = anchor
        } else {
            anchor = screen.frame
            description = screen.localizedName
            outlineRectangle = nil
        }

        let controller = SilentCountdownController(
            onFinished: { [weak self] in
                await self?.startNativeCapture(
                    outlineRectangleInGlobalPoints: outlineRectangle
                )
            },
            onCancelled: { [weak self] in
                self?.cancelSelectionOrCountdown()
            }
        )
        countdownController = controller
        updateStatusIcon(symbol: "timer", description: String(localized: "Clip retake countdown"))
        controller.start(
            seconds: seconds,
            anchorRectangleInGlobalPoints: anchor,
            screen: screen,
            targetDescription: description
        )
    }

    private func completePendingRetake(with item: RecordingHistoryItem) async throws {
        guard let pendingRetake else {
            throw PreviewRetakeCoordinatorError.missingPendingRetake
        }
        let sourceURL = try await dependencies.history.masterURL(for: item.id)
        let inMemorySettings = sessionSettingsByRecordingID[item.id]
            ?? activeCaptureSettings
        let retakePlan = PreviewRetakePlan(
            historyItem: item,
            currentSettings: dependencies.settings.settings,
            inMemorySessionSettings: inMemorySettings
        )
        let replacement = try PreviewRecording(
            id: item.id,
            sourceURL: sourceURL,
            duration: item.recordingDuration,
            pixelSize: item.pixelSize,
            frameRate: item.frameRate,
            audioConfiguration: item.audioConfiguration,
            filename: item.filename,
            trimRange: item.trimRange,
            exportConfiguration: item.exportConfiguration,
            exportQualities: dependencies.settings.settings.exportQualities,
            sourceVideoQualityPercent: item.managedMasterVideoQualityPercent,
            exportAudioPreference: item.exportAudioPreference,
            approximateExportByteCount: item.managedByteCount,
            retakePlan: retakePlan
        )
        let replacementSession = try await dependencies.history.beginPreviewSession(id: item.id)
        let history = dependencies.history
        let originalID = pendingRetake.originalRecording.id
        let context = pendingRetake.context
        let result = PreviewRetakeResult(
            recording: replacement,
            commitInstallation: { [weak self] in
                let originalSession = await context.currentSession()
                _ = try await history.delete(
                    id: originalID,
                    previewSession: originalSession
                )
                let closeResult = try await history.endPreviewSession(originalSession)
                await context.install(session: replacementSession)
                self?.sessionSettingsByRecordingID[originalID] = nil
                self?.logPreviewCleanupFailure(closeResult.cleanupFailure)
            },
            discardReplacement: { [weak self] in
                do {
                    _ = try await history.delete(
                        id: item.id,
                        previewSession: replacementSession
                    )
                    let closeResult = try await history.endPreviewSession(replacementSession)
                    self?.logPreviewCleanupFailure(closeResult.cleanupFailure)
                } catch {
                    ClipLog.storage.error(
                        "Could not discard an uninstalled retake: \(error.localizedDescription, privacy: .public)"
                    )
                }
                self?.sessionSettingsByRecordingID[item.id] = nil
            }
        )

        self.pendingRetake = nil
        if !isPreparingForTermination {
            previewWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        pendingRetake.succeed(result)
    }

    private func cancelPendingRetake() {
        guard let pendingRetake else { return }
        self.pendingRetake = nil
        if !isPreparingForTermination {
            previewWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        pendingRetake.cancel()
    }

    private func failPendingRetake(_ error: any Error) {
        guard let pendingRetake else { return }
        self.pendingRetake = nil
        if !isPreparingForTermination {
            previewWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        pendingRetake.fail(error)
    }

    /// History bookkeeping happens after the MP4 has already been exported and,
    /// for Copy or Save As, shared outside Clip. A repository failure therefore
    /// keeps the managed original and becomes an inline warning, never a false
    /// report that the external operation failed.
    private nonisolated static func registerPreviewShare(
        id: RecordingID,
        outputURL: URL,
        videoQualityPercent: Int,
        preferences: SharePreferences,
        previewSession: ManagedHistoryPreviewSession,
        history: ManagedHistoryRepository,
        shouldClosePreview: Bool = false,
        priorWarning: String? = nil
    ) async -> PreviewShareOutcome {
        do {
            let result = try await history.registerSuccessfulExport(
                id: id,
                exportedFileURL: outputURL,
                retentionPolicy: preferences.retentionPolicy,
                keepOriginalAfterExport: preferences.keepOriginalAfterExport,
                exportedVideoQualityPercent: videoQualityPercent,
                previewSession: previewSession
            )
            return PreviewShareOutcome(
                outputURL: outputURL,
                historyDisposition: result.disposition,
                sourceFinalizationDeferred: result.finalizationDeferred,
                shouldClosePreview: shouldClosePreview,
                postShareWarning: priorWarning
            )
        } catch {
            ClipLog.storage.error(
                "Post-share History registration failed; the managed original was retained"
            )
            return PreviewShareOutcome(
                outputURL: outputURL,
                historyDisposition: .keepOriginal,
                sourceFinalizationDeferred: false,
                shouldClosePreview: shouldClosePreview,
                postShareWarning: combinedPostShareWarning(
                    priorWarning,
                    postShareHistoryWarning()
                )
            )
        }
    }

    private nonisolated static func registerHistoryShare(
        id: RecordingID,
        outputURL: URL,
        videoQualityPercent: Int,
        preferences: SharePreferences,
        history: ManagedHistoryRepository,
        exportInventory: ManagedExportInventory? = nil,
        priorWarning: String? = nil
    ) async -> HistoryShareOutcome {
        let outputByteCount = ShareCompletionFormatting.fileByteCount(at: outputURL)
        do {
            _ = try await history.registerSuccessfulExport(
                id: id,
                exportedFileURL: outputURL,
                retentionPolicy: preferences.retentionPolicy,
                keepOriginalAfterExport: preferences.keepOriginalAfterExport,
                exportedVideoQualityPercent: videoQualityPercent
            )
            return HistoryShareOutcome(
                refreshedIndex: try await history.load(),
                exportInventory: exportInventory,
                outputByteCount: outputByteCount,
                postShareWarning: priorWarning
            )
        } catch {
            ClipLog.storage.error(
                "Post-share History registration failed; the current History view was retained"
            )
            return HistoryShareOutcome(
                refreshedIndex: nil,
                exportInventory: exportInventory,
                outputByteCount: outputByteCount,
                postShareWarning: combinedPostShareWarning(
                    priorWarning,
                    postShareHistoryWarning()
                )
            )
        }
    }

    /// Copy and promised drag have already succeeded by the time the durable
    /// Exports marker is written. Inventory bookkeeping therefore becomes an
    /// inline warning rather than falsely failing a usable external share.
    private nonisolated static func publishManagedExport(
        _ request: PreviewExportRequest,
        lease: ManagedExportPublicationLease,
        through exports: PreviewExportCoordinator
    ) async -> String? {
        do {
            try await exports.markPublished(request, lease: lease)
            return nil
        } catch {
            ClipLog.storage.error(
                "Post-share Exports registration failed; the shared MP4 remains usable"
            )
            return String(
                localized: "Clip couldn’t add the shared MP4 to Exports. The file is still available."
            )
        }
    }

    private nonisolated static func combinedPostShareWarning(
        _ first: String?,
        _ second: String?
    ) -> String? {
        switch (first, second) {
        case let (first?, second?) where first != second:
            "\(first) \(second)"
        case let (first?, _):
            first
        case let (_, second?):
            second
        case (nil, nil):
            nil
        }
    }

    private nonisolated static func postShareHistoryWarning() -> String {
        String(localized: "Clip couldn’t update History. The shared MP4 is still available.")
    }

    private nonisolated static func persist(
        _ request: PreviewExportRequest,
        session: ManagedHistoryPreviewSession,
        in history: ManagedHistoryRepository
    ) async throws {
        _ = try await history.updatePreviewMetadata(
            session: session,
            filename: request.filename,
            trimRange: request.trimRange,
            configuration: request.configuration,
            audioPreference: request.audioPreference
        )
    }

    private nonisolated static func persist(
        _ recording: PreviewRecording,
        session: ManagedHistoryPreviewSession,
        in history: ManagedHistoryRepository
    ) async throws {
        _ = try await history.updatePreviewMetadata(
            session: session,
            filename: recording.filename,
            trimRange: recording.trimRange,
            configuration: recording.exportConfiguration,
            audioPreference: recording.exportAudioPreference
        )
    }

    private func closePreviewWindow(context: PreviewLifecycleContext) {
        guard previewLifecycleContext === context else { return }
        previewWindowDelegate?.allowClose = true
        previewWindowController?.close()
        previewWindowController = nil
        previewWindowDelegate = nil
        previewViewModel = nil
        previewLifecycleContext = nil
    }

    private func logPreviewCleanupFailure(_ failure: ManagedFileCleanupFailure?) {
        guard let failure else { return }
        ClipLog.storage.error(
            "Deferred Preview cleanup will retry during reconciliation: \(failure.reason, privacy: .public)"
        )
    }

    private func openHistory() {
        guard !isPreparingForTermination else { return }
        popover.performClose(nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let history = dependencies.history
                let exports = dependencies.exports
                async let loadedIndex = history.load()
                let exportInventory: ManagedExportInventory
                let exportInventoryAlert: HistoryAlert?
                do {
                    exportInventory = try await exports.inventory()
                    exportInventoryAlert = nil
                } catch {
                    exportInventory = .empty
                    let details = UserFacingErrorPresentation.details(for: error)
                    ClipLog.storage.error(
                        "History opened without its Exports inventory: \(details.technicalDescription, privacy: .private)"
                    )
                    exportInventoryAlert = .error(
                        id: UUID(),
                        title: "Couldn’t Load Exports",
                        message: "Recordings are still available. Refresh History to try loading exports again."
                    )
                }
                let index = try await loadedIndex
                let viewModel = HistoryViewModel(
                    index: index,
                    exportInventory: exportInventory,
                    actions: makeHistoryActions()
                )
                viewModel.alert = exportInventoryAlert
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 860, height: 560),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = String(localized: "Clip History")
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(
                    rootView: HistoryView(viewModel: viewModel)
                )
                historyWindowController?.close()
                let controller = NSWindowController(window: window)
                historyWindowController = controller
                controller.showWindow(nil)
                window.center()
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                presentError(title: "Couldn’t Open History", error: error)
            }
        }
    }

    private func makeHistoryActions() -> HistoryActions {
        let history = dependencies.history
        let exports = dependencies.exports
        let pasteboard = dependencies.pasteboard
        let sharing = dependencies.sharing
        let settingsModel = dependencies.settings

        return HistoryActions(
            refresh: { try await history.reloadFromDisk() },
            preview: { [weak self] item in try await self?.presentPreview(item) },
            copy: { item in
                let preferences = SharePreferences(settings: settingsModel.settings)
                let request = try await Self.exportRequest(
                    for: item,
                    history: history,
                    exportQualities: settingsModel.settings.exportQualities
                )
                let publication = try await exports.exportForPublication(request)
                let outputURL = publication.outputURL
                do {
                    try pasteboard.placeFile(at: outputURL)
                } catch {
                    await exports.cancelPublication(publication)
                    throw error
                }
                let publicationWarning = await Self.publishManagedExport(
                    request,
                    lease: publication,
                    through: exports
                )
                return await Self.registerHistoryShare(
                    id: item.id,
                    outputURL: outputURL,
                    videoQualityPercent: request.videoQualityPercent,
                    preferences: preferences,
                    history: history,
                    exportInventory: try? await exports.inventory(),
                    priorWarning: publicationWarning
                )
            },
            save: { item in
                let preferences = SharePreferences(settings: settingsModel.settings)
                let request = try await Self.exportRequest(
                    for: item,
                    history: history,
                    exportQualities: settingsModel.settings.exportQualities
                )
                guard let outputURL = try await sharing.saveAs(request) else { return nil }
                return await Self.registerHistoryShare(
                    id: item.id,
                    outputURL: outputURL,
                    videoQualityPercent: request.videoQualityPercent,
                    preferences: preferences,
                    history: history
                )
            },
            reveal: { item in
                let url = try await history.masterURL(for: item.id)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            rename: { id, filename in
                _ = try await history.rename(id: id, to: filename.fileName)
                return try await history.load()
            },
            delete: { id in
                _ = try await history.delete(id: id)
                return try await history.load()
            },
            clear: {
                let current = try await history.load()
                for item in current.items {
                    _ = try await history.delete(id: item.id)
                }
                return try await history.load()
            },
            refreshExports: { try await exports.inventory() },
            revealExport: { export in
                guard FileManager.default.isReadableFile(atPath: export.url.path) else {
                    throw PreviewExportCoordinatorError.managedExportNotFound(export.id)
                }
                NSWorkspace.shared.activateFileViewerSelecting([export.url])
            },
            deleteExport: { id in
                try await exports.deleteExport(id: id)
            },
            purgeExports: {
                try await exports.deleteAllPublishedExports()
            }
        )
    }

    private nonisolated static func exportRequest(
        for item: RecordingHistoryItem,
        history: ManagedHistoryRepository,
        exportQualities: ExportQualitySettings
    ) async throws -> PreviewExportRequest {
        PreviewExportRequest(
            recordingID: item.id,
            sourceURL: try await history.masterURL(for: item.id),
            captureFrameRate: item.frameRate,
            filename: item.filename,
            trimRange: item.trimRange,
            configuration: item.exportConfiguration,
            videoQualityPercent: exportQualities.quality(for: item.exportConfiguration.preset),
            sourceVideoQualityPercent: item.managedMasterVideoQualityPercent,
            audioPreference: item.exportAudioPreference
        )
    }

    private func openSettings() {
        guard !isPreparingForTermination else { return }
        popover.performClose(nil)
        let history = dependencies.history
        let historyDirectory = dependencies.directories.recordings
        let storageActions = SettingsStorageActions(
            loadUsage: {
                SettingsStorageSnapshot(try await history.storageUsage())
            },
            clearHistory: { [weak self] in
                let current = try await history.load()
                for item in current.items {
                    _ = try await history.delete(id: item.id)
                }
                let snapshot = SettingsStorageSnapshot(try await history.storageUsage())
                await self?.refreshMenuBarModel()
                return snapshot
            },
            revealHistory: {
                NSWorkspace.shared.activateFileViewerSelecting([historyDirectory])
            }
        )
        let view = SettingsView(
            model: dependencies.settings,
            liveSharePreferences: dependencies.liveSharePreferences,
            shortcuts: dependencies.shortcuts,
            permissions: dependencies.permissions,
            audio: dependencies.audio,
            historyDirectory: historyDirectory,
            storageActions: storageActions
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: SettingsView.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Clip Settings")
        window.isReleasedWhenClosed = false
        window.contentMinSize = SettingsView.contentSize
        window.contentViewController = NSHostingController(rootView: view)
        settingsWindowController?.close()
        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func observeSettings() {
        settingsObservation = dependencies.settings.$settings.dropFirst().sink { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                await self.applySettings(settings)
            }
        }
    }

    private func applySettings(_ settings: ClipSettings) async {
        if !settings.rememberLastArea {
            lastAreaStore.clear()
        }
        if dependencies.launchConfiguration.allowsSystemIntegrations {
            do {
                try applicationBehavior.apply(settings)
            } catch {
                presentError(title: "Couldn’t Apply Settings", error: error)
            }
            do {
                try dependencies.shortcuts.registerShortcuts(
                    settings.shortcuts,
                    handler: { [weak self] action in
                        self?.handleGlobalShortcut(action)
                    }
                )
            } catch {
                presentError(title: "Couldn’t Register Global Shortcuts", error: error)
            }
        }
        await refreshMenuBarModel()
    }

    private func ensureScreenRecordingPermission() async -> Bool {
        let permission = dependencies.permissions.currentStatus(for: .screenRecording)
        let plan = ScreenRecordingPermissionPolicy.explicitCapturePlan(for: permission)
        if plan.canProceed { return true }

        if plan.shouldShowExplanation {
            let explanation = NSAlert()
            explanation.alertStyle = .informational
            explanation.messageText = String(localized: "Allow Screen Recording")
            explanation.informativeText = String(
                localized: "Clip needs Screen & System Audio Recording access to record only the area or display you choose. Recordings stay local on this Mac."
            )
            explanation.addButton(withTitle: String(localized: "Continue"))
            explanation.addButton(withTitle: String(localized: "Not Now"))
            guard explanation.runModal() == .alertFirstButtonReturn else { return false }
        }

        if plan.shouldRequestAccess,
           await dependencies.permissions.request(.screenRecording) == .granted {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Screen Recording Is Not Allowed")
        alert.informativeText = String(
            localized: "macOS must allow this exact Clip build. If Clip already appears enabled, turn it off and on again, or remove it and re-add /Applications/Clip.app. Then quit and reopen Clip."
        )
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(
               string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
           ) {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func ensureLiveShareScreenRecordingPermission() async -> Bool {
        let permission = dependencies.permissions.currentStatus(for: .screenRecording)
        let plan = ScreenRecordingPermissionPolicy.explicitCapturePlan(for: permission)
        if plan.canProceed { return true }

        if plan.shouldShowExplanation {
            let explanation = NSAlert()
            explanation.alertStyle = .informational
            explanation.messageText = String(localized: "Allow Screen Recording")
            explanation.informativeText = String(
                localized: "Clip needs Screen & System Audio Recording access to share only the windows or display you choose. Live Share sends selected video and optional system audio to connected viewers over encrypted WebRTC media transport."
            )
            explanation.addButton(withTitle: String(localized: "Continue"))
            explanation.addButton(withTitle: String(localized: "Not Now"))
            guard explanation.runModal() == .alertFirstButtonReturn else { return false }
        }

        if plan.shouldRequestAccess,
           await dependencies.permissions.request(.screenRecording) == .granted {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Screen Recording Is Not Allowed")
        alert.informativeText = String(
            localized: "Allow this exact Clip build in System Settings, then quit and reopen Clip before starting Live Share."
        )
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(
               string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
           ) {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    /// Resolves optional audio independently for this capture. Persisted user
    /// intent is left unchanged, but revoked permission or a missing default
    /// microphone can never prevent an otherwise valid video recording.
    private func resolvedCaptureSettings(_ requested: ClipSettings) async -> ClipSettings {
        var resolved = requested

        if resolved.audio.microphoneEnabled {
            var status = dependencies.permissions.currentStatus(for: .microphone)
            if status == .notDetermined {
                status = await dependencies.permissions.request(.microphone)
            }
            await dependencies.audio.refreshDevices()
            if status != .granted || dependencies.audio.defaultInputName == nil {
                resolved.audio.microphoneEnabled = false
                ClipLog.capture.warning(
                    "Microphone is unavailable for this session; continuing with video"
                )
            }
        }

        if resolved.audio.systemAudioEnabled {
            var status = dependencies.permissions.currentStatus(for: .systemAudio)
            if status == .notDetermined {
                status = await dependencies.permissions.request(.systemAudio)
            }
            if status != .granted {
                resolved.audio.systemAudioEnabled = false
                ClipLog.capture.warning(
                    "System audio is unavailable for this session; continuing with video"
                )
            }
        }

        return resolved
    }

    private func makeRecordingSnapshot(notice: String? = nil) -> RecordingPresentationSnapshot {
        let phase: RecordingPresentationPhase
        switch recordingState.phase {
        case .paused: phase = .paused
        case .finishing: phase = .finishing
        default: phase = .recording
        }
        let settings = activeCaptureSettings ?? dependencies.settings.settings
        return RecordingPresentationSnapshot(
            phase: phase,
            activeElapsedSeconds: (try? recordingState.activeDuration(at: currentInstant())) ?? 0,
            hasReceivedFirstFrame: recordingState.timeline.hasFrames,
            microphone: unavailableRecordingAudioSources.contains(.microphone)
                ? .unavailable(reason: String(localized: "Unavailable"))
                : settings.audio.microphoneEnabled
                    ? .active(detail: dependencies.audio.defaultInputName)
                    : .off,
            systemAudio: unavailableRecordingAudioSources.contains(.systemAudio)
                ? .unavailable(reason: String(localized: "Unavailable"))
                : settings.audio.systemAudioEnabled ? .active() : .off,
            notice: notice ?? recordingAudioNotice
        )
    }

    private func audioLossNotice() -> String? {
        switch (
            unavailableRecordingAudioSources.contains(.microphone),
            unavailableRecordingAudioSources.contains(.systemAudio)
        ) {
        case (true, true):
            String(localized: "Microphone and system audio became unavailable. Video recording continues.")
        case (true, false):
            String(localized: "Microphone became unavailable. Video recording continues without microphone audio.")
        case (false, true):
            String(localized: "System audio became unavailable. Video recording continues without system audio.")
        case (false, false):
            nil
        }
    }

    private func updateRecordingPresentation() {
        recordingPresentationModel?.update(makeRecordingSnapshot())
    }

    private func failRecording(code: RecordingFailureCode, error: any Error) throws {
        guard [.selecting, .countdown, .recording, .paused, .finishing].contains(recordingState.phase) else {
            return
        }
        _ = try recordingState.fail(
            RecordingFailure(
                code: code,
                technicalDescription: error.localizedDescription
            ),
            at: currentInstant()
        )
    }

    private func resetAfterTerminalState() {
        countdownController?.stopWithoutCallback()
        countdownController = nil
        selectionController?.dismissWithoutCallback()
        selectionController = nil
        applicationSelectionController?.dismissWithoutCallback()
        applicationSelectionController = nil
        regionOutlineController.hide()
        recordingPresentationModel?.cancelPendingAction()
        recordingPresentationModel = nil
        activeRecordingID = nil
        activeCaptureSettings = nil
        unavailableRecordingAudioSources.removeAll()
        recordingAudioNotice = nil
        if [.canceled, .failed, .preview].contains(recordingState.phase) {
            try? recordingState.reset()
        }
        if !isPreparingForTermination {
            installIdlePopover()
            Task { @MainActor [weak self] in
                await self?.refreshMenuBarModel()
            }
            updateStatusIcon(symbol: "record.circle", description: String(localized: "Clip"))
        }
    }

    private func currentInstant() throws -> RecordingInstant {
        try RecordingInstant(seconds: ProcessInfo.processInfo.systemUptime)
    }

    private func matchingScreen(displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return false }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }

    private func updateStatusIcon(symbol: String, description: String) {
        guard let button = statusItem?.button else { return }
        let image: NSImage?
        if symbol == "record.circle" {
            image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        } else {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        }
        image?.isTemplate = true
        button.image = image
    }

    private func updateLiveShareStatusIcon(_ status: LiveShareMenuBarStatus) {
        updateStatusIcon(
            symbol: status.symbolName,
            description: status.accessibilityDescription
        )
    }

    private func presentError(title: String, error: any Error) {
        let details = UserFacingErrorPresentation.details(for: error)
        ClipLog.lifecycle.error(
            "User-facing operation failed (\(title, privacy: .public)): \(details.technicalDescription, privacy: .private)"
        )
        guard !isPreparingForTermination else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details.message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}

private struct SharePreferences: Sendable {
    let retentionPolicy: HistoryRetentionPolicy
    let keepOriginalAfterExport: Bool
    let closePreviewAfterCopy: Bool

    init(settings: ClipSettings) {
        retentionPolicy = settings.historyRetention
        keepOriginalAfterExport = settings.keepOriginalAfterExport
        closePreviewAfterCopy = settings.automaticallyClosePreviewAfterCopy
    }
}

private struct CaptureStoppedError: LocalizedError, Sendable, TechnicalErrorDescriptionProviding {
    let message: String

    var errorDescription: String? {
        String(localized: "The screen capture stream ended unexpectedly.")
    }

    var technicalDescriptionForLogging: String {
        message.isEmpty ? "Screen capture stream stopped without a reason." : message
    }
}

private struct RecordingSavedPreviewDeferredError: LocalizedError, Sendable,
    TechnicalErrorDescriptionProviding {
    let technicalDescription: String

    var errorDescription: String? {
        String(
            localized: "The recording is safe in History. Finish the current Preview operation, then open the recording from History."
        )
    }

    var technicalDescriptionForLogging: String {
        "Recording import completed, but Preview presentation was deferred: \(technicalDescription)"
    }
}

private enum MenuCaptureCoordinatorError: LocalizedError, Sendable {
    case displayUnavailable
    case recordingUnavailable

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            String(localized: "The selected display is no longer available.")
        case .recordingUnavailable:
            String(localized: "The selected recording is no longer available.")
        }
    }
}

private enum ApplicationCaptureCoordinatorError: LocalizedError, Sendable {
    case noVisibleApplications

    var errorDescription: String? {
        String(localized: "No visible application windows are available to record.")
    }
}

private enum PreviewPresentationError: LocalizedError, Sendable {
    case operationInProgress

    var errorDescription: String? {
        String(localized: "Finish the current Preview operation before opening another recording.")
    }
}

private actor PreviewLifecycleContext {
    private var session: ManagedHistoryPreviewSession

    init(session: ManagedHistoryPreviewSession) {
        self.session = session
    }

    func currentSession() -> ManagedHistoryPreviewSession {
        session
    }

    func install(session: ManagedHistoryPreviewSession) {
        self.session = session
    }
}

@MainActor
private final class PreviewWindowDelegate: NSObject, NSWindowDelegate {
    weak var viewModel: PreviewViewModel?
    var allowClose = false

    init(viewModel: PreviewViewModel) {
        self.viewModel = viewModel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowClose else { return true }
        viewModel?.done()
        return false
    }
}

@MainActor
private final class PendingRetake {
    let originalRecording: PreviewRecording
    let context: PreviewLifecycleContext
    private var continuation: CheckedContinuation<PreviewRetakeResult?, any Error>?

    init(
        originalRecording: PreviewRecording,
        context: PreviewLifecycleContext,
        continuation: CheckedContinuation<PreviewRetakeResult?, any Error>
    ) {
        self.originalRecording = originalRecording
        self.context = context
        self.continuation = continuation
    }

    func succeed(_ result: PreviewRetakeResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func cancel() {
        continuation?.resume(returning: nil)
        continuation = nil
    }

    func fail(_ error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private enum PreviewRetakeCoordinatorError: LocalizedError, Sendable {
    case liveShareActive
    case retakeAlreadyActive
    case missingCapturePlan
    case displayUnavailable(String)
    case applicationUnavailable(String)
    case missingPendingRetake

    var errorDescription: String? {
        switch self {
        case .liveShareActive:
            String(localized: "End Live Share before starting a retake.")
        case .retakeAlreadyActive:
            String(localized: "A retake is already in progress.")
        case .missingCapturePlan:
            String(localized: "This recording does not contain enough capture information to retake it.")
        case let .displayUnavailable(display):
            String(localized: "The original display (\(display)) is no longer available.")
        case let .applicationUnavailable(application):
            String(localized: "\(application) has no visible windows on the original display.")
        case .missingPendingRetake:
            String(localized: "The retake finished after its Preview was closed.")
        }
    }
}
