import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation

enum MeshParticipantProvisionalPeerLinkAdapterError: Error, Equatable,
    LocalizedError, Sendable
{
    case closed
    case callbacksUnavailable
    case invalidPair
    case conflictingPair
    case unknownPair(ClipLiveShareNativeV3ParticipantID)
    case staleNegotiationRevision
    case staleICESequence
    case promotionContextMismatch

    var errorDescription: String? {
        switch self {
        case .closed:
            "The provisional peer-link adapter is closed."
        case .callbacksUnavailable:
            "The provisional peer-link callbacks are not installed."
        case .invalidPair:
            "The provisional peer link is not bound to this participant and admission."
        case .conflictingPair:
            "A different provisional admission is already preparing this peer."
        case let .unknownPair(participantID):
            "There is no provisional link for \(participantID.rawValue)."
        case .staleNegotiationRevision:
            "The provisional peer-link negotiation revision is stale."
        case .staleICESequence:
            "The provisional peer-link ICE sequence is stale."
        case .promotionContextMismatch:
            "The committed membership does not match the prepared provisional links."
        }
    }
}

struct MeshParticipantProvisionalPeerLinkCallbacks: Sendable {
    typealias SendRelay = @Sendable (
        ClipLiveShareNativeV3BootstrapRelayPayload,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void
    typealias MarkReady = @Sendable (
        ClipLiveShareNativeV3ParticipantID,
        ClipLiveShareNativeTimestamp
    ) async throws -> Void
    typealias ReportFailure = @Sendable (String) -> Void

    let sendRelay: SendRelay
    let markReady: MarkReady
    let reportFailure: ReportFailure

    init(
        sendRelay: @escaping SendRelay,
        markReady: @escaping MarkReady,
        reportFailure: @escaping ReportFailure = { _ in }
    ) {
        self.sendRelay = sendRelay
        self.markReady = markReady
        self.reportFailure = reportFailure
    }
}

/// Owns the authenticated-but-quarantined phase of native-v3 peer links.
///
/// The adapter and `MeshParticipantRuntime` intentionally share the exact same
/// `ClipLiveShareNativeV3MeshPeerLinkManager`. Before membership commit this
/// object alone handles signed, admission-bound SDP/ICE. Room control events
/// are ignored by the runtime and every local RTP encoding is inactive. After
/// `promote` verifies the committed launch context, the same transports are
/// enabled and the runtime takes over their direct control channels without a
/// reconnect or a second WebRTC connection.
actor MeshParticipantProvisionalPeerLinkAdapter {
    private struct NegotiationState: Sendable {
        var nextRevisionRawValue: UInt64 = 1
        var activeRevision: ClipLiveShareNativeV3PeerLinkRevision?
        var nextOutgoingICESequence: UInt32 = 0
        var latestIncomingICESequence: UInt32?
    }

    private struct PairState: Sendable {
        let descriptor: MeshParticipantBootstrapProvisionalPair
        var negotiation = NegotiationState()
        var readinessReported = false
    }

    private let localParticipantID: ClipLiveShareNativeV3ParticipantID
    private let localSigner: any ClipLiveShareIdentitySigner
    private let manager: ClipLiveShareNativeV3MeshPeerLinkManager
    private let now: @Sendable () -> Date

    private var committedParticipantIDs:
        Set<ClipLiveShareNativeV3ParticipantID>
    private var pairs:
        [ClipLiveShareNativeV3ParticipantID: PairState] = [:]
    private var callbacks: MeshParticipantProvisionalPeerLinkCallbacks?
    private var eventTask: Task<Void, Never>?
    private var didStartEventLoop = false
    private var isClosed = false

    init(
        localParticipantID: ClipLiveShareNativeV3ParticipantID,
        localSigner: any ClipLiveShareIdentitySigner,
        committedParticipantIDs:
            Set<ClipLiveShareNativeV3ParticipantID>,
        manager: ClipLiveShareNativeV3MeshPeerLinkManager,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard committedParticipantIDs.contains(localParticipantID) else {
            throw MeshParticipantProvisionalPeerLinkAdapterError.invalidPair
        }
        self.localParticipantID = localParticipantID
        self.localSigner = localSigner
        self.committedParticipantIDs = committedParticipantIDs
        self.manager = manager
        self.now = now
    }

    nonisolated func makePairHooks() -> MeshParticipantBootstrapPairHooks {
        MeshParticipantBootstrapPairHooks(
            prepare: { [self] pair in
                try await prepare(pair)
            },
            receiveRelay: { [self] payload, remoteParticipantID, pair in
                try await receiveRelay(
                    payload,
                    from: remoteParticipantID,
                    pair: pair
                )
            },
            abort: { [self] remoteParticipantID in
                await abort(remoteParticipantID)
            },
            promote: { [self] context in
                try await promote(context)
            }
        )
    }

    func installCallbacks(
        _ callbacks: MeshParticipantProvisionalPeerLinkCallbacks
    ) async {
        self.callbacks = callbacks
        await startEventLoopIfNeeded()
    }

    func prepare(
        _ descriptor: MeshParticipantBootstrapProvisionalPair
    ) async throws {
        try requireOpen()
        guard callbacks != nil else {
            throw MeshParticipantProvisionalPeerLinkAdapterError
                .callbacksUnavailable
        }
        try validate(descriptor)
        if let existing = pairs[descriptor.remoteParticipantID] {
            guard sameAdmission(
                existing.descriptor,
                descriptor
            ) else {
                throw MeshParticipantProvisionalPeerLinkAdapterError
                    .conflictingPair
            }
            return
        }

        pairs[descriptor.remoteParticipantID] = PairState(
            descriptor: descriptor
        )
        await startEventLoopIfNeeded()
        do {
            try await reconcile()
        } catch {
            pairs[descriptor.remoteParticipantID] = nil
            throw error
        }
    }

    func receiveRelay(
        _ payload: ClipLiveShareNativeV3BootstrapRelayPayload,
        from remoteParticipantID: ClipLiveShareNativeV3ParticipantID,
        pair descriptor: MeshParticipantBootstrapProvisionalPair
    ) async throws {
        try requireOpen()
        guard var state = pairs[remoteParticipantID] else {
            throw MeshParticipantProvisionalPeerLinkAdapterError
                .unknownPair(remoteParticipantID)
        }
        guard sameAdmission(state.descriptor, descriptor),
              payload.peerLinkKey.participantIDs
                == Set([localParticipantID, remoteParticipantID])
        else {
            throw MeshParticipantProvisionalPeerLinkAdapterError.invalidPair
        }

        switch payload {
        case let .offer(signed):
            let offer = signed.offer
            try validateIncoming(
                offer.context,
                from: remoteParticipantID,
                state: state
            )
            try signed.verify(
                againstProvisionalAdmission: descriptor.admission,
                expectedTransportNonce: descriptor.transportNonce
            )
            if let active = state.negotiation.activeRevision,
               offer.context.negotiationRevision <= active {
                throw MeshParticipantProvisionalPeerLinkAdapterError
                    .staleNegotiationRevision
            }
            state.negotiation.activeRevision =
                offer.context.negotiationRevision
            state.negotiation.nextRevisionRawValue = max(
                state.negotiation.nextRevisionRawValue,
                offer.context.negotiationRevision.rawValue + 1
            )
            state.negotiation.nextOutgoingICESequence = 0
            state.negotiation.latestIncomingICESequence = nil
            pairs[remoteParticipantID] = state
            try await manager.applyRemoteNegotiation(
                .init(
                    peerLinkKey: offer.context.peerLinkKey,
                    targetParticipantID: localParticipantID,
                    payload: .sessionDescription(
                        .init(kind: .offer, sdp: offer.sdp)
                    )
                ),
                from: remoteParticipantID
            )

        case let .answer(signed):
            let answer = signed.answer
            try validateIncoming(
                answer.context,
                from: remoteParticipantID,
                state: state
            )
            try signed.verify(
                againstProvisionalAdmission: descriptor.admission,
                expectedTransportNonce: descriptor.transportNonce
            )
            guard state.negotiation.activeRevision
                == answer.context.negotiationRevision else {
                throw MeshParticipantProvisionalPeerLinkAdapterError
                    .staleNegotiationRevision
            }
            try await manager.applyRemoteNegotiation(
                .init(
                    peerLinkKey: answer.context.peerLinkKey,
                    targetParticipantID: localParticipantID,
                    payload: .sessionDescription(
                        .init(kind: .answer, sdp: answer.sdp)
                    )
                ),
                from: remoteParticipantID
            )

        case let .ice(signed):
            let ice = signed.ice
            try validateIncoming(
                ice.context,
                from: remoteParticipantID,
                state: state
            )
            try signed.verify(
                againstProvisionalAdmission: descriptor.admission,
                expectedTransportNonce: descriptor.transportNonce
            )
            guard state.negotiation.activeRevision
                    == ice.context.negotiationRevision
            else {
                throw MeshParticipantProvisionalPeerLinkAdapterError
                    .staleNegotiationRevision
            }
            if let latest = state.negotiation.latestIncomingICESequence,
               ice.candidateSequence <= latest {
                throw MeshParticipantProvisionalPeerLinkAdapterError
                    .staleICESequence
            }
            state.negotiation.latestIncomingICESequence =
                ice.candidateSequence
            pairs[remoteParticipantID] = state
            try await manager.applyRemoteNegotiation(
                .init(
                    peerLinkKey: ice.context.peerLinkKey,
                    targetParticipantID: localParticipantID,
                    payload: .iceCandidate(
                        .init(
                            candidate: ice.candidate,
                            sdpMid: ice.sdpMid,
                            sdpMLineIndex: Int32(ice.sdpMLineIndex)
                        )
                    )
                ),
                from: remoteParticipantID
            )

        case .possessionChallenge, .possessionProof:
            throw MeshParticipantProvisionalPeerLinkAdapterError.invalidPair
        }
    }

    func promote(
        _ context: MeshParticipantBootstrapLaunchContext
    ) async throws {
        try requireOpen()
        let participantIDs = context.signedMembership.snapshot.participantIDs
        try context.authorityChain.verify(
            expectedSessionID: context.signedMembership.snapshot.sessionID,
            expectedFoundingCreatorIdentity:
                context.expectedFoundingCreatorIdentity,
            localCapabilities: .current,
            at: ClipLiveShareNativeTimestamp(date: now())
        )
        guard
            context.localParticipantID == localParticipantID,
            context.localIdentitySigner.publicKey == localSigner.publicKey,
            context.authorityChain.currentMembership
                == context.signedMembership,
            participantIDs.contains(localParticipantID),
            Set(pairs.keys).isSubset(of: participantIDs),
            pairs.allSatisfy({
                context.verifiedPeerTransportNonces[$0.key]
                    == $0.value.descriptor.transportNonce
                    && context.bootstrapAdmissionDigests[$0.key]
                    == $0.value.descriptor.admissionDigest
                    && $0.value.readinessReported
            })
        else {
            throw MeshParticipantProvisionalPeerLinkAdapterError
                .promotionContextMismatch
        }

        let remainingProvisional = pairs.filter {
            !participantIDs.contains($0.key)
        }
        try await manager.reconcileParticipants(
            participantIDs.union(remainingProvisional.keys),
            quarantinedParticipantIDs: Set(remainingProvisional.keys)
        )
        committedParticipantIDs = participantIDs
        pairs = remainingProvisional
    }

    func abort(
        _ remoteParticipantID: ClipLiveShareNativeV3ParticipantID
    ) async {
        guard !isClosed, pairs.removeValue(
            forKey: remoteParticipantID
        ) != nil else { return }
        do {
            try await reconcile()
        } catch {
            callbacks?.reportFailure(error.localizedDescription)
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        pairs.removeAll(keepingCapacity: false)
        eventTask?.cancel()
        eventTask = nil
        do {
            try await manager.reconcileParticipants(
                committedParticipantIDs
            )
        } catch {
            callbacks?.reportFailure(error.localizedDescription)
        }
        callbacks = nil
    }

    private func startEventLoopIfNeeded() async {
        guard !didStartEventLoop, !isClosed else { return }
        didStartEventLoop = true
        let stream = await manager.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    private func handle(
        _ event: ClipLiveShareNativeV3MeshPeerLinkManagerEvent
    ) async {
        do {
            switch event {
            case let .targetedNegotiation(targeted):
                guard pairs[targeted.targetParticipantID] != nil else {
                    return
                }
                try await routeLocalNegotiation(targeted)

            case let .linkAdded(link), let .linkUpdated(link):
                guard var state = pairs[link.remoteParticipantID],
                      link.isReady,
                      !state.readinessReported,
                      let callbacks
                else { return }
                try await callbacks.markReady(
                    link.remoteParticipantID,
                    ClipLiveShareNativeTimestamp(date: now())
                )
                state.readinessReported = true
                pairs[link.remoteParticipantID] = state

            case let .linkFailed(_, participantID, message):
                guard pairs[participantID] != nil else { return }
                callbacks?.reportFailure(
                    "\(participantID.rawValue): \(message)"
                )

            case let .reconnectExhausted(_, participantID):
                guard pairs[participantID] != nil else { return }
                callbacks?.reportFailure(
                    String(
                        localized:
                            "The provisional connection to \(participantID.rawValue) could not be restored."
                    )
                )

            case .closed:
                isClosed = true
                pairs.removeAll(keepingCapacity: false)

            case .controlMessageReceived, .remoteVideoTrackAdded,
                 .remoteVideoTrackRemoved,
                 .remoteParticipantAudioAvailable,
                 .remoteParticipantAudioRemoved, .statisticsUpdated,
                 .linkRemoved, .negotiationNeeded, .reconnectScheduled:
                // Quarantined room control/media is intentionally not
                // delivered. Receiver state remains replayable in the manager
                // and becomes visible only after signed promotion.
                break
            }
        } catch {
            callbacks?.reportFailure(error.localizedDescription)
        }
    }

    private func routeLocalNegotiation(
        _ targeted: ClipLiveShareNativeV3TargetedNegotiation
    ) async throws {
        let participantID = targeted.targetParticipantID
        guard var state = pairs[participantID],
              let callbacks else {
            throw MeshParticipantProvisionalPeerLinkAdapterError
                .unknownPair(participantID)
        }
        let descriptor = state.descriptor
        let linkContext: ClipLiveShareNativeV3PeerLinkContext
        let payload: ClipLiveShareNativeV3BootstrapRelayPayload

        switch targeted.payload {
        case let .sessionDescription(description):
            switch description.kind {
            case .offer:
                let revision = try ClipLiveShareNativeV3PeerLinkRevision(
                    rawValue: state.negotiation.nextRevisionRawValue
                )
                state.negotiation.activeRevision = revision
                state.negotiation.nextRevisionRawValue &+= 1
                state.negotiation.nextOutgoingICESequence = 0
                state.negotiation.latestIncomingICESequence = nil
                linkContext = try makeContext(
                    descriptor,
                    revision: revision
                )
                let offer = try ClipLiveShareNativeV3PeerLinkOffer(
                    context: linkContext,
                    sdp: description.sdp
                )
                payload = .offer(
                    try ClipLiveShareSignedNativeV3PeerLinkOffer(
                        signing: offer,
                        with: localSigner,
                        senderIdentity: localSigner.publicKey
                    )
                )

            case .answer:
                guard let revision =
                    state.negotiation.activeRevision else {
                    throw MeshParticipantProvisionalPeerLinkAdapterError
                        .staleNegotiationRevision
                }
                linkContext = try makeContext(
                    descriptor,
                    revision: revision
                )
                let answer = try ClipLiveShareNativeV3PeerLinkAnswer(
                    context: linkContext,
                    sdp: description.sdp
                )
                payload = .answer(
                    try ClipLiveShareSignedNativeV3PeerLinkAnswer(
                        signing: answer,
                        with: localSigner,
                        senderIdentity: localSigner.publicKey
                    )
                )
            }

        case let .iceCandidate(candidate):
            guard let revision = state.negotiation.activeRevision else {
                throw MeshParticipantProvisionalPeerLinkAdapterError
                    .staleNegotiationRevision
            }
            linkContext = try makeContext(
                descriptor,
                revision: revision
            )
            let ice = try ClipLiveShareNativeV3PeerLinkICECandidate(
                context: linkContext,
                candidateSequence:
                    state.negotiation.nextOutgoingICESequence,
                candidate: candidate.candidate,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: Int(candidate.sdpMLineIndex)
            )
            state.negotiation.nextOutgoingICESequence &+= 1
            payload = .ice(
                try ClipLiveShareSignedNativeV3PeerLinkICECandidate(
                    signing: ice,
                    with: localSigner,
                    senderIdentity: localSigner.publicKey
                )
            )
        }
        pairs[participantID] = state
        try await callbacks.sendRelay(payload, participantID)
    }

    private func makeContext(
        _ descriptor: MeshParticipantBootstrapProvisionalPair,
        revision: ClipLiveShareNativeV3PeerLinkRevision
    ) throws -> ClipLiveShareNativeV3PeerLinkContext {
        try ClipLiveShareNativeV3PeerLinkContext(
            sessionID: descriptor.admission.admission.sessionID,
            membershipRevision:
                descriptor.admission.admission.candidateCredential
                    .credential.membershipRevision,
            peerLinkKey: ClipLiveShareNativeV3PeerLinkKey(
                localParticipantID,
                descriptor.remoteParticipantID
            ),
            negotiationRevision: revision,
            senderParticipantID: localParticipantID,
            receiverParticipantID: descriptor.remoteParticipantID,
            transportNonce: descriptor.transportNonce,
            provisionalAdmissionDigest: descriptor.admissionDigest
        )
    }

    private func validateIncoming(
        _ context: ClipLiveShareNativeV3PeerLinkContext,
        from participantID: ClipLiveShareNativeV3ParticipantID,
        state: PairState
    ) throws {
        guard
            context.senderParticipantID == participantID,
            context.receiverParticipantID == localParticipantID,
            context.peerLinkKey.participantIDs
                == Set([localParticipantID, participantID]),
            context.provisionalAdmissionDigest
                == state.descriptor.admissionDigest
        else {
            throw MeshParticipantProvisionalPeerLinkAdapterError.invalidPair
        }
    }

    private func validate(
        _ descriptor: MeshParticipantBootstrapProvisionalPair
    ) throws {
        let admission = descriptor.admission.admission
        let candidate = admission.candidateParticipantID
        let pairIDs = Set([
            descriptor.localParticipantID,
            descriptor.remoteParticipantID,
        ])
        let participants =
            admission.currentMembership.snapshot.participants
                + [admission.candidateCredential.credential.participant]
        guard
            descriptor.localParticipantID == localParticipantID,
            descriptor.remoteParticipantID != localParticipantID,
            descriptor.admissionDigest == admission.digest,
            pairIDs.contains(candidate),
            pairIDs.isSubset(of: Set(admission.proposedParticipantIDs)),
            pairIDs.subtracting([candidate]).allSatisfy(
                admission.currentMembership.snapshot.participantIDs.contains
            ),
            participants.first(where: {
                $0.participantID == localParticipantID
            })?.identity == localSigner.publicKey
        else {
            throw MeshParticipantProvisionalPeerLinkAdapterError.invalidPair
        }
    }

    private func sameAdmission(
        _ lhs: MeshParticipantBootstrapProvisionalPair,
        _ rhs: MeshParticipantBootstrapProvisionalPair
    ) -> Bool {
        lhs.localParticipantID == rhs.localParticipantID
            && lhs.remoteParticipantID == rhs.remoteParticipantID
            && lhs.transportNonce == rhs.transportNonce
            && lhs.admissionDigest == rhs.admissionDigest
            && lhs.admission == rhs.admission
    }

    private func reconcile() async throws {
        try await manager.reconcileParticipants(
            committedParticipantIDs.union(pairs.keys),
            quarantinedParticipantIDs: Set(pairs.keys)
        )
    }

    private func requireOpen() throws {
        guard !isClosed else {
            throw MeshParticipantProvisionalPeerLinkAdapterError.closed
        }
    }
}
