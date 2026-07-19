import Foundation
import Testing
@testable import ClipLiveShare

@Suite("Live Share settings")
struct LiveShareSettingsTests {
    @Test("quality presets preserve GoPeep's eight sender ceilings")
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
        #expect(settings.adaptiveBitrateEnabled)
        #expect(!settings.autoShareFocusedWindows)
        #expect(!settings.accessCodeEnabled)
    }

    @Test("settings are stable Codable values")
    func codable() throws {
        var value = LiveShareSettings.default
        value.quality = .insane
        value.frameRate = .sixty
        value.autoShareFocusedWindows = true
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(LiveShareSettings.self, from: data) == value)
    }
}
