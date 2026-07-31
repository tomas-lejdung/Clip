import AppKit
import ClipLiveShare
import Foundation
import SwiftUI
import Testing
@testable import Clip

@Suite("Native-v3 mesh room presentation")
@MainActor
struct MeshRoomPresentationModelTests {
    @Test
    func collaborationColorUsesPersistentIdentity() {
        let identity = Data("persistent-public-identity".utf8)
        let first = MeshParticipantIdentityColor.collaborationColor(
            forPersistentIdentity: identity
        )
        let second = MeshParticipantIdentityColor.collaborationColor(
            forPersistentIdentity: identity
        )
        let other = MeshParticipantIdentityColor.collaborationColor(
            forPersistentIdentity: Data("another-identity".utf8)
        )

        #expect(first == second)
        #expect(first != other)
    }

    @Test
    func collaborationDefaultsBuildBoundedAttributedEvents() throws {
        var settings = LiveShareSettings.default
        settings.collaborationPointerVisibleByDefault = true
        settings.collaborationPingDurationSeconds = 7
        settings.collaborationInkColor = try .init(
            red: 240,
            green: 80,
            blue: 120
        )
        settings.collaborationInkExpirySeconds = 45
        let configuration = MeshParticipantCollaborationConfiguration(
            settings: settings,
            persistentIdentity: Data("persistent-identity".utf8)
        )
        let participantID = ClipLiveShareNativeV3ParticipantID.random()
        let context = try ClipLiveShareNativeV3CollaborationContext(
            sessionID: .random(),
            participantID: participantID,
            sourceKey: .init(
                ownerParticipantID:
                    ClipLiveShareNativeV3ParticipantID.random(),
                sourceInstanceID: .random()
            ),
            sequence: 1,
            sentAt: .init(millisecondsSince1970: 1_000)
        )
        let position = try ClipLiveShareNativeV3NormalizedPoint(
            x: 0.25,
            y: 0.75
        )

        guard case let .ping(ping) = try configuration.ping(
            context: context,
            position: position
        ) else {
            Issue.record("Expected a ping event")
            return
        }
        #expect(configuration.pointerVisibleByDefault)
        #expect(ping.color == configuration.identityColor)
        #expect(ping.color != configuration.inkColor)
        #expect(
            ping.expiresAt.millisecondsSince1970
                - context.sentAt.millisecondsSince1970 == 7_000
        )

        guard case let .strokeBegin(stroke) =
            try configuration.strokeBegin(
                context: context,
                strokeID: .init(),
                point: position
            )
        else {
            Issue.record("Expected a stroke-begin event")
            return
        }
        #expect(stroke.color == settings.collaborationInkColor)
        #expect(
            stroke.expiresAt.millisecondsSince1970
                - context.sentAt.millisecondsSince1970 == 45_000
        )
    }

    @Test
    func mediaRateEstimatorKeepsPeersTracksAndDirectionsSeparate() {
        var estimator = MeshRoomMediaRateEstimator()
        let start = Date(timeIntervalSince1970: 100)
        let annaOutgoing = MeshRoomMediaCounterKey(
            participantID: "anna",
            trackIdentifier: "screen",
            direction: .outgoing
        )
        let annaIncoming = MeshRoomMediaCounterKey(
            participantID: "anna",
            trackIdentifier: "screen",
            direction: .incoming
        )
        let benOutgoing = MeshRoomMediaCounterKey(
            participantID: "ben",
            trackIdentifier: "screen",
            direction: .outgoing
        )
        estimator.record([
            annaOutgoing: .init(
                capturedAt: start,
                bytes: 1_000,
                frames: 10,
                reportedFramesPerSecond: 29.97
            ),
            annaIncoming: .init(
                capturedAt: start,
                bytes: 4_000,
                frames: 20,
                reportedFramesPerSecond: 0
            ),
            benOutgoing: .init(
                capturedAt: start,
                bytes: 500,
                frames: 0,
                reportedFramesPerSecond: 0
            ),
        ])
        #expect(estimator.rates.count == 3)
        #expect(estimator.rates[annaOutgoing]?.bitsPerSecond == 0)
        #expect(estimator.rates[annaOutgoing]?.framesPerSecond == 29.97)

        estimator.record([
            annaOutgoing: .init(
                capturedAt: start.addingTimeInterval(2),
                bytes: 3_000,
                frames: 70,
                reportedFramesPerSecond: 29.97
            ),
            annaIncoming: .init(
                capturedAt: start.addingTimeInterval(2),
                bytes: 5_000,
                frames: 68,
                reportedFramesPerSecond: 0
            ),
            benOutgoing: .init(
                capturedAt: start.addingTimeInterval(2),
                bytes: 1_500,
                frames: 120,
                reportedFramesPerSecond: 0
            ),
        ])

        #expect(
            estimator.rates[annaOutgoing]
                == MeshRoomMediaRate(
                    bitsPerSecond: 8_000,
                    framesPerSecond: 29.97
                )
        )
        #expect(
            estimator.rates[annaIncoming]
                == MeshRoomMediaRate(
                    bitsPerSecond: 4_000,
                    framesPerSecond: 24
                )
        )
        #expect(
            estimator.rates[benOutgoing]
                == MeshRoomMediaRate(
                    bitsPerSecond: 4_000,
                    framesPerSecond: 60
                )
        )
    }

    @Test
    func mediaRateEstimatorIgnoresDuplicateResetsAndPrunesCounters() {
        var estimator = MeshRoomMediaRateEstimator()
        let start = Date(timeIntervalSince1970: 200)
        let key = MeshRoomMediaCounterKey(
            participantID: "anna",
            trackIdentifier: "window",
            direction: .incoming
        )
        estimator.record([
            key: .init(
                capturedAt: start,
                bytes: 1_000,
                frames: 10,
                reportedFramesPerSecond: 0
            )
        ])
        estimator.record([
            key: .init(
                capturedAt: start.addingTimeInterval(1),
                bytes: 2_000,
                frames: 40,
                reportedFramesPerSecond: 0
            )
        ])
        let measured = estimator.rates[key]

        estimator.record([
            key: .init(
                capturedAt: start.addingTimeInterval(1),
                bytes: 2_000,
                frames: 40,
                reportedFramesPerSecond: 0
            )
        ])
        #expect(estimator.rates[key] == measured)

        estimator.record([
            key: .init(
                capturedAt: start.addingTimeInterval(2),
                bytes: 10,
                frames: 1,
                reportedFramesPerSecond: 0
            )
        ])
        #expect(estimator.rates[key] == nil)

        estimator.record([:])
        #expect(estimator.rates.isEmpty)

        estimator.record([
            key: .init(
                capturedAt: start.addingTimeInterval(3),
                bytes: 100,
                frames: 10,
                reportedFramesPerSecond: 24
            )
        ])
        #expect(
            estimator.rates[key]
                == MeshRoomMediaRate(
                    bitsPerSecond: 0,
                    framesPerSecond: 24
                )
        )
    }

    @Test
    func snapshotNormalizesRoomCollectionsAndRedactsSecrets() {
        let inviteSecret = "PRIVATE-MESH-JOIN-CAPABILITY"
        let snapshot = makeSnapshot(
            roomName: "   ",
            invite: MeshRoomInviteSnapshot(
                url: URL(
                    string:
                        "https://share.example/ROOM#join=\(inviteSecret)"
                )!,
                roomCode: "ROOM"
            ),
            accessWordEnabled: true,
            accessWord: "MEADOW",
            pendingAdmissions: [
                .init(id: "local", displayName: "Self", deviceName: nil),
                .init(id: "pending", displayName: "Pat", deviceName: nil),
                .init(id: "pending", displayName: "Duplicate", deviceName: nil),
            ],
            remoteParticipants: [
                remoteParticipant(id: "local"),
                remoteParticipant(id: "remote"),
                remoteParticipant(id: "remote"),
            ]
        )

        #expect(snapshot.roomName == "Live Share")
        #expect(snapshot.pendingAdmissions.map(\.id) == ["pending"])
        #expect(snapshot.remoteParticipants.map(\.id) == ["remote"])
        #expect(snapshot.participantCount == 2)
        #expect(!snapshot.description.contains(inviteSecret))
        #expect(!snapshot.description.contains("MEADOW"))
        #expect(!snapshot.invite!.description.contains(inviteSecret))
    }

    @Test
    func mediaDiagnosticsRemainDirectionAndParticipantScoped() {
        let outgoing = MeshRoomMediaDiagnosticsSnapshot(
            id: "remote-outgoing-screen",
            sourceName: "Screen → Anna",
            direction: .outgoing,
            codec: "H264",
            width: 1_920,
            height: 1_080,
            framesPerSecond: 60,
            bitsPerSecond: 8_000_000,
            droppedFrames: 2,
            queuePressureDrops: 3,
            queuePressureReason: "cpu",
            packetsLost: 4,
            processingLatencyMilliseconds: 5
        )
        let incoming = MeshRoomMediaDiagnosticsSnapshot(
            id: "remote-incoming-window",
            sourceName: "Window",
            direction: .incoming,
            codec: "VP9",
            width: 1_280,
            height: 720,
            framesPerSecond: 30,
            bitsPerSecond: 2_000_000,
            droppedFrames: 6,
            packetsLost: 7,
            processingLatencyMilliseconds: 8
        )
        let remote = remoteParticipant(
            id: "remote",
            diagnostics: [outgoing, incoming]
        )
        let snapshot = makeSnapshot(
            remoteParticipants: [remote],
            outgoingDiagnostics: [incoming, outgoing]
        )

        #expect(snapshot.outgoingDiagnostics == [outgoing])
        #expect(snapshot.remoteParticipants.first?.diagnostics == [incoming])
        #expect(
            snapshot.outgoingDiagnostics.first?.queuePressureDrops == 3
        )
        #expect(
            snapshot.outgoingDiagnostics.first?.queuePressureReason == "cpu"
        )
        #expect(
            snapshot.remoteParticipants.first?.diagnostics.first?
                .processingLatencyMilliseconds == 8
        )
    }

    @Test
    func creatorAuthorityActionsAreRoleAndStateGated() {
        var copied: [String] = []
        var accessChanges: [Bool] = []
        var inviteRefreshes = 0
        var approvals: [String] = []
        var removals: [String] = []
        var endings = 0
        let model = MeshRoomPresentationModel(
            snapshot: makeSnapshot(
                pendingAdmissions: [
                    .init(id: "pending", displayName: "Pat", deviceName: nil)
                ],
                remoteParticipants: [remoteParticipant(id: "remote")]
            ),
            actions: .init(
                copyText: { copied.append($0) },
                setAccessWordEnabled: { accessChanges.append($0) },
                requestNewInvite: { inviteRefreshes += 1 },
                approveAdmission: { approvals.append($0) },
                removeParticipant: { removals.append($0) },
                endRoomForEveryone: { endings += 1 }
            ),
            copiedFeedbackDuration: .seconds(60)
        )

        model.copyInvite()
        model.requestNewInvite()
        model.setAccessWordEnabled(true)
        model.approveAdmission("unknown")
        model.approveAdmission("pending")
        model.removeParticipant("local")
        model.removeParticipant("remote")
        model.endRoomForEveryone()

        #expect(copied.count == 1)
        #expect(accessChanges == [true])
        #expect(inviteRefreshes == 1)
        #expect(approvals == ["pending"])
        #expect(removals == ["remote"])
        #expect(endings == 1)

        model.update(makeSnapshot(
            currentLeaderParticipantID: "remote",
            remoteParticipants: [remoteParticipant(id: "remote")]
        ))
        model.copyInvite()
        model.requestNewInvite()
        model.setAccessWordEnabled(false)
        model.removeParticipant("remote")
        model.endRoomForEveryone()

        #expect(copied.count == 1)
        #expect(accessChanges == [true])
        #expect(inviteRefreshes == 1)
        #expect(removals == ["remote"])
        #expect(endings == 1)
    }

    @Test
    func accessWordCopyIsLeaderOnlyAndRequiresAVisibleWord() {
        var copied: [String] = []
        let model = MeshRoomPresentationModel(
            snapshot: makeSnapshot(
                accessWordEnabled: true,
                accessWord: "MEADOW"
            ),
            actions: .init(copyText: { copied.append($0) })
        )

        model.copyAccessWord()
        #expect(copied == ["MEADOW"])

        model.update(makeSnapshot(
            currentLeaderParticipantID: "remote",
            accessWordEnabled: true,
            accessWord: "MEADOW"
        ))
        model.copyAccessWord()
        #expect(copied == ["MEADOW"])

        model.update(makeSnapshot(
            accessWordEnabled: true,
            accessWord: nil
        ))
        model.copyAccessWord()
        #expect(copied == ["MEADOW"])
    }

    @Test
    func creatorTransitionMakesTheSameParticipantModelAuthoritative() {
        var approvals: [String] = []
        let model = MeshRoomPresentationModel(
            snapshot: makeSnapshot(
                currentLeaderParticipantID: "remote",
                pendingAdmissions: [
                    .init(id: "pending", displayName: "Pat", deviceName: nil)
                ],
                remoteParticipants: [remoteParticipant(id: "remote")]
            ),
            actions: .init(
                approveAdmission: { approvals.append($0) }
            )
        )

        model.approveAdmission("pending")
        #expect(approvals.isEmpty)

        model.update(makeSnapshot(
            phase: .live(elapsedSeconds: 12),
            currentLeaderParticipantID: "local",
            pendingAdmissions: [
                .init(id: "pending", displayName: "Pat", deviceName: nil)
            ],
            remoteParticipants: [remoteParticipant(id: "remote")]
        ))
        model.approveAdmission("pending")
        #expect(approvals == ["pending"])
        #expect(model.snapshot.currentLeaderDisplayName == "Alex")
    }

    @Test
    func leaderlessRoomKeepsMediaActionsButLocksMembership() {
        var sharedFocused = 0
        var approvals: [String] = []
        var pointerChanges: [Bool] = []
        let model = MeshRoomPresentationModel(
            snapshot: makeSnapshot(
                phase: .leaderlessLocked,
                currentLeaderParticipantID: nil,
                pendingAdmissions: [
                    .init(id: "pending", displayName: "Pat", deviceName: nil)
                ],
                collaboration: .init()
            ),
            actions: .init(
                approveAdmission: { approvals.append($0) },
                shareFocusedWindow: { sharedFocused += 1 },
                setLocalPointerVisible: { pointerChanges.append($0) }
            )
        )

        model.approveAdmission("pending")
        model.shareFocusedWindow()
        model.setLocalPointerVisible(true)

        #expect(approvals.isEmpty)
        #expect(sharedFocused == 1)
        #expect(pointerChanges == [true])
    }

    @Test
    func remoteAudioAndWindowActionsRemainParticipantScoped() {
        let source = MeshRoomRemoteSourceSnapshot(
            id: "shared-id",
            applicationName: "Figma",
            windowTitle: "Design",
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            isVisible: true,
            isFocused: true,
            isConnected: true
        )
        let anna = remoteParticipant(
            id: "anna",
            sources: [source],
            systemAudioAvailable: true
        )
        let ben = remoteParticipant(
            id: "ben",
            sources: [source],
            systemAudioAvailable: true
        )
        var volumes: [(String, Double)] = []
        var visibility: [(MeshRoomSourceKey, Bool)] = []
        var fullScreen: [MeshRoomSourceKey] = []
        let model = MeshRoomPresentationModel(
            snapshot: makeSnapshot(
                remoteParticipants: [anna, ben]
            ),
            actions: .init(
                setParticipantVolume: {
                    volumes.append(($0, $1))
                },
                setRemoteSourceVisible: {
                    visibility.append(($0, $1))
                },
                toggleRemoteSourceFullScreen: {
                    fullScreen.append($0)
                }
            )
        )
        let annaKey = MeshRoomSourceKey(
            participantID: "anna",
            sourceID: "shared-id"
        )
        let benKey = MeshRoomSourceKey(
            participantID: "ben",
            sourceID: "shared-id"
        )

        model.setParticipantVolume("anna", 3)
        model.setRemoteSourceVisible(annaKey, false)
        model.toggleRemoteSourceFullScreen(benKey)
        model.setRemoteSourceVisible(
            .init(participantID: "unknown", sourceID: "shared-id"),
            false
        )

        #expect(volumes.count == 1)
        #expect(volumes.first?.0 == "anna")
        #expect(volumes.first?.1 == 1)
        #expect(visibility.count == 1)
        #expect(visibility.first?.0 == annaKey)
        #expect(visibility.first?.1 == false)
        #expect(fullScreen == [benKey])
    }

    @Test
    func hiddenOrDisconnectedRemoteSourceCannotEnterFullScreen() {
        let hidden = MeshRoomRemoteSourceSnapshot(
            id: "hidden",
            applicationName: "Figma",
            windowTitle: "Hidden",
            pixelWidth: 100,
            pixelHeight: 100,
            isVisible: false,
            isFocused: false,
            isConnected: true
        )
        let disconnected = MeshRoomRemoteSourceSnapshot(
            id: "disconnected",
            applicationName: "Figma",
            windowTitle: "Disconnected",
            pixelWidth: 100,
            pixelHeight: 100,
            isVisible: true,
            isFocused: false,
            isConnected: false
        )
        var fullScreen: [MeshRoomSourceKey] = []
        let model = MeshRoomPresentationModel(
            snapshot: makeSnapshot(
                remoteParticipants: [
                    remoteParticipant(
                        id: "remote",
                        sources: [hidden, disconnected]
                    )
                ]
            ),
            actions: .init(
                toggleRemoteSourceFullScreen: {
                    fullScreen.append($0)
                }
            )
        )

        model.toggleRemoteSourceFullScreen(.init(
            participantID: "remote",
            sourceID: "hidden"
        ))
        model.toggleRemoteSourceFullScreen(.init(
            participantID: "remote",
            sourceID: "disconnected"
        ))
        #expect(fullScreen.isEmpty)
    }

    @Test
    func collaborationToolsAreParticipantOwnedWhileConnected() {
        var localPointers: [Bool] = []
        var clears = 0
        let model = MeshRoomPresentationModel(
            snapshot: makeSnapshot(
                collaboration: .init(
                    canClearAnnotations: true
                )
            ),
            actions: .init(
                setLocalPointerVisible: { localPointers.append($0) },
                clearAnnotations: { clears += 1 }
            )
        )

        model.setLocalPointerVisible(true)
        model.clearAnnotations()
        #expect(localPointers == [true])
        #expect(clears == 1)

        model.update(makeSnapshot(
            currentLeaderParticipantID: "remote",
            remoteParticipants: [remoteParticipant(id: "remote")],
            collaboration: .init()
        ))
        model.setLocalPointerVisible(false)
        #expect(localPointers == [true, false])
    }

    @Test
    func electionPhaseKeepsParticipantOwnedMediaAvailable() {
        var sharedWindows: [String] = []
        var audioChanges: [Bool] = []
        let model = MeshRoomPresentationModel(
            snapshot: makeSnapshot(phase: .electingCreator),
            actions: .init(
                shareWindow: { sharedWindows.append($0) },
                setSystemAudioEnabled: { audioChanges.append($0) }
            )
        )

        model.shareWindow("window")
        model.setSystemAudioEnabled(true)
        #expect(sharedWindows == ["window"])
        #expect(audioChanges == [true])
    }

    @Test
    func leadershipTransferPreservesFoundingCreatorProvenance() {
        let snapshot = makeSnapshot(
            foundingCreatorParticipantID: "founder",
            currentLeaderParticipantID: "successor",
            remoteParticipants: [
                remoteParticipant(id: "founder", displayName: "Founder"),
                remoteParticipant(id: "successor", displayName: "Successor"),
            ]
        )

        #expect(snapshot.foundingCreatorParticipantID == "founder")
        #expect(snapshot.foundingCreatorDisplayName == "Founder")
        #expect(snapshot.currentLeaderParticipantID == "successor")
        #expect(snapshot.currentLeaderDisplayName == "Successor")
        #expect(!snapshot.isLocalLeader)
    }

    @Test
    func commonCreatorAndParticipantPanesUseFluidNaturalSizing() {
        let remoteSource = MeshRoomRemoteSourceSnapshot(
            id: "remote-source",
            applicationName: "Figma",
            windowTitle: "Design",
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            isVisible: true,
            isFocused: true,
            isConnected: true
        )

        for creatorID in ["local", "remote"] {
            let snapshot = makeSnapshot(
                currentLeaderParticipantID: creatorID,
                remoteParticipants: [
                    remoteParticipant(
                        id: "remote",
                        sources: [remoteSource],
                        systemAudioAvailable: true
                    )
                ]
            )
            let controller = NSHostingController(
                rootView: MeshRoomPopoverView(
                    model: MeshRoomPresentationModel(
                        snapshot: snapshot,
                        actions: .noOp
                    ),
                    maximumHeight: 720
                )
            )
            let window = NSWindow(
                contentRect: NSRect(
                    origin: .zero,
                    size: NSSize(
                        width: MeshRoomPopoverView.contentWidth,
                        height: 260
                    )
                ),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()

            let fitted = controller.view.fittingSize
            #expect(ceil(fitted.width) == MeshRoomPopoverView.contentWidth)
            #expect(fitted.height > 260)
            #expect(fitted.height <= 720)
        }
    }

    @Test("Rotating an active room invite preserves its stable name")
    func activeRoomInviteRotationPreservesName() {
        #expect(
            MeshRoomIdentityPolicy.roomName(
                current: "Room 4A12BC90",
                inviteDerivedName: "Room 9FEE1023",
                roomIsActive: true
            ) == "Room 4A12BC90"
        )
        #expect(
            MeshRoomIdentityPolicy.roomName(
                current: "Live Share",
                inviteDerivedName: "Room 4A12BC90",
                roomIsActive: false
            ) == "Room 4A12BC90"
        )
    }

    private func makeSnapshot(
        phase: MeshRoomPhase = .live(elapsedSeconds: 3),
        roomName: String = "Design Review",
        foundingCreatorParticipantID: String? = "local",
        currentLeaderParticipantID: String? = "local",
        invite: MeshRoomInviteSnapshot? = .init(
            url: URL(string: "https://share.example/ROOM#join=secret")!,
            roomCode: "ROOM"
        ),
        accessWordEnabled: Bool = false,
        accessWord: String? = nil,
        pendingAdmissions: [MeshRoomPendingAdmissionSnapshot] = [],
        remoteParticipants: [MeshRoomRemoteParticipantSnapshot] = [],
        outgoingDiagnostics: [MeshRoomMediaDiagnosticsSnapshot] = [],
        collaboration: MeshRoomCollaborationSnapshot = .init()
    ) -> MeshRoomViewSnapshot {
        MeshRoomViewSnapshot(
            phase: phase,
            roomName: roomName,
            localParticipant: .init(
                id: "local",
                displayName: "Alex",
                deviceName: "Studio"
            ),
            foundingCreatorParticipantID: foundingCreatorParticipantID,
            currentLeaderParticipantID: currentLeaderParticipantID,
            invite: invite,
            accessWordEnabled: accessWordEnabled,
            accessWord: accessWord,
            pendingAdmissions: pendingAdmissions,
            localSources: [
                .init(
                    id: "source",
                    applicationName: "Xcode",
                    windowTitle: "Clip",
                    status: .live
                )
            ],
            canShareFocusedWindow: true,
            focusedWindowDescription: "Clip — Xcode",
            availableWindows: [
                .init(
                    id: "window",
                    applicationName: "Xcode",
                    windowTitle: "Clip",
                    applicationPath: nil
                )
            ],
            canAddWindow: true,
            settings: .init(
                canChangeAudioExclusions: true
            ),
            remoteParticipants: remoteParticipants,
            outgoingDiagnostics: outgoingDiagnostics,
            collaboration: collaboration
        )
    }

    private func remoteParticipant(
        id: String,
        displayName: String? = nil,
        sources: [MeshRoomRemoteSourceSnapshot] = [],
        systemAudioAvailable: Bool = false,
        diagnostics: [MeshRoomMediaDiagnosticsSnapshot] = []
    ) -> MeshRoomRemoteParticipantSnapshot {
        .init(
            id: id,
            displayName: displayName ?? id.capitalized,
            route: .direct,
            sources: sources,
            systemAudioAvailable: systemAudioAvailable,
            diagnostics: diagnostics
        )
    }
}
