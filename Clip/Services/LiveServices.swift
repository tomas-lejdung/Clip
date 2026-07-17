import Foundation

struct SystemClock: ClockServicing {
    var now: Date { Date() }

    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

struct LiveFileSystem: FileSystemServicing {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic])
    }
}

