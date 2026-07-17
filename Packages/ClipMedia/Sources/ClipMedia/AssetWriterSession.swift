@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

public enum CapturedAudioSource: String, CaseIterable, Hashable, Sendable {
    case systemAudio
    case microphone
}

public enum CapturedSampleKind: Hashable, Sendable {
    case video
    case systemAudio
    case microphone

    var audioSource: CapturedAudioSource? {
        switch self {
        case .video: nil
        case .systemAudio: .systemAudio
        case .microphone: .microphone
        }
    }
}

public enum AssetWriterSessionError: Error, Sendable {
    case cannotCreateWriter(String)
    case cannotCreateEncoder(String)
    case cannotAddVideoInput
    case cannotAddSystemAudioInput
    case cannotAddMicrophoneInput
    case cannotStartWriting(String)
    case appendFailed(String)
    case finishFailed(String)
}

/// Keeps real-time input backpressure separate from terminal writer failure.
///
/// `AVAssetWriterInput.isReadyForMoreMediaData` can be `false` while a healthy
/// writer is applying transient backpressure, but it also becomes `false` when
/// the writer has already failed or otherwise terminated. The latter must be
/// surfaced immediately so capture can stop and preserve any playable output.
enum AssetWriterAppendReadiness {
    static func permitsAppend(
        writerStatus: AVAssetWriter.Status,
        inputIsReady: Bool
    ) throws -> Bool {
        switch writerStatus {
        case .unknown, .writing:
            return inputIsReady
        case .failed:
            throw AssetWriterSessionError.appendFailed(
                "The recording writer failed before accepting a sample."
            )
        case .cancelled:
            throw AssetWriterSessionError.appendFailed(
                "The recording writer was cancelled before accepting a sample."
            )
        case .completed:
            throw AssetWriterSessionError.appendFailed(
                "The recording writer completed before accepting a sample."
            )
        @unknown default:
            throw AssetWriterSessionError.appendFailed(
                "The recording writer entered an unsupported state before accepting a sample."
            )
        }
    }
}

/// Polls a video input without retaining the writer-state lock between checks.
/// Audio callbacks can therefore advance AVAssetWriter's cross-track
/// interleaver while video is under transient backpressure.
enum AssetWriterVideoReadinessPoller {
    enum Decision: Equatable, Sendable {
        case ready
        case wait
        case cancelled
    }

    enum Outcome: Equatable, Sendable {
        case ready
        case cancelled
        case timedOut
    }

    static func wait(
        until deadline: Date,
        check: () throws -> Decision,
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.001) }
    ) rethrows -> Outcome {
        while true {
            switch try check() {
            case .ready:
                return .ready
            case .cancelled:
                return .cancelled
            case .wait:
                guard Date() < deadline else {
                    return .timedOut
                }
                pause()
            }
        }
    }
}

/// Maps capture time into the video-anchored writer timeline while enforcing
/// AVAssetWriter's strictly increasing per-input presentation timestamps.
enum AssetWriterTimestampPolicy {
    enum Classification: Equatable, Sendable {
        case accepted(CMTime)
        case invalid
        case preRoll
        case nonmonotonic
    }

    static func classify(
        outputTime: CMTime,
        firstSourceTime: CMTime,
        lastAppended: CMTime?
    ) -> Classification {
        guard outputTime.isNumeric, firstSourceTime.isNumeric else {
            return .invalid
        }
        guard outputTime >= firstSourceTime else {
            return .preRoll
        }
        let relativeTime = outputTime - firstSourceTime
        if let lastAppended, relativeTime <= lastAppended {
            return .nonmonotonic
        }
        return .accepted(relativeTime)
    }

    static func relativeOutputTime(
        outputTime: CMTime,
        firstSourceTime: CMTime,
        lastAppended: CMTime?
    ) -> CMTime? {
        guard case let .accepted(relativeTime) = classify(
            outputTime: outputTime,
            firstSourceTime: firstSourceTime,
            lastAppended: lastAppended
        ) else {
            return nil
        }
        return relativeTime
    }
}

enum AssetWriterIntentionalDropReason: Equatable, Sendable {
    case sessionInactive
    case paused
    case preRoll
    case optionalAudioDisabled
    case optionalAudioUnavailable
    case optionalAudioInvalid
    case optionalAudioNonmonotonic
    case optionalAudioBackpressure

    func isExpected(for kind: CapturedSampleKind) -> Bool {
        switch (kind, self) {
        case (.video, .sessionInactive),
             (.video, .paused):
            true
        case (.systemAudio, _), (.microphone, _):
            true
        case (.video, _):
            false
        }
    }
}

enum AssetWriterAppendOutcome: Equatable, Sendable {
    case appended
    case intentionallyDropped(AssetWriterIntentionalDropReason)

    var didAppend: Bool {
        self == .appended
    }
}

/// Bridges a single missed ScreenCaptureKit scheduling interval without ever
/// moving an original capture timestamp. Ordinary gaps in `(2Δ, 3Δ]` receive
/// one held frame at `previous + Δ`; larger ordinary gaps remain intentional
/// VFR timing so static/sparse capture never creates an encoding burst. The
/// first post-resume seam is stricter: a gap above `3Δ` is anomalous and fails
/// visibly rather than hiding a broken pause transition.
struct LiveVideoCadencePolicy: Equatable, Sendable {
    enum PolicyError: Error, Equatable, LocalizedError, Sendable {
        case gapExceedsRepairLimit

        var errorDescription: String? {
            switch self {
            case .gapExceedsRepairLimit:
                "Screen capture did not resume within the recoverable video cadence window."
            }
        }
    }

    let nominalFrameDuration: CMTime
    let maximumFrameGap: CMTime

    init(framesPerSecond: Int) {
        precondition(framesPerSecond > 0)
        nominalFrameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(framesPerSecond)
        )
        maximumFrameGap = CMTime(
            value: 2,
            timescale: CMTimeScale(framesPerSecond)
        )
    }

    func heldFramePresentationTime(
        previous: CMTime,
        current: CMTime,
        isResumeSeam: Bool
    ) throws -> CMTime? {
        guard previous.isValid,
              previous.isNumeric,
              current.isValid,
              current.isNumeric,
              current > previous,
              current - previous > maximumFrameGap else {
            return nil
        }

        let heldFrameTime = previous + nominalFrameDuration
        guard current - heldFrameTime <= maximumFrameGap else {
            if isResumeSeam {
                throw PolicyError.gapExceedsRepairLimit
            }
            return nil
        }
        return heldFrameTime
    }
}

/// Serializes AVAssetWriter access while allowing ScreenCaptureKit to deliver
/// video and audio on separate callback queues.
public final class AssetWriterSession: @unchecked Sendable {
    private enum FinalizationState {
        case accepting
        case finishing
        case completed
        case failed
        case cancelled

        var acceptsNewSamples: Bool {
            if case .accepting = self { return true }
            return false
        }

        var permitsAdmittedVideoAppend: Bool {
            switch self {
            case .accepting, .finishing: true
            case .completed, .failed, .cancelled: false
            }
        }
    }

    private enum SampleAdmission {
        case accepted(
            presentationTime: CMTime,
            completesResumeCadenceSeam: Bool
        )
        case dropped(AssetWriterIntentionalDropReason)
    }

    private struct RetainedVideoFrame {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
    }

    public let outputURL: URL

    private let writer: AVAssetWriter
    private let encoder: VideoToolboxH264Encoder
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let defaultFrameDuration: CMTime
    private let liveVideoCadencePolicy: LiveVideoCadencePolicy
    private let muxerBackpressureTimeout: TimeInterval
    private let finalizationBarrier: (@Sendable () -> Void)?
    private let lock = NSCondition()
    private let videoAppendLock = NSLock()

    private var videoInput: AVAssetWriterInput?
    private var timeline = SampleTimeline()
    private var hasStarted = false
    private var hasStartedWriting = false
    private var hasStartedSession = false
    private var finalizationState: FinalizationState = .accepting
    private var finalizationTask: Task<URL, any Error>?
    private var admittedVideoAppendCount = 0
    private var isEstablishingWriter = false
    private var firstTimelineTime: CMTime?
    private var pendingVideoResumeSourceTime: CMTime?
    private var lastAppendedOutputTimes: [CapturedSampleKind: CMTime] = [:]
    /// Exactly one raw frame is retained transiently. It supplies the held
    /// image for a bounded cadence gap (including a resume seam), then is
    /// replaced by the next accepted original frame.
    private var retainedVideoFrame: RetainedVideoFrame?
    private var disabledAudioSources: Set<CapturedAudioSource> = []
    private var finishedAudioSources: Set<CapturedAudioSource> = []

    public convenience init(
        outputURL: URL,
        configuration: RecordingConfiguration
    ) throws {
        try self.init(
            outputURL: outputURL,
            configuration: configuration,
            finalizationBarrier: nil
        )
    }

    init(
        outputURL: URL,
        configuration: RecordingConfiguration,
        finalizationBarrier: (@Sendable () -> Void)?
    ) throws {
        self.outputURL = outputURL
        self.finalizationBarrier = finalizationBarrier
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw AssetWriterSessionError.cannotCreateWriter(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        defaultFrameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.framesPerSecond)
        )
        liveVideoCadencePolicy = LiveVideoCadencePolicy(
            framesPerSecond: configuration.framesPerSecond
        )
        muxerBackpressureTimeout = max(
            0.25,
            2.0 / Double(configuration.framesPerSecond)
        )
        do {
            encoder = try VideoToolboxH264Encoder(
                configuration: .liveMaster(recording: configuration)
            )
        } catch {
            throw AssetWriterSessionError.cannotCreateEncoder(
                Self.encoderErrorDescription(error)
            )
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]

        if configuration.audioMode.capturesSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw AssetWriterSessionError.cannotAddSystemAudioInput
            }
            writer.add(input)
            systemAudioInput = input
        } else {
            systemAudioInput = nil
        }

        if configuration.audioMode.capturesMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw AssetWriterSessionError.cannotAddMicrophoneInput
            }
            writer.add(input)
            microphoneInput = input
        } else {
            microphoneInput = nil
        }
    }

    public func start() throws {
        try lock.withLock {
            guard !hasStarted else { return }
            guard finalizationState.acceptsNewSamples else {
                throw AssetWriterSessionError.cannotStartWriting(
                    "The recording was already finalized."
                )
            }
            // AVAssetWriter cannot add a passthrough input after it starts.
            // Starting is therefore deferred until VideoToolbox returns the
            // first compressed sample and its H.264 format description.
            hasStarted = true
        }
    }

    /// Returns `false` for paused/pre-roll samples and optional-audio rejection.
    /// Invalid or nonmonotonic live video and sustained encoder/muxer stalls
    /// throw instead of silently dropping a complete screen frame.
    @discardableResult
    public func append(_ sampleBuffer: CMSampleBuffer, kind: CapturedSampleKind) throws -> Bool {
        try appendClassified(sampleBuffer, kind: kind).didAppend
    }

    @discardableResult
    func appendClassified(
        _ sampleBuffer: CMSampleBuffer,
        kind: CapturedSampleKind
    ) throws -> AssetWriterAppendOutcome {
        switch kind {
        case .video:
            return try appendVideoClassified(sampleBuffer)
        case .systemAudio:
            return try appendAudioClassified(
                sampleBuffer,
                to: systemAudioInput,
                kind: .systemAudio
            )
        case .microphone:
            return try appendAudioClassified(
                sampleBuffer,
                to: microphoneInput,
                kind: .microphone
            )
        }
    }

    private func appendVideoClassified(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> AssetWriterAppendOutcome {
        videoAppendLock.lock()
        defer { videoAppendLock.unlock() }

        let prepared: (
            reason: AssetWriterIntentionalDropReason?,
            pixelBuffer: CVPixelBuffer?,
            presentationTime: CMTime,
            duration: CMTime,
            completesResumeCadenceSeam: Bool
        ) = try lock.withLock {
            switch try admission(for: sampleBuffer, kind: .video) {
            case let .dropped(reason):
                return (
                    reason,
                    nil as CVPixelBuffer?,
                    CMTime.invalid,
                    CMTime.invalid,
                    false
                )
            case let .accepted(relativeOutputTime, completesResumeCadenceSeam):
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    throw AssetWriterSessionError.appendFailed(
                        "The screen frame did not contain a pixel buffer."
                    )
                }
                let sourceDuration = CMSampleBufferGetDuration(sampleBuffer)
                let duration = sourceDuration.isValid && sourceDuration.isNumeric
                    ? sourceDuration
                    : defaultFrameDuration
                admittedVideoAppendCount += 1
                if !hasStartedWriting {
                    isEstablishingWriter = true
                }
                return (
                    nil,
                    pixelBuffer,
                    relativeOutputTime,
                    duration,
                    completesResumeCadenceSeam
                )
            }
        }
        if let reason = prepared.reason {
            return .intentionallyDropped(reason)
        }
        guard let pixelBuffer = prepared.pixelBuffer else {
            throw AssetWriterSessionError.appendFailed(
                "The screen frame did not contain a pixel buffer."
            )
        }
        defer { completeAdmittedVideoAppend() }

        do {
            guard try appendPendingCompressedVideo(), admittedVideoAppendIsPermitted() else {
                return .intentionallyDropped(.sessionInactive)
            }
            guard try appendHeldCadenceFrameIfNeeded(
                before: prepared.presentationTime,
                isResumeSeam: prepared.completesResumeCadenceSeam
            ) else {
                return .intentionallyDropped(.sessionInactive)
            }
            guard admittedVideoAppendIsPermitted() else {
                return .intentionallyDropped(.sessionInactive)
            }
            try encoder.encode(
                pixelBuffer,
                presentationTime: prepared.presentationTime,
                duration: prepared.duration
            )
            lock.withLock {
                lastAppendedOutputTimes[.video] = prepared.presentationTime
            }
            let needsFirstOutput = lock.withLock { !hasStartedWriting }
            if needsFirstOutput {
                try encoder.waitForFirstOutput()
            }
            guard try appendPendingCompressedVideo() else {
                return .intentionallyDropped(.sessionInactive)
            }
            retainedVideoFrame = RetainedVideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: prepared.presentationTime
            )
            return .appended
        } catch let error as AssetWriterSessionError {
            throw error
        } catch {
            throw AssetWriterSessionError.appendFailed(
                Self.encoderErrorDescription(error)
            )
        }
    }

    private func appendAudioClassified(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput?,
        kind: CapturedSampleKind
    ) throws -> AssetWriterAppendOutcome {
        try lock.withLock {
            switch try admission(for: sampleBuffer, kind: kind) {
            case let .dropped(reason):
                return .intentionallyDropped(reason)
            case let .accepted(relativeOutputTime, _):
                while !hasStartedWriting,
                      isEstablishingWriter,
                      finalizationState.acceptsNewSamples {
                    lock.wait()
                }
                guard finalizationState.acceptsNewSamples else {
                    return .intentionallyDropped(.sessionInactive)
                }
                if let audioSource = kind.audioSource,
                   disabledAudioSources.contains(audioSource) {
                    return .intentionallyDropped(.optionalAudioDisabled)
                }
                return try appendAudio(
                    sampleBuffer,
                    to: input,
                    kind: kind,
                    at: relativeOutputTime
                )
            }
        }
    }

    /// Must be called with `lock` held.
    private func admission(
        for sampleBuffer: CMSampleBuffer,
        kind: CapturedSampleKind
    ) throws -> SampleAdmission {
        guard hasStarted, finalizationState.acceptsNewSamples else {
            return .dropped(.sessionInactive)
        }
        if let audioSource = kind.audioSource,
           disabledAudioSources.contains(audioSource) {
            return .dropped(.optionalAudioDisabled)
        }
        guard sampleBuffer.isValid else {
            if kind == .video {
                throw AssetWriterSessionError.appendFailed(
                    "The screen frame was invalid."
                )
            }
            return .dropped(.optionalAudioInvalid)
        }

        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard sourceTime.isValid, sourceTime.isNumeric else {
            if kind == .video {
                throw AssetWriterSessionError.appendFailed(
                    "The screen frame had an invalid presentation timestamp."
                )
            }
            return .dropped(.optionalAudioInvalid)
        }
        guard let outputTime = timeline.outputTime(for: sourceTime) else {
            return .dropped(.paused)
        }

        if firstTimelineTime == nil {
            guard kind == .video else {
                return .dropped(.preRoll)
            }
            // Anchor in the pause-adjusted timeline, not raw capture time.
            firstTimelineTime = outputTime
        }
        guard let firstTimelineTime else {
            return .dropped(.preRoll)
        }

        switch AssetWriterTimestampPolicy.classify(
            outputTime: outputTime,
            firstSourceTime: firstTimelineTime,
            lastAppended: lastAppendedOutputTimes[kind]
        ) {
        case let .accepted(relativeOutputTime):
            let completesResumeCadenceSeam: Bool
            if kind == .video,
               let resumeSourceTime = pendingVideoResumeSourceTime,
               sourceTime >= resumeSourceTime {
                pendingVideoResumeSourceTime = nil
                completesResumeCadenceSeam = true
            } else {
                completesResumeCadenceSeam = false
            }
            return .accepted(
                presentationTime: relativeOutputTime,
                completesResumeCadenceSeam: completesResumeCadenceSeam
            )
        case .preRoll:
            if kind == .video {
                throw AssetWriterSessionError.appendFailed(
                    "The screen frame presentation timestamp preceded the recording anchor."
                )
            }
            return .dropped(.preRoll)
        case .invalid:
            if kind == .video {
                throw AssetWriterSessionError.appendFailed(
                    "The screen frame had an invalid presentation timestamp."
                )
            }
            return .dropped(.optionalAudioInvalid)
        case .nonmonotonic:
            if kind == .video {
                throw AssetWriterSessionError.appendFailed(
                    "The screen frame presentation timestamp did not advance."
                )
            }
            return .dropped(.optionalAudioNonmonotonic)
        }
    }

    private func admittedVideoAppendIsPermitted() -> Bool {
        lock.withLock { finalizationState.permitsAdmittedVideoAppend }
    }

    private func completeAdmittedVideoAppend() {
        let shouldInvalidate = lock.withLock { () -> Bool in
            admittedVideoAppendCount = max(0, admittedVideoAppendCount - 1)
            if admittedVideoAppendCount == 0, !hasStartedWriting {
                isEstablishingWriter = false
            }
            lock.broadcast()
            if case .cancelled = finalizationState {
                return admittedVideoAppendCount == 0
            }
            return false
        }
        if shouldInvalidate {
            encoder.invalidate()
        }
    }

    /// Stops accepting one optional audio source without ending the writer.
    /// Video and the other audio input remain active. Returning `false` means
    /// the source was absent, already disabled, or the writer was terminal.
    @discardableResult
    func disableAudioSource(_ source: CapturedAudioSource) -> Bool {
        lock.withLock {
            guard hasStarted,
                  finalizationState.acceptsNewSamples,
                  audioInput(for: source) != nil,
                  disabledAudioSources.insert(source).inserted else {
                return false
            }
            if hasStartedSession {
                markAudioInputAsFinished(source)
            }
            return true
        }
    }

    public func pause(at sourceTime: CMTime) throws {
        try lock.withLock {
            try timeline.pause(at: sourceTime)
            // A newer pause supersedes an unconsumed seam from an earlier
            // resume. Only the next successful resume may request completion.
            pendingVideoResumeSourceTime = nil
        }
    }

    public func resume(at sourceTime: CMTime) throws {
        try lock.withLock {
            try timeline.resume(at: sourceTime)
            pendingVideoResumeSourceTime = sourceTime
        }
    }

    public func finish() async throws -> URL {
        let task = lock.withLock { () -> Task<URL, any Error>? in
            if let finalizationTask {
                return finalizationTask
            }
            guard finalizationState.acceptsNewSamples else {
                return nil
            }
            finalizationState = .finishing
            lock.broadcast()
            let task = Task.detached { [self] in
                try await performFinalization()
            }
            finalizationTask = task
            return task
        }
        guard let task else {
            throw Self.finalizationCancelledError()
        }
        return try await task.value
    }

    public func cancelAndRemoveOutput() {
        let action = lock.withLock { () -> (remove: Bool, invalidateEncoder: Bool) in
            switch finalizationState {
            case .accepting:
                finalizationState = .cancelled
                lock.broadcast()
                writer.cancelWriting()
                return (true, admittedVideoAppendCount == 0)
            case .finishing:
                finalizationState = .cancelled
                // AVAssetWriter documents that a pending asynchronous finish
                // completes when cancellation occurs. All append calls remain
                // serialized by this condition while cancellation begins.
                writer.cancelWriting()
                lock.broadcast()
                return (true, false)
            case .failed, .cancelled:
                return (true, false)
            case .completed:
                return (false, false)
            }
        }
        if action.invalidateEncoder {
            encoder.invalidate()
        }
        clearRetainedVideoFrame()
        if action.remove {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private func performFinalization() async throws -> URL {
        defer { clearRetainedVideoFrame() }
        do {
            finalizationBarrier?()
            try waitForAdmittedVideoAppends()
            let finalSamples = try encoder.completeFrames()
            guard try appendCompressedVideoSamples(finalSamples) else {
                throw Self.finalizationCancelledError()
            }
            try lock.withLock {
                guard case .finishing = finalizationState else {
                    throw Self.finalizationCancelledError()
                }
                guard hasStartedWriting, let videoInput else {
                    throw AssetWriterSessionError.finishFailed(
                        "The H.264 encoder produced no video samples."
                    )
                }
                videoInput.markAsFinished()
                for source in CapturedAudioSource.allCases {
                    markAudioInputAsFinished(source)
                }
            }

            guard await beginFinishingWriterIfPermitted() else {
                throw Self.finalizationCancelledError()
            }
            return try lock.withLock {
                guard case .finishing = finalizationState else {
                    throw Self.finalizationCancelledError()
                }
                guard writer.status == .completed else {
                    throw AssetWriterSessionError.finishFailed(
                        writer.error?.localizedDescription ?? "AVAssetWriter did not complete"
                    )
                }
                finalizationState = .completed
                return outputURL
            }
        } catch {
            encoder.invalidate()
            let normalizedError: AssetWriterSessionError
            if let error = error as? AssetWriterSessionError {
                normalizedError = error
            } else {
                normalizedError = .finishFailed(Self.encoderErrorDescription(error))
            }
            let wasCancelled = lock.withLock { () -> Bool in
                if case .cancelled = finalizationState {
                    return true
                }
                if case .finishing = finalizationState {
                    finalizationState = .failed
                    writer.cancelWriting()
                }
                return false
            }
            try? FileManager.default.removeItem(at: outputURL)
            if wasCancelled {
                throw Self.finalizationCancelledError()
            }
            throw normalizedError
        }
    }

    private func waitForAdmittedVideoAppends() throws {
        lock.lock()
        defer { lock.unlock() }
        while admittedVideoAppendCount > 0 {
            guard case .finishing = finalizationState else {
                throw Self.finalizationCancelledError()
            }
            lock.wait()
        }
        guard case .finishing = finalizationState else {
            throw Self.finalizationCancelledError()
        }
    }

    private func beginFinishingWriterIfPermitted() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.withLock {
                guard case .finishing = finalizationState else {
                    continuation.resume(returning: false)
                    return
                }
                writer.finishWriting {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    private static func finalizationCancelledError() -> AssetWriterSessionError {
        .finishFailed("Recording finalization was cancelled.")
    }

    private func clearRetainedVideoFrame() {
        videoAppendLock.withLock {
            retainedVideoFrame = nil
        }
    }

    private func audioInput(for source: CapturedAudioSource) -> AVAssetWriterInput? {
        switch source {
        case .systemAudio: systemAudioInput
        case .microphone: microphoneInput
        }
    }

    private func markAudioInputAsFinished(_ source: CapturedAudioSource) {
        guard !finishedAudioSources.contains(source),
              let input = audioInput(for: source) else {
            return
        }
        input.markAsFinished()
        finishedAudioSources.insert(source)
    }

    private func appendAudio(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput?,
        kind: CapturedSampleKind,
        at relativeOutputTime: CMTime
    ) throws -> AssetWriterAppendOutcome {
        guard hasStartedWriting, hasStartedSession, let input else {
            return .intentionallyDropped(.optionalAudioUnavailable)
        }
        guard let retimed = try sampleBuffer.retimed(to: relativeOutputTime) else {
            return .intentionallyDropped(.optionalAudioInvalid)
        }
        guard try AssetWriterAppendReadiness.permitsAppend(
            writerStatus: writer.status,
            inputIsReady: input.isReadyForMoreMediaData
        ) else {
            return .intentionallyDropped(.optionalAudioBackpressure)
        }
        guard input.append(retimed) else {
            throw AssetWriterSessionError.appendFailed(
                writer.error?.localizedDescription ?? "AVAssetWriterInput rejected an audio sample"
            )
        }
        lastAppendedOutputTimes[kind] = relativeOutputTime
        return .appended
    }

    private func appendPendingCompressedVideo() throws -> Bool {
        do {
            return try appendCompressedVideoSamples(encoder.drainCompressedSamples())
        } catch let error as AssetWriterSessionError {
            throw error
        } catch {
            throw AssetWriterSessionError.appendFailed(
                Self.encoderErrorDescription(error)
            )
        }
    }

    /// Inserts at most one retained frame for a bounded scheduling gap. The
    /// policy operates on pause-adjusted output times, so paused wall-clock
    /// duration is never encoded into the MP4.
    private func appendHeldCadenceFrameIfNeeded(
        before currentPresentationTime: CMTime,
        isResumeSeam: Bool
    ) throws -> Bool {
        guard let retainedVideoFrame,
              let heldPresentationTime = try liveVideoCadencePolicy
                .heldFramePresentationTime(
                    previous: retainedVideoFrame.presentationTime,
                    current: currentPresentationTime,
                    isResumeSeam: isResumeSeam
                ) else {
            return true
        }
        guard admittedVideoAppendIsPermitted() else {
            return false
        }

        try encoder.encode(
            retainedVideoFrame.pixelBuffer,
            presentationTime: heldPresentationTime,
            duration: defaultFrameDuration
        )
        return try appendPendingCompressedVideo()
    }

    private func appendCompressedVideoSamples(_ samples: [CMSampleBuffer]) throws -> Bool {
        for sample in samples {
            let deadline = Date(timeIntervalSinceNow: muxerBackpressureTimeout)
            let readinessOutcome = try AssetWriterVideoReadinessPoller.wait(
                until: deadline
            ) {
                try lock.withLock { () throws -> AssetWriterVideoReadinessPoller.Decision in
                    guard finalizationState.permitsAdmittedVideoAppend else {
                        return .cancelled
                    }
                    if videoInput == nil {
                        guard let formatDescription = CMSampleBufferGetFormatDescription(sample) else {
                            throw AssetWriterSessionError.appendFailed(
                                "VideoToolbox returned H.264 without a format description."
                            )
                        }
                        let input = AVAssetWriterInput(
                            mediaType: .video,
                            outputSettings: nil,
                            sourceFormatHint: formatDescription
                        )
                        input.expectsMediaDataInRealTime = true
                        guard writer.canAdd(input) else {
                            throw AssetWriterSessionError.cannotAddVideoInput
                        }
                        writer.add(input)
                        videoInput = input

                        guard writer.startWriting() else {
                            throw AssetWriterSessionError.cannotStartWriting(
                                writer.error?.localizedDescription
                                    ?? "AVAssetWriter rejected the compressed H.264 stream."
                            )
                        }
                        hasStartedWriting = true
                        isEstablishingWriter = false
                        lock.broadcast()
                        writer.startSession(atSourceTime: .zero)
                        hasStartedSession = true
                        for source in disabledAudioSources {
                            markAudioInputAsFinished(source)
                        }
                    }

                    guard let videoInput else {
                        throw AssetWriterSessionError.cannotAddVideoInput
                    }
                    guard try AssetWriterAppendReadiness.permitsAppend(
                        writerStatus: writer.status,
                        inputIsReady: videoInput.isReadyForMoreMediaData
                    ) else {
                        return .wait
                    }
                    guard videoInput.append(sample) else {
                        throw AssetWriterSessionError.appendFailed(
                            writer.error?.localizedDescription
                                ?? "AVAssetWriterInput rejected compressed H.264."
                        )
                    }
                    return .ready
                }
            }
            switch readinessOutcome {
            case .ready:
                break
            case .cancelled:
                return false
            case .timedOut:
                throw AssetWriterSessionError.appendFailed(
                    "The MP4 muxer could not keep up with the H.264 encoder."
                )
            }
        }
        return lock.withLock { finalizationState.permitsAdmittedVideoAppend }
    }

    private static func encoderErrorDescription(_ error: Error) -> String {
        switch error {
        case let error as VideoToolboxH264Encoder.EncoderError:
            switch error {
            case let .cannotCreate(status):
                return "The hardware H.264 encoder could not be created (\(status))."
            case let .cannotSetProperty(name, status):
                return "The hardware H.264 encoder rejected \(name) (\(status))."
            case let .cannotPrepare(status):
                return "The hardware H.264 encoder could not prepare (\(status))."
            case let .rejectedFrame(status):
                return "The hardware H.264 encoder rejected a screen frame (\(status))."
            case .droppedFrame:
                return "The hardware H.264 encoder dropped a screen frame."
            case .missingCompressedSample:
                return "The hardware H.264 encoder returned no compressed frame."
            case .backpressureExceeded:
                return "The hardware H.264 encoder could not keep up with capture."
            case let .cannotComplete(status):
                return "The hardware H.264 encoder could not finish (\(status))."
            }
        default:
            return error.localizedDescription
        }
    }
}

extension AssetWriterSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .cannotCreateWriter(message),
             let .cannotCreateEncoder(message),
             let .cannotStartWriting(message),
             let .appendFailed(message),
             let .finishFailed(message):
            return message
        case .cannotAddVideoInput:
            return "The MP4 writer could not accept compressed H.264 video."
        case .cannotAddSystemAudioInput:
            return "The MP4 writer could not accept system audio."
        case .cannotAddMicrophoneInput:
            return "The MP4 writer could not accept microphone audio."
        }
    }
}

private extension CMSampleBuffer {
    func retimed(to outputPresentationTime: CMTime) throws -> CMSampleBuffer? {
        var timingCount = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            self,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        guard countStatus == noErr, timingCount > 0 else { return nil }

        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingCount
        )
        let fillStatus = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                self,
                entryCount: timingCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: &timingCount
            )
        }
        guard fillStatus == noErr else { return nil }

        let originalPresentationTime = CMSampleBufferGetPresentationTimeStamp(self)
        let shift = outputPresentationTime - originalPresentationTime
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + shift
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + shift
            }
        }

        var output: CMSampleBuffer?
        let copyStatus = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: self,
                sampleTimingEntryCount: timingCount,
                sampleTimingArray: buffer.baseAddress,
                sampleBufferOut: &output
            )
        }
        guard copyStatus == noErr else { return nil }
        return output
    }
}
