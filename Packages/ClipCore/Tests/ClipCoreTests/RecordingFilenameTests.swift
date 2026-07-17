import Foundation
import Testing
@testable import ClipCore

@Suite("Recording filenames")
struct RecordingFilenameTests {
    @Test("Timestamp names are stable in an injected time zone")
    func timestampFilename() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 17,
            hour: 10,
            minute: 42,
            second: 18
        )))

        let filename = RecordingFilename.timestamped(
            at: date,
            timeZone: try #require(TimeZone(secondsFromGMT: 0))
        )
        #expect(filename.stem == "clip-20260717-104218")
        #expect(filename.fileName == "clip-20260717-104218.mp4")
    }

    @Test("Filename templates expand every supported token in an injected time zone")
    func templateExpansionAndTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 17,
            hour: 22,
            minute: 5,
            second: 9
        )))
        let format = try RecordingFilenameTemplate(
            validating: "capture-YYYY-MM-DD_HH-mm-ss.mp4"
        )

        #expect(
            format.filename(
                at: date,
                timeZone: try #require(TimeZone(secondsFromGMT: 0))
            ).fileName == "capture-2026-07-17_22-05-09.mp4"
        )
        #expect(
            format.filename(
                at: date,
                timeZone: try #require(TimeZone(secondsFromGMT: 2 * 60 * 60))
            ).fileName == "capture-2026-07-18_00-05-09.mp4"
        )
    }

    @Test("Filename templates append and canonicalize the MP4 extension")
    func templateExtensionAndRoundTrip() throws {
        let withoutExtension = try RecordingFilenameTemplate(
            validating: "  demo-YYYYMMDD-HHmmss  "
        )
        let uppercaseExtension = try RecordingFilenameTemplate(
            validating: "demo-YYYYMMDD-HHmmss.MP4"
        )

        #expect(withoutExtension.format == "demo-YYYYMMDD-HHmmss.mp4")
        #expect(uppercaseExtension == withoutExtension)
        #expect(try jsonRoundTrip(withoutExtension) == withoutExtension)
        #expect(RecordingFilenameTemplate.supportedTokens == [
            "YYYY", "MM", "DD", "HH", "mm", "ss",
        ])
    }

    @Test("Unsafe filename templates are rejected before they can be persisted")
    func unsafeTemplates() {
        #expect(throws: RecordingFilenameError.empty) {
            try RecordingFilenameTemplate(validating: " .mp4 ")
        }
        #expect(throws: RecordingFilenameError.containsPathSeparator) {
            try RecordingFilenameTemplate(validating: "folder/clip-YYYY.mp4")
        }
        #expect(throws: RecordingFilenameError.containsPathSeparator) {
            try RecordingFilenameTemplate(validating: "disk:clip-YYYY.mp4")
        }
        #expect(throws: RecordingFilenameError.containsControlCharacter) {
            try RecordingFilenameTemplate(validating: "clip-\nYYYY.mp4")
        }
        #expect(throws: RecordingFilenameError.trailingPeriod) {
            try RecordingFilenameTemplate(validating: "clip-YYYY..mp4")
        }
        #expect(throws: RecordingFilenameError.tooLong(maximumUTF8Bytes: 240)) {
            try RecordingFilenameTemplate(
                validating: String(repeating: "é", count: 121) + ".mp4"
            )
        }
    }

    @Test("Every valid template expansion remains a validated MP4 filename")
    func allExpansionsRemainValid() throws {
        let dates = [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1_800_000_000),
            Date(timeIntervalSince1970: 4_102_444_799),
        ]
        let zones = [
            try #require(TimeZone(secondsFromGMT: -12 * 60 * 60)),
            try #require(TimeZone(secondsFromGMT: 0)),
            try #require(TimeZone(secondsFromGMT: 14 * 60 * 60)),
        ]
        let templates = [
            RecordingFilenameTemplate.default,
            try RecordingFilenameTemplate(validating: "DD-MM-YYYY ss.mm.HH.mp4"),
            try RecordingFilenameTemplate(validating: "static name.mp4"),
        ]

        for template in templates {
            for date in dates {
                for zone in zones {
                    let generated = template.filename(at: date, timeZone: zone)
                    #expect(generated.fileName.hasSuffix(".mp4"))
                    #expect(try RecordingFilename(validating: generated.fileName) == generated)
                }
            }
        }
    }

    @Test("Four-digit year expansion preserves the validated maximum length")
    func extremeYearPreservesLengthInvariant() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let farFuture = try #require(calendar.date(from: DateComponents(
            year: 12_000,
            month: 1,
            day: 1
        )))
        let template = try RecordingFilenameTemplate(
            validating: String(repeating: "a", count: 236) + "YYYY.mp4"
        )

        let generated = template.filename(at: farFuture, timeZone: calendar.timeZone)
        #expect(generated.stem.utf8.count == RecordingFilename.maximumStemUTF8ByteCount)
        #expect(generated.stem.hasSuffix("9999"))
        #expect(try RecordingFilename(validating: generated.fileName) == generated)
    }

    @Test("Rename trims whitespace and protects a single MP4 extension")
    func renameAndExtension() throws {
        let original = try RecordingFilename(validating: "clip-20260717-104218")
        let renamed = try original.renamed(to: "  Dashboard Filters.MP4  ")
        #expect(renamed.stem == "Dashboard Filters")
        #expect(renamed.fileName == "Dashboard Filters.mp4")
    }

    @Test("Filename validation rejects empty and reserved names")
    func emptyAndReserved() {
        #expect(throws: RecordingFilenameError.empty) {
            try RecordingFilename(validating: "  .mp4 ")
        }
        #expect(throws: RecordingFilenameError.reservedName) {
            try RecordingFilename(validating: "..")
        }
    }

    @Test("Filename validation rejects path separators, controls, and trailing periods")
    func unsafeCharacters() {
        #expect(throws: RecordingFilenameError.containsPathSeparator) {
            try RecordingFilename(validating: "folder/clip")
        }
        #expect(throws: RecordingFilenameError.containsPathSeparator) {
            try RecordingFilename(validating: "disk:clip")
        }
        #expect(throws: RecordingFilenameError.containsControlCharacter) {
            try RecordingFilename(validating: "clip\u{0000}name")
        }
        #expect(throws: RecordingFilenameError.trailingPeriod) {
            try RecordingFilename(validating: "clip.")
        }
    }

    @Test("Filename length is bounded by UTF-8 bytes, not grapheme count")
    func filenameLength() throws {
        let allowed = String(repeating: "a", count: RecordingFilename.maximumStemUTF8ByteCount)
        #expect(try RecordingFilename(validating: allowed).stem == allowed)

        let tooLong = String(repeating: "é", count: 121)
        #expect(throws: RecordingFilenameError.tooLong(maximumUTF8Bytes: 240)) {
            try RecordingFilename(validating: tooLong)
        }
    }

    @Test("Canonical Unicode names compare and encode consistently")
    func unicodeNormalizationAndRoundTrip() throws {
        let decomposed = "Cafe\u{301}"
        let filename = try RecordingFilename(validating: decomposed)
        #expect(filename.stem == "Café")
        #expect(try jsonRoundTrip(filename) == filename)
        #expect(filename.description == "Café.mp4")
    }

    @Test("Invalid filenames cannot enter through persisted JSON")
    func invalidFilenameJSON() {
        let data = Data(#""../escape.mp4""#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecordingFilename.self, from: data)
        }
    }
}
