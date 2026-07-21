import CoreGraphics
import CryptoKit
import Foundation

enum NativeViewerSourceMode: Equatable, Sendable {
    case manual
    case followsFocusedWindow
}

struct NativeViewerSourceSnapshot: Equatable, Sendable {
    let sourceInstanceID: String
    let streamID: String
    let applicationName: String
    let windowName: String
    let pixelSize: CGSize
    let isFocused: Bool
    let isConnected: Bool
    let stateRevision: UInt64
    let mode: NativeViewerSourceMode
}

struct NativeViewerWindowID: Hashable, Sendable, CustomStringConvertible {
    private let rawValue: String

    static func manual(sourceInstanceID: String) -> Self {
        Self(rawValue: "manual:\(sourceInstanceID)")
    }

    static func automatic(sessionID: String) -> Self {
        Self(rawValue: "automatic:\(sessionID)")
    }

    var description: String { rawValue }
}

struct NativeViewerWindowSnapshot: Equatable, Identifiable, Sendable {
    let id: NativeViewerWindowID
    let source: NativeViewerSourceSnapshot
    var isVisible: Bool
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
    let sessionID: String
    private(set) var windows: [NativeViewerWindowID: NativeViewerWindowSnapshot] = [:]

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    mutating func reconcile(_ sources: [NativeViewerSourceSnapshot]) -> [NativeViewerWindowChange] {
        var incoming: [NativeViewerWindowID: NativeViewerSourceSnapshot] = [:]
        for source in sources {
            let id = switch source.mode {
            case .manual:
                NativeViewerWindowID.manual(sourceInstanceID: source.sourceInstanceID)
            case .followsFocusedWindow:
                NativeViewerWindowID.automatic(sessionID: sessionID)
            }
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
                    isVisible: existing.isVisible
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
