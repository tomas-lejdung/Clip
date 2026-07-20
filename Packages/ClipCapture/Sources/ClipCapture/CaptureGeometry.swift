import CoreVideo
import CoreMedia

enum CaptureFrameFreshnessPolicy {
    static let maximumFrameIntervals = 2.0
    private static let maximumComparableAgeSeconds = 60.0

    /// ScreenCaptureKit timestamps use the host clock on supported macOS
    /// versions. Invalid timestamps—or a value whose epoch is clearly not the
    /// host clock—are delivered rather than guessed stale.
    static func isStale(
        presentationTime: CMTime,
        hostTime: CMTime,
        framesPerSecond: Int
    ) -> Bool {
        guard presentationTime.isValid,
              !presentationTime.isIndefinite,
              hostTime.isValid,
              !hostTime.isIndefinite,
              framesPerSecond > 0 else {
            return false
        }
        let age = CMTimeGetSeconds(hostTime - presentationTime)
        guard age.isFinite,
              age >= 0,
              age <= maximumComparableAgeSeconds else {
            return false
        }
        return age > maximumFrameIntervals / Double(framesPerSecond)
    }
}

public enum CaptureFrameDimensionValidator {
    public static func validate(
        _ pixelBuffer: CVPixelBuffer,
        expectedWidth: Int,
        expectedHeight: Int,
        alternateExpectedWidth: Int? = nil,
        alternateExpectedHeight: Int? = nil
    ) throws {
        try validate(
            actualWidth: CVPixelBufferGetWidth(pixelBuffer),
            actualHeight: CVPixelBufferGetHeight(pixelBuffer),
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
            alternateExpectedWidth: alternateExpectedWidth,
            alternateExpectedHeight: alternateExpectedHeight
        )
    }

    public static func validate(
        actualWidth: Int,
        actualHeight: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        alternateExpectedWidth: Int? = nil,
        alternateExpectedHeight: Int? = nil
    ) throws {
        let matchesCurrent = actualWidth == expectedWidth && actualHeight == expectedHeight
        let matchesPending = alternateExpectedWidth == actualWidth
            && alternateExpectedHeight == actualHeight
        guard matchesCurrent || matchesPending else {
            throw CaptureSessionError.invalidFrameDimensions(
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
    }
}

enum CaptureFrameDimensionAction: Equatable {
    case deliver
    case dropRetired
}

/// Tracks the one geometry ScreenCaptureKit is allowed to retire after an
/// in-place configuration update.
///
/// `SCStream.updateConfiguration(_:)` can return before the stream-output
/// queue has drained frames produced with the previous dimensions. Those
/// frames must not reach the newly configured encoder, but treating the first
/// queued frame as corruption makes an otherwise successful codec switch fail.
/// Keep that exact previous geometry for two presentation-time intervals,
/// drop it as ordinary backpressure, and continue rejecting every third or
/// persistent geometry.
struct CaptureFrameDimensionTransitionState {
    static let retiredFrameIntervals: CMTimeValue = 2

    private struct RetiredGeometry {
        let width: Int
        let height: Int
        let discardThroughPresentationTime: CMTime
    }

    private var retired: RetiredGeometry?

    var hasRetiredGeometry: Bool {
        retired != nil
    }

    mutating func commit(
        previousWidth: Int,
        previousHeight: Int,
        currentWidth: Int,
        currentHeight: Int,
        commitPresentationTime: CMTime,
        framesPerSecond: Int
    ) {
        guard previousWidth != currentWidth || previousHeight != currentHeight,
              commitPresentationTime.isValid,
              !commitPresentationTime.isIndefinite else {
            retired = nil
            return
        }
        let clampedFrameRate = min(max(framesPerSecond, 1), Int(Int32.max))
        let graceDuration = CMTime(
            value: Self.retiredFrameIntervals,
            timescale: CMTimeScale(clampedFrameRate)
        )
        retired = RetiredGeometry(
            width: previousWidth,
            height: previousHeight,
            discardThroughPresentationTime: commitPresentationTime + graceDuration
        )
    }

    mutating func reset() {
        retired = nil
    }

    mutating func classify(
        actualWidth: Int,
        actualHeight: Int,
        presentationTime: CMTime,
        currentWidth: Int,
        currentHeight: Int,
        pendingWidth: Int? = nil,
        pendingHeight: Int? = nil
    ) throws -> CaptureFrameDimensionAction {
        let matchesCurrent = actualWidth == currentWidth && actualHeight == currentHeight
        let matchesPending = pendingWidth == actualWidth && pendingHeight == actualHeight

        if matchesCurrent || matchesPending {
            expireRetiredGeometry(after: presentationTime)
            return .deliver
        }

        if let retired,
           actualWidth == retired.width,
           actualHeight == retired.height,
           isAtOrBeforeRetiredCutoff(presentationTime, retired: retired) {
            return .dropRetired
        }

        expireRetiredGeometry(after: presentationTime)
        throw CaptureSessionError.invalidFrameDimensions(
            expectedWidth: currentWidth,
            expectedHeight: currentHeight,
            actualWidth: actualWidth,
            actualHeight: actualHeight
        )
    }

    private mutating func expireRetiredGeometry(after presentationTime: CMTime) {
        guard let retired,
              presentationTime.isValid,
              !presentationTime.isIndefinite,
              CMTimeCompare(
                  presentationTime,
                  retired.discardThroughPresentationTime
              ) > 0 else {
            return
        }
        self.retired = nil
    }

    private func isAtOrBeforeRetiredCutoff(
        _ presentationTime: CMTime,
        retired: RetiredGeometry
    ) -> Bool {
        guard presentationTime.isValid,
              !presentationTime.isIndefinite else {
            return false
        }
        return CMTimeCompare(
            presentationTime,
            retired.discardThroughPresentationTime
        ) <= 0
    }
}

public struct CaptureBackpressureCounter: Equatable, Sendable {
    public private(set) var statistics = CaptureDeliveryStatistics()

    public init() {}

    public mutating func record(_ disposition: CaptureFrameDisposition) {
        switch disposition {
        case .accepted:
            statistics.deliveredFrames += 1
        case .droppedBackpressure:
            statistics.backpressureDrops += 1
        }
    }
}

public enum CaptureBackpressureHealth: Equatable, Sendable {
    case nominal
    case sustainedOverload
}

/// Converts cumulative delivery counters into a deliberately conservative
/// overload signal. A single slow callback or short startup handoff is normal
/// for live capture, so callers act only on several consecutive pressured
/// samples and likewise require sustained recovery before clearing a warning.
public struct CaptureBackpressurePolicy: Equatable, Sendable {
    /// Production Live Share policy at its one-second sampling cadence:
    ///
    /// - at least 10 frame attempts must be observed in a sample;
    /// - at least 3 frames and 25% of attempts must be dropped;
    /// - 5 consecutive pressured samples surface overload;
    /// - 3 consecutive healthy samples clear overload.
    public static let sustainedLiveVideo = Self(
        minimumFrameAttemptsPerSample: 10,
        minimumDropsPerSample: 3,
        minimumDropFraction: 0.25,
        samplesToDeclareOverload: 5,
        samplesToRecover: 3
    )

    public let minimumFrameAttemptsPerSample: UInt64
    public let minimumDropsPerSample: UInt64
    public let minimumDropFraction: Double
    public let samplesToDeclareOverload: Int
    public let samplesToRecover: Int

    public init(
        minimumFrameAttemptsPerSample: UInt64,
        minimumDropsPerSample: UInt64,
        minimumDropFraction: Double,
        samplesToDeclareOverload: Int,
        samplesToRecover: Int
    ) {
        self.minimumFrameAttemptsPerSample = max(1, minimumFrameAttemptsPerSample)
        self.minimumDropsPerSample = max(1, minimumDropsPerSample)
        self.minimumDropFraction = min(max(minimumDropFraction, 0), 1)
        self.samplesToDeclareOverload = max(1, samplesToDeclareOverload)
        self.samplesToRecover = max(1, samplesToRecover)
    }
}

public struct CaptureBackpressureMonitor: Equatable, Sendable {
    public private(set) var health: CaptureBackpressureHealth = .nominal

    private let policy: CaptureBackpressurePolicy
    private var previousStatistics: CaptureDeliveryStatistics?
    private var consecutivePressureSamples = 0
    private var consecutiveRecoverySamples = 0

    public init(policy: CaptureBackpressurePolicy = .sustainedLiveVideo) {
        self.policy = policy
    }

    /// Observes monotonically increasing cumulative counters. The first value is
    /// a baseline. A counter reset starts a new baseline and immediately clears
    /// any warning so a replacement capture session cannot inherit old pressure.
    @discardableResult
    public mutating func observe(
        _ statistics: CaptureDeliveryStatistics
    ) -> CaptureBackpressureHealth {
        guard let previousStatistics else {
            self.previousStatistics = statistics
            return health
        }
        guard statistics.deliveredFrames >= previousStatistics.deliveredFrames,
              statistics.backpressureDrops >= previousStatistics.backpressureDrops else {
            reset(withBaseline: statistics)
            return health
        }

        self.previousStatistics = statistics
        let delivered = statistics.deliveredFrames - previousStatistics.deliveredFrames
        let dropped = statistics.backpressureDrops - previousStatistics.backpressureDrops
        let (attempted, overflow) = delivered.addingReportingOverflow(dropped)
        let frameAttempts = overflow ? UInt64.max : attempted
        guard frameAttempts >= policy.minimumFrameAttemptsPerSample else {
            // An idle or undersampled interval is neither evidence of overload
            // nor evidence that an existing overload has recovered.
            return health
        }

        let dropFraction = Double(dropped) / Double(frameAttempts)
        let isPressured = dropped >= policy.minimumDropsPerSample
            && dropFraction >= policy.minimumDropFraction
        if isPressured {
            consecutivePressureSamples = min(
                policy.samplesToDeclareOverload,
                consecutivePressureSamples + 1
            )
            consecutiveRecoverySamples = 0
            if consecutivePressureSamples >= policy.samplesToDeclareOverload {
                health = .sustainedOverload
            }
        } else {
            consecutivePressureSamples = 0
            guard health == .sustainedOverload else { return health }
            consecutiveRecoverySamples = min(
                policy.samplesToRecover,
                consecutiveRecoverySamples + 1
            )
            if consecutiveRecoverySamples >= policy.samplesToRecover {
                health = .nominal
                consecutiveRecoverySamples = 0
            }
        }
        return health
    }

    private mutating func reset(withBaseline baseline: CaptureDeliveryStatistics) {
        previousStatistics = baseline
        consecutivePressureSamples = 0
        consecutiveRecoverySamples = 0
        health = .nominal
    }
}
