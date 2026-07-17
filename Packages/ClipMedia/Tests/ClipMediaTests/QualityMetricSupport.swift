@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// A deterministic, code-rendered screen-content fixture. It deliberately
/// contains details that expose the failure modes hidden by photographic test
/// clips: one-pixel rules, tiny bitmap text, saturated color boundaries,
/// scrolling glyphs, and cadence-relative motion at both 30 and 60 FPS.
enum QualityFixture {
    static let width = 640
    static let height = 360

    static func bgraFrame(index: Int, framesPerSecond: Int) -> [UInt8] {
        precondition(framesPerSecond == 30 || framesPerSecond == 60)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let tileIsLight = ((x / 32) + (y / 32)).isMultiple(of: 2)
                let value: UInt8 = tileIsLight ? 232 : 34
                setPixel(&pixels, x: x, y: y, color: (value, value, value))
            }
        }

        // Rec.709-friendly saturated bars with black and white one-pixel
        // boundaries exercise chroma edges without relying on AppKit colors.
        let colors: [(UInt8, UInt8, UInt8)] = [
            (235, 34, 46),
            (242, 132, 28),
            (245, 220, 42),
            (34, 194, 82),
            (27, 199, 210),
            (38, 92, 226),
            (172, 55, 218),
            (245, 245, 245),
        ]
        let barWidth = 72
        for (offset, color) in colors.enumerated() {
            let x = 24 + (offset * barWidth)
            fill(&pixels, x: x, y: 18, width: barWidth, height: 54, color: color)
            verticalLine(&pixels, x: x, y: 17, height: 56, color: (0, 0, 0))
            verticalLine(&pixels, x: x + 1, y: 18, height: 54, color: (255, 255, 255))
        }

        // Alternating luma at one physical pixel is the hardest fixture area.
        // Keep it bounded so it measures fine-edge survival without dominating
        // the whole-frame SSIM score.
        fill(&pixels, x: 24, y: 92, width: 128, height: 52, color: (127, 127, 127))
        for x in 24..<152 {
            let value: UInt8 = (x - 24).isMultiple(of: 2) ? 248 : 7
            verticalLine(&pixels, x: x, y: 92, height: 52, color: (value, value, value))
        }
        for y in 92..<144 where (y - 92).isMultiple(of: 4) {
            horizontalLine(&pixels, x: 176, y: y, width: 144, color: (255, 255, 255))
            horizontalLine(&pixels, x: 176, y: y + 1, width: 144, color: (0, 0, 0))
        }

        // Fine diagonal and concentric colored edges reveal resize or blur.
        for offset in 0..<9 {
            drawLine(
                &pixels,
                from: (350 + offset * 5, 92),
                to: (438 + offset * 5, 151),
                color: offset.isMultiple(of: 2) ? (255, 255, 255) : (0, 0, 0)
            )
        }
        for inset in stride(from: 0, through: 24, by: 4) {
            strokeRect(
                &pixels,
                x: 500 + inset,
                y: 91 + inset,
                width: 112 - (inset * 2),
                height: 72 - (inset * 2),
                color: inset.isMultiple(of: 8) ? (250, 45, 190) : (40, 235, 220)
            )
        }

        fill(&pixels, x: 18, y: 173, width: 604, height: 42, color: (8, 10, 14))
        drawText(
            "CLIP QUALITY 0123456789 1PX TEXT",
            into: &pixels,
            x: 26,
            y: 184,
            scale: 1,
            color: (246, 246, 246)
        )
        drawText(
            "RGB EDGES",
            into: &pixels,
            x: 382,
            y: 181,
            scale: 2,
            color: (255, 210, 35)
        )

        // Motion is defined in seconds, not frames. A 60 FPS fixture advances
        // half as far per frame and therefore catches accidental 30 FPS caps.
        let travel = width - 116
        let elapsed = Double(index) / Double(framesPerSecond)
        let unreflected = Int((elapsed * 180).rounded(.down)) % (travel * 2)
        let motionX = unreflected <= travel ? unreflected : (travel * 2) - unreflected
        fill(&pixels, x: 24 + motionX, y: 232, width: 76, height: 58, color: (238, 34, 174))
        strokeRect(
            &pixels,
            x: 24 + motionX,
            y: 232,
            width: 76,
            height: 58,
            color: (255, 255, 255)
        )
        drawText(
            "MOVE",
            into: &pixels,
            x: 31 + motionX,
            y: 250,
            scale: 2,
            color: (8, 8, 8)
        )

        let scrollMessage = "SCROLL 30 60 FPS FRAME \(String(format: "%04d", index))"
        let glyphAdvance = 12
        let messageWidth = scrollMessage.count * glyphAdvance
        let scrollCycle = width + messageWidth
        let scrollX = width - (Int((elapsed * 150).rounded(.down)) % scrollCycle)
        fill(&pixels, x: 0, y: 310, width: width, height: 34, color: (3, 8, 24))
        drawText(
            scrollMessage,
            into: &pixels,
            x: scrollX,
            y: 319,
            scale: 2,
            color: (70, 236, 255)
        )

        strokeRect(&pixels, x: 4, y: 4, width: width - 8, height: height - 8, color: (255, 222, 30))
        return pixels
    }

    static func lumaFrame(index: Int, framesPerSecond: Int) -> LumaFrame {
        LumaFrame.fromBGRA(
            bgraFrame(index: index, framesPerSecond: framesPerSecond),
            width: width,
            height: height,
            bytesPerRow: width * 4
        )
    }

    private static func setPixel(
        _ pixels: inout [UInt8],
        x: Int,
        y: Int,
        color: (UInt8, UInt8, UInt8)
    ) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let offset = ((y * width) + x) * 4
        pixels[offset] = color.2
        pixels[offset + 1] = color.1
        pixels[offset + 2] = color.0
        pixels[offset + 3] = 255
    }

    private static func fill(
        _ pixels: inout [UInt8],
        x: Int,
        y: Int,
        width fillWidth: Int,
        height fillHeight: Int,
        color: (UInt8, UInt8, UInt8)
    ) {
        guard fillWidth > 0, fillHeight > 0 else { return }
        for row in y..<(y + fillHeight) {
            for column in x..<(x + fillWidth) {
                setPixel(&pixels, x: column, y: row, color: color)
            }
        }
    }

    private static func verticalLine(
        _ pixels: inout [UInt8],
        x: Int,
        y: Int,
        height lineHeight: Int,
        color: (UInt8, UInt8, UInt8)
    ) {
        fill(&pixels, x: x, y: y, width: 1, height: lineHeight, color: color)
    }

    private static func horizontalLine(
        _ pixels: inout [UInt8],
        x: Int,
        y: Int,
        width lineWidth: Int,
        color: (UInt8, UInt8, UInt8)
    ) {
        fill(&pixels, x: x, y: y, width: lineWidth, height: 1, color: color)
    }

    private static func strokeRect(
        _ pixels: inout [UInt8],
        x: Int,
        y: Int,
        width rectWidth: Int,
        height rectHeight: Int,
        color: (UInt8, UInt8, UInt8)
    ) {
        guard rectWidth > 0, rectHeight > 0 else { return }
        horizontalLine(&pixels, x: x, y: y, width: rectWidth, color: color)
        horizontalLine(
            &pixels,
            x: x,
            y: y + rectHeight - 1,
            width: rectWidth,
            color: color
        )
        verticalLine(&pixels, x: x, y: y, height: rectHeight, color: color)
        verticalLine(
            &pixels,
            x: x + rectWidth - 1,
            y: y,
            height: rectHeight,
            color: color
        )
    }

    private static func drawLine(
        _ pixels: inout [UInt8],
        from start: (Int, Int),
        to end: (Int, Int),
        color: (UInt8, UInt8, UInt8)
    ) {
        var x = start.0
        var y = start.1
        let dx = abs(end.0 - start.0)
        let sx = start.0 < end.0 ? 1 : -1
        let dy = -abs(end.1 - start.1)
        let sy = start.1 < end.1 ? 1 : -1
        var error = dx + dy
        while true {
            setPixel(&pixels, x: x, y: y, color: color)
            if x == end.0, y == end.1 { break }
            let doubled = error * 2
            if doubled >= dy {
                error += dy
                x += sx
            }
            if doubled <= dx {
                error += dx
                y += sy
            }
        }
    }

    private static func drawText(
        _ text: String,
        into pixels: inout [UInt8],
        x: Int,
        y: Int,
        scale: Int,
        color: (UInt8, UInt8, UInt8)
    ) {
        var cursor = x
        for character in text.uppercased() {
            for (row, bits) in glyph(character).enumerated() {
                for column in 0..<5 where bits & (1 << (4 - column)) != 0 {
                    fill(
                        &pixels,
                        x: cursor + (column * scale),
                        y: y + (row * scale),
                        width: scale,
                        height: scale,
                        color: color
                    )
                }
            }
            cursor += 6 * scale
        }
    }

    private static func glyph(_ character: Character) -> [UInt8] {
        switch character {
        case "A": [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001]
        case "C": [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110]
        case "D": [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110]
        case "E": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111]
        case "F": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000]
        case "G": [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110]
        case "I": [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111]
        case "L": [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111]
        case "M": [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001]
        case "O": [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110]
        case "P": [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000]
        case "Q": [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101]
        case "R": [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001]
        case "S": [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110]
        case "T": [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100]
        case "U": [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110]
        case "V": [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100]
        case "X": [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001]
        case "Y": [0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100]
        case "0": [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110]
        case "1": [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110]
        case "2": [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111]
        case "3": [0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110]
        case "4": [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010]
        case "5": [0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110]
        case "6": [0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110]
        case "7": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000]
        case "8": [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110]
        case "9": [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110]
        default: [0, 0, 0, 0, 0, 0, 0]
        }
    }
}

struct LumaFrame: Equatable, Sendable {
    let width: Int
    let height: Int
    let samples: [Double]

    static func fromBGRA(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> LumaFrame {
        precondition(bytes.count >= bytesPerRow * height)
        var luma = [Double]()
        luma.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * 4)
                let blue = Double(bytes[offset])
                let green = Double(bytes[offset + 1])
                let red = Double(bytes[offset + 2])
                luma.append((0.2126 * red) + (0.7152 * green) + (0.0722 * blue))
            }
        }
        return LumaFrame(width: width, height: height, samples: luma)
    }

    func boxBlurred(radius: Int) -> LumaFrame {
        guard radius > 0 else { return self }
        var result = [Double](repeating: 0, count: samples.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0
                var count = 0
                for sampleY in max(0, y - radius)...min(height - 1, y + radius) {
                    for sampleX in max(0, x - radius)...min(width - 1, x + radius) {
                        sum += samples[(sampleY * width) + sampleX]
                        count += 1
                    }
                }
                result[(y * width) + x] = sum / Double(count)
            }
        }
        return LumaFrame(width: width, height: height, samples: result)
    }
}

struct FrameQuality: Equatable, Sendable {
    let lumaSSIM: Double
    let edgeRetention: Double
}

struct AggregateQuality: Equatable, Sendable {
    let comparedFrameCount: Int
    let averageLumaSSIM: Double
    let minimumLumaSSIM: Double
    let averageEdgeRetention: Double
    let minimumEdgeRetention: Double
}

enum ScreenContentQualityMetrics {
    /// Windowed luminance SSIM using the standard 8-bit constants. Eight-pixel
    /// windows keep the score sensitive to small text instead of allowing a
    /// large unchanged background to hide local damage.
    static func compare(_ reference: LumaFrame, _ candidate: LumaFrame) -> FrameQuality {
        guard reference.width == candidate.width,
              reference.height == candidate.height,
              reference.samples.count == candidate.samples.count,
              !reference.samples.isEmpty else {
            return FrameQuality(lumaSSIM: 0, edgeRetention: 0)
        }
        return FrameQuality(
            lumaSSIM: windowedSSIM(reference, candidate),
            edgeRetention: retainedReferenceEdges(reference, candidate)
        )
    }

    static func aggregate(
        references: [LumaFrame],
        candidates: [LumaFrame]
    ) -> AggregateQuality {
        let count = min(references.count, candidates.count)
        guard count > 0 else {
            return AggregateQuality(
                comparedFrameCount: 0,
                averageLumaSSIM: 0,
                minimumLumaSSIM: 0,
                averageEdgeRetention: 0,
                minimumEdgeRetention: 0
            )
        }
        let measurements = (0..<count).map { compare(references[$0], candidates[$0]) }
        return AggregateQuality(
            comparedFrameCount: count,
            averageLumaSSIM: measurements.map(\.lumaSSIM).reduce(0, +) / Double(count),
            minimumLumaSSIM: measurements.map(\.lumaSSIM).min() ?? 0,
            averageEdgeRetention: measurements.map(\.edgeRetention).reduce(0, +) / Double(count),
            minimumEdgeRetention: measurements.map(\.edgeRetention).min() ?? 0
        )
    }

    static func averageAbsoluteLumaError(
        references: [LumaFrame],
        candidates: [LumaFrame]
    ) -> Double {
        let frameCount = min(references.count, candidates.count)
        guard frameCount > 0 else { return .infinity }
        var totalError = 0.0
        var sampleCount = 0
        for frameIndex in 0..<frameCount {
            let reference = references[frameIndex]
            let candidate = candidates[frameIndex]
            guard reference.width == candidate.width,
                  reference.height == candidate.height,
                  reference.samples.count == candidate.samples.count else {
                return .infinity
            }
            for (referenceSample, candidateSample) in zip(
                reference.samples,
                candidate.samples
            ) {
                totalError += abs(referenceSample - candidateSample)
                sampleCount += 1
            }
        }
        return sampleCount > 0 ? totalError / Double(sampleCount) : .infinity
    }

    private static func windowedSSIM(_ reference: LumaFrame, _ candidate: LumaFrame) -> Double {
        let blockSize = 8
        let c1 = pow(0.01 * 255.0, 2.0)
        let c2 = pow(0.03 * 255.0, 2.0)
        var score = 0.0
        var blocks = 0

        for blockY in stride(from: 0, to: reference.height, by: blockSize) {
            for blockX in stride(from: 0, to: reference.width, by: blockSize) {
                let maxY = min(reference.height, blockY + blockSize)
                let maxX = min(reference.width, blockX + blockSize)
                let count = (maxY - blockY) * (maxX - blockX)
                guard count > 1 else { continue }

                var referenceMean = 0.0
                var candidateMean = 0.0
                for y in blockY..<maxY {
                    for x in blockX..<maxX {
                        let index = (y * reference.width) + x
                        referenceMean += reference.samples[index]
                        candidateMean += candidate.samples[index]
                    }
                }
                referenceMean /= Double(count)
                candidateMean /= Double(count)

                var referenceVariance = 0.0
                var candidateVariance = 0.0
                var covariance = 0.0
                for y in blockY..<maxY {
                    for x in blockX..<maxX {
                        let index = (y * reference.width) + x
                        let referenceDelta = reference.samples[index] - referenceMean
                        let candidateDelta = candidate.samples[index] - candidateMean
                        referenceVariance += referenceDelta * referenceDelta
                        candidateVariance += candidateDelta * candidateDelta
                        covariance += referenceDelta * candidateDelta
                    }
                }
                let denominator = Double(count - 1)
                referenceVariance /= denominator
                candidateVariance /= denominator
                covariance /= denominator

                let numerator = (2 * referenceMean * candidateMean + c1)
                    * (2 * covariance + c2)
                let divisor = (referenceMean * referenceMean + candidateMean * candidateMean + c1)
                    * (referenceVariance + candidateVariance + c2)
                score += divisor > 0 ? max(-1, min(1, numerator / divisor)) : 1
                blocks += 1
            }
        }
        return blocks > 0 ? score / Double(blocks) : 0
    }

    /// Counts significant reference luma edges that still have a comparable
    /// gradient within one output pixel. The one-pixel search tolerates normal
    /// H.264 ringing without treating a resize or material blur as retained.
    private static func retainedReferenceEdges(
        _ reference: LumaFrame,
        _ candidate: LumaFrame
    ) -> Double {
        let width = reference.width
        let height = reference.height
        guard width >= 3, height >= 3 else { return 0 }
        var edgeCount = 0
        var retainedCount = 0

        func magnitude(_ frame: LumaFrame, x: Int, y: Int) -> Double {
            let horizontal = frame.samples[(y * width) + x + 1]
                - frame.samples[(y * width) + x - 1]
            let vertical = frame.samples[((y + 1) * width) + x]
                - frame.samples[((y - 1) * width) + x]
            return hypot(horizontal, vertical)
        }

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let referenceMagnitude = magnitude(reference, x: x, y: y)
                guard referenceMagnitude >= 48 else { continue }
                edgeCount += 1
                var candidateMagnitude = 0.0
                for candidateY in max(1, y - 1)...min(height - 2, y + 1) {
                    for candidateX in max(1, x - 1)...min(width - 2, x + 1) {
                        candidateMagnitude = max(
                            candidateMagnitude,
                            magnitude(candidate, x: candidateX, y: candidateY)
                        )
                    }
                }
                if candidateMagnitude >= max(18, referenceMagnitude * 0.42) {
                    retainedCount += 1
                }
            }
        }
        return edgeCount > 0 ? Double(retainedCount) / Double(edgeCount) : 1
    }
}

struct DecodedQualityFrame: Sendable {
    let presentationTime: CMTime
    let duration: CMTime
    let luma: LumaFrame
}

enum QualityMediaDecoder {
    static func decodeVideo(_ url: URL) async throws -> [DecodedQualityFrame] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw QualityTestError.missingVideoTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw QualityTestError.cannotAddReaderOutput }
        reader.add(output)
        guard reader.startReading() else { throw QualityTestError.cannotStartReader }

        var frames: [DecodedQualityFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
                  let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw QualityTestError.unsupportedPixelBuffer
            }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let byteCount = bytesPerRow * height
            let bytes = Array(
                UnsafeBufferPointer(
                    start: baseAddress.assumingMemoryBound(to: UInt8.self),
                    count: byteCount
                )
            )
            frames.append(DecodedQualityFrame(
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sample),
                duration: CMSampleBufferGetDuration(sample),
                luma: .fromBGRA(
                    bytes,
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow
                )
            ))
        }
        guard reader.status == .completed else { throw QualityTestError.readerFailed }
        return frames
    }
}

enum QualityTestError: Error {
    case cannotAddReaderOutput
    case cannotAddWriterInput
    case cannotCreateFormatDescription(OSStatus)
    case cannotCreatePixelBuffer(CVReturn)
    case cannotCreateSampleBuffer(OSStatus)
    case cannotStartReader
    case cannotStartWriter
    case missingVideoTrack
    case readerFailed
    case unsupportedPixelBuffer
    case writerBackPressureTimeout
    case writerAppendFailed
    case writerFinishFailed
}
