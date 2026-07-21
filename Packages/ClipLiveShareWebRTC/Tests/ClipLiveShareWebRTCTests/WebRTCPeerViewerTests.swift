import AppKit
import ClipLiveShare
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import ClipLiveShareWebRTC

extension NativeMediaResourceTests {
    @Suite("Production WebRTC peer viewer")
    struct WebRTCPeerViewerTests {
        @Test("manifest before RTC tracks binds when negotiation supplies the track")
        func manifestBeforeTrack() async throws {
            let fixture = try ViewerLoopbackFixture(codec: .vp8)
            defer { fixture.close() }
            let descriptors = try fixture.activateSlots(count: 1)
            fixture.viewer.applyRemoteStreamManifest(
                try fixture.manifest(descriptors)
            )
            #expect(fixture.viewer.snapshot.boundStreams.isEmpty)

            try await fixture.connect()
            #expect(await viewerWaitUntil {
                fixture.viewer.snapshot.boundStreams == descriptors
                    && fixture.probe.addedStreamIDs == [descriptors[0].id]
            })
        }

        @Test("RTC tracks before manifest stay hidden until authoritative metadata arrives")
        func trackBeforeManifest() async throws {
            let fixture = try ViewerLoopbackFixture(codec: .vp8)
            defer { fixture.close() }
            let descriptors = try fixture.activateSlots(count: 1)

            try await fixture.connect()
            #expect(await viewerWaitUntil {
                fixture.viewer.snapshot.negotiatedVideoTrackIDs.count
                    == WebRTCRuntimeIdentity.maximumVideoSlots
            })
            #expect(fixture.viewer.snapshot.boundStreams.isEmpty)

            fixture.viewer.applyRemoteStreamManifest(
                try fixture.manifest(descriptors)
            )
            #expect(await viewerWaitUntil {
                fixture.viewer.snapshot.boundStreams == descriptors
                    && fixture.probe.addedStreamIDs == [descriptors[0].id]
            })
        }

        @Test("oversized offers are rejected before libwebrtc allocates receivers")
        func oversizedOfferRejectedBeforeRemoteDescription() async throws {
            let viewer = try WebRTCPeerViewer(configuration: .init(
                iceServers: [],
                resourceLimits: .init(maximumVideoTracks: 99)
            ))
            defer { viewer.close() }
            let mediaLines = (0 ..< 5).map {
                "m=video 9 UDP/TLS/RTP/SAVPF \(96 + $0)"
            }
            let offer = WebRTCSessionDescription(
                kind: .offer,
                sdp: (["v=0"] + mediaLines + [
                    "m=audio 9 UDP/TLS/RTP/SAVPF 111",
                    "m=application 9 UDP/DTLS/SCTP webrtc-datachannel"
                ]).joined(separator: "\r\n")
            )

            await #expect(throws:
                WebRTCPeerViewerError.invalidOfferMediaSections(
                    maximumVideoTracks: WebRTCRuntimeIdentity.maximumVideoSlots
                )) {
                try await viewer.answer(offer)
            }
            #expect(viewer.snapshot.negotiatedVideoTrackIDs.isEmpty)
        }

        @Test("multiple logical streams bind to their exact stable RTC tracks")
        func multipleTracks() async throws {
            let fixture = try ViewerLoopbackFixture(codec: .vp8)
            defer { fixture.close() }
            let descriptors = try fixture.activateSlots(count: 3)

            try await fixture.connect()
            fixture.viewer.applyRemoteStreamManifest(
                try fixture.manifest(descriptors)
            )
            #expect(await viewerWaitUntil {
                fixture.viewer.remoteVideoStreams.map(\.id) == descriptors.map(\.id)
            })
            #expect(
                fixture.viewer.remoteVideoStreams.map(\.mediaTrackID)
                    == descriptors.map(\.mediaTrackID)
            )
            #expect(fixture.probe.addedStreamIDs == descriptors.map(\.id))
        }

        @Test("one stable audio receiver survives repeated offers without duplication")
        func audioExactlyOnce() async throws {
            let fixture = try ViewerLoopbackFixture(codec: .vp8)
            defer { fixture.close() }
            try await fixture.connect()
            #expect(await viewerWaitUntil {
                fixture.probe.systemAudioAvailableCount == 1
            })
            let audioTrackID = try #require(fixture.viewer.snapshot.systemAudioTrackID)

            for _ in 0 ..< 2 {
                let offer = try await fixture.host.createReoffer(
                    for: fixture.viewerID
                )
                let answer = try await fixture.viewer.answer(offer)
                try await fixture.host.setRemoteAnswer(
                    answer,
                    for: fixture.viewerID
                )
            }

            #expect(fixture.probe.systemAudioAvailableCount == 1)
            #expect(fixture.probe.systemAudioRemovedCount == 0)
            #expect(fixture.viewer.snapshot.systemAudioTrackID == audioTrackID)
        }

        @Test("live codec reoffer preserves tracks, stream binding, and control transport")
        func liveCodecRenegotiation() async throws {
            let fixture = try ViewerLoopbackFixture(codec: .h264)
            defer { fixture.close() }
            let descriptors = try fixture.activateSlots(count: 1)
            try await fixture.connect()
            fixture.viewer.applyRemoteStreamManifest(
                try fixture.manifest(descriptors)
            )
            #expect(await viewerWaitUntil {
                fixture.viewer.snapshot.boundStreams == descriptors
            })
            let videoTrackIDs = fixture.viewer.snapshot.negotiatedVideoTrackIDs
            let audioTrackID = fixture.viewer.snapshot.systemAudioTrackID

            let switchTask = Task {
                try await fixture.host.updateVideoCodec(.vp8)
            }
            #expect(await viewerWaitUntil { fixture.host.videoCodec == .vp8 })
            let reoffer = try await fixture.host.createReoffer(
                for: fixture.viewerID
            )
            #expect(reoffer.sdp.contains(" VP8/90000"))
            let answer = try await fixture.viewer.answer(reoffer)
            #expect(answer.sdp.localizedCaseInsensitiveContains("stereo=1"))
            try await fixture.host.setRemoteAnswer(answer, for: fixture.viewerID)
            try await switchTask.value

            #expect(fixture.viewer.snapshot.negotiatedVideoTrackIDs == videoTrackIDs)
            #expect(fixture.viewer.snapshot.systemAudioTrackID == audioTrackID)
            #expect(fixture.viewer.snapshot.boundStreams == descriptors)
            #expect(fixture.probe.addedStreamIDs == [descriptors[0].id])
            #expect(fixture.probe.systemAudioAvailableCount == 1)
            #expect(fixture.probe.isConnectedAndControlOpen)
        }

        @Test("control is bidirectional and close tears down every receiver exactly once")
        func controlAndTeardown() async throws {
            let fixture = try ViewerLoopbackFixture(codec: .vp8)
            let descriptors = try fixture.activateSlots(count: 1)
            try await fixture.connect()
            fixture.viewer.applyRemoteStreamManifest(
                try fixture.manifest(descriptors)
            )
            #expect(await viewerWaitUntil {
                fixture.viewer.snapshot.boundStreams == descriptors
                    && fixture.probe.systemAudioAvailableCount == 1
            })

            let hostPayload = Data("host-control".utf8)
            #expect(fixture.host.sendControl(hostPayload, to: fixture.viewerID))
            #expect(await viewerWaitUntil {
                fixture.probe.viewerControlMessages.contains(hostPayload)
            })
            let viewerPayload = Data("viewer-control".utf8)
            #expect(fixture.viewer.sendControl(viewerPayload))
            #expect(await viewerWaitUntil {
                fixture.probe.hostControlMessages.contains(viewerPayload)
            })

            var inbound = try await fixture.viewer.inboundStatisticsSnapshot()
            for _ in 0 ..< 25 where inbound.route != .direct {
                try await Task.sleep(for: .milliseconds(20))
                inbound = try await fixture.viewer.inboundStatisticsSnapshot()
            }
            #expect(inbound.route == .direct)
            fixture.viewer.setSystemAudioPlaybackEnabled(true)
            #expect(fixture.viewer.snapshot.isSystemAudioPlaybackEnabled)
            fixture.viewer.setSystemAudioPlaybackEnabled(false)
            #expect(!fixture.viewer.snapshot.isSystemAudioPlaybackEnabled)
            fixture.viewer.setSystemAudioVolume(0.35)
            #expect(fixture.viewer.snapshot.systemAudioVolume == 0.35)
            fixture.viewer.setSystemAudioVolume(2)
            #expect(fixture.viewer.snapshot.systemAudioVolume == 1)

            let stream = try #require(fixture.viewer.remoteVideoStreams.first)
            let decodedSizeProbe = DecodedSizeProbe()
            await exerciseRenderer(stream: stream, probe: decodedSizeProbe)

            let priorOffer = try await fixture.host.createReoffer(
                for: fixture.viewerID
            )
            fixture.viewer.close()
            fixture.viewer.close()
            #expect(await viewerWaitUntil {
                fixture.probe.removedStreamIDs == [descriptors[0].id]
                    && fixture.probe.systemAudioRemovedCount == 1
            })
            let snapshot = fixture.viewer.snapshot
            #expect(snapshot.isClosed)
            #expect(snapshot.connectionState == .closed)
            #expect(snapshot.controlDataChannelState == .closed)
            #expect(snapshot.negotiatedVideoTrackIDs.isEmpty)
            #expect(snapshot.boundStreams.isEmpty)
            #expect(snapshot.systemAudioTrackID == nil)
            #expect(!fixture.viewer.sendControl(Data()))
            await #expect(throws: WebRTCPeerViewerError.viewerClosed) {
                try await fixture.viewer.answer(priorOffer)
            }
            fixture.host.close()
        }
    }
}

@MainActor
private func exerciseRenderer(
    stream: WebRTCRemoteVideoStream,
    probe: DecodedSizeProbe
) async {
    let view = WebRTCRemoteVideoView(frame: CGRect(
        x: 0,
        y: 0,
        width: 640,
        height: 480
    ))
    view.bind(to: stream)
    #expect(view.boundStreamID == stream.id)
    #expect(view.boundMediaTrackID == stream.mediaTrackID)
    view.unbind()
    #expect(view.boundStreamID == nil)
    view.bind(to: stream)
    view.onDecodedPixelSizeChange = { size in
        probe.record(size)
    }
    let metalView = view.subviews.first as? RTCMTLNSVideoView
    #expect(metalView != nil)
    if let metalView {
        view.videoView(
            metalView,
            didChangeVideoSize: CGSize(width: 1_280, height: 720)
        )
        view.videoView(
            metalView,
            didChangeVideoSize: CGSize(width: 1_280, height: 720)
        )
    }
    for _ in 0 ..< 10 where probe.sizes.isEmpty {
        await Task.yield()
    }
    #expect(probe.sizes == [CGSize(width: 1_280, height: 720)])
    #expect(view.decodedPixelSize == CGSize(width: 1_280, height: 720))
    #expect(metalView?.frame == CGRect(
        x: 0,
        y: 60,
        width: 640,
        height: 360
    ))
    view.teardown()
    #expect(view.boundStreamID == nil)
}

private final class DecodedSizeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSizes: [CGSize] = []

    var sizes: [CGSize] {
        lock.withLock { storedSizes }
    }

    func record(_ size: CGSize) {
        lock.withLock { storedSizes.append(size) }
    }
}

private final class ViewerLoopbackFixture: @unchecked Sendable {
    let viewerID = "native-viewer"
    let probe = ViewerLoopbackProbe()
    let host: WebRTCPeerHost
    let viewer: WebRTCPeerViewer

    init(codec: WebRTCVideoCodec) throws {
        host = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                resourceLimits: .init(answerTimeout: 5),
                videoCodec: codec
            ),
            eventQueue: probe.eventQueue,
            eventHandler: { [probe] event in
                probe.receive(hostEvent: event)
            }
        )
        viewer = try WebRTCPeerViewer(
            configuration: .init(
                iceServers: [],
                resourceLimits: .init(answerTimeout: 5),
                systemAudioPlaybackEnabled: false
            ),
            eventQueue: probe.eventQueue,
            eventHandler: { [probe] event in
                probe.receive(viewerEvent: event)
            }
        )
        probe.host = host
        probe.viewer = viewer
    }

    func activateSlots(count: Int) throws -> [ClipLiveShareStreamDescriptor] {
        try host.slotSnapshots.prefix(count).map { slot in
            let descriptor = try ClipLiveShareStreamDescriptor(
                id: ClipLiveShareStreamID(rawValue: "logical-stream-\(slot.index)"),
                mediaTrackID: ClipLiveShareMediaTrackID(rawValue: slot.trackID),
                active: true,
                focused: slot.index == 0,
                appName: "Fixture \(slot.index)",
                windowName: "Window \(slot.index)",
                width: 1_280 + slot.index * 2,
                height: 720 + slot.index * 2,
                order: slot.index
            )
            try host.activateSlot(slot.index, metadata: descriptor)
            return descriptor
        }
    }

    func manifest(
        _ descriptors: [ClipLiveShareStreamDescriptor]
    ) throws -> ClipLiveShareStreamManifest {
        try ClipLiveShareStreamManifest(
            sessionID: ClipLiveShareSessionID(rawValue: "native-viewer-session"),
            streams: descriptors,
            maximumStreams: WebRTCRuntimeIdentity.maximumVideoSlots
        )
    }

    func connect() async throws {
        let offer = try await host.createOffer(for: viewerID)
        let answer = try await viewer.answer(offer)
        try await host.setRemoteAnswer(answer, for: viewerID)
        probe.hostCanAcceptCandidates()
        let ready = await viewerWaitUntil { self.probe.isConnectedAndControlOpen }
        if !ready {
            print("Viewer loopback did not become ready: \(probe.stateDescription)")
            print("Viewer snapshot: \(viewer.snapshot)")
            print("Host snapshots: \(host.viewerSnapshots)")
        }
        #expect(ready)
    }

    func close() {
        viewer.close()
        host.close()
    }
}

private final class ViewerLoopbackProbe: @unchecked Sendable {
    let eventQueue = DispatchQueue(
        label: "com.tomaslejdung.clip.tests.webrtc-viewer-events"
    )

    private let lock = NSLock()
    private weak var storedHost: WebRTCPeerHost?
    private weak var storedViewer: WebRTCPeerViewer?
    private var hostCandidateReady = false
    private var pendingForHost: [WebRTCICECandidate] = []
    private var hostConnected = false
    private var viewerConnected = false
    private var hostControlOpen = false
    private var viewerControlOpen = false
    private var hostCandidateCount = 0
    private var viewerCandidateCount = 0
    private var storedErrors: [String] = []
    private var storedAddedStreamIDs: [ClipLiveShareStreamID] = []
    private var storedRemovedStreamIDs: [ClipLiveShareStreamID] = []
    private var storedSystemAudioAvailableCount = 0
    private var storedSystemAudioRemovedCount = 0
    private var storedViewerControlMessages: [Data] = []
    private var storedHostControlMessages: [Data] = []

    var host: WebRTCPeerHost? {
        get { lock.withLock { storedHost } }
        set { lock.withLock { storedHost = newValue } }
    }

    var viewer: WebRTCPeerViewer? {
        get { lock.withLock { storedViewer } }
        set { lock.withLock { storedViewer = newValue } }
    }

    var isConnectedAndControlOpen: Bool {
        lock.withLock {
            hostConnected && viewerConnected && hostControlOpen && viewerControlOpen
        }
    }

    var stateDescription: String {
        lock.withLock {
            "hostConnected=\(hostConnected), viewerConnected=\(viewerConnected), "
                + "hostControlOpen=\(hostControlOpen), viewerControlOpen=\(viewerControlOpen), "
                + "hostCandidates=\(hostCandidateCount), "
                + "viewerCandidates=\(viewerCandidateCount), "
                + "pendingForHost=\(pendingForHost.count), "
                + "errors=\(storedErrors)"
        }
    }

    var addedStreamIDs: [ClipLiveShareStreamID] {
        lock.withLock { storedAddedStreamIDs }
    }

    var removedStreamIDs: [ClipLiveShareStreamID] {
        lock.withLock { storedRemovedStreamIDs }
    }

    var systemAudioAvailableCount: Int {
        lock.withLock { storedSystemAudioAvailableCount }
    }

    var systemAudioRemovedCount: Int {
        lock.withLock { storedSystemAudioRemovedCount }
    }

    var viewerControlMessages: [Data] {
        lock.withLock { storedViewerControlMessages }
    }

    var hostControlMessages: [Data] {
        lock.withLock { storedHostControlMessages }
    }

    func receive(hostEvent: WebRTCPeerHostEvent) {
        switch hostEvent {
        case .localICECandidate(let viewerID, let candidate)
            where viewerID == "native-viewer":
            lock.withLock { hostCandidateCount += 1 }
            guard let viewer = lock.withLock({ storedViewer }) else { return }
            Task {
                do {
                    try await viewer.addRemoteICECandidate(candidate)
                } catch {
                    self.record(error: "viewer candidate: \(error)")
                }
            }
        case .connectionStateChanged(let viewerID, let state)
            where viewerID == "native-viewer":
            lock.withLock { hostConnected = state == .connected }
        case .controlDataChannelStateChanged(let viewerID, let state)
            where viewerID == "native-viewer":
            lock.withLock { hostControlOpen = state == .open }
        case .controlMessageReceived(let viewerID, let data, _)
            where viewerID == "native-viewer":
            lock.withLock { storedHostControlMessages.append(data) }
        case .error(let viewerID, let error) where viewerID == "native-viewer":
            record(error: "host: \(error)")
        default:
            break
        }
    }

    func receive(viewerEvent: WebRTCPeerViewerEvent) {
        switch viewerEvent {
        case .localICECandidate(let candidate):
            lock.withLock { viewerCandidateCount += 1 }
            deliverToHost(candidate)
        case .connectionStateChanged(let state):
            lock.withLock { viewerConnected = state == .connected }
        case .controlDataChannelStateChanged(let state):
            lock.withLock { viewerControlOpen = state == .open }
        case .controlMessageReceived(let data, _):
            lock.withLock { storedViewerControlMessages.append(data) }
        case .remoteVideoStreamAdded(let stream):
            lock.withLock { storedAddedStreamIDs.append(stream.id) }
        case .remoteVideoStreamRemoved(let streamID):
            lock.withLock { storedRemovedStreamIDs.append(streamID) }
        case .systemAudioTrackAvailable:
            lock.withLock { storedSystemAudioAvailableCount += 1 }
        case .systemAudioTrackRemoved:
            lock.withLock { storedSystemAudioRemovedCount += 1 }
        case .error(let error):
            record(error: "viewer: \(error)")
        default:
            break
        }
    }

    func hostCanAcceptCandidates() {
        let pending: ([WebRTCICECandidate], WebRTCPeerHost?) = lock.withLock {
            hostCandidateReady = true
            defer { pendingForHost.removeAll(keepingCapacity: true) }
            return (pendingForHost, storedHost)
        }
        guard let host = pending.1 else { return }
        for candidate in pending.0 {
            Task {
                do {
                    try await host.addRemoteICECandidate(
                        candidate,
                        for: "native-viewer"
                    )
                } catch {
                    self.record(error: "pending host candidate: \(error)")
                }
            }
        }
    }

    private func deliverToHost(_ candidate: WebRTCICECandidate) {
        let host: WebRTCPeerHost? = lock.withLock {
            guard hostCandidateReady else {
                pendingForHost.append(candidate)
                return nil
            }
            return storedHost
        }
        guard let host else { return }
        Task {
            do {
                try await host.addRemoteICECandidate(candidate, for: "native-viewer")
            } catch {
                self.record(error: "host candidate: \(error)")
            }
        }
    }

    private func record(error: String) {
        lock.withLock { storedErrors.append(error) }
    }
}

private func viewerWaitUntil(
    timeout: Duration = .seconds(5),
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
