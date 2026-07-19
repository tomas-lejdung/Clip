import CoreVideo

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
