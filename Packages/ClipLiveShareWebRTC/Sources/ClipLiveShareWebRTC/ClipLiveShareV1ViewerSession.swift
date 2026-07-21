import ClipLiveShare
import Foundation

public struct ClipLiveShareV1ViewerInvite: Equatable, Sendable {
  public let originalURL: URL
  public let endpoint: ClipLiveShareServerEndpoint
  public let room: ClipLiveShareRoomName
  public let fragment: ClipLiveShareViewerFragment
  public let capabilities: ClipLiveShareCapabilities

  public init(
    originalURL: URL,
    endpoint: ClipLiveShareServerEndpoint,
    room: ClipLiveShareRoomName,
    fragment: ClipLiveShareViewerFragment,
    capabilities: ClipLiveShareCapabilities
  ) {
    self.originalURL = originalURL
    self.endpoint = endpoint
    self.room = room
    self.fragment = fragment
    self.capabilities = capabilities
  }
}

public enum ClipLiveShareV1ViewerSessionError: Error, Equatable, Sendable,
  LocalizedError
{
  case invalidInvite
  case incompatibleServer
  case connectionAlreadyActive
  case signalingUnavailable
  case hostUnavailable
  case accessCodeRequired
  case accessCodeRejected
  case invalidSignalingMessage
  case unexpectedSignalingMessage
  case peerFailure(String)
  case controlChannelUnavailable
  case sessionClosed(String?)

  public var errorDescription: String? {
    switch self {
    case .invalidInvite:
      "That is not a complete Clip Live Share invite."
    case .incompatibleServer:
      "This server does not support Clip Live Share."
    case .connectionAlreadyActive:
      "This viewer session is already active."
    case .signalingUnavailable:
      "Clip could not reach the Live Share host."
    case .hostUnavailable:
      "The Live Share host is not available."
    case .accessCodeRequired:
      "This share requires an access code."
    case .accessCodeRejected:
      "The access code was not accepted."
    case .invalidSignalingMessage:
      "The Live Share server returned an invalid message."
    case .unexpectedSignalingMessage:
      "The Live Share host returned an unexpected message."
    case .peerFailure(let message):
      "The peer-to-peer viewer failed: \(message)"
    case .controlChannelUnavailable:
      "The peer-to-peer control channel is unavailable."
    case .sessionClosed(let reason):
      reason ?? "The host ended this Live Share."
    }
  }
}

public enum ClipLiveShareV1ViewerSessionEvent: @unchecked Sendable {
  case connecting
  case signalingConnected(ClipLiveShareV1ViewerInvite)
  case accessCodeRequired
  case authenticated(ClipLiveShareSessionID)
  case connectionStateChanged(WebRTCPeerConnectionState)
  case controlDataChannelStateChanged(WebRTCControlDataChannelState)
  case signalingHandoffCompleted
  case controlMessage(ClipLiveShareInnerMessage)
  case nativeControlMessage(Data)
  case remoteVideoStreamAdded(WebRTCRemoteVideoStream)
  case remoteVideoStreamUpdated(WebRTCRemoteVideoStream)
  case remoteVideoStreamRemoved(ClipLiveShareStreamID)
  case systemAudioTrackAvailable(String)
  case systemAudioTrackRemoved(String)
  case failed(ClipLiveShareV1ViewerSessionError)
  case closed
}

protocol ClipLiveShareV1PeerViewer: AnyObject, Sendable {
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

extension WebRTCPeerViewer: ClipLiveShareV1PeerViewer {}

protocol ClipLiveShareV1PeerViewerFactory: Sendable {
  func makeViewer(
    configuration: WebRTCPeerViewerConfiguration,
    eventQueue: DispatchQueue,
    eventHandler: @escaping WebRTCPeerViewer.EventHandler
  ) throws -> any ClipLiveShareV1PeerViewer
}

private struct ClipLiveShareV1DefaultPeerViewerFactory:
  ClipLiveShareV1PeerViewerFactory
{
  func makeViewer(
    configuration: WebRTCPeerViewerConfiguration,
    eventQueue: DispatchQueue,
    eventHandler: @escaping WebRTCPeerViewer.EventHandler
  ) throws -> any ClipLiveShareV1PeerViewer {
    try WebRTCPeerViewer(
      configuration: configuration,
      eventQueue: eventQueue,
      eventHandler: eventHandler
    )
  }
}

/// Native viewer for a browser-compatible Clip v1 invitation.
///
/// The signaling service sees only the existing opaque encrypted relay. Once
/// the ordered WebRTC DataChannel opens, the short-lived WebSocket route is
/// closed and all media/control traffic remains peer-to-peer.
public actor ClipLiveShareV1ViewerSession {
  private enum Phase {
    case idle
    case connecting
    case waitingForRoute
    case waitingForAuthentication
    case negotiating
    case live
    case failed
    case closed
  }

  private enum OperationError: Error {
    case superseded
  }

  private let httpTransport: any ClipLiveShareHTTPTransport
  private let webSocketFactory: any ClipLiveShareWebSocketFactory
  private let peerViewerFactory: any ClipLiveShareV1PeerViewerFactory
  private let eventQueue: DispatchQueue
  private var operationGeneration: UInt64 = 0
  private var phase: Phase = .idle
  private var invite: ClipLiveShareV1ViewerInvite?
  private var identity: ClipLiveShareViewerIdentity?
  private var encryptedChannel: ClipLiveShareEncryptedChannel?
  private var routeID: ClipLiveShareRouteID?
  private var sessionID: ClipLiveShareSessionID?
  private var negotiationID: ClipLiveShareNegotiationID?
  private var pendingChallenge: ClipLiveShareAuthChallenge?
  private var suppliedAccessCode: String?
  private var viewer: (any ClipLiveShareV1PeerViewer)?
  private var socket: ClipLiveShareV1ViewerSerializedSocket?
  private var receiveTask: Task<Void, Never>?
  private var signalingHandoffCompleted = false
  private var continuations: [UUID: AsyncStream<ClipLiveShareV1ViewerSessionEvent>.Continuation] =
    [:]

  public init(
    httpTransport: any ClipLiveShareHTTPTransport = URLSessionClipLiveShareHTTPTransport(),
    webSocketFactory: any ClipLiveShareWebSocketFactory = URLSessionClipLiveShareWebSocketFactory(),
    eventQueue: DispatchQueue = .main
  ) {
    self.httpTransport = httpTransport
    self.webSocketFactory = webSocketFactory
    peerViewerFactory = ClipLiveShareV1DefaultPeerViewerFactory()
    self.eventQueue = eventQueue
  }

  init(
    httpTransport: any ClipLiveShareHTTPTransport,
    webSocketFactory: any ClipLiveShareWebSocketFactory,
    peerViewerFactory: any ClipLiveShareV1PeerViewerFactory,
    eventQueue: DispatchQueue = .main
  ) {
    self.httpTransport = httpTransport
    self.webSocketFactory = webSocketFactory
    self.peerViewerFactory = peerViewerFactory
    self.eventQueue = eventQueue
  }

  deinit {
    receiveTask?.cancel()
    viewer?.close()
  }

  public func events() -> AsyncStream<ClipLiveShareV1ViewerSessionEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: ClipLiveShareV1ViewerSessionEvent.self,
      bufferingPolicy: .bufferingNewest(256)
    )
    continuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(id) }
    }
    return stream
  }

  public func start(inviteURL: URL, accessCode: String? = nil) async throws {
    guard phase == .idle || phase == .failed || phase == .closed else {
      throw ClipLiveShareV1ViewerSessionError.connectionAlreadyActive
    }
    await tearDown(emitClosed: false)
    let generation = operationGeneration
    phase = .connecting
    suppliedAccessCode = Self.nonemptyAccessCode(accessCode)
    signalingHandoffCompleted = false
    emit(.connecting)

    do {
      let context = try await resolveInvite(inviteURL)
      try ensureCurrentOperation(generation)
      invite = context
      identity = ClipLiveShareViewerIdentity()
      let configuration = WebRTCPeerViewerConfiguration(
        iceServers: context.capabilities.iceServers.map {
          WebRTCICEServerConfiguration(
            urlStrings: $0.urls,
            username: $0.username,
            credential: $0.credential
          )
        }
      )
      let viewer = try peerViewerFactory.makeViewer(
        configuration: configuration,
        eventQueue: eventQueue,
        eventHandler: { [weak self] event in
          Task {
            await self?.handlePeerEvent(
              event,
              generation: generation
            )
          }
        }
      )
      self.viewer = viewer

      var request = URLRequest(
        url: try context.endpoint.webSocketURL(
          for: context.capabilities.viewerWebSocketPathTemplate,
          room: context.room
        )
      )
      request.timeoutInterval = 10
      let base = try await webSocketFactory.makeConnection(for: request)
      do {
        try ensureCurrentOperation(generation)
      } catch {
        await base.close()
        throw error
      }
      let socket = ClipLiveShareV1ViewerSerializedSocket(base: base)
      self.socket = socket
      try await socket.resume()
      try ensureCurrentOperation(generation)
      guard let identity else {
        throw ClipLiveShareV1ViewerSessionError.signalingUnavailable
      }
      try await sendOuter(
        .viewerHello(
          try ClipLiveShareViewerHello(
            viewerKey: identity.publicKey
          ))
      )
      try ensureCurrentOperation(generation)
      phase = .waitingForRoute
      emit(.signalingConnected(context))
      receiveTask = Task { [weak self] in
        await self?.receiveLoop(
          socket: socket,
          generation: generation
        )
      }
    } catch OperationError.superseded {
      throw CancellationError()
    } catch is CancellationError {
      if generation == operationGeneration {
        await tearDown(emitClosed: false)
      }
      throw CancellationError()
    } catch let error as ClipLiveShareV1ViewerSessionError {
      guard generation == operationGeneration else {
        throw CancellationError()
      }
      await fail(error)
      throw error
    } catch {
      guard generation == operationGeneration, !Task.isCancelled else {
        if generation == operationGeneration {
          await tearDown(emitClosed: false)
        }
        throw CancellationError()
      }
      let mapped = ClipLiveShareV1ViewerSessionError.signalingUnavailable
      await fail(mapped)
      throw mapped
    }
  }

  public func submitAccessCode(_ accessCode: String) async throws {
    guard let challenge = pendingChallenge,
      phase == .waitingForAuthentication
    else {
      throw ClipLiveShareV1ViewerSessionError.unexpectedSignalingMessage
    }
    guard let accessCode = Self.nonemptyAccessCode(accessCode) else {
      throw ClipLiveShareV1ViewerSessionError.accessCodeRequired
    }
    suppliedAccessCode = accessCode
    let generation = operationGeneration
    do {
      try await sendAuthenticationResponse(challenge)
      guard generation == operationGeneration else {
        throw CancellationError()
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ClipLiveShareV1ViewerSessionError {
      guard generation == operationGeneration else {
        throw CancellationError()
      }
      await fail(error)
      throw error
    } catch {
      guard generation == operationGeneration else {
        throw CancellationError()
      }
      let mapped = ClipLiveShareV1ViewerSessionError.signalingUnavailable
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
      throw ClipLiveShareV1ViewerSessionError.signalingUnavailable
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

  private static func nonemptyAccessCode(_ accessCode: String?) -> String? {
    guard let accessCode else { return nil }
    let normalized = ClipLiveShareAccessCodeProof.normalize(accessCode)
    return normalized.isEmpty ? nil : normalized
  }

  private func ensureCurrentOperation(_ generation: UInt64) throws {
    guard generation == operationGeneration,
      phase != .closed,
      phase != .failed
    else {
      throw OperationError.superseded
    }
    try Task.checkCancellation()
  }

  private func resolveInvite(_ url: URL) async throws
    -> ClipLiveShareV1ViewerInvite
  {
    let fragment: ClipLiveShareViewerFragment
    do {
      fragment = try ClipLiveShareViewerFragment(url: url)
    } catch {
      throw ClipLiveShareV1ViewerSessionError.invalidInvite
    }
    guard
      var components = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
      ), let scheme = components.scheme, let host = components.host,
      !scheme.isEmpty, !host.isEmpty
    else {
      throw ClipLiveShareV1ViewerSessionError.invalidInvite
    }
    let viewerPath = components.path
    components.path = ""
    components.query = nil
    components.fragment = nil
    guard let root = components.url,
      let endpoint = try? ClipLiveShareServerEndpoint(rootURL: root)
    else {
      throw ClipLiveShareV1ViewerSessionError.invalidInvite
    }
    let capabilities = try await fetchCapabilities(endpoint)
    let room = try roomName(
      from: viewerPath,
      template: capabilities.viewerPathTemplate
    )
    return ClipLiveShareV1ViewerInvite(
      originalURL: url,
      endpoint: endpoint,
      room: room,
      fragment: fragment,
      capabilities: capabilities
    )
  }

  private func fetchCapabilities(
    _ endpoint: ClipLiveShareServerEndpoint
  ) async throws -> ClipLiveShareCapabilities {
    var request = URLRequest(url: endpoint.capabilitiesURL)
    request.httpMethod = "GET"
    request.timeoutInterval = 5
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let response = try await httpTransport.execute(request)
    guard response.statusCode == 200,
      !response.data.isEmpty,
      response.data.count <= ClipLiveShareSignalingResourceLimits.maximumCapabilitiesBytes,
      let capabilities = try? JSONDecoder().decode(
        ClipLiveShareCapabilities.self,
        from: response.data
      )
    else {
      throw ClipLiveShareV1ViewerSessionError.incompatibleServer
    }
    return capabilities
  }

  private func roomName(from path: String, template: String) throws
    -> ClipLiveShareRoomName
  {
    let pieces = template.components(separatedBy: "{room}")
    guard pieces.count == 2,
      path.hasPrefix(pieces[0]),
      path.hasSuffix(pieces[1])
    else {
      throw ClipLiveShareV1ViewerSessionError.invalidInvite
    }
    let start = path.index(path.startIndex, offsetBy: pieces[0].count)
    let end = path.index(path.endIndex, offsetBy: -pieces[1].count)
    guard start <= end else {
      throw ClipLiveShareV1ViewerSessionError.invalidInvite
    }
    do {
      return try ClipLiveShareRoomName(rawValue: String(path[start..<end]))
    } catch {
      throw ClipLiveShareV1ViewerSessionError.invalidInvite
    }
  }

  private func receiveLoop(
    socket: ClipLiveShareV1ViewerSerializedSocket,
    generation: UInt64
  ) async {
    do {
      while !Task.isCancelled {
        let payload = try await socket.receive()
        guard generation == operationGeneration else { return }
        await handleSocketPayload(payload)
      }
    } catch {
      guard !Task.isCancelled,
        generation == operationGeneration,
        !signalingHandoffCompleted,
        phase != .closed,
        phase != .failed
      else { return }
      await fail(.signalingUnavailable)
    }
  }

  private func handleSocketPayload(_ payload: ClipLiveShareWebSocketPayload) async {
    let data: Data =
      switch payload {
      case .text(let text): Data(text.utf8)
      case .data(let data): data
      }
    guard let invite,
      data.count <= invite.capabilities.limits.maximumMessageBytes,
      let message = try? ClipLiveShareMessageCodec.decodeOuter(
        data,
        maximumBytes: invite.capabilities.limits.maximumMessageBytes
      )
    else {
      await fail(.invalidSignalingMessage)
      return
    }
    switch message {
    case let .routeOpened(opened):
      guard phase == .waitingForRoute,
        routeID == nil,
        let identity,
        opened.viewerKey == nil
          || opened.viewerKey == identity.publicKey
      else {
        await fail(.unexpectedSignalingMessage)
        return
      }
      do {
        routeID = opened.routeID
        encryptedChannel = try ClipLiveShareEncryptedChannel(
          viewer: identity,
          roomPublicKey: invite.fragment.publicKey,
          room: invite.room,
          routeID: opened.routeID
        )
        phase = .waitingForAuthentication
      } catch {
        await fail(.invalidSignalingMessage)
      }

    case let .relay(envelope):
      await handleRelay(envelope)

    case .hostUnavailable:
      await fail(.hostUnavailable)

    case let .routeClosed(closed):
      guard closed.routeID == routeID else { return }
      if !signalingHandoffCompleted {
        await fail(.signalingUnavailable)
      }

    case let .error(error):
      await fail(.peerFailure(error.message))

    case .viewerHello, .closeRoute:
      await fail(.unexpectedSignalingMessage)
    }
  }

  private func handleRelay(_ envelope: ClipLiveShareRelayEnvelope) async {
    guard var channel = encryptedChannel,
      let routeID,
      envelope.routeID == routeID
    else {
      await fail(.invalidSignalingMessage)
      return
    }
    do {
      let message = try channel.open(envelope)
      encryptedChannel = channel
      try await handleHostMessage(message, delivery: .signaling)
    } catch let error as ClipLiveShareV1ViewerSessionError {
      await fail(error)
    } catch {
      await fail(.invalidSignalingMessage)
    }
  }

  private enum MessageDelivery { case signaling, control }

  private func handleHostMessage(
    _ message: ClipLiveShareInnerMessage,
    delivery: MessageDelivery
  ) async throws {
    if let sessionID, message.sessionID != sessionID {
      throw ClipLiveShareV1ViewerSessionError.unexpectedSignalingMessage
    }
    switch message {
    case let .authChallenge(challenge):
      guard delivery == .signaling,
        phase == .waitingForAuthentication,
        sessionID == nil
      else {
        throw ClipLiveShareV1ViewerSessionError.unexpectedSignalingMessage
      }
      sessionID = challenge.sessionID
      pendingChallenge = challenge
      if challenge.accessCodeRequired, suppliedAccessCode == nil {
        emit(.accessCodeRequired)
      } else {
        try await sendAuthenticationResponse(challenge)
      }

    case let .authResult(result):
      guard delivery == .signaling,
        result.sessionID == sessionID,
        phase == .waitingForAuthentication
      else {
        throw ClipLiveShareV1ViewerSessionError.unexpectedSignalingMessage
      }
      guard result.allowed else {
        throw ClipLiveShareV1ViewerSessionError.accessCodeRejected
      }
      pendingChallenge = nil
      phase = .negotiating
      emit(.authenticated(result.sessionID))

    case let .offer(offer):
      guard delivery == .signaling, phase == .negotiating else {
        throw ClipLiveShareV1ViewerSessionError.unexpectedSignalingMessage
      }
      try await answer(offer, delivery: .signaling)

    case let .ice(candidate):
      guard delivery == .signaling,
        candidate.negotiationID == negotiationID
      else { return }
      try await addRemoteICE(candidate)

    case let .codecOffer(offer):
      guard delivery == .control, phase == .live else {
        throw ClipLiveShareV1ViewerSessionError.unexpectedSignalingMessage
      }
      try await answer(offer, delivery: .control)

    case let .codecICE(candidate):
      guard delivery == .control,
        candidate.negotiationID == negotiationID
      else { return }
      try await addRemoteICE(candidate)

    case let .manifest(manifest):
      guard delivery == .control, phase == .live else {
        throw ClipLiveShareV1ViewerSessionError.unexpectedSignalingMessage
      }
      viewer?.applyRemoteStreamManifest(manifest)
      emit(.controlMessage(message))

    case let .sessionClosing(closing):
      if delivery == .control {
        try? sendControl(
          .sessionClosing(
            try ClipLiveShareSessionClosing(
              sessionID: closing.sessionID,
              reason: "viewer-acknowledged"
            )))
      }
      throw ClipLiveShareV1ViewerSessionError.sessionClosed(closing.reason)

    case .streamState, .focus, .geometry, .cursor, .sharingState,
      .systemAudioState, .error:
      guard delivery == .control, phase == .live else {
        throw ClipLiveShareV1ViewerSessionError.unexpectedSignalingMessage
      }
      emit(.controlMessage(message))

    case .authResponse, .answer, .codecAnswer:
      throw ClipLiveShareV1ViewerSessionError.unexpectedSignalingMessage
    }
  }

  private func sendAuthenticationResponse(
    _ challenge: ClipLiveShareAuthChallenge
  ) async throws {
    let response = try ClipLiveShareAccessCodeProof.response(
      to: challenge,
      accessCode: suppliedAccessCode
    )
    try await sendEncrypted(.authResponse(response))
  }

  private func answer(
    _ offer: ClipLiveShareSessionDescription,
    delivery: MessageDelivery
  ) async throws {
    guard let viewer else {
      throw ClipLiveShareV1ViewerSessionError.signalingUnavailable
    }
    negotiationID = offer.negotiationID
    let answer = try await viewer.answer(.init(kind: .offer, sdp: offer.sdp))
    let value = try ClipLiveShareSessionDescription(
      sessionID: offer.sessionID,
      negotiationID: offer.negotiationID,
      sdp: answer.sdp
    )
    switch delivery {
    case .signaling:
      try await sendEncrypted(.answer(value))
    case .control:
      try sendControl(.codecAnswer(value))
    }
  }

  private func addRemoteICE(_ candidate: ClipLiveShareICECandidate) async throws {
    guard let lineIndex = Int32(exactly: candidate.sdpMLineIndex),
      let viewer
    else {
      throw ClipLiveShareV1ViewerSessionError.invalidSignalingMessage
    }
    try await viewer.addRemoteICECandidate(
      .init(
        candidate: candidate.candidate,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: lineIndex
      ))
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
    case let .localICECandidate(candidate):
      guard let sessionID, let negotiationID else { return }
      do {
        let value = try ClipLiveShareICECandidate(
          sessionID: sessionID,
          negotiationID: negotiationID,
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: Int(candidate.sdpMLineIndex)
        )
        if signalingHandoffCompleted {
          try sendControl(.codecICE(value))
        } else {
          try await sendEncrypted(.ice(value))
        }
      } catch {
        await fail(.peerFailure(error.localizedDescription))
      }

    case let .connectionStateChanged(state):
      emit(.connectionStateChanged(state))
      if state == .failed || state == .closed {
        await fail(.peerFailure("The WebRTC connection closed."))
      }

    case let .controlDataChannelStateChanged(state):
      emit(.controlDataChannelStateChanged(state))
      if state == .open {
        guard phase == .negotiating || phase == .live else {
          await fail(.unexpectedSignalingMessage)
          return
        }
        phase = .live
        await completeSignalingHandoff()
      } else if state == .closed,
        phase == .negotiating || phase == .live
      {
        await fail(.controlChannelUnavailable)
      }

    case .controlDataChannelDrained:
      break

    case let .controlMessageReceived(data, isBinary):
      guard phase == .live,
        !isBinary,
        data.count <= ClipLiveShareV1.maximumInnerMessageBytes
      else {
        await fail(.invalidSignalingMessage)
        return
      }
      guard let message = try? ClipLiveShareMessageCodec.decodeInner(data) else {
        // Additive native-v2 messages share the reliable DataChannel.
        // Only a structurally recognizable v2 discriminator is
        // surfaced; arbitrary malformed v1 JSON still fails closed.
        guard Self.isNativeV2ControlMessage(data) else {
          await fail(.invalidSignalingMessage)
          return
        }
        emit(.nativeControlMessage(data))
        return
      }
      do {
        try await handleHostMessage(message, delivery: .control)
      } catch let error as ClipLiveShareV1ViewerSessionError {
        if case .sessionClosed = error {
          emit(.failed(error))
          await tearDown(emitClosed: true)
        } else {
          await fail(error)
        }
      } catch {
        await fail(.peerFailure(error.localizedDescription))
      }

    case .negotiationNeeded:
      break
    case let .remoteVideoStreamAdded(stream):
      emit(.remoteVideoStreamAdded(stream))
    case let .remoteVideoStreamUpdated(stream):
      emit(.remoteVideoStreamUpdated(stream))
    case let .remoteVideoStreamRemoved(streamID):
      emit(.remoteVideoStreamRemoved(streamID))
    case let .systemAudioTrackAvailable(trackID):
      emit(.systemAudioTrackAvailable(trackID))
    case let .systemAudioTrackRemoved(trackID):
      emit(.systemAudioTrackRemoved(trackID))
    case let .error(error):
      await fail(.peerFailure(error.localizedDescription))
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

  private func completeSignalingHandoff() async {
    guard !signalingHandoffCompleted else { return }
    signalingHandoffCompleted = true
    if let routeID {
      try? await sendOuter(.closeRoute(routeID))
    }
    receiveTask?.cancel()
    receiveTask = nil
    await socket?.close()
    socket = nil
    encryptedChannel = nil
    emit(.signalingHandoffCompleted)
  }

  private func sendEncrypted(_ message: ClipLiveShareInnerMessage) async throws {
    guard var channel = encryptedChannel else {
      throw ClipLiveShareV1ViewerSessionError.signalingUnavailable
    }
    let envelope = try channel.seal(message)
    encryptedChannel = channel
    try await sendOuter(.relay(envelope))
  }

  private func sendControl(_ message: ClipLiveShareInnerMessage) throws {
    guard let viewer else {
      throw ClipLiveShareV1ViewerSessionError.controlChannelUnavailable
    }
    let data = try ClipLiveShareMessageCodec.encodeInner(message)
    guard viewer.sendControl(data, isBinary: false) else {
      throw ClipLiveShareV1ViewerSessionError.controlChannelUnavailable
    }
  }

  private func sendOuter(_ message: ClipLiveShareOuterMessage) async throws {
    guard let socket else {
      throw ClipLiveShareV1ViewerSessionError.signalingUnavailable
    }
    let maximum =
      invite?.capabilities.limits.maximumMessageBytes
      ?? ClipLiveShareSignalingResourceLimits.maximumMessageBytes
    let data = try ClipLiveShareMessageCodec.encodeOuter(
      message,
      maximumBytes: maximum
    )
    guard let text = String(data: data, encoding: .utf8) else {
      throw ClipLiveShareV1ViewerSessionError.invalidSignalingMessage
    }
    try await socket.send(.text(text))
  }

  private func fail(_ error: ClipLiveShareV1ViewerSessionError) async {
    guard phase != .failed, phase != .closed else { return }
    operationGeneration &+= 1
    phase = .failed
    emit(.failed(error))
    receiveTask?.cancel()
    receiveTask = nil
    await socket?.close()
    socket = nil
    viewer?.close()
    viewer = nil
    encryptedChannel = nil
  }

  private func tearDown(emitClosed: Bool) async {
    operationGeneration &+= 1
    receiveTask?.cancel()
    receiveTask = nil
    await socket?.close()
    socket = nil
    viewer?.close()
    viewer = nil
    encryptedChannel = nil
    identity = nil
    routeID = nil
    sessionID = nil
    negotiationID = nil
    pendingChallenge = nil
    suppliedAccessCode = nil
    invite = nil
    signalingHandoffCompleted = false
    phase = emitClosed ? .closed : .idle
    if emitClosed { emit(.closed) }
  }

  private func emit(_ event: ClipLiveShareV1ViewerSessionEvent) {
    for continuation in continuations.values {
      continuation.yield(event)
    }
  }

  private func removeContinuation(_ id: UUID) {
    continuations[id] = nil
  }
}

/// Serializes WebSocket sends across actor reentrancy so the encrypted relay's
/// monotonically increasing sequence also arrives in that order.
private actor ClipLiveShareV1ViewerSerializedSocket {
  private let base: any ClipLiveShareWebSocketConnection
  private var sendTail: (id: UUID, task: Task<Void, any Error>)?

  init(base: any ClipLiveShareWebSocketConnection) {
    self.base = base
  }

  func resume() async throws { try await base.resume() }

  func send(_ payload: ClipLiveShareWebSocketPayload) async throws {
    let predecessor = sendTail?.task
    let id = UUID()
    let base = base
    let task = Task {
      try await predecessor?.value
      try Task.checkCancellation()
      try await base.send(payload)
    }
    sendTail = (id, task)
    defer { if sendTail?.id == id { sendTail = nil } }
    try await task.value
  }

  func receive() async throws -> ClipLiveShareWebSocketPayload {
    try await base.receive()
  }

  func close() async {
    sendTail?.task.cancel()
    sendTail = nil
    await base.close()
  }
}
