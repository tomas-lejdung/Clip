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
        let windows = (1...5).map(makeWindow)
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
        let windows = (1...5).map(makeWindow)
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
        let windows = (1...2).map(makeWindow)
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

    private func makeWindow(_ value: Int) -> ShareableCaptureWindow {
        .init(
            id: CGWindowID(value),
            frame: CGRect(x: value * 20, y: 20, width: 800, height: 600),
            title: "Window \(value)",
            applicationName: "Fixture \(value)",
            bundleIdentifier: "com.example.fixture\(value)",
            processID: pid_t(1_000 + value),
            pixelWidth: 800,
            pixelHeight: 600
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
}

private struct FixedMeshCaptureDiscovery: CaptureContentDiscovering {
    let content: ShareableCaptureContent

    func shareableContent(
        excludingBundleIdentifier: String?
    ) async throws -> ShareableCaptureContent {
        _ = excludingBundleIdentifier
        return content
    }
}

@MainActor
private final class MeshLocalPublicationRecorder {
    struct Start {
        let instanceID: ClipLiveShareSourceInstanceID
        let windowID: CGWindowID?
    }

    var starts: [Start] = []
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
                    windowID: windowID
                ))
                if let windowID {
                    self?.windowIDByInstance[instanceID] = windowID
                }
            },
            update: { _, _ in },
            stop: { [weak self] in self?.stops.append($0) },
            stopAll: {},
            setSystemAudio: { _ in },
            applySettings: { _ in }
        )
    }
}
