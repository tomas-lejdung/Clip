import ClipLiveShare
import Foundation

public enum ClipLiveShareServerRoomV4SessionRole: Equatable, Sendable {
  case creator
  case candidate
  case member
}

public enum ClipLiveShareServerRoomV4SessionAuthentication: Equatable, Sendable {
  case creator(ownerCapability: ClipLiveShareServerRoomV4OwnerCapability)
  case freshCandidate
  case member(
    handle: ClipLiveShareServerRoomV4MemberHandle,
    reconnectCapability: ClipLiveShareServerRoomV4ReconnectCapability
  )

  public var role: ClipLiveShareServerRoomV4SessionRole {
    switch self {
    case .creator: .creator
    case .freshCandidate: .candidate
    case .member: .member
    }
  }
}

public struct ClipLiveShareServerRoomV4MemberCredentials: Equatable, Sendable {
  public let handle: ClipLiveShareServerRoomV4MemberHandle
  public let reconnectCapability: ClipLiveShareServerRoomV4ReconnectCapability

  public init(
    handle: ClipLiveShareServerRoomV4MemberHandle,
    reconnectCapability: ClipLiveShareServerRoomV4ReconnectCapability
  ) {
    self.handle = handle
    self.reconnectCapability = reconnectCapability
  }
}

public enum ClipLiveShareServerRoomV4TransportEvent: Equatable, Sendable {
  case connecting(role: ClipLiveShareServerRoomV4SessionRole, attempt: Int)
  case connected(role: ClipLiveShareServerRoomV4SessionRole, attempt: Int)
  case message(ClipLiveShareServerRoomV4WireMessage)
  case reconnecting(role: ClipLiveShareServerRoomV4SessionRole, attempt: Int)
  case failed(ClipLiveShareServerRoomV4TransportError)
  case closed
}

/// One authenticated participant socket for a v4 server-coordinated room.
///
/// The actor deliberately exposes the shared package's flat wire messages
/// instead of synthesizing room authority or election state. The server is a
/// bounded router; end-to-end admission, identity, signaling, and media remain
/// above this transport.
public actor ClipLiveShareServerRoomV4Transport {
  private struct Configuration: Sendable {
    let target: ClipLiveShareServerRoomV4Target
    let capabilities: ClipLiveShareServerRoomV4Capabilities
  }

  private struct SocketState: Sendable {
    let id: UUID
    let generation: UInt64
    let socket: ClipLiveShareSerializedWebSocket
  }

  private let webSocketFactory: any ClipLiveShareWebSocketFactory
  private let reconnectPolicy: ClipLiveShareReconnectPolicy
  private let sleeper: any ClipLiveShareReconnectSleeper

  private var generation: UInt64 = 0
  private var configuration: Configuration?
  private var authentication: ClipLiveShareServerRoomV4SessionAuthentication?
  private var pendingCandidateHandle: ClipLiveShareServerRoomV4CandidateHandle?
  private var opening: SocketState?
  private var connection: SocketState?
  private var receiveTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var reconnectToken: UUID?
  private var explicitlyClosing = false
  private var continuations: [
    UUID: AsyncStream<ClipLiveShareServerRoomV4TransportEvent>.Continuation
  ] = [:]

  public init(
    webSocketFactory: any ClipLiveShareWebSocketFactory = URLSessionClipLiveShareWebSocketFactory(),
    reconnectPolicy: ClipLiveShareReconnectPolicy = .boundedExponential,
    reconnectSleeper: any ClipLiveShareReconnectSleeper = ContinuousClipLiveShareReconnectSleeper()
  ) {
    self.webSocketFactory = webSocketFactory
    self.reconnectPolicy = reconnectPolicy
    sleeper = reconnectSleeper
  }

  public func events(
    bufferingLimit: Int = 256
  ) -> AsyncStream<ClipLiveShareServerRoomV4TransportEvent> {
    let id = UUID()
    let pair = AsyncStream.makeStream(
      of: ClipLiveShareServerRoomV4TransportEvent.self,
      bufferingPolicy: .bufferingOldest(max(1, bufferingLimit))
    )
    continuations[id] = pair.continuation
    pair.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(id) }
    }
    return pair.stream
  }

  public func connect(
    to target: ClipLiveShareServerRoomV4Target,
    capabilities: ClipLiveShareServerRoomV4Capabilities,
    authentication: ClipLiveShareServerRoomV4SessionAuthentication
  ) async throws {
    guard
      configuration == nil,
      self.authentication == nil,
      opening == nil,
      connection == nil,
      reconnectTask == nil
    else {
      throw ClipLiveShareServerRoomV4TransportError.connectionAlreadyActive
    }
    generation &+= 1
    let expectedGeneration = generation
    configuration = .init(target: target, capabilities: capabilities)
    self.authentication = authentication
    pendingCandidateHandle = nil
    explicitlyClosing = false
    do {
      try await openConnection(attempt: 0, expectedGeneration: expectedGeneration)
    } catch {
      if generation == expectedGeneration {
        clearSessionState()
      }
      throw map(error)
    }
  }

  public func currentAuthentication(
  ) -> ClipLiveShareServerRoomV4SessionAuthentication? {
    authentication
  }

  public func admittedMemberCredentials(
  ) -> ClipLiveShareServerRoomV4MemberCredentials? {
    guard case .member(let handle, let capability) = authentication else {
      return nil
    }
    return .init(handle: handle, reconnectCapability: capability)
  }

  public func sendJoinKnock(
    sequence: UInt64,
    payload: ClipLiveShareServerRoomV4OpaqueJoinKnock
  ) async throws {
    try await send(.joinKnock(
      candidateHandle: nil,
      sequence: sequence,
      payload: payload
    ))
  }

  public func admitCandidate(
    _ handle: ClipLiveShareServerRoomV4CandidateHandle,
    descriptor: ClipLiveShareServerRoomV4OpaqueAdmissionRecord
  ) async throws {
    try await send(.admitCandidate(candidateHandle: handle, descriptor: descriptor))
  }

  public func denyCandidate(
    _ handle: ClipLiveShareServerRoomV4CandidateHandle,
    reason: String = ""
  ) async throws {
    try await send(.denyCandidate(candidateHandle: handle, reason: reason))
  }

  public func sendPairSignal(
    _ signal: ClipLiveShareServerRoomV4PairSignalEnvelope
  ) async throws {
    try await send(.pairSignal(signal))
  }

  public func removeMember(
    _ handle: ClipLiveShareServerRoomV4MemberHandle
  ) async throws {
    try await send(.removeMember(handle))
  }

  public func send(
    _ message: ClipLiveShareServerRoomV4WireMessage
  ) async throws {
    guard let authentication, let configuration, let active = connection else {
      throw ClipLiveShareServerRoomV4TransportError.notConnected
    }
    try validateOutbound(
      message,
      authentication: authentication,
      capabilities: configuration.capabilities
    )
    let payload: Data
    do {
      payload = try ClipLiveShareServerRoomV4WireCodec.encode(
        message,
        maximumBytes: configuration.capabilities.maximumMessageBytes
      )
    } catch {
      throw map(error)
    }
    guard let text = String(data: payload, encoding: .utf8) else {
      throw ClipLiveShareServerRoomV4TransportError.invalidMessage
    }
    do {
      try await active.socket.send(.text(text))
      guard isCurrentConnection(active) else {
        throw ClipLiveShareServerRoomV4TransportError.operationSuperseded
      }
    } catch let error as ClipLiveShareServerRoomV4TransportError {
      if error == .operationSuperseded { throw error }
      await connectionDidFail(active)
      throw ClipLiveShareServerRoomV4TransportError.sendFailed
    } catch {
      await connectionDidFail(active)
      throw ClipLiveShareServerRoomV4TransportError.sendFailed
    }
  }

  /// Sends the protocol-level leave message and then closes the local socket.
  /// A creator leave ends the server room; a member leave removes only that
  /// member. Unlike `close()`, this never enters reconnect grace.
  public func leave() async {
    explicitlyClosing = true
    if let active = connection, let capabilities = configuration?.capabilities {
      if
        let encoded = try? ClipLiveShareServerRoomV4WireCodec.encode(
          .leaveRoom,
          maximumBytes: capabilities.maximumMessageBytes
        ),
        let text = String(data: encoded, encoding: .utf8)
      {
        try? await active.socket.send(.text(text))
      }
    }
    await stopSession(emitClosed: true)
  }

  /// Closes locally without sending `leave-room`. The server may retain an
  /// admitted participant for its bounded reconnect grace period.
  public func close() async {
    explicitlyClosing = true
    await stopSession(emitClosed: true)
  }

  private func openConnection(
    attempt: Int,
    expectedGeneration: UInt64
  ) async throws {
    guard
      generation == expectedGeneration,
      let configuration,
      let authentication
    else {
      throw ClipLiveShareServerRoomV4TransportError.operationSuperseded
    }
    emit(.connecting(role: authentication.role, attempt: attempt))
    var request = URLRequest(
      url: try configuration.capabilities.roomWebSocketURL(for: configuration.target)
    )
    request.timeoutInterval = 10
    switch authentication {
    case .creator(let ownerCapability):
      request.setValue(
        "Bearer \(ownerCapability.rawValue)",
        forHTTPHeaderField: "Authorization"
      )
    case .freshCandidate:
      break
    case .member(let handle, let reconnectCapability):
      request.setValue(
        "Reconnect \(reconnectCapability.rawValue)",
        forHTTPHeaderField: "Authorization"
      )
      request.setValue(handle.rawValue, forHTTPHeaderField: "X-Clip-Member-Handle")
    }

    let underlying: any ClipLiveShareWebSocketConnection
    do {
      underlying = try await webSocketFactory.makeConnection(for: request)
    } catch {
      throw ClipLiveShareServerRoomV4TransportError.connectionFailed
    }
    let socket = ClipLiveShareSerializedWebSocket(base: underlying)
    let state = SocketState(id: UUID(), generation: expectedGeneration, socket: socket)
    guard generation == expectedGeneration, connection == nil else {
      await socket.close()
      throw ClipLiveShareServerRoomV4TransportError.operationSuperseded
    }
    opening = state
    do {
      try await socket.resume()
      guard isCurrentOpening(state) else {
        throw ClipLiveShareServerRoomV4TransportError.operationSuperseded
      }
    } catch {
      if isCurrentOpening(state) { opening = nil }
      await socket.close()
      throw map(error)
    }
    opening = nil
    connection = state
    emit(.connected(role: authentication.role, attempt: attempt))
    receiveTask = Task { [weak self] in
      await self?.receiveLoop(state)
    }
  }

  private func receiveLoop(_ state: SocketState) async {
    while !Task.isCancelled {
      let payload: ClipLiveShareWebSocketPayload
      do {
        payload = try await state.socket.receive()
      } catch {
        await connectionDidFail(state)
        return
      }
      guard isCurrentConnection(state) else { return }
      do {
        let data: Data
        switch payload {
        case .text(let text):
          data = Data(text.utf8)
        case .data:
          throw ClipLiveShareServerRoomV4TransportError.unsupportedBinaryMessage
        }
        guard let capabilities = configuration?.capabilities else {
          throw ClipLiveShareServerRoomV4TransportError.operationSuperseded
        }
        guard data.count <= capabilities.maximumMessageBytes else {
          throw ClipLiveShareServerRoomV4TransportError.messageTooLarge(
            maximumBytes: capabilities.maximumMessageBytes
          )
        }
        let message = try ClipLiveShareServerRoomV4WireCodec.decode(
          data,
          maximumBytes: capabilities.maximumMessageBytes
        )
        try acceptInbound(message)
        emit(.message(message))
        if isTerminal(message) {
          explicitlyClosing = true
          await stopSession(emitClosed: true)
          return
        }
      } catch {
        let mapped = map(error)
        emit(.failed(mapped))
        explicitlyClosing = true
        await stopSession(emitClosed: true)
        return
      }
    }
  }

  private func acceptInbound(
    _ message: ClipLiveShareServerRoomV4WireMessage
  ) throws {
    guard let authentication else {
      throw ClipLiveShareServerRoomV4TransportError.notConnected
    }
    switch message {
    case .candidateOpened(let handle, _):
      guard case .freshCandidate = authentication, pendingCandidateHandle == nil else {
        throw ClipLiveShareServerRoomV4TransportError.invalidMessage
      }
      pendingCandidateHandle = handle

    case .joinKnock(let handle, _, _):
      guard case .creator = authentication, handle != nil else {
        throw ClipLiveShareServerRoomV4TransportError.invalidMessage
      }

    case .memberAdmitted(let handle, let reconnectCapability, _):
      switch authentication {
      case .freshCandidate:
        guard
          let candidateHandle = pendingCandidateHandle,
          candidateHandle.admittedMemberHandle == handle,
          let reconnectCapability
        else {
          throw ClipLiveShareServerRoomV4TransportError.invalidMessage
        }
        self.authentication = .member(
          handle: handle,
          reconnectCapability: reconnectCapability
        )
        pendingCandidateHandle = nil
      case .creator:
        guard reconnectCapability == nil else {
          throw ClipLiveShareServerRoomV4TransportError.invalidMessage
        }
      case .member(let expectedHandle, let existingCapability):
        guard expectedHandle == handle else {
          throw ClipLiveShareServerRoomV4TransportError.invalidMessage
        }
        if let reconnectCapability, reconnectCapability != existingCapability {
          throw ClipLiveShareServerRoomV4TransportError.invalidMessage
        }
      }

    case .pairSignal(let signal):
      guard signal.from != nil else {
        throw ClipLiveShareServerRoomV4TransportError.invalidMessage
      }

    case .denyCandidate(let handle, _):
      switch authentication {
      case .freshCandidate:
        guard handle == nil else {
          throw ClipLiveShareServerRoomV4TransportError.invalidMessage
        }
      case .creator:
        // A routed handle tells the creator that a pending candidate closed
        // or expired. This is cleanup state, not a terminal room denial.
        guard handle != nil else {
          throw ClipLiveShareServerRoomV4TransportError.invalidMessage
        }
      case .member:
        throw ClipLiveShareServerRoomV4TransportError.invalidMessage
      }

    case .rosterSnapshot, .roomEnded, .protocolError:
      break

    case .admitCandidate, .leaveRoom, .removeMember:
      throw ClipLiveShareServerRoomV4TransportError.invalidMessage
    }
  }

  private func validateOutbound(
    _ message: ClipLiveShareServerRoomV4WireMessage,
    authentication: ClipLiveShareServerRoomV4SessionAuthentication,
    capabilities: ClipLiveShareServerRoomV4Capabilities
  ) throws {
    switch (authentication, message) {
    case (.freshCandidate, .joinKnock(let handle, _, _)) where handle == nil:
      guard pendingCandidateHandle != nil else {
        throw ClipLiveShareServerRoomV4TransportError.invalidMessage
      }
      break
    case (.freshCandidate, .leaveRoom):
      break
    case (.creator, .admitCandidate):
      break
    case (.creator, .denyCandidate(let handle, _)) where handle != nil:
      break
    case (.creator, .pairSignal(let signal)) where signal.from == nil:
      guard signal.ciphertext.count <= capabilities.maximumOpaquePayloadBytes else {
        throw ClipLiveShareServerRoomV4TransportError.messageTooLarge(
          maximumBytes: capabilities.maximumOpaquePayloadBytes
        )
      }
    case (.creator, .removeMember), (.creator, .leaveRoom):
      break
    case (.member, .pairSignal(let signal)) where signal.from == nil:
      guard signal.ciphertext.count <= capabilities.maximumOpaquePayloadBytes else {
        throw ClipLiveShareServerRoomV4TransportError.messageTooLarge(
          maximumBytes: capabilities.maximumOpaquePayloadBytes
        )
      }
    case (.member, .leaveRoom):
      break
    default:
      throw ClipLiveShareServerRoomV4TransportError.invalidMessage
    }
  }

  private func isTerminal(_ message: ClipLiveShareServerRoomV4WireMessage) -> Bool {
    switch message {
    case .denyCandidate(let handle, _): handle == nil
    case .roomEnded: true
    default: false
    }
  }

  private func connectionDidFail(_ state: SocketState) async {
    guard isCurrentConnection(state) else { return }
    connection = nil
    receiveTask = nil
    await state.socket.close()
    guard !explicitlyClosing, let authentication else { return }

    if case .freshCandidate = authentication {
      emit(.failed(.candidateDisconnectedBeforeAdmission))
      clearSessionState()
      emit(.closed)
      return
    }
    scheduleReconnect(expectedGeneration: state.generation)
  }

  private func scheduleReconnect(expectedGeneration: UInt64) {
    guard reconnectTask == nil else { return }
    let token = UUID()
    reconnectToken = token
    reconnectTask = Task { [weak self] in
      await self?.reconnectLoop(token: token, expectedGeneration: expectedGeneration)
    }
  }

  private func reconnectLoop(token: UUID, expectedGeneration: UInt64) async {
    var attempt = 1
    while
      reconnectToken == token,
      generation == expectedGeneration,
      !explicitlyClosing,
      let authentication
    {
      guard let delay = reconnectPolicy.delay(forAttempt: attempt) else { break }
      emit(.reconnecting(role: authentication.role, attempt: attempt))
      do {
        try await sleeper.sleep(for: delay)
        guard
          reconnectToken == token,
          generation == expectedGeneration,
          !explicitlyClosing
        else { return }
        try await openConnection(
          attempt: attempt,
          expectedGeneration: expectedGeneration
        )
        if reconnectToken == token {
          reconnectToken = nil
          reconnectTask = nil
        }
        return
      } catch is CancellationError {
        return
      } catch ClipLiveShareServerRoomV4TransportError.operationSuperseded {
        return
      } catch {
        attempt += 1
      }
    }
    guard
      reconnectToken == token,
      generation == expectedGeneration,
      !explicitlyClosing
    else { return }
    reconnectToken = nil
    reconnectTask = nil
    emit(.failed(.reconnectExhausted))
    clearSessionState()
    emit(.closed)
  }

  private func stopSession(emitClosed: Bool) async {
    generation &+= 1
    let opening = self.opening
    let active = connection
    receiveTask?.cancel()
    reconnectTask?.cancel()
    receiveTask = nil
    reconnectTask = nil
    reconnectToken = nil
    self.opening = nil
    connection = nil
    clearSessionState()
    if let opening { await opening.socket.close() }
    if let active { await active.socket.close() }
    if emitClosed { emit(.closed) }
  }

  private func clearSessionState() {
    configuration = nil
    authentication = nil
    pendingCandidateHandle = nil
    opening = nil
    connection = nil
  }

  private func isCurrentOpening(_ state: SocketState) -> Bool {
    opening?.id == state.id && opening?.generation == state.generation
      && generation == state.generation
  }

  private func isCurrentConnection(_ state: SocketState) -> Bool {
    connection?.id == state.id && connection?.generation == state.generation
      && generation == state.generation
  }

  private func emit(_ event: ClipLiveShareServerRoomV4TransportEvent) {
    var overflowed: [UUID] = []
    for (id, continuation) in continuations {
      if case .dropped = continuation.yield(event) {
        overflowed.append(id)
      }
    }
    for id in overflowed {
      continuations.removeValue(forKey: id)?.finish()
    }
  }

  private func removeContinuation(_ id: UUID) {
    continuations.removeValue(forKey: id)
  }

  private func map(_ error: any Error) -> ClipLiveShareServerRoomV4TransportError {
    if let error = error as? ClipLiveShareServerRoomV4TransportError {
      return error
    }
    if let error = error as? ClipLiveShareProtocolError {
      if case .messageTooLarge(let maximum, _) = error {
        return .messageTooLarge(maximumBytes: maximum)
      }
      return .invalidMessage
    }
    if error is ClipLiveShareServerRoomV4Error {
      return .invalidMessage
    }
    return .connectionFailed
  }
}
