import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTCAudioBridge
import Foundation
import OSLog
@preconcurrency import WebRTC

public struct ClipLiveShareNativeV3WebRTCConfiguration: Equatable, Sendable {
  public var peer: WebRTCPeerConfiguration
  public var remoteParticipantAudioPlaybackEnabled: Bool
  public var remoteParticipantAudioVolume: Double

  public init(
    peer: WebRTCPeerConfiguration = .clipDefault,
    remoteParticipantAudioPlaybackEnabled: Bool = true,
    remoteParticipantAudioVolume: Double = 1
  ) {
    self.peer = peer
    self.remoteParticipantAudioPlaybackEnabled =
      remoteParticipantAudioPlaybackEnabled
    self.remoteParticipantAudioVolume = min(max(remoteParticipantAudioVolume, 0), 1)
  }

  public static let clipDefault = Self()
}

/// Cumulative output-side diagnostics for the participant-scoped WebRTC
/// audio device. A negotiated remote audio track is not sufficient evidence
/// that a listener can hear it; these counters prove that WebRTC's playout
/// mixer was actually pulled and that non-silent PCM reached CoreAudio.
public struct ClipLiveShareNativeV3WebRTCPlayoutDiagnostics:
  Equatable, Sendable
{
  public let callbackCount: UInt64
  public let renderedFrameCount: UInt64
  public let nonSilentFrameCount: UInt64
  public let errorCount: UInt64

  public init(
    callbackCount: UInt64,
    renderedFrameCount: UInt64,
    nonSilentFrameCount: UInt64,
    errorCount: UInt64
  ) {
    self.callbackCount = callbackCount
    self.renderedFrameCount = renderedFrameCount
    self.nonSilentFrameCount = nonSilentFrameCount
    self.errorCount = errorCount
  }
}

public enum ClipLiveShareNativeV3WebRTCPeerLinkError: Error, Equatable, Sendable,
  LocalizedError
{
  case factoryClosed
  case transportClosed
  case peerConnectionCreationFailed
  case videoTransceiverCreationFailed(slot: Int)
  case audioTransceiverCreationFailed
  case dataChannelCreationFailed
  case unexpectedDataChannel(String)
  case videoCodecUnavailable(WebRTCVideoCodec)
  case codecPreferenceFailed(String)
  case negotiationInProgress
  case invalidSessionDescriptionKind
  case sessionDescriptionTooLarge(maximumBytes: Int)
  case localDescriptionCreationFailed(String)
  case localDescriptionApplicationFailed(String)
  case remoteDescriptionApplicationFailed(String)
  case offerCollision
  case invalidICECandidate(String)
  case iceCandidateLimitReached(maximum: Int)
  case iceCandidateApplicationFailed(String)
  case controlChannelUnavailable
  case controlBackpressure
  case invalidSlot(Int)
  case slotAlreadyActive(Int)
  case slotInactive(Int)
  case slotTrackMismatch(expected: String, actual: String)
  case statisticsUnavailable

  public var errorDescription: String? {
    switch self {
    case .factoryClosed:
      "The native-v3 WebRTC media factory is closed."
    case .transportClosed:
      "The native-v3 WebRTC peer connection is closed."
    case .peerConnectionCreationFailed:
      "libwebrtc could not create the native-v3 peer connection."
    case let .videoTransceiverCreationFailed(slot):
      "libwebrtc could not create native-v3 video slot \(slot)."
    case .audioTransceiverCreationFailed:
      "libwebrtc could not create the native-v3 participant-audio track."
    case .dataChannelCreationFailed:
      "libwebrtc could not create the native-v3 control DataChannel."
    case let .unexpectedDataChannel(label):
      "The peer opened an unexpected native-v3 DataChannel named \(label)."
    case let .videoCodecUnavailable(codec):
      "The requested native-v3 video codec \(codec.rawValue) is unavailable."
    case let .codecPreferenceFailed(message):
      "The native-v3 codec preference failed: \(message)"
    case .negotiationInProgress:
      "A native-v3 WebRTC negotiation is already in progress."
    case .invalidSessionDescriptionKind:
      "The native-v3 session description is not valid in the current state."
    case let .sessionDescriptionTooLarge(maximumBytes):
      "The native-v3 SDP exceeds the \(maximumBytes)-byte limit."
    case let .localDescriptionCreationFailed(message):
      "The native-v3 local description could not be created: \(message)"
    case let .localDescriptionApplicationFailed(message):
      "The native-v3 local description could not be applied: \(message)"
    case let .remoteDescriptionApplicationFailed(message):
      "The native-v3 remote description could not be applied: \(message)"
    case .offerCollision:
      "The native-v3 offer lost deterministic glare resolution."
    case let .invalidICECandidate(message):
      "The native-v3 ICE candidate is invalid: \(message)"
    case let .iceCandidateLimitReached(maximum):
      "The native-v3 peer exceeded \(maximum) ICE candidates."
    case let .iceCandidateApplicationFailed(message):
      "The native-v3 ICE candidate could not be applied: \(message)"
    case .controlChannelUnavailable:
      "The native-v3 reliable control channel is unavailable."
    case .controlBackpressure:
      "The native-v3 reliable control channel is applying backpressure."
    case let .invalidSlot(slot):
      "Native-v3 video slot \(slot) is invalid."
    case let .slotAlreadyActive(slot):
      "Native-v3 video slot \(slot) is already active."
    case let .slotInactive(slot):
      "Native-v3 video slot \(slot) is inactive."
    case let .slotTrackMismatch(expected, actual):
      "The native-v3 slot expected track \(expected), received \(actual)."
    case .statisticsUnavailable:
      "Native-v3 WebRTC statistics are unavailable."
    }
  }
}

private final class ClipLiveShareNativeV3LocalVideoSlot: @unchecked Sendable {
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
    trackID = ClipLiveShareMediaTrackID.random().rawValue
    streamID = ClipLiveShareStreamID.random().rawValue
    source = factory.videoSource(forScreenCast: true)
    track = factory.videoTrack(with: source, trackId: trackID)
    frameSource = WebRTCFrameSource(source: source)
    track.isEnabled = false
  }

  var snapshot: WebRTCStreamSlotSnapshot {
    .init(
      index: index,
      trackID: trackID,
      streamID: streamID,
      metadata: metadata,
      captureGeometry: captureGeometry
    )
  }
}

private final class ClipLiveShareNativeV3WeakPeerTransport:
  @unchecked Sendable
{
  weak var value: ClipLiveShareNativeV3WebRTCPeerLinkTransport?

  init(_ value: ClipLiveShareNativeV3WebRTCPeerLinkTransport) {
    self.value = value
  }
}

/// Shared local media engine and concrete transport factory for one native-v3
/// participant. Four stable video tracks and one stable audio track are reused
/// by every pair connection; each captured frame is therefore submitted to
/// libwebrtc exactly once regardless of room size.
public final class ClipLiveShareNativeV3WebRTCTransportFactory:
  LiveShareVideoSlotHosting,
  ClipLiveShareNativeV3PeerLinkTransportFactory,
  @unchecked Sendable
{
  private let configuration: ClipLiveShareNativeV3WebRTCConfiguration
  private let lock = NSLock()
  private let sslLease: WebRTCSSLRuntimeLease
  private let h264EncoderFactory: WebRTCH264EncoderFactory
  private let videoEncoderFactory: WebRTCVideoEncoderFactory
  private let systemAudioDevice: ClipLiveShareWebRTCSystemAudioDevice
  private let peerFactory: RTCPeerConnectionFactory
  private let videoCodecCapabilities: [RTCRtpCodecCapability]
  private let audioCodecCapabilities: [RTCRtpCodecCapability]
  private let slots: [ClipLiveShareNativeV3LocalVideoSlot]
  private let systemAudioTrack: RTCAudioTrack
  private let systemAudioTrackID: String
  private let systemAudioStreamID: String
  private var peerTransports: [ClipLiveShareNativeV3WeakPeerTransport] = []
  private var systemAudioEnabled = false
  private var activeSenderPolicy: WebRTCSenderPolicy
  private var activeVideoCodec: WebRTCVideoCodec
  private var activeVideoEncodingMode: LiveShareEncodingMode
  private var activeAdvancedVideoConfigurations:
    WebRTCAdvancedVideoConfigurations
  private var isClosed = false

  public init(
    configuration: ClipLiveShareNativeV3WebRTCConfiguration = .clipDefault
  ) throws {
    self.configuration = configuration
    activeSenderPolicy = configuration.peer.senderPolicy
    activeVideoCodec = configuration.peer.videoCodec
    activeVideoEncodingMode = configuration.peer.videoEncodingMode
    activeAdvancedVideoConfigurations =
      configuration.peer.advancedVideoConfigurations
    sslLease = try WebRTCSSLRuntimeLease()
    let h264 = WebRTCH264EncoderFactory(
      configuration: .init(
        mode: WebRTCH264EncodingMode(configuration.peer.videoEncodingMode)
      ),
      advancedConfiguration: configuration.peer.advancedVideoConfigurations.h264
    )
    h264EncoderFactory = h264
    let encoderFactory = WebRTCVideoEncoderFactory(
      preferredCodec: configuration.peer.videoCodec,
      h264Factory: h264,
      advancedConfigurations: configuration.peer.advancedVideoConfigurations
    )
    videoEncoderFactory = encoderFactory
    let audioDevice = ClipLiveShareWebRTCSystemAudioDevice()
    systemAudioDevice = audioDevice
    let factory = ClipLiveShareWebRTCCreatePeerConnectionFactory(
      encoderFactory,
      RTCDefaultVideoDecoderFactory(),
      audioDevice
    )
    peerFactory = factory
    videoCodecCapabilities = factory
      .rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
      .codecs
    audioCodecCapabilities = factory
      .rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindAudio)
      .codecs
    guard videoCodecCapabilities.contains(where: {
      $0.name.caseInsensitiveCompare(configuration.peer.videoCodec.rtcName)
        == .orderedSame
    }) else {
      throw ClipLiveShareNativeV3WebRTCPeerLinkError.videoCodecUnavailable(
        configuration.peer.videoCodec
      )
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
    let audioSource = factory.audioSource(with: audioConstraints)
    systemAudioTrackID = ClipLiveShareMediaTrackID.random().rawValue
    systemAudioStreamID = ClipLiveShareStreamID.random().rawValue
    systemAudioTrack = factory.audioTrack(
      with: audioSource,
      trackId: systemAudioTrackID
    )
    systemAudioTrack.isEnabled = false
    audioDevice.setInputEnabled(false)
    slots = (0..<ClipLiveShareNativeV3.reservedVideoSlotsPerParticipant).map {
      ClipLiveShareNativeV3LocalVideoSlot(index: $0, factory: factory)
    }
  }

  deinit {
    close()
  }

  public var slotSnapshots: [WebRTCStreamSlotSnapshot] {
    lock.withLock { slots.map(\.snapshot) }
  }

  public var localParticipantAudioTrackID: String { systemAudioTrackID }

  public var playoutDiagnostics:
    ClipLiveShareNativeV3WebRTCPlayoutDiagnostics
  {
    .init(
      callbackCount: systemAudioDevice.playoutCallbackCount,
      renderedFrameCount: systemAudioDevice.renderedPlayoutFrameCount,
      nonSilentFrameCount: systemAudioDevice.nonSilentPlayoutFrameCount,
      errorCount: systemAudioDevice.playoutErrorCount
    )
  }

  /// Actual sender state, not the persisted/UI preference. Acceptance
  /// reporting uses this value so a failed or stopped capture cannot be
  /// misreported merely because the System Audio toggle is still on.
  public var isSystemAudioEnabled: Bool {
    lock.withLock { !isClosed && systemAudioEnabled }
  }

  public func makeTransport(
    configuration linkConfiguration: ClipLiveShareNativeV3PeerLinkConfiguration
  ) async throws -> any ClipLiveShareNativeV3PeerLinkTransport {
    try lock.withLock {
      guard !isClosed else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.factoryClosed
      }
      var currentConfiguration = configuration
      currentConfiguration.peer.senderPolicy = activeSenderPolicy
      currentConfiguration.peer.videoCodec = activeVideoCodec
      currentConfiguration.peer.videoEncodingMode =
        activeVideoEncodingMode
      currentConfiguration.peer.advancedVideoConfigurations =
        activeAdvancedVideoConfigurations
      let transport = try ClipLiveShareNativeV3WebRTCPeerLinkTransport(
        linkConfiguration: linkConfiguration,
        webRTCConfiguration: currentConfiguration,
        peerFactory: peerFactory,
        videoCodecCapabilities: videoCodecCapabilities,
        audioCodecCapabilities: audioCodecCapabilities,
        localVideoSlots: slots,
        localParticipantAudioTrack: systemAudioTrack,
        localParticipantAudioStreamID: systemAudioStreamID,
        activeLocalVideoSourceCount: slots.count(where: {
          $0.metadata != nil
        })
      )
      peerTransports.removeAll { $0.value == nil }
      peerTransports.append(.init(transport))
      return transport
    }
  }

  public var senderPolicy: WebRTCSenderPolicy {
    lock.withLock { activeSenderPolicy }
  }

  public var videoCodec: WebRTCVideoCodec {
    lock.withLock { activeVideoCodec }
  }

  public var videoEncodingMode: LiveShareEncodingMode {
    lock.withLock { activeVideoEncodingMode }
  }

  public var advancedVideoConfigurations:
    WebRTCAdvancedVideoConfigurations
  {
    lock.withLock { activeAdvancedVideoConfigurations }
  }

  /// Retains the policy for future pair links. The mesh manager applies it to
  /// every current pair's RTP senders in the same participant operation.
  public func retainSenderPolicy(_ policy: WebRTCSenderPolicy) {
    lock.withLock {
      guard !isClosed else { return }
      activeSenderPolicy = policy
    }
  }

  public func updateVideoEncodingMode(_ mode: LiveShareEncodingMode) {
    let transports = lock.withLock {
      guard !isClosed else {
        return [ClipLiveShareNativeV3WebRTCPeerLinkTransport]()
      }
      activeVideoEncodingMode = mode
      h264EncoderFactory.updateMode(WebRTCH264EncodingMode(mode))
      peerTransports.removeAll { $0.value == nil }
      return peerTransports.compactMap(\.value)
    }
    for transport in transports {
      transport.updateLocalVideoEncodingMode(mode)
    }
  }

  public func updateAdvancedVideoConfiguration(
    _ configuration: WebRTCCodecAdvancedConfiguration
  ) {
    lock.withLock {
      guard !isClosed else { return }
      switch configuration {
      case let .h264(value):
        activeAdvancedVideoConfigurations.h264 = value
      }
      videoEncoderFactory.updateAdvancedConfiguration(configuration)
    }
  }

  /// Retains a codec preference for links constructed after the current mesh
  /// transaction. Existing links are updated by the manager before this value
  /// is committed.
  public func retainVideoCodec(_ codec: WebRTCVideoCodec) throws {
    try lock.withLock {
      guard !isClosed else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.factoryClosed
      }
      guard videoCodecCapabilities.contains(where: {
        $0.name.caseInsensitiveCompare(codec.rtcName) == .orderedSame
      }) else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError
          .videoCodecUnavailable(codec)
      }
      activeVideoCodec = codec
    }
  }

  @discardableResult
  public func send(
    _ frame: BorrowedCaptureVideoFrame,
    toSlot slot: Int
  ) -> CaptureFrameDisposition {
    lock.withLock {
      guard
        !isClosed,
        slots.indices.contains(slot),
        slots[slot].metadata != nil
      else { return .droppedBackpressure }
      return slots[slot].frameSource.send(frame)
    }
  }

  public func activateSlot(
    _ slot: Int,
    metadata: ClipLiveShareStreamDescriptor,
    captureGeometry: WebRTCVideoCaptureGeometry
  ) throws {
    let update = try lock.withLock {
      guard !isClosed else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.factoryClosed
      }
      guard slots.indices.contains(slot) else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.invalidSlot(slot)
      }
      let target = slots[slot]
      guard metadata.mediaTrackID.rawValue == target.trackID else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.slotTrackMismatch(
          expected: target.trackID,
          actual: metadata.mediaTrackID.rawValue
        )
      }
      guard target.metadata == nil else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.slotAlreadyActive(slot)
      }
      target.frameSource.clearLatestFrame()
      target.metadata = metadata
      target.captureGeometry = captureGeometry
      target.track.isEnabled = true
      peerTransports.removeAll { $0.value == nil }
      return (
        peerTransports.compactMap(\.value),
        slots.count(where: { $0.metadata != nil })
      )
    }
    let (transports, count) = update
    for transport in transports {
      transport.updateActiveLocalVideoSourceCount(count)
    }
  }

  public func updateSlotMetadata(
    _ slot: Int,
    metadata: ClipLiveShareStreamDescriptor,
    captureGeometry: WebRTCVideoCaptureGeometry
  ) throws {
    try lock.withLock {
      guard !isClosed else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.factoryClosed
      }
      guard slots.indices.contains(slot) else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.invalidSlot(slot)
      }
      let target = slots[slot]
      guard metadata.mediaTrackID.rawValue == target.trackID else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.slotTrackMismatch(
          expected: target.trackID,
          actual: metadata.mediaTrackID.rawValue
        )
      }
      guard target.metadata != nil else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.slotInactive(slot)
      }
      target.frameSource.discardLatestFrameUnlessMatching(
        width: captureGeometry.width,
        height: captureGeometry.height
      )
      target.metadata = metadata
      target.captureGeometry = captureGeometry
    }
  }

  public func deactivateSlot(_ slot: Int) {
    let update = lock.withLock { () -> (
      [ClipLiveShareNativeV3WebRTCPeerLinkTransport], Int
    )? in
      guard !isClosed, slots.indices.contains(slot) else { return nil }
      let target = slots[slot]
      target.metadata = nil
      target.captureGeometry = nil
      target.track.isEnabled = false
      target.frameSource.clearLatestFrame()
      peerTransports.removeAll { $0.value == nil }
      return (
        peerTransports.compactMap(\.value),
        slots.count(where: { $0.metadata != nil })
      )
    }
    guard let (transports, count) = update else { return }
    for transport in transports {
      transport.updateActiveLocalVideoSourceCount(count)
    }
  }

  public func setSystemAudioEnabled(_ enabled: Bool) {
    lock.withLock {
      guard !isClosed else { return }
      systemAudioEnabled = enabled
      systemAudioTrack.isEnabled = enabled
      systemAudioDevice.setInputEnabled(enabled)
      if !enabled { systemAudioDevice.clearQueuedAudio() }
    }
  }

  @discardableResult
  public func send(_ sample: BorrowedCaptureAudioSample) -> Bool {
    let acceptsAudio = lock.withLock { !isClosed && systemAudioEnabled }
    guard acceptsAudio else { return false }
    return systemAudioDevice.enqueue(sample.sampleBuffer)
  }

  public func close() {
    lock.withLock {
      guard !isClosed else { return }
      isClosed = true
      systemAudioEnabled = false
      systemAudioTrack.isEnabled = false
      systemAudioDevice.setInputEnabled(false)
      systemAudioDevice.clearQueuedAudio()
      for slot in slots {
        slot.metadata = nil
        slot.captureGeometry = nil
        slot.track.isEnabled = false
        slot.frameSource.clearLatestFrame()
      }
    }
  }
}

/// A concrete symmetric native-v3 pair connection. Both endpoints create the
/// same send-receive media plan and can publish or consume media independently.
public final class ClipLiveShareNativeV3WebRTCPeerLinkTransport:
  ClipLiveShareNativeV3PeerLinkTransport,
  @unchecked Sendable
{
  private static let bandwidthLogger = Logger(
    subsystem: "ClipLiveShareWebRTC",
    category: "Peer bandwidth"
  )
  private enum ReceivedTrack {
    case video(ClipLiveShareMediaTrackID)
    case participantAudio(String)
    case unsupported
  }

  private struct LocalMediaIdentifier {
    let streamID: String
    let trackID: String
  }

  private let linkConfiguration: ClipLiveShareNativeV3PeerLinkConfiguration
  private let webRTCConfiguration: ClipLiveShareNativeV3WebRTCConfiguration
  private let resourceLimits: WebRTCPeerResourceLimits
  private let controlBufferPolicy: WebRTCControlBufferPolicy
  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let delegate: ClipLiveShareNativeV3WebRTCPeerDelegate
  private let connection: RTCPeerConnection
  private let localVideoSlots: [ClipLiveShareNativeV3LocalVideoSlot]
  private let localParticipantAudioTrack: RTCAudioTrack
  private let localParticipantAudioStreamID: String
  private let videoCodecCapabilities: [RTCRtpCodecCapability]
  private let audioCodecCapabilities: [RTCRtpCodecCapability]
  private var videoTransceivers: [RTCRtpTransceiver]
  private var audioTransceiver: RTCRtpTransceiver?
  private var outboundMediaEnabled: Bool
  private var senderPolicy: WebRTCSenderPolicy
  private var videoEncodingMode: LiveShareEncodingMode
  private var activeLocalVideoSourceCount: Int
  private var bandwidthApplicationState =
    NativeV3PeerBandwidthApplicationState()
  private var bandwidthSeedPending: Bool
  private var videoCodec: WebRTCVideoCodec
  private let videoCodecNegotiationPolicy: WebRTCVideoCodecNegotiationPolicy
  private var controlChannel: RTCDataChannel?
  private var connectionState: WebRTCPeerConnectionState = .new
  private var controlChannelState: WebRTCControlDataChannelState = .connecting
  private var route: WebRTCConnectionRoute = .unknown
  private var remoteDescriptionApplied = false
  private var remoteTrackIdentifiersByMID: [String: String] = [:]
  private var pendingRemoteICECandidates: [WebRTCICECandidate] = []
  private var localICECandidateCount = 0
  private var remoteICECandidateCount = 0
  private var isNegotiating = false
  /// A second request can arrive while the canonical offerer is waiting for
  /// its answer. Coalesce it until signaling returns to stable instead of
  /// creating a competing offer against the same transceiver/MID layout.
  private var hasPendingOfferRequest = false
  /// Codec changes use an explicit canonical offer/request. Ignore the
  /// redundant negotiation-needed callback produced by setCodecPreferences
  /// until that exact exchange reaches stable signaling.
  private var explicitCodecNegotiationPending = false
  private var didStart = false
  private var isClosed = false
  private var remoteVideoTracks:
    [ClipLiveShareMediaTrackID: WebRTCRemoteVideoTrackHandle] = [:]
  private var videoTrackIDsByReceiverID:
    [String: ClipLiveShareMediaTrackID] = [:]
  private var remoteParticipantAudioTrack: RTCAudioTrack?
  private var remoteParticipantAudioTrackID: String?
  private var participantAudioReceiverID: String?
  private var remoteParticipantAudioPlaybackEnabled: Bool
  private var remoteParticipantAudioVolume: Double
  private var continuations: [
    UUID: AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent>.Continuation
  ] = [:]

  fileprivate init(
    linkConfiguration: ClipLiveShareNativeV3PeerLinkConfiguration,
    webRTCConfiguration: ClipLiveShareNativeV3WebRTCConfiguration,
    peerFactory: RTCPeerConnectionFactory,
    videoCodecCapabilities: [RTCRtpCodecCapability],
    audioCodecCapabilities: [RTCRtpCodecCapability],
    localVideoSlots: [ClipLiveShareNativeV3LocalVideoSlot],
    localParticipantAudioTrack: RTCAudioTrack,
    localParticipantAudioStreamID: String,
    activeLocalVideoSourceCount: Int
  ) throws {
    self.linkConfiguration = linkConfiguration
    self.webRTCConfiguration = webRTCConfiguration
    self.localVideoSlots = localVideoSlots
    self.localParticipantAudioTrack = localParticipantAudioTrack
    self.localParticipantAudioStreamID = localParticipantAudioStreamID
    self.videoCodecCapabilities = videoCodecCapabilities
    self.audioCodecCapabilities = audioCodecCapabilities
    videoTransceivers = []
    audioTransceiver = nil
    outboundMediaEnabled =
      linkConfiguration.outboundMediaInitiallyEnabled
    senderPolicy = webRTCConfiguration.peer.senderPolicy
    videoEncodingMode = webRTCConfiguration.peer.videoEncodingMode
    self.activeLocalVideoSourceCount = activeLocalVideoSourceCount
    bandwidthSeedPending = activeLocalVideoSourceCount > 0
      && webRTCConfiguration.peer.videoEncodingMode == .quality
    videoCodec = webRTCConfiguration.peer.videoCodec
    videoCodecNegotiationPolicy =
      linkConfiguration.videoCodecNegotiationPolicy
    resourceLimits = webRTCConfiguration.peer.resourceLimits.normalized
    controlBufferPolicy = .init(
      resourceLimits: webRTCConfiguration.peer.resourceLimits
    )
    remoteParticipantAudioPlaybackEnabled =
      webRTCConfiguration.remoteParticipantAudioPlaybackEnabled
    remoteParticipantAudioVolume =
      webRTCConfiguration.remoteParticipantAudioVolume
    queue = DispatchQueue(
      label:
        "com.tomaslejdung.clip.liveshare.native-v3-peer."
          + linkConfiguration.remoteParticipantID.rawValue,
      qos: .userInteractive
    )
    delegate = ClipLiveShareNativeV3WebRTCPeerDelegate()

    let rtcConfiguration = RTCConfiguration()
    rtcConfiguration.sdpSemantics = .unifiedPlan
    rtcConfiguration.bundlePolicy = .maxBundle
    rtcConfiguration.rtcpMuxPolicy = .require
    rtcConfiguration.continualGatheringPolicy = .gatherContinually
    rtcConfiguration.iceTransportPolicy =
      webRTCConfiguration.peer.forcesRelay ? .relay : .all
    rtcConfiguration.iceServers = webRTCConfiguration.peer.iceServers.map {
      if $0.username != nil || $0.credential != nil {
        RTCIceServer(
          urlStrings: $0.urlStrings,
          username: $0.username,
          credential: $0.credential
        )
      } else {
        RTCIceServer(urlStrings: $0.urlStrings)
      }
    }
    guard let connection = peerFactory.peerConnection(
      with: rtcConfiguration,
      constraints: RTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: nil
      ),
      delegate: delegate
    ) else {
      throw ClipLiveShareNativeV3WebRTCPeerLinkError
        .peerConnectionCreationFailed
    }
    self.connection = connection

    do {
      if linkConfiguration.role == .offerer {
        var videoTransceivers: [RTCRtpTransceiver] = []
        for slot in localVideoSlots {
          let transceiverConfiguration = RTCRtpTransceiverInit()
          transceiverConfiguration.direction = .sendRecv
          transceiverConfiguration.streamIds = [slot.streamID]
          guard let transceiver = connection.addTransceiver(
            with: slot.track,
            init: transceiverConfiguration
          ) else {
            throw ClipLiveShareNativeV3WebRTCPeerLinkError
              .videoTransceiverCreationFailed(slot: slot.index)
          }
          try Self.applyVideoCodecPreference(
            videoCodec,
            policy: videoCodecNegotiationPolicy,
            capabilities: videoCodecCapabilities,
            to: transceiver
          )
          Self.applySenderPolicy(
            senderPolicy,
            to: transceiver.sender
          )
          Self.setSender(
            transceiver.sender,
            active: outboundMediaEnabled
          )
          videoTransceivers.append(transceiver)
        }
        self.videoTransceivers = videoTransceivers

        let audioConfiguration = RTCRtpTransceiverInit()
        audioConfiguration.direction = .sendRecv
        audioConfiguration.streamIds = [localParticipantAudioStreamID]
        guard let audioTransceiver = connection.addTransceiver(
          with: localParticipantAudioTrack,
          init: audioConfiguration
        ) else {
          throw ClipLiveShareNativeV3WebRTCPeerLinkError
            .audioTransceiverCreationFailed
        }
        try Self.applyAudioCodecPreference(
          capabilities: audioCodecCapabilities,
          to: audioTransceiver
        )
        Self.applyAudioSenderPolicy(to: audioTransceiver.sender)
        Self.setSender(
          audioTransceiver.sender,
          active: outboundMediaEnabled
        )
        self.audioTransceiver = audioTransceiver

        let channelConfiguration = RTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        channelConfiguration.maxPacketLifeTime = -1
        channelConfiguration.maxRetransmits = -1
        channelConfiguration.isNegotiated = false
        guard let channel = connection.dataChannel(
          forLabel: linkConfiguration.controlChannel.label,
          configuration: channelConfiguration
        ) else {
          throw ClipLiveShareNativeV3WebRTCPeerLinkError
            .dataChannelCreationFailed
        }
        controlChannel = channel
        channel.delegate = delegate
        controlChannelState = Self.controlState(channel.readyState)
      }
    } catch {
      delegate.detach()
      connection.delegate = nil
      connection.close()
      throw error
    }

    queue.setSpecific(key: queueKey, value: 1)
    delegate.attach(to: self)
  }

  deinit {
    onQueue {
      closeOnQueue()
    }
  }

  public func events() async
    -> AsyncStream<ClipLiveShareNativeV3PeerLinkTransportEvent>
  {
    onQueue {
      let id = UUID()
      let (stream, continuation) = AsyncStream.makeStream(
        of: ClipLiveShareNativeV3PeerLinkTransportEvent.self,
        bufferingPolicy: .bufferingNewest(256)
      )
      guard !isClosed else {
        continuation.finish()
        return stream
      }
      continuations[id] = continuation
      continuation.onTermination = { [weak self] _ in
        self?.queue.async { [weak self] in
          self?.continuations[id] = nil
        }
      }
      return stream
    }
  }

  public func start() async throws {
    let shouldOffer = try onQueue { () throws -> Bool in
      try ensureOpen()
      guard !didStart else { return false }
      didStart = true
      return linkConfiguration.role == .offerer
    }
    if shouldOffer {
      try await requestNegotiation()
    }
  }

  public func requestNegotiation() async throws {
    guard try beginOfferNegotiationOrDefer() else { return }
    do {
      let rtcOffer = try await createDescription(kind: .offer)
      let configured = RTCSessionDescription(
        type: .offer,
        sdp: WebRTCOpusMusicSDP.applying(
          to: WebRTCH264EncoderFactory.upgradingProfileLevels(in: rtcOffer.sdp)
        )
      )
      try await setLocalDescription(configured)
      emit(
        .localNegotiation(
          .sessionDescription(.init(kind: .offer, sdp: configured.sdp))
        )
      )
      finishNegotiation()
    } catch {
      onQueue { explicitCodecNegotiationPending = false }
      finishNegotiation()
      throw error
    }
  }

  public func applyRemoteDescription(
    _ description: WebRTCSessionDescription
  ) async throws {
    guard description.sdp.utf8.count <= resourceLimits.maximumSDPPayloadBytes else {
      throw ClipLiveShareNativeV3WebRTCPeerLinkError
        .sessionDescriptionTooLarge(
          maximumBytes: resourceLimits.maximumSDPPayloadBytes
        )
    }
    switch description.kind {
    case .offer:
      do {
        try await applyRemoteOffer(description)
      } catch {
        onQueue { explicitCodecNegotiationPending = false }
        throw error
      }
    case .answer:
      try beginNegotiation()
      do {
        let state = onQueue { connection.signalingState }
        guard state == .haveLocalOffer else {
          throw ClipLiveShareNativeV3WebRTCPeerLinkError
            .invalidSessionDescriptionKind
        }
        try await setRemoteDescription(
          RTCSessionDescription(type: .answer, sdp: description.sdp)
        )
        await flushPendingRemoteICECandidates()
        onQueue { explicitCodecNegotiationPending = false }
        finishNegotiation()
      } catch {
        onQueue { explicitCodecNegotiationPending = false }
        finishNegotiation()
        throw error
      }
      try await drainPendingOfferRequestIfNeeded()
    }
  }

  public func addRemoteICECandidate(
    _ candidate: WebRTCICECandidate
  ) async throws {
    do {
      try candidate.validate(resourceLimits: resourceLimits)
    } catch {
      throw ClipLiveShareNativeV3WebRTCPeerLinkError.invalidICECandidate(
        error.localizedDescription
      )
    }
    let shouldQueue = try onQueue { () throws -> Bool in
      try ensureOpen()
      guard remoteICECandidateCount
        < resourceLimits.maximumICECandidatesPerPeer
      else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError
          .iceCandidateLimitReached(
            maximum: resourceLimits.maximumICECandidatesPerPeer
          )
      }
      remoteICECandidateCount += 1
      if !remoteDescriptionApplied {
        pendingRemoteICECandidates.append(candidate)
        return true
      }
      return false
    }
    if !shouldQueue {
      try await apply(candidate)
    }
  }

  public func sendControlMessage(_ data: Data) async throws {
    try onQueue {
      try ensureOpen()
      guard let controlChannel, controlChannel.readyState == .open else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError
          .controlChannelUnavailable
      }
      guard controlBufferPolicy.permits(
        payloadByteCount: data.count,
        bufferedAmountBytes: controlChannel.bufferedAmount
      ) else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.controlBackpressure
      }
      guard controlChannel.sendData(
        RTCDataBuffer(data: data, isBinary: true)
      ) else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.controlBackpressure
      }
    }
  }

  /// Sends a replaceable cursor sample directly to the native DataChannel.
  /// Unlike durable control state, a sample that encounters pressure is
  /// dropped rather than queued or surfaced as a peer failure.
  public func sendEphemeralControlMessage(_ data: Data) async -> Bool {
    onQueue {
      guard !isClosed,
        let controlChannel,
        controlChannel.readyState == .open,
        controlBufferPolicy.permits(
          payloadByteCount: data.count,
          bufferedAmountBytes: controlChannel.bufferedAmount
        )
      else {
        return false
      }
      return controlChannel.sendData(
        RTCDataBuffer(data: data, isBinary: true)
      )
    }
  }

  public func remoteVideoStream(
    for descriptor: ClipLiveShareStreamDescriptor
  ) async -> WebRTCRemoteVideoStream? {
    onQueue {
      guard let track = remoteVideoTracks[descriptor.mediaTrackID] else {
        return nil
      }
      return WebRTCRemoteVideoStream(descriptor: descriptor, track: track)
    }
  }

  /// Gates outbound RTP on this peer only. The shared local tracks remain
  /// enabled for already-committed peers, while all four video encodings and
  /// participant audio stay inactive on a provisional candidate link.
  public func setOutboundMediaEnabled(_ enabled: Bool) async {
    onQueue {
      guard !isClosed else { return }
      outboundMediaEnabled = enabled
      for transceiver in videoTransceivers {
        Self.setSender(transceiver.sender, active: enabled)
      }
      if let audioTransceiver {
        Self.setSender(audioTransceiver.sender, active: enabled)
      }
      if enabled {
        applyPeerBandwidthPolicy()
      }
    }
  }

  public func updateSenderPolicy(_ policy: WebRTCSenderPolicy) async {
    onQueue {
      guard !isClosed else { return }
      let previousEnvelope = peerBandwidthEnvelope()
      senderPolicy = policy
      for transceiver in videoTransceivers {
        Self.applySenderPolicy(policy, to: transceiver.sender)
      }
      let nextEnvelope = peerBandwidthEnvelope()
      if videoEncodingMode == .quality,
        (nextEnvelope?.maximumBitrateBps ?? 0)
          > (previousEnvelope?.maximumBitrateBps ?? 0)
      {
        bandwidthSeedPending = true
      }
      applyPeerBandwidthPolicy()
    }
  }

  fileprivate func updateLocalVideoEncodingMode(
    _ mode: LiveShareEncodingMode
  ) {
    onQueue {
      guard !isClosed else { return }
      if mode == .quality, videoEncodingMode != .quality,
        activeLocalVideoSourceCount > 0
      {
        bandwidthSeedPending = true
      }
      videoEncodingMode = mode
      if mode != .quality { bandwidthSeedPending = false }
      applyPeerBandwidthPolicy()
    }
  }

  fileprivate func updateActiveLocalVideoSourceCount(_ count: Int) {
    onQueue {
      guard !isClosed else { return }
      let previousCount = activeLocalVideoSourceCount
      activeLocalVideoSourceCount = max(0, count)
      if activeLocalVideoSourceCount == 0 {
        bandwidthSeedPending = false
        clearPeerBandwidthPolicyAfterLastVideo()
        return
      }
      if previousCount == 0, videoEncodingMode == .quality {
        bandwidthSeedPending = true
      }
      applyPeerBandwidthPolicy()
    }
  }

  /// The server-coordinated room currently applies one complete fallback
  /// policy to every active slot. Retain that contract while also carrying the
  /// encoding mode into the peer-wide bandwidth seed state.
  public func updateSenderPolicies(
    _ policiesBySlot: [Int: WebRTCSenderPolicy],
    fallback: WebRTCSenderPolicy,
    videoEncodingMode: LiveShareEncodingMode
  ) async {
    _ = policiesBySlot
    updateLocalVideoEncodingMode(videoEncodingMode)
    await updateSenderPolicy(fallback)
  }

  public func updateVideoCodecPreference(
    _ codec: WebRTCVideoCodec
  ) async throws {
    try setVideoCodecPreference(codec, expectsExplicitNegotiation: true)
  }

  public func restoreVideoCodecPreference(
    _ codec: WebRTCVideoCodec
  ) async throws {
    try setVideoCodecPreference(codec, expectsExplicitNegotiation: false)
  }

  public func currentVideoCodecPreference() async -> WebRTCVideoCodec? {
    onQueue { isClosed ? nil : videoCodec }
  }

  private func setVideoCodecPreference(
    _ codec: WebRTCVideoCodec,
    expectsExplicitNegotiation: Bool
  ) throws {
    try onQueue {
      try ensureOpen()
      guard videoCodecCapabilities.contains(where: {
        $0.name.caseInsensitiveCompare(codec.rtcName) == .orderedSame
      }) else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError
          .videoCodecUnavailable(codec)
      }
      for transceiver in videoTransceivers {
        try Self.applyVideoCodecPreference(
          codec,
          policy: videoCodecNegotiationPolicy,
          capabilities: videoCodecCapabilities,
          to: transceiver
        )
      }
      videoCodec = codec
      explicitCodecNegotiationPending = expectsExplicitNegotiation
    }
  }

  public func rollbackLocalOfferIfNeeded() async throws {
    let state = try onQueue { () throws -> RTCSignalingState in
      try ensureOpen()
      return connection.signalingState
    }
    switch state {
    case .stable:
      onQueue { explicitCodecNegotiationPending = false }
      return
    case .haveLocalOffer, .haveLocalPrAnswer:
      try await setLocalDescription(
        RTCSessionDescription(type: .rollback, sdp: "")
      )
      onQueue {
        hasPendingOfferRequest = false
        explicitCodecNegotiationPending = false
      }
    case .haveRemoteOffer, .haveRemotePrAnswer, .closed:
      throw ClipLiveShareNativeV3WebRTCPeerLinkError
        .invalidSessionDescriptionKind
    @unknown default:
      throw ClipLiveShareNativeV3WebRTCPeerLinkError
        .invalidSessionDescriptionKind
    }
  }

  public func setRemoteParticipantAudioPlaybackEnabled(_ enabled: Bool) async {
    onQueue {
      remoteParticipantAudioPlaybackEnabled = enabled
      remoteParticipantAudioTrack?.isEnabled = enabled
    }
  }

  public func setRemoteParticipantAudioVolume(_ volume: Double) async {
    onQueue {
      remoteParticipantAudioVolume = min(max(volume, 0), 1)
      remoteParticipantAudioTrack?.source.volume =
        remoteParticipantAudioVolume
    }
  }

  public func restartICE() async throws {
    let shouldCreateOffer = try onQueue {
      try ensureOpen()
      connection.restartIce()
      return linkConfiguration.role == .offerer
    }
    // Native-v3 uses the lower participant ID as the permanent offerer. Both
    // endpoints may observe the same ICE failure, but the answerer must only
    // prepare to consume the canonical peer's restart offer; originating a
    // second offer would violate the signed pair context and create glare.
    if shouldCreateOffer {
      try await requestNegotiation()
    }
  }

  public func statistics() async throws
    -> ClipLiveShareNativeV3PeerLinkTransportStatistics
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do {
          try ensureOpen()
          connection.statistics { [weak self] report in
            guard let self else {
              continuation.resume(
                throwing:
                  ClipLiveShareNativeV3WebRTCPeerLinkError.transportClosed
              )
              return
            }
            queue.async { [self] in
              guard !isClosed else {
                continuation.resume(
                  throwing:
                    ClipLiveShareNativeV3WebRTCPeerLinkError.transportClosed
                )
                return
              }
              let statistics =
                ClipLiveShareNativeV3WebRTCStatisticsParser.parse(
                  report,
                  trackIdentifiersByMID: statisticsTrackIdentifiersByMID()
                )
              route = statistics.route
              continuation.resume(returning: statistics)
            }
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func statisticsTrackIdentifiersByMID()
    -> ClipLiveShareNativeV3WebRTCTrackIdentifiersByMID
  {
    var outgoing: [String: String] = [:]
    var incoming: [String: String] = [:]
    for transceiver in videoTransceivers {
      let mid = transceiver.mid
      guard !mid.isEmpty else { continue }
      if let trackID = transceiver.sender.track?.trackId, !trackID.isEmpty {
        outgoing[mid] = trackID
      }
      if let trackID = transceiver.receiver.track?.trackId, !trackID.isEmpty {
        incoming[mid] = remoteTrackIdentifiersByMID[mid] ?? trackID
      }
    }
    return .init(outgoing: outgoing, incoming: incoming)
  }

  public func close() async {
    onQueue {
      closeOnQueue()
    }
  }

  fileprivate func handle(
    _ event: ClipLiveShareNativeV3WebRTCPeerDelegate.Event,
    connection callbackConnection: RTCPeerConnection? = nil
  ) {
    queue.async { [self] in
      guard
        !isClosed,
        callbackConnection == nil || callbackConnection === connection
      else { return }
      switch event {
      case let .localICECandidate(candidate):
        guard localICECandidateCount
          < resourceLimits.maximumICECandidatesPerPeer
        else { return }
        localICECandidateCount += 1
        emit(.localNegotiation(.iceCandidate(candidate)))
      case let .connectionStateChanged(state):
        guard connectionState != state else { return }
        connectionState = state
        if state == .connected {
          applyPeerBandwidthPolicy()
        }
        emit(.connectionStateChanged(state))
      case let .dataChannelOpened(channel):
        acceptDataChannel(channel)
      case let .dataChannelStateChanged(channel, state):
        guard channel === controlChannel, state != controlChannelState else {
          return
        }
        controlChannelState = state
        emit(.controlChannelStateChanged(state))
      case let .controlMessage(channel, data):
        guard channel === controlChannel else { return }
        guard data.count <= resourceLimits.maximumControlMessagePayloadBytes else {
          emit(.failed(
            ClipLiveShareNativeV3WebRTCPeerLinkError.controlBackpressure
              .localizedDescription
          ))
          return
        }
        emit(.controlMessageReceived(data))
      case .negotiationNeeded:
        guard !explicitCodecNegotiationPending else { return }
        emit(.negotiationNeeded)
      case .receiverAdded:
        // Receiver callbacks may arrive before setRemoteDescription's
        // completion and can expose libwebrtc placeholder track IDs. The
        // completion reconciles the authoritative transceiver/MID mapping.
        guard remoteDescriptionApplied else { return }
        reconcileRemoteReceivers()
      case let .receiverRemoved(receiverID):
        removeReceiver(receiverID)
      case let .failed(message):
        emit(.failed(message))
      case let .iceGatheringDiagnostic(code, url, message):
        emit(.iceGatheringDiagnostic(
          code: code,
          url: url,
          message: message
        ))
      }
    }
  }

  private func applyRemoteOffer(
    _ description: WebRTCSessionDescription
  ) async throws {
    try beginNegotiation()
    defer { finishNegotiation() }

    let state = onQueue { connection.signalingState }
    if state != .stable {
      guard linkConfiguration.role == .answerer else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError.offerCollision
      }
      try await setLocalDescription(
        RTCSessionDescription(type: .rollback, sdp: "")
      )
    }
    try WebRTCOfferMediaSectionPolicy.validate(
      description.sdp,
      resourceLimits: resourceLimits
    )
    // Native peers keep Clip's established asymmetric preference ladder. When
    // the canonical offerer changes codec, align the answerer's transceivers
    // to that offer before creating the answer. Do not override an answerer
    // that is itself waiting for its requested codec exchange, and never infer
    // a fallback codec for an exact Web edge.
    let shouldAdoptOfferedCodec = onQueue {
      videoCodecNegotiationPolicy == .nativeCompatible
        && !explicitCodecNegotiationPending
    }
    if shouldAdoptOfferedCodec,
      let offeredCodec = Self.preferredVideoCodec(in: description.sdp)
    {
      try setVideoCodecPreference(
        offeredCodec,
        expectsExplicitNegotiation: false
      )
    }
    try await setRemoteDescription(
      RTCSessionDescription(type: .offer, sdp: description.sdp)
    )
    try attachAnswererOutboundMediaIfNeeded()
    await flushPendingRemoteICECandidates()
    let rtcAnswer = try await createDescription(kind: .answer)
    let configured = RTCSessionDescription(
      type: .answer,
      sdp: Self.rewritingLocalMediaIdentifiers(
        in: WebRTCOpusMusicSDP.applying(to: rtcAnswer.sdp),
        identifiersByMID: localMediaIdentifiersByMID()
      )
    )
    try await setLocalDescription(configured)
    onQueue { explicitCodecNegotiationPending = false }
    emit(
      .localNegotiation(
        .sessionDescription(.init(kind: .answer, sdp: configured.sdp))
      )
    )
  }

  private func createDescription(
    kind: WebRTCSessionDescription.Kind
  ) async throws -> RTCSessionDescription {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do {
          try ensureOpen()
          let completion:
            @Sendable (RTCSessionDescription?, (any Error)?) -> Void = {
            [weak self] description, error in
            guard let self else {
              continuation.resume(
                throwing:
                  ClipLiveShareNativeV3WebRTCPeerLinkError.transportClosed
              )
              return
            }
            queue.async {
              if let error {
                continuation.resume(
                  throwing:
                    ClipLiveShareNativeV3WebRTCPeerLinkError
                    .localDescriptionCreationFailed(
                      error.localizedDescription
                    )
                )
              } else if let description {
                continuation.resume(returning: description)
              } else {
                continuation.resume(
                  throwing:
                    ClipLiveShareNativeV3WebRTCPeerLinkError
                    .localDescriptionCreationFailed(
                      "libwebrtc returned no description"
                    )
                )
              }
            }
          }
          let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
          )
          if kind == .offer {
            connection.offer(for: constraints, completionHandler: completion)
          } else {
            connection.answer(for: constraints, completionHandler: completion)
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func setLocalDescription(
    _ description: RTCSessionDescription
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      queue.async { [self] in
        do {
          try ensureOpen()
          connection.setLocalDescription(description) { error in
            self.queue.async {
              if let error {
                continuation.resume(
                  throwing:
                    ClipLiveShareNativeV3WebRTCPeerLinkError
                    .localDescriptionApplicationFailed(
                      error.localizedDescription
                    )
                )
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

  private func setRemoteDescription(
    _ description: RTCSessionDescription
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      queue.async { [self] in
        do {
          try ensureOpen()
          connection.setRemoteDescription(description) { [weak self] error in
            guard let self else {
              continuation.resume(
                throwing:
                  ClipLiveShareNativeV3WebRTCPeerLinkError.transportClosed
              )
              return
            }
            queue.async { [self] in
              if let error {
                continuation.resume(
                  throwing:
                    ClipLiveShareNativeV3WebRTCPeerLinkError
                    .remoteDescriptionApplicationFailed(
                      error.localizedDescription
                    )
                )
              } else {
                remoteTrackIdentifiersByMID =
                  Self.trackIdentifiersByMID(in: description.sdp)
                remoteDescriptionApplied = true
                reconcileRemoteReceivers()
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

  private func apply(_ candidate: WebRTCICECandidate) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      queue.async { [self] in
        do {
          try ensureOpen()
          connection.add(
            RTCIceCandidate(
              sdp: candidate.candidate,
              sdpMLineIndex: candidate.sdpMLineIndex,
              sdpMid: candidate.sdpMid
            )
          ) { error in
            self.queue.async {
              if let error {
                continuation.resume(
                  throwing:
                    ClipLiveShareNativeV3WebRTCPeerLinkError
                    .iceCandidateApplicationFailed(
                      error.localizedDescription
                    )
                )
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

  private func flushPendingRemoteICECandidates() async {
    let candidates = onQueue { () -> [WebRTCICECandidate] in
      let result = pendingRemoteICECandidates
      pendingRemoteICECandidates.removeAll(keepingCapacity: true)
      return result
    }
    for candidate in candidates {
      do {
        try await apply(candidate)
      } catch {
        emit(.failed(error.localizedDescription))
      }
    }
  }

  private func acceptDataChannel(_ channel: RTCDataChannel) {
    guard
      channel.label == linkConfiguration.controlChannel.label,
      channel.isOrdered,
      controlChannel == nil
    else {
      channel.close()
      emit(
        .failed(
          ClipLiveShareNativeV3WebRTCPeerLinkError
            .unexpectedDataChannel(channel.label).localizedDescription
        )
      )
      return
    }
    controlChannel = channel
    channel.delegate = delegate
    controlChannelState = Self.controlState(channel.readyState)
    emit(.controlChannelStateChanged(controlChannelState))
  }

  private func receive(
    _ track: RTCMediaStreamTrack,
    receiverID: String,
    advertisedTrackID: String
  ) {
    guard videoTrackIDsByReceiverID[receiverID] == nil,
      participantAudioReceiverID != receiverID
    else { return }
    if let videoTrack = track as? RTCVideoTrack {
      guard
        remoteVideoTracks.count
          < ClipLiveShareNativeV3.reservedVideoSlotsPerParticipant,
        let trackID = try? ClipLiveShareMediaTrackID(
          rawValue: advertisedTrackID
        )
      else {
        videoTrack.isEnabled = false
        return
      }
      videoTrackIDsByReceiverID[receiverID] = trackID
      guard remoteVideoTracks[trackID] == nil else { return }
      videoTrack.isEnabled = true
      remoteVideoTracks[trackID] = WebRTCRemoteVideoTrackHandle(
        track: videoTrack
      )
      emit(.remoteVideoTrackAdded(trackID))
      return
    }
    if let audioTrack = track as? RTCAudioTrack {
      guard remoteParticipantAudioTrack == nil else {
        audioTrack.isEnabled = false
        return
      }
      participantAudioReceiverID = receiverID
      remoteParticipantAudioTrack = audioTrack
      remoteParticipantAudioTrackID = advertisedTrackID
      audioTrack.isEnabled = remoteParticipantAudioPlaybackEnabled
      audioTrack.source.volume = remoteParticipantAudioVolume
      emit(.remoteParticipantAudioAvailable(trackID: advertisedTrackID))
    }
  }

  /// Unified Plan creates the offerer's receiving transceivers before an
  /// answer is applied. libwebrtc does not consistently call
  /// `didAdd receiver` for those pre-existing receivers, even though their
  /// tracks become usable once the remote answer is installed. Reconcile the
  /// authoritative receiver list after every remote description so both
  /// endpoints expose the same symmetric media layout. `receive` is
  /// idempotent by receiver and track identifier, so delegate callbacks and
  /// this reconciliation cannot publish duplicate track events.
  private func reconcileRemoteReceivers() {
    for transceiver in connection.transceivers {
      let receiver = transceiver.receiver
      guard
        let track = receiver.track,
        let advertisedTrackID =
          remoteTrackIdentifiersByMID[transceiver.mid]
      else { continue }
      receive(
        track,
        receiverID: receiver.receiverId,
        advertisedTrackID: advertisedTrackID
      )
    }
  }

  /// An answerer must bind its local tracks to the transceivers created from
  /// the remote offer. Pre-creating a second set of transceivers makes
  /// libwebrtc answer `recvonly` on the offered m-lines and defers the local
  /// tracks to an unnecessary second negotiation. `addTrack` follows Unified
  /// Plan's reuse algorithm, yielding one symmetric four-video/one-audio
  /// layout in the initial offer/answer exchange.
  private func attachAnswererOutboundMediaIfNeeded() throws {
    try onQueue {
      guard linkConfiguration.role == .answerer else { return }
      guard videoTransceivers.isEmpty, audioTransceiver == nil else { return }

      var addedSenders: [RTCRtpSender] = []
      var attachedVideoTransceivers: [RTCRtpTransceiver] = []
      do {
        for slot in localVideoSlots {
          guard
            let sender = connection.add(
              slot.track,
              streamIds: [slot.streamID]
            ),
            let transceiver = connection.transceivers.first(where: {
              $0.sender.senderId == sender.senderId
            })
          else {
            throw ClipLiveShareNativeV3WebRTCPeerLinkError
              .videoTransceiverCreationFailed(slot: slot.index)
          }
          addedSenders.append(sender)
          try Self.applyVideoCodecPreference(
            videoCodec,
            policy: videoCodecNegotiationPolicy,
            capabilities: videoCodecCapabilities,
            to: transceiver
          )
          Self.applySenderPolicy(senderPolicy, to: sender)
          Self.setSender(sender, active: outboundMediaEnabled)
          attachedVideoTransceivers.append(transceiver)
        }

        guard
          let audioSender = connection.add(
            localParticipantAudioTrack,
            streamIds: [localParticipantAudioStreamID]
          ),
          let attachedAudioTransceiver =
            connection.transceivers.first(where: {
              $0.sender.senderId == audioSender.senderId
            })
        else {
          throw ClipLiveShareNativeV3WebRTCPeerLinkError
            .audioTransceiverCreationFailed
        }
        addedSenders.append(audioSender)
        try Self.applyAudioCodecPreference(
          capabilities: audioCodecCapabilities,
          to: attachedAudioTransceiver
        )
        Self.applyAudioSenderPolicy(to: audioSender)
        Self.setSender(audioSender, active: outboundMediaEnabled)

        videoTransceivers = attachedVideoTransceivers
        audioTransceiver = attachedAudioTransceiver
      } catch {
        for sender in addedSenders {
          _ = connection.removeTrack(sender)
        }
        throw error
      }
    }
  }

  private func localMediaIdentifiersByMID()
    -> [String: LocalMediaIdentifier]
  {
    onQueue {
      var identifiers: [String: LocalMediaIdentifier] = [:]
      for (slot, transceiver) in zip(localVideoSlots, videoTransceivers) {
        guard !transceiver.mid.isEmpty else { continue }
        identifiers[transceiver.mid] = .init(
          streamID: slot.streamID,
          trackID: slot.trackID
        )
      }
      if let audioTransceiver, !audioTransceiver.mid.isEmpty {
        identifiers[audioTransceiver.mid] = .init(
          streamID: localParticipantAudioStreamID,
          trackID: localParticipantAudioTrack.trackId
        )
      }
      return identifiers
    }
  }

  /// The Objective-C `addTrack` bridge assigns generated msid identifiers when
  /// it reuses transceivers created by a remote offer. Clip's source manifests
  /// use the factory's stable track identifiers across every pair, so rewrite
  /// only the answer's local msid attributes to those stable values before the
  /// description is installed. Codec, ICE, DTLS, directions, and RTP payloads
  /// remain untouched.
  private static func rewritingLocalMediaIdentifiers(
    in sdp: String,
    identifiersByMID: [String: LocalMediaIdentifier]
  ) -> String {
    let usesCRLF = sdp.contains("\r\n")
    let separator = usesCRLF ? "\r\n" : "\n"
    var lines = sdp.components(separatedBy: separator)
    var sectionStart: Int?

    func rewriteSection(_ range: Range<Int>) {
      guard
        let midLine = lines[range].first(where: { $0.hasPrefix("a=mid:") }),
        let identifiers = identifiersByMID[
          String(midLine.dropFirst("a=mid:".count))
        ]
      else { return }

      for index in range {
        let line = lines[index]
        if line.hasPrefix("a=msid:") {
          lines[index] =
            "a=msid:\(identifiers.streamID) \(identifiers.trackID)"
        } else if let marker = line.range(of: " msid:") {
          lines[index] =
            String(line[..<marker.upperBound])
            + "\(identifiers.streamID) \(identifiers.trackID)"
        } else if let marker = line.range(of: " mslabel:") {
          lines[index] =
            String(line[..<marker.upperBound]) + identifiers.streamID
        } else if let marker = line.range(of: " label:") {
          lines[index] =
            String(line[..<marker.upperBound]) + identifiers.trackID
        }
      }
    }

    for index in lines.indices where lines[index].hasPrefix("m=") {
      if let sectionStart {
        rewriteSection(sectionStart..<index)
      }
      sectionStart = index
    }
    if let sectionStart {
      rewriteSection(sectionStart..<lines.endIndex)
    }
    return lines.joined(separator: separator)
  }

  private static func trackIdentifiersByMID(
    in sdp: String
  ) -> [String: String] {
    let normalized = sdp.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    var result: [String: String] = [:]
    var sectionStart: Int?

    func inspectSection(_ range: Range<Int>) {
      guard
        let midLine = lines[range].first(where: { $0.hasPrefix("a=mid:") }),
        let msidLine = lines[range].first(where: { $0.hasPrefix("a=msid:") })
      else { return }
      let mid = String(midLine.dropFirst("a=mid:".count))
      let identifiers = msidLine
        .dropFirst("a=msid:".count)
        .split(whereSeparator: \.isWhitespace)
      guard
        !mid.isEmpty,
        identifiers.count >= 2,
        result.count
          < ClipLiveShareNativeV3.reservedVideoSlotsPerParticipant + 1
      else { return }
      result[mid] = String(identifiers[1])
    }

    for index in lines.indices where lines[index].hasPrefix("m=") {
      if let sectionStart {
        inspectSection(sectionStart..<index)
      }
      sectionStart = index
    }
    if let sectionStart {
      inspectSection(sectionStart..<lines.endIndex)
    }
    return result
  }

  private func removeReceiver(_ receiverID: String) {
    if let trackID = videoTrackIDsByReceiverID.removeValue(
      forKey: receiverID
    ) {
      remoteVideoTracks.removeValue(forKey: trackID)?.invalidate()
      emit(.remoteVideoTrackRemoved(trackID))
      return
    }
    guard participantAudioReceiverID == receiverID else { return }
    participantAudioReceiverID = nil
    if let trackID = remoteParticipantAudioTrackID {
      remoteParticipantAudioTrack?.isEnabled = false
      remoteParticipantAudioTrack = nil
      remoteParticipantAudioTrackID = nil
      emit(.remoteParticipantAudioRemoved(trackID: trackID))
    }
  }

  private func beginNegotiation() throws {
    try onQueue {
      try ensureOpen()
      guard !isNegotiating else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError
          .negotiationInProgress
      }
      isNegotiating = true
      localICECandidateCount = 0
      remoteICECandidateCount = pendingRemoteICECandidates.count
    }
  }

  private func beginOfferNegotiationOrDefer() throws -> Bool {
    try onQueue {
      try ensureOpen()
      guard linkConfiguration.role == .offerer else {
        throw ClipLiveShareNativeV3WebRTCPeerLinkError
          .invalidSessionDescriptionKind
      }
      guard !isNegotiating, connection.signalingState == .stable else {
        hasPendingOfferRequest = true
        return false
      }
      isNegotiating = true
      hasPendingOfferRequest = false
      localICECandidateCount = 0
      remoteICECandidateCount = pendingRemoteICECandidates.count
      return true
    }
  }

  private func drainPendingOfferRequestIfNeeded() async throws {
    let shouldDrain = onQueue { () -> Bool in
      guard hasPendingOfferRequest,
        !isNegotiating,
        connection.signalingState == .stable,
        linkConfiguration.role == .offerer
      else { return false }
      hasPendingOfferRequest = false
      return true
    }
    if shouldDrain {
      try await requestNegotiation()
    }
  }

  private func finishNegotiation() {
    onQueue {
      isNegotiating = false
    }
  }

  private func closeOnQueue() {
    guard !isClosed else { return }
    isClosed = true
    isNegotiating = false
    hasPendingOfferRequest = false
    explicitCodecNegotiationPending = false
    pendingRemoteICECandidates.removeAll(keepingCapacity: false)
    delegate.detach()
    connection.delegate = nil
    if let controlChannel {
      controlChannel.delegate = nil
      controlChannel.close()
      self.controlChannel = nil
    }
    for (trackID, track) in remoteVideoTracks {
      track.invalidate()
      emit(.remoteVideoTrackRemoved(trackID))
    }
    remoteVideoTracks.removeAll(keepingCapacity: false)
    videoTrackIDsByReceiverID.removeAll(keepingCapacity: false)
    if let trackID = remoteParticipantAudioTrackID {
      remoteParticipantAudioTrack?.isEnabled = false
      remoteParticipantAudioTrack = nil
      remoteParticipantAudioTrackID = nil
      participantAudioReceiverID = nil
      emit(.remoteParticipantAudioRemoved(trackID: trackID))
    }
    connection.close()
    connectionState = .closed
    controlChannelState = .closed
    for continuation in continuations.values {
      continuation.finish()
    }
    continuations.removeAll(keepingCapacity: false)
  }

  private func ensureOpen() throws {
    guard !isClosed else {
      throw ClipLiveShareNativeV3WebRTCPeerLinkError.transportClosed
    }
  }

  private func emit(
    _ event: ClipLiveShareNativeV3PeerLinkTransportEvent
  ) {
    onQueue {
      for continuation in continuations.values {
        continuation.yield(event)
      }
    }
  }

  @discardableResult
  private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try work()
    }
    return try queue.sync(execute: work)
  }

  private static func controlState(
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

  private static func applyVideoCodecPreference(
    _ codec: WebRTCVideoCodec,
    policy: WebRTCVideoCodecNegotiationPolicy,
    capabilities: [RTCRtpCodecCapability],
    to transceiver: RTCRtpTransceiver
  ) throws {
    let preferences = videoCodecPreferenceNames(
      for: codec,
      policy: policy
    ).flatMap { name in
      capabilities.filter {
        $0.name.caseInsensitiveCompare(name) == .orderedSame
      }
    }
    guard !preferences.isEmpty else {
      throw ClipLiveShareNativeV3WebRTCPeerLinkError
        .videoCodecUnavailable(codec)
    }
    do {
      try transceiver.setCodecPreferences(preferences, error: ())
    } catch {
      throw ClipLiveShareNativeV3WebRTCPeerLinkError
        .codecPreferenceFailed(error.localizedDescription)
    }
  }

  /// Returns SDP preference order only. A transceiver negotiates one codec
  /// from this list and therefore creates one encoder, never parallel fallback
  /// encodings. Web edges remain exact so an unsupported browser gets
  /// unavailable video rather than transcoding. Native edges preserve the
  /// pre-Web-viewer ladder verbatim; changing networking must not change Clip's
  /// established encoder negotiation behavior.
  static func videoCodecPreferenceNames(
    for codec: WebRTCVideoCodec,
    policy: WebRTCVideoCodecNegotiationPolicy = .exact
  ) -> [String] {
    switch policy {
    case .exact:
      [codec.rtcName]
    case .nativeCompatible:
      switch codec {
      case .av1:
        [
          codec.rtcName,
          WebRTCVideoCodec.vp9.rtcName,
          WebRTCVideoCodec.vp8.rtcName,
        ]
      case .vp9:
        [codec.rtcName, WebRTCVideoCodec.vp8.rtcName]
      case .h264, .vp8:
        [codec.rtcName]
      }
    }
  }

  /// Reads the first real video codec in the first video m-line. Auxiliary
  /// RTX/RED/FEC payloads are ignored. Every standard Native-v3 video m-line
  /// uses the same preference order, so one is sufficient to align the answer.
  private static func preferredVideoCodec(
    in sdp: String
  ) -> WebRTCVideoCodec? {
    let lines = sdp.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n")
    var codecsByPayload: [String: WebRTCVideoCodec] = [:]
    for line in lines where line.hasPrefix("a=rtpmap:") {
      let parts = line.dropFirst("a=rtpmap:".count)
        .split(separator: " ", maxSplits: 1)
      guard parts.count == 2,
        let name = parts.last?
          .split(separator: "/", maxSplits: 1)
          .first
          .map(String.init),
        let codec = WebRTCVideoCodec.allCases.first(where: {
          $0.rtcName.caseInsensitiveCompare(name) == .orderedSame
        })
      else { continue }
      codecsByPayload[String(parts[0])] = codec
    }
    guard let videoLine = lines.first(where: { $0.hasPrefix("m=video ") })
    else { return nil }
    return videoLine.split(whereSeparator: \.isWhitespace)
      .dropFirst(3)
      .lazy
      .compactMap { codecsByPayload[String($0)] }
      .first
  }

  private static func applyAudioCodecPreference(
    capabilities: [RTCRtpCodecCapability],
    to transceiver: RTCRtpTransceiver
  ) throws {
    let opus = capabilities.filter {
      $0.name.caseInsensitiveCompare("opus") == .orderedSame
    }
    guard !opus.isEmpty else {
      throw ClipLiveShareNativeV3WebRTCPeerLinkError
        .codecPreferenceFailed("Opus is unavailable")
    }
    do {
      try transceiver.setCodecPreferences(opus, error: ())
    } catch {
      throw ClipLiveShareNativeV3WebRTCPeerLinkError
        .codecPreferenceFailed(error.localizedDescription)
    }
  }

  /// Per-sender maxima do not initialize libwebrtc's peer-wide bandwidth
  /// estimator. Without this one-time seed a new edge begins near WebRTC's
  /// ~300 kbps default even when the user selected a 20 Mbps quality budget.
  /// Seed every Native and Web edge from the same policy, once the connection
  /// is usable and the first local source is active. Later updates preserve
  /// the learned estimate unless the user explicitly raises the quality
  /// budget or returns to Quality mode.
  private func peerBandwidthEnvelope() -> NativeV3PeerBandwidthEnvelope? {
    guard activeLocalVideoSourceCount > 0 else { return nil }
    return NativeV3PeerBandwidthEnvelope.make(
      activeVideoPolicies: Array(
        repeating: senderPolicy,
        count: activeLocalVideoSourceCount
      ),
      preferredInitialVideoBitrateBps: .max,
      auxiliaryBitrateBps: WebRTCOpusMusicSDP.maximumAverageBitrateBps
    )
  }

  private func applyPeerBandwidthPolicy() {
    let conditions = NativeV3PeerBandwidthConditions(
      isConnected: connectionState == .connected,
      outboundMediaEnabled: outboundMediaEnabled,
      activeVideoSourceCount: activeLocalVideoSourceCount,
      videoEncodingMode: videoEncodingMode
    )
    guard !isClosed, conditions.canApply,
      let envelope = peerBandwidthEnvelope()
    else { return }

    let shouldSeed = conditions.shouldSeed(
      seedPending: bandwidthSeedPending,
      hasSeededCurrentEstimate:
        bandwidthApplicationState.hasSeededCurrentEstimate
    )
    guard let transition = bandwidthApplicationState.transition(
      to: envelope,
      seedCurrentEstimate: shouldSeed
    ) else { return }

    let update = transition.update
    let accepted = connection.setBweMinBitrateBps(
      update.minimumBitrateBps.map(NSNumber.init),
      currentBitrateBps: update.currentBitrateBps.map(NSNumber.init),
      maxBitrateBps: update.maximumBitrateBps.map(NSNumber.init)
    )
    if accepted {
      bandwidthApplicationState.commit(transition)
      if update.currentBitrateBps != nil { bandwidthSeedPending = false }
    } else {
      Self.bandwidthLogger.error(
        """
        WebRTC rejected peer bandwidth update \
        (min: \(update.minimumBitrateBps ?? -1, privacy: .public), \
        current: \(update.currentBitrateBps ?? -1, privacy: .public), \
        max: \(update.maximumBitrateBps ?? -1, privacy: .public)).
        """
      )
    }
  }

  private func clearPeerBandwidthPolicyAfterLastVideo() {
    guard !isClosed, connectionState == .connected else {
      bandwidthApplicationState.reset()
      return
    }
    let accepted = connection.setBweMinBitrateBps(
      NSNumber(value: 0),
      currentBitrateBps: nil,
      maxBitrateBps: NSNumber(
        value: WebRTCOpusMusicSDP.maximumAverageBitrateBps
      )
    )
    if accepted {
      bandwidthApplicationState.reset()
    } else {
      Self.bandwidthLogger.error(
        "WebRTC rejected the source-free bandwidth reset."
      )
    }
  }

  private static func applySenderPolicy(
    _ policy: WebRTCSenderPolicy,
    to sender: RTCRtpSender
  ) {
    let parameters = sender.parameters
    let preference: RTCDegradationPreference = switch policy.degradationStrategy {
    case .resolution: .maintainResolution
    case .balanced: .balanced
    case .framerate: .maintainFramerate
    case .disabled: .disabled
    }
    parameters.degradationPreference = NSNumber(value: preference.rawValue)
    for encoding in parameters.encodings {
      encoding.maxBitrateBps = policy.maximumBitrateBps.map(NSNumber.init)
      encoding.minBitrateBps = policy.minimumBitrateBps.map(NSNumber.init)
      encoding.maxFramerate = policy.maximumFramesPerSecond.map(NSNumber.init)
      encoding.scaleResolutionDownBy = policy.resolutionScale.map(NSNumber.init)
      encoding.bitratePriority = policy.bitratePriority
      encoding.networkPriority = .high
      if let temporalLayerCount = policy.temporalLayerCount {
        encoding.numTemporalLayers = NSNumber(value: temporalLayerCount)
      }
    }
    sender.parameters = parameters
  }

  private static func applyAudioSenderPolicy(to sender: RTCRtpSender) {
    let parameters = sender.parameters
    for encoding in parameters.encodings {
      encoding.maxBitrateBps = NSNumber(
        value: WebRTCOpusMusicSDP.maximumAverageBitrateBps
      )
      encoding.bitratePriority = 1
      encoding.networkPriority = .high
    }
    sender.parameters = parameters
  }

  private static func setSender(
    _ sender: RTCRtpSender,
    active: Bool
  ) {
    let parameters = sender.parameters
    for encoding in parameters.encodings {
      encoding.isActive = active
    }
    sender.parameters = parameters
  }
}

private final class ClipLiveShareNativeV3WebRTCPeerDelegate:
  NSObject,
  RTCPeerConnectionDelegate,
  RTCDataChannelDelegate,
  @unchecked Sendable
{
  enum Event: @unchecked Sendable {
    case localICECandidate(WebRTCICECandidate)
    case connectionStateChanged(WebRTCPeerConnectionState)
    case dataChannelOpened(RTCDataChannel)
    case dataChannelStateChanged(
      RTCDataChannel,
      WebRTCControlDataChannelState
    )
    case controlMessage(RTCDataChannel, Data)
    case negotiationNeeded
    case receiverAdded(String, RTCMediaStreamTrack)
    case receiverRemoved(String)
    case iceGatheringDiagnostic(code: Int, url: String, message: String)
    case failed(String)
  }

  private let lock = NSLock()
  private weak var transport:
    ClipLiveShareNativeV3WebRTCPeerLinkTransport?

  func attach(
    to transport: ClipLiveShareNativeV3WebRTCPeerLinkTransport
  ) {
    lock.withLock { self.transport = transport }
  }

  func detach() {
    lock.withLock { transport = nil }
  }

  private func forward(
    _ event: Event,
    connection: RTCPeerConnection? = nil
  ) {
    lock.withLock { transport }?.handle(
      event,
      connection: connection
    )
  }

  func peerConnection(
    _: RTCPeerConnection,
    didChange _: RTCSignalingState
  ) {}

  func peerConnection(
    _: RTCPeerConnection,
    didAdd _: RTCMediaStream
  ) {}

  func peerConnection(
    _: RTCPeerConnection,
    didRemove _: RTCMediaStream
  ) {}

  func peerConnectionShouldNegotiate(
    _ peerConnection: RTCPeerConnection
  ) {
    forward(.negotiationNeeded, connection: peerConnection)
  }

  func peerConnection(
    _: RTCPeerConnection,
    didChange _: RTCIceConnectionState
  ) {}

  func peerConnection(
    _: RTCPeerConnection,
    didChange _: RTCIceGatheringState
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didGenerate candidate: RTCIceCandidate
  ) {
    forward(
      .localICECandidate(
        .init(
          candidate: candidate.sdp,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex
        )
      ),
      connection: peerConnection
    )
  }

  func peerConnection(
    _: RTCPeerConnection,
    didRemove _: [RTCIceCandidate]
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
    let state: WebRTCPeerConnectionState = switch newState {
    case .new: .new
    case .connecting: .connecting
    case .connected: .connected
    case .disconnected: .disconnected
    case .failed: .failed
    case .closed: .closed
    @unknown default: .failed
    }
    forward(.connectionStateChanged(state), connection: peerConnection)
  }

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didAdd receiver: RTCRtpReceiver,
    streams _: [RTCMediaStream]
  ) {
    guard let track = receiver.track else { return }
    forward(
      .receiverAdded(receiver.receiverId, track),
      connection: peerConnection
    )
  }

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didRemove receiver: RTCRtpReceiver
  ) {
    forward(
      .receiverRemoved(receiver.receiverId),
      connection: peerConnection
    )
  }

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent
  ) {
    forward(
      .iceGatheringDiagnostic(
        code: Int(event.errorCode),
        url: event.url,
        message: event.errorText
      ),
      connection: peerConnection
    )
  }

  func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    let state: WebRTCControlDataChannelState = switch dataChannel.readyState {
    case .connecting: .connecting
    case .open: .open
    case .closing: .closing
    case .closed: .closed
    @unknown default: .closed
    }
    forward(.dataChannelStateChanged(dataChannel, state))
  }

  func dataChannel(
    _: RTCDataChannel,
    didChangeBufferedAmount _: UInt64
  ) {}

  func dataChannel(
    _ dataChannel: RTCDataChannel,
    didReceiveMessageWith buffer: RTCDataBuffer
  ) {
    forward(.controlMessage(dataChannel, buffer.data))
  }
}

struct ClipLiveShareNativeV3WebRTCTrackIdentifiersByMID: Equatable {
  let outgoing: [String: String]
  let incoming: [String: String]

  init(
    outgoing: [String: String] = [:],
    incoming: [String: String] = [:]
  ) {
    self.outgoing = outgoing
    self.incoming = incoming
  }
}

struct ClipLiveShareNativeV3WebRTCStatisticSample {
  let id: String
  let type: String
  let values: [String: NSObject]
}

enum ClipLiveShareNativeV3WebRTCStatisticsParser {
  static func parse(
    _ report: RTCStatisticsReport,
    capturedAt: Date = Date(),
    trackIdentifiersByMID: ClipLiveShareNativeV3WebRTCTrackIdentifiersByMID =
      .init()
  ) -> ClipLiveShareNativeV3PeerLinkTransportStatistics {
    parse(
      report.statistics.values.map {
        .init(id: $0.id, type: $0.type, values: $0.values)
      },
      capturedAt: capturedAt,
      trackIdentifiersByMID: trackIdentifiersByMID
    )
  }

  static func parse(
    _ samples: [ClipLiveShareNativeV3WebRTCStatisticSample],
    capturedAt: Date,
    trackIdentifiersByMID: ClipLiveShareNativeV3WebRTCTrackIdentifiersByMID =
      .init()
  ) -> ClipLiveShareNativeV3PeerLinkTransportStatistics {
    var bytesSent: UInt64 = 0
    var bytesReceived: UInt64 = 0
    var packetsSent: UInt64 = 0
    var packetsReceived: UInt64 = 0
    var packetsLost: Int64 = 0
    let samplesByID = Dictionary(
      uniqueKeysWithValues: samples.map { ($0.id, $0) }
    )
    for statistic in samples {
      if statistic.type == "outbound-rtp" {
        bytesSent += number(statistic.values["bytesSent"])?.uint64Value ?? 0
        packetsSent +=
          number(statistic.values["packetsSent"])?.uint64Value ?? 0
      } else if statistic.type == "inbound-rtp" {
        bytesReceived +=
          number(statistic.values["bytesReceived"])?.uint64Value ?? 0
        packetsReceived +=
          number(statistic.values["packetsReceived"])?.uint64Value ?? 0
        packetsLost +=
          number(statistic.values["packetsLost"])?.int64Value ?? 0
      }
    }
    // Current WebRTC statistics expose the authoritative selected pair from
    // the transport report. Older builds also marked the candidate-pair row
    // directly, so retain those shapes as compatibility fallbacks.
    let selectedPair = samples.lazy.compactMap { statistic in
      guard
        statistic.type == "transport",
        let selectedPairID = string(
          statistic.values["selectedCandidatePairId"]
        )
      else { return nil }
      return samplesByID[selectedPairID]
    }.first ?? samples.first {
      $0.type == "candidate-pair"
        && number($0.values["selected"])?.boolValue == true
    } ?? samples.first {
      $0.type == "candidate-pair"
        && number($0.values["nominated"])?.boolValue == true
        && string($0.values["state"]) == "succeeded"
    }
    let localCandidate = selectedPair
      .flatMap { string($0.values["localCandidateId"]) }
      .flatMap { samplesByID[$0] }
    let remoteCandidate = selectedPair
      .flatMap { string($0.values["remoteCandidateId"]) }
      .flatMap { samplesByID[$0] }
    let route: WebRTCConnectionRoute
    if localCandidate == nil && remoteCandidate == nil {
      route = .unknown
    } else if string(localCandidate?.values["candidateType"]) == "relay"
      || string(remoteCandidate?.values["candidateType"]) == "relay"
    {
      route = .relay
    } else {
      route = .direct
    }
    return .init(
      capturedAt: capturedAt,
      route: route,
      currentRoundTripTimeMilliseconds:
        number(selectedPair?.values["currentRoundTripTime"])
          .map { $0.doubleValue * 1_000 },
      availableOutgoingBitrateBps:
        number(selectedPair?.values["availableOutgoingBitrate"])?
          .doubleValue,
      bytesSent: bytesSent,
      bytesReceived: bytesReceived,
      packetsSent: packetsSent,
      packetsReceived: packetsReceived,
      packetsLost: packetsLost,
      videoSources: videoSources(
        samples,
        samplesByID: samplesByID,
        trackIdentifiersByMID: trackIdentifiersByMID
      )
    )
  }

  private static func videoSources(
    _ samples: [ClipLiveShareNativeV3WebRTCStatisticSample],
    samplesByID: [String: ClipLiveShareNativeV3WebRTCStatisticSample],
    trackIdentifiersByMID: ClipLiveShareNativeV3WebRTCTrackIdentifiersByMID
  ) -> [ClipLiveShareNativeV3VideoSourceStatistics] {
    let remoteInboundByLocalID = Dictionary(
      uniqueKeysWithValues: samples.compactMap {
        statistic
          -> (String, ClipLiveShareNativeV3WebRTCStatisticSample)? in
        guard
          statistic.type == "remote-inbound-rtp",
          let localID = string(statistic.values["localId"])
        else { return nil }
        return (localID, statistic)
      }
    )

    let sources = samples.compactMap {
      statistic -> ClipLiveShareNativeV3VideoSourceStatistics? in
      let direction: ClipLiveShareNativeV3MediaStatisticsDirection
      switch statistic.type {
      case "outbound-rtp":
        direction = .outgoing
      case "inbound-rtp":
        direction = .incoming
      default:
        return nil
      }
      let kind =
        string(statistic.values["kind"])
          ?? string(statistic.values["mediaType"])
      guard kind?.lowercased() == "video" else { return nil }

      let mid = string(statistic.values["mid"])
      // The inbound `trackIdentifier` reported by libwebrtc can be the
      // receiver's generated local identifier, especially on the permanent
      // offerer side of a symmetric Unified Plan connection. Clip rewrites
      // and parses each m-line's msid so the MID map is the authoritative,
      // room-stable media track identifier used by source manifests. Prefer
      // that map in both directions whenever it is available.
      let mappedTrackIdentifier = mid.flatMap {
        direction == .outgoing
          ? trackIdentifiersByMID.outgoing[$0]
          : trackIdentifiersByMID.incoming[$0]
      }
      let trackIdentifier =
        mappedTrackIdentifier
          ?? string(statistic.values["trackIdentifier"])
          ?? string(statistic.values["mediaSourceId"])
            .flatMap { samplesByID[$0] }
            .flatMap { string($0.values["trackIdentifier"]) }
          ?? statistic.id
      let codec = string(statistic.values["codecId"])
        .flatMap { samplesByID[$0] }
        .flatMap(codecName)
      let frames: UInt64
      let latency: Double?
      let relatedRemoteInbound = remoteInboundByLocalID[statistic.id]
      switch direction {
      case .outgoing:
        frames =
          number(statistic.values["framesEncoded"])?.uint64Value
            ?? number(statistic.values["framesSent"])?.uint64Value
            ?? 0
        latency = averageMilliseconds(
          total: number(statistic.values["totalEncodeTime"])?.doubleValue,
          count: frames
        )
      case .incoming:
        frames =
          number(statistic.values["framesDecoded"])?.uint64Value
            ?? number(statistic.values["framesReceived"])?.uint64Value
            ?? 0
        let jitterBufferCount =
          number(statistic.values["jitterBufferEmittedCount"])?.uint64Value
            ?? 0
        latency =
          averageMilliseconds(
            total:
              number(statistic.values["jitterBufferDelay"])?.doubleValue,
            count: jitterBufferCount
          )
          ?? averageMilliseconds(
            total: number(statistic.values["totalDecodeTime"])?.doubleValue,
            count: frames
          )
      }

      return .init(
        direction: direction,
        trackIdentifier: trackIdentifier,
        codec: codec,
        width: number(statistic.values["frameWidth"])?.intValue ?? 0,
        height: number(statistic.values["frameHeight"])?.intValue ?? 0,
        framesPerSecond:
          number(statistic.values["framesPerSecond"])?.doubleValue ?? 0,
        bytes:
          number(
            statistic.values[
              direction == .outgoing ? "bytesSent" : "bytesReceived"
            ]
          )?.uint64Value ?? 0,
        frames: frames,
        droppedFrames:
          number(statistic.values["framesDropped"])?.uint64Value ?? 0,
        queuePressureDrops:
          number(statistic.values["framesDiscardedOnSend"])?.uint64Value ?? 0,
        packets:
          number(
            statistic.values[
              direction == .outgoing ? "packetsSent" : "packetsReceived"
            ]
          )?.uint64Value ?? 0,
        packetsLost:
          direction == .outgoing
            ? number(relatedRemoteInbound?.values["packetsLost"])?.int64Value
              ?? 0
            : number(statistic.values["packetsLost"])?.int64Value ?? 0,
        qpSum:
          direction == .outgoing
            ? nonnegativeUInt64(statistic.values["qpSum"])
            : nil,
        targetBitrateBps:
          direction == .outgoing
            ? finiteNonnegativeDouble(statistic.values["targetBitrate"])
            : nil,
        totalEncodeTimeSeconds:
          direction == .outgoing
            ? finiteNonnegativeDouble(statistic.values["totalEncodeTime"])
            : nil,
        totalPacketSendDelaySeconds:
          direction == .outgoing
            ? finiteNonnegativeDouble(
              statistic.values["totalPacketSendDelay"]
            )
            : nil,
        qualityLimitationResolutionChanges:
          direction == .outgoing
            ? nonnegativeUInt64(
              statistic.values["qualityLimitationResolutionChanges"]
            )
            : nil,
        processingLatencyMilliseconds: latency,
        queuePressureReason:
          direction == .outgoing
            ? string(statistic.values["qualityLimitationReason"])
            : nil
      )
    }
    return sources.sorted {
      if $0.direction != $1.direction {
        return $0.direction.rawValue < $1.direction.rawValue
      }
      return $0.trackIdentifier < $1.trackIdentifier
    }
  }

  private static func codecName(
    _ statistic: ClipLiveShareNativeV3WebRTCStatisticSample
  ) -> String? {
    let value =
      string(statistic.values["mimeType"])
        ?? string(statistic.values["name"])
    guard let value else { return nil }
    return value.split(separator: "/").last.map(String.init)
  }

  private static func averageMilliseconds(
    total: Double?,
    count: UInt64
  ) -> Double? {
    guard let total, total.isFinite, total >= 0, count > 0 else {
      return nil
    }
    return total * 1_000 / Double(count)
  }

  private static func finiteNonnegativeDouble(_ value: NSObject?) -> Double? {
    guard let value = number(value)?.doubleValue,
      value.isFinite,
      value >= 0
    else {
      return nil
    }
    return value
  }

  private static func nonnegativeUInt64(_ value: NSObject?) -> UInt64? {
    guard let value = finiteNonnegativeDouble(value) else { return nil }
    return UInt64(exactly: value)
  }

  private static func number(_ value: NSObject?) -> NSNumber? {
    value as? NSNumber
  }

  private static func string(_ value: NSObject?) -> String? {
    if let value = value as? NSString { return value as String }
    return value as? String
  }
}
