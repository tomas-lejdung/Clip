import ClipLiveShare
import Foundation

enum MeshRoomFriendshipState: Equatable, Sendable {
    case available
    case incomingRequest
    case requestPending
    case trusted
    case failed(message: String)
}

struct MeshRoomPendingFriendRequestSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let participantID: String
    let displayName: String
    let deviceName: String?
}

struct MeshFriendshipHandshakeSnapshot: Equatable, Sendable {
    var stateByParticipantID:
        [ClipLiveShareNativeV3ParticipantID: MeshRoomFriendshipState] = [:]
    var pendingRequests: [MeshRoomPendingFriendRequestSnapshot] = []
    var notice: String?
}

struct MeshFriendshipRemoteParticipantContext: Equatable, Sendable {
    let participantID: ClipLiveShareNativeV3ParticipantID
    let identity: ClipLiveShareIdentityPublicKey
    let displayName: String
    let deviceName: String?
    let isConnected: Bool
}

struct MeshFriendshipRoomContext: Equatable, Sendable {
    let roomID: ClipLiveShareServerRoomV4RoomID
    let sessionID: ClipLiveShareSessionID
    let localParticipantID: ClipLiveShareNativeV3ParticipantID
    let remotes: [MeshFriendshipRemoteParticipantContext]
}

struct MeshFriendshipHandshakeDependencies: Sendable {
    let signer: any ClipLiveShareIdentitySigner
    let repository: MeshFriendshipRepository
    let presenceServiceEndpoint: ClipLiveShareRendezvousEndpoint
}

/// Participant-owned four-step friendship handshake.
///
/// Every transition is durably journaled before its signed message crosses
/// the reliable pair DataChannel. A duplicate message or recovered pair
/// resends the exact cached signed response rather than creating a second
/// request, new mailbox, or new signature.
@MainActor
final class MeshFriendshipHandshakeController {
    typealias SendMessage = @MainActor @Sendable (
        ClipLiveShareServerRoomV4SignedFriendMessage,
        ClipLiveShareNativeV3ParticipantID
    ) async throws -> Void

    private let localDisplayName: String
    private let localDeviceName: String
    private let dependencies: MeshFriendshipHandshakeDependencies
    private let sendMessage: SendMessage
    private let now: @Sendable () -> Date
    private let onSnapshotChanged: @MainActor (
        MeshFriendshipHandshakeSnapshot
    ) -> Void

    private var context: MeshFriendshipRoomContext?
    private var failures:
        [ClipLiveShareNativeV3ParticipantID: String] = [:]
    private var notice: String?
    private var noticeClearTask: Task<Void, Never>?
    private var hasPrunedRecovery = false
    private(set) var snapshot = MeshFriendshipHandshakeSnapshot()

    init(
        localDisplayName: String,
        localDeviceName: String?,
        dependencies: MeshFriendshipHandshakeDependencies,
        now: @escaping @Sendable () -> Date = Date.init,
        sendMessage: @escaping SendMessage,
        onSnapshotChanged: @escaping @MainActor (
            MeshFriendshipHandshakeSnapshot
        ) -> Void = { _ in }
    ) {
        self.localDisplayName = localDisplayName
        self.localDeviceName = localDeviceName ?? localDisplayName
        self.dependencies = dependencies
        self.now = now
        self.sendMessage = sendMessage
        self.onSnapshotChanged = onSnapshotChanged
    }

    func updateRoom(_ context: MeshFriendshipRoomContext?) async {
        self.context = context
        if context == nil {
            noticeClearTask?.cancel()
            noticeClearTask = nil
            notice = nil
        }
        if !hasPrunedRecovery {
            hasPrunedRecovery = true
            _ = try? await dependencies.repository.pruneExpiredRecovery()
        }
        await refreshSnapshot()
    }

    func addFriend(
        participantID: ClipLiveShareNativeV3ParticipantID
    ) async {
        guard let context,
              let remote = remote(participantID, in: context),
              remote.isConnected,
              snapshot.stateByParticipantID[participantID] != .trusted,
              snapshot.stateByParticipantID[participantID]
                != .incomingRequest else { return }
        clearNotice()
        do {
            if let cached = try await locallyAuthoredMessage(
                for: participantID,
                in: context
            ) {
                try await send(cached, to: participantID)
                return
            }

            let timestamp = try ClipLiveShareNativeTimestamp(date: now())
            let locator = await dependencies.repository
                .makeLocalPublishingLocator()
            let profile = try localProfile(locator: locator)
            let request = try ClipLiveShareServerRoomV4FriendRequest(
                roomID: context.roomID,
                sessionID: context.sessionID,
                requesterParticipantID: context.localParticipantID,
                accepterParticipantID: participantID,
                requester: profile,
                expectedAccepterFingerprint: remote.identity.fingerprint,
                issuedAt: timestamp,
                expiresAt: try timestamp.adding(
                    milliseconds: ClipLiveShareServerRoomV4Friends
                        .maximumHandshakeLifetimeMilliseconds
                )
            )
            let signed = try ClipLiveShareServerRoomV4SignedFriendMessage(
                signing: .request(request),
                with: dependencies.signer
            )
            try await dependencies.repository.recordOutgoingRequest(signed)
            failures[participantID] = nil
            await refreshSnapshot()
            try await send(signed, to: participantID)
        } catch {
            await record(error, for: participantID)
        }
    }

    func allow(
        requestID rawRequestID: String
    ) async {
        guard let requestID = try? ClipLiveShareServerRoomV4FriendRequestID(
            rawValue: rawRequestID
        ), let context,
              let pendingParticipantID = snapshot.pendingRequests
                .first(where: { $0.id == rawRequestID })
                .flatMap({
                    try? ClipLiveShareNativeV3ParticipantID(
                        rawValue: $0.participantID
                    )
                }) else { return }
        do {
            let journal = try await dependencies.repository.snapshot()
                .recoveryJournal
            guard let entry = journal.first(where: {
                $0.requestID == requestID && $0.role == .accepter
            }), case let .request(request) = entry.signedRequest.message,
                  request.roomID == context.roomID,
                  request.sessionID == context.sessionID,
                  request.accepterParticipantID == context.localParticipantID,
                  remote(request.requesterParticipantID, in: context) != nil
            else { return }

            if let cached = try await dependencies.repository
                .recoverableReply(for: requestID) {
                try await send(cached, to: request.requesterParticipantID)
                return
            }

            let locator = await dependencies.repository
                .makeLocalPublishingLocator()
            let acceptance = try ClipLiveShareServerRoomV4FriendAcceptance(
                accepting: request,
                accepter: try localProfile(locator: locator),
                acceptedAt: try ClipLiveShareNativeTimestamp(date: now())
            )
            let signed = try ClipLiveShareServerRoomV4SignedFriendMessage(
                signing: .acceptance(acceptance),
                with: dependencies.signer
            )
            try await dependencies.repository.recordAcceptance(
                signed,
                requestID: requestID
            )
            failures[request.requesterParticipantID] = nil
            await refreshSnapshot()
            try await send(signed, to: request.requesterParticipantID)
        } catch {
            await record(error, for: pendingParticipantID)
        }
    }

    func deny(requestID rawRequestID: String) async {
        guard let requestID = try? ClipLiveShareServerRoomV4FriendRequestID(
            rawValue: rawRequestID
        ), let context,
           let participantID = snapshot.pendingRequests
            .first(where: { $0.id == rawRequestID })
            .flatMap({
                try? ClipLiveShareNativeV3ParticipantID(
                    rawValue: $0.participantID
                )
            }) else { return }
        do {
            let journal = try await dependencies.repository.snapshot()
                .recoveryJournal
            guard let entry = journal.first(where: {
                $0.requestID == requestID && $0.role == .accepter
            }), case let .request(request) = entry.signedRequest.message,
                  request.roomID == context.roomID,
                  request.sessionID == context.sessionID,
                  request.accepterParticipantID == context.localParticipantID,
                  request.requesterParticipantID == participantID else {
                return
            }
            if let cached = entry.signedDecline {
                try await send(cached, to: participantID)
                return
            }
            let decline = try ClipLiveShareServerRoomV4FriendDecline(
                declining: request,
                accepterIdentity: dependencies.signer.publicKey,
                declinedAt: try ClipLiveShareNativeTimestamp(date: now())
            )
            let signed = try ClipLiveShareServerRoomV4SignedFriendMessage(
                signing: .decline(decline),
                with: dependencies.signer
            )
            try await dependencies.repository.recordOutgoingDecline(
                signed,
                requestID: requestID
            )
            failures[participantID] = nil
            await refreshSnapshot()
            try await send(signed, to: participantID)
        } catch {
            await record(error, for: participantID)
        }
    }

    func retry(
        participantID: ClipLiveShareNativeV3ParticipantID
    ) async {
        guard let context,
              remote(participantID, in: context)?.isConnected == true else {
            return
        }
        do {
            guard let message = try await locallyAuthoredMessage(
                for: participantID,
                in: context
            ) else { return }
            try await send(message, to: participantID)
        } catch {
            await record(error, for: participantID)
        }
    }

    func handle(
        _ signedMessage: ClipLiveShareServerRoomV4SignedFriendMessage,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async {
        guard let context,
              signedMessage.message.authorParticipantID == participantID,
              signedMessage.message.recipientParticipantID
                == context.localParticipantID,
              signedMessage.message.roomID == context.roomID,
              signedMessage.message.sessionID == context.sessionID,
              remote(participantID, in: context) != nil else { return }
        do {
            switch signedMessage.message {
            case .request:
                try await receiveRequest(signedMessage, from: participantID)
            case .acceptance:
                try await receiveAcceptance(signedMessage, from: participantID)
            case .decline:
                try await receiveDecline(
                    signedMessage,
                    from: participantID,
                    in: context
                )
            case .acknowledgement:
                try await receiveAcknowledgement(
                    signedMessage,
                    from: participantID
                )
            case .commitReceipt:
                try await dependencies.repository.commitOutgoingFriendship(
                    receipt: signedMessage,
                    requestID: signedMessage.message.requestID
                )
            }
            failures[participantID] = nil
            await refreshSnapshot()
        } catch let error as MeshFriendshipRepositoryError
            where error == .replayedRequest
        {
            // An explicitly denied request stays denied. Silently discard its
            // exact or conflicting replay instead of recreating a prompt.
            return
        } catch {
            await record(error, for: participantID)
        }
    }

    private func receiveRequest(
        _ message: ClipLiveShareServerRoomV4SignedFriendMessage,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await dependencies.repository.recordIncomingRequest(message)
        if let cached = try await dependencies.repository.recoverableReply(
            for: message.message.requestID
        ) {
            try await send(cached, to: participantID)
        }
    }

    private func receiveAcceptance(
        _ signedAcceptance: ClipLiveShareServerRoomV4SignedFriendMessage,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        let requestID = signedAcceptance.message.requestID
        if let cached = try await dependencies.repository.recoverableReply(
            for: requestID
        ) {
            try await send(cached, to: participantID)
            return
        }
        let journal = try await dependencies.repository.snapshot()
            .recoveryJournal
        guard let entry = journal.first(where: {
            $0.requestID == requestID && $0.role == .requester
        }), case let .request(request) = entry.signedRequest.message,
              case let .acceptance(acceptance) = signedAcceptance.message else {
            throw MeshFriendshipRepositoryError.missingHandshake
        }
        let acknowledgement = try
            ClipLiveShareServerRoomV4FriendAcknowledgement(
                acknowledging: acceptance,
                request: request,
                acknowledgedAt: try ClipLiveShareNativeTimestamp(date: now())
            )
        let signed = try ClipLiveShareServerRoomV4SignedFriendMessage(
            signing: .acknowledgement(acknowledgement),
            with: dependencies.signer
        )
        try await dependencies.repository.stageOutgoingAcknowledgement(
            signed,
            acceptance: signedAcceptance,
            requestID: requestID
        )
        await refreshSnapshot()
        try await send(signed, to: participantID)
    }

    private func receiveDecline(
        _ signedDecline: ClipLiveShareServerRoomV4SignedFriendMessage,
        from participantID: ClipLiveShareNativeV3ParticipantID,
        in context: MeshFriendshipRoomContext
    ) async throws {
        try await dependencies.repository.recordIncomingDecline(
            signedDecline,
            requestID: signedDecline.message.requestID
        )
        let name = remote(participantID, in: context)?.displayName
            ?? String(localized: "Participant")
        showNotice(String(localized: "\(name) declined your friend request."))
    }

    private func receiveAcknowledgement(
        _ signedAcknowledgement: ClipLiveShareServerRoomV4SignedFriendMessage,
        from participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        let requestID = signedAcknowledgement.message.requestID
        // An accepter's ordinary recoverable reply is its acceptance until
        // the commit exists. Receiving the acknowledgement is precisely what
        // advances that state, so only a previously committed receipt may
        // short-circuit this handler. Returning the cached acceptance here
        // would strand both peers in `requestPending` forever.
        let journal = try await dependencies.repository.snapshot()
            .recoveryJournal
        if let receipt = journal.first(where: {
            $0.requestID == requestID && $0.role == .accepter
        })?.signedCommitReceipt {
            try await send(receipt, to: participantID)
            return
        }
        guard case let .acknowledgement(acknowledgement) =
                signedAcknowledgement.message else {
            throw MeshFriendshipRepositoryError.invalidHandshake
        }
        let receipt = try ClipLiveShareServerRoomV4FriendCommitReceipt(
            committing: acknowledgement,
            committedAt: try ClipLiveShareNativeTimestamp(date: now())
        )
        let signed = try ClipLiveShareServerRoomV4SignedFriendMessage(
            signing: .commitReceipt(receipt),
            with: dependencies.signer
        )
        try await dependencies.repository.commitIncomingFriendship(
            receipt: signed,
            acknowledgement: signedAcknowledgement,
            requestID: requestID
        )
        await refreshSnapshot()
        try await send(signed, to: participantID)
    }

    private func locallyAuthoredMessage(
        for participantID: ClipLiveShareNativeV3ParticipantID,
        in context: MeshFriendshipRoomContext
    ) async throws -> ClipLiveShareServerRoomV4SignedFriendMessage? {
        let journal = try await dependencies.repository.snapshot()
            .recoveryJournal
        guard let entry = journal.last(where: { entry in
            guard case let .request(request) = entry.signedRequest.message,
                  request.roomID == context.roomID,
                  request.sessionID == context.sessionID else { return false }
            return switch entry.role {
            case .requester:
                request.requesterParticipantID == context.localParticipantID
                    && request.accepterParticipantID == participantID
            case .accepter:
                request.accepterParticipantID == context.localParticipantID
                    && request.requesterParticipantID == participantID
            }
        }) else { return nil }
        switch entry.role {
        case .requester:
            guard entry.signedDecline == nil else { return nil }
            return entry.signedAcknowledgement ?? entry.signedRequest
        case .accepter:
            return entry.signedCommitReceipt ?? entry.signedAcceptance
        }
    }

    private func refreshSnapshot() async {
        guard let context else {
            snapshot = .init()
            onSnapshotChanged(snapshot)
            return
        }
        do {
            let stored = try await dependencies.repository.snapshot()
            var state = Dictionary(
                uniqueKeysWithValues: context.remotes.map {
                    ($0.participantID, MeshRoomFriendshipState.available)
                }
            )
            for remote in context.remotes {
                if stored.friends.contains(where: {
                    $0.identity == remote.identity && $0.trustState == .trusted
                }) {
                    state[remote.participantID] = .trusted
                }
            }

            var pending: [MeshRoomPendingFriendRequestSnapshot] = []
            for entry in stored.recoveryJournal {
                guard case let .request(request) = entry.signedRequest.message,
                      request.roomID == context.roomID,
                      request.sessionID == context.sessionID else { continue }
                let remoteID: ClipLiveShareNativeV3ParticipantID
                switch entry.role {
                case .requester:
                    guard request.requesterParticipantID
                            == context.localParticipantID else { continue }
                    remoteID = request.accepterParticipantID
                    guard entry.signedDecline == nil else { continue }
                    if state[remoteID] != .trusted {
                        state[remoteID] = .requestPending
                    }
                case .accepter:
                    guard request.accepterParticipantID
                            == context.localParticipantID else { continue }
                    remoteID = request.requesterParticipantID
                    guard entry.signedDecline == nil else { continue }
                    if state[remoteID] != .trusted {
                        if entry.signedAcceptance == nil {
                            state[remoteID] = .incomingRequest
                            pending.append(.init(
                                id: request.requestID.rawValue,
                                participantID: remoteID.rawValue,
                                displayName: request.requester.displayName,
                                deviceName: request.requester.deviceName
                            ))
                        } else {
                            state[remoteID] = .requestPending
                        }
                    }
                }
            }
            for (participantID, message) in failures
                where state[participantID] != .trusted {
                state[participantID] = .failed(message: message)
            }
            snapshot = .init(
                stateByParticipantID: state,
                pendingRequests: pending.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare(
                        $1.displayName
                    ) == .orderedAscending
                },
                notice: notice
            )
            onSnapshotChanged(snapshot)
        } catch {
            let message = error.localizedDescription
            snapshot = .init(
                stateByParticipantID: Dictionary(
                    uniqueKeysWithValues: context.remotes.map {
                        ($0.participantID, .failed(message: message))
                    }
                ),
                notice: notice
            )
            onSnapshotChanged(snapshot)
        }
    }

    private func localProfile(
        locator: ClipLiveShareServerRoomV4FriendLocator
    ) throws -> ClipLiveShareServerRoomV4FriendProfile {
        try .init(
            identity: dependencies.signer.publicKey,
            displayName: localDisplayName,
            deviceName: localDeviceName,
            presenceServiceEndpoint: dependencies.presenceServiceEndpoint,
            locator: locator
        )
    }

    private func remote(
        _ participantID: ClipLiveShareNativeV3ParticipantID,
        in context: MeshFriendshipRoomContext
    ) -> MeshFriendshipRemoteParticipantContext? {
        context.remotes.first { $0.participantID == participantID }
    }

    private func send(
        _ message: ClipLiveShareServerRoomV4SignedFriendMessage,
        to participantID: ClipLiveShareNativeV3ParticipantID
    ) async throws {
        try await sendMessage(message, participantID)
        failures[participantID] = nil
        await refreshSnapshot()
    }

    private func record(
        _ error: any Error,
        for participantID: ClipLiveShareNativeV3ParticipantID
    ) async {
        failures[participantID] = error.localizedDescription
        await refreshSnapshot()
    }

    private func clearNotice() {
        noticeClearTask?.cancel()
        noticeClearTask = nil
        notice = nil
    }

    private func showNotice(_ message: String) {
        clearNotice()
        notice = message
        noticeClearTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self else { return }
            notice = nil
            noticeClearTask = nil
            await refreshSnapshot()
        }
    }
}
