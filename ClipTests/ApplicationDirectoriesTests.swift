import ClipCore
import ClipMedia
import CoreMedia
import Foundation
import Testing
@testable import Clip

@Suite("Application directories")
struct ApplicationDirectoriesTests {
    @Test("Unattended capture smoke is double-acknowledged, bounded, and fail-closed")
    func unattendedCaptureSmokeLaunchGuard() {
        let mode = UnattendedCaptureSmokeLaunch.modeArgument
        let acknowledgement = UnattendedCaptureSmokeLaunch.acknowledgementArgument
        let environment = [UnattendedCaptureSmokeLaunch.environmentKey: "1"]

        #expect(
            UnattendedCaptureSmokeLaunch.resolve(
                arguments: ["Clip"],
                environment: environment
            ) == .none
        )
        #expect(
            UnattendedCaptureSmokeLaunch.resolve(
                arguments: ["Clip", mode, acknowledgement],
                environment: [:]
            ) == .invalid
        )
        #expect(
            UnattendedCaptureSmokeLaunch.resolve(
                arguments: ["Clip", mode],
                environment: environment
            ) == .invalid
        )
        #expect(
            UnattendedCaptureSmokeLaunch.resolve(
                arguments: ["Clip", mode, mode, acknowledgement],
                environment: environment
            ) == .invalid
        )
        #expect(
            UnattendedCaptureSmokeLaunch.resolve(
                arguments: ["Clip", mode, acknowledgement],
                environment: environment
            ) == .run(UnattendedCaptureSmokeRequest(
                durationSeconds: 4,
                framesPerSecond: 30,
                preservesOutputForReview: false
            ))
        )

        #expect(
            UnattendedCaptureSmokeLaunch.resolve(
                arguments: [
                    "Clip",
                    mode,
                    acknowledgement,
                    UnattendedCaptureSmokeLaunch.preserveOutputArgument,
                ],
                environment: environment
            ) == .run(UnattendedCaptureSmokeRequest(
                durationSeconds: 4,
                framesPerSecond: 30,
                preservesOutputForReview: true
            ))
        )
        #expect(
            UnattendedCaptureSmokeLaunch.resolve(
                arguments: ["Clip", UnattendedCaptureSmokeLaunch.preserveOutputArgument],
                environment: environment
            ) == .invalid
        )
        #expect(
            UnattendedCaptureSmokeLaunch.resolve(
                arguments: [
                    "Clip",
                    mode,
                    acknowledgement,
                    UnattendedCaptureSmokeLaunch.preserveOutputArgument,
                    UnattendedCaptureSmokeLaunch.preserveOutputArgument,
                ],
                environment: environment
            ) == .invalid
        )
    }

    @Test("Unattended capture smoke accepts only 30 or 60 fps and 3 to 600 seconds")
    func unattendedCaptureSmokeBounds() {
        let base = [
            "Clip",
            UnattendedCaptureSmokeLaunch.modeArgument,
            UnattendedCaptureSmokeLaunch.acknowledgementArgument,
        ]
        let environment = [UnattendedCaptureSmokeLaunch.environmentKey: "1"]
        let valid = base + [
            "\(UnattendedCaptureSmokeLaunch.durationArgumentPrefix)600",
            "\(UnattendedCaptureSmokeLaunch.frameRateArgumentPrefix)60",
        ]
        #expect(
            UnattendedCaptureSmokeLaunch.resolve(
                arguments: valid,
                environment: environment
            ) == .run(UnattendedCaptureSmokeRequest(
                durationSeconds: 600,
                framesPerSecond: 60,
                preservesOutputForReview: false
            ))
        )

        for invalidArgument in [
            "\(UnattendedCaptureSmokeLaunch.durationArgumentPrefix)2.9",
            "\(UnattendedCaptureSmokeLaunch.durationArgumentPrefix)601",
            "\(UnattendedCaptureSmokeLaunch.durationArgumentPrefix)nan",
            "\(UnattendedCaptureSmokeLaunch.frameRateArgumentPrefix)24",
            "\(UnattendedCaptureSmokeLaunch.frameRateArgumentPrefix)120",
        ] {
            #expect(
                UnattendedCaptureSmokeLaunch.resolve(
                    arguments: base + [invalidArgument],
                    environment: environment
                ) == .invalid
            )
        }
    }

    @Test("Unattended capture preserves only a successful requested output")
    func unattendedCaptureArtifactPolicy() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let smokeRoot = testRoot
            .appendingPathComponent("Clip-Controlled-Capture-Smoke", isDirectory: true)
        let workDirectory = smokeRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outputURL = workDirectory.appendingPathComponent("synthetic-capture.mp4")
        try fileManager.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        try Data("video".utf8).write(to: outputURL)
        defer { try? fileManager.removeItem(at: testRoot) }

        #expect(!UnattendedCaptureSmokeArtifactPolicy.shouldPreserveOutput(
            requested: false,
            runSucceeded: true,
            outputURL: outputURL
        ))
        #expect(!UnattendedCaptureSmokeArtifactPolicy.shouldPreserveOutput(
            requested: true,
            runSucceeded: false,
            outputURL: outputURL
        ))
        #expect(UnattendedCaptureSmokeArtifactPolicy.shouldPreserveOutput(
            requested: true,
            runSucceeded: true,
            outputURL: outputURL
        ))

        #expect(UnattendedCaptureSmokeArtifactPolicy.deleteWorkDirectory(workDirectory))
        #expect(!fileManager.fileExists(atPath: workDirectory.path))
        #expect(!fileManager.fileExists(atPath: smokeRoot.path))
        #expect(!UnattendedCaptureSmokeArtifactPolicy.shouldPreserveOutput(
            requested: true,
            runSucceeded: true,
            outputURL: outputURL
        ))
    }

    @Test("Unattended capture report exposes a preserved review path")
    func unattendedCapturePreservedOutputReport() throws {
        let report = UnattendedCaptureSmokeReport(
            protocolVersion: 3,
            status: "passed",
            scope: "fixture",
            requestedDurationSeconds: 6,
            requestedFramesPerSecond: 30,
            pauseDurationSeconds: 0.9,
            screenPermissionWasPreauthorized: true,
            previewFrameWasGenerated: true,
            copyWasByteIdentical: true,
            copyPasteboardResolvedFileURL: true,
            copiedFileWasDecodedAndEvaluated: true,
            outputWasDeleted: false,
            preservedOutputPath: "/tmp/synthetic-capture.mp4",
            metrics: nil,
            failure: nil
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any]
        )
        #expect(object["protocolVersion"] as? Int == 3)
        #expect(object["outputWasDeleted"] as? Bool == false)
        #expect(
            object["preservedOutputPath"] as? String
                == "/tmp/synthetic-capture.mp4"
        )
    }

    @Test("Unattended capture display link requests an exact 30 or 60 fps cadence")
    func unattendedCaptureDisplayLinkCadence() {
        let thirty = UnattendedCaptureSmokeAnimationPolicy.exactFrameRateRange(
            framesPerSecond: 30
        )
        #expect(thirty?.minimum == 30)
        #expect(thirty?.maximum == 30)
        #expect(thirty?.preferred == 30)

        let sixty = UnattendedCaptureSmokeAnimationPolicy.exactFrameRateRange(
            framesPerSecond: 60
        )
        #expect(sixty?.minimum == 60)
        #expect(sixty?.maximum == 60)
        #expect(sixty?.preferred == 60)

        #expect(UnattendedCaptureSmokeAnimationPolicy.exactFrameRateRange(
            framesPerSecond: 24
        ) == nil)
    }

    @Test("Unattended capture animation invalidation is idempotent and deinit-safe")
    @MainActor
    func unattendedCaptureAnimationLifecycle() {
        var invalidationCount = 0
        do {
            let lease = UnattendedCaptureSmokeAnimationLease {
                invalidationCount += 1
            }
            #expect(lease.isActive)
            lease.invalidate()
            lease.invalidate()
            #expect(!lease.isActive)
            #expect(invalidationCount == 1)
        }

        do {
            let lease = UnattendedCaptureSmokeAnimationLease {
                invalidationCount += 1
            }
            #expect(lease.isActive)
            withExtendedLifetime(lease) {}
        }
        #expect(invalidationCount == 2)
    }

    @Test("Unattended capture timeline ignores zero-sample boundary markers")
    func unattendedCaptureTimelineIgnoresBoundaryMarkers() {
        #expect(
            UnattendedCaptureSmokeTimelinePolicy.mediaPresentationTime(
                sampleCount: 0,
                presentationTime: .zero
            ) == nil
        )
        #expect(
            UnattendedCaptureSmokeTimelinePolicy.mediaPresentationTime(
                sampleCount: 1,
                presentationTime: .zero
            ) == .zero
        )
    }

    @Test("Unattended capture reports the deterministic two-frame gap target")
    func unattendedCaptureTwoFrameGapTarget() {
        #expect(UnattendedCaptureSmokeTimelinePolicy.meetsTwoFrameGapTarget(
            maximumGap: 2.0 / 30.0,
            framesPerSecond: 30
        ))
        #expect(UnattendedCaptureSmokeTimelinePolicy.meetsTwoFrameGapTarget(
            maximumGap: 2.0 / 60.0,
            framesPerSecond: 60
        ))
        #expect(!UnattendedCaptureSmokeTimelinePolicy.meetsTwoFrameGapTarget(
            maximumGap: 0.08,
            framesPerSecond: 30
        ))
        #expect(!UnattendedCaptureSmokeTimelinePolicy.meetsTwoFrameGapTarget(
            maximumGap: .nan,
            framesPerSecond: 30
        ))
    }

    @Test("Hosted unit tests suppress production startup without suppressing UI-test app launches")
    func hostedUnitTestDetectionIsExplicitAndUIAware() {
        #expect(
            !HostedUnitTestDetection.shouldSuppressNormalAppStartup(
                arguments: ["/Applications/Clip.app/Contents/MacOS/Clip"],
                environment: [:]
            )
        )
        #expect(
            HostedUnitTestDetection.shouldSuppressNormalAppStartup(
                arguments: ["/tmp/Clip.app/Contents/MacOS/Clip"],
                environment: ["XCTestConfigurationFilePath": "/tmp/ClipTests.xctestconfiguration"]
            )
        )
        #expect(
            HostedUnitTestDetection.shouldSuppressNormalAppStartup(
                arguments: ["/tmp/Clip.app/Contents/MacOS/Clip"],
                environment: ["XCInjectBundleInto": "/tmp/Clip.app/Contents/MacOS/Clip"]
            )
        )
        #expect(
            !HostedUnitTestDetection.shouldSuppressNormalAppStartup(
                arguments: [
                    "/tmp/Clip.app/Contents/MacOS/Clip",
                    AppLaunchConfiguration.uiTestingArgument,
                ],
                environment: ["XCTestConfigurationFilePath": "/tmp/ClipUITests.xctestconfiguration"]
            )
        )
    }

    @Test("Normal launches ignore test-only acceptance flags and keep production state")
    func normalLaunchConfigurationIsUnchanged() {
        let configuration = AppLaunchConfiguration.resolve(
            arguments: ["Clip", AppLaunchConfiguration.realCaptureAcceptanceArgument],
            temporaryDirectory: URL(fileURLWithPath: "/tmp/clip-launch-tests"),
            isolationIdentifier: "normal"
        )

        #expect(configuration.mode == .standard)
        #expect(configuration.isolatedStateRoot == nil)
        #expect(configuration.defaultsSuiteName == nil)
        #expect(configuration.initialSettings(homeDirectory: URL(fileURLWithPath: "/home")) == nil)
        #expect(!configuration.isUITesting)
        #expect(!configuration.completesOnboarding)
        #expect(configuration.allowsSystemIntegrations)
    }

    @Test("Every deterministic UI scenario is guarded and receives its own isolated state")
    func deterministicUIScenariosAreGuardedAndIsolated() {
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/clip-launch-tests")

        for scenario in DeterministicUIScenario.allCases {
            let arguments = [
                "Clip",
                AppLaunchConfiguration.uiTestingArgument,
                scenario.launchArgument,
            ]
            let isolationIdentifier = AppLaunchConfiguration.isolationIdentifier(
                for: arguments
            )
            let configuration = AppLaunchConfiguration.resolve(
                arguments: arguments,
                temporaryDirectory: temporaryDirectory,
                isolationIdentifier: isolationIdentifier
            )

            #expect(configuration.mode == .uiTesting)
            #expect(configuration.uiScenario == scenario)
            #expect(configuration.uiScenarioRequest == .scenario(scenario))
            #expect(configuration.launchesDeterministicUIScenario)
            #expect(!configuration.allowsSystemIntegrations)
            #expect(isolationIdentifier == "ui-scenario-\(scenario.rawValue)")
            #expect(
                configuration.isolatedStateRoot
                    == temporaryDirectory
                        .appendingPathComponent("Clip-UI-Testing", isDirectory: true)
                        .appendingPathComponent(isolationIdentifier, isDirectory: true)
            )
            #expect(
                configuration.defaultsSuiteName
                    == "com.tomaslejdung.clip.ui-testing.\(isolationIdentifier)"
            )
        }
    }

    @Test("Scenario arguments cannot affect normal or real-capture launches")
    func deterministicUIScenarioArgumentsCannotEscapeTheirGuard() {
        let root = URL(fileURLWithPath: "/tmp/clip-launch-tests")
        let production = AppLaunchConfiguration.resolve(
            arguments: ["Clip", DeterministicUIScenario.permissionsDenied.launchArgument],
            temporaryDirectory: root,
            isolationIdentifier: "production"
        )
        #expect(production.mode == .standard)
        #expect(production.uiScenarioRequest == .none)
        #expect(production.uiScenario == nil)
        #expect(!production.launchesDeterministicUIScenario)
        #expect(production.allowsSystemIntegrations)

        let realCapture = AppLaunchConfiguration.resolve(
            arguments: [
                "Clip",
                AppLaunchConfiguration.uiTestingArgument,
                AppLaunchConfiguration.realCaptureAcceptanceArgument,
                DeterministicUIScenario.failure.launchArgument,
            ],
            temporaryDirectory: root,
            isolationIdentifier: "real-capture-acceptance"
        )
        #expect(realCapture.mode == .realCaptureAcceptance)
        #expect(realCapture.uiScenarioRequest == .none)
        #expect(realCapture.uiScenario == nil)
        #expect(!realCapture.launchesDeterministicUIScenario)
        #expect(realCapture.completesOnboarding)
    }

    @Test("Unknown and ambiguous UI scenarios fail closed")
    func invalidDeterministicUIScenariosFailClosed() {
        let root = URL(fileURLWithPath: "/tmp/clip-launch-tests")
        let invalidArguments: [[String]] = [
            ["Clip", AppLaunchConfiguration.uiTestingArgument, "--ui-scenario=unknown"],
            ["Clip", AppLaunchConfiguration.uiTestingArgument, "--ui-scenario"],
            [
                "Clip",
                AppLaunchConfiguration.uiTestingArgument,
                DeterministicUIScenario.onboarding.launchArgument,
                DeterministicUIScenario.history.launchArgument,
            ],
        ]

        for arguments in invalidArguments {
            let isolationIdentifier = AppLaunchConfiguration.isolationIdentifier(
                for: arguments
            )
            let configuration = AppLaunchConfiguration.resolve(
                arguments: arguments,
                temporaryDirectory: root,
                isolationIdentifier: isolationIdentifier
            )
            #expect(configuration.mode == .uiTesting)
            #expect(configuration.uiScenarioRequest == .invalid)
            #expect(configuration.uiScenario == nil)
            #expect(configuration.launchesDeterministicUIScenario)
            #expect(!configuration.allowsSystemIntegrations)
            #expect(isolationIdentifier == "ui-scenario-invalid")
        }
    }

    @Test("UI-test launches use per-launch files and defaults without enabling the real lane")
    func uiTestLaunchConfigurationIsIsolated() throws {
        let temporaryDirectory = URL(fileURLWithPath: "/tmp/clip-launch-tests")
        let configuration = AppLaunchConfiguration.resolve(
            arguments: ["Clip", AppLaunchConfiguration.uiTestingArgument],
            temporaryDirectory: temporaryDirectory,
            isolationIdentifier: "plain-ui-test"
        )

        #expect(configuration.mode == .uiTesting)
        #expect(
            configuration.isolatedStateRoot
                == temporaryDirectory
                    .appendingPathComponent("Clip-UI-Testing", isDirectory: true)
                    .appendingPathComponent("plain-ui-test", isDirectory: true)
        )
        #expect(
            configuration.defaultsSuiteName
                == "com.tomaslejdung.clip.ui-testing.plain-ui-test"
        )
        #expect(configuration.isUITesting)
        #expect(!configuration.completesOnboarding)
        #expect(!configuration.allowsSystemIntegrations)
        #expect(configuration.initialSettings(homeDirectory: temporaryDirectory) == nil)
    }

    @MainActor
    @Test("Real capture acceptance starts from isolated deterministic settings")
    func realCaptureAcceptanceConfigurationIsDeterministic() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipLaunchConfigurationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let isolationIdentifier = UUID().uuidString.lowercased()
        let configuration = AppLaunchConfiguration.resolve(
            arguments: [
                "Clip",
                AppLaunchConfiguration.uiTestingArgument,
                AppLaunchConfiguration.realCaptureAcceptanceArgument,
            ],
            temporaryDirectory: root,
            isolationIdentifier: isolationIdentifier
        )
        let defaultsSuiteName = try #require(configuration.defaultsSuiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName) }

        #expect(configuration.mode == .realCaptureAcceptance)
        #expect(configuration.completesOnboarding)
        #expect(!configuration.allowsSystemIntegrations)

        let defaults = try configuration.makeUserDefaults()
        defaults.set(true, forKey: OnboardingStore.defaultCompletionKey)
        #expect(defaults.bool(forKey: OnboardingStore.defaultCompletionKey))

        let home = root.appendingPathComponent("Home", isDirectory: true)
        let fixedSettings = try #require(configuration.initialSettings(homeDirectory: home))
        #expect(fixedSettings.defaultCaptureMode == .fullscreen)
        #expect(fixedSettings.mostRecentCaptureMode == .fullscreen)
        #expect(!fixedSettings.rememberLastArea)
        #expect(fixedSettings.frameRate == .thirty)
        #expect(fixedSettings.showCursor)
        #expect(fixedSettings.audio == .none)
        #expect(fixedSettings.countdown == .oneSecond)
        #expect(fixedSettings.historyRetention == .indefinitely)
        #expect(fixedSettings.exportConfiguration == .compact)
        #expect(!fixedSettings.automaticallyClosePreviewAfterCopy)
        #expect(fixedSettings.keepOriginalAfterExport)
        #expect(!fixedSettings.launchAtLogin)
        #expect(!fixedSettings.showInDock)

        let model = try AppSettingsModel(
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            homeDirectory: home,
            initialSettings: fixedSettings,
            directoryBookmarks: FakeDirectoryBookmarkService(directories: [])
        )
        await model.load()
        #expect(model.settings == fixedSettings)
    }

    @Test("Real audio acceptance overrides are isolated and mutually exclusive")
    func realAudioAcceptanceOverridesAreGuarded() throws {
        let root = URL(fileURLWithPath: "/tmp/clip-launch-tests")
        let baseArguments = [
            "Clip",
            AppLaunchConfiguration.uiTestingArgument,
            AppLaunchConfiguration.realCaptureAcceptanceArgument,
        ]

        let microphone = AppLaunchConfiguration.resolve(
            arguments: baseArguments + [AppLaunchConfiguration.realMicrophoneAcceptanceArgument],
            temporaryDirectory: root,
            isolationIdentifier: "real-microphone"
        )
        #expect(microphone.realCaptureAudioConfiguration == .microphoneOnly)
        #expect(
            microphone.initialSettings(homeDirectory: root)?.audio
                == .microphoneOnly
        )

        let systemAudio = AppLaunchConfiguration.resolve(
            arguments: baseArguments + [AppLaunchConfiguration.realSystemAudioAcceptanceArgument],
            temporaryDirectory: root,
            isolationIdentifier: "real-system-audio"
        )
        #expect(systemAudio.realCaptureAudioConfiguration == .systemAudioOnly)
        #expect(
            systemAudio.initialSettings(homeDirectory: root)?.audio
                == .systemAudioOnly
        )

        let combined = AppLaunchConfiguration.resolve(
            arguments: baseArguments + [AppLaunchConfiguration.realCombinedAudioAcceptanceArgument],
            temporaryDirectory: root,
            isolationIdentifier: "real-combined-audio"
        )
        #expect(combined.realCaptureAudioConfiguration == .microphoneAndSystemAudio)
        #expect(
            combined.initialSettings(homeDirectory: root)?.audio
                == .microphoneAndSystemAudio
        )

        let conflicting = AppLaunchConfiguration.resolve(
            arguments: baseArguments + [
                AppLaunchConfiguration.realMicrophoneAcceptanceArgument,
                AppLaunchConfiguration.realSystemAudioAcceptanceArgument,
            ],
            temporaryDirectory: root,
            isolationIdentifier: "real-conflicting-audio"
        )
        #expect(conflicting.realCaptureAudioConfiguration == nil)
        #expect(
            conflicting.initialSettings(homeDirectory: root)?.audio
                == AudioConfiguration.none
        )

        let combinedConflict = AppLaunchConfiguration.resolve(
            arguments: baseArguments + [
                AppLaunchConfiguration.realCombinedAudioAcceptanceArgument,
                AppLaunchConfiguration.realMicrophoneAcceptanceArgument,
            ],
            temporaryDirectory: root,
            isolationIdentifier: "real-combined-conflict"
        )
        #expect(combinedConflict.realCaptureAudioConfiguration == nil)
        #expect(
            combinedConflict.initialSettings(homeDirectory: root)?.audio
                == AudioConfiguration.none
        )

        let production = AppLaunchConfiguration.resolve(
            arguments: [
                "Clip",
                AppLaunchConfiguration.realCaptureAcceptanceArgument,
                AppLaunchConfiguration.realMicrophoneAcceptanceArgument,
            ],
            temporaryDirectory: root,
            isolationIdentifier: "production"
        )
        #expect(production.mode == .standard)
        #expect(production.realCaptureAudioConfiguration == nil)
        #expect(production.initialSettings(homeDirectory: root) == nil)
    }

    @Test("Real workflow overrides are guarded, temporary, and preserve only dedicated state")
    func realWorkflowAcceptanceOverridesAreGuarded() throws {
        let root = URL(fileURLWithPath: "/tmp/clip-launch-tests", isDirectory: true)
        let saveDirectory = root.appendingPathComponent("Authorized Save", isDirectory: true)
        let arguments = [
            "Clip",
            AppLaunchConfiguration.uiTestingArgument,
            AppLaunchConfiguration.realCaptureAcceptanceArgument,
            "\(AppLaunchConfiguration.realFrameRateArgumentPrefix)60",
            "\(AppLaunchConfiguration.realCursorArgumentPrefix)off",
            AppLaunchConfiguration.realRememberLastAreaArgument,
            "\(AppLaunchConfiguration.realRetentionArgumentPrefix)do-not-retain",
            "\(AppLaunchConfiguration.realSaveDirectoryArgumentPrefix)\(saveDirectory.path)",
            "\(AppLaunchConfiguration.realStateIdentifierArgumentPrefix)workflow-123",
            AppLaunchConfiguration.realPreserveStateArgument,
        ]
        let isolationIdentifier = AppLaunchConfiguration.isolationIdentifier(for: arguments)
        let configuration = AppLaunchConfiguration.resolve(
            arguments: arguments,
            temporaryDirectory: root,
            isolationIdentifier: isolationIdentifier
        )
        let settings = try #require(configuration.initialSettings(homeDirectory: root))

        #expect(isolationIdentifier == "real-capture-workflow-123")
        #expect(configuration.mode == .realCaptureAcceptance)
        #expect(configuration.realCaptureOverrides.frameRate == .sixty)
        #expect(configuration.realCaptureOverrides.showsCursor == false)
        #expect(configuration.realCaptureOverrides.remembersLastArea)
        #expect(configuration.realCaptureOverrides.historyRetention == .doNotRetainAfterExport)
        #expect(configuration.realCaptureOverrides.defaultSaveDirectory == saveDirectory)
        #expect(configuration.realCaptureOverrides.preservesIsolatedState)
        #expect(!configuration.resetsIsolatedStateOnLaunch)
        #expect(settings.frameRate == .sixty)
        #expect(!settings.showCursor)
        #expect(settings.rememberLastArea)
        #expect(settings.historyRetention == .doNotRetainAfterExport)
        #expect(settings.defaultSaveDirectory == saveDirectory)

        let outsideTemporaryDirectory = AppLaunchConfiguration.resolve(
            arguments: [
                "Clip",
                AppLaunchConfiguration.uiTestingArgument,
                AppLaunchConfiguration.realCaptureAcceptanceArgument,
                "\(AppLaunchConfiguration.realSaveDirectoryArgumentPrefix)/Users/example/Documents",
                AppLaunchConfiguration.realPreserveStateArgument,
            ],
            temporaryDirectory: root,
            isolationIdentifier: "real-capture-acceptance"
        )
        #expect(outsideTemporaryDirectory.realCaptureOverrides.defaultSaveDirectory == nil)
        #expect(!outsideTemporaryDirectory.realCaptureOverrides.preservesIsolatedState)
        #expect(outsideTemporaryDirectory.resetsIsolatedStateOnLaunch)

        let production = AppLaunchConfiguration.resolve(
            arguments: arguments.filter { $0 != AppLaunchConfiguration.uiTestingArgument },
            temporaryDirectory: root,
            isolationIdentifier: "production"
        )
        #expect(production.mode == .standard)
        #expect(production.realCaptureOverrides == .none)
        #expect(production.initialSettings(homeDirectory: root) == nil)
    }

    @Test("Creates all managed directories")
    func createsManagedDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileSystem = LiveFileSystem()
        let directories = try ApplicationDirectories.resolve(
            applicationSupportRoot: root.appendingPathComponent("Application Support"),
            cachesRoot: root.appendingPathComponent("Caches"),
            bundleIdentifier: "com.example.ClipTests",
            fileSystem: fileSystem
        )

        #expect(fileSystem.fileExists(at: directories.applicationSupport))
        #expect(fileSystem.fileExists(at: directories.recordings))
        #expect(fileSystem.fileExists(at: directories.exports))
        #expect(fileSystem.fileExists(at: directories.caches))
        #expect(
            directories.exports.deletingLastPathComponent().standardizedFileURL
                == directories.caches.standardizedFileURL
        )
    }

    @MainActor
    @Test("Application dependencies accept inert platform-service implementations")
    func appDependenciesAcceptProtocolPlatformServices() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDependenciesFakes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = AppLaunchConfiguration.resolve(
            arguments: [
                "Clip",
                AppLaunchConfiguration.uiTestingArgument,
                DeterministicUIScenario.settings.launchArgument,
            ],
            temporaryDirectory: root,
            isolationIdentifier: "fake-composition"
        )
        let defaultsSuiteName = try #require(configuration.defaultsSuiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName) }

        let fileSystem = LiveFileSystem()
        let directories = try ApplicationDirectories.resolve(
            applicationSupportRoot: root.appendingPathComponent("Support"),
            cachesRoot: root.appendingPathComponent("Caches"),
            bundleIdentifier: "com.tomaslejdung.clip.fake-composition",
            fileSystem: fileSystem
        )
        let settings = try AppSettingsModel(
            applicationSupportDirectory: directories.applicationSupport,
            homeDirectory: root,
            directoryBookmarks: FakeDirectoryBookmarkService(directories: [])
        )
        let permissions = FakePermissionService()
        let audio = FakeAudioService()
        let pasteboard = FakePasteboardService()
        let displays = FakeDisplayService()
        let capture = FakeCaptureService()
        let exports = PreviewExportCoordinator(exportsDirectory: directories.exports)
        let sharing = PreviewSharingService(
            exports: exports,
            pasteboard: pasteboard,
            settings: settings
        )
        let history = try ManagedHistoryRepository(
            applicationSupportDirectory: directories.applicationSupport,
            recordingsDirectory: directories.recordings
        )

        let dependencies = AppDependencies(
            launchConfiguration: configuration,
            directories: directories,
            defaults: try configuration.makeUserDefaults(),
            fileSystem: fileSystem,
            clock: SystemClock(),
            settings: settings,
            permissions: permissions,
            audio: audio,
            pasteboard: pasteboard,
            displays: displays,
            capture: capture,
            exports: exports,
            sharing: sharing,
            history: history,
            shortcuts: GlobalShortcutService(registrar: FakeGlobalHotKeyRegistrar())
        )

        #expect(dependencies.permissions === permissions)
        #expect(dependencies.audio === audio)
        #expect(dependencies.pasteboard === pasteboard)
        #expect(dependencies.displays === displays)
        #expect(dependencies.capture === capture)
        #expect(dependencies.permissions.currentStatus(for: .screenRecording) == .denied)
        let availableDisplays = try await dependencies.displays.availableDisplays()
        #expect(availableDisplays.isEmpty)
    }

    @Test("Atomic writes replace an existing file")
    func atomicWritesReplaceExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("state/value.json")
        let fileSystem = LiveFileSystem()

        try fileSystem.writeAtomically(Data("old".utf8), to: destination)
        try fileSystem.writeAtomically(Data("new".utf8), to: destination)

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
    }

    @MainActor
    @Test("Default filename formats persist through the application settings store")
    func defaultFilenameTemplateRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let supportDirectory = root.appendingPathComponent("Application Support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try RecordingFilenameTemplate(
            validating: "project-YYYY-MM-DD_HH-mm-ss.mp4"
        )

        let first = try AppSettingsModel(
            applicationSupportDirectory: supportDirectory,
            homeDirectory: root,
            directoryBookmarks: FakeDirectoryBookmarkService(directories: [])
        )
        await first.load()
        await first.update { $0.defaultFilenameTemplate = template }
        #expect(first.lastPersistenceError == nil)

        let restored = try AppSettingsModel(
            applicationSupportDirectory: supportDirectory,
            homeDirectory: root,
            directoryBookmarks: FakeDirectoryBookmarkService(directories: [])
        )
        await restored.load()

        #expect(restored.settings.defaultFilenameTemplate == template)
        #expect(restored.settings.schemaVersion == ClipSettings.currentSchemaVersion)
        #expect(restored.lastPersistenceError == nil)
    }

    @MainActor
    @Test("Settings persistence hides filesystem details behind a concise message")
    func settingsPersistenceErrorsAreSanitized() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedSupportPath = root.appendingPathComponent("Support")
        try Data("not a directory".utf8).write(to: blockedSupportPath)
        let model = try AppSettingsModel(
            applicationSupportDirectory: blockedSupportPath,
            homeDirectory: root,
            directoryBookmarks: FakeDirectoryBookmarkService(directories: [])
        )

        await model.update { $0.showCursor.toggle() }

        #expect(model.lastPersistenceError == UserFacingErrorPresentation.genericMessage)
        #expect(model.lastPersistenceError?.contains(blockedSupportPath.path) == false)
    }

    @MainActor
    @Test("Default Save As folders persist and restore sandbox authorization")
    func defaultSaveDirectoryBookmarkRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let supportDirectory = root.appendingPathComponent("Application Support", isDirectory: true)
        let selectedDirectory = root.appendingPathComponent("Chosen Exports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: selectedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let bookmarks = FakeDirectoryBookmarkService(directories: [selectedDirectory])
        let first = try AppSettingsModel(
            applicationSupportDirectory: supportDirectory,
            homeDirectory: root,
            directoryBookmarks: bookmarks
        )
        await first.load()
        try await first.setDefaultSaveDirectory(selectedDirectory)

        #expect(first.settings.defaultSaveDirectory == selectedDirectory.standardizedFileURL)
        #expect(first.defaultSaveDirectoryAccessError == nil)
        #expect(bookmarks.createdBookmarkCount == 1)
        #expect(bookmarks.startedURLs == [selectedDirectory.standardizedFileURL])

        bookmarks.resolveAsStale = true
        let restored = try AppSettingsModel(
            applicationSupportDirectory: supportDirectory,
            homeDirectory: root,
            directoryBookmarks: bookmarks
        )
        await restored.load()

        #expect(restored.settings.defaultSaveDirectory == selectedDirectory.standardizedFileURL)
        #expect(restored.defaultSaveDirectoryAccessError == nil)
        #expect(bookmarks.createdBookmarkCount == 2)
        #expect(bookmarks.startedURLs.count == 2)
    }

    @MainActor
    @Test("Default Save As folders reject non-file and unavailable locations")
    func defaultSaveDirectoryValidation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmarks = FakeDirectoryBookmarkService(directories: [])
        let model = try AppSettingsModel(
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            homeDirectory: root,
            directoryBookmarks: bookmarks
        )

        do {
            try await model.setDefaultSaveDirectory(try #require(URL(string: "https://example.com")))
            Issue.record("A remote URL must not become the Save As directory")
        } catch let error as DefaultSaveDirectoryError {
            #expect(error == .mustBeFileURL)
        }

        let missing = root.appendingPathComponent("Missing", isDirectory: true)
        do {
            try await model.setDefaultSaveDirectory(missing)
            Issue.record("A missing folder must not become the Save As directory")
        } catch let error as DefaultSaveDirectoryError {
            #expect(error == .directoryDoesNotExist(missing.standardizedFileURL))
        }

        #expect(bookmarks.createdBookmarkCount == 0)
        #expect(bookmarks.startedURLs.isEmpty)
    }

    @Test("Storage snapshots preserve repository usage categories")
    func settingsStorageSnapshotMapping() {
        let snapshot = SettingsStorageSnapshot(
            ManagedHistoryStorageUsage(
                itemCount: 4,
                indexedMasterByteCount: 1_000,
                actualManagedMP4ByteCount: 1_300,
                recognizedOrphanByteCount: 200,
                untrackedMP4ByteCount: 100
            )
        )

        #expect(snapshot.recordingCount == 4)
        #expect(snapshot.indexedMasterByteCount == 1_000)
        #expect(snapshot.directoryMP4ByteCount == 1_300)
        #expect(snapshot.cleanupCandidateByteCount == 200)
        #expect(snapshot.untrackedMP4ByteCount == 100)
    }

    @Test("Export cleanup expires only old Clip cache directories")
    func exportCleanupHonorsGracePeriodAndOwnershipShape() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordingDirectory = root.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        let oldCache = recordingDirectory.appendingPathComponent("0-1000-compact", isDirectory: true)
        let recentCache = recordingDirectory.appendingPathComponent("0-2000-crisp", isDirectory: true)
        let unknownDirectory = root.appendingPathComponent("not-owned", isDirectory: true)
        for directory in [oldCache, recentCache, unknownDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data("mp4".utf8).write(to: directory.appendingPathComponent("clip.mp4"))
        }

        let now = Date(timeIntervalSince1970: 2_000_000)
        let staleDate = now.addingTimeInterval(-PreviewExportCoordinator.staleExportLifetime - 1)
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: oldCache.appendingPathComponent("clip.mp4").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: oldCache.path
        )

        let coordinator = PreviewExportCoordinator(exportsDirectory: root)
        let removed = try await coordinator.removeStaleExports(
            olderThan: now.addingTimeInterval(-PreviewExportCoordinator.staleExportLifetime)
        )

        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: oldCache.path))
        #expect(FileManager.default.fileExists(atPath: recentCache.path))
        #expect(FileManager.default.fileExists(atPath: unknownDirectory.path))
    }

    @Test("Export cache identity includes the encoding schema version")
    func exportCacheIdentityInvalidatesEarlierEncodingAlgorithms() async throws {
        let coordinator = PreviewExportCoordinator(
            exportsDirectory: URL(fileURLWithPath: "/tmp/clip-export-cache-version")
        )
        let request = PreviewExportRequest(
            recordingID: RecordingID(
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            ),
            sourceURL: URL(fileURLWithPath: "/tmp/master.mp4"),
            captureFrameRate: .thirty,
            filename: try RecordingFilename(validating: "clip-cache.mp4"),
            trimRange: try TrimRange(startTime: 0, endTime: 21.598),
            configuration: .crisp,
            audioPreference: .keepAudio
        )

        let key = await coordinator.cacheKey(for: request)

        #expect(PreviewExportCoordinator.cacheSchemaVersion == 3)
        #expect(key == "v3-0-21598-crisp-30fps-audio")
        #expect(key != "0-21598-crisp")
    }

    @Test("Export planning preserves the capture FPS ceiling instead of rounding nominal FPS")
    func exportPlanningUsesCaptureFrameRateCeiling() async throws {
        let coordinator = PreviewExportCoordinator(
            exportsDirectory: URL(fileURLWithPath: "/tmp/clip-export-cadence")
        )
        let request = PreviewExportRequest(
            recordingID: RecordingID(
                UUID(uuidString: "12121212-3434-5656-7878-909090909090")!
            ),
            sourceURL: URL(fileURLWithPath: "/tmp/variable-rate-master.mp4"),
            captureFrameRate: .thirty,
            filename: try RecordingFilename(validating: "variable-rate.mp4"),
            trimRange: try TrimRange(startTime: 0, endTime: 12),
            configuration: .crisp,
            audioPreference: .keepAudio
        )
        let inspection = MediaInspection(
            duration: 12,
            fileSize: 1_000_000,
            videoTrackCount: 1,
            audioTrackCount: 1,
            width: 1_920,
            height: 1_080,
            nominalFramesPerSecond: 28.29,
            videoCodec: kCMVideoCodecType_H264
        )

        let configuration = await coordinator.mediaConfiguration(
            for: request,
            inspection: inspection
        )

        #expect(configuration.framesPerSecond == 30)
    }

    @MainActor
    @Test("Hourly maintenance survives a failed cycle and remains bounded across a long synthetic run")
    func periodicMaintenanceLoopSoak() async {
        let cycleCount = 10_000
        let failingCycle = 4_321
        let probe = PeriodicMaintenanceProbe(
            allowedSleepCount: cycleCount,
            failingOperation: failingCycle
        )
        let clock = FiniteMaintenanceClock(probe: probe)

        await PeriodicStorageMaintenanceLoop.run(
            clock: clock,
            operation: {
                let operation = await probe.recordOperation()
                if operation == failingCycle {
                    throw PeriodicMaintenanceFixtureError.expectedFailure
                }
            },
            reportFailure: { error in
                #expect(error as? PeriodicMaintenanceFixtureError == .expectedFailure)
                Task { await probe.recordReportedFailure() }
            }
        )
        await probe.waitForReportedFailures(1)
        let snapshot = await probe.snapshot

        #expect(snapshot.sleepCount == cycleCount + 1)
        #expect(snapshot.operationCount == cycleCount)
        #expect(snapshot.reportedFailureCount == 1)
        #expect(snapshot.durations.allSatisfy { $0 == .seconds(60 * 60) })
    }
}

private enum PeriodicMaintenanceFixtureError: Error, Equatable {
    case expectedFailure
}

private actor PeriodicMaintenanceProbe {
    struct Snapshot: Sendable {
        let sleepCount: Int
        let operationCount: Int
        let reportedFailureCount: Int
        let durations: [Duration]
    }

    private let allowedSleepCount: Int
    private let failingOperation: Int
    private var sleepCount = 0
    private var operationCount = 0
    private var reportedFailureCount = 0
    private var durations: [Duration] = []

    init(allowedSleepCount: Int, failingOperation: Int) {
        self.allowedSleepCount = allowedSleepCount
        self.failingOperation = failingOperation
    }

    func recordSleep(_ duration: Duration) throws {
        sleepCount += 1
        guard sleepCount <= allowedSleepCount else { throw CancellationError() }
        durations.append(duration)
    }

    func recordOperation() -> Int {
        operationCount += 1
        return operationCount
    }

    func recordReportedFailure() {
        reportedFailureCount += 1
    }

    func waitForReportedFailures(_ expected: Int) async {
        while reportedFailureCount < expected {
            await Task.yield()
        }
    }

    var snapshot: Snapshot {
        Snapshot(
            sleepCount: sleepCount,
            operationCount: operationCount,
            reportedFailureCount: reportedFailureCount,
            durations: durations
        )
    }
}

private struct FiniteMaintenanceClock: ClockServicing {
    let probe: PeriodicMaintenanceProbe
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func sleep(for duration: Duration) async throws {
        try await probe.recordSleep(duration)
    }
}

@MainActor
private final class FakeDirectoryBookmarkService: DirectoryBookmarkServicing {
    private let directories: Set<URL>
    var resolveAsStale = false
    private(set) var createdBookmarkCount = 0
    private(set) var startedURLs: [URL] = []

    init(directories: Set<URL>) {
        self.directories = Set(directories.map(\.standardizedFileURL))
    }

    func isDirectory(_ url: URL) -> Bool {
        directories.contains(url.standardizedFileURL)
    }

    func makeSecurityScopedBookmark(for url: URL) throws -> Data {
        createdBookmarkCount += 1
        return Data(url.standardizedFileURL.absoluteString.utf8)
    }

    func resolveSecurityScopedBookmark(_ data: Data) throws -> ResolvedDirectoryBookmark {
        let encodedURL = try #require(String(data: data, encoding: .utf8))
        let url = try #require(URL(string: encodedURL))
        return ResolvedDirectoryBookmark(
            url: url.standardizedFileURL,
            isStale: resolveAsStale
        )
    }

    func startAccessing(_ url: URL) -> Bool {
        startedURLs.append(url.standardizedFileURL)
        return true
    }

    nonisolated func stopAccessing(_: URL) {}
}

@MainActor
private final class FakePermissionService: PermissionServicing {
    func currentStatus(for permission: ClipPermission) -> PermissionState { .denied }
    func request(_ permission: ClipPermission) async -> PermissionState { .denied }
}

@MainActor
private final class FakeAudioService: AudioServicing {
    let defaultInputName: String? = nil
    func refreshDevices() async {}
}

@MainActor
private final class FakePasteboardService: PasteboardServicing {
    func placeFile(at url: URL) throws {}
}

@MainActor
private final class FakeDisplayService: DisplayServicing {
    func availableDisplays() async throws -> [ClipDisplay] { [] }
}

@MainActor
private final class FakeCaptureService: CaptureServicing {
    let events = AsyncStream<ScreenRecorderEvent> { continuation in
        continuation.finish()
    }

    func prepare(_ target: PreparedCaptureTarget) async throws {}
    func start(recordingID: RecordingID, settings: ClipSettings) async throws {}
    func pause() async throws {}
    func resume() async throws {}
    func finish() async throws -> RecordingArtifact {
        throw FakeCaptureServiceError.noArtifact
    }
    func cancel() async {}
}

private enum FakeCaptureServiceError: Error {
    case noArtifact
}

@MainActor
private final class FakeGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    func replace(
        registrations: [GlobalHotKeyRegistration],
        handler: @escaping @MainActor (GlobalShortcutAction) -> Void
    ) throws {}

    func unregisterAll() {}
}
