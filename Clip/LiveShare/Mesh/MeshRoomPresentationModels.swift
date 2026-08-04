import ClipLiveShare
import Foundation

enum MeshParticipantIdentityColor {
    /// Participant IDs are intentionally random per room. Collaboration
    /// attribution instead derives from the persistent signing identity so
    /// the same person keeps the same pointer and ping color across rooms.
    static func collaborationColor(
        forPersistentIdentity identity: Data
    ) -> ClipLiveShareNativeV3CollaborationColor {
        let digest = ClipLiveShareNativeDigest(hashing: identity)
        let bytes = Array(digest.bytes)
        return try! .init(
            red: 72 &+ bytes[0] % 152,
            green: 72 &+ bytes[1] % 152,
            blue: 72 &+ bytes[2] % 152
        )
    }
}

struct MeshParticipantCollaborationConfiguration: Equatable, Sendable {
    let pointerVisibleByDefault: Bool
    let identityColor: ClipLiveShareNativeV3CollaborationColor
    let inkColor: ClipLiveShareNativeV3CollaborationColor
    let pingDurationMilliseconds: Int64
    let inkExpiryMilliseconds: Int64

    init(settings: LiveShareSettings, persistentIdentity: Data) {
        pointerVisibleByDefault =
            settings.collaborationPointerVisibleByDefault
        identityColor = MeshParticipantIdentityColor.collaborationColor(
            forPersistentIdentity: persistentIdentity
        )
        inkColor = settings.collaborationInkColor
        pingDurationMilliseconds =
            Int64(settings.collaborationPingDurationSeconds) * 1_000
        inkExpiryMilliseconds =
            Int64(settings.collaborationInkExpirySeconds) * 1_000
    }

    func ping(
        context: ClipLiveShareNativeV3CollaborationContext,
        position: ClipLiveShareNativeV3NormalizedPoint
    ) throws -> ClipLiveShareNativeV3CollaborationEvent {
        .ping(
            try .init(
                context: context,
                position: position,
                color: identityColor,
                expiresAt: context.sentAt.adding(
                    milliseconds: pingDurationMilliseconds
                )
            )
        )
    }

    func strokeBegin(
        context: ClipLiveShareNativeV3CollaborationContext,
        strokeID: ClipLiveShareNativeV3StrokeID,
        point: ClipLiveShareNativeV3NormalizedPoint
    ) throws -> ClipLiveShareNativeV3CollaborationEvent {
        .strokeBegin(
            try .init(
                context: context,
                strokeID: strokeID,
                point: point,
                color: inkColor,
                expiresAt: context.sentAt.adding(
                    milliseconds: inkExpiryMilliseconds
                )
            )
        )
    }
}

struct MeshRoomMediaCounterKey: Equatable, Hashable, Sendable {
    let participantID: String
    let trackIdentifier: String
    let sourceIdentifier: String
    let direction: MeshRoomMediaDiagnosticsSnapshot.Direction

    init(
        participantID: String,
        trackIdentifier: String,
        sourceIdentifier: String,
        direction: MeshRoomMediaDiagnosticsSnapshot.Direction
    ) {
        self.participantID = participantID
        self.trackIdentifier = trackIdentifier
        self.sourceIdentifier = sourceIdentifier
        self.direction = direction
    }
}

struct MeshRoomMediaCounterSample: Equatable, Sendable {
    let capturedAt: Date
    let bytes: UInt64
    let frames: UInt64
    let reportedFramesPerSecond: Double
    let packets: UInt64
    let droppedFrames: UInt64
    let queuePressureDrops: UInt64
    let qpSum: UInt64?
    let targetBitrateBps: Double?
    let totalEncodeTimeSeconds: Double?
    let totalPacketSendDelaySeconds: Double?
    let qualityLimitationResolutionChanges: UInt64?

    init(
        capturedAt: Date,
        bytes: UInt64,
        frames: UInt64,
        reportedFramesPerSecond: Double,
        packets: UInt64 = 0,
        droppedFrames: UInt64 = 0,
        queuePressureDrops: UInt64 = 0,
        qpSum: UInt64? = nil,
        targetBitrateBps: Double? = nil,
        totalEncodeTimeSeconds: Double? = nil,
        totalPacketSendDelaySeconds: Double? = nil,
        qualityLimitationResolutionChanges: UInt64? = nil
    ) {
        self.capturedAt = capturedAt
        self.bytes = bytes
        self.frames = frames
        self.reportedFramesPerSecond = reportedFramesPerSecond
        self.packets = packets
        self.droppedFrames = droppedFrames
        self.queuePressureDrops = queuePressureDrops
        self.qpSum = qpSum
        self.targetBitrateBps = Self.finiteNonnegative(targetBitrateBps)
        self.totalEncodeTimeSeconds =
            Self.finiteNonnegative(totalEncodeTimeSeconds)
        self.totalPacketSendDelaySeconds =
            Self.finiteNonnegative(totalPacketSendDelaySeconds)
        self.qualityLimitationResolutionChanges =
            qualityLimitationResolutionChanges
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? max(0, $0) : nil }
    }
}

struct MeshRoomMediaRate: Equatable, Sendable {
    let bitsPerSecond: Int
    let framesPerSecond: Double
    let targetBitrateBps: Double?
    let averageQuantizer: Double?
    let averageEncodeTimeMilliseconds: Double?
    let averageSendDelayMilliseconds: Double?
    let droppedFrames: UInt64
    let queuePressureDrops: UInt64
    let qualityLimitationResolutionChanges: UInt64

    init(
        bitsPerSecond: Int,
        framesPerSecond: Double,
        targetBitrateBps: Double? = nil,
        averageQuantizer: Double? = nil,
        averageEncodeTimeMilliseconds: Double? = nil,
        averageSendDelayMilliseconds: Double? = nil,
        droppedFrames: UInt64 = 0,
        queuePressureDrops: UInt64 = 0,
        qualityLimitationResolutionChanges: UInt64 = 0
    ) {
        self.bitsPerSecond = max(0, bitsPerSecond)
        self.framesPerSecond =
            framesPerSecond.isFinite ? max(0, framesPerSecond) : 0
        self.targetBitrateBps = Self.finiteNonnegative(targetBitrateBps)
        self.averageQuantizer = Self.finiteNonnegative(averageQuantizer)
        self.averageEncodeTimeMilliseconds =
            Self.finiteNonnegative(averageEncodeTimeMilliseconds)
        self.averageSendDelayMilliseconds =
            Self.finiteNonnegative(averageSendDelayMilliseconds)
        self.droppedFrames = droppedFrames
        self.queuePressureDrops = queuePressureDrops
        self.qualityLimitationResolutionChanges =
            qualityLimitationResolutionChanges
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? max(0, $0) : nil }
    }
}

/// Derives per-track rates without ever blending participant pairs or media
/// directions. Missing tracks are removed on every sample, bounding retained
/// slow-peer state to the room's currently reported RTP rows.
struct MeshRoomMediaRateEstimator: Sendable {
    private var previous:
        [MeshRoomMediaCounterKey: MeshRoomMediaCounterSample] = [:]
    private(set) var rates:
        [MeshRoomMediaCounterKey: MeshRoomMediaRate] = [:]

    mutating func record(
        _ samples: [MeshRoomMediaCounterKey: MeshRoomMediaCounterSample]
    ) {
        previous = previous.filter { samples[$0.key] != nil }
        rates = rates.filter { samples[$0.key] != nil }

        for (key, sample) in samples {
            guard let prior = previous[key] else {
                previous[key] = sample
                rates[key] = MeshRoomMediaRate(
                    bitsPerSecond: 0,
                    framesPerSecond:
                        Self.validReportedFPS(sample.reportedFramesPerSecond),
                    targetBitrateBps: sample.targetBitrateBps
                )
                continue
            }
            guard sample.capturedAt > prior.capturedAt else {
                continue
            }

            defer { previous[key] = sample }
            guard sample.bytes >= prior.bytes,
                  sample.frames >= prior.frames else {
                rates[key] = nil
                continue
            }

            let elapsed = sample.capturedAt.timeIntervalSince(
                prior.capturedAt
            )
            guard elapsed > 0 else { continue }
            let derivedFPS = Double(sample.frames - prior.frames) / elapsed
            let frameDelta = sample.frames - prior.frames
            let packetDelta = Self.delta(sample.packets, prior.packets)
            let reportedFPS = Self.validReportedFPS(
                sample.reportedFramesPerSecond
            )
            rates[key] = MeshRoomMediaRate(
                bitsPerSecond: Self.rate(
                    bytes: sample.bytes - prior.bytes,
                    elapsed: elapsed
                ),
                framesPerSecond:
                    reportedFPS > 0
                        ? reportedFPS
                        : max(0, derivedFPS.isFinite ? derivedFPS : 0),
                targetBitrateBps: sample.targetBitrateBps,
                averageQuantizer: Self.averageDelta(
                    current: sample.qpSum,
                    previous: prior.qpSum,
                    count: frameDelta
                ),
                averageEncodeTimeMilliseconds: Self.averageDelta(
                    current: sample.totalEncodeTimeSeconds,
                    previous: prior.totalEncodeTimeSeconds,
                    count: frameDelta,
                    multiplier: 1_000
                ),
                averageSendDelayMilliseconds: Self.averageDelta(
                    current: sample.totalPacketSendDelaySeconds,
                    previous: prior.totalPacketSendDelaySeconds,
                    count: packetDelta,
                    multiplier: 1_000
                ),
                droppedFrames: Self.delta(
                    sample.droppedFrames,
                    prior.droppedFrames
                ),
                queuePressureDrops: Self.delta(
                    sample.queuePressureDrops,
                    prior.queuePressureDrops
                ),
                qualityLimitationResolutionChanges: Self.optionalDelta(
                    sample.qualityLimitationResolutionChanges,
                    prior.qualityLimitationResolutionChanges
                ) ?? 0
            )
        }
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    /// Optional cumulative counters must remain unknown across a missing
    /// sample. Treating absence as zero would turn the next reported lifetime
    /// value into a false one-second spike.
    private static func optionalDelta(
        _ current: UInt64?,
        _ previous: UInt64?
    ) -> UInt64? {
        guard let current, let previous, current >= previous else { return nil }
        return current - previous
    }

    private static func averageDelta(
        current: UInt64?,
        previous: UInt64?,
        count: UInt64
    ) -> Double? {
        guard count > 0,
              let current,
              let previous,
              current >= previous else { return nil }
        return Double(current - previous) / Double(count)
    }

    private static func averageDelta(
        current: Double?,
        previous: Double?,
        count: UInt64,
        multiplier: Double
    ) -> Double? {
        guard count > 0,
              let current,
              let previous,
              current.isFinite,
              previous.isFinite,
              current >= previous else { return nil }
        let average = (current - previous) / Double(count) * multiplier
        return average.isFinite ? max(0, average) : nil
    }

    private static func validReportedFPS(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func rate(
        bytes: UInt64,
        elapsed: TimeInterval
    ) -> Int {
        let value = Double(bytes) * 8 / elapsed
        guard value.isFinite, value > 0 else { return 0 }
        return Int(min(value.rounded(), Double(Int.max)))
    }
}

enum MeshRoomPhase: Equatable, Sendable {
    case connecting
    case live(elapsedSeconds: TimeInterval)
    case reconnecting
    case ending
    case ended(message: String?)
    case failed(message: String)

    var title: String {
        switch self {
        case .connecting:
            String(localized: "Connecting…")
        case let .live(elapsedSeconds):
            String(
                localized:
                    "Live · \(LiveShareDurationFormatting.string(elapsedSeconds))"
            )
        case .reconnecting:
            String(localized: "Reconnecting…")
        case .ending:
            String(localized: "Ending room…")
        case let .ended(message):
            message ?? String(localized: "Room ended")
        case let .failed(message):
            message
        }
    }

    var isConnected: Bool {
        switch self {
        case .live, .reconnecting:
            true
        case .connecting, .ending, .ended, .failed:
            false
        }
    }

    var allowsMediaChanges: Bool {
        switch self {
        case .live:
            true
        case .connecting, .reconnecting, .ending, .ended, .failed:
            false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .ended, .failed:
            true
        default:
            false
        }
    }
}

enum MeshRoomConnectionRoute: Equatable, Sendable {
    case connecting
    case connected
    case direct
    case turn
    case disconnected

    var title: String {
        switch self {
        case .connecting:
            String(localized: "Connecting")
        case .connected:
            String(localized: "Connected")
        case .direct:
            "P2P"
        case .turn:
            "TURN"
        case .disconnected:
            String(localized: "Disconnected")
        }
    }

    var isConnected: Bool {
        self == .connected || self == .direct || self == .turn
    }
}

enum MeshRoomStatusNoticeSeverity: Equatable, Sendable {
    case information
    case warning
    case error
}

enum MeshRoomIdentityPolicy {
    /// Rotating admission material must never make an established room appear
    /// to be a different room. Before activation the invite-derived name is
    /// authoritative; afterward only the invitation itself changes.
    static func roomName(
        current: String,
        inviteDerivedName: String,
        roomIsActive: Bool
    ) -> String {
        roomIsActive ? current : inviteDerivedName
    }
}

struct MeshRoomStatusNoticeSnapshot: Equatable, Sendable {
    let title: String
    let message: String
    let severity: MeshRoomStatusNoticeSeverity
}

struct MeshRoomSourceKey: Hashable, Identifiable, Sendable {
    let participantID: String
    let sourceID: String

    var id: Self { self }
}

enum MeshRoomCollaborationTool: CaseIterable, Equatable, Sendable {
    case pointer
    case ping
    case drawing
}

/// The local participant's collaboration tools for one remote source.
///
/// Pointer visibility is independent. Ping and drawing both own the primary
/// mouse gesture, so enabling either one disables the other.
struct MeshRoomCollaborationToolSelection: Equatable, Sendable {
    private(set) var pointerEnabled: Bool
    private(set) var pingEnabled: Bool
    private(set) var drawingEnabled: Bool

    init(
        pointerEnabled: Bool = false,
        pingEnabled: Bool = false,
        drawingEnabled: Bool = false
    ) {
        self.pointerEnabled = pointerEnabled
        self.drawingEnabled = drawingEnabled
        self.pingEnabled = pingEnabled && !drawingEnabled
    }

    func isEnabled(_ tool: MeshRoomCollaborationTool) -> Bool {
        switch tool {
        case .pointer:
            pointerEnabled
        case .ping:
            pingEnabled
        case .drawing:
            drawingEnabled
        }
    }

    mutating func set(
        _ tool: MeshRoomCollaborationTool,
        enabled: Bool
    ) {
        switch tool {
        case .pointer:
            pointerEnabled = enabled
        case .ping:
            pingEnabled = enabled
            if enabled { drawingEnabled = false }
        case .drawing:
            drawingEnabled = enabled
            if enabled { pingEnabled = false }
        }
    }
}

struct MeshRoomCollaborationSourcePolicy: Equatable, Sendable {
    let selection: MeshRoomCollaborationToolSelection
    let isUsingGlobalSettings: Bool
}

struct MeshRoomCollaborationPolicyChange: Equatable, Sendable {
    let pointerHiddenSources: Set<MeshRoomSourceKey>

    static let none = Self(pointerHiddenSources: [])
}

/// Pure local policy for global collaboration defaults and per-source
/// overrides. The full participant/source key is intentional: source instance
/// identifiers are scoped to their publisher and may collide across peers.
///
/// Authoritative source reconciliation is separate from peer/track readiness.
/// This preserves overrides across a hidden window or temporary WebRTC
/// recovery, while removing them as soon as the room roster says that source
/// has ended.
struct MeshRoomCollaborationPolicyReducer: Equatable, Sendable {
    private(set) var globalSelection: MeshRoomCollaborationToolSelection
    private(set) var sourceOverrides:
        [MeshRoomSourceKey: MeshRoomCollaborationToolSelection] = [:]
    private(set) var authoritativeSources: Set<MeshRoomSourceKey> = []

    init(
        globalSelection: MeshRoomCollaborationToolSelection = .init()
    ) {
        self.globalSelection = globalSelection
    }

    func policy(
        for source: MeshRoomSourceKey
    ) -> MeshRoomCollaborationSourcePolicy {
        if let override = sourceOverrides[source] {
            return .init(
                selection: override,
                isUsingGlobalSettings: false
            )
        }
        return .init(
            selection: globalSelection,
            isUsingGlobalSettings: true
        )
    }

    /// Reconciles only authoritative source membership. Visibility and media
    /// connectivity must never be passed here because neither ends a source.
    @discardableResult
    mutating func reconcileAuthoritativeSources(
        _ sources: Set<MeshRoomSourceKey>
    ) -> Set<MeshRoomSourceKey> {
        let removed = authoritativeSources.subtracting(sources)
        authoritativeSources = sources
        sourceOverrides = sourceOverrides.filter { sources.contains($0.key) }
        return removed
    }

    /// A global edit deliberately reattaches every window to the defaults,
    /// even when the selected value happens to match the current global value.
    @discardableResult
    mutating func setGlobal(
        _ tool: MeshRoomCollaborationTool,
        enabled: Bool
    ) -> MeshRoomCollaborationPolicyChange {
        let previouslyVisible = pointerVisibleSources()
        globalSelection.set(tool, enabled: enabled)
        sourceOverrides.removeAll(keepingCapacity: true)
        return change(fromPreviouslyVisible: previouslyVisible)
    }

    /// The first per-source edit snapshots all global values before changing
    /// one tool. Subsequent global changes reset this override by design.
    @discardableResult
    mutating func set(
        _ tool: MeshRoomCollaborationTool,
        enabled: Bool,
        for source: MeshRoomSourceKey
    ) -> MeshRoomCollaborationPolicyChange {
        guard authoritativeSources.contains(source) else { return .none }
        let wasVisible = policy(for: source).selection.pointerEnabled
        var selection = sourceOverrides[source] ?? globalSelection
        selection.set(tool, enabled: enabled)
        sourceOverrides[source] = selection
        let isVisible = selection.pointerEnabled
        return .init(
            pointerHiddenSources: wasVisible && !isVisible ? [source] : []
        )
    }

    @discardableResult
    mutating func useGlobalSettings(
        for source: MeshRoomSourceKey
    ) -> MeshRoomCollaborationPolicyChange {
        guard authoritativeSources.contains(source),
              let previous = sourceOverrides.removeValue(forKey: source)
        else { return .none }
        return .init(
            pointerHiddenSources:
                previous.pointerEnabled && !globalSelection.pointerEnabled
                    ? [source]
                    : []
        )
    }

    mutating func removeAllSources() {
        authoritativeSources.removeAll(keepingCapacity: false)
        sourceOverrides.removeAll(keepingCapacity: false)
    }

    private func pointerVisibleSources() -> Set<MeshRoomSourceKey> {
        Set(authoritativeSources.filter {
            policy(for: $0).selection.pointerEnabled
        })
    }

    private func change(
        fromPreviouslyVisible previouslyVisible: Set<MeshRoomSourceKey>
    ) -> MeshRoomCollaborationPolicyChange {
        .init(
            pointerHiddenSources:
                previouslyVisible.subtracting(pointerVisibleSources())
        )
    }
}

struct MeshRoomLocalParticipantSnapshot: Equatable, Sendable {
    let id: String
    let displayName: String
    let deviceName: String?
    let clientKind: ClipLiveShareServerRoomV4ClientKind

    init(
        id: String,
        displayName: String,
        deviceName: String? = nil,
        clientKind: ClipLiveShareServerRoomV4ClientKind = .nativeApp
    ) {
        self.id = id
        self.displayName = displayName
        self.deviceName = deviceName
        self.clientKind = clientKind
    }
}

extension ClipLiveShareServerRoomV4ClientKind {
    var participantKindTitle: String {
        switch self {
        case .nativeApp:
            String(localized: "Native")
        case .webViewer:
            String(localized: "Web")
        }
    }

    var supportsFriendship: Bool { self == .nativeApp }
}

struct MeshRoomInviteSnapshot: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let url: URL
    let roomCode: String
    let isAvailable: Bool

    init(
        url: URL,
        roomCode: String,
        isAvailable: Bool = true
    ) {
        self.url = url
        self.roomCode = roomCode
        self.isAvailable = isAvailable
    }

    var description: String {
        "MeshRoomInviteSnapshot(roomCode: \(roomCode), url: <redacted invite>, "
            + "isAvailable: \(isAvailable))"
    }

    var debugDescription: String { description }

    /// This code identifies the reusable invitation, not the room itself.
    /// Keeping the distinction explicit in the presentation model prevents a
    /// rotated invitation from being mistaken for a renamed room (and vice
    /// versa).
    var codeLabel: String {
        String(localized: "Invite Code")
    }

    var reuseDetail: String {
        String(localized: "Reusable until you change it.")
    }
}

struct MeshRoomPendingAdmissionSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let deviceName: String?
}

struct MeshRoomLocalSourceSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let applicationName: String
    let windowTitle: String
    let status: LiveShareSourceViewStatus
    let isFocused: Bool
    let canStop: Bool

    init(
        id: String,
        applicationName: String,
        windowTitle: String,
        status: LiveShareSourceViewStatus,
        isFocused: Bool = false,
        canStop: Bool = true
    ) {
        self.id = id
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.status = status
        self.isFocused = isFocused
        self.canStop = canStop
    }

    var title: String {
        if !windowTitle.isEmpty { return windowTitle }
        if !applicationName.isEmpty { return applicationName }
        return String(localized: "Shared Window")
    }

    var detail: String {
        guard !applicationName.isEmpty, applicationName != title else {
            return status.title
        }
        return "\(applicationName) · \(status.title)"
    }
}

struct MeshRoomRemoteSourceSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let applicationName: String
    let windowTitle: String
    let pixelWidth: Int
    let pixelHeight: Int
    let isVisible: Bool
    let isFocused: Bool
    let isConnected: Bool
    let scaleMode: NativeViewerScaleMode
    let isFullScreen: Bool

    init(
        id: String,
        applicationName: String,
        windowTitle: String,
        pixelWidth: Int,
        pixelHeight: Int,
        isVisible: Bool,
        isFocused: Bool,
        isConnected: Bool,
        scaleMode: NativeViewerScaleMode = .follow,
        isFullScreen: Bool = false
    ) {
        self.id = id
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.pixelWidth = max(0, pixelWidth)
        self.pixelHeight = max(0, pixelHeight)
        self.isVisible = isVisible
        self.isFocused = isFocused
        self.isConnected = isConnected
        self.scaleMode = scaleMode
        self.isFullScreen = isFullScreen
    }

    var title: String {
        if !windowTitle.isEmpty { return windowTitle }
        if !applicationName.isEmpty { return applicationName }
        return String(localized: "Shared Window")
    }

    var detail: String {
        var values: [String] = []
        if !applicationName.isEmpty, applicationName != title {
            values.append(applicationName)
        }
        if pixelWidth > 0, pixelHeight > 0 {
            values.append("\(pixelWidth) × \(pixelHeight)")
        }
        if !isConnected {
            values.append(String(localized: "Disconnected"))
        }
        return values.joined(separator: " · ")
    }
}

/// One local source's delivery state on one exact peer edge. Keeping these
/// details underneath the source-level publishing summary makes a stalled or
/// bandwidth-limited recipient visible without duplicating the source row.
struct MeshRoomMediaRecipientDiagnosticsSnapshot:
    Equatable, Identifiable, Sendable
{
    var id: String { recipientID }

    let recipientID: String
    let recipientName: String
    let codec: String?
    let width: Int
    let height: Int
    let framesPerSecond: Double
    let bitsPerSecond: Int
    let bytesSent: UInt64
    let targetBitrateBps: Double?
    let averageQuantizer: Double?
    let recentEncodeTimeMilliseconds: Double?
    let recentSendDelayMilliseconds: Double?
    let recentDroppedFrames: UInt64
    let recentQueuePressureDrops: UInt64
    let queuePressureReason: String?
    let qualityLimitationResolutionChanges: UInt64
    let packetsLost: Int64

    init(
        recipientID: String,
        recipientName: String,
        codec: String? = nil,
        width: Int = 0,
        height: Int = 0,
        framesPerSecond: Double = 0,
        bitsPerSecond: Int = 0,
        bytesSent: UInt64 = 0,
        targetBitrateBps: Double? = nil,
        averageQuantizer: Double? = nil,
        recentEncodeTimeMilliseconds: Double? = nil,
        recentSendDelayMilliseconds: Double? = nil,
        recentDroppedFrames: UInt64 = 0,
        recentQueuePressureDrops: UInt64 = 0,
        queuePressureReason: String? = nil,
        qualityLimitationResolutionChanges: UInt64 = 0,
        packetsLost: Int64 = 0
    ) {
        self.recipientID = recipientID
        self.recipientName = recipientName
        self.codec = codec
        self.width = max(0, width)
        self.height = max(0, height)
        self.framesPerSecond = Self.finiteNonnegative(framesPerSecond)
        self.bitsPerSecond = max(0, bitsPerSecond)
        self.bytesSent = bytesSent
        self.targetBitrateBps = Self.finiteNonnegative(targetBitrateBps)
        self.averageQuantizer = Self.finiteNonnegative(averageQuantizer)
        self.recentEncodeTimeMilliseconds =
            Self.finiteNonnegative(recentEncodeTimeMilliseconds)
        self.recentSendDelayMilliseconds =
            Self.finiteNonnegative(recentSendDelayMilliseconds)
        self.recentDroppedFrames = recentDroppedFrames
        self.recentQueuePressureDrops = recentQueuePressureDrops
        self.queuePressureReason = queuePressureReason
        self.qualityLimitationResolutionChanges =
            qualityLimitationResolutionChanges
        self.packetsLost = max(0, packetsLost)
    }

    private static func finiteNonnegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? max(0, $0) : nil }
    }
}

struct MeshRoomMediaDiagnosticsSnapshot: Equatable, Identifiable, Sendable {
    enum Direction: Equatable, Hashable, Sendable {
        case outgoing
        case incoming
    }

    let id: String
    /// Exact source-instance identity shared by every per-peer sender for one
    /// locally published source. RTP track identifiers are reusable transport
    /// slots, so `id` identifies a displayed diagnostics row while this value
    /// is the key used to collapse those peer-specific rows into a publishing
    /// summary without merging a replacement source into its predecessor.
    let sourceIdentifier: String
    let sourceName: String
    let direction: Direction
    let recipientID: String?
    let recipientName: String?
    let codec: String?
    let width: Int
    let height: Int
    let framesPerSecond: Double
    let bitsPerSecond: Int
    let droppedFrames: UInt64
    let queuePressureDrops: UInt64
    let queuePressureReason: String?
    let packetsLost: Int64
    let processingLatencyMilliseconds: Double?
    let targetBitrateBps: Double?
    let averageQuantizer: Double?
    let recentEncodeTimeMilliseconds: Double?
    let recentSendDelayMilliseconds: Double?
    let recentDroppedFrames: UInt64
    let recentQueuePressureDrops: UInt64
    let qualityLimitationResolutionChanges: UInt64
    let sourcePointWidth: Int?
    let sourcePointHeight: Int?
    let sourcePixelWidth: Int?
    let sourcePixelHeight: Int?
    let captureWidth: Int?
    let captureHeight: Int?
    let capturePixelFormat: String?
    let manifestWidth: Int?
    let manifestHeight: Int?
    let configuredMinimumBitratePerRecipientBps: Int?
    let configuredMaximumBitratePerRecipientBps: Int?
    let bytesSent: UInt64
    let captureDeliveredFrames: UInt64
    let captureBackpressureDrops: UInt64
    let qualityLimitationReasons: [String]
    let recipientEdges: [MeshRoomMediaRecipientDiagnosticsSnapshot]

    init(
        id: String,
        sourceIdentifier: String? = nil,
        sourceName: String,
        direction: Direction,
        recipientID: String? = nil,
        recipientName: String? = nil,
        codec: String? = nil,
        width: Int = 0,
        height: Int = 0,
        framesPerSecond: Double = 0,
        bitsPerSecond: Int = 0,
        droppedFrames: UInt64 = 0,
        queuePressureDrops: UInt64 = 0,
        queuePressureReason: String? = nil,
        packetsLost: Int64 = 0,
        processingLatencyMilliseconds: Double? = nil,
        targetBitrateBps: Double? = nil,
        averageQuantizer: Double? = nil,
        recentEncodeTimeMilliseconds: Double? = nil,
        recentSendDelayMilliseconds: Double? = nil,
        recentDroppedFrames: UInt64 = 0,
        recentQueuePressureDrops: UInt64 = 0,
        qualityLimitationResolutionChanges: UInt64 = 0,
        sourcePointWidth: Int? = nil,
        sourcePointHeight: Int? = nil,
        sourcePixelWidth: Int? = nil,
        sourcePixelHeight: Int? = nil,
        captureWidth: Int? = nil,
        captureHeight: Int? = nil,
        capturePixelFormat: String? = nil,
        manifestWidth: Int? = nil,
        manifestHeight: Int? = nil,
        configuredMinimumBitratePerRecipientBps: Int? = nil,
        configuredMaximumBitratePerRecipientBps: Int? = nil,
        bytesSent: UInt64 = 0,
        captureDeliveredFrames: UInt64 = 0,
        captureBackpressureDrops: UInt64 = 0,
        qualityLimitationReasons: [String] = [],
        recipientEdges: [MeshRoomMediaRecipientDiagnosticsSnapshot] = []
    ) {
        self.id = id
        self.sourceIdentifier = sourceIdentifier ?? id
        self.sourceName = sourceName
        self.direction = direction
        self.recipientID = recipientID
        self.recipientName = recipientName
        self.codec = codec
        self.width = max(0, width)
        self.height = max(0, height)
        self.framesPerSecond = max(0, framesPerSecond)
        self.bitsPerSecond = max(0, bitsPerSecond)
        self.droppedFrames = droppedFrames
        self.queuePressureDrops = queuePressureDrops
        self.queuePressureReason = queuePressureReason
        self.packetsLost = max(0, packetsLost)
        self.processingLatencyMilliseconds =
            processingLatencyMilliseconds.map { max(0, $0) }
        self.targetBitrateBps = Self.finiteNonnegative(targetBitrateBps)
        self.averageQuantizer = Self.finiteNonnegative(averageQuantizer)
        self.recentEncodeTimeMilliseconds =
            Self.finiteNonnegative(recentEncodeTimeMilliseconds)
        self.recentSendDelayMilliseconds =
            Self.finiteNonnegative(recentSendDelayMilliseconds)
        self.recentDroppedFrames = recentDroppedFrames
        self.recentQueuePressureDrops = recentQueuePressureDrops
        self.qualityLimitationResolutionChanges =
            qualityLimitationResolutionChanges
        self.sourcePointWidth = sourcePointWidth.map { max(0, $0) }
        self.sourcePointHeight = sourcePointHeight.map { max(0, $0) }
        self.sourcePixelWidth = sourcePixelWidth.map { max(0, $0) }
        self.sourcePixelHeight = sourcePixelHeight.map { max(0, $0) }
        self.captureWidth = captureWidth.map { max(0, $0) }
        self.captureHeight = captureHeight.map { max(0, $0) }
        self.capturePixelFormat = capturePixelFormat
        self.manifestWidth = manifestWidth.map { max(0, $0) }
        self.manifestHeight = manifestHeight.map { max(0, $0) }
        self.configuredMinimumBitratePerRecipientBps =
            configuredMinimumBitratePerRecipientBps.map { max(0, $0) }
        self.configuredMaximumBitratePerRecipientBps =
            configuredMaximumBitratePerRecipientBps.map { max(0, $0) }
        self.bytesSent = bytesSent
        self.captureDeliveredFrames = captureDeliveredFrames
        self.captureBackpressureDrops = captureBackpressureDrops
        self.qualityLimitationReasons = qualityLimitationReasons
        self.recipientEdges = recipientEdges
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? max(0, $0) : nil }
    }

    /// Presents local publication as sources rather than raw WebRTC senders.
    ///
    /// One source has a sender on every direct peer link, and WebRTC may keep
    /// a superseded sender row in its statistics report briefly after track
    /// replacement. Active source-instance identities remove those stale rows.
    /// Remaining rows are summarized with total upload/loss plus the weakest
    /// current delivery dimensions, cadence, drops and latency. Exact peer
    /// RTT/loss remains in `MeshRoomPeerDiagnosticsSnapshot` and Connections.
    static func publishingSources(
        from diagnostics: [Self],
        activeSourceIdentifiers: Set<String>
    ) -> [Self] {
        let activeOutgoing = diagnostics.filter {
            $0.direction == .outgoing
                && activeSourceIdentifiers.contains($0.sourceIdentifier)
        }
        return Dictionary(
            grouping: activeOutgoing,
            by: \.sourceIdentifier
        )
        .map { sourceIdentifier, rows in
            let ordered = rows.sorted { $0.id < $1.id }
            let canonical = ordered[0]
            let recipientEdges = ordered.map { row in
                MeshRoomMediaRecipientDiagnosticsSnapshot(
                    recipientID: row.recipientID ?? row.id,
                    recipientName:
                        row.recipientName
                            ?? row.recipientID
                            ?? row.id,
                    codec: row.codec,
                    width: row.width,
                    height: row.height,
                    framesPerSecond: row.framesPerSecond,
                    bitsPerSecond: row.bitsPerSecond,
                    bytesSent: row.bytesSent,
                    targetBitrateBps: row.targetBitrateBps,
                    averageQuantizer: row.averageQuantizer,
                    recentEncodeTimeMilliseconds:
                        row.recentEncodeTimeMilliseconds,
                    recentSendDelayMilliseconds:
                        row.recentSendDelayMilliseconds,
                    recentDroppedFrames: row.recentDroppedFrames,
                    recentQueuePressureDrops:
                        row.recentQueuePressureDrops,
                    queuePressureReason: row.queuePressureReason,
                    qualityLimitationResolutionChanges:
                        row.qualityLimitationResolutionChanges,
                    packetsLost: row.packetsLost
                )
            }
            .sorted { lhs, rhs in
                let nameOrder = lhs.recipientName.localizedStandardCompare(
                    rhs.recipientName
                )
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.recipientID < rhs.recipientID
            }
            let weakestResolution = ordered
                .filter { $0.width > 0 && $0.height > 0 }
                .min {
                    let lhsProduct = $0.width
                        .multipliedReportingOverflow(by: $0.height)
                    let rhsProduct = $1.width
                        .multipliedReportingOverflow(by: $1.height)
                    let lhsPixels = lhsProduct.overflow
                        ? Int.max
                        : lhsProduct.partialValue
                    let rhsPixels = rhsProduct.overflow
                        ? Int.max
                        : rhsProduct.partialValue
                    if lhsPixels != rhsPixels {
                        return lhsPixels < rhsPixels
                    }
                    if $0.width != $1.width {
                        return $0.width < $1.width
                    }
                    return $0.height < $1.height
                }
            let frameRates = ordered.map(\.framesPerSecond)
            let codecs = Set(ordered.compactMap(\.codec))
            let pressure = ordered.max {
                if $0.queuePressureDrops
                    != $1.queuePressureDrops {
                    return $0.queuePressureDrops
                        < $1.queuePressureDrops
                }
                return ($0.queuePressureReason ?? "")
                    < ($1.queuePressureReason ?? "")
            }
            return Self(
                id: "outgoing-\(sourceIdentifier)",
                sourceIdentifier: sourceIdentifier,
                sourceName: canonical.sourceName,
                direction: .outgoing,
                codec: codecs.count == 1
                    ? codecs.first
                    : codecs.isEmpty
                        ? nil
                        : String(localized: "Mixed"),
                width: weakestResolution?.width ?? 0,
                height: weakestResolution?.height ?? 0,
                // Every row has already been resolved to the active source.
                // Zero therefore means an active peer is currently stalled,
                // not that the row is an unrelated empty sender slot.
                framesPerSecond: frameRates.min() ?? 0,
                bitsPerSecond: saturatingSum(
                    ordered.map(\.bitsPerSecond)
                ),
                droppedFrames:
                    ordered.map(\.droppedFrames).max() ?? 0,
                queuePressureDrops:
                    ordered.map(\.queuePressureDrops).max() ?? 0,
                queuePressureReason: pressure?.queuePressureReason,
                packetsLost: saturatingSum(
                    ordered.map(\.packetsLost)
                ),
                processingLatencyMilliseconds: ordered
                    .compactMap(\.processingLatencyMilliseconds)
                    .max(),
                targetBitrateBps: sumOptional(
                    ordered.map(\.targetBitrateBps)
                ),
                averageQuantizer: ordered
                    .compactMap(\.averageQuantizer)
                    .max(),
                recentEncodeTimeMilliseconds: ordered
                    .compactMap(\.recentEncodeTimeMilliseconds)
                    .max(),
                recentSendDelayMilliseconds: ordered
                    .compactMap(\.recentSendDelayMilliseconds)
                    .max(),
                recentDroppedFrames:
                    ordered.map(\.recentDroppedFrames).max() ?? 0,
                recentQueuePressureDrops:
                    ordered.map(\.recentQueuePressureDrops).max() ?? 0,
                qualityLimitationResolutionChanges:
                    ordered.map(\.qualityLimitationResolutionChanges)
                        .max() ?? 0,
                sourcePointWidth: canonical.sourcePointWidth,
                sourcePointHeight: canonical.sourcePointHeight,
                sourcePixelWidth: canonical.sourcePixelWidth,
                sourcePixelHeight: canonical.sourcePixelHeight,
                captureWidth: canonical.captureWidth,
                captureHeight: canonical.captureHeight,
                capturePixelFormat: canonical.capturePixelFormat,
                manifestWidth: canonical.manifestWidth,
                manifestHeight: canonical.manifestHeight,
                configuredMinimumBitratePerRecipientBps:
                    canonical.configuredMinimumBitratePerRecipientBps,
                configuredMaximumBitratePerRecipientBps:
                    canonical.configuredMaximumBitratePerRecipientBps,
                bytesSent: saturatingSum(ordered.map(\.bytesSent)),
                captureDeliveredFrames: canonical.captureDeliveredFrames,
                captureBackpressureDrops:
                    canonical.captureBackpressureDrops,
                qualityLimitationReasons: Array(
                    Set(ordered.flatMap { row in
                        row.qualityLimitationReasons
                            + [row.queuePressureReason].compactMap { $0 }
                    })
                ).sorted(),
                recipientEdges: recipientEdges
            )
        }
        .sorted { lhs, rhs in
            if lhs.sourceName != rhs.sourceName {
                return lhs.sourceName.localizedStandardCompare(
                    rhs.sourceName
                ) == .orderedAscending
            }
            return lhs.sourceIdentifier < rhs.sourceIdentifier
        }
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(into: 0) { result, value in
            let (sum, overflow) = result.addingReportingOverflow(value)
            result = overflow ? Int.max : sum
        }
    }

    private static func saturatingSum(_ values: [Int64]) -> Int64 {
        values.reduce(into: 0) { result, value in
            let (sum, overflow) = result.addingReportingOverflow(value)
            result = overflow ? Int64.max : sum
        }
    }

    private static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(into: 0) { result, value in
            let (sum, overflow) = result.addingReportingOverflow(value)
            result = overflow ? UInt64.max : sum
        }
    }

    private static func sumOptional(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }
        // An aggregate target is meaningful only when every recipient edge
        // reports one. Summing the known subset would present partial data as
        // the complete source target.
        guard !present.isEmpty, present.count == values.count else { return nil }
        let result = present.reduce(0, +)
        return result.isFinite ? max(0, result) : Double.greatestFiniteMagnitude
    }
}

struct MeshRoomPeerDiagnosticsSnapshot: Equatable, Identifiable, Sendable {
    let participantID: String
    let displayName: String
    let route: MeshRoomConnectionRoute
    let roundTripMilliseconds: Double?
    let availableOutgoingBitrateBps: Double?
    let bytesSent: UInt64
    let bytesReceived: UInt64
    let packetsLost: Int64

    init(
        participantID: String,
        displayName: String,
        route: MeshRoomConnectionRoute,
        roundTripMilliseconds: Double? = nil,
        availableOutgoingBitrateBps: Double? = nil,
        bytesSent: UInt64 = 0,
        bytesReceived: UInt64 = 0,
        packetsLost: Int64 = 0
    ) {
        self.participantID = participantID
        self.displayName = displayName
        self.route = route
        self.roundTripMilliseconds = roundTripMilliseconds.map { max(0, $0) }
        self.availableOutgoingBitrateBps = availableOutgoingBitrateBps
            .flatMap { $0.isFinite ? max(0, $0) : nil }
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.packetsLost = max(0, packetsLost)
    }

    var id: String { participantID }
}

struct MeshRoomCollaborationSnapshot: Equatable, Sendable {
    let isLocalPointerVisible: Bool
    let isLocalPingModeEnabled: Bool
    let isLocalInkEnabled: Bool
    let activePointerCount: Int
    let annotationStrokeCount: Int
    let canClearAnnotations: Bool

    init(
        isLocalPointerVisible: Bool = false,
        isLocalPingModeEnabled: Bool = false,
        isLocalInkEnabled: Bool = false,
        activePointerCount: Int = 0,
        annotationStrokeCount: Int = 0,
        canClearAnnotations: Bool = false
    ) {
        self.isLocalPointerVisible = isLocalPointerVisible
        self.isLocalPingModeEnabled = isLocalPingModeEnabled
        self.isLocalInkEnabled = isLocalInkEnabled
        self.activePointerCount = max(0, activePointerCount)
        self.annotationStrokeCount = max(0, annotationStrokeCount)
        self.canClearAnnotations = canClearAnnotations
    }

    var summary: String {
        var active: [String] = []
        if activePointerCount > 0 {
            active.append(
                String(localized: "\(activePointerCount) pointers")
            )
        }
        if annotationStrokeCount > 0 {
            active.append(
                String(localized: "\(annotationStrokeCount) strokes")
            )
        }
        return active.isEmpty
            ? String(localized: "Pointers and drawing")
            : active.joined(separator: " · ")
    }
}

struct MeshRoomRemoteParticipantSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let deviceName: String?
    let clientKind: ClipLiveShareServerRoomV4ClientKind
    let route: MeshRoomConnectionRoute
    let connectedDuration: TimeInterval?
    let sources: [MeshRoomRemoteSourceSnapshot]
    let systemAudioAvailable: Bool
    let systemAudioEnabled: Bool
    let volume: Double
    let diagnostics: [MeshRoomMediaDiagnosticsSnapshot]
    let friendshipState: MeshRoomFriendshipState

    init(
        id: String,
        displayName: String,
        deviceName: String? = nil,
        clientKind: ClipLiveShareServerRoomV4ClientKind = .nativeApp,
        route: MeshRoomConnectionRoute,
        connectedDuration: TimeInterval? = nil,
        sources: [MeshRoomRemoteSourceSnapshot] = [],
        systemAudioAvailable: Bool = false,
        systemAudioEnabled: Bool = true,
        volume: Double = 1,
        diagnostics: [MeshRoomMediaDiagnosticsSnapshot] = [],
        friendshipState: MeshRoomFriendshipState = .available
    ) {
        self.id = id
        self.displayName = displayName
        self.deviceName = deviceName
        self.clientKind = clientKind
        self.route = route
        self.connectedDuration = connectedDuration.map { max(0, $0) }
        self.sources = sources
        self.systemAudioAvailable = systemAudioAvailable
        self.systemAudioEnabled = systemAudioEnabled
        self.volume = min(max(volume, 0), 1)
        self.diagnostics = diagnostics.filter { $0.direction == .incoming }
        self.friendshipState = friendshipState
    }

    var visibleSourceCount: Int {
        sources.count(where: \.isVisible)
    }
}

struct MeshRoomViewSnapshot: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let phase: MeshRoomPhase
    let roomName: String
    let localParticipant: MeshRoomLocalParticipantSnapshot
    /// Immutable participant that created and owns the room. The clean-slate
    /// server-coordinated mesh never transfers this role; creator departure
    /// ends the room for every member.
    let creatorParticipantID: String?
    let invite: MeshRoomInviteSnapshot?
    let accessWordEnabled: Bool
    let accessWord: String?
    let canChangeAccessWord: Bool
    let askBeforeJoining: Bool
    let canChangeAskBeforeJoining: Bool
    let pendingAdmissions: [MeshRoomPendingAdmissionSnapshot]
    let pendingFriendRequests: [MeshRoomPendingFriendRequestSnapshot]
    let localSources: [MeshRoomLocalSourceSnapshot]
    let fullscreen: LiveShareFullscreenViewSnapshot
    let canShareFocusedWindow: Bool
    let focusedWindowDescription: String?
    let availableWindows: [LiveShareAvailableWindowViewSnapshot]
    let canAddWindow: Bool
    let settings: LiveShareSettingsViewSnapshot
    let remoteParticipants: [MeshRoomRemoteParticipantSnapshot]
    let outgoingDiagnostics: [MeshRoomMediaDiagnosticsSnapshot]
    let peerDiagnostics: [MeshRoomPeerDiagnosticsSnapshot]
    let collaboration: MeshRoomCollaborationSnapshot
    let statusNotice: MeshRoomStatusNoticeSnapshot?
    let canLeaveRoom: Bool
    let canEndRoom: Bool

    init(
        phase: MeshRoomPhase,
        roomName: String,
        localParticipant: MeshRoomLocalParticipantSnapshot,
        creatorParticipantID: String?,
        invite: MeshRoomInviteSnapshot? = nil,
        accessWordEnabled: Bool = false,
        accessWord: String? = nil,
        canChangeAccessWord: Bool = true,
        askBeforeJoining: Bool = false,
        canChangeAskBeforeJoining: Bool = true,
        pendingAdmissions: [MeshRoomPendingAdmissionSnapshot] = [],
        pendingFriendRequests: [MeshRoomPendingFriendRequestSnapshot] = [],
        localSources: [MeshRoomLocalSourceSnapshot] = [],
        fullscreen: LiveShareFullscreenViewSnapshot = .init(
            isOn: false,
            displayName: String(localized: "Main Display")
        ),
        canShareFocusedWindow: Bool = false,
        focusedWindowDescription: String? = nil,
        availableWindows: [LiveShareAvailableWindowViewSnapshot] = [],
        canAddWindow: Bool = false,
        settings: LiveShareSettingsViewSnapshot = .init(),
        remoteParticipants: [MeshRoomRemoteParticipantSnapshot] = [],
        outgoingDiagnostics: [MeshRoomMediaDiagnosticsSnapshot] = [],
        peerDiagnostics: [MeshRoomPeerDiagnosticsSnapshot] = [],
        collaboration: MeshRoomCollaborationSnapshot = .init(),
        statusNotice: MeshRoomStatusNoticeSnapshot? = nil,
        canLeaveRoom: Bool = true,
        canEndRoom: Bool = true
    ) {
        self.phase = phase
        let trimmedRoomName = roomName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.roomName = trimmedRoomName.isEmpty
            ? String(localized: "Live Share")
            : trimmedRoomName
        self.localParticipant = localParticipant
        self.creatorParticipantID = creatorParticipantID
        self.invite = invite
        self.accessWordEnabled = accessWordEnabled
        self.accessWord = accessWord
        self.canChangeAccessWord = canChangeAccessWord
        self.askBeforeJoining = askBeforeJoining
        self.canChangeAskBeforeJoining = canChangeAskBeforeJoining
        self.pendingAdmissions = Self.unique(
            pendingAdmissions,
            excluding: localParticipant.id,
            id: \.id
        )
        self.pendingFriendRequests = Self.unique(
            pendingFriendRequests,
            excluding: localParticipant.id,
            id: \.id
        )
        self.localSources = Self.unique(localSources, id: \.id)
        self.fullscreen = fullscreen
        self.canShareFocusedWindow = canShareFocusedWindow
        self.focusedWindowDescription = focusedWindowDescription
        self.availableWindows = Self.unique(availableWindows, id: \.id)
        self.canAddWindow = canAddWindow
        self.settings = settings
        self.remoteParticipants = Self.unique(
            remoteParticipants,
            excluding: localParticipant.id,
            id: \.id
        )
        self.outgoingDiagnostics = outgoingDiagnostics.filter {
            $0.direction == .outgoing
        }
        self.peerDiagnostics = Self.unique(
            peerDiagnostics,
            excluding: localParticipant.id,
            id: \.participantID
        )
        self.collaboration = collaboration
        self.statusNotice = statusNotice
        self.canLeaveRoom = canLeaveRoom
        self.canEndRoom = canEndRoom
    }

    var isLocalCreator: Bool {
        creatorParticipantID == localParticipant.id
    }

    var participantCount: Int {
        1 + remoteParticipants.count
    }

    var remoteSharedSourceCount: Int {
        remoteParticipants.reduce(0) { count, participant in
            count + participant.sources.count
        }
    }

    var sharingRemoteParticipantCount: Int {
        remoteParticipants.count { !$0.sources.isEmpty }
    }

    var connectedParticipantCount: Int {
        1 + remoteParticipants.count(where: { $0.route.isConnected })
    }

    /// Web viewers are receive-only, so they can never contribute an incoming
    /// media stream to native participants. Keep them in connection
    /// diagnostics, but omit the otherwise-empty per-publisher media section.
    var diagnosticRemoteParticipants: [MeshRoomRemoteParticipantSnapshot] {
        remoteParticipants.filter { $0.clientKind == .nativeApp }
    }

    var creatorDisplayName: String? {
        guard let creatorParticipantID else { return nil }
        if creatorParticipantID == localParticipant.id {
            return localParticipant.displayName
        }
        return remoteParticipants.first {
            $0.id == creatorParticipantID
        }?.displayName
    }

    var hasLocalMedia: Bool {
        fullscreen.isOn || !localSources.isEmpty
    }

    var description: String {
        "MeshRoomViewSnapshot(phase: \(phase.title), room: \(roomName), "
            + "participants: \(participantCount), invite: <redacted>, "
            + "Access Word: <redacted>)"
    }

    var debugDescription: String { description }

    private static func unique<Element>(
        _ values: [Element],
        excluding excludedID: String? = nil,
        id: KeyPath<Element, String>
    ) -> [Element] {
        var seen = Set<String>()
        return values.filter { value in
            let valueID = value[keyPath: id]
            guard valueID != excludedID else { return false }
            return seen.insert(valueID).inserted
        }
    }
}
