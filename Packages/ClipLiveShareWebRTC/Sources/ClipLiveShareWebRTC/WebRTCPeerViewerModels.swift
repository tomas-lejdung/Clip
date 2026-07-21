import ClipLiveShare
import Foundation
@preconcurrency import WebRTC

public struct WebRTCPeerViewerConfiguration: Equatable, Sendable {
    public var iceServers: [WebRTCICEServerConfiguration]
    public var forcesRelay: Bool
    public var resourceLimits: WebRTCPeerResourceLimits
    public var systemAudioPlaybackEnabled: Bool
    public var systemAudioVolume: Double

    public init(
        iceServers: [WebRTCICEServerConfiguration],
        forcesRelay: Bool = false,
        resourceLimits: WebRTCPeerResourceLimits = .clipDefault,
        systemAudioPlaybackEnabled: Bool = true,
        systemAudioVolume: Double = 1
    ) {
        self.iceServers = iceServers
        self.forcesRelay = forcesRelay
        self.resourceLimits = resourceLimits
        self.systemAudioPlaybackEnabled = systemAudioPlaybackEnabled
        self.systemAudioVolume = min(max(systemAudioVolume, 0), 1)
    }

    public static let clipDefault = Self(iceServers: [
        .init(urlStrings: ["stun:stun.l.google.com:19302"]),
        .init(urlStrings: ["stun:stun1.l.google.com:19302"]),
        .init(urlStrings: ["stun:stun2.l.google.com:19302"]),
    ])
}

/// A logical Clip stream paired with its private native WebRTC receive track.
/// App targets render this through `WebRTCRemoteVideoView` and never need to
/// import the WebRTC framework themselves.
public struct WebRTCRemoteVideoStream: Identifiable, @unchecked Sendable {
    public let descriptor: ClipLiveShareStreamDescriptor
    let track: WebRTCRemoteVideoTrackHandle

    public var id: ClipLiveShareStreamID { descriptor.id }
    public var mediaTrackID: ClipLiveShareMediaTrackID { descriptor.mediaTrackID }

    init(
        descriptor: ClipLiveShareStreamDescriptor,
        track: WebRTCRemoteVideoTrackHandle
    ) {
        self.descriptor = descriptor
        self.track = track
    }
}

public enum WebRTCPeerViewerEvent: @unchecked Sendable {
    case localICECandidate(WebRTCICECandidate)
    case connectionStateChanged(WebRTCPeerConnectionState)
    case controlDataChannelStateChanged(WebRTCControlDataChannelState)
    case controlDataChannelDrained
    case controlMessageReceived(data: Data, isBinary: Bool)
    case negotiationNeeded
    case remoteVideoStreamAdded(WebRTCRemoteVideoStream)
    case remoteVideoStreamUpdated(WebRTCRemoteVideoStream)
    case remoteVideoStreamRemoved(streamID: ClipLiveShareStreamID)
    case systemAudioTrackAvailable(trackID: String)
    case systemAudioTrackRemoved(trackID: String)
    case error(WebRTCPeerViewerError)
}

public struct WebRTCPeerViewerSnapshot: Equatable, Sendable {
    public let connectionState: WebRTCPeerConnectionState
    public let controlDataChannelState: WebRTCControlDataChannelState
    public let route: WebRTCConnectionRoute
    public let negotiatedVideoTrackIDs: [String]
    public let boundStreams: [ClipLiveShareStreamDescriptor]
    public let systemAudioTrackID: String?
    public let isSystemAudioPlaybackEnabled: Bool
    public let systemAudioVolume: Double
    public let isClosed: Bool

    public init(
        connectionState: WebRTCPeerConnectionState,
        controlDataChannelState: WebRTCControlDataChannelState,
        route: WebRTCConnectionRoute,
        negotiatedVideoTrackIDs: [String],
        boundStreams: [ClipLiveShareStreamDescriptor],
        systemAudioTrackID: String?,
        isSystemAudioPlaybackEnabled: Bool,
        systemAudioVolume: Double,
        isClosed: Bool
    ) {
        self.connectionState = connectionState
        self.controlDataChannelState = controlDataChannelState
        self.route = route
        self.negotiatedVideoTrackIDs = negotiatedVideoTrackIDs
        self.boundStreams = boundStreams
        self.systemAudioTrackID = systemAudioTrackID
        self.isSystemAudioPlaybackEnabled = isSystemAudioPlaybackEnabled
        self.systemAudioVolume = min(max(systemAudioVolume, 0), 1)
        self.isClosed = isClosed
    }
}

public struct WebRTCInboundTrackStatistics: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case video
        case audio
        case unknown
    }

    public let id: String
    public let kind: Kind
    public let bytesReceived: UInt64
    public let packetsReceived: UInt64
    public let packetsLost: Int64
    public let framesDecoded: UInt64?
    public let framesDropped: UInt64?
    public let framesPerSecond: Double?
    public let jitterSeconds: Double?
    public let codec: String?

    public init(
        id: String,
        kind: Kind,
        bytesReceived: UInt64,
        packetsReceived: UInt64,
        packetsLost: Int64,
        framesDecoded: UInt64?,
        framesDropped: UInt64?,
        framesPerSecond: Double?,
        jitterSeconds: Double?,
        codec: String?
    ) {
        self.id = id
        self.kind = kind
        self.bytesReceived = bytesReceived
        self.packetsReceived = packetsReceived
        self.packetsLost = packetsLost
        self.framesDecoded = framesDecoded
        self.framesDropped = framesDropped
        self.framesPerSecond = framesPerSecond
        self.jitterSeconds = jitterSeconds
        self.codec = codec
    }
}

public struct WebRTCInboundStatisticsSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let route: WebRTCConnectionRoute
    public let tracks: [WebRTCInboundTrackStatistics]

    public init(
        capturedAt: Date,
        route: WebRTCConnectionRoute,
        tracks: [WebRTCInboundTrackStatistics]
    ) {
        self.capturedAt = capturedAt
        self.route = route
        self.tracks = tracks
    }
}

public enum WebRTCPeerViewerError: Error, Equatable, LocalizedError, Sendable {
    case sslInitializationFailed
    case viewerClosed
    case peerConnectionCreationFailed(String)
    case expectedOffer
    case negotiationInProgress
    case sessionDescriptionPayloadTooLarge(maximumBytes: Int)
    case invalidOfferMediaSections(maximumVideoTracks: Int)
    case remoteDescriptionApplicationFailed(String)
    case localDescriptionCreationFailed(String)
    case localDescriptionApplicationFailed(String)
    case invalidICECandidate(String)
    case iceCandidateLimitReached(maximum: Int)
    case iceCandidateApplicationFailed(String)
    case iceGatheringFailed(code: Int, url: String, message: String)
    case unexpectedDataChannel(String)
    case controlMessagePayloadTooLarge(maximumBytes: Int)
    case duplicateSystemAudioTrack
    case videoTrackLimitReached(maximum: Int)
    case missingVideoTrack(String)

    public var errorDescription: String? {
        switch self {
        case .sslInitializationFailed:
            "WebRTC could not initialize its SSL runtime."
        case .viewerClosed:
            "The WebRTC viewer is closed."
        case .peerConnectionCreationFailed(let message):
            "The viewer peer connection could not be created: \(message)"
        case .expectedOffer:
            "The viewer expected a WebRTC offer."
        case .negotiationInProgress:
            "The viewer is already applying another WebRTC offer."
        case .sessionDescriptionPayloadTooLarge(let maximumBytes):
            "The remote description exceeds the \(maximumBytes)-byte limit."
        case .invalidOfferMediaSections(let maximumVideoTracks):
            "The host offer exceeds Clip's media limits (maximum \(maximumVideoTracks) video, one audio, and one control section)."
        case .remoteDescriptionApplicationFailed(let message):
            "The remote description could not be applied: \(message)"
        case .localDescriptionCreationFailed(let message):
            "The WebRTC answer could not be created: \(message)"
        case .localDescriptionApplicationFailed(let message):
            "The WebRTC answer could not be applied: \(message)"
        case .invalidICECandidate(let message):
            "The remote ICE candidate was rejected: \(message)"
        case .iceCandidateLimitReached(let maximum):
            "The host exceeded the limit of \(maximum) ICE candidates."
        case .iceCandidateApplicationFailed(let message):
            "The remote ICE candidate could not be applied: \(message)"
        case let .iceGatheringFailed(code, url, message):
            "ICE gathering failed for \(url) (\(code)): \(message)"
        case .unexpectedDataChannel(let label):
            "The host opened an unexpected data channel named \(label)."
        case .controlMessagePayloadTooLarge(let maximumBytes):
            "The control message exceeds the \(maximumBytes)-byte limit."
        case .duplicateSystemAudioTrack:
            "The host offered more than one system-audio track."
        case .videoTrackLimitReached(let maximum):
            "The host offered more than \(maximum) video tracks."
        case .missingVideoTrack(let trackID):
            "The manifest references unavailable video track \(trackID)."
        }
    }
}

final class WebRTCRemoteVideoTrackHandle: @unchecked Sendable {
    let id: String

    private let lock = NSLock()
    private let track: RTCVideoTrack
    private var isActive = true
    private var renderers: [ObjectIdentifier: any RTCVideoRenderer] = [:]

    init(track: RTCVideoTrack) {
        id = track.trackId
        self.track = track
        track.isEnabled = true
    }

    @discardableResult
    func addRenderer(_ renderer: any RTCVideoRenderer) -> Bool {
        lock.withLock {
            guard isActive else { return false }
            let key = ObjectIdentifier(renderer)
            guard renderers.updateValue(renderer, forKey: key) == nil else { return true }
            track.add(renderer)
            return true
        }
    }

    func removeRenderer(_ renderer: any RTCVideoRenderer) {
        lock.withLock {
            let key = ObjectIdentifier(renderer)
            guard renderers.removeValue(forKey: key) != nil else { return }
            track.remove(renderer)
        }
    }

    func invalidate() {
        lock.withLock {
            guard isActive else { return }
            isActive = false
            for renderer in renderers.values {
                track.remove(renderer)
            }
            renderers.removeAll(keepingCapacity: false)
            track.isEnabled = false
        }
    }
}
