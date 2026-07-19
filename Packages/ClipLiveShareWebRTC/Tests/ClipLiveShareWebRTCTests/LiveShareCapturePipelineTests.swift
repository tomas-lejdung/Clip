import ClipCapture
import ClipLiveShare
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ClipLiveShareWebRTC

@Suite("Live Share capture pipeline policy")
struct LiveShareCapturePipelineTests {
    @Test("only the four negotiated slots are accepted")
    func slotBounds() async {
        let pipeline = LiveShareCapturePipeline(host: FakeSlotHost())
        await #expect(throws: LiveShareCapturePipelineError.invalidSlot(-1)) {
            try await pipeline.start(Self.descriptor(), inSlot: -1)
        }
        await #expect(throws: LiveShareCapturePipelineError.invalidSlot(4)) {
            try await pipeline.start(Self.descriptor(), inSlot: 4)
        }
    }

    @Test("WebRTC slot is active before capture delivers its first frame")
    func initialFrameHandoff() async throws {
        let host = FakeSlotHost()
        let pipeline = LiveShareCapturePipeline(
            host: host,
            sessionFactory: { _, frameConsumer, _ in
                FixtureCaptureSession(frameConsumer: frameConsumer)
            }
        )

        try await pipeline.start(Self.descriptor(), inSlot: 0)

        #expect(host.timeline == [.activated(0), .sent(0)])
        #expect(await pipeline.statistics(for: 0) == CaptureDeliveryStatistics(
            deliveredFrames: 1,
            backpressureDrops: 0
        ))
        try await pipeline.stop(slot: 0)
    }

    @Test("capture startup failure rolls back its WebRTC slot")
    func startupFailureRollback() async {
        let host = FakeSlotHost()
        let pipeline = LiveShareCapturePipeline(
            host: host,
            sessionFactory: { _, frameConsumer, _ in
                FixtureCaptureSession(
                    frameConsumer: frameConsumer,
                    startupError: .startFailed
                )
            }
        )

        await #expect(throws: FixtureCaptureError.startFailed) {
            try await pipeline.start(Self.descriptor(), inSlot: 0)
        }
        #expect(host.timeline == [.activated(0), .deactivated(0)])
        #expect(await pipeline.activeSlots.isEmpty)
    }

    @Test("a slot cannot be reused until its previous capture has drained")
    func retiringSlotBlocksReplacement() async throws {
        let host = FakeSlotHost()
        let stopGate = FixtureAsyncGate()
        let factory = FixtureSessionFactory(firstStopGate: stopGate)
        let pipeline = LiveShareCapturePipeline(
            host: host,
            sessionFactory: { _, frameConsumer, _ in
                factory.make(frameConsumer: frameConsumer)
            }
        )

        try await pipeline.start(Self.descriptor(), inSlot: 0)
        let stopTask = Task {
            try await pipeline.stop(slot: 0)
        }
        await stopGate.waitUntilEntered()

        await #expect(throws: LiveShareCapturePipelineError.slotAlreadyActive(0)) {
            try await pipeline.start(Self.descriptor(), inSlot: 0)
        }

        await stopGate.release()
        try await stopTask.value
        try await pipeline.start(Self.descriptor(), inSlot: 0)
        try await pipeline.stop(slot: 0)
    }

    @Test("stop during capture discovery drains startup before slot reuse")
    func startupRetirementBlocksReplacement() async throws {
        let host = FakeSlotHost()
        let startGate = FixtureAsyncGate()
        let factory = FixtureSessionFactory(firstStartGate: startGate)
        let pipeline = LiveShareCapturePipeline(
            host: host,
            sessionFactory: { _, frameConsumer, _ in
                factory.make(frameConsumer: frameConsumer)
            }
        )

        let startTask = Task {
            try await pipeline.start(Self.descriptor(), inSlot: 0)
        }
        await startGate.waitUntilEntered()
        let stopTask = Task {
            try await pipeline.stop(slot: 0)
        }
        await host.waitUntilDeactivated(slot: 0)

        await #expect(throws: LiveShareCapturePipelineError.slotAlreadyActive(0)) {
            try await pipeline.start(Self.descriptor(), inSlot: 0)
        }

        await startGate.release()
        await #expect(throws: LiveShareCapturePipelineError.superseded(0)) {
            try await startTask.value
        }
        try await stopTask.value

        try await pipeline.start(Self.descriptor(), inSlot: 0)
        try await pipeline.stop(slot: 0)
    }

    private static func descriptor() -> LiveShareCaptureDescriptor {
        let source = LiveShareWindowSource(
            id: LiveShareWindowID(rawValue: 42),
            windowName: "Fixture",
            appName: "Tests"
        )
        return LiveShareCaptureDescriptor(
            source: .window(source),
            target: .window(id: 42),
            video: CaptureVideoConfiguration(width: 1_280, height: 720),
            stream: GoPeepV1StreamInfo(
                trackID: "video0",
                windowName: "Fixture",
                appName: "Tests",
                isFocused: true,
                width: 1_280,
                height: 720
            )
        )
    }
}

private final class FakeSlotHost: LiveShareVideoSlotHosting, @unchecked Sendable {
    enum Event: Equatable {
        case activated(Int)
        case sent(Int)
        case deactivated(Int)
    }

    private let lock = NSLock()
    private var activeSlots = Set<Int>()
    private var storedTimeline: [Event] = []

    var timeline: [Event] {
        lock.withLock { storedTimeline }
    }

    func waitUntilDeactivated(slot: Int) async {
        while !lock.withLock({ storedTimeline.contains(.deactivated(slot)) }) {
            await Task.yield()
        }
    }

    func send(
        _ frame: BorrowedCaptureVideoFrame,
        toSlot slot: Int
    ) -> CaptureFrameDisposition {
        lock.withLock {
            storedTimeline.append(.sent(slot))
            return activeSlots.contains(slot) ? .accepted : .droppedBackpressure
        }
    }

    func activateSlot(_ slot: Int, metadata: GoPeepV1StreamInfo) throws {
        lock.withLock {
            activeSlots.insert(slot)
            storedTimeline.append(.activated(slot))
        }
    }

    func deactivateSlot(_ slot: Int) {
        lock.withLock {
            activeSlots.remove(slot)
            storedTimeline.append(.deactivated(slot))
        }
    }
}

private enum FixtureCaptureError: Error, Equatable {
    case startFailed
}

private actor FixtureAsyncGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class FixtureSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let firstStartGate: FixtureAsyncGate?
    private let firstStopGate: FixtureAsyncGate?
    private var creationCount = 0

    init(
        firstStartGate: FixtureAsyncGate? = nil,
        firstStopGate: FixtureAsyncGate? = nil
    ) {
        self.firstStartGate = firstStartGate
        self.firstStopGate = firstStopGate
    }

    func make(
        frameConsumer: @escaping ScreenCaptureSession.FrameConsumer
    ) -> any LiveShareCaptureSession {
        let gates = lock.withLock { () -> (FixtureAsyncGate?, FixtureAsyncGate?) in
            creationCount += 1
            guard creationCount == 1 else { return (nil, nil) }
            return (firstStartGate, firstStopGate)
        }
        return FixtureCaptureSession(
            frameConsumer: frameConsumer,
            startGate: gates.0,
            stopGate: gates.1
        )
    }
}

private final class FixtureCaptureSession: LiveShareCaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private let frameConsumer: ScreenCaptureSession.FrameConsumer
    private let startupError: FixtureCaptureError?
    private let startGate: FixtureAsyncGate?
    private let stopGate: FixtureAsyncGate?
    private var running = false
    private var storedStatistics = CaptureDeliveryStatistics()

    init(
        frameConsumer: @escaping ScreenCaptureSession.FrameConsumer,
        startupError: FixtureCaptureError? = nil,
        startGate: FixtureAsyncGate? = nil,
        stopGate: FixtureAsyncGate? = nil
    ) {
        self.frameConsumer = frameConsumer
        self.startupError = startupError
        self.startGate = startGate
        self.stopGate = stopGate
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var statistics: CaptureDeliveryStatistics {
        lock.withLock { storedStatistics }
    }

    func start(_ request: CaptureSessionRequest) async throws {
        if let startupError { throw startupError }
        await startGate?.suspend()
        lock.withLock { running = true }
        let disposition = frameConsumer(try makeFixtureFrame())
        lock.withLock {
            switch disposition {
            case .accepted:
                storedStatistics.deliveredFrames += 1
            case .droppedBackpressure:
                storedStatistics.backpressureDrops += 1
            }
        }
    }

    func stop() async throws {
        lock.withLock { running = false }
        await stopGate?.suspend()
    }

    func update(
        target: CaptureTarget,
        video: CaptureVideoConfiguration
    ) async throws {}
}

private func makeFixtureFrame() throws -> BorrowedCaptureVideoFrame {
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferCreate(
        kCFAllocatorDefault,
        1_280,
        720,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
        &pixelBuffer
    ) == kCVReturnSuccess,
        let pixelBuffer else {
        throw FixtureCaptureError.startFailed
    }

    var formatDescription: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    ) == noErr,
        let formatDescription else {
        throw FixtureCaptureError.startFailed
    }
    let presentationTime = CMTime.zero
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    ) == noErr,
        let sampleBuffer else {
        throw FixtureCaptureError.startFailed
    }
    return BorrowedCaptureVideoFrame(
        sampleBuffer: sampleBuffer,
        pixelBuffer: pixelBuffer,
        presentationTime: presentationTime
    )
}
