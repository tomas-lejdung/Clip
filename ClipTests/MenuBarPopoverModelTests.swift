import AppKit
import ClipCore
import ClipLiveShare
import CoreGraphics
import SwiftUI
import XCTest
@testable import Clip

@MainActor
final class MenuBarPopoverModelTests: XCTestCase {
    func testServerRoomInviteEntryAcceptsOnlyCompleteV4Invites() throws {
        let invite = try makeServerRoomInvite()
        let inviteURL = try invite.url.absoluteString

        XCTAssertEqual(
            MenuBarServerRoomInviteEntry.parse(" \n\(inviteURL)\t"),
            invite
        )
        XCTAssertNil(MenuBarServerRoomInviteEntry.parse(""))
        XCTAssertNil(
            MenuBarServerRoomInviteEntry.parse(
                "https://mesh.example.test/#clip-native-v3=invalid"
            )
        )
    }

    func testServerRoomActionsUseSeparateCreateAndJoinCallbacks() throws {
        let invite = try makeServerRoomInvite()
        var createCount = 0
        var joinRequest: MenuBarServerRoomJoinRequest?
        let actions = MenuBarActions(
            createLiveShareRoom: { createCount += 1 },
            joinLiveShareInvite: { joinRequest = $0 },
            captureArea: {},
            lastArea: {},
            fullscreen: {},
            openHistory: {},
            openSettings: {},
            quit: {}
        )

        actions.createLiveShareRoom()
        actions.joinLiveShareInvite(
            MenuBarServerRoomJoinRequest(
                invite: invite,
                accessWord: "  be-ta  "
            )
        )

        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(joinRequest?.invite, invite)
        XCTAssertEqual(joinRequest?.accessWord, "BE-TA")
        XCTAssertEqual(joinRequest?.requiresCreatorApproval, false)
        XCTAssertFalse(joinRequest?.description.contains("BE-TA") == true)
        XCTAssertFalse(
            joinRequest?.description.contains(
                try invite.url.absoluteString
            ) == true
        )
    }

    func testServerRoomJoinRequestDropsAnEmptyAccessWord() throws {
        let request = MenuBarServerRoomJoinRequest(
            invite: try makeServerRoomInvite(),
            accessWord: " \n "
        )

        XCTAssertNil(request.accessWord)
        XCTAssertTrue(request.description.contains("<none>"))
    }

    func testSavedFriendJoinRequiresCreatorApproval() throws {
        let request = MenuBarServerRoomJoinRequest(
            invite: try makeServerRoomInvite(),
            accessWord: nil,
            requiresCreatorApproval: true
        )

        XCTAssertTrue(request.requiresCreatorApproval)
        XCTAssertTrue(
            request.description.contains("requiresCreatorApproval: true")
        )
    }

    func testLiveShareFriendsSortOnlineFirstThenByName() {
        let model = MenuBarPopoverModel()
        model.replaceLiveShareFriends([
            .init(
                id: "offline",
                displayName: "Alex",
                deviceName: "Mac A",
                isOnline: false
            ),
            .init(
                id: "zoe",
                displayName: "Zoe",
                deviceName: "Mac Z",
                isOnline: true
            ),
            .init(
                id: "ben",
                displayName: "Ben",
                deviceName: "Mac B",
                isOnline: true
            ),
        ])

        XCTAssertEqual(
            model.liveShareFriends.map(\.id),
            ["ben", "zoe", "offline"]
        )
        XCTAssertEqual(model.liveShareFriends[0].status, "Room Available")
        XCTAssertEqual(model.liveShareFriends[2].status, "No Room")
    }

    func testFriendPresenceRowsExposeVerifiedAvailabilityAndIssues() throws {
        let identity = try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(repeating: 0x77, count: 32)
        ).publicKey
        let snapshot = MeshFriendPresenceControllerSnapshot(friends: [
            MeshFriendPresenceSnapshot(
                id: "online",
                identity: identity,
                displayName: "Alex",
                deviceName: "Studio Mac",
                availability: .online,
                verifiedInvite: try makeServerRoomInvite(),
                lastSeenAt: Date(timeIntervalSince1970: 100),
                lastCheckedAt: Date(timeIntervalSince1970: 101),
                retryAfter: nil,
                issue: nil
            ),
            MeshFriendPresenceSnapshot(
                id: "offline",
                identity: identity,
                displayName: "Ben",
                deviceName: "MacBook",
                availability: .offline,
                verifiedInvite: nil,
                lastSeenAt: nil,
                lastCheckedAt: Date(timeIntervalSince1970: 102),
                retryAfter: Date(timeIntervalSince1970: 110),
                issue: "Presence expired."
            ),
        ])

        let rows = MenuBarFriendPresencePolicy.rows(from: snapshot)

        XCTAssertEqual(rows.map(\.id), ["online", "offline"])
        XCTAssertTrue(rows[0].isOnline)
        XCTAssertEqual(rows[0].status, "Room Available")
        XCTAssertFalse(rows[1].isOnline)
        XCTAssertEqual(rows[1].status, "No Room")
        XCTAssertEqual(rows[1].issue, "Presence expired.")
    }

    func testSavedFriendJoinAcceptsOnlyVerifiedOnlinePresence() throws {
        let identity = try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(repeating: 0x78, count: 32)
        ).publicKey
        let invite = try makeServerRoomInvite()
        let snapshot = MeshFriendPresenceControllerSnapshot(friends: [
            MeshFriendPresenceSnapshot(
                id: "online",
                identity: identity,
                displayName: "Alex",
                deviceName: "Studio Mac",
                availability: .online,
                verifiedInvite: invite,
                lastSeenAt: Date(timeIntervalSince1970: 100),
                lastCheckedAt: Date(timeIntervalSince1970: 101),
                retryAfter: nil,
                issue: nil
            ),
            MeshFriendPresenceSnapshot(
                id: "offline-with-stale-invite",
                identity: identity,
                displayName: "Ben",
                deviceName: "MacBook",
                availability: .offline,
                verifiedInvite: invite,
                lastSeenAt: Date(timeIntervalSince1970: 90),
                lastCheckedAt: Date(timeIntervalSince1970: 101),
                retryAfter: nil,
                issue: nil
            ),
            MeshFriendPresenceSnapshot(
                id: "online-without-invite",
                identity: identity,
                displayName: "Casey",
                deviceName: "Mac mini",
                availability: .online,
                verifiedInvite: nil,
                lastSeenAt: Date(timeIntervalSince1970: 100),
                lastCheckedAt: Date(timeIntervalSince1970: 101),
                retryAfter: nil,
                issue: "Presence could not be verified."
            ),
        ])

        let request = MenuBarFriendPresencePolicy.verifiedJoinRequest(
            friendID: "online",
            snapshot: snapshot
        )

        XCTAssertEqual(request?.invite, invite)
        XCTAssertNil(request?.accessWord)
        XCTAssertEqual(request?.requiresCreatorApproval, true)
        XCTAssertNil(
            MenuBarFriendPresencePolicy.verifiedJoinRequest(
                friendID: "offline-with-stale-invite",
                snapshot: snapshot
            )
        )
        XCTAssertNil(
            MenuBarFriendPresencePolicy.verifiedJoinRequest(
                friendID: "online-without-invite",
                snapshot: snapshot
            )
        )
        XCTAssertNil(
            MenuBarFriendPresencePolicy.verifiedJoinRequest(
                friendID: "missing",
                snapshot: snapshot
            )
        )
    }

    func testServerRoomAccessWordMatchesV4NormalizationAndBounds() {
        XCTAssertEqual(
            MenuBarServerRoomAccessWord.normalize("  be-ta  "),
            "BE-TA"
        )
        XCTAssertNil(MenuBarServerRoomAccessWord.normalize(" \n "))
        XCTAssertNil(
            MenuBarServerRoomAccessWord.normalize(
                String(repeating: "a", count: 257)
            )
        )
    }

    func testLiveShareConnectionStatusExplainsManualApproval() throws {
        let model = MenuBarPopoverModel()

        model.setLiveShareConnectionStatus(
            .awaitingApproval(roomName: "Room ABCD1234")
        )

        XCTAssertEqual(
            model.liveShareConnectionStatus.title,
            "Waiting for Approval"
        )
        XCTAssertEqual(
            model.liveShareConnectionStatus.detail,
            "The room creator of Room ABCD1234 must allow you before you can join."
        )
        XCTAssertEqual(
            model.liveShareConnectionStatus.paneContent,
            .connection
        )
    }

    func testFriendJoinPresentationWaitsForApprovalThenShowsRoom() {
        XCTAssertEqual(
            ServerMeshJoinPresentationPolicy.transition(
                for: .connecting,
                roomName: "Room ABCD1234"
            ),
            .unchanged
        )
        XCTAssertEqual(
            ServerMeshJoinPresentationPolicy.transition(
                for: .waitingForAdmission,
                roomName: "Room ABCD1234"
            ),
            .awaitingApproval(roomName: "Room ABCD1234")
        )
        XCTAssertEqual(
            ServerMeshJoinPresentationPolicy.transition(
                for: .active,
                roomName: "Room ABCD1234"
            ),
            .showActiveRoom
        )
    }

    func testAccessWordRequirementKeepsAuthenticatedInviteReachable() throws {
        let invite = try makeServerRoomInvite()
        let status = MenuBarLiveShareConnectionStatus
            .accessWordRequired(
                roomName: "Room ABCD1234",
                invite: invite,
                requiresCreatorApproval: true
            )
        let model = MenuBarPopoverModel()

        model.setLiveShareConnectionStatus(status)

        XCTAssertEqual(status.paneContent, .accessWord)
        XCTAssertEqual(status.accessWordInvite, invite)
        XCTAssertTrue(status.accessWordRequiresCreatorApproval)
        XCTAssertEqual(status.title, "Access Word Required")
        XCTAssertEqual(
            status.detail,
            "Enter the Access Word for Room ABCD1234 to continue."
        )
        XCTAssertEqual(
            model.liveShareConnectionStatus.accessWordInvite,
            invite
        )

        let retryRequest = MenuBarServerRoomJoinRequest(
            invite: try XCTUnwrap(status.accessWordInvite),
            accessWord: "  be-ta  ",
            requiresCreatorApproval:
                status.accessWordRequiresCreatorApproval
        )
        XCTAssertEqual(retryRequest.accessWord, "BE-TA")
        XCTAssertTrue(retryRequest.requiresCreatorApproval)
    }

    func testSavedFriendAccessWordJoinRequiresAnExplicitCreatorDecision()
        throws
    {
        var fixture = try makeSavedFriendRoom()
        let candidate = try makeSavedFriendCandidate(seed: 0x68)
        let friendPresence = MeshFriendPresenceControllerSnapshot(friends: [
            MeshFriendPresenceSnapshot(
                id: "verified-host",
                identity: fixture.hostIdentity,
                displayName: "Alex",
                deviceName: "Studio Mac",
                availability: .online,
                verifiedInvite: fixture.invite,
                lastSeenAt: Date(timeIntervalSince1970: 100),
                lastCheckedAt: Date(timeIntervalSince1970: 101),
                retryAfter: nil,
                issue: nil
            ),
        ])

        // This is the exact request produced when the person clicks a verified
        // online friend. The first attempt has no Access Word but must already
        // carry the friend-only creator-approval requirement.
        let initialRequest = try XCTUnwrap(
            MenuBarFriendPresencePolicy.verifiedJoinRequest(
                friendID: "verified-host",
                snapshot: friendPresence
            )
        )
        XCTAssertEqual(initialRequest.invite, fixture.invite)
        XCTAssertNil(initialRequest.accessWord)
        XCTAssertTrue(initialRequest.requiresCreatorApproval)

        let missingWordBootstrap = try ClipLiveShareServerRoomV4ClientRoom
            .makeCandidate(
                invite: initialRequest.invite,
                pairKeyIdentity: candidate.pairIdentity,
                localDescriptor: candidate.descriptor,
                signer: candidate.signer,
                accessWord: initialRequest.accessWord,
                requiresCreatorApproval:
                    initialRequest.requiresCreatorApproval
            )
        XCTAssertThrowsError(
            try fixture.creator.consumeForwardedJoinKnock(
                candidateHandle: candidate.handle,
                payload: missingWordBootstrap.joinKnock
            )
        ) { error in
            XCTAssertEqual(
                error as? ClipLiveShareServerRoomV4ClientRoomError,
                .invalidAccessWord
            )
        }
        XCTAssertTrue(fixture.creator.snapshot.pendingApprovals.isEmpty)

        // The app retains the authenticated invite and the approval bit while
        // asking for the missing Access Word. Reconstructing the retry from
        // this status exercises the same state that drives the popover form.
        let accessWordStatus = MenuBarLiveShareConnectionStatus
            .accessWordRequired(
                roomName: "Room \(fixture.invite.roomCode.rawValue)",
                invite: initialRequest.invite,
                requiresCreatorApproval:
                    initialRequest.requiresCreatorApproval
            )
        let model = MenuBarPopoverModel()
        model.setLiveShareConnectionStatus(accessWordStatus)
        XCTAssertEqual(model.liveShareConnectionStatus.paneContent, .accessWord)

        let retryRequest = MenuBarServerRoomJoinRequest(
            invite: try XCTUnwrap(
                model.liveShareConnectionStatus.accessWordInvite
            ),
            accessWord: "  secret word  ",
            requiresCreatorApproval:
                model.liveShareConnectionStatus
                    .accessWordRequiresCreatorApproval
        )
        XCTAssertEqual(retryRequest.accessWord, "SECRET WORD")
        XCTAssertTrue(retryRequest.requiresCreatorApproval)

        let verifiedBootstrap = try ClipLiveShareServerRoomV4ClientRoom
            .makeCandidate(
                invite: retryRequest.invite,
                pairKeyIdentity: candidate.pairIdentity,
                localDescriptor: candidate.descriptor,
                signer: candidate.signer,
                accessWord: retryRequest.accessWord,
                requiresCreatorApproval:
                    retryRequest.requiresCreatorApproval
            )
        let decision = try fixture.creator.consumeForwardedJoinKnock(
            candidateHandle: candidate.handle,
            payload: verifiedBootstrap.joinKnock
        )
        guard case let .pendingApproval(pending) = decision else {
            XCTFail("A verified friend must still wait for the creator")
            return
        }
        XCTAssertEqual(pending.candidateHandle, candidate.handle)
        XCTAssertEqual(fixture.creator.snapshot.pendingApprovals, [pending])

        let waiting = ServerMeshJoinPresentationPolicy.transition(
            for: .waitingForAdmission,
            roomName: "Room \(fixture.invite.roomCode.rawValue)"
        )
        guard case let .awaitingApproval(roomName) = waiting else {
            XCTFail("The candidate should show the waiting-for-approval pane")
            return
        }
        model.setLiveShareConnectionStatus(
            .awaitingApproval(roomName: roomName)
        )
        XCTAssertEqual(model.liveShareConnectionStatus.paneContent, .connection)
        XCTAssertEqual(model.liveShareConnectionStatus.title, "Waiting for Approval")

        let admission = try fixture.creator.approve(
            candidateHandle: candidate.handle
        )
        XCTAssertEqual(admission.candidateHandle, candidate.handle)
        XCTAssertTrue(fixture.creator.snapshot.pendingApprovals.isEmpty)
        XCTAssertEqual(
            ServerMeshJoinPresentationPolicy.transition(
                for: .active,
                roomName: roomName
            ),
            .showActiveRoom
        )

        // Denial is equally explicit and durable: replaying the same signed
        // request cannot silently admit the friend after the host chose Deny.
        let deniedCandidate = try makeSavedFriendCandidate(seed: 0x69)
        let deniedBootstrap = try ClipLiveShareServerRoomV4ClientRoom
            .makeCandidate(
                invite: retryRequest.invite,
                pairKeyIdentity: deniedCandidate.pairIdentity,
                localDescriptor: deniedCandidate.descriptor,
                signer: deniedCandidate.signer,
                accessWord: retryRequest.accessWord,
                requiresCreatorApproval: true
            )
        guard case .pendingApproval = try fixture.creator
            .consumeForwardedJoinKnock(
                candidateHandle: deniedCandidate.handle,
                payload: deniedBootstrap.joinKnock
            ) else {
            XCTFail("The second friend should also require a decision")
            return
        }
        XCTAssertEqual(
            try fixture.creator.deny(
                candidateHandle: deniedCandidate.handle
            ),
            deniedCandidate.handle
        )
        XCTAssertThrowsError(
            try fixture.creator.consumeForwardedJoinKnock(
                candidateHandle: deniedCandidate.handle,
                payload: deniedBootstrap.joinKnock
            )
        ) { error in
            XCTAssertEqual(
                error as? ClipLiveShareServerRoomV4ClientRoomError,
                .admissionDenied
            )
        }
    }

    func testNonPromptLiveShareStatesSelectTheirExpectedPane() {
        XCTAssertEqual(
            MenuBarLiveShareConnectionStatus.idle.paneContent,
            .entry
        )
        XCTAssertEqual(
            MenuBarLiveShareConnectionStatus.creating.paneContent,
            .connection
        )
        XCTAssertEqual(
            MenuBarLiveShareConnectionStatus
                .joining(roomName: "Room ABCD1234")
                .paneContent,
            .connection
        )
    }

    func testVersionDisplayUsesTheMarketingVersion() {
        XCTAssertEqual(
            MenuBarApplicationVersion.displayString(
                infoDictionary: ["CFBundleShortVersionString": "1.2.3"]
            ),
            "v1.2.3"
        )
    }

    private func makeServerRoomInvite()
        throws -> ClipLiveShareServerRoomV4Invite {
        let signer = try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(repeating: 0x66, count: 32)
        )
        return try ClipLiveShareServerRoomV4Invite(
            serviceEndpoint: URL(string: "https://mesh.example.test")!,
            roomID: .init(bytes: Data(repeating: 0x11, count: 32)),
            sessionID: .init(rawValue: "menu-server-room-v4"),
            creatorIdentity: signer.publicKey,
            roomAgreementSecret: .init(
                bytes: Data(repeating: 0x33, count: 32)
            ),
            admissionCapability: .init(
                bytes: Data(repeating: 0x44, count: 32)
            )
        )
    }

    private func makeSavedFriendRoom() throws -> SavedFriendRoomFixture {
        let signer = try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(repeating: 0x67, count: 32)
        )
        let pairIdentity = ClipLiveShareServerRoomV4KeyAgreementIdentity()
        let descriptor = try ClipLiveShareServerRoomV4MemberDescriptor(
            participantID: .random(),
            identity: signer.publicKey,
            pairSignalingPublicKey: pairIdentity.publicKey,
            displayName: "Alex",
            deviceName: "Studio Mac"
        )
        let bootstrap = try ClipLiveShareServerRoomV4ClientRoom.makeCreator(
            serviceEndpoint: URL(string: "https://mesh.example.test")!,
            roomID: .random(),
            memberHandle: .random(),
            sessionID: .init(rawValue: "saved-friend-app-flow"),
            ownerCapability: .random(),
            roomAgreementSecret: .random(),
            admissionCapability: .random(),
            pairKeyIdentity: pairIdentity,
            localDescriptor: descriptor,
            signer: signer,
            roomCode: try .init(rawValue: "FRIEND42"),
            admissionPolicy: try .requiringAccessWord(
                "SECRET WORD",
                askBeforeJoining: false
            )
        )
        return .init(
            creator: bootstrap.room,
            invite: bootstrap.invite,
            hostIdentity: signer.publicKey
        )
    }

    private func makeSavedFriendCandidate(seed: UInt8) throws
        -> SavedFriendCandidateFixture
    {
        let signer = try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(repeating: seed, count: 32)
        )
        let pairIdentity = ClipLiveShareServerRoomV4KeyAgreementIdentity()
        return try .init(
            handle: .random(),
            signer: signer,
            pairIdentity: pairIdentity,
            descriptor: .init(
                participantID: .random(),
                identity: signer.publicKey,
                pairSignalingPublicKey: pairIdentity.publicKey,
                displayName: "Friend \(seed)",
                deviceName: "Friend Mac \(seed)"
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

    func testLiveShareEntryUsesItsOwnCompactFluidHeight() {
        let reported = expectation(
            description: "Natural Live Share entry height reported"
        )
        var reportedHeight: CGFloat?
        let controller = NSHostingController(
            rootView: MenuBarPopoverView(
                model: MenuBarPopoverModel(),
                actions: MenuBarActions(
                    captureArea: {},
                    lastArea: {},
                    fullscreen: {},
                    openHistory: {},
                    openSettings: {},
                    quit: {}
                ),
                initialRoute: .liveShare,
                maximumHeight: 940,
                onContentHeightChange: { height in
                    guard reportedHeight == nil else { return }
                    reportedHeight = height
                    reported.fulfill()
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: MenuBarPopoverView.contentSize
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()

        let fittedHeight = ceil(controller.view.fittingSize.height)
        XCTAssertEqual(XCTWaiter.wait(for: [reported], timeout: 1), .completed)
        XCTAssertGreaterThan(fittedHeight, 200)
        XCTAssertLessThan(fittedHeight, MenuBarPopoverView.contentSize.height)
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

private struct SavedFriendRoomFixture {
    var creator: ClipLiveShareServerRoomV4ClientRoom
    let invite: ClipLiveShareServerRoomV4Invite
    let hostIdentity: ClipLiveShareIdentityPublicKey
}

private struct SavedFriendCandidateFixture {
    let handle: ClipLiveShareServerRoomV4CandidateHandle
    let signer: ClipLiveShareSoftwareIdentitySigner
    let pairIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity
    let descriptor: ClipLiveShareServerRoomV4MemberDescriptor
}
