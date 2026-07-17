import CoreMedia

public enum SampleTimelineError: Error, Equatable, Sendable {
    case invalidSourceTime
    case alreadyPaused
    case notPaused
    case resumeBeforePause
    case pauseBeforePreviousResume
}

/// Removes paused wall-clock intervals from capture sample timestamps.
public struct SampleTimeline: Sendable {
    private struct CompletedPause: Sendable {
        let start: CMTime
        let end: CMTime
        let accumulatedDurationAtEnd: CMTime
    }

    public private(set) var accumulatedPauseDuration: CMTime = .zero
    public private(set) var pauseStartedAt: CMTime?
    private var completedPauses: [CompletedPause] = []

    public init() {}

    public var isPaused: Bool {
        pauseStartedAt != nil
    }

    public mutating func pause(at sourceTime: CMTime) throws {
        guard sourceTime.isValid, sourceTime.isNumeric else {
            throw SampleTimelineError.invalidSourceTime
        }
        guard pauseStartedAt == nil else {
            throw SampleTimelineError.alreadyPaused
        }
        if let previousResume = completedPauses.last?.end,
           sourceTime < previousResume {
            throw SampleTimelineError.pauseBeforePreviousResume
        }
        pauseStartedAt = sourceTime
    }

    public mutating func resume(at sourceTime: CMTime) throws {
        guard sourceTime.isValid, sourceTime.isNumeric else {
            throw SampleTimelineError.invalidSourceTime
        }
        guard let pauseStartedAt else {
            throw SampleTimelineError.notPaused
        }
        guard sourceTime >= pauseStartedAt else {
            throw SampleTimelineError.resumeBeforePause
        }
        accumulatedPauseDuration = accumulatedPauseDuration + (sourceTime - pauseStartedAt)
        completedPauses.append(
            CompletedPause(
                start: pauseStartedAt,
                end: sourceTime,
                accumulatedDurationAtEnd: accumulatedPauseDuration
            )
        )
        self.pauseStartedAt = nil
    }

    /// Maps a source timestamp onto the pause-free output timeline.
    ///
    /// Pause intervals are half-open: `[pause, resume)`. A sample exactly at
    /// `pause` is dropped, while a sample exactly at `resume` is retained and
    /// has the completed pause duration removed. An active pause extends from
    /// its start indefinitely. Looking up a delayed timestamp uses only the
    /// completed intervals preceding that timestamp, rather than callback
    /// arrival order.
    public func outputTime(for sourceTime: CMTime) -> CMTime? {
        guard sourceTime.isValid, sourceTime.isNumeric else {
            return nil
        }

        if let pauseStartedAt, sourceTime >= pauseStartedAt {
            return nil
        }

        // Find the final completed pause whose start is not later than this
        // sample. Pauses are appended chronologically, so lookup is O(log n).
        var lowerBound = 0
        var upperBound = completedPauses.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if completedPauses[middle].start <= sourceTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        guard lowerBound > 0 else {
            return sourceTime
        }

        let pause = completedPauses[lowerBound - 1]
        if sourceTime < pause.end {
            return nil
        }
        return sourceTime - pause.accumulatedDurationAtEnd
    }

    public func outputDuration(for sourceDuration: CMTime) -> CMTime {
        sourceDuration
    }
}
