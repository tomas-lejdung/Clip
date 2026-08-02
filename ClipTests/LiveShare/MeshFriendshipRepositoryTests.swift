import ClipLiveShare
import Foundation
import Testing
@testable import Clip

@Suite("Mesh friendship repository")
struct MeshFriendshipRepositoryTests {
    @Test("four-step commit is atomic, recoverable, and trusted on both sides")
    func completeCommitAndRecovery() async throws {
        let fixture = try Fixture()
        let requesterStorage = MemoryMeshFriendshipStorage()
        let accepterStorage = MemoryMeshFriendshipStorage()
        let requesterRepository = MeshFriendshipRepository(
            storage: requesterStorage,
            localIdentity: fixture.requesterSigner.publicKey,
            now: { fixture.now }
        )
        let accepterRepository = MeshFriendshipRepository(
            storage: accepterStorage,
            localIdentity: fixture.accepterSigner.publicKey,
            now: { fixture.now }
        )
        let chain = try fixture.makeChain(
            requesterLocator: await requesterRepository.makeLocalPublishingLocator(),
            accepterLocator: await accepterRepository.makeLocalPublishingLocator()
        )

        try await requesterRepository.recordOutgoingRequest(chain.request)
        try await accepterRepository.recordIncomingRequest(chain.request)
        try await accepterRepository.recordAcceptance(
            chain.acceptance,
            requestID: chain.requestID
        )
        try await requesterRepository.stageOutgoingAcknowledgement(
            chain.acknowledgement,
            acceptance: chain.acceptance,
            requestID: chain.requestID
        )

        guard case let .request(request) = chain.request.message,
              case let .acceptance(acceptance) = chain.acceptance.message else {
            Issue.record("The fixture did not create a request/acceptance pair.")
            return
        }
        let pending = try #require(await requesterRepository.friend(
            with: fixture.accepterSigner.publicKey
        ))
        #expect(pending.trustState == .pendingCommit)
        #expect(pending.localPublishingLocator == request.requester.locator)
        #expect(pending.profile.locator == acceptance.accepter.locator)
        #expect(
            pending.localPublishingLocator.routingID
                != pending.profile.locator.routingID
        )

        try await accepterRepository.commitIncomingFriendship(
            receipt: chain.receipt,
            acknowledgement: chain.acknowledgement,
            requestID: chain.requestID
        )
        #expect(
            try await accepterRepository.recoverableReply(for: chain.requestID)
                == chain.receipt
        )
        #expect(
            try await accepterRepository.friend(
                with: fixture.requesterSigner.publicKey
            )?.trustState == .trusted
        )

        // Simulate requester relaunch after sending its acknowledgement but
        // before receiving the commit receipt.
        let relaunchedRequester = MeshFriendshipRepository(
            storage: requesterStorage,
            localIdentity: fixture.requesterSigner.publicKey,
            now: { fixture.now }
        )
        #expect(
            try await relaunchedRequester.recoverableReply(for: chain.requestID)
                == chain.acknowledgement
        )
        try await relaunchedRequester.commitOutgoingFriendship(
            receipt: chain.receipt,
            requestID: chain.requestID
        )
        #expect(
            try await relaunchedRequester.friend(
                with: fixture.accepterSigner.publicKey
            )?.trustState == .trusted
        )
    }

    @Test("duplicate request ID is idempotent but conflicting replay is rejected")
    func idempotencyAndReplay() async throws {
        let fixture = try Fixture()
        let storage = MemoryMeshFriendshipStorage()
        let repository = MeshFriendshipRepository(
            storage: storage,
            localIdentity: fixture.requesterSigner.publicKey,
            now: { fixture.now }
        )
        let chain = try fixture.makeChain(
            requesterLocator: await repository.makeLocalPublishingLocator(),
            accepterLocator: .random()
        )
        try await repository.recordOutgoingRequest(chain.request)
        try await repository.recordOutgoingRequest(chain.request)
        #expect(try await repository.snapshot().recoveryJournal.count == 1)

        let conflicting = try fixture.makeChain(
            requesterLocator: await repository.makeLocalPublishingLocator(),
            accepterLocator: .random()
        ).request
        await #expect(throws: MeshFriendshipRepositoryError.replayedRequest) {
            try await repository.recordOutgoingRequest(conflicting)
        }

        try await repository.reject(chain.requestID)
        await #expect(throws: MeshFriendshipRepositoryError.replayedRequest) {
            try await repository.recordOutgoingRequest(chain.request)
        }
    }

    @Test("failed durable commit does not publish trusted in-memory state")
    func failedSaveDoesNotCommit() async throws {
        let fixture = try Fixture()
        let requesterStorage = MemoryMeshFriendshipStorage()
        let accepterStorage = MemoryMeshFriendshipStorage()
        let requesterRepository = MeshFriendshipRepository(
            storage: requesterStorage,
            localIdentity: fixture.requesterSigner.publicKey,
            now: { fixture.now }
        )
        let accepterRepository = MeshFriendshipRepository(
            storage: accepterStorage,
            localIdentity: fixture.accepterSigner.publicKey,
            now: { fixture.now }
        )
        let chain = try fixture.makeChain(
            requesterLocator: await requesterRepository.makeLocalPublishingLocator(),
            accepterLocator: await accepterRepository.makeLocalPublishingLocator()
        )
        try await accepterRepository.recordIncomingRequest(chain.request)
        try await accepterRepository.recordAcceptance(
            chain.acceptance,
            requestID: chain.requestID
        )
        accepterStorage.failNextSave()

        await #expect(throws: MemoryMeshFriendshipStorage.TestError.writeFailed) {
            try await accepterRepository.commitIncomingFriendship(
                receipt: chain.receipt,
                acknowledgement: chain.acknowledgement,
                requestID: chain.requestID
            )
        }
        #expect(
            try await accepterRepository.friend(
                with: fixture.requesterSigner.publicKey
            ) == nil
        )
        #expect(
            try await accepterRepository.recoverableReply(for: chain.requestID)
                == chain.acceptance
        )
    }

    @Test("commit rebinds an acknowledgement signer to the requester identity")
    func acknowledgementSignerBinding() async throws {
        let fixture = try Fixture()
        let repository = MeshFriendshipRepository(
            storage: MemoryMeshFriendshipStorage(),
            localIdentity: fixture.accepterSigner.publicKey,
            now: { fixture.now }
        )
        let chain = try fixture.makeChain(
            requesterLocator: .random(),
            accepterLocator: await repository.makeLocalPublishingLocator()
        )
        try await repository.recordIncomingRequest(chain.request)
        try await repository.recordAcceptance(
            chain.acceptance,
            requestID: chain.requestID
        )
        guard case let .acknowledgement(value) = chain.acknowledgement.message else {
            Issue.record("The fixture did not create an acknowledgement.")
            return
        }
        let impostor = ClipLiveShareSoftwareIdentitySigner()
        let impostorAcknowledgement = try
            ClipLiveShareServerRoomV4SignedFriendMessage(
                signing: .acknowledgement(value),
                with: impostor
            )

        await #expect(throws: MeshFriendshipRepositoryError.invalidHandshake) {
            try await repository.commitIncomingFriendship(
                receipt: chain.receipt,
                acknowledgement: impostorAcknowledgement,
                requestID: chain.requestID
            )
        }
        #expect(
            try await repository.friend(
                with: fixture.requesterSigner.publicKey
            ) == nil
        )
    }

    @Test("file storage survives repository relaunch")
    func filePersistence() async throws {
        let fixture = try Fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mesh-friends-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("friends.json")
        let first = MeshFriendshipRepository(
            storage: LiveMeshFriendshipFileStorage(fileURL: fileURL),
            localIdentity: fixture.requesterSigner.publicKey,
            now: { fixture.now }
        )
        let localMailbox = await first.makeLocalPublishingLocator()
        let chain = try fixture.makeChain(
            requesterLocator: localMailbox,
            accepterLocator: .random()
        )
        try await first.recordOutgoingRequest(chain.request)
        let second = MeshFriendshipRepository(
            storage: LiveMeshFriendshipFileStorage(fileURL: fileURL),
            localIdentity: fixture.requesterSigner.publicKey,
            now: { fixture.now }
        )
        let recovered = try await second.snapshot().recoveryJournal
        #expect(recovered.count == 1)
        #expect(recovered.first?.signedRequest == chain.request)
    }

    @Test("local aliases persist, reset safely, and survive reconfirmation")
    func localAliasLifecycle() async throws {
        let fixture = try Fixture()
        let storage = MemoryMeshFriendshipStorage()
        let repository = MeshFriendshipRepository(
            storage: storage,
            localIdentity: fixture.requesterSigner.publicKey,
            now: { fixture.now }
        )
        let chain = try fixture.makeChain(
            requesterLocator: await repository.makeLocalPublishingLocator(),
            accepterLocator: .random()
        )
        try await repository.recordOutgoingRequest(chain.request)
        try await repository.stageOutgoingAcknowledgement(
            chain.acknowledgement,
            acceptance: chain.acceptance,
            requestID: chain.requestID
        )
        try await repository.commitOutgoingFriendship(
            receipt: chain.receipt,
            requestID: chain.requestID
        )
        let original = try #require(await repository.snapshot().friends.first)

        try await repository.renameFriend(
            identity: original.identity,
            to: "  Jules  "
        )
        var renamed = try #require(await repository.snapshot().friends.first)
        #expect(renamed.displayName == "Jules")
        #expect(renamed.localAlias == "Jules")
        #expect(renamed.profile == original.profile)
        #expect(renamed.localPublishingLocator == original.localPublishingLocator)

        // An idempotent signed reconfirmation may refresh trusted metadata but
        // must never erase this device's local label.
        try await repository.commitOutgoingFriendship(
            receipt: chain.receipt,
            requestID: chain.requestID
        )
        renamed = try #require(await repository.snapshot().friends.first)
        #expect(renamed.localAlias == "Jules")

        let relaunched = MeshFriendshipRepository(
            storage: storage,
            localIdentity: fixture.requesterSigner.publicKey,
            now: { fixture.now }
        )
        #expect(try await relaunched.snapshot().friends.first?.displayName == "Jules")

        try await relaunched.renameFriend(
            identity: original.identity,
            to: " \n "
        )
        let reset = try #require(await relaunched.snapshot().friends.first)
        #expect(reset.localAlias == nil)
        #expect(reset.displayName == reset.profile.displayName)
    }

    @Test("invalid local aliases fail atomically")
    func invalidLocalAlias() async throws {
        let fixture = try Fixture()
        let storage = MemoryMeshFriendshipStorage()
        let repository = MeshFriendshipRepository(
            storage: storage,
            localIdentity: fixture.requesterSigner.publicKey,
            now: { fixture.now }
        )
        let chain = try fixture.makeChain(
            requesterLocator: await repository.makeLocalPublishingLocator(),
            accepterLocator: .random()
        )
        try await repository.recordOutgoingRequest(chain.request)
        try await repository.stageOutgoingAcknowledgement(
            chain.acknowledgement,
            acceptance: chain.acceptance,
            requestID: chain.requestID
        )
        try await repository.commitOutgoingFriendship(
            receipt: chain.receipt,
            requestID: chain.requestID
        )
        let friend = try #require(await repository.snapshot().friends.first)

        await #expect(throws: MeshFriendshipRepositoryError.invalidAlias) {
            try await repository.renameFriend(
                identity: friend.identity,
                to: "Bad\u{0000}Name"
            )
        }
        #expect(try await repository.snapshot().friends.first?.localAlias == nil)
    }

    private struct Chain {
        let requestID: ClipLiveShareServerRoomV4FriendRequestID
        let request: ClipLiveShareServerRoomV4SignedFriendMessage
        let acceptance: ClipLiveShareServerRoomV4SignedFriendMessage
        let acknowledgement: ClipLiveShareServerRoomV4SignedFriendMessage
        let receipt: ClipLiveShareServerRoomV4SignedFriendMessage
    }

    private struct Fixture: @unchecked Sendable {
        let requestID: ClipLiveShareServerRoomV4FriendRequestID
        let requesterSigner = ClipLiveShareSoftwareIdentitySigner()
        let accepterSigner = ClipLiveShareSoftwareIdentitySigner()
        let roomID = ClipLiveShareServerRoomV4RoomID.random()
        let sessionID = ClipLiveShareSessionID.random()
        let requesterParticipantID = ClipLiveShareNativeV3ParticipantID.random()
        let accepterParticipantID = ClipLiveShareNativeV3ParticipantID.random()
        let timestamp: ClipLiveShareNativeTimestamp
        let now: Date

        init(requestID: ClipLiveShareServerRoomV4FriendRequestID = .random()) throws {
            self.requestID = requestID
            timestamp = try .init(millisecondsSince1970: 1_800_000_000_000)
            now = timestamp.date.addingTimeInterval(4)
        }

        func makeChain(
            requesterLocator: ClipLiveShareServerRoomV4FriendLocator,
            accepterLocator: ClipLiveShareServerRoomV4FriendLocator
        ) throws -> Chain {
            let requesterProfile = try ClipLiveShareServerRoomV4FriendProfile(
                identity: requesterSigner.publicKey,
                displayName: "Requester",
                deviceName: "Requester Mac",
                locator: requesterLocator
            )
            let accepterProfile = try ClipLiveShareServerRoomV4FriendProfile(
                identity: accepterSigner.publicKey,
                displayName: "Accepter",
                deviceName: "Accepter Mac",
                locator: accepterLocator
            )
            let requestValue = try ClipLiveShareServerRoomV4FriendRequest(
                requestID: requestID,
                roomID: roomID,
                sessionID: sessionID,
                requesterParticipantID: requesterParticipantID,
                accepterParticipantID: accepterParticipantID,
                requester: requesterProfile,
                expectedAccepterFingerprint: accepterSigner.publicKey.fingerprint,
                issuedAt: timestamp,
                expiresAt: try timestamp.adding(milliseconds: 5 * 60 * 1_000)
            )
            let request = try ClipLiveShareServerRoomV4SignedFriendMessage(
                signing: .request(requestValue),
                with: requesterSigner
            )
            let acceptanceValue = try ClipLiveShareServerRoomV4FriendAcceptance(
                accepting: requestValue,
                accepter: accepterProfile,
                acceptedAt: try timestamp.adding(milliseconds: 1_000)
            )
            let acceptance = try ClipLiveShareServerRoomV4SignedFriendMessage(
                signing: .acceptance(acceptanceValue),
                with: accepterSigner
            )
            let acknowledgementValue = try
                ClipLiveShareServerRoomV4FriendAcknowledgement(
                    acknowledging: acceptanceValue,
                    request: requestValue,
                    acknowledgedAt: try timestamp.adding(milliseconds: 2_000)
                )
            let acknowledgement = try
                ClipLiveShareServerRoomV4SignedFriendMessage(
                    signing: .acknowledgement(acknowledgementValue),
                    with: requesterSigner
                )
            let receiptValue = try ClipLiveShareServerRoomV4FriendCommitReceipt(
                committing: acknowledgementValue,
                committedAt: try timestamp.adding(milliseconds: 3_000)
            )
            let receipt = try ClipLiveShareServerRoomV4SignedFriendMessage(
                signing: .commitReceipt(receiptValue),
                with: accepterSigner
            )
            return .init(
                requestID: requestID,
                request: request,
                acceptance: acceptance,
                acknowledgement: acknowledgement,
                receipt: receipt
            )
        }
    }
}

private final class MemoryMeshFriendshipStorage: MeshFriendshipStorage,
    @unchecked Sendable
{
    enum TestError: Error, Equatable { case writeFailed }

    private let lock = NSLock()
    private var data: Data?
    private var shouldFailNextSave = false

    func load() throws -> Data? {
        lock.withLock { data }
    }

    func save(_ data: Data) throws {
        try lock.withLock {
            if shouldFailNextSave {
                shouldFailNextSave = false
                throw TestError.writeFailed
            }
            self.data = data
        }
    }

    func failNextSave() {
        lock.withLock { shouldFailNextSave = true }
    }
}
