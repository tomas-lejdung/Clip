import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import CoreGraphics
import Testing
@testable import Clip

@Suite("Local publication")
@MainActor
struct MeshParticipantLocalPublicationControllerTests {
    @Test
    func failedFullscreenStartLeavesNoGhostSource() async {
        var snapshots: [MeshParticipantLocalPublicationSnapshot] = []
        var failures: [String] = []
        let discovery = FixedMeshCaptureDiscovery(
            content: .init(
                displays: [
                    .init(
                        id: 41,
                        frame: CGRect(
                            x: 0,
                            y: 0,
                            width: 1_920,
                            height: 1_080
                        ),
                        pixelWidth: 1_920,
                        pixelHeight: 1_080
                    )
                ],
                windows: []
            )
        )
        let controller = MeshParticipantLocalPublicationController(
            settings: .default,
            discovery: discovery,
            maximumActiveSources:
                ClipLiveShareNativeV3
                    .defaultMaximumActiveSourcesPerParticipant,
            operations: .init(
                start: { _, _ in
                    throw MeshLocalPublicationFixtureError.startFailed
                },
                update: { _, _ in },
                stop: { _ in },
                stopAll: {},
                setSystemAudio: { _ in },
                applySettings: { _ in }
            ),
            persistSettings: { _ in },
            onChange: { snapshots.append($0) },
            onFailure: { failures.append($0) }
        )

        controller.start()
        controller.setFullscreenEnabled(true)
        await controller.settlePendingOperations()

        #expect(controller.activeSourceSnapshots.isEmpty)
        #expect(snapshots.last?.fullscreen.isOn == false)
        #expect(failures.count == 1)

        await controller.stop()
    }

    @Test("Auto Share retains four sources and replaces the least recently focused")
    func autoShareUsesDeterministicFocusRecency() async {
        let windows = (1...5).map { makeWindow($0) }
        let recorder = MeshLocalPublicationRecorder()
        let controller = makeController(
            settings: .init(autoShareFocusedWindows: true),
            windows: windows,
            recorder: recorder
        )
        controller.start()

        for window in windows.prefix(4) {
            controller.focusedWindowDidChange(focused(window))
            await controller.settlePendingOperations()
        }
        #expect(controller.activeSourceSnapshots.count == 4)

        controller.focusedWindowDidChange(focused(windows[0]))
        await controller.settlePendingOperations()
        controller.focusedWindowDidChange(focused(windows[4]))
        await controller.settlePendingOperations()

        #expect(controller.activeSourceSnapshots.count == 4)
        #expect(recorder.startedWindowIDs == [1, 2, 3, 4, 5])
        #expect(recorder.stoppedWindowIDs == [2])

        await controller.stop()
    }

    @Test("Auto Share never evicts a manually added source")
    func autoSharePreservesManualSources() async {
        let windows = (1...5).map { makeWindow($0) }
        let recorder = MeshLocalPublicationRecorder()
        var snapshots: [MeshParticipantLocalPublicationSnapshot] = []
        let controller = makeController(
            settings: .default,
            windows: windows,
            recorder: recorder,
            onChange: { snapshots.append($0) }
        )
        controller.start()
        controller.focusedWindowDidChange(focused(windows[0]))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()

        controller.updateSettings(
            .init(autoShareFocusedWindows: true)
        )
        await controller.settlePendingOperations()
        for window in windows.dropFirst().prefix(3) {
            controller.focusedWindowDidChange(focused(window))
            await controller.settlePendingOperations()
        }
        controller.focusedWindowDidChange(focused(windows[4]))
        await controller.settlePendingOperations()

        #expect(recorder.startedWindowIDs == [1, 2, 3, 4, 5])
        #expect(recorder.stoppedWindowIDs == [2])
        #expect(controller.activeSourceSnapshots.count == 4)
        #expect(snapshots.last?.settings.autoShareFocusedWindows == true)

        await controller.stop()
    }

    @Test("Asynchronous source failure removes only its ghost publication")
    func asynchronousSourceFailureRollsBackOneSource() async throws {
        let windows = (1...2).map { makeWindow($0) }
        let recorder = MeshLocalPublicationRecorder()
        var failures: [String] = []
        let controller = makeController(
            settings: .default,
            windows: windows,
            recorder: recorder,
            onFailure: { failures.append($0) }
        )
        controller.start()
        for window in windows {
            controller.focusedWindowDidChange(focused(window))
            await controller.settlePendingOperations()
            controller.shareFocusedWindow()
            await controller.settlePendingOperations()
        }
        let failed = try #require(recorder.starts.first)
        controller.captureSourceFailed(
            failed.instanceID,
            message: "The source stopped producing frames."
        )
        await controller.settlePendingOperations()

        #expect(controller.activeSourceSnapshots.count == 1)
        #expect(failures == ["The source stopped producing frames."])
        #expect(recorder.stops.isEmpty)

        await controller.stop()
    }

    @Test("System-audio failure disables audio without ending video")
    func systemAudioFailureRollsBackAudioOnly() async {
        let window = makeWindow(1)
        let recorder = MeshLocalPublicationRecorder()
        var persisted: [LiveShareSettings] = []
        var snapshots: [MeshParticipantLocalPublicationSnapshot] = []
        let controller = MeshParticipantLocalPublicationController(
            settings: .init(systemAudioEnabled: true),
            discovery: FixedMeshCaptureDiscovery(
                content: .init(displays: [], windows: [window])
            ),
            maximumActiveSources: 4,
            operations: recorder.operations,
            observesFocusedWindow: false,
            persistSettings: { persisted.append($0) },
            onChange: { snapshots.append($0) },
            onFailure: { _ in }
        )
        controller.start()
        controller.focusedWindowDidChange(focused(window))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        controller.systemAudioCaptureFailed(
            message: "System audio became unavailable."
        )
        await controller.settlePendingOperations()

        #expect(controller.activeSourceSnapshots.count == 1)
        #expect(snapshots.last?.settings.systemAudioEnabled == false)
        #expect(persisted.last?.systemAudioEnabled == false)

        await controller.stop()
    }

    @Test("Failed settings transaction rolls back and permits the same retry")
    func failedSettingsTransactionIsRetryable() async {
        var applied: [LiveShareSettings] = []
        var persisted: [LiveShareSettings] = []
        var snapshots: [MeshParticipantLocalPublicationSnapshot] = []
        var failures: [String] = []
        var rejectsFirstVP8Attempt = true
        let controller = MeshParticipantLocalPublicationController(
            settings: .default,
            discovery: FixedMeshCaptureDiscovery(
                content: .init(displays: [], windows: [])
            ),
            maximumActiveSources: 4,
            operations: .init(
                start: { _, _ in },
                update: { _, _ in },
                stop: { _ in },
                stopAll: {},
                setSystemAudio: { _ in },
                applySettings: { value in
                    applied.append(value)
                    if value.videoCodec == .vp8,
                       rejectsFirstVP8Attempt {
                        rejectsFirstVP8Attempt = false
                        throw MeshLocalPublicationFixtureError.settingsFailed
                    }
                }
            ),
            observesFocusedWindow: false,
            persistSettings: { persisted.append($0) },
            onChange: { snapshots.append($0) },
            onFailure: { failures.append($0) }
        )
        let requested = LiveShareSettingsViewSnapshot(
            codec: .init(codec: .vp8, acceleration: .software)
        )

        controller.start()
        controller.updateSettings(requested)
        await controller.settlePendingOperations()

        #expect(applied.map(\.videoCodec) == [.vp8, .av1])
        #expect(persisted.isEmpty)
        #expect(snapshots.last?.settings.codec.codec == .av1)
        #expect(failures.count == 1)

        controller.updateSettings(requested)
        await controller.settlePendingOperations()

        #expect(applied.map(\.videoCodec) == [.vp8, .av1, .vp8])
        #expect(persisted.map(\.videoCodec) == [.vp8])
        #expect(snapshots.last?.settings.codec.codec == .vp8)

        await controller.stop()
    }

    @Test("Rapid settings updates use their own media snapshots")
    func rapidSettingsUpdatesAreSnapshotIsolated() async throws {
        let window = makeWindow(1)
        var descriptorFrameRates: [Int] = []
        var applied: [LiveShareSettings] = []
        var persisted: [LiveShareSettings] = []
        var snapshots: [MeshParticipantLocalPublicationSnapshot] = []
        var failures: [String] = []
        let controller = MeshParticipantLocalPublicationController(
            settings: .default,
            discovery: FixedMeshCaptureDiscovery(
                content: .init(displays: [], windows: [window])
            ),
            maximumActiveSources: 4,
            operations: .init(
                start: { _, _ in },
                update: { _, descriptor in
                    descriptorFrameRates.append(
                        descriptor.video.framesPerSecond
                    )
                },
                stop: { _ in },
                stopAll: {},
                setSystemAudio: { _ in },
                applySettings: { value in
                    applied.append(value)
                    if value.videoCodec == .vp8 {
                        throw MeshLocalPublicationFixtureError.settingsFailed
                    }
                }
            ),
            observesFocusedWindow: false,
            persistSettings: { persisted.append($0) },
            onChange: { snapshots.append($0) },
            onFailure: { failures.append($0) }
        )
        controller.start()
        controller.focusedWindowDidChange(focused(window))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        descriptorFrameRates.removeAll()

        controller.updateSettings(.init(frameRate: .sixty))
        controller.updateSettings(
            .init(
                frameRate: .thirty,
                codec: .init(codec: .vp8, acceleration: .software)
            )
        )
        await controller.settlePendingOperations()

        #expect(applied.map(\.frameRate) == [.sixty, .thirty, .sixty])
        #expect(descriptorFrameRates == [60])
        #expect(persisted.map(\.frameRate) == [.sixty])
        #expect(snapshots.last?.settings.frameRate == .sixty)
        #expect(snapshots.last?.settings.codec.codec == .av1)
        #expect(failures.count == 1)

        await controller.stop()
    }

    @Test("Descriptor failure rolls back and permits the same retry")
    func failedDescriptorUpdateIsRetryable() async {
        let window = makeWindow(1)
        var descriptorFrameRates: [Int] = []
        var persisted: [LiveShareSettings] = []
        var snapshots: [MeshParticipantLocalPublicationSnapshot] = []
        var failures: [String] = []
        var rejectsFirstSixtyFPSUpdate = true
        let controller = MeshParticipantLocalPublicationController(
            settings: .default,
            discovery: FixedMeshCaptureDiscovery(
                content: .init(displays: [], windows: [window])
            ),
            maximumActiveSources: 4,
            operations: .init(
                start: { _, _ in },
                update: { _, descriptor in
                    descriptorFrameRates.append(
                        descriptor.video.framesPerSecond
                    )
                    if descriptor.video.framesPerSecond == 60,
                       rejectsFirstSixtyFPSUpdate {
                        rejectsFirstSixtyFPSUpdate = false
                        throw MeshLocalPublicationFixtureError.settingsFailed
                    }
                },
                stop: { _ in },
                stopAll: {},
                setSystemAudio: { _ in },
                applySettings: { _ in }
            ),
            observesFocusedWindow: false,
            persistSettings: { persisted.append($0) },
            onChange: { snapshots.append($0) },
            onFailure: { failures.append($0) }
        )
        controller.start()
        controller.focusedWindowDidChange(focused(window))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        descriptorFrameRates.removeAll()
        let requested = LiveShareSettingsViewSnapshot(frameRate: .sixty)

        controller.updateSettings(requested)
        await controller.settlePendingOperations()

        #expect(descriptorFrameRates == [60])
        #expect(persisted.isEmpty)
        #expect(snapshots.last?.settings.frameRate == .thirty)
        #expect(failures.count == 1)

        controller.updateSettings(requested)
        await controller.settlePendingOperations()

        #expect(descriptorFrameRates == [60, 60])
        #expect(persisted.map(\.frameRate) == [.sixty])
        #expect(snapshots.last?.settings.frameRate == .sixty)

        await controller.stop()
    }

    @Test("Audio failure does not clobber a later optimistic settings request")
    func audioFailurePreservesLaterOptimisticRequest() async {
        let window = makeWindow(1)
        var audioRequests: [CaptureAudioSessionRequest?] = []
        var persisted: [LiveShareSettings] = []
        var snapshots: [MeshParticipantLocalPublicationSnapshot] = []
        var failures: [String] = []
        var rejectsFirstEnable = true
        let controller = MeshParticipantLocalPublicationController(
            settings: .default,
            discovery: FixedMeshCaptureDiscovery(
                content: .init(displays: [], windows: [window])
            ),
            maximumActiveSources: 4,
            operations: .init(
                start: { _, _ in },
                update: { _, _ in },
                stop: { _ in },
                stopAll: {},
                setSystemAudio: { request in
                    audioRequests.append(request)
                    if request != nil, rejectsFirstEnable {
                        rejectsFirstEnable = false
                        throw MeshLocalPublicationFixtureError.settingsFailed
                    }
                },
                applySettings: { _ in }
            ),
            observesFocusedWindow: false,
            persistSettings: { persisted.append($0) },
            onChange: { snapshots.append($0) },
            onFailure: { failures.append($0) }
        )
        controller.start()
        controller.focusedWindowDidChange(focused(window))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        audioRequests.removeAll()

        controller.updateSettings(.init(systemAudioEnabled: true))
        controller.updateSettings(
            .init(frameRate: .sixty, systemAudioEnabled: true)
        )
        await controller.settlePendingOperations()

        #expect(audioRequests.map { $0 != nil } == [true, false, true])
        #expect(persisted.map(\.systemAudioEnabled) == [false, true])
        #expect(snapshots.last?.settings.systemAudioEnabled == true)
        #expect(snapshots.last?.settings.frameRate == .sixty)
        #expect(failures.count == 1)

        await controller.stop()
    }

    @Test("Capture failure commits audio off without clobbering a later retry")
    func captureAudioFailurePreservesLaterRetry() async {
        var persisted: [LiveShareSettings] = []
        var snapshots: [MeshParticipantLocalPublicationSnapshot] = []
        var failures: [String] = []
        let controller = MeshParticipantLocalPublicationController(
            settings: .init(systemAudioEnabled: true),
            discovery: FixedMeshCaptureDiscovery(
                content: .init(displays: [], windows: [])
            ),
            maximumActiveSources: 4,
            operations: .init(
                start: { _, _ in },
                update: { _, _ in },
                stop: { _ in },
                stopAll: {},
                setSystemAudio: { _ in },
                applySettings: { _ in }
            ),
            observesFocusedWindow: false,
            persistSettings: { persisted.append($0) },
            onChange: { snapshots.append($0) },
            onFailure: { failures.append($0) }
        )
        controller.start()

        controller.systemAudioCaptureFailed(
            message: "System audio became unavailable."
        )
        controller.updateSettings(
            .init(frameRate: .sixty, systemAudioEnabled: true)
        )
        await controller.settlePendingOperations()

        #expect(persisted.map(\.systemAudioEnabled) == [false, true])
        #expect(snapshots.last?.settings.systemAudioEnabled == true)
        #expect(snapshots.last?.settings.frameRate == .sixty)
        #expect(failures == ["System audio became unavailable."])

        await controller.stop()
    }

    @Test("Re-sharing the same window creates a fresh source generation")
    func resharingWindowUsesFreshSourceInstanceID() async throws {
        let window = makeWindow(1)
        let recorder = MeshLocalPublicationRecorder()
        let controller = makeController(
            settings: .default,
            windows: [window],
            recorder: recorder
        )
        controller.start()
        controller.focusedWindowDidChange(focused(window))
        await controller.settlePendingOperations()

        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        let first = try #require(recorder.starts.last?.instanceID)

        controller.stopSource(first)
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        let second = try #require(recorder.starts.last?.instanceID)

        #expect(first != second)
        #expect(recorder.starts.count == 2)
        #expect(recorder.stops == [first])
        #expect(controller.activeSourceSnapshots.map(\.id) == [second.rawValue])

        await controller.stop()
    }

    @Test("An off-Space window freezes without changing its publication identity")
    func offSpaceWindowKeepsPublicationAndResumesInPlace() async throws {
        let initial = makeWindow(1)
        let hidden = makeWindow(
            1,
            isOnScreen: false,
            pointWidth: 1_200,
            pointHeight: 700,
            pixelWidth: 2_400,
            pixelHeight: 1_400
        )
        let returned = makeWindow(
            1,
            pointWidth: 1_000,
            pointHeight: 700,
            pixelWidth: 2_000,
            pixelHeight: 1_400
        )
        let discovery = MutableMeshCaptureDiscovery(
            content: .init(displays: [], windows: [initial])
        )
        let recorder = MeshLocalPublicationRecorder()
        var snapshots: [MeshParticipantLocalPublicationSnapshot] = []
        let controller = makeLifecycleController(
            discovery: discovery,
            recorder: recorder,
            onChange: { snapshots.append($0) }
        )
        controller.start()
        await controller.refreshShareableContent()
        controller.focusedWindowDidChange(focused(initial))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        let originalStart = try #require(recorder.starts.first)
        recorder.updates.removeAll()

        await discovery.setContent(
            .init(displays: [], windows: [hidden])
        )
        await controller.refreshShareableContent()

        #expect(controller.activeSourceSnapshots.map(\.id) == [
            originalStart.instanceID.rawValue
        ])
        #expect(recorder.starts.count == 1)
        #expect(recorder.updates.isEmpty)
        #expect(recorder.stops.isEmpty)
        #expect(snapshots.last?.availableWindows.isEmpty == true)

        await discovery.setContent(
            .init(displays: [], windows: [returned])
        )
        await controller.refreshShareableContent()

        let resumed = try #require(recorder.updates.last)
        #expect(resumed.instanceID == originalStart.instanceID)
        #expect(resumed.descriptor.stream.id
            == originalStart.descriptor.stream.id)
        #expect(resumed.descriptor.stream.mediaTrackID
            == originalStart.descriptor.stream.mediaTrackID)
        #expect(resumed.descriptor.sourcePixelWidth == returned.pixelWidth)
        #expect(resumed.descriptor.sourcePixelHeight == returned.pixelHeight)
        #expect(recorder.starts.count == 1)
        #expect(recorder.stops.isEmpty)

        await controller.stop()
    }

    @Test("A genuinely closed window stops once after confirmed inventory misses")
    func closedWindowStopsAfterConsecutiveMisses() async throws {
        let window = makeWindow(1)
        let discovery = MutableMeshCaptureDiscovery(
            content: .init(displays: [], windows: [window])
        )
        let recorder = MeshLocalPublicationRecorder()
        let controller = makeLifecycleController(
            discovery: discovery,
            recorder: recorder,
            windowClosureConfirmationCount: 3
        )
        controller.start()
        await controller.refreshShareableContent()
        controller.focusedWindowDidChange(focused(window))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        let instanceID = try #require(recorder.starts.first?.instanceID)
        await discovery.setContent(.init(displays: [], windows: []))

        for _ in 0..<2 {
            await controller.refreshShareableContent()
            #expect(controller.activeSourceSnapshots.count == 1)
            #expect(recorder.stops.isEmpty)
        }
        await controller.refreshShareableContent()
        await controller.refreshShareableContent()

        #expect(controller.activeSourceSnapshots.isEmpty)
        #expect(recorder.stops == [instanceID])

        await controller.stop()
    }

    @Test("Window presence resets the closure confirmation counter")
    func retainedWindowResetsConsecutiveMisses() async {
        let window = makeWindow(1)
        let hidden = makeWindow(1, isOnScreen: false)
        let discovery = MutableMeshCaptureDiscovery(
            content: .init(displays: [], windows: [window])
        )
        let recorder = MeshLocalPublicationRecorder()
        let controller = makeLifecycleController(
            discovery: discovery,
            recorder: recorder,
            windowClosureConfirmationCount: 3
        )
        controller.start()
        await controller.refreshShareableContent()
        controller.focusedWindowDidChange(focused(window))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()

        await discovery.setContent(.init(displays: [], windows: []))
        await controller.refreshShareableContent()
        await controller.refreshShareableContent()
        await discovery.setContent(.init(displays: [], windows: [hidden]))
        await controller.refreshShareableContent()
        await discovery.setContent(.init(displays: [], windows: []))
        await controller.refreshShareableContent()
        await controller.refreshShareableContent()

        #expect(controller.activeSourceSnapshots.count == 1)
        #expect(recorder.stops.isEmpty)

        await controller.stop()
    }

    @Test("A recycled window ID does not retain the closed source")
    func recycledWindowIDRequiresMatchingProcessAndBundle() async throws {
        let original = makeWindow(1)
        let replacement = makeWindow(
            1,
            processID: 9_001,
            bundleIdentifier: "com.example.replacement"
        )
        let discovery = MutableMeshCaptureDiscovery(
            content: .init(displays: [], windows: [original])
        )
        let recorder = MeshLocalPublicationRecorder()
        let controller = makeLifecycleController(
            discovery: discovery,
            recorder: recorder,
            windowClosureConfirmationCount: 2
        )
        controller.start()
        await controller.refreshShareableContent()
        controller.focusedWindowDidChange(focused(original))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        let instanceID = try #require(recorder.starts.first?.instanceID)

        await discovery.setContent(
            .init(displays: [], windows: [replacement])
        )
        await controller.refreshShareableContent()
        #expect(controller.activeSourceSnapshots.count == 1)
        await controller.refreshShareableContent()

        #expect(controller.activeSourceSnapshots.isEmpty)
        #expect(recorder.stops == [instanceID])

        await controller.stop()
    }

    @Test("Discovery errors never destroy an active publication")
    func discoveryErrorsAreNonDestructive() async {
        let window = makeWindow(1)
        let discovery = MutableMeshCaptureDiscovery(
            content: .init(displays: [], windows: [window])
        )
        let recorder = MeshLocalPublicationRecorder()
        let controller = makeLifecycleController(
            discovery: discovery,
            recorder: recorder,
            windowClosureConfirmationCount: 2
        )
        controller.start()
        await controller.refreshShareableContent()
        controller.focusedWindowDidChange(focused(window))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()

        await discovery.setFailsDiscovery(true)
        for _ in 0..<4 {
            await controller.refreshShareableContent()
        }

        #expect(controller.activeSourceSnapshots.count == 1)
        #expect(recorder.stops.isEmpty)

        await discovery.setFailsDiscovery(false)
        await discovery.setContent(
            .init(
                displays: [],
                windows: [makeWindow(1, isOnScreen: false)]
            )
        )
        await controller.refreshShareableContent()
        #expect(controller.activeSourceSnapshots.count == 1)
        #expect(recorder.stops.isEmpty)

        await controller.stop()
    }

    @Test("Explicit stop remains immediate while a window is off-Space")
    func explicitStopWhileFrozenIsImmediate() async throws {
        let window = makeWindow(1)
        let discovery = MutableMeshCaptureDiscovery(
            content: .init(displays: [], windows: [window])
        )
        let recorder = MeshLocalPublicationRecorder()
        let controller = makeLifecycleController(
            discovery: discovery,
            recorder: recorder,
            windowClosureConfirmationCount: 3
        )
        controller.start()
        await controller.refreshShareableContent()
        controller.focusedWindowDidChange(focused(window))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        let instanceID = try #require(recorder.starts.first?.instanceID)

        await discovery.setContent(
            .init(
                displays: [],
                windows: [makeWindow(1, isOnScreen: false)]
            )
        )
        await controller.refreshShareableContent()
        controller.stopSource(instanceID)
        await controller.settlePendingOperations()

        #expect(controller.activeSourceSnapshots.isEmpty)
        #expect(recorder.stops == [instanceID])

        await controller.stop()
    }

    @Test("Fullscreen display disappearance keeps its existing immediate behavior")
    func fullscreenDisplayDisappearanceStopsImmediately() async throws {
        let display = ShareableCaptureDisplay(
            id: 41,
            frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        let discovery = MutableMeshCaptureDiscovery(
            content: .init(displays: [display], windows: [])
        )
        let recorder = MeshLocalPublicationRecorder()
        let controller = makeLifecycleController(
            discovery: discovery,
            recorder: recorder
        )
        controller.start()
        await controller.refreshShareableContent()
        controller.setFullscreenEnabled(true)
        await controller.settlePendingOperations()
        let instanceID = try #require(recorder.starts.first?.instanceID)

        await discovery.setContent(.init(displays: [], windows: []))
        await controller.refreshShareableContent()

        #expect(controller.activeSourceSnapshots.isEmpty)
        #expect(recorder.stops == [instanceID])

        await controller.stop()
    }

    @Test("Explicit stop during a suspended descriptor update cannot resurrect its source")
    func stopDuringSuspendedDescriptorUpdateDoesNotResurrect() async throws {
        let initial = makeWindow(1)
        let resized = makeWindow(
            1,
            pointWidth: 1_000,
            pointHeight: 700,
            pixelWidth: 2_000,
            pixelHeight: 1_400
        )
        let discovery = MutableMeshCaptureDiscovery(
            content: .init(displays: [], windows: [initial])
        )
        let updateGate = SuspendedMeshDescriptorUpdate()
        var starts: [ClipLiveShareSourceInstanceID] = []
        var stops: [ClipLiveShareSourceInstanceID] = []
        var updateCount = 0
        let controller = MeshParticipantLocalPublicationController(
            settings: .default,
            discovery: discovery,
            maximumActiveSources: 4,
            operations: .init(
                start: { instanceID, _ in starts.append(instanceID) },
                update: { _, _ in
                    updateCount += 1
                    await updateGate.suspendOnce()
                },
                stop: { stops.append($0) },
                stopAll: {},
                setSystemAudio: { _ in },
                applySettings: { _ in }
            ),
            observesFocusedWindow: false,
            refreshInterval: nil,
            persistSettings: { _ in },
            onChange: { _ in },
            onFailure: { _ in }
        )
        controller.start()
        await controller.refreshShareableContent()
        controller.focusedWindowDidChange(focused(initial))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        let instanceID = try #require(starts.first)

        await discovery.setContent(
            .init(displays: [], windows: [resized])
        )
        let refresh = Task { @MainActor in
            await controller.refreshShareableContent()
        }
        await updateGate.waitUntilSuspended()

        controller.stopSource(instanceID)
        #expect(controller.activeSourceSnapshots.count == 1)
        #expect(stops.isEmpty)

        updateGate.resume()
        await refresh.value
        await controller.settlePendingOperations()

        #expect(updateCount == 1)
        #expect(starts == [instanceID])
        #expect(stops == [instanceID])
        #expect(controller.activeSourceSnapshots.isEmpty)

        await controller.stop()
    }

    @Test("Focus changes serialize behind a periodic geometry update")
    func focusChangeSerializesBehindPeriodicResize() async throws {
        let initial = makeWindow(1)
        let resized = makeWindow(
            1,
            pointWidth: 1_000,
            pointHeight: 700,
            pixelWidth: 2_000,
            pixelHeight: 1_400
        )
        let discovery = MutableMeshCaptureDiscovery(
            content: .init(displays: [], windows: [initial])
        )
        let updateGate = SuspendedMeshDescriptorUpdate()
        var starts: [(
            ClipLiveShareSourceInstanceID,
            LiveShareCaptureDescriptor
        )] = []
        var updates: [LiveShareCaptureDescriptor] = []
        let controller = MeshParticipantLocalPublicationController(
            settings: .default,
            discovery: discovery,
            maximumActiveSources: 4,
            operations: .init(
                start: { starts.append(($0, $1)) },
                update: { _, descriptor in
                    updates.append(descriptor)
                    await updateGate.suspendOnce()
                },
                stop: { _ in },
                stopAll: {},
                setSystemAudio: { _ in },
                applySettings: { _ in }
            ),
            observesFocusedWindow: false,
            refreshInterval: nil,
            persistSettings: { _ in },
            onChange: { _ in },
            onFailure: { _ in }
        )
        controller.start()
        await controller.refreshShareableContent()
        controller.focusedWindowDidChange(focused(initial))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()
        let start = try #require(starts.first)

        await discovery.setContent(
            .init(displays: [], windows: [resized])
        )
        let refresh = Task { @MainActor in
            await controller.refreshShareableContent()
        }
        await updateGate.waitUntilSuspended()

        controller.focusedWindowDidChange(nil)
        updateGate.resume()
        await refresh.value
        await controller.settlePendingOperations()

        #expect(updates.count == 2)
        #expect(updates[0].sourcePixelWidth == resized.pixelWidth)
        #expect(updates[0].sourcePixelHeight == resized.pixelHeight)
        #expect(updates[0].stream.focused)
        #expect(updates[1].sourcePixelWidth == resized.pixelWidth)
        #expect(updates[1].sourcePixelHeight == resized.pixelHeight)
        #expect(!updates[1].stream.focused)
        #expect(updates[1].stream.id == start.1.stream.id)
        #expect(
            updates[1].stream.mediaTrackID
                == start.1.stream.mediaTrackID
        )
        #expect(controller.activeSourceSnapshots.first?.isFocused == false)

        await controller.stop()
    }

    @Test("Focus changes wait for periodic closure reconciliation")
    func focusChangeWaitsForPeriodicClosure() async throws {
        let window = makeWindow(1)
        let discovery = MutableMeshCaptureDiscovery(
            content: .init(displays: [], windows: [window])
        )
        let stopGate = SuspendedMeshDescriptorUpdate()
        var updates: [LiveShareCaptureDescriptor] = []
        var stops: [ClipLiveShareSourceInstanceID] = []
        let controller = MeshParticipantLocalPublicationController(
            settings: .default,
            discovery: discovery,
            maximumActiveSources: 4,
            operations: .init(
                start: { _, _ in },
                update: { _, descriptor in updates.append(descriptor) },
                stop: { instanceID in
                    stops.append(instanceID)
                    await stopGate.suspendOnce()
                },
                stopAll: {},
                setSystemAudio: { _ in },
                applySettings: { _ in }
            ),
            observesFocusedWindow: false,
            refreshInterval: nil,
            windowClosureConfirmationCount: 1,
            persistSettings: { _ in },
            onChange: { _ in },
            onFailure: { _ in }
        )
        controller.start()
        await controller.refreshShareableContent()
        controller.focusedWindowDidChange(focused(window))
        await controller.settlePendingOperations()
        controller.shareFocusedWindow()
        await controller.settlePendingOperations()

        await discovery.setContent(.init(displays: [], windows: []))
        let refresh = Task { @MainActor in
            await controller.refreshShareableContent()
        }
        await stopGate.waitUntilSuspended()

        controller.focusedWindowDidChange(nil)
        stopGate.resume()
        await refresh.value
        await controller.settlePendingOperations()

        #expect(stops.count == 1)
        #expect(updates.isEmpty)
        #expect(controller.activeSourceSnapshots.isEmpty)

        await controller.stop()
    }

    private func makeController(
        settings: LiveShareSettings,
        windows: [ShareableCaptureWindow],
        recorder: MeshLocalPublicationRecorder,
        onChange: @escaping (MeshParticipantLocalPublicationSnapshot) -> Void = {
            _ in
        },
        onFailure: @escaping (String) -> Void = { _ in }
    ) -> MeshParticipantLocalPublicationController {
        MeshParticipantLocalPublicationController(
            settings: settings,
            discovery: FixedMeshCaptureDiscovery(
                content: .init(displays: [], windows: windows)
            ),
            maximumActiveSources: 4,
            operations: recorder.operations,
            observesFocusedWindow: false,
            persistSettings: { _ in },
            onChange: onChange,
            onFailure: onFailure
        )
    }

    private func makeLifecycleController(
        discovery: any CaptureContentDiscovering,
        recorder: MeshLocalPublicationRecorder,
        windowClosureConfirmationCount: Int = 3,
        onChange: @escaping (MeshParticipantLocalPublicationSnapshot) -> Void = {
            _ in
        }
    ) -> MeshParticipantLocalPublicationController {
        MeshParticipantLocalPublicationController(
            settings: .default,
            discovery: discovery,
            maximumActiveSources: 4,
            operations: recorder.operations,
            observesFocusedWindow: false,
            refreshInterval: nil,
            windowClosureConfirmationCount: windowClosureConfirmationCount,
            persistSettings: { _ in },
            onChange: onChange,
            onFailure: { _ in }
        )
    }

    private func makeWindow(
        _ value: Int,
        isOnScreen: Bool = true,
        processID: pid_t? = nil,
        bundleIdentifier: String? = nil,
        pointWidth: Int = 800,
        pointHeight: Int = 600,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) -> ShareableCaptureWindow {
        .init(
            id: CGWindowID(value),
            frame: CGRect(
                x: value * 20,
                y: 20,
                width: pointWidth,
                height: pointHeight
            ),
            title: "Window \(value)",
            applicationName: "Fixture \(value)",
            bundleIdentifier:
                bundleIdentifier ?? "com.example.fixture\(value)",
            processID: processID ?? pid_t(1_000 + value),
            isOnScreen: isOnScreen,
            capturePointWidth: pointWidth,
            capturePointHeight: pointHeight,
            pixelWidth: pixelWidth ?? pointWidth,
            pixelHeight: pixelHeight ?? pointHeight
        )
    }

    private func focused(
        _ window: ShareableCaptureWindow
    ) -> FocusedLiveShareWindow {
        .init(window: window, appKitFrame: window.frame)
    }
}

private enum MeshLocalPublicationFixtureError: Error {
    case startFailed
    case settingsFailed
    case discoveryFailed
}

private struct FixedMeshCaptureDiscovery: CaptureContentDiscovering {
    let content: ShareableCaptureContent

    func shareableContent(
        excludingBundleIdentifier: String?,
        windowScope: CaptureWindowDiscoveryScope
    ) async throws -> ShareableCaptureContent {
        _ = excludingBundleIdentifier
        switch windowScope {
        case .onScreenOnly:
            return .init(
                displays: content.displays,
                windows: content.visibleWindows
            )
        case .allWindows:
            return content
        }
    }
}

private actor MutableMeshCaptureDiscovery: CaptureContentDiscovering {
    private var content: ShareableCaptureContent
    private var failsDiscovery = false

    init(content: ShareableCaptureContent) {
        self.content = content
    }

    func setContent(_ content: ShareableCaptureContent) {
        self.content = content
    }

    func setFailsDiscovery(_ failsDiscovery: Bool) {
        self.failsDiscovery = failsDiscovery
    }

    func shareableContent(
        excludingBundleIdentifier: String?
    ) async throws -> ShareableCaptureContent {
        try await shareableContent(
            excludingBundleIdentifier: excludingBundleIdentifier,
            windowScope: .onScreenOnly
        )
    }

    func shareableContent(
        excludingBundleIdentifier: String?,
        windowScope: CaptureWindowDiscoveryScope
    ) async throws -> ShareableCaptureContent {
        _ = excludingBundleIdentifier
        guard !failsDiscovery else {
            throw MeshLocalPublicationFixtureError.discoveryFailed
        }
        switch windowScope {
        case .onScreenOnly:
            return .init(
                displays: content.displays,
                windows: content.visibleWindows
            )
        case .allWindows:
            return content
        }
    }
}

@MainActor
private final class SuspendedMeshDescriptorUpdate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didSuspend = false

    func suspendOnce() async {
        guard !didSuspend else { return }
        didSuspend = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class MeshLocalPublicationRecorder {
    struct Start {
        let instanceID: ClipLiveShareSourceInstanceID
        let windowID: CGWindowID?
        let descriptor: LiveShareCaptureDescriptor
    }

    struct Update {
        let instanceID: ClipLiveShareSourceInstanceID
        let descriptor: LiveShareCaptureDescriptor
    }

    var starts: [Start] = []
    var updates: [Update] = []
    var stops: [ClipLiveShareSourceInstanceID] = []
    private var windowIDByInstance:
        [ClipLiveShareSourceInstanceID: CGWindowID] = [:]

    var startedWindowIDs: [CGWindowID] {
        starts.compactMap(\.windowID)
    }

    var stoppedWindowIDs: [CGWindowID] {
        stops.compactMap { windowIDByInstance[$0] }
    }

    var operations: MeshParticipantLocalPublicationOperations {
        .init(
            start: { [weak self] instanceID, descriptor in
                let windowID: CGWindowID? = if case let .window(source) =
                    descriptor.source {
                    source.id.rawValue
                } else {
                    nil
                }
                self?.starts.append(.init(
                    instanceID: instanceID,
                    windowID: windowID,
                    descriptor: descriptor
                ))
                if let windowID {
                    self?.windowIDByInstance[instanceID] = windowID
                }
            },
            update: { [weak self] instanceID, descriptor in
                self?.updates.append(.init(
                    instanceID: instanceID,
                    descriptor: descriptor
                ))
            },
            stop: { [weak self] in self?.stops.append($0) },
            stopAll: {},
            setSystemAudio: { _ in },
            applySettings: { _ in }
        )
    }
}
