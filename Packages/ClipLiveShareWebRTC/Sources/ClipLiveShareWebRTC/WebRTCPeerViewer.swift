import ClipLiveShare
import Foundation
@preconcurrency import WebRTC

enum WebRTCOfferMediaSectionPolicy {
    static func validate(
        _ sdp: String,
        resourceLimits: WebRTCPeerResourceLimits
    ) throws {
        let limits = resourceLimits.normalized
        var videoCount = 0
        var audioCount = 0
        var applicationCount = 0

        for rawLine in sdp.split(
            omittingEmptySubsequences: true,
            whereSeparator: \.isNewline
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("m=") else { continue }
            guard let media = line.dropFirst(2).split(
                whereSeparator: \.isWhitespace
            ).first?.lowercased() else {
                throw WebRTCPeerViewerError.invalidOfferMediaSections(
                    maximumVideoTracks: limits.maximumVideoTracks
                )
            }
            switch media {
            case "video": videoCount += 1
            case "audio": audioCount += 1
            case "application": applicationCount += 1
            default:
                throw WebRTCPeerViewerError.invalidOfferMediaSections(
                    maximumVideoTracks: limits.maximumVideoTracks
                )
            }
            guard videoCount <= limits.maximumVideoTracks,
                  audioCount <= 1,
                  applicationCount <= 1 else {
                throw WebRTCPeerViewerError.invalidOfferMediaSections(
                    maximumVideoTracks: limits.maximumVideoTracks
                )
            }
        }
    }
}

struct WebRTCInboundReceiverAdmissionPolicy: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case video
        case systemAudio
        case unsupported
    }

    enum Decision: Equatable, Sendable {
        case accepted
        case duplicateCallback
        case videoLimitReached
        case duplicateSystemAudio
        case unsupported
    }

    let maximumVideoTracks: Int
    private(set) var videoReceiverIDs: Set<String> = []
    private(set) var systemAudioReceiverID: String?

    init(maximumVideoTracks: Int) {
        self.maximumVideoTracks = min(
            WebRTCRuntimeIdentity.maximumVideoSlots,
            max(1, maximumVideoTracks)
        )
    }

    mutating func admit(receiverID: String, kind: Kind) -> Decision {
        if videoReceiverIDs.contains(receiverID)
            || systemAudioReceiverID == receiverID {
            return .duplicateCallback
        }
        switch kind {
        case .video:
            guard videoReceiverIDs.count < maximumVideoTracks else {
                return .videoLimitReached
            }
            videoReceiverIDs.insert(receiverID)
            return .accepted
        case .systemAudio:
            guard systemAudioReceiverID == nil else {
                return .duplicateSystemAudio
            }
            systemAudioReceiverID = receiverID
            return .accepted
        case .unsupported:
            return .unsupported
        }
    }

    mutating func remove(receiverID: String) {
        videoReceiverIDs.remove(receiverID)
        if systemAudioReceiverID == receiverID {
            systemAudioReceiverID = nil
        }
    }

    var retainedReceiverCount: Int {
        videoReceiverIDs.count + (systemAudioReceiverID == nil ? 0 : 1)
    }
}

/// Clip's native, receive-only Unified Plan WebRTC peer.
///
/// The viewer owns one peer connection and never creates a local media track.
/// All mutable libwebrtc state is serialized on a private queue; delegate
/// callbacks only enqueue value events. Initial negotiation and later codec or
/// ICE-restart offers use the same `answer(_:)` operation.
public final class WebRTCPeerViewer: @unchecked Sendable {
    public typealias EventHandler = @Sendable (WebRTCPeerViewerEvent) -> Void

    private final class NegotiationOperation: @unchecked Sendable {
        let generation: UInt64
        let continuation: CheckedContinuation<WebRTCSessionDescription, any Error>

        init(
            generation: UInt64,
            continuation: CheckedContinuation<WebRTCSessionDescription, any Error>
        ) {
            self.generation = generation
            self.continuation = continuation
        }
    }

    private enum ReceivedTrack: @unchecked Sendable {
        case video(ClipLiveShareMediaTrackID)
        case systemAudio(trackID: String, accepted: Bool)
        case unsupported
    }

    private let configuration: WebRTCPeerViewerConfiguration
    private let resourceLimits: WebRTCPeerResourceLimits
    private let controlBufferPolicy: WebRTCControlBufferPolicy
    private let eventHandler: EventHandler
    private let eventDeliveryQueue: DispatchQueue
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let sslLease: WebRTCSSLRuntimeLease
    private let factory: RTCPeerConnectionFactory
    private let delegate: WebRTCPeerViewerDelegate
    private let connection: RTCPeerConnection

    private var registry = RemoteStreamRegistry()
    private var receiverAdmission: WebRTCInboundReceiverAdmissionPolicy
    private var videoTracks: [
        ClipLiveShareMediaTrackID: WebRTCRemoteVideoTrackHandle
    ] = [:]
    private var videoReceiverIDsByTrackID: [
        ClipLiveShareMediaTrackID: Set<String>
    ] = [:]
    private var receivedTracksByReceiverID: [String: ReceivedTrack] = [:]
    private var systemAudioTrack: RTCAudioTrack?
    private var systemAudioTrackID: String?
    private var systemAudioReceiverIDs: Set<String> = []
    private var systemAudioPlaybackEnabled: Bool
    private var systemAudioVolume: Double
    private var controlChannel: RTCDataChannel?
    private var connectionState: WebRTCPeerConnectionState = .new
    private var controlDataChannelState: WebRTCControlDataChannelState = .closed
    private var route: WebRTCConnectionRoute = .unknown
    private var negotiationGeneration: UInt64 = 0
    private var pendingNegotiation: NegotiationOperation?
    private var remoteDescriptionApplied = false
    private var pendingRemoteICECandidates: [WebRTCICECandidate] = []
    private var localICECandidateCount = 0
    private var remoteICECandidateCount = 0
    private var awaitsControlDrain = false
    private var isClosed = false

    public init(
        configuration: WebRTCPeerViewerConfiguration = .clipDefault,
        eventQueue: DispatchQueue = .main,
        eventHandler: @escaping EventHandler = { _ in }
    ) throws {
        self.configuration = configuration
        resourceLimits = configuration.resourceLimits.normalized
        receiverAdmission = WebRTCInboundReceiverAdmissionPolicy(
            maximumVideoTracks: configuration.resourceLimits.normalized
                .maximumVideoTracks
        )
        controlBufferPolicy = WebRTCControlBufferPolicy(
            resourceLimits: configuration.resourceLimits
        )
        systemAudioPlaybackEnabled = configuration.systemAudioPlaybackEnabled
        systemAudioVolume = configuration.systemAudioVolume
        self.eventHandler = eventHandler
        eventDeliveryQueue = DispatchQueue(
            label: "com.tomaslejdung.clip.liveshare.webrtc-viewer-events",
            target: eventQueue
        )
        queue = DispatchQueue(
            label: "com.tomaslejdung.clip.liveshare.webrtc-viewer",
            qos: .userInteractive
        )
        do {
            sslLease = try WebRTCSSLRuntimeLease()
        } catch {
            throw WebRTCPeerViewerError.sslInitializationFailed
        }
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        delegate = WebRTCPeerViewerDelegate()

        let rtcConfiguration = RTCConfiguration()
        rtcConfiguration.sdpSemantics = .unifiedPlan
        rtcConfiguration.bundlePolicy = .maxBundle
        rtcConfiguration.rtcpMuxPolicy = .require
        rtcConfiguration.continualGatheringPolicy = .gatherContinually
        rtcConfiguration.iceTransportPolicy = configuration.forcesRelay ? .relay : .all
        rtcConfiguration.iceServers = configuration.iceServers.map { server in
            if server.username != nil || server.credential != nil {
                return RTCIceServer(
                    urlStrings: server.urlStrings,
                    username: server.username,
                    credential: server.credential
                )
            }
            return RTCIceServer(urlStrings: server.urlStrings)
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let connection = factory.peerConnection(
            with: rtcConfiguration,
            constraints: constraints,
            delegate: delegate
        ) else {
            throw WebRTCPeerViewerError.peerConnectionCreationFailed(
                "libwebrtc returned nil"
            )
        }
        self.connection = connection
        queue.setSpecific(key: queueKey, value: 1)
        delegate.attach(to: self)
    }

    deinit {
        close()
    }

    public var snapshot: WebRTCPeerViewerSnapshot {
        onQueue {
            WebRTCPeerViewerSnapshot(
                connectionState: connectionState,
                controlDataChannelState: controlDataChannelState,
                route: route,
                negotiatedVideoTrackIDs: videoTracks.keys.map(\.rawValue).sorted(),
                boundStreams: registry.bindings.map(\.descriptor),
                systemAudioTrackID: systemAudioTrackID,
                isSystemAudioPlaybackEnabled: systemAudioPlaybackEnabled,
                systemAudioVolume: systemAudioVolume,
                isClosed: isClosed
            )
        }
    }

    public var remoteVideoStreams: [WebRTCRemoteVideoStream] {
        onQueue {
            registry.bindings.compactMap(remoteStream(for:))
        }
    }

    /// Applies an initial offer or a later codec/ICE-restart reoffer and
    /// returns the matching local answer. Only one asynchronous SDP operation
    /// may be active, and `close()` invalidates it deterministically.
    public func answer(
        _ offer: WebRTCSessionDescription
    ) async throws -> WebRTCSessionDescription {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<WebRTCSessionDescription, any Error>) in
            queue.async { [self] in
                do {
                    try ensureOpen()
                    guard offer.kind == .offer else {
                        throw WebRTCPeerViewerError.expectedOffer
                    }
                    guard offer.sdp.utf8.count <= resourceLimits.maximumSDPPayloadBytes else {
                        throw WebRTCPeerViewerError.sessionDescriptionPayloadTooLarge(
                            maximumBytes: resourceLimits.maximumSDPPayloadBytes
                        )
                    }
                    try WebRTCOfferMediaSectionPolicy.validate(
                        offer.sdp,
                        resourceLimits: resourceLimits
                    )
                    guard pendingNegotiation == nil else {
                        throw WebRTCPeerViewerError.negotiationInProgress
                    }
                    negotiationGeneration &+= 1
                    let operation = NegotiationOperation(
                        generation: negotiationGeneration,
                        continuation: continuation
                    )
                    pendingNegotiation = operation
                    // Candidate limits apply to one negotiation generation,
                    // not the lifetime of a peer that can receive many codec
                    // reoffers and ICE restarts.
                    localICECandidateCount = 0
                    remoteICECandidateCount = pendingRemoteICECandidates.count
                    applyRemoteOffer(offer, operation: operation)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Accepts host ICE in any signaling order. Candidates received before or
    /// during an offer are validated, bounded, and retained until that remote
    /// description has been installed.
    public func addRemoteICECandidate(
        _ candidate: WebRTCICECandidate
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try ensureOpen()
                    do {
                        try candidate.validate(resourceLimits: resourceLimits)
                    } catch {
                        throw WebRTCPeerViewerError.invalidICECandidate(
                            error.localizedDescription
                        )
                    }
                    guard remoteICECandidateCount
                        < resourceLimits.maximumICECandidatesPerPeer else {
                        throw WebRTCPeerViewerError.iceCandidateLimitReached(
                            maximum: resourceLimits.maximumICECandidatesPerPeer
                        )
                    }
                    remoteICECandidateCount += 1
                    guard remoteDescriptionApplied, pendingNegotiation == nil else {
                        pendingRemoteICECandidates.append(candidate)
                        continuation.resume()
                        return
                    }
                    add(candidate, continuation: continuation)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Makes the newest authoritative manifest visible to the race-safe
    /// stream registry. Media tracks may have arrived before or after it.
    public func applyRemoteStreamManifest(
        _ manifest: ClipLiveShareStreamManifest
    ) {
        onQueue {
            guard !isClosed else { return }
            handleRegistryChanges(registry.apply(manifest))
        }
    }

    @discardableResult
    public func sendControl(
        _ data: Data,
        isBinary: Bool = false
    ) -> Bool {
        onQueue {
            guard !isClosed,
                  let controlChannel,
                  controlChannel.readyState == .open else { return false }
            guard controlBufferPolicy.permits(
                payloadByteCount: data.count,
                bufferedAmountBytes: controlChannel.bufferedAmount
            ) else {
                if controlBufferPolicy.permits(
                    payloadByteCount: data.count,
                    bufferedAmountBytes: 0
                ) {
                    awaitsControlDrain = true
                }
                return false
            }
            return controlChannel.sendData(RTCDataBuffer(
                data: data,
                isBinary: isBinary
            ))
        }
    }

    public func setSystemAudioPlaybackEnabled(_ enabled: Bool) {
        onQueue {
            guard !isClosed else { return }
            systemAudioPlaybackEnabled = enabled
            systemAudioTrack?.isEnabled = enabled
        }
    }

    /// Sets the gain for the one aggregate remote system-audio track. The
    /// receiver keeps volume independent from mute so restoring playback uses
    /// the viewer's previous level.
    public func setSystemAudioVolume(_ volume: Double) {
        onQueue {
            guard !isClosed else { return }
            systemAudioVolume = min(max(volume, 0), 1)
            systemAudioTrack?.source.volume = systemAudioVolume
        }
    }

    public func inboundStatisticsSnapshot() async throws
        -> WebRTCInboundStatisticsSnapshot
    {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try ensureOpen()
                    connection.statistics { [weak self] report in
                        guard let self else {
                            continuation.resume(throwing:
                                WebRTCPeerViewerError.viewerClosed)
                            return
                        }
                        queue.async { [self] in
                            guard !isClosed else {
                                continuation.resume(throwing:
                                    WebRTCPeerViewerError.viewerClosed)
                                return
                            }
                            let snapshot = WebRTCInboundStatisticsParser.parse(report)
                            route = snapshot.route
                            continuation.resume(returning: snapshot)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Idempotent deterministic teardown. No delegate callback can mutate or
    /// re-open receiver state after this returns.
    public func close() {
        onQueue {
            guard !isClosed else { return }
            isClosed = true
            negotiationGeneration &+= 1
            if let pendingNegotiation {
                self.pendingNegotiation = nil
                pendingNegotiation.continuation.resume(throwing:
                    WebRTCPeerViewerError.viewerClosed)
            }
            pendingRemoteICECandidates.removeAll(keepingCapacity: false)
            delegate.detach()
            connection.delegate = nil

            if let controlChannel {
                controlChannel.delegate = nil
                controlChannel.close()
                self.controlChannel = nil
            }
            if controlDataChannelState != .closed {
                controlDataChannelState = .closed
                emit(.controlDataChannelStateChanged(.closed))
            }

            for change in registry.reset() {
                if case let .unbound(binding) = change {
                    emit(.remoteVideoStreamRemoved(streamID: binding.id))
                }
            }
            for track in videoTracks.values { track.invalidate() }
            videoTracks.removeAll(keepingCapacity: false)
            videoReceiverIDsByTrackID.removeAll(keepingCapacity: false)

            if let systemAudioTrackID {
                systemAudioTrack?.isEnabled = false
                systemAudioTrack = nil
                self.systemAudioTrackID = nil
                systemAudioReceiverIDs.removeAll(keepingCapacity: false)
                emit(.systemAudioTrackRemoved(trackID: systemAudioTrackID))
            }
            receivedTracksByReceiverID.removeAll(keepingCapacity: false)
            receiverAdmission = WebRTCInboundReceiverAdmissionPolicy(
                maximumVideoTracks: resourceLimits.maximumVideoTracks
            )
            connection.close()
            if connectionState != .closed {
                connectionState = .closed
                emit(.connectionStateChanged(.closed))
            }
        }
    }

    fileprivate func handle(
        _ event: WebRTCPeerViewerDelegate.Event,
        connection callbackConnection: RTCPeerConnection? = nil
    ) {
        queue.async { [self] in
            guard !isClosed,
                  callbackConnection == nil || callbackConnection === connection else {
                return
            }
            switch event {
            case .localICECandidate(let candidate):
                guard localICECandidateCount
                    < resourceLimits.maximumICECandidatesPerPeer else { return }
                localICECandidateCount += 1
                emit(.localICECandidate(candidate))

            case .connectionState(let state):
                guard state != connectionState else { return }
                connectionState = state
                emit(.connectionStateChanged(state))

            case .dataChannelOpened(let channel):
                acceptDataChannel(channel)

            case let .dataChannelState(channel, state):
                guard channel === controlChannel,
                      state != controlDataChannelState else { return }
                controlDataChannelState = state
                emit(.controlDataChannelStateChanged(state))

            case let .controlBufferedAmountChanged(channel, amount):
                guard channel === controlChannel,
                      awaitsControlDrain,
                      controlBufferPolicy.hasDrained(bufferedAmountBytes: amount) else {
                    return
                }
                awaitsControlDrain = false
                emit(.controlDataChannelDrained)

            case let .controlMessage(channel, data, isBinary):
                guard channel === controlChannel else { return }
                guard data.count <= resourceLimits.maximumControlMessagePayloadBytes else {
                    emit(.error(.controlMessagePayloadTooLarge(
                        maximumBytes: resourceLimits.maximumControlMessagePayloadBytes
                    )))
                    return
                }
                emit(.controlMessageReceived(data: data, isBinary: isBinary))

            case .negotiationNeeded:
                emit(.negotiationNeeded)

            case let .receiverAdded(receiverID, track):
                receive(track, receiverID: receiverID)

            case let .receiverRemoved(receiverID):
                removeReceiver(receiverID)

            case let .error(error):
                emit(.error(error))
            }
        }
    }

    private func applyRemoteOffer(
        _ offer: WebRTCSessionDescription,
        operation: NegotiationOperation
    ) {
        let rtcOffer = RTCSessionDescription(type: .offer, sdp: offer.sdp)
        connection.setRemoteDescription(rtcOffer) { [weak self] error in
            guard let self else {
                operation.continuation.resume(throwing:
                    WebRTCPeerViewerError.viewerClosed)
                return
            }
            queue.async { [self] in
                guard pendingNegotiation === operation else { return }
                if let error {
                    fail(operation, with: .remoteDescriptionApplicationFailed(
                        error.localizedDescription
                    ))
                    return
                }
                remoteDescriptionApplied = true
                flushPendingRemoteICECandidates()
                createAnswer(operation)
            }
        }
    }

    private func createAnswer(_ operation: NegotiationOperation) {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        connection.answer(for: constraints) { [weak self] description, error in
            guard let self else {
                operation.continuation.resume(throwing:
                    WebRTCPeerViewerError.viewerClosed)
                return
            }
            queue.async { [self] in
                guard pendingNegotiation === operation else { return }
                if let error {
                    fail(operation, with: .localDescriptionCreationFailed(
                        error.localizedDescription
                    ))
                    return
                }
                guard let description else {
                    fail(operation, with: .localDescriptionCreationFailed(
                        "libwebrtc returned neither a description nor an error"
                    ))
                    return
                }
                let upgraded = RTCSessionDescription(
                    type: description.type,
                    sdp: WebRTCOpusMusicSDP.applying(to: description.sdp)
                )
                applyLocalAnswer(upgraded, operation: operation)
            }
        }
    }

    private func applyLocalAnswer(
        _ answer: RTCSessionDescription,
        operation: NegotiationOperation
    ) {
        connection.setLocalDescription(answer) { [weak self] error in
            guard let self else {
                operation.continuation.resume(throwing:
                    WebRTCPeerViewerError.viewerClosed)
                return
            }
            queue.async { [self] in
                guard pendingNegotiation === operation else { return }
                if let error {
                    fail(operation, with: .localDescriptionApplicationFailed(
                        error.localizedDescription
                    ))
                    return
                }
                pendingNegotiation = nil
                operation.continuation.resume(returning: WebRTCSessionDescription(
                    kind: .answer,
                    sdp: answer.sdp
                ))
            }
        }
    }

    private func fail(
        _ operation: NegotiationOperation,
        with error: WebRTCPeerViewerError
    ) {
        guard pendingNegotiation === operation else { return }
        pendingNegotiation = nil
        operation.continuation.resume(throwing: error)
        emit(.error(error))
    }

    private func add(
        _ candidate: WebRTCICECandidate,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
        connection.add(rtcCandidate) { [weak self] error in
            guard let self else {
                continuation.resume(throwing: WebRTCPeerViewerError.viewerClosed)
                return
            }
            queue.async { [self] in
                if isClosed {
                    continuation.resume(throwing: WebRTCPeerViewerError.viewerClosed)
                } else if let error {
                    continuation.resume(throwing:
                        WebRTCPeerViewerError.iceCandidateApplicationFailed(
                            error.localizedDescription
                        ))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func flushPendingRemoteICECandidates() {
        let candidates = pendingRemoteICECandidates
        pendingRemoteICECandidates.removeAll(keepingCapacity: true)
        for candidate in candidates {
            let rtcCandidate = RTCIceCandidate(
                sdp: candidate.candidate,
                sdpMLineIndex: candidate.sdpMLineIndex,
                sdpMid: candidate.sdpMid
            )
            connection.add(rtcCandidate) { [weak self] error in
                guard let self, let error else { return }
                queue.async { [self] in
                    guard !isClosed else { return }
                    emit(.error(.iceCandidateApplicationFailed(
                        error.localizedDescription
                    )))
                }
            }
        }
    }

    private func acceptDataChannel(_ channel: RTCDataChannel) {
        guard channel.label == WebRTCRuntimeIdentity.controlDataChannelLabel,
              channel.isOrdered,
              controlChannel == nil else {
            channel.close()
            emit(.error(.unexpectedDataChannel(channel.label)))
            return
        }
        controlChannel = channel
        channel.delegate = delegate
        controlDataChannelState = Self.dataChannelState(channel.readyState)
        emit(.controlDataChannelStateChanged(controlDataChannelState))
    }

    private func receive(
        _ track: RTCMediaStreamTrack,
        receiverID: String
    ) {
        guard receivedTracksByReceiverID[receiverID] == nil else { return }
        if let videoTrack = track as? RTCVideoTrack {
            guard let mediaTrackID = try? ClipLiveShareMediaTrackID(
                rawValue: videoTrack.trackId
            ) else {
                videoTrack.isEnabled = false
                return
            }
            switch receiverAdmission.admit(
                receiverID: receiverID,
                kind: .video
            ) {
            case .accepted:
                break
            case .duplicateCallback:
                return
            case .videoLimitReached:
                videoTrack.isEnabled = false
                emit(.error(.videoTrackLimitReached(
                    maximum: resourceLimits.maximumVideoTracks
                )))
                return
            case .duplicateSystemAudio, .unsupported:
                videoTrack.isEnabled = false
                return
            }
            receivedTracksByReceiverID[receiverID] = .video(mediaTrackID)
            var receiverIDs = videoReceiverIDsByTrackID[mediaTrackID] ?? []
            receiverIDs.insert(receiverID)
            videoReceiverIDsByTrackID[mediaTrackID] = receiverIDs
            guard videoTracks[mediaTrackID] == nil else { return }
            videoTracks[mediaTrackID] = WebRTCRemoteVideoTrackHandle(track: videoTrack)
            handleRegistryChanges(registry.registerMediaTrack(mediaTrackID))
            return
        }
        if let audioTrack = track as? RTCAudioTrack {
            switch receiverAdmission.admit(
                receiverID: receiverID,
                kind: .systemAudio
            ) {
            case .accepted:
                receivedTracksByReceiverID[receiverID] = .systemAudio(
                    trackID: audioTrack.trackId,
                    accepted: true
                )
                systemAudioReceiverIDs.insert(receiverID)
                systemAudioTrack = audioTrack
                systemAudioTrackID = audioTrack.trackId
                audioTrack.source.volume = systemAudioVolume
                audioTrack.isEnabled = systemAudioPlaybackEnabled
                emit(.systemAudioTrackAvailable(trackID: audioTrack.trackId))
            case .duplicateCallback:
                return
            case .duplicateSystemAudio:
                audioTrack.isEnabled = false
                emit(.error(.duplicateSystemAudioTrack))
            case .videoLimitReached, .unsupported:
                audioTrack.isEnabled = false
            }
            return
        }
        track.isEnabled = false
    }

    private func removeReceiver(_ receiverID: String) {
        guard let received = receivedTracksByReceiverID.removeValue(
            forKey: receiverID
        ) else { return }
        receiverAdmission.remove(receiverID: receiverID)
        switch received {
        case .video(let mediaTrackID):
            var receiverIDs = videoReceiverIDsByTrackID[mediaTrackID] ?? []
            receiverIDs.remove(receiverID)
            guard receiverIDs.isEmpty else {
                videoReceiverIDsByTrackID[mediaTrackID] = receiverIDs
                return
            }
            videoReceiverIDsByTrackID[mediaTrackID] = nil
            handleRegistryChanges(registry.removeMediaTrack(mediaTrackID))
            videoTracks.removeValue(forKey: mediaTrackID)?.invalidate()

        case let .systemAudio(trackID, accepted):
            guard accepted else { return }
            systemAudioReceiverIDs.remove(receiverID)
            guard systemAudioReceiverIDs.isEmpty,
                  systemAudioTrackID == trackID else { return }
            systemAudioTrack?.isEnabled = false
            systemAudioTrack = nil
            systemAudioTrackID = nil
            emit(.systemAudioTrackRemoved(trackID: trackID))

        case .unsupported:
            break
        }
    }

    private func handleRegistryChanges(
        _ changes: [RemoteStreamRegistryChange]
    ) {
        for change in changes {
            switch change {
            case .bound(let binding):
                if let stream = remoteStream(for: binding) {
                    emit(.remoteVideoStreamAdded(stream))
                }
            case .updated(_, let current):
                if let stream = remoteStream(for: current) {
                    emit(.remoteVideoStreamUpdated(stream))
                }
            case .unbound(let binding):
                emit(.remoteVideoStreamRemoved(streamID: binding.id))
            }
        }
    }

    private func remoteStream(
        for binding: RemoteStreamBinding
    ) -> WebRTCRemoteVideoStream? {
        guard let track = videoTracks[binding.mediaTrackID] else { return nil }
        return WebRTCRemoteVideoStream(
            descriptor: binding.descriptor,
            track: track
        )
    }

    private func ensureOpen() throws {
        guard !isClosed else { throw WebRTCPeerViewerError.viewerClosed }
    }

    private func emit(_ event: WebRTCPeerViewerEvent) {
        let eventHandler = eventHandler
        eventDeliveryQueue.async {
            eventHandler(event)
        }
    }

    @discardableResult
    private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync(execute: work)
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

private final class WebRTCPeerViewerDelegate: NSObject,
    RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable
{
    enum Event: @unchecked Sendable {
        case localICECandidate(WebRTCICECandidate)
        case connectionState(WebRTCPeerConnectionState)
        case dataChannelOpened(RTCDataChannel)
        case dataChannelState(RTCDataChannel, WebRTCControlDataChannelState)
        case controlBufferedAmountChanged(RTCDataChannel, UInt64)
        case controlMessage(RTCDataChannel, Data, isBinary: Bool)
        case negotiationNeeded
        case receiverAdded(receiverID: String, track: RTCMediaStreamTrack)
        case receiverRemoved(receiverID: String)
        case error(WebRTCPeerViewerError)
    }

    private weak var viewer: WebRTCPeerViewer?
    private let lock = NSLock()

    func attach(to viewer: WebRTCPeerViewer) {
        lock.withLock { self.viewer = viewer }
    }

    func detach() {
        lock.withLock { viewer = nil }
    }

    private func forward(
        _ event: Event,
        connection: RTCPeerConnection? = nil
    ) {
        lock.withLock { viewer }?.handle(event, connection: connection)
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

    func peerConnectionShouldNegotiate(
        _ peerConnection: RTCPeerConnection
    ) {
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
        forward(.dataChannelOpened(dataChannel), connection: peerConnection)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        forward(.connectionState(Self.connectionState(newState)), connection: peerConnection)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        guard let track = rtpReceiver.track else { return }
        forward(.receiverAdded(
            receiverID: rtpReceiver.receiverId,
            track: track
        ), connection: peerConnection)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove rtpReceiver: RTCRtpReceiver
    ) {
        forward(.receiverRemoved(
            receiverID: rtpReceiver.receiverId
        ), connection: peerConnection)
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
        forward(.dataChannelState(
            dataChannel,
            Self.dataChannelState(dataChannel.readyState)
        ))
    }

    func dataChannel(
        _ dataChannel: RTCDataChannel,
        didChangeBufferedAmount _: UInt64
    ) {
        forward(.controlBufferedAmountChanged(
            dataChannel,
            dataChannel.bufferedAmount
        ))
    }

    func dataChannel(
        _ dataChannel: RTCDataChannel,
        didReceiveMessageWith buffer: RTCDataBuffer
    ) {
        forward(.controlMessage(
            dataChannel,
            buffer.data,
            isBinary: buffer.isBinary
        ))
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
