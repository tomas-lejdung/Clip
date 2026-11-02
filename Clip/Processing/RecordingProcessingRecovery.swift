import ClipCore
import ClipMedia
import CoreMedia
import Foundation

struct RecordingProcessingRecoveryFailure: Sendable {
    let fileURL: URL
    let reason: String
}

struct RecordingProcessingRecoveryReport: Sendable {
    var recovered: [RecordingHistoryItem] = []
    var failures: [RecordingProcessingRecoveryFailure] = []
}

/// Startup-only reconciliation, before legacy capture recovery and retention.
/// A journal establishes recording ownership; filenames alone never adopt a
/// video. Cancellation leaves current working files available for the next run.
@MainActor
enum RecordingProcessingRecovery {
    static func recover(
        directories: ApplicationDirectories,
        history: ManagedHistoryRepository,
        processor: any RecordingSessionProcessing = RecordingProcessor(),
        inspect: @escaping @Sendable (URL) async throws -> MediaInspection = { try await MediaInspector.inspect($0) }
    ) async -> RecordingProcessingRecoveryReport {
        var report = RecordingProcessingRecoveryReport()
        var existingJobs: Set<RecordingID> = []
        guard !Task.isCancelled else { return report }

        if RecordingSessionFiles.entryExists(directories.processing) {
            do {
                try RecordingSessionFiles.requireSafeDirectory(directories.processing)
                let entries = try FileManager.default.contentsOfDirectory(at: directories.processing,
                    includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for directory in entries {
                    guard !Task.isCancelled else { return report }
                    guard let id = canonicalID(directory.lastPathComponent) else { continue }
                    existingJobs.insert(id)
                    do {
                        try RecordingSessionFiles.requireSafeDirectory(directory)
                        try RecordingSessionFiles.requireRegularFile(directory.appendingPathComponent("session.json"))
                        let session = try RecordingProcessingSession.recover(directory: directory,
                            directories: directories, processor: processor)
                        switch session.manifest.phase {
                        case .ready, .committing, .committed:
                            break
                        case .prepared, .processing, .failed:
                            guard !Task.isCancelled else { return report }
                            _ = try await session.process(options: session.options, progress: { _, _ in })
                        }
                        guard !Task.isCancelled else { return report }
                        if let saved = try await session.commit(recording: nil, history: history) {
                            report.recovered.append(saved)
                        }
                    } catch {
                        guard !Task.isCancelled, !(error is CancellationError) else { return report }
                        report.failures.append(.init(fileURL: directory, reason: error.localizedDescription))
                    }
                }
            } catch {
                report.failures.append(.init(fileURL: directories.processing, reason: error.localizedDescription))
                return report
            }
        }

        guard !Task.isCancelled else { return report }
        if RecordingSessionFiles.entryExists(directories.captureStaging) {
            do {
                try RecordingSessionFiles.requireSafeDirectory(directories.captureStaging)
                let entries = try FileManager.default.contentsOfDirectory(at: directories.captureStaging,
                    includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for sidecar in entries {
                    guard !Task.isCancelled else { return report }
                    guard let id = stagingID(sidecar.lastPathComponent), !existingJobs.contains(id) else { continue }
                    let video = directories.captureStaging.appendingPathComponent("\(id.description).mp4")
                    do {
                        try RecordingSessionFiles.requireRegularFile(sidecar)
                        let record = try CaptureRecoveryRecord.decode(Data(contentsOf: sidecar))
                        guard record.schemaVersion == CaptureRecoveryRecord.currentSchemaVersion,
                              record.recordingID == id else {
                            throw ProcessingSessionFailure("Clip could not verify the staged recording's ownership. Its files were kept.")
                        }
                        guard try await history.item(id: id) == nil else {
                            throw ProcessingSessionFailure("This recording is already in History. The additional staged files were kept.")
                        }
                        try RecordingSessionFiles.requireRegularFile(video)
                        let media = try await inspect(video)
                        guard !Task.isCancelled else { return report }
                        guard media.videoTrackCount == 1, media.videoCodec == kCMVideoCodecType_HEVC,
                              media.duration.isFinite, media.duration > 0,
                              media.width >= 2, media.height >= 2 else {
                            throw ProcessingSessionFailure("The staged video could not be verified as a complete recording. Its files were kept.")
                        }
                        let artifact = RecordingArtifact(id: id, fileURL: video, duration: media.duration,
                            pixelSize: try PixelSize(width: media.width, height: media.height),
                            frameRate: record.settings.frameRate, audioConfiguration: record.settings.audio,
                            captureTarget: record.captureTarget)
                        let session = try await RecordingProcessingSession.create(artifact: artifact,
                            captureSettings: record.settings, directories: directories, processor: processor)
                        guard !Task.isCancelled else { return report }
                        _ = try await session.process(options: session.options, progress: { _, _ in })
                        guard !Task.isCancelled else { return report }
                        if let saved = try await session.commit(recording: nil, history: history) {
                            report.recovered.append(saved)
                        }
                    } catch {
                        guard !Task.isCancelled, !(error is CancellationError) else { return report }
                        report.failures.append(.init(fileURL: video, reason: error.localizedDescription))
                    }
                }
            } catch {
                report.failures.append(.init(fileURL: directories.captureStaging, reason: error.localizedDescription))
            }
        }

        guard !Task.isCancelled else { return report }
        cleanAbandonedReaderLinks(in: directories.exports, report: &report)
        return report
    }

    private static func canonicalID(_ name: String) -> RecordingID? {
        guard let uuid = UUID(uuidString: name), RecordingID(uuid).description == name else { return nil }
        return RecordingID(uuid)
    }

    private static func stagingID(_ name: String) -> RecordingID? {
        let suffix = ".clip-recovery.json"
        guard name.hasPrefix("."), name.hasSuffix(suffix) else { return nil }
        return canonicalID(String(name.dropFirst().dropLast(suffix.count)))
    }

    /// Old reader leases cannot belong to the new process. Published exports
    /// and anything outside this private, strictly named namespace are retained.
    private static func cleanAbandonedReaderLinks(in exports: URL,
                                                  report: inout RecordingProcessingRecoveryReport) {
        let readers = exports.appendingPathComponent(".readers", isDirectory: true)
        guard RecordingSessionFiles.entryExists(readers) else { return }
        do {
            try RecordingSessionFiles.requireSafeDirectory(readers)
            for file in try FileManager.default.contentsOfDirectory(at: readers, includingPropertiesForKeys: nil) {
                guard !Task.isCancelled else { return }
                let stem = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "mp4", let uuid = UUID(uuidString: stem),
                      uuid.uuidString.lowercased() == stem.lowercased() else { continue }
                // Symlinks and unreadable files are not established reader links.
                guard (try? RecordingSessionFiles.requireRegularFile(file)) != nil else { continue }
                do { try FileManager.default.removeItem(at: file) }
                catch { report.failures.append(.init(fileURL: file, reason: error.localizedDescription)) }
            }
        } catch {
            report.failures.append(.init(fileURL: readers, reason: error.localizedDescription))
        }
    }
}
