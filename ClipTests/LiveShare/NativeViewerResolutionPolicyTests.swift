import CoreGraphics
import Testing
@testable import Clip

@Suite("Native viewer resolution policy")
struct NativeViewerResolutionPolicyTests {
    @Test("Auto maps one decoded pixel to one Retina backing pixel")
    func automaticUsesActualPixelsWhenTheyFit() throws {
        let result = try #require(NativeViewerResolutionPolicy.resolve(.init(
            decodedPixelSize: CGSize(width: 2_560, height: 1_440),
            destinationBackingScale: 2,
            maximumContentSize: CGSize(width: 1_500, height: 900),
            mode: .automatic
        )))

        #expect(result.contentSize == CGSize(width: 1_280, height: 720))
        #expect(result.destinationPixelsPerSourcePixel == 1)
        #expect(!result.isFitted)
    }

    @Test("Auto fits an oversized stream without upscaling")
    func automaticFitsOversizedStream() throws {
        let result = try #require(NativeViewerResolutionPolicy.resolve(.init(
            decodedPixelSize: CGSize(width: 3_840, height: 2_160),
            destinationBackingScale: 1,
            maximumContentSize: CGSize(width: 1_600, height: 900),
            mode: .automatic
        )))

        #expect(result.contentSize == CGSize(width: 1_600, height: 900))
        // Runtime CGFloat division and the compiler-folded literal can differ
        // by one ULP even though they describe the same fitted scale.
        #expect(abs(result.destinationPixelsPerSourcePixel - (1_600.0 / 3_840.0)) < 1e-12)
        #expect(result.isFitted)
    }

    @Test("Actual Pixels remains exact even when larger than the display")
    func actualPixelsDoesNotFit() throws {
        let result = try #require(NativeViewerResolutionPolicy.resolve(.init(
            decodedPixelSize: CGSize(width: 3_840, height: 2_160),
            destinationBackingScale: 2,
            maximumContentSize: CGSize(width: 1_200, height: 700),
            mode: .actualPixels
        )))

        #expect(result.contentSize == CGSize(width: 1_920, height: 1_080))
        #expect(!result.isFitted)
    }

    @Test("Fit never enlarges a small source")
    func fitNeverUpscales() throws {
        let result = try #require(NativeViewerResolutionPolicy.resolve(.init(
            decodedPixelSize: CGSize(width: 640, height: 360),
            destinationBackingScale: 2,
            maximumContentSize: CGSize(width: 1_600, height: 900),
            mode: .fit
        )))

        #expect(result.contentSize == CGSize(width: 320, height: 180))
        #expect(result.destinationPixelsPerSourcePixel == 1)
        #expect(!result.isFitted)
    }

    @Test("Invalid geometry is rejected")
    func rejectsInvalidGeometry() {
        #expect(NativeViewerResolutionPolicy.resolve(.init(
            decodedPixelSize: .zero,
            destinationBackingScale: 2,
            maximumContentSize: CGSize(width: 1_600, height: 900),
            mode: .automatic
        )) == nil)
    }

    @Test("An authoritative revision resizes on its first matching frame")
    func authoritativeGeometryCommitsImmediately() {
        var policy = NativeViewerDimensionStabilizer(requiredConsecutiveFrames: 4)
        #expect(policy.observe(
            decodedPixelSize: CGSize(width: 1_280, height: 720),
            authoritativePixelSize: nil,
            stateRevision: 1
        ) == CGSize(width: 1_280, height: 720))

        #expect(policy.observe(
            decodedPixelSize: CGSize(width: 1_920, height: 1_080),
            authoritativePixelSize: CGSize(width: 1_920, height: 1_080),
            stateRevision: 2
        ) == CGSize(width: 1_920, height: 1_080))
    }

    @Test("A transient adaptive frame does not resize the window")
    func transientDimensionsAreIgnored() {
        var policy = NativeViewerDimensionStabilizer(requiredConsecutiveFrames: 3)
        _ = policy.observe(
            decodedPixelSize: CGSize(width: 1_920, height: 1_080),
            authoritativePixelSize: nil,
            stateRevision: 1
        )

        #expect(policy.observe(
            decodedPixelSize: CGSize(width: 960, height: 540),
            authoritativePixelSize: nil,
            stateRevision: 1
        ) == nil)
        #expect(policy.observe(
            decodedPixelSize: CGSize(width: 1_920, height: 1_080),
            authoritativePixelSize: nil,
            stateRevision: 1
        ) == nil)
        #expect(policy.committedPixelSize == CGSize(width: 1_920, height: 1_080))
    }

    @Test("A persistent decoded size eventually becomes authoritative")
    func persistentDimensionsCommit() {
        var policy = NativeViewerDimensionStabilizer(requiredConsecutiveFrames: 3)
        _ = policy.observe(
            decodedPixelSize: CGSize(width: 1_920, height: 1_080),
            authoritativePixelSize: nil,
            stateRevision: 1
        )

        for _ in 0..<2 {
            #expect(policy.observe(
                decodedPixelSize: CGSize(width: 1_280, height: 720),
                authoritativePixelSize: nil,
                stateRevision: 1
            ) == nil)
        }
        #expect(policy.observe(
            decodedPixelSize: CGSize(width: 1_280, height: 720),
            authoritativePixelSize: nil,
            stateRevision: 1
        ) == CGSize(width: 1_280, height: 720))
    }
}
