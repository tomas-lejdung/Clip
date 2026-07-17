import ClipCore
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

enum PreviewRecordingError: LocalizedError, Equatable, Sendable {
    case invalidDuration(TimeInterval)
    case negativeEstimatedByteCount(Int64)

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            "The recording does not have a valid duration."
        case .negativeEstimatedByteCount:
            "The estimated file size is invalid."
        }
    }
}

/// The capture plan used by Retake. New history records retain the exact
/// capture-session inputs durably; older records preserve their historical
/// target/audio/frame rate and use current countdown/cursor preferences.
struct PreviewRetakePlan: Equatable, Sendable {
    let target: ClipCore.CaptureTarget
    let settings: ClipSettings
    let usesExactSessionSettings: Bool

    init(
        target: ClipCore.CaptureTarget,
        settings: ClipSettings,
        usesExactSessionSettings: Bool
    ) {
        self.target = target
        self.settings = settings
        self.usesExactSessionSettings = usesExactSessionSettings
    }

    init(
        historyItem: RecordingHistoryItem,
        currentSettings: ClipSettings,
        inMemorySessionSettings: ClipSettings? = nil
    ) {
        var legacyFallback = currentSettings
        legacyFallback.frameRate = historyItem.frameRate
        legacyFallback.audio = historyItem.audioConfiguration

        if let inMemorySessionSettings {
            self.init(
                target: historyItem.captureTarget,
                settings: inMemorySessionSettings,
                usesExactSessionSettings: true
            )
        } else if let snapshot = historyItem.captureSessionSnapshot {
            self.init(
                target: historyItem.captureTarget,
                settings: snapshot.applying(to: currentSettings),
                usesExactSessionSettings: true
            )
        } else {
            self.init(
                target: historyItem.captureTarget,
                settings: legacyFallback,
                usesExactSessionSettings: false
            )
        }
    }
}

/// An immutable snapshot of the recording presented by the preview window.
///
/// The managed source file remains owned by the history layer. Preview actions
/// receive snapshots and must never remove that source as a side effect.
struct PreviewRecording: Equatable, Sendable, Identifiable {
    let id: RecordingID
    let sourceURL: URL
    let duration: TimeInterval
    let pixelSize: PixelSize
    let frameRate: CaptureFrameRate
    let audioConfiguration: AudioConfiguration
    var filename: RecordingFilename
    var trimRange: TrimRange
    var exportConfiguration: ExportConfiguration
    var exportAudioPreference: ExportAudioPreference
    var approximateExportByteCount: Int64?
    let retakePlan: PreviewRetakePlan?

    init(
        id: RecordingID,
        sourceURL: URL,
        duration: TimeInterval,
        pixelSize: PixelSize,
        frameRate: CaptureFrameRate = .thirty,
        audioConfiguration: AudioConfiguration = .none,
        filename: RecordingFilename,
        trimRange: TrimRange,
        exportConfiguration: ExportConfiguration,
        exportAudioPreference: ExportAudioPreference = .keepAudio,
        approximateExportByteCount: Int64? = nil,
        retakePlan: PreviewRetakePlan? = nil
    ) throws {
        guard duration.isFinite, duration > 0 else {
            throw PreviewRecordingError.invalidDuration(duration)
        }
        try trimRange.validate(recordingDuration: duration)
        if let approximateExportByteCount, approximateExportByteCount < 0 {
            throw PreviewRecordingError.negativeEstimatedByteCount(approximateExportByteCount)
        }

        self.id = id
        self.sourceURL = sourceURL
        self.duration = duration
        self.pixelSize = pixelSize
        self.frameRate = frameRate
        self.audioConfiguration = audioConfiguration
        self.filename = filename
        self.trimRange = trimRange
        self.exportConfiguration = exportConfiguration
        self.exportAudioPreference = exportAudioPreference
        self.approximateExportByteCount = approximateExportByteCount
        self.retakePlan = retakePlan
    }

    var aspectRatio: CGFloat {
        CGFloat(pixelSize.width) / CGFloat(pixelSize.height)
    }
}

/// A complete, validated description of what the user currently sees in Preview.
/// Every share path uses this same request so trim, preset, and filename cannot drift.
struct PreviewExportRequest: Equatable, Sendable {
    let recordingID: RecordingID
    let sourceURL: URL
    /// The capture setting is the authoritative cadence ceiling. A screen
    /// recording can inspect as 28.29 FPS even though it was captured on a
    /// 30 FPS timeline; rounding that observation down would spuriously turn
    /// an unchanged Crisp export into a 28 FPS conversion.
    let captureFrameRate: CaptureFrameRate
    let filename: RecordingFilename
    let trimRange: TrimRange
    let configuration: ExportConfiguration
    let audioPreference: ExportAudioPreference

    init(
        recordingID: RecordingID,
        sourceURL: URL,
        captureFrameRate: CaptureFrameRate,
        filename: RecordingFilename,
        trimRange: TrimRange,
        configuration: ExportConfiguration,
        audioPreference: ExportAudioPreference
    ) {
        self.recordingID = recordingID
        self.sourceURL = sourceURL
        self.captureFrameRate = captureFrameRate
        self.filename = filename
        self.trimRange = trimRange
        self.configuration = configuration
        self.audioPreference = audioPreference
    }
}

struct PreviewShareOutcome: Sendable {
    let outputURL: URL
    let historyDisposition: HistoryPostExportDisposition
    let sourceFinalizationDeferred: Bool
    let shouldClosePreview: Bool
    /// A successful Copy, Save As, or drag must remain successful when only the
    /// subsequent History bookkeeping fails. This warning is shown inline so
    /// the user knows the shared file is usable and the managed original remains.
    let postShareWarning: String?

    init(
        outputURL: URL,
        historyDisposition: HistoryPostExportDisposition,
        sourceFinalizationDeferred: Bool,
        shouldClosePreview: Bool = false,
        postShareWarning: String? = nil
    ) {
        self.outputURL = outputURL
        self.historyDisposition = historyDisposition
        self.sourceFinalizationDeferred = sourceFinalizationDeferred
        self.shouldClosePreview = shouldClosePreview
        self.postShareWarning = postShareWarning
    }
}

/// Retake is a two-phase handoff: Preview installs the playable replacement
/// first, then commits ownership. A failed commit restores the old player and
/// lets the coordinator discard the uninstalled capture.
struct PreviewRetakeResult: Sendable {
    let recording: PreviewRecording
    let commitInstallation: @MainActor @Sendable () async throws -> Void
    let discardReplacement: @MainActor @Sendable () async -> Void
}

typealias PreviewExportAction = @Sendable (PreviewExportRequest) async throws -> PreviewShareOutcome
typealias PreviewCopyAction = @MainActor @Sendable (PreviewExportRequest) async throws -> PreviewShareOutcome
typealias PreviewSaveAction = @MainActor @Sendable (PreviewExportRequest) async throws -> PreviewShareOutcome?
typealias PreviewRetakeAction = @MainActor @Sendable (PreviewRecording) async throws -> PreviewRetakeResult?

/// Integration boundary between Preview and the export/history coordinators.
///
/// `export` must return a stable MP4 URL whose final path component matches the
/// request filename. `copy` returns the MP4 it placed on the pasteboard. `save`
/// returns nil when the save panel is cancelled. `retake` returns nil when the
/// replacement capture is cancelled and must leave the existing source untouched.
struct PreviewActions: Sendable {
    let export: PreviewExportAction
    let copy: PreviewCopyAction
    let save: PreviewSaveAction
    let retake: PreviewRetakeAction
    let done: @MainActor @Sendable (PreviewRecording) async throws -> Void
    let delete: @MainActor @Sendable (PreviewRecording) async throws -> Void
    let reveal: @MainActor @Sendable (URL) -> Void

    init(
        export: @escaping PreviewExportAction,
        copy: @escaping PreviewCopyAction,
        save: @escaping PreviewSaveAction,
        retake: @escaping PreviewRetakeAction,
        done: @escaping @MainActor @Sendable (PreviewRecording) async throws -> Void,
        delete: @escaping @MainActor @Sendable (PreviewRecording) async throws -> Void,
        reveal: @escaping @MainActor @Sendable (URL) -> Void = { _ in }
    ) {
        self.export = export
        self.copy = copy
        self.save = save
        self.retake = retake
        self.done = done
        self.delete = delete
        self.reveal = reveal
    }
}

/// A native promised-file payload. Export begins only after a drag receiver asks
/// for the MP4, avoiding eager work when the user merely clicks the preview.
struct PreviewFileDragItem: Transferable, Identifiable, Sendable {
    typealias FailureReporter = @MainActor @Sendable (UserFacingErrorDetails) -> Void
    typealias SuccessReporter = @MainActor @Sendable (PreviewShareOutcome) -> Void

    let id: RecordingID
    let request: PreviewExportRequest
    let export: PreviewExportAction
    let reportFailure: FailureReporter
    let reportSuccess: SuccessReporter

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Movie) { item in
            do {
                let outcome = try await item.export(item.request)
                await item.reportSuccess(outcome)
                return SentTransferredFile(outcome.outputURL)
            } catch {
                await item.reportFailure(UserFacingErrorPresentation.details(for: error))
                throw error
            }
        }
    }
}

enum PreviewSmallestTargetSelection: String, CaseIterable, Identifiable, Sendable {
    case tenMegabytes
    case twentyFiveMegabytes
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .tenMegabytes:
            "10 MB (approx.)"
        case .twentyFiveMegabytes:
            "25 MB (approx.)"
        case .custom:
            "Custom"
        }
    }
}

extension ExportPreset {
    var previewTitle: String {
        switch self {
        case .compact:
            "Compact"
        case .crisp:
            "Crisp"
        case .smallest:
            "Smallest"
        }
    }
}

enum PreviewTimecodeFormatter {
    static func string(from seconds: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = wholeSeconds / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        let remainingSeconds = wholeSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

extension PreviewRecording {
    static func demo() -> Self {
        do {
            let duration: TimeInterval = 24
            return try Self(
                id: RecordingID(UUID(uuidString: "7C8BDF46-8E4E-4B6E-A493-C2A40AF19043")!),
                sourceURL: URL(fileURLWithPath: "/tmp/clip-preview-demo.mp4"),
                duration: duration,
                pixelSize: PixelSize(width: 1_440, height: 900),
                frameRate: .thirty,
                audioConfiguration: .systemAudioOnly,
                filename: RecordingFilename(validating: "clip-20260717-104218.mp4"),
                trimRange: TrimRange(startTime: 2, endTime: duration),
                exportConfiguration: .compact,
                approximateExportByteCount: 5_800_000
            )
        } catch {
            preconditionFailure("Invalid deterministic Preview demo state: \(error)")
        }
    }
}

extension PreviewActions {
    static let demo = Self(
        export: {
            PreviewShareOutcome(
                outputURL: $0.sourceURL,
                historyDisposition: .keepOriginal,
                sourceFinalizationDeferred: false
            )
        },
        copy: {
            PreviewShareOutcome(
                outputURL: $0.sourceURL,
                historyDisposition: .keepOriginal,
                sourceFinalizationDeferred: false
            )
        },
        save: { _ in nil },
        retake: { _ in nil },
        done: { _ in },
        delete: { _ in }
    )
}
