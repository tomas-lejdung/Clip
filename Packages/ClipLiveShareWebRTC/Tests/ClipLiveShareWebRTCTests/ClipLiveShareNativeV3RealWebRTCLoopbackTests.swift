import AudioToolbox
import ClipCapture
import ClipLiveShare
import CoreMedia
import Foundation
import Testing

@testable import ClipLiveShareWebRTC

extension NativeMediaResourceTests {
  @Suite("Native v3 production WebRTC loopback")
  struct ClipLiveShareNativeV3RealWebRTCLoopbackTests {
    @Test(
      "two participants negotiate symmetric media and ordered control",
      .timeLimit(.minutes(1))
    )
    func twoParticipantProductionPair() async throws {
      let first = try NativeV3RealParticipant(byte: 0x10)
      let second = try NativeV3RealParticipant(byte: 0x20)
      let link = try await NativeV3RealLink(first: first, second: second)

      do {
        try await link.start()
        let ready = await link.waitUntilReady()
        let readySnapshot = await link.snapshot()
        #expect(
          ready,
          Comment(rawValue: "Pair did not become ready: \(readySnapshot)")
        )
        guard ready else {
          await link.close()
          first.factory.close()
          second.factory.close()
          return
        }

        #expect(readySnapshot.first.connectionState == .connected)
        #expect(readySnapshot.second.connectionState == .connected)
        #expect(readySnapshot.first.controlState == .open)
        #expect(readySnapshot.second.controlState == .open)
        #expect(readySnapshot.first.localICECandidateCount > 0)
        #expect(readySnapshot.second.localICECandidateCount > 0)
        #expect(readySnapshot.relayErrors.isEmpty)
        #expect(readySnapshot.first.failures.isEmpty)
        #expect(readySnapshot.second.failures.isEmpty)

        let firstRemoteVideoTrackIDs = Set(
          second.factory.slotSnapshots.map(\.trackID)
        )
        let secondRemoteVideoTrackIDs = Set(
          first.factory.slotSnapshots.map(\.trackID)
        )
        #expect(
          readySnapshot.first.remoteVideoTrackIDs
            == firstRemoteVideoTrackIDs
        )
        #expect(
          readySnapshot.second.remoteVideoTrackIDs
            == secondRemoteVideoTrackIDs
        )
        #expect(
          readySnapshot.first.remoteAudioTrackID
            == second.factory.localParticipantAudioTrackID
        )
        #expect(
          readySnapshot.second.remoteAudioTrackID
            == first.factory.localParticipantAudioTrackID
        )
        #expect(readySnapshot.first.remoteVideoTrackAddEvents == 4)
        #expect(readySnapshot.second.remoteVideoTrackAddEvents == 4)
        #expect(readySnapshot.first.remoteAudioAvailableEvents == 1)
        #expect(readySnapshot.second.remoteAudioAvailableEvents == 1)
        #expect(!first.factory.isSystemAudioEnabled)
        first.factory.setSystemAudioEnabled(true)
        #expect(first.factory.isSystemAudioEnabled)
        first.factory.setSystemAudioEnabled(false)
        #expect(!first.factory.isSystemAudioEnabled)

        let descriptions =
          readySnapshot.first.localDescriptions
          + readySnapshot.second.localDescriptions
        let offer = try #require(
          descriptions.first(where: { $0.kind == .offer })
        )
        let answer = try #require(
          descriptions.first(where: { $0.kind == .answer })
        )
        for description in [offer, answer] {
          let sections = nativeV3MediaSections(in: description.sdp)
          #expect(sections["video"] == 4)
          #expect(sections["audio"] == 1)
          #expect(sections["application"] == 1)
        }

        let firstPayload = Data("first-to-second".utf8)
        let secondPayload = Data("second-to-first".utf8)
        try await link.send(firstPayload, from: .first)
        try await link.send(secondPayload, from: .second)
        let delivered = await link.waitUntil {
          $0.second.controlMessages.contains(firstPayload)
            && $0.first.controlMessages.contains(secondPayload)
        }
        let deliveredSnapshot = await link.snapshot()
        #expect(
          delivered,
          Comment(
            rawValue:
              "Bidirectional control was not delivered: \(deliveredSnapshot)"
          )
        )
        #expect(
          deliveredSnapshot.first.controlMessages == [secondPayload]
        )
        #expect(
          deliveredSnapshot.second.controlMessages == [firstPayload]
        )

        await link.close()
        let closed = await link.waitUntilClosed()
        #expect(closed, "Both production event streams must finish on close")
        let closedSnapshot = await link.snapshot()
        #expect(closedSnapshot.first.remoteVideoTrackIDs.isEmpty)
        #expect(closedSnapshot.second.remoteVideoTrackIDs.isEmpty)
        #expect(closedSnapshot.first.remoteAudioTrackID == nil)
        #expect(closedSnapshot.second.remoteAudioTrackID == nil)
        #expect(closedSnapshot.first.remoteVideoTrackRemoveEvents == 4)
        #expect(closedSnapshot.second.remoteVideoTrackRemoveEvents == 4)
        #expect(closedSnapshot.first.remoteAudioRemovedEvents == 1)
        #expect(closedSnapshot.second.remoteAudioRemovedEvents == 1)
        await link.expectClosedOperationsFail()
      } catch {
        await link.close()
        first.factory.close()
        second.factory.close()
        throw error
      }

      first.factory.close()
      second.factory.close()
    }

    @Test(
      "system audio renders non-silent PCM and playout stops with its link",
      .timeLimit(.minutes(1))
    )
    func systemAudioProductionPlayout() async throws {
      let sender = try NativeV3RealParticipant(byte: 0x11)
      let listener = try NativeV3RealParticipant(
        byte: 0x22,
        remoteAudioPlaybackEnabled: true
      )
      let link = try await NativeV3RealLink(first: sender, second: listener)

      do {
        try await link.start()
        let ready = await link.waitUntilReady()
        let readySnapshot = await link.snapshot()
        #expect(
          ready,
          Comment(
            rawValue: "Audio pair did not become ready: \(readySnapshot)"
          )
        )
        guard ready else {
          await link.close()
          sender.factory.close()
          listener.factory.close()
          return
        }

        sender.factory.setSystemAudioEnabled(true)
        let tone = BorrowedCaptureAudioSample(
          sampleBuffer: try makeNativeV3PlayoutToneSample()
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        var acceptedSamples = 0
        while clock.now < deadline,
          listener.factory.playoutDiagnostics.nonSilentFrameCount == 0
        {
          if sender.factory.send(tone) {
            acceptedSamples += 1
          }
          try await Task.sleep(for: .milliseconds(10))
        }

        let audible = listener.factory.playoutDiagnostics
        #expect(acceptedSamples > 0)
        #expect(audible.callbackCount > 0)
        #expect(audible.renderedFrameCount > 0)
        #expect(audible.nonSilentFrameCount > 0)
        #expect(audible.errorCount == 0)

        sender.factory.setSystemAudioEnabled(false)
        #expect(!sender.factory.isSystemAudioEnabled)
        await link.close()
        #expect(await link.waitUntilClosed())

        // Allow a callback already owned by CoreAudio to finish, then prove
        // the closed peer connection does not leave its output pull running.
        try await Task.sleep(for: .milliseconds(100))
        let afterClose = listener.factory.playoutDiagnostics
        try await Task.sleep(for: .milliseconds(150))
        let afterSettling = listener.factory.playoutDiagnostics
        #expect(afterSettling.callbackCount == afterClose.callbackCount)
        #expect(
          afterSettling.renderedFrameCount == afterClose.renderedFrameCount
        )
        #expect(afterSettling.errorCount == afterClose.errorCount)

        sender.factory.close()
        listener.factory.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(listener.factory.playoutDiagnostics == afterSettling)
      } catch {
        await link.close()
        sender.factory.close()
        listener.factory.close()
        throw error
      }
    }

    @Test(
      "three participants establish all three independent production links",
      .timeLimit(.minutes(1))
    )
    func threeParticipantProductionMesh() async throws {
      let first = try NativeV3RealParticipant(byte: 0x31)
      let second = try NativeV3RealParticipant(byte: 0x42)
      let third = try NativeV3RealParticipant(byte: 0x53)
      let firstSecond = try await NativeV3RealLink(
        first: first,
        second: second
      )
      let firstThird = try await NativeV3RealLink(
        first: first,
        second: third
      )
      let secondThird = try await NativeV3RealLink(
        first: second,
        second: third
      )
      let links = [firstSecond, firstThird, secondThird]
      let expectedRemoteParticipants = [
        (
          link: firstSecond,
          remoteForFirst: second,
          remoteForSecond: first
        ),
        (
          link: firstThird,
          remoteForFirst: third,
          remoteForSecond: first
        ),
        (
          link: secondThird,
          remoteForFirst: third,
          remoteForSecond: second
        ),
      ]

      do {
        // Negotiate serially so this acceptance test measures three real
        // independent links without making process-wide WebRTC startup races
        // part of the contract.
        for link in links {
          try await link.start()
          let ready = await link.waitUntilReady()
          let readySnapshot = await link.snapshot()
          #expect(
            ready,
            Comment(
              rawValue:
                "Three-participant link did not become ready: "
                + "\(readySnapshot)"
            )
          )
          guard ready else {
            for link in links { await link.close() }
            for participant in [first, second, third] {
              participant.factory.close()
            }
            return
          }
        }

        for (index, link) in links.enumerated() {
          let firstPayload = Data("mesh-\(index)-first".utf8)
          let secondPayload = Data("mesh-\(index)-second".utf8)
          try await link.send(firstPayload, from: .first)
          try await link.send(secondPayload, from: .second)
          let delivered = await link.waitUntil {
            $0.first.controlMessages == [secondPayload]
              && $0.second.controlMessages == [firstPayload]
          }
          let deliveredSnapshot = await link.snapshot()
          #expect(
            delivered,
            Comment(
              rawValue:
                "Control stayed isolated from another pair: "
                + "\(deliveredSnapshot)"
            )
          )
        }

        for expected in expectedRemoteParticipants {
          let snapshot = await expected.link.snapshot()
          #expect(snapshot.first.connectionState == .connected)
          #expect(snapshot.second.connectionState == .connected)
          #expect(snapshot.first.controlState == .open)
          #expect(snapshot.second.controlState == .open)
          #expect(
            snapshot.first.remoteVideoTrackIDs
              == Set(
                expected.remoteForFirst.factory.slotSnapshots.map(\.trackID)
              )
          )
          #expect(
            snapshot.second.remoteVideoTrackIDs
              == Set(
                expected.remoteForSecond.factory.slotSnapshots.map(\.trackID)
              )
          )
          #expect(
            snapshot.first.remoteAudioTrackID
              == expected.remoteForFirst.factory.localParticipantAudioTrackID
          )
          #expect(
            snapshot.second.remoteAudioTrackID
              == expected.remoteForSecond.factory.localParticipantAudioTrackID
          )
          #expect(snapshot.first.remoteVideoTrackAddEvents == 4)
          #expect(snapshot.second.remoteVideoTrackAddEvents == 4)
          #expect(snapshot.first.remoteAudioAvailableEvents == 1)
          #expect(snapshot.second.remoteAudioAvailableEvents == 1)
          #expect(snapshot.relayErrors.isEmpty)
        }

        for link in links { await link.close() }
        for link in links {
          #expect(await link.waitUntilClosed())
        }
      } catch {
        for link in links { await link.close() }
        for participant in [first, second, third] {
          participant.factory.close()
        }
        throw error
      }

      for participant in [first, second, third] {
        participant.factory.close()
      }
    }

    @Test(
      "four participants establish all six isolated production links",
      .timeLimit(.minutes(2))
    )
    func fourParticipantProductionMesh() async throws {
      let participants = try [
        NativeV3RealParticipant(byte: 0x61),
        NativeV3RealParticipant(byte: 0x72),
        NativeV3RealParticipant(byte: 0x83),
        NativeV3RealParticipant(byte: 0x94),
      ]
      let pairs = [
        (0, 1), (0, 2), (0, 3),
        (1, 2), (1, 3),
        (2, 3),
      ]
      var links:
        [(
          link: NativeV3RealLink,
          firstIndex: Int,
          secondIndex: Int
        )] = []

      do {
        for (firstIndex, secondIndex) in pairs {
          links.append((
            link: try await NativeV3RealLink(
              first: participants[firstIndex],
              second: participants[secondIndex]
            ),
            firstIndex: firstIndex,
            secondIndex: secondIndex
          ))
        }

        // Six libwebrtc peer connections share four participant factories.
        // Negotiate each pair serially so the acceptance contract measures the
        // complete topology rather than process-wide startup contention.
        for entry in links {
          try await entry.link.start()
          let ready = await entry.link.waitUntilReady()
          let snapshot = await entry.link.snapshot()
          #expect(
            ready,
            Comment(
              rawValue:
                "Four-participant link "
                + "\(entry.firstIndex)-\(entry.secondIndex) "
                + "did not become ready: \(snapshot)"
            )
          )
          guard ready else {
            for entry in links { await entry.link.close() }
            for participant in participants {
              participant.factory.close()
            }
            return
          }
        }

        for (index, entry) in links.enumerated() {
          let firstPayload = Data(
            "four-mesh-\(index)-first".utf8
          )
          let secondPayload = Data(
            "four-mesh-\(index)-second".utf8
          )
          try await entry.link.send(firstPayload, from: .first)
          try await entry.link.send(secondPayload, from: .second)
          let delivered = await entry.link.waitUntil {
            $0.first.controlMessages == [secondPayload]
              && $0.second.controlMessages == [firstPayload]
          }
          let deliveredSnapshot = await entry.link.snapshot()
          #expect(
            delivered,
            Comment(
              rawValue:
                "Ordered control escaped or stalled on pair \(index): "
                + "\(deliveredSnapshot)"
            )
          )
        }

        for entry in links {
          let snapshot = await entry.link.snapshot()
          let firstRemote = participants[entry.secondIndex]
          let secondRemote = participants[entry.firstIndex]
          #expect(snapshot.first.connectionState == .connected)
          #expect(snapshot.second.connectionState == .connected)
          #expect(snapshot.first.controlState == .open)
          #expect(snapshot.second.controlState == .open)
          #expect(
            snapshot.first.remoteVideoTrackIDs
              == Set(firstRemote.factory.slotSnapshots.map(\.trackID))
          )
          #expect(
            snapshot.second.remoteVideoTrackIDs
              == Set(secondRemote.factory.slotSnapshots.map(\.trackID))
          )
          #expect(
            snapshot.first.remoteAudioTrackID
              == firstRemote.factory.localParticipantAudioTrackID
          )
          #expect(
            snapshot.second.remoteAudioTrackID
              == secondRemote.factory.localParticipantAudioTrackID
          )
          #expect(snapshot.first.remoteVideoTrackAddEvents == 4)
          #expect(snapshot.second.remoteVideoTrackAddEvents == 4)
          #expect(snapshot.first.remoteAudioAvailableEvents == 1)
          #expect(snapshot.second.remoteAudioAvailableEvents == 1)
          #expect(snapshot.relayErrors.isEmpty)
          #expect(snapshot.first.failures.isEmpty)
          #expect(snapshot.second.failures.isEmpty)
        }

        for entry in links { await entry.link.close() }
        for entry in links {
          #expect(await entry.link.waitUntilClosed())
          let closed = await entry.link.snapshot()
          #expect(closed.first.remoteVideoTrackIDs.isEmpty)
          #expect(closed.second.remoteVideoTrackIDs.isEmpty)
          #expect(closed.first.remoteAudioTrackID == nil)
          #expect(closed.second.remoteAudioTrackID == nil)
          #expect(closed.first.remoteVideoTrackRemoveEvents == 4)
          #expect(closed.second.remoteVideoTrackRemoveEvents == 4)
          #expect(closed.first.remoteAudioRemovedEvents == 1)
          #expect(closed.second.remoteAudioRemovedEvents == 1)
          await entry.link.expectClosedOperationsFail()
        }
      } catch {
        for entry in links { await entry.link.close() }
        for participant in participants {
          participant.factory.close()
        }
        throw error
      }

      for participant in participants {
        participant.factory.close()
      }
    }
  }
}

private struct NativeV3RealParticipant: Sendable {
  let id: ClipLiveShareNativeV3ParticipantID
  let factory: ClipLiveShareNativeV3WebRTCTransportFactory

  init(
    byte: UInt8,
    remoteAudioPlaybackEnabled: Bool = false
  ) throws {
    id = try .init(
      bytes: Data(
        repeating: byte,
        count: ClipLiveShareNativeV3.participantIDByteCount
      )
    )
    factory = try .init(
      configuration: .init(
        peer: .init(
          iceServers: [],
          resourceLimits: .init(negotiationTimeout: 10),
          videoCodec: .vp8
        ),
        remoteParticipantAudioPlaybackEnabled:
          remoteAudioPlaybackEnabled
      )
    )
  }
}

private enum NativeV3RealLinkSide: Sendable {
  case first
  case second

  var opposite: Self {
    switch self {
    case .first: .second
    case .second: .first
    }
  }
}

private struct NativeV3RealEndpointSnapshot: Sendable, CustomStringConvertible {
  var connectionState: WebRTCPeerConnectionState = .new
  var controlState: WebRTCControlDataChannelState = .connecting
  var localDescriptions: [WebRTCSessionDescription] = []
  var localICECandidateCount = 0
  var controlMessages: [Data] = []
  var remoteVideoTrackIDs: Set<String> = []
  var remoteAudioTrackID: String?
  var remoteVideoTrackAddEvents = 0
  var remoteVideoTrackRemoveEvents = 0
  var remoteAudioAvailableEvents = 0
  var remoteAudioRemovedEvents = 0
  var failures: [String] = []
  var eventStreamFinished = false

  var description: String {
    "connection=\(connectionState.rawValue), "
      + "control=\(controlState.rawValue), "
      + "descriptions=\(localDescriptions.map(\.kind.rawValue)), "
      + "ice=\(localICECandidateCount), "
      + "messages=\(controlMessages.count), "
      + "videoTracks=\(remoteVideoTrackIDs.count), "
      + "audio=\(remoteAudioTrackID != nil), "
      + "videoAddRemove=\(remoteVideoTrackAddEvents)/"
      + "\(remoteVideoTrackRemoveEvents), "
      + "audioAddRemove=\(remoteAudioAvailableEvents)/"
      + "\(remoteAudioRemovedEvents), "
      + "failures=\(failures), "
      + "finished=\(eventStreamFinished)"
  }
}

private struct NativeV3RealLinkSnapshot: Sendable, CustomStringConvertible {
  var first = NativeV3RealEndpointSnapshot()
  var second = NativeV3RealEndpointSnapshot()
  var relayErrors: [String] = []

  var isReady: Bool {
    first.connectionState == .connected
      && second.connectionState == .connected
      && first.controlState == .open
      && second.controlState == .open
      && first.remoteVideoTrackIDs.count == 4
      && second.remoteVideoTrackIDs.count == 4
      && first.remoteAudioTrackID != nil
      && second.remoteAudioTrackID != nil
      && first.failures.isEmpty
      && second.failures.isEmpty
      && relayErrors.isEmpty
  }

  var eventStreamsFinished: Bool {
    first.eventStreamFinished && second.eventStreamFinished
  }

  var description: String {
    "first={\(first)}, second={\(second)}, relayErrors=\(relayErrors)"
  }
}

private actor NativeV3RealLinkRelay {
  private let firstTransport: any ClipLiveShareNativeV3PeerLinkTransport
  private let secondTransport: any ClipLiveShareNativeV3PeerLinkTransport
  private var state = NativeV3RealLinkSnapshot()

  init(
    firstTransport: any ClipLiveShareNativeV3PeerLinkTransport,
    secondTransport: any ClipLiveShareNativeV3PeerLinkTransport
  ) {
    self.firstTransport = firstTransport
    self.secondTransport = secondTransport
  }

  func receive(
    _ event: ClipLiveShareNativeV3PeerLinkTransportEvent,
    from side: NativeV3RealLinkSide
  ) async {
    mutate(side) { endpoint in
      switch event {
      case let .localNegotiation(.sessionDescription(description)):
        endpoint.localDescriptions.append(description)
      case .localNegotiation(.iceCandidate):
        endpoint.localICECandidateCount += 1
      case let .connectionStateChanged(connectionState):
        endpoint.connectionState = connectionState
      case let .controlChannelStateChanged(controlState):
        endpoint.controlState = controlState
      case let .controlMessageReceived(data):
        endpoint.controlMessages.append(data)
      case let .remoteVideoTrackAdded(trackID):
        endpoint.remoteVideoTrackAddEvents += 1
        endpoint.remoteVideoTrackIDs.insert(trackID.rawValue)
      case let .remoteVideoTrackRemoved(trackID):
        endpoint.remoteVideoTrackRemoveEvents += 1
        endpoint.remoteVideoTrackIDs.remove(trackID.rawValue)
      case let .remoteParticipantAudioAvailable(trackID):
        endpoint.remoteAudioAvailableEvents += 1
        endpoint.remoteAudioTrackID = trackID
      case let .remoteParticipantAudioRemoved(trackID):
        endpoint.remoteAudioRemovedEvents += 1
        if endpoint.remoteAudioTrackID == trackID {
          endpoint.remoteAudioTrackID = nil
        }
      case let .failed(message):
        endpoint.failures.append(message)
      case .negotiationNeeded, .routeChanged, .statisticsChanged,
           .iceGatheringDiagnostic:
        break
      }
    }

    guard case let .localNegotiation(payload) = event else { return }
    let remoteTransport =
      side == .first ? secondTransport : firstTransport
    do {
      switch payload {
      case let .sessionDescription(description):
        try await remoteTransport.applyRemoteDescription(description)
      case let .iceCandidate(candidate):
        try await remoteTransport.addRemoteICECandidate(candidate)
      }
    } catch {
      state.relayErrors.append(
        "\(side) -> \(side.opposite): \(error.localizedDescription)"
      )
    }
  }

  func streamFinished(_ side: NativeV3RealLinkSide) {
    mutate(side) { $0.eventStreamFinished = true }
  }

  func snapshot() -> NativeV3RealLinkSnapshot { state }

  private func mutate(
    _ side: NativeV3RealLinkSide,
    _ body: (inout NativeV3RealEndpointSnapshot) -> Void
  ) {
    switch side {
    case .first:
      body(&state.first)
    case .second:
      body(&state.second)
    }
  }
}

private final class NativeV3RealLink: @unchecked Sendable {
  private let firstTransport: any ClipLiveShareNativeV3PeerLinkTransport
  private let secondTransport: any ClipLiveShareNativeV3PeerLinkTransport
  private let relay: NativeV3RealLinkRelay
  private let firstPump: Task<Void, Never>
  private let secondPump: Task<Void, Never>
  private let closeLock = NSLock()
  private var didClose = false

  init(
    first: NativeV3RealParticipant,
    second: NativeV3RealParticipant
  ) async throws {
    let key = try ClipLiveShareNativeV3PeerLinkKey(first.id, second.id)
    let firstConfiguration = try ClipLiveShareNativeV3PeerLinkConfiguration(
      key: key,
      localParticipantID: first.id
    )
    let secondConfiguration = try ClipLiveShareNativeV3PeerLinkConfiguration(
      key: key,
      localParticipantID: second.id
    )
    firstTransport = try await first.factory.makeTransport(
      configuration: firstConfiguration
    )
    secondTransport = try await second.factory.makeTransport(
      configuration: secondConfiguration
    )
    relay = NativeV3RealLinkRelay(
      firstTransport: firstTransport,
      secondTransport: secondTransport
    )

    let firstEvents = await firstTransport.events()
    let secondEvents = await secondTransport.events()
    let relay = relay
    firstPump = Task {
      for await event in firstEvents {
        await relay.receive(event, from: .first)
      }
      await relay.streamFinished(.first)
    }
    secondPump = Task {
      for await event in secondEvents {
        await relay.receive(event, from: .second)
      }
      await relay.streamFinished(.second)
    }
  }

  func start() async throws {
    // The canonical answerer starts first. The offerer then emits the only
    // initial offer and both sides relay every trickled ICE candidate through
    // the same transport-neutral event contract production uses.
    try await secondTransport.start()
    try await firstTransport.start()
  }

  func send(_ data: Data, from side: NativeV3RealLinkSide) async throws {
    switch side {
    case .first:
      try await firstTransport.sendControlMessage(data)
    case .second:
      try await secondTransport.sendControlMessage(data)
    }
  }

  func snapshot() async -> NativeV3RealLinkSnapshot {
    await relay.snapshot()
  }

  func waitUntilReady() async -> Bool {
    await waitUntil { $0.isReady }
  }

  func waitUntilClosed() async -> Bool {
    await waitUntil(timeout: .seconds(2)) { $0.eventStreamsFinished }
  }

  func waitUntil(
    timeout: Duration = .seconds(10),
    condition: @escaping @Sendable (NativeV3RealLinkSnapshot) -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition(await relay.snapshot()) { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition(await relay.snapshot())
  }

  func close() async {
    let shouldClose = closeLock.withLock { () -> Bool in
      guard !didClose else { return false }
      didClose = true
      return true
    }
    guard shouldClose else { return }
    await firstTransport.close()
    await secondTransport.close()
    await firstPump.value
    await secondPump.value
  }

  func expectClosedOperationsFail() async {
    for transport in [firstTransport, secondTransport] {
      do {
        try await transport.sendControlMessage(Data("after-close".utf8))
        Issue.record("Closed production transport accepted control data")
      } catch {
        #expect(
          error as? ClipLiveShareNativeV3WebRTCPeerLinkError
            == .transportClosed
        )
      }
    }
  }
}

private func nativeV3MediaSections(in sdp: String) -> [String: Int] {
  var sections: [String: Int] = [:]
  for rawLine in sdp.split(
    omittingEmptySubsequences: true,
    whereSeparator: \.isNewline
  ) {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    guard line.lowercased().hasPrefix("m=") else { continue }
    if let media = line.dropFirst(2).split(whereSeparator: \.isWhitespace).first {
      sections[String(media).lowercased(), default: 0] += 1
    }
  }
  return sections
}

private enum NativeV3PlayoutToneError: Error {
  case blockBuffer(OSStatus)
  case fillBlockBuffer(OSStatus)
  case format(OSStatus)
  case sample(OSStatus)
}

/// A quiet 10 ms stereo tone. It is intentionally audible to the mixer but
/// effectively unobtrusive if this hardware-backed acceptance test uses the
/// current Mac's default output device.
private func makeNativeV3PlayoutToneSample() throws -> CMSampleBuffer {
  let sampleRate = 48_000
  let frameCount = sampleRate / 100
  let channelCount: UInt32 = 2
  var samples = [Float](
    repeating: 0,
    count: frameCount * Int(channelCount)
  )
  for frame in 0..<frameCount {
    let phase = 2 * Double.pi * 440 * Double(frame) / Double(sampleRate)
    let value = Float(sin(phase)) * 0.01
    samples[frame * 2] = value
    samples[frame * 2 + 1] = value
  }

  let byteCount = samples.count * MemoryLayout<Float>.size
  var blockBuffer: CMBlockBuffer?
  let blockStatus = CMBlockBufferCreateWithMemoryBlock(
    allocator: kCFAllocatorDefault,
    memoryBlock: nil,
    blockLength: byteCount,
    blockAllocator: kCFAllocatorDefault,
    customBlockSource: nil,
    offsetToData: 0,
    dataLength: byteCount,
    flags: 0,
    blockBufferOut: &blockBuffer
  )
  guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
    throw NativeV3PlayoutToneError.blockBuffer(blockStatus)
  }
  let fillStatus = samples.withUnsafeBytes { bytes in
    CMBlockBufferReplaceDataBytes(
      with: bytes.baseAddress!,
      blockBuffer: blockBuffer,
      offsetIntoDestination: 0,
      dataLength: byteCount
    )
  }
  guard fillStatus == kCMBlockBufferNoErr else {
    throw NativeV3PlayoutToneError.fillBlockBuffer(fillStatus)
  }

  let bytesPerFrame = channelCount * UInt32(MemoryLayout<Float>.size)
  var description = AudioStreamBasicDescription(
    mSampleRate: Double(sampleRate),
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: bytesPerFrame,
    mFramesPerPacket: 1,
    mBytesPerFrame: bytesPerFrame,
    mChannelsPerFrame: channelCount,
    mBitsPerChannel: 32,
    mReserved: 0
  )
  var formatDescription: CMAudioFormatDescription?
  let formatStatus = CMAudioFormatDescriptionCreate(
    allocator: kCFAllocatorDefault,
    asbd: &description,
    layoutSize: 0,
    layout: nil,
    magicCookieSize: 0,
    magicCookie: nil,
    extensions: nil,
    formatDescriptionOut: &formatDescription
  )
  guard formatStatus == noErr, let formatDescription else {
    throw NativeV3PlayoutToneError.format(formatStatus)
  }

  var sampleBuffer: CMSampleBuffer?
  let sampleStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
    allocator: kCFAllocatorDefault,
    dataBuffer: blockBuffer,
    dataReady: true,
    makeDataReadyCallback: nil,
    refcon: nil,
    formatDescription: formatDescription,
    sampleCount: frameCount,
    presentationTimeStamp: .zero,
    packetDescriptions: nil,
    sampleBufferOut: &sampleBuffer
  )
  guard sampleStatus == noErr, let sampleBuffer else {
    throw NativeV3PlayoutToneError.sample(sampleStatus)
  }
  return sampleBuffer
}
