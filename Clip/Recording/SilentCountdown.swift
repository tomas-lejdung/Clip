import AppKit
import Combine
import SwiftUI

@MainActor
final class CountdownPresentationModel: ObservableObject {
    @Published fileprivate(set) var secondsRemaining: Int
    let targetDescription: String?

    init(secondsRemaining: Int, targetDescription: String? = nil) {
        self.secondsRemaining = max(0, secondsRemaining)
        self.targetDescription = targetDescription
    }

    static func demo(secondsRemaining: Int = 3) -> CountdownPresentationModel {
        CountdownPresentationModel(
            secondsRemaining: secondsRemaining,
            targetDescription: String(localized: "Selected Area")
        )
    }
}

@MainActor
struct SilentCountdownView: View {
    @ObservedObject var model: CountdownPresentationModel

    var body: some View {
        VStack(spacing: 7) {
            Text("\(model.secondsRemaining)")
                .font(.system(size: 68, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityLabel(
                    String(localized: "Recording starts in \(model.secondsRemaining)")
                )

            if let targetDescription = model.targetDescription {
                Text(targetDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .frame(width: 146, height: 132)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.white.opacity(0.2))
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clip.countdown")
    }
}

/// Runs the visual-only countdown and removes its window before handing control
/// to the recording engine. This type does not produce sound and does not touch
/// ScreenCaptureKit or privacy APIs.
@MainActor
final class SilentCountdownController {
    typealias AsyncHandler = @MainActor @Sendable () async -> Void

    private let scheduler: CountdownScheduler
    private let onFinished: AsyncHandler
    private let onCancelled: AsyncHandler

    private var panel: CountdownPanel?
    private var model: CountdownPresentationModel?
    private var countdownTask: Task<Void, Never>?
    private var activeRunIdentifier: UUID?

    var isRunning: Bool { activeRunIdentifier != nil }

    init(
        scheduler: CountdownScheduler = .live,
        onFinished: @escaping AsyncHandler,
        onCancelled: @escaping AsyncHandler
    ) {
        self.scheduler = scheduler
        self.onFinished = onFinished
        self.onCancelled = onCancelled
    }

    /// `anchorRectangleInGlobalPoints` can be the selected area or full display.
    /// The small, click-through panel is centered and clamped to `screen`.
    func start(
        seconds: Int,
        anchorRectangleInGlobalPoints: CGRect,
        screen: NSScreen,
        targetDescription: String? = nil
    ) {
        stopWithoutCallback()

        let seconds = max(0, seconds)
        let runIdentifier = UUID()
        activeRunIdentifier = runIdentifier

        if seconds > 0 {
            let model = CountdownPresentationModel(
                secondsRemaining: seconds,
                targetDescription: targetDescription
            )
            self.model = model

            let panel = CountdownPanel(
                contentViewController: NSHostingController(
                    rootView: SilentCountdownView(model: model)
                ),
                onCancel: { [weak self] in self?.cancel() }
            )
            self.panel = panel
            position(
                panel,
                centeredIn: anchorRectangleInGlobalPoints,
                constrainedTo: screen.frame
            )
            panel.makeKeyAndOrderFront(nil)
        }

        countdownTask = Task { @MainActor [weak self] in
            await self?.run(seconds: seconds, identifier: runIdentifier)
        }
    }

    func cancel() {
        guard activeRunIdentifier != nil else { return }
        activeRunIdentifier = nil
        countdownTask?.cancel()
        countdownTask = nil
        hidePanel()
        let callback = onCancelled

        Task { @MainActor in
            await Task.yield()
            await callback()
        }
    }

    func stopWithoutCallback() {
        activeRunIdentifier = nil
        countdownTask?.cancel()
        countdownTask = nil
        hidePanel()
    }

    private func run(seconds: Int, identifier: UUID) async {
        for value in CountdownPresentationSequence.values(seconds: seconds) {
            guard activeRunIdentifier == identifier, !Task.isCancelled else { return }
            model?.secondsRemaining = value

            do {
                try await scheduler.sleep(.seconds(1))
            } catch {
                return
            }
        }

        guard activeRunIdentifier == identifier, !Task.isCancelled else { return }
        activeRunIdentifier = nil
        countdownTask = nil
        hidePanel()
        let callback = onFinished

        // Give WindowServer a frame to remove the overlay so it cannot appear in
        // the recording's first sample, even when countdown is configured Off.
        await Task.yield()
        try? await ContinuousClock().sleep(for: .milliseconds(20))
        await callback()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
        model = nil
    }

    private func position(
        _ panel: NSPanel,
        centeredIn anchorRectangle: CGRect,
        constrainedTo screenFrame: CGRect
    ) {
        let safeAnchor = anchorRectangle.isNull || anchorRectangle.isEmpty
            ? screenFrame
            : anchorRectangle.intersection(screenFrame)
        let size = panel.frame.size
        let x = min(
            max(safeAnchor.midX - size.width / 2, screenFrame.minX + 8),
            screenFrame.maxX - size.width - 8
        )
        let y = min(
            max(safeAnchor.midY - size.height / 2, screenFrame.minY + 8),
            screenFrame.maxY - size.height - 8
        )
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }
}

@MainActor
private final class CountdownPanel: NSPanel {
    private let onCancel: @MainActor @Sendable () -> Void

    override var canBecomeKey: Bool { true }

    init(
        contentViewController: NSViewController,
        onCancel: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onCancel = onCancel
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 146, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.contentViewController = contentViewController
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        sharingType = .none
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != 53 else {
            onCancel()
            return
        }
        super.keyDown(with: event)
    }
}
