import ClipCore
import Foundation

/// Durable session metadata written before ScreenCaptureKit starts.
///
/// AVAssetWriter may leave a playable MP4 behind if Clip or macOS terminates
/// after the writer has finalized but before History is updated. Keeping this
/// small sidecar next to the in-progress file lets startup recovery adopt only
/// files that Clip can positively identify as its own.
struct CaptureRecoveryRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let recordingID: RecordingID
    let createdAt: Date
    let captureTarget: ClipCore.CaptureTarget
    let settings: ClipSettings

    init(
        schemaVersion: Int = CaptureRecoveryRecord.currentSchemaVersion,
        recordingID: RecordingID,
        createdAt: Date,
        captureTarget: ClipCore.CaptureTarget,
        settings: ClipSettings
    ) {
        self.schemaVersion = schemaVersion
        self.recordingID = recordingID
        self.createdAt = createdAt
        self.captureTarget = captureTarget
        self.settings = settings
    }

    static func url(for recordingID: RecordingID, in directory: URL) -> URL {
        directory.appendingPathComponent(
            ".\(recordingID.description).clip-recovery.json"
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> CaptureRecoveryRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(CaptureRecoveryRecord.self, from: data)
    }
}
