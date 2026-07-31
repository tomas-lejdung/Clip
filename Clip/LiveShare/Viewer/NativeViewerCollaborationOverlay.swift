import AppKit
import ClipLiveShare
import QuartzCore

struct NativeViewerCollaborationPointer: Equatable, Sendable, Identifiable {
    let participantID: ClipLiveShareNativeV3ParticipantID
    let participantName: String
    let color: ClipLiveShareNativeV3CollaborationColor
    let position: ClipLiveShareNativeV3NormalizedPoint

    var id: ClipLiveShareNativeV3ParticipantID { participantID }
}

struct NativeViewerCollaborationPing: Equatable, Sendable, Identifiable {
    let id: UUID
    let participantID: ClipLiveShareNativeV3ParticipantID
    let color: ClipLiveShareNativeV3CollaborationColor
    let position: ClipLiveShareNativeV3NormalizedPoint
}

struct NativeViewerCollaborationStroke: Equatable, Sendable, Identifiable {
    let participantID: ClipLiveShareNativeV3ParticipantID
    let strokeID: ClipLiveShareNativeV3StrokeID
    let color: ClipLiveShareNativeV3CollaborationColor
    let points: [ClipLiveShareNativeV3NormalizedPoint]

    var id: ClipLiveShareNativeV3StrokeID { strokeID }
}

struct NativeViewerCollaborationOverlaySnapshot: Equatable, Sendable {
    var pointers: [NativeViewerCollaborationPointer] = []
    var pings: [NativeViewerCollaborationPing] = []
    var strokes: [NativeViewerCollaborationStroke] = []

    static let empty = Self()
}

enum NativeViewerCollaborationInteractionMode: Equatable, Sendable {
    case disabled
    case pointer
    case draw(ClipLiveShareNativeV3CollaborationColor)

    var acceptsInput: Bool { self != .disabled }
}

@MainActor
struct NativeViewerCollaborationActions {
    var pointerChanged: (ClipLiveShareNativeV3NormalizedPoint?) -> Void
    var ping: (ClipLiveShareNativeV3NormalizedPoint) -> Void
    var strokeBegan:
        (ClipLiveShareNativeV3StrokeID, ClipLiveShareNativeV3NormalizedPoint) -> Void
    var strokePoints:
        (ClipLiveShareNativeV3StrokeID, [ClipLiveShareNativeV3NormalizedPoint]) -> Void
    var strokeEnded: (ClipLiveShareNativeV3StrokeID) -> Void

    init(
        pointerChanged: @escaping (ClipLiveShareNativeV3NormalizedPoint?) -> Void =
            { _ in },
        ping: @escaping (ClipLiveShareNativeV3NormalizedPoint) -> Void = { _ in },
        strokeBegan: @escaping (
            ClipLiveShareNativeV3StrokeID,
            ClipLiveShareNativeV3NormalizedPoint
        ) -> Void = { _, _ in },
        strokePoints: @escaping (
            ClipLiveShareNativeV3StrokeID,
            [ClipLiveShareNativeV3NormalizedPoint]
        ) -> Void = { _, _ in },
        strokeEnded: @escaping (ClipLiveShareNativeV3StrokeID) -> Void = { _ in }
    ) {
        self.pointerChanged = pointerChanged
        self.ping = ping
        self.strokeBegan = strokeBegan
        self.strokePoints = strokePoints
        self.strokeEnded = strokeEnded
    }
}

enum NativeViewerCollaborationGeometry {
    static func normalizedPoint(
        for location: CGPoint,
        contentFrame: CGRect
    ) -> ClipLiveShareNativeV3NormalizedPoint? {
        guard
            contentFrame.width > 0,
            contentFrame.height > 0,
            contentFrame.contains(location)
        else {
            return nil
        }
        return try? ClipLiveShareNativeV3NormalizedPoint(
            x: Double((location.x - contentFrame.minX) / contentFrame.width),
            y: Double((contentFrame.maxY - location.y) / contentFrame.height)
        )
    }

    static func point(
        for normalized: ClipLiveShareNativeV3NormalizedPoint,
        contentFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: contentFrame.minX + CGFloat(normalized.x) * contentFrame.width,
            y: contentFrame.maxY - CGFloat(normalized.y) * contentFrame.height
        )
    }
}

@MainActor
final class NativeViewerCollaborationOverlayView: NSView {
    var onPointerChanged: (ClipLiveShareNativeV3NormalizedPoint?) -> Void = { _ in }
    var onPing: (ClipLiveShareNativeV3NormalizedPoint) -> Void = { _ in }
    var onStrokeBegan:
        (ClipLiveShareNativeV3StrokeID, ClipLiveShareNativeV3NormalizedPoint) -> Void =
        { _, _ in }
    var onStrokePoints:
        (ClipLiveShareNativeV3StrokeID, [ClipLiveShareNativeV3NormalizedPoint]) -> Void =
        { _, _ in }
    var onStrokeEnded: (ClipLiveShareNativeV3StrokeID) -> Void = { _ in }

    var interactionMode: NativeViewerCollaborationInteractionMode = .disabled {
        didSet {
            if oldValue.acceptsInput, !interactionMode.acceptsInput {
                onPointerChanged(nil)
                finishActiveStroke()
            }
            updateTrackingAreas()
            resetCursorRects()
        }
    }

    var contentFrame: CGRect = .zero {
        didSet {
            guard contentFrame != oldValue else { return }
            render()
        }
    }

    private var snapshot = NativeViewerCollaborationOverlaySnapshot.empty
    private var pointerLayers: [CALayer] = []
    private var pingLayers: [CALayer] = []
    private var strokeLayers: [CALayer] = []
    private var trackingArea: NSTrackingArea?
    private var activeStrokeID: ClipLiveShareNativeV3StrokeID?
    private var pendingStrokePoints: [ClipLiveShareNativeV3NormalizedPoint] = []
    private var lastPointerPosition: ClipLiveShareNativeV3NormalizedPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Live Share collaboration overlay"))
        setAccessibilityIdentifier("clip.nativeViewer.collaborationOverlay")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { interactionMode.acceptsInput }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactionMode.acceptsInput, bounds.contains(point) else {
            return nil
        }
        return self
    }

    override func resetCursorRects() {
        discardCursorRects()
        guard interactionMode.acceptsInput else { return }
        addCursorRect(bounds, cursor: interactionMode == .pointer ? .pointingHand : .crosshair)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        guard interactionMode.acceptsInput else {
            trackingArea = nil
            super.updateTrackingAreas()
            return
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
        trackingArea = replacement
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        publishPointer(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        publishPointer(for: event)
        guard
            case .draw = interactionMode,
            let activeStrokeID,
            let point = normalizedPoint(for: event)
        else {
            return
        }
        if pendingStrokePoints.last != point {
            pendingStrokePoints.append(point)
        }
        if pendingStrokePoints.count >= 8 {
            flushStrokePoints(strokeID: activeStrokeID)
        }
    }

    override func mouseExited(with event: NSEvent) {
        lastPointerPosition = nil
        onPointerChanged(nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = normalizedPoint(for: event) else { return }
        switch interactionMode {
        case .disabled:
            break
        case .pointer:
            onPing(point)
        case .draw:
            finishActiveStroke()
            let strokeID = ClipLiveShareNativeV3StrokeID()
            activeStrokeID = strokeID
            pendingStrokePoints.removeAll(keepingCapacity: true)
            onStrokeBegan(strokeID, point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        finishActiveStroke()
    }

    func update(_ snapshot: NativeViewerCollaborationOverlaySnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        render()
    }

    private func normalizedPoint(
        for event: NSEvent
    ) -> ClipLiveShareNativeV3NormalizedPoint? {
        NativeViewerCollaborationGeometry.normalizedPoint(
            for: convert(event.locationInWindow, from: nil),
            contentFrame: contentFrame
        )
    }

    private func publishPointer(for event: NSEvent) {
        guard let point = normalizedPoint(for: event) else {
            if lastPointerPosition != nil {
                lastPointerPosition = nil
                onPointerChanged(nil)
            }
            return
        }
        guard point != lastPointerPosition else { return }
        lastPointerPosition = point
        onPointerChanged(point)
    }

    private func finishActiveStroke() {
        guard let activeStrokeID else { return }
        flushStrokePoints(strokeID: activeStrokeID)
        self.activeStrokeID = nil
        onStrokeEnded(activeStrokeID)
    }

    private func flushStrokePoints(strokeID: ClipLiveShareNativeV3StrokeID) {
        guard !pendingStrokePoints.isEmpty else { return }
        let points = pendingStrokePoints
        pendingStrokePoints.removeAll(keepingCapacity: true)
        onStrokePoints(strokeID, points)
    }

    private func render() {
        clearRenderedLayers()
        guard contentFrame.width > 0, contentFrame.height > 0 else { return }
        for stroke in snapshot.strokes {
            let path = CGMutablePath()
            for (index, normalized) in stroke.points.enumerated() {
                let point = NativeViewerCollaborationGeometry.point(
                    for: normalized,
                    contentFrame: contentFrame
                )
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            let shape = CAShapeLayer()
            shape.path = path
            shape.fillColor = NSColor.clear.cgColor
            shape.strokeColor = stroke.color.appKitColor.cgColor
            shape.lineWidth = 3
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.shadowColor = NSColor.black.cgColor
            shape.shadowOpacity = 0.34
            shape.shadowRadius = 1.5
            layer?.addSublayer(shape)
            strokeLayers.append(shape)
        }
        for ping in snapshot.pings {
            let center = NativeViewerCollaborationGeometry.point(
                for: ping.position,
                contentFrame: contentFrame
            )
            let ring = CAShapeLayer()
            ring.path = CGPath(
                ellipseIn: CGRect(
                    x: center.x - 13,
                    y: center.y - 13,
                    width: 26,
                    height: 26
                ),
                transform: nil
            )
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = ping.color.appKitColor.cgColor
            ring.lineWidth = 3
            layer?.addSublayer(ring)
            pingLayers.append(ring)
        }
        for pointer in snapshot.pointers {
            let point = NativeViewerCollaborationGeometry.point(
                for: pointer.position,
                contentFrame: contentFrame
            )
            pointerLayers.append(
                renderPointer(
                    at: point,
                    name: pointer.participantName,
                    color: pointer.color.appKitColor
                )
            )
        }
    }

    private func renderPointer(
        at point: CGPoint,
        name: String,
        color: NSColor
    ) -> CALayer {
        let container = CALayer()
        container.frame = bounds

        let pointer = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: point)
        path.addLine(to: CGPoint(x: point.x + 4, y: point.y - 19))
        path.addLine(to: CGPoint(x: point.x + 10, y: point.y - 12))
        path.addLine(to: CGPoint(x: point.x + 17, y: point.y - 14))
        path.closeSubpath()
        pointer.path = path
        pointer.fillColor = color.cgColor
        pointer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        pointer.lineWidth = 1
        pointer.shadowColor = NSColor.black.cgColor
        pointer.shadowOpacity = 0.55
        pointer.shadowRadius = 2
        container.addSublayer(pointer)

        let label = CATextLayer()
        label.string = name
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.fontSize = 11
        label.foregroundColor = NSColor.white.cgColor
        label.backgroundColor = color.withAlphaComponent(0.94).cgColor
        label.cornerRadius = 5
        label.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        label.alignmentMode = .center
        let width = min(150, max(44, CGFloat(name.count * 7 + 14)))
        label.frame = CGRect(
            x: min(max(0, point.x + 12), max(0, bounds.width - width)),
            y: min(max(0, point.y - 32), max(0, bounds.height - 19)),
            width: width,
            height: 19
        )
        container.addSublayer(label)
        layer?.addSublayer(container)
        return container
    }

    private func clearRenderedLayers() {
        for layer in pointerLayers + pingLayers + strokeLayers {
            layer.removeFromSuperlayer()
        }
        pointerLayers.removeAll(keepingCapacity: true)
        pingLayers.removeAll(keepingCapacity: true)
        strokeLayers.removeAll(keepingCapacity: true)
    }
}

private extension ClipLiveShareNativeV3CollaborationColor {
    var appKitColor: NSColor {
        NSColor(
            calibratedRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }
}
