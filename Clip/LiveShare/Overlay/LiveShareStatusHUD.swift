import AppKit
import SwiftUI

struct LiveShareStatusHUDSnapshot: Equatable, Sendable {
    let slots: [LiveShareSourceSlotViewSnapshot]
    let connectedViewerCount: Int
    let fullscreen: LiveShareFullscreenViewSnapshot
    let hasCapturePressureWarning: Bool

    init(
        slots: [LiveShareSourceSlotViewSnapshot],
        connectedViewerCount: Int,
        fullscreen: LiveShareFullscreenViewSnapshot,
        hasCapturePressureWarning: Bool = false
    ) {
        let byIndex = Dictionary(
            slots.filter { (0..<4).contains($0.index) }.map { ($0.index, $0.state) },
            uniquingKeysWith: { _, newest in newest }
        )
        if fullscreen.isOn {
            self.slots = (0..<4).map {
                LiveShareSourceSlotViewSnapshot(
                    index: $0,
                    state: $0 == 0 ? (byIndex[0] ?? .starting) : .empty
                )
            }
        } else {
            self.slots = (0..<4).map {
                LiveShareSourceSlotViewSnapshot(index: $0, state: byIndex[$0] ?? .empty)
            }
        }
        self.connectedViewerCount = max(0, connectedViewerCount)
        self.fullscreen = fullscreen
        self.hasCapturePressureWarning = hasCapturePressureWarning
    }

    init(viewSnapshot: LiveShareViewSnapshot) {
        self.init(
            slots: viewSnapshot.slots,
            connectedViewerCount: viewSnapshot.connectedViewerCount,
            fullscreen: viewSnapshot.fullscreen,
            hasCapturePressureWarning: viewSnapshot.capturePressureWarning != nil
        )
    }

    var hasActiveMedia: Bool {
        fullscreen.isOn || slots.contains { $0.state != .empty }
    }

    var contentSize: CGSize {
        return CGSize(
            width: 190,
            // Both idle and active states contain the same two rows. Keeping
            // one height prevents the top-right panel from gaining empty
            // vertical padding and visibly jumping when Stop All appears.
            height: 66 + (hasCapturePressureWarning ? 24 : 0)
        )
    }
}

@MainActor
struct LiveShareStatusHUDActions {
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
struct LiveShareStatusHUDView: View {
    let snapshot: LiveShareStatusHUDSnapshot
    let actions: LiveShareStatusHUDActions

    var body: some View {
        VStack(spacing: 7) {
            if snapshot.hasCapturePressureWarning {
                Label("Dropping capture frames", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("clip.liveShare.hud.capturePressureWarning")
            }

            HStack(spacing: 7) {
                HStack(spacing: 5) {
                    ForEach(snapshot.slots) { slot in
                        LiveShareSourceDot(state: slot.state)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(sourceAccessibilityLabel)

                Spacer(minLength: 6)

                Label(
                    "\(snapshot.connectedViewerCount)",
                    systemImage: "person.2.fill"
                )
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    String(localized: "\(snapshot.connectedViewerCount) connected viewers")
                )
            }

            HStack(spacing: 6) {
                Button {
                    actions.setFullscreenEnabled(!snapshot.fullscreen.isOn)
                } label: {
                    Label(
                        String(localized: "Fullscreen"),
                        systemImage: snapshot.fullscreen.isOn
                            ? "rectangle.inset.filled"
                            : "rectangle"
                    )
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    LiveShareHUDButtonStyle(
                        tint: snapshot.fullscreen.isOn ? .blue : .secondary
                    )
                )
                .disabled(!snapshot.fullscreen.isEnabled)
                .help(snapshot.fullscreen.displayName)
                .accessibilityValue(snapshot.fullscreen.isOn ? "On" : "Off")
                .accessibilityIdentifier("clip.liveShare.hud.fullscreen")

                if snapshot.hasActiveMedia {
                    Button(role: .destructive, action: actions.stopAllMedia) {
                        Label(String(localized: "Stop All"), systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(LiveShareHUDButtonStyle(tint: .red))
                    .accessibilityIdentifier("clip.liveShare.hud.stopAll")
                }
            }
        }
        .padding(9)
        .frame(width: snapshot.contentSize.width, height: snapshot.contentSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.28), radius: 7, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.liveShare.hud")
    }

    private var sourceAccessibilityLabel: String {
        let live = snapshot.slots.count { $0.state == .live }
        let starting = snapshot.slots.count { $0.state == .starting }
        return String(localized: "\(live) live and \(starting) starting sources out of 4")
    }
}

@MainActor
final class LiveShareStatusHUDController {
    private let actions: LiveShareStatusHUDActions
    private let panel = LiveShareOverlayPanel(
        initialSize: CGSize(width: 190, height: 66),
        level: .statusBar
    )
    private var hostingView: LiveShareFirstMouseHostingView<LiveShareStatusHUDView>?
    private var snapshot: LiveShareStatusHUDSnapshot?
    private var visibleScreenFrame: CGRect?

    var isVisible: Bool { panel.isVisible }

    init(actions: LiveShareStatusHUDActions) {
        self.actions = actions
    }

    func show(
        snapshot: LiveShareStatusHUDSnapshot,
        visibleScreenFrame: CGRect
    ) {
        self.snapshot = snapshot
        self.visibleScreenFrame = visibleScreenFrame
        render(snapshot)
        let frame = LiveShareOverlayGeometry.topRightHUDFrame(
            visibleScreenFrame: visibleScreenFrame,
            size: snapshot.contentSize
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func tearDown() {
        hide()
        snapshot = nil
        visibleScreenFrame = nil
        panel.contentView = nil
        hostingView = nil
    }

    private func render(_ snapshot: LiveShareStatusHUDSnapshot) {
        let rootView = LiveShareStatusHUDView(snapshot: snapshot, actions: actions)
        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = LiveShareFirstMouseHostingView(rootView: rootView)
            hostingView.frame = CGRect(origin: .zero, size: snapshot.contentSize)
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView
            self.hostingView = hostingView
        }
    }
}

private struct LiveShareSourceDot: View {
    let state: LiveShareSourceSlotState

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 9, height: 9)
            .overlay {
                if state == .empty {
                    Circle().strokeBorder(.secondary.opacity(0.55), lineWidth: 1)
                }
            }
            .accessibilityLabel(label)
    }

    private var fill: Color {
        switch state {
        case .empty: .clear
        case .starting: .blue
        case .live: .red
        }
    }

    private var label: String {
        switch state {
        case .empty: String(localized: "Empty source slot")
        case .starting: String(localized: "Source starting")
        case .live: String(localized: "Source live")
        }
    }
}

private struct LiveShareHUDButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        LiveShareHUDButtonBody(
            label: configuration.label,
            tint: tint,
            isPressed: configuration.isPressed
        )
    }
}

private struct LiveShareHUDButtonBody<Label: View>: View {
    let label: Label
    let tint: Color
    let isPressed: Bool
    @State private var isHovering = false

    var body: some View {
        label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                tint.opacity(isPressed ? 0.65 : (isHovering ? 1 : 0.85)),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
            .onHover { isInside in
                isHovering = isInside
                (isInside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }
}
