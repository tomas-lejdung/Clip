import ClipCore
import Foundation
import Testing
@testable import Clip

@Suite("Managed recording history repository")
struct ManagedHistoryRepositoryTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let fixedToken = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    private func makeEnvironment() throws -> (
        root: URL,
        support: URL,
        recordings: URL,
        external: URL,
        repository: ManagedHistoryRepository
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipManagedHistoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let recordings = support.appendingPathComponent("Recordings", isDirectory: true)
        let external = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let now = fixedNow
        let token = fixedToken
        let repository = try ManagedHistoryRepository(
            applicationSupportDirectory: support,
            recordingsDirectory: recordings,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: { now },
            tokenGenerator: { token }
        )
        return (root, support, recordings, external, repository)
    }

    private func makeRequest(
        sourceURL: URL,
        id: UUID,
        createdAt: Date? = nil,
        duration: TimeInterval = 10,
        captureSessionSnapshot: CaptureSessionSnapshot? = nil,
        filenameTemplate: RecordingFilenameTemplate = .default
    ) throws -> FinalizedRecordingImport {
        let displayID = try DisplayID("display-1")
        return FinalizedRecordingImport(
            id: RecordingID(id),
            sourceURL: sourceURL,
            createdAt: createdAt,
            filenameTemplate: filenameTemplate,
            duration: duration,
            pixelSize: try PixelSize(width: 1440, height: 900),
            frameRate: .thirty,
            audioConfiguration: .none,
            captureTarget: .region(
                CaptureSelection(
                    displayID: displayID,
                    normalizedRect: try NormalizedRect(
                        x: 0.1,
                        y: 0.1,
                        width: 0.8,
                        height: 0.8
                    )
                )
            ),
            captureSessionSnapshot: captureSessionSnapshot
        )
    }

    @Test("Import applies the configured filename format with the repository time zone")
    func configuredFilenameTemplate() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = environment.external.appendingPathComponent("capture.mp4")
        try writeMP4("video", to: source)
        let template = try RecordingFilenameTemplate(
            validating: "meeting-DD-MM-YYYY_HH.mm.ss.mp4"
        )

        let item = try await environment.repository.importFinalizedRecording(
            makeRequest(
                sourceURL: source,
                id: UUID(uuidString: "10101010-1010-1010-1010-101010101010")!,
                filenameTemplate: template
            )
        )

        #expect(item.filename.fileName == "meeting-15-01-2027_08.00.00.mp4")
    }

    private func writeMP4(_ bytes: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(bytes.utf8).write(to: url)
    }

    private func overwriteIndex(_ index: RecordingHistoryIndex, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(index).write(to: url, options: .atomic)
    }

    @Test("Import copies a finalized MP4, leaves its source, and persists versioned metadata")
    func importAndReload() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let source = environment.external.appendingPathComponent("capture.mp4")
        try writeMP4("managed-video", to: source)
        let snapshot = CaptureSessionSnapshot(
            frameRate: .sixty,
            showCursor: false,
            audio: .microphoneAndSystemAudio,
            countdown: .fiveSeconds
        )

        let item = try await environment.repository.importFinalizedRecording(
            makeRequest(
                sourceURL: source,
                id: id,
                captureSessionSnapshot: snapshot
            )
        )
        let masterURL = try await environment.repository.masterURL(for: item.id)
        #expect(masterURL.deletingLastPathComponent() == environment.recordings)
        #expect(try Data(contentsOf: masterURL) == Data("managed-video".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(item.filename == RecordingFilename.timestamped(
            at: fixedNow,
            timeZone: TimeZone(secondsFromGMT: 0)!
        ))
        #expect(item.captureSessionSnapshot == snapshot)
        #expect(FileManager.default.fileExists(atPath: environment.repository.indexURL.path))

        let reloaded = try ManagedHistoryRepository(
            applicationSupportDirectory: environment.support,
            recordingsDirectory: environment.recordings
        )
        #expect(try await reloaded.load().item(id: item.id) == item)
    }

    @Test("Rename, trim, preset, and audio export mutations are durable")
    func metadataMutations() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let source = environment.external.appendingPathComponent("capture.mp4")
        try writeMP4("video", to: source)
        let imported = try await environment.repository.importFinalizedRecording(
            makeRequest(sourceURL: source, id: id)
        )

        _ = try await environment.repository.rename(id: imported.id, to: "dashboard-filters.mp4")
        let trim = try TrimRange(startTime: 1, endTime: 8)
        _ = try await environment.repository.updateTrim(id: imported.id, trimRange: trim)
        _ = try await environment.repository.updateExportConfiguration(
            id: imported.id,
            configuration: .crisp
        )
        _ = try await environment.repository.updateExportAudioPreference(
            id: imported.id,
            preference: .removeAudio
        )

        let reloaded = try await environment.repository.reloadFromDisk()
        let item = try #require(reloaded.item(id: imported.id))
        #expect(item.filename.fileName == "dashboard-filters.mp4")
        #expect(item.trimRange == trim)
        #expect(item.exportConfiguration == .crisp)
        #expect(item.exportAudioPreference == .removeAudio)
    }

    @Test("Preview audio removal persists across close and repository relaunch without changing the master")
    func previewAudioPreferenceSurvivesReopenAndRelaunch() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = environment.external.appendingPathComponent("capture-with-audio.mp4")
        try writeMP4("managed-master-with-audio", to: source)
        let imported = try await environment.repository.importFinalizedRecording(
            makeRequest(
                sourceURL: source,
                id: UUID(uuidString: "23232323-2323-2323-2323-232323232323")!
            )
        )
        let masterURL = try await environment.repository.masterURL(for: imported.id)
        let masterBytes = try Data(contentsOf: masterURL)
        let session = try await environment.repository.beginPreviewSession(id: imported.id)

        _ = try await environment.repository.updatePreviewMetadata(
            session: session,
            filename: imported.filename,
            trimRange: imported.trimRange,
            configuration: imported.exportConfiguration,
            audioPreference: .removeAudio
        )
        _ = try await environment.repository.endPreviewSession(session)

        let relaunched = try ManagedHistoryRepository(
            applicationSupportDirectory: environment.support,
            recordingsDirectory: environment.recordings
        )
        let restored = try #require(try await relaunched.item(id: imported.id))
        #expect(restored.exportAudioPreference == .removeAudio)
        #expect(restored.audioConfiguration == imported.audioConfiguration)
        #expect(try Data(contentsOf: masterURL) == masterBytes)
    }

    @Test("Delete removes only the managed copy, never the import source")
    func deletionOwnership() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let source = environment.external.appendingPathComponent("capture.mp4")
        try writeMP4("video", to: source)
        let item = try await environment.repository.importFinalizedRecording(
            makeRequest(sourceURL: source, id: id)
        )
        let master = try await environment.repository.masterURL(for: item.id)

        let result = try await environment.repository.delete(id: item.id)
        #expect(result.removedItem == item)
        #expect(result.cleanupFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: master.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try await environment.repository.item(id: item.id) == nil)
    }

    @Test("Seven-day retention removes expired managed masters only")
    func retentionCleanup() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let oldSource = environment.external.appendingPathComponent("old.mp4")
        let recentSource = environment.external.appendingPathComponent("recent.mp4")
        try writeMP4("old", to: oldSource)
        try writeMP4("recent", to: recentSource)
        let old = try await environment.repository.importFinalizedRecording(
            makeRequest(
                sourceURL: oldSource,
                id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                createdAt: fixedNow.addingTimeInterval(-8 * 86_400)
            )
        )
        let recent = try await environment.repository.importFinalizedRecording(
            makeRequest(
                sourceURL: recentSource,
                id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                createdAt: fixedNow.addingTimeInterval(-1 * 86_400)
            )
        )
        let oldMaster = try await environment.repository.masterURL(for: old.id)

        let result = try await environment.repository.applyRetentionCleanup(policy: .sevenDays)
        #expect(result.plan.recordingIDs == [old.id])
        #expect(result.cleanupFailures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: oldMaster.path))
        #expect(FileManager.default.fileExists(atPath: oldSource.path))
        #expect(try await environment.repository.item(id: recent.id) != nil)
    }

    @Test("Every post-export disposition preserves the external exported file")
    func exportDispositions() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let export = environment.external.appendingPathComponent("save-as.mp4")
        try writeMP4("exported", to: export)

        func imported(_ uuid: String, name: String) async throws -> RecordingHistoryItem {
            let source = environment.external.appendingPathComponent("\(name).mp4")
            try writeMP4(name, to: source)
            return try await environment.repository.importFinalizedRecording(
                makeRequest(sourceURL: source, id: UUID(uuidString: uuid)!)
            )
        }

        let kept = try await imported(
            "66666666-6666-6666-6666-666666666666",
            name: "kept"
        )
        let keptMaster = try await environment.repository.masterURL(for: kept.id)
        let keepResult = try await environment.repository.registerSuccessfulExport(
            id: kept.id,
            exportedFileURL: export,
            retentionPolicy: .sevenDays,
            keepOriginalAfterExport: true
        )
        #expect(keepResult.disposition == .keepOriginal)
        #expect(keepResult.retainedItem?.lastExportedAt == fixedNow)
        #expect(keepResult.removedItem == nil)
        #expect(FileManager.default.fileExists(atPath: keptMaster.path))

        let replaced = try await imported(
            "77777777-7777-7777-7777-777777777777",
            name: "replaced"
        )
        let oldMaster = try await environment.repository.masterURL(for: replaced.id)
        _ = try await environment.repository.updateTrim(
            id: replaced.id,
            trimRange: TrimRange(startTime: 2, endTime: 8)
        )
        let replacementMetadata = try RecordingMediaMetadata(
            duration: 6,
            pixelSize: PixelSize(width: 960, height: 540),
            frameRate: .sixty
        )
        let replaceResult = try await environment.repository.registerSuccessfulExport(
            id: replaced.id,
            exportedFileURL: export,
            retentionPolicy: .sevenDays,
            keepOriginalAfterExport: false,
            exportedVideoQualityPercent: 85,
            exportedMediaMetadata: replacementMetadata
        )
        let replacementURL = try await environment.repository.masterURL(for: replaced.id)
        #expect(replaceResult.disposition == .replaceOriginalWithExport)
        #expect(replacementURL == oldMaster)
        #expect(FileManager.default.fileExists(atPath: oldMaster.path))
        #expect(try Data(contentsOf: replacementURL) == Data("exported".utf8))
        #expect(replaceResult.retainedItem?.recordingDuration == 6)
        let expectedReplacementTrim = try TrimRange.full(recordingDuration: 6)
        #expect(replaceResult.retainedItem?.trimRange == expectedReplacementTrim)
        #expect(replaceResult.retainedItem?.pixelSize == replacementMetadata.pixelSize)
        #expect(replaceResult.retainedItem?.frameRate == .sixty)
        #expect(replaceResult.retainedItem?.managedMasterVideoQualityPercent == 85)
        #expect(replaceResult.retainedItem?.managedMaster == replaced.managedMaster)
        #expect(replaceResult.removedItem == nil)

        let removed = try await imported(
            "88888888-8888-8888-8888-888888888888",
            name: "removed"
        )
        let removedMaster = try await environment.repository.masterURL(for: removed.id)
        let removeResult = try await environment.repository.registerSuccessfulExport(
            id: removed.id,
            exportedFileURL: export,
            retentionPolicy: .doNotRetainAfterExport,
            keepOriginalAfterExport: true
        )
        #expect(removeResult.disposition == .removeHistoryItem)
        #expect(removeResult.retainedItem == nil)
        #expect(removeResult.removedItem?.id == removed.id)
        #expect(removeResult.removedItem?.lastExportedAt == fixedNow)
        #expect(!FileManager.default.fileExists(atPath: removedMaster.path))

        #expect(FileManager.default.fileExists(atPath: export.path))
        #expect(try Data(contentsOf: export) == Data("exported".utf8))
    }

    @Test("Replacing from the managed master itself is a safe metadata-only rebase")
    func replacementSourceEqualsDestination() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = environment.external.appendingPathComponent("same-source.mp4")
        try writeMP4("same-file", to: source)
        let item = try await environment.repository.importFinalizedRecording(
            makeRequest(
                sourceURL: source,
                id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
            )
        )
        let masterURL = try await environment.repository.masterURL(for: item.id)
        let metadata = try RecordingMediaMetadata(
            duration: 3.25,
            pixelSize: PixelSize(width: 640, height: 360),
            frameRate: .thirty
        )

        let result = try await environment.repository.registerSuccessfulExport(
            id: item.id,
            exportedFileURL: masterURL,
            retentionPolicy: .indefinitely,
            keepOriginalAfterExport: false,
            exportedVideoQualityPercent: 98,
            exportedMediaMetadata: metadata
        )

        #expect(try await environment.repository.masterURL(for: item.id) == masterURL)
        #expect(try Data(contentsOf: masterURL) == Data("same-file".utf8))
        #expect(result.disposition == .replaceOriginalWithExport)
        #expect(result.retainedItem?.recordingDuration == 3.25)
        let expectedTrim = try TrimRange.full(recordingDuration: 3.25)
        #expect(result.retainedItem?.trimRange == expectedTrim)
        #expect(result.cleanupFailure == nil)
    }

    @Test("Do-not-retain removes history immediately but pins the Preview master until close")
    func previewSessionDefersRemoval() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = environment.external.appendingPathComponent("preview-removal.mp4")
        let exported = environment.external.appendingPathComponent("shared.mp4")
        try writeMP4("preview-source", to: source)
        try writeMP4("shared-copy", to: exported)
        let item = try await environment.repository.importFinalizedRecording(
            makeRequest(
                sourceURL: source,
                id: UUID(uuidString: "10101010-1010-1010-1010-101010101010")!
            )
        )
        let masterURL = try await environment.repository.masterURL(for: item.id)
        let session = try await environment.repository.beginPreviewSession(id: item.id)

        let result = try await environment.repository.registerSuccessfulExport(
            id: item.id,
            exportedFileURL: exported,
            retentionPolicy: .doNotRetainAfterExport,
            keepOriginalAfterExport: true
        )

        #expect(result.finalizationDeferred)
        #expect(try await environment.repository.item(id: item.id) == nil)
        #expect(try Data(contentsOf: masterURL) == Data("preview-source".utf8))

        let closeResult = try await environment.repository.endPreviewSession(session)
        #expect(closeResult.finalizedDisposition == .removeHistoryItem)
        #expect(!FileManager.default.fileExists(atPath: masterURL.path))
        #expect(try Data(contentsOf: exported) == Data("shared-copy".utf8))
    }

    @Test("Retention cleanup skips a master while Preview has it pinned")
    func retentionCleanupSkipsPinnedPreview() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = environment.external.appendingPathComponent("pinned-expired.mp4")
        try writeMP4("preview-source", to: source)
        let item = try await environment.repository.importFinalizedRecording(
            makeRequest(
                sourceURL: source,
                id: UUID(uuidString: "40404040-4040-4040-4040-404040404040")!,
                createdAt: fixedNow.addingTimeInterval(-8 * 86_400)
            )
        )
        let masterURL = try await environment.repository.masterURL(for: item.id)
        let session = try await environment.repository.beginPreviewSession(id: item.id)

        let pinnedCleanup = try await environment.repository.applyRetentionCleanup(
            policy: .sevenDays
        )

        #expect(pinnedCleanup.plan.recordingIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: masterURL.path))
        _ = try await environment.repository.endPreviewSession(session)

        let laterCleanup = try await environment.repository.applyRetentionCleanup(
            policy: .sevenDays
        )
        #expect(laterCleanup.plan.recordingIDs == [item.id])
        #expect(!FileManager.default.fileExists(atPath: masterURL.path))
    }

    @Test("History deletion cannot invalidate a Preview opened by another UI surface")
    func externalDeletionDefersWhilePreviewIsPinned() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = environment.external.appendingPathComponent("preview-history-delete.mp4")
        try writeMP4("preview-source", to: source)
        let item = try await environment.repository.importFinalizedRecording(
            makeRequest(
                sourceURL: source,
                id: UUID(uuidString: "30303030-3030-3030-3030-303030303030")!
            )
        )
        let masterURL = try await environment.repository.masterURL(for: item.id)
        let session = try await environment.repository.beginPreviewSession(id: item.id)

        let deletion = try await environment.repository.delete(id: item.id)

        #expect(deletion.cleanupFailure == nil)
        #expect(try await environment.repository.item(id: item.id) == nil)
        #expect(FileManager.default.fileExists(atPath: masterURL.path))

        let closeResult = try await environment.repository.endPreviewSession(session)
        #expect(closeResult.finalizedDisposition == .removeHistoryItem)
        #expect(!FileManager.default.fileExists(atPath: masterURL.path))
    }

    @Test("Keep-original off installs only the latest successful export when Preview closes")
    func previewSessionDefersLatestReplacement() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = environment.external.appendingPathComponent("preview-original.mp4")
        let firstExport = environment.external.appendingPathComponent("first.mp4")
        let latestExport = environment.external.appendingPathComponent("latest.mp4")
        try writeMP4("original", to: source)
        try writeMP4("first-export", to: firstExport)
        try writeMP4("latest-export", to: latestExport)
        let item = try await environment.repository.importFinalizedRecording(
            makeRequest(
                sourceURL: source,
                id: UUID(uuidString: "20202020-2020-2020-2020-202020202020")!,
                duration: 10,
                captureSessionSnapshot: CaptureSessionSnapshot(
                    frameRate: .thirty,
                    showCursor: true,
                    audio: .none,
                    countdown: .threeSeconds,
                    crispQuality: 98
                )
            )
        )
        let masterURL = try await environment.repository.masterURL(for: item.id)
        let session = try await environment.repository.beginPreviewSession(id: item.id)
        let firstMetadata = try RecordingMediaMetadata(
            duration: 6,
            pixelSize: PixelSize(width: 960, height: 540),
            frameRate: .thirty
        )
        let latestMetadata = try RecordingMediaMetadata(
            duration: 4,
            pixelSize: PixelSize(width: 1280, height: 720),
            frameRate: .sixty
        )

        _ = try await environment.repository.registerSuccessfulExport(
            id: item.id,
            exportedFileURL: firstExport,
            retentionPolicy: .indefinitely,
            keepOriginalAfterExport: false,
            exportedVideoQualityPercent: 90,
            exportedMediaMetadata: firstMetadata,
            previewSession: session
        )
        let latestResult = try await environment.repository.registerSuccessfulExport(
            id: item.id,
            exportedFileURL: latestExport,
            retentionPolicy: .indefinitely,
            keepOriginalAfterExport: false,
            exportedVideoQualityPercent: 85,
            exportedMediaMetadata: latestMetadata,
            previewSession: session
        )

        #expect(latestResult.finalizationDeferred)
        #expect(try Data(contentsOf: masterURL) == Data("original".utf8))
        #expect(try await environment.repository.item(id: item.id)?.trimRange == item.trimRange)

        let closeResult = try await environment.repository.endPreviewSession(session)
        let rebasedItem = try #require(closeResult.retainedItem)
        #expect(try Data(contentsOf: masterURL) == Data("latest-export".utf8))
        #expect(rebasedItem.recordingDuration == latestMetadata.duration)
        #expect(rebasedItem.pixelSize == latestMetadata.pixelSize)
        #expect(rebasedItem.frameRate == latestMetadata.frameRate)
        #expect(rebasedItem.managedMasterVideoQualityPercent == 85)
        #expect(rebasedItem.captureSessionSnapshot?.crispQuality == 98)
        let expectedFullTrim = try TrimRange.full(recordingDuration: 4)
        #expect(rebasedItem.trimRange == expectedFullTrim)
        #expect(try Data(contentsOf: firstExport) == Data("first-export".utf8))
        #expect(try Data(contentsOf: latestExport) == Data("latest-export".utf8))
    }

    @Test("Reconciliation removes missing metadata and owned orphans but retains unknown MP4s")
    func reconciliationSafety() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }

        let orphanSource = environment.external.appendingPathComponent("orphan-source.mp4")
        try writeMP4("orphan", to: orphanSource)
        let orphan = try await environment.repository.importFinalizedRecording(
            makeRequest(
                sourceURL: orphanSource,
                id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
            )
        )
        let orphanMaster = try await environment.repository.masterURL(for: orphan.id)
        try overwriteIndex(RecordingHistoryIndex(), at: environment.repository.indexURL)

        let repository = try ManagedHistoryRepository(
            applicationSupportDirectory: environment.support,
            recordingsDirectory: environment.recordings,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let missingSource = environment.external.appendingPathComponent("missing-source.mp4")
        try writeMP4("missing", to: missingSource)
        let missing = try await repository.importFinalizedRecording(
            makeRequest(
                sourceURL: missingSource,
                id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
            )
        )
        let missingMaster = try await repository.masterURL(for: missing.id)
        try FileManager.default.removeItem(at: missingMaster)

        // UUID-like names alone do not establish ownership; this represents an external Save As.
        let unknown = environment.recordings.appendingPathComponent(
            "cccccccc-cccc-cccc-cccc-cccccccccccc.mp4"
        )
        try writeMP4("external-save-as", to: unknown)

        let usage = try await repository.storageUsage()
        #expect(usage.recognizedOrphanByteCount == Int64(Data("orphan".utf8).count))
        #expect(usage.untrackedMP4ByteCount == Int64(Data("external-save-as".utf8).count))

        let report = try await repository.reconcile()
        #expect(report.removedMissingItems == [missing.id])
        #expect(report.deletedOrphanFiles == [orphanMaster])
        #expect(report.retainedUnknownFiles == [unknown])
        #expect(report.cleanupFailures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: orphanMaster.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(FileManager.default.fileExists(atPath: orphanSource.path))
    }

    @Test("Future history schema versions fail closed")
    func futureSchema() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        try overwriteIndex(
            RecordingHistoryIndex(schemaVersion: 2),
            at: environment.repository.indexURL
        )

        await #expect(
            throws: ManagedHistoryRepositoryError.unsupportedHistorySchema(
                found: 2,
                expected: 1
            )
        ) {
            try await environment.repository.load()
        }
    }

    @Test("Stale managed transactions are bounded without deleting unknown or sole rollback files")
    func staleTransactionCleanupIsOwnershipAndRecoverySafe() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }

        let id = UUID(uuidString: "91919191-9191-9191-9191-919191919191")!
        let source = environment.external.appendingPathComponent("transaction-source.mp4")
        try writeMP4("current-master", to: source)
        let item = try await environment.repository.importFinalizedRecording(
            makeRequest(sourceURL: source, id: id)
        )
        let master = try await environment.repository.masterURL(for: item.id)

        let importing = environment.recordings.appendingPathComponent(
            ".\(master.lastPathComponent).11111111-1111-1111-1111-111111111111.importing"
        )
        let temporary = environment.recordings.appendingPathComponent(
            ".\(master.lastPathComponent).22222222-2222-2222-2222-222222222222.temporary"
        )
        let rollback = environment.recordings.appendingPathComponent(
            ".\(master.lastPathComponent).33333333-3333-3333-3333-333333333333.rollback"
        )
        let recent = environment.recordings.appendingPathComponent(
            ".\(master.lastPathComponent).44444444-4444-4444-4444-444444444444.importing"
        )
        let missingDestinationRollback = environment.recordings.appendingPathComponent(
            ".aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.mp4.55555555-5555-5555-5555-555555555555.rollback"
        )
        let unknown = environment.recordings.appendingPathComponent(
            ".notes.66666666-6666-6666-6666-666666666666.temporary"
        )
        for url in [
            importing,
            temporary,
            rollback,
            recent,
            missingDestinationRollback,
            unknown,
        ] {
            try Data("transaction-artifact".utf8).write(to: url)
        }

        let cutoff = Date(timeIntervalSince1970: 1_900_000_000)
        let staleDate = cutoff.addingTimeInterval(-1)
        for url in [importing, temporary, rollback, missingDestinationRollback, unknown] {
            try FileManager.default.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: url.path
            )
        }
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff],
            ofItemAtPath: recent.path
        )

        let report = try await environment.repository.removeStaleTransactionArtifacts(
            olderThan: cutoff
        )

        #expect(Set(report.deletedArtifacts) == Set([importing, temporary, rollback]))
        #expect(report.retainedRollbackArtifacts == [missingDestinationRollback])
        #expect(report.cleanupFailures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: master.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: missingDestinationRollback.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
    }
}

@Suite("Atomic independent file replacement")
struct AtomicFileReplacementTests {
    private let token = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipAtomicReplacementTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryArtifacts(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.hasSuffix(".temporary")
        }
    }

    @Test("A complete staged copy atomically replaces an existing user file")
    func replacesExistingDestination() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("managed-export.mp4")
        let destination = directory.appendingPathComponent("user-file.mp4")
        try Data("complete-export".utf8).write(to: source)
        try Data("previous-user-file".utf8).write(to: destination)

        try AtomicFileReplacement.replaceOrCreate(
            from: source,
            to: destination,
            tokenGenerator: { token }
        )

        #expect(try Data(contentsOf: source) == Data("complete-export".utf8))
        #expect(try Data(contentsOf: destination) == Data("complete-export".utf8))
        #expect(try temporaryArtifacts(in: directory).isEmpty)
    }

    @Test("A failed staging copy preserves the existing user file and cleans staging")
    func failedCopyPreservesDestination() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingSource = directory.appendingPathComponent("missing-export.mp4")
        let destination = directory.appendingPathComponent("user-file.mp4")
        try Data("irreplaceable-user-file".utf8).write(to: destination)

        #expect(throws: CocoaError.self) {
            try AtomicFileReplacement.replaceOrCreate(
                from: missingSource,
                to: destination,
                tokenGenerator: { token }
            )
        }

        #expect(try Data(contentsOf: destination) == Data("irreplaceable-user-file".utf8))
        #expect(try temporaryArtifacts(in: directory).isEmpty)
    }

    @Test("Using the destination as its own source is a non-destructive no-op")
    func sourceEqualsDestination() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("same.mp4")
        try Data("same-file".utf8).write(to: file)

        try AtomicFileReplacement.replaceOrCreate(
            from: file,
            to: file,
            tokenGenerator: { token }
        )

        #expect(try Data(contentsOf: file) == Data("same-file".utf8))
        #expect(try temporaryArtifacts(in: directory).isEmpty)
    }

    @Test("A preserved original is a complete rollback file beside the destination")
    func preservesRollbackCopy() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("managed-export.mp4")
        let destination = directory.appendingPathComponent("managed-master.mp4")
        let backup = directory.appendingPathComponent(".managed-master.mp4.rollback")
        try Data("new-master".utf8).write(to: source)
        try Data("old-master".utf8).write(to: destination)

        try AtomicFileReplacement.replaceOrCreate(
            from: source,
            to: destination,
            preservingOriginalAt: backup,
            tokenGenerator: { token }
        )

        #expect(try Data(contentsOf: destination) == Data("new-master".utf8))
        #expect(try Data(contentsOf: backup) == Data("old-master".utf8))
        #expect(try temporaryArtifacts(in: directory).isEmpty)
    }
}

@Suite("Sandbox-authorized Save As")
struct UserAuthorizedFileSaveTests {
    private let token = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!

    @Test("Only the panel-authorized destination is touched outside Clip's container")
    func stagesInsideManagedContainer() throws {
        let source = URL(fileURLWithPath: "/ClipContainer/Exports/managed.mp4")
        let destination = URL(fileURLWithPath: "/Users/test/Downloads/clip.mp4")
        let staging = source.deletingLastPathComponent().appendingPathComponent(
            ".clip-save-\(token.uuidString.lowercased()).temporary"
        )
        let fileSystem = RecordingUserAuthorizedSaveFileSystem(
            existingURLs: [source, destination]
        )

        try UserAuthorizedFileReplacement.replaceOrCreate(
            from: source,
            to: destination,
            fileSystem: fileSystem,
            tokenGenerator: { token }
        )

        #expect(
            fileSystem.operations == [
                .exists(staging),
                .copy(source, staging),
                .exists(destination),
                .replace(destination, staging),
                .remove(staging),
            ]
        )
        #expect(
            fileSystem.operations.allSatisfy { operation in
                operation.externalWriteURLs.allSatisfy { $0 == destination }
            }
        )
    }

    @Test("A failed new-file copy removes only its partial authorized destination")
    func failedNewDestinationCopyRemovesPartialFile() throws {
        let source = URL(fileURLWithPath: "/ClipContainer/Exports/managed.mp4")
        let destination = URL(fileURLWithPath: "/Users/test/Downloads/clip.mp4")
        let staging = source.deletingLastPathComponent().appendingPathComponent(
            ".clip-save-\(token.uuidString.lowercased()).temporary"
        )
        let fileSystem = RecordingUserAuthorizedSaveFileSystem(
            existingURLs: [source],
            partialCopyFailureDestination: destination
        )

        #expect(throws: CocoaError.self) {
            try UserAuthorizedFileReplacement.replaceOrCreate(
                from: source,
                to: destination,
                fileSystem: fileSystem,
                tokenGenerator: { token }
            )
        }

        #expect(
            fileSystem.operations == [
                .exists(staging),
                .copy(source, staging),
                .exists(destination),
                .copy(staging, destination),
                .remove(destination),
                .remove(staging),
            ]
        )
        #expect(!fileSystem.contains(destination))
        #expect(fileSystem.contains(source))
    }

    @MainActor
    @Test("Save Panel approval is security-scoped and publishes a complete external copy")
    func savePanelApprovalPublishesFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipAuthorizedSaveTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let managedDirectory = root.appendingPathComponent("Container/Exports", isDirectory: true)
        let downloadsDirectory = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(
            at: managedDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let source = managedDirectory.appendingPathComponent("managed.mp4")
        let destination = downloadsDirectory.appendingPathComponent("clip.mp4")
        try Data("complete-export".utf8).write(to: source)
        try Data("previous-file".utf8).write(to: destination)

        let chooser = FakeSaveDestinationChooser(destination: destination)
        let scope = FakeSecurityScopedResourceAccess()
        let service = UserAuthorizedFileSaveService(
            destinationChooser: chooser,
            securityScope: scope
        )

        let result = try await service.save(
            filename: "clip.mp4",
            initialDirectory: downloadsDirectory
        ) {
            source
        }

        #expect(result == destination)
        #expect(try Data(contentsOf: source) == Data("complete-export".utf8))
        #expect(try Data(contentsOf: destination) == Data("complete-export".utf8))
        #expect(
            chooser.requests == [
                SaveDestinationRequest(
                    filename: "clip.mp4",
                    initialDirectory: downloadsDirectory
                ),
            ]
        )
        #expect(scope.stoppedURLs == [destination])
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: downloadsDirectory.path)
                == ["clip.mp4"]
        )
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: managedDirectory.path)
                == ["managed.mp4"]
        )
    }

    @MainActor
    @Test("Canceling Save Panel does not export or touch a security scope")
    func canceledPanelHasNoSideEffects() async throws {
        let chooser = FakeSaveDestinationChooser(destination: nil)
        let scope = FakeSecurityScopedResourceAccess()
        let service = UserAuthorizedFileSaveService(
            destinationChooser: chooser,
            securityScope: scope
        )
        var didProduceExport = false

        let result = try await service.save(
            filename: "clip.mp4",
            initialDirectory: URL(fileURLWithPath: "/Users/test/Movies")
        ) {
            didProduceExport = true
            return URL(fileURLWithPath: "/unreachable.mp4")
        }

        #expect(result == nil)
        #expect(!didProduceExport)
        #expect(scope.stoppedURLs.isEmpty)
    }
}

private enum RecordedUserAuthorizedSaveOperation: Equatable {
    case exists(URL)
    case copy(URL, URL)
    case replace(URL, URL)
    case remove(URL)

    var externalWriteURLs: [URL] {
        let downloads = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)
        switch self {
        case .exists:
            return []
        case let .copy(_, destination), let .replace(destination, _):
            return destination.deletingLastPathComponent() == downloads ? [destination] : []
        case let .remove(url):
            return url.deletingLastPathComponent() == downloads ? [url] : []
        }
    }
}

private final class RecordingUserAuthorizedSaveFileSystem: UserAuthorizedSaveFileSystem {
    private var existingURLs: Set<URL>
    private let partialCopyFailureDestination: URL?
    private(set) var operations: [RecordedUserAuthorizedSaveOperation] = []

    init(
        existingURLs: Set<URL>,
        partialCopyFailureDestination: URL? = nil
    ) {
        self.existingURLs = existingURLs
        self.partialCopyFailureDestination = partialCopyFailureDestination
    }

    func contains(_ url: URL) -> Bool {
        existingURLs.contains(url)
    }

    func itemExists(at url: URL) -> Bool {
        operations.append(.exists(url))
        return existingURLs.contains(url)
    }

    func copyItem(from sourceURL: URL, to destinationURL: URL) throws {
        operations.append(.copy(sourceURL, destinationURL))
        existingURLs.insert(destinationURL)
        if destinationURL == partialCopyFailureDestination {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func replaceItem(at destinationURL: URL, with sourceURL: URL) throws {
        operations.append(.replace(destinationURL, sourceURL))
        existingURLs.remove(sourceURL)
        existingURLs.insert(destinationURL)
    }

    func removeItem(at url: URL) throws {
        operations.append(.remove(url))
        existingURLs.remove(url)
    }
}

@MainActor
private final class FakeSaveDestinationChooser: SaveDestinationChoosing {
    let destination: URL?
    private(set) var requests: [SaveDestinationRequest] = []

    init(destination: URL?) {
        self.destination = destination
    }

    func chooseDestination(for request: SaveDestinationRequest) async -> URL? {
        requests.append(request)
        return destination
    }
}

@MainActor
private final class FakeSecurityScopedResourceAccess: SecurityScopedResourceAccessing {
    private(set) var stoppedURLs: [URL] = []

    func stopAccessing(_ url: URL) {
        stoppedURLs.append(url)
    }
}
