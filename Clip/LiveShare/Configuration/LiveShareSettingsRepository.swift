import ClipCore
import ClipLiveShare
import Foundation

actor LiveShareSettingsRepository {
    private let store: AtomicJSONFileStore<LiveShareSettings>

    init(applicationSupportDirectory: URL) throws {
        store = try AtomicJSONFileStore(
            fileURL: applicationSupportDirectory
                .appendingPathComponent("live-share-settings.json")
        )
    }

    func load() async throws -> LiveShareSettings {
        try await store.load() ?? .default
    }

    func save(_ settings: LiveShareSettings) async throws {
        try await store.save(settings)
    }
}
