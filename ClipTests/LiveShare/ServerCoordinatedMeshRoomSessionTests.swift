import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import Testing

@testable import Clip

@Suite("Server-coordinated mesh room session")
struct ServerCoordinatedMeshRoomSessionTests {
    @Test("discovery supplies ICE capabilities before media construction")
    func discoveryPrecedesMediaConstruction() async throws {
        let fixture = try ServerRoomSessionFixture()
        let bootstrap = try fixture.creatorBootstrap()
        let transport = ServerRoomSessionTransportProbe()
        let ordering = ServerRoomSessionOrderingProbe()
        let capabilities = try fixture.capabilities()
        let mediaFactory = ServerRoomSessionPeerTransportFactory()
        let session = ServerCoordinatedMeshRoomSession(
            bootstrap: .init(bootstrap),
            controlPlane: .init(
                discover: { _ in
                    await ordering.record("discover")
                    return capabilities
                },
                create: { _, _, _ in
                    await ordering.record("create")
                }
            ),
            transport: await transport.client(),
            mediaFactory: { supplied, send in
                #expect(supplied == capabilities)
                await ordering.record("media")
                return fixture.mediaClient(
                    factory: mediaFactory,
                    sendPairSignal: send
                )
            }
        )

        try await session.start()
        #expect(await ordering.entries() == ["discover", "media", "create"])
        #expect(
            await transport.authentication()
                == .creator(ownerCapability: bootstrap.createRequest.ownerToken)
        )
        await session.close()
    }

    @Test("two three four roster growth retains AB and the invite")
    func rosterGrowthRetainsPairsAndInvite() async throws {
        let fixture = try ServerRoomSessionFixture()
        let prepared = try fixture.preparedRooms(memberCount: 4)
        let bootstrap = try fixture.creatorBootstrap()
        let originalInviteURL = try bootstrap.invite.url
        let transport = ServerRoomSessionTransportProbe()
        let peerFactory = ServerRoomSessionPeerTransportFactory()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: peerFactory
        )
        try await session.start()

        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 2, revision: 1)
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().media?.links.links.count == 1
        }
        let originalAB = try #require(
            await peerFactory.transport(
                for: fixture.participants[1].descriptor.participantID
            )
        )

        // C can signal before the creator receives the roster that creates AC.
        // The room layer holds the encrypted envelope until the exact verified
        // pair context exists.
        var cRoom = try #require(prepared.candidateRooms[fixture.handles[2]])
        let signal = try cRoom.sealPairSignal(
            to: fixture.handles[0],
            payload: .offer(epoch: .init(rawValue: 1), sdp: "v=0\r\n")
        ).routedFrom(fixture.handles[2])
        await transport.emit(.message(.pairSignal(signal)))

        await transport.emit(.message(.rosterSnapshot(
            try prepared.roster(memberCount: 3, revision: 2)
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().media?.links.links.count == 2
        }
        let transportAC = try #require(
            await peerFactory.transport(
                for: fixture.participants[2].descriptor.participantID
            )
        )
        try await serverRoomSessionEventually {
            await transportAC.remoteDescriptions().count == 1
        }
        await transport.emit(.message(.rosterSnapshot(
            try prepared.roster(memberCount: 4, revision: 3)
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().media?.links.links.count == 3
        }

        #expect(
            await peerFactory.transport(
                for: fixture.participants[1].descriptor.participantID
            ) === originalAB
        )
        #expect(try await session.snapshot().invite?.url == originalInviteURL)

        // A signaling reconnect retains the live media/source snapshot and a
        // repeated authoritative roster resumes the room by reconciling the
        // already-started runtime. It must never try to start a second media
        // runtime or tear down AB.
        await transport.emit(.reconnecting(role: .creator, attempt: 1))
        try await serverRoomSessionEventually {
            let snapshot = await session.snapshot()
            return snapshot.phase == .active
                && snapshot.media?.links.links.count == 3
        }
        await transport.emit(.message(.rosterSnapshot(
            try prepared.roster(memberCount: 4, revision: 3)
        )))
        try await serverRoomSessionEventually {
            let snapshot = await session.snapshot()
            return snapshot.phase == .active
                && snapshot.media?.links.links.count == 3
        }
        #expect(
            await peerFactory.transport(
                for: fixture.participants[1].descriptor.participantID
            ) === originalAB
        )

        // Removing C and D removes only their incident links; AB is retained.
        await transport.emit(.message(.rosterSnapshot(
            try prepared.roster(memberCount: 2, revision: 4)
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().media?.links.links.count == 1
        }
        #expect(
            await peerFactory.transport(
                for: fixture.participants[1].descriptor.participantID
            ) === originalAB
        )

        // Link connectivity is media state, not membership. It updates the
        // session snapshot without requiring another roster revision.
        await originalAB.emit(.connectionStateChanged(.connected))
        await originalAB.emit(.controlChannelStateChanged(.open))
        try await serverRoomSessionEventually {
            await session.snapshot().media?.links.links.first?.isReady == true
        }
        await session.close()
    }

    @Test("participant presentation uses canonical invite and live transport diagnostics")
    @MainActor
    func participantPresentationUsesCanonicalInviteAndDiagnostics()
        async throws
    {
        let fixture = try ServerRoomSessionFixture()
        let roomCode = try ClipLiveShareServerRoomV4RoomCode(
            rawValue: "INVITE42"
        )
        let bootstrap = try fixture.creatorBootstrap(roomCode: roomCode)
        let prepared = try fixture.preparedRooms(
            memberCount: 2,
            bootstrap: bootstrap
        )
        let transport = ServerRoomSessionTransportProbe()
        let peerFactory = ServerRoomSessionPeerTransportFactory()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: peerFactory
        )
        let coordinator = ServerCoordinatedMeshParticipantCoordinator(
            localParticipantID:
                fixture.participants[0].descriptor.participantID,
            localIdentity: Data(repeating: 0xD1, count: 65),
            localDisplayName:
                fixture.participants[0].descriptor.displayName,
            session: .init(session),
            initialSettings: .init(videoCodec: .av1)
        )
        coordinator.start()

        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 2, revision: 1)
        )))
        try await serverRoomSessionEventually {
            await MainActor.run {
                coordinator.presentationModel.snapshot.participantCount == 2
            }
        }

        let remoteID = fixture.participants[1].descriptor.participantID
        let peer = try #require(
            await peerFactory.transport(for: remoteID)
        )
        await peer.emit(.connectionStateChanged(.connected))
        await peer.emit(.controlChannelStateChanged(.open))

        let instanceID = ClipLiveShareSourceInstanceID.random()
        let trackID = try ClipLiveShareMediaTrackID(
            rawValue: "diagnostic-track"
        )
        let source = try ClipLiveShareNativeV3PublishedSource(
            key: .init(
                ownerParticipantID:
                    fixture.participants[0].descriptor.participantID,
                sourceInstanceID: instanceID
            ),
            descriptor: .init(
                sourceInstanceID: instanceID,
                stream: .init(
                    id: .init(rawValue: "diagnostic-stream"),
                    mediaTrackID: trackID,
                    active: true,
                    focused: true,
                    appName: "Fixture",
                    windowName: "Diagnostic Window",
                    width: 1_280,
                    height: 720,
                    order: 0,
                    sourcePointWidth: 1_280,
                    sourcePointHeight: 720
                )
            )
        )
        try await session.publishLocalSources([source])
        await peer.emit(.statisticsChanged(.init(
            capturedAt: Date(timeIntervalSince1970: 10),
            route: .direct,
            currentRoundTripTimeMilliseconds: 18,
            availableOutgoingBitrateBps: 21_000_000,
            bytesSent: 12_345,
            bytesReceived: 67_890,
            packetsLost: 3,
            videoSources: [
                .init(
                    direction: .outgoing,
                    trackIdentifier: trackID.rawValue,
                    codec: "VP8",
                    width: 1_280,
                    height: 720,
                    framesPerSecond: 30,
                    bytes: 12_345,
                    frames: 300,
                    packets: 320,
                    packetsLost: 3
                )
            ]
        )))

        try await serverRoomSessionEventually {
            await MainActor.run {
                let snapshot = coordinator.presentationModel.snapshot
                return snapshot.peerDiagnostics.first?.bytesReceived
                        == 67_890
                    && snapshot.outgoingDiagnostics.first?.codec == "VP8"
            }
        }
        let snapshot = coordinator.presentationModel.snapshot
        #expect(snapshot.roomName == "Room INVITE42")
        #expect(snapshot.invite?.roomCode == "INVITE42")
        #expect(snapshot.invite?.isAvailable == true)
        let diagnostics = try #require(snapshot.peerDiagnostics.first)
        #expect(diagnostics.roundTripMilliseconds == 18)
        #expect(diagnostics.availableOutgoingBitrateBps == 21_000_000)
        #expect(diagnostics.bytesSent == 12_345)
        #expect(diagnostics.bytesReceived == 67_890)
        #expect(diagnostics.packetsLost == 3)
        // The participant setting is AV1, but the current RTP statistics say
        // this negotiated sender is VP8. Diagnostics must report transport
        // truth rather than the requested preference.
        #expect(snapshot.settings.codec.codec == .av1)
        #expect(snapshot.outgoingDiagnostics.first?.codec == "VP8")

        await coordinator.close()
    }

    @Test("ask-before-join exposes approval and explicit admission")
    func approvalFlow() async throws {
        let fixture = try ServerRoomSessionFixture()
        let bootstrap = try fixture.creatorBootstrap(
            policy: .open(askBeforeJoining: true)
        )
        let candidate = try fixture.candidateBootstrap(
            index: 1,
            invite: bootstrap.invite
        )
        let transport = ServerRoomSessionTransportProbe()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: .init()
        )
        try await session.start()
        await transport.emit(.message(.joinKnock(
            candidateHandle: fixture.candidateHandles[1],
            sequence: 1,
            payload: candidate.joinKnock
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().room.pendingApprovals.count == 1
        }
        #expect(await transport.admissions().isEmpty)

        try await session.approve(fixture.candidateHandles[1])
        #expect(await transport.admissions() == [fixture.candidateHandles[1]])
        #expect(try await session.snapshot().invite?.url == bootstrap.invite.url)
        await session.close()
    }

    @Test("Access Word friend join is prompted before creator approval")
    func accessWordFriendJoinPromptsBeforeApproval() async throws {
        let fixture = try ServerRoomSessionFixture()
        let bootstrap = try fixture.creatorBootstrap(
            policy: .requiringAccessWord(
                "secret word",
                askBeforeJoining: false
            )
        )
        let candidate = try fixture.candidateBootstrap(
            index: 1,
            invite: bootstrap.invite,
            requiresCreatorApproval: true
        )
        let transport = ServerRoomSessionTransportProbe()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: .init()
        )

        try await session.start()
        await transport.emit(.message(.joinKnock(
            candidateHandle: fixture.candidateHandles[1],
            sequence: 1,
            payload: candidate.joinKnock
        )))

        try await serverRoomSessionEventually {
            await transport.denials().count == 1
        }
        let denial = try #require(await transport.denials().first)
        #expect(denial.0 == fixture.candidateHandles[1])
        #expect(
            denial.1
                == ServerCoordinatedMeshAdmissionDenialReason
                    .accessWordRequired
        )
        #expect(await session.snapshot().room.pendingApprovals.isEmpty)
        await session.close()
    }

    @Test("candidate maps the Access Word denial to a typed prompt event")
    func accessWordDenialEmitsPromptEvent() async throws {
        let fixture = try ServerRoomSessionFixture()
        let creator = try fixture.creatorBootstrap(
            policy: .requiringAccessWord(
                "secret word",
                askBeforeJoining: false
            )
        )
        let candidate = try fixture.candidateBootstrap(
            index: 1,
            invite: creator.invite,
            requiresCreatorApproval: true
        )
        let transport = ServerRoomSessionTransportProbe()
        let session = fixture.session(
            bootstrap: .init(candidate, invite: creator.invite),
            transport: transport,
            peerFactory: .init()
        )
        let events = await session.events()
        let probe = ServerRoomSessionEventProbe()
        let eventTask = Task {
            for await event in events { await probe.record(event) }
        }

        try await session.start()
        await transport.emit(.message(.candidateOpened(
            candidateHandle: fixture.candidateHandles[1],
            roomDescriptor: creator.createRequest.descriptor
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().phase == .waitingForAdmission
        }
        await transport.emit(.message(.denyCandidate(
            candidateHandle: nil,
            reason: ServerCoordinatedMeshAdmissionDenialReason
                .accessWordRequired
        )))
        await transport.emit(.closed)

        try await serverRoomSessionEventually {
            await probe.didRequireAccessWord()
        }
        if case let .ended(reason) = await session.snapshot().phase {
            #expect(reason == "The room requires an Access Word.")
        } else {
            Issue.record("Expected Access Word denial to end this attempt")
        }
        eventTask.cancel()
    }

    @Test("candidate maps an admission denial to a typed event")
    func admissionDenialEmitsTypedEvent() async throws {
        let fixture = try ServerRoomSessionFixture()
        let creator = try fixture.creatorBootstrap()
        let candidate = try fixture.candidateBootstrap(
            index: 1,
            invite: creator.invite,
            requiresCreatorApproval: true
        )
        let transport = ServerRoomSessionTransportProbe()
        let session = fixture.session(
            bootstrap: .init(candidate, invite: creator.invite),
            transport: transport,
            peerFactory: .init()
        )
        let events = await session.events()
        let probe = ServerRoomSessionEventProbe()
        let eventTask = Task {
            for await event in events { await probe.record(event) }
        }

        try await session.start()
        await transport.emit(.message(.candidateOpened(
            candidateHandle: fixture.candidateHandles[1],
            roomDescriptor: creator.createRequest.descriptor
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().phase == .waitingForAdmission
        }
        await transport.emit(.message(.denyCandidate(
            candidateHandle: nil,
            reason: "Not today."
        )))

        try await serverRoomSessionEventually {
            await probe.didDenyAdmission(reason: "Not today.")
        }
        if case let .ended(reason) = await session.snapshot().phase {
            #expect(reason == "Not today.")
        } else {
            Issue.record("Expected admission denial to end this attempt")
        }
        eventTask.cancel()
    }

    @Test("one pair failure is local and creator end is terminal")
    func isolatedPairFailureAndCreatorEnd() async throws {
        let fixture = try ServerRoomSessionFixture()
        let prepared = try fixture.preparedRooms(memberCount: 3)
        let bootstrap = try fixture.creatorBootstrap()
        let transport = ServerRoomSessionTransportProbe()
        let peerFactory = ServerRoomSessionPeerTransportFactory()
        await peerFactory.failCreation(
            for: fixture.participants[2].descriptor.participantID
        )
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: peerFactory
        )
        try await session.start()
        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 3, revision: 1)
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().phase == .active
        }
        let active = await session.snapshot()
        #expect(active.room.members.count == 3)
        #expect(active.media?.reconciliation.failedPairs.count == 1)
        #expect(active.media?.links.links.count == 1)

        await transport.emit(.message(.roomEnded(reason: "Creator left")))
        try await serverRoomSessionEventually {
            await session.snapshot().phase == .ended(reason: "Creator left")
        }
        await transport.emit(.closed)
        #expect(await session.snapshot().media == nil)
    }

    @Test("invalid candidate proof is denied without affecting an active pair")
    func invalidCandidateIsScoped() async throws {
        let fixture = try ServerRoomSessionFixture()
        let prepared = try fixture.preparedRooms(memberCount: 2)
        let bootstrap = try fixture.creatorBootstrap()
        let transport = ServerRoomSessionTransportProbe()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: .init()
        )
        try await session.start()
        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 2, revision: 1)
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().phase == .active
        }

        let candidate = try fixture.candidateBootstrap(
            index: 2,
            invite: bootstrap.invite
        )
        var corrupted = candidate.joinKnock.ciphertext
        corrupted[corrupted.startIndex] ^= 0x01
        let invalid = try ClipLiveShareServerRoomV4OpaqueJoinKnock(
            ciphertext: corrupted
        )
        await transport.failNextDenialSend()
        await transport.emit(.message(.joinKnock(
            candidateHandle: fixture.candidateHandles[2],
            sequence: 1,
            payload: invalid
        )))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.denials().isEmpty)
        #expect(await session.snapshot().phase == .active)
        await transport.emit(.reconnecting(role: .creator, attempt: 1))
        await transport.emit(.connected(role: .creator, attempt: 1))
        try await serverRoomSessionEventually {
            await transport.denials().count == 1
        }
        let snapshot = await session.snapshot()
        #expect(snapshot.phase == .active)
        #expect(snapshot.media?.links.links.count == 1)
        #expect(await transport.denials().first?.1
            == "This invitation or access proof is not valid.")
        await session.close()
    }

    @Test("replayed pair signal fails only its authenticated edge")
    func rejectedPairSignalIsScoped() async throws {
        let fixture = try ServerRoomSessionFixture()
        let prepared = try fixture.preparedRooms(memberCount: 3)
        let bootstrap = try fixture.creatorBootstrap()
        let transport = ServerRoomSessionTransportProbe()
        let factory = ServerRoomSessionPeerTransportFactory()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: factory
        )
        let events = await session.events()
        let probe = ServerRoomSessionEventProbe()
        let eventTask = Task {
            for await event in events { await probe.record(event) }
        }
        try await session.start()
        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 3, revision: 1)
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().media?.links.links.count == 2
        }

        var cRoom = try #require(prepared.candidateRooms[fixture.handles[2]])
        let signal = try cRoom.sealPairSignal(
            to: fixture.handles[0],
            payload: .offer(epoch: .init(rawValue: 1), sdp: "v=0\r\n")
        ).routedFrom(fixture.handles[2])
        await transport.emit(.message(.pairSignal(signal)))
        await transport.emit(.message(.pairSignal(signal)))
        try await serverRoomSessionEventually {
            await probe.didFail(fixture.participants[2].descriptor.participantID)
        }
        let snapshot = await session.snapshot()
        #expect(snapshot.phase == .active)
        #expect(snapshot.media?.links.links.count == 2)
        #expect(await factory.transport(
            for: fixture.participants[1].descriptor.participantID
        ) != nil)
        await session.close()
        eventTask.cancel()
    }

    @Test("pre-roster pair signal overflow is nonterminal")
    func pendingSignalOverflowIsScoped() async throws {
        let fixture = try ServerRoomSessionFixture()
        let prepared = try fixture.preparedRooms(memberCount: 3)
        let bootstrap = try fixture.creatorBootstrap()
        let transport = ServerRoomSessionTransportProbe()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: .init()
        )
        try await session.start()
        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 2, revision: 1)
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().phase == .active
        }
        var cRoom = try #require(prepared.candidateRooms[fixture.handles[2]])
        for index in 1...140 {
            let signal = try cRoom.sealPairSignal(
                to: fixture.handles[0],
                payload: .iceCandidate(
                    epoch: .init(rawValue: 1),
                    candidate: "candidate:\(index)",
                    mediaID: "0",
                    mediaLineIndex: 0
                )
            ).routedFrom(fixture.handles[2])
            await transport.emit(.message(.pairSignal(signal)))
        }
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = await session.snapshot()
        #expect(snapshot.phase == .active)
        #expect(snapshot.media?.links.links.count == 1)
        await session.close()
    }

    @Test("candidate join write retries with a fresh monotonic sequence")
    func candidateJoinRetriesAfterReconnect() async throws {
        let fixture = try ServerRoomSessionFixture()
        let creator = try fixture.creatorBootstrap()
        let candidate = try fixture.candidateBootstrap(
            index: 1,
            invite: creator.invite
        )
        let transport = ServerRoomSessionTransportProbe()
        let session = fixture.session(
            bootstrap: .init(candidate, invite: creator.invite),
            transport: transport,
            peerFactory: .init()
        )
        try await session.start()
        let initialSnapshot = await session.snapshot()
        #expect(initialSnapshot.invite == creator.invite)
        #expect(initialSnapshot.invite?.roomCode == creator.invite.roomCode)
        await transport.failNextJoinSend()
        await transport.emit(.message(.candidateOpened(
            candidateHandle: fixture.candidateHandles[1],
            roomDescriptor: creator.createRequest.descriptor
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().phase == .connecting
        }
        await transport.emit(.reconnecting(role: .candidate, attempt: 1))
        await transport.emit(.connected(role: .candidate, attempt: 1))
        await transport.emit(.message(.candidateOpened(
            candidateHandle: fixture.candidateHandles[2],
            roomDescriptor: creator.createRequest.descriptor
        )))
        try await serverRoomSessionEventually {
            await transport.joins() == [2]
        }
        #expect(await session.snapshot().phase == .waitingForAdmission)
        await session.close()
    }

    @Test("ambiguous approval write replays without disrupting active pairs")
    func approvalWriteRetriesAfterReconnect() async throws {
        let fixture = try ServerRoomSessionFixture()
        let prepared = try fixture.preparedRooms(memberCount: 2)
        let bootstrap = try fixture.creatorBootstrap(
            policy: .open(askBeforeJoining: true)
        )
        let candidate = try fixture.candidateBootstrap(
            index: 2,
            invite: bootstrap.invite
        )
        let transport = ServerRoomSessionTransportProbe()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: .init()
        )
        try await session.start()
        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 2, revision: 1)
        )))
        await transport.emit(.message(.joinKnock(
            candidateHandle: fixture.candidateHandles[2],
            sequence: 1,
            payload: candidate.joinKnock
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().room.pendingApprovals.count == 1
        }
        await transport.failNextAdmissionSend()
        try await session.approve(fixture.candidateHandles[2])
        #expect(await transport.admissions().isEmpty)

        await transport.emit(.reconnecting(role: .creator, attempt: 1))
        await transport.emit(.connected(role: .creator, attempt: 1))
        try await serverRoomSessionEventually {
            await transport.admissions() == [fixture.candidateHandles[2]]
        }
        let snapshot = await session.snapshot()
        #expect(snapshot.phase == .active)
        #expect(snapshot.media?.links.links.count == 1)
        await session.close()
    }

    @Test("pair signaling write retries while unrelated pair stays allocated")
    func pairSignalWriteRetriesAfterReconnect() async throws {
        let fixture = try ServerRoomSessionFixture()
        let prepared = try fixture.preparedRooms(memberCount: 3)
        let bootstrap = try fixture.creatorBootstrap()
        let transport = ServerRoomSessionTransportProbe()
        let factory = ServerRoomSessionPeerTransportFactory()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: factory
        )
        try await session.start()
        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 3, revision: 1)
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().media?.links.links.count == 2
        }
        let peerB = try #require(await factory.transport(
            for: fixture.participants[1].descriptor.participantID
        ))
        let peerC = try #require(await factory.transport(
            for: fixture.participants[2].descriptor.participantID
        ))
        await transport.failNextPairSignalSend()
        await peerB.emit(.localNegotiation(.sessionDescription(.init(
            kind: .offer,
            sdp: "v=0\r\no=retry\r\n"
        ))))
        try await serverRoomSessionEventually {
            await transport.attemptedPairSignals().count == 1
        }
        #expect(await transport.sentPairSignals().isEmpty)
        let ambiguousAttempt = try #require(
            await transport.attemptedPairSignals().first
        )

        await transport.emit(.reconnecting(role: .creator, attempt: 1))
        await transport.emit(.connected(role: .creator, attempt: 1))
        try await serverRoomSessionEventually {
            await transport.sentPairSignals().count == 1
        }
        #expect(
            await transport.attemptedPairSignals()
                == [ambiguousAttempt, ambiguousAttempt]
        )
        #expect(await transport.sentPairSignals() == [ambiguousAttempt])
        #expect(await factory.transport(
            for: fixture.participants[2].descriptor.participantID
        ) === peerC)
        #expect(await session.snapshot().phase == .active)
        await session.close()
    }

    @Test("concurrent pair sends use one serialized outbox drain")
    func concurrentPairSendsAreSerialized() async throws {
        let fixture = try ServerRoomSessionFixture()
        let prepared = try fixture.preparedRooms(memberCount: 3)
        let bootstrap = try fixture.creatorBootstrap()
        let transport = ServerRoomSessionTransportProbe()
        let callback = ServerRoomSessionPairSignalCallbackProbe()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: .init(),
            pairSignalCallbackProbe: callback
        )
        try await session.start()
        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 3, revision: 1)
        )))
        try await serverRoomSessionEventually {
            let hasTwoLinks = await session.snapshot().media?.links.links.count
                == 2
            let callbackIsInstalled = await callback.isInstalled()
            return hasTwoLinks && callbackIsInstalled
        }
        let pairs = try #require(
            await session.snapshot().verifiedRoom?.pairs.sorted {
                $0.remoteHandle < $1.remoteHandle
            }
        )
        #expect(pairs.count == 2)
        let firstPair = try #require(pairs.first)
        let secondPair = try #require(pairs.last)

        await transport.suspendNextPairSignalSend()
        async let firstSend: Void = callback.send(
            context: firstPair.context,
            payload: .offer(
                epoch: firstPair.epoch,
                sdp: "v=0\r\no=first-concurrent\r\n"
            ),
            remoteHandle: firstPair.remoteHandle
        )
        try await serverRoomSessionEventually {
            await transport.isPairSignalSendSuspended()
        }

        // The room actor is re-entrant while the first transport write is
        // suspended. This second callback must enqueue behind it and return
        // without starting another drain over the same queue head.
        let secondSend = Task {
            try await callback.send(
                context: secondPair.context,
                payload: .offer(
                    epoch: secondPair.epoch,
                    sdp: "v=0\r\no=second-concurrent\r\n"
                ),
                remoteHandle: secondPair.remoteHandle
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.attemptedPairSignals().count == 1)

        await transport.resumeSuspendedPairSignalSend()
        try await firstSend
        try await secondSend.value
        try await serverRoomSessionEventually {
            await transport.sentPairSignals().count == 2
        }
        let attempts = await transport.attemptedPairSignals()
        #expect(attempts.count == 2)
        #expect(attempts.map(\.pairID) == [
            firstPair.context.pairID,
            secondPair.context.pairID,
        ])
        #expect(Set(attempts.map { "\($0.pairID.rawValue):\($0.sequence)" }).count == 2)
        #expect(await transport.sentPairSignals() == attempts)
        await session.close()
    }

    @Test("a failed queue head does not fail a delivered later pair")
    func permanentPairSendFailurePreservesPerEnvelopeResult() async throws {
        let fixture = try ServerRoomSessionFixture()
        let prepared = try fixture.preparedRooms(memberCount: 3)
        let bootstrap = try fixture.creatorBootstrap()
        let transport = ServerRoomSessionTransportProbe()
        let callback = ServerRoomSessionPairSignalCallbackProbe()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: .init(),
            pairSignalCallbackProbe: callback
        )
        try await session.start()
        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 3, revision: 1)
        )))
        try await serverRoomSessionEventually {
            let hasTwoLinks = await session.snapshot().media?.links.links.count
                == 2
            let callbackIsInstalled = await callback.isInstalled()
            return hasTwoLinks && callbackIsInstalled
        }
        let pairs = try #require(
            await session.snapshot().verifiedRoom?.pairs.sorted {
                $0.remoteHandle < $1.remoteHandle
            }
        )
        let firstPair = try #require(pairs.first)
        let secondPair = try #require(pairs.last)

        await transport.failNextPairSignalSend(with: .invalidMessage)
        await transport.suspendNextPairSignalSend()
        let firstSend = Task {
            try await callback.send(
                context: firstPair.context,
                payload: .offer(
                    epoch: firstPair.epoch,
                    sdp: "v=0\r\no=permanent-failure\r\n"
                ),
                remoteHandle: firstPair.remoteHandle
            )
        }
        try await serverRoomSessionEventually {
            await transport.isPairSignalSendSuspended()
        }
        let secondSend = Task {
            try await callback.send(
                context: secondPair.context,
                payload: .offer(
                    epoch: secondPair.epoch,
                    sdp: "v=0\r\no=must-not-be-stranded\r\n"
                ),
                remoteHandle: secondPair.remoteHandle
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        await transport.resumeSuspendedPairSignalSend()

        await #expect(
            throws: ClipLiveShareServerRoomV4TransportError.invalidMessage
        ) {
            try await firstSend.value
        }
        try await secondSend.value
        try await serverRoomSessionEventually {
            await transport.attemptedPairSignals().count == 2
        }
        let attempts = await transport.attemptedPairSignals()
        let secondAttempt = try #require(attempts.last)
        #expect(attempts.map(\.pairID) == [
            firstPair.context.pairID,
            secondPair.context.pairID,
        ])
        #expect(await transport.sentPairSignals() == [secondAttempt])
        await session.close()
    }

    @Test("closing a room resolves a pending pair callback")
    func closingRoomFailsPendingPairCallback() async throws {
        let fixture = try ServerRoomSessionFixture()
        let prepared = try fixture.preparedRooms(memberCount: 2)
        let bootstrap = try fixture.creatorBootstrap()
        let transport = ServerRoomSessionTransportProbe()
        let callback = ServerRoomSessionPairSignalCallbackProbe()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: .init(),
            pairSignalCallbackProbe: callback
        )
        try await session.start()
        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 2, revision: 1)
        )))
        try await serverRoomSessionEventually {
            let hasLink = await session.snapshot().media?.links.links.count == 1
            let callbackIsInstalled = await callback.isInstalled()
            return hasLink && callbackIsInstalled
        }
        let pair = try #require(
            await session.snapshot().verifiedRoom?.pairs.first
        )

        await transport.suspendNextPairSignalSend()
        let send = Task {
            try await callback.send(
                context: pair.context,
                payload: .offer(
                    epoch: pair.epoch,
                    sdp: "v=0\r\no=close-pending\r\n"
                ),
                remoteHandle: pair.remoteHandle
            )
        }
        try await serverRoomSessionEventually {
            await transport.isPairSignalSendSuspended()
        }

        await session.close()
        await #expect(throws: ServerCoordinatedMeshRoomSessionError.terminal) {
            try await send.value
        }
        await transport.resumeSuspendedPairSignalSend()
    }

    @Test("pair routing errors retry only their edge and never end the room")
    func pairProtocolErrorsAreScopedAndRecoverable() async throws {
        let fixture = try ServerRoomSessionFixture()
        let prepared = try fixture.preparedRooms(memberCount: 3)
        let bootstrap = try fixture.creatorBootstrap()
        let transport = ServerRoomSessionTransportProbe()
        let factory = ServerRoomSessionPeerTransportFactory()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: factory
        )
        try await session.start()
        await transport.emit(.message(.memberAdmitted(
            memberHandle: fixture.handles[0],
            reconnectCapability: nil,
            roster: try prepared.roster(memberCount: 3, revision: 1)
        )))
        try await serverRoomSessionEventually {
            await session.snapshot().media?.links.links.count == 2
        }
        let peerB = try #require(await factory.transport(
            for: fixture.participants[1].descriptor.participantID
        ))
        let peerC = try #require(await factory.transport(
            for: fixture.participants[2].descriptor.participantID
        ))
        await peerB.emit(.localNegotiation(.sessionDescription(.init(
            kind: .offer,
            sdp: "v=0\r\no=route-backpressure\r\n"
        ))))
        try await serverRoomSessionEventually {
            await transport.sentPairSignals().count == 1
        }
        let first = try #require(await transport.sentPairSignals().first)
        let pair = try ClipLiveShareServerRoomV4ProtocolErrorPair(
            pairID: first.pairID,
            remoteHandle: first.to,
            sequence: first.sequence
        )
        await transport.emit(.message(.protocolError(
            code: "route_backpressure",
            message: "The direct route is temporarily busy.",
            pair: pair
        )))
        try await serverRoomSessionEventually(timeout: .seconds(2)) {
            await transport.sentPairSignals().count == 2
        }
        let retried = try #require(await transport.sentPairSignals().last)
        #expect(retried == first)

        // Compatibility with a server that omitted pair correlation is still
        // nonterminal. It is intentionally not guessed onto every edge.
        await transport.emit(.message(.protocolError(
            code: "sequence_rejected",
            message: "A stale pair sequence was ignored.",
            pair: nil
        )))
        try await Task.sleep(for: .milliseconds(20))
        let snapshot = await session.snapshot()
        #expect(snapshot.phase == .active)
        #expect(snapshot.media?.links.links.count == 2)
        #expect(await factory.transport(
            for: fixture.participants[2].descriptor.participantID
        ) === peerC)
        await session.close()
    }

    @Test("room authentication protocol errors remain terminal")
    func roomProtocolErrorIsTerminal() async throws {
        let fixture = try ServerRoomSessionFixture()
        let bootstrap = try fixture.creatorBootstrap()
        let transport = ServerRoomSessionTransportProbe()
        let session = fixture.session(
            bootstrap: .init(bootstrap),
            transport: transport,
            peerFactory: .init()
        )
        try await session.start()
        await transport.emit(.message(.protocolError(
            code: "room_unauthorized",
            message: "The room capability was rejected.",
            pair: nil
        )))
        try await serverRoomSessionEventually {
            if case .ended = await session.snapshot().phase { true }
            else { false }
        }
    }
}

private actor ServerRoomSessionEventProbe {
    private var values: [ServerCoordinatedMeshRoomSessionEvent] = []
    func record(_ event: ServerCoordinatedMeshRoomSessionEvent) {
        values.append(event)
    }
    func didFail(_ participantID: ClipLiveShareNativeV3ParticipantID) -> Bool {
        values.contains {
            if case let .pairFailed(candidate, _) = $0 {
                candidate == participantID
            } else {
                false
            }
        }
    }
    func didRequireAccessWord() -> Bool {
        values.contains {
            if case .accessWordRequired = $0 { true } else { false }
        }
    }
    func didDenyAdmission(reason: String) -> Bool {
        values.contains {
            if case let .admissionDenied(candidate) = $0 {
                candidate == reason
            } else {
                false
            }
        }
    }
}

private actor ServerRoomSessionOrderingProbe {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func entries() -> [String] { values }
}

private actor ServerRoomSessionTransportProbe {
    private var continuation:
        AsyncStream<ClipLiveShareServerRoomV4TransportEvent>.Continuation?
    private var buffered: [ClipLiveShareServerRoomV4TransportEvent] = []
    private var connectedAuthentication:
        ClipLiveShareServerRoomV4SessionAuthentication?
    private var admitted: [ClipLiveShareServerRoomV4CandidateHandle] = []
    private var denied:
        [(ClipLiveShareServerRoomV4CandidateHandle, String)] = []
    private var joinSequences: [UInt64] = []
    private var pairSignals: [ClipLiveShareServerRoomV4PairSignalEnvelope] = []
    private var pairSignalAttempts:
        [ClipLiveShareServerRoomV4PairSignalEnvelope] = []
    private var admissionSendFailures = 0
    private var denialSendFailures = 0
    private var joinSendFailures = 0
    private var pairSendFailures:
        [ClipLiveShareServerRoomV4TransportError] = []
    private var shouldSuspendNextPairSignalSend = false
    private var pairSignalSendIsSuspended = false
    private var pairSignalSendContinuation: CheckedContinuation<Void, Never>?

    func client() -> ServerCoordinatedMeshRoomTransportClient {
        .init(
            events: { await self.eventStream() },
            connect: { _, _, authentication in
                await self.record(authentication: authentication)
            },
            sendJoinKnock: { sequence, _ in
                try await self.recordJoinSend(sequence)
            },
            admitCandidate: { handle, _ in
                try await self.recordAdmissionSend(handle)
            },
            denyCandidate: { handle, reason in
                try await self.recordDenial(handle, reason: reason)
            },
            sendPairSignal: { signal in
                try await self.recordPairSignalSend(signal)
            },
            removeMember: { _ in },
            leave: {},
            close: { await self.finish() }
        )
    }

    func emit(_ event: ClipLiveShareServerRoomV4TransportEvent) {
        if let continuation {
            continuation.yield(event)
        } else {
            buffered.append(event)
        }
    }

    func authentication() -> ClipLiveShareServerRoomV4SessionAuthentication? {
        connectedAuthentication
    }

    func admissions() -> [ClipLiveShareServerRoomV4CandidateHandle] { admitted }
    func denials() -> [(ClipLiveShareServerRoomV4CandidateHandle, String)] {
        denied
    }
    func joins() -> [UInt64] { joinSequences }
    func sentPairSignals() -> [ClipLiveShareServerRoomV4PairSignalEnvelope] {
        pairSignals
    }
    func attemptedPairSignals() -> [ClipLiveShareServerRoomV4PairSignalEnvelope] {
        pairSignalAttempts
    }
    func failNextAdmissionSend() { admissionSendFailures += 1 }
    func failNextDenialSend() { denialSendFailures += 1 }
    func failNextJoinSend() { joinSendFailures += 1 }
    func failNextPairSignalSend(
        with error: ClipLiveShareServerRoomV4TransportError = .sendFailed
    ) {
        pairSendFailures.append(error)
    }
    func suspendNextPairSignalSend() {
        shouldSuspendNextPairSignalSend = true
    }
    func isPairSignalSendSuspended() -> Bool { pairSignalSendIsSuspended }
    func resumeSuspendedPairSignalSend() {
        pairSignalSendContinuation?.resume()
        pairSignalSendContinuation = nil
    }

    private func eventStream()
        -> AsyncStream<ClipLiveShareServerRoomV4TransportEvent>
    {
        let pair = AsyncStream.makeStream(
            of: ClipLiveShareServerRoomV4TransportEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        continuation = pair.continuation
        for event in buffered { pair.continuation.yield(event) }
        buffered.removeAll()
        return pair.stream
    }

    private func record(
        authentication: ClipLiveShareServerRoomV4SessionAuthentication
    ) {
        connectedAuthentication = authentication
    }

    private func recordAdmissionSend(
        _ handle: ClipLiveShareServerRoomV4CandidateHandle
    ) throws {
        if admissionSendFailures > 0 {
            admissionSendFailures -= 1
            throw ClipLiveShareServerRoomV4TransportError.sendFailed
        }
        admitted.append(handle)
    }

    private func recordJoinSend(_ sequence: UInt64) throws {
        if joinSendFailures > 0 {
            joinSendFailures -= 1
            throw ClipLiveShareServerRoomV4TransportError.sendFailed
        }
        joinSequences.append(sequence)
    }

    private func recordPairSignalSend(
        _ signal: ClipLiveShareServerRoomV4PairSignalEnvelope
    ) async throws {
        pairSignalAttempts.append(signal)
        if shouldSuspendNextPairSignalSend {
            shouldSuspendNextPairSignalSend = false
            pairSignalSendIsSuspended = true
            await withCheckedContinuation { continuation in
                pairSignalSendContinuation = continuation
            }
            pairSignalSendIsSuspended = false
        }
        if !pairSendFailures.isEmpty {
            throw pairSendFailures.removeFirst()
        }
        pairSignals.append(signal)
    }

    private func recordDenial(
        _ handle: ClipLiveShareServerRoomV4CandidateHandle,
        reason: String
    ) throws {
        if denialSendFailures > 0 {
            denialSendFailures -= 1
            throw ClipLiveShareServerRoomV4TransportError.sendFailed
        }
        denied.append((handle, reason))
    }

    private func finish() {
        pairSignalSendContinuation?.resume()
        pairSignalSendContinuation = nil
        continuation?.finish()
        continuation = nil
    }
}

private actor ServerRoomSessionPairSignalCallbackProbe {
    private var callback: ServerCoordinatedMeshMediaRuntime.SendPairSignal?

    func install(_ callback: @escaping ServerCoordinatedMeshMediaRuntime.SendPairSignal) {
        self.callback = callback
    }

    func isInstalled() -> Bool { callback != nil }

    func send(
        context: ClipLiveShareServerRoomV4PairContext,
        payload: ClipLiveShareServerRoomV4PairSignalPayload,
        remoteHandle: ClipLiveShareServerRoomV4MemberHandle
    ) async throws {
        let callback = try #require(callback)
        try await callback(context, payload, remoteHandle)
    }
}

private struct ServerRoomSessionParticipant: Sendable {
    let signer: ClipLiveShareSoftwareIdentitySigner
    let pairIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity
    let descriptor: ClipLiveShareServerRoomV4MemberDescriptor
}

private struct ServerRoomSessionPreparedRooms {
    let creatorRecord: ClipLiveShareServerRoomV4OpaqueAdmissionRecord
    let records:
        [ClipLiveShareServerRoomV4MemberHandle:
            ClipLiveShareServerRoomV4OpaqueAdmissionRecord]
    let candidateRooms:
        [ClipLiveShareServerRoomV4MemberHandle:
            ClipLiveShareServerRoomV4ClientRoom]
    let creatorHandle: ClipLiveShareServerRoomV4MemberHandle

    func roster(
        memberCount: Int,
        revision: UInt64
    ) throws -> ClipLiveShareServerRoomV4RosterSnapshot {
        let included = Array(records.keys.sorted().prefix(memberCount))
        return try .init(
            revision: .init(rawValue: revision),
            creatorHandle: creatorHandle,
            members: included.map {
                .init(handle: $0, descriptor: records[$0]!, connected: true)
            }
        )
    }
}

private struct ServerRoomSessionFixture: Sendable {
    let endpoint = URL(string: "https://rooms.example.test")!
    let roomID: ClipLiveShareServerRoomV4RoomID
    let sessionID: ClipLiveShareSessionID
    let owner: ClipLiveShareServerRoomV4OwnerCapability
    let secret: ClipLiveShareServerRoomV4RoomAgreementSecret
    let admission: ClipLiveShareServerRoomV4AdmissionCapability
    let handles: [ClipLiveShareServerRoomV4MemberHandle]
    let candidateHandles: [ClipLiveShareServerRoomV4CandidateHandle]
    let participants: [ServerRoomSessionParticipant]

    init() throws {
        roomID = try .init(bytes: Data(repeating: 0xB1, count: 32))
        sessionID = try .init(rawValue: "server-room-session-tests")
        owner = try .init(bytes: Data(repeating: 0xB2, count: 32))
        secret = try .init(bytes: Data(repeating: 0xB3, count: 32))
        admission = try .init(bytes: Data(repeating: 0xB4, count: 32))
        handles = try (0..<4).map {
            try .init(bytes: Data(repeating: UInt8(0x20 + $0), count: 16))
        }
        candidateHandles = try handles.map { try .init(bytes: $0.bytes) }
        participants = try (0..<4).map { index in
            let signer = try ClipLiveShareSoftwareIdentitySigner(
                rawRepresentation: Data(repeating: UInt8(index + 1), count: 32)
            )
            let pairIdentity = ClipLiveShareServerRoomV4KeyAgreementIdentity()
            let participantID = try ClipLiveShareNativeV3ParticipantID(
                bytes: Data(repeating: UInt8(0x60 + index), count: 16)
            )
            return try .init(
                signer: signer,
                pairIdentity: pairIdentity,
                descriptor: .init(
                    participantID: participantID,
                    identity: signer.publicKey,
                    pairSignalingPublicKey: pairIdentity.publicKey,
                    displayName: "Member \(index + 1)",
                    deviceName: "Fixture Mac"
                )
            )
        }
    }

    func capabilities() throws -> ClipLiveShareServerRoomV4Capabilities {
        try .init(
            serverVersion: "test",
            maximumRooms: 100,
            iceServers: [
                .init(urls: ["turn:relay.example.test"], username: "u", credential: "p")
            ]
        )
    }

    func creatorBootstrap(
        policy: ClipLiveShareServerRoomV4AdmissionPolicy = .open(),
        roomCode: ClipLiveShareServerRoomV4RoomCode = .random()
    ) throws -> ClipLiveShareServerRoomV4CreatorBootstrap {
        try ClipLiveShareServerRoomV4ClientRoom.makeCreator(
            serviceEndpoint: endpoint,
            roomID: roomID,
            memberHandle: handles[0],
            sessionID: sessionID,
            ownerCapability: owner,
            roomAgreementSecret: secret,
            admissionCapability: admission,
            pairKeyIdentity: participants[0].pairIdentity,
            localDescriptor: participants[0].descriptor,
            signer: participants[0].signer,
            roomCode: roomCode,
            admissionPolicy: policy
        )
    }

    func candidateBootstrap(
        index: Int,
        invite: ClipLiveShareServerRoomV4Invite,
        accessWord: String? = nil,
        requiresCreatorApproval: Bool = false
    ) throws -> ClipLiveShareServerRoomV4CandidateBootstrap {
        try ClipLiveShareServerRoomV4ClientRoom.makeCandidate(
            invite: invite,
            pairKeyIdentity: participants[index].pairIdentity,
            localDescriptor: participants[index].descriptor,
            signer: participants[index].signer,
            accessWord: accessWord,
            requiresCreatorApproval: requiresCreatorApproval
        )
    }

    func preparedRooms(
        memberCount: Int,
        bootstrap suppliedBootstrap:
            ClipLiveShareServerRoomV4CreatorBootstrap? = nil
    ) throws
        -> ServerRoomSessionPreparedRooms
    {
        let bootstrap = try suppliedBootstrap ?? creatorBootstrap()
        var issuer = bootstrap.room
        var records = [handles[0]: bootstrap.createRequest.descriptor]
        var candidateRooms:
            [ClipLiveShareServerRoomV4MemberHandle:
                ClipLiveShareServerRoomV4ClientRoom] = [:]
        for index in 1..<memberCount {
            let candidate = try candidateBootstrap(
                index: index,
                invite: bootstrap.invite
            )
            guard case .admit(let command) = try issuer.consumeForwardedJoinKnock(
                candidateHandle: candidateHandles[index],
                payload: candidate.joinKnock
            ) else {
                throw ClipLiveShareServerRoomV4ClientRoomError.admissionDenied
            }
            records[handles[index]] = command.descriptor
            candidateRooms[handles[index]] = candidate.room
        }
        // Admit candidate rooms against the final roster so they can create
        // authentic encrypted pair signals for signal-before-roster tests.
        let prepared = ServerRoomSessionPreparedRooms(
            creatorRecord: bootstrap.createRequest.descriptor,
            records: records,
            candidateRooms: candidateRooms,
            creatorHandle: handles[0]
        )
        let finalRoster = try prepared.roster(
            memberCount: memberCount,
            revision: UInt64(memberCount)
        )
        for index in 1..<memberCount {
            var room = candidateRooms[handles[index]]!
            _ = try room.consumeMemberAdmitted(
                memberHandle: handles[index],
                reconnectCapability: .random(),
                roster: finalRoster
            )
            candidateRooms[handles[index]] = room
        }
        return .init(
            creatorRecord: bootstrap.createRequest.descriptor,
            records: records,
            candidateRooms: candidateRooms,
            creatorHandle: handles[0]
        )
    }

    func session(
        bootstrap: ServerCoordinatedMeshRoomSessionBootstrap,
        transport: ServerRoomSessionTransportProbe,
        peerFactory: ServerRoomSessionPeerTransportFactory,
        pairSignalCallbackProbe:
            ServerRoomSessionPairSignalCallbackProbe? = nil
    ) -> ServerCoordinatedMeshRoomSession {
        ServerCoordinatedMeshRoomSession(
            bootstrap: bootstrap,
            controlPlane: .init(
                discover: { _ in try capabilities() },
                create: { _, _, _ in }
            ),
            transport: ServerCoordinatedMeshRoomTransportClient(
                events: { await transport.eventStreamForFixture() },
                connect: { _, _, authentication in
                    await transport.connectForFixture(authentication)
                },
                sendJoinKnock: { sequence, _ in
                    try await transport.joinForFixture(sequence)
                },
                admitCandidate: { handle, _ in
                    try await transport.admitForFixture(handle)
                },
                denyCandidate: { handle, reason in
                    try await transport.denyForFixture(handle, reason: reason)
                },
                sendPairSignal: { signal in
                    try await transport.pairSignalForFixture(signal)
                },
                removeMember: { _ in },
                leave: {},
                close: { await transport.closeForFixture() }
            ),
            mediaFactory: { _, send in
                if let pairSignalCallbackProbe {
                    await pairSignalCallbackProbe.install(send)
                }
                return mediaClient(factory: peerFactory, sendPairSignal: send)
            }
        )
    }

    func mediaClient(
        factory: ServerRoomSessionPeerTransportFactory,
        sendPairSignal: @escaping ServerCoordinatedMeshMediaRuntime.SendPairSignal
    ) -> ServerCoordinatedMeshMediaClient {
        let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
            localParticipantID: participants[0].descriptor.participantID,
            transportFactory: factory
        )
        let reconciler = ClipLiveShareServerMeshPeerReconciler(
            localParticipantID: participants[0].descriptor.participantID,
            peerLinkManager: manager
        )
        return .init(ServerCoordinatedMeshMediaRuntime(
            links: ServerCoordinatedMeshMediaLinkAdapter(
                manager: manager,
                reconciler: reconciler
            ),
            sendPairSignal: sendPairSignal
        ))
    }
}

private enum ServerRoomSessionPeerError: Error { case creationFailed }

private actor ServerRoomSessionPeerTransportFactory:
    ClipLiveShareNativeV3PeerLinkTransportFactory
{
    private var transports:
        [ClipLiveShareNativeV3ParticipantID: ServerRoomSessionPeerTransport] = [:]
    private var failed: Set<ClipLiveShareNativeV3ParticipantID> = []

    func makeTransport(
        configuration: ClipLiveShareNativeV3PeerLinkConfiguration
    ) throws -> any ClipLiveShareNativeV3PeerLinkTransport {
        guard !failed.contains(configuration.remoteParticipantID) else {
            throw ServerRoomSessionPeerError.creationFailed
        }
        let transport = ServerRoomSessionPeerTransport(configuration: configuration)
        transports[configuration.remoteParticipantID] = transport
        return transport
    }

    func failCreation(for participantID: ClipLiveShareNativeV3ParticipantID) {
        failed.insert(participantID)
    }

    func transport(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> ServerRoomSessionPeerTransport? {
        transports[participantID]
    }
}

private actor ServerRoomSessionPeerTransport:
    ClipLiveShareNativeV3PeerLinkTransport
{
    nonisolated let configuration: ClipLiveShareNativeV3PeerLinkConfiguration
    private var continuation:
        AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent>.Continuation?
    private var descriptions: [WebRTCSessionDescription] = []

    init(configuration: ClipLiveShareNativeV3PeerLinkConfiguration) {
        self.configuration = configuration
    }

    func events() -> AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent> {
        let pair = AsyncStream.makeStream(
            of: ClipLiveShareNativeV3PeerLinkTransportEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        continuation = pair.continuation
        return pair.stream
    }

    func start() {}
    func requestNegotiation() {}
    func applyRemoteDescription(_ value: WebRTCSessionDescription) {
        descriptions.append(value)
    }
    func addRemoteICECandidate(_: WebRTCICECandidate) {}
    func sendControlMessage(_: Data) {}
    func sendEphemeralControlMessage(_: Data) -> Bool { true }
    func remoteVideoStream(for _: ClipLiveShareStreamDescriptor)
        -> WebRTCRemoteVideoStream? { nil }
    func setOutboundMediaEnabled(_: Bool) {}
    func setRemoteParticipantAudioPlaybackEnabled(_: Bool) {}
    func setRemoteParticipantAudioVolume(_: Double) {}
    func restartICE() {}
    func statistics() -> ClipLiveShareNativeV3PeerLinkTransportStatistics {
        .init(capturedAt: Date(timeIntervalSince1970: 0))
    }
    func close() { continuation?.finish() }
    func emit(_ event: ClipLiveShareNativeV3PeerLinkTransportEvent) {
        continuation?.yield(event)
    }
    func remoteDescriptions() -> [WebRTCSessionDescription] { descriptions }
}

private extension ServerRoomSessionTransportProbe {
    func eventStreamForFixture()
        -> AsyncStream<ClipLiveShareServerRoomV4TransportEvent>
    {
        eventStream()
    }
    func connectForFixture(
        _ authentication: ClipLiveShareServerRoomV4SessionAuthentication
    ) {
        record(authentication: authentication)
    }
    func admitForFixture(
        _ handle: ClipLiveShareServerRoomV4CandidateHandle
    ) throws {
        try recordAdmissionSend(handle)
    }
    func joinForFixture(_ sequence: UInt64) throws {
        try recordJoinSend(sequence)
    }
    func pairSignalForFixture(
        _ signal: ClipLiveShareServerRoomV4PairSignalEnvelope
    ) async throws {
        try await recordPairSignalSend(signal)
    }
    func denyForFixture(
        _ handle: ClipLiveShareServerRoomV4CandidateHandle,
        reason: String
    ) throws {
        try recordDenial(handle, reason: reason)
    }
    func closeForFixture() { finish() }
}

private func serverRoomSessionEventually(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for server-room session state")
}
