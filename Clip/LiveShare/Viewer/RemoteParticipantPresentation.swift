import Foundation

/// A source identity scoped to one remote participant.
struct RemoteParticipantSourceKey: Hashable, Sendable {
    let participantNamespace: Data
    let sourceInstanceID: String
}

/// A viewer-window identity scoped to one remote participant.
struct RemoteParticipantWindowKey: Hashable, Sendable {
    let participantNamespace: Data
    fileprivate let sourceInstanceID: String
}

struct RemoteParticipantLocalWindowPresentation: Equatable, Sendable {
    let scaleMode: NativeViewerScaleMode
    let isVisible: Bool
    let isFullScreen: Bool
}

/// Owns the presentation state for exactly one remote participant.
///
/// Authoritative source descriptors and negotiated media tracks can arrive in
/// either order. A source becomes presentable only when both are available.
/// Local window preferences are retained while a track reconnects or a
/// descriptor is replaced, but are discarded when the authoritative source is
/// actually removed.
struct RemoteParticipantPresentation<RemoteTrack> {
    private(set) var participantNamespace: Data?
    private(set) var isTornDown = false

    private var authoritativeSources: [NativeViewerSourceSnapshot] = []
    private var remoteTracksByStreamID: [String: RemoteTrack] = [:]
    private var localPresentationByWindow:
        [String: RemoteParticipantLocalWindowPresentation] = [:]

    init(participantNamespace: Data? = nil) {
        self.participantNamespace = participantNamespace
    }

    var readySources: [NativeViewerSourceSnapshot] {
        guard !isTornDown, participantNamespace != nil else { return [] }
        return authoritativeSources.filter {
            remoteTracksByStreamID[$0.streamID] != nil
        }
    }

    var sourceKeys: Set<RemoteParticipantSourceKey> {
        Set(authoritativeSources.compactMap { sourceKey(for: $0) })
    }

    mutating func replaceParticipantNamespace(_ participantNamespace: Data) {
        guard !isTornDown else { return }
        self.participantNamespace = participantNamespace
    }

    @discardableResult
    mutating func replaceAuthoritativeSources(
        _ sources: [NativeViewerSourceSnapshot]
    ) -> [NativeViewerSourceSnapshot] {
        guard !isTornDown else { return [] }
        authoritativeSources = sources

        let retainedSourceIDs = Set(sources.map(\.sourceInstanceID))
        localPresentationByWindow = localPresentationByWindow.filter {
            retainedSourceIDs.contains($0.key)
        }
        return readySources
    }

    @discardableResult
    mutating func upsertRemoteTrack(
        _ track: RemoteTrack,
        streamID: String
    ) -> [NativeViewerSourceSnapshot] {
        guard !isTornDown else { return [] }
        remoteTracksByStreamID[streamID] = track
        return readySources
    }

    @discardableResult
    mutating func removeRemoteTrack(
        streamID: String
    ) -> [NativeViewerSourceSnapshot] {
        guard !isTornDown else { return [] }
        remoteTracksByStreamID[streamID] = nil
        return readySources
    }

    func remoteTrack(forStreamID streamID: String) -> RemoteTrack? {
        guard !isTornDown else { return nil }
        return remoteTracksByStreamID[streamID]
    }

    func sourceKey(
        for source: NativeViewerSourceSnapshot
    ) -> RemoteParticipantSourceKey? {
        guard let participantNamespace else { return nil }
        return RemoteParticipantSourceKey(
            participantNamespace: participantNamespace,
            sourceInstanceID: source.sourceInstanceID
        )
    }

    func windowKey(
        for source: NativeViewerSourceSnapshot
    ) -> RemoteParticipantWindowKey? {
        guard let participantNamespace else { return nil }
        return RemoteParticipantWindowKey(
            participantNamespace: participantNamespace,
            sourceInstanceID: source.sourceInstanceID
        )
    }

    mutating func rememberLocalPresentation(
        _ windows: [NativeViewerWindowSnapshot]
    ) {
        guard !isTornDown else { return }
        for window in windows {
            localPresentationByWindow[window.source.sourceInstanceID] =
                RemoteParticipantLocalWindowPresentation(
                    scaleMode: window.scaleMode,
                    isVisible: window.isVisible,
                    isFullScreen: window.isFullScreen
                )
        }
    }

    func localPresentation(
        for source: NativeViewerSourceSnapshot
    ) -> RemoteParticipantLocalWindowPresentation? {
        guard !isTornDown else { return nil }
        return localPresentationByWindow[source.sourceInstanceID]
    }

    /// Clears participant-owned state exactly once.
    ///
    /// The return value lets the AppKit owner tear down its windows and video
    /// surfaces on the same first transition without repeating that work when
    /// application termination and session closure overlap.
    @discardableResult
    mutating func tearDown() -> Bool {
        guard !isTornDown else { return false }
        isTornDown = true
        authoritativeSources.removeAll()
        remoteTracksByStreamID.removeAll()
        localPresentationByWindow.removeAll()
        return true
    }
}
