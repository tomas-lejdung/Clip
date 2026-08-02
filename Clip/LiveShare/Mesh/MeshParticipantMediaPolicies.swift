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
