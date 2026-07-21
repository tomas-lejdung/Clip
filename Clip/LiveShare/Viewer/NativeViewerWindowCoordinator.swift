import AppKit

enum NativeViewerCursorFocusPolicy {
    static func shouldClearCursor(
        streamID: String,
        authoritativeSources: [NativeViewerSourceSnapshot]
    ) -> Bool {
        !authoritativeSources.contains {
            $0.streamID == streamID && $0.isFocused
        }
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

    private var ownerName: String
    private let identityColor: NSColor
    private let surfaceFactory: SurfaceFactory
    private var registry: NativeViewerWindowRegistry
    private var entries: [NativeViewerWindowID: Entry] = [:]

    init(
        sessionID: String,
        ownerName: String,
        ownerPublicIdentity: Data,
        surfaceFactory: @escaping SurfaceFactory
    ) {
        self.ownerName = ownerName
        identityColor = NativeViewerIdentityColor
            .stable(for: ownerPublicIdentity)
            .appKitColor
        self.surfaceFactory = surfaceFactory
        registry = NativeViewerWindowRegistry(sessionID: sessionID)
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

    func setScaleMode(_ mode: NativeViewerScaleMode) {
        for entry in entries.values {
            entry.controller.setScaleMode(mode)
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
        for (id, entry) in entries where registry.windows[id]?.source.streamID != streamID {
            entry.controller.content.setCursor(
                normalizedX: nil,
                normalizedY: nil
            )
        }
        guard let id = registry.windows.first(where: {
            $0.value.source.streamID == streamID
        })?.key,
        let entry = entries[id] else { return }
        entry.controller.content.setCursor(
            normalizedX: normalizedX,
            normalizedY: normalizedY
        )
    }

    func markDisconnected() {
        let disconnected = registry.windows.values.map { snapshot in
            NativeViewerSourceSnapshot(
                sourceInstanceID: snapshot.source.sourceInstanceID,
                streamID: snapshot.source.streamID,
                applicationName: snapshot.source.applicationName,
                windowName: snapshot.source.windowName,
                pixelSize: snapshot.source.pixelSize,
                isFocused: snapshot.source.isFocused,
                isConnected: false,
                stateRevision: snapshot.source.stateRevision,
                mode: snapshot.source.mode
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
        registry = NativeViewerWindowRegistry(sessionID: registry.sessionID)
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
        surface.onDecodedPixelSizeChange = { [weak controller] size in
            controller?.decodedPixelSizeDidChange(size)
        }
        controller.onCloseRequested = { [weak self] controller in
            self?.handleClose(controller) ?? .hide
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
            controller.showWithoutTakingFocus()
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
        window.setFrameOrigin(origin)
    }
}
