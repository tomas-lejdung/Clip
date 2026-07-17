import CoreGraphics

struct PixelAlignedCaptureGeometry: Equatable, Sendable {
    let sourceRectangle: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Pure selection math shared by pointer, keyboard, persistence, and tests.
enum CaptureSelectionGeometry {
    /// Returns the exact pointer-drag rectangle without applying the product's
    /// minimum capture size. This keeps creation anchored under the pointer;
    /// the minimum is applied once the gesture ends.
    static func draftRectangle(
        from anchor: CGPoint,
        to currentPoint: CGPoint,
        in bounds: CGRect,
        aspectRatio: CGFloat? = nil
    ) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let boundedAnchor = CGPoint(
            x: min(max(anchor.x, bounds.minX), bounds.maxX),
            y: min(max(anchor.y, bounds.minY), bounds.maxY)
        )
        let boundedCurrent = CGPoint(
            x: min(max(currentPoint.x, bounds.minX), bounds.maxX),
            y: min(max(currentPoint.y, bounds.minY), bounds.maxY)
        )
        let extendsLeft = boundedCurrent.x < boundedAnchor.x
        let extendsDown = boundedCurrent.y < boundedAnchor.y
        var width = abs(boundedCurrent.x - boundedAnchor.x)
        var height = abs(boundedCurrent.y - boundedAnchor.y)

        if let aspectRatio, aspectRatio.isFinite, aspectRatio > 0,
           width > 0 || height > 0 {
            if height == 0 || width / height > aspectRatio {
                height = width / aspectRatio
            } else {
                width = height * aspectRatio
            }

            let availableWidth = extendsLeft
                ? boundedAnchor.x - bounds.minX
                : bounds.maxX - boundedAnchor.x
            let availableHeight = extendsDown
                ? boundedAnchor.y - bounds.minY
                : bounds.maxY - boundedAnchor.y
            let scale = min(
                1,
                width > 0 ? availableWidth / width : 1,
                height > 0 ? availableHeight / height : 1
            )
            width *= max(0, scale)
            height *= max(0, scale)
        }

        return CGRect(
            x: extendsLeft ? boundedAnchor.x - width : boundedAnchor.x,
            y: extendsDown ? boundedAnchor.y - height : boundedAnchor.y,
            width: width,
            height: height
        )
    }

    static func clamped(
        _ rectangle: CGRect,
        to bounds: CGRect,
        minimumSize requestedMinimumSize: CGSize
    ) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let standardized = rectangle.standardized
        let minimumSize = CGSize(
            width: min(max(1, requestedMinimumSize.width), bounds.width),
            height: min(max(1, requestedMinimumSize.height), bounds.height)
        )
        let width = min(max(standardized.width, minimumSize.width), bounds.width)
        let height = min(max(standardized.height, minimumSize.height), bounds.height)
        let x = min(max(standardized.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(standardized.minY, bounds.minY), bounds.maxY - height)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Finalizes a pointer-created draft after mouse-up. Clicks and nearly
    /// one-dimensional strokes are ignored; a genuine two-axis drag is only
    /// then expanded to the product minimum and clamped to the display.
    static func finalizedDraftRectangle(
        _ rectangle: CGRect,
        in bounds: CGRect,
        minimumSize: CGSize
    ) -> CGRect? {
        let standardized = rectangle.standardized
        guard standardized.width >= 2, standardized.height >= 2 else { return nil }
        return clamped(standardized, to: bounds, minimumSize: minimumSize)
    }

    static func rectangle(
        from anchor: CGPoint,
        to currentPoint: CGPoint,
        in bounds: CGRect,
        minimumSize: CGSize,
        aspectRatio: CGFloat? = nil
    ) -> CGRect {
        let boundedAnchor = CGPoint(
            x: min(max(anchor.x, bounds.minX), bounds.maxX),
            y: min(max(anchor.y, bounds.minY), bounds.maxY)
        )
        let boundedCurrent = CGPoint(
            x: min(max(currentPoint.x, bounds.minX), bounds.maxX),
            y: min(max(currentPoint.y, bounds.minY), bounds.maxY)
        )

        var width = max(abs(boundedCurrent.x - boundedAnchor.x), minimumSize.width)
        var height = max(abs(boundedCurrent.y - boundedAnchor.y), minimumSize.height)

        if let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 {
            if width / height > aspectRatio {
                height = width / aspectRatio
            } else {
                width = height * aspectRatio
            }
        }

        let x = boundedCurrent.x < boundedAnchor.x ? boundedAnchor.x - width : boundedAnchor.x
        let y = boundedCurrent.y < boundedAnchor.y ? boundedAnchor.y - height : boundedAnchor.y

        return clamped(
            CGRect(x: x, y: y, width: width, height: height),
            to: bounds,
            minimumSize: minimumSize
        )
    }

    static func moved(_ rectangle: CGRect, by delta: CGVector, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let width = min(rectangle.width, bounds.width)
        let height = min(rectangle.height, bounds.height)
        let x = min(max(rectangle.minX + delta.dx, bounds.minX), bounds.maxX - width)
        let y = min(max(rectangle.minY + delta.dy, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func resized(
        _ rectangle: CGRect,
        using handle: CaptureSelectionHandle,
        delta: CGVector,
        in bounds: CGRect,
        minimumSize: CGSize,
        preserveAspectRatio: Bool
    ) -> CGRect {
        let original = clamped(rectangle, to: bounds, minimumSize: minimumSize)
        let horizontal = handle.horizontalDirection
        let vertical = handle.verticalDirection

        if preserveAspectRatio {
            return aspectRatioResize(
                original,
                horizontal: horizontal,
                vertical: vertical,
                delta: delta,
                bounds: bounds,
                minimumSize: minimumSize
            )
        }

        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        if horizontal < 0 {
            minX = min(max(original.minX + delta.dx, bounds.minX), maxX - minimumSize.width)
        } else if horizontal > 0 {
            maxX = max(min(original.maxX + delta.dx, bounds.maxX), minX + minimumSize.width)
        }

        if vertical < 0 {
            minY = min(max(original.minY + delta.dy, bounds.minY), maxY - minimumSize.height)
        } else if vertical > 0 {
            maxY = max(min(original.maxY + delta.dy, bounds.maxY), minY + minimumSize.height)
        }

        return clamped(
            CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            to: bounds,
            minimumSize: minimumSize
        )
    }

    static func handleRectangles(
        for rectangle: CGRect,
        handleSize: CGFloat
    ) -> [CaptureSelectionHandle: CGRect] {
        Dictionary(uniqueKeysWithValues: CaptureSelectionHandle.allCases.map { handle in
            let center = handle.center(in: rectangle)
            return (
                handle,
                CGRect(
                    x: center.x - handleSize / 2,
                    y: center.y - handleSize / 2,
                    width: handleSize,
                    height: handleSize
                )
            )
        })
    }

    /// Returns a toolbar origin outside the selection whenever one of the four
    /// surrounding placements fits. The fallback stays completely on-screen.
    static func toolbarOrigin(
        selection: CGRect,
        toolbarSize: CGSize,
        in bounds: CGRect,
        padding: CGFloat
    ) -> CGPoint {
        let centeredX = selection.midX - toolbarSize.width / 2
        let centeredY = selection.midY - toolbarSize.height / 2
        let candidates = [
            CGPoint(x: centeredX, y: selection.minY - padding - toolbarSize.height),
            CGPoint(x: centeredX, y: selection.maxY + padding),
            CGPoint(x: selection.maxX + padding, y: centeredY),
            CGPoint(x: selection.minX - padding - toolbarSize.width, y: centeredY),
        ]

        for candidate in candidates {
            let frame = CGRect(origin: candidate, size: toolbarSize)
            if bounds.contains(frame), !frame.intersects(selection) {
                return candidate
            }
        }

        return CGPoint(
            x: min(max(centeredX, bounds.minX), bounds.maxX - toolbarSize.width),
            y: min(max(selection.minY + padding, bounds.minY), bounds.maxY - toolbarSize.height)
        )
    }

    /// Returns the physical-pixel extent covered by a point rectangle. Each
    /// dimension is even so the selection UI reports the same H.264-safe size
    /// that capture preparation will use.
    static func pixelSize(for rectangle: CGRect, scaleFactor: CGFloat) -> CGSize {
        guard scaleFactor.isFinite, scaleFactor > 0,
              hasFiniteComponents(rectangle),
              rectangle.width > 0,
              rectangle.height > 0 else {
            return .zero
        }

        let standardized = rectangle.standardized
        return CGSize(
            width: CGFloat(evenCoveredPixelCount(
                minimum: standardized.minX * scaleFactor,
                maximum: standardized.maxX * scaleFactor
            )),
            height: CGFloat(evenCoveredPixelCount(
                minimum: standardized.minY * scaleFactor,
                maximum: standardized.maxY * scaleFactor
            ))
        )
    }

    /// Snaps a ScreenCaptureKit source rectangle to the display's physical
    /// pixel grid and makes both dimensions even. The selected content is
    /// covered whenever the display bounds permit it; at an outer edge the
    /// interval grows toward the display interior instead.
    static func pixelAligned(
        _ rectangle: CGRect,
        in bounds: CGRect,
        scaleFactor: CGFloat
    ) -> PixelAlignedCaptureGeometry? {
        guard scaleFactor.isFinite, scaleFactor > 0,
              hasFiniteComponents(rectangle),
              hasFiniteComponents(bounds),
              bounds.width > 0,
              bounds.height > 0 else {
            return nil
        }

        let pixelWidthValue = bounds.width * scaleFactor
        let pixelHeightValue = bounds.height * scaleFactor
        guard pixelWidthValue.isFinite,
              pixelHeightValue.isFinite,
              pixelWidthValue <= CGFloat(Int.max - 1),
              pixelHeightValue <= CGFloat(Int.max - 1) else {
            return nil
        }
        let displayPixelWidth = Int(pixelWidthValue.rounded())
        let displayPixelHeight = Int(pixelHeightValue.rounded())
        guard displayPixelWidth >= 2, displayPixelHeight >= 2 else { return nil }

        let clipped = rectangle.standardized.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        guard let horizontal = evenPixelInterval(
            minimum: (clipped.minX - bounds.minX) * scaleFactor,
            maximum: (clipped.maxX - bounds.minX) * scaleFactor,
            limit: displayPixelWidth
        ), let vertical = evenPixelInterval(
            minimum: (clipped.minY - bounds.minY) * scaleFactor,
            maximum: (clipped.maxY - bounds.minY) * scaleFactor,
            limit: displayPixelHeight
        ) else {
            return nil
        }

        return PixelAlignedCaptureGeometry(
            sourceRectangle: CGRect(
                x: bounds.minX + CGFloat(horizontal.minimum) / scaleFactor,
                y: bounds.minY + CGFloat(vertical.minimum) / scaleFactor,
                width: CGFloat(horizontal.maximum - horizontal.minimum) / scaleFactor,
                height: CGFloat(vertical.maximum - vertical.minimum) / scaleFactor
            ),
            pixelWidth: horizontal.maximum - horizontal.minimum,
            pixelHeight: vertical.maximum - vertical.minimum
        )
    }

    private static func aspectRatioResize(
        _ original: CGRect,
        horizontal: CGFloat,
        vertical: CGFloat,
        delta: CGVector,
        bounds: CGRect,
        minimumSize: CGSize
    ) -> CGRect {
        guard original.height > 0 else { return original }

        let horizontalScale = horizontal == 0
            ? 1
            : max(0, (original.width + horizontal * delta.dx) / original.width)
        let verticalScale = vertical == 0
            ? 1
            : max(0, (original.height + vertical * delta.dy) / original.height)

        let proposedScale: CGFloat
        if horizontal == 0 {
            proposedScale = verticalScale
        } else if vertical == 0 {
            proposedScale = horizontalScale
        } else {
            proposedScale = abs(horizontalScale - 1) >= abs(verticalScale - 1)
                ? horizontalScale
                : verticalScale
        }

        let minimumScale = max(
            minimumSize.width / original.width,
            minimumSize.height / original.height
        )
        let maximumWidth = availableLength(
            minimum: bounds.minX,
            maximum: bounds.maxX,
            originalMinimum: original.minX,
            originalMaximum: original.maxX,
            direction: horizontal
        )
        let maximumHeight = availableLength(
            minimum: bounds.minY,
            maximum: bounds.maxY,
            originalMinimum: original.minY,
            originalMaximum: original.maxY,
            direction: vertical
        )
        let maximumScale = min(maximumWidth / original.width, maximumHeight / original.height)
        let scale = min(max(proposedScale, min(minimumScale, maximumScale)), maximumScale)
        let newSize = CGSize(width: original.width * scale, height: original.height * scale)

        let x: CGFloat
        if horizontal < 0 {
            x = original.maxX - newSize.width
        } else if horizontal > 0 {
            x = original.minX
        } else {
            x = original.midX - newSize.width / 2
        }

        let y: CGFloat
        if vertical < 0 {
            y = original.maxY - newSize.height
        } else if vertical > 0 {
            y = original.minY
        } else {
            y = original.midY - newSize.height / 2
        }

        return clamped(
            CGRect(origin: CGPoint(x: x, y: y), size: newSize),
            to: bounds,
            minimumSize: minimumSize
        )
    }

    private static func availableLength(
        minimum: CGFloat,
        maximum: CGFloat,
        originalMinimum: CGFloat,
        originalMaximum: CGFloat,
        direction: CGFloat
    ) -> CGFloat {
        if direction < 0 {
            return originalMaximum - minimum
        }
        if direction > 0 {
            return maximum - originalMinimum
        }
        let center = (originalMinimum + originalMaximum) / 2
        return 2 * min(center - minimum, maximum - center)
    }

    private static func hasFiniteComponents(_ rectangle: CGRect) -> Bool {
        rectangle.origin.x.isFinite
            && rectangle.origin.y.isFinite
            && rectangle.size.width.isFinite
            && rectangle.size.height.isFinite
    }

    private static func evenCoveredPixelCount(
        minimum: CGFloat,
        maximum: CGFloat
    ) -> Int {
        let lower = snappedPixelCoordinate(minimum).rounded(.down)
        let upper = snappedPixelCoordinate(maximum).rounded(.up)
        guard lower.isFinite,
              upper.isFinite,
              upper >= lower,
              upper - lower <= CGFloat(Int.max - 1) else {
            return 0
        }
        let covered = max(2, Int(upper - lower))
        return covered.isMultiple(of: 2) ? covered : covered + 1
    }

    private static func evenPixelInterval(
        minimum: CGFloat,
        maximum: CGFloat,
        limit: Int
    ) -> (minimum: Int, maximum: Int)? {
        guard minimum.isFinite, maximum.isFinite, maximum > minimum, limit >= 2 else {
            return nil
        }

        var lower = max(
            0,
            min(limit, Int(snappedPixelCoordinate(minimum).rounded(.down)))
        )
        var upper = max(
            0,
            min(limit, Int(snappedPixelCoordinate(maximum).rounded(.up)))
        )
        guard upper > lower else { return nil }

        if upper - lower < 2 {
            upper = min(limit, lower + 2)
            lower = max(0, upper - 2)
        }
        if !(upper - lower).isMultiple(of: 2) {
            if upper < limit {
                upper += 1
            } else if lower > 0 {
                lower -= 1
            } else {
                // An odd-sized display cannot contain an even interval that
                // covers both outer edges. Keep the top/left edge stable and
                // crop the final physical pixel rather than scaling it.
                upper -= 1
            }
        }

        guard upper - lower >= 2, (upper - lower).isMultiple(of: 2) else {
            return nil
        }
        return (lower, upper)
    }

    private static func snappedPixelCoordinate(_ value: CGFloat) -> CGFloat {
        let nearest = value.rounded()
        return abs(value - nearest) < 0.000_000_1 ? nearest : value
    }
}
