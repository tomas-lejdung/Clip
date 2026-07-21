import CoreGraphics
import Testing
@testable import ClipCapture

@Suite("Shareable capture discovery policy")
struct CaptureDiscoveryTests {
    @Test("capture point dimensions default to rounded frame dimensions")
    func defaultCapturePointDimensions() {
        let fixture = window(
            id: 1,
            processID: 44,
            title: "Document",
            frame: CGRect(x: 10, y: 10, width: 800.4, height: 600.6)
        )

        #expect(fixture.capturePointWidth == 800)
        #expect(fixture.capturePointHeight == 601)
    }

    @Test("capture point dimensions retain the capture filter content size")
    func explicitCapturePointDimensions() {
        let fixture = ShareableCaptureWindow(
            id: 1,
            frame: CGRect(x: 10, y: 10, width: 800, height: 600),
            title: "Document",
            applicationName: "Fixture",
            bundleIdentifier: "example.fixture",
            processID: 44,
            capturePointWidth: 824,
            capturePointHeight: 624,
            pixelWidth: 1_648,
            pixelHeight: 1_248
        )

        #expect(fixture.capturePointWidth == 824)
        #expect(fixture.capturePointHeight == 624)
        #expect(fixture.pixelWidth == 1_648)
        #expect(fixture.pixelHeight == 1_248)
    }

    @Test("focused selection chooses the frontmost application's first ordered window")
    func focusedSelection() {
        let back = window(id: 2, processID: 44, title: "Back")
        let front = window(id: 1, processID: 44, title: "Front")
        let unrelated = window(id: 3, processID: 99, title: "Other")

        #expect(FocusedWindowSelection.eligibleWindow(
            frontmostProcessID: 44,
            orderedWindows: [unrelated, front, back]
        )?.id == 1)
    }

    @Test("no frontmost process has no overlay target")
    func noTarget() {
        #expect(FocusedWindowSelection.eligibleWindow(
            frontmostProcessID: nil,
            orderedWindows: [window(id: 1, processID: 1, title: "One")]
        ) == nil)
    }

    @Test("focused selection skips transient undersized windows")
    func minimumFocusedWindowSize() {
        let tiny = window(
            id: 1,
            processID: 44,
            title: "Transient",
            frame: CGRect(x: 10, y: 10, width: 80, height: 80)
        )
        let document = window(id: 2, processID: 44, title: "Document")
        #expect(FocusedWindowSelection.eligibleWindow(
            frontmostProcessID: 44,
            orderedWindows: [tiny, document],
            minimumPointSize: CGSize(width: 100, height: 100)
        )?.id == 2)
    }

    @Test("focused selection skips untitled popups and confirmation surfaces")
    func untitledTransientWindows() {
        let popup = window(id: 1, processID: 44, title: "")
        let confirmation = window(id: 2, processID: 44, title: "  \n\t")
        let document = window(id: 3, processID: 44, title: "Document")

        #expect(FocusedWindowSelection.eligibleWindow(
            frontmostProcessID: 44,
            orderedWindows: [popup, confirmation, document],
            minimumPointSize: CGSize(width: 100, height: 100)
        )?.id == document.id)
    }

    @Test("focused selection has no target when only transient windows remain")
    func onlyTransientWindows() {
        let popup = window(id: 1, processID: 44, title: "")
        let confirmation = window(id: 2, processID: 44, title: "   ")

        #expect(FocusedWindowSelection.eligibleWindow(
            frontmostProcessID: 44,
            orderedWindows: [popup, confirmation],
            minimumPointSize: CGSize(width: 100, height: 100)
        ) == nil)
    }

    private func window(
        id: CGWindowID,
        processID: pid_t,
        title: String,
        frame: CGRect = CGRect(x: 10, y: 10, width: 800, height: 600)
    ) -> ShareableCaptureWindow {
        ShareableCaptureWindow(
            id: id,
            frame: frame,
            title: title,
            applicationName: "Fixture",
            bundleIdentifier: "example.fixture",
            processID: processID,
            pixelWidth: 1_600,
            pixelHeight: 1_200
        )
    }
}
