import XCTest

final class ClipLaunchTests: XCTestCase {
    private struct HelperStatusReport: Decodable {
        let protocolVersion: Int
        let service: String
        let status: String
    }

    private struct SelfTestReport: Decodable {
        let protocolVersion: Int
        let success: Bool
        let generatedMP4WasValid: Bool
        let invalidPayloadWasRejected: Bool
        let localPasteboardResolvedFileURL: Bool
        let failure: String?
    }

    private struct MP4Report: Decodable {
        struct AudioTrack: Decodable {
            let trackIndex: Int
            let durationSeconds: Double
            let estimatedDataRate: Double
            let sampleCount: Int64
            let peakAmplitude: Double
            let rmsAmplitude: Double
        }

        let valid: Bool
        let fileURL: String
        let durationSeconds: Double
        let videoTrackCount: Int
        let audioTrackCount: Int
        let audioDurationSeconds: Double
        let audioEstimatedDataRate: Double
        let audioSampleCount: Int64
        let audioPeakAmplitude: Double
        let audioRMSAmplitude: Double
        let audioTracks: [AudioTrack]
        let width: Int
        let height: Int
        let nominalFramesPerSecond: Double
        let videoCodec: String?
        let decodedVideoFrameCount: Int
        let deterministicFixtureFrameCount: Int
        let deterministicFixtureColorFamilyCount: Int
        let fileSizeBytes: Int64
        let failure: String?
    }

    private struct FixtureReadyReport: Decodable {
        let protocolVersion: Int
        let status: String
        let dropReceiverAccessibilityIdentifier: String
        let dropPointX: Double
        let dropPointY: Double
        let capturePointX: Double
        let capturePointY: Double
        let captureAreaStartX: Double
        let captureAreaStartY: Double
        let captureAreaEndX: Double
        let captureAreaEndY: Double
        let captureAreaExpectedWidthPixels: Int
        let captureAreaExpectedHeightPixels: Int
        let displayExpectedWidthPixels: Int
        let displayExpectedHeightPixels: Int
        let toneActive: Bool
        let failure: String?
    }

    private struct CommandResult {
        let status: Int32
        let standardOutput: Data
        let standardError: Data
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMenuBarAgentLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let deadline = Date().addingTimeInterval(5)
        while app.state == .notRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertNotEqual(app.state, .notRunning)
        app.terminate()
    }

    /// Renders the production Live Share popover against fixed snapshots. These scenarios are
    /// isolated from app state and deliberately have no coordinator, signaling, capture, WebRTC,
    /// permission, or pointer-control path behind their inert controls.
    @MainActor
    func testDeterministicLiveSharePopoverStatesWithoutPrivacyPrompts() throws {
        try assertLiveShareScenario(
            "live-share-ready",
            statusLabel: "Ready to share",
            visibleIdentifiers: [
                "clip.liveShare.copyLink",
                "clip.liveShare.copyRoomCode",
                "clip.liveShare.fullscreen",
                "clip.liveShare.addWindow",
            ]
        )
        try assertLiveShareScenario(
            "live-share-live",
            statusLabel: "Live · 01:34",
            visibleIdentifiers: [
                "clip.liveShare.copyLink",
                "clip.liveShare.accessCode.copy",
                "clip.liveShare.stopAll",
            ]
        )
        try assertLiveShareScenario(
            "live-share-reconnecting",
            statusLabel: "Reconnecting 2/5…",
            visibleIdentifiers: [
                "clip.liveShare.stopAll",
                "clip.liveShare.stopSession",
            ]
        )
        try assertLiveShareScenario(
            "live-share-failed",
            statusLabel: "The signaling service is unavailable.",
            visibleIdentifiers: [
                "clip.liveShare.retry",
                "clip.liveShare.stopSession",
            ]
        )
    }

    /// The companion bottom scenario scrolls through AppKit after layout instead of synthesizing
    /// a gesture, so the lower half of the production LazyVStack is covered without moving the
    /// user's cursor.
    @MainActor
    func testDeterministicLiveSharePopoverBottomWithoutPointerControl() throws {
        let app = launchDeterministicScenario("live-share-live-bottom")
        defer { app.terminate() }

        let root = app.descendants(matching: .any)
            .matching(identifier: "clip.uiScenario.live-share-live-bottom")
            .firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 10))

        let statistics = app.descendants(matching: .any)
            .matching(identifier: "clip.liveShare.statistics")
            .firstMatch
        XCTAssertTrue(statistics.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForHittable(statistics, timeout: 5),
            "The deterministic bottom scenario did not expose the lower Live Share content."
        )
        XCTAssertEqual(
            accessibilityValue(of: statistics),
            "1",
            "The deterministic bottom scenario did not expand Statistics."
        )
        let uptime = app.staticTexts
            .matching(NSPredicate(format: "value == %@", "Uptime 01:34"))
            .firstMatch
        XCTAssertTrue(uptime.waitForExistence(timeout: 5))
        let finalStream = app.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@", "Keynote · Product roadmap"))
            .firstMatch
        XCTAssertTrue(
            finalStream.waitForExistence(timeout: 5),
            "The expanded fixture did not render its final stream statistics row."
        )
        attachScenarioScreenshot(app: app, name: "Live Share — live — bottom")
    }

    @MainActor
    func testDeterministicLiveShareOverlayAndHUDStatesWithoutPointerControl() throws {
        let app = launchDeterministicScenario("live-share-overlays")
        defer { app.terminate() }

        for identifier in [
            "clip.liveShare.fixture.focused.shareable",
            "clip.liveShare.fixture.focused.live",
            "clip.liveShare.fixture.hud.windows",
            "clip.liveShare.fixture.hud.fullscreen",
        ] {
            let element = app.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
            XCTAssertTrue(
                element.waitForExistence(timeout: 10),
                "Missing deterministic overlay fixture \(identifier)."
            )
        }

        let primaryControls = app.descendants(matching: .any)
            .matching(identifier: "clip.liveShare.focusedWindow.primary")
        XCTAssertEqual(primaryControls.count, 2)
        attachScenarioScreenshot(app: app, name: "Live Share — overlays and HUD")
    }

    @MainActor
    func testDeterministicHelperAcceptanceWithoutPrivacyPrompts() throws {
        let helperURL = try helperExecutableURL()
        let statusResult = try run(helperURL, arguments: ["--status"])
        XCTAssertEqual(statusResult.status, 0, diagnostic(for: statusResult))
        let status = try JSONDecoder().decode(
            HelperStatusReport.self,
            from: statusResult.standardOutput
        )
        XCTAssertEqual(status.protocolVersion, 2)
        XCTAssertEqual(status.service, "ClipTestHelper")
        XCTAssertEqual(status.status, "ready")

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-ui-acceptance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let selfTestResult = try run(helperURL, arguments: [
            "--self-test",
            "--work-directory",
            workDirectory.path,
        ])
        XCTAssertEqual(selfTestResult.status, 0, diagnostic(for: selfTestResult))
        let report = try JSONDecoder().decode(
            SelfTestReport.self,
            from: selfTestResult.standardOutput
        )
        XCTAssertEqual(report.protocolVersion, 2)
        XCTAssertTrue(report.success, report.failure ?? "Self-test reported failure.")
        XCTAssertTrue(report.generatedMP4WasValid)
        XCTAssertTrue(report.invalidPayloadWasRejected)
        XCTAssertTrue(report.localPasteboardResolvedFileURL)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workDirectory.appendingPathComponent("fixture.png").path
            )
        )
    }

    /// This test is intentionally dormant during every normal test command.
    /// `scripts/run-real-capture-acceptance.sh --allow-permission-prompts-and-pointer-control` is
    /// the only repository script that opts in. After macOS access has been
    /// granted once, the flow is otherwise unattended and validates trim,
    /// promised-file drag, and Copy using our local helper instead of pasting
    /// into Messages, Slack, or another app.
    @MainActor
    func testRealScreenCaptureCopyRoundTripWhenExplicitlyEnabled() throws {
        #if !CLIP_REAL_CAPTURE_ACCEPTANCE
        throw XCTSkip("Real ScreenCaptureKit acceptance is opt-in and permission-gated.")
        #else

        let helperURL = try helperExecutableURL()
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-real-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        let fixtureReadyURL = workDirectory.appendingPathComponent("fixture-ready.json")
        let dropResultURL = workDirectory.appendingPathComponent("drop-result.json")
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let fixture = Process()
        fixture.executableURL = helperURL
        fixture.arguments = [
            "--fixture",
            "--ready-file", fixtureReadyURL.path,
            "--result-file", dropResultURL.path,
            "--quit-after", "120",
        ]
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning {
                fixture.terminate()
                fixture.waitUntilExit()
            }
        }
        let fixtureReady = try waitForJSON(
            FixtureReadyReport.self,
            at: fixtureReadyURL,
            timeout: 10
        )
        XCTAssertEqual(fixtureReady.protocolVersion, 2)
        XCTAssertEqual(fixtureReady.status, "ready")
        XCTAssertEqual(
            fixtureReady.dropReceiverAccessibilityIdentifier,
            "clip.acceptance.dropReceiver"
        )

        let isolatedStateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clip-UI-Testing", isDirectory: true)
            .appendingPathComponent("real-capture-acceptance", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--real-capture-acceptance"]
        app.launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: isolatedStateRoot)
        }

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "Clip's status item did not appear.")
        let statusFrame = statusItem.frame
        let statusOrigin = statusItem.coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 0)
        )
        statusItem.click()

        let captureArea = app.buttons["clip.menu.captureArea"]
        XCTAssertTrue(captureArea.waitForExistence(timeout: 5))
        captureArea.click()

        let continuePermission = app.dialogs.firstMatch.buttons["Continue"].firstMatch
        if continuePermission.waitForExistence(timeout: 2) {
            continuePermission.click()
        }

        // Exercise the actual Capture Area gesture around the deterministic
        // fixture. The helper publishes global XCTest coordinates and backing-
        // pixel dimensions, avoiding assumptions about display scale or menu-
        // bar placement.
        runMainLoop(for: 2)
        let selectionStart = statusOrigin.withOffset(CGVector(
            dx: CGFloat(fixtureReady.captureAreaStartX) - statusFrame.minX,
            dy: CGFloat(fixtureReady.captureAreaStartY) - statusFrame.minY
        ))
        let selectionEnd = statusOrigin.withOffset(CGVector(
            dx: CGFloat(fixtureReady.captureAreaEndX) - statusFrame.minX,
            dy: CGFloat(fixtureReady.captureAreaEndY) - statusFrame.minY
        ))
        selectionStart.click(forDuration: 0.25, thenDragTo: selectionEnd)

        let dimensions = app.staticTexts["clip.capture.dimensions"]
        XCTAssertTrue(
            dimensions.waitForExistence(timeout: 8),
            "Capture Area did not expose the selected dimensions."
        )
        let selectedDimensions = try XCTUnwrap(
            pixelDimensions(
                dimensions.label.isEmpty
                    ? accessibilityValue(of: dimensions)
                    : dimensions.label
            ),
            "Capture Area published an unreadable dimensions label."
        )
        XCTAssertLessThanOrEqual(
            abs(selectedDimensions.width - fixtureReady.captureAreaExpectedWidthPixels),
            4,
            "The pointer drag did not select the fixture's expected width."
        )
        XCTAssertLessThanOrEqual(
            abs(selectedDimensions.height - fixtureReady.captureAreaExpectedHeightPixels),
            4,
            "The pointer drag did not select the fixture's expected height."
        )

        let recordArea = app.buttons["clip.capture.record"]
        XCTAssertTrue(recordArea.waitForExistence(timeout: 8))
        recordArea.click()
        runMainLoop(for: 6)

        statusItem.click()
        let pauseResume = app.buttons["clip.recording.pauseResume"]
        XCTAssertTrue(
            pauseResume.waitForExistence(timeout: 12),
            "Pause did not become available after Clip received its first frame."
        )
        pauseResume.click()
        XCTAssertTrue(
            waitForLabel("Resume", on: pauseResume, timeout: 5),
            "Resume did not become available after pausing."
        )
        pauseResume.click()
        XCTAssertTrue(
            waitForLabel("Pause", on: pauseResume, timeout: 5),
            "Pause did not become available after resuming."
        )
        runMainLoop(for: 2)

        let finish = app.buttons["clip.recording.finish"]
        XCTAssertTrue(
            finish.waitForExistence(timeout: 12),
            "Recording controls did not appear. Confirm Screen Recording access and relaunch Clip."
        )
        finish.click()

        let expectedFilename = "acceptance-copy-roundtrip.mp4"
        let filename = app.textFields["clip.preview.filename"]
        XCTAssertTrue(filename.waitForExistence(timeout: 30), "Preview filename was not editable.")

        // Validate Clip's unexported managed master before trimming or sharing.
        // This proves that the selected area dimensions reached ScreenCaptureKit
        // and that actual decoded pixels contain the deterministic fixture.
        let managedMasterURL = try waitForSingleManagedMP4(
            in: isolatedStateRoot,
            timeout: 10
        )
        let masterValidationResult = try run(
            helperURL,
            arguments: ["--validate-mp4", managedMasterURL.path]
        )
        XCTAssertEqual(
            masterValidationResult.status,
            0,
            diagnostic(for: masterValidationResult)
        )
        let masterReport = try JSONDecoder().decode(
            MP4Report.self,
            from: masterValidationResult.standardOutput
        )
        XCTAssertTrue(masterReport.valid, masterReport.failure ?? "Managed master was rejected.")
        XCTAssertEqual(masterReport.videoTrackCount, 1)
        XCTAssertEqual(
            masterReport.width,
            selectedDimensions.width - (selectedDimensions.width % 2)
        )
        XCTAssertEqual(
            masterReport.height,
            selectedDimensions.height - (selectedDimensions.height % 2)
        )
        XCTAssertEqual(masterReport.videoCodec, "avc1")
        XCTAssertGreaterThan(masterReport.decodedVideoFrameCount, 0)
        XCTAssertGreaterThan(
            masterReport.deterministicFixtureFrameCount,
            0,
            "Decoded managed-master pixels did not match the deterministic fixture."
        )
        XCTAssertGreaterThanOrEqual(
            masterReport.deterministicFixtureColorFamilyCount,
            6,
            "The managed master did not retain the fixture's calibration colors."
        )

        filename.click()
        filename.typeKey("a", modifierFlags: .command)
        filename.typeText(expectedFilename)

        // Exercise the real SwiftUI trim gesture through the handles' existing
        // accessibility labels. Moving the start handle far enough to cross a
        // whole-second boundary makes the non-default trim observable without
        // relying on private app state.
        let timeline = element(labeled: "Video timeline", in: app)
        let trimStart = element(labeled: "Trim start", in: app)
        let trimEnd = element(labeled: "Trim end", in: app)
        XCTAssertTrue(timeline.waitForExistence(timeout: 10), "Preview timeline was not accessible.")
        XCTAssertTrue(trimStart.waitForExistence(timeout: 10), "Trim start was not accessible.")
        XCTAssertTrue(trimEnd.waitForExistence(timeout: 10), "Trim end was not accessible.")

        let initialTrimStartValue = accessibilityValue(of: trimStart)
        let originalDuration = try XCTUnwrap(timecodeSeconds(accessibilityValue(of: trimEnd)))
        XCTAssertGreaterThan(originalDuration, 1)

        let startCoordinate = trimStart.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let trimDistance = min(max(timeline.frame.width * 0.42, 140), 320)
        startCoordinate.click(
            forDuration: 0.35,
            thenDragTo: startCoordinate.withOffset(CGVector(dx: trimDistance, dy: 0))
        )
        XCTAssertTrue(
            waitForValueChange(on: trimStart, from: initialTrimStartValue, timeout: 8),
            "Dragging the accessible trim-start handle did not change its value."
        )
        let editedTrimStart = try XCTUnwrap(timecodeSeconds(accessibilityValue(of: trimStart)))
        XCTAssertGreaterThan(
            editedTrimStart,
            0,
            "The real acceptance lane must export a non-default trim."
        )

        // Drag the top video surface into the helper's local receiver. The
        // helper publishes the receiver's exact screen point atomically, and
        // writes a second report only after AVFoundation validates the dropped
        // promised MP4.
        let dragHint = app.staticTexts["Drag video to share"]
        XCTAssertTrue(dragHint.waitForExistence(timeout: 10), "Preview drag source was not visible.")
        let previewWindow = try XCTUnwrap(
            app.windows.allElementsBoundByIndex.first(where: { window in
                window.frame.contains(CGPoint(x: filename.frame.midX, y: filename.frame.midY))
            }),
            "Could not locate the Preview window containing the filename field."
        )
        let sourceCoordinate = dragHint.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).withOffset(CGVector(
            dx: -min(220, previewWindow.frame.width * 0.25),
            dy: -24
        ))
        let previewOrigin = previewWindow.coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 0)
        )
        let dropCoordinate = previewOrigin.withOffset(CGVector(
            dx: CGFloat(fixtureReady.dropPointX) - previewWindow.frame.minX,
            dy: CGFloat(fixtureReady.dropPointY) - previewWindow.frame.minY
        ))
        sourceCoordinate.click(forDuration: 0.8, thenDragTo: dropCoordinate)

        let droppedReport = try waitForJSON(
            MP4Report.self,
            at: dropResultURL,
            timeout: 45
        )
        XCTAssertTrue(droppedReport.valid, droppedReport.failure ?? "Dropped MP4 was rejected.")
        XCTAssertEqual(URL(string: droppedReport.fileURL)?.lastPathComponent, expectedFilename)
        XCTAssertGreaterThan(droppedReport.durationSeconds, 0)
        XCTAssertLessThan(
            droppedReport.durationSeconds,
            originalDuration,
            "The dropped MP4 did not reflect the non-default trim."
        )
        XCTAssertGreaterThanOrEqual(droppedReport.videoTrackCount, 1)
        XCTAssertGreaterThan(droppedReport.decodedVideoFrameCount, 0)
        XCTAssertGreaterThan(
            droppedReport.deterministicFixtureFrameCount,
            0,
            "The shared export no longer contained decoded fixture evidence."
        )
        XCTAssertGreaterThanOrEqual(
            droppedReport.deterministicFixtureColorFamilyCount,
            6
        )
        XCTAssertGreaterThan(droppedReport.fileSizeBytes, 0)

        app.activate()

        let copy = app.buttons["clip.preview.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 30), "Clip did not finish and show Preview.")
        copy.click()
        runMainLoop(for: 1)

        let validationResult = try run(helperURL, arguments: ["--validate-pasteboard"])
        XCTAssertEqual(validationResult.status, 0, diagnostic(for: validationResult))
        let report = try JSONDecoder().decode(
            MP4Report.self,
            from: validationResult.standardOutput
        )
        XCTAssertTrue(report.valid, report.failure ?? "Copied MP4 was rejected.")
        XCTAssertEqual(URL(string: report.fileURL)?.lastPathComponent, expectedFilename)
        XCTAssertGreaterThan(report.durationSeconds, 0)
        XCTAssertGreaterThanOrEqual(report.videoTrackCount, 1)
        XCTAssertGreaterThan(report.decodedVideoFrameCount, 0)
        XCTAssertGreaterThan(report.deterministicFixtureFrameCount, 0)
        XCTAssertGreaterThan(report.fileSizeBytes, 0)
        XCTAssertEqual(
            report.durationSeconds,
            droppedReport.durationSeconds,
            accuracy: 0.25,
            "Drag and explicit Copy should export the same edited trim."
        )

        // Copy persists the current Preview edits. Verify the renamed recording
        // appears in local History whether Preview remained open or the user's
        // auto-close-after-Copy setting closed it.
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 2) {
            done.click()
            _ = waitForDisappearance(done, timeout: 10)
        }
        statusItem.click()
        let history = app.buttons["clip.menu.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.click()
        XCTAssertTrue(
            app.staticTexts[expectedFilename].waitForExistence(timeout: 10),
            "The copied recording and edited filename were not persisted to History."
        )
        #endif
    }

    /// Opt-in end-to-end owner acceptance for the ordinary Fullscreen path.
    /// The recording contains the local animated ClipTestHelper fixture, uses
    /// isolated settings/storage, and leaves a human-readable validation report
    /// plus a Preview screenshot in the xcresult bundle.
    @MainActor
    func testRealFullscreenCapturePreviewFlowWhenExplicitlyEnabled() throws {
        #if !CLIP_REAL_CAPTURE_ACCEPTANCE
        throw XCTSkip("Real fullscreen ScreenCaptureKit acceptance is opt-in and permission-gated.")
        #else
        let helperURL = try helperExecutableURL()
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-fullscreen-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        let fixtureReadyURL = workDirectory.appendingPathComponent("fixture-ready.json")
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let fixture = Process()
        fixture.executableURL = helperURL
        fixture.arguments = [
            "--fixture",
            "--ready-file", fixtureReadyURL.path,
            "--quit-after", "90",
        ]
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning {
                fixture.terminate()
                fixture.waitUntilExit()
            }
        }

        let fixtureReady = try waitForJSON(
            FixtureReadyReport.self,
            at: fixtureReadyURL,
            timeout: 10
        )
        XCTAssertEqual(fixtureReady.protocolVersion, 2)
        XCTAssertEqual(
            fixtureReady.status,
            "ready",
            fixtureReady.failure ?? "The harmless animated fixture did not become ready."
        )

        let stateIdentifier = "fullscreen-flow"
        let isolationIdentifier = "real-capture-\(stateIdentifier)"
        let isolatedStateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clip-UI-Testing", isDirectory: true)
            .appendingPathComponent(isolationIdentifier, isDirectory: true)
        let defaultsSuiteName = "com.tomaslejdung.clip.ui-testing.\(isolationIdentifier)"

        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--real-capture-acceptance",
            "--real-capture-state-id=\(stateIdentifier)",
            "--real-capture-frame-rate=30",
            "--real-capture-cursor=off",
        ]
        app.launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: isolatedStateRoot)
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "Clip's status item did not appear.")
        statusItem.click()

        let fullscreen = app.buttons["clip.menu.fullscreen"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 8), "Fullscreen was not available.")
        fullscreen.click()

        let continuePermission = app.dialogs.firstMatch.buttons["Continue"].firstMatch
        if continuePermission.waitForExistence(timeout: 2) {
            continuePermission.click()
        }

        let dimensions = app.staticTexts["clip.capture.dimensions"]
        XCTAssertTrue(
            dimensions.waitForExistence(timeout: 10),
            "Fullscreen selection did not expose the selected display dimensions."
        )
        let dimensionsDescription = dimensions.label.isEmpty
            ? accessibilityValue(of: dimensions)
            : dimensions.label
        let selectedDimensions = try XCTUnwrap(
            pixelDimensions(dimensionsDescription.components(separatedBy: "•").last ?? dimensionsDescription),
            "Fullscreen selection published unreadable dimensions: \(dimensionsDescription)"
        )
        XCTAssertEqual(selectedDimensions.width, fixtureReady.displayExpectedWidthPixels)
        XCTAssertEqual(selectedDimensions.height, fixtureReady.displayExpectedHeightPixels)

        let record = app.buttons["clip.capture.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "Fullscreen Record was not available.")
        record.click()

        // Includes Clip's one-second countdown followed by roughly five
        // seconds of the helper's 30 Hz animated calibration pattern.
        runMainLoop(for: 6)
        statusItem.click()
        let finish = app.buttons["clip.recording.finish"]
        XCTAssertTrue(
            finish.waitForExistence(timeout: 12),
            "Recording controls did not appear. Confirm Screen Recording access and relaunch Clip."
        )
        finish.click()

        let filename = app.textFields["clip.preview.filename"]
        XCTAssertTrue(
            filename.waitForExistence(timeout: 30),
            "Preview did not appear after the fullscreen recording stopped."
        )
        let previewVideo = app.descendants(matching: .any)
            .matching(identifier: "clip.preview.video")
            .firstMatch
        let timeline = element(labeled: "Video timeline", in: app)
        XCTAssertTrue(previewVideo.waitForExistence(timeout: 10), "Preview did not show its video surface.")
        XCTAssertTrue(timeline.waitForExistence(timeout: 10), "Preview did not show its timeline.")
        XCTAssertTrue(app.buttons["clip.preview.copy"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["clip.preview.done"].waitForExistence(timeout: 10))

        // Exercise actual AVPlayer-backed Preview playback, not merely window
        // presentation, and return it to a paused state before diagnostics.
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Preview playback control was unavailable.")
        play.click()
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "Preview did not enter playback.")
        runMainLoop(for: 1)
        if pause.exists { pause.click() }

        let managedMasterURL = try waitForSingleManagedMP4(
            in: isolatedStateRoot,
            timeout: 10
        )
        let validationResult = try run(
            helperURL,
            arguments: ["--validate-mp4", managedMasterURL.path]
        )
        XCTAssertEqual(validationResult.status, 0, diagnostic(for: validationResult))
        let report = try JSONDecoder().decode(
            MP4Report.self,
            from: validationResult.standardOutput
        )

        XCTAssertTrue(report.valid, report.failure ?? "The fullscreen managed master was rejected.")
        XCTAssertEqual(report.videoTrackCount, 1)
        XCTAssertEqual(report.audioTrackCount, 0, "The audio-disabled flow unexpectedly recorded audio.")
        XCTAssertTrue(
            ["avc1", "hvc1", "hev1"].contains(report.videoCodec ?? ""),
            "Fullscreen capture did not use a supported hardware master codec."
        )
        XCTAssertEqual(report.width, selectedDimensions.width - (selectedDimensions.width % 2))
        XCTAssertEqual(report.height, selectedDimensions.height - (selectedDimensions.height % 2))
        XCTAssertGreaterThan(report.durationSeconds, 3)
        XCTAssertLessThan(report.durationSeconds, 12)
        XCTAssertGreaterThanOrEqual(
            report.nominalFramesPerSecond,
            24,
            "The 30 FPS fullscreen master regressed to visibly sluggish cadence."
        )
        XCTAssertLessThanOrEqual(report.nominalFramesPerSecond, 31)
        XCTAssertGreaterThan(report.decodedVideoFrameCount, 0)
        XCTAssertGreaterThan(
            report.deterministicFixtureFrameCount,
            0,
            "Decoded fullscreen pixels did not contain ClipTestHelper's animated fixture."
        )
        XCTAssertGreaterThanOrEqual(
            report.deterministicFixtureColorFamilyCount,
            6,
            "The fullscreen master did not retain the fixture's calibration colors."
        )
        XCTAssertGreaterThan(report.fileSizeBytes, 0)

        let captureDescription = """
        Clip fullscreen flow passed.
        Captured content: the complete selected display containing ClipTestHelper's harmless animated checkerboard, yellow calibration border, eight color bars, moving MOTION tile, scrolling/timecode text, cursor target, and the local MP4 receiver window.
        Managed master: \(report.width)x\(report.height) \(report.videoCodec ?? "unknown codec") MP4, \(String(format: "%.3f", report.durationSeconds)) seconds, \(String(format: "%.3f", report.nominalFramesPerSecond)) nominal FPS, \(report.fileSizeBytes) bytes, \(report.videoTrackCount) video / \(report.audioTrackCount) audio tracks.
        Decoded evidence: \(report.decodedVideoFrameCount) inspected frames, \(report.deterministicFixtureFrameCount) fixture matches, \(report.deterministicFixtureColorFamilyCount) calibration color families.
        Preview: filename, video surface, timeline, playback, Copy, and Done controls were present; playback entered the playing state.
        """
        let reportAttachment = XCTAttachment(string: captureDescription)
        reportAttachment.name = "Clip Fullscreen Capture Description"
        reportAttachment.lifetime = .keepAlways
        add(reportAttachment)

        let previewWindow = try XCTUnwrap(
            app.windows.allElementsBoundByIndex.first(where: { window in
                window.frame.contains(CGPoint(x: filename.frame.midX, y: filename.frame.midY))
            }),
            "Could not locate the Preview window for screenshot diagnostics."
        )
        let screenshotAttachment = XCTAttachment(screenshot: previewWindow.screenshot())
        screenshotAttachment.name = "Clip Fullscreen Preview"
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)
        print("CLIP_FULLSCREEN_CAPTURE_DESCRIPTION\n\(captureDescription)")

        app.buttons["clip.preview.done"].click()
        XCTAssertTrue(
            waitForDisappearance(filename, timeout: 10),
            "Done did not close the completed Preview."
        )
        #endif
    }

    #if CLIP_REAL_AUDIO_ACCEPTANCE
    private enum RealAudioSource {
        case microphone
        case systemAudio
        case microphoneAndSystemAudio

        var launchArgument: String {
            switch self {
            case .microphone: "--real-capture-audio=microphone"
            case .systemAudio: "--real-capture-audio=system"
            case .microphoneAndSystemAudio: "--real-capture-audio=both"
            }
        }

        var filename: String {
            switch self {
            case .microphone: "acceptance-microphone-only.mp4"
            case .systemAudio: "acceptance-system-audio-only.mp4"
            case .microphoneAndSystemAudio: "acceptance-microphone-and-system-audio.mp4"
            }
        }

        var displayName: String {
            switch self {
            case .microphone: "microphone"
            case .systemAudio: "system audio"
            case .microphoneAndSystemAudio: "microphone and system audio"
            }
        }

        var requiresNonSilentSystemSignal: Bool {
            self == .systemAudio || self == .microphoneAndSystemAudio
        }
    }

    /// Opt-in only: this launches the real Clip app, drives the macOS pointer,
    /// and requires previously granted Screen Recording and Microphone access.
    @MainActor
    func testRealMicrophoneCaptureProducesNonemptyAudioTrack() throws {
        try assertRealAudioCapture(source: .microphone)
    }

    /// Opt-in only: Clip captures a synthetic tone emitted by ClipTestHelper,
    /// never a browser, media service, or user document.
    @MainActor
    func testRealSystemAudioCaptureProducesNonemptyAudioTrack() throws {
        try assertRealAudioCapture(source: .systemAudio)
    }

    /// Opt-in only: both requested inputs must survive export as one mixed,
    /// non-silent sharing-compatible AAC track.
    @MainActor
    func testRealMicrophoneAndSystemAudioCaptureProducesMixedAudioTrack() throws {
        try assertRealAudioCapture(source: .microphoneAndSystemAudio)
    }

    @MainActor
    private func assertRealAudioCapture(source: RealAudioSource) throws {
        let helperURL = try helperExecutableURL()
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clip-real-audio-\(source.displayName.replacingOccurrences(of: " ", with: "-"))-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        // The ordinary helper product is a command-line executable and has no
        // durable bundle identifier. Wrap that exact executable in a temporary
        // local .app so Clip's Capture App path can select/filter it without
        // falling back to a full-display recording.
        let fixtureExecutableURL = try bundledAudioFixtureExecutable(
            helperURL,
            in: workDirectory
        )

        let fixtureReadyURL = workDirectory.appendingPathComponent("fixture-ready.json")
        let dropResultURL = workDirectory.appendingPathComponent("drop-result.json")
        let fixture = Process()
        fixture.executableURL = fixtureExecutableURL
        fixture.arguments = [
            "--fixture",
            "--tone",
            "--ready-file", fixtureReadyURL.path,
            "--result-file", dropResultURL.path,
            "--quit-after", "120",
        ]
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning {
                fixture.terminate()
                fixture.waitUntilExit()
            }
        }

        let fixtureReady = try waitForJSON(
            FixtureReadyReport.self,
            at: fixtureReadyURL,
            timeout: 10
        )
        XCTAssertEqual(fixtureReady.protocolVersion, 2)
        XCTAssertEqual(
            fixtureReady.status,
            "ready",
            fixtureReady.failure ?? "The synthetic audio fixture was not ready."
        )
        XCTAssertTrue(
            fixtureReady.toneActive,
            fixtureReady.failure ?? "The synthetic acceptance tone was not active."
        )

        let isolatedStateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clip-UI-Testing", isDirectory: true)
            .appendingPathComponent("real-capture-acceptance", isDirectory: true)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--real-capture-acceptance",
            source.launchArgument,
        ]
        app.launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: isolatedStateRoot)
        }

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "Clip's status item did not appear.")
        statusItem.click()

        let captureApplication = app.buttons["clip.menu.captureApplication"]
        XCTAssertTrue(
            captureApplication.waitForExistence(timeout: 5),
            "Capture App was not available."
        )
        captureApplication.click()

        let continuePermission = app.dialogs.firstMatch.buttons["Continue"].firstMatch
        if continuePermission.waitForExistence(timeout: 2) {
            continuePermission.click()
        }

        runMainLoop(for: 2)
        let statusFrame = statusItem.frame
        let statusOrigin = statusItem.coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 0)
        )
        let fixtureCoordinate = statusOrigin.withOffset(CGVector(
            dx: CGFloat(fixtureReady.capturePointX) - statusFrame.minX,
            dy: CGFloat(fixtureReady.capturePointY) - statusFrame.minY
        ))
        fixtureCoordinate.click()

        let recordApplication = app.buttons["clip.capture.application.record"]
        XCTAssertTrue(
            recordApplication.waitForExistence(timeout: 10),
            "Clip did not select the synthetic helper application."
        )
        recordApplication.click()

        // One-second countdown plus several seconds of real ScreenCaptureKit
        // samples gives both the video and requested audio source time to write.
        runMainLoop(for: 6)
        statusItem.click()
        let finish = app.buttons["clip.recording.finish"]
        XCTAssertTrue(
            finish.waitForExistence(timeout: 12),
            "Recording controls did not appear. Grant Screen Recording and \(source.displayName) access, then relaunch Clip."
        )
        runMainLoop(for: 2)
        finish.click()

        let filename = app.textFields["clip.preview.filename"]
        XCTAssertTrue(
            filename.waitForExistence(timeout: 30),
            "Preview did not appear for the \(source.displayName) recording."
        )

        if source == .microphoneAndSystemAudio {
            // The managed master is intentionally richer than a share export:
            // ScreenCaptureKit system audio and microphone samples occupy two
            // separate tracks. Prove that both requested inputs wrote decoded
            // samples before asking the exporter to mix them into one track.
            let managedMasterURL = try waitForSingleManagedMP4(
                in: isolatedStateRoot,
                timeout: 10
            )
            let masterValidationResult = try run(
                helperURL,
                arguments: ["--validate-mp4", managedMasterURL.path]
            )
            XCTAssertEqual(
                masterValidationResult.status,
                0,
                diagnostic(for: masterValidationResult)
            )
            let masterReport = try JSONDecoder().decode(
                MP4Report.self,
                from: masterValidationResult.standardOutput
            )
            XCTAssertTrue(
                masterReport.valid,
                masterReport.failure ?? "Combined-audio managed master was rejected."
            )
            XCTAssertEqual(
                masterReport.audioTrackCount,
                2,
                "The combined managed master must retain separate system and microphone tracks."
            )
            XCTAssertEqual(masterReport.audioTracks.count, 2)
            for (expectedIndex, track) in masterReport.audioTracks.enumerated() {
                XCTAssertEqual(track.trackIndex, expectedIndex)
                XCTAssertGreaterThan(
                    track.durationSeconds,
                    0.5,
                    "Managed audio track \(expectedIndex) had no meaningful duration."
                )
                XCTAssertGreaterThan(
                    track.estimatedDataRate,
                    1_000,
                    "Managed audio track \(expectedIndex) had no encoded data."
                )
                XCTAssertGreaterThan(
                    track.sampleCount,
                    0,
                    "Managed audio track \(expectedIndex) did not decode to PCM samples."
                )
            }
            XCTAssertTrue(
                masterReport.audioTracks.contains(where: {
                    $0.peakAmplitude > 0.005 && $0.rmsAmplitude > 0.001
                }),
                "Neither managed source track contained the helper's synthetic system tone."
            )
        }

        filename.click()
        filename.typeKey("a", modifierFlags: .command)
        filename.typeText(source.filename)

        // Export through Clip's actual Preview drag provider into a local helper
        // receiver. The promised file is deleted immediately after validation.
        let dragHint = app.staticTexts["Drag video to share"]
        XCTAssertTrue(dragHint.waitForExistence(timeout: 10), "Preview drag source was not visible.")
        let previewWindow = try XCTUnwrap(
            app.windows.allElementsBoundByIndex.first(where: { window in
                window.frame.contains(CGPoint(x: filename.frame.midX, y: filename.frame.midY))
            }),
            "Could not locate the Preview window containing the filename field."
        )
        let sourceCoordinate = dragHint.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).withOffset(CGVector(
            dx: -min(220, previewWindow.frame.width * 0.25),
            dy: -24
        ))
        let previewOrigin = previewWindow.coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 0)
        )
        let dropCoordinate = previewOrigin.withOffset(CGVector(
            dx: CGFloat(fixtureReady.dropPointX) - previewWindow.frame.minX,
            dy: CGFloat(fixtureReady.dropPointY) - previewWindow.frame.minY
        ))
        sourceCoordinate.click(forDuration: 0.8, thenDragTo: dropCoordinate)

        let report = try waitForJSON(
            MP4Report.self,
            at: dropResultURL,
            timeout: 45
        )
        XCTAssertTrue(report.valid, report.failure ?? "The exported MP4 was rejected.")
        XCTAssertEqual(URL(string: report.fileURL)?.lastPathComponent, source.filename)
        XCTAssertGreaterThan(report.durationSeconds, 1)
        XCTAssertGreaterThanOrEqual(report.videoTrackCount, 1)
        XCTAssertEqual(
            report.audioTrackCount,
            1,
            "The \(source.displayName) export must contain one sharing-compatible AAC audio track."
        )
        XCTAssertEqual(
            report.audioTracks.count,
            1,
            "Export must mix requested sources into exactly one decoded audio track."
        )
        XCTAssertGreaterThan(
            report.audioDurationSeconds,
            0.5,
            "The \(source.displayName) track exists but contains no meaningful duration."
        )
        XCTAssertGreaterThan(
            report.audioEstimatedDataRate,
            1_000,
            "The \(source.displayName) track exists but contains no encoded audio data."
        )
        XCTAssertGreaterThan(
            report.audioSampleCount,
            0,
            "The \(source.displayName) track did not decode to any PCM samples."
        )
        if source.requiresNonSilentSystemSignal {
            XCTAssertGreaterThan(
                report.audioPeakAmplitude,
                0.005,
                "System audio did not contain the helper's synthetic tone."
            )
            XCTAssertGreaterThan(
                report.audioRMSAmplitude,
                0.001,
                "System audio decoded as silence instead of the helper's synthetic tone."
            )
        }
        XCTAssertGreaterThan(report.fileSizeBytes, 0)

        app.activate()
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 5) {
            done.click()
            _ = waitForDisappearance(done, timeout: 10)
        }
    }

    private func bundledAudioFixtureExecutable(
        _ helperURL: URL,
        in workDirectory: URL
    ) throws -> URL {
        let bundleURL = workDirectory.appendingPathComponent(
            "ClipAudioAcceptanceFixture.app",
            isDirectory: true
        )
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let executablesURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let executableURL = executablesURL.appendingPathComponent(
            "ClipAudioAcceptanceFixture"
        )
        try FileManager.default.createDirectory(
            at: executablesURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: helperURL, to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": "Clip Audio Acceptance Fixture",
            "CFBundleExecutable": "ClipAudioAcceptanceFixture",
            "CFBundleIdentifier": "com.tomaslejdung.clip.audio-acceptance-fixture",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Clip Audio Acceptance Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            options: .atomic
        )
        return executableURL
    }
    #endif

    @MainActor
    private func assertLiveShareScenario(
        _ rawValue: String,
        statusLabel: String,
        visibleIdentifiers: [String]
    ) throws {
        let app = launchDeterministicScenario(rawValue)
        defer { app.terminate() }

        let root = app.descendants(matching: .any)
            .matching(identifier: "clip.uiScenario.\(rawValue)")
            .firstMatch
        XCTAssertTrue(
            root.waitForExistence(timeout: 10),
            "The deterministic Live Share scenario \(rawValue) did not launch."
        )
        let status = app.descendants(matching: .any)
            .matching(identifier: "clip.liveShare.status")
            .firstMatch
        XCTAssertTrue(
            status.waitForExistence(timeout: 5),
            "The \(rawValue) fixture did not expose its status element."
        )
        let renderedStatus = [status.label, accessibilityValue(of: status)]
            .joined(separator: " ")
        XCTAssertTrue(
            renderedStatus.contains(statusLabel),
            "The \(rawValue) fixture rendered “\(renderedStatus)” instead of “\(statusLabel)”."
        )

        for identifier in visibleIdentifiers {
            let element = app.descendants(matching: .any)
                .matching(identifier: identifier)
                .firstMatch
            XCTAssertTrue(
                element.waitForExistence(timeout: 5),
                "The \(rawValue) fixture did not render \(identifier)."
            )
        }

        attachScenarioScreenshot(
            app: app,
            name: "Live Share — \(rawValue.replacingOccurrences(of: "-", with: " "))"
        )
    }

    @MainActor
    private func launchDeterministicScenario(_ rawValue: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-scenario=\(rawValue)"]
        app.launch()
        return app
    }

    @MainActor
    private func attachScenarioScreenshot(app: XCUIApplication, name: String) {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else {
            XCTFail("Could not capture \(name) because its fixture window was missing.")
            return
        }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.exists && element.isHittable
    }

    private func helperExecutableURL() throws -> URL {
        if let explicitPath = ProcessInfo.processInfo.environment["CLIP_TEST_HELPER_PATH"] {
            let explicitURL = URL(fileURLWithPath: explicitPath)
            if FileManager.default.isExecutableFile(atPath: explicitURL.path) {
                return explicitURL
            }
        }

        var directory = Bundle(for: Self.self).bundleURL
        for _ in 0..<12 {
            let candidate = directory.appendingPathComponent("ClipTestHelper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("ClipTestHelper was not present in the built products directory.")
    }

    private func run(_ executableURL: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            standardOutput: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            standardError: standardError.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private func diagnostic(for result: CommandResult) -> String {
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        let error = String(decoding: result.standardError, as: UTF8.self)
        return "status=\(result.status)\nstdout:\n\(output)\nstderr:\n\(error)"
    }

    @MainActor
    private func waitForJSON<Report: Decodable>(
        _ type: Report.Type,
        at url: URL,
        timeout: TimeInterval
    ) throws -> Report {
        let deadline = Date().addingTimeInterval(timeout)
        var lastDecodingError: (any Error)?
        while Date() < deadline {
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(type, from: data)
            } catch {
                lastDecodingError = error
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        throw NSError(
            domain: "ClipUITests.FixtureReport",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for \(url.lastPathComponent). "
                    + (lastDecodingError?.localizedDescription ?? "No report was written."),
            ]
        )
    }

    @MainActor
    private func element(labeled label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    @MainActor
    private func accessibilityValue(of element: XCUIElement) -> String {
        if let value = element.value as? String {
            return value
        }
        return String(describing: element.value ?? "")
    }

    private func timecodeSeconds(_ value: String) -> TimeInterval? {
        let components = value.split(separator: ":")
        guard (2...3).contains(components.count),
              components.allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        let integers = components.compactMap { Int($0) }
        if integers.count == 2 {
            return TimeInterval((integers[0] * 60) + integers[1])
        }
        return TimeInterval((integers[0] * 3_600) + (integers[1] * 60) + integers[2])
    }

    private func pixelDimensions(_ value: String) -> (width: Int, height: Int)? {
        let components = value
            .replacingOccurrences(of: "×", with: "x")
            .split(separator: "x", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard components.count == 2,
              let width = Int(components[0]),
              let height = Int(components[1]),
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }

    @MainActor
    private func waitForSingleManagedMP4(
        in isolatedStateRoot: URL,
        timeout: TimeInterval
    ) throws -> URL {
        let recordingsDirectory = isolatedStateRoot
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.tomaslejdung.clip", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        let deadline = Date().addingTimeInterval(timeout)
        var lastCandidateCount = 0

        while Date() < deadline {
            let candidates = (try? FileManager.default.contentsOfDirectory(
                at: recordingsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ))?.filter { url in
                guard url.pathExtension.lowercased() == "mp4" else { return false }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true
            } ?? []
            lastCandidateCount = candidates.count
            if candidates.count == 1, let onlyCandidate = candidates.first {
                return onlyCandidate
            }
            if candidates.count > 1 {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        throw NSError(
            domain: "ClipUITests.ManagedMaster",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Expected one managed MP4 in \(recordingsDirectory.path), found \(lastCandidateCount).",
            ]
        )
    }

    @MainActor
    private func runMainLoop(for duration: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    }

    @MainActor
    private func waitForLabel(
        _ expectedLabel: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isEnabled, element.label.contains(expectedLabel) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isEnabled && element.label.contains(expectedLabel)
    }

    @MainActor
    private func waitForValueChange(
        on element: XCUIElement,
        from initialValue: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, accessibilityValue(of: element) != initialValue {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && accessibilityValue(of: element) != initialValue
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }
}
