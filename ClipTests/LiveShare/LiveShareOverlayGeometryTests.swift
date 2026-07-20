import CoreGraphics
import Testing
@testable import Clip

@Suite("Live Share overlay geometry")
struct LiveShareOverlayGeometryTests {
    @Test
    func testOnlyExplicitAnchorToggleAnimatesFocusedWindowControl() {
        #expect(!FocusedWindowShareOverlayMovement.targetRefresh.isAnimated)
        #expect(FocusedWindowShareOverlayMovement.anchorToggle.isAnimated)
    }

    @Test
    func testFocusedControlUsesLowerLeftAndLowerRightAnchors() {
        let target = CGRect(x: 100, y: 200, width: 800, height: 600)
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        #expect(
            LiveShareOverlayGeometry.focusedControlFrame(
                targetWindowFrame: target,
                visibleScreenFrame: screen,
                side: .left
            ) == CGRect(x: 116, y: 216, width: 130, height: 32)
        )
        #expect(
            LiveShareOverlayGeometry.focusedControlFrame(
                targetWindowFrame: target,
                visibleScreenFrame: screen,
                side: .right
            ) == CGRect(x: 754, y: 216, width: 130, height: 32)
        )
    }

    @Test
    func testAnchorSideIsRetainedPerWindowAndResetsWithSession() {
        var memory = LiveShareOverlayAnchorMemory()

        #expect(memory.side(for: "window-1") == .left)
        #expect(memory.toggle(for: "window-1") == .right)
        #expect(memory.side(for: "window-1") == .right)
        #expect(memory.side(for: "window-2") == .left)

        memory.reset()
        #expect(memory.side(for: "window-1") == .left)
    }

    @Test
    func testFocusedControlClampsToActualSecondaryDisplay() {
        let target = CGRect(x: -1_900, y: -40, width: 220, height: 160)
        let secondaryScreen = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_057)

        let frame = LiveShareOverlayGeometry.focusedControlFrame(
            targetWindowFrame: target,
            visibleScreenFrame: secondaryScreen,
            side: .left
        )

        #expect(frame.origin.x == -1_884)
        #expect(frame.origin.y == 0)
        #expect(secondaryScreen.contains(frame))
    }

    @Test
    func testFocusedControlClampsWhenWindowExtendsPastRightEdge() {
        let frame = LiveShareOverlayGeometry.focusedControlFrame(
            targetWindowFrame: CGRect(x: 900, y: 100, width: 300, height: 300),
            visibleScreenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 700),
            side: .right
        )

        #expect(frame == CGRect(x: 870, y: 116, width: 130, height: 32))
    }

    @Test
    func testHUDAnchorsBelowTopRightVisibleFrame() {
        let frame = LiveShareOverlayGeometry.topRightHUDFrame(
            visibleScreenFrame: CGRect(x: 1_440, y: 23, width: 2_560, height: 1_417),
            size: CGSize(width: 190, height: 96)
        )

        #expect(frame == CGRect(x: 3_798, y: 1_332, width: 190, height: 96))
    }

    @Test
    func testHUDSnapshotAlwaysHasFourDotsAndCountsOnlyNonEmptyMedia() {
        let idle = LiveShareStatusHUDSnapshot(
            slots: [],
            connectedViewerCount: 0,
            fullscreen: .init(isOn: false, displayName: "Main")
        )
        let snapshot = LiveShareStatusHUDSnapshot(
            slots: [.init(index: 1, state: .live)],
            connectedViewerCount: -2,
            fullscreen: .init(isOn: false, displayName: "Main")
        )

        #expect(snapshot.slots.map(\.state) == [.empty, .live, .empty, .empty])
        #expect(snapshot.connectedViewerCount == 0)
        #expect(snapshot.hasActiveMedia)
        #expect(idle.contentSize == snapshot.contentSize)
        #expect(snapshot.contentSize == CGSize(width: 190, height: 66))
    }

    @Test
    func testFullscreenOwnsFirstDotAndClearsEveryWindowDot() {
        let snapshot = LiveShareStatusHUDSnapshot(
            slots: [
                .init(index: 0, state: .live),
                .init(index: 1, state: .live),
                .init(index: 2, state: .starting),
            ],
            connectedViewerCount: 1,
            fullscreen: .init(isOn: true, displayName: "Main")
        )

        #expect(snapshot.slots.map(\.state) == [.live, .empty, .empty, .empty])
    }

    @Test
    func testHUDMakesSustainedCapturePressureVisible() {
        let snapshot = LiveShareStatusHUDSnapshot(
            slots: [.init(index: 0, state: .live)],
            connectedViewerCount: 1,
            fullscreen: .init(isOn: false, displayName: "Main"),
            hasCapturePressureWarning: true
        )

        #expect(snapshot.hasCapturePressureWarning)
        #expect(snapshot.contentSize == CGSize(width: 190, height: 90))
    }
}
