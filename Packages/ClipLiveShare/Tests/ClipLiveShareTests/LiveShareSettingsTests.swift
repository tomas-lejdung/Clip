import Foundation
import Testing
@testable import ClipLiveShare

@Suite("Live Share settings")
struct LiveShareSettingsTests {
    @Test("quality presets preserve Clip's eight sender ceilings")
    func qualityPresets() {
        #expect(LiveShareQualityPreset.allCases.map(\.maximumBitrateBitsPerSecond) == [
            500_000,
            1_500_000,
            3_000_000,
            6_000_000,
            10_000_000,
            15_000_000,
            20_000_000,
            50_000_000,
        ])
    }

    @Test("native defaults prioritize readable text at 30 FPS")
    func defaults() {
        let settings = LiveShareSettings.default
        #expect(settings.quality == .veryHigh)
        #expect(settings.frameRate == .thirty)
        #expect(settings.encodingMode == .quality)
        #expect(settings.videoCodec == .vp8)
        #expect(settings.colorMode == .compatibleRec709)
        #expect(!settings.systemAudioEnabled)
        #expect(!settings.cursorUpdatesMatchFrameRate)
        #expect(settings.prioritizeFocusedWindow)
        #expect(!settings.autoShareFocusedWindows)
        #expect(!settings.accessCodeEnabled)
        #expect(settings.advancedVideoSettings == .default)
        for codec in LiveShareVideoCodec.allCases {
            #expect(settings.advancedVideoSettings[codec] == .default)
        }
    }

    @Test("settings are stable Codable values")
    func codable() throws {
        var value = LiveShareSettings.default
        value.quality = .insane
        value.frameRate = .sixty
        value.videoCodec = .h264
        value.colorMode = .fullRangeRec709
        value.systemAudioEnabled = true
        value.cursorUpdatesMatchFrameRate = true
        value.prioritizeFocusedWindow = false
        value.autoShareFocusedWindows = true
        value.advancedVideoSettings.h264 = LiveShareCodecAdvancedSettings(
            maximumQuantizer: 30,
            minimumBitratePercent: 45,
            degradationPreference: .preserveResolution,
            temporalLayerCount: 2,
            scaleResolutionDownBy: 1.5,
            h264QualityPercent: 90,
            h264KeyFrameIntervalSeconds: 4
        )
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(LiveShareSettings.self, from: data) == value)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["videoCodec"] as? String == "h264")
        #expect(object["colorMode"] as? String == "fullRangeRec709")
        #expect(object["systemAudioEnabled"] as? Bool == true)
        #expect(object["cursorUpdatesMatchFrameRate"] as? Bool == true)
        #expect(object["prioritizeFocusedWindow"] as? Bool == false)
        #expect(object["adaptiveBitrateEnabled"] == nil)
        #expect(object["advancedVideoSettings"] != nil)
    }

    @Test("codec-less settings migrate to VP8 and the renamed focused-window preference")
    func legacyMigration() throws {
        let data = Data("""
        {
          "quality": 6,
          "frameRate": 30,
          "encodingMode": "performance",
          "adaptiveBitrateEnabled": false,
          "autoShareFocusedWindows": true,
          "accessCodeEnabled": true
        }
        """.utf8)

        let settings = try JSONDecoder().decode(LiveShareSettings.self, from: data)
        #expect(settings.quality == .max)
        #expect(settings.frameRate == .thirty)
        #expect(settings.encodingMode == .performance)
        #expect(settings.videoCodec == .vp8)
        #expect(settings.colorMode == .compatibleRec709)
        #expect(!settings.systemAudioEnabled)
        #expect(!settings.cursorUpdatesMatchFrameRate)
        #expect(!settings.prioritizeFocusedWindow)
        #expect(settings.autoShareFocusedWindows)
        #expect(settings.accessCodeEnabled)
        #expect(settings.advancedVideoSettings == .default)
    }

    @Test("missing settings fields receive current defaults")
    func missingFieldsUseDefaults() throws {
        let settings = try JSONDecoder().decode(LiveShareSettings.self, from: Data("{}".utf8))
        #expect(settings == .default)
    }

    @Test("codec options have stable persistence identifiers and user-facing names")
    func codecs() throws {
        #expect(LiveShareVideoCodec.allCases == [.h264, .vp8, .vp9, .av1])
        #expect(LiveShareVideoCodec.allCases.map(\.rawValue) == ["h264", "vp8", "vp9", "av1"])
        #expect(LiveShareVideoCodec.allCases.map(\.displayName) == ["H.264", "VP8", "VP9", "AV1"])

        for codec in LiveShareVideoCodec.allCases {
            let data = try JSONEncoder().encode(codec)
            #expect(try JSONDecoder().decode(LiveShareVideoCodec.self, from: data) == codec)
        }
    }

    @Test("color modes have stable persistence identifiers")
    func colorModes() throws {
        #expect(LiveShareColorMode.allCases == [
            .compatibleRec709,
            .fullRangeRec709,
            .nativeDisplay,
        ])
        #expect(LiveShareColorMode.allCases.map(\.rawValue) == [
            "compatibleRec709",
            "fullRangeRec709",
            "nativeDisplay",
        ])

        for mode in LiveShareColorMode.allCases {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(LiveShareColorMode.self, from: data) == mode)
        }
    }

    @Test("H264 exposes the VideoToolbox quantizer range")
    func maximumQuantizerRange() {
        #expect(LiveShareCodecAdvancedSettings.h264MaximumQuantizerRange == 0 ... 51)
    }

    @Test("advanced values normalize to sender and UI limits")
    func advancedNormalization() {
        let outOfRange = LiveShareCodecAdvancedSettings(
            maximumQuantizer: 200,
            minimumBitratePercent: -5,
            degradationPreference: .balanced,
            temporalLayerCount: 7,
            scaleResolutionDownBy: 10,
            h264QualityPercent: 0,
            h264KeyFrameIntervalSeconds: 20
        )

        let h264 = outOfRange.normalized(for: .h264)
        #expect(h264.maximumQuantizer == 51)
        #expect(h264.minimumBitratePercent == 0)
        #expect(h264.degradationPreference == .balanced)
        #expect(h264.temporalLayerCount == 3)
        #expect(h264.scaleResolutionDownBy == 4)
        #expect(h264.h264QualityPercent == 1)
        #expect(h264.h264KeyFrameIntervalSeconds == 10)

        let vp8 = outOfRange.normalized(for: .vp8)
        #expect(vp8.maximumQuantizer == nil)
        #expect(vp8.h264QualityPercent == nil)
        #expect(vp8.h264KeyFrameIntervalSeconds == nil)

        let automatic = LiveShareCodecAdvancedSettings.default.normalized(for: .av1)
        #expect(automatic == .default)
    }

    @Test("advanced settings can be read and replaced by codec")
    func advancedSettingsByCodec() {
        var settings = LiveShareAdvancedVideoSettings.default
        let vp9 = LiveShareCodecAdvancedSettings(
            degradationPreference: .preserveFrameRate
        )

        settings.set(vp9, for: .vp9)
        #expect(settings[.vp9] == vp9)
        #expect(settings.settings(for: .vp9) == vp9)
        #expect(settings[.h264] == .default)
        #expect(settings[.vp8] == .default)
        #expect(settings[.av1] == .default)

        settings.vp9.maximumQuantizer = 28
        #expect(settings.normalized().vp9.maximumQuantizer == nil)
    }

    @Test("advanced settings remain backward-compatible when fields are missing")
    func advancedSettingsMigration() throws {
        let data = Data("""
        {
          "h264": {
            "maximumQuantizer": 31
          },
          "vp9": {
            "degradationPreference": "disabled",
            "temporalLayerCount": 3
          }
        }
        """.utf8)

        let settings = try JSONDecoder().decode(LiveShareAdvancedVideoSettings.self, from: data)
        #expect(settings.h264.maximumQuantizer == 31)
        #expect(settings.h264.degradationPreference == .automatic)
        #expect(settings.vp8 == .default)
        #expect(settings.vp9.degradationPreference == .disabled)
        #expect(settings.vp9.temporalLayerCount == 3)
        #expect(settings.av1 == .default)

        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(LiveShareAdvancedVideoSettings.self, from: encoded) == settings)
    }
}
