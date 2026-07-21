import ClipCore
import ClipLiveShare
import Foundation
import Testing
@testable import Clip

@Suite("Native friend persistence")
struct NativeFriendRepositoryTests {
    @Test("Friends round-trip without session passwords or private identity material")
    func roundTrip() async throws {
        let fileSystem = NativeFriendMemoryFileSystem()
        let directory = URL(fileURLWithPath: "/fixture", isDirectory: true)
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: directory,
            fileSystem: fileSystem
        )
        let friend = makeFriend(name: "Alex")
        try await repository.save(NativeFriendBook(records: [friend]))
        let loaded = try await repository.load()

        #expect(loaded.records == [friend])
        let encoded = try #require(await fileSystem.lastWrittenData)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("Alex"))
        #expect(!text.localizedCaseInsensitiveContains("password"))
        #expect(!text.localizedCaseInsensitiveContains("privateKey"))
    }

    @Test("Durable acceptance returns only after the friend is readable from disk")
    @MainActor
    func durableAcceptanceCompletesAtomicWrite() async throws {
        let fileSystem = NativeFriendMemoryFileSystem()
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/durable-fixture",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        let model = NativeFriendModel(repository: repository)
        let friend = makeFriend(name: "Alex")

        try await model.acceptDurably(friend)

        #expect(try await repository.load().records == [friend])
        #expect(model.lastPersistenceError == nil)
    }

    @Test("Failed durable acceptance is rolled back and cannot be resurrected")
    @MainActor
    func failedDurableAcceptanceRollsBack() async throws {
        let fileSystem = NativeFriendFailingOnceFileSystem()
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/failed-durable-fixture",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        let existing = makeFriend(name: "Existing")
        let uncommitted = makeFriend(name: "Uncommitted")
        let model = NativeFriendModel(
            repository: repository,
            initialBook: NativeFriendBook(records: [existing])
        )

        do {
            try await model.acceptDurably(uncommitted)
            Issue.record("Expected the durable write to fail")
        } catch {
            #expect(error as? NativeFriendPersistenceError == .saveFailed)
        }
        #expect(!model.book.records.contains(where: { $0.id == uncommitted.id }))

        // A later persistence snapshot must not carry the rejected contact
        // back to disk after the corrective write.
        model.rename(id: existing.id, to: "Renamed Existing")
        await model.flushPendingPersistence()
        let reloaded = try await repository.load()
        #expect(reloaded.records.count == 1)
        #expect(reloaded.records.first?.id == existing.id)
        #expect(reloaded.records.first?.displayName == "Renamed Existing")
    }

    @Test("A staged contact stays hidden until its durable promotion")
    @MainActor
    func pendingCommitIsNotPublishedAsFriend() async throws {
        let fileSystem = NativeFriendMemoryFileSystem()
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/pending-commit-fixture",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        let model = NativeFriendModel(repository: repository)
        var pending = makeFriend(name: "Alex")
        pending.trustState = .pendingCommit

        try await model.acceptDurably(pending)
        #expect(model.presentationSnapshots.isEmpty)
        #expect(model.recordAvailableForJoin(id: pending.id) == nil)

        try await model.promoteDurably(id: pending.id)
        #expect(model.presentationSnapshots.map(\.id) == [pending.id])
        #expect(try await repository.load().records.first?.trustState == .trusted)
    }

    @Test("Failed final promotion remains a hidden pending commit")
    @MainActor
    func failedPromotionDoesNotPublishFriend() async throws {
        let fileSystem = NativeFriendFailingOnceFileSystem(
            shouldFailNextWrite: false
        )
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/failed-promotion-fixture",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        let model = NativeFriendModel(repository: repository)
        var pending = makeFriend(name: "Alex")
        pending.trustState = .pendingCommit
        try await model.acceptDurably(pending)
        await fileSystem.failNextWrite()

        do {
            try await model.promoteDurably(id: pending.id)
            Issue.record("Expected the promotion write to fail")
        } catch {
            #expect(error as? NativeFriendPersistenceError == .saveFailed)
        }
        #expect(model.presentationSnapshots.isEmpty)
        #expect(model.book.records.first?.trustState == .pendingCommit)
        await model.flushPendingPersistence()
        #expect(try await repository.load().records.first?.trustState
            == .pendingCommit)
    }

    @Test("Requester crash after acceptance replays the exact durable acknowledgement")
    @MainActor
    func requesterRecoveryAfterAcceptanceBeforeAcknowledgementSend() async throws {
        let fixture = try NativeFriendHandshakeFixture()
        let fileSystem = NativeFriendMemoryFileSystem()
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/requester-crash-fixture",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        let pending = fixture.requesterRecord(trustState: .pendingCommit)
        let entry = try fixture.entry(role: .requester)
        let firstProcess = NativeFriendModel(repository: repository)

        try await firstProcess.stageRequesterHandshakeDurably(
            record: pending,
            entry: entry
        )

        let restarted = NativeFriendModel(repository: repository)
        await restarted.load(
            localIdentity: fixture.viewerSigner.publicKey,
            at: fixture.now.date
        )
        let recovery = try #require(restarted.requesterHandshakeRecoveries.first)
        #expect(recovery.signedRequest == entry.signedRequest)
        #expect(recovery.signedAcceptance == entry.signedAcceptance)
        #expect(recovery.signedAcknowledgement == entry.signedAcknowledgement)
        #expect(restarted.presentationSnapshots.count == 1)
        #expect(restarted.presentationSnapshots.first?.isFinishingSetup == true)
        #expect(restarted.book.records.first?.trustState == .pendingCommit)

        restarted.setPresence(.live, id: pending.id)
        #expect(restarted.recordAvailableForJoin(id: pending.id) == pending)
    }

    @Test("Pending setup cannot join when its route differs from signed evidence")
    @MainActor
    func requesterRecoveryRequiresJournalPinnedRoute() throws {
        let fixture = try NativeFriendHandshakeFixture()
        let entry = try fixture.entry(role: .requester)
        var mismatched = fixture.requesterRecord(trustState: .pendingCommit)
        mismatched.rendezvousID = try ClipLiveShareRendezvousID(
            bytes: Data(
                repeating: 0xEE,
                count: ClipLiveShareNativeV2.rendezvousIDByteCount
            )
        )
        let model = NativeFriendModel(
            repository: try NativeFriendRepository(
                applicationSupportDirectory: URL(
                    fileURLWithPath: "/mismatched-recovery-fixture",
                    isDirectory: true
                )
            ),
            initialBook: NativeFriendBook(
                records: [mismatched],
                handshakeJournal: [entry]
            )
        )

        model.setPresence(.live, id: mismatched.id)

        #expect(model.presentationSnapshots.isEmpty)
        #expect(model.recordAvailableForJoin(id: mismatched.id) == nil)
    }

    @Test("Host crash after ACK recovers evidence and its exact persisted receipt")
    @MainActor
    func accepterRecoveryAfterAcknowledgementBeforeReceiptDelivery() async throws {
        let fixture = try NativeFriendHandshakeFixture()
        let fileSystem = NativeFriendMemoryFileSystem()
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/accepter-crash-fixture",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        let trusted = fixture.accepterRecord()
        let entry = try fixture.entry(role: .accepter)
        let firstProcess = NativeFriendModel(repository: repository)
        try await firstProcess.commitAccepterHandshakeDurably(
            record: trusted,
            entry: entry
        )

        let afterACKCrash = NativeFriendModel(repository: repository)
        await afterACKCrash.load(
            localIdentity: fixture.hostSigner.publicKey,
            at: fixture.now.date
        )
        let recovered = try #require(afterACKCrash.accepterHandshakeRecoveries.first)
        #expect(recovered.signedAcknowledgement == entry.signedAcknowledgement)
        #expect(recovered.signedCommitReceipt == nil)

        try await afterACKCrash.storeCommitReceiptDurably(
            fixture.signedReceipt,
            handshakeID: recovered.id
        )
        let afterReceiptCrash = NativeFriendModel(repository: repository)
        await afterReceiptCrash.load(
            localIdentity: fixture.hostSigner.publicKey,
            at: fixture.now.date
        )
        #expect(
            afterReceiptCrash.accepterHandshakeRecoveries.first?
                .signedCommitReceipt == fixture.signedReceipt
        )
        #expect(afterReceiptCrash.book.records.first?.trustState == .trusted)
    }

    @Test("Receipt promotion and journal removal share one durable snapshot")
    @MainActor
    func requesterReceiptCompletesDurably() async throws {
        let fixture = try NativeFriendHandshakeFixture()
        let fileSystem = NativeFriendMemoryFileSystem()
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/requester-receipt-fixture",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        let model = NativeFriendModel(repository: repository)
        let entry = try fixture.entry(role: .requester)
        let pending = fixture.requesterRecord(trustState: .pendingCommit)
        try await model.stageRequesterHandshakeDurably(record: pending, entry: entry)

        try await model.completeRequesterHandshakeDurably(
            friendID: pending.id,
            handshakeID: entry.id
        )

        let persisted = try await repository.load()
        #expect(persisted.records.first?.trustState == .trusted)
        #expect(persisted.handshakeJournal.isEmpty)
        #expect(model.presentationSnapshots.map(\.id) == [pending.id])
    }

    @Test("Expired recovery is purged and cannot leave a hidden pending contact")
    @MainActor
    func expiredJournalIsPurgedOnLoad() async throws {
        let fixture = try NativeFriendHandshakeFixture()
        let fileSystem = NativeFriendMemoryFileSystem()
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/expired-journal-fixture",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        let pending = fixture.requesterRecord(trustState: .pendingCommit)
        let entry = try fixture.entry(role: .requester)
        try await repository.save(NativeFriendBook(
            records: [pending],
            handshakeJournal: [entry]
        ))

        let model = NativeFriendModel(repository: repository)
        await model.load(
            localIdentity: fixture.viewerSigner.publicKey,
            at: entry.recoveryDeadline.date.addingTimeInterval(1)
        )

        #expect(model.book.handshakeJournal.isEmpty)
        #expect(model.book.records.isEmpty)
        #expect(try await repository.load().handshakeJournal.isEmpty)
        #expect(try await repository.load().records.isEmpty)
    }

    @Test("Failed journal reset restores both evidence and pending contact")
    @MainActor
    func failedJournalResetRollsBackPendingRecord() async throws {
        let fixture = try NativeFriendHandshakeFixture()
        let fileSystem = NativeFriendFailingOnceFileSystem(
            shouldFailNextWrite: false
        )
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/failed-journal-reset-fixture",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        let model = NativeFriendModel(repository: repository)
        let pending = fixture.requesterRecord(trustState: .pendingCommit)
        let entry = try fixture.entry(role: .requester)
        try await model.stageRequesterHandshakeDurably(record: pending, entry: entry)
        await fileSystem.failNextWrite()

        await #expect(throws: NativeFriendPersistenceError.saveFailed) {
            try await model.clearHandshakeJournalDurably()
        }
        #expect(model.book.records == [pending])
        #expect(model.book.handshakeJournal == [entry])
        await model.flushPendingPersistence()
        let reloaded = try await repository.load()
        #expect(reloaded.records == [pending])
        #expect(reloaded.handshakeJournal == [entry])
    }

    @Test("Failed identity-bound clear restores records and journal")
    @MainActor
    func failedClearAllRollsBackEntireBook() async throws {
        let fixture = try NativeFriendHandshakeFixture()
        let fileSystem = NativeFriendFailingOnceFileSystem(
            shouldFailNextWrite: false
        )
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/failed-clear-all-fixture",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        let model = NativeFriendModel(repository: repository)
        let pending = fixture.requesterRecord(trustState: .pendingCommit)
        let entry = try fixture.entry(role: .requester)
        try await model.stageRequesterHandshakeDurably(record: pending, entry: entry)
        await fileSystem.failNextWrite()

        await #expect(throws: NativeFriendPersistenceError.saveFailed) {
            try await model.clearAllDurably()
        }
        #expect(model.book.records == [pending])
        #expect(model.book.handshakeJournal == [entry])
        await model.flushPendingPersistence()
        #expect(try await repository.load() == NativeFriendBook(
            records: [pending],
            handshakeJournal: [entry]
        ))
    }

    @Test("Historical recovery permits ACK after the bound descriptor expired")
    func historicalValidationUsesEachSignedEventTime() throws {
        let fixture = try NativeFriendHandshakeFixture(
            descriptorLifetimeMilliseconds: 30_000,
            requestLifetimeMilliseconds: 120_000,
            acknowledgementOffsetMilliseconds: 60_000
        )
        let entry = try fixture.entry(role: .requester)
        try entry.validate(
            localIdentity: fixture.viewerSigner.publicKey,
            at: fixture.now.adding(milliseconds: 61_000)
        )
    }

    @Test("Upsert preserves the original friendship date")
    func upsertPreservesCreation() throws {
        let originalDate = Date(timeIntervalSince1970: 10)
        let friend = makeFriend(name: "Alex", createdAt: originalDate)
        var book = NativeFriendBook(records: [friend])
        var renamed = friend
        renamed.displayName = "Alexander"
        renamed.lastConnectedAt = Date(timeIntervalSince1970: 50)

        book.upsert(renamed)

        #expect(book.records.count == 1)
        #expect(book.records[0].displayName == "Alexander")
        #expect(book.records[0].createdAt == originalDate)
        #expect(book.records[0].lastConnectedAt == Date(timeIntervalSince1970: 50))
    }

    @Test("Duplicate identities collapse deterministically")
    func duplicateIdentityCollapses() {
        let older = makeFriend(
            name: "Old",
            createdAt: Date(timeIntervalSince1970: 10),
            lastConnectedAt: Date(timeIntervalSince1970: 20)
        )
        var newer = older
        newer.displayName = "New"
        newer.lastConnectedAt = Date(timeIntervalSince1970: 30)

        let book = NativeFriendBook(records: [older, newer])
        #expect(book.records.count == 1)
        #expect(book.records[0].displayName == "New")
    }

    @Test("Block and remove are explicit local trust operations")
    func blockAndRemove() {
        let friend = makeFriend(name: "Alex")
        var book = NativeFriendBook(records: [friend])

        book.setBlocked(true, id: friend.id)
        #expect(book.records[0].trustState == .blocked)
        let removed = book.remove(id: friend.id)
        #expect(removed?.id == friend.id)
        #expect(book.records.isEmpty)
    }

    private func makeFriend(
        name: String,
        createdAt: Date = Date(timeIntervalSince1970: 10),
        lastConnectedAt: Date? = nil
    ) -> NativeFriendRecord {
        let signer = NativeDeviceIdentitySigner()
        return NativeFriendRecord(
            identity: signer.publicKey,
            displayName: name,
            deviceName: "MacBook Pro",
            endpoint: .official,
            rendezvousID: .random(),
            createdAt: createdAt,
            lastConnectedAt: lastConnectedAt
        )
    }
}

private struct NativeFriendHandshakeFixture {
    let hostSigner = ClipLiveShareSoftwareIdentitySigner()
    let viewerSigner = ClipLiveShareSoftwareIdentitySigner()
    let now: ClipLiveShareNativeTimestamp
    let signedDescriptor: ClipLiveShareSignedNativeSessionDescriptor
    let signedRequest: ClipLiveShareSignedNativeFriendMessage
    let signedAcceptance: ClipLiveShareSignedNativeFriendMessage
    let signedAcknowledgement: ClipLiveShareSignedNativeFriendMessage
    let signedReceipt: ClipLiveShareSignedNativeFriendMessage

    init(
        descriptorLifetimeMilliseconds: Int64 = 240_000,
        requestLifetimeMilliseconds: Int64 = 60_000,
        acknowledgementOffsetMilliseconds: Int64 = 0
    ) throws {
        now = try ClipLiveShareNativeTimestamp(millisecondsSince1970: 1_900_000_000_000)
        let endpoint = ClipLiveShareServerEndpoint.localDevelopment
        let rendezvousID = ClipLiveShareRendezvousID.random()
        let sessionID = try ClipLiveShareSessionID(rawValue: "journal-recovery-session")
        let descriptor = try ClipLiveShareNativeSessionDescriptor(
            endpoint: endpoint,
            room: try ClipLiveShareRoomName(rawValue: "JOURNAL-ROOM-001"),
            rendezvousID: rendezvousID,
            hostIdentity: hostSigner.publicKey,
            roomPublicKey: ClipLiveShareRoomIdentity().publicKey,
            sessionID: sessionID,
            issuedAt: now,
            expiresAt: now.adding(milliseconds: descriptorLifetimeMilliseconds),
            stateRevision: ClipLiveShareStateRevision(rawValue: 1)
        )
        signedDescriptor = try ClipLiveShareSignedNativeSessionDescriptor(
            signing: descriptor,
            with: hostSigner
        )
        let request = try ClipLiveShareNativeFriendRequest(
            requestID: .random(),
            sessionID: sessionID,
            sessionDescriptorDigest: descriptor.digest,
            requestedHostFingerprint: hostSigner.publicKey.fingerprint,
            requesterIdentity: viewerSigner.publicKey,
            requesterEndpoint: endpoint,
            requesterRendezvousID: .random(),
            requesterDeviceName: "Viewer Mac",
            issuedAt: now,
            expiresAt: now.adding(milliseconds: requestLifetimeMilliseconds)
        )
        signedRequest = try ClipLiveShareSignedNativeFriendMessage(
            signing: .request(request),
            with: viewerSigner
        )
        let acceptance = try ClipLiveShareNativeFriendAcceptance(
            requestID: request.requestID,
            sessionID: sessionID,
            requestDigest: request.digest,
            accepterIdentity: hostSigner.publicKey,
            requesterFingerprint: viewerSigner.publicKey.fingerprint,
            accepterDisplayName: "Host Person",
            accepterDeviceName: "Host Mac",
            accepterEndpoint: endpoint,
            rendezvousID: rendezvousID,
            acceptedAt: now,
            stateRevision: descriptor.stateRevision
        )
        signedAcceptance = try ClipLiveShareSignedNativeFriendMessage(
            signing: .accepted(acceptance),
            with: hostSigner
        )
        let acknowledgementTime = try now.adding(
            milliseconds: acknowledgementOffsetMilliseconds
        )
        let acknowledgement = try ClipLiveShareNativeFriendAcceptanceAcknowledgement(
            acknowledging: acceptance,
            for: request,
            acknowledgedAt: acknowledgementTime
        )
        signedAcknowledgement = try ClipLiveShareSignedNativeFriendMessage(
            signing: .acceptanceAcknowledged(acknowledgement),
            with: viewerSigner
        )
        let receipt = try ClipLiveShareNativeFriendCommitReceipt(
            committing: acknowledgement,
            acknowledgementDigest: signedAcknowledgement.digest,
            acceptance: acceptance,
            request: request,
            committedAt: acknowledgementTime
        )
        signedReceipt = try ClipLiveShareSignedNativeFriendMessage(
            signing: .commitReceipt(receipt),
            with: hostSigner
        )
    }

    func entry(
        role: NativeFriendHandshakeRole
    ) throws -> NativeFriendHandshakeJournalEntry {
        try NativeFriendHandshakeJournalEntry(
            role: role,
            signedSessionDescriptor: signedDescriptor,
            signedRequest: signedRequest,
            signedAcceptance: signedAcceptance,
            signedAcknowledgement: signedAcknowledgement
        )
    }

    func requesterRecord(
        trustState: NativeFriendTrustState
    ) -> NativeFriendRecord {
        guard case let .accepted(acceptance) = signedAcceptance.message else {
            preconditionFailure()
        }
        return NativeFriendRecord(
            identity: hostSigner.publicKey,
            displayName: acceptance.accepterDisplayName,
            deviceName: acceptance.accepterDeviceName,
            endpoint: acceptance.accepterEndpoint,
            rendezvousID: acceptance.rendezvousID,
            trustState: trustState,
            createdAt: now.date
        )
    }

    func accepterRecord() -> NativeFriendRecord {
        guard case let .request(request) = signedRequest.message else {
            preconditionFailure()
        }
        return NativeFriendRecord(
            identity: viewerSigner.publicKey,
            displayName: request.requesterDeviceName,
            deviceName: request.requesterDeviceName,
            endpoint: request.requesterEndpoint,
            rendezvousID: request.requesterRendezvousID,
            trustState: .trusted,
            createdAt: now.date
        )
    }
}

private actor NativeFriendMemoryFileSystem: AtomicFileSystem {
    private var values: [URL: Data] = [:]

    var lastWrittenData: Data? { values.values.first }

    func dataIfPresent(at url: URL) async throws -> Data? {
        values[url]
    }

    func writeAtomically(_ data: Data, to url: URL) async throws {
        values[url] = data
    }
}

private actor NativeFriendFailingOnceFileSystem: AtomicFileSystem {
    private enum Failure: Error { case intentional }

    private var values: [URL: Data] = [:]
    private var shouldFailNextWrite: Bool

    init(shouldFailNextWrite: Bool = true) {
        self.shouldFailNextWrite = shouldFailNextWrite
    }

    func failNextWrite() {
        shouldFailNextWrite = true
    }

    func dataIfPresent(at url: URL) async throws -> Data? {
        values[url]
    }

    func writeAtomically(_ data: Data, to url: URL) async throws {
        if shouldFailNextWrite {
            shouldFailNextWrite = false
            throw Failure.intentional
        }
        values[url] = data
    }
}
