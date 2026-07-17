@preconcurrency import AVFoundation
import ClipMedia
import CoreMedia
import CoreVideo
import Darwin
import Foundation

private let fixtureWidth = 1_440
private let fixtureHeight = 900
private let fixtureFramesPerSecond = 30
private let fixtureDurationSeconds = 30
private let fixtureFrameCount = fixtureFramesPerSecond * fixtureDurationSeconds
private let previewTargetMilliseconds = 1_000.0
private let compactExportTargetMilliseconds = 2_000.0

@main
private enum ClipMediaPerformanceBenchmark {
    static func main() async throws {
        let options = try BenchmarkOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-performance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let syntheticFrames = try SyntheticScreenFrames(
            width: fixtureWidth,
            height: fixtureHeight,
            count: fixtureFramesPerSecond
        )
        var previewSamples: [Double] = []
        var sourceURL: URL?
        var sourceInspection: MediaInspection?

        for iteration in 0..<options.previewIterations {
            let candidateURL = workingDirectory
                .appendingPathComponent("reference-\(iteration)")
                .appendingPathExtension("mp4")
            let writer = try AssetWriterSession(
                outputURL: candidateURL,
                configuration: RecordingConfiguration(
                    width: fixtureWidth,
                    height: fixtureHeight,
                    framesPerSecond: fixtureFramesPerSecond,
                    showsCursor: false,
                    audioMode: .off
                )
            )
            try writer.start()
            for frameIndex in 0..<fixtureFrameCount {
                let sample = try syntheticFrames.sample(frameIndex: frameIndex)
                try appendWithRetry(sample, to: writer)
            }

            // Capture frames are encoded as they arrive. This interval starts at
            // the same native boundary as the user's Finish action: no more
            // samples remain to be submitted. It ends only once the MP4 is
            // finalized and AVFoundation can load the metadata Preview needs.
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await writer.finish()
            let inspection = try await MediaInspector.inspect(candidateURL)
            let elapsed = milliseconds(since: start)
            try validate(inspection, expectedPreset: nil)
            previewSamples.append(elapsed)
            sourceURL = candidateURL
            sourceInspection = inspection
        }

        guard let sourceURL, let sourceInspection else {
            throw BenchmarkError.missingReferenceFixture
        }
        let compactConfiguration = MediaExportConfigurationFactory.make(
            preset: .compact,
            sourceWidth: sourceInspection.width,
            sourceHeight: sourceInspection.height,
            sourceFramesPerSecond: Int(sourceInspection.nominalFramesPerSecond.rounded()),
            duration: sourceInspection.duration
        )

        var exportSamples: [Double] = []
        var exportByteCounts: [Int64] = []
        for iteration in 0..<options.exportIterations {
            let outputURL = workingDirectory
                .appendingPathComponent("compact-\(iteration)")
                .appendingPathExtension("mp4")
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await NativeAssetExporter().export(
                sourceURL: sourceURL,
                destinationURL: outputURL,
                timeRange: nil,
                configuration: compactConfiguration
            )
            let elapsed = milliseconds(since: start)
            let inspection = try await MediaInspector.inspect(outputURL)
            try validate(inspection, expectedPreset: compactConfiguration)
            exportSamples.append(elapsed)
            exportByteCounts.append(inspection.fileSize)
        }

        let summary = BenchmarkSummary(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            environment: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: machineArchitecture(),
                swiftVersion: "Swift 6 release benchmark"
            ),
            fixture: .init(
                width: fixtureWidth,
                height: fixtureHeight,
                framesPerSecond: fixtureFramesPerSecond,
                durationSeconds: fixtureDurationSeconds,
                frameCount: fixtureFrameCount,
                audio: "off",
                content: "deterministic low-motion synthetic screen UI",
                sourceByteCount: sourceInspection.fileSize
            ),
            previewMediaReadiness: MetricSummary(
                samplesMilliseconds: previewSamples,
                targetMilliseconds: previewTargetMilliseconds
            ),
            compactExport: MetricSummary(
                samplesMilliseconds: exportSamples,
                targetMilliseconds: compactExportTargetMilliseconds
            ),
            compactOutputByteCounts: exportByteCounts
        )

        printSummary(summary)
        if let outputURL = options.outputURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(summary)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL, options: .atomic)
            print("Evidence: \(outputURL.path)")
        }

        guard summary.passed else {
            throw BenchmarkError.performanceTargetMissed
        }
    }
}

private struct BenchmarkOptions {
    var previewIterations = 3
    var exportIterations = 5
    var outputURL: URL?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--preview-iterations":
                index += 1
                previewIterations = try Self.positiveInteger(arguments, at: index, for: argument)
            case "--export-iterations":
                index += 1
                exportIterations = try Self.positiveInteger(arguments, at: index, for: argument)
            case "--output":
                index += 1
                guard arguments.indices.contains(index) else {
                    throw BenchmarkError.invalidArguments("Missing path after \(argument)")
                }
                outputURL = URL(fileURLWithPath: arguments[index]).standardizedFileURL
            case "--help", "-h":
                print(
                    "Usage: ClipMediaPerformanceBenchmark "
                        + "[--preview-iterations N] [--export-iterations N] [--output PATH]"
                )
                Darwin.exit(EXIT_SUCCESS)
            default:
                throw BenchmarkError.invalidArguments("Unknown argument: \(argument)")
            }
            index += 1
        }
    }

    private static func positiveInteger(
        _ arguments: [String],
        at index: Int,
        for option: String
    ) throws -> Int {
        guard arguments.indices.contains(index),
              let value = Int(arguments[index]),
              value > 0 else {
            throw BenchmarkError.invalidArguments("\(option) requires a positive integer")
        }
        return value
    }
}

private struct BenchmarkSummary: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let environment: Environment
    let fixture: Fixture
    let previewMediaReadiness: MetricSummary
    let compactExport: MetricSummary
    let compactOutputByteCounts: [Int64]

    var passed: Bool {
        previewMediaReadiness.passesTarget && compactExport.passesTarget
    }

    struct Environment: Codable {
        let operatingSystem: String
        let architecture: String
        let swiftVersion: String
    }

    struct Fixture: Codable {
        let width: Int
        let height: Int
        let framesPerSecond: Int
        let durationSeconds: Int
        let frameCount: Int
        let audio: String
        let content: String
        let sourceByteCount: Int64
    }
}

private struct MetricSummary: Codable {
    let samplesMilliseconds: [Double]
    let targetMilliseconds: Double
    let minimumMilliseconds: Double
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    let passesTarget: Bool

    init(samplesMilliseconds: [Double], targetMilliseconds: Double) {
        precondition(!samplesMilliseconds.isEmpty)
        let sorted = samplesMilliseconds.sorted()
        self.samplesMilliseconds = samplesMilliseconds
        self.targetMilliseconds = targetMilliseconds
        minimumMilliseconds = sorted[0]
        medianMilliseconds = Self.percentile(0.5, in: sorted)
        p95Milliseconds = Self.percentile(0.95, in: sorted)
        maximumMilliseconds = sorted[sorted.count - 1]
        // Requiring every observed sample to remain below the target is
        // stronger than the product wording's "usually" requirement.
        passesTarget = maximumMilliseconds < targetMilliseconds
    }

    private static func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
        let rank = max(0, Int(ceil(percentile * Double(sorted.count))) - 1)
        return sorted[min(rank, sorted.count - 1)]
    }
}

private final class SyntheticScreenFrames {
    private let width: Int
    private let height: Int
    private let buffers: [CVPixelBuffer]
    private let formatDescription: CMVideoFormatDescription

    init(width: Int, height: Int, count: Int) throws {
        self.width = width
        self.height = height
        var generated: [CVPixelBuffer] = []
        generated.reserveCapacity(count)
        for index in 0..<count {
            generated.append(try Self.makePixelBuffer(
                width: width,
                height: height,
                phase: index,
                phaseCount: count
            ))
        }
        buffers = generated

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: generated[0],
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw BenchmarkError.cannotCreateFormatDescription(status)
        }
        formatDescription = description
    }

    func sample(frameIndex: Int) throws -> CMSampleBuffer {
        let duration = CMTime(value: 1, timescale: CMTimeScale(fixtureFramesPerSecond))
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(frameIndex),
                timescale: CMTimeScale(fixtureFramesPerSecond)
            ),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffers[frameIndex % buffers.count],
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw BenchmarkError.cannotCreateSampleBuffer(status)
        }
        return sample
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        phase: Int,
        phaseCount: Int
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw BenchmarkError.cannotCreatePixelBuffer(status)
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw BenchmarkError.missingPixelBufferMemory
        }
        let rowWords = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<UInt32>.size
        let pixels = baseAddress.assumingMemoryBound(to: UInt32.self)

        for y in 0..<height {
            let tileRow = y / 90
            for x in 0..<width {
                let tileColumn = x / 120
                pixels[(y * rowWords) + x] = (tileRow + tileColumn).isMultiple(of: 2)
                    ? 0xFF_26_29_2E
                    : 0xFF_E7_E9_EC
            }
        }
        fill(
            pixels,
            rowWords: rowWords,
            bounds: CGRect(x: 0, y: 0, width: width, height: 70),
            color: 0xFF_18_1A_1F
        )
        let travel = max(width - 260, 1)
        let movingX = 40 + ((phase * travel) / max(phaseCount - 1, 1))
        fill(
            pixels,
            rowWords: rowWords,
            bounds: CGRect(x: movingX, y: 210, width: 220, height: 130),
            color: 0xFF_FF_31_5A
        )
        return buffer
    }

    private static func fill(
        _ pixels: UnsafeMutablePointer<UInt32>,
        rowWords: Int,
        bounds: CGRect,
        color: UInt32
    ) {
        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            for x in Int(bounds.minX)..<Int(bounds.maxX) {
                pixels[(y * rowWords) + x] = color
            }
        }
    }
}

private func appendWithRetry(
    _ sample: CMSampleBuffer,
    to writer: AssetWriterSession
) throws {
    for _ in 0..<20_000 {
        if try writer.append(sample, kind: .video) {
            return
        }
        Thread.sleep(forTimeInterval: 0.0005)
    }
    throw BenchmarkError.writerBackPressureTimeout
}

private func validate(
    _ inspection: MediaInspection,
    expectedPreset: MediaExportConfiguration?
) throws {
    let expectedWidth = expectedPreset?.width ?? fixtureWidth
    let expectedHeight = expectedPreset?.height ?? fixtureHeight
    let expectedFPS = expectedPreset?.framesPerSecond ?? fixtureFramesPerSecond
    guard inspection.fileSize > 0,
          inspection.videoTrackCount == 1,
          inspection.audioTrackCount == 0,
          inspection.width == expectedWidth,
          inspection.height == expectedHeight,
          abs(inspection.nominalFramesPerSecond - Double(expectedFPS)) <= 0.1,
          abs(inspection.duration - Double(fixtureDurationSeconds))
            <= (1.0 / Double(expectedFPS)),
          inspection.videoCodec == kCMVideoCodecType_H264 else {
        throw BenchmarkError.invalidMedia(inspection)
    }
}

private func milliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func machineArchitecture() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafePointer(to: &systemInfo.machine) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
            String(cString: $0)
        }
    }
}

private func printSummary(_ summary: BenchmarkSummary) {
    print("Clip permission-free native performance benchmark")
    print(
        "Fixture: \(summary.fixture.durationSeconds)s, "
            + "\(summary.fixture.width)x\(summary.fixture.height)@"
            + "\(summary.fixture.framesPerSecond), H.264, audio off"
    )
    printMetric("Preview media readiness", summary.previewMediaReadiness)
    printMetric("Compact export", summary.compactExport)
    print("Result: \(summary.passed ? "PASS" : "FAIL")")
}

private func printMetric(_ name: String, _ metric: MetricSummary) {
    let samples = metric.samplesMilliseconds
        .map { String(format: "%.2f", $0) }
        .joined(separator: ", ")
    print("\(name) samples (ms): [\(samples)]")
    print(
        String(
            format: "%@ min/median/p95/max: %.2f / %.2f / %.2f / %.2f ms; target < %.0f ms — %@",
            name,
            metric.minimumMilliseconds,
            metric.medianMilliseconds,
            metric.p95Milliseconds,
            metric.maximumMilliseconds,
            metric.targetMilliseconds,
            metric.passesTarget ? "PASS" : "FAIL"
        )
    )
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case cannotCreatePixelBuffer(CVReturn)
    case missingPixelBufferMemory
    case cannotCreateFormatDescription(OSStatus)
    case cannotCreateSampleBuffer(OSStatus)
    case writerBackPressureTimeout
    case missingReferenceFixture
    case invalidMedia(MediaInspection)
    case performanceTargetMissed

    var description: String {
        switch self {
        case let .invalidArguments(message): message
        case let .cannotCreatePixelBuffer(status): "Cannot create pixel buffer (\(status))"
        case .missingPixelBufferMemory: "Pixel buffer has no accessible memory"
        case let .cannotCreateFormatDescription(status):
            "Cannot create video format description (\(status))"
        case let .cannotCreateSampleBuffer(status): "Cannot create sample buffer (\(status))"
        case .writerBackPressureTimeout: "Timed out waiting for the H.264 writer"
        case .missingReferenceFixture: "No reference fixture was produced"
        case let .invalidMedia(inspection): "Generated media validation failed: \(inspection)"
        case .performanceTargetMissed: "One or more performance targets were missed"
        }
    }
}
