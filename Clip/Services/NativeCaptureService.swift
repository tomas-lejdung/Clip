import ClipCore
import ClipMedia
import Foundation

enum NativeCaptureServiceError: LocalizedError {
    case noPreparedTarget
    case recordingAlreadyActive
    case recordingNotActive
    case invalidOutputDimensions
    case insufficientStorage(availableBytes: Int64, requiredBytes: Int64)
    case recoveryMetadataUnavailable
    case zeroDurationOutput

    var errorDescription: String? {
        switch self {
        case .noPreparedTarget:
            String(localized: "Choose an area or display before recording.")
        case .recordingAlreadyActive:
            String(localized: "A recording is already in progress.")
        case .recordingNotActive:
            String(localized: "There is no recording in progress.")
        case .invalidOutputDimensions:
            String(localized: "The selected capture area is too small.")
        case let .insufficientStorage(availableBytes, requiredBytes):
            String(
                localized: "Recording needs at least \(Self.formattedByteCount(requiredBytes)) of free space. Only \(Self.formattedByteCount(availableBytes)) is available."
            )
        case .recoveryMetadataUnavailable:
            String(localized: "Clip could not prepare a recoverable recording file. Check available storage and try again.")
        case .zeroDurationOutput:
            String(localized: "The recording did not contain any video frames.")
        }
    }

    fileprivate static func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, byteCount), countStyle: .file)
    }
}

/// Conservative guardrails for an unbounded screen recording.
///
/// A capture may start with at least 1 GiB available for important usage. Once
/// active, it is stopped below 512 MiB so AVAssetWriter still has room to
/// finalize its MP4 and the app can preserve playable material. The split
/// thresholds add hysteresis and avoid repeatedly allowing a new recording near
/// the stop point.
struct RecordingStorageCapacityPolicy: Equatable, Sendable {
    static let gibibyte: Int64 = 1_024 * 1_024 * 1_024
    static let mebibyte: Int64 = 1_024 * 1_024

    static let standard = RecordingStorageCapacityPolicy(
        minimumStartCapacityBytes: gibibyte,
        minimumActiveCapacityBytes: 512 * mebibyte
    )

    let minimumStartCapacityBytes: Int64
    let minimumActiveCapacityBytes: Int64

    init(minimumStartCapacityBytes: Int64, minimumActiveCapacityBytes: Int64) {
        precondition(minimumStartCapacityBytes >= minimumActiveCapacityBytes)
        precondition(minimumActiveCapacityBytes >= 0)
        self.minimumStartCapacityBytes = minimumStartCapacityBytes
        self.minimumActiveCapacityBytes = minimumActiveCapacityBytes
    }

    /// A missing capacity estimate is not evidence of a full volume.
    func permitsStart(availableCapacityBytes: Int64?) -> Bool {
        guard let availableCapacityBytes else { return true }
        return availableCapacityBytes >= minimumStartCapacityBytes
    }

    /// Returns true only for a known capacity below the finalization reserve.
    func requiresActiveStop(availableCapacityBytes: Int64?) -> Bool {
        guard let availableCapacityBytes else { return false }
        return availableCapacityBytes < minimumActiveCapacityBytes
    }
}

/// The small portion of `ScreenRecorder` used by the app-facing capture
/// service. Keeping this boundary on the main actor lets deterministic tests
/// exercise service lifecycle and cleanup without creating ScreenCaptureKit
/// objects or requesting privacy access.
@MainActor
protocol ScreenRecorderServicing: AnyObject {
    func start(_ request: ScreenRecordingRequest) async throws
    func pause() throws
    func resume() throws
    func finish() async throws -> URL
    func cancel() async throws
}

extension ScreenRecorder: ScreenRecorderServicing {}

@MainActor
final class NativeCaptureService: CaptureServicing {
    typealias CapacityProvider = @MainActor @Sendable (URL) -> Int64?
    typealias CapacitySleep = @Sendable (Duration) async throws -> Void
    typealias RecorderFactory = @MainActor (
        @escaping @Sendable (ScreenRecorderEvent) -> Void
    ) -> any ScreenRecorderServicing

    private struct ActiveRecording {
        let id: RecordingID
        let target: PreparedCaptureTarget
        let settings: ClipSettings
        let outputURL: URL
        let recoveryURL: URL
    }

    private let recordingsDirectory: URL
    private let recorder: any ScreenRecorderServicing
    private let capacityPolicy: RecordingStorageCapacityPolicy
    private let capacityProvider: CapacityProvider
    private let capacityCheckInterval: Duration
    private let capacitySleep: CapacitySleep
    let events: AsyncStream<ScreenRecorderEvent>
    private let eventContinuation: AsyncStream<ScreenRecorderEvent>.Continuation
    private var preparedTarget: PreparedCaptureTarget?
    private var activeRecording: ActiveRecording?
    private var startTask: Task<Void, Error>?
    private var capacityMonitorTask: Task<Void, Never>?
    private var capacityFailureSessionIdentifier: UUID?
    private var isPerformingTerminalOperation = false

    init(
        recordingsDirectory: URL,
        capacityPolicy: RecordingStorageCapacityPolicy = .standard,
        capacityProvider: CapacityProvider? = nil,
        capacityCheckInterval: Duration = .seconds(5),
        capacitySleep: @escaping CapacitySleep = { duration in
            try await Task.sleep(for: duration)
        },
        recorderFactory: RecorderFactory = { eventHandler in
            ScreenRecorder(eventHandler: eventHandler)
        }
    ) {
        let eventStream = AsyncStream<ScreenRecorderEvent>.makeStream()
        self.recordingsDirectory = recordingsDirectory
        self.capacityPolicy = capacityPolicy
        self.capacityProvider = capacityProvider ?? { url in
            try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
        }
        self.capacityCheckInterval = capacityCheckInterval
        self.capacitySleep = capacitySleep
        events = eventStream.stream
        eventContinuation = eventStream.continuation
        recorder = recorderFactory { event in
            eventStream.continuation.yield(event)
        }
    }

    deinit {
        capacityMonitorTask?.cancel()
        eventContinuation.finish()
    }

    func prepare(_ target: PreparedCaptureTarget) async throws {
        guard activeRecording == nil,
              startTask == nil,
              !isPerformingTerminalOperation else {
            throw NativeCaptureServiceError.recordingAlreadyActive
        }
        guard target.outputWidth >= 2,
              target.outputHeight >= 2,
              target.outputWidth.isMultiple(of: 2),
              target.outputHeight.isMultiple(of: 2) else {
            throw NativeCaptureServiceError.invalidOutputDimensions
        }
        preparedTarget = target
    }

    func start(recordingID: RecordingID, settings: ClipSettings) async throws {
        guard activeRecording == nil,
              startTask == nil,
              !isPerformingTerminalOperation else {
            throw NativeCaptureServiceError.recordingAlreadyActive
        }
        // The idle invariant says this is nil; cancel defensively so every
        // subsequently thrown start path is also a monitor-terminal path.
        cancelCapacityMonitor()
        guard let preparedTarget else {
            throw NativeCaptureServiceError.noPreparedTarget
        }
        let availableCapacity = capacityProvider(recordingsDirectory)
        guard capacityPolicy.permitsStart(availableCapacityBytes: availableCapacity) else {
            throw NativeCaptureServiceError.insufficientStorage(
                availableBytes: availableCapacity ?? 0,
                requiredBytes: capacityPolicy.minimumStartCapacityBytes
            )
        }

        let outputURL = recordingsDirectory
            .appendingPathComponent(recordingID.description)
            .appendingPathExtension("mp4")
        let recoveryURL = CaptureRecoveryRecord.url(
            for: recordingID,
            in: recordingsDirectory
        )
        do {
            let recoveryRecord = CaptureRecoveryRecord(
                recordingID: recordingID,
                createdAt: Date(),
                captureTarget: preparedTarget.domainTarget,
                settings: settings
            )
            try recoveryRecord.encoded().write(to: recoveryURL, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: recoveryURL)
            throw NativeCaptureServiceError.recoveryMetadataUnavailable
        }
        let configuration = RecordingConfiguration(
            width: preparedTarget.outputWidth,
            height: preparedTarget.outputHeight,
            framesPerSecond: settings.frameRate.framesPerSecond,
            videoQualityPercent: settings.exportQualities.crisp,
            showsCursor: settings.showCursor,
            audioMode: Self.audioMode(for: settings.audio)
        )
        let active = ActiveRecording(
            id: recordingID,
            target: preparedTarget,
            settings: settings,
            outputURL: outputURL,
            recoveryURL: recoveryURL
        )
        activeRecording = active
        capacityFailureSessionIdentifier = nil

        let request = ScreenRecordingRequest(
            sessionIdentifier: recordingID.rawValue,
            displayID: preparedTarget.displayID,
            sourceRect: preparedTarget.sourceRect,
            excludedBundleIdentifier: ApplicationDirectories.bundleIdentifier,
            includedApplicationBundleIdentifier: preparedTarget.includedApplicationBundleIdentifier,
            outputURL: outputURL,
            configuration: configuration
        )
        let recorder = recorder
        let startTask = Task {
            try await recorder.start(request)
        }
        self.startTask = startTask

        do {
            try await startTask.value
        } catch {
            if activeRecording?.id == recordingID {
                cancelCapacityMonitor()
                self.startTask = nil
                if !isPerformingTerminalOperation {
                    activeRecording = nil
                }
            }
            try? FileManager.default.removeItem(at: recoveryURL)
            throw error
        }
        if activeRecording?.id == recordingID {
            self.startTask = nil
            if !isPerformingTerminalOperation {
                startCapacityMonitor(for: recordingID)
            }
        }
    }

    func pause() async throws {
        guard let activeRecording, !isPerformingTerminalOperation else {
            throw NativeCaptureServiceError.recordingNotActive
        }
        let pendingStart = startTask
        if let pendingStart {
            try await pendingStart.value
        }
        guard self.activeRecording?.id == activeRecording.id,
              !isPerformingTerminalOperation else {
            throw NativeCaptureServiceError.recordingNotActive
        }
        try recorder.pause()
    }

    func resume() async throws {
        guard let activeRecording, !isPerformingTerminalOperation else {
            throw NativeCaptureServiceError.recordingNotActive
        }
        let pendingStart = startTask
        if let pendingStart {
            try await pendingStart.value
        }
        guard self.activeRecording?.id == activeRecording.id,
              !isPerformingTerminalOperation else {
            throw NativeCaptureServiceError.recordingNotActive
        }
        try recorder.resume()
    }

    func finish() async throws -> RecordingArtifact {
        cancelCapacityMonitor()
        guard let activeRecording, !isPerformingTerminalOperation else {
            throw NativeCaptureServiceError.recordingNotActive
        }
        isPerformingTerminalOperation = true
        defer {
            cancelCapacityMonitor()
            self.activeRecording = nil
            preparedTarget = nil
            startTask = nil
            isPerformingTerminalOperation = false
        }

        if let pendingStart = startTask {
            try await pendingStart.value
        }
        let outputURL: URL
        do {
            outputURL = try await recorder.finish()
        } catch ScreenRecorderError.noVideoFrames {
            try? FileManager.default.removeItem(at: activeRecording.outputURL)
            try? FileManager.default.removeItem(at: activeRecording.recoveryURL)
            throw NativeCaptureServiceError.zeroDurationOutput
        } catch let ScreenRecorderError.streamStoppedWithRecoverableOutput(message, recoveredURL) {
            outputURL = recoveredURL
            ClipLog.capture.warning(
                "Capture stopped unexpectedly but produced a recoverable MP4: \(message, privacy: .public)"
            )
        }
        let inspection = try await MediaInspector.inspect(outputURL)
        guard inspection.duration > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: activeRecording.recoveryURL)
            throw NativeCaptureServiceError.zeroDurationOutput
        }

        return RecordingArtifact(
            id: activeRecording.id,
            fileURL: outputURL,
            duration: inspection.duration,
            pixelSize: try PixelSize(width: inspection.width, height: inspection.height),
            frameRate: activeRecording.settings.frameRate,
            audioConfiguration: activeRecording.settings.audio,
            captureTarget: activeRecording.target.domainTarget
        )
    }

    func cancel() async {
        cancelCapacityMonitor()
        guard let activeRecording, !isPerformingTerminalOperation else { return }
        isPerformingTerminalOperation = true
        defer {
            cancelCapacityMonitor()
            try? FileManager.default.removeItem(at: activeRecording.recoveryURL)
            try? FileManager.default.removeItem(at: activeRecording.outputURL)
            self.activeRecording = nil
            preparedTarget = nil
            startTask = nil
            isPerformingTerminalOperation = false
        }
        do {
            if let pendingStart = startTask {
                try await pendingStart.value
            }
            try await recorder.cancel()
        } catch {
            ClipLog.capture.error(
                "Failed to stop a canceled capture cleanly: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func audioMode(for configuration: AudioConfiguration) -> AudioCaptureMode {
        switch (configuration.microphoneEnabled, configuration.systemAudioEnabled) {
        case (false, false): .off
        case (true, false): .microphone
        case (false, true): .system
        case (true, true): .microphoneAndSystem
        }
    }

    private func startCapacityMonitor(for recordingID: RecordingID) {
        cancelCapacityMonitor()
        let interval = capacityCheckInterval
        let sleep = capacitySleep
        capacityMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard let self,
                      self.activeRecording?.id == recordingID,
                      !self.isPerformingTerminalOperation else {
                    return
                }
                let availableCapacity = self.capacityProvider(self.recordingsDirectory)
                guard self.capacityPolicy.requiresActiveStop(
                    availableCapacityBytes: availableCapacity
                ) else {
                    continue
                }
                self.emitCapacityFailureOnce(
                    for: recordingID,
                    availableCapacityBytes: availableCapacity ?? 0
                )
                return
            }
        }
    }

    private func cancelCapacityMonitor() {
        capacityMonitorTask?.cancel()
        capacityMonitorTask = nil
    }

    private func emitCapacityFailureOnce(
        for recordingID: RecordingID,
        availableCapacityBytes: Int64
    ) {
        guard activeRecording?.id == recordingID,
              !isPerformingTerminalOperation,
              capacityFailureSessionIdentifier != recordingID.rawValue else {
            return
        }
        capacityFailureSessionIdentifier = recordingID.rawValue
        let available = NativeCaptureServiceError.formattedByteCount(
            availableCapacityBytes
        )
        eventContinuation.yield(
            .failure(
                sessionIdentifier: recordingID.rawValue,
                message: String(
                    localized: "Recording stopped because free disk space fell to \(available). The captured video will be finalized."
                )
            )
        )
    }
}
