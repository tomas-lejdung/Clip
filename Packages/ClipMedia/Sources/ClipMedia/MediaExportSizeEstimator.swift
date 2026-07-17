import Foundation

/// The deterministic rate plan used both to configure the native exporter and
/// to give Preview an immediate file-size estimate.
public struct MediaExportSizeEstimate: Equatable, Sendable {
    public let byteCount: Int64
    public let effectiveVideoBitRate: Int
    public let effectiveAudioBitRate: Int
    public let estimatedContainerBitRate: Int
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int

    public init(
        byteCount: Int64,
        effectiveVideoBitRate: Int,
        effectiveAudioBitRate: Int,
        estimatedContainerBitRate: Int,
        width: Int,
        height: Int,
        framesPerSecond: Int
    ) {
        self.byteCount = byteCount
        self.effectiveVideoBitRate = effectiveVideoBitRate
        self.effectiveAudioBitRate = effectiveAudioBitRate
        self.estimatedContainerBitRate = estimatedContainerBitRate
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }
}

public enum MediaExportSizeEstimator {
    /// Calculates the expected MP4 size from the exact output rate plan. This
    /// is intentionally synchronous and inexpensive so Preview can recompute
    /// it for every trim-handle movement without launching an export.
    public static func estimate(
        configuration: MediaExportConfiguration,
        duration: TimeInterval,
        includesAudio: Bool,
        sourceByteCount: Int64? = nil,
        sourceDuration: TimeInterval? = nil,
        sourceIncludesAudio: Bool? = nil
    ) -> MediaExportSizeEstimate {
        let safeDuration = duration.isFinite ? max(duration, 0) : 0
        let videoBitRate = effectiveVideoBitRate(
            configuration: configuration,
            duration: safeDuration,
            includesAudio: includesAudio
        )
        let audioBitRate = includesAudio ? configuration.audioBitRate : 0
        let containerBitRate = estimatedContainerBitRate(
            encodedStreamBitRate: videoBitRate + audioBitRate
        )
        let totalBitRate = videoBitRate + audioBitRate + containerBitRate
        let unboundedBytes = (Double(totalBitRate) * safeDuration / 8).rounded(.up)
        let plannedByteCount = if unboundedBytes >= Double(Int64.max) {
            Int64.max
        } else {
            Int64(max(unboundedBytes, 0))
        }
        let byteCount = sourceCalibratedByteCount(
            plannedByteCount: plannedByteCount,
            sourceByteCount: sourceByteCount,
            sourceDuration: sourceDuration,
            selectedDuration: safeDuration,
            removesSourceAudio: sourceIncludesAudio == true && !includesAudio,
            outputAudioBitRate: configuration.audioBitRate,
            capsObservationToRatePlan: configuration.preset != .crisp
        )

        return MediaExportSizeEstimate(
            byteCount: byteCount,
            effectiveVideoBitRate: videoBitRate,
            effectiveAudioBitRate: audioBitRate,
            estimatedContainerBitRate: containerBitRate,
            width: configuration.width,
            height: configuration.height,
            framesPerSecond: configuration.framesPerSecond
        )
    }

    /// Average bitrate is a ceiling for VideoToolbox's content-adaptive H.264
    /// encoder, not a promise that a mostly-static screen recording will use
    /// every bit. When Preview knows the managed master's real byte count, its
    /// observed bytes-per-second is a much better estimate for the same content
    /// than the theoretical encoder envelope. Crisp may reuse that compatible
    /// master exactly, so its observation is not capped to the nominal plan.
    static func sourceCalibratedByteCount(
        plannedByteCount: Int64,
        sourceByteCount: Int64?,
        sourceDuration: TimeInterval?,
        selectedDuration: TimeInterval,
        removesSourceAudio: Bool = false,
        outputAudioBitRate: Int = 0,
        capsObservationToRatePlan: Bool = true
    ) -> Int64 {
        guard let sourceByteCount,
              sourceByteCount >= 0,
              let sourceDuration,
              sourceDuration.isFinite,
              sourceDuration > 0,
              selectedDuration.isFinite,
              selectedDuration >= 0 else {
            return plannedByteCount
        }

        let proportionalBytes = (Double(sourceByteCount)
            * min(selectedDuration / sourceDuration, 1)).rounded(.up)
        var calibratedByteCount = proportionalBytes >= Double(Int64.max)
            ? Int64.max
            : Int64(max(proportionalBytes, 0))
        if removesSourceAudio, outputAudioBitRate > 0 {
            let estimatedAudioBytes = Int64(
                (Double(outputAudioBitRate) * selectedDuration / 8).rounded(.up)
            )
            calibratedByteCount = max(0, calibratedByteCount - estimatedAudioBytes)
        }
        return capsObservationToRatePlan
            ? min(plannedByteCount, calibratedByteCount)
            : calibratedByteCount
    }

    /// Applies the same soft-size-target limiter used by `NativeAssetExporter`.
    /// Keeping this in one place prevents Preview's estimate from drifting from
    /// the rate actually handed to VideoToolbox.
    static func effectiveVideoBitRate(
        configuration: MediaExportConfiguration,
        duration: TimeInterval,
        includesAudio: Bool
    ) -> Int {
        guard let targetBytes = configuration.approximateTargetBytes else {
            return configuration.videoBitRate
        }

        let totalTargetRate = Int(
            (Double(targetBytes) * 8 / max(duration, 0.25)).rounded(.down)
        )
        let audioRate = includesAudio ? configuration.audioBitRate : 0
        let containerAllowance = max(16_000, totalTargetRate / 100)
        let targetVideoRate = max(100_000, totalTargetRate - audioRate - containerAllowance)
        return min(configuration.videoBitRate, targetVideoRate)
    }

    private static func estimatedContainerBitRate(
        encodedStreamBitRate: Int
    ) -> Int {
        // MP4 sample tables and interleaving overhead vary with frame count.
        // One percent with a small floor is a deliberately conservative local
        // estimate; the UI labels the result as estimated rather than exact.
        return max(16_000, encodedStreamBitRate / 100)
    }
}
