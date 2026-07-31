import ClipLiveShare
import Foundation
import Testing

@testable import Clip

@Suite("Mesh participant bootstrap coordinator")
struct MeshParticipantBootstrapCoordinatorTests {
    @Test(
        "creator admits through the four-participant product limit with every pair proven before commit"
    )
    func sequentialAdmissionThroughFourParticipants() async throws {
        let fixture = try MeshBootstrapFixture()
        let creatorContext =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.participants[0],
                creatorSigner: fixture.signers[0],
                at: fixture.time(0)
            )

        let first = try await fixture.beginAdmission(
            memberContexts: [
                fixture.participants[0].participantID: creatorContext
            ],
            candidateIndex: 1,
            routeNumber: 1,
            at: fixture.time(10)
        )
        try await first.drain(at: fixture.time(10))
        #expect(
            (await first.coordinator(for: first.leaderID).snapshot()).phase
                == .awaitingApproval
        )
        #expect(
            await first.recorder(for: first.candidateID)
                .preparedPeerIDs().isEmpty
        )
        try await first.approve(at: fixture.time(10))
        try await first.drain(at: fixture.time(10))

        #expect(
            await first.recorder(for: first.candidateID)
                .preparedPeerIDs()
                == Set(first.memberIDs)
        )
        #expect(
            await first.recorder(for: first.candidateID)
                .promotedContextCount() == 0
        )

        // SDP remains on the authenticated bootstrap relay while the pair is
        // quarantined. It becomes direct-control state only after commit.
        let candidatePair = try #require(
            await first.recorder(for: first.candidateID)
                .firstPreparedPair()
        )
        let offerContext = try ClipLiveShareNativeV3PeerLinkContext(
            sessionID: fixture.sessionID,
            membershipRevision:
                candidatePair.admission.admission.candidateCredential
                    .credential.membershipRevision,
            peerLinkKey: ClipLiveShareNativeV3PeerLinkKey(
                first.candidateID,
                first.memberIDs[0]
            ),
            negotiationRevision:
                ClipLiveShareNativeV3PeerLinkRevision(rawValue: 1),
            senderParticipantID: first.candidateID,
            receiverParticipantID: first.memberIDs[0],
            transportNonce: candidatePair.transportNonce
        )
        let offer = try ClipLiveShareNativeV3PeerLinkOffer(
            context: offerContext,
            sdp: "provisional-offer"
        )
        let signedOffer = try ClipLiveShareSignedNativeV3PeerLinkOffer(
            signing: offer,
            with: fixture.signer(for: first.candidateID),
            senderIdentity: fixture.participant(for: first.candidateID).identity
        )
        try await first.coordinator(for: first.candidateID)
            .relayPairPayload(
                .offer(signedOffer),
                to: first.memberIDs[0]
            )
        try await first.drain(at: fixture.time(11))
        #expect(
            await first.recorder(for: first.memberIDs[0])
                .relayCount() == 1
        )

        try await first.markEveryPairReady(at: fixture.time(12))
        try await first.drain(at: fixture.time(12))
        let firstContexts = try await first.completedContexts()
        #expect(firstContexts.count == 2)
        for context in firstContexts.values {
            #expect(context.signedMembership.snapshot.participants.count == 2)
            #expect(context.bootstrapAdmissionDigests.count == 1)
            #expect(context.verifiedPeerTransportNonces.count == 1)
        }
        for id in firstContexts.keys {
            #expect(
                await first.recorder(for: id).promotedContextCount() == 1
            )
        }

        let second = try await fixture.beginAdmission(
            memberContexts: firstContexts,
            candidateIndex: 2,
            routeNumber: 2,
            at: fixture.time(20)
        )
        try await second.drain(at: fixture.time(20))
        try await second.approve(at: fixture.time(20))
        try await second.drain(at: fixture.time(20))
        #expect(
            await second.recorder(for: second.candidateID)
                .preparedPeerIDs()
                == Set(second.memberIDs)
        )
        #expect(
            await second.recorder(for: second.candidateID)
                .promotedContextCount() == 0
        )

        try await second.markEveryPairReady(at: fixture.time(22))
        try await second.drain(at: fixture.time(22))
        let secondContexts = try await second.completedContexts()
        #expect(secondContexts.count == 3)
        for context in secondContexts.values {
            #expect(context.signedMembership.snapshot.participants.count == 3)
            #expect(context.bootstrapAdmissionDigests.count == 2)
            #expect(context.verifiedPeerTransportNonces.count == 2)
            #expect(
                context.authorityChain.foundingCreatorIdentity
                    == fixture.participants[0].identity
            )
        }

        let third = try await fixture.beginAdmission(
            memberContexts: secondContexts,
            candidateIndex: 3,
            routeNumber: 13,
            at: fixture.time(30)
        )
        try await third.drain(at: fixture.time(30))
        try await third.approve(at: fixture.time(30))
        try await third.drain(at: fixture.time(30))
        #expect(
            await third.recorder(for: third.candidateID)
                .preparedPeerIDs()
                == Set(third.memberIDs)
        )
        try await third.markEveryPairReady(at: fixture.time(32))
        try await third.drain(at: fixture.time(32))
        let thirdContexts = try await third.completedContexts()
        #expect(thirdContexts.count == 4)
        for context in thirdContexts.values {
            #expect(context.signedMembership.snapshot.participants.count == 4)
            #expect(context.bootstrapAdmissionDigests.count == 3)
            #expect(context.verifiedPeerTransportNonces.count == 3)
        }
    }

    @Test("timeout aborts every provisional pair without promoting control")
    func timeoutAbortsQuarantinedPairs() async throws {
        let fixture = try MeshBootstrapFixture()
        let creatorContext =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.participants[0],
                creatorSigner: fixture.signers[0],
                at: fixture.time(0)
            )
        let run = try await fixture.beginAdmission(
            memberContexts: [
                fixture.participants[0].participantID: creatorContext
            ],
            candidateIndex: 1,
            routeNumber: 3,
            at: fixture.time(10)
        )
        try await run.drain(at: fixture.time(10))
        try await run.approve(at: fixture.time(10))
        try await run.drain(at: fixture.time(10))
        let leaderID = try #require(run.memberIDs.first)
        try await run.coordinator(for: leaderID)
            .expire(at: fixture.time(71))
        try await run.drain(at: fixture.time(71))

        #expect(
            (await run.coordinator(for: leaderID).snapshot()).phase
                == .timedOut
        )
        #expect(
            (await run.coordinator(for: run.candidateID).snapshot()).phase
                == .timedOut
        )
        #expect(
            await run.recorder(for: leaderID).abortedPeerIDs()
                == [run.candidateID]
        )
        #expect(
            await run.recorder(for: run.candidateID).abortedPeerIDs()
                == [leaderID]
        )
        #expect(
            await run.recorder(for: leaderID).promotedContextCount() == 0
        )
    }

    @Test("leader denial rejects the join before any pair is prepared")
    func explicitDenialPreventsProvisionalLinks() async throws {
        let fixture = try MeshBootstrapFixture()
        let creatorContext =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.participants[0],
                creatorSigner: fixture.signers[0],
                at: fixture.time(0)
            )
        let run = try await fixture.beginAdmission(
            memberContexts: [
                fixture.participants[0].participantID: creatorContext
            ],
            candidateIndex: 1,
            routeNumber: 7,
            at: fixture.time(10)
        )
        try await run.drain(at: fixture.time(10))
        try await run.coordinator(for: run.leaderID).denyAdmission()
        try await run.drain(at: fixture.time(10))

        #expect(
            (await run.coordinator(for: run.candidateID).snapshot()).phase
                == .rejected(.denied)
        )
        for recorder in run.recorders.values {
            #expect(await recorder.preparedPeerIDs().isEmpty)
            #expect(await recorder.promotedContextCount() == 0)
        }
    }

    @Test("a second authenticated join receives busy without disturbing approval")
    func concurrentJoinIsBusy() async throws {
        let fixture = try MeshBootstrapFixture()
        let creatorContext =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.participants[0],
                creatorSigner: fixture.signers[0],
                at: fixture.time(0)
            )
        let run = try await fixture.beginAdmission(
            memberContexts: [
                fixture.participants[0].participantID: creatorContext
            ],
            candidateIndex: 1,
            routeNumber: 8,
            at: fixture.time(10)
        )
        try await run.drain(at: fixture.time(10))

        let second = fixture.participants[2]
        let secondProof = fixture.route(number: 9)
        let secondHello = try ClipLiveShareSignedNativeV3BootstrapHello(
            signing: .init(
                sessionID: fixture.sessionID,
                participantID: second.participantID,
                identity: second.identity,
                displayName: second.displayName,
                rendezvousProof: secondProof,
                issuedAt: fixture.time(11),
                expiresAt: fixture.time(70)
            ),
            with: fixture.signers[2]
        )
        try await run.coordinator(for: run.leaderID).rejectConcurrentJoin(
            secondHello,
            authenticatedRendezvousProof: secondProof,
            from: second.participantID,
            at: fixture.time(11)
        )
        let response = try #require(await run.network.next())
        #expect(response.from == run.leaderID)
        #expect(response.to == second.participantID)
        guard case let .rejected(rejection) = response.envelope else {
            Issue.record("Concurrent join did not receive a rejection")
            return
        }
        #expect(rejection.reason == .busy)
        #expect(rejection.rendezvousProof == secondProof)
        #expect(
            (await run.coordinator(for: run.leaderID).snapshot()).phase
                == .awaitingApproval
        )
        #expect(
            await run.recorder(for: run.leaderID)
                .preparedPeerIDs().isEmpty
        )
    }

    @Test("tampered hello is rejected before provisional admission")
    func tamperedHelloFailsClosed() async throws {
        let fixture = try MeshBootstrapFixture()
        let context =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.participants[0],
                creatorSigner: fixture.signers[0],
                at: fixture.time(0)
            )
        let network = MeshBootstrapNetwork()
        let route = fixture.route(number: 4)
        let leader = try MeshParticipantBootstrapCoordinator(
            memberContext: context,
            rendezvousProof: route,
            send: fixture.send(
                from: fixture.participants[0].participantID,
                over: network
            )
        )
        let hello = try ClipLiveShareNativeV3BootstrapHello(
            sessionID: fixture.sessionID,
            participantID: fixture.participants[1].participantID,
            identity: fixture.participants[1].identity,
            displayName: fixture.participants[1].displayName,
            rendezvousProof: route,
            issuedAt: fixture.time(10),
            expiresAt: fixture.time(70)
        )
        let forged = ClipLiveShareSignedNativeV3BootstrapHello(
            hello: hello,
            signature: try fixture.signers[0].signature(
                for: hello.canonicalRepresentation
            )
        )

        do {
            try await leader.receive(
                .hello(forged),
                from: fixture.participants[1].participantID,
                at: fixture.time(10)
            )
            Issue.record("Tampered hello unexpectedly passed verification")
        } catch {
            #expect(error as? ClipLiveShareNativeV3Error == .invalidSignature)
        }
        #expect(
            (await leader.snapshot()).phase == .rejected(.incompatible)
        )
        #expect(await leader.launchContext() == nil)
    }

    @Test("locked ended and full rooms reject before pair creation")
    func admissionPolicyRejections() async throws {
        let fixture = try MeshBootstrapFixture()
        let creatorContext =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.participants[0],
                creatorSigner: fixture.signers[0],
                at: fixture.time(0)
            )

        for (offset, availability, expected) in [
            (
                5,
                MeshParticipantBootstrapRoomAvailability.leaderlessLocked,
                ClipLiveShareNativeV3BootstrapRejectionReason.roomLocked
            ),
            (
                6,
                MeshParticipantBootstrapRoomAvailability.ended,
                ClipLiveShareNativeV3BootstrapRejectionReason.roomEnded
            ),
        ] {
            let run = try await fixture.beginAdmission(
                memberContexts: [
                    fixture.participants[0].participantID: creatorContext
                ],
                candidateIndex: 1,
                routeNumber: UInt8(offset),
                availability: availability,
                at: fixture.time(10)
            )
            try await run.drain(at: fixture.time(10))
            let phase = await run.coordinator(
                for: run.candidateID
            ).snapshot().phase
            #expect(
                phase
                    == MeshParticipantBootstrapPhase.rejected(expected)
            )
            #expect(
                await run.recorder(for: run.candidateID)
                    .preparedPeerIDs().isEmpty
            )
        }
    }

    @Test("access word is an independent route-bound v3 admission gate")
    func accessWordAdmissionGate() async throws {
        let fixture = try MeshBootstrapFixture()
        let creatorContext =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.participants[0],
                creatorSigner: fixture.signers[0],
                at: fixture.time(0)
            )

        for (route, supplied, expected) in [
            (
                UInt8(10),
                Optional<String>.none,
                ClipLiveShareNativeV3BootstrapRejectionReason
                    .accessWordRequired
            ),
            (
                UInt8(11),
                Optional("WRONG-WORD"),
                ClipLiveShareNativeV3BootstrapRejectionReason
                    .invalidAccessWord
            ),
        ] {
            let run = try await fixture.beginAdmission(
                memberContexts: [
                    fixture.participants[0].participantID: creatorContext
                ],
                candidateIndex: 1,
                routeNumber: route,
                requiredAccessWord: "CALM-OTTER",
                candidateAccessWord: supplied,
                at: fixture.time(10)
            )
            try await run.drain(at: fixture.time(10))
            #expect(
                (await run.coordinator(for: run.candidateID).snapshot())
                    .phase == .rejected(expected)
            )
            #expect(
                await run.recorder(for: run.candidateID)
                    .preparedPeerIDs().isEmpty
            )
        }

        let accepted = try await fixture.beginAdmission(
            memberContexts: [
                fixture.participants[0].participantID: creatorContext
            ],
            candidateIndex: 1,
            routeNumber: 12,
            requiredAccessWord: "CALM-OTTER",
            candidateAccessWord: " calm-otter ",
            at: fixture.time(10)
        )
        try await accepted.drain(at: fixture.time(10))
        #expect(
            (await accepted.coordinator(for: accepted.leaderID).snapshot())
                .phase == .awaitingApproval
        )
    }

    @Test("rejection delivery failure still aborts provisional state")
    func rejectionFailureStillCleansUp() async throws {
        let fixture = try MeshBootstrapFixture()
        let context =
            try MeshParticipantBootstrapCoordinator.creatorGenesis(
                sessionID: fixture.sessionID,
                creator: fixture.participants[0],
                creatorSigner: fixture.signers[0],
                at: fixture.time(0)
            )
        let recorder = MeshBootstrapPairRecorder()
        let route = fixture.route(number: 14)
        let leader = try MeshParticipantBootstrapCoordinator(
            memberContext: context,
            rendezvousProof: route,
            send: { _, _ in
                throw MeshParticipantBootstrapError.sendFailed(
                    "route unavailable"
                )
            },
            pairHooks: .init(
                abort: { participantID in
                    await recorder.abort(participantID)
                }
            )
        )
        let hello = try ClipLiveShareNativeV3BootstrapHello(
            sessionID: fixture.sessionID,
            participantID: fixture.participants[1].participantID,
            identity: fixture.participants[1].identity,
            displayName: fixture.participants[1].displayName,
            capabilities: fixture.participants[1].capabilities,
            rendezvousProof: route,
            issuedAt: fixture.time(10),
            expiresAt: fixture.time(70)
        )
        try await leader.receive(
            .hello(.init(signing: hello, with: fixture.signers[1])),
            from: fixture.participants[1].participantID,
            at: fixture.time(10)
        )

        await #expect(throws: MeshParticipantBootstrapError.self) {
            try await leader.denyAdmission()
        }
        #expect((await leader.snapshot()).phase == .rejected(.denied))
        #expect(
            await recorder.abortedPeerIDs()
                == [fixture.participants[1].participantID]
        )
    }
}

private struct MeshBootstrapMessage: Sendable {
    let envelope: ClipLiveShareNativeV3BootstrapEnvelope
    let from: ClipLiveShareNativeV3ParticipantID
    let to: ClipLiveShareNativeV3ParticipantID
}

private actor MeshBootstrapNetwork {
    private var messages: [MeshBootstrapMessage] = []

    func enqueue(_ message: MeshBootstrapMessage) {
        messages.append(message)
    }

    func next() -> MeshBootstrapMessage? {
        guard !messages.isEmpty else { return nil }
        return messages.removeFirst()
    }
}

private actor MeshBootstrapPairRecorder {
    private var prepared:
        [ClipLiveShareNativeV3ParticipantID:
            MeshParticipantBootstrapProvisionalPair] = [:]
    private var relays: [ClipLiveShareNativeV3BootstrapRelayPayload] = []
    private var aborted: Set<ClipLiveShareNativeV3ParticipantID> = []
    private var promoted: [MeshParticipantBootstrapLaunchContext] = []

    func prepare(_ pair: MeshParticipantBootstrapProvisionalPair) {
        prepared[pair.remoteParticipantID] = pair
    }

    func receive(_ payload: ClipLiveShareNativeV3BootstrapRelayPayload) {
        relays.append(payload)
    }

    func abort(_ participantID: ClipLiveShareNativeV3ParticipantID) {
        aborted.insert(participantID)
    }

    func promote(_ context: MeshParticipantBootstrapLaunchContext) {
        promoted.append(context)
    }

    func preparedPeerIDs() -> Set<ClipLiveShareNativeV3ParticipantID> {
        Set(prepared.keys)
    }

    func firstPreparedPair() -> MeshParticipantBootstrapProvisionalPair? {
        prepared.values.first
    }

    func relayCount() -> Int { relays.count }

    func abortedPeerIDs() -> Set<ClipLiveShareNativeV3ParticipantID> {
        aborted
    }

    func promotedContextCount() -> Int { promoted.count }
}

private struct MeshBootstrapAdmissionRun {
    let network: MeshBootstrapNetwork
    let candidateID: ClipLiveShareNativeV3ParticipantID
    let leaderID: ClipLiveShareNativeV3ParticipantID
    let memberIDs: [ClipLiveShareNativeV3ParticipantID]
    let coordinators:
        [ClipLiveShareNativeV3ParticipantID:
            MeshParticipantBootstrapCoordinator]
    let recorders:
        [ClipLiveShareNativeV3ParticipantID: MeshBootstrapPairRecorder]

    func coordinator(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> MeshParticipantBootstrapCoordinator {
        coordinators[participantID]!
    }

    func recorder(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> MeshBootstrapPairRecorder {
        recorders[participantID]!
    }

    func drain(at now: ClipLiveShareNativeTimestamp) async throws {
        var delivered = 0
        while let message = await network.next() {
            delivered += 1
            guard delivered < 1_000 else {
                Issue.record("Bootstrap message loop did not quiesce")
                return
            }
            let receiver = try #require(coordinators[message.to])
            try await receiver.receive(
                message.envelope,
                from: message.from,
                at: now
            )
        }
    }

    func markEveryPairReady(
        at now: ClipLiveShareNativeTimestamp
    ) async throws {
        for memberID in memberIDs {
            try await coordinator(for: memberID).markPeerLinkReady(
                with: candidateID,
                at: now
            )
        }
        for memberID in memberIDs {
            try await coordinator(for: candidateID).markPeerLinkReady(
                with: memberID,
                at: now
            )
        }
    }

    func approve(at now: ClipLiveShareNativeTimestamp) async throws {
        try await coordinator(for: leaderID).approveAdmission(at: now)
    }

    func completedContexts() async throws
        -> [ClipLiveShareNativeV3ParticipantID:
            MeshParticipantBootstrapLaunchContext]
    {
        var result:
            [ClipLiveShareNativeV3ParticipantID:
                MeshParticipantBootstrapLaunchContext] = [:]
        for (participantID, coordinator) in coordinators {
            guard let context = await coordinator.launchContext() else {
                throw CancellationError()
            }
            result[participantID] = context
        }
        return result
    }
}

private struct MeshBootstrapFixture {
    let sessionID = try! ClipLiveShareSessionID(
        rawValue: "mesh-bootstrap-app-tests"
    )
    let origin = try! ClipLiveShareNativeTimestamp(
        millisecondsSince1970: 1_900_000_000_000
    )
    let signers: [ClipLiveShareSoftwareIdentitySigner]
    let participants: [ClipLiveShareNativeV3Participant]

    init() throws {
        signers = try (1...4).map {
            try ClipLiveShareSoftwareIdentitySigner(
                rawRepresentation: Data(repeating: UInt8($0), count: 32)
            )
        }
        // Later candidates deliberately have smaller IDs. This proves a
        // candidate can initiate all of its pair challenges rather than
        // accidentally relying on existing members to be lower ordered.
        let participantBytes: [UInt8] = [0x40, 0x30, 0x20, 0x10]
        participants = try zip(participantBytes, signers).enumerated().map {
            index, value in
            try ClipLiveShareNativeV3Participant(
                participantID: ClipLiveShareNativeV3ParticipantID(
                    bytes: Data(repeating: value.0, count: 16)
                ),
                identity: value.1.publicKey,
                displayName: "Participant \(index + 1)",
                capabilities: .current
            )
        }
    }

    func time(_ seconds: Int64) -> ClipLiveShareNativeTimestamp {
        try! origin.adding(milliseconds: seconds * 1_000)
    }

    func route(
        number: UInt8
    ) -> ClipLiveShareNativeV3RendezvousProof {
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

    func signer(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> ClipLiveShareSoftwareIdentitySigner {
        signers[
            participants.firstIndex(where: {
                $0.participantID == participantID
            })!
        ]
    }

    func participant(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> ClipLiveShareNativeV3Participant {
        participants.first(where: {
            $0.participantID == participantID
        })!
    }

    func send(
        from participantID: ClipLiveShareNativeV3ParticipantID,
        over network: MeshBootstrapNetwork
    ) -> MeshParticipantBootstrapCoordinator.RendezvousSend {
        { envelope, destination in
            await network.enqueue(
                .init(
                    envelope: envelope,
                    from: participantID,
                    to: destination
                )
            )
        }
    }

    func beginAdmission(
        memberContexts:
            [ClipLiveShareNativeV3ParticipantID:
                MeshParticipantBootstrapLaunchContext],
        candidateIndex: Int,
        routeNumber: UInt8,
        availability: MeshParticipantBootstrapRoomAvailability = .active,
        requiredAccessWord: String? = nil,
        candidateAccessWord: String? = nil,
        at now: ClipLiveShareNativeTimestamp
    ) async throws -> MeshBootstrapAdmissionRun {
        let network = MeshBootstrapNetwork()
        let route = route(number: routeNumber)
        var coordinators:
            [ClipLiveShareNativeV3ParticipantID:
                MeshParticipantBootstrapCoordinator] = [:]
        var recorders:
            [ClipLiveShareNativeV3ParticipantID:
                MeshBootstrapPairRecorder] = [:]
        let leaderID = try #require(
            memberContexts.values.first?.signedMembership.snapshot
                .leaderParticipantID
        )

        for (participantID, context) in memberContexts {
            let recorder = MeshBootstrapPairRecorder()
            recorders[participantID] = recorder
            coordinators[participantID] =
                try MeshParticipantBootstrapCoordinator(
                    memberContext: context,
                    rendezvousProof:
                        participantID == leaderID ? route : nil,
                    availability: availability,
                    requiredAccessWord:
                        participantID == leaderID
                            ? requiredAccessWord
                            : nil,
                    send: send(from: participantID, over: network),
                    pairHooks: hooks(recorder: recorder)
                )
        }

        let candidate = participants[candidateIndex]
        let recorder = MeshBootstrapPairRecorder()
        recorders[candidate.participantID] = recorder
        let candidateCoordinator =
            try MeshParticipantBootstrapCoordinator(
                candidateSessionID: sessionID,
                candidate: candidate,
                candidateSigner: signers[candidateIndex],
                admissionLeaderParticipantID: leaderID,
                expectedFoundingCreatorIdentity: participants[0].identity,
                rendezvousProof: route,
                accessWord: candidateAccessWord,
                send: send(from: candidate.participantID, over: network),
                pairHooks: hooks(recorder: recorder)
            )
        coordinators[candidate.participantID] = candidateCoordinator
        try await candidateCoordinator.requestJoin(at: now)
        return MeshBootstrapAdmissionRun(
            network: network,
            candidateID: candidate.participantID,
            leaderID: leaderID,
            memberIDs: memberContexts.keys.sorted(),
            coordinators: coordinators,
            recorders: recorders
        )
    }

    private func hooks(
        recorder: MeshBootstrapPairRecorder
    ) -> MeshParticipantBootstrapPairHooks {
        .init(
            prepare: { pair in
                await recorder.prepare(pair)
            },
            receiveRelay: { payload, _, _ in
                await recorder.receive(payload)
            },
            abort: { participantID in
                await recorder.abort(participantID)
            },
            promote: { context in
                await recorder.promote(context)
            }
        )
    }
}
