import ClipLiveShareWebRTC
import Foundation

@MainActor
final class NativeFriendPresenceMonitor {
    typealias Probe = @Sendable (NativeFriendRecord) async -> LiveShareFriendPresence

    private let friends: NativeFriendModel
    private let interval: Duration
    private let probe: Probe
    private var task: Task<Void, Never>?

    init(
        friends: NativeFriendModel,
        interval: Duration = .seconds(4),
        probe: Probe? = nil
    ) {
        self.friends = friends
        self.interval = interval
        self.probe = probe ?? Self.liveProbe
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await refresh()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refresh() async {
        let records = friends.recordsEligibleForPresenceProbe
        let probe = self.probe
        let results = await withTaskGroup(
            of: (String, LiveShareFriendPresence).self,
            returning: [(String, LiveShareFriendPresence)].self
        ) { group in
            for record in records {
                group.addTask { (record.id, await probe(record)) }
            }
            var values: [(String, LiveShareFriendPresence)] = []
            for await value in group { values.append(value) }
            return values
        }
        guard !Task.isCancelled else { return }
        let currentIDs = Set(records.map(\.id))
        for record in friends.book.records where !currentIDs.contains(record.id) {
            friends.setPresence(.offline, id: record.id)
        }
        for (id, presence) in results {
            friends.setPresence(presence, id: id)
        }
    }

    private static func liveProbe(
        _ friend: NativeFriendRecord
    ) async -> LiveShareFriendPresence {
        do {
            let target = try ClipNativeRendezvousTarget(
                endpoint: friend.endpoint.rootURL,
                rendezvousID: friend.rendezvousID.bytes
            )
            let client = ClipNativeRendezvousHTTPClient()
            let capabilities = try await client.discover(at: friend.endpoint.rootURL)
            let status = try await client.status(target, capabilities: capabilities)
            // Preparation is intentionally private: Friends become joinable
            // only after the host explicitly presses Start and publishes an
            // active signed descriptor.
            return status.state == .active ? .live : .offline
        } catch {
            return .offline
        }
    }
}
