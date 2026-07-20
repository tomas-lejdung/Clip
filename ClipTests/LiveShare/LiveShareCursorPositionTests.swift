import CoreGraphics
import Testing
@testable import Clip

@Suite("Live Share cursor normalization")
struct LiveShareCursorPositionTests {
    @Test("AppKit cursor is normalized to viewer top-left percentages")
    func inside() {
        let position = LiveShareCursorNormalization.position(
            appKitCursor: CGPoint(x: 300, y: 400),
            appKitWindowFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        #expect(position == LiveShareCursorPosition(
            xPercent: 25,
            yPercent: 50,
            isInView: true
        ))
    }

    @Test("outside coordinates clamp but remain marked outside")
    func outside() {
        let position = LiveShareCursorNormalization.position(
            appKitCursor: CGPoint(x: -20, y: 900),
            appKitWindowFrame: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        #expect(position.xPercent == 0)
        #expect(position.yPercent == 0)
        #expect(!position.isInView)
    }
}
