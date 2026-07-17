import Foundation

struct HelperStatus: Codable, Sendable {
    let service: String
    let status: String
    let protocolVersion: Int

    static let ready = HelperStatus(
        service: "ClipTestHelper",
        status: "ready",
        protocolVersion: 2
    )
}

struct MP4ValidationReport: Codable, Sendable {
    let protocolVersion: Int
    let valid: Bool
    let fileURL: String
    let fileSizeBytes: Int64
    let durationSeconds: Double
    let videoTrackCount: Int
    let audioTrackCount: Int
    let audioDurationSeconds: Double
    let audioEstimatedDataRate: Double
    let audioSampleCount: Int64
    let audioPeakAmplitude: Double
    let audioRMSAmplitude: Double
    let audioTracks: [AudioTrackValidationReport]
    let width: Int
    let height: Int
    let nominalFramesPerSecond: Double
    let videoCodec: String?
    let h264ProfileIDC: Int?
    let hasRec709ColorDescription: Bool
    let videoSampleCount: Int
    let firstVideoPresentationTimeSeconds: Double
    let lastVideoPresentationTimeSeconds: Double
    let maximumVideoTimestampGapSeconds: Double
    let audioCodec: String?
    let decodedVideoFrameCount: Int
    let deterministicFixtureFrameCount: Int
    let deterministicFixtureColorFamilyCount: Int
    let failure: String?
}

struct AudioTrackValidationReport: Codable, Sendable {
    let trackIndex: Int
    let durationSeconds: Double
    let estimatedDataRate: Double
    let sampleCount: Int64
    let peakAmplitude: Double
    let rmsAmplitude: Double
}

struct FixtureReadyReport: Codable, Sendable {
    let protocolVersion: Int
    let status: String
    let dropReceiverAccessibilityIdentifier: String
    let dropPointX: Double
    let dropPointY: Double
    let capturePointX: Double
    let capturePointY: Double
    let captureAreaStartX: Double
    let captureAreaStartY: Double
    let captureAreaEndX: Double
    let captureAreaEndY: Double
    let captureAreaExpectedWidthPixels: Int
    let captureAreaExpectedHeightPixels: Int
    let displayExpectedWidthPixels: Int
    let displayExpectedHeightPixels: Int
    let fixtureFramesPerSecond: Int
    let toneActive: Bool
    let failure: String?
}

struct AcceptanceSelfTestReport: Codable, Sendable {
    let protocolVersion: Int
    let success: Bool
    let generatedMP4URL: String
    let renderedFixturePNGURL: String
    let generatedMP4WasValid: Bool
    let invalidPayloadWasRejected: Bool
    let localPasteboardResolvedFileURL: Bool
    let failure: String?
}

enum HelperJSON {
    static func data<T: Encodable>(for value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func write<T: Encodable>(_ value: T, to outputURL: URL? = nil) throws {
        var data = try data(for: value)
        data.append(0x0A)

        if let outputURL {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL, options: .atomic)
        }
        FileHandle.standardOutput.write(data)
    }
}

enum HelperCommand: Sendable {
    case status
    case validateMP4(URL)
    case validatePasteboard
    case generateMP4(URL)
    case renderFixture(URL, frame: Int)
    case selfTest(workDirectory: URL)
    case fixture(FixtureOptions)
}

struct FixtureOptions: Sendable {
    let isAnimated: Bool
    let framesPerSecond: Int
    let playsTone: Bool
    let resultFileURL: URL?
    let readyFileURL: URL?
    let quitAfterSeconds: TimeInterval?
}

enum HelperArgumentsError: LocalizedError {
    case unknownArgument(String)
    case missingValue(String)
    case invalidValue(argument: String, value: String)
    case conflictingModes

    var errorDescription: String? {
        switch self {
        case let .unknownArgument(argument):
            "Unknown argument: \(argument)"
        case let .missingValue(argument):
            "Missing value after \(argument)."
        case let .invalidValue(argument, value):
            "Invalid value for \(argument): \(value)"
        case .conflictingModes:
            "Choose exactly one ClipTestHelper mode."
        }
    }
}

enum HelperArguments {
    static let usage = """
    Usage:
      ClipTestHelper [--status]
      ClipTestHelper --validate-mp4 PATH
      ClipTestHelper --validate-pasteboard
      ClipTestHelper --generate-mp4 PATH
      ClipTestHelper --render-fixture PATH [--frame NUMBER]
      ClipTestHelper --self-test --work-directory DIRECTORY
      ClipTestHelper --fixture [--static] [--fixture-fps 30|60] [--tone] [--result-file PATH] [--ready-file PATH] [--quit-after SECONDS]

    None of these modes requests Screen Recording, Microphone, Accessibility, or
    Automation permission. --tone plays a low-volume synthetic signal through the
    current output device. Real Clip capture is exercised only by separately
    guarded acceptance scripts.
    """

    static func parse(_ rawArguments: [String]) throws -> HelperCommand {
        let arguments = Array(rawArguments.dropFirst())
        guard !arguments.isEmpty else { return .status }

        var mode: HelperCommand?
        var frame = 45
        var fixtureIsAnimated = true
        var fixtureFramesPerSecond = 30
        var fixturePlaysTone = false
        var fixtureResultURL: URL?
        var fixtureReadyURL: URL?
        var fixtureQuitAfter: TimeInterval?
        var selfTestDirectory: URL?
        var index = 0

        func requireValue(after argument: String) throws -> String {
            let valueIndex = index + 1
            guard arguments.indices.contains(valueIndex) else {
                throw HelperArgumentsError.missingValue(argument)
            }
            return arguments[valueIndex]
        }

        func assignMode(_ newMode: HelperCommand) throws {
            guard mode == nil else { throw HelperArgumentsError.conflictingModes }
            mode = newMode
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--status":
                try assignMode(.status)

            case "--validate-mp4":
                let value = try requireValue(after: argument)
                try assignMode(.validateMP4(fileURL(value)))
                index += 1

            case "--validate-pasteboard":
                try assignMode(.validatePasteboard)

            case "--generate-mp4":
                let value = try requireValue(after: argument)
                try assignMode(.generateMP4(fileURL(value)))
                index += 1

            case "--render-fixture":
                let value = try requireValue(after: argument)
                try assignMode(.renderFixture(fileURL(value), frame: frame))
                index += 1

            case "--self-test":
                try assignMode(.selfTest(
                    workDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("clip-acceptance-\(UUID().uuidString)")
                ))

            case "--fixture":
                try assignMode(.fixture(FixtureOptions(
                    isAnimated: fixtureIsAnimated,
                    framesPerSecond: fixtureFramesPerSecond,
                    playsTone: fixturePlaysTone,
                    resultFileURL: fixtureResultURL,
                    readyFileURL: fixtureReadyURL,
                    quitAfterSeconds: fixtureQuitAfter
                )))

            case "--frame":
                let value = try requireValue(after: argument)
                guard let parsed = Int(value), parsed >= 0 else {
                    throw HelperArgumentsError.invalidValue(argument: argument, value: value)
                }
                frame = parsed
                index += 1

            case "--work-directory":
                let value = try requireValue(after: argument)
                selfTestDirectory = fileURL(value)
                index += 1

            case "--static":
                fixtureIsAnimated = false

            case "--fixture-fps":
                let value = try requireValue(after: argument)
                guard let parsed = Int(value), parsed == 30 || parsed == 60 else {
                    throw HelperArgumentsError.invalidValue(argument: argument, value: value)
                }
                fixtureFramesPerSecond = parsed
                index += 1

            case "--tone":
                fixturePlaysTone = true

            case "--result-file":
                let value = try requireValue(after: argument)
                fixtureResultURL = fileURL(value)
                index += 1

            case "--ready-file":
                let value = try requireValue(after: argument)
                fixtureReadyURL = fileURL(value)
                index += 1

            case "--quit-after":
                let value = try requireValue(after: argument)
                guard let parsed = TimeInterval(value), parsed > 0 else {
                    throw HelperArgumentsError.invalidValue(argument: argument, value: value)
                }
                fixtureQuitAfter = parsed
                index += 1

            case "--help", "-h":
                FileHandle.standardOutput.write(Data((usage + "\n").utf8))
                return .status

            default:
                throw HelperArgumentsError.unknownArgument(argument)
            }
            index += 1
        }

        guard let parsedMode = mode else {
            if selfTestDirectory != nil || !fixtureIsAnimated
                || fixtureFramesPerSecond != 30 || fixturePlaysTone
                || fixtureResultURL != nil
                || fixtureReadyURL != nil
                || fixtureQuitAfter != nil || frame != 45 {
                throw HelperArgumentsError.conflictingModes
            }
            return .status
        }
        switch parsedMode {
        case .renderFixture(let url, _):
            return .renderFixture(url, frame: frame)
        case .selfTest:
            return .selfTest(
                workDirectory: selfTestDirectory
                    ?? FileManager.default.temporaryDirectory
                        .appendingPathComponent("clip-acceptance-\(UUID().uuidString)")
            )
        case .fixture:
            return .fixture(FixtureOptions(
                isAnimated: fixtureIsAnimated,
                framesPerSecond: fixtureFramesPerSecond,
                playsTone: fixturePlaysTone,
                resultFileURL: fixtureResultURL,
                readyFileURL: fixtureReadyURL,
                quitAfterSeconds: fixtureQuitAfter
            ))
        default:
            if selfTestDirectory != nil || !fixtureIsAnimated
                || fixtureFramesPerSecond != 30 || fixturePlaysTone
                || fixtureResultURL != nil
                || fixtureReadyURL != nil
                || fixtureQuitAfter != nil || frame != 45 {
                throw HelperArgumentsError.conflictingModes
            }
            return parsedMode
        }
    }

    private static func fileURL(_ value: String) -> URL {
        URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            .standardizedFileURL
    }
}
