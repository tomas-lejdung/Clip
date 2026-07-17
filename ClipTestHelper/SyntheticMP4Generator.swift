@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum SyntheticMP4GeneratorError: LocalizedError {
    case cannotCreateWriter(String)
    case cannotAddVideoInput
    case cannotStartWriting(String)
    case cannotCreatePixelBuffer(CVReturn)
    case writerBackPressureTimeout
    case cannotAppendFrame(Int, String)
    case cannotFinishWriting(String)

    var errorDescription: String? {
        switch self {
        case let .cannotCreateWriter(message):
            "Could not create the synthetic MP4 writer: \(message)"
        case .cannotAddVideoInput:
            "Could not add the synthetic video input."
        case let .cannotStartWriting(message):
            "Could not start the synthetic MP4 writer: \(message)"
        case let .cannotCreatePixelBuffer(status):
            "Could not create a synthetic pixel buffer (\(status))."
        case .writerBackPressureTimeout:
            "The synthetic MP4 writer did not accept another frame in time."
        case let .cannotAppendFrame(frame, message):
            "Could not append synthetic frame \(frame): \(message)"
        case let .cannotFinishWriting(message):
            "Could not finish the synthetic MP4 writer: \(message)"
        }
    }
}

enum SyntheticMP4Generator {
    static let width = 640
    static let height = 360
    static let framesPerSecond = 30
    static let frameCount = 60

    static func write(to outputURL: URL) async throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw SyntheticMP4GeneratorError.cannotCreateWriter(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 1_500_000,
                    AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: framesPerSecond,
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw SyntheticMP4GeneratorError.cannotAddVideoInput
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
        )

        guard writer.startWriting() else {
            throw SyntheticMP4GeneratorError.cannotStartWriting(
                writer.error?.localizedDescription ?? "AVAssetWriter rejected startWriting."
            )
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            var retries = 0
            while !input.isReadyForMoreMediaData {
                guard retries < 1_000 else {
                    writer.cancelWriting()
                    throw SyntheticMP4GeneratorError.writerBackPressureTimeout
                }
                retries += 1
                try await Task.sleep(for: .milliseconds(1))
            }

            let pixelBuffer = try makePixelBuffer(frame: frame)
            let presentationTime = CMTime(
                value: CMTimeValue(frame),
                timescale: CMTimeScale(framesPerSecond)
            )
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                let message = writer.error?.localizedDescription ?? "The adaptor rejected the frame."
                writer.cancelWriting()
                throw SyntheticMP4GeneratorError.cannotAppendFrame(frame, message)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SyntheticMP4GeneratorError.cannotFinishWriting(
                writer.error?.localizedDescription ?? "AVAssetWriter did not complete."
            )
        }
    }

    private static func makePixelBuffer(frame: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw SyntheticMP4GeneratorError.cannotCreatePixelBuffer(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw SyntheticMP4GeneratorError.cannotCreatePixelBuffer(kCVReturnInvalidPixelBufferAttributes)
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let movingX = 30 + ((frame * 7) % (width - 120))

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * 4)
                let tileIsLight = ((x / 24) + (y / 24)).isMultiple(of: 2)
                var red: UInt8 = tileIsLight ? 225 : 32
                var green: UInt8 = tileIsLight ? 225 : 32
                var blue: UInt8 = tileIsLight ? 225 : 32

                if x >= movingX, x < movingX + 80, y >= 130, y < 210 {
                    red = 237
                    green = 52
                    blue = 72
                }
                if abs(x - (width / 2)) <= 2 || abs(y - (height / 2)) <= 2 {
                    red = 30
                    green = 215
                    blue = 96
                }

                bytes[offset] = blue
                bytes[offset + 1] = green
                bytes[offset + 2] = red
                bytes[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}
