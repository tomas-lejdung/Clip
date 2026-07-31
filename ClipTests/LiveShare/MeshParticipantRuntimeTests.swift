import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import Testing

@testable import Clip

@Suite("Mesh participant runtime")
struct MeshParticipantRuntimeTests {
    @Test("source manifests synchronize once when each direct channel opens")
    func sourceSynchronizationIsDirectAndOncePerRevision() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 3)
        let session = try await fixture.makeRuntime()
        try await session.runtime.start(at: fixture.now)

        try await session.runtime.publishLocalSources([])
        #expect(await session.factory.totalControlMessageCount() == 0)

        for peer in fixture.peerIDs {
            let transport = try #require(
                await session.factory.transport(for: peer)
            )
            await transport.emit(.controlChannelStateChanged(.open))
        }
        try await meshRuntimeEventually {
            await session.factory.totalControlMessageCount() == 2
        }
        for peer in fixture.peerIDs {
            let transport = try #require(
                await session.factory.transport(for: peer)
            )
            #expect(
                try await transport.controlEnvelopes()
                    .filter(\.isSourceSnapshot).count == 1
            )
            await transport.emit(.controlChannelStateChanged(.open))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await session.factory.totalControlMessageCount() == 2)

        try await session.runtime.publishLocalSources([])
        try await meshRuntimeEventually {
            await session.factory.totalControlMessageCount() == 4
        }
        await session.runtime.close()
    }

    @Test("a slow or failed peer cannot block source delivery to healthy peers")
    func sourceDeliveryIsIsolatedPerPeer() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 3)
        let session = try await fixture.makeRuntime()
        try await session.runtime.start(at: fixture.now)
        let healthy = try #require(
            await session.factory.transport(for: fixture.peerIDs[0])
        )
        let slow = try #require(
            await session.factory.transport(for: fixture.peerIDs[1])
        )
        await healthy.emit(.controlChannelStateChanged(.open))
        await slow.emit(.controlChannelStateChanged(.open))
        try await meshRuntimeEventually {
            (await session.manager.snapshot()).links.allSatisfy {
                $0.controlChannelState == .open
            }
        }
        await slow.setControlSendDelay(.milliseconds(180))
        await slow.failNextControlSend()

        let publication = Task {
            try await session.runtime.publishLocalSources([])
        }
        try await meshRuntimeEventually(timeout: .milliseconds(100)) {
            await healthy.controlMessageCount() == 1
        }
        #expect(await slow.controlMessageCount() == 0)
        try await publication.value
        await session.runtime.close()
    }

    @Test("one failed direct edge degrades only that participant")
    func directEdgeFailureDoesNotFailTheRoom() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 3)
        let session = try await fixture.makeRuntime()
        let recorder = MeshRuntimeEventRecorder()
        let stream = await session.runtime.events()
        let eventTask = Task {
            for await event in stream {
                await recorder.record(event)
            }
        }
        try await session.runtime.start(at: fixture.now)

        let failedPeer = fixture.peerIDs[0]
        let healthyPeer = fixture.peerIDs[1]
        let failedTransport = try #require(
            await session.factory.transport(for: failedPeer)
        )
        let healthyTransport = try #require(
            await session.factory.transport(for: healthyPeer)
        )
        await failedTransport.emit(.controlChannelStateChanged(.open))
        await healthyTransport.emit(.controlChannelStateChanged(.open))
        try await meshRuntimeEventually {
            (await session.manager.snapshot()).links.allSatisfy {
                $0.controlChannelState == .open
            }
        }

        await failedTransport.emit(.failed("fixture edge failed"))
        try await meshRuntimeEventually {
            await recorder.degradedParticipantIDs() == [failedPeer]
        }
        #expect(await recorder.failureCount() == 0)

        try await session.runtime.publishLocalSources([])
        try await meshRuntimeEventually {
            await healthyTransport.controlMessageCount() == 1
        }
        #expect(await healthyTransport.controlMessageCount() == 1)

        eventTask.cancel()
        await session.runtime.close()
    }

    @Test("an exhausted edge is recreated once and resynchronizes sources")
    func exhaustedEdgeGetsFreshPairTransport() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 3)
        let session = try await fixture.makeRuntime(
            reconnectPolicy: .disabled
        )
        let recorder = MeshRuntimeEventRecorder()
        let stream = await session.runtime.events()
        let eventTask = Task {
            for await event in stream {
                await recorder.record(event)
            }
        }
        try await session.runtime.start(at: fixture.now)

        let recoveredPeer = fixture.peerIDs[0]
        let healthyPeer = fixture.peerIDs[1]
        let original = try #require(
            await session.factory.transport(for: recoveredPeer)
        )
        let healthy = try #require(
            await session.factory.transport(for: healthyPeer)
        )
        await original.emit(.controlChannelStateChanged(.open))
        await healthy.emit(.controlChannelStateChanged(.open))
        let recoveredTrackID = try ClipLiveShareMediaTrackID(
            rawValue: "mesh-track"
        )
        await original.emit(.remoteVideoTrackAdded(recoveredTrackID))
        try await meshRuntimeEventually {
            await recorder.remoteTrackEventCount(
                participantID: recoveredPeer,
                isAvailable: true
            ) == 1
        }
        try await session.runtime.publishLocalSources([
            fixture.publishedSource(owner: fixture.localParticipantID)
        ])
        try await meshRuntimeEventually {
            let originalCount = await original.controlMessageCount()
            let healthyCount = await healthy.controlMessageCount()
            return originalCount == 1 && healthyCount == 1
        }

        await original.emit(.failed("fixture reconnect exhaustion"))
        try await meshRuntimeEventually {
            await session.factory.transportCreationCount(
                for: recoveredPeer
            ) == 2
        }
        #expect(await original.closeCount() == 1)
        #expect(await recorder.failureCount() == 0)
        #expect(
            await recorder.degradedParticipantIDs()
                .contains(recoveredPeer)
        )
        #expect(
            await recorder.remoteTrackEventCount(
                participantID: recoveredPeer,
                isAvailable: false
            ) == 1
        )

        let replacement = try #require(
            await session.factory.transport(for: recoveredPeer)
        )
        await replacement.emit(.localNegotiation(
            .sessionDescription(.init(
                kind: .offer,
                sdp: "fresh-pair-offer"
            ))
        ))
        try await meshRuntimeEventually {
            await session.bootstrap.sentCount() == 1
        }
        // WebRTC can announce a receiver before the pair's authenticated
        // control channel opens. The runtime retains it in the manager but
        // does not expose it until the recovered pair is ready.
        await replacement.emit(.remoteVideoTrackAdded(recoveredTrackID))
        await replacement.emit(.connectionStateChanged(.connected))
        await replacement.emit(.controlChannelStateChanged(.open))
        try await meshRuntimeEventually {
            try await replacement.controlEnvelopes()
                .filter(\.isSourceSnapshot).count == 1
        }
        try await meshRuntimeEventually {
            (await session.runtime.snapshot()).links.links.contains {
                $0.remoteParticipantID == recoveredPeer && $0.isReady
            }
        }
        try await meshRuntimeEventually {
            await recorder.remoteTrackEventCount(
                participantID: recoveredPeer,
                isAvailable: true
            ) == 2
        }
        #expect(await healthy.controlMessageCount() == 1)

        eventTask.cancel()
        await session.runtime.close()
    }

    @Test("room control broadcast commits healthy edges despite one send failure")
    func roomControlBroadcastIsBestEffortPerPeer() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 3)
        let session = try await fixture.makeRuntime()
        let recorder = MeshRuntimeEventRecorder()
        let stream = await session.runtime.events()
        let eventTask = Task {
            for await event in stream {
                await recorder.record(event)
            }
        }
        try await session.runtime.start(at: fixture.now)

        let failedPeer = fixture.peerIDs[0]
        let healthyPeer = fixture.peerIDs[1]
        let failedTransport = try #require(
            await session.factory.transport(for: failedPeer)
        )
        let healthyTransport = try #require(
            await session.factory.transport(for: healthyPeer)
        )
        await failedTransport.emit(.controlChannelStateChanged(.open))
        await healthyTransport.emit(.controlChannelStateChanged(.open))
        try await meshRuntimeEventually {
            (await session.manager.snapshot()).links.allSatisfy {
                $0.controlChannelState == .open
            }
        }
        try await session.runtime.publishLocalSources([])
        let localSnapshot = try #require(
            (await session.runtime.snapshot())
                .sourceSnapshots[fixture.localParticipantID]
        )
        let healthyCountBefore = await healthyTransport.controlMessageCount()
        await failedTransport.failNextControlSend()

        try await session.runtime.sendRoomControl(
            .sourceSnapshot(localSnapshot)
        )

        try await meshRuntimeEventually {
            await healthyTransport.controlMessageCount()
                == healthyCountBefore + 1
        }
        try await meshRuntimeEventually {
            await recorder.degradedParticipantIDs().contains(failedPeer)
        }
        #expect(await recorder.failureCount() == 0)

        eventTask.cancel()
        await session.runtime.close()
    }

    @Test("provisional pairs cannot leak topology media control or statistics")
    func provisionalPairStateIsQuarantined() async throws {
        let fixture = try MeshRuntimeFixture(
            participantCount: 3,
            committedParticipantCount: 2
        )
        let session = try await fixture.makeRuntime()
        try await session.runtime.start(at: fixture.now)

        let candidate = fixture.participants[2].participantID
        try await session.manager.reconcileParticipants(
            Set(
                fixture.initialMembership.snapshot.participantIDs
                    .union([candidate])
            ),
            quarantinedParticipantIDs: [candidate]
        )
        let candidateTransport = try #require(
            await session.factory.transport(for: candidate)
        )
        let provisionalTrackID = try ClipLiveShareMediaTrackID(
            rawValue: "provisional-video"
        )
        await candidateTransport.emit(.connectionStateChanged(.connected))
        await candidateTransport.emit(.controlChannelStateChanged(.open))
        await candidateTransport.emit(
            .remoteVideoTrackAdded(provisionalTrackID)
        )
        await candidateTransport.emit(
            .remoteParticipantAudioAvailable(
                trackID: "provisional-audio"
            )
        )
        try await meshRuntimeEventually {
            let link = await session.manager.snapshot().links.first {
                $0.remoteParticipantID == candidate
            }
            return link?.controlChannelState == .open
                && link?.remoteVideoTrackIDs == [provisionalTrackID]
                && link?.remoteParticipantAudioTrackID
                    == "provisional-audio"
        }

        try await session.runtime.publishLocalSources([
            fixture.publishedSource(owner: fixture.localParticipantID)
        ])
        try await session.runtime.refreshStatistics()
        let snapshot = await session.runtime.snapshot()
        #expect(
            snapshot.links.participantIDs
                == fixture.initialMembership.snapshot.participantIDs
        )
        #expect(
            !snapshot.links.links.contains {
                $0.remoteParticipantID == candidate
            }
        )
        #expect(snapshot.audioTrackIDs[candidate] == nil)
        #expect(snapshot.statistics[candidate] == nil)
        #expect(await candidateTransport.controlMessageCount() == 0)

        do {
            try await session.runtime.setParticipantAudioEnabled(
                true,
                participantID: candidate
            )
            Issue.record("Expected provisional participant audio to fail")
        } catch {
            #expect(
                error as? ClipLiveShareNativeV3Error
                    == .unknownParticipant(candidate)
            )
        }
        await session.runtime.close()
    }

    @Test("bootstrap carries negotiation only until the direct channel opens")
    func directControlTakesOverFromBootstrap() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 2)
        let session = try await fixture.makeRuntime()
        try await session.runtime.start(at: fixture.now)
        let peer = fixture.peerIDs[0]
        let transport = try #require(
            await session.factory.transport(for: peer)
        )

        await transport.emit(
            .localNegotiation(
                .sessionDescription(
                    .init(kind: .offer, sdp: "bootstrap-offer")
                )
            )
        )
        try await meshRuntimeEventually {
            await session.bootstrap.sentCount() == 1
        }
        #expect(await transport.controlMessageCount() == 0)

        await transport.emit(.controlChannelStateChanged(.open))
        try await meshRuntimeEventually {
            (await session.manager.snapshot()).links.first?
                .controlChannelState == .open
        }
        await transport.emit(
            .localNegotiation(
                .sessionDescription(
                    .init(kind: .offer, sdp: "direct-offer")
                )
            )
        )
        try await meshRuntimeEventually {
            await transport.controlMessageCount() == 1
        }
        #expect(await session.bootstrap.sentCount() == 1)
        let direct = try #require(
            try await transport.controlEnvelopes().last
        )
        guard case let .peerLinkOffer(offer) = direct else {
            Issue.record("Expected a signed direct peer-link offer")
            await session.runtime.close()
            return
        }
        #expect(offer.offer.sdp == "direct-offer")
        await session.runtime.close()
    }

    @Test("pointer, hide, ping, ink and owner clear replicate over control")
    func collaborationPropagation() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 2)
        let session = try await fixture.makeRuntime()
        try await session.runtime.start(at: fixture.now)
        let peer = fixture.peerIDs[0]
        let transport = try #require(
            await session.factory.transport(for: peer)
        )
        await transport.emit(.controlChannelStateChanged(.open))
        try await meshRuntimeEventually {
            (await session.manager.snapshot()).links.first?
                .controlChannelState == .open
        }
        let source = try fixture.publishedSource(
            owner: fixture.localParticipantID
        )
        try await session.runtime.publishLocalSources([source])
        let sourceKey = source.key

        let visible = try fixture.pointer(
            participantID: fixture.localParticipantID,
            sourceKey: sourceKey,
            sequence: 1,
            position: .init(x: 0.25, y: 0.75)
        )
        try await session.runtime.broadcastCollaboration(visible)
        #expect(
            (await session.runtime.snapshot())
                .collaboration[sourceKey]?
                .pointers[fixture.localParticipantID] != nil
        )

        let hidden = try fixture.pointer(
            participantID: fixture.localParticipantID,
            sourceKey: sourceKey,
            sequence: 2,
            position: nil
        )
        try await session.runtime.broadcastCollaboration(hidden)
        #expect(
            (await session.runtime.snapshot())
                .collaboration[sourceKey]?
                .pointers[fixture.localParticipantID] == nil
        )
        let peerPointer = try fixture.pointer(
            participantID: peer,
            sourceKey: sourceKey,
            sequence: 1,
            position: .init(x: 0.8, y: 0.2)
        )
        let color = try ClipLiveShareNativeV3CollaborationColor(
            red: 255,
            green: 90,
            blue: 40
        )
        let pingContext = try fixture.collaborationContext(
            participantID: peer,
            sourceKey: sourceKey,
            sequence: 2
        )
        let ping = ClipLiveShareNativeV3CollaborationEvent.ping(
            try .init(
                context: pingContext,
                position: .init(x: 0.6, y: 0.4),
                color: color,
                expiresAt: pingContext.sentAt.adding(milliseconds: 5_000)
            )
        )
        let strokeID = ClipLiveShareNativeV3StrokeID()
        let beginContext = try fixture.collaborationContext(
            participantID: peer,
            sourceKey: sourceKey,
            sequence: 3
        )
        let begin = ClipLiveShareNativeV3CollaborationEvent.strokeBegin(
            try .init(
                context: beginContext,
                strokeID: strokeID,
                point: .init(x: 0.1, y: 0.1),
                color: color,
                expiresAt: beginContext.sentAt.adding(milliseconds: 20_000)
            )
        )
        let points = ClipLiveShareNativeV3CollaborationEvent.strokePoints(
            try .init(
                context: fixture.collaborationContext(
                    participantID: peer,
                    sourceKey: sourceKey,
                    sequence: 4
                ),
                strokeID: strokeID,
                points: [
                    .init(x: 0.2, y: 0.2),
                    .init(x: 0.3, y: 0.25),
                ]
            )
        )
        let end = ClipLiveShareNativeV3CollaborationEvent.strokeEnd(
            .init(
                context: try fixture.collaborationContext(
                    participantID: peer,
                    sourceKey: sourceKey,
                    sequence: 5
                ),
                strokeID: strokeID
            )
        )
        for event in [peerPointer, ping, begin, points, end] {
            await transport.emit(
                .controlMessageReceived(
                    try ClipLiveShareNativeV3ControlCodec.encode(
                        .collaboration(event)
                    )
                )
            )
        }
        try await meshRuntimeEventually {
            let state = (await session.runtime.snapshot())
                .collaboration[sourceKey]
            return state?.pointers[peer] != nil
                && state?.pings.count == 1
                && state?.strokes[strokeID]?.isComplete == true
                && state?.strokes[strokeID]?.points.count == 3
        }
        let clear = ClipLiveShareNativeV3CollaborationEvent.clear(
            try .init(
                context: fixture.collaborationContext(
                    participantID: fixture.localParticipantID,
                    sourceKey: sourceKey,
                    sequence: 3
                ),
                clearEpoch: 1,
                scope: .source
            )
        )
        try await session.runtime.broadcastCollaboration(clear)
        let cleared = try #require(
            (await session.runtime.snapshot()).collaboration[sourceKey]
        )
        #expect(cleared.pointers.isEmpty)
        #expect(cleared.pings.isEmpty)
        #expect(cleared.strokes.isEmpty)

        let events = try await transport.controlEnvelopes().compactMap {
            if case let .collaboration(value) = $0 { value } else { nil }
        }
        #expect(events == [visible, hidden, clear])
        await session.runtime.close()
    }

    @Test("removing a publication prunes collaboration and rejects delayed events")
    func collaborationIsBoundToExactSourceInstance() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 2)
        let session = try await fixture.makeRuntime()
        try await session.runtime.start(at: fixture.now)

        let original = try fixture.publishedSource(
            owner: fixture.localParticipantID
        )
        try await session.runtime.publishLocalSources([original])
        let visible = try fixture.pointer(
            participantID: fixture.localParticipantID,
            sourceKey: original.key,
            sequence: 1,
            position: .init(x: 0.25, y: 0.75)
        )
        try await session.runtime.broadcastCollaboration(visible)
        #expect(
            (await session.runtime.snapshot())
                .collaboration[original.key] != nil
        )

        try await session.runtime.publishLocalSources([])
        let removed = await session.runtime.snapshot()
        #expect(removed.collaboration[original.key] == nil)

        let delayed = try fixture.pointer(
            participantID: fixture.localParticipantID,
            sourceKey: original.key,
            sequence: 2,
            position: .init(x: 0.5, y: 0.5)
        )
        await #expect(
            throws: MeshParticipantRuntimeError.sourceBeforeMembershipCommit
        ) {
            try await session.runtime.broadcastCollaboration(delayed)
        }

        let replacement = try fixture.publishedSource(
            owner: fixture.localParticipantID
        )
        #expect(replacement.key != original.key)
        try await session.runtime.publishLocalSources([replacement])
        let replacementPointer = try fixture.pointer(
            participantID: fixture.localParticipantID,
            sourceKey: replacement.key,
            sequence: 1,
            position: .init(x: 0.75, y: 0.25)
        )
        try await session.runtime.broadcastCollaboration(replacementPointer)
        #expect(
            (await session.runtime.snapshot())
                .collaboration[replacement.key]?
                .pointers[fixture.localParticipantID] != nil
        )

        await session.runtime.close()
    }

    @Test("native cursor context is bound to the authenticated source")
    func sourceCursorContextIsSourceScoped() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 2)
        let session = try await fixture.makeRuntime()
        let recorder = MeshRuntimeEventRecorder()
        let events = await session.runtime.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }
        try await session.runtime.start(at: fixture.now)
        let peer = fixture.peerIDs[0]
        let transport = try #require(
            await session.factory.transport(for: peer)
        )
        await transport.emit(.controlChannelStateChanged(.open))
        let source = try fixture.publishedSource(owner: peer)
        let sourceSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
            sessionID: fixture.sessionID,
            membershipRevision:
                fixture.initialMembership.snapshot.membershipRevision,
            ownerParticipantID: peer,
            sourceRevision: .init(rawValue: 1),
            sources: [source]
        )
        await transport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .sourceSnapshot(sourceSnapshot)
            )
        ))
        try await meshRuntimeEventually {
            (await session.runtime.snapshot()).sourceSnapshots[peer]?
                .sources == [source]
        }

        let cursor = try ClipLiveShareNativeV3SourceCursor(
            sessionID: fixture.sessionID,
            participantID: peer,
            sourceKey: source.key,
            streamID: source.descriptor.stream.id,
            sequence: 1,
            position: .init(x: 0.4, y: 0.6)
        )
        await transport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .sourceCursor(cursor)
            )
        ))
        try await meshRuntimeEventually {
            await recorder.sourceCursors() == [cursor]
        }

        eventTask.cancel()
        await session.runtime.close()
    }

    @Test("membership removal tears down exactly one participant")
    func exactParticipantTeardown() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 3)
        let session = try await fixture.makeRuntime()
        try await session.runtime.start(at: fixture.now)
        let removed = fixture.peerIDs[1]
        let retained = fixture.peerIDs[0]
        let removedTransport = try #require(
            await session.factory.transport(for: removed)
        )
        let retainedTransport = try #require(
            await session.factory.transport(for: retained)
        )
        let nextMembership = try fixture.membership(
            participantIDs: [
                fixture.localParticipantID,
                retained,
            ],
            revision: 2
        )
        let nextAuthority = try ClipLiveShareNativeV3RoomAuthorityChain(
            foundingCreatorParticipantID: fixture.localParticipantID,
            foundingCreatorIdentity: fixture.signers[0].publicKey,
            genesisMembership: fixture.initialMembership,
            checkpoints: [],
            latestMembership: nextMembership
        )
        try await session.runtime.commitMembership(
            nextMembership,
            validatedAuthorityChain: nextAuthority,
            verifiedNonces: [
                retained: fixture.nonces[retained]!,
            ],
            bootstrapAdmissionDigests: [
                retained: fixture.digests[retained]!,
            ],
            at: fixture.now
        )

        #expect(await removedTransport.closeCount() == 1)
        #expect(await retainedTransport.closeCount() == 0)
        let snapshot = await session.runtime.snapshot()
        #expect(snapshot.signedMembership == nextMembership)
        #expect(
            Set(snapshot.links.links.map(\.remoteParticipantID))
                == [retained]
        )
        await session.runtime.close()
    }

    @Test("an upper-ID participant requests codec renegotiation over direct control")
    func upperParticipantRequestsLowerOwnedOffer() async throws {
        let fixture = try MeshRuntimeFixture(
            participantCount: 2,
            localIndex: 1
        )
        let session = try await fixture.makeRuntime()
        try await session.runtime.start(at: fixture.now)
        let peer = fixture.peerIDs[0]
        let transport = try #require(
            await session.factory.transport(for: peer)
        )
        await transport.emit(.controlChannelStateChanged(.open))
        try await meshRuntimeEventually {
            (await session.manager.snapshot()).links.first?
                .controlChannelState == .open
        }

        try await session.runtime.updateVideoCodec(.vp8, at: fixture.now)
        try await meshRuntimeEventually {
            await transport.controlMessageCount() == 1
        }
        #expect(await transport.negotiationRequestCount() == 0)
        let requestEnvelope = try #require(
            try await transport.controlEnvelopes().first
        )
        guard case let .peerLinkRenegotiationRequest(signedRequest) =
            requestEnvelope
        else {
            Issue.record("Expected a signed renegotiation request")
            await session.runtime.close()
            return
        }
        #expect(
            signedRequest.request.context.senderParticipantID
                == fixture.localParticipantID
        )
        #expect(
            signedRequest.request.context.receiverParticipantID == peer
        )
        #expect(signedRequest.request.preferredVideoCodec == "vp8")

        let offer = try fixture.signedOffer(
            senderIndex: 0,
            receiverIndex: 1,
            revision: 1,
            sdp: "lower-owned-codec-offer"
        )
        await transport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .peerLinkOffer(offer)
            )
        ))
        try await meshRuntimeEventually {
            await transport.remoteDescriptionCount() == 1
        }
        await transport.emit(.localNegotiation(
            .sessionDescription(
                .init(kind: .answer, sdp: "upper-codec-answer")
            )
        ))
        try await meshRuntimeEventually {
            await transport.controlMessageCount() == 2
        }
        #expect(await transport.codecHistory() == [.vp8])
        await session.runtime.close()
    }

    @Test("signed renegotiation replay coalesces and invalid requests quarantine only their sender")
    func renegotiationReplayAndPairValidation() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 3)
        let session = try await fixture.makeRuntime()
        let eventRecorder = MeshRuntimeEventRecorder()
        let eventStream = await session.runtime.events()
        let eventTask = Task {
            for await event in eventStream {
                await eventRecorder.record(event)
            }
        }
        try await session.runtime.start(at: fixture.now)
        let peer = fixture.peerIDs[0]
        let transport = try #require(
            await session.factory.transport(for: peer)
        )
        await transport.emit(.controlChannelStateChanged(.open))
        try await meshRuntimeEventually {
            (await session.manager.snapshot()).links.first {
                $0.remoteParticipantID == peer
            }?.controlChannelState == .open
        }

        let accepted = try fixture.signedRenegotiationRequest(
            senderIndex: 1,
            receiverIndex: 0,
            revision: 2,
            codec: .vp8
        )
        let acceptedData = try ClipLiveShareNativeV3ControlCodec.encode(
            .peerLinkRenegotiationRequest(accepted)
        )
        await transport.emit(.controlMessageReceived(acceptedData))
        await transport.emit(.controlMessageReceived(acceptedData))
        try await meshRuntimeEventually {
            await transport.negotiationRequestCount() == 1
        }
        #expect(await transport.codecHistory() == [.vp8])

        let stale = try fixture.signedRenegotiationRequest(
            senderIndex: 1,
            receiverIndex: 0,
            revision: 1,
            codec: .h264
        )
        await transport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .peerLinkRenegotiationRequest(stale)
            )
        ))
        let equivocation = try fixture.signedRenegotiationRequest(
            senderIndex: 1,
            receiverIndex: 0,
            revision: 2,
            codec: .vp9
        )
        await transport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .peerLinkRenegotiationRequest(equivocation)
            )
        ))
        let wrongPair = try fixture.signedRenegotiationRequest(
            senderIndex: 2,
            receiverIndex: 1,
            revision: 3,
            codec: .vp9
        )
        await transport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .peerLinkRenegotiationRequest(wrongPair)
            )
        ))
        try await meshRuntimeEventually {
            await eventRecorder.degradedParticipantIDs() == [peer]
        }
        #expect(await eventRecorder.failureCount() == 0)
        #expect(await transport.negotiationRequestCount() == 1)
        #expect(await transport.codecHistory() == [.vp8, .h264])

        eventTask.cancel()
        await session.runtime.close()
    }

    @Test("malformed control data quarantines one peer while a healthy peer remains usable")
    func malformedControlDataIsPeerScoped() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 3)
        let session = try await fixture.makeRuntime()
        let eventRecorder = MeshRuntimeEventRecorder()
        let eventStream = await session.runtime.events()
        let eventTask = Task {
            for await event in eventStream {
                await eventRecorder.record(event)
            }
        }
        try await session.runtime.start(at: fixture.now)

        let malformedPeer = fixture.peerIDs[0]
        let healthyPeer = fixture.peerIDs[1]
        let malformedTransport = try #require(
            await session.factory.transport(for: malformedPeer)
        )
        let healthyTransport = try #require(
            await session.factory.transport(for: healthyPeer)
        )
        await malformedTransport.emit(.controlChannelStateChanged(.open))
        await healthyTransport.emit(.controlChannelStateChanged(.open))
        try await meshRuntimeEventually {
            (await session.manager.snapshot()).links.allSatisfy {
                $0.controlChannelState == .open
            }
        }

        await malformedTransport.emit(
            .controlMessageReceived(Data([0xff, 0x00, 0x7f]))
        )
        try await meshRuntimeEventually {
            await eventRecorder.degradedParticipantIDs() == [malformedPeer]
        }
        #expect(await eventRecorder.failureCount() == 0)

        let healthyCountBefore =
            await healthyTransport.controlMessageCount()
        try await session.runtime.publishLocalSources([])
        try await meshRuntimeEventually {
            await healthyTransport.controlMessageCount()
                == healthyCountBefore + 1
        }

        eventTask.cancel()
        await session.runtime.close()
    }

    @Test("a failed second codec request does not roll back the first pair")
    func codecTransactionsAreIndependentPerPair() async throws {
        let fixture = try MeshRuntimeFixture(
            participantCount: 3,
            localIndex: 2
        )
        let session = try await fixture.makeRuntime()
        try await session.runtime.start(at: fixture.now)
        let firstPeer = fixture.peerIDs[0]
        let secondPeer = fixture.peerIDs[1]
        let first = try #require(
            await session.factory.transport(for: firstPeer)
        )
        let second = try #require(
            await session.factory.transport(for: secondPeer)
        )
        await first.emit(.controlChannelStateChanged(.open))
        await second.emit(.controlChannelStateChanged(.open))
        try await meshRuntimeEventually {
            (await session.manager.snapshot()).links.allSatisfy {
                $0.controlChannelState == .open
            }
        }
        await second.failNextControlSend()

        await #expect(
            throws: MeshParticipantRuntimeError.codecUpdateFailed(
                [secondPeer.rawValue]
            )
        ) {
            try await session.runtime.updateVideoCodec(
                .vp8,
                at: fixture.now
            )
        }
        #expect(await first.codecHistory() == [.vp8])
        #expect(await second.codecHistory() == [.vp8, .h264])
        #expect(await first.controlMessageCount() == 1)
        #expect(await second.controlMessageCount() == 0)

        let offer = try fixture.signedOffer(
            senderIndex: 0,
            receiverIndex: 2,
            revision: 1,
            sdp: "first-pair-offer"
        )
        await first.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .peerLinkOffer(offer)
            )
        ))
        try await meshRuntimeEventually {
            await first.remoteDescriptionCount() == 1
        }
        await first.emit(.localNegotiation(
            .sessionDescription(
                .init(kind: .answer, sdp: "first-pair-answer")
            )
        ))
        try await meshRuntimeEventually {
            await first.controlMessageCount() == 2
        }
        #expect(await first.codecHistory() == [.vp8])
        #expect(await second.codecHistory() == [.vp8, .h264])
        await session.runtime.close()
    }

    @Test("bootstrap forwarding uses the current leader as its only direct hub")
    func bootstrapForwardUsesLeaderHubAndRejectsPostCommitReplay()
        async throws
    {
        let fixture = try MeshRuntimeFixture(
            participantCount: 3,
            localIndex: 1,
            committedParticipantCount: 2
        )
        let session = try await fixture.makeRuntime()
        let recorder = MeshRuntimeEventRecorder()
        let stream = await session.runtime.events()
        let eventTask = Task {
            for await event in stream {
                await recorder.record(event)
            }
        }
        try await session.runtime.start(at: fixture.now)
        let leaderID = fixture.participants[0].participantID
        let candidateID = fixture.participants[2].participantID
        let leaderTransport = try #require(
            await session.factory.transport(for: leaderID)
        )
        await leaderTransport.emit(.controlChannelStateChanged(.open))
        try await meshRuntimeEventually {
            (await session.manager.snapshot()).links.first?
                .controlChannelState == .open
        }

        let admissionDigest = ClipLiveShareNativeDigest(
            hashing: Data("candidate-three-admission".utf8)
        )
        let hello = try fixture.signedBootstrapHello(
            participantIndex: 2
        )
        let leaderToExisting = try ClipLiveShareNativeV3BootstrapForward(
            sessionID: fixture.sessionID,
            admissionDigest: admissionDigest,
            originParticipantID: candidateID,
            targetParticipantID: fixture.localParticipantID,
            envelope: .hello(hello)
        )
        await leaderTransport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .bootstrapForward(leaderToExisting)
            )
        ))
        try await meshRuntimeEventually {
            await recorder.bootstrapForwardCount() == 1
        }

        let challenge = try ClipLiveShareNativeV3PossessionChallenge(
            sessionID: fixture.sessionID,
            membershipRevision: .init(rawValue: 2),
            peerLinkKey: .init(
                fixture.localParticipantID,
                candidateID
            ),
            verifierParticipantID: fixture.localParticipantID,
            proverParticipantID: candidateID,
            credentialDigest: ClipLiveShareNativeDigest(
                hashing: Data("candidate-credential".utf8)
            ),
            transportNonce: .init(
                bytes: Data(repeating: 0xC3, count: 32)
            ),
            challenge: Data(repeating: 0xA3, count: 32),
            issuedAt: fixture.now,
            expiresAt: fixture.now.adding(milliseconds: 30_000)
        )
        let relay = try ClipLiveShareNativeV3BootstrapRelay(
            sessionID: fixture.sessionID,
            admissionDigest: admissionDigest,
            originParticipantID: fixture.localParticipantID,
            targetParticipantID: candidateID,
            payload: .possessionChallenge(challenge)
        )
        let existingToLeader = try ClipLiveShareNativeV3BootstrapForward(
            sessionID: fixture.sessionID,
            admissionDigest: admissionDigest,
            originParticipantID: fixture.localParticipantID,
            targetParticipantID: candidateID,
            envelope: .relay(relay)
        )
        try await session.runtime.sendBootstrapForward(
            existingToLeader,
            toDirectParticipantID: leaderID
        )
        try await meshRuntimeEventually {
            await leaderTransport.controlMessageCount() == 1
        }
        #expect(
            try await leaderTransport.controlEnvelopes().first
                == .bootstrapForward(existingToLeader)
        )

        await #expect(
            throws: MeshParticipantRuntimeError.invalidBootstrapForward
        ) {
            try await session.runtime.sendBootstrapForward(
                leaderToExisting,
                toDirectParticipantID: leaderID
            )
        }

        let committed = try fixture.membership(
            participantIDs: Set(fixture.participants.map(\.participantID)),
            revision: 2
        )
        let authority = try ClipLiveShareNativeV3RoomAuthorityChain(
            foundingCreatorParticipantID: leaderID,
            foundingCreatorIdentity: fixture.signers[0].publicKey,
            genesisMembership: fixture.initialMembership,
            checkpoints: [],
            latestMembership: committed
        )
        let candidateNonce = try ClipLiveShareNativeV3TransportNonce(
            bytes: Data(repeating: 0xD3, count: 32)
        )
        try await session.runtime.commitMembership(
            committed,
            validatedAuthorityChain: authority,
            verifiedNonces: [
                leaderID: fixture.nonces[leaderID]!,
                candidateID: candidateNonce,
            ],
            bootstrapAdmissionDigests: [
                leaderID: fixture.digests[leaderID]!,
                candidateID: admissionDigest,
            ],
            at: fixture.now
        )
        await leaderTransport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .bootstrapForward(leaderToExisting)
            )
        ))
        try await meshRuntimeEventually {
            await recorder.degradedParticipantIDs().contains(leaderID)
        }
        #expect(await recorder.failureCount() == 0)
        #expect(await recorder.bootstrapForwardCount() == 1)

        eventTask.cancel()
        await session.runtime.close()
    }
}

@Suite("Mesh participant coordinator resilience", .serialized)
@MainActor
struct MeshParticipantCoordinatorResilienceTests {
    @Test("last remote window offers leave only while remote audio remains")
    func lastRemoteWindowLeavePolicy() {
        #expect(MeshRemoteWindowClosePolicy.shouldConfirmLeave(
            visibleRemoteWindowCount: 1,
            hasRemoteAudio: true
        ))
        #expect(!MeshRemoteWindowClosePolicy.shouldConfirmLeave(
            visibleRemoteWindowCount: 2,
            hasRemoteAudio: true
        ))
        #expect(!MeshRemoteWindowClosePolicy.shouldConfirmLeave(
            visibleRemoteWindowCount: 1,
            hasRemoteAudio: false
        ))
        #expect(!MeshRemoteWindowClosePolicy.shouldConfirmLeave(
            visibleRemoteWindowCount: 0,
            hasRemoteAudio: true
        ))
    }

    @Test(
        "local leader restores authority only after an exact-chain quorum confirms"
    )
    func localLeaderRestoreRequiresAuthorityConfirmation() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 4)
        let session = try fixture.makeCoordinator()
        session.coordinator.start()
        try await session.openAllPeerLinks()
        try await meshCoordinatorEventually {
            if case .live =
                session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }

        let encodedAuthority =
            try ClipLiveShareNativeV3ControlCodec.encode(
                .roomAuthority(fixture.authority)
            )
        let confirmationPeers = [
            fixture.peerIDs[0],
            fixture.peerIDs[1],
        ]
        var controlCountsBeforeConfirmation:
            [ClipLiveShareNativeV3ParticipantID: Int] = [:]
        for peerID in confirmationPeers {
            let transport = try #require(
                await session.transportFactory.transport(for: peerID)
            )
            controlCountsBeforeConfirmation[peerID] =
                await transport.controlMessageCount()
            await transport.emit(.controlMessageReceived(encodedAuthority))
        }
        let baselineControlCounts = controlCountsBeforeConfirmation
        try await meshRuntimeEventually {
            for peerID in confirmationPeers {
                guard
                    let transport =
                        await session.transportFactory.transport(
                            for: peerID
                    ),
                    await transport.controlMessageCount()
                        > baselineControlCounts[peerID, default: 0]
                else {
                    return false
                }
            }
            return true
        }

        let returningPeer = fixture.peerIDs[1]
        let unavailablePeer = fixture.peerIDs[2]
        let returningTransport = try #require(
            await session.transportFactory.transport(
                for: returningPeer
            )
        )
        let unavailableTransport = try #require(
            await session.transportFactory.transport(
                for: unavailablePeer
            )
        )
        await returningTransport.emit(
            .controlChannelStateChanged(.closed)
        )
        await unavailableTransport.emit(
            .controlChannelStateChanged(.closed)
        )

        try await meshCoordinatorEventually {
            session.coordinator.presentationModel.snapshot.phase
                == .leaderlessLocked
        }
        await returningTransport.emit(
            .controlChannelStateChanged(.open)
        )
        try await meshCoordinatorEventually {
            let snapshot =
                session.coordinator.presentationModel.snapshot
            let recovered = snapshot.remoteParticipants.first {
                $0.id == returningPeer.rawValue
            }
            return snapshot.phase == .leaderlessLocked
                && recovered?.route == .direct
        }

        // Raw link reachability is now a strict majority, but authority stays
        // locked until this peer confirms the exact current chain.
        await returningTransport.emit(
            .controlMessageReceived(encodedAuthority)
        )
        try await meshCoordinatorEventually {
            if case .live =
                session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }

        session.coordinator.presentationModel.endRoomForEveryone()
        try await meshCoordinatorEventually {
            if case .ended =
                session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }
    }

    @Test("one direct peer failure leaves the coordinator room live")
    func peerFailureDoesNotFailCoordinator() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 3)
        let session = try fixture.makeCoordinator()
        session.coordinator.start()

        try await session.openAllPeerLinks()
        try await meshCoordinatorEventually {
            if case .live = session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }

        let failedPeer = fixture.peerIDs[0]
        let healthyPeer = fixture.peerIDs[1]
        let failedTransport = try #require(
            await session.transportFactory.transport(for: failedPeer)
        )
        await failedTransport.emit(.failed("fixture direct edge failed"))

        try await meshCoordinatorEventually {
            let snapshot = session.coordinator.presentationModel.snapshot
            guard case .live = snapshot.phase else { return false }
            let failed = snapshot.remoteParticipants.first {
                $0.id == failedPeer.rawValue
            }
            let healthy = snapshot.remoteParticipants.first {
                $0.id == healthyPeer.rawValue
            }
            return failed?.route == .disconnected
                && healthy?.route == .direct
        }
        #expect(session.coordinator.isActive)

        session.coordinator.presentationModel.endRoomForEveryone()
        try await meshCoordinatorEventually {
            if case .ended = session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }
    }

    @Test("invalid peer room state quarantines only its sender")
    func invalidPeerRoomStateDoesNotFailCoordinator() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 3)
        let session = try fixture.makeCoordinator()
        session.coordinator.start()
        try await session.openAllPeerLinks()
        try await meshCoordinatorEventually {
            if case .live = session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }

        let invalidPeer = fixture.peerIDs[0]
        let healthyPeer = fixture.peerIDs[1]
        let invalidTransport = try #require(
            await session.transportFactory.transport(for: invalidPeer)
        )
        // Only the current leader may originate an ordinary membership. The
        // signed value itself is valid, so this exercises coordinator-level
        // sender semantics rather than wire decoding.
        await invalidTransport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .membershipSnapshot(fixture.initialMembership)
            )
        ))

        try await meshRuntimeEventually {
            await invalidTransport.closeCount() == 1
        }
        try await meshCoordinatorEventually {
            let snapshot = session.coordinator.presentationModel.snapshot
            guard case .live = snapshot.phase else { return false }
            let invalid = snapshot.remoteParticipants.first {
                $0.id == invalidPeer.rawValue
            }
            let healthy = snapshot.remoteParticipants.first {
                $0.id == healthyPeer.rawValue
            }
            return invalid?.route == .disconnected
                && healthy?.route == .direct
        }
        #expect(session.coordinator.isActive)

        session.coordinator.presentationModel.endRoomForEveryone()
        try await meshCoordinatorEventually {
            if case .ended = session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }
    }

    @Test("retry replaces the failed event subscription and returns to live")
    func retryAfterGlobalFailureRestartsEventConsumption() async throws {
        let fixture = try MeshRuntimeFixture(participantCount: 2)
        let session = try fixture.makeCoordinator()
        session.coordinator.start()
        try await session.openAllPeerLinks()
        try await meshCoordinatorEventually {
            if case .live = session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }

        await session.bootstrap.emit(.failed("fixture global failure"))
        try await meshCoordinatorEventually {
            if case .failed =
                session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }

        session.coordinator.presentationModel.retry()
        try await meshCoordinatorEventually {
            session.coordinator.presentationModel.snapshot.phase
                == .reconnecting
        }
        try await session.openAllPeerLinks()
        try await meshCoordinatorEventually {
            if case .live = session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }
        #expect(session.coordinator.isActive)

        session.coordinator.presentationModel.endRoomForEveryone()
        try await meshCoordinatorEventually {
            if case .ended = session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }
    }

    @Test("crashed leader is excluded while a reachable quorum commits succession")
    func crashedLeaderDoesNotBlockCoordinatorSuccession() async throws {
        let fixture = try MeshRuntimeFixture(
            participantCount: 4,
            localIndex: 1
        )
        let session = try fixture.makeCoordinator(
            leaderLossStabilityDuration: .milliseconds(10)
        )
        session.coordinator.start()
        try await session.openAllPeerLinks()
        try await meshCoordinatorEventually {
            if case .live = session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }

        let crashedLeaderID = fixture.participants[0].participantID
        let voterAID = fixture.participants[2].participantID
        let voterBID = fixture.participants[3].participantID
        let crashedTransport = try #require(
            await session.transportFactory.transport(for: crashedLeaderID)
        )
        let voterATransport = try #require(
            await session.transportFactory.transport(for: voterAID)
        )
        let voterBTransport = try #require(
            await session.transportFactory.transport(for: voterBID)
        )
        await crashedTransport.emit(.failed("fixture leader crashed"))

        try await meshRuntimeEventually(timeout: .seconds(3)) {
            try await voterATransport.controlEnvelopes()
                .compactMap(\.leadershipProposal)
                .last != nil
        }
        let signedProposal = try #require(
            try await voterATransport.controlEnvelopes()
                .compactMap(\.leadershipProposal)
                .last
        )
        let electionTime = try ClipLiveShareNativeTimestamp(date: Date())
        let reachable: Set = [
            fixture.localParticipantID,
            voterAID,
            voterBID,
        ]

        var voterA = try fixture.lifecycle(for: 2)
        var voterB = try fixture.lifecycle(for: 3)
        _ = try voterA.beginUnexpectedLeaderLoss(
            reachableParticipantIDs: reachable,
            at: electionTime
        )
        _ = try voterB.beginUnexpectedLeaderLoss(
            reachableParticipantIDs: reachable,
            at: electionTime
        )
        let voteA = try #require(
            meshLeadershipVote(
                in: voterA.receiveLeadershipProposal(
                    signedProposal,
                    at: electionTime
                )
            )
        )
        let voteB = try #require(
            meshLeadershipVote(
                in: voterB.receiveLeadershipProposal(
                    signedProposal,
                    at: electionTime
                )
            )
        )
        await voterATransport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .leadershipVote(voteA)
            )
        ))
        await voterBTransport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .leadershipVote(voteB)
            )
        ))

        try await meshCoordinatorEventually(timeout: .seconds(3)) {
            let snapshot = session.coordinator.presentationModel.snapshot
            return snapshot.currentLeaderParticipantID
                    == fixture.localParticipantID.rawValue
                && snapshot.remoteParticipants.count == 2
                && !snapshot.remoteParticipants.contains {
                    $0.id == crashedLeaderID.rawValue
                }
        }
        let committed = await session.coordinator.runtime.snapshot()
        #expect(
            committed.signedMembership.snapshot.participantIDs == reachable
        )
        #expect(
            try await crashedTransport.controlEnvelopes()
                .allSatisfy { envelope in
                    if case let .roomAuthority(chain) = envelope {
                        // Every newly ready link now receives the current
                        // full chain. The crashed peer may have received that
                        // initial synchronization, but never the newer
                        // succession commit.
                        return chain.currentTerm
                            == fixture.authority.currentTerm
                    }
                    return !envelope.isLeadershipSuccessionCommit
                }
        )

        session.coordinator.presentationModel.endRoomForEveryone()
        try await meshCoordinatorEventually {
            if case .ended = session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }
    }

    @Test(
        "an unrelated sender cannot erase a valid leadership transaction"
    )
    func unrelatedSenderCannotPoisonLeadershipAccumulator() async throws {
        let fixture = try MeshRuntimeFixture(
            participantCount: 4,
            localIndex: 2
        )
        let session = try fixture.makeCoordinator()
        session.coordinator.start()
        try await session.openAllPeerLinks()
        try await meshCoordinatorEventually {
            if case .live =
                session.coordinator.presentationModel.snapshot.phase {
                return true
            }
            return false
        }

        let transitionTime =
            try ClipLiveShareNativeTimestamp(date: Date())
        var leader = try fixture.lifecycle(for: 0)
        var successor = try fixture.lifecycle(for: 1)
        var observer = try fixture.lifecycle(for: 2)
        var unrelated = try fixture.lifecycle(for: 3)
        let transferRequest = try #require(
            meshTransferRequest(
                in: leader.beginGracefulLeaderLeave(
                    at: transitionTime
                )
            )
        )
        let successorEvents =
            try successor.receiveLeadershipTransferRequest(
                transferRequest,
                at: transitionTime
            )
        _ = try observer.receiveLeadershipTransferRequest(
            transferRequest,
            at: transitionTime
        )
        _ = try unrelated.receiveLeadershipTransferRequest(
            transferRequest,
            at: transitionTime
        )
        let proposal = try #require(
            meshLeadershipProposal(in: successorEvents)
        )
        let leaderVote = try #require(
            meshLeadershipVote(
                in: leader.receiveLeadershipProposal(
                    proposal,
                    at: transitionTime
                )
            )
        )
        let observerVote = try #require(
            meshLeadershipVote(
                in: observer.receiveLeadershipProposal(
                    proposal,
                    at: transitionTime
                )
            )
        )
        _ = try successor.receiveLeadershipVote(
            leaderVote,
            at: transitionTime
        )
        let certificate = try #require(
            meshLeadershipCertificate(
                in: successor.receiveLeadershipVote(
                    observerVote,
                    at: transitionTime
                )
            )
        )
        let retained: Set = [
            fixture.participants[1].participantID,
            fixture.localParticipantID,
        ]
        let membership = try successor.makeSuccessorMembership(
            for: certificate,
            retainingParticipantIDs: retained,
            at: transitionTime
        )
        _ = try successor.commitLeadershipTransition(
            certificate: certificate,
            successorMembership: membership,
            at: transitionTime
        )
        let authorityChain = successor.authorityChain

        let successorID = fixture.participants[1].participantID
        let unrelatedID = fixture.participants[3].participantID
        let successorTransport = try #require(
            await session.transportFactory.transport(for: successorID)
        )
        let unrelatedTransport = try #require(
            await session.transportFactory.transport(for: unrelatedID)
        )

        // The certified successor's first two fragments are valid. Replaying
        // that authority chain from another authenticated peer must quarantine
        // only the replaying peer, without clearing the successor's pending
        // transaction.
        await successorTransport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .leadershipCertificate(certificate)
            )
        ))
        await successorTransport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .roomAuthority(authorityChain)
            )
        ))
        try await Task.sleep(for: .milliseconds(30))
        await unrelatedTransport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .roomAuthority(authorityChain)
            )
        ))
        try await meshRuntimeEventually {
            await unrelatedTransport.closeCount() == 1
        }

        await successorTransport.emit(.controlMessageReceived(
            try ClipLiveShareNativeV3ControlCodec.encode(
                .membershipSnapshot(membership)
            )
        ))
        try await meshCoordinatorEventually {
            session.coordinator.presentationModel.snapshot
                .currentLeaderParticipantID == successorID.rawValue
        }
        let committed = await session.coordinator.runtime.snapshot()
        #expect(
            committed.signedMembership.snapshot.participantIDs
                == retained
        )
        #expect(session.coordinator.isActive)

        session.coordinator.cancelForApplicationStop()
        #expect(!session.coordinator.isActive)
    }
}

private extension ClipLiveShareNativeV3ControlEnvelope {
    var isSourceSnapshot: Bool {
        if case .sourceSnapshot = self { true } else { false }
    }

    var leadershipProposal:
        ClipLiveShareSignedNativeV3LeadershipProposal?
    {
        if case let .leadershipProposal(value) = self {
            return value
        }
        return nil
    }

    var isLeadershipSuccessionCommit: Bool {
        switch self {
        case .leadershipCertificate, .roomAuthority, .membershipSnapshot:
            true
        default:
            false
        }
    }
}

private struct MeshRuntimeFixture {
    struct Session {
        let runtime: MeshParticipantRuntime
        let manager: ClipLiveShareNativeV3MeshPeerLinkManager
        let factory: MeshRuntimeTransportFactory
        let bootstrap: MeshRuntimeBootstrap
    }

    @MainActor
    struct CoordinatorSession {
        let coordinator: MeshParticipantCoordinator
        let transportFactory: MeshRuntimeTransportFactory
        let bootstrap: MeshRuntimeBootstrap
        let peerIDs: [ClipLiveShareNativeV3ParticipantID]

        func openAllPeerLinks() async throws {
            try await meshRuntimeEventually {
                for peerID in peerIDs {
                    if await transportFactory.transport(for: peerID) == nil {
                        return false
                    }
                }
                return true
            }
            for peerID in peerIDs {
                let transport = try #require(
                    await transportFactory.transport(for: peerID)
                )
                await transport.emit(.connectionStateChanged(.connected))
                await transport.emit(.routeChanged(.direct))
                await transport.emit(.controlChannelStateChanged(.open))
            }
        }
    }

    let signers: [ClipLiveShareSoftwareIdentitySigner]
    let participants: [ClipLiveShareNativeV3Participant]
    let sessionID: ClipLiveShareSessionID
    let now: ClipLiveShareNativeTimestamp
    let initialMembership:
        ClipLiveShareSignedNativeV3MembershipSnapshot
    let authority: ClipLiveShareNativeV3RoomAuthorityChain
    let localIndex: Int
    let nonces:
        [ClipLiveShareNativeV3ParticipantID:
            ClipLiveShareNativeV3TransportNonce]
    let digests:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeDigest]

    init(
        participantCount: Int,
        localIndex: Int = 0,
        committedParticipantCount: Int? = nil
    ) throws {
        let committedParticipantCount =
            committedParticipantCount ?? participantCount
        precondition((1...participantCount).contains(
            committedParticipantCount
        ))
        precondition((0..<committedParticipantCount).contains(localIndex))
        self.localIndex = localIndex
        signers = (0..<participantCount).map { _ in
            ClipLiveShareSoftwareIdentitySigner()
        }
        participants = try signers.enumerated().map { index, signer in
            try .init(
                participantID: .init(
                    bytes: Data(
                        repeating: UInt8(index + 1),
                        count:
                            ClipLiveShareNativeV3.participantIDByteCount
                    )
                ),
                identity: signer.publicKey,
                displayName: "Participant \(index + 1)",
                capabilities: .current
            )
        }
        sessionID = try .init(rawValue: "mesh-runtime-tests")
        now = try ClipLiveShareNativeTimestamp(date: Date())
        initialMembership = try Self.makeMembership(
            sessionID: sessionID,
            participants: Array(
                participants.prefix(committedParticipantCount)
            ),
            leader: participants[0],
            signer: signers[0],
            revision: 1,
            now: now
        )
        authority = try .init(
            foundingCreatorParticipantID: participants[0].participantID,
            foundingCreatorIdentity: participants[0].identity,
            genesisMembership: initialMembership,
            checkpoints: []
        )
        let peerParticipants = participants
            .prefix(committedParticipantCount)
            .enumerated().filter {
                $0.offset != localIndex
            }
        nonces = try Dictionary(
            uniqueKeysWithValues: peerParticipants.enumerated().map {
                index,
                indexedParticipant in
                (
                    indexedParticipant.element.participantID,
                    try .init(
                        bytes: Data(
                            repeating: UInt8(0x80 + index),
                            count: 32
                        )
                    )
                )
            }
        )
        digests = Dictionary(
            uniqueKeysWithValues: peerParticipants.enumerated().map {
                index,
                indexedParticipant in
                (
                    indexedParticipant.element.participantID,
                    ClipLiveShareNativeDigest(
                        hashing: Data("admission-\(index)".utf8)
                    )
                )
            }
        )
    }

    var localParticipantID: ClipLiveShareNativeV3ParticipantID {
        participants[localIndex].participantID
    }

    var peerIDs: [ClipLiveShareNativeV3ParticipantID] {
        initialMembership.snapshot.participants
            .map(\.participantID)
            .filter { $0 != localParticipantID }
    }

    func makeRuntime(
        reconnectPolicy: ClipLiveShareReconnectPolicy =
            .boundedExponential
    ) async throws -> Session {
        let factory = MeshRuntimeTransportFactory()
        let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
            localParticipantID: localParticipantID,
            transportFactory: factory,
            reconnectPolicy: reconnectPolicy
        )
        let bootstrap = MeshRuntimeBootstrap()
        let runtime = MeshParticipantRuntime(
            context: .init(
                localParticipantID: localParticipantID,
                localIdentitySigner: signers[localIndex],
                signedMembership: initialMembership,
                authorityChain: authority,
                expectedFoundingCreatorIdentity: signers[0].publicKey,
                bootstrapAdmissionDigests: digests,
                verifiedPeerTransportNonces: nonces
            ),
            manager: manager,
            bootstrap: bootstrap
        )
        return Session(
            runtime: runtime,
            manager: manager,
            factory: factory,
            bootstrap: bootstrap
        )
    }

    @MainActor
    func makeCoordinator(
        leaderLossStabilityDuration: Duration = .seconds(2)
    ) throws -> CoordinatorSession {
        let transportFactory = MeshRuntimeTransportFactory()
        let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
            localParticipantID: localParticipantID,
            transportFactory: transportFactory
        )
        let bootstrap = MeshRuntimeBootstrap()
        let mediaFactory =
            try ClipLiveShareNativeV3WebRTCTransportFactory()
        let coordinator = try MeshParticipantCoordinator(
            context: launchContext,
            bootstrap: bootstrap,
            mediaFactory: mediaFactory,
            peerLinkManager: manager,
            localCaptureDiscovery: EmptyMeshCaptureDiscovery(),
            leaderLossStabilityDuration: leaderLossStabilityDuration,
            onSessionEnded: {}
        )
        return CoordinatorSession(
            coordinator: coordinator,
            transportFactory: transportFactory,
            bootstrap: bootstrap,
            peerIDs: peerIDs
        )
    }

    private var launchContext: MeshParticipantLaunchContext {
        .init(
            localParticipantID: localParticipantID,
            localIdentitySigner: signers[localIndex],
            signedMembership: initialMembership,
            authorityChain: authority,
            expectedFoundingCreatorIdentity: signers[0].publicKey,
            bootstrapAdmissionDigests: digests,
            verifiedPeerTransportNonces: nonces
        )
    }

    func lifecycle(
        for index: Int
    ) throws -> ClipLiveShareNativeV3RoomLifecycleCoordinator {
        let participant = participants[index]
        return try .init(
            localParticipantID: participant.participantID,
            localSigner: signers[index],
            authorityChain: authority,
            expectedSessionID: sessionID,
            expectedFoundingCreatorIdentity: participants[0].identity,
            establishedPeerParticipantIDs:
                initialMembership.snapshot.participantIDs
                .subtracting([participant.participantID]),
            at: now
        )
    }

    func membership(
        participantIDs: Set<ClipLiveShareNativeV3ParticipantID>,
        revision: UInt64
    ) throws -> ClipLiveShareSignedNativeV3MembershipSnapshot {
        try Self.makeMembership(
            sessionID: sessionID,
            participants: participants.filter {
                participantIDs.contains($0.participantID)
            },
            leader: participants[0],
            signer: signers[0],
            revision: revision,
            now: now
        )
    }

    func publishedSource(
        owner: ClipLiveShareNativeV3ParticipantID
    ) throws -> ClipLiveShareNativeV3PublishedSource {
        let sourceID = ClipLiveShareSourceInstanceID.random()
        let stream = try ClipLiveShareStreamDescriptor(
            id: .init(rawValue: "mesh-source"),
            mediaTrackID: .init(rawValue: "mesh-track"),
            active: true,
            focused: true,
            appName: "Fixture",
            windowName: "Fixture",
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

    func pointer(
        participantID: ClipLiveShareNativeV3ParticipantID,
        sourceKey: ClipLiveShareNativeV3SourceKey,
        sequence: UInt64,
        position: ClipLiveShareNativeV3NormalizedPoint?
    ) throws -> ClipLiveShareNativeV3CollaborationEvent {
        .pointer(
            .init(
                context: try collaborationContext(
                    participantID: participantID,
                    sourceKey: sourceKey,
                    sequence: sequence
                ),
                position: position
            )
        )
    }

    func collaborationContext(
        participantID: ClipLiveShareNativeV3ParticipantID,
        sourceKey: ClipLiveShareNativeV3SourceKey,
        sequence: UInt64
    ) throws -> ClipLiveShareNativeV3CollaborationContext {
        try .init(
            sessionID: sessionID,
            participantID: participantID,
            sourceKey: sourceKey,
            sequence: sequence,
            sentAt: ClipLiveShareNativeTimestamp(date: Date())
        )
    }

    func signedRenegotiationRequest(
        senderIndex: Int,
        receiverIndex: Int,
        revision: UInt64,
        codec: WebRTCVideoCodec
    ) throws -> ClipLiveShareSignedNativeV3PeerLinkRenegotiationRequest {
        let request =
            try ClipLiveShareNativeV3PeerLinkRenegotiationRequest(
                context: peerLinkContext(
                    senderIndex: senderIndex,
                    receiverIndex: receiverIndex,
                    revision: revision
                ),
                membershipDigest: initialMembership.snapshot.digest,
                preferredVideoCodec: codec.rawValue,
                issuedAt: now,
                expiresAt: now.adding(milliseconds: 60_000)
            )
        return try .init(
            signing: request,
            with: signers[senderIndex],
            membership: initialMembership
        )
    }

    func signedOffer(
        senderIndex: Int,
        receiverIndex: Int,
        revision: UInt64,
        sdp: String
    ) throws -> ClipLiveShareSignedNativeV3PeerLinkOffer {
        let sender = participants[senderIndex]
        let offer = try ClipLiveShareNativeV3PeerLinkOffer(
            context: peerLinkContext(
                senderIndex: senderIndex,
                receiverIndex: receiverIndex,
                revision: revision
            ),
            sdp: sdp
        )
        return try .init(
            signing: offer,
            with: signers[senderIndex],
            senderIdentity: sender.identity
        )
    }

    func signedBootstrapHello(
        participantIndex: Int
    ) throws -> ClipLiveShareSignedNativeV3BootstrapHello {
        let participant = participants[participantIndex]
        let proof = ClipLiveShareNativeV3RendezvousProof(
            sessionID: sessionID,
            rendezvousID: .random(),
            routeID: .random(),
            foundingCreatorIdentity: participants[0].identity,
            admissionCapability: .random()
        )
        let hello = try ClipLiveShareNativeV3BootstrapHello(
            sessionID: sessionID,
            participantID: participant.participantID,
            identity: participant.identity,
            displayName: participant.displayName,
            rendezvousProof: proof,
            issuedAt: now,
            expiresAt: now.adding(milliseconds: 30_000)
        )
        return try .init(
            signing: hello,
            with: signers[participantIndex]
        )
    }

    private func peerLinkContext(
        senderIndex: Int,
        receiverIndex: Int,
        revision: UInt64
    ) throws -> ClipLiveShareNativeV3PeerLinkContext {
        let sender = participants[senderIndex]
        let receiver = participants[receiverIndex]
        let remoteParticipantID =
            sender.participantID == localParticipantID
            ? receiver.participantID
            : sender.participantID
        let nonce = try nonces[remoteParticipantID]
            ?? ClipLiveShareNativeV3TransportNonce(
                bytes: Data(repeating: 0xF1, count: 32)
            )
        return try .init(
            sessionID: sessionID,
            membershipRevision:
                initialMembership.snapshot.membershipRevision,
            peerLinkKey: .init(
                sender.participantID,
                receiver.participantID
            ),
            negotiationRevision: .init(rawValue: revision),
            senderParticipantID: sender.participantID,
            receiverParticipantID: receiver.participantID,
            transportNonce: nonce
        )
    }

    private static func makeMembership(
        sessionID: ClipLiveShareSessionID,
        participants: [ClipLiveShareNativeV3Participant],
        leader: ClipLiveShareNativeV3Participant,
        signer: ClipLiveShareSoftwareIdentitySigner,
        revision: UInt64,
        now: ClipLiveShareNativeTimestamp
    ) throws -> ClipLiveShareSignedNativeV3MembershipSnapshot {
        let membershipRevision =
            try ClipLiveShareNativeV3MembershipRevision(
                rawValue: revision
            )
        let credentials = try participants.map { participant in
            try ClipLiveShareSignedNativeV3MembershipCredential(
                signing: .init(
                    sessionID: sessionID,
                    leaderParticipantID: leader.participantID,
                    leaderIdentity: leader.identity,
                    participant: participant,
                    membershipRevision: membershipRevision,
                    issuedAt: now,
                    expiresAt: now.adding(milliseconds: 180_000)
                ),
                with: signer
            )
        }
        let snapshot = try ClipLiveShareNativeV3MembershipSnapshot(
            sessionID: sessionID,
            leaderParticipantID: leader.participantID,
            leaderIdentity: leader.identity,
            membershipRevision: membershipRevision,
            credentials: credentials,
            issuedAt: now,
            expiresAt: now.adding(milliseconds: 120_000),
            maximumParticipants:
                ClipLiveShareNativeV3AdmissionPolicy.productDefault
                .maximumParticipants
        )
        return try .init(signing: snapshot, with: signer)
    }
}

private enum MeshRuntimeTransportError: Error {
    case sendFailed
}

private struct EmptyMeshCaptureDiscovery: CaptureContentDiscovering {
    func shareableContent(
        excludingBundleIdentifier _: String?
    ) async throws -> ShareableCaptureContent {
        .init(displays: [], windows: [])
    }
}

private actor MeshRuntimeTransportFactory:
    ClipLiveShareNativeV3PeerLinkTransportFactory
{
    private var transports:
        [ClipLiveShareNativeV3ParticipantID: MeshRuntimeTransport] = [:]
    private var transportHistory:
        [ClipLiveShareNativeV3ParticipantID: [MeshRuntimeTransport]] = [:]

    func makeTransport(
        configuration: ClipLiveShareNativeV3PeerLinkConfiguration
    ) -> any ClipLiveShareNativeV3PeerLinkTransport {
        let transport = MeshRuntimeTransport(
            configuration: configuration
        )
        transports[configuration.remoteParticipantID] = transport
        transportHistory[configuration.remoteParticipantID, default: []]
            .append(transport)
        return transport
    }

    func transport(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> MeshRuntimeTransport? {
        transports[participantID]
    }

    func totalControlMessageCount() async -> Int {
        var total = 0
        for transport in transports.values {
            total += await transport.controlMessageCount()
        }
        return total
    }

    func transportCreationCount(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> Int {
        transportHistory[participantID, default: []].count
    }
}

private actor MeshRuntimeTransport:
    ClipLiveShareNativeV3PeerLinkTransport
{
    nonisolated let configuration:
        ClipLiveShareNativeV3PeerLinkConfiguration
    private var continuation:
        AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent>.Continuation?
    private var sentControl: [Data] = []
    private var closes = 0
    private var failNextSend = false
    private var controlSendDelay: Duration?
    private var negotiationRequests = 0
    private var remoteDescriptions: [WebRTCSessionDescription] = []
    private var codecPreferences: [WebRTCVideoCodec] = []
    private var failNextCodecUpdate = false

    init(configuration: ClipLiveShareNativeV3PeerLinkConfiguration) {
        self.configuration = configuration
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
    func requestNegotiation() {
        negotiationRequests += 1
    }
    func applyRemoteDescription(
        _ description: WebRTCSessionDescription
    ) {
        remoteDescriptions.append(description)
    }
    func addRemoteICECandidate(_: WebRTCICECandidate) {}

    func sendControlMessage(_ data: Data) async throws {
        if let controlSendDelay {
            try await Task.sleep(for: controlSendDelay)
        }
        if failNextSend {
            failNextSend = false
            throw MeshRuntimeTransportError.sendFailed
        }
        sentControl.append(data)
    }

    func remoteVideoStream(
        for _: ClipLiveShareStreamDescriptor
    ) -> WebRTCRemoteVideoStream? {
        nil
    }

    func setRemoteParticipantAudioPlaybackEnabled(_: Bool) {}
    func setRemoteParticipantAudioVolume(_: Double) {}
    func updateVideoCodecPreference(
        _ codec: WebRTCVideoCodec
    ) throws {
        codecPreferences.append(codec)
        if failNextCodecUpdate {
            failNextCodecUpdate = false
            throw MeshRuntimeTransportError.sendFailed
        }
    }
    func restartICE() {}

    func statistics()
        -> ClipLiveShareNativeV3PeerLinkTransportStatistics
    {
        .init(capturedAt: Date())
    }

    func close() {
        closes += 1
        continuation?.finish()
        continuation = nil
    }

    func emit(_ event: ClipLiveShareNativeV3PeerLinkTransportEvent) {
        continuation?.yield(event)
    }

    func setControlSendDelay(_ delay: Duration?) {
        controlSendDelay = delay
    }

    func failNextControlSend() {
        failNextSend = true
    }

    func failNextVideoCodecUpdate() {
        failNextCodecUpdate = true
    }

    func controlMessageCount() -> Int { sentControl.count }
    func closeCount() -> Int { closes }
    func negotiationRequestCount() -> Int { negotiationRequests }
    func remoteDescriptionCount() -> Int { remoteDescriptions.count }
    func codecHistory() -> [WebRTCVideoCodec] { codecPreferences }

    func controlEnvelopes() throws
        -> [ClipLiveShareNativeV3ControlEnvelope]
    {
        try sentControl.map {
            try ClipLiveShareNativeV3ControlCodec.decode($0)
        }
    }
}

private actor MeshRuntimeEventRecorder {
    private var failures: [String] = []
    private var degradedParticipants:
        [ClipLiveShareNativeV3ParticipantID] = []
    private var bootstrapForwards:
        [ClipLiveShareNativeV3BootstrapForward] = []
    private var cursors: [ClipLiveShareNativeV3SourceCursor] = []
    private var remoteTrackEvents:
        [(ClipLiveShareNativeV3ParticipantID, Bool)] = []

    func record(_ event: MeshParticipantRuntimeEvent) {
        switch event {
        case let .failed(message):
            failures.append(message)
        case let .peerDegraded(participantID, _):
            degradedParticipants.append(participantID)
        case let .bootstrapForwardReceived(forward, _):
            bootstrapForwards.append(forward)
        case let .sourceCursorReceived(cursor, _):
            cursors.append(cursor)
        case let .remoteVideoTrackChanged(
            participantID,
            _,
            isAvailable
        ):
            remoteTrackEvents.append((participantID, isAvailable))
        default:
            break
        }
    }

    func failureCount() -> Int { failures.count }
    func degradedParticipantIDs()
        -> [ClipLiveShareNativeV3ParticipantID]
    {
        degradedParticipants
    }
    func bootstrapForwardCount() -> Int {
        bootstrapForwards.count
    }
    func sourceCursors() -> [ClipLiveShareNativeV3SourceCursor] {
        cursors
    }
    func remoteTrackEventCount(
        participantID: ClipLiveShareNativeV3ParticipantID,
        isAvailable: Bool
    ) -> Int {
        remoteTrackEvents.count {
            $0.0 == participantID && $0.1 == isAvailable
        }
    }
}

private actor MeshRuntimeBootstrap: MeshParticipantBootstrapRouting {
    private var continuation:
        AsyncStream<MeshParticipantBootstrapRouteEvent>.Continuation?
    private var sent:
        [(ClipLiveShareNativeV3BootstrapEnvelope,
          ClipLiveShareNativeV3ParticipantID)] = []

    func events() -> AsyncStream<MeshParticipantBootstrapRouteEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: MeshParticipantBootstrapRouteEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = continuation
        return stream
    }

    func send(
        _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) {
        sent.append((envelope, participantID))
    }

    func close() {
        continuation?.finish()
        continuation = nil
    }

    func sentCount() -> Int { sent.count }

    func emit(_ event: MeshParticipantBootstrapRouteEvent) {
        continuation?.yield(event)
    }
}

private func meshLeadershipVote(
    in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareSignedNativeV3LeadershipVote? {
    for event in events {
        if case let .broadcastLeadershipVote(vote) = event {
            return vote
        }
    }
    return nil
}

private func meshTransferRequest(
    in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareSignedNativeV3LeadershipTransferRequest? {
    for event in events {
        if case let .broadcastTransferRequest(request) = event {
            return request
        }
    }
    return nil
}

private func meshLeadershipProposal(
    in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareSignedNativeV3LeadershipProposal? {
    for event in events {
        if case let .broadcastLeadershipProposal(proposal) = event {
            return proposal
        }
    }
    return nil
}

private func meshLeadershipCertificate(
    in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareNativeV3LeadershipCertificate? {
    for event in events {
        if case let .leadershipCertificateReady(certificate) = event {
            return certificate
        }
    }
    return nil
}

@MainActor
private func meshCoordinatorEventually(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for mesh coordinator condition")
}

private func meshRuntimeEventually(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for mesh runtime condition")
}
