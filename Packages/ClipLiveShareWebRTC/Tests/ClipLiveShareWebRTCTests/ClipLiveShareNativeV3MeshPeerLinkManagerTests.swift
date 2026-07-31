import ClipLiveShare
import Foundation
import Testing

@testable import ClipLiveShareWebRTC

@Suite("Native v3 mesh peer-link manager")
struct ClipLiveShareNativeV3MeshPeerLinkManagerTests {
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
}

private enum MeshFakeError: Error {
  case creationFailed
  case restartFailed
  case statisticsFailed
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
  private var shouldFailNextStatistics = false
  private var descriptions: [WebRTCSessionDescription] = []
  private var candidates: [WebRTCICECandidate] = []
  private var controlMessages: [Data] = []
  private var outboundStates: [Bool]
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
