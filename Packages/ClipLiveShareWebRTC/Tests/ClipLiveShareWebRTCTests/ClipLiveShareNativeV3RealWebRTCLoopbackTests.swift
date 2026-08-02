import AudioToolbox
import ClipCapture
import ClipLiveShare
import CoreMedia
import Foundation
import Testing
@preconcurrency import WebRTC

@testable import ClipLiveShareWebRTC

extension NativeMediaResourceTests {
  @Suite("Native v3 production WebRTC loopback")
  struct ClipLiveShareNativeV3RealWebRTCLoopbackTests {
    @Test(
      "native offerer interoperates with browser-like receive-only peer",
      .timeLimit(.minutes(1))
    )
    func nativeOffererToBrowserReceiveOnly() async throws {
      try await assertBrowserLikeReceiveOnlyPair(
        nativeByte: 0x10,
        browserByte: 0x20,
        expectedOfferer: .native
      )
    }

    @Test(
      "browser-like receive-only offerer interoperates with native answerer",
      .timeLimit(.minutes(1))
    )
    func browserReceiveOnlyOffererToNative() async throws {
      try await assertBrowserLikeReceiveOnlyPair(
        nativeByte: 0x20,
        browserByte: 0x10,
        expectedOfferer: .browser
      )
    }

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

    private func assertBrowserLikeReceiveOnlyPair(
      nativeByte: UInt8,
      browserByte: UInt8,
      expectedOfferer: NativeV3BrowserOfferer
    ) async throws {
      let native = try NativeV3RealParticipant(byte: nativeByte)
      let browserID = try ClipLiveShareNativeV3ParticipantID(
        bytes: Data(
          repeating: browserByte,
          count: ClipLiveShareNativeV3.participantIDByteCount
        )
      )
      let link = try await NativeV3BrowserReceiveOnlyLink(
        native: native,
        browserID: browserID
      )

      do {
        try await link.start()
        let ready = await link.waitUntilReady()
        let readySnapshot = await link.snapshot()
        #expect(
          ready,
          Comment(
            rawValue:
              "Native/browser pair did not become ready: \(readySnapshot)"
          )
        )
        guard ready else {
          await link.close()
          native.factory.close()
          return
        }

        #expect(readySnapshot.browser.offerer == expectedOfferer)
        #expect(readySnapshot.native.connectionState == .connected)
        #expect(readySnapshot.browser.connectionState == .connected)
        #expect(readySnapshot.native.controlState == .open)
        #expect(readySnapshot.browser.controlState == .open)
        #expect(readySnapshot.browser.controlChannelIsOrdered)
        #expect(
          readySnapshot.browser.controlChannelLabel
            == ClipLiveShareNativeV3.controlDataChannelLabel
        )
        #expect(readySnapshot.browser.remoteVideoTrackCount == 4)
        #expect(readySnapshot.browser.remoteAudioTrackCount == 1)
        #expect(readySnapshot.browser.mediaTransceiverCount == 5)
        #expect(readySnapshot.browser.outboundMediaTrackCount == 0)
        #expect(readySnapshot.native.remoteVideoTrackIDs.isEmpty)
        #expect(readySnapshot.native.remoteAudioTrackID == nil)
        #expect(readySnapshot.native.remoteVideoTrackAddEvents == 0)
        #expect(readySnapshot.native.remoteAudioAvailableEvents == 0)
        #expect(readySnapshot.native.failures.isEmpty)
        #expect(readySnapshot.browser.failures.isEmpty)
        #expect(readySnapshot.relayErrors.isEmpty)

        let browserLocal = try #require(
          readySnapshot.browser.localDescriptions.last
        )
        let browserRemote = try #require(
          readySnapshot.browser.remoteDescriptions.last
        )
        let offer = expectedOfferer == .browser
          ? browserLocal
          : browserRemote
        let answer = expectedOfferer == .browser
          ? browserRemote
          : browserLocal
        #expect(offer.kind == .offer)
        #expect(answer.kind == .answer)
        for description in [offer, answer] {
          let sections = nativeV3MediaSections(in: description.sdp)
          #expect(sections["video"] == 4)
          #expect(sections["audio"] == 1)
          #expect(sections["application"] == 1)
          #expect(nativeV3NamedVideoCodecs(in: description.sdp) == ["VP8"])
        }
        let browserDirections = nativeV3MediaDirections(
          in: browserLocal.sdp
        )
        #expect(browserDirections["video"] == ["recvonly"])
        #expect(browserDirections["audio"] == ["recvonly"])

        let snapshot = try ClipLiveShareNativeV3SourceSnapshot(
          sessionID: ClipLiveShareSessionID(
            rawValue: "browser-receive-only-loopback"
          ),
          membershipRevision: .init(rawValue: 1),
          ownerParticipantID: native.id,
          sourceRevision: .init(rawValue: 1),
          sources: []
        )
        let nativePayload = try ClipLiveShareMeshMediaControlCodec.encode(
          .sourceSnapshot(snapshot)
        )
        try await link.sendFromNative(nativePayload)

        let browserSnapshot = try ClipLiveShareNativeV3SourceSnapshot(
          sessionID: snapshot.sessionID,
          membershipRevision: snapshot.membershipRevision,
          ownerParticipantID: browserID,
          sourceRevision: .init(rawValue: 1),
          sources: []
        )
        let browserPayload = try ClipLiveShareMeshMediaControlCodec.encode(
          .sourceSnapshot(browserSnapshot)
        )
        try link.sendFromBrowser(browserPayload)
        let delivered = await link.waitUntil {
          $0.browser.controlMessages == [nativePayload]
            && $0.native.controlMessages == [browserPayload]
        }
        let deliveredSnapshot = await link.snapshot()
        #expect(
          delivered,
          Comment(
            rawValue:
              "Source snapshots did not cross ordered control: "
              + "\(deliveredSnapshot)"
          )
        )
        #expect(
          try ClipLiveShareMeshMediaControlCodec.decode(
            deliveredSnapshot.browser.controlMessages[0]
          ) == .sourceSnapshot(snapshot)
        )
        #expect(
          try ClipLiveShareMeshMediaControlCodec.decode(
            deliveredSnapshot.native.controlMessages[0]
          ) == .sourceSnapshot(browserSnapshot)
        )

        await link.close()
        #expect(await link.waitUntilClosed())
      } catch {
        await link.close()
        native.factory.close()
        throw error
      }

      native.factory.close()
    }
  }
}

private enum NativeV3BrowserOfferer: String, Sendable {
  case native
  case browser
}

private struct NativeV3BrowserEndpointSnapshot: Sendable,
  CustomStringConvertible
{
  let offerer: NativeV3BrowserOfferer
  var connectionState: WebRTCPeerConnectionState = .new
  var controlState: WebRTCControlDataChannelState = .connecting
  var controlChannelLabel: String?
  var controlChannelIsOrdered = false
  var localDescriptions: [WebRTCSessionDescription] = []
  var remoteDescriptions: [WebRTCSessionDescription] = []
  var localICECandidateCount = 0
  var controlMessages: [Data] = []
  var remoteVideoTrackCount = 0
  var remoteAudioTrackCount = 0
  var mediaTransceiverCount = 0
  var outboundMediaTrackCount = 0
  var failures: [String] = []
  var isClosed = false

  var description: String {
    "offerer=\(offerer.rawValue), "
      + "connection=\(connectionState.rawValue), "
      + "control=\(controlState.rawValue), "
      + "descriptions=\(localDescriptions.map(\.kind.rawValue)), "
      + "ice=\(localICECandidateCount), "
      + "messages=\(controlMessages.count), "
      + "video=\(remoteVideoTrackCount), "
      + "audio=\(remoteAudioTrackCount), "
      + "transceivers=\(mediaTransceiverCount), "
      + "outbound=\(outboundMediaTrackCount), "
      + "failures=\(failures), closed=\(isClosed)"
  }
}

private struct NativeV3BrowserLinkSnapshot: Sendable,
  CustomStringConvertible
{
  var native = NativeV3RealEndpointSnapshot()
  var browser: NativeV3BrowserEndpointSnapshot
  var relayErrors: [String] = []

  var isReady: Bool {
    native.connectionState == .connected
      && browser.connectionState == .connected
      && native.controlState == .open
      && browser.controlState == .open
      && browser.remoteVideoTrackCount == 4
      && browser.remoteAudioTrackCount == 1
      && browser.outboundMediaTrackCount == 0
      && native.remoteVideoTrackIDs.isEmpty
      && native.remoteAudioTrackID == nil
      && native.failures.isEmpty
      && browser.failures.isEmpty
      && relayErrors.isEmpty
  }

  var description: String {
    "native={\(native)}, browser={\(browser)}, relayErrors=\(relayErrors)"
  }
}

private actor NativeV3BrowserLinkState {
  private var native = NativeV3RealEndpointSnapshot()
  private var relayErrors: [String] = []

  func recordNative(
    _ event: ClipLiveShareNativeV3PeerLinkTransportEvent
  ) {
    switch event {
    case let .localNegotiation(.sessionDescription(description)):
      native.localDescriptions.append(description)
    case .localNegotiation(.iceCandidate):
      native.localICECandidateCount += 1
    case let .connectionStateChanged(state):
      native.connectionState = state
    case let .controlChannelStateChanged(state):
      native.controlState = state
    case let .controlMessageReceived(data):
      native.controlMessages.append(data)
    case let .remoteVideoTrackAdded(trackID):
      native.remoteVideoTrackAddEvents += 1
      native.remoteVideoTrackIDs.insert(trackID.rawValue)
    case let .remoteVideoTrackRemoved(trackID):
      native.remoteVideoTrackRemoveEvents += 1
      native.remoteVideoTrackIDs.remove(trackID.rawValue)
    case let .remoteParticipantAudioAvailable(trackID):
      native.remoteAudioAvailableEvents += 1
      native.remoteAudioTrackID = trackID
    case let .remoteParticipantAudioRemoved(trackID):
      native.remoteAudioRemovedEvents += 1
      if native.remoteAudioTrackID == trackID {
        native.remoteAudioTrackID = nil
      }
    case let .failed(message):
      native.failures.append(message)
    case .negotiationNeeded, .routeChanged, .statisticsChanged,
         .iceGatheringDiagnostic:
      break
    }
  }

  func finishNativeEvents() {
    native.eventStreamFinished = true
  }

  func recordRelayError(_ error: any Error) {
    relayErrors.append(error.localizedDescription)
  }

  func snapshot(
    browser: NativeV3BrowserEndpointSnapshot
  ) -> NativeV3BrowserLinkSnapshot {
    .init(
      native: native,
      browser: browser,
      relayErrors: relayErrors
    )
  }
}

private final class NativeV3BrowserReceiveOnlyLink: @unchecked Sendable {
  private let nativeTransport: any ClipLiveShareNativeV3PeerLinkTransport
  private let browser: NativeV3BrowserReceiveOnlyEndpoint
  private let state: NativeV3BrowserLinkState
  private let nativePump: Task<Void, Never>
  private let closeLock = NSLock()
  private var didClose = false

  init(
    native: NativeV3RealParticipant,
    browserID: ClipLiveShareNativeV3ParticipantID
  ) async throws {
    let key = try ClipLiveShareNativeV3PeerLinkKey(native.id, browserID)
    let configuration = try ClipLiveShareNativeV3PeerLinkConfiguration(
      key: key,
      localParticipantID: native.id
    )
    nativeTransport = try await native.factory.makeTransport(
      configuration: configuration
    )
    let offerer: NativeV3BrowserOfferer =
      configuration.role == .offerer ? .native : .browser
    browser = try NativeV3BrowserReceiveOnlyEndpoint(offerer: offerer)
    state = NativeV3BrowserLinkState()

    let nativeTransport = nativeTransport
    let browser = browser
    let state = state
    browser.setNegotiationSink { payload in
      Task {
        do {
          switch payload {
          case let .sessionDescription(description):
            try await nativeTransport.applyRemoteDescription(description)
          case let .iceCandidate(candidate):
            try await nativeTransport.addRemoteICECandidate(candidate)
          }
        } catch {
          await state.recordRelayError(error)
        }
      }
    }

    let events = await nativeTransport.events()
    nativePump = Task {
      for await event in events {
        await state.recordNative(event)
        guard case let .localNegotiation(payload) = event else { continue }
        do {
          switch payload {
          case let .sessionDescription(description):
            try await browser.applyRemoteDescription(description)
          case let .iceCandidate(candidate):
            try await browser.addRemoteICECandidate(candidate)
          }
        } catch {
          await state.recordRelayError(error)
        }
      }
      await state.finishNativeEvents()
    }
  }

  func start() async throws {
    try await nativeTransport.start()
    try await browser.start()
  }

  func sendFromNative(_ data: Data) async throws {
    try await nativeTransport.sendControlMessage(data)
  }

  func sendFromBrowser(_ data: Data) throws {
    try browser.sendControlMessage(data)
  }

  func snapshot() async -> NativeV3BrowserLinkSnapshot {
    await state.snapshot(browser: browser.snapshot())
  }

  func waitUntilReady() async -> Bool {
    await waitUntil { $0.isReady }
  }

  func waitUntilClosed() async -> Bool {
    await waitUntil(timeout: .seconds(2)) {
      $0.native.eventStreamFinished && $0.browser.isClosed
    }
  }

  func waitUntil(
    timeout: Duration = .seconds(10),
    condition: @escaping @Sendable (NativeV3BrowserLinkSnapshot) -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition(await snapshot()) { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition(await snapshot())
  }

  func close() async {
    let shouldClose = closeLock.withLock { () -> Bool in
      guard !didClose else { return false }
      didClose = true
      return true
    }
    guard shouldClose else { return }
    browser.close()
    await nativeTransport.close()
    await nativePump.value
  }
}

private final class NativeV3BrowserPeerDelegate:
  NSObject,
  RTCPeerConnectionDelegate,
  RTCDataChannelDelegate,
  @unchecked Sendable
{
  enum Event: @unchecked Sendable {
    case localICECandidate(RTCIceCandidate)
    case connectionState(RTCPeerConnectionState)
    case dataChannel(RTCDataChannel)
    case dataChannelState(RTCDataChannel)
    case data(RTCDataChannel, Data)
    case receiverChanged
    case failure(String)
  }

  private let lock = NSLock()
  private var handler: (@Sendable (Event) -> Void)?

  func attach(_ handler: @escaping @Sendable (Event) -> Void) {
    lock.withLock { self.handler = handler }
  }

  func detach() {
    lock.withLock { handler = nil }
  }

  private func emit(_ event: Event) {
    lock.withLock { handler }?(event)
  }

  func peerConnection(
    _: RTCPeerConnection,
    didChange _: RTCSignalingState
  ) {}

  func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
  func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
  func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
  func peerConnection(_: RTCPeerConnection, didChange _: RTCIceConnectionState) {}
  func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}

  func peerConnection(
    _: RTCPeerConnection,
    didGenerate candidate: RTCIceCandidate
  ) {
    emit(.localICECandidate(candidate))
  }

  func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}

  func peerConnection(
    _: RTCPeerConnection,
    didOpen dataChannel: RTCDataChannel
  ) {
    emit(.dataChannel(dataChannel))
  }

  func peerConnection(
    _: RTCPeerConnection,
    didChange newState: RTCPeerConnectionState
  ) {
    emit(.connectionState(newState))
  }

  func peerConnection(
    _: RTCPeerConnection,
    didAdd _: RTCRtpReceiver,
    streams _: [RTCMediaStream]
  ) {
    emit(.receiverChanged)
  }

  func peerConnection(
    _: RTCPeerConnection,
    didRemove _: RTCRtpReceiver
  ) {
    emit(.receiverChanged)
  }

  func peerConnection(
    _: RTCPeerConnection,
    didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent
  ) {
    emit(.failure("ICE \(event.errorCode): \(event.errorText)"))
  }

  func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    emit(.dataChannelState(dataChannel))
  }

  func dataChannel(_: RTCDataChannel, didChangeBufferedAmount _: UInt64) {}

  func dataChannel(
    _ dataChannel: RTCDataChannel,
    didReceiveMessageWith buffer: RTCDataBuffer
  ) {
    emit(.data(dataChannel, buffer.data))
  }
}

private enum NativeV3BrowserEndpointError: Error, LocalizedError {
  case peerConnectionCreationFailed
  case transceiverCreationFailed
  case dataChannelCreationFailed
  case dataChannelUnavailable
  case descriptionCreationFailed(String)
  case descriptionApplicationFailed(String)
  case candidateApplicationFailed(String)

  var errorDescription: String? {
    switch self {
    case .peerConnectionCreationFailed:
      "Browser-like peer connection creation failed."
    case .transceiverCreationFailed:
      "Browser-like receive-only transceiver creation failed."
    case .dataChannelCreationFailed:
      "Browser-like control DataChannel creation failed."
    case .dataChannelUnavailable:
      "Browser-like control DataChannel is unavailable."
    case let .descriptionCreationFailed(message):
      "Browser-like description creation failed: \(message)"
    case let .descriptionApplicationFailed(message):
      "Browser-like description application failed: \(message)"
    case let .candidateApplicationFailed(message):
      "Browser-like ICE candidate application failed: \(message)"
    }
  }
}

private final class NativeV3BrowserReceiveOnlyEndpoint: @unchecked Sendable {
  typealias NegotiationSink = @Sendable (
    ClipLiveShareNativeV3PeerNegotiationPayload
  ) -> Void

  private let offerer: NativeV3BrowserOfferer
  private let factory: RTCPeerConnectionFactory
  private let connection: RTCPeerConnection
  private let delegate: NativeV3BrowserPeerDelegate
  private let lock = NSLock()
  private var state: NativeV3BrowserEndpointSnapshot
  private var controlChannel: RTCDataChannel?
  private var negotiationSink: NegotiationSink?
  private var remoteDescriptionApplied = false
  private var pendingRemoteCandidates: [RTCIceCandidate] = []
  private var didStart = false

  init(offerer: NativeV3BrowserOfferer) throws {
    self.offerer = offerer
    state = .init(offerer: offerer)
    factory = RTCPeerConnectionFactory(
      encoderFactory: RTCDefaultVideoEncoderFactory(),
      decoderFactory: RTCDefaultVideoDecoderFactory()
    )
    delegate = NativeV3BrowserPeerDelegate()

    let configuration = RTCConfiguration()
    configuration.sdpSemantics = .unifiedPlan
    configuration.bundlePolicy = .maxBundle
    configuration.rtcpMuxPolicy = .require
    configuration.continualGatheringPolicy = .gatherContinually
    configuration.iceTransportPolicy = .all
    configuration.iceServers = []
    guard let connection = factory.peerConnection(
      with: configuration,
      constraints: RTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: nil
      ),
      delegate: delegate
    ) else {
      throw NativeV3BrowserEndpointError.peerConnectionCreationFailed
    }
    self.connection = connection
    delegate.attach { [weak self] event in
      self?.handle(event)
    }

    if offerer == .browser {
      let videoCodecs = factory
        .rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        .codecs
        .filter { $0.name.caseInsensitiveCompare("VP8") == .orderedSame }
      let audioCodecs = factory
        .rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindAudio)
        .codecs
        .filter { $0.name.caseInsensitiveCompare("opus") == .orderedSame }
      guard !videoCodecs.isEmpty, !audioCodecs.isEmpty else {
        throw NativeV3BrowserEndpointError.transceiverCreationFailed
      }
      for _ in 0..<ClipLiveShareNativeV3.reservedVideoSlotsPerParticipant {
        let configuration = RTCRtpTransceiverInit()
        configuration.direction = .recvOnly
        guard let transceiver = connection.addTransceiver(
          of: .video,
          init: configuration
        ) else {
          throw NativeV3BrowserEndpointError.transceiverCreationFailed
        }
        try transceiver.setCodecPreferences(videoCodecs, error: ())
      }
      let configuration = RTCRtpTransceiverInit()
      configuration.direction = .recvOnly
      guard let transceiver = connection.addTransceiver(
        of: .audio,
        init: configuration
      ) else {
        throw NativeV3BrowserEndpointError.transceiverCreationFailed
      }
      try transceiver.setCodecPreferences(audioCodecs, error: ())

      let dataConfiguration = RTCDataChannelConfiguration()
      dataConfiguration.isOrdered = true
      dataConfiguration.maxPacketLifeTime = -1
      dataConfiguration.maxRetransmits = -1
      dataConfiguration.isNegotiated = false
      guard let dataChannel = connection.dataChannel(
        forLabel: ClipLiveShareNativeV3.controlDataChannelLabel,
        configuration: dataConfiguration
      ) else {
        throw NativeV3BrowserEndpointError.dataChannelCreationFailed
      }
      accept(dataChannel)
    }
    refreshMediaSnapshot()
  }

  func setNegotiationSink(_ sink: @escaping NegotiationSink) {
    lock.withLock { negotiationSink = sink }
  }

  func start() async throws {
    let shouldOffer = lock.withLock { () -> Bool in
      guard !didStart else { return false }
      didStart = true
      return offerer == .browser
    }
    guard shouldOffer else { return }
    let offer = try await createDescription(type: .offer)
    try await setLocalDescription(offer)
    emitNegotiation(
      .sessionDescription(.init(kind: .offer, sdp: offer.sdp))
    )
  }

  func applyRemoteDescription(
    _ description: WebRTCSessionDescription
  ) async throws {
    let rtcDescription = RTCSessionDescription(
      type: description.kind == .offer ? .offer : .answer,
      sdp: description.sdp
    )
    try await setRemoteDescription(rtcDescription)
    lock.withLock {
      state.remoteDescriptions.append(description)
      remoteDescriptionApplied = true
    }
    let pending = lock.withLock { () -> [RTCIceCandidate] in
      let pending = pendingRemoteCandidates
      pendingRemoteCandidates.removeAll(keepingCapacity: true)
      return pending
    }
    for candidate in pending {
      try await add(candidate)
    }
    refreshMediaSnapshot()

    guard description.kind == .offer else { return }
    let answer = try await createDescription(type: .answer)
    try await setLocalDescription(answer)
    emitNegotiation(
      .sessionDescription(.init(kind: .answer, sdp: answer.sdp))
    )
  }

  func addRemoteICECandidate(_ candidate: WebRTCICECandidate) async throws {
    let rtcCandidate = RTCIceCandidate(
      sdp: candidate.candidate,
      sdpMLineIndex: candidate.sdpMLineIndex,
      sdpMid: candidate.sdpMid
    )
    let shouldQueue = lock.withLock { () -> Bool in
      guard !remoteDescriptionApplied else { return false }
      pendingRemoteCandidates.append(rtcCandidate)
      return true
    }
    if !shouldQueue {
      try await add(rtcCandidate)
    }
  }

  func sendControlMessage(_ data: Data) throws {
    let channel = lock.withLock { controlChannel }
    guard let channel, channel.readyState == .open else {
      throw NativeV3BrowserEndpointError.dataChannelUnavailable
    }
    guard channel.sendData(RTCDataBuffer(data: data, isBinary: true)) else {
      throw NativeV3BrowserEndpointError.dataChannelUnavailable
    }
  }

  func snapshot() -> NativeV3BrowserEndpointSnapshot {
    refreshMediaSnapshot()
    return lock.withLock { state }
  }

  func close() {
    let channel = lock.withLock { () -> RTCDataChannel? in
      guard !state.isClosed else { return nil }
      state.isClosed = true
      state.connectionState = .closed
      state.controlState = .closed
      let channel = controlChannel
      controlChannel = nil
      negotiationSink = nil
      return channel
    }
    channel?.delegate = nil
    channel?.close()
    delegate.detach()
    connection.delegate = nil
    connection.close()
  }

  private func handle(_ event: NativeV3BrowserPeerDelegate.Event) {
    switch event {
    case let .localICECandidate(candidate):
      lock.withLock { state.localICECandidateCount += 1 }
      emitNegotiation(
        .iceCandidate(
          .init(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
          )
        )
      )
    case let .connectionState(connectionState):
      lock.withLock {
        state.connectionState = switch connectionState {
        case .new: .new
        case .connecting: .connecting
        case .connected: .connected
        case .disconnected: .disconnected
        case .failed: .failed
        case .closed: .closed
        @unknown default: .failed
        }
      }
    case let .dataChannel(channel):
      accept(channel)
    case let .dataChannelState(channel):
      lock.withLock {
        guard channel === controlChannel else { return }
        state.controlState = Self.controlState(channel.readyState)
      }
    case let .data(channel, data):
      lock.withLock {
        guard channel === controlChannel else { return }
        state.controlMessages.append(data)
      }
    case .receiverChanged:
      refreshMediaSnapshot()
    case let .failure(message):
      lock.withLock { state.failures.append(message) }
    }
  }

  private func accept(_ channel: RTCDataChannel) {
    lock.withLock {
      guard
        channel.label == ClipLiveShareNativeV3.controlDataChannelLabel,
        channel.isOrdered,
        controlChannel == nil
      else {
        channel.close()
        state.failures.append("Unexpected browser-like DataChannel")
        return
      }
      controlChannel = channel
      channel.delegate = delegate
      state.controlChannelLabel = channel.label
      state.controlChannelIsOrdered = channel.isOrdered
      state.controlState = Self.controlState(channel.readyState)
    }
  }

  private func emitNegotiation(
    _ payload: ClipLiveShareNativeV3PeerNegotiationPayload
  ) {
    lock.withLock { negotiationSink }?(payload)
  }

  private func refreshMediaSnapshot() {
    let transceivers = connection.transceivers.filter {
      $0.mediaType == .video || $0.mediaType == .audio
    }
    let videoReceiverIDs = Set(
      transceivers.compactMap { transceiver -> String? in
        guard
          transceiver.mediaType == .video,
          transceiver.receiver.track is RTCVideoTrack
        else { return nil }
        return transceiver.receiver.receiverId
      }
    )
    let audioReceiverIDs = Set(
      transceivers.compactMap { transceiver -> String? in
        guard
          transceiver.mediaType == .audio,
          transceiver.receiver.track is RTCAudioTrack
        else { return nil }
        return transceiver.receiver.receiverId
      }
    )
    let outboundCount = transceivers.filter { $0.sender.track != nil }.count
    lock.withLock {
      state.remoteVideoTrackCount = videoReceiverIDs.count
      state.remoteAudioTrackCount = audioReceiverIDs.count
      state.mediaTransceiverCount = transceivers.count
      state.outboundMediaTrackCount = outboundCount
    }
  }

  private func createDescription(
    type: RTCSdpType
  ) async throws -> RTCSessionDescription {
    try await withCheckedThrowingContinuation { continuation in
      let completion:
        @Sendable (RTCSessionDescription?, (any Error)?) -> Void = {
          description, error in
          if let error {
            continuation.resume(
              throwing: NativeV3BrowserEndpointError
                .descriptionCreationFailed(error.localizedDescription)
            )
          } else if let description {
            continuation.resume(returning: description)
          } else {
            continuation.resume(
              throwing: NativeV3BrowserEndpointError
                .descriptionCreationFailed("no description")
            )
          }
        }
      let constraints = RTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: nil
      )
      if type == .offer {
        connection.offer(for: constraints, completionHandler: completion)
      } else {
        connection.answer(for: constraints, completionHandler: completion)
      }
    }
  }

  private func setLocalDescription(
    _ description: RTCSessionDescription
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.setLocalDescription(description) { [weak self] error in
        if let error {
          continuation.resume(
            throwing: NativeV3BrowserEndpointError
              .descriptionApplicationFailed(error.localizedDescription)
          )
          return
        }
        self?.lock.withLock {
          self?.state.localDescriptions.append(
            .init(
              kind: description.type == .offer ? .offer : .answer,
              sdp: description.sdp
            )
          )
        }
        continuation.resume()
      }
    }
  }

  private func setRemoteDescription(
    _ description: RTCSessionDescription
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.setRemoteDescription(description) { error in
        if let error {
          continuation.resume(
            throwing: NativeV3BrowserEndpointError
              .descriptionApplicationFailed(error.localizedDescription)
          )
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func add(_ candidate: RTCIceCandidate) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.add(candidate) { error in
        if let error {
          continuation.resume(
            throwing: NativeV3BrowserEndpointError
              .candidateApplicationFailed(error.localizedDescription)
          )
        } else {
          continuation.resume()
        }
      }
    }
  }

  private static func controlState(
    _ state: RTCDataChannelState
  ) -> WebRTCControlDataChannelState {
    switch state {
    case .connecting: .connecting
    case .open: .open
    case .closing: .closing
    case .closed: .closed
    @unknown default: .closed
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

private func nativeV3MediaDirections(in sdp: String) -> [String: Set<String>] {
  let normalized = sdp.replacingOccurrences(of: "\r\n", with: "\n")
  let lines = normalized.components(separatedBy: "\n")
  var result: [String: Set<String>] = [:]
  var media: String?
  for line in lines {
    if line.hasPrefix("m=") {
      media = line.dropFirst(2).split(whereSeparator: \.isWhitespace).first.map(
        String.init
      )
    } else if let media,
      ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains(line)
    {
      result[media, default: []].insert(String(line.dropFirst(2)))
    }
  }
  return result
}

private func nativeV3NamedVideoCodecs(in sdp: String) -> Set<String> {
  let normalized = sdp.replacingOccurrences(of: "\r\n", with: "\n")
  let namedCodecs: Set<String> = ["AV1", "VP9", "VP8", "H264"]
  var inVideo = false
  var result: Set<String> = []
  for line in normalized.components(separatedBy: "\n") {
    if line.hasPrefix("m=") {
      inVideo = line.hasPrefix("m=video ")
      continue
    }
    guard inVideo, line.hasPrefix("a=rtpmap:") else { continue }
    let codec = line
      .split(separator: " ", maxSplits: 1)
      .last?
      .split(separator: "/", maxSplits: 1)
      .first
      .map { String($0).uppercased() }
    if let codec, namedCodecs.contains(codec) {
      result.insert(codec)
    }
  }
  return result
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
