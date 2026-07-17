import Foundation

public enum RecordingTimeError: Error, Equatable, Sendable {
    case invalidInstant(TimeInterval)
    case timeMovedBackwards(previous: TimeInterval, current: TimeInterval)
    case samplePredatesFirstFrame
    case invalidTimeline
}

public struct RecordingInstant: Codable, Comparable, Hashable, Sendable {
    public let seconds: TimeInterval

    public init(seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds >= 0 else {
            throw RecordingTimeError.invalidInstant(seconds)
        }
        self.seconds = seconds
    }

    private init(uncheckedSeconds: TimeInterval) {
        seconds = uncheckedSeconds
    }

    public static let zero = Self(uncheckedSeconds: 0)

    public func advanced(by duration: TimeInterval) throws -> Self {
        try Self(seconds: seconds + duration)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.seconds < rhs.seconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let seconds = try container.decode(TimeInterval.self)
        do {
            try self.init(seconds: seconds)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Recording instant must be finite and non-negative."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(seconds)
    }
}

public enum RecordingPhase: String, CaseIterable, Codable, Hashable, Sendable {
    case idle
    case selecting
    case countdown
    case recording
    case paused
    case finishing
    case canceled
    case failed
    case preview
}

public enum RecordingFailureCode: String, Codable, Hashable, Sendable {
    case noFrames
    case captureUnavailable
    case streamFailed
    case encodingFailed
    case criticalDiskPressure
    case displayDisconnected
    case audioUnavailable
    case unknown
}

public struct RecordingFailure: Error, Codable, Equatable, Hashable, Sendable {
    public let code: RecordingFailureCode
    public let technicalDescription: String?

    public init(code: RecordingFailureCode, technicalDescription: String? = nil) {
        self.code = code
        self.technicalDescription = technicalDescription
    }

    public static let noFrames = Self(code: .noFrames)
}

public enum RecordingTransitionError: Error, Equatable, Sendable {
    case invalidTransition(from: RecordingPhase, operation: String)
    case missingCaptureTarget
    case targetDoesNotMatchMode
    case noFramesAvailable
    case cancellationConfirmationNotPending
    case invalidDecodedState
}

public enum RecordingCommand: Codable, Equatable, Sendable {
    case showCountdown(seconds: Int)
    case startCapture
    case stopAndFinalize
    case discardOutput
    case showCancellationConfirmation(activeDuration: TimeInterval)
    case attemptFinalizePlayableOutput
    case presentPreview(RecordingID)
    case reportFailure(RecordingFailure)
}

public struct RecordingTimeline: Codable, Equatable, Sendable {
    public private(set) var firstFrameAt: RecordingInstant?
    public private(set) var pausedAt: RecordingInstant?
    public private(set) var accumulatedPausedDuration: TimeInterval
    public private(set) var finishedAt: RecordingInstant?

    public init() {
        firstFrameAt = nil
        pausedAt = nil
        accumulatedPausedDuration = 0
        finishedAt = nil
    }

    public var hasFrames: Bool { firstFrameAt != nil }

    public func activeDuration(at instant: RecordingInstant) throws -> TimeInterval {
        guard let firstFrameAt else { return 0 }
        let effectiveEnd = finishedAt ?? pausedAt ?? instant
        guard effectiveEnd >= firstFrameAt else {
            throw RecordingTimeError.samplePredatesFirstFrame
        }
        return max(0, effectiveEnd.seconds - firstFrameAt.seconds - accumulatedPausedDuration)
    }

    /// Maps a monotonic source timestamp to an output timestamp with completed pauses removed.
    public func outputTimestamp(for sourceInstant: RecordingInstant) throws -> TimeInterval {
        guard let firstFrameAt else {
            throw RecordingTransitionError.noFramesAvailable
        }
        guard sourceInstant >= firstFrameAt else {
            throw RecordingTimeError.samplePredatesFirstFrame
        }
        return max(0, sourceInstant.seconds - firstFrameAt.seconds - accumulatedPausedDuration)
    }

    mutating func acceptFirstFrame(at instant: RecordingInstant) {
        guard firstFrameAt == nil else { return }
        firstFrameAt = instant
    }

    mutating func pause(at instant: RecordingInstant) throws {
        guard let firstFrameAt else {
            throw RecordingTransitionError.noFramesAvailable
        }
        guard instant >= firstFrameAt else {
            throw RecordingTimeError.samplePredatesFirstFrame
        }
        pausedAt = instant
    }

    mutating func resume(at instant: RecordingInstant) throws {
        guard let pausedAt else {
            throw RecordingTimeError.invalidTimeline
        }
        guard instant >= pausedAt else {
            throw RecordingTimeError.timeMovedBackwards(
                previous: pausedAt.seconds,
                current: instant.seconds
            )
        }
        accumulatedPausedDuration += instant.seconds - pausedAt.seconds
        self.pausedAt = nil
    }

    mutating func stop(at instant: RecordingInstant) throws {
        guard firstFrameAt != nil else { return }
        guard finishedAt == nil else { return }
        if pausedAt != nil {
            try resume(at: instant)
        }
        finishedAt = instant
    }

    private enum CodingKeys: CodingKey {
        case firstFrameAt
        case pausedAt
        case accumulatedPausedDuration
        case finishedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firstFrameAt = try container.decodeIfPresent(RecordingInstant.self, forKey: .firstFrameAt)
        pausedAt = try container.decodeIfPresent(RecordingInstant.self, forKey: .pausedAt)
        accumulatedPausedDuration = try container.decode(
            TimeInterval.self,
            forKey: .accumulatedPausedDuration
        )
        finishedAt = try container.decodeIfPresent(RecordingInstant.self, forKey: .finishedAt)

        let isValid = accumulatedPausedDuration.isFinite
            && accumulatedPausedDuration >= 0
            && (firstFrameAt != nil || (pausedAt == nil && finishedAt == nil && accumulatedPausedDuration == 0))
            && (pausedAt.map { paused in firstFrameAt.map { paused >= $0 } ?? false } ?? true)
            && (finishedAt.map { finished in firstFrameAt.map { finished >= $0 } ?? false } ?? true)
            && !(pausedAt != nil && finishedAt != nil)
        guard isValid else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Recording timeline invariants are invalid."
                )
            )
        }
    }
}

public struct RecordingStateMachine: Codable, Equatable, Sendable {
    public static let immediateCancellationThreshold: TimeInterval = 3

    public private(set) var phase: RecordingPhase
    public private(set) var captureMode: CaptureMode?
    public private(set) var target: CaptureTarget?
    public private(set) var countdownDeadline: RecordingInstant?
    public private(set) var timeline: RecordingTimeline
    public private(set) var failure: RecordingFailure?
    public private(set) var previewRecordingID: RecordingID?
    public private(set) var isCancellationConfirmationPending: Bool
    public private(set) var lastObservedInstant: RecordingInstant?

    public init() {
        phase = .idle
        captureMode = nil
        target = nil
        countdownDeadline = nil
        timeline = RecordingTimeline()
        failure = nil
        previewRecordingID = nil
        isCancellationConfirmationPending = false
        lastObservedInstant = nil
    }

    public mutating func beginSelection(mode: CaptureMode) throws {
        guard [.idle, .canceled, .failed, .preview].contains(phase) else {
            throw invalidTransition("beginSelection")
        }
        self = Self()
        phase = .selecting
        captureMode = mode
    }

    /// Prepares either an adjusted region or a whole display without starting the countdown.
    public mutating func prepare(target: CaptureTarget, mode: CaptureMode) throws {
        guard [.idle, .selecting, .canceled, .failed, .preview].contains(phase) else {
            throw invalidTransition("prepareTarget")
        }
        guard Self.target(target, matches: mode) else {
            throw RecordingTransitionError.targetDoesNotMatchMode
        }
        self = Self()
        phase = .selecting
        captureMode = mode
        self.target = target
    }

    @discardableResult
    public mutating func start(
        countdown: CountdownDuration,
        at instant: RecordingInstant
    ) throws -> [RecordingCommand] {
        guard phase == .selecting else {
            throw invalidTransition("start")
        }
        guard let target else {
            throw RecordingTransitionError.missingCaptureTarget
        }
        guard let captureMode, Self.target(target, matches: captureMode) else {
            throw RecordingTransitionError.targetDoesNotMatchMode
        }
        timeline = RecordingTimeline()
        failure = nil
        previewRecordingID = nil
        isCancellationConfirmationPending = false

        if countdown == .off {
            try observe(instant)
            phase = .recording
            countdownDeadline = nil
            return [.startCapture]
        }

        let deadline = try instant.advanced(by: TimeInterval(countdown.seconds))
        try observe(instant)
        phase = .countdown
        countdownDeadline = deadline
        return [.showCountdown(seconds: countdown.seconds)]
    }

    @discardableResult
    public mutating func advanceCountdown(to instant: RecordingInstant) throws -> [RecordingCommand] {
        guard phase == .countdown, let countdownDeadline else {
            throw invalidTransition("advanceCountdown")
        }
        try observe(instant)
        guard instant >= countdownDeadline else { return [] }
        phase = .recording
        self.countdownDeadline = nil
        return [.startCapture]
    }

    public func countdownSecondsRemaining(at instant: RecordingInstant) throws -> Int? {
        guard phase == .countdown, let countdownDeadline else { return nil }
        if let lastObservedInstant, instant < lastObservedInstant {
            throw RecordingTimeError.timeMovedBackwards(
                previous: lastObservedInstant.seconds,
                current: instant.seconds
            )
        }
        return max(0, Int(ceil(countdownDeadline.seconds - instant.seconds)))
    }

    /// Accepts the first valid video frame and returns its pause-adjusted output timestamp.
    @discardableResult
    public mutating func acceptFrame(at instant: RecordingInstant) throws -> TimeInterval {
        guard phase == .recording else {
            throw invalidTransition("acceptFrame")
        }
        try observe(instant)
        timeline.acceptFirstFrame(at: instant)
        return try timeline.outputTimestamp(for: instant)
    }

    public mutating func pause(at instant: RecordingInstant) throws {
        guard phase == .recording else {
            throw invalidTransition("pause")
        }
        guard timeline.hasFrames else {
            throw RecordingTransitionError.noFramesAvailable
        }
        try observe(instant)
        try timeline.pause(at: instant)
        phase = .paused
    }

    public mutating func resume(at instant: RecordingInstant) throws {
        guard phase == .paused else {
            throw invalidTransition("resume")
        }
        try observe(instant)
        try timeline.resume(at: instant)
        phase = .recording
    }

    public func activeDuration(at instant: RecordingInstant) throws -> TimeInterval {
        if let lastObservedInstant, instant < lastObservedInstant {
            throw RecordingTimeError.timeMovedBackwards(
                previous: lastObservedInstant.seconds,
                current: instant.seconds
            )
        }
        return try timeline.activeDuration(at: instant)
    }

    @discardableResult
    public mutating func requestFinish(at instant: RecordingInstant) throws -> [RecordingCommand] {
        guard phase == .recording || phase == .paused else {
            throw invalidTransition("requestFinish")
        }
        try observe(instant)
        guard timeline.hasFrames else {
            let noFrames = RecordingFailure.noFrames
            phase = .failed
            failure = noFrames
            return [.discardOutput, .reportFailure(noFrames)]
        }
        try timeline.stop(at: instant)
        phase = .finishing
        isCancellationConfirmationPending = false
        return [.stopAndFinalize]
    }

    @discardableResult
    public mutating func completeFinish(recordingID: RecordingID) throws -> [RecordingCommand] {
        guard phase == .finishing else {
            throw invalidTransition("completeFinish")
        }
        phase = .preview
        previewRecordingID = recordingID
        return [.presentPreview(recordingID)]
    }

    @discardableResult
    public mutating func requestCancel(at instant: RecordingInstant) throws -> [RecordingCommand] {
        guard [.selecting, .countdown, .recording, .paused].contains(phase) else {
            throw invalidTransition("requestCancel")
        }
        try observe(instant)

        let activeDuration = try timeline.activeDuration(at: instant)
        if phase == .recording || phase == .paused,
           activeDuration > Self.immediateCancellationThreshold {
            isCancellationConfirmationPending = true
            return [.showCancellationConfirmation(activeDuration: activeDuration)]
        }

        try timeline.stop(at: instant)
        phase = .canceled
        countdownDeadline = nil
        isCancellationConfirmationPending = false
        return [.discardOutput]
    }

    @discardableResult
    public mutating func resolveCancellation(
        confirmed: Bool,
        at instant: RecordingInstant
    ) throws -> [RecordingCommand] {
        guard isCancellationConfirmationPending else {
            throw RecordingTransitionError.cancellationConfirmationNotPending
        }
        guard phase == .recording || phase == .paused else {
            throw invalidTransition("resolveCancellation")
        }
        try observe(instant)
        isCancellationConfirmationPending = false
        guard confirmed else { return [] }
        try timeline.stop(at: instant)
        phase = .canceled
        return [.discardOutput]
    }

    /// Moves into a terminal failure state and asks the integration layer to preserve playable data.
    @discardableResult
    public mutating func fail(
        _ failure: RecordingFailure,
        at instant: RecordingInstant
    ) throws -> [RecordingCommand] {
        guard [.selecting, .countdown, .recording, .paused, .finishing].contains(phase) else {
            throw invalidTransition("fail")
        }
        try observe(instant)
        let hasPlayableMaterial = timeline.hasFrames
        try timeline.stop(at: instant)
        phase = .failed
        countdownDeadline = nil
        isCancellationConfirmationPending = false
        self.failure = failure
        return [
            hasPlayableMaterial ? .attemptFinalizePlayableOutput : .discardOutput,
            .reportFailure(failure),
        ]
    }

    /// Installs a playable artifact salvaged after a capture failure.
    ///
    /// Failure is terminal while the integration layer attempts finalization.
    /// This explicit transition keeps a successful recovery synchronized with
    /// the Preview that is subsequently presented.
    @discardableResult
    public mutating func recoverPlayableOutput(
        recordingID: RecordingID
    ) throws -> [RecordingCommand] {
        guard phase == .failed, timeline.hasFrames else {
            throw invalidTransition("recoverPlayableOutput")
        }
        phase = .preview
        failure = nil
        previewRecordingID = recordingID
        return [.presentPreview(recordingID)]
    }

    public mutating func reset() throws {
        guard [.idle, .canceled, .failed, .preview].contains(phase) else {
            throw invalidTransition("reset")
        }
        self = Self()
    }

    private mutating func observe(_ instant: RecordingInstant) throws {
        if let lastObservedInstant, instant < lastObservedInstant {
            throw RecordingTimeError.timeMovedBackwards(
                previous: lastObservedInstant.seconds,
                current: instant.seconds
            )
        }
        lastObservedInstant = instant
    }

    private func invalidTransition(_ operation: String) -> RecordingTransitionError {
        .invalidTransition(from: phase, operation: operation)
    }

    private static func target(_ target: CaptureTarget, matches mode: CaptureMode) -> Bool {
        switch (mode, target) {
        case (.captureArea, .region),
             (.lastArea, .region),
             (.fullscreen, .fullscreen),
             (.captureApplication, .application):
            true
        default:
            false
        }
    }

    private enum CodingKeys: CodingKey {
        case phase
        case captureMode
        case target
        case countdownDeadline
        case timeline
        case failure
        case previewRecordingID
        case isCancellationConfirmationPending
        case lastObservedInstant
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decode(RecordingPhase.self, forKey: .phase)
        captureMode = try container.decodeIfPresent(CaptureMode.self, forKey: .captureMode)
        target = try container.decodeIfPresent(CaptureTarget.self, forKey: .target)
        countdownDeadline = try container.decodeIfPresent(
            RecordingInstant.self,
            forKey: .countdownDeadline
        )
        timeline = try container.decode(RecordingTimeline.self, forKey: .timeline)
        failure = try container.decodeIfPresent(RecordingFailure.self, forKey: .failure)
        previewRecordingID = try container.decodeIfPresent(
            RecordingID.self,
            forKey: .previewRecordingID
        )
        isCancellationConfirmationPending = try container.decode(
            Bool.self,
            forKey: .isCancellationConfirmationPending
        )
        lastObservedInstant = try container.decodeIfPresent(
            RecordingInstant.self,
            forKey: .lastObservedInstant
        )

        guard isDecodedStateValid else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Recording state machine invariants are invalid."
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phase, forKey: .phase)
        try container.encodeIfPresent(captureMode, forKey: .captureMode)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(countdownDeadline, forKey: .countdownDeadline)
        try container.encode(timeline, forKey: .timeline)
        try container.encodeIfPresent(failure, forKey: .failure)
        try container.encodeIfPresent(previewRecordingID, forKey: .previewRecordingID)
        try container.encode(
            isCancellationConfirmationPending,
            forKey: .isCancellationConfirmationPending
        )
        try container.encodeIfPresent(lastObservedInstant, forKey: .lastObservedInstant)
    }

    private var isDecodedStateValid: Bool {
        let hasTargetAndMode = target != nil && captureMode != nil
        let failureMatchesPhase = (phase == .failed) == (failure != nil)
        let previewMatchesPhase = (phase == .preview) == (previewRecordingID != nil)
        let countdownMatchesPhase = (phase == .countdown) == (countdownDeadline != nil)
        let pendingCancellationIsValid = !isCancellationConfirmationPending
            || phase == .recording
            || phase == .paused

        guard failureMatchesPhase,
              previewMatchesPhase,
              countdownMatchesPhase,
              pendingCancellationIsValid
        else { return false }

        switch phase {
        case .idle:
            return captureMode == nil && target == nil && !timeline.hasFrames
        case .selecting:
            return captureMode != nil && !timeline.hasFrames
        case .countdown, .recording:
            return hasTargetAndMode
        case .paused:
            return hasTargetAndMode && timeline.hasFrames && timeline.pausedAt != nil
        case .finishing:
            return hasTargetAndMode && timeline.hasFrames && timeline.finishedAt != nil
        case .canceled:
            return true
        case .failed:
            return true
        case .preview:
            return hasTargetAndMode && timeline.hasFrames && timeline.finishedAt != nil
        }
    }
}
