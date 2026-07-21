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

    @Test("Logical presentation uses the full point-sized window")
    func logicalPresentationFillsAvailableFrame() {
        let available = CGRect(x: 5, y: 5, width: 800, height: 600)
        let sourcePixels = CGSize(width: 1_600, height: 1_200)

        #expect(NativeViewerContentView.aspectFitContentRect(
            sourcePixelSize: sourcePixels,
            videoFrame: available
        ) == available)
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

    @Test("Viewer windows start windowed and never auto-tab")
    func safeInitialWindowState() {
        let source = NativeViewerSourceSnapshot(
            sourceInstanceID: "source-1",
            streamID: "video0",
            applicationName: "Fixture",
            windowName: "Document",
            pixelSize: CGSize(width: 1_920, height: 1_080),
            sourcePointSize: CGSize(width: 960, height: 540),
            isFocused: true,
            isConnected: true,
            stateRevision: 1,
            mode: .manual
        )
        let controller = NativeViewerWindowController(
            id: .manual(sourceInstanceID: source.sourceInstanceID),
            ownerName: "Friend",
            source: source,
            identityColor: .systemPink,
            videoView: NSView()
        )
        defer { controller.tearDown() }

        #expect(controller.window?.styleMask.contains(.fullScreen) == false)
        #expect(controller.window?.collectionBehavior.contains(.fullScreenPrimary) == true)
        #expect(controller.window?.tabbingMode == .disallowed)
        #expect(controller.content.isFlipped == false)
    }
}
