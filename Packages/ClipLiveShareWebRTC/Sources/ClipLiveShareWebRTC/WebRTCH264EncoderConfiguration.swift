import ClipLiveShare
import Foundation

/// The rate-control intent used by Clip's native H.264 encoder.
///
/// This is intentionally separate from libwebrtc's congestion controller.
/// The latter may lower the bitrate passed to the encoder at any time to keep
/// latency bounded; this value controls what VideoToolbox does inside that
/// effective network budget.
enum WebRTCH264EncodingMode: String, Equatable, Sendable {
    case quality
    case performance
}

enum WebRTCH264ProfileFamily: Equatable, Sendable {
    case constrainedHigh
    case high
    case main
    case constrainedBaseline
    case baseline

    init(profileLevelID: String) {
        let identifier = profileLevelID.lowercased()
        if identifier.hasPrefix("640c") {
            self = .constrainedHigh
        } else if identifier.hasPrefix("64") {
            self = .high
        } else if identifier.hasPrefix("4d") {
            self = .main
        } else if identifier.hasPrefix("42e0") {
            self = .constrainedBaseline
        } else {
            self = .baseline
        }
    }
}

extension WebRTCH264EncodingMode {
    init(_ mode: LiveShareEncodingMode) {
        switch mode {
        case .quality: self = .quality
        case .performance: self = .performance
        }
    }
}

struct WebRTCH264EncoderConfiguration: Equatable, Sendable {
    var mode: WebRTCH264EncodingMode
    var quality: Double
    var qualityTargetFraction: Double
    var performanceTargetFraction: Double
    var keyFrameIntervalSeconds: Int
    var maximumQuantizer: Int?

    init(
        mode: WebRTCH264EncodingMode = .quality,
        quality: Double = 0.98,
        qualityTargetFraction: Double = 1,
        performanceTargetFraction: Double = 1,
        keyFrameIntervalSeconds: Int = 2,
        maximumQuantizer: Int? = nil
    ) {
        precondition((0 ... 1).contains(quality))
        precondition((0 ... 1).contains(qualityTargetFraction))
        precondition((0 ... 1).contains(performanceTargetFraction))
        precondition(keyFrameIntervalSeconds > 0)
        precondition(maximumQuantizer.map { (0 ... 51).contains($0) } ?? true)
        self.mode = mode
        self.quality = quality
        self.qualityTargetFraction = qualityTargetFraction
        self.performanceTargetFraction = performanceTargetFraction
        self.keyFrameIntervalSeconds = keyFrameIntervalSeconds
        self.maximumQuantizer = maximumQuantizer
    }

    init(
        mode: WebRTCH264EncodingMode,
        advancedConfiguration: WebRTCH264AdvancedConfiguration
    ) {
        self.init(
            mode: mode,
            quality: advancedConfiguration.qualityFraction,
            keyFrameIntervalSeconds: advancedConfiguration.keyFrameIntervalSeconds,
            maximumQuantizer: advancedConfiguration.maximumQuantizer
        )
    }

    static let quality = Self()
    static let performance = Self(mode: .performance)
}

struct WebRTCH264BitrateEnvelope: Equatable, Sendable {
    let maximumBitrateBps: Int
    let initialBitrateBps: Int

    init(startKbit: UInt32, maximumKbit: UInt32, minimumKbit: UInt32) {
        let requestedStart = max(100_000, Int(max(startKbit, minimumKbit)) * 1_000)
        maximumBitrateBps = maximumKbit > 0
            ? max(100_000, Int(maximumKbit) * 1_000)
            : requestedStart
        initialBitrateBps = min(requestedStart, maximumBitrateBps)
    }

    func clamped(_ requestedBitsPerSecond: Int) -> Int {
        min(max(100_000, requestedBitsPerSecond), maximumBitrateBps)
    }
}

enum WebRTCH264BitratePolicy {
    /// The user's selected Mbps is VideoToolbox's soft
    /// target, while WebRTC adapts delivery with its frame dropper and pacer.
    /// Performance follows WebRTC's current estimate inside that ceiling.
    static func encoderTargetBitsPerSecond(
        mode: WebRTCH264EncodingMode,
        configuredMaximumBitrateBps: Int,
        networkTargetBitrateBps: Int
    ) -> Int {
        let configuredMaximum = max(100_000, configuredMaximumBitrateBps)
        let networkTarget = min(
            configuredMaximum,
            max(100_000, networkTargetBitrateBps)
        )
        return mode == .quality ? configuredMaximum : networkTarget
    }
}

enum WebRTCH264SessionUpdatePolicy {
    static func requiresImmediateRebuild(
        current: WebRTCH264RateControlPlan,
        currentFramesPerSecond _: Int,
        requested: WebRTCH264RateControlPlan,
        requestedFramesPerSecond _: Int
    ) -> Bool {
        current.mode != requested.mode
    }

}

/// Explicit latency constraints shared by session construction and tests.
/// VideoToolbox may internally hold one frame, while Clip permits at most two
/// accepted submissions so a transient hardware stall cannot grow into a
/// seconds-long queue.
struct WebRTCH264LatencyPolicy: Equatable, Sendable {
    static let maximumFrameDelayCount = 1
    static let suggestedLookAheadFrameCount = 0
    static let maximumInFlightFrames = 2
    static let maximumSupportedFramesPerSecond = 60
    static let minimumOutputAgeNanoseconds: UInt64 = 100_000_000

    static func maximumOutputAgeNanoseconds(framesPerSecond: Int) -> UInt64 {
        let cadence = UInt64(max(1, framesPerSecond))
        let twoSeconds: UInt64 = 2_000_000_000
        let twoFrameIntervals = (twoSeconds + cadence - 1) / cadence
        // Two frames is an appropriate admission bound, but 33 ms at 60 FPS
        // is too short as an asynchronous hardware callback deadline. A
        // current encode that completes inside 100 ms is still useful and
        // should not force an IDR/session-rebuild cycle.
        return max(minimumOutputAgeNanoseconds, twoFrameIntervals)
    }

    /// Clip's frame source stamps `RTCVideoFrame` with the same monotonic
    /// uptime clock used here. A negative or future value cannot belong to
    /// that clock domain, so start its latency budget at admission rather than
    /// fabricating an age. Valid older values deliberately retain upstream
    /// WebRTC queue time in the two-frame deadline.
    static func admittedUptimeNanoseconds(
        frameTimestampNanoseconds: Int64,
        nowUptimeNanoseconds: UInt64
    ) -> UInt64 {
        guard frameTimestampNanoseconds >= 0 else { return nowUptimeNanoseconds }
        let timestamp = UInt64(frameTimestampNanoseconds)
        return timestamp <= nowUptimeNanoseconds
            ? timestamp
            : nowUptimeNanoseconds
    }

    static func isOutputStale(
        admittedUptimeNanoseconds: UInt64,
        nowUptimeNanoseconds: UInt64,
        maximumAgeNanoseconds: UInt64
    ) -> Bool {
        guard nowUptimeNanoseconds >= admittedUptimeNanoseconds else { return false }
        return nowUptimeNanoseconds - admittedUptimeNanoseconds
            > maximumAgeNanoseconds
    }

    static func enablesLowLatencyRateControl(
        mode: WebRTCH264EncodingMode,
        profileLevelID: String
    ) -> Bool {
        mode == .performance
            && profileLevelID.lowercased().hasPrefix("64")
    }
}

/// A tiny thread-safe admission controller for asynchronous VT submissions.
/// A rejected reservation is an intentional real-time frame drop, not an
/// encoder failure; actual VT submission/callback failures remain separate.
final class WebRTCH264FrameSubmissionGate: @unchecked Sendable {
    enum Admission {
        case reserved(Reservation)
        case saturated
        case stalled
    }

    final class Reservation: @unchecked Sendable {
        private let lock = NSLock()
        private var isCompleted = false
        private weak var gate: WebRTCH264FrameSubmissionGate?
        private let identifier: UInt64

        fileprivate init(
            gate: WebRTCH264FrameSubmissionGate,
            identifier: UInt64
        ) {
            self.gate = gate
            self.identifier = identifier
        }

        func complete() {
            let shouldRelease = lock.withLock {
                guard !isCompleted else { return false }
                isCompleted = true
                return true
            }
            if shouldRelease {
                gate?.completeReservation(identifier)
            }
        }
    }

    private let lock = NSLock()
    private let maximumInFlightFrames: Int
    private var reservations: [UInt64: UInt64] = [:]
    private var nextIdentifier: UInt64 = 0
    private var rejectedReservations = 0

    init(
        maximumInFlightFrames: Int = WebRTCH264LatencyPolicy.maximumInFlightFrames
    ) {
        precondition(maximumInFlightFrames > 0)
        self.maximumInFlightFrames = maximumInFlightFrames
    }

    func admit(
        maximumAgeNanoseconds: UInt64,
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Admission {
        lock.withLock {
            guard reservations.count < maximumInFlightFrames else {
                rejectedReservations += 1
                let oldest = reservations.values.min()
                if let oldest,
                   WebRTCH264LatencyPolicy.isOutputStale(
                       admittedUptimeNanoseconds: oldest,
                       nowUptimeNanoseconds: nowUptimeNanoseconds,
                       maximumAgeNanoseconds: maximumAgeNanoseconds
                   ) {
                    return .stalled
                }
                return .saturated
            }
            nextIdentifier &+= 1
            let identifier = nextIdentifier
            reservations[identifier] = nowUptimeNanoseconds
            return .reserved(Reservation(gate: self, identifier: identifier))
        }
    }

    /// Test convenience for count-only admission. Production uses `admit` so
    /// a permanently wedged VideoToolbox callback can be distinguished from a
    /// momentarily full two-frame gate.
    func reserve() -> Reservation? {
        guard case let .reserved(reservation) = admit(
            maximumAgeNanoseconds: .max
        ) else {
            return nil
        }
        return reservation
    }

    var pendingCount: Int {
        lock.withLock { reservations.count }
    }

    var backpressureDropCount: Int {
        lock.withLock { rejectedReservations }
    }

    /// Invalidation is the terminal path for a session. VT is not required to
    /// invoke callbacks for every abandoned frame, so release its accounting
    /// explicitly rather than waiting on callbacks that may never arrive.
    func cancelAll() {
        lock.withLock {
            reservations.removeAll()
        }
    }

    private func completeReservation(_ identifier: UInt64) {
        lock.withLock {
            reservations[identifier] = nil
        }
    }
}

/// State-queue-confined retry intent for a PLI/keyframe request. Multiple
/// frames may be in flight for one request, so an identifier prevents a late
/// failure from re-arming a request that an earlier IDR already satisfied.
struct WebRTCH264KeyFrameRequestState: Equatable, Sendable {
    typealias Identifier = UInt64

    private(set) var pendingIdentifier: Identifier?
    private var nextIdentifier: Identifier = 0

    var isPending: Bool { pendingIdentifier != nil }

    mutating func request() {
        nextIdentifier &+= 1
        pendingIdentifier = nextIdentifier
    }

    /// Only a keyframe accepted by the current RTC callback satisfies the
    /// request. Submission to VideoToolbox alone is not sufficient because VT
    /// and the asynchronous output path may still drop the frame.
    mutating func accepted(_ identifier: Identifier) {
        guard pendingIdentifier == identifier else { return }
        pendingIdentifier = nil
    }

    mutating func reset() {
        pendingIdentifier = nil
    }
}

/// Shared by a factory and every encoder it creates. Updating the controller
/// changes live encoders as well as future ones; an active encoder rebuilds its
/// VideoToolbox session before accepting the next frame.
final class WebRTCH264EncoderConfigurationController: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let configuration: WebRTCH264EncoderConfiguration
        let revision: UInt64
    }

    private let lock = NSLock()
    private var configuration: WebRTCH264EncoderConfiguration
    private var revision: UInt64 = 0
    private var submissionBackpressureDrops: UInt64 = 0

    init(configuration: WebRTCH264EncoderConfiguration = .quality) {
        self.configuration = configuration
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(configuration: configuration, revision: revision)
        }
    }

    func update(_ configuration: WebRTCH264EncoderConfiguration) {
        lock.withLock {
            guard self.configuration != configuration else { return }
            self.configuration = configuration
            revision &+= 1
        }
    }

    func updateMode(_ mode: WebRTCH264EncodingMode) {
        lock.withLock {
            guard configuration.mode != mode else { return }
            configuration.mode = mode
            revision &+= 1
        }
    }

    func updateAdvancedConfiguration(
        _ advancedConfiguration: WebRTCH264AdvancedConfiguration
    ) {
        lock.withLock {
            var replacement = configuration
            replacement.quality = advancedConfiguration.qualityFraction
            replacement.keyFrameIntervalSeconds =
                advancedConfiguration.keyFrameIntervalSeconds
            replacement.maximumQuantizer =
                advancedConfiguration.maximumQuantizer
            guard replacement != configuration else { return }
            configuration = replacement
            revision &+= 1
        }
    }

    func recordSubmissionBackpressureDrop() {
        lock.withLock {
            if submissionBackpressureDrops < .max {
                submissionBackpressureDrops += 1
            }
        }
    }

    var submissionBackpressureDropCount: UInt64 {
        lock.withLock { submissionBackpressureDrops }
    }
}

struct WebRTCH264RateControlPlan: Equatable, Sendable {
    let mode: WebRTCH264EncodingMode
    let maximumBitrateBps: Int
    let targetBitrateBps: Int
    let quality: Double?
    let prioritizesSpeed: Bool

    init(
        configuration: WebRTCH264EncoderConfiguration,
        maximumBitrateBps: Int
    ) {
        let maximum = max(100_000, maximumBitrateBps)
        let fraction: Double
        switch configuration.mode {
        case .quality:
            fraction = configuration.qualityTargetFraction
            quality = configuration.quality
            prioritizesSpeed = false
        case .performance:
            fraction = configuration.performanceTargetFraction
            quality = nil
            prioritizesSpeed = true
        }
        mode = configuration.mode
        self.maximumBitrateBps = maximum
        targetBitrateBps = max(100_000, min(maximum, Int(Double(maximum) * fraction)))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
