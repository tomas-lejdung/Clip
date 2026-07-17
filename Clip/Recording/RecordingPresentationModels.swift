import Foundation

enum RecordingPresentationPhase: Equatable, Sendable {
    case recording
    case paused
    case finishing
}

enum RecordingAudioSourceState: Equatable, Sendable {
    case off
    case active(detail: String? = nil)
    case unavailable(reason: String)

    var statusText: String {
        switch self {
        case .off:
            String(localized: "Off")
        case let .active(detail):
            detail ?? String(localized: "On")
        case let .unavailable(reason):
            reason
        }
    }
}

struct RecordingPresentationSnapshot: Equatable, Sendable {
    let phase: RecordingPresentationPhase
    let activeElapsedSeconds: TimeInterval
    let hasReceivedFirstFrame: Bool
    let microphone: RecordingAudioSourceState
    let systemAudio: RecordingAudioSourceState
    let notice: String?

    init(
        phase: RecordingPresentationPhase,
        activeElapsedSeconds: TimeInterval,
        hasReceivedFirstFrame: Bool = true,
        microphone: RecordingAudioSourceState,
        systemAudio: RecordingAudioSourceState,
        notice: String? = nil
    ) {
        self.phase = phase
        self.activeElapsedSeconds = max(0, activeElapsedSeconds.isFinite ? activeElapsedSeconds : 0)
        self.hasReceivedFirstFrame = hasReceivedFirstFrame
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.notice = notice
    }

    static let demoRecording = RecordingPresentationSnapshot(
        phase: .recording,
        activeElapsedSeconds: 18,
        microphone: .active(detail: "MacBook Pro Microphone"),
        systemAudio: .active()
    )

    static let demoPaused = RecordingPresentationSnapshot(
        phase: .paused,
        activeElapsedSeconds: 42,
        microphone: .active(detail: "MacBook Pro Microphone"),
        systemAudio: .off,
        notice: String(localized: "Paused time is excluded from the clip.")
    )

    static let demoFinishing = RecordingPresentationSnapshot(
        phase: .finishing,
        activeElapsedSeconds: 73,
        microphone: .off,
        systemAudio: .active()
    )

    static let demoAudioUnavailable = RecordingPresentationSnapshot(
        phase: .recording,
        activeElapsedSeconds: 9,
        microphone: .unavailable(reason: String(localized: "Input unavailable")),
        systemAudio: .active(),
        notice: String(localized: "Video continues without microphone audio.")
    )
}

struct RecordingPresentationClock: Sendable {
    private let readTime: @Sendable () -> TimeInterval

    init(now: @escaping @Sendable () -> TimeInterval) {
        readTime = now
    }

    func now() -> TimeInterval {
        let value = readTime()
        return value.isFinite ? value : 0
    }

    static let live = RecordingPresentationClock {
        ProcessInfo.processInfo.systemUptime
    }

    static func fixed(_ value: TimeInterval) -> RecordingPresentationClock {
        RecordingPresentationClock { value }
    }
}

struct RecordingPresentationActions: Sendable {
    var pause: @MainActor @Sendable () async throws -> Void
    var resume: @MainActor @Sendable () async throws -> Void
    var finish: @MainActor @Sendable () async throws -> Void
    var cancel: @MainActor @Sendable () async throws -> Void

    static let noOp = RecordingPresentationActions(
        pause: {},
        resume: {},
        finish: {},
        cancel: {}
    )
}

enum RecordingDurationFormatter {
    static func string(seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

enum CountdownPresentationSequence {
    static func values(seconds: Int) -> [Int] {
        guard seconds > 0 else { return [] }
        return Array(stride(from: seconds, through: 1, by: -1))
    }
}

struct CountdownScheduler: Sendable {
    var sleep: @Sendable (Duration) async throws -> Void

    static let live = CountdownScheduler { duration in
        try await ContinuousClock().sleep(for: duration)
    }

    /// Deterministic scheduler for demos and tests; it advances without wall time.
    static let immediate = CountdownScheduler { _ in
        await Task.yield()
    }
}
