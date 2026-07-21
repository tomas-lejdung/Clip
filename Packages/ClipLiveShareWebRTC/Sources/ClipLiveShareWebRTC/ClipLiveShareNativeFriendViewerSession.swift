import ClipLiveShare
import Foundation

/// The result of the signed Clip-to-Clip introduction. The rendezvous server
/// relays only opaque bytes and is released as soon as the WebRTC control
/// DataChannel is open.
public enum ClipLiveShareNativeFriendViewerSessionEvent: @unchecked Sendable {
  case connecting
  case rendezvousConnected(ClipNativeRendezvousTarget)
  case descriptorAccepted(ClipLiveShareSignedNativeSessionDescriptor)
  case awaitingHostApproval
  case authenticated(ClipLiveShareSessionID)
  case connectionStateChanged(WebRTCPeerConnectionState)
  case controlDataChannelStateChanged(WebRTCControlDataChannelState)
  case rendezvousHandoffCompleted
  case controlMessage(ClipLiveShareInnerMessage)
  case nativeControlMessage(Data)
  case remoteVideoStreamAdded(WebRTCRemoteVideoStream)
  case remoteVideoStreamUpdated(WebRTCRemoteVideoStream)
  case remoteVideoStreamRemoved(ClipLiveShareStreamID)
  case systemAudioTrackAvailable(String)
  case systemAudioTrackRemoved(String)
  case failed(ClipLiveShareNativeFriendViewerSessionError)
  case closed
}

public enum ClipLiveShareNativeFriendViewerSessionError: Error, Equatable,
  Sendable, LocalizedError
{
  case invalidConfiguration
  case connectionAlreadyActive
  case rendezvousUnavailable
  case hostUnavailable
  case descriptorRejected
  case descriptorReplayed
  case challengeRejected
  case admissionRejected(String?)
  case invalidSignalingMessage
  case unexpectedSignalingMessage
  case peerFailure(String)
  case controlChannelUnavailable
  case sessionClosed(String?)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The saved friend no longer matches this native rendezvous."
    case .connectionAlreadyActive:
      "This native viewer session is already active."
    case .rendezvousUnavailable:
      "Clip could not reach the friend's native rendezvous."
    case .hostUnavailable:
      "The friend is not currently sharing."
    case .descriptorRejected:
      "The share could not be verified as the saved friend."
    case .descriptorReplayed:
      "The native session descriptor was received more than once."
    case .challengeRejected:
      "The host admission challenge did not match this connection."
    case .admissionRejected(let reason):
      reason ?? "The host did not allow this device to join."
    case .invalidSignalingMessage:
      "The native rendezvous returned an invalid message."
    case .unexpectedSignalingMessage:
      "The native host returned a message at the wrong stage."
    case .peerFailure(let message):
      "The peer-to-peer viewer failed: \(message)"
    case .controlChannelUnavailable:
      "The peer-to-peer control channel is unavailable."
    case .sessionClosed(let reason):
      reason ?? "The host ended this Live Share."
    }
  }
}

protocol ClipLiveShareNativeFriendViewerTransport: Sendable {
  func nativeFriendEvents() async -> AsyncStream<ClipNativeRendezvousEvent>
  func nativeFriendAttachViewer(
    _ target: ClipNativeRendezvousTarget
  ) async throws -> ClipNativeRendezvousCapabilities
  func nativeFriendSend(_ payload: Data) async throws
  func nativeFriendCloseRoute(reason: String?) async
  func nativeFriendTeardown() async
}

extension ClipNativeRendezvousViewerTransport:
  ClipLiveShareNativeFriendViewerTransport
{
  func nativeFriendEvents() async -> AsyncStream<ClipNativeRendezvousEvent> {
    events()
  }

  func nativeFriendAttachViewer(
    _ target: ClipNativeRendezvousTarget
  ) async throws -> ClipNativeRendezvousCapabilities {
    try await attachViewer(target)
  }

  func nativeFriendSend(_ payload: Data) async throws {
    try await send(payload)
  }

  func nativeFriendCloseRoute(reason: String?) async {
    await closeRoute(reason: reason)
  }

  func nativeFriendTeardown() async { await teardown() }
}

protocol ClipLiveShareNativeFriendPeerViewer: AnyObject, Sendable {
  var remoteVideoStreams: [WebRTCRemoteVideoStream] { get }
  var snapshot: WebRTCPeerViewerSnapshot { get }

  func answer(
    _ offer: WebRTCSessionDescription
  ) async throws -> WebRTCSessionDescription
  func addRemoteICECandidate(_ candidate: WebRTCICECandidate) async throws
  func applyRemoteStreamManifest(_ manifest: ClipLiveShareStreamManifest)
  func sendControl(_ data: Data, isBinary: Bool) -> Bool
  func setSystemAudioPlaybackEnabled(_ enabled: Bool)
  func setSystemAudioVolume(_ volume: Double)
  func inboundStatisticsSnapshot() async throws
    -> WebRTCInboundStatisticsSnapshot
  func close()
}

extension WebRTCPeerViewer: ClipLiveShareNativeFriendPeerViewer {}

protocol ClipLiveShareNativeFriendPeerViewerFactory: Sendable {
  func makeViewer(
    configuration: WebRTCPeerViewerConfiguration,
    eventQueue: DispatchQueue,
    eventHandler: @escaping WebRTCPeerViewer.EventHandler
  ) throws -> any ClipLiveShareNativeFriendPeerViewer
}

private struct ClipLiveShareDefaultNativeFriendPeerViewerFactory:
  ClipLiveShareNativeFriendPeerViewerFactory
{
  func makeViewer(
    configuration: WebRTCPeerViewerConfiguration,
    eventQueue: DispatchQueue,
    eventHandler: @escaping WebRTCPeerViewer.EventHandler
  ) throws -> any ClipLiveShareNativeFriendPeerViewer {
    try WebRTCPeerViewer(
      configuration: configuration,
      eventQueue: eventQueue,
      eventHandler: eventHandler
    )
  }
}

/// A saved-friend viewer whose host identity is pinned before any WebRTC
/// negotiation occurs.
///
/// Wire sequence:
///
/// 1. Native rendezvous provides a signed, short-lived session descriptor.
/// 2. The viewer sends a fresh v1 ECDH key and receives an encrypted v2
///    challenge bound to that descriptor, route, key, session, and revision.
/// 3. The viewer signs the challenge with its persistent device identity.
/// 4. After explicit host approval, the existing encrypted v1 offer/answer/ICE
///    exchange establishes WebRTC. The rendezvous route is then closed.
public actor ClipLiveShareNativeFriendViewerSession {
  private enum Phase {
    case idle
    case connecting
    case waitingForDescriptor
    case waitingForChallenge
    case waitingForAdmission
    case negotiating
    case live
    case failed
    case closed
  }

  private enum OperationError: Error { case superseded }
  private enum MessageDelivery { case rendezvous, control }

  private let target: ClipNativeRendezvousTarget
  private let expectedHostIdentity: ClipLiveShareIdentityPublicKey
  private let viewerIdentitySigner: any ClipLiveShareIdentitySigner
  private let viewerDeviceName: String
  private let viewerConfiguration: WebRTCPeerViewerConfiguration
  private let transport: any ClipLiveShareNativeFriendViewerTransport
  private let peerViewerFactory: any ClipLiveShareNativeFriendPeerViewerFactory
  private let eventQueue: DispatchQueue
  private let now: @Sendable () throws -> ClipLiveShareNativeTimestamp

  private var operationGeneration: UInt64 = 0
  private var phase: Phase = .idle
  private var transportTask: Task<Void, Never>?
  private var routeID: ClipLiveShareRouteID?
  private var signedDescriptor: ClipLiveShareSignedNativeSessionDescriptor?
  private var descriptorReplayGuard = try! ClipLiveShareNativeReplayGuard(maximumRecords: 8)
  private var ephemeralIdentity: ClipLiveShareViewerIdentity?
  private var encryptedChannel: ClipLiveShareEncryptedChannel?
  private var acceptedChallenge: ClipLiveShareNativeViewerChallenge?
  private var negotiationID: ClipLiveShareNegotiationID?
  private var viewer: (any ClipLiveShareNativeFriendPeerViewer)?
  private var rendezvousHandoffCompleted = false
  private var didSubmitInitialAnswer = false
  private var isAwaitingPeerAfterRendezvousLoss = false
  private var rendezvousLossGraceTask: Task<Void, Never>?
  private var continuations: [
    UUID: AsyncStream<ClipLiveShareNativeFriendViewerSessionEvent>.Continuation
  ] = [:]

  public init(
    target: ClipNativeRendezvousTarget,
    expectedHostIdentity: ClipLiveShareIdentityPublicKey,
    viewerIdentitySigner: any ClipLiveShareIdentitySigner,
    viewerDeviceName: String,
    viewerConfiguration: WebRTCPeerViewerConfiguration = .clipDefault,
    eventQueue: DispatchQueue = .main
  ) {
    self.target = target
    self.expectedHostIdentity = expectedHostIdentity
    self.viewerIdentitySigner = viewerIdentitySigner
    self.viewerDeviceName = viewerDeviceName
    self.viewerConfiguration = viewerConfiguration
    transport = ClipNativeRendezvousViewerTransport()
    peerViewerFactory = ClipLiveShareDefaultNativeFriendPeerViewerFactory()
    self.eventQueue = eventQueue
    now = { try ClipLiveShareNativeTimestamp(date: Date()) }
  }

  init(
    target: ClipNativeRendezvousTarget,
    expectedHostIdentity: ClipLiveShareIdentityPublicKey,
    viewerIdentitySigner: any ClipLiveShareIdentitySigner,
    viewerDeviceName: String,
    viewerConfiguration: WebRTCPeerViewerConfiguration = .clipDefault,
    transport: any ClipLiveShareNativeFriendViewerTransport,
    peerViewerFactory: any ClipLiveShareNativeFriendPeerViewerFactory,
    eventQueue: DispatchQueue = .main,
    now: @escaping @Sendable () throws -> ClipLiveShareNativeTimestamp
  ) {
    self.target = target
    self.expectedHostIdentity = expectedHostIdentity
    self.viewerIdentitySigner = viewerIdentitySigner
    self.viewerDeviceName = viewerDeviceName
    self.viewerConfiguration = viewerConfiguration
    self.transport = transport
    self.peerViewerFactory = peerViewerFactory
    self.eventQueue = eventQueue
    self.now = now
  }

  deinit {
    transportTask?.cancel()
    rendezvousLossGraceTask?.cancel()
    viewer?.close()
  }

  public func events() -> AsyncStream<ClipLiveShareNativeFriendViewerSessionEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: ClipLiveShareNativeFriendViewerSessionEvent.self,
      bufferingPolicy: .bufferingNewest(256)
    )
    continuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(id) }
    }
    return stream
  }

  public func start() async throws {
    guard phase == .idle || phase == .failed || phase == .closed else {
      throw ClipLiveShareNativeFriendViewerSessionError.connectionAlreadyActive
    }
    await tearDown(emitClosed: false)
    let generation = operationGeneration
    phase = .connecting
    emit(.connecting)

    do {
      try validateConfiguration()
      try validateDeviceName()
      let stream = await transport.nativeFriendEvents()
      transportTask = Task { [weak self] in
        await self?.consumeTransportEvents(stream, generation: generation)
      }
      _ = try await transport.nativeFriendAttachViewer(target)
      try ensureCurrentOperation(generation)
      if phase == .connecting { phase = .waitingForDescriptor }
    } catch OperationError.superseded {
      throw CancellationError()
    } catch is CancellationError {
      if generation == operationGeneration {
        await tearDown(emitClosed: false)
      }
      throw CancellationError()
    } catch let error as ClipLiveShareNativeFriendViewerSessionError {
      guard generation == operationGeneration else { throw CancellationError() }
      await fail(error)
      throw error
    } catch let error as ClipNativeRendezvousError {
      guard generation == operationGeneration else { throw CancellationError() }
      let mapped: ClipLiveShareNativeFriendViewerSessionError =
        error == .rendezvousNotLive || error == .rendezvousNotFound
        || error == .hostOffline
        ? .hostUnavailable : .rendezvousUnavailable
      await fail(mapped)
      throw mapped
    } catch {
      guard generation == operationGeneration, !Task.isCancelled else {
        throw CancellationError()
      }
      let mapped = ClipLiveShareNativeFriendViewerSessionError.rendezvousUnavailable
      await fail(mapped)
      throw mapped
    }
  }

  public func setSystemAudioPlaybackEnabled(_ enabled: Bool) {
    viewer?.setSystemAudioPlaybackEnabled(enabled)
  }

  public func setSystemAudioVolume(_ volume: Double) {
    viewer?.setSystemAudioVolume(volume)
  }

  public var remoteVideoStreams: [WebRTCRemoteVideoStream] {
    viewer?.remoteVideoStreams ?? []
  }

  public var viewerSnapshot: WebRTCPeerViewerSnapshot? { viewer?.snapshot }

  public func inboundStatisticsSnapshot() async throws
    -> WebRTCInboundStatisticsSnapshot
  {
    guard let viewer else {
      throw ClipLiveShareNativeFriendViewerSessionError.rendezvousUnavailable
    }
    return try await viewer.inboundStatisticsSnapshot()
  }

  @discardableResult
  public func sendNativeControl(_ data: Data) -> Bool {
    viewer?.sendControl(data, isBinary: false) ?? false
  }

  public func close() async {
    guard phase != .closed else { return }
    await tearDown(emitClosed: true)
  }

  private func validateConfiguration() throws {
    guard (try? ClipLiveShareServerEndpoint(rootURL: target.endpoint)) != nil,
      (try? ClipLiveShareRendezvousID(bytes: target.rendezvousID)) != nil
    else {
      throw ClipLiveShareNativeFriendViewerSessionError.invalidConfiguration
    }
  }

  /// A saved friend pins its endpoint and opaque rendezvous identifier, while
  /// the room is intentionally fresh for each share. The room becomes trusted
  /// only as part of the host-signed descriptor; it is never persisted.
  private func expectedContext(
    for signedRoom: ClipLiveShareRoomName
  ) throws -> ClipLiveShareNativeRendezvousContext {
    try .init(
      endpoint: ClipLiveShareServerEndpoint(rootURL: target.endpoint),
      room: signedRoom,
      rendezvousID: ClipLiveShareRendezvousID(bytes: target.rendezvousID)
    )
  }

  private func validateDeviceName() throws {
    let bytes = viewerDeviceName.utf8.count
    guard bytes > 0, bytes <= 128 else {
      throw ClipLiveShareNativeFriendViewerSessionError.invalidConfiguration
    }
  }

  private func ensureCurrentOperation(_ generation: UInt64) throws {
    guard generation == operationGeneration,
      phase != .closed,
      phase != .failed
    else { throw OperationError.superseded }
    try Task.checkCancellation()
  }

  private func consumeTransportEvents(
    _ stream: AsyncStream<ClipNativeRendezvousEvent>,
    generation: UInt64
  ) async {
    for await event in stream {
      guard !Task.isCancelled, generation == operationGeneration else { return }
      await handleTransportEvent(event)
    }
  }

  private func handleTransportEvent(_ event: ClipNativeRendezvousEvent) async {
    // The rendezvous has no authority over an established P2P session. Its
    // socket can finish, race a final event, or disappear with the server
    // after handoff without affecting WebRTC media/control.
    guard !rendezvousHandoffCompleted else { return }
    // Once the answer is submitted, the host and viewer both retain their
    // WebRTC peers while the control DataChannel races the temporary
    // rendezvous socket. A reconnect cannot resume that opaque route, so all
    // later rendezvous events are irrelevant to this admitted peer.
    guard !isAwaitingPeerAfterRendezvousLoss else { return }
    switch event {
    case .connecting:
      break
    case .connected(let role, _):
      guard role == .viewer else {
        await fail(.invalidSignalingMessage)
        return
      }
      emit(.rendezvousConnected(target))
    case .hostActive:
      break
    case .routeOpened(let routeID, let descriptor):
      guard let descriptor else {
        await fail(.descriptorRejected)
        return
      }
      await acceptRoute(routeID: routeID, descriptorData: descriptor)
    case .relay(let routeID, let payload, _):
      await handleRelay(routeID: routeID, payload: payload)
    case .routeClosed(let routeID, let reason):
      guard routeID == self.routeID?.rawValue else { return }
      if Self.isNonTerminalPostAnswerRouteClose(reason),
        didSubmitInitialAnswer,
        case .negotiating = phase
      {
        await preservePeerAfterRendezvousLoss()
      } else if !rendezvousHandoffCompleted {
        await fail(.sessionClosed(reason))
      }
    case .serverError:
      if !rendezvousHandoffCompleted { await fail(.rendezvousUnavailable) }
    case .invalidMessageReceived, .eventBufferOverflow:
      await fail(.invalidSignalingMessage)
    case .disconnected(let reason, let willReconnect):
      guard !rendezvousHandoffCompleted, !willReconnect else { return }
      await fail(
        reason == .reconnectExhausted ? .rendezvousUnavailable : .hostUnavailable
      )
    case .reconnectScheduled, .hostPreparing:
      break
    case .stopped:
      if !rendezvousHandoffCompleted, phase != .closed, phase != .failed {
        await fail(.rendezvousUnavailable)
      }
    }
  }

  private func acceptRoute(routeID rawRouteID: String, descriptorData: Data) async {
    guard phase == .connecting || phase == .waitingForDescriptor,
      routeID == nil
    else {
      await fail(.descriptorReplayed)
      return
    }
    do {
      let routeID = try ClipLiveShareRouteID(rawValue: rawRouteID)
      let signed = try ClipLiveShareNativeV2MessageCodec.decode(
        ClipLiveShareSignedNativeSessionDescriptor.self,
        from: descriptorData,
        maximumBytes: ClipNativeRendezvousLimits.maximumDescriptorBytes
      )
      let timestamp = try now()
      do {
        try descriptorReplayGuard.accept(
          signed,
          expectedIdentity: expectedHostIdentity,
          expectedContext: try expectedContext(for: signed.descriptor.room),
          at: timestamp
        )
      } catch ClipLiveShareNativeV2Error.replayed {
        throw ClipLiveShareNativeFriendViewerSessionError.descriptorReplayed
      } catch {
        throw ClipLiveShareNativeFriendViewerSessionError.descriptorRejected
      }
      let identity = ClipLiveShareViewerIdentity()
      let channel = try ClipLiveShareEncryptedChannel(
        viewer: identity,
        roomPublicKey: signed.descriptor.roomPublicKey,
        room: signed.descriptor.room,
        routeID: routeID
      )
      let generation = operationGeneration
      let viewer = try peerViewerFactory.makeViewer(
        configuration: viewerConfiguration,
        eventQueue: eventQueue,
        eventHandler: { [weak self] event in
          Task { await self?.handlePeerEvent(event, generation: generation) }
        }
      )
      self.routeID = routeID
      signedDescriptor = signed
      ephemeralIdentity = identity
      encryptedChannel = channel
      self.viewer = viewer
      phase = .waitingForChallenge
      emit(.descriptorAccepted(signed))
      try await sendOuter(
        .viewerHello(try ClipLiveShareViewerHello(viewerKey: identity.publicKey))
      )
    } catch let error as ClipLiveShareNativeFriendViewerSessionError {
      await fail(error)
    } catch {
      await fail(.descriptorRejected)
    }
  }

  private func handleRelay(routeID rawRouteID: String, payload: Data) async {
    guard rawRouteID == routeID?.rawValue else {
      await fail(.invalidSignalingMessage)
      return
    }
    let outer: ClipLiveShareOuterMessage
    do {
      outer = try ClipLiveShareMessageCodec.decodeOuter(payload)
    } catch {
      await fail(.invalidSignalingMessage)
      return
    }
    guard case .relay(let envelope) = outer else {
      await fail(.unexpectedSignalingMessage)
      return
    }
    do {
      if phase == .waitingForChallenge {
        try await handleChallenge(envelope)
      } else {
        guard var channel = encryptedChannel else {
          throw ClipLiveShareNativeFriendViewerSessionError.invalidSignalingMessage
        }
        let message = try channel.open(envelope)
        encryptedChannel = channel
        try await handleHostMessage(message, delivery: .rendezvous)
      }
    } catch let error as ClipLiveShareNativeFriendViewerSessionError {
      await fail(error)
    } catch {
      await fail(.invalidSignalingMessage)
    }
  }

  private func handleChallenge(_ envelope: ClipLiveShareRelayEnvelope) async throws {
    guard var channel = encryptedChannel,
      let descriptor = signedDescriptor,
      let routeID,
      let identity = ephemeralIdentity
    else {
      throw ClipLiveShareNativeFriendViewerSessionError.invalidSignalingMessage
    }
    let payload = try channel.openOpaquePayload(envelope)
    let challenge = try ClipLiveShareNativeV2MessageCodec.decode(
      ClipLiveShareNativeViewerChallenge.self,
      from: payload
    )
    encryptedChannel = channel
    guard challenge.sessionDescriptorDigest == descriptor.descriptor.digest,
      challenge.sessionID == descriptor.descriptor.sessionID,
      challenge.routeID == routeID,
      challenge.viewerEphemeralPublicKey == identity.publicKey,
      challenge.stateRevision == descriptor.descriptor.stateRevision,
      acceptedChallenge == nil
    else {
      throw ClipLiveShareNativeFriendViewerSessionError.challengeRejected
    }
    let timestamp = try now()
    do {
      try descriptor.verify(
        expectedIdentity: expectedHostIdentity,
        expectedContext: try expectedContext(for: descriptor.descriptor.room),
        at: timestamp
      )
    } catch {
      throw ClipLiveShareNativeFriendViewerSessionError.descriptorRejected
    }
    let proof = try ClipLiveShareSignedNativeViewerProof(
      signing: challenge,
      with: viewerIdentitySigner
    )
    do {
      try proof.verify(
        expectedChallenge: challenge,
        expectedIdentity: viewerIdentitySigner.publicKey,
        at: timestamp
      )
    } catch {
      throw ClipLiveShareNativeFriendViewerSessionError.challengeRejected
    }
    acceptedChallenge = challenge
    phase = .waitingForAdmission
    let proofData = try ClipLiveShareNativeV2MessageCodec.encode(proof)
    try await sendEncryptedOpaque(proofData)
    emit(.awaitingHostApproval)
  }

  private func handleHostMessage(
    _ message: ClipLiveShareInnerMessage,
    delivery: MessageDelivery
  ) async throws {
    guard let descriptor = signedDescriptor else {
      throw ClipLiveShareNativeFriendViewerSessionError.invalidSignalingMessage
    }
    let sessionID = descriptor.descriptor.sessionID
    guard message.sessionID == sessionID else {
      throw ClipLiveShareNativeFriendViewerSessionError.unexpectedSignalingMessage
    }
    switch message {
    case .authResult(let result):
      guard delivery == .rendezvous, phase == .waitingForAdmission else {
        throw ClipLiveShareNativeFriendViewerSessionError.unexpectedSignalingMessage
      }
      guard result.allowed else {
        throw ClipLiveShareNativeFriendViewerSessionError.admissionRejected(result.reason)
      }
      do {
        try descriptor.verify(
          expectedIdentity: expectedHostIdentity,
          expectedContext: try expectedContext(for: descriptor.descriptor.room),
          at: now()
        )
      } catch {
        throw ClipLiveShareNativeFriendViewerSessionError.descriptorRejected
      }
      phase = .negotiating
      emit(.authenticated(sessionID))

    case .offer(let offer):
      guard delivery == .rendezvous, phase == .negotiating else {
        throw ClipLiveShareNativeFriendViewerSessionError.unexpectedSignalingMessage
      }
      try await answer(offer, delivery: .rendezvous)

    case .ice(let candidate):
      guard delivery == .rendezvous,
        candidate.negotiationID == negotiationID
      else { return }
      try await addRemoteICE(candidate)

    case .codecOffer(let offer):
      guard delivery == .control, phase == .live else {
        throw ClipLiveShareNativeFriendViewerSessionError.unexpectedSignalingMessage
      }
      try await answer(offer, delivery: .control)

    case .codecICE(let candidate):
      guard delivery == .control,
        candidate.negotiationID == negotiationID
      else { return }
      try await addRemoteICE(candidate)

    case .manifest(let manifest):
      guard delivery == .control, phase == .live else {
        throw ClipLiveShareNativeFriendViewerSessionError.unexpectedSignalingMessage
      }
      viewer?.applyRemoteStreamManifest(manifest)
      emit(.controlMessage(message))

    case .sessionClosing(let closing):
      if delivery == .control {
        try? sendControl(
          .sessionClosing(
            try ClipLiveShareSessionClosing(
              sessionID: closing.sessionID,
              reason: "viewer-acknowledged"
            )
          )
        )
      }
      throw ClipLiveShareNativeFriendViewerSessionError.sessionClosed(closing.reason)

    case .streamState, .focus, .geometry, .cursor, .sharingState,
      .systemAudioState, .error:
      guard delivery == .control, phase == .live else {
        throw ClipLiveShareNativeFriendViewerSessionError.unexpectedSignalingMessage
      }
      emit(.controlMessage(message))

    case .authChallenge, .authResponse, .answer, .codecAnswer:
      throw ClipLiveShareNativeFriendViewerSessionError.unexpectedSignalingMessage
    }
  }

  private func answer(
    _ offer: ClipLiveShareSessionDescription,
    delivery: MessageDelivery
  ) async throws {
    guard let viewer else {
      throw ClipLiveShareNativeFriendViewerSessionError.rendezvousUnavailable
    }
    negotiationID = offer.negotiationID
    let answer = try await viewer.answer(.init(kind: .offer, sdp: offer.sdp))
    let value = try ClipLiveShareSessionDescription(
      sessionID: offer.sessionID,
      negotiationID: offer.negotiationID,
      sdp: answer.sdp
    )
    switch delivery {
    case .rendezvous:
      // Mark the peer before crossing the transport actor. If its socket
      // reports loss concurrently, the route-close event must preserve this
      // viable peer; a failed send still tears it down through the caller.
      didSubmitInitialAnswer = true
      do {
        try await sendEncrypted(.answer(value))
      } catch {
        didSubmitInitialAnswer = false
        throw error
      }
    case .control:
      try sendControl(.codecAnswer(value))
    }
  }

  private func addRemoteICE(_ candidate: ClipLiveShareICECandidate) async throws {
    guard let viewer, let lineIndex = Int32(exactly: candidate.sdpMLineIndex) else {
      throw ClipLiveShareNativeFriendViewerSessionError.invalidSignalingMessage
    }
    try await viewer.addRemoteICECandidate(
      .init(
        candidate: candidate.candidate,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: lineIndex
      )
    )
  }

  private func handlePeerEvent(
    _ event: WebRTCPeerViewerEvent,
    generation: UInt64
  ) async {
    guard generation == operationGeneration,
      phase != .closed,
      phase != .failed
    else { return }
    switch event {
    case .localICECandidate(let candidate):
      guard let descriptor = signedDescriptor, let negotiationID else { return }
      // The old opaque signaling route cannot be resumed. Existing candidates
      // continue ICE while the two peers wait for their DataChannel; a new
      // candidate cannot be delivered until that channel opens.
      if isAwaitingPeerAfterRendezvousLoss { return }
      do {
        let value = try ClipLiveShareICECandidate(
          sessionID: descriptor.descriptor.sessionID,
          negotiationID: negotiationID,
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: Int(candidate.sdpMLineIndex)
        )
        if rendezvousHandoffCompleted {
          try sendControl(.codecICE(value))
        } else {
          try await sendEncrypted(.ice(value))
        }
      } catch {
        await fail(.peerFailure(error.localizedDescription))
      }

    case .connectionStateChanged(let state):
      emit(.connectionStateChanged(state))
      if state == .failed || state == .closed {
        await fail(.peerFailure("The WebRTC connection closed."))
      }

    case .controlDataChannelStateChanged(let state):
      emit(.controlDataChannelStateChanged(state))
      if state == .open {
        guard phase == .negotiating || phase == .live else {
          await fail(.unexpectedSignalingMessage)
          return
        }
        phase = .live
        rendezvousLossGraceTask?.cancel()
        rendezvousLossGraceTask = nil
        isAwaitingPeerAfterRendezvousLoss = false
        do {
          try sendNativeControlHello()
          await completeRendezvousHandoff()
        } catch {
          await fail(.controlChannelUnavailable)
        }
      } else if state == .closed, phase == .negotiating || phase == .live {
        await fail(.controlChannelUnavailable)
      }

    case .controlDataChannelDrained, .negotiationNeeded:
      break

    case .controlMessageReceived(let data, let isBinary):
      guard phase == .live, !isBinary,
        data.count <= ClipLiveShareV1.maximumInnerMessageBytes
      else {
        await fail(.invalidSignalingMessage)
        return
      }
      guard let message = try? ClipLiveShareMessageCodec.decodeInner(data) else {
        guard Self.isNativeV2ControlMessage(data) else {
          await fail(.invalidSignalingMessage)
          return
        }
        emit(.nativeControlMessage(data))
        return
      }
      do {
        try await handleHostMessage(message, delivery: .control)
      } catch let error as ClipLiveShareNativeFriendViewerSessionError {
        if case .sessionClosed = error {
          emit(.failed(error))
          await tearDown(emitClosed: true)
        } else {
          await fail(error)
        }
      } catch {
        await fail(.peerFailure(error.localizedDescription))
      }

    case .remoteVideoStreamAdded(let stream):
      emit(.remoteVideoStreamAdded(stream))
    case .remoteVideoStreamUpdated(let stream):
      emit(.remoteVideoStreamUpdated(stream))
    case .remoteVideoStreamRemoved(let streamID):
      emit(.remoteVideoStreamRemoved(streamID))
    case .systemAudioTrackAvailable(let trackID):
      emit(.systemAudioTrackAvailable(trackID))
    case .systemAudioTrackRemoved(let trackID):
      emit(.systemAudioTrackRemoved(trackID))
    case .error(let error):
      await fail(.peerFailure(error.localizedDescription))
    }
  }

  private func sendNativeControlHello() throws {
    guard let descriptor = signedDescriptor else {
      throw ClipLiveShareNativeFriendViewerSessionError.controlChannelUnavailable
    }
    let issuedAt = try now()
    let hello = try ClipLiveShareNativeControlHello(
      sessionID: descriptor.descriptor.sessionID,
      viewerIdentity: viewerIdentitySigner.publicKey,
      deviceName: viewerDeviceName,
      issuedAt: issuedAt,
      expiresAt: issuedAt.adding(
        milliseconds: ClipLiveShareNativeV2.maximumControlHelloLifetimeMilliseconds
      )
    )
    let signed = try ClipLiveShareSignedNativeControlHello(
      signing: hello,
      with: viewerIdentitySigner
    )
    let data = try ClipLiveShareNativeV2MessageCodec.encode(signed)
    guard viewer?.sendControl(data, isBinary: false) == true else {
      throw ClipLiveShareNativeFriendViewerSessionError.controlChannelUnavailable
    }
  }

  private static func isNativeV2ControlMessage(_ data: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else { return false }
    if dictionary["version"] as? Int == ClipLiveShareNativeV2.version,
      dictionary["type"] is String
    {
      return true
    }
    guard let message = dictionary["message"] as? [String: Any],
      message["version"] as? Int == ClipLiveShareNativeV2.version,
      message["type"] is String,
      dictionary["signature"] is String
    else { return false }
    return true
  }

  private func completeRendezvousHandoff() async {
    guard !rendezvousHandoffCompleted else { return }
    rendezvousHandoffCompleted = true
    encryptedChannel = nil
    acceptedChallenge = nil
    await transport.nativeFriendCloseRoute(reason: "viewer completed signaling")
    transportTask?.cancel()
    transportTask = nil
    emit(.rendezvousHandoffCompleted)
  }

  private func preservePeerAfterRendezvousLoss() async {
    guard !isAwaitingPeerAfterRendezvousLoss else { return }
    isAwaitingPeerAfterRendezvousLoss = true
    transportTask?.cancel()
    transportTask = nil
    // Stop futile route recreation. The admitted host retains the matching
    // peer for the same bounded period while WebRTC completes independently.
    await transport.nativeFriendTeardown()
    let generation = operationGeneration
    rendezvousLossGraceTask?.cancel()
    rendezvousLossGraceTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(60))
      } catch {
        return
      }
      await self?.rendezvousLossGraceExpired(generation: generation)
    }
  }

  private static func isNonTerminalPostAnswerRouteClose(
    _ reason: String?
  ) -> Bool {
    reason == "signaling-connection-lost"
      || reason == "viewer completed signaling"
  }

  private func rendezvousLossGraceExpired(generation: UInt64) async {
    guard generation == operationGeneration,
      isAwaitingPeerAfterRendezvousLoss,
      case .negotiating = phase
    else { return }
    await fail(.rendezvousUnavailable)
  }

  private func sendEncrypted(_ message: ClipLiveShareInnerMessage) async throws {
    guard var channel = encryptedChannel else {
      throw ClipLiveShareNativeFriendViewerSessionError.rendezvousUnavailable
    }
    let envelope = try outboundEnvelope(channel.seal(message))
    encryptedChannel = channel
    try await sendOuter(.relay(envelope))
  }

  private func sendEncryptedOpaque(_ payload: Data) async throws {
    guard var channel = encryptedChannel else {
      throw ClipLiveShareNativeFriendViewerSessionError.rendezvousUnavailable
    }
    let envelope = try outboundEnvelope(channel.sealOpaquePayload(payload))
    encryptedChannel = channel
    try await sendOuter(.relay(envelope))
  }

  private func sendControl(_ message: ClipLiveShareInnerMessage) throws {
    guard let viewer else {
      throw ClipLiveShareNativeFriendViewerSessionError.controlChannelUnavailable
    }
    let data = try ClipLiveShareMessageCodec.encodeInner(message)
    guard viewer.sendControl(data, isBinary: false) else {
      throw ClipLiveShareNativeFriendViewerSessionError.controlChannelUnavailable
    }
  }

  private func sendOuter(_ message: ClipLiveShareOuterMessage) async throws {
    let data = try ClipLiveShareMessageCodec.encodeOuter(message)
    try await transport.nativeFriendSend(data)
  }

  /// Unlike the browser signaling server, native rendezvous intentionally
  /// treats payloads as completely opaque and therefore cannot insert the
  /// viewer's route ID into a v1 relay envelope. Bind it here before relay.
  private func outboundEnvelope(
    _ envelope: ClipLiveShareRelayEnvelope
  ) throws -> ClipLiveShareRelayEnvelope {
    guard let routeID else {
      throw ClipLiveShareNativeFriendViewerSessionError.rendezvousUnavailable
    }
    return try ClipLiveShareRelayEnvelope(
      routeID: routeID,
      sequence: envelope.sequence,
      nonce: envelope.nonce,
      ciphertext: envelope.ciphertext
    )
  }

  private func fail(
    _ error: ClipLiveShareNativeFriendViewerSessionError
  ) async {
    guard phase != .failed, phase != .closed else { return }
    operationGeneration &+= 1
    phase = .failed
    emit(.failed(error))
    rendezvousLossGraceTask?.cancel()
    rendezvousLossGraceTask = nil
    isAwaitingPeerAfterRendezvousLoss = false
    transportTask?.cancel()
    transportTask = nil
    await transport.nativeFriendTeardown()
    viewer?.close()
    viewer = nil
    encryptedChannel = nil
    ephemeralIdentity = nil
    acceptedChallenge = nil
  }

  private func tearDown(emitClosed: Bool) async {
    operationGeneration &+= 1
    rendezvousLossGraceTask?.cancel()
    rendezvousLossGraceTask = nil
    transportTask?.cancel()
    transportTask = nil
    await transport.nativeFriendTeardown()
    viewer?.close()
    viewer = nil
    routeID = nil
    signedDescriptor = nil
    descriptorReplayGuard = try! ClipLiveShareNativeReplayGuard(maximumRecords: 8)
    ephemeralIdentity = nil
    encryptedChannel = nil
    acceptedChallenge = nil
    negotiationID = nil
    rendezvousHandoffCompleted = false
    didSubmitInitialAnswer = false
    isAwaitingPeerAfterRendezvousLoss = false
    phase = emitClosed ? .closed : .idle
    if emitClosed { emit(.closed) }
  }

  private func emit(_ event: ClipLiveShareNativeFriendViewerSessionEvent) {
    for continuation in continuations.values { continuation.yield(event) }
  }

  private func removeContinuation(_ id: UUID) {
    continuations[id] = nil
  }
}
