import ClipCapture
import ClipLiveShare
import Foundation

public protocol LiveShareVideoSlotHosting: AnyObject, Sendable {
    @discardableResult
    func send(
        _ frame: BorrowedCaptureVideoFrame,
        toSlot slot: Int
    ) -> CaptureFrameDisposition

    func activateSlot(_ slot: Int, metadata: GoPeepV1StreamInfo) throws
    func deactivateSlot(_ slot: Int)
}

public struct LiveShareCaptureDescriptor: Equatable, Sendable {
    public let source: LiveShareSource
    public let target: CaptureTarget
    public let video: CaptureVideoConfiguration
    public let stream: GoPeepV1StreamInfo

    public init(
        source: LiveShareSource,
        target: CaptureTarget,
        video: CaptureVideoConfiguration,
        stream: GoPeepV1StreamInfo
    ) {
        self.source = source
        self.target = target
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

    private struct ActiveSource: @unchecked Sendable {
        let descriptor: LiveShareCaptureDescriptor
        let generation: UUID
        let session: ScreenCaptureSession
    }

    private let host: any LiveShareVideoSlotHosting
    private let eventHandler: EventHandler
    private var active: [Int: ActiveSource] = [:]

    public init(
        host: any LiveShareVideoSlotHosting,
        eventHandler: @escaping EventHandler = { _ in }
    ) {
        self.host = host
        self.eventHandler = eventHandler
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
        guard active[slot] == nil else {
            throw LiveShareCapturePipelineError.slotAlreadyActive(slot)
        }

        let host = host
        let source = descriptor.source
        let eventHandler = eventHandler
        let session = ScreenCaptureSession(
            queueLabel: "com.tomaslejdung.clip.liveshare.video\(slot)",
            frameConsumer: { frame in
                host.send(frame, toSlot: slot)
            },
            eventConsumer: { event in
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
            session: session
        )
        var activatedHostSlot = false
        do {
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
            try host.activateSlot(slot, metadata: descriptor.stream)
            activatedHostSlot = true
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
            if stillOwnsSlot || activatedHostSlot {
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
        host.deactivateSlot(slot)
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
        try await source.session.update(
            target: descriptor.target,
            video: descriptor.video
        )
        guard let current = active[slot],
              current.generation == expectedGeneration,
              current.session === source.session else {
            throw LiveShareCapturePipelineError.superseded(slot)
        }
        active[slot] = ActiveSource(
            descriptor: descriptor,
            generation: expectedGeneration,
            session: source.session
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
