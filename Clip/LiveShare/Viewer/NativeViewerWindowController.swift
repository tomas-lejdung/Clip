import AppKit
import QuartzCore

enum NativeViewerWindowCloseDisposition: Sendable {
    case hide
    case leaveSession
}

enum NativeViewerCollaborationControlTool: CaseIterable, Equatable, Hashable, Sendable {
    case pointer
    case ping
    case drawing

    var title: String {
        switch self {
        case .pointer:
            String(localized: "Reveal Pointer")
        case .ping:
            String(localized: "Ping")
        case .drawing:
            String(localized: "Draw")
        }
    }

    var systemImageName: String {
        switch self {
        case .pointer:
            "cursorarrow"
        case .ping:
            "scope"
        case .drawing:
            "pencil.tip"
        }
    }
}

struct NativeViewerCollaborationControlState: Equatable, Sendable {
    var pointerEnabled: Bool
    var pingEnabled: Bool
    var drawingEnabled: Bool
    var isUsingGlobalSettings: Bool

    init(
        pointerEnabled: Bool,
        pingEnabled: Bool,
        drawingEnabled: Bool,
        isUsingGlobalSettings: Bool
    ) {
        self.pointerEnabled = pointerEnabled
        self.pingEnabled = pingEnabled
        self.drawingEnabled = drawingEnabled
        self.isUsingGlobalSettings = isUsingGlobalSettings
    }

    func isEnabled(_ tool: NativeViewerCollaborationControlTool) -> Bool {
        switch tool {
        case .pointer:
            pointerEnabled
        case .ping:
            pingEnabled
        case .drawing:
            drawingEnabled
        }
    }

    static let globalDefaults = NativeViewerCollaborationControlState(
        pointerEnabled: false,
        pingEnabled: false,
        drawingEnabled: false,
        isUsingGlobalSettings: true
    )
}

private enum NativeViewerHeaderAction {
    case followSource
    case native
    case fit
    case matchSourceSize
    case toggleCollaboration(NativeViewerCollaborationControlTool, enabled: Bool)
    case resetCollaborationToGlobal
    case toggleFullScreen
    case close
}

@MainActor
private final class NativeViewerFloatingControlButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var foregroundColor = NSColor.black
    private var selectionColor = NSColor.black.withAlphaComponent(0.12)

    var isControlSelected = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        bezelStyle = .inline
        isBordered = false
        focusRingType = .none
        font = .systemFont(ofSize: 11, weight: .semibold)
        imagePosition = .imageLeading
        alphaValue = 0.72
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let replacement = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(replacement)
        trackingArea = replacement
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance(animated: true)
    }

    func setPalette(foreground: NSColor, selection: NSColor) {
        foregroundColor = foreground
        selectionColor = selection
        updateAppearance()
    }

    private func updateAppearance(animated: Bool = false) {
        let targetAlpha: CGFloat = isHovered || isControlSelected ? 1 : 0.72
        let background = isControlSelected
            ? selectionColor
            : isHovered
                ? foregroundColor.withAlphaComponent(0.10)
                : .clear
        contentTintColor = foregroundColor
        guard animated else {
            alphaValue = targetAlpha
            layer?.backgroundColor = background.cgColor
            return
        }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = targetAlpha
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layer?.backgroundColor = background.cgColor
        CATransaction.commit()
    }
}

@MainActor
private final class NativeViewerFloatingControlGroupView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateAppearance(foreground: NSColor) {
        layer?.backgroundColor = foreground.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
    }
}

@MainActor
private final class NativeViewerHeaderView: NSView {
    static let height: CGFloat = 28
    static let fullScreenHeight: CGFloat = 36
    static let preferredFullScreenWidth: CGFloat = 500
    static let fullScreenHUDReserve: CGFloat =
        MeshParticipantOverlayGeometry.statusHUDSizeWithBringToFront.width
    static let fullScreenHUDGap: CGFloat = 16

    private let titleLabel = NSTextField(labelWithString: "")
    private let materialView = NSVisualEffectView()
    private let collaborationGroup = NativeViewerFloatingControlGroupView()
    private var collaborationButtons:
        [NativeViewerCollaborationControlTool: NativeViewerFloatingControlButton] = [:]
    private let zoomButton = NativeViewerFloatingControlButton()
    private let fullScreenButton = NativeViewerFloatingControlButton()
    private let closeButton = NativeViewerFloatingControlButton()
    private var scaleMode = NativeViewerScaleMode.follow
    private var zoomPercentage = 100
    private var isFullScreen = false
    private var controlsAreInteractive = true
    private var collaborationState = NativeViewerCollaborationControlState.globalDefaults
    private var foregroundColor = NSColor.black
    private var hoverTrackingArea: NSTrackingArea?

    var onAction: ((NativeViewerHeaderAction) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true

        materialView.material = .hudWindow
        materialView.blendingMode = .withinWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 10
        materialView.layer?.masksToBounds = true
        materialView.isHidden = true
        addSubview(materialView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isSelectable = false
        titleLabel.setAccessibilityIdentifier("clip.nativeViewer.windowTitle")
        addSubview(titleLabel)

        addSubview(collaborationGroup)
        for tool in NativeViewerCollaborationControlTool.allCases {
            let button = NativeViewerFloatingControlButton()
            button.title = ""
            button.image = NSImage(
                systemSymbolName: tool.systemImageName,
                accessibilityDescription: tool.title
            )
            button.imagePosition = .imageOnly
            button.toolTip = tool.title
            button.setAccessibilityLabel(tool.title)
            button.setAccessibilityIdentifier(
                "clip.nativeViewer.collaboration.\(String(describing: tool))"
            )
            button.target = self
            button.action = #selector(toggleCollaborationControl(_:))
            button.tag = Self.tag(for: tool)
            collaborationGroup.addSubview(button)
            collaborationButtons[tool] = button
        }

        configureButton(zoomButton, action: #selector(showZoomMenu))
        zoomButton.title = "100%"
        zoomButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        zoomButton.imagePosition = .imageLeading
        // AppKit otherwise anchors the image independently at the leading edge
        // of a wider borderless button. Keep the magnifier and mode title as one
        // centered unit so the computed horizontal inset is real on both sides.
        zoomButton.imageHugsTitle = true
        zoomButton.setAccessibilityLabel(String(localized: "Shared-window zoom"))
        zoomButton.setAccessibilityIdentifier("clip.nativeViewer.zoom")
        addSubview(zoomButton)

        configureButton(fullScreenButton, action: #selector(toggleFullScreen))
        fullScreenButton.title = ""
        fullScreenButton.image = NSImage(
            systemSymbolName: "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: "Enter Full Screen"
        )
        fullScreenButton.imagePosition = .imageOnly
        fullScreenButton.setAccessibilityLabel("Enter Full Screen")
        fullScreenButton.setAccessibilityIdentifier("clip.nativeViewer.fullScreen")
        addSubview(fullScreenButton)

        configureButton(closeButton, action: #selector(closeWindow))
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.setAccessibilityLabel("Close shared window")
        closeButton.setAccessibilityIdentifier("clip.nativeViewer.close")
        addSubview(closeButton)
        updateCollaborationState(.globalDefaults)
        updatePalette(.black)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let replacement = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(replacement)
        hoverTrackingArea = replacement
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func layout() {
        super.layout()
        materialView.frame = bounds
        let closeWidth: CGFloat = 24
        let fullScreenWidth: CGFloat = 24
        let zoomWidth = zoomControlWidth()
        let toolWidth: CGFloat = 24
        let groupPadding: CGFloat = 2
        let groupWidth = CGFloat(collaborationButtons.count) * toolWidth
            + groupPadding * 2
        let controlHeight = min(CGFloat(isFullScreen ? 28 : 22), max(0, bounds.height - 4))
        let controlY = floor((bounds.height - controlHeight) / 2)
        if isFullScreen {
            closeButton.frame = .zero
        } else {
            closeButton.frame = CGRect(
                x: max(4, bounds.width - closeWidth - 4),
                y: controlY,
                width: min(closeWidth, max(0, bounds.width - 8)),
                height: controlHeight
            )
        }
        let fullScreenMaxX = isFullScreen
            ? max(4, bounds.width - 4)
            : closeButton.frame.minX - 2
        fullScreenButton.frame = CGRect(
            x: max(4, fullScreenMaxX - fullScreenWidth),
            y: controlY,
            width: min(fullScreenWidth, max(0, fullScreenMaxX - 4)),
            height: controlHeight
        )
        zoomButton.frame = CGRect(
            x: max(4, fullScreenButton.frame.minX - zoomWidth - 2),
            y: controlY,
            width: min(zoomWidth, max(0, fullScreenButton.frame.minX - 6)),
            height: controlHeight
        )
        let collaborationMaxX = zoomButton.frame.minX - 2
        collaborationGroup.frame = CGRect(
            x: max(4, collaborationMaxX - groupWidth),
            y: controlY,
            width: min(groupWidth, max(0, collaborationMaxX - 4)),
            height: controlHeight
        )
        for (index, tool) in NativeViewerCollaborationControlTool.allCases.enumerated() {
            collaborationButtons[tool]?.frame = CGRect(
                x: groupPadding + CGFloat(index) * toolWidth,
                y: 0,
                width: toolWidth,
                height: controlHeight
            )
        }
        titleLabel.frame = CGRect(
            x: isFullScreen ? 12 : 8,
            y: floor((bounds.height - 17) / 2),
            width: max(0, collaborationGroup.frame.minX - (isFullScreen ? 20 : 15)),
            height: 17
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard controlsAreInteractive else { return nil }
        let hit = super.hitTest(point)
        if let hit,
           hit === zoomButton || hit === fullScreenButton || hit === closeButton
            || collaborationButtons.values.contains(where: { hit === $0 })
            || hit.isDescendant(of: zoomButton)
            || hit.isDescendant(of: fullScreenButton)
            || hit.isDescendant(of: closeButton)
            || hit.isDescendant(of: collaborationGroup) {
            return hit
        }
        return bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    func updateTitle(_ title: String) {
        titleLabel.stringValue = title
        titleLabel.setAccessibilityLabel(title)
    }

    func updatePresentation(mode: NativeViewerScaleMode, zoomPercentage: Int) {
        scaleMode = mode
        self.zoomPercentage = max(1, zoomPercentage)
        switch mode {
        case .follow:
            zoomButton.title = String(localized: "Follow")
        case .native:
            zoomButton.title = String(localized: "Native")
        case .fit:
            zoomButton.title = String(localized: "Fit · \(self.zoomPercentage)%")
        }
        zoomButton.setAccessibilityValue(zoomButton.title)
        needsLayout = true
    }

    func updateCollaborationState(_ state: NativeViewerCollaborationControlState) {
        collaborationState = state
        for (tool, button) in collaborationButtons {
            button.isControlSelected = state.isEnabled(tool)
            button.setAccessibilityValue(
                state.isEnabled(tool)
                    ? String(localized: "On")
                    : String(localized: "Off")
            )
        }
        collaborationGroup.updateAppearance(foreground: foregroundColor)
        needsLayout = true
    }

    func updateFullScreen(_ fullScreen: Bool) {
        isFullScreen = fullScreen
        let symbol = fullScreen
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        let label = fullScreen
            ? String(localized: "Exit Full Screen")
            : String(localized: "Enter Full Screen")
        fullScreenButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )
        fullScreenButton.setAccessibilityLabel(label)
        // Closing the last viewer window may leave the room. Fullscreen must be
        // exited explicitly first so AppKit can restore its Space and window
        // geometry before any close/leave confirmation is possible.
        closeButton.isHidden = fullScreen
        closeButton.setAccessibilityHidden(fullScreen)
        closeButton.isEnabled = controlsAreInteractive && !fullScreen
        materialView.isHidden = !fullScreen
        updatePalette(fullScreen ? .white : foregroundColor)
        needsLayout = true
    }

    func setControlsInteractive(_ interactive: Bool) {
        controlsAreInteractive = interactive
        for button in collaborationButtons.values {
            button.isEnabled = interactive
        }
        for button in [zoomButton, fullScreenButton] {
            button.isEnabled = interactive
        }
        closeButton.isEnabled = interactive && !isFullScreen
    }

    func updateIdentityColor(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        let resolved = luminance > 0.58
            ? NSColor.black.withAlphaComponent(0.82)
            : .white
        updatePalette(isFullScreen ? .white : resolved)
    }

    var controlFrames: (zoom: CGRect, fullScreen: CGRect, close: CGRect) {
        (zoomButton.frame, fullScreenButton.frame, closeButton.frame)
    }

    var controlOpacities: [CGFloat] {
        [zoomButton.alphaValue, fullScreenButton.alphaValue, closeButton.alphaValue]
    }

    var controlTintColors: [NSColor?] {
        [zoomButton.contentTintColor, fullScreenButton.contentTintColor, closeButton.contentTintColor]
    }

    var collaborationControlFrames:
        [NativeViewerCollaborationControlTool: CGRect] {
        collaborationButtons.mapValues { collaborationGroup.convert($0.frame, to: self) }
    }

    var isResetCollaborationVisible: Bool {
        false
    }

    var collaborationControlToolTips:
        [NativeViewerCollaborationControlTool: String?] {
        collaborationButtons.mapValues(\.toolTip)
    }

    var collaborationControlAccessibilityLabels:
        [NativeViewerCollaborationControlTool: String?] {
        collaborationButtons.mapValues { $0.accessibilityLabel() }
    }

    var controlsInteractive: Bool { controlsAreInteractive }

    var controlsEnabled: Bool {
        collaborationButtons.values.allSatisfy(\.isEnabled)
            && [zoomButton, fullScreenButton].allSatisfy(\.isEnabled)
            && (isFullScreen || closeButton.isEnabled)
    }

    var isCloseControlVisible: Bool {
        !closeButton.isHidden && closeButton.frame.width > 0
    }

    func focusCollaborationControl(
        _ tool: NativeViewerCollaborationControlTool
    ) -> Bool {
        guard let button = collaborationButtons[tool], button.isEnabled else {
            return false
        }
        return window?.makeFirstResponder(button) ?? false
    }

    var containsKeyboardFocus: Bool {
        guard let focusedView = window?.firstResponder as? NSView else {
            return false
        }
        return focusedView === self || focusedView.isDescendant(of: self)
    }

    func activateCollaborationControl(
        _ tool: NativeViewerCollaborationControlTool
    ) {
        onAction?(
            .toggleCollaboration(
                tool,
                enabled: !collaborationState.isEnabled(tool)
            )
        )
    }

    func activateResetCollaborationToGlobal() {
        onAction?(.resetCollaborationToGlobal)
    }

    private func configureButton(
        _ button: NativeViewerFloatingControlButton,
        action: Selector
    ) {
        button.target = self
        button.action = action
        button.setPalette(
            foreground: foregroundColor,
            selection: foregroundColor.withAlphaComponent(0.18)
        )
    }

    @objc private func showZoomMenu() {
        let menu = NSMenu(title: String(localized: "Shared Window Zoom"))
        let follow = NSMenuItem(
            title: String(localized: "Follow Source"),
            action: #selector(selectFollow),
            keyEquivalent: ""
        )
        follow.target = self
        follow.state = scaleMode == .follow ? .on : .off
        menu.addItem(follow)

        let native = NSMenuItem(
            title: String(localized: "Native"),
            action: #selector(selectNative),
            keyEquivalent: ""
        )
        native.target = self
        native.state = scaleMode == .native ? .on : .off
        menu.addItem(native)

        let fit = NSMenuItem(
            title: String(localized: "Fit Window"),
            action: #selector(selectFit),
            keyEquivalent: ""
        )
        fit.target = self
        fit.state = scaleMode == .fit ? .on : .off
        menu.addItem(fit)

        menu.addItem(.separator())

        let match = NSMenuItem(
            title: String(localized: "Match Source Size"),
            action: #selector(matchSourceSize),
            keyEquivalent: ""
        )
        match.target = self
        menu.addItem(match)

        let fullScreen = NSMenuItem(
            title: isFullScreen
                ? String(localized: "Exit Full Screen")
                : String(localized: "Enter Full Screen"),
            action: #selector(toggleFullScreen),
            keyEquivalent: ""
        )
        fullScreen.target = self
        menu.addItem(fullScreen)
        menu.popUp(
            positioning: nil,
            at: CGPoint(x: zoomButton.frame.minX, y: zoomButton.frame.minY),
            in: self
        )
    }

    @objc private func selectFollow() {
        onAction?(.followSource)
    }

    @objc private func selectFit() {
        onAction?(.fit)
    }

    @objc private func selectNative() {
        onAction?(.native)
    }

    @objc private func matchSourceSize() {
        onAction?(.matchSourceSize)
    }

    @objc private func toggleCollaborationControl(_ sender: NSButton) {
        guard let tool = Self.tool(for: sender.tag) else { return }
        activateCollaborationControl(tool)
    }

    @objc private func resetCollaborationToGlobal() {
        onAction?(.resetCollaborationToGlobal)
    }

    @objc private func toggleFullScreen() {
        onAction?(.toggleFullScreen)
    }

    @objc private func closeWindow() {
        onAction?(.close)
    }

    private func updatePalette(_ foreground: NSColor) {
        foregroundColor = foreground
        titleLabel.textColor = foreground
        let selection = foreground.withAlphaComponent(isFullScreen ? 0.20 : 0.16)
        for button in collaborationButtons.values {
            button.setPalette(foreground: foreground, selection: selection)
        }
        for button in [
            zoomButton,
            fullScreenButton,
            closeButton,
        ] {
            button.setPalette(foreground: foreground, selection: selection)
        }
        collaborationGroup.updateAppearance(foreground: foreground)
    }

    var collaborationGroupBorderWidth: CGFloat {
        collaborationGroup.layer?.borderWidth ?? 0
    }

    var zoomContentHorizontalPadding: CGFloat {
        max(0, (zoomButton.frame.width - zoomContentWidth()) / 2)
    }

    var zoomControlHugsTitle: Bool {
        zoomButton.imageHugsTitle
    }

    private func zoomControlWidth() -> CGFloat {
        max(68, ceil(zoomContentWidth() + 16))
    }

    private func zoomContentWidth() -> CGFloat {
        let font = zoomButton.font ?? NSFont.systemFont(ofSize: 11)
        let titleWidth = (zoomButton.title as NSString).size(
            withAttributes: [.font: font]
        ).width
        let imageWidth = zoomButton.image?.size.width ?? 0
        let spacing: CGFloat = titleWidth > 0 && imageWidth > 0 ? 4 : 0
        return titleWidth + imageWidth + spacing
    }

    private static func tag(for tool: NativeViewerCollaborationControlTool) -> Int {
        switch tool {
        case .pointer: 1
        case .ping: 2
        case .drawing: 3
        }
    }

    private static func tool(for tag: Int) -> NativeViewerCollaborationControlTool? {
        switch tag {
        case 1: .pointer
        case 2: .ping
        case 3: .drawing
        default: nil
        }
    }
}

@MainActor
final class NativeViewerContentView: NSView {
    static let identityBorderWidth: CGFloat = 6
    static let headerHeight = NativeViewerHeaderView.height

    static var horizontalChrome: CGFloat { identityBorderWidth * 2 }
    static var verticalChrome: CGFloat { identityBorderWidth * 2 + headerHeight }

    let videoView: NSView
    let collaborationOverlayView = NativeViewerCollaborationOverlayView(frame: .zero)

    var onFollowSource: (() -> Void)?
    var onFitToWindow: (() -> Void)?
    var onNativeSize: (() -> Void)?
    var onMatchSourceSize: (() -> Void)?
    var onCollaborationControlChanged:
        ((NativeViewerCollaborationControlTool, Bool) -> Void)?
    var onCollaborationControlResetToGlobal: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onClose: (() -> Void)?

    private let videoViewport = NSView()
    private let headerView = NativeViewerHeaderView(frame: .zero)
    private let cursorLayer = CAShapeLayer()
    private var identityColor: NSColor
    private var isFocused = false
    private var isConnected = true
    private var cursorPosition: CGPoint?
    private var panAnchorPosition: CGPoint?
    private var sourcePixelSize: CGSize?
    private var sourceLogicalSize: CGSize?
    private var sourceStreamID: String?
    private var scaleMode = NativeViewerScaleMode.follow
    private var isPresentationActive = true
    private(set) var isFullScreenPresentation = false
    private var currentNativeOrigin: CGPoint?
    private var targetNativeOrigin: CGPoint?
    private var panGeometryKey: PanGeometryKey?
    private var panTimer: Timer?
    private var fullScreenTrackingArea: NSTrackingArea?
    private var fullScreenHeaderHideTimer: Timer?
    private var fullScreenHeaderHideTimerCreationCount = 0
    private var isFullScreenHeaderHovered = false
    private var headerVisibilityRevision = 0
    private(set) var isFullScreenHeaderVisible = true

    private struct PanGeometryKey: Equatable {
        let sourceSize: CGSize
        let viewportSize: CGSize
    }

    init(videoView: NSView, identityColor: NSColor) {
        self.videoView = videoView
        self.identityColor = identityColor
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = identityColor.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        videoViewport.wantsLayer = true
        videoViewport.layer?.backgroundColor = NSColor.black.cgColor
        videoViewport.layer?.masksToBounds = true
        addSubview(videoViewport)

        videoView.translatesAutoresizingMaskIntoConstraints = true
        videoView.wantsLayer = true
        videoView.layer?.masksToBounds = true
        videoViewport.addSubview(videoView)

        cursorLayer.fillColor = NSColor.clear.cgColor
        cursorLayer.strokeColor = NSColor.white.cgColor
        cursorLayer.lineWidth = 2
        cursorLayer.shadowColor = NSColor.black.cgColor
        cursorLayer.shadowOpacity = 0.8
        cursorLayer.shadowRadius = 2
        cursorLayer.isHidden = true
        videoViewport.layer?.addSublayer(cursorLayer)

        collaborationOverlayView.translatesAutoresizingMaskIntoConstraints = true
        collaborationOverlayView.autoresizingMask = [.width, .height]
        videoViewport.addSubview(collaborationOverlayView)

        headerView.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .followSource:
                onFollowSource?()
            case .fit:
                onFitToWindow?()
            case .native:
                onNativeSize?()
            case .matchSourceSize:
                onMatchSourceSize?()
            case let .toggleCollaboration(tool, enabled):
                onCollaborationControlChanged?(tool, enabled)
            case .resetCollaborationToGlobal:
                onCollaborationControlResetToGlobal?()
            case .toggleFullScreen:
                onToggleFullScreen?()
            case .close:
                onClose?()
            }
        }
        headerView.onHoverChanged = { [weak self] hovered in
            guard let self, isFullScreenPresentation else { return }
            isFullScreenHeaderHovered = hovered
            if hovered {
                showFullScreenHeader(scheduleHide: false)
            } else {
                showFullScreenHeader(scheduleHide: true)
            }
        }
        addSubview(headerView)
        updateFrameColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopPanAnimation()
            stopFullScreenHeaderTimer()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        if let fullScreenTrackingArea {
            removeTrackingArea(fullScreenTrackingArea)
        }
        let replacement = NSTrackingArea(
            rect: bounds,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ],
            owner: self
        )
        addTrackingArea(replacement)
        fullScreenTrackingArea = replacement
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        revealFullScreenHeaderIfNeeded(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        revealFullScreenHeaderIfNeeded(for: event)
    }

    override func layout() {
        super.layout()
        if isFullScreenPresentation {
            videoViewport.frame = bounds
            headerView.frame = Self.fullScreenControlFrame(
                bounds: bounds,
                safeAreaTopInset: window?.screen?.safeAreaInsets.top ?? 0
            )
            cursorLayer.frame = videoViewport.bounds
            collaborationOverlayView.frame = videoViewport.bounds
            layoutVideoSurface()
            return
        }
        let border = Self.identityBorderWidth
        let headerOriginY = max(
            border,
            bounds.height - border - Self.headerHeight
        )
        headerView.frame = CGRect(
            x: border,
            y: headerOriginY,
            width: max(0, bounds.width - border * 2),
            // The top identity border is visually part of the colored header.
            // Include it in the header view so its controls are centered in
            // the complete visible bar rather than only the lower 28 points.
            height: max(0, bounds.height - headerOriginY)
        )
        videoViewport.frame = CGRect(
            x: border,
            y: border,
            width: max(0, bounds.width - border * 2),
            height: max(0, bounds.height - border * 2 - Self.headerHeight)
        )
        cursorLayer.frame = videoViewport.bounds
        collaborationOverlayView.frame = videoViewport.bounds
        layoutVideoSurface()
    }

    func update(
        ownerName: String,
        source: NativeViewerSourceSnapshot,
        identityColor: NSColor,
        resolvedSourceLogicalSize: CGSize
    ) {
        if sourceStreamID != source.streamID {
            cursorPosition = nil
            panAnchorPosition = nil
        }
        sourceStreamID = source.streamID
        self.identityColor = identityColor
        isFocused = source.isFocused
        isConnected = source.isConnected
        sourcePixelSize = source.pixelSize
        sourceLogicalSize = resolvedSourceLogicalSize
        if !source.isFocused || !source.isConnected {
            cursorPosition = nil
        }
        let title = Self.title(ownerName: ownerName, source: source)
        headerView.updateTitle(title)
        setAccessibilityLabel("\(title), shared window")
        updateFrameColor()
        resetPanGeometry()
        needsLayout = true
    }

    func updateResolvedSourceLogicalSize(_ size: CGSize) {
        guard sourceLogicalSize != size else { return }
        sourceLogicalSize = size
        resetPanGeometry()
        needsLayout = true
    }

    func setScaleMode(_ mode: NativeViewerScaleMode) {
        guard scaleMode != mode else {
            updateZoomIndicator()
            return
        }
        scaleMode = mode
        resetPanGeometry()
        updateZoomIndicator()
        needsLayout = true
    }

    func setFullScreenPresentation(_ fullScreen: Bool) {
        guard isFullScreenPresentation != fullScreen else { return }
        isFullScreenPresentation = fullScreen
        layer?.cornerRadius = fullScreen ? 0 : 10
        headerView.updateFullScreen(fullScreen)
        updateFrameColor()
        if fullScreen {
            showFullScreenHeader(scheduleHide: true)
        } else {
            stopFullScreenHeaderTimer()
            isFullScreenHeaderHovered = false
            setFullScreenHeaderVisible(true)
        }
        resetPanGeometry()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setCursor(normalizedX: CGFloat?, normalizedY: CGFloat?) {
        if let normalizedX, let normalizedY,
           normalizedX.isFinite, normalizedY.isFinite,
           (0...1).contains(normalizedX), (0...1).contains(normalizedY) {
            let position = CGPoint(x: normalizedX, y: normalizedY)
            cursorPosition = position
            panAnchorPosition = position
        } else {
            cursorPosition = nil
        }
        updateNativePanTarget(animated: true)
        layoutCursor()
    }

    func setPresentationActive(_ active: Bool) {
        guard isPresentationActive != active else { return }
        isPresentationActive = active
        if active {
            updateNativePanTarget(animated: false)
            needsLayout = true
        } else {
            stopPanAnimation()
        }
    }

    func setCollaborationOverlay(
        _ snapshot: NativeViewerCollaborationOverlaySnapshot
    ) {
        collaborationOverlayView.update(snapshot)
    }

    func setCollaborationInteractionMode(
        _ mode: NativeViewerCollaborationInteractionMode
    ) {
        collaborationOverlayView.interactionMode = mode
    }

    func setCollaborationControlState(
        _ state: NativeViewerCollaborationControlState
    ) {
        headerView.updateCollaborationState(state)
    }

    func activateCollaborationControl(
        _ tool: NativeViewerCollaborationControlTool
    ) {
        headerView.activateCollaborationControl(tool)
    }

    func activateResetCollaborationToGlobal() {
        headerView.activateResetCollaborationToGlobal()
    }

    static func cursorPoint(
        normalizedX: CGFloat,
        normalizedY: CGFloat,
        videoFrame: CGRect,
        sourcePixelSize: CGSize? = nil
    ) -> CGPoint {
        let renderedFrame = aspectFitContentRect(
            sourcePixelSize: sourcePixelSize,
            videoFrame: videoFrame
        )
        return CGPoint(
            x: renderedFrame.minX + normalizedX * renderedFrame.width,
            y: renderedFrame.maxY - normalizedY * renderedFrame.height
        )
    }

    static func aspectFitContentRect(
        sourcePixelSize: CGSize?,
        videoFrame: CGRect
    ) -> CGRect {
        guard let sourcePixelSize,
              sourcePixelSize.width.isFinite,
              sourcePixelSize.height.isFinite,
              sourcePixelSize.width > 0,
              sourcePixelSize.height > 0,
              videoFrame.width > 0,
              videoFrame.height > 0 else {
            return videoFrame
        }
        let scale = min(
            videoFrame.width / sourcePixelSize.width,
            videoFrame.height / sourcePixelSize.height
        )
        let renderedSize = CGSize(
            width: sourcePixelSize.width * scale,
            height: sourcePixelSize.height * scale
        )
        return CGRect(
            x: videoFrame.midX - renderedSize.width / 2,
            y: videoFrame.midY - renderedSize.height / 2,
            width: renderedSize.width,
            height: renderedSize.height
        )
    }

    var videoViewportFrame: CGRect { videoViewport.frame }
    var headerFrame: CGRect { headerView.frame }
    var zoomPercentage: Int {
        if !isFullScreenPresentation, scaleMode != .fit { return 100 }
        return NativeViewerPanPolicy.zoomPercentage(
            sourceLogicalSize: sourceLogicalSize ?? .zero,
            renderedContentSize: videoView.frame.size
        ) ?? 100
    }
    var headerControlFrames: (zoom: CGRect, fullScreen: CGRect, close: CGRect) {
        headerView.controlFrames
    }
    var headerControlOpacities: [CGFloat] { headerView.controlOpacities }
    var headerControlTintColors: [NSColor?] { headerView.controlTintColors }
    var collaborationControlFrames:
        [NativeViewerCollaborationControlTool: CGRect] {
        headerView.collaborationControlFrames
    }
    var isResetCollaborationControlVisible: Bool {
        headerView.isResetCollaborationVisible
    }
    var collaborationControlGroupBorderWidth: CGFloat {
        headerView.collaborationGroupBorderWidth
    }
    var zoomControlHorizontalPadding: CGFloat {
        headerView.zoomContentHorizontalPadding
    }
    var zoomControlHugsTitle: Bool {
        headerView.zoomControlHugsTitle
    }
    var collaborationControlToolTips:
        [NativeViewerCollaborationControlTool: String?] {
        headerView.collaborationControlToolTips
    }
    var collaborationControlAccessibilityLabels:
        [NativeViewerCollaborationControlTool: String?] {
        headerView.collaborationControlAccessibilityLabels
    }
    var areFullScreenControlsInteractive: Bool {
        headerView.controlsInteractive
    }
    var areFullScreenControlsEnabled: Bool {
        headerView.controlsEnabled
    }
    var isCloseControlVisible: Bool {
        headerView.isCloseControlVisible
    }
    var fullScreenHideTimerCreationCount: Int {
        fullScreenHeaderHideTimerCreationCount
    }
    var hasKeyboardFocusedFullScreenControl: Bool {
        headerView.containsKeyboardFocus
    }

    static func fullScreenControlFrame(
        bounds: CGRect,
        safeAreaTopInset: CGFloat
    ) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let horizontalInset: CGFloat = 16
        // The sharing HUD occupies the top-right corner. Because this capsule
        // remains centered, reserving the HUD on the right also requires the
        // same amount on the left. Capping the width this way preserves the
        // centered composition on narrower fullscreen displays instead of
        // letting the capsule slide under the HUD.
        let hudSafeCenteredWidth = bounds.width - 2 * (
            NativeViewerHeaderView.fullScreenHUDReserve
                + NativeViewerHeaderView.fullScreenHUDGap
        )
        let width = min(
            NativeViewerHeaderView.preferredFullScreenWidth,
            max(
                0,
                min(
                    bounds.width - horizontalInset * 2,
                    hudSafeCenteredWidth
                )
            )
        )
        let height = min(
            NativeViewerHeaderView.fullScreenHeight,
            bounds.height
        )
        // macOS reveals its menu/status bar at the display's top edge. The
        // centered Clip capsule stays below both that transient surface and a
        // possible notch, and it deliberately avoids Clip's top-right sharing
        // HUD. `safeAreaTopInset` is zero on displays without a notch, so retain
        // a menu-bar-sized minimum clearance there as well.
        let topClearance = max(CGFloat(44), safeAreaTopInset + 14)
        return CGRect(
            x: floor(bounds.midX - width / 2),
            y: max(12, floor(bounds.maxY - topClearance - height)),
            width: width,
            height: height
        )
    }

    private func layoutVideoSurface() {
        guard videoViewport.bounds.width > 0, videoViewport.bounds.height > 0 else {
            videoView.frame = .zero
            collaborationOverlayView.contentFrame = .zero
            return
        }
        if usesNativeViewport,
           let sourceLogicalSize,
           let geometry = NativeViewerPanPolicy.geometry(
               sourceLogicalSize: sourceLogicalSize,
               viewportSize: videoViewport.bounds.size,
               normalizedCursor: panAnchorPosition
           ) {
            let alignedSize = NativeViewerPanPolicy.backingAlignedFrame(
                CGRect(origin: .zero, size: geometry.contentFrame.size),
                backingScale: effectiveBackingScale
            ).size
            let alignedOrigin = NativeViewerPanPolicy.snappedContentOrigin(
                geometry.contentFrame.origin,
                backingScale: effectiveBackingScale,
                sourceLogicalSize: alignedSize,
                viewportSize: videoViewport.bounds.size
            )
            let key = PanGeometryKey(
                sourceSize: alignedSize,
                viewportSize: videoViewport.bounds.size
            )
            targetNativeOrigin = alignedOrigin
            if panGeometryKey != key || currentNativeOrigin == nil {
                panGeometryKey = key
                currentNativeOrigin = alignedOrigin
            }
            videoView.frame = CGRect(
                origin: NativeViewerPanPolicy.snappedContentOrigin(
                    currentNativeOrigin ?? alignedOrigin,
                    backingScale: effectiveBackingScale,
                    sourceLogicalSize: alignedSize,
                    viewportSize: videoViewport.bounds.size
                ),
                size: alignedSize
            )
        } else {
            stopPanAnimation()
            currentNativeOrigin = nil
            targetNativeOrigin = nil
            panGeometryKey = nil
            videoView.frame = NativeViewerPanPolicy.backingAlignedFrame(
                Self.aspectFitContentRect(
                    sourcePixelSize: sourceLogicalSize ?? sourcePixelSize,
                    videoFrame: videoViewport.bounds
                ),
                backingScale: effectiveBackingScale
            )
        }
        collaborationOverlayView.contentFrame = videoView.frame
        updateZoomIndicator()
        layoutCursor()
    }

    private func updateNativePanTarget(animated: Bool) {
        guard isPresentationActive,
              usesNativeViewport,
              let sourceLogicalSize,
              let geometry = NativeViewerPanPolicy.geometry(
                  sourceLogicalSize: sourceLogicalSize,
                  viewportSize: videoViewport.bounds.size,
                  normalizedCursor: panAnchorPosition
              ) else {
            stopPanAnimation()
            return
        }
        let alignedSize = NativeViewerPanPolicy.backingAlignedFrame(
            CGRect(origin: .zero, size: geometry.contentFrame.size),
            backingScale: effectiveBackingScale
        ).size
        let alignedOrigin = NativeViewerPanPolicy.snappedContentOrigin(
            geometry.contentFrame.origin,
            backingScale: effectiveBackingScale,
            sourceLogicalSize: alignedSize,
            viewportSize: videoViewport.bounds.size
        )
        targetNativeOrigin = alignedOrigin
        if currentNativeOrigin == nil {
            currentNativeOrigin = alignedOrigin
            applyCurrentNativeFrame()
            return
        }
        if let currentNativeOrigin,
           abs(alignedOrigin.x - currentNativeOrigin.x) < 0.35,
           abs(alignedOrigin.y - currentNativeOrigin.y) < 0.35 {
            self.currentNativeOrigin = alignedOrigin
            applyCurrentNativeFrame()
            stopPanAnimation()
            return
        }
        if animated {
            startPanAnimation()
        } else {
            currentNativeOrigin = geometry.contentFrame.origin
            applyCurrentNativeFrame()
        }
    }

    /// Native always renders the host's logical surface at 100%, including in
    /// fullscreen, where an oversized source is cropped and follows the cursor.
    /// Follow retains its established fullscreen fit behavior, while windowed
    /// Follow remains the automatic form of Native.
    private var usesNativeViewport: Bool {
        scaleMode == .native
            || (!isFullScreenPresentation && scaleMode == .follow)
    }

    private func startPanAnimation() {
        guard panTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advancePanAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        panTimer = timer
    }

    private func advancePanAnimation() {
        guard let currentNativeOrigin, let targetNativeOrigin else {
            stopPanAnimation()
            return
        }
        let delta = CGPoint(
            x: targetNativeOrigin.x - currentNativeOrigin.x,
            y: targetNativeOrigin.y - currentNativeOrigin.y
        )
        if abs(delta.x) < 0.35, abs(delta.y) < 0.35 {
            self.currentNativeOrigin = targetNativeOrigin
            applyCurrentNativeFrame()
            stopPanAnimation()
            return
        }
        self.currentNativeOrigin = CGPoint(
            x: currentNativeOrigin.x + delta.x * 0.2,
            y: currentNativeOrigin.y + delta.y * 0.2
        )
        applyCurrentNativeFrame()
    }

    private func applyCurrentNativeFrame() {
        guard let currentNativeOrigin, let sourceLogicalSize else { return }
        let alignedSize = NativeViewerPanPolicy.backingAlignedFrame(
            CGRect(origin: .zero, size: sourceLogicalSize),
            backingScale: effectiveBackingScale
        ).size
        videoView.frame = CGRect(
            origin: NativeViewerPanPolicy.snappedContentOrigin(
                currentNativeOrigin,
                backingScale: effectiveBackingScale,
                sourceLogicalSize: alignedSize,
                viewportSize: videoViewport.bounds.size
            ),
            size: alignedSize
        )
        collaborationOverlayView.contentFrame = videoView.frame
        layoutCursor()
    }

    private var effectiveBackingScale: CGFloat {
        if let scale = window?.backingScaleFactor,
           scale.isFinite,
           scale > 0 {
            return scale
        }
        if let scale = layer?.contentsScale,
           scale.isFinite,
           scale > 0 {
            return scale
        }
        return 1
    }

    private func stopPanAnimation() {
        panTimer?.invalidate()
        panTimer = nil
    }

    private func revealFullScreenHeaderIfNeeded(for event: NSEvent) {
        guard isFullScreenPresentation else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard Self.shouldRevealFullScreenHeader(
            pointer: point,
            bounds: bounds,
            headerFrame: headerView.frame
        ) else { return }
        showFullScreenHeader(scheduleHide: true)
    }

    static func shouldRevealFullScreenHeader(
        pointer: CGPoint,
        bounds: CGRect,
        headerFrame: CGRect
    ) -> Bool {
        bounds.contains(pointer)
            || headerFrame.insetBy(dx: -8, dy: -8).contains(pointer)
    }

    private func showFullScreenHeader(scheduleHide: Bool) {
        setFullScreenHeaderVisible(true)
        guard scheduleHide,
              isFullScreenPresentation,
              !isFullScreenHeaderHovered else {
            stopFullScreenHeaderTimer()
            return
        }
        scheduleFullScreenHeaderHide()
    }

    private func scheduleFullScreenHeaderHide() {
        let fireDate = Date(timeIntervalSinceNow: 2.2)
        if let fullScreenHeaderHideTimer,
           fullScreenHeaderHideTimer.isValid {
            fullScreenHeaderHideTimer.fireDate = fireDate
            return
        }
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fullScreenHeaderHideTimer = nil
                self.hideFullScreenHeaderForInactivity()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullScreenHeaderHideTimer = timer
        fullScreenHeaderHideTimerCreationCount += 1
    }

    func noteFullScreenPointerActivityForTesting() {
        guard isFullScreenPresentation else { return }
        showFullScreenHeader(scheduleHide: true)
    }

    func focusFullScreenCollaborationControlForTesting(
        _ tool: NativeViewerCollaborationControlTool
    ) -> Bool {
        headerView.focusCollaborationControl(tool)
    }

    func hideFullScreenHeaderImmediatelyForTesting() {
        stopFullScreenHeaderTimer()
        setFullScreenHeaderVisible(false)
    }

    func hideFullScreenHeaderForInactivity() {
        stopFullScreenHeaderTimer()
        guard isFullScreenPresentation else { return }
        if isFullScreenHeaderHovered {
            showFullScreenHeader(scheduleHide: false)
            return
        }
        if let window {
            let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if headerView.frame.insetBy(dx: -8, dy: -8).contains(pointer) {
                showFullScreenHeader(scheduleHide: true)
                return
            }
        }
        setFullScreenHeaderVisible(false)
    }

    private func setFullScreenHeaderVisible(_ visible: Bool) {
        isFullScreenHeaderVisible = visible
        headerVisibilityRevision += 1
        let revision = headerVisibilityRevision
        headerView.setAccessibilityHidden(!visible)
        if !visible, headerView.containsKeyboardFocus {
            window?.makeFirstResponder(nil)
        }
        headerView.setControlsInteractive(visible)
        if visible {
            headerView.isHidden = false
        }
        let targetAlpha: CGFloat = visible ? 1 : 0
        guard headerView.alphaValue != targetAlpha else {
            headerView.isHidden = !visible
            return
        }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                headerView.animator().alphaValue = targetAlpha
            },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          self.headerVisibilityRevision == revision,
                          !visible else { return }
                    self.headerView.isHidden = true
                }
            }
        )
    }

    private func stopFullScreenHeaderTimer() {
        fullScreenHeaderHideTimer?.invalidate()
        fullScreenHeaderHideTimer = nil
    }

    private func resetPanGeometry() {
        stopPanAnimation()
        currentNativeOrigin = nil
        targetNativeOrigin = nil
        panGeometryKey = nil
    }

    private func updateFrameColor() {
        let baseColor = isConnected ? identityColor : .systemGray
        let color = isFocused
            ? baseColor.blended(withFraction: 0.18, of: .white) ?? baseColor
            : baseColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = isFullScreenPresentation
            ? NSColor.black.cgColor
            : color.withAlphaComponent(isFocused ? 0.98 : 0.82).cgColor
        cursorLayer.strokeColor = color.cgColor
        CATransaction.commit()
        headerView.updateIdentityColor(isFullScreenPresentation ? .black : color)
    }

    private func updateZoomIndicator() {
        headerView.updatePresentation(
            mode: scaleMode,
            zoomPercentage: zoomPercentage
        )
    }

    private func layoutCursor() {
        guard let cursorPosition else {
            cursorLayer.isHidden = true
            return
        }
        let point = CGPoint(
            x: videoView.frame.minX + cursorPosition.x * videoView.frame.width,
            y: videoView.frame.maxY - cursorPosition.y * videoView.frame.height
        )
        let radius: CGFloat = 8
        cursorLayer.path = CGPath(
            ellipseIn: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ),
            transform: nil
        )
        cursorLayer.isHidden = !videoViewport.bounds.contains(point)
    }

    private static func title(
        ownerName: String,
        source: NativeViewerSourceSnapshot
    ) -> String {
        let sourceName = source.windowName.isEmpty ? source.applicationName : source.windowName
        return "\(ownerName) · \(sourceName)"
    }
}

@MainActor
private final class NativeViewerPresentationWindow: NSWindow {
    var onEscapePressed: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, styleMask.contains(.fullScreen) else {
            super.keyDown(with: event)
            return
        }
        onEscapePressed?()
    }
}

@MainActor
final class NativeViewerWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultMinimumFrameSize = CGSize(
        width: 320 + NativeViewerContentView.horizontalChrome,
        height: 180 + NativeViewerContentView.verticalChrome
    )

    let viewerWindowID: NativeViewerWindowID
    let content: NativeViewerContentView

    var onCloseRequested: ((NativeViewerWindowController) -> NativeViewerWindowCloseDisposition)?
    /// User-originated mode changes. Programmatic synchronization through
    /// `setScaleMode(_:)` deliberately does not echo through this callback.
    var onScaleModeChanged: ((NativeViewerWindowController, NativeViewerScaleMode) -> Void)?
    var onFullScreenChanged: ((NativeViewerWindowController, Bool) -> Void)?
    var onCollaborationControlChanged: ((
        NativeViewerWindowController,
        NativeViewerCollaborationControlTool,
        Bool
    ) -> Void)?
    var onCollaborationControlResetToGlobal:
        ((NativeViewerWindowController) -> Void)?

    private(set) var scaleMode = NativeViewerScaleMode.follow
    private(set) var isFullScreen = false
    private var source: NativeViewerSourceSnapshot
    private var dimensionStabilizer = NativeViewerDimensionStabilizer()
    private var isApplyingPolicySize = false
    private var pendingPolicyResizeAfterFullScreen = false
    private var pendingHideAfterFullScreen = false
    private enum FullScreenTransition: Equatable {
        case idle
        case entering
        case exiting
    }
    private var fullScreenTransition = FullScreenTransition.idle
    private var tearDownRequested = false
    private var tearDownCompleted = false
    private var tearDownFullScreenExitAttempts = 0
    private var pendingFullScreenExitAction: ((NSWindow) -> Void)?
    // The coordinator releases its entry synchronously. Retain this controller
    // until AppKit finishes restoring a fullscreen window, then close it.
    private var pendingTearDownRetain: NativeViewerWindowController?

    init(
        id: NativeViewerWindowID,
        ownerName: String,
        source: NativeViewerSourceSnapshot,
        identityColor: NSColor,
        videoView: NSView
    ) {
        viewerWindowID = id
        self.source = source
        content = NativeViewerContentView(videoView: videoView, identityColor: identityColor)
        let initialSourceSize = source.sourcePointSize
        let initialScale = min(
            1,
            960 / initialSourceSize.width,
            540 / initialSourceSize.height
        )
        let initialVideoSize = CGSize(
            width: max(320, initialSourceSize.width * initialScale),
            height: max(180, initialSourceSize.height * initialScale)
        )
        let window = NativeViewerPresentationWindow(
            contentRect: CGRect(
                origin: .zero,
                size: CGSize(
                    width: initialVideoSize.width + NativeViewerContentView.horizontalChrome,
                    height: initialVideoSize.height + NativeViewerContentView.verticalChrome
                )
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.contentView = content
        window.delegate = self
        window.tabbingMode = .disallowed
        window.title = Self.title(ownerName: ownerName, source: source)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.minSize = Self.defaultMinimumFrameSize
        window.setAccessibilitySubrole(.standardWindow)
        window.onEscapePressed = { [weak self] in
            self?.toggleFullScreen()
        }

        content.onFollowSource = { [weak self] in
            self?.setUserScaleMode(.follow)
        }
        content.onFitToWindow = { [weak self] in
            self?.setUserScaleMode(.fit)
        }
        content.onNativeSize = { [weak self] in
            self?.setUserScaleMode(.native)
        }
        content.onMatchSourceSize = { [weak self] in
            self?.matchSourceSize()
        }
        content.onCollaborationControlChanged = { [weak self] tool, enabled in
            guard let self else { return }
            onCollaborationControlChanged?(self, tool, enabled)
        }
        content.onCollaborationControlResetToGlobal = { [weak self] in
            guard let self else { return }
            onCollaborationControlResetToGlobal?(self)
        }
        content.onToggleFullScreen = { [weak self] in
            self?.toggleFullScreen()
        }
        content.onClose = { [weak self] in
            self?.requestClose()
        }
        content.update(
            ownerName: ownerName,
            source: source,
            identityColor: identityColor,
            resolvedSourceLogicalSize: Self.resolvedSourceLogicalSize(
                source: source,
                destinationBackingScale: window.backingScaleFactor
            )
        )
        content.setScaleMode(scaleMode)
        applyPixelSize(source.pixelSize, authoritative: source.pixelSize, revision: source.stateRevision)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        ownerName: String,
        source: NativeViewerSourceSnapshot,
        identityColor: NSColor
    ) {
        guard source.stateRevision >= self.source.stateRevision else { return }
        let previousSourcePointSize = self.source.sourcePointSize
        self.source = source
        window?.title = Self.title(ownerName: ownerName, source: source)
        content.update(
            ownerName: ownerName,
            source: source,
            identityColor: identityColor,
            resolvedSourceLogicalSize: Self.resolvedSourceLogicalSize(
                source: source,
                destinationBackingScale: window?.backingScaleFactor ?? 1
            )
        )
        content.setScaleMode(scaleMode)
        applyPixelSize(source.pixelSize, authoritative: source.pixelSize, revision: source.stateRevision)
        if scaleMode == .native {
            updateWindowMinimumSize(for: scaleMode)
            clampCurrentNativeWindowIfNeeded()
        }
        if previousSourcePointSize != source.sourcePointSize,
           scaleMode == .follow,
           let committed = dimensionStabilizer.committedPixelSize {
            resizeVideoContent(for: committed)
        }
    }

    func decodedPixelSizeDidChange(_ size: CGSize) {
        applyPixelSize(size, authoritative: source.pixelSize, revision: source.stateRevision)
    }

    func setScaleMode(_ mode: NativeViewerScaleMode) {
        let changed = scaleMode != mode
        scaleMode = mode
        if changed, mode != .follow {
            // A host-size update may have arrived while Follow was fullscreen.
            // Once the viewer chooses Native or Fit, that queued Follow resize
            // must not overwrite the viewer-owned frame on fullscreen exit.
            pendingPolicyResizeAfterFullScreen = false
        }
        updateWindowMinimumSize(for: mode)
        content.setScaleMode(mode)
        if mode == .follow,
           let committed = dimensionStabilizer.committedPixelSize {
            resizeVideoContent(for: committed)
        } else if mode == .native {
            clampCurrentNativeWindowIfNeeded()
        } else if changed {
            pendingPolicyResizeAfterFullScreen = false
            content.layoutSubtreeIfNeeded()
        }
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    func setCollaborationControlState(
        _ state: NativeViewerCollaborationControlState
    ) {
        content.setCollaborationControlState(state)
    }

    func showWithoutTakingFocus() {
        pendingHideAfterFullScreen = false
        content.setPresentationActive(true)
        window?.orderFront(nil)
    }

    func bringToFrontWithoutTakingFocus() {
        pendingHideAfterFullScreen = false
        content.setPresentationActive(true)
        if isFullScreen {
            window?.orderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    func hide() {
        guard !isFullScreen else {
            // Ordering out a fullscreen window can strand a hidden fullscreen
            // Space and leave the coordinator's fullscreen state stale. Exit
            // through AppKit first, then hide after the restored frame exists.
            guard !pendingHideAfterFullScreen else { return }
            pendingHideAfterFullScreen = true
            window?.toggleFullScreen(nil)
            return
        }
        performHide()
    }

    private func performHide() {
        content.setPresentationActive(false)
        window?.orderOut(nil)
    }

    func tearDown() {
        tearDown(requestFullScreenExit: { window in
            window.toggleFullScreen(nil)
        })
    }

    func tearDown(
        requestFullScreenExit: @escaping (NSWindow) -> Void
    ) {
        guard !tearDownRequested else { return }
        tearDownRequested = true
        pendingFullScreenExitAction = requestFullScreenExit
        pendingPolicyResizeAfterFullScreen = false
        pendingHideAfterFullScreen = false
        onCloseRequested = nil
        onScaleModeChanged = nil
        onFullScreenChanged = nil
        onCollaborationControlChanged = nil
        onCollaborationControlResetToGlobal = nil
        (window as? NativeViewerPresentationWindow)?.onEscapePressed = nil
        content.onFollowSource = nil
        content.onFitToWindow = nil
        content.onNativeSize = nil
        content.onMatchSourceSize = nil
        content.onCollaborationControlChanged = nil
        content.onCollaborationControlResetToGlobal = nil
        content.onToggleFullScreen = nil
        content.onClose = nil
        content.setPresentationActive(false)

        guard let window else {
            finishTearDown()
            return
        }
        guard fullScreenTransition != .entering else {
            pendingTearDownRetain = self
            return
        }
        guard isFullScreen
            || fullScreenTransition == .exiting
            || window.styleMask.contains(.fullScreen) else {
            finishTearDown()
            return
        }
        pendingTearDownRetain = self
        requestFullScreenExitIfNeeded()
    }

    private func requestFullScreenExitIfNeeded() {
        guard tearDownRequested,
              fullScreenTransition == .idle,
              let window,
              let pendingFullScreenExitAction else { return }
        tearDownFullScreenExitAttempts += 1
        pendingFullScreenExitAction(window)
    }

    private func finishTearDown() {
        guard !tearDownCompleted else { return }
        tearDownCompleted = true
        pendingFullScreenExitAction = nil
        pendingPolicyResizeAfterFullScreen = false
        pendingHideAfterFullScreen = false
        window?.delegate = nil
        content.removeFromSuperview()
        close()
        pendingTearDownRetain = nil
    }

    var isTearDownPendingFullScreenExit: Bool {
        tearDownRequested && !tearDownCompleted
    }

    var hasCompletedTearDown: Bool {
        tearDownCompleted
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch onCloseRequested?(self) ?? .hide {
        case .hide:
            hide()
            return false
        case .leaveSession:
            return true
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard !isApplyingPolicySize else { return }
        guard !isFullScreen else { return }
        if scaleMode == .follow {
            setUserScaleMode(.native)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        refreshResolvedSourceLogicalSize()
        if scaleMode == .native {
            updateWindowMinimumSize(for: scaleMode)
            clampCurrentNativeWindowIfNeeded()
            return
        }
        guard scaleMode == .follow,
              let committed = dimensionStabilizer.committedPixelSize else { return }
        resizeVideoContent(for: committed)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        refreshResolvedSourceLogicalSize()
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        if scaleMode == .native {
            updateWindowMinimumSize(for: scaleMode)
            clampCurrentNativeWindowIfNeeded()
            return
        }
        guard scaleMode == .follow,
              let committed = dimensionStabilizer.committedPixelSize else { return }
        resizeVideoContent(for: committed)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreenTransition = .entering
        isFullScreen = true
        content.setFullScreenPresentation(true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenTransition = .idle
        if tearDownRequested {
            requestFullScreenExitIfNeeded()
            return
        }
        onFullScreenChanged?(self, true)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        fullScreenTransition = .exiting
        // Keep the edge-to-edge presentation through AppKit's exit animation.
        // The restored window frame and persistent mode take effect together
        // in `windowDidExitFullScreen`.
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransition = .idle
        isFullScreen = false
        content.setFullScreenPresentation(false)
        if tearDownRequested {
            finishTearDown()
            return
        }
        updateWindowMinimumSize(for: scaleMode)
        if scaleMode == .native {
            // Native keeps a viewer-owned frame while fullscreen, but a host
            // shrink received during that time must apply once the restored
            // window can be resized safely.
            clampCurrentNativeWindowIfNeeded()
        }
        onFullScreenChanged?(self, false)
        if pendingPolicyResizeAfterFullScreen,
           let committed = dimensionStabilizer.committedPixelSize {
            pendingPolicyResizeAfterFullScreen = false
            resizeVideoContent(for: committed)
        } else {
            pendingPolicyResizeAfterFullScreen = false
        }
        if pendingHideAfterFullScreen {
            pendingHideAfterFullScreen = false
            performHide()
        }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenTransition = .idle
        isFullScreen = false
        content.setFullScreenPresentation(false)
        if tearDownRequested {
            finishTearDown()
        }
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullScreenTransition = .idle
        isFullScreen = true
        pendingHideAfterFullScreen = false
        content.setFullScreenPresentation(true)
        guard tearDownRequested else { return }
        if tearDownFullScreenExitAttempts < 2 {
            DispatchQueue.main.async { [weak self] in
                self?.requestFullScreenExitIfNeeded()
            }
        } else {
            // A failed AppKit exit should not leave a permanently retained,
            // frozen viewer. Closing is the last-resort cleanup after a retry.
            finishTearDown()
        }
    }

    func windowWillResize(
        _ sender: NSWindow,
        to frameSize: NSSize
    ) -> NSSize {
        guard !isApplyingPolicySize, !isFullScreen else { return frameSize }
        if scaleMode == .follow {
            setUserScaleMode(.native)
        }
        guard scaleMode == .native else { return frameSize }
        return clampedNativeFrameSize(frameSize, for: sender)
    }

    private func setUserScaleMode(_ mode: NativeViewerScaleMode) {
        guard scaleMode != mode else {
            if mode == .follow,
               let committed = dimensionStabilizer.committedPixelSize {
                resizeVideoContent(for: committed)
            }
            return
        }
        scaleMode = mode
        if mode != .follow {
            // See `setScaleMode(_:)`: manual resize and header-menu changes
            // must cancel any Follow resize deferred by fullscreen.
            pendingPolicyResizeAfterFullScreen = false
        }
        updateWindowMinimumSize(for: mode)
        content.setScaleMode(mode)
        if mode == .follow,
           let committed = dimensionStabilizer.committedPixelSize {
            resizeVideoContent(for: committed)
        } else if mode == .native {
            clampCurrentNativeWindowIfNeeded()
        } else {
            pendingPolicyResizeAfterFullScreen = false
            content.layoutSubtreeIfNeeded()
        }
        onScaleModeChanged?(self, mode)
    }

    private func matchSourceSize() {
        if let committed = dimensionStabilizer.committedPixelSize {
            resizeVideoContent(for: committed)
        }
    }

    private func requestClose() {
        guard let window else { return }
        if windowShouldClose(window) {
            close()
        }
    }

    private func refreshResolvedSourceLogicalSize() {
        content.updateResolvedSourceLogicalSize(Self.resolvedSourceLogicalSize(
            source: source,
            destinationBackingScale: window?.backingScaleFactor ?? 1
        ))
    }

    private func applyPixelSize(
        _ size: CGSize,
        authoritative: CGSize?,
        revision: UInt64
    ) {
        guard let committed = dimensionStabilizer.observe(
            decodedPixelSize: size,
            authoritativePixelSize: authoritative,
            stateRevision: revision
        ) else { return }
        guard scaleMode == .follow else { return }
        if isFullScreen {
            pendingPolicyResizeAfterFullScreen = true
        } else {
            resizeVideoContent(for: committed)
        }
    }

    private func resizeVideoContent(for pixelSize: CGSize) {
        if isFullScreen {
            pendingPolicyResizeAfterFullScreen = true
            return
        }
        guard let window,
              let screen = window.screen ?? NSScreen.main else { return }
        let backingScale = max(1, screen.backingScaleFactor)
        let contentFrame = window.contentRect(forFrameRect: window.frame)
        let systemChromeWidth = max(0, window.frame.width - contentFrame.width)
        let systemChromeHeight = max(0, window.frame.height - contentFrame.height)
        let maximum = CGSize(
            width: max(
                1,
                screen.visibleFrame.width
                    - systemChromeWidth
                    - NativeViewerContentView.horizontalChrome
            ),
            height: max(
                1,
                screen.visibleFrame.height
                    - systemChromeHeight
                    - NativeViewerContentView.verticalChrome
            )
        )
        guard let resolution = NativeViewerResolutionPolicy.resolve(.init(
            decodedPixelSize: pixelSize,
            sourcePointSize: source.sourcePointSize,
            destinationBackingScale: backingScale,
            maximumContentSize: maximum,
            mode: scaleMode
        )) else { return }

        let oldTop = window.frame.maxY
        isApplyingPolicySize = true
        window.setContentSize(CGSize(
            width: resolution.contentSize.width + NativeViewerContentView.horizontalChrome,
            height: resolution.contentSize.height + NativeViewerContentView.verticalChrome
        ))
        var frame = window.frame
        frame.origin.y = oldTop - frame.height
        frame.origin = Self.clampedOrigin(
            frame: frame,
            visibleFrame: screen.visibleFrame
        )
        window.setFrame(frame, display: true, animate: false)
        isApplyingPolicySize = false
    }

    private func clampCurrentNativeWindowIfNeeded() {
        guard scaleMode == .native,
              !isFullScreen,
              let window else { return }
        let clampedSize = clampedNativeFrameSize(window.frame.size, for: window)
        guard clampedSize != window.frame.size else { return }
        var frame = window.frame
        let oldTop = frame.maxY
        frame.size = clampedSize
        frame.origin.y = oldTop - frame.height
        if let screen = window.screen ?? NSScreen.main {
            frame.origin = Self.clampedOrigin(
                frame: frame,
                visibleFrame: screen.visibleFrame
            )
        }
        isApplyingPolicySize = true
        window.setFrame(frame, display: true, animate: false)
        isApplyingPolicySize = false
    }

    private func updateWindowMinimumSize(for mode: NativeViewerScaleMode) {
        guard let window else { return }
        guard mode == .native else {
            window.minSize = Self.defaultMinimumFrameSize
            return
        }

        let frameSize = window.frame.size
        let contentSize = window.contentRect(
            forFrameRect: CGRect(origin: .zero, size: frameSize)
        ).size
        let systemChromeSize = CGSize(
            width: max(0, frameSize.width - contentSize.width),
            height: max(0, frameSize.height - contentSize.height)
        )
        let maximumFrameSize = Self.maximumNativeFrameSize(
            sourceLogicalSize: Self.resolvedSourceLogicalSize(
                source: source,
                destinationBackingScale: window.backingScaleFactor
            ),
            systemChromeSize: systemChromeSize
        )
        window.minSize = CGSize(
            width: min(Self.defaultMinimumFrameSize.width, maximumFrameSize.width),
            height: min(Self.defaultMinimumFrameSize.height, maximumFrameSize.height)
        )
    }

    private func clampedNativeFrameSize(
        _ proposedFrameSize: CGSize,
        for window: NSWindow
    ) -> CGSize {
        let proposedFrame = CGRect(origin: .zero, size: proposedFrameSize)
        let proposedContentSize = window.contentRect(forFrameRect: proposedFrame).size
        let systemChromeSize = CGSize(
            width: max(0, proposedFrameSize.width - proposedContentSize.width),
            height: max(0, proposedFrameSize.height - proposedContentSize.height)
        )
        return Self.clampedNativeFrameSize(
            proposedFrameSize: proposedFrameSize,
            sourceLogicalSize: Self.resolvedSourceLogicalSize(
                source: source,
                destinationBackingScale: window.backingScaleFactor
            ),
            systemChromeSize: systemChromeSize,
            minimumFrameSize: window.minSize
        )
    }

    static func clampedNativeFrameSize(
        proposedFrameSize: CGSize,
        sourceLogicalSize: CGSize,
        systemChromeSize: CGSize,
        minimumFrameSize: CGSize
    ) -> CGSize {
        // Native and Follow operate in host logical points, not decoded pixels.
        // This is what lets the same 1,000-point host window remain the same
        // physical AppKit size on both 1x and Retina viewer displays while the
        // decoder preserves whatever pixel density the host supplied.
        let maximumFrameSize = maximumNativeFrameSize(
            sourceLogicalSize: sourceLogicalSize,
            systemChromeSize: systemChromeSize
        )
        // AppKit applies `minimumFrameSize` before returning a live-resize
        // proposal. A tiny shared window can have a native maximum below
        // Clip's normal 320×180 usability floor, so Native needs a per-axis
        // effective minimum that never exceeds its host-derived maximum.
        let effectiveMinimumFrameSize = CGSize(
            width: min(
                maximumFrameSize.width,
                max(1, minimumFrameSize.width)
            ),
            height: min(
                maximumFrameSize.height,
                max(1, minimumFrameSize.height)
            )
        )
        return CGSize(
            width: max(
                effectiveMinimumFrameSize.width,
                min(proposedFrameSize.width, maximumFrameSize.width)
            ),
            height: max(
                effectiveMinimumFrameSize.height,
                min(proposedFrameSize.height, maximumFrameSize.height)
            )
        )
    }

    private static func maximumNativeFrameSize(
        sourceLogicalSize: CGSize,
        systemChromeSize: CGSize
    ) -> CGSize {
        CGSize(
            width: max(
                1,
                sourceLogicalSize.width
                    + NativeViewerContentView.horizontalChrome
                    + systemChromeSize.width
            ),
            height: max(
                1,
                sourceLogicalSize.height
                    + NativeViewerContentView.verticalChrome
                    + systemChromeSize.height
            )
        )
    }

    static func clampedOrigin(frame: CGRect, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(
                max(visibleFrame.minX, frame.origin.x),
                max(visibleFrame.minX, visibleFrame.maxX - frame.width)
            ),
            y: min(
                max(visibleFrame.minY, frame.origin.y),
                max(visibleFrame.minY, visibleFrame.maxY - frame.height)
            )
        )
    }

    private static func resolvedSourceLogicalSize(
        source: NativeViewerSourceSnapshot,
        destinationBackingScale _: CGFloat
    ) -> CGSize {
        source.sourcePointSize
    }

    private static func title(
        ownerName: String,
        source: NativeViewerSourceSnapshot
    ) -> String {
        let sourceName = source.windowName.isEmpty ? source.applicationName : source.windowName
        return "\(ownerName) · \(sourceName)"
    }
}

private extension NSColor {
    convenience init(_ identityColor: NativeViewerIdentityColor) {
        self.init(
            calibratedHue: identityColor.hue,
            saturation: identityColor.saturation,
            brightness: identityColor.brightness,
            alpha: 1
        )
    }
}

extension NativeViewerIdentityColor {
    @MainActor
    var appKitColor: NSColor { NSColor(self) }
}
