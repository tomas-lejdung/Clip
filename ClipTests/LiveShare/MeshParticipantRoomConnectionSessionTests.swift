import ClipLiveShare
import Foundation
import Testing

@testable import Clip

@Suite("Mesh participant room connection session")
struct MeshParticipantRoomConnectionSessionTests {
    @Test("creator publishes invite and hands off the direct v3 activation")
    func creatorEntry() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        let events = await session.events()
        let recorder = MeshRoomConnectionEventRecorder()
        let task = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        try await session.start()

        let snapshot = await session.snapshot()
        #expect(snapshot.phase == .active)
        #expect(snapshot.invite != nil)
        try await waitUntil {
            await recorder.activationCount() == 1
        }
        #expect(
            await recorder.latestInvite() == snapshot.invite
        )

        await session.close()
        task.cancel()
        #expect(await routes.ownerStopValues() == [true])
    }

    @Test("leader exposes approval and denial before allocating a pair")
    func explicitDenial() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        let invite = try #require((await session.snapshot()).invite)
        let proof = fixture.proof(invite: invite, routeByte: 0x31)
        await routes.emitOwner(.routeReady(
            participantID: fixture.candidate.participantID,
            proof: proof
        ))
        let hello = try fixture.hello(proof: proof)
        await routes.emitOwner(.envelope(
            hello,
            from: fixture.candidate.participantID
        ))
        try await waitUntil {
            await session.snapshot().phase == .awaitingApproval
        }

        #expect(
            (await session.snapshot()).pendingAdmission
                == fixture.candidate
        )
        try await session.denyAdmission(
            fixture.candidate.participantID
        )
        #expect((await session.snapshot()).phase == .active)
        #expect(
            await routes.sentOwnerEnvelopes().contains(where: {
                guard case let .rejected(value) = $0 else {
                    return false
                }
                return value.reason == .denied
            })
        )
        await session.close()
    }

    @Test("leader route without hello expires without ending the room")
    func abandonedLeaderRouteTimeout() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        let invite = try #require((await session.snapshot()).invite)
        let proof = fixture.proof(invite: invite, routeByte: 0x35)
        await routes.emitOwner(.routeReady(
            participantID: fixture.candidate.participantID,
            proof: proof
        ))
        try await Task.sleep(for: .milliseconds(10))

        try await session.expireAdmission(
            at: try fixture.now.adding(milliseconds: 61_000)
        )
        #expect((await session.snapshot()).phase == .active)
        #expect(
            await routes.closedOwnerParticipants()
                == [fixture.candidate.participantID]
        )
        await session.close()
    }

    @Test("rendezvous loss leaves an established room active")
    func establishedRoomSurvivesRendezvousLoss() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        #expect((await session.snapshot()).phase == .active)
        #expect((await session.snapshot()).invite != nil)

        await routes.emitOwner(.failed("rendezvous unavailable"))
        try await waitUntil {
            let snapshot = await session.snapshot()
            return snapshot.phase == .active && snapshot.invite == nil
        }

        #expect((await session.snapshot()).pendingAdmission == nil)
        await session.close()
    }

    @Test("malformed competing route is isolated from active admission")
    func malformedCompetingRouteIsolation() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        let invite = try #require((await session.snapshot()).invite)
        let activeProof = fixture.proof(invite: invite, routeByte: 0x38)
        await routes.emitOwner(.routeReady(
            participantID: fixture.candidate.participantID,
            proof: activeProof
        ))
        await routes.emitOwner(.envelope(
            try fixture.hello(proof: activeProof),
            from: fixture.candidate.participantID
        ))
        try await waitUntil {
            await session.snapshot().phase == .awaitingApproval
        }

        let competingID = try ClipLiveShareNativeV3ParticipantID(
            bytes: Data(repeating: 0x39, count: 16)
        )
        await routes.emitOwner(.envelope(
            try fixture.hello(proof: activeProof),
            from: competingID
        ))
        try await waitUntil {
            await routes.closedOwnerParticipants().contains(competingID)
        }
        #expect(
            (await session.snapshot()).phase == .awaitingApproval
        )
        #expect(
            (await session.snapshot()).pendingAdmission
                == fixture.candidate
        )

        try await session.denyAdmission(
            fixture.candidate.participantID
        )
        await session.close()
    }

    @Test("peer-link failure aborts only the active admission")
    func peerLinkFailureAbortsAdmission() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let failure = MeshRoomConnectionFailureProbe()
        let links = MeshParticipantRoomPeerLinks.testing(
            bind: { _, reportFailure in
                await failure.install(reportFailure)
            }
        )
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: links,
            now: { fixture.now }
        )
        try await session.start()
        let invite = try #require((await session.snapshot()).invite)
        let proof = fixture.proof(invite: invite, routeByte: 0x3A)
        await routes.emitOwner(.routeReady(
            participantID: fixture.candidate.participantID,
            proof: proof
        ))
        try await waitUntil { await failure.isInstalled() }

        await failure.report("peer-link-failed")
        try await waitUntil {
            let phase = await session.snapshot().phase
            let closed = await routes.closedOwnerParticipants()
            return phase == .active
                && closed.contains(fixture.candidate.participantID)
        }
        #expect((await session.snapshot()).pendingAdmission == nil)
        await session.close()
    }

    @Test("unrelated membership bypasses an active bootstrap transaction")
    func unrelatedMembershipBypass() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        let invite = try #require((await session.snapshot()).invite)
        let proof = fixture.proof(invite: invite, routeByte: 0x36)
        await routes.emitOwner(.routeReady(
            participantID: fixture.candidate.participantID,
            proof: proof
        ))
        await routes.emitOwner(.envelope(
            try fixture.hello(proof: proof),
            from: fixture.candidate.participantID
        ))
        try await waitUntil {
            await session.snapshot().phase == .awaitingApproval
        }
        let current =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.creator,
                creatorSigner: fixture.creatorSigner,
                at: fixture.now
            )
        #expect(
            try await session.receiveCommittedMembership(
                current.signedMembership,
                from: fixture.creator.participantID
            ) == false
        )
        #expect(
            (await session.snapshot()).phase == .awaitingApproval
        )
        try await session.denyAdmission(
            fixture.candidate.participantID
        )
        await session.close()
    }

    @Test("membership refresh aborts an admission based on the prior revision")
    func membershipRefreshAbortsStaleAdmission() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        let invite = try #require((await session.snapshot()).invite)
        let proof = fixture.proof(invite: invite, routeByte: 0x3B)
        await routes.emitOwner(.routeReady(
            participantID: fixture.candidate.participantID,
            proof: proof
        ))
        await routes.emitOwner(.envelope(
            try fixture.hello(proof: proof),
            from: fixture.candidate.participantID
        ))
        try await waitUntil {
            await session.snapshot().phase == .awaitingApproval
        }

        let genesis =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.creator,
                creatorSigner: fixture.creatorSigner,
                at: fixture.now
            )
        var lifecycle = try ClipLiveShareNativeV3RoomLifecycleCoordinator(
            localParticipantID: fixture.creator.participantID,
            localSigner: fixture.creatorSigner,
            authorityChain: genesis.authorityChain,
            expectedSessionID: fixture.sessionID,
            expectedFoundingCreatorIdentity: fixture.creator.identity,
            admissionPolicy: genesis.admissionPolicy,
            establishedPeerParticipantIDs: [],
            at: fixture.now
        )
        let refreshedAt = try fixture.now.adding(milliseconds: 1_000)
        let refreshedMembership = try lifecycle.makeMembershipSnapshot(
            participants: [fixture.creator],
            at: refreshedAt
        )
        _ = try lifecycle.commitMembershipSnapshot(
            refreshedMembership,
            at: refreshedAt
        )
        let refreshed = MeshParticipantBootstrapLaunchContext(
            localParticipantID: fixture.creator.participantID,
            localIdentitySigner: fixture.creatorSigner,
            signedMembership: lifecycle.signedMembership,
            authorityChain: lifecycle.authorityChain,
            expectedFoundingCreatorIdentity: fixture.creator.identity,
            bootstrapAdmissionDigests: [:],
            verifiedPeerTransportNonces: [:],
            admissionPolicy: genesis.admissionPolicy
        )

        try await session.applyCommittedContext(
            refreshed,
            refreshInviteIfLocalLeader: false
        )

        #expect((await session.snapshot()).phase == .active)
        #expect((await session.snapshot()).pendingAdmission == nil)
        #expect(
            (await session.snapshot()).membershipRevision
                == refreshedMembership.snapshot.membershipRevision
        )
        #expect(
            await routes.closedOwnerParticipants().contains(
                fixture.candidate.participantID
            )
        )
        await session.close()
    }

    @Test("locked room authority closes admission and gates every leader mutation")
    func lockedAuthorityGatesLeaderSession() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        let genesis =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.creator,
                creatorSigner: fixture.creatorSigner,
                at: fixture.now
            )
        let invite = try #require((await session.snapshot()).invite)
        let proof = fixture.proof(invite: invite, routeByte: 0x3C)
        await routes.emitOwner(.routeReady(
            participantID: fixture.candidate.participantID,
            proof: proof
        ))
        await routes.emitOwner(.envelope(
            try fixture.hello(proof: proof),
            from: fixture.candidate.participantID
        ))
        try await waitUntil {
            await session.snapshot().phase == .awaitingApproval
        }

        try await session.applyCommittedContext(
            genesis,
            availability: .leaderlessLocked,
            refreshInviteIfLocalLeader: false
        )
        #expect((await session.snapshot()).pendingAdmission == nil)
        #expect((await session.snapshot()).invite == nil)
        #expect(
            await routes.closedOwnerParticipants().contains(
                fixture.candidate.participantID
            )
        )
        await #expect(
            throws:
                MeshParticipantBootstrapError.roomAuthorityUnavailable
        ) {
            try await session.refreshInvite()
        }
        await #expect(
            throws:
                MeshParticipantBootstrapError.roomAuthorityUnavailable
        ) {
            try await session.updateRequiredAccessWord("locked")
        }
        await #expect(
            throws:
                MeshParticipantBootstrapError.roomAuthorityUnavailable
        ) {
            try await session.approveAdmission(
                fixture.candidate.participantID
            )
        }

        try await session.applyCommittedContext(
            genesis,
            availability: .active,
            refreshInviteIfLocalLeader: false
        )
        try await waitUntil {
            let snapshot = await session.snapshot()
            let starts = await routes.ownerStartCount()
            return snapshot.invite != nil
                && starts == 2
        }
        await session.close()
    }

    @Test("New Invite waits for an active admission to finish")
    func queuedInviteRotation() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        let first = try #require((await session.snapshot()).invite)
        let proof = fixture.proof(invite: first, routeByte: 0x37)
        await routes.emitOwner(.routeReady(
            participantID: fixture.candidate.participantID,
            proof: proof
        ))
        await routes.emitOwner(.envelope(
            try fixture.hello(proof: proof),
            from: fixture.candidate.participantID
        ))
        try await waitUntil {
            await session.snapshot().phase == .awaitingApproval
        }

        try await session.refreshInvite()
        #expect(await routes.ownerStartCount() == 1)
        #expect((await session.snapshot()).invite == first)

        try await session.denyAdmission(
            fixture.candidate.participantID
        )
        try await waitUntil {
            let starts = await routes.ownerStartCount()
            let phase = await session.snapshot().phase
            return starts == 2 && phase == .active
        }
        let second = try #require((await session.snapshot()).invite)
        #expect(first.rendezvousID != second.rendezvousID)
        await session.close()
    }

    @Test(
        "one creator session admits participants two through four then rejects participant five"
    )
    func sequentialAdmissionsThroughProductLimit() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let coordinatorProbe = MeshRoomConnectionCoordinatorProbe()
        let pairProbe = MeshRoomConnectionPairProbe()
        let links = MeshParticipantRoomPeerLinks.testing(
            pairHooks: .init(
                prepare: { pair in
                    await pairProbe.prepare(pair)
                }
            ),
            bind: { coordinator, _ in
                await coordinatorProbe.install(coordinator)
            }
        )
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: links,
            now: { fixture.now }
        )
        try await session.start()

        let candidates = try [
            fixture.participant(byte: 0x40, name: "Participant 2"),
            fixture.participant(byte: 0x50, name: "Participant 3"),
            fixture.participant(byte: 0x60, name: "Participant 4"),
        ]
        var members: [
            ClipLiveShareNativeV3ParticipantID:
                (
                    participant: ClipLiveShareNativeV3Participant,
                    signer: ClipLiveShareSoftwareIdentitySigner
                )
        ] = [
            fixture.creator.participantID:
                (fixture.creator, fixture.creatorSigner)
        ]

        for (index, candidate) in candidates.enumerated() {
            await coordinatorProbe.clear()
            await pairProbe.clear()
            let invite = try #require((await session.snapshot()).invite)
            let proof = fixture.proof(
                invite: invite,
                routeByte: UInt8(0x61 + index)
            )
            await routes.emitOwner(.routeReady(
                participantID: candidate.participant.participantID,
                proof: proof
            ))
            await routes.emitOwner(.envelope(
                try fixture.hello(
                    participant: candidate.participant,
                    signer: candidate.signer,
                    proof: proof
                ),
                from: candidate.participant.participantID
            ))
            try await waitUntil {
                await session.snapshot().phase == .awaitingApproval
            }

            try await session.approveAdmission(
                candidate.participant.participantID
            )
            let provisional = try await routes.waitForLatestProvisional()
            let challenge = try await routes.waitForLatestChallenge(
                to: candidate.participant.participantID
            )
            let signedProof =
                try ClipLiveShareSignedNativeV3PossessionProof(
                    signing: challenge,
                    with: candidate.signer
                )
            let proofRelay = try ClipLiveShareNativeV3BootstrapRelay(
                sessionID: fixture.sessionID,
                admissionDigest: provisional.admission.digest,
                originParticipantID:
                    candidate.participant.participantID,
                targetParticipantID:
                    fixture.creator.participantID,
                payload: .possessionProof(signedProof)
            )
            await routes.emitOwner(.envelope(
                .relay(proofRelay),
                from: candidate.participant.participantID
            ))
            try await waitUntil {
                await pairProbe.contains(
                    candidate.participant.participantID
                )
            }

            let coordinator = try #require(
                await coordinatorProbe.current()
            )
            try await coordinator.markPeerLinkReady(
                with: candidate.participant.participantID,
                at: fixture.now
            )

            for member in members.values
                where member.participant.participantID
                    != fixture.creator.participantID
            {
                let readiness = try fixture.signedReadiness(
                    reporter: member.participant,
                    signer: member.signer,
                    candidateID:
                        candidate.participant.participantID,
                    allExistingMemberIDs: Set(members.keys),
                    provisional: provisional
                )
                let forward = try ClipLiveShareNativeV3BootstrapForward(
                    sessionID: fixture.sessionID,
                    admissionDigest: provisional.admission.digest,
                    originParticipantID:
                        member.participant.participantID,
                    targetParticipantID:
                        fixture.creator.participantID,
                    envelope: .linkReadiness(readiness)
                )
                #expect(
                    try await session.receiveBootstrapForward(
                        forward,
                        from: member.participant.participantID
                    )
                )
            }

            let candidateReadiness = try fixture.signedReadiness(
                reporter: candidate.participant,
                signer: candidate.signer,
                candidateID: candidate.participant.participantID,
                allExistingMemberIDs: Set(members.keys),
                provisional: provisional
            )
            await routes.emitOwner(.envelope(
                .linkReadiness(candidateReadiness),
                from: candidate.participant.participantID
            ))
            try await waitUntil {
                let snapshot = await session.snapshot()
                return snapshot.phase == .active
                    && snapshot.pendingAdmission == nil
                    && snapshot.membershipRevision
                        == provisional.admission.candidateCredential
                            .credential.membershipRevision
            }
            members[candidate.participant.participantID] = candidate
        }

        #expect(members.count == 4)
        let rejected = try fixture.participant(
            byte: 0x70,
            name: "Participant 5"
        )
        let invite = try #require((await session.snapshot()).invite)
        let proof = fixture.proof(invite: invite, routeByte: 0x70)
        await routes.emitOwner(.routeReady(
            participantID: rejected.participant.participantID,
            proof: proof
        ))
        await routes.emitOwner(.envelope(
            try fixture.hello(
                participant: rejected.participant,
                signer: rejected.signer,
                proof: proof
            ),
            from: rejected.participant.participantID
        ))
        try await waitUntil {
            let rejectedAtCapacity =
                await routes.sentOwnerEnvelopes().contains {
                    guard case let .rejected(value) = $0 else {
                        return false
                    }
                    return value.reason == .roomFull
                }
            let snapshot = await session.snapshot()
            return rejectedAtCapacity
                && snapshot.phase == .active
                && snapshot.pendingAdmission == nil
        }
        #expect(
            await routes.closedOwnerParticipants().contains(
                rejected.participant.participantID
            )
        )
        await session.close()
    }

    @Test("candidate timeout closes provisional admission deterministically")
    func candidateTimeout() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let invite = try routes.initialInvite()
        let session = try MeshParticipantRoomConnectionSession.candidate(
            invite: invite,
            participant: fixture.candidate,
            signer: fixture.candidateSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        await routes.emitCandidate(.routeReady(
            participantID: fixture.creator.participantID,
            proof: fixture.proof(invite: invite, routeByte: 0x41)
        ))
        try await waitUntil {
            await routes.sentCandidateEnvelopes().contains(where: {
                if case .hello = $0 { return true }
                return false
            })
        }

        try await session.expireAdmission(
            at: try fixture.now.adding(milliseconds: 61_000)
        )
        try await waitUntil {
            await session.snapshot().phase == .timedOut
        }
        await session.close()
        #expect(await routes.candidateStopCount() == 1)
    }

    @Test("signed Access Word requirement pauses hello until supplied")
    func accessWordPromptBeforeHello() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(
            fixture: fixture,
            candidateAccessWordRequired: true
        )
        let invite = try routes.initialInvite()
        let session = try MeshParticipantRoomConnectionSession.candidate(
            invite: invite,
            participant: fixture.candidate,
            signer: fixture.candidateSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        await routes.emitCandidate(.routeReady(
            participantID: fixture.creator.participantID,
            proof: fixture.proof(invite: invite, routeByte: 0x42)
        ))
        try await waitUntil {
            await session.snapshot().phase == .accessWordRequired
        }
        #expect((await session.snapshot()).accessWordRequired == true)
        #expect(await routes.sentCandidateEnvelopes().isEmpty)

        try await session.provideAccessWord("  secret room  ")
        try await waitUntil {
            await routes.sentCandidateEnvelopes().contains(where: {
                if case .hello = $0 { return true }
                return false
            })
        }
        await session.close()
    }

    @Test("abandoned Access Word prompt expires the candidate route")
    func accessWordPromptTimeout() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(
            fixture: fixture,
            candidateAccessWordRequired: true
        )
        let invite = try routes.initialInvite()
        let session = try MeshParticipantRoomConnectionSession.candidate(
            invite: invite,
            participant: fixture.candidate,
            signer: fixture.candidateSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        await routes.emitCandidate(.routeReady(
            participantID: fixture.creator.participantID,
            proof: fixture.proof(invite: invite, routeByte: 0x43)
        ))
        try await waitUntil {
            await session.snapshot().phase == .accessWordRequired
        }

        try await session.expireAdmission(
            at: try fixture.now.adding(milliseconds: 61_000)
        )
        #expect((await session.snapshot()).phase == .timedOut)
        #expect(await routes.candidateStopCount() == 1)
        await session.close()
    }

    @Test("certified successor refreshes a fresh encrypted invite")
    func successorInviteRefresh() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        let first = try #require((await session.snapshot()).invite)
        let context =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.creator,
                creatorSigner: fixture.creatorSigner,
                at: fixture.now
            )

        try await session.applyCommittedContext(
            context,
            refreshInviteIfLocalLeader: true
        )
        let second = try #require((await session.snapshot()).invite)
        #expect(first.rendezvousID != second.rendezvousID)
        #expect(first.admissionCapability != second.admissionCapability)
        #expect(await routes.ownerStartCount() == 2)
        #expect(await routes.ownerStopValues() == [true])
        await session.close()
    }

    @Test("changing Access Word requirement rotates signed invite metadata")
    func accessWordRequirementRefresh() async throws {
        let fixture = try MeshRoomConnectionFixture()
        let routes = try MeshRoomConnectionRoutes(fixture: fixture)
        let session = try MeshParticipantRoomConnectionSession.creator(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            participant: fixture.creator,
            signer: fixture.creatorSigner,
            routeFactory: routes.factory,
            peerLinks: .testing(),
            now: { fixture.now }
        )
        try await session.start()
        let first = try #require((await session.snapshot()).invite)

        try await session.updateRequiredAccessWord(" CALM-OTTER ")
        let second = try #require((await session.snapshot()).invite)
        #expect(first.rendezvousID != second.rendezvousID)
        #expect(
            await routes.ownerAccessWordRequirements()
                == [false, true]
        )

        try await session.updateRequiredAccessWord(nil)
        #expect(
            await routes.ownerAccessWordRequirements()
                == [false, true, false]
        )
        await session.close()
    }
}

private actor MeshRoomConnectionFailureProbe {
    private var callback: (@Sendable (String) -> Void)?

    func install(_ callback: @escaping @Sendable (String) -> Void) {
        self.callback = callback
    }

    func isInstalled() -> Bool {
        callback != nil
    }

    func report(_ message: String) {
        callback?(message)
    }
}

private actor MeshRoomConnectionEventRecorder {
    private var events: [MeshParticipantRoomConnectionEvent] = []

    func record(_ event: MeshParticipantRoomConnectionEvent) {
        events.append(event)
    }

    func activationCount() -> Int {
        events.reduce(into: 0) { count, event in
            if case .activationReady = event { count += 1 }
        }
    }

    func latestInvite() -> ClipLiveShareNativeV3Invite? {
        for event in events.reversed() {
            if case let .inviteChanged(invite) = event {
                return invite
            }
        }
        return nil
    }
}

private final class MeshRoomConnectionRoutes: @unchecked Sendable {
    private let lock = NSLock()
    private let fixture: MeshRoomConnectionFixture
    private let candidateAccessWordRequired: Bool?
    private let ownerStream:
        AsyncStream<MeshParticipantEncryptedRendezvousEvent>
    private let ownerContinuation:
        AsyncStream<MeshParticipantEncryptedRendezvousEvent>.Continuation
    private let candidateStream:
        AsyncStream<MeshParticipantEncryptedRendezvousEvent>
    private let candidateContinuation:
        AsyncStream<MeshParticipantEncryptedRendezvousEvent>.Continuation
    private var nextRouteByte: UInt8 = 0x51
    private var ownerStarts = 0
    private var ownerStops: [Bool] = []
    private var ownerRequiredAccessWords: [Bool] = []
    private var candidateStops = 0
    private var closedOwnerParticipantIDs:
        [ClipLiveShareNativeV3ParticipantID] = []
    private var ownerSent:
        [ClipLiveShareNativeV3BootstrapEnvelope] = []
    private var candidateSent:
        [ClipLiveShareNativeV3BootstrapEnvelope] = []

    init(
        fixture: MeshRoomConnectionFixture,
        candidateAccessWordRequired: Bool? = nil
    ) throws {
        self.fixture = fixture
        self.candidateAccessWordRequired = candidateAccessWordRequired
        (ownerStream, ownerContinuation) = AsyncStream.makeStream(
            of: MeshParticipantEncryptedRendezvousEvent.self
        )
        (candidateStream, candidateContinuation) = AsyncStream.makeStream(
            of: MeshParticipantEncryptedRendezvousEvent.self
        )
    }

    var factory: MeshParticipantRoomConnectionRouteFactory {
        .init(
            makeOwner: { [self] configuration in
                let invite = try nextInvite(configuration: configuration)
                lock.withLock {
                    ownerRequiredAccessWords.append(
                        configuration.accessWordRequired
                    )
                }
                return .init(
                    invite: invite,
                    events: { [ownerStream] in ownerStream },
                    start: { [self] in
                        lock.withLock { ownerStarts += 1 }
                    },
                    send: { [self] envelope, _ in
                        lock.withLock { ownerSent.append(envelope) }
                    },
                    closeRoute: { [self] participantID, _ in
                        lock.withLock {
                            closedOwnerParticipantIDs.append(participantID)
                        }
                    },
                    stop: { [self] remove in
                        lock.withLock { ownerStops.append(remove) }
                    }
                )
            },
            makeCandidate: { [self] _, _ in
                .init(
                    events: { [candidateStream] in candidateStream },
                    start: {},
                    send: { [self] envelope, _ in
                        lock.withLock { candidateSent.append(envelope) }
                    },
                    stop: { [self] in
                        lock.withLock { candidateStops += 1 }
                    },
                    accessWordRequired: { [self] in
                        candidateAccessWordRequired
                    }
                )
            }
        )
    }

    func initialInvite() throws -> ClipLiveShareNativeV3Invite {
        try nextInvite(configuration: .init(
            endpoint: fixture.endpoint,
            sessionID: fixture.sessionID,
            foundingCreatorIdentity: fixture.creator.identity,
            leaderParticipantID: fixture.creator.participantID,
            leaderSigner: fixture.creatorSigner
        ))
    }

    func emitOwner(_ event: MeshParticipantEncryptedRendezvousEvent) async {
        ownerContinuation.yield(event)
        await Task.yield()
    }

    func emitCandidate(_ event: MeshParticipantEncryptedRendezvousEvent) async {
        candidateContinuation.yield(event)
        await Task.yield()
    }

    func ownerStartCount() async -> Int {
        lock.withLock { ownerStarts }
    }

    func ownerStopValues() async -> [Bool] {
        lock.withLock { ownerStops }
    }

    func candidateStopCount() async -> Int {
        lock.withLock { candidateStops }
    }

    func ownerAccessWordRequirements() async -> [Bool] {
        lock.withLock { ownerRequiredAccessWords }
    }

    func closedOwnerParticipants() async
        -> [ClipLiveShareNativeV3ParticipantID] {
        lock.withLock { closedOwnerParticipantIDs }
    }

    func sentOwnerEnvelopes() async
        -> [ClipLiveShareNativeV3BootstrapEnvelope] {
        lock.withLock { ownerSent }
    }

    func sentCandidateEnvelopes() async
        -> [ClipLiveShareNativeV3BootstrapEnvelope] {
        lock.withLock { candidateSent }
    }

    func waitForLatestProvisional() async throws
        -> ClipLiveShareSignedNativeV3ProvisionalAdmission {
        try await waitUntil {
            self.latestProvisional() != nil
        }
        return try #require(latestProvisional())
    }

    func waitForLatestChallenge(
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws -> ClipLiveShareNativeV3PossessionChallenge {
        try await waitUntil {
            self.latestChallenge(to: participantID) != nil
        }
        return try #require(latestChallenge(to: participantID))
    }

    private func latestProvisional()
        -> ClipLiveShareSignedNativeV3ProvisionalAdmission? {
        lock.withLock {
            for envelope in ownerSent.reversed() {
                if case let .provisionalAdmission(value) = envelope {
                    return value
                }
            }
            return nil
        }
    }

    private func latestChallenge(
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) -> ClipLiveShareNativeV3PossessionChallenge? {
        lock.withLock {
            for envelope in ownerSent.reversed() {
                guard case let .relay(relay) = envelope,
                      relay.targetParticipantID == participantID,
                      case let .possessionChallenge(value) = relay.payload
                else { continue }
                return value
            }
            return nil
        }
    }

    private func nextInvite(
        configuration: MeshParticipantRoomOwnerRouteConfiguration
    ) throws -> ClipLiveShareNativeV3Invite {
        let byte = lock.withLock {
            defer { nextRouteByte &+= 1 }
            return nextRouteByte
        }
        return try .init(
            endpoint: configuration.endpoint,
            rendezvousID: .init(
                bytes: Data(
                    repeating: byte,
                    count: ClipLiveShareNativeV3InviteProtocol
                        .rendezvousIDByteCount
                )
            ),
            sessionID: configuration.sessionID,
            foundingCreatorIdentity:
                configuration.foundingCreatorIdentity,
            leaderParticipantID:
                configuration.leaderParticipantID,
            leaderIdentity:
                configuration.leaderSigner.publicKey,
            leaderRendezvousPublicKey: ClipLiveShareNativeV3RendezvousIdentity().publicKey,
            admissionCapability: try .init(
                bytes: Data(repeating: byte, count: 32)
            )
        )
    }
}

private struct MeshRoomConnectionFixture: Sendable {
    let endpoint = URL(string: "https://mesh.example")!
    let sessionID = try! ClipLiveShareSessionID(
        rawValue: "mesh-room-connection-tests"
    )
    let now = try! ClipLiveShareNativeTimestamp(
        millisecondsSince1970: 1_900_000_000_000
    )
    let creatorSigner: ClipLiveShareSoftwareIdentitySigner
    let candidateSigner: ClipLiveShareSoftwareIdentitySigner
    let creator: ClipLiveShareNativeV3Participant
    let candidate: ClipLiveShareNativeV3Participant

    init() throws {
        creatorSigner = try .init(
            rawRepresentation: Data(repeating: 0x11, count: 32)
        )
        candidateSigner = try .init(
            rawRepresentation: Data(repeating: 0x22, count: 32)
        )
        creator = try .init(
            participantID: .init(
                bytes: Data(repeating: 0x31, count: 16)
            ),
            identity: creatorSigner.publicKey,
            displayName: "Creator",
            capabilities: .current
        )
        candidate = try .init(
            participantID: .init(
                bytes: Data(repeating: 0x32, count: 16)
            ),
            identity: candidateSigner.publicKey,
            displayName: "Candidate",
            capabilities: .current
        )
    }

    func proof(
        invite: ClipLiveShareNativeV3Invite,
        routeByte: UInt8
    ) -> ClipLiveShareNativeV3RendezvousProof {
        .init(
            sessionID: invite.sessionID,
            rendezvousID: invite.rendezvousID,
            routeID: try! .init(
                bytes: Data(repeating: routeByte, count: 16)
            ),
            foundingCreatorIdentity:
                invite.foundingCreatorIdentity,
            admissionCapability: invite.admissionCapability
        )
    }

    func hello(
        proof: ClipLiveShareNativeV3RendezvousProof
    ) throws -> ClipLiveShareNativeV3BootstrapEnvelope {
        try hello(
            participant: candidate,
            signer: candidateSigner,
            proof: proof
        )
    }

    func hello(
        participant: ClipLiveShareNativeV3Participant,
        signer: ClipLiveShareSoftwareIdentitySigner,
        proof: ClipLiveShareNativeV3RendezvousProof
    ) throws -> ClipLiveShareNativeV3BootstrapEnvelope {
        let value = try ClipLiveShareNativeV3BootstrapHello(
            sessionID: sessionID,
            participantID: participant.participantID,
            identity: participant.identity,
            displayName: participant.displayName,
            rendezvousProof: proof,
            issuedAt: now,
            expiresAt: try now.adding(milliseconds: 60_000)
        )
        return .hello(try .init(
            signing: value,
            with: signer
        ))
    }

    func participant(
        byte: UInt8,
        name: String
    ) throws -> (
        participant: ClipLiveShareNativeV3Participant,
        signer: ClipLiveShareSoftwareIdentitySigner
    ) {
        let signer = try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(repeating: byte, count: 32)
        )
        return (
            try .init(
                participantID: .init(
                    bytes: Data(repeating: byte, count: 16)
                ),
                identity: signer.publicKey,
                displayName: name,
                capabilities: .current
            ),
            signer
        )
    }

    func signedReadiness(
        reporter: ClipLiveShareNativeV3Participant,
        signer: ClipLiveShareSoftwareIdentitySigner,
        candidateID: ClipLiveShareNativeV3ParticipantID,
        allExistingMemberIDs:
            Set<ClipLiveShareNativeV3ParticipantID>,
        provisional: ClipLiveShareSignedNativeV3ProvisionalAdmission
    ) throws -> ClipLiveShareSignedNativeV3BootstrapLinkReadiness {
        let peerIDs =
            reporter.participantID == candidateID
                ? allExistingMemberIDs
                : Set([candidateID])
        let keys = try peerIDs.map {
            try ClipLiveShareNativeV3PeerLinkKey(
                reporter.participantID,
                $0
            )
        }
        let readiness = try ClipLiveShareNativeV3BootstrapLinkReadiness(
            sessionID: sessionID,
            admissionDigest: provisional.admission.digest,
            reporterParticipantID: reporter.participantID,
            reporterIdentity: reporter.identity,
            readyPeerLinkKeys: Set(keys)
        )
        return try .init(signing: readiness, with: signer)
    }
}

private actor MeshRoomConnectionCoordinatorProbe {
    private var coordinator: MeshParticipantBootstrapCoordinator?

    func install(_ coordinator: MeshParticipantBootstrapCoordinator) {
        self.coordinator = coordinator
    }

    func clear() {
        coordinator = nil
    }

    func current() -> MeshParticipantBootstrapCoordinator? {
        coordinator
    }
}

private actor MeshRoomConnectionPairProbe {
    private var participantIDs:
        Set<ClipLiveShareNativeV3ParticipantID> = []

    func prepare(_ pair: MeshParticipantBootstrapProvisionalPair) {
        participantIDs.insert(pair.remoteParticipantID)
    }

    func clear() {
        participantIDs.removeAll()
    }

    func contains(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) -> Bool {
        participantIDs.contains(participantID)
    }
}

private func waitUntil(
    attempts: Int = 200,
    _ predicate: @escaping () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for asynchronous mesh state")
}
