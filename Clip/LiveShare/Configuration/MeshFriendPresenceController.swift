import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation

/// The deliberately narrow network surface used by friend presence. The
/// rendezvous service receives only a per-friend routing ID and opaque bytes.
protocol MeshFriendPresenceTransport: Sendable {
  func publishFriendPresence(
    at endpoint: URL,
    encryptedPresence: ClipLiveShareServerRoomV4EncryptedFriendPresence
  ) async throws

  func friendPresence(
    at endpoint: URL,
    routingID: ClipLiveShareServerRoomV4FriendRoutingID
  ) async throws -> ClipLiveShareServerRoomV4EncryptedFriendPresence?
}

extension ClipLiveShareServerRoomV4HTTPClient: MeshFriendPresenceTransport {}

enum MeshFriendPresenceAvailability: Equatable, Sendable {
  case offline
  case online
}

struct MeshFriendPresenceSnapshot: Equatable, Identifiable, Sendable,
  CustomStringConvertible
{
  let id: String
  let identity: ClipLiveShareIdentityPublicKey
  let displayName: String
  let deviceName: String
  let availability: MeshFriendPresenceAvailability
  /// Present only after decrypting the friend-only mailbox and pinning the
  /// publisher's persistent identity and this device as the recipient.
  let verifiedInvite: ClipLiveShareServerRoomV4Invite?
  let lastSeenAt: Date?
  let lastCheckedAt: Date?
  let retryAfter: Date?
  let issue: String?

  var description: String {
    "MeshFriendPresenceSnapshot(id: \(id), availability: \(availability), "
      + "invite: <redacted>, issue: \(issue == nil ? "none" : "present"))"
  }
}

struct MeshFriendPresenceControllerSnapshot: Equatable, Sendable,
  CustomStringConvertible
{
  let friends: [MeshFriendPresenceSnapshot]

  var onlineFriends: [MeshFriendPresenceSnapshot] {
    friends.filter { $0.availability == .online }
  }

  var description: String {
    "MeshFriendPresenceControllerSnapshot(friends: \(friends.count), "
      + "online: \(onlineFriends.count), invites: <redacted>)"
  }
}

struct MeshFriendPresenceTiming: Equatable, Sendable {
  static let production = Self(
    presenceLifetime: 45,
    publicationRefreshInterval: 15,
    pollInterval: 5,
    initialFailureBackoff: 2,
    maximumFailureBackoff: 60,
    idleLoopInterval: 5
  )

  let presenceLifetime: TimeInterval
  let publicationRefreshInterval: TimeInterval
  let pollInterval: TimeInterval
  let initialFailureBackoff: TimeInterval
  let maximumFailureBackoff: TimeInterval
  let idleLoopInterval: TimeInterval

  init(
    presenceLifetime: TimeInterval,
    publicationRefreshInterval: TimeInterval,
    pollInterval: TimeInterval,
    initialFailureBackoff: TimeInterval,
    maximumFailureBackoff: TimeInterval,
    idleLoopInterval: TimeInterval
  ) {
    precondition(
      presenceLifetime > 0
        && presenceLifetime
          <= TimeInterval(
            ClipLiveShareServerRoomV4FriendPresence
              .maximumLifetimeMilliseconds
          ) / 1_000
    )
    precondition(
      publicationRefreshInterval > 0
        && publicationRefreshInterval < presenceLifetime
        && pollInterval > 0
        && initialFailureBackoff > 0
        && maximumFailureBackoff >= initialFailureBackoff
        && idleLoopInterval > 0
    )
    self.presenceLifetime = presenceLifetime
    self.publicationRefreshInterval = publicationRefreshInterval
    self.pollInterval = pollInterval
    self.initialFailureBackoff = initialFailureBackoff
    self.maximumFailureBackoff = maximumFailureBackoff
    self.idleLoopInterval = idleLoopInterval
  }
}

enum MeshFriendPresenceControllerError: Error, Equatable, Sendable,
  LocalizedError
{
  case duplicateDirectionalMailbox
  case revisionExhausted

  var errorDescription: String? {
    switch self {
    case .duplicateDirectionalMailbox:
      "A friend presence mailbox was reused. Remove and add the friend again."
    case .revisionExhausted:
      "The friend presence revision is exhausted."
    }
  }
}

/// Owns saved-friend room discovery independently from the active mesh.
///
/// The directional endpoint rule is easy to accidentally invert:
///
/// - Publish `record.localPublishingLocator` at *this device's* configured
///   `localPresenceServiceEndpoint`.
/// - Poll `record.profile.locator` at the remote profile's signed
///   `presenceServiceEndpoint`.
///
/// Every friendship has two unique mailboxes, one for each direction. There is
/// no global presence mailbox, and no identity, name, or invite is passed to
/// `MeshFriendPresenceTransport` in plaintext.
actor MeshFriendPresenceController {
  typealias FriendLoader = @Sendable () async throws -> [MeshFriendRecord]
  typealias SnapshotObserver = @MainActor @Sendable (
    MeshFriendPresenceControllerSnapshot
  ) -> Void
  typealias Sleeper = @Sendable (Duration) async throws -> Void

  private struct FriendState: Sendable {
    var record: MeshFriendRecord
    var verifiedInvite: ClipLiveShareServerRoomV4Invite?
    var verifiedPresenceExpiresAt: Date?
    var lastSeenAt: Date?
    var lastCheckedAt: Date?
    var lastSeenRevision: UInt64?
    var lastPublishedRevision: UInt64?
    var nextPollAt: Date?
    var nextPublishAt: Date?
    var pollFailureCount = 0
    var publishFailureCount = 0
    var pollIssue: String?
    var publishIssue: String?
    var mailboxIsInvalid = false
  }

  private let signer: any ClipLiveShareIdentitySigner
  private let localPresenceServiceEndpoint: ClipLiveShareRendezvousEndpoint
  private let transport: any MeshFriendPresenceTransport
  private let loadFriends: FriendLoader
  private let timing: MeshFriendPresenceTiming
  private let now: @Sendable () -> Date
  private let sleep: Sleeper
  private let onSnapshotChanged: SnapshotObserver

  private var currentInvite: ClipLiveShareServerRoomV4Invite?
  private var states: [String: FriendState] = [:]
  private var loopTask: Task<Void, Never>?
  private var isSynchronizing = false
  private var synchronizationRequested = false
  private var inviteGeneration: UInt64 = 0
  private var lastEmittedSnapshot: MeshFriendPresenceControllerSnapshot?

  init(
    signer: any ClipLiveShareIdentitySigner,
    repository: MeshFriendshipRepository,
    localPresenceServiceEndpoint: ClipLiveShareRendezvousEndpoint,
    transport: any MeshFriendPresenceTransport =
      ClipLiveShareServerRoomV4HTTPClient(),
    timing: MeshFriendPresenceTiming = .production,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping Sleeper = { duration in
      try await Task.sleep(for: duration)
    },
    onSnapshotChanged: @escaping SnapshotObserver = { _ in }
  ) {
    self.signer = signer
    self.localPresenceServiceEndpoint = localPresenceServiceEndpoint
    self.transport = transport
    loadFriends = {
      try await repository.snapshot().friends
    }
    self.timing = timing
    self.now = now
    self.sleep = sleep
    self.onSnapshotChanged = onSnapshotChanged
  }

  /// Test and composition seam that avoids manufacturing friendship
  /// handshakes merely to exercise the presence scheduler.
  init(
    signer: any ClipLiveShareIdentitySigner,
    loadFriends: @escaping FriendLoader,
    localPresenceServiceEndpoint: ClipLiveShareRendezvousEndpoint,
    transport: any MeshFriendPresenceTransport,
    timing: MeshFriendPresenceTiming = .production,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping Sleeper = { duration in
      try await Task.sleep(for: duration)
    },
    onSnapshotChanged: @escaping SnapshotObserver = { _ in }
  ) {
    self.signer = signer
    self.loadFriends = loadFriends
    self.localPresenceServiceEndpoint = localPresenceServiceEndpoint
    self.transport = transport
    self.timing = timing
    self.now = now
    self.sleep = sleep
    self.onSnapshotChanged = onSnapshotChanged
  }

  deinit {
    loopTask?.cancel()
  }

  func start(currentInvite: ClipLiveShareServerRoomV4Invite?) {
    updateCurrentInvite(currentInvite)
    guard loopTask == nil else { return }
    loopTask = Task { [weak self] in
      await self?.runLoop()
    }
  }

  /// Stops all polling and refresh work. Published records intentionally
  /// contain no server-side deletion credential, so they disappear through
  /// their short bounded expiry (45 seconds in production) instead of
  /// exposing a global account or identity-bearing delete API.
  func stop() {
    loopTask?.cancel()
    loopTask = nil
    currentInvite = nil
    inviteGeneration &+= 1
    synchronizationRequested = false
  }

  func updateCurrentInvite(
    _ invite: ClipLiveShareServerRoomV4Invite?
  ) {
    let oldURL = canonicalURL(of: currentInvite)
    let newURL = canonicalURL(of: invite)
    currentInvite = invite
    guard oldURL != newURL else { return }
    inviteGeneration &+= 1
    synchronizationRequested = true
    for id in states.keys {
      states[id]?.nextPublishAt = nil
      states[id]?.publishIssue = nil
    }
  }

  private func canonicalURL(
    of invite: ClipLiveShareServerRoomV4Invite?
  ) -> String? {
    guard let invite else { return nil }
    return try? invite.url.absoluteString
  }

  func snapshot() -> MeshFriendPresenceControllerSnapshot {
    expireVerifiedPresence(at: now())
    return makeSnapshot()
  }

  /// Runs one complete bounded reconciliation. This is public to the app
  /// layer so friendship changes and explicit invite rotation can be made
  /// visible immediately instead of waiting for the periodic loop.
  func synchronizeNow() async {
    if isSynchronizing {
      synchronizationRequested = true
      return
    }
    isSynchronizing = true
    repeat {
      synchronizationRequested = false
      await synchronizePass(at: now())
    } while synchronizationRequested && !Task.isCancelled
    isSynchronizing = false
  }

  private func runLoop() async {
    while !Task.isCancelled {
      await synchronizeNow()
      let seconds = max(0.25, nextLoopDelay(at: now()))
      do {
        try await sleep(.milliseconds(Int64(seconds * 1_000)))
      } catch {
        return
      }
    }
  }

  private func synchronizePass(at timestamp: Date) async {
    let records: [MeshFriendRecord]
    do {
      records = try await loadFriends().filter { $0.trustState == .trusted }
    } catch {
      await emitSnapshot()
      return
    }

    reconcile(records: records)
    expireVerifiedPresence(at: timestamp)
    for id in states.keys.sorted() {
      guard var state = states[id] else { continue }
      if state.mailboxIsInvalid {
        states[id] = state
        continue
      }
      if let invite = currentInvite,
        state.nextPublishAt.map({ $0 <= timestamp }) ?? true
      {
        let generation = inviteGeneration
        await publish(invite: invite, state: &state, at: timestamp)
        if generation != inviteGeneration {
          state.nextPublishAt = nil
          synchronizationRequested = true
        }
      }
      if state.nextPollAt.map({ $0 <= timestamp }) ?? true {
        await poll(state: &state, at: timestamp)
      }
      states[id] = state
    }
    await emitSnapshot()
  }

  private func reconcile(records: [MeshFriendRecord]) {
    var recordsByID: [String: MeshFriendRecord] = [:]
    var duplicateIdentityIDs: Set<String> = []
    for record in records {
      if recordsByID.updateValue(record, forKey: record.id) != nil {
        duplicateIdentityIDs.insert(record.id)
      }
    }
    states = states.filter { recordsByID[$0.key] != nil }
    for record in records {
      if var existing = states[record.id] {
        if existing.record == record { continue }
        if existing.record.hasSamePresenceConfiguration(as: record) {
          // A rename changes presentation only. Preserve verified presence,
          // polling cadence, failures and backoff rather than making the
          // friend briefly appear offline.
          existing.record = record
          states[record.id] = existing
          continue
        }
      }
      states[record.id] = FriendState(record: record)
    }

    var owners: [ClipLiveShareServerRoomV4FriendRoutingID: [String]] = [:]
    for record in records {
      owners[record.localPublishingLocator.routingID, default: []]
        .append(record.id)
      owners[record.profile.locator.routingID, default: []]
        .append(record.id)
    }
    let invalidIDs = duplicateIdentityIDs.union(
      owners.values
        .filter { $0.count > 1 }
        .flatMap { $0 }
    )
    for id in states.keys {
      states[id]?.mailboxIsInvalid = invalidIDs.contains(id)
      if invalidIDs.contains(id) {
        states[id]?.publishIssue =
          MeshFriendPresenceControllerError
          .duplicateDirectionalMailbox.localizedDescription
        states[id]?.pollIssue =
          MeshFriendPresenceControllerError
          .duplicateDirectionalMailbox.localizedDescription
        states[id]?.verifiedInvite = nil
        states[id]?.verifiedPresenceExpiresAt = nil
      }
    }
  }

  private func publish(
    invite: ClipLiveShareServerRoomV4Invite,
    state: inout FriendState,
    at timestamp: Date
  ) async {
    do {
      if state.lastPublishedRevision == nil,
        let existing = try await transport.friendPresence(
          at: localPresenceServiceEndpoint.rootURL,
          routingID: state.record.localPublishingLocator.routingID
        )
      {
        state.lastPublishedRevision = existing.revision
      }
      var revision = try nextRevision(
        after: state.lastPublishedRevision,
        at: timestamp
      )
      do {
        try await sealAndPublish(
          invite: invite,
          revision: revision,
          state: state,
          at: timestamp
        )
      } catch ClipLiveShareServerRoomV4TransportError
        .friendPresenceRevisionConflict
      {
        guard
          let existing = try await transport.friendPresence(
            at: localPresenceServiceEndpoint.rootURL,
            routingID: state.record.localPublishingLocator.routingID
          )
        else {
          throw ClipLiveShareServerRoomV4TransportError
            .friendPresenceRevisionConflict
        }
        revision = try nextRevision(after: existing.revision, at: timestamp)
        try await sealAndPublish(
          invite: invite,
          revision: revision,
          state: state,
          at: timestamp
        )
      }
      state.lastPublishedRevision = revision
      state.publishFailureCount = 0
      state.publishIssue = nil
      state.nextPublishAt = timestamp.addingTimeInterval(
        timing.publicationRefreshInterval
      )
    } catch {
      state.publishFailureCount += 1
      state.publishIssue = error.localizedDescription
      state.nextPublishAt = timestamp.addingTimeInterval(
        failureBackoff(attempt: state.publishFailureCount)
      )
    }
  }

  private func sealAndPublish(
    invite: ClipLiveShareServerRoomV4Invite,
    revision: UInt64,
    state: FriendState,
    at timestamp: Date
  ) async throws {
    let issuedAt = try ClipLiveShareNativeTimestamp(date: timestamp)
    let expiresAt = try issuedAt.adding(
      milliseconds: Int64(timing.presenceLifetime * 1_000)
    )
    let encrypted = try ClipLiveShareServerRoomV4FriendPresenceCrypto.seal(
      invite: invite,
      revision: revision,
      publisherSigner: signer,
      recipientIdentity: state.record.identity,
      locator: state.record.localPublishingLocator,
      issuedAt: issuedAt,
      expiresAt: expiresAt
    )
    try await transport.publishFriendPresence(
      at: localPresenceServiceEndpoint.rootURL,
      encryptedPresence: encrypted
    )
  }

  private func poll(
    state: inout FriendState,
    at timestamp: Date
  ) async {
    defer { state.lastCheckedAt = timestamp }
    do {
      guard
        let encrypted = try await transport.friendPresence(
          at: state.record.profile.presenceServiceEndpoint.rootURL,
          routingID: state.record.profile.locator.routingID
        )
      else {
        state.verifiedInvite = nil
        state.verifiedPresenceExpiresAt = nil
        state.pollFailureCount = 0
        state.pollIssue = nil
        state.nextPollAt = timestamp.addingTimeInterval(timing.pollInterval)
        return
      }

      if encrypted.revision != state.lastSeenRevision {
        let invite = try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
          encrypted,
          locator: state.record.profile.locator,
          expectedPublisherIdentity: state.record.identity,
          recipientIdentity: signer.publicKey,
          at: try ClipLiveShareNativeTimestamp(date: timestamp),
          afterRevision: state.lastSeenRevision
        )
        state.verifiedInvite = invite
        state.verifiedPresenceExpiresAt = Date(
          timeIntervalSince1970:
            TimeInterval(encrypted.expiresAtMilliseconds) / 1_000
        )
        state.lastSeenAt = timestamp
        state.lastSeenRevision = encrypted.revision
      }
      state.pollFailureCount = 0
      state.pollIssue = nil
      state.nextPollAt = timestamp.addingTimeInterval(timing.pollInterval)
    } catch {
      state.pollFailureCount += 1
      state.pollIssue = error.localizedDescription
      state.nextPollAt = timestamp.addingTimeInterval(
        failureBackoff(attempt: state.pollFailureCount)
      )
      if state.verifiedPresenceExpiresAt.map({ $0 <= timestamp }) ?? true {
        state.verifiedInvite = nil
        state.verifiedPresenceExpiresAt = nil
      }
    }
  }

  private func nextRevision(
    after previous: UInt64?,
    at timestamp: Date
  ) throws -> UInt64 {
    let milliseconds = timestamp.timeIntervalSince1970 * 1_000
    guard milliseconds.isFinite, milliseconds > 0 else {
      throw MeshFriendPresenceControllerError.revisionExhausted
    }
    let wallClockRevision = UInt64(min(milliseconds, Double(UInt64.max)))
    guard let previous else { return max(1, wallClockRevision) }
    guard previous < UInt64.max else {
      throw MeshFriendPresenceControllerError.revisionExhausted
    }
    return max(previous + 1, wallClockRevision)
  }

  private func failureBackoff(attempt: Int) -> TimeInterval {
    var delay = timing.initialFailureBackoff
    for _ in 1..<min(max(attempt, 1), 32) {
      delay = min(delay * 2, timing.maximumFailureBackoff)
    }
    return min(delay, timing.maximumFailureBackoff)
  }

  private func expireVerifiedPresence(at timestamp: Date) {
    for id in states.keys
    where
      states[id]?.verifiedPresenceExpiresAt.map({ $0 <= timestamp }) == true
    {
      states[id]?.verifiedInvite = nil
      states[id]?.verifiedPresenceExpiresAt = nil
    }
  }

  private func makeSnapshot() -> MeshFriendPresenceControllerSnapshot {
    .init(
      friends: states.values.map { state in
        let invite = state.verifiedInvite
        return .init(
          id: state.record.id,
          identity: state.record.identity,
          displayName: state.record.displayName,
          deviceName: state.record.deviceName,
          availability: invite == nil ? .offline : .online,
          verifiedInvite: invite,
          lastSeenAt: state.lastSeenAt,
          lastCheckedAt: state.lastCheckedAt,
          retryAfter: [state.nextPollAt, state.nextPublishAt]
            .compactMap { $0 }
            .min(),
          issue: state.pollIssue ?? state.publishIssue
        )
      }.sorted {
        let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
        return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
      })
  }

  private func emitSnapshot() async {
    let value = makeSnapshot()
    guard value != lastEmittedSnapshot else { return }
    lastEmittedSnapshot = value
    await onSnapshotChanged(value)
  }

  private func nextLoopDelay(at timestamp: Date) -> TimeInterval {
    let dueDates = states.values.flatMap { state in
      [state.nextPollAt, currentInvite == nil ? nil : state.nextPublishAt]
        .compactMap { $0 }
    }
    guard let next = dueDates.min() else { return timing.idleLoopInterval }
    return min(
      timing.idleLoopInterval,
      max(0, next.timeIntervalSince(timestamp))
    )
  }
}
