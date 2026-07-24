import AppKit
import ClipCore
import CoreGraphics
import SwiftUI
import XCTest
@testable import Clip

@MainActor
final class MenuBarPopoverModelTests: XCTestCase {
    func testVersionDisplayUsesTheMarketingVersion() {
        XCTAssertEqual(
            MenuBarApplicationVersion.displayString(
                infoDictionary: ["CFBundleShortVersionString": "1.2.3"]
            ),
            "v1.2.3"
        )
    }

    func testVersionDisplayRejectsMissingOrEmptyVersions() {
        XCTAssertNil(MenuBarApplicationVersion.displayString(infoDictionary: [:]))
        XCTAssertNil(
            MenuBarApplicationVersion.displayString(
                infoDictionary: ["CFBundleShortVersionString": "   "]
            )
        )
    }

    func testDisplayRefreshRemovesStalePreparedTarget() {
        let first = display(id: 1, name: "Main", width: 3_456, height: 2_234)
        let second = display(id: 2, name: "External", width: 2_560, height: 1_440)
        let model = MenuBarPopoverModel(
            displays: [first, second],
            preparedDisplayID: second.id
        )

        XCTAssertEqual(model.preparedDisplay, second)
        model.replaceDisplays([first])
        XCTAssertNil(model.preparedDisplay)
        XCTAssertTrue(model.isFullscreenAvailable)

        model.replaceDisplays([])
        XCTAssertFalse(model.isFullscreenAvailable)
    }

    func testOnlyAvailableDisplaysCanBecomePreparedTarget() {
        let first = display(id: 11, name: "Main", width: 1_920, height: 1_080)
        let model = MenuBarPopoverModel(displays: [first])

        model.prepareDisplay(id: 99)
        XCTAssertNil(model.preparedDisplayID)

        model.prepareDisplay(id: first.id)
        XCTAssertEqual(model.preparedDisplayID, first.id)
    }

    func testUnavailableAudioCannotBeEnabled() {
        let model = MenuBarPopoverModel(
            microphone: .init(isEnabled: true, isAvailable: false),
            systemAudio: .init(isAvailable: false)
        )

        model.setMicrophoneEnabled(true)
        model.setSystemAudioEnabled(true)

        XCTAssertFalse(model.microphone.isEnabled)
        XCTAssertFalse(model.systemAudio.isEnabled)
        XCTAssertEqual(model.microphone.status, "Unavailable")
    }

    func testClickHighlightsDefaultOffAndToggleIndependently() {
        let model = MenuBarPopoverModel(
            microphone: .init(isAvailable: false),
            systemAudio: .init(isAvailable: false)
        )

        XCTAssertFalse(model.showClickHighlights)
        model.setClickHighlightsEnabled(true)
        XCTAssertTrue(model.showClickHighlights)
        XCTAssertFalse(model.microphone.isEnabled)
        XCTAssertFalse(model.systemAudio.isEnabled)
    }

    func testRecentRecordingRowsAreBoundedAndPreserveRepositoryOrder() {
        let rows = (0..<5).map { index in
            MenuBarRecentRecordingRow(
                id: RecordingID(),
                filename: "clip-\(index)",
                byteCount: Int64(index) * 1_000_000
            )
        }
        let model = MenuBarPopoverModel(recentRecordings: rows)

        XCTAssertEqual(
            model.recentRecordings.map(\.filename),
            ["clip-0", "clip-1", "clip-2"]
        )

        model.replaceRecentRecordings(Array(rows.reversed()))
        XCTAssertEqual(
            model.recentRecordings.map(\.filename),
            ["clip-4", "clip-3", "clip-2"]
        )
    }

    func testEnglishFileSizeLabelsAreDeterministic() {
        XCTAssertEqual(MenuBarFormatting.byteCount(0), "0 B")
        XCTAssertEqual(MenuBarFormatting.byteCount(999), "999 B")
        XCTAssertEqual(MenuBarFormatting.byteCount(2_400_000), "2.4 MB")
        XCTAssertEqual(MenuBarFormatting.byteCount(12_000_000), "12 MB")
        XCTAssertEqual(MenuBarFormatting.byteCount(-1), "0 B")
    }

    func testCursorRegionIsBalancedAndNeverInterceptsMenuControls() {
        let cursorRegion = MenuPointingHandCursorView(
            frame: NSRect(x: 0, y: 0, width: 120, height: 28)
        )

        XCTAssertTrue(cursorRegion.registeredCursor === NSCursor.pointingHand)
        XCTAssertNil(cursorRegion.hitTest(NSPoint(x: 20, y: 12)))

        cursorRegion.isEnabled = false

        XCTAssertNil(cursorRegion.registeredCursor)
        XCTAssertNil(cursorRegion.hitTest(NSPoint(x: 20, y: 12)))
    }

    func testPopoverContentReplacementKeepsOneStableRootController() {
        let container = PopoverContentContainerViewController()
        container.loadView()
        container.view.frame = NSRect(origin: .zero, size: MenuBarPopoverView.contentSize)
        let stableRootView = container.view

        let idle = NSViewController()
        idle.view = NSView(frame: .zero)
        container.replaceContent(with: idle, animated: false)

        XCTAssertTrue(container.view === stableRootView)
        XCTAssertTrue(container.currentContentViewController === idle)
        XCTAssertTrue(idle.parent === container)
        XCTAssertEqual(idle.view.frame, container.view.bounds)

        let liveShare = NSViewController()
        liveShare.view = NSView(frame: .zero)
        container.view.frame.size = LiveSharePopoverView.contentSize
        container.replaceContent(with: liveShare, animated: false)

        XCTAssertTrue(container.view === stableRootView)
        XCTAssertTrue(container.currentContentViewController === liveShare)
        XCTAssertNil(idle.parent)
        XCTAssertTrue(liveShare.parent === container)
        XCTAssertTrue(liveShare.view.superview === container.view)
        XCTAssertEqual(liveShare.view.frame, container.view.bounds)
    }

    func testIdleMenuContentSizeShowsTheWholeMenu() {
        XCTAssertEqual(MenuBarPopoverView.contentSize.width, 330)
        XCTAssertEqual(MenuBarPopoverView.contentSize.height, 620)

        let model = MenuBarPopoverModel(
            displays: [display(id: 1, name: "Studio Display", width: 5_120, height: 2_880)],
            microphone: .init(),
            systemAudio: .init(),
            showClickHighlights: true,
            recentRecordings: (0..<MenuBarPopoverModel.recentRecordingLimit).map { index in
                MenuBarRecentRecordingRow(
                    id: RecordingID(),
                    filename: "clip-\(index)",
                    byteCount: Int64(index + 1) * 1_000_000
                )
            },
            isLastAreaAvailable: true,
            isFullscreenAvailable: true
        )
        let controller = NSHostingController(
            rootView: MenuBarPopoverView(
                model: model,
                actions: MenuBarActions(
                    captureArea: {},
                    lastArea: {},
                    fullscreen: {},
                    openHistory: {},
                    openSettings: {},
                    quit: {}
                )
            )
        )
        let fittingSize = controller.sizeThatFits(
            in: NSSize(width: MenuBarPopoverView.contentSize.width, height: 10_000)
        )

        XCTAssertGreaterThan(fittingSize.height, 360)
        XCTAssertLessThanOrEqual(fittingSize.height, MenuBarPopoverView.contentSize.height)
    }

    private func display(
        id: CGDirectDisplayID,
        name: String,
        width: Int,
        height: Int
    ) -> MenuBarDisplayRow {
        MenuBarDisplayRow(
            id: id,
            name: name,
            pixelWidth: width,
            pixelHeight: height
        )
    }
}
