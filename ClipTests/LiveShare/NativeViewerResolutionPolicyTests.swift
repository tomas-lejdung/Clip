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

    @Test("Auto preserves source point size across Retina combinations")
    func automaticUsesSourcePointsAcrossDisplayScales() throws {
        for destinationScale in [CGFloat(1), CGFloat(2)] {
            let retina = try #require(NativeViewerResolutionPolicy.resolve(.init(
                decodedPixelSize: CGSize(width: 2_000, height: 1_200),
                sourcePointSize: CGSize(width: 1_000, height: 600),
                destinationBackingScale: destinationScale,
                maximumContentSize: CGSize(width: 1_500, height: 900),
                mode: .automatic
            )))
            let external = try #require(NativeViewerResolutionPolicy.resolve(.init(
                decodedPixelSize: CGSize(width: 1_000, height: 600),
                sourcePointSize: CGSize(width: 1_000, height: 600),
                destinationBackingScale: destinationScale,
                maximumContentSize: CGSize(width: 1_500, height: 900),
                mode: .automatic
            )))

            #expect(retina.contentSize == CGSize(width: 1_000, height: 600))
            #expect(external.contentSize == CGSize(width: 1_000, height: 600))
        }
    }

    @Test("Auto preserves source points when the encoder downsizes")
    func automaticSeparatesPresentationFromEncodedGeometry() throws {
        let result = try #require(NativeViewerResolutionPolicy.resolve(.init(
            decodedPixelSize: CGSize(width: 2_560, height: 1_440),
            sourcePointSize: CGSize(width: 3_000, height: 1_687.5),
            destinationBackingScale: 2,
            maximumContentSize: CGSize(width: 1_600, height: 900),
            mode: .automatic
        )))

        #expect(result.contentSize == CGSize(width: 1_600, height: 900))
        #expect(result.isFitted)
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

    @Test("Actual preserves native content but caps its viewport across viewer display scales")
    func actualPixelsCapsViewportWithoutScalingContent() throws {
        for destinationScale in [CGFloat(1), CGFloat(2)] {
            let retinaHost = try #require(NativeViewerResolutionPolicy.resolve(.init(
                decodedPixelSize: CGSize(width: 2_000, height: 1_000),
                sourcePointSize: CGSize(width: 1_000, height: 500),
                destinationBackingScale: destinationScale,
                maximumContentSize: CGSize(width: 800, height: 400),
                mode: .actualPixels
            )))
            let externalHost = try #require(NativeViewerResolutionPolicy.resolve(.init(
                decodedPixelSize: CGSize(width: 2_000, height: 1_000),
                sourcePointSize: CGSize(width: 2_000, height: 1_000),
                destinationBackingScale: destinationScale,
                maximumContentSize: CGSize(width: 800, height: 400),
                mode: .actualPixels
            )))

            #expect(retinaHost.contentSize == CGSize(width: 800, height: 400))
            #expect(externalHost.contentSize == CGSize(width: 800, height: 400))
            #expect(!retinaHost.isFitted)
            #expect(!externalHost.isFitted)
        }
    }

    @Test("Actual keeps the legacy decoded-pixel fallback for old hosts")
    func actualLegacyHostFallbackUsesViewerBackingScale() throws {
        let result = try #require(NativeViewerResolutionPolicy.resolve(.init(
            decodedPixelSize: CGSize(width: 1_600, height: 1_200),
            destinationBackingScale: 2,
            maximumContentSize: CGSize(width: 2_000, height: 1_500),
            mode: .actualPixels
        )))

        #expect(result.contentSize == CGSize(width: 800, height: 600))
        #expect(!result.isFitted)
    }

    @Test("Legacy hosts retain decoded-pixel sizing")
    func legacyHostFallback() throws {
        let result = try #require(NativeViewerResolutionPolicy.resolve(.init(
            decodedPixelSize: CGSize(width: 1_600, height: 1_200),
            destinationBackingScale: 1,
            maximumContentSize: CGSize(width: 2_000, height: 1_500),
            mode: .automatic
        )))

        #expect(result.contentSize == CGSize(width: 1_600, height: 1_200))
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

@Suite("Native viewer pan policy")
struct NativeViewerPanPolicyTests {
    @Test("Cursor is centered in oversized native content")
    func centersCursorInOversizedContent() throws {
        let geometry = try #require(NativeViewerPanPolicy.geometry(
            sourceLogicalSize: CGSize(width: 2_000, height: 1_000),
            viewportSize: CGSize(width: 800, height: 400),
            normalizedCursor: CGPoint(x: 0.5, y: 0.5)
        ))

        #expect(geometry.contentFrame == CGRect(x: -600, y: -300, width: 2_000, height: 1_000))
        #expect(geometry.overflowSize == CGSize(width: 1_200, height: 600))
        #expect(geometry.canPanHorizontally)
        #expect(geometry.canPanVertically)
        #expect(geometry.isCropped)
    }

    @Test("Cursor following clamps at every source edge")
    func clampsCursorAtEdges() throws {
        let sourceSize = CGSize(width: 2_000, height: 1_000)
        let viewportSize = CGSize(width: 800, height: 400)
        let topLeft = try #require(NativeViewerPanPolicy.geometry(
            sourceLogicalSize: sourceSize,
            viewportSize: viewportSize,
            normalizedCursor: CGPoint(x: 0, y: 0)
        ))
        let bottomRight = try #require(NativeViewerPanPolicy.geometry(
            sourceLogicalSize: sourceSize,
            viewportSize: viewportSize,
            normalizedCursor: CGPoint(x: 1, y: 1)
        ))

        #expect(topLeft.contentFrame.origin == CGPoint(x: 0, y: -600))
        #expect(topLeft.contentFrame.maxX >= viewportSize.width)
        #expect(topLeft.contentFrame.maxY >= viewportSize.height)
        #expect(bottomRight.contentFrame.origin == CGPoint(x: -1_200, y: 0))
        #expect(bottomRight.contentFrame.minX <= 0)
        #expect(bottomRight.contentFrame.minY <= 0)
    }

    @Test("An axis that fits stays centered while the other follows the cursor")
    func fittedAxisDoesNotPan() throws {
        let sourceSize = CGSize(width: 1_200, height: 300)
        let viewportSize = CGSize(width: 800, height: 500)
        let geometry = try #require(NativeViewerPanPolicy.geometry(
            sourceLogicalSize: sourceSize,
            viewportSize: viewportSize,
            normalizedCursor: CGPoint(x: 1, y: 1)
        ))

        #expect(geometry.contentFrame.origin == CGPoint(x: -400, y: 100))
        #expect(geometry.canPanHorizontally)
        #expect(!geometry.canPanVertically)
    }

    @Test("Content that fits does not move with the cursor")
    func fittedContentDoesNotPan() throws {
        let sourceSize = CGSize(width: 640, height: 360)
        let viewportSize = CGSize(width: 800, height: 600)
        let first = try #require(NativeViewerPanPolicy.geometry(
            sourceLogicalSize: sourceSize,
            viewportSize: viewportSize,
            normalizedCursor: CGPoint(x: 0, y: 0)
        ))
        let second = try #require(NativeViewerPanPolicy.geometry(
            sourceLogicalSize: sourceSize,
            viewportSize: viewportSize,
            normalizedCursor: CGPoint(x: 1, y: 1)
        ))

        #expect(first.contentFrame.origin == CGPoint(x: 80, y: 120))
        #expect(second.contentFrame.origin == first.contentFrame.origin)
        #expect(!first.isCropped)
    }

    @Test("Manual pan is clamped without revealing empty space")
    func clampsManualPan() {
        let origin = NativeViewerPanPolicy.clampedContentOrigin(
            CGPoint(x: 100, y: -1_000),
            sourceLogicalSize: CGSize(width: 1_200, height: 900),
            viewportSize: CGSize(width: 800, height: 600)
        )

        #expect(origin == CGPoint(x: 0, y: -300))
    }

    @Test("Out-of-range cursor values clamp and absent cursor recenters")
    func normalizesCursorInput() throws {
        let clamped = try #require(NativeViewerPanPolicy.geometry(
            sourceLogicalSize: CGSize(width: 1_200, height: 900),
            viewportSize: CGSize(width: 800, height: 600),
            normalizedCursor: CGPoint(x: -2, y: 4)
        ))
        let absent = try #require(NativeViewerPanPolicy.geometry(
            sourceLogicalSize: CGSize(width: 1_200, height: 900),
            viewportSize: CGSize(width: 800, height: 600),
            normalizedCursor: nil
        ))

        #expect(clamped.contentFrame.origin == CGPoint(x: 0, y: 0))
        #expect(absent.contentFrame.origin == CGPoint(x: -200, y: -150))
    }

    @Test("Zoom is relative to source logical size")
    func reportsDisplayIndependentZoom() {
        #expect(NativeViewerPanPolicy.zoomPercentage(
            sourceLogicalSize: CGSize(width: 1_000, height: 600),
            renderedContentSize: CGSize(width: 1_000, height: 600)
        ) == 100)
        #expect(NativeViewerPanPolicy.zoomPercentage(
            sourceLogicalSize: CGSize(width: 1_000, height: 600),
            renderedContentSize: CGSize(width: 720, height: 432)
        ) == 72)
    }

    @Test("Invalid geometry is rejected")
    func rejectsInvalidGeometry() {
        #expect(NativeViewerPanPolicy.geometry(
            sourceLogicalSize: .zero,
            viewportSize: CGSize(width: 800, height: 600),
            normalizedCursor: nil
        ) == nil)
        #expect(NativeViewerPanPolicy.zoomPercentage(
            sourceLogicalSize: CGSize(width: 1_000, height: 600),
            renderedContentSize: .zero
        ) == nil)
    }
}
