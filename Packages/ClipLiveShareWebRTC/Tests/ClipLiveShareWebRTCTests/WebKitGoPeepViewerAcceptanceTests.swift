import AppKit
import ClipCapture
import ClipLiveShare
import CoreMedia
import CoreVideo
import Foundation
import Testing
import WebKit
@testable import ClipLiveShareWebRTC

/// Runs GoPeep's served viewer unchanged inside a real WebKit browser process.
///
/// The ordinary package suite leaves this acceptance dormant because it owns an
/// external GoPeep server and launches WebKit auxiliary processes. The repository
/// acceptance script supplies the opt-in environment after starting an unmodified
/// sibling GoPeep checkout on loopback.
extension NativeMediaResourceTests {
@Suite("WebKit GoPeep viewer acceptance", .serialized)
struct WebKitGoPeepViewerAcceptanceTests {
    @MainActor
    @Test("served viewer decodes a slot activated after negotiation")
    func servedViewerDecodesNativeHost() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CLIP_RUN_GOPEEP_WEBKIT_ACCEPTANCE"] == "1" else {
            return
        }
        let signalingURL = try #require(
            environment["CLIP_GOPEEP_INTEROP_SIGNAL_URL"].flatMap(URL.init(string:))
        )
        let server = try GoPeepV1ServerConfiguration(
            signalingServerURL: signalingURL,
            iceServers: []
        )
        let harness = try WebKitGoPeepHostHarness(server: server)
        let viewerURL = try await harness.start()
        defer {
            Task { await harness.stop() }
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 960, height: 640),
            configuration: configuration
        )
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        // WebKit throttles media in a detached view. Keep the test view ordered in
        // offscreen coordinates so its real rendering path runs without stealing focus.
        window.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
        window.orderFrontRegardless()
        defer {
            webView.stopLoading()
            window.orderOut(nil)
            window.close()
        }

        webView.load(URLRequest(url: viewerURL))
        let loaded = try await waitForWebKitSnapshot(
            webView: webView,
            timeout: .seconds(10)
        ) { $0.readyState == "complete" }
        #expect(loaded)

        let controlOpen = await harness.waitUntilControlOpen(timeout: .seconds(15))
        #expect(controlOpen)
        #expect(await harness.answerAdvertisesH264)
        try await harness.activateFixtureSlot()

        var firstDecodedFrameCount: Int?
        var lastSnapshot = try await webKitViewerSnapshot(webView)
        for index in 0 ..< 240 {
            try await harness.sendFixtureFrame(index: index)
            try await Task.sleep(for: .milliseconds(16))

            if index.isMultiple(of: 8) {
                lastSnapshot = try await webKitViewerSnapshot(webView)
                if lastSnapshot.decodedFrames > 0, firstDecodedFrameCount == nil {
                    firstDecodedFrameCount = lastSnapshot.decodedFrames
                }
                if let firstDecodedFrameCount,
                   lastSnapshot.decodedFrames >= firstDecodedFrameCount + 3,
                   lastSnapshot.metadataMatchesFixture,
                   lastSnapshot.cursorMetadataConsumed {
                    break
                }
            }
        }

        lastSnapshot = try await webKitViewerSnapshot(webView)
        let initialFrames = firstDecodedFrameCount ?? 0
        #expect(lastSnapshot.statusText == "Connected")
        #expect(lastSnapshot.hasVideoSource)
        #expect(lastSnapshot.videoWidth == 2_762)
        #expect(lastSnapshot.videoHeight == 1_202)
        #expect(lastSnapshot.decodedFrames >= initialFrames + 3)
        #expect(lastSnapshot.metadataMatchesFixture)
        #expect(lastSnapshot.cursorMetadataConsumed)
        #expect(lastSnapshot.streamOrder.contains(0))

        let originalViewerID = await harness.viewerID
        let framesBeforeVP8 = lastSnapshot.decodedFrames
        try await harness.switchVideoCodec(to: .vp8)
        #expect(await harness.answerAdvertisesVP8)
        #expect(await harness.viewerID == originalViewerID)
        for index in 240 ..< 480 {
            try await harness.sendFixtureFrame(index: index)
            try await Task.sleep(for: .milliseconds(16))
            if index.isMultiple(of: 8) {
                lastSnapshot = try await webKitViewerSnapshot(webView)
                if lastSnapshot.decodedFrames >= framesBeforeVP8 + 3 { break }
            }
        }
        lastSnapshot = try await webKitViewerSnapshot(webView)
        #expect(lastSnapshot.decodedFrames >= framesBeforeVP8 + 3)
        #expect(lastSnapshot.metadataMatchesFixture)
        #expect(lastSnapshot.streamOrder.contains(0))

        var nextFrameIndex = 480
        for codec in [WebRTCVideoCodec.vp9, .av1] {
            let framesBeforeSwitch = lastSnapshot.decodedFrames
            try await harness.switchVideoCodec(to: codec)
            let compatibleCodecNames = codec == .av1
                ? [codec.rtcName, WebRTCVideoCodec.vp9.rtcName, WebRTCVideoCodec.vp8.rtcName]
                : [codec.rtcName, WebRTCVideoCodec.vp8.rtcName]
            #expect(await harness.answerAdvertisesAny(compatibleCodecNames))
            #expect(await harness.viewerID == originalViewerID)
            for index in nextFrameIndex ..< nextFrameIndex + 240 {
                try await harness.sendFixtureFrame(index: index)
                try await Task.sleep(for: .milliseconds(16))
                if index.isMultiple(of: 8) {
                    lastSnapshot = try await webKitViewerSnapshot(webView)
                    if lastSnapshot.decodedFrames >= framesBeforeSwitch + 3 { break }
                }
            }
            nextFrameIndex += 240
            lastSnapshot = try await webKitViewerSnapshot(webView)
            #expect(lastSnapshot.decodedFrames >= framesBeforeSwitch + 3)
            #expect(lastSnapshot.metadataMatchesFixture)
            #expect(lastSnapshot.streamOrder.contains(0))

            #expect(try await harness.waitForOutboundCodec(
                among: compatibleCodecNames,
                timeout: .seconds(3)
            ) != nil)
        }

        let framesBeforeH264Return = lastSnapshot.decodedFrames
        try await harness.switchVideoCodec(to: .h264)
        #expect(await harness.answerAdvertisesH264)
        #expect(await harness.viewerID == originalViewerID)
        for index in nextFrameIndex ..< nextFrameIndex + 240 {
            try await harness.sendFixtureFrame(index: index)
            try await Task.sleep(for: .milliseconds(16))
            if index.isMultiple(of: 8) {
                lastSnapshot = try await webKitViewerSnapshot(webView)
                if lastSnapshot.decodedFrames >= framesBeforeH264Return + 3 { break }
            }
        }
        lastSnapshot = try await webKitViewerSnapshot(webView)
        #expect(lastSnapshot.decodedFrames >= framesBeforeH264Return + 3)
        #expect(lastSnapshot.metadataMatchesFixture)
        #expect(lastSnapshot.streamOrder.contains(0))
    }
}
}

private actor WebKitGoPeepHostHarness {
    private let server: GoPeepV1ServerConfiguration
    private let signaling: GoPeepV1SignalingClient
    private let peerHost: WebRTCPeerHost
    private var eventTask: Task<Void, Never>?
    private var room: GoPeepV1RoomReservationResponse?
    private var joined = false
    private var nextViewerNumber = 1
    private var offerSent: Set<String> = []
    private var offerInFlight: Set<String> = []
    private var answerApplied: Set<String> = []
    private var pendingLocalICE: [String: [WebRTCICECandidate]] = [:]
    private var pendingRemoteICE: [String: [WebRTCICECandidate]] = [:]
    private var controlOpen = false
    private var controlViewerID: String?
    private var answerSDP = ""
    private var failure: String?

    init(server: GoPeepV1ServerConfiguration) throws {
        self.server = server
        signaling = GoPeepV1SignalingClient(
            server: server,
            reconnectPolicy: .disabled
        )

        let eventQueue = DispatchQueue(
            label: "com.tomaslejdung.clip.tests.webkit-peer-events"
        )
        let bridge = WebKitPeerEventBridge()
        peerHost = try WebRTCPeerHost(
            configuration: .init(
                iceServers: [],
                senderPolicy: .init(
                    maximumBitrateBps: 12_000_000,
                    maximumFramesPerSecond: 30,
                    maintainsResolution: true
                )
            ),
            eventQueue: eventQueue,
            eventHandler: { event in bridge.receive(event) }
        )
        bridge.harness = self
    }

    var answerAdvertisesH264: Bool {
        answerSDP.localizedCaseInsensitiveContains("H264/90000")
    }

    var answerAdvertisesVP8: Bool {
        answerSDP.localizedCaseInsensitiveContains("VP8/90000")
    }

    func answerAdvertises(_ codec: WebRTCVideoCodec) -> Bool {
        answerSDP.localizedCaseInsensitiveContains("\(codec.rtcName)/90000")
    }

    func answerAdvertisesAny(_ codecNames: [String]) -> Bool {
        codecNames.contains {
            answerSDP.localizedCaseInsensitiveContains("\($0)/90000")
        }
    }

    var viewerID: String? { controlViewerID }

    func start() async throws -> URL {
        let stream = await signaling.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handleSignalingEvent(event)
            }
        }

        let reservation = try await signaling.reserveRoom()
        room = reservation
        try await signaling.connect(room: GoPeepV1RoomConfiguration(
            reservation: reservation
        ))

        let didJoin = await waitUntil(timeout: .seconds(5)) { joined }
        guard didJoin else {
            throw WebKitAcceptanceError.timeout("sharer join acknowledgement")
        }
        return server.viewerURL(for: reservation.room)
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        peerHost.close()
        await signaling.stop()
    }

    func waitUntilControlOpen(timeout: Duration) async -> Bool {
        await waitUntil(timeout: timeout) { controlOpen || failure != nil }
            && controlOpen
    }

    func sendFixtureFrame(index: Int) throws {
        if let failure {
            throw WebKitAcceptanceError.runtime(failure)
        }
        let frame = try makeWebKitFixtureFrame(
            index: index,
            width: 2_762,
            height: 1_202
        )
        guard peerHost.send(frame, toSlot: 0) == .accepted else {
            throw WebKitAcceptanceError.runtime("native host rejected fixture frame")
        }
    }

    func switchVideoCodec(to codec: WebRTCVideoCodec) async throws {
        if let failure {
            throw WebKitAcceptanceError.runtime(failure)
        }
        guard controlViewerID != nil else {
            throw WebKitAcceptanceError.runtime("control viewer is unavailable")
        }
        try await peerHost.updateVideoCodec(codec)
        if let failure {
            throw WebKitAcceptanceError.runtime(failure)
        }
        guard peerHost.videoCodec == codec else {
            throw WebKitAcceptanceError.runtime(
                "native host did not commit the \(codec.rtcName) switch"
            )
        }
    }

    func outboundCodecNames() async throws -> Set<String> {
        if let failure {
            throw WebKitAcceptanceError.runtime(failure)
        }
        let snapshot = try await peerHost.outboundSenderStatisticsSnapshot()
        return Set(snapshot[slot: 0]?.codecs ?? [])
    }

    func waitForOutboundCodec(
        among codecNames: [String],
        timeout: Duration
    ) async throws -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let active = try await outboundCodecNames()
            if let codec = codecNames.first(where: active.contains) {
                return codec
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let active = try await outboundCodecNames()
        return codecNames.first(where: active.contains)
    }

    /// Mirrors Clip's real first-share order: the browser completes its offer,
    /// answer, and data-channel setup while all four stable tracks are disabled.
    /// The selected slot only becomes active afterward, without renegotiation.
    func activateFixtureSlot() throws {
        if let failure {
            throw WebKitAcceptanceError.runtime(failure)
        }
        guard let viewerID = controlViewerID else {
            throw WebKitAcceptanceError.runtime("control viewer is unavailable")
        }

        try peerHost.activateSlot(0, metadata: Self.fixtureMetadata)
        let messages = [
            GoPeepV1Message(
                type: .streamActivated,
                streamActivated: Self.fixtureMetadata
            ),
            GoPeepV1Message(type: .focusChange, focusedTrack: "video0"),
            GoPeepV1Message(
                type: .cursorPosition,
                trackID: "video0",
                cursorX: 0.25,
                cursorY: 0.75,
                cursorInView: true
            ),
            GoPeepV1Message(type: .sharerStarted),
        ]
        for message in messages {
            guard try peerHost.sendControl(message, to: viewerID) else {
                throw WebKitAcceptanceError.runtime(
                    "could not deliver post-negotiation activation metadata"
                )
            }
        }
    }

    private func waitUntil(
        timeout: Duration,
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func handleSignalingEvent(_ event: GoPeepV1SignalingEvent) async {
        guard case .message(let message) = event else { return }
        switch message.type {
        case .joined:
            joined = message.role == .sharer

        case .viewerJoined:
            let viewerID = "viewer-\(nextViewerNumber)"
            nextViewerNumber += 1
            await sendOffer(viewerID: viewerID, isReoffer: false)

        case .viewerReoffer:
            guard !message.peerID.isEmpty else { return }
            peerHost.removePeer(message.peerID, notifies: false)
            offerSent.remove(message.peerID)
            answerApplied.remove(message.peerID)
            pendingLocalICE[message.peerID] = nil
            pendingRemoteICE[message.peerID] = nil
            await sendOffer(viewerID: message.peerID, isReoffer: false)

        case .answer, .renegotiateAnswer:
            guard !message.peerID.isEmpty, !message.sdp.isEmpty else { return }
            do {
                answerSDP = message.sdp
                try await peerHost.setRemoteAnswer(message.sdp, for: message.peerID)
                answerApplied.insert(message.peerID)
                offerInFlight.remove(message.peerID)
                for candidate in pendingRemoteICE.removeValue(forKey: message.peerID) ?? [] {
                    try await peerHost.addRemoteICECandidate(candidate, for: message.peerID)
                }
            } catch {
                failure = "could not apply WebKit answer: \(error.localizedDescription)"
            }

        case .ice:
            guard !message.peerID.isEmpty,
                  let candidateData = message.candidate.data(using: .utf8) else { return }
            do {
                let candidate = try JSONDecoder().decode(
                    WebRTCICECandidate.self,
                    from: candidateData
                )
                if answerApplied.contains(message.peerID) {
                    try await peerHost.addRemoteICECandidate(candidate, for: message.peerID)
                } else {
                    pendingRemoteICE[message.peerID, default: []].append(candidate)
                }
            } catch {
                failure = "could not apply WebKit ICE: \(error.localizedDescription)"
            }

        case .error:
            failure = message.errorMessage.isEmpty
                ? "GoPeep signaling rejected the acceptance session"
                : message.errorMessage

        default:
            break
        }
    }

    private func sendOffer(viewerID: String, isReoffer: Bool) async {
        guard offerInFlight.insert(viewerID).inserted else { return }
        do {
            let offer = try await (isReoffer
                ? peerHost.createReoffer(for: viewerID)
                : peerHost.createOffer(for: viewerID))
            try await signaling.send(GoPeepV1Message(
                type: .offer,
                sdp: offer.sdp,
                peerID: viewerID
            ))
            offerSent.insert(viewerID)
            for candidate in pendingLocalICE.removeValue(forKey: viewerID) ?? [] {
                try await sendLocalICE(candidate, viewerID: viewerID)
            }
        } catch {
            offerInFlight.remove(viewerID)
            failure = "could not send native WebRTC offer: \(error.localizedDescription)"
        }
    }

    fileprivate func receivePeerEvent(_ event: WebRTCPeerHostEvent) async {
        switch event {
        case .localICECandidate(let viewerID, let candidate):
            do {
                if offerSent.contains(viewerID) {
                    try await sendLocalICE(candidate, viewerID: viewerID)
                } else {
                    pendingLocalICE[viewerID, default: []].append(candidate)
                }
            } catch {
                failure = "could not send native ICE: \(error.localizedDescription)"
            }

        case .controlDataChannelStateChanged(let viewerID, let state):
            guard state == .open else { return }
            do {
                controlOpen = true
                controlViewerID = viewerID
                _ = try peerHost.sendControl(
                    GoPeepV1Message(type: .streamsInfo, streams: []),
                    to: viewerID
                )
            } catch {
                failure = "could not send GoPeep control metadata: \(error.localizedDescription)"
            }

        case .connectionStateChanged(_, let state):
            if state == .failed {
                failure = "native-to-WebKit peer connection failed"
            }

        case .negotiationNeeded(let viewerID):
            await sendOffer(viewerID: viewerID, isReoffer: true)

        case .error(_, let error):
            failure = error.localizedDescription

        default:
            break
        }
    }

    private func sendLocalICE(
        _ candidate: WebRTCICECandidate,
        viewerID: String
    ) async throws {
        let data = try JSONEncoder().encode(candidate)
        try await signaling.send(GoPeepV1Message(
            type: .ice,
            candidate: String(decoding: data, as: UTF8.self),
            peerID: viewerID
        ))
    }

    private static let fixtureMetadata = GoPeepV1StreamInfo(
        trackID: "video0",
        windowName: "WebKit Fixture",
        appName: "Clip Acceptance",
        isFocused: true,
        width: 2_762,
        height: 1_202
    )
}

private final class WebKitPeerEventBridge: @unchecked Sendable {
    weak var harness: WebKitGoPeepHostHarness?

    func receive(_ event: WebRTCPeerHostEvent) {
        Task { [weak harness] in
            await harness?.receivePeerEvent(event)
        }
    }
}

private struct WebKitViewerSnapshot: Decodable {
    let readyState: String
    let statusText: String
    let hasVideoSource: Bool
    let videoWidth: Int
    let videoHeight: Int
    let decodedFrames: Int
    let metadataMatchesFixture: Bool
    let cursorMetadataConsumed: Bool
    let streamOrder: [Int]
}

@MainActor
private func webKitViewerSnapshot(_ webView: WKWebView) async throws -> WebKitViewerSnapshot {
    let script = #"""
    (() => {
      const video = document.getElementById("main-video");
      if (!window.__clipWebKitFrameProbe) {
        const probe = { presentedFrames: 0, lastMediaTime: 0 };
        window.__clipWebKitFrameProbe = probe;
        if (video && typeof video.requestVideoFrameCallback === "function") {
          const observe = (_now, metadata) => {
            probe.presentedFrames += 1;
            probe.lastMediaTime = metadata?.mediaTime || 0;
            video.requestVideoFrameCallback(observe);
          };
          video.requestVideoFrameCallback(observe);
        }
      }
      const info = typeof streamsInfo === "undefined" ? [] : streamsInfo;
      const order = typeof streamOrder === "undefined" ? [] : streamOrder;
      const cursor = typeof cursorFollowState === "undefined" ? null : cursorFollowState;
      const playback = video && typeof video.getVideoPlaybackQuality === "function"
        ? video.getVideoPlaybackQuality() : null;
      const frames = playback && Number.isFinite(playback.totalVideoFrames)
        ? playback.totalVideoFrames
        : (video && Number.isFinite(video.webkitDecodedFrameCount)
            ? video.webkitDecodedFrameCount : 0);
      const observedFrames = window.__clipWebKitFrameProbe?.presentedFrames || 0;
      const fixture = info.find((item) => item.trackId === "video0");
      return JSON.stringify({
        readyState: document.readyState,
        statusText: document.getElementById("status-text")?.textContent || "",
        hasVideoSource: !!video?.srcObject,
        videoWidth: video?.videoWidth || 0,
        videoHeight: video?.videoHeight || 0,
        decodedFrames: Math.max(frames || 0, observedFrames),
        metadataMatchesFixture: !!fixture &&
          fixture.windowName === "WebKit Fixture" &&
          fixture.appName === "Clip Acceptance" &&
          fixture.width === 2762 && fixture.height === 1202 &&
          fixture.isFocused === true,
        cursorMetadataConsumed: !!cursor && cursor.cursorInView === true,
        streamOrder: Array.from(order),
      });
    })()
    """#
    let result = try await webView.evaluateJavaScript(script)
    guard let json = result as? String,
          let data = json.data(using: .utf8) else {
        throw WebKitAcceptanceError.invalidBrowserSnapshot
    }
    return try JSONDecoder().decode(WebKitViewerSnapshot.self, from: data)
}

@MainActor
private func waitForWebKitSnapshot(
    webView: WKWebView,
    timeout: Duration,
    predicate: (WebKitViewerSnapshot) -> Bool
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        do {
            if predicate(try await webKitViewerSnapshot(webView)) { return true }
        } catch {
            // The JavaScript context is unavailable while the navigation is replacing it.
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    return predicate(try await webKitViewerSnapshot(webView))
}

private enum WebKitAcceptanceError: Error, LocalizedError {
    case invalidBrowserSnapshot
    case timeout(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .invalidBrowserSnapshot:
            "WebKit returned an invalid GoPeep viewer snapshot."
        case .timeout(let operation):
            "Timed out waiting for \(operation)."
        case .runtime(let message):
            message
        }
    }
}

private func makeWebKitFixtureFrame(
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
        throw WebKitAcceptanceError.runtime("could not create fixture pixel buffer")
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0 ..< height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< width {
                let offset = x * 4
                row[offset] = UInt8((x + index * 3) & 0xff)
                row[offset + 1] = UInt8((y * 2 + index * 5) & 0xff)
                row[offset + 2] = UInt8(((x / 16 + y / 16 + index / 3) & 1) * 255)
                row[offset + 3] = 255
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    var formatDescription: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    ) == noErr,
        let formatDescription else {
        throw WebKitAcceptanceError.runtime("could not describe fixture pixel buffer")
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
        throw WebKitAcceptanceError.runtime("could not create fixture sample buffer")
    }
    return BorrowedCaptureVideoFrame(
        sampleBuffer: sampleBuffer,
        pixelBuffer: pixelBuffer,
        presentationTime: presentationTime
    )
}
