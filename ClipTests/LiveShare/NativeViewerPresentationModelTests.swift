import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import Testing
@testable import Clip

@MainActor
struct NativeViewerPresentationModelTests {
    @Test
    func actionsAreGatedByAuthoritativeSnapshot() {
        var submittedCodes: [String] = []
        var friendships = 0
        let model = NativeViewerPresentationModel(
            snapshot: .init(phase: .connecting, friendship: .unavailable),
            actions: .init(
                submitAccessCode: { submittedCodes.append($0) },
                requestFriendship: { friendships += 1 }
            )
        )

        model.submitAccessCode("  TEST  ")
        model.requestFriendship()
        #expect(submittedCodes.isEmpty)
        #expect(friendships == 0)

        model.update(.init(
            phase: .waitingForAccessCode,
            friendship: .available
        ))
        model.submitAccessCode("  TEST  ")
        model.requestFriendship()
        #expect(submittedCodes == ["TEST"])
        #expect(friendships == 1)
    }

    @Test
    func sourceVisibilityAndVolumeAreNormalized() {
        var visibility: [(String, Bool)] = []
        var volumes: [Double] = []
        let source = NativeViewerSourceViewSnapshot(
            id: "source-1",
            applicationName: "Keynote",
            windowName: "Deck",
            pixelWidth: 1920,
            pixelHeight: 1080,
            isVisible: true,
            isFocused: true,
            isConnected: true
        )
        let model = NativeViewerPresentationModel(
            snapshot: .init(
                phase: .live,
                sources: [source],
                systemAudioAvailable: true
            ),
            actions: .init(
                setVolume: { volumes.append($0) },
                setSourceVisible: { visibility.append(($0, $1)) }
            )
        )

        model.setSourceVisible("unknown", false)
        model.setSourceVisible("source-1", false)
        model.setVolume(2)
        #expect(visibility.count == 1)
        #expect(visibility.first?.0 == "source-1")
        #expect(visibility.first?.1 == false)
        #expect(volumes == [1])
    }

    @Test
    func deterministicViewerScenariosCoverApprovalAndMultiWindowLiveState() {
        let waiting = DeterministicNativeViewerDemo.snapshot(
            for: .nativeViewerWaiting
        )
        #expect(waiting.phase == .waitingForHostApproval)
        #expect(waiting.friendship == .friends)
        #expect(waiting.sources.isEmpty)

        let live = DeterministicNativeViewerDemo.snapshot(for: .nativeViewerLive)
        #expect(live.phase == .live)
        #expect(live.route == .peerToPeer)
        #expect(live.sources.count == 3)
        #expect(live.visibleSourceCount == 2)
        #expect(live.systemAudioAvailable)
        #expect(live.statistics.codec == "AV1")
    }

    @Test
    func liveViewerWithoutSourcesExplainsWhatItIsWaitingFor() {
        let waiting = NativeViewerViewSnapshot(
            phase: .live,
            ownerName: "Alex",
            sources: []
        )
        #expect(waiting.waitingForSourceMessage
            == "Waiting for Alex to share a window…")

        let notLive = NativeViewerViewSnapshot(
            phase: .connecting,
            ownerName: "Alex",
            sources: []
        )
        #expect(notLive.waitingForSourceMessage == nil)
    }

    @Test
    func savedFriendModeSkipsInviteOnlyAuthenticationAndFriendship() throws {
        let fixture = try NativeViewerFriendSecurityFixture()
        let friend = NativeFriendRecord(
            identity: fixture.hostSigner.publicKey,
            displayName: "Alex",
            deviceName: "Studio Mac",
            endpoint: fixture.endpoint,
            rendezvousID: fixture.rendezvousID
        )
        let mode = NativeLiveShareViewerJoinMode.friend(friend)

        #expect(mode.ownerName == "Alex")
        #expect(mode.ownerDeviceName == "Studio Mac")
        #expect(mode.initialFriendship == .friends)
        #expect(!mode.acceptsAccessCode)
        #expect(!mode.sendsNativeControlHello)

        let invite = NativeLiveShareViewerJoinMode.invite("https://example.test/invite")
        #expect(invite.acceptsAccessCode)
        #expect(invite.sendsNativeControlHello)
        #expect(invite.initialFriendship == .unavailable)
    }

    @Test
    func v1SourcesRemainAuthoritativeUntilFirstNativeLifecycleRevision() throws {
        let sessionID = try ClipLiveShareSessionID(
            rawValue: "viewer-source-authority"
        )
        var nativeState = ClipLiveShareNativeStreamLifecycleState(
            sessionID: sessionID
        )
        #expect(!NativeViewerSourceAuthorityPolicy.usesNativeLifecycle(
            nativeState
        ))

        try nativeState.apply(ClipLiveShareNativeStreamLifecycleMessage(
            sessionID: sessionID,
            stateRevision: ClipLiveShareStateRevision(rawValue: 1),
            event: .snapshot([])
        ))
        // An explicit empty native snapshot must remain authoritative; falling
        // back now would resurrect stale browser-v1 sources.
        #expect(NativeViewerSourceAuthorityPolicy.usesNativeLifecycle(
            nativeState
        ))
    }

    @Test
    func friendTransportEventsMapToDeterministicViewerPhases() {
        var phase = NativeViewerSessionPhase.connecting
        phase = NativeViewerTransportPhasePolicy.phase(
            after: .awaitingHostApproval,
            current: phase
        )
        #expect(phase == .waitingForHostApproval)

        phase = NativeViewerTransportPhasePolicy.phase(
            after: .controlOpened,
            current: phase
        )
        #expect(phase == .live)

        phase = NativeViewerTransportPhasePolicy.phase(
            after: .disconnected,
            current: phase
        )
        #expect(phase == .reconnecting)

        // ICE can recover while the already-open DataChannel remains open, so
        // `.connected` must restore live without waiting for another `.open`.
        phase = NativeViewerTransportPhasePolicy.phase(
            after: .connected,
            current: phase
        )
        #expect(phase == .live)

        phase = NativeViewerTransportPhasePolicy.phase(
            after: .closed,
            current: phase
        )
        #expect(phase == .ended(message: nil))
    }

    @Test
    func savedFriendLoadsDeploymentICEServersIncludingTURN() async throws {
        let endpoint = ClipLiveShareServerEndpoint.localDevelopment
        let capabilities = try ClipLiveShareCapabilities(
            protocolIdentifier: ClipLiveShareV1.protocolIdentifier,
            versions: [ClipLiveShareV1.version],
            serverVersion: "viewer-test",
            viewerPathTemplate: "/{room}",
            hostWebSocketPathTemplate: "/api/v1/rooms/{room}/host",
            viewerWebSocketPathTemplate: "/api/v1/rooms/{room}/viewer",
            iceServers: [
                try ClipLiveShareICEServer(
                    urls: ["stun:stun.example.test:3478"]
                ),
                try ClipLiveShareICEServer(
                    urls: ["turns:turn.example.test:5349"],
                    username: "viewer",
                    credential: "temporary-secret"
                )
            ],
            limits: try ClipLiveShareCapabilities.Limits(
                maximumMessageBytes: ClipLiveShareV1.maximumWebSocketMessageBytes,
                maximumPendingViewersPerRoom: 8
            )
        )
        let transport = NativeViewerHTTPTransportStub(result: .init(
            statusCode: 200,
            data: try JSONEncoder().encode(capabilities)
        ))

        let configuration = try await
            NativeViewerDeploymentConfigurationResolver.load(
                endpoint: endpoint,
                transport: transport
            )

        #expect(await transport.lastRequestURL == endpoint.capabilitiesURL)
        #expect(configuration.iceServers == [
            WebRTCICEServerConfiguration(
                urlStrings: ["stun:stun.example.test:3478"]
            ),
            WebRTCICEServerConfiguration(
                urlStrings: ["turns:turn.example.test:5349"],
                username: "viewer",
                credential: "temporary-secret"
            )
        ])
    }

    @Test
    func fastFriendResponsePreventsLateSendRollback() throws {
        let fixture = try NativeViewerFriendSecurityFixture()
        let request = fixture.request

        #expect(NativeViewerFriendRequestSendPolicy.shouldRollback(
            sentRequest: request,
            pendingRequest: request
        ))
        // A fast response clears the request while sendNativeControl is still
        // suspended, so the later send result must preserve that response.
        #expect(!NativeViewerFriendRequestSendPolicy.shouldRollback(
            sentRequest: request,
            pendingRequest: nil
        ))
        // Even if the ACK send is still retrying and therefore keeps the
        // request pending, a durably accepted host response owns the state.
        #expect(!NativeViewerFriendRequestSendPolicy.shouldRollback(
            sentRequest: request,
            pendingRequest: request,
            committedRequest: request
        ))
    }

    @Test
    func friendAcceptanceIsPersistedBeforeCommitAcknowledgement() async throws {
        let fixture = try NativeViewerFriendSecurityFixture()
        let acceptance = fixture.acceptance(for: fixture.request)
        var events: [String] = []

        let signed = try await
            NativeViewerFriendAcceptanceCommitBuilder.signedAcknowledgement(
                acceptance: acceptance,
                request: fixture.request,
                signer: fixture.viewerSigner,
                acknowledgedAt: fixture.now,
                persist: { _ in
                    events.append("persisted")
                }
            )
        events.append("acknowledgement-ready")

        #expect(events == ["persisted", "acknowledgement-ready"])
        guard case let .acceptanceAcknowledged(acknowledgement) = signed.message else {
            Issue.record("Expected an acceptance acknowledgement")
            return
        }
        #expect(acknowledgement.requestID == fixture.request.requestID)
        #expect(acknowledgement.acceptanceDigest == acceptance.digest)
    }

    @Test
    func friendRequestRemainsPendingUntilCommitReceipt() throws {
        let fixture = try NativeViewerFriendSecurityFixture()
        let acceptance = fixture.acceptance(for: fixture.request)
        let signed = try ClipLiveShareSignedNativeFriendMessage(
            signing: .accepted(acceptance),
            with: fixture.hostSigner
        )
        var pendingRequest: ClipLiveShareNativeFriendRequest? = fixture.request

        if NativeViewerFriendAcceptanceSendPolicy.shouldClearPendingRequest(
            commitReceiptAccepted: false
        ) {
            pendingRequest = nil
        }
        #expect(pendingRequest == fixture.request)
        #expect(NativeViewerFriendAcceptanceSendPolicy.isRetransmission(
            receivedDigest: signed.digest,
            committedDigest: signed.digest
        ))

        if NativeViewerFriendAcceptanceSendPolicy.shouldClearPendingRequest(
            commitReceiptAccepted: true
        ) {
            pendingRequest = nil
        }
        #expect(pendingRequest == nil)
    }

    @Test
    func invalidFriendResponseContextDoesNotConsumeReplayRecord() throws {
        let fixture = try NativeViewerFriendSecurityFixture()
        let acceptance = fixture.acceptance(for: fixture.request)
        let signed = try ClipLiveShareSignedNativeFriendMessage(
            signing: .accepted(acceptance),
            with: fixture.hostSigner
        )
        let unrelatedRequest = try fixture.makeRequest(requestIDByte: 0x71)
        var replayGuard = try ClipLiveShareNativeFriendReplayGuard()

        #expect(throws: ClipLiveShareNativeV2Error.self) {
            try NativeViewerFriendResponseVerifier.validateAcceptance(
                signed,
                acceptance: acceptance,
                request: unrelatedRequest,
                host: fixture.descriptor,
                at: fixture.now,
                replayGuard: &replayGuard
            )
        }

        try NativeViewerFriendResponseVerifier.validateAcceptance(
            signed,
            acceptance: acceptance,
            request: fixture.request,
            host: fixture.descriptor,
            at: fixture.now,
            replayGuard: &replayGuard
        )
        #expect(throws: ClipLiveShareNativeV2Error.replayed) {
            try NativeViewerFriendResponseVerifier.validateAcceptance(
                signed,
                acceptance: acceptance,
                request: fixture.request,
                host: fixture.descriptor,
                at: fixture.now,
                replayGuard: &replayGuard
            )
        }
    }

    @Test
    func hostCommitReceiptIsValidatedAndExactRetransmissionConverges() throws {
        let fixture = try NativeViewerFriendSecurityFixture()
        let exchange = try fixture.commitReceiptExchange()
        var replayGuard = try ClipLiveShareNativeFriendReplayGuard()

        try NativeViewerFriendCommitReceiptVerifier.validate(
            exchange.signedReceipt,
            receipt: exchange.receipt,
            acknowledgement: exchange.acknowledgement,
            signedAcknowledgementDigest: exchange.signedAcknowledgement.digest,
            acceptance: exchange.acceptance,
            request: fixture.request,
            host: fixture.descriptor,
            at: fixture.now
        )
        #expect(try replayGuard.acceptCommitReceiptIdempotently(
            exchange.signedReceipt,
            expectedIdentity: fixture.hostSigner.publicKey
        ) == .firstSeen)
        #expect(try replayGuard.acceptCommitReceiptIdempotently(
            exchange.signedReceipt,
            expectedIdentity: fixture.hostSigner.publicKey
        ) == .duplicate)
    }

    @Test
    func recoveredCommitReceiptUsesItsSignedCommitTime() throws {
        let fixture = try NativeViewerFriendSecurityFixture()
        let exchange = try fixture.commitReceiptExchange()
        let afterNetworkExpiry = try exchange.receipt.expiresAt.adding(
            milliseconds: 1
        )

        let recoveryTime =
            NativeViewerFriendCommitReceiptValidationPolicy.validationTime(
                for: exchange.receipt,
                isRecovery: true,
                wallClock: afterNetworkExpiry
            )
        let liveTime =
            NativeViewerFriendCommitReceiptValidationPolicy.validationTime(
                for: exchange.receipt,
                isRecovery: false,
                wallClock: afterNetworkExpiry
            )

        #expect(recoveryTime == exchange.receipt.committedAt)
        #expect(liveTime == afterNetworkExpiry)
        try NativeViewerFriendCommitReceiptVerifier.validate(
            exchange.signedReceipt,
            receipt: exchange.receipt,
            acknowledgement: exchange.acknowledgement,
            signedAcknowledgementDigest: exchange.signedAcknowledgement.digest,
            acceptance: exchange.acceptance,
            request: fixture.request,
            host: fixture.descriptor,
            at: recoveryTime
        )
        #expect(throws: ClipLiveShareNativeV2Error.expired) {
            try NativeViewerFriendCommitReceiptVerifier.validate(
                exchange.signedReceipt,
                receipt: exchange.receipt,
                acknowledgement: exchange.acknowledgement,
                signedAcknowledgementDigest: exchange.signedAcknowledgement.digest,
                acceptance: exchange.acceptance,
                request: fixture.request,
                host: fixture.descriptor,
                at: liveTime
            )
        }
    }

    @Test
    func pendingRecordUsesRecoveryJoinPolicyWithoutBecomingFriend() throws {
        let fixture = try NativeViewerFriendSecurityFixture()
        let pending = NativeFriendRecord(
            identity: fixture.hostSigner.publicKey,
            displayName: "Alex",
            deviceName: "Mac",
            endpoint: fixture.endpoint,
            rendezvousID: fixture.rendezvousID,
            trustState: .pendingCommit
        )
        let trusted = NativeFriendRecord(
            identity: pending.identity,
            displayName: pending.displayName,
            deviceName: pending.deviceName,
            endpoint: pending.endpoint,
            rendezvousID: pending.rendezvousID
        )

        let recovery = NativeLiveShareViewerJoinMode.recovery(pending)
        let friend = NativeLiveShareViewerJoinMode.friend(trusted)

        #expect(recovery.initialFriendship == .pending)
        #expect(recovery.permitsRequesterHandshakeRecovery)
        #expect(friend.initialFriendship == .friends)
        #expect(!friend.permitsRequesterHandshakeRecovery)
    }

    @Test
    func invalidCommitReceiptContextDoesNotConsumeReplayRecord() throws {
        let fixture = try NativeViewerFriendSecurityFixture()
        let exchange = try fixture.commitReceiptExchange()
        let unrelatedDigest = try ClipLiveShareNativeDigest(
            bytes: Data(repeating: 0xA5, count: ClipLiveShareNativeV2.digestByteCount)
        )
        var replayGuard = try ClipLiveShareNativeFriendReplayGuard()

        #expect(throws: ClipLiveShareNativeV2Error.contextMismatch) {
            try NativeViewerFriendCommitReceiptVerifier.validate(
                exchange.signedReceipt,
                receipt: exchange.receipt,
                acknowledgement: exchange.acknowledgement,
                signedAcknowledgementDigest: unrelatedDigest,
                acceptance: exchange.acceptance,
                request: fixture.request,
                host: fixture.descriptor,
                at: fixture.now
            )
        }

        try NativeViewerFriendCommitReceiptVerifier.validate(
            exchange.signedReceipt,
            receipt: exchange.receipt,
            acknowledgement: exchange.acknowledgement,
            signedAcknowledgementDigest: exchange.signedAcknowledgement.digest,
            acceptance: exchange.acceptance,
            request: fixture.request,
            host: fixture.descriptor,
            at: fixture.now
        )
        #expect(try replayGuard.acceptCommitReceiptIdempotently(
            exchange.signedReceipt,
            expectedIdentity: fixture.hostSigner.publicKey
        ) == .firstSeen)
    }

    @Test
    func descriptorRevisionRefreshPreservesNativeWindows() throws {
        let fixture = try NativeViewerFriendSecurityFixture()
        let refreshed = try fixture.descriptor(
            stateRevision: ClipLiveShareStateRevision(rawValue: 8)
        )

        #expect(NativeViewerDescriptorPresentationPolicy
            .requiresWindowReinstallation(
                previous: nil,
                incoming: fixture.descriptor
            ))
        #expect(!NativeViewerDescriptorPresentationPolicy
            .requiresWindowReinstallation(
                previous: fixture.descriptor,
                incoming: refreshed
            ))

        let replacementSession = try fixture.descriptor(
            sessionID: ClipLiveShareSessionID(
                rawValue: "viewer-security-session-replacement"
            ),
            stateRevision: ClipLiveShareStateRevision(rawValue: 1)
        )
        #expect(NativeViewerDescriptorPresentationPolicy
            .requiresWindowReinstallation(
                previous: fixture.descriptor,
                incoming: replacementSession
            ))
    }
}

private actor NativeViewerHTTPTransportStub: ClipLiveShareHTTPTransport {
    let result: ClipLiveShareHTTPResult
    private(set) var lastRequestURL: URL?

    init(result: ClipLiveShareHTTPResult) {
        self.result = result
    }

    func execute(_ request: URLRequest) async throws -> ClipLiveShareHTTPResult {
        lastRequestURL = request.url
        return result
    }
}

private struct NativeViewerFriendSecurityFixture {
    let hostSigner: ClipLiveShareSoftwareIdentitySigner
    let viewerSigner: ClipLiveShareSoftwareIdentitySigner
    let endpoint: ClipLiveShareServerEndpoint
    let rendezvousID: ClipLiveShareRendezvousID
    let issuedAt: ClipLiveShareNativeTimestamp
    let now: ClipLiveShareNativeTimestamp
    let descriptor: ClipLiveShareNativeSessionDescriptor
    let request: ClipLiveShareNativeFriendRequest

    init() throws {
        hostSigner = try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(repeating: 0x11, count: 32)
        )
        viewerSigner = try ClipLiveShareSoftwareIdentitySigner(
            rawRepresentation: Data(repeating: 0x22, count: 32)
        )
        endpoint = .official
        rendezvousID = try ClipLiveShareRendezvousID(
            bytes: Data(repeating: 0x33, count: 32)
        )
        issuedAt = try ClipLiveShareNativeTimestamp(
            millisecondsSince1970: 1_750_000_000_000
        )
        now = try issuedAt.adding(milliseconds: 1_000)
        let roomIdentity = ClipLiveShareRoomIdentity()
        descriptor = try ClipLiveShareNativeSessionDescriptor(
            endpoint: endpoint,
            room: ClipLiveShareRoomName(rawValue: "CALM-OTTER-042"),
            rendezvousID: rendezvousID,
            hostIdentity: hostSigner.publicKey,
            roomPublicKey: roomIdentity.publicKey,
            sessionID: ClipLiveShareSessionID(rawValue: "viewer-security-session"),
            issuedAt: issuedAt,
            expiresAt: issuedAt.adding(milliseconds: 120_000),
            stateRevision: ClipLiveShareStateRevision(rawValue: 7)
        )
        request = try Self.makeRequest(
            requestIDByte: 0x55,
            descriptor: descriptor,
            viewerSigner: viewerSigner,
            endpoint: endpoint,
            rendezvousID: rendezvousID,
            issuedAt: issuedAt
        )
    }

    func makeRequest(requestIDByte: UInt8) throws -> ClipLiveShareNativeFriendRequest {
        try Self.makeRequest(
            requestIDByte: requestIDByte,
            descriptor: descriptor,
            viewerSigner: viewerSigner,
            endpoint: endpoint,
            rendezvousID: rendezvousID,
            issuedAt: issuedAt
        )
    }

    func descriptor(
        sessionID: ClipLiveShareSessionID? = nil,
        stateRevision: ClipLiveShareStateRevision
    ) throws -> ClipLiveShareNativeSessionDescriptor {
        try ClipLiveShareNativeSessionDescriptor(
            endpoint: descriptor.endpoint,
            room: descriptor.room,
            rendezvousID: descriptor.rendezvousID,
            hostIdentity: descriptor.hostIdentity,
            roomPublicKey: descriptor.roomPublicKey,
            sessionID: sessionID ?? descriptor.sessionID,
            issuedAt: descriptor.issuedAt,
            expiresAt: descriptor.expiresAt,
            stateRevision: stateRevision
        )
    }

    func acceptance(
        for request: ClipLiveShareNativeFriendRequest
    ) -> ClipLiveShareNativeFriendAcceptance {
        try! ClipLiveShareNativeFriendAcceptance(
            requestID: request.requestID,
            sessionID: request.sessionID,
            requestDigest: request.digest,
            accepterIdentity: hostSigner.publicKey,
            requesterFingerprint: request.requesterIdentity.fingerprint,
            accepterDisplayName: "Host Person",
            accepterDeviceName: "Host Mac",
            accepterEndpoint: endpoint,
            rendezvousID: rendezvousID,
            acceptedAt: now,
            stateRevision: descriptor.stateRevision
        )
    }

    func commitReceiptExchange() throws -> (
        acceptance: ClipLiveShareNativeFriendAcceptance,
        acknowledgement: ClipLiveShareNativeFriendAcceptanceAcknowledgement,
        signedAcknowledgement: ClipLiveShareSignedNativeFriendMessage,
        receipt: ClipLiveShareNativeFriendCommitReceipt,
        signedReceipt: ClipLiveShareSignedNativeFriendMessage
    ) {
        let acceptance = acceptance(for: request)
        let acknowledgement = try ClipLiveShareNativeFriendAcceptanceAcknowledgement(
            acknowledging: acceptance,
            for: request,
            acknowledgedAt: now
        )
        let signedAcknowledgement = try ClipLiveShareSignedNativeFriendMessage(
            signing: .acceptanceAcknowledged(acknowledgement),
            with: viewerSigner
        )
        let receipt = try ClipLiveShareNativeFriendCommitReceipt(
            committing: acknowledgement,
            acknowledgementDigest: signedAcknowledgement.digest,
            acceptance: acceptance,
            request: request,
            committedAt: now
        )
        let signedReceipt = try ClipLiveShareSignedNativeFriendMessage(
            signing: .commitReceipt(receipt),
            with: hostSigner
        )
        return (
            acceptance,
            acknowledgement,
            signedAcknowledgement,
            receipt,
            signedReceipt
        )
    }

    private static func makeRequest(
        requestIDByte: UInt8,
        descriptor: ClipLiveShareNativeSessionDescriptor,
        viewerSigner: ClipLiveShareSoftwareIdentitySigner,
        endpoint: ClipLiveShareServerEndpoint,
        rendezvousID: ClipLiveShareRendezvousID,
        issuedAt: ClipLiveShareNativeTimestamp
    ) throws -> ClipLiveShareNativeFriendRequest {
        try ClipLiveShareNativeFriendRequest(
            requestID: ClipLiveShareFriendRequestID(
                bytes: Data(repeating: requestIDByte, count: 16)
            ),
            sessionID: descriptor.sessionID,
            sessionDescriptorDigest: descriptor.digest,
            requestedHostFingerprint: descriptor.hostIdentity.fingerprint,
            requesterIdentity: viewerSigner.publicKey,
            requesterEndpoint: endpoint,
            requesterRendezvousID: rendezvousID,
            requesterDeviceName: "Viewer Mac",
            issuedAt: issuedAt,
            expiresAt: issuedAt.adding(milliseconds: 300_000)
        )
    }
}
