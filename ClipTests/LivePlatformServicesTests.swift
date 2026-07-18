import AppKit
import ClipCore
import ClipMedia
import Foundation
import Testing
@testable import Clip

@Suite("Live platform services", .serialized)
struct LivePlatformServicesTests {
    @MainActor
    @Test("Dock and login settings apply once and reconcile approval states")
    func applicationBehaviorIsIdempotent() throws {
        let probe = ApplicationBehaviorProbe()
        var settings = ClipSettings.defaults(
            homeDirectory: URL(fileURLWithPath: "/tmp/clip-application-behavior")
        )
        let service = probe.makeService()

        try service.apply(settings)
        try service.apply(settings)

        #expect(probe.activationPolicies == [.accessory])
        #expect(probe.registerCount == 0)
        #expect(probe.unregisterCount == 0)

        settings.showInDock = true
        settings.launchAtLogin = true
        probe.launchStatus = .requiresApproval
        try service.apply(settings)
        try service.apply(settings)

        #expect(probe.activationPolicies == [.accessory, .regular])
        #expect(probe.registerCount == 1)
        #expect(probe.unregisterCount == 0)

        settings.launchAtLogin = false
        probe.launchStatus = .requiresApproval
        try service.apply(settings)
        try service.apply(settings)

        #expect(probe.registerCount == 1)
        #expect(probe.unregisterCount == 1)
    }

    @MainActor
    @Test("Rejected Dock changes and failed login registration remain retryable")
    func applicationBehaviorFailuresRemainRetryable() throws {
        let probe = ApplicationBehaviorProbe()
        var settings = ClipSettings.defaults(
            homeDirectory: URL(fileURLWithPath: "/tmp/clip-application-behavior-retry")
        )
        settings.showInDock = true
        settings.launchAtLogin = true
        probe.acceptsActivationPolicy = false
        let service = probe.makeService()

        #expect(throws: ApplicationBehaviorError.activationPolicyRejected(showInDock: true)) {
            try service.apply(settings)
        }
        #expect(throws: ApplicationBehaviorError.activationPolicyRejected(showInDock: true)) {
            try service.apply(settings)
        }
        #expect(probe.activationPolicies == [.regular, .regular])
        #expect(probe.registerCount == 0)

        probe.acceptsActivationPolicy = true
        probe.registrationError = ApplicationBehaviorProbeError.registrationFailed
        #expect(throws: ApplicationBehaviorProbeError.registrationFailed) {
            try service.apply(settings)
        }
        #expect(throws: ApplicationBehaviorProbeError.registrationFailed) {
            try service.apply(settings)
        }
        #expect(probe.activationPolicies == [.regular, .regular, .regular])
        #expect(probe.registerCount == 2)
    }

    @MainActor
    @Test("Display discovery maps two screens by ID and keeps point-to-pixel geometry consistent")
    func displayDiscoveryMapsMultipleScreensByIdentity() async throws {
        let discovery = FixtureDisplayDiscovery(
            fixtures: [
                CaptureDisplay(
                    id: 22,
                    frame: CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440),
                    pixelWidth: 5_120,
                    pixelHeight: 2_880
                ),
                CaptureDisplay(
                    id: 11,
                    frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                    pixelWidth: 3_840,
                    pixelHeight: 2_160
                ),
            ]
        )
        let appKitDisplays = [
            LiveDisplayService.AppKitDisplaySnapshot(
                id: 11,
                name: "Built-in Display",
                frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
            ),
            LiveDisplayService.AppKitDisplaySnapshot(
                id: 22,
                name: "Studio Display",
                frame: CGRect(x: 1_920, y: -180, width: 2_048, height: 1_152)
            ),
        ]
        let service = LiveDisplayService(
            discovery: discovery,
            appKitDisplays: { appKitDisplays },
            stableIdentifier: { "stable-\($0)" }
        )

        let displays = try await service.availableDisplays()

        #expect(displays.map(\.id) == [22, 11])
        #expect(displays.map(\.name) == ["Studio Display", "Built-in Display"])
        #expect(displays.map(\.stableIdentifier) == ["stable-22", "stable-11"])
        #expect(displays[0].frame == appKitDisplays[1].frame)
        #expect(displays[0].scaleFactor == 2.5)
        #expect(displays[0].frame.width * displays[0].scaleFactor == 5_120)
        #expect(displays[1].scaleFactor == 2)
    }

    @MainActor
    @Test("A temporarily unmatched ScreenCaptureKit display remains selectable")
    func displayDiscoveryFallsBackWhenAppKitScreenIsUnavailable() async throws {
        let captureFrame = CGRect(x: -1_280, y: 0, width: 1_280, height: 720)
        let service = LiveDisplayService(
            discovery: FixtureDisplayDiscovery(
                fixtures: [
                    CaptureDisplay(
                        id: 77,
                        frame: captureFrame,
                        pixelWidth: 2_560,
                        pixelHeight: 1_440
                    ),
                ]
            ),
            appKitDisplays: { [] },
            stableIdentifier: { "detached-\($0)" }
        )

        let display = try #require(try await service.availableDisplays().first)

        #expect(display.id == 77)
        #expect(display.stableIdentifier == "detached-77")
        #expect(display.name == "Display")
        #expect(display.frame == captureFrame)
        #expect(display.scaleFactor == 2)
    }

    @MainActor
    @Test("Explicit capture retries screen access for a denied persisted state")
    func explicitCaptureRetriesDeniedScreenAccess() async throws {
        let suiteName = "com.tomaslejdung.clip.tests.permissions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let requestProbe = ScreenRecordingRequestProbe()
        let service = LivePermissionService(
            defaults: defaults,
            screenRecordingStatus: { .requiresApproval },
            requestScreenRecording: {
                requestProbe.requestCount += 1
                return requestProbe.isGranted
            }
        )

        #expect(service.currentStatus(for: .screenRecording) == .notDetermined)
        let firstRequest = await service.request(.screenRecording)
        #expect(firstRequest == .denied)
        #expect(requestProbe.requestCount == 1)
        #expect(service.currentStatus(for: .screenRecording) == .denied)

        let deniedPlan = ScreenRecordingPermissionPolicy.explicitCapturePlan(for: .denied)
        #expect(deniedPlan.shouldRequestAccess)
        #expect(!deniedPlan.shouldShowExplanation)

        requestProbe.isGranted = true
        let retry = await service.request(.screenRecording)
        #expect(retry == .granted)
        #expect(requestProbe.requestCount == 2)
    }

    @Test("Explicit capture permission policy preserves preflight authority")
    func explicitCapturePermissionPlans() {
        #expect(
            ScreenRecordingPermissionPolicy.explicitCapturePlan(for: .granted)
                == ExplicitScreenRecordingPermissionPlan(
                    canProceed: true,
                    shouldShowExplanation: false,
                    shouldRequestAccess: false
                )
        )
        #expect(
            ScreenRecordingPermissionPolicy.explicitCapturePlan(for: .notDetermined)
                == ExplicitScreenRecordingPermissionPlan(
                    canProceed: false,
                    shouldShowExplanation: true,
                    shouldRequestAccess: true
                )
        )
        #expect(
            ScreenRecordingPermissionPolicy.explicitCapturePlan(for: .denied)
                == ExplicitScreenRecordingPermissionPlan(
                    canProceed: false,
                    shouldShowExplanation: false,
                    shouldRequestAccess: true
                )
        )
        #expect(
            ScreenRecordingPermissionPolicy.explicitCapturePlan(for: .restricted)
                == ExplicitScreenRecordingPermissionPlan(
                    canProceed: false,
                    shouldShowExplanation: false,
                    shouldRequestAccess: false
                )
        )
    }

    @Test("Screen permission state uses CoreGraphics authorization as authority")
    func screenPermissionStatePolicy() {
        #expect(
            ScreenRecordingPermissionPolicy.currentState(
                authorizationStatus: .authorized,
                hasRequestedAccess: true
            ) == .granted
        )
        #expect(
            ScreenRecordingPermissionPolicy.currentState(
                authorizationStatus: .requiresApproval,
                hasRequestedAccess: false
            ) == .notDetermined
        )
        #expect(
            ScreenRecordingPermissionPolicy.currentState(
                authorizationStatus: .requiresApproval,
                hasRequestedAccess: true
            ) == .denied
        )
        #expect(
            ScreenRecordingPermissionPolicy.currentState(
                authorizationStatus: .restricted,
                hasRequestedAccess: false
            ) == .restricted
        )
    }

    @Test("Storage policy allows an unknown capacity estimate")
    func storagePolicyAllowsUnknownCapacity() {
        let policy = RecordingStorageCapacityPolicy(
            minimumStartCapacityBytes: 1_000,
            minimumActiveCapacityBytes: 500
        )

        #expect(policy.permitsStart(availableCapacityBytes: nil))
        #expect(!policy.requiresActiveStop(availableCapacityBytes: nil))
    }

    @Test("Storage policy applies inclusive start and active boundaries")
    func storagePolicyBoundaries() {
        let policy = RecordingStorageCapacityPolicy(
            minimumStartCapacityBytes: 1_000,
            minimumActiveCapacityBytes: 500
        )

        #expect(!policy.permitsStart(availableCapacityBytes: 999))
        #expect(policy.permitsStart(availableCapacityBytes: 1_000))
        #expect(policy.permitsStart(availableCapacityBytes: 1_001))
        #expect(policy.requiresActiveStop(availableCapacityBytes: 499))
        #expect(!policy.requiresActiveStop(availableCapacityBytes: 500))
        #expect(!policy.requiresActiveStop(availableCapacityBytes: 501))
    }

    @Test("Standard storage policy reserves space to finalize the MP4")
    func standardStoragePolicyThresholds() {
        let policy = RecordingStorageCapacityPolicy.standard

        #expect(policy.minimumStartCapacityBytes == 1_024 * 1_024 * 1_024)
        #expect(policy.minimumActiveCapacityBytes == 512 * 1_024 * 1_024)
        #expect(policy.minimumStartCapacityBytes > policy.minimumActiveCapacityBytes)
    }

    @MainActor
    @Test("Capture preparation rejects odd dimensions before recording configuration")
    func capturePreparationRejectsOddDimensions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = NativeCaptureService(
            recordingsDirectory: directory,
            capacityProvider: { _ in Int64.max }
        )
        let displayID = try DisplayID("odd-dimension-display")

        for dimensions in [(width: 101, height: 100), (width: 100, height: 101)] {
            let target = PreparedCaptureTarget(
                domainTarget: .fullscreen(displayID),
                displayID: 1,
                sourceRect: nil,
                outputWidth: dimensions.width,
                outputHeight: dimensions.height
            )
            do {
                try await service.prepare(target)
                Issue.record("Expected odd dimensions to be rejected")
            } catch NativeCaptureServiceError.invalidOutputDimensions {
                // Expected: callers must align dimensions before this boundary.
            } catch {
                Issue.record("Unexpected preparation error: \(error)")
            }
        }
    }

    @MainActor
    @Test("Capture refuses critically low capacity before requesting screen access")
    func captureRefusesLowCapacityBeforeStartingRecorder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let policy = RecordingStorageCapacityPolicy(
            minimumStartCapacityBytes: 1_000,
            minimumActiveCapacityBytes: 500
        )
        let service = NativeCaptureService(
            recordingsDirectory: directory,
            capacityPolicy: policy,
            capacityProvider: { _ in 999 }
        )
        let displayID = try DisplayID("capacity-test-display")
        try await service.prepare(
            PreparedCaptureTarget(
                domainTarget: .fullscreen(displayID),
                displayID: 1,
                sourceRect: nil,
                outputWidth: 100,
                outputHeight: 100
            )
        )

        do {
            try await service.start(
                recordingID: RecordingID(),
                settings: .defaults(homeDirectory: directory)
            )
            Issue.record("Expected start to be refused before ScreenCaptureKit was called")
        } catch NativeCaptureServiceError.insufficientStorage(
            let availableBytes,
            let requiredBytes
        ) {
            #expect(availableBytes == 999)
            #expect(requiredBytes == 1_000)
        } catch {
            Issue.record("Unexpected start error: \(error)")
        }
    }

    @MainActor
    @Test("Capture master uses the configured Crisp quality")
    func captureUsesConfiguredCrispQuality() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = FakeScreenRecorder(finishBehavior: .returnOutput)
        let service = NativeCaptureService(
            recordingsDirectory: directory,
            capacityProvider: { _ in Int64.max },
            recorderFactory: { eventHandler in
                recorder.eventHandler = eventHandler
                return recorder
            }
        )
        var settings = ClipSettings.defaults(homeDirectory: directory)
        settings.exportQualities.crisp = 73

        try await service.prepare(try captureTarget(named: "quality-display"))
        try await service.start(recordingID: RecordingID(), settings: settings)

        #expect(recorder.lastRequest?.configuration.videoQuality == 0.73)
        await service.cancel()
    }

    @MainActor
    @Test("A zero-frame finish removes output and recovery metadata")
    func zeroFrameFinishCleansCaptureFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = FakeScreenRecorder(finishBehavior: .noVideoFrames)
        let service = NativeCaptureService(
            recordingsDirectory: directory,
            capacityProvider: { _ in Int64.max },
            recorderFactory: { eventHandler in
                recorder.eventHandler = eventHandler
                return recorder
            }
        )
        let recordingID = RecordingID()
        try await service.prepare(try captureTarget(named: "zero-frame-display"))
        try await service.start(
            recordingID: recordingID,
            settings: .defaults(homeDirectory: directory)
        )

        let outputURL = try #require(recorder.lastRequest?.outputURL)
        let recoveryURL = CaptureRecoveryRecord.url(for: recordingID, in: directory)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(FileManager.default.fileExists(atPath: recoveryURL.path))

        do {
            _ = try await service.finish()
            Issue.record("Expected a zero-duration output error")
        } catch NativeCaptureServiceError.zeroDurationOutput {
            // Expected sanitized app-facing failure.
        } catch {
            Issue.record("Unexpected finish error: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
        #expect(!FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    @MainActor
    @Test("Low-disk monitoring ignores a stale session and emits once for the current session")
    func lowDiskMonitorIsCurrentSessionAndOneShot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = FakeScreenRecorder(finishBehavior: .returnOutput)
        let sleeper = ControlledCapacitySleeper()
        let capacities = CapacitySequence([1_000, 1_000, 0])
        let policy = RecordingStorageCapacityPolicy(
            minimumStartCapacityBytes: 100,
            minimumActiveCapacityBytes: 50
        )
        let service = NativeCaptureService(
            recordingsDirectory: directory,
            capacityPolicy: policy,
            capacityProvider: { _ in capacities.next() },
            capacityCheckInterval: .seconds(5),
            capacitySleep: { _ in await sleeper.sleep() },
            recorderFactory: { eventHandler in
                recorder.eventHandler = eventHandler
                return recorder
            }
        )
        var events = service.events.makeAsyncIterator()

        let staleID = RecordingID()
        try await service.prepare(try captureTarget(named: "stale-display"))
        try await service.start(
            recordingID: staleID,
            settings: .defaults(homeDirectory: directory)
        )
        await sleeper.waitForPendingCount(1)
        await service.cancel()

        let currentID = RecordingID()
        try await service.prepare(try captureTarget(named: "current-display"))
        try await service.start(
            recordingID: currentID,
            settings: .defaults(homeDirectory: directory)
        )
        await sleeper.waitForPendingCount(2)

        // The canceled monitor deliberately ignores task cancellation until
        // resumed. Its generation check must reject the now-stale session.
        await sleeper.resumeNext()
        await Task.yield()
        await sleeper.resumeNext()

        let nextEvent = await events.next()
        let event = try #require(nextEvent)
        switch event {
        case let .failure(sessionIdentifier, message):
            #expect(sessionIdentifier == currentID.rawValue)
            #expect(message.localizedCaseInsensitiveContains("disk space"))
        default:
            Issue.record("Expected one low-disk failure event, received \(event)")
        }
        for _ in 0..<5 {
            await Task.yield()
        }
        let pendingSleepCount = await sleeper.pendingCount
        #expect(pendingSleepCount == 0)
        #expect(capacities.callCount == 3)

        await service.cancel()
    }

    @MainActor
    @Test("Copy places a readable MP4 file URL on the pasteboard")
    func copiesFileURL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let videoURL = root.appendingPathComponent("clip-test.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.tomaslejdung.clip.tests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let service = LivePasteboardService(pasteboard: pasteboard)

        try service.placeFile(at: videoURL)

        let copiedURL = try #require(pasteboard.string(forType: .fileURL))
        #expect(URL(string: copiedURL)?.standardizedFileURL == videoURL.standardizedFileURL)
    }

    @MainActor
    @Test("Copy rejects files that are not MP4 videos")
    func rejectsUnsupportedFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).mov")
        try Data("fixture".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.tomaslejdung.clip.tests.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        let service = LivePasteboardService(pasteboard: pasteboard)

        #expect(throws: PasteboardServiceError.unsupportedFileType) {
            try service.placeFile(at: fileURL)
        }
    }
}

@MainActor
private final class ApplicationBehaviorProbe {
    var launchStatus: LaunchAtLoginRegistrationStatus = .disabled
    var acceptsActivationPolicy = true
    var registrationError: (any Error)?
    private(set) var activationPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    func makeService() -> ApplicationBehaviorService {
        ApplicationBehaviorService(
            setActivationPolicy: { [weak self] policy in
                guard let self else { return false }
                activationPolicies.append(policy)
                return acceptsActivationPolicy
            },
            launchAtLoginStatus: { [weak self] in
                self?.launchStatus ?? .disabled
            },
            registerLaunchAtLogin: { [weak self] in
                guard let self else { return }
                registerCount += 1
                if let registrationError { throw registrationError }
            },
            unregisterLaunchAtLogin: { [weak self] in
                self?.unregisterCount += 1
            }
        )
    }
}

private enum ApplicationBehaviorProbeError: Error, Equatable {
    case registrationFailed
}

private struct FixtureDisplayDiscovery: ScreenCaptureDiscovering {
    let fixtures: [CaptureDisplay]

    func displays() async throws -> [CaptureDisplay] {
        fixtures
    }
}

@MainActor
private final class ScreenRecordingRequestProbe {
    var requestCount = 0
    var isGranted = false
}

@MainActor
private final class FakeScreenRecorder: ScreenRecorderServicing {
    enum FinishBehavior {
        case noVideoFrames
        case returnOutput
    }

    var eventHandler: (@Sendable (ScreenRecorderEvent) -> Void)?
    private(set) var lastRequest: ScreenRecordingRequest?
    private let finishBehavior: FinishBehavior

    init(finishBehavior: FinishBehavior) {
        self.finishBehavior = finishBehavior
    }

    func start(_ request: ScreenRecordingRequest) async throws {
        lastRequest = request
        try Data("partial-capture".utf8).write(to: request.outputURL)
    }

    func pause() throws {}

    func resume() throws {}

    func finish() async throws -> URL {
        switch finishBehavior {
        case .noVideoFrames:
            throw ScreenRecorderError.noVideoFrames
        case .returnOutput:
            return try #require(lastRequest?.outputURL)
        }
    }

    func cancel() async throws {}
}

private actor ControlledCapacitySleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int {
        continuations.count
    }

    func sleep() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForPendingCount(_ expectedCount: Int) async {
        while continuations.count < expectedCount {
            await Task.yield()
        }
    }

    func resumeNext() {
        continuations.removeFirst().resume()
    }
}

@MainActor
private final class CapacitySequence {
    private var values: [Int64]
    private(set) var callCount = 0

    init(_ values: [Int64]) {
        self.values = values
    }

    func next() -> Int64? {
        callCount += 1
        return values.isEmpty ? nil : values.removeFirst()
    }
}

private func captureTarget(named displayName: String) throws -> PreparedCaptureTarget {
    let displayID = try DisplayID(displayName)
    return PreparedCaptureTarget(
        domainTarget: .fullscreen(displayID),
        displayID: 1,
        sourceRect: nil,
        outputWidth: 100,
        outputHeight: 100
    )
}
