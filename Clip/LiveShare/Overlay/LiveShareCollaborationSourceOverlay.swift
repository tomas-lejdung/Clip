import AppKit
import SwiftUI

/// Capture-excluded panel shared by native-v3 collaboration overlays.
@MainActor
final class LiveShareOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(initialSize: CGSize, level: NSWindow.Level) {
        super.init(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        self.level = level
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        sharingType = .none
    }
}

/// Presents remote pointers and ink above the publisher's original source
/// without burning those annotations back into ScreenCaptureKit video.
///
/// Every receiver renders the same vector state over its own decoded content,
/// while the publisher gets this click-through, capture-excluded panel. That
/// avoids feedback loops and preserves native sharpness at every viewer scale.
@MainActor
final class LiveShareCollaborationSourceOverlayCoordinator {
    private struct Entry {
        let panel: LiveShareOverlayPanel
        let overlay: NativeViewerCollaborationOverlayView
    }

    private var entries: [String: Entry] = [:]

    func update(
        sourceID: String,
        sourceFrame: CGRect,
        snapshot: NativeViewerCollaborationOverlaySnapshot,
        isVisible: Bool
    ) {
        guard
            isVisible,
            sourceFrame.width > 0,
            sourceFrame.height > 0
        else {
            remove(sourceID: sourceID)
            return
        }
        let entry = entries[sourceID] ?? makeEntry(sourceID: sourceID)
        entry.panel.setFrame(sourceFrame, display: true, animate: false)
        entry.overlay.frame = CGRect(origin: .zero, size: sourceFrame.size)
        entry.overlay.contentFrame = entry.overlay.bounds
        entry.overlay.update(snapshot)
        entry.panel.orderFrontRegardless()
    }

    func remove(sourceID: String) {
        guard let entry = entries.removeValue(forKey: sourceID) else { return }
        entry.panel.orderOut(nil)
        entry.panel.contentView = nil
    }

    func retainSources(_ sourceIDs: Set<String>) {
        for sourceID in entries.keys where !sourceIDs.contains(sourceID) {
            remove(sourceID: sourceID)
        }
    }

    func tearDown() {
        for entry in entries.values {
            entry.panel.orderOut(nil)
            entry.panel.contentView = nil
        }
        entries.removeAll(keepingCapacity: false)
    }

    private func makeEntry(sourceID: String) -> Entry {
        let panel = LiveShareOverlayPanel(initialSize: .zero, level: .floating)
        panel.ignoresMouseEvents = true
        panel.setAccessibilityElement(false)
        panel.setAccessibilityIdentifier(
            "clip.liveShare.collaborationSource.\(sourceID)"
        )
        let overlay = NativeViewerCollaborationOverlayView(frame: .zero)
        overlay.interactionMode = .disabled
        panel.contentView = overlay
        let entry = Entry(panel: panel, overlay: overlay)
        entries[sourceID] = entry
        return entry
    }
}

enum MeshFocusedWindowControlState: Equatable, Sendable {
    case shareable
    case starting
    case live
    case stopping

    fileprivate var title: String {
        switch self {
        case .shareable:
            String(localized: "Share")
        case .starting, .live:
            String(localized: "Stop")
        case .stopping:
            String(localized: "Stopping…")
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .shareable:
            "play.fill"
        case .starting, .live, .stopping:
            "stop.fill"
        }
    }

    fileprivate var isEnabled: Bool { self != .stopping }
}

enum MeshOverlayAnchorSide: Equatable, Sendable {
    case left
    case right

    fileprivate var opposite: Self { self == .left ? .right : .left }
}

enum MeshParticipantOverlayGeometry {
    static let focusedControlSize = CGSize(width: 130, height: 32)
    static let statusHUDSize = CGSize(width: 190, height: 66)

    static func focusedControlFrame(
        targetWindowFrame: CGRect,
        visibleScreenFrame: CGRect,
        side: MeshOverlayAnchorSide
    ) -> CGRect {
        let target = targetWindowFrame.standardized
        let screen = visibleScreenFrame.standardized
        let size = focusedControlSize
        let inset: CGFloat = 16
        let x = side == .left
            ? target.minX + inset
            : target.maxX - inset - size.width
        return CGRect(
            x: clampedOrigin(
                x,
                length: size.width,
                minimum: screen.minX,
                maximum: screen.maxX
            ),
            y: clampedOrigin(
                target.minY + inset,
                length: size.height,
                minimum: screen.minY,
                maximum: screen.maxY
            ),
            width: size.width,
            height: size.height
        )
    }

    static func statusHUDFrame(
        visibleScreenFrame: CGRect,
        size: CGSize = statusHUDSize
    ) -> CGRect {
        let screen = visibleScreenFrame.standardized
        let inset: CGFloat = 12
        return CGRect(
            x: clampedOrigin(
                screen.maxX - inset - size.width,
                length: size.width,
                minimum: screen.minX,
                maximum: screen.maxX
            ),
            y: clampedOrigin(
                screen.maxY - inset - size.height,
                length: size.height,
                minimum: screen.minY,
                maximum: screen.maxY
            ),
            width: size.width,
            height: size.height
        )
    }

    private static func clampedOrigin(
        _ value: CGFloat,
        length: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        min(max(value, minimum), max(minimum, maximum - max(0, length)))
    }
}

@MainActor
struct MeshFocusedWindowControlActions {
    var share: () -> Void
    var stop: () -> Void

    init(
        share: @escaping () -> Void = {},
        stop: @escaping () -> Void = {}
    ) {
        self.share = share
        self.stop = stop
    }
}

@MainActor
private struct MeshFocusedWindowControlView: View {
    let snapshot: MeshParticipantFocusedWindowControlSnapshot
    let side: MeshOverlayAnchorSide
    let primaryAction: () -> Void
    let toggleSide: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: primaryAction) {
                Label(
                    snapshot.state.title,
                    systemImage: snapshot.state.systemImage
                )
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(
                MeshOverlayButtonStyle(
                    tint: snapshot.state == .shareable
                        ? .secondary
                        : .red
                )
            )
            .disabled(!snapshot.state.isEnabled)
            .accessibilityIdentifier(
                "clip.meshRoom.focusedWindow.primary"
            )

            Button(action: toggleSide) {
                Image(
                    systemName:
                        side == .left ? "arrow.right" : "arrow.left"
                )
                .font(.system(size: 10, weight: .bold))
                .frame(width: 27, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(MeshOverlayButtonStyle(tint: .secondary))
            .help(String(localized: "Move control to the other side"))
            .accessibilityIdentifier("clip.meshRoom.focusedWindow.move")
        }
        .frame(
            width: MeshParticipantOverlayGeometry.focusedControlSize.width,
            height: MeshParticipantOverlayGeometry.focusedControlSize.height
        )
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.meshRoom.focusedWindow.overlay")
    }
}

/// Owns the one interactive Share/Stop control attached to the currently
/// focused eligible local window. `sharingType = .none` on the panel keeps the
/// control out of every ScreenCaptureKit source while ordinary AppKit hit
/// testing remains available to its buttons.
@MainActor
final class MeshFocusedWindowControlCoordinator {
    private let actions: MeshFocusedWindowControlActions
    private(set) var panel = LiveShareOverlayPanel(
        initialSize: MeshParticipantOverlayGeometry.focusedControlSize,
        level: .floating
    )
    private var hostingView:
        MeshFirstMouseHostingView<MeshFocusedWindowControlView>?
    private var snapshot: MeshParticipantFocusedWindowControlSnapshot?
    private var visibleScreenFrame: CGRect?
    private var sideBySourceID: [String: MeshOverlayAnchorSide] = [:]

    init(actions: MeshFocusedWindowControlActions) {
        self.actions = actions
        panel.setAccessibilityIdentifier(
            "clip.meshRoom.focusedWindow.panel"
        )
    }

    var isVisible: Bool { panel.isVisible }

    func show(
        snapshot: MeshParticipantFocusedWindowControlSnapshot,
        visibleScreenFrame: CGRect
    ) {
        self.snapshot = snapshot
        self.visibleScreenFrame = visibleScreenFrame
        render()
        movePanel(animated: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        snapshot = nil
        visibleScreenFrame = nil
    }

    func tearDown() {
        hide()
        sideBySourceID.removeAll(keepingCapacity: false)
        panel.contentView = nil
        hostingView = nil
    }

    func contentHitTest(at point: CGPoint) -> NSView? {
        panel.contentView?.hitTest(point)
    }

    private func performPrimaryAction() {
        guard let snapshot else { return }
        switch snapshot.state {
        case .shareable:
            actions.share()
        case .starting, .live:
            actions.stop()
        case .stopping:
            break
        }
    }

    private func toggleSide() {
        guard let snapshot else { return }
        sideBySourceID[snapshot.sourceID] =
            (sideBySourceID[snapshot.sourceID] ?? .left).opposite
        render()
        movePanel(animated: true)
    }

    private func render() {
        guard let snapshot else { return }
        let side = sideBySourceID[snapshot.sourceID] ?? .left
        let root = MeshFocusedWindowControlView(
            snapshot: snapshot,
            side: side,
            primaryAction: { [weak self] in
                self?.performPrimaryAction()
            },
            toggleSide: { [weak self] in self?.toggleSide() }
        )
        if let hostingView {
            hostingView.rootView = root
        } else {
            let hostingView = MeshFirstMouseHostingView(rootView: root)
            hostingView.frame = CGRect(
                origin: .zero,
                size: MeshParticipantOverlayGeometry.focusedControlSize
            )
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView
            self.hostingView = hostingView
        }
        hostingView?.layoutSubtreeIfNeeded()
    }

    private func movePanel(animated: Bool) {
        guard let snapshot, let visibleScreenFrame else { return }
        let frame = MeshParticipantOverlayGeometry.focusedControlFrame(
            targetWindowFrame: snapshot.appKitFrame,
            visibleScreenFrame: visibleScreenFrame,
            side: sideBySourceID[snapshot.sourceID] ?? .left
        )
        guard animated else {
            panel.setFrame(frame, display: true, animate: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut
            )
            panel.animator().setFrame(frame, display: true)
        }
    }
}

struct MeshLocalStatusHUDSnapshot: Equatable {
    let sourceStatuses: [LiveShareSourceViewStatus?]
    let participantCount: Int
    let fullscreen: LiveShareFullscreenViewSnapshot

    init(
        sourceStatuses: [LiveShareSourceViewStatus],
        participantCount: Int,
        fullscreen: LiveShareFullscreenViewSnapshot
    ) {
        self.sourceStatuses = Array(sourceStatuses.prefix(4)).map(Optional.some)
            + Array(
                repeating: nil,
                count: max(0, 4 - sourceStatuses.count)
            )
        self.participantCount = max(1, participantCount)
        self.fullscreen = fullscreen
    }

    var hasActiveMedia: Bool {
        fullscreen.isOn
            || sourceStatuses.contains {
                $0 == .starting || $0 == .live || $0 == .stopping
            }
    }
}

@MainActor
struct MeshLocalStatusHUDActions {
    var setFullscreenEnabled: (Bool) -> Void
    var stopAllMedia: () -> Void

    init(
        setFullscreenEnabled: @escaping (Bool) -> Void = { _ in },
        stopAllMedia: @escaping () -> Void = {}
    ) {
        self.setFullscreenEnabled = setFullscreenEnabled
        self.stopAllMedia = stopAllMedia
    }
}

@MainActor
private struct MeshLocalStatusHUDView: View {
    let snapshot: MeshLocalStatusHUDSnapshot
    let actions: MeshLocalStatusHUDActions

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                HStack(spacing: 5) {
                    ForEach(Array(snapshot.sourceStatuses.enumerated()),
                            id: \.offset) { _, status in
                        Circle()
                            .fill(dotColor(status))
                            .frame(width: 9, height: 9)
                            .overlay {
                                if status == nil {
                                    Circle().strokeBorder(
                                        .secondary.opacity(0.55),
                                        lineWidth: 1
                                    )
                                }
                            }
                    }
                }
                Spacer(minLength: 6)
                Label(
                    "\(snapshot.participantCount)",
                    systemImage: "person.2.fill"
                )
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button {
                    actions.setFullscreenEnabled(!snapshot.fullscreen.isOn)
                } label: {
                    Label(
                        String(localized: "Fullscreen"),
                        systemImage:
                            snapshot.fullscreen.isOn
                                ? "rectangle.inset.filled"
                                : "rectangle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    MeshOverlayButtonStyle(
                        tint: snapshot.fullscreen.isOn ? .blue : .secondary
                    )
                )
                .disabled(!snapshot.fullscreen.isEnabled)
                .accessibilityIdentifier("clip.meshRoom.hud.fullscreen")

                if snapshot.hasActiveMedia {
                    Button(role: .destructive, action: actions.stopAllMedia) {
                        Label(
                            String(localized: "Stop All"),
                            systemImage: "stop.fill"
                        )
                    }
                    .buttonStyle(MeshOverlayButtonStyle(tint: .red))
                    .accessibilityIdentifier("clip.meshRoom.hud.stopAll")
                }
            }
        }
        .padding(9)
        .frame(
            width: MeshParticipantOverlayGeometry.statusHUDSize.width,
            height: MeshParticipantOverlayGeometry.statusHUDSize.height
        )
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.28), radius: 7, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.meshRoom.hud")
    }

    private func dotColor(_ status: LiveShareSourceViewStatus?) -> Color {
        switch status {
        case .starting?:
            .blue
        case .live?:
            .red
        case .stopping?:
            .orange
        case .failed?:
            .orange
        case nil:
            .clear
        }
    }
}

/// Persistent, participant-local sharing controls. It deliberately reports
/// participant count rather than a host/viewer count because every member is a
/// symmetric publisher and receiver in the clean native-v3 room.
@MainActor
final class MeshLocalStatusHUDCoordinator {
    private let actions: MeshLocalStatusHUDActions
    private(set) var panel = LiveShareOverlayPanel(
        initialSize: MeshParticipantOverlayGeometry.statusHUDSize,
        level: .statusBar
    )
    private var hostingView:
        MeshFirstMouseHostingView<MeshLocalStatusHUDView>?

    init(actions: MeshLocalStatusHUDActions) {
        self.actions = actions
        panel.setAccessibilityIdentifier("clip.meshRoom.hud.panel")
    }

    var isVisible: Bool { panel.isVisible }

    func show(
        snapshot: MeshLocalStatusHUDSnapshot,
        visibleScreenFrame: CGRect
    ) {
        let root = MeshLocalStatusHUDView(
            snapshot: snapshot,
            actions: actions
        )
        if let hostingView {
            hostingView.rootView = root
        } else {
            let hostingView = MeshFirstMouseHostingView(rootView: root)
            hostingView.frame = CGRect(
                origin: .zero,
                size: MeshParticipantOverlayGeometry.statusHUDSize
            )
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView
            self.hostingView = hostingView
        }
        hostingView?.layoutSubtreeIfNeeded()
        panel.setFrame(
            MeshParticipantOverlayGeometry.statusHUDFrame(
                visibleScreenFrame: visibleScreenFrame
            ),
            display: true,
            animate: false
        )
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func tearDown() {
        hide()
        panel.contentView = nil
        hostingView = nil
    }

    func contentHitTest(at point: CGPoint) -> NSView? {
        panel.contentView?.hitTest(point)
    }
}

@MainActor
private final class MeshFirstMouseHostingView<Content: View>:
    NSHostingView<Content>
{
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct MeshOverlayButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(
                tint.opacity(configuration.isPressed ? 0.65 : 0.86),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
    }
}
