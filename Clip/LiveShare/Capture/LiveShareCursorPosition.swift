import CoreGraphics
import Foundation

struct LiveShareCursorPosition: Equatable, Sendable {
    let xPercent: Double
    let yPercent: Double
    let isInView: Bool
}

enum LiveShareCursorNormalization {
    static func position(
        appKitCursor: CGPoint,
        appKitWindowFrame: CGRect
    ) -> LiveShareCursorPosition {
        guard appKitWindowFrame.width > 0, appKitWindowFrame.height > 0 else {
            return LiveShareCursorPosition(xPercent: 0, yPercent: 0, isInView: false)
        }
        let isInView = appKitWindowFrame.contains(appKitCursor)
        let x = ((appKitCursor.x - appKitWindowFrame.minX) / appKitWindowFrame.width)
            .clamped(to: 0 ... 1)
        let y = ((appKitWindowFrame.maxY - appKitCursor.y) / appKitWindowFrame.height)
            .clamped(to: 0 ... 1)
        return LiveShareCursorPosition(
            xPercent: Double(x * 100),
            yPercent: Double(y * 100),
            isInView: isInView
        )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
