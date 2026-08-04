import CoreGraphics
import Foundation

/// The WindowServer geometry needed to determine which parts of one shared
/// source are still visible on the publisher's display.
///
/// Snapshots must be supplied in WindowServer front-to-back order. The utility
/// deliberately models only whole-window alpha and rectangular bounds because
/// public window-list APIs do not expose another application's per-pixel shape.
struct LiveShareCollaborationOcclusionWindowSnapshot: Equatable, Sendable {
    let windowNumber: Int
    let frame: CGRect
    let alpha: Double
    let isOnScreen: Bool
    let ownerProcessID: Int?
    let ownerName: String?
    let windowLayer: Int?

    init(
        windowNumber: Int,
        frame: CGRect,
        alpha: Double,
        isOnScreen: Bool,
        ownerProcessID: Int? = nil,
        ownerName: String? = nil,
        windowLayer: Int? = nil
    ) {
        self.windowNumber = windowNumber
        self.frame = frame
        self.alpha = alpha
        self.isOnScreen = isOnScreen
        self.ownerProcessID = ownerProcessID
        self.ownerName = ownerName
        self.windowLayer = windowLayer
    }
}

enum LiveShareCollaborationOcclusionEvaluationDisposition: String, Sendable {
    case excluded
    case systemCursor
    case aboveOverlayLevel
    case offScreen
    case transparent
    case occluding
    case invalidAlpha
    case invalidFrame
}

struct LiveShareCollaborationOcclusionEvaluation: Sendable {
    let window: LiveShareCollaborationOcclusionWindowSnapshot
    let disposition: LiveShareCollaborationOcclusionEvaluationDisposition
    let cumulativeVisibleAreaRatio: Double
}

/// Computes a conservative rectangular mask for a collaboration overlay.
///
/// The result uses the same global coordinate space as `sourceFrame`. `nil`
/// means that the source or relevant WindowServer geometry could not be
/// verified and callers must fail closed by hiding the overlay. An empty array
/// means that verified opaque windows fully cover the source.
enum LiveShareCollaborationVisibleRegionGeometry {
    static func visibleRects(
        sourceFrame: CGRect,
        windowsFrontToBack: [
            LiveShareCollaborationOcclusionWindowSnapshot
        ],
        sourceWindowNumber: Int,
        excludedWindowNumbers: Set<Int> = [],
        maximumOccludingWindowLayer: Int? = nil,
        onEvaluation: ((LiveShareCollaborationOcclusionEvaluation) -> Void)? = nil
    ) -> [CGRect]? {
        guard let sourceIndex = windowsFrontToBack.firstIndex(where: {
            $0.windowNumber == sourceWindowNumber
        }) else {
            return nil
        }
        let source = windowsFrontToBack[sourceIndex]
        guard source.isOnScreen,
              validWindowAlpha(source.alpha),
              source.alpha > 0,
              let sourceFrame = validStandardized(sourceFrame)
        else {
            return nil
        }

        var visibleRects = [sourceFrame]
        let sourceArea = sourceFrame.width * sourceFrame.height
        func report(
            _ window: LiveShareCollaborationOcclusionWindowSnapshot,
            _ disposition: LiveShareCollaborationOcclusionEvaluationDisposition
        ) {
            guard let onEvaluation else { return }
            let visibleArea = visibleRects.reduce(CGFloat.zero) {
                $0 + ($1.width * $1.height)
            }
            let ratio = min(1, max(0, visibleArea / sourceArea))
            onEvaluation(.init(
                window: window,
                disposition: disposition,
                cumulativeVisibleAreaRatio: Double(ratio)
            ))
        }
        for window in windowsFrontToBack[..<sourceIndex] {
            if excludedWindowNumbers.contains(window.windowNumber) {
                report(window, .excluded)
                continue
            }
            // CGWindowList includes the WindowServer cursor as a tiny opaque
            // pseudo-window at the public cursor window level. It is not app
            // content covering the source: the compositor already renders the
            // host's native cursor above every window. Subtracting it creates a
            // moving hole in the collaboration overlay whenever the publisher
            // focuses and points inside the shared window.
            //
            // Match the semantic CoreGraphics level instead of a PID, window
            // number, owner name, or cursor dimensions; all of those vary by
            // Mac, cursor shape, and launch.
            if window.windowLayer == Int(
                CGWindowLevelForKey(.cursorWindow)
            ) {
                report(window, .systemCursor)
                continue
            }
            // The masked fallback panel is deliberately placed at a known
            // WindowServer level. Surfaces above that level (menu extras,
            // system overlays, and other high-level panels) already occlude
            // it in the compositor. Subtracting their coarse CGWindow bounds
            // as well is both redundant and incorrect: several system
            // surfaces expose display-sized opaque bounds even though only a
            // small per-pixel region is drawn, which previously reduced a
            // Retina source to a tiny top-right mask fragment.
            if let maximumOccludingWindowLayer,
               let windowLayer = window.windowLayer,
               windowLayer > maximumOccludingWindowLayer
            {
                report(window, .aboveOverlayLevel)
                continue
            }
            if !window.isOnScreen {
                report(window, .offScreen)
                continue
            }
            guard validWindowAlpha(window.alpha) else {
                report(window, .invalidAlpha)
                return nil
            }
            // WindowServer exposes only whole-window alpha, not the exact
            // composited pixels. A floating annotation cannot reproduce the
            // attenuation of a translucent window above its source, so any
            // nonzero-alpha surface is conservatively treated as an occluder.
            guard window.alpha > 0 else {
                report(window, .transparent)
                continue
            }
            guard let cover = validStandardized(window.frame) else {
                // An opaque window above the source with unknown geometry
                // cannot safely be ignored: doing so could paint annotations
                // over unrelated content.
                report(window, .invalidFrame)
                return nil
            }
            visibleRects = visibleRects.flatMap {
                subtracting(cover, from: $0)
            }
            report(window, .occluding)
            if visibleRects.isEmpty { return [] }
        }
        return visibleRects.sorted(by: rectOrdering)
    }

    /// Converts WindowServer's top-left global coordinates into the unflipped
    /// bottom-left coordinates used by the publisher overlay's AppKit layer.
    /// Scaling is explicit because a test seam or a future presentation policy
    /// may size the panel differently from the source's logical bounds.
    static func localRects(
        visibleGlobalRects: [CGRect],
        sourceFrame: CGRect,
        localSize: CGSize
    ) -> [CGRect]? {
        guard
            let sourceFrame = validStandardized(sourceFrame),
            localSize.width.isFinite,
            localSize.height.isFinite,
            localSize.width > 0,
            localSize.height > 0
        else { return nil }
        let scaleX = localSize.width / sourceFrame.width
        let scaleY = localSize.height / sourceFrame.height
        let localBounds = CGRect(origin: .zero, size: localSize)
        var result: [CGRect] = []
        result.reserveCapacity(visibleGlobalRects.count)
        for global in visibleGlobalRects {
            guard let global = validStandardized(global) else { return nil }
            let intersection = global.intersection(sourceFrame)
            guard !intersection.isNull,
                  intersection.width > 0,
                  intersection.height > 0
            else { continue }
            let local = CGRect(
                x: (intersection.minX - sourceFrame.minX) * scaleX,
                y: (sourceFrame.maxY - intersection.maxY) * scaleY,
                width: intersection.width * scaleX,
                height: intersection.height * scaleY
            ).intersection(localBounds)
            guard !local.isNull, local.width > 0, local.height > 0 else {
                continue
            }
            result.append(local)
        }
        return result.sorted(by: rectOrdering)
    }

    private static func validStandardized(_ frame: CGRect) -> CGRect? {
        let frame = frame.standardized
        guard frame.minX.isFinite,
              frame.minY.isFinite,
              frame.maxX.isFinite,
              frame.maxY.isFinite,
              frame.width > 0,
              frame.height > 0
        else {
            return nil
        }
        return frame
    }

    private static func validWindowAlpha(_ alpha: Double) -> Bool {
        alpha.isFinite && (0...1).contains(alpha)
    }

    /// Splits `rect` around its intersection with `cover`. The four candidate
    /// strips never overlap: top and bottom span the full width, while left and
    /// right occupy only the intersection's vertical band.
    private static func subtracting(
        _ cover: CGRect,
        from rect: CGRect
    ) -> [CGRect] {
        let intersection = rect.intersection(cover)
        guard !intersection.isNull,
              intersection.width > 0,
              intersection.height > 0
        else {
            return [rect]
        }

        var pieces: [CGRect] = []
        if intersection.minY > rect.minY {
            pieces.append(CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: intersection.minY - rect.minY
            ))
        }
        if intersection.maxY < rect.maxY {
            pieces.append(CGRect(
                x: rect.minX,
                y: intersection.maxY,
                width: rect.width,
                height: rect.maxY - intersection.maxY
            ))
        }
        if intersection.minX > rect.minX {
            pieces.append(CGRect(
                x: rect.minX,
                y: intersection.minY,
                width: intersection.minX - rect.minX,
                height: intersection.height
            ))
        }
        if intersection.maxX < rect.maxX {
            pieces.append(CGRect(
                x: intersection.maxX,
                y: intersection.minY,
                width: rect.maxX - intersection.maxX,
                height: intersection.height
            ))
        }
        return pieces
    }

    private static func rectOrdering(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        if lhs.height != rhs.height { return lhs.height < rhs.height }
        return lhs.width < rhs.width
    }
}
