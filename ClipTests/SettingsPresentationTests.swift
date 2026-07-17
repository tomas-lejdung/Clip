import CoreGraphics
import Testing
@testable import Clip

@Suite("Settings presentation")
struct SettingsPresentationTests {
    @Test("Settings has an explicit initial tab with stable identifiers")
    func explicitInitialTab() {
        #expect(SettingsTab.initial == .general)
        #expect(SettingsTab.allCases.count == 5)
        #expect(Set(SettingsTab.allCases.map(\.accessibilityIdentifier)).count == 5)
        #expect(SettingsTab.general.accessibilityIdentifier == "clip.settings.general")
        #expect(SettingsTab.permissions.accessibilityIdentifier == "clip.settings.permissions")
    }

    @MainActor
    @Test("The hosting view and production content window share one initial size")
    func stableInitialContentSize() {
        #expect(SettingsView.contentSize == CGSize(width: 570, height: 470))
    }
}
