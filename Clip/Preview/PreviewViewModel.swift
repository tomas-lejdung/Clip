@preconcurrency import AVFoundation
import AppKit
import ClipCore
import Combine
import Foundation
import OSLog

enum PreviewOperation: Equatable, Sendable {
    case copying
    case saving
    case savingTrim
    case retaking
    case closing
    case deleting

    var progressTitle: String {
        switch self {
        case .copying:
            "Preparing Copy…"
        case .saving:
            "Saving…"
        case .savingTrim:
            "Preparing Trim…"
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
    @Published private(set) var isEditingTrim = false
    @Published private(set) var processingState: PreviewProcessingState?
    @Published private(set) var isExpandedPreviewPresented = false
    @Published private(set) var exportAudioPreference: ExportAudioPreference
    @Published private(set) var operation: PreviewOperation?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastSharedFileURL: URL?
    @Published private(set) var lastExportedByteCount: Int64?
    @Published var alert: PreviewAlert?
    @Published var isDeleteConfirmationPresented = false

    let player: AVPlayer
    weak var editorWindow: NSWindow?

    private let actions: PreviewActions
    private var operationTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var nativeErrorAlert: NSAlert?
    private var expandedPlayer: PreviewExpandedPlayerController?
    private var processingGeneration = UUID()
    private var savedTrimRange: TrimRange

    init(recording: PreviewRecording, actions: PreviewActions, processingState: PreviewProcessingState? = nil) {
        self.recording = recording
        self.actions = actions
        self.processingState = processingState
        filenameText = recording.filename.stem
        trimStart = recording.trimRange.startTime
        trimEnd = recording.trimRange.endTime
        savedTrimRange = recording.trimRange
        currentTime = recording.trimRange.startTime
        exportAudioPreference = recording.exportAudioPreference

        player = processingState?.phase.isBusy == true ? AVPlayer() : AVPlayer(url: recording.sourceURL)
        player.actionAtItemEnd = .pause
        player.isMuted = !recording.exportAudioPreference.includesAudio
        player.seek(to: CMTime(seconds: recording.trimRange.startTime, preferredTimescale: 600))
        updatePlaybackRange()
    }

    deinit {
        operationTask?.cancel()
        processingTask?.cancel()
    }

    var duration: TimeInterval { recording.duration }
    var aspectRatio: CGFloat { recording.aspectRatio }
    var isBusy: Bool { operation != nil || (processingState != nil && processingState?.phase != .ready) }
    var isProcessing: Bool { processingState?.phase.isBusy == true }
    var canEditProcessing: Bool { operation == nil && !isEditingTrim && processingState != nil && !isProcessing }
    var isPlaying: Bool { player.timeControlStatus == .playing }
    var canShare: Bool { !isBusy && !isEditingTrim && validatedFilename != nil }
    var canEditTrim: Bool { !isBusy }
    var canSaveTrim: Bool { isEditingTrim && canEditTrim && validatedFilename != nil }
    var canClose: Bool { operation == nil }
    var availableCRFValues: [Int] {
        let current = processingState?.options.crf ?? 24
        return Array(Set(Array(18...40) + [current])).sorted()
    }
    var hasRecordedAudio: Bool {
        recording.audioConfiguration.microphoneEnabled
            || recording.audioConfiguration.systemAudioEnabled
    }
    var isAudioRemoved: Bool { exportAudioPreference == .removeAudio }

    var filenameErrorMessage: String? {
        guard validatedFilename == nil else { return nil }
        return "Enter a valid filename without folders or control characters."
    }

    var outputSizeDescription: String {
        guard let lastExportedByteCount else {
            let dimensions = "\(recording.pixelSize.width) × \(recording.pixelSize.height)"
            guard let bytes = recording.approximateExportByteCount else { return dimensions }
            return "\(dimensions) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
        let size = ByteCountFormatter.string(
            fromByteCount: lastExportedByteCount,
            countStyle: .file
        )
        return "Actual output: \(size)"
    }

    var dragItem: PreviewFileDragItem? {
        guard canShare, let original = makeExportRequest() else { return nil }
        let lease: (any PreviewSourceLease)?
        do { lease = try actions.acquireSourceLease(original) }
        catch {
            let details = UserFacingErrorPresentation.details(for: error)
            ClipLog.export.error("Could not retain video for a promised drag: \(details.technicalDescription, privacy: .private)")
            presentError(title: "Couldn’t Prepare Drag", message: details.message)
            return nil
        }
        let request = PreviewExportRequest(recordingID: original.recordingID,
            sourceURL: lease?.sourceURL ?? original.sourceURL,
            captureFrameRate: original.captureFrameRate, filename: original.filename,
            trimRange: original.trimRange, audioPreference: original.audioPreference,
            sourceCacheIdentity: PreviewExportCoordinator.sourceCacheIdentity(for: original))
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
            },
            sourceLease: lease
        )
    }

    func updateFilename(_ text: String) {
        guard !isBusy else { return }
        filenameText = text
        lastExportedByteCount = nil
        statusMessage = nil
    }

    func setAudioRemoved(_ removed: Bool) {
        guard !isBusy, hasRecordedAudio else { return }
        exportAudioPreference = removed ? .removeAudio : .keepAudio
        player.isMuted = removed
        lastExportedByteCount = nil
        statusMessage = nil
    }

    func updateTrimStart(_ proposedTime: TimeInterval) {
        guard !isBusy, isEditingTrim else { return }
        let maximum = max(0, trimEnd - minimumTrimDuration)
        trimStart = min(max(proposedTime, 0), maximum)
        updatePlaybackRange()
        lastExportedByteCount = nil
        statusMessage = nil
        if currentTime < trimStart {
            seek(to: trimStart)
        }
    }

    func updateTrimEnd(_ proposedTime: TimeInterval) {
        guard !isBusy, isEditingTrim else { return }
        let minimum = min(duration, trimStart + minimumTrimDuration)
        trimEnd = min(max(proposedTime, minimum), duration)
        updatePlaybackRange()
        lastExportedByteCount = nil
        statusMessage = nil
        if currentTime > trimEnd {
            seek(to: trimEnd)
        }
    }

    func resetTrim() {
        guard !isBusy, isEditingTrim else { return }
        trimStart = 0
        trimEnd = duration
        updatePlaybackRange()
        lastExportedByteCount = nil
        seek(to: 0)
        statusMessage = nil
    }

    func beginTrimEditing() {
        guard canEditTrim, !isEditingTrim else { return }
        player.pause()
        isEditingTrim = true
        statusMessage = nil
    }

    func cancelTrimEditing() {
        guard !isBusy, isEditingTrim else { return }
        restoreSavedTrim()
    }

    func saveTrim() {
        guard isEditingTrim, !isBusy else { return }
        guard let request = makeExportRequest() else {
            presentError(title: validatedFilename == nil ? "Invalid Filename" : "Couldn’t Save Trim",
                         message: filenameErrorMessage ?? "Select a valid trim range.")
            return
        }
        guard begin(.savingTrim) else { return }
        player.pause()
        let prepareExport = actions.prepareExport
        operationTask = Task { [weak self] in
            do {
                let preparedURL = try await prepareExport?(request)
                try Task.checkCancellation()
                guard let self else { return }
                self.savedTrimRange = request.trimRange
                self.isEditingTrim = false
                self.lastExportedByteCount = preparedURL.flatMap(ShareCompletionFormatting.fileByteCount(at:))
                self.completeOperation(status: "Trim saved. Ready to share.")
                self.seekPlayer(to: request.trimRange.startTime)
            } catch is CancellationError {
                self?.completeOperation(status: nil)
            } catch {
                self?.failOperation(title: "Couldn’t Save Trim", error: error)
            }
        }
    }

    private func restoreSavedTrim() {
        player.pause()
        trimStart = savedTrimRange.startTime
        trimEnd = savedTrimRange.endTime
        updatePlaybackRange()
        isEditingTrim = false
        lastExportedByteCount = nil
        statusMessage = nil
        seekPlayer(to: currentTime)
    }

    private func updatePlaybackRange() {
        player.currentItem?.reversePlaybackEndTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
    }

    func seek(to proposedTime: TimeInterval) {
        guard !isBusy else { return }
        seekPlayer(to: proposedTime)
    }

    private func seekPlayer(to proposedTime: TimeInterval) {
        let boundedTime = min(max(proposedTime, trimStart), trimEnd)
        currentTime = boundedTime
        player.seek(
            to: CMTime(seconds: boundedTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func togglePlayback() {
        guard !isBusy else { return }
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
                currentTime = min(max(observedTime, trimStart), trimEnd)
                if observedTime < trimStart || observedTime > trimEnd || (isPlaying && observedTime >= trimEnd) {
                    player.pause()
                    seekPlayer(to: trimStart)
                }
            }

            do {
                try await clock.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    /// Initial capture finalization and processing update the same visible shell.
    func updateProcessingState(_ state: PreviewProcessingState?) {
        let previousPhase = processingState?.phase
        processingState = state
        if let state {
            if state.phase.isBusy {
                closeExpandedPreview()
                player.pause()
            }
        }
        if state?.phase != previousPhase, let title = state?.phase.title, let application = NSApp {
            NSAccessibility.post(element: application, notification: .announcementRequested,
                                 userInfo: [.announcement: title, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    func replaceRecording(_ replacement: PreviewRecording, preservingEdits: Bool = true) {
        closeExpandedPreview()
        let priorTime = currentTime
        let edited = currentRecordingSnapshot()
        var value = replacement
        if preservingEdits {
            value.filename = edited.filename
            value.exportAudioPreference = edited.exportAudioPreference
            // A provisional shell has no playable timeline; its estimated
            // duration must never become a real trim on the finalized video.
            if player.currentItem != nil {
                let start = min(edited.trimRange.startTime, max(0, value.duration - 0.1))
                let requestedEnd = abs(edited.trimRange.endTime - recording.duration) < 0.000_001
                    ? value.duration : edited.trimRange.endTime
                let end = min(max(requestedEnd, start + min(0.1, value.duration)), value.duration)
                if let trim = try? TrimRange(startTime: start, endTime: end) { value.trimRange = trim }
            }
        }
        install(value)
        seekPlayer(to: preservingEdits ? priorTime : value.trimRange.startTime)
    }

    func resolutionTitle(_ scale: RecordingResolutionScale) -> String {
        let native = processingState?.nativePixelSize ?? recording.pixelSize
        let dimensions = (try? scale.pixelSize(from: native)) ?? native
        let name = scale == .native ? "Native" : "\(scale.percent)%"
        return "\(name) · \(dimensions.width) × \(dimensions.height)"
    }

    func selectResolution(_ scale: RecordingResolutionScale) {
        guard canEditProcessing, var options = processingState?.options else { return }
        options.scale = scale
        requestProcessing(options)
    }

    func selectCRF(_ value: Int) {
        guard canEditProcessing, var options = processingState?.options,
              availableCRFValues.contains(value), value != options.crf else { return }
        options.crf = value
        requestProcessing(options)
    }

    func retryProcessing() {
        guard canEditProcessing, let options = processingState?.options else { return }
        requestProcessing(options, force: true)
    }

    private func requestProcessing(_ options: RecordingProcessingOptions, force: Bool = false) {
        guard canEditProcessing, let process = actions.process, let state = processingState,
              force || options != state.options else { return }
        closeExpandedPreview()
        player.pause()
        let snapshot = currentRecordingSnapshot()
        let generation = UUID()
        processingGeneration = generation
        var preparing = state
        preparing.options = options; preparing.phase = .preparing; preparing.progress = nil; preparing.message = nil
        updateProcessingState(preparing)
        statusMessage = nil
        processingTask = Task { [weak self] in
            do {
                let replacement = try await process(options, snapshot) { [weak self] phase, progress in
                    guard let self, self.processingGeneration == generation, var current = self.processingState else { return }
                    current.phase = phase; current.progress = progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
                    self.updateProcessingState(current)
                }
                guard let self, self.processingGeneration == generation else { return }
                self.replaceRecording(replacement)
                if let prepareExport = self.actions.prepareExport,
                   self.trimStart > 0 || self.trimEnd < self.duration,
                   let request = self.makeExportRequest() {
                    var finishing = preparing
                    finishing.phase = .finishing; finishing.progress = nil
                    self.updateProcessingState(finishing)
                    let preparedURL = try await prepareExport(request)
                    try Task.checkCancellation()
                    guard self.processingGeneration == generation else { return }
                    self.lastExportedByteCount = ShareCompletionFormatting.fileByteCount(at: preparedURL)
                }
                var ready = preparing
                ready.phase = .ready; ready.progress = 1
                self.updateProcessingState(ready)
                self.actions.processingOptionsChanged(options)
                self.processingTask = nil
            } catch {
                guard let self, self.processingGeneration == generation else { return }
                var failed = preparing
                failed.phase = .failed; failed.progress = nil
                failed.message = UserFacingErrorPresentation.details(for: error).message
                self.updateProcessingState(failed)
                self.processingTask = nil
            }
        }
    }

    func showExpandedPreview() {
        guard !isBusy, player.currentItem != nil else { return }
        if let expandedPlayer { expandedPlayer.show(); return }
        let controller = PreviewExpandedPlayerController(player: player, title: filenameText,
                                                        editorWindow: editorWindow) { [weak self] in
            self?.expandedPlayer = nil
            self?.isExpandedPreviewPresented = false
        }
        expandedPlayer = controller
        isExpandedPreviewPresented = true
        controller.show()
    }

    func closeExpandedPreview(restoringEditor: Bool = true) {
        expandedPlayer?.close(restoringEditor: restoringEditor)
        expandedPlayer = nil
        isExpandedPreviewPresented = false
    }

    func copy() {
        guard !isBusy, !isEditingTrim, begin(.copying), let request = makeExportRequest() else { return }
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
        guard !isBusy, !isEditingTrim, begin(.saving), let request = makeExportRequest() else { return }
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
                guard !Task.isCancelled else {
                    if let result { await result.discardReplacement() }
                    self?.completeOperation(status: nil)
                    return
                }
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
        guard canClose else { return }
        if isEditingTrim { restoreSavedTrim() }
        dismissAlert()
        operation = .closing
        statusMessage = nil
        closeExpandedPreview(restoringEditor: false)
        player.pause()
        let done = actions.done
        operationTask = Task { [weak self] in
            do {
                guard let self else { return }
                await self.processingTask?.value
                // Initial processing belongs to the coordinator, whereas later
                // requests belong to this model. Both settle before close.
                while self.isProcessing {
                    try await Task.sleep(for: .milliseconds(40))
                }
                try await done(self.currentRecordingSnapshot())
                guard !Task.isCancelled else { return }
                self.completeOperation(status: nil)
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
        if let nativeErrorAlert {
            self.nativeErrorAlert = nil
            nativeErrorAlert.window.sheetParent?.endSheet(nativeErrorAlert.window)
            nativeErrorAlert.window.orderOut(nil)
        }
    }

    /// Gives application termination a bounded ownership handoff point. The
    /// caller first resolves any coordinator-owned Retake continuation, then
    /// waits for in-flight Preview work before persisting this final snapshot.
    func settleForTermination() async {
        closeExpandedPreview(restoringEditor: false)
        player.pause()
        dismissAlert()
        await processingTask?.value
        let pendingTask = operationTask
        await pendingTask?.value
        operationTask = nil
        operation = nil
        if isEditingTrim { restoreSavedTrim() }
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
            audioPreference: exportAudioPreference
        )
    }

    private func currentRecordingSnapshot() -> PreviewRecording {
        guard let request = makeExportRequest() else { return recording }
        var snapshot = recording
        snapshot.filename = request.filename
        snapshot.trimRange = isEditingTrim ? savedTrimRange : request.trimRange
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
        let diagnosticError = error as NSError
        ClipLog.lifecycle.error("Preview error type=\(String(reflecting: type(of: error)), privacy: .public) code=\(diagnosticError.code, privacy: .public)")
        ClipLog.lifecycle.error(
            "Preview operation failed (\(title, privacy: .public)): \(details.technicalDescription, privacy: .private)"
        )
        presentError(title: title, message: details.message)
    }

    private func presentError(title: String, message: String) {
        dismissAlert()
        let presentation = PreviewAlert(title: title, message: message)
        alert = presentation
        guard let editorWindow else { return }
        let sheet = NSAlert()
        sheet.alertStyle = .warning
        sheet.messageText = title
        sheet.informativeText = message
        sheet.addButton(withTitle: "OK")
        // AppKit keeps an attached sheet in its floating parent's window group,
        // so the alert receives mouse events without a separate SwiftUI overlay.
        nativeErrorAlert = sheet
        sheet.beginSheetModal(for: editorWindow) { [weak self] _ in
            guard let self, self.alert?.id == presentation.id else { return }
            self.nativeErrorAlert = nil
            self.alert = nil
        }
    }

    @discardableResult
    private func handleShareOutcome(
        _ outcome: PreviewShareOutcome,
        verb: String,
        defaultStatus: String? = nil
    ) -> String? {
        lastSharedFileURL = outcome.outputURL
        lastExportedByteCount = ShareCompletionFormatting.fileByteCount(at: outcome.outputURL)
        let success = defaultStatus ?? "\(verb) \(outcome.outputURL.lastPathComponent)"
        let resolvedStatus: String?
        if let warning = outcome.postShareWarning {
            resolvedStatus = "\(success) — \(warning)"
        } else {
            resolvedStatus = success
        }
        statusMessage = resolvedStatus
        return resolvedStatus
    }

    private func install(_ replacement: PreviewRecording) {
        closeExpandedPreview()
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: replacement.sourceURL))
        player.actionAtItemEnd = .pause

        recording = replacement
        lastSharedFileURL = nil
        lastExportedByteCount = nil
        filenameText = replacement.filename.stem
        trimStart = replacement.trimRange.startTime
        trimEnd = replacement.trimRange.endTime
        savedTrimRange = replacement.trimRange
        isEditingTrim = false
        currentTime = replacement.trimRange.startTime
        exportAudioPreference = replacement.exportAudioPreference
        player.isMuted = !replacement.exportAudioPreference.includesAudio
        updatePlaybackRange()

        seekPlayer(to: replacement.trimRange.startTime)
    }
}
