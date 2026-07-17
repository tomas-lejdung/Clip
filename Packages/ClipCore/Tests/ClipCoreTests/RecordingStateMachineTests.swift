import Foundation
import Testing
@testable import ClipCore

@Suite("Recording state machine")
struct RecordingStateMachineTests {
    private func preparedMachine(
        mode: CaptureMode = .captureArea,
        target: CaptureTarget? = nil
    ) throws -> RecordingStateMachine {
        var machine = RecordingStateMachine()
        try machine.prepare(
            target: target ?? .region(makeSelection()),
            mode: mode
        )
        return machine
    }

    @Test("Initial state is inert and empty")
    func initialState() {
        let machine = RecordingStateMachine()
        #expect(machine.phase == .idle)
        #expect(machine.target == nil)
        #expect(machine.captureMode == nil)
        #expect(!machine.timeline.hasFrames)
        #expect(!machine.isCancellationConfirmationPending)
    }

    @Test("Capture targets must match their selected mode")
    func targetModeValidation() throws {
        var machine = RecordingStateMachine()
        #expect(throws: RecordingTransitionError.targetDoesNotMatchMode) {
            try machine.prepare(
                target: .fullscreen(makeDisplayID()),
                mode: .captureArea
            )
        }
        try machine.prepare(target: .fullscreen(makeDisplayID()), mode: .fullscreen)
        #expect(machine.phase == .selecting)

        let application = try ApplicationCaptureTarget(
            displayID: makeDisplayID(),
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari"
        )
        #expect(throws: RecordingTransitionError.targetDoesNotMatchMode) {
            try machine.prepare(target: .application(application), mode: .fullscreen)
        }
        try machine.prepare(
            target: .application(application),
            mode: .captureApplication
        )
        #expect(machine.captureMode == .captureApplication)
    }

    @Test("A prepared target is required to start")
    func missingTarget() throws {
        var machine = RecordingStateMachine()
        try machine.beginSelection(mode: .captureArea)
        #expect(throws: RecordingTransitionError.missingCaptureTarget) {
            try machine.start(countdown: .off, at: makeInstant(0))
        }
    }

    @Test("Countdown is visual state and begins capture exactly at its deadline")
    func countdownFlow() throws {
        var machine = try preparedMachine()
        #expect(
            try machine.start(countdown: .threeSeconds, at: makeInstant(10))
                == [.showCountdown(seconds: 3)]
        )
        #expect(machine.phase == .countdown)
        #expect(try machine.countdownSecondsRemaining(at: makeInstant(10)) == 3)
        #expect(try machine.countdownSecondsRemaining(at: makeInstant(11.1)) == 2)
        #expect(try machine.advanceCountdown(to: makeInstant(12.999)).isEmpty)
        #expect(machine.phase == .countdown)
        #expect(try machine.advanceCountdown(to: makeInstant(13)) == [.startCapture])
        #expect(machine.phase == .recording)
        #expect(machine.countdownDeadline == nil)
    }

    @Test("Disabled countdown starts capture immediately")
    func noCountdown() throws {
        var machine = try preparedMachine()
        #expect(try machine.start(countdown: .off, at: makeInstant(4)) == [.startCapture])
        #expect(machine.phase == .recording)
    }

    @Test("Timing starts on the first valid frame, not on capture startup")
    func firstFrameStartsTiming() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(2))
        #expect(try machine.activeDuration(at: makeInstant(8)) == 0)
        #expect(try machine.acceptFrame(at: makeInstant(8)) == 0)
        #expect(try machine.acceptFrame(at: makeInstant(9.5)) == 1.5)
        #expect(try machine.activeDuration(at: makeInstant(10)) == 2)
    }

    @Test("Pause time is removed from elapsed and output timestamps")
    func pauseAdjustedTimeline() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(0))
        try machine.acceptFrame(at: makeInstant(10))
        try machine.pause(at: makeInstant(14))

        #expect(machine.phase == .paused)
        #expect(try machine.activeDuration(at: makeInstant(100)) == 4)

        try machine.resume(at: makeInstant(19))
        #expect(machine.phase == .recording)
        #expect(try machine.acceptFrame(at: makeInstant(22)) == 7)
        #expect(machine.timeline.accumulatedPausedDuration == 5)
        #expect(try machine.activeDuration(at: makeInstant(25)) == 10)
    }

    @Test("Pause before a first frame is rejected without changing phase")
    func pauseBeforeFrames() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(5))
        #expect(throws: RecordingTransitionError.noFramesAvailable) {
            try machine.pause(at: makeInstant(6))
        }
        #expect(machine.phase == .recording)
        let startInstant = try makeInstant(5)
        #expect(machine.lastObservedInstant == startInstant)
    }

    @Test("Finish finalizes playable content then opens its preview")
    func successfulFinish() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(0))
        try machine.acceptFrame(at: makeInstant(1))
        #expect(try machine.requestFinish(at: makeInstant(4)) == [.stopAndFinalize])
        #expect(machine.phase == .finishing)
        #expect(try machine.activeDuration(at: makeInstant(100)) == 3)

        let id = RecordingID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        #expect(try machine.completeFinish(recordingID: id) == [.presentPreview(id)])
        #expect(machine.phase == .preview)
        #expect(machine.previewRecordingID == id)
        #expect(try jsonRoundTrip(machine) == machine)
    }

    @Test("Finish rejects a recording with no frames")
    func noFrameFinish() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(0))
        #expect(
            try machine.requestFinish(at: makeInstant(1))
                == [.discardOutput, .reportFailure(.noFrames)]
        )
        #expect(machine.phase == .failed)
        #expect(machine.failure == .noFrames)
    }

    @Test("Three seconds or less cancels immediately")
    func immediateCancellationThreshold() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(0))
        try machine.acceptFrame(at: makeInstant(1))
        #expect(try machine.requestCancel(at: makeInstant(4)) == [.discardOutput])
        #expect(machine.phase == .canceled)
        #expect(!machine.isCancellationConfirmationPending)
    }

    @Test("Meaningful content requires confirmation before cancellation")
    func confirmedCancellation() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(0))
        try machine.acceptFrame(at: makeInstant(1))
        #expect(
            try machine.requestCancel(at: makeInstant(4.1))
                == [.showCancellationConfirmation(activeDuration: 3.0999999999999996)]
        )
        #expect(machine.phase == .recording)
        #expect(machine.isCancellationConfirmationPending)

        #expect(try machine.resolveCancellation(confirmed: false, at: makeInstant(5)).isEmpty)
        #expect(machine.phase == .recording)
        #expect(!machine.isCancellationConfirmationPending)

        _ = try machine.requestCancel(at: makeInstant(6))
        #expect(try machine.resolveCancellation(confirmed: true, at: makeInstant(6.5)) == [.discardOutput])
        #expect(machine.phase == .canceled)
    }

    @Test("Paused wall time does not trigger meaningful-content confirmation")
    func pausedCancellationUsesActiveTime() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(0))
        try machine.acceptFrame(at: makeInstant(1))
        try machine.pause(at: makeInstant(3))
        #expect(try machine.requestCancel(at: makeInstant(100)) == [.discardOutput])
        #expect(machine.phase == .canceled)
        #expect(try machine.timeline.activeDuration(at: makeInstant(200)) == 2)
    }

    @Test("Selection and countdown cancel without confirmation")
    func preRecordingCancellation() throws {
        var selecting = RecordingStateMachine()
        try selecting.beginSelection(mode: .captureArea)
        #expect(try selecting.requestCancel(at: makeInstant(0)) == [.discardOutput])
        #expect(selecting.phase == .canceled)

        var countdown = try preparedMachine()
        try countdown.start(countdown: .fiveSeconds, at: makeInstant(0))
        #expect(try countdown.requestCancel(at: makeInstant(2)) == [.discardOutput])
        #expect(countdown.phase == .canceled)
    }

    @Test("Failures preserve playable material but discard empty output")
    func failureRecoveryCommands() throws {
        let failure = RecordingFailure(
            code: .displayDisconnected,
            technicalDescription: "Display 2 disappeared"
        )

        var empty = try preparedMachine()
        try empty.start(countdown: .off, at: makeInstant(0))
        #expect(
            try empty.fail(failure, at: makeInstant(1))
                == [.discardOutput, .reportFailure(failure)]
        )

        var playable = try preparedMachine()
        try playable.start(countdown: .off, at: makeInstant(0))
        try playable.acceptFrame(at: makeInstant(1))
        #expect(
            try playable.fail(failure, at: makeInstant(2))
                == [.attemptFinalizePlayableOutput, .reportFailure(failure)]
        )
        #expect(playable.phase == .failed)
        #expect(playable.failure == failure)
        #expect(try playable.activeDuration(at: makeInstant(100)) == 1)
    }

    @Test("A successfully finalized failure can transition to Preview")
    func recoveredFailureTransitionsToPreview() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(10))
        try machine.acceptFrame(at: makeInstant(11))
        _ = try machine.fail(
            RecordingFailure(
                code: .streamFailed,
                technicalDescription: "The capture stream ended early"
            ),
            at: makeInstant(14)
        )

        let recordingID = RecordingID(
            UUID(uuidString: "d714c713-d4bd-43cf-baf8-f12fd1f0d3f0")!
        )
        #expect(
            try machine.recoverPlayableOutput(recordingID: recordingID)
                == [.presentPreview(recordingID)]
        )
        #expect(machine.phase == .preview)
        #expect(machine.failure == nil)
        #expect(machine.previewRecordingID == recordingID)
        #expect(try jsonRoundTrip(machine) == machine)
    }

    @Test("Monotonic time moving backwards is rejected")
    func backwardsTime() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(10))
        try machine.acceptFrame(at: makeInstant(11))
        #expect(throws: RecordingTimeError.timeMovedBackwards(previous: 11, current: 10.5)) {
            try machine.pause(at: makeInstant(10.5))
        }
        #expect(machine.phase == .recording)
    }

    @Test("The state machine supports recordings beyond thirty minutes")
    func longRecording() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(0))
        try machine.acceptFrame(at: makeInstant(1))
        #expect(try machine.activeDuration(at: makeInstant(1_802)) == 1_801)
    }

    @Test("A multi-hour recording remains stable across ten thousand pause cycles")
    func multiHourPauseResumeSoak() throws {
        var machine = try preparedMachine()
        try machine.start(countdown: .off, at: makeInstant(0))
        try machine.acceptFrame(at: makeInstant(1))

        var sourceTime = 1.0
        var expectedActiveDuration = 0.0
        var previousOutputTime = 0.0
        for _ in 0..<10_000 {
            sourceTime += 0.25
            expectedActiveDuration += 0.25
            let beforePause = try machine.acceptFrame(at: makeInstant(sourceTime))
            #expect(beforePause >= previousOutputTime)
            previousOutputTime = beforePause

            try machine.pause(at: makeInstant(sourceTime))
            sourceTime += 0.75
            try machine.resume(at: makeInstant(sourceTime))

            let afterResume = try machine.acceptFrame(at: makeInstant(sourceTime))
            #expect(abs(afterResume - expectedActiveDuration) < 0.000_001)
            #expect(afterResume >= previousOutputTime)
            previousOutputTime = afterResume
        }

        #expect(sourceTime > 2 * 60 * 60)
        #expect(abs(try machine.activeDuration(at: makeInstant(sourceTime)) - 2_500) < 0.000_001)
        #expect(try jsonRoundTrip(machine) == machine)
        #expect(try machine.requestFinish(at: makeInstant(sourceTime)) == [.stopAndFinalize])
    }

    @Test("Invalid transitions are explicit")
    func invalidTransitions() throws {
        var machine = RecordingStateMachine()
        #expect(throws: RecordingTransitionError.invalidTransition(from: .idle, operation: "pause")) {
            try machine.pause(at: makeInstant(0))
        }
        #expect(throws: RecordingTransitionError.cancellationConfirmationNotPending) {
            try machine.resolveCancellation(confirmed: true, at: makeInstant(0))
        }
    }

    @Test("Persisted state is validated while decoding")
    func invalidPersistedState() throws {
        let data = try JSONEncoder().encode(RecordingStateMachine())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["phase"] = "paused"
        let corruptData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecordingStateMachine.self, from: corruptData)
        }
    }
}
