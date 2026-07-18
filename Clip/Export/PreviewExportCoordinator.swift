import AppKit
import ClipCore
import ClipMedia
import CoreMedia
import Foundation
import UniformTypeIdentifiers

enum PreviewExportCoordinatorError: LocalizedError {
    case sourceHasNoVideo
    case invalidDestination
    case invalidManagedExport(URL)
    case managedExportNotFound(ManagedExportID)
    case managedExportInUse(ManagedExportID)

    var errorDescription: String? {
        switch self {
        case .sourceHasNoVideo:
            String(localized: "The recording does not contain a usable video track.")
        case .invalidDestination:
            String(localized: "Choose a valid destination for the MP4 file.")
        case .invalidManagedExport:
            String(localized: "Clip could not verify this managed export.")
        case .managedExportNotFound:
            String(localized: "This export is no longer available. Refresh Exports and try again.")
        case .managedExportInUse:
            String(localized: "This export is currently in use. Try again when sharing finishes.")
        }
    }
}

/// Stable identity for one published file inside Clip's managed export cache.
///
/// The raw value is a validated path relative to the Exports root:
/// `<recording UUID>/<encoding cache key>/<filename>.mp4`. Coordinator APIs
/// validate it again before touching disk, so a caller cannot use a crafted ID
/// to escape the cache directory.
struct ManagedExportID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

struct ManagedExportRecord: Identifiable, Equatable, Sendable {
    let id: ManagedExportID
    let recordingID: RecordingID
    let url: URL
    let filename: RecordingFilename
    let byteCount: Int64
    /// First time this physical cache file was successfully published by Copy
    /// or an accepted file drag. Reusing the same cache entry preserves it.
    let createdAt: Date
    let preset: ExportPreset
    let qualityPercent: Int
}

struct ManagedExportInventory: Equatable, Sendable {
    let items: [ManagedExportRecord]
    let totalByteCount: Int64

    static let empty = ManagedExportInventory(items: [], totalByteCount: 0)
}

/// A bounded ownership hold spanning export completion through external
/// publication and durable inventory registration. The opaque token is useful
/// only to the coordinator instance that issued it.
struct ManagedExportPublicationLease: Equatable, Sendable {
    fileprivate let token: UUID
    fileprivate let exportID: ManagedExportID
    let outputURL: URL
}

private struct ManagedExportPublicationMarker: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: ManagedExportID
    let recordingID: RecordingID
    let filename: RecordingFilename
    let createdAt: Date
    let preset: ExportPreset
    let qualityPercent: Int

    init(
        id: ManagedExportID,
        recordingID: RecordingID,
        filename: RecordingFilename,
        createdAt: Date,
        preset: ExportPreset,
        qualityPercent: Int
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.recordingID = recordingID
        self.filename = filename
        self.createdAt = createdAt
        self.preset = preset
        self.qualityPercent = qualityPercent
    }
}

private struct ManagedExportPublicationManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var records: [ManagedExportPublicationMarker]

    init(records: [ManagedExportPublicationMarker] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.records = records
    }
}

extension ManagedExportID: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

actor PreviewExportCoordinator {
    static let staleExportLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let publicationLeaseLifetime: TimeInterval = 5 * 60
    /// Bump whenever encoding or reuse semantics change so an export created by
    /// an older build cannot mask a fidelity/cadence fix in a newer build.
    static let cacheSchemaVersion = 4

    private let exportsDirectory: URL
    private let exporter: any MediaExporting
    private let now: @Sendable () -> Date
    private let tokenGenerator: @Sendable () -> UUID
    /// Actors are reentrant across exporter awaits. Counts let destructive
    /// inventory operations and stale cleanup recognize an export that is
    /// still being inspected or encoded rather than deleting underneath it.
    private var activeExportCounts: [ManagedExportID: Int] = [:]
    private var publicationLeases: [UUID: PublicationLeaseState] = [:]

    private struct PublicationLeaseState {
        let exportID: ManagedExportID
        let outputURL: URL
        let expiresAt: Date
    }

    private struct ManagedExportLocation {
        let id: ManagedExportID
        let recordingID: RecordingID
        let cacheKey: String
        let filename: RecordingFilename
        let recordingDirectory: URL
        let cacheDirectory: URL
        let fileURL: URL
    }

    private struct ExportPlan {
        let id: ManagedExportID
        let outputDirectory: URL
        let outputURL: URL
    }

    private struct RegularFileValues {
        let fileSize: Int64
    }

    private static let publicationManifestFilename = ".clip-published-exports-v1.json"

    init(
        exportsDirectory: URL,
        exporter: any MediaExporting = NativeAssetExporter(),
        now: @escaping @Sendable () -> Date = { Date() },
        tokenGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.exportsDirectory = exportsDirectory.standardizedFileURL
        self.exporter = exporter
        self.now = now
        self.tokenGenerator = tokenGenerator
    }

    /// Returns a Clip-managed export whose lifetime is intentionally longer
    /// than a pasteboard or drag session. Cache identity includes every option
    /// that changes encoded bytes.
    func export(_ request: PreviewExportRequest) async throws -> URL {
        let plan = try exportPlan(for: request)
        retainActiveExport(plan.id)
        defer { finishActiveExport(plan.id) }
        return try await performExport(request, plan: plan)
    }

    /// Exports and immediately converts the encoder's active hold into a
    /// bounded publication lease without yielding the actor between them.
    /// This closes the window in which stale cleanup or an Exports purge could
    /// otherwise delete a reused cache URL before Copy/drag registers it.
    func exportForPublication(
        _ request: PreviewExportRequest
    ) async throws -> ManagedExportPublicationLease {
        let plan = try exportPlan(for: request)
        retainActiveExport(plan.id)
        do {
            let outputURL = try await performExport(request, plan: plan)
            // The active export hold becomes the lease's hold. Keeping that
            // single count continuously retained is what closes the cleanup
            // race; acquiring a new hold after `export()` returned would not.
            return try makePublicationLease(
                request,
                outputURL: outputURL,
                expectedID: plan.id,
                acquireActiveHold: false
            )
        } catch {
            finishActiveExport(plan.id)
            throw error
        }
    }

    /// Starts a bounded lease for an already-complete managed export. The
    /// combined `exportForPublication` API is the safe production path; this
    /// lower-level form also supports deterministic fixtures and future cache
    /// adoption without exposing lease bookkeeping.
    func beginPublication(
        _ request: PreviewExportRequest,
        outputURL: URL
    ) throws -> ManagedExportPublicationLease {
        let expectedID = makeExportID(
            recordingID: request.recordingID,
            cacheKey: cacheKey(for: request),
            filename: request.filename
        )
        return try makePublicationLease(
            request,
            outputURL: outputURL,
            expectedID: expectedID,
            acquireActiveHold: true
        )
    }

    private func makePublicationLease(
        _ request: PreviewExportRequest,
        outputURL: URL,
        expectedID: ManagedExportID,
        acquireActiveHold: Bool
    ) throws -> ManagedExportPublicationLease {
        let issuedAt = now()
        releaseExpiredPublicationLeases(at: issuedAt)
        let requestID = makeExportID(
            recordingID: request.recordingID,
            cacheKey: cacheKey(for: request),
            filename: request.filename
        )
        guard requestID == expectedID else {
            throw PreviewExportCoordinatorError.invalidManagedExport(outputURL)
        }
        let location = try managedLocation(for: expectedID)
        guard sameResolvedPath(location.fileURL, outputURL),
              regularFileValues(at: location.fileURL) != nil else {
            throw PreviewExportCoordinatorError.invalidManagedExport(outputURL)
        }
        let token = tokenGenerator()
        guard publicationLeases[token] == nil else {
            throw PreviewExportCoordinatorError.invalidManagedExport(outputURL)
        }
        let resolvedOutputURL = location.fileURL.standardizedFileURL
        if acquireActiveHold {
            retainActiveExport(expectedID)
        }
        publicationLeases[token] = PublicationLeaseState(
            exportID: expectedID,
            outputURL: resolvedOutputURL,
            expiresAt: issuedAt.addingTimeInterval(Self.publicationLeaseLifetime)
        )
        return ManagedExportPublicationLease(
            token: token,
            exportID: expectedID,
            outputURL: resolvedOutputURL
        )
    }

    private func exportPlan(for request: PreviewExportRequest) throws -> ExportPlan {
        let cacheKey = cacheKey(for: request)
        let id = makeExportID(
            recordingID: request.recordingID,
            cacheKey: cacheKey,
            filename: request.filename
        )
        let location = try managedLocation(for: id)
        return ExportPlan(
            id: id,
            outputDirectory: location.cacheDirectory,
            outputURL: location.fileURL
        )
    }

    private func performExport(
        _ request: PreviewExportRequest,
        plan: ExportPlan
    ) async throws -> URL {
        let inspection = try await MediaInspector.inspect(request.sourceURL)
        guard inspection.videoTrackCount > 0,
              inspection.width > 0,
              inspection.height > 0 else {
            throw PreviewExportCoordinatorError.sourceHasNoVideo
        }

        try FileManager.default.createDirectory(
            at: plan.outputDirectory,
            withIntermediateDirectories: true
        )
        let expectedAudioTrackCount = request.audioPreference.includesAudio
            && inspection.audioTrackCount > 0 ? 1 : 0

        if FileManager.default.isReadableFile(atPath: plan.outputURL.path),
           let existing = try? await MediaInspector.inspect(plan.outputURL),
           existing.videoTrackCount > 0,
           existing.audioTrackCount == expectedAudioTrackCount,
           abs(existing.duration - request.trimRange.duration) <= (1.0 / 24.0) {
            return plan.outputURL
        }

        let mediaConfiguration = mediaConfiguration(for: request, inspection: inspection)
        let range = CMTimeRange(
            start: CMTime(seconds: request.trimRange.startTime, preferredTimescale: 600),
            duration: CMTime(seconds: request.trimRange.duration, preferredTimescale: 600)
        )

        return try await exporter.export(
            sourceURL: request.sourceURL,
            destinationURL: plan.outputURL,
            timeRange: range,
            configuration: mediaConfiguration
        )
    }

    /// Durably publishes a Copy/drag result and consumes its lease even when
    /// marker I/O fails. Save As never obtains a publication lease and remains
    /// an external, untracked operation.
    @discardableResult
    func markPublished(
        _ request: PreviewExportRequest,
        lease: ManagedExportPublicationLease
    ) async throws -> ManagedExportRecord {
        releaseExpiredPublicationLeases(at: now())
        guard let state = publicationLeases[lease.token],
              state.exportID == lease.exportID,
              sameResolvedPath(state.outputURL, lease.outputURL) else {
            throw PreviewExportCoordinatorError.managedExportNotFound(lease.exportID)
        }
        defer { releasePublicationLease(token: lease.token) }
        let expectedID = makeExportID(
            recordingID: request.recordingID,
            cacheKey: cacheKey(for: request),
            filename: request.filename
        )
        guard expectedID == state.exportID else {
            throw PreviewExportCoordinatorError.invalidManagedExport(lease.outputURL)
        }
        return try publish(request, outputURL: state.outputURL, expectedID: expectedID)
    }

    /// Cancels a lease after pasteboard/drag preparation fails. It is
    /// intentionally idempotent so error paths can call it defensively.
    func cancelPublication(_ lease: ManagedExportPublicationLease) {
        guard let state = publicationLeases[lease.token],
              state.exportID == lease.exportID,
              sameResolvedPath(state.outputURL, lease.outputURL) else {
            return
        }
        releasePublicationLease(token: lease.token)
    }

    private func publish(
        _ request: PreviewExportRequest,
        outputURL: URL,
        expectedID: ManagedExportID
    ) throws -> ManagedExportRecord {
        guard ExportQualitySettings.validRange.contains(request.videoQualityPercent) else {
            throw PreviewExportCoordinatorError.invalidManagedExport(outputURL)
        }
        let location = try managedLocation(for: expectedID)
        guard sameResolvedPath(location.fileURL, outputURL),
              let values = regularFileValues(at: location.fileURL) else {
            throw PreviewExportCoordinatorError.invalidManagedExport(outputURL)
        }

        var manifest = try loadManifestStrictly(from: location.cacheDirectory)
        let existing = manifest.records.first { $0.id == expectedID }
        let marker = ManagedExportPublicationMarker(
            id: expectedID,
            recordingID: request.recordingID,
            filename: request.filename,
            createdAt: existing?.createdAt ?? now(),
            preset: request.configuration.preset,
            qualityPercent: request.videoQualityPercent
        )
        manifest.records.removeAll { $0.id == expectedID }
        manifest.records.append(marker)
        manifest.records.sort { $0.id.rawValue < $1.id.rawValue }
        try writeManifest(manifest, to: location.cacheDirectory)

        return makeRecord(marker: marker, location: location, fileSize: values.fileSize)
    }

    /// Lists complete Copy/drag publications that still exist on disk. Raw
    /// encoder cache files without Clip's durable manifest entry are private
    /// staging files (including Save As intermediates) and stay invisible.
    func inventory() throws -> ManagedExportInventory {
        releaseExpiredPublicationLeases(at: now())
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: exportsDirectory.path) else {
            return .empty
        }

        let recordingDirectories = try fileManager.contentsOfDirectory(
            at: exportsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var recordsByID: [ManagedExportID: ManagedExportRecord] = [:]

        for recordingDirectory in recordingDirectories {
            guard let directoryValues = try? recordingDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ),
                  directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true,
                  UUID(uuidString: recordingDirectory.lastPathComponent) != nil else {
                continue
            }

            let cacheDirectories = (try? fileManager.contentsOfDirectory(
                at: recordingDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for cacheDirectory in cacheDirectories {
                guard let cacheValues = try? cacheDirectory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                ),
                      cacheValues.isDirectory == true,
                      cacheValues.isSymbolicLink != true,
                      let manifest = try? loadManifestIfPresent(from: cacheDirectory) else {
                    continue
                }

                for marker in manifest.records {
                    guard marker.schemaVersion == ManagedExportPublicationMarker.currentSchemaVersion,
                          ExportQualitySettings.validRange.contains(marker.qualityPercent),
                          let location = try? managedLocation(for: marker.id),
                          sameResolvedPath(location.cacheDirectory, cacheDirectory),
                          marker.recordingID == location.recordingID,
                          marker.filename == location.filename,
                          let values = regularFileValues(at: location.fileURL) else {
                        continue
                    }
                    guard recordsByID[marker.id] == nil else { continue }
                    recordsByID[marker.id] = makeRecord(
                        marker: marker,
                        location: location,
                        fileSize: values.fileSize
                    )
                }
            }
        }

        var records = Array(recordsByID.values)
        records.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.rawValue < $1.id.rawValue
        }
        return ManagedExportInventory(
            items: records,
            totalByteCount: saturatingByteCount(records.map(\.byteCount))
        )
    }

    /// Deletes one published cache file without touching unlisted staging
    /// files or sibling exports in the same encoding cache directory.
    @discardableResult
    func deleteExport(id: ManagedExportID) throws -> ManagedExportInventory {
        releaseExpiredPublicationLeases(at: now())
        guard activeExportCounts[id, default: 0] == 0 else {
            throw PreviewExportCoordinatorError.managedExportInUse(id)
        }
        try deletePublishedExport(id: id)
        return try inventory()
    }

    /// Purges only user-visible Copy/drag publications. Save As staging files,
    /// foreign files, and malformed manifests remain untouched for conservative
    /// stale-cache maintenance rather than being claimed as owned data.
    @discardableResult
    func deleteAllPublishedExports() throws -> ManagedExportInventory {
        releaseExpiredPublicationLeases(at: now())
        let current = try inventory()
        if let active = current.items.first(where: {
            activeExportCounts[$0.id, default: 0] > 0
        }) {
            throw PreviewExportCoordinatorError.managedExportInUse(active.id)
        }
        for record in current.items {
            try deletePublishedExport(id: record.id)
        }
        return try inventory()
    }

    /// Removes only Clip's UUID/cache-key export directories after their files
    /// have been untouched for the configured grace period. The actor boundary
    /// serializes cleanup with export publication, and the seven-day default
    /// keeps promised drag and pasteboard file URLs alive for receiving apps.
    @discardableResult
    func removeStaleExports(olderThan cutoff: Date) throws -> Int {
        releaseExpiredPublicationLeases(at: now())
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: exportsDirectory.path) else { return 0 }

        let recordingDirectories = try fileManager.contentsOfDirectory(
            at: exportsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var removedCount = 0

        for recordingDirectory in recordingDirectories {
            let recordingValues = try recordingDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard UUID(uuidString: recordingDirectory.lastPathComponent) != nil,
                  recordingValues.isDirectory == true,
                  recordingValues.isSymbolicLink != true else {
                continue
            }

            let cacheDirectories = try fileManager.contentsOfDirectory(
                at: recordingDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for cacheDirectory in cacheDirectories {
                let cacheValues = try cacheDirectory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard cacheValues.isDirectory == true,
                      cacheValues.isSymbolicLink != true,
                      !isCacheDirectoryActive(cacheDirectory),
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
        return MediaExportConfigurationFactory.make(
            preset: mediaPreset(for: request.configuration.preset),
            sourceWidth: inspection.width,
            sourceHeight: inspection.height,
            sourceFramesPerSecond: request.captureFrameRate.framesPerSecond,
            videoQualityPercent: request.videoQualityPercent,
            sourceVideoQualityPercent: request.sourceVideoQualityPercent,
            includesAudio: request.audioPreference.includesAudio
        )
    }

    func cacheKey(for request: PreviewExportRequest) -> String {
        let start = Int64((request.trimRange.startTime * 1_000).rounded())
        let end = Int64((request.trimRange.endTime * 1_000).rounded())
        let audio = request.audioPreference.includesAudio ? "audio" : "silent"
        let frameRate = request.captureFrameRate.framesPerSecond
        return "v\(Self.cacheSchemaVersion)-\(start)-\(end)"
            + "-\(request.configuration.preset.rawValue)-q\(request.videoQualityPercent)"
            + "-sourceq\(request.sourceVideoQualityPercent)"
            + "-\(frameRate)fps-\(audio)"
    }

    private func makeExportID(
        recordingID: RecordingID,
        cacheKey: String,
        filename: RecordingFilename
    ) -> ManagedExportID {
        ManagedExportID(
            rawValue: "\(recordingID.description)/\(cacheKey)/\(filename.fileName)"
        )
    }

    private func managedLocation(for id: ManagedExportID) throws -> ManagedExportLocation {
        let components = id.rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              let uuid = UUID(uuidString: String(components[0])) else {
            throw PreviewExportCoordinatorError.managedExportNotFound(id)
        }
        let recordingID = RecordingID(uuid)
        let recordingComponent = String(components[0])
        let cacheKey = String(components[1])
        let filenameComponent = String(components[2])
        guard recordingComponent == recordingID.description,
              !cacheKey.isEmpty,
              cacheKey != ".",
              cacheKey != "..",
              !cacheKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let filename = try? RecordingFilename(validating: filenameComponent),
              filename.fileName == filenameComponent else {
            throw PreviewExportCoordinatorError.managedExportNotFound(id)
        }

        let recordingDirectory = exportsDirectory.appendingPathComponent(
            recordingID.description,
            isDirectory: true
        )
        let cacheDirectory = recordingDirectory.appendingPathComponent(
            cacheKey,
            isDirectory: true
        )
        let fileURL = cacheDirectory.appendingPathComponent(filename.fileName)
        let resolvedRoot = exportsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        guard resolvedFile.path.hasPrefix(rootPrefix) else {
            throw PreviewExportCoordinatorError.invalidManagedExport(fileURL)
        }
        return ManagedExportLocation(
            id: id,
            recordingID: recordingID,
            cacheKey: cacheKey,
            filename: filename,
            recordingDirectory: recordingDirectory,
            cacheDirectory: cacheDirectory,
            fileURL: fileURL
        )
    }

    private func regularFileValues(at url: URL) -> RegularFileValues? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0 else {
            return nil
        }
        return RegularFileValues(fileSize: Int64(size))
    }

    private func sameResolvedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath()
            == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func manifestURL(in cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent(Self.publicationManifestFilename)
    }

    private func loadManifestIfPresent(
        from cacheDirectory: URL
    ) throws -> ManagedExportPublicationManifest? {
        let url = manifestURL(in: cacheDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PreviewExportCoordinatorError.invalidManagedExport(url)
        }
        let manifest = try JSONDecoder().decode(
            ManagedExportPublicationManifest.self,
            from: Data(contentsOf: url)
        )
        guard manifest.schemaVersion == ManagedExportPublicationManifest.currentSchemaVersion else {
            throw PreviewExportCoordinatorError.invalidManagedExport(url)
        }
        return manifest
    }

    private func loadManifestStrictly(
        from cacheDirectory: URL
    ) throws -> ManagedExportPublicationManifest {
        try loadManifestIfPresent(from: cacheDirectory) ?? ManagedExportPublicationManifest()
    }

    private func writeManifest(
        _ manifest: ManagedExportPublicationManifest,
        to cacheDirectory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: manifestURL(in: cacheDirectory),
            options: [.atomic]
        )
    }

    private func makeRecord(
        marker: ManagedExportPublicationMarker,
        location: ManagedExportLocation,
        fileSize: Int64
    ) -> ManagedExportRecord {
        ManagedExportRecord(
            id: marker.id,
            recordingID: marker.recordingID,
            url: location.fileURL.standardizedFileURL,
            filename: marker.filename,
            byteCount: fileSize,
            createdAt: marker.createdAt,
            preset: marker.preset,
            qualityPercent: marker.qualityPercent
        )
    }

    private func deletePublishedExport(id: ManagedExportID) throws {
        let location = try managedLocation(for: id)
        var manifest = try loadManifestStrictly(from: location.cacheDirectory)
        guard let marker = manifest.records.first(where: { $0.id == id }),
              marker.schemaVersion == ManagedExportPublicationMarker.currentSchemaVersion,
              marker.recordingID == location.recordingID,
              marker.filename == location.filename else {
            throw PreviewExportCoordinatorError.managedExportNotFound(id)
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: location.fileURL.path) {
            guard regularFileValues(at: location.fileURL) != nil else {
                throw PreviewExportCoordinatorError.invalidManagedExport(location.fileURL)
            }
            try fileManager.removeItem(at: location.fileURL)
        }

        manifest.records.removeAll { $0.id == id }
        let manifestURL = manifestURL(in: location.cacheDirectory)
        if manifest.records.isEmpty {
            if fileManager.fileExists(atPath: manifestURL.path) {
                try fileManager.removeItem(at: manifestURL)
            }
        } else {
            try writeManifest(manifest, to: location.cacheDirectory)
        }
        try pruneEmptyDirectory(location.cacheDirectory)
        try pruneEmptyDirectory(location.recordingDirectory)
    }

    private func pruneEmptyDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path),
              try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty else {
            return
        }
        try fileManager.removeItem(at: directory)
    }

    private func finishActiveExport(_ id: ManagedExportID) {
        guard let count = activeExportCounts[id] else { return }
        if count <= 1 {
            activeExportCounts[id] = nil
        } else {
            activeExportCounts[id] = count - 1
        }
    }

    private func retainActiveExport(_ id: ManagedExportID) {
        activeExportCounts[id, default: 0] += 1
    }

    private func releasePublicationLease(token: UUID) {
        guard let state = publicationLeases.removeValue(forKey: token) else { return }
        finishActiveExport(state.exportID)
    }

    private func releaseExpiredPublicationLeases(at date: Date) {
        let expiredTokens = publicationLeases.compactMap { token, state in
            state.expiresAt <= date ? token : nil
        }
        for token in expiredTokens {
            releasePublicationLease(token: token)
        }
    }

    private func isCacheDirectoryActive(_ cacheDirectory: URL) -> Bool {
        activeExportCounts.contains { id, count in
            guard count > 0, let location = try? managedLocation(for: id) else { return false }
            return sameResolvedPath(location.cacheDirectory, cacheDirectory)
        }
    }

    private func saturatingByteCount(_ values: [Int64]) -> Int64 {
        values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
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
            // Publication manifests are hidden implementation files, but their
            // timestamp intentionally refreshes the seven-day grace period when
            // an existing cached MP4 is copied or dragged again.
            options: []
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
        let publication = try await exports.exportForPublication(request)
        do {
            try pasteboard.placeFile(at: publication.outputURL)
        } catch {
            await exports.cancelPublication(publication)
            throw error
        }
        do {
            _ = try await exports.markPublished(request, lease: publication)
        } catch {
            // Pasteboard publication already succeeded. Preserve that external
            // success even if the optional History inventory marker fails.
            ClipLog.storage.error(
                "Post-copy Exports registration failed; the pasted MP4 remains usable"
            )
        }
        return publication.outputURL
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
