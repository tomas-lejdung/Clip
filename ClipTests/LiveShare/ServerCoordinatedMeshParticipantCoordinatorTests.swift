import ClipLiveShare
import Foundation
import Testing

@testable import Clip

@Suite("Server-coordinated mesh participant coordinator")
@MainActor
struct ServerCoordinatedMeshParticipantCoordinatorTests {
    @Test("friend presence publishes only an active creator invite")
    func creatorPresenceInvitePolicyRequiresActiveCreator() throws {
        let invite = try makeInvite()

        #expect(
            MeshCreatorPresenceInvitePolicy.invite(
                role: .creator,
                phase: .active,
                invite: invite
            ) == invite
        )
        #expect(
            MeshCreatorPresenceInvitePolicy.invite(
                role: .participant,
                phase: .active,
                invite: invite
            ) == nil
        )
        #expect(
            MeshCreatorPresenceInvitePolicy.invite(
                role: .creator,
                phase: .connecting,
                invite: invite
            ) == nil
        )
        #expect(
            MeshCreatorPresenceInvitePolicy.invite(
                role: .creator,
                phase: .ended(reason: "Room ended."),
                invite: invite
            ) == nil
        )
        #expect(
            MeshCreatorPresenceInvitePolicy.invite(
                role: .creator,
                phase: .active,
                invite: nil
            ) == nil
        )
    }

    @Test("a failed room start tears local media down exactly once")
    func startFailureTearsDownParticipant() async throws {
        let probe = ParticipantCoordinatorLifecycleProbe()
        let session = ServerCoordinatedMeshParticipantRoomSessionClient(
            events: { AsyncStream { _ in } },
            snapshot: { fatalError("snapshot is not used before start") },
            start: { throw ParticipantCoordinatorTestError.startFailed },
            rotateInvite: { throw ParticipantCoordinatorTestError.startFailed }
        )
        let coordinator = ServerCoordinatedMeshParticipantCoordinator(
            localParticipantID: .random(),
            localIdentity: Data(repeating: 7, count: 65),
            localDisplayName: "Local",
            session: session,
            localMedia: .init(
                start: { probe.startCount += 1 },
                stop: { probe.stopCount += 1 }
            ),
            onSessionEnded: { probe.endCount += 1 }
        )

        coordinator.start()
        try await eventually {
            probe.stopCount == 1 && probe.endCount == 1
        }

        #expect(probe.startCount == 1)
        #expect(probe.stopCount == 1)
        #expect(probe.endCount == 1)
        #expect(!coordinator.isActive)

        // Application shutdown racing the failed start remains idempotent.
        await coordinator.close()
        #expect(probe.stopCount == 1)
        #expect(probe.endCount == 1)
    }

    @Test("a local publication notice survives its failure echo and clears on recovery")
    func localPublicationNoticeClearsOnAuthoritativeRecovery() {
        let session = ServerCoordinatedMeshParticipantRoomSessionClient(
            events: { AsyncStream { $0.finish() } },
            snapshot: { fatalError("snapshot is not used") },
            start: {},
            rotateInvite: { throw ParticipantCoordinatorTestError.startFailed }
        )
        let coordinator = ServerCoordinatedMeshParticipantCoordinator(
            localParticipantID: .random(),
            localIdentity: Data(repeating: 8, count: 65),
            localDisplayName: "Local",
            session: session,
            localMedia: .init()
        )
        let failedState = MeshParticipantLocalPublicationSnapshot()
        coordinator.localPublicationDidChange(failedState)
        coordinator.localPublicationDidFail("Capture is not running.")

        #expect(
            coordinator.presentationModel.snapshot.statusNotice?.message
                == "Capture is not running."
        )

        // `report` publishes its unchanged state immediately after the error.
        // That echo is not proof of recovery and must not flash the notice away.
        coordinator.localPublicationDidChange(failedState)
        #expect(coordinator.presentationModel.snapshot.statusNotice != nil)

        var recoveredState = failedState
        recoveredState.canAddWindow = true
        coordinator.localPublicationDidChange(recoveredState)
        #expect(coordinator.presentationModel.snapshot.statusNotice == nil)
    }

    @Test("a room-control retry clears only its own non-capture notice")
    func controlRetryClearsOnlyMatchingNotice() {
        let coordinator = makeCoordinator()
        let unchangedPublication = MeshParticipantLocalPublicationSnapshot()
        coordinator.localPublicationDidChange(unchangedPublication)
        coordinator.controlOperationDidFail(
            .admissionPolicy,
            message: "Could not update room policy."
        )

        let failedNotice = coordinator.presentationModel.snapshot.statusNotice
        #expect(failedNotice?.title == "Room settings issue")
        #expect(failedNotice?.message == "Could not update room policy.")
        #expect(failedNotice?.title != "Sharing issue")

        // Neither a publication echo nor an authoritative publication change
        // proves anything about the failed policy update.
        coordinator.localPublicationDidChange(unchangedPublication)
        var changedPublication = unchangedPublication
        changedPublication.canAddWindow = true
        coordinator.localPublicationDidChange(changedPublication)
        #expect(
            coordinator.presentationModel.snapshot.statusNotice?.message
                == "Could not update room policy."
        )

        // A successful retry of another room operation also cannot clear it.
        coordinator.controlOperationDidSucceed(.inviteRotation)
        #expect(
            coordinator.presentationModel.snapshot.statusNotice?.message
                == "Could not update room policy."
        )

        coordinator.controlOperationDidSucceed(.admissionPolicy)
        #expect(coordinator.presentationModel.snapshot.statusNotice == nil)
    }

    @Test("friend aliases replace only local participant presentation names")
    func friendAliasesArePresentationOnlyAndReplaceLive() throws {
        let friendIdentity = try identity(seed: 0x61)
        let nonfriendIdentity = try identity(seed: 0x62)
        let coordinator = makeCoordinator(
            initialFriendDisplayNames: friendDirectory(
                identity: friendIdentity,
                displayName: "Jules"
            )
        )

        #expect(
            coordinator.presentationDisplayName(
                for: friendIdentity,
                authenticatedName: "Juliah’s MacBook"
            ) == "Jules"
        )
        #expect(
            coordinator.presentationDisplayName(
                for: nonfriendIdentity,
                authenticatedName: "Authenticated Guest"
            ) == "Authenticated Guest"
        )

        coordinator.replaceFriendDisplayNames(
            friendDirectory(
                identity: friendIdentity,
                displayName: "Julia"
            )
        )

        #expect(
            coordinator.presentationDisplayName(
                for: friendIdentity,
                authenticatedName: "Juliah’s MacBook"
            ) == "Julia"
        )
    }

    @Test("capture recovery remains authoritative beside control retries")
    func captureRecoveryRemainsAuthoritative() {
        let coordinator = makeCoordinator()
        let failedState = MeshParticipantLocalPublicationSnapshot()
        coordinator.localPublicationDidChange(failedState)
        coordinator.localPublicationDidFail("Capture is not running.")
        coordinator.controlOperationDidFail(
            .collaboration,
            message: "Could not send the pointer."
        )

        // Control retry success must not clear or downgrade the independent
        // capture failure.
        coordinator.controlOperationDidSucceed(.collaboration)
        #expect(
            coordinator.presentationModel.snapshot.statusNotice?.title
                == "Sharing issue"
        )
        coordinator.localPublicationDidChange(failedState)
        #expect(coordinator.presentationModel.snapshot.statusNotice != nil)

        var recoveredState = failedState
        recoveredState.canAddWindow = true
        coordinator.localPublicationDidChange(recoveredState)
        #expect(coordinator.presentationModel.snapshot.statusNotice == nil)
    }

    @Test("Access Word prompt is delivered before the failed attempt ends")
    func accessWordPromptPrecedesSessionEnd() async throws {
        let stream = AsyncStream.makeStream(
            of: ServerCoordinatedMeshRoomSessionEvent.self
        )
        let probe = ParticipantCoordinatorLifecycleProbe()
        let session = ServerCoordinatedMeshParticipantRoomSessionClient(
            events: { stream.stream },
            snapshot: { fatalError("snapshot is not used") },
            start: {},
            rotateInvite: { throw ParticipantCoordinatorTestError.startFailed }
        )
        let coordinator = ServerCoordinatedMeshParticipantCoordinator(
            localParticipantID: .random(),
            localIdentity: Data(repeating: 9, count: 65),
            localDisplayName: "Local",
            session: session,
            localMedia: .init(stop: { probe.stopCount += 1 }),
            onSessionEnded: { probe.endCount += 1 },
            onAccessWordRequired: { probe.accessWordPromptCount += 1 }
        )

        coordinator.start()
        stream.continuation.yield(.accessWordRequired)
        try await eventually {
            probe.accessWordPromptCount == 1 && probe.endCount == 1
        }

        #expect(probe.stopCount == 1)
        #expect(probe.callbackOrder == ["access-word", "ended"])
        #expect(!coordinator.isActive)
    }

    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private func makeInvite() throws -> ClipLiveShareServerRoomV4Invite {
        let signer = try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(repeating: 0x76, count: 32)
        )
        return try ClipLiveShareServerRoomV4Invite(
            serviceEndpoint: URL(string: "https://mesh.example.test")!,
            roomID: .init(bytes: Data(repeating: 0x11, count: 32)),
            sessionID: .init(rawValue: "presence-policy-test"),
            creatorIdentity: signer.publicKey,
            roomAgreementSecret: .init(
                bytes: Data(repeating: 0x33, count: 32)
            ),
            admissionCapability: .init(
                bytes: Data(repeating: 0x44, count: 32)
            )
        )
    }

    private func makeCoordinator(
        initialFriendDisplayNames: MeshFriendDisplayNameDirectory = .empty
    )
        -> ServerCoordinatedMeshParticipantCoordinator
    {
        ServerCoordinatedMeshParticipantCoordinator(
            localParticipantID: .random(),
            localIdentity: Data(repeating: 0x58, count: 65),
            localDisplayName: "Local",
            session: .init(
                events: { AsyncStream { $0.finish() } },
                snapshot: { fatalError("snapshot is not used") },
                start: {},
                rotateInvite: {
                    throw ParticipantCoordinatorTestError.startFailed
                }
            ),
            localMedia: .init(),
            initialFriendDisplayNames: initialFriendDisplayNames
        )
    }

    private func identity(
        seed: UInt8
    ) throws -> ClipLiveShareIdentityPublicKey {
        try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(repeating: seed, count: 32)
        ).publicKey
    }

    private func friendDirectory(
        identity: ClipLiveShareIdentityPublicKey,
        displayName: String
    ) -> MeshFriendDisplayNameDirectory {
        MeshFriendDisplayNameDirectory(
            snapshot: .init(
                friends: [
                    .init(
                        id: identity.fingerprint.rawValue,
                        identity: identity,
                        displayName: displayName,
                        deviceName: "Friend Mac",
                        availability: .offline,
                        verifiedInvite: nil,
                        lastSeenAt: nil,
                        lastCheckedAt: nil,
                        retryAfter: nil,
                        issue: nil
                    )
                ]
            )
        )
    }
}

@Suite("Mesh collaboration policy")
struct MeshRoomCollaborationPolicyReducerTests {
    private let sourceA = MeshRoomSourceKey(
        participantID: "participant-a",
        sourceID: "shared-source"
    )
    private let sourceB = MeshRoomSourceKey(
        participantID: "participant-b",
        sourceID: "shared-source"
    )

    @Test("new sources inherit all global tools")
    func newSourcesInheritGlobalSelection() {
        var reducer = MeshRoomCollaborationPolicyReducer(
            globalSelection: .init(
                pointerEnabled: true,
                pingEnabled: true
            )
        )
        reducer.reconcileAuthoritativeSources([sourceA, sourceB])

        for source in [sourceA, sourceB] {
            let policy = reducer.policy(for: source)
            #expect(policy.isUsingGlobalSettings)
            #expect(policy.selection.pointerEnabled)
            #expect(policy.selection.pingEnabled)
            #expect(!policy.selection.drawingEnabled)
        }
    }

    @Test("first source edit detaches a complete global snapshot")
    func sourceEditDetachesCompleteSelection() {
        var reducer = MeshRoomCollaborationPolicyReducer(
            globalSelection: .init(
                pointerEnabled: true,
                pingEnabled: true
            )
        )
        reducer.reconcileAuthoritativeSources([sourceA])

        reducer.set(.drawing, enabled: true, for: sourceA)
        let policy = reducer.policy(for: sourceA)

        #expect(!policy.isUsingGlobalSettings)
        #expect(policy.selection.pointerEnabled)
        #expect(!policy.selection.pingEnabled)
        #expect(policy.selection.drawingEnabled)

        reducer.set(.ping, enabled: true, for: sourceA)
        let changed = reducer.policy(for: sourceA).selection
        #expect(changed.pointerEnabled)
        #expect(changed.pingEnabled)
        #expect(!changed.drawingEnabled)
    }

    @Test("global edits clear overrides and target hidden pointers")
    func globalEditClearsOverridesAndTargetsHiddenPointers() {
        var reducer = MeshRoomCollaborationPolicyReducer(
            globalSelection: .init(pointerEnabled: false)
        )
        reducer.reconcileAuthoritativeSources([sourceA, sourceB])
        reducer.set(.pointer, enabled: true, for: sourceA)
        reducer.set(.pointer, enabled: true, for: sourceB)

        let change = reducer.setGlobal(.ping, enabled: true)

        #expect(change.pointerHiddenSources == [sourceA, sourceB])
        #expect(reducer.sourceOverrides.isEmpty)
        #expect(reducer.globalSelection.pingEnabled)
        #expect(!reducer.globalSelection.drawingEnabled)
        #expect(reducer.policy(for: sourceA).isUsingGlobalSettings)
    }

    @Test("reset reattaches one source and hides only its pointer")
    func resetReattachesOneSource() {
        var reducer = MeshRoomCollaborationPolicyReducer()
        reducer.reconcileAuthoritativeSources([sourceA, sourceB])
        reducer.set(.pointer, enabled: true, for: sourceA)
        reducer.set(.pointer, enabled: true, for: sourceB)

        let change = reducer.useGlobalSettings(for: sourceA)

        #expect(change.pointerHiddenSources == [sourceA])
        #expect(reducer.policy(for: sourceA).isUsingGlobalSettings)
        #expect(!reducer.policy(for: sourceB).isUsingGlobalSettings)
        #expect(reducer.policy(for: sourceB).selection.pointerEnabled)
    }

    @Test("source pointer disable targets only that full source key")
    func sourcePointerDisableIsTargeted() {
        var reducer = MeshRoomCollaborationPolicyReducer(
            globalSelection: .init(pointerEnabled: true)
        )
        reducer.reconcileAuthoritativeSources([sourceA, sourceB])

        let change = reducer.set(
            .pointer,
            enabled: false,
            for: sourceA
        )

        #expect(change.pointerHiddenSources == [sourceA])
        #expect(!reducer.policy(for: sourceA).selection.pointerEnabled)
        #expect(reducer.policy(for: sourceB).selection.pointerEnabled)
    }

    @Test("authoritative lifecycle preserves recovery and prunes ended sources")
    func authoritativeLifecyclePrunesOnlyEndedSources() {
        var reducer = MeshRoomCollaborationPolicyReducer()
        reducer.reconcileAuthoritativeSources([sourceA, sourceB])
        reducer.set(.drawing, enabled: true, for: sourceA)
        reducer.set(.ping, enabled: true, for: sourceB)

        // A visibility or track-recovery pass retains the same authoritative
        // source keys, so neither override changes.
        let transientRemoval = reducer.reconcileAuthoritativeSources([
            sourceA, sourceB,
        ])
        #expect(transientRemoval.isEmpty)
        #expect(reducer.policy(for: sourceA).selection.drawingEnabled)

        let ended = reducer.reconcileAuthoritativeSources([sourceB])
        #expect(ended == [sourceA])
        #expect(reducer.sourceOverrides[sourceA] == nil)
        #expect(reducer.policy(for: sourceB).selection.pingEnabled)

        // Reusing the same source instance string under a different
        // participant never revives the ended participant's override.
        reducer.reconcileAuthoritativeSources([sourceA, sourceB])
        #expect(reducer.policy(for: sourceA).isUsingGlobalSettings)
        #expect(!reducer.policy(for: sourceB).isUsingGlobalSettings)
    }

    @Test("edits for non-authoritative sources are ignored")
    func nonAuthoritativeSourceEditIsIgnored() {
        var reducer = MeshRoomCollaborationPolicyReducer()
        let change = reducer.set(.pointer, enabled: true, for: sourceA)

        #expect(change == .none)
        #expect(reducer.sourceOverrides.isEmpty)
    }
}

@MainActor
private final class ParticipantCoordinatorLifecycleProbe {
    var startCount = 0
    var stopCount = 0
    var endCount = 0 {
        didSet { callbackOrder.append("ended") }
    }
    var accessWordPromptCount = 0 {
        didSet { callbackOrder.append("access-word") }
    }
    var callbackOrder: [String] = []
}

private enum ParticipantCoordinatorTestError: Error {
    case startFailed
}
