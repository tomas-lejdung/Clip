import Foundation

/// Schedules a short, event-driven retained-frame burst when a new peer becomes
/// connected. Static ScreenCaptureKit sources can remain idle indefinitely, so
/// a peer that joins after the last natural frame otherwise has no image to
/// encode until the source changes again.
///
/// The burst is deliberately finite and low-rate. A later trigger supersedes
/// any pending callbacks from the earlier trigger, which bounds work even when
/// several mesh links connect or reconnect close together.
final class WebRTCRetainedFrameReplayBurst: @unchecked Sendable {
  typealias Replay = @Sendable () -> Void
  typealias Scheduler = @Sendable (
    _ delayNanoseconds: UInt64,
    _ action: @escaping @Sendable () -> Void
  ) -> Void

  static let defaultAttemptDelaysNanoseconds: [UInt64] = [
    0,
    250_000_000,
    750_000_000,
    1_750_000_000,
  ]

  /// Natural capture wins over retained replay. This interval limits a frozen
  /// source to at most five retained frames per second during the finite burst.
  static let minimumIdleIntervalNanoseconds: UInt64 = 200_000_000

  private let lock = NSLock()
  private let attemptDelaysNanoseconds: [UInt64]
  private let scheduler: Scheduler
  private var generation: UInt64 = 0

  init(
    attemptDelaysNanoseconds: [UInt64] =
      WebRTCRetainedFrameReplayBurst.defaultAttemptDelaysNanoseconds,
    scheduler: @escaping Scheduler = WebRTCRetainedFrameReplayBurst
      .dispatchScheduler
  ) {
    self.attemptDelaysNanoseconds = attemptDelaysNanoseconds
    self.scheduler = scheduler
  }

  func trigger(_ replay: @escaping Replay) {
    let currentGeneration = lock.withLock { () -> UInt64 in
      generation &+= 1
      return generation
    }
    for delay in attemptDelaysNanoseconds {
      scheduler(delay) { [weak self] in
        guard let self, isCurrent(currentGeneration) else { return }
        replay()
      }
    }
  }

  func cancel() {
    lock.withLock { generation &+= 1 }
  }

  private func isCurrent(_ candidate: UInt64) -> Bool {
    lock.withLock { generation == candidate }
  }

  private static let dispatchScheduler: Scheduler = { delay, action in
    DispatchQueue.global(qos: .userInteractive).asyncAfter(
      deadline: .now() + .nanoseconds(Int(clamping: delay)),
      execute: action
    )
  }
}

enum WebRTCRetainedFrameReplayPolicy {
  static func shouldTriggerAfterOutboundMediaChange(
    wasEnabled: Bool,
    isEnabled: Bool,
    connectionState: WebRTCPeerConnectionState
  ) -> Bool {
    !wasEnabled && isEnabled && connectionState == .connected
  }
}
