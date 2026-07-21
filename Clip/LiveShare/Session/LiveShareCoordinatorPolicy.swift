import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import CoreGraphics
import Foundation

enum LiveShareCoordinatorPolicy {
    static let maximumReconnectAttempts = 7

    /// Recording click highlights are a separate, file-capture preference.
    /// Live Share does not expose that setting and ScreenCaptureKit can place
    /// the system highlight in the wrong coordinate space after a live window
    /// resize, so every network capture keeps it disabled explicitly.
    static func captureVideoConfiguration(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        showsCursor: Bool = true,
        sourceRect: CGRect? = nil
    ) -> CaptureVideoConfiguration {
        CaptureVideoConfiguration(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            showsCursor: showsCursor,
            showsClickHighlights: false,
            sourceRect: sourceRect
        )
    }

    /// ScreenCaptureKit input geometry for a live source. Native pixels remain
    /// untouched whenever they fit the H.264 hardware envelope, including odd
    /// dimensions. H.264's even output alignment is applied separately by
    /// `streamGeometry`; asking ScreenCaptureKit to turn 1,605 pixels into
    /// 1,604 would fractionally rescale every pixel and soften text.
    ///
    /// Apple Silicon's hardware H.264 encoder still rejects geometry above a
    /// 4,096-pixel side (including 5K and 6K displays), so oversized sources
    /// are aspect-fit and macroblock-aligned before capture. VP8, VP9, and AV1
    /// keep exact native geometry because none of those H.264 limits apply to
    /// their libwebrtc software encoders.
    static func captureGeometry(
        sourceWidth: Int,
        sourceHeight: Int,
        codec: LiveShareVideoCodec,
        framesPerSecond: Int = 30
    ) -> LiveShareCaptureGeometry {
        let width = max(1, sourceWidth)
        let height = max(1, sourceHeight)
        guard codec == .h264 else {
            return LiveShareCaptureGeometry(width: width, height: height)
        }

        let maximumSide = 4_096.0
        let maximumLevelMacroblocksPerFrame = 36_864
        let maximumLevelMacroblocksPerSecond = 2_073_600
        let cadence = max(1, framesPerSecond)
        let maximumMacroblocksPerFrame = min(
            maximumLevelMacroblocksPerFrame,
            max(1, maximumLevelMacroblocksPerSecond / cadence)
        )
        let maximumLuma = Double(maximumMacroblocksPerFrame * 16 * 16)
        let sourceLuma = Double(width) * Double(height)
        let scale = min(
            1,
            maximumSide / Double(width),
            maximumSide / Double(height),
            sqrt(maximumLuma / sourceLuma)
        )
        // A tiny epsilon prevents an exactly representable boundary such as
        // 6,016 × 3,384 → 4,096 × 2,304 from losing two pixels to binary
        // floating-point rounding before the even-alignment step.
        var fittedWidth = max(2, Int((Double(width) * scale + 1e-7).rounded(.down)))
        var fittedHeight = max(2, Int((Double(height) * scale + 1e-7).rounded(.down)))
        if scale < 1 {
            // H.264 Level 5.2 is expressed in 16×16 macroblocks, not only
            // visible luma pixels. Align a downscaled result to macroblocks so
            // codec padding cannot push an unusual aspect ratio beyond 36,864.
            if fittedWidth >= 16 { fittedWidth -= fittedWidth % 16 }
            if fittedHeight >= 16 { fittedHeight -= fittedHeight % 16 }
        }
        var encodedWidth = videoEncoderCompatibleDimension(fittedWidth)
        var encodedHeight = videoEncoderCompatibleDimension(fittedHeight)
        let macroblocks = ((encodedWidth + 15) / 16) * ((encodedHeight + 15) / 16)
        var requiresConstrainedCapture = scale < 1
        if macroblocks > maximumMacroblocksPerFrame {
            // A source can fit the visible-luma envelope yet exceed Level 5.2
            // after codec padding. Only those boundary cases lose the final
            // partial macroblock; normal under-limit geometry stays unchanged.
            if encodedWidth >= 16 { encodedWidth -= encodedWidth % 16 }
            if encodedHeight >= 16 { encodedHeight -= encodedHeight % 16 }
            requiresConstrainedCapture = true
        }
        guard requiresConstrainedCapture else {
            return LiveShareCaptureGeometry(width: width, height: height)
        }
        return LiveShareCaptureGeometry(width: encodedWidth, height: encodedHeight)
    }

    /// Dimensions advertised to WebRTC and produced by the encoder. Software
    /// codecs can encode the capture geometry directly. H.264 aligns down by
    /// at most one pixel per axis; the native pixel buffer remains unchanged
    /// and the VideoToolbox bridge performs a top-left crop instead of a scale.
    static func streamGeometry(
        captureGeometry: LiveShareCaptureGeometry,
        codec: LiveShareVideoCodec
    ) -> LiveShareCaptureGeometry {
        guard codec == .h264 else { return captureGeometry }
        return LiveShareCaptureGeometry(
            width: videoEncoderCompatibleDimension(captureGeometry.width),
            height: videoEncoderCompatibleDimension(captureGeometry.height)
        )
    }

    /// A signaling-service error is untrusted input. Never carry its text into
    /// public OSLog diagnostics; the protocol type provides enough context.
    static func redactedSignalingFailureDescription(
        serverMessage: String
    ) -> String {
        _ = serverMessage
        return "The signaling server rejected a request."
    }

    static func sourceIdentifier(_ id: LiveShareSourceID) -> String {
        switch id {
        case let .window(windowID):
            "window:\(windowID.rawValue)"
        case let .fullscreen(displayID):
            "display:\(displayID.rawValue)"
        }
    }

    static func sourceIdentifier(_ source: LiveShareSource) -> String {
        sourceIdentifier(source.id)
    }

    static func sourceID(from identifier: String) -> LiveShareSourceID? {
        let pieces = identifier.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2, let rawValue = UInt32(pieces[1]) else { return nil }
        switch pieces[0] {
        case "window":
            return .window(LiveShareWindowID(rawValue: rawValue))
        case "display":
            return .fullscreen(LiveShareDisplayID(rawValue: rawValue))
        default:
            return nil
        }
    }

    /// Builds the one mixed system-audio capture request for the current Live
    /// Share selection. Window audio is application-scoped in ScreenCaptureKit,
    /// so several shared windows from one application deliberately contribute
    /// only one bundle identifier. The caller owns the request identifier so a
    /// source refresh can update an existing audio session without changing its
    /// logical identity.
    static func captureAudioRequest(
        systemAudioEnabled: Bool,
        sources: LiveShareSourceSelection,
        knownWindows: [LiveShareWindowID: ShareableCaptureWindow],
        filterDisplayID: CGDirectDisplayID,
        clipBundleIdentifier: String,
        requestIdentifier: UUID
    ) -> CaptureAudioSessionRequest? {
        guard systemAudioEnabled else { return nil }

        if let fullscreen = sources.fullscreen {
            return CaptureAudioSessionRequest(
                identifier: requestIdentifier,
                scope: .system(
                    displayID: fullscreen.id.rawValue,
                    excludedBundleIdentifier: clipBundleIdentifier
                )
            )
        }

        let bundleIdentifiers: Set<String> = Set(
            sources.windows.compactMap { source in
                guard let window = knownWindows[source.id] else { return nil }
                let identifier = window.bundleIdentifier
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return identifier.isEmpty ? nil : identifier
            }
        )
        guard !bundleIdentifiers.isEmpty else { return nil }

        return CaptureAudioSessionRequest(
            identifier: requestIdentifier,
            scope: .applications(
                displayID: filterDisplayID,
                bundleIdentifiers: bundleIdentifiers
            )
        )
    }

    static func senderPolicy(
        for settings: LiveShareSettings,
        maximumBitrateBps: Int? = nil,
        bitratePriority: Double = 1
    ) -> WebRTCSenderPolicy {
        return WebRTCSenderPolicy(
            maximumBitrateBps: maximumBitrateBps
                ?? settings.quality.maximumBitrateBitsPerSecond,
            maximumFramesPerSecond: settings.frameRate.rawValue,
            maintainsResolution: settings.encodingMode == .quality,
            bitratePriority: bitratePriority
        )
    }

    /// Divides one viewer's selected video budget across all active tracks.
    /// A focused window receives four shares while each background window
    /// receives one when focus prioritization is enabled. This keeps the sum
    /// bounded by the selected Mbps value instead of multiplying it by the
    /// number of shared windows.
    static func senderPolicies(
        for settings: LiveShareSettings,
        slots: LiveShareTrackSlotAllocation
    ) -> [Int: WebRTCSenderPolicy] {
        let activeSlots = slots.activeSlots.sorted { $0.index < $1.index }
        guard !activeSlots.isEmpty else { return [:] }

        let prioritizesFocus = settings.prioritizeFocusedWindow
            && activeSlots.count > 1
            && activeSlots.contains(where: \.isFocused)
        let weights = activeSlots.map { slot in
            prioritizesFocus && slot.isFocused ? 4 : 1
        }
        let totalWeight = weights.reduce(0, +)
        let totalBudget = settings.quality.maximumBitrateBitsPerSecond
        var allocations = zip(activeSlots, weights).map { slot, weight in
            (slot, totalBudget * weight / totalWeight)
        }

        // Integer division can leave a few bits undistributed. Give those to
        // the focused (or first) stream while preserving the exact total cap.
        let allocated = allocations.reduce(0) { $0 + $1.1 }
        if let remainderIndex = allocations.firstIndex(where: { $0.0.isFocused })
            ?? allocations.indices.first
        {
            allocations[remainderIndex].1 += totalBudget - allocated
        }

        return Dictionary(uniqueKeysWithValues: allocations.map { slot, bitrate in
            (
                slot.index,
                senderPolicy(
                    for: settings,
                    maximumBitrateBps: bitrate,
                    bitratePriority: prioritizesFocus && slot.isFocused ? 4 : 1
                )
            )
        })
    }

    /// Stream statistics aggregate actual and target bitrate across every
    /// sampled viewer. Present the matching aggregate configured ceiling so a
    /// second viewer cannot make a healthy stream appear to exceed its limit.
    static func aggregateConfiguredBitrateCeiling(
        perViewer: Int,
        viewerCount: Int
    ) -> Int {
        let perViewer = max(0, perViewer)
        let viewerCount = max(0, viewerCount)
        let (total, overflow) = perViewer.multipliedReportingOverflow(by: viewerCount)
        return overflow ? Int.max : total
    }

    /// libwebrtc's H.264 path crops odd BGRA input down to even 4:2:0 output.
    /// Capture retains the exact native pixels; metadata advertises the decoded
    /// geometry so the viewer never adds a one-pixel CSS rescale.
    static func videoEncoderCompatibleDimension(_ value: Int) -> Int {
        let positive = max(2, value)
        return positive - positive % 2
    }

    static func preferredFullscreenDisplay(
        from displays: [ShareableCaptureDisplay],
        focusedWindowFrame: CGRect?,
        primaryDisplayID: CGDirectDisplayID
    ) -> ShareableCaptureDisplay? {
        if let focusedWindowFrame {
            let candidate = displays.max { lhs, rhs in
                intersectionArea(lhs.frame, focusedWindowFrame)
                    < intersectionArea(rhs.frame, focusedWindowFrame)
            }
            if let candidate,
               intersectionArea(candidate.frame, focusedWindowFrame) > 0 {
                return candidate
            }
        }
        return displays.first(where: { $0.id == primaryDisplayID }) ?? displays.first
    }

    /// Captures enough durable source information to put the current window
    /// shares back if the mutually-exclusive fullscreen capture cannot start.
    /// The domain source is deliberately retained separately from the current
    /// ScreenCaptureKit window so user-visible metadata does not change during
    /// a failed mode switch.
    static func fullscreenRollbackPlan(
        sources: LiveShareSourceSelection,
        slots: LiveShareTrackSlotAllocation,
        knownWindows: [LiveShareWindowID: ShareableCaptureWindow]
    ) -> LiveShareFullscreenRollbackPlan {
        let windows = sources.windows.compactMap { source -> LiveShareFullscreenRollbackWindow? in
            guard let window = knownWindows[source.id] else { return nil }
            return LiveShareFullscreenRollbackWindow(source: source, window: window)
        }
        let focusedSourceID = slots.activeSlots.first(where: \.isFocused)?.source?.id
        let restorableIDs = Set(windows.map { LiveShareSourceID.window($0.source.id) })
        return LiveShareFullscreenRollbackPlan(
            windows: windows,
            focusedSourceID: focusedSourceID.flatMap {
                restorableIDs.contains($0) ? $0 : nil
            }
        )
    }

    static func viewerConnection(
        from state: WebRTCPeerConnectionState,
        route: WebRTCConnectionRoute = .unknown
    ) -> LiveShareViewerConnection {
        switch state {
        case .new, .connecting:
            .connecting
        case .connected:
            switch route {
            case .unknown:
                .connected
            case .direct:
                .peerToPeer
            case .relay:
                .turn
            }
        case .disconnected, .failed, .closed:
            .disconnected
        }
    }

    static func permitsWindowShare(
        isAlreadyShared: Bool,
        hasFullscreenSource: Bool,
        activeWindowCount: Int,
        autoShareEnabled: Bool
    ) -> Bool {
        isAlreadyShared
            || hasFullscreenSource
            || activeWindowCount < LiveShareSourceSelection.maximumWindowCount
            || autoShareEnabled
    }

    static func menuBarStatus(for phase: LiveShareViewPhase) -> LiveShareMenuBarStatus {
        switch phase {
        case .live:
            .live
        case .reconnecting:
            .reconnecting
        case .failed:
            .failed
        case .inactive, .reservingRoom, .connecting, .ready, .starting, .stopping:
            .ready
        }
    }

    static func userFacingFailure(_ failure: LiveShareFailure?) -> String {
        switch failure?.code {
        case .identityUnavailable:
            String(localized: "Clip couldn’t access this Mac’s secure Live Share identity. Try again.")
        case .reservationFailed:
            String(localized: "Couldn’t create a share link. Try again.")
        case .signalingFailed, .connectionLost:
            String(localized: "The Live Share connection was lost. Try again.")
        case .captureFailed:
            String(localized: "Clip couldn’t capture the selected source.")
        case .encoderFailed:
            String(localized: "The video encoder couldn’t start.")
        case .peerConnectionFailed:
            String(localized: "A viewer connection couldn’t be established.")
        case .unknown, nil:
            String(localized: "Live Share couldn’t complete this action. Try again.")
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.standardized.intersection(rhs.standardized)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }
}

struct LiveShareCaptureGeometry: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// MainActor-owned sampling state for capture delivery. Entries are keyed by
/// domain source but also retain the capture generation, so late statistics from
/// a stopped session can neither raise nor clear the replacement session's alert.
struct LiveShareCapturePressureLedger {
    private struct Entry {
        let generation: UUID
        var monitor: CaptureBackpressureMonitor
        var statistics: CaptureDeliveryStatistics
        var latestBackpressureDrops: UInt64
    }

    private let policy: CaptureBackpressurePolicy
    private var entries: [LiveShareSourceID: Entry] = [:]

    init(policy: CaptureBackpressurePolicy = .sustainedLiveVideo) {
        self.policy = policy
    }

    mutating func update(
        _ samples: [LiveShareCaptureDeliverySnapshot],
        activeGenerations: [LiveShareSourceID: UUID]
    ) {
        let obsolete = entries.compactMap { sourceID, entry in
            activeGenerations[sourceID] == entry.generation ? nil : sourceID
        }
        for sourceID in obsolete {
            entries[sourceID] = nil
        }

        var observedSources = Set<LiveShareSourceID>()
        for sample in samples {
            let sourceID = sample.source.id
            guard activeGenerations[sourceID] == sample.generation,
                  observedSources.insert(sourceID).inserted else {
                continue
            }

            var entry: Entry
            if let current = entries[sourceID], current.generation == sample.generation {
                entry = current
                entry.latestBackpressureDrops = sample.statistics.backpressureDrops
                    >= current.statistics.backpressureDrops
                    ? sample.statistics.backpressureDrops
                        - current.statistics.backpressureDrops
                    : 0
            } else {
                entry = Entry(
                    generation: sample.generation,
                    monitor: CaptureBackpressureMonitor(policy: policy),
                    statistics: sample.statistics,
                    latestBackpressureDrops: 0
                )
            }
            entry.statistics = sample.statistics
            entry.monitor.observe(sample.statistics)
            entries[sourceID] = entry
        }
    }

    func isOverloaded(_ sourceID: LiveShareSourceID, generation: UUID?) -> Bool {
        guard let generation,
              let entry = entries[sourceID],
              entry.generation == generation else {
            return false
        }
        return entry.monitor.health == .sustainedOverload
    }

    func statistics(
        for sourceID: LiveShareSourceID,
        generation: UUID?
    ) -> CaptureDeliveryStatistics? {
        guard let generation,
              let entry = entries[sourceID],
              entry.generation == generation else {
            return nil
        }
        return entry.statistics
    }

    /// Drops observed since the preceding statistics sample. WebRTC's drop
    /// value is also displayed as a per-sample delta, so keeping this interval
    /// count avoids comparing a lifetime capture total with a one-second RTC
    /// value in the same row.
    func latestBackpressureDrops(
        for sourceID: LiveShareSourceID,
        generation: UUID?
    ) -> UInt64 {
        guard let generation,
              let entry = entries[sourceID],
              entry.generation == generation else {
            return 0
        }
        return entry.latestBackpressureDrops
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }
}

struct LiveShareFullscreenRollbackWindow: Equatable, Sendable {
    let source: LiveShareWindowSource
    let window: ShareableCaptureWindow
}

struct LiveShareFullscreenRollbackPlan: Equatable, Sendable {
    let windows: [LiveShareFullscreenRollbackWindow]
    let focusedSourceID: LiveShareSourceID?

    var isEmpty: Bool { windows.isEmpty }
}

enum LiveShareMenuBarStatus: Equatable, Sendable {
    case ready
    case live
    case reconnecting
    case failed

    var symbolName: String {
        switch self {
        case .ready:
            "dot.radiowaves.left.and.right"
        case .live:
            "record.circle.fill"
        case .reconnecting:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .ready:
            String(localized: "Clip Live Share is ready")
        case .live:
            String(localized: "Clip Live Share is live")
        case .reconnecting:
            String(localized: "Clip Live Share is reconnecting")
        case .failed:
            String(localized: "Clip Live Share needs attention")
        }
    }
}

enum LiveShareViewerAdmissionCapacity {
    static func canBegin(
        routeID: String,
        allocatedViewerIDs: some Sequence<String>,
        pendingRouteIDs: some Sequence<String>,
        maximumViewers: Int
    ) -> Bool {
        let pending = Set(pendingRouteIDs)
        guard maximumViewers > 0, !pending.contains(routeID) else { return false }
        var distinctViewerIDs = Set(allocatedViewerIDs)
        distinctViewerIDs.formUnion(pending)
        return distinctViewerIDs.count < maximumViewers
    }
}

/// Keeps browser/native-v1 introduction routes alive while the host is ready
/// but has not pressed Start yet. The relay route carries no authentication or
/// media in this phase; it is only a bounded rendezvous placeholder that can be
/// promoted once the host installs the peer runtime.
enum LiveSharePreparedViewerRouteBuffer {
    static func retain(
        _ routeID: ClipLiveShareRouteID,
        in routeIDs: inout Set<ClipLiveShareRouteID>,
        maximumCount: Int
    ) -> Bool {
        if routeIDs.contains(routeID) { return true }
        guard maximumCount > 0, routeIDs.count < maximumCount else {
            return false
        }
        routeIDs.insert(routeID)
        return true
    }

    static func cancel(
        _ routeID: ClipLiveShareRouteID,
        in routeIDs: inout Set<ClipLiveShareRouteID>
    ) {
        routeIDs.remove(routeID)
    }

    static func drain(
        _ routeIDs: inout Set<ClipLiveShareRouteID>
    ) -> Set<ClipLiveShareRouteID> {
        defer { routeIDs.removeAll() }
        return routeIDs
    }
}

struct LiveShareViewerAdmissionProgress: Equatable {
    private(set) var didReceiveSignalingHandoff = false
    private(set) var didOpenControlDataChannel = false

    var remainsPending: Bool { !didOpenControlDataChannel }

    mutating func receiveSignalingHandoff() {
        didReceiveSignalingHandoff = true
    }

    mutating func openControlDataChannel() {
        didOpenControlDataChannel = true
    }
}

struct LiveSharePeerNegotiationLedger {
    private let resourceLimits: WebRTCPeerResourceLimits

    enum RemoteICEDisposition: Equatable {
        case buffered
        case ready(WebRTCICECandidate)
        case rejected
    }

    struct OfferToken: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    private struct Entry {
        let token: OfferToken
        var isOfferInFlight = true
        var isAnswerEligible = false
        var isOfferSent = false
        var isRemoteDescriptionReady = false
        var bufferedLocalICE: [WebRTCICECandidate] = []
        var bufferedRemoteICE: [WebRTCICECandidate] = []
    }

    private var entries: [String: Entry] = [:]

    init(resourceLimits: WebRTCPeerResourceLimits = .clipDefault) {
        self.resourceLimits = resourceLimits.normalized
    }

    mutating func beginOffer(for viewerID: String) -> OfferToken? {
        guard entries[viewerID]?.isOfferInFlight != true else { return nil }
        guard !viewerID.isEmpty,
              viewerID.utf8.count <= resourceLimits.maximumViewerIDBytes,
              viewerID.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        guard entries[viewerID] != nil
                || entries.count < resourceLimits.maximumViewerCount else {
            return nil
        }
        let token = OfferToken()
        entries[viewerID] = Entry(token: token)
        return token
    }

    func contains(_ token: OfferToken, for viewerID: String) -> Bool {
        entries[viewerID]?.token == token
    }

    func tokenAwaitingAnswer(for viewerID: String) -> OfferToken? {
        guard let entry = entries[viewerID],
              entry.isAnswerEligible,
              !entry.isRemoteDescriptionReady else { return nil }
        return entry.token
    }

    /// Opens the answer gate immediately before the signaling send suspends.
    /// A fast browser can return its answer before `send(_:)` resumes on the
    /// MainActor, while local ICE must remain buffered until that send succeeds.
    @discardableResult
    mutating func markOfferAnswerEligible(
        for viewerID: String,
        token: OfferToken
    ) -> Bool {
        guard var entry = entries[viewerID],
              entry.token == token,
              entry.isOfferInFlight,
              !entry.isAnswerEligible else {
            return false
        }
        entry.isAnswerEligible = true
        entries[viewerID] = entry
        return true
    }

    mutating func receiveLocalICE(
        _ candidate: WebRTCICECandidate,
        for viewerID: String
    ) -> WebRTCICECandidate? {
        guard var entry = entries[viewerID] else { return nil }
        guard (try? candidate.validate(resourceLimits: resourceLimits)) != nil else {
            return nil
        }
        guard entry.isOfferSent else {
            guard entry.bufferedLocalICE.count
                < resourceLimits.maximumICECandidatesPerPeer else {
                return nil
            }
            entry.bufferedLocalICE.append(candidate)
            entries[viewerID] = entry
            return nil
        }
        return candidate
    }

    mutating func markOfferSent(
        for viewerID: String,
        token: OfferToken
    ) -> [WebRTCICECandidate]? {
        guard var entry = entries[viewerID],
              entry.token == token,
              entry.isAnswerEligible,
              !entry.isOfferSent else { return nil }
        entry.isOfferSent = true
        if entry.isRemoteDescriptionReady {
            entry.isOfferInFlight = false
        }
        let buffered = entry.bufferedLocalICE
        entry.bufferedLocalICE.removeAll(keepingCapacity: false)
        entries[viewerID] = entry
        return buffered
    }

    mutating func receiveRemoteICE(
        _ candidate: WebRTCICECandidate,
        for viewerID: String
    ) -> RemoteICEDisposition {
        guard var entry = entries[viewerID] else { return .rejected }
        guard (try? candidate.validate(resourceLimits: resourceLimits)) != nil else {
            return .rejected
        }
        guard entry.isRemoteDescriptionReady else {
            guard entry.bufferedRemoteICE.count
                < resourceLimits.maximumICECandidatesPerPeer else {
                return .rejected
            }
            entry.bufferedRemoteICE.append(candidate)
            entries[viewerID] = entry
            return .buffered
        }
        return .ready(candidate)
    }

    mutating func completeAnswer(
        for viewerID: String,
        token: OfferToken
    ) -> [WebRTCICECandidate]? {
        guard var entry = entries[viewerID],
              entry.token == token,
              entry.isAnswerEligible,
              !entry.isRemoteDescriptionReady else { return nil }
        entry.isRemoteDescriptionReady = true
        if entry.isOfferSent {
            entry.isOfferInFlight = false
        }
        let buffered = entry.bufferedRemoteICE
        entry.bufferedRemoteICE.removeAll(keepingCapacity: false)
        entries[viewerID] = entry
        return buffered
    }

    mutating func remove(_ viewerID: String) {
        entries[viewerID] = nil
    }

    @discardableResult
    mutating func remove(_ viewerID: String, token: OfferToken) -> Bool {
        guard entries[viewerID]?.token == token else { return false }
        entries[viewerID] = nil
        return true
    }

    mutating func removeAll() {
        self = Self(resourceLimits: resourceLimits)
    }

}

/// Tracks viewers that may have missed a durable control-plane update.
/// Cursor positions are intentionally excluded because the next sample always
/// supersedes the previous one.
struct LiveShareAuthoritativeControlDeliveryLedger {
    static let defaultMaximumReplayAttempts = 4
    static let defaultMaximumTrackedPeers = 32

    private let maximumReplayAttempts: Int
    private let maximumTrackedPeers: Int
    private var attemptsByViewerID: [String: Int] = [:]

    init(
        maximumReplayAttempts: Int = defaultMaximumReplayAttempts,
        maximumTrackedPeers: Int = defaultMaximumTrackedPeers
    ) {
        self.maximumReplayAttempts = max(1, maximumReplayAttempts)
        self.maximumTrackedPeers = max(1, maximumTrackedPeers)
    }

    var dirtyViewerIDs: [String] {
        attemptsByViewerID.keys.sorted()
    }

    mutating func recordLifecycleDelivery(_ result: WebRTCControlDeliveryResult) {
        markDirty(result.unavailableViewerIDs)
    }

    mutating func markDirty(_ viewerID: String) {
        markDirty([viewerID])
    }

    mutating func markDirty(_ viewerIDs: some Sequence<String>) {
        for viewerID in viewerIDs where !viewerID.isEmpty {
            guard attemptsByViewerID[viewerID] != nil
                    || attemptsByViewerID.count < maximumTrackedPeers else {
                continue
            }
            // A new authoritative mutation receives a fresh bounded retry
            // budget even when an older snapshot exhausted its attempts.
            attemptsByViewerID[viewerID] = 0
        }
    }

    /// Re-arms an exhausted replay only when that viewer still has dirty
    /// authoritative state. A stale native drain callback must not create new
    /// work after a newer snapshot was already delivered.
    mutating func recordNativeControlDrain(_ viewerID: String) {
        guard attemptsByViewerID[viewerID] != nil else { return }
        attemptsByViewerID[viewerID] = 0
    }

    mutating func beginReplay(for viewerID: String) -> Bool {
        guard let attempts = attemptsByViewerID[viewerID],
              attempts < maximumReplayAttempts else { return false }
        attemptsByViewerID[viewerID] = attempts + 1
        return true
    }

    mutating func markReplayDelivered(to viewerID: String) {
        attemptsByViewerID[viewerID] = nil
    }

    func canReplay(to viewerID: String) -> Bool {
        guard let attempts = attemptsByViewerID[viewerID] else { return false }
        return attempts < maximumReplayAttempts
    }

    mutating func remove(_ viewerID: String) {
        attemptsByViewerID[viewerID] = nil
    }

    mutating func removeAll() {
        attemptsByViewerID.removeAll(keepingCapacity: false)
    }
}

enum LiveShareFullscreenPostStopAction: Equatable, Sendable {
    case continueToFullscreen
    case restoreWindows
    case abandon
}

/// Tracks both identity and intent for fullscreen requests. Identity alone is
/// insufficient once enabling fullscreen has crossed its destructive boundary:
/// a newer OFF request must restore the windows that the suspended ON request
/// stopped, while Stop All and session termination must not restore them.
struct LiveShareFullscreenRequestGate {
    struct Request: Equatable, Sendable {
        fileprivate let id: UUID
        let isEnabled: Bool
    }

    private var current: Request?

    mutating func begin(isEnabled: Bool) -> Request {
        let request = Request(id: UUID(), isEnabled: isEnabled)
        current = request
        return request
    }

    func contains(_ request: Request) -> Bool {
        current == request
    }

    /// Resolves work after the current window captures have already stopped.
    /// A replacement OFF request means "cancel fullscreen" and therefore rolls
    /// the transaction back. No current request means an independent teardown
    /// invalidated it, so the old operation must not recreate media.
    func actionAfterDestructiveStop(
        for request: Request
    ) -> LiveShareFullscreenPostStopAction {
        if contains(request) {
            return request.isEnabled ? .continueToFullscreen : .abandon
        }
        if current?.isEnabled == false {
            return .restoreWindows
        }
        return .abandon
    }

    /// A rollback may start because the original ON capture failed and remain
    /// valid if OFF replaces that request while restoration is suspended.
    func permitsWindowRollback(for request: Request) -> Bool {
        contains(request) || current?.isEnabled == false
    }

    mutating func finish(_ request: Request) {
        if current == request {
            current = nil
        }
    }

    mutating func invalidate() {
        current = nil
    }
}
