import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Clip Live Share native v3 mesh foundation")
struct ClipLiveShareNativeV3FoundationTests {
  @Test("v3 constants preserve protocol headroom above initial product policy")
  func protocolAndProductBounds() {
    #expect(ClipLiveShareNativeV3.version == 3)
    #expect(ClipLiveShareNativeV3.controlDataChannelLabel == "clip-native-control-v3")
    #expect(ClipLiveShareNativeV3.maximumProtocolParticipants == 4)
    #expect(ClipLiveShareNativeV3.defaultProductAdmissionLimit == 2)
    #expect(ClipLiveShareNativeV3.reservedVideoSlotsPerParticipant == 4)
    #expect(ClipLiveShareNativeV3.defaultMaximumActiveSourcesPerParticipant == 2)
    #expect(
      ClipLiveShareNativeV3.maximumMembershipCredentialLifetimeMilliseconds
        == 5 * 60 * 1_000
    )
  }

  @Test("participant, source, and peer-link keys are canonical and collision-safe")
  func canonicalIdentifiers() throws {
    let first = try participantID(0x20)
    let second = try participantID(0x10)
    let sourceID = try ClipLiveShareSourceInstanceID(
      bytes: Data(repeating: 0x33, count: 16)
    )

    #expect(
      try ClipLiveShareNativeV3ParticipantID(rawValue: first.rawValue) == first
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidParticipantID) {
      try ClipLiveShareNativeV3ParticipantID(bytes: Data(repeating: 0, count: 15))
    }

    let sourceForFirst = ClipLiveShareNativeV3SourceKey(
      ownerParticipantID: first,
      sourceInstanceID: sourceID
    )
    let sourceForSecond = ClipLiveShareNativeV3SourceKey(
      ownerParticipantID: second,
      sourceInstanceID: sourceID
    )
    #expect(sourceForFirst != sourceForSecond)

    let forward = try ClipLiveShareNativeV3PeerLinkKey(first, second)
    let reverse = try ClipLiveShareNativeV3PeerLinkKey(second, first)
    #expect(forward == reverse)
    #expect(forward.lowerParticipantID == second)
    #expect(forward.otherParticipant(than: first) == second)
    #expect(throws: ClipLiveShareNativeV3Error.selfPeerLink) {
      try ClipLiveShareNativeV3PeerLinkKey(first, first)
    }
  }

  @Test("unknown optional capabilities survive while unknown requirements fail strictly")
  func forwardCompatibleCapabilities() throws {
    let future = try ClipLiveShareNativeV3Capability(
      rawValue: "annotations.vector-v2"
    )
    let optionalFuture = try ClipLiveShareNativeV3Capabilities(
      supported: ClipLiveShareNativeV3Capabilities.current.supported.union([future]),
      required: ClipLiveShareNativeV3Capabilities.current.required
    )
    try ClipLiveShareNativeV3Capabilities.current.validateCompatibility(
      with: optionalFuture
    )

    let encoded = try ClipLiveShareNativeV3FoundationJSONCodec.encode(optionalFuture)
    let decoded = try ClipLiveShareNativeV3FoundationJSONCodec.decode(
      ClipLiveShareNativeV3Capabilities.self,
      from: encoded
    )
    #expect(decoded == optionalFuture)
    #expect(decoded.supported.contains(future))

    let requiredFuture = try ClipLiveShareNativeV3Capabilities(
      supported: optionalFuture.supported,
      required: optionalFuture.required.union([future])
    )
    #expect(
      throws: ClipLiveShareNativeV3Error.incompatibleCapabilities(
        missing: [future]
      )
    ) {
      try ClipLiveShareNativeV3Capabilities.current.validateCompatibility(
        with: requiredFuture
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.self) {
      try ClipLiveShareNativeV3Capability(rawValue: "Not Uppercase")
    }
  }

  @Test("membership credentials bind identity, context, capabilities, lifetime, and signature")
  func signedCredentialSecurity() throws {
    let fixture = NativeV3Fixture()
    let signed = try fixture.signedCredential(
      participant: fixture.guest,
      revision: 1
    )

    try signed.verify(
      expectedSessionID: fixture.sessionID,
      expectedLeaderParticipantID: fixture.leader.participantID,
      expectedLeaderIdentity: fixture.leaderSigner.publicKey,
      at: fixture.now
    )
    #expect(
      signed.credential.expiresAt.millisecondsSince1970
        - signed.credential.issuedAt.millisecondsSince1970
        == ClipLiveShareNativeV3.maximumMembershipCredentialLifetimeMilliseconds
    )

    let otherSession = try ClipLiveShareSessionID(rawValue: "other-v3-session")
    #expect(throws: ClipLiveShareNativeV3Error.contextMismatch) {
      try signed.verify(
        expectedSessionID: otherSession,
        expectedLeaderParticipantID: fixture.leader.participantID,
        expectedLeaderIdentity: fixture.leaderSigner.publicKey,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.identityMismatch) {
      try signed.verify(
        expectedSessionID: fixture.sessionID,
        expectedLeaderParticipantID: fixture.leader.participantID,
        expectedLeaderIdentity: fixture.otherSigner.publicKey,
        at: fixture.now
      )
    }

    let changedParticipant = try ClipLiveShareNativeV3Participant(
      participantID: fixture.guest.participantID,
      identity: fixture.guest.identity,
      displayName: "Tampered name",
      capabilities: .current
    )
    let changedCredential = try fixture.credential(
      participant: changedParticipant,
      revision: 1
    )
    let tampered = ClipLiveShareSignedNativeV3MembershipCredential(
      credential: changedCredential,
      signature: signed.signature
    )
    #expect(throws: ClipLiveShareNativeV3Error.invalidSignature) {
      try tampered.verify(
        expectedSessionID: fixture.sessionID,
        expectedLeaderParticipantID: fixture.leader.participantID,
        expectedLeaderIdentity: fixture.leaderSigner.publicKey,
        at: fixture.now
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.expired) {
      try signed.verify(
        expectedSessionID: fixture.sessionID,
        expectedLeaderParticipantID: fixture.leader.participantID,
        expectedLeaderIdentity: fixture.leaderSigner.publicKey,
        at: signed.credential.expiresAt
      )
    }
    #expect(throws: ClipLiveShareNativeV3Error.invalidLifetime) {
      _ = try fixture.credential(
        participant: fixture.guest,
        revision: 1,
        expiresAfter:
          ClipLiveShareNativeV3.maximumMembershipCredentialLifetimeMilliseconds + 1
      )
    }
  }

  @Test("leader-signed snapshots are canonical, nested, and version strict")
  func signedSnapshotSecurityAndWireSchema() throws {
    let fixture = NativeV3Fixture()
    let forward = try fixture.signedSnapshot(
      participants: [fixture.leader, fixture.guest],
      revision: 1
    )
    let reverse = try fixture.signedSnapshot(
      participants: [fixture.guest, fixture.leader],
      revision: 1
    )
    #expect(
      forward.snapshot.canonicalRepresentation
        == reverse.snapshot.canonicalRepresentation
    )

    try forward.verify(
      expectedSessionID: fixture.sessionID,
      expectedLeaderParticipantID: fixture.leader.participantID,
      expectedLeaderIdentity: fixture.leaderSigner.publicKey,
      at: fixture.now
    )
    let encoded = try ClipLiveShareNativeV3FoundationJSONCodec.encode(forward)
    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(text.contains("\"version\":3"))
    #expect(text.contains("\"membershipRevision\":1"))
    #expect(
      try ClipLiveShareNativeV3FoundationJSONCodec.decode(
        ClipLiveShareSignedNativeV3MembershipSnapshot.self,
        from: encoded
      ) == forward
    )

    let object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var mutated = object
    var snapshotObject = try #require(mutated["snapshot"] as? [String: Any])
    snapshotObject["version"] = 2
    mutated["snapshot"] = snapshotObject
    let wrongVersion = try JSONSerialization.data(withJSONObject: mutated)
    #expect(throws: ClipLiveShareProtocolError.unsupportedVersion(2)) {
      try ClipLiveShareNativeV3FoundationJSONCodec.decode(
        ClipLiveShareSignedNativeV3MembershipSnapshot.self,
        from: wrongVersion
      )
    }
  }

  @Test("wire accepts a four-participant complete mesh while product defaults admit two")
  func completeMeshProtocolAndProductLimits() throws {
    let fixture = NativeV3Fixture()
    let participants = [
      fixture.leader,
      fixture.guest,
      fixture.third,
      fixture.fourth,
    ]
    let signed = try fixture.signedSnapshot(participants: participants, revision: 1)
    let topology = try ClipLiveShareNativeV3CompleteMeshTopology(
      participantIDs: signed.snapshot.participantIDs
    )

    #expect(topology.participantIDs.count == 4)
    #expect(topology.peerLinkKeys.count == 6)
    #expect(try topology.peers(for: fixture.guest.participantID).count == 3)
    try topology.validateCompleteMesh()
    let leaderLinks = try fixture.establishedLinks(
      local: fixture.leader,
      participants: participants
    )
    #expect(
      topology.isLocallyReady(
        participantID: fixture.leader.participantID,
        establishedLinks: leaderLinks
      )
    )
    #expect(!topology.isComplete(establishedLinks: leaderLinks))
    #expect(topology.isComplete(establishedLinks: topology.peerLinkKeys))

    #expect(throws: ClipLiveShareNativeV3Error.participantLimit(maximum: 2, actual: 4)) {
      _ = try ClipLiveShareNativeV3MeshState(
        localParticipantID: fixture.leader.participantID,
        signedMembership: signed,
        expectedSessionID: fixture.sessionID,
        expectedLeaderParticipantID: fixture.leader.participantID,
        expectedLeaderIdentity: fixture.leaderSigner.publicKey,
        establishedLinks: leaderLinks,
        at: fixture.now
      )
    }
    let protocolState = try ClipLiveShareNativeV3MeshState(
      localParticipantID: fixture.leader.participantID,
      signedMembership: signed,
      expectedSessionID: fixture.sessionID,
      expectedLeaderParticipantID: fixture.leader.participantID,
      expectedLeaderIdentity: fixture.leaderSigner.publicKey,
      admissionPolicy: .protocolMaximum,
      establishedLinks: leaderLinks,
      at: fixture.now
    )
    #expect(protocolState.peerLinks.count == 6)

    let fiveParticipants = Set(
      try (0..<5).map { try participantID(UInt8(0x50 + $0)) }
    )
    #expect(
      throws: ClipLiveShareNativeV3Error.participantLimit(
        maximum: 4,
        actual: 5
      )
    ) {
      _ = try ClipLiveShareNativeV3CompleteMeshTopology(
        participantIDs: fiveParticipants,
        maximumParticipants: 5
      )
    }
  }

  @Test("membership and each publisher use independent monotonic ledgers")
  func independentRevisionLedgers() throws {
    let first = try participantID(0x01)
    let second = try participantID(0x02)
    var membership = ClipLiveShareNativeV3MembershipRevisionLedger()
    var sources = ClipLiveShareNativeV3SourceRevisionLedger()
    var peerLinks = ClipLiveShareNativeV3PeerLinkRevisionLedger()
    let firstSecond = try ClipLiveShareNativeV3PeerLinkKey(first, second)
    let third = try participantID(0x03)
    let firstThird = try ClipLiveShareNativeV3PeerLinkKey(first, third)

    try membership.accept(ClipLiveShareNativeV3MembershipRevision(rawValue: 9))
    try sources.accept(
      ClipLiveShareNativeV3SourceRevision(rawValue: 40),
      from: first
    )
    try sources.accept(
      ClipLiveShareNativeV3SourceRevision(rawValue: 1),
      from: second
    )
    try peerLinks.accept(
      ClipLiveShareNativeV3PeerLinkRevision(rawValue: 50),
      for: firstSecond
    )
    try peerLinks.accept(
      ClipLiveShareNativeV3PeerLinkRevision(rawValue: 1),
      for: firstThird
    )
    #expect(membership.latestAcceptedRevision?.rawValue == 9)
    #expect(sources.latestAcceptedRevisions[first]?.rawValue == 40)
    #expect(sources.latestAcceptedRevisions[second]?.rawValue == 1)
    #expect(peerLinks.latestAcceptedRevisions[firstSecond]?.rawValue == 50)
    #expect(peerLinks.latestAcceptedRevisions[firstThird]?.rawValue == 1)

    #expect(
      throws: ClipLiveShareNativeV3Error.staleMembershipRevision(
        expectedGreaterThan: 9,
        actual: 9
      )
    ) {
      try membership.accept(ClipLiveShareNativeV3MembershipRevision(rawValue: 9))
    }
    #expect(
      throws: ClipLiveShareNativeV3Error.staleSourceRevision(
        participantID: second,
        expectedGreaterThan: 1,
        actual: 1
      )
    ) {
      try sources.accept(
        ClipLiveShareNativeV3SourceRevision(rawValue: 1),
        from: second
      )
    }
    #expect(
      throws: ClipLiveShareNativeV3Error.stalePeerLinkRevision(
        peerLinkKey: firstSecond,
        expectedGreaterThan: 50,
        actual: 50
      )
    ) {
      try peerLinks.accept(
        ClipLiveShareNativeV3PeerLinkRevision(rawValue: 50),
        for: firstSecond
      )
    }

    #expect(throws: ClipLiveShareNativeV3Error.invalidRevision(name: "membership")) {
      _ = try ClipLiveShareNativeV3MembershipRevision(rawValue: 0)
    }
    #expect(throws: ClipLiveShareNativeV3Error.invalidRevision(name: "source")) {
      _ = try ClipLiveShareNativeV3SourceRevision(rawValue: 0)
    }
    #expect(
      throws: ClipLiveShareNativeV3Error.invalidRevision(
        name: "peer-link negotiation"
      )
    ) {
      _ = try ClipLiveShareNativeV3PeerLinkRevision(rawValue: 0)
    }
  }

  @Test("membership cannot rebind an existing participant ID to another identity")
  func participantIdentityRebindingIsTransactional() throws {
    let fixture = NativeV3Fixture()
    let participants = [fixture.leader, fixture.guest]
    let initial = try fixture.signedSnapshot(
      participants: participants,
      revision: 1
    )
    let establishedLinks = try fixture.establishedLinks(
      local: fixture.leader,
      participants: participants
    )
    var state = try ClipLiveShareNativeV3MeshState(
      localParticipantID: fixture.leader.participantID,
      signedMembership: initial,
      expectedSessionID: fixture.sessionID,
      expectedLeaderParticipantID: fixture.leader.participantID,
      expectedLeaderIdentity: fixture.leaderSigner.publicKey,
      establishedLinks: establishedLinks,
      at: fixture.now
    )
    let guestSource = try fixture.publishedSource(
      owner: fixture.guest,
      byte: 0x63
    )
    try state.applySourceSnapshot(
      ClipLiveShareNativeV3SourceSnapshot(
        sessionID: fixture.sessionID,
        membershipRevision: ClipLiveShareNativeV3MembershipRevision(rawValue: 1),
        ownerParticipantID: fixture.guest.participantID,
        sourceRevision: ClipLiveShareNativeV3SourceRevision(rawValue: 7),
        sources: [guestSource]
      ),
      from: fixture.guest.participantID
    )

    let reboundGuest = try fixture.participant(
      idByte: 0x20,
      signer: fixture.otherSigner,
      name: "Rebound guest"
    )
    let reboundSnapshot = try fixture.signedSnapshot(
      participants: [fixture.leader, reboundGuest],
      revision: 2,
      issuedOffset: 1_000
    )
    let stateBeforeRebind = state

    #expect(
      throws: ClipLiveShareNativeV3Error.participantIdentityChanged(
        fixture.guest.participantID
      )
    ) {
      try state.applyMembershipSnapshot(
        reboundSnapshot,
        establishedLinks: establishedLinks,
        at: fixture.now
      )
    }
    #expect(state == stateBeforeRebind)
    #expect(state.sources[guestSource.key] == guestSource)
    #expect(
      state.sourceLedger.latestAcceptedRevisions[fixture.guest.participantID]?
        .rawValue == 7
    )
  }

  @Test("mesh state authenticates source ownership and removes departed publishers")
  func meshSourceAndMembershipState() throws {
    let fixture = NativeV3Fixture()
    let initial = try fixture.signedSnapshot(
      participants: [fixture.leader, fixture.guest, fixture.third],
      revision: 1
    )
    var state = try ClipLiveShareNativeV3MeshState(
      localParticipantID: fixture.leader.participantID,
      signedMembership: initial,
      expectedSessionID: fixture.sessionID,
      expectedLeaderParticipantID: fixture.leader.participantID,
      expectedLeaderIdentity: fixture.leaderSigner.publicKey,
      admissionPolicy: .protocolMaximum,
      establishedLinks: try fixture.establishedLinks(
        local: fixture.leader,
        participants: [fixture.leader, fixture.guest, fixture.third]
      ),
      at: fixture.now
    )

    let guestSource = try fixture.publishedSource(owner: fixture.guest, byte: 0x61)
    let thirdSource = try fixture.publishedSource(owner: fixture.third, byte: 0x71)
    try state.applySourceSnapshot(
      ClipLiveShareNativeV3SourceSnapshot(
        sessionID: fixture.sessionID,
        membershipRevision: ClipLiveShareNativeV3MembershipRevision(rawValue: 1),
        ownerParticipantID: fixture.guest.participantID,
        sourceRevision: ClipLiveShareNativeV3SourceRevision(rawValue: 1),
        sources: [guestSource]
      ),
      from: fixture.guest.participantID
    )
    try state.applySourceSnapshot(
      ClipLiveShareNativeV3SourceSnapshot(
        sessionID: fixture.sessionID,
        membershipRevision: ClipLiveShareNativeV3MembershipRevision(rawValue: 1),
        ownerParticipantID: fixture.third.participantID,
        sourceRevision: ClipLiveShareNativeV3SourceRevision(rawValue: 1),
        sources: [thirdSource]
      ),
      from: fixture.third.participantID
    )
    #expect(state.sources.count == 2)

    #expect(throws: ClipLiveShareNativeV3Error.invalidSourceOwnership) {
      try state.applySourceSnapshot(
        ClipLiveShareNativeV3SourceSnapshot(
          sessionID: fixture.sessionID,
          membershipRevision: ClipLiveShareNativeV3MembershipRevision(rawValue: 1),
          ownerParticipantID: fixture.guest.participantID,
          sourceRevision: ClipLiveShareNativeV3SourceRevision(rawValue: 2),
          sources: [guestSource]
        ),
        from: fixture.third.participantID
      )
    }
    #expect(state.sourceLedger.latestAcceptedRevisions[fixture.guest.participantID]?.rawValue == 1)

    let retainedLink = try ClipLiveShareNativeV3PeerLinkKey(
      fixture.leader.participantID,
      fixture.guest.participantID
    )
    try state.setPeerLinkPhase(
      .connected,
      for: retainedLink,
      negotiationRevision: ClipLiveShareNativeV3PeerLinkRevision(rawValue: 1)
    )

    let addingFourth = try fixture.signedSnapshot(
      participants: [
        fixture.leader,
        fixture.guest,
        fixture.third,
        fixture.fourth,
      ],
      revision: 2,
      issuedOffset: 1_000
    )
    let stateBeforeIncompleteTopology = state
    #expect(throws: ClipLiveShareNativeV3Error.invalidTopology) {
      try state.applyMembershipSnapshot(
        addingFourth,
        establishedLinks: try fixture.establishedLinks(
          local: fixture.leader,
          participants: [fixture.leader, fixture.guest, fixture.third]
        ),
        at: fixture.now
      )
    }
    #expect(state == stateBeforeIncompleteTopology)
    #expect(state.signedMembership.snapshot.membershipRevision.rawValue == 1)
    #expect(state.sources.count == 2)

    let withoutThird = try fixture.signedSnapshot(
      participants: [fixture.leader, fixture.guest],
      revision: 2,
      issuedOffset: 1_000
    )
    try state.applyMembershipSnapshot(
      withoutThird,
      establishedLinks: [retainedLink],
      at: fixture.now
    )
    #expect(state.topology.participantIDs.count == 2)
    #expect(state.peerLinks[retainedLink]?.phase == .connected)
    #expect(state.sources[guestSource.key] == guestSource)
    #expect(state.sources[thirdSource.key] == nil)
    #expect(state.sourceLedger.latestAcceptedRevisions[fixture.third.participantID] == nil)

    #expect(
      throws: ClipLiveShareNativeV3Error.staleMembershipRevision(
        expectedGreaterThan: 2,
        actual: 1
      )
    ) {
      try state.applyMembershipSnapshot(
        initial,
        establishedLinks: try fixture.establishedLinks(
          local: fixture.leader,
          participants: [fixture.leader, fixture.guest, fixture.third]
        ),
        at: fixture.now
      )
    }
  }

  @Test("source snapshots accept four wire slots but product state enforces two active")
  func sourceWireAndProductLimits() throws {
    let fixture = NativeV3Fixture()
    let signed = try fixture.signedSnapshot(
      participants: [fixture.leader, fixture.guest],
      revision: 1
    )
    var state = try ClipLiveShareNativeV3MeshState(
      localParticipantID: fixture.leader.participantID,
      signedMembership: signed,
      expectedSessionID: fixture.sessionID,
      expectedLeaderParticipantID: fixture.leader.participantID,
      expectedLeaderIdentity: fixture.leaderSigner.publicKey,
      establishedLinks: try fixture.establishedLinks(
        local: fixture.leader,
        participants: [fixture.leader, fixture.guest]
      ),
      at: fixture.now
    )
    let sources = try (0..<4).map {
      try fixture.publishedSource(
        owner: fixture.guest,
        byte: UInt8(0x40 + $0)
      )
    }
    let wireSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
      sessionID: fixture.sessionID,
      membershipRevision: ClipLiveShareNativeV3MembershipRevision(rawValue: 1),
      ownerParticipantID: fixture.guest.participantID,
      sourceRevision: ClipLiveShareNativeV3SourceRevision(rawValue: 1),
      sources: sources
    )
    #expect(wireSnapshot.sources.count == 4)
    #expect(throws: ClipLiveShareProtocolError.self) {
      try state.applySourceSnapshot(
        wireSnapshot,
        from: fixture.guest.participantID
      )
    }
    #expect(state.sources.isEmpty)
    #expect(state.sourceLedger.latestAcceptedRevisions.isEmpty)
  }
}

private struct NativeV3Fixture {
  let leaderSigner = ClipLiveShareSoftwareIdentitySigner()
  let guestSigner = ClipLiveShareSoftwareIdentitySigner()
  let thirdSigner = ClipLiveShareSoftwareIdentitySigner()
  let fourthSigner = ClipLiveShareSoftwareIdentitySigner()
  let otherSigner = ClipLiveShareSoftwareIdentitySigner()

  let sessionID = try! ClipLiveShareSessionID(rawValue: "native-v3-session")
  let issuedAt = try! ClipLiveShareNativeTimestamp(
    millisecondsSince1970: 1_800_000_000_000
  )

  var now: ClipLiveShareNativeTimestamp {
    try! issuedAt.adding(milliseconds: 2_000)
  }

  var leader: ClipLiveShareNativeV3Participant {
    try! participant(
      idByte: 0x10,
      signer: leaderSigner,
      name: "Leader"
    )
  }

  var guest: ClipLiveShareNativeV3Participant {
    try! participant(
      idByte: 0x20,
      signer: guestSigner,
      name: "Guest"
    )
  }

  var third: ClipLiveShareNativeV3Participant {
    try! participant(
      idByte: 0x30,
      signer: thirdSigner,
      name: "Third"
    )
  }

  var fourth: ClipLiveShareNativeV3Participant {
    try! participant(
      idByte: 0x40,
      signer: fourthSigner,
      name: "Fourth"
    )
  }

  func participant(
    idByte: UInt8,
    signer: ClipLiveShareSoftwareIdentitySigner,
    name: String
  ) throws -> ClipLiveShareNativeV3Participant {
    try ClipLiveShareNativeV3Participant(
      participantID: participantID(idByte),
      identity: signer.publicKey,
      displayName: name,
      capabilities: .current
    )
  }

  func credential(
    participant: ClipLiveShareNativeV3Participant,
    revision: UInt64,
    expiresAfter: Int64 =
      ClipLiveShareNativeV3.maximumMembershipCredentialLifetimeMilliseconds
  ) throws -> ClipLiveShareNativeV3MembershipCredential {
    try ClipLiveShareNativeV3MembershipCredential(
      sessionID: sessionID,
      leaderParticipantID: leader.participantID,
      leaderIdentity: leaderSigner.publicKey,
      participant: participant,
      membershipRevision: ClipLiveShareNativeV3MembershipRevision(rawValue: revision),
      issuedAt: issuedAt,
      expiresAt: issuedAt.adding(milliseconds: expiresAfter)
    )
  }

  func signedCredential(
    participant: ClipLiveShareNativeV3Participant,
    revision: UInt64
  ) throws -> ClipLiveShareSignedNativeV3MembershipCredential {
    try ClipLiveShareSignedNativeV3MembershipCredential(
      signing: credential(participant: participant, revision: revision),
      with: leaderSigner
    )
  }

  func signedSnapshot(
    participants: [ClipLiveShareNativeV3Participant],
    revision: UInt64,
    issuedOffset: Int64 = 0
  ) throws -> ClipLiveShareSignedNativeV3MembershipSnapshot {
    let credentials = try participants.map {
      try signedCredential(participant: $0, revision: min(revision, 1))
    }
    let snapshotIssuedAt = try issuedAt.adding(milliseconds: issuedOffset)
    let snapshot = try ClipLiveShareNativeV3MembershipSnapshot(
      sessionID: sessionID,
      leaderParticipantID: leader.participantID,
      leaderIdentity: leaderSigner.publicKey,
      membershipRevision: ClipLiveShareNativeV3MembershipRevision(rawValue: revision),
      credentials: credentials,
      issuedAt: snapshotIssuedAt,
      expiresAt: snapshotIssuedAt.adding(milliseconds: 120_000)
    )
    return try ClipLiveShareSignedNativeV3MembershipSnapshot(
      signing: snapshot,
      with: leaderSigner
    )
  }

  func publishedSource(
    owner: ClipLiveShareNativeV3Participant,
    byte: UInt8
  ) throws -> ClipLiveShareNativeV3PublishedSource {
    let sourceID = try ClipLiveShareSourceInstanceID(
      bytes: Data(repeating: byte, count: 16)
    )
    let descriptor = ClipLiveShareNativeStreamDescriptor(
      sourceInstanceID: sourceID,
      presentationMode: .manual,
      stream: try ClipLiveShareStreamDescriptor(
        id: ClipLiveShareStreamID(rawValue: "stream-\(byte)"),
        mediaTrackID: ClipLiveShareMediaTrackID(rawValue: "track-\(byte)"),
        active: true,
        focused: false,
        appName: "Fixture",
        windowName: "Window \(byte)",
        width: 1_280,
        height: 720,
        order: Int(byte)
      )
    )
    return try ClipLiveShareNativeV3PublishedSource(
      key: ClipLiveShareNativeV3SourceKey(
        ownerParticipantID: owner.participantID,
        sourceInstanceID: sourceID
      ),
      descriptor: descriptor
    )
  }

  func establishedLinks(
    local: ClipLiveShareNativeV3Participant,
    participants: [ClipLiveShareNativeV3Participant]
  ) throws -> Set<ClipLiveShareNativeV3PeerLinkKey> {
    Set(
      try participants
        .filter { $0.participantID != local.participantID }
        .map {
          try ClipLiveShareNativeV3PeerLinkKey(
            local.participantID,
            $0.participantID
          )
        }
    )
  }
}

private func participantID(_ byte: UInt8) throws -> ClipLiveShareNativeV3ParticipantID {
  try ClipLiveShareNativeV3ParticipantID(
    bytes: Data(repeating: byte, count: ClipLiveShareNativeV3.participantIDByteCount)
  )
}
