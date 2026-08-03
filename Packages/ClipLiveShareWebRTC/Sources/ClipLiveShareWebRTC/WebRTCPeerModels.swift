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

/// SDP codec advertisement policy for one participant edge.
///
/// This changes negotiation only. A peer connection still selects exactly one
/// codec for each RTP stream, so the Native compatibility ladder does not
/// create a second encoder. Web edges deliberately advertise only the selected
/// codec: an incompatible browser gets unavailable video instead of
/// transcoding.
public enum WebRTCVideoCodecNegotiationPolicy: Equatable, Sendable {
    case nativeCompatible
    case exact
}

/// Clip's codec-specific controls for its native VideoToolbox H.264 encoder.
public struct WebRTCH264AdvancedConfiguration: Equatable, Sendable {
    public var maximumQuantizer: Int?
    public var qualityFraction: Double
    public var keyFrameIntervalSeconds: Int

    public init(
        maximumQuantizer: Int? = nil,
        qualityFraction: Double = 0.98,
        keyFrameIntervalSeconds: Int = 2
    ) {
        self.maximumQuantizer = maximumQuantizer.map { min(51, max(0, $0)) }
        self.qualityFraction = min(1, max(0, qualityFraction))
        self.keyFrameIntervalSeconds = max(1, keyFrameIntervalSeconds)
    }

    public static let clipDefault = Self()
}

/// Initial advanced state for Clip's configurable VideoToolbox encoder.
/// Sender-level controls for every codec live in `WebRTCSenderPolicy`.
public struct WebRTCAdvancedVideoConfigurations: Equatable, Sendable {
    public var h264: WebRTCH264AdvancedConfiguration

    public init(
        h264: WebRTCH264AdvancedConfiguration = .clipDefault
    ) {
        self.h264 = h264
    }

    public static let clipDefault = Self()
}

/// A type-safe live encoder update. Associating the codec with its payload
/// prevents H.264-only fields from accidentally being sent to another codec.
public enum WebRTCCodecAdvancedConfiguration: Equatable, Sendable {
    case h264(WebRTCH264AdvancedConfiguration)

    public var codec: WebRTCVideoCodec {
        switch self {
        case .h264: .h264
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

public enum WebRTCSenderDegradationStrategy: String, CaseIterable, Codable,
    Equatable, Sendable
{
    /// Prefer dropping frames over reducing the captured pixel dimensions.
    case resolution
    /// Let libwebrtc trade frame rate and resolution together.
    case balanced
    /// Prefer reducing resolution while retaining the requested cadence.
    case framerate
    /// Disable libwebrtc's frame-rate and resolution adaptation.
    case disabled
}

public struct WebRTCSenderPolicy: Equatable, Sendable {
    public var maximumBitrateBps: Int?
    public var minimumBitrateBps: Int?
    public var maximumFramesPerSecond: Int?
    public var degradationStrategy: WebRTCSenderDegradationStrategy
    public var temporalLayerCount: Int?
    public var resolutionScale: Double?
    public var bitratePriority: Double

    public init(
        maximumBitrateBps: Int? = 12_000_000,
        minimumBitrateBps: Int? = nil,
        maximumFramesPerSecond: Int? = 30,
        degradationStrategy: WebRTCSenderDegradationStrategy = .resolution,
        temporalLayerCount: Int? = nil,
        resolutionScale: Double? = 1,
        bitratePriority: Double = 1
    ) {
        self.maximumBitrateBps = maximumBitrateBps
        self.minimumBitrateBps = minimumBitrateBps
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.degradationStrategy = degradationStrategy
        self.temporalLayerCount = temporalLayerCount
        self.resolutionScale = resolutionScale
        self.bitratePriority = bitratePriority
    }

    public static let clipDefault = Self()
}

/// Resource limits applied to each native-v3 participant peer connection.
/// Admission is decided before allocating the fixed media transceivers.
public struct WebRTCPeerResourceLimits: Equatable, Sendable {
    public var maximumParticipantPeerCount: Int
    public var negotiationTimeout: TimeInterval
    public var maximumICECandidatesPerPeer: Int
    public var maximumICECandidatePayloadBytes: Int
    public var maximumParticipantIDBytes: Int
    public var maximumSDPPayloadBytes: Int
    public var maximumVideoTracks: Int
    public var maximumControlMessagePayloadBytes: Int
    public var maximumControlBufferedAmountBytes: Int

    public init(
        maximumParticipantPeerCount: Int = 8,
        negotiationTimeout: TimeInterval = 15,
        maximumICECandidatesPerPeer: Int = 256,
        maximumICECandidatePayloadBytes: Int = 4_096,
        maximumParticipantIDBytes: Int = 128,
        maximumSDPPayloadBytes: Int = 262_144,
        maximumVideoTracks: Int = WebRTCRuntimeIdentity.maximumVideoSlots,
        maximumControlMessagePayloadBytes: Int = 196_400,
        maximumControlBufferedAmountBytes: Int = 262_144
    ) {
        self.maximumParticipantPeerCount = maximumParticipantPeerCount
        self.negotiationTimeout = negotiationTimeout
        self.maximumICECandidatesPerPeer = maximumICECandidatesPerPeer
        self.maximumICECandidatePayloadBytes = maximumICECandidatePayloadBytes
        self.maximumParticipantIDBytes = maximumParticipantIDBytes
        self.maximumSDPPayloadBytes = maximumSDPPayloadBytes
        self.maximumVideoTracks = maximumVideoTracks
        self.maximumControlMessagePayloadBytes = maximumControlMessagePayloadBytes
        self.maximumControlBufferedAmountBytes = maximumControlBufferedAmountBytes
    }

    public static let clipDefault = Self()

    public var normalized: Self {
        let finiteAnswerTimeout = negotiationTimeout.isFinite ? negotiationTimeout : 15
        let normalizedControlMessagePayloadBytes = min(
            196_400,
            max(1_024, maximumControlMessagePayloadBytes)
        )
        return Self(
            maximumParticipantPeerCount: min(32, max(1, maximumParticipantPeerCount)),
            negotiationTimeout: min(120, max(0.01, finiteAnswerTimeout)),
            maximumICECandidatesPerPeer: min(
                1_024,
                max(1, maximumICECandidatesPerPeer)
            ),
            maximumICECandidatePayloadBytes: min(
                16_384,
                max(256, maximumICECandidatePayloadBytes)
            ),
            maximumParticipantIDBytes: min(512, max(16, maximumParticipantIDBytes)),
            maximumSDPPayloadBytes: min(
                1_048_576,
                max(4_096, maximumSDPPayloadBytes)
            ),
            maximumVideoTracks: min(
                WebRTCRuntimeIdentity.maximumVideoSlots,
                max(1, maximumVideoTracks)
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

public struct WebRTCPeerConfiguration: Equatable, Sendable {
    public var iceServers: [WebRTCICEServerConfiguration]
    public var forcesRelay: Bool
    public var senderPolicy: WebRTCSenderPolicy
    public var resourceLimits: WebRTCPeerResourceLimits
    public var videoCodec: WebRTCVideoCodec
    public var videoEncodingMode: LiveShareEncodingMode
    public var advancedVideoConfigurations: WebRTCAdvancedVideoConfigurations

    public init(
        iceServers: [WebRTCICEServerConfiguration],
        forcesRelay: Bool = false,
        senderPolicy: WebRTCSenderPolicy = .clipDefault,
        resourceLimits: WebRTCPeerResourceLimits = .clipDefault,
        videoCodec: WebRTCVideoCodec = .h264,
        videoEncodingMode: LiveShareEncodingMode = .quality,
        advancedVideoConfigurations: WebRTCAdvancedVideoConfigurations = .clipDefault
    ) {
        self.iceServers = iceServers
        self.forcesRelay = forcesRelay
        self.senderPolicy = senderPolicy
        self.resourceLimits = resourceLimits
        self.videoCodec = videoCodec
        self.videoEncodingMode = videoEncodingMode
        self.advancedVideoConfigurations = advancedVideoConfigurations
    }

    public static let clipDefault = Self(iceServers: [
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
            guard
                let media = line.dropFirst(2).split(
                    whereSeparator: \.isWhitespace
                ).first?.lowercased()
            else {
                throw
                    ClipLiveShareNativeV3WebRTCPeerLinkError
                    .invalidSessionDescriptionKind
            }
            switch media {
            case "video":
                videoCount += 1
            case "audio":
                audioCount += 1
            case "application":
                applicationCount += 1
            default:
                throw
                    ClipLiveShareNativeV3WebRTCPeerLinkError
                    .invalidSessionDescriptionKind
            }
            guard
                videoCount <= limits.maximumVideoTracks,
                audioCount <= 1,
                applicationCount <= 1
            else {
                throw
                    ClipLiveShareNativeV3WebRTCPeerLinkError
                    .invalidSessionDescriptionKind
            }
        }
    }
}

/// A transport-neutral ICE candidate suitable for Clip's encrypted signaling
/// and peer-to-peer control messages.
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
    /// fields remain accepted because ICE implementations may add them.
    func validate(resourceLimits: WebRTCPeerResourceLimits = .clipDefault) throws {
        let limits = resourceLimits.normalized
        guard candidate.utf8.count <= limits.maximumICECandidatePayloadBytes else {
            throw WebRTCICECandidateValidationError.payloadTooLarge(
                maximumBytes: limits.maximumICECandidatePayloadBytes
            )
        }
        // Four video m-lines, system audio, and the reliable data-channel
        // m-line are the only negotiated sections in Clip's offer.
        guard (0 ... Int32(WebRTCRuntimeIdentity.maximumMediaLineIndex))
            .contains(sdpMLineIndex) else {
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
    public let metadata: ClipLiveShareStreamDescriptor?
    public let captureGeometry: WebRTCVideoCaptureGeometry?

    public var id: Int { index }
    public var isActive: Bool { metadata != nil }

    init(
        index: Int,
        trackID: String,
        streamID: String,
        metadata: ClipLiveShareStreamDescriptor?,
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
