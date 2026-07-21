import Foundation

public enum LiveSharePhase: String, Codable, CaseIterable, Hashable, Sendable {
  case idle
  case reservingRoom
  case connecting
  case ready
  case starting
  case sharing
  case reconnecting
  case stopping
  case failed
}

public enum LiveShareFailureCode: String, Codable, Hashable, Sendable {
  case reservationFailed
  case signalingFailed
  case captureFailed
  case encoderFailed
  case peerConnectionFailed
  case connectionLost
  case unknown
}

public struct LiveShareFailure: Error, Codable, Equatable, Hashable, Sendable {
  public let code: LiveShareFailureCode
  public let technicalDescription: String?

  public init(code: LiveShareFailureCode, technicalDescription: String? = nil) {
    self.code = code
    self.technicalDescription = technicalDescription
  }
}

public enum LiveShareTransitionError: Error, Equatable, Sendable {
  case invalidTransition(from: LiveSharePhase, operation: String)
  case noSelectedSources
  case negativeViewerCount(Int)
  case invalidReconnectAttempt(Int)
}

/// The share-link information the UI is allowed to render. Room ownership,
/// the P-256 private key, encrypted-route state, and access-code challenges are
/// deliberately kept out of the domain snapshot.
public struct ClipLiveSharePublicRoom: Codable, Equatable, Hashable, Sendable {
  public let name: ClipLiveShareRoomName
  public let viewerURL: URL

  public init(name: ClipLiveShareRoomName, viewerURL: URL) {
    self.name = name
    self.viewerURL = viewerURL
  }
}

/// A read-only value suitable for UI rendering and cross-actor delivery.
public struct LiveShareSnapshot: Codable, Equatable, Hashable, Sendable {
  public let phase: LiveSharePhase
  public let sources: LiveShareSourceSelection
  public let room: ClipLiveSharePublicRoom?
  public let viewerCount: Int
  public let reconnectAttempt: Int
  public let failure: LiveShareFailure?

  public var isSessionConnected: Bool {
    [.ready, .starting, .sharing, .stopping].contains(phase)
  }

  public var isSharingMedia: Bool { phase == .starting || phase == .sharing }
}

/// A deterministic domain state machine. It performs no I/O and owns no capture,
/// signaling, or WebRTC objects.
public struct LiveShareStateMachine: Sendable {
  private var phase: LiveSharePhase
  private var sources: LiveShareSourceSelection
  private var room: ClipLiveSharePublicRoom?
  private var viewerCount: Int
  private var reconnectAttempt: Int
  private var failure: LiveShareFailure?
  private var phaseAfterReconnect: LiveSharePhase?

  public init() {
    phase = .idle
    sources = .empty
    room = nil
    viewerCount = 0
    reconnectAttempt = 0
    failure = nil
    phaseAfterReconnect = nil
  }

  public var snapshot: LiveShareSnapshot {
    LiveShareSnapshot(
      phase: phase,
      sources: sources,
      room: room,
      viewerCount: viewerCount,
      reconnectAttempt: reconnectAttempt,
      failure: failure
    )
  }

  public mutating func beginRoomReservation() throws {
    guard phase == .idle || phase == .failed else {
      throw invalidTransition("beginRoomReservation")
    }
    phase = .reservingRoom
    room = nil
    viewerCount = 0
    reconnectAttempt = 0
    failure = nil
    phaseAfterReconnect = nil
  }

  public mutating func receiveRoom(_ room: ClipLiveSharePublicRoom) throws {
    guard phase == .reservingRoom else {
      throw invalidTransition("receiveRoom")
    }
    self.room = room
    phase = .connecting
  }

  public mutating func markSignalingConnected() throws {
    guard phase == .connecting, room != nil else {
      throw invalidTransition("markSignalingConnected")
    }
    phase = .ready
    reconnectAttempt = 0
  }

  @discardableResult
  public mutating func addSource(_ source: LiveShareSource) -> LiveShareSourceChange {
    let change = sources.adding(source)
    sources = change.selection
    return change
  }

  @discardableResult
  public mutating func removeSource(_ id: LiveShareSourceID) -> LiveShareSourceChange {
    let change = sources.removing(id)
    sources = change.selection
    normalizePhaseAfterSourceRemoval()
    return change
  }

  @discardableResult
  public mutating func toggleSource(_ source: LiveShareSource) -> LiveShareSourceChange {
    let change = sources.toggling(source)
    sources = change.selection
    normalizePhaseAfterSourceRemoval()
    return change
  }

  @discardableResult
  public mutating func replaceWindows(
    with window: LiveShareWindowSource
  ) -> LiveShareSourceChange {
    let change = sources.replacingWindows(with: window)
    sources = change.selection
    return change
  }

  @discardableResult
  public mutating func markWindowAsMostRecentlyUsed(
    _ id: LiveShareWindowID
  ) -> LiveShareSourceChange {
    let change = sources.markingWindowAsMostRecentlyUsed(id)
    sources = change.selection
    return change
  }

  @discardableResult
  public mutating func clearSources() -> LiveShareSourceChange {
    let change = sources.clearing()
    sources = change.selection
    normalizePhaseAfterSourceRemoval()
    return change
  }

  public mutating func beginSharing() throws {
    guard phase == .ready else {
      throw invalidTransition("beginSharing")
    }
    guard !sources.isEmpty else {
      throw LiveShareTransitionError.noSelectedSources
    }
    phase = .starting
  }

  public mutating func markSharingStarted() throws {
    guard phase == .starting else {
      throw invalidTransition("markSharingStarted")
    }
    phase = .sharing
  }

  public mutating func beginStopping() throws {
    guard phase == .starting || phase == .sharing || phase == .reconnecting else {
      throw invalidTransition("beginStopping")
    }
    phase = .stopping
    phaseAfterReconnect = nil
  }

  /// Stops every media source while retaining the room and connected viewers so
  /// sharing can resume without making browsers reconnect.
  public mutating func completeStopping() throws {
    guard phase == .stopping else {
      throw invalidTransition("completeStopping")
    }
    phase = .ready
    sources = .empty
    reconnectAttempt = 0
  }

  public mutating func markConnectionLost() throws {
    guard [.connecting, .ready, .starting, .sharing, .stopping].contains(phase) else {
      throw invalidTransition("markConnectionLost")
    }
    switch phase {
    case .starting:
      phaseAfterReconnect = .starting
    case .sharing:
      phaseAfterReconnect = .sharing
    case .stopping:
      phaseAfterReconnect = .ready
    default:
      phaseAfterReconnect = .ready
    }
    phase = .reconnecting
    reconnectAttempt = 1
  }

  public mutating func scheduleReconnect(attempt: Int) throws {
    guard phase == .reconnecting else {
      throw invalidTransition("scheduleReconnect")
    }
    guard attempt > 0, attempt >= reconnectAttempt else {
      throw LiveShareTransitionError.invalidReconnectAttempt(attempt)
    }
    reconnectAttempt = attempt
  }

  public mutating func markReconnected() throws {
    guard phase == .reconnecting, room != nil else {
      throw invalidTransition("markReconnected")
    }
    phase = phaseAfterReconnect ?? .ready
    phaseAfterReconnect = nil
    reconnectAttempt = 0
  }

  public mutating func updateViewerCount(_ count: Int) throws {
    guard count >= 0 else {
      throw LiveShareTransitionError.negativeViewerCount(count)
    }
    viewerCount = count
  }

  public mutating func fail(_ failure: LiveShareFailure) {
    phase = .failed
    self.failure = failure
    phaseAfterReconnect = nil
  }

  public mutating func disconnect() {
    self = Self()
  }

  private func invalidTransition(_ operation: String) -> LiveShareTransitionError {
    .invalidTransition(from: phase, operation: operation)
  }

  private mutating func normalizePhaseAfterSourceRemoval() {
    guard sources.isEmpty else { return }
    if phase == .starting || phase == .sharing {
      phase = .ready
    } else if phase == .reconnecting {
      phaseAfterReconnect = .ready
    }
  }
}
