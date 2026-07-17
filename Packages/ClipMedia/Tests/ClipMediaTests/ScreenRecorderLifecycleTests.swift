import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit
import Testing
@testable import ClipMedia

@Suite("Screen recorder session lifecycle")
struct ScreenRecorderLifecycleTests {
    @Test("Only complete screen samples with image buffers reach the video writer")
    func screenVideoSampleEligibility() {
        #expect(
            ScreenVideoSampleEligibility.accepts(
                isValid: true,
                hasImageBuffer: true,
                frameStatusRawValue: SCFrameStatus.complete.rawValue
            )
        )

        for status in [
            SCFrameStatus.idle,
            .blank,
            .suspended,
            .started,
            .stopped,
        ] {
            #expect(
                !ScreenVideoSampleEligibility.accepts(
                    isValid: true,
                    hasImageBuffer: true,
                    frameStatusRawValue: status.rawValue
                )
            )
        }
        #expect(
            !ScreenVideoSampleEligibility.accepts(
                isValid: true,
                hasImageBuffer: true,
                frameStatusRawValue: nil
            )
        )
        #expect(
            !ScreenVideoSampleEligibility.accepts(
                isValid: true,
                hasImageBuffer: false,
                frameStatusRawValue: SCFrameStatus.complete.rawValue
            )
        )
        #expect(
            !ScreenVideoSampleEligibility.accepts(
                isValid: false,
                hasImageBuffer: true,
                frameStatusRawValue: SCFrameStatus.complete.rawValue
            )
        )
    }

    @Test("Every video pixel buffer must exactly match the configured dimensions")
    func videoPixelBufferDimensionsMustMatch() throws {
        var optionalPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1_280,
            720,
            kCVPixelFormatType_32BGRA,
            nil,
            &optionalPixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let pixelBuffer = try #require(optionalPixelBuffer)

        try ScreenVideoSampleDimensionValidator.validate(
            pixelBuffer,
            expectedWidth: 1_280,
            expectedHeight: 720
        )

        let mismatch = ScreenVideoSampleDimensionError.mismatch(
            expectedWidth: 1_920,
            expectedHeight: 1_080,
            actualWidth: 1_280,
            actualHeight: 720
        )
        #expect(throws: mismatch) {
            try ScreenVideoSampleDimensionValidator.validate(
                pixelBuffer,
                expectedWidth: 1_920,
                expectedHeight: 1_080
            )
        }
        #expect(mismatch.localizedDescription.contains("pixel frame"))
        #expect(mismatch.localizedDescription.contains("requires exactly"))
        #expect(mismatch.localizedDescription.contains("avoid rescaling"))
    }

    @Test("Start and stop operations cannot reenter")
    func operationsCannotReenter() {
        let first = UUID()
        let second = UUID()
        var lifecycle = ScreenRecorderLifecycle()

        let reservedFirst = lifecycle.reserveStart(sessionIdentifier: first)
        #expect(reservedFirst)
        let duplicateFirst = lifecycle.reserveStart(sessionIdentifier: first)
        #expect(!duplicateFirst)
        let overlappingSecond = lifecycle.reserveStart(sessionIdentifier: second)
        #expect(!overlappingSecond)
        #expect(lifecycle.acceptsSamples(sessionIdentifier: first))

        let completedFirst = lifecycle.completeStart(sessionIdentifier: first)
        #expect(completedFirst)
        let completedFirstAgain = lifecycle.completeStart(sessionIdentifier: first)
        #expect(!completedFirstAgain)
        let beganFirstStop = lifecycle.beginStop(sessionIdentifier: first)
        #expect(beganFirstStop)
        let beganFirstStopAgain = lifecycle.beginStop(sessionIdentifier: first)
        #expect(!beganFirstStopAgain)
        let startDuringStop = lifecycle.reserveStart(sessionIdentifier: second)
        #expect(!startDuringStop)
        #expect(!lifecycle.acceptsSamples(sessionIdentifier: first))

        let completedFirstStop = lifecycle.completeStop(sessionIdentifier: first)
        #expect(completedFirstStop)
        let reservedSecond = lifecycle.reserveStart(sessionIdentifier: second)
        #expect(reservedSecond)
    }

    @Test("Callbacks from an earlier session are rejected after restart")
    func staleCallbacksAreRejected() {
        let first = UUID()
        let second = UUID()
        var lifecycle = ScreenRecorderLifecycle()

        let reservedFirst = lifecycle.reserveStart(sessionIdentifier: first)
        let completedFirst = lifecycle.completeStart(sessionIdentifier: first)
        let beganFirstStop = lifecycle.beginStop(sessionIdentifier: first)
        let completedFirstStop = lifecycle.completeStop(sessionIdentifier: first)
        let reservedSecond = lifecycle.reserveStart(sessionIdentifier: second)
        #expect(reservedFirst)
        #expect(completedFirst)
        #expect(beganFirstStop)
        #expect(completedFirstStop)
        #expect(reservedSecond)

        #expect(!lifecycle.acceptsSamples(sessionIdentifier: first))
        #expect(lifecycle.acceptsSamples(sessionIdentifier: second))
        let staleCompletion = lifecycle.completeStart(sessionIdentifier: first)
        #expect(!staleCompletion)
        let completedSecond = lifecycle.completeStart(sessionIdentifier: second)
        #expect(completedSecond)
        let staleStop = lifecycle.beginStop(sessionIdentifier: first)
        #expect(!staleStop)
    }

    @Test("A failed start can only release its own reservation")
    func failedStartIsGenerationChecked() {
        let first = UUID()
        let unrelated = UUID()
        var lifecycle = ScreenRecorderLifecycle()

        let reservedFirst = lifecycle.reserveStart(sessionIdentifier: first)
        #expect(reservedFirst)
        let abandonedUnrelated = lifecycle.abandonStart(sessionIdentifier: unrelated)
        #expect(!abandonedUnrelated)
        #expect(lifecycle.phase == .starting(first))
        let abandonedFirst = lifecycle.abandonStart(sessionIdentifier: first)
        #expect(abandonedFirst)
        #expect(lifecycle.phase == .idle)
        let abandonedFirstAgain = lifecycle.abandonStart(sessionIdentifier: first)
        #expect(!abandonedFirstAgain)
    }

    @Test("An optional audio append failure disables only that source")
    func audioFailureIsNonfatalAndSourceScoped() {
        var gate = ScreenRecorderSampleFailureGate()

        #expect(gate.accepts(.video))
        #expect(gate.accepts(.systemAudio))
        #expect(gate.accepts(.microphone))
        #expect(
            gate.handleAppendFailure(for: .microphone)
                == .audioSourceBecameUnavailable(.microphone)
        )
        #expect(gate.accepts(.video))
        #expect(gate.accepts(.systemAudio))
        #expect(!gate.accepts(.microphone))
        #expect(gate.unavailableAudioSources == [.microphone])
    }

    @Test("Repeated failed-source callbacks are ignored while video failure stays fatal")
    func repeatedAudioFailureIsIgnored() {
        var gate = ScreenRecorderSampleFailureGate()

        #expect(
            gate.handleAppendFailure(for: .systemAudio)
                == .audioSourceBecameUnavailable(.systemAudio)
        )
        #expect(
            gate.handleAppendFailure(for: .systemAudio)
                == .ignoreAlreadyUnavailableAudio(.systemAudio)
        )
        #expect(gate.handleAppendFailure(for: .video) == .fatal)
        #expect(gate.accepts(.video))
        #expect(gate.accepts(.microphone))
        #expect(!gate.accepts(.systemAudio))
    }

    @Test("Microphone and system audio failures remain independent")
    func audioSourcesFailIndependently() {
        var gate = ScreenRecorderSampleFailureGate()

        _ = gate.handleAppendFailure(for: .microphone)
        #expect(gate.accepts(.systemAudio))
        _ = gate.handleAppendFailure(for: .systemAudio)
        #expect(!gate.accepts(.microphone))
        #expect(!gate.accepts(.systemAudio))
        #expect(gate.accepts(.video))
        #expect(gate.unavailableAudioSources == [.microphone, .systemAudio])
    }

    @Test("A disappeared display discards an empty stream but preserves captured video")
    func displayDisconnectTerminationDecision() {
        var beforeFirstFrame = ScreenRecorderTerminationState()
        beforeFirstFrame.recordStreamFailure(message: "Display 2 was disconnected")
        #expect(beforeFirstFrame.terminationDisposition == .discardNoVideo)

        var afterFirstFrame = ScreenRecorderTerminationState()
        let firstSampleWasFirst = afterFirstFrame.recordVideoSample()
        let secondSampleWasFirst = afterFirstFrame.recordVideoSample()
        #expect(firstSampleWasFirst)
        #expect(!secondSampleWasFirst)
        afterFirstFrame.recordStreamFailure(message: "Display 2 was disconnected")
        afterFirstFrame.recordStreamFailure(message: "Later stop error")
        #expect(
            afterFirstFrame.terminationDisposition
                == .finalizeRecoverableOutput(message: "Display 2 was disconnected")
        )
    }

    @Test("A normal stream with video finalizes normally")
    func normalTerminationDecision() {
        var state = ScreenRecorderTerminationState()
        _ = state.recordVideoSample()
        #expect(state.terminationDisposition == .finalize)
    }

    @Test("Missing loopback audio is optional and does not skip microphone registration")
    func loopbackRegistrationFailureIsSourceScoped() {
        enum FixtureError: LocalizedError {
            case loopbackUnavailable

            var errorDescription: String? { "System audio route unavailable" }
        }

        var attempted: [CapturedAudioSource] = []
        let failures = ScreenRecorderAudioOutputRegistration.register(
            sources: [.systemAudio, .microphone]
        ) { source in
            attempted.append(source)
            if source == .systemAudio {
                throw FixtureError.loopbackUnavailable
            }
        }

        #expect(attempted == [.systemAudio, .microphone])
        #expect(
            failures == [
                ScreenRecorderAudioRegistrationFailure(
                    source: .systemAudio,
                    message: "System audio route unavailable"
                ),
            ]
        )
    }
}

@Suite("Screen recorder content filters")
struct ScreenRecorderContentFilterTests {
    private func request(
        excluded: String? = "com.tomaslejdung.clip",
        included: String? = nil
    ) -> ScreenRecordingRequest {
        ScreenRecordingRequest(
            displayID: 42,
            excludedBundleIdentifier: excluded,
            includedApplicationBundleIdentifier: included,
            outputURL: URL(fileURLWithPath: "/tmp/capture.mp4"),
            configuration: RecordingConfiguration(width: 1_280, height: 720)
        )
    }

    @Test("Display recording excludes Clip")
    func displaySelection() {
        #expect(
            request().filterSelection
                == .display(excludedBundleIdentifier: "com.tomaslejdung.clip")
        )
    }

    @Test("Application inclusion takes precedence over display exclusions")
    func applicationSelection() {
        let selected = request(included: "com.apple.Safari")
        #expect(
            selected.filterSelection
                == .application(bundleIdentifier: "com.apple.Safari")
        )
        #expect(selected.includedApplicationBundleIdentifier == "com.apple.Safari")
    }

    @Test("An exact window takes precedence over application and display filters")
    func exactWindowSelection() {
        var selected = request(included: "com.tomaslejdung.clip")
        selected.includedWindowID = 987

        #expect(selected.filterSelection == .window(987))
        #expect(
            selected.targetAvailability(
                displayIDs: [42],
                applicationBundleIdentifiers: ["com.tomaslejdung.clip"],
                windowIDs: [987]
            ) == .available
        )
        #expect(
            selected.targetAvailability(
                displayIDs: [42],
                applicationBundleIdentifiers: ["com.tomaslejdung.clip"],
                windowIDs: []
            ) == .windowUnavailable(987)
        )
    }

    @Test("Native-pixel stream configuration never upscales nominal capture")
    func nativePixelStreamConfiguration() {
        let sourceRect = CGRect(x: 120, y: 80, width: 1_240, height: 601)
        var selected = request(included: "com.openai.codex")
        selected.sourceRect = sourceRect
        selected.configuration = RecordingConfiguration(
            width: 2_480,
            height: 1_202,
            framesPerSecond: 30,
            showsCursor: false,
            audioMode: .microphoneAndSystem
        )

        let configuration = ScreenStreamConfigurationFactory.make(for: selected)

        #expect(configuration.width == 2_480)
        #expect(configuration.height == 1_202)
        #expect(configuration.sourceRect == sourceRect)
        #expect(configuration.captureResolution == .best)
        #expect(!configuration.scalesToFit)
        #expect(configuration.preservesAspectRatio)
        #expect(configuration.minimumFrameInterval == CMTime(value: 1, timescale: 30))
        #expect(!configuration.showsCursor)
        #expect(configuration.capturesAudio)
        #expect(configuration.captureMicrophone)
        #expect(configuration.excludesCurrentProcessAudio)
    }

    @Test("Synthetic self-capture can include only the current process's test audio")
    func syntheticSelfAudioConfiguration() {
        var selected = request(included: "com.tomaslejdung.clip")
        selected.excludesCurrentProcessAudio = false
        selected.configuration = RecordingConfiguration(
            width: 640,
            height: 360,
            framesPerSecond: 30,
            showsCursor: false,
            audioMode: .system
        )

        let configuration = ScreenStreamConfigurationFactory.make(for: selected)

        #expect(configuration.capturesAudio)
        #expect(!configuration.captureMicrophone)
        #expect(!configuration.excludesCurrentProcessAudio)
    }

    @Test("A second display disappearing invalidates only its request")
    func unavailableSecondDisplay() {
        let mainDisplay = request()
        var secondDisplay = request()
        secondDisplay.displayID = 77
        let initialDisplays: Set<CGDirectDisplayID> = [42, 77]

        #expect(
            secondDisplay.targetAvailability(
                displayIDs: initialDisplays,
                applicationBundleIdentifiers: []
            ) == .available
        )

        let afterDisconnect: Set<CGDirectDisplayID> = [42]
        #expect(
            secondDisplay.targetAvailability(
                displayIDs: afterDisconnect,
                applicationBundleIdentifiers: []
            ) == .displayUnavailable
        )
        #expect(
            mainDisplay.targetAvailability(
                displayIDs: afterDisconnect,
                applicationBundleIdentifiers: []
            ) == .available
        )
    }

    @Test("An application request distinguishes a missing app from a missing display")
    func unavailableApplicationTarget() {
        let selected = request(included: "com.apple.Safari")

        #expect(
            selected.targetAvailability(
                displayIDs: [42],
                applicationBundleIdentifiers: []
            ) == .applicationUnavailable("com.apple.Safari")
        )
        #expect(
            selected.targetAvailability(
                displayIDs: [],
                applicationBundleIdentifiers: ["com.apple.Safari"]
            ) == .displayUnavailable
        )
    }
}
