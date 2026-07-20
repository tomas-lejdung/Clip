import Combine
import ClipCore
import ClipLiveShare
import Foundation

actor LiveShareSettingsRepository {
    private let store: AtomicJSONFileStore<LiveShareSettings>

    init(
        applicationSupportDirectory: URL,
        fileSystem: any AtomicFileSystem = LocalAtomicFileSystem()
    ) throws {
        store = try AtomicJSONFileStore(
            fileURL: applicationSupportDirectory
                .appendingPathComponent("live-share-settings.json"),
            fileSystem: fileSystem
        )
    }

    func load() async throws -> LiveShareSettings {
        try await store.load() ?? .default
    }

    func save(_ settings: LiveShareSettings) async throws {
        try await store.save(settings)
    }
}

actor LiveShareServerEndpointRepository {
    private let store: AtomicJSONFileStore<LiveShareServerEndpoint>

    init(
        applicationSupportDirectory: URL,
        fileSystem: any AtomicFileSystem = LocalAtomicFileSystem()
    ) throws {
        store = try AtomicJSONFileStore(
            fileURL: applicationSupportDirectory
                .appendingPathComponent("live-share-server-settings.json"),
            fileSystem: fileSystem
        )
    }

    func load() async throws -> LiveShareServerEndpoint {
        try await store.load() ?? .goPeepRemote
    }

    func save(_ endpoint: LiveShareServerEndpoint) async throws {
        try await store.save(endpoint)
    }
}

/// The single application-owned source of truth for Live Share defaults.
/// Active-session controls publish their changes through this model, so an
/// open Settings window and the menu popover never race separate file writers.
/// A coordinator snapshots `serverEndpoint` when it starts; changing the
/// endpoint therefore applies only to the next room.
@MainActor
final class LiveSharePreferencesModel: ObservableObject {
    private let settingsRepository: LiveShareSettingsRepository
    private let endpointRepository: LiveShareServerEndpointRepository
    private var settingsPersistenceTail: Task<Void, Never>?
    private var endpointPersistenceTail: Task<Void, Never>?
    private var settingsPersistenceError: String?
    private var endpointPersistenceError: String?

    @Published private(set) var settings: LiveShareSettings
    @Published private(set) var serverEndpoint: LiveShareServerEndpoint
    @Published private(set) var isLoaded = false
    @Published private(set) var lastPersistenceError: String?

    init(
        applicationSupportDirectory: URL,
        initialSettings: LiveShareSettings = .default,
        initialServerEndpoint: LiveShareServerEndpoint = .goPeepRemote,
        settingsFileSystem: any AtomicFileSystem = LocalAtomicFileSystem(),
        endpointFileSystem: any AtomicFileSystem = LocalAtomicFileSystem()
    ) throws {
        settings = initialSettings
        serverEndpoint = initialServerEndpoint
        settingsRepository = try LiveShareSettingsRepository(
            applicationSupportDirectory: applicationSupportDirectory,
            fileSystem: settingsFileSystem
        )
        endpointRepository = try LiveShareServerEndpointRepository(
            applicationSupportDirectory: applicationSupportDirectory,
            fileSystem: endpointFileSystem
        )
    }

    func load() async {
        settingsPersistenceError = nil
        endpointPersistenceError = nil
        do {
            settings = try await settingsRepository.load()
        } catch {
            do {
                try await settingsRepository.save(settings)
            } catch {
                settingsPersistenceError = String(
                    localized: "Live Share defaults could not be loaded or repaired."
                )
            }
        }
        do {
            serverEndpoint = try await endpointRepository.load()
        } catch {
            serverEndpoint = .goPeepRemote
            do {
                try await endpointRepository.save(serverEndpoint)
            } catch {
                endpointPersistenceError = String(
                    localized: "The Live Share server address could not be loaded or reset."
                )
            }
        }
        refreshPersistenceError()
        isLoaded = true
    }

    func updateSettings(
        _ mutation: (inout LiveShareSettings) -> Void
    ) {
        var updated = settings
        mutation(&updated)
        replaceSettings(with: updated)
    }

    func replaceSettings(with updated: LiveShareSettings) {
        guard settings != updated else { return }
        settings = updated
        enqueueSettingsPersistence(updated)
    }

    func restoreSessionDefaults() {
        replaceSettings(with: .default)
    }

    func setServerEndpoint(_ endpoint: LiveShareServerEndpoint) {
        guard serverEndpoint != endpoint else { return }
        serverEndpoint = endpoint
        enqueueEndpointPersistence(endpoint)
    }

    func setServerAddress(_ address: String) throws {
        setServerEndpoint(try LiveShareServerEndpoint(userInput: address))
    }

    func resetServerEndpoint() {
        setServerEndpoint(.goPeepRemote)
    }

    func flushPendingPersistence() async {
        await settingsPersistenceTail?.value
        await endpointPersistenceTail?.value
    }

    private func enqueueSettingsPersistence(
        _ snapshot: LiveShareSettings
    ) {
        let previous = settingsPersistenceTail
        let repository = settingsRepository
        let task = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await repository.save(snapshot)
                self?.settingsPersistenceError = nil
            } catch {
                self?.settingsPersistenceError = String(
                    localized: "Live Share defaults could not be saved."
                )
            }
            self?.refreshPersistenceError()
        }
        settingsPersistenceTail = task
    }

    private func enqueueEndpointPersistence(
        _ snapshot: LiveShareServerEndpoint
    ) {
        let previous = endpointPersistenceTail
        let repository = endpointRepository
        let task = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await repository.save(snapshot)
                self?.endpointPersistenceError = nil
            } catch {
                self?.endpointPersistenceError = String(
                    localized: "The Live Share server address could not be saved."
                )
            }
            self?.refreshPersistenceError()
        }
        endpointPersistenceTail = task
    }

    private func refreshPersistenceError() {
        let failures = [settingsPersistenceError, endpointPersistenceError]
            .compactMap { $0 }
        lastPersistenceError = failures.isEmpty ? nil : failures.joined(separator: " ")
    }
}

enum LiveShareServerConnectionProbeError: LocalizedError, Equatable, Sendable {
    case unreachable
    case invalidResponse
    case incompatibleStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unreachable:
            String(localized: "Clip could not reach this Live Share server.")
        case .invalidResponse:
            String(localized: "The Live Share server returned an invalid response.")
        case let .incompatibleStatus(status):
            String(
                localized: "The server does not expose a compatible reservation endpoint (HTTP \(status))."
            )
        }
    }
}

/// A HEAD request verifies the configured reservation route and TLS connection
/// without allocating a room. GoPeep v1 answers HEAD with 405 because the route
/// deliberately accepts POST only; a future health-aware server may answer 2xx.
struct LiveShareServerConnectionProbe: Sendable {
    typealias Execute = @Sendable (URLRequest) async throws -> Int

    private let execute: Execute

    init(execute: @escaping Execute) {
        self.execute = execute
    }

    func test(_ endpoint: LiveShareServerEndpoint) async throws {
        let server = try endpoint.configuration
        var request = URLRequest(url: server.reservationURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let status: Int
        do {
            status = try await execute(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LiveShareServerConnectionProbeError.unreachable
        }
        guard (200..<300).contains(status) || status == 405 else {
            throw LiveShareServerConnectionProbeError.incompatibleStatus(status)
        }
    }

    static let live = Self { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LiveShareServerConnectionProbeError.invalidResponse
        }
        return response.statusCode
    }
}
