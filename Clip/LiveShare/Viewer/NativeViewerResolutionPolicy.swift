import CoreGraphics
import Foundation

enum NativeViewerScaleMode: String, CaseIterable, Equatable, Sendable {
    case automatic
    case actualPixels
    case fit
}

struct NativeViewerResolutionRequest: Equatable, Sendable {
    let decodedPixelSize: CGSize
    /// Logical point size reported by the source Mac. Older hosts omit it.
    let sourcePointSize: CGSize?
    let destinationBackingScale: CGFloat
    let maximumContentSize: CGSize
    let mode: NativeViewerScaleMode

    init(
        decodedPixelSize: CGSize,
        sourcePointSize: CGSize? = nil,
        destinationBackingScale: CGFloat,
        maximumContentSize: CGSize,
        mode: NativeViewerScaleMode
    ) {
        self.decodedPixelSize = decodedPixelSize
        self.sourcePointSize = sourcePointSize
        self.destinationBackingScale = destinationBackingScale
        self.maximumContentSize = maximumContentSize
        self.mode = mode
    }
}

struct NativeViewerResolution: Equatable, Sendable {
    /// The video content size in AppKit points. Window chrome and Clip's
    /// identity border are deliberately excluded.
    let contentSize: CGSize
    /// Destination backing pixels used for one decoded source pixel.
    let destinationPixelsPerSourcePixel: CGFloat
    let isFitted: Bool
}

enum NativeViewerResolutionPolicy {
    static func resolve(_ request: NativeViewerResolutionRequest) -> NativeViewerResolution? {
        guard request.decodedPixelSize.width.isFinite,
              request.decodedPixelSize.height.isFinite,
              request.decodedPixelSize.width > 0,
              request.decodedPixelSize.height > 0,
              request.destinationBackingScale.isFinite,
              request.destinationBackingScale > 0,
              request.maximumContentSize.width.isFinite,
              request.maximumContentSize.height.isFinite,
              request.maximumContentSize.width > 0,
              request.maximumContentSize.height > 0 else {
            return nil
        }

        if let sourcePointSize = request.sourcePointSize,
           !isValid(sourcePointSize) {
            return nil
        }

        // AppKit window geometry is expressed in points. A source Mac's
        // logical point size is therefore the only display-independent
        // definition of "Actual": a 1,000-point window stays 1,000 points on
        // both 1x and Retina viewer displays. Dividing decoded pixels by the
        // *viewer's* backing scale incorrectly doubles Retina-hosted windows
        // on 1x viewers and halves 1x-hosted windows on Retina viewers.
        let legacyPointSize = CGSize(
            width: request.decodedPixelSize.width / request.destinationBackingScale,
            height: request.decodedPixelSize.height / request.destinationBackingScale
        )
        let preferredPointSize = request.sourcePointSize ?? legacyPointSize
        let fitScale = min(
            1,
            request.maximumContentSize.width / preferredPointSize.width,
            request.maximumContentSize.height / preferredPointSize.height
        )
        let shouldFit = switch request.mode {
        case .automatic:
            fitScale < 1
        case .actualPixels:
            false
        case .fit:
            true
        }
        let pointScale = shouldFit ? fitScale : 1
        // Native mode keeps the video surface at 100%, but the window itself
        // must remain usable on the viewer's current display. A capped
        // viewport crops the native surface; cursor-follow panning reveals the
        // hidden portion without ever scaling the shared pixels down.
        let resolvedContentSize: CGSize
        if request.mode == .actualPixels {
            resolvedContentSize = CGSize(
                width: min(preferredPointSize.width, request.maximumContentSize.width),
                height: min(preferredPointSize.height, request.maximumContentSize.height)
            )
        } else {
            resolvedContentSize = CGSize(
                width: preferredPointSize.width * pointScale,
                height: preferredPointSize.height * pointScale
            )
        }

        return NativeViewerResolution(
            contentSize: CGSize(
                width: max(1, floor(resolvedContentSize.width)),
                height: max(1, floor(resolvedContentSize.height))
            ),
            destinationPixelsPerSourcePixel:
                preferredPointSize.width * pointScale
                * request.destinationBackingScale
                / request.decodedPixelSize.width,
            isFitted: pointScale < 1
        )
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
    }
}

/// Point-space geometry for displaying a shared window at its native logical
/// size inside a smaller viewer viewport. The cursor coordinates follow the
/// capture protocol: x grows from the left and y grows from the top.
struct NativeViewerPanGeometry: Equatable, Sendable {
    let contentFrame: CGRect
    let overflowSize: CGSize

    var canPanHorizontally: Bool { overflowSize.width > 0 }
    var canPanVertically: Bool { overflowSize.height > 0 }
    var isCropped: Bool { canPanHorizontally || canPanVertically }
}

enum NativeViewerPanPolicy {
    /// Places native-sized content so the cursor is centered whenever possible.
    /// At an edge, the origin is clamped so panning never reveals empty space.
    /// An axis whose content already fits remains centered and does not pan.
    static func geometry(
        sourceLogicalSize: CGSize,
        viewportSize: CGSize,
        normalizedCursor: CGPoint?
    ) -> NativeViewerPanGeometry? {
        guard isValid(sourceLogicalSize), isValid(viewportSize) else { return nil }

        let cursor = normalizedCursor.flatMap(validatedCursor) ?? CGPoint(x: 0.5, y: 0.5)
        let sourceCursorFromBottom = CGPoint(
            x: cursor.x * sourceLogicalSize.width,
            y: (1 - cursor.y) * sourceLogicalSize.height
        )
        let preferredOrigin = CGPoint(
            x: viewportSize.width / 2 - sourceCursorFromBottom.x,
            y: viewportSize.height / 2 - sourceCursorFromBottom.y
        )
        let origin = clampedContentOrigin(
            preferredOrigin,
            sourceLogicalSize: sourceLogicalSize,
            viewportSize: viewportSize
        )

        let overflow = CGSize(
            width: max(0, sourceLogicalSize.width - viewportSize.width),
            height: max(0, sourceLogicalSize.height - viewportSize.height)
        )
        return NativeViewerPanGeometry(
            contentFrame: CGRect(origin: origin, size: sourceLogicalSize),
            overflowSize: overflow
        )
    }

    /// Clamps a manual or animated pan to the same no-empty-space bounds used
    /// by cursor following. Axes that fit are always recentered.
    static func clampedContentOrigin(
        _ proposedOrigin: CGPoint,
        sourceLogicalSize: CGSize,
        viewportSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: clampedAxisOrigin(
                proposedOrigin.x,
                contentLength: sourceLogicalSize.width,
                viewportLength: viewportSize.width
            ),
            y: clampedAxisOrigin(
                proposedOrigin.y,
                contentLength: sourceLogicalSize.height,
                viewportLength: viewportSize.height
            )
        )
    }

    /// Returns a presentation percentage relative to the source Mac's logical
    /// size. Native mode is therefore 100% on both Retina and non-Retina Macs.
    static func zoomPercentage(
        sourceLogicalSize: CGSize,
        renderedContentSize: CGSize
    ) -> Int? {
        guard isValid(sourceLogicalSize), isValid(renderedContentSize) else { return nil }
        let scale = min(
            renderedContentSize.width / sourceLogicalSize.width,
            renderedContentSize.height / sourceLogicalSize.height
        )
        guard scale.isFinite else { return nil }
        return Int((scale * 100).rounded())
    }

    private static func validatedCursor(_ cursor: CGPoint) -> CGPoint? {
        guard cursor.x.isFinite, cursor.y.isFinite else { return nil }
        return CGPoint(
            x: min(1, max(0, cursor.x)),
            y: min(1, max(0, cursor.y))
        )
    }

    private static func clampedAxisOrigin(
        _ proposedOrigin: CGFloat,
        contentLength: CGFloat,
        viewportLength: CGFloat
    ) -> CGFloat {
        guard contentLength > viewportLength else {
            return (viewportLength - contentLength) / 2
        }
        return min(0, max(viewportLength - contentLength, proposedOrigin))
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
    }
}

/// Prevents short-lived adaptive encoder dimensions from repeatedly resizing a
/// native window. An explicit authoritative geometry revision can commit as
/// soon as a matching frame arrives; otherwise a new decoded size must remain
/// stable for several consecutive frames.
struct NativeViewerDimensionStabilizer: Equatable, Sendable {
    let requiredConsecutiveFrames: Int

    private(set) var committedPixelSize: CGSize?
    private(set) var committedRevision: UInt64 = 0
    private var candidatePixelSize: CGSize?
    private var candidateFrameCount = 0

    init(requiredConsecutiveFrames: Int = 8) {
        self.requiredConsecutiveFrames = max(2, requiredConsecutiveFrames)
    }

    mutating func observe(
        decodedPixelSize: CGSize,
        authoritativePixelSize: CGSize?,
        stateRevision: UInt64
    ) -> CGSize? {
        guard decodedPixelSize.width.isFinite,
              decodedPixelSize.height.isFinite,
              decodedPixelSize.width > 0,
              decodedPixelSize.height > 0 else {
            return nil
        }

        if committedPixelSize == nil {
            return commit(decodedPixelSize, revision: stateRevision)
        }
        if decodedPixelSize == committedPixelSize {
            resetCandidate()
            committedRevision = max(committedRevision, stateRevision)
            return nil
        }

        if stateRevision > committedRevision,
           authoritativePixelSize == decodedPixelSize {
            return commit(decodedPixelSize, revision: stateRevision)
        }

        if candidatePixelSize == decodedPixelSize {
            candidateFrameCount += 1
        } else {
            candidatePixelSize = decodedPixelSize
            candidateFrameCount = 1
        }
        guard candidateFrameCount >= requiredConsecutiveFrames else { return nil }
        return commit(decodedPixelSize, revision: stateRevision)
    }

    private mutating func commit(_ size: CGSize, revision: UInt64) -> CGSize {
        committedPixelSize = size
        committedRevision = max(committedRevision, revision)
        resetCandidate()
        return size
    }

    private mutating func resetCandidate() {
        candidatePixelSize = nil
        candidateFrameCount = 0
    }
}
