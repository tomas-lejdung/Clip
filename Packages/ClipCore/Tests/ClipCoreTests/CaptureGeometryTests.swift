import Foundation
import Testing
@testable import ClipCore

@Suite("One-display capture geometry")
struct CaptureGeometryTests {
    @Test("Strict normalized rectangles reject invalid geometry")
    func strictGeometryValidation() {
        #expect(throws: CaptureGeometryError.normalizedRectOutsideDisplay) {
            try NormalizedRect(x: 0.8, y: 0, width: 0.3, height: 1)
        }
        #expect(throws: CaptureGeometryError.nonPositiveNormalizedSize(width: 0, height: 1)) {
            try NormalizedRect(x: 0, y: 0, width: 0, height: 1)
        }
        #expect(throws: CaptureGeometryError.nonFiniteNormalizedRect) {
            try NormalizedRect(x: .nan, y: 0, width: 1, height: 1)
        }
    }

    @Test("Clamping preserves size and translates selection inside one display")
    func clampPreservesSize() throws {
        let rect = try NormalizedRect.clamped(x: 0.9, y: -0.4, width: 0.25, height: 0.5)
        let expected = try NormalizedRect(x: 0.75, y: 0, width: 0.25, height: 0.5)
        #expect(rect == expected)
    }

    @Test("Oversized selection clamps to the complete display")
    func clampOversized() throws {
        let rect = try NormalizedRect.clamped(x: 0.2, y: 0.2, width: 4, height: 2)
        let expected = try NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        #expect(rect == expected)
    }

    @Test("Translation and resize remain inside the same display")
    func translationAndResize() throws {
        let initial = try NormalizedRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let moved = try initial.translated(byX: 1, y: -1)
        let expectedMoved = try NormalizedRect(x: 0.6, y: 0, width: 0.4, height: 0.4)
        #expect(moved == expectedMoved)

        let resized = try moved.resized(width: 0.9, height: 2)
        let expectedResized = try NormalizedRect(x: 0.6, y: 0, width: 0.4, height: 1)
        #expect(resized == expectedResized)
    }

    @Test("Normalized coordinates convert to covering display-local pixels")
    func pixelConversion() throws {
        let size = try PixelSize(width: 100, height: 50)
        let fractional = try NormalizedRect(x: 0.101, y: 0.201, width: 0.5, height: 0.5)
        let expectedFractional = try PixelRect(x: 10, y: 10, width: 51, height: 26)
        #expect(fractional.pixelRect(in: size) == expectedFractional)

        let full = try NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        let expectedFull = try PixelRect(x: 0, y: 0, width: 100, height: 50)
        #expect(full.pixelRect(in: size) == expectedFull)
    }

    @Test("Tiny normalized selections still resolve to at least one pixel")
    func minimumPixelSelection() throws {
        let size = try PixelSize(width: 100, height: 100)
        let rect = try NormalizedRect(x: 0.5, y: 0.5, width: 0.00001, height: 0.00001)
        #expect(rect.pixelRect(in: size).width == 1)
        #expect(rect.pixelRect(in: size).height == 1)
    }

    @Test("Selection rejects resolution against a different display")
    func displayMismatch() throws {
        let selection = try makeSelection(displayID: "display-1")
        let display = try makeDisplay(id: "display-2")
        #expect(throws: CaptureGeometryError.displayMismatch(
            expected: try makeDisplayID("display-1"),
            actual: try makeDisplayID("display-2")
        )) {
            try selection.pixelRect(on: display)
        }
    }

    @Test("Last Area uses its original display when still connected")
    func originalLastArea() throws {
        let selection = try makeSelection(displayID: "external")
        let main = try makeDisplay(id: "main", isMain: true)
        let external = try makeDisplay(id: "external", width: 1920, height: 1080, isMain: false)
        let result = try #require(LastAreaResolver.resolve(selection, among: [main, external]))

        #expect(result.kind == .originalDisplay)
        #expect(!result.didFallback)
        #expect(result.selection == selection)
        #expect(result.display == external)
    }

    @Test("Missing Last Area display moves normalized geometry to the main display")
    func mainDisplayFallback() throws {
        let selection = try makeSelection(displayID: "missing", x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let secondary = try makeDisplay(id: "secondary", isMain: false)
        let main = try makeDisplay(id: "main", width: 2000, height: 1000, isMain: true)
        let result = try #require(LastAreaResolver.resolve(selection, among: [secondary, main]))

        #expect(result.kind == .fallbackToMainDisplay)
        #expect(result.didFallback)
        #expect(result.selection.displayID == main.id)
        #expect(result.selection.normalizedRect == selection.normalizedRect)
        let expectedPixels = try PixelRect(x: 500, y: 250, width: 1000, height: 500)
        #expect(result.pixelRect == expectedPixels)
    }

    @Test("Resolver falls back deterministically and handles no displays")
    func fallbackWithoutMainDisplay() throws {
        let selection = try makeSelection(displayID: "missing")
        let first = try makeDisplay(id: "first", isMain: false)
        let second = try makeDisplay(id: "second", isMain: false)
        let result = try #require(LastAreaResolver.resolve(selection, among: [first, second]))
        #expect(result.kind == .fallbackToFirstAvailableDisplay)
        #expect(result.display == first)
        #expect(LastAreaResolver.resolve(selection, among: []) == nil)
    }

    @Test("Capture targets use an explicit stable JSON discriminator")
    func targetRoundTrip() throws {
        let region = CaptureTarget.region(try makeSelection())
        let displayID = try makeDisplayID()
        let fullscreen = CaptureTarget.fullscreen(displayID)
        let application = CaptureTarget.application(
            try ApplicationCaptureTarget(
                displayID: displayID,
                bundleIdentifier: " com.apple.Safari ",
                applicationName: " Safari "
            )
        )
        #expect(try jsonRoundTrip(region) == region)
        #expect(try jsonRoundTrip(fullscreen) == fullscreen)
        #expect(try jsonRoundTrip(application) == application)
        #expect(region.displayID == displayID)
        #expect(fullscreen.displayID == displayID)
        #expect(application.displayID == displayID)
        guard case let .application(target) = application else {
            Issue.record("Expected an application target")
            return
        }
        #expect(target.bundleIdentifier == "com.apple.Safari")
        #expect(target.applicationName == "Safari")
    }

    @Test("Application targets reject identities that cannot be resolved for Retake")
    func applicationTargetValidation() throws {
        let displayID = try makeDisplayID()
        #expect(throws: ApplicationCaptureTargetError.emptyBundleIdentifier) {
            try ApplicationCaptureTarget(
                displayID: displayID,
                bundleIdentifier: "  ",
                applicationName: "Safari"
            )
        }
        #expect(throws: ApplicationCaptureTargetError.emptyApplicationName) {
            try ApplicationCaptureTarget(
                displayID: displayID,
                bundleIdentifier: "com.apple.Safari",
                applicationName: "\n"
            )
        }

        let corrupt = Data(
            #"{"kind":"application","application":{"displayID":"main","bundleIdentifier":"","applicationName":"Safari"}}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CaptureTarget.self, from: corrupt)
        }
    }

    @Test("Geometry value decoding revalidates invariants")
    func corruptGeometryJSON() {
        let invalidSize = Data(#"{"width":0,"height":900}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PixelSize.self, from: invalidSize)
        }

        let invalidRect = Data(#"{"x":0.9,"y":0,"width":0.5,"height":1}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NormalizedRect.self, from: invalidRect)
        }
    }

    @Test("Display IDs trim whitespace and reject empty values")
    func displayIDValidation() throws {
        #expect(try DisplayID("  display  ").rawValue == "display")
        #expect(throws: CaptureGeometryError.emptyDisplayIdentifier) {
            try DisplayID(" \n ")
        }
    }
}
