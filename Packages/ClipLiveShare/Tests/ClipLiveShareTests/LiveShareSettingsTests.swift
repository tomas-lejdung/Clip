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
        #expect(!settings.systemAudioEnabled)
        #expect(settings.prioritizeFocusedWindow)
        #expect(!settings.autoShareFocusedWindows)
        #expect(!settings.accessCodeEnabled)
    }

    @Test("settings are stable Codable values")
    func codable() throws {
        var value = LiveShareSettings.default
        value.quality = .insane
        value.frameRate = .sixty
        value.videoCodec = .h264
        value.systemAudioEnabled = true
        value.prioritizeFocusedWindow = false
        value.autoShareFocusedWindows = true
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(LiveShareSettings.self, from: data) == value)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["videoCodec"] as? String == "h264")
        #expect(object["systemAudioEnabled"] as? Bool == true)
        #expect(object["prioritizeFocusedWindow"] as? Bool == false)
        #expect(object["adaptiveBitrateEnabled"] == nil)
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
        #expect(!settings.systemAudioEnabled)
        #expect(!settings.prioritizeFocusedWindow)
        #expect(settings.autoShareFocusedWindows)
        #expect(settings.accessCodeEnabled)
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
}
