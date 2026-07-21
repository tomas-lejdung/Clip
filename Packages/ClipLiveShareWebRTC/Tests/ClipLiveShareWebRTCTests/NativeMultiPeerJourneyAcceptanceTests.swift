import ClipLiveShare
import Foundation
import Testing

@testable import ClipLiveShareWebRTC

@Suite("Native multi-peer journey acceptance", .serialized)
struct NativeMultiPeerJourneyAcceptanceTests {
  @Test("two compatible receivers keep four streams, stereo audio, and control after signaling")
  func simultaneousReceiversSurviveSignalingHandoff() async throws {
    let mesh = NativeAcceptancePeerMesh()
    let host = try WebRTCPeerHost(
      configuration: .init(
        iceServers: [],
        resourceLimits: .init(answerTimeout: 5),
        videoCodec: .vp8
      ),
      eventQueue: mesh.eventQueue,
      eventHandler: { [mesh] event in mesh.receive(hostEvent: event) }
    )
    mesh.host = host
    let nativeID = "native-clip-viewer"
    let browserProtocolID = "browser-protocol-viewer"
    let native = try mesh.makeViewer(id: nativeID)
    let browserProtocol = try mesh.makeViewer(id: browserProtocolID)
    defer {
      native.close()
      browserProtocol.close()
      host.close()
    }

    let descriptors = try host.slotSnapshots.prefix(4).map { slot in
      let descriptor = try ClipLiveShareStreamDescriptor(
        id: ClipLiveShareStreamID(rawValue: "acceptance-stream-\(slot.index)"),
        mediaTrackID: ClipLiveShareMediaTrackID(rawValue: slot.trackID),
        active: true,
        focused: slot.index == 0,
        appName: "Fixture \(slot.index + 1)",
        windowName: "Window \(slot.index + 1)",
        width: 1_280 + slot.index * 2,
        height: 720 + slot.index * 2,
        order: slot.index
      )
      try host.activateSlot(slot.index, metadata: descriptor)
      return descriptor
    }
    #expect(descriptors.count == WebRTCRuntimeIdentity.maximumVideoSlots)
    host.setSystemAudioEnabled(true)

    let nativeNegotiation = try await connect(
      host: host,
      viewer: native,
      viewerID: nativeID,
      mesh: mesh
    )
    let browserNegotiation = try await connect(
      host: host,
      viewer: browserProtocol,
      viewerID: browserProtocolID,
      mesh: mesh
    )
    for negotiation in [nativeNegotiation, browserNegotiation] {
      #expect(negotiation.offer.sdp.localizedCaseInsensitiveContains("opus/48000/2"))
      #expect(negotiation.answer.sdp.localizedCaseInsensitiveContains("stereo=1"))
    }

    let sessionID = try ClipLiveShareSessionID(
      rawValue: "native-multi-peer-acceptance"
    )
    let manifest = try ClipLiveShareStreamManifest(
      sessionID: sessionID,
      streams: descriptors,
      maximumStreams: WebRTCRuntimeIdentity.maximumVideoSlots
    )
    let manifestPayload = try ClipLiveShareMessageCodec.encodeInner(.manifest(manifest))
    #expect(host.sendControl(manifestPayload, to: nativeID))
    #expect(host.sendControl(manifestPayload, to: browserProtocolID))
    native.applyRemoteStreamManifest(manifest)
    browserProtocol.applyRemoteStreamManifest(manifest)

    #expect(
      await nativeAcceptanceEventually {
        native.remoteVideoStreams.map(\.id) == descriptors.map(\.id)
          && browserProtocol.remoteVideoStreams.map(\.id) == descriptors.map(\.id)
          && mesh.snapshot(for: nativeID).systemAudioAvailableCount == 1
          && mesh.snapshot(for: browserProtocolID).systemAudioAvailableCount == 1
          && mesh.snapshot(for: nativeID).viewerMessages.contains(manifestPayload)
          && mesh.snapshot(for: browserProtocolID).viewerMessages.contains(manifestPayload)
      })
    #expect(native.remoteVideoStreams.map(\.mediaTrackID) == descriptors.map(\.mediaTrackID))
    #expect(
      browserProtocol.remoteVideoStreams.map(\.mediaTrackID)
        == descriptors.map(\.mediaTrackID)
    )
    let nativeAudioTrackID = try #require(native.snapshot.systemAudioTrackID)
    let browserAudioTrackID = try #require(browserProtocol.snapshot.systemAudioTrackID)

    for (viewerID, viewer) in [
      (nativeID, native),
      (browserProtocolID, browserProtocol),
    ] {
      let offer = try await host.createReoffer(for: viewerID)
      let answer = try await viewer.answer(offer)
      try await host.setRemoteAnswer(answer, for: viewerID)
    }
    #expect(mesh.snapshot(for: nativeID).systemAudioAvailableCount == 1)
    #expect(mesh.snapshot(for: browserProtocolID).systemAudioAvailableCount == 1)
    #expect(native.snapshot.systemAudioTrackID == nativeAudioTrackID)
    #expect(browserProtocol.snapshot.systemAudioTrackID == browserAudioTrackID)

    // From this point no SDP or ICE can cross the test signaling bridge.
    // The reliable control DataChannels must remain fully peer-to-peer.
    mesh.endSignalingHandoff()
    let focusPayload = try ClipLiveShareMessageCodec.encodeInner(
      .focus(.init(sessionID: sessionID, streamID: descriptors[2].id))
    )
    #expect(host.sendControl(focusPayload, to: nativeID))
    #expect(host.sendControl(focusPayload, to: browserProtocolID))
    let viewerReply = Data("native-control-after-handoff".utf8)
    #expect(native.sendControl(viewerReply))
    #expect(
      await nativeAcceptanceEventually {
        mesh.snapshot(for: nativeID).viewerMessages.contains(focusPayload)
          && mesh.snapshot(for: browserProtocolID).viewerMessages.contains(focusPayload)
          && mesh.snapshot(for: nativeID).hostMessages.contains(viewerReply)
      })

    host.deactivateSlot(3)
    let reducedManifest = try ClipLiveShareStreamManifest(
      sessionID: sessionID,
      streams: Array(descriptors.prefix(3)),
      maximumStreams: WebRTCRuntimeIdentity.maximumVideoSlots
    )
    native.applyRemoteStreamManifest(reducedManifest)
    browserProtocol.applyRemoteStreamManifest(reducedManifest)
    #expect(
      await nativeAcceptanceEventually {
        native.remoteVideoStreams.map(\.id) == Array(descriptors.prefix(3)).map(\.id)
          && browserProtocol.remoteVideoStreams.map(\.id)
            == Array(descriptors.prefix(3)).map(\.id)
          && mesh.snapshot(for: nativeID).removedStreamIDs == [descriptors[3].id]
          && mesh.snapshot(for: browserProtocolID).removedStreamIDs
            == [descriptors[3].id]
      })
  }

  private func connect(
    host: WebRTCPeerHost,
    viewer: WebRTCPeerViewer,
    viewerID: String,
    mesh: NativeAcceptancePeerMesh
  ) async throws -> (offer: WebRTCSessionDescription, answer: WebRTCSessionDescription) {
    let offer = try await host.createOffer(for: viewerID)
    let answer = try await viewer.answer(offer)
    try await host.setRemoteAnswer(answer, for: viewerID)
    mesh.hostCanAcceptCandidates(for: viewerID)
    let ready = await nativeAcceptanceEventually {
      mesh.snapshot(for: viewerID).isConnectedAndControlOpen
    }
    if !ready {
      print("Native acceptance peer \(viewerID) did not connect: \(mesh.snapshot(for: viewerID))")
      print("Viewer snapshot: \(viewer.snapshot)")
      print("Host snapshots: \(host.viewerSnapshots)")
    }
    #expect(ready)
    return (offer, answer)
  }
}

private struct NativeAcceptancePeerSnapshot: Sendable {
  var hostConnected = false
  var viewerConnected = false
  var hostControlOpen = false
  var viewerControlOpen = false
  var hostMessages: [Data] = []
  var viewerMessages: [Data] = []
  var removedStreamIDs: [ClipLiveShareStreamID] = []
  var systemAudioAvailableCount = 0
  var errors: [String] = []

  var isConnectedAndControlOpen: Bool {
    hostConnected && viewerConnected && hostControlOpen && viewerControlOpen
  }
}

private final class NativeAcceptancePeerMesh: @unchecked Sendable {
  let eventQueue = DispatchQueue(
    label: "com.tomaslejdung.clip.tests.native-multi-peer-acceptance"
  )

  private let lock = NSLock()
  private weak var storedHost: WebRTCPeerHost?
  private var viewers: [String: WebRTCPeerViewer] = [:]
  private var snapshots: [String: NativeAcceptancePeerSnapshot] = [:]
  private var pendingViewerCandidates: [String: [WebRTCICECandidate]] = [:]
  private var hostCandidateReady: Set<String> = []
  private var signalingIsOpen = true

  var host: WebRTCPeerHost? {
    get { lock.withLock { storedHost } }
    set { lock.withLock { storedHost = newValue } }
  }

  func makeViewer(id: String) throws -> WebRTCPeerViewer {
    lock.withLock { snapshots[id] = NativeAcceptancePeerSnapshot() }
    do {
      let viewer = try WebRTCPeerViewer(
        configuration: .init(
          iceServers: [],
          resourceLimits: .init(answerTimeout: 5),
          systemAudioPlaybackEnabled: false
        ),
        eventQueue: eventQueue,
        eventHandler: { [weak self] event in
          self?.receive(viewerEvent: event, viewerID: id)
        }
      )
      lock.withLock { viewers[id] = viewer }
      return viewer
    } catch {
      lock.withLock { snapshots[id] = nil }
      throw error
    }
  }

  func snapshot(for viewerID: String) -> NativeAcceptancePeerSnapshot {
    lock.withLock { snapshots[viewerID] ?? NativeAcceptancePeerSnapshot() }
  }

  func endSignalingHandoff() {
    lock.withLock {
      signalingIsOpen = false
      pendingViewerCandidates.removeAll()
    }
  }

  func hostCanAcceptCandidates(for viewerID: String) {
    let values: ([WebRTCICECandidate], WebRTCPeerHost?) = lock.withLock {
      hostCandidateReady.insert(viewerID)
      let pending = pendingViewerCandidates.removeValue(forKey: viewerID) ?? []
      return (pending, storedHost)
    }
    guard let host = values.1 else { return }
    for candidate in values.0 {
      Task { [weak self] in
        do {
          try await host.addRemoteICECandidate(candidate, for: viewerID)
        } catch {
          self?.mutate(viewerID) { $0.errors.append("queued viewer candidate: \(error)") }
        }
      }
    }
  }

  func receive(hostEvent: WebRTCPeerHostEvent) {
    switch hostEvent {
    case .localICECandidate(let viewerID, let candidate):
      guard let viewer = lock.withLock({ signalingIsOpen ? viewers[viewerID] : nil })
      else { return }
      Task { [weak self] in
        do {
          try await viewer.addRemoteICECandidate(candidate)
        } catch {
          self?.mutate(viewerID) { $0.errors.append("host candidate: \(error)") }
        }
      }
    case .connectionStateChanged(let viewerID, let state):
      mutate(viewerID) { $0.hostConnected = state == .connected }
    case .controlDataChannelStateChanged(let viewerID, let state):
      mutate(viewerID) { $0.hostControlOpen = state == .open }
    case .controlMessageReceived(let viewerID, let data, _):
      mutate(viewerID) { $0.hostMessages.append(data) }
    case .error(let viewerID, let error):
      if let viewerID { mutate(viewerID) { $0.errors.append("host: \(error)") } }
    default:
      break
    }
  }

  private func receive(
    viewerEvent: WebRTCPeerViewerEvent,
    viewerID: String
  ) {
    switch viewerEvent {
    case .localICECandidate(let candidate):
      deliverViewerCandidate(candidate, viewerID: viewerID)
    case .connectionStateChanged(let state):
      mutate(viewerID) { $0.viewerConnected = state == .connected }
    case .controlDataChannelStateChanged(let state):
      mutate(viewerID) { $0.viewerControlOpen = state == .open }
    case .controlMessageReceived(let data, _):
      mutate(viewerID) { $0.viewerMessages.append(data) }
    case .remoteVideoStreamRemoved(let streamID):
      mutate(viewerID) { $0.removedStreamIDs.append(streamID) }
    case .systemAudioTrackAvailable:
      mutate(viewerID) { $0.systemAudioAvailableCount += 1 }
    case .error(let error):
      mutate(viewerID) { $0.errors.append("viewer: \(error)") }
    default:
      break
    }
  }

  private func deliverViewerCandidate(
    _ candidate: WebRTCICECandidate,
    viewerID: String
  ) {
    let host: WebRTCPeerHost? = lock.withLock {
      guard signalingIsOpen else { return nil }
      guard hostCandidateReady.contains(viewerID) else {
        pendingViewerCandidates[viewerID, default: []].append(candidate)
        return nil
      }
      return storedHost
    }
    guard let host else { return }
    Task { [weak self] in
      do {
        try await host.addRemoteICECandidate(candidate, for: viewerID)
      } catch {
        self?.mutate(viewerID) { $0.errors.append("viewer candidate: \(error)") }
      }
    }
  }

  private func mutate(
    _ viewerID: String,
    _ body: (inout NativeAcceptancePeerSnapshot) -> Void
  ) {
    lock.withLock {
      guard var value = snapshots[viewerID] else { return }
      body(&value)
      snapshots[viewerID] = value
    }
  }
}

private func nativeAcceptanceEventually(
  timeout: Duration = .seconds(8),
  condition: @escaping @Sendable () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return condition()
}
