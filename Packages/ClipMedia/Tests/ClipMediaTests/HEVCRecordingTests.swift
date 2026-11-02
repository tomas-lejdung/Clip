@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ClipMedia

@Suite("Production HEVC recording", .serialized)
struct HEVCRecordingTests {
    @Test(arguments: [30, 60], [false, true])
    func stopPreservesStaticTailAndExcludesPausedWallTime(framesPerSecond: Int, stopWhilePaused: Bool) async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("HEVC-tail-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let writer = try AssetWriterSession(outputURL: output,
            configuration: RecordingConfiguration(width: 160, height: 90, framesPerSecond: framesPerSecond))
        try writer.start()
        try #require(try writer.append(sample(at: CMTime(value: 100, timescale: 1), fps: framesPerSecond), kind: .video))
        try #require(try writer.append(sample(at: CMTime(value: Int64(100 * framesPerSecond + 1), timescale: CMTimeScale(framesPerSecond)),
            fps: framesPerSecond), kind: .video))
        if stopWhilePaused { try writer.pause(at: CMTime(value: 102, timescale: 1)) }
        _ = try await writer.finish(at: CMTime(value: 105, timescale: 1))
        let inspection = try await MediaInspector.inspect(output)
        #expect(inspection.videoCodec == kCMVideoCodecType_HEVC)
        #expect(inspection.width == 160 && inspection.height == 90)
        #expect(abs(inspection.duration - (stopWhilePaused ? 2 : 5)) < 0.001)
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetExtension(description,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String == kCMFormatDescriptionTransferFunction_sRGB as String)
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(samples)
        try #require(reader.startReading())
        var times: [CMTime] = []
        while let sample = samples.copyNextSampleBuffer() {
            // AVAssetReader can include zero-sample edit-boundary markers.
            if sample.numSamples > 0 { times.append(sample.presentationTimeStamp) }
        }
        #expect(reader.status == .completed && times.count == 3)
        #expect(abs((times.last! + CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))).seconds - inspection.duration) < 0.001)
    }

    @Test func convertsDisplayProfileWithoutChangingTheRaster() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let input = try pixelBuffer(width: 160, height: 90, space: p3)
        let normalizer = try RecordingPixelNormalizer(width: 160, height: 90)
        let output = try normalizer.normalize(input)
        #expect(CVPixelBufferGetWidth(output) == 160 && CVPixelBufferGetHeight(output) == 90)
        #expect(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String == kCVImageBufferTransferFunction_sRGB as String)
        let reference = try #require(CGColor(colorSpace: p3,
            components: [200.0 / 255, 60.0 / 255, 40.0 / 255, 1])?.converted(to: sRGB, intent: .relativeColorimetric, options: nil)?.components)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let pixels = try #require(CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self))
        for (channel, component) in [(2, reference[0]), (1, reference[1]), (0, reference[2])] {
            let expected = Int((min(1, max(0, component)) * 255).rounded())
            #expect(abs(Int(pixels[channel]) - expected) <= 3)
        }
        #expect(pixels[2] != 200 || pixels[1] != 60 || pixels[0] != 40)
    }

    @Test("A static hold before Pause is preserved through Resume and Stop", arguments: [30, 60])
    func resumesAfterAStaticHold(framesPerSecond: Int) async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("HEVC-static-resume-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let writer = try AssetWriterSession(outputURL: output,
            configuration: RecordingConfiguration(width: 160, height: 90, framesPerSecond: framesPerSecond))
        let interval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        try writer.start()
        try #require(try writer.append(sample(at: CMTime(value: 100, timescale: 1), fps: framesPerSecond), kind: .video))
        try #require(try writer.append(sample(at: CMTime(value: 100, timescale: 1) + interval, fps: framesPerSecond), kind: .video))
        try writer.pause(at: CMTime(value: 102, timescale: 1))
        try writer.resume(at: CMTime(value: 104, timescale: 1))
        try #require(try writer.append(sample(at: CMTime(value: 104, timescale: 1) + interval, fps: framesPerSecond), kind: .video))
        _ = try await writer.finish(at: CMTime(value: 107, timescale: 1))
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 5) < 0.001)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(samples)
        try #require(reader.startReading())
        var times: [Double] = []
        while let sample = samples.copyNextSampleBuffer() {
            if sample.numSamples > 0 { times.append(sample.presentationTimeStamp.seconds) }
        }
        let expected = [0, interval.seconds, 2 + interval.seconds, 5 - interval.seconds]
        #expect(reader.status == .completed && times.count == expected.count)
        for (actual, expected) in zip(times, expected) { #expect(abs(actual - expected) < 0.001) }
    }

    @Test func rejectsUnknownColorAndGeometryRatherThanRetaggingOrScaling() throws {
        let normalizer = try RecordingPixelNormalizer(width: 160, height: 90)
        let unknown = try pixelBuffer(width: 160, height: 90, space: nil)
        #expect(throws: AssetWriterSessionError.self) { _ = try normalizer.normalize(unknown) }
        let wrongSize = try pixelBuffer(width: 162, height: 90, space: CGColorSpace(name: CGColorSpace.sRGB))
        #expect(throws: ScreenVideoSampleDimensionError.self) { _ = try normalizer.normalize(wrongSize) }
    }

    private func sample(at time: CMTime, fps: Int) throws -> CMSampleBuffer {
        let image = try pixelBuffer(width: 160, height: 90, space: CGColorSpace(name: CGColorSpace.sRGB))
        var description: CMVideoFormatDescription?
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try #require(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }

    private func pixelBuffer(width: Int, height: Int, space: CGColorSpace?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let image = try #require(buffer)
        if let space { CVBufferSetAttachment(image, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate) }
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let bytes = try #require(CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self))
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * CVPixelBufferGetBytesPerRow(image) + x * 4
                bytes[offset] = 40; bytes[offset + 1] = 60; bytes[offset + 2] = 200; bytes[offset + 3] = 255
            }
        }
        return image
    }
}
