import AppKit
#if DEBUG
import OSLog
#endif
import QuartzCore
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

/// Window-source annotations use a capture-excluded panel ordered directly
/// above the source. When WindowServer verifies that relative placement, every
/// unrelated window above the source occludes the annotation panel naturally.
/// A conservative floating/masked fallback remains available when cross-process
/// relative placement cannot be verified. Fullscreen capture has no single
/// source window and remains an unmasked floating overlay.
enum LiveShareCollaborationSourceOverlayTarget: Equatable {
    case window(windowNumber: Int, windowLevel: Int)
    case fullscreen

    var panelLevel: NSWindow.Level {
        switch self {
        case let .window(_, windowLevel):
            NSWindow.Level(rawValue: windowLevel)
        case .fullscreen:
            .floating
        }
    }

    var collectionBehavior: NSWindow.CollectionBehavior {
        switch self {
        case .window:
            [
                .moveToActiveSpace,
                .canJoinAllApplications,
                .fullScreenAuxiliary,
                .transient,
                .ignoresCycle,
            ]
        case .fullscreen:
            [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle,
            ]
        }
    }

    var relativeWindowNumber: Int? {
        guard case let .window(windowNumber, _) = self else { return nil }
        return windowNumber
    }

    static func visibleWindow(
        _ snapshot: LiveShareCollaborationSourceWindowSnapshot?
    ) -> Self? {
        guard let snapshot, snapshot.isOnScreen else { return nil }
        return .window(
            windowNumber: snapshot.windowNumber,
            windowLevel: snapshot.windowLevel
        )
    }
}

enum LiveShareCollaborationSourceOverlayPresentationMode: Equatable {
    case sourceRelative
    case maskedFallback
    case fullscreen
    case hidden
}

struct LiveShareCollaborationSourceWindowSnapshot: Equatable, Sendable {
    let frame: CGRect
    let windowNumber: Int
    let windowLevel: Int
    let isOnScreen: Bool

    static func resolve(
        windowNumber: CGWindowID,
        information: [String: Any]
    ) -> Self? {
        guard
            let bounds = information[kCGWindowBounds as String]
                as? [String: Any],
            let frame = CGRect(
                dictionaryRepresentation: bounds as CFDictionary
            )
        else { return nil }
        return .init(
            frame: frame,
            windowNumber: Int(windowNumber),
            windowLevel:
                (information[kCGWindowLayer as String] as? NSNumber)?.intValue
                    ?? NSWindow.Level.normal.rawValue,
            isOnScreen:
                (information[kCGWindowIsOnscreen as String] as? NSNumber)?
                    .boolValue == true
        )
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
#if DEBUG
    private static let maskLogger = Logger(
        subsystem: ApplicationDirectories.bundleIdentifier,
        category: "live-share-host-mask"
    )
#endif

    typealias WindowSnapshotProvider = @MainActor (Int) ->
        [LiveShareCollaborationOcclusionWindowSnapshot]?
    typealias RelativeOrderAction = @MainActor (
        LiveShareOverlayPanel,
        Int
    ) -> Void
    typealias RelativeOrderVerifier = @MainActor (
        Int,
        Int
    ) -> Bool

    private struct Entry {
        let panel: LiveShareOverlayPanel
        let overlay: NativeViewerCollaborationOverlayView
        let visibilityMask: CAShapeLayer
    }

    private var entries: [String: Entry] = [:]
    /// Geometry changes comparatively rarely and require querying AppKit / the
    /// window server. Keep the last resolved frame so collaboration snapshots
    /// can repaint immediately without waiting for the 250 ms geometry poll.
    private var sourceFrames: [String: CGRect] = [:]
    private var sourceTargets:
        [String: LiveShareCollaborationSourceOverlayTarget] = [:]
    private var orderingCounts: [String: Int] = [:]
    private var relativeOrderingCounts: [String: Int] = [:]
    private var maskedFallbackCounts: [String: Int] = [:]
    private var presentationModes:
        [String: LiveShareCollaborationSourceOverlayPresentationMode] = [:]
    private let windowSnapshotProvider: WindowSnapshotProvider
    private let relativeOrderAction: RelativeOrderAction
    private let relativeOrderVerifier: RelativeOrderVerifier

    init(
        windowSnapshotProvider: WindowSnapshotProvider? = nil,
        relativeOrderAction: RelativeOrderAction? = nil,
        relativeOrderVerifier: RelativeOrderVerifier? = nil
    ) {
        self.windowSnapshotProvider = windowSnapshotProvider ?? { windowNumber in
            Self.windowServerWindowsFrontToBack(through: windowNumber)
        }
        self.relativeOrderAction = relativeOrderAction ?? { panel, windowNumber in
            panel.order(.above, relativeTo: windowNumber)
        }
        self.relativeOrderVerifier = relativeOrderVerifier
            ?? { panelWindowNumber, sourceWindowNumber in
                Self.windowServerConfirmsAdjacency(
                    panelWindowNumber: panelWindowNumber,
                    sourceWindowNumber: sourceWindowNumber
                )
            }
    }

    func update(
        sourceID: String,
        sourceFrame: CGRect,
        target: LiveShareCollaborationSourceOverlayTarget,
        snapshot: NativeViewerCollaborationOverlaySnapshot,
        isVisible: Bool
    ) {
        guard sourceFrame.width > 0, sourceFrame.height > 0 else {
            remove(sourceID: sourceID)
            return
        }
        sourceFrames[sourceID] = sourceFrame
        sourceTargets[sourceID] = target
        let entry = entries[sourceID] ?? makeEntry(sourceID: sourceID)
        layout(
            entry,
            sourceFrame: sourceFrame,
            snapshot: snapshot,
            isVisible: isVisible
        )
        orderingCounts[sourceID, default: 0] += 1
        guard reconcilePresentation(
            entry,
            sourceID: sourceID,
            sourceFrame: sourceFrame,
            target: target
        ) else {
            entry.panel.orderOut(nil)
            return
        }
    }

    /// Repaints collaboration state against the last resolved source frame.
    /// Pointer traffic calls this from the room snapshot path; it deliberately
    /// performs no capture/window geometry work.
    func updateSnapshot(
        sourceID: String,
        snapshot: NativeViewerCollaborationOverlaySnapshot,
        isVisible: Bool
    ) {
        // This path receives pointer traffic at up to 60 Hz. It must remain a
        // pure layer repaint: WindowServer geometry/order reconciliation is
        // owned by `update`, which runs on the dedicated placement cadence.
        guard let entry = entries[sourceID] else { return }
        entry.overlay.update(snapshot)
        entry.overlay.isHidden = !isVisible
    }

    private func layout(
        _ entry: Entry,
        sourceFrame: CGRect,
        snapshot: NativeViewerCollaborationOverlaySnapshot,
        isVisible: Bool
    ) {
        if entry.panel.frame != sourceFrame {
            entry.panel.setFrame(sourceFrame, display: true, animate: false)
        }
        let overlayFrame = CGRect(origin: .zero, size: sourceFrame.size)
        if entry.overlay.frame != overlayFrame {
            entry.overlay.frame = overlayFrame
        }
        // Resizing an NSPanel may resize its content view synchronously before
        // the frame comparison above. Keep the drawable source rect independent
        // of that AppKit side effect; otherwise the host panel can have the
        // correct size while pointers, pings, and strokes all render against a
        // stale zero-sized content frame.
        if entry.overlay.contentFrame != entry.overlay.bounds {
            entry.overlay.contentFrame = entry.overlay.bounds
        }
        entry.overlay.update(snapshot)
        entry.overlay.isHidden = !isVisible
    }

    func remove(sourceID: String) {
        sourceFrames[sourceID] = nil
        sourceTargets[sourceID] = nil
        orderingCounts[sourceID] = nil
        relativeOrderingCounts[sourceID] = nil
        maskedFallbackCounts[sourceID] = nil
        presentationModes[sourceID] = nil
        removeEntry(sourceID: sourceID)
    }

    private func removeEntry(sourceID: String) {
        guard let entry = entries.removeValue(forKey: sourceID) else { return }
        entry.panel.orderOut(nil)
        entry.panel.contentView = nil
    }

    func retainSources(_ sourceIDs: Set<String>) {
        for sourceID in sourceFrames.keys where !sourceIDs.contains(sourceID) {
            remove(sourceID: sourceID)
        }
    }

    func tearDown() {
        for entry in entries.values {
            entry.panel.orderOut(nil)
            entry.panel.contentView = nil
        }
        entries.removeAll(keepingCapacity: false)
        sourceFrames.removeAll(keepingCapacity: false)
        sourceTargets.removeAll(keepingCapacity: false)
        orderingCounts.removeAll(keepingCapacity: false)
        relativeOrderingCounts.removeAll(keepingCapacity: false)
        maskedFallbackCounts.removeAll(keepingCapacity: false)
        presentationModes.removeAll(keepingCapacity: false)
    }

    /// Narrow test/debug seam proving a snapshot repaint did not wait for a
    /// later geometry query.
    func renderedSnapshot(
        sourceID: String
    ) -> NativeViewerCollaborationOverlaySnapshot? {
        entries[sourceID]?.overlay.renderedSnapshot
    }

    func renderedContentFrame(sourceID: String) -> CGRect? {
        entries[sourceID]?.overlay.contentFrame
    }

    func renderedAnnotationLayerCount(sourceID: String) -> Int {
        entries[sourceID]?.overlay.layer?.sublayers?.count ?? 0
    }

    func target(
        sourceID: String
    ) -> LiveShareCollaborationSourceOverlayTarget? {
        sourceTargets[sourceID]
    }

    func orderingCount(sourceID: String) -> Int {
        orderingCounts[sourceID, default: 0]
    }

    func relativeOrderingCount(sourceID: String) -> Int {
        relativeOrderingCounts[sourceID, default: 0]
    }

    func maskedFallbackCount(sourceID: String) -> Int {
        maskedFallbackCounts[sourceID, default: 0]
    }

    func presentationMode(
        sourceID: String
    ) -> LiveShareCollaborationSourceOverlayPresentationMode? {
        presentationModes[sourceID]
    }

    func isVisible(sourceID: String) -> Bool {
        guard let entry = entries[sourceID] else { return false }
        return entry.panel.isVisible && !entry.overlay.isHidden
    }

    func panelWindowNumber(sourceID: String) -> Int? {
        entries[sourceID]?.panel.windowNumber
    }

    func visibilityMaskBounds(sourceID: String) -> CGRect? {
        entries[sourceID]?.visibilityMask.path?.boundingBoxOfPath
    }

    func hasVisibilityMask(sourceID: String) -> Bool {
        entries[sourceID]?.overlay.layer?.mask != nil
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
        let visibilityMask = CAShapeLayer()
        visibilityMask.fillColor = NSColor.white.cgColor
        visibilityMask.fillRule = .nonZero
        let entry = Entry(
            panel: panel,
            overlay: overlay,
            visibilityMask: visibilityMask
        )
        entries[sourceID] = entry
        return entry
    }

    /// Returns false when WindowServer cannot verify any visible source
    /// content. The caller keeps the entry alive but orders it out, allowing a
    /// later geometry/snapshot refresh to restore the same panel without a
    /// recreate flash.
    private func applyVisibilityMask(
        to entry: Entry,
        target: LiveShareCollaborationSourceOverlayTarget,
        sourceFrame: CGRect
    ) -> Bool {
        guard let sourceWindowNumber = target.relativeWindowNumber else {
            entry.overlay.layer?.mask = nil
            return true
        }
        guard let windows = windowSnapshotProvider(sourceWindowNumber) else {
#if DEBUG
            Self.logMaskPresentation(
                mode: .hidden,
                sourceWindowNumber: sourceWindowNumber,
                sourceWindowFrame: nil,
                panelFrame: sourceFrame,
                visibleAreaRatio: nil,
                reason: "window-list-unavailable"
            )
#endif
            setVisibleLocalRects([], on: entry)
            return false
        }
        guard let sourceWindow = windows.first(where: {
            $0.windowNumber == sourceWindowNumber
        }) else {
#if DEBUG
            Self.logMaskPresentation(
                mode: .hidden,
                sourceWindowNumber: sourceWindowNumber,
                sourceWindowFrame: nil,
                panelFrame: sourceFrame,
                visibleAreaRatio: nil,
                reason: "source-window-missing"
            )
#endif
            setVisibleLocalRects([], on: entry)
            return false
        }
#if DEBUG
        Self.logMaskGeometry(
            sourceWindowNumber: sourceWindowNumber,
            sourceWindowFrame: sourceWindow.frame,
            panelFrame: sourceFrame,
            panelBackingScale: entry.panel.backingScaleFactor,
            candidateCount: max(0, windows.count - 1)
        )
        var cumulativeVisibleAreaRatio = 1.0
#endif
        let onEvaluation:
            ((LiveShareCollaborationOcclusionEvaluation) -> Void)?
#if DEBUG
        onEvaluation = { evaluation in
            let previousVisibleAreaRatio = cumulativeVisibleAreaRatio
            cumulativeVisibleAreaRatio = evaluation.cumulativeVisibleAreaRatio
            let failedClosed = switch evaluation.disposition {
            case .invalidAlpha, .invalidFrame: true
            default: false
            }
            guard evaluation.cumulativeVisibleAreaRatio
                    < previousVisibleAreaRatio || failedClosed
            else { return }
            Self.logMaskCandidate(
                sourceWindowNumber: sourceWindowNumber,
                evaluation: evaluation
            )
        }
#else
        onEvaluation = nil
#endif
        guard let visibleGlobalRects =
            LiveShareCollaborationVisibleRegionGeometry.visibleRects(
                sourceFrame: sourceWindow.frame,
                windowsFrontToBack: windows,
                sourceWindowNumber: sourceWindowNumber,
                excludedWindowNumbers: Set(
                    entries.values.map(\.panel.windowNumber)
                ),
                // This fallback is presented at `.floating`. Higher-level
                // WindowServer surfaces naturally remain above it, so only
                // candidates at or below this level need rectangular
                // subtraction.
                maximumOccludingWindowLayer: Int(
                    NSWindow.Level.floating.rawValue
                ),
                onEvaluation: onEvaluation
            )
        else {
#if DEBUG
            Self.logMaskPresentation(
                mode: .hidden,
                sourceWindowNumber: sourceWindowNumber,
                sourceWindowFrame: sourceWindow.frame,
                panelFrame: sourceFrame,
                visibleAreaRatio: cumulativeVisibleAreaRatio,
                reason: "visible-region-unverifiable"
            )
#endif
            setVisibleLocalRects([], on: entry)
            return false
        }
        guard !visibleGlobalRects.isEmpty else {
#if DEBUG
            Self.logMaskPresentation(
                mode: .hidden,
                sourceWindowNumber: sourceWindowNumber,
                sourceWindowFrame: sourceWindow.frame,
                panelFrame: sourceFrame,
                visibleAreaRatio: cumulativeVisibleAreaRatio,
                reason: "fully-covered"
            )
#endif
            setVisibleLocalRects([], on: entry)
            return false
        }
        guard let visibleLocalRects =
            LiveShareCollaborationVisibleRegionGeometry.localRects(
                visibleGlobalRects: visibleGlobalRects,
                sourceFrame: sourceWindow.frame,
                localSize: sourceFrame.size
            ), !visibleLocalRects.isEmpty
        else {
#if DEBUG
            Self.logMaskPresentation(
                mode: .hidden,
                sourceWindowNumber: sourceWindowNumber,
                sourceWindowFrame: sourceWindow.frame,
                panelFrame: sourceFrame,
                visibleAreaRatio: cumulativeVisibleAreaRatio,
                reason: "local-region-empty"
            )
#endif
            setVisibleLocalRects([], on: entry)
            return false
        }
        setVisibleLocalRects(visibleLocalRects, on: entry)
#if DEBUG
        Self.logMaskPresentation(
            mode: .maskedFallback,
            sourceWindowNumber: sourceWindowNumber,
            sourceWindowFrame: sourceWindow.frame,
            panelFrame: sourceFrame,
            visibleAreaRatio: cumulativeVisibleAreaRatio,
            reason: "relative-order-unverified"
        )
#endif
        return true
    }

#if DEBUG
    private static func logMaskGeometry(
        sourceWindowNumber: Int,
        sourceWindowFrame: CGRect,
        panelFrame: CGRect,
        panelBackingScale: CGFloat,
        candidateCount: Int
    ) {
        maskLogger.debug(
            "Host mask geometry sourceWindow=\(sourceWindowNumber, privacy: .public) sourceX=\(Double(sourceWindowFrame.minX), privacy: .public) sourceY=\(Double(sourceWindowFrame.minY), privacy: .public) sourceWidth=\(Double(sourceWindowFrame.width), privacy: .public) sourceHeight=\(Double(sourceWindowFrame.height), privacy: .public) panelX=\(Double(panelFrame.minX), privacy: .public) panelY=\(Double(panelFrame.minY), privacy: .public) panelWidth=\(Double(panelFrame.width), privacy: .public) panelHeight=\(Double(panelFrame.height), privacy: .public) panelBackingScale=\(Double(panelBackingScale), privacy: .public) candidates=\(candidateCount, privacy: .public)"
        )
    }

    private static func logMaskCandidate(
        sourceWindowNumber: Int,
        evaluation: LiveShareCollaborationOcclusionEvaluation
    ) {
        let window = evaluation.window
        let ownerProcessID = window.ownerProcessID ?? -1
        let ownerName = window.ownerName ?? "unknown"
        let layer = window.windowLayer ?? Int.min
        maskLogger.debug(
            "Host mask candidate sourceWindow=\(sourceWindowNumber, privacy: .public) window=\(window.windowNumber, privacy: .public) ownerPID=\(ownerProcessID, privacy: .public) owner=\(ownerName, privacy: .private(mask: .hash)) layer=\(layer, privacy: .public) alpha=\(window.alpha, privacy: .public) x=\(Double(window.frame.minX), privacy: .public) y=\(Double(window.frame.minY), privacy: .public) width=\(Double(window.frame.width), privacy: .public) height=\(Double(window.frame.height), privacy: .public) disposition=\(evaluation.disposition.rawValue, privacy: .public) cumulativeVisibleAreaRatio=\(evaluation.cumulativeVisibleAreaRatio, privacy: .public)"
        )
    }

    private static func logMaskPresentation(
        mode: LiveShareCollaborationSourceOverlayPresentationMode,
        sourceWindowNumber: Int,
        sourceWindowFrame: CGRect?,
        panelFrame: CGRect,
        visibleAreaRatio: Double?,
        reason: String
    ) {
        let sourceSize = sourceWindowFrame?.size ?? .zero
        maskLogger.debug(
            "Host mask presentation mode=\(presentationModeName(mode), privacy: .public) sourceWindow=\(sourceWindowNumber, privacy: .public) sourceWidth=\(Double(sourceSize.width), privacy: .public) sourceHeight=\(Double(sourceSize.height), privacy: .public) panelWidth=\(Double(panelFrame.width), privacy: .public) panelHeight=\(Double(panelFrame.height), privacy: .public) visibleAreaRatio=\(visibleAreaRatio ?? -1, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private static func presentationModeName(
        _ mode: LiveShareCollaborationSourceOverlayPresentationMode
    ) -> String {
        switch mode {
        case .sourceRelative: "source-relative"
        case .maskedFallback: "masked-fallback"
        case .fullscreen: "fullscreen"
        case .hidden: "hidden"
        }
    }
#endif

    private func setVisibleLocalRects(_ rects: [CGRect], on entry: Entry) {
        let path = CGMutablePath()
        rects.forEach { path.addRect($0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        entry.visibilityMask.frame = entry.overlay.bounds
        entry.visibilityMask.path = path
        entry.overlay.layer?.mask = entry.visibilityMask
        CATransaction.commit()
    }

    private static func windowServerWindowsFrontToBack(
        through sourceWindowNumber: Int
    )
        -> [LiveShareCollaborationOcclusionWindowSnapshot]? {
        guard
            let information = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return nil }
        var result: [LiveShareCollaborationOcclusionWindowSnapshot] = []
        result.reserveCapacity(information.count)
        var foundSource = false
        for window in information {
            guard
                let number = window[kCGWindowNumber as String] as? NSNumber,
                let bounds = window[kCGWindowBounds as String]
                    as? [String: Any],
                let frame = CGRect(
                    dictionaryRepresentation: bounds as CFDictionary
                ),
                let alpha = window[kCGWindowAlpha as String] as? NSNumber,
                let isOnScreen = window[kCGWindowIsOnscreen as String]
                    as? NSNumber
            else {
                // The list is front-to-back. Dropping an unparseable entry
                // could let a floating cursor appear over an unknown window,
                // so fail closed instead.
                return nil
            }
            result.append(.init(
                windowNumber: number.intValue,
                frame: frame,
                alpha: alpha.doubleValue,
                isOnScreen: isOnScreen.boolValue,
                ownerProcessID:
                    (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                ownerName: window[kCGWindowOwnerName as String] as? String,
                windowLayer:
                    (window[kCGWindowLayer as String] as? NSNumber)?.intValue
            ))
            if number.intValue == sourceWindowNumber {
                foundSource = true
                break
            }
        }
        // Entries behind the source cannot occlude it and are intentionally
        // not parsed. Their optional/malformed metadata must not hide an
        // otherwise verifiable collaboration overlay.
        return foundSource ? result : nil
    }

    private func reconcilePresentation(
        _ entry: Entry,
        sourceID: String,
        sourceFrame: CGRect,
        target: LiveShareCollaborationSourceOverlayTarget
    ) -> Bool {
        entry.panel.collectionBehavior = target.collectionBehavior
        switch target {
        case .fullscreen:
            entry.panel.level = target.panelLevel
            entry.overlay.layer?.mask = nil
            entry.panel.orderFrontRegardless()
            presentationModes[sourceID] = .fullscreen
#if DEBUG
            Self.logMaskPresentation(
                mode: .fullscreen,
                sourceWindowNumber: 0,
                sourceWindowFrame: sourceFrame,
                panelFrame: entry.panel.frame,
                visibleAreaRatio: 1,
                reason: "display-source"
            )
#endif
            return true

        case let .window(sourceWindowNumber, _):
            // Use the source's raw level. A floating panel cannot be inserted
            // between ordinary application windows, even when its relative
            // order call names the right source window.
            entry.panel.level = target.panelLevel
            if relativeOrderVerifier(
                entry.panel.windowNumber,
                sourceWindowNumber
            ) {
                // WindowServer now owns occlusion at compositor cadence. A
                // retained rectangular mask would reintroduce delayed reveals.
                entry.overlay.layer?.mask = nil
                presentationModes[sourceID] = .sourceRelative
#if DEBUG
                Self.logMaskPresentation(
                    mode: .sourceRelative,
                    sourceWindowNumber: sourceWindowNumber,
                    sourceWindowFrame: sourceFrame,
                    panelFrame: entry.panel.frame,
                    visibleAreaRatio: 1,
                    reason: "adjacency-already-verified"
                )
#endif
                return true
            }

            // Stable placement needs no order churn. Repair only after the
            // WindowServer snapshot proves that activation, Spaces, or another
            // application reorder disturbed the source-relative pair.
            relativeOrderingCounts[sourceID, default: 0] += 1
            relativeOrderAction(entry.panel, sourceWindowNumber)
            if relativeOrderVerifier(
                entry.panel.windowNumber,
                sourceWindowNumber
            ) {
                entry.overlay.layer?.mask = nil
                presentationModes[sourceID] = .sourceRelative
#if DEBUG
                Self.logMaskPresentation(
                    mode: .sourceRelative,
                    sourceWindowNumber: sourceWindowNumber,
                    sourceWindowFrame: sourceFrame,
                    panelFrame: entry.panel.frame,
                    visibleAreaRatio: 1,
                    reason: "adjacency-repaired"
                )
#endif
                return true
            }

            // Cross-process placement can be disturbed by app activation,
            // Spaces, or same-app window reordering. Preserve the conservative
            // fallback: float the panel but reveal only verified source regions.
            guard applyVisibilityMask(
                to: entry,
                target: target,
                sourceFrame: sourceFrame
            ) else {
                presentationModes[sourceID] = .hidden
                return false
            }
            entry.panel.level = .floating
            entry.panel.orderFrontRegardless()
            maskedFallbackCounts[sourceID, default: 0] += 1
            presentationModes[sourceID] = .maskedFallback
            return true
        }
    }

    private static func windowServerConfirmsAdjacency(
        panelWindowNumber: Int,
        sourceWindowNumber: Int
    ) -> Bool {
        guard
            let information = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else { return false }
        var previousWindowNumber: Int?
        for window in information {
            guard
                let number = window[kCGWindowNumber as String] as? NSNumber
            else {
                // Exact adjacency cannot be proven when a WindowServer entry
                // is malformed. Fall back instead of painting over it.
                return false
            }
            let windowNumber = number.intValue
            if windowNumber == sourceWindowNumber {
                return previousWindowNumber == panelWindowNumber
            }
            previousWindowNumber = windowNumber
        }
        return false
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
            .buttonStyle(.plain)
            .foregroundStyle(
                snapshot.state == .shareable ? Color.primary : Color.red
            )
            .disabled(!snapshot.state.isEnabled)
            .opacity(snapshot.state.isEnabled ? 1 : 0.45)
            .modifier(
                ClipPopoverHoverEffect(
                    isInteractive: snapshot.state.isEnabled
                )
            )
            .accessibilityIdentifier(
                "clip.meshRoom.focusedWindow.primary"
            )

            Rectangle()
                .fill(.primary.opacity(0.12))
                .frame(width: 1, height: 18)
                .accessibilityHidden(true)

            Button(action: toggleSide) {
                Image(
                    systemName:
                        side == .left ? "chevron.right" : "chevron.left"
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 29, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(ClipPopoverHoverEffect())
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
