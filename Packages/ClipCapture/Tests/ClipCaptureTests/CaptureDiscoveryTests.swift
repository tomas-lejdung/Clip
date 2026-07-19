import CoreGraphics
import Testing
@testable import ClipCapture

@Suite("Shareable capture discovery policy")
struct CaptureDiscoveryTests {
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
