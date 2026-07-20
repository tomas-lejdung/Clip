import Foundation
import Testing

@testable import ClipLiveShare

@Suite("Live-share state machine")
struct LiveShareStateMachineTests {
  private func readyMachine() throws -> LiveShareStateMachine {
    var machine = LiveShareStateMachine()
    try machine.beginRoomReservation()
    try machine.receiveReservation(makeReservation(), password: "tiger-42")
    try machine.markSignalingConnected()
    return machine
  }

  @Test("Initial snapshot is immutable, inert, and empty")
  func initialState() {
    let machine = LiveShareStateMachine()
    let snapshot = machine.snapshot
    #expect(snapshot.phase == .idle)
    #expect(snapshot.sources.isEmpty)
    #expect(snapshot.room == nil)
    #expect(snapshot.viewerCount == 0)
    #expect(snapshot.reconnectAttempt == 0)
    #expect(snapshot.failure == nil)
    #expect(!snapshot.isSessionConnected)
  }

  @Test("Room reservation transitions to a connected ready session")
  func reservationFlow() throws {
    var machine = LiveShareStateMachine()
    try machine.beginRoomReservation()
    #expect(machine.snapshot.phase == .reservingRoom)

    try machine.receiveReservation(makeReservation(), password: "tiger-42")
    #expect(machine.snapshot.phase == .connecting)
    #expect(machine.snapshot.room?.room.rawValue == "CRISP-FROG-042")
    #expect(machine.snapshot.room?.password == "tiger-42")

    try machine.markSignalingConnected()
    #expect(machine.snapshot.phase == .ready)
    #expect(machine.snapshot.isSessionConnected)
  }

  @Test("Sharing requires a selected source and explicit capture confirmation")
  func startSharing() throws {
    var machine = try readyMachine()
    #expect(throws: LiveShareTransitionError.noSelectedSources) {
      try machine.beginSharing()
    }

    machine.addSource(.window(makeWindow(1)))
    try machine.beginSharing()
    #expect(machine.snapshot.phase == .starting)
    #expect(machine.snapshot.isSharingMedia)

    try machine.markSharingStarted()
    #expect(machine.snapshot.phase == .sharing)
    #expect(machine.snapshot.sources.windows.map(\.id.rawValue) == [1])
  }

  @Test("Sources can be replaced dynamically while sharing")
  func dynamicSources() throws {
    var machine = try readyMachine()
    machine.addSource(.window(makeWindow(1)))
    try machine.beginSharing()
    try machine.markSharingStarted()

    machine.addSource(.window(makeWindow(2)))
    machine.addSource(.fullscreen(makeDisplay(4)))
    #expect(machine.snapshot.phase == .sharing)
    #expect(machine.snapshot.sources.windows.isEmpty)
    #expect(machine.snapshot.sources.fullscreen == makeDisplay(4))

    machine.addSource(.window(makeWindow(5)))
    #expect(machine.snapshot.sources.fullscreen == nil)
    #expect(machine.snapshot.sources.windows == [makeWindow(5)])
  }

  @Test("Removing the final source returns to ready without ending the room")
  func removingFinalSource() throws {
    var machine = try readyMachine()
    let source = makeWindow(1)
    machine.addSource(.window(source))
    try machine.beginSharing()
    try machine.markSharingStarted()
    try machine.updateViewerCount(2)

    machine.removeSource(.window(source.id))

    #expect(machine.snapshot.phase == .ready)
    #expect(machine.snapshot.sources.isEmpty)
    #expect(machine.snapshot.viewerCount == 2)
    #expect(machine.snapshot.room != nil)
  }

  @Test("Stop All clears media while retaining the room and connected viewers")
  func stopRetainsRoom() throws {
    var machine = try readyMachine()
    machine.addSource(.window(makeWindow(1)))
    try machine.beginSharing()
    try machine.markSharingStarted()
    try machine.updateViewerCount(2)
    let room = machine.snapshot.room

    try machine.beginStopping()
    #expect(machine.snapshot.phase == .stopping)
    try machine.completeStopping()

    #expect(machine.snapshot.phase == .ready)
    #expect(machine.snapshot.room == room)
    #expect(machine.snapshot.sources.isEmpty)
    #expect(machine.snapshot.viewerCount == 2)
  }

  @Test("Reconnect restores a live share and preserves source state")
  func reconnectSharing() throws {
    var machine = try readyMachine()
    machine.addSource(.window(makeWindow(8)))
    try machine.beginSharing()
    try machine.markSharingStarted()
    try machine.updateViewerCount(1)

    try machine.markConnectionLost()
    #expect(machine.snapshot.phase == .reconnecting)
    #expect(machine.snapshot.reconnectAttempt == 1)
    #expect(machine.snapshot.sources.windows == [makeWindow(8)])

    try machine.scheduleReconnect(attempt: 4)
    #expect(machine.snapshot.reconnectAttempt == 4)
    try machine.markReconnected()
    #expect(machine.snapshot.phase == .sharing)
    #expect(machine.snapshot.reconnectAttempt == 0)
  }

  @Test("Reconnect while capture is starting preserves the pending start")
  func reconnectStarting() throws {
    var machine = try readyMachine()
    machine.addSource(.window(makeWindow(8)))
    try machine.beginSharing()
    try machine.markConnectionLost()
    #expect(machine.snapshot.phase == .reconnecting)
    try machine.markReconnected()
    #expect(machine.snapshot.phase == .starting)
    try machine.markSharingStarted()
    #expect(machine.snapshot.phase == .sharing)
  }

  @Test("Reconnect from a nonsharing state returns ready")
  func reconnectReady() throws {
    var machine = try readyMachine()
    try machine.markConnectionLost()
    try machine.markReconnected()
    #expect(machine.snapshot.phase == .ready)
  }

  @Test("Removing all media during reconnect recovers to ready")
  func stopMediaDuringReconnect() throws {
    var machine = try readyMachine()
    let source = makeWindow(9)
    machine.addSource(.window(source))
    try machine.beginSharing()
    try machine.markSharingStarted()
    try machine.markConnectionLost()

    machine.removeSource(.window(source.id))
    #expect(machine.snapshot.phase == .reconnecting)
    #expect(machine.snapshot.sources.isEmpty)
    try machine.markReconnected()
    #expect(machine.snapshot.phase == .ready)
  }

  @Test("Connection loss during Stop All reconnects to a ready empty room")
  func reconnectWhileStopping() throws {
    var machine = try readyMachine()
    machine.addSource(.window(makeWindow(10)))
    try machine.beginSharing()
    try machine.markSharingStarted()
    try machine.updateViewerCount(2)
    try machine.beginStopping()

    try machine.markConnectionLost()
    #expect(machine.snapshot.phase == .reconnecting)
    machine.clearSources()
    try machine.markReconnected()

    #expect(machine.snapshot.phase == .ready)
    #expect(machine.snapshot.sources.isEmpty)
    #expect(machine.snapshot.viewerCount == 2)
  }

  @Test("Viewer counts and reconnect attempts reject impossible values")
  func countValidation() throws {
    var machine = try readyMachine()
    #expect(throws: LiveShareTransitionError.negativeViewerCount(-1)) {
      try machine.updateViewerCount(-1)
    }
    try machine.markConnectionLost()
    #expect(throws: LiveShareTransitionError.invalidReconnectAttempt(0)) {
      try machine.scheduleReconnect(attempt: 0)
    }
    try machine.scheduleReconnect(attempt: 3)
    #expect(throws: LiveShareTransitionError.invalidReconnectAttempt(2)) {
      try machine.scheduleReconnect(attempt: 2)
    }
  }

  @Test("Invalid lifecycle operations report their source phase")
  func invalidTransitions() throws {
    var machine = LiveShareStateMachine()
    #expect(
      throws: LiveShareTransitionError.invalidTransition(
        from: .idle,
        operation: "beginSharing"
      )
    ) {
      try machine.beginSharing()
    }
    #expect(
      throws: LiveShareTransitionError.invalidTransition(
        from: .idle,
        operation: "markSignalingConnected"
      )
    ) {
      try machine.markSignalingConnected()
    }
  }

  @Test("Failure is visible in snapshots and a new reservation clears it")
  func failureRecovery() throws {
    var machine = try readyMachine()
    let failure = LiveShareFailure(
      code: .signalingFailed,
      technicalDescription: "socket closed"
    )
    machine.fail(failure)
    #expect(machine.snapshot.phase == .failed)
    #expect(machine.snapshot.failure == failure)

    try machine.beginRoomReservation()
    #expect(machine.snapshot.phase == .reservingRoom)
    #expect(machine.snapshot.failure == nil)
  }

  @Test("Disconnect resets every session value")
  func disconnect() throws {
    var machine = try readyMachine()
    machine.addSource(.fullscreen(makeDisplay()))
    try machine.updateViewerCount(3)
    machine.disconnect()
    #expect(machine.snapshot == LiveShareStateMachine().snapshot)
  }

  @Test("Snapshots round-trip through Codable independently of the machine")
  func snapshotCodable() throws {
    var machine = try readyMachine()
    machine.addSource(.window(makeWindow(4)))
    try machine.updateViewerCount(2)
    let snapshot = machine.snapshot
    let decoded = try JSONDecoder().decode(
      LiveShareSnapshot.self,
      from: JSONEncoder().encode(snapshot)
    )
    #expect(decoded == snapshot)
  }
}
