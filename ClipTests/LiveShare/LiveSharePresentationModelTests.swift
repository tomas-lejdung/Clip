import Foundation
import Testing
@testable import Clip

@Suite("Live Share presentation")
@MainActor
struct LiveSharePresentationModelTests {
    @Test
    func testQualityLadderMatchesGoPeepV1() {
        #expect(
            LiveShareQualityPreset.allCases.map(\.bitsPerSecond) == [
                500_000,
                1_500_000,
                3_000_000,
                6_000_000,
                10_000_000,
                15_000_000,
                20_000_000,
                50_000_000,
            ]
        )
        #expect(LiveShareQualityPreset.veryHigh.bitrateText == "6 Mbps")
        #expect(LiveShareFrameRate.allCases.map(\.rawValue) == [15, 30, 60])
    }

    @Test
    func testSnapshotAlwaysPublishesFourStableSourceSlots() {
        let snapshot = LiveShareViewSnapshot(
            phase: .ready,
            slots: [
                .init(index: 2, state: .live),
                .init(index: 2, state: .starting),
                .init(index: 9, state: .live),
            ]
        )

        #expect(snapshot.slots.map(\.index) == [0, 1, 2, 3])
        #expect(snapshot.slots.map(\.state) == [.empty, .empty, .starting, .empty])
        #expect(snapshot.hasActiveMedia)
    }

    @Test
    func testOnlyConnectedWebRTCPeersCountAsViewers() {
        let snapshot = LiveShareViewSnapshot(
            phase: .ready,
            viewers: [
                .init(id: "connecting", connection: .connecting, connectedDuration: nil),
                .init(id: "unknown-route", connection: .connected, connectedDuration: 1),
                .init(id: "direct", connection: .peerToPeer, connectedDuration: 2),
                .init(id: "relay", connection: .turn, connectedDuration: 4),
                .init(id: "gone", connection: .disconnected, connectedDuration: nil),
            ]
        )

        #expect(snapshot.connectedViewerCount == 3)
        #expect(LiveShareViewerConnection.connected.title == "Connected")
        #expect(LiveShareViewerConnection.connected.title != "P2P")
    }

    @Test
    func testCodecDoesNotClaimAccelerationUntilRuntimeReportsIt() {
        let unverified = LiveShareCodecViewSnapshot()
        #expect(unverified.codec == .vp8)
        #expect(unverified.name == "VP8")
        #expect(unverified.acceleration == .unknown)
        #expect(unverified.detail == "Encoder selected automatically")
        #expect(unverified.detail != "Hardware accelerated")

        let verified = LiveShareCodecViewSnapshot(codec: .vp8, acceleration: .software)
        #expect(verified.name == "VP8")
        #expect(verified.detail == "Software encoding")
    }

    @Test
    func testCodecAndFocusedWindowPriorityCanChangeDuringLiveSharing() {
        var codecChanges: [LiveShareVideoCodec] = []
        var priorityChanges: [Bool] = []
        let model = LiveSharePresentationModel(
            snapshot: LiveShareViewSnapshot(
                phase: .live(elapsedSeconds: 12),
                settings: .init(
                    codec: .init(codec: .h264, acceleration: .hardware),
                    prioritizeFocusedWindow: true,
                    canChangeCodec: true,
                    canChangePrioritizeFocusedWindow: true
                )
            ),
            actions: .init(
                setCodec: { codecChanges.append($0) },
                setPrioritizeFocusedWindow: { priorityChanges.append($0) }
            )
        )

        model.setCodec(.vp8)
        model.setPrioritizeFocusedWindow(false)

        #expect(codecChanges == [.vp8])
        #expect(priorityChanges == [false])
    }

    @Test
    func testCodecAndFocusedWindowPriorityRespectCapabilityGates() {
        var codecChanges: [LiveShareVideoCodec] = []
        var priorityChanges: [Bool] = []
        let model = LiveSharePresentationModel(
            snapshot: LiveShareViewSnapshot(
                phase: .reconnecting(attempt: 1, maximumAttempts: 5),
                settings: .init(
                    canChangeCodec: false,
                    canChangePrioritizeFocusedWindow: false
                )
            ),
            actions: .init(
                setCodec: { codecChanges.append($0) },
                setPrioritizeFocusedWindow: { priorityChanges.append($0) }
            )
        )

        model.setCodec(.vp8)
        model.setPrioritizeFocusedWindow(false)

        #expect(codecChanges.isEmpty)
        #expect(priorityChanges.isEmpty)
    }

    @Test
    func testSystemAudioToggleUsesPresentationCapabilityGate() {
        var changes: [Bool] = []
        let model = LiveSharePresentationModel(
            snapshot: LiveShareViewSnapshot(
                phase: .live(elapsedSeconds: 12),
                settings: .init(
                    systemAudioEnabled: false,
                    canChangeSystemAudio: true
                )
            ),
            actions: .init(setSystemAudioEnabled: { changes.append($0) })
        )

        model.setSystemAudioEnabled(true)
        model.update(LiveShareViewSnapshot(
            phase: .reconnecting(attempt: 1, maximumAttempts: 5),
            settings: .init(
                systemAudioEnabled: true,
                canChangeSystemAudio: false
            )
        ))
        model.setSystemAudioEnabled(false)

        #expect(changes == [true])
    }

    @Test
    func testHardwareCodecDetailRemainsAvailable() {
        let verified = LiveShareCodecViewSnapshot(acceleration: .hardware)
        #expect(verified.detail == "Hardware accelerated")
    }

    @Test
    func testCopyActionsUseExactSessionValues() {
        var copied: [String] = []
        let model = LiveSharePresentationModel(
            snapshot: populatedSnapshot(),
            actions: .init(copyText: { copied.append($0) }),
            copiedFeedbackDuration: .seconds(30)
        )

        model.copyLink()
        #expect(copied == ["https://gopeep.tineestudio.se/CRISP-FROG-042"])
        #expect(model.copiedItem == .link)

        model.copyAccessCode()
        #expect(copied.last == "tiger-42")
        #expect(model.copiedItem == .accessCode)
    }

    @Test
    func testSnapshotGuardsPreventUnsupportedCommands() {
        var qualityChanges: [LiveShareQualityPreset] = []
        var autoShareChanges: [Bool] = []
        var fullscreenChanges: [Bool] = []
        var stopSessionCount = 0
        let snapshot = LiveShareViewSnapshot(
            phase: .stopping,
            fullscreen: .init(isOn: true, displayName: "Studio Display", isEnabled: false),
            settings: .init(
                canChangeQuality: false,
                canChangeAutoShare: true
            )
        )
        let model = LiveSharePresentationModel(
            snapshot: snapshot,
            actions: .init(
                setFullscreenEnabled: { fullscreenChanges.append($0) },
                setQuality: { qualityChanges.append($0) },
                setAutoShareEnabled: { autoShareChanges.append($0) },
                stopSession: { stopSessionCount += 1 }
            )
        )

        model.setQuality(.insane)
        model.setAutoShareEnabled(true)
        model.setFullscreenEnabled(false)
        model.stopSession()

        #expect(qualityChanges.isEmpty)
        #expect(autoShareChanges.isEmpty)
        #expect(fullscreenChanges.isEmpty)
        #expect(stopSessionCount == 0)
    }

    @Test
    func testCapabilityGateCanKeepSixtyFPSVisibleButUnavailable() {
        var frameRateChanges: [LiveShareFrameRate] = []
        let model = LiveSharePresentationModel(
            snapshot: LiveShareViewSnapshot(
                phase: .ready,
                settings: .init(
                    frameRate: .thirty,
                    availableFrameRates: [.fifteen, .thirty]
                )
            ),
            actions: .init(setFrameRate: { frameRateChanges.append($0) })
        )

        model.setFrameRate(.sixty)
        model.setFrameRate(.fifteen)

        #expect(frameRateChanges == [.fifteen])
    }

    @Test
    func testFailureExposesRetryAndSessionStopCommands() {
        var retryCount = 0
        var stopCount = 0
        let model = LiveSharePresentationModel(
            snapshot: LiveShareViewSnapshot(
                phase: .failed(message: "The signaling service is unavailable.")
            ),
            actions: .init(
                retry: { retryCount += 1 },
                stopSession: { stopCount += 1 }
            )
        )

        model.retry()
        model.stopSession()

        #expect(retryCount == 1)
        #expect(stopCount == 1)
    }

    @Test
    func testSourceActionsAreReadOnlyInAutoShareMode() {
        var sharedFocusedCount = 0
        var stoppedSourceIDs: [String] = []
        let source = LiveShareSourceViewSnapshot(
            id: "window-7",
            slotIndex: 0,
            applicationName: "Safari",
            windowTitle: "Clip",
            status: .live
        )
        let model = LiveSharePresentationModel(
            snapshot: LiveShareViewSnapshot(
                phase: .live(elapsedSeconds: 8),
                sources: [source],
                canShareFocusedWindow: true,
                settings: .init(autoShareFocusedWindows: true)
            ),
            actions: .init(
                shareFocusedWindow: { sharedFocusedCount += 1 },
                stopSource: { stoppedSourceIDs.append($0) }
            )
        )

        model.shareFocusedWindow()
        model.stopSource(source.id)

        #expect(sharedFocusedCount == 0)
        #expect(stoppedSourceIDs.isEmpty)
    }

    @Test
    func testLiveStatusAndDurationFormattingAreDeterministic() {
        #expect(LiveShareViewPhase.live(elapsedSeconds: 78).statusText == "Live · 01:18")
        #expect(LiveShareDurationFormatting.string(3_661.9) == "1:01:01")
        #expect(LiveShareDurationFormatting.string(-9) == "00:00")
    }

    @Test
    func testCapturePressureWarningNamesAffectedSourcesWithoutDuplicates() {
        let warning = LiveShareCapturePressureWarningSnapshot(
            sourceNames: ["Safari", " Safari ", "Xcode"]
        )
        let snapshot = LiveShareViewSnapshot(
            phase: .live(elapsedSeconds: 12),
            capturePressureWarning: warning
        )

        #expect(warning.sourceNames == ["Safari", "Xcode"])
        #expect(warning.title == "Capture is dropping frames")
        #expect(warning.message.contains("2 sources"))
        #expect(snapshot.capturePressureWarning == warning)
    }

    @Test
    func testDeterministicPopoverFixturesCoverReadyLiveReconnectAndFailure() throws {
        let ready = try #require(
            DeterministicLiveShareDemo.snapshot(for: .liveShareReady)
        )
        #expect(ready.phase == .ready)
        #expect(ready.room?.roomCode == "CRISP-FROG-042")
        #expect(!ready.hasActiveMedia)
        #expect(ready.availableWindows.count == 3)
        #expect(ready.canAddWindow)

        let live = try #require(
            DeterministicLiveShareDemo.snapshot(for: .liveShareLive)
        )
        let liveBottom = try #require(
            DeterministicLiveShareDemo.snapshot(for: .liveShareLiveBottom)
        )
        #expect(live == liveBottom)
        #expect(live.phase == .live(elapsedSeconds: 94))
        #expect(live.sources.count == 3)
        #expect(live.slots.map(\.state) == [.live, .starting, .live, .empty])
        #expect(live.connectedViewerCount == 2)
        #expect(live.statistics.streams.count == 3)
        #expect(live.accessCode == "orbit-mint-72")
        #expect(live.settings.codec.codec == .h264)
        #expect(live.settings.prioritizeFocusedWindow)
        #expect(live.settings.canChangeCodec)

        let reconnecting = try #require(
            DeterministicLiveShareDemo.snapshot(for: .liveShareReconnecting)
        )
        #expect(reconnecting.phase == .reconnecting(attempt: 2, maximumAttempts: 5))
        #expect(!reconnecting.canAddWindow)
        #expect(!reconnecting.fullscreen.isEnabled)
        #expect(!reconnecting.settings.canChangeQuality)
        #expect(!reconnecting.settings.canChangeCodec)
        #expect(reconnecting.sources.allSatisfy { !$0.canStop })

        let failed = try #require(
            DeterministicLiveShareDemo.snapshot(for: .liveShareFailed)
        )
        #expect(failed.phase.isFailure)
        #expect(failed.accessCodeError != nil)
        #expect(!failed.settings.canChangeMode)
        #expect(failed.viewers == [
            .init(id: "viewer-4F8A", connection: .disconnected, connectedDuration: nil),
        ])
    }

    @Test
    func testOnlyLiveShareScenariosProduceDeterministicLiveShareSnapshots() {
        let populated: [DeterministicUIScenario] = [
            .liveShareReady,
            .liveShareLive,
            .liveShareLiveBottom,
            .liveShareReconnecting,
            .liveShareFailed,
        ]

        for scenario in DeterministicUIScenario.allCases {
            #expect(
                (DeterministicLiveShareDemo.snapshot(for: scenario) != nil)
                    == populated.contains(scenario)
            )
        }
    }

    private func populatedSnapshot() -> LiveShareViewSnapshot {
        LiveShareViewSnapshot(
            phase: .ready,
            room: LiveShareRoomViewSnapshot(
                viewerURL: URL(string: "https://gopeep.tineestudio.se/CRISP-FROG-042")!,
                roomCode: "CRISP-FROG-042"
            ),
            accessCodeEnabled: true,
            accessCode: "tiger-42"
        )
    }
}
