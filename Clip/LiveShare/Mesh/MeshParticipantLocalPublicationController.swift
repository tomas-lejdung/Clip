import AppKit
import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import OSLog

@MainActor
struct MeshParticipantLocalPublicationOperations {
    var start: (
        ClipLiveShareSourceInstanceID,
        LiveShareCaptureDescriptor
    ) async throws -> Void
    var update: (
        ClipLiveShareSourceInstanceID,
        LiveShareCaptureDescriptor
    ) async throws -> Void
    var stop: (ClipLiveShareSourceInstanceID) async throws -> Void
    var stopAll: () async -> Void
    var setSystemAudio: (CaptureAudioSessionRequest?) async throws -> Void
    var applySettings: (LiveShareSettings) async throws -> Void

    init(
        start: @escaping (
            ClipLiveShareSourceInstanceID,
            LiveShareCaptureDescriptor
        ) async throws -> Void,
        update: @escaping (
            ClipLiveShareSourceInstanceID,
            LiveShareCaptureDescriptor
        ) async throws -> Void,
        stop: @escaping (ClipLiveShareSourceInstanceID) async throws -> Void,
        stopAll: @escaping () async -> Void,
        setSystemAudio: @escaping (
            CaptureAudioSessionRequest?
        ) async throws -> Void,
        applySettings: @escaping (LiveShareSettings) async throws -> Void
    ) {
        self.start = start
        self.update = update
        self.stop = stop
        self.stopAll = stopAll
        self.setSystemAudio = setSystemAudio
        self.applySettings = applySettings
    }
}

struct MeshParticipantLocalPublicationSnapshot: Equatable {
    var fullscreen = LiveShareFullscreenViewSnapshot(
        isOn: false,
        displayName: String(localized: "Main Display")
    )
    var canShareFocusedWindow = false
    var focusedWindowDescription: String?
    var availableWindows: [LiveShareAvailableWindowViewSnapshot] = []
    var canAddWindow = false
    var settings = LiveShareSettingsViewSnapshot()
}

struct MeshParticipantLocalCursorSnapshot: Equatable {
    let sourceInstanceID: ClipLiveShareSourceInstanceID
    let streamID: ClipLiveShareStreamID
    let appKitFrame: CGRect
    let updatesPerSecond: Int
}

struct MeshParticipantFocusedWindowControlSnapshot: Equatable {
    let sourceID: String
    let sourceInstanceID: ClipLiveShareSourceInstanceID?
    let applicationName: String
    let windowTitle: String
    let appKitFrame: CGRect
    let state: MeshFocusedWindowControlState
}

struct MeshParticipantLocalStatusSnapshot: Equatable {
    let windowSourceStatuses: [LiveShareSourceViewStatus]
    let fullscreen: LiveShareFullscreenViewSnapshot
}

/// One participant-scoped owner for source discovery, selection, capture and
/// settings. Creator and joiners instantiate this exact same controller. Room
/// leadership is deliberately absent: publishing local media never depends on
/// who currently signs membership.
@MainActor
final class MeshParticipantLocalPublicationController {
    private enum SourceManagement {
        case manual
        case autoShared(lastFocusedOrdinal: UInt64)
    }

    private struct ActiveSource {
        var instanceID: ClipLiveShareSourceInstanceID
        var source: LiveShareSource
        var management: SourceManagement
        var window: ShareableCaptureWindow?
        var display: ShareableCaptureDisplay?
        var descriptor: LiveShareCaptureDescriptor
        var status: LiveShareSourceViewStatus
    }

    private struct SystemAudioReconciliationOutcome {
        var committedSettings: LiveShareSettings
        var failure: (any Error)?
    }

    nonisolated private static let logger = Logger(
        subsystem: ApplicationDirectories.bundleIdentifier,
        category: "live-share-mesh-local-publication"
    )

    private let discovery: any CaptureContentDiscovering
    private let operations: MeshParticipantLocalPublicationOperations
    private let persistSettings: (LiveShareSettings) -> Void
    private let onChange: (MeshParticipantLocalPublicationSnapshot) -> Void
    private let onFailure: (String) -> Void
    private let observesFocusedWindow: Bool
    private let audioRequestIdentifier = UUID()
    private let maximumActiveSources: Int

    /// The value currently presented by the controls. It may be optimistic
    /// while the serialized media transaction is still in flight.
    private var settings: LiveShareSettings
    /// The last settings snapshot that every local media operation accepted.
    /// Persistence and rollback are anchored here so a partial peer failure
    /// cannot make the UI, defaults, and active transports disagree.
    private var appliedSettings: LiveShareSettings
    private var activeByInstanceID:
        [ClipLiveShareSourceInstanceID: ActiveSource] = [:]
    private var instanceIDBySourceID:
        [LiveShareSourceID: ClipLiveShareSourceInstanceID] = [:]
    private var windowsByID: [LiveShareWindowID: ShareableCaptureWindow] = [:]
    private var availableWindows: [ShareableCaptureWindow] = []
    private var focusedWindow: FocusedLiveShareWindow?
    private var refreshTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var transitionGeneration: UInt64 = 0
    private var settingsRevision: UInt64 = 0
    private var settingsTransactionInFlight = false
    private var focusOrdinal: UInt64 = 0
    private var isRunning = false

    private lazy var focusedWindowMonitor = LiveShareFocusedWindowMonitor(
        discovery: discovery,
        excludedBundleIdentifier: ApplicationDirectories.bundleIdentifier,
        handler: { [weak self] focused in
            self?.focusedWindowDidChange(focused)
        }
    )

    init(
        settings: LiveShareSettings,
        discovery: any CaptureContentDiscovering,
        maximumActiveSources: Int,
        operations: MeshParticipantLocalPublicationOperations,
        observesFocusedWindow: Bool = true,
        persistSettings: @escaping (LiveShareSettings) -> Void,
        onChange: @escaping (
            MeshParticipantLocalPublicationSnapshot
        ) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.settings = settings
        appliedSettings = settings
        self.discovery = discovery
        self.operations = operations
        self.observesFocusedWindow = observesFocusedWindow
        self.persistSettings = persistSettings
        self.onChange = onChange
        self.onFailure = onFailure
        self.maximumActiveSources = min(
            max(1, maximumActiveSources),
            ClipLiveShareNativeV3.maximumSourcesPerParticipant
        )
    }

    var activeSourceSnapshots: [MeshRoomLocalSourceSnapshot] {
        activeByInstanceID.values
            .sorted { $0.descriptor.stream.order < $1.descriptor.stream.order }
            .map { source in
                MeshRoomLocalSourceSnapshot(
                    id: source.instanceID.rawValue,
                    applicationName: source.descriptor.stream.appName,
                    windowTitle: source.descriptor.stream.windowName,
                    status: source.status,
                    isFocused: source.descriptor.stream.focused
                )
            }
    }

    var cursorSnapshot: MeshParticipantLocalCursorSnapshot? {
        guard let active = activeByInstanceID.values.first(where: {
            $0.status == .live && $0.descriptor.stream.focused
        }) else {
            return nil
        }
        let appKitFrame: CGRect?
        switch active.source {
        case let .window(window):
            appKitFrame =
                focusedWindow?.window.id == window.id.rawValue
                    ? focusedWindow?.appKitFrame
                    : nil
        case let .fullscreen(display):
            appKitFrame = NSScreen.screens.first {
                ($0.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber)?.uint32Value == display.id.rawValue
            }?.frame
        }
        guard let appKitFrame else { return nil }
        return MeshParticipantLocalCursorSnapshot(
            sourceInstanceID: active.instanceID,
            streamID: active.descriptor.stream.id,
            appKitFrame: appKitFrame,
            updatesPerSecond:
                settings.cursorUpdatesMatchFrameRate
                    ? settings.frameRate.rawValue
                    : 30
        )
    }

    var focusedWindowControlSnapshot:
        MeshParticipantFocusedWindowControlSnapshot?
    {
        guard
            isRunning,
            fullscreenActiveSource == nil,
            let focusedWindow
        else {
            return nil
        }
        let sourceID = LiveShareSourceID.window(
            .init(rawValue: focusedWindow.window.id)
        )
        let instanceID = instanceIDBySourceID[sourceID]
        let state: MeshFocusedWindowControlState
        if let instanceID, let active = activeByInstanceID[instanceID] {
            switch active.status {
            case .starting:
                state = .starting
            case .live:
                state = .live
            case .stopping:
                state = .stopping
            case .failed:
                state = .shareable
            }
        } else {
            state = .shareable
        }
        return MeshParticipantFocusedWindowControlSnapshot(
            sourceID: LiveShareCapturePolicy.sourceIdentifier(sourceID),
            sourceInstanceID: instanceID,
            applicationName: focusedWindow.window.applicationName,
            windowTitle: focusedWindow.window.title,
            appKitFrame: focusedWindow.appKitFrame,
            state: state
        )
    }

    var localStatusSnapshot: MeshParticipantLocalStatusSnapshot {
        MeshParticipantLocalStatusSnapshot(
            windowSourceStatuses: activeByInstanceID.values
                .filter {
                    if case .window = $0.source { true } else { false }
                }
                .sorted {
                    $0.descriptor.stream.order
                        < $1.descriptor.stream.order
                }
                .map(\.status),
            fullscreen: LiveShareFullscreenViewSnapshot(
                isOn: fullscreenActiveSource != nil,
                displayName:
                    fullscreenActiveSource?.descriptor.stream.windowName
                    ?? screenName(displayID: CGMainDisplayID()),
                isEnabled: isRunning
            )
        )
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if observesFocusedWindow {
            focusedWindowMonitor.start()
        }
        refreshTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, isRunning {
                await refreshShareableContent()
                do {
                    try await Task.sleep(for: .milliseconds(750))
                } catch {
                    return
                }
            }
        }
        publish()
    }

    func stop() async {
        guard isRunning || !activeByInstanceID.isEmpty else { return }
        isRunning = false
        transitionGeneration &+= 1
        transitionTask?.cancel()
        transitionTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        if observesFocusedWindow {
            focusedWindowMonitor.stop()
        }
        activeByInstanceID.removeAll()
        instanceIDBySourceID.removeAll()
        await operations.stopAll()
        try? await operations.setSystemAudio(nil)
        publish()
    }

    func shareFocusedWindow() {
        guard let window = focusedWindow?.window else { return }
        enqueue { controller in
            await controller.share(
                window: window,
                management: .manual
            )
        }
    }

    func shareWindow(identifier: String) {
        guard
            case let .window(windowID)? =
                LiveShareCapturePolicy.sourceID(from: identifier),
            let window = windowsByID[windowID]
        else { return }
        enqueue { controller in
            await controller.share(
                window: window,
                management: .manual
            )
        }
    }

    func setFullscreenEnabled(_ enabled: Bool) {
        enqueue { controller in
            if enabled {
                await controller.shareFullscreen()
            } else if let active = controller.activeByInstanceID.values
                .first(where: {
                    if case .fullscreen = $0.source { true } else { false }
                }) {
                await controller.stopSource(active.instanceID)
            }
        }
    }

    func stopSource(_ instanceID: ClipLiveShareSourceInstanceID) {
        enqueue { controller in
            await controller.stopSource(instanceID)
        }
    }

    func stopAllMedia() {
        enqueue { controller in
            let existing = Array(controller.activeByInstanceID.keys)
            for instanceID in existing {
                await controller.stopSource(
                    instanceID,
                    reconcilesAudio: false
                )
            }
            await controller.reconcileSystemAudio()
        }
    }

    func captureSourceFailed(
        _ instanceID: ClipLiveShareSourceInstanceID,
        message: String
    ) {
        enqueue { controller in
            guard let active = controller.activeByInstanceID.removeValue(
                forKey: instanceID
            ) else { return }
            controller.instanceIDBySourceID[active.source.id] = nil
            await controller.reconcileSystemAudio()
            controller.report(message: message)
        }
    }

    func systemAudioCaptureFailed(message: String) {
        let observedSettingsRevision = settingsRevision
        enqueue { controller in
            var committed = controller.appliedSettings
            committed.systemAudioEnabled = false
            controller.appliedSettings = committed
            controller.persistSettings(committed)
            if controller.settingsRevision == observedSettingsRevision {
                controller.settings.systemAudioEnabled = false
            }
            try? await controller.operations.setSystemAudio(nil)
            controller.report(message: message)
        }
    }

    func settlePendingOperations() async {
        await transitionTask?.value
    }

    func updateSettings(_ view: LiveShareSettingsViewSnapshot) {
        var next = settings
        next.quality = view.quality
        next.frameRate = view.frameRate
        next.videoCodec = view.codec.codec
        next.colorMode = view.colorMode
        next.systemAudioEnabled = view.systemAudioEnabled
        next.excludedAudioApplicationBundleIdentifiers =
            normalizedBundleIdentifiers(view.excludedAudioApplicationIDs)
        next.cursorUpdatesMatchFrameRate =
            view.cursorUpdatesMatchFrameRate
        next.prioritizeFocusedWindow = view.prioritizeFocusedWindow
        next.encodingMode = view.mode
        next.advancedVideoSettings = view.advancedVideoSettings
        next.autoShareFocusedWindows = view.autoShareFocusedWindows
        updateSettings(next)
    }

    private func updateSettings(_ next: LiveShareSettings) {
        guard next != settings else { return }
        settingsRevision &+= 1
        let revision = settingsRevision
        settings = next
        publish()
        enqueue { controller in
            controller.settingsTransactionInFlight = true
            defer { controller.settingsTransactionInFlight = false }
            let previous = controller.appliedSettings
            do {
                try await controller.operations.applySettings(next)
                if previous.frameRate != next.frameRate
                    || previous.videoCodec != next.videoCodec
                    || previous.colorMode != next.colorMode {
                    try await controller.refreshActiveDescriptors(using: next)
                }
                let audio = try await controller.reconcileSystemAudio(
                    using: next
                )
                let committed = audio.committedSettings
                controller.appliedSettings = committed
                controller.persistSettings(committed)
                if controller.settingsRevision == revision {
                    controller.settings = committed
                }
                if next.autoShareFocusedWindows,
                   !previous.autoShareFocusedWindows,
                   controller.fullscreenActiveSource == nil,
                   let window = controller.focusedWindow?.window {
                    await controller.autoShare(
                        window: window,
                        focusedOrdinal: controller.nextFocusOrdinal()
                    )
                }
                if let failure = audio.failure {
                    controller.report(failure)
                } else {
                    controller.publish()
                }
            } catch {
                // `applySettings` spans every direct peer and can fail after
                // one transport has already changed. Reapply the last fully
                // accepted snapshot before exposing the failure. This also
                // restores `settings`, allowing the same user selection to be
                // retried instead of being discarded as a no-op.
                do {
                    try await controller.operations.applySettings(previous)
                    try await controller.refreshActiveDescriptors(
                        using: previous
                    )
                    let audio = try await controller.reconcileSystemAudio(
                        using: previous
                    )
                    if audio.committedSettings != previous {
                        controller.appliedSettings = audio.committedSettings
                        controller.persistSettings(audio.committedSettings)
                    }
                    if let failure = audio.failure {
                        Self.logger.error(
                            "System audio could not be restored while rolling back local mesh settings: \(failure.localizedDescription, privacy: .public)"
                        )
                    }
                } catch {
                    Self.logger.error(
                        "Could not roll back local mesh settings: \(error.localizedDescription, privacy: .public)"
                    )
                }
                if controller.settingsRevision == revision {
                    controller.settings = controller.appliedSettings
                }
                controller.report(error)
            }
        }
    }

    func focusedWindowDidChange(
        _ next: FocusedLiveShareWindow?
    ) {
        focusedWindow = next
        if let window = next?.window {
            windowsByID[LiveShareWindowID(rawValue: window.id)] = window
        }
        enqueue { controller in
            let ordinal = controller.nextFocusOrdinal()
            await controller.reconcileFocus()
            if controller.settings.autoShareFocusedWindows,
               controller.fullscreenActiveSource == nil,
               let window = controller.focusedWindow?.window {
                await controller.autoShare(
                    window: window,
                    focusedOrdinal: ordinal
                )
            }
        }
        publish()
    }

    private func share(
        window: ShareableCaptureWindow,
        management: SourceManagement
    ) async {
        guard isRunning,
              ShareableApplicationWindowEligibility.isEligible(
                  window,
                  minimumPointSize: CGSize(width: 100, height: 100)
              ) else { return }
        let sourceID = LiveShareSourceID.window(
            LiveShareWindowID(rawValue: window.id)
        )
        if let existingID = instanceIDBySourceID[sourceID] {
            if case .manual = management {
                activeByInstanceID[existingID]?.management = .manual
            } else if case let .autoShared(lastFocusedOrdinal) = management,
                      case .autoShared =
                          activeByInstanceID[existingID]?.management {
                activeByInstanceID[existingID]?.management = .autoShared(
                    lastFocusedOrdinal: lastFocusedOrdinal
                )
            }
            await reconcileFocus()
            return
        }
        if let fullscreenActiveSource {
            await stopSource(
                fullscreenActiveSource.instanceID,
                reconcilesAudio: false
            )
        }
        guard activeByInstanceID.count < maximumActiveSources else {
            NSSound.beep()
            publish()
            return
        }

        let source = LiveShareSource.window(
            .init(
                id: .init(rawValue: window.id),
                windowName: window.title,
                appName: window.applicationName
            )
        )
        let instanceID = ClipLiveShareSourceInstanceID.random()
        let isFocused = focusedWindow?.window.id == window.id
        do {
            let descriptor = try makeDescriptor(
                source: source,
                window: window,
                display: nil,
                isFocused: isFocused,
                order: activeByInstanceID.count
            )
            activeByInstanceID[instanceID] = ActiveSource(
                instanceID: instanceID,
                source: source,
                management: management,
                window: window,
                display: nil,
                descriptor: descriptor,
                status: .starting
            )
            instanceIDBySourceID[source.id] = instanceID
            publish()
            try await operations.start(
                instanceID,
                descriptor
            )
            guard activeByInstanceID[instanceID] != nil else { return }
            activeByInstanceID[instanceID]?.status = .live
            await reconcileFocus()
            await reconcileSystemAudio()
            publish()
        } catch {
            activeByInstanceID[instanceID] = nil
            instanceIDBySourceID[source.id] = nil
            report(error)
        }
    }

    private func autoShare(
        window: ShareableCaptureWindow,
        focusedOrdinal: UInt64
    ) async {
        let sourceID = LiveShareSourceID.window(
            .init(rawValue: window.id)
        )
        if let existingID = instanceIDBySourceID[sourceID] {
            if case .autoShared =
                activeByInstanceID[existingID]?.management {
                activeByInstanceID[existingID]?.management = .autoShared(
                    lastFocusedOrdinal: focusedOrdinal
                )
            }
            await reconcileFocus()
            return
        }

        if activeByInstanceID.count >= maximumActiveSources {
            let autoSharedSources = activeByInstanceID.values.filter {
                if case .autoShared = $0.management {
                    true
                } else {
                    false
                }
            }
            guard let replacement = autoSharedSources.min(
                by: autoShareReplacementOrder
            ) else {
                NSSound.beep()
                publish()
                return
            }
            await stopSource(
                replacement.instanceID,
                reconcilesAudio: false
            )
        }

        await share(
            window: window,
            management: .autoShared(
                lastFocusedOrdinal: focusedOrdinal
            )
        )
        await reconcileSystemAudio()
    }

    private func shareFullscreen() async {
        guard isRunning else { return }
        var pendingInstanceID: ClipLiveShareSourceInstanceID?
        var pendingSourceID: LiveShareSourceID?
        do {
            let content = try await discovery.shareableContent(
                excludingBundleIdentifier:
                    ApplicationDirectories.bundleIdentifier
            )
            guard let display =
                LiveShareCapturePolicy.preferredFullscreenDisplay(
                    from: content.displays,
                    focusedWindowFrame: focusedWindow?.window.frame,
                    primaryDisplayID: CGMainDisplayID()
                )
            else {
                throw CaptureSessionError.displayUnavailable(
                    CGMainDisplayID()
                )
            }
            await stopAllSourcesWithoutAudioReconciliation()
            let displayName = screenName(displayID: display.id)
            let source = LiveShareSource.fullscreen(
                .init(
                    id: .init(rawValue: display.id),
                    displayName: displayName
                )
            )
            let instanceID = ClipLiveShareSourceInstanceID.random()
            pendingInstanceID = instanceID
            pendingSourceID = source.id
            let descriptor = try makeDescriptor(
                source: source,
                window: nil,
                display: display,
                isFocused: true,
                order: 0
            )
            activeByInstanceID[instanceID] = ActiveSource(
                instanceID: instanceID,
                source: source,
                management: .manual,
                window: nil,
                display: display,
                descriptor: descriptor,
                status: .starting
            )
            instanceIDBySourceID[source.id] = instanceID
            publish()
            try await operations.start(instanceID, descriptor)
            guard activeByInstanceID[instanceID] != nil else { return }
            activeByInstanceID[instanceID]?.status = .live
            await reconcileSystemAudio()
            publish()
        } catch {
            if let pendingInstanceID {
                activeByInstanceID[pendingInstanceID] = nil
            }
            if let pendingSourceID {
                instanceIDBySourceID[pendingSourceID] = nil
            }
            await reconcileSystemAudio()
            report(error)
        }
    }

    private func stopSource(
        _ instanceID: ClipLiveShareSourceInstanceID,
        reconcilesAudio: Bool = true
    ) async {
        guard var active = activeByInstanceID[instanceID] else { return }
        active.status = .stopping
        activeByInstanceID[instanceID] = active
        publish()
        do {
            try await operations.stop(instanceID)
        } catch {
            Self.logger.error(
                "Could not stop local mesh source: \(error.localizedDescription, privacy: .public)"
            )
        }
        activeByInstanceID[instanceID] = nil
        instanceIDBySourceID[active.source.id] = nil
        if reconcilesAudio { await reconcileSystemAudio() }
        await reconcileFocus()
        publish()
    }

    private func stopAllSourcesWithoutAudioReconciliation() async {
        for instanceID in Array(activeByInstanceID.keys) {
            await stopSource(instanceID, reconcilesAudio: false)
        }
    }

    private func reconcileFocus() async {
        guard fullscreenActiveSource == nil else { return }
        let focusedWindowID = focusedWindow?.window.id
        for instanceID in Array(activeByInstanceID.keys) {
            guard var active = activeByInstanceID[instanceID],
                  case let .window(windowSource) = active.source else {
                continue
            }
            let isFocused = windowSource.id.rawValue == focusedWindowID
            guard active.descriptor.stream.focused != isFocused else {
                continue
            }
            do {
                let descriptor = try makeDescriptor(
                    source: active.source,
                    window: active.window,
                    display: nil,
                    isFocused: isFocused,
                    order: active.descriptor.stream.order,
                    existingStream: active.descriptor.stream
                )
                try await operations.update(
                    instanceID,
                    descriptor
                )
                active.descriptor = descriptor
                activeByInstanceID[instanceID] = active
            } catch {
                report(error)
            }
        }
        publish()
    }

    private func refreshShareableContent() async {
        guard isRunning else { return }
        do {
            let content = try await discovery.shareableContent(
                excludingBundleIdentifier:
                    ApplicationDirectories.bundleIdentifier
            )
            guard isRunning, !Task.isCancelled else { return }
            availableWindows = content.windows.filter {
                ShareableApplicationWindowEligibility.isEligible(
                    $0,
                    minimumPointSize: CGSize(width: 100, height: 100)
                )
            }
            for window in availableWindows {
                windowsByID[.init(rawValue: window.id)] = window
            }

            for instanceID in Array(activeByInstanceID.keys) {
                guard var active = activeByInstanceID[instanceID] else {
                    continue
                }
                switch active.source {
                case let .window(source):
                    guard let window = content.windows.first(where: {
                        $0.id == source.id.rawValue
                    }) else {
                        await stopSource(instanceID)
                        continue
                    }
                    active.window = window
                    activeByInstanceID[instanceID] = active
                case let .fullscreen(source):
                    guard let display = content.displays.first(where: {
                        $0.id == source.id.rawValue
                    }) else {
                        await stopSource(instanceID)
                        continue
                    }
                    active.display = display
                    activeByInstanceID[instanceID] = active
                }
            }
            guard !settingsTransactionInFlight else {
                publish()
                return
            }
            await refreshActiveDescriptors()
            await reconcileSystemAudio()
            publish()
        } catch {
            Self.logger.debug(
                "Could not refresh mesh shareable content: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func refreshActiveDescriptors() async {
        do {
            try await refreshActiveDescriptors(using: appliedSettings)
        } catch {
            report(error)
        }
    }

    /// Updates the complete active-source set as one local settings
    /// transaction. Any source accepted before a later failure is restored to
    /// its original descriptor before the error escapes to the settings
    /// rollback path.
    private func refreshActiveDescriptors(
        using mediaSettings: LiveShareSettings
    ) async throws {
        var updated: [
            (ClipLiveShareSourceInstanceID, LiveShareCaptureDescriptor)
        ] = []
        do {
            for instanceID in Array(activeByInstanceID.keys) {
                guard var active = activeByInstanceID[instanceID] else {
                    continue
                }
                let previous = active.descriptor
                let next = try makeDescriptor(
                    source: active.source,
                    window: active.window,
                    display: active.display,
                    isFocused: active.descriptor.stream.focused,
                    order: active.descriptor.stream.order,
                    existingStream: active.descriptor.stream,
                    using: mediaSettings
                )
                guard next != active.descriptor else { continue }
                try await operations.update(
                    instanceID,
                    next
                )
                active.descriptor = next
                activeByInstanceID[instanceID] = active
                updated.append((instanceID, previous))
            }
        } catch {
            for (instanceID, previous) in updated.reversed() {
                do {
                    try await operations.update(instanceID, previous)
                    activeByInstanceID[instanceID]?.descriptor = previous
                } catch {
                    Self.logger.error(
                        "Could not roll back a local mesh capture descriptor: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            publish()
            throw error
        }
        publish()
    }

    private func reconcileSystemAudio() async {
        let target = appliedSettings
        do {
            let outcome = try await reconcileSystemAudio(using: target)
            if outcome.committedSettings != target {
                appliedSettings = outcome.committedSettings
                persistSettings(outcome.committedSettings)
                if settings == target {
                    settings = outcome.committedSettings
                }
            }
            if let failure = outcome.failure {
                report(failure)
            } else {
                publish()
            }
        } catch {
            report(error)
        }
    }

    /// Applies audio for the supplied transaction snapshot rather than the
    /// potentially newer optimistic UI state. Failure to enable audio is a
    /// valid committed result with audio disabled, provided the disabled
    /// state itself can be applied successfully.
    private func reconcileSystemAudio(
        using mediaSettings: LiveShareSettings
    ) async throws -> SystemAudioReconciliationOutcome {
        let sourceSelection = selection
        let request = LiveShareCapturePolicy.captureAudioRequest(
            systemAudioEnabled: mediaSettings.systemAudioEnabled,
            sources: sourceSelection,
            knownWindows: windowsByID,
            filterDisplayID: CGMainDisplayID(),
            clipBundleIdentifier: ApplicationDirectories.bundleIdentifier,
            excludedAudioApplicationBundleIdentifiers:
                mediaSettings.excludedAudioApplicationBundleIdentifiers,
            filterApplicationProcessIdentifiers:
                audioFilterProcessIdentifiers(
                    excludedBundleIdentifiers:
                        mediaSettings
                            .excludedAudioApplicationBundleIdentifiers
                ),
            requestIdentifier: audioRequestIdentifier
        )
        do {
            try await operations.setSystemAudio(request)
            return SystemAudioReconciliationOutcome(
                committedSettings: mediaSettings,
                failure: nil
            )
        } catch {
            guard mediaSettings.systemAudioEnabled else { throw error }
            // A failed enable request must not leave an older capture alive.
            // Only commit the deliberate disabled fallback after that state
            // has itself been accepted by the media layer.
            try await operations.setSystemAudio(nil)
            var committed = mediaSettings
            committed.systemAudioEnabled = false
            return SystemAudioReconciliationOutcome(
                committedSettings: committed,
                failure: error
            )
        }
    }

    private func makeDescriptor(
        source: LiveShareSource,
        window: ShareableCaptureWindow?,
        display: ShareableCaptureDisplay?,
        isFocused: Bool,
        order: Int,
        existingStream: ClipLiveShareStreamDescriptor? = nil,
        using mediaSettings: LiveShareSettings? = nil
    ) throws -> LiveShareCaptureDescriptor {
        let mediaSettings = mediaSettings ?? appliedSettings
        let sourceWidth: Int
        let sourceHeight: Int
        let pointWidth: Int
        let pointHeight: Int
        let target: CaptureTarget
        let applicationName: String
        let windowTitle: String
        let resolution: CaptureVideoResolution

        switch source {
        case let .window(source):
            guard let window, window.id == source.id.rawValue else {
                throw CaptureSessionError.windowUnavailable(
                    source.id.rawValue
                )
            }
            sourceWidth = window.pixelWidth
            sourceHeight = window.pixelHeight
            pointWidth = window.capturePointWidth
            pointHeight = window.capturePointHeight
            target = .window(id: window.id)
            applicationName = source.appName
            windowTitle = source.windowName
            resolution = LiveShareCapturePolicy.windowCaptureResolution(
                sourcePixelWidth: sourceWidth,
                sourcePixelHeight: sourceHeight,
                sourcePointWidth: pointWidth,
                sourcePointHeight: pointHeight
            )
        case let .fullscreen(source):
            guard let display, display.id == source.id.rawValue else {
                throw CaptureSessionError.displayUnavailable(
                    source.id.rawValue
                )
            }
            sourceWidth = display.pixelWidth
            sourceHeight = display.pixelHeight
            pointWidth = max(1, Int(display.frame.width.rounded()))
            pointHeight = max(1, Int(display.frame.height.rounded()))
            target = .display(
                id: display.id,
                excludedBundleIdentifier:
                    ApplicationDirectories.bundleIdentifier
            )
            applicationName = String(localized: "Fullscreen")
            windowTitle = source.displayName
            resolution = .best
        }

        let captureGeometry = LiveShareCapturePolicy.captureGeometry(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            codec: mediaSettings.videoCodec,
            framesPerSecond: mediaSettings.frameRate.rawValue
        )
        let streamGeometry = LiveShareCapturePolicy.streamGeometry(
            captureGeometry: captureGeometry,
            codec: mediaSettings.videoCodec
        )
        let stream = try ClipLiveShareStreamDescriptor(
            id: existingStream?.id ?? .random(),
            mediaTrackID: existingStream?.mediaTrackID ?? .random(),
            active: true,
            focused: isFocused,
            appName: applicationName,
            windowName: windowTitle,
            width: streamGeometry.width,
            height: streamGeometry.height,
            order: min(
                max(0, order),
                ClipLiveShareNativeV3.maximumSourcesPerParticipant - 1
            ),
            sourcePointWidth: pointWidth,
            sourcePointHeight: pointHeight
        )
        return LiveShareCaptureDescriptor(
            source: source,
            target: target,
            sourcePixelWidth: sourceWidth,
            sourcePixelHeight: sourceHeight,
            video: LiveShareCapturePolicy.captureVideoConfiguration(
                width: captureGeometry.width,
                height: captureGeometry.height,
                framesPerSecond: mediaSettings.frameRate.rawValue,
                codec: mediaSettings.videoCodec,
                colorMode: mediaSettings.colorMode,
                showsCursor: isFocused,
                captureResolution: resolution
            ),
            stream: stream
        )
    }

    private var selection: LiveShareSourceSelection {
        let sources = activeByInstanceID.values.map(\.source)
        let fullscreen = sources.compactMap {
            if case let .fullscreen(source) = $0 { source } else { nil }
        }.first
        let windows = sources.compactMap {
            if case let .window(source) = $0 { source } else { nil }
        }
        return (try? LiveShareSourceSelection(
            windows: fullscreen == nil ? windows : [],
            fullscreen: fullscreen
        )) ?? .empty
    }

    private var fullscreenActiveSource: ActiveSource? {
        activeByInstanceID.values.first {
            if case .fullscreen = $0.source { true } else { false }
        }
    }

    private func audioFilterProcessIdentifiers(
        excludedBundleIdentifiers: Set<String>
    ) -> Set<pid_t> {
        let candidates = NSWorkspace.shared.runningApplications.compactMap {
            application -> LiveShareCaptureAudioApplicationProcessCandidate? in
            guard !application.isTerminated,
                  let bundleIdentifier = application.bundleIdentifier else {
                return nil
            }
            return .init(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
        }
        return LiveShareCapturePolicy.audioFilterProcessIdentifiers(
            candidates: candidates,
            excludedBundleIdentifiers: excludedBundleIdentifiers,
            clipBundleIdentifier: ApplicationDirectories.bundleIdentifier
        )
    }

    private func audioApplications()
        -> [LiveShareAudioApplicationViewSnapshot] {
        let candidates = NSWorkspace.shared.runningApplications
            .filter {
                !$0.isTerminated && $0.activationPolicy == .regular
            }
            .compactMap {
                application -> LiveShareCaptureAudioApplicationCandidate? in
                guard let bundleIdentifier =
                    application.bundleIdentifier else { return nil }
                return .init(
                    bundleIdentifier: bundleIdentifier,
                    name: application.localizedName ?? bundleIdentifier,
                    applicationPath: application.bundleURL?.path
                )
            }
        return LiveShareCapturePolicy.audioExclusionApplications(
            candidates: candidates,
            selectedBundleIdentifiers:
                settings.excludedAudioApplicationBundleIdentifiers,
            clipBundleIdentifier: ApplicationDirectories.bundleIdentifier
        )
    }

    private func publish() {
        let fullscreen = fullscreenActiveSource
        let sharedWindowIDs = Set(
            activeByInstanceID.values.compactMap {
                if case let .window(source) = $0.source {
                    source.id
                } else {
                    nil
                }
            }
        )
        let available = availableWindows
            .filter {
                !sharedWindowIDs.contains(.init(rawValue: $0.id))
            }
            .map {
                LiveShareAvailableWindowViewSnapshot(
                    id: LiveShareCapturePolicy.sourceIdentifier(
                        .window(.init(rawValue: $0.id))
                    ),
                    applicationName: $0.applicationName,
                    windowTitle: $0.title.isEmpty
                        ? String(localized: "Untitled Window")
                        : $0.title,
                    applicationPath: NSRunningApplication(
                        processIdentifier: $0.processID
                    )?.bundleURL?.path
                )
            }
        let snapshot = MeshParticipantLocalPublicationSnapshot(
            fullscreen: .init(
                isOn: fullscreen != nil,
                displayName: fullscreen?.descriptor.stream.windowName
                    ?? screenName(displayID: CGMainDisplayID()),
                isEnabled: isRunning,
                detail: activeByInstanceID.values.contains(where: {
                    if case .window = $0.source { true } else { false }
                })
                    ? String(
                        localized:
                            "Starting fullscreen stops the current window shares."
                    )
                    : nil
            ),
            canShareFocusedWindow:
                isRunning
                && focusedWindow != nil
                && fullscreen == nil,
            focusedWindowDescription: focusedWindow.map {
                [$0.window.applicationName, $0.window.title]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            },
            availableWindows: available,
            canAddWindow:
                isRunning
                && fullscreen == nil
                && activeByInstanceID.count < maximumActiveSources
                && !available.isEmpty,
            settings: makeSettingsSnapshot(fullscreenActive: fullscreen != nil)
        )
        onChange(snapshot)
    }

    private func makeSettingsSnapshot(
        fullscreenActive: Bool
    ) -> LiveShareSettingsViewSnapshot {
        var rates: Set<LiveShareFrameRate> = [.fifteen, .thirty]
        if NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 30 >= 60 {
            rates.insert(.sixty)
        }
        return LiveShareSettingsViewSnapshot(
            quality: settings.quality,
            frameRate: settings.frameRate,
            codec: .init(
                codec: settings.videoCodec,
                acceleration:
                    settings.videoCodec == .h264
                        ? .hardware
                        : .software
            ),
            colorMode: settings.colorMode,
            systemAudioEnabled: settings.systemAudioEnabled,
            audioExclusionApplications: audioApplications(),
            excludedAudioApplicationIDs:
                settings.excludedAudioApplicationBundleIdentifiers,
            cursorUpdatesMatchFrameRate:
                settings.cursorUpdatesMatchFrameRate,
            prioritizeFocusedWindow:
                settings.prioritizeFocusedWindow,
            mode: settings.encodingMode,
            advancedVideoSettings: settings.advancedVideoSettings,
            autoShareFocusedWindows: settings.autoShareFocusedWindows,
            canChangeQuality: isRunning,
            canChangeFrameRate: isRunning,
            availableFrameRates: rates,
            canChangeCodec: isRunning,
            canChangeColorMode: isRunning,
            canChangeSystemAudio: isRunning,
            canChangeAudioExclusions: isRunning && fullscreenActive,
            canChangeCursorUpdateRate: isRunning,
            canChangePrioritizeFocusedWindow: isRunning,
            canChangeMode: isRunning,
            canChangeAutoShare: isRunning && !fullscreenActive
        )
    }

    private func enqueue(
        _ operation: @escaping @MainActor (
            MeshParticipantLocalPublicationController
        ) async -> Void
    ) {
        let previous = transitionTask
        let generation = transitionGeneration
        transitionTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled,
                  generation == transitionGeneration,
                  isRunning else { return }
            await operation(self)
        }
    }

    private func report(_ error: any Error) {
        let message = UserFacingErrorPresentation.details(for: error).message
        Self.logger.error(
            "Local mesh publication failed: \(error.localizedDescription, privacy: .public)"
        )
        onFailure(message)
        publish()
    }

    private func report(message: String) {
        let value = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else { return }
        Self.logger.error(
            "Local mesh publication failed: \(value, privacy: .public)"
        )
        onFailure(value)
        publish()
    }

    private func normalizedBundleIdentifiers(
        _ values: Set<String>
    ) -> Set<String> {
        Set(values.compactMap {
            let value = $0.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !value.isEmpty,
                  value != ApplicationDirectories.bundleIdentifier else {
                return nil
            }
            return value
        })
    }

    private func nextFocusOrdinal() -> UInt64 {
        focusOrdinal &+= 1
        return focusOrdinal
    }

    private func autoShareReplacementOrder(
        _ lhs: ActiveSource,
        _ rhs: ActiveSource
    ) -> Bool {
        let lhsOrdinal = switch lhs.management {
        case let .autoShared(lastFocusedOrdinal):
            lastFocusedOrdinal
        case .manual:
            UInt64.max
        }
        let rhsOrdinal = switch rhs.management {
        case let .autoShared(lastFocusedOrdinal):
            lastFocusedOrdinal
        case .manual:
            UInt64.max
        }
        if lhsOrdinal != rhsOrdinal {
            return lhsOrdinal < rhsOrdinal
        }
        return lhs.instanceID.rawValue < rhs.instanceID.rawValue
    }

    private func screenName(displayID: CGDirectDisplayID) -> String {
        NSScreen.screens.first {
            ($0.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber)?.uint32Value == displayID
        }?.localizedName ?? String(localized: "Main Display")
    }
}
