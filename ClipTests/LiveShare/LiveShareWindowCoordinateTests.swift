import AppKit
import ClipCapture
import CoreGraphics
import Testing
@testable import Clip

@Suite("Live Share window coordinate conversion")
struct LiveShareWindowCoordinateTests {
    @Test("Quartz top-left coordinates become AppKit bottom-left coordinates")
    func primaryDisplay() {
        let result = LiveShareWindowCoordinateConversion.appKitFrame(
            for: CGRect(x: 100, y: 50, width: 800, height: 600),
            quartzDisplayFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            appKitDisplayFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        )
        #expect(result == CGRect(x: 100, y: 430, width: 800, height: 600))
    }

    @Test("secondary display origins are preserved")
    func secondaryDisplay() {
        let result = LiveShareWindowCoordinateConversion.appKitFrame(
            for: CGRect(x: 2_000, y: 200, width: 500, height: 400),
            quartzDisplayFrame: CGRect(x: 1_920, y: 100, width: 1_280, height: 1_024),
            appKitDisplayFrame: CGRect(x: 1_920, y: -100, width: 1_280, height: 1_024)
        )
        #expect(result == CGRect(x: 2_000, y: 424, width: 500, height: 400))
    }

    @Test("stale focused-window discovery cannot republish after Stop then Start")
    @MainActor
    func staleDiscoveryCannotReplaceNewMonitorGeneration() async throws {
        let processID = pid_t(4_242)
        let displayID = CGMainDisplayID()
        let displayFrame = CGDisplayBounds(displayID)
        let firstWindow = Self.window(
            id: 71,
            processID: processID,
            frame: displayFrame.insetBy(dx: 80, dy: 80),
            title: "Stale"
        )
        let replacementWindow = Self.window(
            id: 72,
            processID: processID,
            frame: displayFrame.insetBy(dx: 120, dy: 120),
            title: "Replacement"
        )
        let discovery = SuspendedFocusedWindowDiscovery(
            first: ShareableCaptureContent(displays: [], windows: [firstWindow]),
            replacement: ShareableCaptureContent(displays: [], windows: [replacementWindow])
        )
        let recorder = FocusedWindowRecorder()
        let monitor = LiveShareFocusedWindowMonitor(
            discovery: discovery,
            excludedBundleIdentifier: nil,
            frontmostProcessID: { processID },
            handler: { value in recorder.append(value) }
        )

        monitor.start()
        await discovery.waitForFirstRequest()
        monitor.stop()
        monitor.start()

        try await eventuallyFocusedWindow {
            recorder.lastWindowID == replacementWindow.id
        }
        await discovery.releaseFirstRequest()
        try await Task.sleep(for: .milliseconds(50))

        #expect(recorder.nonNilWindowIDs == [replacementWindow.id])
        monitor.stop()
    }

    @Test("focused monitor skips a large untitled popup before the document window")
    @MainActor
    func focusedMonitorSkipsUntitledPopup() async throws {
        let processID = pid_t(4_242)
        let displayFrame = CGDisplayBounds(CGMainDisplayID())
        let popup = Self.window(
            id: 81,
            processID: processID,
            frame: displayFrame.insetBy(dx: 20, dy: 20),
            title: ""
        )
        let document = Self.window(
            id: 82,
            processID: processID,
            frame: displayFrame.insetBy(dx: 80, dy: 80),
            title: "Document"
        )
        let content = ShareableCaptureContent(
            displays: [],
            windows: [popup, document]
        )
        let discovery = SuspendedFocusedWindowDiscovery(
            first: content,
            replacement: content
        )
        let recorder = FocusedWindowRecorder()
        let monitor = LiveShareFocusedWindowMonitor(
            discovery: discovery,
            excludedBundleIdentifier: nil,
            frontmostProcessID: { processID },
            handler: { value in recorder.append(value) }
        )

        monitor.start()
        await discovery.waitForFirstRequest()
        await discovery.releaseFirstRequest()

        try await eventuallyFocusedWindow {
            recorder.lastWindowID == document.id
        }
        #expect(recorder.nonNilWindowIDs == [document.id])
        monitor.stop()
    }

    private static func window(
        id: CGWindowID,
        processID: pid_t,
        frame: CGRect,
        title: String
    ) -> ShareableCaptureWindow {
        ShareableCaptureWindow(
            id: id,
            frame: frame,
            title: title,
            applicationName: "Fixture",
            bundleIdentifier: "com.example.fixture",
            processID: processID,
            pixelWidth: Int(frame.width),
            pixelHeight: Int(frame.height)
        )
    }
}

@MainActor
private final class FocusedWindowRecorder {
    private var values: [FocusedLiveShareWindow?] = []

    var lastWindowID: CGWindowID? { (values.last ?? nil)?.window.id }
    var nonNilWindowIDs: [CGWindowID] { values.compactMap { $0?.window.id } }

    func append(_ value: FocusedLiveShareWindow?) {
        values.append(value)
    }
}

private actor SuspendedFocusedWindowDiscovery: CaptureContentDiscovering {
    private let first: ShareableCaptureContent
    private let replacement: ShareableCaptureContent
    private var requestCount = 0
    private var firstRequestArrived = false
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?

    init(first: ShareableCaptureContent, replacement: ShareableCaptureContent) {
        self.first = first
        self.replacement = replacement
    }

    func shareableContent(
        excludingBundleIdentifier: String?
    ) async throws -> ShareableCaptureContent {
        _ = excludingBundleIdentifier
        requestCount += 1
        guard requestCount == 1 else { return replacement }
        firstRequestArrived = true
        let waiters = firstRequestWaiters
        firstRequestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            firstRequestContinuation = continuation
        }
        return first
    }

    func waitForFirstRequest() async {
        guard !firstRequestArrived else { return }
        await withCheckedContinuation { continuation in
            firstRequestWaiters.append(continuation)
        }
    }

    func releaseFirstRequest() {
        firstRequestContinuation?.resume()
        firstRequestContinuation = nil
    }
}

@MainActor
private func eventuallyFocusedWindow(
    _ predicate: () -> Bool
) async throws {
    for _ in 0..<100 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for the replacement focused window")
}
