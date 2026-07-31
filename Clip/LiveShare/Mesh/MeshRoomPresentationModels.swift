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
    let direction: MeshRoomMediaDiagnosticsSnapshot.Direction
}

struct MeshRoomMediaCounterSample: Equatable, Sendable {
    let capturedAt: Date
    let bytes: UInt64
    let frames: UInt64
    let reportedFramesPerSecond: Double
}

struct MeshRoomMediaRate: Equatable, Sendable {
    let bitsPerSecond: Int
    let framesPerSecond: Double
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
                        Self.validReportedFPS(sample.reportedFramesPerSecond)
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
                        : max(0, derivedFPS.isFinite ? derivedFPS : 0)
            )
        }
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
    case electingCreator
    case leaderlessLocked
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
        case .electingCreator:
            String(localized: "Choosing a new room creator…")
        case .leaderlessLocked:
            String(localized: "Connected · Room membership locked")
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
        case .live, .reconnecting, .electingCreator, .leaderlessLocked:
            true
        case .connecting, .ending, .ended, .failed:
            false
        }
    }

    var allowsMediaChanges: Bool {
        switch self {
        case .live, .reconnecting, .electingCreator, .leaderlessLocked:
            true
        case .connecting, .ending, .ended, .failed:
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
    case direct
    case turn
    case disconnected

    var title: String {
        switch self {
        case .connecting:
            String(localized: "Connecting")
        case .direct:
            "P2P"
        case .turn:
            "TURN"
        case .disconnected:
            String(localized: "Disconnected")
        }
    }

    var isConnected: Bool {
        self == .direct || self == .turn
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

struct MeshRoomLocalParticipantSnapshot: Equatable, Sendable {
    let id: String
    let displayName: String
    let deviceName: String?

    init(
        id: String,
        displayName: String,
        deviceName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.deviceName = deviceName
    }
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

struct MeshRoomMediaDiagnosticsSnapshot: Equatable, Identifiable, Sendable {
    enum Direction: Equatable, Hashable, Sendable {
        case outgoing
        case incoming
    }

    let id: String
    let sourceName: String
    let direction: Direction
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

    init(
        id: String,
        sourceName: String,
        direction: Direction,
        codec: String? = nil,
        width: Int = 0,
        height: Int = 0,
        framesPerSecond: Double = 0,
        bitsPerSecond: Int = 0,
        droppedFrames: UInt64 = 0,
        queuePressureDrops: UInt64 = 0,
        queuePressureReason: String? = nil,
        packetsLost: Int64 = 0,
        processingLatencyMilliseconds: Double? = nil
    ) {
        self.id = id
        self.sourceName = sourceName
        self.direction = direction
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
    }
}

struct MeshRoomPeerDiagnosticsSnapshot: Equatable, Identifiable, Sendable {
    let participantID: String
    let displayName: String
    let route: MeshRoomConnectionRoute
    let roundTripMilliseconds: Double?
    let packetsLost: Int64

    init(
        participantID: String,
        displayName: String,
        route: MeshRoomConnectionRoute,
        roundTripMilliseconds: Double? = nil,
        packetsLost: Int64 = 0
    ) {
        self.participantID = participantID
        self.displayName = displayName
        self.route = route
        self.roundTripMilliseconds = roundTripMilliseconds.map { max(0, $0) }
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
    let route: MeshRoomConnectionRoute
    let connectedDuration: TimeInterval?
    let sources: [MeshRoomRemoteSourceSnapshot]
    let systemAudioAvailable: Bool
    let systemAudioEnabled: Bool
    let volume: Double
    let diagnostics: [MeshRoomMediaDiagnosticsSnapshot]

    init(
        id: String,
        displayName: String,
        deviceName: String? = nil,
        route: MeshRoomConnectionRoute,
        connectedDuration: TimeInterval? = nil,
        sources: [MeshRoomRemoteSourceSnapshot] = [],
        systemAudioAvailable: Bool = false,
        systemAudioEnabled: Bool = true,
        volume: Double = 1,
        diagnostics: [MeshRoomMediaDiagnosticsSnapshot] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.deviceName = deviceName
        self.route = route
        self.connectedDuration = connectedDuration.map { max(0, $0) }
        self.sources = sources
        self.systemAudioAvailable = systemAudioAvailable
        self.systemAudioEnabled = systemAudioEnabled
        self.volume = min(max(volume, 0), 1)
        self.diagnostics = diagnostics.filter { $0.direction == .incoming }
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
    /// Immutable provenance for the participant that created the room.
    ///
    /// This must not change when authority is transferred after a graceful
    /// departure or quorum-certified recovery election.
    let foundingCreatorParticipantID: String?
    /// The participant that currently owns admission and membership authority.
    let currentLeaderParticipantID: String?
    let invite: MeshRoomInviteSnapshot?
    let accessWordEnabled: Bool
    let accessWord: String?
    let canChangeAccessWord: Bool
    let pendingAdmissions: [MeshRoomPendingAdmissionSnapshot]
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
        foundingCreatorParticipantID: String? = nil,
        currentLeaderParticipantID: String?,
        invite: MeshRoomInviteSnapshot? = nil,
        accessWordEnabled: Bool = false,
        accessWord: String? = nil,
        canChangeAccessWord: Bool = true,
        pendingAdmissions: [MeshRoomPendingAdmissionSnapshot] = [],
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
        self.foundingCreatorParticipantID = foundingCreatorParticipantID
        self.currentLeaderParticipantID = currentLeaderParticipantID
        self.invite = invite
        self.accessWordEnabled = accessWordEnabled
        self.accessWord = accessWord
        self.canChangeAccessWord = canChangeAccessWord
        self.pendingAdmissions = Self.unique(
            pendingAdmissions,
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

    var isLocalLeader: Bool {
        currentLeaderParticipantID == localParticipant.id
    }

    var participantCount: Int {
        1 + remoteParticipants.count
    }

    var connectedParticipantCount: Int {
        1 + remoteParticipants.count(where: { $0.route.isConnected })
    }

    var currentLeaderDisplayName: String? {
        guard let currentLeaderParticipantID else { return nil }
        if currentLeaderParticipantID == localParticipant.id {
            return localParticipant.displayName
        }
        return remoteParticipants.first {
            $0.id == currentLeaderParticipantID
        }?.displayName
    }

    var foundingCreatorDisplayName: String? {
        guard let foundingCreatorParticipantID else { return nil }
        if foundingCreatorParticipantID == localParticipant.id {
            return localParticipant.displayName
        }
        return remoteParticipants.first {
            $0.id == foundingCreatorParticipantID
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
