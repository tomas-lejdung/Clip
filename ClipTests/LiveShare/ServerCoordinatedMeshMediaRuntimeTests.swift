import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import Testing

@testable import Clip

@Suite("Server-coordinated mesh media runtime")
struct ServerCoordinatedMeshMediaRuntimeTests {
    @Test("two, three and four members retain every unrelated pair")
    func completeMeshRosterEvolution() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()

        try await session.runtime.start(
            roster: fixture.roster(revision: 1, memberCount: 2)
        )
        let originalAB = try #require(
            await session.factory.transport(for: fixture.nodes[1].participantID)
        )
        #expect(try await session.runtime.snapshot().links.links.count == 1)

        try await session.runtime.applyRoster(
            fixture.roster(revision: 2, memberCount: 3)
        )
        #expect(try await session.runtime.snapshot().links.links.count == 2)
        #expect(
            await session.factory.transport(for: fixture.nodes[1].participantID)
                === originalAB
        )

        try await session.runtime.applyRoster(
            fixture.roster(revision: 3, memberCount: 4)
        )
        let expanded = try await session.runtime.snapshot()
        #expect(expanded.links.links.count == 3)
        #expect(expanded.reconciliation.failedPairs.isEmpty)
        #expect(
            await session.factory.transport(for: fixture.nodes[1].participantID)
                === originalAB
        )

        // Identical server snapshots are harmless. Only a conflicting or
        // lower revision is rejected.
        try await session.runtime.applyRoster(
            fixture.roster(revision: 3, memberCount: 4)
        )
        #expect(await session.factory.makeCount() == 3)
        await session.runtime.close()
    }

    @Test("one pair allocation failure cannot roll back other links")
    func pairFailureIsIsolated() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        try await session.runtime.start(
            roster: fixture.roster(revision: 1, memberCount: 2)
        )
        let originalAB = try #require(
            await session.factory.transport(for: fixture.nodes[1].participantID)
        )
        await session.factory.failCreation(
            for: fixture.nodes[2].participantID
        )

        try await session.runtime.applyRoster(
            fixture.roster(revision: 2, memberCount: 4)
        )
        let snapshot = try await session.runtime.snapshot()
        #expect(snapshot.reconciliation.failedPairs.count == 1)
        #expect(snapshot.links.links.count == 2)
        #expect(
            snapshot.links.links.map(\.remoteParticipantID).contains(
                fixture.nodes[3].participantID
            )
        )
        #expect(
            await session.factory.transport(for: fixture.nodes[1].participantID)
                === originalAB
        )
        await session.runtime.close()
    }

    @Test("manual recovery restarts only the selected pair")
    func manualPairRecoveryIsTargeted() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        try await session.runtime.start(
            roster: fixture.roster(revision: 1, memberCount: 3)
        )
        let peerB = try #require(await session.factory.transport(
            for: fixture.nodes[1].participantID
        ))
        let peerC = try #require(await session.factory.transport(
            for: fixture.nodes[2].participantID
        ))

        try await session.runtime.retryPairConnection(
            fixture.nodes[1].participantID
        )

        #expect(await peerB.restartCount() == 1)
        #expect(await peerC.restartCount() == 0)
        #expect(try await session.runtime.snapshot().links.links.count == 2)
        await session.runtime.close()
    }

    @Test("offerer codec change initiates exactly one canonical negotiation")
    func offererCodecChangeNegotiatesOnce() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let signalProbe = ServerMeshPairSignalProbe()
        let session = fixture.makeRuntime(
            sendPairSignal: { context, payload, remoteHandle in
                await signalProbe.record(
                    context: context,
                    payload: payload,
                    remoteHandle: remoteHandle
                )
            }
        )
        try await session.runtime.start(
            roster: fixture.roster(revision: 1, memberCount: 2)
        )
        let peer = fixture.nodes[1].participantID
        let transport = try #require(
            await session.factory.transport(for: peer)
        )

        try await session.runtime.updateVideoCodecPreference(
            .vp8,
            for: peer,
            rollbackTo: .av1
        )

        #expect(await transport.videoCodecUpdates() == [.vp8])
        #expect(await transport.negotiationRequestCount() == 1)
        #expect(await signalProbe.values().isEmpty)
        await session.runtime.close()
    }

    @Test("answerer codec change requests exactly one canonical offer")
    func answererCodecChangeRequestsCanonicalOfferOnce() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let signalProbe = ServerMeshPairSignalProbe()
        let localIndex = 1
        let session = fixture.makeRuntime(
            localIndex: localIndex,
            sendPairSignal: { context, payload, remoteHandle in
                await signalProbe.record(
                    context: context,
                    payload: payload,
                    remoteHandle: remoteHandle
                )
            }
        )
        let roster = try fixture.roster(
            revision: 1,
            memberCount: 2,
            localIndex: localIndex
        )
        try await session.runtime.start(roster: roster)
        let peer = fixture.nodes[0].participantID
        let pair = try #require(roster.pairsByParticipant[peer])
        let transport = try #require(
            await session.factory.transport(for: peer)
        )

        try await session.runtime.updateVideoCodecPreference(
            .vp8,
            for: peer,
            rollbackTo: .av1
        )

        #expect(await transport.videoCodecUpdates() == [.vp8])
        #expect(await transport.negotiationRequestCount() == 0)
        #expect(await signalProbe.values().count == 1)
        #expect(
            await signalProbe.values().first?.payload
                == .codecRenegotiationRequest(
                    epoch: pair.epoch,
                    codec: .vp8
                )
        )
        await session.runtime.close()
    }

    @Test("codec request applies the requested codec before canonical offer")
    func codecRequestPreparesCanonicalOfferer() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        let roster = try fixture.roster(revision: 1, memberCount: 2)
        try await session.runtime.start(roster: roster)
        let peer = fixture.nodes[1].participantID
        let pair = try #require(roster.pairsByParticipant[peer])
        let transport = try #require(
            await session.factory.transport(for: peer)
        )

        try await session.runtime.receiveAuthenticatedPairSignal(.init(
            pairID: pair.pairID,
            senderHandle: fixture.nodes[1].handle,
            sequence: 1,
            payload: .codecRenegotiationRequest(
                epoch: pair.epoch,
                codec: .h264
            )
        ))

        #expect(await transport.videoCodecUpdates() == [.h264])
        #expect(await transport.negotiationRequestCount() == 1)
        await session.runtime.close()
    }

    @Test("failed canonical codec offer restores its actual pair preference")
    func failedCanonicalCodecOfferRestoresActualPreference() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        let roster = try fixture.roster(revision: 1, memberCount: 2)
        try await session.runtime.start(roster: roster)
        let peer = fixture.nodes[1].participantID
        let pair = try #require(roster.pairsByParticipant[peer])
        let transport = try #require(
            await session.factory.transport(for: peer)
        )
        await transport.failNextNegotiationRequests(1)

        try await session.runtime.receiveAuthenticatedPairSignal(.init(
            pairID: pair.pairID,
            senderHandle: fixture.nodes[1].handle,
            sequence: 1,
            payload: .codecRenegotiationRequest(
                epoch: pair.epoch,
                codec: .h264
            )
        ))
        try await serverMeshEventually {
            await transport.restoredVideoCodecs() == [.av1]
        }

        #expect(await transport.videoCodecUpdates() == [.h264])
        #expect(await transport.currentVideoCodecPreference() == .av1)
        #expect(await transport.negotiationRequestCount() == 1)
        #expect(await transport.rollbackCount() == 2)
        await session.runtime.close()
    }

    @Test("failed codec request restores preference without another exchange")
    func failedCodecRequestRestoresWithoutNegotiationLatch() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let localIndex = 1
        let session = fixture.makeRuntime(
            localIndex: localIndex,
            sendPairSignal: { _, _, _ in
                throw ServerMeshRuntimeTestError.controlSendFailed
            }
        )
        try await session.runtime.start(
            roster: fixture.roster(
                revision: 1,
                memberCount: 2,
                localIndex: localIndex
            )
        )
        let peer = fixture.nodes[0].participantID
        let transport = try #require(
            await session.factory.transport(for: peer)
        )

        var failed = false
        do {
            try await session.runtime.updateVideoCodecPreference(
                .vp8,
                for: peer,
                rollbackTo: .av1
            )
        } catch {
            failed = true
        }

        #expect(failed)
        #expect(await transport.videoCodecUpdates() == [.vp8])
        #expect(await transport.restoredVideoCodecs() == [.av1])
        #expect(await transport.rollbackCount() == 1)
        #expect(await transport.negotiationRequestCount() == 0)
        await session.runtime.close()
    }

    @Test("Web codec rejection rolls back, disables fallback, and re-enables after a supported answer")
    func webCodecRejectionRecoversOnSupportedAnswer() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        let roster = try fixture.roster(
            revision: 1,
            memberCount: 2,
            webParticipantIndexes: [1]
        )
        try await session.runtime.start(roster: roster)
        let webID = fixture.nodes[1].participantID
        let pair = try #require(roster.pairsByParticipant[webID])
        let transport = try #require(
            await session.factory.transport(for: webID)
        )

        try await session.runtime.receiveAuthenticatedPairSignal(.init(
            pairID: pair.pairID,
            senderHandle: fixture.nodes[1].handle,
            sequence: 1,
            payload: .codecRenegotiationRejected(
                epoch: pair.epoch,
                codec: .av1
            )
        ))
        #expect(await transport.rollbackCount() == 1)
        #expect(await transport.outboundMediaEnabledValues() == [false])

        try await session.runtime.updateVideoCodecPreference(
            .vp8,
            for: webID,
            rollbackTo: .av1
        )
        try await session.runtime.receiveAuthenticatedPairSignal(.init(
            pairID: pair.pairID,
            senderHandle: fixture.nodes[1].handle,
            sequence: 2,
            payload: .answer(epoch: pair.epoch, sdp: "supported-vp8")
        ))

        #expect(await transport.videoCodecUpdates() == [.vp8])
        #expect(await transport.negotiationRequestCount() == 1)
        #expect(await transport.outboundMediaEnabledValues() == [false, true])
        await session.runtime.close()
    }

    @Test("an answerer-only failure requests one pair-local recovery offer")
    func answererOnlyFailureRequestsCanonicalOfferer() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let signalProbe = ServerMeshPairSignalProbe()
        let localIndex = 1
        let session = fixture.makeRuntime(
            localIndex: localIndex,
            sendPairSignal: { context, payload, remoteHandle in
                await signalProbe.record(
                    context: context,
                    payload: payload,
                    remoteHandle: remoteHandle
                )
            }
        )
        let roster = try fixture.roster(
            revision: 1,
            memberCount: 3,
            localIndex: localIndex
        )
        let failedParticipantID = fixture.nodes[0].participantID
        let unrelatedParticipantID = fixture.nodes[2].participantID
        let failedPair = try #require(
            roster.pairsByParticipant[failedParticipantID]
        )
        #expect(failedPair.context.initialOfferer == fixture.nodes[0].handle)
        try await session.runtime.start(roster: roster)
        let failedTransport = try #require(
            await session.factory.transport(for: failedParticipantID)
        )
        let unrelatedTransport = try #require(
            await session.factory.transport(for: unrelatedParticipantID)
        )

        // Several callbacks for one asymmetric failure still produce one
        // coalesced encrypted request while the canonical offerer remains
        // healthy and unaware of the answerer's local ICE state.
        await failedTransport.emit(.connectionStateChanged(.failed))
        await failedTransport.emit(.connectionStateChanged(.failed))
        await failedTransport.emit(.failed("answerer-only failure"))
        try await serverMeshEventually {
            await signalProbe.values().count == 1
        }
        let request = try #require(await signalProbe.values().first)
        #expect(request.context == failedPair.context)
        #expect(
            request.payload
                == .renegotiationRequest(epoch: failedPair.epoch)
        )
        #expect(request.remoteHandle == fixture.nodes[0].handle)
        #expect(await failedTransport.restartCount() == 1)
        #expect(await unrelatedTransport.restartCount() == 0)
        #expect(await session.factory.makeCount() == 2)

        // The canonical peer's resulting offer recovers this exact edge. Its
        // ready transition cancels later retry requests.
        try await session.runtime.receiveAuthenticatedPairSignal(.init(
            pairID: failedPair.pairID,
            senderHandle: fixture.nodes[0].handle,
            sequence: 1,
            payload: .offer(epoch: failedPair.epoch, sdp: "recovery-offer")
        ))
        await failedTransport.emit(.connectionStateChanged(.connected))
        await failedTransport.emit(.controlChannelStateChanged(.open))
        try await serverMeshEventually {
            try await session.runtime.snapshot().links.links.first {
                $0.remoteParticipantID == failedParticipantID
            }?.isReady == true
        }
        try await Task.sleep(for: .milliseconds(450))
        #expect(await signalProbe.values().count == 1)
        #expect(await failedTransport.remoteDescriptions().map(\.sdp)
            == ["recovery-offer"])
        #expect(await unrelatedTransport.restartCount() == 0)
        #expect(await session.factory.makeCount() == 2)

        await session.runtime.close()
    }

    @Test("pair signals wait for their exact roster and transport")
    func signalBeforeRosterIsDrainedInSequence() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        let rosterAB = try fixture.roster(revision: 1, memberCount: 2)
        let pairAB = try #require(
            rosterAB.pairsByParticipant[fixture.nodes[1].participantID]
        )
        let signalAB = ServerCoordinatedMeshAuthenticatedPairSignal(
            pairID: pairAB.pairID,
            senderHandle: fixture.nodes[1].handle,
            // Sequence 1 was sealed but its WebSocket write was lost. A
            // strictly increasing sequence must not wedge this pair forever.
            sequence: 2,
            payload: .offer(epoch: pairAB.epoch, sdp: "v=0\r\n")
        )

        // The encrypted signal can beat initial roster application.
        try await session.runtime.receiveAuthenticatedPairSignal(signalAB)
        try await session.runtime.start(roster: rosterAB)
        let transportAB = try #require(
            await session.factory.transport(for: fixture.nodes[1].participantID)
        )
        try await serverMeshEventually {
            await transportAB.remoteDescriptions().count == 1
        }

        // A newly admitted C can also signal before A receives roster N+1.
        let rosterABC = try fixture.roster(revision: 2, memberCount: 3)
        let pairAC = try #require(
            rosterABC.pairsByParticipant[fixture.nodes[2].participantID]
        )
        let signalAC = ServerCoordinatedMeshAuthenticatedPairSignal(
            pairID: pairAC.pairID,
            senderHandle: fixture.nodes[2].handle,
            sequence: 1,
            payload: .offer(epoch: pairAC.epoch, sdp: "v=0\r\no=c\r\n")
        )
        try await session.runtime.receiveAuthenticatedPairSignal(signalAC)
        #expect(await session.factory.transport(for: fixture.nodes[2].participantID) == nil)

        try await session.runtime.applyRoster(rosterABC)
        let transportAC = try #require(
            await session.factory.transport(for: fixture.nodes[2].participantID)
        )
        try await serverMeshEventually {
            await transportAC.remoteDescriptions().count == 1
        }
        #expect(await transportAB.remoteDescriptions().count == 1)

        await #expect(
            throws: ServerCoordinatedMeshMediaRuntimeError.stalePairSignal
        ) {
            try await session.runtime.receiveAuthenticatedPairSignal(signalAC)
        }
        await session.runtime.close()
    }

    @Test("a rejected SDP drops stale ICE and preserves the replacement generation")
    func rejectedSDPDropsStaleICEAndPreservesReplacement() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        let roster = try fixture.roster(revision: 1, memberCount: 3)
        let remoteID = fixture.nodes[1].participantID
        let unrelatedID = fixture.nodes[2].participantID
        let pair = try #require(roster.pairsByParticipant[remoteID])
        let unrelatedPair = try #require(
            roster.pairsByParticipant[unrelatedID]
        )
        await session.factory.failNextRemoteDescription(
            onNextTransportFor: remoteID
        )
        let rejected = ServerCoordinatedMeshAuthenticatedPairSignal(
            pairID: pair.pairID,
            senderHandle: fixture.nodes[1].handle,
            sequence: 1,
            payload: .offer(epoch: pair.epoch, sdp: "rejected")
        )
        let replacement = ServerCoordinatedMeshAuthenticatedPairSignal(
            pairID: pair.pairID,
            senderHandle: fixture.nodes[1].handle,
            sequence: 3,
            payload: .offer(epoch: pair.epoch, sdp: "replacement")
        )
        let staleCandidate = ServerCoordinatedMeshAuthenticatedPairSignal(
            pairID: pair.pairID,
            senderHandle: fixture.nodes[1].handle,
            sequence: 2,
            payload: .iceCandidate(
                epoch: pair.epoch,
                candidate: "candidate:stale",
                mediaID: "0",
                mediaLineIndex: 0
            )
        )
        let replacementCandidate = ServerCoordinatedMeshAuthenticatedPairSignal(
            pairID: pair.pairID,
            senderHandle: fixture.nodes[1].handle,
            sequence: 4,
            payload: .iceCandidate(
                epoch: pair.epoch,
                candidate: "candidate:fresh",
                mediaID: "0",
                mediaLineIndex: 0
            )
        )
        let unrelated = ServerCoordinatedMeshAuthenticatedPairSignal(
            pairID: unrelatedPair.pairID,
            senderHandle: fixture.nodes[2].handle,
            sequence: 1,
            payload: .offer(epoch: unrelatedPair.epoch, sdp: "unrelated")
        )

        try await session.runtime.receiveAuthenticatedPairSignal(rejected)
        try await session.runtime.receiveAuthenticatedPairSignal(staleCandidate)
        try await session.runtime.receiveAuthenticatedPairSignal(replacement)
        try await session.runtime.receiveAuthenticatedPairSignal(
            replacementCandidate
        )
        try await session.runtime.receiveAuthenticatedPairSignal(unrelated)
        try await session.runtime.start(roster: roster)

        try await serverMeshEventually {
            guard await session.factory.makeCount() == 3,
                  let transport = await session.factory.transport(for: remoteID),
                  let unrelatedTransport = await session.factory.transport(
                    for: unrelatedID
                  )
            else { return false }
            let replacementDescriptions = await transport
                .remoteDescriptions().map(\.sdp)
            let replacementCandidates = await transport.remoteCandidates()
                .map(\.candidate)
            let unrelatedDescriptions = await unrelatedTransport
                .remoteDescriptions().map(\.sdp)
            return replacementDescriptions == ["replacement"]
                && replacementCandidates == ["candidate:fresh"]
                && unrelatedDescriptions == ["unrelated"]
        }
        #expect(await session.factory.makeCount() == 3)

        await session.runtime.close()
    }

    @Test("a late ready pair receives the current source snapshot")
    func latePairReceivesCurrentSources() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        try await session.runtime.start(
            roster: fixture.roster(revision: 1, memberCount: 2)
        )
        try await session.runtime.publishLocalSources([
            fixture.publishedSource(owner: fixture.nodes[0].participantID)
        ])

        try await session.runtime.applyRoster(
            fixture.roster(revision: 2, memberCount: 3)
        )
        let transportAC = try #require(
            await session.factory.transport(for: fixture.nodes[2].participantID)
        )
        await transportAC.emit(.connectionStateChanged(.connected))
        await transportAC.emit(.controlChannelStateChanged(.open))

        try await serverMeshEventually {
            await transportAC.controlMessages().count == 1
        }
        let data = try #require(await transportAC.controlMessages().first)
        guard case let .sourceSnapshot(snapshot) =
            try ClipLiveShareMeshMediaControlCodec.decode(data) else {
            Issue.record("Expected a source snapshot")
            await session.runtime.close()
            return
        }
        #expect(snapshot.ownerParticipantID == fixture.nodes[0].participantID)
        #expect(snapshot.sources.count == 1)
        await session.runtime.close()
    }

    @Test("source synchronization retries and coalesces to the latest revision")
    func sourceSynchronizationRetriesLatestRevision() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        let events = await session.runtime.events()
        let eventProbe = ServerMeshRuntimeEventProbe()
        let eventTask = Task {
            for await event in events { await eventProbe.record(event) }
        }
        try await session.runtime.start(
            roster: fixture.roster(revision: 1, memberCount: 2)
        )
        let remoteID = fixture.nodes[1].participantID
        let transport = try #require(
            await session.factory.transport(for: remoteID)
        )
        await transport.emit(.connectionStateChanged(.connected))
        await transport.emit(.controlChannelStateChanged(.open))
        await transport.failNextControlMessages(2)

        try await session.runtime.publishLocalSources([
            fixture.publishedSource(owner: fixture.nodes[0].participantID)
        ])
        let latest = try fixture.publishedSource(
            owner: fixture.nodes[0].participantID
        )
        try await session.runtime.publishLocalSources([latest])

        try await serverMeshEventually {
            let messageCount = await transport.controlMessages().count
            let didRecover = await eventProbe.didRecover(remoteID)
            return messageCount == 1 && didRecover
        }
        let data = try #require(await transport.controlMessages().first)
        guard case let .sourceSnapshot(snapshot) =
            try ClipLiveShareMeshMediaControlCodec.decode(data) else {
            Issue.record("Expected the coalesced source snapshot")
            await session.runtime.close()
            eventTask.cancel()
            return
        }
        #expect(snapshot.sourceRevision.rawValue == 2)
        #expect(snapshot.sources == [latest])
        let didFail = await eventProbe.didFail(remoteID)
        #expect(didFail)

        await session.runtime.close()
        eventTask.cancel()
    }

    @Test("a ready pair recovers even when there are no local sources")
    func noSourcePairRecovery() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        let events = await session.runtime.events()
        let eventProbe = ServerMeshRuntimeEventProbe()
        let eventTask = Task {
            for await event in events { await eventProbe.record(event) }
        }
        try await session.runtime.start(
            roster: fixture.roster(revision: 1, memberCount: 2)
        )
        let remoteID = fixture.nodes[1].participantID
        let transport = try #require(
            await session.factory.transport(for: remoteID)
        )

        await transport.emit(.connectionStateChanged(.connected))
        await transport.emit(.controlChannelStateChanged(.open))

        try await serverMeshEventually {
            await eventProbe.didRecover(remoteID)
        }
        #expect(await transport.controlMessages().isEmpty)

        await session.runtime.close()
        eventTask.cancel()
    }

    @Test("an identical source revision replay is idempotent")
    func identicalSourceRevisionReplayIsIdempotent() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        let events = await session.runtime.events()
        let eventProbe = ServerMeshRuntimeEventProbe()
        let eventTask = Task {
            for await event in events { await eventProbe.record(event) }
        }
        try await session.runtime.start(
            roster: fixture.roster(revision: 1, memberCount: 2)
        )
        let remoteID = fixture.nodes[1].participantID
        let transport = try #require(
            await session.factory.transport(for: remoteID)
        )
        let remoteSource = try fixture.publishedSource(owner: remoteID)
        let snapshot = try ClipLiveShareNativeV3SourceSnapshot(
            sessionID: fixture.sessionID,
            membershipRevision: .init(rawValue: 1),
            ownerParticipantID: remoteID,
            sourceRevision: .init(rawValue: 1),
            sources: [remoteSource]
        )
        let encoded = try ClipLiveShareMeshMediaControlCodec.encode(
            .sourceSnapshot(snapshot)
        )

        await transport.emit(.controlMessageReceived(encoded))
        await transport.emit(.controlMessageReceived(encoded))
        try await serverMeshEventually {
            try await session.runtime.snapshot()
                .sourceSnapshots[remoteID] == snapshot
        }
        let didFail = await eventProbe.didFail(remoteID)
        #expect(!didFail)

        await session.runtime.close()
        eventTask.cancel()
    }

    @Test("a new member incarnation accepts source revision one")
    func replacementIncarnationResetsRemoteSourceRevision() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let session = fixture.makeRuntime()
        try await session.runtime.start(
            roster: fixture.roster(revision: 1, memberCount: 2)
        )
        let remoteID = fixture.nodes[1].participantID
        let oldTransport = try #require(
            await session.factory.transport(for: remoteID)
        )
        let oldSource = try fixture.publishedSource(owner: remoteID)
        let oldSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
            sessionID: fixture.sessionID,
            membershipRevision: .init(rawValue: 1),
            ownerParticipantID: remoteID,
            sourceRevision: .init(rawValue: 7),
            sources: [oldSource]
        )
        await oldTransport.emit(.controlMessageReceived(
            try ClipLiveShareMeshMediaControlCodec.encode(
                .sourceSnapshot(oldSnapshot)
            )
        ))
        try await serverMeshEventually {
            try await session.runtime.snapshot().sourceSnapshots[remoteID]
                == oldSnapshot
        }

        try await session.runtime.applyRoster(
            fixture.rosterReplacingFirstRemote(
                revision: 2,
                replacementHandleByte: 0x77
            )
        )
        #expect(
            try await session.runtime.snapshot().sourceSnapshots[remoteID] == nil
        )
        let replacementTransport = try #require(
            await session.factory.transport(for: remoteID)
        )
        #expect(replacementTransport !== oldTransport)

        let replacementSource = try fixture.publishedSource(owner: remoteID)
        let replacementSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
            sessionID: fixture.sessionID,
            membershipRevision: .init(rawValue: 1),
            ownerParticipantID: remoteID,
            sourceRevision: .init(rawValue: 1),
            sources: [replacementSource]
        )
        await replacementTransport.emit(.controlMessageReceived(
            try ClipLiveShareMeshMediaControlCodec.encode(
                .sourceSnapshot(replacementSnapshot)
            )
        ))
        try await serverMeshEventually {
            try await session.runtime.snapshot().sourceSnapshots[remoteID]
                == replacementSnapshot
        }

        await session.runtime.close()
    }

    @Test("web-v1 accepts only an empty manifest and cannot surface media or controls")
    func webReceiveOnlyProfileIsEnforcedWithoutPairRecovery() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let timestamp = try ClipLiveShareNativeTimestamp(
            millisecondsSince1970: 1_800_000_000_000
        )
        let session = fixture.makeRuntime(now: { timestamp })
        let events = await session.runtime.events()
        let eventProbe = ServerMeshRuntimeEventProbe()
        let eventTask = Task {
            for await event in events { await eventProbe.record(event) }
        }
        try await session.runtime.start(roster: fixture.roster(
            revision: 1,
            memberCount: 3,
            webParticipantIndexes: [1]
        ))
        let webID = fixture.nodes[1].participantID
        let nativeID = fixture.nodes[2].participantID
        let webTransport = try #require(
            await session.factory.transport(for: webID)
        )
        let nativeTransport = try #require(
            await session.factory.transport(for: nativeID)
        )
        #expect(
            webTransport.configuration.videoCodecNegotiationPolicy == .exact
        )
        #expect(
            nativeTransport.configuration.videoCodecNegotiationPolicy
                == .nativeCompatible
        )

        let emptyWebSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
            sessionID: fixture.sessionID,
            membershipRevision: .init(rawValue: 1),
            ownerParticipantID: webID,
            sourceRevision: .init(rawValue: 1),
            sources: []
        )
        await webTransport.emit(.controlMessageReceived(
            try ClipLiveShareMeshMediaControlCodec.encode(
                .sourceSnapshot(emptyWebSnapshot)
            )
        ))
        try await serverMeshEventually {
            try await session.runtime.snapshot().sourceSnapshots[webID]
                == emptyWebSnapshot
        }

        let forbiddenWebSource = try fixture.publishedSource(owner: webID)
        let forbiddenWebSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
            sessionID: fixture.sessionID,
            membershipRevision: .init(rawValue: 1),
            ownerParticipantID: webID,
            sourceRevision: .init(rawValue: 2),
            sources: [forbiddenWebSource]
        )
        let forbiddenCursor = try ClipLiveShareNativeV3SourceCursor(
            sessionID: fixture.sessionID,
            participantID: webID,
            sourceKey: forbiddenWebSource.key,
            streamID: forbiddenWebSource.descriptor.stream.id,
            sequence: 1,
            position: .init(x: 0.25, y: 0.75)
        )
        let forbiddenCollaboration =
            ClipLiveShareNativeV3CollaborationEvent.pointer(.init(
                context: try .init(
                    sessionID: fixture.sessionID,
                    participantID: webID,
                    sourceKey: forbiddenWebSource.key,
                    sequence: 1,
                    sentAt: timestamp
                ),
                position: try .init(x: 0.2, y: 0.4)
            ))
        let forbiddenFriendship = try fixture.friendRequest(
            from: 1,
            to: 0,
            issuedAt: timestamp
        )
        for message in [
            ClipLiveShareMeshMediaControlMessage.sourceSnapshot(
                forbiddenWebSnapshot
            ),
            .sourceCursor(forbiddenCursor),
            .collaboration(forbiddenCollaboration),
            .friendship(forbiddenFriendship),
        ] {
            await webTransport.emit(.controlMessageReceived(
                try ClipLiveShareMeshMediaControlCodec.encode(message)
            ))
        }
        await webTransport.emit(.remoteVideoTrackAdded(
            forbiddenWebSource.descriptor.stream.mediaTrackID
        ))
        await webTransport.emit(.remoteParticipantAudioAvailable(
            trackID: "forbidden-web-audio"
        ))

        // A malformed Web control frame is ignored on only that pair. The
        // subsequent valid empty manifest proves its control channel remains
        // usable without SDP/ICE recovery or disturbance to the unrelated
        // Native edge.
        await webTransport.emit(.controlMessageReceived(Data([0x00])))
        let latestEmptyWebSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
            sessionID: fixture.sessionID,
            membershipRevision: .init(rawValue: 1),
            ownerParticipantID: webID,
            sourceRevision: .init(rawValue: 3),
            sources: []
        )
        await webTransport.emit(.controlMessageReceived(
            try ClipLiveShareMeshMediaControlCodec.encode(
                .sourceSnapshot(latestEmptyWebSnapshot)
            )
        ))

        let nativeSource = try fixture.publishedSource(owner: nativeID)
        let nativeSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
            sessionID: fixture.sessionID,
            membershipRevision: .init(rawValue: 1),
            ownerParticipantID: nativeID,
            sourceRevision: .init(rawValue: 1),
            sources: [nativeSource]
        )
        await nativeTransport.emit(.controlMessageReceived(
            try ClipLiveShareMeshMediaControlCodec.encode(
                .sourceSnapshot(nativeSnapshot)
            )
        ))
        await nativeTransport.emit(.remoteVideoTrackAdded(
            nativeSource.descriptor.stream.mediaTrackID
        ))
        await nativeTransport.emit(.remoteParticipantAudioAvailable(
            trackID: "native-audio"
        ))

        try await serverMeshEventually {
            let snapshot = try await session.runtime.snapshot()
            return snapshot.sourceSnapshots[webID] == latestEmptyWebSnapshot
                && snapshot.sourceSnapshots[nativeID] == nativeSnapshot
                && snapshot.remoteVideoTrackIDs[nativeID]
                    == [nativeSource.descriptor.stream.mediaTrackID]
                && snapshot.audioTrackIDs[nativeID] == "native-audio"
        }
        let snapshot = try await session.runtime.snapshot()
        #expect(snapshot.sourceSnapshots[webID] == latestEmptyWebSnapshot)
        #expect(snapshot.remoteVideoTrackIDs[webID]?.isEmpty != false)
        #expect(snapshot.audioTrackIDs[webID] == nil)
        #expect(snapshot.sourceCursors[forbiddenWebSource.key] == nil)
        #expect(snapshot.collaboration[forbiddenWebSource.key] == nil)
        let receivedForbiddenFriendship = await eventProbe.receivedFriendship(
            forbiddenFriendship,
            from: webID
        )
        #expect(!receivedForbiddenFriendship)
        let didFailWebPair = await eventProbe.didFail(webID)
        #expect(!didFailWebPair)

        #expect(try await session.runtime.remoteVideoStream(
            for: forbiddenWebSource.descriptor.stream,
            from: webID
        ) == nil)
        #expect(await webTransport.remoteVideoStreamRequestCount() == 0)
        try await session.runtime.setRemoteParticipantAudioPlaybackEnabled(
            true,
            for: webID
        )
        #expect(await webTransport.audioPlaybackPreferences().last == false)

        let outboundFriendship = try fixture.friendRequest(
            from: 0,
            to: 1,
            issuedAt: timestamp
        )
        await #expect(
            throws: ServerCoordinatedMeshMediaRuntimeError
                .unsupportedParticipantCapability
        ) {
            try await session.runtime.sendFriendshipMessage(
                outboundFriendship,
                to: webID
            )
        }
        try await Task.sleep(for: .milliseconds(450))
        #expect(await webTransport.restartCount() == 0)
        #expect(await nativeTransport.restartCount() == 0)

        await session.runtime.close()
        eventTask.cancel()
    }

    @Test("collaboration bypasses web-v1 while source cursor metadata remains available")
    func outboundCollaborationSkipsWebParticipant() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let timestamp = try ClipLiveShareNativeTimestamp(
            millisecondsSince1970: 1_800_000_000_000
        )
        let session = fixture.makeRuntime(now: { timestamp })
        try await session.runtime.start(roster: fixture.roster(
            revision: 1,
            memberCount: 3,
            webParticipantIndexes: [1]
        ))
        let webTransport = try #require(await session.factory.transport(
            for: fixture.nodes[1].participantID
        ))
        let nativeTransport = try #require(await session.factory.transport(
            for: fixture.nodes[2].participantID
        ))
        for transport in [webTransport, nativeTransport] {
            await transport.emit(.connectionStateChanged(.connected))
            await transport.emit(.controlChannelStateChanged(.open))
        }
        let source = try fixture.publishedSource(
            owner: fixture.nodes[0].participantID
        )
        try await session.runtime.publishLocalSources([source])
        try await serverMeshEventually {
            let webCount = await webTransport.controlMessages().count
            let nativeCount = await nativeTransport.controlMessages().count
            return webCount == 1 && nativeCount == 1
        }

        let cursor = try ClipLiveShareNativeV3SourceCursor(
            sessionID: fixture.sessionID,
            participantID: fixture.nodes[0].participantID,
            sourceKey: source.key,
            streamID: source.descriptor.stream.id,
            sequence: 1,
            position: .init(x: 0.4, y: 0.6)
        )
        try await session.runtime.broadcastSourceCursor(cursor)
        try await serverMeshEventually {
            let webCount = await webTransport.ephemeralControlMessages().count
            let nativeCount = await nativeTransport
                .ephemeralControlMessages().count
            return webCount == 1 && nativeCount == 1
        }

        let context = try ClipLiveShareNativeV3CollaborationContext(
            sessionID: fixture.sessionID,
            participantID: fixture.nodes[0].participantID,
            sourceKey: source.key,
            sequence: 1,
            sentAt: timestamp
        )
        try await session.runtime.broadcastCollaboration(.pointer(.init(
            context: context,
            position: .init(x: 0.1, y: 0.2)
        )))
        try await session.runtime.broadcastCollaboration(.ping(try .init(
            context: context,
            position: .init(x: 0.25, y: 0.75),
            color: .init(red: 250, green: 80, blue: 40),
            expiresAt: timestamp.adding(milliseconds: 1_000)
        )))
        try await serverMeshEventually {
            let ephemeralCount = await nativeTransport
                .ephemeralControlMessages().count
            let reliableCount = await nativeTransport.controlMessages().count
            return ephemeralCount == 2 && reliableCount == 2
        }
        #expect(await webTransport.ephemeralControlMessages().count == 1)
        #expect(await webTransport.controlMessages().count == 1)

        await session.runtime.close()
    }

    @Test("pointers are ephemeral while durable collaboration stays reliable")
    func collaborationUsesTheAppropriateTransportAndExpires() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let now = try ClipLiveShareNativeTimestamp(
            millisecondsSince1970: 1_000
        )
        let session = fixture.makeRuntime(now: { now })
        try await session.runtime.start(
            roster: fixture.roster(revision: 1, memberCount: 2)
        )
        let remoteID = fixture.nodes[1].participantID
        let transport = try #require(
            await session.factory.transport(for: remoteID)
        )
        await transport.emit(.connectionStateChanged(.connected))
        await transport.emit(.controlChannelStateChanged(.open))
        let source = try fixture.publishedSource(
            owner: fixture.nodes[0].participantID
        )
        try await session.runtime.publishLocalSources([source])
        try await serverMeshEventually {
            let isReady = try await session.runtime.snapshot().links.links
                .first?.isReady == true
            let messageCount = await transport.controlMessages().count
            return isReady && messageCount == 1
        }
        let context = try ClipLiveShareNativeV3CollaborationContext(
            sessionID: fixture.sessionID,
            participantID: fixture.nodes[0].participantID,
            sourceKey: source.key,
            sequence: 1,
            sentAt: now
        )
        let pointer = ClipLiveShareNativeV3CollaborationEvent.pointer(
            .init(
                context: context,
                position: try .init(x: 0.1, y: 0.2)
            )
        )
        try await session.runtime.broadcastCollaboration(pointer)
        try await serverMeshEventually {
            await transport.ephemeralControlMessages().count == 1
        }
        #expect(await transport.controlMessages().count == 1)
        guard case .collaboration(let decodedPointer) =
            try ClipLiveShareMeshMediaControlCodec.decode(
                try #require(await transport.ephemeralControlMessages().first)
            ) else {
            Issue.record("Expected ephemeral pointer collaboration control")
            await session.runtime.close()
            return
        }
        #expect(decodedPointer == pointer)

        // Pointer and durable collaboration use independent sequence lanes.
        let event = ClipLiveShareNativeV3CollaborationEvent.ping(
            try .init(
                context: context,
                position: .init(x: 0.25, y: 0.75),
                color: .init(red: 250, green: 80, blue: 40),
                expiresAt: now.adding(milliseconds: 1_000)
            )
        )

        try await session.runtime.broadcastCollaboration(event)
        // Reliable control delivery runs on the pair actor, so observe its
        // completion instead of assuming broadcast and transport storage are
        // the same synchronous operation.
        try await serverMeshEventually {
            await transport.controlMessages().count == 2
        }
        let controls = await transport.controlMessages()
        #expect(controls.count == 2) // source snapshot + collaboration
        guard case .collaboration(let decodedEvent) =
            try ClipLiveShareMeshMediaControlCodec.decode(
                try #require(controls.last)
            ) else {
            Issue.record("Expected reliable collaboration control")
            await session.runtime.close()
            return
        }
        #expect(decodedEvent == event)
        #expect(
            try await session.runtime.snapshot()
                .collaboration[source.key]?.pings.count == 1
        )
        #expect(
            try await session.runtime.snapshot()
                .collaboration[source.key]?.pointers.count == 1
        )

        let afterExpiry = try now.adding(milliseconds: 1_001)
        #expect(
            await session.runtime.pruneExpiredCollaboration(at: afterExpiry)
        )
        #expect(
            try await session.runtime.snapshot()
                .collaboration[source.key]?.pings.isEmpty == true
        )
        await session.runtime.close()
    }

    @Test("friendship messages use the authenticated reliable pair callback")
    func friendshipMessagesUseReliablePair() async throws {
        let fixture = try ServerMeshRuntimeFixture()
        let timestamp = try ClipLiveShareNativeTimestamp(
            millisecondsSince1970: 1_800_000_000_000
        )
        let session = fixture.makeRuntime(now: { timestamp })
        let events = await session.runtime.events()
        let eventProbe = ServerMeshRuntimeEventProbe()
        let eventTask = Task {
            for await event in events { await eventProbe.record(event) }
        }
        try await session.runtime.start(
            roster: fixture.roster(revision: 1, memberCount: 2)
        )
        let remoteID = fixture.nodes[1].participantID
        let transport = try #require(
            await session.factory.transport(for: remoteID)
        )
        await transport.emit(.connectionStateChanged(.connected))
        await transport.emit(.controlChannelStateChanged(.open))

        let remoteRequest = try fixture.friendRequest(
            from: 1,
            to: 0,
            issuedAt: timestamp
        )
        await transport.emit(.controlMessageReceived(
            try ClipLiveShareMeshMediaControlCodec.encode(
                .friendship(remoteRequest)
            )
        ))
        try await serverMeshEventually {
            await eventProbe.receivedFriendship(remoteRequest, from: remoteID)
        }

        let localRequest = try fixture.friendRequest(
            from: 0,
            to: 1,
            issuedAt: timestamp
        )
        try await session.runtime.sendFriendshipMessage(
            localRequest,
            to: remoteID
        )
        let data = try #require(await transport.controlMessages().last)
        guard case let .friendship(decoded) =
            try ClipLiveShareMeshMediaControlCodec.decode(data) else {
            Issue.record("Expected reliable friendship control")
            await session.runtime.close()
            eventTask.cancel()
            return
        }
        #expect(decoded == localRequest)
        #expect(await transport.ephemeralControlMessages().isEmpty)

        await session.runtime.close()
        eventTask.cancel()
    }
}

private struct ServerMeshRuntimeFixture {
    struct Node: Sendable {
        let handle: ClipLiveShareServerRoomV4MemberHandle
        let participantID: ClipLiveShareNativeV3ParticipantID
        let descriptor: ClipLiveShareServerRoomV4MemberDescriptor
    }

    let roomID: ClipLiveShareServerRoomV4RoomID
    let sessionID: ClipLiveShareSessionID
    let nodes: [Node]

    init() throws {
        roomID = try .init(bytes: Data(repeating: 0x91, count: 32))
        sessionID = try .init(rawValue: "server-mesh-media-runtime")
        nodes = try (1...4).map { index in
            let byte = UInt8(index)
            let signer = try ClipLiveShareSoftwareIdentitySigner(
                rawRepresentation: Data(repeating: byte, count: 32)
            )
            let agreement = ClipLiveShareServerRoomV4KeyAgreementIdentity()
            let participantID = try ClipLiveShareNativeV3ParticipantID(
                bytes: Data(repeating: byte, count: 16)
            )
            return try Node(
                handle: .init(bytes: Data(repeating: byte + 32, count: 16)),
                participantID: participantID,
                descriptor: .init(
                    participantID: participantID,
                    identity: signer.publicKey,
                    pairSignalingPublicKey: agreement.publicKey,
                    displayName: "Member \(index)",
                    deviceName: "Fixture"
                )
            )
        }
    }

    func roster(
        revision: UInt64,
        memberCount: Int,
        localIndex: Int = 0,
        webParticipantIndexes: Set<Int> = []
    ) throws -> ServerCoordinatedMeshVerifiedRoster {
        let included = Array(nodes.prefix(memberCount))
        let local = included[localIndex]
        let members = try included.enumerated().map { index, node in
            let descriptor: ClipLiveShareServerRoomV4MemberDescriptor
            if webParticipantIndexes.contains(index) {
                descriptor = try webDescriptor(for: node)
            } else {
                descriptor = node.descriptor
            }
            return ServerCoordinatedMeshVerifiedMember(
                handle: node.handle,
                descriptor: descriptor
            )
        }
        let pairs = try included.filter {
            $0.participantID != local.participantID
        }.map { remote in
            ServerCoordinatedMeshVerifiedPair(
                context: try .init(
                    roomID: roomID,
                    sessionID: sessionID,
                    firstHandle: local.handle,
                    firstParticipantID: local.participantID,
                    secondHandle: remote.handle,
                    secondParticipantID: remote.participantID
                ),
                epoch: try .init(rawValue: 1),
                remoteParticipantID: remote.participantID
            )
        }
        return try .init(
            roomID: roomID,
            sessionID: sessionID,
            revision: .init(rawValue: revision),
            localHandle: local.handle,
            localParticipantID: local.participantID,
            members: members,
            pairs: pairs
        )
    }

    private func webDescriptor(
        for node: Node
    ) throws -> ClipLiveShareServerRoomV4MemberDescriptor {
        try .init(
            participantID: node.descriptor.participantID,
            identity: node.descriptor.identity,
            pairSignalingPublicKey:
                node.descriptor.pairSignalingPublicKey,
            displayName: node.descriptor.displayName,
            deviceName: node.descriptor.deviceName,
            clientKind: .webViewer,
            capabilityProfile: .webViewerV1
        )
    }

    func rosterReplacingFirstRemote(
        revision: UInt64,
        replacementHandleByte: UInt8
    ) throws -> ServerCoordinatedMeshVerifiedRoster {
        let local = nodes[0]
        let originalRemote = nodes[1]
        let replacement = Node(
            handle: try .init(bytes: Data(
                repeating: replacementHandleByte,
                count: 16
            )),
            participantID: originalRemote.participantID,
            descriptor: originalRemote.descriptor
        )
        let pair = ServerCoordinatedMeshVerifiedPair(
            context: try .init(
                roomID: roomID,
                sessionID: sessionID,
                firstHandle: local.handle,
                firstParticipantID: local.participantID,
                secondHandle: replacement.handle,
                secondParticipantID: replacement.participantID
            ),
            epoch: try .init(rawValue: 1),
            remoteParticipantID: replacement.participantID
        )
        return try .init(
            roomID: roomID,
            sessionID: sessionID,
            revision: .init(rawValue: revision),
            localHandle: local.handle,
            localParticipantID: local.participantID,
            members: [
                .init(
                    handle: local.handle,
                    descriptor: local.descriptor
                ),
                .init(
                    handle: replacement.handle,
                    descriptor: replacement.descriptor
                ),
            ],
            pairs: [pair]
        )
    }

    func makeRuntime(
        localIndex: Int = 0,
        sendPairSignal: @escaping ServerCoordinatedMeshMediaRuntime.SendPairSignal = {
            _, _, _ in
        },
        now: @escaping @Sendable () -> ClipLiveShareNativeTimestamp = {
            try! ClipLiveShareNativeTimestamp(date: Date())
        }
    ) -> (
        runtime: ServerCoordinatedMeshMediaRuntime,
        factory: ServerMeshRuntimeTransportFactory
    ) {
        let factory = ServerMeshRuntimeTransportFactory()
        let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
            localParticipantID: nodes[localIndex].participantID,
            transportFactory: factory
        )
        let reconciler = ClipLiveShareServerMeshPeerReconciler(
            localParticipantID: nodes[localIndex].participantID,
            peerLinkManager: manager
        )
        let adapter = ServerCoordinatedMeshMediaLinkAdapter(
            manager: manager,
            reconciler: reconciler
        )
        return (
            ServerCoordinatedMeshMediaRuntime(
                links: adapter,
                sendPairSignal: sendPairSignal,
                now: now
            ),
            factory
        )
    }

    func publishedSource(
        owner: ClipLiveShareNativeV3ParticipantID
    ) throws -> ClipLiveShareNativeV3PublishedSource {
        let instanceID = ClipLiveShareSourceInstanceID.random()
        return try .init(
            key: .init(
                ownerParticipantID: owner,
                sourceInstanceID: instanceID
            ),
            descriptor: .init(
                sourceInstanceID: instanceID,
                stream: .init(
                    id: .init(rawValue: "late-source"),
                    mediaTrackID: .init(rawValue: "late-track"),
                    active: true,
                    focused: true,
                    appName: "Fixture",
                    windowName: "Late Window",
                    width: 640,
                    height: 360,
                    order: 0,
                    sourcePointWidth: 640,
                    sourcePointHeight: 360
                )
            )
        )
    }

    func friendRequest(
        from senderIndex: Int,
        to recipientIndex: Int,
        issuedAt: ClipLiveShareNativeTimestamp
    ) throws -> ClipLiveShareServerRoomV4SignedFriendMessage {
        let sender = nodes[senderIndex]
        let recipient = nodes[recipientIndex]
        let signer = try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(
                repeating: UInt8(senderIndex + 1),
                count: 32
            )
        )
        let profile = try ClipLiveShareServerRoomV4FriendProfile(
            identity: signer.publicKey,
            displayName: sender.descriptor.displayName,
            deviceName: sender.descriptor.deviceName,
            locator: .random()
        )
        let request = try ClipLiveShareServerRoomV4FriendRequest(
            roomID: roomID,
            sessionID: sessionID,
            requesterParticipantID: sender.participantID,
            accepterParticipantID: recipient.participantID,
            requester: profile,
            expectedAccepterFingerprint:
                recipient.descriptor.identity.fingerprint,
            issuedAt: issuedAt,
            expiresAt: issuedAt.adding(milliseconds: 60_000)
        )
        return try .init(signing: .request(request), with: signer)
    }
}

private enum ServerMeshRuntimeTestError: Error {
    case creationFailed
    case controlSendFailed
    case remoteDescriptionFailed
}

private actor ServerMeshPairSignalProbe {
    struct Value: Equatable, Sendable {
        let context: ClipLiveShareServerRoomV4PairContext
        let payload: ClipLiveShareServerRoomV4PairSignalPayload
        let remoteHandle: ClipLiveShareServerRoomV4MemberHandle
    }

    private var recorded: [Value] = []

    func record(
        context: ClipLiveShareServerRoomV4PairContext,
        payload: ClipLiveShareServerRoomV4PairSignalPayload,
        remoteHandle: ClipLiveShareServerRoomV4MemberHandle
    ) {
        recorded.append(.init(
            context: context,
            payload: payload,
            remoteHandle: remoteHandle
        ))
    }

    func values() -> [Value] { recorded }
}

private actor ServerMeshRuntimeEventProbe {
    private var values: [ServerCoordinatedMeshMediaRuntimeEvent] = []

    func record(_ event: ServerCoordinatedMeshMediaRuntimeEvent) {
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

    func didRecover(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) -> Bool {
        values.contains {
            if case let .pairRecovered(candidate) = $0 {
                candidate == participantID
            } else {
                false
            }
        }
    }

    func receivedFriendship(
        _ message: ClipLiveShareServerRoomV4SignedFriendMessage,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) -> Bool {
        values.contains {
            if case let .friendshipMessageReceived(candidate, sender) = $0 {
                candidate == message && sender == participantID
            } else {
                false
            }
        }
    }
}

private actor ServerMeshRuntimeTransportFactory:
    ClipLiveShareNativeV3PeerLinkTransportFactory
{
    private var transportsByParticipant:
        [ClipLiveShareNativeV3ParticipantID: ServerMeshRuntimeTransport] = [:]
    private var failedParticipants:
        Set<ClipLiveShareNativeV3ParticipantID> = []
    private var remoteDescriptionFailuresOnNextTransport:
        [ClipLiveShareNativeV3ParticipantID: Int] = [:]
    private var createdCount = 0

    func makeTransport(
        configuration: ClipLiveShareNativeV3PeerLinkConfiguration
    ) throws -> any ClipLiveShareNativeV3PeerLinkTransport {
        guard !failedParticipants.contains(configuration.remoteParticipantID)
        else { throw ServerMeshRuntimeTestError.creationFailed }
        let remoteDescriptionFailureCount =
            remoteDescriptionFailuresOnNextTransport.removeValue(
                forKey: configuration.remoteParticipantID
            ) ?? 0
        let transport = ServerMeshRuntimeTransport(
            configuration: configuration,
            remainingRemoteDescriptionFailures:
                remoteDescriptionFailureCount
        )
        transportsByParticipant[configuration.remoteParticipantID] = transport
        createdCount += 1
        return transport
    }

    func failCreation(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) {
        failedParticipants.insert(participantID)
    }

    func failNextRemoteDescription(
        onNextTransportFor participantID:
            ClipLiveShareNativeV3ParticipantID
    ) {
        remoteDescriptionFailuresOnNextTransport[participantID, default: 0]
            += 1
    }

    func transport(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> ServerMeshRuntimeTransport? {
        transportsByParticipant[participantID]
    }

    func makeCount() -> Int { createdCount }
}

private actor ServerMeshRuntimeTransport:
    ClipLiveShareNativeV3PeerLinkTransport
{
    nonisolated let configuration: ClipLiveShareNativeV3PeerLinkConfiguration
    private var continuation:
        AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent>.Continuation?
    private var descriptions: [WebRTCSessionDescription] = []
    private var candidates: [WebRTCICECandidate] = []
    private var controls: [Data] = []
    private var ephemeralControls: [Data] = []
    private var remainingControlSendFailures = 0
    private var remainingRemoteDescriptionFailures: Int
    private var restarts = 0
    private var negotiationRequests = 0
    private var remainingNegotiationRequestFailures = 0
    private var codecUpdates: [WebRTCVideoCodec] = []
    private var restoredCodecs: [WebRTCVideoCodec] = []
    private var rollbacks = 0
    private var currentCodec: WebRTCVideoCodec = .av1
    private var remoteVideoStreamRequests = 0
    private var audioPlaybackEnabledValues: [Bool] = []
    private var outboundMediaEnabled: [Bool] = []

    init(
        configuration: ClipLiveShareNativeV3PeerLinkConfiguration,
        remainingRemoteDescriptionFailures: Int = 0
    ) {
        self.configuration = configuration
        self.remainingRemoteDescriptionFailures =
            remainingRemoteDescriptionFailures
    }

    func events() -> AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ClipLiveShareNativeV3PeerLinkTransportEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = continuation
        return stream
    }

    func start() {}
    func requestNegotiation() throws {
        negotiationRequests += 1
        if remainingNegotiationRequestFailures > 0 {
            remainingNegotiationRequestFailures -= 1
            throw ServerMeshRuntimeTestError.controlSendFailed
        }
    }
    func applyRemoteDescription(
        _ description: WebRTCSessionDescription
    ) throws {
        if remainingRemoteDescriptionFailures > 0 {
            remainingRemoteDescriptionFailures -= 1
            throw ServerMeshRuntimeTestError.remoteDescriptionFailed
        }
        descriptions.append(description)
    }
    func addRemoteICECandidate(_ candidate: WebRTCICECandidate) {
        candidates.append(candidate)
    }
    func sendControlMessage(_ data: Data) throws {
        if remainingControlSendFailures > 0 {
            remainingControlSendFailures -= 1
            throw ServerMeshRuntimeTestError.controlSendFailed
        }
        controls.append(data)
    }
    func sendEphemeralControlMessage(_ data: Data) -> Bool {
        ephemeralControls.append(data)
        return true
    }
    func remoteVideoStream(
        for _: ClipLiveShareStreamDescriptor
    ) -> WebRTCRemoteVideoStream? {
        remoteVideoStreamRequests += 1
        return nil
    }
    func setOutboundMediaEnabled(_ enabled: Bool) {
        outboundMediaEnabled.append(enabled)
    }
    func setRemoteParticipantAudioPlaybackEnabled(_ enabled: Bool) {
        audioPlaybackEnabledValues.append(enabled)
    }
    func setRemoteParticipantAudioVolume(_: Double) {}
    func updateVideoCodecPreference(_ codec: WebRTCVideoCodec) {
        codecUpdates.append(codec)
        currentCodec = codec
    }
    func restoreVideoCodecPreference(_ codec: WebRTCVideoCodec) async throws {
        restoredCodecs.append(codec)
        currentCodec = codec
    }
    func currentVideoCodecPreference() async -> WebRTCVideoCodec? {
        currentCodec
    }
    func rollbackLocalOfferIfNeeded() { rollbacks += 1 }
    func restartICE() { restarts += 1 }
    func statistics() -> ClipLiveShareNativeV3PeerLinkTransportStatistics {
        .init(capturedAt: Date(timeIntervalSince1970: 0))
    }
    func close() {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ event: ClipLiveShareNativeV3PeerLinkTransportEvent) {
        continuation?.yield(event)
    }
    func remoteDescriptions() -> [WebRTCSessionDescription] { descriptions }
    func remoteCandidates() -> [WebRTCICECandidate] { candidates }
    func controlMessages() -> [Data] { controls }
    func ephemeralControlMessages() -> [Data] { ephemeralControls }
    func failNextControlMessages(_ count: Int) {
        remainingControlSendFailures = max(0, count)
    }
    func failNextNegotiationRequests(_ count: Int) {
        remainingNegotiationRequestFailures = max(0, count)
    }
    func restartCount() -> Int { restarts }
    func negotiationRequestCount() -> Int { negotiationRequests }
    func videoCodecUpdates() -> [WebRTCVideoCodec] { codecUpdates }
    func restoredVideoCodecs() -> [WebRTCVideoCodec] { restoredCodecs }
    func rollbackCount() -> Int { rollbacks }
    func outboundMediaEnabledValues() -> [Bool] { outboundMediaEnabled }
    func remoteVideoStreamRequestCount() -> Int {
        remoteVideoStreamRequests
    }
    func audioPlaybackPreferences() -> [Bool] {
        audioPlaybackEnabledValues
    }
}

private func serverMeshEventually(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for server-coordinated mesh state")
}
