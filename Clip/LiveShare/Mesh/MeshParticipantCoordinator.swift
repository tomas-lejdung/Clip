import AppKit
import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import OSLog

enum MeshParticipantMenuBarStatus: Equatable, Sendable {
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

enum MeshRemoteWindowClosePolicy {
    static func shouldConfirmLeave(
        visibleRemoteWindowCount: Int,
        hasRemoteAudio: Bool
    ) -> Bool {
        visibleRemoteWindowCount == 1 && hasRemoteAudio
    }
}

enum MeshParticipantCoordinatorError: Error, LocalizedError {
    case incompleteTransportInjection

    var errorDescription: String? {
        switch self {
        case .incompleteTransportInjection:
            "Native-v3 activation must provide both the shared media factory and peer-link manager."
        }
    }
}

struct MeshParticipantLocalPresentationState: Sendable {
    var roomName: String
    var invite: MeshRoomInviteSnapshot?
    var accessWordEnabled = false
    var accessWord: String?
    var canChangeAccessWord = true
    var pendingAdmissions: [MeshRoomPendingAdmissionSnapshot] = []
    var fullscreen = LiveShareFullscreenViewSnapshot(
        isOn: false,
        displayName: String(localized: "Main Display")
    )
    var canShareFocusedWindow = false
    var focusedWindowDescription: String?
    var availableWindows: [LiveShareAvailableWindowViewSnapshot] = []
    var canAddWindow = false
    var settings = LiveShareSettingsViewSnapshot()

    init(
        roomName: String = String(localized: "Live Share"),
        invite: MeshRoomInviteSnapshot? = nil
    ) {
        self.roomName = roomName
        self.invite = invite
    }
}

@MainActor
struct MeshParticipantCoordinatorActions {
    var requestShareFocusedWindow: () -> Void
    var requestShareWindow: (String) -> Void
    var requestFullscreen: (Bool) -> Void
    var updateSettings: (LiveShareSettingsViewSnapshot) -> Void
    var setAccessWordEnabled: (Bool) -> Void
    var replaceAccessWord: () -> Void
    var requestNewInvite: () -> Void
    var approveAdmission: (String) -> Void
    var denyAdmission: (String) -> Void
    var removeParticipant: (String) -> Void
    /// Keeps the direct-v3 rendezvous owner synchronized with every committed
    /// membership. A newly elected local leader must allocate a fresh invite;
    /// ordinary membership revisions update the admission baseline without
    /// rotating the current route.
    var committedContextChanged: (
        MeshParticipantBootstrapLaunchContext,
        MeshParticipantBootstrapRoomAvailability,
        Bool
    ) async -> Void
    var receiveBootstrapForward: (
        ClipLiveShareNativeV3BootstrapForward,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Bool
    var receiveBootstrapMembership: (
        ClipLiveShareSignedNativeV3MembershipSnapshot,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Bool
    var handleRoomControl: (
        ClipLiveShareNativeV3ControlEnvelope,
        ClipLiveShareNativeV3ParticipantID
    ) -> Void

    init(
        requestShareFocusedWindow: @escaping () -> Void = {},
        requestShareWindow: @escaping (String) -> Void = { _ in },
        requestFullscreen: @escaping (Bool) -> Void = { _ in },
        updateSettings: @escaping (LiveShareSettingsViewSnapshot) -> Void = {
            _ in
        },
        setAccessWordEnabled: @escaping (Bool) -> Void = { _ in },
        replaceAccessWord: @escaping () -> Void = {},
        requestNewInvite: @escaping () -> Void = {},
        approveAdmission: @escaping (String) -> Void = { _ in },
        denyAdmission: @escaping (String) -> Void = { _ in },
        removeParticipant: @escaping (String) -> Void = { _ in },
        committedContextChanged: @escaping (
            MeshParticipantBootstrapLaunchContext,
            MeshParticipantBootstrapRoomAvailability,
            Bool
        ) async -> Void = { _, _, _ in },
        receiveBootstrapForward: @escaping (
            ClipLiveShareNativeV3BootstrapForward,
            ClipLiveShareNativeV3ParticipantID
        ) async throws -> Bool = { _, _ in false },
        receiveBootstrapMembership: @escaping (
            ClipLiveShareSignedNativeV3MembershipSnapshot,
            ClipLiveShareNativeV3ParticipantID
        ) async throws -> Bool = { _, _ in false },
        handleRoomControl: @escaping (
            ClipLiveShareNativeV3ControlEnvelope,
            ClipLiveShareNativeV3ParticipantID
        ) -> Void = { _, _ in }
    ) {
        self.requestShareFocusedWindow = requestShareFocusedWindow
        self.requestShareWindow = requestShareWindow
        self.requestFullscreen = requestFullscreen
        self.updateSettings = updateSettings
        self.setAccessWordEnabled = setAccessWordEnabled
        self.replaceAccessWord = replaceAccessWord
        self.requestNewInvite = requestNewInvite
        self.approveAdmission = approveAdmission
        self.denyAdmission = denyAdmission
        self.removeParticipant = removeParticipant
        self.committedContextChanged = committedContextChanged
        self.receiveBootstrapForward = receiveBootstrapForward
        self.receiveBootstrapMembership = receiveBootstrapMembership
        self.handleRoomControl = handleRoomControl
    }
}

/// Main-actor owner for one symmetric native-v3 participant.
///
/// There is intentionally no creator/viewer subclass. Every participant owns
/// the same local capture publisher, direct-peer runtime, participant-scoped
/// remote presentations and common popover model. Room authority affects only
/// admission/membership actions exposed by the snapshot.
@MainActor
final class MeshParticipantCoordinator {
    private struct LeadershipTransitionKey: Hashable {
        let term: ClipLiveShareNativeV3LeadershipTerm
        let newLeaderParticipantID:
            ClipLiveShareNativeV3ParticipantID
    }

    private struct LeadershipTransitionFragments {
        var certificate:
            ClipLiveShareNativeV3LeadershipCertificate?
        var membership:
            ClipLiveShareSignedNativeV3MembershipSnapshot?
        var authorityChain:
            ClipLiveShareNativeV3RoomAuthorityChain?
    }

    nonisolated private static let logger = Logger(
        subsystem: ApplicationDirectories.bundleIdentifier,
        category: "live-share-mesh-participant"
    )

    let localParticipantID: ClipLiveShareNativeV3ParticipantID
    let mediaFactory: ClipLiveShareNativeV3WebRTCTransportFactory
    let peerLinkManager: ClipLiveShareNativeV3MeshPeerLinkManager
    let runtime: MeshParticipantRuntime
    let capturePublisher: MeshParticipantCapturePublisher

    private let actions: MeshParticipantCoordinatorActions
    private let localIdentitySigner: any ClipLiveShareIdentitySigner
    private let acceptanceReporter: NativeV3MeshAcceptanceReporter?
    private let onSessionEnded: () -> Void
    private let onMenuBarStatusChanged: (MeshParticipantMenuBarStatus) -> Void
    private let confirmLeaveAfterLastRemoteWindowCloses: () -> Bool
    private let now: @Sendable () -> Date
    private let membershipRefreshSleeper: any ClipLiveShareReconnectSleeper
    private let membershipRefreshLeadTime: TimeInterval
    private let leaderLossStabilityDuration: Duration
    private let initialLocalSettings: LiveShareSettings
    private let persistLocalSettings: (LiveShareSettings) -> Void
    private let localCaptureDiscovery: any CaptureContentDiscovering
    private let maximumLocalSources: Int
    private var localPresentation: MeshParticipantLocalPresentationState
    private var phase: MeshRoomPhase = .connecting
    private var runtimeSnapshot: MeshParticipantRuntimeSnapshot?
    private var lifecycle: ClipLiveShareNativeV3RoomLifecycleCoordinator
    private var verifiedPeerTransportNonces:
        [ClipLiveShareNativeV3ParticipantID:
            ClipLiveShareNativeV3TransportNonce]
    private var bootstrapAdmissionDigests:
        [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeDigest]
    /// Leadership commit fragments may arrive in any order. Keep them scoped
    /// to the exact next term and certified successor so traffic from another
    /// participant cannot overwrite or clear an otherwise valid transition.
    private var pendingLeadershipTransitions:
        [LeadershipTransitionKey: LeadershipTransitionFragments] = [:]
    private var authoritySynchronizedPeers:
        Set<ClipLiveShareNativeV3ParticipantID> = []
    private var authorityAnnouncementPeers:
        Set<ClipLiveShareNativeV3ParticipantID> = []
    private var isLeavePending = false
    private var hasReachedLive = false
    private var leaderLossTask: Task<Void, Never>?
    private var membershipRefreshTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var eventTaskGeneration: UUID?
    private var hasStartedRuntime = false
    private var statisticsTask: Task<Void, Never>?
    private var captureFailureTask: Task<Void, Never>?
    private var collaborationExpiryTask: Task<Void, Never>?
    private var nativeCursorTask: Task<Void, Never>?
    private var mediaRateEstimator = MeshRoomMediaRateEstimator()
    private var localOverlayTask: Task<Void, Never>?
    private var isEnding = false
    private var hasCompletedShutdown = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var didNotifyEnd = false
    private var startedAt = Date()

    private var remotePresentations:
        [ClipLiveShareNativeV3ParticipantID:
            RemoteParticipantPresentation<WebRTCRemoteVideoStream>] = [:]
    private var remoteWindows:
        [ClipLiveShareNativeV3ParticipantID: NativeViewerWindowCoordinator] = [:]
    private var audioEnabled:
        [ClipLiveShareNativeV3ParticipantID: Bool] = [:]
    private var audioVolume:
        [ClipLiveShareNativeV3ParticipantID: Double] = [:]

    private var localPointerVisible = false
    private var localPingModeEnabled = false
    private var localInkEnabled = false
    private var localStatusNotice: MeshRoomStatusNoticeSnapshot?
    private var collaborationSequenceBySource:
        [ClipLiveShareNativeV3SourceKey: UInt64] = [:]
    private var nativeCursorSequenceBySource:
        [ClipLiveShareNativeV3SourceKey: UInt64] = [:]
    private let collaborationConfiguration:
        MeshParticipantCollaborationConfiguration
    private let localSourceOverlays =
        LiveShareCollaborationSourceOverlayCoordinator()
    private lazy var focusedWindowControl =
        MeshFocusedWindowControlCoordinator(
            actions: .init(
                share: { [weak self] in
                    self?.localPublicationController.shareFocusedWindow()
                },
                stop: { [weak self] in
                    guard
                        let instanceID = self?
                            .localPublicationController
                            .focusedWindowControlSnapshot?
                            .sourceInstanceID
                    else { return }
                    self?.localPublicationController.stopSource(instanceID)
                }
            )
        )
    private lazy var localStatusHUD = MeshLocalStatusHUDCoordinator(
        actions: .init(
            setFullscreenEnabled: { [weak self] in
                self?.localPublicationController.setFullscreenEnabled($0)
            },
            stopAllMedia: { [weak self] in
                self?.localPublicationController.stopAllMedia()
            }
        )
    )

    private lazy var localPublicationController =
        makeLocalPublicationController()

    private func makeLocalPublicationController()
        -> MeshParticipantLocalPublicationController
    {
        MeshParticipantLocalPublicationController(
            settings: initialLocalSettings,
            discovery: localCaptureDiscovery,
            maximumActiveSources: maximumLocalSources,
            operations: MeshParticipantLocalPublicationOperations(
                start: { [weak self] instanceID, descriptor in
                    guard let self else { throw CancellationError() }
                    try await capturePublisher.start(
                        ownerParticipantID: localParticipantID,
                        sourceInstanceID: instanceID,
                        capture: descriptor,
                        preferredSlot: nil
                    )
                },
                update: { [weak self] instanceID, descriptor in
                    guard let self else { throw CancellationError() }
                    try await capturePublisher.update(
                        sourceInstanceID: instanceID,
                        capture: descriptor
                    )
                },
                stop: { [weak self] instanceID in
                    guard let self else { throw CancellationError() }
                    try await capturePublisher.stop(
                        sourceInstanceID: instanceID
                    )
                },
                stopAll: { [weak self] in
                    await self?.capturePublisher.stopAll()
                },
                setSystemAudio: { [weak self] request in
                    guard let self else { throw CancellationError() }
                    try await capturePublisher.setSystemAudio(request)
                },
                applySettings: { [weak self] settings in
                    try await self?.applyLocalMediaSettings(settings)
                }
            ),
            persistSettings: { [persistLocalSettings] settings in
                persistLocalSettings(settings)
            },
            onChange: { [weak self] snapshot in
                self?.applyLocalPublicationSnapshot(snapshot)
            },
            onFailure: { [weak self] message in
                self?.reportLocalPublicationFailure(message)
            }
        )
    }

    private(set) lazy var presentationModel = MeshRoomPresentationModel(
        snapshot: makePresentationSnapshot(),
        actions: makePresentationActions()
    )

    init(
        context: MeshParticipantLaunchContext,
        bootstrap: any MeshParticipantBootstrapRouting,
        webRTCConfiguration: ClipLiveShareNativeV3WebRTCConfiguration =
            .clipDefault,
        mediaFactory injectedMediaFactory:
            ClipLiveShareNativeV3WebRTCTransportFactory? = nil,
        peerLinkManager injectedPeerLinkManager:
            ClipLiveShareNativeV3MeshPeerLinkManager? = nil,
        initialLocalSettings: LiveShareSettings = .default,
        persistLocalSettings: @escaping (LiveShareSettings) -> Void = {
            _ in
        },
        localCaptureDiscovery: any CaptureContentDiscovering =
            ScreenCaptureContentDiscovery(),
        localPresentation:
            MeshParticipantLocalPresentationState =
                .init(),
        actions: MeshParticipantCoordinatorActions = .init(),
        now: @escaping @Sendable () -> Date = Date.init,
        membershipRefreshSleeper: any ClipLiveShareReconnectSleeper =
            ContinuousClipLiveShareReconnectSleeper(),
        membershipRefreshLeadTime: TimeInterval = 60,
        leaderLossStabilityDuration: Duration = .seconds(2),
        acceptanceReporter: NativeV3MeshAcceptanceReporter? = nil,
        confirmLeaveAfterLastRemoteWindowCloses:
            @escaping () -> Bool = {
                MeshParticipantCoordinator
                    .presentLastRemoteWindowCloseConfirmation()
            },
        onSessionEnded: @escaping () -> Void,
        onMenuBarStatusChanged: @escaping (MeshParticipantMenuBarStatus) -> Void = {
            _ in
        }
    ) throws {
        localParticipantID = context.localParticipantID
        self.localPresentation = localPresentation
        self.actions = actions
        self.now = now
        self.membershipRefreshSleeper = membershipRefreshSleeper
        self.membershipRefreshLeadTime = max(1, membershipRefreshLeadTime)
        self.leaderLossStabilityDuration = leaderLossStabilityDuration
        self.initialLocalSettings = initialLocalSettings
        self.persistLocalSettings = persistLocalSettings
        collaborationConfiguration =
            MeshParticipantCollaborationConfiguration(
                settings: initialLocalSettings,
                persistentIdentity:
                    context.localIdentitySigner.publicKey.x963Representation
            )
        localPointerVisible =
            initialLocalSettings.collaborationPointerVisibleByDefault
        self.localCaptureDiscovery = localCaptureDiscovery
        maximumLocalSources =
            context.admissionPolicy.maximumActiveSourcesPerParticipant
        localIdentitySigner = context.localIdentitySigner
        self.acceptanceReporter = acceptanceReporter
        self.confirmLeaveAfterLastRemoteWindowCloses =
            confirmLeaveAfterLastRemoteWindowCloses
        self.onSessionEnded = onSessionEnded
        self.onMenuBarStatusChanged = onMenuBarStatusChanged
        verifiedPeerTransportNonces = context.verifiedPeerTransportNonces
        bootstrapAdmissionDigests = context.bootstrapAdmissionDigests
        lifecycle = try ClipLiveShareNativeV3RoomLifecycleCoordinator(
            localParticipantID: context.localParticipantID,
            localSigner: context.localIdentitySigner,
            authorityChain: context.authorityChain,
            expectedSessionID: context.signedMembership.snapshot.sessionID,
            expectedFoundingCreatorIdentity:
                context.expectedFoundingCreatorIdentity,
            admissionPolicy: context.admissionPolicy,
            establishedPeerParticipantIDs:
                Set(context.verifiedPeerTransportNonces.keys),
            at: ClipLiveShareNativeTimestamp(date: Date())
        )

        let factory: ClipLiveShareNativeV3WebRTCTransportFactory
        let manager: ClipLiveShareNativeV3MeshPeerLinkManager
        switch (injectedMediaFactory, injectedPeerLinkManager) {
        case let (.some(injectedFactory), .some(injectedManager)):
            factory = injectedFactory
            manager = injectedManager
        case (nil, nil):
            factory = try ClipLiveShareNativeV3WebRTCTransportFactory(
                configuration: webRTCConfiguration
            )
            manager = ClipLiveShareNativeV3MeshPeerLinkManager(
                localParticipantID: context.localParticipantID,
                transportFactory: factory
            )
        default:
            throw MeshParticipantCoordinatorError.incompleteTransportInjection
        }
        mediaFactory = factory
        peerLinkManager = manager
        let runtime = MeshParticipantRuntime(
            context: context,
            manager: manager,
            bootstrap: bootstrap
        )
        self.runtime = runtime
        runtimeSnapshot = nil
        capturePublisher = MeshParticipantCapturePublisher(
            factory: factory,
            maximumActiveSources:
                context.admissionPolicy.maximumActiveSourcesPerParticipant,
            publishSources: { [weak runtime] sources in
                try await runtime?.publishLocalSources(sources)
            }
        )
    }

    var isActive: Bool {
        eventTask != nil && !isEnding
    }

    func start() {
        guard eventTask == nil, !isEnding else { return }
        let isRetry = hasStartedRuntime
        startedAt = Date()
        localPublicationController.start()
        if isRetry {
            phase = .reconnecting
            onMenuBarStatusChanged(.reconnecting)
            publish()
        }
        captureFailureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let failures = await capturePublisher.failures()
            for await failure in failures {
                guard !Task.isCancelled, !isEnding else { return }
                handleLocalCaptureFailure(failure)
            }
        }
        collaborationExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    guard let self, !isEnding else { return }
                    guard let timestamp = try? ClipLiveShareNativeTimestamp(
                        date: now()
                    ) else { continue }
                    _ = await runtime.pruneExpiredCollaboration(
                        at: timestamp
                    )
                } catch {
                    return
                }
            }
        }
        nativeCursorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !isEnding else { return }
                let updatesPerSecond = await publishNativeCursor()
                do {
                    try await Task.sleep(
                        for: .nanoseconds(
                            1_000_000_000 / Int64(
                                max(1, updatesPerSecond)
                            )
                        )
                    )
                } catch {
                    return
                }
            }
        }
        let eventGeneration = UUID()
        eventTaskGeneration = eventGeneration
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if eventTaskGeneration == eventGeneration {
                    eventTask = nil
                    eventTaskGeneration = nil
                }
            }
            let stream = await runtime.events()
            do {
                if !hasStartedRuntime {
                    try await runtime.start(
                        at: ClipLiveShareNativeTimestamp(date: Date())
                    )
                    hasStartedRuntime = true
                }
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    await handle(event)
                }
            } catch is CancellationError {
                return
            } catch {
                fail(error.localizedDescription)
            }
        }
        statisticsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    guard let self, !isEnding else { return }
                    try await runtime.refreshStatistics()
                } catch is CancellationError {
                    return
                } catch {
                    Self.logger.debug(
                        "Native-v3 statistics unavailable: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        localOverlayTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !isEnding else { return }
                await refreshLocalSourceOverlays()
                refreshLocalSharingControls()
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
        scheduleMembershipRefreshIfNeeded()
        if !isRetry {
            onMenuBarStatusChanged(.ready)
        }
    }

    func updateLocalPresentation(
        _ state: MeshParticipantLocalPresentationState
    ) {
        localPresentation = state
        publish()
    }

    /// Connection/session events update only their own presentation fields.
    /// Replacing `localPresentation` wholesale here would race local capture
    /// discovery and settings changes owned by the participant coordinator.
    func updateRoomName(_ roomName: String) {
        localPresentation.roomName = roomName
        publish()
    }

    func updateRoomInvite(_ invite: MeshRoomInviteSnapshot?) {
        localPresentation.invite = invite
        publish()
    }

    func updatePendingAdmissions(
        _ admissions: [MeshRoomPendingAdmissionSnapshot]
    ) {
        localPresentation.pendingAdmissions = admissions
        publish()
    }

    func updateAccessWordPresentation(
        enabled: Bool,
        value: String?,
        canChange: Bool
    ) {
        localPresentation.accessWordEnabled = enabled
        localPresentation.accessWord = value
        localPresentation.canChangeAccessWord = canChange
        publish()
    }

    private func applyLocalPublicationSnapshot(
        _ snapshot: MeshParticipantLocalPublicationSnapshot
    ) {
        localPresentation.fullscreen = snapshot.fullscreen
        localPresentation.canShareFocusedWindow =
            snapshot.canShareFocusedWindow
        localPresentation.focusedWindowDescription =
            snapshot.focusedWindowDescription
        localPresentation.availableWindows = snapshot.availableWindows
        localPresentation.canAddWindow = snapshot.canAddWindow
        localPresentation.settings = snapshot.settings
        refreshLocalSharingControls()
        publish()
    }

    private func applyLocalMediaSettings(
        _ settings: LiveShareSettings
    ) async throws {
        let requestedCodec = meshWebRTCVideoCodec(settings.videoCodec)
        if mediaFactory.videoCodec != requestedCodec {
            // The participant-wide preference applies to future links even if
            // one current peer cannot complete its independent renegotiation.
            // The runtime rolls only that failed pair back.
            try mediaFactory.retainVideoCodec(requestedCodec)
            try await runtime.updateVideoCodec(
                requestedCodec,
                at: ClipLiveShareNativeTimestamp(date: now())
            )
        }

        mediaFactory.updateVideoEncodingMode(settings.encodingMode)
        if let advanced = meshWebRTCAdvancedVideoConfiguration(
            settings.advancedVideoSettings.settings(for: settings.videoCodec),
            codec: settings.videoCodec
        ) {
            mediaFactory.updateAdvancedVideoConfiguration(advanced)
        }

        let senderPolicy = LiveShareCapturePolicy.senderPolicy(
            for: settings
        )
        await runtime.updateSenderPolicy(senderPolicy)
        mediaFactory.retainSenderPolicy(senderPolicy)
    }

    private func meshWebRTCVideoCodec(
        _ codec: LiveShareVideoCodec
    ) -> WebRTCVideoCodec {
        switch codec {
        case .h264:
            .h264
        case .vp8:
            .vp8
        case .vp9:
            .vp9
        case .av1:
            .av1
        }
    }

    private func meshWebRTCAdvancedVideoConfiguration(
        _ settings: LiveShareCodecAdvancedSettings,
        codec: LiveShareVideoCodec
    ) -> WebRTCCodecAdvancedConfiguration? {
        let normalized = settings.normalized(for: codec)
        switch codec {
        case .h264:
            return .h264(
                WebRTCH264AdvancedConfiguration(
                    maximumQuantizer: normalized.maximumQuantizer,
                    qualityFraction:
                        Double(normalized.h264QualityPercent ?? 98) / 100,
                    keyFrameIntervalSeconds:
                        normalized.h264KeyFrameIntervalSeconds ?? 2
                )
            )
        case .vp8, .vp9, .av1:
            return nil
        }
    }

    func updateLifecycle(phase: MeshRoomPhase) {
        self.phase = phase
        publish()
    }

    func commitMembership(
        _ signedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
        authorityChain: ClipLiveShareNativeV3RoomAuthorityChain,
        verifiedNonces:
            [ClipLiveShareNativeV3ParticipantID:
                ClipLiveShareNativeV3TransportNonce],
        bootstrapAdmissionDigests:
            [ClipLiveShareNativeV3ParticipantID: ClipLiveShareNativeDigest]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let now = try ClipLiveShareNativeTimestamp(date: Date())
                var candidate = lifecycle
                for participantID in verifiedNonces.keys {
                    candidate.markPeerLinkReady(with: participantID)
                }
                let events = try candidate.commitMembershipSnapshot(
                    signedMembership,
                    at: now
                )
                guard candidate.authorityChain == authorityChain else {
                    throw ClipLiveShareNativeV3Error.invalidAuthorityChain
                }
                try await runtime.commitMembership(
                    signedMembership,
                    validatedAuthorityChain: candidate.authorityChain,
                    verifiedNonces: verifiedNonces,
                    bootstrapAdmissionDigests: bootstrapAdmissionDigests,
                    at: now
                )
                installLifecycle(candidate)
                self.verifiedPeerTransportNonces = verifiedNonces
                self.bootstrapAdmissionDigests = bootstrapAdmissionDigests
                try await applyLifecycleEvents(events)
                await notifyCommittedContext(
                    refreshInviteIfLocalLeader:
                        Self.requiresFreshInvite(events)
                )
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func stopLocalCapture(sourceInstanceID: ClipLiveShareSourceInstanceID) {
        Task { @MainActor [weak self] in
            do {
                try await self?.capturePublisher.stop(
                    sourceInstanceID: sourceInstanceID
                )
            } catch {
                self?.fail(error.localizedDescription)
            }
        }
    }

    func setLocalSystemAudio(_ request: CaptureAudioSessionRequest?) {
        Task { @MainActor [weak self] in
            do {
                try await self?.capturePublisher.setSystemAudio(request)
            } catch {
                self?.fail(error.localizedDescription)
            }
        }
    }

    func endForApplicationTermination() async {
        if !isEnding, lifecycle.phase != .ended {
            do {
                try await beginLeaveRoom()
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(5))
                while !hasCompletedShutdown, clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                Self.logger.error(
                    "Could not finish a graceful mesh departure before termination: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        await endSession(notifyApplication: false)
    }

    func hideForApplicationTermination() {
        for coordinator in remoteWindows.values {
            coordinator.tearDown()
        }
        localSourceOverlays.tearDown()
        focusedWindowControl.tearDown()
        localStatusHUD.tearDown()
    }

    func cancelForApplicationStop() {
        guard !isEnding else { return }
        isEnding = true
        eventTask?.cancel()
        statisticsTask?.cancel()
        leaderLossTask?.cancel()
        membershipRefreshTask?.cancel()
        localOverlayTask?.cancel()
        captureFailureTask?.cancel()
        collaborationExpiryTask?.cancel()
        nativeCursorTask?.cancel()
        eventTask = nil
        statisticsTask = nil
        leaderLossTask = nil
        membershipRefreshTask = nil
        localOverlayTask = nil
        captureFailureTask = nil
        collaborationExpiryTask = nil
        nativeCursorTask = nil
        tearDownRemotePresentations()
        localSourceOverlays.tearDown()
        focusedWindowControl.tearDown()
        localStatusHUD.tearDown()
        let runtime = runtime
        let publisher = capturePublisher
        let localPublicationController = localPublicationController
        let factory = mediaFactory
        Task { @MainActor [weak self] in
            await localPublicationController.stop()
            await publisher.stopAll()
            await runtime.close()
            factory.close()
            self?.markShutdownComplete()
        }
    }

    private func handle(_ event: MeshParticipantRuntimeEvent) async {
        switch event {
        case let .snapshotChanged(snapshot):
            mediaRateEstimator.record(
                Dictionary(
                    uniqueKeysWithValues: snapshot.statistics.flatMap {
                        participantID, peerStatistics in
                        peerStatistics.transport.videoSources.map {
                            sourceStatistics in
                            let direction:
                                MeshRoomMediaDiagnosticsSnapshot.Direction =
                                    sourceStatistics.direction == .outgoing
                                        ? .outgoing
                                        : .incoming
                            return (
                                MeshRoomMediaCounterKey(
                                    participantID: participantID.rawValue,
                                    trackIdentifier:
                                        sourceStatistics.trackIdentifier,
                                    direction: direction
                                ),
                                MeshRoomMediaCounterSample(
                                    capturedAt:
                                        peerStatistics.transport.capturedAt,
                                    bytes: sourceStatistics.bytes,
                                    frames: sourceStatistics.frames,
                                    reportedFramesPerSecond:
                                        sourceStatistics.framesPerSecond
                                )
                            )
                        }
                    }
                )
            )
            runtimeSnapshot = snapshot
            let activeSourceKeys = Set(
                snapshot.sourceSnapshots.values.flatMap { manifest in
                    manifest.sources.map(\.key)
                }
            )
            collaborationSequenceBySource =
                collaborationSequenceBySource.filter {
                    activeSourceKeys.contains($0.key)
                }
            nativeCursorSequenceBySource =
                nativeCursorSequenceBySource.filter {
                    activeSourceKeys.contains($0.key)
                }
            if (phase == .connecting || phase == .reconnecting),
               snapshot.isLocallyComplete {
                hasReachedLive = true
                phase = .live(
                    elapsedSeconds: Date().timeIntervalSince(startedAt)
                )
                onMenuBarStatusChanged(.live)
            }
            await synchronizePeerLiveness(from: snapshot)
            await reconcileRemotePresentations()
            await refreshLocalSourceOverlays()
            refreshLocalSharingControls()
            publish()
        case let .remoteVideoTrackChanged(
            participantID,
            mediaTrackID,
            isAvailable
        ):
            if !isAvailable,
               var presentation = remotePresentations[participantID] {
                let streamIDs = runtimeSnapshot?
                    .sourceSnapshots[participantID]?
                    .sources
                    .filter {
                        $0.descriptor.stream.mediaTrackID == mediaTrackID
                    }
                    .map {
                        $0.descriptor.stream.id.rawValue
                    } ?? []
                for streamID in streamIDs {
                    _ = presentation.removeRemoteTrack(
                        streamID: streamID
                    )
                }
                remotePresentations[participantID] = presentation
            }
            await reconcileRemotePresentations()
            publish()
        case let .sourceCursorReceived(cursor, participantID):
            remoteWindows[participantID]?.setCursor(
                streamID: cursor.streamID.rawValue,
                normalizedX: cursor.position.map {
                    CGFloat($0.x)
                },
                normalizedY: cursor.position.map {
                    CGFloat($0.y)
                }
            )
        case let .membershipReceived(snapshot, participantID):
            do {
                let consumed = try await actions
                    .receiveBootstrapMembership(
                        snapshot,
                        participantID
                    )
                if !consumed {
                    await receiveMembership(
                        snapshot,
                        from: participantID
                    )
                }
            } catch {
                await quarantineRemoteParticipant(
                    participantID,
                    error: error
                )
            }
        case let .roomControlReceived(envelope, participantID):
            await receiveRoomControl(envelope, from: participantID)
        case let .bootstrapForwardReceived(forward, participantID):
            // Admission forwarding travels over an already authenticated mesh
            // control link, but the room-connection owner owns the candidate
            // rendezvous transaction until membership commit. Give it first
            // refusal so a final admitted snapshot promotes the provisional
            // link before the ordinary lifecycle can commit the same revision.
            do {
                let consumed = try await actions
                    .receiveBootstrapForward(
                        forward,
                        participantID
                    )
                if !consumed {
                    actions.handleRoomControl(
                        .bootstrapForward(forward),
                        participantID
                    )
                }
            } catch {
                await quarantineRemoteParticipant(
                    participantID,
                    error: error
                )
            }
        case let .peerDegraded(participantID, message):
            Self.logger.warning(
                "Native-v3 peer \(participantID.rawValue, privacy: .public) degraded: \(message, privacy: .public)"
            )
            clearPendingLeadershipTransitions(
                ownedBy: participantID
            )
            authoritySynchronizedPeers.remove(participantID)
            authorityAnnouncementPeers.remove(participantID)
            lifecycle.markPeerLinkUnavailable(with: participantID)
            publish()
        case let .failed(message):
            fail(message)
        case .closed:
            if !isEnding {
                phase = .reconnecting
                onMenuBarStatusChanged(.reconnecting)
                publish()
            }
        }
    }

    // MARK: - Room authority

    /// Keeps media liveness and room authority deliberately separate. A lost
    /// leader link does not stop surviving media; after a short stability
    /// window the lifecycle either starts a strict-majority election or enters
    /// leaderlessLocked. A reappearing certified leader cancels only a recovery
    /// election, never an intentional graceful transfer.
    private func synchronizePeerLiveness(
        from snapshot: MeshParticipantRuntimeSnapshot
    ) async {
        let readyParticipantIDs = Set(
            snapshot.links.links.compactMap {
                $0.isReady ? $0.remoteParticipantID : nil
            }
        )
        for participantID in lifecycle.participantIDs
            .subtracting([localParticipantID]) {
            if readyParticipantIDs.contains(participantID) {
                lifecycle.markPeerLinkReady(with: participantID)
            } else {
                lifecycle.markPeerLinkUnavailable(with: participantID)
            }
        }

        authoritySynchronizedPeers.formIntersection(readyParticipantIDs)
        authorityAnnouncementPeers.formIntersection(readyParticipantIDs)
        // Authority loss is safety-critical and must not wait behind a
        // potentially back-pressured control send. A second evaluation after
        // announcements accounts for confirmations received while awaiting.
        await evaluateLocalLeaderQuorum(
            readyParticipantIDs: readyParticipantIDs
        )
        let newlyReady = readyParticipantIDs
            .intersection(lifecycle.participantIDs)
            .subtracting([localParticipantID])
            .subtracting(authorityAnnouncementPeers)
        for participantID in newlyReady.sorted() {
            let announcedChain = lifecycle.authorityChain
            do {
                try await runtime.sendRoomControl(
                    .roomAuthority(announcedChain),
                    to: [participantID]
                )
                if lifecycle.authorityChain == announcedChain {
                    authorityAnnouncementPeers.insert(participantID)
                }
            } catch {
                authorityAnnouncementPeers.remove(participantID)
            }
        }

        await evaluateLocalLeaderQuorum(
            readyParticipantIDs: readyParticipantIDs
        )
    }

    private func evaluateLocalLeaderQuorum(
        readyParticipantIDs:
            Set<ClipLiveShareNativeV3ParticipantID>
    ) async {
        let leaderID = lifecycle.currentLeaderParticipantID
        guard leaderID != localParticipantID else {
            leaderLossTask?.cancel()
            leaderLossTask = nil
            guard hasReachedLive, !isEnding else { return }
            let reachableCount = readyParticipantIDs
                .intersection(lifecycle.participantIDs)
                .union([localParticipantID])
                .count
            let required =
                ClipLiveShareNativeV3LeadershipCertificate
                .requiredQuorum(
                    participantCount: lifecycle.participantIDs.count
                )
            do {
                switch lifecycle.phase {
                case .active where reachableCount < required:
                    let events = try lifecycle.localLeaderLostQuorum()
                    try await applyLifecycleEvents(events)
                case .leaderlessLocked:
                    let synchronizedCount = authoritySynchronizedPeers
                        .intersection(readyParticipantIDs)
                        .intersection(lifecycle.participantIDs)
                        .union([localParticipantID])
                        .count
                    guard synchronizedCount >= required else { return }
                    let term = lifecycle.currentTerm
                    let digest = lifecycle.signedMembership.snapshot.digest
                    let events = try lifecycle.localLeaderQuorumRestored(
                        expectedTerm: term,
                        expectedMembershipDigest: digest
                    )
                    try await applyLifecycleEvents(events)
                case .active, .electing, .ended:
                    break
                }
            } catch {
                fail(error.localizedDescription)
            }
            return
        }
        if readyParticipantIDs.contains(leaderID) {
            leaderLossTask?.cancel()
            leaderLossTask = nil
            if lifecycle.phase == .leaderlessLocked
                || lifecycle.phase == .electing {
                do {
                    let events = try lifecycle.currentLeaderBecameReachable()
                    Task { @MainActor [weak self] in
                        try? await self?.applyLifecycleEvents(events)
                    }
                } catch {
                    // A graceful transfer is intentionally not cancelled by
                    // observing that the departing leader is still reachable.
                }
            }
            return
        }
        guard hasReachedLive,
              lifecycle.phase == .active
                || lifecycle.phase == .leaderlessLocked,
              leaderLossTask == nil,
              !isEnding else { return }
        let leaderLossStabilityDuration = leaderLossStabilityDuration
        leaderLossTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: leaderLossStabilityDuration)
                guard let self, !isEnding,
                      let snapshot = runtimeSnapshot else { return }
                let reachable = Set(
                    snapshot.links.links.compactMap {
                        $0.isReady ? $0.remoteParticipantID : nil
                    }
                ).union([localParticipantID])
                guard !reachable.contains(
                    lifecycle.currentLeaderParticipantID
                ) else { return }
                let events = try lifecycle.beginUnexpectedLeaderLoss(
                    reachableParticipantIDs: reachable,
                    at: try currentTimestamp()
                )
                try await applyLifecycleEvents(events)
            } catch is CancellationError {
                return
            } catch {
                self?.fail(error.localizedDescription)
            }
            self?.leaderLossTask = nil
        }
    }

    private func receiveRoomControl(
        _ envelope: ClipLiveShareNativeV3ControlEnvelope,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async {
        defer { actions.handleRoomControl(envelope, participantID) }
        do {
            let now = try currentTimestamp()
            switch envelope {
            case let .participantLeaveRequest(signed):
                guard
                    signed.request.participantID == participantID,
                    lifecycle.isLocalLeader
                else { return }
                let membership = try lifecycle.makeMembershipSnapshot(
                    accepting: signed,
                    at: now
                )
                try await commitOrdinaryMembership(
                    membership,
                    broadcasting: true
                )

            case let .leadershipTransferRequest(request):
                guard
                    participantID == lifecycle.currentLeaderParticipantID
                else {
                    throw MeshParticipantRuntimeError.unexpectedSender
                }
                let events = try lifecycle.receiveLeadershipTransferRequest(
                    request,
                    at: now
                )
                try await applyLifecycleEvents(events)

            case let .leadershipProposal(proposal):
                guard
                    participantID
                        == proposal.proposal.candidateParticipantID
                else {
                    throw MeshParticipantRuntimeError.unexpectedSender
                }
                let events = try lifecycle.receiveLeadershipProposal(
                    proposal,
                    at: now
                )
                try await applyLifecycleEvents(events)

            case let .leadershipVote(vote):
                guard participantID == vote.vote.voterParticipantID else {
                    throw MeshParticipantRuntimeError.unexpectedSender
                }
                guard lifecycle.pendingCandidateParticipantID
                    == localParticipantID else { return }
                let events = try lifecycle.receiveLeadershipVote(
                    vote,
                    at: now
                )
                try await applyLifecycleEvents(events)

            case let .leadershipCertificate(certificate):
                guard
                    participantID == certificate.newLeaderParticipantID
                else {
                    throw MeshParticipantRuntimeError.unexpectedSender
                }
                try certificate.verify(
                    lastCommittedMembership: lifecycle.signedMembership,
                    currentTerm: lifecycle.currentTerm,
                    currentLeaderParticipantID:
                        lifecycle.currentLeaderParticipantID,
                    currentLeaderIdentity:
                        lifecycle.currentLeaderIdentity,
                    at: now
                )
                let key = LeadershipTransitionKey(
                    term: certificate.term,
                    newLeaderParticipantID:
                        certificate.newLeaderParticipantID
                )
                var fragments =
                    pendingLeadershipTransitions[key]
                    ?? LeadershipTransitionFragments()
                guard
                    fragments.certificate == nil
                        || fragments.certificate == certificate
                else {
                    throw ClipLiveShareNativeV3Error
                        .invalidLeadershipCertificate
                }
                fragments.certificate = certificate
                pendingLeadershipTransitions[key] = fragments
                try await commitPendingLeadershipTransitionIfReady(
                    for: key
                )

            case let .roomAuthority(chain):
                var candidate = lifecycle
                switch try candidate.reconcileAuthorityChain(
                    chain,
                    from: participantID,
                    at: now
                ) {
                case .identical:
                    let readyParticipantIDs = Set(
                        runtimeSnapshot?.links.links.compactMap {
                            $0.isReady
                                ? $0.remoteParticipantID
                                : nil
                        } ?? []
                    )
                    guard readyParticipantIDs.contains(participantID) else {
                        break
                    }
                    let isNewConfirmation =
                        authoritySynchronizedPeers.insert(
                            participantID
                        ).inserted
                    if isNewConfirmation {
                        // The full chain doubles as an epoch-bound
                        // acknowledgement. Echo once so the announcing peer
                        // can count this exact authority state too.
                        try await runtime.sendRoomControl(
                            .roomAuthority(lifecycle.authorityChain),
                            to: [participantID]
                        )
                    }
                    await evaluateLocalLeaderQuorum(
                        readyParticipantIDs: readyParticipantIDs
                    )

                case .stale:
                    // A reconnecting peer may announce its older valid prefix
                    // before our current chain reaches it. That is a resync
                    // request, not malicious room state.
                    try await runtime.sendRoomControl(
                        .roomAuthority(lifecycle.authorityChain),
                        to: [participantID]
                    )

                case let .adopted(events):
                    let membership = candidate.signedMembership
                    if membership.snapshot.participantIDs.contains(
                        localParticipantID
                    ) {
                        let retainedNonces =
                            verifiedPeerTransportNonces.filter {
                                membership.snapshot.participantIDs
                                    .contains($0.key)
                            }
                        let retainedDigests =
                            bootstrapAdmissionDigests.filter {
                                membership.snapshot.participantIDs
                                    .contains($0.key)
                            }
                        try await runtime.commitMembership(
                            membership,
                            validatedAuthorityChain:
                                candidate.authorityChain,
                            verifiedNonces: retainedNonces,
                            bootstrapAdmissionDigests:
                                retainedDigests,
                            at: now
                        )
                        verifiedPeerTransportNonces = retainedNonces
                        bootstrapAdmissionDigests = retainedDigests
                    }
                    installLifecycle(candidate)
                    pendingLeadershipTransitions.removeAll(
                        keepingCapacity: true
                    )
                    try await applyLifecycleEvents(events)
                    await notifyCommittedContext(
                        refreshInviteIfLocalLeader:
                            Self.requiresFreshInvite(events)
                    )
                    // Confirm the exact adopted chain back to its certified
                    // leader. If that leader has been authority-locked, this
                    // acknowledgement is what permits its safe restore.
                    try await runtime.sendRoomControl(
                        .roomAuthority(lifecycle.authorityChain),
                        to: [participantID]
                    )
                }

            case let .roomTermination(termination):
                guard
                    participantID == lifecycle.currentLeaderParticipantID
                else {
                    throw MeshParticipantRuntimeError.unexpectedSender
                }
                let events = try lifecycle.receiveRoomTermination(
                    termination,
                    at: now
                )
                try await applyLifecycleEvents(events)

            case .membershipSnapshot, .sourceSnapshot,
                 .possessionChallenge, .possessionProof,
                 .peerLinkOffer, .peerLinkAnswer, .peerLinkICE,
                 .peerLinkRenegotiationRequest, .sourceCursor,
                 .collaboration,
                 .bootstrapForward:
                break
            }
        } catch {
            await quarantineRemoteParticipant(
                participantID,
                error: error
            )
        }
    }

    private func receiveMembership(
        _ membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async {
        do {
            if membership.snapshot.leaderParticipantID
                == lifecycle.currentLeaderParticipantID {
                guard participantID == lifecycle.currentLeaderParticipantID
                else {
                    throw MeshParticipantRuntimeError.unexpectedSender
                }
                try await commitOrdinaryMembership(
                    membership,
                    broadcasting: false
                )
            } else {
                guard participantID == membership.snapshot.leaderParticipantID
                else {
                    throw MeshParticipantRuntimeError.unexpectedSender
                }
                let key = try nextLeadershipTransitionKey(
                    newLeaderParticipantID:
                        membership.snapshot.leaderParticipantID
                )
                guard
                    let establishedCandidate =
                        lifecycle.signedMembership.snapshot.participants.first(
                            where: {
                                $0.participantID
                                    == key.newLeaderParticipantID
                            }
                        ),
                    establishedCandidate.identity
                        == membership.snapshot.leaderIdentity
                else {
                    throw ClipLiveShareNativeV3Error.invalidLeader
                }
                try membership.verify(
                    expectedSessionID: lifecycle.sessionID,
                    expectedLeaderParticipantID:
                        key.newLeaderParticipantID,
                    expectedLeaderIdentity:
                        establishedCandidate.identity,
                    localCapabilities: .current,
                    at: try currentTimestamp()
                )
                var fragments =
                    pendingLeadershipTransitions[key]
                    ?? LeadershipTransitionFragments()
                guard
                    fragments.membership == nil
                        || fragments.membership == membership
                else {
                    throw ClipLiveShareNativeV3Error.invalidMembership
                }
                fragments.membership = membership
                pendingLeadershipTransitions[key] = fragments
                try await commitPendingLeadershipTransitionIfReady(
                    for: key
                )
            }
        } catch {
            await quarantineRemoteParticipant(
                participantID,
                error: error
            )
        }
    }

    private func quarantineRemoteParticipant(
        _ participantID: ClipLiveShareNativeV3ParticipantID,
        error: any Error
    ) async {
        let message = error.localizedDescription
        Self.logger.error(
            "Native-v3 participant \(participantID.rawValue, privacy: .public) sent invalid room state: \(message, privacy: .public)"
        )
        clearPendingLeadershipTransitions(ownedBy: participantID)
        authoritySynchronizedPeers.remove(participantID)
        authorityAnnouncementPeers.remove(participantID)
        lifecycle.markPeerLinkUnavailable(with: participantID)
        await runtime.quarantineParticipant(
            participantID,
            reason: message
        )
        publish()
    }

    private func commitOrdinaryMembership(
        _ membership: ClipLiveShareSignedNativeV3MembershipSnapshot,
        broadcasting: Bool
    ) async throws {
        let now = try currentTimestamp()
        var candidate = lifecycle
        let events = try candidate.commitMembershipSnapshot(
            membership,
            at: now
        )
        if broadcasting {
            try await runtime.sendRoomControl(.membershipSnapshot(membership))
        }
        if membership.snapshot.participantIDs.contains(localParticipantID) {
            let retainedNonces = verifiedPeerTransportNonces.filter {
                membership.snapshot.participantIDs.contains($0.key)
            }
            let retainedDigests = bootstrapAdmissionDigests.filter {
                membership.snapshot.participantIDs.contains($0.key)
            }
            try await runtime.commitMembership(
                membership,
                validatedAuthorityChain: candidate.authorityChain,
                verifiedNonces: retainedNonces,
                bootstrapAdmissionDigests: retainedDigests,
                at: now
            )
            verifiedPeerTransportNonces = retainedNonces
            bootstrapAdmissionDigests = retainedDigests
        }
        installLifecycle(candidate)
        // An ordinary membership commit changes the digest against which a
        // leadership certificate is signed. All fragments from the prior
        // membership are therefore obsolete, regardless of their sender.
        pendingLeadershipTransitions.removeAll(keepingCapacity: true)
        try await applyLifecycleEvents(events)
        await notifyCommittedContext(
            refreshInviteIfLocalLeader: Self.requiresFreshInvite(events)
        )
    }

    private func commitPendingLeadershipTransitionIfReady(
        for key: LeadershipTransitionKey
    ) async throws {
        guard
            let fragments = pendingLeadershipTransitions[key],
            let certificate = fragments.certificate,
            let membership = fragments.membership,
            let authorityChain = fragments.authorityChain
        else { return }
        let now = try currentTimestamp()
        var candidate = lifecycle
        let events = try candidate.commitLeadershipTransition(
            certificate: certificate,
            successorMembership: membership,
            at: now
        )
        guard
            certificate.term == key.term,
            certificate.newLeaderParticipantID
                == key.newLeaderParticipantID,
            membership.snapshot.leaderParticipantID
                == key.newLeaderParticipantID,
            authorityChain.currentTerm == key.term,
            authorityChain.currentLeaderParticipantID
                == key.newLeaderParticipantID,
            authorityChain.currentMembership == membership,
            authorityChain == candidate.authorityChain
        else {
            throw ClipLiveShareNativeV3Error.invalidAuthorityChain
        }
        if membership.snapshot.participantIDs.contains(localParticipantID) {
            let retainedNonces = verifiedPeerTransportNonces.filter {
                membership.snapshot.participantIDs.contains($0.key)
            }
            let retainedDigests = bootstrapAdmissionDigests.filter {
                membership.snapshot.participantIDs.contains($0.key)
            }
            try await runtime.commitMembership(
                membership,
                validatedAuthorityChain: candidate.authorityChain,
                verifiedNonces: retainedNonces,
                bootstrapAdmissionDigests: retainedDigests,
                at: now
            )
            verifiedPeerTransportNonces = retainedNonces
            bootstrapAdmissionDigests = retainedDigests
        }
        installLifecycle(candidate)
        pendingLeadershipTransitions.removeAll(keepingCapacity: true)
        try await applyLifecycleEvents(events)
        await notifyCommittedContext(
            refreshInviteIfLocalLeader: Self.requiresFreshInvite(events)
        )
    }

    private func nextLeadershipTransitionKey(
        newLeaderParticipantID:
            ClipLiveShareNativeV3ParticipantID
    ) throws -> LeadershipTransitionKey {
        let (nextTermRawValue, overflow) =
            lifecycle.currentTerm.rawValue.addingReportingOverflow(1)
        guard !overflow else {
            throw ClipLiveShareNativeV3Error.invalidLeadershipTerm
        }
        return LeadershipTransitionKey(
            term: try .init(rawValue: nextTermRawValue),
            newLeaderParticipantID: newLeaderParticipantID
        )
    }

    private func validateAuthorityChainExtendsCurrentRoom(
        _ chain: ClipLiveShareNativeV3RoomAuthorityChain
    ) throws {
        let current = lifecycle.authorityChain
        guard
            chain.foundingCreatorParticipantID
                == current.foundingCreatorParticipantID,
            chain.foundingCreatorIdentity
                == current.foundingCreatorIdentity,
            chain.genesisMembership == current.genesisMembership,
            chain.checkpoints.count == current.checkpoints.count + 1,
            Array(chain.checkpoints.dropLast())
                == current.checkpoints,
            chain.latestMembership == nil,
            let checkpoint = chain.checkpoints.last
        else {
            throw ClipLiveShareNativeV3Error.invalidAuthorityChain
        }
        let authorityBridgeMembership =
            current.checkpoints.last?.successorMembership
            ?? current.genesisMembership
        let expectedPredecessor =
            lifecycle.signedMembership == authorityBridgeMembership
                ? nil
                : lifecycle.signedMembership
        guard
            checkpoint.predecessorMembership == expectedPredecessor,
            checkpoint.certificate.term == chain.currentTerm,
            checkpoint.certificate.newLeaderParticipantID
                == chain.currentLeaderParticipantID,
            checkpoint.successorMembership == chain.currentMembership
        else {
            throw ClipLiveShareNativeV3Error.invalidAuthorityChain
        }
    }

    private func clearPendingLeadershipTransitions(
        ownedBy participantID:
            ClipLiveShareNativeV3ParticipantID
    ) {
        pendingLeadershipTransitions = pendingLeadershipTransitions.filter {
            $0.key.newLeaderParticipantID != participantID
        }
    }

    private func completeLocalLeadershipTransition(
        _ certificate: ClipLiveShareNativeV3LeadershipCertificate
    ) async throws {
        let now = try currentTimestamp()
        let reachable = Set(
            runtimeSnapshot?.links.links.compactMap {
                $0.isReady ? $0.remoteParticipantID : nil
            } ?? []
        ).union([localParticipantID])
        let membership = try lifecycle.makeSuccessorMembership(
            for: certificate,
            retainingParticipantIDs: reachable,
            at: now
        )
        var candidate = lifecycle
        let events = try candidate.commitLeadershipTransition(
            certificate: certificate,
            successorMembership: membership,
            at: now
        )

        // A crash election is decided by the reachable quorum. The complete
        // chain is one independently verifiable transaction; a peer that
        // misses it receives the same authoritative value when its control
        // channel reopens.
        let survivingPeers = reachable.subtracting([localParticipantID])
        try await runtime.sendRoomControl(
            .roomAuthority(candidate.authorityChain),
            to: survivingPeers
        )

        let retainedNonces = verifiedPeerTransportNonces.filter {
            membership.snapshot.participantIDs.contains($0.key)
        }
        let retainedDigests = bootstrapAdmissionDigests.filter {
            membership.snapshot.participantIDs.contains($0.key)
        }
        try await runtime.commitMembership(
            membership,
            validatedAuthorityChain: candidate.authorityChain,
            verifiedNonces: retainedNonces,
            bootstrapAdmissionDigests: retainedDigests,
            at: now
        )
        verifiedPeerTransportNonces = retainedNonces
        bootstrapAdmissionDigests = retainedDigests
        installLifecycle(candidate)
        try await applyLifecycleEvents(events)
        await notifyCommittedContext(
            refreshInviteIfLocalLeader: Self.requiresFreshInvite(events)
        )
    }

    private func installLifecycle(
        _ candidate: ClipLiveShareNativeV3RoomLifecycleCoordinator
    ) {
        let authorityChanged =
            lifecycle.authorityChain != candidate.authorityChain
        lifecycle = candidate
        guard authorityChanged else { return }
        authoritySynchronizedPeers.removeAll(keepingCapacity: true)
        authorityAnnouncementPeers.removeAll(keepingCapacity: true)
    }

    private func applyLifecycleEvents(
        _ events: [ClipLiveShareNativeV3RoomLifecycleEvent]
    ) async throws {
        let carriesCommittedAuthority = events.contains {
            switch $0 {
            case .membershipCommitted, .leadershipCommitted,
                 .newInviteRequired:
                true
            default:
                false
            }
        }
        for event in events {
            switch event {
            case .peerLinksRequired:
                break
            case .membershipCommitted:
                scheduleMembershipRefreshIfNeeded()
                publish()
            case let .cleanupParticipant(participantID):
                removeRemoteParticipant(participantID)
            case .localParticipantRemoved:
                await endSession(notifyApplication: true)
                return
            case let .phaseChanged(next):
                applyLifecyclePhase(next)
                if next != .active || !carriesCommittedAuthority {
                    await notifyCommittedContext(
                        refreshInviteIfLocalLeader: false
                    )
                }
            case let .broadcastTransferRequest(request):
                try await runtime.sendRoomControl(
                    .leadershipTransferRequest(request)
                )
            case let .broadcastLeadershipProposal(proposal):
                try await runtime.sendRoomControl(
                    .leadershipProposal(proposal)
                )
            case let .broadcastLeadershipVote(vote):
                try await runtime.sendRoomControl(.leadershipVote(vote))
            case let .leadershipCertificateReady(certificate):
                try await completeLocalLeadershipTransition(certificate)
            case .leadershipCommitted:
                publish()
            case .newInviteRequired:
                // The committed-context callback is emitted exactly once by
                // the transaction that applied this event.
                break
            case let .broadcastRoomTermination(termination):
                try await runtime.sendRoomControl(
                    .roomTermination(termination)
                )
            case .roomEnded:
                await endSession(notifyApplication: true)
                return
            }
        }
    }

    private func notifyCommittedContext(
        refreshInviteIfLocalLeader: Bool
    ) async {
        guard !isEnding,
              lifecycle.participantIDs.contains(localParticipantID)
        else { return }
        await actions.committedContextChanged(
            MeshParticipantBootstrapLaunchContext(
                localParticipantID: localParticipantID,
                localIdentitySigner: localIdentitySigner,
                signedMembership: lifecycle.signedMembership,
                authorityChain: lifecycle.authorityChain,
                expectedFoundingCreatorIdentity:
                    lifecycle.authorityChain.foundingCreatorIdentity,
                bootstrapAdmissionDigests:
                    bootstrapAdmissionDigests,
                verifiedPeerTransportNonces:
                    verifiedPeerTransportNonces,
                admissionPolicy: lifecycle.admissionPolicy
            ),
            bootstrapRoomAvailability,
            refreshInviteIfLocalLeader
        )
    }

    private var bootstrapRoomAvailability:
        MeshParticipantBootstrapRoomAvailability
    {
        switch lifecycle.phase {
        case .active:
            .active
        case .electing, .leaderlessLocked:
            .leaderlessLocked
        case .ended:
            .ended
        }
    }

    private static func requiresFreshInvite(
        _ events: [ClipLiveShareNativeV3RoomLifecycleEvent]
    ) -> Bool {
        events.contains {
            if case .newInviteRequired = $0 {
                return true
            }
            return false
        }
    }

    private func applyLifecyclePhase(
        _ next: ClipLiveShareNativeV3RoomLifecyclePhase
    ) {
        switch next {
        case .active:
            phase = .live(
                elapsedSeconds: Date().timeIntervalSince(startedAt)
            )
        case .electing:
            phase = .electingCreator
        case .leaderlessLocked:
            phase = .leaderlessLocked
        case .ended:
            phase = .ended(message: nil)
        }
        scheduleMembershipRefreshIfNeeded()
        publish()
    }

    private func removeRemoteParticipant(
        _ participantID: ClipLiveShareNativeV3ParticipantID
    ) {
        remoteWindows.removeValue(forKey: participantID)?.tearDown()
        remotePresentations[participantID]?.tearDown()
        remotePresentations[participantID] = nil
        audioEnabled[participantID] = nil
        audioVolume[participantID] = nil
    }

    private func currentTimestamp() throws
        -> ClipLiveShareNativeTimestamp {
        try ClipLiveShareNativeTimestamp(date: now())
    }

    private func scheduleMembershipRefreshIfNeeded(
        retryDelay: Duration? = nil
    ) {
        membershipRefreshTask?.cancel()
        membershipRefreshTask = nil
        guard !isEnding,
              lifecycle.phase == .active,
              lifecycle.isLocalLeader else { return }

        let expectedRevision =
            lifecycle.signedMembership.snapshot.membershipRevision
        let delay = retryDelay ?? .seconds(
            MeshMembershipRefreshPolicy.delay(
                expiresAt:
                    lifecycle.signedMembership.snapshot.expiresAt.date,
                now: now(),
                leadTime: membershipRefreshLeadTime
            )
        )
        membershipRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await membershipRefreshSleeper.sleep(for: delay)
                guard !Task.isCancelled,
                      !isEnding,
                      lifecycle.phase == .active,
                      lifecycle.isLocalLeader,
                      lifecycle.signedMembership.snapshot.membershipRevision
                        == expectedRevision else { return }
                let renewed = try lifecycle.makeMembershipSnapshot(
                    participants:
                        lifecycle.signedMembership.snapshot.participants,
                    at: try currentTimestamp()
                )
                try await commitOrdinaryMembership(
                    renewed,
                    broadcasting: true
                )
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error(
                    "Could not refresh native-v3 membership: \(error.localizedDescription, privacy: .public)"
                )
                guard !isEnding,
                      lifecycle.phase == .active,
                      lifecycle.isLocalLeader else { return }
                scheduleMembershipRefreshIfNeeded(retryDelay: .seconds(5))
            }
        }
    }

    private func reconcileRemotePresentations() async {
        let membership = lifecycle.signedMembership.snapshot
        let remoteParticipants = membership.participants.filter {
            $0.participantID != localParticipantID
        }
        let remoteIDs = Set(remoteParticipants.map(\.participantID))
        for participantID in remoteWindows.keys where !remoteIDs.contains(
            participantID
        ) {
            remoteWindows.removeValue(forKey: participantID)?.tearDown()
            remotePresentations[participantID]?.tearDown()
            remotePresentations[participantID] = nil
            audioEnabled[participantID] = nil
            audioVolume[participantID] = nil
        }

        for participant in remoteParticipants {
            let participantID = participant.participantID
            if remotePresentations[participantID] == nil {
                remotePresentations[participantID] = RemoteParticipantPresentation(
                    participantNamespace: participant.identity.x963Representation
                )
            }
            if remoteWindows[participantID] == nil {
                installWindowCoordinator(for: participant)
            } else {
                remoteWindows[participantID]?.setOwnerName(
                    participant.displayName
                )
            }

            var presentation = remotePresentations[participantID]
                ?? RemoteParticipantPresentation(
                    participantNamespace: participant.identity.x963Representation
                )
            if let window = remoteWindows[participantID] {
                presentation.rememberLocalPresentation(window.windowSnapshots)
            }
            let authoritative = runtimeSnapshot?.sourceSnapshots[participantID]?
                .sources.map(nativeViewerSource) ?? []
            _ = presentation.replaceAuthoritativeSources(authoritative)
            for published in runtimeSnapshot?.sourceSnapshots[participantID]?
                .sources ?? [] {
                if let stream = try? await runtime.remoteVideoStream(
                    for: published.descriptor.stream,
                    participantID: participantID
                ) {
                    _ = presentation.upsertRemoteTrack(
                        stream,
                        streamID: published.descriptor.stream.id.rawValue
                    )
                }
            }
            remotePresentations[participantID] = presentation
            do {
                try remoteWindows[participantID]?.reconcile(
                    presentation.readySources
                )
            } catch {
                remoteWindows.removeValue(
                    forKey: participantID
                )?.tearDown()
                reportRemotePresentationFailure(
                    participantName: participant.displayName,
                    message: error.localizedDescription
                )
            }
            applyCollaborationOverlays(for: participantID)
        }
    }

    private func installWindowCoordinator(
        for participant: ClipLiveShareNativeV3Participant
    ) {
        let participantID = participant.participantID
        let coordinator = NativeViewerWindowCoordinator(
            ownerName: participant.displayName,
            ownerPublicIdentity: participant.identity.x963Representation,
            surfaceFactory: { [weak self] in
                let videoView = WebRTCRemoteVideoView(frame: .zero)
                let adapter = NativeViewerVideoSurfaceAdapter(
                    view: videoView,
                    bind: { [weak self, weak videoView] source in
                        guard
                            let self,
                            let videoView,
                            let stream =
                                remotePresentations[participantID]?
                                    .remoteTrack(
                                        forStreamID: source.streamID
                                    )
                        else {
                            throw NativeViewerSurfaceBindingError.unavailable(
                                source.streamID
                            )
                        }
                        videoView.bind(to: stream)
                    },
                    teardown: { [weak videoView] in
                        videoView?.teardown()
                    }
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
                runtimeSnapshot?.audioTrackIDs.isEmpty == false
            guard MeshRemoteWindowClosePolicy.shouldConfirmLeave(
                visibleRemoteWindowCount: visibleRemoteWindowCount,
                hasRemoteAudio: hasRemoteAudio
            ) else {
                return false
            }
            return confirmLeaveAfterLastRemoteWindowCloses()
        }
        coordinator.onLeaveRequested = { [weak self] in
            self?.requestLeaveRoom()
        }
        coordinator.onPresentationChanged = { [weak self] in self?.publish() }
        remoteWindows[participantID] = coordinator
        audioEnabled[participantID] = true
        audioVolume[participantID] = 1
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

    private func applyCollaborationOverlays(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) {
        guard
            let sources = runtimeSnapshot?.sourceSnapshots[participantID]?.sources,
            let windows = remoteWindows[participantID]
        else {
            return
        }
        for source in sources {
            let key = source.key
            let state = runtimeSnapshot?.collaboration[key]
            windows.setCollaborationOverlay(
                overlaySnapshot(state),
                sourceInstanceID: key.sourceInstanceID.rawValue
            )
            let mode: NativeViewerCollaborationInteractionMode
            if localInkEnabled {
                mode = .draw(collaborationConfiguration.inkColor)
            } else if localPointerVisible || localPingModeEnabled {
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
        let activeSources = await capturePublisher.activeSources
        let activeIDs = Set(
            activeSources.map {
                $0.published.key.sourceInstanceID.rawValue
            }
        )
        localSourceOverlays.retainSources(activeIDs)
        for active in activeSources {
            let key = active.published.key
            let snapshot = overlaySnapshot(
                runtimeSnapshot?.collaboration[key]
            )
            let isVisible =
                !snapshot.pointers.isEmpty
                    || !snapshot.pings.isEmpty
                    || !snapshot.strokes.isEmpty
            guard
                let frame = MeshLocalSourceOverlayGeometry.appKitFrame(
                    for: active.capture.source,
                    screenFrames: Self.screenFrames(),
                    quartzWindowFrame: Self.quartzWindowFrame(
                        for: active.capture.source
                    )
                )
            else {
                localSourceOverlays.remove(
                    sourceID: key.sourceInstanceID.rawValue
                )
                continue
            }
            localSourceOverlays.update(
                sourceID: key.sourceInstanceID.rawValue,
                sourceFrame: frame,
                snapshot: snapshot,
                isVisible: isVisible
            )
        }
    }

    private func refreshLocalSharingControls() {
        guard !isEnding, isActive else {
            focusedWindowControl.hide()
            localStatusHUD.hide()
            return
        }

        if
            let snapshot =
                localPublicationController.focusedWindowControlSnapshot,
            let visibleFrame = Self.visibleScreenFrame(
                containing: snapshot.appKitFrame
            )
        {
            focusedWindowControl.show(
                snapshot: snapshot,
                visibleScreenFrame: visibleFrame
            )
        } else {
            focusedWindowControl.hide()
        }

        guard
            let visibleFrame =
                NSScreen.main?.visibleFrame
                    ?? NSScreen.screens.first?.visibleFrame
        else {
            localStatusHUD.hide()
            return
        }
        let localStatus = localPublicationController.localStatusSnapshot
        localStatusHUD.show(
            snapshot: MeshLocalStatusHUDSnapshot(
                sourceStatuses: localStatus.windowSourceStatuses,
                participantCount:
                    lifecycle.signedMembership.snapshot.participants.count,
                fullscreen: localStatus.fullscreen
            ),
            visibleScreenFrame: visibleFrame
        )
    }

    private static func visibleScreenFrame(
        containing frame: CGRect
    ) -> CGRect? {
        NSScreen.screens.max {
            intersectionArea($0.frame, frame)
                < intersectionArea($1.frame, frame)
        }?.visibleFrame
    }

    private static func intersectionArea(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    nonisolated private static func quartzWindowFrame(
        for source: LiveShareSource
    ) -> CGRect? {
        guard case let .window(window) = source,
              let values = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow, .excludeDesktopElements],
                CGWindowID(window.id.rawValue)
              ) as? [[String: Any]],
              let bounds = values.first?[kCGWindowBounds as String]
                as? [String: Any]
        else {
            return nil
        }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
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

    private func collaborationActions(
        for sourceKey: ClipLiveShareNativeV3SourceKey
    ) -> NativeViewerCollaborationActions {
        NativeViewerCollaborationActions(
            pointerChanged: { [weak self] position in
                guard let self, localPointerVisible else { return }
                sendCollaboration(sourceKey) { context in
                    .pointer(.init(context: context, position: position))
                }
            },
            ping: { [weak self] position in
                guard let self, localPingModeEnabled else { return }
                sendCollaboration(sourceKey) { context in
                    try self.collaborationConfiguration.ping(
                        context: context,
                        position: position
                    )
                }
            },
            strokeBegan: { [weak self] strokeID, point in
                guard let self, localInkEnabled else { return }
                sendCollaboration(sourceKey) { context in
                    try self.collaborationConfiguration.strokeBegin(
                        context: context,
                        strokeID: strokeID,
                        point: point
                    )
                }
            },
            strokePoints: { [weak self] strokeID, points in
                guard let self, localInkEnabled else { return }
                sendCollaboration(sourceKey) { context in
                    .strokePoints(try .init(
                        context: context,
                        strokeID: strokeID,
                        points: points
                    ))
                }
            },
            strokeEnded: { [weak self] strokeID in
                guard let self, localInkEnabled else { return }
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
        do {
            let now = try ClipLiveShareNativeTimestamp(date: Date())
            let sequence =
                (collaborationSequenceBySource[sourceKey] ?? 0) + 1
            collaborationSequenceBySource[sourceKey] = sequence
            let context = try ClipLiveShareNativeV3CollaborationContext(
                sessionID:
                    lifecycle.sessionID,
                participantID: localParticipantID,
                sourceKey: sourceKey,
                sequence: sequence,
                sentAt: now
            )
            let event = try makeEvent(context)
            Task { [weak runtime] in
                try? await runtime?.broadcastCollaboration(event)
            }
        } catch {
            Self.logger.error(
                "Could not create collaboration event: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func overlaySnapshot(
        _ state: ClipLiveShareNativeV3CollaborationState?
    ) -> NativeViewerCollaborationOverlaySnapshot {
        guard let state else { return .empty }
        let names = Dictionary(
            uniqueKeysWithValues:
                lifecycle.signedMembership.snapshot.participants.map {
                    ($0.participantID, $0.displayName)
                }
        )
        return NativeViewerCollaborationOverlaySnapshot(
            pointers: state.pointers.values.map {
                NativeViewerCollaborationPointer(
                    participantID: $0.participantID,
                    participantName:
                        names[$0.participantID] ?? String(localized: "Participant"),
                    color: color(for: $0.participantID),
                    position: $0.position
                )
            },
            pings: state.pings.enumerated().map { index, ping in
                NativeViewerCollaborationPing(
                    id: deterministicPingID(
                        participantID: ping.participantID,
                        index: index
                    ),
                    participantID: ping.participantID,
                    color: color(for: ping.participantID),
                    position: ping.position
                )
            },
            strokes: state.strokes.values.map {
                NativeViewerCollaborationStroke(
                    participantID: $0.participantID,
                    strokeID: $0.strokeID,
                    color: $0.color,
                    points: $0.points
                )
            }
        )
    }

    private func color(
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) -> ClipLiveShareNativeV3CollaborationColor {
        guard
            let identity = lifecycle.signedMembership.snapshot.participants
                .first(where: {
                    $0.participantID == participantID
                })?.identity.x963Representation
        else {
            assertionFailure(
                "Collaboration state survived its authenticated participant"
            )
            return try! .init(red: 160, green: 160, blue: 160)
        }
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

    private func nativeViewerSource(
        _ published: ClipLiveShareNativeV3PublishedSource
    ) -> NativeViewerSourceSnapshot {
        let descriptor = published.descriptor
        return NativeViewerSourceSnapshot(
            sourceInstanceID: descriptor.sourceInstanceID.rawValue,
            streamID: descriptor.stream.id.rawValue,
            applicationName: descriptor.stream.appName,
            windowName: descriptor.stream.windowName,
            pixelSize: CGSize(
                width: descriptor.stream.width,
                height: descriptor.stream.height
            ),
            sourcePointSize: descriptor.stream.sourcePointSize,
            isFocused: descriptor.stream.focused,
            isConnected: true,
            stateRevision:
                runtimeSnapshot?.sourceSnapshots[
                    published.key.ownerParticipantID
                ]?.sourceRevision.rawValue ?? 1
        )
    }

    private func makePresentationActions() -> MeshRoomPresentationActions {
        MeshRoomPresentationActions(
            copyText: { value in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            },
            setAccessWordEnabled: { [weak self] enabled in
                self?.localPresentation.accessWordEnabled = enabled
                self?.actions.setAccessWordEnabled(enabled)
                self?.publish()
            },
            replaceAccessWord: { [weak self] in
                self?.actions.replaceAccessWord()
            },
            requestNewInvite: { [weak self] in
                self?.actions.requestNewInvite()
            },
            approveAdmission: { [weak self] in
                self?.actions.approveAdmission($0)
            },
            denyAdmission: { [weak self] in
                self?.actions.denyAdmission($0)
            },
            removeParticipant: { [weak self] in
                self?.requestRemoveParticipant($0)
            },
            shareFocusedWindow: { [weak self] in
                self?.localPublicationController.shareFocusedWindow()
            },
            shareWindow: { [weak self] in
                self?.localPublicationController.shareWindow(
                    identifier: $0
                )
            },
            stopLocalSource: { [weak self] rawValue in
                guard
                    let id = try? ClipLiveShareSourceInstanceID(
                        rawValue: rawValue
                    )
                else { return }
                self?.localPublicationController.stopSource(id)
            },
            setFullscreenEnabled: { [weak self] in
                self?.localPublicationController.setFullscreenEnabled($0)
            },
            setQuality: { [weak self] in self?.updateSettings(quality: $0) },
            setFrameRate: { [weak self] in
                self?.updateSettings(frameRate: $0)
            },
            setCodec: { [weak self] in self?.updateSettings(codec: $0) },
            setColorMode: { [weak self] in
                self?.updateSettings(colorMode: $0)
            },
            setSystemAudioEnabled: { [weak self] in
                self?.updateSettings(systemAudioEnabled: $0)
            },
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
            setAdvancedVideoSettings: { [weak self] codec, advanced in
                self?.updateSettings(
                    advancedVideoSettings: self?.localPresentation.settings
                        .advancedVideoSettings.replacing(
                            codec: codec,
                            settings: advanced
                        )
                )
            },
            setAutoShareEnabled: { [weak self] in
                self?.updateSettings(autoShareFocusedWindows: $0)
            },
            stopLocalMedia: { [weak self] in
                self?.localPublicationController.stopAllMedia()
            },
            setParticipantAudioEnabled: { [weak self] rawID, enabled in
                self?.setParticipantAudio(rawID, enabled: enabled)
            },
            setParticipantVolume: { [weak self] rawID, volume in
                self?.setParticipantVolume(rawID, volume: volume)
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
                self?.participantID(rawID).flatMap {
                    self?.remoteWindows[$0]
                }?.bringAllToFront()
            },
            bringAllRemoteWindowsToFront: { [weak self] in
                self?.remoteWindows.values.forEach { $0.bringAllToFront() }
            },
            setLocalPointerVisible: { [weak self] enabled in
                self?.localPointerVisible = enabled
                if !enabled {
                    self?.broadcastPointerHidden()
                }
                self?.refreshCollaborationInteractions()
            },
            setLocalPingModeEnabled: { [weak self] enabled in
                self?.localPingModeEnabled = enabled
                self?.refreshCollaborationInteractions()
            },
            setLocalInkEnabled: { [weak self] enabled in
                self?.localInkEnabled = enabled
                self?.refreshCollaborationInteractions()
            },
            clearAnnotations: { [weak self] in self?.clearAnnotations() },
            retry: { [weak self] in self?.start() },
            leaveRoom: { [weak self] in
                self?.requestLeaveRoom()
            },
            endRoomForEveryone: { [weak self] in
                self?.requestEndRoomForEveryone()
            }
        )
    }

    private func requestLeaveRoom() {
        guard !isEnding, !isLeavePending else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await beginLeaveRoom()
            } catch {
                isLeavePending = false
                fail(error.localizedDescription)
            }
        }
    }

    /// Begins an authenticated departure but deliberately does not tear down
    /// media. An ordinary member waits for the leader's newer membership;
    /// a leader waits for the certified successor's bridge membership. This
    /// keeps every surviving participant on one authoritative room history.
    private func beginLeaveRoom() async throws {
        guard !isEnding else { return }
        guard !isLeavePending else { return }
        isLeavePending = true
        let now = try currentTimestamp()
        if lifecycle.isLocalLeader {
            if lifecycle.participantIDs.count == 1 {
                let events = try lifecycle.endRoomForEveryone(at: now)
                try await applyLifecycleEvents(events)
                return
            }
            let events = try lifecycle.beginGracefulLeaderLeave(at: now)
            try await applyLifecycleEvents(events)
            return
        }

        let signed = try lifecycle.makeParticipantLeaveRequest(at: now)
        phase = .ending
        publish()
        try await runtime.sendRoomControl(.participantLeaveRequest(signed))
        // Only applying a newer leader-signed membership without this
        // participant allows the normal teardown below to begin.
    }

    private func requestRemoveParticipant(_ rawParticipantID: String) {
        guard !isEnding,
              lifecycle.isLocalLeader,
              let participantID = participantID(rawParticipantID),
              participantID != localParticipantID,
              lifecycle.participantIDs.contains(participantID) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let remaining = lifecycle.signedMembership.snapshot
                    .participants.filter {
                        $0.participantID != participantID
                    }
                let membership = try lifecycle.makeMembershipSnapshot(
                    participants: remaining,
                    at: try currentTimestamp()
                )
                // Delivery precedes the local runtime commit, because the
                // commit tears down the removed participant's exact link.
                try await commitOrdinaryMembership(
                    membership,
                    broadcasting: true
                )
                actions.removeParticipant(rawParticipantID)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func requestEndRoomForEveryone() {
        guard !isEnding, lifecycle.isLocalLeader else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let events = try lifecycle.endRoomForEveryone(
                    at: try currentTimestamp()
                )
                try await applyLifecycleEvents(events)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func setParticipantAudio(_ rawID: String, enabled: Bool) {
        guard let id = participantID(rawID) else { return }
        audioEnabled[id] = enabled
        Task { [weak runtime] in
            try? await runtime?.setParticipantAudioEnabled(
                enabled,
                participantID: id
            )
        }
        publish()
    }

    private func setParticipantVolume(_ rawID: String, volume: Double) {
        guard let id = participantID(rawID) else { return }
        let value = min(max(volume, 0), 1)
        audioVolume[id] = value
        Task { [weak runtime] in
            try? await runtime?.setParticipantVolume(
                value,
                participantID: id
            )
        }
        publish()
    }

    private func participantID(
        _ rawValue: String
    ) -> ClipLiveShareNativeV3ParticipantID? {
        try? ClipLiveShareNativeV3ParticipantID(rawValue: rawValue)
    }

    private func participantWindows(
        _ key: MeshRoomSourceKey
    ) -> NativeViewerWindowCoordinator? {
        guard let id = participantID(key.participantID) else { return nil }
        return remoteWindows[id]
    }

    private func refreshCollaborationInteractions() {
        for participantID in remoteWindows.keys {
            applyCollaborationOverlays(for: participantID)
        }
        publish()
    }

    private func clearAnnotations() {
        for key in runtimeSnapshot?.collaboration.keys.map({ $0 }) ?? [] {
            sendCollaboration(key) { context in
                .clear(try .init(
                    context: context,
                    clearEpoch: UInt64(Date().timeIntervalSince1970 * 1_000),
                    scope: key.ownerParticipantID == self.localParticipantID
                        ? .source
                        : .participant
                ))
            }
        }
    }

    private func broadcastPointerHidden() {
        let keys = runtimeSnapshot?.sourceSnapshots.values.flatMap(\.sources)
            .map(\.key) ?? []
        for key in keys where key.ownerParticipantID != localParticipantID {
            sendCollaboration(key) { context in
                .pointer(.init(context: context, position: nil))
            }
        }
    }

    private func publishNativeCursor() async -> Int {
        guard let snapshot = localPublicationController.cursorSnapshot else {
            return 30
        }
        let key = ClipLiveShareNativeV3SourceKey(
            ownerParticipantID: localParticipantID,
            sourceInstanceID: snapshot.sourceInstanceID
        )
        let nextSequence =
            nativeCursorSequenceBySource[key, default: 0] &+ 1
        nativeCursorSequenceBySource[key] = nextSequence
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
                sessionID: lifecycle.sessionID,
                participantID: localParticipantID,
                sourceKey: key,
                streamID: snapshot.streamID,
                sequence: nextSequence,
                position: position
            )
            try await runtime.sendRoomControl(.sourceCursor(cursor))
        } catch {
            Self.logger.debug(
                "Could not publish native-v3 cursor context: \(error.localizedDescription, privacy: .public)"
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
        let current = localPresentation.settings
        localPresentation.settings = LiveShareSettingsViewSnapshot(
            quality: quality ?? current.quality,
            frameRate: frameRate ?? current.frameRate,
            codec: codec.map {
                LiveShareCodecViewSnapshot(
                    codec: $0,
                    acceleration: current.codec.acceleration
                )
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
                autoShareFocusedWindows
                    ?? current.autoShareFocusedWindows,
            canChangeQuality: current.canChangeQuality,
            canChangeFrameRate: current.canChangeFrameRate,
            availableFrameRates: current.availableFrameRates,
            canChangeCodec: current.canChangeCodec,
            canChangeColorMode: current.canChangeColorMode,
            canChangeSystemAudio: current.canChangeSystemAudio,
            canChangeAudioExclusions: current.canChangeAudioExclusions,
            canChangeCursorUpdateRate:
                current.canChangeCursorUpdateRate,
            canChangePrioritizeFocusedWindow:
                current.canChangePrioritizeFocusedWindow,
            canChangeMode: current.canChangeMode,
            canChangeAutoShare: current.canChangeAutoShare
        )
        localPublicationController.updateSettings(
            localPresentation.settings
        )
        publish()
    }

    private func makePresentationSnapshot() -> MeshRoomViewSnapshot {
        let membership = lifecycle.signedMembership.snapshot
        let local = membership.participants.first {
            $0.participantID == localParticipantID
        }
        let localSources = localPublicationController.activeSourceSnapshots
        let remotes = membership.participants
            .filter { $0.participantID != localParticipantID }
            .map(remoteParticipantSnapshot)
        let linkSnapshots = Dictionary(
            uniqueKeysWithValues: (runtimeSnapshot?.links.links ?? []).map {
                ($0.remoteParticipantID, $0)
            }
        )
        let peerDiagnostics = membership.participants.compactMap {
            participant -> MeshRoomPeerDiagnosticsSnapshot? in
            guard participant.participantID != localParticipantID else {
                return nil
            }
            let link = linkSnapshots[participant.participantID]
            let stats = runtimeSnapshot?.statistics[participant.participantID]
            return MeshRoomPeerDiagnosticsSnapshot(
                participantID: participant.participantID.rawValue,
                displayName: participant.displayName,
                route: meshRoute(
                    connectionState: link?.connectionState,
                    route: link?.route
                ),
                roundTripMilliseconds:
                    stats?.transport.currentRoundTripTimeMilliseconds,
                packetsLost: stats?.transport.packetsLost ?? 0
            )
        }
        let outgoingDiagnostics = membership.participants.flatMap {
            participant -> [MeshRoomMediaDiagnosticsSnapshot] in
            guard participant.participantID != localParticipantID else {
                return []
            }
            return mediaDiagnostics(
                participantID: participant.participantID,
                participantName: participant.displayName,
                direction: .outgoing
            )
        }
        let collaborationValues = runtimeSnapshot.map {
            Array($0.collaboration.values)
        } ?? []
        return MeshRoomViewSnapshot(
            phase: presentationPhase,
            roomName: localPresentation.roomName,
            localParticipant: .init(
                id: localParticipantID.rawValue,
                displayName:
                    local?.displayName ?? String(localized: "This Mac"),
                deviceName: Host.current().localizedName
            ),
            foundingCreatorParticipantID:
                lifecycle.authorityChain.foundingCreatorParticipantID.rawValue,
            currentLeaderParticipantID:
                lifecycle.currentLeaderParticipantID.rawValue,
            invite: localPresentation.invite,
            accessWordEnabled: localPresentation.accessWordEnabled,
            accessWord: localPresentation.accessWord,
            canChangeAccessWord: localPresentation.canChangeAccessWord,
            pendingAdmissions: localPresentation.pendingAdmissions,
            localSources: localSources,
            fullscreen: localPresentation.fullscreen,
            canShareFocusedWindow:
                localPresentation.canShareFocusedWindow,
            focusedWindowDescription:
                localPresentation.focusedWindowDescription,
            availableWindows: localPresentation.availableWindows,
            canAddWindow: localPresentation.canAddWindow,
            settings: localPresentation.settings,
            remoteParticipants: remotes,
            outgoingDiagnostics: outgoingDiagnostics,
            peerDiagnostics: peerDiagnostics,
            collaboration: .init(
                isLocalPointerVisible: localPointerVisible,
                isLocalPingModeEnabled: localPingModeEnabled,
                isLocalInkEnabled: localInkEnabled,
                activePointerCount:
                    collaborationValues.reduce(0) {
                        $0 + $1.pointers.count
                    },
                annotationStrokeCount:
                    collaborationValues.reduce(0) {
                        $0 + $1.strokes.count
                    },
                canClearAnnotations:
                    runtimeSnapshot?.collaboration.isEmpty == false
            ),
            statusNotice: localStatusNotice,
            canLeaveRoom:
                !isLeavePending && !presentationPhase.isTerminal,
            canEndRoom:
                lifecycle.isLocalLeader
                    && !presentationPhase.isTerminal
        )
    }

    private var presentationPhase: MeshRoomPhase {
        if case .live = phase {
            return .live(
                elapsedSeconds: Date().timeIntervalSince(startedAt)
            )
        }
        return phase
    }

    private func remoteParticipantSnapshot(
        _ participant: ClipLiveShareNativeV3Participant
    ) -> MeshRoomRemoteParticipantSnapshot {
        let id = participant.participantID
        let link = runtimeSnapshot?.links.links.first {
            $0.remoteParticipantID == id
        }
        let windows = remoteWindows[id]?.windowSnapshots ?? []
        let sources = windows.map { window in
            MeshRoomRemoteSourceSnapshot(
                id: window.source.sourceInstanceID,
                applicationName: window.source.applicationName,
                windowTitle: window.source.windowName,
                pixelWidth: Int(window.source.pixelSize.width),
                pixelHeight: Int(window.source.pixelSize.height),
                isVisible: window.isVisible,
                isFocused: window.source.isFocused,
                isConnected: window.source.isConnected,
                scaleMode: window.scaleMode,
                isFullScreen: window.isFullScreen
            )
        }
        let diagnostics = mediaDiagnostics(
            participantID: id,
            participantName: participant.displayName,
            direction: .incoming
        )
        return MeshRoomRemoteParticipantSnapshot(
            id: id.rawValue,
            displayName: participant.displayName,
            route: meshRoute(
                connectionState: link?.connectionState,
                route: link?.route
            ),
            connectedDuration: link?.isReady == true
                ? Date().timeIntervalSince(startedAt)
                : nil,
            sources: sources,
            systemAudioAvailable:
                runtimeSnapshot?.audioTrackIDs[id] != nil,
            systemAudioEnabled: audioEnabled[id] ?? true,
            volume: audioVolume[id] ?? 1,
            diagnostics: diagnostics
        )
    }

    private func mediaDiagnostics(
        participantID: ClipLiveShareNativeV3ParticipantID,
        participantName: String,
        direction: MeshRoomMediaDiagnosticsSnapshot.Direction
    ) -> [MeshRoomMediaDiagnosticsSnapshot] {
        guard let peer = runtimeSnapshot?.statistics[participantID] else {
            return []
        }
        let sourceOwnerID =
            direction == .outgoing ? localParticipantID : participantID
        let publishedByTrack = Dictionary(
            uniqueKeysWithValues:
                (runtimeSnapshot?.sourceSnapshots[sourceOwnerID]?.sources ?? [])
                .map {
                    (
                        $0.descriptor.stream.mediaTrackID.rawValue,
                        $0.descriptor.stream
                    )
                }
        )
        return peer.transport.videoSources.compactMap { source in
            let expectedDirection:
                ClipLiveShareNativeV3MediaStatisticsDirection =
                    direction == .outgoing ? .outgoing : .incoming
            guard source.direction == expectedDirection else { return nil }
            let rateKey = MeshRoomMediaCounterKey(
                participantID: participantID.rawValue,
                trackIdentifier: source.trackIdentifier,
                direction: direction
            )
            let rate = mediaRateEstimator.rates[rateKey]
            let descriptor = publishedByTrack[source.trackIdentifier]
            let sourceTitle: String
            if let descriptor, !descriptor.windowName.isEmpty {
                sourceTitle = descriptor.windowName
            } else if let descriptor, !descriptor.appName.isEmpty {
                sourceTitle = descriptor.appName
            } else {
                sourceTitle = String(localized: "Shared Window")
            }
            let displayName =
                direction == .outgoing
                    ? "\(sourceTitle) → \(participantName)"
                    : sourceTitle
            return MeshRoomMediaDiagnosticsSnapshot(
                id:
                    "\(participantID.rawValue)-\(direction)-\(source.trackIdentifier)",
                sourceName: displayName,
                direction: direction,
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
                    source.processingLatencyMilliseconds
            )
        }
        .sorted { lhs, rhs in
            if lhs.sourceName != rhs.sourceName {
                return lhs.sourceName.localizedStandardCompare(
                    rhs.sourceName
                ) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private func meshRoute(
        connectionState: WebRTCPeerConnectionState?,
        route: WebRTCConnectionRoute?
    ) -> MeshRoomConnectionRoute {
        if connectionState == nil {
            // Before first readiness the transport is still being created.
            // Once this coordinator has reached live, an absent retained link
            // means that exact participant edge is quarantined/disconnected.
            return hasReachedLive ? .disconnected : .connecting
        }
        guard connectionState == .connected else {
            return .disconnected
        }
        switch route {
        case .direct:
            return .direct
        case .relay:
            return .turn
        case .unknown, nil:
            return .connecting
        }
    }

    private func publish() {
        let snapshot = makePresentationSnapshot()
        presentationModel.update(snapshot)
        acceptanceReporter?.record(
            roomName: localPresentation.roomName,
            phase: phase,
            localParticipantID: localParticipantID,
            localIdentitySigner: localIdentitySigner,
            signedMembership: lifecycle.signedMembership,
            leadershipTerm: lifecycle.currentTerm,
            runtimeSnapshot: runtimeSnapshot,
            localSystemAudioTrackIsEnabled:
                mediaFactory.isSystemAudioEnabled,
            statusNotice: localStatusNotice
        )
    }

    private func fail(_ message: String) {
        guard !isEnding else { return }
        eventTask?.cancel()
        statisticsTask?.cancel()
        leaderLossTask?.cancel()
        membershipRefreshTask?.cancel()
        localOverlayTask?.cancel()
        captureFailureTask?.cancel()
        collaborationExpiryTask?.cancel()
        nativeCursorTask?.cancel()
        eventTask = nil
        eventTaskGeneration = nil
        statisticsTask = nil
        leaderLossTask = nil
        membershipRefreshTask = nil
        localOverlayTask = nil
        captureFailureTask = nil
        collaborationExpiryTask = nil
        nativeCursorTask = nil
        phase = .failed(message: message)
        focusedWindowControl.tearDown()
        localStatusHUD.tearDown()
        onMenuBarStatusChanged(.failed)
        publish()
    }

    private func handleLocalCaptureFailure(
        _ failure: MeshParticipantCaptureFailure
    ) {
        switch failure {
        case let .source(sourceInstanceID, message):
            localPublicationController.captureSourceFailed(
                sourceInstanceID,
                message: message
            )
        case let .systemAudio(message):
            localPublicationController.systemAudioCaptureFailed(
                message: message
            )
        }
    }

    private func reportLocalPublicationFailure(_ message: String) {
        guard !isEnding else { return }
        localStatusNotice = .init(
            title: String(localized: "Sharing Issue"),
            message: message,
            severity: .warning
        )
        Self.logger.error(
            "Native-v3 local publication failed: \(message, privacy: .public)"
        )
        publish()
    }

    private func reportRemotePresentationFailure(
        participantName: String,
        message: String
    ) {
        guard !isEnding else { return }
        localStatusNotice = .init(
            title: String(localized: "Shared Window Issue"),
            message: String(
                localized:
                    "Could not show \(participantName)’s shared window. \(message)"
            ),
            severity: .warning
        )
        Self.logger.error(
            "Native-v3 remote presentation failed for \(participantName, privacy: .public): \(message, privacy: .public)"
        )
        publish()
    }

    private func tearDownRemotePresentations() {
        for coordinator in remoteWindows.values {
            coordinator.tearDown()
        }
        remoteWindows.removeAll()
        for key in remotePresentations.keys {
            remotePresentations[key]?.tearDown()
        }
        remotePresentations.removeAll()
    }

    private func endSession(notifyApplication: Bool) async {
        if isEnding {
            await waitForShutdown()
            return
        }
        isEnding = true
        phase = .ending
        publish()
        eventTask?.cancel()
        statisticsTask?.cancel()
        leaderLossTask?.cancel()
        membershipRefreshTask?.cancel()
        localOverlayTask?.cancel()
        captureFailureTask?.cancel()
        collaborationExpiryTask?.cancel()
        nativeCursorTask?.cancel()
        eventTask = nil
        statisticsTask = nil
        leaderLossTask = nil
        membershipRefreshTask = nil
        localOverlayTask = nil
        captureFailureTask = nil
        collaborationExpiryTask = nil
        nativeCursorTask = nil
        await localPublicationController.stop()
        await capturePublisher.stopAll()
        await runtime.close()
        mediaFactory.close()
        tearDownRemotePresentations()
        localSourceOverlays.tearDown()
        focusedWindowControl.tearDown()
        localStatusHUD.tearDown()
        phase = .ended(message: nil)
        publish()
        markShutdownComplete()
        if notifyApplication, !didNotifyEnd {
            didNotifyEnd = true
            onSessionEnded()
        }
    }

    private func waitForShutdown() async {
        guard !hasCompletedShutdown else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    private func markShutdownComplete() {
        guard !hasCompletedShutdown else { return }
        hasCompletedShutdown = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

enum MeshMembershipRefreshPolicy {
    /// Membership credentials are intentionally short lived. Renew while the
    /// current leader still has ample delivery time, but never schedule a
    /// negative or zero delay after a machine wakes from sleep.
    static func delay(
        expiresAt: Date,
        now: Date,
        leadTime: TimeInterval
    ) -> TimeInterval {
        max(1, expiresAt.timeIntervalSince(now) - max(1, leadTime))
    }
}

enum MeshLocalSourceOverlayGeometry {
    struct ScreenFrame: Equatable {
        let displayID: CGDirectDisplayID
        let quartzFrame: CGRect
        let appKitFrame: CGRect
    }

    static func appKitFrame(
        for source: LiveShareSource,
        screenFrames: [ScreenFrame],
        quartzWindowFrame: CGRect?
    ) -> CGRect? {
        switch source {
        case let .fullscreen(display):
            return screenFrames.first {
                $0.displayID == display.id.rawValue
            }?.appKitFrame
        case .window:
            guard let quartzWindowFrame else { return nil }
            guard let screen = screenFrames.max(by: {
                intersectionArea(
                    $0.quartzFrame,
                    quartzWindowFrame
                ) < intersectionArea(
                    $1.quartzFrame,
                    quartzWindowFrame
                )
            }) else { return nil }
            return LiveShareWindowCoordinateConversion.appKitFrame(
                for: quartzWindowFrame,
                quartzDisplayFrame: screen.quartzFrame,
                appKitDisplayFrame: screen.appKitFrame
            )
        }
    }

    private static func intersectionArea(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> CGFloat {
        let value = lhs.intersection(rhs)
        guard !value.isNull, !value.isInfinite else { return 0 }
        return max(0, value.width) * max(0, value.height)
    }
}

private extension LiveShareAdvancedVideoSettings {
    func replacing(
        codec: LiveShareVideoCodec,
        settings: LiveShareCodecAdvancedSettings
    ) -> Self {
        var value = self
        value[codec] = settings.normalized(for: codec)
        return value
    }
}
