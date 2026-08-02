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
        #expect(content.headerControlTintColors.allSatisfy { $0 == .white })
        #expect(content.collaborationControlFrames.count == 3)
        #expect(content.collaborationControlFrames.values.allSatisfy {
            $0.width == 24 && $0.height == 22
        })
    }

    @Test("Window collaboration controls expose effective state and overrides")
    func collaborationControlStateAndActions() {
        let content = NativeViewerContentView(
            videoView: NSView(),
            identityColor: .systemPink
        )
        content.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        var changes: [(NativeViewerCollaborationControlTool, Bool)] = []
        var resetCount = 0
        content.onCollaborationControlChanged = { tool, enabled in
            changes.append((tool, enabled))
        }
        content.onCollaborationControlResetToGlobal = {
            resetCount += 1
        }

        content.setCollaborationControlState(.init(
            pointerEnabled: true,
            pingEnabled: false,
            drawingEnabled: true,
            isUsingGlobalSettings: false
        ))
        content.layoutSubtreeIfNeeded()

        #expect(!content.isResetCollaborationControlVisible)
        #expect(content.collaborationControlGroupBorderWidth == 0)
        #expect(content.collaborationControlFrames.count == 3)
        for tool in NativeViewerCollaborationControlTool.allCases {
            #expect(content.collaborationControlToolTips[tool] == tool.title)
            #expect(
                content.collaborationControlAccessibilityLabels[tool]
                    == tool.title
            )
        }
        content.activateCollaborationControl(.pointer)
        content.activateCollaborationControl(.ping)
        content.activateResetCollaborationToGlobal()
        #expect(changes.map(\.0) == [.pointer, .ping])
        #expect(changes.map(\.1) == [false, true])
        #expect(resetCount == 1)

        content.setCollaborationControlState(.globalDefaults)
        #expect(!content.isResetCollaborationControlVisible)
        #expect(content.collaborationControlGroupBorderWidth == 0)
    }

    @Test("Sizing control keeps balanced padding in every mode and fullscreen")
    func sizingControlHorizontalPadding() {
        let content = NativeViewerContentView(
            videoView: NSView(),
            identityColor: .systemPink
        )
        content.frame = CGRect(x: 0, y: 0, width: 800, height: 500)

        for mode in [
            NativeViewerScaleMode.follow,
            .native,
            .fit,
        ] {
            content.setScaleMode(mode)
            content.layoutSubtreeIfNeeded()
            #expect(content.zoomControlHorizontalPadding >= 8)
            #expect(content.zoomControlHorizontalPadding < 9)
            #expect(content.zoomControlHugsTitle)
        }

        content.setFullScreenPresentation(true)
        for mode in [
            NativeViewerScaleMode.follow,
            .native,
            .fit,
        ] {
            content.setScaleMode(mode)
            content.layoutSubtreeIfNeeded()
            #expect(content.zoomControlHorizontalPadding >= 8)
            #expect(content.zoomControlHorizontalPadding < 9)
            #expect(content.zoomControlHugsTitle)
        }
        content.setFullScreenPresentation(false)
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
            stateRevision: 1
        )
        let controller = NativeViewerWindowController(
            id: .source(instanceID: source.sourceInstanceID),
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
            stateRevision: 1
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
            stateRevision: 1
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

    @Test("A small native host lowers the normal window minimum")
    func nativeModeCapsMinimumToSmallHost() {
        let systemChromeSize = CGSize(width: 8, height: 22)
        let sourceLogicalSize = CGSize(width: 120, height: 80)
        let expectedMaximum = CGSize(
            width: sourceLogicalSize.width
                + NativeViewerContentView.horizontalChrome
                + systemChromeSize.width,
            height: sourceLogicalSize.height
                + NativeViewerContentView.verticalChrome
                + systemChromeSize.height
        )

        let enlarged = NativeViewerWindowController.clampedNativeFrameSize(
            proposedFrameSize: CGSize(width: 1_000, height: 800),
            sourceLogicalSize: sourceLogicalSize,
            systemChromeSize: systemChromeSize,
            minimumFrameSize: CGSize(width: 332, height: 220)
        )
        let reduced = NativeViewerWindowController.clampedNativeFrameSize(
            proposedFrameSize: CGSize(width: 1, height: 1),
            sourceLogicalSize: sourceLogicalSize,
            systemChromeSize: systemChromeSize,
            minimumFrameSize: CGSize(width: 332, height: 220)
        )

        #expect(enlarged == expectedMaximum)
        #expect(reduced == expectedMaximum)
    }

    @Test("The AppKit minimum follows Native but is restored for Fit")
    func nativeModeUpdatesWindowMinimum() {
        let source = Self.makeSource(
            sourcePointSize: CGSize(width: 120, height: 80)
        )
        let controller = makeController(source: source)
        defer { controller.tearDown() }
        guard let window = controller.window else {
            Issue.record("Expected viewer window")
            return
        }
        let defaultMinimum = window.minSize

        controller.setScaleMode(.native)

        let frameSize = window.frame.size
        let contentSize = window.contentRect(
            forFrameRect: CGRect(origin: .zero, size: frameSize)
        ).size
        let maximum = CGSize(
            width: source.sourcePointSize.width
                + NativeViewerContentView.horizontalChrome
                + max(0, frameSize.width - contentSize.width),
            height: source.sourcePointSize.height
                + NativeViewerContentView.verticalChrome
                + max(0, frameSize.height - contentSize.height)
        )
        #expect(window.minSize.width <= maximum.width)
        #expect(window.minSize.height <= maximum.height)
        #expect(window.minSize.width < defaultMinimum.width)
        #expect(window.minSize.height < defaultMinimum.height)
        #expect(controller.windowWillResize(
            window,
            to: CGSize(width: 1_000, height: 800)
        ) == maximum)

        controller.setScaleMode(.fit)
        #expect(window.minSize == defaultMinimum)
    }

    @Test("Source growth resizes Follow but preserves Native and Fit frames")
    func hostGrowthRespectsSizingModeOwnership() {
        let initial = Self.makeSource(
            sourcePointSize: CGSize(width: 480, height: 270)
        )
        let grown = Self.makeSource(
            sourcePointSize: CGSize(width: 640, height: 360),
            stateRevision: 2
        )

        let follow = makeController(source: initial)
        defer { follow.tearDown() }
        let followFrame = follow.window?.frame
        follow.update(
            ownerName: "Friend",
            source: grown,
            identityColor: .systemPink
        )
        #expect(follow.window?.frame != followFrame)

        for mode in [NativeViewerScaleMode.native, .fit] {
            let controller = makeController(source: initial)
            controller.setScaleMode(mode)
            let viewerOwnedFrame = controller.window?.frame
            controller.update(
                ownerName: "Friend",
                source: grown,
                identityColor: .systemPink
            )
            #expect(controller.window?.frame == viewerOwnedFrame)
            controller.tearDown()
        }
    }

    @Test("Native applies a host shrink after leaving fullscreen")
    func nativeHostShrinkWhileFullscreenClampsRestoredWindow() {
        let initial = Self.makeSource(
            sourcePointSize: CGSize(width: 640, height: 360)
        )
        let shrunk = Self.makeSource(
            sourcePointSize: CGSize(width: 240, height: 135),
            stateRevision: 2
        )
        let controller = makeController(source: initial)
        defer { controller.tearDown() }
        guard let window = controller.window else {
            Issue.record("Expected viewer window")
            return
        }
        controller.setScaleMode(.native)
        let initialFrame = window.frame

        controller.windowWillEnterFullScreen(
            Notification(name: NSWindow.willEnterFullScreenNotification, object: window)
        )
        controller.update(
            ownerName: "Friend",
            source: shrunk,
            identityColor: .systemPink
        )
        #expect(window.frame == initialFrame)

        controller.windowDidExitFullScreen(
            Notification(name: NSWindow.didExitFullScreenNotification, object: window)
        )
        #expect(window.frame.width < initialFrame.width)
        #expect(window.frame.height < initialFrame.height)
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
        // AppKit aligns the centered frame to the current backing scale. A 1×
        // test environment rounds 62.5 points to 63, while a 2× environment
        // represents the mathematically exact half point.
        #expect(video.frame.width == 1_200)
        #expect(video.frame.height == 675)
        #expect(video.frame.minX == 0)
        #expect(abs(video.frame.midY - content.bounds.midY) <= 0.5)
        #expect(content.isFullScreenHeaderVisible)
        #expect(content.areFullScreenControlsInteractive)
        #expect(content.areFullScreenControlsEnabled)
        #expect(!content.isCloseControlVisible)
        #expect(content.headerControlFrames.close == .zero)
        #expect(
            content.headerControlFrames.zoom.minY
                == content.headerControlFrames.fullScreen.minY
        )
        #expect(content.collaborationControlFrames.values.allSatisfy {
            $0.minY == content.headerControlFrames.fullScreen.minY
        })

        content.hideFullScreenHeaderForInactivity()
        #expect(!content.isFullScreenHeaderVisible)
        #expect(!content.areFullScreenControlsInteractive)
        #expect(!content.areFullScreenControlsEnabled)
        content.setFullScreenPresentation(false)
        #expect(content.isFullScreenHeaderVisible)
        #expect(content.areFullScreenControlsInteractive)
        #expect(content.areFullScreenControlsEnabled)
        #expect(content.isCloseControlVisible)
        #expect(content.headerControlFrames.close.width > 0)
    }

    @Test("Fullscreen Native remains 100 percent and follows the cursor")
    func fullscreenNativeCropsAndFollowsCursor() {
        let video = NSView()
        let content = NativeViewerContentView(videoView: video, identityColor: .systemPink)
        let source = Self.makeSource(
            sourcePointSize: CGSize(width: 2_400, height: 1_600)
        )
        content.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        content.update(
            ownerName: "Friend",
            source: source,
            identityColor: .systemPink,
            resolvedSourceLogicalSize: source.sourcePointSize
        )
        content.setScaleMode(.native)
        // Seed the pan anchor before fullscreen resets its geometry so the
        // first fullscreen frame lands at the cursor without timer-dependent
        // interpolation in this deterministic test.
        content.setCursor(normalizedX: 1, normalizedY: 1)
        content.setFullScreenPresentation(true)
        content.layoutSubtreeIfNeeded()

        #expect(video.frame.size == source.sourcePointSize)
        #expect(video.frame.origin == CGPoint(x: -1_200, y: 0))
        #expect(content.zoomPercentage == 100)

        content.setCursor(normalizedX: 0, normalizedY: 0)
        // Settling presentation deterministically exercises the same target
        // used by the 60 Hz cursor-follow timer without waiting on wall time.
        content.setPresentationActive(false)
        content.setPresentationActive(true)
        #expect(video.frame.origin == CGPoint(x: 0, y: -800))

        content.setFullScreenPresentation(false)
    }

    @Test("Fullscreen Fit continues to aspect-fit oversized sources")
    func fullscreenFitStillAspectFits() {
        let video = NSView()
        let content = NativeViewerContentView(videoView: video, identityColor: .systemPink)
        let source = Self.makeSource(
            sourcePointSize: CGSize(width: 2_400, height: 1_600)
        )
        content.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        content.update(
            ownerName: "Friend",
            source: source,
            identityColor: .systemPink,
            resolvedSourceLogicalSize: source.sourcePointSize
        )
        content.setScaleMode(.fit)
        content.setFullScreenPresentation(true)
        content.layoutSubtreeIfNeeded()

        #expect(video.frame == content.bounds)
        #expect(content.zoomPercentage == 50)

        content.setFullScreenPresentation(false)
    }

    @Test("Fullscreen pointer activity reuses one pending hide timer")
    func fullscreenPointerActivityCoalescesHideTimer() {
        let content = NativeViewerContentView(
            videoView: NSView(),
            identityColor: .systemPink
        )
        content.setFullScreenPresentation(true)
        let creationCount = content.fullScreenHideTimerCreationCount

        for _ in 0..<100 {
            content.noteFullScreenPointerActivityForTesting()
        }

        #expect(content.fullScreenHideTimerCreationCount == creationCount)
        content.setFullScreenPresentation(false)
    }

    @Test("Hidden fullscreen controls resign keyboard focus and disable actions")
    func hiddenFullscreenControlsResignKeyboardFocus() {
        let controller = makeController()
        defer { controller.tearDown() }
        controller.content.setFullScreenPresentation(true)

        #expect(
            controller.content.focusFullScreenCollaborationControlForTesting(
                .pointer
            )
        )
        #expect(controller.content.hasKeyboardFocusedFullScreenControl)

        controller.content.hideFullScreenHeaderImmediatelyForTesting()

        #expect(!controller.content.hasKeyboardFocusedFullScreenControl)
        #expect(!controller.content.areFullScreenControlsInteractive)
        #expect(!controller.content.areFullScreenControlsEnabled)
    }

    @Test("Fullscreen controls reveal on normal pointer movement")
    func fullscreenHeaderRevealRegion() {
        let bounds = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let header = NativeViewerContentView.fullScreenControlFrame(
            bounds: bounds,
            safeAreaTopInset: 0
        )

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
        #expect(NativeViewerContentView.shouldRevealFullScreenHeader(
            pointer: CGPoint(x: 600, y: 400),
            bounds: bounds,
            headerFrame: header
        ))
        #expect(!NativeViewerContentView.shouldRevealFullScreenHeader(
            pointer: CGPoint(x: -10, y: 400),
            bounds: bounds,
            headerFrame: header
        ))
    }

    @Test("Fullscreen capsule stays below system chrome and away from the top-right HUD")
    func fullscreenControlGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let ordinary = NativeViewerContentView.fullScreenControlFrame(
            bounds: bounds,
            safeAreaTopInset: 0
        )
        let notched = NativeViewerContentView.fullScreenControlFrame(
            bounds: bounds,
            safeAreaTopInset: 38
        )
        let narrow = NativeViewerContentView.fullScreenControlFrame(
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            safeAreaTopInset: 0
        )
        let medium = NativeViewerContentView.fullScreenControlFrame(
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600),
            safeAreaTopInset: 0
        )

        #expect(ordinary.size == CGSize(width: 500, height: 36))
        #expect(ordinary.midX == bounds.midX)
        #expect(bounds.maxY - ordinary.maxY >= 44)
        #expect(bounds.maxX - ordinary.maxX >= 200)
        #expect(bounds.maxY - notched.maxY >= 52)
        #expect(notched.maxY < ordinary.maxY)
        #expect(narrow.width == 368)
        #expect(narrow.midX == 400)
        #expect(800 - narrow.maxX >= 216)
        #expect(medium.width == 468)
        #expect(medium.midX == 450)
        #expect(900 - medium.maxX >= 216)
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

    @Test("Fullscreen teardown waits for AppKit to restore the window")
    func fullscreenTearDownWaitsForExit() {
        let controller = makeController()
        guard let window = controller.window else {
            Issue.record("Expected viewer window")
            return
        }
        let notification = Notification(
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        controller.windowWillEnterFullScreen(notification)
        controller.windowDidEnterFullScreen(notification)
        var exitRequestCount = 0

        controller.tearDown(requestFullScreenExit: { _ in
            exitRequestCount += 1
        })

        #expect(exitRequestCount == 1)
        #expect(controller.isTearDownPendingFullScreenExit)
        #expect(!controller.hasCompletedTearDown)
        #expect(window.delegate === controller)

        controller.windowWillExitFullScreen(notification)
        controller.windowDidExitFullScreen(notification)

        #expect(!controller.isTearDownPendingFullScreenExit)
        #expect(controller.hasCompletedTearDown)
        #expect(window.delegate == nil)
    }

    @Test("Teardown requested during fullscreen entry exits after entry completes")
    func tearDownDuringFullScreenEntryWaitsForDidEnter() {
        let controller = makeController()
        guard let window = controller.window else {
            Issue.record("Expected viewer window")
            return
        }
        let notification = Notification(
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        controller.windowWillEnterFullScreen(notification)
        var exitRequestCount = 0

        controller.tearDown(requestFullScreenExit: { _ in
            exitRequestCount += 1
        })
        #expect(exitRequestCount == 0)
        #expect(controller.isTearDownPendingFullScreenExit)

        controller.windowDidEnterFullScreen(notification)
        #expect(exitRequestCount == 1)

        controller.windowWillExitFullScreen(notification)
        controller.windowDidExitFullScreen(notification)
        #expect(controller.hasCompletedTearDown)
    }

    @Test("Leaving Follow during fullscreen cancels its deferred source resize")
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

        let grownSource = NativeViewerSourceSnapshot(
            sourceInstanceID: "source-1",
            streamID: "video0",
            applicationName: "Fixture",
            windowName: "Document",
            pixelSize: CGSize(width: 2_400, height: 1_350),
            sourcePointSize: CGSize(width: 1_200, height: 675),
            isFocused: true,
            isConnected: true,
            stateRevision: 2
        )
        controller.update(
            ownerName: "Friend",
            source: grownSource,
            identityColor: .systemPink
        )
        controller.setScaleMode(.native)
        controller.windowDidExitFullScreen(notification)

        #expect(controller.scaleMode == .native)
        #expect(window.frame == originalFrame)
    }

    @Test("Pair recovery retains the window and rebinds only the replacement track")
    func pairRecoveryRetainsWindowUntilReplacementTrack() throws {
        var boundSources: [NativeViewerSourceSnapshot] = []
        var teardownCount = 0
        let coordinator = NativeViewerWindowCoordinator(
            ownerName: "Friend",
            ownerPublicIdentity: Data(repeating: 7, count: 65),
            surfaceFactory: {
                NativeViewerVideoSurfaceAdapter(
                    view: NSView(),
                    bind: { boundSources.append($0) },
                    teardown: { teardownCount += 1 }
                )
            }
        )
        defer { coordinator.tearDown() }
        let connected = Self.makeSource()
        try coordinator.reconcile([connected])
        coordinator.setSourceVisible(
            false,
            sourceInstanceID: connected.sourceInstanceID
        )
        coordinator.setScaleMode(
            .native,
            sourceInstanceID: connected.sourceInstanceID
        )
        let disconnected = NativeViewerSourceSnapshot(
            sourceInstanceID: connected.sourceInstanceID,
            streamID: connected.streamID,
            applicationName: connected.applicationName,
            windowName: connected.windowName,
            pixelSize: connected.pixelSize,
            sourcePointSize: connected.sourcePointSize,
            isFocused: connected.isFocused,
            isConnected: false,
            stateRevision: connected.stateRevision
        )

        try coordinator.reconcile([disconnected])

        #expect(coordinator.windowCount == 1)
        #expect(coordinator.windowSnapshots.first?.isVisible == false)
        #expect(coordinator.windowSnapshots.first?.scaleMode == .native)
        #expect(boundSources == [connected])
        #expect(teardownCount == 0)

        let recovered = Self.makeSource(stateRevision: 2)
        try coordinator.reconcile([recovered])

        #expect(coordinator.windowCount == 1)
        #expect(coordinator.windowSnapshots.first?.isVisible == false)
        #expect(coordinator.windowSnapshots.first?.scaleMode == .native)
        #expect(boundSources == [connected, recovered])
        #expect(teardownCount == 0)
    }

    @Test("Coordinator applies and routes per-source collaboration controls")
    func coordinatorRoutesCollaborationControlsBySource() throws {
        let coordinator = NativeViewerWindowCoordinator(
            ownerName: "Friend",
            ownerPublicIdentity: Data(repeating: 9, count: 65),
            surfaceFactory: {
                NativeViewerVideoSurfaceAdapter(
                    view: NSView(),
                    bind: { _ in },
                    teardown: {}
                )
            }
        )
        defer { coordinator.tearDown() }
        let source = Self.makeSource()
        let custom = NativeViewerCollaborationControlState(
            pointerEnabled: true,
            pingEnabled: false,
            drawingEnabled: true,
            isUsingGlobalSettings: false
        )
        coordinator.setCollaborationControlState(
            custom,
            sourceInstanceID: source.sourceInstanceID
        )
        try coordinator.reconcile([source])

        var change: (
            String,
            NativeViewerCollaborationControlTool,
            Bool
        )?
        var resetSource: String?
        coordinator.onCollaborationControlChanged = {
            change = ($0, $1, $2)
        }
        coordinator.onCollaborationControlResetToGlobal = {
            resetSource = $0
        }
        coordinator.activateCollaborationControl(
            .ping,
            sourceInstanceID: source.sourceInstanceID
        )
        coordinator.activateResetCollaborationToGlobal(
            sourceInstanceID: source.sourceInstanceID
        )

        #expect(coordinator.collaborationControlState(
            sourceInstanceID: source.sourceInstanceID
        ) == custom)
        #expect(change?.0 == source.sourceInstanceID)
        #expect(change?.1 == .ping)
        #expect(change?.2 == true)
        #expect(resetSource == source.sourceInstanceID)

        try coordinator.reconcile([])
        #expect(coordinator.collaborationControlState(
            sourceInstanceID: source.sourceInstanceID
        ) == nil)
    }

    private func makeController(
        source: NativeViewerSourceSnapshot = Self.makeSource()
    ) -> NativeViewerWindowController {
        NativeViewerWindowController(
            id: .source(instanceID: source.sourceInstanceID),
            ownerName: "Friend",
            source: source,
            identityColor: .systemPink,
            videoView: NSView()
        )
    }

    private static func makeSource(
        sourcePointSize: CGSize = CGSize(width: 960, height: 540),
        stateRevision: UInt64 = 1
    ) -> NativeViewerSourceSnapshot {
        NativeViewerSourceSnapshot(
            sourceInstanceID: "source-1",
            streamID: "video0",
            applicationName: "Fixture",
            windowName: "Document",
            pixelSize: CGSize(
                width: sourcePointSize.width * 2,
                height: sourcePointSize.height * 2
            ),
            sourcePointSize: sourcePointSize,
            isFocused: true,
            isConnected: true,
            stateRevision: stateRevision
        )
    }
}
