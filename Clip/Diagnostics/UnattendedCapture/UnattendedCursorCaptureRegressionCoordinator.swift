// App-target diagnostic entry point; see ../README.md.
import AppKit
import ClipCapture
import ClipMedia
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
@preconcurrency import ScreenCaptureKit

struct UnattendedCursorCaptureRegressionRequest: Equatable, Sendable {
    let preservesArtifacts: Bool
}

enum UnattendedCursorCaptureRegressionLaunch: Equatable, Sendable {
    case none
    case run(UnattendedCursorCaptureRegressionRequest)
    case invalid

    static let modeArgument = "--unattended-cursor-capture-regression"
    static let acknowledgementArgument = "--acknowledge-controlled-pointer-movement"
    static let preserveArtifactsArgument = "--cursor-regression-preserve-artifacts"
    static let environmentKey = "CLIP_RUN_UNATTENDED_CURSOR_CAPTURE_REGRESSION"

    static func resolve(
        arguments: [String],
        environment: [String: String]
    ) -> UnattendedCursorCaptureRegressionLaunch {
        let modeCount = arguments.count(where: { $0 == modeArgument })
        let acknowledgementCount = arguments.count(where: {
            $0 == acknowledgementArgument
        })
        let preserveCount = arguments.count(where: {
            $0 == preserveArtifactsArgument
        })
        let hasRegressionArgument = modeCount > 0
            || acknowledgementCount > 0
            || preserveCount > 0

        guard hasRegressionArgument else { return .none }
        guard modeCount == 1,
              acknowledgementCount == 1,
              preserveCount <= 1,
              environment[environmentKey] == "1" else {
            return .invalid
        }
        return .run(UnattendedCursorCaptureRegressionRequest(
            preservesArtifacts: preserveCount == 1
        ))
    }
}

enum ControlledCaptureLaunchConflictPolicy {
    static func conflicts(
        smoke: UnattendedCaptureSmokeLaunch,
        cursorRegression: UnattendedCursorCaptureRegressionLaunch
    ) -> Bool {
        guard smoke != .none, cursorRegression != .none else { return false }
        return true
    }
}

enum CursorCaptureRegressionVariant: String, Codable, CaseIterable, Sendable {
    case currentBest = "current-best"
    case candidateNominal = "candidate-nominal"

    var scalesToFit: Bool {
        true
    }

    var captureResolution: CaptureVideoResolution {
        switch self {
        case .currentBest:
            .best
        case .candidateNominal:
            .nominal
        }
    }
}

enum CursorCaptureRegressionPhase: String, Codable, CaseIterable, Sendable {
    case warmingUp = "warming-up"
    case cursorOutsideBaseline = "cursor-outside-baseline"
    case cursorOutsideMoving = "cursor-outside-moving"
    case cursorInsideStatic = "cursor-inside-static"
    case cursorInsideMoving = "cursor-inside-moving"
    case cursorOutsideRecovery = "cursor-outside-recovery"

    static let measuredCases: [CursorCaptureRegressionPhase] = [
        .cursorOutsideBaseline,
        .cursorOutsideMoving,
        .cursorInsideStatic,
        .cursorInsideMoving,
        .cursorOutsideRecovery,
    ]
}

struct CursorCaptureRegressionRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct CursorCaptureRegressionPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }
}

struct CursorCaptureRegressionDisplay: Codable, Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let frame: CursorCaptureRegressionRect
    let visibleFrame: CursorCaptureRegressionRect
    let quartzBounds: CursorCaptureRegressionRect
    let backingScaleFactor: Double
    let captureScaleFactor: Double
    let pixelWidth: Int
    let pixelHeight: Int
}

enum CursorCaptureRegressionDisplayPolicy {
    static let scaleTolerance = 0.15

    static func selectPreferredDisplay(
        from displays: [CursorCaptureRegressionDisplay]
    ) -> CursorCaptureRegressionDisplay? {
        let oneXDisplay = displays
            .filter {
                abs($0.backingScaleFactor - 1) <= scaleTolerance
                    && abs($0.captureScaleFactor - 1) <= scaleTolerance
            }
            .max {
                $0.visibleFrame.width * $0.visibleFrame.height
                    < $1.visibleFrame.width * $1.visibleFrame.height
            }
        if let oneXDisplay {
            return oneXDisplay
        }
        return displays
            .filter { $0.backingScaleFactor >= 1.75 }
            .max {
                $0.visibleFrame.width * $0.visibleFrame.height
                    < $1.visibleFrame.width * $1.visibleFrame.height
            }
    }
}

enum CursorCaptureRegressionCoordinatePolicy {
    static func quartzGlobalPoint(
        appKitGlobalPoint: CGPoint,
        screenFrame: CGRect,
        quartzBounds: CGRect
    ) -> CGPoint? {
        guard screenFrame.width > 0, screenFrame.height > 0,
              quartzBounds.width > 0, quartzBounds.height > 0 else {
            return nil
        }
        let normalizedX = (appKitGlobalPoint.x - screenFrame.minX)
            / screenFrame.width
        let normalizedY = (screenFrame.maxY - appKitGlobalPoint.y)
            / screenFrame.height
        return CGPoint(
            x: quartzBounds.minX + normalizedX * quartzBounds.width,
            y: quartzBounds.minY + normalizedY * quartzBounds.height
        )
    }
}

enum CursorCaptureRegressionImageMetrics {
    static func edgeContrast(
        luma: [UInt8],
        width: Int,
        height: Int
    ) -> Double {
        guard width > 1, height > 1, luma.count == width * height else {
            return 0
        }
        var total = 0.0
        var count = 0
        for row in 0..<height {
            let rowStart = row * width
            for column in 1..<width {
                total += abs(
                    Double(luma[rowStart + column])
                        - Double(luma[rowStart + column - 1])
                )
                count += 1
            }
        }
        for row in 1..<height {
            let rowStart = row * width
            let previousRowStart = (row - 1) * width
            for column in 0..<width {
                total += abs(
                    Double(luma[rowStart + column])
                        - Double(luma[previousRowStart + column])
                )
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return total / (Double(count) * 255)
    }

    static func meanAbsoluteDifference(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        let total = zip(lhs, rhs).reduce(into: 0.0) { result, values in
            result += abs(Double(values.0) - Double(values.1))
        }
        return total / (Double(lhs.count) * 255)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }
}

struct CursorCaptureRegressionFrameAttachments: Codable, Equatable, Sendable {
    let statusRawValue: Int?
    let status: String?
    let displayTime: UInt64?
    let scaleFactor: Double?
    let contentScale: Double?
    let contentRect: CursorCaptureRegressionRect?
    let dirtyRects: [CursorCaptureRegressionRect]
    let screenRect: CursorCaptureRegressionRect?
    let boundingRect: CursorCaptureRegressionRect?
    let presenterOverlayContentRect: CursorCaptureRegressionRect?
}

struct CursorCaptureRegressionFrameObservation: Codable, Equatable, Sendable {
    let variant: CursorCaptureRegressionVariant
    let phase: CursorCaptureRegressionPhase
    let presentationTimeSeconds: Double
    let width: Int
    let height: Int
    let pixelFormat: UInt32
    let edgeContrast: Double
    let baselineMeanAbsoluteDifference: Double?
    let attachments: CursorCaptureRegressionFrameAttachments
}

struct CursorCaptureRegressionPhaseSummary: Codable, Equatable, Sendable {
    let variant: CursorCaptureRegressionVariant
    let phase: CursorCaptureRegressionPhase
    let frameCount: Int
    let medianEdgeContrast: Double
    let minimumEdgeContrast: Double
    let medianBaselineMeanAbsoluteDifference: Double?
    let maximumBaselineMeanAbsoluteDifference: Double?
}

enum CursorCaptureRegressionSummaryPolicy {
    static func summaries(
        observations: [CursorCaptureRegressionFrameObservation]
    ) -> [CursorCaptureRegressionPhaseSummary] {
        CursorCaptureRegressionVariant.allCases.flatMap { variant in
            CursorCaptureRegressionPhase.measuredCases.map { phase in
                let matching = observations.filter {
                    $0.variant == variant && $0.phase == phase
                }
                let differences = matching.compactMap(
                    \.baselineMeanAbsoluteDifference
                )
                return CursorCaptureRegressionPhaseSummary(
                    variant: variant,
                    phase: phase,
                    frameCount: matching.count,
                    medianEdgeContrast: CursorCaptureRegressionImageMetrics
                        .median(matching.map(\.edgeContrast)),
                    minimumEdgeContrast: matching.map(\.edgeContrast).min() ?? 0,
                    medianBaselineMeanAbsoluteDifference: differences.isEmpty
                        ? nil
                        : CursorCaptureRegressionImageMetrics.median(differences),
                    maximumBaselineMeanAbsoluteDifference: differences.max()
                )
            }
        }
    }
}

struct CursorCaptureRegressionComparison: Codable, Equatable, Sendable {
    let currentMovingEdgeRetention: Double?
    let candidateMovingEdgeRetention: Double?
    let candidateMinusCurrentMovingEdgeRetention: Double?
}

struct UnattendedCursorCaptureRegressionReport: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let status: String
    let scope: String
    let screenPermissionWasPreauthorized: Bool
    let selectedDisplay: CursorCaptureRegressionDisplay?
    let activeDisplays: [CursorCaptureRegressionDisplay]
    let hasMixedScaleTopology: Bool
    let originalCursorPosition: CursorCaptureRegressionPoint?
    let restoredCursorPosition: CursorCaptureRegressionPoint?
    let cursorRestoreDistance: Double?
    let artifactDirectoryPath: String?
    let artifactFileNames: [String]
    let observations: [CursorCaptureRegressionFrameObservation]
    let phaseSummaries: [CursorCaptureRegressionPhaseSummary]
    let comparison: CursorCaptureRegressionComparison?
    let failure: String?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

private enum UnattendedCursorCaptureRegressionError: LocalizedError {
    case screenPermissionNotPreauthorized
    case anotherClipInstanceIsRunning
    case noSupportedDisplay
    case fixtureWindowUnavailable
    case invalidCaptureDimensions
    case cursorPositionUnavailable
    case cursorMoveFailed(CGError)
    case firstFrameTimedOut
    case incompletePhase(
        CursorCaptureRegressionVariant,
        CursorCaptureRegressionPhase
    )
    case streamFailed(String)
    case artifactWriteFailed

    var errorDescription: String? {
        switch self {
        case .screenPermissionNotPreauthorized:
            "Screen Recording is not already authorized; this unattended lane never requests permission."
        case .anotherClipInstanceIsRunning:
            "Quit every other Clip instance before running the cursor capture regression."
        case .noSupportedDisplay:
            "The cursor regression requires an active 1× or Retina display."
        case .fixtureWindowUnavailable:
            "ScreenCaptureKit did not expose the controlled fixture window."
        case .invalidCaptureDimensions:
            "The fixture did not resolve to its display's exact native backing dimensions."
        case .cursorPositionUnavailable:
            "The current global cursor position could not be read."
        case let .cursorMoveFailed(error):
            "The controlled pointer move failed with CoreGraphics error \(error.rawValue)."
        case .firstFrameTimedOut:
            "The raw ScreenCaptureKit stream did not deliver a frame in time."
        case let .incompletePhase(variant, phase):
            "The raw stream delivered too few frames for \(variant.rawValue)/\(phase.rawValue)."
        case let .streamFailed(message):
            "The raw ScreenCaptureKit stream failed: \(message)"
        case .artifactWriteFailed:
            "The bounded synthetic PNG/JSON artifacts could not be written."
        }
    }
}

private struct CursorCaptureRegressionOwnedFrame: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bgra: Data
}

private struct CursorCaptureRegressionContext: Hashable, Sendable {
    let variant: CursorCaptureRegressionVariant
    let phase: CursorCaptureRegressionPhase
}

private final class CursorCaptureRegressionFrameCollector: @unchecked Sendable {
    static let maximumObservations = 720

    private let lock = NSLock()
    private let detailRect: CGRect
    private let referenceFrameSize: CGSize
    private var context = CursorCaptureRegressionContext(
        variant: .currentBest,
        phase: .warmingUp
    )
    private var observations: [CursorCaptureRegressionFrameObservation] = []
    private var baselineLuma: [CursorCaptureRegressionVariant: [UInt8]] = [:]
    private var representativeFrames: [
        CursorCaptureRegressionContext: CursorCaptureRegressionOwnedFrame
    ] = [:]
    private var representativeEdgeContrast: [
        CursorCaptureRegressionContext: Double
    ] = [:]
    private var streamFailure: String?

    init(detailRect: CGRect, referenceFrameSize: CGSize) {
        self.detailRect = detailRect
        self.referenceFrameSize = referenceFrameSize
    }

    func setContext(
        variant: CursorCaptureRegressionVariant,
        phase: CursorCaptureRegressionPhase
    ) {
        lock.withLock {
            context = CursorCaptureRegressionContext(
                variant: variant,
                phase: phase
            )
        }
    }

    func receive(_ event: CaptureSessionEvent) {
        if case let .failed(_, error) = event {
            lock.withLock {
                if streamFailure == nil {
                    streamFailure = error.localizedDescription
                }
            }
        }
    }

    func receive(_ frame: BorrowedCaptureVideoFrame) -> CaptureFrameDisposition {
        guard CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
                == kCVPixelFormatType_32BGRA else {
            return .droppedBackpressure
        }
        CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(frame.pixelBuffer) else {
            return .droppedBackpressure
        }

        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(frame.pixelBuffer)
        let metricRect = CGRect(
            x: detailRect.minX * CGFloat(width) / referenceFrameSize.width,
            y: detailRect.minY * CGFloat(height) / referenceFrameSize.height,
            width: detailRect.width * CGFloat(width) / referenceFrameSize.width,
            height: detailRect.height * CGFloat(height) / referenceFrameSize.height
        )
        guard let luma = Self.copyLuma(
            from: baseAddress,
            bytesPerRow: bytesPerRow,
            width: width,
            height: height,
            rect: metricRect
        ) else {
            return .droppedBackpressure
        }
        let metricWidth = Int(metricRect.width.rounded(.down))
        let metricHeight = Int(metricRect.height.rounded(.down))
        let edgeContrast = CursorCaptureRegressionImageMetrics.edgeContrast(
            luma: luma,
            width: metricWidth,
            height: metricHeight
        )
        let frameContext = lock.withLock { context }
        let attachments = Self.attachments(from: frame.sampleBuffer)
        let shouldCopyRepresentative = lock.withLock {
            frameContext.phase != .warmingUp
                && edgeContrast
                    < (representativeEdgeContrast[frameContext] ?? .infinity)
        }
        let ownedFrame = shouldCopyRepresentative
            ? CursorCaptureRegressionOwnedFrame(
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                bgra: Data(bytes: baseAddress, count: bytesPerRow * height)
            )
            : nil

        lock.withLock {
            guard observations.count < Self.maximumObservations else { return }
            if frameContext.phase == .cursorOutsideBaseline,
               baselineLuma[frameContext.variant] == nil {
                baselineLuma[frameContext.variant] = luma
            }
            let difference = baselineLuma[frameContext.variant].flatMap {
                CursorCaptureRegressionImageMetrics.meanAbsoluteDifference($0, luma)
            }
            observations.append(CursorCaptureRegressionFrameObservation(
                variant: frameContext.variant,
                phase: frameContext.phase,
                presentationTimeSeconds: frame.presentationTime.seconds,
                width: width,
                height: height,
                pixelFormat: CVPixelBufferGetPixelFormatType(frame.pixelBuffer),
                edgeContrast: edgeContrast,
                baselineMeanAbsoluteDifference: difference,
                attachments: attachments
            ))
            if let ownedFrame,
               edgeContrast
                    < (representativeEdgeContrast[frameContext] ?? .infinity) {
                representativeFrames[frameContext] = ownedFrame
                representativeEdgeContrast[frameContext] = edgeContrast
            }
        }
        return .accepted
    }

    var snapshot: (
        observations: [CursorCaptureRegressionFrameObservation],
        frames: [CursorCaptureRegressionContext: CursorCaptureRegressionOwnedFrame],
        failure: String?
    ) {
        lock.withLock {
            (observations, representativeFrames, streamFailure)
        }
    }

    func frameCount(
        variant: CursorCaptureRegressionVariant,
        phase: CursorCaptureRegressionPhase
    ) -> Int {
        lock.withLock {
            observations.count {
                $0.variant == variant && $0.phase == phase
            }
        }
    }

    private static func copyLuma(
        from baseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        rect: CGRect
    ) -> [UInt8]? {
        let x = Int(rect.minX.rounded(.down))
        let y = Int(rect.minY.rounded(.down))
        let roiWidth = Int(rect.width.rounded(.down))
        let roiHeight = Int(rect.height.rounded(.down))
        guard x >= 0, y >= 0, roiWidth > 1, roiHeight > 1,
              x + roiWidth <= width, y + roiHeight <= height else {
            return nil
        }
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var result = [UInt8]()
        result.reserveCapacity(roiWidth * roiHeight)
        for row in y..<(y + roiHeight) {
            let rowAddress = bytes.advanced(by: row * bytesPerRow)
            for column in x..<(x + roiWidth) {
                let pixel = rowAddress.advanced(by: column * 4)
                let blue = UInt32(pixel[0])
                let green = UInt32(pixel[1])
                let red = UInt32(pixel[2])
                result.append(UInt8((54 * red + 183 * green + 19 * blue) >> 8))
            }
        }
        return result
    }

    private static func attachments(
        from sampleBuffer: CMSampleBuffer
    ) -> CursorCaptureRegressionFrameAttachments {
        let values = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        let value = values?.first ?? [:]
        let statusRawValue = (value[.status] as? NSNumber)?.intValue
        return CursorCaptureRegressionFrameAttachments(
            statusRawValue: statusRawValue,
            status: statusRawValue.flatMap(frameStatusName),
            displayTime: (value[.displayTime] as? NSNumber)?.uint64Value,
            scaleFactor: (value[.scaleFactor] as? NSNumber)?.doubleValue,
            contentScale: (value[.contentScale] as? NSNumber)?.doubleValue,
            contentRect: rect(from: value[.contentRect]).map(
                CursorCaptureRegressionRect.init
            ),
            dirtyRects: rects(from: value[.dirtyRects]).map(
                CursorCaptureRegressionRect.init
            ),
            screenRect: rect(from: value[.screenRect]).map(
                CursorCaptureRegressionRect.init
            ),
            boundingRect: rect(from: value[.boundingRect]).map(
                CursorCaptureRegressionRect.init
            ),
            presenterOverlayContentRect: rect(
                from: value[.presenterOverlayContentRect]
            ).map(CursorCaptureRegressionRect.init)
        )
    }

    private static func rect(from value: Any?) -> CGRect? {
        if let value = value as? NSValue {
            return value.rectValue
        }
        return nil
    }

    private static func rects(from value: Any?) -> [CGRect] {
        guard let values = value as? NSArray else { return [] }
        return values.compactMap(rect(from:))
    }

    private static func frameStatusName(_ rawValue: Int) -> String? {
        guard let status = SCFrameStatus(rawValue: rawValue) else { return nil }
        return switch status {
        case .started: "started"
        case .complete: "complete"
        case .idle: "idle"
        case .blank: "blank"
        case .suspended: "suspended"
        case .stopped: "stopped"
        @unknown default: "unknown"
        }
    }
}

@MainActor
private final class CursorCaptureRegressionPointerLease {
    let originalPosition: CGPoint
    private(set) var restoredPosition: CGPoint?
    private(set) var movedPointer = false

    init?() {
        guard let event = CGEvent(source: nil) else { return nil }
        originalPosition = event.location
    }

    func move(to point: CGPoint) throws {
        let result = CGWarpMouseCursorPosition(point)
        guard result == .success else {
            throw UnattendedCursorCaptureRegressionError.cursorMoveFailed(result)
        }
        movedPointer = true
    }

    @discardableResult
    func restore() -> CGPoint? {
        guard movedPointer else {
            restoredPosition = CGEvent(source: nil)?.location
            return restoredPosition
        }
        if CGWarpMouseCursorPosition(originalPosition) == .success {
            restoredPosition = CGEvent(source: nil)?.location
        }
        movedPointer = false
        return restoredPosition
    }
}

@MainActor
final class UnattendedCursorCaptureRegressionCoordinator {
    typealias Completion = @MainActor @Sendable (
        UnattendedCursorCaptureRegressionReport
    ) -> Void

    private static let fixtureSize = CGSize(width: 800, height: 450)
    private static let detailRect = CGRect(x: 32, y: 98, width: 256, height: 128)
    private static let cursorPointA = CGPoint(x: 535, y: 150)
    private static let cursorPointB = CGPoint(x: 690, y: 310)
    private static let minimumFramesPerPhase = 5

    private let request: UnattendedCursorCaptureRegressionRequest
    private let completion: Completion
    private let fixtureView = CursorCaptureRegressionFixtureView(
        frame: CGRect(origin: .zero, size: fixtureSize),
        detailRect: detailRect
    )
    private let collector = CursorCaptureRegressionFrameCollector(
        detailRect: detailRect,
        referenceFrameSize: fixtureSize
    )
    private var window: NSWindow?
    private var animationLease: UnattendedCaptureSmokeAnimationLease?
    private var captureSession: ScreenCaptureSession?
    private var pointerLease: CursorCaptureRegressionPointerLease?
    private var runTask: Task<Void, Never>?
    private var artifactDirectory: URL?

    init(
        request: UnattendedCursorCaptureRegressionRequest,
        completion: @escaping Completion
    ) {
        self.request = request
        self.completion = completion
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await execute()
            runTask = nil
            completion(report)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        if let captureSession, captureSession.isRunning {
            Task { try? await captureSession.stop() }
        }
        self.captureSession = nil
        pointerLease?.restore()
        pointerLease = nil
        stopFixture()
    }

    private func execute() async -> UnattendedCursorCaptureRegressionReport {
        let permissionWasPreauthorized =
            CaptureAuthorization.screenRecordingStatus == .authorized
        var displays: [CursorCaptureRegressionDisplay] = []
        var selectedDisplay: CursorCaptureRegressionDisplay?
        var originalCursorPosition: CGPoint?
        var restoredCursorPosition: CGPoint?
        var artifactFileNames: [String] = []
        var failure: String?
        var status = "failed"

        do {
            let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
            guard !NSRunningApplication.runningApplications(
                withBundleIdentifier: ApplicationDirectories.bundleIdentifier
            ).contains(where: { $0.processIdentifier != ownProcessIdentifier }) else {
                throw UnattendedCursorCaptureRegressionError
                    .anotherClipInstanceIsRunning
            }
            guard permissionWasPreauthorized else {
                throw UnattendedCursorCaptureRegressionError
                    .screenPermissionNotPreauthorized
            }

            let runtimeDisplays = try await loadRuntimeDisplays()
            displays = runtimeDisplays.map(\.report)
            guard let selected = selectRuntimeDisplay(from: runtimeDisplays) else {
                status = "skipped"
                throw UnattendedCursorCaptureRegressionError
                    .noSupportedDisplay
            }
            selectedDisplay = selected.report

            guard let pointerLease = CursorCaptureRegressionPointerLease() else {
                throw UnattendedCursorCaptureRegressionError
                    .cursorPositionUnavailable
            }
            self.pointerLease = pointerLease
            originalCursorPosition = pointerLease.originalPosition

            let target = try await prepareFixture(on: selected)
            for variant in CursorCaptureRegressionVariant.allCases {
                try await capture(
                    variant: variant,
                    target: target,
                    pointerLease: pointerLease
                )
            }
            restoredCursorPosition = pointerLease.restore()
            self.pointerLease = nil
            stopFixture()

            let snapshot = collector.snapshot
            if let streamFailure = snapshot.failure {
                throw UnattendedCursorCaptureRegressionError
                    .streamFailed(streamFailure)
            }
            for variant in CursorCaptureRegressionVariant.allCases {
                for phase in CursorCaptureRegressionPhase.measuredCases {
                    guard collector.frameCount(variant: variant, phase: phase)
                            >= Self.minimumFramesPerPhase else {
                        throw UnattendedCursorCaptureRegressionError
                            .incompletePhase(variant, phase)
                    }
                }
            }
            status = "passed"
        } catch is CancellationError {
            failure = "The controlled cursor capture regression was cancelled."
        } catch {
            failure = error.localizedDescription
        }

        if let captureSession, captureSession.isRunning {
            try? await captureSession.stop()
        }
        captureSession = nil
        if let pointerLease {
            restoredCursorPosition = pointerLease.restore()
            self.pointerLease = nil
        }
        stopFixture()

        let snapshot = collector.snapshot
        if request.preservesArtifacts {
            do {
                artifactFileNames = try writeArtifacts(
                    representativeFrames: snapshot.frames
                )
            } catch {
                status = "failed"
                failure = UnattendedCursorCaptureRegressionError
                    .artifactWriteFailed.localizedDescription
            }
        }
        let summaries = CursorCaptureRegressionSummaryPolicy.summaries(
            observations: snapshot.observations
        )
        if status == "passed",
           !Self.productionCapturePreservesDetail(
               summaries,
               observations: snapshot.observations,
               backingScaleFactor: selectedDisplay?.backingScaleFactor ?? 1
           ) {
            status = "failed"
            failure = "The production capture resolution did not preserve the fixture's native detail."
        }
        let comparison = makeComparison(summaries)
        let restoreDistance = originalCursorPosition.flatMap { original in
            restoredCursorPosition.map {
                Double(hypot($0.x - original.x, $0.y - original.y))
            }
        }
        // Quartz can report a fractional origin that the warp API restores to
        // the nearest addressable display coordinate. A 1.5-point diagonal
        // tolerance covers that quantization without accepting a visible move.
        if status == "passed", restoreDistance.map({ $0 > 1.5 }) == true {
            status = "failed"
            failure = "The original cursor position was not restored within 1.5 Quartz points."
        }

        var report = UnattendedCursorCaptureRegressionReport(
            protocolVersion: 1,
            status: status,
            scope: "raw pre-encoder ScreenCaptureKit frames from one synthetic native-scale window; topology is reported separately",
            screenPermissionWasPreauthorized: permissionWasPreauthorized,
            selectedDisplay: selectedDisplay,
            activeDisplays: displays,
            hasMixedScaleTopology: displays.contains {
                abs($0.backingScaleFactor - 1) <=
                    CursorCaptureRegressionDisplayPolicy.scaleTolerance
            } && displays.contains {
                $0.backingScaleFactor >= 1.75
            },
            originalCursorPosition: originalCursorPosition.map(
                CursorCaptureRegressionPoint.init
            ),
            restoredCursorPosition: restoredCursorPosition.map(
                CursorCaptureRegressionPoint.init
            ),
            cursorRestoreDistance: restoreDistance,
            artifactDirectoryPath: request.preservesArtifacts
                ? artifactDirectory?.path
                : nil,
            artifactFileNames: request.preservesArtifacts
                ? artifactFileNames + ["report.json"]
                : [],
            observations: snapshot.observations,
            phaseSummaries: summaries,
            comparison: comparison,
            failure: failure
        )
        if request.preservesArtifacts {
            do {
                try persistReport(report)
            } catch {
                report = UnattendedCursorCaptureRegressionReport(
                    protocolVersion: report.protocolVersion,
                    status: "failed",
                    scope: report.scope,
                    screenPermissionWasPreauthorized:
                        report.screenPermissionWasPreauthorized,
                    selectedDisplay: report.selectedDisplay,
                    activeDisplays: report.activeDisplays,
                    hasMixedScaleTopology: report.hasMixedScaleTopology,
                    originalCursorPosition: report.originalCursorPosition,
                    restoredCursorPosition: report.restoredCursorPosition,
                    cursorRestoreDistance: report.cursorRestoreDistance,
                    artifactDirectoryPath: report.artifactDirectoryPath,
                    artifactFileNames: report.artifactFileNames,
                    observations: report.observations,
                    phaseSummaries: report.phaseSummaries,
                    comparison: report.comparison,
                    failure: UnattendedCursorCaptureRegressionError
                        .artifactWriteFailed.localizedDescription
                )
            }
        } else {
            cleanupArtifacts()
        }
        return report
    }

    private struct RuntimeDisplay {
        let screen: NSScreen
        let captureDisplay: SCDisplay
        let report: CursorCaptureRegressionDisplay
    }

    private struct CaptureTarget {
        let windowID: CGWindowID
        let width: Int
        let height: Int
        let outsideCursorPoint: CGPoint
        let outsideCursorPointB: CGPoint
        let insideCursorPointA: CGPoint
        let insideCursorPointB: CGPoint
    }

    private func loadRuntimeDisplays() async throws -> [RuntimeDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber,
            let captureDisplay = content.displays.first(where: {
                $0.displayID == CGDirectDisplayID(number.uint32Value)
            }) else {
                return nil
            }
            let captureScale = captureDisplay.frame.width > 0
                ? Double(captureDisplay.width) / captureDisplay.frame.width
                : screen.backingScaleFactor
            let displayID = captureDisplay.displayID
            return RuntimeDisplay(
                screen: screen,
                captureDisplay: captureDisplay,
                report: CursorCaptureRegressionDisplay(
                    displayID: displayID,
                    frame: CursorCaptureRegressionRect(screen.frame),
                    visibleFrame: CursorCaptureRegressionRect(screen.visibleFrame),
                    quartzBounds: CursorCaptureRegressionRect(
                        CGDisplayBounds(displayID)
                    ),
                    backingScaleFactor: screen.backingScaleFactor,
                    captureScaleFactor: captureScale,
                    pixelWidth: captureDisplay.width,
                    pixelHeight: captureDisplay.height
                )
            )
        }
    }

    private func selectRuntimeDisplay(
        from displays: [RuntimeDisplay]
    ) -> RuntimeDisplay? {
        guard let selected = CursorCaptureRegressionDisplayPolicy
            .selectPreferredDisplay(from: displays.map(\.report)) else {
            return nil
        }
        return displays.first { $0.report.displayID == selected.displayID }
    }

    private func prepareFixture(
        on display: RuntimeDisplay
    ) async throws -> CaptureTarget {
        let visibleFrame = display.screen.visibleFrame
        guard visibleFrame.width >= Self.fixtureSize.width + 40,
              visibleFrame.height >= Self.fixtureSize.height + 40 else {
            throw UnattendedCursorCaptureRegressionError
                .noSupportedDisplay
        }

        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.fixtureSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: display.screen
        )
        window.title = "Clip Raw Cursor Capture Regression Fixture"
        window.identifier = NSUserInterfaceItemIdentifier(
            "clip.cursorCaptureRegression.fixture"
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.contentView = fixtureView
        window.setFrameOrigin(CGPoint(
            x: visibleFrame.midX - Self.fixtureSize.width / 2,
            y: visibleFrame.midY - Self.fixtureSize.height / 2
        ))
        window.orderFrontRegardless()
        self.window = window

        let displayLink = window.displayLink(
            target: fixtureView,
            selector: #selector(
                CursorCaptureRegressionFixtureView.displayLinkDidFire(_:)
            )
        )
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: 60,
            preferred: 60
        )
        displayLink.add(to: .main, forMode: .common)
        animationLease = UnattendedCaptureSmokeAnimationLease {
            displayLink.invalidate()
        }
        fixtureView.needsDisplay = true
        fixtureView.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let windowID = CGWindowID(window.windowNumber)
        guard content.windows.contains(where: { $0.windowID == windowID }) else {
            throw UnattendedCursorCaptureRegressionError.fixtureWindowUnavailable
        }
        let backingSize = fixtureView.convertToBacking(fixtureView.bounds).size
        let width = Int(backingSize.width.rounded())
        let height = Int(backingSize.height.rounded())
        let horizontalScale = Double(width) / Self.fixtureSize.width
        let verticalScale = Double(height) / Self.fixtureSize.height
        guard width > 0,
              height > 0,
              abs(horizontalScale - display.report.backingScaleFactor)
                <= CursorCaptureRegressionDisplayPolicy.scaleTolerance,
              abs(verticalScale - display.report.backingScaleFactor)
                <= CursorCaptureRegressionDisplayPolicy.scaleTolerance else {
            throw UnattendedCursorCaptureRegressionError.invalidCaptureDimensions
        }

        let screenFrame = display.report.frame.cgRect
        let quartzBounds = display.report.quartzBounds.cgRect
        let outsideAppKitPoint = CGPoint(
            x: visibleFrame.minX + 12,
            y: visibleFrame.minY + 12
        )
        let outsideBAppKitPoint = CGPoint(
            x: visibleFrame.maxX - 12,
            y: visibleFrame.minY + 12
        )
        let insideAAppKitPoint = CGPoint(
            x: window.frame.minX + Self.cursorPointA.x,
            y: window.frame.maxY - Self.cursorPointA.y
        )
        let insideBAppKitPoint = CGPoint(
            x: window.frame.minX + Self.cursorPointB.x,
            y: window.frame.maxY - Self.cursorPointB.y
        )
        guard let outside = CursorCaptureRegressionCoordinatePolicy
            .quartzGlobalPoint(
                appKitGlobalPoint: outsideAppKitPoint,
                screenFrame: screenFrame,
                quartzBounds: quartzBounds
            ),
            let insideA = CursorCaptureRegressionCoordinatePolicy
                .quartzGlobalPoint(
                    appKitGlobalPoint: insideAAppKitPoint,
                    screenFrame: screenFrame,
                    quartzBounds: quartzBounds
                ),
            let outsideB = CursorCaptureRegressionCoordinatePolicy
                .quartzGlobalPoint(
                    appKitGlobalPoint: outsideBAppKitPoint,
                    screenFrame: screenFrame,
                    quartzBounds: quartzBounds
                ),
            let insideB = CursorCaptureRegressionCoordinatePolicy
                .quartzGlobalPoint(
                    appKitGlobalPoint: insideBAppKitPoint,
                    screenFrame: screenFrame,
                    quartzBounds: quartzBounds
                ) else {
            throw UnattendedCursorCaptureRegressionError
                .invalidCaptureDimensions
        }
        return CaptureTarget(
            windowID: windowID,
            width: width,
            height: height,
            outsideCursorPoint: outside,
            outsideCursorPointB: outsideB,
            insideCursorPointA: insideA,
            insideCursorPointB: insideB
        )
    }

    private func capture(
        variant: CursorCaptureRegressionVariant,
        target: CaptureTarget,
        pointerLease: CursorCaptureRegressionPointerLease
    ) async throws {
        collector.setContext(variant: variant, phase: .warmingUp)
        try pointerLease.move(to: target.outsideCursorPoint)
        try await Task.sleep(for: .milliseconds(150))

        let session = ScreenCaptureSession(
            queueLabel: "com.tomaslejdung.clip.capture.cursor-regression.\(variant.rawValue)",
            frameConsumer: collector.receive,
            eventConsumer: collector.receive
        )
        captureSession = session
        do {
            try await session.start(CaptureSessionRequest(
                target: .window(id: target.windowID),
                video: CaptureVideoConfiguration(
                    width: target.width,
                    height: target.height,
                    framesPerSecond: 60,
                    showsCursor: true,
                    showsClickHighlights: false,
                    pixelFormat: .bgra,
                    scalesToFit: variant.scalesToFit,
                    captureResolution: variant.captureResolution
                )
            ))
            try await waitForFirstFrame(variant: variant)
            try await holdPhase(
                .cursorOutsideBaseline,
                variant: variant,
                duration: .milliseconds(500)
            )

            collector.setContext(variant: variant, phase: .cursorOutsideMoving)
            try await movePointer(
                pointerLease,
                from: target.outsideCursorPoint,
                to: target.outsideCursorPointB
            )

            try pointerLease.move(to: target.insideCursorPointA)
            try await Task.sleep(for: .milliseconds(120))
            try await holdPhase(
                .cursorInsideStatic,
                variant: variant,
                duration: .milliseconds(500)
            )

            collector.setContext(variant: variant, phase: .cursorInsideMoving)
            try await movePointer(
                pointerLease,
                from: target.insideCursorPointA,
                to: target.insideCursorPointB
            )

            try pointerLease.move(to: target.outsideCursorPoint)
            try await Task.sleep(for: .milliseconds(120))
            try await holdPhase(
                .cursorOutsideRecovery,
                variant: variant,
                duration: .milliseconds(500)
            )
            try await session.stop()
            captureSession = nil
        } catch {
            if session.isRunning {
                try? await session.stop()
            }
            captureSession = nil
            throw error
        }
    }

    private func movePointer(
        _ pointerLease: CursorCaptureRegressionPointerLease,
        from start: CGPoint,
        to end: CGPoint
    ) async throws {
        for step in 0..<48 {
            try Task.checkCancellation()
            let progress = Double(step) / 47
            let eased = 0.5 - cos(progress * .pi * 2) / 2
            try pointerLease.move(to: CGPoint(
                x: start.x + (end.x - start.x) * eased,
                y: start.y + (end.y - start.y) * eased
            ))
            try await Task.sleep(for: .milliseconds(17))
        }
    }

    private func waitForFirstFrame(
        variant: CursorCaptureRegressionVariant
    ) async throws {
        for _ in 0..<40 {
            try Task.checkCancellation()
            if collector.frameCount(variant: variant, phase: .warmingUp) > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw UnattendedCursorCaptureRegressionError.firstFrameTimedOut
    }

    private func holdPhase(
        _ phase: CursorCaptureRegressionPhase,
        variant: CursorCaptureRegressionVariant,
        duration: Duration
    ) async throws {
        collector.setContext(variant: variant, phase: phase)
        try await Task.sleep(for: duration)
    }

    private func writeArtifacts(
        representativeFrames: [
            CursorCaptureRegressionContext: CursorCaptureRegressionOwnedFrame
        ]
    ) throws -> [String] {
        guard request.preservesArtifacts else { return [] }
        let directory = try prepareArtifactDirectory()
        var fileNames: [String] = []
        for variant in CursorCaptureRegressionVariant.allCases {
            for phase in CursorCaptureRegressionPhase.measuredCases {
                let context = CursorCaptureRegressionContext(
                    variant: variant,
                    phase: phase
                )
                guard let frame = representativeFrames[context] else { continue }
                let fileName = "\(variant.rawValue)--\(phase.rawValue).png"
                try Self.writePNG(
                    frame,
                    to: directory.appendingPathComponent(fileName)
                )
                fileNames.append(fileName)
            }
        }
        return fileNames.sorted()
    }

    private func prepareArtifactDirectory() throws -> URL {
        if let artifactDirectory { return artifactDirectory }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Clip-Cursor-Capture-Regression",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let directory = root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        artifactDirectory = directory
        return directory
    }

    private func persistReport(
        _ report: UnattendedCursorCaptureRegressionReport
    ) throws {
        guard let artifactDirectory else {
            throw UnattendedCursorCaptureRegressionError.artifactWriteFailed
        }
        try report.encoded().write(
            to: artifactDirectory.appendingPathComponent("report.json"),
            options: [.atomic]
        )
    }

    private func cleanupArtifacts() {
        guard let artifactDirectory else { return }
        try? FileManager.default.removeItem(
            at: artifactDirectory.deletingLastPathComponent()
        )
        self.artifactDirectory = nil
    }

    private func stopFixture() {
        animationLease?.invalidate()
        animationLease = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    private func makeComparison(
        _ summaries: [CursorCaptureRegressionPhaseSummary]
    ) -> CursorCaptureRegressionComparison? {
        func retention(for variant: CursorCaptureRegressionVariant) -> Double? {
            guard let baseline = summaries.first(where: {
                $0.variant == variant && $0.phase == .cursorOutsideBaseline
            })?.medianEdgeContrast,
            let moving = summaries.first(where: {
                $0.variant == variant && $0.phase == .cursorInsideMoving
            })?.medianEdgeContrast,
            baseline > 0 else {
                return nil
            }
            return moving / baseline
        }
        let current = retention(for: .currentBest)
        let candidate = retention(for: .candidateNominal)
        guard current != nil || candidate != nil else { return nil }
        return CursorCaptureRegressionComparison(
            currentMovingEdgeRetention: current,
            candidateMovingEdgeRetention: candidate,
            candidateMinusCurrentMovingEdgeRetention: current.flatMap {
                currentValue in candidate.map { $0 - currentValue }
            }
        )
    }

    private static func productionCapturePreservesDetail(
        _ summaries: [CursorCaptureRegressionPhaseSummary],
        observations: [CursorCaptureRegressionFrameObservation],
        backingScaleFactor: Double
    ) -> Bool {
        let nativeScale = max(1, backingScaleFactor.rounded())
        let productionVariant: CursorCaptureRegressionVariant =
            nativeScale >= 2 ? .currentBest : .candidateNominal
        // The fixture alternates every logical point. A sharp Retina raster
        // therefore contains two identical backing pixels per point and half
        // as many adjacent transitions as its 1× counterpart.
        let minimumNativeEdgeContrast = 0.95 / nativeScale
        for phase in CursorCaptureRegressionPhase.measuredCases {
            guard let summary = summaries.first(where: {
                $0.variant == productionVariant && $0.phase == phase
            }),
            summary.medianEdgeContrast >= minimumNativeEdgeContrast,
            summary.minimumEdgeContrast >= minimumNativeEdgeContrast,
            (summary.maximumBaselineMeanAbsoluteDifference ?? 0) <= 0.01 else {
                return false
            }
        }
        let expectedWidth = Int((fixtureSize.width * nativeScale).rounded())
        let expectedHeight = Int((fixtureSize.height * nativeScale).rounded())
        let measuredPhases = Set(CursorCaptureRegressionPhase.measuredCases)
        let productionFrames = observations.filter {
            $0.variant == productionVariant && measuredPhases.contains($0.phase)
        }
        guard !productionFrames.isEmpty else { return false }
        return productionFrames.allSatisfy {
            $0.width == expectedWidth
                && $0.height == expectedHeight
                && abs(($0.attachments.scaleFactor ?? 0) - nativeScale) <= 0.15
                && abs(($0.attachments.contentScale ?? 0) - 1) <= 0.15
        }
    }

    private static func writePNG(
        _ frame: CursorCaptureRegressionOwnedFrame,
        to url: URL
    ) throws {
        guard let provider = CGDataProvider(data: frame.bgra as CFData),
              let image = CGImage(
                  width: frame.width,
                  height: frame.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: frame.bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let data = NSBitmapImageRep(cgImage: image).representation(
                  using: .png,
                  properties: [:]
              ) else {
            throw UnattendedCursorCaptureRegressionError.artifactWriteFailed
        }
        try data.write(to: url, options: [.atomic])
    }
}

@MainActor
private final class CursorCaptureRegressionFixtureView: NSView {
    private let detailRect: CGRect
    private let motionLayer = CALayer()
    private let counterLayer = CATextLayer()
    private var frameNumber = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    init(frame: CGRect, detailRect: CGRect) {
        self.detailRect = detailRect
        super.init(frame: frame)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.backgroundColor = NSColor.black.cgColor

        motionLayer.bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        motionLayer.cornerRadius = 12
        motionLayer.backgroundColor = NSColor.magenta.cgColor
        layer?.addSublayer(motionLayer)

        counterLayer.contentsScale = 1
        counterLayer.font = NSFont.monospacedDigitSystemFont(
            ofSize: 18,
            weight: .bold
        )
        counterLayer.fontSize = 18
        counterLayer.foregroundColor = NSColor.white.cgColor
        counterLayer.backgroundColor = NSColor.black.cgColor
        counterLayer.alignmentMode = .left
        counterLayer.frame = CGRect(x: 32, y: 392, width: 420, height: 28)
        layer?.addSublayer(counterLayer)
        advanceFrame()
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc
    func displayLinkDidFire(_ displayLink: CADisplayLink) {
        advanceFrame()
    }

    override func draw(_ dirtyRect: NSRect) {
        let tile: CGFloat = 32
        for row in 0..<Int(ceil(bounds.height / tile)) {
            for column in 0..<Int(ceil(bounds.width / tile)) {
                ((row + column).isMultiple(of: 2)
                    ? NSColor(calibratedWhite: 0.88, alpha: 1)
                    : NSColor(calibratedWhite: 0.1, alpha: 1)).setFill()
                CGRect(
                    x: CGFloat(column) * tile,
                    y: CGFloat(row) * tile,
                    width: tile,
                    height: tile
                ).fill()
            }
        }

        let colors: [NSColor] = [
            .red, .orange, .yellow, .green, .cyan, .blue, .magenta,
        ]
        let barWidth = (bounds.width - 64) / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.setFill()
            CGRect(
                x: 32 + CGFloat(index) * barWidth,
                y: 24,
                width: barWidth,
                height: 48
            ).fill()
        }

        for row in 0..<Int(detailRect.height) {
            for column in 0..<Int(detailRect.width) {
                ((row + column).isMultiple(of: 2)
                    ? NSColor.white
                    : NSColor.black).setFill()
                CGRect(
                    x: detailRect.minX + CGFloat(column),
                    y: detailRect.minY + CGFloat(row),
                    width: 1,
                    height: 1
                ).fill()
            }
        }
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black,
        ]
        NSString(string: "STATIC 1PX EDGE ROI · RAW SCK · 0123456789").draw(
            at: CGPoint(x: detailRect.minX, y: detailRect.maxY + 8),
            withAttributes: textAttributes
        )

        NSColor.systemYellow.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 5, dy: 5))
        border.lineWidth = 10
        border.stroke()
    }

    private func advanceFrame() {
        frameNumber += 1
        let travel = max(1, bounds.width - 130)
        let phase = CGFloat(frameNumber % 240) / 239
        let x = 30 + travel * (0.5 - cos(phase * .pi * 2) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        motionLayer.position = CGPoint(x: x + 36, y: 310)
        counterLayer.string = String(
            format: "RAW CURSOR FIXTURE · FRAME %06d", frameNumber
        )
        CATransaction.commit()
    }
}
