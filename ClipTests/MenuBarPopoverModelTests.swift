import AppKit
import ClipCore
import CoreGraphics
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
