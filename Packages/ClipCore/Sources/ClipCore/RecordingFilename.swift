import Foundation

public enum RecordingFilenameError: Error, Equatable, Sendable {
    case empty
    case reservedName
    case containsPathSeparator
    case containsControlCharacter
    case trailingPeriod
    case tooLong(maximumUTF8Bytes: Int)
}

public struct RecordingFilename: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public static let maximumStemUTF8ByteCount = 240

    public let stem: String

    public init(validating userInput: String) throws {
        var candidate = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.lowercased().hasSuffix(".mp4") {
            candidate.removeLast(4)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        candidate = candidate.precomposedStringWithCanonicalMapping

        guard !candidate.isEmpty else {
            throw RecordingFilenameError.empty
        }
        guard candidate != ".", candidate != ".." else {
            throw RecordingFilenameError.reservedName
        }
        guard !candidate.contains("/"), !candidate.contains(":") else {
            throw RecordingFilenameError.containsPathSeparator
        }
        guard !candidate.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RecordingFilenameError.containsControlCharacter
        }
        guard !candidate.hasSuffix(".") else {
            throw RecordingFilenameError.trailingPeriod
        }
        guard candidate.utf8.count <= Self.maximumStemUTF8ByteCount else {
            throw RecordingFilenameError.tooLong(
                maximumUTF8Bytes: Self.maximumStemUTF8ByteCount
            )
        }
        self.stem = candidate
    }

    public var fileName: String { "\(stem).mp4" }
    public var description: String { fileName }

    public func renamed(to userInput: String) throws -> Self {
        try Self(validating: userInput)
    }

    public static func timestamped(at date: Date, timeZone: TimeZone) -> Self {
        RecordingFilenameTemplate.default.filename(at: date, timeZone: timeZone)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(validating: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid MP4 recording filename: \(error)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fileName)
    }
}

/// A validated, user-editable format for new recording names.
///
/// The syntax deliberately uses a small fixed set of case-sensitive tokens so
/// it remains understandable without exposing `DateFormatter` patterns:
/// `YYYY` (year), `MM` (month), `DD` (day), `HH` (24-hour), `mm` (minute), and
/// `ss` (second). Every token expands to the same number of UTF-8 bytes it
/// occupies in the template, so validation guarantees every generated name is
/// also a valid ``RecordingFilename``.
public struct RecordingFilenameTemplate: Codable, Equatable, Hashable, Sendable,
    CustomStringConvertible
{
    public static let supportedTokens = ["YYYY", "MM", "DD", "HH", "mm", "ss"]
    public static let `default` = try! Self(validating: "clip-YYYYMMDD-HHmmss.mp4")

    /// The canonical user-facing format, always including one final `.mp4`.
    public let format: String

    private let stemTemplate: String

    public init(validating userInput: String) throws {
        var candidate = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.lowercased().hasSuffix(".mp4") {
            candidate.removeLast(4)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        candidate = candidate.precomposedStringWithCanonicalMapping

        // Token expansions contain only fixed-width ASCII digits. Validating
        // the template as a filename stem therefore proves every expansion is
        // safe, including its length and path-component behavior.
        let validated = try RecordingFilename(validating: candidate)
        stemTemplate = validated.stem
        format = validated.fileName
    }

    public var description: String { format }

    public func filename(at date: Date, timeZone: TimeZone) -> RecordingFilename {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let replacements = [
            ("YYYY", fixedWidth(components.year, width: 4)),
            ("MM", fixedWidth(components.month, width: 2)),
            ("DD", fixedWidth(components.day, width: 2)),
            ("HH", fixedWidth(components.hour, width: 2)),
            ("mm", fixedWidth(components.minute, width: 2)),
            ("ss", fixedWidth(components.second, width: 2)),
        ]
        let renderedStem = replacements.reduce(stemTemplate) { partial, replacement in
            partial.replacingOccurrences(of: replacement.0, with: replacement.1)
        }

        // The initializer proves token substitution cannot make the stem
        // unsafe: every supported token is replaced by equal-width ASCII.
        return try! RecordingFilename(validating: renderedStem)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(validating: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid recording filename format: \(error)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(format)
    }

    private func fixedWidth(_ value: Int?, width: Int) -> String {
        let maximum = (0..<width).reduce(1) { result, _ in result * 10 } - 1
        let boundedValue = min(max(value ?? 0, 0), maximum)
        return String(
            format: "%0*d",
            locale: Locale(identifier: "en_US_POSIX"),
            width,
            boundedValue
        )
    }
}
