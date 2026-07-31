import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Clip Live Share native v3 bootstrap")
struct ClipLiveShareNativeV3BootstrapTests {
  @Test("signed hello is rendezvous-bound, fresh, and compatible")
  func signedHelloVerification() throws {
    let fixture = try BootstrapFixture()
    let hello = try fixture.signedHello()

    try hello.verify(
      expectedSessionID: fixture.sessionID,
      expectedRendezvousProof: fixture.rendezvousProof,
      at: fixture.now
    )
    #expect(throws: ClipLiveShareNativeV3BootstrapError.rendezvousProofMismatch) {
      try hello.verify(
        expectedSessionID: fixture.sessionID,
        expectedRendezvousProof: fixture.rendezvousProof(
          transportByte: 0xEE
        ),
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      try hello.verify(
        expectedSessionID: try .init(rawValue: "wrong-bootstrap-session"),
        expectedRendezvousProof: fixture.rendezvousProof,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV3BootstrapError.rendezvousProofMismatch) {
      try hello.verify(
        expectedSessionID: fixture.sessionID,
        expectedRendezvousProof: fixture.rendezvousProof(
          foundingCreatorIdentity: fixture.outsiderSigner.publicKey
        ),
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.expired) {
      try hello.verify(
        expectedSessionID: fixture.sessionID,
        expectedRendezvousProof: fixture.rendezvousProof,
        at: hello.hello.expiresAt
      )
    }
  }

  @Test("v3 rendezvous proof binds session route creator and transport")
  func authenticatedRendezvousProof() throws {
    let fixture = try BootstrapFixture()
    let first = fixture.rendezvousProof
    let repeated = fixture.rendezvousProof
    #expect(first == repeated)
    #expect(first != fixture.rendezvousProof(transportByte: 0x99))
    #expect(first != fixture.rendezvousProof(routeByte: 0x53))
    #expect(
      first
        != fixture.rendezvousProof(
          sessionID: try .init(rawValue: "another-bootstrap-session")
        )
    )
    #expect(
      first
        != fixture.rendezvousProof(
          foundingCreatorIdentity: fixture.outsiderSigner.publicKey
        )
    )
  }

  @Test("v3 access word proof is normalized and route bound")
  func accessWordProof() throws {
    let fixture = try BootstrapFixture()
    let proof = try ClipLiveShareNativeV3AccessWordProof(
      accessWord: " calm-otter ",
      sessionID: fixture.sessionID,
      participantID: fixture.candidate.participantID,
      identity: fixture.candidate.identity,
      rendezvousProof: fixture.rendezvousProof
    )
    #expect(
      proof.verify(
        accessWord: "CALM-OTTER",
        sessionID: fixture.sessionID,
        participantID: fixture.candidate.participantID,
        identity: fixture.candidate.identity,
        rendezvousProof: fixture.rendezvousProof
      )
    )
    #expect(
      !proof.verify(
        accessWord: "CALM-OWL",
        sessionID: fixture.sessionID,
        participantID: fixture.candidate.participantID,
        identity: fixture.candidate.identity,
        rendezvousProof: fixture.rendezvousProof
      )
    )
    #expect(
      !proof.verify(
        accessWord: "CALM-OTTER",
        sessionID: fixture.sessionID,
        participantID: fixture.candidate.participantID,
        identity: fixture.candidate.identity,
        rendezvousProof: fixture.rendezvousProof(transportByte: 0x99)
      )
    )
  }

  @Test("provisional admission authenticates room provenance without committing membership")
  func provisionalAdmissionVerification() throws {
    let fixture = try BootstrapFixture()
    let hello = try fixture.signedHello()
    let admission = try fixture.signedAdmission(hello: hello)

    try admission.verify(
      expectedHello: hello,
      expectedFoundingCreatorIdentity: fixture.leaderSigner.publicKey,
      at: fixture.now
    )
    #expect(
      !admission.admission.currentMembership.snapshot.participantIDs.contains(
        fixture.candidate.participantID
      )
    )
    #expect(
      admission.admission.proposedParticipantIDs
        == [fixture.leader.participantID, fixture.candidate.participantID]
          .sorted()
    )

    let otherHello = try fixture.signedHello(
      rendezvousProof: fixture.rendezvousProof(transportByte: 0xFE)
    )
    #expect(
      throws: ClipLiveShareNativeV3BootstrapError
        .invalidProvisionalAdmission
    ) {
      try admission.verify(
        expectedHello: otherHello,
        expectedFoundingCreatorIdentity: fixture.leaderSigner.publicKey,
        at: fixture.now
      )
    }
  }

  @Test("bootstrap relay permits only its exact participant pair")
  func relayIsPairScoped() throws {
    let fixture = try BootstrapFixture()
    let hello = try fixture.signedHello()
    let admission = try fixture.signedAdmission(hello: hello)
    let link = try ClipLiveShareNativeV3PeerLinkKey(
      fixture.leader.participantID,
      fixture.candidate.participantID
    )
    let challenge = try ClipLiveShareNativeV3PossessionChallenge(
      sessionID: fixture.sessionID,
      membershipRevision: try .init(rawValue: 2),
      peerLinkKey: link,
      verifierParticipantID: fixture.leader.participantID,
      proverParticipantID: fixture.candidate.participantID,
      credentialDigest:
        admission.admission.candidateCredential.credential.digest,
      transportNonce: try .init(bytes: Data(repeating: 0x77, count: 32)),
      challenge: Data(repeating: 0x88, count: 32),
      issuedAt: fixture.issuedAt,
      expiresAt: fixture.expiresAt
    )
    let relay = try ClipLiveShareNativeV3BootstrapRelay(
      sessionID: fixture.sessionID,
      admissionDigest: admission.admission.digest,
      originParticipantID: fixture.leader.participantID,
      targetParticipantID: fixture.candidate.participantID,
      payload: .possessionChallenge(challenge)
    )
    #expect(relay.payload.peerLinkKey == link)
    #expect(
      throws: ClipLiveShareNativeV3BootstrapError.invalidRelay
    ) {
      _ = try ClipLiveShareNativeV3BootstrapRelay(
        sessionID: fixture.sessionID,
        admissionDigest: admission.admission.digest,
        originParticipantID: fixture.candidate.participantID,
        targetParticipantID: fixture.outsider.participantID,
        payload: .possessionChallenge(challenge)
      )
    }
  }

  @Test("link readiness is participant-signed and admission-scoped")
  func signedLinkReadiness() throws {
    let fixture = try BootstrapFixture()
    let admission = try fixture.signedAdmission(hello: fixture.signedHello())
    let link = try ClipLiveShareNativeV3PeerLinkKey(
      fixture.leader.participantID,
      fixture.candidate.participantID
    )
    let readiness = try ClipLiveShareNativeV3BootstrapLinkReadiness(
      sessionID: fixture.sessionID,
      admissionDigest: admission.admission.digest,
      reporterParticipantID: fixture.candidate.participantID,
      reporterIdentity: fixture.candidate.identity,
      readyPeerLinkKeys: [link]
    )
    let signed = try ClipLiveShareSignedNativeV3BootstrapLinkReadiness(
      signing: readiness,
      with: fixture.candidateSigner
    )
    try signed.verify(admission: admission)

    let forged = ClipLiveShareSignedNativeV3BootstrapLinkReadiness(
      readiness: readiness,
      signature: try fixture.outsiderSigner.signature(
        for: readiness.canonicalRepresentation
      )
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidSignature) {
      try forged.verify(admission: admission)
    }
  }

  @Test("closed bootstrap codec rejects unsupported, unknown, and smuggled messages")
  func closedCodec() throws {
    let fixture = try BootstrapFixture()
    let hello = try fixture.signedHello()
    let admission = try fixture.signedAdmission(hello: hello)
    let envelopes: [ClipLiveShareNativeV3BootstrapEnvelope] = [
      .hello(hello),
      .provisionalAdmission(admission),
      .admitted(admission.admission.currentMembership),
      .rejected(
        .init(
          sessionID: fixture.sessionID,
          rendezvousProof: fixture.rendezvousProof,
          reason: .roomFull
        )
      ),
    ]
    for envelope in envelopes {
      let data = try ClipLiveShareNativeV3BootstrapCodec.encode(envelope)
      #expect(try ClipLiveShareNativeV3BootstrapCodec.decode(data) == envelope)
    }

    let unsupported = Data(
      #"{"payload":{},"type":"hello","version":99}"#.utf8
    )
    #expect(throws: ClipLiveShareProtocolError.unsupportedVersion(99)) {
      try ClipLiveShareNativeV3BootstrapCodec.decode(unsupported)
    }
    let unknown = Data(#"{"payload":{},"type":"future","version":3}"#.utf8)
    #expect(
      throws: ClipLiveShareNativeV3BootstrapError.unknownMessageType("future")
    ) {
      try ClipLiveShareNativeV3BootstrapCodec.decode(unknown)
    }
    let smuggled = Data(
      #"{"legacy":{},"payload":{},"type":"hello","version":3}"#.utf8
    )
    #expect(throws: ClipLiveShareNativeV3BootstrapError.unexpectedFields) {
      try ClipLiveShareNativeV3BootstrapCodec.decode(smuggled)
    }
  }

  @Test("v3 rendezvous binds session, invitation, route, direction, and ordering")
  func encryptedRendezvous() throws {
    let fixture = try BootstrapFixture()
    let leaderIdentity = try ClipLiveShareNativeV3RendezvousIdentity(
      rawRepresentation: Data(repeating: 0x11, count: 32)
    )
    let candidateIdentity = try ClipLiveShareNativeV3RendezvousIdentity(
      rawRepresentation: Data(repeating: 0x22, count: 32)
    )
    let rendezvousID = try ClipLiveShareNativeV3RendezvousID(
      bytes: Data(repeating: 0x33, count: 32)
    )
    let route = try ClipLiveShareRouteID(
      bytes: Data(repeating: 0x52, count: 16)
    )
    var leader = try ClipLiveShareNativeV3EncryptedRendezvousChannel(
      leader: leaderIdentity,
      candidatePublicKey: candidateIdentity.publicKey,
      sessionID: fixture.sessionID,
      rendezvousID: rendezvousID,
      routeID: route
    )
    var candidate = try ClipLiveShareNativeV3EncryptedRendezvousChannel(
      candidate: candidateIdentity,
      leaderPublicKey: leaderIdentity.publicKey,
      sessionID: fixture.sessionID,
      rendezvousID: rendezvousID,
      routeID: route
    )
    let rejection = ClipLiveShareNativeV3BootstrapEnvelope.rejected(
      .init(
        sessionID: fixture.sessionID,
        rendezvousProof: fixture.rendezvousProof,
        reason: .denied
      )
    )
    let plaintext = try ClipLiveShareNativeV3BootstrapCodec.encode(rejection)

    let leaderRelay = try leader.seal(
      rejection,
      nonce: Data(repeating: 0x44, count: 12)
    )
    #expect(leaderRelay.ciphertext.range(of: plaintext) == nil)
    #expect(
      ClipLiveShareBase64URL.encode(leaderRelay.ciphertext)
        == "M4xn6iBrX-pwj9JgMwJxWLU5RvKeDLk5uWI5Zm5fIaalJP_5BhcyualPLuiR8FMCeCUUnOfwvK9ywd5lIHBlLzcBVDLL42nUmtqhDLlmVc0BUT5F2yZtzSaxmo-19dfMwHbauzGoR_wpudOqGosQuoLLfCbxPQW7S9nigZsA36x2LnBKHaMauM7zLpETjbVftBXrobAQzs5M3-HoyIEFnQCGdNtuGu1PFnzLM6hnJD1hZFCz7qDh8w"
    )
    #expect(try candidate.open(leaderRelay) == rejection)
    #expect(leader.lastOutboundSequence == 1)
    #expect(candidate.lastInboundSequence == 1)

    let candidateRelay = try candidate.seal(rejection)
    #expect(candidateRelay.routeID == nil)
    let forwardedCandidateRelay =
      try ClipLiveShareNativeV3RelayEnvelope(
      routeID: route,
      sequence: candidateRelay.sequence,
      nonce: candidateRelay.nonce,
      ciphertext: candidateRelay.ciphertext
    )
    #expect(try leader.open(forwardedCandidateRelay) == rejection)

    #expect(
      throws: ClipLiveShareProtocolError.invalidSequence(
        expected: 2,
        actual: 1
      )
    ) {
      try leader.open(forwardedCandidateRelay)
    }

    let otherRoute = try ClipLiveShareRouteID(
      bytes: Data(repeating: 0x53, count: 16)
    )
    var wrongRouteCandidate =
      try ClipLiveShareNativeV3EncryptedRendezvousChannel(
        candidate: candidateIdentity,
        leaderPublicKey: leaderIdentity.publicKey,
        sessionID: fixture.sessionID,
        rendezvousID: rendezvousID,
        routeID: otherRoute
      )
    #expect(
      throws: ClipLiveShareProtocolError.routeMismatch(
        expected: otherRoute,
        actual: route
      )
    ) {
      try wrongRouteCandidate.open(leaderRelay)
    }

    var tamperedCiphertext = leaderRelay.ciphertext
    tamperedCiphertext[tamperedCiphertext.startIndex] ^= 1
    let tampered = try ClipLiveShareNativeV3RelayEnvelope(
      routeID: leaderRelay.routeID,
      sequence: leaderRelay.sequence,
      nonce: leaderRelay.nonce,
      ciphertext: tamperedCiphertext
    )
    var freshCandidate = try ClipLiveShareNativeV3EncryptedRendezvousChannel(
      candidate: candidateIdentity,
      leaderPublicKey: leaderIdentity.publicKey,
      sessionID: fixture.sessionID,
      rendezvousID: rendezvousID,
      routeID: route
    )
    #expect(throws: ClipLiveShareProtocolError.authenticationFailed) {
      try freshCandidate.open(tampered)
    }
    #expect(freshCandidate.lastInboundSequence == 0)

    let otherSession = try ClipLiveShareSessionID(
      rawValue: "other-bootstrap-session"
    )
    var wrongSessionCandidate =
      try ClipLiveShareNativeV3EncryptedRendezvousChannel(
        candidate: candidateIdentity,
        leaderPublicKey: leaderIdentity.publicKey,
        sessionID: otherSession,
        rendezvousID: rendezvousID,
        routeID: route
      )
    #expect(throws: ClipLiveShareProtocolError.authenticationFailed) {
      try wrongSessionCandidate.open(leaderRelay)
    }
  }

  @Test("rendezvous plaintext and ciphertext have independent hard bounds")
  func encryptedRendezvousSizeBounds() throws {
    let leaderIdentity = try ClipLiveShareNativeV3RendezvousIdentity(
      rawRepresentation: Data(repeating: 0x31, count: 32)
    )
    let candidateIdentity = try ClipLiveShareNativeV3RendezvousIdentity(
      rawRepresentation: Data(repeating: 0x32, count: 32)
    )
    let sessionID = try ClipLiveShareSessionID(
      rawValue: "rendezvous-size-bound"
    )
    let rendezvousID = try ClipLiveShareNativeV3RendezvousID(
      bytes: Data(repeating: 0x33, count: 32)
    )
    let routeID = try ClipLiveShareRouteID(
      bytes: Data(repeating: 0x34, count: 16)
    )
    var leader = try ClipLiveShareNativeV3EncryptedRendezvousChannel(
      leader: leaderIdentity,
      candidatePublicKey: candidateIdentity.publicKey,
      sessionID: sessionID,
      rendezvousID: rendezvousID,
      routeID: routeID
    )
    var candidate = try ClipLiveShareNativeV3EncryptedRendezvousChannel(
      candidate: candidateIdentity,
      leaderPublicKey: leaderIdentity.publicKey,
      sessionID: sessionID,
      rendezvousID: rendezvousID,
      routeID: routeID
    )
    let maximumPayload = Data(
      repeating: 0xA5,
      count:
        ClipLiveShareNativeV3RendezvousCrypto.maximumPlaintextBytes
    )
    let relay = try leader.sealOpaquePayload(
      maximumPayload,
      nonce: Data(repeating: 0x35, count: 12)
    )
    #expect(
      relay.ciphertext.count
        == ClipLiveShareNativeV3RendezvousCrypto.maximumCiphertextBytes
    )
    #expect(try candidate.openOpaquePayload(relay) == maximumPayload)

    var overLimitLeader =
      try ClipLiveShareNativeV3EncryptedRendezvousChannel(
        leader: leaderIdentity,
        candidatePublicKey: candidateIdentity.publicKey,
        sessionID: sessionID,
        rendezvousID: rendezvousID,
        routeID: routeID
      )
    let overLimitPayload = Data(
      repeating: 0xA5,
      count:
        ClipLiveShareNativeV3RendezvousCrypto.maximumPlaintextBytes + 1
    )
    #expect(
      throws: ClipLiveShareProtocolError.messageTooLarge(
        maximum:
          ClipLiveShareNativeV3RendezvousCrypto.maximumPlaintextBytes,
        actual: overLimitPayload.count
      )
    ) {
      try overLimitLeader.sealOpaquePayload(
        overLimitPayload,
        nonce: Data(repeating: 0x36, count: 12)
      )
    }
    #expect(overLimitLeader.lastOutboundSequence == 0)

    #expect(throws: ClipLiveShareProtocolError.authenticationFailed) {
      _ = try ClipLiveShareNativeV3RelayEnvelope(
        routeID: routeID,
        sequence: 1,
        nonce: Data(repeating: 0x37, count: 12),
        ciphertext: Data(
          repeating: 0x38,
          count:
            ClipLiveShareNativeV3RendezvousCrypto
            .maximumCiphertextBytes + 1
        )
      )
    }
  }

  @Test("authority provenance carries ordinary membership updates for late joins")
  func authorityChainCarriesLatestMembership() throws {
    let fixture = try BootstrapFixture()
    let genesis = try fixture.membership()
    let latest = try fixture.membership(
      participants: [fixture.leader, fixture.candidate],
      revision: 2
    )
    let chain = try ClipLiveShareNativeV3RoomAuthorityChain(
      foundingCreatorParticipantID: fixture.leader.participantID,
      foundingCreatorIdentity: fixture.leader.identity,
      genesisMembership: genesis,
      checkpoints: [],
      latestMembership: latest
    )
    try chain.verify(
      expectedSessionID: fixture.sessionID,
      expectedFoundingCreatorIdentity: fixture.leader.identity,
      at: fixture.now
    )
    #expect(chain.currentMembership == latest)
    #expect(
      chain.currentMembership.snapshot.participantIDs
        == [fixture.leader.participantID, fixture.candidate.participantID]
    )
  }
}

private struct BootstrapFixture {
  let leaderSigner: ClipLiveShareSoftwareIdentitySigner
  let candidateSigner: ClipLiveShareSoftwareIdentitySigner
  let outsiderSigner: ClipLiveShareSoftwareIdentitySigner
  let sessionID = try! ClipLiveShareSessionID(rawValue: "bootstrap-session")
  let issuedAt = try! ClipLiveShareNativeTimestamp(
    millisecondsSince1970: 1_800_100_000_000
  )

  init() throws {
    leaderSigner = try .init(rawRepresentation: Data(repeating: 0x21, count: 32))
    candidateSigner = try .init(
      rawRepresentation: Data(repeating: 0x22, count: 32)
    )
    outsiderSigner = try .init(
      rawRepresentation: Data(repeating: 0x23, count: 32)
    )
  }

  var now: ClipLiveShareNativeTimestamp {
    try! issuedAt.adding(milliseconds: 1_000)
  }

  var expiresAt: ClipLiveShareNativeTimestamp {
    try! issuedAt.adding(milliseconds: 60_000)
  }

  var rendezvousProof: ClipLiveShareNativeV3RendezvousProof {
    rendezvousProof(transportByte: 0xA5)
  }

  func rendezvousProof(
    transportByte: UInt8 = 0xA5,
    routeByte: UInt8 = 0x52,
    sessionID: ClipLiveShareSessionID? = nil,
    foundingCreatorIdentity: ClipLiveShareIdentityPublicKey? = nil
  ) -> ClipLiveShareNativeV3RendezvousProof {
    .init(
      sessionID: sessionID ?? self.sessionID,
      rendezvousID: try! .init(
        bytes: Data(repeating: 0x51, count: 32)
      ),
      routeID: try! .init(
        bytes: Data(
          repeating: routeByte,
          count: 16
        )
      ),
      foundingCreatorIdentity:
        foundingCreatorIdentity ?? leaderSigner.publicKey,
      admissionCapability: try! .init(
        bytes: Data(repeating: transportByte, count: 32)
      )
    )
  }

  var leader: ClipLiveShareNativeV3Participant {
    try! participant(0x10, signer: leaderSigner, name: "Leader")
  }

  var candidate: ClipLiveShareNativeV3Participant {
    try! participant(0x20, signer: candidateSigner, name: "Candidate")
  }

  var outsider: ClipLiveShareNativeV3Participant {
    try! participant(0x30, signer: outsiderSigner, name: "Outsider")
  }

  func participant(
    _ byte: UInt8,
    signer: ClipLiveShareSoftwareIdentitySigner,
    name: String
  ) throws -> ClipLiveShareNativeV3Participant {
    try .init(
      participantID: .init(bytes: Data(repeating: byte, count: 16)),
      identity: signer.publicKey,
      displayName: name,
      capabilities: .current
    )
  }

  func credential(
    for participant: ClipLiveShareNativeV3Participant,
    revision: UInt64
  ) throws -> ClipLiveShareSignedNativeV3MembershipCredential {
    let value = try ClipLiveShareNativeV3MembershipCredential(
      sessionID: sessionID,
      leaderParticipantID: leader.participantID,
      leaderIdentity: leader.identity,
      participant: participant,
      membershipRevision: .init(rawValue: revision),
      issuedAt: issuedAt,
      expiresAt: try issuedAt.adding(milliseconds: 120_000)
    )
    return try .init(signing: value, with: leaderSigner)
  }

  func membership(
    participants: [ClipLiveShareNativeV3Participant]? = nil,
    revision: UInt64 = 1
  ) throws -> ClipLiveShareSignedNativeV3MembershipSnapshot {
    let participants = participants ?? [leader]
    let value = try ClipLiveShareNativeV3MembershipSnapshot(
      sessionID: sessionID,
      leaderParticipantID: leader.participantID,
      leaderIdentity: leader.identity,
      membershipRevision: .init(rawValue: revision),
      credentials: try participants.map {
        try credential(
          for: $0,
          revision: $0.participantID == leader.participantID ? 1 : revision
        )
      },
      issuedAt: issuedAt,
      expiresAt: try issuedAt.adding(milliseconds: 120_000)
    )
    return try .init(signing: value, with: leaderSigner)
  }

  func signedHello(
    rendezvousProof: ClipLiveShareNativeV3RendezvousProof? = nil
  ) throws -> ClipLiveShareSignedNativeV3BootstrapHello {
    let value = try ClipLiveShareNativeV3BootstrapHello(
      sessionID: sessionID,
      participantID: candidate.participantID,
      identity: candidate.identity,
      displayName: candidate.displayName,
      rendezvousProof: rendezvousProof ?? self.rendezvousProof,
      issuedAt: issuedAt,
      expiresAt: expiresAt
    )
    return try .init(signing: value, with: candidateSigner)
  }

  func signedAdmission(
    hello: ClipLiveShareSignedNativeV3BootstrapHello
  ) throws -> ClipLiveShareSignedNativeV3ProvisionalAdmission {
    let current = try membership()
    let chain = try ClipLiveShareNativeV3RoomAuthorityChain(
      foundingCreatorParticipantID: leader.participantID,
      foundingCreatorIdentity: leader.identity,
      genesisMembership: current,
      checkpoints: []
    )
    let value = try ClipLiveShareNativeV3ProvisionalAdmission(
      sessionID: sessionID,
      rendezvousProof: hello.hello.rendezvousProof,
      helloDigest: hello.hello.digest,
      candidateCredential: credential(for: candidate, revision: 2),
      currentMembership: current,
      authorityChain: chain,
      proposedParticipantIDs: [leader.participantID, candidate.participantID],
      issuedAt: issuedAt,
      expiresAt: expiresAt
    )
    return try .init(signing: value, with: leaderSigner)
  }

}
