import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation

enum MeshParticipantEncryptedRendezvousError: Error, Equatable,
    LocalizedError, Sendable
{
    case alreadyStarted
    case notStarted
    case closed
    case invalidPacket
    case unexpectedPacket
    case invalidRoute
    case routeNotReady
    case participantRouteMismatch
    case descriptorRejected

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "The native-v3 rendezvous is already started."
        case .notStarted:
            "The native-v3 rendezvous is not started."
        case .closed:
            "The native-v3 rendezvous is closed."
        case .invalidPacket:
            "The native-v3 rendezvous packet is invalid."
        case .unexpectedPacket:
            "The native-v3 rendezvous packet is not valid in this phase."
        case .invalidRoute:
            "The native-v3 rendezvous route is invalid."
        case .routeNotReady:
            "The native-v3 rendezvous route is not authenticated yet."
        case .participantRouteMismatch:
            "The native-v3 participant is bound to another rendezvous route."
        case .descriptorRejected:
            "The native-v3 room descriptor was rejected."
        }
    }
}

enum MeshParticipantEncryptedRendezvousEvent: Equatable, Sendable {
    case routeReady(
        participantID: ClipLiveShareNativeV3ParticipantID,
        proof: ClipLiveShareNativeV3RendezvousProof
    )
    case envelope(
        ClipLiveShareNativeV3BootstrapEnvelope,
        from: ClipLiveShareNativeV3ParticipantID
    )
    case routeClosed(
        participantID: ClipLiveShareNativeV3ParticipantID?,
        reason: String?
    )
    case failed(String)
    case stopped
}

struct MeshParticipantRendezvousOwnerTransport: Sendable {
    var events: @Sendable () async
        -> AsyncStream<ClipNativeRendezvousEvent>
    var attach: @Sendable (ClipNativeRendezvousOwner) async throws -> Void
    var publish: @Sendable (Data) async throws -> Void
    var send: @Sendable (Data, String) async throws -> Void
    var closeRoute: @Sendable (String, String?) async -> Void
    var teardown: @Sendable (Bool) async -> Void

    init(
        events: @escaping @Sendable () async
            -> AsyncStream<ClipNativeRendezvousEvent>,
        attach: @escaping @Sendable (
            ClipNativeRendezvousOwner
        ) async throws -> Void,
        publish: @escaping @Sendable (Data) async throws -> Void,
        send: @escaping @Sendable (Data, String) async throws -> Void,
        closeRoute: @escaping @Sendable (String, String?) async -> Void,
        teardown: @escaping @Sendable (Bool) async -> Void
    ) {
        self.events = events
        self.attach = attach
        self.publish = publish
        self.send = send
        self.closeRoute = closeRoute
        self.teardown = teardown
    }

    static func live(
        _ transport: ClipNativeRendezvousOwnerTransport =
            .init(reconnectPolicy: .persistentExponential)
    ) -> Self {
        Self(
            events: { await transport.events() },
            attach: { owner in
                _ = try await transport.attachOwner(owner)
            },
            publish: { descriptor in
                try await transport.publishSession(
                    descriptor: descriptor
                )
            },
            send: { payload, routeID in
                try await transport.send(payload, to: routeID)
            },
            closeRoute: { routeID, reason in
                await transport.closeRoute(routeID, reason: reason)
            },
            teardown: { remove in
                await transport.teardown(removeRendezvous: remove)
            }
        )
    }
}

struct MeshParticipantRendezvousCandidateTransport: Sendable {
    var events: @Sendable () async
        -> AsyncStream<ClipNativeRendezvousEvent>
    var attach: @Sendable (
        ClipNativeRendezvousTarget
    ) async throws -> Void
    var send: @Sendable (Data) async throws -> Void
    var closeRoute: @Sendable (String?) async -> Void
    var teardown: @Sendable () async -> Void

    init(
        events: @escaping @Sendable () async
            -> AsyncStream<ClipNativeRendezvousEvent>,
        attach: @escaping @Sendable (
            ClipNativeRendezvousTarget
        ) async throws -> Void,
        send: @escaping @Sendable (Data) async throws -> Void,
        closeRoute: @escaping @Sendable (String?) async -> Void,
        teardown: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        self.attach = attach
        self.send = send
        self.closeRoute = closeRoute
        self.teardown = teardown
    }

    static func live(
        _ transport: ClipNativeRendezvousCandidateTransport =
            .init(reconnectPolicy: .persistentExponential)
    ) -> Self {
        Self(
            events: { await transport.events() },
            attach: { target in
                _ = try await transport.attachCandidate(target)
            },
            send: { payload in
                try await transport.send(payload)
            },
            closeRoute: { reason in
                await transport.closeRoute(reason: reason)
            },
            teardown: {
                await transport.teardown()
            }
        )
    }
}

/// Current-leader side of the clean-slate native-v3 invitation route.
///
/// The native rendezvous server sees only the signed public room descriptor,
/// route metadata and opaque ciphertext. The participant identity and
/// ephemeral key preface are themselves encrypted with the invite capability;
/// all subsequent bootstrap messages use pairwise P-256/AES-GCM.
actor MeshParticipantEncryptedRendezvousOwner {
    private struct RouteState: Sendable {
        let participantID: ClipLiveShareNativeV3ParticipantID
        let proof: ClipLiveShareNativeV3RendezvousProof
        var channel: ClipLiveShareNativeV3EncryptedRendezvousChannel
    }

    let invite: ClipLiveShareNativeV3Invite

    private let signer: any ClipLiveShareIdentitySigner
    private let leaderRendezvousIdentity: ClipLiveShareNativeV3RendezvousIdentity
    private let owner: ClipNativeRendezvousOwner
    private let transport: MeshParticipantRendezvousOwnerTransport
    private let now: @Sendable () throws
        -> ClipLiveShareNativeTimestamp
    private let accessWordRequired: Bool

    private var pendingRoutes: Set<String> = []
    private var routesByID: [String: RouteState] = [:]
    private var routeIDByParticipant:
        [ClipLiveShareNativeV3ParticipantID: String] = [:]
    private var continuations: [
        UUID:
            AsyncStream<MeshParticipantEncryptedRendezvousEvent>
                .Continuation
    ] = [:]
    private var eventTask: Task<Void, Never>?
    private var didStart = false
    private var isClosed = false

    init(
        endpoint: URL,
        sessionID: ClipLiveShareSessionID,
        foundingCreatorIdentity: ClipLiveShareIdentityPublicKey,
        leaderParticipantID: ClipLiveShareNativeV3ParticipantID,
        leaderSigner: any ClipLiveShareIdentitySigner,
        rendezvousID:
            ClipLiveShareNativeV3RendezvousID = .random(),
        admissionCapability: ClipLiveShareNativeV3AdmissionCapability = .random(),
        leaderRendezvousIdentity: ClipLiveShareNativeV3RendezvousIdentity = .init(),
        accessWordRequired: Bool = false,
        ownerToken: Data = meshRendezvousRandomData(count: 32),
        transport: MeshParticipantRendezvousOwnerTransport = .live(),
        now: @escaping @Sendable () throws
            -> ClipLiveShareNativeTimestamp = {
                try .init(date: Date())
            }
    ) throws {
        invite = try ClipLiveShareNativeV3Invite(
            endpoint: endpoint,
            rendezvousID: rendezvousID,
            sessionID: sessionID,
            foundingCreatorIdentity: foundingCreatorIdentity,
            leaderParticipantID: leaderParticipantID,
            leaderIdentity: leaderSigner.publicKey,
            leaderRendezvousPublicKey: leaderRendezvousIdentity.publicKey,
            admissionCapability: admissionCapability
        )
        signer = leaderSigner
        self.leaderRendezvousIdentity = leaderRendezvousIdentity
        self.transport = transport
        self.now = now
        self.accessWordRequired = accessWordRequired
        let target = try ClipNativeRendezvousTarget(
            endpoint: endpoint,
            rendezvousID: rendezvousID.bytes
        )
        owner = try ClipNativeRendezvousOwner(
            target: target,
            ownerToken: ownerToken
        )
    }

    func events()
        -> AsyncStream<MeshParticipantEncryptedRendezvousEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: MeshParticipantEncryptedRendezvousEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        guard !isClosed else {
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    func start() async throws {
        guard !isClosed else {
            throw MeshParticipantEncryptedRendezvousError.closed
        }
        guard !didStart else {
            throw MeshParticipantEncryptedRendezvousError.alreadyStarted
        }
        didStart = true
        let stream = await transport.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
        do {
            try await transport.attach(owner)
            let issuedAt = try now()
            let descriptor = try ClipLiveShareNativeV3RoomDescriptor(
                rendezvousID: invite.rendezvousID,
                sessionID: invite.sessionID,
                foundingCreatorIdentity:
                    invite.foundingCreatorIdentity,
                leaderParticipantID: invite.leaderParticipantID,
                leaderIdentity: invite.leaderIdentity,
                leaderRendezvousPublicKey: invite.leaderRendezvousPublicKey,
                accessWordRequired: accessWordRequired,
                issuedAt: issuedAt,
                expiresAt: issuedAt.adding(
                    milliseconds:
                        ClipLiveShareNativeV3InviteProtocol
                        .maximumDescriptorLifetimeMilliseconds
                )
            )
            try await transport.publish(
                ClipLiveShareSignedNativeV3RoomDescriptor(
                    signing: descriptor,
                    with: signer
                ).encoded()
            )
        } catch {
            await stop(removeRendezvous: true)
            throw error
        }
    }

    func send(
        _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        guard didStart else {
            throw MeshParticipantEncryptedRendezvousError.notStarted
        }
        guard !isClosed else {
            throw MeshParticipantEncryptedRendezvousError.closed
        }
        guard
            let rawRouteID = routeIDByParticipant[participantID],
            var state = routesByID[rawRouteID],
            state.participantID == participantID
        else {
            throw MeshParticipantEncryptedRendezvousError
                .routeNotReady
        }
        let sealed = try state.channel.seal(envelope)
        routesByID[rawRouteID] = state
        try await transport.send(
            try MeshParticipantRendezvousPacketCodec.encrypted(
                sealed,
                routeID: state.channel.routeID
            ),
            rawRouteID
        )
    }

    func closeRoute(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        reason: String? = nil
    ) async {
        guard let rawRouteID =
            routeIDByParticipant.removeValue(forKey: participantID)
        else { return }
        routesByID[rawRouteID] = nil
        pendingRoutes.remove(rawRouteID)
        await transport.closeRoute(rawRouteID, reason)
    }

    func stop(removeRendezvous: Bool = true) async {
        guard !isClosed else { return }
        isClosed = true
        didStart = false
        eventTask?.cancel()
        eventTask = nil
        pendingRoutes.removeAll()
        routesByID.removeAll()
        routeIDByParticipant.removeAll()
        await transport.teardown(removeRendezvous)
        emit(.stopped)
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func handle(_ event: ClipNativeRendezvousEvent) async {
        do {
            switch event {
            case let .routeOpened(rawRouteID, _):
                _ = try ClipLiveShareRouteID(rawValue: rawRouteID)
                pendingRoutes.insert(rawRouteID)

            case let .relay(rawRouteID, payload, _):
                try await receive(payload, on: rawRouteID)

            case let .routeClosed(rawRouteID, reason):
                pendingRoutes.remove(rawRouteID)
                let state = routesByID.removeValue(
                    forKey: rawRouteID
                )
                if let participantID = state?.participantID {
                    routeIDByParticipant[participantID] = nil
                }
                emit(.routeClosed(
                    participantID: state?.participantID,
                    reason: reason
                ))

            case .invalidMessageReceived, .eventBufferOverflow:
                emit(.failed(
                    MeshParticipantEncryptedRendezvousError
                        .invalidPacket.localizedDescription
                ))

            case let .serverError(code):
                emit(.failed("Native-v3 rendezvous server: \(code)"))

            case let .disconnected(reason, willReconnect):
                if !willReconnect {
                    emit(.failed(
                        "Native-v3 rendezvous disconnected: \(reason)"
                    ))
                }

            case .stopped:
                if !isClosed { emit(.stopped) }

            case .connecting, .connected, .ownerPreparing, .ownerActive,
                 .reconnectScheduled:
                break
            }
        } catch {
            let rawRouteID = routeID(for: event)
            let participantID = rawRouteID.flatMap {
                routesByID[$0]?.participantID
            }
            await reject(rawRouteID: rawRouteID)
            if rawRouteID != nil {
                // A malformed candidate route is adversarial input scoped to
                // that route. It must not make the established room appear
                // failed or tear down an unrelated active admission.
                emit(.routeClosed(
                    participantID: participantID,
                    reason: "v3-route-rejected"
                ))
            } else {
                emit(.failed(error.localizedDescription))
            }
        }
    }

    private func receive(_ payload: Data, on rawRouteID: String)
        async throws {
        guard pendingRoutes.contains(rawRouteID) else {
            throw MeshParticipantEncryptedRendezvousError.invalidRoute
        }
        let routeID = try ClipLiveShareRouteID(rawValue: rawRouteID)
        let packet = try MeshParticipantRendezvousPacketCodec.decode(
            payload,
            expectedRouteID: routeID
        )
        if var state = routesByID[rawRouteID] {
            guard case let .encrypted(sealed) = packet else {
                throw MeshParticipantEncryptedRendezvousError
                    .unexpectedPacket
            }
            let envelope = try state.channel.open(sealed)
            routesByID[rawRouteID] = state
            emit(.envelope(envelope, from: state.participantID))
            return
        }

        guard case let .sealedKnock(sealedKnock) = packet else {
            throw MeshParticipantEncryptedRendezvousError
                .unexpectedPacket
        }
        let knock =
            try ClipLiveShareNativeV3RendezvousKnock.openSealed(
                sealedKnock,
                expectedSessionID: invite.sessionID,
                expectedRendezvousID: invite.rendezvousID,
                expectedRouteID: routeID,
                admissionCapability: invite.admissionCapability
            )
        guard
            routeIDByParticipant[knock.participantID] == nil
        else {
            throw MeshParticipantEncryptedRendezvousError
                .participantRouteMismatch
        }
        let proof = ClipLiveShareNativeV3RendezvousProof(
            sessionID: invite.sessionID,
            rendezvousID: invite.rendezvousID,
            routeID: routeID,
            foundingCreatorIdentity:
                invite.foundingCreatorIdentity,
            admissionCapability: invite.admissionCapability
        )
        let channel =
            try ClipLiveShareNativeV3EncryptedRendezvousChannel(
                leader: leaderRendezvousIdentity,
                candidatePublicKey:
                    knock.ephemeralPublicKey,
                sessionID: invite.sessionID,
                rendezvousID: invite.rendezvousID,
                routeID: routeID
            )
        routesByID[rawRouteID] = RouteState(
            participantID: knock.participantID,
            proof: proof,
            channel: channel
        )
        routeIDByParticipant[knock.participantID] = rawRouteID
        emit(.routeReady(
            participantID: knock.participantID,
            proof: proof
        ))
    }

    private func reject(rawRouteID: String?) async {
        guard let rawRouteID else { return }
        pendingRoutes.remove(rawRouteID)
        let state = routesByID.removeValue(forKey: rawRouteID)
        if let participantID = state?.participantID {
            routeIDByParticipant[participantID] = nil
        }
        await transport.closeRoute(rawRouteID, "v3-route-rejected")
    }

    private func routeID(
        for event: ClipNativeRendezvousEvent
    ) -> String? {
        switch event {
        case let .routeOpened(routeID, _),
             let .relay(routeID, _, _),
             let .routeClosed(routeID, _):
            routeID
        default:
            nil
        }
    }

    private func emit(
        _ event: MeshParticipantEncryptedRendezvousEvent
    ) {
        var terminated: [UUID] = []
        for (id, continuation) in continuations {
            switch continuation.yield(event) {
            case .enqueued:
                break
            case .dropped, .terminated:
                continuation.finish()
                terminated.append(id)
            @unknown default:
                continuation.finish()
                terminated.append(id)
            }
        }
        for id in terminated { continuations[id] = nil }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

/// Candidate side of the clean-slate native-v3 invitation route.
actor MeshParticipantEncryptedRendezvousCandidate {
    let invite: ClipLiveShareNativeV3Invite
    let participantID: ClipLiveShareNativeV3ParticipantID

    private let candidateRendezvousIdentity: ClipLiveShareNativeV3RendezvousIdentity
    private let transport: MeshParticipantRendezvousCandidateTransport
    private let now: @Sendable () throws
        -> ClipLiveShareNativeTimestamp
    private var routeID: ClipLiveShareRouteID?
    private var proof: ClipLiveShareNativeV3RendezvousProof?
    private var channel:
        ClipLiveShareNativeV3EncryptedRendezvousChannel?
    private var descriptorAccessWordRequired: Bool?
    private var continuations: [
        UUID:
            AsyncStream<MeshParticipantEncryptedRendezvousEvent>
                .Continuation
    ] = [:]
    private var eventTask: Task<Void, Never>?
    private var didStart = false
    private var isClosed = false

    init(
        invite: ClipLiveShareNativeV3Invite,
        participantID: ClipLiveShareNativeV3ParticipantID,
        candidateRendezvousIdentity: ClipLiveShareNativeV3RendezvousIdentity = .init(),
        transport: MeshParticipantRendezvousCandidateTransport = .live(),
        now: @escaping @Sendable () throws
            -> ClipLiveShareNativeTimestamp = {
                try .init(date: Date())
            }
    ) {
        self.invite = invite
        self.participantID = participantID
        self.candidateRendezvousIdentity = candidateRendezvousIdentity
        self.transport = transport
        self.now = now
    }

    func events()
        -> AsyncStream<MeshParticipantEncryptedRendezvousEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: MeshParticipantEncryptedRendezvousEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        guard !isClosed else {
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    func start() async throws {
        guard !isClosed else {
            throw MeshParticipantEncryptedRendezvousError.closed
        }
        guard !didStart else {
            throw MeshParticipantEncryptedRendezvousError.alreadyStarted
        }
        didStart = true
        let stream = await transport.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
        do {
            try await transport.attach(
                ClipNativeRendezvousTarget(
                    endpoint: invite.endpoint,
                    rendezvousID: invite.rendezvousID.bytes
                )
            )
        } catch {
            await stop()
            throw error
        }
    }

    func send(
        _ envelope: ClipLiveShareNativeV3BootstrapEnvelope,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        guard participantID == invite.leaderParticipantID else {
            throw MeshParticipantEncryptedRendezvousError
                .participantRouteMismatch
        }
        guard didStart else {
            throw MeshParticipantEncryptedRendezvousError.notStarted
        }
        guard !isClosed else {
            throw MeshParticipantEncryptedRendezvousError.closed
        }
        guard let routeID, var channel else {
            throw MeshParticipantEncryptedRendezvousError
                .routeNotReady
        }
        let sealed = try channel.seal(envelope)
        self.channel = channel
        try await transport.send(
            try MeshParticipantRendezvousPacketCodec.encrypted(
                sealed,
                routeID: routeID
            )
        )
    }

    /// Available after the signed descriptor has been verified and before the
    /// candidate sends its bootstrap hello.
    func accessWordRequired() -> Bool? {
        descriptorAccessWordRequired
    }

    func stop() async {
        guard !isClosed else { return }
        isClosed = true
        didStart = false
        eventTask?.cancel()
        eventTask = nil
        routeID = nil
        proof = nil
        channel = nil
        descriptorAccessWordRequired = nil
        await transport.teardown()
        emit(.stopped)
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func handle(_ event: ClipNativeRendezvousEvent) async {
        do {
            switch event {
            case let .routeOpened(rawRouteID, descriptorData):
                guard
                    routeID == nil,
                    let descriptorData
                else {
                    throw MeshParticipantEncryptedRendezvousError
                        .unexpectedPacket
                }
                let openedRouteID =
                    try ClipLiveShareRouteID(rawValue: rawRouteID)
                let descriptor =
                    try ClipLiveShareSignedNativeV3RoomDescriptor
                    .decode(descriptorData)
                try descriptor.verify(
                    matching: invite,
                    at: try now()
                )
                descriptorAccessWordRequired =
                    descriptor.descriptor.accessWordRequired
                let rendezvousProof =
                    ClipLiveShareNativeV3RendezvousProof(
                        sessionID: invite.sessionID,
                        rendezvousID: invite.rendezvousID,
                        routeID: openedRouteID,
                        foundingCreatorIdentity:
                            invite.foundingCreatorIdentity,
                        admissionCapability: invite.admissionCapability
                    )
                let encryptedChannel =
                    try ClipLiveShareNativeV3EncryptedRendezvousChannel(
                        candidate: candidateRendezvousIdentity,
                        leaderPublicKey: invite.leaderRendezvousPublicKey,
                        sessionID: invite.sessionID,
                        rendezvousID: invite.rendezvousID,
                        routeID: openedRouteID
                    )
                let knock = ClipLiveShareNativeV3RendezvousKnock(
                    sessionID: invite.sessionID,
                    rendezvousID: invite.rendezvousID,
                    routeID: openedRouteID,
                    participantID: participantID,
                    ephemeralPublicKey: candidateRendezvousIdentity.publicKey,
                    admissionCapability: invite.admissionCapability
                )
                routeID = openedRouteID
                proof = rendezvousProof
                channel = encryptedChannel
                try await transport.send(
                    MeshParticipantRendezvousPacketCodec.sealedKnock(
                        try knock.sealed(
                            with: invite.admissionCapability
                        )
                    )
                )
                emit(.routeReady(
                    participantID: invite.leaderParticipantID,
                    proof: rendezvousProof
                ))

            case let .relay(rawRouteID, payload, _):
                guard
                    let routeID,
                    rawRouteID == routeID.rawValue,
                    var channel
                else {
                    throw MeshParticipantEncryptedRendezvousError
                        .invalidRoute
                }
                let packet =
                    try MeshParticipantRendezvousPacketCodec.decode(
                        payload,
                        expectedRouteID: routeID
                    )
                guard case let .encrypted(sealed) = packet else {
                    throw MeshParticipantEncryptedRendezvousError
                        .unexpectedPacket
                }
                let envelope = try channel.open(sealed)
                self.channel = channel
                emit(.envelope(
                    envelope,
                    from: invite.leaderParticipantID
                ))

            case let .routeClosed(_, reason):
                emit(.routeClosed(
                    participantID: invite.leaderParticipantID,
                    reason: reason
                ))

            case .invalidMessageReceived, .eventBufferOverflow:
                emit(.failed(
                    MeshParticipantEncryptedRendezvousError
                        .invalidPacket.localizedDescription
                ))

            case let .serverError(code):
                emit(.failed("Native-v3 rendezvous server: \(code)"))

            case let .disconnected(reason, willReconnect):
                if !willReconnect {
                    emit(.failed(
                        "Native-v3 rendezvous disconnected: \(reason)"
                    ))
                }

            case .stopped:
                if !isClosed { emit(.stopped) }

            case .connecting, .connected, .ownerPreparing, .ownerActive,
                 .reconnectScheduled:
                break
            }
        } catch {
            emit(.failed(error.localizedDescription))
            await transport.closeRoute("v3-route-rejected")
        }
    }

    private func emit(
        _ event: MeshParticipantEncryptedRendezvousEvent
    ) {
        var terminated: [UUID] = []
        for (id, continuation) in continuations {
            switch continuation.yield(event) {
            case .enqueued:
                break
            case .dropped, .terminated:
                continuation.finish()
                terminated.append(id)
            @unknown default:
                continuation.finish()
                terminated.append(id)
            }
        }
        for id in terminated { continuations[id] = nil }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

private enum MeshParticipantRendezvousPacket: Sendable {
    case sealedKnock(Data)
    case encrypted(ClipLiveShareNativeV3RelayEnvelope)
}

private enum MeshParticipantRendezvousPacketCodec {
    private static let version: UInt8 = 3
    private static let sealedKnockKind: UInt8 = 1
    private static let encryptedKind: UInt8 = 2

    private struct EncryptedWire: Codable {
        let version: Int
        let routeID: ClipLiveShareRouteID
        let sequence: UInt64
        let nonce: Data
        let ciphertext: Data

        enum CodingKeys: String, CodingKey, CaseIterable {
            case version
            case routeID = "routeId"
            case sequence
            case nonce
            case ciphertext
        }
    }

    static func sealedKnock(_ data: Data) -> Data {
        var packet = Data([version, sealedKnockKind])
        packet.append(data)
        return packet
    }

    static func encrypted(
        _ envelope: ClipLiveShareNativeV3RelayEnvelope,
        routeID: ClipLiveShareRouteID
    ) throws -> Data {
        guard
            envelope.routeID == nil
                || envelope.routeID == routeID
        else {
            throw MeshParticipantEncryptedRendezvousError
                .invalidRoute
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let wire = try encoder.encode(EncryptedWire(
            version: Int(version),
            routeID: routeID,
            sequence: envelope.sequence,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext
        ))
        var packet = Data([version, encryptedKind])
        packet.append(wire)
        guard packet.count
            <= ClipNativeRendezvousLimits.maximumOpaquePayloadBytes
        else {
            throw MeshParticipantEncryptedRendezvousError
                .invalidPacket
        }
        return packet
    }

    static func decode(
        _ data: Data,
        expectedRouteID: ClipLiveShareRouteID
    ) throws -> MeshParticipantRendezvousPacket {
        guard
            data.count >= 3,
            data[0] == version
        else {
            throw MeshParticipantEncryptedRendezvousError.invalidPacket
        }
        let payload = data.dropFirst(2)
        switch data[1] {
        case sealedKnockKind:
            guard payload.count
                <= ClipLiveShareNativeV3InviteProtocol
                .maximumSealedKnockBytes
            else {
                throw MeshParticipantEncryptedRendezvousError
                    .invalidPacket
            }
            return .sealedKnock(Data(payload))

        case encryptedKind:
            let payloadData = Data(payload)
            guard
                let object = try? JSONSerialization.jsonObject(
                    with: payloadData
                ),
                let dictionary = object as? [String: Any],
                Set(dictionary.keys)
                    == Set(EncryptedWire.CodingKeys.allCases.map(
                        \.stringValue
                    ))
            else {
                throw MeshParticipantEncryptedRendezvousError
                    .invalidPacket
            }
            let wire: EncryptedWire
            do {
                wire = try JSONDecoder().decode(
                    EncryptedWire.self,
                    from: payloadData
                )
            } catch {
                throw MeshParticipantEncryptedRendezvousError
                    .invalidPacket
            }
            guard
                wire.version == Int(version),
                wire.routeID == expectedRouteID
            else {
                throw MeshParticipantEncryptedRendezvousError
                    .invalidRoute
            }
            return .encrypted(
                try ClipLiveShareNativeV3RelayEnvelope(
                    routeID: wire.routeID,
                    sequence: wire.sequence,
                    nonce: wire.nonce,
                    ciphertext: wire.ciphertext
                )
            )

        default:
            throw MeshParticipantEncryptedRendezvousError.invalidPacket
        }
    }
}

private func meshRendezvousRandomData(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in
        UInt8.random(in: .min ... .max, using: &generator)
    })
}
