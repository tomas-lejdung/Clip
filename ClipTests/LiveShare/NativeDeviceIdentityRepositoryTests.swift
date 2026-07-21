import Foundation
import Security
import Testing
@testable import Clip

@Suite("Native device identity repository")
struct NativeDeviceIdentityRepositoryTests {
    @Test("Identity, rendezvous and owner capability survive repository recreation")
    func persistsCompleteIdentity() async throws {
        let storage = MemoryNativeIdentitySecureStorage()
        let firstRepository = NativeDeviceIdentityRepository(storage: storage)
        let first = try await firstRepository.loadOrCreate()
        let secondRepository = NativeDeviceIdentityRepository(storage: storage)
        let second = try await secondRepository.loadOrCreate()

        #expect(first.publicKey == second.publicKey)
        #expect(first.rendezvousID == second.rendezvousID)
        #expect(first.ownerToken.rawValue == second.ownerToken.rawValue)
        let payload = Data("signed fixture".utf8)
        #expect(first.publicKey.isValidSignature(
            try second.signer.signature(for: payload),
            for: payload
        ))
    }

    @Test("Reset rotates every persistent secret")
    func resetRotatesIdentity() async throws {
        let repository = NativeDeviceIdentityRepository(
            storage: MemoryNativeIdentitySecureStorage()
        )
        let first = try await repository.loadOrCreate()
        let replacement = try await repository.reset()

        #expect(first.publicKey != replacement.publicKey)
        #expect(first.rendezvousID != replacement.rendezvousID)
        #expect(first.ownerToken.rawValue != replacement.ownerToken.rawValue)
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
