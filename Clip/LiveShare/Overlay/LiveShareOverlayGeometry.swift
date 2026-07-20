import AppKit

enum LiveShareOverlayAnchorSide: String, CaseIterable, Equatable, Sendable {
    case left
    case right

    var opposite: Self { self == .left ? .right : .left }
}

struct LiveShareOverlayAnchorMemory: Equatable, Sendable {
    private var sideBySourceID: [String: LiveShareOverlayAnchorSide] = [:]

    func side(for sourceID: String) -> LiveShareOverlayAnchorSide {
        sideBySourceID[sourceID] ?? .left
    }

    @discardableResult
    mutating func toggle(for sourceID: String) -> LiveShareOverlayAnchorSide {
        let next = side(for: sourceID).opposite
        sideBySourceID[sourceID] = next
        return next
    }

    mutating func reset() {
        sideBySourceID.removeAll(keepingCapacity: false)
    }
}

enum LiveShareOverlayGeometry {
    static let focusedControlSize = CGSize(width: 130, height: 32)
    static let focusedControlInset: CGFloat = 16
    static let hudInset: CGFloat = 12

    static func focusedControlFrame(
        targetWindowFrame: CGRect,
        visibleScreenFrame: CGRect,
        side: LiveShareOverlayAnchorSide,
        size: CGSize = focusedControlSize,
        inset: CGFloat = focusedControlInset
    ) -> CGRect {
        let target = targetWindowFrame.standardized
        let screen = visibleScreenFrame.standardized
        let intendedX: CGFloat
        switch side {
        case .left:
            intendedX = target.minX + inset
        case .right:
            intendedX = target.maxX - inset - size.width
        }
        let intendedY = target.minY + inset

        return CGRect(
            origin: CGPoint(
                x: clampedOrigin(intendedX, length: size.width, in: screen.minX...screen.maxX),
                y: clampedOrigin(intendedY, length: size.height, in: screen.minY...screen.maxY)
            ),
            size: size
        )
    }

    static func topRightHUDFrame(
        visibleScreenFrame: CGRect,
        size: CGSize,
        inset: CGFloat = hudInset
    ) -> CGRect {
        let screen = visibleScreenFrame.standardized
        return CGRect(
            origin: CGPoint(
                x: clampedOrigin(
                    screen.maxX - inset - size.width,
                    length: size.width,
                    in: screen.minX...screen.maxX
                ),
                y: clampedOrigin(
                    screen.maxY - inset - size.height,
                    length: size.height,
                    in: screen.minY...screen.maxY
                )
            ),
            size: size
        )
    }

    private static func clampedOrigin(
        _ value: CGFloat,
        length: CGFloat,
        in limits: ClosedRange<CGFloat>
    ) -> CGFloat {
        let maximum = max(limits.lowerBound, limits.upperBound - max(0, length))
        return min(max(value, limits.lowerBound), maximum)
    }
}
