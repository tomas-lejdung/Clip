import CoreGraphics
import ClipCore
import ClipLiveShare
import Foundation
import Testing
@testable import Clip

@Suite("Settings presentation")
struct SettingsPresentationTests {
    @Test("Settings has an explicit initial tab with stable identifiers")
    func explicitInitialTab() {
        #expect(SettingsTab.initial == .general)
        #expect(SettingsTab.allCases.count == 6)
        #expect(Set(SettingsTab.allCases.map(\.accessibilityIdentifier)).count == 6)
        #expect(SettingsTab.general.accessibilityIdentifier == "clip.settings.general")
        #expect(SettingsTab.liveShare.accessibilityIdentifier == "clip.settings.liveShare")
        #expect(SettingsTab.permissions.accessibilityIdentifier == "clip.settings.permissions")
    }

    @MainActor
    @Test("The hosting view and production content window share one initial size")
    func stableInitialContentSize() {
        #expect(SettingsView.contentSize == CGSize(width: 760, height: 520))
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

    @MainActor
    @Test("Live Share preferences persist independently and reset independently")
    func liveSharePreferencePersistenceAndReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Clip-LiveShare-Preferences-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = try LiveSharePreferencesModel(applicationSupportDirectory: directory)
        await model.load()
        #expect(model.settings == .default)
        #expect(model.serverEndpoint == .goPeepRemote)

        model.updateSettings {
            $0.quality = .insane
            $0.videoCodec = .av1
            $0.systemAudioEnabled = true
        }
        let customEndpoint = try LiveShareServerEndpoint(
            userInput: "https://share.example.com:8443"
        )
        model.setServerEndpoint(customEndpoint)
        await model.flushPendingPersistence()

        let reloaded = try LiveSharePreferencesModel(applicationSupportDirectory: directory)
        await reloaded.load()
        #expect(reloaded.settings.quality == .insane)
        #expect(reloaded.settings.videoCodec == .av1)
        #expect(reloaded.settings.systemAudioEnabled)
        #expect(reloaded.serverEndpoint == customEndpoint)

        reloaded.resetServerEndpoint()
        #expect(reloaded.serverEndpoint == .goPeepRemote)
        #expect(reloaded.settings.quality == .insane)

        reloaded.setServerEndpoint(customEndpoint)
        reloaded.restoreSessionDefaults()
        #expect(reloaded.settings == .default)
        #expect(reloaded.serverEndpoint == customEndpoint)
    }

    @MainActor
    @Test("A corrupt Live Share server file repairs itself to the built-in endpoint")
    func corruptLiveShareEndpointRepairsItself() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Clip-LiveShare-Corrupt-Endpoint-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not valid JSON".utf8).write(
            to: directory.appendingPathComponent("live-share-server-settings.json")
        )

        let repaired = try LiveSharePreferencesModel(
            applicationSupportDirectory: directory
        )
        await repaired.load()
        #expect(repaired.serverEndpoint == .goPeepRemote)
        #expect(repaired.lastPersistenceError == nil)

        let reloaded = try LiveSharePreferencesModel(
            applicationSupportDirectory: directory
        )
        await reloaded.load()
        #expect(reloaded.serverEndpoint == .goPeepRemote)
        #expect(reloaded.lastPersistenceError == nil)
    }

    @MainActor
    @Test("A settings save cannot hide an independent server save failure")
    func liveSharePersistenceErrorsRemainIndependent() async throws {
        let settingsFileSystem = SettingsMemoryAtomicFileSystem()
        let endpointFileSystem = SettingsMemoryAtomicFileSystem(failsWrites: true)
        let model = try LiveSharePreferencesModel(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/Clip-LiveShare-Independent-Errors",
                isDirectory: true
            ),
            settingsFileSystem: settingsFileSystem,
            endpointFileSystem: endpointFileSystem
        )
        await model.load()

        model.setServerEndpoint(
            try LiveShareServerEndpoint(userInput: "https://share.example.com")
        )
        await model.flushPendingPersistence()
        #expect(model.lastPersistenceError != nil)

        model.updateSettings { $0.quality = .insane }
        await model.flushPendingPersistence()
        #expect(model.lastPersistenceError != nil)
    }

    @MainActor
    @Test("The connection probe checks the reservation route without allocating a room")
    func liveShareConnectionProbe() async throws {
        let recorder = SettingsProbeRecorder(statusCode: 405)
        let probe = LiveShareServerConnectionProbe { request in
            await recorder.record(request)
        }
        try await probe.test(.goPeepRemote)

        let request = try #require(await recorder.lastRequest())
        #expect(request.httpMethod == "HEAD")
        #expect(
            request.url?.absoluteString
                == "https://gopeep.tineestudio.se/api/reserve"
        )
        #expect(request.timeoutInterval == 5)

        let incompatible = LiveShareServerConnectionProbe { _ in 404 }
        await #expect(throws: LiveShareServerConnectionProbeError.incompatibleStatus(404)) {
            try await incompatible.test(.goPeepRemote)
        }
    }
}

private actor SettingsProbeRecorder {
    private let statusCode: Int
    private var request: URLRequest?

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func record(_ request: URLRequest) -> Int {
        self.request = request
        return statusCode
    }

    func lastRequest() -> URLRequest? {
        request
    }
}

private enum SettingsAtomicFileSystemError: Error {
    case expectedWriteFailure
}

private actor SettingsMemoryAtomicFileSystem: AtomicFileSystem {
    private var files: [URL: Data] = [:]
    private let failsWrites: Bool

    init(failsWrites: Bool = false) {
        self.failsWrites = failsWrites
    }

    func dataIfPresent(at url: URL) async throws -> Data? {
        files[url]
    }

    func writeAtomically(_ data: Data, to url: URL) async throws {
        guard !failsWrites else {
            throw SettingsAtomicFileSystemError.expectedWriteFailure
        }
        files[url] = data
    }
}
