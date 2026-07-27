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

    @Test("Identity frame and custom header stay outside the video surface")
    func framedHeaderLayout() {
        let video = NSView()
        let content = NativeViewerContentView(videoView: video, identityColor: .systemPink)
        content.frame = CGRect(
            x: 0,
            y: 0,
            width: 1_000 + NativeViewerContentView.horizontalChrome,
            height: 500 + NativeViewerContentView.verticalChrome
        )
        content.layoutSubtreeIfNeeded()

        #expect(content.videoViewportFrame == CGRect(x: 6, y: 6, width: 1_000, height: 500))
        #expect(content.headerFrame == CGRect(x: 6, y: 506, width: 1_000, height: 28))
        #expect(video.frame == CGRect(x: 0, y: 0, width: 1_000, height: 500))
        #expect(content.headerFrame.minY == content.videoViewportFrame.maxY)
        #expect(
            content.headerControlFrames.zoom.maxX
                < content.headerControlFrames.fullScreen.minX
        )
        #expect(
            content.headerControlFrames.fullScreen.maxX
                < content.headerControlFrames.close.minX
        )
        #expect(content.headerControlOpacities.allSatisfy { $0 < 1 })
        #expect(content.headerControlTintColors.allSatisfy { $0 == .black })
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
        #expect(controller.window?.styleMask.contains(.fullSizeContentView) == true)
        #expect(controller.window?.titleVisibility == .hidden)
        #expect(controller.window?.titlebarAppearsTransparent == true)
        #expect(controller.window?.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(controller.window?.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(controller.window?.standardWindowButton(.zoomButton)?.isHidden == true)
        #expect(controller.window?.collectionBehavior.contains(.fullScreenPrimary) == true)
        #expect(controller.window?.tabbingMode == .disallowed)
        #expect(controller.content.isFlipped == false)
        #expect(controller.scaleMode == .follow)
        #expect(controller.content.zoomPercentage == 100)
    }

    @Test("Native mode keeps a 100 percent surface and crops it inside a small viewport")
    func nativeModeCropsWithoutScaling() {
        let video = NSView()
        let content = NativeViewerContentView(videoView: video, identityColor: .systemPink)
        let source = NativeViewerSourceSnapshot(
            sourceInstanceID: "source-1",
            streamID: "video0",
            applicationName: "Fixture",
            windowName: "Document",
            pixelSize: CGSize(width: 2_000, height: 1_000),
            sourcePointSize: CGSize(width: 1_000, height: 500),
            isFocused: true,
            isConnected: true,
            stateRevision: 1,
            mode: .manual
        )
        content.frame = CGRect(
            x: 0,
            y: 0,
            width: 600 + NativeViewerContentView.horizontalChrome,
            height: 300 + NativeViewerContentView.verticalChrome
        )
        content.update(
            ownerName: "Friend",
            source: source,
            identityColor: .systemPink,
            resolvedSourceLogicalSize: CGSize(width: 1_000, height: 500)
        )
        content.setScaleMode(.native)
        content.layoutSubtreeIfNeeded()

        #expect(video.frame.size == CGSize(width: 1_000, height: 500))
        #expect(video.frame.origin == CGPoint(x: -200, y: -100))
        #expect(content.zoomPercentage == 100)
    }

    @Test("Native cursor pan lands the rendered surface on Retina backing pixels")
    func nativeCursorPanSnapsToRetinaBackingGrid() {
        let backingScale: CGFloat = 2
        let video = NSView()
        let content = NativeViewerContentView(videoView: video, identityColor: .systemPink)
        content.layer?.contentsScale = backingScale
        let source = NativeViewerSourceSnapshot(
            sourceInstanceID: "source-odd",
            streamID: "video0",
            applicationName: "Fixture",
            windowName: "Odd Width",
            pixelSize: CGSize(width: 2_310, height: 1_222),
            sourcePointSize: CGSize(width: 2_311, height: 1_222),
            isFocused: true,
            isConnected: true,
            stateRevision: 1,
            mode: .manual
        )
        content.frame = CGRect(
            x: 0,
            y: 0,
            width: 1_200 + NativeViewerContentView.horizontalChrome,
            height: 700 + NativeViewerContentView.verticalChrome
        )
        content.update(
            ownerName: "Friend",
            source: source,
            identityColor: .systemPink,
            resolvedSourceLogicalSize: CGSize(width: 2_311, height: 1_222)
        )
        content.setScaleMode(.native)
        content.setCursor(normalizedX: 0.371, normalizedY: 0.619)
        content.layoutSubtreeIfNeeded()

        #expect(video.frame.origin.x * backingScale
            == (video.frame.origin.x * backingScale).rounded())
        #expect(video.frame.origin.y * backingScale
            == (video.frame.origin.y * backingScale).rounded())
        #expect(video.frame.minX <= 0)
        #expect(video.frame.minY <= 0)
        #expect(video.frame.maxX >= content.videoViewportFrame.width)
        #expect(video.frame.maxY >= content.videoViewportFrame.height)
    }

    @Test("Reset sizing clamps the complete viewer window into the visible screen")
    func resetSizingClampsOnscreen() {
        let visible = CGRect(x: 100, y: 50, width: 1_200, height: 800)
        let oversizedAtEdge = CGRect(x: 1_150, y: -100, width: 900, height: 700)

        #expect(NativeViewerWindowController.clampedOrigin(
            frame: oversizedAtEdge,
            visibleFrame: visible
        ) == CGPoint(x: 400, y: 50))
    }

    @Test("Manual resize leaves Follow and enters Native")
    func manualResizeLeavesFollow() {
        let controller = makeController()
        defer { controller.tearDown() }
        var reportedMode: NativeViewerScaleMode?
        controller.onScaleModeChanged = { _, mode in
            reportedMode = mode
        }
        guard let window = controller.window else {
            Issue.record("Expected viewer window")
            return
        }

        let proposed = CGSize(width: 700, height: 450)
        _ = controller.windowWillResize(
            window,
            to: proposed
        )

        #expect(controller.scaleMode == .native)
        #expect(reportedMode == .native)
    }

    @Test("Programmatic mode synchronization does not echo")
    func programmaticModeDoesNotNotify() {
        let controller = makeController()
        defer { controller.tearDown() }
        var callbackCount = 0
        controller.onScaleModeChanged = { _, _ in
            callbackCount += 1
        }

        controller.setScaleMode(.fit)
        controller.setScaleMode(.native)
        controller.setScaleMode(.follow)

        #expect(callbackCount == 0)
    }

    @Test("Native mode prevents a viewport larger than the host logical size")
    func nativeModeCapsViewerSize() {
        let result = NativeViewerWindowController.clampedNativeFrameSize(
            proposedFrameSize: CGSize(width: 1_600, height: 1_000),
            sourceLogicalSize: CGSize(width: 1_000, height: 600),
            systemChromeSize: .zero,
            minimumFrameSize: CGSize(width: 332, height: 220)
        )

        #expect(result == CGSize(
            width: 1_000 + NativeViewerContentView.horizontalChrome,
            height: 600 + NativeViewerContentView.verticalChrome
        ))
    }

    @Test("Fullscreen overlays the header and fits video into the whole content area")
    func fullscreenUsesWholeContentArea() {
        let video = NSView()
        let content = NativeViewerContentView(videoView: video, identityColor: .systemPink)
        let source = Self.makeSource()
        content.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        content.update(
            ownerName: "Friend",
            source: source,
            identityColor: .systemPink,
            resolvedSourceLogicalSize: CGSize(width: 960, height: 540)
        )

        content.setFullScreenPresentation(true)
        content.layoutSubtreeIfNeeded()

        #expect(content.videoViewportFrame == content.bounds)
        #expect(content.headerFrame.maxY <= content.bounds.maxY)
        #expect(content.headerFrame.intersects(content.videoViewportFrame))
        #expect(video.frame == CGRect(x: 0, y: 63, width: 1_200, height: 675))
        #expect(content.isFullScreenHeaderVisible)

        content.hideFullScreenHeaderForInactivity()
        #expect(!content.isFullScreenHeaderVisible)
        content.setFullScreenPresentation(false)
        #expect(content.isFullScreenHeaderVisible)
    }

    @Test("Fullscreen controls reveal only near the top overlay")
    func fullscreenHeaderRevealRegion() {
        let bounds = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let header = CGRect(x: 8, y: 764, width: 1_184, height: 28)

        #expect(NativeViewerContentView.shouldRevealFullScreenHeader(
            pointer: CGPoint(x: 600, y: 790),
            bounds: bounds,
            headerFrame: header
        ))
        #expect(NativeViewerContentView.shouldRevealFullScreenHeader(
            pointer: CGPoint(x: 10, y: 760),
            bounds: bounds,
            headerFrame: header
        ))
        #expect(!NativeViewerContentView.shouldRevealFullScreenHeader(
            pointer: CGPoint(x: 600, y: 400),
            bounds: bounds,
            headerFrame: header
        ))
    }

    @Test("Fullscreen callbacks preserve the persistent sizing mode")
    func fullscreenPreservesScaleMode() {
        let controller = makeController()
        defer { controller.tearDown() }
        controller.setScaleMode(.native)
        var states: [Bool] = []
        controller.onFullScreenChanged = { _, isFullScreen in
            states.append(isFullScreen)
        }
        let notification = Notification(
            name: NSWindow.willEnterFullScreenNotification,
            object: controller.window
        )

        controller.windowWillEnterFullScreen(notification)
        controller.windowDidEnterFullScreen(notification)
        #expect(controller.isFullScreen)
        #expect(controller.content.isFullScreenPresentation)
        #expect(controller.scaleMode == .native)

        controller.windowWillExitFullScreen(notification)
        controller.windowDidExitFullScreen(notification)
        #expect(!controller.isFullScreen)
        #expect(!controller.content.isFullScreenPresentation)
        #expect(controller.scaleMode == .native)
        #expect(states == [true, false])
    }

    @Test("Leaving Follow during fullscreen cancels its deferred host resize")
    func nativeModeCancelsDeferredFollowResize() {
        let controller = makeController()
        defer { controller.tearDown() }
        guard let window = controller.window else {
            Issue.record("Expected viewer window")
            return
        }
        let originalFrame = window.frame
        let notification = Notification(
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        controller.windowWillEnterFullScreen(notification)

        let resizedSource = NativeViewerSourceSnapshot(
            sourceInstanceID: "source-1",
            streamID: "video0",
            applicationName: "Fixture",
            windowName: "Document",
            pixelSize: CGSize(width: 1_600, height: 900),
            sourcePointSize: CGSize(width: 800, height: 450),
            isFocused: true,
            isConnected: true,
            stateRevision: 2,
            mode: .manual
        )
        controller.update(
            ownerName: "Friend",
            source: resizedSource,
            identityColor: .systemPink
        )
        controller.setScaleMode(.native)
        controller.windowDidExitFullScreen(notification)

        #expect(controller.scaleMode == .native)
        #expect(window.frame == originalFrame)
    }

    private func makeController() -> NativeViewerWindowController {
        NativeViewerWindowController(
            id: .manual(sourceInstanceID: "source-1"),
            ownerName: "Friend",
            source: Self.makeSource(),
            identityColor: .systemPink,
            videoView: NSView()
        )
    }

    private static func makeSource() -> NativeViewerSourceSnapshot {
        NativeViewerSourceSnapshot(
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
    }
}
