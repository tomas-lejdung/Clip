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
    @Test("Native Friends rows expose name, device, fingerprint, and trust status")
    func nativeFriendRows() throws {
        let fileSystem = SettingsMemoryAtomicFileSystem()
        let repository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/Clip-Settings-Friends",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        let book = try settingsNativeFriendBook()
        let model = NativeFriendModel(repository: repository, initialBook: book)
        let liveRecord = try #require(book.records.first(where: {
            $0.trustState == .trusted
        }))
        model.setPresence(.live, id: liveRecord.id)

        let rows = SettingsView.nativeFriendRows(for: model)
        let live = try #require(rows.first(where: { $0.id == liveRecord.id }))
        let blocked = try #require(rows.first(where: { $0.status == .blocked }))

        #expect(live.displayName == liveRecord.displayName)
        #expect(live.deviceName == liveRecord.deviceName)
        #expect(live.status == .live)
        #expect(live.fingerprint.replacingOccurrences(of: " ", with: "")
            == liveRecord.identity.fingerprint.rawValue)
        #expect(blocked.isBlocked)
        #expect(
            SettingsAccessibilityIdentifier.nativeFriend(
                live.id,
                element: "name"
            ) == "clip.settings.liveShare.friend.\(live.id).name"
        )
        #expect(
            SettingsAccessibilityIdentifier.nativeIdentityFingerprint
                == "clip.settings.liveShare.identity.fingerprint"
        )
        #expect(
            SettingsAccessibilityIdentifier.nativeIdentityResetConfirm
                == "clip.settings.liveShare.identity.reset.confirm"
        )
    }

    @MainActor
    @Test("Reset Identity rotates the secure identity and removes persisted Friends")
    func resetNativeIdentity() async throws {
        let friendFileSystem = SettingsMemoryAtomicFileSystem()
        let friendRepository = try NativeFriendRepository(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/Clip-Settings-Identity-Reset",
                isDirectory: true
            ),
            fileSystem: friendFileSystem
        )
        let friendModel = NativeFriendModel(
            repository: friendRepository,
            initialBook: try settingsNativeFriendBook()
        )
        let identityStorage = SettingsMemoryIdentityStorage()
        let identityRepository = NativeDeviceIdentityRepository(
            storage: identityStorage
        )
        let original = try await identityRepository.loadOrCreate().fingerprint

        let replacement = try await SettingsView.resetNativeIdentity(
            repository: identityRepository,
            friends: friendModel
        )

        #expect(replacement != original)
        #expect(friendModel.book.records.isEmpty)
        #expect(try await friendRepository.load().records.isEmpty)
        #expect(identityStorage.deleteCount == 1)
        #expect(
            try await identityRepository.loadOrCreate().fingerprint
                == replacement
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
        #expect(model.serverEndpoint == .official)

        model.updateSettings {
            $0.quality = .insane
            $0.videoCodec = .av1
            $0.systemAudioEnabled = true
            $0.cursorUpdatesMatchFrameRate = true
        }
        let customEndpoint = try ClipLiveShareServerEndpoint(
            userInput: "https://share.example.com:8443"
        )
        model.setServerEndpoint(customEndpoint)
        await model.flushPendingPersistence()

        let reloaded = try LiveSharePreferencesModel(applicationSupportDirectory: directory)
        await reloaded.load()
        #expect(reloaded.settings.quality == .insane)
        #expect(reloaded.settings.videoCodec == .av1)
        #expect(reloaded.settings.systemAudioEnabled)
        #expect(reloaded.settings.cursorUpdatesMatchFrameRate)
        #expect(reloaded.serverEndpoint == customEndpoint)

        reloaded.resetServerEndpoint()
        #expect(reloaded.serverEndpoint == .official)
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
        #expect(repaired.serverEndpoint == .official)
        #expect(repaired.lastPersistenceError == nil)

        let reloaded = try LiveSharePreferencesModel(
            applicationSupportDirectory: directory
        )
        await reloaded.load()
        #expect(reloaded.serverEndpoint == .official)
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
            try ClipLiveShareServerEndpoint(userInput: "https://share.example.com")
        )
        await model.flushPendingPersistence()
        #expect(model.lastPersistenceError != nil)

        model.updateSettings { $0.quality = .insane }
        await model.flushPendingPersistence()
        #expect(model.lastPersistenceError != nil)
    }

    @MainActor
    @Test("The connection probe validates the capability document without allocating a room")
    func liveShareConnectionProbe() async throws {
        let recorder = SettingsProbeRecorder()
        let capabilities = try JSONEncoder().encode(ClipLiveShareCapabilities.v1Default)
        let probe = LiveShareServerConnectionProbe { request in
            await recorder.record(request)
            return LiveShareServerProbeResponse(statusCode: 200, data: capabilities)
        }
        try await probe.test(.official)

        let request = try #require(await recorder.lastRequest())
        #expect(request.httpMethod == "GET")
        #expect(
            request.url?.absoluteString
                == "https://clip.tineestudio.se/.well-known/clip-live-share"
        )
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 5)

        let incompatible = LiveShareServerConnectionProbe { _ in
            LiveShareServerProbeResponse(statusCode: 404, data: Data())
        }
        await #expect(throws: LiveShareServerConnectionProbeError.incompatibleStatus(404)) {
            try await incompatible.test(.official)
        }

        let malformed = LiveShareServerConnectionProbe { _ in
            LiveShareServerProbeResponse(statusCode: 200, data: Data("{}".utf8))
        }
        await #expect(throws: LiveShareServerConnectionProbeError.incompatibleProtocol) {
            try await malformed.test(.official)
        }
    }
}

private actor SettingsProbeRecorder {
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
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

private final class SettingsMemoryIdentityStorage:
    NativeDeviceIdentitySecureStorage, @unchecked Sendable
{
    private let lock = NSLock()
    private var data: Data?
    private var storedDeleteCount = 0

    var deleteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDeleteCount
    }

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func insert(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        data = nil
        storedDeleteCount += 1
    }
}

private func settingsNativeFriendBook() throws -> NativeFriendBook {
    let liveIdentity = try NativeDeviceIdentitySigner(
        rawRepresentation: settingsPrivateKey(seed: 2)
    ).publicKey
    let blockedIdentity = try NativeDeviceIdentitySigner(
        rawRepresentation: settingsPrivateKey(seed: 3)
    ).publicKey
    return NativeFriendBook(records: [
        NativeFriendRecord(
            identity: liveIdentity,
            displayName: "Mira",
            deviceName: "Mira’s MacBook Pro",
            endpoint: .official,
            rendezvousID: try ClipLiveShareRendezvousID(
                bytes: Data(
                    repeating: 0x22,
                    count: ClipLiveShareNativeV2.rendezvousIDByteCount
                )
            ),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        NativeFriendRecord(
            identity: blockedIdentity,
            displayName: "Old Studio Mac",
            deviceName: "Mac mini",
            endpoint: .official,
            rendezvousID: try ClipLiveShareRendezvousID(
                bytes: Data(
                    repeating: 0x33,
                    count: ClipLiveShareNativeV2.rendezvousIDByteCount
                )
            ),
            trustState: .blocked,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        ),
    ])
}

private func settingsPrivateKey(seed: UInt8) -> Data {
    precondition(seed > 0)
    var data = Data(repeating: 0, count: 32)
    data[data.index(before: data.endIndex)] = seed
    return data
}
