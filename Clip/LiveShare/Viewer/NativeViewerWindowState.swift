import ClipLiveShare
import CoreGraphics
import CryptoKit
import Foundation

struct NativeViewerSourceSnapshot: Equatable, Sendable {
    let sourceInstanceID: String
    let streamID: String
    let applicationName: String
    let windowName: String
    let pixelSize: CGSize
    /// The source window or display size in macOS points. Encoded pixels stay
    /// separate so Retina captures remain sharp without appearing twice as
    /// large on a 1x viewer display.
    let sourcePointSize: CGSize
    let isFocused: Bool
    let isConnected: Bool
    let stateRevision: UInt64

    init(
        sourceInstanceID: String,
        streamID: String,
        applicationName: String,
        windowName: String,
        pixelSize: CGSize,
        sourcePointSize: CGSize,
        isFocused: Bool,
        isConnected: Bool,
        stateRevision: UInt64
    ) {
        self.sourceInstanceID = sourceInstanceID
        self.streamID = streamID
        self.applicationName = applicationName
        self.windowName = windowName
        self.pixelSize = pixelSize
        self.sourcePointSize = sourcePointSize
        self.isFocused = isFocused
        self.isConnected = isConnected
        self.stateRevision = stateRevision
    }
}

extension ClipLiveShareStreamDescriptor {
    var sourcePointSize: CGSize {
        CGSize(width: sourcePointWidth, height: sourcePointHeight)
    }
}

struct NativeViewerWindowID: Hashable, Sendable, CustomStringConvertible {
    private let rawValue: String

    static func source(instanceID: String) -> Self {
        Self(rawValue: "source:\(instanceID)")
    }

    var description: String { rawValue }
}

struct NativeViewerWindowSnapshot: Equatable, Identifiable, Sendable {
    let id: NativeViewerWindowID
    let source: NativeViewerSourceSnapshot
    var isVisible: Bool
    /// Local viewer presentation state. This is intentionally independent
    /// from the host-owned source lifecycle and geometry.
    var scaleMode: NativeViewerScaleMode
    var isFullScreen: Bool

    init(
        id: NativeViewerWindowID,
        source: NativeViewerSourceSnapshot,
        isVisible: Bool,
        scaleMode: NativeViewerScaleMode = .follow,
        isFullScreen: Bool = false
    ) {
        self.id = id
        self.source = source
        self.isVisible = isVisible
        self.scaleMode = scaleMode
        self.isFullScreen = isFullScreen
    }
}

enum NativeViewerWindowChange: Equatable, Sendable {
    case create(NativeViewerWindowSnapshot)
    case update(NativeViewerWindowSnapshot)
    case remove(NativeViewerWindowID)
    case visibility(NativeViewerWindowID, isVisible: Bool)
}

/// Reconciles remote source lifecycle without tracking window positions. AppKit
/// owns local placement after a window is created, so host geometry can never
/// pull a viewer's windows around their desktop.
struct NativeViewerWindowRegistry: Equatable, Sendable {
    private(set) var windows: [NativeViewerWindowID: NativeViewerWindowSnapshot] = [:]

    init() {}

    mutating func reconcile(_ sources: [NativeViewerSourceSnapshot]) -> [NativeViewerWindowChange] {
        var incoming: [NativeViewerWindowID: NativeViewerSourceSnapshot] = [:]
        for source in sources {
            let id = NativeViewerWindowID.source(
                instanceID: source.sourceInstanceID
            )
            guard let existing = incoming[id] else {
                incoming[id] = source
                continue
            }
            if source.stateRevision > existing.stateRevision {
                incoming[id] = source
            }
        }

        var changes: [NativeViewerWindowChange] = []
        for id in windows.keys.filter({ incoming[$0] == nil }).sorted(by: descriptionOrder) {
            windows.removeValue(forKey: id)
            changes.append(.remove(id))
        }
        for id in incoming.keys.sorted(by: descriptionOrder) {
            guard let source = incoming[id] else { continue }
            if var existing = windows[id] {
                guard existing.source != source else { continue }
                existing = NativeViewerWindowSnapshot(
                    id: id,
                    source: source,
                    isVisible: existing.isVisible,
                    scaleMode: existing.scaleMode,
                    isFullScreen: existing.isFullScreen
                )
                windows[id] = existing
                changes.append(.update(existing))
            } else {
                let snapshot = NativeViewerWindowSnapshot(
                    id: id,
                    source: source,
                    isVisible: true
                )
                windows[id] = snapshot
                changes.append(.create(snapshot))
            }
        }
        return changes
    }

    mutating func setVisible(
        _ isVisible: Bool,
        for id: NativeViewerWindowID
    ) -> NativeViewerWindowChange? {
        guard var snapshot = windows[id], snapshot.isVisible != isVisible else { return nil }
        snapshot.isVisible = isVisible
        windows[id] = snapshot
        return .visibility(id, isVisible: isVisible)
    }

    mutating func showAll() -> [NativeViewerWindowChange] {
        windows.keys.sorted(by: descriptionOrder).compactMap { setVisible(true, for: $0) }
    }

    mutating func setScaleMode(
        _ scaleMode: NativeViewerScaleMode,
        for id: NativeViewerWindowID
    ) {
        guard var snapshot = windows[id] else { return }
        snapshot.scaleMode = scaleMode
        windows[id] = snapshot
    }

    mutating func setFullScreen(
        _ isFullScreen: Bool,
        for id: NativeViewerWindowID
    ) {
        guard var snapshot = windows[id] else { return }
        snapshot.isFullScreen = isFullScreen
        windows[id] = snapshot
    }

    var visibleWindowCount: Int {
        windows.values.count(where: \.isVisible)
    }

    private func descriptionOrder(
        _ lhs: NativeViewerWindowID,
        _ rhs: NativeViewerWindowID
    ) -> Bool {
        lhs.description < rhs.description
    }
}

struct NativeViewerIdentityColor: Equatable, Sendable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    static func stable(for publicIdentity: Data) -> Self {
        let digest = SHA256.hash(data: publicIdentity)
        let bytes = Array(digest)
        let value = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Self(
            hue: Double(value) / Double(UInt16.max),
            saturation: 0.72,
            brightness: 0.92
        )
    }

    func focused(_ isFocused: Bool) -> Self {
        guard isFocused else { return self }
        return Self(
            hue: hue,
            saturation: min(1, saturation + 0.08),
            brightness: 1
        )
    }
}
