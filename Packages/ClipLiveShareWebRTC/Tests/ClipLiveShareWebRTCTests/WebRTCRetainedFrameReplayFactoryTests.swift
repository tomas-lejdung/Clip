import ClipCapture
import Foundation
import Testing
@testable import ClipLiveShareWebRTC

extension NativeMediaResourceTests {
  @Suite("Retained frame replay factory integration")
  struct WebRTCRetainedFrameReplayFactoryTests {
    @Test("connection callback replays active slot but not deactivated or closed slots")
    func callbackRespectsCurrentFactoryLifetime() throws {
      let scheduler = FactoryReplayScheduler()
      let emittedSlots = FactoryReplayEmissionRecorder()
      let factory = try ClipLiveShareNativeV3WebRTCTransportFactory(
        configuration: .init(peer: .init(
          iceServers: [],
          videoCodec: .vp8
        )),
        retainedFrameReplayBurst: WebRTCRetainedFrameReplayBurst(
          attemptDelaysNanoseconds: [0],
          scheduler: { delay, action in
            scheduler.schedule(after: delay, action)
          }
        ),
        retainedFrameMinimumIdleIntervalNanoseconds: 0,
        retainedFrameReplayObserver: { slot in
          emittedSlots.record(slot)
        }
      )
      defer { factory.close() }

      let slot = try #require(factory.slotSnapshots.first)
      let geometry = WebRTCVideoCaptureGeometry(width: 64, height: 48)
      let descriptor = ClipLiveShareWebRTCTestFixtures.streamDescriptor(
        for: slot,
        width: geometry.width,
        height: geometry.height
      )

      try factory.activateSlot(
        slot.index,
        metadata: descriptor,
        captureGeometry: geometry
      )
      #expect(factory.send(
        try makeRetainedFrameFixture(
          width: geometry.width,
          height: geometry.height
        ),
        toSlot: slot.index
      ) == .accepted)

      factory.retainedFrameReplayRequest()
      #expect(scheduler.pendingCount == 1)
      scheduler.runAll()
      #expect(emittedSlots.values == [slot.index])

      factory.deactivateSlot(slot.index)
      try factory.activateSlot(
        slot.index,
        metadata: descriptor,
        captureGeometry: geometry
      )
      #expect(factory.send(
        try makeRetainedFrameFixture(
          width: geometry.width,
          height: geometry.height
        ),
        toSlot: slot.index
      ) == .accepted)
      factory.retainedFrameReplayRequest()
      factory.deactivateSlot(slot.index)
      scheduler.runAll()
      #expect(emittedSlots.values == [slot.index])

      try factory.activateSlot(
        slot.index,
        metadata: descriptor,
        captureGeometry: geometry
      )
      #expect(factory.send(
        try makeRetainedFrameFixture(
          width: geometry.width,
          height: geometry.height
        ),
        toSlot: slot.index
      ) == .accepted)
      factory.retainedFrameReplayRequest()
      factory.close()
      scheduler.runAll()
      #expect(emittedSlots.values == [slot.index])
    }
  }
}

private final class FactoryReplayScheduler: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [@Sendable () -> Void] = []

  var pendingCount: Int {
    lock.withLock { pending.count }
  }

  func schedule(
    after delayNanoseconds: UInt64,
    _ action: @escaping @Sendable () -> Void
  ) {
    _ = delayNanoseconds
    lock.withLock { pending.append(action) }
  }

  func runAll() {
    while true {
      let next = lock.withLock { () -> (@Sendable () -> Void)? in
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
      }
      guard let next else { return }
      next()
    }
  }
}

private final class FactoryReplayEmissionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var slots: [Int] = []

  var values: [Int] {
    lock.withLock { slots }
  }

  func record(_ slot: Int) {
    lock.withLock { slots.append(slot) }
  }
}
