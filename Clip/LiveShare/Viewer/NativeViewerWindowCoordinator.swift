import AppKit

enum NativeViewerSurfaceBindingError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(streamID):
            "The remote video stream \(streamID) is not available."
        }
    }
}

enum NativeViewerCursorFocusPolicy {
    static func shouldPresentCursor(
        streamID: String,
        authoritativeSources: [NativeViewerSourceSnapshot]
    ) -> Bool {
        authoritativeSources.contains {
            $0.streamID == streamID && $0.isFocused && $0.isConnected
        }
    }

    static func shouldClearCursor(
        streamID: String,
        authoritativeSources: [NativeViewerSourceSnapshot]
    ) -> Bool {
        !shouldPresentCursor(
            streamID: streamID,
            authoritativeSources: authoritativeSources
        )
    }
}

@MainActor
final class NativeViewerVideoSurfaceAdapter {
    let view: NSView
    var onDecodedPixelSizeChange: ((CGSize) -> Void)?

    private let bindAction: (NativeViewerSourceSnapshot) throws -> Void
    private let teardownAction: () -> Void

    init(
        view: NSView,
        bind: @escaping (NativeViewerSourceSnapshot) throws -> Void,
        teardown: @escaping () -> Void
    ) {
        self.view = view
        bindAction = bind
        teardownAction = teardown
    }

    func bind(to source: NativeViewerSourceSnapshot) throws {
        try bindAction(source)
    }

    func decodedPixelSizeDidChange(_ size: CGSize) {
        onDecodedPixelSizeChange?(size)
    }

    func tearDown() {
        onDecodedPixelSizeChange = nil
        teardownAction()
    }
}

@MainActor
final class NativeViewerWindowCoordinator {
    typealias SurfaceFactory = () -> NativeViewerVideoSurfaceAdapter

    private struct Entry {
        let controller: NativeViewerWindowController
        let surface: NativeViewerVideoSurfaceAdapter
    }

    var confirmLeaveWhenLastWindowCloses: () -> Bool = { false }
    var onLeaveRequested: () -> Void = {}
    var onPresentationChanged: () -> Void = {}

    private var ownerName: String
    private let identityColor: NSColor
    private let surfaceFactory: SurfaceFactory
    private var registry: NativeViewerWindowRegistry
    private var entries: [NativeViewerWindowID: Entry] = [:]

    init(
        ownerName: String,
        ownerPublicIdentity: Data,
        surfaceFactory: @escaping SurfaceFactory
    ) {
        self.ownerName = ownerName
        identityColor = NativeViewerIdentityColor
            .stable(for: ownerPublicIdentity)
            .appKitColor
        self.surfaceFactory = surfaceFactory
        registry = NativeViewerWindowRegistry()
    }

    var visibleWindowCount: Int { registry.visibleWindowCount }
    var windowCount: Int { entries.count }
    var windowSnapshots: [NativeViewerWindowSnapshot] {
        registry.windows.values.sorted { $0.id.description < $1.id.description }
    }

    func reconcile(_ sources: [NativeViewerSourceSnapshot]) throws {
        for change in registry.reconcile(sources) {
            switch change {
            case .create(let snapshot):
                try create(snapshot)
            case .update(let snapshot):
                try update(snapshot)
            case .remove(let id):
                remove(id)
            case .visibility(let id, let isVisible):
                setVisibility(isVisible, id: id)
            }
        }
        for (id, entry) in entries {
            guard let streamID = registry.windows[id]?.source.streamID,
                  NativeViewerCursorFocusPolicy.shouldClearCursor(
                    streamID: streamID,
                    authoritativeSources: sources
                  ) else { continue }
            entry.controller.content.setCursor(
                normalizedX: nil,
                normalizedY: nil
            )
        }
    }

    func showAll() {
        for change in registry.showAll() {
            guard case let .visibility(id, isVisible) = change else { continue }
            setVisibility(isVisible, id: id)
        }
    }

    func setSourceVisible(_ isVisible: Bool, sourceInstanceID: String) {
        guard let id = registry.windows.first(where: {
            $0.value.source.sourceInstanceID == sourceInstanceID
        })?.key,
        let change = registry.setVisible(isVisible, for: id),
        case let .visibility(changedID, visible) = change else { return }
        setVisibility(visible, id: changedID)
    }

    func setScaleMode(
        _ mode: NativeViewerScaleMode,
        sourceInstanceID: String
    ) {
        guard let id = windowID(sourceInstanceID: sourceInstanceID),
              let controller = entries[id]?.controller else { return }
        controller.setScaleMode(mode)
        registry.setScaleMode(mode, for: id)
    }

    func toggleFullScreen(sourceInstanceID: String) {
        guard let id = windowID(sourceInstanceID: sourceInstanceID),
              let controller = entries[id]?.controller else { return }
        if registry.windows[id]?.isVisible != true,
           let change = registry.setVisible(true, for: id),
           case let .visibility(changedID, isVisible) = change {
            setVisibility(isVisible, id: changedID)
        }
        controller.toggleFullScreen()
    }

    func bringToFront(sourceInstanceID: String) {
        guard let id = windowID(sourceInstanceID: sourceInstanceID),
              let controller = entries[id]?.controller else { return }
        if registry.windows[id]?.isVisible != true {
            _ = registry.setVisible(true, for: id)
        }
        bringToFront(controller)
    }

    func bringAllToFront() {
        _ = registry.showAll()
        let ordered = entries.keys.sorted { lhs, rhs in
            let lhsSource = registry.windows[lhs]?.source
            let rhsSource = registry.windows[rhs]?.source
            if lhsSource?.isFocused != rhsSource?.isFocused {
                return lhsSource?.isFocused == false
            }
            return lhs.description < rhs.description
        }
        for id in ordered {
            guard let controller = entries[id]?.controller else { continue }
            bringToFront(controller)
        }
    }

    func setOwnerName(_ ownerName: String) {
        guard self.ownerName != ownerName else { return }
        self.ownerName = ownerName
        for (id, entry) in entries {
            guard let snapshot = registry.windows[id] else { continue }
            entry.controller.update(
                ownerName: ownerName,
                source: snapshot.source,
                identityColor: identityColor
            )
        }
    }

    func setCursor(
        streamID: String,
        normalizedX: CGFloat?,
        normalizedY: CGFloat?
    ) {
        let authoritativeSources = registry.windows.values.map(\.source)
        guard NativeViewerCursorFocusPolicy.shouldPresentCursor(
            streamID: streamID,
            authoritativeSources: authoritativeSources
        ) else {
            // Ignore delayed cursor packets from a source that has already
            // lost host focus. Clear that source defensively, but preserve the
            // current focused source's latest cursor until its next sample.
            for (id, entry) in entries
            where registry.windows[id]?.source.streamID == streamID {
                entry.controller.content.setCursor(
                    normalizedX: nil,
                    normalizedY: nil
                )
            }
            return
        }

        for (id, entry) in entries where registry.windows[id]?.source.streamID != streamID {
            entry.controller.content.setCursor(
                normalizedX: nil,
                normalizedY: nil
            )
        }
        for (id, entry) in entries
        where registry.windows[id]?.source.streamID == streamID {
            entry.controller.content.setCursor(
                normalizedX: normalizedX,
                normalizedY: normalizedY
            )
        }
    }

    func setCollaborationOverlay(
        _ snapshot: NativeViewerCollaborationOverlaySnapshot,
        sourceInstanceID: String
    ) {
        guard
            let id = windowID(sourceInstanceID: sourceInstanceID),
            let content = entries[id]?.controller.content
        else {
            return
        }
        content.setCollaborationOverlay(snapshot)
    }

    func setCollaborationInteraction(
        _ mode: NativeViewerCollaborationInteractionMode,
        sourceInstanceID: String,
        actions: NativeViewerCollaborationActions = .init()
    ) {
        guard
            let id = windowID(sourceInstanceID: sourceInstanceID),
            let content = entries[id]?.controller.content
        else {
            return
        }
        let overlay = content.collaborationOverlayView
        overlay.onPointerChanged = actions.pointerChanged
        overlay.onPing = actions.ping
        overlay.onStrokeBegan = actions.strokeBegan
        overlay.onStrokePoints = actions.strokePoints
        overlay.onStrokeEnded = actions.strokeEnded
        content.setCollaborationInteractionMode(mode)
    }

    func markDisconnected() {
        let disconnected = registry.windows.values.map { snapshot in
            NativeViewerSourceSnapshot(
                sourceInstanceID: snapshot.source.sourceInstanceID,
                streamID: snapshot.source.streamID,
                applicationName: snapshot.source.applicationName,
                windowName: snapshot.source.windowName,
                pixelSize: snapshot.source.pixelSize,
                sourcePointSize: snapshot.source.sourcePointSize,
                isFocused: snapshot.source.isFocused,
                isConnected: false,
                stateRevision: snapshot.source.stateRevision
            )
        }
        try? reconcile(disconnected)
    }

    func tearDown() {
        for entry in entries.values {
            entry.surface.tearDown()
            entry.controller.tearDown()
        }
        entries.removeAll()
        registry = NativeViewerWindowRegistry()
    }

    private func create(_ snapshot: NativeViewerWindowSnapshot) throws {
        let surface = surfaceFactory()
        let controller = NativeViewerWindowController(
            id: snapshot.id,
            ownerName: ownerName,
            source: snapshot.source,
            identityColor: identityColor,
            videoView: surface.view
        )
        controller.setScaleMode(snapshot.scaleMode)
        surface.onDecodedPixelSizeChange = { [weak controller] size in
            controller?.decodedPixelSizeDidChange(size)
        }
        controller.onCloseRequested = { [weak self] controller in
            self?.handleClose(controller) ?? .hide
        }
        controller.onScaleModeChanged = { [weak self] controller, mode in
            guard let self else { return }
            registry.setScaleMode(mode, for: controller.viewerWindowID)
            onPresentationChanged()
        }
        controller.onFullScreenChanged = { [weak self] controller, isFullScreen in
            guard let self else { return }
            registry.setFullScreen(isFullScreen, for: controller.viewerWindowID)
            onPresentationChanged()
        }
        do {
            try surface.bind(to: snapshot.source)
        } catch {
            surface.tearDown()
            controller.tearDown()
            throw error
        }
        entries[snapshot.id] = Entry(controller: controller, surface: surface)
        cascade(controller.window, index: entries.count - 1)
        if snapshot.isVisible {
            // A newly shared source should be visible immediately, even when
            // Clip is not the active application, without stealing keyboard
            // focus or becoming permanently floating.
            bringToFront(controller)
        }
    }

    private func update(_ snapshot: NativeViewerWindowSnapshot) throws {
        guard let entry = entries[snapshot.id] else {
            try create(snapshot)
            return
        }
        try entry.surface.bind(to: snapshot.source)
        entry.controller.update(
            ownerName: ownerName,
            source: snapshot.source,
            identityColor: identityColor
        )
        // Metadata and focus changes update the border/title in place. The
        // viewer owns desktop stacking, so a host focus event must never raise
        // or reposition an already visible native window.
    }

    private func remove(_ id: NativeViewerWindowID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.surface.tearDown()
        entry.controller.tearDown()
    }

    private func setVisibility(_ isVisible: Bool, id: NativeViewerWindowID) {
        guard let controller = entries[id]?.controller else { return }
        if isVisible {
            controller.showWithoutTakingFocus()
        } else {
            controller.hide()
        }
    }

    private func windowID(sourceInstanceID: String) -> NativeViewerWindowID? {
        registry.windows.first(where: {
            $0.value.source.sourceInstanceID == sourceInstanceID
        })?.key
    }

    private func handleClose(
        _ controller: NativeViewerWindowController
    ) -> NativeViewerWindowCloseDisposition {
        let id = controller.viewerWindowID
        guard registry.windows[id]?.isVisible == true else { return .hide }
        if registry.visibleWindowCount == 1, confirmLeaveWhenLastWindowCloses() {
            onLeaveRequested()
            return .hide
        }
        if let change = registry.setVisible(false, for: id),
           case let .visibility(changedID, isVisible) = change {
            setVisibility(isVisible, id: changedID)
            onPresentationChanged()
        }
        return .hide
    }

    private func cascade(_ window: NSWindow?, index: Int) {
        guard let window, index > 0 else {
            window?.center()
            return
        }
        guard let reference = entries.values
            .map(\.controller.window)
            .compactMap({ $0 })
            .first(where: { $0 !== window }) else {
            window.center()
            return
        }
        var origin = reference.frame.origin
        let offset = CGFloat((index % 6) * 28)
        origin.x += offset
        origin.y -= offset
        if let visibleFrame = (window.screen ?? reference.screen ?? NSScreen.main)?.visibleFrame {
            origin = NativeViewerWindowController.clampedOrigin(
                frame: CGRect(origin: origin, size: window.frame.size),
                visibleFrame: visibleFrame
            )
        }
        window.setFrameOrigin(origin)
    }

    private func bringToFront(_ controller: NativeViewerWindowController) {
        controller.bringToFrontWithoutTakingFocus()
    }
}
