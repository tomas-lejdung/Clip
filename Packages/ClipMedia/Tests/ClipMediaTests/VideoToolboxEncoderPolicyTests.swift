import Foundation
import Testing
@testable import ClipMedia

@Suite("VideoToolbox master policy")
struct VideoToolboxEncoderPolicyTests {
    @Test("Live masters use quality-first real-time H.264 without a hard rate limit")
    func liveMasterPolicy() {
        let recording = RecordingConfiguration(
            width: 2_560,
            height: 1_440,
            framesPerSecond: 60,
            showsCursor: true,
            audioMode: .system
        )

        let policy = VideoToolboxH264Encoder.Configuration.liveMaster(
            recording: recording
        )

        #expect(policy.width == recording.width)
        #expect(policy.height == recording.height)
        #expect(policy.framesPerSecond == 60)
        #expect(policy.averageBitRate == recording.videoBitRate)
        #expect(policy.quality == 0.98)
        #expect(policy.isRealTime)
        #expect(!policy.allowsFrameReordering)
        #expect(!policy.prioritizesEncodingSpeedOverQuality)
        #expect(policy.maximumKeyFrameInterval == 120)
        #expect(policy.hardDataRateLimitBytesPerSecond == nil)
    }

    @Test("Bounded VideoToolbox operation returns a completed status")
    func boundedOperationCompletes() {
        let queue = DispatchQueue(label: "clip.tests.vt-completion")
        var timedOut = false
        let status = BoundedVideoToolboxOperation.run(
            on: queue,
            timeout: 0.5,
            operation: { noErr },
            onTimeout: { timedOut = true }
        )

        #expect(status == noErr)
        #expect(!timedOut)
    }

    @Test("Bounded VideoToolbox operation times out and starts teardown")
    func boundedOperationTimesOut() {
        let queue = DispatchQueue(label: "clip.tests.vt-timeout")
        let operationGate = DispatchSemaphore(value: 0)
        let operationFinished = DispatchSemaphore(value: 0)
        let timeoutCount = LockedCounter()
        let start = Date()

        let status = BoundedVideoToolboxOperation.run(
            on: queue,
            timeout: 0.03,
            operation: {
                operationGate.wait()
                operationFinished.signal()
                return noErr
            },
            onTimeout: {
                timeoutCount.increment()
                // Model invalidation unblocking a synchronous VideoToolbox
                // call, while keeping the caller-side deadline independent.
                operationGate.signal()
            }
        )

        #expect(status == nil)
        #expect(Date().timeIntervalSince(start) < 0.25)
        #expect(timeoutCount.value == 1)
        #expect(operationFinished.wait(timeout: .now() + 1) == .success)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}
