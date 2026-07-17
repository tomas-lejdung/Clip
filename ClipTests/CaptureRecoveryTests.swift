import ClipCore
import ClipMedia
import Foundation
import Testing
@testable import Clip

@Suite("Interrupted capture recovery")
struct CaptureRecoveryTests {
    private func makeEnvironment(
        inspection: MediaInspection
    ) throws -> (root: URL, recordings: URL, repository: ManagedHistoryRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipRecoveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let recordings = support.appendingPathComponent("Recordings", isDirectory: true)
        let repository = try ManagedHistoryRepository(
            applicationSupportDirectory: support,
            recordingsDirectory: recordings,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            mediaInspector: { _ in inspection }
        )
        return (root, recordings, repository)
    }

    private func makeRecoveryRecord(
        id: RecordingID,
        settings: ClipSettings,
        createdAt: Date
    ) throws -> CaptureRecoveryRecord {
        let displayID = try DisplayID("recovery-display")
        let selection = CaptureSelection(
            displayID: displayID,
            normalizedRect: try NormalizedRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        )
        return CaptureRecoveryRecord(
            recordingID: id,
            createdAt: createdAt,
            captureTarget: .region(selection),
            settings: settings
        )
    }

    @Test("A playable Clip-owned interrupted MP4 is adopted with its exact session metadata")
    func recoversPlayableInterruptedCapture() async throws {
        let inspection = MediaInspection(
            duration: 4.25,
            fileSize: 12,
            videoTrackCount: 1,
            audioTrackCount: 2,
            width: 1280,
            height: 720,
            nominalFramesPerSecond: 59.94,
            videoCodec: nil
        )
        let environment = try makeEnvironment(inspection: inspection)
        defer { try? FileManager.default.removeItem(at: environment.root) }

        let id = RecordingID(
            UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        )
        let videoURL = environment.recordings
            .appendingPathComponent(id.description)
            .appendingPathExtension("mp4")
        try Data("playable-mp4".utf8).write(to: videoURL)

        var settings = ClipSettings.defaults(homeDirectory: environment.root)
        settings.frameRate = .sixty
        settings.audio = .microphoneAndSystemAudio
        settings.countdown = .fiveSeconds
        settings.showCursor = false
        settings.exportConfiguration = .crisp
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let recoveryRecord = try makeRecoveryRecord(
            id: id,
            settings: settings,
            createdAt: createdAt
        )
        let recoveryURL = CaptureRecoveryRecord.url(
            for: id,
            in: environment.recordings
        )
        try recoveryRecord.encoded().write(to: recoveryURL)

        let report = try await environment.repository.recoverInterruptedRecordings()
        let recovered = try #require(report.recovered.first)
        #expect(report.recovered.count == 1)
        #expect(report.retainedFailures.isEmpty)
        #expect(recovered.item.id == id)
        #expect(recovered.item.createdAt == createdAt)
        #expect(recovered.item.recordingDuration == inspection.duration)
        #expect(recovered.item.pixelSize == (try PixelSize(width: 1280, height: 720)))
        #expect(recovered.item.frameRate == .sixty)
        #expect(recovered.item.audioConfiguration == .microphoneAndSystemAudio)
        #expect(recovered.item.exportConfiguration == .crisp)
        #expect(recovered.settings == settings)
        #expect(!FileManager.default.fileExists(atPath: recoveryURL.path))
        #expect(FileManager.default.fileExists(atPath: videoURL.path))
        #expect(try await environment.repository.item(id: id) == recovered.item)
    }

    @Test("Invalid and unproven files are retained without entering History")
    func retainsFilesThatCannotBeSafelyRecovered() async throws {
        let inspection = MediaInspection(
            duration: 0,
            fileSize: 7,
            videoTrackCount: 0,
            audioTrackCount: 0,
            width: 0,
            height: 0,
            nominalFramesPerSecond: 0,
            videoCodec: nil
        )
        let environment = try makeEnvironment(inspection: inspection)
        defer { try? FileManager.default.removeItem(at: environment.root) }

        let invalidID = RecordingID(
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        let invalidURL = environment.recordings
            .appendingPathComponent(invalidID.description)
            .appendingPathExtension("mp4")
        try Data("partial".utf8).write(to: invalidURL)
        let settings = ClipSettings.defaults(homeDirectory: environment.root)
        let recoveryRecord = try makeRecoveryRecord(
            id: invalidID,
            settings: settings,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let recoveryURL = CaptureRecoveryRecord.url(
            for: invalidID,
            in: environment.recordings
        )
        try recoveryRecord.encoded().write(to: recoveryURL)

        let unprovenID = RecordingID(
            UUID(uuidString: "ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb")!
        )
        let unprovenURL = environment.recordings
            .appendingPathComponent(unprovenID.description)
            .appendingPathExtension("mp4")
        try Data("external".utf8).write(to: unprovenURL)

        let report = try await environment.repository.recoverInterruptedRecordings()
        #expect(report.recovered.isEmpty)
        #expect(report.retainedFailures.map(\.fileURL) == [invalidURL])
        #expect(FileManager.default.fileExists(atPath: invalidURL.path))
        #expect(FileManager.default.fileExists(atPath: recoveryURL.path))
        #expect(FileManager.default.fileExists(atPath: unprovenURL.path))
        #expect(try await environment.repository.item(id: invalidID) == nil)
        #expect(try await environment.repository.item(id: unprovenID) == nil)
    }

    @Test("A marker written before an interrupted index commit does not hide a playable capture")
    func recoversOwnedCaptureAfterMarkerBeforeIndexCrash() async throws {
        let inspection = MediaInspection(
            duration: 2.5,
            fileSize: 12,
            videoTrackCount: 1,
            audioTrackCount: 0,
            width: 960,
            height: 540,
            nominalFramesPerSecond: 30,
            videoCodec: nil
        )
        let environment = try makeEnvironment(inspection: inspection)
        defer { try? FileManager.default.removeItem(at: environment.root) }

        let id = RecordingID(
            UUID(uuidString: "abababab-cdcd-efef-1212-343434343434")!
        )
        let videoURL = environment.recordings
            .appendingPathComponent(id.description)
            .appendingPathExtension("mp4")
        try Data("playable-owned-mp4".utf8).write(to: videoURL)
        let markerURL = environment.recordings.appendingPathComponent(
            ".\(videoURL.lastPathComponent).clip-managed"
        )
        try ManagedHistoryRepository.ownershipMarkerContents.write(to: markerURL)

        let settings = ClipSettings.defaults(homeDirectory: environment.root)
        let createdAt = Date(timeIntervalSince1970: 1_800_100_000)
        let recoveryRecord = try makeRecoveryRecord(
            id: id,
            settings: settings,
            createdAt: createdAt
        )
        let recoveryURL = CaptureRecoveryRecord.url(
            for: id,
            in: environment.recordings
        )
        try recoveryRecord.encoded().write(to: recoveryURL)

        let report = try await environment.repository.recoverInterruptedRecordings()
        let recovered = try #require(report.recovered.first)
        #expect(report.recovered.count == 1)
        #expect(report.retainedFailures.isEmpty)
        #expect(recovered.item.id == id)
        #expect(recovered.item.createdAt == createdAt)
        #expect(FileManager.default.fileExists(atPath: videoURL.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(!FileManager.default.fileExists(atPath: recoveryURL.path))
        #expect(try await environment.repository.item(id: id) == recovered.item)
    }
}
