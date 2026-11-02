@preconcurrency import CoreMedia
import Foundation
import Testing
@preconcurrency import VideoToolbox
@testable import ClipMedia

@Suite("VideoToolbox master policy")
struct VideoToolboxEncoderPolicyTests {
    @Test("Recording uses fixed native hardware HEVC with the selected average bitrate")
    func liveMasterPolicy() {
        let recording = RecordingConfiguration(width: 2_560, height: 1_440,
            framesPerSecond: 60, targetAverageBitRate: 20_000_000, audioMode: .system)
        let policy = VideoToolboxHEVCEncoder.Configuration.liveMaster(recording: recording)
        #expect(policy.width == recording.width && policy.height == recording.height)
        #expect(policy.framesPerSecond == 60 && policy.averageBitRate == 20_000_000)
        #expect(policy.isRealTime && !policy.allowsFrameReordering)
        #expect(!policy.prioritizesEncodingSpeedOverQuality && policy.maximumKeyFrameInterval == 120)
        let defaults = VideoToolboxHEVCEncoder.Configuration.liveMaster(
            recording: RecordingConfiguration(width: 4478, height: 3048))
        #expect(defaults.averageBitRate == 10_000_000)
        #expect(defaults.width == 4478 && defaults.height == 3048)
    }

    @Test("Recording requires hardware HEVC without software or codec fallback")
    func requiresHardwareEncoder() {
        let specification = VideoToolboxHEVCEncoder.Configuration.hardwareOnlyEncoderSpecification
        #expect(specification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool == true)
        #expect(specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool == true)
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
