import ClipLiveShare
import Foundation

/// Video codecs that Clip can select for an active WebRTC screen share.
///
/// This is intentionally independent from the app's settings model. The
/// WebRTC package owns negotiation while callers decide how the choice is
/// presented and persisted.
public enum WebRTCVideoCodec: String, CaseIterable, Codable, Equatable, Sendable {
    case h264
    case vp8
    case vp9
    case av1

    var rtcName: String {
        switch self {
        case .h264: "H264"
        case .vp8: "VP8"
        case .vp9: "VP9"
        case .av1: "AV1"
        }
    }
}

public struct WebRTCICEServerConfiguration: Equatable, Sendable {
    public var urlStrings: [String]
    public var username: String?
    public var credential: String?

    public init(
        urlStrings: [String],
        username: String? = nil,
        credential: String? = nil
    ) {
        self.urlStrings = urlStrings
        self.username = username
        self.credential = credential
    }
}

public struct WebRTCSenderPolicy: Equatable, Sendable {
    public var maximumBitrateBps: Int?
    public var maximumFramesPerSecond: Int?
    public var maintainsResolution: Bool
    public var bitratePriority: Double

    public init(
        maximumBitrateBps: Int? = 12_000_000,
        maximumFramesPerSecond: Int? = 30,
        maintainsResolution: Bool = true,
        bitratePriority: Double = 1
    ) {
        self.maximumBitrateBps = maximumBitrateBps
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.maintainsResolution = maintainsResolution
        self.bitratePriority = bitratePriority
    }

    public static let goPeepDefault = Self()
}

/// Resource limits applied before a viewer can allocate a native peer and to
/// every ICE exchange. GoPeep v1 has no admission acknowledgement, so the host
/// enforces these limits locally. Eight viewers leaves useful headroom for a
/// personal screen-share room without allowing an untrusted room to allocate
/// an unlimited number of four-transceiver peer connections.
public struct WebRTCPeerResourceLimits: Equatable, Sendable {
    public var maximumViewerCount: Int
    public var answerTimeout: TimeInterval
    public var maximumICECandidatesPerPeer: Int
    public var maximumICECandidatePayloadBytes: Int
    public var maximumViewerIDBytes: Int
    public var maximumSDPPayloadBytes: Int
    public var maximumControlMessagePayloadBytes: Int
    public var maximumControlBufferedAmountBytes: Int

    public init(
        maximumViewerCount: Int = 8,
        answerTimeout: TimeInterval = 15,
        maximumICECandidatesPerPeer: Int = 256,
        maximumICECandidatePayloadBytes: Int = 4_096,
        maximumViewerIDBytes: Int = 128,
        maximumSDPPayloadBytes: Int = 262_144,
        maximumControlMessagePayloadBytes: Int = 65_536,
        maximumControlBufferedAmountBytes: Int = 262_144
    ) {
        self.maximumViewerCount = maximumViewerCount
        self.answerTimeout = answerTimeout
        self.maximumICECandidatesPerPeer = maximumICECandidatesPerPeer
        self.maximumICECandidatePayloadBytes = maximumICECandidatePayloadBytes
        self.maximumViewerIDBytes = maximumViewerIDBytes
        self.maximumSDPPayloadBytes = maximumSDPPayloadBytes
        self.maximumControlMessagePayloadBytes = maximumControlMessagePayloadBytes
        self.maximumControlBufferedAmountBytes = maximumControlBufferedAmountBytes
    }

    public static let goPeepDefault = Self()

    public var normalized: Self {
        let finiteAnswerTimeout = answerTimeout.isFinite ? answerTimeout : 15
        let normalizedControlMessagePayloadBytes = min(
            262_144,
            max(1_024, maximumControlMessagePayloadBytes)
        )
        return Self(
            maximumViewerCount: min(32, max(1, maximumViewerCount)),
            answerTimeout: min(120, max(0.01, finiteAnswerTimeout)),
            maximumICECandidatesPerPeer: min(
                1_024,
                max(1, maximumICECandidatesPerPeer)
            ),
            maximumICECandidatePayloadBytes: min(
                16_384,
                max(256, maximumICECandidatePayloadBytes)
            ),
            maximumViewerIDBytes: min(512, max(16, maximumViewerIDBytes)),
            maximumSDPPayloadBytes: min(
                1_048_576,
                max(4_096, maximumSDPPayloadBytes)
            ),
            maximumControlMessagePayloadBytes: normalizedControlMessagePayloadBytes,
            maximumControlBufferedAmountBytes: max(
                normalizedControlMessagePayloadBytes,
                min(4_194_304, max(65_536, maximumControlBufferedAmountBytes))
            )
        )
    }
}

/// Pure high-water policy shared by the native DataChannel send paths and
/// deterministic tests. Clip never maintains a second application-level
/// control queue: durable state is replayed by the coordinator, while cursor
/// samples are intentionally superseded by the next sample.
struct WebRTCControlBufferPolicy: Equatable, Sendable {
    let resourceLimits: WebRTCPeerResourceLimits

    init(resourceLimits: WebRTCPeerResourceLimits) {
        self.resourceLimits = resourceLimits.normalized
    }

    func permits(payloadByteCount: Int, bufferedAmountBytes: UInt64) -> Bool {
        guard payloadByteCount >= 0,
              payloadByteCount <= resourceLimits.maximumControlMessagePayloadBytes else {
            return false
        }
        let remainingCapacity = resourceLimits.maximumControlBufferedAmountBytes
            - payloadByteCount
        return bufferedAmountBytes <= UInt64(remainingCapacity)
    }

    /// Uses a low-water mark so a durable-state replay is not immediately
    /// pushed back into the same saturated native queue. The data channel is
    /// the only queue; Clip retains only the latest authoritative snapshot.
    func hasDrained(bufferedAmountBytes: UInt64) -> Bool {
        bufferedAmountBytes <= UInt64(
            resourceLimits.maximumControlBufferedAmountBytes / 2
        )
    }
}

public struct WebRTCPeerHostConfiguration: Equatable, Sendable {
    public var iceServers: [WebRTCICEServerConfiguration]
    public var forcesRelay: Bool
    public var senderPolicy: WebRTCSenderPolicy
    public var resourceLimits: WebRTCPeerResourceLimits
    public var videoCodec: WebRTCVideoCodec
    public var videoEncodingMode: LiveShareEncodingMode

    public init(
        iceServers: [WebRTCICEServerConfiguration],
        forcesRelay: Bool = false,
        senderPolicy: WebRTCSenderPolicy = .goPeepDefault,
        resourceLimits: WebRTCPeerResourceLimits = .goPeepDefault,
        videoCodec: WebRTCVideoCodec = .h264,
        videoEncodingMode: LiveShareEncodingMode = .quality
    ) {
        self.iceServers = iceServers
        self.forcesRelay = forcesRelay
        self.senderPolicy = senderPolicy
        self.resourceLimits = resourceLimits
        self.videoCodec = videoCodec
        self.videoEncodingMode = videoEncodingMode
    }

    public static let goPeepDefault = Self(iceServers: [
        .init(urlStrings: ["stun:stun.l.google.com:19302"]),
        .init(urlStrings: ["stun:stun1.l.google.com:19302"]),
        .init(urlStrings: ["stun:stun2.l.google.com:19302"]),
    ])
}

public struct WebRTCSessionDescription: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case offer
        case answer
    }

    public let kind: Kind
    public let sdp: String

    public init(kind: Kind, sdp: String) {
        self.kind = kind
        self.sdp = sdp
    }
}

/// A transport-neutral ICE candidate suitable for embedding in GoPeep's
/// `candidate` JSON field.
public struct WebRTCICECandidate: Codable, Equatable, Sendable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int32

    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

public enum WebRTCICECandidateValidationError: Error, Equatable, LocalizedError, Sendable {
    case payloadTooLarge(maximumBytes: Int)
    case invalidMediaLineIndex(Int32)
    case invalidMediaID
    case malformedCandidate

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge(let maximumBytes):
            "The ICE candidate exceeds the \(maximumBytes)-byte limit."
        case .invalidMediaLineIndex(let index):
            "The ICE candidate media-line index \(index) is out of range."
        case .invalidMediaID:
            "The ICE candidate media identifier is invalid."
        case .malformedCandidate:
            "The ICE candidate does not match the expected candidate grammar."
        }
    }
}

public extension WebRTCICECandidate {
    /// Performs inexpensive structural validation before libwebrtc receives
    /// untrusted signaling input. Extensions after the mandatory RFC 8445
    /// fields remain accepted for browser compatibility.
    func validate(resourceLimits: WebRTCPeerResourceLimits = .goPeepDefault) throws {
        let limits = resourceLimits.normalized
        guard candidate.utf8.count <= limits.maximumICECandidatePayloadBytes else {
            throw WebRTCICECandidateValidationError.payloadTooLarge(
                maximumBytes: limits.maximumICECandidatePayloadBytes
            )
        }
        // Four video m-lines plus the reliable data-channel m-line are the only
        // negotiated sections in Clip's GoPeep-compatible offer.
        guard (0 ... Int32(WebRTCRuntimeIdentity.maximumVideoSlots)).contains(sdpMLineIndex) else {
            throw WebRTCICECandidateValidationError.invalidMediaLineIndex(sdpMLineIndex)
        }
        if let sdpMid {
            guard !sdpMid.isEmpty,
                  sdpMid.utf8.count <= 64,
                  sdpMid.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw WebRTCICECandidateValidationError.invalidMediaID
            }
        }
        guard candidate.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw WebRTCICECandidateValidationError.malformedCandidate
        }

        let fields = candidate.split(whereSeparator: \Character.isWhitespace)
        guard fields.count >= 8,
              fields[0].hasPrefix("candidate:"),
              fields[0].count > "candidate:".count,
              fields[0].count <= 266,
              let component = Int(fields[1]), (1 ... 256).contains(component),
              ["udp", "tcp"].contains(fields[2].lowercased()),
              UInt32(fields[3]) != nil,
              !fields[4].isEmpty, fields[4].count <= 255,
              let port = UInt16(fields[5]), port > 0,
              fields[6].lowercased() == "typ",
              ["host", "srflx", "prflx", "relay"].contains(fields[7].lowercased()),
              fields.allSatisfy({ field in
                  field.count <= 512 && field.unicodeScalars.allSatisfy {
                      !CharacterSet.controlCharacters.contains($0)
                  }
              }) else {
            throw WebRTCICECandidateValidationError.malformedCandidate
        }
    }
}

/// Pixel geometry delivered by ScreenCaptureKit to a stable WebRTC slot.
///
/// This can intentionally differ from the encoded stream metadata by one
/// pixel. H.264 requires even output dimensions, while preserving an odd-sized
/// native capture lets the encoder crop that final pixel without asking
/// ScreenCaptureKit to fractionally rescale the complete image.
public struct WebRTCVideoCaptureGeometry: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public struct WebRTCStreamSlotSnapshot: Equatable, Sendable, Identifiable {
    public let index: Int
    public let trackID: String
    public let streamID: String
    public let metadata: GoPeepV1StreamInfo?
    public let captureGeometry: WebRTCVideoCaptureGeometry?

    public var id: Int { index }
    public var isActive: Bool { metadata != nil }

    init(
        index: Int,
        trackID: String,
        streamID: String,
        metadata: GoPeepV1StreamInfo?,
        captureGeometry: WebRTCVideoCaptureGeometry? = nil
    ) {
        self.index = index
        self.trackID = trackID
        self.streamID = streamID
        self.metadata = metadata
        self.captureGeometry = captureGeometry
    }
}

public enum WebRTCPeerConnectionState: String, Equatable, Sendable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

public enum WebRTCControlDataChannelState: String, Equatable, Sendable {
    case connecting
    case open
    case closing
    case closed
}

public enum WebRTCConnectionRoute: String, Equatable, Sendable {
    case unknown
    case direct
    case relay
}

public struct WebRTCViewerSnapshot: Equatable, Sendable, Identifiable {
    public let viewerID: String
    public let connectionState: WebRTCPeerConnectionState
    public let controlDataChannelState: WebRTCControlDataChannelState
    public let route: WebRTCConnectionRoute

    public var id: String { viewerID }
    public var isConnected: Bool { connectionState == .connected }

    public init(
        viewerID: String,
        connectionState: WebRTCPeerConnectionState,
        controlDataChannelState: WebRTCControlDataChannelState,
        route: WebRTCConnectionRoute = .unknown
    ) {
        self.viewerID = viewerID
        self.connectionState = connectionState
        self.controlDataChannelState = controlDataChannelState
        self.route = route
    }
}

/// A cumulative outbound RTP counter and its measured interval rate for one
/// viewer/slot sender. Bitrate is `nil` until two valid libwebrtc reports have
/// established a baseline. FPS uses libwebrtc's direct measurement when it is
/// present, then falls back to counter deltas. Nothing is estimated from the
/// configured bitrate or capture cadence.
public struct WebRTCOutboundViewerStatistics: Equatable, Sendable, Identifiable {
    public let viewerID: String
    public let bytesSent: UInt64
    public let packetsSent: UInt64
    public let framesSent: UInt64
    public let framesEncoded: UInt64
    public let bitrateBps: Double?
    public let framesPerSecond: Double?
    /// libwebrtc's current codec target, which may be lower than Clip's
    /// selected ceiling while congestion control protects latency.
    public let targetBitrateBps: Double?
    /// Mean encoder time for frames completed during the latest sample.
    public let averageEncodeTimeMilliseconds: Double?
    /// Mean time packets completed during the latest sample spent waiting
    /// before being handed to the network socket.
    public let averagePacketSendDelayMilliseconds: Double?
    public let encoderDroppedFrames: UInt64?
    public let qualityLimitationReason: String?
    public let codec: String?

    public var id: String { viewerID }
    public var deliveredFramesPerSecond: Double? { framesPerSecond }

    public init(
        viewerID: String,
        bytesSent: UInt64,
        packetsSent: UInt64,
        framesSent: UInt64,
        framesEncoded: UInt64,
        bitrateBps: Double?,
        framesPerSecond: Double?,
        targetBitrateBps: Double? = nil,
        averageEncodeTimeMilliseconds: Double? = nil,
        averagePacketSendDelayMilliseconds: Double? = nil,
        encoderDroppedFrames: UInt64? = nil,
        qualityLimitationReason: String? = nil,
        codec: String? = nil
    ) {
        self.viewerID = viewerID
        self.bytesSent = bytesSent
        self.packetsSent = packetsSent
        self.framesSent = framesSent
        self.framesEncoded = framesEncoded
        self.bitrateBps = bitrateBps
        self.framesPerSecond = framesPerSecond
        self.targetBitrateBps = targetBitrateBps
        self.averageEncodeTimeMilliseconds = averageEncodeTimeMilliseconds
        self.averagePacketSendDelayMilliseconds = averagePacketSendDelayMilliseconds
        self.encoderDroppedFrames = encoderDroppedFrames
        self.qualityLimitationReason = qualityLimitationReason
        self.codec = codec
    }
}

/// Actual outbound RTP totals aggregated across every current viewer sender
/// for one of GoPeep's four stable video slots.
public struct WebRTCOutboundSlotStatistics: Equatable, Sendable, Identifiable {
    public let slot: Int
    public let trackID: String
    public let isActive: Bool
    public let bytesSent: UInt64
    public let packetsSent: UInt64
    public let framesSent: UInt64
    public let framesEncoded: UInt64
    /// Sum of measured network egress bitrate across viewers.
    public let aggregateBitrateBps: Double?
    /// Mean measured delivered sender FPS across viewers.
    public let averageFramesPerSecond: Double?
    /// Sum of libwebrtc's current target across viewers. This is deliberately
    /// distinct from both measured egress and Clip's configured ceiling.
    public let aggregateTargetBitrateBps: Double?
    public let averageEncodeTimeMilliseconds: Double?
    public let averagePacketSendDelayMilliseconds: Double?
    public let encoderDroppedFrames: UInt64
    public let qualityLimitationReasons: [String]
    public let codecs: [String]
    public let viewers: [WebRTCOutboundViewerStatistics]

    public var id: Int { slot }
    public var bitrateBps: Double? { aggregateBitrateBps }
    public var deliveredFramesPerSecond: Double? { averageFramesPerSecond }

    public init(
        slot: Int,
        trackID: String,
        isActive: Bool,
        bytesSent: UInt64,
        packetsSent: UInt64,
        framesSent: UInt64,
        framesEncoded: UInt64,
        aggregateBitrateBps: Double?,
        averageFramesPerSecond: Double?,
        aggregateTargetBitrateBps: Double? = nil,
        averageEncodeTimeMilliseconds: Double? = nil,
        averagePacketSendDelayMilliseconds: Double? = nil,
        encoderDroppedFrames: UInt64 = 0,
        qualityLimitationReasons: [String] = [],
        codecs: [String] = [],
        viewers: [WebRTCOutboundViewerStatistics]
    ) {
        self.slot = slot
        self.trackID = trackID
        self.isActive = isActive
        self.bytesSent = bytesSent
        self.packetsSent = packetsSent
        self.framesSent = framesSent
        self.framesEncoded = framesEncoded
        self.aggregateBitrateBps = aggregateBitrateBps
        self.averageFramesPerSecond = averageFramesPerSecond
        self.aggregateTargetBitrateBps = aggregateTargetBitrateBps
        self.averageEncodeTimeMilliseconds = averageEncodeTimeMilliseconds
        self.averagePacketSendDelayMilliseconds = averagePacketSendDelayMilliseconds
        self.encoderDroppedFrames = encoderDroppedFrames
        self.qualityLimitationReasons = qualityLimitationReasons
        self.codecs = codecs
        self.viewers = viewers
    }
}

public struct WebRTCOutboundStatisticsSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let viewerCount: Int
    public let connectedViewerCount: Int
    public let slots: [WebRTCOutboundSlotStatistics]
    /// Aggregate H.264 inputs rejected by Clip's bounded submission gate
    /// since the previous statistics sample. This is host-wide because one
    /// encoder controller serves all viewer/slot encoder instances.
    public let h264SubmissionBackpressureDrops: UInt64

    public init(
        capturedAt: Date,
        viewerCount: Int,
        connectedViewerCount: Int,
        slots: [WebRTCOutboundSlotStatistics],
        h264SubmissionBackpressureDrops: UInt64 = 0
    ) {
        self.capturedAt = capturedAt
        self.viewerCount = viewerCount
        self.connectedViewerCount = connectedViewerCount
        self.slots = slots
        self.h264SubmissionBackpressureDrops = h264SubmissionBackpressureDrops
    }

    public subscript(slot slot: Int) -> WebRTCOutboundSlotStatistics? {
        slots.first { $0.slot == slot }
    }
}

public enum WebRTCPeerHostEvent: Sendable {
    case viewerAdded(viewerID: String)
    case viewerRemoved(viewerID: String)
    case localICECandidate(viewerID: String, candidate: WebRTCICECandidate)
    case connectionStateChanged(viewerID: String, state: WebRTCPeerConnectionState)
    case controlDataChannelStateChanged(viewerID: String, state: WebRTCControlDataChannelState)
    case controlDataChannelDrained(viewerID: String)
    case controlMessageReceived(viewerID: String, data: Data, isBinary: Bool)
    case negotiationNeeded(viewerID: String)
    case videoCodecChanged(codec: WebRTCVideoCodec)
    case error(viewerID: String?, error: WebRTCPeerHostError)
}

public struct WebRTCControlDeliveryResult: Equatable, Sendable {
    public let deliveredViewerIDs: [String]
    public let unavailableViewerIDs: [String]

    public init(deliveredViewerIDs: [String], unavailableViewerIDs: [String]) {
        self.deliveredViewerIDs = deliveredViewerIDs
        self.unavailableViewerIDs = unavailableViewerIDs
    }
}

/// Serializes the asynchronous SDP callbacks associated with one peer.
///
/// libwebrtc completes offer and description operations asynchronously. A
/// viewer can disappear and be recreated with the same signaling identifier
/// while one of those callbacks is still queued, so checking the viewer ID is
/// not sufficient. The host keeps one of these ledgers on the identity-bearing
/// `PeerContext` and validates every callback against the token it began with.
struct WebRTCPeerOperationGeneration: Equatable, Sendable {
    struct LocalDescriptionToken: Equatable, Sendable {
        fileprivate let negotiation: UInt64
    }

    struct RemoteDescriptionToken: Equatable, Sendable {
        fileprivate let negotiation: UInt64
        fileprivate let application: UInt64
    }

    private var negotiation: UInt64 = 0
    private var remoteApplication: UInt64 = 0
    private var localDescriptionsInFlight: Set<UInt64> = []

    var hasLocalDescriptionInFlight: Bool {
        !localDescriptionsInFlight.isEmpty
    }

    mutating func beginLocalDescription() -> LocalDescriptionToken {
        negotiation &+= 1
        remoteApplication = 0
        localDescriptionsInFlight.insert(negotiation)
        return LocalDescriptionToken(negotiation: negotiation)
    }

    mutating func finishLocalDescription(_ token: LocalDescriptionToken) {
        localDescriptionsInFlight.remove(token.negotiation)
    }

    /// Invalidates every asynchronous offer callback before applying an SDP
    /// rollback. Those callbacks may still arrive, but no longer keep the peer
    /// marked busy or match the current negotiation generation.
    mutating func invalidateLocalDescriptions() {
        negotiation &+= 1
        remoteApplication = 0
        localDescriptionsInFlight.removeAll(keepingCapacity: true)
    }

    mutating func beginRemoteDescription() -> RemoteDescriptionToken {
        remoteApplication &+= 1
        return RemoteDescriptionToken(
            negotiation: negotiation,
            application: remoteApplication
        )
    }

    func contains(_ token: LocalDescriptionToken) -> Bool {
        token.negotiation == negotiation
    }

    func contains(_ token: RemoteDescriptionToken) -> Bool {
        token.negotiation == negotiation
            && token.application == remoteApplication
    }
}

public enum WebRTCPeerHostError: Error, Equatable, LocalizedError, Sendable {
    case sslInitializationFailed
    case hostClosed
    case emptyViewerID
    case invalidViewerID(maximumBytes: Int)
    case duplicateViewer(String)
    case viewerCapacityReached(maximum: Int)
    case viewerNotFound(String)
    case negotiationTimedOut(viewerID: String)
    case peerConnectionCreationFailed(String)
    case dataChannelCreationFailed(String)
    case trackCreationFailed(slot: Int)
    case h264Unavailable
    case h264PreferenceFailed(slot: Int, message: String)
    case videoCodecUnavailable(WebRTCVideoCodec)
    case videoCodecPreferenceFailed(
        codec: WebRTCVideoCodec,
        viewerID: String,
        slot: Int,
        message: String
    )
    case videoCodecSwitchInProgress(from: WebRTCVideoCodec, to: WebRTCVideoCodec)
    case videoCodecSwitchFailed(from: WebRTCVideoCodec, to: WebRTCVideoCodec, message: String)
    case localDescriptionCreationFailed(String)
    case localDescriptionApplicationFailed(String)
    case remoteDescriptionApplicationFailed(String)
    case sessionDescriptionPayloadTooLarge(maximumBytes: Int)
    case iceCandidateApplicationFailed(String)
    case invalidICECandidate(String)
    case iceCandidateLimitReached(viewerID: String, maximum: Int)
    case iceGatheringFailed(code: Int, url: String, message: String)
    case invalidSlot(Int)
    case slotTrackMismatch(slot: Int, expected: String, actual: String)
    case slotAlreadyActive(Int)
    case slotInactive(Int)
    case noAvailableSlot
    case controlMessageEncodingFailed(String)
    case stalePeerOperation(String)

    public var errorDescription: String? {
        switch self {
        case .sslInitializationFailed:
            "WebRTC could not initialize its SSL runtime."
        case .hostClosed:
            "The WebRTC peer host is closed."
        case .emptyViewerID:
            "The viewer identifier cannot be empty."
        case .invalidViewerID(let maximumBytes):
            "The viewer identifier exceeds the \(maximumBytes)-byte limit or contains control characters."
        case .duplicateViewer(let id):
            "A peer already exists for viewer \(id)."
        case .viewerCapacityReached(let maximum):
            "The room already has its maximum of \(maximum) viewers."
        case .viewerNotFound(let id):
            "No peer exists for viewer \(id)."
        case .negotiationTimedOut(let viewerID):
            "Viewer \(viewerID) did not answer the WebRTC offer in time."
        case .peerConnectionCreationFailed(let message):
            "The peer connection could not be created: \(message)"
        case .dataChannelCreationFailed(let message):
            "The control data channel could not be created: \(message)"
        case .trackCreationFailed(let slot):
            "The video track for slot \(slot) could not be created."
        case .h264Unavailable:
            "The WebRTC runtime does not expose an H.264 sender codec."
        case .h264PreferenceFailed(let slot, let message):
            "H.264 could not be selected for slot \(slot): \(message)"
        case .videoCodecUnavailable(let codec):
            "The WebRTC encoder does not support \(codec.rtcName)."
        case .videoCodecPreferenceFailed(let codec, let viewerID, let slot, let message):
            "The \(codec.rtcName) preference for viewer \(viewerID), video slot \(slot) could not be applied: \(message)"
        case .videoCodecSwitchInProgress(let from, let to):
            "A WebRTC codec change from \(from.rtcName) to \(to.rtcName) is already in progress."
        case .videoCodecSwitchFailed(let from, let to, let message):
            "The WebRTC codec change from \(from.rtcName) to \(to.rtcName) failed: \(message)"
        case .localDescriptionCreationFailed(let message):
            "The local session description could not be created: \(message)"
        case .localDescriptionApplicationFailed(let message):
            "The local session description could not be applied: \(message)"
        case .remoteDescriptionApplicationFailed(let message):
            "The remote session description could not be applied: \(message)"
        case .sessionDescriptionPayloadTooLarge(let maximumBytes):
            "The remote session description exceeds the \(maximumBytes)-byte limit."
        case .iceCandidateApplicationFailed(let message):
            "The remote ICE candidate could not be applied: \(message)"
        case .invalidICECandidate(let message):
            "The remote ICE candidate was rejected: \(message)"
        case .iceCandidateLimitReached(let viewerID, let maximum):
            "Viewer \(viewerID) exceeded the limit of \(maximum) ICE candidates."
        case .iceGatheringFailed(let code, let url, let message):
            "ICE gathering failed for \(url) (\(code)): \(message)"
        case .invalidSlot(let slot):
            "Video slot \(slot) is outside the supported range."
        case .slotTrackMismatch(let slot, let expected, let actual):
            "Video slot \(slot) requires track ID \(expected), not \(actual)."
        case .slotAlreadyActive(let slot):
            "Video slot \(slot) is already active."
        case .slotInactive(let slot):
            "Video slot \(slot) is not active."
        case .noAvailableSlot:
            "All four video slots are already active."
        case .controlMessageEncodingFailed(let message):
            "The control message could not be encoded: \(message)"
        case .stalePeerOperation(let viewerID):
            "A superseded WebRTC operation completed for viewer \(viewerID)."
        }
    }
}
