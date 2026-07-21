import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTCAudioBridge
import Foundation
@preconcurrency import WebRTC

/// Clip's native WebRTC host.
///
/// The host creates one libwebrtc factory and four stable screen-cast tracks.
/// Every viewer gets its own peer connection while sharing those four sources,
/// which keeps track and stream identifiers stable across activation changes.
public final class WebRTCPeerHost: LiveShareVideoSlotHosting, @unchecked Sendable {
    public typealias EventHandler = @Sendable (WebRTCPeerHostEvent) -> Void
    private static let idleFrameReplayIntervalNanoseconds: UInt64 = 2_000_000_000

    private final class Slot: @unchecked Sendable {
        let index: Int
        let trackID: String
        let streamID: String
        let source: RTCVideoSource
        let track: RTCVideoTrack
        let frameSource: WebRTCFrameSource
        var metadata: ClipLiveShareStreamDescriptor?
        var captureGeometry: WebRTCVideoCaptureGeometry?

        init(index: Int, factory: RTCPeerConnectionFactory) {
            self.index = index
            // These identifiers are exposed to the remote browser by WebRTC.
            // Keep the stable slot index local and publish only per-session,
            // cryptographically random identities on the wire.
            trackID = ClipLiveShareMediaTrackID.random().rawValue
            streamID = ClipLiveShareStreamID.random().rawValue
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
                metadata: metadata,
                captureGeometry: captureGeometry
            )
        }
    }

    private final class PeerContext: @unchecked Sendable {
        let viewerID: String
        let connection: RTCPeerConnection
        let delegate: WebRTCPeerDelegate
        let controlChannel: RTCDataChannel
        let systemAudioSender: RTCRtpSender
        let systemAudioTransceiver: RTCRtpTransceiver
        let sendersBySlot: [Int: RTCRtpSender]
        let transceiversBySlot: [Int: RTCRtpTransceiver]
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
            systemAudioSender: RTCRtpSender,
            systemAudioTransceiver: RTCRtpTransceiver,
            sendersBySlot: [Int: RTCRtpSender],
            transceiversBySlot: [Int: RTCRtpTransceiver]
        ) {
            self.viewerID = viewerID
            self.connection = connection
            self.delegate = delegate
            self.controlChannel = controlChannel
            self.systemAudioSender = systemAudioSender
            self.systemAudioTransceiver = systemAudioTransceiver
            self.sendersBySlot = sendersBySlot
            self.transceiversBySlot = transceiversBySlot
        }
    }

    private final class PendingVideoCodecSwitch: @unchecked Sendable {
        let previous: WebRTCVideoCodec
        let requested: WebRTCVideoCodec
        var awaitingViewerIDs: Set<String>
        let continuation: CheckedContinuation<Void, any Error>

        init(
            previous: WebRTCVideoCodec,
            requested: WebRTCVideoCodec,
            awaitingViewerIDs: Set<String>,
            continuation: CheckedContinuation<Void, any Error>
        ) {
            self.previous = previous
            self.requested = requested
            self.awaitingViewerIDs = awaitingViewerIDs
            self.continuation = continuation
        }
    }

    private final class PendingVideoCodecRestoration: @unchecked Sendable {
        let previous: WebRTCVideoCodec
        let failedRequested: WebRTCVideoCodec
        var awaitingViewerIDs: Set<String>

        init(
            previous: WebRTCVideoCodec,
            failedRequested: WebRTCVideoCodec,
            awaitingViewerIDs: Set<String>
        ) {
            self.previous = previous
            self.failedRequested = failedRequested
            self.awaitingViewerIDs = awaitingViewerIDs
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
    private let h264EncoderFactory: WebRTCH264EncoderFactory
    private let systemAudioDevice: ClipLiveShareWebRTCSystemAudioDevice
    private let factory: RTCPeerConnectionFactory
    private let videoCodecCapabilities: [RTCRtpCodecCapability]
    private let audioCodecCapabilities: [RTCRtpCodecCapability]
    private let systemAudioTrackID: String
    private let systemAudioStreamID: String
    private let systemAudioTrack: RTCAudioTrack
    private let slots: [Slot]
    private var peers: [String: PeerContext] = [:]
    private var previousOutboundCounters: [
        WebRTCOutboundCounterKey: WebRTCOutboundCounter
    ] = [:]
    private var previousH264SubmissionBackpressureDrops: UInt64?
    private var activeVideoCodec: WebRTCVideoCodec
    private var activeVideoEncodingMode: LiveShareEncodingMode
    private var systemAudioEnabled = false
    private var pendingVideoCodecSwitch: PendingVideoCodecSwitch?
    private var pendingVideoCodecRestoration: PendingVideoCodecRestoration?
    private var isClosed = false

    public init(
        configuration: WebRTCPeerHostConfiguration = .clipDefault,
        eventQueue: DispatchQueue = .main,
        eventHandler: @escaping EventHandler = { _ in }
    ) throws {
        self.configuration = configuration
        resourceLimits = configuration.resourceLimits.normalized
        controlBufferPolicy = WebRTCControlBufferPolicy(
            resourceLimits: configuration.resourceLimits
        )
        activeSenderPolicy = configuration.senderPolicy
        activeVideoCodec = configuration.videoCodec
        activeVideoEncodingMode = configuration.videoEncodingMode
        self.eventQueue = eventQueue
        self.eventHandler = eventHandler
        queue = DispatchQueue(
            label: "com.tomaslejdung.clip.liveshare.webrtc-host",
            qos: .userInteractive
        )
        sslLease = try WebRTCSSLRuntimeLease()
        let nativeH264Factory = WebRTCH264EncoderFactory(
            configuration: WebRTCH264EncoderConfiguration(
                mode: WebRTCH264EncodingMode(configuration.videoEncodingMode)
            )
        )
        h264EncoderFactory = nativeH264Factory
        let audioDevice = ClipLiveShareWebRTCSystemAudioDevice()
        let videoEncoderFactory = WebRTCVideoEncoderFactory(
            preferredCodec: configuration.videoCodec,
            h264Factory: nativeH264Factory
        )
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        let peerFactory = ClipLiveShareWebRTCCreatePeerConnectionFactory(
            videoEncoderFactory,
            videoDecoderFactory,
            audioDevice
        )
        systemAudioDevice = audioDevice
        factory = peerFactory
        let codecs = peerFactory
            .rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
            .codecs
        videoCodecCapabilities = codecs
        guard codecs.contains(where: {
            $0.name.caseInsensitiveCompare(configuration.videoCodec.rtcName) == .orderedSame
        }) else {
            throw WebRTCPeerHostError.videoCodecUnavailable(configuration.videoCodec)
        }
        let audioCodecs = peerFactory
            .rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindAudio)
            .codecs
        audioCodecCapabilities = audioCodecs
        guard audioCodecs.contains(where: {
            $0.name.caseInsensitiveCompare("opus") == .orderedSame
        }) else {
            throw WebRTCPeerHostError.systemAudioCodecUnavailable
        }
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "googAutoGainControl": kRTCMediaConstraintsValueFalse,
                "googEchoCancellation": kRTCMediaConstraintsValueFalse,
                "googHighpassFilter": kRTCMediaConstraintsValueFalse,
                "googNoiseSuppression": kRTCMediaConstraintsValueFalse,
            ],
            optionalConstraints: nil
        )
        let audioSource = peerFactory.audioSource(with: audioConstraints)
        let audioTrackID = ClipLiveShareMediaTrackID.random().rawValue
        let audioStreamID = ClipLiveShareStreamID.random().rawValue
        let audioTrack = peerFactory.audioTrack(
            with: audioSource,
            trackId: audioTrackID
        )
        audioTrack.isEnabled = false
        systemAudioTrackID = audioTrackID
        systemAudioStreamID = audioStreamID
        systemAudioTrack = audioTrack
        audioDevice.setInputEnabled(false)
        slots = (0 ..< WebRTCRuntimeIdentity.maximumVideoSlots).map {
            Slot(index: $0, factory: peerFactory)
        }
        queue.setSpecific(key: queueKey, value: 1)
        scheduleIdleFrameReplay()
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

    /// The preferred codec used for new offers and, after renegotiation,
    /// active peers. Optional software codecs retain VP8 as a compatibility
    /// fallback for viewers that cannot negotiate the preferred format.
    public var videoCodec: WebRTCVideoCodec {
        onQueue { activeVideoCodec }
    }

    public var videoEncodingMode: LiveShareEncodingMode {
        onQueue { activeVideoEncodingMode }
    }

    public func senderPolicy(forSlot slot: Int) -> WebRTCSenderPolicy {
        onQueue { senderPoliciesBySlot[slot] ?? activeSenderPolicy }
    }

    public var slotSnapshots: [WebRTCStreamSlotSnapshot] {
        onQueue { slots.map(\.snapshot) }
    }

    public var isSystemAudioEnabled: Bool {
        onQueue { systemAudioEnabled }
    }

    public var systemAudioSnapshot: WebRTCSystemAudioSnapshot {
        onQueue {
            WebRTCSystemAudioSnapshot(
                trackID: systemAudioTrackID,
                streamID: systemAudioStreamID,
                isEnabled: systemAudioEnabled,
                isDeviceRecording: systemAudioDevice.isRecording,
                queuedFrameCount: systemAudioDevice.queuedFrameCount,
                acceptedFrameCount: systemAudioDevice.acceptedFrameCount,
                droppedFrameCount: systemAudioDevice.droppedFrameCount,
                underflowFrameCount: systemAudioDevice.underflowFrameCount,
                deliveryCallbackCount: systemAudioDevice.deliveryCallbackCount,
                deliveredFrameCount: systemAudioDevice.deliveredFrameCount,
                deliveryErrorCount: systemAudioDevice.deliveryErrorCount
            )
        }
    }

    /// Enables the pre-negotiated Opus sender without replacing tracks or
    /// renegotiating active peers. Disabling also removes any queued PCM so a
    /// later re-enable cannot replay stale desktop audio.
    public func setSystemAudioEnabled(_ enabled: Bool) {
        onQueue {
            guard !isClosed else { return }
            systemAudioEnabled = enabled
            systemAudioTrack.isEnabled = enabled
            systemAudioDevice.setInputEnabled(enabled)
        }
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

    /// Changes VideoToolbox's native rate-control behavior for current and
    /// future H.264 encoders. Active encoders observe the shared controller and
    /// rebuild before their next frame; tracks and peer transports remain live.
    public func updateVideoEncodingMode(_ mode: LiveShareEncodingMode) {
        onQueue {
            guard !isClosed else { return }
            activeVideoEncodingMode = mode
            h264EncoderFactory.updateMode(WebRTCH264EncodingMode(mode))
        }
    }

    /// Selects a preferred codec for every video transceiver and waits until
    /// all current peers have answered the resulting reoffers. VP9 and AV1
    /// offers retain VP8 as a compatibility fallback. Track IDs, sources, the
    /// control data channel, and the ICE transport remain intact.
    ///
    /// Applying codec preferences raises `negotiationNeeded` for each viewer;
    /// the signaling owner must send `createReoffer(for:)` and deliver the
    /// resulting answer through `setRemoteAnswer`. If one peer cannot complete
    /// that exchange, preferences are restored for every surviving peer and a
    /// second negotiation-needed event restores their previous codec.
    public func updateVideoCodec(_ codec: WebRTCVideoCodec) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try ensureOpen()
                    if let pendingVideoCodecSwitch {
                        throw WebRTCPeerHostError.videoCodecSwitchInProgress(
                            from: pendingVideoCodecSwitch.previous,
                            to: pendingVideoCodecSwitch.requested
                        )
                    }
                    if let pendingVideoCodecRestoration {
                        throw WebRTCPeerHostError.videoCodecSwitchInProgress(
                            from: pendingVideoCodecRestoration.failedRequested,
                            to: pendingVideoCodecRestoration.previous
                        )
                    }
                    guard codec != activeVideoCodec else {
                        continuation.resume()
                        return
                    }
                    guard videoCodecCapabilities.contains(where: {
                        $0.name.caseInsensitiveCompare(codec.rtcName) == .orderedSame
                    }) else {
                        throw WebRTCPeerHostError.videoCodecUnavailable(codec)
                    }
                    for context in peers.values {
                        guard context.connection.signalingState == .stable,
                              context.awaitingAnswerGeneration == nil,
                              !context.operationGeneration
                                .hasLocalDescriptionInFlight else {
                            throw WebRTCPeerHostError.videoCodecSwitchFailed(
                                from: activeVideoCodec,
                                to: codec,
                                message: "viewer \(context.viewerID) is already negotiating"
                            )
                        }
                    }

                    let previous = activeVideoCodec
                    try applyVideoCodecPreference(
                        codec,
                        previous: previous,
                        contexts: peers.values.sorted { $0.viewerID < $1.viewerID }
                    )
                    activeVideoCodec = codec
                    let awaitingViewerIDs = Set(peers.keys)
                    guard !awaitingViewerIDs.isEmpty else {
                        emit(.videoCodecChanged(codec: codec))
                        continuation.resume()
                        return
                    }
                    pendingVideoCodecSwitch = PendingVideoCodecSwitch(
                        previous: previous,
                        requested: codec,
                        awaitingViewerIDs: awaitingViewerIDs,
                        continuation: continuation
                    )

                    // setCodecPreferences normally causes negotiationneeded,
                    // but an already-raised native flag may coalesce it. The
                    // explicit host event guarantees one signaling request.
                    for viewerID in awaitingViewerIDs.sorted() {
                        emit(.negotiationNeeded(viewerID: viewerID))
                    }
                } catch {
                    continuation.resume(throwing: error)
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
            let h264SubmissionBackpressureDrops = h264EncoderFactory
                .submissionBackpressureDropCount
            let latestH264SubmissionBackpressureDrops: UInt64
            if let previousH264SubmissionBackpressureDrops,
               h264SubmissionBackpressureDrops >= previousH264SubmissionBackpressureDrops
            {
                latestH264SubmissionBackpressureDrops =
                    h264SubmissionBackpressureDrops
                    - previousH264SubmissionBackpressureDrops
            } else {
                // The controller belongs to this host, so its first sampled
                // value is also the complete first interval. Treat a reset as
                // a new baseline without hiding the new controller's drops.
                latestH264SubmissionBackpressureDrops =
                    h264SubmissionBackpressureDrops
            }
            previousH264SubmissionBackpressureDrops = h264SubmissionBackpressureDrops
            return WebRTCOutboundStatisticsAggregator.makeSnapshot(
                samples: samples,
                slots: plan.slots,
                connectedViewerCount: plan.connectedViewerCount,
                previous: &previousOutboundCounters,
                capturedAt: Date(),
                h264SubmissionBackpressureDrops:
                    latestH264SubmissionBackpressureDrops
            )
        }
    }

    /// Creates a new peer and a trickle-ICE offer containing all four stable
    /// video tracks and Clip's reliable ordered control channel.
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

    /// Creates a fresh offer for an existing Clip viewer connection.
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
                        let peerError = WebRTCPeerHostError.invalidICECandidate(
                            error.localizedDescription
                        )
                        removeFailedPeer(context)
                        throw peerError
                    }
                    guard context.remoteICECandidateCount
                        < resourceLimits.maximumICECandidatesPerPeer else {
                        let peerError = WebRTCPeerHostError.iceCandidateLimitReached(
                            viewerID: viewerID,
                            maximum: resourceLimits.maximumICECandidatesPerPeer
                        )
                        removeFailedPeer(context)
                        throw peerError
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
            peerLeftVideoCodecTransaction(viewerID: viewerID)
            if notifies {
                emit(.viewerRemoved(viewerID: viewerID))
            }
        }
    }

    public func close() {
        onQueue {
            guard !isClosed else { return }
            isClosed = true
            if let pendingVideoCodecSwitch {
                self.pendingVideoCodecSwitch = nil
                pendingVideoCodecSwitch.continuation.resume(throwing:
                    WebRTCPeerHostError.hostClosed)
            }
            pendingVideoCodecRestoration = nil
            let contexts = peers.values
            peers.removeAll(keepingCapacity: false)
            previousOutboundCounters.removeAll(keepingCapacity: false)
            previousH264SubmissionBackpressureDrops = nil
            for context in contexts {
                close(context)
                emit(.viewerRemoved(viewerID: context.viewerID))
            }
            for slot in slots {
                slot.metadata = nil
                slot.captureGeometry = nil
                slot.track.isEnabled = false
                slot.frameSource.clearLatestFrame()
            }
            systemAudioEnabled = false
            systemAudioTrack.isEnabled = false
            systemAudioDevice.setInputEnabled(false)
        }
    }

    /// Copies one borrowed ScreenCaptureKit LPCM callback into the bounded
    /// WebRTC audio device queue. Conversion is synchronous so the borrowed
    /// CMSampleBuffer never escapes its capture callback.
    @discardableResult
    public func send(_ sample: BorrowedCaptureAudioSample) -> Bool {
        let acceptsAudio = onQueue { !isClosed && systemAudioEnabled }
        guard acceptsAudio else { return false }
        return systemAudioDevice.enqueue(sample.sampleBuffer)
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

    public func activateSlot(_ slot: Int, metadata: ClipLiveShareStreamDescriptor) throws {
        try activateSlot(
            slot,
            metadata: metadata,
            captureGeometry: WebRTCVideoCaptureGeometry(
                width: metadata.width,
                height: metadata.height
            )
        )
    }

    public func activateSlot(
        _ slot: Int,
        metadata: ClipLiveShareStreamDescriptor,
        captureGeometry: WebRTCVideoCaptureGeometry
    ) throws {
        try onQueue {
            try ensureOpen()
            guard slots.indices.contains(slot) else {
                throw WebRTCPeerHostError.invalidSlot(slot)
            }
            let target = slots[slot]
            guard metadata.mediaTrackID.rawValue == target.trackID else {
                throw WebRTCPeerHostError.slotTrackMismatch(
                    slot: slot,
                    expected: target.trackID,
                    actual: metadata.mediaTrackID.rawValue
                )
            }
            guard target.metadata == nil else {
                throw WebRTCPeerHostError.slotAlreadyActive(slot)
            }
            target.frameSource.clearLatestFrame()
            target.metadata = metadata
            target.captureGeometry = captureGeometry
            target.track.isEnabled = true
        }
    }

    /// Updates dimensions and labels for an already-active stable track. This
    /// is used when a live codec switch changes only the transmitted geometry;
    /// no sender, track, data channel, or peer transport is replaced.
    public func updateSlotMetadata(
        _ slot: Int,
        metadata: ClipLiveShareStreamDescriptor
    ) throws {
        try updateSlotMetadata(
            slot,
            metadata: metadata,
            captureGeometry: WebRTCVideoCaptureGeometry(
                width: metadata.width,
                height: metadata.height
            )
        )
    }

    public func updateSlotMetadata(
        _ slot: Int,
        metadata: ClipLiveShareStreamDescriptor,
        captureGeometry: WebRTCVideoCaptureGeometry
    ) throws {
        try onQueue {
            try ensureOpen()
            guard slots.indices.contains(slot) else {
                throw WebRTCPeerHostError.invalidSlot(slot)
            }
            let target = slots[slot]
            guard metadata.mediaTrackID.rawValue == target.trackID else {
                throw WebRTCPeerHostError.slotTrackMismatch(
                    slot: slot,
                    expected: target.trackID,
                    actual: metadata.mediaTrackID.rawValue
                )
            }
            guard target.metadata != nil else {
                throw WebRTCPeerHostError.slotInactive(slot)
            }
            target.frameSource.discardLatestFrameUnlessMatching(
                width: captureGeometry.width,
                height: captureGeometry.height
            )
            target.metadata = metadata
            target.captureGeometry = captureGeometry
        }
    }

    @discardableResult
    public func activateFirstAvailable(metadata: ClipLiveShareStreamDescriptor) throws -> Int {
        try onQueue {
            try ensureOpen()
            guard let target = slots.first(where: { $0.metadata == nil }) else {
                throw WebRTCPeerHostError.noAvailableSlot
            }
            guard metadata.mediaTrackID.rawValue == target.trackID else {
                throw WebRTCPeerHostError.slotTrackMismatch(
                    slot: target.index,
                    expected: target.trackID,
                    actual: metadata.mediaTrackID.rawValue
                )
            }
            target.frameSource.clearLatestFrame()
            target.metadata = metadata
            target.captureGeometry = WebRTCVideoCaptureGeometry(
                width: metadata.width,
                height: metadata.height
            )
            target.track.isEnabled = true
            return target.index
        }
    }

    public func deactivateSlot(_ slot: Int) {
        onQueue {
            guard slots.indices.contains(slot) else { return }
            slots[slot].metadata = nil
            slots[slot].captureGeometry = nil
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

    /// Sends replaceable high-frequency state such as cursor movement. When
    /// the DataChannel is above its high-water mark this payload is dropped
    /// without scheduling a durable replay.
    @discardableResult
    public func sendEphemeralControl(
        _ data: Data,
        to viewerID: String,
        isBinary: Bool = false
    ) -> Bool {
        sendControl(
            data,
            to: viewerID,
            isBinary: isBinary,
            isDurable: false
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
        var transceivers: [Int: RTCRtpTransceiver] = [:]
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
                try setVideoCodecPreference(
                    activeVideoCodec,
                    on: transceiver,
                    viewerID: viewerID,
                    slot: slot.index
                )
                applySenderPolicy(to: transceiver.sender, slot: slot.index)
                senders[slot.index] = transceiver.sender
                transceivers[slot.index] = transceiver
            }

            let audioTransceiverConfiguration = RTCRtpTransceiverInit()
            audioTransceiverConfiguration.direction = .sendOnly
            audioTransceiverConfiguration.streamIds = [systemAudioStreamID]
            guard let audioTransceiver = connection.addTransceiver(
                with: systemAudioTrack,
                init: audioTransceiverConfiguration
            ) else {
                throw WebRTCPeerHostError.systemAudioTrackCreationFailed
            }
            try setSystemAudioCodecPreference(
                on: audioTransceiver,
                viewerID: viewerID
            )
            applySystemAudioSenderPolicy(to: audioTransceiver.sender)

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
                systemAudioSender: audioTransceiver.sender,
                systemAudioTransceiver: audioTransceiver,
                sendersBySlot: senders,
                transceiversBySlot: transceivers
            )
            peers[viewerID] = context
            // A viewer can join while current peers are renegotiating. Its
            // first offer already uses the requested codec, so the global
            // switch must also wait for this answer (or for its removal).
            pendingVideoCodecSwitch?.awaitingViewerIDs.insert(viewerID)
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
                    context.operationGeneration.finishLocalDescription(token)
                    continuation.resume(throwing: staleError)
                    return
                }
                if let error {
                    context.operationGeneration.finishLocalDescription(token)
                    failPendingVideoCodecSwitch(
                        viewerID: context.viewerID,
                        underlyingError: error
                    )
                    removeFailedPeer(context)
                    continuation.resume(throwing:
                        WebRTCPeerHostError.localDescriptionCreationFailed(
                            error.localizedDescription
                        ))
                    return
                }
                guard let description else {
                    context.operationGeneration.finishLocalDescription(token)
                    let missingDescriptionError = WebRTCPeerHostError
                        .localDescriptionCreationFailed(
                            "libwebrtc returned neither a description nor an error"
                        )
                    failPendingVideoCodecSwitch(
                        viewerID: context.viewerID,
                        underlyingError: missingDescriptionError
                    )
                    removeFailedPeer(context)
                    continuation.resume(throwing: missingDescriptionError)
                    return
                }
                let upgradedDescription = RTCSessionDescription(
                    type: description.type,
                    sdp: WebRTCOpusMusicSDP.applying(
                        to: WebRTCH264EncoderFactory.upgradingProfileLevels(
                            in: description.sdp
                        )
                    )
                )
                context.connection.setLocalDescription(upgradedDescription) { [weak self] error in
                    guard let self else {
                        continuation.resume(throwing: WebRTCPeerHostError.hostClosed)
                        return
                    }
                    queue.async { [self] in
                        context.operationGeneration.finishLocalDescription(token)
                        if let staleError = operationError(context: context, token: token) {
                            continuation.resume(throwing: staleError)
                            return
                        }
                        if let error {
                            failPendingVideoCodecSwitch(
                                viewerID: context.viewerID,
                                underlyingError: error
                            )
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
                                sdp: upgradedDescription.sdp
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
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    let context = try peer(viewerID)
                    guard description.kind == expectedKind else {
                        let peerError = WebRTCPeerHostError
                            .remoteDescriptionApplicationFailed(
                                "expected \(expectedKind.rawValue), received \(description.kind.rawValue)"
                            )
                        removeFailedPeer(context)
                        throw peerError
                    }
                    guard description.sdp.utf8.count
                        <= resourceLimits.maximumSDPPayloadBytes else {
                        let peerError = WebRTCPeerHostError
                            .sessionDescriptionPayloadTooLarge(
                                maximumBytes: resourceLimits.maximumSDPPayloadBytes
                            )
                        removeFailedPeer(context)
                        throw peerError
                    }
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
                                failPendingVideoCodecSwitch(
                                    viewerID: viewerID,
                                    underlyingError: error
                                )
                                let peerError =
                                    WebRTCPeerHostError.remoteDescriptionApplicationFailed(
                                        error.localizedDescription
                                    )
                                removeFailedPeer(context)
                                continuation.resume(throwing: peerError)
                            } else {
                                context.answerTimeoutWorkItem?.cancel()
                                context.answerTimeoutWorkItem = nil
                                context.awaitingAnswerGeneration = nil
                                completePendingVideoCodecSwitchAnswer(viewerID: viewerID)
                                completePendingVideoCodecRestorationAnswer(
                                    viewerID: viewerID
                                )
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
                : RTCDegradationPreference.maintainFramerate.rawValue
        )
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = policy.maximumBitrateBps.map(NSNumber.init)
            encoding.maxFramerate = policy.maximumFramesPerSecond.map(NSNumber.init)
            encoding.scaleResolutionDownBy = 1
            encoding.bitratePriority = policy.bitratePriority
            encoding.networkPriority = .high
        }
        sender.parameters = parameters
    }

    private func applySystemAudioSenderPolicy(to sender: RTCRtpSender) {
        let parameters = sender.parameters
        for encoding in parameters.encodings {
            Self.applySystemAudioEncodingPolicy(to: encoding)
        }
        sender.parameters = parameters
    }

    static func applySystemAudioEncodingPolicy(
        to encoding: RTCRtpEncodingParameters
    ) {
        // `maxaveragebitrate` in the negotiated Opus fmtp selects the
        // encoder's music target. Keep the sender ceiling aligned with it.
        let target = NSNumber(value: WebRTCOpusMusicSDP.maximumAverageBitrateBps)
        encoding.maxBitrateBps = target
        encoding.bitratePriority = 1
        encoding.networkPriority = .high
    }

    private func setVideoCodecPreference(
        _ codec: WebRTCVideoCodec,
        on transceiver: RTCRtpTransceiver,
        viewerID: String,
        slot: Int
    ) throws {
        let orderedRTCNames: [String]
        switch codec {
        case .av1:
            orderedRTCNames = [
                codec.rtcName,
                WebRTCVideoCodec.vp9.rtcName,
                WebRTCVideoCodec.vp8.rtcName,
            ]
        case .vp9:
            orderedRTCNames = [codec.rtcName, WebRTCVideoCodec.vp8.rtcName]
        case .h264, .vp8:
            orderedRTCNames = [codec.rtcName]
        }
        let preferences = orderedRTCNames.flatMap { rtcName in
            videoCodecCapabilities.filter {
                $0.name.caseInsensitiveCompare(rtcName) == .orderedSame
            }
        }
        guard !preferences.isEmpty else {
            throw WebRTCPeerHostError.videoCodecUnavailable(codec)
        }
        do {
            try transceiver.setCodecPreferences(preferences, error: ())
        } catch {
            throw WebRTCPeerHostError.videoCodecPreferenceFailed(
                codec: codec,
                viewerID: viewerID,
                slot: slot,
                message: error.localizedDescription
            )
        }
    }

    private func setSystemAudioCodecPreference(
        on transceiver: RTCRtpTransceiver,
        viewerID: String
    ) throws {
        let opus = audioCodecCapabilities.filter {
            $0.name.caseInsensitiveCompare("opus") == .orderedSame
        }
        guard !opus.isEmpty else {
            throw WebRTCPeerHostError.systemAudioCodecUnavailable
        }
        do {
            try transceiver.setCodecPreferences(opus, error: ())
        } catch {
            throw WebRTCPeerHostError.systemAudioCodecPreferenceFailed(
                viewerID: viewerID,
                message: error.localizedDescription
            )
        }
    }

    private func applyVideoCodecPreference(
        _ codec: WebRTCVideoCodec,
        previous: WebRTCVideoCodec,
        contexts: [PeerContext]
    ) throws {
        var changed: [(PeerContext, Int, RTCRtpTransceiver)] = []
        do {
            for context in contexts {
                for (slot, transceiver) in context.transceiversBySlot.sorted(by: {
                    $0.key < $1.key
                }) {
                    try setVideoCodecPreference(
                        codec,
                        on: transceiver,
                        viewerID: context.viewerID,
                        slot: slot
                    )
                    changed.append((context, slot, transceiver))
                }
            }
        } catch {
            for (context, slot, transceiver) in changed.reversed() {
                try? setVideoCodecPreference(
                    previous,
                    on: transceiver,
                    viewerID: context.viewerID,
                    slot: slot
                )
            }
            throw error
        }
    }

    private func completePendingVideoCodecSwitchAnswer(viewerID: String) {
        guard let pendingVideoCodecSwitch,
              pendingVideoCodecSwitch.awaitingViewerIDs.remove(viewerID) != nil,
              pendingVideoCodecSwitch.awaitingViewerIDs.isEmpty else {
            return
        }
        self.pendingVideoCodecSwitch = nil
        emit(.videoCodecChanged(codec: pendingVideoCodecSwitch.requested))
        replayLatestActiveFrames()
        pendingVideoCodecSwitch.continuation.resume()
    }

    private func completePendingVideoCodecRestorationAnswer(viewerID: String) {
        guard let pendingVideoCodecRestoration,
              pendingVideoCodecRestoration.awaitingViewerIDs.remove(viewerID) != nil,
              pendingVideoCodecRestoration.awaitingViewerIDs.isEmpty else {
            return
        }
        self.pendingVideoCodecRestoration = nil
        replayLatestActiveFrames()
    }

    private func peerLeftVideoCodecTransaction(viewerID: String) {
        completePendingVideoCodecSwitchAnswer(viewerID: viewerID)
        completePendingVideoCodecRestorationAnswer(viewerID: viewerID)
    }

    private func failPendingVideoCodecSwitch(
        viewerID: String,
        underlyingError: any Error
    ) {
        guard let pendingVideoCodecSwitch,
              pendingVideoCodecSwitch.awaitingViewerIDs.contains(viewerID) else {
            return
        }
        self.pendingVideoCodecSwitch = nil
        activeVideoCodec = pendingVideoCodecSwitch.previous

        let contexts = peers.values.sorted { $0.viewerID < $1.viewerID }
        try? applyVideoCodecPreference(
            pendingVideoCodecSwitch.previous,
            previous: pendingVideoCodecSwitch.requested,
            contexts: contexts
        )
        if !contexts.isEmpty {
            pendingVideoCodecRestoration = PendingVideoCodecRestoration(
                previous: pendingVideoCodecSwitch.previous,
                failedRequested: pendingVideoCodecSwitch.requested,
                awaitingViewerIDs: Set(contexts.map(\.viewerID))
            )
        }
        for context in contexts {
            requestPreviousCodecReoffer(
                for: context,
                previous: pendingVideoCodecSwitch.previous,
                requested: pendingVideoCodecSwitch.requested
            )
        }
        pendingVideoCodecSwitch.continuation.resume(throwing:
            WebRTCPeerHostError.videoCodecSwitchFailed(
                from: pendingVideoCodecSwitch.previous,
                to: pendingVideoCodecSwitch.requested,
                message: underlyingError.localizedDescription
            ))
    }

    /// Restores a peer after another viewer caused a transactional codec
    /// switch to fail. Peers that already answered are stable and can reoffer
    /// immediately. Peers still holding the abandoned target-codec offer must
    /// first apply an SDP rollback; creating another offer in have-local-offer
    /// would otherwise fail and unnecessarily disconnect the viewer.
    private func requestPreviousCodecReoffer(
        for context: PeerContext,
        previous: WebRTCVideoCodec,
        requested: WebRTCVideoCodec
    ) {
        context.answerTimeoutWorkItem?.cancel()
        context.answerTimeoutWorkItem = nil
        context.awaitingAnswerGeneration = nil
        context.operationGeneration.invalidateLocalDescriptions()

        switch context.connection.signalingState {
        case .stable:
            emit(.negotiationNeeded(viewerID: context.viewerID))

        case .haveLocalOffer, .haveLocalPrAnswer:
            let rollback = RTCSessionDescription(type: .rollback, sdp: "")
            context.connection.setLocalDescription(rollback) { [weak self, weak context] error in
                guard let self, let context else { return }
                queue.async { [self] in
                    guard !isClosed,
                          peers[context.viewerID] === context else { return }
                    if let error {
                        let hostError = WebRTCPeerHostError
                            .localDescriptionApplicationFailed(
                                "codec rollback: \(error.localizedDescription)"
                            )
                        emit(.error(viewerID: context.viewerID, error: hostError))
                        removeFailedPeer(context)
                    } else {
                        emit(.negotiationNeeded(viewerID: context.viewerID))
                    }
                }
            }

        case .haveRemoteOffer, .haveRemotePrAnswer, .closed:
            let error = WebRTCPeerHostError.videoCodecSwitchFailed(
                from: previous,
                to: requested,
                message: "viewer \(context.viewerID) could not roll back from signaling state \(context.connection.signalingState)"
            )
            emit(.error(viewerID: context.viewerID, error: error))
            removeFailedPeer(context)

        @unknown default:
            removeFailedPeer(context)
        }
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
                    guard let captureGeometry = slot.captureGeometry else { continue }
                    slot.frameSource.replayLatestFrame(
                        expectedWidth: captureGeometry.width,
                        expectedHeight: captureGeometry.height
                    )
                }
            }
        }
    }

    /// ScreenCaptureKit intentionally omits unchanged frames. Replaying one
    /// cached matching frame at most every two seconds lets a pending PLI or a
    /// rebuilt codec recover even when the shared screen is perfectly static,
    /// while keeping idle CPU/network work bounded to 0.5 FPS per source.
    private func scheduleIdleFrameReplay() {
        queue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            guard let self, !isClosed else { return }
            if peers.values.contains(where: { $0.connectionState == .connected }) {
                for slot in slots {
                    guard slot.metadata != nil,
                          let captureGeometry = slot.captureGeometry else { continue }
                    slot.frameSource.replayLatestFrameIfIdle(
                        forAtLeast: Self.idleFrameReplayIntervalNanoseconds,
                        expectedWidth: captureGeometry.width,
                        expectedHeight: captureGeometry.height
                    )
                }
            }
            scheduleIdleFrameReplay()
        }
    }

    private func replayLatestActiveFrames() {
        for slot in slots {
            guard slot.metadata != nil,
                  let captureGeometry = slot.captureGeometry else { continue }
            slot.frameSource.replayLatestFrame(
                expectedWidth: captureGeometry.width,
                expectedHeight: captureGeometry.height
            )
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
        peerLeftVideoCodecTransaction(viewerID: context.viewerID)
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
                    failPendingVideoCodecSwitch(
                        viewerID: viewerID,
                        underlyingError: WebRTCPeerHostError.videoCodecSwitchFailed(
                            from: pendingVideoCodecSwitch?.previous ?? activeVideoCodec,
                            to: pendingVideoCodecSwitch?.requested ?? activeVideoCodec,
                            message: "viewer connection became \(state)"
                        )
                    )
                    peers.removeValue(forKey: viewerID)
                    previousOutboundCounters = previousOutboundCounters.filter {
                        $0.key.viewerID != viewerID
                    }
                    close(context)
                    peerLeftVideoCodecTransaction(viewerID: viewerID)
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
                guard data.count <= resourceLimits.maximumControlMessagePayloadBytes else {
                    emit(.error(
                        viewerID: viewerID,
                        error: .controlMessagePayloadTooLarge(
                            maximumBytes: resourceLimits.maximumControlMessagePayloadBytes
                        )
                    ))
                    removeFailedPeer(context)
                    return
                }
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

    /// Internal boundary shared by the libwebrtc delegate and hostile-peer
    /// regression tests. Remote control payload violations are deliberately
    /// scoped to the sending peer.
    func receiveRemoteControlMessage(
        _ data: Data,
        isBinary: Bool = false,
        from viewerID: String
    ) {
        handle(.controlMessage(data, isBinary: isBinary), viewerID: viewerID, connection: nil)
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
            failPendingVideoCodecSwitch(
                viewerID: context.viewerID,
                underlyingError: error
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
        // Clip creates the control channel. Ignore unexpected remote channels.
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
        didReceiveMessageWith buffer: RTCDataBuffer
    ) {
        forward(.controlMessage(buffer.data, isBinary: buffer.isBinary))
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
