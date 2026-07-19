import ClipCapture
import ClipLiveShare
import Foundation
@preconcurrency import WebRTC

/// A native GoPeep v1-compatible WebRTC host.
///
/// The host creates one libwebrtc factory and four stable screen-cast tracks.
/// Every viewer gets its own peer connection while sharing those four sources,
/// which keeps track and stream identifiers stable across activation changes.
public final class WebRTCPeerHost: LiveShareVideoSlotHosting, @unchecked Sendable {
    public typealias EventHandler = @Sendable (WebRTCPeerHostEvent) -> Void

    private final class Slot: @unchecked Sendable {
        let index: Int
        let trackID: String
        let streamID: String
        let source: RTCVideoSource
        let track: RTCVideoTrack
        let frameSource: WebRTCFrameSource
        var metadata: GoPeepV1StreamInfo?

        init(index: Int, factory: RTCPeerConnectionFactory) {
            self.index = index
            trackID = "video\(index)"
            streamID = "gopeep-stream-\(index)"
            source = factory.videoSource(forScreenCast: true)
            track = factory.videoTrack(with: source, trackId: trackID)
            frameSource = WebRTCFrameSource(source: source)
            track.isEnabled = false
        }

        var snapshot: WebRTCStreamSlotSnapshot {
            WebRTCStreamSlotSnapshot(
                index: index,
                trackID: trackID,
                streamID: streamID,
                metadata: metadata
            )
        }
    }

    private final class PeerContext: @unchecked Sendable {
        let viewerID: String
        let connection: RTCPeerConnection
        let delegate: WebRTCPeerDelegate
        let controlChannel: RTCDataChannel
        let sendersBySlot: [Int: RTCRtpSender]
        var isClosing = false
        var connectionState: WebRTCPeerConnectionState = .new
        var controlDataChannelState: WebRTCControlDataChannelState = .connecting
        var route: WebRTCConnectionRoute = .unknown
        var operationGeneration = WebRTCPeerOperationGeneration()
        var negotiationGeneration: UInt64 = 0
        var awaitingAnswerGeneration: UInt64?
        var answerTimeoutWorkItem: DispatchWorkItem?
        var localICECandidateCount = 0
        var remoteICECandidateCount = 0
        var didReportLocalICECandidateLimit = false
        var awaitsDurableControlDrain = false
        var latestFrameSeedGeneration: UInt64 = 0

        init(
            viewerID: String,
            connection: RTCPeerConnection,
            delegate: WebRTCPeerDelegate,
            controlChannel: RTCDataChannel,
            sendersBySlot: [Int: RTCRtpSender]
        ) {
            self.viewerID = viewerID
            self.connection = connection
            self.delegate = delegate
            self.controlChannel = controlChannel
            self.sendersBySlot = sendersBySlot
        }
    }

    private struct OutboundStatisticsRequest: @unchecked Sendable {
        let viewerID: String
        let slot: Int
        let trackID: String
        let connection: RTCPeerConnection
        let sender: RTCRtpSender
    }

    private struct OutboundStatisticsPlan: @unchecked Sendable {
        let requests: [OutboundStatisticsRequest]
        let slots: [WebRTCStreamSlotSnapshot]
        let connectedViewerCount: Int
    }

    private let configuration: WebRTCPeerHostConfiguration
    private let resourceLimits: WebRTCPeerResourceLimits
    private let controlBufferPolicy: WebRTCControlBufferPolicy
    private var activeSenderPolicy: WebRTCSenderPolicy
    private var senderPoliciesBySlot: [Int: WebRTCSenderPolicy] = [:]
    private let eventQueue: DispatchQueue
    private let eventHandler: EventHandler
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let sslLease: WebRTCSSLRuntimeLease
    private let factory: RTCPeerConnectionFactory
    private let h264Codecs: [RTCRtpCodecCapability]
    private let slots: [Slot]
    private var peers: [String: PeerContext] = [:]
    private var previousOutboundCounters: [
        WebRTCOutboundCounterKey: WebRTCOutboundCounter
    ] = [:]
    private var isClosed = false

    public init(
        configuration: WebRTCPeerHostConfiguration = .goPeepDefault,
        eventQueue: DispatchQueue = .main,
        eventHandler: @escaping EventHandler = { _ in }
    ) throws {
        self.configuration = configuration
        resourceLimits = configuration.resourceLimits.normalized
        controlBufferPolicy = WebRTCControlBufferPolicy(
            resourceLimits: configuration.resourceLimits
        )
        activeSenderPolicy = configuration.senderPolicy
        self.eventQueue = eventQueue
        self.eventHandler = eventHandler
        queue = DispatchQueue(
            label: "com.tomaslejdung.clip.liveshare.webrtc-host",
            qos: .userInteractive
        )
        sslLease = try WebRTCSSLRuntimeLease()
        let peerFactory = RTCPeerConnectionFactory()
        factory = peerFactory
        let codecs = peerFactory
            .rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
            .codecs
            .filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
        guard !codecs.isEmpty else {
            throw WebRTCPeerHostError.h264Unavailable
        }
        h264Codecs = codecs
        slots = (0 ..< WebRTCRuntimeIdentity.maximumVideoSlots).map {
            Slot(index: $0, factory: peerFactory)
        }
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        close()
    }

    public var viewerIDs: [String] {
        onQueue { peers.keys.sorted() }
    }

    public var viewerSnapshots: [WebRTCViewerSnapshot] {
        onQueue {
            peers.values
                .map {
                    WebRTCViewerSnapshot(
                        viewerID: $0.viewerID,
                        connectionState: $0.connectionState,
                        controlDataChannelState: $0.controlDataChannelState,
                        route: $0.route
                    )
                }
                .sorted { $0.viewerID < $1.viewerID }
        }
    }

    public var connectedViewerCount: Int {
        onQueue { peers.values.count(where: { $0.connectionState == .connected }) }
    }

    public var senderPolicy: WebRTCSenderPolicy {
        onQueue { activeSenderPolicy }
    }

    public func senderPolicy(forSlot slot: Int) -> WebRTCSenderPolicy {
        onQueue { senderPoliciesBySlot[slot] ?? activeSenderPolicy }
    }

    public var slotSnapshots: [WebRTCStreamSlotSnapshot] {
        onQueue { slots.map(\.snapshot) }
    }

    /// Applies a new quality envelope immediately to every current sender and
    /// retains it for peers created later. Resolution preservation remains
    /// independent from the bitrate and frame-rate caps.
    public func updateSenderPolicy(_ policy: WebRTCSenderPolicy) {
        onQueue {
            guard !isClosed else { return }
            activeSenderPolicy = policy
            senderPoliciesBySlot.removeAll()
            for context in peers.values {
                for (slot, sender) in context.sendersBySlot {
                    applySenderPolicy(to: sender, slot: slot)
                }
            }
        }
    }

    /// Applies source-aware envelopes atomically. The fallback covers empty
    /// preallocated slots and any slot omitted by the caller, so peers created
    /// later receive the same policy as existing peers.
    public func updateSenderPolicies(
        _ policiesBySlot: [Int: WebRTCSenderPolicy],
        fallback: WebRTCSenderPolicy
    ) {
        onQueue {
            guard !isClosed else { return }
            activeSenderPolicy = fallback
            senderPoliciesBySlot = policiesBySlot.filter {
                slots.indices.contains($0.key)
            }
            for context in peers.values {
                for (slot, sender) in context.sendersBySlot {
                    applySenderPolicy(to: sender, slot: slot)
                }
            }
        }
    }

    /// Reads actual `outbound-rtp` sender counters from libwebrtc and returns
    /// per-slot network totals. Bitrate and FPS are measured from consecutive
    /// reports, so they remain `nil` for a sender's first snapshot.
    public func outboundSenderStatisticsSnapshot() async throws
        -> WebRTCOutboundStatisticsSnapshot
    {
        let plan = try onQueue { () throws -> OutboundStatisticsPlan in
            try ensureOpen()
            let requests: [OutboundStatisticsRequest] = peers.values.flatMap {
                context -> [OutboundStatisticsRequest] in
                context.sendersBySlot.compactMap { entry -> OutboundStatisticsRequest? in
                    let (slot, sender) = entry
                    guard slots.indices.contains(slot) else { return nil }
                    return OutboundStatisticsRequest(
                        viewerID: context.viewerID,
                        slot: slot,
                        trackID: slots[slot].trackID,
                        connection: context.connection,
                        sender: sender
                    )
                }
            }
            return OutboundStatisticsPlan(
                requests: requests,
                slots: slots.map(\.snapshot),
                connectedViewerCount: peers.values.count(where: {
                    $0.connectionState == .connected
                })
            )
        }

        let samples = await withTaskGroup(
            of: WebRTCRawOutboundStatistics.self,
            returning: [WebRTCRawOutboundStatistics].self
        ) { group in
            for request in plan.requests {
                group.addTask { [self] in
                    await outboundStatistics(for: request)
                }
            }
            var samples: [WebRTCRawOutboundStatistics] = []
            samples.reserveCapacity(plan.requests.count)
            for await sample in group {
                samples.append(sample)
            }
            return samples
        }

        return try onQueue {
            try ensureOpen()
            return WebRTCOutboundStatisticsAggregator.makeSnapshot(
                samples: samples,
                slots: plan.slots,
                connectedViewerCount: plan.connectedViewerCount,
                previous: &previousOutboundCounters,
                capturedAt: Date()
            )
        }
    }

    /// Creates a new peer and a trickle-ICE offer containing all four stable
    /// video tracks and the reliable ordered GoPeep control channel.
    public func createOffer(for viewerID: String) async throws -> WebRTCSessionDescription {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<WebRTCSessionDescription, any Error>) in
            queue.async { [self] in
                do {
                    let context = try createPeer(viewerID: viewerID)
                    let token = context.operationGeneration.beginLocalDescription()
                    createAndApplyLocalOffer(
                        context: context,
                        token: token,
                        continuation: continuation
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Creates a fresh offer for an existing GoPeep viewer connection.
    public func createReoffer(for viewerID: String) async throws -> WebRTCSessionDescription {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<WebRTCSessionDescription, any Error>) in
            queue.async { [self] in
                do {
                    let context = try peer(viewerID)
                    let token = context.operationGeneration.beginLocalDescription()
                    createAndApplyLocalOffer(
                        context: context,
                        token: token,
                        continuation: continuation
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Restarts ICE and returns the resulting trickle-ICE reoffer.
    public func restartICE(for viewerID: String) async throws -> WebRTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let context = try peer(viewerID)
                    context.connection.restartIce()
                    let token = context.operationGeneration.beginLocalDescription()
                    createAndApplyLocalOffer(
                        context: context,
                        token: token,
                        continuation: continuation
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func setRemoteAnswer(
        _ answer: WebRTCSessionDescription,
        for viewerID: String
    ) async throws {
        try await setRemoteDescription(answer, expectedKind: .answer, for: viewerID)
    }

    public func setRemoteAnswer(_ sdp: String, for viewerID: String) async throws {
        try await setRemoteAnswer(.init(kind: .answer, sdp: sdp), for: viewerID)
    }

    public func addRemoteICECandidate(
        _ candidate: WebRTCICECandidate,
        for viewerID: String
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    let context = try peer(viewerID)
                    do {
                        try candidate.validate(resourceLimits: resourceLimits)
                    } catch {
                        throw WebRTCPeerHostError.invalidICECandidate(
                            error.localizedDescription
                        )
                    }
                    guard context.remoteICECandidateCount
                        < resourceLimits.maximumICECandidatesPerPeer else {
                        throw WebRTCPeerHostError.iceCandidateLimitReached(
                            viewerID: viewerID,
                            maximum: resourceLimits.maximumICECandidatesPerPeer
                        )
                    }
                    // Count attempts as well as candidates accepted by
                    // libwebrtc, so a peer cannot repeatedly submit candidates
                    // that fail only after native parsing.
                    context.remoteICECandidateCount += 1
                    let rtcCandidate = RTCIceCandidate(
                        sdp: candidate.candidate,
                        sdpMLineIndex: candidate.sdpMLineIndex,
                        sdpMid: candidate.sdpMid
                    )
                    context.connection.add(rtcCandidate) { [weak self] error in
                        guard let self else {
                            continuation.resume(throwing: WebRTCPeerHostError.hostClosed)
                            return
                        }
                        queue.async {
                            if let error {
                                continuation.resume(throwing:
                                    WebRTCPeerHostError.iceCandidateApplicationFailed(
                                        error.localizedDescription
                                    ))
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func removePeer(_ viewerID: String, notifies: Bool = true) {
        onQueue {
            guard let context = peers.removeValue(forKey: viewerID) else { return }
            previousOutboundCounters = previousOutboundCounters.filter {
                $0.key.viewerID != viewerID
            }
            close(context)
            if notifies {
                emit(.viewerRemoved(viewerID: viewerID))
            }
        }
    }

    public func close() {
        onQueue {
            guard !isClosed else { return }
            isClosed = true
            let contexts = peers.values
            peers.removeAll(keepingCapacity: false)
            previousOutboundCounters.removeAll(keepingCapacity: false)
            for context in contexts {
                close(context)
                emit(.viewerRemoved(viewerID: context.viewerID))
            }
            for slot in slots {
                slot.metadata = nil
                slot.track.isEnabled = false
                slot.frameSource.clearLatestFrame()
            }
        }
    }

    @discardableResult
    public func send(
        _ frame: BorrowedCaptureVideoFrame,
        toSlot slot: Int
    ) -> CaptureFrameDisposition {
        onQueue {
            guard !isClosed,
                  slots.indices.contains(slot),
                  slots[slot].metadata != nil else {
                return .droppedBackpressure
            }
            // Keep slot lifecycle and frame emission in one serial critical
            // section. An old ScreenCaptureKit callback can no longer cross a
            // deactivate/reactivate boundary and seed a replacement source.
            return slots[slot].frameSource.send(frame)
        }
    }

    public func activateSlot(_ slot: Int, metadata: GoPeepV1StreamInfo) throws {
        try onQueue {
            try ensureOpen()
            guard slots.indices.contains(slot) else {
                throw WebRTCPeerHostError.invalidSlot(slot)
            }
            let target = slots[slot]
            guard metadata.trackID == target.trackID else {
                throw WebRTCPeerHostError.slotTrackMismatch(
                    slot: slot,
                    expected: target.trackID,
                    actual: metadata.trackID
                )
            }
            guard target.metadata == nil else {
                throw WebRTCPeerHostError.slotAlreadyActive(slot)
            }
            target.frameSource.clearLatestFrame()
            target.metadata = metadata
            target.track.isEnabled = true
        }
    }

    @discardableResult
    public func activateFirstAvailable(metadata: GoPeepV1StreamInfo) throws -> Int {
        try onQueue {
            try ensureOpen()
            guard let target = slots.first(where: { $0.metadata == nil }) else {
                throw WebRTCPeerHostError.noAvailableSlot
            }
            guard metadata.trackID == target.trackID else {
                throw WebRTCPeerHostError.slotTrackMismatch(
                    slot: target.index,
                    expected: target.trackID,
                    actual: metadata.trackID
                )
            }
            target.frameSource.clearLatestFrame()
            target.metadata = metadata
            target.track.isEnabled = true
            return target.index
        }
    }

    public func deactivateSlot(_ slot: Int) {
        onQueue {
            guard slots.indices.contains(slot) else { return }
            slots[slot].metadata = nil
            slots[slot].track.isEnabled = false
            slots[slot].frameSource.clearLatestFrame()
        }
    }

    @discardableResult
    public func sendControl(
        _ data: Data,
        to viewerID: String,
        isBinary: Bool = false
    ) -> Bool {
        sendControl(
            data,
            to: viewerID,
            isBinary: isBinary,
            isDurable: true
        )
    }

    private func sendControl(
        _ data: Data,
        to viewerID: String,
        isBinary: Bool,
        isDurable: Bool
    ) -> Bool {
        onQueue {
            guard !isClosed,
                  let context = peers[viewerID],
                  context.controlChannel.readyState == .open else {
                return false
            }
            guard controlBufferPolicy.permits(
                      payloadByteCount: data.count,
                      bufferedAmountBytes: context.controlChannel.bufferedAmount
                  ) else {
                if isDurable,
                   controlBufferPolicy.permits(
                       payloadByteCount: data.count,
                       bufferedAmountBytes: 0
                   ) {
                    context.awaitsDurableControlDrain = true
                }
                return false
            }
            let didSend = context.controlChannel.sendData(
                RTCDataBuffer(data: data, isBinary: isBinary)
            )
            if isDurable, !didSend {
                context.awaitsDurableControlDrain = true
            }
            return didSend
        }
    }

    @discardableResult
    public func sendControl(
        _ message: GoPeepV1Message,
        to viewerID: String
    ) throws -> Bool {
        do {
            return sendControl(
                try JSONEncoder().encode(message),
                to: viewerID,
                isBinary: false,
                isDurable: message.type != .cursorPosition
            )
        } catch {
            throw WebRTCPeerHostError.controlMessageEncodingFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public func broadcastControl(
        _ data: Data,
        isBinary: Bool = false
    ) -> WebRTCControlDeliveryResult {
        broadcastControl(data, isBinary: isBinary, isDurable: true)
    }

    private func broadcastControl(
        _ data: Data,
        isBinary: Bool,
        isDurable: Bool
    ) -> WebRTCControlDeliveryResult {
        onQueue {
            var delivered: [String] = []
            var unavailable: [String] = []
            let buffer = RTCDataBuffer(data: data, isBinary: isBinary)
            for (viewerID, context) in peers.sorted(by: { $0.key < $1.key }) {
                guard context.controlChannel.readyState == .open else {
                    unavailable.append(viewerID)
                    continue
                }
                guard controlBufferPolicy.permits(
                    payloadByteCount: data.count,
                    bufferedAmountBytes: context.controlChannel.bufferedAmount
                ) else {
                    if isDurable,
                       controlBufferPolicy.permits(
                           payloadByteCount: data.count,
                           bufferedAmountBytes: 0
                       ) {
                        context.awaitsDurableControlDrain = true
                    }
                    unavailable.append(viewerID)
                    continue
                }
                guard context.controlChannel.sendData(buffer) else {
                    if isDurable {
                        context.awaitsDurableControlDrain = true
                    }
                    unavailable.append(viewerID)
                    continue
                }
                delivered.append(viewerID)
            }
            return WebRTCControlDeliveryResult(
                deliveredViewerIDs: delivered,
                unavailableViewerIDs: unavailable
            )
        }
    }

    @discardableResult
    public func broadcastControl(
        _ message: GoPeepV1Message
    ) throws -> WebRTCControlDeliveryResult {
        do {
            return broadcastControl(
                try JSONEncoder().encode(message),
                isBinary: false,
                isDurable: message.type != .cursorPosition
            )
        } catch {
            throw WebRTCPeerHostError.controlMessageEncodingFailed(error.localizedDescription)
        }
    }

    private func createPeer(viewerID: String) throws -> PeerContext {
        try ensureOpen()
        guard !viewerID.isEmpty else { throw WebRTCPeerHostError.emptyViewerID }
        guard viewerID.utf8.count <= resourceLimits.maximumViewerIDBytes,
              viewerID.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw WebRTCPeerHostError.invalidViewerID(
                maximumBytes: resourceLimits.maximumViewerIDBytes
            )
        }
        guard peers[viewerID] == nil else {
            throw WebRTCPeerHostError.duplicateViewer(viewerID)
        }
        // This check intentionally precedes RTCPeerConnection creation. Each
        // peer allocates four video transceivers and native encoder state.
        guard peers.count < resourceLimits.maximumViewerCount else {
            throw WebRTCPeerHostError.viewerCapacityReached(
                maximum: resourceLimits.maximumViewerCount
            )
        }

        let delegate = WebRTCPeerDelegate(viewerID: viewerID, host: self)
        let rtcConfiguration = makeRTCConfiguration()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let connection = factory.peerConnection(
            with: rtcConfiguration,
            constraints: constraints,
            delegate: delegate
        ) else {
            throw WebRTCPeerHostError.peerConnectionCreationFailed("libwebrtc returned nil")
        }

        var senders: [Int: RTCRtpSender] = [:]
        do {
            for slot in slots {
                let transceiverConfiguration = RTCRtpTransceiverInit()
                transceiverConfiguration.direction = .sendOnly
                transceiverConfiguration.streamIds = [slot.streamID]
                guard let transceiver = connection.addTransceiver(
                    with: slot.track,
                    init: transceiverConfiguration
                ) else {
                    throw WebRTCPeerHostError.trackCreationFailed(slot: slot.index)
                }
                do {
                    try transceiver.setCodecPreferences(
                        h264Codecs,
                        error: ()
                    )
                } catch {
                    throw WebRTCPeerHostError.h264PreferenceFailed(
                        slot: slot.index,
                        message: error.localizedDescription
                    )
                }
                applySenderPolicy(to: transceiver.sender, slot: slot.index)
                senders[slot.index] = transceiver.sender
            }

            let dataConfiguration = RTCDataChannelConfiguration()
            dataConfiguration.isOrdered = true
            dataConfiguration.maxPacketLifeTime = -1
            dataConfiguration.maxRetransmits = -1
            dataConfiguration.isNegotiated = false
            guard let dataChannel = connection.dataChannel(
                forLabel: WebRTCRuntimeIdentity.controlDataChannelLabel,
                configuration: dataConfiguration
            ) else {
                throw WebRTCPeerHostError.dataChannelCreationFailed("libwebrtc returned nil")
            }
            dataChannel.delegate = delegate

            let context = PeerContext(
                viewerID: viewerID,
                connection: connection,
                delegate: delegate,
                controlChannel: dataChannel,
                sendersBySlot: senders
            )
            peers[viewerID] = context
            emit(.viewerAdded(viewerID: viewerID))
            return context
        } catch {
            delegate.detach()
            connection.close()
            throw error
        }
    }

    private func createAndApplyLocalOffer(
        context: PeerContext,
        token: WebRTCPeerOperationGeneration.LocalDescriptionToken,
        continuation: CheckedContinuation<WebRTCSessionDescription, any Error>
    ) {
        context.negotiationGeneration &+= 1
        let negotiationGeneration = context.negotiationGeneration
        context.answerTimeoutWorkItem?.cancel()
        context.answerTimeoutWorkItem = nil
        context.awaitingAnswerGeneration = nil
        context.localICECandidateCount = 0
        context.remoteICECandidateCount = 0
        context.didReportLocalICECandidateLimit = false
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse,
            ],
            optionalConstraints: nil
        )
        context.connection.offer(for: constraints) { [weak self] description, error in
            guard let self else {
                continuation.resume(throwing: WebRTCPeerHostError.hostClosed)
                return
            }
            queue.async { [self] in
                if let staleError = operationError(context: context, token: token) {
                    continuation.resume(throwing: staleError)
                    return
                }
                if let error {
                    removeFailedPeer(context)
                    continuation.resume(throwing:
                        WebRTCPeerHostError.localDescriptionCreationFailed(
                            error.localizedDescription
                        ))
                    return
                }
                guard let description else {
                    removeFailedPeer(context)
                    continuation.resume(throwing:
                        WebRTCPeerHostError.localDescriptionCreationFailed(
                            "libwebrtc returned neither a description nor an error"
                        ))
                    return
                }
                context.connection.setLocalDescription(description) { [weak self] error in
                    guard let self else {
                        continuation.resume(throwing: WebRTCPeerHostError.hostClosed)
                        return
                    }
                    queue.async { [self] in
                        if let staleError = operationError(context: context, token: token) {
                            continuation.resume(throwing: staleError)
                            return
                        }
                        if let error {
                            removeFailedPeer(context)
                            continuation.resume(throwing:
                                WebRTCPeerHostError.localDescriptionApplicationFailed(
                                    error.localizedDescription
                                ))
                        } else {
                            scheduleAnswerTimeout(
                                for: context,
                                negotiationGeneration: negotiationGeneration
                            )
                            continuation.resume(returning: WebRTCSessionDescription(
                                kind: .offer,
                                sdp: description.sdp
                            ))
                        }
                    }
                }
            }
        }
    }

    private func setRemoteDescription(
        _ description: WebRTCSessionDescription,
        expectedKind: WebRTCSessionDescription.Kind,
        for viewerID: String
    ) async throws {
        guard description.kind == expectedKind else {
            throw WebRTCPeerHostError.remoteDescriptionApplicationFailed(
                "expected \(expectedKind.rawValue), received \(description.kind.rawValue)"
            )
        }
        guard description.sdp.utf8.count <= resourceLimits.maximumSDPPayloadBytes else {
            throw WebRTCPeerHostError.sessionDescriptionPayloadTooLarge(
                maximumBytes: resourceLimits.maximumSDPPayloadBytes
            )
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    let context = try peer(viewerID)
                    let token = context.operationGeneration.beginRemoteDescription()
                    let rtcDescription = RTCSessionDescription(
                        type: expectedKind == .answer ? .answer : .offer,
                        sdp: description.sdp
                    )
                    context.connection.setRemoteDescription(rtcDescription) { [weak self] error in
                        guard let self else {
                            continuation.resume(throwing: WebRTCPeerHostError.hostClosed)
                            return
                        }
                        queue.async { [self] in
                            if let staleError = operationError(context: context, token: token) {
                                continuation.resume(throwing: staleError)
                                return
                            }
                            if let error {
                                continuation.resume(throwing:
                                    WebRTCPeerHostError.remoteDescriptionApplicationFailed(
                                        error.localizedDescription
                                    ))
                            } else {
                                context.answerTimeoutWorkItem?.cancel()
                                context.answerTimeoutWorkItem = nil
                                context.awaitingAnswerGeneration = nil
                                continuation.resume()
                            }
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func makeRTCConfiguration() -> RTCConfiguration {
        let result = RTCConfiguration()
        result.sdpSemantics = .unifiedPlan
        result.bundlePolicy = .maxBundle
        result.rtcpMuxPolicy = .require
        result.continualGatheringPolicy = .gatherContinually
        result.iceTransportPolicy = configuration.forcesRelay ? .relay : .all
        result.iceServers = configuration.iceServers.map { server in
            if server.username != nil || server.credential != nil {
                return RTCIceServer(
                    urlStrings: server.urlStrings,
                    username: server.username,
                    credential: server.credential
                )
            }
            return RTCIceServer(urlStrings: server.urlStrings)
        }
        return result
    }

    private func applySenderPolicy(to sender: RTCRtpSender, slot: Int) {
        let policy = senderPoliciesBySlot[slot] ?? activeSenderPolicy
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(value:
            policy.maintainsResolution
                ? RTCDegradationPreference.maintainResolution.rawValue
                : RTCDegradationPreference.balanced.rawValue
        )
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = policy.maximumBitrateBps.map(NSNumber.init)
            encoding.maxFramerate = policy.maximumFramesPerSecond.map(NSNumber.init)
            encoding.scaleResolutionDownBy = 1
            encoding.bitratePriority = 1
            encoding.networkPriority = .high
        }
        sender.parameters = parameters
    }

    private func outboundStatistics(
        for request: OutboundStatisticsRequest
    ) async -> WebRTCRawOutboundStatistics {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                request.connection.statistics(for: request.sender) { [self] report in
                    queue.async {
                        let parsed = WebRTCOutboundStatisticsParser.parse(
                            report,
                            viewerID: request.viewerID,
                            slot: request.slot,
                            trackID: request.trackID
                        )
                        if let route = parsed.route {
                            self.peers[request.viewerID]?.route = route
                        }
                        continuation.resume(returning: parsed)
                    }
                }
            }
        }
    }

    private func peer(_ viewerID: String) throws -> PeerContext {
        try ensureOpen()
        guard let context = peers[viewerID] else {
            throw WebRTCPeerHostError.viewerNotFound(viewerID)
        }
        return context
    }

    /// A newly negotiated H.264 sender is not guaranteed to consume a frame in
    /// the same callback that reports peer/DataChannel readiness. Seed a small,
    /// fixed burst from each slot's one-frame cache; every delayed callback
    /// revalidates peer identity and channel state, so it cannot outlive or leak
    /// into a replacement viewer.
    private func scheduleLatestFrameSeed(for context: PeerContext) {
        context.latestFrameSeedGeneration &+= 1
        let generation = context.latestFrameSeedGeneration
        for delayMilliseconds in [0, 80, 200, 500, 1_000] {
            queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) {
                [weak self, weak context] in
                guard let self,
                      let context,
                      !isClosed,
                      peers[context.viewerID] === context,
                      context.latestFrameSeedGeneration == generation,
                      context.connectionState == .connected,
                      context.controlDataChannelState == .open else {
                    return
                }
                for slot in slots where slot.metadata != nil {
                    slot.frameSource.replayLatestFrame()
                }
            }
        }
    }

    private func ensureOpen() throws {
        if isClosed { throw WebRTCPeerHostError.hostClosed }
    }

    private func operationError(
        context: PeerContext,
        token: WebRTCPeerOperationGeneration.LocalDescriptionToken
    ) -> WebRTCPeerHostError? {
        if isClosed { return .hostClosed }
        guard peers[context.viewerID] === context,
              context.operationGeneration.contains(token) else {
            return .stalePeerOperation(context.viewerID)
        }
        return nil
    }

    private func operationError(
        context: PeerContext,
        token: WebRTCPeerOperationGeneration.RemoteDescriptionToken
    ) -> WebRTCPeerHostError? {
        if isClosed { return .hostClosed }
        guard peers[context.viewerID] === context,
              context.operationGeneration.contains(token) else {
            return .stalePeerOperation(context.viewerID)
        }
        return nil
    }

    private func close(_ context: PeerContext) {
        guard !context.isClosing else { return }
        context.isClosing = true
        context.answerTimeoutWorkItem?.cancel()
        context.answerTimeoutWorkItem = nil
        context.awaitingAnswerGeneration = nil
        context.delegate.detach()
        context.controlChannel.delegate = nil
        context.controlChannel.close()
        context.connection.delegate = nil
        context.connection.close()
    }

    private func removeFailedPeer(_ context: PeerContext) {
        guard peers[context.viewerID] === context else { return }
        peers.removeValue(forKey: context.viewerID)
        previousOutboundCounters = previousOutboundCounters.filter {
            $0.key.viewerID != context.viewerID
        }
        close(context)
        emit(.viewerRemoved(viewerID: context.viewerID))
    }

    fileprivate func handle(
        _ event: WebRTCPeerDelegate.Event,
        viewerID: String,
        connection: RTCPeerConnection?
    ) {
        queue.async { [self] in
            guard !isClosed,
                  let context = peers[viewerID],
                  connection == nil || context.connection === connection else {
                return
            }
            switch event {
            case .localICECandidate(let candidate):
                do {
                    try candidate.validate(resourceLimits: resourceLimits)
                } catch {
                    emit(.error(
                        viewerID: viewerID,
                        error: .invalidICECandidate(error.localizedDescription)
                    ))
                    return
                }
                guard context.localICECandidateCount
                    < resourceLimits.maximumICECandidatesPerPeer else {
                    if !context.didReportLocalICECandidateLimit {
                        context.didReportLocalICECandidateLimit = true
                        emit(.error(
                            viewerID: viewerID,
                            error: .iceCandidateLimitReached(
                                viewerID: viewerID,
                                maximum: resourceLimits.maximumICECandidatesPerPeer
                            )
                        ))
                    }
                    return
                }
                context.localICECandidateCount += 1
                emit(.localICECandidate(viewerID: viewerID, candidate: candidate))
            case .connectionState(let state):
                let previousState = context.connectionState
                context.connectionState = state
                emit(.connectionStateChanged(viewerID: viewerID, state: state))
                if state == .connected, previousState != .connected {
                    scheduleLatestFrameSeed(for: context)
                }
                if state == .failed || state == .closed {
                    peers.removeValue(forKey: viewerID)
                    previousOutboundCounters = previousOutboundCounters.filter {
                        $0.key.viewerID != viewerID
                    }
                    close(context)
                    emit(.viewerRemoved(viewerID: viewerID))
                }
            case .controlState(let state):
                let previousState = context.controlDataChannelState
                context.controlDataChannelState = state
                if state != .open {
                    context.awaitsDurableControlDrain = false
                }
                emit(.controlDataChannelStateChanged(viewerID: viewerID, state: state))
                if state == .open, previousState != .open {
                    scheduleLatestFrameSeed(for: context)
                }
            case .controlBufferedAmountChanged(let bufferedAmountBytes):
                guard context.awaitsDurableControlDrain,
                      controlBufferPolicy.hasDrained(
                          bufferedAmountBytes: bufferedAmountBytes
                      ) else {
                    return
                }
                context.awaitsDurableControlDrain = false
                emit(.controlDataChannelDrained(viewerID: viewerID))
            case .controlMessage(let data, let isBinary):
                emit(.controlMessageReceived(
                    viewerID: viewerID,
                    data: data,
                    isBinary: isBinary
                ))
            case .negotiationNeeded:
                emit(.negotiationNeeded(viewerID: viewerID))
            case .error(let error):
                emit(.error(viewerID: viewerID, error: error))
            }
        }
    }

    private func emit(_ event: WebRTCPeerHostEvent) {
        let eventHandler = eventHandler
        eventQueue.async {
            eventHandler(event)
        }
    }

    private func scheduleAnswerTimeout(
        for context: PeerContext,
        negotiationGeneration: UInt64
    ) {
        let workItem = DispatchWorkItem { [weak self, weak context] in
            guard let self, let context,
                  !isClosed,
                  peers[context.viewerID] === context,
                  context.negotiationGeneration == negotiationGeneration,
                  context.awaitingAnswerGeneration == negotiationGeneration else {
                return
            }
            context.answerTimeoutWorkItem = nil
            context.awaitingAnswerGeneration = nil
            let error = WebRTCPeerHostError.negotiationTimedOut(
                viewerID: context.viewerID
            )
            emit(.error(viewerID: context.viewerID, error: error))
            removeFailedPeer(context)
        }
        context.answerTimeoutWorkItem = workItem
        context.awaitingAnswerGeneration = negotiationGeneration
        queue.asyncAfter(
            deadline: .now() + resourceLimits.answerTimeout,
            execute: workItem
        )
    }

    @discardableResult
    private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync(execute: work)
    }
}

private final class WebRTCPeerDelegate: NSObject, RTCPeerConnectionDelegate,
    RTCDataChannelDelegate, @unchecked Sendable
{
    enum Event: @unchecked Sendable {
        case localICECandidate(WebRTCICECandidate)
        case connectionState(WebRTCPeerConnectionState)
        case controlState(WebRTCControlDataChannelState)
        case controlBufferedAmountChanged(UInt64)
        case controlMessage(Data, isBinary: Bool)
        case negotiationNeeded
        case error(WebRTCPeerHostError)
    }

    let viewerID: String
    private weak var host: WebRTCPeerHost?
    private let lock = NSLock()

    init(viewerID: String, host: WebRTCPeerHost) {
        self.viewerID = viewerID
        self.host = host
    }

    func detach() {
        lock.withLock { host = nil }
    }

    private func forward(_ event: Event, connection: RTCPeerConnection? = nil) {
        lock.withLock { host }?.handle(event, viewerID: viewerID, connection: connection)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd stream: RTCMediaStream
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove stream: RTCMediaStream
    ) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        forward(.negotiationNeeded, connection: peerConnection)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        forward(.localICECandidate(WebRTCICECandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        )), connection: peerConnection)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {
        // Clip creates the GoPeep channel. Ignore unexpected remote channels.
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        forward(.connectionState(Self.connectionState(newState)), connection: peerConnection)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent
    ) {
        forward(.error(.iceGatheringFailed(
            code: Int(event.errorCode),
            url: event.url,
            message: event.errorText
        )), connection: peerConnection)
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        forward(.controlState(Self.dataChannelState(dataChannel.readyState)))
    }

    func dataChannel(
        _ dataChannel: RTCDataChannel,
        didChangeBufferedAmount _: UInt64
    ) {
        // libwebrtc's callback argument has historically represented the
        // previous amount on some branches. Read the channel's current value.
        forward(.controlBufferedAmountChanged(dataChannel.bufferedAmount))
    }

    func dataChannel(
        _: RTCDataChannel,
        didReceiveMessageWith _: RTCDataBuffer
    ) {
        // GoPeep v1's control channel is host-to-viewer only. Discard viewer
        // payloads at the native delegate boundary so an admitted peer cannot
        // turn unsolicited messages into unbounded app/event-queue work.
    }

    private static func connectionState(
        _ state: RTCPeerConnectionState
    ) -> WebRTCPeerConnectionState {
        switch state {
        case .new: .new
        case .connecting: .connecting
        case .connected: .connected
        case .disconnected: .disconnected
        case .failed: .failed
        case .closed: .closed
        @unknown default: .failed
        }
    }

    private static func dataChannelState(
        _ state: RTCDataChannelState
    ) -> WebRTCControlDataChannelState {
        switch state {
        case .connecting: .connecting
        case .open: .open
        case .closing: .closing
        case .closed: .closed
        @unknown default: .closed
        }
    }
}
