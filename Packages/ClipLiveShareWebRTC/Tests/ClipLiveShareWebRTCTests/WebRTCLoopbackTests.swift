import ClipCapture
import ClipLiveShare
import CoreMedia
import CoreVideo
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import ClipLiveShareWebRTC

@Suite("Native WebRTC loopback", .serialized)
struct WebRTCLoopbackTests {
    @Test("host negotiates, sends control data, and delivers a captured pixel buffer")
    func nativeLoopback() async throws {
        let bridge = LoopbackBridge()
        let host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                senderPolicy: .init(
                    maximumBitrateBps: 2_000_000,
                    maximumFramesPerSecond: 30,
                    maintainsResolution: true
                ),
                resourceLimits: .init(answerTimeout: 0.05)
            ),
            eventQueue: bridge.eventQueue,
            eventHandler: { event in bridge.receive(hostEvent: event) }
        )
        bridge.host = host
        defer { host.close() }

        let offer = try await host.createOffer(for: "loopback-viewer")
        let receiver = try LoopbackReceiver(bridge: bridge)
        defer { receiver.close() }
        bridge.receiver = receiver.connection

        let answer = try await receiver.answer(offer: offer.sdp)
        bridge.receiverCanAcceptCandidates()
        try await host.setRemoteAnswer(answer, for: "loopback-viewer")
        bridge.hostCanAcceptCandidates()
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.viewerIDs == ["loopback-viewer"])

        let connected = await waitUntil(timeout: .seconds(5)) {
            bridge.isConnectedAndControlOpen
        }
        #expect(connected)
        #expect(host.connectedViewerCount == 1)
        #expect(host.viewerSnapshots.first?.isConnected == true)
        #expect(bridge.controlChannelLabel == WebRTCRuntimeIdentity.controlDataChannelLabel)
        #expect(bridge.controlChannelIsOrdered)

        let control = Data(#"{"type":"sharer-started"}"#.utf8)
        let delivery = host.broadcastControl(control)
        #expect(delivery.deliveredViewerIDs == ["loopback-viewer"])
        #expect(delivery.unavailableViewerIDs.isEmpty)
        #expect(await waitUntil(timeout: .seconds(2)) {
            bridge.lastControlMessage == control
        })

        try host.activateSlot(0, metadata: GoPeepV1StreamInfo(
            trackID: "video0",
            windowName: "Deterministic fixture",
            appName: "Clip tests",
            isFocused: true,
            width: 320,
            height: 180
        ))
        let baselineStatistics = try await host.outboundSenderStatisticsSnapshot()
        #expect(baselineStatistics.viewerCount == 1)
        #expect(baselineStatistics[slot: 0]?.aggregateBitrateBps == nil)
        for index in 0 ..< 45 {
            let frame = try makeFixtureFrame(index: index, width: 320, height: 180)
            #expect(host.send(frame, toSlot: 0) == .accepted)
            try await Task.sleep(for: .milliseconds(12))
        }

        #expect(await waitUntil(timeout: .seconds(5)) {
            bridge.receivedVideoFrameCount > 0
        })
        #expect(bridge.receivedVideoSize == .init(width: 320, height: 180))

        let outbound = try await host.outboundSenderStatisticsSnapshot()
        let slot = try #require(outbound[slot: 0])
        #expect(slot.bytesSent > 0)
        #expect(slot.packetsSent > 0)
        #expect(slot.framesSent > 0)
        #expect(slot.framesEncoded > 0)
        #expect((slot.aggregateBitrateBps ?? 0) > 0)
        #expect((slot.averageFramesPerSecond ?? 0) > 0)
        #expect(slot.viewers.count == 1)
    }
}

private final class LoopbackBridge: @unchecked Sendable {
    let eventQueue = DispatchQueue(label: "com.tomaslejdung.clip.tests.webrtc-events")

    private let lock = NSLock()
    private weak var storedHost: WebRTCPeerHost?
    private var storedReceiver: RTCPeerConnection?
    private var pendingForHost: [WebRTCICECandidate] = []
    private var pendingForReceiver: [WebRTCICECandidate] = []
    private var hostCandidateReady = false
    private var receiverCandidateReady = false
    private var hostConnected = false
    private var receiverConnected = false
    private var hostControlOpen = false
    private var storedControlLabel: String?
    private var storedControlOrdered = false
    private var storedControlMessage: Data?
    private var storedFrameCount = 0
    private var storedVideoSize = CGSize.zero

    var host: WebRTCPeerHost? {
        get { lock.withLock { storedHost } }
        set { lock.withLock { storedHost = newValue } }
    }

    var receiver: RTCPeerConnection? {
        get { lock.withLock { storedReceiver } }
        set { lock.withLock { storedReceiver = newValue } }
    }

    var isConnectedAndControlOpen: Bool {
        lock.withLock { hostConnected && receiverConnected && hostControlOpen }
    }

    var controlChannelLabel: String? { lock.withLock { storedControlLabel } }
    var controlChannelIsOrdered: Bool { lock.withLock { storedControlOrdered } }
    var lastControlMessage: Data? { lock.withLock { storedControlMessage } }
    var receivedVideoFrameCount: Int { lock.withLock { storedFrameCount } }
    var receivedVideoSize: CGSize { lock.withLock { storedVideoSize } }

    func receive(hostEvent: WebRTCPeerHostEvent) {
        switch hostEvent {
        case .localICECandidate(_, let candidate):
            deliverToReceiver(candidate)
        case .connectionStateChanged(_, let state):
            lock.withLock { hostConnected = state == .connected }
        case .controlDataChannelStateChanged(_, let state):
            lock.withLock { hostControlOpen = state == .open }
        default:
            break
        }
    }

    func receive(receiverCandidate: WebRTCICECandidate) {
        let host: WebRTCPeerHost? = lock.withLock {
            guard hostCandidateReady else {
                pendingForHost.append(receiverCandidate)
                return nil
            }
            return storedHost
        }
        guard let host else { return }
        Task { try? await host.addRemoteICECandidate(receiverCandidate, for: "loopback-viewer") }
    }

    func receiverCanAcceptCandidates() {
        let pending: ([WebRTCICECandidate], RTCPeerConnection?) = lock.withLock {
            receiverCandidateReady = true
            defer { pendingForReceiver.removeAll() }
            return (pendingForReceiver, storedReceiver)
        }
        guard let receiver = pending.1 else { return }
        for candidate in pending.0 {
            add(candidate, to: receiver)
        }
    }

    func hostCanAcceptCandidates() {
        let pending: ([WebRTCICECandidate], WebRTCPeerHost?) = lock.withLock {
            hostCandidateReady = true
            defer { pendingForHost.removeAll() }
            return (pendingForHost, storedHost)
        }
        guard let host = pending.1 else { return }
        for candidate in pending.0 {
            Task { try? await host.addRemoteICECandidate(candidate, for: "loopback-viewer") }
        }
    }

    func receiverConnectionChanged(_ state: RTCPeerConnectionState) {
        lock.withLock { receiverConnected = state == .connected }
    }

    func receiverOpened(_ channel: RTCDataChannel) {
        lock.withLock {
            storedControlLabel = channel.label
            storedControlOrdered = channel.isOrdered
        }
    }

    func receiverControlMessage(_ data: Data) {
        lock.withLock { storedControlMessage = data }
    }

    func receiverRenderedFrame(size: CGSize) {
        lock.withLock {
            storedFrameCount += 1
            storedVideoSize = size
        }
    }

    private func deliverToReceiver(_ candidate: WebRTCICECandidate) {
        let receiver: RTCPeerConnection? = lock.withLock {
            guard receiverCandidateReady else {
                pendingForReceiver.append(candidate)
                return nil
            }
            return storedReceiver
        }
        guard let receiver else { return }
        add(candidate, to: receiver)
    }

    private func add(_ candidate: WebRTCICECandidate, to receiver: RTCPeerConnection) {
        receiver.add(RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )) { _ in }
    }
}

private final class LoopbackReceiver: NSObject, RTCPeerConnectionDelegate,
    RTCDataChannelDelegate, RTCVideoRenderer, @unchecked Sendable
{
    private let bridge: LoopbackBridge
    private let sslLease: WebRTCSSLRuntimeLease
    private let factory: RTCPeerConnectionFactory
    let connection: RTCPeerConnection
    private var controlChannel: RTCDataChannel?
    private var videoTracks: [RTCVideoTrack] = []

    init(bridge: LoopbackBridge) throws {
        self.bridge = bridge
        sslLease = try WebRTCSSLRuntimeLease()
        factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.iceServers = []
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let connection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: nil
        ) else {
            throw WebRTCPeerHostError.peerConnectionCreationFailed("loopback receiver")
        }
        self.connection = connection
        super.init()
        connection.delegate = self
    }

    func answer(offer: String) async throws -> WebRTCSessionDescription {
        try await setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer))
        let answer = try await createAnswer()
        try await setLocalDescription(answer)
        return .init(kind: .answer, sdp: answer.sdp)
    }

    func close() {
        connection.delegate = nil
        controlChannel?.delegate = nil
        controlChannel?.close()
        for track in videoTracks { track.remove(self) }
        videoTracks.removeAll()
        connection.close()
    }

    private func setRemoteDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func createAnswer() async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            )
            connection.answer(for: constraints) { description, error in
                if let error { continuation.resume(throwing: error) }
                else if let description { continuation.resume(returning: description) }
                else {
                    continuation.resume(throwing:
                        WebRTCPeerHostError.localDescriptionCreationFailed("loopback answer"))
                }
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

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
        bridge.receive(receiverCandidate: WebRTCICECandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        ))
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {
        controlChannel = dataChannel
        dataChannel.delegate = self
        bridge.receiverOpened(dataChannel)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        bridge.receiverConnectionChanged(newState)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        guard let track = rtpReceiver.track as? RTCVideoTrack,
              track.trackId == "video0" else { return }
        videoTracks.append(track)
        track.add(self)
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    func dataChannel(
        _ dataChannel: RTCDataChannel,
        didReceiveMessageWith buffer: RTCDataBuffer
    ) {
        bridge.receiverControlMessage(buffer.data)
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        bridge.receiverRenderedFrame(size: CGSize(
            width: CGFloat(frame.width),
            height: CGFloat(frame.height)
        ))
    }
}

private func waitUntil(
    timeout: Duration,
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func makeFixtureFrame(
    index: Int,
    width: Int,
    height: Int
) throws -> BorrowedCaptureVideoFrame {
    var pixelBuffer: CVPixelBuffer?
    let attributes: CFDictionary = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary
    guard CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes,
        &pixelBuffer
    ) == kCVReturnSuccess,
        let pixelBuffer else {
        throw WebRTCPeerHostError.localDescriptionCreationFailed("pixel buffer")
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(base, Int32(index & 0xff), CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    var formatDescription: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    ) == noErr,
        let formatDescription else {
        throw WebRTCPeerHostError.localDescriptionCreationFailed("format description")
    }
    let presentationTime = CMTime(value: CMTimeValue(index), timescale: 30)
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    ) == noErr,
        let sampleBuffer else {
        throw WebRTCPeerHostError.localDescriptionCreationFailed("sample buffer")
    }
    return BorrowedCaptureVideoFrame(
        sampleBuffer: sampleBuffer,
        pixelBuffer: pixelBuffer,
        presentationTime: presentationTime
    )
}
