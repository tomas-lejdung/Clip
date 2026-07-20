import ClipCapture
import ClipLiveShare
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ClipLiveShareWebRTC

extension NativeMediaResourceTests {
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

    @Test("in-place geometry update commits stable-slot metadata")
    func geometryUpdateMetadata() async throws {
        let host = FakeSlotHost()
        let pipeline = LiveShareCapturePipeline(
            host: host,
            sessionFactory: { _, frameConsumer, _ in
                FixtureCaptureSession(frameConsumer: frameConsumer)
            }
        )
        let generation = UUID()
        try await pipeline.start(Self.descriptor(), inSlot: 0, generation: generation)

        let source = LiveShareWindowSource(
            id: LiveShareWindowID(rawValue: 42),
            windowName: "Fixture",
            appName: "Tests"
        )
        let capped = LiveShareCaptureDescriptor(
            source: .window(source),
            target: .window(id: 42),
            sourcePixelWidth: 5_120,
            sourcePixelHeight: 2_880,
            video: CaptureVideoConfiguration(width: 4_096, height: 2_304),
            stream: GoPeepV1StreamInfo(
                trackID: "video0",
                windowName: "Fixture",
                appName: "Tests",
                isFocused: true,
                width: 4_096,
                height: 2_304
            )
        )
        try await pipeline.update(capped, inSlot: 0, expectedGeneration: generation)

        #expect(host.timeline == [
            .activated(0),
            .sent(0),
            .metadataUpdated(slot: 0, width: 4_096, height: 2_304),
        ])
        #expect(capped.sourcePixelWidth == 5_120)
        #expect(capped.sourcePixelHeight == 2_880)
        try await pipeline.stop(slot: 0)
    }

    @Test("metadata failure restores the previous capture configuration")
    func geometryMetadataFailureRollback() async throws {
        let host = FakeSlotHost()
        let session = FixtureCaptureSession(
            frameConsumer: { _ in .accepted },
            deliversStartupFrame: false
        )
        let pipeline = LiveShareCapturePipeline(
            host: host,
            sessionFactory: { _, _, _ in session }
        )
        let generation = UUID()
        let original = Self.descriptor()
        try await pipeline.start(original, inSlot: 0, generation: generation)
        host.rejectNextMetadataUpdate()
        let updated = LiveShareCaptureDescriptor(
            source: original.source,
            target: original.target,
            sourcePixelWidth: 5_120,
            sourcePixelHeight: 2_880,
            video: CaptureVideoConfiguration(width: 4_096, height: 2_304),
            stream: GoPeepV1StreamInfo(
                trackID: "video0",
                windowName: "Fixture",
                appName: "Tests",
                isFocused: true,
                width: 4_096,
                height: 2_304
            )
        )

        await #expect(throws: FixtureCaptureError.metadataUpdateFailed) {
            try await pipeline.update(updated, inSlot: 0, expectedGeneration: generation)
        }
        #expect(session.updatedGeometry == [
            CaptureVideoConfiguration(width: 4_096, height: 2_304),
            original.video,
        ])
        #expect(host.timeline.last == .metadataUpdated(
            slot: 0,
            width: original.stream.width,
            height: original.stream.height
        ))
        try await pipeline.stop(slot: 0)
    }

    @Test("encoded alignment metadata does not rescale native odd capture")
    func metadataOnlyAlignmentUpdate() async throws {
        let host = FakeSlotHost()
        let session = FixtureCaptureSession(
            frameConsumer: { _ in .accepted },
            deliversStartupFrame: false
        )
        let pipeline = LiveShareCapturePipeline(
            host: host,
            sessionFactory: { _, _, _ in session }
        )
        let generation = UUID()
        let source = LiveShareWindowSource(
            id: LiveShareWindowID(rawValue: 42),
            windowName: "Odd Fixture",
            appName: "Tests"
        )
        let nativeVideo = CaptureVideoConfiguration(width: 1_605, height: 1_108)
        let original = LiveShareCaptureDescriptor(
            source: .window(source),
            target: .window(id: 42),
            video: nativeVideo,
            stream: GoPeepV1StreamInfo(
                trackID: "video0",
                windowName: "Odd Fixture",
                appName: "Tests",
                isFocused: true,
                width: 1_605,
                height: 1_108
            )
        )
        try await pipeline.start(original, inSlot: 0, generation: generation)

        let h264Aligned = LiveShareCaptureDescriptor(
            source: original.source,
            target: original.target,
            video: nativeVideo,
            stream: GoPeepV1StreamInfo(
                trackID: "video0",
                windowName: "Odd Fixture",
                appName: "Tests",
                isFocused: true,
                width: 1_604,
                height: 1_108
            )
        )
        try await pipeline.update(
            h264Aligned,
            inSlot: 0,
            expectedGeneration: generation
        )

        #expect(session.updatedGeometry.isEmpty)
        #expect(host.latestConfiguration == .init(
            slot: 0,
            captureWidth: 1_605,
            captureHeight: 1_108,
            streamWidth: 1_604,
            streamHeight: 1_108
        ))
        try await pipeline.stop(slot: 0)
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

    @Test("system audio enables its negotiated sender before capture starts")
    func systemAudioEnableBeforeStart() async throws {
        let host = FakeSlotHost()
        let factory = FixtureAudioSessionFactory(deliversStartupSample: true)
        let pipeline = Self.pipeline(host: host, audioFactory: factory)
        let request = Self.audioRequest(
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )

        try await pipeline.setSystemAudio(request)

        #expect(host.timeline == [
            .systemAudioEnabled(true),
            .systemAudioSent,
        ])
        #expect(factory.latestSession?.startRequests == [request])
        #expect(await pipeline.isSystemAudioActive)
        try await pipeline.setSystemAudio(nil)
    }

    @Test("application audio scope updates in place and deduplicates identical requests")
    func systemAudioApplicationScopeUpdate() async throws {
        let host = FakeSlotHost()
        let factory = FixtureAudioSessionFactory()
        let pipeline = Self.pipeline(host: host, audioFactory: factory)
        let initial = Self.audioRequest(
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            bundleIdentifiers: ["com.example.browser"]
        )
        let updated = Self.audioRequest(
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            bundleIdentifiers: [
                "com.example.browser",
                " com.example.browser ",
                "com.example.player",
            ]
        )

        try await pipeline.setSystemAudio(initial)
        try await pipeline.setSystemAudio(updated)
        try await pipeline.setSystemAudio(updated)

        #expect(factory.creationCount == 1)
        #expect(factory.latestSession?.startRequests == [initial])
        #expect(factory.latestSession?.updateRequests == [updated])
        #expect(updated.scope == .applications(
            displayID: 42,
            bundleIdentifiers: ["com.example.browser", "com.example.player"]
        ))
        #expect(factory.latestSession?.stopCount == 0)
        try await pipeline.setSystemAudio(nil)
    }

    @Test("disabling system audio stops capture and disables its sender")
    func systemAudioDisable() async throws {
        let host = FakeSlotHost()
        let factory = FixtureAudioSessionFactory()
        let pipeline = Self.pipeline(host: host, audioFactory: factory)

        try await pipeline.setSystemAudio(Self.audioRequest())
        try await pipeline.setSystemAudio(nil)
        try await pipeline.setSystemAudio(nil)

        #expect(factory.latestSession?.stopCount == 1)
        #expect(host.timeline == [
            .systemAudioEnabled(true),
            .systemAudioEnabled(false),
            .systemAudioEnabled(false),
        ])
        #expect(!(await pipeline.isSystemAudioActive))
    }

    @Test("system-audio startup failure rolls back capture and sender state")
    func systemAudioStartupFailureRollback() async {
        let host = FakeSlotHost()
        let factory = FixtureAudioSessionFactory(
            startupError: .audioStartFailed,
            runsBeforeStartupFailure: true
        )
        let pipeline = Self.pipeline(host: host, audioFactory: factory)
        let request = Self.audioRequest()

        await #expect(throws: FixtureCaptureError.audioStartFailed) {
            try await pipeline.setSystemAudio(request)
        }

        #expect(factory.latestSession?.startRequests == [request])
        #expect(factory.latestSession?.stopCount == 1)
        #expect(host.timeline == [
            .systemAudioEnabled(true),
            .systemAudioEnabled(false),
        ])
        #expect(!(await pipeline.isSystemAudioActive))
    }

    @Test("stopAll drains system audio together with active video slots")
    func stopAllIncludesSystemAudio() async throws {
        let host = FakeSlotHost()
        let factory = FixtureAudioSessionFactory()
        let pipeline = Self.pipeline(host: host, audioFactory: factory)

        try await pipeline.start(Self.descriptor(), inSlot: 0)
        try await pipeline.setSystemAudio(Self.audioRequest())
        await pipeline.stopAll()

        #expect(factory.latestSession?.stopCount == 1)
        #expect(host.timeline == [
            .activated(0),
            .sent(0),
            .systemAudioEnabled(true),
            .systemAudioEnabled(false),
            .deactivated(0),
        ])
        #expect(await pipeline.activeSlots.isEmpty)
        #expect(!(await pipeline.isSystemAudioActive))
    }

    private static func pipeline(
        host: FakeSlotHost,
        audioFactory: FixtureAudioSessionFactory
    ) -> LiveShareCapturePipeline {
        LiveShareCapturePipeline(
            host: host,
            sessionFactory: { _, frameConsumer, _ in
                FixtureCaptureSession(frameConsumer: frameConsumer)
            },
            audioSessionFactory: { sampleConsumer, eventConsumer in
                audioFactory.make(
                    sampleConsumer: sampleConsumer,
                    eventConsumer: eventConsumer
                )
            }
        )
    }

    private static func audioRequest(
        identifier: UUID = UUID(),
        bundleIdentifiers: Set<String> = ["com.example.browser"]
    ) -> CaptureAudioSessionRequest {
        CaptureAudioSessionRequest(
            identifier: identifier,
            scope: .applications(
                displayID: 42,
                bundleIdentifiers: bundleIdentifiers
            )
        )
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
}

private final class FakeSlotHost: LiveShareVideoSlotHosting, @unchecked Sendable {
    struct Configuration: Equatable {
        let slot: Int
        let captureWidth: Int
        let captureHeight: Int
        let streamWidth: Int
        let streamHeight: Int
    }

    enum Event: Equatable {
        case activated(Int)
        case sent(Int)
        case metadataUpdated(slot: Int, width: Int, height: Int)
        case deactivated(Int)
        case systemAudioEnabled(Bool)
        case systemAudioSent
    }

    private let lock = NSLock()
    private var activeSlots = Set<Int>()
    private var storedTimeline: [Event] = []
    private var rejectsNextMetadata = false
    private var storedLatestConfiguration: Configuration?

    var timeline: [Event] {
        lock.withLock { storedTimeline }
    }

    var latestConfiguration: Configuration? {
        lock.withLock { storedLatestConfiguration }
    }

    func rejectNextMetadataUpdate() {
        lock.withLock { rejectsNextMetadata = true }
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

    func activateSlot(
        _ slot: Int,
        metadata: GoPeepV1StreamInfo,
        captureGeometry: WebRTCVideoCaptureGeometry
    ) throws {
        lock.withLock {
            activeSlots.insert(slot)
            storedLatestConfiguration = Configuration(
                slot: slot,
                captureWidth: captureGeometry.width,
                captureHeight: captureGeometry.height,
                streamWidth: metadata.width,
                streamHeight: metadata.height
            )
            storedTimeline.append(.activated(slot))
        }
    }

    func updateSlotMetadata(
        _ slot: Int,
        metadata: GoPeepV1StreamInfo,
        captureGeometry: WebRTCVideoCaptureGeometry
    ) throws {
        try lock.withLock {
            guard activeSlots.contains(slot) else {
                throw LiveShareCapturePipelineError.slotInactive(slot)
            }
            if rejectsNextMetadata {
                rejectsNextMetadata = false
                throw FixtureCaptureError.metadataUpdateFailed
            }
            storedLatestConfiguration = Configuration(
                slot: slot,
                captureWidth: captureGeometry.width,
                captureHeight: captureGeometry.height,
                streamWidth: metadata.width,
                streamHeight: metadata.height
            )
            storedTimeline.append(.metadataUpdated(
                slot: slot,
                width: metadata.width,
                height: metadata.height
            ))
        }
    }

    func deactivateSlot(_ slot: Int) {
        lock.withLock {
            activeSlots.remove(slot)
            storedTimeline.append(.deactivated(slot))
        }
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        lock.withLock {
            storedTimeline.append(.systemAudioEnabled(enabled))
        }
    }

    func send(_ sample: BorrowedCaptureAudioSample) -> Bool {
        lock.withLock {
            storedTimeline.append(.systemAudioSent)
            return true
        }
    }
}

private final class FixtureAudioSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let startupError: FixtureCaptureError?
    private let runsBeforeStartupFailure: Bool
    private let deliversStartupSample: Bool
    private var storedSessions: [FixtureAudioSession] = []

    init(
        startupError: FixtureCaptureError? = nil,
        runsBeforeStartupFailure: Bool = false,
        deliversStartupSample: Bool = false
    ) {
        self.startupError = startupError
        self.runsBeforeStartupFailure = runsBeforeStartupFailure
        self.deliversStartupSample = deliversStartupSample
    }

    var creationCount: Int {
        lock.withLock { storedSessions.count }
    }

    var latestSession: FixtureAudioSession? {
        lock.withLock { storedSessions.last }
    }

    func make(
        sampleConsumer: @escaping ScreenCaptureAudioSession.SampleConsumer,
        eventConsumer: @escaping ScreenCaptureAudioSession.EventConsumer
    ) -> any LiveShareAudioCaptureSession {
        let session = FixtureAudioSession(
            sampleConsumer: sampleConsumer,
            eventConsumer: eventConsumer,
            startupError: startupError,
            runsBeforeStartupFailure: runsBeforeStartupFailure,
            deliversStartupSample: deliversStartupSample
        )
        lock.withLock { storedSessions.append(session) }
        return session
    }
}

private final class FixtureAudioSession: LiveShareAudioCaptureSession, @unchecked Sendable {
    private let lock = NSLock()
    private let sampleConsumer: ScreenCaptureAudioSession.SampleConsumer
    private let eventConsumer: ScreenCaptureAudioSession.EventConsumer
    private let startupError: FixtureCaptureError?
    private let runsBeforeStartupFailure: Bool
    private let deliversStartupSample: Bool
    private var running = false
    private var storedStartRequests: [CaptureAudioSessionRequest] = []
    private var storedUpdateRequests: [CaptureAudioSessionRequest] = []
    private var storedStopCount = 0

    init(
        sampleConsumer: @escaping ScreenCaptureAudioSession.SampleConsumer,
        eventConsumer: @escaping ScreenCaptureAudioSession.EventConsumer,
        startupError: FixtureCaptureError?,
        runsBeforeStartupFailure: Bool,
        deliversStartupSample: Bool
    ) {
        self.sampleConsumer = sampleConsumer
        self.eventConsumer = eventConsumer
        self.startupError = startupError
        self.runsBeforeStartupFailure = runsBeforeStartupFailure
        self.deliversStartupSample = deliversStartupSample
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var startRequests: [CaptureAudioSessionRequest] {
        lock.withLock { storedStartRequests }
    }

    var updateRequests: [CaptureAudioSessionRequest] {
        lock.withLock { storedUpdateRequests }
    }

    var stopCount: Int {
        lock.withLock { storedStopCount }
    }

    func start(_ request: CaptureAudioSessionRequest) async throws {
        lock.withLock {
            storedStartRequests.append(request)
            if startupError == nil || runsBeforeStartupFailure {
                running = true
            }
        }
        if let startupError { throw startupError }
        if deliversStartupSample {
            sampleConsumer(BorrowedCaptureAudioSample(
                sampleBuffer: try makeFixtureAudioSample()
            ))
        }
        eventConsumer(.started(request.identifier))
    }

    func stop() async throws {
        lock.withLock {
            running = false
            storedStopCount += 1
        }
    }

    func update(_ request: CaptureAudioSessionRequest) async throws {
        lock.withLock { storedUpdateRequests.append(request) }
        eventConsumer(.updated(request.identifier))
    }
}

private enum FixtureCaptureError: Error, Equatable {
    case startFailed
    case audioStartFailed
    case metadataUpdateFailed
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
    private let deliversStartupFrame: Bool
    private let startGate: FixtureAsyncGate?
    private let stopGate: FixtureAsyncGate?
    private var running = false
    private var storedStatistics = CaptureDeliveryStatistics()
    private var storedUpdatedGeometry: [CaptureVideoConfiguration] = []

    init(
        frameConsumer: @escaping ScreenCaptureSession.FrameConsumer,
        startupError: FixtureCaptureError? = nil,
        deliversStartupFrame: Bool = true,
        startGate: FixtureAsyncGate? = nil,
        stopGate: FixtureAsyncGate? = nil
    ) {
        self.frameConsumer = frameConsumer
        self.startupError = startupError
        self.deliversStartupFrame = deliversStartupFrame
        self.startGate = startGate
        self.stopGate = stopGate
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var statistics: CaptureDeliveryStatistics {
        lock.withLock { storedStatistics }
    }

    var updatedGeometry: [CaptureVideoConfiguration] {
        lock.withLock { storedUpdatedGeometry }
    }

    func start(_ request: CaptureSessionRequest) async throws {
        if let startupError { throw startupError }
        await startGate?.suspend()
        lock.withLock { running = true }
        guard deliversStartupFrame else { return }
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
    ) async throws {
        lock.withLock { storedUpdatedGeometry.append(video) }
    }
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

private enum FixtureAudioError: Error {
    case blockBuffer(OSStatus)
    case format(OSStatus)
    case sample(OSStatus)
}

private func makeFixtureAudioSample() throws -> CMSampleBuffer {
    let frameCount = 16
    let channelCount: UInt32 = 2
    let bytesPerFrame = channelCount * UInt32(MemoryLayout<Float>.size)
    let byteCount = frameCount * Int(bytesPerFrame)
    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
        throw FixtureAudioError.blockBuffer(blockStatus)
    }

    var description = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: channelCount,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &description,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
        throw FixtureAudioError.format(formatStatus)
    }

    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: frameCount,
        presentationTimeStamp: .zero,
        packetDescriptions: nil,
        sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
        throw FixtureAudioError.sample(sampleStatus)
    }
    return sampleBuffer
}
