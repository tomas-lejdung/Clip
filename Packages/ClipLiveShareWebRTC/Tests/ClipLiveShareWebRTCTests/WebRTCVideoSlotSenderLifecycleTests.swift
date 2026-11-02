import ClipLiveShare
import Foundation
import Testing
@testable import ClipLiveShareWebRTC

extension NativeMediaResourceTests {
  @Suite("Video slot RTP sender lifecycle")
  struct WebRTCVideoSlotSenderLifecycleTests {
    @Test("publication activates only its sender and reshare toggles it again")
    func publicationControlsSenderActivity() async throws {
      try await withVideoSlotSenderFixture { factory, transport in
        #expect(transport.videoSenderEncodingActivity == activity())
        let initialTracks = factory.slotSnapshots.map(\.trackID)

        try activateVideoSlot(0, in: factory)
        #expect(transport.videoSenderEncodingActivity == activity(active: [0]))
        try activateVideoSlot(2, in: factory)
        #expect(transport.videoSenderEncodingActivity == activity(active: [0, 2]))

        factory.deactivateSlot(0)
        #expect(transport.videoSenderEncodingActivity == activity(active: [2]))
        try activateVideoSlot(0, in: factory)
        #expect(transport.videoSenderEncodingActivity == activity(active: [0, 2]))
        #expect(factory.slotSnapshots.map(\.trackID) == initialTracks)
      }
    }

    @Test("admitting a provisional peer enables only published slots")
    func admissionPreservesInactiveSlots() async throws {
      try await withVideoSlotSenderFixture(outboundInitiallyEnabled: false) { factory, transport in
        try activateVideoSlot(1, in: factory)
        #expect(transport.videoSenderEncodingActivity == activity())
        await transport.setOutboundMediaEnabled(true)
        #expect(transport.videoSenderEncodingActivity == activity(active: [1]))

        await transport.setOutboundMediaEnabled(false)
        try activateVideoSlot(3, in: factory)
        factory.deactivateSlot(1)
        #expect(transport.videoSenderEncodingActivity == activity())
        await transport.setOutboundMediaEnabled(true)
        #expect(transport.videoSenderEncodingActivity == activity(active: [3]))
      }
    }

    @Test("a new peer inherits exact publication state")
    func prepublishedSlotsSeedNewPeer() async throws {
      try await withVideoSlotSenderFixture(prepublishedSlots: [1, 3]) { _, transport in
        #expect(transport.videoSenderEncodingActivity == activity(active: [1, 3]))
      }
    }

    @Test("out-of-order publication snapshots cannot disable a newer source")
    func stalePublicationSnapshotIsIgnored() async throws {
      try await withVideoSlotSenderFixture { _, transport in
        transport.updateActiveLocalVideoSlots([2], revision: 2)
        transport.updateActiveLocalVideoSlots([0], revision: 1)
        #expect(transport.videoSenderEncodingActivity == activity(active: [2]))

        transport.updateActiveLocalVideoSlots([], revision: 3)
        transport.updateActiveLocalVideoSlots([2], revision: 2)
        #expect(transport.videoSenderEncodingActivity == activity())
      }
    }

    @Test("a peer seeded from current publication state rejects older snapshots")
    func initialPublicationRevisionIsRetained() async throws {
      try await withVideoSlotSenderFixture(prepublishedSlots: [1, 3]) { _, transport in
        transport.updateActiveLocalVideoSlots([0], revision: 1)
        #expect(transport.videoSenderEncodingActivity == activity(active: [1, 3]))
      }
    }

    private func activity(active slots: Set<Int> = []) -> [Int: [Bool]] {
      Dictionary(uniqueKeysWithValues: (0..<4).map { ($0, [slots.contains($0)]) })
    }
  }
}

private func activateVideoSlot(
  _ index: Int,
  in factory: ClipLiveShareNativeV3WebRTCTransportFactory
) throws {
  let slot = try #require(factory.slotSnapshots.first { $0.index == index })
  try factory.activateSlot(
    index,
    metadata: ClipLiveShareWebRTCTestFixtures.streamDescriptor(for: slot),
    captureGeometry: .init(width: 1_280, height: 720)
  )
}

private func withVideoSlotSenderFixture(
  outboundInitiallyEnabled: Bool = true,
  prepublishedSlots: [Int] = [],
  _ operation: (
    ClipLiveShareNativeV3WebRTCTransportFactory,
    ClipLiveShareNativeV3WebRTCPeerLinkTransport
  ) async throws -> Void
) async throws {
  let factory = try ClipLiveShareNativeV3WebRTCTransportFactory(
    configuration: .init(peer: .init(iceServers: [], videoCodec: .vp8))
  )
  defer { factory.close() }
  for slot in prepublishedSlots {
    try activateVideoSlot(slot, in: factory)
  }
  let localID = try ClipLiveShareNativeV3ParticipantID(bytes: Data(repeating: 0x10, count: 16))
  let remoteID = try ClipLiveShareNativeV3ParticipantID(bytes: Data(repeating: 0x20, count: 16))
  let key = try ClipLiveShareNativeV3PeerLinkKey(localID, remoteID)
  let transport = try #require(await factory.makeTransport(
    configuration: .init(
      key: key,
      localParticipantID: localID,
      outboundMediaInitiallyEnabled: outboundInitiallyEnabled
    )
  ) as? ClipLiveShareNativeV3WebRTCPeerLinkTransport)
  do {
    try await operation(factory, transport)
  } catch {
    await transport.close()
    throw error
  }
  await transport.close()
}
