import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation

enum MeshParticipantCapturePublisherError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case missingMediaSlot
    case duplicateSource
    case unknownSource
    case sourceLimit

    var errorDescription: String? {
        switch self {
        case .missingMediaSlot:
            "The native-v3 media engine has no matching video slot."
        case .duplicateSource:
            "This local source is already being shared."
        case .unknownSource:
            "This local source is not being shared."
        case .sourceLimit:
            "The participant has reached the active source limit."
        }
    }
}

enum MeshParticipantCaptureFailure: Equatable, Sendable {
    case source(
        sourceInstanceID: ClipLiveShareSourceInstanceID,
        message: String
    )
    case systemAudio(message: String)
}

/// Owns the local participant's transient raw capture pipeline. Raw frames are
/// submitted to the shared native-v3 factory and are never copied into room
/// state; only compressed tracks and authenticated source descriptors leave
/// this object.
actor MeshParticipantCapturePublisher {
    struct ActiveSource: Sendable {
        let slot: Int
        let generation: UUID
        let capture: LiveShareCaptureDescriptor
        let published: ClipLiveShareNativeV3PublishedSource
    }

    typealias SourcePublisher = @Sendable (
        [ClipLiveShareNativeV3PublishedSource]
    ) async throws -> Void
    private let factory: ClipLiveShareNativeV3WebRTCTransportFactory
    private lazy var pipeline = LiveShareCapturePipeline(
        host: factory,
        eventHandler: { [weak self] event in
            Task {
                await self?.handlePipelineEvent(event)
            }
        }
    )
    private let maximumActiveSources: Int
    private let publishSources: SourcePublisher
    private let failureStream: AsyncStream<MeshParticipantCaptureFailure>
    private let failureContinuation:
        AsyncStream<MeshParticipantCaptureFailure>.Continuation
    private var activeBySource:
        [ClipLiveShareSourceInstanceID: ActiveSource] = [:]

    init(
        factory: ClipLiveShareNativeV3WebRTCTransportFactory,
        maximumActiveSources: Int =
            ClipLiveShareNativeV3.defaultMaximumActiveSourcesPerParticipant,
        publishSources: @escaping SourcePublisher
    ) {
        let (failureStream, failureContinuation) = AsyncStream.makeStream(
            of: MeshParticipantCaptureFailure.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        self.factory = factory
        self.maximumActiveSources = min(
            max(1, maximumActiveSources),
            ClipLiveShareNativeV3.maximumSourcesPerParticipant
        )
        self.publishSources = publishSources
        self.failureStream = failureStream
        self.failureContinuation = failureContinuation
    }

    var activeSources: [ActiveSource] {
        activeBySource.values.sorted { $0.slot < $1.slot }
    }

    func failures() -> AsyncStream<MeshParticipantCaptureFailure> {
        failureStream
    }

    func start(
        ownerParticipantID: ClipLiveShareNativeV3ParticipantID,
        sourceInstanceID: ClipLiveShareSourceInstanceID,
        capture descriptor: LiveShareCaptureDescriptor,
        preferredSlot: Int? = nil
    ) async throws {
        guard activeBySource[sourceInstanceID] == nil else {
            throw MeshParticipantCapturePublisherError.duplicateSource
        }
        guard activeBySource.count < maximumActiveSources else {
            throw MeshParticipantCapturePublisherError.sourceLimit
        }
        let occupied = Set(activeBySource.values.map(\.slot))
        let available = factory.slotSnapshots
            .map(\.index)
            .filter { !occupied.contains($0) }
            .sorted()
        let slot = if let preferredSlot, available.contains(preferredSlot) {
            preferredSlot
        } else if let first = available.first {
            first
        } else {
            throw MeshParticipantCapturePublisherError.missingMediaSlot
        }
        guard
            let trackID = factory.slotSnapshots.first(where: {
                $0.index == slot
            })?.trackID
        else {
            throw MeshParticipantCapturePublisherError.missingMediaSlot
        }
        let stream = try rewrite(
            descriptor.stream,
            mediaTrackID: ClipLiveShareMediaTrackID(rawValue: trackID),
            order: slot
        )
        let capture = LiveShareCaptureDescriptor(
            source: descriptor.source,
            target: descriptor.target,
            sourcePixelWidth: descriptor.sourcePixelWidth,
            sourcePixelHeight: descriptor.sourcePixelHeight,
            video: descriptor.video,
            stream: stream
        )
        let published = try ClipLiveShareNativeV3PublishedSource(
            key: .init(
                ownerParticipantID: ownerParticipantID,
                sourceInstanceID: sourceInstanceID
            ),
            descriptor: .init(
                sourceInstanceID: sourceInstanceID,
                stream: stream
            )
        )
        let generation = UUID()
        try await pipeline.start(
            capture,
            inSlot: slot,
            generation: generation
        )
        activeBySource[sourceInstanceID] = ActiveSource(
            slot: slot,
            generation: generation,
            capture: capture,
            published: published
        )
        do {
            try await publishCurrentSources()
        } catch {
            activeBySource[sourceInstanceID] = nil
            try? await pipeline.stop(slot: slot)
            throw error
        }
    }

    func update(
        sourceInstanceID: ClipLiveShareSourceInstanceID,
        capture descriptor: LiveShareCaptureDescriptor
    ) async throws {
        guard let current = activeBySource[sourceInstanceID] else {
            throw MeshParticipantCapturePublisherError.unknownSource
        }
        let stream = try rewrite(
            descriptor.stream,
            mediaTrackID: current.capture.stream.mediaTrackID,
            order: current.slot
        )
        let capture = LiveShareCaptureDescriptor(
            source: descriptor.source,
            target: descriptor.target,
            sourcePixelWidth: descriptor.sourcePixelWidth,
            sourcePixelHeight: descriptor.sourcePixelHeight,
            video: descriptor.video,
            stream: stream
        )
        let published = try ClipLiveShareNativeV3PublishedSource(
            key: current.published.key,
            descriptor: .init(
                sourceInstanceID: sourceInstanceID,
                stream: stream
            )
        )
        try await pipeline.update(
            capture,
            inSlot: current.slot,
            expectedGeneration: current.generation
        )
        activeBySource[sourceInstanceID] = ActiveSource(
            slot: current.slot,
            generation: current.generation,
            capture: capture,
            published: published
        )
        try await publishCurrentSources()
    }

    func stop(
        sourceInstanceID: ClipLiveShareSourceInstanceID
    ) async throws {
        guard let current = activeBySource.removeValue(
            forKey: sourceInstanceID
        ) else {
            throw MeshParticipantCapturePublisherError.unknownSource
        }
        try await pipeline.stop(slot: current.slot)
        try await publishCurrentSources()
    }

    func setSystemAudio(_ request: CaptureAudioSessionRequest?) async throws {
        try await pipeline.setSystemAudio(request)
    }

    func stopAll() async {
        await pipeline.stopAll()
        activeBySource.removeAll()
        try? await publishCurrentSources()
    }

    private func handlePipelineEvent(
        _ event: LiveShareCapturePipelineEvent
    ) async {
        switch event {
        case let .sourceFailed(slot, _, generation, message):
            guard let entry = activeBySource.first(where: {
                $0.value.slot == slot
                    && $0.value.generation == generation
            }) else {
                return
            }
            activeBySource[entry.key] = nil
            try? await pipeline.stop(slot: slot)
            do {
                try await publishCurrentSources()
            } catch {
                failureContinuation.yield(.source(
                    sourceInstanceID: entry.key,
                    message:
                        "\(message) \(error.localizedDescription)"
                ))
                return
            }
            failureContinuation.yield(.source(
                sourceInstanceID: entry.key,
                message: message
            ))
        case let .systemAudioFailed(message):
            failureContinuation.yield(.systemAudio(message: message))
        case .sourceStarted, .sourceStopped:
            break
        }
    }

    private func publishCurrentSources() async throws {
        try await publishSources(
            activeBySource.values
                .sorted { $0.slot < $1.slot }
                .map(\.published)
        )
    }

    private func rewrite(
        _ descriptor: ClipLiveShareStreamDescriptor,
        mediaTrackID: ClipLiveShareMediaTrackID,
        order: Int
    ) throws -> ClipLiveShareStreamDescriptor {
        try ClipLiveShareStreamDescriptor(
            id: descriptor.id,
            mediaTrackID: mediaTrackID,
            active: descriptor.active,
            focused: descriptor.focused,
            appName: descriptor.appName,
            windowName: descriptor.windowName,
            width: descriptor.width,
            height: descriptor.height,
            order: order,
            sourcePointWidth: descriptor.sourcePointWidth,
            sourcePointHeight: descriptor.sourcePointHeight
        )
    }

}
