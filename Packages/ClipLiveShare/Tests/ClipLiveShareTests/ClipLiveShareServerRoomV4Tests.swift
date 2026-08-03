import CryptoKit
import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Server-coordinated native mesh v4")
struct ClipLiveShareServerRoomV4Tests {
  @Test("invite path is human-readable, private payload stays client-only, and bytes are stable")
  func stablePrivateInvite() throws {
    let fixture = try V4Fixture()
    let invite = try fixture.invite(nonceByte: 9)
    let first = try invite.url
    let second = try invite.url

    #expect(first == second)
    #expect(first.path == "/" + fixture.roomCode.rawValue)
    #expect(first.query == nil)
    #expect(first.fragment?.hasPrefix("v=4&key=") == true)
    #expect(first.fragment?.hasSuffix("&join=" + fixture.admissionCapability.rawValue) == true)

    let serviceURL = try invite.serviceRoomURL
    #expect(serviceURL.fragment == nil)
    let serviceBytes = serviceURL.absoluteString
    #expect(serviceURL.path == "/" + fixture.roomCode.rawValue)
    #expect(!serviceBytes.contains(fixture.roomID.rawValue))
    #expect(!serviceBytes.contains(fixture.sessionID.rawValue))
    #expect(!serviceBytes.contains(fixture.admissionCapability.rawValue))
    #expect(!serviceBytes.contains(fixture.roomAgreementSecret.rawValue))
    #expect(!serviceBytes.contains(fixture.creatorSigner.publicKey.rawValue))

    let decoded = try ClipLiveShareServerRoomV4Invite(url: first)
    #expect(decoded == invite)
    #expect(decoded.roomCode == fixture.roomCode)
    #expect(decoded.description.contains("<redacted>"))
    #expect(!decoded.description.contains(fixture.admissionCapability.rawValue))

    let slashEndpointInvite = try ClipLiveShareServerRoomV4Invite(
      serviceEndpoint: URL(string: "https://mesh.clip.example/")!,
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      creatorIdentity: fixture.creatorSigner.publicKey,
      roomAgreementSecret: fixture.roomAgreementSecret,
      admissionCapability: fixture.admissionCapability,
      roomCode: fixture.roomCode
    )
    #expect(slashEndpointInvite.serviceEndpoint.absoluteString == "https://mesh.clip.example")
    #expect(
      try ClipLiveShareServerRoomV4Invite(url: slashEndpointInvite.url)
        == slashEndpointInvite
    )
  }

  @Test("only explicit New Invite rotation changes copied URL")
  func explicitOnlyInviteRotation() throws {
    let fixture = try V4Fixture()
    let invite = try fixture.invite(nonceByte: 4)
    var issuer = ClipLiveShareServerRoomV4InviteIssuer(currentInvite: invite)
    let stableURL = try issuer.currentInvite.url

    // Reading and unrelated immutable room state cannot rotate the issuer.
    for _ in 0..<10 { #expect(try issuer.currentInvite.url == stableURL) }

    let replacement = try ClipLiveShareServerRoomV4AdmissionCapability(
      bytes: Data(repeating: 0xA7, count: 32)
    )
    let rotated = try issuer.rotateInvite(to: replacement)
    #expect(try rotated.url != stableURL)
    #expect(rotated.roomID == invite.roomID)
    #expect(rotated.roomCode == invite.roomCode)
    #expect(try rotated.serviceRoomURL == invite.serviceRoomURL)
    #expect(rotated.sessionID == invite.sessionID)
    #expect(rotated.roomAgreementSecret == invite.roomAgreementSecret)
    #expect(rotated.creatorIdentity == invite.creatorIdentity)
    #expect(rotated.admissionCapability == replacement)
    #expect(try issuer.currentInvite.url == rotated.url)
  }

  @Test("invite authentication binds room code path and rejects noncanonical tampering")
  func inviteTamperResistance() throws {
    let fixture = try V4Fixture()
    let inviteURL = try fixture.invite(nonceByte: 7).url
    var components = try #require(URLComponents(url: inviteURL, resolvingAgainstBaseURL: false))
    components.path = "/MESH4APQ"
    let tampered = try #require(components.url)
    #expect(throws: (any Error).self) {
      try ClipLiveShareServerRoomV4Invite(url: tampered)
    }

    components = try #require(URLComponents(url: inviteURL, resolvingAgainstBaseURL: false))
    components.query = "leak=true"
    #expect(throws: (any Error).self) {
      try ClipLiveShareServerRoomV4Invite(url: try #require(components.url))
    }

    let canonicalComponents = try #require(
      URLComponents(url: inviteURL, resolvingAgainstBaseURL: false)
    )
    let fragment = try #require(canonicalComponents.percentEncodedFragment)
    for replacement in [
      "v=4&join=" + fixture.admissionCapability.rawValue + "&key="
        + String(fragment.split(separator: "&")[1].dropFirst(4)),
      fragment + "&unknown=1",
      fragment.replacingOccurrences(of: "v=4", with: "v=3"),
    ] {
      var tamperedComponents = try #require(
        URLComponents(url: inviteURL, resolvingAgainstBaseURL: false)
      )
      tamperedComponents.percentEncodedFragment = replacement
      #expect(throws: (any Error).self) {
        try ClipLiveShareServerRoomV4Invite(url: try #require(tamperedComponents.url))
      }
    }
  }

  @Test("room codes are normalized, bounded, and use the canonical alphabet")
  func roomCodes() throws {
    #expect(try ClipLiveShareServerRoomV4RoomCode(rawValue: "mesh4app").rawValue == "MESH4APP")
    #expect(throws: ClipLiveShareServerRoomV4Error.self) {
      try ClipLiveShareServerRoomV4RoomCode(rawValue: "SHORT")
    }
    #expect(throws: ClipLiveShareServerRoomV4Error.self) {
      try ClipLiveShareServerRoomV4RoomCode(rawValue: "MESH-APP")
    }
    for _ in 0..<64 {
      let code = ClipLiveShareServerRoomV4RoomCode.random().rawValue
      #expect(code.utf8.count == ClipLiveShareServerRoomV4.roomCodeLength)
      #expect(code.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) })
    }
  }

  @Test("join and admission resources are signed, encrypted, and context bound")
  func opaqueAdmissionSecurity() throws {
    let fixture = try V4Fixture()
    let descriptor = try fixture.descriptor(
      participantByte: 0x31,
      signer: fixture.aliceSigner,
      keyAgreement: fixture.aliceKeyAgreement,
      name: "Alice Secret Name"
    )
    let knock = try ClipLiveShareServerRoomV4JoinKnock(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      descriptor: descriptor,
      admissionCapability: fixture.admissionCapability,
      accessWordProof: ClipLiveShareNativeDigest(hashing: Data("access secret".utf8)),
      nonce: Data(repeating: 0x52, count: 32)
    )
    let signedKnock = try ClipLiveShareServerRoomV4SignedJoinKnock(
      signing: knock,
      with: fixture.aliceSigner
    )
    try signedKnock.verify(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      admissionCapability: fixture.admissionCapability
    )

    let cipher = fixture.roomCipher
    let opaqueKnock = try cipher.sealJoinKnock(
      signedKnock,
      nonce: Data(repeating: 0x63, count: 12)
    )
    #expect(!opaqueKnock.ciphertext.containsSubsequence(Data("Alice Secret Name".utf8)))
    #expect(try cipher.openJoinKnock(opaqueKnock) == signedKnock)

    let handle = try V4Fixture.fixedMemberHandle(0x42)
    let record = ClipLiveShareServerRoomV4AdmissionRecord(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      memberHandle: handle,
      descriptor: descriptor
    )
    let signedRecord = try ClipLiveShareServerRoomV4SignedAdmissionRecord(
      signing: record,
      with: fixture.creatorSigner
    )
    try signedRecord.verify(
      creatorIdentity: fixture.creatorSigner.publicKey,
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      expectedHandle: handle
    )
    let opaqueRecord = try cipher.sealAdmissionRecord(
      signedRecord,
      nonce: Data(repeating: 0x74, count: 12)
    )
    #expect(!opaqueRecord.ciphertext.containsSubsequence(descriptor.identity.x963Representation))
    #expect(try cipher.openAdmissionRecord(opaqueRecord) == signedRecord)

    var tampered = opaqueRecord.ciphertext
    tampered[tampered.index(before: tampered.endIndex)] ^= 1
    let tamperedRecord = try ClipLiveShareServerRoomV4OpaqueAdmissionRecord(ciphertext: tampered)
    #expect(throws: ClipLiveShareProtocolError.authenticationFailed) {
      try cipher.openAdmissionRecord(tamperedRecord)
    }
  }

  @Test("member descriptors carry one closed versioned participant profile")
  func memberDescriptorProfiles() throws {
    let fixture = try V4Fixture()
    let native = try fixture.descriptor(
      participantByte: 0x31,
      signer: fixture.aliceSigner,
      keyAgreement: fixture.aliceKeyAgreement,
      name: "Native Participant"
    )
    #expect(native.clientKind == .nativeApp)
    #expect(native.capabilityProfile == .nativeV1)

    let web = try ClipLiveShareServerRoomV4MemberDescriptor(
      participantID: native.participantID,
      identity: native.identity,
      pairSignalingPublicKey: native.pairSignalingPublicKey,
      displayName: "Web Participant",
      deviceName: "Safari",
      clientKind: .webViewer,
      capabilityProfile: .webViewerV1
    )
    #expect(web.clientKind == .webViewer)
    #expect(web.capabilityProfile == .webViewerV1)
    #expect(web.canonicalRepresentation != native.canonicalRepresentation)

    let encoded = try JSONEncoder().encode(web)
    let root = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(root["clientKind"] as? String == "webViewer")
    #expect(root["capabilityProfile"] as? String == "webViewerV1")
    #expect(
      try JSONDecoder().decode(
        ClipLiveShareServerRoomV4MemberDescriptor.self,
        from: encoded
      ) == web
    )

    #expect(throws: ClipLiveShareServerRoomV4Error.self) {
      try ClipLiveShareServerRoomV4MemberDescriptor(
        participantID: native.participantID,
        identity: native.identity,
        pairSignalingPublicKey: native.pairSignalingPublicKey,
        displayName: "Invalid Participant",
        deviceName: "Invalid Device",
        clientKind: .nativeApp,
        capabilityProfile: .webViewerV1
      )
    }

    for mutation in [
      { (value: inout [String: Any]) in
        _ = value.removeValue(forKey: "capabilityProfile")
      },
      { (value: inout [String: Any]) in value["capabilityProfile"] = "futureV99" },
      { (value: inout [String: Any]) in value["clientKind"] = "nativeApp" },
      { (value: inout [String: Any]) in value["capabilities"] = ["publish": true] },
    ] {
      var invalid = root
      mutation(&invalid)
      let data = try JSONSerialization.data(withJSONObject: invalid)
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
          ClipLiveShareServerRoomV4MemberDescriptor.self,
          from: data
        )
      }
    }

    let vector = try V4WebMemberDescriptorFixture.load()
    #expect(vector.descriptor == web)
    #expect(
      ClipLiveShareBase64URL.encode(web.canonicalRepresentation)
        == vector.descriptorCanonicalBase64URL
    )
    #expect(vector.signedJoinKnock.knock.descriptor == web)
    #expect(vector.identityPublicKeyBase64URL == web.identity.rawValue)
    #expect(
      vector.signatureBase64URL
        == vector.signedJoinKnock.signature.rawValue
    )
    #expect(
      ClipLiveShareBase64URL.encode(
        vector.signedJoinKnock.knock.canonicalRepresentation
      ) == vector.joinKnockCanonicalBase64URL
    )
    try vector.signedJoinKnock.verify(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      admissionCapability: fixture.admissionCapability
    )
  }

  @Test("rosters are bounded, canonical, and order independent")
  func rosterValidationAndOrdering() throws {
    let fixture = try V4Fixture()
    let handles = try [0x44, 0x11, 0x33, 0x22].map(V4Fixture.fixedMemberHandle)
    let members = try handles.map { try fixture.rosterMember(handle: $0) }
    let roster = try ClipLiveShareServerRoomV4RosterSnapshot(
      revision: .init(rawValue: 9),
      creatorHandle: handles[0],
      members: members
    )
    #expect(roster.members.map(\.handle) == handles.sorted())

    let reversed = try ClipLiveShareServerRoomV4RosterSnapshot(
      revision: .init(rawValue: 9),
      creatorHandle: handles[0],
      members: members.reversed()
    )
    #expect(roster == reversed)
    #expect(throws: ClipLiveShareServerRoomV4Error.self) {
      try ClipLiveShareServerRoomV4RosterSnapshot(
        revision: .init(rawValue: 1),
        creatorHandle: handles[0],
        members: [members[0], members[0]]
      )
    }
    #expect(throws: ClipLiveShareServerRoomV4Error.self) {
      try ClipLiveShareServerRoomV4RosterSnapshot(
        revision: .init(rawValue: 1),
        creatorHandle: try V4Fixture.fixedMemberHandle(0xEF),
        members: members
      )
    }
    #expect(throws: ClipLiveShareServerRoomV4Error.self) {
      try ClipLiveShareServerRoomV4RosterSnapshot(
        revision: .init(rawValue: 1),
        creatorHandle: handles[0],
        members: members + [try fixture.rosterMember(handle: V4Fixture.fixedMemberHandle(0x55))]
      )
    }
  }

  @Test("roster revisions reconcile sets without touching retained pair epochs")
  func pairSetReconciliationIsIndependent() throws {
    let fixture = try V4Fixture()
    let a = try V4Fixture.fixedMemberHandle(0x10)
    let b = try V4Fixture.fixedMemberHandle(0x20)
    let c = try V4Fixture.fixedMemberHandle(0x30)
    let first = try fixture.roster(revision: 1, creator: a, handles: [a, b])
    let second = try fixture.roster(revision: 88, creator: a, handles: [c, b, a])

    let initial = try ClipLiveShareServerRoomV4PairReconciliationPlan(
      existingPeers: [],
      localHandle: a,
      snapshot: first
    )
    #expect(initial.added == [b])
    let expanded = try ClipLiveShareServerRoomV4PairReconciliationPlan(
      existingPeers: [b],
      localHandle: a,
      snapshot: second
    )
    #expect(expanded.added == [c])
    #expect(expanded.retained == [b])
    #expect(expanded.removed.isEmpty)

    let context = try fixture.pairContext(
      firstHandle: a,
      firstParticipantByte: 0xF0,
      secondHandle: b,
      secondParticipantByte: 0x01
    )
    var negotiation = ClipLiveShareServerRoomV4PairNegotiationState(
      context: context,
      epoch: try .init(rawValue: 4)
    )
    _ = expanded
    #expect(negotiation.epoch.rawValue == 4)
    #expect(try negotiation.advanceEpoch().rawValue == 5)
  }

  @Test("pair identity is symmetric and offerer follows participant ID, not handle")
  func pairIdentityAndOfferer() throws {
    let fixture = try V4Fixture()
    let lowHandle = try V4Fixture.fixedMemberHandle(0x01)
    let highHandle = try V4Fixture.fixedMemberHandle(0xF1)
    let lowHandleParticipant = try V4Fixture.fixedParticipantID(0xF0)
    let highHandleParticipant = try V4Fixture.fixedParticipantID(0x02)
    let forward = try ClipLiveShareServerRoomV4PairContext(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      firstHandle: lowHandle,
      firstParticipantID: lowHandleParticipant,
      secondHandle: highHandle,
      secondParticipantID: highHandleParticipant
    )
    let reverse = try ClipLiveShareServerRoomV4PairContext(
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      firstHandle: highHandle,
      firstParticipantID: highHandleParticipant,
      secondHandle: lowHandle,
      secondParticipantID: lowHandleParticipant
    )
    #expect(forward == reverse)
    #expect(forward.initialOfferer == highHandle)
    #expect(forward.initialOffererParticipantID == highHandleParticipant)

    let changedSession = try ClipLiveShareServerRoomV4PairContext(
      roomID: fixture.roomID,
      sessionID: .random(),
      firstHandle: lowHandle,
      firstParticipantID: lowHandleParticipant,
      secondHandle: highHandle,
      secondParticipantID: highHandleParticipant
    )
    #expect(changedSession.pairID == forward.pairID)
    #expect(changedSession != forward)
  }

  @Test("four members derive exactly six stable direct pairs")
  func completeFourMemberGraph() throws {
    let fixture = try V4Fixture()
    let handles = try (1...4).map { try V4Fixture.fixedMemberHandle(UInt8($0)) }
    let participantIDs = try (1...4).map {
      try V4Fixture.fixedParticipantID(UInt8(0x10 + $0))
    }
    var pairs = Set<ClipLiveShareServerRoomV4PairID>()
    for left in 0..<handles.count {
      for right in (left + 1)..<handles.count {
        let context = try ClipLiveShareServerRoomV4PairContext(
          roomID: fixture.roomID,
          sessionID: fixture.sessionID,
          firstHandle: handles[left],
          firstParticipantID: participantIDs[left],
          secondHandle: handles[right],
          secondParticipantID: participantIDs[right]
        )
        pairs.insert(context.pairID)
      }
    }
    #expect(pairs.count == 6)
  }

  @Test("pair signaling signs, encrypts, orders, and round trips every case")
  func pairSignalingRoundTrip() throws {
    let fixture = try V4Fixture()
    var (alice, bob, context) = try fixture.pairChannels()
    let epoch = try ClipLiveShareServerRoomV4PairEpoch(rawValue: 3)
    let payloads: [ClipLiveShareServerRoomV4PairSignalPayload] = [
      .offer(epoch: epoch, sdp: "v=0\r\na=offer\r\n"),
      .answer(epoch: epoch, sdp: "v=0\r\na=answer\r\n"),
      .iceCandidate(
        epoch: epoch,
        candidate: "candidate:1 1 udp 1 127.0.0.1 5000 typ host",
        mediaID: "video0",
        mediaLineIndex: 0
      ),
      .iceCandidate(epoch: epoch, candidate: "", mediaID: nil, mediaLineIndex: nil),
      .iceRestart(epoch: try epoch.next()),
      .renegotiationRequest(epoch: try epoch.next()),
      .codecRenegotiationRequest(
        epoch: try epoch.next(),
        codec: .av1
      ),
      .codecRenegotiationRejected(
        epoch: try epoch.next(),
        codec: .av1
      ),
      .close,
    ]
    for payload in payloads {
      let outbound = try alice.seal(payload)
      #expect(outbound.from == nil)
      #expect(outbound.pairID == context.pairID)
      let forwarded = try outbound.routedFrom(alice.localHandle)
      #expect(try bob.open(forwarded) == payload)
    }

    let replay = try alice.seal(.close).routedFrom(alice.localHandle)
    #expect(try bob.open(replay) == .close)
    #expect(throws: ClipLiveShareProtocolError.self) { try bob.open(replay) }
  }

  @Test("codec request canonical bytes match the browser implementation")
  func codecRequestBrowserCanonicalVector() throws {
    let payload = ClipLiveShareServerRoomV4PairSignalPayload
      .codecRenegotiationRequest(
        epoch: try .init(rawValue: 1),
        codec: .av1
      )
    #expect(
      ClipLiveShareBase64URL.encode(payload.canonicalRepresentation)
        == "AAAAMmNsaXAtbGl2ZS1zaGFyZS1zZXJ2ZXItcm9vbS12NC9wYWlyLXNpZ25hbC1wYXlsb2FkAAAAAAAAAAQAAAAbY29kZWMtcmVuZWdvdGlhdGlvbi1yZXF1ZXN0AAAAAAAAAAEAAAADYXYx"
    )
  }

  @Test("pair signaling rejects direction, context, ciphertext, and identity tamper")
  func pairSignalingTamperResistance() throws {
    let fixture = try V4Fixture()
    var (alice, bob, context) = try fixture.pairChannels()
    let message = try alice.seal(
      .offer(epoch: try .init(rawValue: 1), sdp: "v=0\r\n")
    ).routedFrom(alice.localHandle)
    let wrongDirection = try ClipLiveShareServerRoomV4PairSignalEnvelope(
      from: message.to,
      to: try #require(message.from),
      pairID: message.pairID,
      sequence: message.sequence,
      ciphertext: message.ciphertext
    )
    #expect(throws: ClipLiveShareServerRoomV4Error.invalidPairContext) {
      try bob.open(wrongDirection)
    }

    var bytes = message.ciphertext
    bytes[bytes.index(before: bytes.endIndex)] ^= 1
    let tampered = try ClipLiveShareServerRoomV4PairSignalEnvelope(
      from: message.from,
      to: message.to,
      pairID: context.pairID,
      sequence: message.sequence,
      ciphertext: bytes
    )
    #expect(throws: ClipLiveShareProtocolError.authenticationFailed) {
      try bob.open(tampered)
    }
  }

  @Test("closed wire codec round trips every case")
  func closedWireRoundTrip() throws {
    let fixture = try V4Fixture()
    let candidate = try V4Fixture.fixedCandidateHandle(0xA1)
    let member = try V4Fixture.fixedMemberHandle(0xA2)
    let knock = try ClipLiveShareServerRoomV4OpaqueJoinKnock(
      ciphertext: fixture.sealedOpaqueBytes(byte: 0x19)
    )
    let admission = try ClipLiveShareServerRoomV4OpaqueAdmissionRecord(
      ciphertext: fixture.sealedOpaqueBytes(byte: 0x29)
    )
    let roster = try fixture.roster(revision: 2, creator: member, handles: [member])
    var (alice, _, _) = try fixture.pairChannels()
    let pairSignal = try alice.seal(.renegotiationRequest(epoch: .init(rawValue: 2)))
    let reconnect = try ClipLiveShareServerRoomV4ReconnectCapability(
      bytes: Data(repeating: 0x39, count: 32)
    )
    let messages: [ClipLiveShareServerRoomV4WireMessage] = [
      .candidateOpened(candidateHandle: candidate, roomDescriptor: admission),
      .joinKnock(candidateHandle: candidate, sequence: 1, payload: knock),
      .joinKnock(candidateHandle: nil, sequence: 2, payload: knock),
      .admitCandidate(candidateHandle: candidate, descriptor: admission),
      .denyCandidate(candidateHandle: candidate, reason: "invalid-access-word"),
      .memberAdmitted(
        memberHandle: member,
        reconnectCapability: reconnect,
        roster: roster
      ),
      .rosterSnapshot(roster),
      .pairSignal(pairSignal),
      .leaveRoom,
      .removeMember(member),
      .roomEnded(reason: "creator-reconnect-expired"),
      .protocolError(
        code: "stale-sequence",
        message: "sequence was stale",
        pair: try .init(
          pairID: pairSignal.pairID,
          remoteHandle: pairSignal.to,
          sequence: pairSignal.sequence
        )
      ),
    ]
    for message in messages {
      let data = try ClipLiveShareServerRoomV4WireCodec.encode(message)
      #expect(try ClipLiveShareServerRoomV4WireCodec.decode(data) == message)
      let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(root["type"] as? String == message.type)
      #expect(root["version"] as? Int == 4)
    }
  }

  @Test("wire codec rejects unknown, smuggled, oversized, and malformed values")
  func strictWireRejection() throws {
    let unknown = Data(#"{"type":"future","version":4}"#.utf8)
    #expect(throws: ClipLiveShareServerRoomV4Error.unknownWireMessage("future")) {
      try ClipLiveShareServerRoomV4WireCodec.decode(unknown)
    }
    let old = Data(#"{"type":"leave-room","version":3}"#.utf8)
    #expect(throws: ClipLiveShareProtocolError.unsupportedVersion(3)) {
      try ClipLiveShareServerRoomV4WireCodec.decode(old)
    }
    let smuggled = Data(
      #"{"legacy":true,"payload":{},"type":"leave-room","version":4}"#.utf8
    )
    #expect(throws: ClipLiveShareServerRoomV4Error.self) {
      try ClipLiveShareServerRoomV4WireCodec.decode(smuggled)
    }
    let payloadSmuggle = Data(
      #"{"payload":{"leader":"forged"},"type":"leave-room","version":4}"#.utf8
    )
    #expect(throws: ClipLiveShareServerRoomV4Error.self) {
      try ClipLiveShareServerRoomV4WireCodec.decode(payloadSmuggle)
    }
    #expect(throws: ClipLiveShareProtocolError.messageTooLarge(maximum: 8, actual: unknown.count)) {
      try ClipLiveShareServerRoomV4WireCodec.decode(unknown, maximumBytes: 8)
    }
  }

  @Test("outer service messages reveal no participant, room, or signaling plaintext")
  func privacyBoundary() throws {
    let fixture = try V4Fixture()
    let descriptor = try fixture.descriptor(
      participantByte: 0x77,
      signer: fixture.aliceSigner,
      keyAgreement: fixture.aliceKeyAgreement,
      name: "Highly Private Participant"
    )
    let handle = try V4Fixture.fixedMemberHandle(0x55)
    let signed = try ClipLiveShareServerRoomV4SignedAdmissionRecord(
      signing: .init(
        roomID: fixture.roomID,
        sessionID: fixture.sessionID,
        memberHandle: handle,
        descriptor: descriptor
      ),
      with: fixture.creatorSigner
    )
    let opaque = try fixture.roomCipher.sealAdmissionRecord(signed)
    let roster = try ClipLiveShareServerRoomV4RosterSnapshot(
      revision: .init(rawValue: 1),
      creatorHandle: handle,
      members: [
        .init(handle: handle, descriptor: opaque, connected: true)
      ]
    )
    let wire = try ClipLiveShareServerRoomV4WireCodec.encode(.rosterSnapshot(roster))
    let text = String(decoding: wire, as: UTF8.self)
    #expect(!text.contains("Highly Private Participant"))
    #expect(!text.contains(fixture.sessionID.rawValue))
    #expect(!text.contains(fixture.roomAgreementSecret.rawValue))
    #expect(!text.contains(fixture.admissionCapability.rawValue))
    #expect(!text.contains(descriptor.identity.rawValue))

    var (alice, _, _) = try fixture.pairChannels()
    let signal = try alice.seal(
      .offer(epoch: .init(rawValue: 1), sdp: "PRIVATE-SDP-CONTENTS")
    )
    let signalWire = String(
      decoding: try ClipLiveShareServerRoomV4WireCodec.encode(.pairSignal(signal)),
      as: UTF8.self
    )
    #expect(!signalWire.contains("PRIVATE-SDP-CONTENTS"))
  }

  @Test("canonical pair and encrypted invite vectors remain fixed")
  func canonicalVectors() throws {
    let fixture = try V4Fixture()
    let context = try ClipLiveShareServerRoomV4PairContext(
      roomID: V4Fixture.fixedRoomID(0x01),
      sessionID: fixture.sessionID,
      firstHandle: V4Fixture.fixedMemberHandle(0x02),
      firstParticipantID: V4Fixture.fixedParticipantID(0x21),
      secondHandle: V4Fixture.fixedMemberHandle(0x03),
      secondParticipantID: V4Fixture.fixedParticipantID(0x22)
    )
    #expect(
      context.pairID.rawValue
        == "LjIVx8KDdzl4gf3-NxR_0Rs1BVtaVMO0DB89lbPmvHo"
    )
    let inviteVector = try fixture.invite(nonceByte: 0x0A).url.absoluteString
    let webFixture = try V4WebInviteFixture.load()
    #expect(inviteVector == webFixture.url.absoluteString)

    let decoded = try ClipLiveShareServerRoomV4Invite(url: webFixture.url)
    #expect(decoded.roomCode.rawValue == webFixture.roomCode)
    #expect(decoded.roomID.rawValue == webFixture.roomID)
    #expect(decoded.sessionID.rawValue == webFixture.sessionID)
    #expect(decoded.admissionCapability.rawValue == webFixture.admissionCapability)
    #expect(decoded.roomAgreementSecret.rawValue == webFixture.roomAgreementSecret)
  }

  @Test("Swift decodes and re-encodes every authoritative Go wire fixture")
  func goWireCanonicalFixture() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot =
      testFile
      .deletingLastPathComponent()  // ClipLiveShareTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // ClipLiveShare
      .deletingLastPathComponent()  // Packages
      .deletingLastPathComponent()  // repository
    let fixtureURL = repositoryRoot.appendingPathComponent(
      "server/internal/protocol/testdata/native-room-v4-wire.json"
    )
    let data = try Data(contentsOf: fixtureURL)
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let vectors = try #require(root["messages"] as? [[String: Any]])
    #expect(vectors.count == 6)

    for vector in vectors {
      let original = try #require(vector["message"] as? [String: Any])
      let originalData = try JSONSerialization.data(
        withJSONObject: original,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      let decoded = try ClipLiveShareServerRoomV4WireCodec.decode(originalData)
      let encoded = try ClipLiveShareServerRoomV4WireCodec.encode(decoded)
      let roundTrip = try #require(
        JSONSerialization.jsonObject(with: encoded) as? NSDictionary
      )
      #expect(roundTrip == (original as NSDictionary))
    }
  }

  @Test("Swift opens and verifies the browser interop fixture")
  func browserPairInteropVector() throws {
    let fixture = try V4Fixture()
    var (_, browserChannel, context) = try fixture.pairChannels()
    let nativeHandle = try V4Fixture.fixedMemberHandle(0x11)
    let browserHandle = try V4Fixture.fixedMemberHandle(0x22)
    let expectedNativeDescriptor = try fixture.descriptor(
      participantByte: 0x31,
      signer: fixture.aliceSigner,
      keyAgreement: fixture.aliceKeyAgreement,
      name: "Native Fixture"
    )
    let expectedBrowserDescriptor = try ClipLiveShareServerRoomV4MemberDescriptor(
      participantID: V4Fixture.fixedParticipantID(0x32),
      identity: fixture.bobSigner.publicKey,
      pairSignalingPublicKey: fixture.bobKeyAgreement.publicKey,
      displayName: "Web Fixture",
      deviceName: "Browser",
      clientKind: .webViewer,
      capabilityProfile: .webViewerV1
    )
    let testFile = URL(fileURLWithPath: #filePath)
    let fixtureURL = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(
        "Fixtures/server-room-v4-browser-pair.json"
      )
    let root = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
    )
    #expect(root["roomId"] as? String == fixture.roomID.rawValue)
    #expect(root["sessionId"] as? String == fixture.sessionID.rawValue)
    #expect(root["roomAgreementSecret"] as? String == fixture.roomAgreementSecret.rawValue)
    #expect(root["creatorIdentity"] as? String == fixture.creatorSigner.publicKey.rawValue)
    #expect(root["nativeHandle"] as? String == nativeHandle.rawValue)
    #expect(root["browserHandle"] as? String == browserHandle.rawValue)
    #expect(root["pairId"] as? String == context.pairID.rawValue)

    let decoder = JSONDecoder()
    let nativeDescriptor = try decoder.decode(
      ClipLiveShareServerRoomV4MemberDescriptor.self,
      from: JSONSerialization.data(withJSONObject: try #require(root["nativeDescriptor"]))
    )
    let browserDescriptor = try decoder.decode(
      ClipLiveShareServerRoomV4MemberDescriptor.self,
      from: JSONSerialization.data(withJSONObject: try #require(root["browserDescriptor"]))
    )
    #expect(nativeDescriptor == expectedNativeDescriptor)
    #expect(browserDescriptor == expectedBrowserDescriptor)

    let opaqueValue = try #require(root["opaqueAdmissionRecord"] as? String)
    let opaqueBytes = try #require(ClipLiveShareBase64URL.decode(opaqueValue))
    let signedAdmission = try fixture.roomCipher.openAdmissionRecord(
      .init(ciphertext: opaqueBytes)
    )
    try signedAdmission.verify(
      creatorIdentity: fixture.creatorSigner.publicKey,
      roomID: fixture.roomID,
      sessionID: fixture.sessionID,
      expectedHandle: browserHandle
    )
    #expect(signedAdmission.record.descriptor == expectedBrowserDescriptor)

    let envelopeObject = try #require(root["envelope"] as? [String: Any])
    let payloadValue = try #require(envelopeObject["payload"] as? String)
    let ciphertext = try #require(ClipLiveShareBase64URL.decode(payloadValue))
    let envelope = try ClipLiveShareServerRoomV4PairSignalEnvelope(
      from: .init(rawValue: try #require(envelopeObject["from"] as? String)),
      to: .init(rawValue: try #require(envelopeObject["to"] as? String)),
      pairID: .init(rawValue: try #require(envelopeObject["pairId"] as? String)),
      sequence: try #require(envelopeObject["sequence"] as? UInt64),
      ciphertext: ciphertext
    )
    #expect(
      try browserChannel.open(envelope)
        == .offer(epoch: .init(rawValue: 1), sdp: "v=0\r\n")
    )
  }

  @Test("creator HTTP request matches the Go create-room contract")
  func creatorCreateContract() throws {
    let fixture = try V4Fixture()
    let candidate = try V4Fixture.fixedCandidateHandle(0x42)
    let descriptor = try ClipLiveShareServerRoomV4OpaqueAdmissionRecord(
      ciphertext: fixture.sealedOpaqueBytes(byte: 0x51)
    )
    let owner = try ClipLiveShareServerRoomV4OwnerCapability(
      bytes: Data(repeating: 0x61, count: 32)
    )
    let request = ClipLiveShareServerRoomV4CreateRequest(
      ownerToken: owner,
      creatorHandle: candidate.admittedMemberHandle,
      descriptor: descriptor
    )
    let data = try serverRoomV4StrictEncode(request, maximumBytes: 16 * 1_024)
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(root.keys) == ["ownerToken", "creatorHandle", "descriptor"])
    #expect(root["ownerToken"] as? String == owner.rawValue)
    #expect(root["creatorHandle"] as? String == candidate.rawValue)
    #expect(root["descriptor"] as? String == descriptor.rawValue)
  }
}

private struct V4WebMemberDescriptorFixture: Decodable {
  let descriptor: ClipLiveShareServerRoomV4MemberDescriptor
  let descriptorCanonicalBase64URL: String
  let joinKnockCanonicalBase64URL: String
  let identityPublicKeyBase64URL: String
  let signatureBase64URL: String
  let signedJoinKnock: ClipLiveShareServerRoomV4SignedJoinKnock

  static func load() throws -> Self {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot =
      testFile
      .deletingLastPathComponent()  // ClipLiveShareTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // ClipLiveShare
      .deletingLastPathComponent()  // Packages
      .deletingLastPathComponent()  // repository
    let fixtureURL = repositoryRoot.appendingPathComponent(
      "Packages/ClipLiveShare/Tests/Fixtures/server-room-v4-web-member-descriptor.json"
    )
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: fixtureURL))
  }
}

private struct V4Fixture {
  let roomCode = try! ClipLiveShareServerRoomV4RoomCode(rawValue: "MESH4APP")
  let roomID = try! fixedRoomID(0x10)
  let sessionID = try! ClipLiveShareSessionID(rawValue: "v4-session-vector")
  let admissionCapability = try! ClipLiveShareServerRoomV4AdmissionCapability(
    bytes: Data(repeating: 0x20, count: 32)
  )
  let roomAgreementSecret = try! ClipLiveShareServerRoomV4RoomAgreementSecret(
    bytes: Data(repeating: 0x30, count: 32)
  )
  let creatorSigner = try! ClipLiveShareSoftwareIdentitySigner(
    rawRepresentation: Data(repeating: 0x01, count: 32)
  )
  let aliceSigner = try! ClipLiveShareSoftwareIdentitySigner(
    rawRepresentation: Data(repeating: 0x02, count: 32)
  )
  let bobSigner = try! ClipLiveShareSoftwareIdentitySigner(
    rawRepresentation: Data(repeating: 0x03, count: 32)
  )
  let aliceKeyAgreement = try! ClipLiveShareServerRoomV4KeyAgreementIdentity(
    rawRepresentation: Data(repeating: 0x04, count: 32)
  )
  let bobKeyAgreement = try! ClipLiveShareServerRoomV4KeyAgreementIdentity(
    rawRepresentation: Data(repeating: 0x05, count: 32)
  )

  init() throws {}

  var roomCipher: ClipLiveShareServerRoomV4RoomCipher {
    .init(
      roomID: roomID,
      sessionID: sessionID,
      roomAgreementSecret: roomAgreementSecret
    )
  }

  func invite(nonceByte: UInt8) throws -> ClipLiveShareServerRoomV4Invite {
    try .init(
      serviceEndpoint: URL(string: "https://mesh.clip.example")!,
      roomCode: roomCode,
      roomID: roomID,
      sessionID: sessionID,
      creatorIdentity: creatorSigner.publicKey,
      roomAgreementSecret: roomAgreementSecret,
      admissionCapability: admissionCapability,
      nonce: Data(repeating: nonceByte, count: 12)
    )
  }

  func descriptor(
    participantByte: UInt8,
    signer: ClipLiveShareSoftwareIdentitySigner,
    keyAgreement: ClipLiveShareServerRoomV4KeyAgreementIdentity,
    name: String
  ) throws -> ClipLiveShareServerRoomV4MemberDescriptor {
    try .init(
      participantID: Self.fixedParticipantID(participantByte),
      identity: signer.publicKey,
      pairSignalingPublicKey: keyAgreement.publicKey,
      displayName: name,
      deviceName: "Private Device",
      clientKind: .nativeApp,
      capabilityProfile: .nativeV1
    )
  }

  func rosterMember(
    handle: ClipLiveShareServerRoomV4MemberHandle
  ) throws -> ClipLiveShareServerRoomV4RosterMember {
    let descriptor = try self.descriptor(
      participantByte: handle.bytes.first ?? 1,
      signer: aliceSigner,
      keyAgreement: aliceKeyAgreement,
      name: "Private Name"
    )
    let record = ClipLiveShareServerRoomV4AdmissionRecord(
      roomID: roomID,
      sessionID: sessionID,
      memberHandle: handle,
      descriptor: descriptor
    )
    let signed = try ClipLiveShareServerRoomV4SignedAdmissionRecord(
      signing: record,
      with: creatorSigner
    )
    return try .init(
      handle: handle,
      descriptor: roomCipher.sealAdmissionRecord(signed),
      connected: true
    )
  }

  func roster(
    revision: UInt64,
    creator: ClipLiveShareServerRoomV4MemberHandle,
    handles: [ClipLiveShareServerRoomV4MemberHandle]
  ) throws -> ClipLiveShareServerRoomV4RosterSnapshot {
    try .init(
      revision: .init(rawValue: revision),
      creatorHandle: creator,
      members: handles.map { try rosterMember(handle: $0) }
    )
  }

  func pairContext(
    firstHandle: ClipLiveShareServerRoomV4MemberHandle,
    firstParticipantByte: UInt8,
    secondHandle: ClipLiveShareServerRoomV4MemberHandle,
    secondParticipantByte: UInt8
  ) throws -> ClipLiveShareServerRoomV4PairContext {
    try .init(
      roomID: roomID,
      sessionID: sessionID,
      firstHandle: firstHandle,
      firstParticipantID: Self.fixedParticipantID(firstParticipantByte),
      secondHandle: secondHandle,
      secondParticipantID: Self.fixedParticipantID(secondParticipantByte)
    )
  }

  func pairChannels() throws -> (
    ClipLiveShareServerRoomV4EncryptedPairSignalingChannel,
    ClipLiveShareServerRoomV4EncryptedPairSignalingChannel,
    ClipLiveShareServerRoomV4PairContext
  ) {
    let aliceHandle = try Self.fixedMemberHandle(0x11)
    let bobHandle = try Self.fixedMemberHandle(0x22)
    let context = try pairContext(
      firstHandle: aliceHandle,
      firstParticipantByte: 0x31,
      secondHandle: bobHandle,
      secondParticipantByte: 0x32
    )
    return try (
      .init(
        context: context,
        localHandle: aliceHandle,
        localKeyAgreementIdentity: aliceKeyAgreement,
        localIdentitySigner: aliceSigner,
        remoteKeyAgreementPublicKey: bobKeyAgreement.publicKey,
        remoteIdentity: bobSigner.publicKey
      ),
      .init(
        context: context,
        localHandle: bobHandle,
        localKeyAgreementIdentity: bobKeyAgreement,
        localIdentitySigner: bobSigner,
        remoteKeyAgreementPublicKey: aliceKeyAgreement.publicKey,
        remoteIdentity: aliceSigner.publicKey
      ),
      context
    )
  }

  func sealedOpaqueBytes(byte: UInt8) -> Data {
    Data(repeating: byte, count: 12 + 1 + 16)
  }

  static func fixedRoomID(_ byte: UInt8) throws -> ClipLiveShareServerRoomV4RoomID {
    try .init(bytes: Data(repeating: byte, count: 32))
  }
  static func fixedMemberHandle(
    _ byte: UInt8
  ) throws -> ClipLiveShareServerRoomV4MemberHandle {
    try .init(bytes: Data(repeating: byte, count: 16))
  }
  static func fixedCandidateHandle(
    _ byte: UInt8
  ) throws -> ClipLiveShareServerRoomV4CandidateHandle {
    try .init(bytes: Data(repeating: byte, count: 16))
  }
  static func fixedParticipantID(
    _ byte: UInt8
  ) throws -> ClipLiveShareNativeV3ParticipantID {
    try .init(bytes: Data(repeating: byte, count: 16))
  }
}

private struct V4WebInviteFixture: Decodable {
  let url: URL
  let roomCode: String
  let roomID: String
  let sessionID: String
  let admissionCapability: String
  let roomAgreementSecret: String

  enum CodingKeys: String, CodingKey {
    case url
    case roomCode
    case roomID = "roomId"
    case sessionID = "sessionId"
    case admissionCapability
    case roomAgreementSecret
  }

  static func load() throws -> Self {
    let testFile = URL(fileURLWithPath: #filePath)
    let fixtureURL =
      testFile
      .deletingLastPathComponent()  // ClipLiveShareTests
      .deletingLastPathComponent()  // Tests
      .appendingPathComponent("Fixtures/server-room-v4-invite.json")
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: fixtureURL))
  }
}

extension Data {
  fileprivate func containsSubsequence(_ other: Data) -> Bool {
    guard !other.isEmpty, other.count <= count else { return false }
    return ranges(of: other).isEmpty == false
  }

  fileprivate func ranges(of needle: Data) -> [Range<Data.Index>] {
    var result: [Range<Data.Index>] = []
    var searchStart = startIndex
    while searchStart < endIndex,
      let range = self[searchStart...].range(of: needle)
    {
      result.append(range)
      searchStart = range.upperBound
    }
    return result
  }
}
