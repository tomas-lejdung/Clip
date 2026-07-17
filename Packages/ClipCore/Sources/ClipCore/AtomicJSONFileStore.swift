import Foundation

public enum AtomicJSONFileStoreError: Error, Equatable, Sendable {
    case destinationMustBeFileURL
}

public protocol AtomicFileSystem: Sendable {
    func dataIfPresent(at url: URL) async throws -> Data?
    func writeAtomically(_ data: Data, to url: URL) async throws
}

public struct LocalAtomicFileSystem: AtomicFileSystem {
    public init() {}

    public func dataIfPresent(at url: URL) async throws -> Data? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Deletion between the existence check and read is equivalent to a missing store.
            return nil
        }
    }

    public func writeAtomically(_ data: Data, to url: URL) async throws {
        let parentDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }
}

/// An actor-isolated JSON store that serializes all reads and atomic replacements.
public actor AtomicJSONFileStore<Value: Codable & Sendable> {
    public nonisolated let fileURL: URL
    private let fileSystem: any AtomicFileSystem

    public init(
        fileURL: URL,
        fileSystem: any AtomicFileSystem = LocalAtomicFileSystem()
    ) throws {
        guard fileURL.isFileURL else {
            throw AtomicJSONFileStoreError.destinationMustBeFileURL
        }
        self.fileURL = fileURL
        self.fileSystem = fileSystem
    }

    public func load() async throws -> Value? {
        guard let data = try await fileSystem.dataIfPresent(at: fileURL) else {
            return nil
        }
        return try Self.makeDecoder().decode(Value.self, from: data)
    }

    public func load(or defaultValue: Value) async throws -> Value {
        try await load() ?? defaultValue
    }

    public func save(_ value: Value) async throws {
        let data = try Self.makeEncoder().encode(value)
        try await fileSystem.writeAtomically(data, to: fileURL)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public typealias RecordingHistoryJSONStore = AtomicJSONFileStore<RecordingHistoryIndex>
public typealias SettingsJSONStore = AtomicJSONFileStore<ClipSettings>
