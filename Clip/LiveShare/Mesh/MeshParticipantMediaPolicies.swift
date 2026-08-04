import ClipLiveShare
import ClipLiveShareWebRTC

/// Converts persisted settings into the unchanged pre-v4 WebRTC types. The
/// server-coordinated room owns topology only; it must not introduce a second
/// capture, quality, or encoder policy.
enum MeshParticipantMediaSettingsPolicy {
    /// Applies the persisted participant media contract before the first peer
    /// link is created. Starting from `WebRTCPeerConfiguration.clipDefault`
    /// without this conversion silently negotiates H.264 while the popover
    /// presents the participant's selected codec.
    static func peerConfiguration(
        _ base: WebRTCPeerConfiguration,
        settings: LiveShareSettings
    ) -> WebRTCPeerConfiguration {
        var configuration = base
        configuration.senderPolicy = LiveShareCapturePolicy.senderPolicy(
            for: settings
        )
        configuration.videoCodec = videoCodec(settings.videoCodec)
        configuration.videoEncodingMode = settings.encodingMode

        if case let .h264(h264) = advancedVideoConfiguration(
            settings.advancedVideoSettings.settings(for: .h264),
            codec: .h264
        ) {
            configuration.advancedVideoConfigurations.h264 = h264
        }
        return configuration
    }

    static func videoCodec(
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

    static func liveShareVideoCodec(
        _ codec: WebRTCVideoCodec
    ) -> LiveShareVideoCodec {
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

    static func advancedVideoConfiguration(
        _ settings: LiveShareCodecAdvancedSettings,
        codec: LiveShareVideoCodec
    ) -> WebRTCCodecAdvancedConfiguration? {
        guard codec == .h264 else { return nil }
        let normalized = settings.normalized(for: codec)
        return .h264(
            WebRTCH264AdvancedConfiguration(
                maximumQuantizer: normalized.maximumQuantizer,
                qualityFraction:
                    Double(normalized.h264QualityPercent ?? 98) / 100,
                keyFrameIntervalSeconds:
                    normalized.h264KeyFrameIntervalSeconds ?? 2
            )
        )
    }
}

/// Applies one codec preference to the participant's complete set of direct
/// links. The WebRTC runtime already rolls back the link that rejects its
/// update; this transaction additionally restores the factory preference and
/// every currently known link, including a peer that joined while negotiation
/// was suspended.
@MainActor
enum MeshParticipantCodecTransaction {
    struct Failure: Error, Equatable {
        let failedParticipantIDs: [ClipLiveShareNativeV3ParticipantID]
        let factoryRollbackFailed: Bool
        let rollbackFailedParticipantIDs: [
            ClipLiveShareNativeV3ParticipantID
        ]
    }

    static func apply(
        requestedCodec: WebRTCVideoCodec,
        previousCodec: WebRTCVideoCodec,
        participantIDs: () async -> [ClipLiveShareNativeV3ParticipantID],
        retainCodec: (WebRTCVideoCodec) throws -> Void,
        updateParticipant: (
            ClipLiveShareNativeV3ParticipantID,
            WebRTCVideoCodec,
            WebRTCVideoCodec
        ) async throws -> Void
    ) async throws {
        try retainCodec(requestedCodec)
        let initialParticipantIDs = await participantIDs()
        var failed: [ClipLiveShareNativeV3ParticipantID] = []
        for participantID in initialParticipantIDs {
            do {
                try await updateParticipant(
                    participantID,
                    requestedCodec,
                    previousCodec
                )
            } catch {
                failed.append(participantID)
            }
        }
        guard !failed.isEmpty else { return }

        var factoryRollbackFailed = false
        do {
            try retainCodec(previousCodec)
        } catch {
            factoryRollbackFailed = true
        }
        // Take a fresh membership snapshot after restoring the factory. A peer
        // may have joined while a negotiation was suspended; it inherited the
        // provisional codec and therefore needs the same authoritative
        // restoration as every original peer. A peer joining after this point
        // inherits `previousCodec` directly from the restored factory.
        let rollbackParticipantIDs = await participantIDs()
        var rollbackFailed: [ClipLiveShareNativeV3ParticipantID] = []
        for participantID in rollbackParticipantIDs.reversed() {
            do {
                try await updateParticipant(
                    participantID,
                    previousCodec,
                    requestedCodec
                )
            } catch {
                rollbackFailed.append(participantID)
            }
        }
        throw Failure(
            failedParticipantIDs: failed,
            factoryRollbackFailed: factoryRollbackFailed,
            rollbackFailedParticipantIDs: rollbackFailed
        )
    }
}
