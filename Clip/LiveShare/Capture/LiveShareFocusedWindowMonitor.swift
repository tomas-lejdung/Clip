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
        appKitDisplayFrame: CGRect
    ) -> CGRect? {
        let intersection = quartzWindowFrame.standardized.intersection(
            quartzDisplayFrame.standardized
        )
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        let localX = intersection.minX - quartzDisplayFrame.minX
        let localTop = intersection.minY - quartzDisplayFrame.minY
        return CGRect(
            x: appKitDisplayFrame.minX + localX,
            y: appKitDisplayFrame.maxY - localTop - intersection.height,
            width: intersection.width,
            height: intersection.height
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
