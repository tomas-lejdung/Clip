import AppKit
import ClipMedia
import CoreGraphics

struct CaptureApplicationWindowSegment: Equatable, Identifiable, Sendable {
    let id: String
    let windowID: CGWindowID
    let bundleIdentifier: String
    let applicationName: String
    let sourceRectangleInDisplayPoints: CGRect
    let rectangleInDisplayPoints: CGRect
}

struct SelectedCaptureApplication: Equatable, Sendable {
    let display: CaptureSelectionDisplay
    let bundleIdentifier: String
    let applicationName: String
    /// The union of every visible window segment for this app on the display,
    /// in AppKit display-local coordinates.
    let rectangleInDisplayPoints: CGRect
    /// The same union in ScreenCaptureKit's top-left display-local coordinates.
    let sourceRectangleInDisplayPoints: CGRect
    let outputPixelSize: CGSize
    let highlightedRectanglesInDisplayPoints: [CGRect]
}

enum ApplicationCaptureSelectionLayout {
    /// Converts ScreenCaptureKit global top-left window frames into both source
    /// and AppKit-local rectangles for one display. Input order is preserved;
    /// ScreenCaptureKit supplies windows front-to-back and hit testing relies on it.
    static func segments(
        for display: CaptureSelectionDisplay,
        quartzDisplayFrame: CGRect,
        windows: [CaptureApplicationWindow]
    ) -> [CaptureApplicationWindowSegment] {
        guard quartzDisplayFrame.width > 0, quartzDisplayFrame.height > 0 else {
            return []
        }

        return windows.compactMap { window in
            let intersection = window.frame.standardized.intersection(quartzDisplayFrame)
            guard !intersection.isNull,
                  !intersection.isEmpty,
                  intersection.width >= 2,
                  intersection.height >= 2 else {
                return nil
            }

            let sourceRectangle = CGRect(
                x: intersection.minX - quartzDisplayFrame.minX,
                y: intersection.minY - quartzDisplayFrame.minY,
                width: intersection.width,
                height: intersection.height
            )
            let appKitRectangle = CGRect(
                x: sourceRectangle.minX,
                y: display.localBounds.height - sourceRectangle.maxY,
                width: sourceRectangle.width,
                height: sourceRectangle.height
            ).intersection(display.localBounds)
            guard !appKitRectangle.isNull, !appKitRectangle.isEmpty else { return nil }

            return CaptureApplicationWindowSegment(
                id: "\(display.id)-\(window.windowID)",
                windowID: window.windowID,
                bundleIdentifier: window.bundleIdentifier,
                applicationName: window.applicationName,
                sourceRectangleInDisplayPoints: sourceRectangle,
                rectangleInDisplayPoints: appKitRectangle
            )
        }
    }

    static func bundleIdentifier(
        at point: CGPoint,
        in segments: [CaptureApplicationWindowSegment]
    ) -> String? {
        segments.first(where: { $0.rectangleInDisplayPoints.contains(point) })?
            .bundleIdentifier
    }

    static func selection(
        bundleIdentifier: String,
        display: CaptureSelectionDisplay,
        segments: [CaptureApplicationWindowSegment]
    ) -> SelectedCaptureApplication? {
        let matching = segments.filter { $0.bundleIdentifier == bundleIdentifier }
        guard let first = matching.first else { return nil }

        let sourceUnion = matching.dropFirst().reduce(
            first.sourceRectangleInDisplayPoints
        ) { partial, segment in
            partial.union(segment.sourceRectangleInDisplayPoints)
        }
        let appKitUnion = matching.dropFirst().reduce(
            first.rectangleInDisplayPoints
        ) { partial, segment in
            partial.union(segment.rectangleInDisplayPoints)
        }
        let outputPixelSize = CGSize(
            width: ceil(sourceUnion.width * display.scaleFactor),
            height: ceil(sourceUnion.height * display.scaleFactor)
        )
        guard outputPixelSize.width >= 2, outputPixelSize.height >= 2 else { return nil }

        return SelectedCaptureApplication(
            display: display,
            bundleIdentifier: bundleIdentifier,
            applicationName: first.applicationName,
            rectangleInDisplayPoints: appKitUnion,
            sourceRectangleInDisplayPoints: sourceUnion,
            outputPixelSize: outputPixelSize,
            highlightedRectanglesInDisplayPoints: matching.map(\.rectangleInDisplayPoints)
        )
    }
}

/// Presents one capture-excluded overlay per display and lets the user choose
/// the visible application under the pointer. A click selects all of that
/// application's visible windows on the clicked display; Record or Return then
/// confirms the target.
@MainActor
final class ApplicationCaptureSelectionController {
    typealias CompletionHandler = @MainActor @Sendable (SelectedCaptureApplication) -> Void
    typealias CancellationHandler = @MainActor @Sendable () -> Void

    private struct ScreenContext {
        let screen: NSScreen
        let display: CaptureSelectionDisplay
        let quartzFrame: CGRect
    }

    private let onComplete: CompletionHandler
    private let onCancel: CancellationHandler
    private var panels: [String: ApplicationCaptureSelectionPanel] = [:]
    private var overlayViews: [String: ApplicationCaptureSelectionOverlayView] = [:]
    private var activeDisplayIdentifier: String?
    private var isFinishing = false

    var isPresented: Bool { !panels.isEmpty }

    init(
        onComplete: @escaping CompletionHandler,
        onCancel: @escaping CancellationHandler
    ) {
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    @discardableResult
    func present(windows: [CaptureApplicationWindow]) -> Bool {
        let contexts = Self.currentScreenContexts()
        guard !contexts.isEmpty else {
            cancelAfterClosing()
            return false
        }
        closeOverlays()
        isFinishing = false

        let main = contexts.first(where: { $0.display.isMain }) ?? contexts[0]
        activeDisplayIdentifier = main.display.id
        var selectableWindowCount = 0

        for context in contexts {
            let segments = ApplicationCaptureSelectionLayout.segments(
                for: context.display,
                quartzDisplayFrame: context.quartzFrame,
                windows: windows
            )
            selectableWindowCount += segments.count
            let identifier = context.display.id
            let overlay = ApplicationCaptureSelectionOverlayView(
                display: context.display,
                segments: segments,
                isActive: identifier == activeDisplayIdentifier,
                onActivate: { [weak self] identifier in
                    self?.activateDisplay(identifier)
                },
                onComplete: { [weak self] selection in
                    self?.complete(selection)
                },
                onCancel: { [weak self] in
                    self?.cancel()
                }
            )
            let panel = ApplicationCaptureSelectionPanel(
                screen: context.screen,
                contentView: overlay
            )
            panels[identifier] = panel
            overlayViews[identifier] = overlay
        }

        guard selectableWindowCount > 0 else {
            closeOverlays()
            return false
        }

        NSApp.activate(ignoringOtherApps: true)
        for panel in panels.values {
            panel.orderFrontRegardless()
        }
        activateDisplay(main.display.id, clearOtherSelections: false)
        return true
    }

    func cancel() {
        guard isPresented, !isFinishing else { return }
        cancelAfterClosing()
    }

    func dismissWithoutCallback() {
        closeOverlays()
        isFinishing = false
    }

    private func activateDisplay(
        _ identifier: String,
        clearOtherSelections: Bool = true
    ) {
        guard panels[identifier] != nil else { return }
        let changedDisplay = activeDisplayIdentifier != identifier
        activeDisplayIdentifier = identifier

        for (candidateIdentifier, overlay) in overlayViews {
            overlay.setActive(
                candidateIdentifier == identifier,
                clearSelection: clearOtherSelections && changedDisplay
                    && candidateIdentifier != identifier
            )
        }
        panels[identifier]?.makeKeyAndOrderFront(nil)
        overlayViews[identifier]?.focusForKeyboardInput()
    }

    private func complete(_ selection: SelectedCaptureApplication) {
        guard !isFinishing, selection.display.id == activeDisplayIdentifier else { return }
        isFinishing = true
        closeOverlays()
        let callback = onComplete
        Task { @MainActor in
            await Task.yield()
            try? await ContinuousClock().sleep(for: .milliseconds(20))
            callback(selection)
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
            let pixelWidth = CGFloat(CGDisplayPixelsWide(displayID))
            let pixelHeight = CGFloat(CGDisplayPixelsHigh(displayID))
            let pixelSize = CGSize(
                width: pixelWidth > 0 ? pixelWidth : screen.frame.width * screen.backingScaleFactor,
                height: pixelHeight > 0 ? pixelHeight : screen.frame.height * screen.backingScaleFactor
            )
            let scaleFactor = screen.frame.width > 0
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
                    scaleFactor: scaleFactor,
                    isMain: screen === NSScreen.main
                ),
                quartzFrame: CGDisplayBounds(displayID)
            )
        }
    }

    private static func stableIdentifier(for displayID: CGDirectDisplayID) -> String {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return "display-\(displayID)"
        }
        return CFUUIDCreateString(
            kCFAllocatorDefault,
            unmanagedUUID.takeRetainedValue()
        ) as String
    }
}

@MainActor
final class ApplicationCaptureConfirmationView: NSVisualEffectView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let recordButton = NSButton()
    let cancelButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        setAccessibilityIdentifier("clip.capture.application.toolbar")

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        recordButton.title = String(localized: "Record App")
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .large
        recordButton.keyEquivalent = "\r"
        recordButton.setAccessibilityIdentifier("clip.capture.application.record")

        cancelButton.title = String(localized: "Cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("clip.capture.application.cancel")

        let buttons = NSStackView(views: [cancelButton, recordButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fillEqually
        buttons.spacing = 8

        let content = NSStackView(views: [titleLabel, detailLabel, buttons])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .centerX
        content.distribution = .fill
        content.spacing = 7
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            // Give each text field a real full-width AppKit cell. Centering an
            // intrinsic-width label only centers glyphs inside that short cell.
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

@MainActor
private final class ApplicationCaptureSelectionOverlayView: NSView {
    typealias ActivationHandler = @MainActor @Sendable (String) -> Void
    typealias CompletionHandler = @MainActor @Sendable (SelectedCaptureApplication) -> Void
    typealias CancellationHandler = @MainActor @Sendable () -> Void

    private let display: CaptureSelectionDisplay
    private let segments: [CaptureApplicationWindowSegment]
    private let onActivate: ActivationHandler
    private let onComplete: CompletionHandler
    private let onCancel: CancellationHandler
    private let toolbar = ApplicationCaptureConfirmationView(frame: .zero)
    private var trackingArea: NSTrackingArea?
    private var isActiveDisplay: Bool
    private var hoveredBundleIdentifier: String?
    private var selectedBundleIdentifier: String?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    init(
        display: CaptureSelectionDisplay,
        segments: [CaptureApplicationWindowSegment],
        isActive: Bool,
        onActivate: @escaping ActivationHandler,
        onComplete: @escaping CompletionHandler,
        onCancel: @escaping CancellationHandler
    ) {
        self.display = display
        self.segments = segments
        self.isActiveDisplay = isActive
        self.onActivate = onActivate
        self.onComplete = onComplete
        self.onCancel = onCancel
        super.init(frame: display.localBounds)
        wantsLayer = true
        setupToolbar()
        updatePresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setActive(_ active: Bool, clearSelection: Bool) {
        isActiveDisplay = active
        if clearSelection {
            selectedBundleIdentifier = nil
        }
        updatePresentation()
    }

    func focusForKeyboardInput() {
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let replacement = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(replacement)
        trackingArea = replacement
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
        for segment in segments {
            addCursorRect(segment.rectangleInDisplayPoints, cursor: .pointingHand)
        }
        if !toolbar.isHidden {
            addCursorRect(
                convert(toolbar.recordButton.bounds, from: toolbar.recordButton),
                cursor: .pointingHand
            )
            addCursorRect(
                convert(toolbar.cancelButton.bounds, from: toolbar.cancelButton),
                cursor: .pointingHand
            )
        }
    }

    override func layout() {
        super.layout()
        guard let selection = currentSelection else { return }
        let size = CGSize(width: min(310, max(260, bounds.width - 32)), height: 116)
        let candidateX = selection.rectangleInDisplayPoints.midX - size.width / 2
        let x = min(max(12, candidateX), max(12, bounds.maxX - size.width - 12))
        let below = selection.rectangleInDisplayPoints.minY - size.height - 12
        let y = below >= 12
            ? below
            : min(
                max(12, selection.rectangleInDisplayPoints.maxY + 12),
                max(12, bounds.maxY - size.height - 12)
            )
        toolbar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(isActiveDisplay ? 0.22 : 0.4).setFill()
        NSBezierPath(rect: bounds).fill()

        let highlighted = selectedBundleIdentifier ?? hoveredBundleIdentifier
        guard let highlighted else { return }
        let matching = segments.filter { $0.bundleIdentifier == highlighted }
        for segment in matching {
            let rectangle = segment.rectangleInDisplayPoints.intersection(bounds)
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(rect: rectangle).fill()
            let border = NSBezierPath(rect: rectangle.insetBy(dx: 1, dy: 1))
            border.lineWidth = selectedBundleIdentifier == highlighted ? 4 : 2.5
            NSColor.controlAccentColor.setStroke()
            border.stroke()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovered = ApplicationCaptureSelectionLayout.bundleIdentifier(
            at: point,
            in: segments
        )
        guard hovered != hoveredBundleIdentifier else { return }
        hoveredBundleIdentifier = hovered
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredBundleIdentifier = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        focusForKeyboardInput()
        if !isActiveDisplay {
            onActivate(display.id)
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let bundleIdentifier = ApplicationCaptureSelectionLayout.bundleIdentifier(
            at: point,
            in: segments
        ) else {
            return
        }
        selectedBundleIdentifier = bundleIdentifier
        updatePresentation()
        if event.clickCount >= 2 {
            completeSelection()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return and keypad Enter
            completeSelection()
        case 53: // Escape
            onCancel()
        default:
            super.keyDown(with: event)
        }
    }

    private var currentSelection: SelectedCaptureApplication? {
        guard let selectedBundleIdentifier else { return nil }
        return ApplicationCaptureSelectionLayout.selection(
            bundleIdentifier: selectedBundleIdentifier,
            display: display,
            segments: segments
        )
    }

    private func setupToolbar() {
        toolbar.isHidden = true
        toolbar.recordButton.target = self
        toolbar.recordButton.action = #selector(recordPressed(_:))
        toolbar.cancelButton.target = self
        toolbar.cancelButton.action = #selector(cancelPressed(_:))
        addSubview(toolbar)
    }

    private func updatePresentation() {
        if let selection = currentSelection, isActiveDisplay {
            toolbar.titleLabel.stringValue = selection.applicationName
            toolbar.detailLabel.stringValue = String(
                localized: "All visible windows on this display"
            )
            toolbar.isHidden = false
        } else {
            toolbar.isHidden = true
        }
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    @objc
    private func recordPressed(_ sender: NSButton) {
        completeSelection()
    }

    @objc
    private func cancelPressed(_ sender: NSButton) {
        onCancel()
    }

    private func completeSelection() {
        guard isActiveDisplay, let selection = currentSelection else { return }
        onComplete(selection)
    }
}

@MainActor
private final class ApplicationCaptureSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(screen: NSScreen, contentView: ApplicationCaptureSelectionOverlayView) {
        super.init(
            contentRect: CGRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        self.contentView = contentView
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        sharingType = .none
    }
}
