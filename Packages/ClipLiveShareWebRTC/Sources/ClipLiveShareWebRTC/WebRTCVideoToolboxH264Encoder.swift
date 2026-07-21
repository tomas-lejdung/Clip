@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
@preconcurrency import VideoToolbox
@preconcurrency import WebRTC

/// A native H.264 WebRTC encoder. ScreenCaptureKit's CVPixelBuffer enters
/// VideoToolbox directly and the resulting Annex-B access unit enters
/// libwebrtc; there is no intermediate image conversion or video encode.
final class WebRTCVideoToolboxH264Encoder: NSObject, RTCVideoEncoder,
    @unchecked Sendable
{
    private static let success = 0
    private static let error = -1

    private struct StartConfiguration: Equatable, Sendable {
        let width: Int
        let height: Int
        let framesPerSecond: Int
        let initialBitrateBps: Int
    }

    private let codecInfo: RTCVideoCodecInfo
    private let configurationController: WebRTCH264EncoderConfigurationController
    private let stateQueue = DispatchQueue(
        label: "com.tomaslejdung.clip.webrtc.h264-encoder"
    )
    private let stateQueueKey = DispatchSpecificKey<UInt8>()
    private let outputQueue = DispatchQueue(
        label: "com.tomaslejdung.clip.webrtc.h264-encoder.output",
        qos: .userInteractive
    )
    private let outputQueueKey = DispatchSpecificKey<UInt8>()
    private let callbackLock = NSLock()

    private var callback: RTCVideoEncoderCallback?
    private var callbackGeneration: UInt64 = 0
    private var startConfiguration: StartConfiguration?
    private var compressionSession: CompressionSession?
    private var configuredMaximumBitrateBps = 1_000_000
    private var networkTargetBitrateBps = 1_000_000
    private var framesPerSecond = 30
    private var activeConfigurationRevision: UInt64?
    private var pendingBitrateUpdate: (bitsPerSecond: Int, framesPerSecond: Int)?
    private var keyFrameRequest = WebRTCH264KeyFrameRequestState()

    init(
        codecInfo: RTCVideoCodecInfo,
        configurationController: WebRTCH264EncoderConfigurationController
    ) {
        self.codecInfo = codecInfo
        self.configurationController = configurationController
        super.init()
        stateQueue.setSpecific(key: stateQueueKey, value: 1)
        outputQueue.setSpecific(key: outputQueueKey, value: 1)
    }

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        callbackLock.withLock {
            callbackGeneration &+= 1
            self.callback = callback
        }
        if callback != nil {
            // A callback replacement is a new consumer of the H.264 reference
            // chain. If encoding already started, rebuild before the next
            // input and force an IDR so the new consumer never begins on a
            // delta that references output delivered only to its predecessor.
            stateQueue.async { [weak self] in
                guard let self, startConfiguration != nil else { return }
                keyFrameRequest.request()
                compressionSession?.invalidateReferenceChain()
            }
        }
        if callback == nil {
            drainOutputQueue()
        }
    }

    func startEncode(
        with settings: RTCVideoEncoderSettings,
        numberOfCores _: Int32
    ) -> Int {
        onStateQueue {
            releaseSession()
            keyFrameRequest = WebRTCH264KeyFrameRequestState()
            pendingBitrateUpdate = nil
            let width = Int(settings.width)
            let height = Int(settings.height)
            guard width > 0, height > 0 else { return Self.error }

            framesPerSecond = max(1, Int(settings.maxFramerate))
            let bitrate = WebRTCH264BitrateEnvelope(
                startKbit: settings.startBitrate,
                maximumKbit: settings.maxBitrate,
                minimumKbit: settings.minBitrate
            )
            configuredMaximumBitrateBps = bitrate.maximumBitrateBps
            networkTargetBitrateBps = bitrate.initialBitrateBps
            startConfiguration = StartConfiguration(
                width: width,
                height: height,
                framesPerSecond: framesPerSecond,
                initialBitrateBps: networkTargetBitrateBps
            )
            return rebuildSession() ? Self.success : Self.error
        }
    }

    func release() -> Int {
        callbackLock.withLock {
            callbackGeneration &+= 1
            callback = nil
        }
        onStateQueue {
            releaseSession()
            keyFrameRequest = WebRTCH264KeyFrameRequestState()
            startConfiguration = nil
            activeConfigurationRevision = nil
            pendingBitrateUpdate = nil
        }
        drainOutputQueue()
        return Self.success
    }

    func encode(
        _ frame: RTCVideoFrame,
        codecSpecificInfo _: (any RTCCodecSpecificInfo)?,
        frameTypes: [NSNumber]
    ) -> Int {
        onStateQueue { () -> Int in
            if frameTypes.contains(where: {
                $0.uintValue == RTCFrameType.videoFrameKey.rawValue
            }) {
                keyFrameRequest.request()
            }
            applyPendingBitrateUpdate()
            guard let pixelBufferFrame = frame.buffer as? RTCCVPixelBuffer else {
                return Self.error
            }
            let currentUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            let admittedUptimeNanoseconds = WebRTCH264LatencyPolicy
                .admittedUptimeNanoseconds(
                    frameTimestampNanoseconds: frame.timeStampNs,
                    nowUptimeNanoseconds: currentUptimeNanoseconds
                )
            let maximumOutputAgeNanoseconds = WebRTCH264LatencyPolicy
                .maximumOutputAgeNanoseconds(framesPerSecond: framesPerSecond)
            guard !WebRTCH264LatencyPolicy.isOutputStale(
                admittedUptimeNanoseconds: admittedUptimeNanoseconds,
                nowUptimeNanoseconds: currentUptimeNanoseconds,
                maximumAgeNanoseconds: maximumOutputAgeNanoseconds
            ) else {
                // This frame has not entered VideoToolbox, so dropping it does
                // not break the current H.264 reference chain. Any pending PLI
                // remains armed for the next fresh input.
                return Self.success
            }

            // A full gate whose oldest reservation is over two frame periods
            // old represents a wedged VT session, not normal backpressure.
            // Rebuild it and give this still-current frame one clean attempt.
            for attempt in 0 ... 1 {
                guard ensureCurrentSession(), var session = compressionSession else {
                    return Self.error
                }

                let frameWidth = Int(frame.width)
                let frameHeight = Int(frame.height)
                if session.width != frameWidth || session.height != frameHeight {
                    guard let current = startConfiguration else { return Self.error }
                    startConfiguration = StartConfiguration(
                        width: frameWidth,
                        height: frameHeight,
                        framesPerSecond: current.framesPerSecond,
                        initialBitrateBps: current.initialBitrateBps
                    )
                    guard rebuildSession(), let replacement = compressionSession else {
                        return Self.error
                    }
                    session = replacement
                }

                guard let pixelBuffer = session.pixelBuffer(
                    preparing: pixelBufferFrame,
                    targetWidth: frameWidth,
                    targetHeight: frameHeight
                ) else {
                    return Self.error
                }
                guard !WebRTCH264LatencyPolicy.isOutputStale(
                    admittedUptimeNanoseconds: admittedUptimeNanoseconds,
                    nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    maximumAgeNanoseconds: maximumOutputAgeNanoseconds
                ) else {
                    return Self.success
                }

                let generation = callbackLock.withLock { callbackGeneration }
                let metadata = FrameMetadata(
                    width: frameWidth,
                    height: frameHeight,
                    timeStamp: UInt32(bitPattern: frame.timeStamp),
                    captureTimeMs: frame.timeStampNs / 1_000_000,
                    rotation: frame.rotation,
                    encodeStartMs: Self.monotonicMilliseconds,
                    callbackGeneration: generation,
                    keyFrameRequestIdentifier: keyFrameRequest.pendingIdentifier,
                    admittedUptimeNanoseconds: admittedUptimeNanoseconds,
                    maximumOutputAgeNanoseconds: maximumOutputAgeNanoseconds
                )
                let encodingSession = session
                let result = session.encode(
                    pixelBuffer,
                    presentationTime: CMTime(
                        value: frame.timeStampNs,
                        timescale: 1_000_000_000
                    ),
                    forceKeyFrame: metadata.keyFrameRequestIdentifier != nil,
                    metadata: metadata,
                    failure: { [weak self] metadata, invalidatesReferenceChain in
                        guard let self else { return }
                        if invalidatesReferenceChain {
                            recoverReferenceChain(
                                metadata,
                                session: encodingSession
                            )
                        } else {
                            retryKeyFrame(metadata)
                        }
                    },
                    output: { [weak self] sampleBuffer, metadata, completion in
                        guard let self else {
                            completion()
                            return
                        }
                        guard encodingSession.isHealthy,
                              !isStale(metadata) else {
                            recoverReferenceChain(
                                metadata,
                                session: encodingSession
                            )
                            completion()
                            return
                        }
                        guard let accessUnit = H264AnnexBAccessUnit(
                            sampleBuffer: sampleBuffer
                        ) else {
                            recoverReferenceChain(
                                metadata,
                                session: encodingSession
                            )
                            completion()
                            return
                        }
                        outputQueue.async { [weak self] in
                            defer { completion() }
                            guard let self else { return }
                            guard encodingSession.isHealthy,
                                  !isStale(metadata) else {
                                recoverReferenceChain(
                                    metadata,
                                    session: encodingSession
                                )
                                return
                            }
                            let accepted = deliver(
                                accessUnit,
                                metadata: metadata
                            )
                            guard accepted else {
                                recoverReferenceChain(
                                    metadata,
                                    session: encodingSession
                                )
                                return
                            }
                            guard let identifier = metadata
                                .keyFrameRequestIdentifier
                            else {
                                return
                            }
                            if accessUnit.isKeyFrame {
                                acceptKeyFrame(
                                    identifier,
                                    metadata: metadata
                                )
                            } else {
                                retryKeyFrame(metadata)
                            }
                        }
                    }
                )
                switch result {
                case .submitted:
                    return Self.success
                case .droppedForBackpressure:
                    configurationController.recordSubmissionBackpressureDrop()
                    retryKeyFrame(metadata)
                    return Self.success
                case .stalled:
                    configurationController.recordSubmissionBackpressureDrop()
                    retryKeyFrame(metadata)
                    guard attempt == 0,
                          !isStale(metadata)
                    else {
                        return Self.success
                    }
                    // `stalled` marks this session unhealthy. The next loop
                    // rebuilds it and refreshes its generation before trying
                    // this same frame once more within its original deadline.
                    continue
                case .failed:
                    retryKeyFrame(metadata)
                    return Self.error
                }
            }
            return Self.success
        }
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        // libwebrtc may call this from inside the encoded-image callback, so
        // never make WebRTC's encoder queue wait for VideoToolbox property
        // writes. Coalescing also avoids reapplying rate control for every
        // small bandwidth-estimator movement.
        stateQueue.async { [weak self] in
            guard let self, startConfiguration != nil else { return }
            pendingBitrateUpdate = (
                bitsPerSecond: min(
                    configuredMaximumBitrateBps,
                    max(100_000, Int(bitrateKbit) * 1_000)
                ),
                framesPerSecond: max(1, Int(framerate))
            )
        }
        return 0
    }

    func implementationName() -> String {
        "ClipVideoToolboxH264"
    }

    func scalingSettings() -> RTCVideoEncoderQpThresholds? {
        // Match libwebrtc's upstream H.264 thresholds. EncodedImage uses -1
        // below so VideoStreamEncoder parses the real QP from our Annex-B
        // access unit. DegradationPreference decides how the same scaler acts:
        // Quality preserves resolution; Performance preserves frame rate.
        RTCVideoEncoderQpThresholds(thresholdsLow: 28, high: 39)
    }

    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { true }
    var supportsNativeHandle: Bool { true }

    private func ensureCurrentSession() -> Bool {
        guard startConfiguration != nil else { return false }
        let snapshot = configurationController.snapshot()
        if compressionSession == nil
            || activeConfigurationRevision != snapshot.revision
            || compressionSession?.isHealthy == false
        {
            return rebuildSession(snapshot: snapshot)
        }
        return true
    }

    private func applyPendingBitrateUpdate() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard let update = pendingBitrateUpdate else { return }
        networkTargetBitrateBps = update.bitsPerSecond
        framesPerSecond = update.framesPerSecond
        guard let session = compressionSession else { return }
        let snapshot = configurationController.snapshot()
        let plan = rateControlPlan(snapshot: snapshot)
        if session.requiresImmediateRebuild(
            for: plan,
            framesPerSecond: framesPerSecond
        ) {
            pendingBitrateUpdate = nil
            releaseSession()
            activeConfigurationRevision = nil
            return
        }
        pendingBitrateUpdate = nil
        if !session.updateNetworkRateControl(plan) {
            releaseSession()
            activeConfigurationRevision = nil
        }
    }

    /// VideoToolbox may produce a frame synchronously from `encode`. The RTC
    /// callback is then allowed to feed rate-control information back into the
    /// encoder before the outer call returns. Executing inline when already on
    /// the state queue prevents that legal callback cycle from self-deadlocking.
    private func onStateQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return operation()
        }
        return stateQueue.sync(execute: operation)
    }

    private func drainOutputQueue() {
        guard DispatchQueue.getSpecific(key: outputQueueKey) == nil else { return }
        outputQueue.sync {}
    }

    private func rebuildSession(
        snapshot: WebRTCH264EncoderConfigurationController.Snapshot? = nil
    ) -> Bool {
        guard let startConfiguration else { return false }
        let snapshot = snapshot ?? configurationController.snapshot()
        let plan = rateControlPlan(snapshot: snapshot)
        let profile = H264Profile(codecInfo: codecInfo)

        let replacement: CompressionSession
        do {
            replacement = try CompressionSession(
                width: startConfiguration.width,
                height: startConfiguration.height,
                framesPerSecond: framesPerSecond,
                keyFrameIntervalSeconds: snapshot.configuration.keyFrameIntervalSeconds,
                profile: profile,
                rateControl: plan
            )
        } catch {
            return false
        }

        let previous = compressionSession
        callbackLock.withLock {
            // Samples from the previous VT session must not enter a restarted
            // RTC encoder, even when the callback object itself is unchanged.
            callbackGeneration &+= 1
        }
        compressionSession = replacement
        activeConfigurationRevision = snapshot.revision
        previous?.invalidate()
        return true
    }

    private func rateControlPlan(
        snapshot: WebRTCH264EncoderConfigurationController.Snapshot
    ) -> WebRTCH264RateControlPlan {
        let configuration = snapshot.configuration
        return WebRTCH264RateControlPlan(
            configuration: configuration,
            maximumBitrateBps: WebRTCH264BitratePolicy.encoderTargetBitsPerSecond(
                mode: configuration.mode,
                configuredMaximumBitrateBps: configuredMaximumBitrateBps,
                networkTargetBitrateBps: networkTargetBitrateBps
            )
        )
    }

    private func releaseSession() {
        compressionSession?.invalidate()
        compressionSession = nil
    }

    private func isStale(_ metadata: FrameMetadata) -> Bool {
        WebRTCH264LatencyPolicy.isOutputStale(
            admittedUptimeNanoseconds: metadata.admittedUptimeNanoseconds,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            maximumAgeNanoseconds: metadata.maximumOutputAgeNanoseconds
        )
    }

    /// Failure paths can run on a VideoToolbox callback thread or the output
    /// queue. Serialize the retry intent and reject callbacks belonging to an
    /// invalidated session generation. The request normally remains pending;
    /// the identifier check is what prevents a late failure from resurrecting
    /// a request already satisfied by another in-flight IDR.
    private func retryKeyFrame(_ metadata: FrameMetadata) {
        guard let identifier = metadata.keyFrameRequestIdentifier else { return }
        stateQueue.async { [weak self] in
            guard let self, startConfiguration != nil else { return }
            let isCurrentGeneration = callbackLock.withLock {
                metadata.callbackGeneration == callbackGeneration
            }
            guard isCurrentGeneration,
                  keyFrameRequest.pendingIdentifier == identifier
            else {
                return
            }
            // The pending state is deliberately retained until RTC accepts an
            // IDR. The next live input therefore retries this request.
        }
    }

    /// Once VideoToolbox has emitted an access unit, later units may reference
    /// it. If Clip cannot deliver that unit, invalidate the complete encoder
    /// generation before another dependent delta can escape, then arm an IDR
    /// on the replacement session. Marking the captured session is safe even
    /// after a normal rebuild because it cannot affect its replacement.
    private func recoverReferenceChain(
        _ metadata: FrameMetadata,
        session: CompressionSession
    ) {
        session.invalidateReferenceChain()
        let ownsCurrentGeneration = callbackLock.withLock { () -> Bool in
            guard metadata.callbackGeneration == callbackGeneration else {
                return false
            }
            callbackGeneration &+= 1
            return true
        }
        guard ownsCurrentGeneration else { return }
        stateQueue.async { [weak self] in
            guard let self, startConfiguration != nil else { return }
            keyFrameRequest.request()
        }
    }

    private func acceptKeyFrame(
        _ identifier: WebRTCH264KeyFrameRequestState.Identifier,
        metadata: FrameMetadata
    ) {
        stateQueue.async { [weak self] in
            guard let self, startConfiguration != nil else { return }
            let isCurrentGeneration = callbackLock.withLock {
                metadata.callbackGeneration == callbackGeneration
            }
            guard isCurrentGeneration else { return }
            keyFrameRequest.accepted(identifier)
        }
    }

    private func deliver(
        _ accessUnit: H264AnnexBAccessUnit,
        metadata: FrameMetadata
    ) -> Bool {
        guard accessUnit.width == metadata.width,
              accessUnit.height == metadata.height
        else {
            return false
        }

        let image = RTCEncodedImage()
        image.buffer = accessUnit.data
        image.encodedWidth = Int32(metadata.width)
        image.encodedHeight = Int32(metadata.height)
        image.timeStamp = metadata.timeStamp
        image.captureTimeMs = metadata.captureTimeMs
        image.ntpTimeMs = 0
        image.flags = 0
        image.encodeStartMs = metadata.encodeStartMs
        image.encodeFinishMs = Self.monotonicMilliseconds
        image.frameType = accessUnit.isKeyFrame ? .videoFrameKey : .videoFrameDelta
        image.rotation = metadata.rotation
        // A negative value asks modern libwebrtc's VideoStreamEncoder to parse
        // the real H.264 slice QP from this Annex-B access unit.
        image.qp = -1
        image.contentType = .screenshare

        let codecSpecific = RTCCodecSpecificInfoH264()
        codecSpecific.packetizationMode = H264Profile(codecInfo: codecInfo)
            .packetizationMode
        let callback = callbackLock.withLock {
            metadata.callbackGeneration == callbackGeneration ? self.callback : nil
        }
        return callback?(image, codecSpecific) == true
    }

    private static var monotonicMilliseconds: Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1_000)
    }
}

private extension WebRTCVideoToolboxH264Encoder {
    struct FrameMetadata: Sendable {
        let width: Int
        let height: Int
        let timeStamp: UInt32
        let captureTimeMs: Int64
        let rotation: RTCVideoRotation
        let encodeStartMs: Int64
        let callbackGeneration: UInt64
        let keyFrameRequestIdentifier: WebRTCH264KeyFrameRequestState.Identifier?
        let admittedUptimeNanoseconds: UInt64
        let maximumOutputAgeNanoseconds: UInt64
    }

    struct H264Profile {
        let profileLevel: CFString
        let packetizationMode: RTCH264PacketizationMode

        init(codecInfo: RTCVideoCodecInfo) {
            let profileLevelID = codecInfo.parameters["profile-level-id"]?.lowercased() ?? ""
            self.profileLevelID = profileLevelID
            switch WebRTCH264ProfileFamily(profileLevelID: profileLevelID) {
            case .constrainedHigh:
                profileLevel = kVTProfileLevel_H264_ConstrainedHigh_AutoLevel
            case .high:
                profileLevel = kVTProfileLevel_H264_High_AutoLevel
            case .main:
                profileLevel = kVTProfileLevel_H264_Main_AutoLevel
            case .constrainedBaseline:
                profileLevel = kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
            case .baseline:
                profileLevel = kVTProfileLevel_H264_Baseline_AutoLevel
            }
            packetizationMode = codecInfo.parameters["packetization-mode"] == "0"
                ? .singleNalUnit
                : .nonInterleaved
        }

        let profileLevelID: String

        func enablesLowLatencyRateControl(
            mode: WebRTCH264EncodingMode
        ) -> Bool {
            // Apple's low-latency rate-control encoder supports only High
            // profiles. `64` is H.264 High's profile_idc; enabling it for the
            // negotiated 42e0 constrained-baseline format would either fail
            // session creation or emit a bitstream the remote SDP forbids.
            WebRTCH264LatencyPolicy.enablesLowLatencyRateControl(
                mode: mode,
                profileLevelID: profileLevelID
            )
        }
    }

    final class CompressionSession: @unchecked Sendable {
        enum SessionError: Error {
            case cannotCreate(OSStatus)
            case cannotConfigure(OSStatus)
            case cannotPrepare(OSStatus)
        }

        let width: Int
        let height: Int
        private let session: VTCompressionSession
        private let framesPerSecond: Int
        private let allowsSourceAdaptation: Bool
        private let submissionGate = WebRTCH264FrameSubmissionGate()
        private let healthLock = NSLock()
        private var hasFailed = false
        private var rateControl: WebRTCH264RateControlPlan
        private var cropAndScaleTemporaryBuffer: [UInt8] = []
        private var invalidated = false

        var isHealthy: Bool {
            healthLock.withLock { !hasFailed }
        }

        init(
            width: Int,
            height: Int,
            framesPerSecond: Int,
            keyFrameIntervalSeconds: Int,
            profile: H264Profile,
            rateControl: WebRTCH264RateControlPlan
        ) throws {
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
            allowsSourceAdaptation = rateControl.mode == .performance
            self.rateControl = rateControl
            var candidate: VTCompressionSession?
            var encoderSpecification: [CFString: Any] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            ]
            if profile.enablesLowLatencyRateControl(mode: rateControl.mode) {
                encoderSpecification[
                    kVTVideoEncoderSpecification_EnableLowLatencyRateControl
                ] = kCFBooleanTrue
            }
            let imageAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ]
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: encoderSpecification as CFDictionary,
                imageBufferAttributes: imageAttributes as CFDictionary,
                compressedDataAllocator: kCFAllocatorDefault,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &candidate
            )
            guard status == noErr, let candidate else {
                throw SessionError.cannotCreate(status)
            }
            session = candidate

            do {
                try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
                try set(kVTCompressionPropertyKey_ProfileLevel, profile.profileLevel)
                try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
                try setIfSupported(
                    kVTCompressionPropertyKey_MaxFrameDelayCount,
                    NSNumber(value: WebRTCH264LatencyPolicy.maximumFrameDelayCount)
                )
                try set(
                    kVTCompressionPropertyKey_ExpectedFrameRate,
                    NSNumber(value: framesPerSecond)
                )
                try setIfSupported(
                    kVTCompressionPropertyKey_MaximumRealTimeFrameRate,
                    NSNumber(
                        value: WebRTCH264LatencyPolicy
                            .maximumSupportedFramesPerSecond
                    )
                )
                try setIfSupported(
                    kVTCompressionPropertyKey_SuggestedLookAheadFrameCount,
                    NSNumber(
                        value: WebRTCH264LatencyPolicy.suggestedLookAheadFrameCount
                    )
                )
                try set(
                    kVTCompressionPropertyKey_MaxKeyFrameInterval,
                    NSNumber(value: framesPerSecond * keyFrameIntervalSeconds)
                )
                try set(
                    kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                    NSNumber(value: keyFrameIntervalSeconds)
                )
                try set(
                    kVTCompressionPropertyKey_ColorPrimaries,
                    kCMFormatDescriptionColorPrimaries_ITU_R_709_2
                )
                try set(
                    kVTCompressionPropertyKey_TransferFunction,
                    kCMFormatDescriptionTransferFunction_ITU_R_709_2
                )
                try set(
                    kVTCompressionPropertyKey_YCbCrMatrix,
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
                )
                guard updateRateControl(rateControl) else {
                    throw SessionError.cannotConfigure(kVTParameterErr)
                }
                let prepare = VTCompressionSessionPrepareToEncodeFrames(session)
                guard prepare == noErr else {
                    throw SessionError.cannotPrepare(prepare)
                }
            } catch {
                VTCompressionSessionInvalidate(session)
                throw error
            }
        }

        deinit {
            invalidate()
        }

        func updateRateControl(_ plan: WebRTCH264RateControlPlan) -> Bool {
            let speedStatus = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                value: plan.prioritizesSpeed ? kCFBooleanTrue : kCFBooleanFalse
            )
            guard speedStatus == noErr || speedStatus == kVTPropertyNotSupportedErr else {
                return false
            }

            switch plan.mode {
            case .quality:
                guard VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_Quality,
                    value: NSNumber(value: plan.quality ?? 0.98)
                ) == noErr else {
                    return false
                }
                return configureQualityRateControl(plan)
            case .performance:
                return setPerformanceAverage(plan)
            }
        }

        /// Applies only values intended to move with WebRTC's bandwidth
        /// estimate. Quality keeps its selected soft target stable and relies
        /// on WebRTC's frame dropper/pacer for adaptation. Performance retains
        /// AverageBitRate that follows the estimate. The RTP sender and pacer
        /// retain the hard network ceiling: Apple's normal-window hardware
        /// path rejects DataRateLimits when its low-latency/lookahead encoder
        /// is selected.
        func updateNetworkRateControl(
            _ plan: WebRTCH264RateControlPlan
        ) -> Bool {
            let succeeded: Bool
            switch plan.mode {
            case .quality:
                // Quality's selected soft target is established when the
                // session is built. Rewriting AverageBitRate on a live macOS
                // hardware encoder can synchronously block in media-server
                // XPC. WebRTC still applies every estimate to its upstream
                // frame dropper and RTP pacer.
                succeeded = true
            case .performance:
                succeeded = setPerformanceAverage(plan)
            }
            if succeeded {
                rateControl = plan
            } else {
                markFailed()
            }
            return succeeded
        }

        func requiresImmediateRebuild(
            for plan: WebRTCH264RateControlPlan,
            framesPerSecond: Int
        ) -> Bool {
            WebRTCH264SessionUpdatePolicy.requiresImmediateRebuild(
                current: rateControl,
                currentFramesPerSecond: self.framesPerSecond,
                requested: plan,
                requestedFramesPerSecond: framesPerSecond
            )
        }

        enum EncodeResult {
            case submitted
            case droppedForBackpressure
            case stalled
            case failed
        }

        func encode(
            _ pixelBuffer: CVPixelBuffer,
            presentationTime: CMTime,
            forceKeyFrame: Bool,
            metadata: FrameMetadata,
            failure: @escaping @Sendable (FrameMetadata, Bool) -> Void,
            output: @escaping @Sendable (
                CMSampleBuffer,
                FrameMetadata,
                @escaping @Sendable () -> Void
            ) -> Void
        ) -> EncodeResult {
            guard !invalidated else { return .failed }
            let admission = submissionGate.admit(
                maximumAgeNanoseconds: metadata.maximumOutputAgeNanoseconds,
                nowUptimeNanoseconds: metadata.admittedUptimeNanoseconds
            )
            let reservation: WebRTCH264FrameSubmissionGate.Reservation
            switch admission {
            case let .reserved(candidate):
                reservation = candidate
            case .saturated:
                // Live video must remain current. Reporting success to
                // libwebrtc intentionally drops this frame without treating a
                // transient hardware stall as an encoder crash.
                return .droppedForBackpressure
            case .stalled:
                // A callback that has held the two-frame gate for longer than
                // the output deadline cannot be allowed to pin the stream.
                // Mark this session unhealthy so the caller can invalidate it
                // and retry the current fresh frame on a new hardware session.
                markFailed()
                return .stalled
            }
            let frameProperties: CFDictionary? = forceKeyFrame
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
                : nil
            var flags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: .invalid,
                frameProperties: frameProperties,
                infoFlagsOut: &flags
            ) { [weak self] status, infoFlags, sampleBuffer in
                guard status == noErr else {
                    failure(metadata, true)
                    reservation.complete()
                    self?.markFailed()
                    return
                }
                guard !infoFlags.contains(.frameDropped), let sampleBuffer else {
                    failure(metadata, false)
                    reservation.complete()
                    return
                }
                output(sampleBuffer, metadata, reservation.complete)
            }
            if status != noErr {
                reservation.complete()
                markFailed()
                return .failed
            }
            if flags.contains(.frameDropped) {
                reservation.complete()
                return .droppedForBackpressure
            }
            return .submitted
        }

        /// Quality mode requires the pixel buffer to match the geometry
        /// negotiated for this encoder instance, with no additional libwebrtc
        /// adaptation. Performance mode explicitly permits libwebrtc's
        /// crop/scale wrapper and performs that requested adaptation once into
        /// the VT pool.
        func pixelBuffer(
            preparing source: RTCCVPixelBuffer,
            targetWidth: Int,
            targetHeight: Int
        ) -> CVPixelBuffer? {
            let backing = source.pixelBuffer
            let backingMatches = CVPixelBufferGetWidth(backing) == targetWidth
                && CVPixelBufferGetHeight(backing) == targetHeight
            let requiresAdaptation = source.requiresCropping()
                || source.requiresScaling(
                    toWidth: Int32(targetWidth),
                    height: Int32(targetHeight)
                )
                || !backingMatches
            guard requiresAdaptation else { return backing }
            let isEncoderAlignmentCrop = source.cropWidth == targetWidth
                && source.cropHeight == targetHeight
                && source.cropX == 0
                && source.cropY == 0
                && CVPixelBufferGetWidth(backing) - targetWidth >= 0
                && CVPixelBufferGetWidth(backing) - targetWidth <= 1
                && CVPixelBufferGetHeight(backing) - targetHeight >= 0
                && CVPixelBufferGetHeight(backing) - targetHeight <= 1
                && !source.requiresScaling(
                    toWidth: Int32(targetWidth),
                    height: Int32(targetHeight)
                )
            guard (allowsSourceAdaptation || isEncoderAlignmentCrop),
                  let pool = VTCompressionSessionGetPixelBufferPool(session)
            else {
                return nil
            }

            var output: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pool,
                &output
            ) == kCVReturnSuccess, let output else {
                return nil
            }
            let temporaryByteCount = max(
                0,
                Int(source.bufferSizeForCroppingAndScaling(
                    toWidth: Int32(targetWidth),
                    height: Int32(targetHeight)
                ))
            )
            if cropAndScaleTemporaryBuffer.count < temporaryByteCount {
                cropAndScaleTemporaryBuffer = [UInt8](
                    repeating: 0,
                    count: temporaryByteCount
                )
            }
            let succeeded = cropAndScaleTemporaryBuffer.withUnsafeMutableBytes { bytes in
                source.cropAndScale(
                    to: output,
                    withTempBuffer: bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                )
            }
            return succeeded ? output : nil
        }

        func invalidate() {
            guard !invalidated else { return }
            invalidated = true
            VTCompressionSessionInvalidate(session)
            submissionGate.cancelAll()
        }

        /// Thread-safe reference-chain invalidation used by asynchronous output
        /// paths. Outstanding samples check `isHealthy` before RTC delivery;
        /// the state queue rebuilds this session before accepting new input.
        func invalidateReferenceChain() {
            markFailed()
        }

        private func markFailed() {
            healthLock.withLock {
                hasFailed = true
            }
        }

        private func configureQualityRateControl(
            _ plan: WebRTCH264RateControlPlan
        ) -> Bool {
            setQualitySoftAverage(plan)
        }

        /// Clip's VideoToolbox quality mode: Quality controls
        /// visual intent, AverageBitRate uses the selected Mbps as a soft
        /// target, and there is deliberately no encoder-side VBV or
        /// DataRateLimits clamp. RTP pacing remains the authoritative ceiling.
        private func setQualitySoftAverage(
            _ plan: WebRTCH264RateControlPlan
        ) -> Bool {
            if #available(macOS 26.0, *) {
                _ = VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_VariableBitRate,
                    value: nil
                )
                _ = VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_VBVMaxBitRate,
                    value: nil
                )
            }
            _ = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_DataRateLimits,
                value: nil
            )
            return VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: plan.targetBitrateBps)
            ) == noErr
        }

        /// Low-latency Performance encoding follows WebRTC's current estimate
        /// through AverageBitRate. Do not also set DataRateLimits here: on the
        /// macOS hardware path used by ordinary Retina windows, VideoToolbox
        /// accepts the property write but then rejects session preparation
        /// because DRL is incompatible with that encoder's lookahead feature.
        private func setPerformanceAverage(
            _ plan: WebRTCH264RateControlPlan
        ) -> Bool {
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: plan.targetBitrateBps)
            ) == noErr
        }

        private func set(_ key: CFString, _ value: CFTypeRef) throws {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                throw SessionError.cannotConfigure(status)
            }
        }

        private func setIfSupported(
            _ key: CFString,
            _ value: CFTypeRef
        ) throws {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr || status == kVTPropertyNotSupportedErr else {
                throw SessionError.cannotConfigure(status)
            }
        }
    }
}

/// Converts VideoToolbox's length-prefixed H.264 sample into the Annex-B form
/// expected by libwebrtc. IDR access units include their negotiated SPS/PPS so
/// a newly joined viewer and every PLI response are independently decodable.
struct H264AnnexBAccessUnit: Equatable, Sendable {
    static let startCode = Data([0, 0, 0, 1])

    let data: Data
    let isKeyFrame: Bool
    let width: Int
    let height: Int

    init?(sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = sampleBuffer.formatDescription,
              CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_H264,
              let blockBuffer = sampleBuffer.dataBuffer
        else {
            return nil
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        width = Int(dimensions.width)
        height = Int(dimensions.height)

        isKeyFrame = Self.isSyncSample(sampleBuffer)
        var result = Data()
        var nalHeaderLength: Int32 = 4
        if isKeyFrame {
            guard Self.appendParameterSets(
                from: formatDescription,
                to: &result,
                nalHeaderLength: &nalHeaderLength
            ) else {
                return nil
            }
        } else {
            guard Self.readNALHeaderLength(
                from: formatDescription,
                into: &nalHeaderLength
            ) else {
                return nil
            }
        }

        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        var avcc = Data(count: byteCount)
        let copyStatus = avcc.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: baseAddress
            )
        }
        guard copyStatus == kCMBlockBufferNoErr,
              Self.appendNALUnits(
                  from: avcc,
                  headerLength: Int(nalHeaderLength),
                  to: &result
              ),
              !result.isEmpty
        else {
            return nil
        }
        data = result
    }

    private static func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]],
            let first = attachments.first
        else {
            return true
        }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private static func appendParameterSets(
        from formatDescription: CMFormatDescription,
        to output: inout Data,
        nalHeaderLength: inout Int32
    ) -> Bool {
        var count = 0
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let first = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )
        guard first == noErr, count > 0 else { return false }

        for index in 0 ..< count {
            pointer = nil
            size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { return false }
            output.append(startCode)
            output.append(pointer, count: size)
        }
        return (1 ... 4).contains(Int(nalHeaderLength))
    }

    private static func readNALHeaderLength(
        from formatDescription: CMFormatDescription,
        into nalHeaderLength: inout Int32
    ) -> Bool {
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )
        return status == noErr && (1 ... 4).contains(Int(nalHeaderLength))
    }

    static func appendNALUnits(
        from avcc: Data,
        headerLength: Int,
        to output: inout Data
    ) -> Bool {
        guard (1 ... 4).contains(headerLength) else { return false }
        var offset = 0
        while offset < avcc.count {
            guard offset + headerLength <= avcc.count else { return false }
            var length = 0
            for byte in avcc[offset ..< offset + headerLength] {
                length = (length << 8) | Int(byte)
            }
            offset += headerLength
            guard length > 0, offset + length <= avcc.count else { return false }
            output.append(startCode)
            output.append(avcc[offset ..< offset + length])
            offset += length
        }
        return offset == avcc.count
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
