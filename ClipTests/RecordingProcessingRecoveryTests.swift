import ClipCore
import ClipMedia
import CoreMedia
import Foundation
import Testing
@testable import Clip

@MainActor
@Suite("Recording processing startup recovery")
struct RecordingProcessingRecoveryTests {
    @Test("A crash after History import finishes cleanup without another Source or encode")
    func resumesCommittedSourceWithoutDuplication() async throws {
        for phase in [RecordingProcessingSession.Phase.committing, .committed] {
            let fixture = try ProcessingSessionTestFixture()
            defer { fixture.remove() }
            let encoder = ProcessingSessionTestProcessor()
            let session = try await fixture.makeSession(processor: encoder)
            let candidate = try await session.process(options: .defaults, progress: { _, _ in })
            let bytes = try Data(contentsOf: candidate.sourceURL)
            var crashJournal = session.manifest
            crashJournal.phase = phase
            let saved = try #require(try await session.commit(recording: candidate, history: fixture.history))
            try FileManager.default.createDirectory(at: session.directory, withIntermediateDirectories: true)
            try fixture.captureBytes.write(to: session.originalURL)
            try bytes.write(to: candidate.sourceURL)
            try RecordingSessionFiles.encoder.encode(crashJournal).write(to: session.journalURL)

            let report = await RecordingProcessingRecovery.recover(directories: fixture.directories,
                history: fixture.history, processor: encoder)
            #expect(report.failures.isEmpty)
            #expect(report.recovered.map(\.id) == [saved.id])
            #expect(try await fixture.history.load().items.count == 1)
            #expect(await encoder.callCount == 1)
            #expect(!FileManager.default.fileExists(atPath: session.originalURL.path))
            #expect(!FileManager.default.fileExists(atPath: candidate.sourceURL.path))
            let source = try await fixture.history.masterURL(for: saved.id)
            #expect(try Data(contentsOf: source) == bytes)
        }
    }

    @Test("Prepared jobs resume their persisted recipe and save an untrimmed Source")
    func resumesPreparedJob() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let encoder = ProcessingSessionTestProcessor()
        var settings = fixture.settings
        settings.recordingProcessing = .init(scale: .half, crf: 28, captureBitrateMbps: 20)
        let session = try await RecordingProcessingSession.create(artifact: fixture.artifact,
            captureSettings: settings, directories: fixture.directories, processor: encoder)
        let report = await RecordingProcessingRecovery.recover(directories: fixture.directories,
            history: fixture.history, processor: encoder)
        let saved = try #require(report.recovered.first)
        #expect(report.failures.isEmpty && saved.id == session.id)
        #expect(saved.processing?.options == settings.recordingProcessing)
        #expect(saved.recordingDuration == 10 && saved.trimRange.duration == 10)
    }

    @Test("Missing journals and arbitrary videos remain untouched instead of guessing ownership")
    func missingJournalAndUnknownVideosRemain() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let encoder = ProcessingSessionTestProcessor()
        let session = try await fixture.makeSession(processor: encoder)
        try FileManager.default.removeItem(at: session.journalURL)
        let unknown = fixture.directories.processing.appendingPathComponent("manual-video.mp4")
        try Data("unowned video".utf8).write(to: unknown)
        let report = await RecordingProcessingRecovery.recover(directories: fixture.directories,
            history: fixture.history, processor: encoder)
        #expect(report.recovered.isEmpty && report.failures.count == 1)
        #expect(await encoder.callCount == 0)
        #expect(try Data(contentsOf: session.originalURL) == fixture.captureBytes)
        #expect(try Data(contentsOf: unknown) == Data("unowned video".utf8))
        #expect(!FileManager.default.fileExists(atPath: session.journalURL.path))
    }

    @Test("Capture metadata without its video is retained without creating an empty job")
    func metadataOnlyCaptureIsRetained() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let sidecar = try writeSidecar(fixture)
        try FileManager.default.removeItem(at: fixture.artifact.fileURL)
        let encoder = ProcessingSessionTestProcessor()
        let report = await RecordingProcessingRecovery.recover(directories: fixture.directories,
            history: fixture.history, processor: encoder, inspect: Self.inspection)
        #expect(report.recovered.isEmpty && report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
        #expect(await encoder.callCount == 0)
    }

    @Test("A matching staged sidecar and inspected HEVC resume through the production transaction")
    func stagedCaptureResumes() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let sidecar = try writeSidecar(fixture)
        let encoder = ProcessingSessionTestProcessor()
        let report = await RecordingProcessingRecovery.recover(directories: fixture.directories,
            history: fixture.history, processor: encoder, inspect: Self.inspection)
        let saved = try #require(report.recovered.first)
        #expect(report.failures.isEmpty && saved.id == fixture.artifact.id)
        #expect(saved.recordingDuration == 10 && saved.processing?.options == .defaults)
        #expect(await encoder.callCount == 1)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.artifact.fileURL.path))
    }

    @Test("A mismatched capture sidecar cannot claim a UUID-named staged movie")
    func mismatchedStagingMetadataIsRejected() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let sidecar = CaptureRecoveryRecord.url(for: fixture.artifact.id, in: fixture.directories.captureStaging)
        let record = CaptureRecoveryRecord(recordingID: RecordingID(), createdAt: Date(),
            captureTarget: fixture.artifact.captureTarget, settings: fixture.settings)
        try record.encoded().write(to: sidecar)
        let report = await RecordingProcessingRecovery.recover(directories: fixture.directories,
            history: fixture.history, processor: ProcessingSessionTestProcessor(), inspect: Self.inspection)
        #expect(report.recovered.isEmpty && report.failures.count == 1)
        #expect(try Data(contentsOf: fixture.artifact.fileURL) == fixture.captureBytes)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
    }

    @Test("Cancellation stops recovery before ownership or processing work begins")
    func cancelledRecoveryLeavesCapture() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let sidecar = try writeSidecar(fixture)
        let encoder = ProcessingSessionTestProcessor()
        let recovery = Task { await RecordingProcessingRecovery.recover(directories: fixture.directories,
            history: fixture.history, processor: encoder, inspect: Self.inspection) }
        recovery.cancel()
        let report = await recovery.value
        #expect(report.recovered.isEmpty && report.failures.isEmpty)
        #expect(await encoder.callCount == 0)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(try Data(contentsOf: fixture.artifact.fileURL) == fixture.captureBytes)
    }

    @Test("Cancellation during encoding retains the current original and does not start staged work")
    func cancellationBetweenJobsKeepsRecoverableFiles() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let encoder = ProcessingSessionTestProcessor(blocked: [1])
        let session = try await fixture.makeSession(processor: encoder)
        let stagedID = RecordingID()
        let staged = fixture.directories.captureStaging.appendingPathComponent("\(stagedID.description).mp4")
        try fixture.captureBytes.write(to: staged)
        let sidecar = CaptureRecoveryRecord.url(for: stagedID, in: fixture.directories.captureStaging)
        try CaptureRecoveryRecord(recordingID: stagedID, createdAt: Date(),
            captureTarget: fixture.artifact.captureTarget, settings: fixture.settings).encoded().write(to: sidecar)
        let recovery = Task { await RecordingProcessingRecovery.recover(directories: fixture.directories,
            history: fixture.history, processor: encoder, inspect: Self.inspection) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await encoder.callCount == 0 {
            guard ContinuousClock.now < deadline else { throw ProcessingSessionTestFailure.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
        recovery.cancel()
        await encoder.release(1)
        let report = await recovery.value
        #expect(report.recovered.isEmpty && report.failures.isEmpty)
        #expect(await encoder.callCount == 1)
        #expect(try await fixture.history.load().items.isEmpty)
        #expect(try Data(contentsOf: session.originalURL) == fixture.captureBytes)
        #expect(try Data(contentsOf: staged) == fixture.captureBytes)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test("Startup reader cleanup preserves published exports, unknown files, and symlinks")
    func readerCleanupIsNarrowlyOwned() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let readers = fixture.directories.exports.appendingPathComponent(".readers", isDirectory: true)
        try FileManager.default.createDirectory(at: readers, withIntermediateDirectories: true)
        let stale = readers.appendingPathComponent("\(UUID().uuidString).mp4")
        let unknown = readers.appendingPathComponent("not-a-reader.mp4")
        let published = fixture.directories.exports.appendingPathComponent("shared.mp4")
        let linked = readers.appendingPathComponent("\(UUID().uuidString).mp4")
        for file in [stale, unknown, published] { try Data("preserved bytes".utf8).write(to: file) }
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: published)
        let report = await RecordingProcessingRecovery.recover(directories: fixture.directories,
            history: fixture.history, processor: ProcessingSessionTestProcessor())
        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(RecordingSessionFiles.entryExists(linked))
        #expect(try Data(contentsOf: published) == Data("preserved bytes".utf8))
    }

    private func writeSidecar(_ fixture: ProcessingSessionTestFixture) throws -> URL {
        let sidecar = CaptureRecoveryRecord.url(for: fixture.artifact.id, in: fixture.directories.captureStaging)
        let record = CaptureRecoveryRecord(recordingID: fixture.artifact.id, createdAt: Date(),
            captureTarget: fixture.artifact.captureTarget, settings: fixture.settings)
        try record.encoded().write(to: sidecar)
        return sidecar
    }

    nonisolated private static func inspection(_ url: URL) async throws -> MediaInspection {
        let data = try Data(contentsOf: url)
        return MediaInspection(duration: 10, fileSize: Int64(data.count), videoTrackCount: 1,
            audioTrackCount: 0, width: 1280, height: 720, nominalFramesPerSecond: 30,
            videoCodec: kCMVideoCodecType_HEVC)
    }
}
