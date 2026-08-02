import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Clip Live Share mesh media control")
struct ClipLiveShareMeshMediaControlTests {
  @Test("closed v4 codec round trips every direct control message")
  func roundTripsClosedVocabulary() throws {
    let fixture = try MeshMediaControlFixture()
    let messages: [ClipLiveShareMeshMediaControlMessage] = [
      .sourceSnapshot(fixture.sourceSnapshot),
      .sourceCursor(fixture.sourceCursor),
      .collaboration(fixture.collaboration),
      .friendship(fixture.friendship),
    ]

    #expect(
      Set(messages.map(\.kind))
        == Set(ClipLiveShareMeshMediaControlMessageKind.allCases)
    )
    for message in messages {
      let data = try ClipLiveShareMeshMediaControlCodec.encode(message)
      #expect(try ClipLiveShareMeshMediaControlCodec.decode(data) == message)

      let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
      )
      #expect(Set(object.keys) == ["version", "type", "payload"])
      #expect(object["version"] as? Int == ClipLiveShareServerRoomV4.version)
    }
  }

  @Test("codec rejects legacy control cases and open-ended envelopes")
  func rejectsLegacyAndOpenEndedInputs() throws {
    let legacyVersion = Data(
      #"{"payload":{},"type":"source-snapshot","version":3}"#.utf8
    )
    #expect(throws: ClipLiveShareProtocolError.unsupportedVersion(3)) {
      try ClipLiveShareMeshMediaControlCodec.decode(legacyVersion)
    }

    for removedType in [
      "membership-snapshot",
      "peer-link-offer",
      "leadership-proposal",
      "bootstrap-forward",
    ] {
      let data = Data(
        #"{"payload":{},"type":"\#(removedType)","version":4}"#.utf8
      )
      #expect(
        throws: ClipLiveShareMeshMediaControlError.unknownMessageType(
          removedType
        )
      ) {
        try ClipLiveShareMeshMediaControlCodec.decode(data)
      }
    }

    let smuggled = Data(
      #"{"legacy":{},"payload":{},"type":"source-cursor","version":4}"#.utf8
    )
    #expect(throws: ClipLiveShareProtocolError.self) {
      try ClipLiveShareMeshMediaControlCodec.decode(smuggled)
    }

    let oversized = Data(
      #"{"payload":{},"type":"future","version":4}"#.utf8
    )
    #expect(
      throws: ClipLiveShareProtocolError.messageTooLarge(
        maximum: 4,
        actual: oversized.count
      )
    ) {
      try ClipLiveShareMeshMediaControlCodec.decode(
        oversized,
        maximumBytes: 4
      )
    }
  }

  @Test("cursor remains bound to the authenticated source owner")
  func cursorOwnerBinding() throws {
    let fixture = try MeshMediaControlFixture()
    let otherParticipant = try ClipLiveShareNativeV3ParticipantID(
      bytes: Data(repeating: 0x44, count: 16)
    )

    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      _ = try ClipLiveShareNativeV3SourceCursor(
        sessionID: fixture.sessionID,
        participantID: otherParticipant,
        sourceKey: fixture.sourceKey,
        streamID: fixture.streamID,
        sequence: 1,
        position: nil
      )
    }
  }
}

private struct MeshMediaControlFixture {
  let sessionID: ClipLiveShareSessionID
  let participantID: ClipLiveShareNativeV3ParticipantID
  let sourceKey: ClipLiveShareNativeV3SourceKey
  let streamID: ClipLiveShareStreamID
  let sourceSnapshot: ClipLiveShareNativeV3SourceSnapshot
  let sourceCursor: ClipLiveShareNativeV3SourceCursor
  let collaboration: ClipLiveShareNativeV3CollaborationEvent
  let friendship: ClipLiveShareServerRoomV4SignedFriendMessage

  init() throws {
    sessionID = try ClipLiveShareSessionID(
      rawValue: "mesh-media-control-session"
    )
    participantID = try ClipLiveShareNativeV3ParticipantID(
      bytes: Data(repeating: 0x11, count: 16)
    )
    sourceKey = ClipLiveShareNativeV3SourceKey(
      ownerParticipantID: participantID,
      sourceInstanceID: try ClipLiveShareSourceInstanceID(
        bytes: Data(repeating: 0x22, count: 16)
      )
    )
    streamID = try ClipLiveShareStreamID(rawValue: "mesh-stream")
    sourceSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
      sessionID: sessionID,
      membershipRevision: ClipLiveShareNativeV3MembershipRevision(rawValue: 1),
      ownerParticipantID: participantID,
      sourceRevision: ClipLiveShareNativeV3SourceRevision(rawValue: 1),
      sources: []
    )
    sourceCursor = try ClipLiveShareNativeV3SourceCursor(
      sessionID: sessionID,
      participantID: participantID,
      sourceKey: sourceKey,
      streamID: streamID,
      sequence: 1,
      position: try .init(x: 0.25, y: 0.75)
    )
    collaboration = .pointer(
      ClipLiveShareNativeV3PointerEvent(
        context: try ClipLiveShareNativeV3CollaborationContext(
          sessionID: sessionID,
          participantID: participantID,
          sourceKey: sourceKey,
          sequence: 2,
          sentAt: ClipLiveShareNativeTimestamp(millisecondsSince1970: 1)
        ),
        position: try .init(x: 0.5, y: 0.5)
      )
    )
    let requesterSigner = ClipLiveShareSoftwareIdentitySigner()
    let accepterSigner = ClipLiveShareSoftwareIdentitySigner()
    let accepterParticipantID = try ClipLiveShareNativeV3ParticipantID(
      bytes: Data(repeating: 0x33, count: 16)
    )
    let profile = try ClipLiveShareServerRoomV4FriendProfile(
      identity: requesterSigner.publicKey,
      displayName: "Requester",
      deviceName: "Mac",
      locator: .random()
    )
    let request = try ClipLiveShareServerRoomV4FriendRequest(
      roomID: .random(),
      sessionID: sessionID,
      requesterParticipantID: participantID,
      accepterParticipantID: accepterParticipantID,
      requester: profile,
      expectedAccepterFingerprint: accepterSigner.publicKey.fingerprint,
      issuedAt: try .init(millisecondsSince1970: 1),
      expiresAt: try .init(millisecondsSince1970: 60_001)
    )
    friendship = try .init(signing: .request(request), with: requesterSigner)
  }
}
