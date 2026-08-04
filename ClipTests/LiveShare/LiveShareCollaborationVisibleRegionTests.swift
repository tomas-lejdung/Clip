import CoreGraphics
import Testing

@testable import Clip

@Suite("Live Share collaboration visible region")
struct LiveShareCollaborationVisibleRegionTests {
    @Test("an opaque window in front removes only its overlapping area")
    func partialCoverIsSubtracted() throws {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = try #require(visibleRects(
            sourceFrame: source,
            windows: [
                window(2, CGRect(x: 60, y: -20, width: 80, height: 140)),
                window(1, source),
            ]
        ))

        #expect(result == [CGRect(x: 0, y: 0, width: 60, height: 100)])
    }

    @Test("overlapping covers produce non-overlapping visible fragments")
    func multipleOverlappingCoversRemainDisjoint() throws {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = try #require(visibleRects(
            sourceFrame: source,
            windows: [
                window(2, CGRect(x: 0, y: 50, width: 60, height: 50)),
                window(3, CGRect(x: 40, y: 25, width: 60, height: 50)),
                window(1, source),
            ]
        ))

        #expect(totalArea(result) == 4_500)
        for index in result.indices {
            for otherIndex in result.indices where otherIndex > index {
                let intersection = result[index].intersection(result[otherIndex])
                #expect(intersection.isNull || intersection.isEmpty)
            }
        }
        #expect(result.allSatisfy { source.contains($0) })
    }

    @Test("a full opaque cover produces a verified empty region")
    func fullCoverProducesEmptyRegion() throws {
        let source = CGRect(x: 10, y: 20, width: 80, height: 60)
        let result = try #require(visibleRects(
            sourceFrame: source,
            windows: [
                window(2, CGRect(x: 0, y: 0, width: 200, height: 200)),
                window(1, source),
            ]
        ))

        #expect(result.isEmpty)
    }

    @Test("windows behind the source do not occlude it")
    func coverBehindSourceIsIgnored() throws {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = try #require(visibleRects(
            sourceFrame: source,
            windows: [
                window(1, source),
                window(2, source),
            ]
        ))

        #expect(result == [source])
    }

    @Test("excluded overlay windows never occlude their own source")
    func excludedOverlayIsIgnored() throws {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = try #require(
            LiveShareCollaborationVisibleRegionGeometry.visibleRects(
                sourceFrame: source,
                windowsFrontToBack: [
                    window(99, source),
                    window(1, source),
                ],
                sourceWindowNumber: 1,
                excludedWindowNumbers: [99]
            )
        )

        #expect(result == [source])
    }

    @Test("WindowServer cursor surfaces never cut holes in the source")
    func systemCursorSurfaceIsIgnored() throws {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        var evaluations: [LiveShareCollaborationOcclusionEvaluation] = []
        let result = try #require(
            LiveShareCollaborationVisibleRegionGeometry.visibleRects(
                sourceFrame: source,
                windowsFrontToBack: [
                    window(
                        5,
                        CGRect(x: 40, y: 40, width: 23, height: 22),
                        ownerProcessID: 618,
                        windowLayer: Int(
                            CGWindowLevelForKey(.cursorWindow)
                        )
                    ),
                    window(1, source),
                ],
                sourceWindowNumber: 1,
                onEvaluation: { evaluations.append($0) }
            )
        )

        #expect(result == [source])
        #expect(evaluations.count == 1)
        #expect(evaluations[0].disposition == .systemCursor)
        #expect(evaluations[0].cumulativeVisibleAreaRatio == 1)
    }

    @Test("a genuine window with cursor-sized geometry still occludes")
    func cursorSizedAppWindowStillOccludes() throws {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cover = CGRect(x: 40, y: 40, width: 23, height: 22)
        let result = try #require(visibleRects(
            sourceFrame: source,
            windows: [
                window(
                    2,
                    cover,
                    ownerProcessID: 618,
                    windowLayer: 0
                ),
                window(1, source),
            ]
        ))

        #expect(
            totalArea(result) == source.width * source.height
                - cover.width * cover.height
        )
    }

    @Test("display-sized surfaces above the fallback panel do not mask it")
    func highLevelDisplaySurfaceIsCompositorOccluded() throws {
        let source = CGRect(x: 100, y: 100, width: 600, height: 400)
        let display = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        var evaluations: [LiveShareCollaborationOcclusionEvaluation] = []
        let result = try #require(
            LiveShareCollaborationVisibleRegionGeometry.visibleRects(
                sourceFrame: source,
                windowsFrontToBack: [
                    window(2, display, windowLayer: 25),
                    window(1, source, windowLayer: 0),
                ],
                sourceWindowNumber: 1,
                maximumOccludingWindowLayer: 3,
                onEvaluation: { evaluations.append($0) }
            )
        )

        #expect(result == [source])
        #expect(evaluations.count == 1)
        #expect(evaluations[0].disposition == .aboveOverlayLevel)
        #expect(evaluations[0].cumulativeVisibleAreaRatio == 1)
    }

    @Test("normal-level display-sized windows still mask the fallback")
    func normalLevelDisplayCoverStillOccludes() throws {
        let source = CGRect(x: 100, y: 100, width: 600, height: 400)
        let display = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let result = try #require(
            LiveShareCollaborationVisibleRegionGeometry.visibleRects(
                sourceFrame: source,
                windowsFrontToBack: [
                    window(2, display, windowLayer: 0),
                    window(1, source, windowLayer: 0),
                ],
                sourceWindowNumber: 1,
                maximumOccludingWindowLayer: 3
            )
        )

        #expect(result.isEmpty)
    }

    @Test("off-screen and fully transparent windows do not remove content")
    func invisibleWindowsAreIgnored() throws {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = try #require(visibleRects(
            sourceFrame: source,
            windows: [
                window(2, source, alpha: 1, isOnScreen: false),
                window(3, source, alpha: 0),
                window(1, source),
            ]
        ))

        #expect(result == [source])
    }

    @Test("a translucent window is conservatively treated as an occluder")
    func translucentWindowOccludes() throws {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = try #require(visibleRects(
            sourceFrame: source,
            windows: [
                window(
                    2,
                    CGRect(x: 50, y: 0, width: 50, height: 100),
                    alpha: 0.5
                ),
                window(1, source),
            ]
        ))

        #expect(result == [CGRect(x: 0, y: 0, width: 50, height: 100)])
    }

    @Test("negative desktop coordinates retain exact geometry")
    func negativeCoordinatesAreSupported() throws {
        let source = CGRect(x: -200, y: -100, width: 100, height: 100)
        let result = try #require(visibleRects(
            sourceFrame: source,
            windows: [
                window(
                    2,
                    CGRect(x: -150, y: -100, width: 50, height: 100)
                ),
                window(1, source),
            ]
        ))

        #expect(
            result == [CGRect(x: -200, y: -100, width: 50, height: 100)]
        )
    }

    @Test("display-sized candidate captures the inverse edge-reveal signature")
    func displaySizedCandidateRevealsOffDisplaySourceGeometry() throws {
        let display = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let fullyOnScreenSource = CGRect(
            x: 100,
            y: 100,
            width: 600,
            height: 400
        )
        let straddlingSource = CGRect(
            x: 700,
            y: 100,
            width: 600,
            height: 400
        )
        var fullyOnScreenEvaluations:
            [LiveShareCollaborationOcclusionEvaluation] = []
        let fullyOnScreenVisible = try #require(
            LiveShareCollaborationVisibleRegionGeometry.visibleRects(
                sourceFrame: fullyOnScreenSource,
                windowsFrontToBack: [
                    window(2, display),
                    window(1, fullyOnScreenSource),
                ],
                sourceWindowNumber: 1,
                onEvaluation: { fullyOnScreenEvaluations.append($0) }
            )
        )

        #expect(fullyOnScreenVisible.isEmpty)
        #expect(fullyOnScreenEvaluations.count == 1)
        #expect(fullyOnScreenEvaluations[0].disposition == .occluding)
        #expect(fullyOnScreenEvaluations[0].cumulativeVisibleAreaRatio == 0)

        var straddlingEvaluations:
            [LiveShareCollaborationOcclusionEvaluation] = []
        let straddlingVisible = try #require(
            LiveShareCollaborationVisibleRegionGeometry.visibleRects(
                sourceFrame: straddlingSource,
                windowsFrontToBack: [
                    window(2, display),
                    window(1, straddlingSource),
                ],
                sourceWindowNumber: 1,
                onEvaluation: { straddlingEvaluations.append($0) }
            )
        )

        #expect(straddlingVisible == [
            CGRect(x: 1_000, y: 100, width: 300, height: 400),
        ])
        #expect(straddlingEvaluations.count == 1)
        #expect(straddlingEvaluations[0].disposition == .occluding)
        #expect(straddlingEvaluations[0].cumulativeVisibleAreaRatio == 0.5)

        // A panel clipped to the display intersection maps the surviving,
        // entirely off-display source strip back into the visible panel. That
        // was the observed "move right, reveal more" failure.
        let clippedPanelSize = straddlingSource.intersection(display).size
        let local = try #require(
            LiveShareCollaborationVisibleRegionGeometry.localRects(
                visibleGlobalRects: straddlingVisible,
                sourceFrame: straddlingSource,
                localSize: clippedPanelSize
            )
        )
        #expect(local == [
            CGRect(x: 150, y: 0, width: 150, height: 400),
        ])

        // Production preserves the full WindowServer source extent. The same
        // strip therefore stays in its correct off-display half of the panel
        // instead of being compressed into visible display space.
        let fullExtentLocal = try #require(
            LiveShareCollaborationVisibleRegionGeometry.localRects(
                visibleGlobalRects: straddlingVisible,
                sourceFrame: straddlingSource,
                localSize: straddlingSource.size
            )
        )
        #expect(fullExtentLocal == [
            CGRect(x: 300, y: 0, width: 300, height: 400),
        ])
    }

    @Test("WindowServer rectangles flip and scale into panel-local coordinates")
    func globalRectsConvertToLocalPanelCoordinates() throws {
        let result = try #require(
            LiveShareCollaborationVisibleRegionGeometry.localRects(
                visibleGlobalRects: [
                    // Top-left and bottom-right quarters in Quartz's
                    // top-left-origin global coordinate space.
                    CGRect(x: -100, y: 200, width: 100, height: 50),
                    CGRect(x: 0, y: 250, width: 100, height: 50),
                ],
                sourceFrame: CGRect(x: -100, y: 200, width: 200, height: 100),
                localSize: CGSize(width: 400, height: 200)
            )
        )

        #expect(result == [
            CGRect(x: 200, y: 0, width: 200, height: 100),
            CGRect(x: 0, y: 100, width: 200, height: 100),
        ])
    }

    @Test("invalid panel conversion geometry fails closed")
    func invalidLocalConversionFailsClosed() {
        #expect(
            LiveShareCollaborationVisibleRegionGeometry.localRects(
                visibleGlobalRects: [CGRect(x: 0, y: 0, width: 10, height: 10)],
                sourceFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                localSize: .zero
            ) == nil
        )
    }

    @Test("a missing or off-screen source fails closed")
    func unavailableSourceFailsClosed() {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(visibleRects(
            sourceFrame: source,
            windows: [window(2, source)]
        ) == nil)
        #expect(visibleRects(
            sourceFrame: source,
            windows: [window(1, source, isOnScreen: false)]
        ) == nil)
        #expect(visibleRects(
            sourceFrame: source,
            windows: [window(1, source, alpha: 0)]
        ) == nil)
    }

    @Test("unknown opaque occluder geometry fails closed")
    func invalidOpaqueCoverFailsClosed() {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(visibleRects(
            sourceFrame: source,
            windows: [
                window(
                    2,
                    CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20)
                ),
                window(1, source),
            ]
        ) == nil)
    }

    private func visibleRects(
        sourceFrame: CGRect,
        windows: [LiveShareCollaborationOcclusionWindowSnapshot]
    ) -> [CGRect]? {
        LiveShareCollaborationVisibleRegionGeometry.visibleRects(
            sourceFrame: sourceFrame,
            windowsFrontToBack: windows,
            sourceWindowNumber: 1
        )
    }

    private func window(
        _ number: Int,
        _ frame: CGRect,
        alpha: Double = 1,
        isOnScreen: Bool = true,
        ownerProcessID: Int? = nil,
        windowLayer: Int? = nil
    ) -> LiveShareCollaborationOcclusionWindowSnapshot {
        .init(
            windowNumber: number,
            frame: frame,
            alpha: alpha,
            isOnScreen: isOnScreen,
            ownerProcessID: ownerProcessID,
            windowLayer: windowLayer
        )
    }

    private func totalArea(_ rects: [CGRect]) -> CGFloat {
        rects.reduce(0) { $0 + $1.width * $1.height }
    }
}
