import AppKit
import ClipCore
import ClipMedia
import CoreMedia
import Foundation
import UniformTypeIdentifiers

enum PreviewExportCoordinatorError: LocalizedError {
    case sourceHasNoVideo
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .sourceHasNoVideo:
            String(localized: "The recording does not contain a usable video track.")
        case .invalidDestination:
            String(localized: "Choose a valid destination for the MP4 file.")
        }
    }
}

actor PreviewExportCoordinator {
    static let staleExportLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// Bump whenever encoding or reuse semantics change so an export created by
    /// an older build cannot mask a fidelity/cadence fix in a newer build.
    static let cacheSchemaVersion = 3

    private let exportsDirectory: URL
    private let exporter: any MediaExporting

    init(
        exportsDirectory: URL,
        exporter: any MediaExporting = NativeAssetExporter()
    ) {
        self.exportsDirectory = exportsDirectory
        self.exporter = exporter
    }

    /// Returns a Clip-managed export whose lifetime is intentionally longer
    /// than a pasteboard or drag session. Cache identity includes every option
    /// that changes encoded bytes.
    func export(_ request: PreviewExportRequest) async throws -> URL {
        let inspection = try await MediaInspector.inspect(request.sourceURL)
        guard inspection.videoTrackCount > 0,
              inspection.width > 0,
              inspection.height > 0 else {
            throw PreviewExportCoordinatorError.sourceHasNoVideo
        }

        let outputDirectory = exportsDirectory
            .appendingPathComponent(request.recordingID.description, isDirectory: true)
            .appendingPathComponent(cacheKey(for: request), isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let outputURL = outputDirectory.appendingPathComponent(request.filename.fileName)
        let expectedAudioTrackCount = request.audioPreference.includesAudio
            && inspection.audioTrackCount > 0 ? 1 : 0

        if FileManager.default.isReadableFile(atPath: outputURL.path),
           let existing = try? await MediaInspector.inspect(outputURL),
           existing.videoTrackCount > 0,
           existing.audioTrackCount == expectedAudioTrackCount,
           abs(existing.duration - request.trimRange.duration) <= (1.0 / 24.0) {
            return outputURL
        }

        let mediaConfiguration = mediaConfiguration(for: request, inspection: inspection)
        let range = CMTimeRange(
            start: CMTime(seconds: request.trimRange.startTime, preferredTimescale: 600),
            duration: CMTime(seconds: request.trimRange.duration, preferredTimescale: 600)
        )

        return try await exporter.export(
            sourceURL: request.sourceURL,
            destinationURL: outputURL,
            timeRange: range,
            configuration: mediaConfiguration
        )
    }

    /// Removes only Clip's UUID/cache-key export directories after their files
    /// have been untouched for the configured grace period. The actor boundary
    /// serializes cleanup with export publication, and the seven-day default
    /// keeps promised drag and pasteboard file URLs alive for receiving apps.
    @discardableResult
    func removeStaleExports(olderThan cutoff: Date) throws -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: exportsDirectory.path) else { return 0 }

        let recordingDirectories = try fileManager.contentsOfDirectory(
            at: exportsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var removedCount = 0

        for recordingDirectory in recordingDirectories {
            guard UUID(uuidString: recordingDirectory.lastPathComponent) != nil,
                  try recordingDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                continue
            }

            let cacheDirectories = try fileManager.contentsOfDirectory(
                at: recordingDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for cacheDirectory in cacheDirectories {
                guard try cacheDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                      try newestModificationDate(in: cacheDirectory, fileManager: fileManager) < cutoff else {
                    continue
                }
                try fileManager.removeItem(at: cacheDirectory)
                removedCount += 1
            }

            if try fileManager.contentsOfDirectory(atPath: recordingDirectory.path).isEmpty {
                try fileManager.removeItem(at: recordingDirectory)
            }
        }
        return removedCount
    }

    private func mediaPreset(for preset: ExportPreset) -> MediaExportPreset {
        switch preset {
        case .compact: .compact
        case .crisp: .crisp
        case .smallest: .smallest
        }
    }

    /// Uses durable capture metadata for the cadence ceiling rather than
    /// rounding `nominalFramesPerSecond`. Screen-content samples are commonly
    /// variable-rate, so a 30 FPS capture may legitimately inspect as 28.29.
    func mediaConfiguration(
        for request: PreviewExportRequest,
        inspection: MediaInspection
    ) -> MediaExportConfiguration {
        let approximateTarget = request.configuration.preset == .smallest
            ? Double(request.configuration.smallestSizeTarget.megabytes)
            : nil
        return MediaExportConfigurationFactory.make(
            preset: mediaPreset(for: request.configuration.preset),
            sourceWidth: inspection.width,
            sourceHeight: inspection.height,
            sourceFramesPerSecond: request.captureFrameRate.framesPerSecond,
            duration: request.trimRange.duration,
            approximateTargetMegabytes: approximateTarget,
            includesAudio: request.audioPreference.includesAudio
        )
    }

    func cacheKey(for request: PreviewExportRequest) -> String {
        let start = Int64((request.trimRange.startTime * 1_000).rounded())
        let end = Int64((request.trimRange.endTime * 1_000).rounded())
        let target = request.configuration.preset == .smallest
            ? "-\(request.configuration.smallestSizeTarget.megabytes)mb"
            : ""
        let audio = request.audioPreference.includesAudio ? "audio" : "silent"
        let frameRate = request.captureFrameRate.framesPerSecond
        return "v\(Self.cacheSchemaVersion)-\(start)-\(end)"
            + "-\(request.configuration.preset.rawValue)\(target)"
            + "-\(frameRate)fps-\(audio)"
    }

    private func newestModificationDate(
        in directory: URL,
        fileManager: FileManager
    ) throws -> Date {
        var newest = try directory.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate ?? .distantPast
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return newest
        }
        for case let url as URL in enumerator {
            let modificationDate = try url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate ?? .distantPast
            newest = max(newest, modificationDate)
        }
        return newest
    }
}

struct SaveDestinationRequest: Equatable, Sendable {
    let filename: String
    let initialDirectory: URL
}

@MainActor
protocol SaveDestinationChoosing: AnyObject {
    func chooseDestination(for request: SaveDestinationRequest) async -> URL?
}

@MainActor
final class SystemSaveDestinationChooser: SaveDestinationChoosing {
    func chooseDestination(for request: SaveDestinationRequest) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = request.filename
        panel.directoryURL = request.initialDirectory
        panel.message = String(
            localized: "Save an independent MP4 file. Clip will never delete it."
        )

        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }
}

@MainActor
protocol SecurityScopedResourceAccessing: AnyObject {
    func stopAccessing(_ url: URL)
}

@MainActor
final class LiveSecurityScopedResourceAccess: SecurityScopedResourceAccessing {
    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

protocol UserAuthorizedSaveFileSystem {
    func itemExists(at url: URL) -> Bool
    func copyItem(from sourceURL: URL, to destinationURL: URL) throws
    func replaceItem(at destinationURL: URL, with sourceURL: URL) throws
    func removeItem(at url: URL) throws
}

struct LiveUserAuthorizedSaveFileSystem: UserAuthorizedSaveFileSystem {
    func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func copyItem(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        _ = try FileManager.default.replaceItemAt(
            destinationURL,
            withItemAt: sourceURL
        )
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Publishes a complete managed export through the exact URL authorized by
/// NSSavePanel. The staging copy deliberately lives beside the managed source
/// inside Clip's container: a Powerbox grant for `Downloads/clip.mp4` does not
/// authorize creating arbitrary hidden siblings in Downloads.
enum UserAuthorizedFileReplacement {
    static func replaceOrCreate(
        from sourceURL: URL,
        to destinationURL: URL,
        fileSystem: any UserAuthorizedSaveFileSystem = LiveUserAuthorizedSaveFileSystem(),
        tokenGenerator: @Sendable () -> UUID = { UUID() }
    ) throws {
        if AtomicFileReplacement.sameResolvedPath(sourceURL, destinationURL) {
            return
        }

        let stagingURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            ".clip-save-\(tokenGenerator().uuidString.lowercased()).temporary"
        )
        guard !fileSystem.itemExists(at: stagingURL) else {
            throw CocoaError(.fileWriteFileExists)
        }
        defer { try? fileSystem.removeItem(at: stagingURL) }

        try fileSystem.copyItem(from: sourceURL, to: stagingURL)
        if fileSystem.itemExists(at: destinationURL) {
            try fileSystem.replaceItem(at: destinationURL, with: stagingURL)
        } else {
            // The selected destination itself is covered by the Save Panel
            // extension. Do not probe or create its parent directory.
            do {
                try fileSystem.copyItem(from: stagingURL, to: destinationURL)
            } catch {
                // `FileManager.copyItem` may leave a partial destination when
                // the volume fills or access is interrupted. This exact URL was
                // explicitly authorized and did not exist before our attempt,
                // so remove only that incomplete new file. Existing user files
                // continue to use the atomic replacement branch above.
                try? fileSystem.removeItem(at: destinationURL)
                throw error
            }
        }
    }
}

@MainActor
final class UserAuthorizedFileSaveService {
    private let destinationChooser: any SaveDestinationChoosing
    private let securityScope: any SecurityScopedResourceAccessing
    private let fileSystem: any UserAuthorizedSaveFileSystem

    init(
        destinationChooser: any SaveDestinationChoosing = SystemSaveDestinationChooser(),
        securityScope: any SecurityScopedResourceAccessing = LiveSecurityScopedResourceAccess(),
        fileSystem: any UserAuthorizedSaveFileSystem = LiveUserAuthorizedSaveFileSystem()
    ) {
        self.destinationChooser = destinationChooser
        self.securityScope = securityScope
        self.fileSystem = fileSystem
    }

    func save(
        filename: String,
        initialDirectory: URL,
        produceExport: @MainActor () async throws -> URL
    ) async throws -> URL? {
        guard let destinationURL = await destinationChooser.chooseDestination(
            for: SaveDestinationRequest(
                filename: filename,
                initialDirectory: initialDirectory
            )
        ) else {
            return nil
        }

        // macOS starts security-scoped access for URLs returned by NSSavePanel.
        // Balance that implicit session after the complete file is published.
        defer { securityScope.stopAccessing(destinationURL) }
        guard destinationURL.isFileURL else {
            throw PreviewExportCoordinatorError.invalidDestination
        }

        let managedExport = try await produceExport()
        try UserAuthorizedFileReplacement.replaceOrCreate(
            from: managedExport,
            to: destinationURL,
            fileSystem: fileSystem
        )
        return destinationURL
    }
}

@MainActor
final class PreviewSharingService {
    private let exports: PreviewExportCoordinator
    private let pasteboard: any PasteboardServicing
    private let settings: AppSettingsModel
    private let fileSaver: UserAuthorizedFileSaveService

    init(
        exports: PreviewExportCoordinator,
        pasteboard: any PasteboardServicing,
        settings: AppSettingsModel,
        fileSaver: UserAuthorizedFileSaveService = UserAuthorizedFileSaveService()
    ) {
        self.exports = exports
        self.pasteboard = pasteboard
        self.settings = settings
        self.fileSaver = fileSaver
    }

    func copy(_ request: PreviewExportRequest) async throws -> URL {
        let outputURL = try await exports.export(request)
        try pasteboard.placeFile(at: outputURL)
        return outputURL
    }

    func saveAs(_ request: PreviewExportRequest) async throws -> URL? {
        try await fileSaver.save(
            filename: request.filename.fileName,
            initialDirectory: settings.settings.defaultSaveDirectory
        ) {
            try await exports.export(request)
        }
    }
}
