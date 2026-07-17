@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
@preconcurrency import VideoToolbox

/// A direct, quality-oriented VideoToolbox H.264 encoder for live screen
/// capture. Raw ScreenCaptureKit pixel buffers enter here and compressed
/// CMSampleBuffers leave here; no AVFoundation video encoder sits between the
/// capture pixels and the MP4 muxer.
final class VideoToolboxH264Encoder: @unchecked Sendable {
    enum EncoderError: Error, Equatable, Sendable {
        case cannotCreate(OSStatus)
        case cannotSetProperty(name: String, status: OSStatus)
        case cannotPrepare(OSStatus)
        case rejectedFrame(OSStatus)
        case droppedFrame
        case missingCompressedSample
        case backpressureExceeded
        case cannotComplete(OSStatus)
    }

    struct Configuration: Equatable, Sendable {
        let width: Int
        let height: Int
        let framesPerSecond: Int
        let averageBitRate: Int
        let quality: Double
        let isRealTime: Bool
        let allowsFrameReordering: Bool
        let prioritizesEncodingSpeedOverQuality: Bool
        let maximumKeyFrameInterval: Int
        let hardDataRateLimitBytesPerSecond: Int?

        init(
            width: Int,
            height: Int,
            framesPerSecond: Int,
            averageBitRate: Int,
            quality: Double = 0.98,
            isRealTime: Bool = true,
            allowsFrameReordering: Bool = false
        ) {
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
            self.averageBitRate = averageBitRate
            self.quality = quality
            self.isRealTime = isRealTime
            self.allowsFrameReordering = allowsFrameReordering
            prioritizesEncodingSpeedOverQuality = false
            maximumKeyFrameInterval = framesPerSecond * 2
            hardDataRateLimitBytesPerSecond = nil
        }

        static func liveMaster(
            recording configuration: RecordingConfiguration
        ) -> Configuration {
            Configuration(
                width: configuration.width,
                height: configuration.height,
                framesPerSecond: configuration.framesPerSecond,
                averageBitRate: configuration.videoBitRate,
                quality: 0.98,
                isRealTime: true,
                allowsFrameReordering: false
            )
        }
    }

    private let session: VTCompressionSession
    private let condition = NSCondition()
    private let sessionOperationLock = NSLock()
    private let maximumPendingFrameCount: Int
    private let backpressureTimeout: TimeInterval
    private let firstOutputTimeout: TimeInterval
    private let flushQueue = DispatchQueue(
        label: "com.tomaslejdung.clip.videotoolbox.flush",
        qos: .userInitiated
    )

    private var pendingFrameCount = 0
    private var compressedSamples: [CMSampleBuffer] = []
    private var terminalError: EncoderError?
    private var isInvalidated = false

    init(configuration: Configuration) throws {
        precondition(configuration.width > 0 && configuration.height > 0)
        precondition(configuration.framesPerSecond > 0)
        precondition((0...1).contains(configuration.quality))

        maximumPendingFrameCount = 6
        backpressureTimeout = 2.0 / Double(configuration.framesPerSecond)

        let hardwareRequiredSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        let hardwarePreferredSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: configuration.width,
            kCVPixelBufferHeightKey: configuration.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]

        func createSession(
            specification: [CFString: Any],
            output: inout VTCompressionSession?
        ) -> OSStatus {
            VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(configuration.width),
                height: Int32(configuration.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: imageBufferAttributes as CFDictionary,
                compressedDataAllocator: kCFAllocatorDefault,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &output
            )
        }

        var createdSession: VTCompressionSession?
        var usesNativeSoftwareFallback = false
        var createStatus = createSession(
            specification: hardwareRequiredSpecification,
            output: &createdSession
        )
        if createStatus != noErr || createdSession == nil {
            // Apple Silicon's hardware H.264 encoder does not accept every
            // native display size (notably some 5K modes). Preserve exact
            // pixels with VideoToolbox's native software fallback rather than
            // downscaling the recording or failing fullscreen capture.
            createdSession = nil
            usesNativeSoftwareFallback = true
            createStatus = createSession(
                specification: hardwarePreferredSpecification,
                output: &createdSession
            )
        }
        guard createStatus == noErr, let createdSession else {
            throw EncoderError.cannotCreate(createStatus)
        }
        session = createdSession
        firstOutputTimeout = usesNativeSoftwareFallback
            ? 5.0
            : max(backpressureTimeout, 0.5)

        do {
            try set(
                kVTCompressionPropertyKey_RealTime,
                value: configuration.isRealTime ? kCFBooleanTrue : kCFBooleanFalse,
                name: "RealTime"
            )
            try set(
                kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_High_AutoLevel,
                name: "ProfileLevel"
            )
            try set(
                kVTCompressionPropertyKey_Quality,
                value: NSNumber(value: configuration.quality),
                name: "Quality",
                allowsUnsupportedProperty: usesNativeSoftwareFallback
            )
            try set(
                kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                value: configuration.prioritizesEncodingSpeedOverQuality
                    ? kCFBooleanTrue
                    : kCFBooleanFalse,
                name: "PrioritizeEncodingSpeedOverQuality",
                allowsUnsupportedProperty: usesNativeSoftwareFallback
            )
            try set(
                kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: configuration.averageBitRate),
                name: "AverageBitRate"
            )
            try set(
                kVTCompressionPropertyKey_ExpectedFrameRate,
                value: NSNumber(value: configuration.framesPerSecond),
                name: "ExpectedFrameRate"
            )
            try set(
                kVTCompressionPropertyKey_AllowFrameReordering,
                value: configuration.allowsFrameReordering
                    ? kCFBooleanTrue
                    : kCFBooleanFalse,
                name: "AllowFrameReordering"
            )
            try set(
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: NSNumber(value: configuration.maximumKeyFrameInterval),
                name: "MaxKeyFrameInterval"
            )
            try set(
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                value: NSNumber(value: 2.0),
                name: "MaxKeyFrameIntervalDuration"
            )
            try set(
                kVTCompressionPropertyKey_ColorPrimaries,
                value: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                name: "ColorPrimaries"
            )
            try set(
                kVTCompressionPropertyKey_TransferFunction,
                value: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                name: "TransferFunction"
            )
            try set(
                kVTCompressionPropertyKey_YCbCrMatrix,
                value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
                name: "YCbCrMatrix"
            )

            let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
            guard prepareStatus == noErr else {
                throw EncoderError.cannotPrepare(prepareStatus)
            }
        } catch {
            VTCompressionSessionInvalidate(session)
            throw error
        }
    }

    deinit {
        invalidate()
    }

    /// Submits one raw pixel buffer. A bounded wait absorbs brief hardware
    /// encoder pressure; a sustained stall is a terminal, user-visible error
    /// rather than a silently missing video frame.
    func encode(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime
    ) throws {
        try reservePendingFrameSlot()

        var synchronousFlags = VTEncodeInfoFlags()
        let status = sessionOperationLock.withLock {
            VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: duration,
                frameProperties: nil,
                infoFlagsOut: &synchronousFlags
            ) { [weak self] status, infoFlags, sampleBuffer in
                self?.handleEncodedFrame(
                    status: status,
                    infoFlags: infoFlags,
                    sampleBuffer: sampleBuffer
                )
            }
        }

        guard status == noErr else {
            completeRejectedSubmission(with: .rejectedFrame(status))
            throw EncoderError.rejectedFrame(status)
        }
        if synchronousFlags.contains(.frameDropped) {
            // The output handler owns pending-count completion for successful
            // submissions, including asynchronously reported dropped frames.
            // Record the error immediately so the capture callback fails now.
            condition.withLock {
                terminalError = terminalError ?? .droppedFrame
                condition.broadcast()
            }
            throw EncoderError.droppedFrame
        }
    }

    /// Waits for the first encoded sample so the MP4 writer can establish its
    /// passthrough format before audio callbacks are accepted.
    func waitForFirstOutput() throws {
        // Hardware-session warm-up is a one-time cost rather than sustained
        // overload. Native software H.264 can also retain its first frame for
        // look-ahead until another frame arrives, so explicitly complete the
        // sole pending first frame if the ordinary warm-up window expires.
        let deadline = Date(timeIntervalSinceNow: min(firstOutputTimeout, 0.5))
        let shouldForceFirstFrame = try condition.withLock { () throws -> Bool in
            while compressedSamples.isEmpty,
                  terminalError == nil,
                  pendingFrameCount > 0 {
                guard condition.wait(until: deadline) else {
                    return true
                }
            }
            if let terminalError {
                throw terminalError
            }
            return false
        }
        if shouldForceFirstFrame {
            guard let status = boundedCompleteFrames(timeout: firstOutputTimeout) else {
                throw EncoderError.backpressureExceeded
            }
            guard status == noErr else {
                failAndInvalidate(.cannotComplete(status))
                throw EncoderError.cannotComplete(status)
            }
        }
        let outputDeadline = Date(timeIntervalSinceNow: backpressureTimeout)
        do {
            try condition.withLock {
                while compressedSamples.isEmpty,
                      terminalError == nil,
                      !isInvalidated,
                      pendingFrameCount > 0 {
                    guard condition.wait(until: outputDeadline) else {
                        throw EncoderError.backpressureExceeded
                    }
                }
                if let terminalError { throw terminalError }
                guard !isInvalidated else {
                    throw EncoderError.rejectedFrame(kVTInvalidSessionErr)
                }
                guard !compressedSamples.isEmpty else {
                    throw EncoderError.backpressureExceeded
                }
            }
        } catch let error as EncoderError {
            failAndInvalidate(
                error,
                asynchronous: error == .backpressureExceeded
            )
            throw error
        }
    }

    func drainCompressedSamples() throws -> [CMSampleBuffer] {
        try condition.withLock {
            if let terminalError {
                throw terminalError
            }
            let drained = compressedSamples
            compressedSamples.removeAll(keepingCapacity: true)
            return drained
        }
    }

    func completeFrames() throws -> [CMSampleBuffer] {
        let timeout = max(firstOutputTimeout, 1.0)
        guard let status = boundedCompleteFrames(timeout: timeout) else {
            throw EncoderError.backpressureExceeded
        }
        guard status == noErr else {
            failAndInvalidate(.cannotComplete(status))
            throw EncoderError.cannotComplete(status)
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        let samples: [CMSampleBuffer]
        do {
            samples = try condition.withLock { () throws -> [CMSampleBuffer] in
                while pendingFrameCount > 0,
                      terminalError == nil,
                      !isInvalidated {
                    guard condition.wait(until: deadline) else {
                        throw EncoderError.backpressureExceeded
                    }
                }
                if let terminalError {
                    throw terminalError
                }
                guard !isInvalidated else {
                    throw EncoderError.rejectedFrame(kVTInvalidSessionErr)
                }
                let drained = compressedSamples
                compressedSamples.removeAll(keepingCapacity: false)
                return drained
            }
        } catch let error as EncoderError {
            failAndInvalidate(
                error,
                asynchronous: error == .backpressureExceeded
            )
            throw error
        }
        invalidate()
        return samples
    }

    func invalidate() {
        let shouldInvalidate = markInvalidated()
        if shouldInvalidate {
            VTCompressionSessionInvalidate(session)
        }
    }

    /// `VTCompressionSessionCompleteFrames` is documented as synchronous and
    /// can block inside VideoToolbox. Running it on a private serial queue keeps
    /// the capture/finalization caller bounded. A timeout marks the encoder
    /// terminal immediately and starts invalidation on another queue so even a
    /// pathological teardown cannot re-block the caller that detected it.
    private func boundedCompleteFrames(timeout: TimeInterval) -> OSStatus? {
        let session = SendableCompressionSession(session)
        let operationLock = sessionOperationLock
        return BoundedVideoToolboxOperation.run(
            on: flushQueue,
            timeout: timeout,
            operation: {
                operationLock.withLock {
                    VTCompressionSessionCompleteFrames(
                        session.value,
                        untilPresentationTimeStamp: .invalid
                    )
                }
            },
            onTimeout: { [weak self] in
                self?.failAndInvalidate(.backpressureExceeded, asynchronous: true)
            }
        )
    }

    private func failAndInvalidate(
        _ error: EncoderError,
        asynchronous: Bool = false
    ) {
        let shouldInvalidate = condition.withLock { () -> Bool in
            terminalError = terminalError ?? error
            guard !isInvalidated else {
                condition.broadcast()
                return false
            }
            isInvalidated = true
            condition.broadcast()
            return true
        }
        guard shouldInvalidate else { return }

        let session = SendableCompressionSession(session)
        if asynchronous {
            DispatchQueue.global(qos: .userInitiated).async {
                VTCompressionSessionInvalidate(session.value)
            }
        } else {
            VTCompressionSessionInvalidate(session.value)
        }
    }

    private func markInvalidated() -> Bool {
        condition.withLock {
            guard !isInvalidated else { return false }
            isInvalidated = true
            condition.broadcast()
            return true
        }
    }

    private func set(
        _ key: CFString,
        value: CFTypeRef,
        name: String,
        allowsUnsupportedProperty: Bool = false
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if allowsUnsupportedProperty, status == kVTPropertyNotSupportedErr {
            return
        }
        guard status == noErr else {
            throw EncoderError.cannotSetProperty(name: name, status: status)
        }
    }

    private func reservePendingFrameSlot() throws {
        let deadline = Date(timeIntervalSinceNow: backpressureTimeout)
        try condition.withLock {
            while pendingFrameCount >= maximumPendingFrameCount,
                  terminalError == nil,
                  !isInvalidated {
                guard condition.wait(until: deadline) else {
                    terminalError = .backpressureExceeded
                    throw EncoderError.backpressureExceeded
                }
            }
            if let terminalError {
                throw terminalError
            }
            guard !isInvalidated else {
                throw EncoderError.rejectedFrame(kVTInvalidSessionErr)
            }
            pendingFrameCount += 1
        }
    }

    private func completeRejectedSubmission(with error: EncoderError) {
        condition.withLock {
            pendingFrameCount = max(0, pendingFrameCount - 1)
            terminalError = terminalError ?? error
            condition.broadcast()
        }
    }

    private func handleEncodedFrame(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) {
        condition.withLock {
            pendingFrameCount = max(0, pendingFrameCount - 1)
            if isInvalidated || terminalError != nil {
                // A callback may race a watchdog-triggered invalidation. It
                // still retires its pending slot, but must never append output
                // or replace the original visible terminal error.
            } else if status != noErr {
                terminalError = terminalError ?? .rejectedFrame(status)
            } else if infoFlags.contains(.frameDropped) {
                terminalError = terminalError ?? .droppedFrame
            } else if let sampleBuffer, sampleBuffer.isValid {
                compressedSamples.append(sampleBuffer)
            } else {
                terminalError = terminalError ?? .missingCompressedSample
            }
            condition.broadcast()
        }
    }
}

private final class SendableCompressionSession: @unchecked Sendable {
    let value: VTCompressionSession

    init(_ value: VTCompressionSession) {
        self.value = value
    }
}

/// Races one synchronous VideoToolbox operation against a wall-clock deadline.
/// The operation may continue on its private queue after timeout, but callers
/// always regain control and can initiate session invalidation immediately.
enum BoundedVideoToolboxOperation {
    static func run(
        on queue: DispatchQueue,
        timeout: TimeInterval,
        operation: @escaping @Sendable () -> OSStatus,
        onTimeout: () -> Void
    ) -> OSStatus? {
        precondition(timeout > 0 && timeout.isFinite)
        let state = State()
        queue.async {
            state.complete(with: operation())
        }
        guard let result = state.wait(timeout: timeout) else {
            onTimeout()
            return nil
        }
        return result
    }

    private final class State: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: OSStatus?

        func complete(with result: OSStatus) {
            condition.withLock {
                guard self.result == nil else { return }
                self.result = result
                condition.broadcast()
            }
        }

        func wait(timeout: TimeInterval) -> OSStatus? {
            let deadline = Date(timeIntervalSinceNow: timeout)
            return condition.withLock {
                while result == nil {
                    guard condition.wait(until: deadline) else { return nil }
                }
                return result
            }
        }
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
