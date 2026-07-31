import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Native-v3 clean-slate invitations")
struct ClipLiveShareNativeV3InviteTests {
  @Test("invite round-trips through the native mesh fragment")
  func inviteRoundTrip() throws {
    let fixture = try Fixture()
    let url = try fixture.invite.url
    let decoded = try ClipLiveShareNativeV3Invite(url: url)

    #expect(decoded == fixture.invite)
    #expect(url.fragment?.hasPrefix("clip-native-v3=") == true)
    #expect(!url.absoluteString.contains("v=1"))
    #expect(!url.absoluteString.contains("v=2"))
    #expect(!fixture.invite.description.contains(
      fixture.admissionCapability.rawValue
    ))
  }

  @Test("invite rejects unknown fields and a non-root endpoint")
  func inviteStrictness() throws {
    let fixture = try Fixture()
    var components = try #require(
      URLComponents(
        url: fixture.invite.url,
        resolvingAgainstBaseURL: false
      )
    )
    let fragment = try #require(components.fragment)
    let encoded = String(fragment.dropFirst("clip-native-v3=".count))
    let data = try #require(ClipLiveShareBase64URL.decode(encoded))
    var object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["unexpectedField"] = true
    components.fragment =
      "clip-native-v3="
      + ClipLiveShareBase64URL.encode(
        try JSONSerialization.data(withJSONObject: object)
      )
    #expect(throws: ClipLiveShareNativeV3InviteError.invalidInvite) {
      _ = try ClipLiveShareNativeV3Invite(
        url: #require(components.url)
      )
    }

    #expect(throws: ClipLiveShareNativeV3InviteError.invalidEndpoint) {
      _ = try ClipLiveShareNativeV3Invite(
        endpoint: URL(string: "https://example.test/nested-room")!,
        rendezvousID: fixture.rendezvousID,
        sessionID: fixture.sessionID,
        foundingCreatorIdentity: fixture.signer.publicKey,
        leaderParticipantID: fixture.leaderID,
        leaderIdentity: fixture.signer.publicKey,
        leaderRendezvousPublicKey:
          fixture.leaderRendezvousIdentity.publicKey,
        admissionCapability: fixture.admissionCapability
      )
    }
  }

  @Test("signed descriptor is bound to every public invite field")
  func descriptorBinding() throws {
    let fixture = try Fixture()
    let signed = try fixture.signedDescriptor()
    let decoded = try ClipLiveShareSignedNativeV3RoomDescriptor.decode(
      signed.encoded()
    )
    try decoded.verify(matching: fixture.invite, at: fixture.time(1))

    let changedInvite = try ClipLiveShareNativeV3Invite(
      endpoint: fixture.endpoint,
      rendezvousID: fixture.rendezvousID,
      sessionID: fixture.sessionID,
      foundingCreatorIdentity: fixture.signer.publicKey,
      leaderParticipantID: .random(),
      leaderIdentity: fixture.signer.publicKey,
      leaderRendezvousPublicKey:
        fixture.leaderRendezvousIdentity.publicKey,
      admissionCapability: fixture.admissionCapability
    )
    #expect(
      throws: ClipLiveShareNativeV3InviteError.descriptorMismatch
    ) {
      try decoded.verify(
        matching: changedInvite,
        at: fixture.time(1)
      )
    }
  }

  @Test("signed descriptor authenticates the Access Word requirement")
  func descriptorAccessWordRequirement() throws {
    let fixture = try Fixture()
    let signed = try fixture.signedDescriptor(
      accessWordRequired: true
    )
    let decoded = try ClipLiveShareSignedNativeV3RoomDescriptor.decode(
      signed.encoded()
    )

    #expect(decoded.descriptor.accessWordRequired)
    try decoded.verify(matching: fixture.invite, at: fixture.time(1))

    let changedDescriptor = try ClipLiveShareNativeV3RoomDescriptor(
      rendezvousID: decoded.descriptor.rendezvousID,
      sessionID: decoded.descriptor.sessionID,
      foundingCreatorIdentity:
        decoded.descriptor.foundingCreatorIdentity,
      leaderParticipantID:
        decoded.descriptor.leaderParticipantID,
      leaderIdentity: decoded.descriptor.leaderIdentity,
      leaderRendezvousPublicKey:
        decoded.descriptor.leaderRendezvousPublicKey,
      accessWordRequired: false,
      issuedAt: decoded.descriptor.issuedAt,
      expiresAt: decoded.descriptor.expiresAt
    )
    let tampered = ClipLiveShareSignedNativeV3RoomDescriptor(
      descriptor: changedDescriptor,
      signature: decoded.signature
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidSignature) {
      try tampered.verify(
        matching: fixture.invite,
        at: fixture.time(1)
      )
    }
  }

  @Test("rendezvous knock binds route participant and ephemeral key")
  func knockAuthentication() throws {
    let fixture = try Fixture()
    let candidateRendezvousIdentity =
      ClipLiveShareNativeV3RendezvousIdentity()
    let knock = ClipLiveShareNativeV3RendezvousKnock(
      sessionID: fixture.sessionID,
      rendezvousID: fixture.rendezvousID,
      routeID: fixture.routeID,
      participantID: fixture.candidateID,
      ephemeralPublicKey: candidateRendezvousIdentity.publicKey,
      admissionCapability: fixture.admissionCapability
    )
    let decoded = try ClipLiveShareNativeV3RendezvousKnock.decode(
      knock.encoded()
    )
    try decoded.verify(
      expectedSessionID: fixture.sessionID,
      expectedRendezvousID: fixture.rendezvousID,
      expectedRouteID: fixture.routeID,
      admissionCapability: fixture.admissionCapability
    )
    let sealed = try knock.sealed(
      with: fixture.admissionCapability
    )
    #expect(sealed.range(of: fixture.candidateID.bytes) == nil)
    #expect(
      sealed.range(
        of: candidateRendezvousIdentity.publicKey.x963Representation
      ) == nil
    )
    #expect(
      try ClipLiveShareNativeV3RendezvousKnock.openSealed(
        sealed,
        expectedSessionID: fixture.sessionID,
        expectedRendezvousID: fixture.rendezvousID,
        expectedRouteID: fixture.routeID,
        admissionCapability: fixture.admissionCapability
      ) == knock
    )

    #expect(
      throws:
        ClipLiveShareNativeV3InviteError.invalidKnockAuthentication
    ) {
      try decoded.verify(
        expectedSessionID: fixture.sessionID,
        expectedRendezvousID: fixture.rendezvousID,
        expectedRouteID: fixture.routeID,
        admissionCapability: .random()
      )
    }
    var tampered = sealed
    tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
    #expect(
      throws:
        ClipLiveShareNativeV3InviteError.invalidKnockAuthentication
    ) {
      _ = try ClipLiveShareNativeV3RendezvousKnock.openSealed(
        tampered,
        expectedSessionID: fixture.sessionID,
        expectedRendezvousID: fixture.rendezvousID,
        expectedRouteID: fixture.routeID,
        admissionCapability: fixture.admissionCapability
      )
    }
    #expect(throws: ClipLiveShareNativeV3InviteError.invalidKnock) {
      try decoded.verify(
        expectedSessionID: fixture.sessionID,
        expectedRendezvousID: fixture.rendezvousID,
        expectedRouteID: try .init(
          bytes: Data(
            repeating: 0xEE,
            count: 16
          )
        ),
        admissionCapability: fixture.admissionCapability
      )
    }
  }
}

private struct Fixture {
  let endpoint = URL(string: "https://mesh.example.test")!
  let rendezvousID = try! ClipLiveShareNativeV3RendezvousID(
    bytes: Data(repeating: 0x11, count: 32)
  )
  let sessionID = try! ClipLiveShareSessionID(
    rawValue: "native-v3-clean-slate-room"
  )
  let signer: ClipLiveShareSoftwareIdentitySigner
  let leaderID = try! ClipLiveShareNativeV3ParticipantID(
    bytes: Data(repeating: 0x22, count: 16)
  )
  let candidateID = try! ClipLiveShareNativeV3ParticipantID(
    bytes: Data(repeating: 0x33, count: 16)
  )
  let leaderRendezvousIdentity =
    ClipLiveShareNativeV3RendezvousIdentity()
  let admissionCapability =
    try! ClipLiveShareNativeV3AdmissionCapability(
      bytes: Data(repeating: 0x44, count: 32)
    )
  let routeID = try! ClipLiveShareRouteID(
    bytes: Data(repeating: 0x55, count: 16)
  )
  let origin = try! ClipLiveShareNativeTimestamp(
    millisecondsSince1970: 2_000_000_000_000
  )
  let invite: ClipLiveShareNativeV3Invite

  init() throws {
    signer = try ClipLiveShareSoftwareIdentitySigner(
      rawRepresentation: Data(repeating: 0x66, count: 32)
    )
    invite = try ClipLiveShareNativeV3Invite(
      endpoint: endpoint,
      rendezvousID: rendezvousID,
      sessionID: sessionID,
      foundingCreatorIdentity: signer.publicKey,
      leaderParticipantID: leaderID,
      leaderIdentity: signer.publicKey,
      leaderRendezvousPublicKey:
        leaderRendezvousIdentity.publicKey,
      admissionCapability: admissionCapability
    )
  }

  func time(_ seconds: Int64) -> ClipLiveShareNativeTimestamp {
    try! origin.adding(milliseconds: seconds * 1_000)
  }

  func signedDescriptor(
    accessWordRequired: Bool = false
  )
    throws -> ClipLiveShareSignedNativeV3RoomDescriptor
  {
    let descriptor = try ClipLiveShareNativeV3RoomDescriptor(
      rendezvousID: rendezvousID,
      sessionID: sessionID,
      foundingCreatorIdentity: signer.publicKey,
      leaderParticipantID: leaderID,
      leaderIdentity: signer.publicKey,
      leaderRendezvousPublicKey:
        leaderRendezvousIdentity.publicKey,
      accessWordRequired: accessWordRequired,
      issuedAt: origin,
      expiresAt: time(300)
    )
    return try .init(signing: descriptor, with: signer)
  }
}
