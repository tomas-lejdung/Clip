import AppKit
import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import OSLog

enum NativeV3MeshAcceptanceReporterError: Error, LocalizedError {
    case unsafeRunDirectory
    case unsafeReportDestination
    case unsafeTerminationRequest

    var errorDescription: String? {
        switch self {
        case .unsafeRunDirectory:
            "The native-v3 acceptance run directory is not a private, regular directory."
        case .unsafeReportDestination:
            "The native-v3 acceptance report destination is unsafe."
        case .unsafeTerminationRequest:
            "The native-v3 acceptance termination request is unsafe."
        }
    }
}

enum NativeV3MeshAcceptanceReadyEvidencePolicy {
    static func shouldReplace(
        currentMemberCount: Int?,
        membershipMatchesCurrent: Bool,
        incomingMemberCount: Int,
        localSourceCount: Int,
        remoteSourceCounts: [Int],
        transportIsReady: Bool
    ) -> Bool {
        guard
            transportIsReady,
            localSourceCount >= 1,
            remoteSourceCounts.allSatisfy({ $0 >= 1 })
        else {
            return false
        }
        guard let currentMemberCount else { return true }
        return incomingMemberCount > currentMemberCount
            || membershipMatchesCurrent
    }
}

/// App-integrated evidence writer for the owner-approved native-v3
/// multi-process acceptance lane.
///
/// This diagnostic deliberately observes the production coordinator instead
/// of constructing a parallel mesh. Each report is signed by the process's
/// persistent participant identity and embeds the exact leader-signed
/// membership committed by that process. The launcher can therefore prove
/// that independently launched apps agreed on one room and one full peer/media
/// topology, rather than merely proving that several app processes opened.
///
/// Normal Clip launches never construct this type. Launch-flag validation,
/// private directory validation, stable code-signing checks in the launcher,
/// and the explicit multi-instance acknowledgement all fail closed.
@MainActor
final class NativeV3MeshAcceptanceReporter {
    private struct ReadyEvidence {
        let roomName: String
        let participantID: ClipLiveShareNativeV3ParticipantID
        let signedMembership:
            ClipLiveShareSignedNativeV3MembershipSnapshot
        let leadershipTerm: ClipLiveShareNativeV3LeadershipTerm
        let peerLinks:
            [ClipLiveShareNativeV3AcceptanceReportPayload.PeerLink]
        let localSourceCount: Int
        let localAudioTrackCount: Int
        let remoteMedia:
            [ClipLiveShareNativeV3AcceptanceReportPayload.RemoteMedia]
        let failures: [String]
    }

    nonisolated private static let logger = Logger(
        subsystem: ApplicationDirectories.bundleIdentifier,
        category: "native-v3-mesh-acceptance-report"
    )

    private let request: NativeV3MeshAcceptanceReportingRequest
    private let reportURL: URL
    private var terminationWatcher: Task<Void, Never>?
    private var readyEvidence: ReadyEvidence?

    init(
        request: NativeV3MeshAcceptanceReportingRequest,
        fileManager: FileManager = .default
    ) throws {
        try Self.validatePrivateDirectory(
            request.runDirectory,
            fileManager: fileManager
        )
        try Self.validatePrivateDirectory(
            request.reportsDirectory,
            fileManager: fileManager
        )
        try Self.validatePrivateDirectory(
            request.terminationRequestURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        self.request = request
        reportURL = request.reportsDirectory.appendingPathComponent(
            "\(request.processLabel).report.json",
            isDirectory: false
        )
        if fileManager.fileExists(atPath: reportURL.path) {
            let values = try reportURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else {
                throw NativeV3MeshAcceptanceReporterError
                    .unsafeReportDestination
            }
        }
    }

    func startTerminationWatcher(
        requestTermination: @escaping @MainActor () -> Void
    ) {
        guard terminationWatcher == nil else { return }
        terminationWatcher = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if FileManager.default.fileExists(
                    atPath: request.terminationRequestURL.path
                ) {
                    do {
                        try validateTerminationRequest()
                        terminationWatcher = nil
                        requestTermination()
                        return
                    } catch {
                        Self.logger.error(
                            "Rejected unsafe native-v3 termination request: \(error.localizedDescription, privacy: .public)"
                        )
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stopTerminationWatcher() {
        terminationWatcher?.cancel()
        terminationWatcher = nil
    }

    func record(
        roomName: String,
        phase: MeshRoomPhase,
        localParticipantID: ClipLiveShareNativeV3ParticipantID,
        localIdentitySigner: any ClipLiveShareIdentitySigner,
        signedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
        leadershipTerm: ClipLiveShareNativeV3LeadershipTerm,
        runtimeSnapshot: MeshParticipantRuntimeSnapshot?,
        localSystemAudioTrackIsEnabled: Bool,
        statusNotice: MeshRoomStatusNoticeSnapshot?
    ) {
        do {
            let report = try makeReport(
                roomName: roomName,
                phase: phase,
                localParticipantID: localParticipantID,
                localIdentitySigner: localIdentitySigner,
                signedMembership: signedMembership,
                leadershipTerm: leadershipTerm,
                runtimeSnapshot: runtimeSnapshot,
                localSystemAudioTrackIsEnabled:
                    localSystemAudioTrackIsEnabled,
                statusNotice: statusNotice
            )
            try write(report)
        } catch {
            Self.logger.error(
                "Could not write native-v3 acceptance report: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func makeReport(
        roomName: String,
        phase: MeshRoomPhase,
        localParticipantID: ClipLiveShareNativeV3ParticipantID,
        localIdentitySigner: any ClipLiveShareIdentitySigner,
        signedMembership: ClipLiveShareSignedNativeV3MembershipSnapshot,
        leadershipTerm: ClipLiveShareNativeV3LeadershipTerm,
        runtimeSnapshot: MeshParticipantRuntimeSnapshot?,
        localSystemAudioTrackIsEnabled: Bool,
        statusNotice: MeshRoomStatusNoticeSnapshot?
    ) throws -> ClipLiveShareSignedNativeV3AcceptanceReport {
        if case .ended = phase, let readyEvidence {
            let payload = try makePayload(
                evidence: readyEvidence,
                phase: .ended,
                hadReachedReady: true,
                cleanTeardown: true
            )
            return try ClipLiveShareSignedNativeV3AcceptanceReport(
                signing: payload,
                with: localIdentitySigner
            )
        }

        let membership = signedMembership.snapshot
        let remoteParticipantIDs = membership.participantIDs.subtracting([
            localParticipantID
        ])
        let linksByParticipant = Dictionary(
            uniqueKeysWithValues: (runtimeSnapshot?.links.links ?? []).map {
                ($0.remoteParticipantID, $0)
            }
        )
        let peerLinks = remoteParticipantIDs.sorted().map { participantID in
            let link = linksByParticipant[participantID]
            return ClipLiveShareNativeV3AcceptanceReportPayload.PeerLink(
                remoteParticipantID: participantID,
                connectionState: Self.connectionState(
                    link?.connectionState
                ),
                isReady: link?.isReady == true,
                route: Self.route(
                    connectionState: link?.connectionState,
                    route: link?.route
                )
            )
        }
        let remoteMedia = try remoteParticipantIDs.sorted().map {
            participantID in
            try ClipLiveShareNativeV3AcceptanceReportPayload.RemoteMedia(
                participantID: participantID,
                sourceCount:
                    runtimeSnapshot?.sourceSnapshots[participantID]?
                        .sources.count ?? 0,
                audioTrackCount:
                    runtimeSnapshot?.audioTrackIDs[participantID] == nil
                    ? 0 : 1
            )
        }
        let failures = Self.failures(
            phase: phase,
            statusNotice: statusNotice
        )
        let evidence = ReadyEvidence(
            roomName: roomName,
            participantID: localParticipantID,
            signedMembership: signedMembership,
            leadershipTerm: leadershipTerm,
            peerLinks: peerLinks,
            localSourceCount:
                runtimeSnapshot?.sourceSnapshots[localParticipantID]?
                    .sources.count ?? 0,
            localAudioTrackCount: localSystemAudioTrackIsEnabled ? 1 : 0,
            remoteMedia: remoteMedia,
            failures: failures
        )
        let reachedReady =
            Self.phase(phase) == .live
            && runtimeSnapshot?.isLocallyComplete == true
            && failures.isEmpty
        let currentReadyEvidence = readyEvidence
        if NativeV3MeshAcceptanceReadyEvidencePolicy.shouldReplace(
            currentMemberCount:
                currentReadyEvidence?.signedMembership.snapshot
                    .participants.count,
            membershipMatchesCurrent:
                currentReadyEvidence?.signedMembership == signedMembership,
            incomingMemberCount: membership.participants.count,
            localSourceCount: evidence.localSourceCount,
            remoteSourceCounts:
                evidence.remoteMedia.map(\.sourceCount),
            transportIsReady: reachedReady
        ) {
            // Grow through sequential admission, then freeze the membership
            // once the complete published room has been observed. Graceful
            // simultaneous shutdown can produce smaller or same-sized bridge
            // memberships at different processes; those must not replace the
            // one common topology that the ready-stage validator proved.
            readyEvidence = evidence
        }
        let payload = try makePayload(
            evidence: evidence,
            phase: Self.phase(phase),
            hadReachedReady: reachedReady || readyEvidence != nil,
            cleanTeardown: false
        )
        return try ClipLiveShareSignedNativeV3AcceptanceReport(
            signing: payload,
            with: localIdentitySigner
        )
    }

    private func makePayload(
        evidence: ReadyEvidence,
        phase: ClipLiveShareNativeV3AcceptanceReportPayload.Phase,
        hadReachedReady: Bool,
        cleanTeardown: Bool
    ) throws -> ClipLiveShareNativeV3AcceptanceReportPayload {
        try ClipLiveShareNativeV3AcceptanceReportPayload(
            runIdentifier: request.runIdentifier,
            processLabel: request.processLabel,
            reportedAt: ClipLiveShareNativeTimestamp(date: Date()),
            roomName: evidence.roomName,
            participantID: evidence.participantID,
            signedMembership: evidence.signedMembership,
            leadershipTerm: evidence.leadershipTerm,
            phase: phase,
            peerLinks: evidence.peerLinks,
            localSourceCount: evidence.localSourceCount,
            localAudioTrackCount: evidence.localAudioTrackCount,
            remoteMedia: evidence.remoteMedia,
            hadReachedReady: hadReachedReady,
            failures: evidence.failures,
            cleanTeardown: cleanTeardown
        )
    }

    private func write(
        _ report: ClipLiveShareSignedNativeV3AcceptanceReport,
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: reportURL.path) {
            let values = try reportURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else {
                throw NativeV3MeshAcceptanceReporterError
                    .unsafeReportDestination
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: reportURL.path
        )
    }

    private func validateTerminationRequest(
        fileManager: FileManager = .default
    ) throws {
        let values = try request.terminationRequestURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        let attributes = try fileManager.attributesOfItem(
            atPath: request.terminationRequestURL.path
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            values.fileSize == 0,
            (attributes[.posixPermissions] as? NSNumber)
                .map({ $0.intValue & 0o077 == 0 }) == true
        else {
            throw NativeV3MeshAcceptanceReporterError
                .unsafeTerminationRequest
        }
    }

    private static func validatePrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard
            values.isDirectory == true,
            values.isSymbolicLink != true,
            (attributes[.posixPermissions] as? NSNumber)
                .map({ $0.intValue & 0o077 == 0 }) == true
        else {
            throw NativeV3MeshAcceptanceReporterError.unsafeRunDirectory
        }
    }

    private static func failures(
        phase: MeshRoomPhase,
        statusNotice: MeshRoomStatusNoticeSnapshot?
    ) -> [String] {
        var messages: [String] = []
        if case let .failed(message) = phase {
            messages.append(message)
        }
        if let statusNotice {
            messages.append(
                "\(statusNotice.title): \(statusNotice.message)"
            )
        }
        return Array(Set(messages)).sorted()
    }

    private static func phase(
        _ phase: MeshRoomPhase
    ) -> ClipLiveShareNativeV3AcceptanceReportPayload.Phase {
        switch phase {
        case .connecting:
            .connecting
        case .live:
            .live
        case .reconnecting:
            .reconnecting
        case .electingCreator:
            .electingLeader
        case .leaderlessLocked:
            .leaderlessLocked
        case .ending:
            .ending
        case .ended:
            .ended
        case .failed:
            .failed
        }
    }

    private static func connectionState(
        _ state: WebRTCPeerConnectionState?
    ) -> ClipLiveShareNativeV3AcceptanceReportPayload.PeerConnectionState {
        switch state {
        case .new, nil:
            .new
        case .connecting:
            .connecting
        case .connected:
            .connected
        case .disconnected:
            .disconnected
        case .failed:
            .failed
        case .closed:
            .closed
        }
    }

    private static func route(
        connectionState: WebRTCPeerConnectionState?,
        route: WebRTCConnectionRoute?
    ) -> ClipLiveShareNativeV3AcceptanceReportPayload.PeerRoute {
        guard connectionState == .connected else {
            return connectionState == nil ? .unknown : .disconnected
        }
        switch route {
        case .direct:
            return .direct
        case .relay:
            return .relay
        case .unknown, nil:
            return .unknown
        }
    }
}
