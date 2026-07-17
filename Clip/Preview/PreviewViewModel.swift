@preconcurrency import AVFoundation
import ClipCore
import ClipMedia
import Combine
import Foundation
import OSLog

enum PreviewOperation: Equatable, Sendable {
    case copying
    case saving
    case retaking
    case closing
    case deleting

    var progressTitle: String {
        switch self {
        case .copying:
            "Preparing Copy…"
        case .saving:
            "Saving…"
        case .retaking:
            "Waiting for Retake…"
        case .closing:
            "Saving Changes…"
        case .deleting:
            "Deleting…"
        }
    }
}

struct PreviewAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class PreviewViewModel: ObservableObject {
    @Published private(set) var recording: PreviewRecording
    @Published var filenameText: String
    @Published private(set) var trimStart: TimeInterval
    @Published private(set) var trimEnd: TimeInterval
    @Published private(set) var currentTime: TimeInterval
    @Published private(set) var selectedPreset: ExportPreset
    @Published private(set) var exportAudioPreference: ExportAudioPreference
    @Published private(set) var smallestTargetSelection: PreviewSmallestTargetSelection
    @Published private(set) var customTargetMegabytes: Int
    @Published private(set) var operation: PreviewOperation?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastSharedFileURL: URL?
    @Published private(set) var lastExportedByteCount: Int64?
    @Published var alert: PreviewAlert?
    @Published var isDeleteConfirmationPresented = false
    @Published private(set) var sourceFinalizationDeferred = false

    let player: AVPlayer

    private let actions: PreviewActions
    private var operationTask: Task<Void, Never>?

    init(recording: PreviewRecording, actions: PreviewActions) {
        self.recording = recording
        self.actions = actions
        filenameText = recording.filename.fileName
        trimStart = recording.trimRange.startTime
        trimEnd = recording.trimRange.endTime
        currentTime = recording.trimRange.startTime
        selectedPreset = recording.exportConfiguration.preset
        exportAudioPreference = recording.exportAudioPreference

        switch recording.exportConfiguration.smallestSizeTarget {
        case .tenMegabytes:
            smallestTargetSelection = .tenMegabytes
            customTargetMegabytes = 25
        case .twentyFiveMegabytes:
            smallestTargetSelection = .twentyFiveMegabytes
            customTargetMegabytes = 25
        case let .custom(megabytes):
            smallestTargetSelection = .custom
            customTargetMegabytes = megabytes
        }

        player = AVPlayer(url: recording.sourceURL)
        player.actionAtItemEnd = .pause
        player.isMuted = !recording.exportAudioPreference.includesAudio
        player.seek(to: CMTime(seconds: recording.trimRange.startTime, preferredTimescale: 600))
    }

    deinit {
        operationTask?.cancel()
    }

    var duration: TimeInterval { recording.duration }
    var aspectRatio: CGFloat { recording.aspectRatio }
    var isBusy: Bool { operation != nil }
    var isPlaying: Bool { player.timeControlStatus == .playing }
    var canShare: Bool { !isBusy && validatedFilename != nil }
    var hasRecordedAudio: Bool {
        recording.audioConfiguration.microphoneEnabled
            || recording.audioConfiguration.systemAudioEnabled
    }
    var isAudioRemoved: Bool { exportAudioPreference == .removeAudio }

    var filenameErrorMessage: String? {
        guard validatedFilename == nil else { return nil }
        return "Enter a valid filename without folders or control characters."
    }

    var estimatedOutputSize: MediaExportSizeEstimate {
        let configuration = MediaExportConfigurationFactory.make(
            preset: mediaPreset,
            sourceWidth: recording.pixelSize.width,
            sourceHeight: recording.pixelSize.height,
            sourceFramesPerSecond: recording.frameRate.framesPerSecond,
            duration: selectedTrimDuration,
            approximateTargetMegabytes: selectedPreset == .smallest
                ? Double(resolvedSmallestTarget.megabytes)
                : nil,
            includesAudio: hasRecordedAudio && exportAudioPreference.includesAudio
        )
        return MediaExportSizeEstimator.estimate(
            configuration: configuration,
            duration: selectedTrimDuration,
            includesAudio: hasRecordedAudio && exportAudioPreference.includesAudio,
            sourceByteCount: recording.approximateExportByteCount,
            sourceDuration: recording.duration,
            sourceIncludesAudio: hasRecordedAudio
        )
    }

    var outputSizeDescription: String {
        if selectedPreset != .smallest {
            guard let lastExportedByteCount else {
                return "Quality based — size varies"
            }
            let size = ByteCountFormatter.string(
                fromByteCount: lastExportedByteCount,
                countStyle: .file
            )
            return "Actual output: \(size)"
        }

        let size = ByteCountFormatter.string(
            fromByteCount: estimatedOutputSize.byteCount,
            countStyle: .file
        )
        return "Estimated output: \(size) · \(resolvedSmallestTarget.megabytes) MB target"
    }

    /// Kept as a source-compatible alias for callers that predate the
    /// quality-based Compact and Crisp presentation.
    var estimatedOutputSizeDescription: String {
        outputSizeDescription
    }

    var dragItem: PreviewFileDragItem? {
        guard canShare, let request = makeExportRequest() else { return nil }
        return PreviewFileDragItem(
            id: recording.id,
            request: request,
            export: actions.export,
            reportFailure: { [weak self] details in
                ClipLog.export.error(
                    "Promised-file export failed: \(details.technicalDescription, privacy: .private)"
                )
                self?.presentError(title: "Couldn’t Export Video", message: details.message)
            },
            reportSuccess: { [weak self] outcome in
                self?.handleShareOutcome(
                    outcome,
                    verb: "Shared",
                    defaultStatus: "Shared \(outcome.outputURL.lastPathComponent)"
                )
            }
        )
    }

    func updateFilename(_ text: String) {
        filenameText = text
        lastExportedByteCount = nil
        statusMessage = nil
    }

    func selectPreset(_ preset: ExportPreset) {
        selectedPreset = preset
        lastExportedByteCount = nil
        statusMessage = nil
    }

    func selectSmallestTarget(_ selection: PreviewSmallestTargetSelection) {
        smallestTargetSelection = selection
        lastExportedByteCount = nil
        statusMessage = nil
    }

    func setCustomTargetMegabytes(_ megabytes: Int) {
        customTargetMegabytes = min(max(megabytes, SmallestSizeTarget.customRange.lowerBound),
                                    SmallestSizeTarget.customRange.upperBound)
        lastExportedByteCount = nil
        statusMessage = nil
    }

    func setAudioRemoved(_ removed: Bool) {
        guard hasRecordedAudio else { return }
        exportAudioPreference = removed ? .removeAudio : .keepAudio
        player.isMuted = removed
        lastExportedByteCount = nil
        statusMessage = nil
    }

    func updateTrimStart(_ proposedTime: TimeInterval) {
        let maximum = max(0, trimEnd - minimumTrimDuration)
        trimStart = min(max(proposedTime, 0), maximum)
        lastExportedByteCount = nil
        statusMessage = nil
        if currentTime < trimStart {
            seek(to: trimStart)
        }
    }

    func updateTrimEnd(_ proposedTime: TimeInterval) {
        let minimum = min(duration, trimStart + minimumTrimDuration)
        trimEnd = min(max(proposedTime, minimum), duration)
        lastExportedByteCount = nil
        statusMessage = nil
        if currentTime > trimEnd {
            seek(to: trimEnd)
        }
    }

    func resetTrim() {
        trimStart = 0
        trimEnd = duration
        lastExportedByteCount = nil
        seek(to: 0)
        statusMessage = nil
    }

    func seek(to proposedTime: TimeInterval) {
        let boundedTime = min(max(proposedTime, trimStart), trimEnd)
        currentTime = boundedTime
        player.seek(
            to: CMTime(seconds: boundedTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            objectWillChange.send()
            return
        }

        if currentTime >= trimEnd - 0.02 || currentTime < trimStart {
            seek(to: trimStart)
        }
        player.play()
        objectWillChange.send()
    }

    /// Called from the view's lifetime-bound task; no observer token can outlive Preview.
    func monitorPlayback() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let observedTime = player.currentTime().seconds
            if observedTime.isFinite {
                currentTime = min(max(observedTime, 0), duration)
                if isPlaying, observedTime >= trimEnd {
                    player.pause()
                    seek(to: trimStart)
                }
            }

            do {
                try await clock.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    func copy() {
        guard begin(.copying), let request = makeExportRequest() else { return }
        let copy = actions.copy
        operationTask = Task { [weak self] in
            do {
                let outcome = try await copy(request)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                let status = self.handleShareOutcome(
                    outcome,
                    verb: "Copied",
                    defaultStatus: ShareCompletionFormatting.copiedStatus(
                        for: outcome.outputURL
                    )
                )
                self.completeOperation(status: status)
                // Keep Preview visible when there is a warning so it cannot be
                // lost behind an automatic close and the user can retry safely.
                if outcome.shouldClosePreview, outcome.postShareWarning == nil {
                    self.done()
                }
            } catch is CancellationError {
                self?.completeOperation(status: nil)
            } catch {
                self?.failOperation(title: "Couldn’t Copy Video", error: error)
            }
        }
    }

    func saveAs() {
        guard begin(.saving), let request = makeExportRequest() else { return }
        let save = actions.save
        operationTask = Task { [weak self] in
            do {
                let outcome = try await save(request)
                guard !Task.isCancelled else { return }
                if let outcome {
                    guard let self else { return }
                    let status = self.handleShareOutcome(
                        outcome,
                        verb: "Saved",
                        defaultStatus: "Saved \(outcome.outputURL.lastPathComponent)"
                    )
                    self.completeOperation(status: status)
                } else {
                    self?.completeOperation(status: nil)
                }
            } catch is CancellationError {
                self?.completeOperation(status: nil)
            } catch {
                self?.failOperation(title: "Couldn’t Save Video", error: error)
            }
        }
    }

    func revealLastSharedFile() {
        guard let lastSharedFileURL else { return }
        actions.reveal(lastSharedFileURL)
    }

    func retake() {
        guard begin(.retaking) else { return }
        let previousRecording = currentRecordingSnapshot()
        let retake = actions.retake
        operationTask = Task { [weak self] in
            do {
                let result = try await retake(previousRecording)
                guard !Task.isCancelled else { return }
                guard let result else {
                    self?.completeOperation(status: nil)
                    return
                }
                guard let self else {
                    await result.discardReplacement()
                    return
                }
                self.install(result.recording)
                do {
                    try await result.commitInstallation()
                    self.sourceFinalizationDeferred = false
                    self.completeOperation(status: "Retake ready")
                } catch {
                    self.install(previousRecording)
                    await result.discardReplacement()
                    self.failOperation(title: "Couldn’t Install Retake", error: error)
                }
            } catch is CancellationError {
                self?.completeOperation(status: nil)
            } catch {
                // The current recording is deliberately not changed until retake succeeds.
                self?.failOperation(title: "Couldn’t Retake Recording", error: error)
            }
        }
    }

    func done() {
        guard begin(.closing) else { return }
        player.pause()
        let snapshot = currentRecordingSnapshot()
        let done = actions.done
        operationTask = Task { [weak self] in
            do {
                try await done(snapshot)
                guard !Task.isCancelled else { return }
                self?.completeOperation(status: nil)
            } catch is CancellationError {
                self?.completeOperation(status: nil)
            } catch {
                self?.failOperation(title: "Couldn’t Close Preview", error: error)
            }
        }
    }

    func requestDelete() {
        guard !isBusy else { return }
        isDeleteConfirmationPresented = true
    }

    func cancelDelete() {
        isDeleteConfirmationPresented = false
    }

    func confirmDelete() {
        isDeleteConfirmationPresented = false
        guard begin(.deleting, requiresValidFilename: false) else { return }
        player.pause()
        let snapshot = currentRecordingSnapshot()
        let delete = actions.delete
        operationTask = Task { [weak self] in
            do {
                try await delete(snapshot)
                guard !Task.isCancelled else { return }
                self?.completeOperation(status: nil)
            } catch is CancellationError {
                self?.completeOperation(status: nil)
            } catch {
                self?.failOperation(title: "Couldn’t Delete Recording", error: error)
            }
        }
    }

    func dismissAlert() {
        alert = nil
    }

    /// Gives application termination a bounded ownership handoff point. The
    /// caller first resolves any coordinator-owned Retake continuation, then
    /// waits for in-flight Preview work before persisting this final snapshot.
    func settleForTermination() async {
        player.pause()
        let pendingTask = operationTask
        pendingTask?.cancel()
        await pendingTask?.value
        operationTask = nil
        operation = nil
    }

    func snapshotForPersistence() -> PreviewRecording {
        currentRecordingSnapshot()
    }

    private var minimumTrimDuration: TimeInterval {
        min(0.1, duration)
    }

    private var validatedFilename: RecordingFilename? {
        try? RecordingFilename(validating: filenameText)
    }

    private var resolvedSmallestTarget: SmallestSizeTarget {
        switch smallestTargetSelection {
        case .tenMegabytes:
            .tenMegabytes
        case .twentyFiveMegabytes:
            .twentyFiveMegabytes
        case .custom:
            (try? SmallestSizeTarget(customMegabytes: customTargetMegabytes)) ?? .twentyFiveMegabytes
        }
    }

    private var selectedTrimDuration: TimeInterval {
        max(trimEnd - trimStart, 0)
    }

    private var mediaPreset: MediaExportPreset {
        switch selectedPreset {
        case .compact:
            .compact
        case .crisp:
            .crisp
        case .smallest:
            .smallest
        }
    }

    private func makeExportRequest() -> PreviewExportRequest? {
        guard let filename = validatedFilename,
              let trimRange = try? TrimRange(startTime: trimStart, endTime: trimEnd) else {
            return nil
        }
        return PreviewExportRequest(
            recordingID: recording.id,
            sourceURL: recording.sourceURL,
            captureFrameRate: recording.frameRate,
            filename: filename,
            trimRange: trimRange,
            configuration: ExportConfiguration(
                preset: selectedPreset,
                smallestSizeTarget: resolvedSmallestTarget
            ),
            audioPreference: exportAudioPreference
        )
    }

    private func currentRecordingSnapshot() -> PreviewRecording {
        guard let request = makeExportRequest() else { return recording }
        var snapshot = recording
        snapshot.filename = request.filename
        snapshot.trimRange = request.trimRange
        snapshot.exportConfiguration = request.configuration
        snapshot.exportAudioPreference = request.audioPreference
        return snapshot
    }

    private func begin(
        _ requestedOperation: PreviewOperation,
        requiresValidFilename: Bool = true
    ) -> Bool {
        guard !isBusy else { return false }
        guard !requiresValidFilename || validatedFilename != nil else {
            presentError(
                title: "Invalid Filename",
                message: filenameErrorMessage ?? "Enter a valid filename."
            )
            return false
        }
        operation = requestedOperation
        statusMessage = nil
        return true
    }

    private func completeOperation(status: String?) {
        operation = nil
        operationTask = nil
        statusMessage = status
    }

    private func failOperation(title: String, error: any Error) {
        operation = nil
        operationTask = nil
        let details = UserFacingErrorPresentation.details(for: error)
        ClipLog.lifecycle.error(
            "Preview operation failed (\(title, privacy: .public)): \(details.technicalDescription, privacy: .private)"
        )
        presentError(title: title, message: details.message)
    }

    private func presentError(title: String, message: String) {
        alert = PreviewAlert(title: title, message: message)
    }

    @discardableResult
    private func handleShareOutcome(
        _ outcome: PreviewShareOutcome,
        verb: String,
        defaultStatus: String? = nil
    ) -> String? {
        lastSharedFileURL = outcome.outputURL
        lastExportedByteCount = ShareCompletionFormatting.fileByteCount(at: outcome.outputURL)
        sourceFinalizationDeferred = outcome.sourceFinalizationDeferred
        let success = defaultStatus ?? "\(verb) \(outcome.outputURL.lastPathComponent)"
        let resolvedStatus: String?
        if let warning = outcome.postShareWarning {
            resolvedStatus = "\(success) — \(warning)"
        } else if outcome.historyDisposition == .removeHistoryItem {
            resolvedStatus = "\(success) — removed from History when Preview closes"
        } else if outcome.historyDisposition == .replaceOriginalWithExport,
                  outcome.sourceFinalizationDeferred {
            resolvedStatus = "\(success) — optimized original will update when Preview closes"
        } else {
            resolvedStatus = success
        }
        statusMessage = resolvedStatus
        return resolvedStatus
    }

    private func install(_ replacement: PreviewRecording) {
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: replacement.sourceURL))
        player.actionAtItemEnd = .pause

        recording = replacement
        lastSharedFileURL = nil
        lastExportedByteCount = nil
        filenameText = replacement.filename.fileName
        trimStart = replacement.trimRange.startTime
        trimEnd = replacement.trimRange.endTime
        currentTime = replacement.trimRange.startTime
        selectedPreset = replacement.exportConfiguration.preset
        exportAudioPreference = replacement.exportAudioPreference
        player.isMuted = !replacement.exportAudioPreference.includesAudio

        switch replacement.exportConfiguration.smallestSizeTarget {
        case .tenMegabytes:
            smallestTargetSelection = .tenMegabytes
        case .twentyFiveMegabytes:
            smallestTargetSelection = .twentyFiveMegabytes
        case let .custom(megabytes):
            smallestTargetSelection = .custom
            customTargetMegabytes = megabytes
        }

        seek(to: replacement.trimRange.startTime)
    }
}
