import ClipCore
import ClipLiveShare
import Foundation

enum NativeFriendTrustState: String, Codable, Equatable, Sendable {
    /// A durably staged requester-side contact that is not user-visible until
    /// the host confirms its matching commit.
    case pendingCommit
    case trusted
    case blocked
}

struct NativeFriendRecord: Codable, Equatable, Identifiable, Sendable {
    let identity: ClipLiveShareIdentityPublicKey
    var displayName: String
    var deviceName: String
    var endpoint: ClipLiveShareServerEndpoint
    var rendezvousID: ClipLiveShareRendezvousID
    var trustState: NativeFriendTrustState
    let createdAt: Date
    var lastConnectedAt: Date?

    var id: String { identity.fingerprint.rawValue }

    init(
        identity: ClipLiveShareIdentityPublicKey,
        displayName: String,
        deviceName: String,
        endpoint: ClipLiveShareServerEndpoint,
        rendezvousID: ClipLiveShareRendezvousID,
        trustState: NativeFriendTrustState = .trusted,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.identity = identity
        self.displayName = Self.normalizedName(displayName, fallback: "Friend")
        self.deviceName = Self.normalizedName(deviceName, fallback: "Mac")
        self.endpoint = endpoint
        self.rendezvousID = rendezvousID
        self.trustState = trustState
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    private static func normalizedName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(128))
    }
}

enum NativeFriendHandshakeRole: String, Codable, Equatable, Sendable {
    case requester
    case accepter
}

/// Bounded crash-recovery evidence for the final friendship commit. Every
/// value is already signed by one of the two devices; no password, private
/// identity material, room secret, or media key is persisted here.
struct NativeFriendHandshakeJournalEntry: Codable, Equatable, Identifiable, Sendable {
    /// Signed commit evidence is replayable only through a newly authenticated
    /// P2P session with the same persistent identities. The protocol messages'
    /// short network validity is checked at their signed event time; this local
    /// retention window bounds restart recovery independently.
    static let recoveryRetentionMilliseconds: Int64 = 7 * 24 * 60 * 60 * 1_000

    let role: NativeFriendHandshakeRole
    let signedSessionDescriptor: ClipLiveShareSignedNativeSessionDescriptor
    let signedRequest: ClipLiveShareSignedNativeFriendMessage
    let signedAcceptance: ClipLiveShareSignedNativeFriendMessage
    let signedAcknowledgement: ClipLiveShareSignedNativeFriendMessage
    var signedCommitReceipt: ClipLiveShareSignedNativeFriendMessage?

    var id: String { "\(role.rawValue):\(request.requestID.rawValue)" }
    var recoveryDeadline: ClipLiveShareNativeTimestamp {
        // The initializer rejects timestamp overflow below.
        try! acknowledgement.acknowledgedAt.adding(
            milliseconds: Self.recoveryRetentionMilliseconds
        )
    }
    var counterpartyIdentity: ClipLiveShareIdentityPublicKey {
        switch role {
        case .requester: acceptance.accepterIdentity
        case .accepter: request.requesterIdentity
        }
    }

    var request: ClipLiveShareNativeFriendRequest {
        guard case let .request(value) = signedRequest.message else {
            preconditionFailure("Journal request type was validated at initialization")
        }
        return value
    }

    var acceptance: ClipLiveShareNativeFriendAcceptance {
        guard case let .accepted(value) = signedAcceptance.message else {
            preconditionFailure("Journal acceptance type was validated at initialization")
        }
        return value
    }

    var acknowledgement: ClipLiveShareNativeFriendAcceptanceAcknowledgement {
        guard case let .acceptanceAcknowledged(value) = signedAcknowledgement.message else {
            preconditionFailure("Journal acknowledgement type was validated at initialization")
        }
        return value
    }

    init(
        role: NativeFriendHandshakeRole,
        signedSessionDescriptor: ClipLiveShareSignedNativeSessionDescriptor,
        signedRequest: ClipLiveShareSignedNativeFriendMessage,
        signedAcceptance: ClipLiveShareSignedNativeFriendMessage,
        signedAcknowledgement: ClipLiveShareSignedNativeFriendMessage,
        signedCommitReceipt: ClipLiveShareSignedNativeFriendMessage? = nil
    ) throws {
        guard case let .request(request) = signedRequest.message,
              case let .accepted(acceptance) = signedAcceptance.message,
              case let .acceptanceAcknowledged(acknowledgement) =
                signedAcknowledgement.message,
              request.requestID == acceptance.requestID,
              request.requestID == acknowledgement.requestID else {
            throw ClipLiveShareNativeV2Error.contextMismatch
        }
        _ = try acknowledgement.acknowledgedAt.adding(
            milliseconds: Self.recoveryRetentionMilliseconds
        )
        if let signedCommitReceipt {
            guard case let .commitReceipt(receipt) = signedCommitReceipt.message,
                  receipt.requestID == request.requestID else {
                throw ClipLiveShareNativeV2Error.contextMismatch
            }
        }
        self.role = role
        self.signedSessionDescriptor = signedSessionDescriptor
        self.signedRequest = signedRequest
        self.signedAcceptance = signedAcceptance
        self.signedAcknowledgement = signedAcknowledgement
        self.signedCommitReceipt = signedCommitReceipt
    }

    /// Revalidates every signature, identity, session, endpoint, revision and
    /// expiry boundary after decoding untrusted disk contents.
    func validate(
        localIdentity: ClipLiveShareIdentityPublicKey,
        at now: ClipLiveShareNativeTimestamp
    ) throws {
        guard now < recoveryDeadline else {
            throw ClipLiveShareNativeV2Error.expired
        }
        try Self.validateNotImplausiblyFuture(
            acknowledgement.acknowledgedAt,
            relativeTo: now
        )
        let descriptor = signedSessionDescriptor.descriptor
        // Reproduce the live protocol's temporal checkpoints instead of
        // pretending the short-lived descriptor remained active through the
        // entire commit: the request binds its digest at request time, while
        // acceptance/ACK/receipt each prove their own later event boundary.
        try signedSessionDescriptor.verify(
            expectedIdentity: descriptor.hostIdentity,
            expectedContext: descriptor.rendezvousContext,
            at: request.issuedAt
        )
        try signedRequest.verifySignature(expectedIdentity: request.requesterIdentity)
        try request.validate(
            expectedSessionDescriptor: descriptor,
            expectedHostIdentity: descriptor.hostIdentity,
            at: acceptance.acceptedAt
        )
        try signedAcceptance.verifySignature(expectedIdentity: acceptance.accepterIdentity)
        try acceptance.validate(
            for: request,
            expectedSessionDescriptor: descriptor,
            at: acknowledgement.acknowledgedAt
        )
        try signedAcknowledgement.verifySignature(
            expectedIdentity: acknowledgement.requesterIdentity
        )
        try acknowledgement.validate(
            for: acceptance,
            request: request,
            expectedSessionDescriptor: descriptor,
            at: acknowledgement.acknowledgedAt
        )
        switch role {
        case .requester:
            guard localIdentity == request.requesterIdentity else {
                throw ClipLiveShareNativeV2Error.identityMismatch
            }
        case .accepter:
            guard localIdentity == acceptance.accepterIdentity else {
                throw ClipLiveShareNativeV2Error.identityMismatch
            }
        }
        if let signedCommitReceipt {
            guard case let .commitReceipt(receipt) = signedCommitReceipt.message else {
                throw ClipLiveShareNativeV2Error.contextMismatch
            }
            try Self.validateNotImplausiblyFuture(receipt.committedAt, relativeTo: now)
            try signedCommitReceipt.verifySignature(
                expectedIdentity: acceptance.accepterIdentity
            )
            try receipt.validate(
                for: acknowledgement,
                acknowledgementDigest: signedAcknowledgement.digest,
                acceptance: acceptance,
                request: request,
                expectedSessionDescriptor: descriptor,
                at: receipt.committedAt
            )
        }
    }

    private static func validateNotImplausiblyFuture(
        _ timestamp: ClipLiveShareNativeTimestamp,
        relativeTo now: ClipLiveShareNativeTimestamp
    ) throws {
        let (latest, overflow) = now.millisecondsSince1970.addingReportingOverflow(
            ClipLiveShareNativeV2.maximumClockSkewMilliseconds
        )
        guard overflow || timestamp.millisecondsSince1970 <= latest else {
            throw ClipLiveShareNativeV2Error.notYetValid
        }
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case signedSessionDescriptor
        case signedRequest
        case signedAcceptance
        case signedAcknowledgement
        case signedCommitReceipt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            role: container.decode(NativeFriendHandshakeRole.self, forKey: .role),
            signedSessionDescriptor: container.decode(
                ClipLiveShareSignedNativeSessionDescriptor.self,
                forKey: .signedSessionDescriptor
            ),
            signedRequest: container.decode(
                ClipLiveShareSignedNativeFriendMessage.self,
                forKey: .signedRequest
            ),
            signedAcceptance: container.decode(
                ClipLiveShareSignedNativeFriendMessage.self,
                forKey: .signedAcceptance
            ),
            signedAcknowledgement: container.decode(
                ClipLiveShareSignedNativeFriendMessage.self,
                forKey: .signedAcknowledgement
            ),
            signedCommitReceipt: container.decodeIfPresent(
                ClipLiveShareSignedNativeFriendMessage.self,
                forKey: .signedCommitReceipt
            )
        )
    }
}

struct NativeFriendBook: Codable, Equatable, Sendable {
    static let maximumHandshakeJournalEntries = 16

    private(set) var records: [NativeFriendRecord]
    private(set) var handshakeJournal: [NativeFriendHandshakeJournalEntry]

    init(
        records: [NativeFriendRecord] = [],
        handshakeJournal: [NativeFriendHandshakeJournalEntry] = []
    ) {
        var newestByID: [String: NativeFriendRecord] = [:]
        for record in records {
            if let current = newestByID[record.id] {
                let currentDate = current.lastConnectedAt ?? current.createdAt
                let newDate = record.lastConnectedAt ?? record.createdAt
                if newDate >= currentDate { newestByID[record.id] = record }
            } else {
                newestByID[record.id] = record
            }
        }
        self.records = newestByID.values.sorted(by: Self.order)
        self.handshakeJournal = []
        for entry in handshakeJournal {
            upsertHandshake(entry)
        }
    }

    mutating func upsert(_ record: NativeFriendRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            var replacement = record
            replacement = NativeFriendRecord(
                identity: record.identity,
                displayName: record.displayName,
                deviceName: record.deviceName,
                endpoint: record.endpoint,
                rendezvousID: record.rendezvousID,
                trustState: record.trustState,
                createdAt: records[index].createdAt,
                lastConnectedAt: record.lastConnectedAt ?? records[index].lastConnectedAt
            )
            records[index] = replacement
        } else {
            records.append(record)
        }
        records.sort(by: Self.order)
    }

    @discardableResult
    mutating func remove(id: String) -> NativeFriendRecord? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = records.remove(at: index)
        handshakeJournal.removeAll { $0.counterpartyIdentity == removed.identity }
        return removed
    }

    mutating func setBlocked(_ blocked: Bool, id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].trustState = blocked ? .blocked : .trusted
        if blocked {
            let identity = records[index].identity
            handshakeJournal.removeAll { $0.counterpartyIdentity == identity }
        }
    }

    mutating func rename(_ name: String, id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index] = NativeFriendRecord(
            identity: records[index].identity,
            displayName: name,
            deviceName: records[index].deviceName,
            endpoint: records[index].endpoint,
            rendezvousID: records[index].rendezvousID,
            trustState: records[index].trustState,
            createdAt: records[index].createdAt,
            lastConnectedAt: records[index].lastConnectedAt
        )
        records.sort(by: Self.order)
    }

    mutating func upsertHandshake(_ entry: NativeFriendHandshakeJournalEntry) {
        handshakeJournal.removeAll { $0.id == entry.id }
        handshakeJournal.append(entry)
        handshakeJournal.sort(by: Self.handshakeOrder)
        if handshakeJournal.count > Self.maximumHandshakeJournalEntries {
            handshakeJournal.removeFirst(
                handshakeJournal.count - Self.maximumHandshakeJournalEntries
            )
        }
    }

    @discardableResult
    mutating func removeHandshake(id: String) -> NativeFriendHandshakeJournalEntry? {
        guard let index = handshakeJournal.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return handshakeJournal.remove(at: index)
    }

    mutating func removeAllHandshakes() {
        handshakeJournal.removeAll()
    }

    /// Invalid, expired, foreign-identity, or state-orphaned evidence is never
    /// exposed to retry logic. A requester-side pending record without valid
    /// evidence is also removed so it cannot remain hidden forever.
    @discardableResult
    mutating func validateHandshakeJournal(
        localIdentity: ClipLiveShareIdentityPublicKey,
        at now: ClipLiveShareNativeTimestamp
    ) -> Bool {
        let previousEntries = handshakeJournal
        let previousRecords = records
        handshakeJournal = handshakeJournal.filter { entry in
            guard (try? entry.validate(localIdentity: localIdentity, at: now)) != nil else {
                return false
            }
            return records.contains { record in
                record.identity == entry.counterpartyIdentity
                    && (entry.role == .requester
                        ? record.trustState == .pendingCommit
                        : record.trustState == .trusted)
            }
        }
        let requesterFriendIDs = Set(
            handshakeJournal
                .filter { $0.role == .requester }
                .map { $0.counterpartyIdentity.fingerprint.rawValue }
        )
        records.removeAll {
            $0.trustState == .pendingCommit && !requesterFriendIDs.contains($0.id)
        }
        return previousEntries != handshakeJournal || previousRecords != records
    }

    private enum CodingKeys: String, CodingKey {
        case records
        case handshakeJournal
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            records: try container.decodeIfPresent(
                [NativeFriendRecord].self,
                forKey: .records
            ) ?? [],
            handshakeJournal: try container.decodeIfPresent(
                [NativeFriendHandshakeJournalEntry].self,
                forKey: .handshakeJournal
            ) ?? []
        )
    }

    private static func order(_ lhs: NativeFriendRecord, _ rhs: NativeFriendRecord) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func handshakeOrder(
        _ lhs: NativeFriendHandshakeJournalEntry,
        _ rhs: NativeFriendHandshakeJournalEntry
    ) -> Bool {
        if lhs.recoveryDeadline != rhs.recoveryDeadline {
            return lhs.recoveryDeadline < rhs.recoveryDeadline
        }
        return lhs.id < rhs.id
    }
}

actor NativeFriendRepository {
    private let store: AtomicJSONFileStore<NativeFriendBook>

    init(
        applicationSupportDirectory: URL,
        fileSystem: any AtomicFileSystem = LocalAtomicFileSystem()
    ) throws {
        store = try AtomicJSONFileStore(
            fileURL: applicationSupportDirectory
                .appendingPathComponent("native-friends.json"),
            fileSystem: fileSystem
        )
    }

    func load() async throws -> NativeFriendBook {
        try await store.load() ?? NativeFriendBook()
    }

    func save(_ book: NativeFriendBook) async throws {
        try await store.save(book)
    }
}
