import CoreVideo
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import ClipLiveShareWebRTC

extension NativeMediaResourceTests {
@Suite("Native VideoToolbox WebRTC H264", .serialized)
struct WebRTCVideoToolboxH264EncoderTests {
    @Test("negotiated constrained-high profile stays constrained in VideoToolbox")
    func h264ProfileFamilies() {
        #expect(WebRTCH264ProfileFamily(profileLevelID: "640c34") == .constrainedHigh)
        #expect(WebRTCH264ProfileFamily(profileLevelID: "640034") == .high)
        #expect(WebRTCH264ProfileFamily(profileLevelID: "4d0034") == .main)
        #expect(WebRTCH264ProfileFamily(profileLevelID: "42e034") == .constrainedBaseline)
        #expect(WebRTCH264ProfileFamily(profileLevelID: "420034") == .baseline)
    }

    @Test("quality and performance keep visual intent separate from the bitrate ceiling")
    func rateControlPlans() {
        let quality = WebRTCH264RateControlPlan(
            configuration: .quality,
            maximumBitrateBps: 20_000_000
        )
        #expect(quality.mode == .quality)
        #expect(quality.quality == 0.98)
        #expect(!quality.prioritizesSpeed)
        #expect(quality.maximumBitrateBps == 20_000_000)
        #expect(quality.targetBitrateBps == 20_000_000)

        let performance = WebRTCH264RateControlPlan(
            configuration: .performance,
            maximumBitrateBps: 6_000_000
        )
        #expect(performance.mode == .performance)
        #expect(performance.quality == nil)
        #expect(performance.prioritizesSpeed)
        #expect(performance.maximumBitrateBps == 6_000_000)
        #expect(performance.targetBitrateBps == 6_000_000)
    }

    @Test("start bitrate is clamped by the configured ceiling")
    func bitrateEnvelope() {
        let ordinary = WebRTCH264BitrateEnvelope(
            startKbit: 1_500,
            maximumKbit: 20_000,
            minimumKbit: 100
        )
        #expect(ordinary.initialBitrateBps == 1_500_000)
        #expect(ordinary.maximumBitrateBps == 20_000_000)
        #expect(ordinary.clamped(50_000_000) == 20_000_000)

        let clamped = WebRTCH264BitrateEnvelope(
            startKbit: 8_000,
            maximumKbit: 6_000,
            minimumKbit: 100
        )
        #expect(clamped.initialBitrateBps == 6_000_000)
    }

    @Test("Quality targets the selected ceiling while Performance follows the network")
    func bitratePolicy() {
        #expect(WebRTCH264BitratePolicy.encoderTargetBitsPerSecond(
            mode: .quality,
            configuredMaximumBitrateBps: 20_000_000,
            networkTargetBitrateBps: 1_500_000
        ) == 20_000_000)
        #expect(WebRTCH264BitratePolicy.encoderTargetBitsPerSecond(
            mode: .performance,
            configuredMaximumBitrateBps: 20_000_000,
            networkTargetBitrateBps: 1_500_000
        ) == 1_500_000)
        #expect(WebRTCH264BitratePolicy.encoderTargetBitsPerSecond(
            mode: .performance,
            configuredMaximumBitrateBps: 6_000_000,
            networkTargetBitrateBps: 50_000_000
        ) == 6_000_000)
    }

    @Test("rate updates stay live while mode changes rebuild")
    func sessionUpdatePolicy() {
        let qualitySix = WebRTCH264RateControlPlan(
            configuration: .quality,
            maximumBitrateBps: 6_000_000
        )
        let qualityMaterial = WebRTCH264RateControlPlan(
            configuration: .quality,
            maximumBitrateBps: 3_000_000
        )
        #expect(!WebRTCH264SessionUpdatePolicy.requiresImmediateRebuild(
            current: qualitySix,
            currentFramesPerSecond: 30,
            requested: qualityMaterial,
            requestedFramesPerSecond: 30
        ))
        #expect(WebRTCH264SessionUpdatePolicy.requiresImmediateRebuild(
            current: qualitySix,
            currentFramesPerSecond: 30,
            requested: WebRTCH264RateControlPlan(
                configuration: .performance,
                maximumBitrateBps: 3_000_000
            ),
            requestedFramesPerSecond: 30
        ))
        #expect(!WebRTCH264SessionUpdatePolicy.requiresImmediateRebuild(
            current: qualitySix,
            currentFramesPerSecond: 30,
            requested: qualityMaterial,
            requestedFramesPerSecond: 60
        ))

        let performance = WebRTCH264RateControlPlan(
            configuration: .performance,
            maximumBitrateBps: 500_000
        )
        #expect(!WebRTCH264SessionUpdatePolicy.requiresImmediateRebuild(
            current: performance,
            currentFramesPerSecond: 30,
            requested: WebRTCH264RateControlPlan(
                configuration: .performance,
                maximumBitrateBps: 20_000_000
            ),
            requestedFramesPerSecond: 30
        ))
    }

    @Test("latency policy bounds VideoToolbox and enables low-latency RC only for Performance High Profile")
    func latencyPolicy() {
        #expect(WebRTCH264LatencyPolicy.maximumFrameDelayCount == 1)
        #expect(WebRTCH264LatencyPolicy.suggestedLookAheadFrameCount == 0)
        #expect(WebRTCH264LatencyPolicy.maximumInFlightFrames == 2)
        #expect(WebRTCH264LatencyPolicy.maximumSupportedFramesPerSecond == 60)
        #expect(WebRTCH264LatencyPolicy.minimumOutputAgeNanoseconds == 100_000_000)
        let maximumAge = WebRTCH264LatencyPolicy.maximumOutputAgeNanoseconds(
            framesPerSecond: 30
        )
        #expect(maximumAge == 100_000_000)
        #expect(WebRTCH264LatencyPolicy.maximumOutputAgeNanoseconds(
            framesPerSecond: 60
        ) == 100_000_000)
        #expect(WebRTCH264LatencyPolicy.maximumOutputAgeNanoseconds(
            framesPerSecond: 15
        ) == 133_333_334)
        #expect(WebRTCH264LatencyPolicy.admittedUptimeNanoseconds(
            frameTimestampNanoseconds: 900,
            nowUptimeNanoseconds: 1_000
        ) == 900)
        #expect(WebRTCH264LatencyPolicy.admittedUptimeNanoseconds(
            frameTimestampNanoseconds: -1,
            nowUptimeNanoseconds: 1_000
        ) == 1_000)
        #expect(WebRTCH264LatencyPolicy.admittedUptimeNanoseconds(
            frameTimestampNanoseconds: 1_001,
            nowUptimeNanoseconds: 1_000
        ) == 1_000)
        #expect(!WebRTCH264LatencyPolicy.isOutputStale(
            admittedUptimeNanoseconds: 100,
            nowUptimeNanoseconds: 100 + maximumAge,
            maximumAgeNanoseconds: maximumAge
        ))
        #expect(WebRTCH264LatencyPolicy.isOutputStale(
            admittedUptimeNanoseconds: 100,
            nowUptimeNanoseconds: 101 + maximumAge,
            maximumAgeNanoseconds: maximumAge
        ))
        // Uptime values from incomparable clock epochs must not be discarded.
        #expect(!WebRTCH264LatencyPolicy.isOutputStale(
            admittedUptimeNanoseconds: 1_000,
            nowUptimeNanoseconds: 999,
            maximumAgeNanoseconds: maximumAge
        ))
        #expect(WebRTCH264LatencyPolicy.enablesLowLatencyRateControl(
            mode: .performance,
            profileLevelID: "640c34"
        ))
        #expect(!WebRTCH264LatencyPolicy.enablesLowLatencyRateControl(
            mode: .quality,
            profileLevelID: "640c34"
        ))
        #expect(!WebRTCH264LatencyPolicy.enablesLowLatencyRateControl(
            mode: .performance,
            profileLevelID: "42e034"
        ))
    }

    @Test("submission gate never admits more than two asynchronous frames")
    func submissionGate() throws {
        let gate = WebRTCH264FrameSubmissionGate(maximumInFlightFrames: 2)
        let first = try #require(gate.reserve())
        let second = try #require(gate.reserve())
        #expect(gate.pendingCount == 2)
        #expect(gate.reserve() == nil)
        #expect(gate.backpressureDropCount == 1)

        first.complete()
        #expect(gate.pendingCount == 1)
        let third = try #require(gate.reserve())
        #expect(gate.pendingCount == 2)

        // VT's synchronous info flags and asynchronous callback can both
        // report a drop; completion must remain idempotent in that race.
        first.complete()
        #expect(gate.pendingCount == 2)
        second.complete()
        third.complete()
        #expect(gate.pendingCount == 0)

        _ = try #require(gate.reserve())
        _ = try #require(gate.reserve())
        gate.cancelAll()
        #expect(gate.pendingCount == 0)
    }

    @Test("submission gate distinguishes transient saturation from a wedged callback")
    func timestampedSubmissionGate() throws {
        let gate = WebRTCH264FrameSubmissionGate(maximumInFlightFrames: 2)
        let first = try #require(Self.reservation(from: gate.admit(
            maximumAgeNanoseconds: 20,
            nowUptimeNanoseconds: 100
        )))
        let second = try #require(Self.reservation(from: gate.admit(
            maximumAgeNanoseconds: 20,
            nowUptimeNanoseconds: 110
        )))

        if case .saturated = gate.admit(
            maximumAgeNanoseconds: 20,
            nowUptimeNanoseconds: 119
        ) {
            // Expected: the oldest callback is still within its deadline.
        } else {
            Issue.record("a current full gate must report transient saturation")
        }
        if case .stalled = gate.admit(
            maximumAgeNanoseconds: 20,
            nowUptimeNanoseconds: 121
        ) {
            // Expected: the oldest callback is now past its deadline.
        } else {
            Issue.record("an overdue full gate must report a stalled session")
        }
        #expect(gate.backpressureDropCount == 2)

        first.complete()
        second.complete()
        #expect(gate.pendingCount == 0)
    }

    @Test("configuration controller counts aggregate submission pressure drops")
    func configurationControllerCountsSubmissionPressure() {
        let controller = WebRTCH264EncoderConfigurationController()
        #expect(controller.submissionBackpressureDropCount == 0)
        controller.recordSubmissionBackpressureDrop()
        controller.recordSubmissionBackpressureDrop()
        #expect(controller.submissionBackpressureDropCount == 2)
    }

    @Test("keyframe intent survives submission loss and only its accepted IDR clears it")
    func keyFrameRequestState() throws {
        var state = WebRTCH264KeyFrameRequestState()
        #expect(!state.isPending)

        state.request()
        let first = try #require(state.pendingIdentifier)
        state.request()
        let second = try #require(state.pendingIdentifier)
        #expect(second != first)

        // A keyframe for an earlier request cannot satisfy a newer explicit
        // PLI that arrived while the first IDR was still in flight.
        state.accepted(first)
        #expect(state.pendingIdentifier == second)
        state.accepted(second)
        #expect(!state.isPending)

        state.request()
        let third = try #require(state.pendingIdentifier)
        #expect(third != second)
        // A late completion from a redundant frame for the old request cannot
        // clear the newer PLI.
        state.accepted(first)
        #expect(state.pendingIdentifier == third)
        state.reset()
        #expect(!state.isPending)
    }

    @Test("live mode changes advance the shared encoder configuration")
    func modeController() {
        let controller = WebRTCH264EncoderConfigurationController(
            configuration: .quality
        )
        let initial = controller.snapshot()
        controller.updateMode(.performance)
        let changed = controller.snapshot()
        #expect(initial.configuration.mode == .quality)
        #expect(changed.configuration.mode == .performance)
        #expect(changed.revision == initial.revision + 1)

        controller.updateMode(.performance)
        #expect(controller.snapshot().revision == changed.revision)
    }

    @Test("live H264 controls preserve mode and advance the rebuild revision")
    func advancedConfigurationController() {
        let controller = WebRTCH264EncoderConfigurationController(
            configuration: .performance
        )
        let initial = controller.snapshot()
        let advanced = WebRTCH264AdvancedConfiguration(
            maximumQuantizer: 36,
            qualityFraction: 0.91,
            keyFrameIntervalSeconds: 5
        )

        controller.updateAdvancedConfiguration(advanced)
        let changed = controller.snapshot()
        #expect(changed.revision == initial.revision + 1)
        #expect(changed.configuration.mode == .performance)
        #expect(changed.configuration.maximumQuantizer == 36)
        #expect(changed.configuration.quality == 0.91)
        #expect(changed.configuration.keyFrameIntervalSeconds == 5)

        controller.updateAdvancedConfiguration(advanced)
        #expect(controller.snapshot().revision == changed.revision)
    }

    @Test("length-prefixed NAL units become complete Annex-B units")
    func annexBConversion() {
        let avcc = Data([
            0, 0, 0, 3, 0x65, 0xAA, 0xBB,
            0, 0, 0, 2, 0x41, 0xCC,
        ])
        var result = Data()
        #expect(H264AnnexBAccessUnit.appendNALUnits(
            from: avcc,
            headerLength: 4,
            to: &result
        ))
        #expect(result == Data([
            0, 0, 0, 1, 0x65, 0xAA, 0xBB,
            0, 0, 0, 1, 0x41, 0xCC,
        ]))

        var rejected = Data()
        #expect(!H264AnnexBAccessUnit.appendNALUnits(
            from: Data([0, 0, 0, 9, 0x65]),
            headerLength: 4,
            to: &rejected
        ))
    }

    @Test("hardware encoder preserves geometry and emits SPS, PPS, and IDR")
    func directHardwareEncode() throws {
        let codec = try #require(
            WebRTCH264EncoderFactory().supportedCodecs().first
        )
        let encoder = WebRTCVideoToolboxH264Encoder(
            codecInfo: codec,
            configurationController: .init(configuration: .quality)
        )
        defer { _ = encoder.release() }
        let scaling = try #require(encoder.scalingSettings())
        #expect(scaling.low == 28)
        #expect(scaling.high == 39)

        let settings = RTCVideoEncoderSettings()
        settings.name = "H264"
        settings.width = 320
        settings.height = 180
        settings.startBitrate = 4_000
        settings.maxBitrate = 4_000
        settings.minBitrate = 100
        settings.maxFramerate = 30
        settings.mode = .screensharing
        #expect(encoder.startEncode(with: settings, numberOfCores: 4) == 0)

        let output = EncodedOutputWaiter()
        encoder.setCallback { image, codecSpecific in
            let h264 = codecSpecific as? RTCCodecSpecificInfoH264
            output.receive(
                data: image.buffer,
                width: Int(image.encodedWidth),
                height: Int(image.encodedHeight),
                timeStamp: image.timeStamp,
                isKeyFrame: image.frameType == .videoFrameKey,
                packetizationMode: h264?.packetizationMode,
                qp: image.qp.intValue
            )
            return true
        }

        let pixelBuffer = try Self.makeFixture(width: 320, height: 180)
        let captureTimestamp = Int64(
            clamping: DispatchTime.now().uptimeNanoseconds
        )
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: captureTimestamp
        )
        frame.timeStamp = 90_000
        #expect(encoder.encode(
            frame,
            codecSpecificInfo: nil,
            frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]
        ) == 0)

        let encoded = try #require(output.wait(timeout: 3))
        #expect(encoded.width == 320)
        #expect(encoded.height == 180)
        #expect(encoded.timeStamp == 90_000)
        #expect(encoded.isKeyFrame)
        #expect(encoded.qp == -1)
        #expect(encoded.packetizationMode == .nonInterleaved)
        let nalTypes = Self.nalTypes(in: encoded.data)
        #expect(nalTypes.contains(7), "keyframe must carry SPS")
        #expect(nalTypes.contains(8), "keyframe must carry PPS")
        #expect(nalTypes.contains(5), "keyframe must carry an IDR slice")

        output.reset()
        let deltaFrame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        )
        deltaFrame.timeStamp = 93_000
        #expect(encoder.encode(
            deltaFrame,
            codecSpecificInfo: nil,
            frameTypes: [NSNumber(value: RTCFrameType.videoFrameDelta.rawValue)]
        ) == 0)
        let delta = try #require(output.wait(timeout: 3))
        #expect(!delta.isKeyFrame)
        let deltaNALTypes = Self.nalTypes(in: delta.data)
        #expect(!deltaNALTypes.contains(7), "delta frame must not repeat SPS")
        #expect(!deltaNALTypes.contains(8), "delta frame must not repeat PPS")
        #expect(deltaNALTypes.contains(1), "delta frame must carry a non-IDR slice")
    }

    @Test("only Performance applies libwebrtc's explicit source adaptation")
    func performanceSourceAdaptation() throws {
        let codec = try #require(
            WebRTCH264EncoderFactory().supportedCodecs().first
        )
        let source = try Self.makeFixture(width: 320, height: 180)
        let adapted = RTCCVPixelBuffer(
            pixelBuffer: source,
            adaptedWidth: 160,
            adaptedHeight: 90,
            cropWidth: 320,
            cropHeight: 180,
            cropX: 0,
            cropY: 0
        )
        let frame = RTCVideoFrame(
            buffer: adapted,
            rotation: ._0,
            timeStampNs: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        )
        frame.timeStamp = 180_000

        let quality = WebRTCVideoToolboxH264Encoder(
            codecInfo: codec,
            configurationController: .init(configuration: .quality)
        )
        defer { _ = quality.release() }
        #expect(quality.startEncode(
            with: Self.settings(width: 160, height: 90),
            numberOfCores: 4
        ) == 0)
        #expect(quality.encode(
            frame,
            codecSpecificInfo: nil,
            frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]
        ) == -1)

        let performance = WebRTCVideoToolboxH264Encoder(
            codecInfo: codec,
            configurationController: .init(configuration: .performance)
        )
        defer { _ = performance.release() }
        #expect(performance.startEncode(
            with: Self.settings(width: 160, height: 90),
            numberOfCores: 4
        ) == 0)
        let output = EncodedOutputWaiter()
        performance.setCallback { image, codecSpecific in
            output.receive(
                data: image.buffer,
                width: Int(image.encodedWidth),
                height: Int(image.encodedHeight),
                timeStamp: image.timeStamp,
                isKeyFrame: image.frameType == .videoFrameKey,
                packetizationMode: (codecSpecific as? RTCCodecSpecificInfoH264)?
                    .packetizationMode,
                qp: image.qp.intValue
            )
            return true
        }
        let performanceFrame = RTCVideoFrame(
            buffer: adapted,
            rotation: ._0,
            timeStampNs: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        )
        performanceFrame.timeStamp = 180_000
        #expect(performance.encode(
            performanceFrame,
            codecSpecificInfo: nil,
            frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]
        ) == 0)
        let encoded = try #require(output.wait(timeout: 3))
        #expect(encoded.width == 160)
        #expect(encoded.height == 90)
    }

    @Test("constrained-high Performance encodes a normal window through a live rate update")
    func constrainedHighPerformanceRateUpdate() throws {
        let codec = try #require(
            WebRTCH264EncoderFactory().supportedCodecs().first {
                $0.parameters["profile-level-id"]?.hasPrefix("640c") == true
            }
        )
        let encoder = WebRTCVideoToolboxH264Encoder(
            codecInfo: codec,
            configurationController: .init(configuration: .performance)
        )
        defer { _ = encoder.release() }

        // This matches the ordinary window geometry that exposed
        // VideoToolbox's DRL/lookahead incompatibility in the live app.
        #expect(encoder.startEncode(
            with: Self.settings(width: 1_334, height: 820),
            numberOfCores: 4
        ) == 0)

        let output = EncodedOutputWaiter()
        encoder.setCallback { image, codecSpecific in
            output.receive(
                data: image.buffer,
                width: Int(image.encodedWidth),
                height: Int(image.encodedHeight),
                timeStamp: image.timeStamp,
                isKeyFrame: image.frameType == .videoFrameKey,
                packetizationMode: (codecSpecific as? RTCCodecSpecificInfoH264)?
                    .packetizationMode,
                qp: image.qp.intValue
            )
            return true
        }

        let pixelBuffer = try Self.makeFixture(width: 1_334, height: 820)
        let first = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        )
        first.timeStamp = 270_000
        #expect(encoder.encode(
            first,
            codecSpecificInfo: nil,
            frameTypes: [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)]
        ) == 0)
        let initial = try #require(output.wait(timeout: 3))
        #expect(initial.width == 1_334)
        #expect(initial.height == 820)
        #expect(initial.isKeyFrame)

        output.reset()
        #expect(encoder.setBitrate(1_200, framerate: 30) == 0)
        let second = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        )
        second.timeStamp = 273_000
        #expect(encoder.encode(
            second,
            codecSpecificInfo: nil,
            frameTypes: [NSNumber(value: RTCFrameType.videoFrameDelta.rawValue)]
        ) == 0)
        let updated = try #require(output.wait(timeout: 3))
        #expect(updated.width == 1_334)
        #expect(updated.height == 820)
    }

    private static func settings(
        width: UInt16,
        height: UInt16
    ) -> RTCVideoEncoderSettings {
        let settings = RTCVideoEncoderSettings()
        settings.name = "H264"
        settings.width = width
        settings.height = height
        settings.startBitrate = 4_000
        settings.maxBitrate = 4_000
        settings.minBitrate = 100
        settings.maxFramerate = 30
        settings.mode = .screensharing
        return settings
    }

    private static func reservation(
        from admission: WebRTCH264FrameSubmissionGate.Admission
    ) -> WebRTCH264FrameSubmissionGate.Reservation? {
        guard case let .reserved(reservation) = admission else { return nil }
        return reservation
    }

    private static func makeFixture(width: Int, height: Int) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &output
        )
        let pixelBuffer = try #require(output)
        #expect(status == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!
            .assumingMemoryBound(to: UInt8.self)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = y * bytesPerRow + x * 4
                let checker = ((x / 4) + (y / 4)).isMultiple(of: 2)
                bytes[offset] = checker ? 0x10 : 0xF0
                bytes[offset + 1] = UInt8((x * 255) / width)
                bytes[offset + 2] = UInt8((y * 255) / height)
                bytes[offset + 3] = 0xFF
            }
        }
        return pixelBuffer
    }

    private static func nalTypes(in annexB: Data) -> [UInt8] {
        let bytes = [UInt8](annexB)
        guard bytes.count >= 5 else { return [] }
        var types: [UInt8] = []
        for index in 0 ... bytes.count - 5 where
            bytes[index] == 0 && bytes[index + 1] == 0
                && bytes[index + 2] == 0 && bytes[index + 3] == 1
        {
            types.append(bytes[index + 4] & 0x1F)
        }
        return types
    }
}
}

private final class EncodedOutputWaiter: @unchecked Sendable {
    struct Output: Sendable {
        let data: Data
        let width: Int
        let height: Int
        let timeStamp: UInt32
        let isKeyFrame: Bool
        let packetizationMode: RTCH264PacketizationMode?
        let qp: Int
    }

    private let condition = NSCondition()
    private var output: Output?

    func receive(
        data: Data,
        width: Int,
        height: Int,
        timeStamp: UInt32,
        isKeyFrame: Bool,
        packetizationMode: RTCH264PacketizationMode?,
        qp: Int
    ) {
        condition.lock()
        output = Output(
            data: data,
            width: width,
            height: height,
            timeStamp: timeStamp,
            isKeyFrame: isKeyFrame,
            packetizationMode: packetizationMode,
            qp: qp
        )
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Output? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while output == nil {
            guard condition.wait(until: deadline) else { return nil }
        }
        return output
    }

    func reset() {
        condition.lock()
        output = nil
        condition.unlock()
    }
}
