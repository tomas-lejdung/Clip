import AppKit
import QuartzCore

enum NativeViewerWindowCloseDisposition: Sendable {
    case hide
    case leaveSession
}

private enum NativeViewerHeaderAction {
    case fitToWindow
    case nativeSize
    case resetToActualSize
    case close
}

@MainActor
private final class NativeViewerHeaderButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        alphaValue = 0.62
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
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        let targetAlpha: CGFloat = hovered ? 1 : 0.62
        guard alphaValue != targetAlpha else { return }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = targetAlpha
        }
    }
}

@MainActor
private final class NativeViewerHeaderView: NSView {
    static let height: CGFloat = 28

    private let titleLabel = NSTextField(labelWithString: "")
    private let zoomButton = NativeViewerHeaderButton()
    private let closeButton = NativeViewerHeaderButton()

    var onAction: ((NativeViewerHeaderAction) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isSelectable = false
        titleLabel.setAccessibilityIdentifier("clip.nativeViewer.windowTitle")
        addSubview(titleLabel)

        configureButton(zoomButton, action: #selector(showZoomMenu))
        zoomButton.title = "100%"
        zoomButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        zoomButton.imagePosition = .imageLeading
        zoomButton.setAccessibilityLabel("Viewer zoom")
        zoomButton.setAccessibilityIdentifier("clip.nativeViewer.zoom")
        addSubview(zoomButton)

        configureButton(closeButton, action: #selector(closeWindow))
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imagePosition = .imageOnly
        closeButton.setAccessibilityLabel("Close shared window")
        closeButton.setAccessibilityIdentifier("clip.nativeViewer.close")
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let closeWidth: CGFloat = 24
        let zoomWidth: CGFloat = 60
        let controlHeight = min(CGFloat(22), max(0, bounds.height - 4))
        closeButton.frame = CGRect(
            x: max(4, bounds.width - closeWidth - 4),
            y: floor((bounds.height - controlHeight) / 2),
            width: min(closeWidth, max(0, bounds.width - 8)),
            height: controlHeight
        )
        zoomButton.frame = CGRect(
            x: max(4, closeButton.frame.minX - zoomWidth - 2),
            y: closeButton.frame.minY,
            width: min(zoomWidth, max(0, closeButton.frame.minX - 6)),
            height: controlHeight
        )
        titleLabel.frame = CGRect(
            x: 8,
            y: floor((bounds.height - 17) / 2),
            width: max(0, zoomButton.frame.minX - 15),
            height: 17
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit,
           hit === zoomButton || hit === closeButton
            || hit.isDescendant(of: zoomButton)
            || hit.isDescendant(of: closeButton) {
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

    func updateZoomPercentage(_ percentage: Int) {
        let clamped = max(1, percentage)
        zoomButton.title = "\(clamped)%"
        zoomButton.setAccessibilityValue("\(clamped) percent")
    }

    func updateIdentityColor(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        titleLabel.textColor = luminance > 0.58
            ? NSColor.black.withAlphaComponent(0.82)
            : .white
    }

    var controlFrames: (zoom: CGRect, close: CGRect) {
        (zoomButton.frame, closeButton.frame)
    }

    var controlOpacities: [CGFloat] {
        [zoomButton.alphaValue, closeButton.alphaValue]
    }

    var controlTintColors: [NSColor?] {
        [zoomButton.contentTintColor, closeButton.contentTintColor]
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = .black
        button.focusRingType = .none
    }

    @objc private func showZoomMenu() {
        let menu = NSMenu(title: "Viewer Zoom")
        let fit = NSMenuItem(
            title: String(localized: "Fit to Window"),
            action: #selector(selectFit),
            keyEquivalent: ""
        )
        fit.target = self
        menu.addItem(fit)

        let native = NSMenuItem(
            title: String(localized: "Native 100%"),
            action: #selector(selectNative),
            keyEquivalent: ""
        )
        native.target = self
        menu.addItem(native)
        menu.addItem(.separator())

        let reset = NSMenuItem(
            title: String(localized: "Reset Window to Actual Size"),
            action: #selector(resetToActualSize),
            keyEquivalent: ""
        )
        reset.target = self
        menu.addItem(reset)
        menu.popUp(
            positioning: nil,
            at: CGPoint(x: zoomButton.frame.minX, y: zoomButton.frame.minY),
            in: self
        )
    }

    @objc private func selectFit() {
        onAction?(.fitToWindow)
    }

    @objc private func selectNative() {
        onAction?(.nativeSize)
    }

    @objc private func resetToActualSize() {
        onAction?(.resetToActualSize)
    }

    @objc private func closeWindow() {
        onAction?(.close)
    }
}

@MainActor
final class NativeViewerContentView: NSView {
    static let identityBorderWidth: CGFloat = 6
    static let headerHeight = NativeViewerHeaderView.height

    static var horizontalChrome: CGFloat { identityBorderWidth * 2 }
    static var verticalChrome: CGFloat { identityBorderWidth * 2 + headerHeight }

    let videoView: NSView

    var onFitToWindow: (() -> Void)?
    var onNativeSize: (() -> Void)?
    var onResetToActualSize: (() -> Void)?
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
    private var scaleMode = NativeViewerScaleMode.automatic
    private var isPresentationActive = true
    private var currentNativeOrigin: CGPoint?
    private var targetNativeOrigin: CGPoint?
    private var panGeometryKey: PanGeometryKey?
    private var panTimer: Timer?

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

        headerView.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .fitToWindow:
                onFitToWindow?()
            case .nativeSize:
                onNativeSize?()
            case .resetToActualSize:
                onResetToActualSize?()
            case .close:
                onClose?()
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
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        let border = Self.identityBorderWidth
        headerView.frame = CGRect(
            x: border,
            y: max(border, bounds.height - border - Self.headerHeight),
            width: max(0, bounds.width - border * 2),
            height: min(Self.headerHeight, max(0, bounds.height - border * 2))
        )
        videoViewport.frame = CGRect(
            x: border,
            y: border,
            width: max(0, bounds.width - border * 2),
            height: max(0, bounds.height - border * 2 - Self.headerHeight)
        )
        cursorLayer.frame = videoViewport.bounds
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
        needsLayout = true
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
        if scaleMode == .actualPixels { return 100 }
        return NativeViewerPanPolicy.zoomPercentage(
            sourceLogicalSize: sourceLogicalSize ?? .zero,
            renderedContentSize: videoView.frame.size
        ) ?? 100
    }
    var headerControlFrames: (zoom: CGRect, close: CGRect) {
        headerView.controlFrames
    }
    var headerControlOpacities: [CGFloat] { headerView.controlOpacities }
    var headerControlTintColors: [NSColor?] { headerView.controlTintColors }

    private func layoutVideoSurface() {
        guard videoViewport.bounds.width > 0, videoViewport.bounds.height > 0 else {
            videoView.frame = .zero
            return
        }
        if scaleMode == .actualPixels,
           let sourceLogicalSize,
           let geometry = NativeViewerPanPolicy.geometry(
               sourceLogicalSize: sourceLogicalSize,
               viewportSize: videoViewport.bounds.size,
               normalizedCursor: panAnchorPosition
           ) {
            let key = PanGeometryKey(
                sourceSize: sourceLogicalSize,
                viewportSize: videoViewport.bounds.size
            )
            targetNativeOrigin = geometry.contentFrame.origin
            if panGeometryKey != key || currentNativeOrigin == nil {
                panGeometryKey = key
                currentNativeOrigin = geometry.contentFrame.origin
            }
            videoView.frame = CGRect(
                origin: currentNativeOrigin ?? geometry.contentFrame.origin,
                size: geometry.contentFrame.size
            )
        } else {
            stopPanAnimation()
            currentNativeOrigin = nil
            targetNativeOrigin = nil
            panGeometryKey = nil
            videoView.frame = Self.aspectFitContentRect(
                sourcePixelSize: sourceLogicalSize ?? sourcePixelSize,
                videoFrame: videoViewport.bounds
            )
        }
        updateZoomIndicator()
        layoutCursor()
    }

    private func updateNativePanTarget(animated: Bool) {
        guard isPresentationActive,
              scaleMode == .actualPixels,
              let sourceLogicalSize,
              let geometry = NativeViewerPanPolicy.geometry(
                  sourceLogicalSize: sourceLogicalSize,
                  viewportSize: videoViewport.bounds.size,
                  normalizedCursor: panAnchorPosition
              ) else {
            stopPanAnimation()
            return
        }
        targetNativeOrigin = geometry.contentFrame.origin
        if currentNativeOrigin == nil {
            currentNativeOrigin = geometry.contentFrame.origin
            applyCurrentNativeFrame()
            return
        }
        if let currentNativeOrigin,
           abs(geometry.contentFrame.origin.x - currentNativeOrigin.x) < 0.35,
           abs(geometry.contentFrame.origin.y - currentNativeOrigin.y) < 0.35 {
            self.currentNativeOrigin = geometry.contentFrame.origin
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
        videoView.frame = CGRect(origin: currentNativeOrigin, size: sourceLogicalSize)
        layoutCursor()
    }

    private func stopPanAnimation() {
        panTimer?.invalidate()
        panTimer = nil
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
        layer?.backgroundColor = color.withAlphaComponent(isFocused ? 0.98 : 0.82).cgColor
        cursorLayer.strokeColor = color.cgColor
        CATransaction.commit()
        headerView.updateIdentityColor(color)
    }

    private func updateZoomIndicator() {
        headerView.updateZoomPercentage(zoomPercentage)
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
final class NativeViewerWindowController: NSWindowController, NSWindowDelegate {
    let viewerWindowID: NativeViewerWindowID
    let content: NativeViewerContentView

    var onCloseRequested: ((NativeViewerWindowController) -> NativeViewerWindowCloseDisposition)?

    private(set) var scaleMode = NativeViewerScaleMode.automatic
    private var source: NativeViewerSourceSnapshot
    private var dimensionStabilizer = NativeViewerDimensionStabilizer()
    private var isApplyingPolicySize = false
    private var userAdjustedSize = false

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
        let initialSourceSize = source.sourcePointSize ?? CGSize(
            width: source.pixelSize.width / 2,
            height: source.pixelSize.height / 2
        )
        let initialScale = min(
            1,
            960 / initialSourceSize.width,
            540 / initialSourceSize.height
        )
        let initialVideoSize = CGSize(
            width: max(320, initialSourceSize.width * initialScale),
            height: max(180, initialSourceSize.height * initialScale)
        )
        let window = NSWindow(
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
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.minSize = CGSize(
            width: 320 + NativeViewerContentView.horizontalChrome,
            height: 180 + NativeViewerContentView.verticalChrome
        )
        window.setAccessibilitySubrole(.standardWindow)

        content.onFitToWindow = { [weak self] in
            self?.setPresentationModeWithoutResizing(.fit)
        }
        content.onNativeSize = { [weak self] in
            self?.setPresentationModeWithoutResizing(.actualPixels)
        }
        content.onResetToActualSize = { [weak self] in
            self?.resetToActualSize()
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
        if previousSourcePointSize != source.sourcePointSize,
           (!userAdjustedSize || scaleMode != .automatic),
           let committed = dimensionStabilizer.committedPixelSize {
            resizeVideoContent(for: committed)
        }
    }

    func decodedPixelSizeDidChange(_ size: CGSize) {
        applyPixelSize(size, authoritative: source.pixelSize, revision: source.stateRevision)
    }

    func setScaleMode(_ mode: NativeViewerScaleMode) {
        scaleMode = mode
        userAdjustedSize = false
        content.setScaleMode(mode)
        if let committed = dimensionStabilizer.committedPixelSize {
            resizeVideoContent(for: committed)
        }
    }

    func showWithoutTakingFocus() {
        content.setPresentationActive(true)
        window?.orderFront(nil)
    }

    func hide() {
        content.setPresentationActive(false)
        window?.orderOut(nil)
    }

    func tearDown() {
        onCloseRequested = nil
        window?.delegate = nil
        content.removeFromSuperview()
        close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch onCloseRequested?(self) ?? .hide {
        case .hide:
            sender.orderOut(nil)
            return false
        case .leaveSession:
            return true
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard !isApplyingPolicySize else { return }
        userAdjustedSize = true
    }

    func windowDidChangeScreen(_ notification: Notification) {
        refreshResolvedSourceLogicalSize()
        guard !userAdjustedSize,
              let committed = dimensionStabilizer.committedPixelSize else { return }
        resizeVideoContent(for: committed)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        refreshResolvedSourceLogicalSize()
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        guard !userAdjustedSize,
              let committed = dimensionStabilizer.committedPixelSize else { return }
        resizeVideoContent(for: committed)
    }

    private func setPresentationModeWithoutResizing(_ mode: NativeViewerScaleMode) {
        scaleMode = mode
        userAdjustedSize = true
        content.setScaleMode(mode)
        content.layoutSubtreeIfNeeded()
    }

    private func resetToActualSize() {
        scaleMode = .actualPixels
        userAdjustedSize = false
        content.setScaleMode(.actualPixels)
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
        guard !userAdjustedSize || scaleMode != .automatic else { return }
        resizeVideoContent(for: committed)
    }

    private func resizeVideoContent(for pixelSize: CGSize) {
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
        destinationBackingScale: CGFloat
    ) -> CGSize {
        if let sourcePointSize = source.sourcePointSize {
            return sourcePointSize
        }
        let scale = max(1, destinationBackingScale)
        return CGSize(
            width: source.pixelSize.width / scale,
            height: source.pixelSize.height / scale
        )
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
