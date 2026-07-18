import AppKit
import CoreGraphics

/// Coordinates one borderless overlay panel per connected display. This type
/// only selects a target; it never asks for capture permissions or starts a
/// ScreenCaptureKit stream.
@MainActor
final class CaptureSelectionController {
    typealias CompletionHandler = @MainActor @Sendable (CaptureSelectionResult) -> Void
    typealias CancellationHandler = @MainActor @Sendable () -> Void

    private struct ScreenContext {
        let screen: NSScreen
        let display: CaptureSelectionDisplay
    }

    private let configuration: CaptureSelectionConfiguration
    private let onComplete: CompletionHandler
    private let onCancel: CancellationHandler

    private var panels: [String: CaptureSelectionPanel] = [:]
    private var overlayViews: [String: CaptureSelectionOverlayView] = [:]
    private var activeDisplayIdentifier: String?
    private var presentationMode: CaptureSelectionPresentationMode?
    private var isFinishing = false

    var isPresented: Bool { !panels.isEmpty }

    init(
        configuration: CaptureSelectionConfiguration = .init(),
        onComplete: @escaping CompletionHandler,
        onCancel: @escaping CancellationHandler
    ) {
        self.configuration = configuration
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    /// Presents blank area selection, or restores Last Area for adjustment.
    func presentAreaSelection(restoring storedArea: StoredCaptureArea? = nil) {
        let contexts = Self.currentScreenContexts()
        guard !contexts.isEmpty else {
            cancelAfterClosing()
            return
        }

        let restoredContext = storedArea.flatMap { stored in
            contexts.first { $0.display.id == stored.displayIdentifier }
        }
        let activeContext = restoredContext
            ?? contexts.first(where: { $0.display.isMain })
            ?? contexts[0]

        var restoredRectangle: CGRect?
        if let storedArea {
            restoredRectangle = CaptureSelectionGeometry.clamped(
                storedArea.rectangle.denormalized(in: activeContext.display.localBounds),
                to: activeContext.display.localBounds,
                minimumSize: configuration.minimumAreaSize
            )
        }

        present(
            contexts: contexts,
            mode: .area,
            activeDisplayIdentifier: activeContext.display.id,
            restoredRectangle: restoredRectangle
        )
    }

    /// Presents all displays for fullscreen target selection. Choosing a display
    /// prepares it; recording only completes after Record or Return.
    func presentFullscreenSelection(preferredDisplayIdentifier: String? = nil) {
        let contexts = Self.currentScreenContexts()
        guard !contexts.isEmpty else {
            cancelAfterClosing()
            return
        }

        let activeContext = preferredDisplayIdentifier.flatMap { identifier in
            contexts.first { $0.display.id == identifier }
        } ?? contexts.first(where: { $0.display.isMain }) ?? contexts[0]

        present(
            contexts: contexts,
            mode: .fullscreen,
            activeDisplayIdentifier: activeContext.display.id,
            restoredRectangle: nil
        )
    }

    /// Cancels Capture Mode and notifies the injected cancellation callback.
    func cancel() {
        guard isPresented, !isFinishing else { return }
        cancelAfterClosing()
    }

    /// Tears down overlays without treating app shutdown as user cancellation.
    func dismissWithoutCallback() {
        closeOverlays()
        isFinishing = false
    }

    private func present(
        contexts: [ScreenContext],
        mode: CaptureSelectionPresentationMode,
        activeDisplayIdentifier: String,
        restoredRectangle: CGRect?
    ) {
        closeOverlays()
        isFinishing = false
        presentationMode = mode
        self.activeDisplayIdentifier = activeDisplayIdentifier

        for context in contexts {
            let identifier = context.display.id
            let initialSelection = identifier == activeDisplayIdentifier ? restoredRectangle : nil
            let overlay = CaptureSelectionOverlayView(
                display: context.display,
                mode: mode,
                initialSelection: initialSelection,
                isActive: identifier == activeDisplayIdentifier,
                configuration: configuration,
                onActivate: { [weak self] identifier in
                    self?.activateDisplay(identifier)
                },
                onComplete: { [weak self] result in
                    self?.complete(result)
                },
                onCancel: { [weak self] in
                    self?.cancel()
                }
            )
            let panel = CaptureSelectionPanel(screen: context.screen, contentView: overlay)
            panels[identifier] = panel
            overlayViews[identifier] = overlay
        }

        NSApp.activate(ignoringOtherApps: true)
        for panel in panels.values {
            panel.orderFrontRegardless()
        }
        activateDisplay(activeDisplayIdentifier, clearOtherSelections: false)
    }

    private func activateDisplay(
        _ identifier: String,
        clearOtherSelections: Bool = true
    ) {
        guard panels[identifier] != nil else { return }
        let changedDisplay = activeDisplayIdentifier != identifier
        activeDisplayIdentifier = identifier

        for (candidateIdentifier, overlay) in overlayViews {
            let isActive = candidateIdentifier == identifier
            overlay.setActive(
                isActive,
                clearSelection: presentationMode == .area
                    && clearOtherSelections
                    && changedDisplay
                    && !isActive
            )
        }

        guard let panel = panels[identifier], let overlay = overlayViews[identifier] else { return }
        panel.makeKeyAndOrderFront(nil)
        overlay.focusForKeyboardInput()
    }

    private func complete(_ result: CaptureSelectionResult) {
        guard !isFinishing else { return }

        let resultDisplayIdentifier: String
        switch result {
        case let .area(area): resultDisplayIdentifier = area.display.id
        case let .fullscreen(display): resultDisplayIdentifier = display.id
        }
        guard resultDisplayIdentifier == activeDisplayIdentifier else { return }

        isFinishing = true
        closeOverlays()
        let callback = onComplete

        // orderOut is synchronous at the AppKit level. Yielding and waiting one
        // display frame lets WindowServer remove every overlay before the caller
        // starts a stream, preventing the selector from becoming frame zero.
        Task { @MainActor in
            await Task.yield()
            try? await ContinuousClock().sleep(for: .milliseconds(20))
            callback(result)
        }
    }

    private func cancelAfterClosing() {
        guard !isFinishing else { return }
        isFinishing = true
        closeOverlays()
        let callback = onCancel

        Task { @MainActor in
            await Task.yield()
            callback()
        }
    }

    private func closeOverlays() {
        for panel in panels.values {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll(keepingCapacity: false)
        overlayViews.removeAll(keepingCapacity: false)
        activeDisplayIdentifier = nil
        presentationMode = nil
        NSCursor.arrow.set()
    }

    private static func currentScreenContexts() -> [ScreenContext] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            let width = CGFloat(CGDisplayPixelsWide(displayID))
            let height = CGFloat(CGDisplayPixelsHigh(displayID))
            let fallbackPixelSize = CGSize(
                width: screen.frame.width * screen.backingScaleFactor,
                height: screen.frame.height * screen.backingScaleFactor
            )
            let pixelSize = width > 0 && height > 0
                ? CGSize(width: width, height: height)
                : fallbackPixelSize
            let physicalScaleFactor = screen.frame.width > 0
                ? pixelSize.width / screen.frame.width
                : screen.backingScaleFactor

            return ScreenContext(
                screen: screen,
                display: CaptureSelectionDisplay(
                    id: stableIdentifier(for: displayID),
                    displayID: displayID,
                    name: screen.localizedName,
                    frameInGlobalPoints: screen.frame,
                    pixelSize: pixelSize,
                    scaleFactor: physicalScaleFactor,
                    isMain: screen === NSScreen.main
                )
            )
        }
    }

    private static func stableIdentifier(for displayID: CGDirectDisplayID) -> String {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return "display-\(displayID)"
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
    }
}

/// A click-through, capture-excluded outline that keeps an area target visible
/// after the dimming selection UI has gone away.
@MainActor
final class CaptureRegionOutlineController {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show(rectangleInGlobalPoints rectangle: CGRect) {
        hide()
        let rectangle = rectangle.standardized
        guard rectangle.width > 0, rectangle.height > 0 else { return }

        let borderInset: CGFloat = 3
        let panel = NSPanel(
            contentRect: rectangle.insetBy(dx: -borderInset, dy: -borderInset),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.sharingType = .none
        panel.contentView = CaptureRegionOutlineView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView?.autoresizingMask = [.width, .height]
        panel.contentView?.setAccessibilityIdentifier("clip.recording.regionOutline")
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

@MainActor
private final class CaptureRegionOutlineView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        NSColor.systemRed.withAlphaComponent(0.95).setStroke()
        path.stroke()
    }
}

/// A transparent selection window still needs a nontransparent composited pixel
/// at every point where it owns pointer input. WindowServer performs that test
/// before AppKit asks any descendant view to participate in `hitTest(_:)`.
@MainActor
final class CaptureSelectionHitSurfaceView: NSView {
    /// One alpha byte is visually indistinguishable from clear, while remaining
    /// nonzero after the window backing store is quantized to eight-bit alpha.
    static let opacity: CGFloat = 1.0 / 255.0

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    init(contentView: CaptureSelectionOverlayView) {
        super.init(frame: CGRect(origin: .zero, size: contentView.frame.size))
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(deviceWhite: 0, alpha: Self.opacity).setFill()
        dirtyRect.fill()
    }
}

@MainActor
final class CaptureSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    convenience init(screen: NSScreen, contentView: CaptureSelectionOverlayView) {
        self.init(frame: screen.frame, contentView: contentView)
    }

    init(frame: CGRect, contentView: CaptureSelectionOverlayView) {
        super.init(
            contentRect: CGRect(origin: .zero, size: frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        setFrame(frame, display: false)
        self.contentView = CaptureSelectionHitSurfaceView(contentView: contentView)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        isMovable = false
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        // The panels are also removed before recording starts. sharingType is a
        // second line of defense if another capture session is already active.
        sharingType = .none
    }
}
