import AppKit
import ClipCapture
import CoreGraphics
import Foundation

struct FocusedLiveShareWindow: Equatable, Sendable {
    let window: ShareableCaptureWindow
    /// AppKit global coordinates used to place a normal overlay panel.
    let appKitFrame: CGRect
}

enum LiveShareWindowCoordinateConversion {
    static func appKitFrame(
        for quartzWindowFrame: CGRect,
        quartzDisplayFrame: CGRect,
        appKitDisplayFrame: CGRect,
        preservingFullWindowExtent: Bool = false
    ) -> CGRect? {
        let windowFrame = quartzWindowFrame.standardized
        let quartzDisplayFrame = quartzDisplayFrame.standardized
        let appKitDisplayFrame = appKitDisplayFrame.standardized
        let intersection = windowFrame.intersection(quartzDisplayFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        guard quartzDisplayFrame.width > 0,
              quartzDisplayFrame.height > 0,
              appKitDisplayFrame.width > 0,
              appKitDisplayFrame.height > 0
        else { return nil }

        // Quartz/WindowServer uses top-left display coordinates while AppKit
        // uses bottom-left coordinates. Collaboration overlays opt into the
        // *entire* source-window extent instead of only its display
        // intersection. Their visibility masks are calculated against the
        // entire WindowServer window. Mapping such a mask into a clipped panel
        // compresses an off-display surviving strip back onto the visible
        // display, which is why moving a Retina-hosted source partly off-screen
        // used to reveal progressively more of the pointer. WindowServer
        // naturally clips the resulting full-extent panel at presentation.
        //
        // Apply the display's coordinate ratio as well. It is normally 1, but
        // making the conversion explicit keeps Quartz pixels and AppKit points
        // aligned for Retina displays and for deterministic mixed-DPI tests.
        let representedFrame = preservingFullWindowExtent
            ? windowFrame
            : intersection
        let scaleX = appKitDisplayFrame.width / quartzDisplayFrame.width
        let scaleY = appKitDisplayFrame.height / quartzDisplayFrame.height
        let localX = (representedFrame.minX - quartzDisplayFrame.minX) * scaleX
        let localTop = (representedFrame.minY - quartzDisplayFrame.minY) * scaleY
        let appKitSize = CGSize(
            width: representedFrame.width * scaleX,
            height: representedFrame.height * scaleY
        )
        return CGRect(
            x: appKitDisplayFrame.minX + localX,
            y: appKitDisplayFrame.maxY - localTop - appKitSize.height,
            width: appKitSize.width,
            height: appKitSize.height
        )
    }
}

@MainActor
final class LiveShareFocusedWindowMonitor {
    typealias Handler = @MainActor @Sendable (FocusedLiveShareWindow?) -> Void

    private let discovery: any CaptureContentDiscovering
    private let excludedBundleIdentifier: String?
    private let frontmostProcessID: @MainActor @Sendable () -> pid_t?
    private let handler: Handler
    private var task: Task<Void, Never>?
    private var lastValue: FocusedLiveShareWindow?
    private var refreshGeneration: UInt64 = 0

    init(
        discovery: any CaptureContentDiscovering = ScreenCaptureContentDiscovery(),
        excludedBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        frontmostProcessID: @escaping @MainActor @Sendable () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        handler: @escaping Handler
    ) {
        self.discovery = discovery
        self.excludedBundleIdentifier = excludedBundleIdentifier
        self.frontmostProcessID = frontmostProcessID
        self.handler = handler
    }

    func start() {
        guard task == nil else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        task = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await refresh(generation: generation)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        refreshGeneration &+= 1
        task?.cancel()
        task = nil
        publish(nil)
    }

    private func refresh(generation: UInt64) async {
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        guard let processID = frontmostProcessID() else {
            publish(nil, generation: generation)
            return
        }
        do {
            let content = try await discovery.shareableContent(
                excludingBundleIdentifier: excludedBundleIdentifier
            )
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            guard let window = FocusedWindowSelection.eligibleWindow(
                frontmostProcessID: processID,
                orderedWindows: content.windows,
                minimumPointSize: CGSize(width: 100, height: 100)
            ), let frame = appKitFrame(for: window.frame) else {
                publish(nil, generation: generation)
                return
            }
            publish(
                FocusedLiveShareWindow(window: window, appKitFrame: frame),
                generation: generation
            )
        } catch {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            publish(nil, generation: generation)
        }
    }

    private func appKitFrame(for quartzWindowFrame: CGRect) -> CGRect? {
        let candidates = NSScreen.screens.compactMap { screen -> (CGRect, CGRect)? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            return (CGDisplayBounds(number.uint32Value), screen.frame)
        }
        let match = candidates.max { lhs, rhs in
            lhs.0.intersection(quartzWindowFrame).area
                < rhs.0.intersection(quartzWindowFrame).area
        }
        guard let match else { return nil }
        return LiveShareWindowCoordinateConversion.appKitFrame(
            for: quartzWindowFrame,
            quartzDisplayFrame: match.0,
            appKitDisplayFrame: match.1
        )
    }

    private func publish(_ value: FocusedLiveShareWindow?) {
        guard value != lastValue else { return }
        lastValue = value
        handler(value)
    }

    private func publish(
        _ value: FocusedLiveShareWindow?,
        generation: UInt64
    ) {
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        publish(value)
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
