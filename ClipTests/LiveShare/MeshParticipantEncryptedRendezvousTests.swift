import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import Testing

@testable import Clip

@Suite("Native-v3 encrypted participant rendezvous")
struct MeshParticipantEncryptedRendezvousTests {
    @Test(
        "direct v3 invite opens one encrypted route and carries typed bootstrap both ways"
    )
    func encryptedBidirectionalBootstrap() async throws {
        let relay = MeshParticipantRendezvousTestRelay()
        let leaderSigner = ClipLiveShareSoftwareIdentitySigner()
        let sessionID = ClipLiveShareSessionID.random()
        let leaderID = ClipLiveShareNativeV3ParticipantID.random()
        let candidateID = ClipLiveShareNativeV3ParticipantID.random()
        let now = try ClipLiveShareNativeTimestamp(
            millisecondsSince1970: 1_800_000_000_000
        )

        let owner = try MeshParticipantEncryptedRendezvousOwner(
            endpoint: URL(string: "https://relay.example.test")!,
            sessionID: sessionID,
            foundingCreatorIdentity: leaderSigner.publicKey,
            leaderParticipantID: leaderID,
            leaderSigner: leaderSigner,
            accessWordRequired: true,
            transport: await relay.ownerTransport(),
            now: { now }
        )
        let candidateRendezvousIdentity = ClipLiveShareNativeV3RendezvousIdentity()
        let candidate = MeshParticipantEncryptedRendezvousCandidate(
            invite: await owner.invite,
            participantID: candidateID,
            candidateRendezvousIdentity: candidateRendezvousIdentity,
            transport: await relay.candidateTransport(),
            now: { now }
        )

        let ownerEvents = await owner.events()
        let candidateEvents = await candidate.events()
        let ownerReadyTask = Task {
            try await firstRendezvousEvent(in: ownerEvents) {
                if case .routeReady = $0 { return true }
                return false
            }
        }
        let candidateReadyTask = Task {
            try await firstRendezvousEvent(in: candidateEvents) {
                if case .routeReady = $0 { return true }
                return false
            }
        }

        try await owner.start()
        try await candidate.start()

        let ownerReady = try await ownerReadyTask.value
        let candidateReady = try await candidateReadyTask.value
        #expect(await candidate.accessWordRequired() == true)
        let proof: ClipLiveShareNativeV3RendezvousProof
        switch ownerReady {
        case let .routeReady(participantID, value):
            #expect(participantID == candidateID)
            proof = value
        default:
            Issue.record("Owner did not authenticate the candidate route")
            return
        }
        switch candidateReady {
        case let .routeReady(participantID, value):
            #expect(participantID == leaderID)
            #expect(value == proof)
        default:
            Issue.record("Candidate did not authenticate the leader route")
            return
        }

        let ownerToCandidate = ClipLiveShareNativeV3BootstrapEnvelope.rejected(
            .init(
                sessionID: sessionID,
                rendezvousProof: proof,
                reason: .busy
            )
        )
        let candidateEnvelopeTask = Task {
            try await firstRendezvousEvent(in: candidateEvents) {
                if case .envelope = $0 { return true }
                return false
            }
        }
        try await owner.send(ownerToCandidate, to: candidateID)
        switch try await candidateEnvelopeTask.value {
        case let .envelope(envelope, sender):
            #expect(sender == leaderID)
            #expect(envelope == ownerToCandidate)
        default:
            Issue.record("Candidate did not receive the typed bootstrap envelope")
        }

        let candidateToOwner = ClipLiveShareNativeV3BootstrapEnvelope.rejected(
            .init(
                sessionID: sessionID,
                rendezvousProof: proof,
                reason: .denied
            )
        )
        let ownerEnvelopeTask = Task {
            try await firstRendezvousEvent(in: ownerEvents) {
                if case .envelope = $0 { return true }
                return false
            }
        }
        try await candidate.send(candidateToOwner, to: leaderID)
        switch try await ownerEnvelopeTask.value {
        case let .envelope(envelope, sender):
            #expect(sender == candidateID)
            #expect(envelope == candidateToOwner)
        default:
            Issue.record("Leader did not receive the typed bootstrap envelope")
        }

        let transcript = await relay.transcript()
        #expect(transcript.candidateToOwner.count == 2)
        #expect(transcript.ownerToCandidate.count == 1)
        for packet in transcript.candidateToOwner + transcript.ownerToCandidate {
            #expect(packet.range(
                of: Data(candidateID.rawValue.utf8)
            ) == nil)
            #expect(packet.range(
                of: Data(leaderID.rawValue.utf8)
            ) == nil)
            #expect(packet.range(
                of: try JSONEncoder().encode(ownerToCandidate)
            ) == nil)
            #expect(packet.range(
                of: try JSONEncoder().encode(candidateToOwner)
            ) == nil)
        }

        await candidate.stop()
        await owner.stop()
    }
}

private actor MeshParticipantRendezvousTestRelay {
    struct Transcript: Sendable {
        let candidateToOwner: [Data]
        let ownerToCandidate: [Data]
    }

    private let routeID = ClipLiveShareRouteID.random().rawValue
    private var descriptor: Data?
    private var ownerContinuation:
        AsyncStream<ClipNativeRendezvousEvent>.Continuation?
    private var candidateContinuation:
        AsyncStream<ClipNativeRendezvousEvent>.Continuation?
    private var candidateToOwnerPackets: [Data] = []
    private var ownerToCandidatePackets: [Data] = []
    private var sequence: UInt64 = 0

    func ownerTransport() -> MeshParticipantRendezvousOwnerTransport {
        MeshParticipantRendezvousOwnerTransport(
            events: { [weak self] in
                guard let self else { return AsyncStream { $0.finish() } }
                return await self.makeOwnerEvents()
            },
            attach: { _ in },
            publish: { [weak self] descriptor in
                await self?.publish(descriptor)
            },
            send: { [weak self] payload, routeID in
                try await self?.sendFromOwner(payload, routeID: routeID)
            },
            closeRoute: { [weak self] routeID, reason in
                await self?.close(routeID: routeID, reason: reason)
            },
            teardown: { [weak self] _ in
                await self?.finish()
            }
        )
    }

    func candidateTransport() -> MeshParticipantRendezvousCandidateTransport {
        MeshParticipantRendezvousCandidateTransport(
            events: { [weak self] in
                guard let self else { return AsyncStream { $0.finish() } }
                return await self.makeCandidateEvents()
            },
            attach: { [weak self] _ in
                try await self?.attachCandidate()
            },
            send: { [weak self] payload in
                await self?.sendFromCandidate(payload)
            },
            closeRoute: { [weak self] reason in
                await self?.close(
                    routeID: self?.routeID,
                    reason: reason
                )
            },
            teardown: { [weak self] in
                await self?.finishCandidate()
            }
        )
    }

    func transcript() -> Transcript {
        Transcript(
            candidateToOwner: candidateToOwnerPackets,
            ownerToCandidate: ownerToCandidatePackets
        )
    }

    private func makeOwnerEvents()
        -> AsyncStream<ClipNativeRendezvousEvent> {
        let (stream, continuation) =
            AsyncStream.makeStream(of: ClipNativeRendezvousEvent.self)
        ownerContinuation = continuation
        return stream
    }

    private func makeCandidateEvents()
        -> AsyncStream<ClipNativeRendezvousEvent> {
        let (stream, continuation) =
            AsyncStream.makeStream(of: ClipNativeRendezvousEvent.self)
        candidateContinuation = continuation
        return stream
    }

    private func publish(_ descriptor: Data) {
        self.descriptor = descriptor
    }

    private func attachCandidate() throws {
        guard let descriptor else {
            throw MeshParticipantEncryptedRendezvousError.descriptorRejected
        }
        ownerContinuation?.yield(
            .routeOpened(routeID: routeID, descriptor: nil)
        )
        candidateContinuation?.yield(
            .routeOpened(routeID: routeID, descriptor: descriptor)
        )
    }

    private func sendFromCandidate(_ payload: Data) {
        candidateToOwnerPackets.append(payload)
        sequence &+= 1
        ownerContinuation?.yield(
            .relay(
                routeID: routeID,
                payload: payload,
                sequence: sequence
            )
        )
    }

    private func sendFromOwner(
        _ payload: Data,
        routeID: String
    ) throws {
        guard routeID == self.routeID else {
            throw MeshParticipantEncryptedRendezvousError.invalidRoute
        }
        ownerToCandidatePackets.append(payload)
        sequence &+= 1
        candidateContinuation?.yield(
            .relay(
                routeID: routeID,
                payload: payload,
                sequence: sequence
            )
        )
    }

    private func close(routeID: String?, reason: String?) {
        guard let routeID, routeID == self.routeID else { return }
        ownerContinuation?.yield(
            .routeClosed(routeID: routeID, reason: reason)
        )
        candidateContinuation?.yield(
            .routeClosed(routeID: routeID, reason: reason)
        )
    }

    private func finishCandidate() {
        candidateContinuation?.yield(.stopped)
        candidateContinuation?.finish()
        candidateContinuation = nil
    }

    private func finish() {
        ownerContinuation?.yield(.stopped)
        ownerContinuation?.finish()
        candidateContinuation?.yield(.stopped)
        candidateContinuation?.finish()
        ownerContinuation = nil
        candidateContinuation = nil
    }
}

private func firstRendezvousEvent(
    in stream: AsyncStream<MeshParticipantEncryptedRendezvousEvent>,
    matching predicate: @escaping @Sendable (
        MeshParticipantEncryptedRendezvousEvent
    ) -> Bool
) async throws -> MeshParticipantEncryptedRendezvousEvent {
    try await withThrowingTaskGroup(
        of: MeshParticipantEncryptedRendezvousEvent.self
    ) { group in
        group.addTask {
            for await event in stream where predicate(event) {
                return event
            }
            throw CancellationError()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw CancellationError()
        }
        let event = try await group.next()!
        group.cancelAll()
        return event
    }
}
