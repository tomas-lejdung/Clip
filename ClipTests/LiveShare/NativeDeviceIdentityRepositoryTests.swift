import Foundation
import Security
import Testing
@testable import Clip

@Suite("Native device identity repository")
struct NativeDeviceIdentityRepositoryTests {
    @Test("Signing identity survives repository recreation")
    func persistsSigningIdentity() async throws {
        let storage = MemoryNativeIdentitySecureStorage()
        let firstRepository = NativeDeviceIdentityRepository(storage: storage)
        let first = try await firstRepository.loadOrCreate()
        let secondRepository = NativeDeviceIdentityRepository(storage: storage)
        let second = try await secondRepository.loadOrCreate()

        #expect(first.publicKey == second.publicKey)
        let payload = Data("signed fixture".utf8)
        #expect(first.publicKey.isValidSignature(
            try second.signer.signature(for: payload),
            for: payload
        ))
    }

    @Test("Reset rotates the persistent signing identity")
    func resetRotatesIdentity() async throws {
        let repository = NativeDeviceIdentityRepository(
            storage: MemoryNativeIdentitySecureStorage()
        )
        let first = try await repository.loadOrCreate()
        let replacement = try await repository.reset()

        #expect(first.publicKey != replacement.publicKey)
    }

    @Test("Corrupt Keychain data fails closed instead of rotating trust silently")
    func corruptDataFailsClosed() async {
        let storage = MemoryNativeIdentitySecureStorage(initial: Data("not-json".utf8))
        let repository = NativeDeviceIdentityRepository(storage: storage)

        await #expect(throws: NativeDeviceIdentityStorageError.corruptIdentity) {
            try await repository.loadOrCreate()
        }
    }

    @Test("A concurrent insert winner is loaded")
    func insertRaceLoadsWinner() async throws {
        let winnerStorage = MemoryNativeIdentitySecureStorage()
        let winnerRepository = NativeDeviceIdentityRepository(storage: winnerStorage)
        let winner = try await winnerRepository.loadOrCreate()
        let data = try #require(winnerStorage.data)
        let racingStorage = MemoryNativeIdentitySecureStorage(
            initial: nil,
            duplicateWinner: data
        )
        let repository = NativeDeviceIdentityRepository(storage: racingStorage)
        let result = try await repository.loadOrCreate()

        #expect(result.publicKey == winner.publicKey)
    }

    @Test("The live macOS Keychain round-trips private identity data")
    func liveKeychainRoundTrip() throws {
        let storage = LiveNativeDeviceIdentityKeychain(
            service: "com.tomaslejdung.clip.tests.\(UUID().uuidString)",
            account: "native-device-identity-keychain-round-trip"
        )
        defer { try? storage.delete() }

        try storage.delete()
        #expect(try storage.load() == nil)

        let expected = Data("private identity fixture".utf8)
        try storage.insert(expected)
        #expect(try storage.load() == expected)

        try storage.delete()
        #expect(try storage.load() == nil)
    }

    @Test("Keychain errors retain their actionable OS status")
    func keychainErrorDescription() {
        let message = NativeDeviceIdentityStorageError
            .keychain(errSecMissingEntitlement)
            .technicalDescriptionForLogging

        #expect(message.contains(String(errSecMissingEntitlement)))
        #expect(message.localizedCaseInsensitiveContains("Keychain"))
    }

    @Test("Guarded file identities persist independently per mesh participant")
    func guardedMeshFileIdentitiesPersistAndRemainDistinct() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Clip-Mesh-Identity-Tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root
            .appendingPathComponent("participant-a", isDirectory: true)
            .appendingPathComponent(
                IsolatedNativeDeviceIdentityFileStorage.relativePath,
                isDirectory: false
            )
        let secondURL = root
            .appendingPathComponent("participant-b", isDirectory: true)
            .appendingPathComponent(
                IsolatedNativeDeviceIdentityFileStorage.relativePath,
                isDirectory: false
            )
        let firstRepository = NativeDeviceIdentityRepository(
            storage: IsolatedNativeDeviceIdentityFileStorage(fileURL: firstURL)
        )
        let firstIdentity = try await firstRepository.loadOrCreate()
        let relaunchedRepository = NativeDeviceIdentityRepository(
            storage: IsolatedNativeDeviceIdentityFileStorage(fileURL: firstURL)
        )
        let relaunchedIdentity = try await relaunchedRepository.loadOrCreate()
        let secondRepository = NativeDeviceIdentityRepository(
            storage: IsolatedNativeDeviceIdentityFileStorage(fileURL: secondURL)
        )
        let secondIdentity = try await secondRepository.loadOrCreate()

        #expect(firstIdentity.publicKey == relaunchedIdentity.publicKey)
        #expect(firstIdentity.publicKey != secondIdentity.publicKey)
    }

    @Test("Guarded file identity is owner-only and bounded")
    func guardedMeshFileIdentityIsOwnerOnlyAndBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Clip-Mesh-Identity-Tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(
            IsolatedNativeDeviceIdentityFileStorage.relativePath,
            isDirectory: false
        )
        let storage = IsolatedNativeDeviceIdentityFileStorage(fileURL: fileURL)
        let payload = Data("private identity fixture".utf8)

        try storage.insert(payload)

        #expect(try storage.load() == payload)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )
        let filePermissions = try #require(
            fileAttributes[.posixPermissions] as? NSNumber
        )
        let directoryPermissions = try #require(
            directoryAttributes[.posixPermissions] as? NSNumber
        )
        #expect(filePermissions.intValue & 0o777 == 0o600)
        #expect(directoryPermissions.intValue & 0o777 == 0o700)

        let oversized = Data(
            repeating: 0xFF,
            count: (64 * 1_024) + 1
        )
        let oversizedStorage = IsolatedNativeDeviceIdentityFileStorage(
            fileURL: root.appendingPathComponent("oversized.json")
        )
        #expect(throws: NativeDeviceIdentityStorageError.corruptIdentity) {
            try oversizedStorage.insert(oversized)
        }
    }

    @Test("Only a valid mesh acceptance launch selects file-backed identity storage")
    func fileStorageSelectionIsFailClosed() throws {
        let root = URL(fileURLWithPath: "/tmp/clip-mesh-identity-selection")
        let validArguments = [
            "Clip",
            AppLaunchConfiguration.uiTestingArgument,
            AppLaunchConfiguration.nativeV3MeshAcceptanceArgument,
            AppLaunchConfiguration.nativeV3MeshAcceptanceAcknowledgementArgument,
            "\(AppLaunchConfiguration.nativeV3MeshParticipantArgumentPrefix)participant-a",
        ]
        let meshConfiguration = AppLaunchConfiguration.resolve(
            arguments: validArguments,
            temporaryDirectory: root,
            isolationIdentifier: AppLaunchConfiguration.isolationIdentifier(
                for: validArguments
            )
        )
        let storage = try meshConfiguration.makeNativeDeviceIdentityStorage(
            applicationSupportDirectory: root.appendingPathComponent("Support")
        )
        let isolatedStorage = try #require(
            storage as? IsolatedNativeDeviceIdentityFileStorage
        )
        #expect(
            isolatedStorage.fileURL
                == root
                    .appendingPathComponent("Support")
                    .appendingPathComponent(
                        IsolatedNativeDeviceIdentityFileStorage.relativePath
                    )
        )

        let production = AppLaunchConfiguration.resolve(
            arguments: ["Clip"],
            temporaryDirectory: root,
            isolationIdentifier: "production"
        )
        #expect(
            try production.makeNativeDeviceIdentityStorage(
                applicationSupportDirectory: root
            ) is LiveNativeDeviceIdentityKeychain
        )

        let invalidArguments = Array(validArguments.dropLast())
        let invalid = AppLaunchConfiguration.resolve(
            arguments: invalidArguments,
            temporaryDirectory: root,
            isolationIdentifier: AppLaunchConfiguration.isolationIdentifier(
                for: invalidArguments
            )
        )
        #expect(throws: AppLaunchConfigurationError.invalidNativeV3MeshAcceptanceRequest) {
            _ = try invalid.makeNativeDeviceIdentityStorage(
                applicationSupportDirectory: root
            )
        }
    }
}

private final class MemoryNativeIdentitySecureStorage:
    NativeDeviceIdentitySecureStorage,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedData: Data?
    private let duplicateWinner: Data?

    init(initial: Data? = nil, duplicateWinner: Data? = nil) {
        storedData = initial
        self.duplicateWinner = duplicateWinner
    }

    var data: Data? {
        lock.withLock { storedData }
    }

    func load() throws -> Data? {
        lock.withLock { storedData }
    }

    func insert(_ data: Data) throws {
        try lock.withLock {
            if let duplicateWinner, storedData == nil {
                storedData = duplicateWinner
                throw NativeDeviceIdentityStorageError.keychain(errSecDuplicateItem)
            }
            if storedData != nil {
                throw NativeDeviceIdentityStorageError.keychain(errSecDuplicateItem)
            }
            storedData = data
        }
    }

    func delete() throws {
        lock.withLock { storedData = nil }
    }
}
