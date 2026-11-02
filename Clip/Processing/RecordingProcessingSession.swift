import ClipCore
import ClipMedia
import CryptoKit
import Darwin
import Foundation

/// Keeps the durable transaction independent of the encoder implementation.
/// The production processor validates the complete result before returning.
protocol RecordingSessionProcessing: Sendable {
    func processRecording(sourceURL: URL, destinationURL: URL,
                          configuration: RecordingProcessingConfiguration,
                          progress: @escaping @Sendable (RecordingProcessingProgress) -> Void) async throws -> MediaInspection
}

extension RecordingProcessor: RecordingSessionProcessing {
    func processRecording(sourceURL: URL, destinationURL: URL,
                          configuration: RecordingProcessingConfiguration,
                          progress: @escaping @Sendable (RecordingProcessingProgress) -> Void) async throws -> MediaInspection {
        try await process(sourceURL: sourceURL, destinationURL: destinationURL,
                          configuration: configuration, progress: progress).inspection
    }
}

/// A persistent first-preview transaction. The original and every candidate
/// are private working files; only a verified, full-duration H.264 is imported
/// into History. Export files are never eligible for Source replacement.
@MainActor
final class RecordingProcessingSession {
    enum Phase: String, Codable { case prepared, processing, ready, failed, committing, committed }
    struct Candidate: Codable {
        let fileName: String
        let generation: Int
        let options: RecordingProcessingOptions
        let pixelSize: PixelSize
        let duration: TimeInterval
        let byteCount: Int64
        let sha256: String
    }
    struct Manifest: Codable {
        var schemaVersion = 1
        let id: RecordingID
        let createdAt: Date
        let duration: TimeInterval
        let capturedPixelSize: PixelSize
        let frameRate: CaptureFrameRate
        let audio: AudioConfiguration
        let target: ClipCore.CaptureTarget
        let captureSettings: ClipSettings
        var originalSHA256: String?
        var options: RecordingProcessingOptions
        var filename: RecordingFilename
        var trim: TrimRange
        var audioPreference: ExportAudioPreference = .keepAudio
        var generation = 0
        var phase: Phase = .prepared
        var candidate: Candidate?
        var failure: String?

        // Capture and processed MP4 timebases can differ by a fraction of a
        // millisecond. Edits belong to the media shown in Preview, not the raw clock.
        var editableDuration: TimeInterval { candidate?.duration ?? duration }
    }

    let directory: URL
    let captureStagingDirectory: URL
    private(set) var manifest: Manifest
    private let processor: any RecordingSessionProcessing
    private var worker: Task<PreviewRecording, any Error>?
    private var commitWorker: Task<RecordingHistoryItem?, any Error>?
    private var isDiscarded = false
    private var isCommitting = false

    var id: RecordingID { manifest.id }
    var originalURL: URL { directory.appendingPathComponent("original.mp4") }
    var nativePixelSize: PixelSize { manifest.capturedPixelSize }
    var options: RecordingProcessingOptions { manifest.options }
    var isProcessing: Bool { worker != nil }
    var isClosing: Bool { isCommitting }
    var journalURL: URL { directory.appendingPathComponent("session.json") }

    private init(directory: URL, captureStagingDirectory: URL, manifest: Manifest,
                 processor: any RecordingSessionProcessing) {
        self.directory = directory
        self.captureStagingDirectory = captureStagingDirectory
        self.manifest = manifest
        self.processor = processor
    }

    static func create(artifact: RecordingArtifact, captureSettings: ClipSettings,
                       directories: ApplicationDirectories,
                       processor: any RecordingSessionProcessing = RecordingProcessor()) async throws -> RecordingProcessingSession {
        try captureSettings.recordingProcessing.validate()
        let expected = directories.captureStaging.appendingPathComponent("\(artifact.id.description).mp4")
        guard artifact.fileURL.standardizedFileURL.path == expected.standardizedFileURL.path else {
            throw ProcessingSessionFailure("The recording is outside Clip's capture storage.")
        }
        try RecordingSessionFiles.requireRegularFile(expected)
        let directory = directories.processing.appendingPathComponent(artifact.id.description, isDirectory: true)
        try RecordingSessionFiles.ensureDirectory(directory)
        try RecordingSessionFiles.flush(directory.deletingLastPathComponent())
        let journal = directory.appendingPathComponent("session.json")
        guard !FileManager.default.fileExists(atPath: journal.path) else {
            throw ProcessingSessionFailure("A processing session already exists for this recording.")
        }
        let existingNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard !existingNames.contains(where: { $0 == "original.mp4" || $0.hasPrefix("candidate-") }) else {
            throw ProcessingSessionFailure("Existing working files need recovery before this recording can be adopted.")
        }
        let recoveryURL = CaptureRecoveryRecord.url(for: artifact.id, in: directories.captureStaging)
        let recovery = (try? Data(contentsOf: recoveryURL)).flatMap { try? CaptureRecoveryRecord.decode($0) }
        let created = recovery?.createdAt ?? Date()
        let manifest = Manifest(id: artifact.id, createdAt: created, duration: artifact.duration,
            capturedPixelSize: artifact.pixelSize, frameRate: artifact.frameRate,
            audio: artifact.audioConfiguration, target: artifact.captureTarget,
            captureSettings: captureSettings, options: captureSettings.recordingProcessing,
            filename: captureSettings.defaultFilenameTemplate.filename(at: created, timeZone: .current),
            trim: try .full(recordingDuration: artifact.duration))
        let session = RecordingProcessingSession(directory: directory,
            captureStagingDirectory: directories.captureStaging, manifest: manifest, processor: processor)
        // Write intent before transferring ownership. A crash at either side of
        // the move can be resumed from the UUID-named staging file.
        try session.persist()
        try session.adoptStagedOriginal()
        return session
    }

    static func recover(directory: URL, directories: ApplicationDirectories,
                        processor: any RecordingSessionProcessing = RecordingProcessor()) throws -> RecordingProcessingSession {
        try RecordingSessionFiles.requireSafeDirectory(directory)
        var manifest = try RecordingSessionFiles.decoder.decode(Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        guard manifest.schemaVersion == 1,
              directory.lastPathComponent == manifest.id.description,
              directory.deletingLastPathComponent().standardizedFileURL.path == directories.processing.standardizedFileURL.path,
              manifest.generation >= 0, manifest.duration.isFinite, manifest.duration > 0 else {
            throw ProcessingSessionFailure("Clip could not verify this unfinished recording.")
        }
        try manifest.options.validate()
        if let candidate = manifest.candidate {
            guard candidate.generation > 0, candidate.generation <= manifest.generation,
                  candidate.fileName == "candidate-\(candidate.generation).mp4",
                  candidate.duration.isFinite, candidate.duration > 0,
                  abs(candidate.duration - manifest.duration) <= 0.003 else {
                throw ProcessingSessionFailure("Clip could not verify the processed recording.")
            }
            try candidate.options.validate()
            // Adopt journals written before processed time became authoritative.
            if manifest.trim.endTime == manifest.duration {
                manifest.trim = try rebasedTrim(manifest.trim, from: manifest.duration, to: candidate.duration)
            }
        }
        try manifest.trim.validate(recordingDuration: manifest.editableDuration)
        let session = RecordingProcessingSession(directory: directory,
            captureStagingDirectory: directories.captureStaging, manifest: manifest, processor: processor)
        if manifest.phase != .committed { try session.adoptStagedOriginal() }
        return session
    }

    private func adoptStagedOriginal() throws {
        let staged = captureStagingDirectory.appendingPathComponent("\(id.description).mp4")
        if !FileManager.default.fileExists(atPath: originalURL.path),
           FileManager.default.fileExists(atPath: staged.path) {
            try RecordingSessionFiles.requireRegularFile(staged)
            try FileManager.default.moveItem(at: staged, to: originalURL)
            try RecordingSessionFiles.flush(originalURL)
            try RecordingSessionFiles.flush(directory)
            try RecordingSessionFiles.flush(captureStagingDirectory)
        }
        if FileManager.default.fileExists(atPath: originalURL.path) {
            try RecordingSessionFiles.requireRegularFile(originalURL)
            // The processing journal now owns the capture. Removing this
            // redundant sidecar cannot affect the retained original.
            try? FileManager.default.removeItem(at: CaptureRecoveryRecord.url(for: id, in: captureStagingDirectory))
        }
    }

    func previewRecording() throws -> PreviewRecording {
        if let candidate = manifest.candidate { return try recording(candidate) }
        return try PreviewRecording(id: id, sourceURL: originalURL, duration: manifest.duration,
            pixelSize: manifest.options.scale.pixelSize(from: nativePixelSize), frameRate: manifest.frameRate,
            audioConfiguration: manifest.audio, filename: manifest.filename, trimRange: manifest.trim,
            exportAudioPreference: manifest.audioPreference, retakePlan: retakePlan)
    }

    private var retakePlan: PreviewRetakePlan {
        PreviewRetakePlan(target: manifest.target, settings: manifest.captureSettings, usesExactSessionSettings: true)
    }

    private func recording(_ candidate: Candidate) throws -> PreviewRecording {
        try PreviewRecording(id: id, sourceURL: directory.appendingPathComponent(candidate.fileName),
            duration: candidate.duration, pixelSize: candidate.pixelSize, frameRate: manifest.frameRate,
            audioConfiguration: manifest.audio, filename: manifest.filename, trimRange: manifest.trim,
            exportAudioPreference: manifest.audioPreference, approximateExportByteCount: candidate.byteCount,
            retakePlan: retakePlan)
    }

    func updateMetadata(_ recording: PreviewRecording) throws {
        guard recording.id == id, !isDiscarded else { throw ProcessingSessionFailure("This recording is no longer open.") }
        try recording.trimRange.validate(recordingDuration: manifest.editableDuration)
        manifest.filename = recording.filename
        manifest.trim = recording.trimRange
        manifest.audioPreference = recording.exportAudioPreference
        try persistIfMediaExists()
    }

    func updateMetadata(_ request: PreviewExportRequest) throws {
        guard request.recordingID == id, !isDiscarded else { throw ProcessingSessionFailure("This recording is no longer open.") }
        try request.trimRange.validate(recordingDuration: manifest.editableDuration)
        manifest.filename = request.filename
        manifest.trim = request.trimRange
        manifest.audioPreference = request.audioPreference
        try persistIfMediaExists()
    }

    func process(options: RecordingProcessingOptions,
                 progress: @escaping PreviewProcessingProgress) async throws -> PreviewRecording {
        try Task.checkCancellation()
        try options.validate()
        guard !isDiscarded, !isCommitting, manifest.phase != .committed else {
            throw ProcessingSessionFailure("This Source has already been saved.")
        }
        // Awaiters may resume before the original caller clears its task. Clear
        // only that generation, then check again so queued requests never start
        // concurrent workers or resume past a close/discard ownership boundary.
        while let pending = worker {
            let pendingGeneration = manifest.generation
            _ = try? await pending.value
            if manifest.generation == pendingGeneration { worker = nil }
            try Task.checkCancellation()
        }
        guard !isDiscarded, !isCommitting, manifest.phase != .committed else {
            throw ProcessingSessionFailure("This Source has already been saved.")
        }
        try RecordingSessionFiles.requireRegularFile(originalURL)
        manifest.generation += 1
        let generation = manifest.generation
        // Capture bitrate is provenance of the original, not a setting that a
        // later compression pass can retroactively change.
        var recipe = options
        recipe.captureBitrateMbps = manifest.captureSettings.recordingProcessing.captureBitrateMbps
        manifest.options = recipe
        manifest.phase = .processing
        manifest.failure = nil
        try persist()
        let source = originalURL
        let destination = directory.appendingPathComponent("candidate-\(generation).mp4")
        let processor = processor
        let task = Task { @MainActor [weak self] () throws -> PreviewRecording in
            guard let self else { throw CancellationError() }
            let hash = try await RecordingSessionFiles.hash(source)
            if let expected = self.manifest.originalSHA256, hash != expected {
                throw ProcessingSessionFailure("The original recording changed on disk. Clip kept the existing files.")
            }
            self.manifest.originalSHA256 = hash
            try self.persist()
            let result = try await processor.processRecording(sourceURL: source, destinationURL: destination,
                configuration: .init(scalePercent: recipe.scale.rawValue, crf: recipe.crf)) { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard let self, self.manifest.generation == generation,
                              self.manifest.phase == .processing, !self.isDiscarded else { return }
                        let phase: PreviewProcessingPhase
                        switch event.phase {
                        case .preparing: phase = .preparing
                        case .encoding: phase = .processing
                        case .validating: phase = .finishing
                        }
                        progress(phase, event.fraction)
                    }
                }
            try Task.checkCancellation()
            guard !self.isDiscarded, self.manifest.generation == generation else { throw CancellationError() }
            let candidate = Candidate(fileName: destination.lastPathComponent, generation: generation,
                options: recipe, pixelSize: try PixelSize(width: result.width, height: result.height),
                duration: result.duration, byteCount: try RecordingSessionFiles.byteCount(destination),
                sha256: try await RecordingSessionFiles.hash(destination))
            guard candidate.pixelSize == (try recipe.scale.pixelSize(from: self.nativePixelSize)),
                  abs(candidate.duration - self.manifest.duration) <= 0.003 else {
                throw ProcessingSessionFailure("The processed video did not preserve the full recording. The original was retained.")
            }
            self.manifest.trim = try Self.rebasedTrim(self.manifest.trim,
                from: self.manifest.editableDuration, to: candidate.duration)
            self.manifest.candidate = candidate
            self.manifest.phase = .ready
            try self.persist()
            return try self.recording(candidate)
        }
        worker = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if manifest.generation == generation { worker = nil }
            return result
        } catch {
            if manifest.generation == generation {
                worker = nil
                manifest.phase = .failed
                manifest.failure = error.localizedDescription
                try? persistIfMediaExists()
            }
            throw error
        }
    }

    private static func rebasedTrim(_ trim: TrimRange, from priorDuration: TimeInterval,
                                    to duration: TimeInterval) throws -> TrimRange {
        let start = min(trim.startTime, max(0, duration - min(0.1, duration)))
        let end = trim.endTime == priorDuration ? duration : min(trim.endTime, duration)
        return try TrimRange(startTime: start, endTime: end)
    }

    /// Called only after the editor has settled its latest requested options.
    /// Nil means the user externally deleted every working video. No Source is
    /// fabricated, and independent drag/copy/export files remain untouched.
    func commit(recording: PreviewRecording?, history: ManagedHistoryRepository) async throws -> RecordingHistoryItem? {
        if let commitWorker { return try await commitWorker.value }
        guard !isDiscarded else { return nil }
        // Own the close before awaiting an encoder. A queued reprocess cannot
        // slip into the gap between encoding completion and Source publication.
        isCommitting = true
        let task = Task { @MainActor in try await finishCommit(recording: recording, history: history) }
        commitWorker = task
        defer { commitWorker = nil; isCommitting = false }
        return try await task.value
    }

    private func finishCommit(recording: PreviewRecording?, history: ManagedHistoryRepository) async throws -> RecordingHistoryItem? {
        if let worker {
            do { _ = try await worker.value }
            catch {
                if !hasWorkingMedia { cleanupWorkingFiles(); return nil }
                throw error
            }
        }
        guard !isDiscarded else { return nil }
        if !hasWorkingMedia, manifest.phase != .committed { cleanupWorkingFiles(); return nil }
        if let recording { try updateMetadata(recording) }
        guard let candidate = manifest.candidate,
              candidate.generation == manifest.generation,
              candidate.options.scale == manifest.options.scale,
              candidate.options.crf == manifest.options.crf,
              [.ready, .committing, .committed].contains(manifest.phase) else {
            throw ProcessingSessionFailure("This recording is unfinished. Its original was kept for recovery.")
        }
        let file = directory.appendingPathComponent(candidate.fileName)
        let item: RecordingHistoryItem
        if let saved = try await history.item(id: id) {
            let savedURL = try await history.masterURL(for: id)
            guard try await RecordingSessionFiles.hash(savedURL) == candidate.sha256 else {
                throw ProcessingSessionFailure("Clip could not verify the saved Source. The original was retained.")
            }
            item = saved
        } else {
            try RecordingSessionFiles.requireRegularFile(file)
            guard try await RecordingSessionFiles.hash(file) == candidate.sha256 else {
                throw ProcessingSessionFailure("The processed recording changed on disk. The original was retained.")
            }
            manifest.phase = .committing
            try persist()
            item = try await history.importFinalizedRecording(.init(id: id, sourceURL: file,
                createdAt: manifest.createdAt, filename: manifest.filename,
                duration: candidate.duration, pixelSize: candidate.pixelSize, frameRate: manifest.frameRate,
                audioConfiguration: manifest.audio, captureTarget: manifest.target,
                captureSessionSnapshot: CaptureSessionSnapshot(settings: manifest.captureSettings),
                processing: .init(options: candidate.options, capturedPixelSize: nativePixelSize),
                trimRange: manifest.trim, exportAudioPreference: manifest.audioPreference))
        }
        let savedURL = try await history.masterURL(for: id)
        // The Source and History index must be durable before raw cleanup.
        try RecordingSessionFiles.flush(savedURL)
        try RecordingSessionFiles.flush(history.indexURL)
        try RecordingSessionFiles.flush(history.indexURL.deletingLastPathComponent())
        try RecordingSessionFiles.flush(savedURL.deletingLastPathComponent())
        manifest.phase = .committed
        manifest.failure = nil
        do {
            try persist()
            cleanupWorkingFiles()
        } catch {
            // Saving succeeded. Retaining temporary media is preferable to
            // reporting a failed save or risking the sole original.
            ClipLog.storage.warning("Source saved; temporary cleanup deferred: \(error.localizedDescription, privacy: .public)")
        }
        return item
    }

    var hasWorkingMedia: Bool {
        if RecordingSessionFiles.entryExists(originalURL) { return true }
        return !allocatedCandidateFiles.isEmpty
    }

    private var allocatedCandidateFiles: [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { file in
            let stem = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "mp4", stem.hasPrefix("candidate-"),
                  let generation = Int(stem.dropFirst("candidate-".count)),
                  generation > 0, generation <= manifest.generation else { return false }
            return stem == "candidate-\(generation)"
        }
    }

    func discard() async {
        isDiscarded = true
        worker?.cancel()
        _ = try? await worker?.value
        worker = nil
        _ = try? await commitWorker?.value
        cleanupWorkingFiles()
    }

    private func cleanupWorkingFiles() {
        guard (try? RecordingSessionFiles.requireSafeDirectory(directory)) != nil else { return }
        // No directory-wide deletion: only the fixed original and candidates
        // allocated by this session are ours. Promised drags own separate links.
        for file in [originalURL] + allocatedCandidateFiles {
            guard (try? RecordingSessionFiles.requireRegularFile(file)) != nil else { continue }
            try? FileManager.default.removeItem(at: file)
        }
        if !hasWorkingMedia {
            try? FileManager.default.removeItem(at: journalURL)
            // Remove an empty directory only; retain unknown files for safety.
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func persistIfMediaExists() throws {
        guard hasWorkingMedia else { return }
        try persist()
    }

    private func persist() throws {
        try RecordingSessionFiles.ensureDirectory(directory)
        try RecordingSessionFiles.encoder.encode(manifest).write(to: journalURL, options: .atomic)
        try RecordingSessionFiles.flush(journalURL)
        try RecordingSessionFiles.flush(directory)
    }
}

struct ProcessingSessionFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Small, shared ownership checks for journals and independent drag read links.
enum RecordingSessionFiles {
    static func entryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
    static func ensureDirectory(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ProcessingSessionFailure("Clip's recording storage has moved. The files were left untouched.")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try requireSafeDirectory(url)
    }
    static func requireSafeDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ProcessingSessionFailure("Clip could not verify its recording storage.")
        }
    }
    static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ProcessingSessionFailure("The recording's working files are no longer available.")
        }
    }
    static func byteCount(_ url: URL) throws -> Int64 {
        try requireRegularFile(url)
        return Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    static func hash(_ url: URL) async throws -> String {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            try requireRegularFile(url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    static func flush(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}

/// The native file promise may be requested after its editor has closed. A
/// private hard link (or APFS clone) keeps that exact processed generation alive
/// independently of temporary raw cleanup and History deletion.
final class RecordingDragSourceLease: PreviewSourceLease, @unchecked Sendable {
    let sourceURL: URL
    init(source: URL, exportsDirectory: URL) throws {
        try RecordingSessionFiles.requireRegularFile(source)
        let readers = exportsDirectory.appendingPathComponent(".readers", isDirectory: true)
        try RecordingSessionFiles.ensureDirectory(readers)
        sourceURL = readers.appendingPathComponent("\(UUID().uuidString).mp4")
        do { try FileManager.default.linkItem(at: source, to: sourceURL) }
        catch { try FileManager.default.copyItem(at: source, to: sourceURL) }
    }
    deinit { try? FileManager.default.removeItem(at: sourceURL) }
}
