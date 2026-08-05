import Foundation
import Testing
@testable import ClipLiveShareWebRTC

@Suite("Retained WebRTC frame replay burst")
struct WebRTCRetainedFrameReplayBurstTests {
  @Test("a connection event schedules one finite ordered burst")
  func finiteOrderedBurst() {
    let scheduler = ManualReplayScheduler()
    let replayCount = LockedReplayCount()
    let burst = WebRTCRetainedFrameReplayBurst(
      scheduler: { delay, action in
        scheduler.schedule(after: delay, action)
      }
    )

    burst.trigger { replayCount.increment() }

    #expect(
      scheduler.delays
        == WebRTCRetainedFrameReplayBurst.defaultAttemptDelaysNanoseconds
    )
    scheduler.runAll()
    #expect(replayCount.value == 4)
    #expect(scheduler.pendingCount == 0)
  }

  @Test("a newer connection event supersedes pending callbacks")
  func newerTriggerSupersedesPendingCallbacks() {
    let scheduler = ManualReplayScheduler()
    let firstReplayCount = LockedReplayCount()
    let secondReplayCount = LockedReplayCount()
    let burst = WebRTCRetainedFrameReplayBurst(
      scheduler: { delay, action in
        scheduler.schedule(after: delay, action)
      }
    )

    burst.trigger { firstReplayCount.increment() }
    burst.trigger { secondReplayCount.increment() }
    scheduler.runAll()

    #expect(firstReplayCount.value == 0)
    #expect(secondReplayCount.value == 4)
  }

  @Test("closing the factory can cancel every pending replay")
  func cancellationInvalidatesPendingCallbacks() {
    let scheduler = ManualReplayScheduler()
    let replayCount = LockedReplayCount()
    let burst = WebRTCRetainedFrameReplayBurst(
      scheduler: { delay, action in
        scheduler.schedule(after: delay, action)
      }
    )

    burst.trigger { replayCount.increment() }
    burst.cancel()
    scheduler.runAll()

    #expect(replayCount.value == 0)
  }

  @Test("an empty replay policy schedules no work")
  func emptyPolicySchedulesNothing() {
    let scheduler = ManualReplayScheduler()
    let replayCount = LockedReplayCount()
    let burst = WebRTCRetainedFrameReplayBurst(
      attemptDelaysNanoseconds: [],
      scheduler: { delay, action in
        scheduler.schedule(after: delay, action)
      }
    )

    burst.trigger { replayCount.increment() }

    #expect(scheduler.pendingCount == 0)
    #expect(replayCount.value == 0)
  }

  @Test("approving a connected provisional peer starts retained replay")
  func connectedApprovalStartsReplay() {
    #expect(WebRTCRetainedFrameReplayPolicy
      .shouldTriggerAfterOutboundMediaChange(
        wasEnabled: false,
        isEnabled: true,
        connectionState: .connected
      ))
  }

  @Test("redundant enable and pre-connection approval stay inert")
  func redundantOrPrematureEnableStaysInert() {
    #expect(!WebRTCRetainedFrameReplayPolicy
      .shouldTriggerAfterOutboundMediaChange(
        wasEnabled: true,
        isEnabled: true,
        connectionState: .connected
      ))
    #expect(!WebRTCRetainedFrameReplayPolicy
      .shouldTriggerAfterOutboundMediaChange(
        wasEnabled: false,
        isEnabled: true,
        connectionState: .connecting
      ))
    #expect(!WebRTCRetainedFrameReplayPolicy
      .shouldTriggerAfterOutboundMediaChange(
        wasEnabled: true,
        isEnabled: false,
        connectionState: .connected
      ))
  }
}

private final class ManualReplayScheduler: @unchecked Sendable {
  private struct PendingAction: Sendable {
    let delayNanoseconds: UInt64
    let action: @Sendable () -> Void
  }

  private let lock = NSLock()
  private var pending: [PendingAction] = []

  var delays: [UInt64] {
    lock.withLock { pending.map(\.delayNanoseconds) }
  }

  var pendingCount: Int {
    lock.withLock { pending.count }
  }

  func schedule(
    after delayNanoseconds: UInt64,
    _ action: @escaping @Sendable () -> Void
  ) {
    lock.withLock {
      pending.append(PendingAction(
        delayNanoseconds: delayNanoseconds,
        action: action
      ))
    }
  }

  func runAll() {
    while true {
      let next = lock.withLock { () -> PendingAction? in
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
      }
      guard let next else { return }
      next.action()
    }
  }
}

private final class LockedReplayCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}
