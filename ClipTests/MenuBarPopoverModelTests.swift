import AppKit
import ClipCore
import ClipLiveShare
import CoreGraphics
import SwiftUI
import XCTest
@testable import Clip

@MainActor
final class MenuBarPopoverModelTests: XCTestCase {
    func testNativeV3InviteEntryAcceptsOnlyCompleteV3Invites() throws {
        let invite = try makeNativeV3Invite()
        let inviteURL = try invite.url.absoluteString

        XCTAssertEqual(
            MenuBarNativeV3InviteEntry.parse(" \n\(inviteURL)\t"),
            invite
        )
        XCTAssertNil(MenuBarNativeV3InviteEntry.parse(""))
        XCTAssertNil(
            MenuBarNativeV3InviteEntry.parse(
                "https://mesh.example.test/#clip-native-v3=invalid"
            )
        )
    }

    func testNativeV3RoomActionsUseSeparateCreateAndJoinCallbacks() throws {
        let invite = try makeNativeV3Invite()
        var createCount = 0
        var joinRequest: MenuBarNativeV3JoinRequest?
        let actions = MenuBarActions(
            createNativeV3Room: { createCount += 1 },
            joinNativeV3Invite: { joinRequest = $0 },
            captureArea: {},
            lastArea: {},
            fullscreen: {},
            openHistory: {},
            openSettings: {},
            quit: {}
        )

        actions.createNativeV3Room()
        actions.joinNativeV3Invite(
            MenuBarNativeV3JoinRequest(
                invite: invite,
                accessWord: "  be-ta  "
            )
        )

        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(joinRequest?.invite, invite)
        XCTAssertEqual(joinRequest?.accessWord, "BE-TA")
        XCTAssertFalse(joinRequest?.description.contains("BE-TA") == true)
        XCTAssertFalse(
            joinRequest?.description.contains(
                try invite.url.absoluteString
            ) == true
        )
    }

    func testNativeV3JoinRequestDropsAnEmptyAccessWord() throws {
        let request = MenuBarNativeV3JoinRequest(
            invite: try makeNativeV3Invite(),
            accessWord: " \n "
        )

        XCTAssertNil(request.accessWord)
        XCTAssertTrue(request.description.contains("<none>"))
    }

    func testVersionDisplayUsesTheMarketingVersion() {
        XCTAssertEqual(
            MenuBarApplicationVersion.displayString(
                infoDictionary: ["CFBundleShortVersionString": "1.2.3"]
            ),
            "v1.2.3"
        )
    }

    private func makeNativeV3Invite()
        throws -> ClipLiveShareNativeV3Invite {
        let signer = try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(repeating: 0x66, count: 32)
        )
        return try ClipLiveShareNativeV3Invite(
            endpoint: URL(string: "https://mesh.example.test")!,
            rendezvousID: .init(bytes: Data(repeating: 0x11, count: 32)),
            sessionID: .init(rawValue: "menu-native-v3-room"),
            foundingCreatorIdentity: signer.publicKey,
            leaderParticipantID: .init(
                bytes: Data(repeating: 0x22, count: 16)
            ),
            leaderIdentity: signer.publicKey,
            leaderRendezvousPublicKey: ClipLiveShareNativeV3RendezvousIdentity().publicKey,
            admissionCapability: .init(
                bytes: Data(repeating: 0x44, count: 32)
            )
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
        let cursorRegion = ClipPopoverPointingHandCursorView(
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
        let window = NSWindow(
            contentRect: container.view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = container

        let idle = NSViewController()
        idle.view = NSView(frame: .zero)
        container.replaceContent(with: idle)

        XCTAssertTrue(container.view === stableRootView)
        XCTAssertTrue(container.currentContentViewController === idle)
        XCTAssertTrue(idle.parent === container)
        XCTAssertEqual(idle.view.frame, container.view.bounds)

        let liveShare = NSViewController()
        liveShare.view = NSView(frame: .zero)
        container.replaceContent(with: liveShare)
        container.view.frame.size = NSSize(
            width: ClipPopoverDesign.width,
            height: 620
        )
        container.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(container.view === stableRootView)
        XCTAssertTrue(container.currentContentViewController === liveShare)
        XCTAssertNil(idle.parent)
        XCTAssertTrue(liveShare.parent === container)
        XCTAssertTrue(liveShare.view.superview === container.view)
        XCTAssertEqual(liveShare.view.frame, container.view.bounds)

        let recording = NSViewController()
        recording.view = NSView(frame: .zero)
        container.replaceContent(with: recording)
        container.view.frame.size = RecordingStatusView.contentSize
        container.view.layoutSubtreeIfNeeded()

        XCTAssertNil(liveShare.parent)
        XCTAssertTrue(recording.parent === container)
        XCTAssertEqual(container.view.subviews.count, 1)
        XCTAssertTrue(container.view.subviews.first === recording.view)
        XCTAssertEqual(recording.view.frame, container.view.bounds)

        let nextIdle = NSViewController()
        nextIdle.view = NSView(frame: .zero)
        container.replaceContent(with: nextIdle)
        container.view.frame.size = MenuBarPopoverView.contentSize
        container.view.layoutSubtreeIfNeeded()

        XCTAssertNil(recording.parent)
        XCTAssertTrue(nextIdle.parent === container)
        XCTAssertEqual(container.view.subviews.count, 1)
        XCTAssertTrue(container.view.subviews.first === nextIdle.view)
        XCTAssertEqual(nextIdle.view.frame, container.view.bounds)
    }

    func testPopoverViewsShareTheDesignWidthAndRetainFallbackHeights() {
        XCTAssertEqual(MenuBarPopoverView.contentSize.width, ClipPopoverDesign.width)
        XCTAssertEqual(MenuBarPopoverView.contentSize.height, 980)
        XCTAssertEqual(RecordingStatusView.contentSize.width, ClipPopoverDesign.width)
        XCTAssertEqual(RecordingStatusView.contentSize.height, 360)
    }

    func testSharedPopoverButtonSizesMatchTheVisualHierarchy() {
        XCTAssertEqual(ClipPopoverButtonSize.standard.height, 28)
        XCTAssertEqual(ClipPopoverButtonSize.bottom.height, 36)
    }

    func testPopoverSizingPolicyPreservesWidthAndCapsHeightToTheVisibleScreen() {
        let maximumHeight = PopoverSizingPolicy.maximumContentHeight(
            visibleScreenHeight: 956
        )

        XCTAssertEqual(maximumHeight, 940)
        XCTAssertEqual(
            PopoverSizingPolicy.contentSize(
                width: 330,
                idealHeight: 481.2,
                maximumHeight: maximumHeight
            ),
            NSSize(width: 330, height: 482)
        )
        XCTAssertEqual(
            PopoverSizingPolicy.contentSize(
                width: 330,
                idealHeight: 1_200,
                maximumHeight: maximumHeight
            ),
            NSSize(width: 330, height: 940)
        )
    }

    func testFluidPopoverReportsTheIdleMenuNaturalHeight() {
        let reported = expectation(description: "Natural menu height reported")
        var reportedHeight: CGFloat?
        let model = MenuBarPopoverModel(
            displays: [display(id: 1, name: "Studio Display", width: 5_120, height: 2_880)],
            microphone: .init(),
            systemAudio: .init(),
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
                ),
                maximumHeight: 940,
                onContentHeightChange: { height in
                    guard reportedHeight == nil else { return }
                    reportedHeight = height
                    reported.fulfill()
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: MenuBarPopoverView.contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        let fittedHeight = ceil(controller.view.fittingSize.height)
        XCTAssertEqual(XCTWaiter.wait(for: [reported], timeout: 1), .completed)
        XCTAssertNotNil(reportedHeight)
        XCTAssertLessThan(fittedHeight, MenuBarPopoverView.contentSize.height)
        XCTAssertLessThan(reportedHeight ?? .infinity, MenuBarPopoverView.contentSize.height)
        // NSScrollView's fitting height and its document geometry can differ by
        // one small AppKit layout inset; they must still describe the same
        // compact layout rather than the fallback viewport.
        XCTAssertEqual(fittedHeight, reportedHeight ?? 0, accuracy: 16)
    }

    func testIdleMenuNaturalHeightCanGrowFromRecordingSizedViewport() {
        let reported = expectation(description: "Idle menu grows beyond recording viewport")
        var reportedHeight: CGFloat?
        let model = MenuBarPopoverModel(
            displays: [display(id: 1, name: "Studio Display", width: 5_120, height: 2_880)],
            microphone: .init(),
            systemAudio: .init(),
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
                ),
                maximumHeight: 940,
                onContentHeightChange: { height in
                    guard reportedHeight == nil,
                          height > RecordingStatusView.contentSize.height else {
                        return
                    }
                    reportedHeight = height
                    reported.fulfill()
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(
                    width: MenuBarPopoverView.contentWidth,
                    height: RecordingStatusView.contentSize.height
                )
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        let fittedHeight = ceil(controller.view.fittingSize.height)
        XCTAssertGreaterThan(fittedHeight, RecordingStatusView.contentSize.height)
        XCTAssertLessThan(fittedHeight, MenuBarPopoverView.contentSize.height)
        XCTAssertEqual(XCTWaiter.wait(for: [reported], timeout: 1), .completed)
        XCTAssertGreaterThan(
            reportedHeight ?? 0,
            RecordingStatusView.contentSize.height
        )
        XCTAssertEqual(fittedHeight, reportedHeight ?? 0, accuracy: 16)
    }

    func testFluidPopoverReportsTheRecordingControlsNaturalHeight() {
        let reported = expectation(description: "Natural recording height reported")
        var reportedHeight: CGFloat?
        let controller = NSHostingController(
            rootView: RecordingStatusView(
                model: .demo(.demoRecording),
                maximumHeight: 940,
                onContentHeightChange: { height in
                    guard reportedHeight == nil else { return }
                    reportedHeight = height
                    reported.fulfill()
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: RecordingStatusView.contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        let fittedHeight = ceil(controller.view.fittingSize.height)
        XCTAssertEqual(XCTWaiter.wait(for: [reported], timeout: 1), .completed)
        XCTAssertNotNil(reportedHeight)
        XCTAssertLessThan(fittedHeight, RecordingStatusView.contentSize.height)
        XCTAssertLessThan(reportedHeight ?? .infinity, RecordingStatusView.contentSize.height)
        XCTAssertEqual(fittedHeight, reportedHeight ?? 0, accuracy: 1)
    }

    func testAudioExclusionSummaryShowsNoneAppNameAndCount() {
        let discord = LiveShareAudioApplicationViewSnapshot(
            id: "com.hnc.Discord",
            name: "Discord",
            bundleIdentifier: "com.hnc.Discord"
        )
        let music = LiveShareAudioApplicationViewSnapshot(
            id: "com.apple.Music",
            name: "Music",
            bundleIdentifier: "com.apple.Music"
        )

        XCTAssertEqual(
            LiveShareSettingsViewSnapshot().audioExclusionSummary,
            "None"
        )
        XCTAssertEqual(
            LiveShareSettingsViewSnapshot(
                audioExclusionApplications: [discord, music],
                excludedAudioApplicationIDs: [discord.id]
            ).audioExclusionSummary,
            "Discord"
        )
        XCTAssertEqual(
            LiveShareSettingsViewSnapshot(
                audioExclusionApplications: [discord, music],
                excludedAudioApplicationIDs: [discord.id, music.id]
            ).audioExclusionSummary,
            "2 Apps"
        )
        XCTAssertEqual(
            LiveShareSettingsViewSnapshot(
                excludedAudioApplicationIDs: ["com.example.Unavailable"]
            ).audioExclusionSummary,
            "1 App"
        )
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
