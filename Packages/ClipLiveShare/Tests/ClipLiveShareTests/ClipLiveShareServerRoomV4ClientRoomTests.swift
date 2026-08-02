import CryptoKit
import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Server-room v4 client admission and pair state")
struct ClipLiveShareServerRoomV4ClientRoomTests {
  @Test("creator factory emits one stable private invite and exact create body")
  func creatorFactory() throws {
    let fixture = try ClientRoomFixture()
    let bootstrap = try fixture.creatorBootstrap()

    #expect(bootstrap.createRequest.creatorHandle == fixture.handles[0])
    #expect(bootstrap.createRequest.ownerToken == fixture.ownerCapability)
    #expect(bootstrap.createRequest.descriptor.ciphertext.count <= 16_384)
    #expect(bootstrap.invite.roomID == fixture.roomID)
    #expect(bootstrap.room.localHandle == fixture.handles[0])
    #expect(bootstrap.room.role == .creator)
    #expect(try bootstrap.invite.url == bootstrap.room.currentInvite?.url)
    #expect(!bootstrap.room.description.contains(fixture.ownerCapability.rawValue))
    #expect(!bootstrap.room.description.contains(fixture.roomSecret.rawValue))
  }

  @Test("protocol constants and admission boundary match the Go service")
  func goContractConstants() throws {
    #expect(ClipLiveShareServerRoomV4.protocolIdentifier == "clip-native-room")
    #expect(ClipLiveShareServerRoomV4.maximumOpaqueAdmissionBytes == 16_384)
    _ = try ClipLiveShareServerRoomV4OpaqueAdmissionRecord(
      ciphertext: Data(repeating: 1, count: 16_384)
    )
    #expect(throws: ClipLiveShareServerRoomV4Error.self) {
      try ClipLiveShareServerRoomV4OpaqueAdmissionRecord(
        ciphertext: Data(repeating: 1, count: 16_385)
      )
    }
  }

  @Test("pair ordering follows Go base64url ordering for adversarial handles")
  func crossLanguagePairOrdering() throws {
    var highBytes = Data(repeating: UInt8.zero, count: 16)
    highBytes[0] = 0xF8
    let dashHandle = try ClipLiveShareServerRoomV4MemberHandle(bytes: highBytes)
    let letterHandle = try ClipLiveShareServerRoomV4MemberHandle(
      bytes: Data(repeating: 0, count: 16)
    )
    #expect(!(dashHandle < letterHandle))
    #expect(dashHandle.rawValue < letterHandle.rawValue)

    let roomID = try ClientRoomFixture.fixedRoomID(0x11)
    let context = try ClipLiveShareServerRoomV4PairContext(
      roomID: roomID,
      sessionID: try .init(rawValue: "cross-language-session"),
      firstHandle: letterHandle,
      firstParticipantID: ClientRoomFixture.participantID(0x11),
      secondHandle: dashHandle,
      secondParticipantID: ClientRoomFixture.participantID(0x22)
    )
    #expect(context.lowerHandle == dashHandle)
    #expect(context.upperHandle == letterHandle)
    let canonical = Data(
      ("clip-native-room-v4-pair\0" + roomID.rawValue + "\0"
        + dashHandle.rawValue + "\0" + letterHandle.rawValue).utf8
    )
    #expect(context.pairID.bytes == Data(SHA256.hash(data: canonical)))
  }

  @Test("two three and four participants derive a complete direct mesh")
  func completeMeshes() throws {
    for participantCount in 2...4 {
      var mesh = try ClientMeshHarness()
      for index in 1..<participantCount {
        try mesh.admitParticipant(index)
      }
      var allPairIDs = Set<ClipLiveShareServerRoomV4PairID>()
      for index in 0..<participantCount {
        let room = try #require(mesh.rooms[mesh.fixture.handles[index]])
        #expect(room.snapshot.members.count == participantCount)
        #expect(room.snapshot.pairs.count == participantCount - 1)
        allPairIDs.formUnion(room.snapshot.pairs.map(\.pairID))
        #expect(room.snapshot.pairs.allSatisfy { $0.epoch.rawValue == 1 })
      }
      #expect(allPairIDs.count == participantCount * (participantCount - 1) / 2)
    }
  }

  @Test("client-verified projections contain full two three and four member state")
  func verifiedProjectionContents() throws {
    for participantCount in 2...4 {
      var mesh = try ClientMeshHarness()
      for index in 1..<participantCount {
        try mesh.admitParticipant(index)
      }
      for localIndex in 0..<participantCount {
        let localHandle = mesh.fixture.handles[localIndex]
        let projection = try #require(mesh.room(localHandle).clientVerifiedState)
        #expect(projection.role == (localIndex == 0 ? .creator : .participant))
        #expect(projection.creatorHandle == mesh.fixture.handles[0])
        #expect(projection.localHandle == localHandle)
        #expect(projection.members.count == participantCount)
        #expect(projection.pairs.count == participantCount - 1)
        #expect(projection.members.filter(\.isCreator).count == 1)
        #expect(projection.members.filter(\.isLocal).count == 1)
        for index in 0..<participantCount {
          let member = try #require(
            projection.members.first { $0.handle == mesh.fixture.handles[index] }
          )
          #expect(member.descriptor == mesh.fixture.participants[index].descriptor)
          #expect(member.connected)
        }
        for pair in projection.pairs {
          #expect(pair.context.contains(localHandle))
          #expect(pair.context.contains(pair.remoteHandle))
          #expect(pair.epoch.rawValue == 1)
        }
      }
    }
  }

  @Test("client-verified projection retains disconnected members and pairs")
  func disconnectedProjectionRetention() throws {
    var mesh = try ClientMeshHarness()
    try mesh.admitParticipant(1)
    let a = mesh.fixture.handles[0]
    let b = mesh.fixture.handles[1]
    mesh.revision += 1
    let disconnected = try ClipLiveShareServerRoomV4RosterSnapshot(
      revision: .init(rawValue: mesh.revision),
      creatorHandle: a,
      members: [
        .init(handle: a, descriptor: try #require(mesh.records[a]), connected: true),
        .init(handle: b, descriptor: try #require(mesh.records[b]), connected: false),
      ]
    )
    for handle in [a, b] {
      var room = try mesh.room(handle)
      let transition = try room.consumeRosterSnapshot(disconnected)
      #expect(transition.addedPeers.isEmpty)
      #expect(transition.retainedPeers.count == 1)
      mesh.rooms[handle] = room
    }

    let projection = try #require(mesh.room(a).clientVerifiedState)
    #expect(projection.members.first { $0.handle == b }?.connected == false)
    #expect(projection.pairs.map(\.remoteHandle) == [b])
  }

  @Test("verified AB context and epoch survive C and D roster churn")
  func verifiedPairStability() throws {
    var mesh = try ClientMeshHarness()
    try mesh.admitParticipant(1)
    let a = mesh.fixture.handles[0]
    let b = mesh.fixture.handles[1]
    let c = mesh.fixture.handles[2]
    let d = mesh.fixture.handles[3]
    let initial = try #require(
      mesh.room(a).clientVerifiedState?.pairs.first { $0.remoteHandle == b }
    )

    try mesh.admitParticipant(2)
    try mesh.admitParticipant(3)
    let expanded = try #require(
      mesh.room(a).clientVerifiedState?.pairs.first { $0.remoteHandle == b }
    )
    #expect(expanded == initial)
    try mesh.removeParticipant(d)
    try mesh.removeParticipant(c)
    let contracted = try #require(
      mesh.room(a).clientVerifiedState?.pairs.first { $0.remoteHandle == b }
    )
    #expect(contracted == initial)
  }

  @Test("duplicate same-revision roster is inert for verified state")
  func duplicateRosterIsInert() throws {
    var mesh = try ClientMeshHarness()
    try mesh.admitParticipant(1)
    let a = mesh.fixture.handles[0]
    let b = mesh.fixture.handles[1]
    var room = try mesh.room(a)
    let before = try #require(room.clientVerifiedState)
    let transition = try room.consumeRosterSnapshot(mesh.roster())
    let after = try #require(room.clientVerifiedState)
    #expect(after == before)
    #expect(transition.addedPeers.isEmpty)
    #expect(transition.removedPeers.isEmpty)
    #expect(transition.retainedPeers == [b])
  }

  @Test("verified projection descriptions and encoding contain no private material")
  func verifiedProjectionRedaction() throws {
    var mesh = try ClientMeshHarness()
    try mesh.admitParticipant(1)
    let projection = try #require(
      mesh.room(mesh.fixture.handles[0]).clientVerifiedState
    )
    let reconnect = try mesh.room(mesh.fixture.handles[1]).exportReconnectCredential()
    let description = String(reflecting: projection)
    #expect(!description.contains(mesh.fixture.roomID.rawValue))
    #expect(!description.contains(mesh.fixture.handles[0].rawValue))
    #expect(description.contains("identifiers: <redacted>"))

    let encoded = try JSONEncoder().encode(projection)
    let json = try #require(String(data: encoded, encoding: .utf8))
    let privateValues = [
      mesh.fixture.ownerCapability.rawValue,
      mesh.fixture.roomSecret.rawValue,
      mesh.fixture.admissionCapability.rawValue,
      reconnect.reconnectCapability.rawValue,
    ]
    #expect(privateValues.allSatisfy { !json.contains($0) })
    #expect(!json.contains("ownerToken"))
    #expect(!json.contains("admissionCapability"))
    #expect(!json.contains("reconnectCapability"))
    #expect(!json.contains("roomAgreementSecret"))
  }

  @Test("retained AB pair channel preserves sequences while C joins and leaves")
  func retainedPairChannel() throws {
    var mesh = try ClientMeshHarness()
    try mesh.admitParticipant(1)
    let a = mesh.fixture.handles[0]
    let b = mesh.fixture.handles[1]
    let c = mesh.fixture.handles[2]

    let first = try mesh.seal(
      from: a,
      to: b,
      payload: .offer(epoch: .init(rawValue: 1), sdp: "v=0\r\nfirst")
    )
    #expect(try mesh.open(at: b, envelope: first.routedFrom(a)).epoch?.rawValue == 1)
    #expect(
      try mesh.room(a).snapshot.pairs.first { $0.remoteHandle == b }?.lastOutboundSequence == 1)
    #expect(
      try mesh.room(b).snapshot.pairs.first { $0.remoteHandle == a }?.lastInboundSequence == 1)

    try mesh.admitParticipant(2)
    #expect(
      try mesh.room(a).snapshot.pairs.first { $0.remoteHandle == b }?.lastOutboundSequence == 1)
    #expect(
      try mesh.room(b).snapshot.pairs.first { $0.remoteHandle == a }?.lastInboundSequence == 1)
    #expect(try mesh.room(a).snapshot.pairs.contains { $0.remoteHandle == c })

    try mesh.removeParticipant(c)
    #expect(
      try mesh.room(a).snapshot.pairs.first { $0.remoteHandle == b }?.lastOutboundSequence == 1)
    #expect(
      try mesh.room(b).snapshot.pairs.first { $0.remoteHandle == a }?.lastInboundSequence == 1)
    #expect(!(try mesh.room(a).snapshot.pairs.contains { $0.remoteHandle == c }))

    let second = try mesh.seal(
      from: a,
      to: b,
      payload: .renegotiationRequest(epoch: .init(rawValue: 1))
    )
    #expect(second.sequence == 2)
    #expect(
      try mesh.open(at: b, envelope: second.routedFrom(a))
        == .renegotiationRequest(epoch: .init(rawValue: 1))
    )
  }

  @Test("dropped pair sequence does not wedge the channel and replay still fails")
  func droppedPairSignal() throws {
    var mesh = try ClientMeshHarness()
    try mesh.admitParticipant(1)
    let a = mesh.fixture.handles[0]
    let b = mesh.fixture.handles[1]
    _ = try mesh.seal(
      from: a,
      to: b,
      payload: .offer(epoch: .init(rawValue: 1), sdp: "v=0\r\ndropped")
    )
    let second = try mesh.seal(
      from: a,
      to: b,
      payload: .iceRestart(epoch: .init(rawValue: 1))
    ).routedFrom(a)
    #expect(second.sequence == 2)
    #expect(
      try mesh.open(at: b, envelope: second)
        == .iceRestart(epoch: .init(rawValue: 1))
    )
    #expect(throws: ClipLiveShareProtocolError.self) {
      try mesh.open(at: b, envelope: second)
    }
  }

  @Test("pair route rejects a missing or wrong authenticated sender")
  func pairRouteValidation() throws {
    var mesh = try ClientMeshHarness()
    try mesh.admitParticipant(1)
    try mesh.admitParticipant(2)
    let a = mesh.fixture.handles[0]
    let b = mesh.fixture.handles[1]
    let c = mesh.fixture.handles[2]
    let outbound = try mesh.seal(
      from: a,
      to: b,
      payload: .offer(epoch: .init(rawValue: 1), sdp: "v=0\r\nroute")
    )
    #expect(throws: ClipLiveShareServerRoomV4ClientRoomError.pairUnavailable) {
      try mesh.open(at: b, envelope: outbound)
    }
    #expect(throws: (any Error).self) {
      try mesh.open(at: b, envelope: outbound.routedFrom(c))
    }
  }

  @Test("access word and approval policy do not mutate the invitation")
  func accessWordAndApproval() throws {
    let fixture = try ClientRoomFixture()
    var creatorBootstrap = try fixture.creatorBootstrap(
      policy: .requiringAccessWord("  Secret Word ", askBeforeJoining: true)
    )
    var creator = creatorBootstrap.room
    let stableURL = try #require(creator.currentInvite).url
    let candidateHandle = fixture.candidateHandles[1]

    let wrong = try fixture.candidateBootstrap(
      index: 1, invite: creatorBootstrap.invite, word: "wrong")
    #expect(throws: ClipLiveShareServerRoomV4ClientRoomError.invalidAccessWord) {
      try creator.consumeForwardedJoinKnock(
        candidateHandle: candidateHandle,
        payload: wrong.joinKnock
      )
    }

    let correct = try fixture.candidateBootstrap(
      index: 1,
      invite: creatorBootstrap.invite,
      word: "secret word"
    )
    let decision = try creator.consumeForwardedJoinKnock(
      candidateHandle: candidateHandle,
      payload: correct.joinKnock
    )
    guard case .pendingApproval(let pending) = decision else {
      Issue.record("Expected pending approval")
      return
    }
    #expect(pending.displayName == fixture.participants[1].descriptor.displayName)
    #expect(creator.snapshot.pendingApprovals == [pending])
    let command = try creator.approve(candidateHandle: candidateHandle)
    #expect(command.memberHandle == fixture.handles[1])

    try creator.setAdmissionPolicy(.open(askBeforeJoining: false))
    #expect(try creator.currentInvite?.url == stableURL)
    creatorBootstrap = try fixture.creatorBootstrap(policy: .open())
    #expect(try creatorBootstrap.invite.url != stableURL)
  }

  @Test("a friend join explicitly requires creator approval in an open room")
  func friendJoinRequiresApproval() throws {
    let fixture = try ClientRoomFixture()
    let bootstrap = try fixture.creatorBootstrap(policy: .open())
    var creator = bootstrap.room
    let candidateHandle = fixture.candidateHandles[1]
    let candidate = try fixture.candidateBootstrap(
      index: 1,
      invite: bootstrap.invite,
      requiresCreatorApproval: true
    )

    let decision = try creator.consumeForwardedJoinKnock(
      candidateHandle: candidateHandle,
      payload: candidate.joinKnock
    )
    guard case .pendingApproval(let pending) = decision else {
      Issue.record("Expected friend join to wait for creator approval")
      return
    }
    #expect(pending.participantID == fixture.participants[1].descriptor.participantID)
    #expect(creator.snapshot.pendingApprovals == [pending])

    let admission = try creator.approve(candidateHandle: candidateHandle)
    #expect(admission.memberHandle == fixture.handles[1])
  }

  @Test("a friend join verifies the Access Word before creator approval")
  func friendJoinWithAccessWordRequiresApproval() throws {
    let fixture = try ClientRoomFixture()
    let bootstrap = try fixture.creatorBootstrap(
      policy: .requiringAccessWord(
        "secret word",
        askBeforeJoining: false
      )
    )
    var creator = bootstrap.room
    let candidateHandle = fixture.candidateHandles[1]

    let missingWord = try fixture.candidateBootstrap(
      index: 1,
      invite: bootstrap.invite,
      requiresCreatorApproval: true
    )
    #expect(throws: ClipLiveShareServerRoomV4ClientRoomError.invalidAccessWord) {
      try creator.consumeForwardedJoinKnock(
        candidateHandle: candidateHandle,
        payload: missingWord.joinKnock
      )
    }

    let verifiedFriend = try fixture.candidateBootstrap(
      index: 1,
      invite: bootstrap.invite,
      word: "secret word",
      requiresCreatorApproval: true
    )
    guard case .pendingApproval(let pending) =
      try creator.consumeForwardedJoinKnock(
        candidateHandle: candidateHandle,
        payload: verifiedFriend.joinKnock
      )
    else {
      Issue.record("Expected verified friend to wait for creator approval")
      return
    }
    #expect(pending.participantID == fixture.participants[1].descriptor.participantID)
    #expect(creator.snapshot.pendingApprovals == [pending])
  }

  @Test("identical pending knock replay returns the same approval")
  func pendingKnockReplay() throws {
    let fixture = try ClientRoomFixture()
    let bootstrap = try fixture.creatorBootstrap(
      policy: .open(askBeforeJoining: true)
    )
    var creator = bootstrap.room
    let candidateHandle = fixture.candidateHandles[1]
    let candidate = try fixture.candidateBootstrap(
      index: 1,
      invite: bootstrap.invite
    )

    let first = try creator.consumeForwardedJoinKnock(
      candidateHandle: candidateHandle,
      payload: candidate.joinKnock
    )
    let replay = try creator.consumeForwardedJoinKnock(
      candidateHandle: candidateHandle,
      payload: candidate.joinKnock
    )

    #expect(replay == first)
    #expect(creator.snapshot.pendingApprovals.count == 1)
  }

  @Test("a candidate handle cannot be reused for a different pending knock")
  func pendingKnockConflict() throws {
    let fixture = try ClientRoomFixture()
    let bootstrap = try fixture.creatorBootstrap(
      policy: .open(askBeforeJoining: true)
    )
    var creator = bootstrap.room
    let candidateHandle = fixture.candidateHandles[1]
    let first = try fixture.candidateBootstrap(index: 1, invite: bootstrap.invite)
    let conflicting = try fixture.candidateBootstrap(
      index: 1,
      invite: bootstrap.invite
    )

    _ = try creator.consumeForwardedJoinKnock(
      candidateHandle: candidateHandle,
      payload: first.joinKnock
    )
    #expect(
      throws: ClipLiveShareServerRoomV4ClientRoomError.conflictingCandidateRequest
    ) {
      try creator.consumeForwardedJoinKnock(
        candidateHandle: candidateHandle,
        payload: conflicting.joinKnock
      )
    }
    #expect(creator.snapshot.pendingApprovals.count == 1)
  }

  @Test("auto admission replay returns the exact issued command")
  func automaticAdmissionReplay() throws {
    let fixture = try ClientRoomFixture()
    let bootstrap = try fixture.creatorBootstrap()
    var creator = bootstrap.room
    let candidateHandle = fixture.candidateHandles[1]
    let candidate = try fixture.candidateBootstrap(
      index: 1,
      invite: bootstrap.invite
    )

    let first = try creator.consumeForwardedJoinKnock(
      candidateHandle: candidateHandle,
      payload: candidate.joinKnock
    )
    let replay = try creator.consumeForwardedJoinKnock(
      candidateHandle: candidateHandle,
      payload: candidate.joinKnock
    )

    #expect(replay == first)
    guard case .admit(let firstCommand) = first,
      case .admit(let replayCommand) = replay
    else {
      Issue.record("Expected replayed automatic admission")
      return
    }
    #expect(replayCommand.descriptor == firstCommand.descriptor)

    let conflicting = try fixture.candidateBootstrap(
      index: 1,
      invite: bootstrap.invite
    )
    #expect(
      throws: ClipLiveShareServerRoomV4ClientRoomError.conflictingCandidateRequest
    ) {
      try creator.consumeForwardedJoinKnock(
        candidateHandle: candidateHandle,
        payload: conflicting.joinKnock
      )
    }
  }

  @Test("manual approval and denial remain retryable after ambiguous sends")
  func manualAdmissionRetries() throws {
    let fixture = try ClientRoomFixture()
    let bootstrap = try fixture.creatorBootstrap(
      policy: .open(askBeforeJoining: true)
    )
    var creator = bootstrap.room

    let approvedHandle = fixture.candidateHandles[1]
    let approvedCandidate = try fixture.candidateBootstrap(
      index: 1,
      invite: bootstrap.invite
    )
    _ = try creator.consumeForwardedJoinKnock(
      candidateHandle: approvedHandle,
      payload: approvedCandidate.joinKnock
    )
    let approval = try creator.approve(candidateHandle: approvedHandle)
    let approvalRetry = try creator.approve(candidateHandle: approvedHandle)
    #expect(approvalRetry == approval)
    #expect(
      try creator.consumeForwardedJoinKnock(
        candidateHandle: approvedHandle,
        payload: approvedCandidate.joinKnock
      ) == .admit(approval)
    )

    let deniedHandle = fixture.candidateHandles[2]
    let deniedCandidate = try fixture.candidateBootstrap(
      index: 2,
      invite: bootstrap.invite
    )
    _ = try creator.consumeForwardedJoinKnock(
      candidateHandle: deniedHandle,
      payload: deniedCandidate.joinKnock
    )
    #expect(try creator.deny(candidateHandle: deniedHandle) == deniedHandle)
    #expect(try creator.deny(candidateHandle: deniedHandle) == deniedHandle)
    #expect(throws: ClipLiveShareServerRoomV4ClientRoomError.admissionDenied) {
      try creator.consumeForwardedJoinKnock(
        candidateHandle: deniedHandle,
        payload: deniedCandidate.joinKnock
      )
    }
    #expect(creator.snapshot.pendingApprovals.isEmpty)
  }

  @Test("server candidate rollback forgets pending and issued admission state")
  func candidateRollback() throws {
    let fixture = try ClientRoomFixture()
    let pendingBootstrap = try fixture.creatorBootstrap(
      policy: .open(askBeforeJoining: true)
    )
    var pendingCreator = pendingBootstrap.room
    let firstHandle = fixture.candidateHandles[1]
    let retryHandle = fixture.candidateHandles[2]
    let candidate = try fixture.candidateBootstrap(
      index: 1,
      invite: pendingBootstrap.invite
    )

    _ = try pendingCreator.consumeForwardedJoinKnock(
      candidateHandle: firstHandle,
      payload: candidate.joinKnock
    )
    #expect(try pendingCreator.forgetCandidate(candidateHandle: firstHandle))
    #expect(!(try pendingCreator.forgetCandidate(candidateHandle: firstHandle)))
    #expect(pendingCreator.snapshot.pendingApprovals.isEmpty)
    guard case .pendingApproval(let retriedPending) =
      try pendingCreator.consumeForwardedJoinKnock(
        candidateHandle: retryHandle,
        payload: candidate.joinKnock
      )
    else {
      Issue.record("Expected the identity to retry after pending rollback")
      return
    }
    #expect(retriedPending.candidateHandle == retryHandle)

    let automaticBootstrap = try fixture.creatorBootstrap()
    var automaticCreator = automaticBootstrap.room
    let automaticCandidate = try fixture.candidateBootstrap(
      index: 1,
      invite: automaticBootstrap.invite
    )
    guard case .admit(let originalAdmission) =
      try automaticCreator.consumeForwardedJoinKnock(
        candidateHandle: firstHandle,
        payload: automaticCandidate.joinKnock
      )
    else {
      Issue.record("Expected automatic admission")
      return
    }
    #expect(originalAdmission.memberHandle == firstHandle.admittedMemberHandle)
    #expect(try automaticCreator.forgetCandidate(candidateHandle: firstHandle))
    #expect(!(try automaticCreator.forgetCandidate(candidateHandle: firstHandle)))
    guard case .admit(let retriedAdmission) =
      try automaticCreator.consumeForwardedJoinKnock(
        candidateHandle: retryHandle,
        payload: automaticCandidate.joinKnock
      )
    else {
      Issue.record("Expected the identity to retry after admission rollback")
      return
    }
    #expect(retriedAdmission.memberHandle == retryHandle.admittedMemberHandle)
  }

  @Test("only explicit invite rotation invalidates old knocks")
  func explicitInviteRotation() throws {
    let fixture = try ClientRoomFixture()
    let bootstrap = try fixture.creatorBootstrap()
    var creator = bootstrap.room
    let oldCandidate = try fixture.candidateBootstrap(index: 1, invite: bootstrap.invite)
    let stable = try #require(creator.currentInvite).url
    try creator.setAdmissionPolicy(.open(askBeforeJoining: true))
    #expect(try creator.currentInvite?.url == stable)

    let rotated = try creator.rotateInvite(
      to: try .init(bytes: Data(repeating: 0xD4, count: 32))
    )
    #expect(try rotated.url != stable)
    #expect(throws: (any Error).self) {
      try creator.consumeForwardedJoinKnock(
        candidateHandle: fixture.candidateHandles[1],
        payload: oldCandidate.joinKnock
      )
    }
    let newCandidate = try fixture.candidateBootstrap(index: 1, invite: rotated)
    #expect(
      try creator.consumeForwardedJoinKnock(
        candidateHandle: fixture.candidateHandles[1],
        payload: newCandidate.joinKnock
      )
        == .pendingApproval(
          .init(
            candidateHandle: fixture.candidateHandles[1],
            participantID: fixture.participants[1].descriptor.participantID,
            displayName: fixture.participants[1].descriptor.displayName,
            deviceName: fixture.participants[1].descriptor.deviceName
          )
        )
    )
  }

  @Test("a knock from another encrypted invitation is rejected")
  func wrongInvite() throws {
    let first = try ClientRoomFixture(roomByte: 0x31)
    let second = try ClientRoomFixture(roomByte: 0x32)
    var creator = try first.creatorBootstrap().room
    let foreign = try second.candidateBootstrap(
      index: 1,
      invite: second.creatorBootstrap().invite
    )
    #expect(throws: (any Error).self) {
      try creator.consumeForwardedJoinKnock(
        candidateHandle: first.candidateHandles[1],
        payload: foreign.joinKnock
      )
    }
  }

  @Test("malicious descriptor swaps and duplicate identities fail transactionally")
  func maliciousRoster() throws {
    var mesh = try ClientMeshHarness()
    try mesh.admitParticipant(1)
    let a = mesh.fixture.handles[0]
    let b = mesh.fixture.handles[1]
    let c = mesh.fixture.handles[2]
    let before = try mesh.room(a).snapshot

    let swapped = try ClipLiveShareServerRoomV4RosterSnapshot(
      revision: .init(rawValue: mesh.revision + 1),
      creatorHandle: a,
      members: [
        mesh.rosterMember(a), mesh.rosterMember(b),
        .init(handle: c, descriptor: try #require(mesh.records[b]), connected: true),
      ]
    )
    #expect(throws: (any Error).self) {
      var room = try mesh.room(a)
      _ = try room.consumeRosterSnapshot(swapped)
    }
    #expect(try mesh.room(a).snapshot == before)

    let duplicateIdentityDescriptor = try ClipLiveShareServerRoomV4MemberDescriptor(
      participantID: ClientRoomFixture.participantID(0xE3),
      identity: mesh.fixture.participants[1].signer.publicKey,
      pairSignalingPublicKey: mesh.fixture.participants[2].pairIdentity.publicKey,
      displayName: "Duplicate identity",
      deviceName: "Test Mac"
    )
    let record = ClipLiveShareServerRoomV4AdmissionRecord(
      roomID: mesh.fixture.roomID,
      sessionID: mesh.fixture.sessionID,
      memberHandle: c,
      descriptor: duplicateIdentityDescriptor
    )
    let signed = try ClipLiveShareServerRoomV4SignedAdmissionRecord(
      signing: record,
      with: mesh.fixture.participants[0].signer
    )
    let opaque = try mesh.fixture.roomCipher.sealAdmissionRecord(signed)
    let duplicate = try ClipLiveShareServerRoomV4RosterSnapshot(
      revision: .init(rawValue: mesh.revision + 1),
      creatorHandle: a,
      members: [
        mesh.rosterMember(a), mesh.rosterMember(b),
        .init(handle: c, descriptor: opaque, connected: true),
      ]
    )
    #expect(throws: ClipLiveShareServerRoomV4ClientRoomError.duplicatePersistentIdentity) {
      var room = try mesh.room(a)
      _ = try room.consumeRosterSnapshot(duplicate)
    }
    #expect(try mesh.room(a).snapshot == before)

    let duplicateParticipantDescriptor = try ClipLiveShareServerRoomV4MemberDescriptor(
      participantID: mesh.fixture.participants[1].descriptor.participantID,
      identity: mesh.fixture.participants[3].signer.publicKey,
      pairSignalingPublicKey: mesh.fixture.participants[3].pairIdentity.publicKey,
      displayName: "Duplicate participant",
      deviceName: "Test Mac"
    )
    let participantRecord = ClipLiveShareServerRoomV4AdmissionRecord(
      roomID: mesh.fixture.roomID,
      sessionID: mesh.fixture.sessionID,
      memberHandle: c,
      descriptor: duplicateParticipantDescriptor
    )
    let participantOpaque = try mesh.fixture.roomCipher.sealAdmissionRecord(
      .init(signing: participantRecord, with: mesh.fixture.participants[0].signer)
    )
    let duplicateParticipant = try ClipLiveShareServerRoomV4RosterSnapshot(
      revision: .init(rawValue: mesh.revision + 1),
      creatorHandle: a,
      members: [
        mesh.rosterMember(a), mesh.rosterMember(b),
        .init(handle: c, descriptor: participantOpaque, connected: true),
      ]
    )
    #expect(throws: ClipLiveShareServerRoomV4ClientRoomError.duplicateParticipantID) {
      var room = try mesh.room(a)
      _ = try room.consumeRosterSnapshot(duplicateParticipant)
    }
    #expect(try mesh.room(a).snapshot == before)
  }

  @Test("reconnect handle and capability export and import without description leakage")
  func reconnectCredential() throws {
    var mesh = try ClientMeshHarness()
    try mesh.admitParticipant(1)
    let b = mesh.fixture.handles[1]
    let original = try mesh.room(b)
    let credential = try original.exportReconnectCredential()
    #expect(!credential.description.contains(credential.reconnectCapability.rawValue))
    #expect(!credential.description.contains(credential.memberHandle.rawValue))

    var restored = try ClipLiveShareServerRoomV4ClientRoom.makeReconnectingParticipant(
      invite: mesh.fixture.invite,
      credential: credential,
      pairKeyIdentity: mesh.fixture.participants[1].pairIdentity,
      localDescriptor: mesh.fixture.participants[1].descriptor,
      signer: mesh.fixture.participants[1].signer
    )
    _ = try restored.consumeRosterSnapshot(mesh.roster())
    #expect(restored.localHandle == b)
    #expect(restored.snapshot.members.count == 2)
    #expect(restored.snapshot.pairs.count == 1)

    let foreign = ClipLiveShareServerRoomV4ReconnectCredential(
      roomID: try ClientRoomFixture.fixedRoomID(0xEE),
      sessionID: mesh.fixture.sessionID,
      memberHandle: b,
      reconnectCapability: credential.reconnectCapability
    )
    #expect(throws: ClipLiveShareServerRoomV4ClientRoomError.invalidReconnectCredential) {
      try ClipLiveShareServerRoomV4ClientRoom.makeReconnectingParticipant(
        invite: mesh.fixture.invite,
        credential: foreign,
        pairKeyIdentity: mesh.fixture.participants[1].pairIdentity,
        localDescriptor: mesh.fixture.participants[1].descriptor,
        signer: mesh.fixture.participants[1].signer
      )
    }
  }
}

private struct ClientRoomParticipant: Sendable {
  let signer: ClipLiveShareSoftwareIdentitySigner
  let pairIdentity: ClipLiveShareServerRoomV4KeyAgreementIdentity
  let descriptor: ClipLiveShareServerRoomV4MemberDescriptor

  init(index: Int, roomByte: UInt8) throws {
    signer = ClipLiveShareSoftwareIdentitySigner()
    pairIdentity = .init()
    descriptor = try .init(
      participantID: ClientRoomFixture.participantID(roomByte &+ UInt8(index) &+ 1),
      identity: signer.publicKey,
      pairSignalingPublicKey: pairIdentity.publicKey,
      displayName: "Participant \(index + 1)",
      deviceName: "Test Mac \(index + 1)"
    )
  }
}

private struct ClientRoomFixture: Sendable {
  let roomID: ClipLiveShareServerRoomV4RoomID
  let sessionID: ClipLiveShareSessionID
  let ownerCapability: ClipLiveShareServerRoomV4OwnerCapability
  let roomSecret: ClipLiveShareServerRoomV4RoomAgreementSecret
  let admissionCapability: ClipLiveShareServerRoomV4AdmissionCapability
  let handles: [ClipLiveShareServerRoomV4MemberHandle]
  let candidateHandles: [ClipLiveShareServerRoomV4CandidateHandle]
  let participants: [ClientRoomParticipant]

  init(roomByte: UInt8 = 0x41) throws {
    roomID = try Self.fixedRoomID(roomByte)
    sessionID = try .init(rawValue: "client-state-session-\(roomByte)")
    ownerCapability = try .init(bytes: Data(repeating: roomByte &+ 1, count: 32))
    roomSecret = try .init(bytes: Data(repeating: roomByte &+ 2, count: 32))
    admissionCapability = try .init(bytes: Data(repeating: roomByte &+ 3, count: 32))
    handles = try (0..<4).map {
      try .init(bytes: Data(repeating: roomByte &+ UInt8($0) &+ 10, count: 16))
    }
    candidateHandles = try handles.map { try .init(bytes: $0.bytes) }
    participants = try (0..<4).map { try .init(index: $0, roomByte: roomByte) }
  }

  var invite: ClipLiveShareServerRoomV4Invite {
    try! ClipLiveShareServerRoomV4Invite(
      serviceEndpoint: URL(string: "https://rooms.example.test")!,
      roomID: roomID,
      sessionID: sessionID,
      creatorIdentity: participants[0].signer.publicKey,
      roomAgreementSecret: roomSecret,
      admissionCapability: admissionCapability
    )
  }

  var roomCipher: ClipLiveShareServerRoomV4RoomCipher {
    .init(roomID: roomID, sessionID: sessionID, roomAgreementSecret: roomSecret)
  }

  func creatorBootstrap(
    policy: ClipLiveShareServerRoomV4AdmissionPolicy = .open()
  ) throws -> ClipLiveShareServerRoomV4CreatorBootstrap {
    try ClipLiveShareServerRoomV4ClientRoom.makeCreator(
      serviceEndpoint: URL(string: "https://rooms.example.test")!,
      roomID: roomID,
      memberHandle: handles[0],
      sessionID: sessionID,
      ownerCapability: ownerCapability,
      roomAgreementSecret: roomSecret,
      admissionCapability: admissionCapability,
      pairKeyIdentity: participants[0].pairIdentity,
      localDescriptor: participants[0].descriptor,
      signer: participants[0].signer,
      admissionPolicy: policy
    )
  }

  func candidateBootstrap(
    index: Int,
    invite: ClipLiveShareServerRoomV4Invite,
    word: String? = nil,
    requiresCreatorApproval: Bool = false
  ) throws -> ClipLiveShareServerRoomV4CandidateBootstrap {
    try ClipLiveShareServerRoomV4ClientRoom.makeCandidate(
      invite: invite,
      pairKeyIdentity: participants[index].pairIdentity,
      localDescriptor: participants[index].descriptor,
      signer: participants[index].signer,
      accessWord: word,
      requiresCreatorApproval: requiresCreatorApproval
    )
  }

  static func fixedRoomID(
    _ byte: UInt8
  ) throws -> ClipLiveShareServerRoomV4RoomID {
    try .init(bytes: Data(repeating: byte, count: 32))
  }

  static func participantID(_ byte: UInt8) -> ClipLiveShareNativeV3ParticipantID {
    try! .init(bytes: Data(repeating: byte, count: 16))
  }
}

private struct ClientMeshHarness {
  let fixture: ClientRoomFixture
  var rooms: [ClipLiveShareServerRoomV4MemberHandle: ClipLiveShareServerRoomV4ClientRoom]
  var records:
    [ClipLiveShareServerRoomV4MemberHandle:
      ClipLiveShareServerRoomV4OpaqueAdmissionRecord]
  var revision: UInt64

  init() throws {
    fixture = try ClientRoomFixture()
    let bootstrap = try fixture.creatorBootstrap()
    rooms = [fixture.handles[0]: bootstrap.room]
    records = [fixture.handles[0]: bootstrap.createRequest.descriptor]
    revision = 1
    let initial = try ClipLiveShareServerRoomV4RosterSnapshot(
      revision: .init(rawValue: revision),
      creatorHandle: fixture.handles[0],
      members: [
        .init(
          handle: fixture.handles[0],
          descriptor: bootstrap.createRequest.descriptor,
          connected: true
        )
      ]
    )
    var creator = bootstrap.room
    _ = try creator.consumeMemberAdmitted(
      memberHandle: fixture.handles[0],
      reconnectCapability: nil,
      roster: initial
    )
    rooms[fixture.handles[0]] = creator
  }

  mutating func admitParticipant(_ index: Int) throws {
    let creatorHandle = fixture.handles[0]
    let handle = fixture.handles[index]
    let candidateHandle = fixture.candidateHandles[index]
    var creator = try room(creatorHandle)
    let invite = try #require(creator.currentInvite)
    let candidate = try fixture.candidateBootstrap(index: index, invite: invite)
    let decision = try creator.consumeForwardedJoinKnock(
      candidateHandle: candidateHandle,
      payload: candidate.joinKnock
    )
    guard case .admit(let command) = decision else {
      throw ClipLiveShareServerRoomV4ClientRoomError.admissionDenied
    }
    rooms[creatorHandle] = creator
    records[handle] = command.descriptor
    revision += 1
    let snapshot = try roster()

    for existingHandle in Array(rooms.keys) {
      var existing = try room(existingHandle)
      _ = try existing.consumeRosterSnapshot(snapshot)
      rooms[existingHandle] = existing
    }
    var admitted = candidate.room
    _ = try admitted.consumeMemberAdmitted(
      memberHandle: handle,
      reconnectCapability: .random(),
      roster: snapshot
    )
    rooms[handle] = admitted
  }

  mutating func removeParticipant(
    _ handle: ClipLiveShareServerRoomV4MemberHandle
  ) throws {
    records.removeValue(forKey: handle)
    rooms.removeValue(forKey: handle)
    revision += 1
    let snapshot = try roster()
    for retainedHandle in Array(rooms.keys) {
      var retained = try room(retainedHandle)
      _ = try retained.consumeRosterSnapshot(snapshot)
      rooms[retainedHandle] = retained
    }
  }

  func roster() throws -> ClipLiveShareServerRoomV4RosterSnapshot {
    try .init(
      revision: .init(rawValue: revision),
      creatorHandle: fixture.handles[0],
      members: records.keys.map(rosterMember)
    )
  }

  func rosterMember(
    _ handle: ClipLiveShareServerRoomV4MemberHandle
  ) -> ClipLiveShareServerRoomV4RosterMember {
    .init(handle: handle, descriptor: records[handle]!, connected: true)
  }

  func room(
    _ handle: ClipLiveShareServerRoomV4MemberHandle
  ) throws -> ClipLiveShareServerRoomV4ClientRoom {
    try #require(rooms[handle])
  }

  mutating func seal(
    from: ClipLiveShareServerRoomV4MemberHandle,
    to: ClipLiveShareServerRoomV4MemberHandle,
    payload: ClipLiveShareServerRoomV4PairSignalPayload
  ) throws -> ClipLiveShareServerRoomV4PairSignalEnvelope {
    var sender = try room(from)
    let envelope = try sender.sealPairSignal(to: to, payload: payload)
    rooms[from] = sender
    return envelope
  }

  mutating func open(
    at recipient: ClipLiveShareServerRoomV4MemberHandle,
    envelope: ClipLiveShareServerRoomV4PairSignalEnvelope
  ) throws -> ClipLiveShareServerRoomV4PairSignalPayload {
    var receiver = try room(recipient)
    let payload = try receiver.openPairSignal(envelope)
    rooms[recipient] = receiver
    return payload
  }
}
