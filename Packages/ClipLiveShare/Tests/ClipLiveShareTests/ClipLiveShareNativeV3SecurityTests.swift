import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Clip Live Share native v3 control security")
struct ClipLiveShareNativeV3SecurityTests {
  @Test("closed v3 envelope round-trips every permitted case")
  func closedEnvelopeRoundTripsEveryCase() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let challenge = try fixture.challenge(membership: membership)
    let proof = try ClipLiveShareSignedNativeV3PossessionProof(
      signing: challenge,
      with: fixture.guestSigner
    )
    let offer = try fixture.signedOffer(membership: membership)
    let answer = try fixture.signedAnswer(membership: membership)
    let ice = try fixture.signedICE(membership: membership)
    let renegotiationRequest = try fixture.signedRenegotiationRequest(
      membership: membership
    )
    let signedProposal = try fixture.signedProposal(
      membership: membership,
      reason: .recoveryElection
    )
    let guestVote = try fixture.signedVote(
      proposal: signedProposal.proposal,
      participant: fixture.guest,
      signer: fixture.guestSigner
    )
    let thirdVote = try fixture.signedVote(
      proposal: signedProposal.proposal,
      participant: fixture.third,
      signer: fixture.thirdSigner
    )
    let certificate = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: signedProposal,
      votes: [guestVote, thirdVote]
    )
    let authority = try ClipLiveShareNativeV3RoomAuthorityChain(
      foundingCreatorParticipantID: fixture.leader.participantID,
      foundingCreatorIdentity: fixture.leader.identity,
      genesisMembership: membership,
      checkpoints: []
    )
    let transferRequest = try fixture.signedTransferRequest(
      membership: membership
    )
    let leaveRequest = try fixture.signedLeaveRequest(
      membership: membership
    )
    let termination = try fixture.signedTermination(membership: membership)
    let sourceSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
      sessionID: fixture.sessionID,
      membershipRevision: fixture.membershipRevision,
      ownerParticipantID: fixture.guest.participantID,
      sourceRevision: ClipLiveShareNativeV3SourceRevision(rawValue: 1),
      sources: []
    )
    let collaboration = try fixture.pointerEvent()
    let sourceCursor = try ClipLiveShareNativeV3SourceCursor(
      sessionID: fixture.sessionID,
      participantID: fixture.leader.participantID,
      sourceKey: collaboration.context.sourceKey,
      streamID: .random(),
      sequence: 1,
      position: try .init(x: 0.25, y: 0.75)
    )
    let admissionDigest = ClipLiveShareNativeDigest(
      hashing: Data("bootstrap-admission".utf8)
    )
    let bootstrapRelay = try ClipLiveShareNativeV3BootstrapRelay(
      sessionID: fixture.sessionID,
      admissionDigest: admissionDigest,
      originParticipantID: fixture.leader.participantID,
      targetParticipantID: fixture.guest.participantID,
      payload: .possessionChallenge(challenge)
    )
    let bootstrapForward = try ClipLiveShareNativeV3BootstrapForward(
      sessionID: fixture.sessionID,
      admissionDigest: admissionDigest,
      originParticipantID: fixture.leader.participantID,
      targetParticipantID: fixture.guest.participantID,
      envelope: .relay(bootstrapRelay)
    )

    let envelopes: [ClipLiveShareNativeV3ControlEnvelope] = [
      .membershipSnapshot(membership),
      .sourceSnapshot(sourceSnapshot),
      .possessionChallenge(challenge),
      .possessionProof(proof),
      .peerLinkOffer(offer),
      .peerLinkAnswer(answer),
      .peerLinkICE(ice),
      .peerLinkRenegotiationRequest(renegotiationRequest),
      .roomAuthority(authority),
      .leadershipTransferRequest(transferRequest),
      .leadershipProposal(signedProposal),
      .leadershipVote(guestVote),
      .leadershipCertificate(certificate),
      .participantLeaveRequest(leaveRequest),
      .roomTermination(termination),
      .sourceCursor(sourceCursor),
      .collaboration(collaboration),
      .bootstrapForward(bootstrapForward),
    ]

    #expect(
      Set(envelopes.map(\.kind))
        == Set(ClipLiveShareNativeV3ControlMessageKind.allCases)
    )
    for envelope in envelopes {
      let encoded = try ClipLiveShareNativeV3ControlCodec.encode(envelope)
      #expect(
        try ClipLiveShareNativeV3ControlCodec.decode(encoded) == envelope
      )
      let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      )
      #expect(Set(object.keys) == ["version", "type", "payload"])
      #expect(object["version"] as? Int == 3)
    }
  }

  @Test("ordinary leave is participant-signed and bound to current authority")
  func participantLeaveRequestSecurity() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let request = try fixture.signedLeaveRequest(membership: membership)

    try request.verify(
      against: membership,
      expectedLeaderTerm: fixture.currentTerm,
      expectedLeaderParticipantID: fixture.leader.participantID,
      expectedLeaderIdentity: fixture.leader.identity,
      at: fixture.now
    )

    let forged = ClipLiveShareSignedNativeV3ParticipantLeaveRequest(
      request: request.request,
      signature: try fixture.thirdSigner.signature(
        for: request.request.canonicalRepresentation
      )
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidSignature) {
      try forged.verify(
        against: membership,
        expectedLeaderTerm: fixture.currentTerm,
        expectedLeaderParticipantID: fixture.leader.participantID,
        expectedLeaderIdentity: fixture.leader.identity,
        at: fixture.now
      )
    }

    let newerMembership = try fixture.membership(revision: 2)
    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      try request.verify(
        against: newerMembership,
        expectedLeaderTerm: fixture.currentTerm,
        expectedLeaderParticipantID: fixture.leader.participantID,
        expectedLeaderIdentity: fixture.leader.identity,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.expired) {
      try request.verify(
        against: membership,
        expectedLeaderTerm: fixture.currentTerm,
        expectedLeaderParticipantID: fixture.leader.participantID,
        expectedLeaderIdentity: fixture.leader.identity,
        at: request.request.expiresAt
      )
    }
  }

  @Test("closed envelope rejects old versions, unknown cases, smuggled fields, and size abuse")
  func closedEnvelopeRejectsOpenEndedInputs() throws {
    let v2 = Data(
      #"{"payload":{},"type":"offer","version":2}"#.utf8
    )
    #expect(throws: ClipLiveShareProtocolError.unsupportedVersion(2)) {
      try ClipLiveShareNativeV3ControlCodec.decode(v2)
    }

    let unknown = Data(
      #"{"payload":{},"type":"future-arbitrary-message","version":3}"#.utf8
    )
    #expect(
      throws: ClipLiveShareNativeV3Error.unknownControlMessageType(
        "future-arbitrary-message"
      )
    ) {
      try ClipLiveShareNativeV3ControlCodec.decode(unknown)
    }

    let smuggled = Data(
      #"{"legacy":{"type":"offer"},"payload":{},"type":"peer-link-offer","version":3}"#.utf8
    )
    #expect(throws: ClipLiveShareProtocolError.self) {
      try ClipLiveShareNativeV3ControlCodec.decode(smuggled)
    }
    #expect(
      throws: ClipLiveShareProtocolError.messageTooLarge(
        maximum: 4,
        actual: unknown.count
      )
    ) {
      try ClipLiveShareNativeV3ControlCodec.decode(unknown, maximumBytes: 4)
    }
  }

  @Test("possession proof binds credential, participant, pair, session, nonce, and lifetime")
  func possessionProofSecurity() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let challenge = try fixture.challenge(membership: membership)
    let proof = try ClipLiveShareSignedNativeV3PossessionProof(
      signing: challenge,
      with: fixture.guestSigner
    )
    let guestCredential = try fixture.credential(
      for: fixture.guest,
      in: membership
    )
    try proof.verify(
      expectedChallenge: challenge,
      proverCredential: guestCredential,
      at: fixture.now
    )

    let wrongNonceChallenge = try fixture.challenge(
      membership: membership,
      nonce: ClipLiveShareNativeV3TransportNonce(
        bytes: Data(repeating: 0x99, count: 32)
      )
    )
    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      try proof.verify(
        expectedChallenge: wrongNonceChallenge,
        proverCredential: guestCredential,
        at: fixture.now
      )
    }

    let thirdCredential = try fixture.credential(
      for: fixture.third,
      in: membership
    )
    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      try proof.verify(
        expectedChallenge: challenge,
        proverCredential: thirdCredential,
        at: fixture.now
      )
    }

    let wrongIdentityProof = try ClipLiveShareSignedNativeV3PossessionProof(
      signing: challenge,
      with: fixture.thirdSigner
    )
    #expect(throws: ClipLiveShareNativeV3Error.identityMismatch) {
      try wrongIdentityProof.verify(
        expectedChallenge: challenge,
        proverCredential: guestCredential,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.expired) {
      try proof.verify(
        expectedChallenge: challenge,
        proverCredential: guestCredential,
        at: challenge.expiresAt
      )
    }
  }

  @Test("signed pair offer answer and ICE reject transplant and tamper")
  func peerLinkMessagesArePairScopedAndSigned() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let offer = try fixture.signedOffer(membership: membership)
    let answer = try fixture.signedAnswer(membership: membership)
    let ice = try fixture.signedICE(membership: membership)

    try offer.verify(
      against: membership,
      expectedTransportNonce: fixture.transportNonce
    )
    try answer.verify(
      against: membership,
      expectedTransportNonce: fixture.transportNonce
    )
    try ice.verify(
      against: membership,
      expectedTransportNonce: fixture.transportNonce
    )

    let otherNonce = try ClipLiveShareNativeV3TransportNonce(
      bytes: Data(repeating: 0x55, count: 32)
    )
    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      try offer.verify(
        against: membership,
        expectedTransportNonce: otherNonce
      )
    }

    let tamperedOffer = try ClipLiveShareNativeV3PeerLinkOffer(
      context: offer.offer.context,
      sdp: "v=0\r\ntampered"
    )
    let signedTamperedOffer = ClipLiveShareSignedNativeV3PeerLinkOffer(
      offer: tamperedOffer,
      signature: offer.signature
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidSignature) {
      try signedTamperedOffer.verify(
        against: membership,
        expectedTransportNonce: fixture.transportNonce
      )
    }

    let wrongRevisionMembership = try fixture.membership(revision: 2)
    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      try offer.verify(
        against: wrongRevisionMembership,
        expectedTransportNonce: fixture.transportNonce
      )
    }

    let reversedOfferContext = try fixture.context(
      sender: fixture.guest,
      receiver: fixture.leader
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidPeerLinkContext) {
      _ = try ClipLiveShareNativeV3PeerLinkOffer(
        context: reversedOfferContext,
        sdp: "v=0"
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.invalidPeerLinkContext) {
      _ = try ClipLiveShareNativeV3PeerLinkContext(
        sessionID: fixture.sessionID,
        membershipRevision: fixture.membershipRevision,
        peerLinkKey: fixture.leaderGuestLink,
        negotiationRevision: fixture.negotiationRevision,
        senderParticipantID: fixture.leader.participantID,
        receiverParticipantID: fixture.third.participantID,
        transportNonce: fixture.transportNonce
      )
    }
  }

  @Test("renegotiation requests are upper-authored, membership-bound, and expiring")
  func peerLinkRenegotiationRequestSecurity() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let signed = try fixture.signedRenegotiationRequest(
      membership: membership
    )

    try signed.verify(
      against: membership,
      expectedTransportNonce: fixture.transportNonce,
      at: fixture.now
    )

    let tamperedRequest =
      try ClipLiveShareNativeV3PeerLinkRenegotiationRequest(
        context: signed.request.context,
        membershipDigest: signed.request.membershipDigest,
        preferredVideoCodec: "vp8",
        issuedAt: signed.request.issuedAt,
        expiresAt: signed.request.expiresAt
      )
    #expect(throws: ClipLiveShareNativeV3Error.invalidSignature) {
      try ClipLiveShareSignedNativeV3PeerLinkRenegotiationRequest(
        request: tamperedRequest,
        signature: signed.signature
      ).verify(
        against: membership,
        expectedTransportNonce: fixture.transportNonce,
        at: fixture.now
      )
    }

    let newerMembership = try fixture.membership(revision: 2)
    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      try signed.verify(
        against: newerMembership,
        expectedTransportNonce: fixture.transportNonce,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      try signed.verify(
        against: membership,
        expectedTransportNonce: .init(
          bytes: Data(repeating: 0x55, count: 32)
        ),
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.expired) {
      try signed.verify(
        against: membership,
        expectedTransportNonce: fixture.transportNonce,
        at: signed.request.expiresAt
      )
    }

    #expect(throws: ClipLiveShareNativeV3Error.invalidPeerLinkContext) {
      _ = try ClipLiveShareNativeV3PeerLinkRenegotiationRequest(
        context: fixture.context(
          sender: fixture.leader,
          receiver: fixture.guest
        ),
        membershipDigest: membership.snapshot.digest,
        preferredVideoCodec: "h264",
        issuedAt: fixture.issuedAt,
        expiresAt: fixture.issuedAt.adding(milliseconds: 30_000)
      )
    }
  }

  @Test("provisional SDP is admission-bound and cannot replay after commit")
  func provisionalPeerLinkDomainSeparation() throws {
    let fixture = try V3SecurityFixture()
    let current = try fixture.membership(
      participants: [fixture.leader, fixture.guest]
    )
    let rendezvousProof = ClipLiveShareNativeV3RendezvousProof(
      sessionID: fixture.sessionID,
      rendezvousID: try .init(
        bytes: Data(repeating: 0x70, count: 32)
      ),
      routeID: try .init(
        bytes: Data(repeating: 0x71, count: 16)
      ),
      foundingCreatorIdentity: fixture.leader.identity,
      admissionCapability: try .init(
        bytes: Data(repeating: 0xA7, count: 32)
      )
    )
    let hello = try ClipLiveShareNativeV3BootstrapHello(
      sessionID: fixture.sessionID,
      participantID: fixture.third.participantID,
      identity: fixture.third.identity,
      displayName: fixture.third.displayName,
      rendezvousProof: rendezvousProof,
      issuedAt: fixture.issuedAt,
      expiresAt: fixture.issuedAt.adding(milliseconds: 60_000)
    )
    let signedHello = try ClipLiveShareSignedNativeV3BootstrapHello(
      signing: hello,
      with: fixture.thirdSigner
    )
    let candidateCredential =
      try ClipLiveShareSignedNativeV3MembershipCredential(
        signing: .init(
          sessionID: fixture.sessionID,
          leaderParticipantID: fixture.leader.participantID,
          leaderIdentity: fixture.leader.identity,
          participant: fixture.third,
          membershipRevision: .init(rawValue: 2),
          issuedAt: fixture.issuedAt,
          expiresAt: fixture.issuedAt.adding(milliseconds: 120_000)
        ),
        with: fixture.leaderSigner
      )
    let chain = try ClipLiveShareNativeV3RoomAuthorityChain(
      foundingCreatorParticipantID: fixture.leader.participantID,
      foundingCreatorIdentity: fixture.leader.identity,
      genesisMembership: current,
      checkpoints: []
    )
    let admission = try ClipLiveShareSignedNativeV3ProvisionalAdmission(
      signing: .init(
        sessionID: fixture.sessionID,
        rendezvousProof: rendezvousProof,
        helloDigest: signedHello.hello.digest,
        candidateCredential: candidateCredential,
        currentMembership: current,
        authorityChain: chain,
        proposedParticipantIDs: [
          fixture.leader.participantID,
          fixture.guest.participantID,
          fixture.third.participantID,
        ],
        issuedAt: fixture.issuedAt,
        expiresAt: fixture.issuedAt.adding(milliseconds: 60_000)
      ),
      with: fixture.leaderSigner
    )
    let context = try ClipLiveShareNativeV3PeerLinkContext(
      sessionID: fixture.sessionID,
      membershipRevision: .init(rawValue: 2),
      peerLinkKey: .init(
        fixture.leader.participantID,
        fixture.third.participantID
      ),
      negotiationRevision: .init(rawValue: 1),
      senderParticipantID: fixture.leader.participantID,
      receiverParticipantID: fixture.third.participantID,
      transportNonce: fixture.transportNonce,
      provisionalAdmissionDigest: admission.admission.digest
    )
    let signed = try ClipLiveShareSignedNativeV3PeerLinkOffer(
      signing: .init(context: context, sdp: "v=0\r\nprovisional"),
      with: fixture.leaderSigner,
      senderIdentity: fixture.leader.identity
    )

    try signed.verify(
      againstProvisionalAdmission: admission,
      expectedTransportNonce: fixture.transportNonce
    )
    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      try signed.verify(
        against: current,
        expectedTransportNonce: fixture.transportNonce
      )
    }

    let unboundContext = try ClipLiveShareNativeV3PeerLinkContext(
      sessionID: context.sessionID,
      membershipRevision: context.membershipRevision,
      peerLinkKey: context.peerLinkKey,
      negotiationRevision: context.negotiationRevision,
      senderParticipantID: context.senderParticipantID,
      receiverParticipantID: context.receiverParticipantID,
      transportNonce: context.transportNonce
    )
    let unbound = try ClipLiveShareSignedNativeV3PeerLinkOffer(
      signing: .init(context: unboundContext, sdp: "v=0\r\nunbound"),
      with: fixture.leaderSigner,
      senderIdentity: fixture.leader.identity
    )
    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      try unbound.verify(
        againstProvisionalAdmission: admission,
        expectedTransportNonce: fixture.transportNonce
      )
    }
  }

  @Test("three-member recovery elects a successor without the lost creator")
  func recoveryElectionUsesSurvivingMajority() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let signedProposal = try fixture.signedProposal(
      membership: membership,
      reason: .recoveryElection
    )
    let certificate = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: signedProposal,
      votes: [
        try fixture.signedVote(
          proposal: signedProposal.proposal,
          participant: fixture.guest,
          signer: fixture.guestSigner
        ),
        try fixture.signedVote(
          proposal: signedProposal.proposal,
          participant: fixture.third,
          signer: fixture.thirdSigner
        ),
      ]
    )

    try certificate.verify(
      lastCommittedMembership: membership,
      currentTerm: fixture.currentTerm,
      currentLeaderParticipantID: fixture.leader.participantID,
      currentLeaderIdentity: fixture.leader.identity,
      at: fixture.now
    )
    #expect(certificate.newLeaderParticipantID == fixture.guest.participantID)
    #expect(
      ClipLiveShareNativeV3LeadershipCertificate.requiredQuorum(
        participantCount: 3
      ) == 2
    )
  }

  @Test("two-member recovery fails closed without the lost creator")
  func twoMemberRecoveryCannotManufactureQuorum() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership(
      participants: [fixture.leader, fixture.guest]
    )
    let signedProposal = try fixture.signedProposal(
      membership: membership,
      reason: .recoveryElection
    )
    let candidateVote = try fixture.signedVote(
      proposal: signedProposal.proposal,
      participant: fixture.guest,
      signer: fixture.guestSigner
    )
    let certificate = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: signedProposal,
      votes: [candidateVote]
    )
    #expect(
      throws: ClipLiveShareNativeV3Error.insufficientLeadershipQuorum(
        required: 2,
        actual: 1
      )
    ) {
      try certificate.verify(
        lastCommittedMembership: membership,
        currentTerm: fixture.currentTerm,
        currentLeaderParticipantID: fixture.leader.participantID,
        currentLeaderIdentity: fixture.leader.identity,
        at: fixture.now
      )
    }
  }

  @Test("graceful transfer requires the departing leader vote")
  func gracefulTransferRequiresLeaderAuthorization() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let signedProposal = try fixture.signedProposal(
      membership: membership,
      reason: .gracefulTransfer
    )
    let transferRequest = try fixture.signedTransferRequest(
      membership: membership
    )
    let withoutLeader = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: signedProposal,
      votes: [
        try fixture.signedVote(
          proposal: signedProposal.proposal,
          participant: fixture.guest,
          signer: fixture.guestSigner
        ),
        try fixture.signedVote(
          proposal: signedProposal.proposal,
          participant: fixture.third,
          signer: fixture.thirdSigner
        ),
      ]
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidLeadershipCertificate) {
      try withoutLeader.verify(
        lastCommittedMembership: membership,
        currentTerm: fixture.currentTerm,
        currentLeaderParticipantID: fixture.leader.participantID,
        currentLeaderIdentity: fixture.leader.identity,
        at: fixture.now
      )
    }

    let withLeader = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: signedProposal,
      signedTransferRequest: transferRequest,
      votes: [
        try fixture.signedVote(
          proposal: signedProposal.proposal,
          participant: fixture.guest,
          signer: fixture.guestSigner
        ),
        try fixture.signedVote(
          proposal: signedProposal.proposal,
          participant: fixture.leader,
          signer: fixture.leaderSigner
        ),
      ]
    )
    try withLeader.verify(
      lastCommittedMembership: membership,
      currentTerm: fixture.currentTerm,
      currentLeaderParticipantID: fixture.leader.participantID,
      currentLeaderIdentity: fixture.leader.identity,
      at: fixture.now
    )
  }

  @Test("graceful transfer request is leader-signed and bound to the exact successor")
  func gracefulTransferRequestSecurity() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let request = try fixture.signedTransferRequest(membership: membership)
    try request.verify(
      lastCommittedMembership: membership,
      currentTerm: fixture.currentTerm,
      currentLeaderParticipantID: fixture.leader.participantID,
      currentLeaderIdentity: fixture.leader.identity,
      at: fixture.now
    )

    let forged = ClipLiveShareSignedNativeV3LeadershipTransferRequest(
      request: request.request,
      signature: try fixture.guestSigner.signature(
        for: request.request.canonicalRepresentation
      )
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidSignature) {
      try forged.verify(
        lastCommittedMembership: membership,
        currentTerm: fixture.currentTerm,
        currentLeaderParticipantID: fixture.leader.participantID,
        currentLeaderIdentity: fixture.leader.identity,
        at: fixture.now
      )
    }

    #expect(throws: ClipLiveShareNativeV3Error.invalidLeadershipCertificate) {
      _ = try ClipLiveShareNativeV3LeadershipTransferRequest(
        sessionID: fixture.sessionID,
        currentTerm: fixture.currentTerm,
        nextTerm: ClipLiveShareNativeV3LeadershipTerm(rawValue: 3),
        currentLeaderParticipantID: fixture.leader.participantID,
        currentLeaderIdentity: fixture.leader.identity,
        successorParticipantID: fixture.guest.participantID,
        lastCommittedMembershipRevision:
          membership.snapshot.membershipRevision,
        lastCommittedMembershipDigest: membership.snapshot.digest,
        issuedAt: fixture.issuedAt,
        expiresAt: fixture.issuedAt.adding(milliseconds: 60_000)
      )
    }
  }

  @Test("leader-signed room termination cannot be forged or replayed")
  func roomTerminationSecurity() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let signed = try fixture.signedTermination(membership: membership)
    try signed.verify(
      against: membership,
      expectedLeaderTerm: fixture.currentTerm,
      expectedLeaderParticipantID: fixture.leader.participantID,
      expectedLeaderIdentity: fixture.leader.identity,
      at: fixture.now
    )

    let forged = ClipLiveShareSignedNativeV3RoomTermination(
      termination: signed.termination,
      signature: try fixture.guestSigner.signature(
        for: signed.termination.canonicalRepresentation
      )
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidSignature) {
      try forged.verify(
        against: membership,
        expectedLeaderTerm: fixture.currentTerm,
        expectedLeaderParticipantID: fixture.leader.participantID,
        expectedLeaderIdentity: fixture.leader.identity,
        at: fixture.now
      )
    }

    var ledger = ClipLiveShareNativeV3RoomTerminationLedger()
    try ledger.accept(signed.termination.terminationRevision)
    #expect(
      throws: ClipLiveShareNativeV3Error.staleRoomTerminationRevision(
        expectedGreaterThan: 1,
        actual: 1
      )
    ) {
      try ledger.accept(signed.termination.terminationRevision)
    }
  }

  @Test("late join authenticates successor through the creator-rooted authority chain")
  func creatorRootedAuthorityChain() throws {
    let fixture = try V3SecurityFixture()
    let genesis = try fixture.membership()
    let proposal = try fixture.signedProposal(
      membership: genesis,
      reason: .recoveryElection
    )
    let certificate = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: proposal,
      votes: [
        try fixture.signedVote(
          proposal: proposal.proposal,
          participant: fixture.guest,
          signer: fixture.guestSigner
        ),
        try fixture.signedVote(
          proposal: proposal.proposal,
          participant: fixture.third,
          signer: fixture.thirdSigner
        ),
      ]
    )
    let successor = try fixture.membership(
      participants: [fixture.guest, fixture.third],
      leader: fixture.guest,
      leaderSigner: fixture.guestSigner,
      revision: 2
    )
    let chain = try ClipLiveShareNativeV3RoomAuthorityChain(
      foundingCreatorParticipantID: fixture.leader.participantID,
      foundingCreatorIdentity: fixture.leader.identity,
      genesisMembership: genesis,
      checkpoints: [
        ClipLiveShareNativeV3AuthorityCheckpoint(
          certificate: certificate,
          successorMembership: successor
        )
      ]
    )
    try chain.verify(
      expectedSessionID: fixture.sessionID,
      expectedFoundingCreatorIdentity: fixture.leader.identity,
      at: fixture.now
    )
    #expect(chain.currentTerm.rawValue == 2)
    #expect(chain.currentLeaderParticipantID == fixture.guest.participantID)

    #expect(throws: ClipLiveShareNativeV3Error.invalidAuthorityChain) {
      try chain.verify(
        expectedSessionID: fixture.sessionID,
        expectedFoundingCreatorIdentity: fixture.outsiderSigner.publicKey,
        at: fixture.now
      )
    }
  }

  @Test("leadership certificates reject stale terms membership tamper and duplicate votes")
  func leadershipTamperMatrix() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let signedProposal = try fixture.signedProposal(
      membership: membership,
      reason: .recoveryElection
    )
    let guestVote = try fixture.signedVote(
      proposal: signedProposal.proposal,
      participant: fixture.guest,
      signer: fixture.guestSigner
    )
    let thirdVote = try fixture.signedVote(
      proposal: signedProposal.proposal,
      participant: fixture.third,
      signer: fixture.thirdSigner
    )
    let certificate = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: signedProposal,
      votes: [guestVote, thirdVote]
    )

    #expect(
      throws: ClipLiveShareNativeV3Error.staleLeadershipTerm(
        expectedGreaterThan: 2,
        actual: 2
      )
    ) {
      try certificate.verify(
        lastCommittedMembership: membership,
        currentTerm: ClipLiveShareNativeV3LeadershipTerm(rawValue: 2),
        currentLeaderParticipantID: fixture.leader.participantID,
        currentLeaderIdentity: fixture.leader.identity,
        at: fixture.now
      )
    }
    let skippedTermProposal = try fixture.proposal(
      membership: membership,
      candidate: fixture.guest,
      term: 3,
      reason: .recoveryElection
    )
    let skippedTermSigned = try ClipLiveShareSignedNativeV3LeadershipProposal(
      signing: skippedTermProposal,
      with: fixture.guestSigner
    )
    let skippedTermCertificate = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: skippedTermSigned,
      votes: [
        try fixture.signedVote(
          proposal: skippedTermProposal,
          participant: fixture.guest,
          signer: fixture.guestSigner
        ),
        try fixture.signedVote(
          proposal: skippedTermProposal,
          participant: fixture.third,
          signer: fixture.thirdSigner
        ),
      ]
    )
    #expect(
      throws: ClipLiveShareNativeV3Error.staleLeadershipTerm(
        expectedGreaterThan: 1,
        actual: 3
      )
    ) {
      try skippedTermCertificate.verify(
        lastCommittedMembership: membership,
        currentTerm: fixture.currentTerm,
        currentLeaderParticipantID: fixture.leader.participantID,
        currentLeaderIdentity: fixture.leader.identity,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.duplicateLeadershipVote) {
      _ = try ClipLiveShareNativeV3LeadershipCertificate(
        signedProposal: signedProposal,
        votes: [guestVote, guestVote]
      )
    }

    let changedMembership = try fixture.membership(
      participants: [fixture.leader, fixture.guest],
      revision: 2
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidLeadershipCertificate) {
      try certificate.verify(
        lastCommittedMembership: changedMembership,
        currentTerm: fixture.currentTerm,
        currentLeaderParticipantID: fixture.leader.participantID,
        currentLeaderIdentity: fixture.leader.identity,
        at: fixture.now
      )
    }

    let tamperedVoteValue = try ClipLiveShareNativeV3LeadershipVote(
      proposal: signedProposal.proposal,
      voterParticipantID: fixture.third.participantID,
      voterIdentity: fixture.third.identity
    )
    let forgedThirdVote = ClipLiveShareSignedNativeV3LeadershipVote(
      vote: tamperedVoteValue,
      signature: guestVote.signature
    )
    let forgedCertificate = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: signedProposal,
      votes: [guestVote, forgedThirdVote]
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidSignature) {
      try forgedCertificate.verify(
        lastCommittedMembership: membership,
        currentTerm: fixture.currentTerm,
        currentLeaderParticipantID: fixture.leader.participantID,
        currentLeaderIdentity: fixture.leader.identity,
        at: fixture.now
      )
    }
  }

  @Test("vote ledger prevents equivocation and accepts idempotent repeats")
  func leadershipVoteLedger() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let first = try fixture.signedProposal(
      membership: membership,
      reason: .recoveryElection
    ).proposal
    var ledger = ClipLiveShareNativeV3LeadershipVoteLedger(
      committedTerm: fixture.currentTerm
    )
    try ledger.recordVote(for: first)
    try ledger.recordVote(for: first)

    let competing = try fixture.proposal(
      membership: membership,
      candidate: fixture.third,
      term: 2,
      reason: .recoveryElection
    )
    #expect(throws: ClipLiveShareNativeV3Error.conflictingLeadershipVote) {
      try ledger.recordVote(for: competing)
    }

    let signedFirst = try ClipLiveShareSignedNativeV3LeadershipProposal(
      signing: first,
      with: fixture.guestSigner
    )
    let certificate = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: signedFirst,
      votes: [
        try fixture.signedVote(
          proposal: first,
          participant: fixture.guest,
          signer: fixture.guestSigner
        ),
        try fixture.signedVote(
          proposal: first,
          participant: fixture.third,
          signer: fixture.thirdSigner
        ),
      ]
    )
    try ledger.commit(certificate)
    #expect(ledger.committedTerm.rawValue == 2)
    #expect(ledger.votedProposalDigests.isEmpty)
  }

  @Test("successor snapshot is signed by elected leader and cannot add or rebind members")
  func successorMembershipBridge() throws {
    let fixture = try V3SecurityFixture()
    let previous = try fixture.membership()
    let signedProposal = try fixture.signedProposal(
      membership: previous,
      reason: .recoveryElection
    )
    let certificate = try ClipLiveShareNativeV3LeadershipCertificate(
      signedProposal: signedProposal,
      votes: [
        try fixture.signedVote(
          proposal: signedProposal.proposal,
          participant: fixture.guest,
          signer: fixture.guestSigner
        ),
        try fixture.signedVote(
          proposal: signedProposal.proposal,
          participant: fixture.third,
          signer: fixture.thirdSigner
        ),
      ]
    )
    let successor = try fixture.membership(
      participants: [fixture.guest, fixture.third],
      leader: fixture.guest,
      leaderSigner: fixture.guestSigner,
      revision: 2
    )
    try certificate.verifySuccessorMembership(
      successor,
      after: previous,
      currentTerm: fixture.currentTerm,
      currentLeaderParticipantID: fixture.leader.participantID,
      currentLeaderIdentity: fixture.leader.identity,
      at: fixture.now
    )

    let outsider = try fixture.participant(
      idByte: 0x40,
      signer: fixture.outsiderSigner,
      name: "Outsider"
    )
    let addingOutsider = try fixture.membership(
      participants: [fixture.guest, fixture.third, outsider],
      leader: fixture.guest,
      leaderSigner: fixture.guestSigner,
      revision: 2
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidLeadershipCertificate) {
      try certificate.verifySuccessorMembership(
        addingOutsider,
        after: previous,
        currentTerm: fixture.currentTerm,
        currentLeaderParticipantID: fixture.leader.participantID,
        currentLeaderIdentity: fixture.leader.identity,
        at: fixture.now
      )
    }
  }

  @Test("canonical security statements retain fixed golden vectors")
  func fixedCanonicalGoldenVectors() throws {
    let fixture = try V3SecurityFixture()
    let membership = try fixture.membership()
    let challenge = try fixture.challenge(membership: membership)
    let offer = try fixture.offer()
    let proposal = try fixture.proposal(
      membership: membership,
      candidate: fixture.guest,
      term: 2,
      reason: .recoveryElection
    )
    let envelope = ClipLiveShareNativeV3ControlEnvelope.possessionChallenge(
      challenge
    )

    let challengeDigest = ClipLiveShareNativeDigest(
      hashing: challenge.canonicalRepresentation
    ).rawValue
    let offerDigest = ClipLiveShareNativeDigest(
      hashing: offer.canonicalRepresentation
    ).rawValue
    let proposalDigest = proposal.digest.rawValue
    let envelopeJSON = try #require(
      String(
        data: ClipLiveShareNativeV3ControlCodec.encode(envelope),
        encoding: .utf8
      )
    )

    #expect(challengeDigest == "YgaMOvUxAzxN982NbnJ4UhtmEgWvRgIeDod5rAnsOcw")
    #expect(offerDigest == "H1YfS2iMewkqMnmnFo93niXesD62TcUDuCWAPfoAzt4")
    #expect(proposalDigest == "WtIt4BIV724TrIDXLQX3gJbD4E6Zabnm_3vm0L4IV5w")
    #expect(
      envelopeJSON
        == #"{"payload":{"challenge":"ZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmY","credentialDigest":"WsEW1iTkd3jSb1UxU9BCMzwgsVrdUYiwR6wv8UEtiHw","expiresAt":1800000060000,"issuedAt":1800000000000,"membershipRevision":1,"peerLinkKey":{"lowerParticipantId":"EBAQEBAQEBAQEBAQEBAQEA","upperParticipantId":"ICAgICAgICAgICAgICAgIA"},"proverParticipantId":"ICAgICAgICAgICAgICAgIA","sessionId":"v3-security-session","transportNonce":"REREREREREREREREREREREREREREREREREREREREREQ","verifierParticipantId":"EBAQEBAQEBAQEBAQEBAQEA"},"type":"possession-challenge","version":3}"#
    )
  }
}

private struct V3SecurityFixture {
  let leaderSigner: ClipLiveShareSoftwareIdentitySigner
  let guestSigner: ClipLiveShareSoftwareIdentitySigner
  let thirdSigner: ClipLiveShareSoftwareIdentitySigner
  let outsiderSigner: ClipLiveShareSoftwareIdentitySigner

  let sessionID = try! ClipLiveShareSessionID(rawValue: "v3-security-session")
  let issuedAt = try! ClipLiveShareNativeTimestamp(
    millisecondsSince1970: 1_800_000_000_000
  )
  let membershipRevision = try! ClipLiveShareNativeV3MembershipRevision(
    rawValue: 1
  )
  let negotiationRevision = try! ClipLiveShareNativeV3PeerLinkRevision(
    rawValue: 7
  )
  let currentTerm = try! ClipLiveShareNativeV3LeadershipTerm(rawValue: 1)
  let transportNonce = try! ClipLiveShareNativeV3TransportNonce(
    bytes: Data(repeating: 0x44, count: 32)
  )

  init() throws {
    leaderSigner = try ClipLiveShareSoftwareIdentitySigner(
      rawRepresentation: Data(repeating: 1, count: 32)
    )
    guestSigner = try ClipLiveShareSoftwareIdentitySigner(
      rawRepresentation: Data(repeating: 2, count: 32)
    )
    thirdSigner = try ClipLiveShareSoftwareIdentitySigner(
      rawRepresentation: Data(repeating: 3, count: 32)
    )
    outsiderSigner = try ClipLiveShareSoftwareIdentitySigner(
      rawRepresentation: Data(repeating: 4, count: 32)
    )
  }

  var now: ClipLiveShareNativeTimestamp {
    try! issuedAt.adding(milliseconds: 5_000)
  }

  var leader: ClipLiveShareNativeV3Participant {
    try! participant(idByte: 0x10, signer: leaderSigner, name: "Leader")
  }

  var guest: ClipLiveShareNativeV3Participant {
    try! participant(idByte: 0x20, signer: guestSigner, name: "Guest")
  }

  var third: ClipLiveShareNativeV3Participant {
    try! participant(idByte: 0x30, signer: thirdSigner, name: "Third")
  }

  var leaderGuestLink: ClipLiveShareNativeV3PeerLinkKey {
    try! ClipLiveShareNativeV3PeerLinkKey(
      leader.participantID,
      guest.participantID
    )
  }

  func participant(
    idByte: UInt8,
    signer: ClipLiveShareSoftwareIdentitySigner,
    name: String
  ) throws -> ClipLiveShareNativeV3Participant {
    try ClipLiveShareNativeV3Participant(
      participantID: ClipLiveShareNativeV3ParticipantID(
        bytes: Data(repeating: idByte, count: 16)
      ),
      identity: signer.publicKey,
      displayName: name,
      capabilities: .current
    )
  }

  func membership(
    participants: [ClipLiveShareNativeV3Participant]? = nil,
    leader selectedLeader: ClipLiveShareNativeV3Participant? = nil,
    leaderSigner selectedSigner: ClipLiveShareSoftwareIdentitySigner? = nil,
    revision: UInt64 = 1
  ) throws -> ClipLiveShareSignedNativeV3MembershipSnapshot {
    let selectedLeader = selectedLeader ?? leader
    let selectedSigner = selectedSigner ?? leaderSigner
    let participants = participants ?? [leader, guest, third]
    let revisionValue = try ClipLiveShareNativeV3MembershipRevision(
      rawValue: revision
    )
    let credentials = try participants.map { participant in
      let credential = try ClipLiveShareNativeV3MembershipCredential(
        sessionID: sessionID,
        leaderParticipantID: selectedLeader.participantID,
        leaderIdentity: selectedLeader.identity,
        participant: participant,
        membershipRevision: revisionValue,
        issuedAt: issuedAt,
        expiresAt: issuedAt.adding(milliseconds: 180_000)
      )
      return try ClipLiveShareSignedNativeV3MembershipCredential(
        signing: credential,
        with: selectedSigner
      )
    }
    let snapshot = try ClipLiveShareNativeV3MembershipSnapshot(
      sessionID: sessionID,
      leaderParticipantID: selectedLeader.participantID,
      leaderIdentity: selectedLeader.identity,
      membershipRevision: revisionValue,
      credentials: credentials,
      issuedAt: issuedAt,
      expiresAt: issuedAt.adding(milliseconds: 120_000)
    )
    return try ClipLiveShareSignedNativeV3MembershipSnapshot(
      signing: snapshot,
      with: selectedSigner
    )
  }

  func credential(
    for participant: ClipLiveShareNativeV3Participant,
    in membership: ClipLiveShareSignedNativeV3MembershipSnapshot
  ) throws -> ClipLiveShareSignedNativeV3MembershipCredential {
    try #require(
      membership.snapshot.credentials.first {
        $0.credential.participant.participantID == participant.participantID
      }
    )
  }

  func context(
    sender: ClipLiveShareNativeV3Participant,
    receiver: ClipLiveShareNativeV3Participant
  ) throws -> ClipLiveShareNativeV3PeerLinkContext {
    try ClipLiveShareNativeV3PeerLinkContext(
      sessionID: sessionID,
      membershipRevision: membershipRevision,
      peerLinkKey: ClipLiveShareNativeV3PeerLinkKey(
        sender.participantID,
        receiver.participantID
      ),
      negotiationRevision: negotiationRevision,
      senderParticipantID: sender.participantID,
      receiverParticipantID: receiver.participantID,
      transportNonce: transportNonce
    )
  }

  func offer() throws -> ClipLiveShareNativeV3PeerLinkOffer {
    try ClipLiveShareNativeV3PeerLinkOffer(
      context: context(sender: leader, receiver: guest),
      sdp: "v=0\r\no=clip 7 7 IN IP4 127.0.0.1"
    )
  }

  func signedOffer(
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot
  ) throws -> ClipLiveShareSignedNativeV3PeerLinkOffer {
    _ = membership
    return try ClipLiveShareSignedNativeV3PeerLinkOffer(
      signing: offer(),
      with: leaderSigner,
      senderIdentity: leader.identity
    )
  }

  func signedAnswer(
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot
  ) throws -> ClipLiveShareSignedNativeV3PeerLinkAnswer {
    _ = membership
    let answer = try ClipLiveShareNativeV3PeerLinkAnswer(
      context: context(sender: guest, receiver: leader),
      sdp: "v=0\r\no=clip 7 8 IN IP4 127.0.0.1"
    )
    return try ClipLiveShareSignedNativeV3PeerLinkAnswer(
      signing: answer,
      with: guestSigner,
      senderIdentity: guest.identity
    )
  }

  func signedICE(
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot
  ) throws -> ClipLiveShareSignedNativeV3PeerLinkICECandidate {
    _ = membership
    let ice = try ClipLiveShareNativeV3PeerLinkICECandidate(
      context: context(sender: leader, receiver: guest),
      candidateSequence: 1,
      candidate: "candidate:1 1 UDP 2122260223 192.0.2.1 5000 typ host",
      sdpMid: "0",
      sdpMLineIndex: 0
    )
    return try ClipLiveShareSignedNativeV3PeerLinkICECandidate(
      signing: ice,
      with: leaderSigner,
      senderIdentity: leader.identity
    )
  }

  func signedRenegotiationRequest(
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot
  ) throws -> ClipLiveShareSignedNativeV3PeerLinkRenegotiationRequest {
    let request = try ClipLiveShareNativeV3PeerLinkRenegotiationRequest(
      context: context(sender: guest, receiver: leader),
      membershipDigest: membership.snapshot.digest,
      preferredVideoCodec: "h264",
      issuedAt: issuedAt,
      expiresAt: issuedAt.adding(
        milliseconds:
          ClipLiveShareNativeV3
          .maximumPeerLinkRenegotiationRequestLifetimeMilliseconds
      )
    )
    return try ClipLiveShareSignedNativeV3PeerLinkRenegotiationRequest(
      signing: request,
      with: guestSigner,
      membership: membership
    )
  }

  func challenge(
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    nonce: ClipLiveShareNativeV3TransportNonce? = nil
  ) throws -> ClipLiveShareNativeV3PossessionChallenge {
    try ClipLiveShareNativeV3PossessionChallenge(
      sessionID: sessionID,
      membershipRevision: membership.snapshot.membershipRevision,
      peerLinkKey: leaderGuestLink,
      verifierParticipantID: leader.participantID,
      proverParticipantID: guest.participantID,
      credentialDigest: credential(for: guest, in: membership).credential.digest,
      transportNonce: nonce ?? transportNonce,
      challenge: Data(repeating: 0x66, count: 32),
      issuedAt: issuedAt,
      expiresAt: issuedAt.adding(milliseconds: 60_000)
    )
  }

  func proposal(
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    candidate: ClipLiveShareNativeV3Participant,
    term: UInt64,
    reason: ClipLiveShareNativeV3LeadershipTransitionReason,
    transferRequestDigest: ClipLiveShareNativeDigest? = nil
  ) throws -> ClipLiveShareNativeV3LeadershipProposal {
    try ClipLiveShareNativeV3LeadershipProposal(
      sessionID: sessionID,
      term: ClipLiveShareNativeV3LeadershipTerm(rawValue: term),
      reason: reason,
      previousLeaderParticipantID: leader.participantID,
      candidateParticipantID: candidate.participantID,
      candidateIdentity: candidate.identity,
      lastCommittedMembershipRevision:
        membership.snapshot.membershipRevision,
      lastCommittedMembershipDigest: membership.snapshot.digest,
      transferRequestDigest: transferRequestDigest,
      electorate: membership.snapshot.participantIDs,
      issuedAt: issuedAt,
      expiresAt: issuedAt.adding(milliseconds: 60_000)
    )
  }

  func signedProposal(
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    reason: ClipLiveShareNativeV3LeadershipTransitionReason
  ) throws -> ClipLiveShareSignedNativeV3LeadershipProposal {
    let transferRequestDigest: ClipLiveShareNativeDigest?
    if reason == .gracefulTransfer {
      transferRequestDigest = try signedTransferRequest(
        membership: membership
      ).request.digest
    } else {
      transferRequestDigest = nil
    }
    return try ClipLiveShareSignedNativeV3LeadershipProposal(
      signing: proposal(
        membership: membership,
        candidate: guest,
        term: 2,
        reason: reason,
        transferRequestDigest: transferRequestDigest
      ),
      with: guestSigner
    )
  }

  func signedTransferRequest(
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot
  ) throws -> ClipLiveShareSignedNativeV3LeadershipTransferRequest {
    let request = try ClipLiveShareNativeV3LeadershipTransferRequest(
      sessionID: sessionID,
      currentTerm: currentTerm,
      nextTerm: ClipLiveShareNativeV3LeadershipTerm(rawValue: 2),
      currentLeaderParticipantID: leader.participantID,
      currentLeaderIdentity: leader.identity,
      successorParticipantID: guest.participantID,
      lastCommittedMembershipRevision:
        membership.snapshot.membershipRevision,
      lastCommittedMembershipDigest: membership.snapshot.digest,
      issuedAt: issuedAt,
      expiresAt: issuedAt.adding(milliseconds: 60_000)
    )
    return try ClipLiveShareSignedNativeV3LeadershipTransferRequest(
      signing: request,
      with: leaderSigner
    )
  }

  func signedTermination(
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot
  ) throws -> ClipLiveShareSignedNativeV3RoomTermination {
    let termination = ClipLiveShareNativeV3RoomTermination(
      sessionID: sessionID,
      leaderTerm: currentTerm,
      leaderParticipantID: leader.participantID,
      leaderIdentity: leader.identity,
      membershipRevision: membership.snapshot.membershipRevision,
      membershipDigest: membership.snapshot.digest,
      terminationRevision:
        try ClipLiveShareNativeV3RoomTerminationRevision(rawValue: 1),
      issuedAt: issuedAt,
      reason: .endedByLeader
    )
    return try ClipLiveShareSignedNativeV3RoomTermination(
      signing: termination,
      with: leaderSigner
    )
  }

  func signedLeaveRequest(
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot
  ) throws -> ClipLiveShareSignedNativeV3ParticipantLeaveRequest {
    let request = try ClipLiveShareNativeV3ParticipantLeaveRequest(
      sessionID: sessionID,
      leaderTerm: currentTerm,
      leaderParticipantID: leader.participantID,
      membershipRevision: membership.snapshot.membershipRevision,
      membershipDigest: membership.snapshot.digest,
      participantID: guest.participantID,
      participantIdentity: guest.identity,
      issuedAt: issuedAt,
      expiresAt: issuedAt.adding(milliseconds: 60_000)
    )
    return try ClipLiveShareSignedNativeV3ParticipantLeaveRequest(
      signing: request,
      with: guestSigner
    )
  }

  func signedVote(
    proposal: ClipLiveShareNativeV3LeadershipProposal,
    participant: ClipLiveShareNativeV3Participant,
    signer: ClipLiveShareSoftwareIdentitySigner
  ) throws -> ClipLiveShareSignedNativeV3LeadershipVote {
    try ClipLiveShareSignedNativeV3LeadershipVote(
      signing: ClipLiveShareNativeV3LeadershipVote(
        proposal: proposal,
        voterParticipantID: participant.participantID,
        voterIdentity: participant.identity
      ),
      with: signer
    )
  }

  func pointerEvent() throws -> ClipLiveShareNativeV3CollaborationEvent {
    let sourceID = try ClipLiveShareSourceInstanceID(
      bytes: Data(repeating: 0x77, count: 16)
    )
    return .pointer(
      ClipLiveShareNativeV3PointerEvent(
        context: try ClipLiveShareNativeV3CollaborationContext(
          sessionID: sessionID,
          participantID: guest.participantID,
          sourceKey: ClipLiveShareNativeV3SourceKey(
            ownerParticipantID: leader.participantID,
            sourceInstanceID: sourceID
          ),
          sequence: 1,
          sentAt: issuedAt
        ),
        position: try ClipLiveShareNativeV3NormalizedPoint(x: 0.25, y: 0.75)
      )
    )
  }
}
