@preconcurrency import CoreMedia
import Foundation
import Testing
@preconcurrency import VideoToolbox
@testable import ClipMedia

@Suite("VideoToolbox master policy")
struct VideoToolboxEncoderPolicyTests {
    @Test("Live masters use quality-first real-time video without a hard rate limit")
    func liveMasterPolicy() {
        let recording = RecordingConfiguration(
            width: 2_560,
            height: 1_440,
            framesPerSecond: 60,
            videoQuality: 0.91,
            showsCursor: true,
            audioMode: .system
        )

        let policy = VideoToolboxVideoEncoder.Configuration.liveMaster(
            recording: recording
        )

        #expect(policy.width == recording.width)
        #expect(policy.height == recording.height)
        #expect(policy.framesPerSecond == 60)
        #expect(policy.quality == 0.91)
        #expect(policy.isRealTime)
        #expect(!policy.allowsFrameReordering)
        #expect(!policy.prioritizesEncodingSpeedOverQuality)
        #expect(policy.maximumKeyFrameInterval == 120)
    }

    @Test("Live hardware encoding prefers H.264 and falls back to HEVC")
    func liveHardwareCodecPreference() {
        #expect(VideoToolboxVideoCodec.liveHardwarePreference == [.h264, .hevc])
        #expect(VideoToolboxVideoCodec.h264.codecType == kCMVideoCodecType_H264)
        #expect(VideoToolboxVideoCodec.hevc.codecType == kCMVideoCodecType_HEVC)
        #expect(VideoToolboxVideoCodec.h264.profileLevel == kVTProfileLevel_H264_High_AutoLevel)
        #expect(VideoToolboxVideoCodec.hevc.profileLevel == kVTProfileLevel_HEVC_Main_AutoLevel)
    }

    @Test("Hardware codec selection retains the first successful exact-size session")
    func selectsHEVCAfterH264RejectsExactSize() {
        var attempts: [VideoToolboxVideoCodec] = []
        let selection: VideoToolboxHardwareCodecSelection<String> =
            VideoToolboxHardwareCodecSelector.select { codec in
                attempts.append(codec)
                switch codec {
                case .h264:
                    return (OSStatus(-12_903), nil)
                case .hevc:
                    return (noErr, "exact-size-hevc-session")
                }
            }

        #expect(attempts == [.h264, .hevc])
        switch selection {
        case let .selected(codec, value):
            #expect(codec == .hevc)
            #expect(value == "exact-size-hevc-session")
        case .unavailable:
            Issue.record("Expected the HEVC hardware fallback to be selected")
        }
    }

    @Test("Live codec attempts require rather than merely prefer hardware")
    func requiresHardwareEncoder() {
        let specification = VideoToolboxHardwareCodecSelector
            .hardwareOnlyEncoderSpecification
        #expect(
            specification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder]
                as? Bool == true
        )
        #expect(
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder]
                as? Bool == true
        )
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
