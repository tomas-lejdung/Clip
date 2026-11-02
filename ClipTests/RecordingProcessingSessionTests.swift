@preconcurrency import AVFoundation
import ClipCore
import ClipMedia
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import Testing
@testable import Clip

/// Ownership tests use an injected deterministic encoder; one real integration
/// test also exercises the production hardware writer and bundled x264 helper.
@MainActor
@Suite("Recording processing ownership")
struct RecordingProcessingSessionTests {
    @Test("Bundled encoder processes hardware HEVC at every scale, exports a trim, and stores the full native Source")
    func bundledEncoderCompletesProductionSession() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let processor = RecordingProcessor()
        #expect(FileManager.default.isExecutableFile(atPath: processor.executableURL.path))
        try FileManager.default.removeItem(at: fixture.artifact.fileURL)
        try await ProcessingVideoFixture.writeHEVC(to: fixture.artifact.fileURL)
        let captured = try await MediaInspector.inspect(fixture.artifact.fileURL)
        #expect(captured.videoCodec == kCMVideoCodecType_HEVC)
        #expect(captured.width == 1280 && captured.height == 720)
        // Older Clip versions could keep HEVC Sources in History. Their first
        // share must normalize a separate full H.264 file, never replace Source.
        let legacyHash = try await RecordingSessionFiles.hash(fixture.artifact.fileURL)
        let legacyExporter = PreviewExportCoordinator(exportsDirectory: fixture.directories.exports)
        for trim in [try TrimRange.full(recordingDuration: captured.duration), try TrimRange(startTime: 0.4, endTime: 1.6)] {
            let export = try await legacyExporter.export(.init(recordingID: fixture.artifact.id,
                sourceURL: fixture.artifact.fileURL, captureFrameRate: .thirty,
                filename: .init(validating: "legacy-feature.mp4"), trimRange: trim, audioPreference: .keepAudio))
            let legacyOutput = try await MediaInspector.inspect(export)
            #expect(legacyOutput.videoCodec == kCMVideoCodecType_H264)
            #expect(legacyOutput.width == 1280 && legacyOutput.height == 720 && legacyOutput.audioTrackCount == 0)
            #expect(abs(legacyOutput.duration - trim.duration) < 0.04)
            #expect(try await RecordingSessionFiles.hash(fixture.artifact.fileURL) == legacyHash)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: export.deletingLastPathComponent().path)
            #expect(!remaining.contains { $0.hasPrefix(".legacy-hevc-") || $0.hasSuffix(".processing.mp4") })
        }
        let artifact = RecordingArtifact(id: fixture.artifact.id, fileURL: fixture.artifact.fileURL,
            duration: captured.duration, pixelSize: fixture.artifact.pixelSize, frameRate: .thirty,
            audioConfiguration: .none, captureTarget: fixture.artifact.captureTarget)
        let session = try await RecordingProcessingSession.create(artifact: artifact,
            captureSettings: fixture.settings, directories: fixture.directories, processor: processor)
        var final: PreviewRecording?
        for scale in [RecordingResolutionScale.threeQuarter, .half, .quarter, .native] {
            let candidate = try await session.process(options: .init(scale: scale, crf: 24), progress: { _, _ in })
            let inspection = try await MediaInspector.inspect(candidate.sourceURL)
            let expected = try scale.pixelSize(from: artifact.pixelSize)
            #expect(inspection.videoCodec == kCMVideoCodecType_H264)
            #expect(inspection.width == expected.width && inspection.height == expected.height)
            #expect(abs(inspection.duration - captured.duration) < 0.003)
            #expect(candidate.pixelSize == expected)
            final = candidate
        }
        var preview = try #require(final)
        preview.trimRange = try .init(startTime: 0.4, endTime: 1.6)
        preview.filename = try .init(validating: "feature-change.mp4")
        let candidateHash = try await RecordingSessionFiles.hash(preview.sourceURL)
        let exporter = PreviewExportCoordinator(exportsDirectory: fixture.directories.exports)
        let fullRequest = try PreviewExportRequest(recordingID: preview.id, sourceURL: preview.sourceURL,
            captureFrameRate: preview.frameRate, filename: .init(validating: "clip-20261102-091550.mp4"),
            trimRange: .full(recordingDuration: captured.duration), audioPreference: .keepAudio)
        let publication = try await exporter.exportForPublication(fullRequest)
        let fullExport = publication.outputURL
        _ = try await exporter.markPublished(fullRequest, lease: publication)
        #expect(try await RecordingSessionFiles.hash(fullExport) == candidateHash)
        let trimRequest = PreviewExportRequest(recordingID: preview.id, sourceURL: preview.sourceURL,
            captureFrameRate: preview.frameRate, filename: preview.filename,
            trimRange: preview.trimRange, audioPreference: .removeAudio)
        let exported = try await exporter.export(trimRequest)
        let preparedDate = try exported.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let dragLease = try RecordingDragSourceLease(source: preview.sourceURL,
            exportsDirectory: fixture.directories.exports)
        let dragRequest = PreviewExportRequest(recordingID: preview.id, sourceURL: dragLease.sourceURL,
            captureFrameRate: preview.frameRate, filename: preview.filename,
            trimRange: preview.trimRange, audioPreference: .removeAudio,
            sourceCacheIdentity: PreviewExportCoordinator.sourceCacheIdentity(for: trimRequest))
        #expect(await exporter.cacheKey(for: dragRequest) == exporter.cacheKey(for: trimRequest))
        let copied = try await exporter.exportForPublication(trimRequest)
        #expect(copied.outputURL == exported)
        _ = try await exporter.markPublished(trimRequest, lease: copied)
        let trimmed = try await MediaInspector.inspect(exported)
        #expect(abs(trimmed.duration - 1.2) < 0.04)
        #expect(trimmed.videoCodec == kCMVideoCodecType_H264 && trimmed.audioTrackCount == 0)
        let saved = try #require(try await session.commit(recording: preview, history: fixture.history))
        let source = try await fixture.history.masterURL(for: saved.id)
        #expect(source.standardizedFileURL != exported.standardizedFileURL)
        #expect(try await RecordingSessionFiles.hash(source) == candidateHash)
        #expect(abs(saved.recordingDuration - captured.duration) < 0.003)
        #expect(saved.pixelSize == artifact.pixelSize && saved.processing?.options.crf == 24)
        #expect(saved.processing?.options.scale == .native && saved.trimRange == preview.trimRange)
        #expect(!session.hasWorkingMedia && FileManager.default.fileExists(atPath: exported.path))
        // The receiver can request a drag after Preview closes and raw/candidate
        // files disappear. It reuses the exact Save Trim result, not a new remux.
        let dragged = try await exporter.exportForPublication(dragRequest)
        #expect(dragged.outputURL == exported)
        #expect(try exported.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == preparedDate)
        _ = try await exporter.markPublished(dragRequest, lease: dragged)
        withExtendedLifetime(dragLease) {}
        let reopenedRepository = try ManagedHistoryRepository(applicationSupportDirectory: fixture.directories.applicationSupport,
            recordingsDirectory: fixture.directories.recordings)
        let reopened = try #require(try await reopenedRepository.item(id: saved.id))
        let restored = try await reopenedRepository.updateTrim(id: reopened.id,
            trimRange: .full(recordingDuration: reopened.recordingDuration))
        let full = try await MediaInspector.inspect(source)
        #expect(abs(full.duration - captured.duration) < 0.003)
        #expect(restored.trimRange.startTime == 0 && restored.trimRange.endTime == captured.duration)
    }

    @Test("Repeated trim restores use the processed duration across reprocessing, recovery, and close",
          arguments: [10.0005, 9.9995])
    func processedDurationOwnsTrimTimeline(duration: TimeInterval) async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let encoder = ProcessingSessionTestProcessor(duration: duration)
        let session = try await fixture.makeSession(processor: encoder)
        var preview = try await session.process(options: .defaults, progress: { _, _ in })
        #expect(preview.duration == duration)
        #expect(preview.trimRange.endTime == duration)
        for range in [try TrimRange(startTime: 1.073, endTime: 7),
                      try TrimRange(startTime: 1.073, endTime: duration),
                      try TrimRange.full(recordingDuration: duration)] {
            preview.trimRange = range
            try session.updateMetadata(preview)
            try session.updateMetadata(.init(recordingID: preview.id, sourceURL: preview.sourceURL,
                captureFrameRate: preview.frameRate, filename: preview.filename,
                trimRange: range, audioPreference: preview.exportAudioPreference))
            #expect(session.manifest.trim == range)
        }
        // Restore to the end again after changing resolution/CRF and reopening
        // an interrupted first-preview session. The raw clock remains provenance.
        let reprocessedDuration = duration > 10 ? 9.9995 : 10.0005
        await encoder.setDuration(reprocessedDuration)
        preview = try await session.process(options: .init(scale: .half, crf: 28), progress: { _, _ in })
        #expect(preview.trimRange.endTime == reprocessedDuration)
        let recovered = try RecordingProcessingSession.recover(directory: session.directory,
            directories: fixture.directories, processor: encoder)
        #expect(try recovered.previewRecording().trimRange.endTime == reprocessedDuration)
        let saved = try #require(try await recovered.commit(recording: preview, history: fixture.history))
        #expect(saved.recordingDuration == reprocessedDuration && saved.trimRange.endTime == reprocessedDuration)
        #expect(!recovered.hasWorkingMedia)
    }

    @Test("Cancelling the caller cancels its encoder and preserves the raw recording for recovery")
    func cancellationReachesOwnedEncoder() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let processor = CancellationObservingSessionProcessor()
        let session = try await fixture.makeSession(processor: processor)
        let process = Task { try await session.process(options: .defaults, progress: { _, _ in }) }
        try await waitUntil { await processor.started }
        process.cancel()
        await #expect(throws: CancellationError.self) { try await process.value }
        #expect(await processor.wasCancelled)
        #expect(session.manifest.phase == .failed)
        #expect(try Data(contentsOf: session.originalURL) == fixture.captureBytes)
        #expect(FileManager.default.fileExists(atPath: session.journalURL.path))
        #expect(try await fixture.history.load().items.isEmpty)
    }

    @Test("Capture adoption, reprocessing, and commit preserve full Source and independent exports")
    func adoptProcessAndCommit() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let encoder = ProcessingSessionTestProcessor()
        let session = try await fixture.makeSession(processor: encoder)
        #expect(!FileManager.default.fileExists(atPath: fixture.artifact.fileURL.path))
        #expect(try Data(contentsOf: session.originalURL) == fixture.captureBytes)
        #expect(FileManager.default.fileExists(atPath: session.journalURL.path))
        var first = try await session.process(options: .defaults, progress: { _, _ in })
        first.filename = try .init(validating: "feature-change.mp4")
        first.trimRange = try .init(startTime: 2, endTime: 7)
        first.exportAudioPreference = .removeAudio
        try session.updateMetadata(first)
        let final = try await session.process(options: .init(scale: .half, crf: 28, captureBitrateMbps: 40), progress: { _, _ in })
        #expect(final.duration == 10 && final.trimRange == first.trimRange)
        #expect(final.filename == first.filename && final.exportAudioPreference == .removeAudio)
        #expect(session.options.captureBitrateMbps == 10)
        #expect(final.pixelSize == (try PixelSize(width: 640, height: 360)))
        #expect(await encoder.sources == [session.originalURL, session.originalURL])

        let candidateBytes = try Data(contentsOf: final.sourceURL)
        let independentExport = fixture.root.appendingPathComponent("user-trimmed-export.mp4")
        let exportBytes = Data("short independently shared excerpt".utf8)
        try exportBytes.write(to: independentExport)
        let dragLease = try RecordingDragSourceLease(source: final.sourceURL, exportsDirectory: fixture.directories.exports)
        let saved = try #require(try await session.commit(recording: final, history: fixture.history))
        let source = try await fixture.history.masterURL(for: saved.id)
        #expect(try Data(contentsOf: source) == candidateBytes)
        #expect(saved.recordingDuration == 10 && saved.trimRange == first.trimRange)
        #expect(saved.processing?.options == .init(scale: .half, crf: 28, captureBitrateMbps: 10))
        #expect(saved.processing?.capturedPixelSize == fixture.artifact.pixelSize)
        #expect(try Data(contentsOf: independentExport) == exportBytes)
        #expect(try Data(contentsOf: dragLease.sourceURL) == candidateBytes)
        #expect(!session.hasWorkingMedia)
        let full = try await fixture.history.updateTrim(id: saved.id, trimRange: .full(recordingDuration: saved.recordingDuration))
        #expect(full.trimRange.duration == 10)
        withExtendedLifetime(dragLease) {}
    }

    @Test("An external input is rejected before a processing journal or ownership is created")
    func rejectsUnownedCaptureBeforeMutation() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("user-recording.mp4")
        try fixture.captureBytes.write(to: outside)
        let artifact = RecordingArtifact(id: fixture.artifact.id, fileURL: outside,
            duration: 10, pixelSize: fixture.artifact.pixelSize, frameRate: .thirty,
            audioConfiguration: .none, captureTarget: fixture.artifact.captureTarget)
        await #expect(throws: ProcessingSessionFailure.self) {
            try await RecordingProcessingSession.create(artifact: artifact, captureSettings: fixture.settings,
                directories: fixture.directories, processor: ProcessingSessionTestProcessor())
        }
        #expect(try Data(contentsOf: outside) == fixture.captureBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
    }

    @Test("Missing journal is rebuilt from the current session without adopting an export")
    func missingJournalRebuildsInMemorySession() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let session = try await fixture.makeSession(processor: ProcessingSessionTestProcessor())
        var candidate = try await session.process(options: .defaults, progress: { _, _ in })
        try FileManager.default.removeItem(at: session.journalURL)
        candidate.filename = try .init(validating: "recovered-name.mp4")
        try session.updateMetadata(candidate)
        let journal = try RecordingSessionFiles.decoder.decode(RecordingProcessingSession.Manifest.self,
            from: Data(contentsOf: session.journalURL))
        #expect(journal.id == session.id && journal.filename == candidate.filename)
        let saved = try #require(try await session.commit(recording: candidate, history: fixture.history))
        #expect(saved.filename == candidate.filename && saved.recordingDuration == 10)
    }

    @Test("All media deleted with or without the journal closes without inventing a Source")
    func deletedWorkingFilesAllowClose() async throws {
        for removeJournal in [false, true] {
            let fixture = try ProcessingSessionTestFixture()
            defer { fixture.remove() }
            let session = try await fixture.makeSession(processor: ProcessingSessionTestProcessor())
            let candidate = try await session.process(options: .defaults, progress: { _, _ in })
            let export = fixture.root.appendingPathComponent("shared.mp4")
            try Data("already shared".utf8).write(to: export)
            try FileManager.default.removeItem(at: session.originalURL)
            try FileManager.default.removeItem(at: candidate.sourceURL)
            if removeJournal { try FileManager.default.removeItem(at: session.journalURL) }
            #expect(try await session.commit(recording: candidate, history: fixture.history) == nil)
            #expect(try await fixture.history.item(id: session.id) == nil)
            #expect(try Data(contentsOf: export) == Data("already shared".utf8))
        }
    }

    @Test("Deletion during a failed worker still allows close when every managed video is gone")
    func deletedWhileProcessingAllowsClose() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let encoder = ProcessingSessionTestProcessor(blocked: [1])
        let session = try await fixture.makeSession(processor: encoder)
        let processing = Task { try await session.process(options: .defaults, progress: { _, _ in }) }
        try await waitUntil { await encoder.callCount == 1 }
        let closing = Task { try await session.commit(recording: nil, history: fixture.history) }
        try await waitUntil { session.isClosing }
        try FileManager.default.removeItem(at: session.originalURL)
        await encoder.release(1)
        _ = try? await processing.value
        #expect(try await closing.value == nil)
        #expect(try await fixture.history.item(id: session.id) == nil)
    }

    @Test("Failed requested generation cannot commit an older candidate, even with identical options")
    func failedRetryKeepsOriginalAndRejectsStaleCandidate() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let encoder = ProcessingSessionTestProcessor(failing: [2])
        let session = try await fixture.makeSession(processor: encoder)
        let first = try await session.process(options: .defaults, progress: { _, _ in })
        let originalBytes = try Data(contentsOf: session.originalURL)
        await #expect(throws: ProcessingSessionTestFailure.self) {
            try await session.process(options: .defaults, progress: { _, _ in })
        }
        await #expect(throws: ProcessingSessionFailure.self) {
            try await session.commit(recording: first, history: fixture.history)
        }
        #expect(try Data(contentsOf: session.originalURL) == originalBytes)
        #expect(FileManager.default.fileExists(atPath: first.sourceURL.path))
        #expect(try await fixture.history.item(id: session.id) == nil)
        let recovered = try RecordingProcessingSession.recover(directory: session.directory,
            directories: fixture.directories, processor: encoder)
        let retry = try await recovered.process(options: .defaults, progress: { _, _ in })
        #expect(try await recovered.commit(recording: retry, history: fixture.history) != nil)
    }

    @Test("Close owns the worker boundary and concurrent closes share one Source transaction")
    func concurrentCloseBlocksQueuedReprocessing() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let encoder = ProcessingSessionTestProcessor(blocked: [1])
        let session = try await fixture.makeSession(processor: encoder)
        let processing = Task { try await session.process(options: .defaults, progress: { _, _ in }) }
        try await waitUntil { await encoder.callCount == 1 }
        let queued = Task { try await session.process(options: .init(scale: .half), progress: { _, _ in }) }
        await Task.yield()
        let closeOne = Task { try await session.commit(recording: nil, history: fixture.history) }
        let closeTwo = Task { try await session.commit(recording: nil, history: fixture.history) }
        try await waitUntil { session.isClosing }
        await encoder.release(1)
        _ = try await processing.value
        let one = try #require(try await closeOne.value)
        let two = try #require(try await closeTwo.value)
        #expect(one.id == two.id)
        #expect(await encoder.callCount == 1)
        await #expect(throws: ProcessingSessionFailure.self) { try await queued.value }
        #expect(try await fixture.history.load().items.count == 1)
    }

    @Test("Late encoder progress cannot put a ready preview back into processing")
    func lateProgressIsIgnored() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let encoder = ProcessingSessionTestProcessor()
        let session = try await fixture.makeSession(processor: encoder)
        var events: [PreviewProcessingPhase] = []
        _ = try await session.process(options: .defaults, progress: { phase, _ in events.append(phase) })
        let before = events.count
        await encoder.emitLateProgress()
        await Task.yield()
        #expect(events.count == before)
        #expect(session.manifest.phase == .ready)
    }

    @Test("Cleanup retains uncertain symlinks and never follows them to a foreign file")
    func cleanupDoesNotRemoveUnverifiedSymlink() async throws {
        let fixture = try ProcessingSessionTestFixture()
        defer { fixture.remove() }
        let session = try await fixture.makeSession(processor: ProcessingSessionTestProcessor())
        let candidate = try await session.process(options: .defaults, progress: { _, _ in })
        _ = try await session.process(options: .init(scale: .half), progress: { _, _ in })
        let foreign = fixture.root.appendingPathComponent("foreign.mp4")
        try Data("foreign recording".utf8).write(to: foreign)
        try FileManager.default.removeItem(at: candidate.sourceURL)
        try FileManager.default.createSymbolicLink(at: candidate.sourceURL, withDestinationURL: foreign)
        await session.discard()
        #expect(try Data(contentsOf: foreign) == Data("foreign recording".utf8))
        #expect(RecordingSessionFiles.entryExists(candidate.sourceURL))
        #expect(FileManager.default.fileExists(atPath: session.journalURL.path))
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw ProcessingSessionTestFailure.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
struct ProcessingSessionTestFixture {
    let root: URL
    let directories: ApplicationDirectories
    let history: ManagedHistoryRepository
    let artifact: RecordingArtifact
    let settings: ClipSettings
    let captureBytes = Data("complete deterministic HEVC capture".utf8)
    var sessionDirectory: URL { directories.processing.appendingPathComponent(artifact.id.description) }

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ClipProcessingSessionTests-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        directories = ApplicationDirectories(applicationSupport: support,
            recordings: support.appendingPathComponent("Recordings", isDirectory: true),
            exports: caches.appendingPathComponent("Exports", isDirectory: true), caches: caches)
        try FileManager.default.createDirectory(at: directories.captureStaging, withIntermediateDirectories: true)
        history = try ManagedHistoryRepository(applicationSupportDirectory: support, recordingsDirectory: directories.recordings)
        settings = .defaults(homeDirectory: root)
        let id = RecordingID()
        artifact = RecordingArtifact(id: id, fileURL: directories.captureStaging.appendingPathComponent("\(id.description).mp4"),
            duration: 10, pixelSize: try .init(width: 1280, height: 720), frameRate: .thirty,
            audioConfiguration: .none, captureTarget: .fullscreen(try .init("session-test-display")))
        try captureBytes.write(to: artifact.fileURL)
    }

    func makeSession(processor: any RecordingSessionProcessing) async throws -> RecordingProcessingSession {
        try await .create(artifact: artifact, captureSettings: settings, directories: directories, processor: processor)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

enum ProcessingSessionTestFailure: Error { case encoder, timeout }

actor ProcessingSessionTestProcessor: RecordingSessionProcessing {
    private let blocked: Set<Int>
    private let failing: Set<Int>
    private var duration: TimeInterval
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var lastProgress: (@Sendable (RecordingProcessingProgress) -> Void)?
    private(set) var sources: [URL] = []
    var callCount: Int { sources.count }

    init(blocked: Set<Int> = [], failing: Set<Int> = [], duration: TimeInterval = 10) {
        self.blocked = blocked; self.failing = failing; self.duration = duration
    }

    func setDuration(_ value: TimeInterval) { duration = value }
    func release(_ index: Int) { gates.removeValue(forKey: index)?.resume() }
    func emitLateProgress() { lastProgress?(.init(phase: .validating, fraction: nil)) }

    func processRecording(sourceURL: URL, destinationURL: URL,
                          configuration: RecordingProcessingConfiguration,
                          progress: @escaping @Sendable (RecordingProcessingProgress) -> Void) async throws -> MediaInspection {
        sources.append(sourceURL)
        let index = sources.count
        lastProgress = progress
        if blocked.contains(index) { await withCheckedContinuation { gates[index] = $0 } }
        try Task.checkCancellation()
        if failing.contains(index) { throw ProcessingSessionTestFailure.encoder }
        progress(.init(phase: .encoding, fraction: 0.5))
        let original = try Data(contentsOf: sourceURL)
        var bytes = Data("full-duration h264 scale=\(configuration.scalePercent) crf=\(configuration.crf):".utf8)
        bytes.append(original)
        try bytes.write(to: destinationURL)
        let size = try configuration.dimensions(width: 1280, height: 720)
        return MediaInspection(duration: duration, fileSize: Int64(bytes.count), videoTrackCount: 1,
            audioTrackCount: 0, width: size.width, height: size.height,
            nominalFramesPerSecond: 30, videoCodec: kCMVideoCodecType_H264)
    }
}

private actor CancellationObservingSessionProcessor: RecordingSessionProcessing {
    private(set) var started = false
    private(set) var wasCancelled = false

    func processRecording(sourceURL: URL, destinationURL: URL,
                          configuration: RecordingProcessingConfiguration,
                          progress: @escaping @Sendable (RecordingProcessingProgress) -> Void) async throws -> MediaInspection {
        started = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { wasCancelled = Task.isCancelled; throw error }
        throw ProcessingSessionTestFailure.timeout
    }
}

/// Generated pixels exercise the actual production hardware writer without
/// Screen Recording permission, desktop capture, or user input.
enum ProcessingVideoFixture {
    static func writeHEVC(to output: URL) async throws {
        let writer = try AssetWriterSession(outputURL: output,
            configuration: .init(width: 1280, height: 720, targetAverageBitRate: 10_000_000))
        try writer.start()
        do {
            for frame in 0..<60 {
                let image = try pixelBuffer(frame: frame)
                var description: CMVideoFormatDescription?
                try #require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                    imageBuffer: image, formatDescriptionOut: &description) == noErr)
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                    presentationTimeStamp: CMTime(value: Int64(frame), timescale: 30), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                try #require(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                    imageBuffer: image, formatDescription: description!, sampleTiming: &timing,
                    sampleBufferOut: &sample) == noErr)
                try #require(try writer.append(try #require(sample), kind: .video))
            }
            // A fractional static tail catches full-range export rounding and
            // writer final-sample timing regressions beyond whole seconds.
            _ = try await writer.finish(at: CMTime(value: 122_220, timescale: 60_000))
        } catch { writer.cancelAndRemoveOutput(); throw error }
    }

    private static func pixelBuffer(frame: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        CVBufferSetAttachment(image, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(image), width: 1280, height: 720,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(image), space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        context.setFillColor(CGColor(gray: 0.14, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 240, height: 720))
        let font = CTFontCreateWithName("SFMono-Regular" as CFString, 18, nil)
        for row in 0..<18 {
            let text = row == 0 ? "Feature changes · crisp text" : "\(row). let recording = source.process(crf: 24)"
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 275, y: 660 - row * 32)
            CTLineDraw(line, context)
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 1, alpha: 1))
        context.fill(CGRect(x: 24, y: 24 + frame * 5, width: 192, height: 12))
        return image
    }
}
