import ClipLiveShare
import Foundation

/// The deterministic role used to break initial offer glare for an unordered
/// native-v3 peer link. Either participant can request later renegotiation;
/// the concrete transport remains responsible for WebRTC perfect-negotiation
/// semantics.
public enum ClipLiveShareNativeV3PeerLinkRole: String, Equatable, Sendable {
  case offerer
  case answerer
}

/// The control-channel contract every native-v3 peer link must create.
///
/// There is deliberately no public initializer. A transport receives the
/// canonical configuration from the mesh manager, preventing a production
/// factory from accidentally creating an unordered or partially reliable
/// channel that is incompatible with membership/source state replication.
public struct ClipLiveShareNativeV3ControlChannelConfiguration: Equatable, Sendable {
  public let label: String
  public let isOrdered: Bool
  public let maximumRetransmits: Int?
  public let maximumPacketLifetimeMilliseconds: Int?

  static let reliableOrdered = Self(
    label: ClipLiveShareNativeV3.controlDataChannelLabel,
    isOrdered: true,
    maximumRetransmits: nil,
    maximumPacketLifetimeMilliseconds: nil
  )

  private init(
    label: String,
    isOrdered: Bool,
    maximumRetransmits: Int?,
    maximumPacketLifetimeMilliseconds: Int?
  ) {
    self.label = label
    self.isOrdered = isOrdered
    self.maximumRetransmits = maximumRetransmits
    self.maximumPacketLifetimeMilliseconds = maximumPacketLifetimeMilliseconds
  }
}

/// Stable media sections reserved in every native-v3 peer connection.
///
/// All four video sections are negotiated up front and are available to each
/// participant. One audio section carries each participant's optional
/// system-audio track. Every section is send-receive: four m-lines therefore
/// provide four outbound and four inbound video slots on the same peer
/// connection, rather than doubling the SDP surface with separate one-way
/// sections.
public struct ClipLiveShareNativeV3PeerMediaLayout: Equatable, Sendable {
  public enum Direction: String, Equatable, Sendable {
    case sendReceive = "send-receive"
  }

  public let reservedVideoSlotCount: Int
  public let participantAudioTrackCount: Int
  public let videoDirection: Direction
  public let participantAudioDirection: Direction

  public var reservedOutboundVideoSlotCount: Int { reservedVideoSlotCount }
  public var reservedInboundVideoSlotCount: Int { reservedVideoSlotCount }
  public var outboundParticipantAudioTrackCount: Int {
    participantAudioTrackCount
  }
  public var inboundParticipantAudioTrackCount: Int {
    participantAudioTrackCount
  }

  public static let standard = Self(
    reservedVideoSlotCount: ClipLiveShareNativeV3.reservedVideoSlotsPerParticipant,
    participantAudioTrackCount: 1,
    videoDirection: .sendReceive,
    participantAudioDirection: .sendReceive
  )

  private init(
    reservedVideoSlotCount: Int,
    participantAudioTrackCount: Int,
    videoDirection: Direction,
    participantAudioDirection: Direction
  ) {
    self.reservedVideoSlotCount = reservedVideoSlotCount
    self.participantAudioTrackCount = participantAudioTrackCount
    self.videoDirection = videoDirection
    self.participantAudioDirection = participantAudioDirection
  }
}

/// Immutable construction input for one concrete WebRTC peer connection.
public struct ClipLiveShareNativeV3PeerLinkConfiguration: Equatable, Sendable {
  public let key: ClipLiveShareNativeV3PeerLinkKey
  public let localParticipantID: ClipLiveShareNativeV3ParticipantID
  public let remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  public let role: ClipLiveShareNativeV3PeerLinkRole
  public let controlChannel: ClipLiveShareNativeV3ControlChannelConfiguration
  public let mediaLayout: ClipLiveShareNativeV3PeerMediaLayout
  /// False while a server-room pair is still quarantined behind admission.
  /// SDP/ICE and the reliable control channel may be established, but local
  /// audio/video cannot leave until the authoritative roster admits the peer.
  public let outboundMediaInitiallyEnabled: Bool
  /// Native peers preserve Clip's established codec preference ladder. A
  /// receive-only Web peer instead receives an exact one-codec contract so
  /// Clip never creates a fallback encoding.
  public let videoCodecNegotiationPolicy: WebRTCVideoCodecNegotiationPolicy

  init(
    key: ClipLiveShareNativeV3PeerLinkKey,
    localParticipantID: ClipLiveShareNativeV3ParticipantID,
    outboundMediaInitiallyEnabled: Bool = true,
    videoCodecNegotiationPolicy: WebRTCVideoCodecNegotiationPolicy =
      .nativeCompatible
  ) throws {
    guard
      let remoteParticipantID = key.otherParticipant(than: localParticipantID)
    else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.invalidPeerLink(key)
    }
    self.key = key
    self.localParticipantID = localParticipantID
    self.remoteParticipantID = remoteParticipantID
    role = localParticipantID == key.lowerParticipantID ? .offerer : .answerer
    controlChannel = .reliableOrdered
    mediaLayout = .standard
    self.outboundMediaInitiallyEnabled = outboundMediaInitiallyEnabled
    self.videoCodecNegotiationPolicy = videoCodecNegotiationPolicy
  }
}

/// Transport-neutral negotiation data. The app's authenticated native-v3 wire
/// layer will wrap this value in a pair-scoped signed/encrypted envelope.
public enum ClipLiveShareNativeV3PeerNegotiationPayload: Equatable, Sendable {
  case sessionDescription(WebRTCSessionDescription)
  case iceCandidate(WebRTCICECandidate)
}

/// A local negotiation value with an explicit destination. This prevents a
/// busy A-B negotiation from being accidentally relayed to A-C.
public struct ClipLiveShareNativeV3TargetedNegotiation: Equatable, Sendable {
  public let peerLinkKey: ClipLiveShareNativeV3PeerLinkKey
  public let targetParticipantID: ClipLiveShareNativeV3ParticipantID
  public let payload: ClipLiveShareNativeV3PeerNegotiationPayload

  public init(
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    targetParticipantID: ClipLiveShareNativeV3ParticipantID,
    payload: ClipLiveShareNativeV3PeerNegotiationPayload
  ) {
    self.peerLinkKey = peerLinkKey
    self.targetParticipantID = targetParticipantID
    self.payload = payload
  }
}

public enum ClipLiveShareNativeV3MediaStatisticsDirection:
  String, Equatable, Hashable, Sendable
{
  case outgoing
  case incoming
}

/// One video track's cumulative RTP and processing statistics on one exact
/// participant pair. Bitrate is deliberately not stored here: callers derive
/// it from byte deltas between samples with matching peer, direction, and
/// track identifiers.
public struct ClipLiveShareNativeV3VideoSourceStatistics:
  Equatable, Hashable, Sendable
{
  public let direction: ClipLiveShareNativeV3MediaStatisticsDirection
  public let trackIdentifier: String
  public let codec: String?
  public let width: Int
  public let height: Int
  public let framesPerSecond: Double
  public let bytes: UInt64
  public let frames: UInt64
  public let droppedFrames: UInt64
  public let queuePressureDrops: UInt64
  public let packets: UInt64
  public let packetsLost: Int64
  /// Average encoder time for outgoing video, or jitter-buffer delay for
  /// incoming video. This is not presented as end-to-end latency.
  public let processingLatencyMilliseconds: Double?
  /// WebRTC's current sender limitation, such as `bandwidth` or `cpu`.
  public let queuePressureReason: String?

  public init(
    direction: ClipLiveShareNativeV3MediaStatisticsDirection,
    trackIdentifier: String,
    codec: String? = nil,
    width: Int = 0,
    height: Int = 0,
    framesPerSecond: Double = 0,
    bytes: UInt64 = 0,
    frames: UInt64 = 0,
    droppedFrames: UInt64 = 0,
    queuePressureDrops: UInt64 = 0,
    packets: UInt64 = 0,
    packetsLost: Int64 = 0,
    processingLatencyMilliseconds: Double? = nil,
    queuePressureReason: String? = nil
  ) {
    self.direction = direction
    self.trackIdentifier = String(trackIdentifier.prefix(512))
    self.codec = codec.map { String($0.prefix(64)) }
    self.width = max(0, width)
    self.height = max(0, height)
    self.framesPerSecond =
      framesPerSecond.isFinite ? max(0, framesPerSecond) : 0
    self.bytes = bytes
    self.frames = frames
    self.droppedFrames = droppedFrames
    self.queuePressureDrops = queuePressureDrops
    self.packets = packets
    self.packetsLost = max(0, packetsLost)
    self.processingLatencyMilliseconds =
      processingLatencyMilliseconds.flatMap {
        $0.isFinite ? max(0, $0) : nil
      }
    let normalizedReason = queuePressureReason?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    self.queuePressureReason =
      normalizedReason.flatMap {
        $0.isEmpty || $0.caseInsensitiveCompare("none") == .orderedSame
          ? nil
          : String($0.prefix(64))
      }
  }
}

/// Cumulative transport counters for one local-to-remote peer connection.
/// Concrete WebRTC integration populates these from one RTC statistics report
/// without aggregating participants together.
public struct ClipLiveShareNativeV3PeerLinkTransportStatistics: Equatable, Sendable {
  public let capturedAt: Date
  public let route: WebRTCConnectionRoute
  public let currentRoundTripTimeMilliseconds: Double?
  public let availableOutgoingBitrateBps: Double?
  public let bytesSent: UInt64
  public let bytesReceived: UInt64
  public let packetsSent: UInt64
  public let packetsReceived: UInt64
  public let packetsLost: Int64
  public let videoSources: [ClipLiveShareNativeV3VideoSourceStatistics]

  public init(
    capturedAt: Date,
    route: WebRTCConnectionRoute = .unknown,
    currentRoundTripTimeMilliseconds: Double? = nil,
    availableOutgoingBitrateBps: Double? = nil,
    bytesSent: UInt64 = 0,
    bytesReceived: UInt64 = 0,
    packetsSent: UInt64 = 0,
    packetsReceived: UInt64 = 0,
    packetsLost: Int64 = 0,
    videoSources: [ClipLiveShareNativeV3VideoSourceStatistics] = []
  ) {
    self.capturedAt = capturedAt
    self.route = route
    self.currentRoundTripTimeMilliseconds =
      currentRoundTripTimeMilliseconds.map { max(0, $0) }
    self.availableOutgoingBitrateBps =
      availableOutgoingBitrateBps.map { max(0, $0) }
    self.bytesSent = bytesSent
    self.bytesReceived = bytesReceived
    self.packetsSent = packetsSent
    self.packetsReceived = packetsReceived
    self.packetsLost = packetsLost
    var seen: Set<String> = []
    var counts: [ClipLiveShareNativeV3MediaStatisticsDirection: Int] = [:]
    self.videoSources = videoSources.filter { source in
      guard !source.trackIdentifier.isEmpty else { return false }
      let key = "\(source.direction.rawValue):\(source.trackIdentifier)"
      guard seen.insert(key).inserted else { return false }
      let count = counts[source.direction, default: 0]
      guard count < ClipLiveShareNativeV3.reservedVideoSlotsPerParticipant else {
        return false
      }
      counts[source.direction] = count + 1
      return true
    }
  }
}

/// Events produced by a single injected peer-connection transport.
public enum ClipLiveShareNativeV3PeerLinkTransportEvent: Equatable, Sendable {
  case localNegotiation(ClipLiveShareNativeV3PeerNegotiationPayload)
  case negotiationNeeded
  case connectionStateChanged(WebRTCPeerConnectionState)
  case controlChannelStateChanged(WebRTCControlDataChannelState)
  case controlMessageReceived(Data)
  case remoteVideoTrackAdded(ClipLiveShareMediaTrackID)
  case remoteVideoTrackRemoved(ClipLiveShareMediaTrackID)
  case remoteParticipantAudioAvailable(trackID: String)
  case remoteParticipantAudioRemoved(trackID: String)
  case routeChanged(WebRTCConnectionRoute)
  case statisticsChanged(ClipLiveShareNativeV3PeerLinkTransportStatistics)
  /// One ICE-server candidate failed to gather. This is diagnostic only: a
  /// peer can remain fully connected through host, peer-reflexive or another
  /// relay candidate, so only the authoritative connection-state callback may
  /// start recovery or quarantine this participant.
  case iceGatheringDiagnostic(code: Int, url: String, message: String)
  case failed(String)
}

/// One concrete WebRTC peer connection hidden behind a deterministic,
/// network-free test seam.
public protocol ClipLiveShareNativeV3PeerLinkTransport: Sendable {
  func events() async -> AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent>
  func start() async throws
  func requestNegotiation() async throws
  func applyRemoteDescription(_ description: WebRTCSessionDescription) async throws
  func addRemoteICECandidate(_ candidate: WebRTCICECandidate) async throws
  func sendControlMessage(_ data: Data) async throws
  /// Best-effort delivery for replaceable high-frequency state such as a
  /// cursor sample. Backpressure or link loss drops this sample immediately;
  /// callers must never queue it behind durable room state.
  func sendEphemeralControlMessage(_ data: Data) async -> Bool
  func remoteVideoStream(
    for descriptor: ClipLiveShareStreamDescriptor
  ) async -> WebRTCRemoteVideoStream?
  func setOutboundMediaEnabled(_ enabled: Bool) async
  func updateSenderPolicy(_ policy: WebRTCSenderPolicy) async
  func updateSenderPolicies(
    _ policiesBySlot: [Int: WebRTCSenderPolicy],
    fallback: WebRTCSenderPolicy,
    videoEncodingMode: LiveShareEncodingMode
  ) async
  func updateVideoCodecPreference(_ codec: WebRTCVideoCodec) async throws
  func restoreVideoCodecPreference(_ codec: WebRTCVideoCodec) async throws
  func currentVideoCodecPreference() async -> WebRTCVideoCodec?
  func rollbackLocalOfferIfNeeded() async throws
  func setRemoteParticipantAudioPlaybackEnabled(_ enabled: Bool) async
  func setRemoteParticipantAudioVolume(_ volume: Double) async
  func restartICE() async throws
  func statistics() async throws -> ClipLiveShareNativeV3PeerLinkTransportStatistics
  func close() async
}

public extension ClipLiveShareNativeV3PeerLinkTransport {
  /// Test transports and non-media implementations have no outbound RTP
  /// senders. The production WebRTC transport overrides this and gates every
  /// video sender plus the participant-audio sender independently per peer.
  func setOutboundMediaEnabled(_ enabled: Bool) async {
    _ = enabled
  }

  func updateSenderPolicy(_ policy: WebRTCSenderPolicy) async {
    _ = policy
  }

  func updateSenderPolicies(
    _ policiesBySlot: [Int: WebRTCSenderPolicy],
    fallback: WebRTCSenderPolicy,
    videoEncodingMode: LiveShareEncodingMode
  ) async {
    _ = policiesBySlot
    _ = videoEncodingMode
    await updateSenderPolicy(fallback)
  }

  func updateVideoCodecPreference(_ codec: WebRTCVideoCodec) async throws {
    _ = codec
  }

  /// Restores the previously selected codec after a failed exchange without
  /// scheduling another exchange. Production transport overrides this because
  /// it tracks explicit codec negotiation independently from SDP signaling.
  func restoreVideoCodecPreference(_ codec: WebRTCVideoCodec) async throws {
    try await updateVideoCodecPreference(codec)
  }

  func currentVideoCodecPreference() async -> WebRTCVideoCodec? { nil }

  func sendEphemeralControlMessage(_ data: Data) async -> Bool {
    do {
      try await sendControlMessage(data)
      return true
    } catch {
      return false
    }
  }

  /// Cancels an in-flight local offer before a transactional codec
  /// restoration. Stable transports have nothing to roll back.
  func rollbackLocalOfferIfNeeded() async throws {}
}

/// Creates exactly one concrete transport for each canonical unordered
/// local-to-remote pair.
public protocol ClipLiveShareNativeV3PeerLinkTransportFactory: Sendable {
  func makeTransport(
    configuration: ClipLiveShareNativeV3PeerLinkConfiguration
  ) async throws -> any ClipLiveShareNativeV3PeerLinkTransport
}

public enum ClipLiveShareNativeV3MeshPeerLinkManagerError: Error, Equatable, Sendable,
  LocalizedError
{
  case managerClosed
  case reconciliationInProgress
  case localParticipantMissing
  case invalidPeerLink(ClipLiveShareNativeV3PeerLinkKey)
  case unknownPeer(ClipLiveShareNativeV3ParticipantID)
  case controlChannelNotOpen(ClipLiveShareNativeV3ParticipantID)
  case controlMessageTooLarge(maximumBytes: Int, actualBytes: Int)

  public var errorDescription: String? {
    switch self {
    case .managerClosed:
      "The native-v3 mesh peer-link manager is closed."
    case .reconciliationInProgress:
      "A native-v3 mesh membership reconciliation is already in progress."
    case .localParticipantMissing:
      "The native-v3 membership does not contain the local participant."
    case .invalidPeerLink:
      "The native-v3 peer-link key does not include the local participant."
    case .unknownPeer:
      "The native-v3 participant does not have a local peer connection."
    case .controlChannelNotOpen:
      "The native-v3 reliable control channel is not open."
    case let .controlMessageTooLarge(maximumBytes, actualBytes):
      "The native-v3 control message is \(actualBytes) bytes; the limit is \(maximumBytes)."
    }
  }
}

public struct ClipLiveShareNativeV3PeerLinkSnapshot: Equatable, Sendable, Identifiable {
  public let key: ClipLiveShareNativeV3PeerLinkKey
  public let remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  public let role: ClipLiveShareNativeV3PeerLinkRole
  public let connectionState: WebRTCPeerConnectionState
  public let controlChannelState: WebRTCControlDataChannelState
  public let route: WebRTCConnectionRoute
  public let reconnectAttempt: Int
  public let mediaLayout: ClipLiveShareNativeV3PeerMediaLayout
  /// Whether this exact pair may currently send local RTP. Provisional links
  /// keep their final transport alive with this false until membership commit.
  public let outboundMediaEnabled: Bool
  /// Replayable receiver state. A provisional link can negotiate these
  /// receivers before membership promotion; the committed runtime consumes
  /// this snapshot after subscribing so no one-shot track event is lost.
  public let remoteVideoTrackIDs: Set<ClipLiveShareMediaTrackID>
  public let remoteParticipantAudioTrackID: String?

  public var id: ClipLiveShareNativeV3PeerLinkKey { key }
  public var isReady: Bool {
    connectionState == .connected && controlChannelState == .open
  }
}

public struct ClipLiveShareNativeV3MeshPeerLinkManagerSnapshot: Equatable, Sendable {
  public let localParticipantID: ClipLiveShareNativeV3ParticipantID
  public let participantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  public let links: [ClipLiveShareNativeV3PeerLinkSnapshot]
  public let isClosed: Bool

  public var isLocallyComplete: Bool {
    !isClosed
      && links.count == max(0, participantIDs.count - 1)
      && links.allSatisfy(\.isReady)
  }

  /// Returns the room-visible subset of a manager that may also own
  /// quarantined provisional links. This prevents pre-commit topology and
  /// receiver state from leaking into participant-facing runtime snapshots.
  public func retainingParticipants(
    _ allowedParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  ) -> Self {
    let retainedParticipantIDs = participantIDs.intersection(
      allowedParticipantIDs
    )
    return .init(
      localParticipantID: localParticipantID,
      participantIDs: retainedParticipantIDs,
      links: links.filter {
        retainedParticipantIDs.contains($0.remoteParticipantID)
      },
      isClosed: isClosed
    )
  }
}

public struct ClipLiveShareNativeV3PeerStatistics: Equatable, Sendable, Identifiable {
  public let peerLinkKey: ClipLiveShareNativeV3PeerLinkKey
  public let remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  public let connectionState: WebRTCPeerConnectionState
  public let controlChannelState: WebRTCControlDataChannelState
  public let transport: ClipLiveShareNativeV3PeerLinkTransportStatistics

  public var id: ClipLiveShareNativeV3PeerLinkKey { peerLinkKey }
}

public enum ClipLiveShareNativeV3MeshPeerLinkManagerEvent: Equatable, Sendable {
  case linkAdded(ClipLiveShareNativeV3PeerLinkSnapshot)
  case linkUpdated(ClipLiveShareNativeV3PeerLinkSnapshot)
  case linkRemoved(
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  )
  case targetedNegotiation(ClipLiveShareNativeV3TargetedNegotiation)
  case negotiationNeeded(
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  )
  case controlMessageReceived(
    from: ClipLiveShareNativeV3ParticipantID,
    data: Data
  )
  case remoteVideoTrackAdded(
    from: ClipLiveShareNativeV3ParticipantID,
    mediaTrackID: ClipLiveShareMediaTrackID
  )
  case remoteVideoTrackRemoved(
    from: ClipLiveShareNativeV3ParticipantID,
    mediaTrackID: ClipLiveShareMediaTrackID
  )
  case remoteParticipantAudioAvailable(
    from: ClipLiveShareNativeV3ParticipantID,
    trackID: String
  )
  case remoteParticipantAudioRemoved(
    from: ClipLiveShareNativeV3ParticipantID,
    trackID: String
  )
  case statisticsUpdated(ClipLiveShareNativeV3PeerStatistics)
  case reconnectScheduled(
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    remoteParticipantID: ClipLiveShareNativeV3ParticipantID,
    attempt: Int,
    delay: Duration
  )
  case reconnectExhausted(
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  )
  case linkFailed(
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    remoteParticipantID: ClipLiveShareNativeV3ParticipantID,
    message: String
  )
  case closed
}

/// Owns every peer connection incident to one local native-v3 participant.
///
/// Given signed membership `{A, B, C, D}`, A's manager owns A-B, A-C and A-D;
/// the other managers derive the corresponding edges from the same unordered
/// keys. Together they form the six-edge complete graph, while each process
/// allocates only the three WebRTC connections it can actually terminate.
public actor ClipLiveShareNativeV3MeshPeerLinkManager {
  private struct ManagedLink {
    let configuration: ClipLiveShareNativeV3PeerLinkConfiguration
    let transport: any ClipLiveShareNativeV3PeerLinkTransport
    let generation: UInt64
    var connectionState: WebRTCPeerConnectionState = .new
    var controlChannelState: WebRTCControlDataChannelState = .connecting
    var route: WebRTCConnectionRoute = .unknown
    var outboundMediaEnabled: Bool
    var remoteVideoTrackIDs: Set<ClipLiveShareMediaTrackID> = []
    var remoteParticipantAudioTrackID: String? = nil
    var reconnectAttempt = 0
    var eventTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
  }

  private struct StatisticsRequest: Sendable {
    let peerLinkKey: ClipLiveShareNativeV3PeerLinkKey
    let generation: UInt64
    let transport: any ClipLiveShareNativeV3PeerLinkTransport
  }

  private struct StatisticsResult: Sendable {
    let peerLinkKey: ClipLiveShareNativeV3PeerLinkKey
    let generation: UInt64
    let transport: ClipLiveShareNativeV3PeerLinkTransportStatistics?
  }

  private struct ReceiverAudioPreference: Sendable {
    var playbackEnabled = true
    var volume = 1.0
  }

  public let localParticipantID: ClipLiveShareNativeV3ParticipantID

  private let transportFactory: any ClipLiveShareNativeV3PeerLinkTransportFactory
  private let reconnectPolicy: ClipLiveShareReconnectPolicy
  private let reconnectSleeper: any ClipLiveShareReconnectSleeper
  private let maximumControlMessageBytes: Int

  private var participantIDs: Set<ClipLiveShareNativeV3ParticipantID>
  private var links: [ClipLiveShareNativeV3PeerLinkKey: ManagedLink] = [:]
  private var receiverAudioPreferences:
    [ClipLiveShareNativeV3ParticipantID: ReceiverAudioPreference] = [:]
  private var videoCodecNegotiationPolicies:
    [ClipLiveShareNativeV3ParticipantID: WebRTCVideoCodecNegotiationPolicy] = [:]
  /// The last successfully requested pair codec. It is independent from room
  /// membership and survives a targeted transport recreation, preventing a
  /// recovered edge from silently returning to the factory's startup codec.
  private var videoCodecPreferences:
    [ClipLiveShareNativeV3ParticipantID: WebRTCVideoCodec] = [:]
  private var nextLinkGeneration: UInt64 = 0
  private var isReconciling = false
  private var isClosed = false
  private var continuations: [
    UUID: AsyncStream<ClipLiveShareNativeV3MeshPeerLinkManagerEvent>.Continuation
  ] = [:]

  public init(
    localParticipantID: ClipLiveShareNativeV3ParticipantID,
    transportFactory: any ClipLiveShareNativeV3PeerLinkTransportFactory,
    reconnectPolicy: ClipLiveShareReconnectPolicy = .boundedExponential,
    reconnectSleeper: any ClipLiveShareReconnectSleeper =
      ContinuousClipLiveShareReconnectSleeper(),
    maximumControlMessageBytes: Int =
      WebRTCPeerResourceLimits.clipDefault.normalized.maximumControlMessagePayloadBytes
  ) {
    self.localParticipantID = localParticipantID
    self.transportFactory = transportFactory
    self.reconnectPolicy = reconnectPolicy
    self.reconnectSleeper = reconnectSleeper
    self.maximumControlMessageBytes = max(1, maximumControlMessageBytes)
    participantIDs = [localParticipantID]
  }

  public func events() -> AsyncStream<ClipLiveShareNativeV3MeshPeerLinkManagerEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: ClipLiveShareNativeV3MeshPeerLinkManagerEvent.self,
      bufferingPolicy: .bufferingNewest(256)
    )
    guard !isClosed else {
      continuation.finish()
      return stream
    }
    continuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(id) }
    }
    return stream
  }

  /// Installs creator-certified per-peer codec policy before roster
  /// reconciliation constructs a transport. Participant profiles are
  /// immutable for one room incarnation, so retained links never need to be
  /// rewritten in place; a recreated link reads the same stored policy.
  public func setVideoCodecNegotiationPolicies(
    _ policies: [
      ClipLiveShareNativeV3ParticipantID: WebRTCVideoCodecNegotiationPolicy
    ]
  ) {
    guard !isClosed else { return }
    videoCodecNegotiationPolicies = policies.filter {
      $0.key != localParticipantID
    }
  }

  /// Reconciles the local connections transactionally. New links are fully
  /// constructed and started before obsolete links are removed. If one new
  /// transport fails, every transport created by this call is closed and the
  /// previous membership/link set remains intact.
  public func reconcileParticipants(
    _ desiredParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID>,
    quarantinedParticipantIDs: Set<ClipLiveShareNativeV3ParticipantID> = []
  ) async throws {
    guard !isClosed else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.managerClosed
    }
    guard !isReconciling else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.reconciliationInProgress
    }
    guard desiredParticipantIDs.contains(localParticipantID) else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.localParticipantMissing
    }
    guard
      quarantinedParticipantIDs.isSubset(of: desiredParticipantIDs),
      !quarantinedParticipantIDs.contains(localParticipantID)
    else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.localParticipantMissing
    }

    let topology = try ClipLiveShareNativeV3CompleteMeshTopology(
      participantIDs: desiredParticipantIDs
    )
    let desiredKeys = Set(
      topology.peerLinkKeys.filter { $0.contains(localParticipantID) }
    )
    let missingKeys = desiredKeys.subtracting(links.keys).sorted()
    let obsoleteKeys = Set(links.keys).subtracting(desiredKeys).sorted()

    isReconciling = true
    defer { isReconciling = false }

    var insertedKeys: [ClipLiveShareNativeV3PeerLinkKey] = []
    do {
      for key in missingKeys {
        guard !isClosed else {
          throw ClipLiveShareNativeV3MeshPeerLinkManagerError.managerClosed
        }
        guard let remoteParticipantID = key.otherParticipant(
          than: localParticipantID
        ) else {
          throw ClipLiveShareNativeV3MeshPeerLinkManagerError.invalidPeerLink(
            key
          )
        }
        let configuration = try ClipLiveShareNativeV3PeerLinkConfiguration(
          key: key,
          localParticipantID: localParticipantID,
          outboundMediaInitiallyEnabled:
            !quarantinedParticipantIDs.contains(remoteParticipantID),
          videoCodecNegotiationPolicy:
            videoCodecNegotiationPolicies[remoteParticipantID]
              ?? .nativeCompatible
        )
        let transport = try await transportFactory.makeTransport(
          configuration: configuration
        )
        if let codec = videoCodecPreferences[remoteParticipantID] {
          do {
            try await transport.restoreVideoCodecPreference(codec)
          } catch {
            await transport.close()
            throw error
          }
        }
        if let preference = receiverAudioPreferences[remoteParticipantID] {
          await transport.setRemoteParticipantAudioPlaybackEnabled(
            preference.playbackEnabled
          )
          await transport.setRemoteParticipantAudioVolume(preference.volume)
        }
        guard !isClosed else {
          await transport.close()
          throw ClipLiveShareNativeV3MeshPeerLinkManagerError.managerClosed
        }
        nextLinkGeneration &+= 1
        let generation = nextLinkGeneration
        let stream = await transport.events()
        links[key] = ManagedLink(
          configuration: configuration,
          transport: transport,
          generation: generation,
          outboundMediaEnabled:
            configuration.outboundMediaInitiallyEnabled
        )
        let eventTask = Task { [weak self] in
          guard let self else { return }
          await self.consumeTransportEvents(
            stream,
            peerLinkKey: key,
            generation: generation
          )
        }
        links[key]?.eventTask = eventTask
        insertedKeys.append(key)
        do {
          try await transport.start()
        } catch {
          throw error
        }
        guard !isClosed else {
          throw ClipLiveShareNativeV3MeshPeerLinkManagerError.managerClosed
        }
      }
    } catch {
      for key in insertedKeys.sorted() {
        await removeLink(
          key,
          emitRemoval: false
        )
      }
      throw error
    }

    for key in obsoleteKeys {
      await removeLink(key, emitRemoval: true)
    }
    for key in desiredKeys.sorted() {
      guard var link = links[key] else { continue }
      let shouldEnable = !quarantinedParticipantIDs.contains(
        link.configuration.remoteParticipantID
      )
      guard link.outboundMediaEnabled != shouldEnable else { continue }
      await link.transport.setOutboundMediaEnabled(shouldEnable)
      link.outboundMediaEnabled = shouldEnable
      links[key] = link
      emit(.linkUpdated(snapshot(for: link)))
    }
    participantIDs = desiredParticipantIDs
    receiverAudioPreferences = receiverAudioPreferences.filter {
      desiredParticipantIDs.contains($0.key)
    }
    videoCodecPreferences = videoCodecPreferences.filter {
      desiredParticipantIDs.contains($0.key)
    }
    for key in insertedKeys.sorted() {
      if let link = links[key] {
        emit(.linkAdded(snapshot(for: link)))
      }
    }
  }

  public func snapshot() -> ClipLiveShareNativeV3MeshPeerLinkManagerSnapshot {
    .init(
      localParticipantID: localParticipantID,
      participantIDs: participantIDs,
      links: links.values.map(snapshot(for:)).sorted { $0.key < $1.key },
      isClosed: isClosed
    )
  }

  /// Quarantines one failing pair without changing the last committed room
  /// membership. The removed transport is closed and `linkRemoved` is emitted,
  /// while `participantIDs` remains unchanged so a later reconciliation of the
  /// same signed membership recreates a fresh transport for this participant.
  public func disconnectParticipant(
    _ remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws {
    guard !isClosed else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.managerClosed
    }
    guard !isReconciling else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.reconciliationInProgress
    }
    let link = try activeLink(to: remoteParticipantID)
    isReconciling = true
    defer { isReconciling = false }
    await removeLink(link.configuration.key, emitRemoval: true)
  }

  /// Requests offer/renegotiation only on the selected pair.
  public func requestNegotiation(
    with remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws {
    let link = try activeLink(to: remoteParticipantID)
    try await link.transport.requestNegotiation()
  }

  /// Applies a pair-scoped description or ICE candidate to exactly one
  /// connection. Authentication/revision checks occur in the v3 wire layer
  /// before it calls this transport manager.
  public func applyRemoteNegotiation(
    _ targeted: ClipLiveShareNativeV3TargetedNegotiation,
    from remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws {
    let link = try activeLink(to: remoteParticipantID)
    guard
      targeted.peerLinkKey == link.configuration.key,
      targeted.targetParticipantID == localParticipantID
    else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.invalidPeerLink(
        targeted.peerLinkKey
      )
    }
    switch targeted.payload {
    case let .sessionDescription(description):
      try await link.transport.applyRemoteDescription(description)
      if let codec = await link.transport.currentVideoCodecPreference() {
        videoCodecPreferences[remoteParticipantID] = codec
      }
    case let .iceCandidate(candidate):
      try await link.transport.addRemoteICECandidate(candidate)
    }
  }

  public func sendControlMessage(
    _ data: Data,
    to remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws {
    guard data.count <= maximumControlMessageBytes else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.controlMessageTooLarge(
        maximumBytes: maximumControlMessageBytes,
        actualBytes: data.count
      )
    }
    let link = try activeLink(to: remoteParticipantID)
    guard link.controlChannelState == .open else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.controlChannelNotOpen(
        remoteParticipantID
      )
    }
    try await link.transport.sendControlMessage(data)
  }

  /// Sends one replaceable sample without turning transient DataChannel
  /// pressure into peer degradation. The next cursor sample supersedes this
  /// one, so neither this manager nor the transport retains a retry queue.
  @discardableResult
  public func sendEphemeralControlMessage(
    _ data: Data,
    to remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async -> Bool {
    guard data.count <= maximumControlMessageBytes,
      let link = try? activeLink(to: remoteParticipantID),
      link.controlChannelState == .open
    else {
      return false
    }
    return await link.transport.sendEphemeralControlMessage(data)
  }

  /// Resolves one source descriptor against only its owning participant's
  /// negotiated receiver tracks.
  public func remoteVideoStream(
    for descriptor: ClipLiveShareStreamDescriptor,
    from remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws -> WebRTCRemoteVideoStream? {
    let link = try activeLink(to: remoteParticipantID)
    return await link.transport.remoteVideoStream(for: descriptor)
  }

  public func setRemoteParticipantAudioPlaybackEnabled(
    _ enabled: Bool,
    for remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws {
    let link = try activeLink(to: remoteParticipantID)
    var preference =
      receiverAudioPreferences[remoteParticipantID]
      ?? ReceiverAudioPreference()
    preference.playbackEnabled = enabled
    receiverAudioPreferences[remoteParticipantID] = preference
    await link.transport.setRemoteParticipantAudioPlaybackEnabled(enabled)
  }

  public func setOutboundMediaEnabled(
    _ enabled: Bool,
    for remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws {
    var link = try activeLink(to: remoteParticipantID)
    guard link.outboundMediaEnabled != enabled else { return }
    await link.transport.setOutboundMediaEnabled(enabled)
    link.outboundMediaEnabled = enabled
    links[link.configuration.key] = link
    emit(.linkUpdated(snapshot(for: link)))
  }

  public func updateSenderPolicy(
    _ policy: WebRTCSenderPolicy
  ) async {
    for key in links.keys.sorted() {
      guard let link = links[key] else { continue }
      await link.transport.updateSenderPolicy(policy)
    }
  }

  /// Compatibility seam for callers written during the server-mesh migration.
  /// Networking must not divide or reshape the selected media preset, so the
  /// complete fallback policy is applied unchanged to every current sender.
  public func updateSenderPolicies(
    _ policiesBySlot: [Int: WebRTCSenderPolicy],
    fallback: WebRTCSenderPolicy,
    videoEncodingMode: LiveShareEncodingMode
  ) async {
    for key in links.keys.sorted() {
      guard let link = links[key] else { continue }
      await link.transport.updateSenderPolicies(
        policiesBySlot,
        fallback: fallback,
        videoEncodingMode: videoEncodingMode
      )
    }
  }

  public func updateVideoCodecPreference(
    _ codec: WebRTCVideoCodec,
    for remoteParticipantID: ClipLiveShareNativeV3ParticipantID,
    rollbackTo previousCodec: WebRTCVideoCodec
  ) async throws {
    let link = try activeLink(to: remoteParticipantID)
    let authoritativePreviousCodec =
      await link.transport.currentVideoCodecPreference() ?? previousCodec
    do {
      try await link.transport.updateVideoCodecPreference(codec)
      videoCodecPreferences[remoteParticipantID] = codec
    } catch {
      try? await link.transport.restoreVideoCodecPreference(
        authoritativePreviousCodec
      )
      throw error
    }
  }

  public func restoreVideoCodecPreference(
    _ codec: WebRTCVideoCodec,
    for remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws {
    let link = try activeLink(to: remoteParticipantID)
    try await link.transport.restoreVideoCodecPreference(codec)
    videoCodecPreferences[remoteParticipantID] = codec
  }

  public func currentVideoCodecPreference(
    for remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws -> WebRTCVideoCodec? {
    let link = try activeLink(to: remoteParticipantID)
    return await link.transport.currentVideoCodecPreference()
      ?? videoCodecPreferences[remoteParticipantID]
  }

  public func rollbackLocalOfferIfNeeded(
    for remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws {
    let link = try activeLink(to: remoteParticipantID)
    try await link.transport.rollbackLocalOfferIfNeeded()
  }

  public func setRemoteParticipantAudioVolume(
    _ volume: Double,
    for remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws {
    let link = try activeLink(to: remoteParticipantID)
    let normalizedVolume = min(max(volume, 0), 1)
    var preference =
      receiverAudioPreferences[remoteParticipantID]
      ?? ReceiverAudioPreference()
    preference.volume = normalizedVolume
    receiverAudioPreferences[remoteParticipantID] = preference
    await link.transport.setRemoteParticipantAudioVolume(normalizedVolume)
  }

  /// Collects each pair's statistics concurrently and returns healthy pairs in
  /// canonical order. A failed pair is omitted rather than suppressing every
  /// other participant's diagnostics.
  public func statistics() async throws -> [ClipLiveShareNativeV3PeerStatistics] {
    guard !isClosed else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.managerClosed
    }

    let requests = links.keys.sorted().compactMap { key -> StatisticsRequest? in
      guard let link = links[key] else { return nil }
      return StatisticsRequest(
        peerLinkKey: key,
        generation: link.generation,
        transport: link.transport
      )
    }
    let samples = await withTaskGroup(
      of: StatisticsResult.self,
      returning: [StatisticsResult].self
    ) { group in
      for request in requests {
        group.addTask {
          let statistics = try? await request.transport.statistics()
          return StatisticsResult(
            peerLinkKey: request.peerLinkKey,
            generation: request.generation,
            transport: statistics
          )
        }
      }

      var result: [StatisticsResult] = []
      result.reserveCapacity(requests.count)
      for await sample in group {
        result.append(sample)
      }
      return result
    }

    var result: [ClipLiveShareNativeV3PeerStatistics] = []
    for sample in samples.sorted(by: {
      $0.peerLinkKey < $1.peerLinkKey
    }) {
      guard
        let statistics = sample.transport,
        let current = links[sample.peerLinkKey],
        current.generation == sample.generation
      else { continue }
      result.append(
        .init(
          peerLinkKey: sample.peerLinkKey,
          remoteParticipantID: current.configuration.remoteParticipantID,
          connectionState: current.connectionState,
          controlChannelState: current.controlChannelState,
          transport: statistics
        )
      )
    }
    return result
  }

  /// Explicitly restarts only the selected pair's ICE state.
  public func restartLink(
    to remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) async throws {
    let link = try activeLink(to: remoteParticipantID)
    link.reconnectTask?.cancel()
    if var current = links[link.configuration.key],
      current.generation == link.generation
    {
      current.reconnectTask = nil
      current.reconnectAttempt = 0
      links[link.configuration.key] = current
    }
    try await link.transport.restartICE()
  }

  /// Closes links in canonical key order, exactly once, and terminates all
  /// manager event streams. Repeated calls are idempotent.
  public func close() async {
    guard !isClosed else { return }
    isClosed = true
    for key in links.keys.sorted() {
      await removeLink(key, emitRemoval: true)
    }
    participantIDs = [localParticipantID]
    receiverAudioPreferences.removeAll(keepingCapacity: false)
    emit(.closed)
    for continuation in continuations.values {
      continuation.finish()
    }
    continuations.removeAll(keepingCapacity: false)
  }

  private func activeLink(
    to remoteParticipantID: ClipLiveShareNativeV3ParticipantID
  ) throws -> ManagedLink {
    guard !isClosed else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.managerClosed
    }
    let key = try ClipLiveShareNativeV3PeerLinkKey(
      localParticipantID,
      remoteParticipantID
    )
    guard let link = links[key] else {
      throw ClipLiveShareNativeV3MeshPeerLinkManagerError.unknownPeer(
        remoteParticipantID
      )
    }
    return link
  }

  private func consumeTransportEvents(
    _ stream: AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent>,
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    generation: UInt64
  ) async {
    for await event in stream {
      guard !Task.isCancelled else { return }
      handleTransportEvent(
        event,
        peerLinkKey: peerLinkKey,
        generation: generation
      )
    }
  }

  private func handleTransportEvent(
    _ event: ClipLiveShareNativeV3PeerLinkTransportEvent,
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    generation: UInt64
  ) {
    guard
      !isClosed,
      var link = links[peerLinkKey],
      link.generation == generation
    else { return }
    let remoteParticipantID = link.configuration.remoteParticipantID

    switch event {
    case let .localNegotiation(payload):
      let targeted = ClipLiveShareNativeV3TargetedNegotiation(
        peerLinkKey: peerLinkKey,
        targetParticipantID: remoteParticipantID,
        payload: payload
      )
      emit(.targetedNegotiation(targeted))
    case .negotiationNeeded:
      // Creating the answerer's fixed four-video/one-audio sender layout can
      // make libwebrtc raise `negotiationNeeded` while the initial answer is
      // still being installed. That media is already represented by the
      // initial SDP. Forwarding the callback before the pair is ready races a
      // redundant offer against the outstanding exchange and can corrupt the
      // shared MID/RTCP-mux layout on a later join.
      guard snapshot(for: link).isReady else { break }
      emit(
        .negotiationNeeded(
          peerLinkKey: peerLinkKey,
          remoteParticipantID: remoteParticipantID
        )
      )
    case let .connectionStateChanged(state):
      link.connectionState = state
      if state == .connected {
        link.reconnectTask?.cancel()
        link.reconnectTask = nil
        link.reconnectAttempt = 0
      }
      links[peerLinkKey] = link
      emit(.linkUpdated(snapshot(for: link)))
      if state == .disconnected || state == .failed {
        scheduleReconnect(
          peerLinkKey: peerLinkKey,
          generation: generation
        )
      }
    case let .controlChannelStateChanged(state):
      link.controlChannelState = state
      links[peerLinkKey] = link
      emit(.linkUpdated(snapshot(for: link)))
    case let .controlMessageReceived(data):
      emit(.controlMessageReceived(from: remoteParticipantID, data: data))
    case let .remoteVideoTrackAdded(mediaTrackID):
      link.remoteVideoTrackIDs.insert(mediaTrackID)
      links[peerLinkKey] = link
      emit(
        .remoteVideoTrackAdded(
          from: remoteParticipantID,
          mediaTrackID: mediaTrackID
        )
      )
    case let .remoteVideoTrackRemoved(mediaTrackID):
      link.remoteVideoTrackIDs.remove(mediaTrackID)
      links[peerLinkKey] = link
      emit(
        .remoteVideoTrackRemoved(
          from: remoteParticipantID,
          mediaTrackID: mediaTrackID
        )
      )
    case let .remoteParticipantAudioAvailable(trackID):
      link.remoteParticipantAudioTrackID = trackID
      links[peerLinkKey] = link
      emit(
        .remoteParticipantAudioAvailable(
          from: remoteParticipantID,
          trackID: trackID
        )
      )
    case let .remoteParticipantAudioRemoved(trackID):
      if link.remoteParticipantAudioTrackID == trackID {
        link.remoteParticipantAudioTrackID = nil
        links[peerLinkKey] = link
      }
      emit(
        .remoteParticipantAudioRemoved(
          from: remoteParticipantID,
          trackID: trackID
        )
      )
    case let .routeChanged(route):
      link.route = route
      links[peerLinkKey] = link
      emit(.linkUpdated(snapshot(for: link)))
    case let .statisticsChanged(statistics):
      emit(
        .statisticsUpdated(
          .init(
            peerLinkKey: peerLinkKey,
            remoteParticipantID: remoteParticipantID,
            connectionState: link.connectionState,
            controlChannelState: link.controlChannelState,
            transport: statistics
          )
        )
      )
    case .iceGatheringDiagnostic:
      // A STUN/TURN candidate error is not a peer-link failure. In particular,
      // public STUN servers can time out while a same-LAN host candidate keeps
      // carrying media and control. The connection-state callback remains the
      // single source of truth for reconnect scheduling.
      break
    case let .failed(message):
      emit(
        .linkFailed(
          peerLinkKey: peerLinkKey,
          remoteParticipantID: remoteParticipantID,
          message: message
        )
      )
      scheduleReconnect(
        peerLinkKey: peerLinkKey,
        generation: generation
      )
    }
  }

  private func scheduleReconnect(
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    generation: UInt64
  ) {
    guard
      !isClosed,
      var link = links[peerLinkKey],
      link.generation == generation,
      link.configuration.role == .offerer,
      link.reconnectTask == nil
    else { return }

    let attempt = link.reconnectAttempt + 1
    guard let delay = reconnectPolicy.delay(forAttempt: attempt) else {
      emit(
        .reconnectExhausted(
          peerLinkKey: peerLinkKey,
          remoteParticipantID: link.configuration.remoteParticipantID
        )
      )
      return
    }
    link.reconnectAttempt = attempt
    let remoteParticipantID = link.configuration.remoteParticipantID
    link.reconnectTask = Task { [weak self, reconnectSleeper] in
      do {
        try await reconnectSleeper.sleep(for: delay)
        guard let self else { return }
        await self.performReconnect(
          peerLinkKey: peerLinkKey,
          generation: generation,
          attempt: attempt
        )
      } catch {
        // Cancellation is expected when this link reconnects, leaves the
        // membership, or the manager closes.
      }
    }
    links[peerLinkKey] = link
    emit(
      .reconnectScheduled(
        peerLinkKey: peerLinkKey,
        remoteParticipantID: remoteParticipantID,
        attempt: attempt,
        delay: delay
      )
    )
  }

  private func performReconnect(
    peerLinkKey: ClipLiveShareNativeV3PeerLinkKey,
    generation: UInt64,
    attempt: Int
  ) async {
    guard
      !isClosed,
      var link = links[peerLinkKey],
      link.generation == generation,
      link.configuration.role == .offerer,
      link.reconnectAttempt == attempt
    else { return }
    link.reconnectTask = nil
    links[peerLinkKey] = link
    do {
      try await link.transport.restartICE()
    } catch {
      emit(
        .linkFailed(
          peerLinkKey: peerLinkKey,
          remoteParticipantID: link.configuration.remoteParticipantID,
          message: String(describing: error)
        )
      )
      scheduleReconnect(
        peerLinkKey: peerLinkKey,
        generation: generation
      )
    }
  }

  private func removeLink(
    _ key: ClipLiveShareNativeV3PeerLinkKey,
    emitRemoval: Bool
  ) async {
    guard let link = links.removeValue(forKey: key) else { return }
    link.eventTask?.cancel()
    link.reconnectTask?.cancel()
    await link.transport.close()
    if emitRemoval {
      emit(
        .linkRemoved(
          peerLinkKey: key,
          remoteParticipantID: link.configuration.remoteParticipantID
        )
      )
    }
  }

  private func snapshot(
    for link: ManagedLink
  ) -> ClipLiveShareNativeV3PeerLinkSnapshot {
    .init(
      key: link.configuration.key,
      remoteParticipantID: link.configuration.remoteParticipantID,
      role: link.configuration.role,
      connectionState: link.connectionState,
      controlChannelState: link.controlChannelState,
      route: link.route,
      reconnectAttempt: link.reconnectAttempt,
      mediaLayout: link.configuration.mediaLayout,
      outboundMediaEnabled: link.outboundMediaEnabled,
      remoteVideoTrackIDs: link.remoteVideoTrackIDs,
      remoteParticipantAudioTrackID:
        link.remoteParticipantAudioTrackID
    )
  }

  private func emit(_ event: ClipLiveShareNativeV3MeshPeerLinkManagerEvent) {
    for continuation in continuations.values {
      continuation.yield(event)
    }
  }

  private func removeContinuation(_ id: UUID) {
    continuations[id] = nil
  }
}
