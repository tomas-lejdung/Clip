import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import Testing

@testable import Clip

/// Cross-layer acceptance for the clean-slate native-v3 participant journey.
///
/// These tests intentionally assemble the production bootstrap coordinator,
/// provisional-link adapter, mesh manager, participant runtime, and room
/// lifecycle around deterministic in-process transports. Unit tests for those
/// types remain useful, but this suite guards the contracts at their handoff
/// boundaries: a provisional transport must be the transport promoted into
/// the room, every participant must have the same symmetric runtime, and room
/// authority must survive creator departure without falling back to an older
/// host/viewer session.
@Suite("Native v3 mesh integration acceptance", .serialized)
struct NativeV3MeshIntegrationAcceptanceTests {
    @Test(
        "direct v3 genesis and three distinct joins promote one quarantined six-link mesh"
    )
    func directV3AdmissionBuildsFourParticipantMesh() async throws {
        let room = try await V3AcceptanceRoom.bootstrapFourParticipants()

        #expect(room.routeProofs.count == 3)
        #expect(Set(room.routeProofs).count == 3)
        #expect(room.bootstrapKinds.contains(.hello))
        #expect(room.bootstrapKinds.contains(.provisionalAdmission))
        #expect(room.bootstrapKinds.contains(.admitted))

        let topology = try ClipLiveShareNativeV3CompleteMeshTopology(
            participantIDs: Set(room.participants.map(\.participantID))
        )
        #expect(topology.peerLinkKeys.count == 6)
        #expect(await room.wire.uniquePeerLinkKeys() == Set(topology.peerLinkKeys))
        #expect(await room.wire.endpointCount() == 12)

        for participant in room.participants {
            let manager = try #require(room.managers[participant.participantID])
            let snapshot = await manager.snapshot()
            #expect(snapshot.participantIDs.count == 4)
            #expect(snapshot.links.count == 3)
            #expect(snapshot.isLocallyComplete)
        }

        // Every candidate edge was created once, with outbound RTP disabled,
        // then enabled on that exact object only after the signed membership
        // commit. No replacement transport was constructed during promotion.
        for admission in room.admissionEvidence {
            #expect(admission.preCommitEndpointTokens.count == admission.memberCount * 2)
            #expect(admission.preCommitEndpointTokens == admission.postCommitEndpointTokens)
            #expect(admission.initialOutboundMediaStates == [false])
            #expect(admission.outboundEnableHistories.allSatisfy { $0 == [true] })
            #expect(admission.preCommitSentControlMessageCount == 0)
        }

        await room.close()
    }

    @Test(
        "four symmetric runtimes replicate independent state isolate a slow peer and remove without ghosts"
    )
    func fourParticipantRuntimeReplicationAndCleanup() async throws {
        let room = try await V3AcceptanceRoom.bootstrapFourParticipants()
        try await room.startRuntimes()

        try await v3Eventually("all runtimes locally complete") {
            try await room.runtimeSnapshots().allSatisfy {
                $0.isLocallyComplete
            }
        }

        // Media callbacks deliberately arrived while every candidate edge was
        // quarantined. Runtime startup must replay receiver state exactly once,
        // while the invalid pre-commit room-control payload must never surface.
        try await v3Eventually("pre-commit audio tracks replayed") {
            let snapshots = try await room.runtimeSnapshots()
            return snapshots.allSatisfy {
                $0.audioTrackIDs.count == 3
            }
        }
        for recorder in room.runtimeEventRecorders.values {
            #expect(recorder.failureCount() == 0)
            #expect(recorder.remoteTrackAvailabilityCount() == 3)
        }

        await room.wire.resetDeliveredControlRecords()
        for participant in room.participants {
            let runtime = try #require(room.runtimes[participant.participantID])
            try await runtime.publishLocalSources([
                try room.source(ownedBy: participant.participantID)
            ])
        }

        try await v3Eventually("four source snapshots replicated") {
            let snapshots = try await room.runtimeSnapshots()
            return snapshots.allSatisfy {
                $0.sourceSnapshots.count == 4
                    && $0.sourceSnapshots.values.allSatisfy {
                        $0.sources.count == 1
                    }
            }
        }
        #expect(
            await room.wire.deliveredControlCount(matching: .sourceSnapshot)
                == 12
        )

        for (index, participant) in room.participants.enumerated() {
            let runtime = try #require(room.runtimes[participant.participantID])
            try await runtime.broadcastCollaboration(
                try room.pointerEvent(
                    participantIndex: index,
                    sourceOwnerIndex: index
                )
            )
        }
        try await v3Eventually("four collaboration pointers replicated") {
            let snapshots = try await room.runtimeSnapshots()
            return snapshots.allSatisfy { snapshot in
                snapshot.collaboration.count == 4
                    && snapshot.collaboration.values.allSatisfy {
                        $0.pointers.count == 1
                    }
            }
        }
        #expect(
            await room.wire.deliveredControlCount(matching: .collaboration)
                == 12
        )

        // Audio controls are receiver-local and participant-scoped.
        let first = room.participants[0].participantID
        let second = room.participants[1].participantID
        let third = room.participants[2].participantID
        let firstRuntime = try #require(room.runtimes[first])
        try await firstRuntime.setParticipantAudioEnabled(
            false,
            participantID: second
        )
        try await firstRuntime.setParticipantVolume(
            0.35,
            participantID: second
        )
        let firstToSecond = try #require(
            await room.factories[first]?.transport(for: second)
        )
        let firstToThird = try #require(
            await room.factories[first]?.transport(for: third)
        )
        #expect(await firstToSecond.audioEnabledHistory() == [false])
        #expect(await firstToSecond.audioVolumeHistory() == [0.35])
        #expect(await firstToThird.audioEnabledHistory().isEmpty)
        #expect(await firstToThird.audioVolumeHistory().isEmpty)

        // One slow/failing edge cannot delay healthy peers receiving the next
        // complete source revision.
        let fourth = room.participants[3].participantID
        let slow = try #require(
            await room.factories[first]?.transport(for: fourth)
        )
        await slow.setNextControlSend(
            delay: .milliseconds(300),
            shouldFail: true
        )
        let secondRevision = Task {
            try await firstRuntime.publishLocalSources([
                try room.source(ownedBy: first, titleSuffix: "revision-2")
            ])
        }
        try await v3Eventually(
            "healthy peers receive source revision",
            timeout: .milliseconds(180)
        ) {
            guard
                let secondSnapshot =
                    await room.runtimes[second]?.snapshot()
                        .sourceSnapshots[first],
                let thirdSnapshot =
                    await room.runtimes[third]?.snapshot()
                        .sourceSnapshots[first]
            else { return false }
            return secondSnapshot.sourceRevision.rawValue == 2
                && thirdSnapshot.sourceRevision.rawValue == 2
        }
        #expect(!secondRevision.isCancelled)
        try await secondRevision.value
        #expect(
            await room.runtimes[fourth]?.snapshot()
                .sourceSnapshots[first]?.sourceRevision.rawValue == 1
        )

        try await room.removeParticipant(at: 3)
        try await v3Eventually("removed participant leaves no replicated state") {
            let retained = try await room.runtimeSnapshots(
                participantIDs: Set(room.participants.prefix(3).map(\.participantID))
            )
            return retained.allSatisfy { snapshot in
                snapshot.signedMembership.snapshot.participants.count == 3
                    && snapshot.links.links.count == 2
                    && snapshot.sourceSnapshots[fourth] == nil
                    && snapshot.audioTrackIDs[fourth] == nil
                    && !snapshot.collaboration.keys.contains {
                        $0.ownerParticipantID == fourth
                    }
            }
        }
        #expect(await room.wire.openEndpointCount(involving: fourth) == 0)
        #expect(await room.wire.closedEndpointCount(involving: fourth) == 6)

        await room.close()
        #expect(await room.wire.openEndpointCount() == 0)
    }

    @Test(
        "leader departure yields a successor invite while crash paths require quorum"
    )
    func successionReplacementInviteAndCrashSafety() async throws {
        let room = try await V3AcceptanceRoom.bootstrapFourParticipants()
        let result = try room.performGracefulCreatorSuccession()

        #expect(result.departingLeaderWasRemoved)
        #expect(result.successorBecameLeader)
        #expect(result.successorRequestedNewInvite)
        #expect(result.nextTerm.rawValue == 2)

        // A freshly allocated route is accepted by the successor under the
        // preserved founding authority. It is not inherited from the departed
        // creator and is not an old host/viewer upgrade route.
        let replacementProof = room.route(number: 0x44)
        #expect(!room.routeProofs.contains(replacementProof))
        let replacement = try room.replacementParticipant()
        let successorBootstrap = try MeshParticipantBootstrapCoordinator(
            memberContext: result.successorContext,
            rendezvousProof: replacementProof,
            send: { _, _ in }
        )
        let hello = try ClipLiveShareSignedNativeV3BootstrapHello(
            signing: .init(
                sessionID: room.sessionID,
                participantID: replacement.participant.participantID,
                identity: replacement.participant.identity,
                displayName: replacement.participant.displayName,
                rendezvousProof: replacementProof,
                issuedAt: room.time(30),
                expiresAt: room.time(90)
            ),
            with: replacement.signer
        )
        try await successorBootstrap.receive(
            .hello(hello),
            from: replacement.participant.participantID,
            at: room.time(30)
        )
        #expect((await successorBootstrap.snapshot()).phase == .awaitingApproval)

        let two = try V3LifecycleFixture(participantCount: 2)
        var loneSurvivor = try two.coordinator(for: 1)
        let locked = try loneSurvivor.beginUnexpectedLeaderLoss(
            reachableParticipantIDs: [two.participants[1].participantID],
            at: two.time(10)
        )
        #expect(locked == [.phaseChanged(.leaderlessLocked)])
        #expect(loneSurvivor.phase == .leaderlessLocked)

        let four = try V3LifecycleFixture(participantCount: 4)
        var candidate = try four.coordinator(for: 1)
        var voterA = try four.coordinator(for: 2)
        var voterB = try four.coordinator(for: 3)
        let minority: Set = [
            four.participants[1].participantID,
            four.participants[2].participantID,
        ]
        _ = try candidate.beginUnexpectedLeaderLoss(
            reachableParticipantIDs: minority,
            at: four.time(10)
        )
        #expect(candidate.phase == .leaderlessLocked)

        let majority = minority.union([four.participants[3].participantID])
        let proposal = try #require(
            v3Proposal(
                in: candidate.beginUnexpectedLeaderLoss(
                    reachableParticipantIDs: majority,
                    at: four.time(20)
                )
            )
        )
        _ = try voterA.beginUnexpectedLeaderLoss(
            reachableParticipantIDs: majority,
            at: four.time(20)
        )
        _ = try voterB.beginUnexpectedLeaderLoss(
            reachableParticipantIDs: majority,
            at: four.time(20)
        )
        let voteA = try #require(
            v3Vote(
                in: voterA.receiveLeadershipProposal(
                    proposal,
                    at: four.time(20)
                )
            )
        )
        let voteB = try #require(
            v3Vote(
                in: voterB.receiveLeadershipProposal(
                    proposal,
                    at: four.time(20)
                )
            )
        )
        #expect(
            v3Certificate(
                in: try candidate.receiveLeadershipVote(
                    voteA,
                    at: four.time(20)
                )
            ) == nil
        )
        let certificate = try #require(
            v3Certificate(
                in: candidate.receiveLeadershipVote(
                    voteB,
                    at: four.time(20)
                )
            )
        )
        let recoveredMembership = try candidate.makeSuccessorMembership(
            for: certificate,
            retainingParticipantIDs: majority,
            at: four.time(30)
        )
        let recovered = try candidate.commitLeadershipTransition(
            certificate: certificate,
            successorMembership: recoveredMembership,
            at: four.time(30)
        )
        #expect(candidate.isLocalLeader)
        #expect(recovered.contains(.newInviteRequired))

        await room.close()
    }

    @Test("the app Live Share surface is a native-v3 clean slate")
    func cleanSlateJourneyHasNoLegacySessionPath() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let liveShareRoot = repositoryRoot.appendingPathComponent(
            "Clip/LiveShare",
            isDirectory: true
        )
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: liveShareRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        var sourceFiles = enumerator.compactMap { value -> URL? in
            guard let url = value as? URL,
                  url.pathExtension == "swift" else { return nil }
            return url
        }
        sourceFiles.append(
            repositoryRoot.appendingPathComponent(
                "Clip/App/ApplicationCoordinator.swift"
            )
        )
        sourceFiles.append(
            repositoryRoot.appendingPathComponent(
                "Clip/UI/MenuBarPopoverView.swift"
            )
        )

        let removedFileNames: Set<String> = [
            "LiveShareCoordinator.swift",
            "LiveShareCoordinatorPolicy.swift",
            "NativeLiveShareViewerCoordinator.swift",
            "NativeViewerV1ControlState.swift",
            "NativeFriendModel.swift",
            "NativeFriendPresenceMonitor.swift",
            "NativeFriendRepository.swift",
        ]
        let forbidden = [
            "ClipLiveShareV1ViewerSession",
            "ClipLiveShareNativeFriendViewerSession",
            "ClipLiveShareNativeV2",
            "NativeLiveShareViewerCoordinator",
            "NativeViewerV1ControlState",
            "NativeFriendPresenceMonitor",
            "NativeFriendRepository",
            "publishNativeV3BootstrapRouteIfReady",
            "authenticatedNativeV2Upgrade",
            "legacyAdmissionAuthenticated",
            "mirrorLegacy",
            "handoffToMesh",
        ]

        for sourceURL in sourceFiles {
            #expect(
                !removedFileNames.contains(sourceURL.lastPathComponent),
                "Removed Live Share file still exists: \(sourceURL.lastPathComponent)"
            )
            let source = try String(
                contentsOf: sourceURL,
                encoding: .utf8
            )
            for symbol in forbidden {
                #expect(
                    !source.contains(symbol),
                    "Clean-slate v3 app still references \(symbol) in \(sourceURL.path)"
                )
            }
        }
    }
}

private struct V3AdmissionEvidence: Sendable {
    let memberCount: Int
    let preCommitEndpointTokens: Set<UUID>
    let postCommitEndpointTokens: Set<UUID>
    let initialOutboundMediaStates: Set<Bool>
    let outboundEnableHistories: [[Bool]]
    let preCommitSentControlMessageCount: Int
}

private enum V3ControlKind: Hashable, Sendable {
    case sourceSnapshot
    case collaboration
    case other
}

private struct V3SuccessionResult {
    let departingLeaderWasRemoved: Bool
    let successorBecameLeader: Bool
    let successorRequestedNewInvite: Bool
    let nextTerm: ClipLiveShareNativeV3LeadershipTerm
    let successorContext: MeshParticipantBootstrapLaunchContext
}

private struct V3ReplacementParticipant {
    let signer: ClipLiveShareSoftwareIdentitySigner
    let participant: ClipLiveShareNativeV3Participant
}

private final class V3AcceptanceRoom: @unchecked Sendable {
    let sessionID: ClipLiveShareSessionID
    let origin: ClipLiveShareNativeTimestamp
    let signers: [ClipLiveShareSoftwareIdentitySigner]
    let participants: [ClipLiveShareNativeV3Participant]
    let wire: V3InProcessWire

    private(set) var routeProofs: [ClipLiveShareNativeV3RendezvousProof] = []
    private(set) var bootstrapKinds: Set<V3BootstrapKind> = []
    private(set) var admissionEvidence: [V3AdmissionEvidence] = []
    private(set) var contexts:
        [ClipLiveShareNativeV3ParticipantID:
            MeshParticipantBootstrapLaunchContext] = [:]
    private(set) var managers:
        [ClipLiveShareNativeV3ParticipantID:
            ClipLiveShareNativeV3MeshPeerLinkManager] = [:]
    private(set) var factories:
        [ClipLiveShareNativeV3ParticipantID: V3InProcessTransportFactory] = [:]
    private(set) var adapters:
        [ClipLiveShareNativeV3ParticipantID:
            MeshParticipantProvisionalPeerLinkAdapter] = [:]
    private(set) var runtimes:
        [ClipLiveShareNativeV3ParticipantID: MeshParticipantRuntime] = [:]
    private(set) var runtimeEventRecorders:
        [ClipLiveShareNativeV3ParticipantID: V3RuntimeEventRecorder] = [:]

    private init() throws {
        let fixtureSessionID = try ClipLiveShareSessionID(
            rawValue: "native-v3-mesh-integration"
        )
        let fixtureOrigin = try ClipLiveShareNativeTimestamp(
            date: Date().addingTimeInterval(-20)
        )
        let fixtureSigners = try (1...5).map { byte in
            try ClipLiveShareSoftwareIdentitySigner(
                rawRepresentation: Data(repeating: UInt8(byte), count: 32)
            )
        }
        let fixtureParticipants: [ClipLiveShareNativeV3Participant] =
            try fixtureSigners.prefix(4)
            .enumerated().map { index, signer in
            try ClipLiveShareNativeV3Participant(
                participantID: ClipLiveShareNativeV3ParticipantID(
                    bytes: Data(
                        repeating: UInt8(0x20 + index * 0x10),
                        count: ClipLiveShareNativeV3.participantIDByteCount
                    )
                ),
                identity: signer.publicKey,
                displayName: "Mesh \(index + 1)",
                capabilities: ClipLiveShareNativeV3Capabilities.current
            )
        }
        sessionID = fixtureSessionID
        origin = fixtureOrigin
        signers = fixtureSigners
        participants = fixtureParticipants
        wire = V3InProcessWire()
    }

    static func bootstrapFourParticipants() async throws -> V3AcceptanceRoom {
        let room = try V3AcceptanceRoom()
        let creator = room.participants[0]
        let genesis = try MeshParticipantBootstrapCoordinator.creatorGenesis(
            sessionID: room.sessionID,
            creator: creator,
            creatorSigner: room.signers[0],
            at: room.time(0)
        )
        room.contexts[creator.participantID] = genesis
        try await room.installParticipant(
            index: 0,
            committedParticipantIDs: [creator.participantID]
        )

        for candidateIndex in 1..<4 {
            do {
                try await room.admit(candidateIndex: candidateIndex)
            } catch {
                throw V3AcceptanceTaggedError(
                    stage: "admit participant \(candidateIndex + 1)",
                    underlying: String(describing: error)
                )
            }
        }
        return room
    }

    func time(_ seconds: Int64) -> ClipLiveShareNativeTimestamp {
        try! origin.adding(milliseconds: seconds * 1_000)
    }

    func route(number: UInt8) -> ClipLiveShareNativeV3RendezvousProof {
        .init(
            sessionID: sessionID,
            rendezvousID: try! .init(
                bytes: Data(repeating: number, count: 32)
            ),
            routeID: try! .init(
                bytes: Data(
                    repeating: number,
                    count: 16
                )
            ),
            foundingCreatorIdentity: participants[0].identity,
            admissionCapability: try! .init(
                bytes: Data(repeating: number, count: 32)
            )
        )
    }

    func replacementParticipant() throws -> V3ReplacementParticipant {
        let signer = signers[4]
        return try .init(
            signer: signer,
            participant: .init(
                participantID: .init(
                    bytes: Data(
                        repeating: 0x70,
                        count: ClipLiveShareNativeV3.participantIDByteCount
                    )
                ),
                identity: signer.publicKey,
                displayName: "Replacement",
                capabilities: .current
            )
        )
    }

    func source(
        ownedBy owner: ClipLiveShareNativeV3ParticipantID,
        titleSuffix: String = "initial"
    ) throws -> ClipLiveShareNativeV3PublishedSource {
        let index = participants.firstIndex {
            $0.participantID == owner
        } ?? 0
        let sourceID = try ClipLiveShareSourceInstanceID(
            bytes: Data(repeating: UInt8(0x90 + index), count: 16)
        )
        let stream = try ClipLiveShareStreamDescriptor(
            id: .init(rawValue: "mesh-\(index)-\(titleSuffix)"),
            mediaTrackID: .init(rawValue: "mesh-track-\(index)"),
            active: true,
            focused: true,
            appName: "Fixture \(index + 1)",
            windowName: "Source \(index + 1) \(titleSuffix)",
            width: 640,
            height: 360,
            order: 0,
            sourcePointWidth: 640,
            sourcePointHeight: 360
        )
        return try .init(
            key: .init(
                ownerParticipantID: owner,
                sourceInstanceID: sourceID
            ),
            descriptor: .init(
                sourceInstanceID: sourceID,
                stream: stream
            )
        )
    }

    func pointerEvent(
        participantIndex: Int,
        sourceOwnerIndex: Int
    ) throws -> ClipLiveShareNativeV3CollaborationEvent {
        let participant = participants[participantIndex]
        let owner = participants[sourceOwnerIndex]
        let sourceKey = try source(ownedBy: owner.participantID).key
        return .pointer(
            .init(
                context: try .init(
                    sessionID: sessionID,
                    participantID: participant.participantID,
                    sourceKey: sourceKey,
                    sequence: 1,
                    sentAt: .init(date: Date())
                ),
                position: try .init(
                    x: Double(participantIndex + 1) / 5,
                    y: Double(sourceOwnerIndex + 1) / 5
                )
            )
        )
    }

    func startRuntimes() async throws {
        for participant in participants {
            let participantID = participant.participantID
            let manager = try #require(managers[participantID])
            let context = try #require(contexts[participantID])
            let runtime = MeshParticipantRuntime(
                context: .init(context),
                manager: manager,
                bootstrap: V3InertBootstrapRoute()
            )
            let recorder = V3RuntimeEventRecorder()
            let events = await runtime.events()
            recorder.consume(events)
            runtimes[participantID] = runtime
            runtimeEventRecorders[participantID] = recorder
            try await runtime.start(at: time(4))
        }

        try await v3Eventually {
            try await self.runtimeSnapshots().allSatisfy {
                $0.isLocallyComplete
            }
        }
    }

    func runtimeSnapshots(
        participantIDs: Set<ClipLiveShareNativeV3ParticipantID>? = nil
    ) async throws -> [MeshParticipantRuntimeSnapshot] {
        let requested = participantIDs ?? Set(runtimes.keys)
        var values: [MeshParticipantRuntimeSnapshot] = []
        for participantID in requested.sorted() {
            let runtime = try #require(runtimes[participantID])
            values.append(await runtime.snapshot())
        }
        return values
    }

    func removeParticipant(at index: Int) async throws {
        let removed = participants[index].participantID
        let retainedParticipants = Array(participants.prefix(index))
        let leaderID = participants[0].participantID
        let leaderContext = try #require(contexts[leaderID])
        var lifecycle = try ClipLiveShareNativeV3RoomLifecycleCoordinator(
            localParticipantID: leaderID,
            localSigner: signers[0],
            authorityChain: leaderContext.authorityChain,
            expectedSessionID: sessionID,
            expectedFoundingCreatorIdentity: participants[0].identity,
            establishedPeerParticipantIDs:
                Set(participants.dropFirst().map(\.participantID)),
            at: time(5)
        )
        let nextMembership = try lifecycle.makeMembershipSnapshot(
            participants: retainedParticipants,
            at: time(6)
        )
        _ = try lifecycle.commitMembershipSnapshot(
            nextMembership,
            at: time(6)
        )
        let nextAuthority = lifecycle.authorityChain

        for participant in retainedParticipants {
            let participantID = participant.participantID
            let context = try #require(contexts[participantID])
            let peers = nextMembership.snapshot.participantIDs
                .subtracting([participantID])
            try await runtimes[participantID]?.commitMembership(
                nextMembership,
                validatedAuthorityChain: nextAuthority,
                verifiedNonces: context.verifiedPeerTransportNonces.filter {
                    peers.contains($0.key)
                },
                bootstrapAdmissionDigests:
                    context.bootstrapAdmissionDigests.filter {
                        peers.contains($0.key)
                    },
                at: time(6)
            )
        }
        await runtimes[removed]?.close()
        runtimes[removed] = nil
        runtimeEventRecorders[removed]?.cancel()
        runtimeEventRecorders[removed] = nil
    }

    func performGracefulCreatorSuccession() throws -> V3SuccessionResult {
        let leaderID = participants[0].participantID
        let successorID = participants[1].participantID
        var leader = try lifecycle(for: 0)
        var successor = try lifecycle(for: 1)
        var third = try lifecycle(for: 2)
        var fourth = try lifecycle(for: 3)

        let transfer = try leader.beginGracefulLeaderLeave(at: time(10))
        let request = try #require(v3TransferRequest(in: transfer))
        let successorEvents = try successor.receiveLeadershipTransferRequest(
            request,
            at: time(10)
        )
        _ = try third.receiveLeadershipTransferRequest(
            request,
            at: time(10)
        )
        _ = try fourth.receiveLeadershipTransferRequest(
            request,
            at: time(10)
        )
        let proposal = try #require(v3Proposal(in: successorEvents))
        let leaderVote = try #require(
            v3Vote(
                in: leader.receiveLeadershipProposal(
                    proposal,
                    at: time(10)
                )
            )
        )
        let thirdVote = try #require(
            v3Vote(
                in: third.receiveLeadershipProposal(
                    proposal,
                    at: time(10)
                )
            )
        )
        let fourthVote = try #require(
            v3Vote(
                in: fourth.receiveLeadershipProposal(
                    proposal,
                    at: time(10)
                )
            )
        )
        _ = try successor.receiveLeadershipVote(
            leaderVote,
            at: time(10)
        )
        _ = try successor.receiveLeadershipVote(
            thirdVote,
            at: time(10)
        )
        let certificate = try #require(
            v3Certificate(
                in: successor.receiveLeadershipVote(
                    fourthVote,
                    at: time(10)
                )
            )
        )
        let retainedIDs = Set(participants.dropFirst().map(\.participantID))
        let membership = try successor.makeSuccessorMembership(
            for: certificate,
            retainingParticipantIDs: retainedIDs,
            at: time(20)
        )
        let leaderCommit = try leader.commitLeadershipTransition(
            certificate: certificate,
            successorMembership: membership,
            at: time(20)
        )
        let successorCommit = try successor.commitLeadershipTransition(
            certificate: certificate,
            successorMembership: membership,
            at: time(20)
        )
        _ = try third.commitLeadershipTransition(
            certificate: certificate,
            successorMembership: membership,
            at: time(20)
        )
        _ = try fourth.commitLeadershipTransition(
            certificate: certificate,
            successorMembership: membership,
            at: time(20)
        )

        let prior = try #require(contexts[successorID])
        let peers = retainedIDs.subtracting([successorID])
        let successorContext = MeshParticipantBootstrapLaunchContext(
            localParticipantID: successorID,
            localIdentitySigner: signers[1],
            signedMembership: membership,
            authorityChain: successor.authorityChain,
            expectedFoundingCreatorIdentity: participants[0].identity,
            bootstrapAdmissionDigests:
                prior.bootstrapAdmissionDigests.filter {
                    peers.contains($0.key)
                },
            verifiedPeerTransportNonces:
                prior.verifiedPeerTransportNonces.filter {
                    peers.contains($0.key)
                },
            admissionPolicy: .productDefault
        )
        return .init(
            departingLeaderWasRemoved:
                leaderID != successorID
                    && leaderCommit.contains(.localParticipantRemoved),
            successorBecameLeader: successor.isLocalLeader,
            successorRequestedNewInvite:
                successorCommit.contains(.newInviteRequired),
            nextTerm: successor.currentTerm,
            successorContext: successorContext
        )
    }

    func close() async {
        for runtime in runtimes.values {
            await runtime.close()
        }
        for recorder in runtimeEventRecorders.values {
            recorder.cancel()
        }
        for adapter in adapters.values {
            await adapter.close()
        }
        for manager in managers.values {
            await manager.close()
        }
    }

    private func lifecycle(
        for index: Int
    ) throws -> ClipLiveShareNativeV3RoomLifecycleCoordinator {
        let participant = participants[index]
        let context = try #require(contexts[participant.participantID])
        return try .init(
            localParticipantID: participant.participantID,
            localSigner: signers[index],
            authorityChain: context.authorityChain,
            expectedSessionID: sessionID,
            expectedFoundingCreatorIdentity: participants[0].identity,
            establishedPeerParticipantIDs:
                Set(participants.map(\.participantID))
                .subtracting([participant.participantID]),
            at: time(5)
        )
    }

    private func installParticipant(
        index: Int,
        committedParticipantIDs:
            Set<ClipLiveShareNativeV3ParticipantID>
    ) async throws {
        let participant = participants[index]
        let factory = V3InProcessTransportFactory(
            localParticipantID: participant.participantID,
            wire: wire
        )
        let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
            localParticipantID: participant.participantID,
            transportFactory: factory
        )
        let adapter = try MeshParticipantProvisionalPeerLinkAdapter(
            localParticipantID: participant.participantID,
            localSigner: signers[index],
            committedParticipantIDs: committedParticipantIDs,
            manager: manager
        )
        try await manager.reconcileParticipants(committedParticipantIDs)
        factories[participant.participantID] = factory
        managers[participant.participantID] = manager
        adapters[participant.participantID] = adapter
    }

    private func admit(candidateIndex: Int) async throws {
        let candidate = participants[candidateIndex]
        let existingIDs = Set(participants.prefix(candidateIndex).map(\.participantID))
        try await installParticipant(
            index: candidateIndex,
            committedParticipantIDs: [candidate.participantID]
        )
        let proof = route(number: UInt8(candidateIndex))
        routeProofs.append(proof)
        let bus = V3BootstrapBus()
        let failureRecorder = V3StringRecorder()
        var coordinators:
            [ClipLiveShareNativeV3ParticipantID:
                MeshParticipantBootstrapCoordinator] = [:]
        var holders:
            [ClipLiveShareNativeV3ParticipantID:
                V3BootstrapCoordinatorHolder] = [:]

        for participant in participants.prefix(candidateIndex) {
            let participantID = participant.participantID
            let context = try #require(contexts[participantID])
            let holder = V3BootstrapCoordinatorHolder()
            let adapter = try #require(adapters[participantID])
            let coordinator = try MeshParticipantBootstrapCoordinator(
                memberContext: context,
                rendezvousProof:
                    participantID
                        == context.signedMembership.snapshot.leaderParticipantID
                    ? proof : nil,
                send: bus.sender(from: participantID),
                pairHooks: adapter.makePairHooks()
            )
            await holder.set(coordinator)
            await adapter.installCallbacks(
                callbacks(holder: holder, failures: failureRecorder)
            )
            holders[participantID] = holder
            coordinators[participantID] = coordinator
        }

        let candidateID = candidate.participantID
        let candidateHolder = V3BootstrapCoordinatorHolder()
        let candidateAdapter = try #require(adapters[candidateID])
        let candidateCoordinator = try MeshParticipantBootstrapCoordinator(
            candidateSessionID: sessionID,
            candidate: candidate,
            candidateSigner: signers[candidateIndex],
            admissionLeaderParticipantID: participants[0].participantID,
            expectedFoundingCreatorIdentity: participants[0].identity,
            rendezvousProof: proof,
            send: bus.sender(from: candidateID),
            pairHooks: candidateAdapter.makePairHooks()
        )
        await candidateHolder.set(candidateCoordinator)
        await candidateAdapter.installCallbacks(
            callbacks(holder: candidateHolder, failures: failureRecorder)
        )
        holders[candidateID] = candidateHolder
        coordinators[candidateID] = candidateCoordinator
        let coordinatorsByID = coordinators

        do {
            try await candidateCoordinator.requestJoin(
                at: time(Int64(candidateIndex))
            )
        } catch {
            throw tagged(error, stage: "request join")
        }
        do {
            try await drain(
                bus: bus,
                coordinators: coordinatorsByID,
                at: time(Int64(candidateIndex)),
                until: {
                    await coordinatorsByID[
                        self.participants[0].participantID
                    ]?.snapshot().phase == .awaitingApproval
                }
            )
        } catch {
            throw tagged(error, stage: "deliver join for approval")
        }
        do {
            try await coordinatorsByID[participants[0].participantID]?
                .approveAdmission(at: time(Int64(candidateIndex)))
        } catch {
            throw tagged(error, stage: "approve admission")
        }
        let expectedEndpoints = (candidateIndex + 1) * candidateIndex
        do {
            try await drain(
                bus: bus,
                coordinators: coordinatorsByID,
                at: time(Int64(candidateIndex)),
                until: {
                    await self.wire.endpointCount() == expectedEndpoints
                }
            )
        } catch {
            throw tagged(error, stage: "prove identity and prepare links")
        }

        let provisional = await wire.transports(involving: candidateID)
        let tokensBefore = Set(provisional.map(\.token))
        #expect(provisional.count == candidateIndex * 2)
        #expect(
            provisional.allSatisfy {
                !$0.configuration.outboundMediaInitiallyEnabled
            }
        )
        for transport in provisional {
            await transport.emitPreCommitArtifacts(
                trackSuffix: "\(candidateIndex)"
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        let sentBefore = await provisional.asyncSum {
            await $0.sentControlMessageCount()
        }

        await wire.openAllPending()
        do {
            try await drain(
                bus: bus,
                coordinators: coordinatorsByID,
                at: time(Int64(candidateIndex + 1)),
                until: {
                    for coordinator in coordinatorsByID.values
                        where await coordinator.launchContext() == nil {
                        return false
                    }
                    return true
                }
            )
        } catch {
            throw tagged(error, stage: "commit promoted links")
        }
        let tokensAfter = Set(
            await wire.transports(involving: candidateID).map(\.token)
        )
        let histories = await provisional.asyncMap {
            await $0.outboundMediaEnabledHistory()
        }
        admissionEvidence.append(
            .init(
                memberCount: candidateIndex,
                preCommitEndpointTokens: tokensBefore,
                postCommitEndpointTokens: tokensAfter,
                initialOutboundMediaStates:
                    Set(provisional.map {
                        $0.configuration.outboundMediaInitiallyEnabled
                    }),
                outboundEnableHistories: histories,
                preCommitSentControlMessageCount: sentBefore
            )
        )

        for (participantID, coordinator) in coordinatorsByID {
            guard let launchContext = await coordinator.launchContext() else {
                throw V3AcceptanceError.coordinatorUnavailable
            }
            contexts[participantID] = launchContext
        }
        bootstrapKinds.formUnion(await bus.kinds())
        #expect(await failureRecorder.values().isEmpty)
        #expect(
            Set(contexts.keys)
                == existingIDs.union([candidate.participantID])
        )
    }

    private func tagged(
        _ error: any Error,
        stage: String
    ) -> V3AcceptanceTaggedError {
        V3AcceptanceTaggedError(
            stage: stage,
            underlying: String(describing: error)
        )
    }

    private func callbacks(
        holder: V3BootstrapCoordinatorHolder,
        failures: V3StringRecorder
    ) -> MeshParticipantProvisionalPeerLinkCallbacks {
        .init(
            sendRelay: { payload, participantID in
                try await holder.coordinator().relayPairPayload(
                    payload,
                    to: participantID
                )
            },
            markReady: { participantID, now in
                try await holder.coordinator().markPeerLinkReady(
                    with: participantID,
                    at: now
                )
            },
            reportFailure: { message in
                Task { await failures.append(message) }
            }
        )
    }

    private func drain(
        bus: V3BootstrapBus,
        coordinators:
            [ClipLiveShareNativeV3ParticipantID:
                MeshParticipantBootstrapCoordinator],
        at now: ClipLiveShareNativeTimestamp,
        until condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            while let message = await bus.next() {
                let receiver = try #require(coordinators[message.to])
                do {
                    try await receiver.receive(
                        message.envelope,
                        from: message.from,
                        at: now
                    )
                } catch {
                    let sender = participants.firstIndex {
                        $0.participantID == message.from
                    }.map { $0 + 1 } ?? 0
                    let receiver = participants.firstIndex {
                        $0.participantID == message.to
                    }.map { $0 + 1 } ?? 0
                    throw tagged(
                        error,
                        stage:
                            "\(V3BootstrapKind(message.envelope)) "
                            + "\(sender)->\(receiver)"
                    )
                }
            }
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out draining native-v3 bootstrap")
    }
}

private enum V3BootstrapKind: Hashable, Sendable {
    case hello
    case provisionalAdmission
    case relay
    case linkReadiness
    case admitted
    case rejected

    init(_ envelope: ClipLiveShareNativeV3BootstrapEnvelope) {
        switch envelope {
        case .hello:
            self = .hello
        case .provisionalAdmission:
            self = .provisionalAdmission
        case .relay:
            self = .relay
        case .linkReadiness:
            self = .linkReadiness
        case .admitted:
            self = .admitted
        case .rejected:
            self = .rejected
        }
    }
}

private struct V3BootstrapMessage: Sendable {
    let envelope: ClipLiveShareNativeV3BootstrapEnvelope
    let from: ClipLiveShareNativeV3ParticipantID
    let to: ClipLiveShareNativeV3ParticipantID
}

private actor V3BootstrapBus {
    private var pending: [V3BootstrapMessage] = []
    private var observedKinds: Set<V3BootstrapKind> = []

    nonisolated func sender(
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) -> MeshParticipantBootstrapCoordinator.RendezvousSend {
        { [self] envelope, destination in
            await enqueue(
                .init(
                    envelope: envelope,
                    from: participantID,
                    to: destination
                )
            )
        }
    }

    func enqueue(_ message: V3BootstrapMessage) {
        observedKinds.insert(.init(message.envelope))
        pending.append(message)
    }

    func next() -> V3BootstrapMessage? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    func kinds() -> Set<V3BootstrapKind> {
        observedKinds
    }
}

private actor V3BootstrapCoordinatorHolder {
    private var value: MeshParticipantBootstrapCoordinator?

    func set(_ coordinator: MeshParticipantBootstrapCoordinator) {
        value = coordinator
    }

    func coordinator() throws -> MeshParticipantBootstrapCoordinator {
        guard let value else {
            throw V3AcceptanceError.coordinatorUnavailable
        }
        return value
    }
}

private enum V3AcceptanceError: Error {
    case coordinatorUnavailable
    case missingPeerTransport
    case injectedSendFailure
}

private struct V3AcceptanceTaggedError: Error, CustomStringConvertible {
    let stage: String
    let underlying: String

    var description: String {
        "\(stage): \(underlying)"
    }
}

private actor V3StringRecorder {
    private var storage: [String] = []

    func append(_ value: String) {
        storage.append(value)
    }

    func values() -> [String] {
        storage
    }
}

private struct V3DirectedEndpointKey: Hashable, Sendable {
    let local: ClipLiveShareNativeV3ParticipantID
    let remote: ClipLiveShareNativeV3ParticipantID
}

private struct V3DeliveredControlRecord: Sendable {
    let from: ClipLiveShareNativeV3ParticipantID
    let to: ClipLiveShareNativeV3ParticipantID
    let kind: V3ControlKind
}

private actor V3InProcessWire {
    private var endpoints:
        [V3DirectedEndpointKey: V3InProcessTransport] = [:]
    private var allTransports: [UUID: V3InProcessTransport] = [:]
    private var openedPairs: Set<ClipLiveShareNativeV3PeerLinkKey> = []
    private var deliveredControl: [V3DeliveredControlRecord] = []

    func register(_ transport: V3InProcessTransport) {
        let configuration = transport.configuration
        allTransports[transport.token] = transport
        endpoints[
            .init(
                local: configuration.localParticipantID,
                remote: configuration.remoteParticipantID
            )
        ] = transport
    }

    func unregister(_ transport: V3InProcessTransport) {
        let configuration = transport.configuration
        endpoints[
            .init(
                local: configuration.localParticipantID,
                remote: configuration.remoteParticipantID
            )
        ] = nil
    }

    func endpointCount() -> Int {
        endpoints.count
    }

    func uniquePeerLinkKeys() -> Set<ClipLiveShareNativeV3PeerLinkKey> {
        Set(allTransports.values.map(\.configuration.key))
    }

    func transports(
        involving participantID: ClipLiveShareNativeV3ParticipantID
    ) -> [V3InProcessTransport] {
        endpoints.values.filter {
            $0.configuration.key.contains(participantID)
        }
    }

    func openAllPending() async {
        let keys = Set(endpoints.values.map(\.configuration.key))
            .subtracting(openedPairs)
            .sorted()
        for key in keys {
            let lowerKey = V3DirectedEndpointKey(
                local: key.lowerParticipantID,
                remote: key.upperParticipantID
            )
            let upperKey = V3DirectedEndpointKey(
                local: key.upperParticipantID,
                remote: key.lowerParticipantID
            )
            guard
                let lower = endpoints[lowerKey],
                let upper = endpoints[upperKey]
            else { continue }
            openedPairs.insert(key)
            await lower.emit(.connectionStateChanged(.connected))
            await lower.emit(.controlChannelStateChanged(.open))
            await upper.emit(.connectionStateChanged(.connected))
            await upper.emit(.controlChannelStateChanged(.open))
        }
    }

    func deliverControl(
        _ data: Data,
        from: ClipLiveShareNativeV3ParticipantID,
        to: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        guard let destination = endpoints[.init(local: to, remote: from)] else {
            throw V3AcceptanceError.missingPeerTransport
        }
        let kind: V3ControlKind
        if let envelope = try? ClipLiveShareNativeV3ControlCodec.decode(data) {
            switch envelope {
            case .sourceSnapshot:
                kind = .sourceSnapshot
            case .collaboration:
                kind = .collaboration
            default:
                kind = .other
            }
        } else {
            kind = .other
        }
        deliveredControl.append(.init(from: from, to: to, kind: kind))
        await destination.receiveControl(data)
    }

    func deliveredControlCount(matching kind: V3ControlKind) -> Int {
        deliveredControl.count { $0.kind == kind }
    }

    func resetDeliveredControlRecords() {
        deliveredControl.removeAll(keepingCapacity: true)
    }

    func openEndpointCount(
        involving participantID:
            ClipLiveShareNativeV3ParticipantID? = nil
    ) async -> Int {
        var count = 0
        for transport in allTransports.values {
            if let participantID,
               !transport.configuration.key.contains(participantID) {
                continue
            }
            if await transport.closeCount() == 0 {
                count += 1
            }
        }
        return count
    }

    func closedEndpointCount(
        involving participantID: ClipLiveShareNativeV3ParticipantID
    ) async -> Int {
        var count = 0
        for transport in allTransports.values
            where transport.configuration.key.contains(participantID) {
            count += await transport.closeCount()
        }
        return count
    }
}

private actor V3InProcessTransportFactory:
    ClipLiveShareNativeV3PeerLinkTransportFactory
{
    private let localParticipantID: ClipLiveShareNativeV3ParticipantID
    private let wire: V3InProcessWire
    private var transports:
        [ClipLiveShareNativeV3ParticipantID: V3InProcessTransport] = [:]

    init(
        localParticipantID: ClipLiveShareNativeV3ParticipantID,
        wire: V3InProcessWire
    ) {
        self.localParticipantID = localParticipantID
        self.wire = wire
    }

    func makeTransport(
        configuration: ClipLiveShareNativeV3PeerLinkConfiguration
    ) -> any ClipLiveShareNativeV3PeerLinkTransport {
        precondition(configuration.localParticipantID == localParticipantID)
        let transport = V3InProcessTransport(
            configuration: configuration,
            wire: wire
        )
        transports[configuration.remoteParticipantID] = transport
        return transport
    }

    func transport(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> V3InProcessTransport? {
        transports[participantID]
    }
}

private actor V3InProcessTransport:
    ClipLiveShareNativeV3PeerLinkTransport
{
    nonisolated let configuration:
        ClipLiveShareNativeV3PeerLinkConfiguration
    nonisolated let token = UUID()

    private let wire: V3InProcessWire
    private var continuation:
        AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent>.Continuation?
    private var sentControl = 0
    private var outboundHistory: [Bool] = []
    private var audioEnabled: [Bool] = []
    private var audioVolumes: [Double] = []
    private var closes = 0
    private var nextSendDelay: Duration?
    private var failNextSend = false

    init(
        configuration: ClipLiveShareNativeV3PeerLinkConfiguration,
        wire: V3InProcessWire
    ) {
        self.configuration = configuration
        self.wire = wire
    }

    func events() -> AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ClipLiveShareNativeV3PeerLinkTransportEvent.self,
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation
        return stream
    }

    func start() async {
        await wire.register(self)
    }

    func requestNegotiation() {}
    func applyRemoteDescription(_: WebRTCSessionDescription) {}
    func addRemoteICECandidate(_: WebRTCICECandidate) {}

    func sendControlMessage(_ data: Data) async throws {
        if let delay = nextSendDelay {
            nextSendDelay = nil
            try await Task.sleep(for: delay)
        }
        if failNextSend {
            failNextSend = false
            throw V3AcceptanceError.injectedSendFailure
        }
        sentControl += 1
        try await wire.deliverControl(
            data,
            from: configuration.localParticipantID,
            to: configuration.remoteParticipantID
        )
    }

    func remoteVideoStream(
        for _: ClipLiveShareStreamDescriptor
    ) -> WebRTCRemoteVideoStream? {
        nil
    }

    func setOutboundMediaEnabled(_ enabled: Bool) {
        outboundHistory.append(enabled)
    }

    func updateSenderPolicy(_: WebRTCSenderPolicy) {}
    func updateVideoCodecPreference(_: WebRTCVideoCodec) {}

    func setRemoteParticipantAudioPlaybackEnabled(_ enabled: Bool) {
        audioEnabled.append(enabled)
    }

    func setRemoteParticipantAudioVolume(_ volume: Double) {
        audioVolumes.append(volume)
    }

    func restartICE() {}

    func statistics()
        -> ClipLiveShareNativeV3PeerLinkTransportStatistics
    {
        .init(capturedAt: Date(), route: .direct)
    }

    func close() async {
        guard closes == 0 else { return }
        closes = 1
        continuation?.finish()
        continuation = nil
        await wire.unregister(self)
    }

    func emit(_ event: ClipLiveShareNativeV3PeerLinkTransportEvent) {
        continuation?.yield(event)
    }

    func emitPreCommitArtifacts(trackSuffix: String) {
        continuation?.yield(
            .remoteVideoTrackAdded(
                try! .init(
                    rawValue:
                        "precommit-video-\(configuration.remoteParticipantID.rawValue)-\(trackSuffix)"
                )
            )
        )
        continuation?.yield(
            .remoteParticipantAudioAvailable(
                trackID:
                    "precommit-audio-\(configuration.remoteParticipantID.rawValue)"
            )
        )
        continuation?.yield(
            .controlMessageReceived(Data("precommit-room-control".utf8))
        )
    }

    func receiveControl(_ data: Data) {
        continuation?.yield(.controlMessageReceived(data))
    }

    func setNextControlSend(
        delay: Duration?,
        shouldFail: Bool
    ) {
        nextSendDelay = delay
        failNextSend = shouldFail
    }

    func sentControlMessageCount() -> Int {
        sentControl
    }

    func outboundMediaEnabledHistory() -> [Bool] {
        outboundHistory
    }

    func audioEnabledHistory() -> [Bool] {
        audioEnabled
    }

    func audioVolumeHistory() -> [Double] {
        audioVolumes
    }

    func closeCount() -> Int {
        closes
    }
}

private actor V3InertBootstrapRoute: MeshParticipantBootstrapRouting {
    private var continuation:
        AsyncStream<MeshParticipantBootstrapRouteEvent>.Continuation?

    func events() -> AsyncStream<MeshParticipantBootstrapRouteEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: MeshParticipantBootstrapRouteEvent.self,
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation
        return stream
    }

    func send(
        _: ClipLiveShareNativeV3BootstrapEnvelope,
        to _: ClipLiveShareNativeV3ParticipantID
    ) {}

    func close() {
        continuation?.finish()
        continuation = nil
    }
}

private final class V3RuntimeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []
    private var remoteTrackAvailability:
        [(ClipLiveShareNativeV3ParticipantID,
          ClipLiveShareMediaTrackID)] = []
    private var task: Task<Void, Never>?

    func consume(_ events: AsyncStream<MeshParticipantRuntimeEvent>) {
        task = Task { [weak self] in
            for await event in events {
                self?.record(event)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func failureCount() -> Int {
        lock.withLock { failures.count }
    }

    func remoteTrackAvailabilityCount() -> Int {
        lock.withLock { remoteTrackAvailability.count }
    }

    private func record(_ event: MeshParticipantRuntimeEvent) {
        lock.withLock {
            switch event {
            case let .failed(message):
                failures.append(message)
            case let .remoteVideoTrackChanged(
                participantID,
                mediaTrackID,
                isAvailable
            ):
                if isAvailable {
                    remoteTrackAvailability.append(
                        (participantID, mediaTrackID)
                    )
                }
            default:
                break
            }
        }
    }
}

private struct V3LifecycleFixture {
    let sessionID: ClipLiveShareSessionID
    let origin: ClipLiveShareNativeTimestamp
    let signers: [ClipLiveShareSoftwareIdentitySigner]
    let participants: [ClipLiveShareNativeV3Participant]
    let authorityChain: ClipLiveShareNativeV3RoomAuthorityChain

    init(participantCount: Int) throws {
        let fixtureSessionID = try ClipLiveShareSessionID(
            rawValue: "native-v3-lifecycle-integration"
        )
        let fixtureOrigin = try ClipLiveShareNativeTimestamp(
            date: Date()
        )
        let fixtureSigners: [ClipLiveShareSoftwareIdentitySigner] =
            try (1...participantCount).map { index in
            try ClipLiveShareSoftwareIdentitySigner(
                rawRepresentation: Data(
                    repeating: UInt8(0xA0 + index),
                    count: 32
                )
            )
        }
        let fixtureParticipants: [ClipLiveShareNativeV3Participant] =
            try fixtureSigners.enumerated().map {
            index, signer in
            try ClipLiveShareNativeV3Participant(
                participantID: ClipLiveShareNativeV3ParticipantID(
                    bytes: Data(
                        repeating: UInt8(0x10 + index * 0x10),
                        count: ClipLiveShareNativeV3.participantIDByteCount
                    )
                ),
                identity: signer.publicKey,
                displayName: "Lifecycle \(index + 1)",
                capabilities: ClipLiveShareNativeV3Capabilities.current
            )
        }
        let leader = fixtureParticipants[0]
        let revision = try ClipLiveShareNativeV3MembershipRevision(rawValue: 1)
        let credentials = try fixtureParticipants.map { participant in
            try ClipLiveShareSignedNativeV3MembershipCredential(
                signing: .init(
                    sessionID: fixtureSessionID,
                    leaderParticipantID: leader.participantID,
                    leaderIdentity: leader.identity,
                    participant: participant,
                    membershipRevision: revision,
                    issuedAt: fixtureOrigin,
                    expiresAt:
                        fixtureOrigin.adding(milliseconds: 180_000)
                ),
                with: fixtureSigners[0]
            )
        }
        let snapshot = try ClipLiveShareNativeV3MembershipSnapshot(
            sessionID: fixtureSessionID,
            leaderParticipantID: leader.participantID,
            leaderIdentity: leader.identity,
            membershipRevision: revision,
            credentials: credentials,
            issuedAt: fixtureOrigin,
            expiresAt: fixtureOrigin.adding(milliseconds: 120_000),
            maximumParticipants:
                ClipLiveShareNativeV3AdmissionPolicy.productDefault
                .maximumParticipants
        )
        let membership = try ClipLiveShareSignedNativeV3MembershipSnapshot(
            signing: snapshot,
            with: fixtureSigners[0]
        )
        let fixtureAuthority = try ClipLiveShareNativeV3RoomAuthorityChain(
            foundingCreatorParticipantID: leader.participantID,
            foundingCreatorIdentity: leader.identity,
            genesisMembership: membership,
            checkpoints: []
        )
        sessionID = fixtureSessionID
        origin = fixtureOrigin
        signers = fixtureSigners
        participants = fixtureParticipants
        authorityChain = fixtureAuthority
    }

    func time(_ seconds: Int64) -> ClipLiveShareNativeTimestamp {
        try! origin.adding(milliseconds: seconds * 1_000)
    }

    func coordinator(
        for index: Int
    ) throws -> ClipLiveShareNativeV3RoomLifecycleCoordinator {
        let local = participants[index]
        return try .init(
            localParticipantID: local.participantID,
            localSigner: signers[index],
            authorityChain: authorityChain,
            expectedSessionID: sessionID,
            expectedFoundingCreatorIdentity: participants[0].identity,
            establishedPeerParticipantIDs:
                Set(participants.map(\.participantID))
                .subtracting([local.participantID]),
            at: origin
        )
    }
}

private func v3TransferRequest(
    in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareSignedNativeV3LeadershipTransferRequest? {
    for event in events {
        if case let .broadcastTransferRequest(value) = event {
            return value
        }
    }
    return nil
}

private func v3Proposal(
    in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareSignedNativeV3LeadershipProposal? {
    for event in events {
        if case let .broadcastLeadershipProposal(value) = event {
            return value
        }
    }
    return nil
}

private func v3Vote(
    in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareSignedNativeV3LeadershipVote? {
    for event in events {
        if case let .broadcastLeadershipVote(value) = event {
            return value
        }
    }
    return nil
}

private func v3Certificate(
    in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareNativeV3LeadershipCertificate? {
    for event in events {
        if case let .leadershipCertificateReady(value) = event {
            return value
        }
    }
    return nil
}

private extension Sequence {
    func asyncMap<T: Sendable>(
        _ transform: @escaping @Sendable (Element) async -> T
    ) async -> [T] {
        var result: [T] = []
        for element in self {
            result.append(await transform(element))
        }
        return result
    }

    func asyncSum(
        _ transform: @escaping @Sendable (Element) async -> Int
    ) async -> Int {
        var result = 0
        for element in self {
            result += await transform(element)
        }
        return result
    }
}

private func v3Eventually(
    _ description: String = "condition",
    timeout: Duration = .seconds(3),
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record(
        "Timed out waiting for native-v3 integration condition: \(description)"
    )
}
