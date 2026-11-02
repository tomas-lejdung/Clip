import ClipCore
import ClipMedia
import Foundation

enum ManagedHistoryRepositoryError: Error, Equatable, Sendable {
    case invalidRecoveredMedia(URL)
    case sourceIsNotARegularMP4(URL)
    case recordingAlreadyExists(RecordingID)
    case recordingNotFound(RecordingID)
    case managedDestinationAlreadyExists(URL)
    case unsupportedHistorySchema(found: Int, expected: Int)
    case managedPathEscapedRecordingsDirectory(String)
}

struct FinalizedRecordingImport: Sendable {
    let id: RecordingID
    let sourceURL: URL
    let createdAt: Date?
    let filename: RecordingFilename?
    let filenameTemplate: RecordingFilenameTemplate
    let duration: TimeInterval
    let pixelSize: PixelSize
    let frameRate: CaptureFrameRate
    let audioConfiguration: AudioConfiguration
    let captureTarget: ClipCore.CaptureTarget
    let captureSessionSnapshot: CaptureSessionSnapshot?
    let processing: RecordingProcessingMetadata?
    let trimRange: TrimRange?
    let exportAudioPreference: ExportAudioPreference

    init(
        id: RecordingID = RecordingID(),
        sourceURL: URL,
        createdAt: Date? = nil,
        filename: RecordingFilename? = nil,
        filenameTemplate: RecordingFilenameTemplate = .default,
        duration: TimeInterval,
        pixelSize: PixelSize,
        frameRate: CaptureFrameRate,
        audioConfiguration: AudioConfiguration,
        captureTarget: ClipCore.CaptureTarget,
        captureSessionSnapshot: CaptureSessionSnapshot? = nil,
        processing: RecordingProcessingMetadata? = nil,
        trimRange: TrimRange? = nil,
        exportAudioPreference: ExportAudioPreference = .keepAudio
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.createdAt = createdAt
        self.filename = filename
        self.filenameTemplate = filenameTemplate
        self.duration = duration
        self.pixelSize = pixelSize
        self.frameRate = frameRate
        self.audioConfiguration = audioConfiguration
        self.captureTarget = captureTarget
        self.captureSessionSnapshot = captureSessionSnapshot
        self.processing = processing
        self.trimRange = trimRange
        self.exportAudioPreference = exportAudioPreference
    }
}

struct ManagedFileCleanupFailure: Equatable, Sendable {
    let url: URL
    let reason: String
}

struct ManagedHistoryDeletionResult: Sendable {
    let removedItem: RecordingHistoryItem
    let cleanupFailure: ManagedFileCleanupFailure?
}

struct ManagedHistoryCleanupResult: Sendable {
    let plan: HistoryCleanupPlan
    let cleanupFailures: [ManagedFileCleanupFailure]
}

struct ManagedHistoryPreviewSession: Hashable, Sendable {
    let id: UUID
    let recordingID: RecordingID
}

struct ManagedHistoryPreviewCloseResult: Sendable {
    let didFinalizeDeletion: Bool
    let retainedItem: RecordingHistoryItem?
    let cleanupFailure: ManagedFileCleanupFailure?
}

struct ManagedHistoryStorageUsage: Equatable, Sendable {
    let itemCount: Int
    let indexedMasterByteCount: Int64
    let actualManagedMP4ByteCount: Int64
    let recognizedOrphanByteCount: Int64
    let untrackedMP4ByteCount: Int64
}

struct ManagedHistoryReconciliationReport: Sendable {
    let removedMissingItems: [RecordingID]
    let deletedOrphanFiles: [URL]
    let retainedUnknownFiles: [URL]
    let cleanupFailures: [ManagedFileCleanupFailure]
}

struct ManagedHistoryTransactionCleanupReport: Sendable {
    let deletedArtifacts: [URL]
    /// A rollback may be the only remaining playable copy after a hard crash.
    /// It is retained unless its destination is both indexed and present.
    let retainedRollbackArtifacts: [URL]
    let cleanupFailures: [ManagedFileCleanupFailure]
}

struct RecoveredInterruptedRecording: Sendable {
    let item: RecordingHistoryItem
    let settings: ClipSettings
}

struct InterruptedRecordingRecoveryFailure: Sendable {
    let fileURL: URL
    let reason: String
}

struct InterruptedRecordingRecoveryReport: Sendable {
    let recovered: [RecoveredInterruptedRecording]
    let retainedFailures: [InterruptedRecordingRecoveryFailure]
}

/// Owns only files beneath `recordingsDirectory`. External Save As and export URLs are read-only.
actor ManagedHistoryRepository {
    static let indexFilename = "recording-history-v1.json"
    static let ownershipMarkerContents = Data("clip-managed-history-v1\n".utf8)
    static let staleTransactionArtifactLifetime: TimeInterval = 7 * 24 * 60 * 60

    nonisolated let indexURL: URL
    nonisolated let recordingsDirectory: URL

    private let fileSystem: any ManagedHistoryFileSystem
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let tokenGenerator: @Sendable () -> UUID
    private let mediaInspector: @Sendable (URL) async throws -> MediaInspection
    private var cachedIndex: RecordingHistoryIndex?
    private var previewSessionIDsByRecording: [RecordingID: Set<UUID>] = [:]
    private var deferredFinalizations: [RecordingID: DeferredFinalization] = [:]

    private enum DeferredFinalization: Sendable {
        case remove(item: RecordingHistoryItem, masterURL: URL)

    }

    init(
        applicationSupportDirectory: URL,
        recordingsDirectory: URL,
        fileSystem: any ManagedHistoryFileSystem = LiveManagedHistoryFileSystem(),
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        tokenGenerator: @escaping @Sendable () -> UUID = { UUID() },
        mediaInspector: @escaping @Sendable (URL) async throws -> MediaInspection = {
            try await MediaInspector.inspect($0)
        }
    ) throws {
        self.recordingsDirectory = recordingsDirectory.standardizedFileURL
        indexURL = applicationSupportDirectory
            .standardizedFileURL
            .appendingPathComponent(Self.indexFilename)
        self.fileSystem = fileSystem
        self.timeZone = timeZone
        self.now = now
        self.tokenGenerator = tokenGenerator
        self.mediaInspector = mediaInspector

        try fileSystem.createDirectory(at: applicationSupportDirectory)
        try fileSystem.createDirectory(at: recordingsDirectory)
    }

    func load() throws -> RecordingHistoryIndex {
        try loadedIndex()
    }

    func reloadFromDisk() throws -> RecordingHistoryIndex {
        cachedIndex = nil
        return try loadedIndex()
    }

    func item(id: RecordingID) throws -> RecordingHistoryItem? {
        try loadedIndex().item(id: id)
    }

    func masterURL(for id: RecordingID) throws -> URL {
        guard let item = try loadedIndex().item(id: id) else {
            throw ManagedHistoryRepositoryError.recordingNotFound(id)
        }
        return try managedURL(for: item.managedMaster)
    }

    /// Pins a managed Source while Preview uses it. Explicit deletion and
    /// retention cleanup wait for readers; sharing never replaces the Source.
    func beginPreviewSession(id: RecordingID) throws -> ManagedHistoryPreviewSession {
        guard try loadedIndex().item(id: id) != nil else {
            throw ManagedHistoryRepositoryError.recordingNotFound(id)
        }
        let session = ManagedHistoryPreviewSession(id: tokenGenerator(), recordingID: id)
        previewSessionIDsByRecording[id, default: []].insert(session.id)
        return session
    }

    /// Atomically persists every editable Preview field. Explicitly deleted
    /// items are never reinserted by a late callback from their pinned session.
    @discardableResult
    func updatePreviewMetadata(
        session: ManagedHistoryPreviewSession,
        filename: RecordingFilename,
        trimRange: TrimRange,
        audioPreference: ExportAudioPreference
    ) throws -> RecordingHistoryItem {
        try validateActivePreviewSession(session)
        let updateDate = now()
        var candidate = try loadedIndex()
        if var item = candidate.item(id: session.recordingID) {
            try item.rename(to: filename.fileName, at: updateDate)
            try item.setTrimRange(trimRange, at: updateDate)
            try item.setExportAudioPreference(audioPreference, at: updateDate)
            candidate.upsert(item)
            try persist(candidate)
            cachedIndex = candidate
            return item
        }

        guard case let .remove(item: removedItem, masterURL) = deferredFinalizations[
            session.recordingID
        ] else {
            throw ManagedHistoryRepositoryError.recordingNotFound(session.recordingID)
        }
        var updatedItem = removedItem
        try updatedItem.rename(to: filename.fileName, at: updateDate)
        try updatedItem.setTrimRange(trimRange, at: updateDate)
        try updatedItem.setExportAudioPreference(audioPreference, at: updateDate)
        deferredFinalizations[session.recordingID] = .remove(
            item: updatedItem,
            masterURL: masterURL
        )
        return updatedItem
    }

    /// Releases a Preview pin. A failed physical deletion is reported and
    /// recoverable by the next
    /// startup reconciliation because its index row was durably removed first.
    @discardableResult
    func endPreviewSession(
        _ session: ManagedHistoryPreviewSession
    ) throws -> ManagedHistoryPreviewCloseResult {
        try validateActivePreviewSession(session)
        let isLastReader = previewSessionIDsByRecording[session.recordingID]?.count == 1
        // Closing ends this reader even if the index has become unreadable.
        // Keeping a failed metadata write pinned would block later cleanup.
        defer {
            if isLastReader {
                deferredFinalizations[session.recordingID] = nil
                previewSessionIDsByRecording[session.recordingID] = nil
            } else {
                previewSessionIDsByRecording[session.recordingID]?.remove(session.id)
            }
        }
        guard isLastReader else {
            return ManagedHistoryPreviewCloseResult(
                didFinalizeDeletion: false,
                retainedItem: try loadedIndex().item(id: session.recordingID),
                cleanupFailure: nil
            )
        }

        let result: ManagedHistoryPreviewCloseResult
        switch deferredFinalizations[session.recordingID] {
        case nil:
            result = ManagedHistoryPreviewCloseResult(
                didFinalizeDeletion: false,
                retainedItem: try loadedIndex().item(id: session.recordingID),
                cleanupFailure: nil
            )

        case let .remove(_, masterURL):
            result = ManagedHistoryPreviewCloseResult(
                didFinalizeDeletion: true,
                retainedItem: nil,
                cleanupFailure: removeManagedFileIfPresent(at: masterURL)
            )
        }
        return result
    }

    /// Copies a finalized MP4 into managed storage. The source is never removed.
    @discardableResult
    func importFinalizedRecording(
        _ request: FinalizedRecordingImport
    ) throws -> RecordingHistoryItem {
        guard request.sourceURL.pathExtension.lowercased() == "mp4",
              fileSystem.isRegularFile(at: request.sourceURL) else {
            throw ManagedHistoryRepositoryError.sourceIsNotARegularMP4(request.sourceURL)
        }

        var candidate = try loadedIndex()
        guard candidate.item(id: request.id) == nil else {
            throw ManagedHistoryRepositoryError.recordingAlreadyExists(request.id)
        }

        let managedFile = try ManagedRecordingFile(
            relativePath: "\(request.id.description).mp4"
        )
        let destinationURL = try managedURL(for: managedFile)
        let markerURL = ownershipMarkerURL(for: destinationURL)
        let sourceIsDestination = request.sourceURL.standardizedFileURL == destinationURL
        guard sourceIsDestination || !fileSystem.itemExists(at: destinationURL) else {
            throw ManagedHistoryRepositoryError.managedDestinationAlreadyExists(destinationURL)
        }

        var copiedDestination = false
        let previousMarkerData = try fileSystem.dataIfPresent(at: markerURL)
        do {
            if !sourceIsDestination {
                try fileSystem.copyItemAtomically(
                    from: request.sourceURL,
                    to: destinationURL
                )
                copiedDestination = true
            }
            try markAsManaged(destinationURL)

            let createdAt = request.createdAt ?? now()
            let filename = request.filename ?? request.filenameTemplate.filename(
                at: createdAt,
                timeZone: timeZone
            )
            let item = try RecordingHistoryItem(
                id: request.id,
                createdAt: createdAt,
                filename: filename,
                managedMaster: managedFile,
                managedByteCount: fileSystem.byteCount(of: destinationURL),
                recordingDuration: request.duration,
                pixelSize: request.pixelSize,
                frameRate: request.frameRate,
                processing: request.processing,
                audioConfiguration: request.audioConfiguration,
                captureTarget: request.captureTarget,
                captureSessionSnapshot: request.captureSessionSnapshot,
                trimRange: request.trimRange ?? TrimRange.full(recordingDuration: request.duration),
                exportAudioPreference: request.exportAudioPreference
            )
            candidate.upsert(item)
            try persist(candidate)
            cachedIndex = candidate
            let recoveryURL = CaptureRecoveryRecord.url(
                for: request.id,
                in: recordingsDirectory
            )
            if fileSystem.itemExists(at: recoveryURL) {
                try? fileSystem.removeItem(at: recoveryURL)
            }
            return item
        } catch {
            if copiedDestination {
                try? fileSystem.removeItem(at: destinationURL)
            }
            restoreMarker(at: markerURL, previousData: previousMarkerData)
            throw error
        }
    }

    @discardableResult
    func rename(
        id: RecordingID,
        to userInput: String
    ) throws -> RecordingHistoryItem {
        try mutateItem(id: id) { item in
            try item.rename(to: userInput, at: now())
        }
    }

    @discardableResult
    func updateTrim(
        id: RecordingID,
        trimRange: TrimRange
    ) throws -> RecordingHistoryItem {
        try mutateItem(id: id) { item in
            try item.setTrimRange(trimRange, at: now())
        }
    }

    @discardableResult
    func updateExportAudioPreference(
        id: RecordingID,
        preference: ExportAudioPreference
    ) throws -> RecordingHistoryItem {
        try mutateItem(id: id) { item in
            try item.setExportAudioPreference(preference, at: now())
        }
    }

    @discardableResult
    func delete(
        id: RecordingID,
        previewSession: ManagedHistoryPreviewSession? = nil
    ) throws -> ManagedHistoryDeletionResult {
        if let previewSession {
            guard previewSession.recordingID == id else {
                throw ManagedHistoryRepositoryError.recordingNotFound(id)
            }
            try validateActivePreviewSession(previewSession)
        }
        let hasActivePreview = previewSessionIDsByRecording[id]?.isEmpty == false
        var candidate = try loadedIndex()
        let removedItem: RecordingHistoryItem
        if let indexedItem = candidate.remove(id: id) {
            removedItem = indexedItem
        } else if previewSession != nil,
                  case let .remove(item: deferredItem, _) = deferredFinalizations[id] {
            removedItem = deferredItem
        } else {
            throw ManagedHistoryRepositoryError.recordingNotFound(id)
        }
        let masterURL = try managedURL(for: removedItem.managedMaster)

        if try loadedIndex().item(id: id) != nil {
            try persist(candidate)
            cachedIndex = candidate
        }
        if hasActivePreview {
            deferredFinalizations[id] = .remove(item: removedItem, masterURL: masterURL)
        }
        return ManagedHistoryDeletionResult(
            removedItem: removedItem,
            cleanupFailure: hasActivePreview ? nil : removeManagedFileIfPresent(at: masterURL)
        )
    }

    @discardableResult
    func applyRetentionCleanup(
        policy: HistoryRetentionPolicy
    ) throws -> ManagedHistoryCleanupResult {
        var candidate = try loadedIndex()
        let plan = HistoryCleanupPlanner.plan(
            items: candidate.items.filter {
                previewSessionIDsByRecording[$0.id]?.isEmpty != false
            },
            policy: policy,
            now: now()
        )
        guard !plan.recordingIDs.isEmpty else {
            return ManagedHistoryCleanupResult(plan: plan, cleanupFailures: [])
        }

        let urls = try plan.recordingIDs.compactMap { id -> URL? in
            guard let item = candidate.item(id: id) else { return nil }
            return try managedURL(for: item.managedMaster)
        }
        candidate.applyCleanupPlan(plan)
        try persist(candidate)
        cachedIndex = candidate

        return ManagedHistoryCleanupResult(
            plan: plan,
            cleanupFailures: urls.compactMap(removeManagedFileIfPresent)
        )
    }

    /// Registers Copy, drag, or Save As without ever deleting the supplied exported URL.
    @discardableResult
    func registerSuccessfulExport(
        id: RecordingID,
        previewSession: ManagedHistoryPreviewSession? = nil
    ) throws -> RecordingHistoryItem {
        if let previewSession {
            guard previewSession.recordingID == id else {
                throw ManagedHistoryRepositoryError.recordingNotFound(id)
            }
            try validateActivePreviewSession(previewSession)
        }
        let item = try mutateItem(id: id) { item in
            try item.registerSuccessfulExport(at: now())
        }
        return item
    }

    private func validateActivePreviewSession(
        _ session: ManagedHistoryPreviewSession
    ) throws {
        guard previewSessionIDsByRecording[session.recordingID]?.contains(session.id) == true else {
            throw ManagedHistoryRepositoryError.recordingNotFound(session.recordingID)
        }
    }

    func storageUsage() throws -> ManagedHistoryStorageUsage {
        let index = try loadedIndex()
        let diskFiles = try fileSystem.managedMP4Files(in: recordingsDirectory)
        let referencedPaths = try Set(index.items.map {
            try managedURL(for: $0.managedMaster).path
        })
        let orphans = diskFiles.filter {
            !referencedPaths.contains($0.url.path) && isOwnedManagedFile($0.url)
        }
        let untracked = diskFiles.filter {
            !referencedPaths.contains($0.url.path) && !isOwnedManagedFile($0.url)
        }

        return ManagedHistoryStorageUsage(
            itemCount: index.items.count,
            indexedMasterByteCount: index.totalManagedByteCount,
            actualManagedMP4ByteCount: saturatingSum(diskFiles.map(\.byteCount)),
            recognizedOrphanByteCount: saturatingSum(orphans.map(\.byteCount)),
            untrackedMP4ByteCount: saturatingSum(untracked.map(\.byteCount))
        )
    }

    /// Removes only old, strictly named transaction files created by this
    /// repository. These files are normally deleted by `defer`, but a hard
    /// process termination can bypass that cleanup. Unknown hidden files are
    /// ignored, and a rollback is preserved whenever its indexed destination
    /// cannot be proven to exist.
    @discardableResult
    func removeStaleTransactionArtifacts(
        olderThan cutoff: Date
    ) throws -> ManagedHistoryTransactionCleanupReport {
        let index = try loadedIndex()
        let indexedRelativePaths = Set(index.items.map(\.managedMaster.relativePath))
        let artifacts = try fileSystem.directRegularFiles(in: recordingsDirectory)
        var deleted: [URL] = []
        var retainedRollbacks: [URL] = []
        var failures: [ManagedFileCleanupFailure] = []

        for artifact in artifacts where artifact.modificationDate < cutoff {
            guard let transaction = transactionArtifact(at: artifact.url) else {
                continue
            }
            if transaction.kind == .rollback {
                let destinationIsRecoverablyPresent = indexedRelativePaths.contains(
                    transaction.destinationURL.lastPathComponent
                ) && fileSystem.isRegularFile(at: transaction.destinationURL)
                guard destinationIsRecoverablyPresent else {
                    retainedRollbacks.append(artifact.url)
                    continue
                }
            }

            do {
                try fileSystem.removeItem(at: artifact.url)
                deleted.append(artifact.url)
            } catch {
                failures.append(
                    ManagedFileCleanupFailure(
                        url: artifact.url,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        return ManagedHistoryTransactionCleanupReport(
            deletedArtifacts: deleted,
            retainedRollbackArtifacts: retainedRollbacks,
            cleanupFailures: failures
        )
    }

    /// Adopts only UUID-named MP4s that have Clip's durable capture sidecar.
    /// Invalid or incomplete media is retained untouched so startup recovery
    /// can never destroy the last potentially useful copy.
    func recoverInterruptedRecordings() async throws -> InterruptedRecordingRecoveryReport {
        let index = try loadedIndex()
        let referencedPaths = try Set(index.items.map {
            try managedURL(for: $0.managedMaster).path
        })
        // A hard termination can occur after import writes the ownership marker
        // but before the History index is persisted. The durable capture sidecar
        // remains the authority for recovery, so an otherwise valid owned file
        // must not be excluded merely because that earlier transaction step won.
        let candidates = try fileSystem.managedMP4Files(in: recordingsDirectory).filter {
            !referencedPaths.contains($0.url.path)
        }

        var recovered: [RecoveredInterruptedRecording] = []
        var failures: [InterruptedRecordingRecoveryFailure] = []
        for candidate in candidates {
            let stem = candidate.url.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: stem) else { continue }
            let recordingID = RecordingID(uuid)
            let recoveryURL = CaptureRecoveryRecord.url(
                for: recordingID,
                in: recordingsDirectory
            )
            guard let recoveryData = try fileSystem.dataIfPresent(at: recoveryURL) else {
                continue
            }

            do {
                let recoveryRecord = try CaptureRecoveryRecord.decode(recoveryData)
                guard recoveryRecord.schemaVersion == CaptureRecoveryRecord.currentSchemaVersion,
                      recoveryRecord.recordingID == recordingID else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let inspection = try await mediaInspector(candidate.url)
                guard inspection.videoTrackCount > 0,
                      inspection.duration.isFinite,
                      inspection.duration > 0,
                      inspection.width > 0,
                      inspection.height > 0 else {
                    throw ManagedHistoryRepositoryError.invalidRecoveredMedia(candidate.url)
                }
                let item = try importFinalizedRecording(
                    FinalizedRecordingImport(
                        id: recordingID,
                        sourceURL: candidate.url,
                        createdAt: recoveryRecord.createdAt,
                        filenameTemplate: recoveryRecord.settings.defaultFilenameTemplate,
                        duration: inspection.duration,
                        pixelSize: try PixelSize(
                            width: inspection.width,
                            height: inspection.height
                        ),
                        frameRate: representedFrameRate(
                            inspection.nominalFramesPerSecond,
                            fallback: recoveryRecord.settings.frameRate
                        ),
                        audioConfiguration: recoveryRecord.settings.audio,
                        captureTarget: recoveryRecord.captureTarget,
                        captureSessionSnapshot: CaptureSessionSnapshot(
                            settings: recoveryRecord.settings
                        ),
                    )
                )
                recovered.append(
                    RecoveredInterruptedRecording(
                        item: item,
                        settings: recoveryRecord.settings
                    )
                )
            } catch {
                failures.append(
                    InterruptedRecordingRecoveryFailure(
                        fileURL: candidate.url,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        return InterruptedRecordingRecoveryReport(
            recovered: recovered,
            retainedFailures: failures
        )
    }

    /// Drops missing metadata, deletes only Clip-pattern orphan names, and retains unknown MP4s.
    @discardableResult
    func reconcile() throws -> ManagedHistoryReconciliationReport {
        var candidate = try loadedIndex()
        var missingIDs: [RecordingID] = []
        var missingURLs: [URL] = []
        for item in candidate.items {
            let url = try managedURL(for: item.managedMaster)
            if !fileSystem.isRegularFile(at: url) {
                missingIDs.append(item.id)
                missingURLs.append(url)
                _ = candidate.remove(id: item.id)
            }
        }

        let referencedPaths = try Set(candidate.items.map {
            try managedURL(for: $0.managedMaster).path
        })
        let diskFiles = try fileSystem.managedMP4Files(in: recordingsDirectory)
        let orphanFiles = diskFiles.filter {
            !referencedPaths.contains($0.url.path) && isOwnedManagedFile($0.url)
        }
        let unknownFiles = diskFiles.filter {
            !referencedPaths.contains($0.url.path) && !isOwnedManagedFile($0.url)
        }

        if !missingIDs.isEmpty {
            try persist(candidate)
            cachedIndex = candidate
        }

        var deleted: [URL] = []
        var failures: [ManagedFileCleanupFailure] = []
        for missingURL in missingURLs {
            let markerURL = ownershipMarkerURL(for: missingURL)
            guard fileSystem.itemExists(at: markerURL) else { continue }
            do {
                try fileSystem.removeItem(at: markerURL)
            } catch {
                failures.append(
                    ManagedFileCleanupFailure(
                        url: markerURL,
                        reason: error.localizedDescription
                    )
                )
            }
        }
        for orphan in orphanFiles {
            if let failure = removeManagedFileIfPresent(at: orphan.url) {
                failures.append(failure)
            } else {
                deleted.append(orphan.url)
            }
        }

        return ManagedHistoryReconciliationReport(
            removedMissingItems: missingIDs,
            deletedOrphanFiles: deleted,
            retainedUnknownFiles: unknownFiles.map(\.url),
            cleanupFailures: failures
        )
    }

    private func loadedIndex() throws -> RecordingHistoryIndex {
        if let cachedIndex { return cachedIndex }
        let index: RecordingHistoryIndex
        if let data = try fileSystem.dataIfPresent(at: indexURL) {
            index = try Self.makeDecoder().decode(RecordingHistoryIndex.self, from: data)
        } else {
            index = try RecordingHistoryIndex()
        }
        guard index.schemaVersion == RecordingHistoryIndex.currentSchemaVersion else {
            throw ManagedHistoryRepositoryError.unsupportedHistorySchema(
                found: index.schemaVersion,
                expected: RecordingHistoryIndex.currentSchemaVersion
            )
        }
        cachedIndex = index
        return index
    }

    private func persist(_ index: RecordingHistoryIndex) throws {
        let data = try Self.makeEncoder().encode(index)
        try fileSystem.writeAtomically(data, to: indexURL)
    }

    private func mutateItem(
        id: RecordingID,
        mutation: (inout RecordingHistoryItem) throws -> Void
    ) throws -> RecordingHistoryItem {
        var candidate = try loadedIndex()
        guard var item = candidate.item(id: id) else {
            throw ManagedHistoryRepositoryError.recordingNotFound(id)
        }
        try mutation(&item)
        candidate.upsert(item)
        try persist(candidate)
        cachedIndex = candidate
        return item
    }

    private func managedURL(for file: ManagedRecordingFile) throws -> URL {
        let root = recordingsDirectory.standardizedFileURL
        let url = file.resolved(inside: root).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPrefix) else {
            throw ManagedHistoryRepositoryError.managedPathEscapedRecordingsDirectory(
                file.relativePath
            )
        }
        return url
    }

    private func removeManagedFileIfPresent(at url: URL) -> ManagedFileCleanupFailure? {
        do {
            if fileSystem.itemExists(at: url) {
                try fileSystem.removeItem(at: url)
            }
            let markerURL = ownershipMarkerURL(for: url)
            if fileSystem.itemExists(at: markerURL) {
                try fileSystem.removeItem(at: markerURL)
            }
            return nil
        } catch {
            return ManagedFileCleanupFailure(url: url, reason: error.localizedDescription)
        }
    }

    private func removeFileIfPresent(at url: URL) -> ManagedFileCleanupFailure? {
        do {
            if fileSystem.itemExists(at: url) {
                try fileSystem.removeItem(at: url)
            }
            return nil
        } catch {
            return ManagedFileCleanupFailure(url: url, reason: error.localizedDescription)
        }
    }

    private func representedFrameRate(
        _ nominalFramesPerSecond: Double,
        fallback: CaptureFrameRate
    ) -> CaptureFrameRate {
        guard nominalFramesPerSecond.isFinite, nominalFramesPerSecond > 0 else {
            return fallback
        }
        let thirtyDelta = abs(nominalFramesPerSecond - Double(CaptureFrameRate.thirty.rawValue))
        let sixtyDelta = abs(nominalFramesPerSecond - Double(CaptureFrameRate.sixty.rawValue))
        return thirtyDelta <= sixtyDelta ? .thirty : .sixty
    }

    private func isRecognizedManagedFilename(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        if UUID(uuidString: stem) != nil { return true }
        let parts = stem.components(separatedBy: "-export-")
        return parts.count == 2
            && UUID(uuidString: parts[0]) != nil
            && UUID(uuidString: String(parts[1].prefix(36))) != nil
    }

    private enum TransactionArtifactKind: Equatable {
        case importing
        case temporary
        case rollback
    }

    private struct TransactionArtifact {
        let kind: TransactionArtifactKind
        let destinationURL: URL
    }

    private func transactionArtifact(at url: URL) -> TransactionArtifact? {
        let filename = url.lastPathComponent
        guard filename.hasPrefix(".") else { return nil }

        let suffixes: [(suffix: String, kind: TransactionArtifactKind)] = [
            (".importing", .importing),
            (".temporary", .temporary),
            (".rollback", .rollback),
        ]
        guard let match = suffixes.first(where: { filename.hasSuffix($0.suffix) }) else {
            return nil
        }

        let body = String(filename.dropFirst().dropLast(match.suffix.count))
        guard let tokenSeparator = body.lastIndex(of: ".") else { return nil }
        let destinationName = String(body[..<tokenSeparator])
        let token = String(body[body.index(after: tokenSeparator)...])
        guard UUID(uuidString: token) != nil, !destinationName.isEmpty else {
            return nil
        }

        let destinationURL = recordingsDirectory.appendingPathComponent(destinationName)
        guard isRecognizedManagedFilename(destinationURL) else { return nil }
        return TransactionArtifact(kind: match.kind, destinationURL: destinationURL)
    }

    private func ownershipMarkerURL(for managedURL: URL) -> URL {
        managedURL.deletingLastPathComponent().appendingPathComponent(
            ".\(managedURL.lastPathComponent).clip-managed"
        )
    }

    private func markAsManaged(_ managedURL: URL) throws {
        try fileSystem.writeAtomically(
            Self.ownershipMarkerContents,
            to: ownershipMarkerURL(for: managedURL)
        )
    }

    private func isOwnedManagedFile(_ url: URL) -> Bool {
        guard isRecognizedManagedFilename(url) else { return false }
        return (try? fileSystem.dataIfPresent(at: ownershipMarkerURL(for: url)))
            == Self.ownershipMarkerContents
    }

    private func restoreMarker(at markerURL: URL, previousData: Data?) {
        if let previousData {
            try? fileSystem.writeAtomically(previousData, to: markerURL)
        } else if fileSystem.itemExists(at: markerURL) {
            try? fileSystem.removeItem(at: markerURL)
        }
    }

    private func saturatingSum(_ values: [Int64]) -> Int64 {
        values.reduce(into: Int64.zero) { result, value in
            let (sum, overflow) = result.addingReportingOverflow(value)
            result = overflow ? .max : sum
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
