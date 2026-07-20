import ClipCapture
import ClipLiveShare
import Foundation

public protocol LiveShareVideoSlotHosting: AnyObject, Sendable {
    @discardableResult
    func send(
        _ frame: BorrowedCaptureVideoFrame,
        toSlot slot: Int
    ) -> CaptureFrameDisposition

    func activateSlot(
        _ slot: Int,
        metadata: GoPeepV1StreamInfo,
        captureGeometry: WebRTCVideoCaptureGeometry
    ) throws
    func updateSlotMetadata(
        _ slot: Int,
        metadata: GoPeepV1StreamInfo,
        captureGeometry: WebRTCVideoCaptureGeometry
    ) throws
    func deactivateSlot(_ slot: Int)
}

protocol LiveShareCaptureSession: AnyObject, Sendable {
    var isRunning: Bool { get }
    var statistics: CaptureDeliveryStatistics { get }

    func start(_ request: CaptureSessionRequest) async throws
    func stop() async throws
    func update(
        target: CaptureTarget,
        video: CaptureVideoConfiguration
    ) async throws
}

extension ScreenCaptureSession: LiveShareCaptureSession {}

private final class LiveShareCaptureStartCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !isComplete else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func signal() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isComplete else { return [] }
            isComplete = true
            defer { waiters.removeAll(keepingCapacity: false) }
            return waiters
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
}

public struct LiveShareCaptureDescriptor: Equatable, Sendable {
    public let source: LiveShareSource
    public let target: CaptureTarget
    /// Native source pixels are kept separately from the transmitted capture
    /// geometry. H.264 may intentionally aspect-fit a 5K/6K source while VP8
    /// continues to request the native dimensions.
    public let sourcePixelWidth: Int
    public let sourcePixelHeight: Int
    public let video: CaptureVideoConfiguration
    public let stream: GoPeepV1StreamInfo

    public var captureGeometry: WebRTCVideoCaptureGeometry {
        WebRTCVideoCaptureGeometry(width: video.width, height: video.height)
    }

    public init(
        source: LiveShareSource,
        target: CaptureTarget,
        sourcePixelWidth: Int? = nil,
        sourcePixelHeight: Int? = nil,
        video: CaptureVideoConfiguration,
        stream: GoPeepV1StreamInfo
    ) {
        self.source = source
        self.target = target
        self.sourcePixelWidth = max(1, sourcePixelWidth ?? video.width)
        self.sourcePixelHeight = max(1, sourcePixelHeight ?? video.height)
        self.video = video
        self.stream = stream
    }
}

public enum LiveShareCapturePipelineEvent: Sendable {
    case sourceStarted(slot: Int, source: LiveShareSource, generation: UUID)
    case sourceStopped(slot: Int, source: LiveShareSource, generation: UUID)
    case sourceFailed(
        slot: Int,
        source: LiveShareSource,
        generation: UUID,
        message: String
    )
}

public enum LiveShareCapturePipelineError: Error, Equatable, Sendable {
    case invalidSlot(Int)
    case slotAlreadyActive(Int)
    case slotInactive(Int)
    case superseded(Int)
    case updateRollbackFailed(slot: Int, update: String, rollback: String)
}

/// An atomic identity + counter snapshot for one active capture. Keeping the
/// generation beside the cumulative counters lets MainActor consumers reject a
/// result that arrives after a slot was stopped or reused.
public struct LiveShareCaptureDeliverySnapshot: Equatable, Sendable {
    public let slot: Int
    public let source: LiveShareSource
    public let generation: UUID
    public let statistics: CaptureDeliveryStatistics

    public init(
        slot: Int,
        source: LiveShareSource,
        generation: UUID,
        statistics: CaptureDeliveryStatistics
    ) {
        self.slot = slot
        self.source = source
        self.generation = generation
        self.statistics = statistics
    }
}

/// Owns transient ScreenCaptureKit sessions only. It never imports recording,
/// AVAssetWriter, History, Preview, or Storage.
public actor LiveShareCapturePipeline {
    public typealias EventHandler = @Sendable (LiveShareCapturePipelineEvent) -> Void

    typealias SessionFactory = @Sendable (
        _ queueLabel: String,
        _ frameConsumer: @escaping ScreenCaptureSession.FrameConsumer,
        _ eventConsumer: @escaping ScreenCaptureSession.EventConsumer
    ) -> any LiveShareCaptureSession

    private struct ActiveSource: @unchecked Sendable {
        let descriptor: LiveShareCaptureDescriptor
        let generation: UUID
        let session: any LiveShareCaptureSession
        let startCompletion: LiveShareCaptureStartCompletion
    }

    private let host: any LiveShareVideoSlotHosting
    private let eventHandler: EventHandler
    private let sessionFactory: SessionFactory
    private var active: [Int: ActiveSource] = [:]
    private var retiringSlots = Set<Int>()

    public init(
        host: any LiveShareVideoSlotHosting,
        eventHandler: @escaping EventHandler = { _ in }
    ) {
        self.host = host
        self.eventHandler = eventHandler
        sessionFactory = { queueLabel, frameConsumer, eventConsumer in
            ScreenCaptureSession(
                queueLabel: queueLabel,
                frameConsumer: frameConsumer,
                eventConsumer: eventConsumer
            )
        }
    }

    init(
        host: any LiveShareVideoSlotHosting,
        eventHandler: @escaping EventHandler = { _ in },
        sessionFactory: @escaping SessionFactory
    ) {
        self.host = host
        self.eventHandler = eventHandler
        self.sessionFactory = sessionFactory
    }

    public var activeSlots: [Int] {
        active.keys.sorted()
    }

    public func start(
        _ descriptor: LiveShareCaptureDescriptor,
        inSlot slot: Int,
        generation: UUID = UUID()
    ) async throws {
        try Self.validate(slot)
        guard active[slot] == nil, !retiringSlots.contains(slot) else {
            throw LiveShareCapturePipelineError.slotAlreadyActive(slot)
        }

        let host = host
        let source = descriptor.source
        let eventHandler = eventHandler
        let startCompletion = LiveShareCaptureStartCompletion()
        let session = sessionFactory(
            "com.tomaslejdung.clip.liveshare.video\(slot)",
            { frame in
                host.send(frame, toSlot: slot)
            },
            { event in
                if case let .failed(_, error) = event {
                    eventHandler(.sourceFailed(
                        slot: slot,
                        source: source,
                        generation: generation,
                        message: error.localizedDescription
                    ))
                }
            }
        )
        active[slot] = ActiveSource(
            descriptor: descriptor,
            generation: generation,
            session: session,
            startCompletion: startCompletion
        )
        defer { startCompletion.signal() }
        var activatedHostSlot = false
        do {
            // Enable the negotiated WebRTC track before ScreenCaptureKit starts.
            // `startCapture()` may synchronously deliver the only complete frame
            // for an otherwise idle window before its async call returns.
            try host.activateSlot(
                slot,
                metadata: descriptor.stream,
                captureGeometry: descriptor.captureGeometry
            )
            activatedHostSlot = true
            try await session.start(CaptureSessionRequest(
                target: descriptor.target,
                video: descriptor.video
            ))
            guard let current = active[slot],
                  current.generation == generation,
                  current.session === session else {
                if session.isRunning { try? await session.stop() }
                throw LiveShareCapturePipelineError.superseded(slot)
            }
            eventHandler(.sourceStarted(
                slot: slot,
                source: source,
                generation: generation
            ))
        } catch {
            let stillOwnsSlot = active[slot]?.generation == generation
            if stillOwnsSlot {
                active[slot] = nil
            }
            if session.isRunning { try? await session.stop() }
            // A stop/replacement can interleave while `session.start` awaits.
            // Only tear down the track when this generation still owns it;
            // otherwise `stop(slot:)` already did so or a replacement owns it.
            if activatedHostSlot && stillOwnsSlot {
                host.deactivateSlot(slot)
            }
            throw error
        }
    }

    public func stop(slot: Int) async throws {
        try Self.validate(slot)
        guard let source = active.removeValue(forKey: slot) else {
            throw LiveShareCapturePipelineError.slotInactive(slot)
        }
        retiringSlots.insert(slot)
        defer { retiringSlots.remove(slot) }
        host.deactivateSlot(slot)
        await source.startCompletion.wait()
        if source.session.isRunning {
            try await source.session.stop()
        }
        eventHandler(.sourceStopped(
            slot: slot,
            source: source.descriptor.source,
            generation: source.generation
        ))
    }

    /// Updates an active ScreenCaptureKit stream in place. This keeps the
    /// negotiated WebRTC slot enabled, avoiding a stop/start gap when cadence
    /// or exact source geometry changes.
    public func update(
        _ descriptor: LiveShareCaptureDescriptor,
        inSlot slot: Int,
        expectedGeneration: UUID
    ) async throws {
        try Self.validate(slot)
        guard let source = active[slot],
              source.generation == expectedGeneration else {
            throw LiveShareCapturePipelineError.slotInactive(slot)
        }
        let captureChanged = source.descriptor.target != descriptor.target
            || source.descriptor.video != descriptor.video
        do {
            if captureChanged {
                try await source.session.update(
                    target: descriptor.target,
                    video: descriptor.video
                )
            }
        } catch {
            guard let current = active[slot],
                  current.generation == expectedGeneration,
                  current.session === source.session else {
                throw LiveShareCapturePipelineError.superseded(slot)
            }
            do {
                if captureChanged {
                    try await source.session.update(
                        target: source.descriptor.target,
                        video: source.descriptor.video
                    )
                }
                try host.updateSlotMetadata(
                    slot,
                    metadata: source.descriptor.stream,
                    captureGeometry: source.descriptor.captureGeometry
                )
            } catch let rollbackError {
                throw LiveShareCapturePipelineError.updateRollbackFailed(
                    slot: slot,
                    update: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
        guard let current = active[slot],
              current.generation == expectedGeneration,
              current.session === source.session else {
            throw LiveShareCapturePipelineError.superseded(slot)
        }
        do {
            try host.updateSlotMetadata(
                slot,
                metadata: descriptor.stream,
                captureGeometry: descriptor.captureGeometry
            )
        } catch {
            do {
                if captureChanged {
                    try await source.session.update(
                        target: source.descriptor.target,
                        video: source.descriptor.video
                    )
                }
                try host.updateSlotMetadata(
                    slot,
                    metadata: source.descriptor.stream,
                    captureGeometry: source.descriptor.captureGeometry
                )
            } catch let rollbackError {
                throw LiveShareCapturePipelineError.updateRollbackFailed(
                    slot: slot,
                    update: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
        active[slot] = ActiveSource(
            descriptor: descriptor,
            generation: expectedGeneration,
            session: source.session,
            startCompletion: source.startCompletion
        )
    }

    public func stopAll() async {
        let slots = active.keys.sorted()
        for slot in slots {
            try? await stop(slot: slot)
        }
    }

    public func statistics(for slot: Int) -> CaptureDeliveryStatistics? {
        active[slot]?.session.statistics
    }

    public func deliveryStatisticsSnapshots() -> [LiveShareCaptureDeliverySnapshot] {
        active.keys.sorted().compactMap { slot in
            guard let source = active[slot] else { return nil }
            return LiveShareCaptureDeliverySnapshot(
                slot: slot,
                source: source.descriptor.source,
                generation: source.generation,
                statistics: source.session.statistics
            )
        }
    }

    private static func validate(_ slot: Int) throws {
        guard (0 ..< WebRTCRuntimeIdentity.maximumVideoSlots).contains(slot) else {
            throw LiveShareCapturePipelineError.invalidSlot(slot)
        }
    }
}
