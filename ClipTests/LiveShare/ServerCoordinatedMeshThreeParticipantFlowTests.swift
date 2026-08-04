import AppKit
import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import Testing

@testable import Clip

/// Composes the app-owned v4 room session with the real media runtime, peer
/// manager, reconciler, room crypto and source-control codec. Only the bounded
/// room service and concrete WebRTC socket are replaced by deterministic
/// in-memory routers. This closes the gap between isolated room/runtime tests:
/// every participant runs its own complete stack and can fail independently.
@Suite("Server-coordinated three-participant flow")
struct ServerCoordinatedMeshThreeParticipantFlowTests {
    @Test("a viewer pointer reaches the publisher and every other participant")
    @MainActor
    func collaborationPointerTraversesTheCompleteMesh() async throws {
        let fixture = try ServerRoomComposedFixture(participantCount: 3)
        let clients = try await fixture.makeClients()
        let publisher = clients[0]
        let pointerAuthor = clients[1]
        let observer = clients[2]
        let overlayProbe = ServerRoomComposedSourceOverlayProbe()
        let publisherCoordinator =
            ServerCoordinatedMeshParticipantCoordinator(
                localParticipantID: publisher.participantID,
                localIdentity:
                    publisher.identityPublicKey.x963Representation,
                localDisplayName: "Publisher",
                session: .init(
                    events: { await publisher.session.events() },
                    snapshot: { await publisher.session.snapshot() },
                    // The composed fixture starts each room explicitly below;
                    // the coordinator still consumes the real room event
                    // stream, which is the production host-overlay path.
                    start: {},
                    rotateInvite: {
                        throw ServerRoomComposedError.invalidServerOperation
                    }
                ),
                localMedia: .init(),
                localSourceOverlays: overlayProbe
            )
        publisherCoordinator.start()

        for client in clients {
            try await client.session.start()
        }
        try await serverRoomComposedEventually("collaboration mesh ready") {
            await completeReadyMesh(clients)
        }
        try await publisher.session.publishLocalSources([publisher.source])
        try await serverRoomComposedEventually("publisher source synchronized") {
            for client in clients {
                guard await client.session.snapshot().media?.sourceSnapshots[
                    publisher.participantID
                ]?.sources == [publisher.source] else {
                    return false
                }
            }
            return true
        }

        let position = try ClipLiveShareNativeV3NormalizedPoint(
            x: 0.27,
            y: 0.63
        )
        let timestamp = try ClipLiveShareNativeTimestamp(date: Date())
        let visibleContext = try ClipLiveShareNativeV3CollaborationContext(
            sessionID: fixture.sessionID,
            participantID: pointerAuthor.participantID,
            sourceKey: publisher.source.key,
            sequence: 1,
            sentAt: timestamp
        )
        try await pointerAuthor.session.broadcastCollaboration(
            .pointer(.init(context: visibleContext, position: position))
        )

        try await serverRoomComposedEventually(
            "remote pointer at publisher and observer"
        ) {
            for client in [publisher, observer] {
                guard await client.session.snapshot().media?.collaboration[
                    publisher.source.key
                ]?.pointers[pointerAuthor.participantID]?.position == position
                else {
                    return false
                }
            }
            return true
        }
        try await serverRoomComposedEventually(
            "publisher overlay receives authenticated remote pointer"
        ) {
            await overlayProbe.hasVisiblePointer(
                participantID: pointerAuthor.participantID,
                position: position,
                sourceID: publisher.source.key.sourceInstanceID.rawValue
            )
        }

        let hiddenContext = try ClipLiveShareNativeV3CollaborationContext(
            sessionID: fixture.sessionID,
            participantID: pointerAuthor.participantID,
            sourceKey: publisher.source.key,
            sequence: 2,
            sentAt: timestamp
        )
        try await pointerAuthor.session.broadcastCollaboration(
            .pointer(.init(context: hiddenContext, position: nil))
        )
        try await serverRoomComposedEventually(
            "remote pointer hide at publisher and observer"
        ) {
            for client in clients {
                guard await client.session.snapshot().media?.collaboration[
                    publisher.source.key
                ]?.pointers[pointerAuthor.participantID] == nil else {
                    return false
                }
            }
            return true
        }
        try await serverRoomComposedEventually(
            "publisher overlay hides the remote pointer"
        ) {
            await overlayProbe.isHidden(
                sourceID: publisher.source.key.sourceInstanceID.rawValue
            )
        }

        await publisherCoordinator.close()
        await pointerAuthor.session.leave()
        await publisher.session.leave()
    }

    @Test("three clients form a complete source mesh and retain healthy pairs")
    func completeThreeParticipantFlow() async throws {
        let fixture = try ServerRoomComposedFixture(participantCount: 3)
        let clients = try await fixture.makeClients()
        let creator = clients[0]
        let originalInvite = try #require(
            await creator.session.snapshot().invite?.url
        )

        for (index, client) in clients.enumerated() {
            try await client.session.start()
            let expectedMemberCount = index + 1
            try await serverRoomComposedEventually(
                "\(expectedMemberCount) admitted participants"
            ) {
                for activeClient in clients.prefix(expectedMemberCount) {
                    let snapshot = await activeClient.session.snapshot()
                    guard snapshot.phase == .active,
                          snapshot.room.members.count == expectedMemberCount,
                          snapshot.media?.links.links.count
                            == expectedMemberCount - 1 else {
                        return false
                    }
                }
                return true
            }
            #expect(
                try await creator.session.snapshot().invite?.url
                    == originalInvite
            )
        }

        let participantIDs = Set(clients.map(\.participantID))
        for client in clients {
            try await client.session.publishLocalSources([client.source])
        }
        try await serverRoomComposedEventually(
            "every source manifest at every participant"
        ) {
            for client in clients {
                guard let media = await client.session.snapshot().media,
                      Set(media.sourceSnapshots.keys) == participantIDs else {
                    return false
                }
                for owner in clients {
                    guard media.sourceSnapshots[owner.participantID]?.sources
                            == [owner.source] else {
                        return false
                    }
                }
            }
            return true
        }

        let originalABAtA = try #require(
            await clients[0].peerFactory.transport(
                for: clients[1].participantID
            )
        )
        let originalABAtB = try #require(
            await clients[1].peerFactory.transport(
                for: clients[0].participantID
            )
        )

        // A signaling reconnect is service-plane state only. The direct mesh,
        // source manifests and concrete A-B transports remain unchanged.
        await fixture.roomHub.simulateReconnect(endpointID: clients[1].index)
        try await serverRoomComposedEventually("participant B reconnect") {
            let snapshot = await clients[1].session.snapshot()
            guard snapshot.phase == .active, let media = snapshot.media else {
                return false
            }
            return media.links.links.count == 2
                && Set(media.sourceSnapshots.keys) == participantIDs
        }
        #expect(
            await clients[0].peerFactory.transport(
                for: clients[1].participantID
            ) === originalABAtA
        )
        #expect(
            await clients[1].peerFactory.transport(
                for: clients[0].participantID
            ) === originalABAtB
        )

        // C leaving removes only A-C and B-C. The retained A-B edge and both
        // surviving source manifests stay usable.
        await clients[2].session.leave()
        try await serverRoomComposedEventually("participant C leave") {
            for client in clients.prefix(2) {
                let snapshot = await client.session.snapshot()
                guard snapshot.phase == .active,
                      snapshot.room.members.count == 2,
                      let media = snapshot.media,
                      media.links.links.count == 1,
                      Set(media.sourceSnapshots.keys)
                        == Set(clients.prefix(2).map(\.participantID)) else {
                    return false
                }
            }
            return true
        }
        #expect(
            await clients[0].peerFactory.transport(
                for: clients[1].participantID
            ) === originalABAtA
        )
        #expect(
            await clients[1].peerFactory.transport(
                for: clients[0].participantID
            ) === originalABAtB
        )

        // Clean-slate v4 deliberately has no election. Creator departure is
        // one terminal server fanout, not a leaderless or choosing state.
        await creator.session.leave()
        try await serverRoomComposedEventually("creator departure") {
            if case .ended = await clients[1].session.snapshot().phase {
                return await fixture.roomHub.isEnded()
            }
            return false
        }
        #expect(await fixture.roomHub.creatorDepartureCount() == 1)
    }

    @Test(
        "same identity rejoins the byte-stable invite and restores every pair and source"
    )
    func sameIdentityRejoinsStableInviteAndRestoresCompleteMesh()
        async throws
    {
        let fixture = try ServerRoomComposedFixture(participantCount: 3)
        let initialClients = try await fixture.makeClients()
        let creator = initialClients[0]
        let retainedMember = initialClients[1]
        let departingMember = initialClients[2]

        for client in initialClients {
            try await client.session.start()
        }
        try await serverRoomComposedEventually("initial three-member mesh") {
            await completeReadyMesh(initialClients)
        }

        let stableInvite = try #require(
            await creator.session.snapshot().invite
        )
        let stableInviteURL = try stableInvite.url
        let stableInviteString = stableInviteURL.absoluteString
        let departedHandle = try #require(
            await departingMember.session.snapshot().room.localHandle
        )

        for client in initialClients {
            try await client.session.publishLocalSources([client.source])
        }
        try await serverRoomComposedEventually(
            "initial source manifests and window descriptors"
        ) {
            await completeSourceMesh(
                initialClients,
                expectedSources: Dictionary(
                    uniqueKeysWithValues: initialClients.map {
                        ($0.participantID, $0.source)
                    }
                )
            )
        }

        let originalABAtA = try #require(
            await creator.peerFactory.transport(
                for: retainedMember.participantID
            )
        )
        let originalABAtB = try #require(
            await retainedMember.peerFactory.transport(
                for: creator.participantID
            )
        )
        let originalACAtA = try #require(
            await creator.peerFactory.transport(
                for: departingMember.participantID
            )
        )
        let originalACAtC = try #require(
            await departingMember.peerFactory.transport(
                for: creator.participantID
            )
        )
        let originalBCAtB = try #require(
            await retainedMember.peerFactory.transport(
                for: departingMember.participantID
            )
        )
        let originalBCAtC = try #require(
            await departingMember.peerFactory.transport(
                for: retainedMember.participantID
            )
        )

        // Reproduce the reported WebRTC failure at the exact boundary where
        // a structurally invalid answer/offer is applied. Only C's A-C peer
        // transport fails; A-B and B-C must remain allocated and usable.
        await originalACAtC.failNextRemoteDescriptionWithRTCPMuxError()
        try await originalACAtA.requestNegotiation()
        try await serverRoomComposedEventually(
            "pair-local structural SDP recreation"
        ) {
            guard await completeReadyMesh(initialClients),
                  let replacement = await departingMember.peerFactory
                    .transport(for: creator.participantID) else {
                return false
            }
            return replacement !== originalACAtC
        }
        let recoveredACAtC = try #require(
            await departingMember.peerFactory.transport(
                for: creator.participantID
            )
        )
        #expect(recoveredACAtC !== originalACAtC)
        #expect(
            await creator.peerFactory.transport(
                for: departingMember.participantID
            ) === originalACAtA
        )
        #expect(
            await creator.peerFactory.transport(
                for: retainedMember.participantID
            ) === originalABAtA
        )
        #expect(
            await retainedMember.peerFactory.transport(
                for: creator.participantID
            ) === originalABAtB
        )
        #expect(
            await retainedMember.peerFactory.transport(
                for: departingMember.participantID
            ) === originalBCAtB
        )
        #expect(
            await departingMember.peerFactory.transport(
                for: retainedMember.participantID
            ) === originalBCAtC
        )
        #expect(
            try await creator.session.snapshot().invite?.url.absoluteString
                == stableInviteString
        )

        // Give the departing pair unmistakable statistics. Their complete
        // removal is asserted before and after the same identity rejoins.
        await originalACAtA.emit(.statisticsChanged(.init(
            capturedAt: Date(timeIntervalSince1970: 100),
            route: .direct,
            currentRoundTripTimeMilliseconds: 91,
            availableOutgoingBitrateBps: 9_100_000,
            bytesSent: 91_001,
            bytesReceived: 91_002,
            packetsLost: 91
        )))
        try await serverRoomComposedEventually("departing pair statistics") {
            await creator.session.snapshot().media?.statistics[
                departingMember.participantID
            ]?.transport.bytesReceived == 91_002
        }

        await departingMember.session.leave()
        try await serverRoomComposedEventually(
            "departed sources, statistics and incident pairs removed"
        ) {
            for client in [creator, retainedMember] {
                let snapshot = await client.session.snapshot()
                guard snapshot.phase == .active,
                      snapshot.room.members.count == 2,
                      let media = snapshot.media,
                      media.links.links.count == 1,
                      media.links.links.allSatisfy(\.isReady),
                      media.sourceSnapshots[departingMember.participantID]
                        == nil,
                      media.statistics[departingMember.participantID] == nil
                else { return false }
            }
            return true
        }
        #expect(
            await creator.peerFactory.transport(
                for: retainedMember.participantID
            ) === originalABAtA
        )
        #expect(
            await retainedMember.peerFactory.transport(
                for: creator.participantID
            ) === originalABAtB
        )

        // Reparse the exact same URL. The persistent signing identity stays
        // unchanged, while a fresh participant ID, pair key and member handle
        // create a genuinely new room incarnation with source revision 1.
        let rejoinedMember = try await fixture.makeRejoiningClient(
            materialIndex: 2,
            endpointID: 3,
            inviteURL: stableInviteURL
        )
        #expect(rejoinedMember.participantID != departingMember.participantID)
        #expect(
            rejoinedMember.identityPublicKey
                == departingMember.identityPublicKey
        )
        #expect(
            rejoinedMember.pairSignalingPublicKey
                != departingMember.pairSignalingPublicKey
        )
        #expect(rejoinedMember.source != departingMember.source)

        try await rejoinedMember.session.start()
        try await serverRoomComposedEventually("fresh rejoined incarnation") {
            let snapshot = await rejoinedMember.session.snapshot()
            let currentInviteURL = try? snapshot.invite?.url
            return snapshot.phase == .active
                && snapshot.room.members.count == 3
                && snapshot.room.localHandle != departedHandle
                && currentInviteURL == stableInviteURL
        }
        // Old room-scoped identity and statistics must not come back merely
        // because the same persistent signing identity rejoins.
        #expect(
            await creator.session.snapshot().media?.statistics[
                departingMember.participantID
            ] == nil
        )

        try await rejoinedMember.session.publishLocalSources([
            rejoinedMember.source
        ])
        let recoveredClients = [creator, retainedMember, rejoinedMember]
        let recoveredSources = Dictionary(
            uniqueKeysWithValues: [
                (creator.participantID, creator.source),
                (retainedMember.participantID, retainedMember.source),
                (rejoinedMember.participantID, rejoinedMember.source),
            ]
        )
        try await serverRoomComposedEventually(
            "all pair edges, manifests and windows after rejoin"
        ) {
            guard await completeReadyMesh(recoveredClients) else {
                return false
            }
            return await completeSourceMesh(
                recoveredClients,
                expectedSources: recoveredSources
            )
        }

        #expect(
            await creator.peerFactory.transport(
                for: retainedMember.participantID
            ) === originalABAtA
        )
        #expect(
            await retainedMember.peerFactory.transport(
                for: creator.participantID
            ) === originalABAtB
        )
        #expect(
            await creator.peerFactory.transport(
                for: rejoinedMember.participantID
            ) !== originalACAtA
        )
        #expect(
            await retainedMember.peerFactory.transport(
                for: rejoinedMember.participantID
            ) !== originalBCAtB
        )
        #expect(
            try await creator.session.snapshot().invite?.url.absoluteString
                == stableInviteString
        )
        #expect(
            try await rejoinedMember.session.snapshot().invite?.url
                .absoluteString == stableInviteString
        )

        let freshACAtA = try #require(
            await creator.peerFactory.transport(
                for: rejoinedMember.participantID
            )
        )
        await freshACAtA.emit(.statisticsChanged(.init(
            capturedAt: Date(timeIntervalSince1970: 200),
            route: .direct,
            currentRoundTripTimeMilliseconds: 12,
            availableOutgoingBitrateBps: 20_000_000,
            bytesSent: 20_001,
            bytesReceived: 20_002,
            packetsLost: 0
        )))
        try await serverRoomComposedEventually("fresh rejoined statistics") {
            await creator.session.snapshot().media?.statistics[
                rejoinedMember.participantID
            ]?.transport.bytesReceived == 20_002
        }
        #expect(
            await creator.session.snapshot().media?.statistics[
                rejoinedMember.participantID
            ]?.transport.bytesReceived != 91_002
        )

        await rejoinedMember.session.leave()
        await creator.session.leave()
    }

    @Test(
        "three-client presentation retains transient windows and restores every remote window after rejoin"
    )
    @MainActor
    func presentationRetainsAndRestoresEveryRemoteWindowAfterRejoin()
        async throws
    {
        let fixture = try ServerRoomComposedFixture(participantCount: 3)
        let initialClients = try await fixture.makeClients()
        let creator = initialClients[0]
        let retainedMember = initialClients[1]
        let departingMember = initialClients[2]

        for client in initialClients {
            try await client.session.start()
        }
        try await serverRoomComposedEventually("initial presentation mesh") {
            await completeReadyMesh(initialClients)
        }
        let stableInvite = try #require(
            await creator.session.snapshot().invite
        )

        for client in initialClients {
            try await client.session.publishLocalSources([client.source])
        }
        try await serverRoomComposedEventually(
            "initial presentation source manifests"
        ) {
            await completeSourceMesh(
                initialClients,
                expectedSources: Dictionary(
                    uniqueKeysWithValues: initialClients.map {
                        ($0.participantID, $0.source)
                    }
                )
            )
        }

        var presentations = initialClients.map {
            ServerRoomComposedWindowPresentation(
                localParticipantID: $0.participantID
            )
        }
        defer {
            for presentation in presentations {
                presentation.tearDown()
            }
        }

        for (index, client) in initialClients.enumerated() {
            try presentations[index].reconcile(
                await client.session.snapshot()
            )
        }
        expectCompleteWindowPresentation(
            presentations,
            clients: initialClients
        )

        let creatorPresentation = presentations[0]
        let retainedProbe = try #require(
            creatorPresentation.probe(for: retainedMember.participantID)
        )
        let departingProbe = try #require(
            creatorPresentation.probe(for: departingMember.participantID)
        )
        #expect(retainedProbe.boundSourceIDs.count == 1)
        #expect(departingProbe.boundSourceIDs.count == 1)

        // A pair-local SDP/ICE recreation removes its remote track before the
        // replacement arrives, while the creator-verified source manifest is
        // still authoritative. Drive that exact ordering through the same
        // RemoteParticipantPresentation -> NativeViewerWindowCoordinator path
        // used by the app. The native window and its local presentation must be
        // retained without rebinding a missing track or tearing its surface down.
        let creatorSnapshot = await creator.session.snapshot()
        try creatorPresentation.reconcile(
            creatorSnapshot,
            unavailableRemoteParticipantIDs: [departingMember.participantID]
        )
        #expect(creatorPresentation.windowCount == 2)
        #expect(
            creatorPresentation.windowSnapshots(
                for: departingMember.participantID
            ).first?.source.isConnected == false
        )
        #expect(departingProbe.boundSourceIDs.count == 1)
        #expect(departingProbe.tearDownCount == 0)
        #expect(retainedProbe.tearDownCount == 0)

        try creatorPresentation.reconcile(creatorSnapshot)
        #expect(creatorPresentation.windowCount == 2)
        #expect(
            creatorPresentation.windowSnapshots(
                for: departingMember.participantID
            ).first?.source.isConnected == true
        )
        #expect(departingProbe.boundSourceIDs.count == 2)
        #expect(departingProbe.tearDownCount == 0)

        await departingMember.session.leave()
        try await serverRoomComposedEventually(
            "departing presentation member removed"
        ) {
            for client in [creator, retainedMember] {
                let snapshot = await client.session.snapshot()
                guard snapshot.phase == .active,
                      snapshot.room.members.count == 2,
                      snapshot.media?.sourceSnapshots[
                        departingMember.participantID
                      ] == nil else {
                    return false
                }
            }
            return true
        }
        for index in 0..<2 {
            try presentations[index].reconcile(
                await initialClients[index].session.snapshot()
            )
        }
        #expect(presentations[0].windowCount == 1)
        #expect(presentations[1].windowCount == 1)
        #expect(departingProbe.tearDownCount == 1)
        #expect(retainedProbe.tearDownCount == 0)

        let rejoinedMember = try await fixture.makeRejoiningClient(
            materialIndex: 2,
            endpointID: 3,
            inviteURL: stableInvite.url
        )
        try await rejoinedMember.session.start()
        try await serverRoomComposedEventually(
            "fresh presentation member rejoined"
        ) {
            let snapshot = await rejoinedMember.session.snapshot()
            return snapshot.phase == .active
                && snapshot.room.members.count == 3
                && snapshot.media?.links.links.count == 2
        }
        try await rejoinedMember.session.publishLocalSources([
            rejoinedMember.source
        ])
        let recoveredClients = [creator, retainedMember, rejoinedMember]
        try await serverRoomComposedEventually(
            "rejoined presentation source manifests"
        ) {
            guard await completeReadyMesh(recoveredClients) else {
                return false
            }
            return await completeSourceMesh(
                recoveredClients,
                expectedSources: Dictionary(
                    uniqueKeysWithValues: recoveredClients.map {
                        ($0.participantID, $0.source)
                    }
                )
            )
        }

        let rejoinedPresentation = ServerRoomComposedWindowPresentation(
            localParticipantID: rejoinedMember.participantID
        )
        presentations[2].tearDown()
        presentations[2] = rejoinedPresentation
        for (index, client) in recoveredClients.enumerated() {
            try presentations[index].reconcile(
                await client.session.snapshot()
            )
        }

        expectCompleteWindowPresentation(
            presentations,
            clients: recoveredClients
        )
        #expect(retainedProbe.tearDownCount == 0)
        #expect(
            presentations[0].probe(for: rejoinedMember.participantID)?
                .boundSourceIDs == [
                    rejoinedMember.source.key.sourceInstanceID.rawValue
                ]
        )

        await rejoinedMember.session.leave()
        await creator.session.leave()
    }
}

private struct ServerRoomComposedClient: Sendable {
    let index: Int
    let participantID: ClipLiveShareNativeV3ParticipantID
    let identityPublicKey: ClipLiveShareIdentityPublicKey
    let pairSignalingPublicKey: ClipLiveShareKeyAgreementPublicKey
    let session: ServerCoordinatedMeshRoomSession
    let peerFactory: ServerRoomComposedPeerFactory
    let source: ClipLiveShareNativeV3PublishedSource
}

@MainActor
private final class ServerRoomComposedSourceOverlayProbe:
    ServerCoordinatedMeshParticipantSourceOverlayCoordinating
{
    private struct SnapshotUpdate {
        let sourceID: String
        let snapshot: NativeViewerCollaborationOverlaySnapshot
        let isVisible: Bool
    }

    private var snapshotUpdates: [SnapshotUpdate] = []

    func update(
        sourceID _: String,
        sourceFrame _: CGRect,
        target _: LiveShareCollaborationSourceOverlayTarget,
        snapshot _: NativeViewerCollaborationOverlaySnapshot,
        isVisible _: Bool
    ) {}

    func updateSnapshot(
        sourceID: String,
        snapshot: NativeViewerCollaborationOverlaySnapshot,
        isVisible: Bool
    ) {
        snapshotUpdates.append(.init(
            sourceID: sourceID,
            snapshot: snapshot,
            isVisible: isVisible
        ))
    }

    func remove(sourceID _: String) {}
    func retainSources(_: Set<String>) {}
    func tearDown() {}

    func hasVisiblePointer(
        participantID: ClipLiveShareNativeV3ParticipantID,
        position: ClipLiveShareNativeV3NormalizedPoint,
        sourceID: String
    ) -> Bool {
        guard let update = snapshotUpdates.last else { return false }
        return update.sourceID == sourceID
            && update.isVisible
            && update.snapshot.pointers.contains {
                $0.participantID == participantID && $0.position == position
            }
    }

    func isHidden(sourceID: String) -> Bool {
        guard let update = snapshotUpdates.last else { return false }
        return update.sourceID == sourceID
            && !update.isVisible
            && update.snapshot == .empty
    }
}

private struct ServerRoomComposedMaterial: Sendable {
    let signer: ClipLiveShareSoftwareIdentitySigner
    let pairIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity
    let descriptor: ClipLiveShareServerRoomV4MemberDescriptor
}

private final class ServerRoomComposedFixture: @unchecked Sendable {
    let endpoint = URL(string: "https://composed-room.example.test")!
    let roomID: ClipLiveShareServerRoomV4RoomID
    let sessionID: ClipLiveShareSessionID
    let ownerCapability: ClipLiveShareServerRoomV4OwnerCapability
    let creatorHandle: ClipLiveShareServerRoomV4MemberHandle
    let capabilities: ClipLiveShareServerRoomV4Capabilities
    let materials: [ServerRoomComposedMaterial]
    let roomHub: ServerRoomComposedService
    let peerHub = ServerRoomComposedPeerHub()

    init(participantCount: Int) throws {
        precondition((2...4).contains(participantCount))
        roomID = try .init(bytes: Data(repeating: 0xD1, count: 32))
        sessionID = try .init(rawValue: "composed-three-participant-flow")
        ownerCapability = try .init(
            bytes: Data(repeating: 0xD2, count: 32)
        )
        creatorHandle = try .init(
            bytes: Data(repeating: 0xD3, count: 16)
        )
        capabilities = try .init(
            serverVersion: "composed-test",
            maximumRooms: 1,
            iceServers: []
        )
        materials = try (0..<participantCount).map { index in
            let signer = try ClipLiveShareSoftwareIdentitySigner(
                rawRepresentation: Data(
                    repeating: UInt8(index + 1),
                    count: 32
                )
            )
            let pairIdentity = ClipLiveShareServerRoomV4KeyAgreementIdentity()
            let participantID = try ClipLiveShareNativeV3ParticipantID(
                bytes: Data(repeating: UInt8(0x40 + index), count: 16)
            )
            return try .init(
                signer: signer,
                pairIdentity: pairIdentity,
                descriptor: .init(
                    participantID: participantID,
                    identity: signer.publicKey,
                    pairSignalingPublicKey: pairIdentity.publicKey,
                    displayName: "Participant \(index + 1)",
                    deviceName: "Composed Test Mac \(index + 1)"
                )
            )
        }
        roomHub = ServerRoomComposedService(
            roomID: roomID,
            creatorHandle: creatorHandle
        )
    }

    func makeClients() async throws -> [ServerRoomComposedClient] {
        let creatorBootstrap = try ClipLiveShareServerRoomV4ClientRoom
            .makeCreator(
                serviceEndpoint: endpoint,
                roomID: roomID,
                memberHandle: creatorHandle,
                sessionID: sessionID,
                ownerCapability: ownerCapability,
                roomAgreementSecret: try .init(
                    bytes: Data(repeating: 0xD4, count: 32)
                ),
                admissionCapability: try .init(
                    bytes: Data(repeating: 0xD5, count: 32)
                ),
                pairKeyIdentity: materials[0].pairIdentity,
                localDescriptor: materials[0].descriptor,
                signer: materials[0].signer,
                admissionPolicy: .open()
            )
        var bootstraps: [ServerCoordinatedMeshRoomSessionBootstrap] = [
            .init(creatorBootstrap)
        ]
        for material in materials.dropFirst() {
            let bootstrap = try ClipLiveShareServerRoomV4ClientRoom
                .makeCandidate(
                    invite: creatorBootstrap.invite,
                    pairKeyIdentity: material.pairIdentity,
                    localDescriptor: material.descriptor,
                    signer: material.signer
                )
            bootstraps.append(.init(
                bootstrap,
                invite: creatorBootstrap.invite
            ))
        }

        var clients: [ServerRoomComposedClient] = []
        for index in materials.indices {
            let endpoint = ServerRoomComposedEndpoint(
                id: index,
                service: roomHub
            )
            await roomHub.register(endpoint)
            let peerFactory = ServerRoomComposedPeerFactory(
                localParticipantID: materials[index].descriptor.participantID,
                hub: peerHub
            )
            let localParticipantID = materials[index].descriptor.participantID
            let session = ServerCoordinatedMeshRoomSession(
                bootstrap: bootstraps[index],
                controlPlane: .init(
                    discover: { [capabilities] _ in capabilities },
                    create: { [roomHub] _, request, _ in
                        try await roomHub.create(request)
                    }
                ),
                transport: endpoint.client(),
                mediaFactory: { _, sendPairSignal in
                    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
                        localParticipantID: localParticipantID,
                        transportFactory: peerFactory
                    )
                    let reconciler = ClipLiveShareServerMeshPeerReconciler(
                        localParticipantID: localParticipantID,
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
            )
            clients.append(.init(
                index: index,
                participantID: localParticipantID,
                identityPublicKey: materials[index].descriptor.identity,
                pairSignalingPublicKey:
                    materials[index].descriptor.pairSignalingPublicKey,
                session: session,
                peerFactory: peerFactory,
                source: try source(owner: localParticipantID, index: index)
            ))
        }
        return clients
    }

    func makeRejoiningClient(
        materialIndex: Int,
        endpointID: Int,
        inviteURL: URL
    ) async throws -> ServerRoomComposedClient {
        let persistent = materials[materialIndex]
        let pairIdentity = ClipLiveShareServerRoomV4KeyAgreementIdentity()
        let descriptor = try ClipLiveShareServerRoomV4MemberDescriptor(
            participantID: try .init(
                bytes: Data(
                    repeating: UInt8(0x70 + materialIndex),
                    count: 16
                )
            ),
            identity: persistent.signer.publicKey,
            pairSignalingPublicKey: pairIdentity.publicKey,
            displayName: persistent.descriptor.displayName,
            deviceName: persistent.descriptor.deviceName
        )
        let invite = try ClipLiveShareServerRoomV4Invite(url: inviteURL)
        let bootstrap = try ClipLiveShareServerRoomV4ClientRoom.makeCandidate(
            invite: invite,
            pairKeyIdentity: pairIdentity,
            localDescriptor: descriptor,
            signer: persistent.signer
        )
        let endpoint = ServerRoomComposedEndpoint(
            id: endpointID,
            service: roomHub
        )
        await roomHub.register(endpoint)
        let peerFactory = ServerRoomComposedPeerFactory(
            localParticipantID: descriptor.participantID,
            hub: peerHub
        )
        let localParticipantID = descriptor.participantID
        let session = ServerCoordinatedMeshRoomSession(
            bootstrap: .init(bootstrap, invite: invite),
            controlPlane: .init(
                discover: { [capabilities] _ in capabilities },
                create: { _, _, _ in
                    throw ServerRoomComposedError.invalidServerOperation
                }
            ),
            transport: endpoint.client(),
            mediaFactory: { _, sendPairSignal in
                let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
                    localParticipantID: localParticipantID,
                    transportFactory: peerFactory
                )
                let reconciler = ClipLiveShareServerMeshPeerReconciler(
                    localParticipantID: localParticipantID,
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
        )
        return .init(
            index: endpointID,
            participantID: localParticipantID,
            identityPublicKey: descriptor.identity,
            pairSignalingPublicKey: descriptor.pairSignalingPublicKey,
            session: session,
            peerFactory: peerFactory,
            source: try source(
                owner: localParticipantID,
                index: materialIndex,
                incarnation: "rejoined"
            )
        )
    }

    private func source(
        owner: ClipLiveShareNativeV3ParticipantID,
        index: Int,
        incarnation: String? = nil
    ) throws -> ClipLiveShareNativeV3PublishedSource {
        let instance = ClipLiveShareSourceInstanceID.random()
        let suffix = incarnation.map { "-\($0)" } ?? ""
        return try .init(
            key: .init(
                ownerParticipantID: owner,
                sourceInstanceID: instance
            ),
            descriptor: .init(
                sourceInstanceID: instance,
                stream: .init(
                    id: .init(
                        rawValue: "composed-stream-\(index)\(suffix)"
                    ),
                    mediaTrackID: .init(
                        rawValue: "composed-track-\(index)\(suffix)"
                    ),
                    active: true,
                    focused: index == 0,
                    appName: "Fixture \(index + 1)",
                    windowName: incarnation == nil
                        ? "Window \(index + 1)"
                        : "Window \(index + 1) Rejoined",
                    width: 800 + index,
                    height: 450 + index,
                    order: index,
                    sourcePointWidth: 800 + index,
                    sourcePointHeight: 450 + index
                )
            )
        )
    }
}

private actor ServerRoomComposedEndpoint {
    nonisolated let id: Int
    private let service: ServerRoomComposedService
    private var continuation:
        AsyncStream<ClipLiveShareServerRoomV4TransportEvent>.Continuation?
    private var buffered: [ClipLiveShareServerRoomV4TransportEvent] = []

    init(id: Int, service: ServerRoomComposedService) {
        self.id = id
        self.service = service
    }

    nonisolated func client() -> ServerCoordinatedMeshRoomTransportClient {
        .init(
            events: { await self.events() },
            connect: { target, capabilities, authentication in
                try await self.service.connect(
                    endpointID: self.id,
                    target: target,
                    capabilities: capabilities,
                    authentication: authentication
                )
            },
            sendJoinKnock: { sequence, payload in
                try await self.service.sendJoinKnock(
                    from: self.id,
                    sequence: sequence,
                    payload: payload
                )
            },
            admitCandidate: { handle, descriptor in
                try await self.service.admit(
                    from: self.id,
                    handle: handle,
                    descriptor: descriptor
                )
            },
            denyCandidate: { handle, reason in
                await self.service.deny(
                    from: self.id,
                    handle: handle,
                    reason: reason
                )
            },
            sendPairSignal: { envelope in
                try await self.service.routePairSignal(
                    from: self.id,
                    envelope: envelope
                )
            },
            removeMember: { handle in
                try await self.service.removeMember(
                    from: self.id,
                    handle: handle
                )
            },
            leave: { await self.service.leave(endpointID: self.id) },
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

    private func events()
        -> AsyncStream<ClipLiveShareServerRoomV4TransportEvent>
    {
        let pair = AsyncStream.makeStream(
            of: ClipLiveShareServerRoomV4TransportEvent.self,
            bufferingPolicy: .bufferingOldest(256)
        )
        continuation = pair.continuation
        for event in buffered {
            pair.continuation.yield(event)
        }
        buffered.removeAll(keepingCapacity: false)
        return pair.stream
    }

    private func finish() {
        continuation?.finish()
        continuation = nil
    }
}

private actor ServerRoomComposedService {
    private struct ClientState {
        let endpoint: ServerRoomComposedEndpoint
        var role: ClipLiveShareServerRoomV4SessionRole?
        var candidateHandle: ClipLiveShareServerRoomV4CandidateHandle?
        var memberHandle: ClipLiveShareServerRoomV4MemberHandle?
    }

    private let roomID: ClipLiveShareServerRoomV4RoomID
    private let creatorHandle: ClipLiveShareServerRoomV4MemberHandle
    private var clients: [Int: ClientState] = [:]
    private var records:
        [ClipLiveShareServerRoomV4MemberHandle:
            ClipLiveShareServerRoomV4OpaqueAdmissionRecord] = [:]
    private var revisionRaw: UInt64 = 0
    private var ended = false
    private var creatorLeaves = 0

    init(
        roomID: ClipLiveShareServerRoomV4RoomID,
        creatorHandle: ClipLiveShareServerRoomV4MemberHandle
    ) {
        self.roomID = roomID
        self.creatorHandle = creatorHandle
    }

    func register(_ endpoint: ServerRoomComposedEndpoint) {
        clients[endpoint.id] = .init(
            endpoint: endpoint,
            role: nil,
            candidateHandle: nil,
            memberHandle: nil
        )
    }

    func create(_ request: ClipLiveShareServerRoomV4CreateRequest) throws {
        guard !ended, request.creatorHandle == creatorHandle,
              records.isEmpty else {
            throw ServerRoomComposedError.invalidServerOperation
        }
        records[creatorHandle] = request.descriptor
        revisionRaw = 1
    }

    func connect(
        endpointID: Int,
        target: ClipLiveShareServerRoomV4Target,
        capabilities: ClipLiveShareServerRoomV4Capabilities,
        authentication: ClipLiveShareServerRoomV4SessionAuthentication
    ) async throws {
        guard !ended, target.roomID == roomID,
              capabilities.maximumRoomMembers
                == ClipLiveShareServerRoomV4.maximumParticipants,
              var client = clients[endpointID] else {
            throw ServerRoomComposedError.invalidServerOperation
        }
        client.role = authentication.role
        switch authentication {
        case .creator:
            client.memberHandle = creatorHandle
            clients[endpointID] = client
            await client.endpoint.emit(.connected(role: .creator, attempt: 0))
            await client.endpoint.emit(.message(.rosterSnapshot(try roster())))
        case .freshCandidate:
            let candidate = try ClipLiveShareServerRoomV4CandidateHandle(
                bytes: Data(repeating: UInt8(0x80 + endpointID), count: 16)
            )
            client.candidateHandle = candidate
            clients[endpointID] = client
            let roomDescriptor = try requireServerRoomComposed(
                records[creatorHandle]
            )
            await client.endpoint.emit(.connected(role: .candidate, attempt: 0))
            await client.endpoint.emit(.message(.candidateOpened(
                candidateHandle: candidate,
                roomDescriptor: roomDescriptor
            )))
        case .member(let handle, _):
            client.memberHandle = handle
            clients[endpointID] = client
            await client.endpoint.emit(.connected(role: .member, attempt: 0))
            await client.endpoint.emit(.message(.rosterSnapshot(try roster())))
        }
    }

    func sendJoinKnock(
        from endpointID: Int,
        sequence: UInt64,
        payload: ClipLiveShareServerRoomV4OpaqueJoinKnock
    ) async throws {
        guard let candidate = clients[endpointID]?.candidateHandle,
              let creator = client(with: creatorHandle) else {
            throw ServerRoomComposedError.invalidServerOperation
        }
        await creator.endpoint.emit(.message(.joinKnock(
            candidateHandle: candidate,
            sequence: sequence,
            payload: payload
        )))
    }

    func admit(
        from endpointID: Int,
        handle: ClipLiveShareServerRoomV4CandidateHandle,
        descriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord
    ) async throws {
        guard clients[endpointID]?.memberHandle == creatorHandle,
              let candidateID = clients.first(where: {
                  $0.value.candidateHandle == handle
              })?.key,
              var candidate = clients[candidateID] else {
            throw ServerRoomComposedError.invalidServerOperation
        }
        let memberHandle = handle.admittedMemberHandle
        records[memberHandle] = descriptor
        candidate.memberHandle = memberHandle
        candidate.role = .member
        clients[candidateID] = candidate
        revisionRaw += 1
        let snapshot = try roster()
        await candidate.endpoint.emit(.message(.memberAdmitted(
            memberHandle: memberHandle,
            reconnectCapability: .random(),
            roster: snapshot
        )))
        await broadcastRoster(snapshot, excluding: candidateID)
    }

    func deny(
        from endpointID: Int,
        handle: ClipLiveShareServerRoomV4CandidateHandle,
        reason: String
    ) async {
        guard clients[endpointID]?.memberHandle == creatorHandle,
              let candidate = clients.values.first(where: {
                  $0.candidateHandle == handle
              }) else { return }
        await candidate.endpoint.emit(.message(.denyCandidate(
            candidateHandle: handle,
            reason: reason
        )))
    }

    func routePairSignal(
        from endpointID: Int,
        envelope: ClipLiveShareServerRoomV4PairSignalEnvelope
    ) async throws {
        guard let sender = clients[endpointID]?.memberHandle,
              let receiver = client(with: envelope.to) else {
            throw ServerRoomComposedError.invalidServerOperation
        }
        await receiver.endpoint.emit(.message(.pairSignal(
            try envelope.routedFrom(sender)
        )))
    }

    func removeMember(
        from endpointID: Int,
        handle: ClipLiveShareServerRoomV4MemberHandle
    ) async throws {
        guard clients[endpointID]?.memberHandle == creatorHandle,
              handle != creatorHandle else {
            throw ServerRoomComposedError.invalidServerOperation
        }
        try await remove(handle)
    }

    func leave(endpointID: Int) async {
        guard !ended, let handle = clients[endpointID]?.memberHandle else {
            return
        }
        if handle == creatorHandle {
            ended = true
            creatorLeaves += 1
            for client in clients.values where client.memberHandle != nil
                && client.memberHandle != creatorHandle {
                await client.endpoint.emit(.message(.roomEnded(
                    reason: "creator-left"
                )))
            }
            return
        }
        try? await remove(handle)
    }

    func simulateReconnect(endpointID: Int) async {
        guard !ended, let client = clients[endpointID],
              let role = client.role, client.memberHandle != nil,
              let snapshot = try? roster() else { return }
        await client.endpoint.emit(.reconnecting(role: role, attempt: 1))
        await client.endpoint.emit(.connected(role: role, attempt: 1))
        await client.endpoint.emit(.message(.rosterSnapshot(snapshot)))
    }

    func isEnded() -> Bool { ended }
    func creatorDepartureCount() -> Int { creatorLeaves }

    private func remove(
        _ handle: ClipLiveShareServerRoomV4MemberHandle
    ) async throws {
        guard records.removeValue(forKey: handle) != nil else {
            throw ServerRoomComposedError.invalidServerOperation
        }
        for (id, var client) in clients where client.memberHandle == handle {
            client.memberHandle = nil
            clients[id] = client
        }
        revisionRaw += 1
        try await broadcastRoster(roster(), excluding: nil)
    }

    private func roster() throws -> ClipLiveShareServerRoomV4RosterSnapshot {
        try .init(
            revision: .init(rawValue: revisionRaw),
            creatorHandle: creatorHandle,
            members: records.map {
                .init(handle: $0.key, descriptor: $0.value, connected: true)
            }
        )
    }

    private func broadcastRoster(
        _ roster: ClipLiveShareServerRoomV4RosterSnapshot,
        excluding excludedID: Int?
    ) async {
        for (id, client) in clients where id != excludedID
            && client.memberHandle != nil {
            await client.endpoint.emit(.message(.rosterSnapshot(roster)))
        }
    }

    private func client(
        with handle: ClipLiveShareServerRoomV4MemberHandle
    ) -> ClientState? {
        clients.values.first { $0.memberHandle == handle }
    }
}

private enum ServerRoomComposedError: Error, LocalizedError {
    case invalidServerOperation
    case peerUnavailable
    case failedToSetUpRTCPMux

    var errorDescription: String? {
        switch self {
        case .invalidServerOperation:
            "The deterministic room service rejected the operation."
        case .peerUnavailable:
            "The deterministic peer is unavailable."
        case .failedToSetUpRTCPMux:
            "Failed to apply the description for m= section with mid=4: "
                + "Failed to setup RTCP mux."
        }
    }
}

private func requireServerRoomComposed<T>(_ value: T?) throws -> T {
    guard let value else { throw ServerRoomComposedError.invalidServerOperation }
    return value
}

private actor ServerRoomComposedPeerFactory:
    ClipLiveShareNativeV3PeerLinkTransportFactory
{
    nonisolated let localParticipantID: ClipLiveShareNativeV3ParticipantID
    private let hub: ServerRoomComposedPeerHub
    private var transports:
        [ClipLiveShareNativeV3ParticipantID: ServerRoomComposedPeerTransport]
        = [:]

    init(
        localParticipantID: ClipLiveShareNativeV3ParticipantID,
        hub: ServerRoomComposedPeerHub
    ) {
        self.localParticipantID = localParticipantID
        self.hub = hub
    }

    func makeTransport(
        configuration: ClipLiveShareNativeV3PeerLinkConfiguration
    ) async throws -> any ClipLiveShareNativeV3PeerLinkTransport {
        let transport = ServerRoomComposedPeerTransport(
            configuration: configuration,
            hub: hub
        )
        transports[configuration.remoteParticipantID] = transport
        await hub.register(transport)
        return transport
    }

    func transport(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> ServerRoomComposedPeerTransport? {
        transports[participantID]
    }
}

private actor ServerRoomComposedPeerHub {
    private struct Edge {
        var transports:
            [ClipLiveShareNativeV3ParticipantID: ServerRoomComposedPeerTransport]
            = [:]
        var started: Set<ClipLiveShareNativeV3ParticipantID> = []
        var isReady = false
    }

    private var edges: [ClipLiveShareNativeV3PeerLinkKey: Edge] = [:]

    func register(_ transport: ServerRoomComposedPeerTransport) async {
        let configuration = transport.configuration
        var edge = edges[configuration.key] ?? Edge()
        edge.transports[configuration.localParticipantID] = transport
        edges[configuration.key] = edge
        await activateIfReady(configuration.key)
    }

    func started(_ transport: ServerRoomComposedPeerTransport) async {
        let configuration = transport.configuration
        var edge = edges[configuration.key] ?? Edge()
        edge.transports[configuration.localParticipantID] = transport
        edge.started.insert(configuration.localParticipantID)
        edges[configuration.key] = edge
        await activateIfReady(configuration.key)
    }

    func deliver(
        _ data: Data,
        from configuration: ClipLiveShareNativeV3PeerLinkConfiguration
    ) async throws {
        guard let edge = edges[configuration.key], edge.isReady,
              let remote = edge.transports[configuration.remoteParticipantID]
        else { throw ServerRoomComposedError.peerUnavailable }
        await remote.emit(.controlMessageReceived(data))
    }

    func close(_ configuration: ClipLiveShareNativeV3PeerLinkConfiguration) {
        guard var edge = edges[configuration.key] else { return }
        edge.transports[configuration.localParticipantID] = nil
        edge.started.remove(configuration.localParticipantID)
        edge.isReady = false
        if edge.transports.isEmpty {
            edges[configuration.key] = nil
        } else {
            edges[configuration.key] = edge
        }
    }

    private func activateIfReady(
        _ key: ClipLiveShareNativeV3PeerLinkKey
    ) async {
        guard var edge = edges[key], !edge.isReady,
              edge.transports.count == 2, edge.started.count == 2 else {
            return
        }
        edge.isReady = true
        edges[key] = edge
        let transports = Array(edge.transports.values)
        for transport in transports {
            await transport.emit(.connectionStateChanged(.connected))
            await transport.emit(.controlChannelStateChanged(.open))
        }
        if let offerer = transports.first(where: {
            $0.configuration.role == .offerer
        }) {
            await offerer.emit(.negotiationNeeded)
        }
    }
}

private actor ServerRoomComposedPeerTransport:
    ClipLiveShareNativeV3PeerLinkTransport
{
    nonisolated let configuration: ClipLiveShareNativeV3PeerLinkConfiguration
    private let hub: ServerRoomComposedPeerHub
    private var continuation:
        AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent>.Continuation?
    private var shouldFailNextRemoteDescription = false

    init(
        configuration: ClipLiveShareNativeV3PeerLinkConfiguration,
        hub: ServerRoomComposedPeerHub
    ) {
        self.configuration = configuration
        self.hub = hub
    }

    func events()
        -> AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent>
    {
        let pair = AsyncStream.makeStream(
            of: ClipLiveShareNativeV3PeerLinkTransportEvent.self,
            bufferingPolicy: .bufferingOldest(128)
        )
        continuation = pair.continuation
        return pair.stream
    }

    func start() async { await hub.started(self) }

    func requestNegotiation() async throws {
        continuation?.yield(.localNegotiation(.sessionDescription(.init(
            kind: .offer,
            sdp: "v=0\r\no=offer-\(configuration.localParticipantID.rawValue)\r\n"
        ))))
    }

    func applyRemoteDescription(
        _ description: WebRTCSessionDescription
    ) throws {
        if shouldFailNextRemoteDescription {
            shouldFailNextRemoteDescription = false
            throw ServerRoomComposedError.failedToSetUpRTCPMux
        }
        guard description.kind == .offer else { return }
        continuation?.yield(.localNegotiation(.sessionDescription(.init(
            kind: .answer,
            sdp: "v=0\r\no=answer-\(configuration.localParticipantID.rawValue)\r\n"
        ))))
    }

    func addRemoteICECandidate(_: WebRTCICECandidate) {}

    func sendControlMessage(_ data: Data) async throws {
        try await hub.deliver(data, from: configuration)
    }

    func sendEphemeralControlMessage(_ data: Data) async -> Bool {
        do {
            try await hub.deliver(data, from: configuration)
            return true
        } catch {
            return false
        }
    }

    func remoteVideoStream(
        for _: ClipLiveShareStreamDescriptor
    ) -> WebRTCRemoteVideoStream? { nil }

    func setOutboundMediaEnabled(_: Bool) {}
    func setRemoteParticipantAudioPlaybackEnabled(_: Bool) {}
    func setRemoteParticipantAudioVolume(_: Double) {}
    func restartICE() {}
    func statistics() -> ClipLiveShareNativeV3PeerLinkTransportStatistics {
        .init(capturedAt: Date(timeIntervalSince1970: 0))
    }

    func close() async {
        continuation?.finish()
        continuation = nil
        await hub.close(configuration)
    }

    func emit(_ event: ClipLiveShareNativeV3PeerLinkTransportEvent) {
        continuation?.yield(event)
    }

    func failNextRemoteDescriptionWithRTCPMuxError() {
        shouldFailNextRemoteDescription = true
    }
}

/// Test-owned presentation bridge for the composed room fixture.
///
/// `ServerCoordinatedMeshParticipantCoordinator` owns concrete WebRTC video
/// streams, which deliberately are not constructible outside the WebRTC
/// package. This bridge begins at its existing room-snapshot seam, then drives
/// the exact production presentation and native-window state machines with a
/// deterministic track token and a no-op video surface. It therefore exercises
/// descriptor/track ordering, window retention and rebinding without launching
/// Clip or relying on ScreenCaptureKit.
@MainActor
private final class ServerRoomComposedWindowPresentation {
    @MainActor
    final class SurfaceProbe {
        private(set) var boundSourceIDs: [String] = []
        private(set) var tearDownCount = 0

        func recordBinding(sourceInstanceID: String) {
            boundSourceIDs.append(sourceInstanceID)
        }

        func recordTeardown() {
            tearDownCount += 1
        }
    }

    @MainActor
    private final class RemoteEntry {
        var presentation: RemoteParticipantPresentation<String>
        let windows: NativeViewerWindowCoordinator
        let probe: SurfaceProbe

        init(
            member: ClipLiveShareServerRoomV4ClientVerifiedMember
        ) {
            presentation = .init(
                participantNamespace:
                    member.descriptor.identity.x963Representation
            )
            let probe = SurfaceProbe()
            self.probe = probe
            windows = NativeViewerWindowCoordinator(
                ownerName: member.descriptor.displayName,
                ownerPublicIdentity:
                    member.descriptor.identity.x963Representation,
                surfaceFactory: {
                    NativeViewerVideoSurfaceAdapter(
                        view: NSView(frame: .zero),
                        bind: { [weak probe] source in
                            probe?.recordBinding(
                                sourceInstanceID: source.sourceInstanceID
                            )
                        },
                        teardown: { [weak probe] in
                            probe?.recordTeardown()
                        }
                    )
                }
            )
        }
    }

    private let localParticipantID: ClipLiveShareNativeV3ParticipantID
    private var remotes:
        [ClipLiveShareNativeV3ParticipantID: RemoteEntry] = [:]

    init(localParticipantID: ClipLiveShareNativeV3ParticipantID) {
        self.localParticipantID = localParticipantID
    }

    var windowCount: Int {
        remotes.values.reduce(0) { $0 + $1.windows.windowCount }
    }

    var remoteSourceInstanceIDs: Set<String> {
        Set(remotes.values.flatMap {
            $0.windows.windowSnapshots.map(\.source.sourceInstanceID)
        })
    }

    func probe(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> SurfaceProbe? {
        remotes[participantID]?.probe
    }

    func windowSnapshots(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> [NativeViewerWindowSnapshot] {
        remotes[participantID]?.windows.windowSnapshots ?? []
    }

    func reconcile(
        _ snapshot: ServerCoordinatedMeshRoomSessionSnapshot,
        unavailableRemoteParticipantIDs: Set<
            ClipLiveShareNativeV3ParticipantID
        > = []
    ) throws {
        guard let verified = snapshot.verifiedRoom else {
            throw ServerRoomComposedError.invalidServerOperation
        }
        let remoteMembers = verified.members.filter {
            $0.descriptor.participantID != localParticipantID
        }
        let retainedIDs = Set(remoteMembers.map(\.descriptor.participantID))

        for participantID in Array(remotes.keys) where !retainedIDs.contains(
            participantID
        ) {
            guard let removed = remotes.removeValue(forKey: participantID)
            else { continue }
            _ = removed.presentation.tearDown()
            removed.windows.tearDown()
        }

        for member in remoteMembers {
            let participantID = member.descriptor.participantID
            let entry: RemoteEntry
            if let existing = remotes[participantID] {
                entry = existing
            } else {
                let created = RemoteEntry(member: member)
                remotes[participantID] = created
                entry = created
            }

            entry.windows.setOwnerName(member.descriptor.displayName)
            let existingWindows = entry.windows.windowSnapshots
            entry.presentation.rememberLocalPresentation(existingWindows)
            let published = snapshot.media?.sourceSnapshots[participantID]
            let publishedSources = published?.sources ?? []
            let publishedStreamIDs = Set(
                publishedSources.map { $0.descriptor.stream.id.rawValue }
            )
            let isAvailable = !unavailableRemoteParticipantIDs.contains(
                participantID
            )

            for ready in entry.presentation.readySources
            where !isAvailable || !publishedStreamIDs.contains(ready.streamID) {
                _ = entry.presentation.removeRemoteTrack(
                    streamID: ready.streamID
                )
            }

            let sources = publishedSources.map { source in
                let stream = source.descriptor.stream
                return NativeViewerSourceSnapshot(
                    sourceInstanceID:
                        source.key.sourceInstanceID.rawValue,
                    streamID: stream.id.rawValue,
                    applicationName: stream.appName,
                    windowName: stream.windowName,
                    pixelSize: CGSize(
                        width: stream.width,
                        height: stream.height
                    ),
                    sourcePointSize: stream.sourcePointSize,
                    isFocused: stream.focused,
                    isConnected: isAvailable,
                    stateRevision: published?.sourceRevision.rawValue ?? 1
                )
            }
            _ = entry.presentation.replaceAuthoritativeSources(sources)
            if isAvailable {
                for source in sources {
                    _ = entry.presentation.upsertRemoteTrack(
                        "track:\(participantID.rawValue):\(source.streamID)",
                        streamID: source.streamID
                    )
                }
            }
            try entry.windows.reconcile(
                entry.presentation.windowSources(retaining: existingWindows)
            )
            // Keep hosted tests noninteractive after the native window state
            // machine has created or updated the same window it uses in app.
            for window in entry.windows.windowSnapshots where window.isVisible {
                entry.windows.setSourceVisible(
                    false,
                    sourceInstanceID: window.source.sourceInstanceID
                )
            }
        }
    }

    func tearDown() {
        for entry in remotes.values {
            _ = entry.presentation.tearDown()
            entry.windows.tearDown()
        }
        remotes.removeAll()
    }
}

@MainActor
private func expectCompleteWindowPresentation(
    _ presentations: [ServerRoomComposedWindowPresentation],
    clients: [ServerRoomComposedClient]
) {
    #expect(presentations.count == clients.count)
    let allSources = Dictionary(
        uniqueKeysWithValues: clients.map {
            ($0.participantID, $0.source.key.sourceInstanceID.rawValue)
        }
    )
    for (index, client) in clients.enumerated() {
        let expected = Set(
            allSources.compactMap { participantID, sourceID in
                participantID == client.participantID ? nil : sourceID
            }
        )
        #expect(presentations[index].windowCount == clients.count - 1)
        #expect(presentations[index].remoteSourceInstanceIDs == expected)
    }
}

private func completeReadyMesh(
    _ clients: [ServerRoomComposedClient]
) async -> Bool {
    let expectedParticipants = Set(clients.map(\.participantID))
    for client in clients {
        let snapshot = await client.session.snapshot()
        guard snapshot.phase == .active,
              Set(snapshot.verifiedRoom?.members.map {
                  $0.descriptor.participantID
              } ?? []) == expectedParticipants,
              let links = snapshot.media?.links.links,
              links.count == max(0, clients.count - 1),
              links.allSatisfy(\.isReady) else {
            return false
        }
    }
    return true
}

private func completeSourceMesh(
    _ clients: [ServerRoomComposedClient],
    expectedSources:
        [ClipLiveShareNativeV3ParticipantID:
            ClipLiveShareNativeV3PublishedSource]
) async -> Bool {
    let expectedParticipants = Set(expectedSources.keys)
    let expectedWindowNames = Set(
        expectedSources.values.map(\.descriptor.stream.windowName)
    )
    for client in clients {
        guard let media = await client.session.snapshot().media,
              Set(media.sourceSnapshots.keys) == expectedParticipants else {
            return false
        }
        for (participantID, source) in expectedSources {
            guard media.sourceSnapshots[participantID]?.sources == [source]
            else { return false }
        }
        let receivedWindowNames = Set(
            media.sourceSnapshots.values.flatMap {
                $0.sources.map(\.descriptor.stream.windowName)
            }
        )
        guard receivedWindowNames == expectedWindowNames else { return false }
    }
    return true
}

private func serverRoomComposedEventually(
    _ description: String,
    timeout: Duration = .seconds(5),
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(description)")
}
