@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import ClipMedia

@Suite("Asset writer append readiness")
struct AssetWriterAppendReadinessTests {
    @Test("Timestamp policy drops pre-roll and enforces strict per-input monotonicity")
    func timestampPolicyBoundaries() {
        let anchor = CMTime(value: 600, timescale: 600)
        let beforeAnchor = CMTime(value: 599, timescale: 600)
        let afterAnchor = CMTime(value: 601, timescale: 600)

        #expect(AssetWriterTimestampPolicy.relativeOutputTime(
            outputTime: beforeAnchor,
            firstSourceTime: anchor,
            lastAppended: nil
        ) == nil)
        #expect(AssetWriterTimestampPolicy.relativeOutputTime(
            outputTime: anchor,
            firstSourceTime: anchor,
            lastAppended: nil
        ) == .zero)
        #expect(AssetWriterTimestampPolicy.relativeOutputTime(
            outputTime: anchor,
            firstSourceTime: anchor,
            lastAppended: .zero
        ) == nil)
        #expect(AssetWriterTimestampPolicy.relativeOutputTime(
            outputTime: beforeAnchor,
            firstSourceTime: anchor,
            lastAppended: .zero
        ) == nil)
        #expect(AssetWriterTimestampPolicy.relativeOutputTime(
            outputTime: afterAnchor,
            firstSourceTime: anchor,
            lastAppended: .zero
        ) == CMTime(value: 1, timescale: 600))

        #expect(AssetWriterTimestampPolicy.classify(
            outputTime: .invalid,
            firstSourceTime: anchor,
            lastAppended: nil
        ) == .invalid)
        #expect(AssetWriterTimestampPolicy.classify(
            outputTime: beforeAnchor,
            firstSourceTime: anchor,
            lastAppended: nil
        ) == .preRoll)
        #expect(AssetWriterTimestampPolicy.classify(
            outputTime: anchor,
            firstSourceTime: anchor,
            lastAppended: .zero
        ) == .nonmonotonic)
    }

    @Test("Nonterminal writers preserve real-time backpressure semantics")
    func nonterminalBackpressure() throws {
        #expect(
            try !AssetWriterAppendReadiness.permitsAppend(
                writerStatus: .writing,
                inputIsReady: false
            )
        )
        #expect(
            try !AssetWriterAppendReadiness.permitsAppend(
                writerStatus: .unknown,
                inputIsReady: false
            )
        )
        #expect(
            try AssetWriterAppendReadiness.permitsAppend(
                writerStatus: .writing,
                inputIsReady: true
            )
        )
        #expect(
            try AssetWriterAppendReadiness.permitsAppend(
                writerStatus: .unknown,
                inputIsReady: true
            )
        )
    }

    @Test("Every terminal writer state throws a sanitized append failure")
    func terminalStatesFailImmediately() {
        let cases: [(AVAssetWriter.Status, String)] = [
            (.failed, "The recording writer failed before accepting a sample."),
            (.cancelled, "The recording writer was cancelled before accepting a sample."),
            (.completed, "The recording writer completed before accepting a sample."),
        ]

        for (status, expectedMessage) in cases {
            for inputIsReady in [false, true] {
                do {
                    _ = try AssetWriterAppendReadiness.permitsAppend(
                        writerStatus: status,
                        inputIsReady: inputIsReady
                    )
                    Issue.record("Expected terminal writer status \(status.rawValue) to fail")
                } catch AssetWriterSessionError.appendFailed(let message) {
                    #expect(message == expectedMessage)
                } catch {
                    Issue.record("Expected appendFailed, received \(error)")
                }
            }
        }
    }

    @Test("Video readiness polling yields the writer lock so audio can advance")
    func videoReadinessPollingYieldsForAudio() {
        let writerStateLock = NSLock()
        var audioAdvanced = false
        var checkCount = 0

        let outcome = AssetWriterVideoReadinessPoller.wait(
            until: Date(timeIntervalSinceNow: 1)
        ) {
            writerStateLock.withLock {
                checkCount += 1
                return audioAdvanced ? .ready : .wait
            }
        } pause: {
            // This models an audio callback using the same writer-state lock.
            // It can run only because the poller releases the lock after each
            // readiness check rather than sleeping inside the critical section.
            writerStateLock.withLock {
                audioAdvanced = true
            }
        }

        #expect(outcome == .ready)
        #expect(audioAdvanced)
        #expect(checkCount == 2)
    }

    @Test(
        "Live cadence repair distinguishes bounded jitter, sparse VFR, and resume failure",
        arguments: [30, 60]
    )
    func liveCadenceRepairBoundaries(framesPerSecond: Int) throws {
        let policy = LiveVideoCadencePolicy(
            framesPerSecond: framesPerSecond
        )
        let tenthsOfAFrameScale = CMTimeScale(framesPerSecond * 10)
        let previous = CMTime(
            value: CMTimeValue(framesPerSecond * 100),
            timescale: tenthsOfAFrameScale
        )
        func current(afterTenthsOfAFrame tenths: Int64) -> CMTime {
            previous + CMTime(
                value: CMTimeValue(tenths),
                timescale: tenthsOfAFrameScale
            )
        }

        #expect(try policy.heldFramePresentationTime(
            previous: previous,
            current: current(afterTenthsOfAFrame: 20),
            isResumeSeam: false
        ) == nil)
        #expect(try policy.heldFramePresentationTime(
            previous: previous,
            current: current(afterTenthsOfAFrame: 21),
            isResumeSeam: false
        ) == previous + policy.nominalFrameDuration)
        #expect(try policy.heldFramePresentationTime(
            previous: previous,
            current: current(afterTenthsOfAFrame: 30),
            isResumeSeam: false
        ) == previous + policy.nominalFrameDuration)
        // A larger ordinary gap is genuine VFR/static timing and remains
        // untouched, while the same first-post-resume gap is anomalous.
        #expect(try policy.heldFramePresentationTime(
            previous: previous,
            current: current(afterTenthsOfAFrame: 31),
            isResumeSeam: false
        ) == nil)
        #expect(throws: LiveVideoCadencePolicy.PolicyError.gapExceedsRepairLimit) {
            try policy.heldFramePresentationTime(
                previous: previous,
                current: current(afterTenthsOfAFrame: 31),
                isResumeSeam: true
            )
        }
        #expect(try policy.heldFramePresentationTime(
            previous: previous,
            current: current(afterTenthsOfAFrame: 21),
            isResumeSeam: true
        ) == previous + policy.nominalFrameDuration)
        #expect(try policy.heldFramePresentationTime(
            previous: .invalid,
            current: current(afterTenthsOfAFrame: 21),
            isResumeSeam: false
        ) == nil)
    }

}
