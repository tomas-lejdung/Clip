import Foundation
import Testing
@testable import ClipLiveShare

@Suite("Server-room v4 friendship")
struct ClipLiveShareServerRoomV4FriendTests {
  @Test("signed four-step handshake binds the room, participants, and identities")
  func completeHandshake() throws {
    let fixture = try Fixture()
    let chain = try fixture.makeChain()

    try chain.request.verifyTransportContext(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      authorParticipantID: fixture.requesterParticipantID,
      recipientParticipantID: fixture.accepterParticipantID,
      authorIdentity: fixture.requesterSigner.publicKey,
      recipientIdentity: fixture.accepterSigner.publicKey,
      at: fixture.issuedAt
    )
    try chain.acceptance.verifyTransportContext(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      authorParticipantID: fixture.accepterParticipantID,
      recipientParticipantID: fixture.requesterParticipantID,
      authorIdentity: fixture.accepterSigner.publicKey,
      recipientIdentity: fixture.requesterSigner.publicKey,
      at: try fixture.issuedAt.adding(milliseconds: 1_000)
    )
    try chain.acknowledgement.verifyTransportContext(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      authorParticipantID: fixture.requesterParticipantID,
      recipientParticipantID: fixture.accepterParticipantID,
      authorIdentity: fixture.requesterSigner.publicKey,
      recipientIdentity: fixture.accepterSigner.publicKey,
      at: try fixture.issuedAt.adding(milliseconds: 2_000)
    )
    try chain.receipt.verifyTransportContext(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      authorParticipantID: fixture.accepterParticipantID,
      recipientParticipantID: fixture.requesterParticipantID,
      authorIdentity: fixture.accepterSigner.publicKey,
      recipientIdentity: fixture.requesterSigner.publicKey,
      at: try fixture.issuedAt.adding(milliseconds: 3_000)
    )

    guard case let .request(request) = chain.request.message,
          case let .acceptance(acceptance) = chain.acceptance.message,
          case let .acknowledgement(acknowledgement) =
            chain.acknowledgement.message,
          case let .commitReceipt(receipt) = chain.receipt.message else {
      Issue.record("Unexpected friend message type")
      return
    }
    try acceptance.validate(
      for: request,
      at: try fixture.issuedAt.adding(milliseconds: 1_000)
    )
    try acknowledgement.validate(
      request: request,
      acceptance: acceptance,
      at: try fixture.issuedAt.adding(milliseconds: 2_000)
    )
    try receipt.validate(
      request: request,
      acceptance: acceptance,
      acknowledgement: acknowledgement,
      at: try fixture.issuedAt.adding(milliseconds: 3_000)
    )
  }

  @Test("transport rejects cross-room and wrong-identity replay")
  func rejectsWrongContext() throws {
    let fixture = try Fixture()
    let request = try fixture.makeChain().request
    let otherRoom = ClipLiveShareServerRoomV4RoomID.random()

    #expect(throws: ClipLiveShareServerRoomV4FriendError.contextMismatch) {
      try request.verifyTransportContext(
        roomID: otherRoom,
        sessionID: fixture.sessionID,
        authorParticipantID: fixture.requesterParticipantID,
        recipientParticipantID: fixture.accepterParticipantID,
        authorIdentity: fixture.requesterSigner.publicKey,
        recipientIdentity: fixture.accepterSigner.publicKey,
        at: fixture.issuedAt
      )
    }
    let impostor = ClipLiveShareSoftwareIdentitySigner()
    #expect(throws: ClipLiveShareServerRoomV4FriendError.contextMismatch) {
      try request.verifyTransportContext(
        roomID: fixture.roomID,
        sessionID: fixture.sessionID,
        authorParticipantID: fixture.requesterParticipantID,
        recipientParticipantID: fixture.accepterParticipantID,
        authorIdentity: impostor.publicKey,
        recipientIdentity: fixture.accepterSigner.publicKey,
        at: fixture.issuedAt
      )
    }
  }

  @Test("request expires quickly while commit receipt supports bounded recovery")
  func boundedRecovery() throws {
    let fixture = try Fixture()
    let chain = try fixture.makeChain()
    let afterRequestExpiry = try fixture.issuedAt.adding(milliseconds: 6 * 60 * 1_000)

    #expect(throws: ClipLiveShareServerRoomV4FriendError.expired) {
      try chain.request.verifyTransportContext(
        roomID: fixture.roomID,
        sessionID: fixture.sessionID,
        authorParticipantID: fixture.requesterParticipantID,
        recipientParticipantID: fixture.accepterParticipantID,
        authorIdentity: fixture.requesterSigner.publicKey,
        recipientIdentity: fixture.accepterSigner.publicKey,
        at: afterRequestExpiry
      )
    }
    try chain.receipt.verifyTransportContext(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      authorParticipantID: fixture.accepterParticipantID,
      recipientParticipantID: fixture.requesterParticipantID,
      authorIdentity: fixture.accepterSigner.publicKey,
      recipientIdentity: fixture.requesterSigner.publicKey,
      at: afterRequestExpiry
    )
  }

  @Test("friend message codec and mesh control vocabulary round trip")
  func codecRoundTrip() throws {
    let message = try Fixture().makeChain().receipt
    let encoded = try ClipLiveShareServerRoomV4FriendMessageCodec.encode(message)
    #expect(
      try ClipLiveShareServerRoomV4FriendMessageCodec.decode(encoded) == message
    )

    let control = ClipLiveShareMeshMediaControlMessage.friendship(message)
    let controlData = try ClipLiveShareMeshMediaControlCodec.encode(control)
    #expect(try ClipLiveShareMeshMediaControlCodec.decode(controlData) == control)
    #expect(control.kind == .friendship)
  }

  @Test("signed decline is bound to the request and supports bounded replay")
  func signedDecline() throws {
    let fixture = try Fixture()
    let chain = try fixture.makeChain()
    guard case let .request(request) = chain.request.message else {
      Issue.record("Unexpected friend message type")
      return
    }
    let declinedAt = try fixture.issuedAt.adding(milliseconds: 1_000)
    let decline = try ClipLiveShareServerRoomV4FriendDecline(
      declining: request,
      accepterIdentity: fixture.accepterSigner.publicKey,
      declinedAt: declinedAt
    )
    let signed = try ClipLiveShareServerRoomV4SignedFriendMessage(
      signing: .decline(decline),
      with: fixture.accepterSigner
    )
    try signed.verifyTransportContext(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      authorParticipantID: fixture.accepterParticipantID,
      recipientParticipantID: fixture.requesterParticipantID,
      authorIdentity: fixture.accepterSigner.publicKey,
      recipientIdentity: fixture.requesterSigner.publicKey,
      at: try declinedAt.adding(milliseconds: 6 * 60 * 1_000)
    )
    try decline.validate(
      for: request,
      at: try declinedAt.adding(milliseconds: 6 * 60 * 1_000)
    )
    let encoded = try ClipLiveShareServerRoomV4FriendMessageCodec.encode(signed)
    #expect(
      try ClipLiveShareServerRoomV4FriendMessageCodec.decode(encoded) == signed
    )
  }

  @Test("signer cannot claim another requester's profile")
  func rejectsProfileImpersonation() throws {
    let fixture = try Fixture()
    let chain = try fixture.makeChain()
    #expect(throws: ClipLiveShareServerRoomV4FriendError.identityMismatch) {
      _ = try ClipLiveShareServerRoomV4SignedFriendMessage(
        signing: chain.request.message,
        with: fixture.accepterSigner
      )
    }
  }

  private struct Chain {
    let request: ClipLiveShareServerRoomV4SignedFriendMessage
    let acceptance: ClipLiveShareServerRoomV4SignedFriendMessage
    let acknowledgement: ClipLiveShareServerRoomV4SignedFriendMessage
    let receipt: ClipLiveShareServerRoomV4SignedFriendMessage
  }

  private struct Fixture {
    let roomID = ClipLiveShareServerRoomV4RoomID.random()
    let sessionID = ClipLiveShareSessionID.random()
    let requesterParticipantID = ClipLiveShareNativeV3ParticipantID.random()
    let accepterParticipantID = ClipLiveShareNativeV3ParticipantID.random()
    let requesterSigner = ClipLiveShareSoftwareIdentitySigner()
    let accepterSigner = ClipLiveShareSoftwareIdentitySigner()
    let issuedAt: ClipLiveShareNativeTimestamp
    let requesterProfile: ClipLiveShareServerRoomV4FriendProfile
    let accepterProfile: ClipLiveShareServerRoomV4FriendProfile

    init() throws {
      issuedAt = try .init(millisecondsSince1970: 1_800_000_000_000)
      requesterProfile = try .init(
        identity: requesterSigner.publicKey,
        displayName: "Requester",
        deviceName: "Requester Mac",
        locator: .random()
      )
      accepterProfile = try .init(
        identity: accepterSigner.publicKey,
        displayName: "Accepter",
        deviceName: "Accepter Mac",
        locator: .random()
      )
    }

    func makeChain() throws -> Chain {
      let requestValue = try ClipLiveShareServerRoomV4FriendRequest(
        roomID: roomID,
        sessionID: sessionID,
        requesterParticipantID: requesterParticipantID,
        accepterParticipantID: accepterParticipantID,
        requester: requesterProfile,
        expectedAccepterFingerprint: accepterSigner.publicKey.fingerprint,
        issuedAt: issuedAt,
        expiresAt: try issuedAt.adding(milliseconds: 5 * 60 * 1_000)
      )
      let signedRequest = try ClipLiveShareServerRoomV4SignedFriendMessage(
        signing: .request(requestValue),
        with: requesterSigner
      )
      let acceptanceValue = try ClipLiveShareServerRoomV4FriendAcceptance(
        accepting: requestValue,
        accepter: accepterProfile,
        acceptedAt: try issuedAt.adding(milliseconds: 1_000)
      )
      let signedAcceptance = try ClipLiveShareServerRoomV4SignedFriendMessage(
        signing: .acceptance(acceptanceValue),
        with: accepterSigner
      )
      let acknowledgementValue = try ClipLiveShareServerRoomV4FriendAcknowledgement(
        acknowledging: acceptanceValue,
        request: requestValue,
        acknowledgedAt: try issuedAt.adding(milliseconds: 2_000)
      )
      let signedAcknowledgement = try ClipLiveShareServerRoomV4SignedFriendMessage(
        signing: .acknowledgement(acknowledgementValue),
        with: requesterSigner
      )
      let receiptValue = try ClipLiveShareServerRoomV4FriendCommitReceipt(
        committing: acknowledgementValue,
        committedAt: try issuedAt.adding(milliseconds: 3_000)
      )
      let signedReceipt = try ClipLiveShareServerRoomV4SignedFriendMessage(
        signing: .commitReceipt(receiptValue),
        with: accepterSigner
      )
      return .init(
        request: signedRequest,
        acceptance: signedAcceptance,
        acknowledgement: signedAcknowledgement,
        receipt: signedReceipt
      )
    }
  }
}
