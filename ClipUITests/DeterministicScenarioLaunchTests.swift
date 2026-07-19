import XCTest

/// These assertions intentionally compile in every build but run only after an explicit
/// pointer-control opt-in. Normal verification compiles this source and exercises the launch
/// parser/coordinator with hosted unit tests; it never launches XCUIApplication.
final class DeterministicScenarioLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment[
            "CLIP_RUN_DETERMINISTIC_UI_SCENARIOS"
        ] == "1" else {
            throw XCTSkip(
                "Deterministic UI scenario automation is compile-only unless visible pointer control is explicitly enabled."
            )
        }
    }

    @MainActor
    func testOnboardingScenario() throws {
        try withScenario("onboarding") { app in
            XCTAssertTrue(app.otherElements["clip.uiScenario.onboarding"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["clip.onboarding.welcome"].exists)
            XCTAssertTrue(app.buttons["clip.onboarding.continue"].exists)
        }
    }

    @MainActor
    func testMenuPopoverScenario() throws {
        try withScenario("menu-popover") { app in
            XCTAssertTrue(app.statusItems["clip.uiScenario.statusItem"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["clip.uiScenario.menu-popover"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["clip.menu.captureArea"].exists)
            XCTAssertTrue(app.buttons["clip.menu.captureApplication"].exists)
            XCTAssertTrue(app.buttons["clip.menu.recordPrepared"].exists)
            XCTAssertTrue(app.switches["clip.menu.clickHighlights"].exists)
            XCTAssertEqual(app.switches["clip.menu.clickHighlights"].value as? String, "1")
            XCTAssertTrue(app.buttons["clip.menu.history"].exists)
            XCTAssertTrue(app.buttons["clip.menu.settings"].exists)
            XCTAssertEqual(
                app.staticTexts["clip.menu.version"].label,
                "Version 1.1.0"
            )
        }
    }

    @MainActor
    func testPermissionsDeniedScenario() throws {
        try withScenario("permissions-denied") { app in
            XCTAssertTrue(app.otherElements["clip.uiScenario.permissions-denied"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["clip.onboarding.screenRecording"].exists)
            XCTAssertTrue(app.staticTexts["Screen Recording denied"].exists)
            XCTAssertTrue(app.buttons["clip.onboarding.requestScreenRecording"].exists)
        }
    }

    @MainActor
    func testRecordingScenario() throws {
        try withScenario("recording") { app in
            XCTAssertTrue(app.otherElements["clip.uiScenario.recording"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["clip.recording.status"].exists)
            XCTAssertEqual(app.staticTexts["clip.recording.phase"].label, "Recording")
            XCTAssertTrue(app.buttons["clip.recording.pauseResume"].isEnabled)
            XCTAssertTrue(app.buttons["clip.recording.finish"].isEnabled)
        }
    }

    @MainActor
    func testPausedScenario() throws {
        try withScenario("paused") { app in
            XCTAssertTrue(app.otherElements["clip.uiScenario.paused"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["clip.recording.phase"].label, "Paused")
            XCTAssertEqual(app.buttons["clip.recording.pauseResume"].label, "Resume")
        }
    }

    @MainActor
    func testPreviewScenario() throws {
        try withScenario("preview") { app in
            XCTAssertTrue(app.otherElements["clip.uiScenario.preview"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["clip.preview"].exists)
            XCTAssertTrue(app.otherElements["clip.preview.video"].exists)
            XCTAssertTrue(app.otherElements["clip.preview.timeline"].exists)
            XCTAssertTrue(app.textFields["clip.preview.filename"].exists)
            XCTAssertTrue(app.switches["clip.preview.removeAudio"].exists)
            XCTAssertTrue(app.buttons["clip.preview.copy"].exists)
            XCTAssertTrue(app.buttons["clip.preview.saveAs"].exists)
        }
    }

    @MainActor
    func testHistoryScenario() throws {
        try withScenario("history") { app in
            XCTAssertTrue(app.otherElements["clip.uiScenario.history"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["clip.history"].exists)
            XCTAssertTrue(app.otherElements["clip.history.recordings.list"].exists)
            XCTAssertTrue(app.buttons["clip.history.recordings.refresh"].exists)
            XCTAssertTrue(app.buttons["clip.history.recordings.clearAll"].exists)
            XCTAssertTrue(
                app.buttons.matching(
                    NSPredicate(format: "identifier ENDSWITH '.preview'")
                ).firstMatch.exists
            )
            XCTAssertTrue(
                app.buttons.matching(
                    NSPredicate(format: "identifier ENDSWITH '.more'")
                ).firstMatch.exists
            )
        }
    }

    @MainActor
    func testHistoryExportsScenario() throws {
        try withScenario("history-exports") { app in
            XCTAssertTrue(
                app.otherElements["clip.uiScenario.history-exports"]
                    .waitForExistence(timeout: 5)
            )
            XCTAssertTrue(app.otherElements["clip.history.exports.list"].exists)
            XCTAssertTrue(app.buttons["clip.history.exports.refresh"].exists)
            XCTAssertTrue(app.buttons["clip.history.exports.deleteAll"].exists)
            XCTAssertTrue(
                app.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier ENDSWITH '.sourceDeleted'")
                ).firstMatch.exists
            )
        }
    }

    @MainActor
    func testSettingsScenario() throws {
        try withScenario("settings") { app in
            XCTAssertTrue(app.otherElements["clip.uiScenario.settings"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["clip.settings"].exists)
            XCTAssertTrue(app.otherElements["clip.settings.general"].exists)
            XCTAssertTrue(app.buttons["General"].exists)
            XCTAssertTrue(app.buttons["Permissions"].exists)
            let launchAtLogin = app.descendants(matching: .any)[
                "clip.settings.general.launchAtLogin"
            ]
            let showInDock = app.descendants(matching: .any)[
                "clip.settings.general.showInDock"
            ]
            let captureMode = app.descendants(matching: .any)[
                "clip.settings.general.defaultCaptureMode"
            ]
            XCTAssertTrue(launchAtLogin.exists)
            XCTAssertEqual(launchAtLogin.label, "Launch Clip at login")
            XCTAssertTrue(showInDock.exists)
            XCTAssertEqual(showInDock.label, "Show Clip in the Dock")
            XCTAssertTrue(captureMode.exists)
            XCTAssertEqual(captureMode.label, "Default capture mode")
        }
    }

    @MainActor
    func testEverySettingsTabVisualAudit() throws {
        let scenarios: [(scenario: String, title: String, identifier: String)] = [
            ("settings", "General", "clip.settings.general"),
            ("settings-recording", "Recording", "clip.settings.recording"),
            ("settings-export", "Export", "clip.settings.export"),
            ("settings-storage", "Storage", "clip.settings.storage"),
            ("settings-permissions", "Permissions", "clip.settings.permissions"),
        ]

        for scenario in scenarios {
            try withScenario(scenario.scenario) { app in
                XCTAssertTrue(
                    app.otherElements["clip.uiScenario.\(scenario.scenario)"]
                        .waitForExistence(timeout: 5)
                )
                let tab = app.otherElements[scenario.identifier]
                XCTAssertTrue(
                    tab.waitForExistence(timeout: 5),
                    "\(scenario.title) did not launch as the selected Settings tab."
                )
                if scenario.scenario == "settings-recording" {
                    XCTAssertTrue(
                        app.switches["clip.settings.recording.clickHighlights"].exists
                    )
                }

                retainSettingsScreenshot(
                    app,
                    name: "Settings \(scenario.title) — Top"
                )

                let scrollView = tab.scrollViews.firstMatch.exists
                    ? tab.scrollViews.firstMatch
                    : app.scrollViews.firstMatch
                XCTAssertTrue(
                    scrollView.waitForExistence(timeout: 2),
                    "\(scenario.title) did not expose its Settings scroll view."
                )
                scrollView.scroll(byDeltaX: 0, deltaY: -10_000)

                retainSettingsScreenshot(
                    app,
                    name: "Settings \(scenario.title) — Bottom"
                )
            }
        }
    }

    @MainActor
    func testFailureScenario() throws {
        try withScenario("failure") { app in
            XCTAssertTrue(app.otherElements["clip.uiScenario.failure"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["clip.failure"].exists)
            XCTAssertTrue(app.staticTexts["clip.failure.message"].exists)
        }
    }

    @MainActor
    private func withScenario(
        _ scenario: String,
        assertions: (XCUIApplication) throws -> Void
    ) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-scenario=\(scenario)"]
        app.launch()
        defer { app.terminate() }
        try assertions(app)
    }

    @MainActor
    private func retainSettingsScreenshot(
        _ app: XCUIApplication,
        name: String
    ) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
