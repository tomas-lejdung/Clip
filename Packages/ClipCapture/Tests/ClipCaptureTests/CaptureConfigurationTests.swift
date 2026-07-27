@preconcurrency import ScreenCaptureKit
import CoreGraphics
import CoreVideo
import Testing
@testable import ClipCapture

@Suite("Screen capture video configuration")
struct CaptureConfigurationTests {
    @Test("BGRA remains the default capture format")
    func defaultBGRAFormat() {
        let video = CaptureVideoConfiguration(width: 1_920, height: 1_080)
        let configuration = ScreenCaptureSession.makeConfiguration(for: video)

        #expect(video.pixelFormat == .bgra)
        #expect(configuration.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(!configuration.shouldBeOpaque)
        #expect(video.scalesToFit)
        #expect(configuration.scalesToFit)
        #expect(video.captureResolution == .best)
        #expect(configuration.captureResolution == .best)
    }

    @Test("Nominal capture requests one pixel per source point")
    func nominalCaptureResolution() {
        let video = CaptureVideoConfiguration(
            width: 1_920,
            height: 1_080,
            captureResolution: .nominal
        )
        let configuration = ScreenCaptureSession.makeConfiguration(for: video)

        #expect(video.captureResolution == .nominal)
        #expect(configuration.captureResolution == .nominal)
    }

    @Test("Native resolution follows the source point-to-pixel scale")
    func nativeCaptureResolutionPolicy() {
        #expect(CaptureVideoResolutionPolicy.nativeScale(
            sourcePixelWidth: 1_159,
            sourcePixelHeight: 668,
            sourcePointWidth: 1_159,
            sourcePointHeight: 668
        ) == .nominal)
        #expect(CaptureVideoResolutionPolicy.nativeScale(
            sourcePixelWidth: 2_318,
            sourcePixelHeight: 1_336,
            sourcePointWidth: 1_159,
            sourcePointHeight: 668
        ) == .best)
        // One-pixel rounding at a Retina edge must not misclassify the source.
        #expect(CaptureVideoResolutionPolicy.nativeScale(
            sourcePixelWidth: 2_317,
            sourcePixelHeight: 1_335,
            sourcePointWidth: 1_159,
            sourcePointHeight: 668
        ) == .best)
    }

    @Test("Capture scaling can be disabled without changing the default")
    func scalingPolicy() {
        let video = CaptureVideoConfiguration(
            width: 1_920,
            height: 1_080,
            scalesToFit: false
        )
        let configuration = ScreenCaptureSession.makeConfiguration(for: video)

        #expect(!video.scalesToFit)
        #expect(!configuration.scalesToFit)
        #expect(configuration.preservesAspectRatio)
    }

    @Test("Rec.709 requests opaque SDR video-range NV12")
    func rec709VideoRangeFormat() {
        let video = CaptureVideoConfiguration(
            width: 1_920,
            height: 1_080,
            pixelFormat: .rec709VideoRange
        )
        let configuration = ScreenCaptureSession.makeConfiguration(for: video)

        #expect(configuration.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(configuration.captureDynamicRange == .SDR)
        #expect(configuration.colorSpaceName == CGColorSpace.itur_709)
        #expect(configuration.colorMatrix == CGDisplayStream.yCbCrMatrix_ITU_R_709_2)
        #expect(configuration.shouldBeOpaque)
    }

    @Test("Full-range Rec.709 requests opaque SDR full-range NV12")
    func rec709FullRangeFormat() {
        let video = CaptureVideoConfiguration(
            width: 1_920,
            height: 1_080,
            pixelFormat: .rec709FullRange
        )
        let configuration = ScreenCaptureSession.makeConfiguration(for: video)

        #expect(configuration.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(configuration.captureDynamicRange == .SDR)
        #expect(configuration.colorSpaceName == CGColorSpace.itur_709)
        #expect(configuration.colorMatrix == CGDisplayStream.yCbCrMatrix_ITU_R_709_2)
        #expect(configuration.shouldBeOpaque)
    }

    @Test("Rec.709 BGRA keeps hardware input while normalizing SDR color")
    func rec709BGRAFormat() {
        let video = CaptureVideoConfiguration(
            width: 1_920,
            height: 1_080,
            pixelFormat: .rec709BGRA
        )
        let configuration = ScreenCaptureSession.makeConfiguration(for: video)

        #expect(configuration.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(configuration.captureDynamicRange == .SDR)
        #expect(configuration.colorSpaceName == CGColorSpace.itur_709)
        #expect(configuration.shouldBeOpaque)
    }
}
