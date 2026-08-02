import ClipLiveShare
import Foundation

enum MeshFriendTrustState: String, Codable, Equatable, Sendable {
    /// The requester has durably staged the accepted identity but has not yet
    /// received the accepter's signed durable-commit receipt.
    case pendingCommit
    case trusted
}

struct MeshFriendRecord: Codable, Equatable, Identifiable, Sendable {
    let profile: ClipLiveShareServerRoomV4FriendProfile
    /// Unique mailbox owned by this device for publishing presence to this
    /// one friend. A different friendship receives a different routing ID and
    /// encryption key, preventing the service from correlating the graph.
    let localPublishingLocator: ClipLiveShareServerRoomV4FriendLocator
    var trustState: MeshFriendTrustState
    let createdAt: Date
    var lastConfirmedAt: Date?
    /// A local-only label. It is deliberately outside the signed profile so
    /// renaming a friend never changes or impersonates their authenticated
    /// identity, and it is never published through presence or signaling.
    var localAlias: String?

    init(
        profile: ClipLiveShareServerRoomV4FriendProfile,
        localPublishingLocator: ClipLiveShareServerRoomV4FriendLocator,
        trustState: MeshFriendTrustState,
        createdAt: Date,
        lastConfirmedAt: Date?,
        localAlias: String? = nil
    ) {
        self.profile = profile
        self.localPublishingLocator = localPublishingLocator
        self.trustState = trustState
        self.createdAt = createdAt
        self.lastConfirmedAt = lastConfirmedAt
        self.localAlias = localAlias
    }

    var id: String { profile.identity.fingerprint.rawValue }
    var identity: ClipLiveShareIdentityPublicKey { profile.identity }
    var displayName: String { localAlias ?? profile.displayName }
    var deviceName: String { profile.deviceName }

    /// Alias-only edits must not restart encrypted presence polling or erase
    /// a verified invite/backoff schedule.
    func hasSamePresenceConfiguration(as other: Self) -> Bool {
        profile == other.profile
            && localPublishingLocator == other.localPublishingLocator
            && trustState == other.trustState
            && createdAt == other.createdAt
            && lastConfirmedAt == other.lastConfirmedAt
    }
}

enum MeshFriendAliasPolicy {
    static let maximumCharacterCount = 80
    static let maximumUTF8ByteCount =
        ClipLiveShareServerRoomV4Friends.maximumDisplayNameBytes

    static func normalize(_ proposed: String) throws -> String? {
        let value = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.count <= maximumCharacterCount,
              value.utf8.count <= maximumUTF8ByteCount,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw MeshFriendshipRepositoryError.invalidAlias
        }
        return value
    }
}

enum MeshFriendshipHandshakeRole: String, Codable, Equatable, Sendable {
    case requester
    case accepter
}

/// Bounded, signed evidence retained for crash recovery and idempotent replay.
/// No room secret, invite fragment, SDP, ICE, media key, or private identity
/// material is stored here.
struct MeshFriendshipJournalEntry: Codable, Equatable, Identifiable, Sendable {
    let role: MeshFriendshipHandshakeRole
    let signedRequest: ClipLiveShareServerRoomV4SignedFriendMessage
    var signedAcceptance: ClipLiveShareServerRoomV4SignedFriendMessage?
    var signedDecline: ClipLiveShareServerRoomV4SignedFriendMessage?
    var signedAcknowledgement: ClipLiveShareServerRoomV4SignedFriendMessage?
    var signedCommitReceipt: ClipLiveShareServerRoomV4SignedFriendMessage?
    let createdAt: Date
    var updatedAt: Date

    var id: String {
        "\(role.rawValue):\(signedRequest.message.requestID.rawValue)"
    }

    var requestID: ClipLiveShareServerRoomV4FriendRequestID {
        signedRequest.message.requestID
    }

    /// Exact locally-authored response that is safe to resend after an
    /// ambiguous DataChannel send or pair reconnect. Never return the remote
    /// commit receipt to the requester as though it authored that receipt.
    var lastRecoverableOutboundMessage:
        ClipLiveShareServerRoomV4SignedFriendMessage?
    {
        switch role {
        case .requester:
            signedAcknowledgement
        case .accepter:
            signedCommitReceipt ?? signedDecline ?? signedAcceptance
        }
    }
}

struct MeshFriendshipRepositorySnapshot: Equatable, Sendable {
    let friends: [MeshFriendRecord]
    let recoveryJournal: [MeshFriendshipJournalEntry]
}

enum MeshFriendshipRepositoryError: Error, Equatable, Sendable,
    LocalizedError
{
    case corruptStore
    case identityChanged
    case invalidHandshake
    case invalidAlias
    case missingHandshake
    case replayedRequest
    case storageLimitReached

    var errorDescription: String? {
        switch self {
        case .corruptStore:
            "The saved friends list is damaged."
        case .identityChanged:
            "The saved friends list belongs to another device identity."
        case .invalidHandshake:
            "The friend request handshake is invalid."
        case .invalidAlias:
            "Friend names must be 80 characters or fewer and cannot contain control characters."
        case .missingHandshake:
            "The friend request is no longer pending."
        case .replayedRequest:
            "The friend request was already completed or rejected."
        case .storageLimitReached:
            "The friends list has reached its safe storage limit."
        }
    }
}

protocol MeshFriendshipStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// Atomic application-support storage for public friend profiles and signed
/// recovery evidence. Private device identity material remains in Keychain.
final class LiveMeshFriendshipFileStorage: MeshFriendshipStorage,
    @unchecked Sendable
{
    static let relativePath = "LiveShare/friends-v4.json"
    private static let maximumPayloadBytes = 2 * 1_024 * 1_024

    let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default
    ) {
        fileURL = applicationSupportDirectory.appendingPathComponent(
            Self.relativePath,
            isDirectory: false
        )
        self.fileManager = fileManager
    }

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> Data? {
        try lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let attributes = try fileManager.attributesOfItem(
                atPath: fileURL.path
            )
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue <= Self.maximumPayloadBytes else {
                throw MeshFriendshipRepositoryError.corruptStore
            }
            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        }
    }

    func save(_ data: Data) throws {
        guard data.count <= Self.maximumPayloadBytes else {
            throw MeshFriendshipRepositoryError.storageLimitReached
        }
        try lock.withLock {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            // Friends live in the sandboxed Application Support container on
            // macOS. `.completeFileProtection` is an iOS-style data-protection
            // request and can make an otherwise writable macOS container
            // intermittently reject the atomic replacement. The payload
            // contains public profiles and signed recovery evidence only;
            // private identity material remains in Keychain. Keep the durable
            // atomic write and explicit owner-only filesystem permissions.
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
        }
    }
}

actor MeshFriendshipRepository {
    private struct RejectedOrCompletedRequest: Codable, Equatable, Sendable {
        let requestID: ClipLiveShareServerRoomV4FriendRequestID
        let expiresAt: Date
    }

    private struct StoredState: Codable, Equatable, Sendable {
        static let version = 4

        let version: Int
        let ownerFingerprint: ClipLiveShareIdentityFingerprint
        var friends: [MeshFriendRecord]
        var journal: [MeshFriendshipJournalEntry]
        var replayTombstones: [RejectedOrCompletedRequest]
    }

    private static let maximumFriends = 256
    private static let maximumJournalEntries = 128
    private static let maximumReplayTombstones = 256

    private let storage: any MeshFriendshipStorage
    private let localIdentity: ClipLiveShareIdentityPublicKey
    private let now: @Sendable () -> Date
    private var cachedState: StoredState?

    init(
        storage: any MeshFriendshipStorage,
        localIdentity: ClipLiveShareIdentityPublicKey,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.storage = storage
        self.localIdentity = localIdentity
        self.now = now
    }

    func snapshot() throws -> MeshFriendshipRepositorySnapshot {
        let state = try loadOrCreate()
        return .init(
            friends: state.friends.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            },
            recoveryJournal: state.journal.sorted { $0.createdAt < $1.createdAt }
        )
    }

    /// Creates one unpublished directional mailbox for a new friendship.
    /// The caller embeds it in its signed profile; it becomes durable only as
    /// part of that exact handshake/friend record.
    func makeLocalPublishingLocator()
        -> ClipLiveShareServerRoomV4FriendLocator
    {
        .random()
    }

    func friend(
        with identity: ClipLiveShareIdentityPublicKey
    ) throws -> MeshFriendRecord? {
        try loadOrCreate().friends.first { $0.identity == identity }
    }

    /// Records a locally signed request before it crosses the DataChannel.
    /// Repeating the exact request is idempotent; a conflicting request using
    /// the same random ID is rejected.
    func recordOutgoingRequest(
        _ signedRequest: ClipLiveShareServerRoomV4SignedFriendMessage
    ) throws {
        guard case let .request(request) = signedRequest.message,
              signedRequest.signerIdentity == localIdentity else {
            throw MeshFriendshipRepositoryError.invalidHandshake
        }
        try signedRequest.verify()
        try insertInitialJournal(
            role: .requester,
            signedRequest: signedRequest,
            expectedRequest: request
        )
    }

    /// Records an authenticated peer's request before showing Allow/Deny.
    func recordIncomingRequest(
        _ signedRequest: ClipLiveShareServerRoomV4SignedFriendMessage
    ) throws {
        guard case let .request(request) = signedRequest.message,
              request.expectedAccepterFingerprint == localIdentity.fingerprint,
              signedRequest.signerIdentity != localIdentity else {
            throw MeshFriendshipRepositoryError.invalidHandshake
        }
        try signedRequest.verify()
        try insertInitialJournal(
            role: .accepter,
            signedRequest: signedRequest,
            expectedRequest: request
        )
    }

    /// Persists the signed acceptance before sending it. A duplicate request
    /// can then return this exact byte-equivalent signed response.
    func recordAcceptance(
        _ signedAcceptance: ClipLiveShareServerRoomV4SignedFriendMessage,
        requestID: ClipLiveShareServerRoomV4FriendRequestID
    ) throws {
        try signedAcceptance.verify()
        try updateJournal(requestID: requestID, role: .accepter) { entry in
            guard case let .request(request) = entry.signedRequest.message,
                  case let .acceptance(acceptance) = signedAcceptance.message,
                  signedAcceptance.signerIdentity == localIdentity else {
                throw MeshFriendshipRepositoryError.invalidHandshake
            }
            try acceptance.validate(
                for: request,
                at: try ClipLiveShareNativeTimestamp(date: now())
            )
            if let existing = entry.signedAcceptance,
               existing != signedAcceptance {
                throw MeshFriendshipRepositoryError.replayedRequest
            }
            entry.signedAcceptance = signedAcceptance
            entry.updatedAt = now()
        }
    }

    /// Persists a signed denial before it crosses the DataChannel. Keeping the
    /// exact response in the bounded journal lets a duplicate request recover
    /// deterministically after an ambiguous send.
    func recordOutgoingDecline(
        _ signedDecline: ClipLiveShareServerRoomV4SignedFriendMessage,
        requestID: ClipLiveShareServerRoomV4FriendRequestID
    ) throws {
        try signedDecline.verify()
        try mutate { state in
            let index = try journalIndex(
                requestID: requestID,
                role: .accepter,
                in: state
            )
            var entry = state.journal[index]
            guard case let .request(request) = entry.signedRequest.message,
                  case let .decline(decline) = signedDecline.message,
                  signedDecline.signerIdentity == localIdentity,
                  entry.signedAcceptance == nil,
                  entry.signedAcknowledgement == nil,
                  entry.signedCommitReceipt == nil else {
                throw MeshFriendshipRepositoryError.invalidHandshake
            }
            try decline.validate(
                for: request,
                at: try ClipLiveShareNativeTimestamp(date: now())
            )
            if let existing = entry.signedDecline,
               existing != signedDecline {
                throw MeshFriendshipRepositoryError.replayedRequest
            }
            entry.signedDecline = signedDecline
            entry.updatedAt = now()
            state.journal[index] = entry
            insertReplayTombstone(requestID, at: now(), in: &state)
        }
    }

    /// Records the authenticated peer's decision and clears the requester's
    /// pending state without ever creating a friendship record.
    func recordIncomingDecline(
        _ signedDecline: ClipLiveShareServerRoomV4SignedFriendMessage,
        requestID: ClipLiveShareServerRoomV4FriendRequestID
    ) throws {
        try signedDecline.verify()
        try mutate { state in
            let index = try journalIndex(
                requestID: requestID,
                role: .requester,
                in: state
            )
            var entry = state.journal[index]
            guard case let .request(request) = entry.signedRequest.message,
                  case let .decline(decline) = signedDecline.message,
                  entry.signedAcceptance == nil,
                  entry.signedAcknowledgement == nil,
                  entry.signedCommitReceipt == nil,
                  signedDecline.signerIdentity == decline.accepterIdentity
            else {
                throw MeshFriendshipRepositoryError.invalidHandshake
            }
            try decline.validate(
                for: request,
                at: try ClipLiveShareNativeTimestamp(date: now())
            )
            if let existing = entry.signedDecline,
               existing != signedDecline {
                throw MeshFriendshipRepositoryError.replayedRequest
            }
            entry.signedDecline = signedDecline
            entry.updatedAt = now()
            state.journal[index] = entry
            insertReplayTombstone(requestID, at: now(), in: &state)
        }
    }

    /// Atomically stages the remote identity as pending and journals the exact
    /// acknowledgement before the requester sends it.
    func stageOutgoingAcknowledgement(
        _ signedAcknowledgement: ClipLiveShareServerRoomV4SignedFriendMessage,
        acceptance signedAcceptance: ClipLiveShareServerRoomV4SignedFriendMessage,
        requestID: ClipLiveShareServerRoomV4FriendRequestID
    ) throws {
        try signedAcceptance.verify()
        try signedAcknowledgement.verify()
        try mutate { state in
            let index = try journalIndex(
                requestID: requestID,
                role: .requester,
                in: state
            )
            var entry = state.journal[index]
            guard case let .request(request) = entry.signedRequest.message,
                  case let .acceptance(acceptance) = signedAcceptance.message,
                  case let .acknowledgement(acknowledgement) =
                    signedAcknowledgement.message,
                  signedAcknowledgement.signerIdentity == localIdentity else {
                throw MeshFriendshipRepositoryError.invalidHandshake
            }
            let timestamp = try ClipLiveShareNativeTimestamp(date: now())
            try acceptance.validate(for: request, at: timestamp)
            try acknowledgement.validate(
                request: request,
                acceptance: acceptance,
                at: timestamp
            )
            guard signedAcceptance.signerIdentity == acceptance.accepter.identity else {
                throw MeshFriendshipRepositoryError.invalidHandshake
            }
            if let existing = entry.signedAcknowledgement,
               existing != signedAcknowledgement {
                throw MeshFriendshipRepositoryError.replayedRequest
            }
            entry.signedAcceptance = signedAcceptance
            entry.signedAcknowledgement = signedAcknowledgement
            entry.updatedAt = now()
            state.journal[index] = entry
            try upsertFriend(
                profile: acceptance.accepter,
                localPublishingLocator: request.requester.locator,
                trustState: .pendingCommit,
                at: now(),
                in: &state
            )
        }
    }

    /// The accepter's durable commit: trusted profile and signed receipt are
    /// saved in one atomic file replacement before the receipt may be sent.
    func commitIncomingFriendship(
        receipt signedReceipt: ClipLiveShareServerRoomV4SignedFriendMessage,
        acknowledgement signedAcknowledgement: ClipLiveShareServerRoomV4SignedFriendMessage,
        requestID: ClipLiveShareServerRoomV4FriendRequestID
    ) throws {
        try signedAcknowledgement.verify()
        try signedReceipt.verify()
        try mutate { state in
            let index = try journalIndex(
                requestID: requestID,
                role: .accepter,
                in: state
            )
            var entry = state.journal[index]
            guard case let .request(request) = entry.signedRequest.message,
                  let signedAcceptance = entry.signedAcceptance,
                  case let .acceptance(acceptance) = signedAcceptance.message,
                  case let .acknowledgement(acknowledgement) =
                    signedAcknowledgement.message,
                  case let .commitReceipt(receipt) = signedReceipt.message,
                  signedReceipt.signerIdentity == localIdentity else {
                throw MeshFriendshipRepositoryError.invalidHandshake
            }
            try entry.signedRequest.verify()
            try signedAcceptance.verify()
            guard entry.signedRequest.signerIdentity == request.requester.identity,
                  signedAcceptance.signerIdentity == localIdentity,
                  signedAcknowledgement.signerIdentity
                    == request.requester.identity else {
                throw MeshFriendshipRepositoryError.invalidHandshake
            }
            try receipt.validate(
                request: request,
                acceptance: acceptance,
                acknowledgement: acknowledgement,
                at: try ClipLiveShareNativeTimestamp(date: now())
            )
            if let existing = entry.signedCommitReceipt,
               existing != signedReceipt {
                throw MeshFriendshipRepositoryError.replayedRequest
            }
            entry.signedAcknowledgement = signedAcknowledgement
            entry.signedCommitReceipt = signedReceipt
            entry.updatedAt = now()
            state.journal[index] = entry
            try upsertFriend(
                profile: request.requester,
                localPublishingLocator: acceptance.accepter.locator,
                trustState: .trusted,
                at: now(),
                in: &state
            )
            insertReplayTombstone(requestID, at: now(), in: &state)
        }
    }

    /// The requester promotes its explicitly pending record only after the
    /// accepter's signed durable-commit receipt validates.
    func commitOutgoingFriendship(
        receipt signedReceipt: ClipLiveShareServerRoomV4SignedFriendMessage,
        requestID: ClipLiveShareServerRoomV4FriendRequestID
    ) throws {
        try signedReceipt.verify()
        try mutate { state in
            let index = try journalIndex(
                requestID: requestID,
                role: .requester,
                in: state
            )
            var entry = state.journal[index]
            guard case let .request(request) = entry.signedRequest.message,
                  let signedAcceptance = entry.signedAcceptance,
                  let signedAcknowledgement = entry.signedAcknowledgement,
                  case let .acceptance(acceptance) = signedAcceptance.message,
                  case let .acknowledgement(acknowledgement) =
                    signedAcknowledgement.message,
                  case let .commitReceipt(receipt) = signedReceipt.message else {
                throw MeshFriendshipRepositoryError.invalidHandshake
            }
            try entry.signedRequest.verify()
            try signedAcceptance.verify()
            try signedAcknowledgement.verify()
            guard entry.signedRequest.signerIdentity == localIdentity,
                  signedAcceptance.signerIdentity
                    == acceptance.accepter.identity,
                  signedAcknowledgement.signerIdentity == localIdentity else {
                throw MeshFriendshipRepositoryError.invalidHandshake
            }
            try receipt.validate(
                request: request,
                acceptance: acceptance,
                acknowledgement: acknowledgement,
                at: try ClipLiveShareNativeTimestamp(date: now())
            )
            guard signedReceipt.signerIdentity == acceptance.accepter.identity else {
                throw MeshFriendshipRepositoryError.invalidHandshake
            }
            entry.signedCommitReceipt = signedReceipt
            entry.updatedAt = now()
            state.journal[index] = entry
            try upsertFriend(
                profile: acceptance.accepter,
                localPublishingLocator: request.requester.locator,
                trustState: .trusted,
                at: now(),
                in: &state
            )
            insertReplayTombstone(requestID, at: now(), in: &state)
        }
    }

    func recoverableReply(
        for requestID: ClipLiveShareServerRoomV4FriendRequestID
    ) throws -> ClipLiveShareServerRoomV4SignedFriendMessage? {
        try loadOrCreate().journal
            .first { $0.requestID == requestID }?
            .lastRecoverableOutboundMessage
    }

    func reject(
        _ requestID: ClipLiveShareServerRoomV4FriendRequestID
    ) throws {
        try mutate { state in
            state.journal.removeAll { $0.requestID == requestID }
            insertReplayTombstone(requestID, at: now(), in: &state)
        }
    }

    func removeFriend(
        identity: ClipLiveShareIdentityPublicKey
    ) throws {
        try mutate { state in
            state.friends.removeAll { $0.identity == identity }
        }
    }

    /// Atomically changes only the local presentation alias. Passing an empty
    /// or whitespace-only value restores the signed profile name.
    func renameFriend(
        identity: ClipLiveShareIdentityPublicKey,
        to proposedAlias: String
    ) throws {
        let alias = try MeshFriendAliasPolicy.normalize(proposedAlias)
        try mutate { state in
            guard let index = state.friends.firstIndex(where: {
                $0.identity == identity
            }) else {
                throw MeshFriendshipRepositoryError.missingHandshake
            }
            state.friends[index].localAlias = alias
        }
    }

    @discardableResult
    func pruneExpiredRecovery() throws -> Bool {
        let cutoff = now()
        var changed = false
        try mutate { state in
            let journalCount = state.journal.count
            state.journal.removeAll {
                $0.updatedAt.addingTimeInterval(
                    Double(ClipLiveShareServerRoomV4Friends
                        .maximumRecoveryRetentionMilliseconds) / 1_000
                ) <= cutoff
            }
            let replayCount = state.replayTombstones.count
            state.replayTombstones.removeAll { $0.expiresAt <= cutoff }
            changed = journalCount != state.journal.count
                || replayCount != state.replayTombstones.count
        }
        return changed
    }

    private func insertInitialJournal(
        role: MeshFriendshipHandshakeRole,
        signedRequest: ClipLiveShareServerRoomV4SignedFriendMessage,
        expectedRequest: ClipLiveShareServerRoomV4FriendRequest
    ) throws {
        try mutate { state in
            pruneReplayTombstones(at: now(), in: &state)
            if let existing = state.journal.first(where: {
                $0.requestID == expectedRequest.requestID
            }) {
                guard existing.role == role,
                      existing.signedRequest == signedRequest else {
                    throw MeshFriendshipRepositoryError.replayedRequest
                }
                return
            }
            if state.replayTombstones.contains(where: {
                $0.requestID == expectedRequest.requestID
            }) {
                throw MeshFriendshipRepositoryError.replayedRequest
            }
            guard state.journal.count < Self.maximumJournalEntries else {
                throw MeshFriendshipRepositoryError.storageLimitReached
            }
            state.journal.append(.init(
                role: role,
                signedRequest: signedRequest,
                signedAcceptance: nil,
                signedDecline: nil,
                signedAcknowledgement: nil,
                signedCommitReceipt: nil,
                createdAt: now(),
                updatedAt: now()
            ))
        }
    }

    private func updateJournal(
        requestID: ClipLiveShareServerRoomV4FriendRequestID,
        role: MeshFriendshipHandshakeRole,
        update: (inout MeshFriendshipJournalEntry) throws -> Void
    ) throws {
        try mutate { state in
            let index = try journalIndex(
                requestID: requestID,
                role: role,
                in: state
            )
            try update(&state.journal[index])
        }
    }

    private func journalIndex(
        requestID: ClipLiveShareServerRoomV4FriendRequestID,
        role: MeshFriendshipHandshakeRole,
        in state: StoredState
    ) throws -> Int {
        guard let index = state.journal.firstIndex(where: {
            $0.requestID == requestID && $0.role == role
        }) else {
            throw MeshFriendshipRepositoryError.missingHandshake
        }
        return index
    }

    private func upsertFriend(
        profile: ClipLiveShareServerRoomV4FriendProfile,
        localPublishingLocator: ClipLiveShareServerRoomV4FriendLocator,
        trustState: MeshFriendTrustState,
        at timestamp: Date,
        in state: inout StoredState
    ) throws {
        if let index = state.friends.firstIndex(where: {
            $0.identity == profile.identity
        }) {
            let existing = state.friends[index]
            // A new, incomplete handshake must not rotate a previously
            // trusted friendship's directional presence mailboxes. The new
            // locators become authoritative only with the signed commit
            // receipt that promotes the replacement to `.trusted`.
            if existing.trustState == .trusted,
               trustState == .pendingCommit {
                return
            }
            state.friends[index] = .init(
                profile: profile,
                localPublishingLocator: localPublishingLocator,
                trustState: trustState == .trusted
                    ? .trusted
                    : existing.trustState,
                createdAt: existing.createdAt,
                lastConfirmedAt: trustState == .trusted
                    ? timestamp
                    : existing.lastConfirmedAt,
                localAlias: existing.localAlias
            )
            return
        }
        guard state.friends.count < Self.maximumFriends else {
            throw MeshFriendshipRepositoryError.storageLimitReached
        }
        state.friends.append(.init(
            profile: profile,
            localPublishingLocator: localPublishingLocator,
            trustState: trustState,
            createdAt: timestamp,
            lastConfirmedAt: trustState == .trusted ? timestamp : nil
        ))
    }

    private func insertReplayTombstone(
        _ requestID: ClipLiveShareServerRoomV4FriendRequestID,
        at timestamp: Date,
        in state: inout StoredState
    ) {
        pruneReplayTombstones(at: timestamp, in: &state)
        state.replayTombstones.removeAll { $0.requestID == requestID }
        state.replayTombstones.append(.init(
            requestID: requestID,
            expiresAt: timestamp.addingTimeInterval(
                Double(ClipLiveShareServerRoomV4Friends
                    .maximumRecoveryRetentionMilliseconds) / 1_000
            )
        ))
        if state.replayTombstones.count > Self.maximumReplayTombstones {
            state.replayTombstones.sort { $0.expiresAt < $1.expiresAt }
            state.replayTombstones.removeFirst(
                state.replayTombstones.count - Self.maximumReplayTombstones
            )
        }
    }

    private func pruneReplayTombstones(
        at timestamp: Date,
        in state: inout StoredState
    ) {
        state.replayTombstones.removeAll { $0.expiresAt <= timestamp }
    }

    private func loadOrCreate() throws -> StoredState {
        if let cachedState { return cachedState }
        if let data = try storage.load() {
            do {
                let decoded = try JSONDecoder().decode(StoredState.self, from: data)
                guard decoded.version == StoredState.version else {
                    throw MeshFriendshipRepositoryError.corruptStore
                }
                guard decoded.ownerFingerprint == localIdentity.fingerprint else {
                    throw MeshFriendshipRepositoryError.identityChanged
                }
                guard decoded.friends.count <= Self.maximumFriends,
                      decoded.journal.count <= Self.maximumJournalEntries,
                      decoded.replayTombstones.count
                        <= Self.maximumReplayTombstones else {
                    throw MeshFriendshipRepositoryError.corruptStore
                }
                cachedState = decoded
                return decoded
            } catch let error as MeshFriendshipRepositoryError {
                throw error
            } catch {
                throw MeshFriendshipRepositoryError.corruptStore
            }
        }
        let initial = StoredState(
            version: StoredState.version,
            ownerFingerprint: localIdentity.fingerprint,
            friends: [],
            journal: [],
            replayTombstones: []
        )
        try storage.save(try encode(initial))
        cachedState = initial
        return initial
    }

    private func mutate(
        _ mutation: (inout StoredState) throws -> Void
    ) throws {
        var proposed = try loadOrCreate()
        try mutation(&proposed)
        try storage.save(try encode(proposed))
        cachedState = proposed
    }

    private func encode(_ state: StoredState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(state)
    }
}
