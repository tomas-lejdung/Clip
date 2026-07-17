import Foundation

struct ManagedMP4FileInfo: Equatable, Sendable {
    let url: URL
    let byteCount: Int64
}

struct ManagedStorageArtifactInfo: Equatable, Sendable {
    let url: URL
    let modificationDate: Date
}

protocol ManagedHistoryFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    func itemExists(at url: URL) -> Bool
    func isRegularFile(at url: URL) -> Bool
    func dataIfPresent(at url: URL) throws -> Data?
    func writeAtomically(_ data: Data, to url: URL) throws
    func byteCount(of url: URL) throws -> Int64
    func copyItemAtomically(from sourceURL: URL, to destinationURL: URL) throws
    func replaceItemAtomically(
        from sourceURL: URL,
        to destinationURL: URL,
        preservingOriginalAt backupURL: URL?
    ) throws
    func removeItem(at url: URL) throws
    func managedMP4Files(in directory: URL) throws -> [ManagedMP4FileInfo]
    func directRegularFiles(in directory: URL) throws -> [ManagedStorageArtifactInfo]
}

/// Copies a complete file into a same-directory staging path before changing
/// the destination name. An existing destination is swapped with Foundation's
/// atomic replacement API, so a failed copy never truncates a user's file.
enum AtomicFileReplacement {
    static func replaceOrCreate(
        from sourceURL: URL,
        to destinationURL: URL,
        preservingOriginalAt backupURL: URL? = nil,
        fileManager: FileManager = .default,
        tokenGenerator: @Sendable () -> UUID = { UUID() }
    ) throws {
        if sameResolvedPath(sourceURL, destinationURL) {
            return
        }

        let destinationDirectory = destinationURL.deletingLastPathComponent().standardizedFileURL
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        if let backupURL {
            guard backupURL.deletingLastPathComponent().standardizedFileURL
                    == destinationDirectory,
                  !fileManager.fileExists(atPath: backupURL.path) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }

        let temporaryURL = destinationDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(tokenGenerator().uuidString.lowercased()).temporary"
        )
        guard !fileManager.fileExists(atPath: temporaryURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            let replacementOptions: FileManager.ItemReplacementOptions = backupURL == nil
                ? []
                : [.withoutDeletingBackupItem]
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: backupURL?.lastPathComponent,
                options: replacementOptions
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    static func sameResolvedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath()
            == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }
}

struct LiveManagedHistoryFileSystem: ManagedHistoryFileSystem {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isRegularFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    func byteCount(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    func copyItemAtomically(from sourceURL: URL, to destinationURL: URL) throws {
        try createDirectory(at: destinationURL.deletingLastPathComponent())
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).importing"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    func replaceItemAtomically(
        from sourceURL: URL,
        to destinationURL: URL,
        preservingOriginalAt backupURL: URL?
    ) throws {
        try AtomicFileReplacement.replaceOrCreate(
            from: sourceURL,
            to: destinationURL,
            preservingOriginalAt: backupURL
        )
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func managedMP4Files(in directory: URL) throws -> [ManagedMP4FileInfo] {
        guard itemExists(at: directory) else { return [] }
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [ManagedMP4FileInfo] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "mp4" {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append(
                ManagedMP4FileInfo(
                    url: url.standardizedFileURL,
                    byteCount: Int64(values.fileSize ?? 0)
                )
            )
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    func directRegularFiles(in directory: URL) throws -> [ManagedStorageArtifactInfo] {
        guard itemExists(at: directory) else { return [] }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modificationDate = values.contentModificationDate else {
                return nil
            }
            return ManagedStorageArtifactInfo(
                url: url.standardizedFileURL,
                modificationDate: modificationDate
            )
        }
        .sorted { $0.url.path < $1.url.path }
    }

    func dataIfPresent(at url: URL) throws -> Data? {
        guard itemExists(at: url) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic])
    }
}
