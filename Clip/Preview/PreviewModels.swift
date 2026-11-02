import ClipCore
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
        // Recordings created before capture snapshots could not contain native
        // click highlights, even if the current global preference is On.
        legacyFallback.showClickHighlights = false

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
        self.exportAudioPreference = exportAudioPreference
        self.approximateExportByteCount = approximateExportByteCount
        self.retakePlan = retakePlan
    }

    var aspectRatio: CGFloat {
        CGFloat(pixelSize.width) / CGFloat(pixelSize.height)
    }
}

/// A complete, validated description of what the user currently sees in Preview.
/// Every share path uses this same request so trim, audio, and filename cannot drift.
struct PreviewExportRequest: Equatable, Sendable {
    let recordingID: RecordingID
    let sourceURL: URL
    /// The original capture cadence, retained when remuxing shared files.
    let captureFrameRate: CaptureFrameRate
    let filename: RecordingFilename
    let trimRange: TrimRange
    let audioPreference: ExportAudioPreference
    /// Retains the original source identity when a promised drag uses a lease URL.
    let sourceCacheIdentity: String?

    init(
        recordingID: RecordingID,
        sourceURL: URL,
        captureFrameRate: CaptureFrameRate,
        filename: RecordingFilename,
        trimRange: TrimRange,
        audioPreference: ExportAudioPreference,
        sourceCacheIdentity: String? = nil
    ) {
        self.recordingID = recordingID
        self.sourceURL = sourceURL
        self.captureFrameRate = captureFrameRate
        self.filename = filename
        self.trimRange = trimRange
        self.audioPreference = audioPreference
        self.sourceCacheIdentity = sourceCacheIdentity
    }
}

struct PreviewShareOutcome: Sendable {
    let outputURL: URL
    let shouldClosePreview: Bool
    /// A successful Copy, Save As, or drag must remain successful when only the
    /// subsequent History bookkeeping fails. This warning is shown inline so
    /// the user knows the shared file is usable and the managed original remains.
    let postShareWarning: String?

    init(
        outputURL: URL,
        shouldClosePreview: Bool = false,
        postShareWarning: String? = nil
    ) {
        self.outputURL = outputURL
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
typealias PreviewPrepareExportAction = @MainActor @Sendable (PreviewExportRequest) async throws -> URL

enum PreviewProcessingPhase: Equatable, Sendable {
    case preparing, processing, finishing, ready, failed

    var title: String {
        switch self {
        case .preparing: "Preparing video"
        case .processing: "Processing video"
        case .finishing: "Finishing"
        case .ready: "Ready"
        case .failed: "Couldn’t process video"
        }
    }

    var isBusy: Bool { self == .preparing || self == .processing || self == .finishing }
}

/// Exists only while the original capture is retained for processing choices.
/// Saved Sources are presented without this state and cannot be recompressed.
struct PreviewProcessingState: Equatable, Sendable {
    var options: RecordingProcessingOptions
    var nativePixelSize: PixelSize
    var phase: PreviewProcessingPhase
    var progress: Double?
    var message: String?

    init(options: RecordingProcessingOptions, nativePixelSize: PixelSize,
         phase: PreviewProcessingPhase = .preparing, progress: Double? = nil,
         message: String? = nil) {
        self.options = options
        self.nativePixelSize = nativePixelSize
        self.phase = phase
        self.progress = progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        self.message = message
    }
}

typealias PreviewProcessingProgress = @MainActor @Sendable (PreviewProcessingPhase, Double?) -> Void
typealias PreviewProcessAction = @MainActor @Sendable (
    RecordingProcessingOptions, PreviewRecording, @escaping PreviewProcessingProgress
) async throws -> PreviewRecording

/// Pins a candidate for a promised export, even if the receiver asks for its
/// bytes only after Preview has reprocessed or closed. Releasing the object
/// releases the pin; the recording owner decides when retired files are safe.
protocol PreviewSourceLease: AnyObject, Sendable {
    var sourceURL: URL { get }
}

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
    let process: PreviewProcessAction?
    let processingOptionsChanged: @MainActor @Sendable (RecordingProcessingOptions) -> Void
    let acquireSourceLease: @MainActor @Sendable (PreviewExportRequest) throws -> (any PreviewSourceLease)?
    /// Prepares a reusable, unpublished export before accepting an edited trim.
    let prepareExport: PreviewPrepareExportAction?

    init(
        export: @escaping PreviewExportAction,
        copy: @escaping PreviewCopyAction,
        save: @escaping PreviewSaveAction,
        retake: @escaping PreviewRetakeAction,
        done: @escaping @MainActor @Sendable (PreviewRecording) async throws -> Void,
        delete: @escaping @MainActor @Sendable (PreviewRecording) async throws -> Void,
        reveal: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
        process: PreviewProcessAction? = nil,
        processingOptionsChanged: @escaping @MainActor @Sendable (RecordingProcessingOptions) -> Void = { _ in },
        acquireSourceLease: @escaping @MainActor @Sendable (PreviewExportRequest) throws -> (any PreviewSourceLease)? = { _ in nil },
        prepareExport: PreviewPrepareExportAction? = nil
    ) {
        self.export = export
        self.copy = copy
        self.save = save
        self.retake = retake
        self.done = done
        self.delete = delete
        self.reveal = reveal
        self.process = process
        self.processingOptionsChanged = processingOptionsChanged
        self.acquireSourceLease = acquireSourceLease
        self.prepareExport = prepareExport
    }
}

/// A native promised-file payload. Export begins only after a drag receiver asks
/// for the MP4, avoiding eager work when the user merely clicks the preview.
///
/// The content representation serves native media receivers such as Finder and
/// Messages. The URL object makes the same managed MP4 visible to upload drop
/// targets that accept files from Finder but do not consume an MP4 file promise
/// directly. Both representations resolve through one promise so a receiver
/// asking for both cannot export or register the share twice.
struct PreviewFileDragItem: Identifiable, Sendable {
    typealias FailureReporter = @MainActor @Sendable (UserFacingErrorDetails) -> Void
    typealias SuccessReporter = @MainActor @Sendable (PreviewShareOutcome) -> Void

    let id: RecordingID
    let request: PreviewExportRequest
    private let exportPromise: PreviewFileDragExportPromise

    init(
        id: RecordingID,
        request: PreviewExportRequest,
        export: @escaping PreviewExportAction,
        reportFailure: @escaping FailureReporter,
        reportSuccess: @escaping SuccessReporter,
        sourceLease: (any PreviewSourceLease)? = nil
    ) {
        self.id = id
        self.request = request
        exportPromise = PreviewFileDragExportPromise(
            request: request,
            export: export,
            reportFailure: reportFailure,
            reportSuccess: reportSuccess,
            sourceLease: sourceLease
        )
    }

    func makeItemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        // The representation's MPEG-4 type supplies the extension. Giving the
        // base name avoids receivers appending a second .mp4; the URL/object
        // representations still use the complete canonical filename.
        provider.suggestedName = request.filename.stem

        // Register the native MP4 file representation first so Finder and
        // media-aware apps receive the highest-fidelity representation they
        // understand, with Clip's edited filename rather than a generic UTI
        // description.
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.mpeg4Movie.identifier,
            fileOptions: [.openInPlace],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task {
                do {
                    let outcome = try await resolveExport()
                    try Task.checkCancellation()
                    completion(outcome.outputURL, false, nil)
                    progress.completedUnitCount = 1
                } catch {
                    completion(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }

        // A raw public.file-url data representation advertises the UTI but
        // cannot be loaded as URL/NSURL by AppKit and browser upload targets.
        // This lazy NSItemProviderWriting object supplies both public.file-url
        // and public.url, which makes URL-object coercion work while retaining
        // the same asynchronous single-flight export.
        provider.registerObject(
            PreviewLazyFileURLObject(exportPromise: exportPromise),
            visibility: .all
        )
        return provider
    }

    func resolveExport() async throws -> PreviewShareOutcome {
        try await exportPromise.resolve()
    }
}

private final class PreviewLazyFileURLObject: NSObject, NSItemProviderWriting, @unchecked Sendable {
    private let exportPromise: PreviewFileDragExportPromise

    init(exportPromise: PreviewFileDragExportPromise) {
        self.exportPromise = exportPromise
        super.init()
    }

    static var writableTypeIdentifiersForItemProvider: [String] {
        [UTType.fileURL.identifier, UTType.url.identifier]
    }

    func loadData(
        withTypeIdentifier _: String,
        forItemProviderCompletionHandler completionHandler: @escaping @Sendable (
            Data?,
            (any Error)?
        ) -> Void
    ) -> Progress? {
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            do {
                let outcome = try await exportPromise.resolve()
                try Task.checkCancellation()
                completionHandler(Data(outcome.outputURL.absoluteString.utf8), nil)
                progress.completedUnitCount = 1
            } catch {
                completionHandler(nil, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}

private actor PreviewFileDragExportPromise {
    private let request: PreviewExportRequest
    private let export: PreviewExportAction
    private let reportFailure: PreviewFileDragItem.FailureReporter
    private let reportSuccess: PreviewFileDragItem.SuccessReporter
    private var resolutionTask: Task<PreviewShareOutcome, any Error>?
    private var didReportResolution = false
    private let sourceLease: (any PreviewSourceLease)?

    init(
        request: PreviewExportRequest,
        export: @escaping PreviewExportAction,
        reportFailure: @escaping PreviewFileDragItem.FailureReporter,
        reportSuccess: @escaping PreviewFileDragItem.SuccessReporter,
        sourceLease: (any PreviewSourceLease)?
    ) {
        self.request = request
        self.export = export
        self.reportFailure = reportFailure
        self.reportSuccess = reportSuccess
        self.sourceLease = sourceLease
    }

    func resolve() async throws -> PreviewShareOutcome {
        let task: Task<PreviewShareOutcome, any Error>
        if let resolutionTask {
            task = resolutionTask
        } else {
            let request = self.request
            let export = self.export
            let newTask = Task {
                try await export(request)
            }
            resolutionTask = newTask
            task = newTask
        }

        do {
            let outcome = try await task.value
            if !didReportResolution {
                didReportResolution = true
                await reportSuccess(outcome)
            }
            return outcome
        } catch {
            if !didReportResolution {
                didReportResolution = true
                await reportFailure(UserFacingErrorPresentation.details(for: error))
            }
            throw error
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
                outputURL: $0.sourceURL
            )
        },
        copy: {
            PreviewShareOutcome(
                outputURL: $0.sourceURL
            )
        },
        save: { _ in nil },
        retake: { _ in nil },
        done: { _ in },
        delete: { _ in }
    )
}
