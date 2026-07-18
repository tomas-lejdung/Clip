import AppKit

@MainActor
final class CaptureSelectionOverlayView: NSView {
    typealias ActivationHandler = @MainActor @Sendable (String) -> Void
    typealias CompletionHandler = @MainActor @Sendable (CaptureSelectionResult) -> Void
    typealias CancellationHandler = @MainActor @Sendable () -> Void

    private enum DragInteraction {
        case creating(anchor: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(handle: CaptureSelectionHandle, start: CGPoint, original: CGRect)
    }

    let display: CaptureSelectionDisplay
    let mode: CaptureSelectionPresentationMode

    private let configuration: CaptureSelectionConfiguration
    private let onActivate: ActivationHandler
    private let onComplete: CompletionHandler
    private let onCancel: CancellationHandler

    private let toolbar = NSVisualEffectView()
    private let toolbarStack = NSStackView()
    private let dimensionsLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let recordButton = NSButton()
    private let cancelButton = NSButton()

    private(set) var selection: CGRect?
    private var isActiveDisplay: Bool
    private var focusedItem: CaptureSelectionFocus = .region
    private var dragInteraction: DragInteraction?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    // Transparent views default to handing mouse-downs to their window. Keep
    // the event here so the borderless panel cannot swallow interior drags.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    init(
        display: CaptureSelectionDisplay,
        mode: CaptureSelectionPresentationMode,
        initialSelection: CGRect?,
        isActive: Bool,
        configuration: CaptureSelectionConfiguration,
        onActivate: @escaping ActivationHandler,
        onComplete: @escaping CompletionHandler,
        onCancel: @escaping CancellationHandler
    ) {
        self.display = display
        self.mode = mode
        self.selection = initialSelection.map {
            CaptureSelectionGeometry.clamped(
                $0,
                to: display.localBounds,
                minimumSize: configuration.minimumAreaSize
            )
        }
        self.isActiveDisplay = isActive
        self.configuration = configuration
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
        if clearSelection, mode == .area {
            selection = nil
            dragInteraction = nil
            focusedItem = .region
        }
        updatePresentation()
    }

    func focusForKeyboardInput() {
        window?.makeFirstResponder(self)
        setKeyboardFocusRingNeedsDisplay(bounds)
    }

    override func layout() {
        super.layout()
        positionToolbar()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        switch mode {
        case .area:
            drawAreaOverlay()
        case .fullscreen:
            drawFullscreenOverlay()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)

        // The toolbar can fall back inside a very large selection. Register
        // its neutral cursor before the selection cursors so that dragging its
        // non-control surface still advertises the region's move interaction.
        if !toolbar.isHidden {
            addCursorRect(toolbar.frame, cursor: .arrow)
        }

        if mode == .area, isActiveDisplay, let selection {
            addCursorRect(selection, cursor: .openHand)

            let handles = CaptureSelectionGeometry.handleRectangles(
                for: selection,
                handleSize: configuration.handleSize + 6
            )
            for (handle, rectangle) in handles {
                let cursor: NSCursor
                if handle.horizontalDirection == 0 {
                    cursor = .resizeUpDown
                } else if handle.verticalDirection == 0 {
                    cursor = .resizeLeftRight
                } else {
                    cursor = .crosshair
                }
                addCursorRect(rectangle, cursor: cursor)
            }
        }

        // Buttons remain the highest-priority targets when the fallback
        // toolbar overlaps the selection.
        if !toolbar.isHidden {
            addCursorRect(convert(recordButton.bounds, from: recordButton), cursor: .pointingHand)
            addCursorRect(convert(cancelButton.bounds, from: cancelButton), cursor: .pointingHand)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        guard mode == .area,
              isActiveDisplay,
              let selection,
              selection.contains(point),
              toolbar.frame.contains(point),
              let hitView else {
            return hitView
        }

        // Preserve native button handling, but let the otherwise inert labels,
        // stack, and visual-effect background participate in moving a selection
        // when the toolbar has to be placed over it.
        if hitView === recordButton || hitView.isDescendant(of: recordButton)
            || hitView === cancelButton || hitView.isDescendant(of: cancelButton) {
            return hitView
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        focusForKeyboardInput()
        let point = convert(event.locationInWindow, from: nil)

        if !isActiveDisplay {
            onActivate(display.id)
        }

        guard mode == .area else {
            focusedItem = .recordButton
            updateFocusAppearance()
            return
        }

        if let selection,
           let handle = handle(at: point, in: selection) {
            focusedItem = .handle(handle)
            dragInteraction = .resizing(handle: handle, start: point, original: selection)
        } else if let selection, selection.contains(point) {
            focusedItem = .region
            dragInteraction = .moving(start: point, original: selection)
            NSCursor.closedHand.set()
        } else {
            focusedItem = .region
            dragInteraction = .creating(anchor: point)
            selection = CGRect(origin: point, size: .zero)
        }

        updatePresentation()
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let dragInteraction else { return }
        let point = convert(event.locationInWindow, from: nil)
        let preserveAspectRatio = event.modifierFlags.contains(.shift)

        switch dragInteraction {
        case let .creating(anchor):
            selection = CaptureSelectionGeometry.draftRectangle(
                from: anchor,
                to: point,
                in: bounds,
                aspectRatio: preserveAspectRatio ? 1 : nil
            )

        case let .moving(start, original):
            selection = CaptureSelectionGeometry.moved(
                original,
                by: CGVector(dx: point.x - start.x, dy: point.y - start.y),
                in: bounds
            )

        case let .resizing(handle, start, original):
            selection = CaptureSelectionGeometry.resized(
                original,
                using: handle,
                delta: CGVector(dx: point.x - start.x, dy: point.y - start.y),
                in: bounds,
                minimumSize: configuration.minimumAreaSize,
                preserveAspectRatio: preserveAspectRatio
            )
        }

        updatePresentation()
    }

    override func mouseUp(with event: NSEvent) {
        if case .creating? = dragInteraction, let selection {
            self.selection = CaptureSelectionGeometry.finalizedDraftRectangle(
                selection,
                in: bounds,
                minimumSize: configuration.minimumAreaSize
            )
        }
        dragInteraction = nil
        updatePresentation()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return and keypad Enter
            completeSelection()

        case 53: // Escape
            onCancel()

        case 48: // Tab
            cycleFocus(reverse: event.modifierFlags.contains(.shift))

        case 49 where focusedItem == .recordButton: // Space
            completeSelection()

        case 49 where focusedItem == .cancelButton: // Space
            onCancel()

        case 123, 124, 125, 126: // Arrow keys
            handleArrowKey(event)

        default:
            super.keyDown(with: event)
        }
    }

    private func setupToolbar() {
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 12
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        toolbar.setAccessibilityIdentifier("clip.capture.toolbar")

        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        dimensionsLabel.alignment = .center
        dimensionsLabel.maximumNumberOfLines = 1
        dimensionsLabel.setAccessibilityIdentifier("clip.capture.dimensions")

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 2

        recordButton.title = String(localized: "Record")
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .large
        recordButton.target = self
        recordButton.action = #selector(recordPressed(_:))
        recordButton.keyEquivalent = "\r"
        recordButton.setAccessibilityIdentifier("clip.capture.record")

        cancelButton.title = String(localized: "Cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("clip.capture.cancel")

        let buttons = NSStackView(views: [cancelButton, recordButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fillEqually
        buttons.spacing = 8

        toolbarStack.orientation = .vertical
        toolbarStack.alignment = .centerX
        toolbarStack.distribution = .fill
        toolbarStack.spacing = 7
        toolbarStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        toolbarStack.addArrangedSubview(dimensionsLabel)
        toolbarStack.addArrangedSubview(statusLabel)
        toolbarStack.addArrangedSubview(buttons)
        toolbarStack.frame = toolbar.bounds
        toolbarStack.autoresizingMask = [.width, .height]

        toolbar.addSubview(toolbarStack)
        addSubview(toolbar)
    }

    private func updatePresentation() {
        if mode == .area, let selection, selection.width > 0, selection.height > 0 {
            let pixels = CaptureSelectionGeometry.pixelSize(
                for: selection,
                scaleFactor: display.scaleFactor
            )
            dimensionsLabel.stringValue = "\(Int(pixels.width)) × \(Int(pixels.height))"
            statusLabel.stringValue = "\(configuration.microphoneStatus)  •  \(configuration.systemAudioStatus)"
            recordButton.title = String(localized: "Record")
            toolbar.isHidden = !isActiveDisplay || isCreatingSelection
        } else if mode == .area {
            dimensionsLabel.stringValue = String(localized: "Draw an area")
            statusLabel.stringValue = String(localized: "Drag anywhere on this display")
            toolbar.isHidden = true
        } else {
            dimensionsLabel.stringValue = "\(display.name)  •  \(Int(display.pixelSize.width)) × \(Int(display.pixelSize.height))"
            statusLabel.stringValue = isActiveDisplay
                ? String(localized: "Fullscreen selected")
                : String(localized: "Choose this display")
            recordButton.title = isActiveDisplay
                ? String(localized: "Record")
                : String(localized: "Select Display")
            toolbar.isHidden = false
        }

        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        updateFocusAppearance()
    }

    private func positionToolbar() {
        guard !toolbar.isHidden else { return }

        let toolbarSize = CGSize(
            width: mode == .fullscreen ? min(310, max(250, bounds.width - 32)) : min(290, max(250, bounds.width - 32)),
            height: mode == .fullscreen ? 120 : 112
        )

        let origin: CGPoint
        if mode == .fullscreen {
            origin = CGPoint(
                x: bounds.midX - toolbarSize.width / 2,
                y: bounds.midY - toolbarSize.height / 2
            )
        } else if let selection {
            origin = CaptureSelectionGeometry.toolbarOrigin(
                selection: selection,
                toolbarSize: toolbarSize,
                in: bounds.insetBy(dx: 8, dy: 8),
                padding: configuration.toolbarPadding
            )
        } else {
            origin = .zero
        }

        toolbar.frame = CGRect(origin: origin, size: toolbarSize)
        toolbarStack.frame = toolbar.bounds
    }

    private func drawAreaOverlay() {
        guard isActiveDisplay, let selection else {
            fill(bounds, color: NSColor.black.withAlphaComponent(configuration.dimmingOpacity))
            return
        }

        let clipped = selection.intersection(bounds)
        let dimColor = NSColor.black.withAlphaComponent(configuration.dimmingOpacity)
        fill(CGRect(x: bounds.minX, y: bounds.minY, width: max(0, clipped.minX - bounds.minX), height: bounds.height), color: dimColor)
        fill(CGRect(x: clipped.maxX, y: bounds.minY, width: max(0, bounds.maxX - clipped.maxX), height: bounds.height), color: dimColor)
        fill(CGRect(x: clipped.minX, y: bounds.minY, width: clipped.width, height: max(0, clipped.minY - bounds.minY)), color: dimColor)
        fill(CGRect(x: clipped.minX, y: clipped.maxY, width: clipped.width, height: max(0, bounds.maxY - clipped.maxY)), color: dimColor)

        let border = NSBezierPath(rect: clipped.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = focusedItem == .region ? 2.5 : 2
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        if focusedItem == .region {
            let focus = NSBezierPath(rect: clipped.insetBy(dx: 3, dy: 3))
            var dash: [CGFloat] = [5, 4]
            focus.setLineDash(&dash, count: dash.count, phase: 0)
            focus.lineWidth = 1
            NSColor.white.withAlphaComponent(0.85).setStroke()
            focus.stroke()
        }

        let handleRectangles = CaptureSelectionGeometry.handleRectangles(
            for: clipped,
            handleSize: configuration.handleSize
        )
        for handle in CaptureSelectionHandle.allCases {
            guard let rectangle = handleRectangles[handle] else { continue }
            let path = NSBezierPath(roundedRect: rectangle, xRadius: 2, yRadius: 2)
            if focusedItem == .handle(handle) {
                NSColor.controlAccentColor.setFill()
                path.fill()
                path.lineWidth = 2
                NSColor.white.setStroke()
                path.stroke()
            } else {
                NSColor.white.setFill()
                path.fill()
                path.lineWidth = 1
                NSColor.black.withAlphaComponent(0.5).setStroke()
                path.stroke()
            }
        }
    }

    private func drawFullscreenOverlay() {
        let opacity = isActiveDisplay
            ? configuration.dimmingOpacity * 0.48
            : configuration.dimmingOpacity * 0.78
        fill(bounds, color: NSColor.black.withAlphaComponent(opacity))

        guard isActiveDisplay else { return }
        let path = NSBezierPath(rect: bounds.insetBy(dx: 5, dy: 5))
        path.lineWidth = 5
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func fill(_ rectangle: CGRect, color: NSColor) {
        guard rectangle.width > 0, rectangle.height > 0 else { return }
        color.setFill()
        NSBezierPath(rect: rectangle).fill()
    }

    private func handle(at point: CGPoint, in selection: CGRect) -> CaptureSelectionHandle? {
        let hitSize = max(18, configuration.handleSize + 8)
        return CaptureSelectionHandle.allCases.first { handle in
            let center = handle.center(in: selection)
            let hitRectangle = CGRect(
                x: center.x - hitSize / 2,
                y: center.y - hitSize / 2,
                width: hitSize,
                height: hitSize
            )
            return hitRectangle.contains(point)
        }
    }

    private func cycleFocus(reverse: Bool) {
        if mode == .fullscreen {
            focusedItem = focusedItem == .recordButton ? .cancelButton : .recordButton
        } else if selection != nil {
            focusedItem = focusedItem.advanced(reverse: reverse)
        }
        updateFocusAppearance()
        needsDisplay = true
    }

    private func handleArrowKey(_ event: NSEvent) {
        guard mode == .area, let selection else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let delta: CGVector

        switch event.keyCode {
        case 123: delta = CGVector(dx: -step, dy: 0)
        case 124: delta = CGVector(dx: step, dy: 0)
        case 125: delta = CGVector(dx: 0, dy: -step)
        case 126: delta = CGVector(dx: 0, dy: step)
        default: return
        }

        switch focusedItem {
        case .region:
            self.selection = CaptureSelectionGeometry.moved(selection, by: delta, in: bounds)

        case let .handle(handle):
            self.selection = CaptureSelectionGeometry.resized(
                selection,
                using: handle,
                delta: delta,
                in: bounds,
                minimumSize: configuration.minimumAreaSize,
                preserveAspectRatio: false
            )

        case .recordButton, .cancelButton:
            return
        }

        updatePresentation()
    }

    private func updateFocusAppearance() {
        updateFocusBorder(for: recordButton, focused: focusedItem == .recordButton)
        updateFocusBorder(for: cancelButton, focused: focusedItem == .cancelButton)
    }

    private var isCreatingSelection: Bool {
        if case .creating? = dragInteraction { return true }
        return false
    }

    private func updateFocusBorder(for button: NSButton, focused: Bool) {
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = focused ? 2 : 0
        button.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
    }

    @objc
    private func recordPressed(_ sender: NSButton) {
        if !isActiveDisplay {
            onActivate(display.id)
            return
        }
        completeSelection()
    }

    @objc
    private func cancelPressed(_ sender: NSButton) {
        onCancel()
    }

    private func completeSelection() {
        guard isActiveDisplay else {
            onActivate(display.id)
            return
        }

        switch mode {
        case .area:
            guard let selection else { return }
            let clamped = CaptureSelectionGeometry.clamped(
                selection,
                to: bounds,
                minimumSize: configuration.minimumAreaSize
            )
            onComplete(
                .area(
                    SelectedCaptureArea(
                        display: display,
                        rectangleInDisplayPoints: clamped,
                        normalizedRectangle: NormalizedCaptureRectangle(rect: clamped, in: bounds),
                        outputPixelSize: CaptureSelectionGeometry.pixelSize(
                            for: clamped,
                            scaleFactor: display.scaleFactor
                        )
                    )
                )
            )

        case .fullscreen:
            onComplete(.fullscreen(display))
        }
    }
}
