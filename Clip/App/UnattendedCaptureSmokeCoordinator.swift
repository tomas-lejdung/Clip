@preconcurrency import AVFoundation
import AppKit
import ClipMedia
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
@preconcurrency import ScreenCaptureKit

struct UnattendedCaptureSmokeRequest: Equatable, Sendable {
    static let defaultDurationSeconds = 4.0
    static let minimumDurationSeconds = 3.0
    static let maximumDurationSeconds = 600.0

    let durationSeconds: Double
    let framesPerSecond: Int
    let preservesOutputForReview: Bool
}

enum UnattendedCaptureSmokeLaunch: Equatable, Sendable {
    case none
    case run(UnattendedCaptureSmokeRequest)
    case invalid

    static let modeArgument = "--unattended-real-capture-smoke"
    static let acknowledgementArgument = "--acknowledge-controlled-self-capture"
    static let durationArgumentPrefix = "--capture-smoke-duration="
    static let frameRateArgumentPrefix = "--capture-smoke-frame-rate="
    static let preserveOutputArgument = "--capture-smoke-preserve-output"
    static let environmentKey = "CLIP_RUN_UNATTENDED_CAPTURE_SMOKE"

    static func resolve(
        arguments: [String],
        environment: [String: String]
    ) -> UnattendedCaptureSmokeLaunch {
        let modeCount = arguments.count(where: { $0 == modeArgument })
        let acknowledgementCount = arguments.count(where: {
            $0 == acknowledgementArgument
        })
        let durationValues = values(for: durationArgumentPrefix, in: arguments)
        let frameRateValues = values(for: frameRateArgumentPrefix, in: arguments)
        let preserveOutputCount = arguments.count(where: {
            $0 == preserveOutputArgument
        })
        let hasSmokeArgument = modeCount > 0
            || acknowledgementCount > 0
            || !durationValues.isEmpty
            || !frameRateValues.isEmpty
            || preserveOutputCount > 0

        guard hasSmokeArgument else { return .none }
        guard modeCount == 1,
              acknowledgementCount == 1,
              environment[environmentKey] == "1",
              durationValues.count <= 1,
              frameRateValues.count <= 1,
              preserveOutputCount <= 1 else {
            return .invalid
        }

        let duration = durationValues.first.flatMap(Double.init)
            ?? UnattendedCaptureSmokeRequest.defaultDurationSeconds
        guard duration.isFinite,
              duration >= UnattendedCaptureSmokeRequest.minimumDurationSeconds,
              duration <= UnattendedCaptureSmokeRequest.maximumDurationSeconds else {
            return .invalid
        }

        let framesPerSecond = frameRateValues.first.flatMap(Int.init) ?? 30
        guard framesPerSecond == 30 || framesPerSecond == 60 else {
            return .invalid
        }
        return .run(UnattendedCaptureSmokeRequest(
            durationSeconds: duration,
            framesPerSecond: framesPerSecond,
            preservesOutputForReview: preserveOutputCount == 1
        ))
    }

    private static func values(for prefix: String, in arguments: [String]) -> [String] {
        arguments.compactMap { argument in
            guard argument.hasPrefix(prefix) else { return nil }
            return String(argument.dropFirst(prefix.count))
        }
    }
}

struct UnattendedCaptureSmokeMetrics: Codable, Equatable, Sendable {
    let fileSizeBytes: Int64
    let durationSeconds: Double
    let width: Int
    let height: Int
    let videoSampleCount: Int
    let averageFramesPerSecond: Double
    let maximumVideoTimestampGapSeconds: Double
    let maximumVideoTimestampGapStartSeconds: Double
    let maximumVideoTimestampGapEndSeconds: Double
    let metTwoFrameVideoGapTarget: Bool
    let h264ProfileIDC: Int
    let hasRec709ColorDescription: Bool
    /// Decoded frames inspected for visual fixture evidence (currently capped
    /// at 12); this is deliberately not an animation- or capture-frame count.
    let fixtureFrameCount: Int
    let fixtureMotionRangePixels: Double
    let maximumFineDetailEdgeRetention: Double
    let audioSampleBufferCount: Int
    let audioDecodedSampleCount: Int64
    let audioPeakAmplitude: Double
    let audioRMSAmplitude: Double
    let maximumAudioTimestampGapSeconds: Double
    let audioVideoStartOffsetSeconds: Double
    let audioVideoEndOffsetSeconds: Double
}

struct UnattendedCaptureSmokeReport: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let status: String
    let scope: String
    let requestedDurationSeconds: Double
    let requestedFramesPerSecond: Int
    let pauseDurationSeconds: Double
    let screenPermissionWasPreauthorized: Bool
    let previewFrameWasGenerated: Bool
    let copyWasByteIdentical: Bool
    let copyPasteboardResolvedFileURL: Bool
    let copiedFileWasDecodedAndEvaluated: Bool
    let outputWasDeleted: Bool
    let preservedOutputPath: String?
    let metrics: UnattendedCaptureSmokeMetrics?
    let failure: String?

    var passed: Bool { status == "passed" }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

enum UnattendedCaptureSmokeArtifactPolicy {
    static func shouldPreserveOutput(
        requested: Bool,
        runSucceeded: Bool,
        outputURL: URL?,
        fileManager: FileManager = .default
    ) -> Bool {
        requested
            && runSucceeded
            && outputURL.map { fileManager.fileExists(atPath: $0.path) } == true
    }

    @discardableResult
    static func deleteWorkDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        try? fileManager.removeItem(at: directory)
        // The parent is the smoke-only root. This succeeds only when no other
        // guarded run has left a directory there.
        try? fileManager.removeItem(at: directory.deletingLastPathComponent())
        return !fileManager.fileExists(atPath: directory.path)
    }
}

private enum UnattendedCaptureSmokeError: LocalizedError {
    case screenPermissionNotPreauthorized
    case anotherClipInstanceIsRunning
    case noDisplay
    case fixtureWindowUnavailable
    case firstFrameTimedOut
    case streamFailure(String)
    case invalidMedia(String)
    case previewGenerationFailed
    case copyContractFailed

    var errorDescription: String? {
        switch self {
        case .screenPermissionNotPreauthorized:
            "Screen Recording is not already authorized; the unattended lane never requests permission."
        case .anotherClipInstanceIsRunning:
            "Quit the other Clip instance before controlled self-capture so no other Clip window or audio can enter the test."
        case .noDisplay:
            "No active display is available for the controlled fixture window."
        case .fixtureWindowUnavailable:
            "ScreenCaptureKit did not expose the controlled fixture window."
        case .firstFrameTimedOut:
            "The controlled capture did not produce its first complete video frame."
        case let .streamFailure(message):
            "The controlled ScreenCaptureKit stream failed: \(message)"
        case let .invalidMedia(message):
            "The controlled recording failed validation: \(message)"
        case .previewGenerationFailed:
            "The controlled recording could not generate a decoded Preview frame."
        case .copyContractFailed:
            "The controlled recording failed its isolated local file-URL Copy contract."
        }
    }
}

private final class UnattendedCaptureSmokeEventLedger: @unchecked Sendable {
    struct Snapshot: Sendable {
        let receivedFirstVideoFrame: Bool
        let audioFailures: [String]
        let streamFailure: String?
    }

    private let lock = NSLock()
    private var receivedFirstVideoFrame = false
    private var audioFailures: [String] = []
    private var streamFailure: String?

    func receive(_ event: ScreenRecorderEvent) {
        lock.withLock {
            switch event {
            case .firstVideoSample:
                receivedFirstVideoFrame = true
            case let .audioSourceUnavailable(_, source, message):
                audioFailures.append("\(source.rawValue): \(message)")
            case let .failure(_, message):
                if streamFailure == nil {
                    streamFailure = message
                }
            }
        }
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                receivedFirstVideoFrame: receivedFirstVideoFrame,
                audioFailures: audioFailures,
                streamFailure: streamFailure
            )
        }
    }
}

@MainActor
final class UnattendedCaptureSmokeCoordinator {
    typealias Completion = @MainActor @Sendable (UnattendedCaptureSmokeReport) -> Void

    static let pauseDurationSeconds = 0.9

    private let request: UnattendedCaptureSmokeRequest
    private let completion: Completion
    private let fixtureView = UnattendedCaptureSmokeFixtureView(frame: .zero)
    private var window: NSWindow?
    private var animationLease: UnattendedCaptureSmokeAnimationLease?
    private var tonePlayer: UnattendedCaptureSmokeTonePlayer?
    private var recorder: ScreenRecorder?
    private var runTask: Task<Void, Never>?
    private var workDirectory: URL?

    init(
        request: UnattendedCaptureSmokeRequest,
        completion: @escaping Completion
    ) {
        self.request = request
        self.completion = completion
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await self.execute()
            self.runTask = nil
            self.completion(report)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        stopFixture()
        cleanupFiles()
    }

    private func execute() async -> UnattendedCaptureSmokeReport {
        let permissionWasPreauthorized = CaptureAuthorization.screenRecordingStatus == .authorized
        var metrics: UnattendedCaptureSmokeMetrics?
        var failure: String?
        var previewFrameWasGenerated = false
        var copyWasByteIdentical = false
        var copyPasteboardResolvedFileURL = false
        var copiedFileWasDecodedAndEvaluated = false
        var finalizedOutputURL: URL?

        do {
            let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
            guard !NSRunningApplication.runningApplications(
                withBundleIdentifier: ApplicationDirectories.bundleIdentifier
            ).contains(where: { $0.processIdentifier != ownProcessIdentifier }) else {
                throw UnattendedCaptureSmokeError.anotherClipInstanceIsRunning
            }
            guard permissionWasPreauthorized else {
                throw UnattendedCaptureSmokeError.screenPermissionNotPreauthorized
            }
            let target = try await prepareFixtureAndTarget()
            let outputURL = try prepareOutputURL()
            let ledger = UnattendedCaptureSmokeEventLedger()
            let recorder = ScreenRecorder(eventHandler: ledger.receive)
            self.recorder = recorder

            let configuration = RecordingConfiguration(
                width: target.width,
                height: target.height,
                framesPerSecond: request.framesPerSecond,
                showsCursor: false,
                audioMode: .system
            )
            try await recorder.start(ScreenRecordingRequest(
                displayID: target.displayID,
                includedWindowID: target.windowID,
                excludesCurrentProcessAudio: false,
                outputURL: outputURL,
                configuration: configuration
            ))
            try await waitForFirstVideoFrame(in: ledger)

            let beforePause = min(2.0, max(1.0, request.durationSeconds * 0.35))
            try await Task.sleep(for: .seconds(beforePause))
            try recorder.pause()
            try await Task.sleep(for: .seconds(Self.pauseDurationSeconds))
            try recorder.resume()
            try await Task.sleep(for: .seconds(request.durationSeconds - beforePause))

            if let streamFailure = ledger.snapshot.streamFailure {
                throw UnattendedCaptureSmokeError.streamFailure(streamFailure)
            }
            if !ledger.snapshot.audioFailures.isEmpty {
                throw UnattendedCaptureSmokeError.streamFailure(
                    ledger.snapshot.audioFailures.joined(separator: "; ")
                )
            }
            let finalizedURL = try await recorder.finish()
            finalizedOutputURL = finalizedURL
            self.recorder = nil
            stopFixture()
            metrics = try await UnattendedCaptureSmokeMediaValidator.validate(
                finalizedURL,
                expectedWidth: target.width,
                expectedHeight: target.height,
                expectedDurationSeconds: request.durationSeconds,
                expectedFramesPerSecond: request.framesPerSecond
            )
            previewFrameWasGenerated = try await generatePreviewFrame(from: finalizedURL)
            guard previewFrameWasGenerated else {
                throw UnattendedCaptureSmokeError.previewGenerationFailed
            }
            let copyEvidence = try await exerciseCopyContract(
                sourceURL: finalizedURL,
                expectedMetrics: metrics,
                target: target
            )
            copyWasByteIdentical = copyEvidence.wasByteIdentical
            copyPasteboardResolvedFileURL = copyEvidence.pasteboardResolvedFileURL
            copiedFileWasDecodedAndEvaluated = copyEvidence.wasDecodedAndEvaluated
            guard copyWasByteIdentical,
                  copyPasteboardResolvedFileURL,
                  copiedFileWasDecodedAndEvaluated else {
                throw UnattendedCaptureSmokeError.copyContractFailed
            }
        } catch is CancellationError {
            failure = "The controlled smoke capture was cancelled."
            if let recorder, recorder.isRecording {
                try? await recorder.cancel()
            }
            self.recorder = nil
        } catch {
            failure = error.localizedDescription
            if let recorder, recorder.isRecording {
                try? await recorder.cancel()
            }
            self.recorder = nil
        }

        stopFixture()
        let runSucceeded = failure == nil && metrics != nil
        let outputWasPreserved = UnattendedCaptureSmokeArtifactPolicy.shouldPreserveOutput(
            requested: request.preservesOutputForReview,
            runSucceeded: runSucceeded,
            outputURL: finalizedOutputURL
        )
        if !outputWasPreserved {
            cleanupFiles()
        }
        let outputWasDeleted = workDirectory == nil
        let preservedOutputPath = outputWasPreserved ? finalizedOutputURL?.path : nil
        let outputDispositionSucceeded = request.preservesOutputForReview
            ? preservedOutputPath != nil
            : outputWasDeleted
        return UnattendedCaptureSmokeReport(
            protocolVersion: 3,
            status: runSucceeded && outputDispositionSucceeded ? "passed" : "failed",
            scope: "single app-owned synthetic window and app-owned synthetic tone",
            requestedDurationSeconds: request.durationSeconds,
            requestedFramesPerSecond: request.framesPerSecond,
            pauseDurationSeconds: Self.pauseDurationSeconds,
            screenPermissionWasPreauthorized: permissionWasPreauthorized,
            previewFrameWasGenerated: previewFrameWasGenerated,
            copyWasByteIdentical: copyWasByteIdentical,
            copyPasteboardResolvedFileURL: copyPasteboardResolvedFileURL,
            copiedFileWasDecodedAndEvaluated: copiedFileWasDecodedAndEvaluated,
            outputWasDeleted: outputWasDeleted,
            preservedOutputPath: preservedOutputPath,
            metrics: metrics,
            failure: failure ?? (outputDispositionSucceeded
                ? nil
                : "Temporary output could not be finalized using the requested artifact policy.")
        )
    }

    private struct CaptureTarget {
        let displayID: CGDirectDisplayID
        let windowID: CGWindowID
        let width: Int
        let height: Int
    }

    private struct CopyEvidence {
        let wasByteIdentical: Bool
        let pasteboardResolvedFileURL: Bool
        let wasDecodedAndEvaluated: Bool
    }

    private func prepareFixtureAndTarget() async throws -> CaptureTarget {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            throw UnattendedCaptureSmokeError.noDisplay
        }
        NSApp.setActivationPolicy(.accessory)
        let contentSize = NSSize(width: 640, height: 360)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Clip Controlled Capture Smoke Fixture"
        window.identifier = NSUserInterfaceItemIdentifier("clip.captureSmoke.fixture")
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.contentView = fixtureView
        fixtureView.setFramesPerSecond(request.framesPerSecond)
        window.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - (contentSize.width / 2),
            y: screen.visibleFrame.midY - (contentSize.height / 2)
        ))
        window.orderFrontRegardless()
        self.window = window

        guard let frameRateRange = UnattendedCaptureSmokeAnimationPolicy
            .exactFrameRateRange(framesPerSecond: request.framesPerSecond) else {
            preconditionFailure("The launch guard accepts only 30 or 60 FPS.")
        }
        let displayLink = window.displayLink(
            target: fixtureView,
            selector: #selector(UnattendedCaptureSmokeFixtureView.displayLinkDidFire(_:))
        )
        displayLink.preferredFrameRateRange = frameRateRange
        displayLink.add(to: .main, forMode: .common)
        animationLease = UnattendedCaptureSmokeAnimationLease {
            displayLink.invalidate()
        }

        let tonePlayer = UnattendedCaptureSmokeTonePlayer()
        try tonePlayer.start()
        self.tonePlayer = tonePlayer

        fixtureView.layoutSubtreeIfNeeded()
        fixtureView.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let windowID = CGWindowID(window.windowNumber)
        guard content.windows.contains(where: { $0.windowID == windowID }),
              let display = content.displays.first(where: {
                  $0.displayID == CGDirectDisplayID(number.uint32Value)
              }) else {
            throw UnattendedCaptureSmokeError.fixtureWindowUnavailable
        }
        let scale = display.frame.width > 0
            ? Double(display.width) / display.frame.width
            : screen.backingScaleFactor
        return CaptureTarget(
            displayID: display.displayID,
            windowID: windowID,
            width: evenPixelCount(contentSize.width * scale),
            height: evenPixelCount(contentSize.height * scale)
        )
    }

    private func prepareOutputURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clip-Controlled-Capture-Smoke", isDirectory: true)
        // A prior process may have been force-terminated after the wrapper's
        // bounded timeout. This root is exclusive to synthetic smoke output;
        // clearing it before each guarded run prevents abandoned MP4 growth.
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let directory = root
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        workDirectory = directory
        return directory.appendingPathComponent("synthetic-capture.mp4")
    }

    private func generatePreviewFrame(from sourceURL: URL) async throws -> Bool {
        guard let directory = workDirectory else { return false }
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero else { return false }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 600)
        let requestedTime = CMTimeMultiplyByFloat64(duration, multiplier: 0.5)
        let generated = try await generator.image(at: requestedTime)
        let representation = NSBitmapImageRep(cgImage: generated.image)
        guard representation.pixelsWide > 0,
              representation.pixelsHigh > 0,
              let png = representation.representation(
                using: NSBitmapImageRep.FileType.png,
                properties: [:]
              ),
              !png.isEmpty else {
            return false
        }
        let previewURL = directory.appendingPathComponent("preview-frame.png")
        try png.write(to: previewURL, options: Data.WritingOptions.atomic)
        return FileManager.default.fileExists(atPath: previewURL.path)
    }

    private func exerciseCopyContract(
        sourceURL: URL,
        expectedMetrics: UnattendedCaptureSmokeMetrics?,
        target: CaptureTarget
    ) async throws -> CopyEvidence {
        guard let directory = workDirectory, let expectedMetrics else {
            return CopyEvidence(
                wasByteIdentical: false,
                pasteboardResolvedFileURL: false,
                wasDecodedAndEvaluated: false
            )
        }
        let copiedURL = directory.appendingPathComponent("preview-copy.mp4")
        try FileManager.default.copyItem(at: sourceURL, to: copiedURL)
        let byteIdentical = FileManager.default.contentsEqual(
            atPath: sourceURL.path,
            andPath: copiedURL.path
        )

        // A private pasteboard proves the same local file-URL payload used by
        // Preview Copy without replacing anything on the user's clipboard.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let wrotePasteboard = pasteboard.writeObjects([copiedURL as NSURL])
        let resolved = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { ($0 as? NSURL).map { $0 as URL } }.first
        let pasteboardResolved = wrotePasteboard
            && resolved?.standardizedFileURL == copiedURL.standardizedFileURL

        let copiedMetrics = try await UnattendedCaptureSmokeMediaValidator.validate(
            copiedURL,
            expectedWidth: target.width,
            expectedHeight: target.height,
            expectedDurationSeconds: request.durationSeconds,
            expectedFramesPerSecond: request.framesPerSecond
        )
        return CopyEvidence(
            wasByteIdentical: byteIdentical,
            pasteboardResolvedFileURL: pasteboardResolved,
            wasDecodedAndEvaluated: copiedMetrics == expectedMetrics
        )
    }

    private func waitForFirstVideoFrame(
        in ledger: UnattendedCaptureSmokeEventLedger
    ) async throws {
        for _ in 0..<150 {
            let snapshot = ledger.snapshot
            if snapshot.receivedFirstVideoFrame { return }
            if let failure = snapshot.streamFailure {
                throw UnattendedCaptureSmokeError.streamFailure(failure)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw UnattendedCaptureSmokeError.firstFrameTimedOut
    }

    private func stopFixture() {
        animationLease?.invalidate()
        animationLease = nil
        tonePlayer?.stop()
        tonePlayer = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }

    private func cleanupFiles() {
        guard let directory = workDirectory else { return }
        if UnattendedCaptureSmokeArtifactPolicy.deleteWorkDirectory(directory) {
            workDirectory = nil
        }
    }

    private func evenPixelCount(_ value: Double) -> Int {
        let count = max(2, Int(value.rounded()))
        return count.isMultiple(of: 2) ? count : count - 1
    }
}

@MainActor
private final class UnattendedCaptureSmokeFixtureView: NSView {
    private var frameNumber = 0
    private var framesPerSecond = 30

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func advanceFrame() {
        frameNumber += 1
        needsDisplay = true
        // `needsDisplay` is intentionally coalesced by AppKit. That is useful
        // for normal UI, but it makes this cadence fixture nondeterministic:
        // two display-link callbacks can otherwise become one window-surface
        // update before ScreenCaptureKit samples it. Render the new fixture
        // frame during the callback so every delivered display-link tick has
        // a distinct surface available to capture.
        displayIfNeeded()
    }

    @objc
    func displayLinkDidFire(_ displayLink: CADisplayLink) {
        advanceFrame()
    }

    func setFramesPerSecond(_ framesPerSecond: Int) {
        precondition(framesPerSecond == 30 || framesPerSecond == 60)
        self.framesPerSecond = framesPerSecond
    }

    override func draw(_ dirtyRect: NSRect) {
        let tile: CGFloat = 32
        for row in 0..<Int(ceil(bounds.height / tile)) {
            for column in 0..<Int(ceil(bounds.width / tile)) {
                ((row + column).isMultiple(of: 2)
                    ? NSColor(calibratedWhite: 0.9, alpha: 1)
                    : NSColor(calibratedWhite: 0.12, alpha: 1)).setFill()
                NSRect(
                    x: CGFloat(column) * tile,
                    y: CGFloat(row) * tile,
                    width: tile,
                    height: tile
                ).fill()
            }
        }

        let colors: [NSColor] = [
            .systemRed, .systemOrange, .systemYellow, .systemGreen,
            .systemCyan, .systemBlue, .systemPurple,
        ]
        let barWidth = (bounds.width - 40) / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSRect(
                x: 20 + CGFloat(index) * barWidth,
                y: 24,
                width: barWidth,
                height: 62
            ).fill()
        }

        drawFineDetailTarget()

        let travel = max(1, Int(bounds.width - 120))
        let period = travel * 2
        let motionPixels = Int(
            (Double(frameNumber) * 210 / Double(framesPerSecond)).rounded(.down)
        )
        let phase = motionPixels % period
        let offset = phase <= travel ? phase : period - phase
        // Use a calibrated magenta instead of the appearance-dependent
        // `systemPink` so decoded-pixel motion evidence is stable in both
        // light/dark appearance and across display color spaces.
        NSColor(
            calibratedRed: 0.98,
            green: 0.02,
            blue: 0.98,
            alpha: 1
        ).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 28 + CGFloat(offset), y: 145, width: 88, height: 88),
            xRadius: 14,
            yRadius: 14
        ).fill()

        NSColor.systemYellow.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 5, dy: 5))
        border.lineWidth = 10
        border.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .heavy),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black,
        ]
        NSString(format: "CONTROLLED FRAME %06d", frameNumber).draw(
            at: CGPoint(x: 22, y: bounds.height - 55),
            withAttributes: attributes
        )

        let scrollAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.cyan,
            .backgroundColor: NSColor.black,
        ]
        let scrollText = "SMALL SCROLL 30 60 FPS · FRAME \(frameNumber) · "
        let scrollWidth = NSString(string: scrollText).size(
            withAttributes: scrollAttributes
        ).width
        let cycle = max(1, bounds.width + scrollWidth)
        let scrollPixels = Double(frameNumber) * 120 / Double(framesPerSecond)
        NSString(string: scrollText).draw(
            at: CGPoint(
                x: bounds.width - CGFloat(scrollPixels).truncatingRemainder(dividingBy: cycle),
                y: bounds.height - 82
            ),
            withAttributes: scrollAttributes
        )
    }

    private func drawFineDetailTarget() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let pixel = 1 / max(1, scale)
        NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
        NSRect(x: 20, y: 100, width: 186, height: 38).fill()
        for pixelColumn in 0..<96 {
            (pixelColumn.isMultiple(of: 2) ? NSColor.white : NSColor.black).setFill()
            NSRect(
                x: 20 + CGFloat(pixelColumn) * pixel,
                y: 100,
                width: pixel,
                height: 38
            ).fill()
        }
        let edgeColors: [NSColor] = [.red, .green, .blue, .cyan, .magenta, .yellow]
        let colorStartX = 20 + (96 * pixel) + 8
        for (index, color) in edgeColors.enumerated() {
            color.setFill()
            NSRect(
                x: colorStartX + CGFloat(index) * 22,
                y: 100,
                width: 21,
                height: 38
            ).fill()
            (index.isMultiple(of: 2) ? NSColor.white : NSColor.black).setFill()
            NSRect(
                x: colorStartX + CGFloat(index) * 22,
                y: 100,
                width: pixel,
                height: 38
            ).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black,
        ]
        NSString(string: "1PX TEXT RGB 0123456789").draw(
            at: CGPoint(x: 218, y: 102),
            withAttributes: attributes
        )
    }
}

enum UnattendedCaptureSmokeAnimationPolicy {
    static func exactFrameRateRange(
        framesPerSecond: Int
    ) -> CAFrameRateRange? {
        guard framesPerSecond == 30 || framesPerSecond == 60 else { return nil }
        let cadence = Float(framesPerSecond)
        return CAFrameRateRange(
            minimum: cadence,
            maximum: cadence,
            preferred: cadence
        )
    }
}

@MainActor
final class UnattendedCaptureSmokeAnimationLease {
    private var invalidation: (() -> Void)?

    var isActive: Bool { invalidation != nil }

    init(invalidation: @escaping () -> Void) {
        self.invalidation = invalidation
    }

    func invalidate() {
        let invalidation = self.invalidation
        self.invalidation = nil
        invalidation?()
    }

    isolated deinit {
        invalidation?()
    }
}

@MainActor
private final class UnattendedCaptureSmokeTonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    func start() throws {
        let sampleRate = 48_000.0
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleRate)
        ), let channels = buffer.floatChannelData else {
            throw UnattendedCaptureSmokeError.invalidMedia(
                "The synthetic audio fixture could not allocate its buffer."
            )
        }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let sample = Float(sin(2 * Double.pi * 997 * Double(frame) / sampleRate)) * 0.025
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}

enum UnattendedCaptureSmokeTimelinePolicy {
    /// AVAssetReader can vend zero-sample segment markers before the first
    /// media sample and after the final sample. Their timestamps describe a
    /// boundary, not a frame or audio packet, so they must not participate in
    /// monotonicity or cadence validation.
    static func mediaPresentationTime(
        sampleCount: Int,
        presentationTime: CMTime
    ) -> CMTime? {
        guard sampleCount > 0 else { return nil }
        return presentationTime
    }

    static func meetsTwoFrameGapTarget(
        maximumGap: TimeInterval,
        framesPerSecond: Int
    ) -> Bool {
        guard maximumGap.isFinite,
              maximumGap >= 0,
              framesPerSecond == 30 || framesPerSecond == 60 else {
            return false
        }
        return maximumGap <= (2.0 / Double(framesPerSecond)) + 0.001
    }
}

private enum UnattendedCaptureSmokeMediaValidator {
    private struct Timeline {
        let count: Int
        let first: Double
        let last: Double
        let maximumGap: Double
        let maximumGapStart: Double
        let maximumGapEnd: Double
    }

    private struct AudioSignal {
        let sampleCount: Int64
        let peak: Double
        let rms: Double
    }

    private struct VideoEvidence {
        let fixtureFrames: Int
        let motionRange: Double
        let maximumFineDetailEdgeRetention: Double
    }

    static func validate(
        _ url: URL,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedDurationSeconds: Double,
        expectedFramesPerSecond: Int
    ) async throws -> UnattendedCaptureSmokeMetrics {
        let asset = AVURLAsset(url: url)
        async let durationValue = asset.load(.duration)
        async let playableValue = asset.load(.isPlayable)
        async let videoTracksValue = asset.loadTracks(withMediaType: .video)
        async let audioTracksValue = asset.loadTracks(withMediaType: .audio)
        let (duration, playable, videoTracks, audioTracks) = try await (
            durationValue, playableValue, videoTracksValue, audioTracksValue
        )
        guard playable, videoTracks.count == 1, audioTracks.count == 1 else {
            throw UnattendedCaptureSmokeError.invalidMedia(
                "Expected one playable video track and one system-audio track."
            )
        }
        let videoTrack = videoTracks[0]
        let audioTrack = audioTracks[0]
        async let sizeValue = videoTrack.load(.naturalSize)
        async let transformValue = videoTrack.load(.preferredTransform)
        async let videoFormatsValue = videoTrack.load(.formatDescriptions)
        async let audioFormatsValue = audioTrack.load(.formatDescriptions)
        let (size, transform, videoFormats, audioFormats) = try await (
            sizeValue, transformValue, videoFormatsValue, audioFormatsValue
        )
        let displayed = size.applying(transform)
        guard Int(abs(displayed.width).rounded()) == expectedWidth,
              Int(abs(displayed.height).rounded()) == expectedHeight,
              videoFormats.first.map(CMFormatDescriptionGetMediaSubType)
                == kCMVideoCodecType_H264,
              audioFormats.first.map(CMFormatDescriptionGetMediaSubType)
                == kAudioFormatMPEG4AAC else {
            throw UnattendedCaptureSmokeError.invalidMedia(
                "The output dimensions or H.264/AAC codecs were not preserved."
            )
        }

        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite,
              abs(durationSeconds - expectedDurationSeconds) <= 0.65 else {
            throw UnattendedCaptureSmokeError.invalidMedia(
                "Pause retiming produced an unexpected duration of \(durationSeconds) seconds."
            )
        }
        let videoTimeline = try scanTimeline(asset: asset, track: videoTrack)
        let audioTimeline = try scanTimeline(asset: asset, track: audioTrack)
        let averageFPS = videoTimeline.count > 1 && videoTimeline.last > videoTimeline.first
            ? Double(videoTimeline.count - 1) / (videoTimeline.last - videoTimeline.first)
            : 0
        let minimumVideoSamples = Int(
            (expectedDurationSeconds * Double(expectedFramesPerSecond) * 0.55).rounded(.down)
        )
        // ScreenCaptureKit commonly batches system audio into roughly 512 ms
        // sample buffers. Leave bounded scheduling headroom while the decoded
        // signal and both A/V endpoints below still prove continuous capture.
        let maximumAllowedAudioGap = 0.65
        guard videoTimeline.count >= minimumVideoSamples,
              averageFPS >= Double(expectedFramesPerSecond) * 0.55,
              videoTimeline.maximumGap <= 0.35,
              audioTimeline.count > 0,
              audioTimeline.maximumGap <= maximumAllowedAudioGap else {
            throw UnattendedCaptureSmokeError.invalidMedia(
                "Frame cadence or pause-adjusted sample timestamps were incomplete "
                    + "(video samples: \(videoTimeline.count), minimum: \(minimumVideoSamples), "
                    + "average FPS: \(averageFPS), maximum video gap: "
                    + "\(videoTimeline.maximumGap)s, audio buffers: \(audioTimeline.count), "
                    + "maximum audio gap: \(audioTimeline.maximumGap)s)."
            )
        }

        let startOffset = abs(videoTimeline.first - audioTimeline.first)
        let endOffset = abs(videoTimeline.last - audioTimeline.last)
        guard startOffset <= 0.5, endOffset <= 0.65 else {
            throw UnattendedCaptureSmokeError.invalidMedia(
                "Audio/video timelines diverged after pause and resume."
            )
        }
        let signal = try inspectAudioSignal(asset: asset, track: audioTrack)
        guard signal.sampleCount > 1_000,
              signal.peak >= 0.008,
              signal.rms >= 0.002 else {
            throw UnattendedCaptureSmokeError.invalidMedia(
                "The decoded system-audio track did not contain the synthetic tone."
            )
        }
        let evidence = try inspectVideoEvidence(asset: asset, track: videoTrack)
        guard evidence.fixtureFrames >= 3, evidence.motionRange >= 12 else {
            throw UnattendedCaptureSmokeError.invalidMedia(
                "Decoded pixels did not prove the animated controlled fixture "
                    + "(recognized frames: \(evidence.fixtureFrames), motion range: "
                    + "\(evidence.motionRange)px)."
            )
        }
        let fileSize = Int64(
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        guard fileSize > 0 else {
            throw UnattendedCaptureSmokeError.invalidMedia("The MP4 file was empty.")
        }
        guard let videoFormat = videoFormats.first,
              let h264ProfileIDC = h264ProfileIDC(videoFormat),
              h264ProfileIDC == 100,
              hasRec709ColorDescription(videoFormat) else {
            throw UnattendedCaptureSmokeError.invalidMedia(
                "The video did not preserve H.264 High profile Rec.709 metadata."
            )
        }
        return UnattendedCaptureSmokeMetrics(
            fileSizeBytes: fileSize,
            durationSeconds: durationSeconds,
            width: expectedWidth,
            height: expectedHeight,
            videoSampleCount: videoTimeline.count,
            averageFramesPerSecond: averageFPS,
            maximumVideoTimestampGapSeconds: videoTimeline.maximumGap,
            maximumVideoTimestampGapStartSeconds: videoTimeline.maximumGapStart,
            maximumVideoTimestampGapEndSeconds: videoTimeline.maximumGapEnd,
            metTwoFrameVideoGapTarget: UnattendedCaptureSmokeTimelinePolicy
                .meetsTwoFrameGapTarget(
                    maximumGap: videoTimeline.maximumGap,
                    framesPerSecond: expectedFramesPerSecond
                ),
            h264ProfileIDC: h264ProfileIDC,
            hasRec709ColorDescription: true,
            fixtureFrameCount: evidence.fixtureFrames,
            fixtureMotionRangePixels: evidence.motionRange,
            maximumFineDetailEdgeRetention: evidence.maximumFineDetailEdgeRetention,
            audioSampleBufferCount: audioTimeline.count,
            audioDecodedSampleCount: signal.sampleCount,
            audioPeakAmplitude: signal.peak,
            audioRMSAmplitude: signal.rms,
            maximumAudioTimestampGapSeconds: audioTimeline.maximumGap,
            audioVideoStartOffsetSeconds: startOffset,
            audioVideoEndOffsetSeconds: endOffset
        )
    }

    private static func scanTimeline(asset: AVAsset, track: AVAssetTrack) throws -> Timeline {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw UnattendedCaptureSmokeError.invalidMedia("A media timeline was unreadable.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw UnattendedCaptureSmokeError.invalidMedia("A media timeline could not start reading.")
        }
        var count = 0
        var first: Double?
        var last: Double?
        var maximumGap = 0.0
        var maximumGapStart: Double?
        var maximumGapEnd: Double?
        while let sample = output.copyNextSampleBuffer() {
            guard let presentationTime = UnattendedCaptureSmokeTimelinePolicy
                .mediaPresentationTime(
                    sampleCount: CMSampleBufferGetNumSamples(sample),
                    presentationTime: CMSampleBufferGetPresentationTimeStamp(sample)
                ) else {
                continue
            }
            guard presentationTime.isValid, presentationTime.isNumeric else {
                throw UnattendedCaptureSmokeError.invalidMedia(
                    "A media track contained an invalid timestamp."
                )
            }
            let value = presentationTime.seconds
            guard value.isFinite, last.map({ value > $0 }) ?? true else {
                throw UnattendedCaptureSmokeError.invalidMedia(
                    "A media track contained duplicate or backward timestamps."
                )
            }
            if let last {
                let gap = value - last
                if gap > maximumGap {
                    maximumGap = gap
                    maximumGapStart = last
                    maximumGapEnd = value
                }
            }
            first = first ?? value
            last = value
            count += 1
        }
        guard reader.status == .completed, let first, let last else {
            throw UnattendedCaptureSmokeError.invalidMedia("A media timeline was incomplete.")
        }
        return Timeline(
            count: count,
            first: first,
            last: last,
            maximumGap: maximumGap,
            maximumGapStart: maximumGapStart ?? first,
            maximumGapEnd: maximumGapEnd ?? first
        )
    }

    private static func inspectAudioSignal(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> AudioSignal {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        guard reader.canAdd(output) else {
            throw UnattendedCaptureSmokeError.invalidMedia("System audio could not be decoded.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw UnattendedCaptureSmokeError.invalidMedia("System-audio decoding could not start.")
        }
        var sampleCount: Int64 = 0
        var peak = 0.0
        var squares = 0.0
        let maximumSamples: Int64 = 480_000
        while sampleCount < maximumSamples, let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let floatCount = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var values = Array(repeating: Float.zero, count: floatCount)
            let status = values.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: bytes.count,
                    destination: bytes.baseAddress!
                )
            }
            guard status == noErr else { continue }
            for value in values where value.isFinite && sampleCount < maximumSamples {
                let amplitude = abs(Double(value))
                peak = max(peak, amplitude)
                squares += amplitude * amplitude
                sampleCount += 1
            }
        }
        reader.cancelReading()
        return AudioSignal(
            sampleCount: sampleCount,
            peak: peak,
            rms: sampleCount > 0 ? sqrt(squares / Double(sampleCount)) : 0
        )
    }

    private static func inspectVideoEvidence(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> VideoEvidence {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        guard reader.canAdd(output) else {
            throw UnattendedCaptureSmokeError.invalidMedia("Fixture video could not be decoded.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw UnattendedCaptureSmokeError.invalidMedia("Fixture decoding could not start.")
        }
        var fixtureFrames = 0
        var centroids: [Double] = []
        var maximumFineDetailEdgeRetention = 0.0
        while fixtureFrames < 12,
              let sample = output.copyNextSampleBuffer(),
              let pixels = CMSampleBufferGetImageBuffer(sample) {
            let evidence = inspectFixturePixels(pixels)
            if evidence.matches {
                fixtureFrames += 1
                if let centroid = evidence.motionCentroidX { centroids.append(centroid) }
                maximumFineDetailEdgeRetention = max(
                    maximumFineDetailEdgeRetention,
                    evidence.fineDetailEdgeRetention
                )
            }
        }
        reader.cancelReading()
        return VideoEvidence(
            fixtureFrames: fixtureFrames,
            motionRange: (centroids.max() ?? 0) - (centroids.min() ?? 0),
            maximumFineDetailEdgeRetention: maximumFineDetailEdgeRetention
        )
    }

    private static func inspectFixturePixels(
        _ pixelBuffer: CVPixelBuffer
    ) -> (matches: Bool, motionCentroidX: Double?, fineDetailEdgeRetention: Double) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return (false, nil, 0)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stride = max(1, min(width, height) / 160)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var families = Array(repeating: 0, count: 7)
        var light = 0
        var dark = 0
        var sampled = 0
        var pinkX = 0.0
        var pinkCount = 0
        for y in Swift.stride(from: 0, to: height, by: stride) {
            let row = bytes.advanced(by: y * rowBytes)
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let offset = x * 4
                let b = Int(row[offset])
                let g = Int(row[offset + 1])
                let r = Int(row[offset + 2])
                sampled += 1
                if r > 160, r > g + 50, r > b + 50 { families[0] += 1 }
                if r > 180, g > 70, g < 190, b < 105 { families[1] += 1 }
                if r > 170, g > 150, b < 130 { families[2] += 1 }
                if g > 130, g > r + 30, g > b + 20 { families[3] += 1 }
                if g > 135, b > 135, r < 155 { families[4] += 1 }
                if b > 140, b > r + 40, b > g + 25 { families[5] += 1 }
                if r > 100, b > 130, g < 145 { families[6] += 1 }
                let maximum = max(r, g, b)
                let minimum = min(r, g, b)
                if minimum > 180, maximum - minimum < 50 { light += 1 }
                if maximum < 80, maximum - minimum < 35 { dark += 1 }
                if y > height / 3, y < (height * 3) / 4,
                   r > 180, b > 180, g < 100,
                   r > g + 80, b > g + 80 {
                    pinkX += Double(x)
                    pinkCount += 1
                }
            }
        }
        let threshold = max(3, sampled / 6_000)
        let familyCount = families.count(where: { $0 >= threshold })
        return (
            familyCount >= 6 && light >= sampled / 30 && dark >= sampled / 30,
            pinkCount > 0 ? pinkX / Double(pinkCount) : nil,
            inspectFineDetailEdgeRetention(
                bytes: bytes,
                width: width,
                height: height,
                rowBytes: rowBytes
            )
        )
    }

    private static func h264ProfileIDC(_ description: CMFormatDescription) -> Int? {
        guard let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary?,
              let atoms = extensions[
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
              ] as? NSDictionary else {
            return nil
        }
        let configuration = (atoms["avcC"] as? Data)
            ?? (atoms["avcC"] as? NSData).map { $0 as Data }
        guard let configuration, configuration.count > 1 else { return nil }
        return Int(configuration[configuration.index(configuration.startIndex, offsetBy: 1)])
    }

    private static func hasRec709ColorDescription(
        _ description: CMFormatDescription
    ) -> Bool {
        guard let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary?
        else { return false }
        return (extensions[kCVImageBufferColorPrimariesKey] as? String)
            == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            && (extensions[kCVImageBufferTransferFunctionKey] as? String)
                == (kCVImageBufferTransferFunction_ITU_R_709_2 as String)
            && (extensions[kCVImageBufferYCbCrMatrixKey] as? String)
                == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    private static func inspectFineDetailEdgeRetention(
        bytes: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        rowBytes: Int
    ) -> Double {
        let scale = Double(width) / 640.0
        let startX = max(1, Int((20 * scale).rounded()))
        let startY = max(1, Int((100 * Double(height) / 360.0).rounded()))
        let endX = min(width - 2, startX + 95)
        let endY = min(
            height - 2,
            startY + max(1, Int((38 * Double(height) / 360.0).rounded()))
        )
        guard endX > startX, endY > startY else { return 0 }

        func luma(x: Int, y: Int) -> Double {
            let offset = (y * rowBytes) + (x * 4)
            return (0.2126 * Double(bytes[offset + 2]))
                + (0.7152 * Double(bytes[offset + 1]))
                + (0.0722 * Double(bytes[offset]))
        }

        var retained = 0
        var examined = 0
        let yStride = max(1, (endY - startY) / 8)
        for y in Swift.stride(from: startY + 1, to: endY, by: yStride) {
            for x in (startX + 1)...endX {
                examined += 1
                if abs(luma(x: x, y: y) - luma(x: x - 1, y: y)) >= 48 {
                    retained += 1
                }
            }
        }
        return examined > 0 ? Double(retained) / Double(examined) : 0
    }
}
