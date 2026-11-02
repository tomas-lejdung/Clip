import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Converts the captured display profile into the recording's SDR sRGB pixel
/// contract without scaling. One retained frame and the encoder's bounded input
/// queue are the only live buffers; a recording never accumulates raw frames.
final class RecordingPixelNormalizer {
    let width: Int
    let height: Int
    private let pool: CVPixelBufferPool
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])

    init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        var created: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
             kCVPixelBufferWidthKey: width,
             kCVPixelBufferHeightKey: height,
             kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
        guard result == kCVReturnSuccess, let created else {
            throw AssetWriterSessionError.cannotCreateEncoder("The recording pixel pool could not be created (\(result)).")
        }
        pool = created
    }

    func normalize(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        try ScreenVideoSampleDimensionValidator.validate(source, expectedWidth: width, expectedHeight: height)
        guard let sourceSpace = CVImageBufferGetColorSpace(source)?.takeUnretainedValue() else {
            throw AssetWriterSessionError.appendFailed("The captured frame has no color profile. Recording stopped to avoid incorrect colors.")
        }
        var output: CVPixelBuffer?
        // Six pending encoder inputs, the retained last image, and this image.
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary, &output)
        guard result == kCVReturnSuccess, let output else {
            throw AssetWriterSessionError.appendFailed("The recording encoder exceeded its bounded pixel-buffer pool (\(result)).")
        }
        let image = CIImage(cvPixelBuffer: source, options: [.colorSpace: sourceSpace])
        context.render(image, to: output,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return output
    }
}
