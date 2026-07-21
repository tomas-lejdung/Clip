import ClipLiveShare
import CoreGraphics
import Foundation

struct NativeViewerCursorSnapshot: Equatable, Sendable {
    let streamID: String
    let normalizedX: CGFloat?
    let normalizedY: CGFloat?
}

enum NativeViewerV1ControlEffect: Equatable, Sendable {
    case sourcesChanged
    case cursorChanged(NativeViewerCursorSnapshot)
    case sharingChanged(Bool)
    case systemAudioChanged(Bool)
    case sessionClosed(reason: String?)
    case ignored
}

/// Race-safe application reducer for the browser-compatible v1 control
/// channel. The host's full manifest remains authoritative while incremental
/// messages update only a known stream and never create one from partial data.
struct NativeViewerV1ControlState: Equatable, Sendable {
    let sessionID: ClipLiveShareSessionID

    private(set) var streams: [ClipLiveShareStreamID: ClipLiveShareStreamDescriptor] = [:]
    private(set) var cursors: [ClipLiveShareStreamID: NativeViewerCursorSnapshot] = [:]
    private(set) var sharing = false
    private(set) var systemAudioEnabled = false
    private(set) var stateRevision: UInt64 = 0

    init(sessionID: ClipLiveShareSessionID) {
        self.sessionID = sessionID
    }

    var manifest: ClipLiveShareStreamManifest {
        try! ClipLiveShareStreamManifest(
            sessionID: sessionID,
            streams: streams.values.sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.id.rawValue < rhs.id.rawValue
            }
        )
    }

    var sourceSnapshots: [NativeViewerSourceSnapshot] {
        streams.values
            .filter(\.active)
            .sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.id.rawValue < rhs.id.rawValue
            }
            .map { stream in
                NativeViewerSourceSnapshot(
                    // V1 has no source-generation identifier. Binding the
                    // browser-compatible stream ID is deterministic and safe
                    // because its full manifest is authoritative.
                    sourceInstanceID: "v1:\(stream.id.rawValue)",
                    streamID: stream.id.rawValue,
                    applicationName: stream.appName,
                    windowName: stream.windowName,
                    pixelSize: CGSize(width: stream.width, height: stream.height),
                    sourcePointSize: stream.sourcePointSize,
                    isFocused: stream.focused,
                    isConnected: true,
                    stateRevision: stateRevision,
                    mode: .manual
                )
            }
    }

    mutating func apply(_ message: ClipLiveShareInnerMessage) throws
        -> NativeViewerV1ControlEffect
    {
        guard message.sessionID == sessionID else {
            throw ClipLiveShareProtocolError.invalidResource(
                "control message belongs to another viewer session"
            )
        }

        switch message {
        case let .manifest(manifest):
            streams = Dictionary(uniqueKeysWithValues: manifest.streams.map { ($0.id, $0) })
            pruneCursorsToFocusedStream()
            bumpRevision()
            return .sourcesChanged

        case let .streamState(value):
            guard let current = streams[value.streamID] else { return .ignored }
            streams[value.streamID] = try replacing(current, active: value.active)
            pruneCursorsToFocusedStream()
            bumpRevision()
            return .sourcesChanged

        case let .focus(value):
            guard value.streamID == nil || streams[value.streamID!]?.active == true else {
                return .ignored
            }
            for (id, current) in streams {
                streams[id] = try replacing(current, focused: id == value.streamID)
            }
            pruneCursorsToFocusedStream()
            bumpRevision()
            return .sourcesChanged

        case let .geometry(value):
            guard let current = streams[value.streamID] else { return .ignored }
            streams[value.streamID] = try replacing(
                current,
                width: value.width,
                height: value.height
            )
            bumpRevision()
            return .sourcesChanged

        case let .cursor(value):
            guard let stream = streams[value.streamID],
                  stream.active,
                  stream.focused else {
                // Cursor packets can arrive after a focus message because the
                // DataChannel is fed by independently sampled host state. An
                // old packet must never make an unfocused source's cursor
                // visible again.
                cursors[value.streamID] = nil
                return .ignored
            }
            let snapshot = NativeViewerCursorSnapshot(
                streamID: value.streamID.rawValue,
                normalizedX: value.inView ? CGFloat(value.x / 100) : nil,
                normalizedY: value.inView ? CGFloat(value.y / 100) : nil
            )
            cursors[value.streamID] = snapshot
            return .cursorChanged(snapshot)

        case let .sharingState(value):
            sharing = value.sharing
            return .sharingChanged(value.sharing)

        case let .systemAudioState(value):
            systemAudioEnabled = value.enabled
            return .systemAudioChanged(value.enabled)

        case let .sessionClosing(value):
            sharing = false
            return .sessionClosed(reason: value.reason)

        case .authChallenge, .authResponse, .authResult, .offer, .answer, .ice,
             .codecOffer, .codecAnswer, .codecICE, .error:
            return .ignored
        }
    }

    private mutating func bumpRevision() {
        stateRevision = stateRevision == UInt64.max ? UInt64.max : stateRevision + 1
    }

    private mutating func pruneCursorsToFocusedStream() {
        cursors = cursors.filter {
            streams[$0.key]?.active == true && streams[$0.key]?.focused == true
        }
    }

    private func replacing(
        _ value: ClipLiveShareStreamDescriptor,
        active: Bool? = nil,
        focused: Bool? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) throws -> ClipLiveShareStreamDescriptor {
        let nextActive = active ?? value.active
        return try ClipLiveShareStreamDescriptor(
            id: value.id,
            mediaTrackID: value.mediaTrackID,
            active: nextActive,
            focused: nextActive ? (focused ?? value.focused) : false,
            appName: value.appName,
            windowName: value.windowName,
            width: width ?? value.width,
            height: height ?? value.height,
            order: value.order,
            sourcePointWidth: value.sourcePointWidth,
            sourcePointHeight: value.sourcePointHeight
        )
    }
}
