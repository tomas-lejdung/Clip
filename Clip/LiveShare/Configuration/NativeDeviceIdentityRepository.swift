import ClipLiveShare
import CryptoKit
import Foundation
import Security

enum NativeDeviceIdentityStorageError:
    Error,
    Equatable,
    Sendable,
    LocalizedError,
    TechnicalErrorDescriptionProviding
{
    case keychain(OSStatus)
    case corruptIdentity

    var errorDescription: String? {
        switch self {
        case .keychain:
            return String(
                localized: "Clip couldn’t access this Mac’s secure Live Share identity. Try again."
            )
        case .corruptIdentity:
            return String(
                localized: "This Mac’s secure Live Share identity is damaged and could not be loaded."
            )
        }
    }

    var technicalDescriptionForLogging: String {
        switch self {
        case let .keychain(status):
            let statusDescription = SecCopyErrorMessageString(status, nil)
                .map { $0 as String }
                ?? "Unknown Keychain error"
            return "Native device identity Keychain error [\(status): \(statusDescription)]"
        case .corruptIdentity:
            return "Native device identity Keychain payload is corrupt"
        }
    }
}

protocol NativeDeviceIdentitySecureStorage: Sendable {
    func load() throws -> Data?
    func insert(_ data: Data) throws
    func delete() throws
}

struct LiveNativeDeviceIdentityKeychain: NativeDeviceIdentitySecureStorage {
    private let service: String
    private let account: String

    init(
        service: String = "com.tomaslejdung.clip.live-share",
        account: String = "native-device-identity-v1"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NativeDeviceIdentityStorageError.keychain(status)
        }
        return data
    }

    func insert(_ data: Data) throws {
        var query = baseQuery
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NativeDeviceIdentityStorageError.keychain(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NativeDeviceIdentityStorageError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        // The data-protection Keychain requires a provisioning-authorized
        // application identifier or Keychain access group. Clip is also
        // distributed as a directly signed macOS app without a provisioning
        // profile, so keep this private identity in the standard login
        // Keychain. Its item ACL remains bound to Clip's code signature and it
        // works for both stable certificate and ad-hoc development builds.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

struct NativeDeviceIdentitySigner: ClipLiveShareIdentitySigner, @unchecked Sendable {
    private let privateKey: P256.Signing.PrivateKey

    init(rawRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    init() {
        privateKey = P256.Signing.PrivateKey()
    }

    var publicKey: ClipLiveShareIdentityPublicKey {
        try! ClipLiveShareIdentityPublicKey(
            x963Representation: privateKey.publicKey.x963Representation
        )
    }

    func signature(
        for canonicalRepresentation: Data
    ) throws -> ClipLiveShareIdentitySignature {
        try ClipLiveShareIdentitySignature(
            rawRepresentation: privateKey
                .signature(for: canonicalRepresentation)
                .rawRepresentation
        )
    }

    fileprivate var rawRepresentation: Data { privateKey.rawRepresentation }
}

struct NativeDeviceIdentity: Sendable {
    let signer: NativeDeviceIdentitySigner
    let rendezvousID: ClipLiveShareRendezvousID
    let ownerToken: ClipLiveShareOwnerToken

    var publicKey: ClipLiveShareIdentityPublicKey { signer.publicKey }
    var fingerprint: ClipLiveShareIdentityFingerprint { publicKey.fingerprint }
}

actor NativeDeviceIdentityRepository {
    private struct StoredIdentity: Codable, Sendable {
        let version: Int
        let signingPrivateKey: Data
        let rendezvousID: ClipLiveShareRendezvousID
        let ownerToken: ClipLiveShareOwnerToken
    }

    private let storage: any NativeDeviceIdentitySecureStorage
    private var cachedIdentity: NativeDeviceIdentity?

    init(storage: any NativeDeviceIdentitySecureStorage = LiveNativeDeviceIdentityKeychain()) {
        self.storage = storage
    }

    func loadOrCreate() throws -> NativeDeviceIdentity {
        if let cachedIdentity { return cachedIdentity }
        if let data = try storage.load() {
            let identity = try decode(data)
            cachedIdentity = identity
            return identity
        }

        let identity = NativeDeviceIdentity(
            signer: NativeDeviceIdentitySigner(),
            rendezvousID: .random(),
            ownerToken: .random()
        )
        let encoded = try encode(identity)
        do {
            try storage.insert(encoded)
        } catch let error as NativeDeviceIdentityStorageError
            where error == .keychain(errSecDuplicateItem)
        {
            guard let concurrentlyInserted = try storage.load() else {
                throw NativeDeviceIdentityStorageError.corruptIdentity
            }
            let winner = try decode(concurrentlyInserted)
            cachedIdentity = winner
            return winner
        }
        cachedIdentity = identity
        return identity
    }

    @discardableResult
    func reset() throws -> NativeDeviceIdentity {
        try storage.delete()
        cachedIdentity = nil
        return try loadOrCreate()
    }

    private func encode(_ identity: NativeDeviceIdentity) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(StoredIdentity(
            version: 1,
            signingPrivateKey: identity.signer.rawRepresentation,
            rendezvousID: identity.rendezvousID,
            ownerToken: identity.ownerToken
        ))
    }

    private func decode(_ data: Data) throws -> NativeDeviceIdentity {
        do {
            let stored = try JSONDecoder().decode(StoredIdentity.self, from: data)
            guard stored.version == 1 else {
                throw NativeDeviceIdentityStorageError.corruptIdentity
            }
            return NativeDeviceIdentity(
                signer: try NativeDeviceIdentitySigner(
                    rawRepresentation: stored.signingPrivateKey
                ),
                rendezvousID: stored.rendezvousID,
                ownerToken: stored.ownerToken
            )
        } catch let error as NativeDeviceIdentityStorageError {
            throw error
        } catch {
            throw NativeDeviceIdentityStorageError.corruptIdentity
        }
    }
}
