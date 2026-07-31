import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Clip Live Share native v3 room lifecycle")
struct ClipLiveShareNativeV3RoomLifecycleTests {
  @Test("admission and removal commit only after local pair links are ready")
  func transactionalMembershipAdmissionAndRemoval() throws {
    let fixture = try LifecycleFixture(participantCount: 2)
    var leader = try fixture.coordinator(for: 0)
    let originalMembership = leader.signedMembership
    let admitted = fixture.participants[2]

    let admission = try leader.makeMembershipSnapshot(
      participants: Array(fixture.participants.prefix(3)),
      at: fixture.time(10)
    )
    #expect(throws: ClipLiveShareNativeV3RoomLifecycleError.self) {
      try leader.commitMembershipSnapshot(admission, at: fixture.time(10))
    }
    #expect(leader.signedMembership == originalMembership)
    #expect(leader.phase == .active)

    leader.markPeerLinkReady(with: admitted.participantID)
    let admissionEvents = try leader.commitMembershipSnapshot(
      admission,
      at: fixture.time(10)
    )
    #expect(leader.participantIDs.count == 3)
    #expect(
      membershipEvent(in: admissionEvents)?.admitted
        == [admitted.participantID]
    )

    let removedID = fixture.participants[1].participantID
    let removal = try leader.makeMembershipSnapshot(
      participants: [fixture.participants[0], admitted],
      at: fixture.time(20)
    )
    let removalEvents = try leader.commitMembershipSnapshot(
      removal,
      at: fixture.time(20)
    )
    #expect(membershipEvent(in: removalEvents)?.removed == [removedID])
    #expect(removalEvents.contains(.cleanupParticipant(removedID)))
    #expect(!leader.establishedPeerParticipantIDs.contains(removedID))
  }

  @Test("ordinary participant leaves only after authoritative removal commits")
  func ordinaryParticipantLeave() throws {
    let fixture = try LifecycleFixture(participantCount: 3)
    var leader = try fixture.coordinator(for: 0)
    var participant = try fixture.coordinator(for: 2)
    let request = try participant.makeParticipantLeaveRequest(
      at: fixture.time(10)
    )
    let removal = try leader.makeMembershipSnapshot(
      accepting: request,
      at: fixture.time(10)
    )

    #expect(participant.phase == .active)
    #expect(participant.participantIDs.count == 3)
    let leaderEvents = try leader.commitMembershipSnapshot(
      removal,
      at: fixture.time(10)
    )
    let participantEvents = try participant.commitMembershipSnapshot(
      removal,
      at: fixture.time(10)
    )

    #expect(
      membershipEvent(in: leaderEvents)?.removed
        == [participant.localParticipantID]
    )
    #expect(
      leaderEvents.contains(
        .cleanupParticipant(participant.localParticipantID)
      )
    )
    #expect(participantEvents.contains(.localParticipantRemoved))
    #expect(participant.phase == .ended)
  }

  @Test("three participants gracefully transfer authority and remove the departing leader")
  func gracefulThreeParticipantTransfer() throws {
    let fixture = try LifecycleFixture(participantCount: 3)
    var leader = try fixture.coordinator(for: 0)
    var successor = try fixture.coordinator(for: 1)
    var third = try fixture.coordinator(for: 2)

    let transferEvents = try leader.beginGracefulLeaderLeave(
      at: fixture.time(10)
    )
    let request = try #require(transferRequest(in: transferEvents))
    #expect(leader.phase == .electing)
    #expect(
      request.request.successorParticipantID
        == fixture.participants[1].participantID
    )

    let successorEvents = try successor.receiveLeadershipTransferRequest(
      request,
      at: fixture.time(10)
    )
    _ = try third.receiveLeadershipTransferRequest(
      request,
      at: fixture.time(10)
    )
    let proposal = try #require(leadershipProposal(in: successorEvents))
    let successorVote = try #require(leadershipVote(in: successorEvents))
    #expect(
      successorVote.vote.voterParticipantID
        == fixture.participants[1].participantID
    )

    let leaderVote = try #require(
      leadershipVote(
        in: leader.receiveLeadershipProposal(
          proposal,
          at: fixture.time(10)
        )
      )
    )
    let thirdVote = try #require(
      leadershipVote(
        in: third.receiveLeadershipProposal(
          proposal,
          at: fixture.time(10)
        )
      )
    )
    let certificate = try #require(
      leadershipCertificate(
        in: successor.receiveLeadershipVote(
          leaderVote,
          at: fixture.time(10)
        )
      )
    )
    // A delayed valid third vote is harmless before the transition and can
    // only produce the same proposal certificate with a larger quorum.
    let expandedCertificate = try #require(
      leadershipCertificate(
        in: successor.receiveLeadershipVote(
          thirdVote,
          at: fixture.time(10)
        )
      )
    )
    #expect(expandedCertificate.signedProposal == certificate.signedProposal)

    let successorMembership = try successor.makeSuccessorMembership(
      for: expandedCertificate,
      retainingParticipantIDs: [
        fixture.participants[1].participantID,
        fixture.participants[2].participantID,
      ],
      at: fixture.time(20)
    )
    let leaderCommit = try leader.commitLeadershipTransition(
      certificate: expandedCertificate,
      successorMembership: successorMembership,
      at: fixture.time(20)
    )
    let successorCommit = try successor.commitLeadershipTransition(
      certificate: expandedCertificate,
      successorMembership: successorMembership,
      at: fixture.time(20)
    )
    let thirdCommit = try third.commitLeadershipTransition(
      certificate: expandedCertificate,
      successorMembership: successorMembership,
      at: fixture.time(20)
    )

    #expect(leader.phase == .ended)
    #expect(leaderCommit.contains(.localParticipantRemoved))
    #expect(successor.phase == .active)
    #expect(successor.currentTerm.rawValue == 2)
    #expect(successor.isLocalLeader)
    #expect(successorCommit.contains(.newInviteRequired))
    #expect(third.phase == .active)
    #expect(!thirdCommit.contains(.newInviteRequired))
    #expect(
      successor.participantIDs
        == Set([
          fixture.participants[1].participantID,
          fixture.participants[2].participantID,
        ])
    )
  }

  @Test("graceful transfer skips a disconnected lower-ID successor")
  func gracefulTransferChoosesSmallestReadySuccessor() throws {
    let fixture = try LifecycleFixture(participantCount: 3)
    var leader = try fixture.coordinator(for: 0)
    var readySuccessor = try fixture.coordinator(for: 2)
    let disconnectedID = fixture.participants[1].participantID
    let readyID = fixture.participants[2].participantID
    leader.markPeerLinkUnavailable(with: disconnectedID)

    let transferEvents = try leader.beginGracefulLeaderLeave(
      at: fixture.time(10)
    )
    let request = try #require(transferRequest(in: transferEvents))
    #expect(request.request.successorParticipantID == readyID)

    let successorEvents = try readySuccessor.receiveLeadershipTransferRequest(
      request,
      at: fixture.time(10)
    )
    let proposal = try #require(leadershipProposal(in: successorEvents))
    let leaderVote = try #require(
      leadershipVote(
        in: leader.receiveLeadershipProposal(
          proposal,
          at: fixture.time(10)
        )
      )
    )
    let certificate = try #require(
      leadershipCertificate(
        in: readySuccessor.receiveLeadershipVote(
          leaderVote,
          at: fixture.time(10)
        )
      )
    )
    let successorMembership = try readySuccessor.makeSuccessorMembership(
      for: certificate,
      retainingParticipantIDs: [readyID],
      at: fixture.time(20)
    )
    _ = try readySuccessor.commitLeadershipTransition(
      certificate: certificate,
      successorMembership: successorMembership,
      at: fixture.time(20)
    )

    #expect(readySuccessor.isLocalLeader)
    #expect(readySuccessor.participantIDs == [readyID])
  }

  @Test("three participant leader crash elects from the surviving strict majority")
  func threeParticipantRecoveryElection() throws {
    let fixture = try LifecycleFixture(participantCount: 3)
    var successor = try fixture.coordinator(for: 1)
    var third = try fixture.coordinator(for: 2)
    let survivors: Set = [
      fixture.participants[1].participantID,
      fixture.participants[2].participantID,
    ]

    let successorEvents = try successor.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: survivors,
      at: fixture.time(10)
    )
    _ = try third.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: survivors,
      at: fixture.time(10)
    )
    let proposal = try #require(leadershipProposal(in: successorEvents))
    let thirdVote = try #require(
      leadershipVote(
        in: third.receiveLeadershipProposal(
          proposal,
          at: fixture.time(10)
        )
      )
    )
    let certificate = try #require(
      leadershipCertificate(
        in: successor.receiveLeadershipVote(
          thirdVote,
          at: fixture.time(10)
        )
      )
    )
    let membership = try successor.makeSuccessorMembership(
      for: certificate,
      retainingParticipantIDs: survivors,
      at: fixture.time(20)
    )
    let successorEventsAfterCommit = try successor.commitLeadershipTransition(
      certificate: certificate,
      successorMembership: membership,
      at: fixture.time(20)
    )
    _ = try third.commitLeadershipTransition(
      certificate: certificate,
      successorMembership: membership,
      at: fixture.time(20)
    )

    #expect(successor.isLocalLeader)
    #expect(successor.currentTerm.rawValue == 2)
    #expect(successorEventsAfterCommit.contains(.newInviteRequired))
    #expect(third.currentLeaderParticipantID == successor.localParticipantID)
    #expect(throws: ClipLiveShareNativeV3RoomLifecycleError.self) {
      try successor.receiveLeadershipVote(
        thirdVote,
        at: fixture.time(30)
      )
    }
  }

  @Test("authority provenance carries ordinary admission through later succession and reconnect")
  func admissionThenSuccessionAuthorityChain() throws {
    let fixture = try LifecycleFixture(participantCount: 2)
    var leader = try fixture.coordinator(for: 0)
    let admittedParticipant = fixture.participants[2]
    leader.markPeerLinkReady(with: admittedParticipant.participantID)
    let admittedMembership = try leader.makeMembershipSnapshot(
      participants: Array(fixture.participants.prefix(3)),
      at: fixture.time(10)
    )
    _ = try leader.commitMembershipSnapshot(
      admittedMembership,
      at: fixture.time(10)
    )
    #expect(
      leader.authorityChain.currentMembership == admittedMembership
    )

    let admittedAuthority = leader.authorityChain
    var successor = try ClipLiveShareNativeV3RoomLifecycleCoordinator(
      localParticipantID: fixture.participants[1].participantID,
      localSigner: fixture.signers[1],
      authorityChain: admittedAuthority,
      expectedSessionID: fixture.sessionID,
      expectedFoundingCreatorIdentity: fixture.participants[0].identity,
      admissionPolicy: .productDefault,
      establishedPeerParticipantIDs: [
        fixture.participants[0].participantID,
        fixture.participants[2].participantID,
      ],
      at: fixture.time(10)
    )
    var third = try ClipLiveShareNativeV3RoomLifecycleCoordinator(
      localParticipantID: admittedParticipant.participantID,
      localSigner: fixture.signers[2],
      authorityChain: admittedAuthority,
      expectedSessionID: fixture.sessionID,
      expectedFoundingCreatorIdentity: fixture.participants[0].identity,
      admissionPolicy: .productDefault,
      establishedPeerParticipantIDs: [
        fixture.participants[0].participantID,
        fixture.participants[1].participantID,
      ],
      at: fixture.time(10)
    )
    let survivors: Set = [
      fixture.participants[1].participantID,
      admittedParticipant.participantID,
    ]
    let proposalEvents = try successor.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: survivors,
      at: fixture.time(20)
    )
    _ = try third.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: survivors,
      at: fixture.time(20)
    )
    let proposal = try #require(leadershipProposal(in: proposalEvents))
    let vote = try #require(
      leadershipVote(
        in: third.receiveLeadershipProposal(
          proposal,
          at: fixture.time(20)
        )
      )
    )
    let certificate = try #require(
      leadershipCertificate(
        in: successor.receiveLeadershipVote(
          vote,
          at: fixture.time(20)
        )
      )
    )
    let bridge = try successor.makeSuccessorMembership(
      for: certificate,
      retainingParticipantIDs: survivors,
      at: fixture.time(30)
    )
    _ = try successor.commitLeadershipTransition(
      certificate: certificate,
      successorMembership: bridge,
      at: fixture.time(30)
    )
    #expect(
      successor.authorityChain.checkpoints.last?.predecessorMembership
        == admittedMembership
    )
    try successor.authorityChain.verify(
      expectedSessionID: fixture.sessionID,
      expectedFoundingCreatorIdentity: fixture.participants[0].identity,
      at: fixture.time(30)
    )

    let reconnected = try ClipLiveShareNativeV3RoomLifecycleCoordinator(
      localParticipantID: admittedParticipant.participantID,
      localSigner: fixture.signers[2],
      authorityChain: successor.authorityChain,
      expectedSessionID: fixture.sessionID,
      expectedFoundingCreatorIdentity: fixture.participants[0].identity,
      admissionPolicy: .productDefault,
      establishedPeerParticipantIDs: [
        fixture.participants[1].participantID
      ],
      at: fixture.time(30)
    )
    #expect(reconnected.currentTerm.rawValue == 2)
    #expect(
      reconnected.currentLeaderParticipantID
        == fixture.participants[1].participantID
    )
  }

  @Test("two participant crash is fail-closed because one survivor is not a quorum")
  func twoParticipantCrashLocksRoom() throws {
    let fixture = try LifecycleFixture(participantCount: 2)
    var survivor = try fixture.coordinator(for: 1)
    let events = try survivor.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: [fixture.participants[1].participantID],
      at: fixture.time(10)
    )
    #expect(survivor.phase == .leaderlessLocked)
    #expect(events == [.phaseChanged(.leaderlessLocked)])
    #expect(survivor.pendingCandidateParticipantID == nil)

    let retry = try survivor.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: [fixture.participants[1].participantID],
      at: fixture.time(20)
    )
    #expect(retry == [.phaseChanged(.leaderlessLocked)])

    let recovery = try survivor.currentLeaderBecameReachable()
    #expect(recovery == [.phaseChanged(.active)])
    #expect(survivor.phase == .active)
    #expect(
      survivor.establishedPeerParticipantIDs
        .contains(fixture.participants[0].participantID)
    )
  }

  @Test("a current leader locks mutation without quorum and restores only the same epoch")
  func currentLeaderQuorumLockIsEpochBound() throws {
    let fixture = try LifecycleFixture(participantCount: 4)
    var leader = try fixture.coordinator(for: 0)
    let term = leader.currentTerm
    let digest = leader.signedMembership.snapshot.digest

    let locked = try leader.localLeaderLostQuorum()
    #expect(locked == [.phaseChanged(.leaderlessLocked)])
    #expect(leader.phase == .leaderlessLocked)
    #expect(throws: ClipLiveShareNativeV3RoomLifecycleError.self) {
      try leader.makeMembershipSnapshot(
        participants: leader.signedMembership.snapshot.participants,
        at: fixture.time(10)
      )
    }
    #expect(throws: ClipLiveShareNativeV3RoomLifecycleError.self) {
      try leader.localLeaderQuorumRestored(
        expectedTerm: term,
        expectedMembershipDigest:
          ClipLiveShareNativeDigest(
            bytes: Data(repeating: 0xFF, count: 32)
          )
      )
    }
    #expect(leader.phase == .leaderlessLocked)

    let restored = try leader.localLeaderQuorumRestored(
      expectedTerm: term,
      expectedMembershipDigest: digest
    )
    #expect(restored == [.phaseChanged(.active)])
    #expect(leader.phase == .active)
  }

  @Test("full authority reconciliation catches ordinary updates and rejects forks transactionally")
  func fullAuthorityOrdinaryCatchUpAndForkRejection() throws {
    let fixture = try LifecycleFixture(participantCount: 2)
    var leader = try fixture.coordinator(for: 0)
    var stale = try fixture.coordinator(for: 1)
    let admitted = fixture.participants[2]
    leader.markPeerLinkReady(with: admitted.participantID)
    let admission = try leader.makeMembershipSnapshot(
      participants: Array(fixture.participants.prefix(3)),
      at: fixture.time(10)
    )
    _ = try leader.commitMembershipSnapshot(
      admission,
      at: fixture.time(10)
    )
    let newerAuthority = leader.authorityChain
    let staleAuthority = stale.authorityChain

    #expect(
      throws: ClipLiveShareNativeV3RoomLifecycleError.self
    ) {
      try stale.reconcileAuthorityChain(
        newerAuthority,
        from: fixture.participants[0].participantID,
        at: fixture.time(10)
      )
    }
    #expect(stale.authorityChain == staleAuthority)
    stale.markPeerLinkReady(with: admitted.participantID)
    let adopted = try stale.reconcileAuthorityChain(
      newerAuthority,
      from: fixture.participants[0].participantID,
      at: fixture.time(10)
    )
    guard case let .adopted(events) = adopted else {
      Issue.record("Expected the newer ordinary authority to be adopted")
      return
    }
    #expect(stale.signedMembership == admission)
    #expect(
      membershipEvent(in: events)?.admitted
        == [admitted.participantID]
    )
    #expect(
      try leader.reconcileAuthorityChain(
        staleAuthority,
        from: fixture.participants[1].participantID,
        at: fixture.time(10)
      ) == .stale
    )
    #expect(
      try leader.reconcileAuthorityChain(
        newerAuthority,
        from: fixture.participants[1].participantID,
        at: fixture.time(10)
      ) == .identical
    )

    let forkFixture = try LifecycleFixture(participantCount: 3)
    var forkLeader = try forkFixture.coordinator(for: 0)
    let branchA = try forkLeader.makeMembershipSnapshot(
      participants: [
        forkFixture.participants[0],
        forkFixture.participants[1],
      ],
      at: forkFixture.time(20)
    )
    let branchB = try forkLeader.makeMembershipSnapshot(
      participants: [
        forkFixture.participants[0],
        forkFixture.participants[2],
      ],
      at: forkFixture.time(20)
    )
    _ = try forkLeader.commitMembershipSnapshot(
      branchA,
      at: forkFixture.time(20)
    )
    let committedBranch = forkLeader.authorityChain
    let conflictingBranch = try ClipLiveShareNativeV3RoomAuthorityChain(
      foundingCreatorParticipantID:
        forkFixture.participants[0].participantID,
      foundingCreatorIdentity:
        forkFixture.participants[0].identity,
      genesisMembership: forkFixture.membership,
      checkpoints: [],
      latestMembership: branchB
    )
    #expect(throws: ClipLiveShareNativeV3Error.self) {
      try forkLeader.reconcileAuthorityChain(
        conflictingBranch,
        from: forkFixture.participants[0].participantID,
        at: forkFixture.time(20)
      )
    }
    #expect(forkLeader.authorityChain == committedBranch)
  }

  @Test("one full authority value catches a retained participant across two missed terms")
  func fullAuthorityMultiTermCatchUp() throws {
    let fixture = try LifecycleFixture(participantCount: 4)
    var firstLeader = try fixture.coordinator(for: 0)
    var secondLeader = try fixture.coordinator(for: 1)
    var thirdLeader = try fixture.coordinator(for: 2)
    var stale = try fixture.coordinator(for: 3)

    let firstTransfer = try #require(
      transferRequest(
        in: firstLeader.beginGracefulLeaderLeave(
          at: fixture.time(10)
        )
      )
    )
    let secondEvents = try secondLeader
      .receiveLeadershipTransferRequest(
        firstTransfer,
        at: fixture.time(10)
      )
    _ = try thirdLeader.receiveLeadershipTransferRequest(
      firstTransfer,
      at: fixture.time(10)
    )
    let firstProposal = try #require(
      leadershipProposal(in: secondEvents)
    )
    let firstLeaderVote = try #require(
      leadershipVote(
        in: firstLeader.receiveLeadershipProposal(
          firstProposal,
          at: fixture.time(10)
        )
      )
    )
    let thirdLeaderVote = try #require(
      leadershipVote(
        in: thirdLeader.receiveLeadershipProposal(
          firstProposal,
          at: fixture.time(10)
        )
      )
    )
    _ = try secondLeader.receiveLeadershipVote(
      firstLeaderVote,
      at: fixture.time(10)
    )
    let firstCertificate = try #require(
      leadershipCertificate(
        in: secondLeader.receiveLeadershipVote(
          thirdLeaderVote,
          at: fixture.time(10)
        )
      )
    )
    let firstSuccessorMembership =
      try secondLeader.makeSuccessorMembership(
        for: firstCertificate,
        retainingParticipantIDs: [
          fixture.participants[1].participantID,
          fixture.participants[2].participantID,
          fixture.participants[3].participantID,
        ],
        at: fixture.time(20)
      )
    _ = try secondLeader.commitLeadershipTransition(
      certificate: firstCertificate,
      successorMembership: firstSuccessorMembership,
      at: fixture.time(20)
    )
    _ = try thirdLeader.commitLeadershipTransition(
      certificate: firstCertificate,
      successorMembership: firstSuccessorMembership,
      at: fixture.time(20)
    )
    var currentFourth =
      try ClipLiveShareNativeV3RoomLifecycleCoordinator(
        localParticipantID:
          fixture.participants[3].participantID,
        localSigner: fixture.signers[3],
        authorityChain: secondLeader.authorityChain,
        expectedSessionID: fixture.sessionID,
        expectedFoundingCreatorIdentity:
          fixture.participants[0].identity,
        admissionPolicy: .protocolMaximum,
        establishedPeerParticipantIDs: [
          fixture.participants[1].participantID,
          fixture.participants[2].participantID,
        ],
        at: fixture.time(20)
      )

    let secondTransfer = try #require(
      transferRequest(
        in: secondLeader.beginGracefulLeaderLeave(
          at: fixture.time(30)
        )
      )
    )
    let thirdEvents = try thirdLeader
      .receiveLeadershipTransferRequest(
        secondTransfer,
        at: fixture.time(30)
      )
    _ = try currentFourth.receiveLeadershipTransferRequest(
      secondTransfer,
      at: fixture.time(30)
    )
    let secondProposal = try #require(
      leadershipProposal(in: thirdEvents)
    )
    let secondLeaderVote = try #require(
      leadershipVote(
        in: secondLeader.receiveLeadershipProposal(
          secondProposal,
          at: fixture.time(30)
        )
      )
    )
    let secondCertificate = try #require(
      leadershipCertificate(
        in: thirdLeader.receiveLeadershipVote(
          secondLeaderVote,
          at: fixture.time(30)
        )
      )
    )
    let secondSuccessorMembership =
      try thirdLeader.makeSuccessorMembership(
        for: secondCertificate,
        retainingParticipantIDs: [
          fixture.participants[2].participantID,
          fixture.participants[3].participantID,
        ],
        at: fixture.time(40)
      )
    _ = try thirdLeader.commitLeadershipTransition(
      certificate: secondCertificate,
      successorMembership: secondSuccessorMembership,
      at: fixture.time(40)
    )

    let result = try stale.reconcileAuthorityChain(
      thirdLeader.authorityChain,
      from: fixture.participants[2].participantID,
      at: fixture.time(40)
    )
    guard case .adopted = result else {
      Issue.record("Expected multi-term authority adoption")
      return
    }
    #expect(stale.currentTerm.rawValue == 3)
    #expect(
      stale.currentLeaderParticipantID
        == fixture.participants[2].participantID
    )
    #expect(stale.authorityChain.checkpoints.count == 2)
    #expect(
      stale.participantIDs
        == Set([
          fixture.participants[2].participantID,
          fixture.participants[3].participantID,
        ])
    )
  }

  @Test("four participant partition locks without quorum then elects after reconnect")
  func fourParticipantPartitionAndReconnect() throws {
    let fixture = try LifecycleFixture(participantCount: 4)
    var second = try fixture.coordinator(for: 1)
    var third = try fixture.coordinator(for: 2)
    var fourth = try fixture.coordinator(for: 3)
    let minority: Set = [
      fixture.participants[1].participantID,
      fixture.participants[2].participantID,
    ]
    _ = try second.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: minority,
      at: fixture.time(10)
    )
    #expect(second.phase == .leaderlessLocked)

    let majority = minority.union([fixture.participants[3].participantID])
    let secondEvents = try second.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: majority,
      at: fixture.time(20)
    )
    _ = try third.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: majority,
      at: fixture.time(20)
    )
    _ = try fourth.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: majority,
      at: fixture.time(20)
    )
    let proposal = try #require(leadershipProposal(in: secondEvents))
    let thirdVote = try #require(
      leadershipVote(
        in: third.receiveLeadershipProposal(
          proposal,
          at: fixture.time(20)
        )
      )
    )
    let fourthVote = try #require(
      leadershipVote(
        in: fourth.receiveLeadershipProposal(
          proposal,
          at: fixture.time(20)
        )
      )
    )
    #expect(
      leadershipCertificate(
        in: try second.receiveLeadershipVote(
          thirdVote,
          at: fixture.time(20)
        )
      ) == nil
    )
    let certificate = try #require(
      leadershipCertificate(
        in: second.receiveLeadershipVote(
          fourthVote,
          at: fixture.time(20)
        )
      )
    )
    let successorMembership = try second.makeSuccessorMembership(
      for: certificate,
      retainingParticipantIDs: majority,
      at: fixture.time(30)
    )
    _ = try second.commitLeadershipTransition(
      certificate: certificate,
      successorMembership: successorMembership,
      at: fixture.time(30)
    )
    _ = try third.commitLeadershipTransition(
      certificate: certificate,
      successorMembership: successorMembership,
      at: fixture.time(30)
    )
    _ = try fourth.commitLeadershipTransition(
      certificate: certificate,
      successorMembership: successorMembership,
      at: fixture.time(30)
    )
    #expect(second.currentTerm.rawValue == 2)
    #expect(second.participantIDs == majority)
    #expect(third.phase == .active)
    #expect(fourth.phase == .active)
  }

  @Test("conflicting candidate stale term and delayed messages are rejected transactionally")
  func conflictDelayAndReplayMatrix() throws {
    let fixture = try LifecycleFixture(participantCount: 3)
    var successor = try fixture.coordinator(for: 1)
    var third = try fixture.coordinator(for: 2)
    let survivors: Set = [
      fixture.participants[1].participantID,
      fixture.participants[2].participantID,
    ]
    let successorEvents = try successor.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: survivors,
      at: fixture.time(10)
    )
    _ = try third.beginUnexpectedLeaderLoss(
      reachableParticipantIDs: survivors,
      at: fixture.time(10)
    )
    let correctProposal = try #require(leadershipProposal(in: successorEvents))

    let conflicting = try fixture.signedProposal(
      candidateIndex: 2,
      reason: .recoveryElection,
      membership: successor.signedMembership,
      term: 2,
      at: fixture.time(10)
    )
    #expect(throws: ClipLiveShareNativeV3Error.self) {
      try third.receiveLeadershipProposal(
        conflicting,
        at: fixture.time(10)
      )
    }
    #expect(third.pendingCandidateParticipantID == fixture.participants[1].participantID)

    let vote = try #require(
      leadershipVote(
        in: third.receiveLeadershipProposal(
          correctProposal,
          at: fixture.time(10)
        )
      )
    )
    #expect(throws: ClipLiveShareNativeV3Error.expired) {
      try successor.receiveLeadershipVote(
        vote,
        at: fixture.time(71)
      )
    }
    #expect(successor.phase == .electing)
    let certificate = try #require(
      leadershipCertificate(
        in: successor.receiveLeadershipVote(
          vote,
          at: fixture.time(10)
        )
      )
    )
    let membership = try successor.makeSuccessorMembership(
      for: certificate,
      retainingParticipantIDs: survivors,
      at: fixture.time(20)
    )
    _ = try successor.commitLeadershipTransition(
      certificate: certificate,
      successorMembership: membership,
      at: fixture.time(20)
    )
    let stableMembership = successor.signedMembership
    #expect(throws: ClipLiveShareNativeV3Error.self) {
      try successor.commitLeadershipTransition(
        certificate: certificate,
        successorMembership: membership,
        at: fixture.time(20)
      )
    }
    #expect(successor.signedMembership == stableMembership)
    #expect(successor.currentTerm.rawValue == 2)
  }

  @Test("signed End Room is terminal and cleans every remote participant")
  func signedTerminalRoomEnd() throws {
    let fixture = try LifecycleFixture(participantCount: 3)
    var leader = try fixture.coordinator(for: 0)
    var second = try fixture.coordinator(for: 1)
    let leaderEvents = try leader.endRoomForEveryone(at: fixture.time(10))
    let termination = try #require(roomTermination(in: leaderEvents))
    #expect(leader.phase == .ended)
    #expect(
      cleanupIDs(in: leaderEvents)
        == Set([
          fixture.participants[1].participantID,
          fixture.participants[2].participantID,
        ])
    )

    let secondEvents = try second.receiveRoomTermination(
      termination,
      at: fixture.time(10)
    )
    #expect(second.phase == .ended)
    #expect(secondEvents.contains(.roomEnded(.endedByLeader)))
    #expect(throws: ClipLiveShareNativeV3RoomLifecycleError.roomEnded) {
      try second.beginUnexpectedLeaderLoss(
        reachableParticipantIDs: [second.localParticipantID],
        at: fixture.time(20)
      )
    }
    #expect(throws: ClipLiveShareNativeV3RoomLifecycleError.roomEnded) {
      try second.receiveRoomTermination(
        termination,
        at: fixture.time(20)
      )
    }
  }

  @Test(
    "established rooms remain authoritative after admission credentials expire"
  )
  func establishedRoomLongSessionControls() throws {
    // Ordinary nonleader leave after both the 120-second snapshot and
    // 180-second fixture credential windows have elapsed.
    do {
      let fixture = try LifecycleFixture(participantCount: 3)
      var leader = try fixture.coordinator(for: 0)
      var leaving = try fixture.coordinator(for: 2)
      let request = try leaving.makeParticipantLeaveRequest(
        at: fixture.time(240)
      )
      let membership = try leader.makeMembershipSnapshot(
        accepting: request,
        at: fixture.time(240)
      )
      _ = try leader.commitMembershipSnapshot(
        membership,
        at: fixture.time(240)
      )
      let events = try leaving.commitMembershipSnapshot(
        membership,
        at: fixture.time(240)
      )
      #expect(events.contains(.localParticipantRemoved))
    }

    // Graceful transfer after expiry, followed by a fresh End Room message
    // after the successor membership itself has also expired.
    do {
      let fixture = try LifecycleFixture(participantCount: 3)
      var leader = try fixture.coordinator(for: 0)
      var successor = try fixture.coordinator(for: 1)
      var third = try fixture.coordinator(for: 2)

      let request = try #require(
        transferRequest(
          in: leader.beginGracefulLeaderLeave(at: fixture.time(240))
        )
      )
      let successorEvents = try successor.receiveLeadershipTransferRequest(
        request,
        at: fixture.time(240)
      )
      _ = try third.receiveLeadershipTransferRequest(
        request,
        at: fixture.time(240)
      )
      let proposal = try #require(
        leadershipProposal(in: successorEvents)
      )
      let leaderVote = try #require(
        leadershipVote(
          in: leader.receiveLeadershipProposal(
            proposal,
            at: fixture.time(240)
          )
        )
      )
      let thirdVote = try #require(
        leadershipVote(
          in: third.receiveLeadershipProposal(
            proposal,
            at: fixture.time(240)
          )
        )
      )
      _ = try successor.receiveLeadershipVote(
        leaderVote,
        at: fixture.time(240)
      )
      let certificate = try #require(
        leadershipCertificate(
          in: successor.receiveLeadershipVote(
            thirdVote,
            at: fixture.time(240)
          )
        )
      )
      let successorMembership = try successor.makeSuccessorMembership(
        for: certificate,
        retainingParticipantIDs: [
          fixture.participants[1].participantID,
          fixture.participants[2].participantID,
        ],
        at: fixture.time(250)
      )
      _ = try successor.commitLeadershipTransition(
        certificate: certificate,
        successorMembership: successorMembership,
        at: fixture.time(250)
      )
      _ = try third.commitLeadershipTransition(
        certificate: certificate,
        successorMembership: successorMembership,
        at: fixture.time(250)
      )

      let endEvents = try successor.endRoomForEveryone(
        at: fixture.time(500)
      )
      let termination = try #require(roomTermination(in: endEvents))
      let thirdEvents = try third.receiveRoomTermination(
        termination,
        at: fixture.time(500)
      )
      #expect(thirdEvents.contains(.roomEnded(.endedByLeader)))
    }

    // Unexpected leader loss after expiry still permits the surviving strict
    // majority to certify a successor from the accepted membership.
    do {
      let fixture = try LifecycleFixture(participantCount: 3)
      var successor = try fixture.coordinator(for: 1)
      var third = try fixture.coordinator(for: 2)
      let survivors: Set = [
        fixture.participants[1].participantID,
        fixture.participants[2].participantID,
      ]
      let successorEvents = try successor.beginUnexpectedLeaderLoss(
        reachableParticipantIDs: survivors,
        at: fixture.time(240)
      )
      _ = try third.beginUnexpectedLeaderLoss(
        reachableParticipantIDs: survivors,
        at: fixture.time(240)
      )
      let proposal = try #require(
        leadershipProposal(in: successorEvents)
      )
      let vote = try #require(
        leadershipVote(
          in: third.receiveLeadershipProposal(
            proposal,
            at: fixture.time(240)
          )
        )
      )
      let certificate = try #require(
        leadershipCertificate(
          in: successor.receiveLeadershipVote(
            vote,
            at: fixture.time(240)
          )
        )
      )
      let membership = try successor.makeSuccessorMembership(
        for: certificate,
        retainingParticipantIDs: survivors,
        at: fixture.time(250)
      )
      _ = try successor.commitLeadershipTransition(
        certificate: certificate,
        successorMembership: membership,
        at: fixture.time(250)
      )
      #expect(successor.isLocalLeader)
    }
  }
}

private struct LifecycleFixture {
  let signers: [ClipLiveShareSoftwareIdentitySigner]
  let participants: [ClipLiveShareNativeV3Participant]
  let sessionID = try! ClipLiveShareSessionID(
    rawValue: "native-v3-lifecycle"
  )
  let origin = try! ClipLiveShareNativeTimestamp(
    millisecondsSince1970: 1_850_000_000_000
  )
  let membership: ClipLiveShareSignedNativeV3MembershipSnapshot
  let authority: ClipLiveShareNativeV3RoomAuthorityChain
  let admissionPolicy: ClipLiveShareNativeV3AdmissionPolicy

  init(participantCount: Int) throws {
    signers = try (1...4).map {
      try ClipLiveShareSoftwareIdentitySigner(
        rawRepresentation: Data(repeating: UInt8($0), count: 32)
      )
    }
    participants = try signers.enumerated().map { index, signer in
      try ClipLiveShareNativeV3Participant(
        participantID: ClipLiveShareNativeV3ParticipantID(
          bytes: Data(repeating: UInt8((index + 1) * 0x10), count: 16)
        ),
        identity: signer.publicKey,
        displayName: "Participant \(index + 1)",
        capabilities: .current
      )
    }
    admissionPolicy =
      participantCount == 4 ? .protocolMaximum : .productDefault
    membership = try Self.makeMembership(
      sessionID: sessionID,
      participants: Array(participants.prefix(participantCount)),
      leader: participants[0],
      leaderSigner: signers[0],
      revision: 1,
      at: origin,
      maximumParticipants: admissionPolicy.maximumParticipants
    )
    authority = try ClipLiveShareNativeV3RoomAuthorityChain(
      foundingCreatorParticipantID: participants[0].participantID,
      foundingCreatorIdentity: participants[0].identity,
      genesisMembership: membership,
      checkpoints: []
    )
  }

  func time(_ seconds: Int64) -> ClipLiveShareNativeTimestamp {
    try! origin.adding(milliseconds: seconds * 1_000)
  }

  func coordinator(
    for index: Int
  ) throws -> ClipLiveShareNativeV3RoomLifecycleCoordinator {
    let currentIDs = membership.snapshot.participantIDs
    return try ClipLiveShareNativeV3RoomLifecycleCoordinator(
      localParticipantID: participants[index].participantID,
      localSigner: signers[index],
      authorityChain: authority,
      expectedSessionID: sessionID,
      expectedFoundingCreatorIdentity: participants[0].identity,
      admissionPolicy: admissionPolicy,
      establishedPeerParticipantIDs:
        currentIDs.subtracting([participants[index].participantID]),
      at: time(1)
    )
  }

  func signedProposal(
    candidateIndex: Int,
    reason: ClipLiveShareNativeV3LeadershipTransitionReason,
    membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
    term: UInt64,
    at now: ClipLiveShareNativeTimestamp
  ) throws -> ClipLiveShareSignedNativeV3LeadershipProposal {
    let proposal = try ClipLiveShareNativeV3LeadershipProposal(
      sessionID: sessionID,
      term: ClipLiveShareNativeV3LeadershipTerm(rawValue: term),
      reason: reason,
      previousLeaderParticipantID: participants[0].participantID,
      candidateParticipantID: participants[candidateIndex].participantID,
      candidateIdentity: participants[candidateIndex].identity,
      lastCommittedMembershipRevision: membership.snapshot.membershipRevision,
      lastCommittedMembershipDigest: membership.snapshot.digest,
      electorate: membership.snapshot.participantIDs,
      issuedAt: now,
      expiresAt: now.adding(milliseconds: 60_000)
    )
    return try ClipLiveShareSignedNativeV3LeadershipProposal(
      signing: proposal,
      with: signers[candidateIndex]
    )
  }

  private static func makeMembership(
    sessionID: ClipLiveShareSessionID,
    participants: [ClipLiveShareNativeV3Participant],
    leader: ClipLiveShareNativeV3Participant,
    leaderSigner: ClipLiveShareSoftwareIdentitySigner,
    revision: UInt64,
    at now: ClipLiveShareNativeTimestamp,
    maximumParticipants: Int
  ) throws -> ClipLiveShareSignedNativeV3MembershipSnapshot {
    let membershipRevision = try ClipLiveShareNativeV3MembershipRevision(
      rawValue: revision
    )
    let credentials = try participants.map { participant in
      let credential = try ClipLiveShareNativeV3MembershipCredential(
        sessionID: sessionID,
        leaderParticipantID: leader.participantID,
        leaderIdentity: leader.identity,
        participant: participant,
        membershipRevision: membershipRevision,
        issuedAt: now,
        expiresAt: now.adding(milliseconds: 180_000)
      )
      return try ClipLiveShareSignedNativeV3MembershipCredential(
        signing: credential,
        with: leaderSigner
      )
    }
    let snapshot = try ClipLiveShareNativeV3MembershipSnapshot(
      sessionID: sessionID,
      leaderParticipantID: leader.participantID,
      leaderIdentity: leader.identity,
      membershipRevision: membershipRevision,
      credentials: credentials,
      issuedAt: now,
      expiresAt: now.adding(milliseconds: 120_000),
      maximumParticipants: maximumParticipants
    )
    return try ClipLiveShareSignedNativeV3MembershipSnapshot(
      signing: snapshot,
      with: leaderSigner
    )
  }
}

private func membershipEvent(
  in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> (
  snapshot: ClipLiveShareSignedNativeV3MembershipSnapshot,
  admitted: [ClipLiveShareNativeV3ParticipantID],
  removed: [ClipLiveShareNativeV3ParticipantID]
)? {
  for event in events {
    if case let .membershipCommitted(snapshot, admitted, removed) = event {
      return (snapshot, admitted, removed)
    }
  }
  return nil
}

private func transferRequest(
  in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareSignedNativeV3LeadershipTransferRequest? {
  for event in events {
    if case let .broadcastTransferRequest(request) = event { return request }
  }
  return nil
}

private func leadershipProposal(
  in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareSignedNativeV3LeadershipProposal? {
  for event in events {
    if case let .broadcastLeadershipProposal(proposal) = event {
      return proposal
    }
  }
  return nil
}

private func leadershipVote(
  in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareSignedNativeV3LeadershipVote? {
  for event in events {
    if case let .broadcastLeadershipVote(vote) = event { return vote }
  }
  return nil
}

private func leadershipCertificate(
  in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareNativeV3LeadershipCertificate? {
  for event in events {
    if case let .leadershipCertificateReady(certificate) = event {
      return certificate
    }
  }
  return nil
}

private func roomTermination(
  in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> ClipLiveShareSignedNativeV3RoomTermination? {
  for event in events {
    if case let .broadcastRoomTermination(termination) = event {
      return termination
    }
  }
  return nil
}

private func cleanupIDs(
  in events: [ClipLiveShareNativeV3RoomLifecycleEvent]
) -> Set<ClipLiveShareNativeV3ParticipantID> {
  Set(events.compactMap { event in
    if case let .cleanupParticipant(participantID) = event {
      return participantID
    }
    return nil
  })
}
