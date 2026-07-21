import AppKit
import Testing
@testable import Clip

@Suite("Native viewer window presentation")
@MainActor
struct NativeViewerWindowControllerTests {
    @Test("Remote top-left cursor coordinates map into AppKit video coordinates")
    func cursorCoordinates() {
        let videoFrame = CGRect(x: 5, y: 5, width: 1_000, height: 500)

        #expect(NativeViewerContentView.cursorPoint(
            normalizedX: 0,
            normalizedY: 0,
            videoFrame: videoFrame
        ) == CGPoint(x: 5, y: 505))
        #expect(NativeViewerContentView.cursorPoint(
            normalizedX: 1,
            normalizedY: 1,
            videoFrame: videoFrame
        ) == CGPoint(x: 1_005, y: 5))
        #expect(NativeViewerContentView.cursorPoint(
            normalizedX: 0.5,
            normalizedY: 0.5,
            videoFrame: videoFrame
        ) == CGPoint(x: 505, y: 255))
    }

    @Test("Cursor follows the rendered image instead of horizontal letterboxing")
    func cursorCoordinatesWithPillarboxing() {
        let videoFrame = CGRect(x: 5, y: 5, width: 1_000, height: 500)
        let sourceSize = CGSize(width: 1_000, height: 1_000)

        #expect(NativeViewerContentView.aspectFitContentRect(
            sourcePixelSize: sourceSize,
            videoFrame: videoFrame
        ) == CGRect(x: 255, y: 5, width: 500, height: 500))
        #expect(NativeViewerContentView.cursorPoint(
            normalizedX: 0,
            normalizedY: 0,
            videoFrame: videoFrame,
            sourcePixelSize: sourceSize
        ) == CGPoint(x: 255, y: 505))
        #expect(NativeViewerContentView.cursorPoint(
            normalizedX: 1,
            normalizedY: 1,
            videoFrame: videoFrame,
            sourcePixelSize: sourceSize
        ) == CGPoint(x: 755, y: 5))
    }

    @Test("Cursor follows the rendered image instead of vertical letterboxing")
    func cursorCoordinatesWithLetterboxing() {
        let videoFrame = CGRect(x: 5, y: 5, width: 500, height: 1_000)
        let sourceSize = CGSize(width: 2_000, height: 1_000)

        #expect(NativeViewerContentView.aspectFitContentRect(
            sourcePixelSize: sourceSize,
            videoFrame: videoFrame
        ) == CGRect(x: 5, y: 380, width: 500, height: 250))
        #expect(NativeViewerContentView.cursorPoint(
            normalizedX: 0.5,
            normalizedY: 0,
            videoFrame: videoFrame,
            sourcePixelSize: sourceSize
        ) == CGPoint(x: 255, y: 630))
        #expect(NativeViewerContentView.cursorPoint(
            normalizedX: 0.5,
            normalizedY: 1,
            videoFrame: videoFrame,
            sourcePixelSize: sourceSize
        ) == CGPoint(x: 255, y: 380))
    }

    @Test("A small Retina source is centered without being upscaled")
    func smallSourceRetinaPixelCap() {
        let available = CGRect(x: 5, y: 5, width: 320, height: 210)
        let source = CGSize(width: 160, height: 90)
        let rendered = NativeViewerContentView.pixelCappedContentRect(
            sourcePixelSize: source,
            availableFrame: available,
            destinationBackingScale: 2
        )

        #expect(rendered == CGRect(x: 125, y: 87.5, width: 80, height: 45))
        #expect(rendered.width * 2 / source.width == 1)
        #expect(NativeViewerContentView.cursorPoint(
            normalizedX: 1,
            normalizedY: 1,
            videoFrame: rendered,
            sourcePixelSize: source
        ) == CGPoint(x: 205, y: 87.5))
    }

    @Test("Identity border remains outside the video surface")
    func borderLayout() {
        let video = NSView()
        let content = NativeViewerContentView(videoView: video, identityColor: .systemPink)
        content.frame = CGRect(x: 0, y: 0, width: 1_010, height: 510)
        content.layoutSubtreeIfNeeded()

        #expect(video.frame == CGRect(x: 5, y: 5, width: 1_000, height: 500))
        #expect(content.layer?.borderWidth == 5)
    }
}
