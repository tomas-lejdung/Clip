import Foundation
import Testing
@testable import ClipCore

@Suite("Settings and export domain")
struct SettingsAndExportTests {
    @Test("Product defaults exactly match the specification")
    func productDefaults() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let settings = ClipSettings.defaults(homeDirectory: home)

        #expect(settings.schemaVersion == 2)
        #expect(!settings.launchAtLogin)
        #expect(!settings.showInDock)
        #expect(settings.defaultCaptureMode == .captureArea)
        #expect(settings.mostRecentCaptureMode == nil)
        #expect(settings.captureModeForNextInvocation == .captureArea)
        #expect(settings.rememberLastArea)
        #expect(settings.frameRate == .thirty)
        #expect(settings.showCursor)
        #expect(settings.audio == .none)
        #expect(settings.countdown == .threeSeconds)
        #expect(settings.historyRetention == .sevenDays)
        #expect(settings.exportConfiguration == .compact)
        #expect(settings.defaultFilenameTemplate == .default)
        #expect(!settings.automaticallyClosePreviewAfterCopy)
        #expect(settings.keepOriginalAfterExport)
        #expect(settings.defaultSaveDirectory.path == "/Users/tester/Movies")
        #expect(settings.shortcuts.conflicts.isEmpty)
        #expect(settings.shortcuts.capture.key == "r")
        #expect(settings.shortcuts.finish.key == "s")
        #expect(settings.shortcuts.pauseOrResume.key == "p")
    }

    @Test("All supported settings choices have exact raw values")
    func settingChoices() {
        #expect(CountdownDuration.allCases.map(\.seconds) == [0, 1, 3, 5])
        #expect(CaptureFrameRate.allCases.map(\.framesPerSecond) == [30, 60])
        #expect(CaptureMode.allCases == [
            .captureArea,
            .lastArea,
            .fullscreen,
            .captureApplication,
        ])
        #expect(ExportPreset.allCases == [.compact, .crisp, .smallest])
    }

    @Test("The four audio combinations remain distinct and Codable")
    func audioConfigurations() throws {
        let values: [AudioConfiguration] = [
            .none,
            .microphoneOnly,
            .systemAudioOnly,
            .microphoneAndSystemAudio,
        ]
        #expect(Set(values).count == 4)
        for value in values {
            #expect(try jsonRoundTrip(value) == value)
        }
    }

    @Test("Keyboard shortcuts normalize keys and require modifiers")
    func keyboardShortcutValidation() throws {
        let shortcut = try KeyboardShortcut(key: "R", modifiers: [.option, .command])
        #expect(shortcut.key == "r")
        #expect(shortcut.modifiers == [.option, .command])

        #expect(throws: KeyboardShortcutError.keyMustBeOneCharacter) {
            try KeyboardShortcut(key: "RR", modifiers: .command)
        }
        #expect(throws: KeyboardShortcutError.keyContainsControlCharacter) {
            try KeyboardShortcut(key: "\n", modifiers: .command)
        }
        #expect(throws: KeyboardShortcutError.modifiersRequired) {
            try KeyboardShortcut(key: "r", modifiers: [])
        }
    }

    @Test("Shortcut conflicts identify every affected action")
    func shortcutConflicts() throws {
        let duplicate = try KeyboardShortcut(key: "x", modifiers: [.command, .shift])
        let unique = try KeyboardShortcut(key: "y", modifiers: [.command, .shift])
        let configuration = ShortcutConfiguration(
            capture: duplicate,
            finish: duplicate,
            pauseOrResume: unique
        )

        let conflict = try #require(configuration.conflicts.first)
        #expect(configuration.conflicts.count == 1)
        #expect(conflict.shortcut == duplicate)
        #expect(conflict.actions == [.capture, .finish])
    }

    @Test("Shortcut subscripting updates only the selected action")
    func shortcutSubscript() throws {
        var configuration = ShortcutConfiguration.defaults
        let replacement = try KeyboardShortcut(key: "f", modifiers: [.command, .control])
        configuration[.finish] = replacement
        #expect(configuration[.finish] == replacement)
        #expect(configuration[.capture] == ShortcutConfiguration.defaults.capture)
    }

    @Test("Settings survive a complete JSON round trip")
    func settingsRoundTrip() throws {
        var settings = ClipSettings.defaults(
            homeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )
        settings.exportConfiguration = .smallest10MB
        settings.audio = .microphoneAndSystemAudio
        settings.frameRate = .sixty
        settings.mostRecentCaptureMode = .fullscreen
        settings.defaultFilenameTemplate = try RecordingFilenameTemplate(
            validating: "work-YYYY-MM-DD_HHmmss.mp4"
        )
        #expect(try jsonRoundTrip(settings) == settings)
        #expect(settings.captureModeForNextInvocation == .fullscreen)
    }

    @Test("Schema 1 settings migrate to the default filename template")
    func schemaOneFilenameTemplateMigration() throws {
        let settings = ClipSettings.defaults(
            homeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )
        let encoded = try JSONEncoder().encode(settings)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "defaultFilenameTemplate")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let migrated = try JSONDecoder().decode(ClipSettings.self, from: legacyData)
        #expect(migrated.schemaVersion == ClipSettings.currentSchemaVersion)
        #expect(migrated.defaultFilenameTemplate == .default)

        let migratedObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated))
                as? [String: Any]
        )
        #expect(migratedObject["schemaVersion"] as? Int == 2)
        #expect(
            migratedObject["defaultFilenameTemplate"] as? String
                == "clip-YYYYMMDD-HHmmss.mp4"
        )
    }

    @Test("Settings reject unsupported future schemas and unsafe persisted templates")
    func invalidSettingsMigrations() throws {
        let settings = ClipSettings.defaults(
            homeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )
        let encoded = try JSONEncoder().encode(settings)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object["schemaVersion"] = ClipSettings.currentSchemaVersion + 1
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ClipSettings.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        object["schemaVersion"] = ClipSettings.currentSchemaVersion
        object["defaultFilenameTemplate"] = "../escape-YYYY.mp4"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ClipSettings.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("Settings created before recent-mode persistence use the configured default")
    func settingsWithoutRecentModeRemainCompatible() throws {
        var settings = ClipSettings.defaults(
            homeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )
        settings.defaultCaptureMode = .lastArea
        let encoded = try JSONEncoder().encode(settings)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "mostRecentCaptureMode")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ClipSettings.self, from: legacyData)
        #expect(decoded.mostRecentCaptureMode == nil)
        #expect(decoded.captureModeForNextInvocation == .lastArea)
    }

    @Test("Smallest size targets expose decimal upload byte counts")
    func smallestTargets() throws {
        #expect(SmallestSizeTarget.tenMegabytes.megabytes == 10)
        #expect(SmallestSizeTarget.tenMegabytes.targetByteCount == 10_000_000)
        #expect(SmallestSizeTarget.twentyFiveMegabytes.targetByteCount == 25_000_000)
        #expect(try SmallestSizeTarget(customMegabytes: 1).targetByteCount == 1_000_000)
        #expect(try SmallestSizeTarget(customMegabytes: 500).targetByteCount == 500_000_000)
    }

    @Test("Custom Smallest targets reject values outside 1 through 500 MB")
    func smallestTargetBounds() {
        #expect(throws: SmallestSizeTargetError.customTargetOutOfRange(0)) {
            try SmallestSizeTarget(customMegabytes: 0)
        }
        #expect(throws: SmallestSizeTargetError.customTargetOutOfRange(501)) {
            try SmallestSizeTarget(customMegabytes: 501)
        }
    }

    @Test("Every export configuration is Codable")
    func exportRoundTrips() throws {
        let custom = try SmallestSizeTarget(customMegabytes: 42)
        let configurations: [ExportConfiguration] = [
            .compact,
            .crisp,
            .smallest10MB,
            .smallest25MB,
            ExportConfiguration(preset: .smallest, smallestSizeTarget: custom),
        ]
        for configuration in configurations {
            #expect(try jsonRoundTrip(configuration) == configuration)
        }
    }

    @Test("Decoding enforces custom target bounds")
    func invalidSmallestTargetJSON() {
        let data = Data(#"{"kind":"custom","megabytes":999}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SmallestSizeTarget.self, from: data)
        }
    }
}
