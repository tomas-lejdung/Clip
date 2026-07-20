import AppKit
import SwiftUI

enum FocusedWindowShareOverlayState: Equatable, Sendable {
    case shareable
    case starting
    case live
    case stopping

    var title: String {
        switch self {
        case .shareable:
            String(localized: "Share")
        case .starting, .live:
            String(localized: "Stop")
        case .stopping:
            String(localized: "Stopping…")
        }
    }

    var systemImage: String {
        switch self {
        case .shareable: "play.fill"
        case .starting, .live, .stopping: "stop.fill"
        }
    }

    var isEnabled: Bool { self != .stopping }
}

enum FocusedWindowShareOverlayMovement: Equatable, Sendable {
    case targetRefresh
    case anchorToggle

    var isAnimated: Bool { self == .anchorToggle }
}

struct FocusedWindowShareOverlaySnapshot: Equatable, Sendable {
    let sourceID: String
    let applicationName: String
    let windowTitle: String
    let state: FocusedWindowShareOverlayState
}

@MainActor
struct FocusedWindowShareOverlayActions {
    var share: (String) -> Void
    var stop: (String) -> Void

    init(
        share: @escaping (String) -> Void = { _ in },
        stop: @escaping (String) -> Void = { _ in }
    ) {
        self.share = share
        self.stop = stop
    }
}

@MainActor
struct FocusedWindowShareOverlayView: View {
    let snapshot: FocusedWindowShareOverlaySnapshot
    let side: LiveShareOverlayAnchorSide
    let primaryAction: () -> Void
    let toggleSide: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: primaryAction) {
                Label(snapshot.state.title, systemImage: snapshot.state.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(
                LiveShareOverlayPrimaryButtonStyle(
                    color: primaryColor,
                    isEnabled: snapshot.state.isEnabled
                )
            )
            .disabled(!snapshot.state.isEnabled)
            .help(primaryHelp)
            .accessibilityLabel(primaryHelp)
            .accessibilityIdentifier("clip.liveShare.focusedWindow.primary")

            Button(action: toggleSide) {
                Image(systemName: side == .left ? "arrow.right" : "arrow.left")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 27, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(LiveShareOverlayArrowButtonStyle())
            .help(String(localized: "Move control to the other side"))
            .accessibilityLabel(String(localized: "Move share control to the other side"))
            .accessibilityIdentifier("clip.liveShare.focusedWindow.move")
        }
        .frame(
            width: LiveShareOverlayGeometry.focusedControlSize.width,
            height: LiveShareOverlayGeometry.focusedControlSize.height
        )
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.liveShare.focusedWindow.overlay")
    }

    private var primaryColor: Color {
        switch snapshot.state {
        case .shareable: .secondary
        case .starting: .blue
        case .live: .red
        case .stopping: .secondary
        }
    }

    private var primaryHelp: String {
        switch snapshot.state {
        case .shareable:
            String(localized: "Share \(snapshot.applicationName): \(snapshot.windowTitle)")
        case .starting, .live, .stopping:
            String(localized: "Stop sharing \(snapshot.applicationName): \(snapshot.windowTitle)")
        }
    }
}

@MainActor
final class FocusedWindowShareOverlayController {
    private let actions: FocusedWindowShareOverlayActions
    private let panel = LiveShareOverlayPanel(
        initialSize: LiveShareOverlayGeometry.focusedControlSize,
        level: .floating
    )
    private var hostingView: LiveShareFirstMouseHostingView<FocusedWindowShareOverlayView>?
    private var anchorMemory = LiveShareOverlayAnchorMemory()
    private var currentSnapshot: FocusedWindowShareOverlaySnapshot?
    private var currentTargetWindowFrame: CGRect?
    private var currentVisibleScreenFrame: CGRect?

    var isVisible: Bool { panel.isVisible }

    init(actions: FocusedWindowShareOverlayActions) {
        self.actions = actions
    }

    func show(
        snapshot: FocusedWindowShareOverlaySnapshot,
        targetWindowFrame: CGRect,
        visibleScreenFrame: CGRect
    ) {
        currentSnapshot = snapshot
        currentTargetWindowFrame = targetWindowFrame
        currentVisibleScreenFrame = visibleScreenFrame
        render()
        movePanel(for: .targetRefresh)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        currentSnapshot = nil
        currentTargetWindowFrame = nil
        currentVisibleScreenFrame = nil
    }

    /// Ends a Live Share session. Per-window anchor choices intentionally do not
    /// survive a session boundary.
    func tearDown() {
        hide()
        anchorMemory.reset()
        panel.contentView = nil
        hostingView = nil
    }

    func rememberedSide(for sourceID: String) -> LiveShareOverlayAnchorSide {
        anchorMemory.side(for: sourceID)
    }

    private func performPrimaryAction() {
        guard let snapshot else { return }
        switch snapshot.state {
        case .shareable:
            actions.share(snapshot.sourceID)
        case .starting, .live:
            actions.stop(snapshot.sourceID)
        case .stopping:
            break
        }
    }

    private func toggleSide() {
        guard let snapshot else { return }
        anchorMemory.toggle(for: snapshot.sourceID)
        render()
        movePanel(for: .anchorToggle)
    }

    private var snapshot: FocusedWindowShareOverlaySnapshot? { currentSnapshot }

    private func render() {
        guard let snapshot else { return }
        let rootView = FocusedWindowShareOverlayView(
            snapshot: snapshot,
            side: rememberedSide(for: snapshot.sourceID),
            primaryAction: { [weak self] in self?.performPrimaryAction() },
            toggleSide: { [weak self] in self?.toggleSide() }
        )

        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = LiveShareFirstMouseHostingView(rootView: rootView)
            hostingView.frame = CGRect(origin: .zero, size: LiveShareOverlayGeometry.focusedControlSize)
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView
            self.hostingView = hostingView
        }
    }

    private func movePanel(for movement: FocusedWindowShareOverlayMovement) {
        guard let snapshot,
              let currentTargetWindowFrame,
              let currentVisibleScreenFrame else { return }
        let frame = LiveShareOverlayGeometry.focusedControlFrame(
            targetWindowFrame: currentTargetWindowFrame,
            visibleScreenFrame: currentVisibleScreenFrame,
            side: rememberedSide(for: snapshot.sourceID)
        )
        guard movement.isAnimated else {
            panel.setFrame(frame, display: true, animate: false)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

private struct LiveShareOverlayPrimaryButtonStyle: ButtonStyle {
    let color: Color
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        LiveShareOverlayPrimaryButtonBody(
            label: configuration.label,
            color: color,
            isEnabled: isEnabled,
            isPressed: configuration.isPressed
        )
    }
}

private struct LiveShareOverlayPrimaryButtonBody<Label: View>: View {
    let label: Label
    let color: Color
    let isEnabled: Bool
    let isPressed: Bool
    @State private var isHovering = false

    var body: some View {
        label
            .foregroundStyle(.white)
            .background(
                color.opacity(
                    isEnabled
                        ? (isPressed ? 0.68 : (isHovering ? 1 : 0.86))
                        : 0.38
                )
            )
            .contentShape(Rectangle())
            .onHover { isInside in
                isHovering = isInside
                (isInside && isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }
}

private struct LiveShareOverlayArrowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LiveShareOverlayArrowButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed
        )
    }
}

private struct LiveShareOverlayArrowButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovering = false

    var body: some View {
        label
            .foregroundStyle(.primary)
            .background(.white.opacity(isPressed ? 0.2 : (isHovering ? 0.11 : 0.001)))
            .contentShape(Rectangle())
            .onHover { isInside in
                isHovering = isInside
                (isInside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }
}

@MainActor
final class LiveShareFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

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

        // ScreenCaptureKit also excludes Clip's process, but keep this defense
        // for older/window-list capture paths.
        sharingType = .none
    }
}
