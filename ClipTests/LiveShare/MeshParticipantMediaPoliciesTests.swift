import ClipLiveShare
import ClipLiveShareWebRTC
import Foundation
import Testing

@testable import Clip

@Suite("Mesh participant media policies")
struct MeshParticipantMediaPoliciesTests {
    @Test("settings conversion preserves the established encoder contract")
    func persistedMediaContract() {
        var advanced = LiveShareAdvancedVideoSettings.default
        advanced.h264 = LiveShareCodecAdvancedSettings(
            maximumQuantizer: 31,
            minimumBitratePercent: 20,
            degradationPreference: .preserveFrameRate,
            temporalLayerCount: 2,
            scaleResolutionDownBy: 1.5,
            h264QualityPercent: 93,
            h264KeyFrameIntervalSeconds: 4
        )
        let settings = LiveShareSettings(
            quality: .high,
            frameRate: .sixty,
            encodingMode: .performance,
            videoCodec: .h264,
            advancedVideoSettings: advanced
        )

        let senderPolicy = LiveShareCapturePolicy.senderPolicy(for: settings)
        let advancedConfiguration = MeshParticipantMediaSettingsPolicy
            .advancedVideoConfiguration(
                settings.advancedVideoSettings.settings(for: .h264),
                codec: .h264
            )

        #expect(
            MeshParticipantMediaSettingsPolicy.videoCodec(.h264) == .h264
        )
        #expect(senderPolicy.maximumFramesPerSecond == 60)
        #expect(
            senderPolicy.maximumBitrateBps
                == settings.quality.maximumBitrateBitsPerSecond
        )
        #expect(senderPolicy.minimumBitrateBps == 600_000)
        #expect(senderPolicy.degradationStrategy == .framerate)
        #expect(senderPolicy.temporalLayerCount == 2)
        #expect(senderPolicy.resolutionScale == 1.5)
        #expect(
            advancedConfiguration
                == .h264(WebRTCH264AdvancedConfiguration(
                    maximumQuantizer: 31,
                    qualityFraction: 0.93,
                    keyFrameIntervalSeconds: 4
                ))
        )
    }

    @Test("initial peer configuration uses participant settings before links exist")
    func initialPeerConfiguration() {
        var advanced = LiveShareAdvancedVideoSettings.default
        advanced.av1 = LiveShareCodecAdvancedSettings(
            minimumBitratePercent: 35,
            degradationPreference: .preserveResolution,
            temporalLayerCount: 3,
            scaleResolutionDownBy: 1
        )
        advanced.h264 = LiveShareCodecAdvancedSettings(
            maximumQuantizer: 27,
            h264QualityPercent: 91,
            h264KeyFrameIntervalSeconds: 5
        )
        let settings = LiveShareSettings(
            quality: .max,
            frameRate: .sixty,
            encodingMode: .performance,
            videoCodec: .av1,
            colorMode: .nativeDisplay,
            advancedVideoSettings: advanced
        )
        var base = WebRTCPeerConfiguration.clipDefault
        base.iceServers = [
            .init(urlStrings: ["stun:room.example.test:3478"])
        ]

        let configuration = MeshParticipantMediaSettingsPolicy
            .peerConfiguration(base, settings: settings)

        #expect(configuration.iceServers == base.iceServers)
        #expect(configuration.videoCodec == .av1)
        #expect(configuration.videoEncodingMode == .performance)
        #expect(configuration.senderPolicy.maximumFramesPerSecond == 60)
        #expect(configuration.senderPolicy.maximumBitrateBps == 20_000_000)
        #expect(configuration.senderPolicy.minimumBitrateBps == 7_000_000)
        #expect(configuration.senderPolicy.degradationStrategy == .resolution)
        #expect(configuration.senderPolicy.temporalLayerCount == 3)
        #expect(configuration.senderPolicy.resolutionScale == 1)
        #expect(
            configuration.advancedVideoConfigurations.h264
                == WebRTCH264AdvancedConfiguration(
                    maximumQuantizer: 27,
                    qualityFraction: 0.91,
                    keyFrameIntervalSeconds: 5
                )
        )
    }

    @Test("presentation defaults mirror persisted Live Share defaults")
    func presentationDefaults() {
        let settings = LiveShareSettingsViewSnapshot()

        #expect(settings.quality == .max)
        #expect(settings.codec.codec == .av1)
        #expect(settings.colorMode == .nativeDisplay)
    }
}
