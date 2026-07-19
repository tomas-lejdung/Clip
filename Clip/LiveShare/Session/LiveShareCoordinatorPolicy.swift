import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import CoreGraphics
import Foundation

enum LiveShareCoordinatorPolicy {
    static let maximumReconnectAttempts = 5

    /// GoPeep's `error` field is controlled by the signaling service and may
    /// echo room credentials or SDP. Never carry that text into public OSLog
    /// diagnostics; the protocol type already provides enough classification.
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

    static func senderPolicy(
        for settings: LiveShareSettings,
        isFocused: Bool = true
    ) -> WebRTCSenderPolicy {
        let selectedBitrate = settings.quality.maximumBitrateBitsPerSecond
        let maximumBitrate = settings.adaptiveBitrateEnabled && !isFocused
            ? max(500_000, selectedBitrate / 3)
            : selectedBitrate
        return WebRTCSenderPolicy(
            maximumBitrateBps: maximumBitrate,
            maximumFramesPerSecond: settings.frameRate.rawValue,
            maintainsResolution: settings.encodingMode == .quality
        )
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
        case .reservationFailed:
            String(localized: "Couldn’t create a share link. Try again.")
        case .signalingFailed, .connectionLost:
            String(localized: "The Live Share connection was lost. Try again.")
        case .captureFailed:
            String(localized: "Clip couldn’t capture the selected source.")
        case .encoderFailed:
            String(localized: "The H.264 encoder couldn’t start.")
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

/// MainActor-owned sampling state for capture delivery. Entries are keyed by
/// domain source but also retain the capture generation, so late statistics from
/// a stopped session can neither raise nor clear the replacement session's alert.
struct LiveShareCapturePressureLedger {
    private struct Entry {
        let generation: UUID
        var monitor: CaptureBackpressureMonitor
        var statistics: CaptureDeliveryStatistics
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
            } else {
                entry = Entry(
                    generation: sample.generation,
                    monitor: CaptureBackpressureMonitor(policy: policy),
                    statistics: sample.statistics
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

struct LiveSharePeerNegotiationLedger {
    private let resourceLimits: WebRTCPeerResourceLimits

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

    init(resourceLimits: WebRTCPeerResourceLimits = .goPeepDefault) {
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
    ) -> WebRTCICECandidate? {
        guard var entry = entries[viewerID] else { return nil }
        guard (try? candidate.validate(resourceLimits: resourceLimits)) != nil else {
            return nil
        }
        guard entry.isRemoteDescriptionReady else {
            guard entry.bufferedRemoteICE.count
                < resourceLimits.maximumICECandidatesPerPeer else {
                return nil
            }
            entry.bufferedRemoteICE.append(candidate)
            entries[viewerID] = entry
            return nil
        }
        return candidate
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
