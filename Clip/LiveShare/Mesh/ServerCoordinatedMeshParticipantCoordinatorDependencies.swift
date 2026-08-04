import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation

/// Narrow rendering boundary for collaboration shown over sources published by
/// this participant. Keeping the participant coordinator dependent on this
/// surface lets tests prove that authenticated room state reaches the host UI
/// without opening a real WindowServer overlay.
@MainActor
protocol ServerCoordinatedMeshParticipantSourceOverlayCoordinating: AnyObject {
    func update(
        sourceID: String,
        sourceFrame: CGRect,
        target: LiveShareCollaborationSourceOverlayTarget,
        snapshot: NativeViewerCollaborationOverlaySnapshot,
        isVisible: Bool
    )
    func updateSnapshot(
        sourceID: String,
        snapshot: NativeViewerCollaborationOverlaySnapshot,
        isVisible: Bool
    )
    func remove(sourceID: String)
    func retainSources(_ sourceIDs: Set<String>)
    func tearDown()
}

extension LiveShareCollaborationSourceOverlayCoordinator:
    ServerCoordinatedMeshParticipantSourceOverlayCoordinating {}

/// Narrow app-coordinator view of the v4 room session.
///
/// Keeping this type erased has two purposes: the UI coordinator does not
/// become another room state machine, and focused tests can drive complete
/// roster/session transitions without opening sockets. The concrete adapter
/// below forwards every operation to `ServerCoordinatedMeshRoomSession`.
struct ServerCoordinatedMeshParticipantRoomSessionClient: Sendable {
    let events: @Sendable () async
        -> AsyncStream<ServerCoordinatedMeshRoomSessionEvent>
    let snapshot: @Sendable () async
        -> ServerCoordinatedMeshRoomSessionSnapshot
    let start: @Sendable () async throws -> Void
    let setAdmissionPolicy: @Sendable (
        ClipLiveShareServerRoomV4AdmissionPolicy
    ) async throws -> Void
    let rotateInvite: @Sendable () async throws
        -> ClipLiveShareServerRoomV4Invite
    let approve: @Sendable (
        ClipLiveShareServerRoomV4CandidateHandle
    ) async throws -> Void
    let deny: @Sendable (
        ClipLiveShareServerRoomV4CandidateHandle
    ) async throws -> Void
    let removeMember: @Sendable (
        ClipLiveShareServerRoomV4MemberHandle
    ) async throws -> Void
    let publishLocalSources: @Sendable (
        [ClipLiveShareNativeV3PublishedSource]
    ) async throws -> Void
    let broadcastSourceCursor: @Sendable (
        ClipLiveShareNativeV3SourceCursor
    ) async throws -> Void
    let broadcastCollaboration: @Sendable (
        ClipLiveShareNativeV3CollaborationEvent
    ) async throws -> Void
    let sendFriendshipMessage: @Sendable (
        ClipLiveShareServerRoomV4SignedFriendMessage,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    let remoteVideoStream: @Sendable (
        ClipLiveShareStreamDescriptor,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> WebRTCRemoteVideoStream?
    let setRemoteAudioPlayback: @Sendable (
        Bool,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    let setRemoteAudioVolume: @Sendable (
        Double,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    let updateSenderPolicies: @Sendable (
        [Int: WebRTCSenderPolicy],
        WebRTCSenderPolicy,
        LiveShareEncodingMode
    ) async throws -> Void
    let updateVideoCodec: @Sendable (
        WebRTCVideoCodec,
        ClipLiveShareNativeV3ParticipantID,
        WebRTCVideoCodec
    ) async throws -> Void
    let refreshStatistics: @Sendable () async throws
        -> [ClipLiveShareNativeV3PeerStatistics]
    let pruneExpiredCollaboration: @Sendable (
        ClipLiveShareNativeTimestamp
    ) async -> Bool
    let leave: @Sendable () async -> Void
    let close: @Sendable () async -> Void

    init(
        events: @escaping @Sendable () async
            -> AsyncStream<ServerCoordinatedMeshRoomSessionEvent>,
        snapshot: @escaping @Sendable () async
            -> ServerCoordinatedMeshRoomSessionSnapshot,
        start: @escaping @Sendable () async throws -> Void,
        setAdmissionPolicy: @escaping @Sendable (
            ClipLiveShareServerRoomV4AdmissionPolicy
        ) async throws -> Void = { _ in },
        rotateInvite: @escaping @Sendable () async throws
            -> ClipLiveShareServerRoomV4Invite,
        approve: @escaping @Sendable (
            ClipLiveShareServerRoomV4CandidateHandle
        ) async throws -> Void = { _ in },
        deny: @escaping @Sendable (
            ClipLiveShareServerRoomV4CandidateHandle
        ) async throws -> Void = { _ in },
        removeMember: @escaping @Sendable (
            ClipLiveShareServerRoomV4MemberHandle
        ) async throws -> Void = { _ in },
        publishLocalSources: @escaping @Sendable (
            [ClipLiveShareNativeV3PublishedSource]
        ) async throws -> Void = { _ in },
        broadcastSourceCursor: @escaping @Sendable (
            ClipLiveShareNativeV3SourceCursor
        ) async throws -> Void = { _ in },
        broadcastCollaboration: @escaping @Sendable (
            ClipLiveShareNativeV3CollaborationEvent
        ) async throws -> Void = { _ in },
        sendFriendshipMessage: @escaping @Sendable (
            ClipLiveShareServerRoomV4SignedFriendMessage,
            ClipLiveShareNativeV3ParticipantID
        ) async throws -> Void = { _, _ in },
        remoteVideoStream: @escaping @Sendable (
            ClipLiveShareStreamDescriptor,
            ClipLiveShareNativeV3ParticipantID
        ) async throws -> WebRTCRemoteVideoStream? = { _, _ in nil },
        setRemoteAudioPlayback: @escaping @Sendable (
            Bool,
            ClipLiveShareNativeV3ParticipantID
        ) async throws -> Void = { _, _ in },
        setRemoteAudioVolume: @escaping @Sendable (
            Double,
            ClipLiveShareNativeV3ParticipantID
        ) async throws -> Void = { _, _ in },
        updateSenderPolicies: @escaping @Sendable (
            [Int: WebRTCSenderPolicy],
            WebRTCSenderPolicy,
            LiveShareEncodingMode
        ) async throws -> Void = { _, _, _ in },
        updateVideoCodec: @escaping @Sendable (
            WebRTCVideoCodec,
            ClipLiveShareNativeV3ParticipantID,
            WebRTCVideoCodec
        ) async throws -> Void = { _, _, _ in },
        refreshStatistics: @escaping @Sendable () async throws
            -> [ClipLiveShareNativeV3PeerStatistics] = { [] },
        pruneExpiredCollaboration: @escaping @Sendable (
            ClipLiveShareNativeTimestamp
        ) async -> Bool = { _ in false },
        leave: @escaping @Sendable () async -> Void = {},
        close: @escaping @Sendable () async -> Void = {}
    ) {
        self.events = events
        self.snapshot = snapshot
        self.start = start
        self.setAdmissionPolicy = setAdmissionPolicy
        self.rotateInvite = rotateInvite
        self.approve = approve
        self.deny = deny
        self.removeMember = removeMember
        self.publishLocalSources = publishLocalSources
        self.broadcastSourceCursor = broadcastSourceCursor
        self.broadcastCollaboration = broadcastCollaboration
        self.sendFriendshipMessage = sendFriendshipMessage
        self.remoteVideoStream = remoteVideoStream
        self.setRemoteAudioPlayback = setRemoteAudioPlayback
        self.setRemoteAudioVolume = setRemoteAudioVolume
        self.updateSenderPolicies = updateSenderPolicies
        self.updateVideoCodec = updateVideoCodec
        self.refreshStatistics = refreshStatistics
        self.pruneExpiredCollaboration = pruneExpiredCollaboration
        self.leave = leave
        self.close = close
    }

    init(_ session: ServerCoordinatedMeshRoomSession) {
        events = { await session.events() }
        snapshot = { await session.snapshot() }
        start = { try await session.start() }
        setAdmissionPolicy = { try await session.setAdmissionPolicy($0) }
        rotateInvite = { try await session.rotateInvite() }
        approve = { try await session.approve($0) }
        deny = { try await session.deny($0) }
        removeMember = { try await session.removeMember($0) }
        publishLocalSources = { try await session.publishLocalSources($0) }
        broadcastSourceCursor = {
            try await session.broadcastSourceCursor($0)
        }
        broadcastCollaboration = {
            try await session.broadcastCollaboration($0)
        }
        sendFriendshipMessage = { message, participantID in
            try await session.sendFriendshipMessage(
                message,
                to: participantID
            )
        }
        remoteVideoStream = { descriptor, participantID in
            try await session.remoteVideoStream(
                for: descriptor,
                from: participantID
            )
        }
        setRemoteAudioPlayback = { enabled, participantID in
            try await session.setRemoteParticipantAudioPlaybackEnabled(
                enabled,
                for: participantID
            )
        }
        setRemoteAudioVolume = { volume, participantID in
            try await session.setRemoteParticipantAudioVolume(
                volume,
                for: participantID
            )
        }
        updateSenderPolicies = { policies, fallback, mode in
            try await session.updateSenderPolicies(
                policies,
                fallback: fallback,
                videoEncodingMode: mode
            )
        }
        updateVideoCodec = { codec, participantID, previous in
            try await session.updateVideoCodecPreference(
                codec,
                for: participantID,
                rollbackTo: previous
            )
        }
        refreshStatistics = { try await session.refreshStatistics() }
        pruneExpiredCollaboration = {
            (try? await session.pruneExpiredCollaboration(at: $0)) ?? false
        }
        leave = { await session.leave() }
        close = { await session.close() }
    }
}

/// Testable participant-owned publication surface. The live adapter below is
/// backed by the unchanged ScreenCaptureKit publication controller and capture
/// publisher; v4 never substitutes a different capture or quality path.
@MainActor
struct ServerCoordinatedMeshParticipantLocalMediaClient {
    var start: () -> Void = {}
    var hideForApplicationTermination: () -> Void = {}
    var stop: () async -> Void = {}
    var shareFocusedWindow: () -> Void = {}
    var shareWindow: (String) -> Void = { _ in }
    var stopSource: (ClipLiveShareSourceInstanceID) -> Void = { _ in }
    var setFullscreenEnabled: (Bool) -> Void = { _ in }
    var stopAllMedia: () -> Void = {}
    var updateSettings: (LiveShareSettingsViewSnapshot) -> Void = { _ in }
    var activeSources: () -> [MeshRoomLocalSourceSnapshot] = { [] }
    var activeCaptures: () async -> [MeshParticipantCapturePublisher.ActiveSource] = {
        []
    }
    var captureDiagnostics: () async -> [MeshParticipantCaptureDiagnostics] = {
        []
    }
    var cursorSnapshot: () -> MeshParticipantLocalCursorSnapshot? = { nil }
    var settle: () async -> Void = {}
    var failures: () async -> AsyncStream<MeshParticipantCaptureFailure> = {
        AsyncStream { $0.finish() }
    }
}

@MainActor
final class ServerCoordinatedMeshParticipantCallbackRelay {
    weak var owner: ServerCoordinatedMeshParticipantCoordinator?

    func publicationChanged(
        _ snapshot: MeshParticipantLocalPublicationSnapshot
    ) {
        owner?.localPublicationDidChange(snapshot)
    }

    func publicationFailed(_ message: String) {
        owner?.localPublicationDidFail(message)
    }
}
