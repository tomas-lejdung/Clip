import Foundation
import Testing
@testable import ClipCore

private actor MemoryAtomicFileSystem: AtomicFileSystem {
    private var files: [URL: Data] = [:]
    private(set) var writeCount = 0

    func dataIfPresent(at url: URL) async throws -> Data? {
        files[url]
    }

    func writeAtomically(_ data: Data, to url: URL) async throws {
        files[url] = data
        writeCount += 1
    }

    func seed(_ data: Data, at url: URL) {
        files[url] = data
    }

    func storedData(at url: URL) -> Data? {
        files[url]
    }
}

@Suite("History metadata and retention")
struct HistoryMetadataTests {
    @Test("Managed paths stay relative, nested, and MP4-only")
    func managedPathValidation() throws {
        let file = try ManagedRecordingFile(relativePath: "recordings/2026/clip.mp4")
        let root = URL(fileURLWithPath: "/Application Support/Clip", isDirectory: true)
        #expect(file.resolved(inside: root).path == "/Application Support/Clip/recordings/2026/clip.mp4")

        #expect(throws: HistoryMetadataError.invalidManagedRelativePath("/tmp/clip.mp4")) {
            try ManagedRecordingFile(relativePath: "/tmp/clip.mp4")
        }
        #expect(throws: HistoryMetadataError.invalidManagedRelativePath("recordings/../clip.mp4")) {
            try ManagedRecordingFile(relativePath: "recordings/../clip.mp4")
        }
        #expect(throws: HistoryMetadataError.invalidManagedRelativePath("recordings//clip.mp4")) {
            try ManagedRecordingFile(relativePath: "recordings//clip.mp4")
        }
        #expect(throws: HistoryMetadataError.managedFileMustBeMP4("recordings/clip.mov")) {
            try ManagedRecordingFile(relativePath: "recordings/clip.mov")
        }
    }

    @Test("Trim ranges are non-empty and constrained to recording duration")
    func trimValidation() throws {
        let trim = try TrimRange(startTime: 1.5, endTime: 8)
        #expect(trim.duration == 6.5)
        try trim.validate(recordingDuration: 10)
        #expect(throws: HistoryMetadataError.trimExceedsRecordingDuration(end: 8, duration: 7)) {
            try trim.validate(recordingDuration: 7)
        }
        #expect(throws: HistoryMetadataError.invalidTrimRange(start: 2, end: 2)) {
            try TrimRange(startTime: 2, endTime: 2)
        }
        #expect(throws: HistoryMetadataError.invalidDuration(0)) {
            try TrimRange.full(recordingDuration: 0)
        }
    }

    @Test("History edits and successful exports preserve the complete Source")
    func historyMutations() throws {
        var item = try makeHistoryItem()
        let original = item
        try item.rename(to: "dashboard-filters.mp4", at: Date(timeIntervalSince1970: 1_001))
        let trim = try TrimRange(startTime: 2, endTime: 9)
        try item.setTrimRange(trim, at: Date(timeIntervalSince1970: 1_002))
        try item.setExportAudioPreference(.removeAudio, at: Date(timeIntervalSince1970: 1_003))
        try item.registerSuccessfulExport(at: Date(timeIntervalSince1970: 1_004))
        #expect(item.filename.fileName == "dashboard-filters.mp4")
        #expect(item.trimRange == trim && item.exportAudioPreference == .removeAudio)
        #expect(item.lastExportedAt == Date(timeIntervalSince1970: 1_004))
        #expect(item.managedMaster == original.managedMaster)
        #expect(item.recordingDuration == original.recordingDuration)
        #expect(item.pixelSize == original.pixelSize && item.managedByteCount == original.managedByteCount)
        try item.setTrimRange(.full(recordingDuration: item.recordingDuration), at: Date(timeIntervalSince1970: 1_005))
        #expect(item.trimRange.duration == original.recordingDuration)
    }

    @Test("History mutations reject invalid clock and metadata values")
    func mutationFailures() throws {
        var item = try makeHistoryItem()
        #expect(throws: HistoryMetadataError.updatePredatesCreation) {
            try item.rename(to: "earlier", at: Date(timeIntervalSince1970: 999))
        }
        #expect(throws: HistoryMetadataError.trimExceedsRecordingDuration(end: 11, duration: 10)) {
            try item.setTrimRange(
                TrimRange(startTime: 1, endTime: 11),
                at: Date(timeIntervalSince1970: 1_001)
            )
        }
        #expect(throws: HistoryMetadataError.negativeByteCount(-1)) {
            try makeHistoryItem(byteCount: -1)
        }
    }

    @Test("History items validate persisted metadata on round trip")
    func itemRoundTrip() throws {
        let snapshot = CaptureSessionSnapshot(
            frameRate: .sixty,
            showCursor: false,
            showClickHighlights: true,
            audio: .microphoneAndSystemAudio,
            countdown: .fiveSeconds,
            captureBitrateMbps: 20
        )
        var item = try makeHistoryItem(captureSessionSnapshot: snapshot)
        try item.setTrimRange(
            TrimRange(startTime: 1, endTime: 9),
            at: Date(timeIntervalSince1970: 1_001)
        )
        try item.setExportAudioPreference(
            .removeAudio,
            at: Date(timeIntervalSince1970: 1_002)
        )
        #expect(try jsonRoundTrip(item) == item)
        #expect(try jsonRoundTrip(item).exportAudioPreference == .removeAudio)
        #expect(try jsonRoundTrip(item).captureSessionSnapshot?.captureBitrateMbps == 20)
    }

    @Test("Capture session snapshots restore only capture inputs")
    func captureSessionSnapshotApplication() throws {
        var current = ClipSettings.defaults(
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )
        current.showInDock = true
        current.historyRetention = .thirtyDays
        current.recordingProcessing = .init(scale: .half, crf: 28, captureBitrateMbps: 50)
        let snapshot = CaptureSessionSnapshot(
            frameRate: .sixty,
            showCursor: false,
            showClickHighlights: true,
            audio: .microphoneAndSystemAudio,
            countdown: .fiveSeconds,
            captureBitrateMbps: 20
        )

        let restored = snapshot.applying(to: current)

        #expect(restored.frameRate == .sixty)
        #expect(restored.showCursor == false)
        #expect(restored.showClickHighlights)
        #expect(restored.audio == .microphoneAndSystemAudio)
        #expect(restored.countdown == .fiveSeconds)
        #expect(restored.showInDock == current.showInDock)
        #expect(restored.historyRetention == current.historyRetention)
        #expect(restored.recordingProcessing.scale == .half)
        #expect(restored.recordingProcessing.crf == 28)
        #expect(restored.recordingProcessing.captureBitrateMbps == 20)
        #expect(try jsonRoundTrip(snapshot) == snapshot)
    }

    @Test("History items decode when older metadata omits capture session snapshot")
    func legacyItemWithoutCaptureSessionSnapshot() throws {
        let snapshot = CaptureSessionSnapshot(
            frameRate: .sixty,
            showCursor: false,
            audio: .systemAudioOnly,
            countdown: .oneSecond
        )
        let item = try makeHistoryItem(captureSessionSnapshot: snapshot)
        let encoded = try JSONEncoder().encode(item)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "captureSessionSnapshot")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RecordingHistoryItem.self, from: legacyData)

        #expect(decoded.id == item.id)
        #expect(decoded.captureSessionSnapshot == nil)
        #expect(decoded.frameRate == item.frameRate)
        #expect(decoded.audioConfiguration == item.audioConfiguration)
        #expect(decoded.captureTarget == item.captureTarget)
    }

    @Test("Older history items migrate to keeping audio when the export choice is absent")
    func legacyItemWithoutAudioExportPreference() throws {
        var item = try makeHistoryItem()
        try item.setExportAudioPreference(
            .removeAudio,
            at: Date(timeIntervalSince1970: 1_001)
        )
        let encoded = try JSONEncoder().encode(item)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "exportAudioPreference")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RecordingHistoryItem.self, from: legacyData)

        #expect(decoded.exportAudioPreference == .keepAudio)
        #expect(decoded.audioConfiguration == item.audioConfiguration)
        #expect(ExportAudioPreference.keepAudio.includesAudio)
        #expect(!ExportAudioPreference.removeAudio.includesAudio)
    }

    @Test("Timed retention expires at exact age boundaries")
    func retentionBoundaries() {
        let created = Date(timeIntervalSince1970: 100)
        #expect(!HistoryRetentionPolicy.oneDay.shouldExpire(
            createdAt: created,
            now: created.addingTimeInterval(86_399.999)
        ))
        #expect(HistoryRetentionPolicy.oneDay.shouldExpire(
            createdAt: created,
            now: created.addingTimeInterval(86_400)
        ))
        #expect(!HistoryRetentionPolicy.indefinitely.shouldExpire(
            createdAt: created,
            now: .distantFuture
        ))
    }

    @Test("Legacy export-removal retention migrates to timed retention")
    func legacyExportRetentionMigration() throws {
        let decoded = try JSONDecoder().decode(HistoryRetentionPolicy.self, from: Data("\"doNotRetainAfterExport\"".utf8))
        #expect(decoded == .sevenDays)
    }

    @Test("Legacy source quality metadata never becomes a guessed CRF")
    func legacySourceMetadataMigration() throws {
        let item = try makeHistoryItem()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object.removeValue(forKey: "processing")
        object["managedMasterVideoQualityPercent"] = 98
        object["exportConfiguration"] = ["preset": "crisp"]
        let decoded = try JSONDecoder().decode(RecordingHistoryItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.processing == nil)
        #expect(decoded.managedMaster == item.managedMaster && decoded.recordingDuration == item.recordingDuration)
    }

    @Test("Cleanup plans include only expired managed items and exact reclaimed bytes")
    func cleanupPlan() throws {
        let old = try makeHistoryItem(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            createdAt: Date(timeIntervalSince1970: 0),
            byteCount: 100
        )
        let recent = try makeHistoryItem(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            createdAt: Date(timeIntervalSince1970: 7 * 86_400),
            byteCount: 200,
            path: "recordings/22222222-2222-2222-2222-222222222222.mp4"
        )
        let plan = HistoryCleanupPlanner.plan(
            items: [old, recent],
            policy: .sevenDays,
            now: Date(timeIntervalSince1970: 7 * 86_400)
        )
        #expect(plan.recordingIDs == [old.id])
        #expect(plan.reclaimableByteCount == 100)

        var index = try RecordingHistoryIndex(items: [old, recent])
        index.applyCleanupPlan(plan)
        #expect(index.items.map(\.id) == [recent.id])
    }

    @Test("History index sorts newest first and supports upsert and remove")
    func historyIndexOperations() throws {
        let older = try makeHistoryItem(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            createdAt: Date(timeIntervalSince1970: 1_000),
            byteCount: 100
        )
        var newer = try makeHistoryItem(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            createdAt: Date(timeIntervalSince1970: 2_000),
            byteCount: 200,
            path: "recordings/22222222-2222-2222-2222-222222222222.mp4"
        )
        var index = try RecordingHistoryIndex(items: [older, newer])
        #expect(index.items.map(\.id) == [newer.id, older.id])
        #expect(index.totalManagedByteCount == 300)

        try newer.rename(to: "renamed", at: Date(timeIntervalSince1970: 2_001))
        index.upsert(newer)
        #expect(index.item(id: newer.id)?.filename.fileName == "renamed.mp4")
        #expect(index.remove(id: older.id) == older)
        #expect(index.remove(id: older.id) == nil)
    }

    @Test("History index rejects duplicate IDs and saturates byte totals")
    func duplicateAndOverflow() throws {
        let first = try makeHistoryItem(byteCount: .max)
        let second = try makeHistoryItem(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            byteCount: 1,
            path: "recordings/22222222-2222-2222-2222-222222222222.mp4"
        )
        #expect(try RecordingHistoryIndex(items: [first, second]).totalManagedByteCount == .max)
        #expect(throws: HistoryMetadataError.duplicateRecordingID(first.id)) {
            try RecordingHistoryIndex(items: [first, first])
        }
    }

    @Test("History index is Codable with stable item identity")
    func indexRoundTrip() throws {
        let index = try RecordingHistoryIndex(items: [makeHistoryItem()])
        #expect(try jsonRoundTrip(index) == index)
    }
}

@Suite("Atomic JSON file store")
struct AtomicJSONStoreTests {
    @Test("Missing stores return nil or an injected default")
    func missingStore() async throws {
        let fileSystem = MemoryAtomicFileSystem()
        let url = URL(fileURLWithPath: "/virtual/settings.json")
        let store = try AtomicJSONFileStore<ClipSettings>(
            fileURL: url,
            fileSystem: fileSystem
        )
        #expect(try await store.load() == nil)

        let fallback = ClipSettings.defaults(
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )
        #expect(try await store.load(or: fallback) == fallback)
    }

    @Test("Save and load round-trip through an injected atomic filesystem")
    func inMemoryRoundTrip() async throws {
        let fileSystem = MemoryAtomicFileSystem()
        let url = URL(fileURLWithPath: "/virtual/history.json")
        let store = try RecordingHistoryJSONStore(fileURL: url, fileSystem: fileSystem)
        let index = try RecordingHistoryIndex(items: [makeHistoryItem()])

        try await store.save(index)
        #expect(await fileSystem.writeCount == 1)
        #expect(await fileSystem.storedData(at: url) != nil)
        #expect(try await store.load() == index)
    }

    @Test("Corrupt persisted JSON produces a decoding failure")
    func corruptJSON() async throws {
        let fileSystem = MemoryAtomicFileSystem()
        let url = URL(fileURLWithPath: "/virtual/history.json")
        await fileSystem.seed(Data("not-json".utf8), at: url)
        let store = try RecordingHistoryJSONStore(fileURL: url, fileSystem: fileSystem)

        await #expect(throws: DecodingError.self) {
            try await store.load()
        }
    }

    @Test("Store destinations must be local file URLs")
    func fileURLValidation() throws {
        let url = try #require(URL(string: "https://example.com/settings.json"))
        #expect(throws: AtomicJSONFileStoreError.destinationMustBeFileURL) {
            try SettingsJSONStore(fileURL: url)
        }
    }

    @Test("Local filesystem creates parents and atomically replaces JSON")
    func localFilesystemIntegration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ClipCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "nested/settings.json")
        let store = try SettingsJSONStore(fileURL: url)
        var settings = ClipSettings.defaults(
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        try await store.save(settings)
        settings.showInDock = true
        try await store.save(settings)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try await store.load() == settings)
    }
}
