import Foundation
import OSLog

enum ClipLog {
    private static let subsystem = ApplicationDirectories.bundleIdentifier

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let storage = Logger(subsystem: subsystem, category: "storage")

    /// Logs state and operation metadata only. Call sites must never pass captured
    /// pixels, audio samples, file contents, or user-entered clip names.
    static func operation(
        _ name: StaticString,
        category logger: Logger,
        identifier: UUID? = nil
    ) {
        if let identifier {
            logger.info("Operation \(name) [\(identifier.uuidString, privacy: .private(mask: .hash))]")
        } else {
            logger.info("Operation \(name)")
        }
    }
}

