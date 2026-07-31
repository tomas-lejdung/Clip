import Foundation

/// File-backed identity storage used only by the explicitly guarded native-v3
/// multi-instance acceptance lane.
///
/// Normal Clip launches continue to use `LiveNativeDeviceIdentityKeychain`.
/// Keeping the private identity under each participant's isolated temporary
/// state lets several copies of the same signed app act as different devices
/// without changing the app's bundle/signing identity (and therefore without
/// changing its Screen Recording permission identity).
final class IsolatedNativeDeviceIdentityFileStorage:
    NativeDeviceIdentitySecureStorage,
    @unchecked Sendable
{
    static let relativePath = "NativeV3MeshAcceptance/native-device-identity-v1.json"
    private static let maximumPayloadByteCount = 64 * 1_024

    let fileURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        fileURL: URL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func load() throws -> Data? {
        try lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let payloadSize = attributes[.size] as? NSNumber,
                  payloadSize.intValue <= Self.maximumPayloadByteCount else {
                throw NativeDeviceIdentityStorageError.corruptIdentity
            }
            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        }
    }

    func insert(_ data: Data) throws {
        guard data.count <= Self.maximumPayloadByteCount else {
            throw NativeDeviceIdentityStorageError.corruptIdentity
        }
        try lock.withLock {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            guard !fileManager.fileExists(atPath: fileURL.path) else {
                throw CocoaError(.fileWriteFileExists)
            }

            let stagingURL = directory.appendingPathComponent(
                ".native-device-identity-\(UUID().uuidString).tmp",
                isDirectory: false
            )
            defer { try? fileManager.removeItem(at: stagingURL) }
            try data.write(to: stagingURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: stagingURL.path
            )
            try fileManager.moveItem(at: stagingURL, to: fileURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: fileURL.path
            )
        }
    }

    func delete() throws {
        try lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            try fileManager.removeItem(at: fileURL)
        }
    }
}

extension AppLaunchConfiguration {
    func makeNativeDeviceIdentityStorage(
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> any NativeDeviceIdentitySecureStorage {
        switch nativeV3MeshAcceptanceRequest {
        case .none:
            return LiveNativeDeviceIdentityKeychain()

        case .invalid:
            throw AppLaunchConfigurationError.invalidNativeV3MeshAcceptanceRequest

        case .participant:
            guard mode == .nativeV3MeshAcceptance,
                  isolatedStateRoot != nil else {
                throw AppLaunchConfigurationError.invalidNativeV3MeshAcceptanceRequest
            }
            return IsolatedNativeDeviceIdentityFileStorage(
                fileURL: applicationSupportDirectory.appendingPathComponent(
                    IsolatedNativeDeviceIdentityFileStorage.relativePath,
                    isDirectory: false
                ),
                fileManager: fileManager
            )
        }
    }
}
