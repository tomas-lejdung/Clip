import ClipLiveShare
import Foundation
import Testing
@testable import Clip

@Suite("Mesh friendship handshake controller")
@MainActor
struct MeshFriendshipHandshakeControllerTests {
    @Test("two participants commit one friendship and replay exact recovery messages")
    func completeHandshakeAndDuplicateRecovery() async throws {
        let fixture = try Fixture()
        let aliceRepository = fixture.repository(identity: fixture.alice)
        let bobRepository = fixture.repository(identity: fixture.bob)
        let aliceMessages = FriendshipMessageProbe()
        let bobMessages = FriendshipMessageProbe()
        let alice = fixture.controller(
            signer: fixture.alice,
            repository: aliceRepository,
            endpoint: .official,
            messages: aliceMessages,
            name: "Alice"
        )
        let bob = fixture.controller(
            signer: fixture.bob,
            repository: bobRepository,
            endpoint: .localDevelopment,
            messages: bobMessages,
            name: "Bob"
        )
        await alice.updateRoom(fixture.aliceContext)
        await bob.updateRoom(fixture.bobContext)

        await alice.addFriend(participantID: fixture.bobID)
        let request = try #require(aliceMessages.takeLast()?.message)
        #expect(
            alice.snapshot.stateByParticipantID[fixture.bobID]
                == .requestPending
        )

        await bob.handle(request, from: fixture.aliceID)
        let pending = try #require(bob.snapshot.pendingRequests.first)
        #expect(pending.displayName == "Alice")
        #expect(
            bob.snapshot.stateByParticipantID[fixture.aliceID]
                == .incomingRequest
        )

        await bob.allow(requestID: pending.id)
        let acceptance = try #require(bobMessages.takeLast()?.message)
        await alice.handle(acceptance, from: fixture.bobID)
        let acknowledgement = try #require(aliceMessages.takeLast()?.message)
        await bob.handle(acknowledgement, from: fixture.aliceID)
        let receipt = try #require(bobMessages.takeLast()?.message)
        await alice.handle(receipt, from: fixture.bobID)

        #expect(
            alice.snapshot.stateByParticipantID[fixture.bobID] == .trusted
        )
        #expect(
            bob.snapshot.stateByParticipantID[fixture.aliceID] == .trusted
        )
        let aliceFriend = try #require(
            try await aliceRepository.friend(with: fixture.bob.publicKey)
        )
        let bobFriend = try #require(
            try await bobRepository.friend(with: fixture.alice.publicKey)
        )
        #expect(aliceFriend.profile.presenceServiceEndpoint == .localDevelopment)
        #expect(bobFriend.profile.presenceServiceEndpoint == .official)
        #expect(aliceFriend.localPublishingLocator == bobFriend.profile.locator)
        #expect(bobFriend.localPublishingLocator == aliceFriend.profile.locator)

        // The accepter retained the exact locally signed receipt. A repeated
        // request after an ambiguous send recovers that message byte-for-byte
        // instead of creating another mailbox or signature.
        await bob.handle(request, from: fixture.aliceID)
        #expect(bobMessages.takeLast()?.message == receipt)
    }

    @Test("failed first send retries the identical durable request")
    func retryUsesExactRequest() async throws {
        let fixture = try Fixture()
        let repository = fixture.repository(identity: fixture.alice)
        let messages = FriendshipMessageProbe()
        messages.failNext = true
        let alice = fixture.controller(
            signer: fixture.alice,
            repository: repository,
            endpoint: .official,
            messages: messages,
            name: "Alice"
        )
        await alice.updateRoom(fixture.aliceContext)

        await alice.addFriend(participantID: fixture.bobID)
        guard case .failed = alice.snapshot
            .stateByParticipantID[fixture.bobID] else {
            Issue.record("The failed send was not exposed for retry.")
            return
        }
        let durableRequest = try #require(
            try await repository.snapshot().recoveryJournal.first?
                .signedRequest
        )

        await alice.retry(participantID: fixture.bobID)
        #expect(messages.takeLast()?.message == durableRequest)
        #expect(
            alice.snapshot.stateByParticipantID[fixture.bobID]
                == .requestPending
        )
    }

    @Test("denial returns the requester to available and replays exactly")
    func deniedRequestStaysDenied() async throws {
        let fixture = try Fixture()
        let aliceMessages = FriendshipMessageProbe()
        let bobMessages = FriendshipMessageProbe()
        let alice = fixture.controller(
            signer: fixture.alice,
            repository: fixture.repository(identity: fixture.alice),
            endpoint: .official,
            messages: aliceMessages,
            name: "Alice"
        )
        let bob = fixture.controller(
            signer: fixture.bob,
            repository: fixture.repository(identity: fixture.bob),
            endpoint: .official,
            messages: bobMessages,
            name: "Bob"
        )
        await alice.updateRoom(fixture.aliceContext)
        await bob.updateRoom(fixture.bobContext)
        await alice.addFriend(participantID: fixture.bobID)
        let request = try #require(aliceMessages.takeLast()?.message)
        await bob.handle(request, from: fixture.aliceID)
        let requestID = try #require(bob.snapshot.pendingRequests.first?.id)

        await bob.deny(requestID: requestID)
        #expect(bob.snapshot.pendingRequests.isEmpty)
        let decline = try #require(bobMessages.takeLast()?.message)
        await alice.handle(decline, from: fixture.bobID)
        #expect(
            alice.snapshot.stateByParticipantID[fixture.bobID] == .available
        )
        #expect(alice.snapshot.notice?.contains("declined") == true)

        // The denied request is tombstoned yet retains the exact locally
        // signed response for ambiguous-send recovery.
        await bob.handle(request, from: fixture.aliceID)
        #expect(bob.snapshot.pendingRequests.isEmpty)
        #expect(bobMessages.takeLast()?.message == decline)
    }

    private struct Fixture {
        let alice = ClipLiveShareSoftwareIdentitySigner()
        let bob = ClipLiveShareSoftwareIdentitySigner()
        let aliceID = ClipLiveShareNativeV3ParticipantID.random()
        let bobID = ClipLiveShareNativeV3ParticipantID.random()
        let roomID = ClipLiveShareServerRoomV4RoomID.random()
        let sessionID = ClipLiveShareSessionID.random()
        let now: Date

        init() throws {
            now = try ClipLiveShareNativeTimestamp(
                millisecondsSince1970: 1_800_000_000_000
            ).date
        }

        var aliceContext: MeshFriendshipRoomContext {
            .init(
                roomID: roomID,
                sessionID: sessionID,
                localParticipantID: aliceID,
                remotes: [.init(
                    participantID: bobID,
                    identity: bob.publicKey,
                    displayName: "Bob",
                    deviceName: "Bob Mac",
                    isConnected: true
                )]
            )
        }

        var bobContext: MeshFriendshipRoomContext {
            .init(
                roomID: roomID,
                sessionID: sessionID,
                localParticipantID: bobID,
                remotes: [.init(
                    participantID: aliceID,
                    identity: alice.publicKey,
                    displayName: "Alice",
                    deviceName: "Alice Mac",
                    isConnected: true
                )]
            )
        }

        func repository(
            identity: ClipLiveShareSoftwareIdentitySigner
        ) -> MeshFriendshipRepository {
            MeshFriendshipRepository(
                storage: HandshakeMemoryStorage(),
                localIdentity: identity.publicKey,
                now: { now }
            )
        }

        @MainActor
        func controller(
            signer: ClipLiveShareSoftwareIdentitySigner,
            repository: MeshFriendshipRepository,
            endpoint: ClipLiveShareRendezvousEndpoint,
            messages: FriendshipMessageProbe,
            name: String
        ) -> MeshFriendshipHandshakeController {
            MeshFriendshipHandshakeController(
                localDisplayName: name,
                localDeviceName: "\(name) Mac",
                dependencies: .init(
                    signer: signer,
                    repository: repository,
                    presenceServiceEndpoint: endpoint
                ),
                now: { now },
                sendMessage: { message, participantID in
                    try messages.send(message, to: participantID)
                }
            )
        }
    }
}

@MainActor
private final class FriendshipMessageProbe {
    struct Sent {
        let message: ClipLiveShareServerRoomV4SignedFriendMessage
        let participantID: ClipLiveShareNativeV3ParticipantID
    }

    var sent: [Sent] = []
    var failNext = false

    func send(
        _ message: ClipLiveShareServerRoomV4SignedFriendMessage,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) throws {
        if failNext {
            failNext = false
            throw FriendshipHandshakeTestError.sendFailed
        }
        sent.append(.init(message: message, participantID: participantID))
    }

    func takeLast() -> Sent? {
        sent.popLast()
    }
}

private final class HandshakeMemoryStorage: MeshFriendshipStorage,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var data: Data?

    func load() throws -> Data? {
        lock.withLock { data }
    }

    func save(_ data: Data) throws {
        lock.withLock { self.data = data }
    }
}

private enum FriendshipHandshakeTestError: Error {
    case sendFailed
}
