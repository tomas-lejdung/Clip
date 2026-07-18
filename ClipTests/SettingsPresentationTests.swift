import CoreGraphics
import ClipCore
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
        #expect(SettingsView.contentSize == CGSize(width: 640, height: 520))
    }

    @MainActor
    @Test("The filename editor omits the fixed MP4 extension")
    func filenameEditorOmitsFixedExtension() throws {
        let editorText = SettingsView.filenameTemplateEditorText(for: .default)

        #expect(editorText == "clip-YYYYMMDD-HHmmss")
        #expect(editorText.hasSuffix(".mp4") == false)
        #expect(
            try RecordingFilenameTemplate(validating: editorText)
                == RecordingFilenameTemplate.default
        )
    }
}
