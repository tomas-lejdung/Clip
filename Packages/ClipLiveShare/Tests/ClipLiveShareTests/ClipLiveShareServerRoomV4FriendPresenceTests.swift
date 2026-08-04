import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Server-room v4 encrypted friend presence")
struct ClipLiveShareServerRoomV4FriendPresenceTests {
  @Test("directional friend mailbox hides and round trips the stable current invite")
  func roundTripStableInvite() throws {
    let fixture = try FriendPresenceFixture()
    let first = try fixture.seal(revision: 7, nonceByte: 0x51)
    let second = try fixture.seal(revision: 8, nonceByte: 0x52)

    let inviteBytes = Data((try fixture.invite.url.absoluteString).utf8)
    #expect(first.ciphertext.range(of: inviteBytes) == nil)
    #expect(
      first.ciphertext.range(
        of: fixture.publisher.publicKey.x963Representation
      ) == nil
    )
    #expect(first.ciphertext.range(of: fixture.invite.roomID.bytes) == nil)
    #expect(first.routingID == fixture.locator.routingID)

    let openedFirst = try fixture.open(first)
    let openedSecond = try fixture.open(second, afterRevision: 7)
    #expect(try openedFirst.url == fixture.invite.url)
    #expect(try openedSecond.url == fixture.invite.url)
    #expect(first.revision == 7)
    #expect(second.revision == 8)
    #expect(first.ciphertext != second.ciphertext)

    let record = ClipLiveShareServerRoomV4FriendPresenceRecord(
      encryptedPresence: first
    )
    #expect(try record.encryptedPresence(routingID: fixture.locator.routingID) == first)
    let wire = try JSONEncoder().encode(record)
    let root = try #require(
      JSONSerialization.jsonObject(with: wire) as? [String: Any]
    )
    #expect(Set(root.keys) == ["revision", "expiresAtMilliseconds", "payload"])
    let text = String(decoding: wire, as: UTF8.self)
    #expect(!text.contains(fixture.publisher.publicKey.rawValue))
    #expect(!text.contains(try fixture.invite.url.absoluteString))
    #expect(!text.contains(fixture.locator.presenceSecret.rawValue))
  }

  @Test("presence rejects expiry, replay, wrong key, route, and identities")
  func rejectsTampering() throws {
    let fixture = try FriendPresenceFixture()
    let encrypted = try fixture.seal(revision: 9, nonceByte: 0x61)

    #expect(throws: ClipLiveShareServerRoomV4FriendPresenceError.staleRevision) {
      try fixture.open(encrypted, afterRevision: 9)
    }
    #expect(throws: ClipLiveShareServerRoomV4FriendPresenceError.expired) {
      try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
        encrypted,
        locator: fixture.locator,
        expectedPublisherIdentity: fixture.publisher.publicKey,
        recipientIdentity: fixture.recipient.publicKey,
        at: fixture.expiresAt
      )
    }

    let wrongKey = ClipLiveShareServerRoomV4FriendLocator(
      routingID: fixture.locator.routingID,
      presenceSecret: .random()
    )
    #expect(throws: ClipLiveShareServerRoomV4FriendPresenceError.authenticationFailed) {
      try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
        encrypted,
        locator: wrongKey,
        expectedPublisherIdentity: fixture.publisher.publicKey,
        recipientIdentity: fixture.recipient.publicKey,
        at: fixture.now
      )
    }
    let wrongRoute = ClipLiveShareServerRoomV4FriendLocator(
      routingID: .random(),
      presenceSecret: fixture.locator.presenceSecret
    )
    #expect(throws: ClipLiveShareServerRoomV4FriendPresenceError.authenticationFailed) {
      try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
        encrypted,
        locator: wrongRoute,
        expectedPublisherIdentity: fixture.publisher.publicKey,
        recipientIdentity: fixture.recipient.publicKey,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareServerRoomV4FriendPresenceError.identityMismatch) {
      try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
        encrypted,
        locator: fixture.locator,
        expectedPublisherIdentity: fixture.recipient.publicKey,
        recipientIdentity: fixture.recipient.publicKey,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareServerRoomV4FriendPresenceError.identityMismatch) {
      try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
        encrypted,
        locator: fixture.locator,
        expectedPublisherIdentity: fixture.publisher.publicKey,
        recipientIdentity: fixture.thirdParty.publicKey,
        at: fixture.now
      )
    }

    var damaged = encrypted.ciphertext
    damaged[damaged.index(before: damaged.endIndex)] ^= 1
    let tampered = try ClipLiveShareServerRoomV4EncryptedFriendPresence(
      routingID: encrypted.routingID,
      revision: encrypted.revision,
      expiresAtMilliseconds: encrypted.expiresAtMilliseconds,
      ciphertext: damaged
    )
    #expect(throws: ClipLiveShareServerRoomV4FriendPresenceError.authenticationFailed) {
      try fixture.open(tampered)
    }
  }

  @Test("presence lifetime, revision, and payload bounds are fail closed")
  func bounds() throws {
    let fixture = try FriendPresenceFixture()
    #expect(throws: ClipLiveShareServerRoomV4FriendPresenceError.invalidRevision) {
      try fixture.seal(revision: 0, nonceByte: 1)
    }
    let tooLate = try fixture.now.adding(
      milliseconds:
        ClipLiveShareServerRoomV4FriendPresence.maximumLifetimeMilliseconds + 1
    )
    #expect(throws: ClipLiveShareServerRoomV4FriendPresenceError.invalidLifetime) {
      try ClipLiveShareServerRoomV4FriendPresenceCrypto.seal(
        invite: fixture.invite,
        revision: 1,
        publisherSigner: fixture.publisher,
        recipientIdentity: fixture.recipient.publicKey,
        locator: fixture.locator,
        issuedAt: fixture.now,
        expiresAt: tooLate,
        nonce: Data(repeating: 1, count: 12)
      )
    }
    #expect(throws: ClipLiveShareProtocolError.invalidNonceLength(11)) {
      try ClipLiveShareServerRoomV4FriendPresenceCrypto.seal(
        invite: fixture.invite,
        revision: 1,
        publisherSigner: fixture.publisher,
        recipientIdentity: fixture.recipient.publicKey,
        locator: fixture.locator,
        issuedAt: fixture.now,
        expiresAt: fixture.expiresAt,
        nonce: Data(repeating: 1, count: 11)
      )
    }
    #expect(throws: ClipLiveShareServerRoomV4FriendPresenceError.payloadTooLarge) {
      try ClipLiveShareServerRoomV4EncryptedFriendPresence(
        routingID: fixture.locator.routingID,
        revision: 1,
        expiresAtMilliseconds: fixture.expiresAt.millisecondsSince1970,
        ciphertext: Data(
          repeating: 1,
          count: ClipLiveShareServerRoomV4FriendPresence.maximumCiphertextBytes + 1
        )
      )
    }
  }
}

private struct FriendPresenceFixture {
  let publisher = try! ClipLiveShareSoftwareIdentitySigner(
    rawRepresentation: Data(repeating: 0x11, count: 32)
  )
  let recipient = try! ClipLiveShareSoftwareIdentitySigner(
    rawRepresentation: Data(repeating: 0x12, count: 32)
  )
  let thirdParty = try! ClipLiveShareSoftwareIdentitySigner(
    rawRepresentation: Data(repeating: 0x13, count: 32)
  )
  let locator = ClipLiveShareServerRoomV4FriendLocator(
    routingID: try! .init(bytes: Data(repeating: 0x21, count: 32)),
    presenceSecret: try! .init(keyMaterial: Data(repeating: 0x22, count: 32))
  )
  let now = try! ClipLiveShareNativeTimestamp(millisecondsSince1970: 2_000_000_000_000)
  let expiresAt: ClipLiveShareNativeTimestamp
  let invite: ClipLiveShareServerRoomV4Invite

  init() throws {
    expiresAt = try now.adding(milliseconds: 4 * 60 * 1_000)
    invite = try .init(
      serviceEndpoint: URL(string: "https://mesh.clip.example")!,
      roomID: .init(bytes: Data(repeating: 0x31, count: 32)),
      sessionID: .init(rawValue: "friend-presence-session"),
      creatorIdentity: publisher.publicKey,
      roomAgreementSecret: .init(bytes: Data(repeating: 0x32, count: 32)),
      admissionCapability: .init(bytes: Data(repeating: 0x33, count: 32)),
      roomCode: .init(rawValue: "FRIEND42")
    )
  }

  func seal(
    revision: UInt64,
    nonceByte: UInt8
  ) throws -> ClipLiveShareServerRoomV4EncryptedFriendPresence {
    try ClipLiveShareServerRoomV4FriendPresenceCrypto.seal(
      invite: invite,
      revision: revision,
      publisherSigner: publisher,
      recipientIdentity: recipient.publicKey,
      locator: locator,
      issuedAt: now,
      expiresAt: expiresAt,
      nonce: Data(repeating: nonceByte, count: 12)
    )
  }

  func open(
    _ encrypted: ClipLiveShareServerRoomV4EncryptedFriendPresence,
    afterRevision: UInt64? = nil
  ) throws -> ClipLiveShareServerRoomV4Invite {
    try ClipLiveShareServerRoomV4FriendPresenceCrypto.open(
      encrypted,
      locator: locator,
      expectedPublisherIdentity: publisher.publicKey,
      recipientIdentity: recipient.publicKey,
      at: now,
      afterRevision: afterRevision
    )
  }
}
