@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ClipMedia

@Suite("Native VideoToolbox quality acceptance", .serialized)
struct NativeQualityPipelineTests {
    @Test("Quality metrics reject visible blur instead of only checking decode success")
    func metricsAreSensitiveToLostScreenDetail() {
        let reference = QualityFixture.lumaFrame(index: 9, framesPerSecond: 30)
        let identical = ScreenContentQualityMetrics.compare(reference, reference)
        let blurred = ScreenContentQualityMetrics.compare(
            reference,
            reference.boxBlurred(radius: 2)
        )

        #expect(abs(identical.lumaSSIM - 1) < 0.000_001)
        #expect(abs(identical.edgeRetention - 1) < 0.000_001)
        #expect(blurred.lumaSSIM < 0.985)
        #expect(blurred.edgeRetention < 0.95)
    }

    @Test("Quality-oriented master is materially sharper than the former ABR-only writer")
    func qualityMasterImprovesOnFormerABROnlyEncoding() async throws {
        let qualityURL = qualityTemporaryURL(named: "quality-ab")
        let formerABRURL = qualityTemporaryURL(named: "former-abr-ab")
        defer {
            try? FileManager.default.removeItem(at: qualityURL)
            try? FileManager.default.removeItem(at: formerABRURL)
        }

        let framesPerSecond = 30
        let frameCount = 30
        let comparisonBitRate = 550_000
        let references = try await writeQualityMaster(
            to: qualityURL,
            frameCount: frameCount,
            framesPerSecond: framesPerSecond,
            videoQuality: 0.98
        )
        try await writeFormerABROnlyMaster(
            to: formerABRURL,
            frameCount: frameCount,
            framesPerSecond: framesPerSecond,
            videoBitRate: comparisonBitRate
        )

        let qualityFrames = try await QualityMediaDecoder.decodeVideo(qualityURL)
        let formerABRFrames = try await QualityMediaDecoder.decodeVideo(formerABRURL)
        let qualityScore = ScreenContentQualityMetrics.aggregate(
            references: references,
            candidates: qualityFrames.map(\.luma)
        )
        let formerABRScore = ScreenContentQualityMetrics.aggregate(
            references: references,
            candidates: formerABRFrames.map(\.luma)
        )
        let qualityError = ScreenContentQualityMetrics.averageAbsoluteLumaError(
            references: references,
            candidates: qualityFrames.map(\.luma)
        )
        let formerABRError = ScreenContentQualityMetrics.averageAbsoluteLumaError(
            references: references,
            candidates: formerABRFrames.map(\.luma)
        )

        #expect(qualityScore.comparedFrameCount == frameCount)
        #expect(formerABRScore.comparedFrameCount == frameCount)
        // At the top of SSIM's 0...1 range a one-thousandth gain is large;
        // require it alongside a substantial reduction in absolute luma error
        // so encoder noise cannot create a misleading score-only win.
        #expect(qualityScore.averageLumaSSIM >= formerABRScore.averageLumaSSIM + 0.001)
        #expect(qualityError <= formerABRError * 0.8)
        #expect(qualityScore.averageEdgeRetention >= formerABRScore.averageEdgeRetention)
    }

    @Test(
        "Capture masters retain native geometry, 30/60 FPS motion, color, and fine detail",
        arguments: [30, 60]
    )
    func mastersMeetScreenContentQualityFloor(framesPerSecond: Int) async throws {
        let url = qualityTemporaryURL(named: "master-\(framesPerSecond)fps")
        defer { try? FileManager.default.removeItem(at: url) }

        let frameCount = framesPerSecond == 30 ? 18 : 36
        let references = try await writeQualityMaster(
            to: url,
            frameCount: frameCount,
            framesPerSecond: framesPerSecond
        )
        let inspection = try await MediaInspector.inspect(url)
        let format = try await inspectQualityVideoFormat(url)
        let decoded = try await QualityMediaDecoder.decodeVideo(url)
        let quality = ScreenContentQualityMetrics.aggregate(
            references: references,
            candidates: decoded.map(\.luma)
        )

        // This is the capture-to-master no-scaling assertion: both the writer
        // configuration and the actual decoded samples remain at fixture size.
        #expect(inspection.width == QualityFixture.width)
        #expect(inspection.height == QualityFixture.height)
        #expect(decoded.allSatisfy {
            $0.luma.width == QualityFixture.width && $0.luma.height == QualityFixture.height
        })
        #expect(inspection.videoCodec == kCMVideoCodecType_H264)
        #expect(format.h264ProfileIDC == 100)
        #expect(format.hasRec709Description)
        #expect(abs(inspection.nominalFramesPerSecond - Double(framesPerSecond)) <= 0.1)
        #expect(decoded.count == frameCount)
        #expect(maximumTimestampGap(decoded) <= (2.0 / Double(framesPerSecond)) + 0.001)
        #expect(decoded.last?.presentationTime.seconds ?? 0 > 0)

        #expect(quality.comparedFrameCount == frameCount)
        #expect(quality.averageLumaSSIM >= 0.985)
        #expect(quality.averageEdgeRetention >= 0.95)
    }

    @Test("Crisp reuse and q98/q90/q70 transcodes meet native quality floors")
    func exportPresetsMeetScreenContentQualityFloors() async throws {
        let sourceURL = qualityTemporaryURL(named: "quality-source")
        let reusedCrispURL = qualityTemporaryURL(named: "quality-crisp-reuse")
        let transcodedCrispURL = qualityTemporaryURL(named: "quality-crisp-transcoded")
        let compactURL = qualityTemporaryURL(named: "quality-compact")
        let smallestURL = qualityTemporaryURL(named: "quality-smallest")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: reusedCrispURL)
            try? FileManager.default.removeItem(at: transcodedCrispURL)
            try? FileManager.default.removeItem(at: compactURL)
            try? FileManager.default.removeItem(at: smallestURL)
        }

        let framesPerSecond = 30
        let frameCount = 36
        _ = try await writeQualityMaster(
            to: sourceURL,
            frameCount: frameCount,
            framesPerSecond: framesPerSecond
        )
        let sourceInspection = try await MediaInspector.inspect(sourceURL)
        let sourceFrames = try await QualityMediaDecoder.decodeVideo(sourceURL)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let crisp = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: sourceInspection.width,
            sourceHeight: sourceInspection.height,
            sourceFramesPerSecond: framesPerSecond,
            videoQuality: 0.98,
            sourceVideoQuality: 0.98
        )

        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: reusedCrispURL,
            timeRange: nil,
            configuration: crisp
        )
        #expect(try Data(contentsOf: reusedCrispURL) == sourceBytes)

        // Unknown source quality deliberately disables reuse so q98 is measured
        // as a second full-range H.264 generation on the same frames as q90/q70.
        let transcodedCrisp = MediaExportConfigurationFactory.make(
            preset: .crisp,
            sourceWidth: sourceInspection.width,
            sourceHeight: sourceInspection.height,
            sourceFramesPerSecond: framesPerSecond,
            videoQuality: 0.98,
            sourceVideoQuality: nil
        )
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: transcodedCrispURL,
            timeRange: nil,
            configuration: transcodedCrisp
        )

        let compact = MediaExportConfigurationFactory.make(
            preset: .compact,
            sourceWidth: sourceInspection.width,
            sourceHeight: sourceInspection.height,
            sourceFramesPerSecond: framesPerSecond,
            videoQuality: 0.90,
            sourceVideoQuality: 0.98
        )
        #expect(compact.width == sourceInspection.width)
        #expect(compact.height == sourceInspection.height)
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: compactURL,
            timeRange: nil,
            configuration: compact
        )

        let smallest = MediaExportConfigurationFactory.make(
            preset: .smallest,
            sourceWidth: sourceInspection.width,
            sourceHeight: sourceInspection.height,
            sourceFramesPerSecond: framesPerSecond,
            videoQuality: 0.70,
            sourceVideoQuality: 0.98
        )
        _ = try await NativeAssetExporter().export(
            sourceURL: sourceURL,
            destinationURL: smallestURL,
            timeRange: nil,
            configuration: smallest
        )

        let crispInspection = try await MediaInspector.inspect(transcodedCrispURL)
        let compactInspection = try await MediaInspector.inspect(compactURL)
        let smallestInspection = try await MediaInspector.inspect(smallestURL)
        let crispFormat = try await inspectQualityVideoFormat(transcodedCrispURL)
        let compactFormat = try await inspectQualityVideoFormat(compactURL)
        let smallestFormat = try await inspectQualityVideoFormat(smallestURL)
        let crispFrames = try await QualityMediaDecoder.decodeVideo(transcodedCrispURL)
        let compactFrames = try await QualityMediaDecoder.decodeVideo(compactURL)
        let smallestFrames = try await QualityMediaDecoder.decodeVideo(smallestURL)
        let crispQuality = ScreenContentQualityMetrics.aggregate(
            references: sourceFrames.map(\.luma),
            candidates: crispFrames.map(\.luma)
        )
        let compactQuality = ScreenContentQualityMetrics.aggregate(
            references: sourceFrames.map(\.luma),
            candidates: compactFrames.map(\.luma)
        )
        let smallestQuality = ScreenContentQualityMetrics.aggregate(
            references: sourceFrames.map(\.luma),
            candidates: smallestFrames.map(\.luma)
        )

        #expect(crispInspection.videoCodec == kCMVideoCodecType_H264)
        #expect(compactInspection.videoCodec == kCMVideoCodecType_H264)
        #expect(smallestInspection.videoCodec == kCMVideoCodecType_H264)
        #expect(crispFormat.h264ProfileIDC == 100)
        #expect(compactFormat.h264ProfileIDC == 100)
        #expect(smallestFormat.h264ProfileIDC == 100)
        #expect(crispFormat.hasRec709Description)
        #expect(compactFormat.hasRec709Description)
        #expect(smallestFormat.hasRec709Description)
        #expect(crispInspection.width == QualityFixture.width)
        #expect(crispInspection.height == QualityFixture.height)
        #expect(compactInspection.width == QualityFixture.width)
        #expect(compactInspection.height == QualityFixture.height)
        #expect(smallestInspection.width == QualityFixture.width)
        #expect(smallestInspection.height == QualityFixture.height)
        #expect(try Data(contentsOf: compactURL) != sourceBytes)
        #expect(try Data(contentsOf: smallestURL) != sourceBytes)
        #expect(abs(crispInspection.duration - sourceInspection.duration) <= 1.0 / 30.0)
        #expect(maximumTimestampGap(crispFrames) <= (2.0 / 30.0) + 0.001)
        #expect(maximumTimestampGap(compactFrames) <= (2.0 / 30.0) + 0.001)

        #expect(crispQuality.comparedFrameCount == frameCount)
        #expect(crispQuality.averageLumaSSIM >= 0.98)
        #expect(crispQuality.averageEdgeRetention >= 0.92)
        #expect(compactQuality.comparedFrameCount == frameCount)
        #expect(compactQuality.averageLumaSSIM >= 0.96)
        #expect(compactQuality.averageEdgeRetention >= 0.85)
        #expect(smallestQuality.comparedFrameCount == frameCount)
        #expect(smallestQuality.averageLumaSSIM >= 0.94)
        #expect(smallestQuality.averageEdgeRetention >= 0.80)
        #expect(maximumTimestampGap(smallestFrames) <= (2.0 / Double(framesPerSecond)) + 0.001)

        print(
            "Quality ladder fixture: "
                + "q98 SSIM=\(crispQuality.averageLumaSSIM) "
                + "edges=\(crispQuality.averageEdgeRetention) "
                + "bytes=\(crispInspection.fileSize); "
                + "q90 SSIM=\(compactQuality.averageLumaSSIM) "
                + "edges=\(compactQuality.averageEdgeRetention) "
                + "bytes=\(compactInspection.fileSize); "
                + "q70 SSIM=\(smallestQuality.averageLumaSSIM) "
                + "edges=\(smallestQuality.averageEdgeRetention) "
                + "bytes=\(smallestInspection.fileSize)"
        )
    }
}

private struct QualityVideoFormat {
    let h264ProfileIDC: Int?
    let hasRec709Description: Bool
}

private func inspectQualityVideoFormat(_ url: URL) async throws -> QualityVideoFormat {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first,
          let description = try await track.load(.formatDescriptions).first else {
        throw QualityTestError.missingVideoTrack
    }
    let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary? ?? [:]
    let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
        as? NSDictionary
    let avcConfiguration = (atoms?["avcC"] as? Data)
        ?? (atoms?["avcC"] as? NSData).map { $0 as Data }
    let profile = avcConfiguration.flatMap { data in
        data.count > 1 ? Int(data[data.index(data.startIndex, offsetBy: 1)]) : nil
    }
    let hasRec709 = (extensions[kCVImageBufferColorPrimariesKey] as? String)
        == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        && (extensions[kCVImageBufferTransferFunctionKey] as? String)
            == (kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        && (extensions[kCVImageBufferYCbCrMatrixKey] as? String)
            == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    return QualityVideoFormat(
        h264ProfileIDC: profile,
        hasRec709Description: hasRec709
    )
}

private func maximumTimestampGap(_ frames: [DecodedQualityFrame]) -> Double {
    zip(frames, frames.dropFirst()).reduce(0) { maximum, pair in
        max(maximum, pair.1.presentationTime.seconds - pair.0.presentationTime.seconds)
    }
}

private func writeQualityMaster(
    to outputURL: URL,
    frameCount: Int,
    framesPerSecond: Int,
    videoQuality: Double = 0.98
) async throws -> [LumaFrame] {
    let configuration = RecordingConfiguration(
        width: QualityFixture.width,
        height: QualityFixture.height,
        framesPerSecond: framesPerSecond,
        videoQuality: videoQuality,
        showsCursor: false,
        audioMode: .off
    )
    #expect(configuration.width == QualityFixture.width)
    #expect(configuration.height == QualityFixture.height)

    let writer = try AssetWriterSession(
        outputURL: outputURL,
        configuration: configuration
    )
    try writer.start()
    var references: [LumaFrame] = []
    references.reserveCapacity(frameCount)
    for index in 0..<frameCount {
        let bytes = QualityFixture.bgraFrame(
            index: index,
            framesPerSecond: framesPerSecond
        )
        references.append(.fromBGRA(
            bytes,
            width: QualityFixture.width,
            height: QualityFixture.height,
            bytesPerRow: QualityFixture.width * 4
        ))
        let sample = try makeQualitySample(
            bytes: bytes,
            frameIndex: index,
            framesPerSecond: framesPerSecond
        )
        try appendQualitySample(sample, to: writer)
    }
    _ = try await writer.finish()
    return references
}

/// Reproduces the superseded AVAssetWriter input configuration: H.264 High
/// profile plus average bitrate, but no VideoToolbox quality control. It is
/// intentionally test-only and exists solely as an A/B regression baseline.
private func writeFormerABROnlyMaster(
    to outputURL: URL,
    frameCount: Int,
    framesPerSecond: Int,
    videoBitRate: Int
) async throws {
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: QualityFixture.width,
            AVVideoHeightKey: QualityFixture.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
    )
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else { throw QualityTestError.cannotAddWriterInput }
    writer.add(input)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: QualityFixture.width,
            kCVPixelBufferHeightKey as String: QualityFixture.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
    )
    guard writer.startWriting() else { throw QualityTestError.cannotStartWriter }
    writer.startSession(atSourceTime: .zero)

    for index in 0..<frameCount {
        for _ in 0..<2_000 where !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard input.isReadyForMoreMediaData else {
            writer.cancelWriting()
            throw QualityTestError.writerBackPressureTimeout
        }
        let bytes = QualityFixture.bgraFrame(
            index: index,
            framesPerSecond: framesPerSecond
        )
        let pixelBuffer = try makeQualityPixelBuffer(bytes: bytes)
        guard adaptor.append(
            pixelBuffer,
            withPresentationTime: CMTime(
                value: CMTimeValue(index),
                timescale: CMTimeScale(framesPerSecond)
            )
        ) else {
            writer.cancelWriting()
            throw QualityTestError.writerAppendFailed
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw QualityTestError.writerFinishFailed }
}

private func makeQualitySample(
    bytes: [UInt8],
    frameIndex: Int,
    framesPerSecond: Int
) throws -> CMSampleBuffer {
    let pixelBuffer = try makeQualityPixelBuffer(bytes: bytes)

    var description: CMVideoFormatDescription?
    let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &description
    )
    guard descriptionStatus == noErr, let description else {
        throw QualityTestError.cannotCreateFormatDescription(descriptionStatus)
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(framesPerSecond)),
        presentationTimeStamp: CMTime(
            value: CMTimeValue(frameIndex),
            timescale: CMTimeScale(framesPerSecond)
        ),
        decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: description,
        sampleTiming: &timing,
        sampleBufferOut: &sample
    )
    guard sampleStatus == noErr, let sample else {
        throw QualityTestError.cannotCreateSampleBuffer(sampleStatus)
    }
    return sample
}

private func makeQualityPixelBuffer(bytes: [UInt8]) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        QualityFixture.width,
        QualityFixture.height,
        kCVPixelFormatType_32BGRA,
        [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw QualityTestError.cannotCreatePixelBuffer(status)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw QualityTestError.unsupportedPixelBuffer
    }
    let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    bytes.withUnsafeBytes { source in
        guard let sourceBase = source.baseAddress else { return }
        for row in 0..<QualityFixture.height {
            memcpy(
                destination.advanced(by: row * destinationBytesPerRow),
                sourceBase.advanced(by: row * QualityFixture.width * 4),
                QualityFixture.width * 4
            )
        }
    }

    return pixelBuffer
}

private func appendQualitySample(
    _ sample: CMSampleBuffer,
    to writer: AssetWriterSession
) throws {
    for _ in 0..<2_000 {
        if try writer.append(sample, kind: .video) { return }
        Thread.sleep(forTimeInterval: 0.001)
    }
    throw QualityTestError.writerBackPressureTimeout
}

private func qualityTemporaryURL(named name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("clip-\(name)-\(UUID().uuidString)")
        .appendingPathExtension("mp4")
}
