import AppKit
import SwiftUI

/// Optional floating host for `RecordingStatusView`. The same SwiftUI view can
/// be embedded directly in the menu-bar popover, which is the default product
/// presentation. This host is useful for testing or an explicitly enabled HUD.
@MainActor
final class RecordingHUDController {
    private var panel: RecordingStatusPanel?
    private var hostingController: NSHostingController<RecordingStatusView>?

    var isVisible: Bool { panel?.isVisible == true }

    func makeContentViewController(
        model: RecordingPresentationModel
    ) -> NSHostingController<RecordingStatusView> {
        NSHostingController(rootView: RecordingStatusView(model: model))
    }

    func show(model: RecordingPresentationModel, on screen: NSScreen? = nil) {
        let destinationScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let destinationScreen else { return }

        let hostingController = makeContentViewController(model: model)
        let panel = self.panel ?? RecordingStatusPanel()
        self.panel = panel
        self.hostingController = hostingController

        panel.contentViewController = hostingController
        panel.setContentSize(NSSize(width: 330, height: 285))
        position(panel, on: destinationScreen)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Use this when the capture engine cannot exclude the Clip process or this
    /// specific window. The standard ScreenCaptureKit integration should filter
    /// Clip itself, allowing the menu-bar controls to remain available.
    func hideBeforeUnfilteredCapture() {
        hide()
    }

    func tearDown() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
        hostingController = nil
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        let frame = panel.frame
        panel.setFrameOrigin(
            CGPoint(
                x: visibleFrame.maxX - frame.width - 18,
                y: visibleFrame.maxY - frame.height - 18
            )
        )
    }
}

@MainActor
private final class RecordingStatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 330, height: 285),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        // ScreenCaptureKit should additionally exclude Clip's running
        // application. This prevents legacy/window-list capture from sharing it.
        sharingType = .none
    }
}

