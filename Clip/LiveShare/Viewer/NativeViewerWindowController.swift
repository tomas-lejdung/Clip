import AppKit
import QuartzCore

enum NativeViewerWindowCloseDisposition: Sendable {
    case hide
    case leaveSession
}

@MainActor
final class NativeViewerContentView: NSView {
    static let identityBorderWidth: CGFloat = 5

    let videoView: NSView

    private let identityLabel = NSTextField(labelWithString: "")
    private let identityBadge = NSVisualEffectView()
    private let cursorLayer = CAShapeLayer()
    private var identityColor: NSColor
    private var isFocused = false
    private var isConnected = true
    private var cursorPosition: CGPoint?
    private var sourcePixelSize: CGSize?

    init(videoView: NSView, identityColor: NSColor) {
        self.videoView = videoView
        self.identityColor = identityColor
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        videoView.translatesAutoresizingMaskIntoConstraints = true
        videoView.wantsLayer = true
        videoView.layer?.masksToBounds = true
        addSubview(videoView)

        identityBadge.material = .hudWindow
        identityBadge.blendingMode = .withinWindow
        identityBadge.state = .active
        identityBadge.wantsLayer = true
        identityBadge.layer?.cornerRadius = 7
        identityBadge.layer?.masksToBounds = true
        addSubview(identityBadge)

        identityLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        identityLabel.textColor = .white
        identityLabel.lineBreakMode = .byTruncatingTail
        identityBadge.addSubview(identityLabel)

        cursorLayer.fillColor = NSColor.clear.cgColor
        cursorLayer.strokeColor = NSColor.white.cgColor
        cursorLayer.lineWidth = 2
        cursorLayer.shadowColor = NSColor.black.cgColor
        cursorLayer.shadowOpacity = 0.8
        cursorLayer.shadowRadius = 2
        cursorLayer.isHidden = true
        layer?.addSublayer(cursorLayer)
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let border = Self.identityBorderWidth
        let availableVideoFrame = bounds.insetBy(dx: border, dy: border)
        // The resolution policy sizes the window in source points. Always fit
        // the decoded image into that point-space surface; applying the local
        // display's backing scale a second time would make a 1x source half
        // sized on a Retina viewer.
        videoView.frame = Self.aspectFitContentRect(
            sourcePixelSize: sourcePixelSize,
            videoFrame: availableVideoFrame
        )

        let labelSize = identityLabel.intrinsicContentSize
        let badgeWidth = min(max(72, labelSize.width + 18), max(72, bounds.width - 28))
        identityBadge.frame = CGRect(
            x: border + 9,
            y: bounds.height - border - labelSize.height - 18,
            width: badgeWidth,
            height: labelSize.height + 10
        )
        identityLabel.frame = identityBadge.bounds.insetBy(dx: 9, dy: 5)
        layoutCursor()
    }

    func update(
        ownerName: String,
        source: NativeViewerSourceSnapshot,
        identityColor: NSColor
    ) {
        self.identityColor = identityColor
        isFocused = source.isFocused
        isConnected = source.isConnected
        sourcePixelSize = source.pixelSize
        let sourceName = source.applicationName.isEmpty ? source.windowName : source.applicationName
        identityLabel.stringValue = "\(ownerName) · \(sourceName)"
        setAccessibilityLabel("\(ownerName), \(sourceName), shared window")
        needsLayout = true
        updateBorder()
    }

    func setCursor(normalizedX: CGFloat?, normalizedY: CGFloat?) {
        if let normalizedX, let normalizedY,
           normalizedX.isFinite, normalizedY.isFinite,
           (0...1).contains(normalizedX), (0...1).contains(normalizedY) {
            cursorPosition = CGPoint(x: normalizedX, y: normalizedY)
        } else {
            cursorPosition = nil
        }
        layoutCursor()
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

    private func updateBorder() {
        let baseColor = isConnected ? identityColor : .systemGray
        let color = isFocused ? baseColor.blended(withFraction: 0.22, of: .white) ?? baseColor : baseColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.borderWidth = Self.identityBorderWidth
        layer?.borderColor = color.cgColor
        identityBadge.layer?.borderWidth = 1
        identityBadge.layer?.borderColor = color.withAlphaComponent(0.8).cgColor
        cursorLayer.strokeColor = color.cgColor
        CATransaction.commit()
    }

    private func layoutCursor() {
        guard let cursorPosition else {
            cursorLayer.isHidden = true
            return
        }
        let point = Self.cursorPoint(
            normalizedX: cursorPosition.x,
            normalizedY: cursorPosition.y,
            videoFrame: videoView.frame,
            sourcePixelSize: sourcePixelSize
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
        cursorLayer.isHidden = false
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
        let border = NativeViewerContentView.identityBorderWidth * 2
        let window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size: CGSize(
                    width: initialVideoSize.width + border,
                    height: initialVideoSize.height + border
                )
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.contentView = content
        window.delegate = self
        window.tabbingMode = .disallowed
        window.title = Self.title(ownerName: ownerName, source: source)
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.backgroundColor = .black
        window.minSize = CGSize(width: 330, height: 220)
        window.setAccessibilitySubrole(.standardWindow)
        content.update(ownerName: ownerName, source: source, identityColor: identityColor)
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
        content.update(ownerName: ownerName, source: source, identityColor: identityColor)
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
        if let committed = dimensionStabilizer.committedPixelSize {
            resizeVideoContent(for: committed)
        }
    }

    func showWithoutTakingFocus() {
        window?.orderFront(nil)
    }

    func hide() {
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
        guard !userAdjustedSize || scaleMode != .automatic,
              let committed = dimensionStabilizer.committedPixelSize else { return }
        resizeVideoContent(for: committed)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        guard let committed = dimensionStabilizer.committedPixelSize else { return }
        resizeVideoContent(for: committed)
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
        let border = NativeViewerContentView.identityBorderWidth * 2
        let contentFrame = window.contentRect(forFrameRect: window.frame)
        let chromeHeight = max(0, window.frame.height - contentFrame.height)
        let maximum = CGSize(
            width: max(1, screen.visibleFrame.width - border),
            height: max(1, screen.visibleFrame.height - chromeHeight - border)
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
            width: resolution.contentSize.width + border,
            height: resolution.contentSize.height + border
        ))
        var frame = window.frame
        frame.origin.y = oldTop - frame.height
        window.setFrame(frame, display: true, animate: false)
        isApplyingPolicySize = false
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
