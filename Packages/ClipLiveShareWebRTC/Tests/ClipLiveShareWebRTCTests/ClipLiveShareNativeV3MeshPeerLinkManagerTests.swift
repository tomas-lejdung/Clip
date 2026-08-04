import ClipLiveShare
import Foundation
import Testing

@testable import ClipLiveShareWebRTC

@Suite("Native v3 mesh peer-link manager")
struct ClipLiveShareNativeV3MeshPeerLinkManagerTests {
  @Test("initial negotiation-needed is ignored until the pair is ready")
  func initialNegotiationNeededIsSuppressed() async throws {
    let remote = try meshParticipant(0x10)
    let local = try meshParticipant(0x20)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    let recorder = MeshManagerEventRecorder()
    let stream = await manager.events()
    let recording = Task {
      for await event in stream {
        await recorder.append(event)
      }
    }

    try await manager.reconcileParticipants([local, remote])
    let transport = try #require(await factory.transport(for: remote))
    await transport.emit(.negotiationNeeded)
    try await Task.sleep(for: .milliseconds(30))
    #expect(
      !(await recorder.events()).contains {
        if case .negotiationNeeded = $0 { true } else { false }
      }
    )

    await transport.emit(.connectionStateChanged(.connected))
    await transport.emit(.controlChannelStateChanged(.open))
    try await meshEventually {
      await manager.snapshot().links.first?.isReady == true
    }
    await transport.emit(.negotiationNeeded)
    try await meshEventually {
      await recorder.events().contains {
        if case .negotiationNeeded = $0 { true } else { false }
      }
    }

    recording.cancel()
    await manager.close()
  }

  @Test("complete membership creates one canonical local edge per peer")
  func createsCanonicalIncidentEdges() async throws {
    let local = try meshParticipant(0x20)
    let lower = try meshParticipant(0x10)
    let upperA = try meshParticipant(0x30)
    let upperB = try meshParticipant(0x40)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )

    try await manager.reconcileParticipants([upperB, local, lower, upperA])

    let configurations = await factory.configurations()
    #expect(configurations.count == 3)
    #expect(Set(configurations.map(\.key)).count == 3)
    #expect(configurations.map(\.key) == configurations.map(\.key).sorted())
    #expect(
      configurations.allSatisfy {
        $0.key.contains(local)
          && $0.remoteParticipantID != local
          && $0.controlChannel.label
            == ClipLiveShareNativeV3.controlDataChannelLabel
          && $0.controlChannel.isOrdered
          && $0.controlChannel.maximumRetransmits == nil
          && $0.controlChannel.maximumPacketLifetimeMilliseconds == nil
          && $0.mediaLayout.reservedVideoSlotCount == 4
          && $0.mediaLayout.reservedOutboundVideoSlotCount == 4
          && $0.mediaLayout.reservedInboundVideoSlotCount == 4
          && $0.mediaLayout.participantAudioTrackCount == 1
          && $0.mediaLayout.outboundParticipantAudioTrackCount == 1
          && $0.mediaLayout.inboundParticipantAudioTrackCount == 1
          && $0.mediaLayout.videoDirection == .sendReceive
          && $0.mediaLayout.participantAudioDirection == .sendReceive
      }
    )
    #expect(
      configurations.first(where: { $0.remoteParticipantID == lower })?.role
        == .answerer
    )
    #expect(
      configurations.first(where: { $0.remoteParticipantID == upperA })?.role
        == .offerer
    )
    #expect(
      configurations.first(where: { $0.remoteParticipantID == upperB })?.role
        == .offerer
    )

    let snapshot = await manager.snapshot()
    #expect(snapshot.participantIDs == [local, lower, upperA, upperB])
    #expect(snapshot.links.count == 3)
    #expect(!snapshot.isLocallyComplete)
    await manager.close()
  }

  @Test("reconciliation reuses retained links and closes only obsolete links")
  func reconcilesIncrementally() async throws {
    let local = try meshParticipant(0x10)
    let peerA = try meshParticipant(0x20)
    let peerB = try meshParticipant(0x30)
    let peerC = try meshParticipant(0x40)
    let closeRecorder = MeshCloseRecorder()
    let factory = MeshFakeTransportFactory(closeRecorder: closeRecorder)
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )

    try await manager.reconcileParticipants([local, peerA, peerB])
    let peerATransport = try #require(await factory.transport(for: peerA))
    let peerBTransport = try #require(await factory.transport(for: peerB))
    try await manager.reconcileParticipants([local, peerA, peerB])
    #expect(await factory.makeCount() == 2)
    #expect(await peerATransport.startCount() == 1)
    #expect(await peerBTransport.startCount() == 1)

    try await manager.reconcileParticipants([local, peerA, peerC])
    #expect(await peerATransport.closeCount() == 0)
    #expect(await peerBTransport.closeCount() == 1)
    #expect(await factory.makeCount() == 3)
    #expect(
      Set((await manager.snapshot()).links.map(\.remoteParticipantID))
        == [peerA, peerC]
    )
    await manager.close()
  }

  @Test("disconnect quarantines one pair without rewriting membership")
  func disconnectPreservesMembershipAndAllowsReconciliation() async throws {
    let local = try meshParticipant(0x10)
    let peerA = try meshParticipant(0x20)
    let peerB = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    let recorder = MeshManagerEventRecorder()
    let stream = await manager.events()
    let recording = Task {
      for await event in stream {
        await recorder.append(event)
      }
    }

    try await manager.reconcileParticipants([local, peerA, peerB])
    let firstPeerATransport = try #require(
      await factory.latestTransport(for: peerA)
    )

    try await manager.disconnectParticipant(peerA)

    let disconnectedSnapshot = await manager.snapshot()
    #expect(disconnectedSnapshot.participantIDs == [local, peerA, peerB])
    #expect(
      Set(disconnectedSnapshot.links.map(\.remoteParticipantID)) == [peerB]
    )
    #expect(!disconnectedSnapshot.isLocallyComplete)
    #expect(await firstPeerATransport.closeCount() == 1)
    try await meshEventually {
      await recorder.events().contains {
        guard
          case let .linkRemoved(_, remoteParticipantID) = $0
        else { return false }
        return remoteParticipantID == peerA
      }
    }

    try await manager.reconcileParticipants([local, peerA, peerB])

    let replacement = try #require(await factory.latestTransport(for: peerA))
    #expect(replacement !== firstPeerATransport)
    #expect(await replacement.startCount() == 1)
    #expect(await factory.makeCount() == 3)
    #expect(
      Set((await manager.snapshot()).links.map(\.remoteParticipantID))
        == [peerA, peerB]
    )

    await manager.close()
    recording.cancel()
  }

  @Test("recreated peer retains receiver audio preferences before track arrival")
  func recreatedPeerRetainsReceiverAudioPreferences() async throws {
    let local = try meshParticipant(0x10)
    let customizedPeer = try meshParticipant(0x20)
    let unrelatedPeer = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )

    try await manager.reconcileParticipants([
      local,
      customizedPeer,
      unrelatedPeer,
    ])
    let firstCustomizedTransport = try #require(
      await factory.latestTransport(for: customizedPeer)
    )
    let unrelatedTransport = try #require(
      await factory.latestTransport(for: unrelatedPeer)
    )

    try await manager.setRemoteParticipantAudioPlaybackEnabled(
      false,
      for: customizedPeer
    )
    try await manager.setRemoteParticipantAudioVolume(
      0.35,
      for: customizedPeer
    )
    #expect(
      await firstCustomizedTransport.receiverAudioOperations()
        == ["start", "playback:false", "volume:0.35"]
    )
    #expect(await unrelatedTransport.receiverAudioOperations() == ["start"])

    try await manager.disconnectParticipant(customizedPeer)
    try await manager.reconcileParticipants([
      local,
      customizedPeer,
      unrelatedPeer,
    ])

    let replacement = try #require(
      await factory.latestTransport(for: customizedPeer)
    )
    #expect(replacement !== firstCustomizedTransport)
    #expect(
      await replacement.receiverAudioOperations()
        == ["playback:false", "volume:0.35", "start"]
    )
    #expect(await replacement.playbackEnabledHistory() == [false])
    #expect(await replacement.volumeHistory() == [0.35])
    #expect(await unrelatedTransport.receiverAudioOperations() == ["start"])

    await replacement.emit(
      .remoteParticipantAudioAvailable(trackID: "replacement-audio")
    )
    try await meshEventually {
      await manager.snapshot().links.first {
        $0.remoteParticipantID == customizedPeer
      }?.remoteParticipantAudioTrackID == "replacement-audio"
    }
    #expect(await replacement.playbackEnabledHistory() == [false])
    #expect(await replacement.volumeHistory() == [0.35])

    await manager.close()
  }

  @Test("negotiation and control traffic remain targeted to one pair")
  func targetedNegotiationAndControl() async throws {
    let local = try meshParticipant(0x10)
    let peerA = try meshParticipant(0x20)
    let peerB = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory,
      maximumControlMessageBytes: 16
    )
    let recorder = MeshManagerEventRecorder()
    let stream = await manager.events()
    let recording = Task {
      for await event in stream {
        await recorder.append(event)
      }
    }

    try await manager.reconcileParticipants([local, peerA, peerB])
    let peerATransport = try #require(await factory.transport(for: peerA))
    let peerBTransport = try #require(await factory.transport(for: peerB))
    let offer = WebRTCSessionDescription(kind: .offer, sdp: "offer-a")
    await peerATransport.emit(.localNegotiation(.sessionDescription(offer)))

    try await meshEventually {
      await recorder.events().contains {
        guard case let .targetedNegotiation(targeted) = $0 else { return false }
        return targeted.targetParticipantID == peerA
          && targeted.payload == .sessionDescription(offer)
      }
    }

    try await manager.requestNegotiation(with: peerB)
    #expect(await peerATransport.negotiationRequestCount() == 0)
    #expect(await peerBTransport.negotiationRequestCount() == 1)

    let candidate = WebRTCICECandidate(
      candidate: "candidate:1 1 udp 1 127.0.0.1 9999 typ host",
      sdpMid: "0",
      sdpMLineIndex: 0
    )
    let peerAKey = try ClipLiveShareNativeV3PeerLinkKey(local, peerA)
    try await manager.applyRemoteNegotiation(
      .init(
        peerLinkKey: peerAKey,
        targetParticipantID: local,
        payload: .iceCandidate(candidate)
      ),
      from: peerA
    )
    #expect(await peerATransport.remoteCandidates() == [candidate])
    #expect(await peerBTransport.remoteCandidates().isEmpty)

    await peerATransport.emit(.controlChannelStateChanged(.open))
    try await meshEventually {
      (await manager.snapshot()).links.first {
        $0.remoteParticipantID == peerA
      }?.controlChannelState == .open
    }
    let outbound = Data([0x01, 0x02])
    try await manager.sendControlMessage(outbound, to: peerA)
    #expect(await peerATransport.sentControlMessages() == [outbound])
    #expect(await peerBTransport.sentControlMessages().isEmpty)

    let inbound = Data([0x09])
    await peerBTransport.emit(.controlMessageReceived(inbound))
    try await meshEventually {
      await recorder.events().contains(
        .controlMessageReceived(from: peerB, data: inbound)
      )
    }

    do {
      try await manager.sendControlMessage(Data(repeating: 0, count: 17), to: peerA)
      Issue.record("Expected an oversized control message to fail")
    } catch {
      #expect(
        error as? ClipLiveShareNativeV3MeshPeerLinkManagerError
          == .controlMessageTooLarge(maximumBytes: 16, actualBytes: 17)
      )
    }

    await manager.close()
    recording.cancel()
  }

  @Test("a bad target cannot mutate another pair")
  func rejectsMisdirectedNegotiation() async throws {
    let local = try meshParticipant(0x10)
    let peerA = try meshParticipant(0x20)
    let peerB = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    try await manager.reconcileParticipants([local, peerA, peerB])
    let peerATransport = try #require(await factory.transport(for: peerA))
    let peerAKey = try ClipLiveShareNativeV3PeerLinkKey(local, peerA)
    let answer = WebRTCSessionDescription(kind: .answer, sdp: "answer")

    do {
      try await manager.applyRemoteNegotiation(
        .init(
          peerLinkKey: peerAKey,
          targetParticipantID: peerB,
          payload: .sessionDescription(answer)
        ),
        from: peerA
      )
      Issue.record("Expected a negotiation with the wrong target to fail")
    } catch {
      #expect(
        error as? ClipLiveShareNativeV3MeshPeerLinkManagerError
          == .invalidPeerLink(peerAKey)
      )
    }
    #expect(await peerATransport.remoteDescriptions().isEmpty)
    await manager.close()
  }

  @Test("reconnect attempts are isolated per peer and reset on connection")
  func reconnectIsolation() async throws {
    let local = try meshParticipant(0x10)
    let peerA = try meshParticipant(0x20)
    let peerB = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let sleeper = MeshImmediateSleeper()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory,
      reconnectPolicy: .init(delaysMilliseconds: [0, 0]),
      reconnectSleeper: sleeper
    )
    try await manager.reconcileParticipants([local, peerA, peerB])
    let peerATransport = try #require(await factory.transport(for: peerA))
    let peerBTransport = try #require(await factory.transport(for: peerB))
    await peerATransport.failNextRestart()

    await peerATransport.emit(.connectionStateChanged(.failed))
    try await meshEventually {
      await peerATransport.restartCount() == 2
    }
    #expect(await peerBTransport.restartCount() == 0)
    #expect(await sleeper.sleepCount() == 2)
    #expect(
      (await manager.snapshot()).links.first {
        $0.remoteParticipantID == peerA
      }?.reconnectAttempt == 2
    )

    await peerATransport.emit(.connectionStateChanged(.connected))
    try await meshEventually {
      (await manager.snapshot()).links.first {
        $0.remoteParticipantID == peerA
      }?.reconnectAttempt == 0
    }
    #expect(
      (await manager.snapshot()).links.first {
        $0.remoteParticipantID == peerB
      }?.connectionState == .new
    )
    await manager.close()
  }

  @Test("one ICE-server gathering failure is diagnostic, not a peer failure")
  func iceGatheringFailureIsDiagnostic() async throws {
    let local = try meshParticipant(0x10)
    let peer = try meshParticipant(0x20)
    let factory = MeshFakeTransportFactory()
    let sleeper = MeshImmediateSleeper()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory,
      reconnectPolicy: .init(delaysMilliseconds: [0]),
      reconnectSleeper: sleeper
    )
    let recorder = MeshManagerEventRecorder()
    let stream = await manager.events()
    let recording = Task {
      for await event in stream {
        await recorder.append(event)
      }
    }
    try await manager.reconcileParticipants([local, peer])
    let transport = try #require(await factory.transport(for: peer))
    await transport.emit(.connectionStateChanged(.connected))
    await transport.emit(.controlChannelStateChanged(.open))
    try await meshEventually {
      (await manager.snapshot()).links.first?.isReady == true
    }

    await transport.emit(.iceGatheringDiagnostic(
      code: 701,
      url: "stun:stun.l.google.com:19302",
      message: "STUN binding request timed out."
    ))
    try await Task.sleep(for: .milliseconds(30))

    #expect(await transport.restartCount() == 0)
    #expect(await sleeper.sleepCount() == 0)
    #expect((await manager.snapshot()).links.first?.isReady == true)
    #expect(!(await recorder.events()).contains { event in
      switch event {
      case .linkFailed, .reconnectScheduled, .reconnectExhausted:
        true
      default:
        false
      }
    })
    recording.cancel()
    await manager.close()
  }

  @Test("simultaneous pair failure lets only the canonical offerer restart")
  func reconnectKeepsDeterministicOfferer() async throws {
    let lower = try meshParticipant(0x10)
    let upper = try meshParticipant(0x20)
    let lowerFactory = MeshFakeTransportFactory()
    let upperFactory = MeshFakeTransportFactory()
    let lowerManager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: lower,
      transportFactory: lowerFactory,
      reconnectPolicy: .init(delaysMilliseconds: [0]),
      reconnectSleeper: MeshImmediateSleeper()
    )
    let upperManager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: upper,
      transportFactory: upperFactory,
      reconnectPolicy: .init(delaysMilliseconds: [0]),
      reconnectSleeper: MeshImmediateSleeper()
    )
    try await lowerManager.reconcileParticipants([lower, upper])
    try await upperManager.reconcileParticipants([lower, upper])
    let lowerTransport = try #require(
      await lowerFactory.transport(for: upper)
    )
    let upperTransport = try #require(
      await upperFactory.transport(for: lower)
    )
    #expect(lowerTransport.configuration.role == .offerer)
    #expect(upperTransport.configuration.role == .answerer)

    await lowerTransport.emit(.connectionStateChanged(.failed))
    await upperTransport.emit(.connectionStateChanged(.failed))
    try await meshEventually {
      await lowerTransport.restartCount() == 1
    }
    try await Task.sleep(for: .milliseconds(30))

    #expect(await upperTransport.restartCount() == 0)
    #expect(
      (await upperManager.snapshot()).links.first?.reconnectAttempt == 0
    )
    let key = try ClipLiveShareNativeV3PeerLinkKey(lower, upper)
    try await upperManager.applyRemoteNegotiation(
      .init(
        peerLinkKey: key,
        targetParticipantID: upper,
        payload: .sessionDescription(.init(kind: .offer, sdp: "restart"))
      ),
      from: lower
    )
    #expect(
      await upperTransport.remoteDescriptions()
        == [.init(kind: .offer, sdp: "restart")]
    )

    await lowerManager.close()
    await upperManager.close()
  }

  @Test("statistics stay attributed to their peer")
  func perPeerStatistics() async throws {
    let local = try meshParticipant(0x10)
    let peerA = try meshParticipant(0x20)
    let peerB = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    try await manager.reconcileParticipants([local, peerA, peerB])
    let peerATransport = try #require(await factory.transport(for: peerA))
    let peerBTransport = try #require(await factory.transport(for: peerB))
    await peerATransport.setStatistics(
      .init(
        capturedAt: Date(timeIntervalSince1970: 1),
        route: .direct,
        bytesSent: 100,
        bytesReceived: 200
      )
    )
    await peerBTransport.setStatistics(
      .init(
        capturedAt: Date(timeIntervalSince1970: 2),
        route: .relay,
        bytesSent: 300,
        bytesReceived: 400
      )
    )

    let statistics = try await manager.statistics()
    #expect(statistics.count == 2)
    #expect(statistics.map(\.peerLinkKey) == statistics.map(\.peerLinkKey).sorted())
    #expect(
      statistics.first { $0.remoteParticipantID == peerA }?.transport.bytesSent
        == 100
    )
    #expect(
      statistics.first { $0.remoteParticipantID == peerB }?.transport.route
        == .relay
    )

    await peerATransport.failNextStatistics()
    let healthyStatistics = try await manager.statistics()
    #expect(healthyStatistics.map(\.remoteParticipantID) == [peerB])
    await manager.close()
  }

  @Test("a slow peer statistics callback does not block another pair")
  func slowPeerStatisticsStayPairIsolated() async throws {
    let local = try meshParticipant(0x10)
    let slowPeer = try meshParticipant(0x20)
    let healthyPeer = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    try await manager.reconcileParticipants([local, slowPeer, healthyPeer])
    let slowTransport = try #require(
      await factory.transport(for: slowPeer)
    )
    let healthyTransport = try #require(
      await factory.transport(for: healthyPeer)
    )
    await slowTransport.blockStatistics()

    let polling = Task {
      try await manager.statistics()
    }
    try await meshEventually {
      let slowPeerIsWaiting =
        await slowTransport.statisticsWaiterCount() == 1
      let healthyPeerWasPolled =
        await healthyTransport.statisticsCallCount() == 1
      return slowPeerIsWaiting && healthyPeerWasPolled
    }

    try await manager.setOutboundMediaEnabled(false, for: healthyPeer)
    #expect(await healthyTransport.outboundMediaStates() == [true, false])
    #expect(await slowTransport.outboundMediaStates() == [true])

    await slowTransport.releaseStatistics()
    let statistics = try await polling.value
    #expect(statistics.count == 2)
    await manager.close()
  }

  @Test("failed membership expansion rolls back only newly created links")
  func failedExpansionRollsBackTransaction() async throws {
    let local = try meshParticipant(0x10)
    let peerA = try meshParticipant(0x20)
    let peerB = try meshParticipant(0x30)
    let retainedPeer = try meshParticipant(0x40)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    try await manager.reconcileParticipants([local, retainedPeer])
    let retainedTransport = try #require(await factory.transport(for: retainedPeer))
    await factory.failCreation(for: peerB)

    await #expect(throws: MeshFakeError.self) {
      try await manager.reconcileParticipants([
        local, peerA, peerB, retainedPeer,
      ])
    }

    let rolledBackTransport = try #require(
      await factory.latestTransport(for: peerA)
    )
    #expect(await rolledBackTransport.closeCount() == 1)
    #expect(await retainedTransport.closeCount() == 0)
    let snapshot = await manager.snapshot()
    #expect(snapshot.participantIDs == [local, retainedPeer])
    #expect(snapshot.links.map(\.remoteParticipantID) == [retainedPeer])
    await manager.close()
  }

  @Test("close is canonical, deterministic, and idempotent")
  func deterministicTeardown() async throws {
    let local = try meshParticipant(0x10)
    let peers = try [
      meshParticipant(0x40),
      meshParticipant(0x20),
      meshParticipant(0x30),
    ]
    let closeRecorder = MeshCloseRecorder()
    let factory = MeshFakeTransportFactory(closeRecorder: closeRecorder)
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    try await manager.reconcileParticipants(Set(peers + [local]))
    let expectedOrder = try peers
      .map { try ClipLiveShareNativeV3PeerLinkKey(local, $0) }
      .sorted()

    await manager.close()
    await manager.close()

    #expect(await closeRecorder.keys() == expectedOrder)
    for transport in await factory.transports() {
      #expect(await transport.closeCount() == 1)
    }
    #expect((await manager.snapshot()).isClosed)
    await #expect(
      throws: ClipLiveShareNativeV3MeshPeerLinkManagerError.managerClosed
    ) {
      try await manager.reconcileParticipants([local])
    }
  }

  @Test("local readiness requires every media and control peer link")
  func localReadiness() async throws {
    let local = try meshParticipant(0x10)
    let peerA = try meshParticipant(0x20)
    let peerB = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    try await manager.reconcileParticipants([local, peerA, peerB])
    let peerATransport = try #require(await factory.transport(for: peerA))
    let peerBTransport = try #require(await factory.transport(for: peerB))

    await peerATransport.emit(.connectionStateChanged(.connected))
    await peerATransport.emit(.controlChannelStateChanged(.open))
    await peerBTransport.emit(.connectionStateChanged(.connected))
    await peerBTransport.emit(.controlChannelStateChanged(.open))
    try await meshEventually {
      await manager.snapshot().isLocallyComplete
    }

    await peerBTransport.emit(.controlChannelStateChanged(.closed))
    try await meshEventually {
      !(await manager.snapshot().isLocallyComplete)
    }
    await manager.close()
  }

  @Test("provisional links quarantine every outbound media sender until promotion")
  func provisionalMediaQuarantine() async throws {
    let local = try meshParticipant(0x10)
    let committedPeer = try meshParticipant(0x20)
    let candidate = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )

    try await manager.reconcileParticipants([local, committedPeer])
    try await manager.reconcileParticipants(
      [local, committedPeer, candidate],
      quarantinedParticipantIDs: [candidate]
    )

    let committedTransport = try #require(
      await factory.transport(for: committedPeer)
    )
    let candidateTransport = try #require(
      await factory.transport(for: candidate)
    )
    #expect(
      committedTransport.configuration.outboundMediaInitiallyEnabled
    )
    #expect(
      !candidateTransport.configuration.outboundMediaInitiallyEnabled
    )
    #expect(await committedTransport.outboundMediaStates() == [true])
    #expect(await candidateTransport.outboundMediaStates() == [false])
    #expect(
      (await manager.snapshot()).links.first {
        $0.remoteParticipantID == committedPeer
      }?.outboundMediaEnabled == true
    )
    #expect(
      (await manager.snapshot()).links.first {
        $0.remoteParticipantID == candidate
      }?.outboundMediaEnabled == false
    )
    let committedView = await manager.snapshot().retainingParticipants([
      local,
      committedPeer,
    ])
    #expect(committedView.participantIDs == [local, committedPeer])
    #expect(
      !committedView.links.contains {
        $0.remoteParticipantID == candidate
      }
    )

    let remoteTrackID = try ClipLiveShareMediaTrackID(
      rawValue: "candidate-video"
    )
    await candidateTransport.emit(.remoteVideoTrackAdded(remoteTrackID))
    await candidateTransport.emit(
      .remoteParticipantAudioAvailable(trackID: "candidate-audio")
    )
    try await meshEventually {
      let link = await manager.snapshot().links.first {
        $0.remoteParticipantID == candidate
      }
      return link?.remoteVideoTrackIDs == [remoteTrackID]
        && link?.remoteParticipantAudioTrackID == "candidate-audio"
    }

    // Promotion reuses this exact transport and activates its RTP encodings
    // once. The replayable receiver registry remains available to the runtime
    // that subscribes after the signed membership commit.
    try await manager.reconcileParticipants(
      [local, committedPeer, candidate]
    )
    #expect(await factory.makeCount() == 2)
    #expect(await candidateTransport.outboundMediaStates() == [false, true])
    #expect(
      (await manager.snapshot()).links.first {
        $0.remoteParticipantID == candidate
      }?.outboundMediaEnabled == true
    )
    #expect(
      (await manager.snapshot()).links.first {
        $0.remoteParticipantID == candidate
      }?.remoteVideoTrackIDs == [remoteTrackID]
    )
    await manager.close()
  }

  @Test("mesh settings preserve the full pre-v4 policy on every sender")
  func senderPoliciesDoNotDivideTheSelectedPreset() async throws {
    let local = try meshParticipant(0x10)
    let peerA = try meshParticipant(0x20)
    let peerB = try meshParticipant(0x30)
    let peerC = try meshParticipant(0x40)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    try await manager.reconcileParticipants([local, peerA, peerB])
    let first = try #require(await factory.transport(for: peerA))
    let second = try #require(await factory.transport(for: peerB))
    let fallback = WebRTCSenderPolicy(
      maximumBitrateBps: 6_000_000,
      maximumFramesPerSecond: 60,
      degradationStrategy: .resolution
    )
    let policies = [
      0: WebRTCSenderPolicy(
        maximumBitrateBps: 4_800_000,
        maximumFramesPerSecond: 60,
        degradationStrategy: .resolution,
        bitratePriority: 4
      ),
      1: WebRTCSenderPolicy(
        maximumBitrateBps: 1_200_000,
        maximumFramesPerSecond: 60,
        degradationStrategy: .resolution
      ),
    ]

    await manager.updateSenderPolicies(
      policies,
      fallback: fallback,
      videoEncodingMode: .quality
    )

    let expected = MeshSenderPolicyUpdate(
      policiesBySlot: [:],
      fallback: fallback,
      videoEncodingMode: nil
    )
    #expect(await first.senderPolicyUpdates() == [expected])
    #expect(await second.senderPolicyUpdates() == [expected])

    // The manager still matches the old ownership boundary: the app retains
    // the participant-wide policy in the concrete factory after updating the
    // current mesh. Merely creating a future link must not synthesize a new
    // per-slot allocation inside networking code.
    try await manager.reconcileParticipants([local, peerA, peerB, peerC])
    let third = try #require(await factory.transport(for: peerC))
    #expect(await third.senderPolicyUpdates().isEmpty)
    await manager.close()
  }

  @Test("native and Web links receive the same complete sender policy")
  func webAndNativeSenderPoliciesStayIdentical() async throws {
    let local = try meshParticipant(0x10)
    let nativePeer = try meshParticipant(0x20)
    let webPeer = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    await manager.setVideoCodecNegotiationPolicies([
      nativePeer: .nativeCompatible,
      webPeer: .exact,
    ])
    try await manager.reconcileParticipants([local, nativePeer, webPeer])

    let nativeTransport = try #require(
      await factory.transport(for: nativePeer)
    )
    let webTransport = try #require(await factory.transport(for: webPeer))
    #expect(
      nativeTransport.configuration.videoCodecNegotiationPolicy
        == .nativeCompatible
    )
    #expect(webTransport.configuration.videoCodecNegotiationPolicy == .exact)

    let fallback = WebRTCSenderPolicy(
      maximumBitrateBps: 20_000_000,
      minimumBitrateBps: 4_000_000,
      maximumFramesPerSecond: 60,
      degradationStrategy: .resolution,
      temporalLayerCount: 2,
      resolutionScale: 1,
      bitratePriority: 3
    )
    await manager.updateSenderPolicies(
      [
        0: WebRTCSenderPolicy(
          maximumBitrateBps: 1_000_000,
          maximumFramesPerSecond: 15,
          resolutionScale: 2
        )
      ],
      fallback: fallback,
      videoEncodingMode: .quality
    )

    let expected = MeshSenderPolicyUpdate(
      policiesBySlot: [:],
      fallback: fallback,
      videoEncodingMode: nil
    )
    #expect(await nativeTransport.senderPolicyUpdates() == [expected])
    #expect(await webTransport.senderPolicyUpdates() == [expected])
    await manager.close()
  }

  @Test("creator-certified Web peers keep exact codec policy per link")
  func profileAwareCodecPolicyIsRetainedByRecreatedLinks() async throws {
    let local = try meshParticipant(0x10)
    let nativePeer = try meshParticipant(0x20)
    let webPeer = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )

    await manager.setVideoCodecNegotiationPolicies([
      nativePeer: .nativeCompatible,
      webPeer: .exact,
    ])
    try await manager.reconcileParticipants([local, nativePeer, webPeer])

    #expect(
      await factory.transport(for: nativePeer)?.configuration
        .videoCodecNegotiationPolicy == .nativeCompatible
    )
    let originalWeb = try #require(await factory.transport(for: webPeer))
    #expect(originalWeb.configuration.videoCodecNegotiationPolicy == .exact)

    try await manager.updateVideoCodecPreference(
      .h264,
      for: webPeer,
      rollbackTo: .av1
    )

    try await manager.disconnectParticipant(webPeer)
    try await manager.reconcileParticipants([local, nativePeer, webPeer])
    let replacementWeb = try #require(
      await factory.latestTransport(for: webPeer)
    )
    #expect(replacementWeb !== originalWeb)
    #expect(replacementWeb.configuration.videoCodecNegotiationPolicy == .exact)
    #expect(await replacementWeb.restoredVideoCodecs() == [.h264])
    #expect(await replacementWeb.currentVideoCodecPreference() == .h264)
    await manager.close()
  }

  @Test("failed codec preference restores through the non-negotiating seam")
  func failedCodecPreferenceUsesRestoreSeam() async throws {
    let local = try meshParticipant(0x10)
    let remote = try meshParticipant(0x20)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    try await manager.reconcileParticipants([local, remote])
    let transport = try #require(await factory.transport(for: remote))
    await transport.failNextCodecUpdate()

    var failed = false
    do {
      try await manager.updateVideoCodecPreference(
        .vp9,
        for: remote,
        rollbackTo: .av1
      )
    } catch {
      failed = true
    }

    #expect(failed)
    #expect(await transport.videoCodecUpdates() == [.vp9])
    #expect(await transport.restoredVideoCodecs() == [.av1])
    await manager.close()
  }

  @Test("offered codec survives answerer transport recreation")
  func offeredCodecSurvivesAnswererRecreation() async throws {
    let local = try meshParticipant(0x20)
    let remote = try meshParticipant(0x10)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: local,
      transportFactory: factory
    )
    try await manager.reconcileParticipants([local, remote])
    let original = try #require(await factory.transport(for: remote))
    await original.setCurrentVideoCodec(.h264)
    let key = try ClipLiveShareNativeV3PeerLinkKey(local, remote)
    try await manager.applyRemoteNegotiation(
      .init(
        peerLinkKey: key,
        targetParticipantID: local,
        payload: .sessionDescription(.init(kind: .offer, sdp: "offer"))
      ),
      from: remote
    )

    try await manager.disconnectParticipant(remote)
    try await manager.reconcileParticipants([local, remote])
    let replacement = try #require(await factory.latestTransport(for: remote))
    #expect(replacement !== original)
    #expect(await replacement.restoredVideoCodecs() == [.h264])
    #expect(await replacement.currentVideoCodecPreference() == .h264)
    await manager.close()
  }
}

@Suite("Server-coordinated independent pair reconciliation")
struct ClipLiveShareServerMeshPeerReconcilerTests {
  @Test("structural recovery recreates only the failed pair")
  func structuralRecoveryRecreatesOnlyOnePair() async throws {
    let participantA = try meshParticipant(0x10)
    let participantB = try meshParticipant(0x20)
    let participantC = try meshParticipant(0x30)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: participantA,
      transportFactory: factory
    )
    let reconciler = ClipLiveShareServerMeshPeerReconciler(
      localParticipantID: participantA,
      peerLinkManager: manager
    )
    let initial = try await reconciler.applyRoster(
      serverMeshRoster(
        revision: 1,
        localParticipantID: participantA,
        participantIDs: [participantA, participantB, participantC]
      )
    )
    let originalB = try #require(
      await factory.latestTransport(for: participantB)
    )
    let originalC = try #require(
      await factory.latestTransport(for: participantC)
    )
    let originalBPair = try #require(
      initial.snapshot.pairs.first {
        $0.link.remoteParticipantID == participantB
      }
    )

    let recovered = try await reconciler.recreatePair(with: participantB)
    let replacementB = try #require(
      await factory.latestTransport(for: participantB)
    )
    let retainedC = try #require(
      await factory.latestTransport(for: participantC)
    )
    let recoveredBPair = try #require(
      recovered.pairs.first {
        $0.link.remoteParticipantID == participantB
      }
    )

    #expect(replacementB !== originalB)
    #expect(retainedC === originalC)
    #expect(await originalB.closeCount() == 1)
    #expect(await originalC.closeCount() == 0)
    #expect(await factory.makeCount() == 3)
    #expect(recoveredBPair.pairID == originalBPair.pairID)
    #expect(recoveredBPair.epoch == originalBPair.epoch)
    #expect(recovered.isLocallyComplete)

    await reconciler.close()
  }

  @Test("two, three and four participants derive one canonical pair each")
  func completeTopologiesUseOneDeterministicTransportPerPair() async throws {
    let participants = try [
      meshParticipant(0x10),
      meshParticipant(0x20),
      meshParticipant(0x30),
      meshParticipant(0x40),
    ]

    for participantCount in 2...4 {
      let roster = Set(participants.prefix(participantCount))
      var factories: [ClipLiveShareNativeV3ParticipantID: MeshFakeTransportFactory] = [:]
      var reconcilers: [ClipLiveShareServerMeshPeerReconciler] = []
      var observedPairs:
        [ClipLiveShareNativeV3PeerLinkKey: [ClipLiveShareServerMeshPairSnapshot]] = [:]

      for localParticipantID in roster {
        let factory = MeshFakeTransportFactory()
        let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
          localParticipantID: localParticipantID,
          transportFactory: factory
        )
        let reconciler = ClipLiveShareServerMeshPeerReconciler(
          localParticipantID: localParticipantID,
          peerLinkManager: manager
        )
        factories[localParticipantID] = factory
        reconcilers.append(reconciler)

        let result = try await reconciler.applyRoster(
          serverMeshRoster(
            revision: 1,
            localParticipantID: localParticipantID,
            participantIDs: roster
          )
        )
        #expect(result.disposition == .applied)
        #expect(result.failedPairs.isEmpty)
        #expect(result.snapshot.isLocallyComplete)
        #expect(result.snapshot.pairs.count == participantCount - 1)
        for pair in result.snapshot.pairs {
          observedPairs[pair.id, default: []].append(pair)
        }
      }

      var allKeys = Set<ClipLiveShareNativeV3PeerLinkKey>()
      for (participantID, factory) in factories {
        let configurations = await factory.configurations()
        #expect(configurations.count == participantCount - 1)
        for configuration in configurations {
          allKeys.insert(configuration.key)
          #expect(configuration.outboundMediaInitiallyEnabled)
          #expect(
            configuration.role
              == (participantID == configuration.key.lowerParticipantID
                ? .offerer : .answerer)
          )
          let transport = try #require(
            await factory.transport(
              for: configuration.remoteParticipantID
            )
          )
          #expect(await transport.startCount() == 1)
        }
      }
      #expect(
        allKeys.count == participantCount * (participantCount - 1) / 2
      )
      #expect(Set(observedPairs.keys) == allKeys)
      for endpointPairs in observedPairs.values {
        #expect(endpointPairs.count == 2)
        #expect(Set(endpointPairs.map(\.pairID)).count == 1)
        #expect(Set(endpointPairs.map(\.epoch)).count == 1)
      }
      for reconciler in reconcilers {
        await reconciler.close()
      }
    }
  }

  @Test("unrelated roster changes preserve the A-B transport and pair epoch")
  func retainedPairIdentitySurvivesJoinAndLeave() async throws {
    let participantA = try meshParticipant(0x10)
    let participantB = try meshParticipant(0x20)
    let participantC = try meshParticipant(0x30)
    let participantD = try meshParticipant(0x40)
    let factory = MeshFakeTransportFactory()
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: participantA,
      transportFactory: factory
    )
    let reconciler = ClipLiveShareServerMeshPeerReconciler(
      localParticipantID: participantA,
      peerLinkManager: manager
    )

    let two = try await reconciler.applyRoster(
      serverMeshRoster(
        revision: 1,
        localParticipantID: participantA,
        participantIDs: [participantA, participantB]
      )
    )
    let firstABPair = try #require(
      two.snapshot.pairs.first { $0.link.remoteParticipantID == participantB }
    )
    let firstABTransport = try #require(
      await factory.transport(for: participantB)
    )

    _ = try await reconciler.applyRoster(
      serverMeshRoster(
        revision: 2,
        localParticipantID: participantA,
        participantIDs: [participantA, participantB, participantC]
      )
    )
    _ = try await reconciler.applyRoster(
      serverMeshRoster(
        revision: 3,
        localParticipantID: participantA,
        participantIDs: [participantA, participantB, participantC, participantD]
      )
    )
    let participantCTransport = try #require(
      await factory.transport(for: participantC)
    )
    let afterLeave = try await reconciler.applyRoster(
      serverMeshRoster(
        revision: 4,
        localParticipantID: participantA,
        participantIDs: [participantA, participantB, participantD]
      )
    )

    let retainedABPair = try #require(
      afterLeave.snapshot.pairs.first {
        $0.link.remoteParticipantID == participantB
      }
    )
    let retainedABTransport = try #require(
      await factory.latestTransport(for: participantB)
    )
    #expect(retainedABPair.epoch == firstABPair.epoch)
    #expect(retainedABTransport === firstABTransport)
    #expect(await retainedABTransport.startCount() == 1)
    #expect(await retainedABTransport.closeCount() == 0)
    #expect(await participantCTransport.closeCount() == 1)
    #expect(afterLeave.retainedPairs.contains { $0.id == firstABPair.id })

    let duplicate = try await reconciler.applyRoster(
      serverMeshRoster(
        revision: 4,
        localParticipantID: participantA,
        participantIDs: [participantA, participantB, participantD]
      )
    )
    #expect(duplicate.disposition == .ignoredDuplicate)
    #expect(await factory.makeCount() == 3)

    let stale = try await reconciler.applyRoster(
      serverMeshRoster(
        revision: 2,
        localParticipantID: participantA,
        participantIDs: [participantA, participantB]
      )
    )
    #expect(stale.disposition == .ignoredStale)
    #expect(stale.snapshot.rosterRevision?.rawValue == 4)
    #expect(stale.snapshot.pairs.count == 2)

    let firstDTransport = try #require(
      await factory.transport(for: participantD)
    )
    let changedPairEpoch = try await reconciler.applyRoster(
      serverMeshRoster(
        revision: 5,
        localParticipantID: participantA,
        participantIDs: [participantA, participantB, participantD],
        pairEpochs: [participantD: 2]
      )
    )
    let replacementDTransport = try #require(
      await factory.latestTransport(for: participantD)
    )
    #expect(replacementDTransport !== firstDTransport)
    #expect(await firstDTransport.closeCount() == 1)
    #expect(
      changedPairEpoch.addedPairs.first {
        $0.link.remoteParticipantID == participantD
      }?.epoch.rawValue == 2
    )
    #expect(
      changedPairEpoch.removedPairKeys.contains(
        try ClipLiveShareNativeV3PeerLinkKey(participantA, participantD)
      )
    )
    #expect(
      changedPairEpoch.retainedPairs.first {
        $0.link.remoteParticipantID == participantB
      }?.epoch == firstABPair.epoch
    )
    #expect(await factory.latestTransport(for: participantB) === firstABTransport)

    await reconciler.close()
  }

  @Test("one pair creation failure cannot roll back or block other pairs")
  func pairFailureIsIsolatedAndRetryable() async throws {
    let participantA = try meshParticipant(0x10)
    let participantB = try meshParticipant(0x20)
    let failingParticipant = try meshParticipant(0x30)
    let participantD = try meshParticipant(0x40)
    let factory = MeshFakeTransportFactory()
    await factory.failCreation(for: failingParticipant)
    let manager = ClipLiveShareNativeV3MeshPeerLinkManager(
      localParticipantID: participantA,
      transportFactory: factory
    )
    let reconciler = ClipLiveShareServerMeshPeerReconciler(
      localParticipantID: participantA,
      peerLinkManager: manager
    )

    let first = try await reconciler.applyRoster(
      serverMeshRoster(
        revision: 1,
        localParticipantID: participantA,
        participantIDs: [
          participantA, participantB, failingParticipant, participantD,
        ]
      )
    )
    #expect(first.failedPairs.count == 1)
    #expect(first.failedPairs.first?.remoteParticipantID == failingParticipant)
    #expect(first.failedPairs.first?.attempt == 1)
    #expect(
      Set(first.snapshot.pairs.map(\.link.remoteParticipantID))
        == [participantB, participantD]
    )
    #expect(!first.snapshot.isLocallyComplete)

    let participantBTransport = try #require(
      await factory.transport(for: participantB)
    )
    let participantDTransport = try #require(
      await factory.transport(for: participantD)
    )
    let participantBEpoch = try #require(
      first.snapshot.pairs.first {
        $0.link.remoteParticipantID == participantB
      }
    ).epoch
    let participantDEpoch = try #require(
      first.snapshot.pairs.first {
        $0.link.remoteParticipantID == participantD
      }
    ).epoch

    await factory.allowCreation(for: failingParticipant)
    let retried = try await reconciler.retryPair(
      with: failingParticipant
    )
    #expect(retried.failedPairs.isEmpty)
    #expect(retried.isLocallyComplete)
    #expect(retried.pairs.count == 3)
    #expect(
      retried.pairs.first { $0.link.remoteParticipantID == participantB }?
        .epoch == participantBEpoch
    )
    #expect(
      retried.pairs.first { $0.link.remoteParticipantID == participantD }?
        .epoch == participantDEpoch
    )
    #expect(await factory.latestTransport(for: participantB) === participantBTransport)
    #expect(await factory.latestTransport(for: participantD) === participantDTransport)
    #expect(await participantBTransport.startCount() == 1)
    #expect(await participantDTransport.startCount() == 1)

    await reconciler.close()
  }
}

private enum MeshFakeError: Error {
  case creationFailed
  case codecUpdateFailed
  case restartFailed
  case statisticsFailed
}

private struct MeshSenderPolicyUpdate: Equatable, Sendable {
  let policiesBySlot: [Int: WebRTCSenderPolicy]
  let fallback: WebRTCSenderPolicy
  let videoEncodingMode: LiveShareEncodingMode?
}

private actor MeshFakeTransportFactory:
  ClipLiveShareNativeV3PeerLinkTransportFactory
{
  private let closeRecorder: MeshCloseRecorder?
  private var madeConfigurations: [ClipLiveShareNativeV3PeerLinkConfiguration] = []
  private var madeTransports: [MeshFakeTransport] = []
  private var failedParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID> = []

  init(closeRecorder: MeshCloseRecorder? = nil) {
    self.closeRecorder = closeRecorder
  }

  func makeTransport(
    configuration: ClipLiveShareNativeV3PeerLinkConfiguration
  ) async throws -> any ClipLiveShareNativeV3PeerLinkTransport {
    if failedParticipantIDs.contains(configuration.remoteParticipantID) {
      throw MeshFakeError.creationFailed
    }
    let transport = MeshFakeTransport(
      configuration: configuration,
      closeRecorder: closeRecorder
    )
    madeConfigurations.append(configuration)
    madeTransports.append(transport)
    return transport
  }

  func failCreation(for participantID: ClipLiveShareNativeV3ParticipantID) {
    failedParticipantIDs.insert(participantID)
  }

  func allowCreation(for participantID: ClipLiveShareNativeV3ParticipantID) {
    failedParticipantIDs.remove(participantID)
  }

  func configurations() -> [ClipLiveShareNativeV3PeerLinkConfiguration] {
    madeConfigurations
  }

  func makeCount() -> Int { madeTransports.count }


  func transports() -> [MeshFakeTransport] { madeTransports }

  func transport(
    for participantID: ClipLiveShareNativeV3ParticipantID
  ) -> MeshFakeTransport? {
    madeTransports.first {
      $0.configuration.remoteParticipantID == participantID
    }
  }

  func latestTransport(
    for participantID: ClipLiveShareNativeV3ParticipantID
  ) -> MeshFakeTransport? {
    madeTransports.last {
      $0.configuration.remoteParticipantID == participantID
    }
  }
}

private actor MeshFakeTransport:
  ClipLiveShareNativeV3PeerLinkTransport
{
  nonisolated let configuration: ClipLiveShareNativeV3PeerLinkConfiguration

  private let closeRecorder: MeshCloseRecorder?
  private var continuations: [
    UUID: AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent>.Continuation
  ] = [:]
  private var starts = 0
  private var closes = 0
  private var negotiationRequests = 0
  private var restarts = 0
  private var shouldFailNextRestart = false
  private var shouldFailNextCodecUpdate = false
  private var currentVideoCodec: WebRTCVideoCodec = .av1
  private var shouldFailNextStatistics = false
  private var descriptions: [WebRTCSessionDescription] = []
  private var candidates: [WebRTCICECandidate] = []
  private var controlMessages: [Data] = []
  private var outboundStates: [Bool]
  private var senderPolicies: [MeshSenderPolicyUpdate] = []
  private var recordedVideoCodecUpdates: [WebRTCVideoCodec] = []
  private var recordedRestoredVideoCodecs: [WebRTCVideoCodec] = []
  private var receiverAudioOperationLog: [String] = []
  private var playbackEnabledValues: [Bool] = []
  private var volumeValues: [Double] = []
  private var statisticsCalls = 0
  private var blocksStatistics = false
  private var statisticsWaiters: [CheckedContinuation<Void, Never>] = []
  private var currentStatistics = ClipLiveShareNativeV3PeerLinkTransportStatistics(
    capturedAt: Date(timeIntervalSince1970: 0)
  )

  init(
    configuration: ClipLiveShareNativeV3PeerLinkConfiguration,
    closeRecorder: MeshCloseRecorder?
  ) {
    self.configuration = configuration
    self.closeRecorder = closeRecorder
    outboundStates = [configuration.outboundMediaInitiallyEnabled]
  }

  func events() -> AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: ClipLiveShareNativeV3PeerLinkTransportEvent.self,
      bufferingPolicy: .bufferingNewest(64)
    )
    continuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(id) }
    }
    return stream
  }

  func start() {
    starts += 1
    receiverAudioOperationLog.append("start")
  }

  func requestNegotiation() {
    negotiationRequests += 1
  }

  func applyRemoteDescription(_ description: WebRTCSessionDescription) {
    descriptions.append(description)
  }

  func addRemoteICECandidate(_ candidate: WebRTCICECandidate) {
    candidates.append(candidate)
  }

  func sendControlMessage(_ data: Data) {
    controlMessages.append(data)
  }

  func remoteVideoStream(
    for _: ClipLiveShareStreamDescriptor
  ) -> WebRTCRemoteVideoStream? {
    nil
  }

  func setRemoteParticipantAudioPlaybackEnabled(_ enabled: Bool) {
    playbackEnabledValues.append(enabled)
    receiverAudioOperationLog.append("playback:\(enabled)")
  }

  func setRemoteParticipantAudioVolume(_ volume: Double) {
    volumeValues.append(volume)
    receiverAudioOperationLog.append("volume:\(volume)")
  }

  func setOutboundMediaEnabled(_ enabled: Bool) {
    outboundStates.append(enabled)
  }

  func updateSenderPolicies(
    _ policiesBySlot: [Int: WebRTCSenderPolicy],
    fallback: WebRTCSenderPolicy,
    videoEncodingMode: LiveShareEncodingMode
  ) {
    senderPolicies.append(
      .init(
        policiesBySlot: policiesBySlot,
        fallback: fallback,
        videoEncodingMode: videoEncodingMode
      )
    )
  }

  func updateSenderPolicy(_ policy: WebRTCSenderPolicy) {
    senderPolicies.append(
      .init(
        policiesBySlot: [:],
        fallback: policy,
        videoEncodingMode: nil
      )
    )
  }

  func updateVideoCodecPreference(_ codec: WebRTCVideoCodec) throws {
    recordedVideoCodecUpdates.append(codec)
    if shouldFailNextCodecUpdate {
      shouldFailNextCodecUpdate = false
      throw MeshFakeError.codecUpdateFailed
    }
    currentVideoCodec = codec
  }

  func restoreVideoCodecPreference(_ codec: WebRTCVideoCodec) async throws {
    recordedRestoredVideoCodecs.append(codec)
    currentVideoCodec = codec
  }

  func currentVideoCodecPreference() async -> WebRTCVideoCodec? {
    currentVideoCodec
  }

  func restartICE() throws {
    restarts += 1
    if shouldFailNextRestart {
      shouldFailNextRestart = false
      throw MeshFakeError.restartFailed
    }
  }

  func statistics() async throws
    -> ClipLiveShareNativeV3PeerLinkTransportStatistics
  {
    statisticsCalls += 1
    if shouldFailNextStatistics {
      shouldFailNextStatistics = false
      throw MeshFakeError.statisticsFailed
    }
    if blocksStatistics {
      await withCheckedContinuation { continuation in
        statisticsWaiters.append(continuation)
      }
    }
    return currentStatistics
  }

  func close() async {
    guard closes == 0 else { return }
    closes += 1
    releaseStatistics()
    for continuation in continuations.values {
      continuation.finish()
    }
    continuations.removeAll(keepingCapacity: false)
    await closeRecorder?.record(configuration.key)
  }

  func emit(_ event: ClipLiveShareNativeV3PeerLinkTransportEvent) {
    for continuation in continuations.values {
      continuation.yield(event)
    }
  }

  func failNextRestart() {
    shouldFailNextRestart = true
  }

  func failNextCodecUpdate() {
    shouldFailNextCodecUpdate = true
  }

  func setCurrentVideoCodec(_ codec: WebRTCVideoCodec) {
    currentVideoCodec = codec
  }

  func failNextStatistics() {
    shouldFailNextStatistics = true
  }

  func setStatistics(
    _ statistics: ClipLiveShareNativeV3PeerLinkTransportStatistics
  ) {
    currentStatistics = statistics
  }

  func blockStatistics() {
    blocksStatistics = true
  }

  func releaseStatistics() {
    blocksStatistics = false
    let waiters = statisticsWaiters
    statisticsWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resume()
    }
  }

  func startCount() -> Int { starts }
  func closeCount() -> Int { closes }
  func negotiationRequestCount() -> Int { negotiationRequests }
  func restartCount() -> Int { restarts }
  func remoteDescriptions() -> [WebRTCSessionDescription] { descriptions }
  func remoteCandidates() -> [WebRTCICECandidate] { candidates }
  func sentControlMessages() -> [Data] { controlMessages }
  func receiverAudioOperations() -> [String] {
    receiverAudioOperationLog
  }
  func playbackEnabledHistory() -> [Bool] { playbackEnabledValues }
  func volumeHistory() -> [Double] { volumeValues }
  func outboundMediaStates() -> [Bool] { outboundStates }
  func senderPolicyUpdates() -> [MeshSenderPolicyUpdate] {
    senderPolicies
  }
  func videoCodecUpdates() -> [WebRTCVideoCodec] {
    recordedVideoCodecUpdates
  }
  func restoredVideoCodecs() -> [WebRTCVideoCodec] {
    recordedRestoredVideoCodecs
  }
  func statisticsCallCount() -> Int { statisticsCalls }
  func statisticsWaiterCount() -> Int { statisticsWaiters.count }

  private func removeContinuation(_ id: UUID) {
    continuations[id] = nil
  }
}

private actor MeshCloseRecorder {
  private var closedKeys: [ClipLiveShareNativeV3PeerLinkKey] = []

  func record(_ key: ClipLiveShareNativeV3PeerLinkKey) {
    closedKeys.append(key)
  }

  func keys() -> [ClipLiveShareNativeV3PeerLinkKey] { closedKeys }
}

private actor MeshManagerEventRecorder {
  private var recordedEvents: [ClipLiveShareNativeV3MeshPeerLinkManagerEvent] = []

  func append(_ event: ClipLiveShareNativeV3MeshPeerLinkManagerEvent) {
    recordedEvents.append(event)
  }

  func events() -> [ClipLiveShareNativeV3MeshPeerLinkManagerEvent] {
    recordedEvents
  }
}

private actor MeshImmediateSleeper: ClipLiveShareReconnectSleeper {
  private var sleeps = 0

  func sleep(for _: Duration) async throws {
    sleeps += 1
    await Task.yield()
  }

  func sleepCount() -> Int { sleeps }
}

private func meshParticipant(
  _ byte: UInt8
) throws -> ClipLiveShareNativeV3ParticipantID {
  try .init(
    bytes: Data(
      repeating: byte,
      count: ClipLiveShareNativeV3.participantIDByteCount
    )
  )
}

private func serverMeshRoster(
  revision: UInt64,
  localParticipantID: ClipLiveShareNativeV3ParticipantID,
  participantIDs: Set<ClipLiveShareNativeV3ParticipantID>,
  pairEpochs: [ClipLiveShareNativeV3ParticipantID: UInt64] = [:]
) throws -> ClipLiveShareServerMeshRosterSnapshot {
  let localPairs = try Set(
    participantIDs.filter { $0 != localParticipantID }.map {
      remoteParticipantID in
      let key = try ClipLiveShareNativeV3PeerLinkKey(
        localParticipantID,
        remoteParticipantID
      )
      var pairIDBytes = Data()
      pairIDBytes.append(key.lowerParticipantID.bytes.prefix(16))
      pairIDBytes.append(key.upperParticipantID.bytes.prefix(16))
      return ClipLiveShareServerMeshDesiredPair(
        pairID: try .init(bytes: pairIDBytes),
        epoch: try .init(rawValue: pairEpochs[remoteParticipantID] ?? 1),
        remoteParticipantID: remoteParticipantID
      )
    }
  )
  return .init(
    revision: try .init(rawValue: revision),
    participantIDs: participantIDs,
    localPairs: localPairs
  )
}

private func meshEventually(
  timeout: Duration = .seconds(2),
  condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for native-v3 mesh condition")
}
