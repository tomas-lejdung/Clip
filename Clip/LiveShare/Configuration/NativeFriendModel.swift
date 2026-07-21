import Combine
import ClipLiveShare
import Foundation

enum NativeFriendPersistenceError: Error, Equatable, Sendable {
    case saveFailed
}

@MainActor
final class NativeFriendModel: ObservableObject {
    private let repository: NativeFriendRepository
    private var persistenceTail: Task<Void, Never>?
    private var presenceByID: [String: LiveShareFriendPresence] = [:]
    private var durableAcceptanceTokens: [String: UUID] = [:]
    private var durableHandshakeTokens: [String: UUID] = [:]

    @Published private(set) var book: NativeFriendBook
    @Published private(set) var presentationRevision = 0
    @Published private(set) var isLoaded = false
    @Published private(set) var lastPersistenceError: String?

    init(
        repository: NativeFriendRepository,
        initialBook: NativeFriendBook = NativeFriendBook()
    ) {
        self.repository = repository
        book = initialBook
    }

    func load(
        localIdentity: ClipLiveShareIdentityPublicKey? = nil,
        at date: Date = Date()
    ) async {
        do {
            var loaded = try await repository.load()
            if let localIdentity,
               let timestamp = try? ClipLiveShareNativeTimestamp(date: date),
               loaded.validateHandshakeJournal(
                    localIdentity: localIdentity,
                    at: timestamp
               ) {
                try await repository.save(loaded)
            } else if localIdentity == nil {
                // Without the Keychain identity no persisted proof can be
                // authenticated as local. Keep ordinary trusted contacts, but
                // fail closed for recovery evidence and hidden pending rows.
                loaded.removeAllHandshakes()
                for record in loaded.records where record.trustState == .pendingCommit {
                    loaded.remove(id: record.id)
                }
            }
            book = loaded
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = String(localized: "Friends could not be loaded.")
        }
        presentationRevision &+= 1
        isLoaded = true
    }

    var presentationSnapshots: [LiveShareFriendViewSnapshot] {
        book.records
            .filter {
                $0.trustState == .trusted || hasRequesterRecovery(for: $0)
            }
            .map { record in
                LiveShareFriendViewSnapshot(
                    id: record.id,
                    displayName: record.displayName,
                    deviceName: record.deviceName,
                    presence: presenceByID[record.id] ?? .offline,
                    isFinishingSetup: record.trustState == .pendingCommit
                )
            }
    }

    func recordAvailableForJoin(id: String) -> NativeFriendRecord? {
        guard presenceByID[id] == .live else { return nil }
        guard let record = book.records.first(where: { $0.id == id }) else {
            return nil
        }
        return record.trustState == .trusted || hasRequesterRecovery(for: record)
            ? record
            : nil
    }

    var recordsEligibleForPresenceProbe: [NativeFriendRecord] {
        book.records.filter {
            $0.trustState == .trusted || hasRequesterRecovery(for: $0)
        }
    }

    func accept(_ record: NativeFriendRecord) {
        book.upsert(record)
        presenceByID[record.id] = .offline
        presentationRevision &+= 1
        enqueuePersistence()
    }

    /// Upserts a friend and returns only after that exact book snapshot has
    /// been atomically written. Later model mutations queue behind this write,
    /// so callers can safely emit a remote commit acknowledgement afterward.
    func acceptDurably(_ record: NativeFriendRecord) async throws {
        let token = UUID()
        let previousRecord = book.records.first { $0.id == record.id }
        let previousPresence = presenceByID[record.id]
        durableAcceptanceTokens[record.id] = token
        book.upsert(record)
        presenceByID[record.id] = .offline
        presentationRevision &+= 1

        let previous = persistenceTail
        let snapshot = book
        let repository = repository
        let saveTask = Task { @MainActor in
            await previous?.value
            do {
                try await repository.save(snapshot)
                return true
            } catch {
                return false
            }
        }
        // Reserve the persistence chain before suspending. Any rename, block,
        // removal, or later acceptance therefore observes this write as its
        // predecessor and cannot race an older snapshot over it.
        persistenceTail = Task { @MainActor in
            _ = await saveTask.value
        }

        guard await saveTask.value else {
            lastPersistenceError = String(localized: "Friends could not be saved.")
            if durableAcceptanceTokens[record.id] == token {
                durableAcceptanceTokens[record.id] = nil
                if var previousRecord {
                    // Preserve user changes made to the same existing friend
                    // while the durable route update was in flight.
                    if let current = book.records.first(where: { $0.id == record.id }) {
                        if current.displayName != record.displayName {
                            previousRecord.displayName = current.displayName
                        }
                        if current.trustState != record.trustState {
                            previousRecord.trustState = current.trustState
                        }
                        previousRecord.lastConnectedAt = current.lastConnectedAt
                    }
                    book.upsert(previousRecord)
                } else {
                    book.remove(id: record.id)
                }
                if presenceByID[record.id] == .offline {
                    presenceByID[record.id] = previousPresence
                }
                presentationRevision &+= 1
                // Later UI mutations may already have queued snapshots that
                // contain the uncommitted friend. Queue a corrective snapshot
                // behind all of them so it cannot be resurrected on disk.
                enqueuePersistence()
            }
            throw NativeFriendPersistenceError.saveFailed
        }
        if durableAcceptanceTokens[record.id] == token {
            durableAcceptanceTokens[record.id] = nil
        }
        lastPersistenceError = nil
    }

    func promoteDurably(id: String) async throws {
        guard var record = book.records.first(where: { $0.id == id }) else {
            throw NativeFriendPersistenceError.saveFailed
        }
        guard record.trustState != .trusted else { return }
        record.trustState = .trusted
        try await acceptDurably(record)
    }

    /// Atomically stages the hidden requester-side contact and all exact
    /// signed evidence needed to retransmit its acknowledgement after restart.
    func stageRequesterHandshakeDurably(
        record: NativeFriendRecord,
        entry: NativeFriendHandshakeJournalEntry
    ) async throws {
        guard record.trustState == .pendingCommit,
              entry.role == .requester,
              record.identity == entry.counterpartyIdentity else {
            throw NativeFriendPersistenceError.saveFailed
        }
        try await upsertRecordAndHandshakeDurably(record: record, entry: entry)
    }

    /// Atomically commits the host-side trusted contact with the request,
    /// acceptance, and exact acknowledgement that authorized that commit.
    func commitAccepterHandshakeDurably(
        record: NativeFriendRecord,
        entry: NativeFriendHandshakeJournalEntry
    ) async throws {
        guard record.trustState == .trusted,
              entry.role == .accepter,
              record.identity == entry.counterpartyIdentity else {
            throw NativeFriendPersistenceError.saveFailed
        }
        try await upsertRecordAndHandshakeDurably(record: record, entry: entry)
    }

    /// Stores the exact signed receipt before delivery. Host recovery can then
    /// replay it byte-for-byte; requester recovery can validate it after a
    /// process boundary without manufacturing any new protocol statement.
    func storeCommitReceiptDurably(
        _ signedReceipt: ClipLiveShareSignedNativeFriendMessage,
        handshakeID: String
    ) async throws {
        guard var current = book.handshakeJournal.first(where: { $0.id == handshakeID }) else {
            throw NativeFriendPersistenceError.saveFailed
        }
        let previous = current
        do {
            current = try NativeFriendHandshakeJournalEntry(
                role: current.role,
                signedSessionDescriptor: current.signedSessionDescriptor,
                signedRequest: current.signedRequest,
                signedAcceptance: current.signedAcceptance,
                signedAcknowledgement: current.signedAcknowledgement,
                signedCommitReceipt: signedReceipt
            )
        } catch {
            throw NativeFriendPersistenceError.saveFailed
        }
        let token = UUID()
        durableHandshakeTokens[handshakeID] = token
        book.upsertHandshake(current)
        presentationRevision &+= 1
        guard await saveDurableSnapshot() else {
            lastPersistenceError = String(localized: "Friends could not be saved.")
            if durableHandshakeTokens[handshakeID] == token,
               book.handshakeJournal.first(where: { $0.id == handshakeID }) == current {
                durableHandshakeTokens[handshakeID] = nil
                book.upsertHandshake(previous)
                presentationRevision &+= 1
                enqueuePersistence()
            }
            throw NativeFriendPersistenceError.saveFailed
        }
        if durableHandshakeTokens[handshakeID] == token {
            durableHandshakeTokens[handshakeID] = nil
        }
        lastPersistenceError = nil
    }

    /// The requester publishes the contact and removes retry evidence in one
    /// local atomic file replacement after validating the host receipt.
    func completeRequesterHandshakeDurably(
        friendID: String,
        handshakeID: String
    ) async throws {
        guard var record = book.records.first(where: { $0.id == friendID }),
              record.trustState == .pendingCommit,
              let previousEntry = book.handshakeJournal.first(where: {
                  $0.id == handshakeID && $0.role == .requester
              }) else {
            throw NativeFriendPersistenceError.saveFailed
        }
        let previousRecord = record
        record.trustState = .trusted
        let token = UUID()
        durableAcceptanceTokens[friendID] = token
        durableHandshakeTokens[handshakeID] = token
        book.upsert(record)
        book.removeHandshake(id: handshakeID)
        presentationRevision &+= 1
        guard await saveDurableSnapshot() else {
            lastPersistenceError = String(localized: "Friends could not be saved.")
            if durableAcceptanceTokens[friendID] == token,
               book.records.first(where: { $0.id == friendID }) == record {
                durableAcceptanceTokens[friendID] = nil
                book.upsert(previousRecord)
            }
            if durableHandshakeTokens[handshakeID] == token,
               !book.handshakeJournal.contains(where: { $0.id == handshakeID }) {
                durableHandshakeTokens[handshakeID] = nil
                book.upsertHandshake(previousEntry)
            }
            presentationRevision &+= 1
            enqueuePersistence()
            throw NativeFriendPersistenceError.saveFailed
        }
        if durableAcceptanceTokens[friendID] == token {
            durableAcceptanceTokens[friendID] = nil
        }
        if durableHandshakeTokens[handshakeID] == token {
            durableHandshakeTokens[handshakeID] = nil
        }
        lastPersistenceError = nil
    }

    func removeHandshakeDurably(id: String) async throws {
        guard let previous = book.removeHandshake(id: id) else { return }
        let token = UUID()
        durableHandshakeTokens[id] = token
        presentationRevision &+= 1
        guard await saveDurableSnapshot() else {
            lastPersistenceError = String(localized: "Friends could not be saved.")
            if durableHandshakeTokens[id] == token,
               !book.handshakeJournal.contains(where: { $0.id == id }) {
                durableHandshakeTokens[id] = nil
                book.upsertHandshake(previous)
                presentationRevision &+= 1
                enqueuePersistence()
            }
            throw NativeFriendPersistenceError.saveFailed
        }
        if durableHandshakeTokens[id] == token {
            durableHandshakeTokens[id] = nil
        }
        lastPersistenceError = nil
    }

    func clearHandshakeJournalDurably() async throws {
        let previous = book.handshakeJournal
        guard !previous.isEmpty else { return }
        let previousPendingRecords = book.records.filter {
            $0.trustState == .pendingCommit
        }
        book.removeAllHandshakes()
        for record in book.records where record.trustState == .pendingCommit {
            book.remove(id: record.id)
        }
        presentationRevision &+= 1
        guard await saveDurableSnapshot() else {
            lastPersistenceError = String(localized: "Friends could not be saved.")
            for record in previousPendingRecords { book.upsert(record) }
            for entry in previous { book.upsertHandshake(entry) }
            presentationRevision &+= 1
            enqueuePersistence()
            throw NativeFriendPersistenceError.saveFailed
        }
        lastPersistenceError = nil
    }

    /// Clears all identity-bound trust and recovery state in one durable file
    /// replacement. Identity rotation must await this operation so a failed
    /// friend-book write can never report a successful reset and resurrect old
    /// trust on the next launch.
    func clearAllDurably() async throws {
        let previousBook = book
        let previousPresence = presenceByID
        guard !previousBook.records.isEmpty
            || !previousBook.handshakeJournal.isEmpty else { return }
        book = NativeFriendBook()
        presenceByID.removeAll()
        presentationRevision &+= 1
        guard await saveDurableSnapshot() else {
            lastPersistenceError = String(localized: "Friends could not be saved.")
            book = previousBook
            presenceByID = previousPresence
            presentationRevision &+= 1
            enqueuePersistence()
            throw NativeFriendPersistenceError.saveFailed
        }
        durableAcceptanceTokens.removeAll()
        durableHandshakeTokens.removeAll()
        lastPersistenceError = nil
    }

    var requesterHandshakeRecoveries: [NativeFriendHandshakeJournalEntry] {
        activeHandshakeRecoveries(role: .requester)
    }

    var accepterHandshakeRecoveries: [NativeFriendHandshakeJournalEntry] {
        activeHandshakeRecoveries(role: .accepter)
    }

    func rename(id: String, to name: String) {
        book.rename(name, id: id)
        presentationRevision &+= 1
        enqueuePersistence()
    }

    func setBlocked(_ blocked: Bool, id: String) {
        book.setBlocked(blocked, id: id)
        presenceByID[id] = .offline
        presentationRevision &+= 1
        enqueuePersistence()
    }

    func remove(id: String) {
        guard book.remove(id: id) != nil else { return }
        presenceByID[id] = nil
        presentationRevision &+= 1
        enqueuePersistence()
    }

    func setPresence(_ presence: LiveShareFriendPresence, id: String) {
        guard let record = book.records.first(where: { $0.id == id }),
              presence == .offline
                || record.trustState == .trusted
                || hasRequesterRecovery(for: record),
              presenceByID[id] != presence else { return }
        presenceByID[id] = presence
        presentationRevision &+= 1
    }

    func markConnected(id: String, at date: Date = Date()) {
        guard let current = book.records.first(where: { $0.id == id }) else { return }
        var updated = current
        updated.lastConnectedAt = date
        book.upsert(updated)
        presentationRevision &+= 1
        enqueuePersistence()
    }

    func flushPendingPersistence() async {
        await persistenceTail?.value
    }

    private func hasRequesterRecovery(for record: NativeFriendRecord) -> Bool {
        guard record.trustState == .pendingCommit else { return false }
        return requesterHandshakeRecoveries.contains {
            $0.counterpartyIdentity == record.identity
                && $0.acceptance.accepterEndpoint == record.endpoint
                && $0.acceptance.rendezvousID == record.rendezvousID
        }
    }

    private func enqueuePersistence() {
        let previous = persistenceTail
        let snapshot = book
        let repository = repository
        let task = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await repository.save(snapshot)
                self?.lastPersistenceError = nil
            } catch {
                self?.lastPersistenceError = String(localized: "Friends could not be saved.")
            }
        }
        persistenceTail = task
    }

    private func upsertRecordAndHandshakeDurably(
        record: NativeFriendRecord,
        entry: NativeFriendHandshakeJournalEntry
    ) async throws {
        let previousRecord = book.records.first { $0.id == record.id }
        let previousEntry = book.handshakeJournal.first { $0.id == entry.id }
        let previousPresence = presenceByID[record.id]
        let token = UUID()
        durableAcceptanceTokens[record.id] = token
        durableHandshakeTokens[entry.id] = token
        book.upsert(record)
        book.upsertHandshake(entry)
        presenceByID[record.id] = .offline
        presentationRevision &+= 1

        guard await saveDurableSnapshot() else {
            lastPersistenceError = String(localized: "Friends could not be saved.")
            if durableAcceptanceTokens[record.id] == token,
               book.records.first(where: { $0.id == record.id }) == record {
                durableAcceptanceTokens[record.id] = nil
                if let previousRecord {
                    book.upsert(previousRecord)
                } else {
                    book.remove(id: record.id)
                }
                if presenceByID[record.id] == .offline {
                    presenceByID[record.id] = previousPresence
                }
            }
            if durableHandshakeTokens[entry.id] == token,
               book.handshakeJournal.first(where: { $0.id == entry.id }) == entry {
                durableHandshakeTokens[entry.id] = nil
                if let previousEntry {
                    book.upsertHandshake(previousEntry)
                } else {
                    book.removeHandshake(id: entry.id)
                }
            }
            presentationRevision &+= 1
            enqueuePersistence()
            throw NativeFriendPersistenceError.saveFailed
        }
        if durableAcceptanceTokens[record.id] == token {
            durableAcceptanceTokens[record.id] = nil
        }
        if durableHandshakeTokens[entry.id] == token {
            durableHandshakeTokens[entry.id] = nil
        }
        lastPersistenceError = nil
    }

    private func saveDurableSnapshot() async -> Bool {
        let previous = persistenceTail
        let snapshot = book
        let repository = repository
        let saveTask = Task { @MainActor in
            await previous?.value
            do {
                try await repository.save(snapshot)
                return true
            } catch {
                return false
            }
        }
        persistenceTail = Task { @MainActor in
            _ = await saveTask.value
        }
        return await saveTask.value
    }

    private func activeHandshakeRecoveries(
        role: NativeFriendHandshakeRole,
        at date: Date = Date()
    ) -> [NativeFriendHandshakeJournalEntry] {
        guard let now = try? ClipLiveShareNativeTimestamp(date: date) else {
            return []
        }
        return book.handshakeJournal.filter {
            $0.role == role && now < $0.recoveryDeadline
        }
    }
}
