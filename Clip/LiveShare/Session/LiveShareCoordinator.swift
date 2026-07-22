import AppKit
import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import Combine
import Foundation
import OSLog

private struct LiveShareCaptureGeometrySnapshot {
    let sourceID: LiveShareSourceID
    let slot: Int
    let generation: UUID
    let descriptor: LiveShareCaptureDescriptor
}

struct LiveShareCaptureCursorMutation: Equatable {
    let sourceID: LiveShareSourceID
    let slot: Int
    let generation: UUID
    let descriptor: LiveShareCaptureDescriptor
}

/// Plans atomic ScreenCaptureKit cursor changes for the current track focus.
/// Turning the old cursor off before enabling the new one prevents two capture
/// streams from briefly embedding the same system cursor during a focus move.
enum LiveShareCaptureCursorPolicy {
    static func mutations(
        slots: LiveShareTrackSlotAllocation,
        descriptors: [LiveShareSourceID: LiveShareCaptureDescriptor],
        generations: [LiveShareSourceID: UUID]
    ) -> [LiveShareCaptureCursorMutation] {
        slots.activeSlots.compactMap { slot in
            guard let source = slot.source,
                  let current = descriptors[source.id],
                  let generation = generations[source.id] else { return nil }
            let requested = descriptor(
                current,
                focused: slot.isFocused
            )
            guard requested != current else { return nil }
            return LiveShareCaptureCursorMutation(
                sourceID: source.id,
                slot: slot.index,
                generation: generation,
                descriptor: requested
            )
        }.sorted { lhs, rhs in
            if lhs.descriptor.video.showsCursor
                != rhs.descriptor.video.showsCursor {
                return !lhs.descriptor.video.showsCursor
            }
            return lhs.slot < rhs.slot
        }
    }

    static func descriptor(
        _ descriptor: LiveShareCaptureDescriptor,
        focused: Bool
    ) -> LiveShareCaptureDescriptor {
        var video = descriptor.video
        video.showsCursor = focused
        return LiveShareCaptureDescriptor(
            source: descriptor.source,
            target: descriptor.target,
            sourcePixelWidth: descriptor.sourcePixelWidth,
            sourcePixelHeight: descriptor.sourcePixelHeight,
            video: video,
            stream: try! ClipLiveShareStreamDescriptor(
                id: descriptor.stream.id,
                mediaTrackID: descriptor.stream.mediaTrackID,
                active: descriptor.stream.active,
                focused: focused,
                appName: descriptor.stream.appName,
                windowName: descriptor.stream.windowName,
                width: descriptor.stream.width,
                height: descriptor.stream.height,
                order: descriptor.stream.order,
                sourcePointWidth: descriptor.stream.sourcePointWidth,
                sourcePointHeight: descriptor.stream.sourcePointHeight
            )
        )
    }
}

private struct LiveSharePendingViewerRoute {
    let routeID: ClipLiveShareRouteID
    let sessionID: ClipLiveShareSessionID
    let challenge: ClipLiveShareAuthChallenge
    let accessCode: String?
    var progress = LiveShareViewerAdmissionProgress()
}

enum LiveShareCaptureGeometryTransitionError: LocalizedError {
    case rollbackFailed(change: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case let .rollbackFailed(change, rollback):
            "Capture geometry update failed (\(change)) and its rollback failed (\(rollback))."
        }
    }
}

enum LiveShareCaptureGeometryFailurePolicy {
    static func requiresSessionFailure(after error: any Error) -> Bool {
        if error is LiveShareCaptureGeometryTransitionError { return true }
        guard let pipelineError = error as? LiveShareCapturePipelineError else {
            return false
        }
        if case .updateRollbackFailed = pipelineError { return true }
        return false
    }
}

@MainActor
final class LiveShareNativePeerHandoffController {
    typealias TimeoutHandler = @MainActor @Sendable (
        ClipLiveShareRouteID
    ) async -> Void

    private let timeout: Duration
    private let sleeper: any ClipLiveShareReconnectSleeper
    private let timeoutHandler: TimeoutHandler
    private var timeoutTasks: [ClipLiveShareRouteID: Task<Void, Never>] = [:]

    init(
        timeout: Duration = LiveShareNativeRendezvousLifecycle
            .routeAdmissionTimeout,
        sleeper: any ClipLiveShareReconnectSleeper =
            ContinuousClipLiveShareReconnectSleeper(),
        timeoutHandler: @escaping TimeoutHandler
    ) {
        self.timeout = timeout
        self.sleeper = sleeper
        self.timeoutHandler = timeoutHandler
    }

    /// Once a viewer is admitted, loss of the temporary rendezvous route is
    /// not a WebRTC failure. Keep the peer until its control DataChannel opens,
    /// WebRTC reports a terminal state, or the normal admission timeout fires.
    func admit(_ routeID: ClipLiveShareRouteID) {
        peerTerminated(routeID)
        timeoutTasks[routeID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await sleeper.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  timeoutTasks.removeValue(forKey: routeID) != nil else {
                return
            }
            await timeoutHandler(routeID)
        }
    }

    func signalingRouteClosed(_ routeID: ClipLiveShareRouteID) {
        // Deliberately no timer change. The rendezvous server cannot determine
        // whether the P2P channel opened, and its route-close callback can race
        // arbitrarily far ahead of WebRTC's host callback.
        _ = timeoutTasks[routeID]
    }

    func controlChannelOpened(_ routeID: ClipLiveShareRouteID) {
        peerTerminated(routeID)
    }

    func peerTerminated(_ routeID: ClipLiveShareRouteID) {
        timeoutTasks.removeValue(forKey: routeID)?.cancel()
    }

    func removeAll() {
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
    }

    func isAwaitingControlChannel(_ routeID: ClipLiveShareRouteID) -> Bool {
        timeoutTasks[routeID] != nil
    }
}

@MainActor
final class LiveShareNativeFriendCommitController {
    typealias CommitHandler = @MainActor (
        NativeFriendRecord,
        NativeFriendHandshakeJournalEntry?
    ) async throws -> Void

    private struct PendingAcceptance {
        let request: ClipLiveShareNativeFriendRequest
        let acceptance: ClipLiveShareNativeFriendAcceptance
        let sessionDescriptor: ClipLiveShareNativeSessionDescriptor
        let signedSessionDescriptor: ClipLiveShareSignedNativeSessionDescriptor?
        let signedRequest: ClipLiveShareSignedNativeFriendMessage?
        let signedAcceptance: ClipLiveShareSignedNativeFriendMessage?
        let encodedResponse: Data
        var acceptedAcknowledgementDigest: ClipLiveShareNativeDigest?
        var acceptedSignedAcknowledgement: ClipLiveShareSignedNativeFriendMessage?
        var didCommit = false
        var isCommitting = false
        var isHistoricalRecovery = false
        var encodedCommitReceipt: Data?
    }

    private let commit: CommitHandler
    private var pendingByViewerID: [String: PendingAcceptance] = [:]
    private var friendReplayGuard = try! ClipLiveShareNativeFriendReplayGuard()

    init(commit: @escaping @MainActor (NativeFriendRecord) async throws -> Void) {
        self.commit = { record, _ in try await commit(record) }
    }

    init(commitWithEvidence commit: @escaping CommitHandler) {
        self.commit = commit
    }

    func hasPendingAcceptance(for viewerID: String) -> Bool {
        pendingByViewerID[viewerID] != nil
    }

    func responseForVerifiedDuplicateRequest(
        _ request: ClipLiveShareNativeFriendRequest,
        viewerID: String
    ) -> Data? {
        guard let match = pendingByViewerID.first(where: {
            $0.value.request == request && !$0.value.didCommit
        }) else { return nil }
        let pending = match.value
        if match.key != viewerID {
            pendingByViewerID[match.key] = nil
            pendingByViewerID[viewerID] = pending
        }
        return pending.encodedResponse
    }

    func pendingResponse(for viewerID: String) -> Data? {
        pendingByViewerID[viewerID]?.encodedResponse
    }

    func stage(
        request: ClipLiveShareNativeFriendRequest,
        acceptance: ClipLiveShareNativeFriendAcceptance,
        sessionDescriptor: ClipLiveShareNativeSessionDescriptor,
        encodedResponse: Data,
        viewerID: String
    ) throws {
        guard pendingByViewerID[viewerID] == nil else {
            throw ClipLiveShareNativeV2Error.contextMismatch
        }
        pendingByViewerID[viewerID] = PendingAcceptance(
            request: request,
            acceptance: acceptance,
            sessionDescriptor: sessionDescriptor,
            signedSessionDescriptor: nil,
            signedRequest: nil,
            signedAcceptance: nil,
            encodedResponse: encodedResponse,
            acceptedAcknowledgementDigest: nil,
            acceptedSignedAcknowledgement: nil,
            encodedCommitReceipt: nil
        )
    }

    func stage(
        signedRequest: ClipLiveShareSignedNativeFriendMessage,
        signedAcceptance: ClipLiveShareSignedNativeFriendMessage,
        signedSessionDescriptor: ClipLiveShareSignedNativeSessionDescriptor,
        encodedResponse: Data,
        viewerID: String
    ) throws {
        guard case let .request(request) = signedRequest.message,
              case let .accepted(acceptance) = signedAcceptance.message else {
            throw ClipLiveShareNativeV2Error.contextMismatch
        }
        guard pendingByViewerID[viewerID] == nil else {
            throw ClipLiveShareNativeV2Error.contextMismatch
        }
        pendingByViewerID[viewerID] = PendingAcceptance(
            request: request,
            acceptance: acceptance,
            sessionDescriptor: signedSessionDescriptor.descriptor,
            signedSessionDescriptor: signedSessionDescriptor,
            signedRequest: signedRequest,
            signedAcceptance: signedAcceptance,
            encodedResponse: encodedResponse,
            acceptedAcknowledgementDigest: nil,
            acceptedSignedAcknowledgement: nil,
            encodedCommitReceipt: nil
        )
    }

    /// Restores a host-side post-ACK commit after process restart. The exact
    /// persisted ACK is admitted into the replay guard so only its exact
    /// retransmission can trigger receipt recovery on the new peer route.
    func restoreCommittedHandshake(
        _ entry: NativeFriendHandshakeJournalEntry,
        viewerID: String
    ) throws {
        guard entry.role == .accepter else {
            throw ClipLiveShareNativeV2Error.contextMismatch
        }
        let encodedAcceptance = try ClipLiveShareNativeV2MessageCodec.encode(
            entry.signedAcceptance
        )
        let encodedReceipt = try entry.signedCommitReceipt.map {
            try ClipLiveShareNativeV2MessageCodec.encode($0)
        }
        _ = try friendReplayGuard.acceptAcknowledgementIdempotently(
            entry.signedAcknowledgement,
            expectedIdentity: entry.request.requesterIdentity
        )
        pendingByViewerID[viewerID] = PendingAcceptance(
            request: entry.request,
            acceptance: entry.acceptance,
            sessionDescriptor: entry.signedSessionDescriptor.descriptor,
            signedSessionDescriptor: entry.signedSessionDescriptor,
            signedRequest: entry.signedRequest,
            signedAcceptance: entry.signedAcceptance,
            encodedResponse: encodedAcceptance,
            acceptedAcknowledgementDigest: entry.signedAcknowledgement.digest,
            acceptedSignedAcknowledgement: entry.signedAcknowledgement,
            didCommit: true,
            isCommitting: false,
            isHistoricalRecovery: true,
            encodedCommitReceipt: encodedReceipt
        )
    }

    struct CommitResult {
        let admission: ClipLiveShareNativeFriendAcknowledgementAdmission
        let request: ClipLiveShareNativeFriendRequest
        let acceptance: ClipLiveShareNativeFriendAcceptance
        let acknowledgement: ClipLiveShareNativeFriendAcceptanceAcknowledgement
        let acknowledgementDigest: ClipLiveShareNativeDigest
        let handshakeJournalEntry: NativeFriendHandshakeJournalEntry?
    }

    @discardableResult
    func receiveAcknowledgement(
        _ signed: ClipLiveShareSignedNativeFriendMessage,
        viewerID: String,
        at now: ClipLiveShareNativeTimestamp
    ) async throws -> CommitResult {
        guard var pending = pendingByViewerID[viewerID],
              case let .acceptanceAcknowledged(acknowledgement) =
                signed.message else {
            throw ClipLiveShareNativeV2Error.contextMismatch
        }
        // Validate all session/request/acceptance/time context before admitting
        // the signature digest into the replay guard.
        try acknowledgement.validate(
            for: pending.acceptance,
            request: pending.request,
            expectedSessionDescriptor: pending.sessionDescriptor,
            at: pending.isHistoricalRecovery
                ? acknowledgement.acknowledgedAt
                : now
        )
        if let acceptedSignedAcknowledgement = pending.acceptedSignedAcknowledgement,
           acceptedSignedAcknowledgement != signed {
            throw ClipLiveShareNativeV2Error.replayed
        }
        if let acceptedDigest = pending.acceptedAcknowledgementDigest,
           acceptedDigest != signed.digest {
            throw ClipLiveShareNativeV2Error.replayed
        }
        let admission = try friendReplayGuard
            .acceptAcknowledgementIdempotently(
                signed,
                expectedIdentity: pending.request.requesterIdentity
            )
        if pending.acceptedAcknowledgementDigest == nil {
            guard admission == .firstSeen else {
                throw ClipLiveShareNativeV2Error.replayed
            }
            pending.acceptedAcknowledgementDigest = signed.digest
            pending.acceptedSignedAcknowledgement = signed
            pendingByViewerID[viewerID] = pending
        }
        if pending.didCommit {
            guard admission == .duplicate else {
                throw ClipLiveShareNativeV2Error.replayed
            }
        } else {
            guard !pending.isCommitting else {
                throw LiveShareNativeRendezvousLifecycleError.operationSuperseded
            }
            pending.isCommitting = true
            pendingByViewerID[viewerID] = pending
            // A failed disk write leaves the pending acceptance uncommitted.
            // The exact duplicate ACK is then a safe retry trigger even though
            // its signed digest is already present in the replay guard.
            do {
                let journalEntry: NativeFriendHandshakeJournalEntry?
                if let signedSessionDescriptor = pending.signedSessionDescriptor,
                   let signedRequest = pending.signedRequest,
                   let signedAcceptance = pending.signedAcceptance {
                    journalEntry = try NativeFriendHandshakeJournalEntry(
                        role: .accepter,
                        signedSessionDescriptor: signedSessionDescriptor,
                        signedRequest: signedRequest,
                        signedAcceptance: signedAcceptance,
                        signedAcknowledgement: signed
                    )
                } else {
                    journalEntry = nil
                }
                try await commit(NativeFriendRecord(
                    identity: pending.request.requesterIdentity,
                    displayName: pending.request.requesterDeviceName,
                    deviceName: pending.request.requesterDeviceName,
                    endpoint: pending.request.requesterEndpoint,
                    rendezvousID: pending.request.requesterRendezvousID
                ), journalEntry)
            } catch {
                if var current = pendingByViewerID[viewerID],
                   current.acceptedAcknowledgementDigest == signed.digest {
                    current.isCommitting = false
                    pendingByViewerID[viewerID] = current
                }
                throw error
            }
            guard let current = pendingByViewerID[viewerID],
                  current.acceptedAcknowledgementDigest == signed.digest else {
                throw LiveShareNativeRendezvousLifecycleError.operationSuperseded
            }
            pending = current
            pending.didCommit = true
            pending.isCommitting = false
            pendingByViewerID[viewerID] = pending
        }
        return CommitResult(
            admission: admission,
            request: pending.request,
            acceptance: pending.acceptance,
            acknowledgement: acknowledgement,
            acknowledgementDigest: signed.digest,
            handshakeJournalEntry: try makeJournalEntry(
                pending: pending,
                signedAcknowledgement: signed
            )
        )
    }

    func storeCommitReceipt(
        _ data: Data,
        acknowledgementDigest: ClipLiveShareNativeDigest,
        viewerID: String
    ) throws {
        guard var pending = pendingByViewerID[viewerID],
              pending.didCommit,
              pending.acceptedAcknowledgementDigest == acknowledgementDigest
        else { throw ClipLiveShareNativeV2Error.contextMismatch }
        pending.encodedCommitReceipt = data
        pendingByViewerID[viewerID] = pending
    }

    func commitReceipt(for viewerID: String) -> Data? {
        pendingByViewerID[viewerID]?.encodedCommitReceipt
    }

    func restoredCommitResult(for viewerID: String) throws -> CommitResult {
        guard let pending = pendingByViewerID[viewerID],
              pending.didCommit,
              let signedAcknowledgement = pending.acceptedSignedAcknowledgement,
              case let .acceptanceAcknowledged(acknowledgement) =
                signedAcknowledgement.message else {
            throw ClipLiveShareNativeV2Error.contextMismatch
        }
        return CommitResult(
            admission: .duplicate,
            request: pending.request,
            acceptance: pending.acceptance,
            acknowledgement: acknowledgement,
            acknowledgementDigest: signedAcknowledgement.digest,
            handshakeJournalEntry: try makeJournalEntry(
                pending: pending,
                signedAcknowledgement: signedAcknowledgement
            )
        )
    }

    func removeViewer(_ viewerID: String) {
        // An uncommitted acceptance is retained until this share ends so a
        // requester that restarted after staging its ACK can reconnect and
        // replay the exact request on a new peer route.
        if pendingByViewerID[viewerID]?.didCommit == true {
            pendingByViewerID[viewerID] = nil
        }
    }

    func removeAll() {
        pendingByViewerID.removeAll()
        friendReplayGuard = try! ClipLiveShareNativeFriendReplayGuard()
    }

    private func makeJournalEntry(
        pending: PendingAcceptance,
        signedAcknowledgement: ClipLiveShareSignedNativeFriendMessage
    ) throws -> NativeFriendHandshakeJournalEntry? {
        guard let signedSessionDescriptor = pending.signedSessionDescriptor,
              let signedRequest = pending.signedRequest,
              let signedAcceptance = pending.signedAcceptance else {
            return nil
        }
        return try NativeFriendHandshakeJournalEntry(
            role: .accepter,
            signedSessionDescriptor: signedSessionDescriptor,
            signedRequest: signedRequest,
            signedAcceptance: signedAcceptance,
            signedAcknowledgement: signedAcknowledgement
        )
    }
}

enum LiveShareNativeViewerApprovalPolicy {
    static func permitsAfterModal(
        userAllowed: Bool,
        expectedIdentity: ClipLiveShareIdentityPublicKey,
        currentRecords: [NativeFriendRecord]
    ) -> Bool {
        userAllowed && currentRecords.contains {
            $0.identity == expectedIdentity && $0.trustState == .trusted
        }
    }
}

protocol LiveShareNativeRendezvousHostTransporting: Sendable {
    func eventStream() async -> AsyncStream<ClipNativeRendezvousEvent>
    func attach(_ owner: ClipNativeRendezvousOwner) async throws
    func publish(descriptor: Data) async throws
    func stopSharing() async throws
    func send(_ payload: Data, to routeID: String) async throws
    func closeRoute(_ routeID: String, reason: String?) async
    func tearDown(removeRendezvous: Bool) async
}

private struct LiveShareNativeRendezvousHostTransportAdapter:
    LiveShareNativeRendezvousHostTransporting
{
    let transport: ClipNativeRendezvousHostTransport

    init(transport: ClipNativeRendezvousHostTransport = .init()) {
        self.transport = transport
    }

    func eventStream() async -> AsyncStream<ClipNativeRendezvousEvent> {
        await transport.events()
    }

    func attach(_ owner: ClipNativeRendezvousOwner) async throws {
        _ = try await transport.attachHost(owner)
    }

    func publish(descriptor: Data) async throws {
        try await transport.publishSession(descriptor: descriptor)
    }

    func stopSharing() async throws {
        try await transport.stopSharing()
    }

    func send(_ payload: Data, to routeID: String) async throws {
        try await transport.send(payload, to: routeID)
    }

    func closeRoute(_ routeID: String, reason: String?) async {
        await transport.closeRoute(routeID, reason: reason)
    }

    func tearDown(removeRendezvous: Bool) async {
        await transport.teardown(removeRendezvous: removeRendezvous)
    }
}

enum LiveShareNativeRendezvousLifecycleError: Error, Equatable, LocalizedError {
    case invalidTransition
    case endpointMismatch
    case operationSuperseded
    case stateRevisionExhausted

    var errorDescription: String? {
        switch self {
        case .invalidTransition:
            "The native rendezvous lifecycle cannot perform that operation now."
        case .endpointMismatch:
            "The native rendezvous and browser room use different servers."
        case .operationSuperseded:
            "A newer native rendezvous lifecycle operation replaced this one."
        case .stateRevisionExhausted:
            "The native rendezvous session exhausted its state revisions."
        }
    }
}

enum LiveShareNativeRendezvousLifecyclePhase: Equatable, Sendable {
    case idle
    case attaching
    case preparing
    case activating
    case active
    case deactivating
}

enum LiveShareNativeRendezvousUnavailabilityReason: Equatable, Sendable {
    case descriptorRefreshFailed
    case eventBufferOverflow
    case eventStreamEnded
}

struct LiveShareNativeRendezvousLifecycleSnapshot: Equatable, Sendable {
    let phase: LiveShareNativeRendezvousLifecyclePhase
    let rendezvousID: ClipLiveShareRendezvousID?
    let sessionID: ClipLiveShareSessionID?
    let stateRevision: ClipLiveShareStateRevision?
    let signedDescriptor: ClipLiveShareSignedNativeSessionDescriptor?
}

enum LiveShareNativeRendezvousLifecycleEvent: Equatable, Sendable {
    case descriptorPublished(ClipLiveShareSignedNativeSessionDescriptor)
    case approvalRequested(
        routeID: ClipLiveShareRouteID,
        viewerIdentity: ClipLiveShareIdentityPublicKey
    )
    case viewerAdmitted(
        routeID: ClipLiveShareRouteID,
        sessionID: ClipLiveShareSessionID,
        viewerIdentity: ClipLiveShareIdentityPublicKey
    )
    case signalingMessage(
        routeID: ClipLiveShareRouteID,
        message: ClipLiveShareInnerMessage
    )
    case routeClosed(routeID: ClipLiveShareRouteID, reason: String?)
    case unavailable(LiveShareNativeRendezvousUnavailabilityReason)
}

/// Owns the additive native rendezvous lifecycle alongside the existing
/// browser-v1 signaling client. The native server sees only the persistent
/// opaque rendezvous ID and a short-lived, server-readable signed descriptor.
/// The service treats descriptor bytes as unparsed; only proof and subsequent
/// signaling/control payloads are end-to-end encrypted.
actor LiveShareNativeRendezvousLifecycle {
    typealias IdentityProvider = @Sendable () async throws -> NativeDeviceIdentity

    private struct ActiveSession: Sendable {
        let room: ClipLiveShareRoomConfiguration
        let sessionID: ClipLiveShareSessionID
        var revision: ClipLiveShareStateRevision
        var signedDescriptor: ClipLiveShareSignedNativeSessionDescriptor
    }

    private enum RoutePhase: Equatable, Sendable {
        case waitingForHello
        case waitingForProof
        case waitingForApproval
        case admitted
    }

    private struct Route: Sendable {
        let routeID: ClipLiveShareRouteID
        var phase: RoutePhase
        var channel: ClipLiveShareEncryptedChannel?
        var challenge: ClipLiveShareNativeViewerChallenge?
        var viewerIdentity: ClipLiveShareIdentityPublicKey?
    }

    static let descriptorRefreshInterval: Duration = .seconds(4 * 60)
    static let descriptorRefreshRetryDelays: [Duration] = [
        .seconds(2),
        .seconds(4),
        .seconds(8),
    ]
    static let descriptorExpirySafetyMargin: TimeInterval = 10
    static let routeAdmissionTimeout: Duration = .seconds(60)

    private let serverEndpoint: ClipLiveShareServerEndpoint
    private let identityProvider: IdentityProvider
    private let transport: any LiveShareNativeRendezvousHostTransporting
    private let now: @Sendable () -> Date
    private let refreshSleeper: any ClipLiveShareReconnectSleeper
    private let refreshInterval: Duration?
    private let refreshRetryDelays: [Duration]
    private let descriptorExpirySafetyMargin: TimeInterval

    private var phase: LiveShareNativeRendezvousLifecyclePhase = .idle
    private var generation: UInt64 = 0
    private var identity: NativeDeviceIdentity?
    private var activeSession: ActiveSession?
    private var eventTask: Task<Void, Never>?
    private var eventObservationID: UUID?
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false
    private var routes: [ClipLiveShareRouteID: Route] = [:]
    private var routeTimeoutTasks: [ClipLiveShareRouteID: Task<Void, Never>] = [:]
    private var trustedViewerIdentities: Set<ClipLiveShareIdentityPublicKey> = []
    private var viewerProofReplayGuard = try! ClipLiveShareNativeReplayGuard()
    private var isOutputBufferOverflowing = false
    private var continuations: [
        UUID: AsyncStream<LiveShareNativeRendezvousLifecycleEvent>.Continuation
    ] = [:]

    init(
        serverEndpoint: ClipLiveShareServerEndpoint,
        identityProvider: @escaping IdentityProvider,
        transport: any LiveShareNativeRendezvousHostTransporting,
        now: @escaping @Sendable () -> Date = { Date() },
        refreshSleeper: any ClipLiveShareReconnectSleeper =
            ContinuousClipLiveShareReconnectSleeper(),
        refreshInterval: Duration? = LiveShareNativeRendezvousLifecycle
            .descriptorRefreshInterval,
        refreshRetryDelays: [Duration] = LiveShareNativeRendezvousLifecycle
            .descriptorRefreshRetryDelays,
        descriptorExpirySafetyMargin: TimeInterval =
            LiveShareNativeRendezvousLifecycle.descriptorExpirySafetyMargin
    ) {
        self.serverEndpoint = serverEndpoint
        self.identityProvider = identityProvider
        self.transport = transport
        self.now = now
        self.refreshSleeper = refreshSleeper
        self.refreshInterval = refreshInterval
        self.refreshRetryDelays = refreshRetryDelays
        self.descriptorExpirySafetyMargin = max(
            0,
            descriptorExpirySafetyMargin
        )
    }

    nonisolated static func live(
        serverEndpoint: ClipLiveShareServerEndpoint
    ) -> LiveShareNativeRendezvousLifecycle {
        let identityRepository = NativeDeviceIdentityRepository()
        return LiveShareNativeRendezvousLifecycle(
            serverEndpoint: serverEndpoint,
            identityProvider: {
                try await identityRepository.loadOrCreate()
            },
            transport: LiveShareNativeRendezvousHostTransportAdapter()
        )
    }

    func snapshot() -> LiveShareNativeRendezvousLifecycleSnapshot {
        LiveShareNativeRendezvousLifecycleSnapshot(
            phase: phase,
            rendezvousID: identity?.rendezvousID,
            sessionID: activeSession?.sessionID,
            stateRevision: activeSession?.revision,
            signedDescriptor: activeSession?.signedDescriptor
        )
    }

    func events() -> AsyncStream<LiveShareNativeRendezvousLifecycleEvent> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: LiveShareNativeRendezvousLifecycleEvent.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return pair.stream
    }

    /// Claims the persistent device rendezvous and attaches its host socket.
    /// No descriptor is published here, so the service reports PREPARING and
    /// rejects viewer upgrades until the user explicitly starts sharing.
    func prepare() async throws {
        if phase == .preparing { return }
        guard phase == .idle else {
            throw LiveShareNativeRendezvousLifecycleError.invalidTransition
        }
        generation &+= 1
        isOutputBufferOverflowing = false
        let expectedGeneration = generation
        phase = .attaching
        await beginObservingTransportEvents()

        do {
            let identity = try await identityProvider()
            let owner = try makeOwner(identity: identity)
            try await transport.attach(owner)
            guard generation == expectedGeneration,
                  phase == .attaching,
                  !Task.isCancelled else {
                throw LiveShareNativeRendezvousLifecycleError.operationSuperseded
            }
            self.identity = identity
            activeSession = nil
            phase = .preparing
        } catch {
            if generation == expectedGeneration, phase == .attaching {
                phase = .idle
                self.identity = nil
                activeSession = nil
                eventTask?.cancel()
                eventTask = nil
                eventObservationID = nil
                await transport.tearDown(removeRendezvous: false)
            }
            throw error
        }
    }

    /// Publishes a new signed descriptor only after explicit Start. Every
    /// activation receives a fresh session ID and ephemeral browser room key.
    func activate(
        room: ClipLiveShareRoomConfiguration,
        trustedViewerIdentities: Set<ClipLiveShareIdentityPublicKey> = []
    ) async throws {
        guard phase == .preparing, let identity else {
            throw LiveShareNativeRendezvousLifecycleError.invalidTransition
        }
        guard room.endpoint.rootURL == serverEndpoint.rootURL else {
            throw LiveShareNativeRendezvousLifecycleError.endpointMismatch
        }
        generation &+= 1
        let expectedGeneration = generation
        phase = .activating
        let sessionID = ClipLiveShareSessionID.random()
        let revision = try ClipLiveShareStateRevision(rawValue: 1)
        let signedDescriptor = try makeSignedDescriptor(
            room: room,
            identity: identity,
            sessionID: sessionID,
            revision: revision
        )
        let payload = try encode(signedDescriptor)

        do {
            try await transport.publish(descriptor: payload)
            guard generation == expectedGeneration,
                  phase == .activating,
                  !Task.isCancelled else {
                throw LiveShareNativeRendezvousLifecycleError.operationSuperseded
            }
            activeSession = ActiveSession(
                room: room,
                sessionID: sessionID,
                revision: revision,
                signedDescriptor: signedDescriptor
            )
            self.trustedViewerIdentities = trustedViewerIdentities
            phase = .active
            scheduleDescriptorRefresh(sessionID: sessionID)
            emit(.descriptorPublished(signedDescriptor))
        } catch {
            if generation == expectedGeneration, phase == .activating {
                phase = .preparing
                activeSession = nil
            }
            throw error
        }
    }

    /// Rotates the short-lived descriptor while preserving the native session.
    /// This keeps a long-running share joinable without changing its identity
    /// or established peer-to-peer connections.
    func refreshActiveDescriptor() async throws {
        guard phase == .active,
              !isRefreshing,
              let current = activeSession else {
            throw LiveShareNativeRendezvousLifecycleError.invalidTransition
        }
        guard current.revision.rawValue < UInt64.max else {
            throw LiveShareNativeRendezvousLifecycleError.stateRevisionExhausted
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let expectedGeneration = generation
        let nextRevision = try ClipLiveShareStateRevision(
            rawValue: current.revision.rawValue + 1
        )
        guard let identity else {
            throw LiveShareNativeRendezvousLifecycleError.invalidTransition
        }
        let signedDescriptor = try makeSignedDescriptor(
            room: current.room,
            identity: identity,
            sessionID: current.sessionID,
            revision: nextRevision
        )
        try await transport.publish(descriptor: encode(signedDescriptor))
        guard generation == expectedGeneration,
              phase == .active,
              activeSession?.sessionID == current.sessionID else {
            throw LiveShareNativeRendezvousLifecycleError.operationSuperseded
        }
        activeSession?.revision = nextRevision
        activeSession?.signedDescriptor = signedDescriptor
        emit(.descriptorPublished(signedDescriptor))
    }

    /// Clears any published descriptor before replacing the browser room. The
    /// persistent owner attachment remains PREPARING and can activate the new
    /// room without making the old room joinable.
    func prepareForRoomReplacement() async throws {
        if phase == .idle {
            try await prepare()
            return
        }
        if phase == .preparing { return }
        guard phase == .active || phase == .activating else {
            throw LiveShareNativeRendezvousLifecycleError.invalidTransition
        }
        generation &+= 1
        let expectedGeneration = generation
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        clearRoutes()
        trustedViewerIdentities.removeAll()
        phase = .deactivating
        do {
            try await transport.stopSharing()
            guard generation == expectedGeneration,
                  phase == .deactivating else {
                throw LiveShareNativeRendezvousLifecycleError.operationSuperseded
            }
            activeSession = nil
            phase = .preparing
        } catch {
            if generation == expectedGeneration, phase == .deactivating {
                activeSession = nil
                phase = .preparing
            }
            throw error
        }
    }

    /// Stops only native rendezvous/introduction state. Established WebRTC
    /// peers remain independent and are closed by the coordinator only after
    /// its normal DataChannel session-closing handoff.
    func tearDown(removeRendezvous: Bool = false) async {
        generation &+= 1
        phase = .idle
        identity = nil
        activeSession = nil
        isRefreshing = false
        clearRoutes()
        trustedViewerIdentities.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        eventTask?.cancel()
        eventTask = nil
        eventObservationID = nil
        await transport.tearDown(removeRendezvous: removeRendezvous)
    }

    func resolveApproval(
        routeID: ClipLiveShareRouteID,
        allowed: Bool
    ) async {
        guard let route = routes[routeID],
              route.phase == .waitingForApproval,
              let activeSession,
              let viewerIdentity = route.viewerIdentity else {
            await rejectRoute(routeID, reason: "approval-state-invalid")
            return
        }
        let sessionID = activeSession.sessionID
        do {
            let payload = try reserveEncrypted(
                .authResult(try ClipLiveShareAuthResult(
                    sessionID: sessionID,
                    allowed: allowed,
                    reason: allowed ? nil : "host-declined"
                )),
                on: routeID,
                requiring: .waitingForApproval
            )
            try await transport.send(payload, to: routeID.rawValue)
            guard allowed else {
                await rejectRoute(routeID, reason: "host-declined")
                return
            }
            // transport.send suspends. The route may have closed while the
            // frame was in flight, so never resurrect the pre-await copy.
            guard var currentRoute = routes[routeID],
                  currentRoute.phase == .waitingForApproval,
                  currentRoute.viewerIdentity == viewerIdentity,
                  self.activeSession?.sessionID == sessionID else { return }
            currentRoute.phase = .admitted
            routes[routeID] = currentRoute
            emit(.viewerAdmitted(
                routeID: routeID,
                sessionID: sessionID,
                viewerIdentity: viewerIdentity
            ))
        } catch {
            await rejectRoute(routeID, reason: "approval-send-failed")
        }
    }

    func sendSignalingMessage(
        _ message: ClipLiveShareInnerMessage,
        to routeID: ClipLiveShareRouteID
    ) async throws {
        let payload = try reserveEncrypted(
            message,
            on: routeID,
            requiring: .admitted
        )
        try await transport.send(payload, to: routeID.rawValue)
        guard routes[routeID]?.phase == .admitted else {
            throw ClipNativeRendezvousError.routeNotFound
        }
    }

    func closeRoute(
        _ routeID: ClipLiveShareRouteID,
        reason: String? = nil
    ) async {
        routes[routeID] = nil
        routeTimeoutTasks.removeValue(forKey: routeID)?.cancel()
        await transport.closeRoute(routeID.rawValue, reason: reason)
    }

    func completeSignalingHandoff(_ routeID: ClipLiveShareRouteID) async {
        await closeRoute(routeID, reason: "viewer completed signaling")
    }

    func makeFriendResponse(
        to request: ClipLiveShareNativeFriendRequest,
        allowed: Bool,
        accepterDisplayName: String,
        accepterDeviceName: String
    ) throws -> Data {
        guard let identity, let activeSession else {
            throw LiveShareNativeRendezvousLifecycleError.invalidTransition
        }
        let timestamp = try ClipLiveShareNativeTimestamp(date: now())
        let message: ClipLiveShareNativeFriendMessage
        if allowed {
            message = .accepted(try ClipLiveShareNativeFriendAcceptance(
                requestID: request.requestID,
                sessionID: request.sessionID,
                requestDigest: request.digest,
                accepterIdentity: identity.publicKey,
                requesterFingerprint: request.requesterIdentity.fingerprint,
                accepterDisplayName: accepterDisplayName,
                accepterDeviceName: accepterDeviceName,
                accepterEndpoint: serverEndpoint,
                rendezvousID: identity.rendezvousID,
                acceptedAt: timestamp,
                stateRevision: activeSession.revision
            ))
        } else {
            message = .declined(try ClipLiveShareNativeFriendDecline(
                requestID: request.requestID,
                sessionID: request.sessionID,
                requestDigest: request.digest,
                declinerIdentity: identity.publicKey,
                requesterFingerprint: request.requesterIdentity.fingerprint,
                declinedAt: timestamp,
                reason: "host-declined"
            ))
        }
        return try ClipLiveShareNativeV2MessageCodec.encode(
            ClipLiveShareSignedNativeFriendMessage(
                signing: message,
                with: identity.signer
            )
        )
    }

    func makeFriendCommitReceipt(
        for result: LiveShareNativeFriendCommitController.CommitResult
    ) throws -> Data {
        guard let identity,
              identity.publicKey == result.acceptance.accepterIdentity else {
            throw LiveShareNativeRendezvousLifecycleError.invalidTransition
        }
        let receipt = try ClipLiveShareNativeFriendCommitReceipt(
            committing: result.acknowledgement,
            acknowledgementDigest: result.acknowledgementDigest,
            acceptance: result.acceptance,
            request: result.request,
            // The signature is produced only after the durable write returns.
            // Reusing the ACK timestamp makes an exact retry canonical even if
            // the first receipt was lost after persistence completed.
            committedAt: result.acknowledgement.acknowledgedAt
        )
        return try ClipLiveShareNativeV2MessageCodec.encode(
            ClipLiveShareSignedNativeFriendMessage(
                signing: .commitReceipt(receipt),
                with: identity.signer
            )
        )
    }

    func trustViewerIdentity(
        _ viewerIdentity: ClipLiveShareIdentityPublicKey
    ) throws {
        guard phase == .active, activeSession != nil else {
            throw LiveShareNativeRendezvousLifecycleError.invalidTransition
        }
        trustedViewerIdentities.insert(viewerIdentity)
    }

    private func makeOwner(
        identity: NativeDeviceIdentity
    ) throws -> ClipNativeRendezvousOwner {
        guard let ownerToken = ClipLiveShareBase64URL.decode(
            identity.ownerToken.rawValue
        ) else {
            throw ClipNativeRendezvousError.invalidOwnerToken
        }
        return try ClipNativeRendezvousOwner(
            target: ClipNativeRendezvousTarget(
                endpoint: serverEndpoint.rootURL,
                rendezvousID: identity.rendezvousID.bytes
            ),
            ownerToken: ownerToken
        )
    }

    private func makeSignedDescriptor(
        room: ClipLiveShareRoomConfiguration,
        identity: NativeDeviceIdentity,
        sessionID: ClipLiveShareSessionID,
        revision: ClipLiveShareStateRevision
    ) throws -> ClipLiveShareSignedNativeSessionDescriptor {
        let issuedAt = try ClipLiveShareNativeTimestamp(date: now())
        let expiresAt = try issuedAt.adding(
            milliseconds: ClipLiveShareNativeV2
                .maximumSessionDescriptorLifetimeMilliseconds
        )
        let descriptor = try ClipLiveShareNativeSessionDescriptor(
            endpoint: room.endpoint,
            room: room.room,
            rendezvousID: identity.rendezvousID,
            hostIdentity: identity.publicKey,
            roomPublicKey: room.identity.publicKey,
            sessionID: sessionID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            stateRevision: revision
        )
        return try ClipLiveShareSignedNativeSessionDescriptor(
            signing: descriptor,
            with: identity.signer
        )
    }

    private func encode(
        _ descriptor: ClipLiveShareSignedNativeSessionDescriptor
    ) throws -> Data {
        try ClipLiveShareNativeV2MessageCodec.encode(
            descriptor,
            maximumBytes: ClipNativeRendezvousLimits.maximumDescriptorBytes
        )
    }

    private func beginObservingTransportEvents() async {
        guard eventTask == nil else { return }
        let events = await transport.eventStream()
        let observationID = UUID()
        eventObservationID = observationID
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                await self.handleTransportEvent(event)
            }
            guard !Task.isCancelled, let self else { return }
            await self.transportEventStreamEnded(observationID)
        }
    }

    private func handleTransportEvent(
        _ event: ClipNativeRendezvousEvent
    ) async {
        switch event {
        case let .routeOpened(rawRouteID, _):
            await beginRoute(rawRouteID)

        case let .relay(rawRouteID, payload, _):
            await receive(payload, on: rawRouteID)

        case let .routeClosed(rawRouteID, reason):
            guard let routeID = try? ClipLiveShareRouteID(rawValue: rawRouteID)
            else { return }
            routes[routeID] = nil
            routeTimeoutTasks.removeValue(forKey: routeID)?.cancel()
            emit(.routeClosed(routeID: routeID, reason: reason))

        case .stopped:
            clearRoutes()

        case .eventBufferOverflow:
            await failClosed(
                reason: .eventBufferOverflow,
                expectedSessionID: activeSession?.sessionID
            )

        default:
            break
        }
    }

    private func transportEventStreamEnded(_ observationID: UUID) async {
        guard eventObservationID == observationID,
              phase != .idle else { return }
        eventTask = nil
        eventObservationID = nil
        await failClosed(
            reason: .eventStreamEnded,
            expectedSessionID: activeSession?.sessionID
        )
    }

    private func beginRoute(_ rawRouteID: String) async {
        guard phase == .active,
              activeSession != nil,
              let routeID = try? ClipLiveShareRouteID(rawValue: rawRouteID),
              routes[routeID] == nil else {
            await transport.closeRoute(rawRouteID, reason: "native-share-not-active")
            return
        }
        routes[routeID] = Route(
            routeID: routeID,
            phase: .waitingForHello,
            channel: nil,
            challenge: nil,
            viewerIdentity: nil
        )
        routeTimeoutTasks[routeID] = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.routeAdmissionTimeout)
            } catch {
                return
            }
            await self?.rejectRoute(routeID, reason: "admission-timeout")
        }
    }

    private func receive(_ payload: Data, on rawRouteID: String) async {
        guard let routeID = try? ClipLiveShareRouteID(rawValue: rawRouteID),
              var route = routes[routeID],
              let activeSession else {
            await transport.closeRoute(rawRouteID, reason: "route-not-found")
            return
        }
        do {
            let outer = try ClipLiveShareMessageCodec.decodeOuter(
                payload,
                maximumBytes: ClipNativeRendezvousLimits.maximumOpaquePayloadBytes
            )
            switch route.phase {
            case .waitingForHello:
                guard case let .viewerHello(hello) = outer else {
                    throw ClipLiveShareProtocolError.invalidResource(
                        "native route expected viewer hello"
                    )
                }
                var channel = try ClipLiveShareEncryptedChannel(
                    host: activeSession.room.identity,
                    viewerPublicKey: hello.viewerKey,
                    room: activeSession.room.room,
                    routeID: routeID
                )
                let timestamp = try ClipLiveShareNativeTimestamp(date: now())
                let challenge = try ClipLiveShareNativeViewerChallenge.random(
                    sessionDescriptorDigest: activeSession.signedDescriptor
                        .descriptor.digest,
                    sessionID: activeSession.sessionID,
                    routeID: routeID,
                    viewerEphemeralPublicKey: hello.viewerKey,
                    issuedAt: timestamp,
                    expiresAt: try timestamp.adding(
                        milliseconds: ClipLiveShareNativeV2
                            .maximumChallengeLifetimeMilliseconds
                    ),
                    stateRevision: activeSession.revision
                )
                let challengeData = try ClipLiveShareNativeV2MessageCodec.encode(
                    challenge
                )
                let envelope = try channel.sealOpaquePayload(challengeData)
                route.channel = channel
                route.challenge = challenge
                route.phase = .waitingForProof
                routes[routeID] = route
                try await sendOuter(.relay(envelope), to: routeID)

            case .waitingForProof:
                guard case let .relay(envelope) = outer,
                      envelope.routeID == routeID,
                      var channel = route.channel,
                      let challenge = route.challenge else {
                    throw ClipLiveShareProtocolError.invalidResource(
                        "native route expected encrypted viewer proof"
                    )
                }
                let proofData = try channel.openOpaquePayload(envelope)
                let proof = try ClipLiveShareNativeV2MessageCodec.decode(
                    ClipLiveShareSignedNativeViewerProof.self,
                    from: proofData
                )
                guard trustedViewerIdentities.contains(proof.viewerIdentity) else {
                    await rejectRoute(routeID, reason: "viewer-not-trusted")
                    return
                }
                let timestamp = try ClipLiveShareNativeTimestamp(date: now())
                try viewerProofReplayGuard.accept(
                    proof,
                    expectedChallenge: challenge,
                    expectedIdentity: proof.viewerIdentity,
                    at: timestamp
                )
                route.channel = channel
                route.viewerIdentity = proof.viewerIdentity
                route.phase = .waitingForApproval
                routes[routeID] = route
                emit(.approvalRequested(
                    routeID: routeID,
                    viewerIdentity: proof.viewerIdentity
                ))

            case .waitingForApproval:
                throw ClipLiveShareProtocolError.invalidResource(
                    "native route is waiting for host approval"
                )

            case .admitted:
                guard case let .relay(envelope) = outer,
                      envelope.routeID == routeID,
                      var channel = route.channel else {
                    throw ClipLiveShareProtocolError.invalidResource(
                        "native route expected encrypted signaling"
                    )
                }
                let message = try channel.open(envelope)
                guard message.sessionID == activeSession.sessionID else {
                    throw ClipLiveShareNativeV2Error.contextMismatch
                }
                route.channel = channel
                routes[routeID] = route
                emit(.signalingMessage(routeID: routeID, message: message))
            }
        } catch {
            await rejectRoute(routeID, reason: "native-protocol-rejected")
        }
    }

    /// Advances the per-route encryption sequence before crossing an actor
    /// boundary. Offer creation and ICE callbacks can send concurrently; if
    /// the updated channel were committed after transport.send returned, both
    /// callbacks could seal the same sequence and the viewer would reject the
    /// second frame. A failed send intentionally burns its reserved sequence.
    private func reserveEncrypted(
        _ message: ClipLiveShareInnerMessage,
        on routeID: ClipLiveShareRouteID,
        requiring requiredPhase: RoutePhase
    ) throws -> Data {
        guard var route = routes[routeID], route.phase == requiredPhase else {
            throw ClipNativeRendezvousError.routeNotFound
        }
        guard var channel = route.channel else {
            throw ClipNativeRendezvousError.routeNotFound
        }
        let envelope = try channel.seal(message)
        let payload = try ClipLiveShareMessageCodec.encodeOuter(
            .relay(envelope),
            maximumBytes: ClipNativeRendezvousLimits.maximumOpaquePayloadBytes
        )
        route.channel = channel
        routes[routeID] = route
        return payload
    }

    private func sendOuter(
        _ message: ClipLiveShareOuterMessage,
        to routeID: ClipLiveShareRouteID
    ) async throws {
        try await transport.send(
            ClipLiveShareMessageCodec.encodeOuter(
                message,
                maximumBytes: ClipNativeRendezvousLimits.maximumOpaquePayloadBytes
            ),
            to: routeID.rawValue
        )
    }

    private func rejectRoute(
        _ routeID: ClipLiveShareRouteID,
        reason: String
    ) async {
        routes[routeID] = nil
        routeTimeoutTasks.removeValue(forKey: routeID)?.cancel()
        await transport.closeRoute(routeID.rawValue, reason: reason)
    }

    private func clearRoutes() {
        routes.removeAll()
        for task in routeTimeoutTasks.values { task.cancel() }
        routeTimeoutTasks.removeAll()
    }

    private func emit(_ event: LiveShareNativeRendezvousLifecycleEvent) {
        var dropped = false
        for continuation in continuations.values {
            if case .dropped = continuation.yield(event) {
                dropped = true
            }
        }
        guard dropped, !isOutputBufferOverflowing else { return }
        isOutputBufferOverflowing = true
        let sessionID = activeSession?.sessionID
        Task {
            await failClosed(
                reason: .eventBufferOverflow,
                expectedSessionID: sessionID
            )
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func scheduleDescriptorRefresh(
        sessionID: ClipLiveShareSessionID
    ) {
        refreshTask?.cancel()
        guard refreshInterval != nil else {
            refreshTask = nil
            return
        }
        refreshTask = Task { [weak self] in
            await self?.runDescriptorRefreshLoop(sessionID: sessionID)
        }
    }

    private func runDescriptorRefreshLoop(
        sessionID: ClipLiveShareSessionID
    ) async {
        guard let refreshInterval else { return }
        while !Task.isCancelled {
            do {
                try await refreshSleeper.sleep(for: refreshInterval)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  phase == .active,
                  activeSession?.sessionID == sessionID else { return }
            guard await refreshDescriptorWithRetry(sessionID: sessionID) else {
                return
            }
        }
    }

    private func refreshDescriptorWithRetry(
        sessionID: ClipLiveShareSessionID
    ) async -> Bool {
        var nextDelayIndex = 0
        while !Task.isCancelled {
            guard phase == .active,
                  activeSession?.sessionID == sessionID else { return false }
            guard descriptorCanRemainPublished(
                sessionID: sessionID,
                after: nil
            ) else {
                await failClosed(
                    reason: .descriptorRefreshFailed,
                    expectedSessionID: sessionID
                )
                return false
            }
            do {
                try await refreshActiveDescriptor()
                return true
            } catch is CancellationError {
                return false
            } catch let error as LiveShareNativeRendezvousLifecycleError
                where error == .operationSuperseded
            {
                return false
            } catch {
                guard nextDelayIndex < refreshRetryDelays.count else {
                    await failClosed(
                        reason: .descriptorRefreshFailed,
                        expectedSessionID: sessionID
                    )
                    return false
                }
                let delay = refreshRetryDelays[nextDelayIndex]
                nextDelayIndex += 1
                guard descriptorCanRemainPublished(
                    sessionID: sessionID,
                    after: delay
                ) else {
                    await failClosed(
                        reason: .descriptorRefreshFailed,
                        expectedSessionID: sessionID
                    )
                    return false
                }
                do {
                    try await refreshSleeper.sleep(for: delay)
                } catch {
                    return false
                }
            }
        }
        return false
    }

    private func descriptorCanRemainPublished(
        sessionID: ClipLiveShareSessionID,
        after delay: Duration?
    ) -> Bool {
        guard let activeSession,
              activeSession.sessionID == sessionID else { return false }
        let deadline = activeSession.signedDescriptor.descriptor.expiresAt.date
            .addingTimeInterval(-descriptorExpirySafetyMargin)
        let candidate = now().addingTimeInterval(
            delay.map(Self.timeInterval) ?? 0
        )
        return candidate < deadline
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func failClosed(
        reason: LiveShareNativeRendezvousUnavailabilityReason,
        expectedSessionID: ClipLiveShareSessionID?
    ) async {
        guard phase != .idle else { return }
        if let expectedSessionID,
           activeSession?.sessionID != expectedSessionID { return }

        generation &+= 1
        phase = .deactivating
        activeSession = nil
        identity = nil
        isRefreshing = false
        clearRoutes()
        trustedViewerIdentities.removeAll()

        let refresh = refreshTask
        refreshTask = nil
        refresh?.cancel()
        let observation = eventTask
        eventTask = nil
        eventObservationID = nil
        observation?.cancel()

        // Teardown clears the transport's desired descriptor before any later
        // reconnect, so it can never republish an expired descriptor. Existing
        // WebRTC peers are owned by the coordinator and remain untouched.
        await transport.tearDown(removeRendezvous: false)
        phase = .idle
        emit(.unavailable(reason))
    }
}

@MainActor
final class LiveShareCoordinator {
    nonisolated private static let logger = Logger(
        subsystem: ApplicationDirectories.bundleIdentifier,
        category: "live-share"
    )

    private let preferences: LiveSharePreferencesModel
    private let nativeFriends: NativeFriendModel
    private let serverEndpoint: ClipLiveShareServerEndpoint
    private let signaling: ClipLiveShareSignalingClient
    private let nativeRendezvous: LiveShareNativeRendezvousLifecycle
    private let discovery: any CaptureContentDiscovering
    private let requestScreenRecordingPermission: () async -> Bool
    private let requestNativeViewerApproval: (NativeFriendRecord) -> Bool
    private let requestNativeFriendApproval: (String) -> Bool
    private let onSessionEnded: () -> Void
    private let onMenuBarStatusChanged: (LiveShareMenuBarStatus) -> Void
    private let onJoinInviteRequested: (String) -> Void
    private let onJoinFriendRequested: (NativeFriendRecord) -> Void
    private var friendObservation: AnyCancellable?

    private var state = LiveShareStateMachine()
    private var settings = LiveShareSettings.default
    private var persistedSettingsBaseline = LiveShareSettings.default
    private var slotAllocation = LiveShareTrackSlotAllocation()
    private var accessCode: String?
    private var accessCodeIsUpdating = false
    private var accessCodeError: String?
    private var roomConfiguration: ClipLiveShareRoomConfiguration?
    private var signalingIsAvailable = false
    private var preparedViewerRouteIDs: Set<ClipLiveShareRouteID> = []
    private var pendingViewerRoutes: [
        ClipLiveShareRouteID: LiveSharePendingViewerRoute
    ] = [:]
    private var admissionTimeoutTasks: [
        ClipLiveShareRouteID: Task<Void, Never>
    ] = [:]
    private var viewerSessionIDs: [String: ClipLiveShareSessionID] = [:]
    private var negotiationIDs: [String: ClipLiveShareNegotiationID] = [:]
    private var establishedControlViewerIDs: Set<String> = []
    private var pendingSessionClosingViewerIDs: Set<String> = []
    private var pendingNativeApprovalRouteIDs: Set<ClipLiveShareRouteID> = []
    private var nativeViewerRoutes: [
        ClipLiveShareRouteID: LiveShareViewerAdmissionProgress
    ] = [:]
    private var nativeAdmittedViewerIdentities: [
        String: ClipLiveShareIdentityPublicKey
    ] = [:]
    private var nativeControlViewerIdentities: [
        String: ClipLiveShareIdentityPublicKey
    ] = [:]
    private var nativeControlViewerCapabilities: [
        String: Set<ClipLiveShareNativeControlCapability>
    ] = [:]
    private var nativeControlStateRevisions: [String: UInt64] = [:]
    private var nativeFriendResponseRetryTasks: [String: Task<Void, Never>] = [:]
    private var nativeControlReplayGuard = try! ClipLiveShareNativeReplayGuard()
    private var nativeFriendReplayGuard = try! ClipLiveShareNativeFriendReplayGuard()
    private var peerHost: WebRTCPeerHost?
    private var capturePipeline: LiveShareCapturePipeline?
    private var signalingEventTask: Task<Void, Never>?
    private var nativeRendezvousEventTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var cursorTask: Task<Void, Never>?
    private var sourceRefreshTask: Task<Void, Never>?
    private var failureCleanupTask: Task<Void, Never>?
    private var captureRestartTask: Task<Void, Never>?
    private var captureRestartRequestID: UUID?
    private var codecChangeTask: Task<Void, Never>?
    private var systemAudioReconcileTask: Task<Void, Never>?
    private var systemAudioReconcileTaskID: UUID?
    private var sourceTransitionTask: Task<Void, Never>?
    private var sourceTransitionTaskID: UUID?
    private var sourceTransitionGeneration = 0
    private var captureCursorFocusRevision: UInt64 = 0
    private var latestAutomaticWindowID: LiveShareWindowID?
    private var fullscreenRequestGate = LiveShareFullscreenRequestGate()
    private var retryTask: Task<Void, Never>?
    private var isRetrying = false
    private var isActivatingSharing = false
    private var sharingHasStarted = false
    private var isEnding = false
    private var didNotifyEnd = false
    private var startedAt: Date?
    private var viewerConnectedAt: [String: Date] = [:]
    private var focusedWindow: FocusedLiveShareWindow?
    private var windowsByID: [LiveShareWindowID: ShareableCaptureWindow] = [:]
    private var availableWindows: [ShareableCaptureWindow] = []
    private var applicationPathsByWindowID: [LiveShareWindowID: String] = [:]
    private var displayFramesByID: [LiveShareDisplayID: CGRect] = [:]
    private var captureDescriptors: [LiveShareSourceID: LiveShareCaptureDescriptor] = [:]
    private var captureGenerations: [LiveShareSourceID: UUID] = [:]
    private var sourceStatuses: [LiveShareSourceID: LiveShareSourceViewStatus] = [:]
    private var sourceOperationIDs: Set<LiveShareSourceID> = []
    private var latestStatistics = LiveShareStatisticsViewSnapshot()
    private var capturePressure = LiveShareCapturePressureLedger()
    private var peerNegotiation = LiveSharePeerNegotiationLedger()
    private var authoritativeControlDelivery = LiveShareAuthoritativeControlDeliveryLedger()
    private var controlReplayTask: Task<Void, Never>?
    private var controlReplayTaskID: UUID?
    private var publishedMenuBarStatus: LiveShareMenuBarStatus?
    private let systemAudioRequestIdentifier = UUID()
    private var desiredSystemAudioRequest: CaptureAudioSessionRequest?
    /// Mirrors completed ScreenCaptureKit audio reconciliation, not merely the
    /// user's preference or the lifetime of the pre-negotiated Opus track.
    private var systemAudioIsActive = false

    private lazy var nativePeerHandoff = LiveShareNativePeerHandoffController(
        timeoutHandler: { [weak self] routeID in
            await self?.nativeViewerAdmissionTimedOut(routeID)
        }
    )
    private lazy var nativeFriendCommit = LiveShareNativeFriendCommitController(
        commitWithEvidence: { [weak self] record, evidence in
            guard let self else {
                throw CancellationError()
            }
            guard let evidence else {
                throw ClipLiveShareNativeV2Error.contextMismatch
            }
            try await nativeFriends.commitAccepterHandshakeDurably(
                record: record,
                entry: evidence
            )
        }
    )

    private lazy var focusedWindowMonitor = LiveShareFocusedWindowMonitor(
        discovery: discovery,
        excludedBundleIdentifier: ApplicationDirectories.bundleIdentifier,
        handler: { [weak self] focusedWindow in
            self?.focusedWindowDidChange(focusedWindow)
        }
    )

    private lazy var focusedWindowOverlay = FocusedWindowShareOverlayController(
        actions: FocusedWindowShareOverlayActions(
            share: { [weak self] identifier in
                self?.shareFocusedWindow(requestedIdentifier: identifier)
            },
            stop: { [weak self] identifier in
                self?.stopSource(identifier: identifier)
            }
        )
    )

    private lazy var statusHUD = LiveShareStatusHUDController(
        actions: LiveShareStatusHUDActions(
            setFullscreenEnabled: { [weak self] enabled in
                self?.setFullscreenEnabled(enabled)
            },
            stopAllMedia: { [weak self] in
                self?.requestStopAllMedia()
            }
        )
    )

    private(set) lazy var presentationModel = LiveSharePresentationModel(
        snapshot: makeViewSnapshot(),
        actions: LiveSharePresentationActions(
            copyText: { value in Self.copyToPasteboard(value) },
            setAccessCodeEnabled: { [weak self] enabled in
                self?.setAccessCodeEnabled(enabled)
            },
            replaceAccessCode: { [weak self] in
                self?.replaceAccessCode()
            },
            startSharing: { [weak self] in
                self?.requestStartSharing()
            },
            replaceRoom: { [weak self] in
                self?.requestReplaceRoom()
            },
            joinInvite: { [weak self] invite in
                self?.requestJoinInvite(invite)
            },
            joinFriend: { [weak self] id in
                self?.requestJoinFriend(id)
            },
            shareFocusedWindow: { [weak self] in
                self?.shareFocusedWindow(requestedIdentifier: nil)
            },
            shareWindow: { [weak self] identifier in
                self?.shareWindow(identifier: identifier)
            },
            stopSource: { [weak self] identifier in
                self?.stopSource(identifier: identifier)
            },
            setFullscreenEnabled: { [weak self] enabled in
                self?.setFullscreenEnabled(enabled)
            },
            setQuality: { [weak self] quality in self?.setQuality(quality) },
            setFrameRate: { [weak self] frameRate in self?.setFrameRate(frameRate) },
            setCodec: { [weak self] codec in
                self?.requestVideoCodecChange(codec)
            },
            setColorMode: { [weak self] colorMode in
                self?.setColorMode(colorMode)
            },
            setSystemAudioEnabled: { [weak self] enabled in
                self?.setSystemAudioEnabled(enabled)
            },
            setCursorUpdatesMatchFrameRate: { [weak self] enabled in
                self?.setCursorUpdatesMatchFrameRate(enabled)
            },
            setPrioritizeFocusedWindow: { [weak self] enabled in
                self?.setPrioritizeFocusedWindow(enabled)
            },
            setMode: { [weak self] mode in self?.setEncodingMode(mode) },
            setAdvancedVideoSettings: { [weak self] codec, advanced in
                self?.setAdvancedVideoSettings(advanced, for: codec)
            },
            setAutoShareEnabled: { [weak self] enabled in
                self?.setAutoShareEnabled(enabled)
            },
            stopAllMedia: { [weak self] in self?.requestStopAllMedia() },
            retry: { [weak self] in self?.retry() },
            stopSession: { [weak self] in self?.requestEndSession() }
        )
    )

    init(
        preferences: LiveSharePreferencesModel,
        nativeFriends: NativeFriendModel,
        serverEndpoint: ClipLiveShareServerEndpoint = .official,
        discovery: any CaptureContentDiscovering = ScreenCaptureContentDiscovery(),
        requestScreenRecordingPermission: @escaping () async -> Bool = { true },
        nativeRendezvous: LiveShareNativeRendezvousLifecycle? = nil,
        requestNativeViewerApproval: ((NativeFriendRecord) -> Bool)? = nil,
        requestNativeFriendApproval: ((String) -> Bool)? = nil,
        onJoinInviteRequested: @escaping (String) -> Void = { _ in },
        onJoinFriendRequested: @escaping (NativeFriendRecord) -> Void = { _ in },
        onSessionEnded: @escaping () -> Void,
        onMenuBarStatusChanged: @escaping (LiveShareMenuBarStatus) -> Void = { _ in }
    ) {
        self.preferences = preferences
        self.nativeFriends = nativeFriends
        self.serverEndpoint = serverEndpoint
        self.discovery = discovery
        self.requestScreenRecordingPermission = requestScreenRecordingPermission
        self.requestNativeViewerApproval = requestNativeViewerApproval
            ?? Self.defaultNativeViewerApproval
        self.requestNativeFriendApproval = requestNativeFriendApproval
            ?? Self.defaultNativeFriendApproval
        self.nativeRendezvous = nativeRendezvous
            ?? LiveShareNativeRendezvousLifecycle.live(
                serverEndpoint: serverEndpoint
            )
        self.onJoinInviteRequested = onJoinInviteRequested
        self.onJoinFriendRequested = onJoinFriendRequested
        self.onSessionEnded = onSessionEnded
        self.onMenuBarStatusChanged = onMenuBarStatusChanged
        signaling = ClipLiveShareSignalingClient(
            logger: { entry in
                Self.logger.debug("\(entry.description, privacy: .public)")
            }
        )
        friendObservation = nativeFriends.$presentationRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.publish()
            }
    }

    private static func defaultNativeViewerApproval(
        _ friend: NativeFriendRecord
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Allow \(friend.displayName) to view this Live Share?"
        )
        alert.informativeText = String(
            localized: "\(friend.deviceName) proved its saved Clip identity."
        )
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Decline"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func defaultNativeFriendApproval(_ deviceName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Add \(deviceName) as a friend?")
        alert.informativeText = String(
            localized: "Future native Live Shares will still ask before this friend can view."
        )
        alert.addButton(withTitle: String(localized: "Add Friend"))
        alert.addButton(withTitle: String(localized: "Decline"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static var localFriendDeviceName: String {
        nativeFriendName(
            Host.current().localizedName,
            fallback: String(localized: "Mac")
        )
    }

    private static var localFriendDisplayName: String {
        nativeFriendName(
            NSFullUserName(),
            fallback: localFriendDeviceName
        )
    }

    private static func nativeFriendName(
        _ candidate: String?,
        fallback: String
    ) -> String {
        let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = value.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        var result = ""
        for character in source {
            let next = result + String(character)
            guard next.utf8.count <= 128 else { break }
            result = next
        }
        return result.isEmpty ? fallback : result
    }

    var isActive: Bool {
        state.snapshot.phase != .idle || startupTask != nil || isEnding
    }

    func start() {
        guard startupTask == nil, !isEnding else { return }
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await beginSession()
            startupTask = nil
        }
    }

    private func requestStartSharing() {
        guard activationTask == nil,
              !sharingHasStarted,
              !isEnding,
              signalingIsAvailable,
              state.snapshot.phase == .ready else { return }
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isActivatingSharing = true
            publish()
            guard await requestScreenRecordingPermission(),
                  !Task.isCancelled,
                  !isEnding,
                  state.snapshot.phase == .ready else {
                isActivatingSharing = false
                activationTask = nil
                publish()
                return
            }

            do {
                try installNativeRuntime()
                guard let roomConfiguration else {
                    throw LiveShareTransitionError.invalidTransition(
                        from: state.snapshot.phase,
                        operation: "missingRoomConfiguration"
                    )
                }
                let trustedViewerIdentities = Set(
                    nativeFriends.book.records.compactMap { record in
                        record.trustState == .trusted ? record.identity : nil
                    }
                )
                try await nativeRendezvous.activate(
                    room: roomConfiguration,
                    trustedViewerIdentities: trustedViewerIdentities
                )
                try state.beginSharing()
                try state.markSharingStarted()
                sharingHasStarted = true
                startedAt = Date()
                focusedWindowMonitor.start()
                startSourceRefreshLoop()
                startStatisticsLoop()
                isActivatingSharing = false
                activationTask = nil
                broadcastAuthoritativeControlMutation()
                publish()
                await admitPreparedViewerRoutes()
                if settings.autoShareFocusedWindows,
                   state.snapshot.sources.fullscreen == nil,
                   focusedWindow != nil {
                    shareFocusedWindow(requestedIdentifier: nil, isAutomatic: true)
                }
            } catch {
                try? await nativeRendezvous.prepareForRoomReplacement()
                isActivatingSharing = false
                activationTask = nil
                peerHost?.close()
                peerHost = nil
                capturePipeline = nil
                let code: LiveShareFailureCode =
                    error is LiveShareNativeRendezvousLifecycleError
                    || error is ClipNativeRendezvousError
                    ? .signalingFailed
                    : .encoderFailed
                fail(code: code, error: error)
            }
        }
    }

    private func requestReplaceRoom() {
        guard startupTask == nil,
              activationTask == nil,
              !sharingHasStarted,
              !isEnding,
              [.ready, .connecting].contains(state.snapshot.phase) else { return }
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await nativeRendezvous.prepareForRoomReplacement()
            } catch {
                fail(code: .signalingFailed, error: error)
                startupTask = nil
                return
            }
            signalingEventTask?.cancel()
            signalingEventTask = nil
            cancelAdmissionTimeouts()
            pendingViewerRoutes.removeAll()
            await signaling.stop()
            roomConfiguration = nil
            signalingIsAvailable = false
            state.disconnect()
            publish()
            guard !Task.isCancelled, !isEnding else {
                startupTask = nil
                return
            }
            await beginSession()
            startupTask = nil
        }
    }

    private func requestJoinInvite(_ invite: String) {
        guard !sharingHasStarted, !isEnding else { return }
        onJoinInviteRequested(invite)
    }

    private func requestJoinFriend(_ id: String) {
        guard !sharingHasStarted,
              !isEnding,
              let record = nativeFriends.recordAvailableForJoin(id: id) else { return }
        onJoinFriendRequested(record)
    }

    func endForApplicationTermination() async {
        await endSession(notifyApplication: false)
    }

    /// Fully tears down the host role before ApplicationCoordinator constructs
    /// a native viewer role. Unlike the synchronous app-stop reset, returning
    /// from this method guarantees rendezvous, signaling, capture, and peer
    /// transports have completed their asynchronous shutdown.
    func cancelForRoleTransition() async {
        await endSession(notifyApplication: false)
    }

    func hideForApplicationTermination() {
        focusedWindowMonitor.stop()
        focusedWindowOverlay.tearDown()
        statusHUD.tearDown()
    }

    func cancelForApplicationStop() {
        fullscreenRequestGate.invalidate()
        startupTask?.cancel()
        startupTask = nil
        activationTask?.cancel()
        activationTask = nil
        isActivatingSharing = false
        sharingHasStarted = false
        signalingEventTask?.cancel()
        signalingEventTask = nil
        nativeRendezvousEventTask?.cancel()
        nativeRendezvousEventTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
        cursorTask?.cancel()
        cursorTask = nil
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        failureCleanupTask?.cancel()
        failureCleanupTask = nil
        captureRestartTask?.cancel()
        captureRestartTask = nil
        captureRestartRequestID = nil
        retryTask?.cancel()
        retryTask = nil
        isRetrying = false
        cancelAuthoritativeControlReplay()
        invalidateSourceTransitions()
        focusedWindowMonitor.stop()
        focusedWindowOverlay.tearDown()
        statusHUD.tearDown()
        codecChangeTask?.cancel()
        codecChangeTask = nil
        let systemAudioTask = cancelSystemAudioReconciliation()
        peerHost?.close()
        let pipeline = capturePipeline
        capturePipeline = nil
        capturePressure.removeAll()
        roomConfiguration = nil
        signalingIsAvailable = false
        cancelAdmissionTimeouts()
        pendingViewerRoutes.removeAll()
        viewerSessionIDs.removeAll()
        negotiationIDs.removeAll()
        establishedControlViewerIDs.removeAll()
        pendingSessionClosingViewerIDs.removeAll()
        clearNativeViewerState()
        Task {
            await systemAudioTask?.value
            await pipeline?.stopAll()
            await nativeRendezvous.tearDown()
            await signaling.stop()
        }
        state.disconnect()
    }

    private func beginSession() async {
        do {
            try state.beginRoomReservation()
        } catch {
            return
        }
        isEnding = false
        didNotifyEnd = false
        signalingIsAvailable = false
        publish()

        settings = preferences.settings
        persistedSettingsBaseline = settings
        slotAllocation = LiveShareTrackSlotAllocation()
        do {
            accessCode = settings.accessCodeEnabled
                ? try LiveShareAccessCode.generate()
                : nil
        } catch {
            fail(code: .reservationFailed, error: error)
            return
        }
        publish()

        nativeRendezvousEventTask?.cancel()
        let nativeEvents = await nativeRendezvous.events()
        nativeRendezvousEventTask = Task { @MainActor [weak self] in
            for await event in nativeEvents {
                guard !Task.isCancelled, let self else { return }
                await handleNativeRendezvousEvent(event)
            }
        }

        let events = await signaling.events()
        signalingEventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                await handleSignalingEvent(event)
            }
        }

        do {
            try await nativeRendezvous.prepare()
            let room = try await signaling.createRoom(at: serverEndpoint)
            guard !Task.isCancelled, !isEnding else {
                await nativeRendezvous.tearDown()
                await signaling.stop()
                return
            }
            roomConfiguration = room
            try state.receiveRoom(ClipLiveSharePublicRoom(
                name: room.room,
                viewerURL: try room.viewerURL
            ))
            publish()
            try await signaling.connect(room: room)
        } catch {
            guard !Task.isCancelled, !isEnding else {
                await nativeRendezvous.tearDown()
                return
            }
            let code: LiveShareFailureCode
            if error is NativeDeviceIdentityStorageError {
                code = .identityUnavailable
            } else if state.snapshot.phase == .reservingRoom {
                code = .reservationFailed
            } else if error is WebRTCPeerHostError {
                code = .encoderFailed
            } else {
                code = .signalingFailed
            }
            fail(code: code, error: error)
        }
    }

    private func installNativeRuntime() throws {
        cancelAuthoritativeControlReplay()
        _ = cancelSystemAudioReconciliation()
        desiredSystemAudioRequest = nil
        peerHost?.close()
        guard let roomConfiguration else {
            throw LiveShareTransitionError.invalidTransition(
                from: state.snapshot.phase,
                operation: "missingRoomConfiguration"
            )
        }
        let configuration = WebRTCPeerHostConfiguration(
            iceServers: roomConfiguration.capabilities.iceServers.map {
                WebRTCICEServerConfiguration(
                    urlStrings: $0.urls,
                    username: $0.username,
                    credential: $0.credential
                )
            },
            forcesRelay: false,
            senderPolicy: LiveShareCoordinatorPolicy.senderPolicy(for: settings),
            videoCodec: webRTCVideoCodec(settings.videoCodec),
            videoEncodingMode: settings.encodingMode,
            advancedVideoConfigurations: webRTCAdvancedVideoConfigurations(
                settings.advancedVideoSettings
            )
        )
        let host = try WebRTCPeerHost(
            configuration: configuration,
            eventQueue: .main,
            eventHandler: { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handlePeerEvent(event)
                }
            }
        )
        peerHost = host
        capturePipeline = LiveShareCapturePipeline(
            host: host,
            eventHandler: { [weak self] event in
                Task { @MainActor [weak self] in
                    await self?.handleCapturePipelineEvent(event)
                }
            }
        )
    }

    private func handleSignalingEvent(_ event: ClipLiveShareSignalingEvent) async {
        guard !isEnding else { return }
        switch event {
        case let .connecting(_, reconnectAttempt):
            if state.snapshot.phase == .reconnecting, reconnectAttempt > 0 {
                try? state.scheduleReconnect(attempt: reconnectAttempt)
                publish()
            }

        case .connected:
            signalingIsAvailable = true
            do {
                if state.snapshot.phase == .reconnecting {
                    try state.markReconnected()
                    try reconcileSharingStartIfReady()
                } else if state.snapshot.phase == .connecting {
                    try state.markSignalingConnected()
                }
                publish()
                if sharingHasStarted,
                   settings.autoShareFocusedWindows,
                   state.snapshot.sources.fullscreen == nil,
                   focusedWindow != nil {
                    shareFocusedWindow(requestedIdentifier: nil, isAutomatic: true)
                }
            } catch {
                fail(code: .signalingFailed, error: error)
            }

        case let .routeOpened(routeID):
            if sharingHasStarted {
                await beginViewerAdmission(routeID: routeID)
            } else if !retainPreparedViewerRoute(routeID) {
                await signaling.closeRoute(routeID)
            }

        case let .message(routeID, message):
            await handleSignalingMessage(message, routeID: routeID)

        case let .routeClosed(routeID, reason):
            LiveSharePreparedViewerRouteBuffer.cancel(
                routeID,
                in: &preparedViewerRouteIDs
            )
            if reason == "viewer completed signaling" {
                // The browser can observe its DataChannel opening a few
                // milliseconds before the host callback reaches MainActor.
                // A relay-controlled close reason is not proof that the host
                // channel opened. Preserve both the peer and Clip's admission
                // timeout until the native DataChannel callback confirms it.
                if var route = pendingViewerRoutes[routeID] {
                    route.progress.receiveSignalingHandoff()
                    pendingViewerRoutes[routeID] = route
                }
            } else {
                await removePendingRoute(routeID, removesPeer: true)
            }

        case let .routeRejected(routeID, _):
            LiveSharePreparedViewerRouteBuffer.cancel(
                routeID,
                in: &preparedViewerRouteIDs
            )
            await removePendingRoute(routeID, removesPeer: true)

        case let .serverError(code):
            Self.logger.error(
                "The signaling server rejected a request: \(code, privacy: .public)"
            )

        case .invalidMessageReceived:
            Self.logger.error("The signaling server sent an invalid protocol message")

        case let .disconnected(reason, willReconnect):
            signalingIsAvailable = false
            // The server routes only pending introductions. Established peers
            // continue over their encrypted WebRTC control channels.
            for routeID in pendingViewerRoutes.keys {
                let viewerID = routeID.rawValue
                peerHost?.removePeer(viewerID)
                peerNegotiation.remove(viewerID)
                negotiationIDs[viewerID] = nil
                viewerSessionIDs[viewerID] = nil
            }
            cancelAdmissionTimeouts()
            pendingViewerRoutes.removeAll()
            if willReconnect {
                // Signaling availability is independent from media state once
                // the room has connected. Keep ready/starting/sharing/stopping
                // intact so capture and P2P control remain fully operable. The
                // reconnecting domain phase is reserved for initial setup.
                if state.snapshot.phase == .connecting {
                    try? state.markConnectionLost()
                }
                publish()
            } else if reason == .reconnectExhausted {
                // A custom bounded transport may exhaust its retry policy. Do
                // not tear down an established P2P session merely because its
                // rendezvous service is unavailable; media and control already
                // travel over WebRTC. Production uses a persistent capped retry
                // policy, so it can also admit viewers after the server returns.
                if establishedControlViewerIDs.isEmpty {
                    fail(
                        code: .connectionLost,
                        technicalDescription: "Signaling reconnect attempts were exhausted."
                    )
                } else {
                    publish()
                }
            }

        case let .reconnectScheduled(attempt, _):
            if state.snapshot.phase == .reconnecting {
                try? state.scheduleReconnect(attempt: attempt)
                publish()
            }

        case .eventBufferOverflow:
            // Signaling is an admission rendezvous, not the media transport.
            // A hostile or slow introduction route must never tear down healthy
            // P2P viewers. Pending routes are already bounded and independently
            // retired by the signaling client; keep established media alive.
            Self.logger.error("The signaling event observer fell behind")
            publish()

        case .stopped:
            break
        }
    }

    private func handleNativeRendezvousEvent(
        _ event: LiveShareNativeRendezvousLifecycleEvent
    ) async {
        guard !isEnding else { return }
        switch event {
        case let .descriptorPublished(descriptor):
            sendNativeDescriptor(descriptor)

        case let .approvalRequested(routeID, viewerIdentity):
            guard sharingHasStarted,
                  peerHost != nil,
                  let friend = nativeFriends.book.records.first(where: {
                      $0.identity == viewerIdentity && $0.trustState == .trusted
                  }) else {
                await nativeRendezvous.closeRoute(
                    routeID,
                    reason: "viewer-not-trusted"
                )
                return
            }
            let pendingRouteIDs = pendingViewerRoutes.keys.map(\.rawValue)
                + pendingNativeApprovalRouteIDs.map(\.rawValue)
                + nativeViewerRoutes.keys.map(\.rawValue)
            guard LiveShareViewerAdmissionCapacity.canBegin(
                routeID: routeID.rawValue,
                allocatedViewerIDs: peerHost?.viewerIDs ?? [],
                pendingRouteIDs: pendingRouteIDs,
                maximumViewers: WebRTCPeerResourceLimits.clipDefault
                    .maximumViewerCount
            ) else {
                await nativeRendezvous.closeRoute(
                    routeID,
                    reason: "viewer-capacity-reached"
                )
                return
            }
            pendingNativeApprovalRouteIDs.insert(routeID)
            let userAllowed = requestNativeViewerApproval(friend)
            guard pendingNativeApprovalRouteIDs.contains(routeID),
                  !isEnding else {
                await nativeRendezvous.closeRoute(
                    routeID,
                    reason: "approval-cancelled"
                )
                return
            }
            // NSAlert.runModal spins a nested event loop. Settings can block or
            // remove this friend while the prompt is visible, so trust must be
            // re-read immediately before admitting the route.
            let allowed = LiveShareNativeViewerApprovalPolicy.permitsAfterModal(
                userAllowed: userAllowed,
                expectedIdentity: viewerIdentity,
                currentRecords: nativeFriends.book.records
            )
            await nativeRendezvous.resolveApproval(
                routeID: routeID,
                allowed: allowed
            )
            if !allowed { pendingNativeApprovalRouteIDs.remove(routeID) }

        case let .viewerAdmitted(routeID, sessionID, viewerIdentity):
            guard pendingNativeApprovalRouteIDs.contains(routeID),
                  sharingHasStarted,
                  peerHost != nil else {
                await nativeRendezvous.closeRoute(
                    routeID,
                    reason: "admission-cancelled"
                )
                return
            }
            // resolveApproval crosses the rendezvous actor. Settings can block
            // or remove the friend before this callback returns to MainActor,
            // so authorization must be current at the actual peer allocation.
            guard nativeFriends.book.records.contains(where: {
                $0.identity == viewerIdentity && $0.trustState == .trusted
            }) else {
                pendingNativeApprovalRouteIDs.remove(routeID)
                await nativeRendezvous.closeRoute(
                    routeID,
                    reason: "viewer-not-trusted"
                )
                return
            }
            pendingNativeApprovalRouteIDs.remove(routeID)
            let viewerID = routeID.rawValue
            guard viewerSessionIDs[viewerID] == nil else {
                await nativeRendezvous.closeRoute(
                    routeID,
                    reason: "duplicate-viewer"
                )
                return
            }
            nativeViewerRoutes[routeID] = LiveShareViewerAdmissionProgress()
            nativePeerHandoff.admit(routeID)
            nativeAdmittedViewerIdentities[viewerID] = viewerIdentity
            viewerSessionIDs[viewerID] = sessionID
            await sendOffer(to: viewerID, reoffer: false)

        case let .signalingMessage(routeID, message):
            guard nativeViewerRoutes[routeID] != nil,
                  viewerSessionIDs[routeID.rawValue] == message.sessionID else {
                await rejectNativeViewerProtocol(routeID.rawValue)
                return
            }
            switch message {
            case .answer(let answer):
                await applyRemoteAnswer(answer, viewerID: routeID.rawValue)
            case .ice(let candidate):
                await applyRemoteICE(candidate, viewerID: routeID.rawValue)
            case .sessionClosing:
                await removePendingNativeRoute(routeID, removesPeer: true)
            default:
                await rejectNativeViewerProtocol(routeID.rawValue)
            }

        case let .routeClosed(routeID, _):
            pendingNativeApprovalRouteIDs.remove(routeID)
            guard var progress = nativeViewerRoutes[routeID] else { return }
            nativePeerHandoff.signalingRouteClosed(routeID)
            progress.receiveSignalingHandoff()
            if progress.remainsPending {
                nativeViewerRoutes[routeID] = progress
            } else {
                nativeViewerRoutes[routeID] = nil
            }

        case let .unavailable(reason):
            // Native rendezvous has failed closed. Its admitted peers remain
            // governed by their DataChannel/terminal/timeout events; browser
            // v1 and already-established P2P viewers are unaffected.
            Self.logger.error(
                "Native rendezvous became unavailable: \(String(describing: reason), privacy: .public)"
            )
            publish()
        }
    }

    private func retainPreparedViewerRoute(
        _ routeID: ClipLiveShareRouteID
    ) -> Bool {
        guard !isEnding,
              signalingIsAvailable,
              state.snapshot.phase == .ready else { return false }
        return LiveSharePreparedViewerRouteBuffer.retain(
            routeID,
            in: &preparedViewerRouteIDs,
            maximumCount: WebRTCPeerResourceLimits.clipDefault
                .maximumViewerCount
        )
    }

    private func admitPreparedViewerRoutes() async {
        let routeIDs = LiveSharePreparedViewerRouteBuffer.drain(
            &preparedViewerRouteIDs
        )
        for routeID in routeIDs {
            guard sharingHasStarted, peerHost != nil, !isEnding else {
                await signaling.closeRoute(routeID)
                continue
            }
            await beginViewerAdmission(routeID: routeID)
        }
    }

    private func beginViewerAdmission(routeID: ClipLiveShareRouteID) async {
        LiveSharePreparedViewerRouteBuffer.cancel(
            routeID,
            in: &preparedViewerRouteIDs
        )
        guard sharingHasStarted, peerHost != nil else {
            await signaling.closeRoute(routeID)
            return
        }
        let maximumViewers = WebRTCPeerResourceLimits.clipDefault.maximumViewerCount
        guard LiveShareViewerAdmissionCapacity.canBegin(
            routeID: routeID.rawValue,
            allocatedViewerIDs: peerHost?.viewerIDs ?? [],
            pendingRouteIDs: pendingViewerRoutes.keys.map(\.rawValue)
                + pendingNativeApprovalRouteIDs.map(\.rawValue)
                + nativeViewerRoutes.keys.map(\.rawValue),
            maximumViewers: maximumViewers
        ) else {
            await signaling.closeRoute(routeID)
            return
        }
        guard let sessionID = await nativeRendezvous.snapshot().sessionID else {
            await signaling.closeRoute(routeID)
            return
        }
        let code = accessCode
        let challenge = ClipLiveShareAuthChallenge.random(
            sessionID: sessionID,
            accessCodeRequired: code != nil
        )
        pendingViewerRoutes[routeID] = LiveSharePendingViewerRoute(
            routeID: routeID,
            sessionID: sessionID,
            challenge: challenge,
            accessCode: code
        )
        scheduleAdmissionTimeout(for: routeID)
        do {
            try await signaling.send(.authChallenge(challenge), to: routeID)
        } catch {
            await removePendingRoute(routeID, removesPeer: true)
        }
    }

    private func handleSignalingMessage(
        _ message: ClipLiveShareInnerMessage,
        routeID: ClipLiveShareRouteID
    ) async {
        guard let route = pendingViewerRoutes[routeID],
              message.sessionID == route.sessionID else {
            LiveSharePreparedViewerRouteBuffer.cancel(
                routeID,
                in: &preparedViewerRouteIDs
            )
            await signaling.closeRoute(routeID)
            await removePendingRoute(routeID, removesPeer: true)
            return
        }
        let viewerID = routeID.rawValue
        switch message {
        case .authResponse(let response):
            await handleAuthResponse(response, route: route)

        case .answer(let answer):
            await applyRemoteAnswer(answer, viewerID: viewerID)

        case .ice(let candidate):
            await applyRemoteICE(candidate, viewerID: viewerID)

        case .sessionClosing:
            await removePendingRoute(routeID, removesPeer: true)

        default:
            await signaling.closeRoute(routeID)
            await removePendingRoute(routeID, removesPeer: true)
        }
    }

    private func handleAuthResponse(
        _ response: ClipLiveShareAuthResponse,
        route: LiveSharePendingViewerRoute
    ) async {
        let isAllowed: Bool
        if let code = route.accessCode {
            isAllowed = response.proof.map {
                ClipLiveShareAccessCodeProof.verify(
                    $0,
                    accessCode: code,
                    challenge: route.challenge.challenge,
                    sessionID: route.sessionID
                )
            } ?? false
        } else {
            isAllowed = response.proof == nil
        }

        do {
            try await signaling.send(
                .authResult(try ClipLiveShareAuthResult(
                    sessionID: route.sessionID,
                    allowed: isAllowed,
                    reason: isAllowed ? nil : "invalid-access-code"
                )),
                to: route.routeID
            )
        } catch {
            await removePendingRoute(route.routeID, removesPeer: true)
            return
        }
        guard isAllowed else {
            await signaling.closeRoute(route.routeID)
            await removePendingRoute(route.routeID, removesPeer: true)
            return
        }

        let viewerID = route.routeID.rawValue
        guard viewerSessionIDs[viewerID] == nil else {
            await signaling.closeRoute(route.routeID)
            await removePendingRoute(route.routeID, removesPeer: true)
            return
        }
        viewerSessionIDs[viewerID] = route.sessionID
        await sendOffer(to: viewerID, reoffer: false)
    }

    private func applyRemoteAnswer(
        _ answer: ClipLiveShareSessionDescription,
        viewerID: String
    ) async {
        guard answer.sessionID == viewerSessionIDs[viewerID] else {
            await rejectViewerProtocol(viewerID)
            return
        }
        // Candidates and answers from the superseded negotiation can already
        // be queued when a codec switch starts. The ordered control channel
        // makes them harmless; only the current generation may mutate WebRTC.
        guard answer.negotiationID == negotiationIDs[viewerID],
              let peerHost,
              let offerToken = peerNegotiation.tokenAwaitingAnswer(for: viewerID)
        else { return }
        do {
            try await peerHost.setRemoteAnswer(answer.sdp, for: viewerID)
            guard let pendingCandidates = peerNegotiation.completeAnswer(
                for: viewerID,
                token: offerToken
            ) else { return }
            for candidate in pendingCandidates {
                guard peerNegotiation.contains(offerToken, for: viewerID) else { return }
                try await peerHost.addRemoteICECandidate(candidate, for: viewerID)
            }
        } catch {
            guard peerNegotiation.remove(viewerID, token: offerToken) else { return }
            peerHost.removePeer(viewerID)
            logPeerFailure(error, viewerID: viewerID)
        }
    }

    private func applyRemoteICE(
        _ value: ClipLiveShareICECandidate,
        viewerID: String
    ) async {
        guard value.sessionID == viewerSessionIDs[viewerID] else {
            await rejectViewerProtocol(viewerID)
            return
        }
        guard value.negotiationID == negotiationIDs[viewerID] else { return }
        guard let lineIndex = Int32(exactly: value.sdpMLineIndex) else {
            await rejectViewerProtocol(viewerID)
            return
        }
        let candidate = WebRTCICECandidate(
            candidate: value.candidate,
            sdpMid: value.sdpMid,
            sdpMLineIndex: lineIndex
        )
        do {
            switch peerNegotiation.receiveRemoteICE(candidate, for: viewerID) {
            case .buffered:
                return
            case .ready(let ready):
                try await peerHost?.addRemoteICECandidate(ready, for: viewerID)
            case .rejected:
                await rejectViewerProtocol(viewerID)
            }
        } catch {
            logPeerFailure(error, viewerID: viewerID)
            await rejectViewerProtocol(viewerID)
        }
    }

    private func sendOffer(to viewerID: String, reoffer: Bool) async {
        guard let peerHost,
              let sessionID = viewerSessionIDs[viewerID],
              let offerToken = peerNegotiation.beginOffer(for: viewerID) else { return }
        let negotiationID = ClipLiveShareNegotiationID.random()
        negotiationIDs[viewerID] = negotiationID
        do {
            let offer = try await (reoffer
                ? peerHost.createReoffer(for: viewerID)
                : peerHost.createOffer(for: viewerID))
            guard peerNegotiation.markOfferAnswerEligible(
                for: viewerID,
                token: offerToken
            ) else { return }
            let description = try ClipLiveShareSessionDescription(
                sessionID: sessionID,
                negotiationID: negotiationID,
                sdp: offer.sdp
            )
            try await sendNegotiationMessage(
                establishedControlViewerIDs.contains(viewerID)
                    ? .codecOffer(description)
                    : .offer(description),
                viewerID: viewerID
            )
            guard let pendingCandidates = peerNegotiation.markOfferSent(
                for: viewerID,
                token: offerToken
            ) else { return }
            for candidate in pendingCandidates {
                guard peerNegotiation.contains(offerToken, for: viewerID) else { return }
                try await sendLocalICECandidate(candidate, viewerID: viewerID)
            }
        } catch {
            guard peerNegotiation.remove(viewerID, token: offerToken) else { return }
            peerHost.removePeer(viewerID)
            logPeerFailure(error, viewerID: viewerID)
        }
    }

    private func handlePeerEvent(_ event: WebRTCPeerHostEvent) async {
        if isEnding {
            switch event {
            case let .controlMessageReceived(viewerID, data, isBinary):
                handleClosingControlAcknowledgement(
                    viewerID: viewerID,
                    data: data,
                    isBinary: isBinary
                )
            case let .viewerRemoved(viewerID):
                pendingSessionClosingViewerIDs.remove(viewerID)
            default:
                break
            }
            return
        }
        switch event {
        case .viewerAdded:
            publish()

        case let .viewerRemoved(viewerID):
            peerNegotiation.remove(viewerID)
            authoritativeControlDelivery.remove(viewerID)
            viewerConnectedAt[viewerID] = nil
            negotiationIDs[viewerID] = nil
            viewerSessionIDs[viewerID] = nil
            establishedControlViewerIDs.remove(viewerID)
            pendingSessionClosingViewerIDs.remove(viewerID)
            nativeAdmittedViewerIdentities[viewerID] = nil
            nativeControlViewerIdentities[viewerID] = nil
            nativeControlViewerCapabilities[viewerID] = nil
            nativeControlStateRevisions[viewerID] = nil
            nativeFriendResponseRetryTasks.removeValue(forKey: viewerID)?
                .cancel()
            nativeFriendCommit.removeViewer(viewerID)
            if let routeID = try? ClipLiveShareRouteID(rawValue: viewerID) {
                nativePeerHandoff.peerTerminated(routeID)
                if pendingViewerRoutes[routeID] != nil {
                    admissionTimeoutTasks.removeValue(forKey: routeID)?.cancel()
                    pendingViewerRoutes[routeID] = nil
                    await signaling.closeRoute(routeID)
                }
                if nativeViewerRoutes.removeValue(forKey: routeID) != nil {
                    await nativeRendezvous.closeRoute(
                        routeID,
                        reason: "peer-removed"
                    )
                }
            }
            updateViewerCount()
            publish()

        case let .localICECandidate(viewerID, candidate):
            if let candidate = peerNegotiation.receiveLocalICE(
                candidate,
                for: viewerID
            ) {
                do {
                    try await sendLocalICECandidate(candidate, viewerID: viewerID)
                } catch {
                    logPeerFailure(error, viewerID: viewerID)
                }
            }

        case let .connectionStateChanged(viewerID, connectionState):
            if connectionState == .connected {
                viewerConnectedAt[viewerID] = viewerConnectedAt[viewerID] ?? Date()
            } else if connectionState == .failed || connectionState == .closed {
                viewerConnectedAt[viewerID] = nil
                peerNegotiation.remove(viewerID)
                if let routeID = try? ClipLiveShareRouteID(rawValue: viewerID) {
                    nativePeerHandoff.peerTerminated(routeID)
                }
                peerHost?.removePeer(viewerID)
            }
            updateViewerCount()
            publish()

        case let .controlDataChannelStateChanged(viewerID, channelState):
            if channelState == .open {
                if let routeID = try? ClipLiveShareRouteID(rawValue: viewerID),
                   var route = pendingViewerRoutes[routeID] {
                    route.progress.openControlDataChannel()
                    if !route.progress.remainsPending {
                        admissionTimeoutTasks.removeValue(forKey: routeID)?.cancel()
                        pendingViewerRoutes[routeID] = nil
                    }
                }
                if let routeID = try? ClipLiveShareRouteID(rawValue: viewerID),
                   var progress = nativeViewerRoutes[routeID] {
                    nativePeerHandoff.controlChannelOpened(routeID)
                    progress.openControlDataChannel()
                    if progress.remainsPending {
                        nativeViewerRoutes[routeID] = progress
                    } else {
                        nativeViewerRoutes[routeID] = nil
                    }
                    await nativeRendezvous.completeSignalingHandoff(routeID)
                }
                establishedControlViewerIDs.insert(viewerID)
                sendInitialControlState(to: viewerID)
                // The browser retires the introduction route from its own
                // DataChannel-open callback. Waiting for that remote readiness
                // signal avoids closing signaling before WebKit has installed
                // its control channel.
            }
            publish()

        case let .controlDataChannelDrained(viewerID):
            // A durable snapshot exhausted its short retry budget while the
            // native channel was saturated. The low-water callback grants one
            // fresh bounded replay of current state; no app payload is queued.
            authoritativeControlDelivery.recordNativeControlDrain(viewerID)
            scheduleAuthoritativeControlReplay()

        case let .controlMessageReceived(viewerID, data, isBinary):
            await handleViewerControlMessage(
                viewerID: viewerID,
                data: data,
                isBinary: isBinary
            )

        case let .negotiationNeeded(viewerID):
            await sendOffer(to: viewerID, reoffer: true)

        case .videoCodecChanged:
            publish()

        case let .error(viewerID, error):
            logPeerFailure(error, viewerID: viewerID)
        }
    }

    private func sendLocalICECandidate(
        _ candidate: WebRTCICECandidate,
        viewerID: String
    ) async throws {
        guard let sessionID = viewerSessionIDs[viewerID],
              let negotiationID = negotiationIDs[viewerID] else { return }
        let message = try ClipLiveShareICECandidate(
            sessionID: sessionID,
            negotiationID: negotiationID,
            candidate: candidate.candidate,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int(candidate.sdpMLineIndex)
        )
        try await sendNegotiationMessage(
            establishedControlViewerIDs.contains(viewerID)
                ? .codecICE(message)
                : .ice(message),
            viewerID: viewerID
        )
    }

    private func sendNegotiationMessage(
        _ message: ClipLiveShareInnerMessage,
        viewerID: String
    ) async throws {
        if establishedControlViewerIDs.contains(viewerID) {
            let data = try ClipLiveShareMessageCodec.encodeInner(message)
            guard peerHost?.sendControl(data, to: viewerID) == true else {
                throw ClipLiveShareNetworkError.sendFailed
            }
            return
        }
        guard let routeID = try? ClipLiveShareRouteID(rawValue: viewerID),
              pendingViewerRoutes[routeID] != nil
                || nativeViewerRoutes[routeID] != nil else {
            throw ClipLiveShareNetworkError.routeNotFound
        }
        if nativeViewerRoutes[routeID] != nil {
            try await nativeRendezvous.sendSignalingMessage(
                message,
                to: routeID
            )
        } else {
            try await signaling.send(message, to: routeID)
        }
    }

    private func handleViewerControlMessage(
        viewerID: String,
        data: Data,
        isBinary: Bool
    ) async {
        guard !isBinary,
              data.count <= ClipLiveShareV1.maximumInnerMessageBytes,
              let sessionID = viewerSessionIDs[viewerID] else {
            peerHost?.removePeer(viewerID)
            return
        }
        if let message = try? ClipLiveShareMessageCodec.decodeInner(data) {
            guard message.sessionID == sessionID else {
                peerHost?.removePeer(viewerID)
                return
            }
            switch message {
            case .codecAnswer(let answer):
                await applyRemoteAnswer(answer, viewerID: viewerID)
            case .codecICE(let candidate):
                await applyRemoteICE(candidate, viewerID: viewerID)
            case .sessionClosing:
                if pendingSessionClosingViewerIDs.remove(viewerID) == nil {
                    peerHost?.removePeer(viewerID)
                }
            default:
                peerHost?.removePeer(viewerID)
            }
            return
        }
        if let hello = try? ClipLiveShareNativeV2MessageCodec.decode(
            ClipLiveShareSignedNativeControlHello.self,
            from: data
        ) {
            await handleNativeControlHello(hello, viewerID: viewerID)
            return
        }
        if let friendMessage = try? ClipLiveShareNativeV2MessageCodec.decode(
            ClipLiveShareSignedNativeFriendMessage.self,
            from: data
        ) {
            await handleNativeFriendMessage(friendMessage, viewerID: viewerID)
            return
        }
        peerHost?.removePeer(viewerID)
    }

    private func handleNativeControlHello(
        _ signed: ClipLiveShareSignedNativeControlHello,
        viewerID: String
    ) async {
        guard let sessionID = viewerSessionIDs[viewerID],
              nativeControlViewerIdentities[viewerID] == nil else {
            peerHost?.removePeer(viewerID)
            return
        }
        do {
            let timestamp = try ClipLiveShareNativeTimestamp(date: Date())
            if let expectedIdentity = nativeAdmittedViewerIdentities[viewerID] {
                try nativeControlReplayGuard.accept(
                    signed,
                    expectedSessionID: sessionID,
                    expectedIdentity: expectedIdentity,
                    at: timestamp
                )
            } else {
                try nativeControlReplayGuard.accept(
                    signed,
                    expectedSessionID: sessionID,
                    at: timestamp
                )
                if nativeFriends.book.records.contains(where: {
                    $0.identity == signed.hello.viewerIdentity
                        && $0.trustState == .blocked
                }) {
                    throw ClipLiveShareNativeV2Error.identityMismatch
                }
            }
            nativeControlViewerIdentities[viewerID] = signed.hello.viewerIdentity
            nativeControlViewerCapabilities[viewerID] = signed.hello.capabilities
            nativeControlStateRevisions[viewerID] = 0
            if let friend = nativeFriends.book.records.first(where: {
                $0.identity == signed.hello.viewerIdentity
                    && $0.trustState == .trusted
            }) {
                nativeFriends.markConnected(id: friend.id)
            }
            let lifecycleSnapshot = await nativeRendezvous.snapshot()
            guard let descriptor = lifecycleSnapshot.signedDescriptor,
                  descriptor.descriptor.sessionID == sessionID else {
                throw ClipLiveShareNativeV2Error.contextMismatch
            }
            let descriptorData = try ClipLiveShareNativeV2MessageCodec.encode(
                descriptor
            )
            guard peerHost?.sendControl(descriptorData, to: viewerID) == true else {
                throw ClipLiveShareNetworkError.sendFailed
            }
            authoritativeControlDelivery.markDirty(viewerID)
            scheduleAuthoritativeControlReplay()
            try await restoreNativeFriendCommitIfAvailable(
                viewerIdentity: signed.hello.viewerIdentity,
                viewerID: viewerID,
                at: timestamp
            )
        } catch {
            Self.logger.error(
                "Rejected native viewer identity: \(error.localizedDescription, privacy: .public)"
            )
            peerHost?.removePeer(viewerID)
        }
    }

    private func restoreNativeFriendCommitIfAvailable(
        viewerIdentity: ClipLiveShareIdentityPublicKey,
        viewerID: String,
        at timestamp: ClipLiveShareNativeTimestamp
    ) async throws {
        guard let recovery = nativeFriends.accepterHandshakeRecoveries
            .last(where: { $0.request.requesterIdentity == viewerIdentity }) else {
            return
        }
        try recovery.validate(
            localIdentity: recovery.acceptance.accepterIdentity,
            at: timestamp
        )
        try nativeFriendCommit.restoreCommittedHandshake(
            recovery,
            viewerID: viewerID
        )
        if let receipt = nativeFriendCommit.commitReceipt(for: viewerID) {
            sendNativeFriendCommitReceipt(receipt, to: viewerID)
            return
        }

        let result = try nativeFriendCommit.restoredCommitResult(for: viewerID)
        let receipt = try await nativeRendezvous.makeFriendCommitReceipt(for: result)
        guard let journalEntry = result.handshakeJournalEntry else {
            throw ClipLiveShareNativeV2Error.contextMismatch
        }
        let signedReceipt = try ClipLiveShareNativeV2MessageCodec.decode(
            ClipLiveShareSignedNativeFriendMessage.self,
            from: receipt
        )
        try await nativeFriends.storeCommitReceiptDurably(
            signedReceipt,
            handshakeID: journalEntry.id
        )
        try nativeFriendCommit.storeCommitReceipt(
            receipt,
            acknowledgementDigest: result.acknowledgementDigest,
            viewerID: viewerID
        )
        sendNativeFriendCommitReceipt(receipt, to: viewerID)
    }

    private func handleNativeFriendMessage(
        _ signed: ClipLiveShareSignedNativeFriendMessage,
        viewerID: String
    ) async {
        guard let viewerIdentity = nativeControlViewerIdentities[viewerID] else {
            peerHost?.removePeer(viewerID)
            return
        }
        do {
            switch signed.message {
            case let .request(request):
                guard request.requesterIdentity == viewerIdentity else {
                    throw ClipLiveShareNativeV2Error.identityMismatch
                }
                try signed.verifySignature(expectedIdentity: viewerIdentity)
                // The viewer may safely repeat the exact signed request if the
                // reliable channel was saturated before accepting our reply.
                if let response = nativeFriendCommit
                    .responseForVerifiedDuplicateRequest(
                        request,
                        viewerID: viewerID
                    ) {
                    sendNativeFriendAcceptance(response, to: viewerID)
                    return
                }
                guard !nativeFriendCommit.hasPendingAcceptance(for: viewerID)
                else { throw ClipLiveShareNativeV2Error.contextMismatch }
                try nativeFriendReplayGuard.acceptSignatureOnce(
                    signed,
                    expectedIdentity: viewerIdentity
                )
                let lifecycleSnapshot = await nativeRendezvous.snapshot()
                guard let descriptor = lifecycleSnapshot.signedDescriptor else {
                    throw LiveShareNativeRendezvousLifecycleError.invalidTransition
                }
                let timestamp = try ClipLiveShareNativeTimestamp(date: Date())
                try request.validate(
                    expectedSessionDescriptor: descriptor.descriptor,
                    expectedHostIdentity: descriptor.descriptor.hostIdentity,
                    at: timestamp
                )
                let allowed = requestNativeFriendApproval(
                    request.requesterDeviceName
                )
                let response = try await nativeRendezvous.makeFriendResponse(
                    to: request,
                    allowed: allowed,
                    accepterDisplayName: Self.localFriendDisplayName,
                    accepterDeviceName: Self.localFriendDeviceName
                )
                if allowed {
                    let signedResponse = try ClipLiveShareNativeV2MessageCodec
                        .decode(
                            ClipLiveShareSignedNativeFriendMessage.self,
                            from: response
                        )
                    guard case .accepted = signedResponse.message else {
                        throw ClipLiveShareNativeV2Error.contextMismatch
                    }
                    // Stage before delivery, but do not mutate the friend book.
                    // Persistence happens only after the requester's signed ACK.
                    try nativeFriendCommit.stage(
                        signedRequest: signed,
                        signedAcceptance: signedResponse,
                        signedSessionDescriptor: descriptor,
                        encodedResponse: response,
                        viewerID: viewerID
                    )
                    sendNativeFriendAcceptance(response, to: viewerID)
                } else if peerHost?.sendControl(response, to: viewerID) != true {
                    throw ClipLiveShareNetworkError.sendFailed
                }

            case .acceptanceAcknowledged:
                let timestamp = try ClipLiveShareNativeTimestamp(date: Date())
                if !nativeFriendCommit.hasPendingAcceptance(for: viewerID),
                   let recovery = nativeFriends.accepterHandshakeRecoveries
                    .first(where: {
                        $0.signedAcknowledgement.digest == signed.digest
                            && $0.request.requesterIdentity == viewerIdentity
                    }) {
                    try recovery.validate(
                        localIdentity: recovery.acceptance.accepterIdentity,
                        at: timestamp
                    )
                    try nativeFriendCommit.restoreCommittedHandshake(
                        recovery,
                        viewerID: viewerID
                    )
                }
                let result = try await nativeFriendCommit.receiveAcknowledgement(
                    signed,
                    viewerID: viewerID,
                    at: timestamp
                )
                try await nativeRendezvous.trustViewerIdentity(
                    result.request.requesterIdentity
                )
                nativeFriendResponseRetryTasks.removeValue(forKey: viewerID)?
                    .cancel()
                let receipt: Data
                if let existing = nativeFriendCommit.commitReceipt(
                    for: viewerID
                ) {
                    receipt = existing
                } else {
                    receipt = try await nativeRendezvous.makeFriendCommitReceipt(
                        for: result
                    )
                    guard let journalEntry = result.handshakeJournalEntry else {
                        throw ClipLiveShareNativeV2Error.contextMismatch
                    }
                    let signedReceipt = try ClipLiveShareNativeV2MessageCodec.decode(
                        ClipLiveShareSignedNativeFriendMessage.self,
                        from: receipt
                    )
                    try await nativeFriends.storeCommitReceiptDurably(
                        signedReceipt,
                        handshakeID: journalEntry.id
                    )
                    try nativeFriendCommit.storeCommitReceipt(
                        receipt,
                        acknowledgementDigest: result.acknowledgementDigest,
                        viewerID: viewerID
                    )
                }
                sendNativeFriendCommitReceipt(receipt, to: viewerID)

            case .accepted, .commitReceipt, .declined, .revoked:
                throw ClipLiveShareNativeV2Error.contextMismatch
            }
        } catch {
            Self.logger.error(
                "Rejected native friend request: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func sendNativeFriendAcceptance(
        _ response: Data,
        to viewerID: String
    ) {
        nativeFriendResponseRetryTasks.removeValue(forKey: viewerID)?.cancel()
        guard peerHost?.sendControl(response, to: viewerID) != true else { return }
        nativeFriendResponseRetryTasks[viewerID] = Task {
            @MainActor [weak self] in
            guard let self else { return }
            for delay in [250, 500, 1_000] {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }
                guard nativeFriendCommit.hasPendingAcceptance(for: viewerID),
                      let response = nativeFriendCommit.pendingResponse(
                          for: viewerID
                      ) else { return }
                if peerHost?.sendControl(response, to: viewerID) == true {
                    nativeFriendResponseRetryTasks[viewerID] = nil
                    return
                }
            }
            nativeFriendResponseRetryTasks[viewerID] = nil
        }
    }

    private func sendNativeFriendCommitReceipt(
        _ response: Data,
        to viewerID: String
    ) {
        nativeFriendResponseRetryTasks.removeValue(forKey: viewerID)?.cancel()
        guard peerHost?.sendControl(response, to: viewerID) != true else { return }
        nativeFriendResponseRetryTasks[viewerID] = Task {
            @MainActor [weak self] in
            guard let self else { return }
            for delay in [250, 500, 1_000, 2_000] {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }
                guard let receipt = nativeFriendCommit.commitReceipt(
                    for: viewerID
                ) else { return }
                if peerHost?.sendControl(receipt, to: viewerID) == true {
                    nativeFriendResponseRetryTasks[viewerID] = nil
                    return
                }
            }
            nativeFriendResponseRetryTasks[viewerID] = nil
        }
    }

    private func sendNativeDescriptor(
        _ descriptor: ClipLiveShareSignedNativeSessionDescriptor
    ) {
        guard let peerHost,
              let data = try? ClipLiveShareNativeV2MessageCodec.encode(
                  descriptor
              ) else { return }
        for viewerID in nativeControlViewerIdentities.keys {
            guard viewerSessionIDs[viewerID] == descriptor.descriptor.sessionID
            else { continue }
            _ = peerHost.sendControl(data, to: viewerID)
        }
    }

    private func handleClosingControlAcknowledgement(
        viewerID: String,
        data: Data,
        isBinary: Bool
    ) {
        guard !isBinary,
              pendingSessionClosingViewerIDs.contains(viewerID),
              let sessionID = viewerSessionIDs[viewerID],
              let message = try? ClipLiveShareMessageCodec.decodeInner(data),
              message.sessionID == sessionID,
              case .sessionClosing = message else { return }
        pendingSessionClosingViewerIDs.remove(viewerID)
    }

    private func removePendingRoute(
        _ routeID: ClipLiveShareRouteID,
        removesPeer: Bool
    ) async {
        LiveSharePreparedViewerRouteBuffer.cancel(
            routeID,
            in: &preparedViewerRouteIDs
        )
        admissionTimeoutTasks.removeValue(forKey: routeID)?.cancel()
        pendingViewerRoutes[routeID] = nil
        let viewerID = routeID.rawValue
        guard !establishedControlViewerIDs.contains(viewerID) else { return }
        peerNegotiation.remove(viewerID)
        negotiationIDs[viewerID] = nil
        viewerSessionIDs[viewerID] = nil
        if removesPeer {
            peerHost?.removePeer(viewerID)
        }
    }

    private func rejectViewerProtocol(_ viewerID: String) async {
        if let routeID = try? ClipLiveShareRouteID(rawValue: viewerID),
           nativeViewerRoutes[routeID] != nil {
            await rejectNativeViewerProtocol(viewerID)
            return
        }
        peerHost?.removePeer(viewerID)
        guard let routeID = try? ClipLiveShareRouteID(rawValue: viewerID),
              pendingViewerRoutes[routeID] != nil else { return }
        await signaling.closeRoute(routeID)
        await removePendingRoute(routeID, removesPeer: false)
    }

    private func rejectNativeViewerProtocol(_ viewerID: String) async {
        peerHost?.removePeer(viewerID)
        guard let routeID = try? ClipLiveShareRouteID(rawValue: viewerID) else {
            return
        }
        await nativeRendezvous.closeRoute(
            routeID,
            reason: "native-protocol-rejected"
        )
        await removePendingNativeRoute(routeID, removesPeer: false)
    }

    private func removePendingNativeRoute(
        _ routeID: ClipLiveShareRouteID,
        removesPeer: Bool
    ) async {
        nativePeerHandoff.peerTerminated(routeID)
        pendingNativeApprovalRouteIDs.remove(routeID)
        nativeViewerRoutes[routeID] = nil
        let viewerID = routeID.rawValue
        guard !establishedControlViewerIDs.contains(viewerID) else { return }
        peerNegotiation.remove(viewerID)
        negotiationIDs[viewerID] = nil
        viewerSessionIDs[viewerID] = nil
        nativeAdmittedViewerIdentities[viewerID] = nil
        nativeControlViewerIdentities[viewerID] = nil
        nativeControlViewerCapabilities[viewerID] = nil
        nativeControlStateRevisions[viewerID] = nil
        if removesPeer { peerHost?.removePeer(viewerID) }
    }

    private func nativeViewerAdmissionTimedOut(
        _ routeID: ClipLiveShareRouteID
    ) async {
        guard nativeViewerRoutes[routeID] != nil,
              !establishedControlViewerIDs.contains(routeID.rawValue) else {
            return
        }
        await removePendingNativeRoute(routeID, removesPeer: true)
    }

    private func scheduleAdmissionTimeout(for routeID: ClipLiveShareRouteID) {
        admissionTimeoutTasks.removeValue(forKey: routeID)?.cancel()
        admissionTimeoutTasks[routeID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard let self,
                  pendingViewerRoutes[routeID] != nil,
                  !establishedControlViewerIDs.contains(routeID.rawValue) else { return }
            await signaling.closeRoute(routeID)
            await removePendingRoute(routeID, removesPeer: true)
        }
    }

    private func cancelAdmissionTimeouts() {
        for task in admissionTimeoutTasks.values { task.cancel() }
        admissionTimeoutTasks.removeAll()
        preparedViewerRouteIDs.removeAll()
    }

    private func clearNativeViewerState() {
        nativePeerHandoff.removeAll()
        for task in nativeFriendResponseRetryTasks.values { task.cancel() }
        nativeFriendResponseRetryTasks.removeAll()
        nativeFriendCommit.removeAll()
        pendingNativeApprovalRouteIDs.removeAll()
        nativeViewerRoutes.removeAll()
        nativeAdmittedViewerIdentities.removeAll()
        nativeControlViewerIdentities.removeAll()
        nativeControlViewerCapabilities.removeAll()
        nativeControlStateRevisions.removeAll()
    }

    private func handleCapturePipelineEvent(_ event: LiveShareCapturePipelineEvent) async {
        switch event {
        case let .sourceStarted(_, source, generation):
            guard captureGenerations[source.id] == generation else { return }
            sourceStatuses[source.id] = .live
            do {
                try reconcileSharingStartIfReady()
            } catch {
                fail(code: .captureFailed, error: error)
                return
            }
            publish()

        case let .sourceStopped(_, source, generation):
            guard captureGenerations[source.id] == generation else { return }
            sourceStatuses[source.id] = nil
            publish()

        case let .sourceFailed(_, source, generation, message):
            guard captureGenerations[source.id] == generation else { return }
            await handleUnexpectedSourceFailure(source, message: message)

        case let .systemAudioFailed(message):
            await handleSystemAudioFailure(message)
        }
    }

    private func focusedWindowDidChange(_ value: FocusedLiveShareWindow?) {
        focusedWindow = value
        if let value {
            let windowID = LiveShareWindowID(rawValue: value.window.id)
            windowsByID[windowID] = value.window
            applicationPathsByWindowID[windowID] = NSRunningApplication(
                processIdentifier: value.window.processID
            )?.bundleURL?.path
        }

        guard state.snapshot.sources.fullscreen == nil else {
            publish()
            return
        }

        let sourceID = value.map {
            LiveShareSourceID.window(LiveShareWindowID(rawValue: $0.window.id))
        }
        if let sourceID, state.snapshot.sources.contains(sourceID) {
            if case let .window(windowID) = sourceID {
                let change = state.markWindowAsMostRecentlyUsed(windowID)
                _ = try? slotAllocation.apply(change)
            }
            slotAllocation.focus(sourceID)
            broadcastFocusChange()
        } else {
            slotAllocation.focus(nil)
            broadcastFocusChange()
        }
        publish()

        if settings.autoShareFocusedWindows, let value {
            shareFocusedWindow(
                requestedIdentifier: LiveShareCoordinatorPolicy.sourceIdentifier(
                    .window(LiveShareWindowID(rawValue: value.window.id))
                ),
                isAutomatic: true
            )
        }
    }

    private func shareFocusedWindow(
        requestedIdentifier: String?,
        isAutomatic: Bool = false
    ) {
        guard !isEnding,
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing,
              let focusedWindow else { return }
        requestShareWindow(
            focusedWindow.window,
            requestedIdentifier: requestedIdentifier,
            isAutomatic: isAutomatic
        )
    }

    private func shareWindow(identifier: String) {
        guard case let .window(windowID)? = LiveShareCoordinatorPolicy.sourceID(
            from: identifier
        ), let targetWindow = windowsByID[windowID] else { return }
        requestShareWindow(
            targetWindow,
            requestedIdentifier: identifier,
            isAutomatic: false
        )
    }

    private func requestShareWindow(
        _ targetWindow: ShareableCaptureWindow,
        requestedIdentifier: String?,
        isAutomatic: Bool
    ) {
        let windowID = LiveShareWindowID(rawValue: targetWindow.id)
        if isAutomatic {
            latestAutomaticWindowID = windowID
        }
        enqueueSourceTransition { coordinator in
            if isAutomatic, coordinator.latestAutomaticWindowID != windowID {
                return
            }
            await coordinator.performShareWindow(
                targetWindow,
                requestedIdentifier: requestedIdentifier,
                isAutomatic: isAutomatic
            )
        }
    }

    private func performShareWindow(
        _ targetWindow: ShareableCaptureWindow,
        requestedIdentifier: String?,
        isAutomatic: Bool
    ) async {
        guard !isEnding,
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing,
              ShareableApplicationWindowEligibility.isEligible(
                  targetWindow,
                  minimumPointSize: CGSize(width: 100, height: 100)
              ) else { return }
        let windowID = LiveShareWindowID(rawValue: targetWindow.id)
        let sourceID = LiveShareSourceID.window(windowID)
        if let requestedIdentifier,
           requestedIdentifier != LiveShareCoordinatorPolicy.sourceIdentifier(sourceID) {
            return
        }
        if isAutomatic {
            guard settings.autoShareFocusedWindows,
                  latestAutomaticWindowID == windowID,
                  state.snapshot.sources.fullscreen == nil else { return }
        }
        let source = LiveShareSource.window(LiveShareWindowSource(
            id: windowID,
            windowName: targetWindow.title,
            appName: targetWindow.applicationName
        ))
        if state.snapshot.sources.contains(sourceID) {
            if isAutomatic {
                await retainOnlyAutomaticWindow(source)
            }
            slotAllocation.focus(sourceID)
            broadcastFocusChange()
            publish()
            return
        }
        guard permitsWindowShare(sourceID) else {
            NSSound.beep()
            publish()
            return
        }
        if let fullscreen = state.snapshot.sources.fullscreen {
            await stopSource(.fullscreen(fullscreen.id))
        }
        guard !isEnding,
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing else { return }
        _ = await startSource(
            source,
            window: targetWindow,
            display: nil,
            replacesExistingWindows: isAutomatic
        )
    }

    private func retainOnlyAutomaticWindow(_ source: LiveShareSource) async {
        guard case let .window(window) = source else { return }
        let oldAllocation = slotAllocation
        let change = state.replaceWindows(with: window)
        guard change.changed else { return }
        do {
            try slotAllocation.apply(change)
        } catch {
            fail(code: .captureFailed, error: error)
            return
        }
        for removed in change.removed {
            if let oldSlot = oldAllocation.slot(for: removed.id) {
                await stopCaptureOnly(source: removed, slot: oldSlot.index)
            }
        }
    }

    private func permitsWindowShare(_ sourceID: LiveShareSourceID) -> Bool {
        let sources = state.snapshot.sources
        return LiveShareCoordinatorPolicy.permitsWindowShare(
            isAlreadyShared: sources.contains(sourceID),
            hasFullscreenSource: sources.fullscreen != nil,
            activeWindowCount: sources.windows.count,
            autoShareEnabled: settings.autoShareFocusedWindows
        )
    }

    /// Serializes manual additions and exclusive auto-share replacements across
    /// suspension points so capture teardown and stable slot reuse cannot race.
    private func enqueueSourceTransition(
        _ operation: @escaping @MainActor (LiveShareCoordinator) async -> Void
    ) {
        let previous = sourceTransitionTask
        let pendingCodecChange = codecChangeTask
        let taskID = UUID()
        let generation = sourceTransitionGeneration
        sourceTransitionTaskID = taskID
        sourceTransitionTask = Task { @MainActor [weak self] in
            await previous?.value
            await pendingCodecChange?.value
            guard let self,
                  !Task.isCancelled,
                  sourceTransitionGeneration == generation,
                  !isEnding else { return }
            await operation(self)
            if sourceTransitionTaskID == taskID {
                sourceTransitionTaskID = nil
                sourceTransitionTask = nil
            }
        }
    }

    private func invalidateSourceTransitions() {
        sourceTransitionGeneration &+= 1
        sourceTransitionTask?.cancel()
        sourceTransitionTask = nil
        sourceTransitionTaskID = nil
        latestAutomaticWindowID = nil
    }

    private func setFullscreenEnabled(_ enabled: Bool) {
        let request = fullscreenRequestGate.begin(isEnabled: enabled)
        enqueueSourceTransition { coordinator in
            defer {
                coordinator.fullscreenRequestGate.finish(request)
            }
            guard coordinator.fullscreenRequestGate.contains(request) else { return }
            if enabled {
                await coordinator.startFullscreen(request: request)
            } else if let fullscreen = coordinator.state.snapshot.sources.fullscreen {
                await coordinator.stopSource(.fullscreen(fullscreen.id))
                guard coordinator.fullscreenRequestGate.contains(request) else { return }
                if coordinator.settings.autoShareFocusedWindows,
                   coordinator.focusedWindow != nil {
                    coordinator.shareFocusedWindow(
                        requestedIdentifier: nil,
                        isAutomatic: true
                    )
                }
            }
        }
    }

    private func startFullscreen(
        request: LiveShareFullscreenRequestGate.Request
    ) async {
        guard !isEnding,
              fullscreenRequestGate.contains(request),
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing else { return }
        do {
            let content = try await discovery.shareableContent(
                excludingBundleIdentifier: ApplicationDirectories.bundleIdentifier
            )
            guard fullscreenRequestGate.contains(request), !isEnding else { return }
            guard let display = LiveShareCoordinatorPolicy.preferredFullscreenDisplay(
                from: content.displays,
                focusedWindowFrame: focusedWindow?.window.frame,
                primaryDisplayID: CGMainDisplayID()
            ) else {
                throw CaptureSessionError.displayUnavailable(CGMainDisplayID())
            }

            var knownWindows = windowsByID
            for window in content.windows {
                knownWindows[LiveShareWindowID(rawValue: window.id)] = window
            }
            let rollbackPlan = LiveShareCoordinatorPolicy.fullscreenRollbackPlan(
                sources: state.snapshot.sources,
                slots: slotAllocation,
                knownWindows: knownWindows
            )
            let previousStartedAt = startedAt
            let hadActiveSources = !state.snapshot.sources.isEmpty
            if !state.snapshot.sources.isEmpty {
                await stopAllMedia()
            }
            guard !isEnding else { return }
            switch fullscreenRequestGate.actionAfterDestructiveStop(for: request) {
            case .continueToFullscreen:
                break
            case .restoreWindows:
                await completeFullscreenRollback(
                    from: rollbackPlan,
                    request: request,
                    previousStartedAt: previousStartedAt,
                    hadActiveSources: hadActiveSources
                )
                return
            case .abandon:
                return
            }

            let displayID = LiveShareDisplayID(rawValue: display.id)
            let displayName = screen(for: display.id)?.localizedName
                ?? String(localized: "Main Display")
            let source = LiveShareSource.fullscreen(LiveShareDisplaySource(
                id: displayID,
                displayName: displayName
            ))
            displayFramesByID[displayID] = screen(for: display.id)?.frame ?? display.frame
            let didStart = await startSource(
                source,
                window: nil,
                display: display,
                failsSessionWhenNoSources: false
            )
            guard !isEnding else { return }
            let postStartAction = fullscreenRequestGate.actionAfterDestructiveStop(
                for: request
            )
            if didStart {
                if postStartAction == .restoreWindows {
                    await stopSource(source.id)
                    await completeFullscreenRollback(
                        from: rollbackPlan,
                        request: request,
                        previousStartedAt: previousStartedAt,
                        hadActiveSources: hadActiveSources
                    )
                }
                return
            }

            guard state.snapshot.phase != .failed else { return }
            switch postStartAction {
            case .continueToFullscreen:
                if hadActiveSources {
                    await completeFullscreenRollback(
                        from: rollbackPlan,
                        request: request,
                        previousStartedAt: previousStartedAt,
                        hadActiveSources: true
                    )
                } else {
                    fail(
                        code: .captureFailed,
                        technicalDescription: "Fullscreen capture could not start."
                    )
                }
            case .restoreWindows:
                await completeFullscreenRollback(
                    from: rollbackPlan,
                    request: request,
                    previousStartedAt: previousStartedAt,
                    hadActiveSources: hadActiveSources
                )
            case .abandon:
                return
            }
        } catch {
            guard fullscreenRequestGate.contains(request) else { return }
            // Discovery and target selection happen before any existing media
            // is stopped. Keep those healthy sources live when fullscreen
            // cannot even be prepared.
            if state.snapshot.sources.isEmpty {
                fail(code: .captureFailed, error: error)
            } else {
                Self.logger.error(
                    "Fullscreen capture could not be prepared: \(error.localizedDescription, privacy: .public)"
                )
                NSSound.beep()
                publish()
            }
        }
    }

    private func completeFullscreenRollback(
        from plan: LiveShareFullscreenRollbackPlan,
        request: LiveShareFullscreenRequestGate.Request,
        previousStartedAt: Date?,
        hadActiveSources: Bool
    ) async {
        guard hadActiveSources,
              fullscreenRequestGate.permitsWindowRollback(for: request),
              !isEnding else { return }
        let didRestore = await restoreWindowShares(
            from: plan,
            request: request,
            previousStartedAt: previousStartedAt
        )
        guard fullscreenRequestGate.permitsWindowRollback(for: request),
              !isEnding else { return }
        if !didRestore {
            fail(
                code: .captureFailed,
                technicalDescription: "Fullscreen capture failed and the previous window shares could not be restored."
            )
        }
    }

    private func restoreWindowShares(
        from plan: LiveShareFullscreenRollbackPlan,
        request: LiveShareFullscreenRequestGate.Request,
        previousStartedAt: Date?
    ) async -> Bool {
        guard !plan.isEmpty else { return false }
        var restoredAny = false
        for entry in plan.windows {
            guard fullscreenRequestGate.permitsWindowRollback(for: request), !isEnding else {
                return restoredAny
            }
            let restored = await startSource(
                .window(entry.source),
                window: entry.window,
                display: nil,
                failsSessionWhenNoSources: false
            )
            guard fullscreenRequestGate.permitsWindowRollback(for: request), !isEnding else {
                return restoredAny || restored
            }
            restoredAny = restoredAny || restored
        }

        guard restoredAny else { return false }
        if let focusedSourceID = plan.focusedSourceID,
           state.snapshot.sources.contains(focusedSourceID) {
            slotAllocation.focus(focusedSourceID)
        }
        startedAt = previousStartedAt ?? startedAt
        broadcastFocusChange()
        updateCursorLoop()
        publish()
        return true
    }

    @discardableResult
    private func startSource(
        _ source: LiveShareSource,
        window: ShareableCaptureWindow?,
        display: ShareableCaptureDisplay?,
        failsSessionWhenNoSources: Bool = true,
        replacesExistingWindows: Bool = false
    ) async -> Bool {
        let sourceID = source.id
        guard !sourceOperationIDs.contains(sourceID),
              state.snapshot.phase == .ready || state.snapshot.phase == .sharing else {
            return false
        }
        sourceOperationIDs.insert(sourceID)
        defer { sourceOperationIDs.remove(sourceID) }

        let oldAllocation = slotAllocation
        let change: LiveShareSourceChange
        if replacesExistingWindows, case let .window(windowSource) = source {
            change = state.replaceWindows(with: windowSource)
        } else {
            change = state.addSource(source)
        }
        do {
            try slotAllocation.apply(change)
        } catch {
            _ = state.removeSource(sourceID)
            if failsSessionWhenNoSources && state.snapshot.sources.isEmpty {
                fail(code: .captureFailed, error: error)
            } else {
                Self.logger.error(
                    "A Live Share source could not be allocated: \(error.localizedDescription, privacy: .public)"
                )
                publish()
            }
            return false
        }

        for removed in change.removed {
            if let oldSlot = oldAllocation.slot(for: removed.id) {
                await stopCaptureOnly(source: removed, slot: oldSlot.index)
            }
        }

        guard let slot = slotAllocation.slot(for: sourceID) else {
            _ = state.removeSource(sourceID)
            if failsSessionWhenNoSources && state.snapshot.sources.isEmpty {
                fail(
                    code: .captureFailed,
                    technicalDescription: "No stable WebRTC slot was assigned."
                )
            } else {
                Self.logger.error("No stable WebRTC slot was assigned.")
                publish()
            }
            return false
        }

        let generation = UUID()
        captureGenerations[sourceID] = generation
        do {
            let descriptor = try makeDescriptor(
                for: source,
                slot: slot,
                window: window,
                display: display
            )
            captureDescriptors[sourceID] = descriptor
            sourceStatuses[sourceID] = .starting
            if state.snapshot.phase == .ready {
                try state.beginSharing()
            }
            publish()
            try await capturePipeline?.start(
                descriptor,
                inSlot: slot.index,
                generation: generation
            )
            guard captureGenerations[sourceID] == generation else { return false }
            sourceStatuses[sourceID] = .live
            slotAllocation.focus(sourceID)
            try reconcileSharingStartIfReady()
            broadcastAuthoritativeControlMutation()
            broadcastFocusChange()
            updateCursorLoop()
            publish()
            return true
        } catch {
            guard captureGenerations[sourceID] == generation,
                  state.snapshot.sources.contains(sourceID) else {
                return false
            }
            captureGenerations[sourceID] = nil
            captureDescriptors[sourceID] = nil
            sourceStatuses[sourceID] = nil
            let removal = state.removeSource(sourceID)
            _ = try? slotAllocation.apply(removal)
            if failsSessionWhenNoSources && state.snapshot.sources.isEmpty {
                fail(code: .captureFailed, error: error)
            } else {
                Self.logger.error(
                    "A Live Share source failed: \(error.localizedDescription, privacy: .public)"
                )
                publish()
            }
            return false
        }
    }

    /// Completes the first-source transition only when capture is actually
    /// live. This keeps reconnect-during-start distinct from an established
    /// share and also reconsiders the latest focus that may have changed while
    /// source startup was suspended.
    private func reconcileSharingStartIfReady() throws {
        guard state.snapshot.phase == .starting,
              sourceStatuses.values.contains(.live) else { return }
        try state.markSharingStarted()
        startedAt = startedAt ?? Date()
        broadcastAuthoritativeControlMutation()
        if settings.autoShareFocusedWindows,
           state.snapshot.sources.fullscreen == nil,
           focusedWindow != nil {
            shareFocusedWindow(requestedIdentifier: nil, isAutomatic: true)
        }
    }

    private func makeDescriptor(
        for source: LiveShareSource,
        slot: LiveShareTrackSlot,
        window: ShareableCaptureWindow?,
        display: ShareableCaptureDisplay?
    ) throws -> LiveShareCaptureDescriptor {
        let width: Int
        let height: Int
        let target: CaptureTarget
        let windowName: String
        let appName: String
        let sourcePointWidth: Int
        let sourcePointHeight: Int

        switch source {
        case let .window(windowSource):
            guard let window, window.id == windowSource.id.rawValue else {
                throw CaptureSessionError.windowUnavailable(windowSource.id.rawValue)
            }
            width = window.pixelWidth
            height = window.pixelHeight
            sourcePointWidth = window.capturePointWidth
            sourcePointHeight = window.capturePointHeight
            target = .window(id: window.id)
            windowName = windowSource.windowName
            appName = windowSource.appName
            windowsByID[windowSource.id] = window

        case let .fullscreen(displaySource):
            guard let display, display.id == displaySource.id.rawValue else {
                throw CaptureSessionError.displayUnavailable(displaySource.id.rawValue)
            }
            width = display.pixelWidth
            height = display.pixelHeight
            sourcePointWidth = max(1, Int(display.frame.width.rounded()))
            sourcePointHeight = max(1, Int(display.frame.height.rounded()))
            target = .display(
                id: display.id,
                excludedBundleIdentifier: ApplicationDirectories.bundleIdentifier
            )
            windowName = displaySource.displayName
            appName = String(localized: "Fullscreen")
        }

        let geometry = LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: width,
            sourceHeight: height,
            codec: settings.videoCodec,
            framesPerSecond: settings.frameRate.rawValue
        )
        let streamGeometry = LiveShareCoordinatorPolicy.streamGeometry(
            captureGeometry: geometry,
            codec: settings.videoCodec
        )
        guard let browserTrackID = peerHost?.slotSnapshots
            .first(where: { $0.index == slot.index })?.trackID else {
            throw LiveShareTransitionError.invalidTransition(
                from: state.snapshot.phase,
                operation: "missingWebRTCTrack"
            )
        }
        let stream = try ClipLiveShareStreamDescriptor(
            id: slot.streamIdentity,
            mediaTrackID: ClipLiveShareMediaTrackID(rawValue: browserTrackID),
            active: true,
            focused: slot.isFocused,
            appName: appName,
            windowName: windowName,
            width: streamGeometry.width,
            height: streamGeometry.height,
            order: slot.index,
            sourcePointWidth: sourcePointWidth,
            sourcePointHeight: sourcePointHeight
        )
        return LiveShareCaptureDescriptor(
            source: source,
            target: target,
            sourcePixelWidth: width,
            sourcePixelHeight: height,
            video: LiveShareCoordinatorPolicy.captureVideoConfiguration(
                width: geometry.width,
                height: geometry.height,
                framesPerSecond: settings.frameRate.rawValue,
                codec: settings.videoCodec,
                colorMode: settings.colorMode,
                showsCursor: slot.isFocused
            ),
            stream: stream
        )
    }

    private func stopSource(identifier: String) {
        guard let sourceID = LiveShareCoordinatorPolicy.sourceID(from: identifier) else { return }
        enqueueSourceTransition { coordinator in
            await coordinator.stopSource(sourceID)
        }
    }

    private func stopSource(_ sourceID: LiveShareSourceID) async {
        guard sourceStatuses[sourceID] != .stopping,
              let slot = slotAllocation.slot(for: sourceID),
              let source = slot.source else { return }
        sourceOperationIDs.insert(sourceID)
        sourceStatuses[sourceID] = .stopping
        publish()
        captureGenerations[sourceID] = nil
        await stopCaptureOnly(source: source, slot: slot.index)
        let change = state.removeSource(sourceID)
        _ = try? slotAllocation.apply(change)
        sourceStatuses[sourceID] = nil
        captureDescriptors[sourceID] = nil
        sourceOperationIDs.remove(sourceID)

        if state.snapshot.sources.isEmpty {
            latestStatistics = .init()
        } else {
            slotAllocation.focus(slotAllocation.activeSlots.first?.source?.id)
            broadcastFocusChange()
        }
        updateCursorLoop()
        publish()
    }

    private func stopCaptureOnly(source: LiveShareSource, slot: Int) async {
        captureGenerations[source.id] = nil
        try? await capturePipeline?.stop(slot: slot)
        sourceStatuses[source.id] = nil
        captureDescriptors[source.id] = nil
        broadcastAuthoritativeControlMutation()
    }

    private func requestStopAllMedia() {
        fullscreenRequestGate.invalidate()
        latestAutomaticWindowID = nil
        enqueueSourceTransition { coordinator in
            await coordinator.stopAllMedia()
        }
    }

    private func stopAllMedia() async {
        guard !state.snapshot.sources.isEmpty else { return }
        if state.snapshot.phase == .starting || state.snapshot.phase == .sharing {
            try? state.beginStopping()
        }
        for slot in slotAllocation.activeSlots {
            if let source = slot.source { sourceStatuses[source.id] = .stopping }
        }
        publish()

        captureGenerations.removeAll()
        await capturePipeline?.stopAll()
        if state.snapshot.phase == .stopping {
            try? state.completeStopping()
        } else {
            _ = state.clearSources()
        }
        slotAllocation.clear()
        captureDescriptors.removeAll()
        captureGenerations.removeAll()
        sourceStatuses.removeAll()
        sourceOperationIDs.removeAll()
        latestStatistics = .init()
        broadcastAuthoritativeControlMutation()
        updateCursorLoop()
        publish()
    }

    private func handleUnexpectedSourceFailure(
        _ source: LiveShareSource,
        message: String
    ) async {
        guard let slot = slotAllocation.slot(for: source.id) else { return }
        captureGenerations[source.id] = nil
        try? await capturePipeline?.stop(slot: slot.index)
        let removal = state.removeSource(source.id)
        _ = try? slotAllocation.apply(removal)
        sourceStatuses[source.id] = nil
        captureDescriptors[source.id] = nil
        broadcastAuthoritativeControlMutation()
        if state.snapshot.sources.isEmpty {
            latestStatistics = .init()
            Self.logger.error("The final Live Share capture stopped: \(message, privacy: .public)")
            publish()
        } else {
            if !slotAllocation.activeSlots.contains(where: \.isFocused) {
                slotAllocation.focus(slotAllocation.activeSlots.first?.source?.id)
            }
            broadcastFocusChange()
            Self.logger.error("A Live Share capture stopped: \(message, privacy: .public)")
            publish()
        }
    }

    private func setAccessCodeEnabled(_ enabled: Bool) {
        Task { @MainActor [weak self] in
            await self?.updateAccessCode(enabled: enabled)
        }
    }

    private func replaceAccessCode() {
        Task { @MainActor [weak self] in
            await self?.updateAccessCode(enabled: true)
        }
    }

    private func updateAccessCode(enabled: Bool) async {
        guard !isEnding,
              !accessCodeIsUpdating,
              state.snapshot.room != nil,
              [.ready, .starting, .sharing].contains(state.snapshot.phase) else { return }
        accessCodeIsUpdating = true
        accessCodeError = nil
        publish()
        do {
            let updatedCode = enabled ? try LiveShareAccessCode.generate() : nil
            guard !isEnding else { return }
            settings.accessCodeEnabled = enabled
            accessCode = updatedCode
            persistSettings()
            // Replacing or disabling the code is a revocation boundary for
            // viewers still in admission. Established P2P viewers remain;
            // pending browsers reconnect and receive a fresh challenge using
            // the new setting.
            for routeID in Array(pendingViewerRoutes.keys) {
                await signaling.closeRoute(routeID)
                await removePendingRoute(routeID, removesPeer: true)
            }
        } catch {
            accessCodeError = String(localized: "Couldn’t update the access code. Try again.")
            Self.logger.error(
                "Could not update the Live Share access code: \(error.localizedDescription, privacy: .public)"
            )
        }
        accessCodeIsUpdating = false
        publish()
    }

    private func setQuality(_ quality: LiveShareQualityPreset) {
        settings.quality = quality
        applySenderPolicyAndPersist()
    }

    private func setSystemAudioEnabled(_ enabled: Bool) {
        settings.systemAudioEnabled = enabled
        persistSettings()
        publish()
    }

    private func scheduleSystemAudioReconciliation() {
        guard let pipeline = capturePipeline else {
            desiredSystemAudioRequest = nil
            return
        }
        let domain = state.snapshot
        let supportsActiveCapture = !isEnding && [
            LiveSharePhase.ready,
            .starting,
            .sharing,
            .reconnecting,
        ].contains(domain.phase)
        let request = LiveShareCoordinatorPolicy.captureAudioRequest(
            systemAudioEnabled: settings.systemAudioEnabled && supportsActiveCapture,
            sources: domain.sources,
            knownWindows: windowsByID,
            filterDisplayID: CGMainDisplayID(),
            clipBundleIdentifier: ApplicationDirectories.bundleIdentifier,
            requestIdentifier: systemAudioRequestIdentifier
        )
        guard request != desiredSystemAudioRequest else { return }
        desiredSystemAudioRequest = request

        let previous = systemAudioReconcileTask
        let taskID = UUID()
        systemAudioReconcileTaskID = taskID
        systemAudioReconcileTask = Task { @MainActor [weak self] in
            // Enabling and filter changes stay ordered, but a disable must
            // preempt an in-flight ScreenCaptureKit start/update immediately.
            // The pipeline's retirement gate then drains that older operation
            // without allowing another audio sample onto the sender.
            if request != nil {
                await previous?.value
            }
            guard let self,
                  !Task.isCancelled,
                  systemAudioReconcileTaskID == taskID,
                  desiredSystemAudioRequest == request,
                  capturePipeline === pipeline else { return }
            if request == nil {
                setAuthoritativeSystemAudioActive(false)
            }
            do {
                try await pipeline.setSystemAudio(request)
                guard systemAudioReconcileTaskID == taskID,
                      desiredSystemAudioRequest == request,
                      capturePipeline === pipeline else { return }
                setAuthoritativeSystemAudioActive(request != nil)
            } catch {
                guard systemAudioReconcileTaskID == taskID,
                      desiredSystemAudioRequest == request else { return }
                await handleSystemAudioFailure(error.localizedDescription)
            }
            if systemAudioReconcileTaskID == taskID {
                systemAudioReconcileTaskID = nil
                systemAudioReconcileTask = nil
            }
        }
    }

    private func handleSystemAudioFailure(_ message: String) async {
        Self.logger.error(
            "Live Share system audio stopped: \(message, privacy: .public)"
        )
        guard settings.systemAudioEnabled else { return }
        settings.systemAudioEnabled = false
        desiredSystemAudioRequest = nil
        setAuthoritativeSystemAudioActive(false)
        try? await capturePipeline?.setSystemAudio(nil)
        persistSettings()
        NSSound.beep()
        publish()
    }

    private func setAuthoritativeSystemAudioActive(_ isActive: Bool) {
        guard systemAudioIsActive != isActive else { return }
        systemAudioIsActive = isActive
        broadcastAuthoritativeControlMutation()
    }

    @discardableResult
    private func cancelSystemAudioReconciliation() -> Task<Void, Never>? {
        let task = systemAudioReconcileTask
        task?.cancel()
        systemAudioReconcileTask = nil
        systemAudioReconcileTaskID = nil
        desiredSystemAudioRequest = nil
        systemAudioIsActive = false
        return task
    }

    private func setFrameRate(_ frameRate: LiveShareFrameRate) {
        guard codecChangeTask == nil,
              availableFrameRates.contains(frameRate) else { return }
        let oldFrameRate = settings.frameRate
        settings.frameRate = frameRate
        applySenderPolicyAndPersist()
        if oldFrameRate != frameRate, !state.snapshot.sources.isEmpty {
            scheduleActiveCaptureRestart()
        }
    }

    private func setCursorUpdatesMatchFrameRate(_ enabled: Bool) {
        guard settings.cursorUpdatesMatchFrameRate != enabled else { return }
        settings.cursorUpdatesMatchFrameRate = enabled
        persistSettings()
        publish()
    }

    private func setColorMode(_ colorMode: LiveShareColorMode) {
        guard codecChangeTask == nil,
              settings.colorMode != colorMode else { return }
        settings.colorMode = colorMode
        persistSettings()
        publish()
        if !state.snapshot.sources.isEmpty {
            scheduleActiveCaptureRestart()
        }
    }

    private func requestVideoCodecChange(_ codec: LiveShareVideoCodec) {
        guard codec != settings.videoCodec, codecChangeTask == nil else { return }
        guard let host = peerHost else {
            settings.videoCodec = codec
            persistSettings()
            publish()
            return
        }

        let previousCodec = settings.videoCodec
        let pendingSourceTransition = sourceTransitionTask
        let pendingCaptureRestart = captureRestartTask
        codecChangeTask = Task { @MainActor [weak self, weak host] in
            await pendingSourceTransition?.value
            await pendingCaptureRestart?.value
            guard let self, let host else { return }
            guard !Task.isCancelled,
                  !isEnding,
                  peerHost === host,
                  settings.videoCodec == previousCodec else {
                codecChangeTask = nil
                publish()
                return
            }
            let reservedSourceIDs = Set(slotAllocation.activeSlots.compactMap(\.source?.id))
            sourceOperationIDs.formUnion(reservedSourceIDs)
            defer {
                sourceOperationIDs.subtract(reservedSourceIDs)
                if captureDescriptors.values.contains(where: {
                    $0.video.framesPerSecond != settings.frameRate.rawValue
                }) {
                    scheduleActiveCaptureRestart()
                }
            }
            do {
                try await performVideoCodecChange(
                    from: previousCodec,
                    to: codec,
                    host: host
                )
                guard !Task.isCancelled,
                      !isEnding,
                      peerHost === host else { return }
                settings.videoCodec = codec
                persistSettings()
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.error(
                    "Could not change the Live Share codec: \(error.localizedDescription, privacy: .public)"
                )
                if LiveShareCaptureGeometryFailurePolicy.requiresSessionFailure(
                    after: error
                ) {
                    // A failed rollback means codec and capture geometry can
                    // no longer be proven coherent. Quiesce the complete room
                    // instead of leaving an oversized buffer on H.264 and
                    // presenting another black-screen session as live.
                    fail(code: .captureFailed, error: error)
                }
            }
            codecChangeTask = nil
            publish()
        }
        publish()
    }

    /// Couples codec renegotiation to ScreenCaptureKit geometry without ever
    /// presenting an unsupported 5K/6K buffer to VideoToolbox. The safe order
    /// differs by direction: cap before enabling H.264; enable any software
    /// codec before restoring native pixels. Either failure returns capture
    /// and codec to the previous coherent pair.
    private func performVideoCodecChange(
        from previousCodec: LiveShareVideoCodec,
        to codec: LiveShareVideoCodec,
        host: WebRTCPeerHost
    ) async throws {
        if previousCodec != .h264, codec == .h264 {
            let previousGeometry = try await transitionActiveCaptureGeometry(to: .h264)
            do {
                try await host.updateVideoCodec(.h264)
            } catch {
                do {
                    try await restoreCaptureGeometry(previousGeometry)
                } catch let rollbackError {
                    throw LiveShareCaptureGeometryTransitionError.rollbackFailed(
                        change: error.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
                }
                throw error
            }
        } else if previousCodec == .h264, codec != .h264 {
            try await host.updateVideoCodec(webRTCVideoCodec(codec))
            do {
                _ = try await transitionActiveCaptureGeometry(to: codec)
            } catch {
                do {
                    try await host.updateVideoCodec(.h264)
                } catch let rollbackError {
                    throw LiveShareCaptureGeometryTransitionError.rollbackFailed(
                        change: error.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
                }
                throw error
            }
        } else {
            try await host.updateVideoCodec(webRTCVideoCodec(codec))
        }
    }

    /// Reconfigures active ScreenCaptureKit streams in place and returns the
    /// exact descriptors needed by a later codec-negotiation rollback.
    private func transitionActiveCaptureGeometry(
        to codec: LiveShareVideoCodec
    ) async throws -> [LiveShareCaptureGeometrySnapshot] {
        guard let pipeline = capturePipeline else { return [] }
        let changes = slotAllocation.activeSlots.compactMap {
            slot -> (LiveShareCaptureGeometrySnapshot, LiveShareCaptureDescriptor)? in
            guard let source = slot.source,
                  let generation = captureGenerations[source.id],
                  let current = captureDescriptors[source.id] else { return nil }
            let requested = descriptor(
                current,
                using: codec,
                framesPerSecond: settings.frameRate.rawValue
            )
            guard current != requested else { return nil }
            return (
                LiveShareCaptureGeometrySnapshot(
                    sourceID: source.id,
                    slot: slot.index,
                    generation: generation,
                    descriptor: current
                ),
                requested
            )
        }
        guard !changes.isEmpty else { return [] }

        var applied: [LiveShareCaptureGeometrySnapshot] = []
        do {
            for (previous, requested) in changes {
                try await pipeline.update(
                    requested,
                    inSlot: previous.slot,
                    expectedGeneration: previous.generation
                )
                guard captureGenerations[previous.sourceID] == previous.generation,
                      slotAllocation.slot(for: previous.sourceID)?.index == previous.slot,
                      !isEnding else {
                    throw LiveShareCapturePipelineError.superseded(previous.slot)
                }
                captureDescriptors[previous.sourceID] = requested
                applied.append(previous)
            }
        } catch {
            do {
                try await restoreCaptureGeometry(applied.reversed())
            } catch let rollbackError {
                throw LiveShareCaptureGeometryTransitionError.rollbackFailed(
                    change: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }

        broadcastSizeChanges(for: changes.map { $0.1 })
        publish()
        return changes.map { $0.0 }
    }

    private func restoreCaptureGeometry<S: Sequence>(
        _ snapshots: S
    ) async throws where S.Element == LiveShareCaptureGeometrySnapshot {
        guard let pipeline = capturePipeline else { return }
        var restored: [LiveShareCaptureDescriptor] = []
        for snapshot in snapshots {
            guard captureGenerations[snapshot.sourceID] == snapshot.generation,
                  slotAllocation.slot(for: snapshot.sourceID)?.index == snapshot.slot,
                  !isEnding else {
                throw LiveShareCapturePipelineError.superseded(snapshot.slot)
            }
            try await pipeline.update(
                snapshot.descriptor,
                inSlot: snapshot.slot,
                expectedGeneration: snapshot.generation
            )
            captureDescriptors[snapshot.sourceID] = snapshot.descriptor
            restored.append(snapshot.descriptor)
        }
        broadcastSizeChanges(for: restored)
        publish()
    }

    private func descriptor(
        _ descriptor: LiveShareCaptureDescriptor,
        using codec: LiveShareVideoCodec,
        framesPerSecond: Int
    ) -> LiveShareCaptureDescriptor {
        let geometry = LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: descriptor.sourcePixelWidth,
            sourceHeight: descriptor.sourcePixelHeight,
            codec: codec,
            framesPerSecond: framesPerSecond
        )
        let streamGeometry = LiveShareCoordinatorPolicy.streamGeometry(
            captureGeometry: geometry,
            codec: codec
        )
        return LiveShareCaptureDescriptor(
            source: descriptor.source,
            target: descriptor.target,
            sourcePixelWidth: descriptor.sourcePixelWidth,
            sourcePixelHeight: descriptor.sourcePixelHeight,
            video: LiveShareCoordinatorPolicy.captureVideoConfiguration(
                width: geometry.width,
                height: geometry.height,
                framesPerSecond: framesPerSecond,
                codec: codec,
                colorMode: settings.colorMode,
                showsCursor: descriptor.video.showsCursor,
                sourceRect: descriptor.video.sourceRect
            ),
            stream: try! ClipLiveShareStreamDescriptor(
                id: descriptor.stream.id,
                mediaTrackID: descriptor.stream.mediaTrackID,
                active: descriptor.stream.active,
                focused: descriptor.stream.focused,
                appName: descriptor.stream.appName,
                windowName: descriptor.stream.windowName,
                width: streamGeometry.width,
                height: streamGeometry.height,
                order: descriptor.stream.order,
                sourcePointWidth: descriptor.stream.sourcePointWidth,
                sourcePointHeight: descriptor.stream.sourcePointHeight
            )
        )
    }

    private func broadcastSizeChanges(
        for descriptors: [LiveShareCaptureDescriptor]
    ) {
        guard !descriptors.isEmpty else { return }
        broadcastAuthoritativeControlMutation()
    }

    private func setPrioritizeFocusedWindow(_ enabled: Bool) {
        settings.prioritizeFocusedWindow = enabled
        applySenderPolicyAndPersist()
    }

    private func setEncodingMode(_ mode: LiveShareEncodingMode) {
        guard codecChangeTask == nil else { return }
        settings.encodingMode = mode
        peerHost?.updateVideoEncodingMode(mode)
        applySenderPolicyAndPersist()
    }

    private func setAdvancedVideoSettings(
        _ advanced: LiveShareCodecAdvancedSettings,
        for codec: LiveShareVideoCodec
    ) {
        guard codecChangeTask == nil else { return }
        let normalized = advanced.normalized(for: codec)
        settings.advancedVideoSettings.set(normalized, for: codec)
        if let encoderConfiguration = webRTCAdvancedVideoConfiguration(
            normalized,
            for: codec
        ) {
            peerHost?.updateAdvancedVideoConfiguration(encoderConfiguration)
        }
        if settings.videoCodec == codec {
            applyRuntimeSenderPolicies()
        }
        persistSettings()
        publish()
    }

    private func setAutoShareEnabled(_ enabled: Bool) {
        settings.autoShareFocusedWindows = enabled
        if !enabled {
            latestAutomaticWindowID = nil
        }
        persistSettings()
        publish()
        if enabled, state.snapshot.sources.fullscreen == nil, focusedWindow != nil {
            shareFocusedWindow(requestedIdentifier: nil, isAutomatic: true)
        }
    }

    private func applySenderPolicyAndPersist() {
        applyRuntimeSenderPolicies()
        persistSettings()
        publish()
    }

    private func applyRuntimeSenderPolicies() {
        let fallback = LiveShareCoordinatorPolicy.senderPolicy(for: settings)
        let policies = LiveShareCoordinatorPolicy.senderPolicies(
            for: settings,
            slots: slotAllocation
        )
        peerHost?.updateSenderPolicies(policies, fallback: fallback)
    }

    private func webRTCVideoCodec(_ codec: LiveShareVideoCodec) -> WebRTCVideoCodec {
        switch codec {
        case .h264: .h264
        case .vp8: .vp8
        case .vp9: .vp9
        case .av1: .av1
        }
    }

    private func webRTCAdvancedVideoConfigurations(
        _ settings: LiveShareAdvancedVideoSettings
    ) -> WebRTCAdvancedVideoConfigurations {
        WebRTCAdvancedVideoConfigurations(
            h264: webRTCH264AdvancedVideoConfiguration(settings.h264)
        )
    }

    private func webRTCAdvancedVideoConfiguration(
        _ advanced: LiveShareCodecAdvancedSettings,
        for codec: LiveShareVideoCodec
    ) -> WebRTCCodecAdvancedConfiguration? {
        let normalized = advanced.normalized(for: codec)
        switch codec {
        case .h264:
            return .h264(webRTCH264AdvancedVideoConfiguration(normalized))
        case .vp8, .vp9, .av1:
            return nil
        }
    }

    private func webRTCH264AdvancedVideoConfiguration(
        _ advanced: LiveShareCodecAdvancedSettings
    ) -> WebRTCH264AdvancedConfiguration {
        let normalized = advanced.normalized(for: .h264)
        return WebRTCH264AdvancedConfiguration(
            maximumQuantizer: normalized.maximumQuantizer,
            qualityFraction: Double(normalized.h264QualityPercent ?? 98) / 100,
            keyFrameIntervalSeconds: normalized.h264KeyFrameIntervalSeconds ?? 2
        )
    }

    private func persistSettings() {
        let value = settings
        let baseline = persistedSettingsBaseline
        persistedSettingsBaseline = value
        preferences.updateSettings { stored in
            if baseline.quality != value.quality {
                stored.quality = value.quality
            }
            if baseline.frameRate != value.frameRate {
                stored.frameRate = value.frameRate
            }
            if baseline.encodingMode != value.encodingMode {
                stored.encodingMode = value.encodingMode
            }
            if baseline.videoCodec != value.videoCodec {
                stored.videoCodec = value.videoCodec
            }
            if baseline.colorMode != value.colorMode {
                stored.colorMode = value.colorMode
            }
            if baseline.advancedVideoSettings != value.advancedVideoSettings {
                stored.advancedVideoSettings = value.advancedVideoSettings
            }
            if baseline.systemAudioEnabled != value.systemAudioEnabled {
                stored.systemAudioEnabled = value.systemAudioEnabled
            }
            if baseline.cursorUpdatesMatchFrameRate != value.cursorUpdatesMatchFrameRate {
                stored.cursorUpdatesMatchFrameRate = value.cursorUpdatesMatchFrameRate
            }
            if baseline.prioritizeFocusedWindow != value.prioritizeFocusedWindow {
                stored.prioritizeFocusedWindow = value.prioritizeFocusedWindow
            }
            if baseline.autoShareFocusedWindows != value.autoShareFocusedWindows {
                stored.autoShareFocusedWindows = value.autoShareFocusedWindows
            }
            if baseline.accessCodeEnabled != value.accessCodeEnabled {
                stored.accessCodeEnabled = value.accessCodeEnabled
            }
        }
    }

    private func scheduleActiveCaptureRestart() {
        let previous = captureRestartTask
        let pendingSourceTransition = sourceTransitionTask
        let requestID = UUID()
        captureRestartRequestID = requestID
        captureRestartTask = Task { @MainActor [weak self] in
            await pendingSourceTransition?.value
            await previous?.value
            guard let self,
                  !Task.isCancelled,
                  captureRestartRequestID == requestID else { return }
            await restartActiveCaptures(requestID: requestID)
            if captureRestartRequestID == requestID {
                captureRestartRequestID = nil
                captureRestartTask = nil
            }
        }
    }

    private func restartActiveCaptures(requestID: UUID) async {
        guard let pipeline = capturePipeline else { return }
        let active = slotAllocation.activeSlots
        for slot in active {
            guard captureRestartRequestID == requestID, !isEnding else { return }
            guard let source = slot.source,
                  let oldDescriptor = captureDescriptors[source.id],
                  !sourceOperationIDs.contains(source.id) else { continue }
            sourceOperationIDs.insert(source.id)
            defer { sourceOperationIDs.remove(source.id) }
            let descriptor = descriptor(
                oldDescriptor,
                using: settings.videoCodec,
                framesPerSecond: settings.frameRate.rawValue
            )
            sourceStatuses[source.id] = .starting
            publish()
            guard let generation = captureGenerations[source.id] else { continue }
            do {
                try await pipeline.update(
                    descriptor,
                    inSlot: slot.index,
                    expectedGeneration: generation
                )
                guard captureGenerations[source.id] == generation,
                      slotAllocation.slot(for: source.id)?.index == slot.index,
                      state.snapshot.sources.contains(source.id),
                      !isEnding else { continue }
                captureDescriptors[source.id] = descriptor
                sourceStatuses[source.id] = .live
                if descriptor.stream.width != oldDescriptor.stream.width
                    || descriptor.stream.height != oldDescriptor.stream.height
                {
                    broadcastSizeChanges(for: [descriptor])
                }
            } catch {
                guard captureGenerations[source.id] == generation else { continue }
                await handleUnexpectedSourceFailure(
                    source,
                    message: error.localizedDescription
                )
            }
        }
        publish()
    }

    private func retry() {
        guard state.snapshot.phase == .failed, retryTask == nil else { return }
        isRetrying = true
        publish()
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await failureCleanupTask?.value
            failureCleanupTask = nil
            guard !Task.isCancelled else { return }
            await resetRuntimeForRetry()
            guard !Task.isCancelled else { return }
            isRetrying = false
            retryTask = nil
            start()
        }
    }

    private func resetRuntimeForRetry() async {
        fullscreenRequestGate.invalidate()
        invalidateSourceTransitions()
        startupTask?.cancel()
        startupTask = nil
        activationTask?.cancel()
        activationTask = nil
        isActivatingSharing = false
        sharingHasStarted = false
        signalingEventTask?.cancel()
        signalingEventTask = nil
        nativeRendezvousEventTask?.cancel()
        nativeRendezvousEventTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
        cursorTask?.cancel()
        cursorTask = nil
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        captureRestartTask?.cancel()
        captureRestartTask = nil
        captureRestartRequestID = nil
        codecChangeTask?.cancel()
        codecChangeTask = nil
        let systemAudioTask = cancelSystemAudioReconciliation()
        failureCleanupTask?.cancel()
        failureCleanupTask = nil
        cancelAuthoritativeControlReplay()
        focusedWindowMonitor.stop()
        await systemAudioTask?.value
        await capturePipeline?.stopAll()
        capturePipeline = nil
        peerHost?.close()
        peerHost = nil
        await nativeRendezvous.tearDown()
        await signaling.stop()
        state.disconnect()
        roomConfiguration = nil
        signalingIsAvailable = false
        cancelAdmissionTimeouts()
        pendingViewerRoutes.removeAll()
        viewerSessionIDs.removeAll()
        negotiationIDs.removeAll()
        establishedControlViewerIDs.removeAll()
        pendingSessionClosingViewerIDs.removeAll()
        clearNativeViewerState()
        slotAllocation.clear()
        captureDescriptors.removeAll()
        captureGenerations.removeAll()
        sourceStatuses.removeAll()
        sourceOperationIDs.removeAll()
        viewerConnectedAt.removeAll()
        peerNegotiation.removeAll()
        latestStatistics = .init()
        capturePressure.removeAll()
        startedAt = nil
        isEnding = false
        publish()
    }

    private func requestEndSession() {
        Task { @MainActor [weak self] in
            await self?.endSession(notifyApplication: true)
        }
    }

    private func endSession(notifyApplication: Bool) async {
        guard !isEnding else { return }
        isEnding = true
        fullscreenRequestGate.invalidate()
        invalidateSourceTransitions()
        startupTask?.cancel()
        startupTask = nil
        activationTask?.cancel()
        activationTask = nil
        isActivatingSharing = false
        publish()
        focusedWindowMonitor.stop()
        statisticsTask?.cancel()
        statisticsTask = nil
        cursorTask?.cancel()
        cursorTask = nil
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        captureRestartTask?.cancel()
        captureRestartTask = nil
        captureRestartRequestID = nil
        codecChangeTask?.cancel()
        codecChangeTask = nil
        let systemAudioTask = cancelSystemAudioReconciliation()
        retryTask?.cancel()
        retryTask = nil
        isRetrying = false
        signalingEventTask?.cancel()
        signalingEventTask = nil
        nativeRendezvousEventTask?.cancel()
        nativeRendezvousEventTask = nil
        let failureCleanup = failureCleanupTask
        failureCleanupTask = nil
        failureCleanup?.cancel()
        await failureCleanup?.value
        cancelAuthoritativeControlReplay()
        await systemAudioTask?.value

        await sendSessionClosing(reason: "host-ended-session")
        await nativeRendezvous.tearDown()
        captureGenerations.removeAll()
        await capturePipeline?.stopAll()
        capturePipeline = nil
        peerHost?.close()
        peerHost = nil
        await signaling.stop()
        focusedWindowOverlay.tearDown()
        statusHUD.tearDown()
        state.disconnect()
        slotAllocation.clear()
        captureDescriptors.removeAll()
        captureGenerations.removeAll()
        sourceStatuses.removeAll()
        sourceOperationIDs.removeAll()
        viewerConnectedAt.removeAll()
        peerNegotiation.removeAll()
        roomConfiguration = nil
        signalingIsAvailable = false
        cancelAdmissionTimeouts()
        pendingViewerRoutes.removeAll()
        viewerSessionIDs.removeAll()
        negotiationIDs.removeAll()
        establishedControlViewerIDs.removeAll()
        pendingSessionClosingViewerIDs.removeAll()
        clearNativeViewerState()
        startedAt = nil
        sharingHasStarted = false
        latestStatistics = .init()
        capturePressure.removeAll()
        isEnding = false
        publish()

        if notifyApplication, !didNotifyEnd {
            didNotifyEnd = true
            onSessionEnded()
        }
    }

    private func startStatisticsLoop() {
        statisticsTask?.cancel()
        statisticsTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await refreshStatistics()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func startSourceRefreshLoop() {
        sourceRefreshTask?.cancel()
        sourceRefreshTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await refreshActiveSources()
                do {
                    try await Task.sleep(for: .milliseconds(750))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshActiveSources() async {
        guard !isEnding else { return }
        let content: ShareableCaptureContent
        do {
            content = try await discovery.shareableContent(
                excludingBundleIdentifier: ApplicationDirectories.bundleIdentifier
            )
        } catch {
            Self.logger.debug(
                "Could not refresh active Live Share sources: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard !Task.isCancelled, !isEnding else { return }

        let refreshedWindows = content.windows.filter {
            ShareableApplicationWindowEligibility.isEligible(
                $0,
                minimumPointSize: CGSize(width: 100, height: 100)
            )
        }
        for window in refreshedWindows {
            let windowID = LiveShareWindowID(rawValue: window.id)
            windowsByID[windowID] = window
            applicationPathsByWindowID[windowID] = NSRunningApplication(
                processIdentifier: window.processID
            )?.bundleURL?.path
        }
        if availableWindows != refreshedWindows {
            availableWindows = refreshedWindows
            publish()
        }
        guard !slotAllocation.activeSlots.isEmpty else { return }

        for slot in slotAllocation.activeSlots {
            guard let source = slot.source,
                  slotAllocation.slot(for: source.id)?.index == slot.index,
                  !sourceOperationIDs.contains(source.id) else { continue }
            switch source {
            case let .window(windowSource):
                guard let window = content.windows.first(where: {
                    $0.id == windowSource.id.rawValue
                }) else {
                    await stopSource(source.id)
                    continue
                }
                windowsByID[windowSource.id] = window
                applicationPathsByWindowID[windowSource.id] = NSRunningApplication(
                    processIdentifier: window.processID
                )?.bundleURL?.path
                guard let descriptor = captureDescriptors[source.id],
                      descriptor.sourcePixelWidth != window.pixelWidth
                        || descriptor.sourcePixelHeight != window.pixelHeight else {
                    continue
                }
                await restartSourceForGeometryChange(
                    source,
                    slot: slot,
                    window: window,
                    display: nil
                )

            case let .fullscreen(displaySource):
                guard let display = content.displays.first(where: {
                    $0.id == displaySource.id.rawValue
                }) else {
                    await stopSource(source.id)
                    continue
                }
                displayFramesByID[displaySource.id] = screen(for: display.id)?.frame
                    ?? display.frame
                guard let descriptor = captureDescriptors[source.id],
                      descriptor.sourcePixelWidth != display.pixelWidth
                        || descriptor.sourcePixelHeight != display.pixelHeight else {
                    continue
                }
                await restartSourceForGeometryChange(
                    source,
                    slot: slot,
                    window: nil,
                    display: display
                )
            }
        }
    }

    private func restartSourceForGeometryChange(
        _ source: LiveShareSource,
        slot: LiveShareTrackSlot,
        window: ShareableCaptureWindow?,
        display: ShareableCaptureDisplay?
    ) async {
        guard !sourceOperationIDs.contains(source.id),
              let pipeline = capturePipeline,
              let generation = captureGenerations[source.id] else { return }
        sourceOperationIDs.insert(source.id)
        defer { sourceOperationIDs.remove(source.id) }

        do {
            let descriptor = try makeDescriptor(
                for: source,
                slot: slot,
                window: window,
                display: display
            )
            captureDescriptors[source.id] = descriptor
            sourceStatuses[source.id] = .starting
            publish()
            try await pipeline.update(
                descriptor,
                inSlot: slot.index,
                expectedGeneration: generation
            )
            guard captureGenerations[source.id] == generation,
                  slotAllocation.slot(for: source.id)?.index == slot.index,
                  state.snapshot.sources.contains(source.id),
                  !isEnding else { return }
            sourceStatuses[source.id] = .live
            broadcastAuthoritativeControlMutation()
            publish()
            if descriptor.video.framesPerSecond != settings.frameRate.rawValue {
                scheduleActiveCaptureRestart()
            }
        } catch {
            guard captureGenerations[source.id] == generation else { return }
            await handleUnexpectedSourceFailure(
                source,
                message: error.localizedDescription
            )
        }
    }

    private func refreshStatistics() async {
        await refreshCaptureDeliveryStatistics()
        guard let peerHost else {
            latestStatistics = .init()
            publish()
            return
        }
        do {
            let outbound = try await peerHost.outboundSenderStatisticsSnapshot()
            let streams = slotAllocation.activeSlots.compactMap { slot -> LiveShareStreamStatisticsViewSnapshot? in
                guard let source = slot.source,
                      let descriptor = captureDescriptors[source.id],
                      let outboundSlot = outbound.slots.first(where: { $0.slot == slot.index }) else {
                    return nil
                }
                let captureStatistics = capturePressure.statistics(
                    for: source.id,
                    generation: captureGenerations[source.id]
                )
                let senderPolicy = peerHost.senderPolicy(forSlot: slot.index)
                return LiveShareStreamStatisticsViewSnapshot(
                    id: slot.trackID,
                    name: descriptor.stream.appName,
                    width: descriptor.stream.width,
                    height: descriptor.stream.height,
                    deliveredFramesPerSecond: outboundSlot.deliveredFramesPerSecond ?? 0,
                    bitsPerSecond: max(
                        0,
                        Int((outboundSlot.aggregateBitrateBps ?? 0).rounded())
                    ),
                    targetBitsPerSecond: outboundSlot.aggregateTargetBitrateBps.map {
                        max(0, Int($0.rounded()))
                    },
                    configuredBitrateCeiling: LiveShareCoordinatorPolicy
                        .aggregateConfiguredBitrateCeiling(
                            perViewer: senderPolicy.maximumBitrateBps ?? 0,
                            viewerCount: outboundSlot.viewers.count
                        ),
                    bytesSent: Int64(clamping: outboundSlot.bytesSent),
                    captureDeliveredFrames: captureStatistics?.deliveredFrames ?? 0,
                    captureBackpressureDrops: capturePressure.latestBackpressureDrops(
                        for: source.id,
                        generation: captureGenerations[source.id]
                    ),
                    encoderDroppedFrames: outboundSlot.encoderDroppedFrames,
                    averageEncodeTimeMilliseconds: outboundSlot
                        .averageEncodeTimeMilliseconds,
                    averagePacketSendDelayMilliseconds: outboundSlot
                        .averagePacketSendDelayMilliseconds,
                    qualityLimitationReasons: outboundSlot.qualityLimitationReasons,
                    codec: outboundSlot.codecs.isEmpty
                        ? nil
                        : outboundSlot.codecs.sorted().joined(separator: " / "),
                    isFocused: slot.isFocused
                )
            }
            latestStatistics = LiveShareStatisticsViewSnapshot(
                uptime: startedAt.map { Date().timeIntervalSince($0) } ?? 0,
                streams: streams,
                h264SubmissionBackpressureDrops:
                    outbound.h264SubmissionBackpressureDrops
            )
        } catch {
            Self.logger.debug(
                "Could not read WebRTC statistics: \(error.localizedDescription, privacy: .public)"
            )
        }
        updateViewerCount()
        publish()
    }

    private func refreshCaptureDeliveryStatistics() async {
        guard let pipeline = capturePipeline else {
            capturePressure.removeAll()
            return
        }
        let snapshots = await pipeline.deliveryStatisticsSnapshots()
        guard !Task.isCancelled, !isEnding, capturePipeline === pipeline else { return }

        let activeGenerations: [LiveShareSourceID: UUID] = Dictionary(
            uniqueKeysWithValues: slotAllocation.activeSlots.compactMap { slot in
                guard let source = slot.source,
                      let generation = captureGenerations[source.id] else {
                    return nil
                }
                return (source.id, generation)
            }
        )
        let currentSnapshots = snapshots.filter { snapshot in
            guard activeGenerations[snapshot.source.id] == snapshot.generation,
                  let slot = slotAllocation.slot(for: snapshot.source.id) else {
                return false
            }
            return slot.index == snapshot.slot && slot.source == snapshot.source
        }
        capturePressure.update(
            currentSnapshots,
            activeGenerations: activeGenerations
        )
    }

    private func updateCursorLoop() {
        let shouldRun = !slotAllocation.activeSlots.isEmpty
        if !shouldRun {
            cursorTask?.cancel()
            cursorTask = nil
            return
        }
        guard cursorTask == nil else { return }
        cursorTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                broadcastCursorPosition()
                let updatesPerSecond = LiveShareCoordinatorPolicy.cursorUpdatesPerSecond(
                    for: settings
                )
                do {
                    try await Task.sleep(
                        for: .nanoseconds(1_000_000_000 / Int64(updatesPerSecond))
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func broadcastCursorPosition() {
        guard let focusedSlot = slotAllocation.activeSlots.first(where: { $0.isFocused }),
              let source = focusedSlot.source,
              let frame = appKitFrame(for: source.id) else { return }
        let position = LiveShareCursorNormalization.position(
            appKitCursor: NSEvent.mouseLocation,
            appKitWindowFrame: frame
        )
        guard let peerHost else { return }
        for viewerID in establishedControlViewerIDs {
            guard let sessionID = viewerSessionIDs[viewerID],
                  let message = try? ClipLiveShareInnerMessage.cursor(
                    ClipLiveShareCursor(
                        sessionID: sessionID,
                        streamID: focusedSlot.streamIdentity,
                        x: position.xPercent,
                        y: position.yPercent,
                        inView: position.isInView
                    )
                  ),
                  let data = try? ClipLiveShareMessageCodec.encodeInner(message)
            else { continue }
            _ = peerHost.sendEphemeralControl(data, to: viewerID)
        }
    }

    private func appKitFrame(for sourceID: LiveShareSourceID) -> CGRect? {
        switch sourceID {
        case let .window(windowID):
            if focusedWindow?.window.id == windowID.rawValue {
                return focusedWindow?.appKitFrame
            }
            return nil
        case let .fullscreen(displayID):
            return displayFramesByID[displayID]
        }
    }

    private func sendInitialControlState(to viewerID: String) {
        authoritativeControlDelivery.markDirty(viewerID)
        scheduleAuthoritativeControlReplay()
    }

    private func broadcastAuthoritativeControlMutation() {
        guard let peerHost else { return }
        authoritativeControlDelivery.markDirty(peerHost.viewerIDs)
        scheduleAuthoritativeControlReplay()
    }

    private func scheduleAuthoritativeControlReplay() {
        guard controlReplayTask == nil,
              !authoritativeControlDelivery.dirtyViewerIDs.isEmpty else { return }
        let taskID = UUID()
        controlReplayTaskID = taskID
        controlReplayTask = Task { @MainActor [weak self] in
            await self?.runAuthoritativeControlReplay(taskID: taskID)
        }
    }

    private func runAuthoritativeControlReplay(taskID: UUID) async {
        defer {
            if controlReplayTaskID == taskID {
                controlReplayTask = nil
                controlReplayTaskID = nil
            }
        }

        var isFirstAttempt = true
        while !Task.isCancelled,
              controlReplayTaskID == taskID,
              let peerHost {
            if !isFirstAttempt {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
            }
            isFirstAttempt = false

            let openViewerIDs = Set(peerHost.viewerSnapshots.compactMap { viewer in
                viewer.controlDataChannelState == .open ? viewer.viewerID : nil
            })
            let viewerIDs = authoritativeControlDelivery.dirtyViewerIDs.filter {
                openViewerIDs.contains($0)
                    && authoritativeControlDelivery.canReplay(to: $0)
            }
            guard !viewerIDs.isEmpty else { return }

            for viewerID in viewerIDs {
                guard !Task.isCancelled,
                      controlReplayTaskID == taskID,
                      authoritativeControlDelivery.beginReplay(for: viewerID) else {
                    continue
                }
                if sendAuthoritativeControlState(to: viewerID, using: peerHost) {
                    authoritativeControlDelivery.markReplayDelivered(to: viewerID)
                }
            }
        }
    }

    private func sendAuthoritativeControlState(
        to viewerID: String,
        using peerHost: WebRTCPeerHost
    ) -> Bool {
        guard let sessionID = viewerSessionIDs[viewerID] else { return false }
        let streams = slotAllocation.activeSlots.compactMap { streamDescriptor(for: $0) }
        let messages: [ClipLiveShareInnerMessage]
        do {
            messages = [
                .manifest(try ClipLiveShareStreamManifest(
                    sessionID: sessionID,
                    streams: streams,
                    maximumStreams: LiveShareTrackSlotAllocation.slotCount
                )),
                .sharingState(ClipLiveShareSharingState(
                    sessionID: sessionID,
                    sharing: !streams.isEmpty
                )),
                .systemAudioState(ClipLiveShareSystemAudioState(
                    sessionID: sessionID,
                    enabled: systemAudioIsActive
                )),
                .focus(ClipLiveShareFocus(
                    sessionID: sessionID,
                    streamID: slotAllocation.activeSlots
                        .first(where: { $0.isFocused })?.streamIdentity
                )),
            ]
        } catch {
            Self.logger.error(
                "Could not construct Live Share state: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        var delivered = true
        for message in messages {
            do {
                let data = try ClipLiveShareMessageCodec.encodeInner(message)
                let wasDelivered = peerHost.sendControl(data, to: viewerID)
                if !wasDelivered {
                    delivered = false
                }
            } catch {
                delivered = false
            }
        }
        if nativeControlViewerCapabilities[viewerID]?.contains(
            .streamLifecycle
        ) == true {
            do {
                for message in try makeNativeLifecycleMessages(
                    viewerID: viewerID,
                    sessionID: sessionID,
                    streams: streams
                ) {
                    let data = try ClipLiveShareNativeV2MessageCodec.encode(
                        message
                    )
                    if !peerHost.sendControl(data, to: viewerID) {
                        delivered = false
                    }
                }
            } catch {
                delivered = false
            }
        }
        return delivered
    }

    private func makeNativeLifecycleMessages(
        viewerID: String,
        sessionID: ClipLiveShareSessionID,
        streams: [ClipLiveShareStreamDescriptor]
    ) throws -> [ClipLiveShareNativeStreamLifecycleMessage] {
        let descriptors = slotAllocation.activeSlots.compactMap { slot
            -> ClipLiveShareNativeStreamDescriptor? in
            guard let source = slot.source,
                  let generation = captureGenerations[source.id],
                  let stream = streams.first(where: {
                      $0.id == slot.streamIdentity
                  }),
                  let sourceInstanceID = nativeSourceInstanceID(
                      for: generation
                  ) else { return nil }
            let mode: ClipLiveShareNativeSourcePresentationMode
            if case let .window(windowID) = source.id,
               settings.autoShareFocusedWindows,
               latestAutomaticWindowID == windowID {
                mode = .followsFocusedWindow
            } else {
                mode = .manual
            }
            return ClipLiveShareNativeStreamDescriptor(
                sourceInstanceID: sourceInstanceID,
                presentationMode: mode,
                stream: stream
            )
        }
        let events: [ClipLiveShareNativeStreamLifecycleEvent] = [
            .snapshot(descriptors),
            .sharing(!streams.isEmpty),
            .systemAudio(systemAudioIsActive),
        ]
        var revision = nativeControlStateRevisions[viewerID] ?? 0
        var messages: [ClipLiveShareNativeStreamLifecycleMessage] = []
        messages.reserveCapacity(events.count)
        for event in events {
            guard revision < UInt64.max else {
                throw LiveShareNativeRendezvousLifecycleError
                    .stateRevisionExhausted
            }
            revision += 1
            messages.append(try ClipLiveShareNativeStreamLifecycleMessage(
                sessionID: sessionID,
                stateRevision: ClipLiveShareStateRevision(
                    rawValue: revision
                ),
                event: event,
                maximumStreams: LiveShareTrackSlotAllocation.slotCount
            ))
        }
        nativeControlStateRevisions[viewerID] = revision
        return messages
    }

    private func nativeSourceInstanceID(
        for generation: UUID
    ) -> ClipLiveShareSourceInstanceID? {
        var bytes = generation.uuid
        return try? withUnsafeBytes(of: &bytes) { buffer in
            try ClipLiveShareSourceInstanceID(bytes: Data(buffer))
        }
    }

    private func cancelAuthoritativeControlReplay() {
        controlReplayTaskID = nil
        controlReplayTask?.cancel()
        controlReplayTask = nil
        authoritativeControlDelivery.removeAll()
    }

    private func broadcastFocusChange() {
        applyRuntimeSenderPolicies()
        broadcastAuthoritativeControlMutation()
        captureCursorFocusRevision &+= 1
        let revision = captureCursorFocusRevision
        enqueueSourceTransition { coordinator in
            await coordinator.reconcileCaptureCursorVisibility(
                expectedFocusRevision: revision
            )
        }
    }

    /// Applies focus-only ScreenCaptureKit updates without restarting a source
    /// or renegotiating its WebRTC track. The operation runs in the same serial
    /// transition chain as source additions, removals, and geometry changes.
    private func reconcileCaptureCursorVisibility(
        expectedFocusRevision: UInt64
    ) async {
        guard expectedFocusRevision == captureCursorFocusRevision,
              let pipeline = capturePipeline else { return }
        let mutations = LiveShareCaptureCursorPolicy.mutations(
            slots: slotAllocation,
            descriptors: captureDescriptors,
            generations: captureGenerations
        )
        for mutation in mutations {
            do {
                try await pipeline.update(
                    mutation.descriptor,
                    inSlot: mutation.slot,
                    expectedGeneration: mutation.generation
                )
                guard captureGenerations[mutation.sourceID] == mutation.generation,
                      slotAllocation.slot(for: mutation.sourceID)?.index == mutation.slot,
                      !isEnding else { return }
                captureDescriptors[mutation.sourceID] = mutation.descriptor
                guard expectedFocusRevision == captureCursorFocusRevision else {
                    return
                }
            } catch {
                if LiveShareCaptureGeometryFailurePolicy.requiresSessionFailure(
                    after: error
                ) {
                    fail(code: .captureFailed, error: error)
                } else {
                    Self.logger.error(
                        "Could not update Live Share cursor focus: \(error.localizedDescription, privacy: .public)"
                    )
                }
                return
            }
        }
    }

    private func streamDescriptor(
        for slot: LiveShareTrackSlot
    ) -> ClipLiveShareStreamDescriptor? {
        guard let source = slot.source,
              let descriptor = captureDescriptors[source.id] else { return nil }
        return try? ClipLiveShareStreamDescriptor(
            id: slot.streamIdentity,
            mediaTrackID: descriptor.stream.mediaTrackID,
            active: true,
            focused: slot.isFocused,
            appName: descriptor.stream.appName,
            windowName: descriptor.stream.windowName,
            width: descriptor.stream.width,
            height: descriptor.stream.height,
            order: slot.index,
            sourcePointWidth: descriptor.stream.sourcePointWidth,
            sourcePointHeight: descriptor.stream.sourcePointHeight
        )
    }

    private func sendSessionClosing(reason: String) async {
        guard let peerHost else { return }
        let openViewerIDs = Set(peerHost.viewerSnapshots.compactMap { viewer in
            viewer.controlDataChannelState == .open ? viewer.viewerID : nil
        })
        pendingSessionClosingViewerIDs = establishedControlViewerIDs
            .intersection(openViewerIDs)
        for viewerID in Array(pendingSessionClosingViewerIDs) {
            guard let sessionID = viewerSessionIDs[viewerID],
                  let closing = try? ClipLiveShareSessionClosing(
                    sessionID: sessionID,
                    reason: reason
                  ),
                  let data = try? ClipLiveShareMessageCodec.encodeInner(
                    .sessionClosing(closing)
                  ) else { continue }
            if !peerHost.sendControl(data, to: viewerID) {
                pendingSessionClosingViewerIDs.remove(viewerID)
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while !pendingSessionClosingViewerIDs.isEmpty, clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                break
            }
        }
        pendingSessionClosingViewerIDs.removeAll()
    }

    private func updateViewerCount() {
        try? state.updateViewerCount(peerHost?.connectedViewerCount ?? 0)
    }

    private func fail(code: LiveShareFailureCode, error: any Error) {
        let technicalDescription =
            (error as? any TechnicalErrorDescriptionProviding)?
                .technicalDescriptionForLogging
            ?? error.localizedDescription
        fail(code: code, technicalDescription: technicalDescription)
    }

    private func fail(code: LiveShareFailureCode, technicalDescription: String) {
        Self.logger.error("Live Share failed: \(technicalDescription, privacy: .public)")
        invalidateSourceTransitions()
        state.fail(LiveShareFailure(
            code: code,
            technicalDescription: technicalDescription
        ))
        publish()
        guard failureCleanupTask == nil else { return }
        failureCleanupTask = Task { @MainActor [weak self] in
            await self?.quiesceFailedRuntime()
            self?.failureCleanupTask = nil
        }
    }

    private func quiesceFailedRuntime() async {
        fullscreenRequestGate.invalidate()
        invalidateSourceTransitions()
        focusedWindowMonitor.stop()
        activationTask?.cancel()
        activationTask = nil
        isActivatingSharing = false
        sharingHasStarted = false
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        captureRestartTask?.cancel()
        captureRestartTask = nil
        captureRestartRequestID = nil
        codecChangeTask?.cancel()
        codecChangeTask = nil
        let systemAudioTask = cancelSystemAudioReconciliation()
        statisticsTask?.cancel()
        statisticsTask = nil
        cursorTask?.cancel()
        cursorTask = nil
        signalingEventTask?.cancel()
        signalingEventTask = nil
        nativeRendezvousEventTask?.cancel()
        nativeRendezvousEventTask = nil
        cancelAuthoritativeControlReplay()
        await systemAudioTask?.value
        await sendSessionClosing(reason: "host-failed")
        await nativeRendezvous.tearDown()
        captureGenerations.removeAll()
        await capturePipeline?.stopAll()
        capturePipeline = nil
        peerHost?.close()
        peerHost = nil
        await signaling.stop()
        focusedWindowOverlay.tearDown()
        statusHUD.tearDown()
        _ = state.clearSources()
        slotAllocation.clear()
        captureDescriptors.removeAll()
        sourceStatuses.removeAll()
        sourceOperationIDs.removeAll()
        viewerConnectedAt.removeAll()
        peerNegotiation.removeAll()
        roomConfiguration = nil
        signalingIsAvailable = false
        cancelAdmissionTimeouts()
        pendingViewerRoutes.removeAll()
        viewerSessionIDs.removeAll()
        negotiationIDs.removeAll()
        establishedControlViewerIDs.removeAll()
        pendingSessionClosingViewerIDs.removeAll()
        clearNativeViewerState()
        latestStatistics = .init()
        capturePressure.removeAll()
        startedAt = nil
        publish()
    }

    private func logPeerFailure(_ error: any Error, viewerID: String?) {
        if let viewerID {
            Self.logger.error(
                "Viewer \(viewerID, privacy: .private(mask: .hash)) failed: \(error.localizedDescription, privacy: .public)"
            )
        } else {
            Self.logger.error(
                "A WebRTC peer failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        publish()
    }

    private func publish() {
        scheduleSystemAudioReconciliation()
        let snapshot = makeViewSnapshot()
        presentationModel.update(snapshot)
        renderOverlays(snapshot)
        let menuBarStatus = LiveShareCoordinatorPolicy.menuBarStatus(for: snapshot.phase)
        if publishedMenuBarStatus != menuBarStatus {
            publishedMenuBarStatus = menuBarStatus
            onMenuBarStatusChanged(menuBarStatus)
        }
    }

    private func makeViewSnapshot() -> LiveShareViewSnapshot {
        let domain = state.snapshot
        let now = Date()
        let phase: LiveShareViewPhase
        if isEnding {
            phase = .stopping
        } else if isActivatingSharing {
            phase = .starting
        } else if isRetrying {
            phase = .connecting
        } else {
            switch domain.phase {
            case .idle:
                phase = .inactive
            case .reservingRoom:
                phase = .reservingRoom
            case .connecting:
                phase = .connecting
            case .ready:
                phase = .ready
            case .starting:
                phase = .starting
            case .sharing:
                phase = .live(elapsedSeconds: startedAt.map { now.timeIntervalSince($0) } ?? 0)
            case .reconnecting:
                phase = .reconnecting(
                    attempt: min(
                        domain.reconnectAttempt,
                        LiveShareCoordinatorPolicy.maximumReconnectAttempts
                    ),
                    maximumAttempts: LiveShareCoordinatorPolicy.maximumReconnectAttempts
                )
            case .stopping:
                phase = .stopping
            case .failed:
                phase = .failed(message: LiveShareCoordinatorPolicy.userFacingFailure(domain.failure))
            }
        }

        let roomIsClaimed = [.ready, .starting, .sharing, .reconnecting, .stopping]
            .contains(domain.phase)
        let room = roomIsClaimed ? domain.room.map {
            LiveShareRoomViewSnapshot(
                viewerURL: $0.viewerURL,
                roomCode: $0.name.rawValue,
                isAvailable: signalingIsAvailable
            )
        } : nil
        let sources = slotAllocation.activeSlots.compactMap { slot -> LiveShareSourceViewSnapshot? in
            guard case let .window(windowSource)? = slot.source else { return nil }
            return LiveShareSourceViewSnapshot(
                id: LiveShareCoordinatorPolicy.sourceIdentifier(.window(windowSource.id)),
                slotIndex: slot.index,
                applicationName: windowSource.appName,
                windowTitle: windowSource.windowName,
                applicationPath: applicationPathsByWindowID[windowSource.id],
                status: sourceStatuses[.window(windowSource.id)] ?? .live,
                isFocused: slot.isFocused,
                canStop: sourceStatuses[.window(windowSource.id)] != .stopping
            )
        }
        let slots = slotAllocation.slots.map { slot in
            LiveShareSourceSlotViewSnapshot(
                index: slot.index,
                state: slot.source.map {
                    sourceStatuses[$0.id] == .starting ? .starting : .live
                } ?? .empty
            )
        }
        let fullscreenSource = domain.sources.fullscreen
        let fullscreen = LiveShareFullscreenViewSnapshot(
            isOn: fullscreenSource != nil,
            displayName: fullscreenSource?.displayName
                ?? preferredOverlayScreen()?.localizedName
                ?? String(localized: "Main Display"),
            isEnabled: sharingHasStarted && domain.phase == .sharing && !isEnding,
            detail: !domain.sources.windows.isEmpty
                ? String(localized: "Starting fullscreen stops the current window shares.")
                : nil
        )
        let focusedDescription = focusedWindow.map {
            [$0.window.applicationName, $0.window.title]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        let viewerSnapshots = peerHost?.viewerSnapshots ?? []
        let viewers = viewerSnapshots.map { viewer in
            LiveShareViewerViewSnapshot(
                id: viewer.viewerID,
                connection: LiveShareCoordinatorPolicy.viewerConnection(
                    from: viewer.connectionState,
                    route: viewer.route
                ),
                connectedDuration: viewerConnectedAt[viewer.viewerID].map {
                    now.timeIntervalSince($0)
                }
            )
        }
        let canOperateSources = !isEnding && sharingHasStarted && domain.phase == .sharing
        let canChangeSettings = !isEnding
            && [.ready, .starting, .sharing].contains(domain.phase)
        let activeWindowIDs = Set(domain.sources.windows.map(\.id))
        let focusedSourceID = focusedWindow.map {
            LiveShareSourceID.window(LiveShareWindowID(rawValue: $0.window.id))
        }
        let availableWindowSnapshots = availableWindows
            .filter { !activeWindowIDs.contains(LiveShareWindowID(rawValue: $0.id)) }
            .map { window in
                LiveShareAvailableWindowViewSnapshot(
                    id: LiveShareCoordinatorPolicy.sourceIdentifier(
                        .window(LiveShareWindowID(rawValue: window.id))
                    ),
                    applicationName: window.applicationName,
                    windowTitle: window.title.isEmpty
                        ? String(localized: "Untitled Window")
                        : window.title,
                    applicationPath: NSRunningApplication(
                        processIdentifier: window.processID
                    )?.bundleURL?.path
                )
            }
        let overloadedSourceNames = slotAllocation.activeSlots.compactMap { slot -> String? in
            guard let source = slot.source,
                  capturePressure.isOverloaded(
                    source.id,
                    generation: captureGenerations[source.id]
                  ) else {
                return nil
            }
            switch source {
            case let .window(window):
                return window.appName
            case let .fullscreen(display):
                return display.displayName
            }
        }
        let capturePressureWarning = overloadedSourceNames.isEmpty
            ? nil
            : LiveShareCapturePressureWarningSnapshot(sourceNames: overloadedSourceNames)
        return LiveShareViewSnapshot(
            phase: phase,
            sessionStage: sharingHasStarted ? .active : .preparing,
            canStartSharing: !isEnding
                && !isActivatingSharing
                && signalingIsAvailable
                && domain.phase == .ready
                && room != nil,
            canReplaceRoom: !isEnding
                && !isActivatingSharing
                && !sharingHasStarted
                && [.ready, .connecting].contains(domain.phase),
            friends: nativeFriends.presentationSnapshots,
            room: room,
            accessCodeEnabled: settings.accessCodeEnabled,
            accessCode: accessCode,
            canChangeAccessCode: [.ready, .starting, .sharing].contains(domain.phase)
                && !isEnding
                && !accessCodeIsUpdating
                && room != nil,
            accessCodeError: accessCodeError,
            sources: sources,
            slots: slots,
            fullscreen: fullscreen,
            canShareFocusedWindow: canOperateSources
                && focusedSourceID.map(permitsWindowShare) == true,
            focusedWindowDescription: focusedDescription,
            availableWindows: availableWindowSnapshots,
            canAddWindow: canOperateSources
                && !settings.autoShareFocusedWindows
                && !availableWindowSnapshots.isEmpty
                && (fullscreenSource != nil
                    || domain.sources.windows.count < LiveShareSourceSelection.maximumWindowCount),
            settings: LiveShareSettingsViewSnapshot(
                quality: settings.quality,
                frameRate: settings.frameRate,
                codec: .init(
                    codec: settings.videoCodec,
                    acceleration: settings.videoCodec == .h264 ? .hardware : .software
                ),
                colorMode: settings.colorMode,
                systemAudioEnabled: settings.systemAudioEnabled,
                cursorUpdatesMatchFrameRate: settings.cursorUpdatesMatchFrameRate,
                prioritizeFocusedWindow: settings.prioritizeFocusedWindow,
                mode: settings.encodingMode,
                advancedVideoSettings: settings.advancedVideoSettings,
                autoShareFocusedWindows: settings.autoShareFocusedWindows,
                canChangeQuality: canChangeSettings,
                canChangeFrameRate: canChangeSettings && codecChangeTask == nil,
                availableFrameRates: availableFrameRates,
                canChangeCodec: canChangeSettings && codecChangeTask == nil,
                canChangeColorMode: canChangeSettings && codecChangeTask == nil,
                canChangeSystemAudio: canChangeSettings,
                canChangeCursorUpdateRate: canChangeSettings,
                canChangePrioritizeFocusedWindow: canChangeSettings,
                canChangeMode: canChangeSettings && codecChangeTask == nil,
                canChangeAutoShare: canOperateSources && fullscreenSource == nil
            ),
            viewers: viewers,
            connectedViewerCount: peerHost?.connectedViewerCount ?? 0,
            statistics: latestStatistics,
            capturePressureWarning: capturePressureWarning
        )
    }

    private var availableFrameRates: Set<LiveShareFrameRate> {
        var result: Set<LiveShareFrameRate> = [.fifteen, .thirty]
        if NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 30 >= 60 {
            result.insert(.sixty)
        }
        return result
    }

    private func renderOverlays(_ snapshot: LiveShareViewSnapshot) {
        guard snapshot.sessionStage == .active else {
            focusedWindowOverlay.hide()
            statusHUD.hide()
            return
        }
        let showsSessionOverlays: Bool
        switch snapshot.phase {
        case .ready, .starting, .live, .reconnecting:
            showsSessionOverlays = true
        default:
            showsSessionOverlays = false
        }
        guard showsSessionOverlays,
              let visibleFrame = preferredOverlayScreen()?.visibleFrame else {
            focusedWindowOverlay.hide()
            statusHUD.hide()
            return
        }
        statusHUD.show(
            snapshot: LiveShareStatusHUDSnapshot(viewSnapshot: snapshot),
            visibleScreenFrame: visibleFrame
        )

        let showsFocusedWindowControl: Bool
        switch snapshot.phase {
        case .ready, .starting, .live:
            showsFocusedWindowControl = true
        default:
            showsFocusedWindowControl = false
        }
        guard showsFocusedWindowControl,
              !snapshot.fullscreen.isOn,
              let focusedWindow else {
            focusedWindowOverlay.hide()
            return
        }
        let sourceID = LiveShareSourceID.window(
            LiveShareWindowID(rawValue: focusedWindow.window.id)
        )
        guard permitsWindowShare(sourceID) else {
            focusedWindowOverlay.hide()
            return
        }
        let overlayState: FocusedWindowShareOverlayState
        switch sourceStatuses[sourceID] {
        case .starting:
            overlayState = .starting
        case .stopping:
            overlayState = .stopping
        case .live, .failed:
            overlayState = .live
        case nil:
            overlayState = state.snapshot.sources.contains(sourceID) ? .live : .shareable
        }
        let targetScreen = screen(containing: focusedWindow.appKitFrame)
        focusedWindowOverlay.show(
            snapshot: FocusedWindowShareOverlaySnapshot(
                sourceID: LiveShareCoordinatorPolicy.sourceIdentifier(sourceID),
                applicationName: focusedWindow.window.applicationName,
                windowTitle: focusedWindow.window.title,
                state: overlayState
            ),
            targetWindowFrame: focusedWindow.appKitFrame,
            visibleScreenFrame: targetScreen?.visibleFrame ?? visibleFrame
        )
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
    }

    private func preferredOverlayScreen() -> NSScreen? {
        if let fullscreen = state.snapshot.sources.fullscreen,
           let sharedScreen = screen(for: fullscreen.id.rawValue) {
            return sharedScreen
        }
        if let focusedWindow,
           let focusedScreen = screen(containing: focusedWindow.appKitFrame) {
            return focusedScreen
        }
        return screen(for: CGMainDisplayID()) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func screen(containing frame: CGRect) -> NSScreen? {
        let candidate = NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.frame, frame) < intersectionArea(rhs.frame, frame)
        }
        guard let candidate, intersectionArea(candidate.frame, frame) > 0 else { return nil }
        return candidate
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.standardized.intersection(rhs.standardized)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
