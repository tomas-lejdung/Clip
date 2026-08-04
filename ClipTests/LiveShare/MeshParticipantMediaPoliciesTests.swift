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

    @Test("partial codec failure rolls back every accepted peer and remains retryable")
    @MainActor
    func codecTransactionRollsBackAndRetries() async throws {
        enum FixtureError: Error { case rejected }
        let participants = (1...3).map {
            try! ClipLiveShareNativeV3ParticipantID(
                bytes: Data(
                    repeating: UInt8($0),
                    count: ClipLiveShareNativeV3.participantIDByteCount
                )
            )
        }
        var retained: [WebRTCVideoCodec] = []
        var updates: [
            (
                ClipLiveShareNativeV3ParticipantID,
                WebRTCVideoCodec,
                WebRTCVideoCodec
            )
        ] = []
        var rejectsMiddleParticipant = true
        var membershipSnapshots = [participants, participants]

        do {
            try await MeshParticipantCodecTransaction.apply(
                requestedCodec: .vp8,
                previousCodec: .av1,
                participantIDs: { membershipSnapshots.removeFirst() },
                retainCodec: { retained.append($0) },
                updateParticipant: { participantID, codec, rollback in
                    updates.append((participantID, codec, rollback))
                    if codec == .vp8,
                       participantID == participants[1],
                       rejectsMiddleParticipant {
                        throw FixtureError.rejected
                    }
                }
            )
            Issue.record("The partial codec transaction unexpectedly succeeded.")
        } catch let failure as MeshParticipantCodecTransaction.Failure {
            #expect(failure.failedParticipantIDs == [participants[1]])
            #expect(failure.factoryRollbackFailed == false)
            #expect(failure.rollbackFailedParticipantIDs.isEmpty)
        }

        #expect(retained == [.vp8, .av1])
        #expect(updates.map(\.0) == [
            participants[0], participants[1], participants[2],
            participants[2], participants[1], participants[0]
        ])
        #expect(updates.map(\.1) == [
            .vp8, .vp8, .vp8, .av1, .av1, .av1
        ])

        retained.removeAll()
        updates.removeAll()
        rejectsMiddleParticipant = false
        try await MeshParticipantCodecTransaction.apply(
            requestedCodec: .vp8,
            previousCodec: .av1,
            participantIDs: { participants },
            retainCodec: { retained.append($0) },
            updateParticipant: { participantID, codec, rollback in
                updates.append((participantID, codec, rollback))
            }
        )

        #expect(retained == [.vp8])
        #expect(updates.map(\.0) == participants)
        #expect(updates.allSatisfy { $0.1 == .vp8 && $0.2 == .av1 })
    }

    @Test("codec rollback includes a participant that joins mid-transaction")
    @MainActor
    func codecRollbackUsesFreshMembership() async throws {
        enum FixtureError: Error { case rejected }
        let participants = (1...3).map {
            try! ClipLiveShareNativeV3ParticipantID(
                bytes: Data(
                    repeating: UInt8($0),
                    count: ClipLiveShareNativeV3.participantIDByteCount
                )
            )
        }
        var snapshots = [
            Array(participants.prefix(2)),
            participants,
        ]
        var updates: [
            (ClipLiveShareNativeV3ParticipantID, WebRTCVideoCodec)
        ] = []

        await #expect(throws: MeshParticipantCodecTransaction.Failure.self) {
            try await MeshParticipantCodecTransaction.apply(
                requestedCodec: .vp8,
                previousCodec: .av1,
                participantIDs: { snapshots.removeFirst() },
                retainCodec: { _ in },
                updateParticipant: { participantID, codec, _ in
                    updates.append((participantID, codec))
                    if participantID == participants[1], codec == .vp8 {
                        throw FixtureError.rejected
                    }
                }
            )
        }

        #expect(updates.map(\.0) == [
            participants[0], participants[1],
            participants[2], participants[1], participants[0],
        ])
        #expect(updates.suffix(3).allSatisfy { $0.1 == .av1 })
    }
}
