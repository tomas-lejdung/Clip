import ClipLiveShare
import Foundation
import Testing
@testable import Clip

@MainActor
struct NativeFriendPresenceMonitorTests {
    @Test
    func activeFriendsBecomeLiveWhilePreparingRemainsPrivate() async throws {
        let live = makeFriend(name: "Alex", marker: 1)
        let preparing = makeFriend(name: "Mira", marker: 2)
        let model = NativeFriendModel(
            repository: try NativeFriendRepository(
                applicationSupportDirectory: URL(fileURLWithPath: "/presence")
            ),
            initialBook: NativeFriendBook(records: [live, preparing])
        )
        let monitor = NativeFriendPresenceMonitor(friends: model) { record in
            record.id == live.id ? .live : .offline
        }

        await monitor.refresh()

        #expect(model.recordAvailableForJoin(id: live.id) == live)
        #expect(model.recordAvailableForJoin(id: preparing.id) == nil)
        #expect(model.presentationSnapshots.first(where: { $0.id == live.id })?.presence == .live)
        #expect(model.presentationSnapshots.first(where: { $0.id == preparing.id })?.presence == .offline)
    }

    @Test
    func blockedFriendCannotBeMadeJoinableByProbe() async throws {
        var blocked = makeFriend(name: "Blocked", marker: 3)
        blocked.trustState = .blocked
        let model = NativeFriendModel(
            repository: try NativeFriendRepository(
                applicationSupportDirectory: URL(fileURLWithPath: "/presence-blocked")
            ),
            initialBook: NativeFriendBook(records: [blocked])
        )
        let monitor = NativeFriendPresenceMonitor(friends: model) { _ in .live }

        await monitor.refresh()

        #expect(model.recordAvailableForJoin(id: blocked.id) == nil)
        #expect(model.presentationSnapshots.isEmpty)
    }

    private func makeFriend(name: String, marker: UInt8) -> NativeFriendRecord {
        let signer = NativeDeviceIdentitySigner()
        return NativeFriendRecord(
            identity: signer.publicKey,
            displayName: name,
            deviceName: "Mac",
            endpoint: .official,
            rendezvousID: try! .init(
                bytes: Data(
                    repeating: marker,
                    count: ClipLiveShareNativeV2.rendezvousIDByteCount
                )
            )
        )
    }
}
