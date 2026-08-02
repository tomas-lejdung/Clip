import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import Testing

@testable import Clip

@Suite("Saved-friend encrypted presence controller")
struct MeshFriendPresenceControllerTests {
  @Test("publishes locally, polls remotely, and preserves the canonical invite")
  func directionalStablePresence() async throws {
    let fixture = try FriendPresenceControllerFixture()
    let clock = LockedFriendPresenceClock(fixture.now)
    let transport = MemoryMeshFriendPresenceTransport()
    try await transport.seed(
      fixture.remotePresence(revision: 11),
      at: fixture.remoteEndpoint.rootURL
    )
    // Simulates a still-live publication from an earlier app process. The
    // controller must advance it rather than resetting the revision.
    try await transport.seed(
      fixture.localPresence(revision: 41),
      at: fixture.localEndpoint.rootURL
    )
    let controller = fixture.controller(
      records: [fixture.friend],
      clock: clock,
      transport: transport
    )
    await controller.updateCurrentInvite(fixture.localInvite)

    await controller.synchronizeNow()

    let firstPublished = try #require(
      await transport.record(
        endpoint: fixture.localEndpoint.rootURL,
        routingID: fixture.localLocator.routingID
      )
    )
    #expect(firstPublished.revision > 41)
    let openedLocal = try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
      firstPublished,
      locator: fixture.localLocator,
      expectedPublisherIdentity: fixture.localSigner.publicKey,
      recipientIdentity: fixture.remoteSigner.publicKey,
      at: try ClipLiveShareNativeTimestamp(date: fixture.now)
    )
    #expect(try openedLocal.url == fixture.localInvite.url)
    #expect(
      firstPublished.expiresAtMilliseconds
        - Int64(fixture.now.timeIntervalSince1970 * 1_000)
        == 45_000
    )

    let snapshot = await controller.snapshot()
    let online = try #require(snapshot.friends.first)
    #expect(online.availability == .online)
    #expect(try online.verifiedInvite?.url == fixture.remoteInvite.url)
    #expect(online.identity == fixture.remoteSigner.publicKey)

    let calls = await transport.calls()
    #expect(
      calls.contains(
        .init(
          operation: .publish,
          endpoint: fixture.localEndpoint.rootURL,
          routingID: fixture.localLocator.routingID
        )))
    #expect(
      calls.contains(
        .init(
          operation: .fetch,
          endpoint: fixture.remoteEndpoint.rootURL,
          routingID: fixture.remoteLocator.routingID
        )))
    #expect(
      !calls.contains(
        .init(
          operation: .publish,
          endpoint: fixture.remoteEndpoint.rootURL,
          routingID: fixture.localLocator.routingID
        )))

    clock.advance(by: 16)
    await controller.synchronizeNow()
    let refreshed = try #require(
      await transport.record(
        endpoint: fixture.localEndpoint.rootURL,
        routingID: fixture.localLocator.routingID
      )
    )
    #expect(refreshed.revision > firstPublished.revision)
    let refreshedInvite = try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
      refreshed,
      locator: fixture.localLocator,
      expectedPublisherIdentity: fixture.localSigner.publicKey,
      recipientIdentity: fixture.remoteSigner.publicKey,
      at: try ClipLiveShareNativeTimestamp(date: clock.now())
    )
    #expect(try refreshedInvite.url == fixture.localInvite.url)

    let rotatedInvite = try fixture.localInvite(creator: fixture.localSigner)
    await controller.updateCurrentInvite(rotatedInvite)
    await controller.synchronizeNow()
    let rotated = try #require(
      await transport.record(
        endpoint: fixture.localEndpoint.rootURL,
        routingID: fixture.localLocator.routingID
      )
    )
    #expect(rotated.revision > refreshed.revision)
    let openedRotated = try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
      rotated,
      locator: fixture.localLocator,
      expectedPublisherIdentity: fixture.localSigner.publicKey,
      recipientIdentity: fixture.remoteSigner.publicKey,
      at: try ClipLiveShareNativeTimestamp(date: clock.now())
    )
    #expect(try openedRotated.url == rotatedInvite.url)
  }

  @Test(
    "a newly committed friend can join an active creator, but not an ordinary participant"
  )
  func committedFriendDiscoversOnlyActiveCreatorRoom() async throws {
    let creatorSigner = ClipLiveShareSoftwareIdentitySigner()
    let participantSigner = ClipLiveShareSoftwareIdentitySigner()
    let creatorEndpoint = try ClipLiveShareRendezvousEndpoint(
      rootURL: URL(string: "https://creator.example")!
    )
    let participantEndpoint = try ClipLiveShareRendezvousEndpoint(
      rootURL: URL(string: "https://participant.example")!
    )
    let creatorLocator = ClipLiveShareServerRoomV4FriendLocator.random()
    let participantLocator = ClipLiveShareServerRoomV4FriendLocator.random()
    let timestamp = Date(timeIntervalSince1970: 2_000_000_000)
    let creatorInvite = try ClipLiveShareServerRoomV4Invite(
      serviceEndpoint: creatorEndpoint.rootURL,
      roomID: .random(),
      sessionID: .random(),
      creatorIdentity: creatorSigner.publicKey,
      roomAgreementSecret: .random(),
      admissionCapability: .random()
    )
    let creatorFriend = MeshFriendRecord(
      profile: try .init(
        identity: participantSigner.publicKey,
        displayName: "Participant",
        deviceName: "Participant Mac",
        presenceServiceEndpoint: participantEndpoint,
        locator: participantLocator
      ),
      localPublishingLocator: creatorLocator,
      trustState: .trusted,
      createdAt: timestamp,
      lastConfirmedAt: timestamp
    )
    let participantFriend = MeshFriendRecord(
      profile: try .init(
        identity: creatorSigner.publicKey,
        displayName: "Creator",
        deviceName: "Creator Mac",
        presenceServiceEndpoint: creatorEndpoint,
        locator: creatorLocator
      ),
      localPublishingLocator: participantLocator,
      trustState: .trusted,
      createdAt: timestamp,
      lastConfirmedAt: timestamp
    )
    let creatorFriends = MutableFriendPresenceRecords()
    let participantFriends = MutableFriendPresenceRecords()
    let transport = MemoryMeshFriendPresenceTransport()
    let creatorPresence = MeshFriendPresenceController(
      signer: creatorSigner,
      loadFriends: { await creatorFriends.load() },
      localPresenceServiceEndpoint: creatorEndpoint,
      transport: transport,
      now: { timestamp }
    )
    let participantPresence = MeshFriendPresenceController(
      signer: participantSigner,
      loadFriends: { await participantFriends.load() },
      localPresenceServiceEndpoint: participantEndpoint,
      transport: transport,
      now: { timestamp }
    )

    await creatorPresence.updateCurrentInvite(
      MeshCreatorPresenceInvitePolicy.invite(
        role: .creator,
        phase: .active,
        invite: creatorInvite
      )
    )
    await participantPresence.updateCurrentInvite(
      MeshCreatorPresenceInvitePolicy.invite(
        role: .participant,
        phase: .active,
        invite: creatorInvite
      )
    )

    // The active creator has nobody to publish to until the four-step friend
    // handshake has durably committed its directional mailbox.
    await creatorPresence.synchronizeNow()
    #expect(
      await transport.record(
        endpoint: creatorEndpoint.rootURL,
        routingID: creatorLocator.routingID
      ) == nil
    )

    await creatorFriends.replace(with: [creatorFriend])
    await participantFriends.replace(with: [participantFriend])
    await creatorPresence.synchronizeNow()
    await participantPresence.synchronizeNow()

    #expect(
      await transport.record(
        endpoint: creatorEndpoint.rootURL,
        routingID: creatorLocator.routingID
      ) != nil
    )
    #expect(
      await transport.record(
        endpoint: participantEndpoint.rootURL,
        routingID: participantLocator.routingID
      ) == nil
    )

    let participantSnapshot = await participantPresence.snapshot()
    let creatorRow = try #require(
      MenuBarFriendPresencePolicy.rows(from: participantSnapshot).first
    )
    #expect(creatorRow.isOnline)
    #expect(creatorRow.status == "Room Available")
    let joinRequest = try #require(
      MenuBarFriendPresencePolicy.verifiedJoinRequest(
        friendID: creatorRow.id,
        snapshot: participantSnapshot
      )
    )
    #expect(try joinRequest.invite.url == creatorInvite.url)
    #expect(joinRequest.requiresCreatorApproval)

    let creatorSnapshot = await creatorPresence.snapshot()
    let participantRow = try #require(
      MenuBarFriendPresencePolicy.rows(from: creatorSnapshot).first
    )
    #expect(!participantRow.isOnline)
    #expect(participantRow.status == "No Room")
    #expect(
      MenuBarFriendPresencePolicy.verifiedJoinRequest(
        friendID: participantRow.id,
        snapshot: creatorSnapshot
      ) == nil
    )
  }

  @Test("poll failures back off and verified presence expires fail closed")
  func expiryAndBackoff() async throws {
    let fixture = try FriendPresenceControllerFixture(remoteLifetime: 30)
    let clock = LockedFriendPresenceClock(fixture.now)
    let transport = MemoryMeshFriendPresenceTransport()
    try await transport.seed(
      fixture.remotePresence(revision: 2),
      at: fixture.remoteEndpoint.rootURL
    )
    let controller = fixture.controller(
      records: [fixture.friend],
      clock: clock,
      transport: transport,
      timing: .init(
        presenceLifetime: 60,
        publicationRefreshInterval: 20,
        pollInterval: 10,
        initialFailureBackoff: 2,
        maximumFailureBackoff: 8,
        idleLoopInterval: 1
      )
    )

    await controller.synchronizeNow()
    #expect(await controller.snapshot().onlineFriends.count == 1)
    let initialFetches = await transport.fetchCount(
      endpoint: fixture.remoteEndpoint.rootURL,
      routingID: fixture.remoteLocator.routingID
    )

    clock.advance(by: 11)
    await transport.failFetches(
      endpoint: fixture.remoteEndpoint.rootURL,
      routingID: fixture.remoteLocator.routingID
    )
    await controller.synchronizeNow()
    let retained = try #require(await controller.snapshot().friends.first)
    #expect(retained.availability == .online)
    #expect(retained.issue != nil)

    await controller.synchronizeNow()
    #expect(
      await transport.fetchCount(
        endpoint: fixture.remoteEndpoint.rootURL,
        routingID: fixture.remoteLocator.routingID
      ) == initialFetches + 1
    )

    clock.advance(by: 20)
    await controller.synchronizeNow()
    let expired = try #require(await controller.snapshot().friends.first)
    #expect(expired.availability == .offline)
    #expect(expired.verifiedInvite == nil)
  }

  @Test("renaming a friend preserves verified presence and poll backoff")
  func aliasOnlyReconciliationPreservesPresenceState() async throws {
    let fixture = try FriendPresenceControllerFixture()
    let clock = LockedFriendPresenceClock(fixture.now)
    let transport = MemoryMeshFriendPresenceTransport()
    let records = MutableFriendPresenceRecords()
    await records.replace(with: [fixture.friend])
    try await transport.seed(
      fixture.remotePresence(revision: 7),
      at: fixture.remoteEndpoint.rootURL
    )
    let controller = MeshFriendPresenceController(
      signer: fixture.localSigner,
      loadFriends: { await records.load() },
      localPresenceServiceEndpoint: fixture.localEndpoint,
      transport: transport,
      now: clock.now
    )

    await controller.synchronizeNow()
    let before = try #require(await controller.snapshot().friends.first)
    let callsBeforeRename = await transport.calls().count
    var renamed = fixture.friend
    renamed.localAlias = "Jules"
    await records.replace(with: [renamed])

    // No clock advance means the existing poll/publish schedules are not due.
    // Replacing the state would perform both operations again.
    await controller.synchronizeNow()

    let after = try #require(await controller.snapshot().friends.first)
    #expect(after.displayName == "Jules")
    #expect(after.verifiedInvite == before.verifiedInvite)
    #expect(after.lastSeenAt == before.lastSeenAt)
    #expect(after.retryAfter == before.retryAfter)
    #expect(await transport.calls().count == callsBeforeRename)
  }

  @Test("pending friends are ignored and reused mailboxes fail closed")
  func trustAndMailboxIsolation() async throws {
    let fixture = try FriendPresenceControllerFixture()
    let otherSigner = ClipLiveShareSoftwareIdentitySigner()
    let otherProfile = try ClipLiveShareServerRoomV4FriendProfile(
      identity: otherSigner.publicKey,
      displayName: "Other",
      deviceName: "Other Mac",
      presenceServiceEndpoint: fixture.remoteEndpoint,
      locator: .random()
    )
    let duplicate = MeshFriendRecord(
      profile: otherProfile,
      localPublishingLocator: fixture.localLocator,
      trustState: .trusted,
      createdAt: fixture.now,
      lastConfirmedAt: fixture.now
    )
    let pending = MeshFriendRecord(
      profile: try .init(
        identity: ClipLiveShareSoftwareIdentitySigner().publicKey,
        displayName: "Pending",
        deviceName: "Pending Mac",
        presenceServiceEndpoint: fixture.remoteEndpoint,
        locator: .random()
      ),
      localPublishingLocator: .random(),
      trustState: .pendingCommit,
      createdAt: fixture.now,
      lastConfirmedAt: nil
    )
    let transport = MemoryMeshFriendPresenceTransport()
    let controller = fixture.controller(
      records: [fixture.friend, duplicate, pending],
      clock: LockedFriendPresenceClock(fixture.now),
      transport: transport
    )
    await controller.updateCurrentInvite(fixture.localInvite)

    await controller.synchronizeNow()

    let snapshot = await controller.snapshot()
    #expect(snapshot.friends.count == 2)
    #expect(snapshot.friends.allSatisfy { $0.availability == .offline })
    #expect(snapshot.friends.allSatisfy { $0.issue?.contains("reused") == true })
    #expect(await transport.calls().isEmpty)
  }

  @Test("wrong publisher and recipient presence never becomes joinable")
  func identityPinning() async throws {
    let fixture = try FriendPresenceControllerFixture()
    let attacker = ClipLiveShareSoftwareIdentitySigner()
    let timestamp = try ClipLiveShareNativeTimestamp(date: fixture.now)
    let encrypted = try ClipLiveShareServerRoomV4FriendPresenceCrypto.seal(
      invite: try fixture.invite(creator: attacker),
      revision: 1,
      publisherSigner: attacker,
      recipientIdentity: fixture.localSigner.publicKey,
      locator: fixture.remoteLocator,
      issuedAt: timestamp,
      expiresAt: try timestamp.adding(milliseconds: 60_000)
    )
    let transport = MemoryMeshFriendPresenceTransport()
    try await transport.seed(encrypted, at: fixture.remoteEndpoint.rootURL)
    let controller = fixture.controller(
      records: [fixture.friend],
      clock: LockedFriendPresenceClock(fixture.now),
      transport: transport
    )

    await controller.synchronizeNow()

    let friend = try #require(await controller.snapshot().friends.first)
    #expect(friend.availability == .offline)
    #expect(friend.verifiedInvite == nil)
    #expect(friend.issue != nil)
    #expect(!friend.description.contains(try encryptedInviteText(encrypted)))
  }
}

private struct FriendPresenceControllerFixture {
  let localSigner = ClipLiveShareSoftwareIdentitySigner()
  let remoteSigner = ClipLiveShareSoftwareIdentitySigner()
  let localEndpoint: ClipLiveShareRendezvousEndpoint
  let remoteEndpoint: ClipLiveShareRendezvousEndpoint
  let localLocator = ClipLiveShareServerRoomV4FriendLocator.random()
  let remoteLocator = ClipLiveShareServerRoomV4FriendLocator.random()
  let now = Date(timeIntervalSince1970: 2_000_000_000)
  let remoteLifetime: Int64
  let localInvite: ClipLiveShareServerRoomV4Invite
  let remoteInvite: ClipLiveShareServerRoomV4Invite
  let friend: MeshFriendRecord

  init(remoteLifetime: Int64 = 5 * 60) throws {
    localEndpoint = try .init(rootURL: URL(string: "https://local.example")!)
    remoteEndpoint = try .init(rootURL: URL(string: "https://remote.example")!)
    self.remoteLifetime = remoteLifetime
    localInvite = try Self.makeInvite(
      endpoint: localEndpoint.rootURL,
      creator: localSigner
    )
    remoteInvite = try Self.makeInvite(
      endpoint: remoteEndpoint.rootURL,
      creator: remoteSigner
    )
    let profile = try ClipLiveShareServerRoomV4FriendProfile(
      identity: remoteSigner.publicKey,
      displayName: "Remote Friend",
      deviceName: "Remote Mac",
      presenceServiceEndpoint: remoteEndpoint,
      locator: remoteLocator
    )
    friend = .init(
      profile: profile,
      localPublishingLocator: localLocator,
      trustState: .trusted,
      createdAt: now,
      lastConfirmedAt: now
    )
  }

  func controller(
    records: [MeshFriendRecord],
    clock: LockedFriendPresenceClock,
    transport: MemoryMeshFriendPresenceTransport,
    timing: MeshFriendPresenceTiming = .production
  ) -> MeshFriendPresenceController {
    .init(
      signer: localSigner,
      loadFriends: { records },
      localPresenceServiceEndpoint: localEndpoint,
      transport: transport,
      timing: timing,
      now: clock.now
    )
  }

  func localPresence(
    revision: UInt64
  ) throws -> ClipLiveShareServerRoomV4EncryptedFriendPresence {
    let issued = try ClipLiveShareNativeTimestamp(date: now)
    return try ClipLiveShareServerRoomV4FriendPresenceCrypto.seal(
      invite: localInvite,
      revision: revision,
      publisherSigner: localSigner,
      recipientIdentity: remoteSigner.publicKey,
      locator: localLocator,
      issuedAt: issued,
      expiresAt: try issued.adding(milliseconds: 5 * 60 * 1_000)
    )
  }

  func remotePresence(
    revision: UInt64
  ) throws -> ClipLiveShareServerRoomV4EncryptedFriendPresence {
    let issued = try ClipLiveShareNativeTimestamp(date: now)
    return try ClipLiveShareServerRoomV4FriendPresenceCrypto.seal(
      invite: remoteInvite,
      revision: revision,
      publisherSigner: remoteSigner,
      recipientIdentity: localSigner.publicKey,
      locator: remoteLocator,
      issuedAt: issued,
      expiresAt: try issued.adding(milliseconds: remoteLifetime * 1_000)
    )
  }

  func invite(
    creator: ClipLiveShareSoftwareIdentitySigner
  ) throws -> ClipLiveShareServerRoomV4Invite {
    try Self.makeInvite(endpoint: remoteEndpoint.rootURL, creator: creator)
  }

  func localInvite(
    creator: ClipLiveShareSoftwareIdentitySigner
  ) throws -> ClipLiveShareServerRoomV4Invite {
    try Self.makeInvite(endpoint: localEndpoint.rootURL, creator: creator)
  }

  private static func makeInvite(
    endpoint: URL,
    creator: ClipLiveShareSoftwareIdentitySigner
  ) throws -> ClipLiveShareServerRoomV4Invite {
    try .init(
      serviceEndpoint: endpoint,
      roomID: .random(),
      sessionID: .random(),
      creatorIdentity: creator.publicKey,
      roomAgreementSecret: .random(),
      admissionCapability: .random()
    )
  }
}

private final class LockedFriendPresenceClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date {
    lock.withLock { value }
  }

  func advance(by seconds: TimeInterval) {
    lock.withLock {
      value = value.addingTimeInterval(seconds)
    }
  }
}

private actor MutableFriendPresenceRecords {
  private var records: [MeshFriendRecord] = []

  func load() -> [MeshFriendRecord] {
    records
  }

  func replace(with records: [MeshFriendRecord]) {
    self.records = records
  }
}

private actor MemoryMeshFriendPresenceTransport: MeshFriendPresenceTransport {
  enum Operation: Equatable, Sendable {
    case publish
    case fetch
  }

  struct Call: Equatable, Sendable {
    let operation: Operation
    let endpoint: URL
    let routingID: ClipLiveShareServerRoomV4FriendRoutingID
  }

  struct Key: Hashable, Sendable {
    let endpoint: URL
    let routingID: ClipLiveShareServerRoomV4FriendRoutingID
  }

  enum Failure: Error {
    case offline
  }

  private var records: [Key: ClipLiveShareServerRoomV4EncryptedFriendPresence] = [:]
  private var recordedCalls: [Call] = []
  private var failedFetches: Set<Key> = []

  func seed(
    _ presence: ClipLiveShareServerRoomV4EncryptedFriendPresence,
    at endpoint: URL
  ) throws {
    records[.init(endpoint: endpoint, routingID: presence.routingID)] = presence
  }

  func record(
    endpoint: URL,
    routingID: ClipLiveShareServerRoomV4FriendRoutingID
  ) -> ClipLiveShareServerRoomV4EncryptedFriendPresence? {
    records[.init(endpoint: endpoint, routingID: routingID)]
  }

  func calls() -> [Call] {
    recordedCalls
  }

  func failFetches(
    endpoint: URL,
    routingID: ClipLiveShareServerRoomV4FriendRoutingID
  ) {
    failedFetches.insert(.init(endpoint: endpoint, routingID: routingID))
  }

  func fetchCount(
    endpoint: URL,
    routingID: ClipLiveShareServerRoomV4FriendRoutingID
  ) -> Int {
    recordedCalls.filter {
      $0.operation == .fetch
        && $0.endpoint == endpoint
        && $0.routingID == routingID
    }.count
  }

  func publishFriendPresence(
    at endpoint: URL,
    encryptedPresence: ClipLiveShareServerRoomV4EncryptedFriendPresence
  ) async throws {
    let key = Key(endpoint: endpoint, routingID: encryptedPresence.routingID)
    recordedCalls.append(
      .init(
        operation: .publish,
        endpoint: endpoint,
        routingID: encryptedPresence.routingID
      ))
    if let current = records[key],
      encryptedPresence.revision <= current.revision
    {
      throw ClipLiveShareServerRoomV4TransportError
        .friendPresenceRevisionConflict
    }
    records[key] = encryptedPresence
  }

  func friendPresence(
    at endpoint: URL,
    routingID: ClipLiveShareServerRoomV4FriendRoutingID
  ) async throws -> ClipLiveShareServerRoomV4EncryptedFriendPresence? {
    let key = Key(endpoint: endpoint, routingID: routingID)
    recordedCalls.append(
      .init(
        operation: .fetch,
        endpoint: endpoint,
        routingID: routingID
      ))
    if failedFetches.contains(key) { throw Failure.offline }
    return records[key]
  }
}

private func encryptedInviteText(
  _ presence: ClipLiveShareServerRoomV4EncryptedFriendPresence
) throws -> String {
  ClipLiveShareBase64URL.encode(presence.ciphertext)
}
