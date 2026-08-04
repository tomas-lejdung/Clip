import AppKit
import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import OSLog

enum MeshCreatorPresenceInvitePolicy {
    static func invite(
        role: ClipLiveShareServerRoomV4ClientRole,
        phase: ServerCoordinatedMeshRoomSessionPhase,
        invite: ClipLiveShareServerRoomV4Invite?
    ) -> ClipLiveShareServerRoomV4Invite? {
        guard role == .creator, phase == .active else { return nil }
        return invite
    }
}

/// Identifies a recoverable room/control operation independently from local
/// capture publication. A successful retry may clear only the failure for the
/// same operation; capture recovery remains driven by publication state.
enum MeshParticipantControlOperation: Equatable, Sendable {
    case admissionPolicy
    case inviteRotation
    case admissionDecision
    case participantRemoval
    case remoteAudio
    case collaboration

    var failureTitle: String {
        switch self {
        case .admissionPolicy:
            String(localized: "Room settings issue")
        case .inviteRotation:
            String(localized: "Invite issue")
        case .admissionDecision, .participantRemoval:
            String(localized: "Room action issue")
        case .remoteAudio:
            String(localized: "Audio control issue")
        case .collaboration:
            String(localized: "Collaboration issue")
        }
    }
}

/// App/UI owner for one participant in the clean-slate server-rostered mesh.
///
/// Membership is never inferred from peer links. The last creator-verified
/// server roster remains authoritative through a socket reconnect grace
/// period, while each direct WebRTC pair is allowed to fail independently.
/// There is deliberately no election, quorum, handoff or leaderless state:
/// when the immutable creator ends/leaves, the room session is terminal.
@MainActor
final class ServerCoordinatedMeshParticipantCoordinator {
    private static let logger = Logger(
        subsystem: ApplicationDirectories.bundleIdentifier,
        category: "server-coordinated-mesh-participant"
    )

    let localParticipantID: ClipLiveShareNativeV3ParticipantID
    private let localIdentity: Data
    private let localDisplayName: String
    private let localDeviceName: String?
    private let session: ServerCoordinatedMeshParticipantRoomSessionClient
    private let localMedia: ServerCoordinatedMeshParticipantLocalMediaClient
    private let now: @Sendable () -> Date
    private let onSessionEnded: () -> Void
    private let onMenuBarStatusChanged: (MeshParticipantMenuBarStatus) -> Void
    private let onCreatorInviteChanged: (
        ClipLiveShareServerRoomV4Invite?
    ) -> Void
    private let onFriendshipsChanged: () -> Void
    private let onRoomPhaseChanged: (
        ServerCoordinatedMeshRoomSessionPhase
    ) -> Void
    private let onAccessWordRequired: () -> Void
    private let onAdmissionDenied: (String) -> Void
    private let onRoomConnectionFailed: (String) -> Void
    private let persistAdmissionPreferences: (Bool, Bool) -> Void
    private let confirmLeaveAfterLastRemoteWindowCloses: () -> Bool
    private let collaborationConfiguration:
        MeshParticipantCollaborationConfiguration
    private var friendshipController: MeshFriendshipHandshakeController?
    private var friendshipSnapshot = MeshFriendshipHandshakeSnapshot()
    private var trustedFriendParticipantIDs:
        Set<ClipLiveShareNativeV3ParticipantID> = []
    private var publishedCreatorInviteURL: String?
    private var reportedRoomPhase: ServerCoordinatedMeshRoomSessionPhase?

    private var roomSnapshot: ServerCoordinatedMeshRoomSessionSnapshot?
    private var localPublication = MeshParticipantLocalPublicationSnapshot()
    private var phase: MeshRoomPhase = .connecting
    private var startedAt: Date?
    private var statusNotice: MeshRoomStatusNoticeSnapshot?
    /// Capture, peer, friendship, and room-control recovery are independent.
    /// Keep their notices separate so success in one subsystem cannot erase a
    /// still-actionable failure in another.
    private var localPublicationNotice: MeshRoomStatusNoticeSnapshot?
    private var localPublicationFailureBaseline:
        LocalPublicationFailureBaseline?
    private var pairStatusNotice: MeshRoomStatusNoticeSnapshot?
    private var friendshipStatusNotice: MeshRoomStatusNoticeSnapshot?
    private var controlStatusNotice: MeshRoomStatusNoticeSnapshot?
    private var failedControlOperation: MeshParticipantControlOperation?
    private var eventTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var captureFailureTask: Task<Void, Never>?
    private var nativeCursorTask: Task<Void, Never>?
    private var collaborationExpiryTask: Task<Void, Never>?
    private var localOverlayTask: Task<Void, Never>?
    private var isEnding = false
    private var isShutdownRunning = false
    private var hasCompletedShutdown = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var didNotifyEnd = false

    private var remotePresentations:
        [ClipLiveShareNativeV3ParticipantID:
            RemoteParticipantPresentation<WebRTCRemoteVideoStream>] = [:]
    private var remoteWindows:
        [ClipLiveShareNativeV3ParticipantID: NativeViewerWindowCoordinator] = [:]
    private var audioEnabled:
        [ClipLiveShareNativeV3ParticipantID: Bool] = [:]
    private var audioVolume:
        [ClipLiveShareNativeV3ParticipantID: Double] = [:]
    private var pairFailures:
        [ClipLiveShareNativeV3ParticipantID: String] = [:]
    private var mediaRateEstimator = MeshRoomMediaRateEstimator()
    private var localCaptureDiagnosticsBySourceID:
        [String: MeshParticipantCaptureDiagnostics] = [:]

    private var accessWord: String?
    private var askBeforeJoining: Bool
    private var collaborationPolicy = MeshRoomCollaborationPolicyReducer()
    private var nativeCursorSequenceBySource:
        [ClipLiveShareNativeV3SourceKey: UInt64] = [:]
    private var collaborationSequenceBySource:
        [ClipLiveShareNativeV3SourceKey: UInt64] = [:]
    private var collaborationPointerSequenceBySource:
        [ClipLiveShareNativeV3SourceKey: UInt64] = [:]
    private var collaborationPointerCoalescers:
        [ClipLiveShareNativeV3SourceKey:
            NativeViewerCollaborationPointerCoalescer] = [:]
    private let localSourceOverlays:
        any ServerCoordinatedMeshParticipantSourceOverlayCoordinating

    private(set) var presentationModel: MeshRoomPresentationModel!

    private struct LocalPublicationFailureBaseline: Equatable {
        let publication: MeshParticipantLocalPublicationSnapshot
        let sources: [MeshRoomLocalSourceSnapshot]
    }

    init(
        localParticipantID: ClipLiveShareNativeV3ParticipantID,
        localIdentity: Data,
        localDisplayName: String,
        localDeviceName: String? = Host.current().localizedName,
        session: ServerCoordinatedMeshParticipantRoomSessionClient,
        localMedia: ServerCoordinatedMeshParticipantLocalMediaClient = .init(),
        localSourceOverlays:
            any ServerCoordinatedMeshParticipantSourceOverlayCoordinating =
                LiveShareCollaborationSourceOverlayCoordinator(),
        initialSettings: LiveShareSettings = .default,
        friendshipDependencies: MeshFriendshipHandshakeDependencies? = nil,
        accessWord: String? = nil,
        askBeforeJoining: Bool = false,
        now: @escaping @Sendable () -> Date = Date.init,
        persistAdmissionPreferences: @escaping (Bool, Bool) -> Void = {
            _, _ in
        },
        confirmLeaveAfterLastRemoteWindowCloses:
            @escaping () -> Bool = {
                ServerCoordinatedMeshParticipantCoordinator
                    .presentLastRemoteWindowCloseConfirmation()
            },
        onSessionEnded: @escaping () -> Void = {},
        onCreatorInviteChanged: @escaping (
            ClipLiveShareServerRoomV4Invite?
        ) -> Void = { _ in },
        onFriendshipsChanged: @escaping () -> Void = {},
        onRoomPhaseChanged: @escaping (
            ServerCoordinatedMeshRoomSessionPhase
        ) -> Void = { _ in },
        onAccessWordRequired: @escaping () -> Void = {},
        onAdmissionDenied: @escaping (String) -> Void = { _ in },
        onRoomConnectionFailed: @escaping (String) -> Void = { _ in },
        onMenuBarStatusChanged: @escaping (
            MeshParticipantMenuBarStatus
        ) -> Void = { _ in }
    ) {
        self.localParticipantID = localParticipantID
        self.localIdentity = localIdentity
        self.localDisplayName = localDisplayName
        self.localDeviceName = localDeviceName
        self.session = session
        self.localMedia = localMedia
        self.localSourceOverlays = localSourceOverlays
        self.accessWord = Self.normalizedAccessWord(accessWord)
        self.askBeforeJoining = askBeforeJoining
        self.now = now
        self.persistAdmissionPreferences = persistAdmissionPreferences
        self.confirmLeaveAfterLastRemoteWindowCloses =
            confirmLeaveAfterLastRemoteWindowCloses
        self.onSessionEnded = onSessionEnded
        self.onCreatorInviteChanged = onCreatorInviteChanged
        self.onFriendshipsChanged = onFriendshipsChanged
        self.onRoomPhaseChanged = onRoomPhaseChanged
        self.onAccessWordRequired = onAccessWordRequired
        self.onAdmissionDenied = onAdmissionDenied
        self.onRoomConnectionFailed = onRoomConnectionFailed
        self.onMenuBarStatusChanged = onMenuBarStatusChanged
        collaborationConfiguration = .init(
            settings: initialSettings,
            persistentIdentity: localIdentity
        )
        collaborationPolicy = .init(
            globalSelection: .init(
                pointerEnabled:
                    initialSettings.collaborationPointerVisibleByDefault
            )
        )
        localPublication.settings = LiveShareSettingsViewSnapshot(
            quality: initialSettings.quality,
            frameRate: initialSettings.frameRate,
            codec: .init(codec: initialSettings.videoCodec),
            colorMode: initialSettings.colorMode,
            systemAudioEnabled: initialSettings.systemAudioEnabled,
            excludedAudioApplicationIDs:
                initialSettings.excludedAudioApplicationBundleIdentifiers,
            cursorUpdatesMatchFrameRate:
                initialSettings.cursorUpdatesMatchFrameRate,
            prioritizeFocusedWindow:
                initialSettings.prioritizeFocusedWindow,
            mode: initialSettings.encodingMode,
            advancedVideoSettings: initialSettings.advancedVideoSettings,
            autoShareFocusedWindows:
                initialSettings.autoShareFocusedWindows
        )
        presentationModel = MeshRoomPresentationModel(
            snapshot: makePresentationSnapshot(),
            actions: makePresentationActions()
        )
        if let friendshipDependencies {
            friendshipController = MeshFriendshipHandshakeController(
                localDisplayName: localDisplayName,
                localDeviceName: localDeviceName,
                dependencies: friendshipDependencies,
                now: now,
                sendMessage: { [session] message, participantID in
                    try await session.sendFriendshipMessage(
                        message,
                        participantID
                    )
                },
                onSnapshotChanged: { [weak self] snapshot in
                    guard let self else { return }
                    let trustedIDs = Set(
                        snapshot.stateByParticipantID.compactMap {
                            participantID, state in
                            state == .trusted ? participantID : nil
                        }
                    )
                    if trustedIDs != trustedFriendParticipantIDs {
                        trustedFriendParticipantIDs = trustedIDs
                        onFriendshipsChanged()
                    }
                    friendshipSnapshot = snapshot
                    friendshipStatusNotice = snapshot.notice.map {
                        .init(
                            title: String(localized: "Friend request"),
                            message: $0,
                            severity: .information
                        )
                    }
                    refreshRecoverableStatusNotice()
                    publishMenuBarStatus()
                    publish()
                }
            )
        }
    }

    var isActive: Bool { eventTask != nil && !isEnding }

    func start() {
        guard eventTask == nil, !isEnding else { return }
        startedAt = now()
        phase = .connecting
        localMedia.start()
        onMenuBarStatusChanged(.ready)

        captureFailureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let failures = await localMedia.failures()
            for await failure in failures {
                guard !Task.isCancelled, !isEnding else { return }
                handleCaptureFailure(failure)
            }
        }

        nativeCursorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !isEnding else { return }
                let updatesPerSecond = await publishNativeCursor()
                do {
                    try await Task.sleep(
                        for: .nanoseconds(
                            1_000_000_000 / Int64(max(1, updatesPerSecond))
                        )
                    )
                } catch {
                    return
                }
            }
        }

        collaborationExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    guard let self, !isEnding,
                          let timestamp = try? ClipLiveShareNativeTimestamp(
                            date: now()
                          ) else { continue }
                    _ = await session.pruneExpiredCollaboration(timestamp)
                } catch {
                    return
                }
            }
        }

        localOverlayTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !isEnding else { return }
                await refreshLocalSourceOverlays()
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }

        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let events = await session.events()
            do {
                try await session.start()
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await handle(event)
                }
                if !hasCompletedShutdown, !Task.isCancelled {
                    await tearDown(
                        finalMessage: String(
                            localized: "Room connection closed."
                        )
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await tearDown(finalMessage: error.localizedDescription)
            }
        }

        statisticsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    guard let self, !isEnding else { return }
                    await refreshLocalCaptureDiagnostics()
                    _ = try await session.refreshStatistics()
                } catch is CancellationError {
                    return
                } catch {
                    Self.logger.debug(
                        "V4 peer statistics unavailable: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        publish()
    }

    func leaveRoom() {
        guard !isEnding, !phase.isTerminal else { return }
        isEnding = true
        phase = .ending
        publish()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await session.leave()
            await tearDown(finalMessage: String(localized: "You left the room."))
        }
    }

    func endRoomForEveryone() {
        guard isCreator, !isEnding, !phase.isTerminal else { return }
        // V4 intentionally defines creator leave as room termination. There
        // is no authority transfer/election path to race this action.
        leaveRoom()
    }

    func close() async {
        if isEnding {
            await waitForShutdown()
            return
        }
        isEnding = true
        await session.close()
        await tearDown(finalMessage: String(localized: "Room session closed."))
    }

    func hideForApplicationTermination() {
        remoteWindows.values.forEach { $0.tearDown() }
        localSourceOverlays.tearDown()
        localMedia.hideForApplicationTermination()
    }

    func cancelForApplicationStop() {
        guard !isEnding else { return }
        isEnding = true
        cancelTasks()
        remoteWindows.values.forEach { $0.tearDown() }
        localSourceOverlays.tearDown()
        localMedia.hideForApplicationTermination()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await session.close()
            await tearDown(finalMessage: String(localized: "Room session closed."))
        }
    }

    func endForApplicationTermination() async {
        hideForApplicationTermination()
        if isEnding {
            await waitForShutdown()
            return
        }
        isEnding = true
        await session.leave()
        await tearDown(
            finalMessage: isCreator
                ? String(localized: "The room creator ended the room.")
                : String(localized: "You left the room.")
        )
    }

    func settlePendingOperations() async {
        await localMedia.settle()
        await Task.yield()
    }

    func localPublicationDidChange(
        _ snapshot: MeshParticipantLocalPublicationSnapshot
    ) {
        localPublication = snapshot
        let current = LocalPublicationFailureBaseline(
            publication: snapshot,
            sources: localMedia.activeSources()
        )
        if let baseline = localPublicationFailureBaseline,
           current != baseline {
            localPublicationFailureBaseline = nil
            localPublicationNotice = nil
            refreshRecoverableStatusNotice()
        }
        publish()
    }

    func localPublicationDidFail(_ message: String) {
        localPublicationFailureBaseline = .init(
            publication: localPublication,
            sources: localMedia.activeSources()
        )
        localPublicationNotice = .init(
            title: String(localized: "Sharing issue"),
            message: message,
            severity: .error
        )
        refreshRecoverableStatusNotice()
        publish()
    }

    func controlOperationDidFail(
        _ operation: MeshParticipantControlOperation,
        message: String
    ) {
        failedControlOperation = operation
        controlStatusNotice = .init(
            title: operation.failureTitle,
            message: message,
            severity: .warning
        )
        refreshRecoverableStatusNotice()
        publish()
    }

    func controlOperationDidSucceed(
        _ operation: MeshParticipantControlOperation
    ) {
        guard failedControlOperation == operation else { return }
        failedControlOperation = nil
        controlStatusNotice = nil
        refreshRecoverableStatusNotice()
        publish()
    }

    // MARK: - Room events

    private func handle(
        _ event: ServerCoordinatedMeshRoomSessionEvent
    ) async {
        switch event {
        case let .snapshotChanged(snapshot):
            await apply(snapshot)
        case .pendingJoin:
            // The complete pending set comes from the next authoritative room
            // snapshot; never accumulate one-off events into shadow state.
            onMenuBarStatusChanged(.admissionRequest)
        case let .pairFailed(participantID, message):
            pairFailures[participantID] = message
            pairStatusNotice = .init(
                title: String(localized: "One participant connection needs attention"),
                message: message,
                severity: .warning
            )
            refreshRecoverableStatusNotice()
            publish()
        case let .pairRecovered(participantID):
            pairFailures[participantID] = nil
            if pairFailures.isEmpty {
                pairStatusNotice = nil
            }
            refreshRecoverableStatusNotice()
            publish()
            await friendshipController?.retry(participantID: participantID)
        case let .friendshipMessageReceived(message, participantID):
            await friendshipController?.handle(
                message,
                from: participantID
            )
        case let .roomEnded(reason):
            await tearDown(finalMessage: reason)
        case .accessWordRequired:
            onAccessWordRequired()
            await tearDown(
                finalMessage: String(localized: "Access Word Required")
            )
        case let .admissionDenied(reason):
            onAdmissionDenied(reason)
            await tearDown(
                finalMessage: reason.isEmpty
                    ? String(localized: "The room denied admission.")
                    : reason
            )
        case let .failed(message):
            onRoomConnectionFailed(message)
            fail(message)
        case .closed:
            await tearDown(
                finalMessage: phase.terminalMessage
                    ?? String(localized: "Room connection closed.")
            )
        }
    }

    private func apply(
        _ snapshot: ServerCoordinatedMeshRoomSessionSnapshot
    ) async {
        guard !isEnding || snapshot.phase.isTerminal else { return }
        roomSnapshot = snapshot
        // Collaboration vectors are normalized to their source. Repaint them
        // immediately against cached geometry; the 250 ms overlay task remains
        // responsible only for resolving window/display frames.
        if let verified = snapshot.verifiedRoom {
            refreshLocalSourceOverlaySnapshots(
                media: snapshot.media,
                verified: verified
            )
        }
        if reportedRoomPhase != snapshot.phase {
            reportedRoomPhase = snapshot.phase
            onRoomPhaseChanged(snapshot.phase)
        }
        publishCreatorInviteIfNeeded(
            MeshCreatorPresenceInvitePolicy.invite(
                role: snapshot.role,
                phase: snapshot.phase,
                invite: snapshot.invite
            )
        )
        await friendshipController?.updateRoom(
            friendshipRoomContext(snapshot.verifiedRoom)
        )
        switch snapshot.phase {
        case .idle, .connecting, .waitingForAdmission:
            // A reconnect never discards verified members. The room actor
            // retains its last verified roster while the socket is in grace.
            phase = snapshot.verifiedRoom == nil ? .connecting : .reconnecting
        case .active:
            phase = .live(
                elapsedSeconds: max(
                    0,
                    startedAt.map { now().timeIntervalSince($0) } ?? 0
                )
            )
        case let .ended(reason):
            phase = .ended(message: reason)
            await tearDown(finalMessage: reason)
            return
        }
        recordMediaRates(snapshot.media)
        await reconcileRemotePresentations(snapshot)
        if let pairNotice = pairNotice(snapshot: snapshot) {
            pairStatusNotice = pairNotice
        } else {
            pairStatusNotice = nil
        }
        refreshRecoverableStatusNotice()
        publishMenuBarStatus()
        publish()
    }

    private func refreshRecoverableStatusNotice() {
        statusNotice = localPublicationNotice
            ?? pairStatusNotice
            ?? controlStatusNotice
            ?? friendshipStatusNotice
    }

    private func publishCreatorInviteIfNeeded(
        _ invite: ClipLiveShareServerRoomV4Invite?
    ) {
        let canonicalURL = invite.flatMap {
            try? $0.url.absoluteString
        }
        guard canonicalURL != publishedCreatorInviteURL else { return }
        publishedCreatorInviteURL = canonicalURL
        onCreatorInviteChanged(invite)
    }

    private func publishMenuBarStatus() {
        if !pendingAdmissions.isEmpty
            || !friendshipSnapshot.pendingRequests.isEmpty {
            onMenuBarStatusChanged(.admissionRequest)
        } else if phase == .reconnecting {
            onMenuBarStatusChanged(.reconnecting)
        } else {
            onMenuBarStatusChanged(.ready)
        }
    }

    private func fail(_ message: String) {
        guard !phase.isTerminal else { return }
        phase = .failed(message: message)
        statusNotice = .init(
            title: String(localized: "Live Share stopped"),
            message: message,
            severity: .error
        )
        publish()
    }

    private func tearDown(finalMessage: String) async {
        if hasCompletedShutdown { return }
        if isShutdownRunning {
            await waitForShutdown()
            return
        }
        isShutdownRunning = true
        isEnding = true
        cancelTasks()
        await localMedia.stop()
        for windows in remoteWindows.values { windows.tearDown() }
        remoteWindows.removeAll()
        for id in remotePresentations.keys {
            remotePresentations[id]?.tearDown()
        }
        remotePresentations.removeAll()
        localSourceOverlays.tearDown()
        collaborationPolicy.removeAllSources()
        publishCreatorInviteIfNeeded(nil)
        phase = .ended(message: finalMessage)
        hasCompletedShutdown = true
        isShutdownRunning = false
        publish()
        onMenuBarStatusChanged(.ready)
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        if !didNotifyEnd {
            didNotifyEnd = true
            onSessionEnded()
        }
    }

    private func cancelTasks() {
        eventTask?.cancel()
        statisticsTask?.cancel()
        captureFailureTask?.cancel()
        nativeCursorTask?.cancel()
        collaborationExpiryTask?.cancel()
        localOverlayTask?.cancel()
        eventTask = nil
        statisticsTask = nil
        captureFailureTask = nil
        nativeCursorTask = nil
        collaborationExpiryTask = nil
        localOverlayTask = nil
        collaborationPointerCoalescers.values.forEach { $0.cancel() }
        collaborationPointerCoalescers.removeAll(keepingCapacity: false)
    }

    private func waitForShutdown() async {
        guard !hasCompletedShutdown else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    // MARK: - Remote presentation

    private func reconcileRemotePresentations(
        _ sessionSnapshot: ServerCoordinatedMeshRoomSessionSnapshot
    ) async {
        guard let verified = sessionSnapshot.verifiedRoom else { return }
        if let media = sessionSnapshot.media {
            let authoritativeRemoteSources = Set(
                media.sourceSnapshots.values.flatMap(\.sources)
                    .filter {
                        $0.key.ownerParticipantID != localParticipantID
                    }
                    .map { collaborationPolicyKey(for: $0.key) }
            )
            let removed = collaborationPolicy
                .reconcileAuthoritativeSources(authoritativeRemoteSources)
            pruneCollaborationBookkeeping(for: removed)
        }
        let remoteMembers = verified.members.filter { !$0.isLocal }
        let remoteIDs = Set(remoteMembers.map(\.descriptor.participantID))
        for participantID in remoteWindows.keys
        where !remoteIDs.contains(participantID) {
            remoteWindows.removeValue(forKey: participantID)?.tearDown()
            remotePresentations[participantID]?.tearDown()
            remotePresentations[participantID] = nil
            audioEnabled[participantID] = nil
            audioVolume[participantID] = nil
            pairFailures[participantID] = nil
        }

        for member in remoteMembers {
            let participantID = member.descriptor.participantID
            if remotePresentations[participantID] == nil {
                remotePresentations[participantID] = .init(
                    participantNamespace:
                        member.descriptor.identity.x963Representation
                )
            }
            if remoteWindows[participantID] == nil {
                installWindowCoordinator(for: member)
            } else {
                remoteWindows[participantID]?.setOwnerName(
                    member.descriptor.displayName
                )
            }

            var presentation = remotePresentations[participantID]
                ?? .init(
                    participantNamespace:
                        member.descriptor.identity.x963Representation
                )
            let existingWindowSnapshots =
                remoteWindows[participantID]?.windowSnapshots ?? []
            presentation.rememberLocalPresentation(existingWindowSnapshots)
            let published = sessionSnapshot.media?
                .sourceSnapshots[participantID]?.sources ?? []
            let connectedTrackIDs = sessionSnapshot.media?
                .remoteVideoTrackIDs[participantID] ?? []
            let retainedStreamIDs = Set(published.compactMap { source in
                connectedTrackIDs.contains(source.descriptor.stream.mediaTrackID)
                    ? source.descriptor.stream.id.rawValue : nil
            })
            for source in presentation.readySources
            where !retainedStreamIDs.contains(source.streamID) {
                _ = presentation.removeRemoteTrack(streamID: source.streamID)
            }
            _ = presentation.replaceAuthoritativeSources(
                published.map { nativeViewerSource($0, media: sessionSnapshot.media) }
            )
            for source in published {
                guard connectedTrackIDs.contains(
                    source.descriptor.stream.mediaTrackID
                ) else {
                    _ = presentation.removeRemoteTrack(
                        streamID: source.descriptor.stream.id.rawValue
                    )
                    continue
                }
                if let stream = try? await session.remoteVideoStream(
                    source.descriptor.stream,
                    participantID
                ) {
                    _ = presentation.upsertRemoteTrack(
                        stream,
                        streamID: source.descriptor.stream.id.rawValue
                    )
                }
            }
            remotePresentations[participantID] = presentation
            do {
                try remoteWindows[participantID]?.reconcile(
                    presentation.windowSources(
                        retaining: existingWindowSnapshots
                    )
                )
                if route(for: member, media: sessionSnapshot.media)
                    == .disconnected {
                    remoteWindows[participantID]?.markDisconnected()
                }
            } catch {
                remoteWindows.removeValue(forKey: participantID)?.tearDown()
                pairFailures[participantID] = error.localizedDescription
            }
            applyCursor(for: participantID, media: sessionSnapshot.media)
            applyCollaborationOverlays(
                for: participantID,
                media: sessionSnapshot.media,
                verified: verified
            )
        }
    }

    private func installWindowCoordinator(
        for member: ClipLiveShareServerRoomV4ClientVerifiedMember
    ) {
        let participantID = member.descriptor.participantID
        let coordinator = NativeViewerWindowCoordinator(
            ownerName: member.descriptor.displayName,
            ownerPublicIdentity:
                member.descriptor.identity.x963Representation,
            surfaceFactory: { [weak self] in
                let videoView = WebRTCRemoteVideoView(frame: .zero)
                let adapter = NativeViewerVideoSurfaceAdapter(
                    view: videoView,
                    bind: { [weak self, weak videoView] source in
                        guard
                            let self,
                            let videoView,
                            let stream = remotePresentations[participantID]?
                                .remoteTrack(forStreamID: source.streamID)
                        else {
                            throw NativeViewerSurfaceBindingError.unavailable(
                                source.streamID
                            )
                        }
                        videoView.bind(to: stream)
                    },
                    teardown: { [weak videoView] in videoView?.teardown() }
                )
                videoView.onDecodedPixelSizeChange = { [weak adapter] size in
                    adapter?.decodedPixelSizeDidChange(size)
                }
                return adapter
            }
        )
        coordinator.confirmLeaveWhenLastWindowCloses = { [weak self] in
            guard let self else { return false }
            let visibleRemoteWindowCount = remoteWindows.values.reduce(
                into: 0
            ) { count, windows in
                count += windows.visibleWindowCount
            }
            let hasRemoteAudio =
                roomSnapshot?.media?.audioTrackIDs.isEmpty == false
            guard MeshRemoteWindowClosePolicy.shouldConfirmLeave(
                visibleRemoteWindowCount: visibleRemoteWindowCount,
                hasRemoteAudio: hasRemoteAudio
            ) else { return false }
            return confirmLeaveAfterLastRemoteWindowCloses()
        }
        coordinator.onLeaveRequested = { [weak self] in self?.leaveRoom() }
        coordinator.onPresentationChanged = { [weak self] in self?.publish() }
        coordinator.onCollaborationControlChanged = {
            [weak self] sourceID, tool, enabled in
            self?.setCollaborationTool(
                tool,
                enabled: enabled,
                for: .init(
                    participantID: participantID.rawValue,
                    sourceID: sourceID
                )
            )
        }
        coordinator.onCollaborationControlResetToGlobal = {
            [weak self] sourceID in
            self?.resetCollaborationToolsToGlobal(
                for: .init(
                    participantID: participantID.rawValue,
                    sourceID: sourceID
                )
            )
        }
        remoteWindows[participantID] = coordinator
        audioEnabled[participantID] = true
        audioVolume[participantID] = 1
    }

    private func nativeViewerSource(
        _ published: ClipLiveShareNativeV3PublishedSource,
        media: ServerCoordinatedMeshMediaRuntimeSnapshot?
    ) -> NativeViewerSourceSnapshot {
        let stream = published.descriptor.stream
        return .init(
            sourceInstanceID: published.key.sourceInstanceID.rawValue,
            streamID: stream.id.rawValue,
            applicationName: stream.appName,
            windowName: stream.windowName,
            pixelSize: CGSize(width: stream.width, height: stream.height),
            sourcePointSize: stream.sourcePointSize,
            isFocused: stream.focused,
            isConnected:
                media?.remoteVideoTrackIDs[
                    published.key.ownerParticipantID
                ]?.contains(stream.mediaTrackID) == true,
            stateRevision:
                media?.sourceSnapshots[published.key.ownerParticipantID]?
                    .sourceRevision.rawValue ?? 1
        )
    }

    private func applyCursor(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        media: ServerCoordinatedMeshMediaRuntimeSnapshot?
    ) {
        guard let windows = remoteWindows[participantID] else { return }
        let focused = media?.sourceSnapshots[participantID]?.sources.first {
            $0.descriptor.stream.focused
        }
        let cursor = focused.flatMap { media?.sourceCursors[$0.key] }
        windows.setCursor(
            streamID:
                cursor?.streamID.rawValue
                    ?? focused?.descriptor.stream.id.rawValue ?? "",
            normalizedX: cursor?.position.map { CGFloat($0.x) },
            normalizedY: cursor?.position.map { CGFloat($0.y) }
        )
    }

    private func applyCollaborationOverlays(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        media: ServerCoordinatedMeshMediaRuntimeSnapshot?,
        verified: ClipLiveShareServerRoomV4ClientVerifiedRoomState
    ) {
        guard let windows = remoteWindows[participantID],
              let sources = media?.sourceSnapshots[participantID]?.sources
        else { return }
        for published in sources {
            let key = published.key
            let policy = collaborationPolicy.policy(
                for: collaborationPolicyKey(for: key)
            )
            windows.setCollaborationOverlay(
                overlaySnapshot(
                    media?.collaboration[key],
                    verified: verified
                ),
                sourceInstanceID: key.sourceInstanceID.rawValue
            )
            windows.setCollaborationControlState(
                .init(
                    pointerEnabled: policy.selection.pointerEnabled,
                    pingEnabled: policy.selection.pingEnabled,
                    drawingEnabled: policy.selection.drawingEnabled,
                    isUsingGlobalSettings: policy.isUsingGlobalSettings
                ),
                sourceInstanceID: key.sourceInstanceID.rawValue
            )
            let mode: NativeViewerCollaborationInteractionMode
            if policy.selection.drawingEnabled {
                mode = .draw(collaborationConfiguration.inkColor)
            } else if policy.selection.pointerEnabled
                || policy.selection.pingEnabled {
                mode = .pointer
            } else {
                mode = .disabled
            }
            windows.setCollaborationInteraction(
                mode,
                sourceInstanceID: key.sourceInstanceID.rawValue,
                actions: collaborationActions(for: key)
            )
        }
    }

    private func refreshLocalSourceOverlays() async {
        guard let verified = roomSnapshot?.verifiedRoom else {
            localSourceOverlays.tearDown()
            return
        }
        let activeSources = await localMedia.activeCaptures()
        let activeIDs = Set(activeSources.map {
            $0.published.key.sourceInstanceID.rawValue
        })
        localSourceOverlays.retainSources(activeIDs)
        for active in activeSources {
            let key = active.published.key
            let snapshot = overlaySnapshot(
                roomSnapshot?.media?.collaboration[key],
                verified: verified
            )
            let isVisible =
                !snapshot.pointers.isEmpty
                    || !snapshot.pings.isEmpty
                    || !snapshot.strokes.isEmpty
            let windowSnapshot = Self.quartzWindowSnapshot(
                for: active.capture.source
            )
            let target: LiveShareCollaborationSourceOverlayTarget
            switch active.capture.source {
            case .window:
                // Do not strand an annotation panel on another Space or above
                // a minimized source. It will be restored by the geometry poll
                // when WindowServer reports the source on-screen again.
                guard let visibleTarget =
                    LiveShareCollaborationSourceOverlayTarget.visibleWindow(
                        windowSnapshot
                    )
                else {
                    localSourceOverlays.remove(
                        sourceID: key.sourceInstanceID.rawValue
                    )
                    continue
                }
                target = visibleTarget
            case .fullscreen:
                target = .fullscreen
            }
            guard let frame = MeshLocalSourceOverlayGeometry.appKitFrame(
                for: active.capture.source,
                screenFrames: Self.screenFrames(),
                quartzWindowFrame: windowSnapshot?.frame
            ) else {
                localSourceOverlays.remove(
                    sourceID: key.sourceInstanceID.rawValue
                )
                continue
            }
            localSourceOverlays.update(
                sourceID: key.sourceInstanceID.rawValue,
                sourceFrame: frame,
                target: target,
                snapshot: snapshot,
                isVisible: isVisible
            )
        }
    }

    private func refreshLocalSourceOverlaySnapshots(
        media: ServerCoordinatedMeshMediaRuntimeSnapshot?,
        verified: ClipLiveShareServerRoomV4ClientVerifiedRoomState
    ) {
        let localSources = media?.sourceSnapshots[localParticipantID]?.sources
            ?? []
        for source in localSources {
            let snapshot = overlaySnapshot(
                media?.collaboration[source.key],
                verified: verified
            )
            localSourceOverlays.updateSnapshot(
                sourceID: source.key.sourceInstanceID.rawValue,
                snapshot: snapshot,
                isVisible:
                    !snapshot.pointers.isEmpty
                        || !snapshot.pings.isEmpty
                        || !snapshot.strokes.isEmpty
            )
        }
    }

    private static func quartzWindowSnapshot(
        for source: LiveShareSource
    ) -> LiveShareCollaborationSourceWindowSnapshot? {
        guard case let .window(window) = source,
              let values = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow, .excludeDesktopElements],
                CGWindowID(window.id.rawValue)
              ) as? [[String: Any]],
              let info = values.first
        else { return nil }
        // ScreenCaptureKit's SCWindowID is the session-global WindowServer
        // number accepted by NSWindow's relative-order API. Do not gate a
        // valid capture source on AppKit's optional enumeration: sandbox/Space
        // filtering may omit foreign windows.
        return LiveShareCollaborationSourceWindowSnapshot.resolve(
            windowNumber: CGWindowID(window.id.rawValue),
            information: info
        )
    }

    private static func screenFrames()
        -> [MeshLocalSourceOverlayGeometry.ScreenFrame] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return .init(
                displayID: displayID,
                quartzFrame: CGDisplayBounds(displayID),
                appKitFrame: screen.frame
            )
        }
    }

    private func overlaySnapshot(
        _ state: ClipLiveShareNativeV3CollaborationState?,
        verified: ClipLiveShareServerRoomV4ClientVerifiedRoomState
    ) -> NativeViewerCollaborationOverlaySnapshot {
        guard let state else { return .empty }
        let members = Dictionary(
            uniqueKeysWithValues: verified.members.map {
                ($0.descriptor.participantID, $0)
            }
        )
        return .init(
            pointers: state.pointers.values.map { pointer in
                .init(
                    participantID: pointer.participantID,
                    participantName:
                        members[pointer.participantID]?.descriptor.displayName
                            ?? String(localized: "Participant"),
                    color: collaborationColor(
                        for: pointer.participantID,
                        members: members
                    ),
                    position: pointer.position
                )
            },
            pings: state.pings.enumerated().map { index, ping in
                .init(
                    id: deterministicPingID(
                        participantID: ping.participantID,
                        index: index
                    ),
                    participantID: ping.participantID,
                    color: collaborationColor(
                        for: ping.participantID,
                        members: members
                    ),
                    position: ping.position
                )
            },
            strokes: state.strokes.values.map {
                .init(
                    participantID: $0.participantID,
                    strokeID: $0.strokeID,
                    color: $0.color,
                    points: $0.points
                )
            }
        )
    }

    private func collaborationColor(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        members: [ClipLiveShareNativeV3ParticipantID:
            ClipLiveShareServerRoomV4ClientVerifiedMember]
    ) -> ClipLiveShareNativeV3CollaborationColor {
        let identity = members[participantID]?.descriptor.identity
            .x963Representation ?? participantID.bytes
        return MeshParticipantIdentityColor.collaborationColor(
            forPersistentIdentity: identity
        )
    }

    private func deterministicPingID(
        participantID: ClipLiveShareNativeV3ParticipantID,
        index: Int
    ) -> UUID {
        var bytes = Array(participantID.bytes.prefix(16))
        bytes[15] ^= UInt8(truncatingIfNeeded: index)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Presentation

    private func makePresentationSnapshot() -> MeshRoomViewSnapshot {
        let verified = roomSnapshot?.verifiedRoom
        let creatorID = verified?.members.first(where: {
            $0.handle == verified?.creatorHandle
        })?.descriptor.participantID
        let remotes = verified?.members
            .filter { !$0.isLocal }
            .map(remoteParticipantSnapshot) ?? []
        let outgoingRows: [MeshRoomMediaDiagnosticsSnapshot] =
            remotes.flatMap { remote -> [MeshRoomMediaDiagnosticsSnapshot] in
            guard let id = try? ClipLiveShareNativeV3ParticipantID(
                rawValue: remote.id
            ) else { return [] }
            return mediaDiagnostics(participantID: id, direction: .outgoing)
        }
        let activeLocalIDs = Set(
            roomSnapshot?.media?.sourceSnapshots[localParticipantID]?
                .sources.map { $0.key.sourceInstanceID.rawValue } ?? []
        )
        let outgoing = MeshRoomMediaDiagnosticsSnapshot.publishingSources(
            from: outgoingRows,
            activeSourceIdentifiers: activeLocalIDs
        )
        let invite: MeshRoomInviteSnapshot? =
            roomSnapshot?.invite.flatMap { invite in
            guard let url = try? invite.url else { return nil }
            return MeshRoomInviteSnapshot(
                url: url,
                roomCode: invite.roomCode.rawValue,
                isAvailable: roomSnapshot?.role == .creator
            )
        }
        return MeshRoomViewSnapshot(
            phase: phase,
            roomName: roomName,
            localParticipant: .init(
                id: localParticipantID.rawValue,
                displayName: localDisplayName,
                deviceName: localDeviceName,
                clientKind: .nativeApp
            ),
            creatorParticipantID: creatorID?.rawValue,
            invite: invite,
            accessWordEnabled: accessWord != nil,
            accessWord: isCreator ? accessWord : nil,
            canChangeAccessWord: isCreator,
            askBeforeJoining: askBeforeJoining,
            canChangeAskBeforeJoining: isCreator,
            pendingAdmissions: pendingAdmissions,
            pendingFriendRequests: friendshipSnapshot.pendingRequests,
            localSources: localMedia.activeSources(),
            fullscreen: localPublication.fullscreen,
            canShareFocusedWindow: localPublication.canShareFocusedWindow,
            focusedWindowDescription:
                localPublication.focusedWindowDescription,
            availableWindows: localPublication.availableWindows,
            canAddWindow: localPublication.canAddWindow,
            settings: localPublication.settings,
            remoteParticipants: remotes,
            outgoingDiagnostics: outgoing,
            peerDiagnostics: peerDiagnostics,
            collaboration: .init(
                isLocalPointerVisible:
                    collaborationPolicy.globalSelection.pointerEnabled,
                isLocalPingModeEnabled:
                    collaborationPolicy.globalSelection.pingEnabled,
                isLocalInkEnabled:
                    collaborationPolicy.globalSelection.drawingEnabled,
                activePointerCount: roomSnapshot?.media?.collaboration.values
                    .reduce(0) { $0 + $1.pointers.count } ?? 0,
                annotationStrokeCount:
                    roomSnapshot?.media?.collaboration.values.reduce(0) {
                        $0 + $1.strokes.count
                    } ?? 0,
                canClearAnnotations:
                    roomSnapshot?.media?.collaboration.isEmpty == false
            ),
            statusNotice: statusNotice,
            canLeaveRoom: !isCreator && !isEnding && !phase.isTerminal,
            canEndRoom: isCreator && !isEnding && !phase.isTerminal
        )
    }

    private var isCreator: Bool { roomSnapshot?.role == .creator }

    private var roomName: String {
        guard let roomCode = roomSnapshot?.invite?.roomCode.rawValue else {
            return String(localized: "Live Share")
        }
        return String(localized: "Room \(roomCode)")
    }

    private var pendingAdmissions: [MeshRoomPendingAdmissionSnapshot] {
        guard isCreator else { return [] }
        return roomSnapshot?.room.pendingApprovals.map {
            .init(
                id: $0.candidateHandle.rawValue,
                displayName: $0.displayName,
                deviceName: $0.deviceName
            )
        } ?? []
    }

    private var peerDiagnostics: [MeshRoomPeerDiagnosticsSnapshot] {
        guard let snapshot = roomSnapshot else { return [] }
        return snapshot.verifiedRoom?.members.compactMap { member in
            guard !member.isLocal else { return nil }
            let id = member.descriptor.participantID
            let stats = snapshot.media?.statistics[id]
            return .init(
                participantID: id.rawValue,
                displayName: member.descriptor.displayName,
                route: route(for: member, media: snapshot.media),
                roundTripMilliseconds:
                    stats?.transport.currentRoundTripTimeMilliseconds,
                availableOutgoingBitrateBps:
                    stats?.transport.availableOutgoingBitrateBps,
                bytesSent: stats?.transport.bytesSent ?? 0,
                bytesReceived: stats?.transport.bytesReceived ?? 0,
                packetsLost: stats?.transport.packetsLost ?? 0
            )
        } ?? []
    }

    private func remoteParticipantSnapshot(
        _ member: ClipLiveShareServerRoomV4ClientVerifiedMember
    ) -> MeshRoomRemoteParticipantSnapshot {
        let id = member.descriptor.participantID
        let windows = remoteWindows[id]?.windowSnapshots ?? []
        return .init(
            id: id.rawValue,
            displayName: member.descriptor.displayName,
            deviceName: member.descriptor.deviceName,
            clientKind: member.descriptor.clientKind,
            route: route(for: member, media: roomSnapshot?.media),
            connectedDuration:
                member.connected
                    ? startedAt.map { max(0, now().timeIntervalSince($0)) }
                    : nil,
            sources: windows.map {
                .init(
                    id: $0.source.sourceInstanceID,
                    applicationName: $0.source.applicationName,
                    windowTitle: $0.source.windowName,
                    pixelWidth: Int($0.source.pixelSize.width),
                    pixelHeight: Int($0.source.pixelSize.height),
                    isVisible: $0.isVisible,
                    isFocused: $0.source.isFocused,
                    isConnected: $0.source.isConnected,
                    scaleMode: $0.scaleMode,
                    isFullScreen: $0.isFullScreen
                )
            },
            systemAudioAvailable:
                roomSnapshot?.media?.audioTrackIDs[id] != nil,
            systemAudioEnabled: audioEnabled[id] ?? true,
            volume: audioVolume[id] ?? 1,
            diagnostics: mediaDiagnostics(
                participantID: id,
                direction: .incoming
            ),
            friendshipState:
                friendshipSnapshot.stateByParticipantID[id] ?? .available
        )
    }

    private func friendshipRoomContext(
        _ room: ClipLiveShareServerRoomV4ClientVerifiedRoomState?
    ) -> MeshFriendshipRoomContext? {
        guard let room else { return nil }
        return .init(
            roomID: room.roomID,
            sessionID: room.sessionID,
            localParticipantID: localParticipantID,
            remotes: room.members.compactMap { member in
                guard !member.isLocal,
                      member.descriptor.clientKind == .nativeApp else {
                    return nil
                }
                return .init(
                    participantID: member.descriptor.participantID,
                    identity: member.descriptor.identity,
                    displayName: member.descriptor.displayName,
                    deviceName: member.descriptor.deviceName,
                    isConnected: member.connected
                )
            }
        )
    }

    private func route(
        for member: ClipLiveShareServerRoomV4ClientVerifiedMember,
        media: ServerCoordinatedMeshMediaRuntimeSnapshot?
    ) -> MeshRoomConnectionRoute {
        let link = media?.links.links.first {
            $0.remoteParticipantID == member.descriptor.participantID
        }
        guard member.connected || link?.connectionState == .connected else {
            return .disconnected
        }
        return MeshRoomConnectionPresentationPolicy.route(
            connectionState: link?.connectionState,
            transportRoute: MeshRoomConnectionPresentationPolicy
                .effectiveTransportRoute(
                    statisticsRoute:
                        media?.statistics[member.descriptor.participantID]?
                            .transport.route,
                    retainedRoute: link?.route
                ),
            hasReachedLive: phase.isConnected
        )
    }

    private func recordMediaRates(
        _ media: ServerCoordinatedMeshMediaRuntimeSnapshot?
    ) {
        var samples: [MeshRoomMediaCounterKey: MeshRoomMediaCounterSample] = [:]
        for (participantID, statistics) in media?.statistics ?? [:] {
            for direction in [
                MeshRoomMediaDiagnosticsSnapshot.Direction.outgoing,
                .incoming,
            ] {
                let owner = direction == .outgoing
                    ? localParticipantID : participantID
                let published = Dictionary(
                    uniqueKeysWithValues:
                        (media?.sourceSnapshots[owner]?.sources ?? []).map {
                            ($0.descriptor.stream.mediaTrackID.rawValue, $0)
                        }
                )
                for source in statistics.transport.videoSources {
                    let expected: ClipLiveShareNativeV3MediaStatisticsDirection =
                        direction == .outgoing ? .outgoing : .incoming
                    guard source.direction == expected,
                          let sourceID = published[source.trackIdentifier]?
                            .key.sourceInstanceID.rawValue else { continue }
                    let key = MeshRoomMediaCounterKey(
                        participantID: participantID.rawValue,
                        trackIdentifier: source.trackIdentifier,
                        sourceIdentifier: sourceID,
                        direction: direction
                    )
                    samples[key] = .init(
                        capturedAt: statistics.transport.capturedAt,
                        bytes: source.bytes,
                        frames: source.frames,
                        reportedFramesPerSecond: source.framesPerSecond,
                        packets: source.packets,
                        droppedFrames: source.droppedFrames,
                        queuePressureDrops: source.queuePressureDrops,
                        qpSum: source.qpSum,
                        targetBitrateBps: source.targetBitrateBps,
                        totalEncodeTimeSeconds:
                            source.totalEncodeTimeSeconds,
                        totalPacketSendDelaySeconds:
                            source.totalPacketSendDelaySeconds,
                        qualityLimitationResolutionChanges:
                            source.qualityLimitationResolutionChanges
                    )
                }
            }
        }
        mediaRateEstimator.record(samples)
    }

    private func refreshLocalCaptureDiagnostics() async {
        let diagnostics = await localMedia.captureDiagnostics()
        let next = Dictionary(
            uniqueKeysWithValues: diagnostics.map {
                ($0.sourceInstanceID.rawValue, $0)
            }
        )
        guard next != localCaptureDiagnosticsBySourceID else { return }
        localCaptureDiagnosticsBySourceID = next
        publish()
    }

    private func mediaDiagnostics(
        participantID: ClipLiveShareNativeV3ParticipantID,
        direction: MeshRoomMediaDiagnosticsSnapshot.Direction
    ) -> [MeshRoomMediaDiagnosticsSnapshot] {
        guard let media = roomSnapshot?.media,
              let peer = media.statistics[participantID] else { return [] }
        let owner = direction == .outgoing
            ? localParticipantID : participantID
        let published = Dictionary(
            uniqueKeysWithValues:
                (media.sourceSnapshots[owner]?.sources ?? []).map {
                    ($0.descriptor.stream.mediaTrackID.rawValue, $0)
                }
        )
        let expected: ClipLiveShareNativeV3MediaStatisticsDirection =
            direction == .outgoing ? .outgoing : .incoming
        return peer.transport.videoSources.compactMap { source in
            guard source.direction == expected,
                  let published = published[source.trackIdentifier] else {
                return nil
            }
            let sourceID = published.key.sourceInstanceID.rawValue
            let key = MeshRoomMediaCounterKey(
                participantID: participantID.rawValue,
                trackIdentifier: source.trackIdentifier,
                sourceIdentifier: sourceID,
                direction: direction
            )
            let stream = published.descriptor.stream
            let rate = mediaRateEstimator.rates[key]
            let captureDiagnostics = direction == .outgoing
                ? localCaptureDiagnosticsBySourceID[sourceID] : nil
            let configuredMaximumBitrate = direction == .outgoing
                ? localPublication.settings.quality
                    .maximumBitrateBitsPerSecond : nil
            let advancedSettings = localPublication.settings
                .advancedVideoSettings.settings(
                    for: localPublication.settings.codec.codec
                )
            let configuredMinimumBitrate = configuredMaximumBitrate.flatMap {
                maximum in
                advancedSettings.minimumBitratePercent.map {
                    maximum * $0 / 100
                }
            }
            let recipientName = roomSnapshot?.verifiedRoom?.members.first {
                $0.descriptor.participantID == participantID
            }?.descriptor.displayName
            let title = !stream.windowName.isEmpty
                ? stream.windowName
                : !stream.appName.isEmpty
                    ? stream.appName : String(localized: "Shared Window")
            return MeshRoomMediaDiagnosticsSnapshot(
                id: "\(participantID.rawValue)-\(direction)-\(sourceID)",
                sourceIdentifier: sourceID,
                sourceName: title,
                direction: direction,
                recipientID:
                    direction == .outgoing
                        ? participantID.rawValue : nil,
                recipientName:
                    direction == .outgoing ? recipientName : nil,
                codec: source.codec,
                width: source.width,
                height: source.height,
                framesPerSecond:
                    source.framesPerSecond > 0
                        ? source.framesPerSecond
                        : rate?.framesPerSecond ?? 0,
                bitsPerSecond: rate?.bitsPerSecond ?? 0,
                droppedFrames: source.droppedFrames,
                queuePressureDrops: source.queuePressureDrops,
                queuePressureReason: source.queuePressureReason,
                packetsLost: source.packetsLost,
                processingLatencyMilliseconds:
                    source.processingLatencyMilliseconds,
                targetBitrateBps: rate?.targetBitrateBps,
                averageQuantizer: rate?.averageQuantizer,
                recentEncodeTimeMilliseconds:
                    rate?.averageEncodeTimeMilliseconds,
                recentSendDelayMilliseconds:
                    rate?.averageSendDelayMilliseconds,
                recentDroppedFrames: rate?.droppedFrames ?? 0,
                recentQueuePressureDrops:
                    rate?.queuePressureDrops ?? 0,
                qualityLimitationResolutionChanges:
                    rate?.qualityLimitationResolutionChanges ?? 0,
                sourcePointWidth: stream.sourcePointWidth,
                sourcePointHeight: stream.sourcePointHeight,
                sourcePixelWidth:
                    captureDiagnostics?.capture.sourcePixelWidth,
                sourcePixelHeight:
                    captureDiagnostics?.capture.sourcePixelHeight,
                captureWidth: captureDiagnostics?.capture.video.width,
                captureHeight: captureDiagnostics?.capture.video.height,
                capturePixelFormat: captureDiagnostics.map {
                    Self.capturePixelFormatDescription(
                        $0.capture.video.pixelFormat
                    )
                },
                manifestWidth: stream.width,
                manifestHeight: stream.height,
                configuredMinimumBitratePerRecipientBps:
                    configuredMinimumBitrate,
                configuredMaximumBitratePerRecipientBps:
                    configuredMaximumBitrate,
                bytesSent: source.bytes,
                captureDeliveredFrames:
                    captureDiagnostics?.deliveredFrames ?? 0,
                captureBackpressureDrops:
                    captureDiagnostics?.backpressureDrops ?? 0,
                qualityLimitationReasons:
                    [source.queuePressureReason].compactMap { $0 }
            )
        }
    }

    private static func capturePixelFormatDescription(
        _ pixelFormat: CaptureVideoPixelFormat
    ) -> String {
        switch pixelFormat {
        case .bgra:
            "BGRA"
        case .rec709BGRA:
            "BGRA · Rec.709"
        case .rec709VideoRange:
            "NV12 · Rec.709 video range"
        case .rec709FullRange:
            "NV12 · Rec.709 full range"
        }
    }

    private func pairNotice(
        snapshot: ServerCoordinatedMeshRoomSessionSnapshot
    ) -> MeshRoomStatusNoticeSnapshot? {
        let members = Set(
            snapshot.verifiedRoom?.members.map(\.descriptor.participantID) ?? []
        )
        pairFailures = pairFailures.filter { members.contains($0.key) }
        guard let failure = pairFailures.sorted(by: {
            $0.key.rawValue < $1.key.rawValue
        }).first else { return nil }
        let name = snapshot.verifiedRoom?.members.first {
            $0.descriptor.participantID == failure.key
        }?.descriptor.displayName ?? String(localized: "Participant")
        return .init(
            title: String(localized: "\(name) is reconnecting"),
            message: failure.value,
            severity: .warning
        )
    }

    private func publish() {
        if presentationModel != nil {
            presentationModel.update(makePresentationSnapshot())
        }
    }

    // MARK: - Actions

    private func makePresentationActions() -> MeshRoomPresentationActions {
        .init(
            copyText: { value in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            },
            setAccessWordEnabled: { [weak self] in self?.setAccessWordEnabled($0) },
            setAskBeforeJoining: { [weak self] in self?.setAskBeforeJoining($0) },
            replaceAccessWord: { [weak self] in self?.replaceAccessWord() },
            changeInvite: { [weak self] in self?.rotateInvite() },
            approveAdmission: { [weak self] in self?.approveAdmission($0) },
            denyAdmission: { [weak self] in self?.denyAdmission($0) },
            removeParticipant: { [weak self] in self?.removeParticipant($0) },
            addFriend: { [weak self] rawID in
                guard let self,
                      let participantID = try?
                        ClipLiveShareNativeV3ParticipantID(rawValue: rawID)
                else { return }
                Task { @MainActor in
                    await self.friendshipController?.addFriend(
                        participantID: participantID
                    )
                }
            },
            allowFriendRequest: { [weak self] requestID in
                guard let self else { return }
                Task { @MainActor in
                    await self.friendshipController?.allow(
                        requestID: requestID
                    )
                }
            },
            denyFriendRequest: { [weak self] requestID in
                guard let self else { return }
                Task { @MainActor in
                    await self.friendshipController?.deny(
                        requestID: requestID
                    )
                }
            },
            retryFriendship: { [weak self] rawID in
                guard let self,
                      let participantID = try?
                        ClipLiveShareNativeV3ParticipantID(rawValue: rawID)
                else { return }
                Task { @MainActor in
                    await self.friendshipController?.retry(
                        participantID: participantID
                    )
                }
            },
            shareFocusedWindow: { [weak self] in self?.localMedia.shareFocusedWindow() },
            shareWindow: { [weak self] in self?.localMedia.shareWindow($0) },
            stopLocalSource: { [weak self] rawID in
                guard let id = try? ClipLiveShareSourceInstanceID(rawValue: rawID)
                else { return }
                self?.localMedia.stopSource(id)
            },
            setFullscreenEnabled: { [weak self] in self?.localMedia.setFullscreenEnabled($0) },
            setQuality: { [weak self] in self?.updateSettings(quality: $0) },
            setFrameRate: { [weak self] in self?.updateSettings(frameRate: $0) },
            setCodec: { [weak self] in self?.updateSettings(codec: $0) },
            setColorMode: { [weak self] in self?.updateSettings(colorMode: $0) },
            setSystemAudioEnabled: { [weak self] in self?.updateSettings(systemAudioEnabled: $0) },
            setExcludedAudioApplicationIDs: { [weak self] in
                self?.updateSettings(excludedAudioApplicationIDs: $0)
            },
            setCursorUpdatesMatchFrameRate: { [weak self] in
                self?.updateSettings(cursorUpdatesMatchFrameRate: $0)
            },
            setPrioritizeFocusedWindow: { [weak self] in
                self?.updateSettings(prioritizeFocusedWindow: $0)
            },
            setMode: { [weak self] in self?.updateSettings(mode: $0) },
            setAdvancedVideoSettings: { [weak self] codec, settings in
                guard let self else { return }
                var advanced = localPublication.settings
                    .advancedVideoSettings
                advanced[codec] = settings.normalized(for: codec)
                updateSettings(
                    advancedVideoSettings: advanced
                )
            },
            setAutoShareEnabled: { [weak self] in
                self?.updateSettings(autoShareFocusedWindows: $0)
            },
            stopLocalMedia: { [weak self] in self?.localMedia.stopAllMedia() },
            setParticipantAudioEnabled: { [weak self] in
                self?.setParticipantAudio($0, enabled: $1)
            },
            setParticipantVolume: { [weak self] in
                self?.setParticipantVolume($0, volume: $1)
            },
            setRemoteSourceScaleMode: { [weak self] key, mode in
                self?.participantWindows(key)?.setScaleMode(
                    mode,
                    sourceInstanceID: key.sourceID
                )
                self?.publish()
            },
            setRemoteSourceVisible: { [weak self] key, visible in
                self?.participantWindows(key)?.setSourceVisible(
                    visible,
                    sourceInstanceID: key.sourceID
                )
                self?.publish()
            },
            toggleRemoteSourceFullScreen: { [weak self] key in
                self?.participantWindows(key)?.toggleFullScreen(
                    sourceInstanceID: key.sourceID
                )
                self?.publish()
            },
            bringRemoteSourceToFront: { [weak self] key in
                self?.participantWindows(key)?.bringToFront(
                    sourceInstanceID: key.sourceID
                )
            },
            bringParticipantToFront: { [weak self] rawID in
                guard let id = try? ClipLiveShareNativeV3ParticipantID(
                    rawValue: rawID
                ) else { return }
                self?.remoteWindows[id]?.bringAllToFront()
            },
            bringAllRemoteWindowsToFront: { [weak self] in
                self?.remoteWindows.values.forEach { $0.bringAllToFront() }
            },
            setLocalPointerVisible: { [weak self] in
                self?.setGlobalCollaborationTool(
                    .pointer,
                    enabled: $0
                )
            },
            setLocalPingModeEnabled: { [weak self] in
                self?.setGlobalCollaborationTool(.ping, enabled: $0)
            },
            setLocalInkEnabled: { [weak self] in
                self?.setGlobalCollaborationTool(.drawing, enabled: $0)
            },
            clearAnnotations: { [weak self] in self?.clearAnnotations() },
            retry: { [weak self] in self?.start() },
            leaveRoom: { [weak self] in self?.leaveRoom() },
            endRoomForEveryone: { [weak self] in self?.endRoomForEveryone() }
        )
    }

    private func setAccessWordEnabled(_ enabled: Bool) {
        guard isCreator else { return }
        accessWord = enabled
            ? accessWord ?? Self.makeAccessWord()
            : nil
        persistAdmissionPreferences(accessWord != nil, askBeforeJoining)
        updateAdmissionPolicy()
    }

    private func setAskBeforeJoining(_ enabled: Bool) {
        guard isCreator else { return }
        askBeforeJoining = enabled
        persistAdmissionPreferences(accessWord != nil, askBeforeJoining)
        updateAdmissionPolicy()
    }

    private func replaceAccessWord() {
        guard isCreator, accessWord != nil else { return }
        accessWord = Self.makeAccessWord()
        updateAdmissionPolicy()
    }

    private func updateAdmissionPolicy() {
        let accessWord = accessWord
        let ask = askBeforeJoining
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let policy = if let accessWord {
                    try ClipLiveShareServerRoomV4AdmissionPolicy
                        .requiringAccessWord(
                            accessWord,
                            askBeforeJoining: ask
                        )
                } else {
                    ClipLiveShareServerRoomV4AdmissionPolicy.open(
                        askBeforeJoining: ask
                    )
                }
                try await session.setAdmissionPolicy(policy)
                controlOperationDidSucceed(.admissionPolicy)
            } catch {
                controlOperationDidFail(
                    .admissionPolicy,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func rotateInvite() {
        guard isCreator else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await session.rotateInvite()
                controlOperationDidSucceed(.inviteRotation)
            } catch {
                controlOperationDidFail(
                    .inviteRotation,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func approveAdmission(_ rawID: String) {
        guard isCreator,
              let id = try? ClipLiveShareServerRoomV4CandidateHandle(
                rawValue: rawID
              ) else { return }
        performControlOperation(.admissionDecision) { [session] in
            try await session.approve(id)
        }
    }

    private func denyAdmission(_ rawID: String) {
        guard isCreator,
              let id = try? ClipLiveShareServerRoomV4CandidateHandle(
                rawValue: rawID
              ) else { return }
        performControlOperation(.admissionDecision) { [session] in
            try await session.deny(id)
        }
    }

    private func removeParticipant(_ rawID: String) {
        guard isCreator,
              let id = try? ClipLiveShareNativeV3ParticipantID(rawValue: rawID),
              let handle = roomSnapshot?.verifiedRoom?.members.first(where: {
                  $0.descriptor.participantID == id && !$0.isLocal
              })?.handle else { return }
        performControlOperation(.participantRemoval) { [session] in
            try await session.removeMember(handle)
        }
    }

    private func setParticipantAudio(_ rawID: String, enabled: Bool) {
        guard let id = try? ClipLiveShareNativeV3ParticipantID(rawValue: rawID)
        else { return }
        audioEnabled[id] = enabled
        performControlOperation(.remoteAudio) { [session] in
            try await session.setRemoteAudioPlayback(enabled, id)
        }
        publish()
    }

    private func setParticipantVolume(_ rawID: String, volume: Double) {
        guard let id = try? ClipLiveShareNativeV3ParticipantID(rawValue: rawID)
        else { return }
        let value = min(max(volume, 0), 1)
        audioVolume[id] = value
        performControlOperation(.remoteAudio) { [session] in
            try await session.setRemoteAudioVolume(value, id)
        }
        publish()
    }

    private func performControlOperation(
        _ operation: MeshParticipantControlOperation,
        action: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await action()
                controlOperationDidSucceed(operation)
            } catch {
                controlOperationDidFail(
                    operation,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func participantWindows(
        _ key: MeshRoomSourceKey
    ) -> NativeViewerWindowCoordinator? {
        guard let id = try? ClipLiveShareNativeV3ParticipantID(
            rawValue: key.participantID
        ) else { return nil }
        return remoteWindows[id]
    }

    private func setGlobalCollaborationTool(
        _ tool: MeshRoomCollaborationTool,
        enabled: Bool
    ) {
        let change = collaborationPolicy.setGlobal(tool, enabled: enabled)
        sendHiddenPointers(for: change.pointerHiddenSources)
        refreshCollaborationInteractions()
    }

    private func setCollaborationTool(
        _ tool: NativeViewerCollaborationControlTool,
        enabled: Bool,
        for source: MeshRoomSourceKey
    ) {
        let policyTool: MeshRoomCollaborationTool
        switch tool {
        case .pointer:
            policyTool = .pointer
        case .ping:
            policyTool = .ping
        case .drawing:
            policyTool = .drawing
        }
        let change = collaborationPolicy.set(
            policyTool,
            enabled: enabled,
            for: source
        )
        sendHiddenPointers(for: change.pointerHiddenSources)
        refreshCollaborationInteractions()
    }

    private func resetCollaborationToolsToGlobal(
        for source: MeshRoomSourceKey
    ) {
        let change = collaborationPolicy.useGlobalSettings(for: source)
        sendHiddenPointers(for: change.pointerHiddenSources)
        refreshCollaborationInteractions()
    }

    private func collaborationSelection(
        for source: ClipLiveShareNativeV3SourceKey
    ) -> MeshRoomCollaborationToolSelection {
        collaborationPolicy.policy(
            for: collaborationPolicyKey(for: source)
        ).selection
    }

    private func collaborationPolicyKey(
        for source: ClipLiveShareNativeV3SourceKey
    ) -> MeshRoomSourceKey {
        .init(
            participantID: source.ownerParticipantID.rawValue,
            sourceID: source.sourceInstanceID.rawValue
        )
    }

    private func nativeSourceKey(
        for source: MeshRoomSourceKey
    ) -> ClipLiveShareNativeV3SourceKey? {
        guard let participantID = try? ClipLiveShareNativeV3ParticipantID(
            rawValue: source.participantID
        ),
              let sourceID = try? ClipLiveShareSourceInstanceID(
                rawValue: source.sourceID
              )
        else { return nil }
        return .init(
            ownerParticipantID: participantID,
            sourceInstanceID: sourceID
        )
    }

    private func sendHiddenPointers(
        for sources: Set<MeshRoomSourceKey>
    ) {
        for source in sources {
            guard let key = nativeSourceKey(for: source) else { continue }
            queueCollaborationPointer(
                nil,
                reason: .modeDisabled,
                sourceKey: key
            )
        }
    }

    private func pruneCollaborationBookkeeping(
        for removedSources: Set<MeshRoomSourceKey>
    ) {
        guard !removedSources.isEmpty else { return }
        for source in removedSources {
            guard let key = nativeSourceKey(for: source) else { continue }
            collaborationPointerCoalescers.removeValue(forKey: key)?.cancel()
            collaborationPointerSequenceBySource.removeValue(forKey: key)
            collaborationSequenceBySource.removeValue(forKey: key)
        }
    }

    private func clearAnnotations() {
        for key in roomSnapshot?.media?.collaboration.keys.map({ $0 }) ?? [] {
            sendCollaboration(key) { context in
                .clear(try .init(
                    context: context,
                    clearEpoch: UInt64(
                        self.now().timeIntervalSince1970 * 1_000
                    ),
                    scope: key.ownerParticipantID == self.localParticipantID
                        ? .source : .participant
                ))
            }
        }
    }

    private func collaborationActions(
        for sourceKey: ClipLiveShareNativeV3SourceKey
    ) -> NativeViewerCollaborationActions {
        .init(
            pointerChanged: { [weak self] position, reason in
                guard let self,
                      collaborationSelection(for: sourceKey).pointerEnabled
                else { return }
                queueCollaborationPointer(
                    position,
                    reason: reason,
                    sourceKey: sourceKey
                )
            },
            ping: { [weak self] position in
                guard let self,
                      collaborationSelection(for: sourceKey).pingEnabled
                else { return }
                sendCollaboration(sourceKey) { context in
                    try self.collaborationConfiguration.ping(
                        context: context,
                        position: position
                    )
                }
            },
            strokeBegan: { [weak self] strokeID, point in
                guard let self,
                      collaborationSelection(for: sourceKey).drawingEnabled
                else { return }
                sendCollaboration(sourceKey) { context in
                    try self.collaborationConfiguration.strokeBegin(
                        context: context,
                        strokeID: strokeID,
                        point: point
                    )
                }
            },
            strokePoints: { [weak self] strokeID, points in
                guard let self,
                      collaborationSelection(for: sourceKey).drawingEnabled
                else { return }
                sendCollaboration(sourceKey) { context in
                    .strokePoints(try .init(
                        context: context,
                        strokeID: strokeID,
                        points: points
                    ))
                }
            },
            strokeEnded: { [weak self] strokeID in
                guard let self,
                      collaborationSelection(for: sourceKey).drawingEnabled
                else { return }
                sendCollaboration(sourceKey) { context in
                    .strokeEnd(.init(context: context, strokeID: strokeID))
                }
            }
        )
    }

    private func sendCollaboration(
        _ sourceKey: ClipLiveShareNativeV3SourceKey,
        makeEvent: @escaping (
            ClipLiveShareNativeV3CollaborationContext
        ) throws -> ClipLiveShareNativeV3CollaborationEvent
    ) {
        guard let sessionID = roomSnapshot?.verifiedRoom?.sessionID else {
            return
        }
        do {
            let sequence = collaborationSequenceBySource[sourceKey, default: 0]
                &+ 1
            collaborationSequenceBySource[sourceKey] = sequence
            let context = try ClipLiveShareNativeV3CollaborationContext(
                sessionID: sessionID,
                participantID: localParticipantID,
                sourceKey: sourceKey,
                sequence: sequence,
                sentAt: try .init(date: now())
            )
            let event = try makeEvent(context)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await session.broadcastCollaboration(event)
                    controlOperationDidSucceed(.collaboration)
                } catch {
                    controlOperationDidFail(
                        .collaboration,
                        message: error.localizedDescription
                    )
                }
            }
        } catch {
            controlOperationDidFail(
                .collaboration,
                message: error.localizedDescription
            )
        }
    }

    private func queueCollaborationPointer(
        _ position: ClipLiveShareNativeV3NormalizedPoint?,
        reason: NativeViewerCollaborationPointerUpdateReason,
        sourceKey: ClipLiveShareNativeV3SourceKey
    ) {
        let coalescer: NativeViewerCollaborationPointerCoalescer
        if let current = collaborationPointerCoalescers[sourceKey] {
            coalescer = current
        } else {
            coalescer = NativeViewerCollaborationPointerCoalescer {
                [weak self] latestPosition in
                self?.sendPointerCollaboration(
                    latestPosition,
                    sourceKey: sourceKey
                )
            }
            collaborationPointerCoalescers[sourceKey] = coalescer
        }
        coalescer.submit(position, reason: reason)
    }

    private func sendPointerCollaboration(
        _ position: ClipLiveShareNativeV3NormalizedPoint?,
        sourceKey: ClipLiveShareNativeV3SourceKey
    ) {
        guard let sessionID = roomSnapshot?.verifiedRoom?.sessionID else {
            return
        }
        do {
            let sequence = collaborationPointerSequenceBySource[
                sourceKey,
                default: 0
            ] &+ 1
            collaborationPointerSequenceBySource[sourceKey] = sequence
            let context = try ClipLiveShareNativeV3CollaborationContext(
                sessionID: sessionID,
                participantID: localParticipantID,
                sourceKey: sourceKey,
                sequence: sequence,
                sentAt: try .init(date: now())
            )
            let event = ClipLiveShareNativeV3CollaborationEvent.pointer(
                .init(context: context, position: position)
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A replaceable pointer sample dropped under DataChannel
                // pressure is expected and must not raise a room warning.
                try? await self.session.broadcastCollaboration(event)
            }
        } catch {
            controlOperationDidFail(
                .collaboration,
                message: error.localizedDescription
            )
        }
    }

    private func refreshCollaborationInteractions() {
        guard let snapshot = roomSnapshot,
              let verified = snapshot.verifiedRoom else {
            publish()
            return
        }
        for participantID in remoteWindows.keys {
            applyCollaborationOverlays(
                for: participantID,
                media: snapshot.media,
                verified: verified
            )
        }
        publish()
    }

    private func publishNativeCursor() async -> Int {
        guard let snapshot = localMedia.cursorSnapshot(),
              let sessionID = roomSnapshot?.verifiedRoom?.sessionID else {
            return 30
        }
        let key = ClipLiveShareNativeV3SourceKey(
            ownerParticipantID: localParticipantID,
            sourceInstanceID: snapshot.sourceInstanceID
        )
        let sequence = nativeCursorSequenceBySource[key, default: 0] &+ 1
        nativeCursorSequenceBySource[key] = sequence
        let normalized = LiveShareCursorNormalization.position(
            appKitCursor: NSEvent.mouseLocation,
            appKitWindowFrame: snapshot.appKitFrame
        )
        let position = normalized.isInView
            ? try? ClipLiveShareNativeV3NormalizedPoint(
                x: normalized.xPercent / 100,
                y: normalized.yPercent / 100
            )
            : nil
        do {
            let cursor = try ClipLiveShareNativeV3SourceCursor(
                sessionID: sessionID,
                participantID: localParticipantID,
                sourceKey: key,
                streamID: snapshot.streamID,
                sequence: sequence,
                position: position
            )
            try await session.broadcastSourceCursor(cursor)
        } catch {
            Self.logger.debug(
                "Could not publish v4 cursor: \(error.localizedDescription, privacy: .public)"
            )
        }
        return snapshot.updatesPerSecond
    }

    private func updateSettings(
        quality: LiveShareQualityPreset? = nil,
        frameRate: LiveShareFrameRate? = nil,
        codec: LiveShareVideoCodec? = nil,
        colorMode: LiveShareColorMode? = nil,
        systemAudioEnabled: Bool? = nil,
        excludedAudioApplicationIDs: Set<String>? = nil,
        cursorUpdatesMatchFrameRate: Bool? = nil,
        prioritizeFocusedWindow: Bool? = nil,
        mode: LiveShareEncodingMode? = nil,
        advancedVideoSettings: LiveShareAdvancedVideoSettings? = nil,
        autoShareFocusedWindows: Bool? = nil
    ) {
        let current = localPublication.settings
        let next = LiveShareSettingsViewSnapshot(
            quality: quality ?? current.quality,
            frameRate: frameRate ?? current.frameRate,
            codec: codec.map {
                .init(codec: $0, acceleration: current.codec.acceleration)
            } ?? current.codec,
            colorMode: colorMode ?? current.colorMode,
            systemAudioEnabled:
                systemAudioEnabled ?? current.systemAudioEnabled,
            audioExclusionApplications:
                current.audioExclusionApplications,
            excludedAudioApplicationIDs:
                excludedAudioApplicationIDs
                    ?? current.excludedAudioApplicationIDs,
            cursorUpdatesMatchFrameRate:
                cursorUpdatesMatchFrameRate
                    ?? current.cursorUpdatesMatchFrameRate,
            prioritizeFocusedWindow:
                prioritizeFocusedWindow
                    ?? current.prioritizeFocusedWindow,
            mode: mode ?? current.mode,
            advancedVideoSettings:
                advancedVideoSettings ?? current.advancedVideoSettings,
            autoShareFocusedWindows:
                autoShareFocusedWindows ?? current.autoShareFocusedWindows,
            canChangeQuality: current.canChangeQuality,
            canChangeFrameRate: current.canChangeFrameRate,
            availableFrameRates: current.availableFrameRates,
            canChangeCodec: current.canChangeCodec,
            canChangeColorMode: current.canChangeColorMode,
            canChangeSystemAudio: current.canChangeSystemAudio,
            canChangeAudioExclusions: current.canChangeAudioExclusions,
            canChangeCursorUpdateRate: current.canChangeCursorUpdateRate,
            canChangePrioritizeFocusedWindow:
                current.canChangePrioritizeFocusedWindow,
            canChangeMode: current.canChangeMode,
            canChangeAutoShare: current.canChangeAutoShare
        )
        localPublication.settings = next
        localMedia.updateSettings(next)
        publish()
    }

    private func handleCaptureFailure(_ failure: MeshParticipantCaptureFailure) {
        switch failure {
        case let .source(id, message):
            localMedia.stopSource(id)
            localPublicationDidFail(message)
        case let .systemAudio(message):
            localPublicationDidFail(message)
        }
    }

    private static func normalizedAccessWord(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased().nonEmpty
    }

    private static func makeAccessWord() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(8)).uppercased()
    }

    private static func presentLastRemoteWindowCloseConfirmation() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Stay connected to remote audio?")
        alert.informativeText = String(
            localized:
                "This is the last shared video window. You can stay connected and keep listening, or leave the room."
        )
        alert.addButton(withTitle: String(localized: "Stay Connected"))
        alert.addButton(withTitle: String(localized: "Leave Room"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}

private extension ServerCoordinatedMeshRoomSessionPhase {
    var isTerminal: Bool {
        if case .ended = self { true } else { false }
    }
}

private extension MeshRoomPhase {
    var terminalMessage: String? {
        switch self {
        case let .ended(message): message
        case let .failed(message): message
        default: nil
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
