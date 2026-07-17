import ClipCore
import ClipMedia
import CoreGraphics
import Foundation
import Testing
@testable import Clip

@Suite("Capture selection adapter")
struct CaptureSelectionAdapterTests {
    @Test("Converts bottom-left AppKit geometry to top-left ScreenCaptureKit geometry")
    func convertsAreaCoordinates() throws {
        let display = CaptureSelectionDisplay(
            id: "display-test",
            displayID: 42,
            name: "Fixture Display",
            frameInGlobalPoints: CGRect(x: 0, y: 0, width: 1_000, height: 500),
            pixelSize: CGSize(width: 2_000, height: 1_000),
            scaleFactor: 2,
            isMain: true
        )
        let pointRect = CGRect(x: 100, y: 100, width: 400, height: 200)
        let area = SelectedCaptureArea(
            display: display,
            rectangleInDisplayPoints: pointRect,
            normalizedRectangle: NormalizedCaptureRectangle(
                rect: pointRect,
                in: display.localBounds
            ),
            outputPixelSize: CGSize(width: 800, height: 400)
        )

        let prepared = try CaptureSelectionAdapter.preparedTarget(from: .area(area))

        #expect(prepared.sourceRect == CGRect(x: 100, y: 200, width: 400, height: 200))
        #expect(prepared.outputWidth == 800)
        #expect(prepared.outputHeight == 400)
        guard case let .region(selection) = prepared.domainTarget else {
            Issue.record("Expected a region target")
            return
        }
        #expect(selection.normalizedRect.x == 0.1)
        #expect(selection.normalizedRect.y == 0.4)
        #expect(selection.normalizedRect.width == 0.4)
        #expect(selection.normalizedRect.height == 0.4)
    }

    @Test("Area source geometry snaps outward to exact even physical pixels")
    func pixelAlignsAreaGeometry() throws {
        let display = makeDisplay()
        let pointRect = CGRect(x: 100.25, y: 100.25, width: 400.1, height: 200.1)
        let area = SelectedCaptureArea(
            display: display,
            rectangleInDisplayPoints: pointRect,
            normalizedRectangle: NormalizedCaptureRectangle(
                rect: pointRect,
                in: display.localBounds
            ),
            // Capture preparation derives dimensions from the aligned source
            // rectangle instead of trusting stale pre-alignment metadata.
            outputPixelSize: CGSize(width: 801, height: 401)
        )

        let prepared = try CaptureSelectionAdapter.preparedTarget(from: .area(area))

        #expect(prepared.sourceRect == CGRect(x: 100, y: 199.5, width: 401, height: 201))
        #expect(prepared.outputWidth == 802)
        #expect(prepared.outputHeight == 402)
        #expect(prepared.outputWidth.isMultiple(of: 2))
        #expect(prepared.outputHeight.isMultiple(of: 2))
        #expect(prepared.sourceRect?.width == CGFloat(prepared.outputWidth) / 2)
        #expect(prepared.sourceRect?.height == CGFloat(prepared.outputHeight) / 2)
    }

    @Test("Retake realigns durable Region geometry on the display's current pixel grid")
    func pixelAlignsRetakeRegionGeometry() throws {
        let display = makeDisplay()
        let durableSelection = ClipCore.CaptureSelection(
            displayID: try DisplayID(display.id),
            normalizedRect: try NormalizedRect(
                x: 0.10025,
                y: 0.2005,
                width: 0.4001,
                height: 0.4002
            )
        )

        let prepared = try CaptureSelectionAdapter.preparedTarget(
            from: durableSelection,
            on: display
        )

        #expect(prepared.sourceRect == CGRect(x: 100, y: 100, width: 401, height: 201))
        #expect(prepared.outputWidth == 802)
        #expect(prepared.outputHeight == 402)
        #expect(prepared.outputWidth.isMultiple(of: 2))
        #expect(prepared.outputHeight.isMultiple(of: 2))
        guard case let .region(alignedSelection) = prepared.domainTarget else {
            Issue.record("Expected a region target")
            return
        }
        #expect(alignedSelection.normalizedRect.x == 0.1)
        #expect(alignedSelection.normalizedRect.y == 0.2)
        #expect(alignedSelection.normalizedRect.width == 0.401)
        #expect(alignedSelection.normalizedRect.height == 0.402)
    }

    @MainActor
    @Test("Last Area persists normalized geometry")
    func persistsLastArea() throws {
        let suiteName = "com.tomaslejdung.clip.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LastAreaStore(defaults: defaults)
        let display = CaptureSelectionDisplay(
            id: "display-persisted",
            displayID: 7,
            name: "Fixture Display",
            frameInGlobalPoints: CGRect(x: 0, y: 0, width: 1_000, height: 500),
            pixelSize: CGSize(width: 2_000, height: 1_000),
            scaleFactor: 2,
            isMain: true
        )
        let rectangle = CGRect(x: 50, y: 60, width: 300, height: 180)
        let selected = SelectedCaptureArea(
            display: display,
            rectangleInDisplayPoints: rectangle,
            normalizedRectangle: NormalizedCaptureRectangle(
                rect: rectangle,
                in: display.localBounds
            ),
            outputPixelSize: CGSize(width: 600, height: 360)
        )

        try store.save(selected)

        let restored = try #require(store.load())
        #expect(restored.displayIdentifier == display.id)
        #expect(restored.rectangle == selected.normalizedRectangle)
    }

    @MainActor
    @Test("Last Area ignores corrupt data and can be cleared")
    func rejectsCorruptAndClearsLastArea() throws {
        let suiteName = "com.tomaslejdung.clip.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LastAreaStore(defaults: defaults)

        defaults.set(Data("not-json".utf8), forKey: "capture.lastArea")
        #expect(store.load() == nil)

        let display = makeDisplay()
        let rectangle = CGRect(x: 25, y: 40, width: 320, height: 180)
        try store.save(SelectedCaptureArea(
            display: display,
            rectangleInDisplayPoints: rectangle,
            normalizedRectangle: NormalizedCaptureRectangle(
                rect: rectangle,
                in: display.localBounds
            ),
            outputPixelSize: CGSize(width: 640, height: 360)
        ))
        #expect(store.load() != nil)

        store.clear()
        #expect(store.load() == nil)
    }

    @Test("Fullscreen targets retain stable display identity and native pixel dimensions")
    func preparesFullscreenTarget() throws {
        let display = makeDisplay(
            id: "stable-display-uuid",
            displayID: 91,
            pointSize: CGSize(width: 1_512, height: 982),
            pixelSize: CGSize(width: 3_024, height: 1_964)
        )

        let prepared = try CaptureSelectionAdapter.preparedTarget(from: .fullscreen(display))

        #expect(prepared.displayID == 91)
        #expect(prepared.sourceRect == nil)
        #expect(prepared.outputWidth == 3_024)
        #expect(prepared.outputHeight == 1_964)
        guard case let .fullscreen(displayID) = prepared.domainTarget else {
            Issue.record("Expected a fullscreen target")
            return
        }
        #expect(displayID.rawValue == "stable-display-uuid")
    }

    @Test("Fullscreen dimensions are even before recording configuration")
    func preparesEvenFullscreenDimensions() throws {
        let display = makeDisplay(
            pointSize: CGSize(width: 1_000.5, height: 500.5),
            pixelSize: CGSize(width: 2_001, height: 1_001)
        )

        let prepared = try CaptureSelectionAdapter.preparedTarget(from: .fullscreen(display))

        #expect(prepared.outputWidth == 2_000)
        #expect(prepared.outputHeight == 1_000)
    }

    @Test("Adapter rejects empty display bounds and non-positive output pixels")
    func rejectsInvalidPreparedTargets() {
        let emptyDisplay = makeDisplay(
            pointSize: .zero,
            pixelSize: CGSize(width: 100, height: 100)
        )
        let emptyArea = SelectedCaptureArea(
            display: emptyDisplay,
            rectangleInDisplayPoints: .zero,
            normalizedRectangle: NormalizedCaptureRectangle(x: 0, y: 0, width: 1, height: 1),
            outputPixelSize: CGSize(width: 100, height: 100)
        )
        #expect(throws: CaptureSelectionAdapterError.invalidDisplayBounds) {
            try CaptureSelectionAdapter.preparedTarget(from: .area(emptyArea))
        }

        let invalidPixels = makeDisplay(pixelSize: CGSize(width: 0, height: 1_080))
        #expect(throws: CaptureSelectionAdapterError.invalidPixelSize) {
            try CaptureSelectionAdapter.preparedTarget(from: .fullscreen(invalidPixels))
        }
    }

    @Test("Application selection preserves z-order, clips to one display, and includes only that app")
    func preparesApplicationTarget() throws {
        let display = makeDisplay(id: "stable-app-display", displayID: 88)
        let quartzFrame = CGRect(x: 1_000, y: 0, width: 1_000, height: 500)
        let windows = [
            CaptureApplicationWindow(
                windowID: 10,
                frame: CGRect(x: 1_100, y: 50, width: 400, height: 200),
                bundleIdentifier: "com.apple.Safari",
                applicationName: "Safari",
                processID: 101
            ),
            CaptureApplicationWindow(
                windowID: 11,
                frame: CGRect(x: 1_300, y: 300, width: 300, height: 150),
                bundleIdentifier: "com.apple.Safari",
                applicationName: "Safari",
                processID: 101
            ),
            CaptureApplicationWindow(
                windowID: 12,
                frame: CGRect(x: 1_050, y: 25, width: 900, height: 450),
                bundleIdentifier: "com.apple.Notes",
                applicationName: "Notes",
                processID: 202
            ),
            // This window touches the display edge but has no visible area on it.
            CaptureApplicationWindow(
                windowID: 13,
                frame: CGRect(x: 2_000, y: 0, width: 200, height: 200),
                bundleIdentifier: "com.apple.Mail",
                applicationName: "Mail",
                processID: 303
            ),
        ]

        let segments = ApplicationCaptureSelectionLayout.segments(
            for: display,
            quartzDisplayFrame: quartzFrame,
            windows: windows
        )
        #expect(segments.map(\.windowID) == [10, 11, 12])
        #expect(
            segments[0].rectangleInDisplayPoints
                == CGRect(x: 100, y: 250, width: 400, height: 200)
        )
        #expect(
            ApplicationCaptureSelectionLayout.bundleIdentifier(
                at: CGPoint(x: 150, y: 300),
                in: segments
            ) == "com.apple.Safari"
        )

        let selection = try #require(
            ApplicationCaptureSelectionLayout.selection(
                bundleIdentifier: "com.apple.Safari",
                display: display,
                segments: segments
            )
        )
        #expect(selection.sourceRectangleInDisplayPoints == CGRect(x: 100, y: 50, width: 500, height: 400))
        #expect(selection.rectangleInDisplayPoints == CGRect(x: 100, y: 50, width: 500, height: 400))
        #expect(selection.outputPixelSize == CGSize(width: 1_000, height: 800))
        #expect(selection.highlightedRectanglesInDisplayPoints.count == 2)

        let prepared = try CaptureSelectionAdapter.preparedTarget(from: selection)
        #expect(prepared.displayID == 88)
        #expect(prepared.sourceRect == selection.sourceRectangleInDisplayPoints)
        #expect(prepared.outputWidth == 1_000)
        #expect(prepared.outputHeight == 800)
        #expect(prepared.includedApplicationBundleIdentifier == "com.apple.Safari")
        guard case let .application(target) = prepared.domainTarget else {
            Issue.record("Expected an application target")
            return
        }
        #expect(target.displayID.rawValue == "stable-app-display")
        #expect(target.bundleIdentifier == "com.apple.Safari")
        #expect(target.applicationName == "Safari")
    }

    @Test("Application source geometry grows inward at display edges to stay pixel aligned")
    func pixelAlignsApplicationGeometryAtDisplayEdges() throws {
        let display = makeDisplay()
        let sourceRectangle = CGRect(x: 600.75, y: 100.75, width: 399.25, height: 399.25)
        let selection = SelectedCaptureApplication(
            display: display,
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            rectangleInDisplayPoints: CGRect(x: 600.75, y: 0, width: 399.25, height: 399.25),
            sourceRectangleInDisplayPoints: sourceRectangle,
            outputPixelSize: CGSize(width: 799, height: 799),
            highlightedRectanglesInDisplayPoints: []
        )

        let prepared = try CaptureSelectionAdapter.preparedTarget(from: selection)

        #expect(prepared.sourceRect == CGRect(x: 600, y: 100, width: 400, height: 400))
        #expect(prepared.outputWidth == 800)
        #expect(prepared.outputHeight == 800)
        #expect(prepared.sourceRect?.maxX == display.localBounds.maxX)
        #expect(prepared.sourceRect?.maxY == display.localBounds.maxY)
    }

    @Test("Selection clamping and movement stay entirely on one display")
    func clampsAndMovesSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let minimum = CGSize(width: 96, height: 64)

        let clamped = CaptureSelectionGeometry.clamped(
            CGRect(x: -40, y: 590, width: 20, height: 10),
            to: bounds,
            minimumSize: minimum
        )
        #expect(clamped == CGRect(x: 0, y: 536, width: 96, height: 64))

        let moved = CaptureSelectionGeometry.moved(
            CGRect(x: 100, y: 100, width: 300, height: 200),
            by: CGVector(dx: 1_000, dy: -1_000),
            in: bounds
        )
        #expect(moved == CGRect(x: 500, y: 0, width: 300, height: 200))
        #expect(bounds.contains(moved))
    }

    @Test("Pointer creation supports reverse drags and aspect-ratio preservation")
    func createsSelectionFromPointerDrag() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let minimum = CGSize(width: 96, height: 64)

        let reverse = CaptureSelectionGeometry.rectangle(
            from: CGPoint(x: 500, y: 400),
            to: CGPoint(x: 100, y: 150),
            in: bounds,
            minimumSize: minimum
        )
        #expect(reverse == CGRect(x: 100, y: 150, width: 400, height: 250))

        let widescreen = CaptureSelectionGeometry.rectangle(
            from: CGPoint(x: 100, y: 100),
            to: CGPoint(x: 500, y: 300),
            in: bounds,
            minimumSize: minimum,
            aspectRatio: 16.0 / 9.0
        )
        #expect(abs((widescreen.width / widescreen.height) - (16.0 / 9.0)) < 0.000_001)
        #expect(bounds.contains(widescreen))
    }

    @Test("Pointer creation follows the drag origin before minimum-size finalization")
    func draftsSelectionExactlyFromPointerOrigin() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 700)

        let initial = CaptureSelectionGeometry.draftRectangle(
            from: CGPoint(x: 400, y: 300),
            to: CGPoint(x: 400, y: 300),
            in: bounds
        )
        #expect(initial == CGRect(x: 400, y: 300, width: 0, height: 0))

        let forward = CaptureSelectionGeometry.draftRectangle(
            from: CGPoint(x: 400, y: 300),
            to: CGPoint(x: 421, y: 314),
            in: bounds
        )
        #expect(forward == CGRect(x: 400, y: 300, width: 21, height: 14))

        let reverseSquare = CaptureSelectionGeometry.draftRectangle(
            from: CGPoint(x: 400, y: 300),
            to: CGPoint(x: 380, y: 270),
            in: bounds,
            aspectRatio: 1
        )
        #expect(reverseSquare == CGRect(x: 370, y: 270, width: 30, height: 30))
    }

    @Test("Draft finalization ignores clicks and flat strokes before enforcing the minimum")
    func finalizesOnlyTwoDimensionalPointerDrags() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let minimum = CGSize(width: 96, height: 64)

        #expect(CaptureSelectionGeometry.finalizedDraftRectangle(
            CGRect(x: 400, y: 300, width: 0, height: 0),
            in: bounds,
            minimumSize: minimum
        ) == nil)
        #expect(CaptureSelectionGeometry.finalizedDraftRectangle(
            CGRect(x: 400, y: 300, width: 80, height: 1),
            in: bounds,
            minimumSize: minimum
        ) == nil)
        #expect(CaptureSelectionGeometry.finalizedDraftRectangle(
            CGRect(x: 400, y: 300, width: 1, height: 80),
            in: bounds,
            minimumSize: minimum
        ) == nil)

        let finalized = CaptureSelectionGeometry.finalizedDraftRectangle(
            CGRect(x: 400, y: 300, width: 20, height: 12),
            in: bounds,
            minimumSize: minimum
        )
        #expect(finalized == CGRect(x: 400, y: 300, width: 96, height: 64))
    }

    @Test("Handle resizing enforces minimum size, bounds, and Shift aspect ratio")
    func resizesSelectionFromHandles() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 700)
        let minimum = CGSize(width: 96, height: 64)
        let original = CGRect(x: 100, y: 100, width: 400, height: 200)

        let expanded = CaptureSelectionGeometry.resized(
            original,
            using: .topRight,
            delta: CGVector(dx: 100, dy: 50),
            in: bounds,
            minimumSize: minimum,
            preserveAspectRatio: true
        )
        #expect(expanded == CGRect(x: 100, y: 100, width: 500, height: 250))
        #expect(expanded.width / expanded.height == original.width / original.height)

        let collapsed = CaptureSelectionGeometry.resized(
            original,
            using: .bottomRight,
            delta: CGVector(dx: -1_000, dy: 1_000),
            in: bounds,
            minimumSize: minimum,
            preserveAspectRatio: false
        )
        #expect(collapsed.width == minimum.width)
        #expect(collapsed.height == minimum.height)
        #expect(bounds.contains(collapsed))
    }

    @Test("Toolbar placement prefers outside the recording and always remains on-screen")
    func positionsToolbarSafely() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let selection = CGRect(x: 250, y: 250, width: 300, height: 180)
        let toolbarSize = CGSize(width: 220, height: 100)
        let outsideOrigin = CaptureSelectionGeometry.toolbarOrigin(
            selection: selection,
            toolbarSize: toolbarSize,
            in: bounds,
            padding: 12
        )
        let outsideFrame = CGRect(origin: outsideOrigin, size: toolbarSize)
        #expect(bounds.contains(outsideFrame))
        #expect(!outsideFrame.intersects(selection))

        let fallbackOrigin = CaptureSelectionGeometry.toolbarOrigin(
            selection: bounds,
            toolbarSize: toolbarSize,
            in: bounds,
            padding: 12
        )
        #expect(bounds.contains(CGRect(origin: fallbackOrigin, size: toolbarSize)))
    }

    @Test("Last Area normalization clips to a display and sanitizes non-finite persisted values")
    func normalizesAndSanitizesSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 500)
        let clipped = NormalizedCaptureRectangle(
            rect: CGRect(x: -100, y: 100, width: 500, height: 500),
            in: bounds
        )
        #expect(clipped == NormalizedCaptureRectangle(x: 0, y: 0.2, width: 0.4, height: 0.8))

        let corrupt = NormalizedCaptureRectangle(
            x: .nan,
            y: .infinity,
            width: .nan,
            height: -.infinity
        )
        #expect(corrupt.denormalized(in: bounds) == bounds)
    }

    @Test("Keyboard focus order wraps in both directions")
    func cyclesKeyboardFocus() {
        #expect(CaptureSelectionFocus.region.advanced(reverse: false) == .handle(.bottomLeft))
        #expect(CaptureSelectionFocus.region.advanced(reverse: true) == .cancelButton)
        #expect(CaptureSelectionFocus.cancelButton.advanced(reverse: false) == .region)
    }

    @Test("Pixel dimensions use the physical display scale")
    func convertsPointsToPixels() {
        let rectangle = CGRect(x: 0, y: 0, width: 333.25, height: 222.75)
        #expect(
            CaptureSelectionGeometry.pixelSize(for: rectangle, scaleFactor: 2)
                == CGSize(width: 668, height: 446)
        )
    }

    private func makeDisplay(
        id: String = "fixture-display",
        displayID: CGDirectDisplayID = 42,
        pointSize: CGSize = CGSize(width: 1_000, height: 500),
        pixelSize: CGSize = CGSize(width: 2_000, height: 1_000)
    ) -> CaptureSelectionDisplay {
        CaptureSelectionDisplay(
            id: id,
            displayID: displayID,
            name: "Fixture Display",
            frameInGlobalPoints: CGRect(origin: .zero, size: pointSize),
            pixelSize: pixelSize,
            scaleFactor: pointSize.width > 0 ? pixelSize.width / pointSize.width : 1,
            isMain: true
        )
    }
}
