import Combine
import ClipCore
import Foundation
import OSLog

struct ResolvedDirectoryBookmark: Equatable, Sendable {
    let url: URL
    let isStale: Bool
}

@MainActor
protocol DirectoryBookmarkServicing: AnyObject, Sendable {
    func isDirectory(_ url: URL) -> Bool
    func makeSecurityScopedBookmark(for url: URL) throws -> Data
    func resolveSecurityScopedBookmark(_ data: Data) throws -> ResolvedDirectoryBookmark
    func startAccessing(_ url: URL) -> Bool
    nonisolated func stopAccessing(_ url: URL)
}

@MainActor
final class LiveDirectoryBookmarkService: DirectoryBookmarkServicing {
    func isDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func makeSecurityScopedBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
    }

    func resolveSecurityScopedBookmark(_ data: Data) throws -> ResolvedDirectoryBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedDirectoryBookmark(url: url.standardizedFileURL, isStale: isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    nonisolated func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

enum DefaultSaveDirectoryError: LocalizedError, Equatable, Sendable {
    case mustBeFileURL
    case directoryDoesNotExist(URL)
    case accessWasDenied(URL)

    var errorDescription: String? {
        switch self {
        case .mustBeFileURL:
            String(localized: "The default Save As location must be a local folder.")
        case .directoryDoesNotExist:
            String(localized: "The selected Save As folder is no longer available.")
        case .accessWasDenied:
            String(localized: "Clip could not keep access to the selected folder. Choose it again.")
        }
    }
}

private struct DefaultSaveDirectoryBookmark: Codable, Equatable, Sendable {
    let data: Data
}

@MainActor
final class AppSettingsModel: ObservableObject {
    private let store: SettingsJSONStore
    private let defaultSaveDirectoryBookmarkStore: AtomicJSONFileStore<DefaultSaveDirectoryBookmark>
    private let directoryBookmarks: any DirectoryBookmarkServicing
    private var activeSecurityScopedDirectory: URL?
    private var persistenceTail: Task<Void, Never>?

    @Published private(set) var settings: ClipSettings
    @Published private(set) var isLoaded = false
    @Published private(set) var lastPersistenceError: String?
    @Published private(set) var defaultSaveDirectoryAccessError: String?

    init(
        applicationSupportDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        initialSettings: ClipSettings? = nil,
        settingsFileSystem: any AtomicFileSystem = LocalAtomicFileSystem(),
        directoryBookmarks: any DirectoryBookmarkServicing = LiveDirectoryBookmarkService()
    ) throws {
        settings = initialSettings ?? ClipSettings.defaults(homeDirectory: homeDirectory)
        store = try SettingsJSONStore(
            fileURL: applicationSupportDirectory.appendingPathComponent("settings.json"),
            fileSystem: settingsFileSystem
        )
        defaultSaveDirectoryBookmarkStore = try AtomicJSONFileStore(
            fileURL: applicationSupportDirectory
                .appendingPathComponent("default-save-directory-bookmark.json")
        )
        self.directoryBookmarks = directoryBookmarks
    }

    deinit {
        if let activeSecurityScopedDirectory {
            directoryBookmarks.stopAccessing(activeSecurityScopedDirectory)
        }
    }

    func load() async {
        do {
            settings = try await store.load(or: settings)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = reportStorageError(
                error,
                operation: "Load settings"
            )
        }
        await restoreDefaultSaveDirectoryAccess()
        isLoaded = true
    }

    func replace(with updatedSettings: ClipSettings) async {
        settings = updatedSettings
        await persist()
    }

    /// Persists both the display path and a security-scoped bookmark. The bookmark is
    /// deliberately stored outside `ClipSettings` so the cross-platform settings domain
    /// remains free of App Sandbox implementation details.
    func setDefaultSaveDirectory(_ selectedURL: URL) async throws {
        guard selectedURL.isFileURL else {
            throw DefaultSaveDirectoryError.mustBeFileURL
        }

        let directoryURL = selectedURL.standardizedFileURL
        guard directoryBookmarks.isDirectory(directoryURL) else {
            throw DefaultSaveDirectoryError.directoryDoesNotExist(directoryURL)
        }

        let bookmark = try directoryBookmarks.makeSecurityScopedBookmark(for: directoryURL)
        guard directoryBookmarks.startAccessing(directoryURL) else {
            throw DefaultSaveDirectoryError.accessWasDenied(directoryURL)
        }

        do {
            try await defaultSaveDirectoryBookmarkStore.save(
                DefaultSaveDirectoryBookmark(data: bookmark)
            )
        } catch {
            directoryBookmarks.stopAccessing(directoryURL)
            throw error
        }

        replaceActiveSecurityScopedDirectory(with: directoryURL)
        settings.defaultSaveDirectory = directoryURL
        defaultSaveDirectoryAccessError = nil
        await persist()
    }

    func update(_ mutation: (inout ClipSettings) throws -> Void) async rethrows {
        var updatedSettings = settings
        try mutation(&updatedSettings)
        settings = updatedSettings
        await persist()
    }

    /// Publishes a small, permission-free preference change before returning,
    /// then queues its snapshot for ordered persistence. Menu quick controls
    /// use this so an immediately requested capture observes the new value.
    @discardableResult
    func updateImmediately(
        _ mutation: (inout ClipSettings) -> Void
    ) -> Task<Void, Never> {
        var updatedSettings = settings
        mutation(&updatedSettings)
        settings = updatedSettings
        return enqueuePersistence()
    }

    /// Waits until every settings snapshot queued before this call is durable.
    /// Application termination uses this to preserve a just-changed quick setting.
    func flushPendingPersistence() async {
        await persistenceTail?.value
    }

    private func persist() async {
        await enqueuePersistence().value
    }

    /// Chains saves explicitly because actor methods can interleave while their
    /// filesystem awaits. This guarantees an older snapshot can never finish
    /// after and overwrite a newer preference value.
    private func enqueuePersistence() -> Task<Void, Never> {
        let previous = persistenceTail
        let snapshot = settings
        let store = store
        let task = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await store.save(snapshot)
                self?.lastPersistenceError = nil
            } catch {
                guard let self else { return }
                self.lastPersistenceError = self.reportStorageError(
                    error,
                    operation: "Save settings"
                )
            }
        }
        persistenceTail = task
        return task
    }

    private func restoreDefaultSaveDirectoryAccess() async {
        do {
            guard let storedBookmark = try await defaultSaveDirectoryBookmarkStore.load() else {
                defaultSaveDirectoryAccessError = nil
                return
            }

            let resolved = try directoryBookmarks.resolveSecurityScopedBookmark(
                storedBookmark.data
            )
            guard resolved.url.isFileURL,
                  directoryBookmarks.isDirectory(resolved.url) else {
                throw DefaultSaveDirectoryError.directoryDoesNotExist(resolved.url)
            }
            guard directoryBookmarks.startAccessing(resolved.url) else {
                throw DefaultSaveDirectoryError.accessWasDenied(resolved.url)
            }

            if resolved.isStale {
                do {
                    let refreshed = try directoryBookmarks.makeSecurityScopedBookmark(
                        for: resolved.url
                    )
                    try await defaultSaveDirectoryBookmarkStore.save(
                        DefaultSaveDirectoryBookmark(data: refreshed)
                    )
                } catch {
                    directoryBookmarks.stopAccessing(resolved.url)
                    throw error
                }
            }

            replaceActiveSecurityScopedDirectory(with: resolved.url)
            settings.defaultSaveDirectory = resolved.url
            defaultSaveDirectoryAccessError = nil
        } catch {
            defaultSaveDirectoryAccessError = reportStorageError(
                error,
                operation: "Restore default Save As folder"
            )
        }
    }

    private func reportStorageError(
        _ error: any Error,
        operation: String
    ) -> String {
        let details = UserFacingErrorPresentation.details(for: error)
        ClipLog.storage.error(
            "Settings operation failed (\(operation, privacy: .public)): \(details.technicalDescription, privacy: .private)"
        )
        return details.message
    }

    /// Takes ownership of an already-started access session and balances the previous one.
    private func replaceActiveSecurityScopedDirectory(with directoryURL: URL) {
        if let previous = activeSecurityScopedDirectory {
            directoryBookmarks.stopAccessing(previous)
        }
        activeSecurityScopedDirectory = directoryURL
    }
}
