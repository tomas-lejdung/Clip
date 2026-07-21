import Foundation

enum NativeViewerSessionPhase: Equatable, Sendable {
    case connecting
    case waitingForAccessCode
    case waitingForHostApproval
    case live
    case reconnecting
    case failed(message: String)
    case ended(message: String?)

    var title: String {
        switch self {
        case .connecting:
            String(localized: "Connecting…")
        case .waitingForAccessCode:
            String(localized: "Access code required")
        case .waitingForHostApproval:
            String(localized: "Waiting for host approval…")
        case .live:
            String(localized: "Viewing live share")
        case .reconnecting:
            String(localized: "Reconnecting…")
        case let .failed(message):
            message
        case let .ended(message):
            message ?? String(localized: "Share ended")
        }
    }

    var isLive: Bool { self == .live }
    var isTerminal: Bool {
        switch self {
        case .failed, .ended: true
        default: false
        }
    }
}

enum NativeViewerTransportRoute: Equatable, Sendable {
    case unknown
    case peerToPeer
    case turn

    var title: String {
        switch self {
        case .unknown: String(localized: "Connecting")
        case .peerToPeer: "P2P"
        case .turn: "TURN"
        }
    }
}

struct NativeViewerSourceViewSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let applicationName: String
    let windowName: String
    let pixelWidth: Int
    let pixelHeight: Int
    let isVisible: Bool
    let isFocused: Bool
    let isConnected: Bool

    var title: String {
        if !windowName.isEmpty { return windowName }
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
        if !isConnected { values.append(String(localized: "Disconnected")) }
        return values.joined(separator: " · ")
    }
}

enum NativeViewerFriendshipState: Equatable, Sendable {
    case unavailable
    case available
    case pending
    case friends
    case declined
}

struct NativeViewerStatisticsSnapshot: Equatable, Sendable {
    let bitsPerSecond: Int
    let framesPerSecond: Double
    let packetsLost: Int64
    let codec: String?

    init(
        bitsPerSecond: Int = 0,
        framesPerSecond: Double = 0,
        packetsLost: Int64 = 0,
        codec: String? = nil
    ) {
        self.bitsPerSecond = max(0, bitsPerSecond)
        self.framesPerSecond = max(0, framesPerSecond)
        self.packetsLost = max(0, packetsLost)
        self.codec = codec
    }
}

struct NativeViewerViewSnapshot: Equatable, Sendable {
    let phase: NativeViewerSessionPhase
    let ownerName: String
    let ownerDeviceName: String?
    let route: NativeViewerTransportRoute
    let sources: [NativeViewerSourceViewSnapshot]
    let systemAudioAvailable: Bool
    let systemAudioEnabled: Bool
    let volume: Double
    let scaleMode: NativeViewerScaleMode
    let friendship: NativeViewerFriendshipState
    let statistics: NativeViewerStatisticsSnapshot

    init(
        phase: NativeViewerSessionPhase = .connecting,
        ownerName: String = "",
        ownerDeviceName: String? = nil,
        route: NativeViewerTransportRoute = .unknown,
        sources: [NativeViewerSourceViewSnapshot] = [],
        systemAudioAvailable: Bool = false,
        systemAudioEnabled: Bool = true,
        volume: Double = 1,
        scaleMode: NativeViewerScaleMode = .automatic,
        friendship: NativeViewerFriendshipState = .unavailable,
        statistics: NativeViewerStatisticsSnapshot = .init()
    ) {
        self.phase = phase
        self.ownerName = ownerName
        self.ownerDeviceName = ownerDeviceName
        self.route = route
        self.sources = sources
        self.systemAudioAvailable = systemAudioAvailable
        self.systemAudioEnabled = systemAudioEnabled
        self.volume = min(max(volume, 0), 1)
        self.scaleMode = scaleMode
        self.friendship = friendship
        self.statistics = statistics
    }

    var visibleSourceCount: Int { sources.count(where: \.isVisible) }

    var waitingForSourceMessage: String? {
        guard phase.isLive, sources.isEmpty else { return nil }
        let trimmedOwner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = trimmedOwner.isEmpty ? String(localized: "the host") : trimmedOwner
        return String(localized: "Waiting for \(owner) to share a window…")
    }
}
