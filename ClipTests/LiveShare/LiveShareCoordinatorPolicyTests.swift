import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import CoreGraphics
import Foundation
import Testing
@testable import Clip

@Suite("Live Share coordinator policy")
struct LiveShareCoordinatorPolicyTests {
    @Test("Live Share capture never inherits recording click highlights")
    func liveShareClickHighlightIsolation() {
        let configuration = LiveShareCoordinatorPolicy.captureVideoConfiguration(
            width: 1_605,
            height: 1_108,
            framesPerSecond: 30,
            sourceRect: CGRect(x: 10, y: 20, width: 800, height: 600)
        )

        #expect(configuration.showsCursor)
        #expect(!configuration.showsClickHighlights)
        #expect(configuration.width == 1_605)
        #expect(configuration.height == 1_108)
        #expect(configuration.sourceRect == CGRect(x: 10, y: 20, width: 800, height: 600))
    }

    @Test("source identifiers are stable and reversible")
    func sourceIdentifiers() {
        let values: [LiveShareSourceID] = [
            .window(LiveShareWindowID(rawValue: 42)),
            .fullscreen(LiveShareDisplayID(rawValue: 7)),
        ]
        for value in values {
            let identifier = LiveShareCoordinatorPolicy.sourceIdentifier(value)
            #expect(LiveShareCoordinatorPolicy.sourceID(from: identifier) == value)
        }
        #expect(LiveShareCoordinatorPolicy.sourceID(from: "window:not-a-number") == nil)
        #expect(LiveShareCoordinatorPolicy.sourceID(from: "unknown:7") == nil)
    }

    @Test("fullscreen system audio uses its display and excludes Clip")
    func fullscreenSystemAudioRequest() throws {
        let identifier = try #require(UUID(uuidString: "74B3454B-617D-4605-BD56-34D71A92A659"))
        let sources = try LiveShareSourceSelection(fullscreen: LiveShareDisplaySource(
            id: LiveShareDisplayID(rawValue: 42),
            displayName: "Studio Display"
        ))

        let request = try #require(LiveShareCoordinatorPolicy.captureAudioRequest(
            systemAudioEnabled: true,
            sources: sources,
            knownWindows: [:],
            filterDisplayID: 99,
            clipBundleIdentifier: "com.example.Clip",
            requestIdentifier: identifier
        ))

        #expect(request.identifier == identifier)
        #expect(request.scope == .system(
            displayID: 42,
            excludedBundleIdentifier: "com.example.Clip"
        ))
        #expect(request.configuration.excludesCurrentProcessAudio)
    }

    @Test("window system audio resolves, trims, and deduplicates owning applications")
    func windowSystemAudioRequest() throws {
        let identifier = try #require(UUID(uuidString: "033B5F54-D40B-4A49-B4D4-77356F05977B"))
        let sources = try LiveShareSourceSelection(windows: [
            LiveShareWindowSource(
                id: LiveShareWindowID(rawValue: 10),
                windowName: "First",
                appName: "Browser"
            ),
            LiveShareWindowSource(
                id: LiveShareWindowID(rawValue: 11),
                windowName: "Second",
                appName: "Browser"
            ),
            LiveShareWindowSource(
                id: LiveShareWindowID(rawValue: 12),
                windowName: "Blank",
                appName: "Unknown"
            ),
            LiveShareWindowSource(
                id: LiveShareWindowID(rawValue: 13),
                windowName: "Unresolved",
                appName: "Missing"
            ),
        ])
        let knownWindows = [
            LiveShareWindowID(rawValue: 10): makeCaptureWindow(
                id: 10,
                title: "First",
                applicationName: "Browser",
                bundleIdentifier: " com.example.browser "
            ),
            LiveShareWindowID(rawValue: 11): makeCaptureWindow(
                id: 11,
                title: "Second",
                applicationName: "Browser",
                bundleIdentifier: "com.example.browser"
            ),
            LiveShareWindowID(rawValue: 12): makeCaptureWindow(
                id: 12,
                title: "Blank",
                applicationName: "Unknown",
                bundleIdentifier: " \n "
            ),
        ]

        let request = try #require(LiveShareCoordinatorPolicy.captureAudioRequest(
            systemAudioEnabled: true,
            sources: sources,
            knownWindows: knownWindows,
            filterDisplayID: 7,
            clipBundleIdentifier: "com.example.Clip",
            requestIdentifier: identifier
        ))

        #expect(request.identifier == identifier)
        #expect(request.scope == .applications(
            displayID: 7,
            bundleIdentifiers: ["com.example.browser"]
        ))
    }

    @Test("system audio request is absent when disabled or has no resolvable source")
    func absentSystemAudioRequest() throws {
        let identifier = UUID()
        let fullscreen = try LiveShareSourceSelection(fullscreen: LiveShareDisplaySource(
            id: LiveShareDisplayID(rawValue: 42),
            displayName: "Studio Display"
        ))
        #expect(LiveShareCoordinatorPolicy.captureAudioRequest(
            systemAudioEnabled: false,
            sources: fullscreen,
            knownWindows: [:],
            filterDisplayID: 7,
            clipBundleIdentifier: "com.example.Clip",
            requestIdentifier: identifier
        ) == nil)
        #expect(LiveShareCoordinatorPolicy.captureAudioRequest(
            systemAudioEnabled: true,
            sources: .empty,
            knownWindows: [:],
            filterDisplayID: 7,
            clipBundleIdentifier: "com.example.Clip",
            requestIdentifier: identifier
        ) == nil)

        let unresolvedWindows = try LiveShareSourceSelection(windows: [
            LiveShareWindowSource(
                id: LiveShareWindowID(rawValue: 404),
                windowName: "Missing",
                appName: "Missing"
            ),
        ])
        #expect(LiveShareCoordinatorPolicy.captureAudioRequest(
            systemAudioEnabled: true,
            sources: unresolvedWindows,
            knownWindows: [:],
            filterDisplayID: 7,
            clipBundleIdentifier: "com.example.Clip",
            requestIdentifier: identifier
        ) == nil)
        #expect(LiveShareCoordinatorPolicy.captureAudioRequest(
            systemAudioEnabled: true,
            sources: unresolvedWindows,
            knownWindows: [
                LiveShareWindowID(rawValue: 404): makeCaptureWindow(
                    id: 404,
                    title: "Missing",
                    applicationName: "Missing",
                    bundleIdentifier: " \t "
                ),
            ],
            filterDisplayID: 7,
            clipBundleIdentifier: "com.example.Clip",
            requestIdentifier: identifier
        ) == nil)
    }

    @Test("sender policy keeps quality, cadence, and degradation independent")
    func senderPolicy() {
        let quality = LiveShareCoordinatorPolicy.senderPolicy(for: LiveShareSettings(
            quality: .insane,
            frameRate: .sixty,
            encodingMode: .quality
        ))
        #expect(quality.maximumBitrateBps == 50_000_000)
        #expect(quality.maximumFramesPerSecond == 60)
        #expect(quality.maintainsResolution)

        let performance = LiveShareCoordinatorPolicy.senderPolicy(for: LiveShareSettings(
            quality: .low,
            frameRate: .fifteen,
            encodingMode: .performance
        ))
        #expect(performance.maximumBitrateBps == 500_000)
        #expect(performance.maximumFramesPerSecond == 15)
        #expect(!performance.maintainsResolution)
    }

    @Test("one session budget is divided by focus without multiplying bandwidth")
    func senderPolicyAllocation() throws {
        let slots = try LiveShareTrackSlotAllocation(slots: [
            LiveShareTrackSlot(
                index: 0,
                source: .window(.init(id: .init(rawValue: 10), windowName: "A", appName: "A")),
                isFocused: true
            ),
            LiveShareTrackSlot(
                index: 1,
                source: .window(.init(id: .init(rawValue: 11), windowName: "B", appName: "B"))
            ),
            LiveShareTrackSlot(
                index: 2,
                source: .window(.init(id: .init(rawValue: 12), windowName: "C", appName: "C"))
            ),
            LiveShareTrackSlot(index: 3),
        ])

        let prioritized = LiveShareCoordinatorPolicy.senderPolicies(
            for: LiveShareSettings(
                quality: .veryHigh,
                prioritizeFocusedWindow: true
            ),
            slots: slots
        )
        #expect(prioritized[0]?.maximumBitrateBps == 4_000_000)
        #expect(prioritized[1]?.maximumBitrateBps == 1_000_000)
        #expect(prioritized[2]?.maximumBitrateBps == 1_000_000)
        #expect(prioritized[0]?.bitratePriority == 4)
        #expect(prioritized[1]?.bitratePriority == 1)
        #expect(prioritized[2]?.bitratePriority == 1)
        #expect(prioritized.values.compactMap(\.maximumBitrateBps).reduce(0, +) == 6_000_000)

        let equal = LiveShareCoordinatorPolicy.senderPolicies(
            for: LiveShareSettings(
                quality: .veryHigh,
                prioritizeFocusedWindow: false
            ),
            slots: slots
        )
        #expect(equal[0]?.maximumBitrateBps == 2_000_000)
        #expect(equal[1]?.maximumBitrateBps == 2_000_000)
        #expect(equal[2]?.maximumBitrateBps == 2_000_000)
        #expect(equal.values.allSatisfy { $0.bitratePriority == 1 })
        #expect(equal.values.compactMap(\.maximumBitrateBps).reduce(0, +) == 6_000_000)
    }

    @Test("statistics compare aggregate rates with an aggregate ceiling")
    func aggregateBitrateCeiling() {
        #expect(LiveShareCoordinatorPolicy.aggregateConfiguredBitrateCeiling(
            perViewer: 6_000_000,
            viewerCount: 2
        ) == 12_000_000)
        #expect(LiveShareCoordinatorPolicy.aggregateConfiguredBitrateCeiling(
            perViewer: 6_000_000,
            viewerCount: 0
        ) == 0)
        #expect(LiveShareCoordinatorPolicy.aggregateConfiguredBitrateCeiling(
            perViewer: Int.max,
            viewerCount: 2
        ) == Int.max)
    }

    @Test("any failed geometry rollback requires complete session cleanup")
    func geometryRollbackFailurePolicy() {
        #expect(LiveShareCaptureGeometryFailurePolicy.requiresSessionFailure(
            after: LiveShareCaptureGeometryTransitionError.rollbackFailed(
                change: "change",
                rollback: "rollback"
            )
        ))
        #expect(LiveShareCaptureGeometryFailurePolicy.requiresSessionFailure(
            after: LiveShareCapturePipelineError.updateRollbackFailed(
                slot: 0,
                update: "change",
                rollback: "rollback"
            )
        ))
        #expect(!LiveShareCaptureGeometryFailurePolicy.requiresSessionFailure(
            after: LiveShareCapturePipelineError.slotInactive(0)
        ))
    }

    @Test("video dimensions match libwebrtc H.264 output geometry")
    func videoEncoderGeometry() {
        #expect(LiveShareCoordinatorPolicy.videoEncoderCompatibleDimension(2_763) == 2_762)
        #expect(LiveShareCoordinatorPolicy.videoEncoderCompatibleDimension(1_203) == 1_202)
        #expect(LiveShareCoordinatorPolicy.videoEncoderCompatibleDimension(1_920) == 1_920)
        #expect(LiveShareCoordinatorPolicy.videoEncoderCompatibleDimension(1) == 2)
    }

    @Test("H.264 aspect-fits 5K and 6K while software codecs stay native")
    func codecCaptureGeometry() {
        #expect(LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: 1_920,
            sourceHeight: 1_080,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 1_920, height: 1_080))
        #expect(LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: 1_605,
            sourceHeight: 1_108,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 1_605, height: 1_108))
        #expect(LiveShareCoordinatorPolicy.streamGeometry(
            captureGeometry: LiveShareCaptureGeometry(width: 1_605, height: 1_108),
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 1_604, height: 1_108))
        #expect(LiveShareCoordinatorPolicy.streamGeometry(
            captureGeometry: LiveShareCaptureGeometry(width: 1_605, height: 1_109),
            codec: .vp8
        ) == LiveShareCaptureGeometry(width: 1_605, height: 1_109))
        #expect(LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: 5_120,
            sourceHeight: 2_880,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 4_096, height: 2_304))
        #expect(LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: 5_120,
            sourceHeight: 1_440,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 4_096, height: 1_152))
        #expect(LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: 2_880,
            sourceHeight: 5_120,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 2_304, height: 4_096))
        #expect(LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: 6_016,
            sourceHeight: 3_384,
            codec: .h264
        ) == LiveShareCaptureGeometry(width: 4_096, height: 2_304))
        let sixtyFPSH264 = LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: 6_016,
            sourceHeight: 3_384,
            codec: .h264,
            framesPerSecond: 60
        )
        let sixtyFPSMacroblocks = ((sixtyFPSH264.width + 15) / 16)
            * ((sixtyFPSH264.height + 15) / 16)
        #expect(sixtyFPSMacroblocks * 60 <= 2_073_600)
        #expect(sixtyFPSH264 != LiveShareCaptureGeometry(width: 4_096, height: 2_304))
        #expect(LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: 6_016,
            sourceHeight: 3_384,
            codec: .vp8,
            framesPerSecond: 60
        ) == LiveShareCaptureGeometry(width: 6_016, height: 3_384))
        #expect(LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: 6_017,
            sourceHeight: 3_385,
            codec: .vp8
        ) == LiveShareCaptureGeometry(width: 6_017, height: 3_385))
        for codec in [LiveShareVideoCodec.vp9, .av1] {
            #expect(LiveShareCoordinatorPolicy.captureGeometry(
                sourceWidth: 6_017,
                sourceHeight: 3_385,
                codec: codec
            ) == LiveShareCaptureGeometry(width: 6_017, height: 3_385))
            #expect(LiveShareCoordinatorPolicy.streamGeometry(
                captureGeometry: LiveShareCaptureGeometry(width: 6_017, height: 3_385),
                codec: codec
            ) == LiveShareCaptureGeometry(width: 6_017, height: 3_385))
        }
    }

    @Test("H.264 geometry never exceeds hardware side or luma limits")
    func h264GeometryLimits() {
        for (width, height) in [
            (5_120, 2_880),
            (6_016, 3_384),
            (8_000, 1_000),
            (1_000, 8_000),
            (4_097, 2_305),
        ] {
            let geometry = LiveShareCoordinatorPolicy.captureGeometry(
                sourceWidth: width,
                sourceHeight: height,
                codec: .h264
            )
            let streamGeometry = LiveShareCoordinatorPolicy.streamGeometry(
                captureGeometry: geometry,
                codec: .h264
            )
            #expect(streamGeometry.width <= 4_096)
            #expect(streamGeometry.height <= 4_096)
            #expect(streamGeometry.width * streamGeometry.height <= 4_096 * 2_304)
            #expect(
                ((streamGeometry.width + 15) / 16)
                    * ((streamGeometry.height + 15) / 16)
                    <= 36_864
            )
            #expect(streamGeometry.width.isMultiple(of: 2))
            #expect(streamGeometry.height.isMultiple(of: 2))
        }

        // Visible luma alone is under the nominal limit, but codec padding for
        // both non-multiple-of-16 sides would otherwise exceed Level 5.2.
        let pathological = LiveShareCoordinatorPolicy.captureGeometry(
            sourceWidth: 4_081,
            sourceHeight: 2_307,
            codec: .h264
        )
        #expect(
            ((pathological.width + 15) / 16) * ((pathological.height + 15) / 16)
                <= 36_864
        )
    }

    @Test("capture pressure requires sustained samples and rejects stale generations")
    func capturePressureLedger() {
        let source = LiveShareSource.window(LiveShareWindowSource(
            id: LiveShareWindowID(rawValue: 42),
            windowName: "Fixture",
            appName: "Tests"
        ))
        let sourceID = source.id
        let firstGeneration = UUID()
        let replacementGeneration = UUID()
        var ledger = LiveShareCapturePressureLedger()

        func sample(
            generation: UUID,
            delivered: UInt64,
            dropped: UInt64
        ) -> LiveShareCaptureDeliverySnapshot {
            LiveShareCaptureDeliverySnapshot(
                slot: 0,
                source: source,
                generation: generation,
                statistics: CaptureDeliveryStatistics(
                    deliveredFrames: delivered,
                    backpressureDrops: dropped
                )
            )
        }

        let firstActive = [sourceID: firstGeneration]
        ledger.update(
            [sample(generation: firstGeneration, delivered: 0, dropped: 0)],
            activeGenerations: firstActive
        )
        #expect(ledger.latestBackpressureDrops(
            for: sourceID,
            generation: firstGeneration
        ) == 0)
        for interval in 1...4 {
            ledger.update(
                [sample(
                    generation: firstGeneration,
                    delivered: UInt64(interval * 20),
                    dropped: UInt64(interval * 10)
                )],
                activeGenerations: firstActive
            )
            #expect(!ledger.isOverloaded(sourceID, generation: firstGeneration))
            #expect(ledger.latestBackpressureDrops(
                for: sourceID,
                generation: firstGeneration
            ) == 10)
        }

        // A sample for an unrecognized replacement cannot complete the old
        // session's pressure streak.
        ledger.update(
            [sample(generation: replacementGeneration, delivered: 100, dropped: 100)],
            activeGenerations: firstActive
        )
        #expect(!ledger.isOverloaded(sourceID, generation: firstGeneration))

        ledger.update(
            [sample(generation: firstGeneration, delivered: 100, dropped: 50)],
            activeGenerations: firstActive
        )
        #expect(ledger.isOverloaded(sourceID, generation: firstGeneration))

        // Replacing the source clears the visible health and cumulative stats
        // immediately, even if an old actor response arrives afterward.
        let replacementActive = [sourceID: replacementGeneration]
        ledger.update(
            [sample(generation: firstGeneration, delivered: 130, dropped: 50)],
            activeGenerations: replacementActive
        )
        #expect(!ledger.isOverloaded(sourceID, generation: replacementGeneration))
        #expect(ledger.statistics(for: sourceID, generation: replacementGeneration) == nil)

        ledger.update(
            [sample(generation: replacementGeneration, delivered: 1, dropped: 0)],
            activeGenerations: replacementActive
        )
        #expect(ledger.latestBackpressureDrops(
            for: sourceID,
            generation: replacementGeneration
        ) == 0)
        #expect(
            ledger.statistics(for: sourceID, generation: replacementGeneration)
                == CaptureDeliveryStatistics(deliveredFrames: 1, backpressureDrops: 0)
        )
    }

    @Test("fullscreen follows the focused window's display then falls back to primary")
    func fullscreenDisplaySelection() {
        let primary = ShareableCaptureDisplay(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        let secondary = ShareableCaptureDisplay(
            id: 2,
            frame: CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440),
            pixelWidth: 2_560,
            pixelHeight: 1_440
        )
        let focused = CGRect(x: 2_100, y: 100, width: 800, height: 700)
        #expect(LiveShareCoordinatorPolicy.preferredFullscreenDisplay(
            from: [primary, secondary],
            focusedWindowFrame: focused,
            primaryDisplayID: 1
        )?.id == 2)
        #expect(LiveShareCoordinatorPolicy.preferredFullscreenDisplay(
            from: [secondary, primary],
            focusedWindowFrame: nil,
            primaryDisplayID: 1
        )?.id == 1)
    }

    @Test("fullscreen rollback preserves window order, metadata, and focus")
    func fullscreenRollbackPlan() throws {
        let firstSource = LiveShareWindowSource(
            id: LiveShareWindowID(rawValue: 11),
            windowName: "Original document title",
            appName: "Editor"
        )
        let secondSource = LiveShareWindowSource(
            id: LiveShareWindowID(rawValue: 22),
            windowName: "Original browser title",
            appName: "Browser"
        )
        var selection = LiveShareSourceSelection.empty
        var slots = LiveShareTrackSlotAllocation()
        for source in [firstSource, secondSource] {
            let change = selection.adding(.window(source))
            selection = change.selection
            try slots.apply(change)
        }
        slots.focus(.window(firstSource.id))

        let firstWindow = makeCaptureWindow(
            id: firstSource.id.rawValue,
            title: "Current document title",
            applicationName: "Editor"
        )
        let secondWindow = makeCaptureWindow(
            id: secondSource.id.rawValue,
            title: "Current browser title",
            applicationName: "Browser"
        )
        let plan = LiveShareCoordinatorPolicy.fullscreenRollbackPlan(
            sources: selection,
            slots: slots,
            knownWindows: [
                firstSource.id: firstWindow,
                secondSource.id: secondWindow,
            ]
        )

        #expect(plan.windows.map(\.source) == [firstSource, secondSource])
        #expect(plan.windows.map(\.window) == [firstWindow, secondWindow])
        #expect(plan.focusedSourceID == .window(firstSource.id))
        #expect(!plan.isEmpty)
    }

    @Test("fullscreen rollback excludes unavailable windows and stale focus")
    func fullscreenRollbackUnavailableWindow() throws {
        let available = LiveShareWindowSource(
            id: LiveShareWindowID(rawValue: 31),
            windowName: "Available",
            appName: "Editor"
        )
        let unavailable = LiveShareWindowSource(
            id: LiveShareWindowID(rawValue: 32),
            windowName: "Closed",
            appName: "Browser"
        )
        var selection = LiveShareSourceSelection.empty
        var slots = LiveShareTrackSlotAllocation()
        for source in [available, unavailable] {
            let change = selection.adding(.window(source))
            selection = change.selection
            try slots.apply(change)
        }
        slots.focus(.window(unavailable.id))
        let availableWindow = makeCaptureWindow(
            id: available.id.rawValue,
            title: "Available",
            applicationName: "Editor"
        )

        let plan = LiveShareCoordinatorPolicy.fullscreenRollbackPlan(
            sources: selection,
            slots: slots,
            knownWindows: [available.id: availableWindow]
        )

        #expect(plan.windows.map(\.source.id) == [available.id])
        #expect(plan.focusedSourceID == nil)
    }

    @Test("manual sharing observes capacity while automatic replacement may proceed")
    func sourceCapacity() {
        #expect(LiveShareCoordinatorPolicy.permitsWindowShare(
            isAlreadyShared: true,
            hasFullscreenSource: false,
            activeWindowCount: 4,
            autoShareEnabled: false
        ))
        #expect(!LiveShareCoordinatorPolicy.permitsWindowShare(
            isAlreadyShared: false,
            hasFullscreenSource: false,
            activeWindowCount: 4,
            autoShareEnabled: false
        ))
        #expect(LiveShareCoordinatorPolicy.permitsWindowShare(
            isAlreadyShared: false,
            hasFullscreenSource: false,
            activeWindowCount: 4,
            autoShareEnabled: true
        ))
        #expect(LiveShareCoordinatorPolicy.permitsWindowShare(
            isAlreadyShared: false,
            hasFullscreenSource: true,
            activeWindowCount: 4,
            autoShareEnabled: false
        ))
    }

    @Test("viewer states expose connected peers only as connected")
    func viewerConnectionMapping() {
        #expect(LiveShareCoordinatorPolicy.viewerConnection(from: .new) == .connecting)
        #expect(LiveShareCoordinatorPolicy.viewerConnection(from: .connecting) == .connecting)
        #expect(LiveShareCoordinatorPolicy.viewerConnection(from: .connected) == .connected)
        #expect(LiveShareCoordinatorPolicy.viewerConnection(
            from: .connected,
            route: .direct
        ) == .peerToPeer)
        #expect(LiveShareCoordinatorPolicy.viewerConnection(
            from: .connected,
            route: .relay
        ) == .turn)
        #expect(LiveShareCoordinatorPolicy.viewerConnection(from: .disconnected) == .disconnected)
        #expect(LiveShareCoordinatorPolicy.viewerConnection(from: .failed) == .disconnected)
        #expect(LiveShareCoordinatorPolicy.viewerConnection(from: .closed) == .disconnected)
    }

    @Test("menu-bar status distinguishes session health without exposing transient phases")
    func menuBarStatus() {
        #expect(LiveShareCoordinatorPolicy.menuBarStatus(for: .ready) == .ready)
        #expect(LiveShareCoordinatorPolicy.menuBarStatus(for: .starting) == .ready)
        #expect(LiveShareCoordinatorPolicy.menuBarStatus(
            for: .live(elapsedSeconds: 42)
        ) == .live)
        #expect(LiveShareCoordinatorPolicy.menuBarStatus(
            for: .reconnecting(attempt: 2, maximumAttempts: 5)
        ) == .reconnecting)
        #expect(LiveShareCoordinatorPolicy.menuBarStatus(
            for: .failed(message: "Unavailable")
        ) == .failed)

        #expect(LiveShareMenuBarStatus.ready.symbolName != LiveShareMenuBarStatus.live.symbolName)
        #expect(
            LiveShareMenuBarStatus.reconnecting.symbolName
                != LiveShareMenuBarStatus.failed.symbolName
        )
    }

    @Test("user-facing failures never expose technical transport details")
    func failureCopy() {
        let failure = LiveShareFailure(
            code: .signalingFailed,
            technicalDescription: "secret=wont-appear host=internal.example"
        )
        let message = LiveShareCoordinatorPolicy.userFacingFailure(failure)
        #expect(!message.contains("secret"))
        #expect(!message.contains("internal.example"))
        #expect(message.contains("connection"))

        let identityMessage = LiveShareCoordinatorPolicy.userFacingFailure(
            LiveShareFailure(
                code: .identityUnavailable,
                technicalDescription: "Keychain status -34018"
            )
        )
        #expect(identityMessage.contains("identity"))
        #expect(!identityMessage.contains("34018"))
    }

    @Test("viewer admission counts pending and allocated copies of one route once")
    func viewerAdmissionCapacityUsesDistinctRoutes() {
        let allocated = ["viewer-1", "viewer-2", "viewer-3", "viewer-4"]
        let pending = ["viewer-1", "viewer-2", "viewer-3", "viewer-4"]

        #expect(LiveShareViewerAdmissionCapacity.canBegin(
            routeID: "viewer-5",
            allocatedViewerIDs: allocated,
            pendingRouteIDs: pending,
            maximumViewers: 8
        ))
        #expect(!LiveShareViewerAdmissionCapacity.canBegin(
            routeID: "viewer-1",
            allocatedViewerIDs: allocated,
            pendingRouteIDs: pending,
            maximumViewers: 8
        ))
        #expect(!LiveShareViewerAdmissionCapacity.canBegin(
            routeID: "viewer-9",
            allocatedViewerIDs: allocated + ["viewer-5", "viewer-6", "viewer-7", "viewer-8"],
            pendingRouteIDs: pending,
            maximumViewers: 8
        ))
    }

    @Test("pre-Start viewer route is promoted exactly once after Start")
    func preparedViewerRouteDrainsIntoAdmission() {
        let routeID = ClipLiveShareRouteID.random()
        var prepared: Set<ClipLiveShareRouteID> = []

        #expect(LiveSharePreparedViewerRouteBuffer.retain(
            routeID,
            in: &prepared,
            maximumCount: 8
        ))
        let routesToAdmit = LiveSharePreparedViewerRouteBuffer.drain(&prepared)

        #expect(routesToAdmit == [routeID])
        #expect(prepared.isEmpty)
        #expect(LiveSharePreparedViewerRouteBuffer.drain(&prepared).isEmpty)
    }

    @Test("closed pre-Start viewer route is cancelled before Start")
    func preparedViewerRouteCancellation() {
        let cancelledRoute = ClipLiveShareRouteID.random()
        let waitingRoute = ClipLiveShareRouteID.random()
        var prepared: Set<ClipLiveShareRouteID> = []
        #expect(LiveSharePreparedViewerRouteBuffer.retain(
            cancelledRoute,
            in: &prepared,
            maximumCount: 8
        ))
        #expect(LiveSharePreparedViewerRouteBuffer.retain(
            waitingRoute,
            in: &prepared,
            maximumCount: 8
        ))

        LiveSharePreparedViewerRouteBuffer.cancel(
            cancelledRoute,
            in: &prepared
        )

        #expect(LiveSharePreparedViewerRouteBuffer.drain(&prepared) == [waitingRoute])
    }

    @Test("pre-Start viewer waiting is capacity bounded and idempotent")
    func preparedViewerRouteCapacity() {
        let first = ClipLiveShareRouteID.random()
        let second = ClipLiveShareRouteID.random()
        let overflow = ClipLiveShareRouteID.random()
        var prepared: Set<ClipLiveShareRouteID> = []

        #expect(LiveSharePreparedViewerRouteBuffer.retain(
            first,
            in: &prepared,
            maximumCount: 2
        ))
        #expect(LiveSharePreparedViewerRouteBuffer.retain(
            second,
            in: &prepared,
            maximumCount: 2
        ))
        #expect(LiveSharePreparedViewerRouteBuffer.retain(
            first,
            in: &prepared,
            maximumCount: 2
        ))
        #expect(!LiveSharePreparedViewerRouteBuffer.retain(
            overflow,
            in: &prepared,
            maximumCount: 2
        ))
        #expect(prepared == [first, second])
    }

    @Test("signaling handoff stays admission-pending until the host control channel opens")
    func viewerAdmissionWaitsForNativeControlChannel() {
        var progress = LiveShareViewerAdmissionProgress()
        #expect(progress.remainsPending)

        progress.receiveSignalingHandoff()
        #expect(progress.didReceiveSignalingHandoff)
        #expect(progress.remainsPending)

        progress.openControlDataChannel()
        #expect(progress.didOpenControlDataChannel)
        #expect(!progress.remainsPending)
    }

    @Test("signaling server errors are redacted before public diagnostics")
    func signalingServerErrorRedaction() {
        let serverControlled = "password=SECRET room=HIDDEN-ROOM-42 sdp=v=0"
        let description = LiveShareCoordinatorPolicy.redactedSignalingFailureDescription(
            serverMessage: serverControlled
        )

        #expect(description == "The signaling server rejected a request.")
        #expect(!description.contains("SECRET"))
        #expect(!description.contains("HIDDEN-ROOM"))
        #expect(!description.contains("sdp"))
    }

    @Test("peer negotiation serializes offers and buffers ICE around descriptions")
    func negotiationLedger() {
        var ledger = LiveSharePeerNegotiationLedger()
        let local = WebRTCICECandidate(
            candidate: "candidate:local 1 udp 2122260223 192.0.2.1 41000 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        let remote = WebRTCICECandidate(
            candidate: "candidate:remote 1 udp 2122260223 192.0.2.2 42000 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        let firstOffer = ledger.beginOffer(for: "viewer-1")
        #expect(firstOffer != nil)
        #expect(ledger.beginOffer(for: "viewer-1") == nil)
        #expect(ledger.receiveLocalICE(local, for: "viewer-1") == nil)
        #expect(ledger.receiveRemoteICE(remote, for: "viewer-1") == .buffered)
        if let firstOffer {
            let becameAnswerEligible = ledger.markOfferAnswerEligible(
                for: "viewer-1",
                token: firstOffer
            )
            #expect(becameAnswerEligible)
            #expect(ledger.markOfferSent(for: "viewer-1", token: firstOffer) == [local])
            #expect(ledger.completeAnswer(for: "viewer-1", token: firstOffer) == [remote])
        }
        #expect(ledger.beginOffer(for: "viewer-1") != nil)
    }

    @Test("a fast answer is accepted while its offer send is suspended")
    func negotiationLedgerAcceptsAnswerDuringOfferSend() throws {
        var ledger = LiveSharePeerNegotiationLedger()
        let local = WebRTCICECandidate(
            candidate: "candidate:local 1 udp 2122260223 192.0.2.1 41000 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        let remote = WebRTCICECandidate(
            candidate: "candidate:remote 1 udp 2122260223 192.0.2.2 42000 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )
        let offerValue = ledger.beginOffer(for: "viewer-1")
        let offer = try #require(offerValue)

        #expect(ledger.receiveLocalICE(local, for: "viewer-1") == nil)
        #expect(ledger.receiveRemoteICE(remote, for: "viewer-1") == .buffered)
        #expect(ledger.tokenAwaitingAnswer(for: "viewer-1") == nil)

        // This is the exact suspension window in `signaling.send(offer)`: the
        // browser may answer, but local ICE cannot overtake the outbound offer.
        let becameAnswerEligible = ledger.markOfferAnswerEligible(
            for: "viewer-1",
            token: offer
        )
        #expect(becameAnswerEligible)
        #expect(ledger.tokenAwaitingAnswer(for: "viewer-1") == offer)
        #expect(ledger.receiveLocalICE(local, for: "viewer-1") == nil)
        #expect(ledger.completeAnswer(for: "viewer-1", token: offer) == [remote])
        #expect(ledger.tokenAwaitingAnswer(for: "viewer-1") == nil)
        let replacementDuringSuspendedSend = ledger.beginOffer(for: "viewer-1")
        #expect(replacementDuringSuspendedSend == nil)

        // Successful send completion still flushes all local ICE accumulated
        // before and during the suspension, even though SDP already completed.
        #expect(ledger.markOfferSent(for: "viewer-1", token: offer) == [local, local])
        #expect(ledger.receiveLocalICE(local, for: "viewer-1") == local)
        let replacementAfterSend = ledger.beginOffer(for: "viewer-1")
        #expect(replacementAfterSend != nil)
    }

    @Test("peer negotiation bounds viewers and pending ICE")
    func negotiationLedgerBounds() {
        let limits = WebRTCPeerResourceLimits(
            maximumViewerCount: 1,
            answerTimeout: 1,
            maximumICECandidatesPerPeer: 2,
            maximumICECandidatePayloadBytes: 512,
            maximumViewerIDBytes: 32
        )
        var ledger = LiveSharePeerNegotiationLedger(resourceLimits: limits)
        let offer = ledger.beginOffer(for: "viewer-1")
        #expect(offer != nil)
        #expect(ledger.beginOffer(for: "viewer-2") == nil)
        #expect(ledger.beginOffer(for: String(repeating: "x", count: 33)) == nil)

        let candidates = (0 ..< 3).map { index in
            WebRTCICECandidate(
                candidate: "candidate:\(index) 1 udp 2122260223 192.0.2.1 \(41000 + index) typ host",
                sdpMid: "0",
                sdpMLineIndex: 0
            )
        }
        #expect(ledger.receiveRemoteICE(candidates[0], for: "viewer-1") == .buffered)
        #expect(ledger.receiveRemoteICE(candidates[1], for: "viewer-1") == .buffered)
        #expect(ledger.receiveRemoteICE(candidates[2], for: "viewer-1") == .rejected)
        if let offer {
            let becameAnswerEligible = ledger.markOfferAnswerEligible(
                for: "viewer-1",
                token: offer
            )
            #expect(becameAnswerEligible)
            #expect(ledger.markOfferSent(for: "viewer-1", token: offer) == [])
            #expect(
                ledger.completeAnswer(for: "viewer-1", token: offer)
                    == Array(candidates.prefix(2))
            )
        }
        #expect(ledger.receiveRemoteICE(candidates[0], for: "unknown") == .rejected)

        ledger.remove("viewer-1")
        #expect(ledger.beginOffer(for: "viewer-2") != nil)
    }

    @Test("late SDP work cannot mutate a replacement viewer negotiation")
    func negotiationLedgerRejectsStaleTokens() throws {
        var ledger = LiveSharePeerNegotiationLedger()
        let firstValue = ledger.beginOffer(for: "viewer-1")
        let first = try #require(firstValue)
        #expect(ledger.contains(first, for: "viewer-1"))

        ledger.remove("viewer-1")
        let replacementValue = ledger.beginOffer(for: "viewer-1")
        let replacement = try #require(replacementValue)
        #expect(!ledger.contains(first, for: "viewer-1"))
        #expect(ledger.contains(replacement, for: "viewer-1"))
        let staleOfferBecameAnswerEligible = ledger.markOfferAnswerEligible(
            for: "viewer-1",
            token: first
        )
        #expect(!staleOfferBecameAnswerEligible)
        #expect(ledger.markOfferSent(for: "viewer-1", token: first) == nil)
        #expect(ledger.completeAnswer(for: "viewer-1", token: first) == nil)
        let removedReplacementWithStaleToken = ledger.remove(
            "viewer-1",
            token: first
        )
        #expect(!removedReplacementWithStaleToken)
        #expect(ledger.contains(replacement, for: "viewer-1"))

        let replacementBecameAnswerEligible = ledger.markOfferAnswerEligible(
            for: "viewer-1",
            token: replacement
        )
        #expect(replacementBecameAnswerEligible)
        #expect(ledger.markOfferSent(for: "viewer-1", token: replacement) == [])
        #expect(ledger.tokenAwaitingAnswer(for: "viewer-1") == replacement)
        #expect(ledger.completeAnswer(for: "viewer-1", token: replacement) == [])
        #expect(ledger.tokenAwaitingAnswer(for: "viewer-1") == nil)
    }

    @Test("authoritative control replay is per-peer and bounded")
    func authoritativeControlReplayLedger() {
        var ledger = LiveShareAuthoritativeControlDeliveryLedger(
            maximumReplayAttempts: 2,
            maximumTrackedPeers: 2
        )
        ledger.recordLifecycleDelivery(WebRTCControlDeliveryResult(
            deliveredViewerIDs: ["viewer-ok"],
            unavailableViewerIDs: ["viewer-1", "viewer-2", "viewer-3"]
        ))
        #expect(ledger.dirtyViewerIDs == ["viewer-1", "viewer-2"])
        let firstReplay = ledger.beginReplay(for: "viewer-1")
        let secondReplay = ledger.beginReplay(for: "viewer-1")
        let thirdReplay = ledger.beginReplay(for: "viewer-1")
        #expect(firstReplay)
        #expect(secondReplay)
        #expect(!thirdReplay)
        #expect(!ledger.canReplay(to: "viewer-1"))

        // Native low-water recovery grants a fresh bounded replay for the
        // still-dirty current snapshot.
        ledger.recordNativeControlDrain("viewer-1")
        #expect(ledger.canReplay(to: "viewer-1"))
        let firstDrainReplay = ledger.beginReplay(for: "viewer-1")
        let secondDrainReplay = ledger.beginReplay(for: "viewer-1")
        #expect(firstDrainReplay)
        #expect(secondDrainReplay)
        #expect(!ledger.canReplay(to: "viewer-1"))

        // A newer durable mutation refreshes the budget because the snapshot
        // being replayed has changed.
        ledger.markDirty("viewer-1")
        #expect(ledger.canReplay(to: "viewer-1"))
        let refreshedReplay = ledger.beginReplay(for: "viewer-1")
        #expect(refreshedReplay)
        ledger.markReplayDelivered(to: "viewer-1")
        #expect(!ledger.dirtyViewerIDs.contains("viewer-1"))
        ledger.recordNativeControlDrain("viewer-1")
        #expect(!ledger.canReplay(to: "viewer-1"))

        ledger.remove("viewer-2")
        #expect(ledger.dirtyViewerIDs.isEmpty)
    }

    @Test("only the latest suspended source request may complete")
    func latestRequestGate() {
        var gate = LiveShareFullscreenRequestGate()
        let first = gate.begin(isEnabled: true)
        #expect(gate.contains(first))

        let second = gate.begin(isEnabled: false)
        #expect(!gate.contains(first))
        #expect(gate.contains(second))

        gate.finish(first)
        #expect(gate.contains(second))
        gate.finish(second)
        #expect(!gate.contains(second))

        let third = gate.begin(isEnabled: true)
        gate.invalidate()
        #expect(!gate.contains(third))
    }

    @Test("OFF during destructive fullscreen start rolls the stopped windows back")
    func fullscreenOffDuringDestructiveStart() {
        var gate = LiveShareFullscreenRequestGate()
        let enable = gate.begin(isEnabled: true)
        #expect(
            gate.actionAfterDestructiveStop(for: enable)
                == .continueToFullscreen
        )

        // This models ON awaiting stopAllMedia while the user requests OFF.
        let disable = gate.begin(isEnabled: false)
        #expect(!gate.contains(enable))
        #expect(gate.contains(disable))
        #expect(
            gate.actionAfterDestructiveStop(for: enable)
                == .restoreWindows
        )
        #expect(gate.permitsWindowRollback(for: enable))

        // Finishing stale ON work must not clear the queued OFF intent.
        gate.finish(enable)
        #expect(gate.contains(disable))
        #expect(gate.permitsWindowRollback(for: enable))

        // Stop All / termination invalidation is intentionally different from
        // OFF: it abandons the transaction and never recreates media.
        gate.invalidate()
        #expect(
            gate.actionAfterDestructiveStop(for: enable)
                == .abandon
        )
        #expect(!gate.permitsWindowRollback(for: enable))
    }

    @Test("native route loss waits for delayed P2P control or admission timeout")
    @MainActor
    func nativeRendezvousHandoffRace() async throws {
        let recorder = NativePeerHandoffTimeoutRecorder()
        let controller = LiveShareNativePeerHandoffController(
            timeout: .milliseconds(800),
            timeoutHandler: { routeID in await recorder.append(routeID) }
        )
        let delayedOpenRoute = ClipLiveShareRouteID.random()
        controller.admit(delayedOpenRoute)
        controller.signalingRouteClosed(delayedOpenRoute)

        // This is deliberately longer than the removed 500 ms grace. Route
        // loss alone must not retire a healthy peer whose host callback is late.
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.isAwaitingControlChannel(delayedOpenRoute))
        #expect(await recorder.routes.isEmpty)

        controller.controlChannelOpened(delayedOpenRoute)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!controller.isAwaitingControlChannel(delayedOpenRoute))
        #expect(await recorder.routes.isEmpty)

        let timedOutRoute = ClipLiveShareRouteID.random()
        controller.admit(timedOutRoute)
        controller.signalingRouteClosed(timedOutRoute)
        #expect(await eventuallyNativeRendezvous {
            await recorder.routes.contains(timedOutRoute)
        })
    }

    @Test("native viewer approval rechecks trust after the modal returns")
    func nativeViewerApprovalTrustRace() {
        let signer = NativeDeviceIdentitySigner()
        let trusted = NativeFriendRecord(
            identity: signer.publicKey,
            displayName: "Friend",
            deviceName: "Friend Mac",
            endpoint: .localDevelopment,
            rendezvousID: .random()
        )
        var blocked = trusted
        blocked.trustState = .blocked

        #expect(LiveShareNativeViewerApprovalPolicy.permitsAfterModal(
            userAllowed: true,
            expectedIdentity: signer.publicKey,
            currentRecords: [trusted]
        ))
        #expect(!LiveShareNativeViewerApprovalPolicy.permitsAfterModal(
            userAllowed: true,
            expectedIdentity: signer.publicKey,
            currentRecords: [blocked]
        ))
        #expect(!LiveShareNativeViewerApprovalPolicy.permitsAfterModal(
            userAllowed: true,
            expectedIdentity: signer.publicKey,
            currentRecords: []
        ))
        #expect(!LiveShareNativeViewerApprovalPolicy.permitsAfterModal(
            userAllowed: false,
            expectedIdentity: signer.publicKey,
            currentRecords: [trusted]
        ))
    }
}

@Suite("Live Share native rendezvous lifecycle")
struct LiveShareNativeRendezvousLifecycleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("preparation claims the persistent rendezvous without publishing")
    func preparationIsNotJoinable() async throws {
        let identity = makeNativeDeviceIdentity()
        let transport = NativeRendezvousHostTransportSpy()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)

        try await lifecycle.prepare()

        let lifecycleSnapshot = await lifecycle.snapshot()
        let transportSnapshot = await transport.snapshot()
        #expect(lifecycleSnapshot.phase == .preparing)
        #expect(lifecycleSnapshot.rendezvousID == identity.rendezvousID)
        #expect(lifecycleSnapshot.sessionID == nil)
        #expect(transportSnapshot.attachedOwners.count == 1)
        #expect(transportSnapshot.publishedDescriptors.isEmpty)
        await lifecycle.tearDown()
    }

    @Test("explicit activation publishes a fresh valid signed descriptor")
    func explicitActivationPublishesDescriptor() async throws {
        let identity = makeNativeDeviceIdentity()
        let transport = NativeRendezvousHostTransportSpy()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        let room = try makeNativeRoom(name: "NATIVE-ROOM-ONE")

        try await lifecycle.prepare()
        try await lifecycle.activate(room: room)

        let lifecycleSnapshot = await lifecycle.snapshot()
        let payload = try #require(
            await transport.snapshot().publishedDescriptors.last
        )
        let signed = try ClipLiveShareNativeV2MessageCodec.decode(
            ClipLiveShareSignedNativeSessionDescriptor.self,
            from: payload
        )
        let timestamp = try ClipLiveShareNativeTimestamp(date: now)
        try signed.verify(
            expectedIdentity: identity.publicKey,
            expectedContext: ClipLiveShareNativeRendezvousContext(
                endpoint: room.endpoint,
                room: room.room,
                rendezvousID: identity.rendezvousID
            ),
            at: timestamp
        )
        #expect(lifecycleSnapshot.phase == .active)
        #expect(lifecycleSnapshot.sessionID == signed.descriptor.sessionID)
        #expect(signed.descriptor.roomPublicKey == room.identity.publicKey)
        #expect(signed.descriptor.stateRevision.rawValue == 1)
        await lifecycle.tearDown()
    }

    @Test("descriptor refresh preserves session and advances revision")
    func refreshPreservesSession() async throws {
        let identity = makeNativeDeviceIdentity()
        let transport = NativeRendezvousHostTransportSpy()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        let room = try makeNativeRoom(name: "NATIVE-ROOM-TWO")
        try await lifecycle.prepare()
        try await lifecycle.activate(room: room)
        let first = try #require(await lifecycle.snapshot().signedDescriptor)

        try await lifecycle.refreshActiveDescriptor()

        let second = try #require(await lifecycle.snapshot().signedDescriptor)
        #expect(second.descriptor.sessionID == first.descriptor.sessionID)
        #expect(second.descriptor.stateRevision.rawValue == 2)
        #expect(await transport.snapshot().publishedDescriptors.count == 2)
        await lifecycle.tearDown()
    }

    @Test("new room stops the old descriptor and rotates the native session")
    func replacingRoomRotatesSession() async throws {
        let identity = makeNativeDeviceIdentity()
        let transport = NativeRendezvousHostTransportSpy()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        let firstRoom = try makeNativeRoom(name: "NATIVE-FIRST")
        let secondRoom = try makeNativeRoom(name: "NATIVE-SECOND")
        try await lifecycle.prepare()
        try await lifecycle.activate(room: firstRoom)
        let firstSession = try #require(await lifecycle.snapshot().sessionID)

        try await lifecycle.prepareForRoomReplacement()
        try await lifecycle.activate(room: secondRoom)

        let secondSnapshot = await lifecycle.snapshot()
        let transportSnapshot = await transport.snapshot()
        #expect(secondSnapshot.phase == .active)
        #expect(secondSnapshot.sessionID != firstSession)
        #expect(secondSnapshot.signedDescriptor?.descriptor.room == secondRoom.room)
        #expect(transportSnapshot.stopSharingCount == 1)
        #expect(transportSnapshot.publishedDescriptors.count == 2)
        await lifecycle.tearDown()
    }

    @Test("native routes remain rejected before explicit Start")
    func routeRejectedBeforeStart() async throws {
        let identity = makeNativeDeviceIdentity()
        let transport = NativeRendezvousHostTransportSpy()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        let routeID = ClipLiveShareRouteID.random()
        try await lifecycle.prepare()

        await transport.emit(.routeOpened(
            routeID: routeID.rawValue,
            descriptor: nil
        ))

        #expect(await eventuallyNativeRendezvous {
            await transport.snapshot().closedRoutes.contains {
                $0.routeID == routeID.rawValue
                    && $0.reason == "native-share-not-active"
            }
        })
        await lifecycle.tearDown()
    }

    @Test("refresh failures retry briefly and fail closed before descriptor expiry")
    func refreshFailureFailsClosedBeforeExpiry() async throws {
        let identity = makeNativeDeviceIdentity()
        let transport = NativeRendezvousHostTransportSpy(
            maximumSuccessfulPublishes: 1
        )
        let clock = NativeRendezvousTestClock(now)
        let eventRecorder = NativeRendezvousLifecycleEventRecorder()
        let lifecycle = makeLifecycle(
            identity: identity,
            transport: transport,
            nowProvider: { clock.now },
            refreshSleeper: NativeRendezvousAdvancingSleeper(clock: clock),
            refreshInterval: .seconds(4 * 60),
            refreshRetryDelays: [.seconds(2), .seconds(4), .seconds(8)]
        )
        let events = await lifecycle.events()
        let eventTask = Task {
            for await event in events { await eventRecorder.append(event) }
        }
        let room = try makeNativeRoom(name: "NATIVE-REFRESH-FAILURE")
        try await lifecycle.prepare()
        try await lifecycle.activate(room: room)

        #expect(await eventuallyNativeRendezvous {
            await lifecycle.snapshot().phase == .idle
        })
        let elapsed = clock.now.timeIntervalSince(now)
        let transportSnapshot = await transport.snapshot()
        #expect(elapsed < 5 * 60)
        #expect(transportSnapshot.publishAttempts == 5)
        #expect(transportSnapshot.publishedDescriptors.count == 1)
        #expect(transportSnapshot.teardownFlags == [false])
        #expect(await eventRecorder.contains(
            .unavailable(.descriptorRefreshFailed)
        ))
        eventTask.cancel()
    }

    @Test("transport event overflow is surfaced and fails native joins closed")
    func transportEventOverflowFailsClosed() async throws {
        let identity = makeNativeDeviceIdentity()
        let transport = NativeRendezvousHostTransportSpy()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        let eventRecorder = NativeRendezvousLifecycleEventRecorder()
        let events = await lifecycle.events()
        let eventTask = Task {
            for await event in events { await eventRecorder.append(event) }
        }
        try await lifecycle.prepare()
        try await lifecycle.activate(
            room: try makeNativeRoom(name: "NATIVE-EVENT-OVERFLOW")
        )

        await transport.emit(.eventBufferOverflow)

        #expect(await eventuallyNativeRendezvous {
            let phase = await lifecycle.snapshot().phase
            let unavailable = await eventRecorder.contains(
                .unavailable(.eventBufferOverflow)
            )
            return phase == .idle && unavailable
        })
        #expect(await transport.snapshot().teardownFlags == [false])
        eventTask.cancel()
    }

    @Test("stalled lifecycle consumer is bounded and fails native routes closed")
    func lifecycleOutputOverflowFailsClosed() async throws {
        let identity = makeNativeDeviceIdentity()
        let transport = NativeRendezvousHostTransportSpy()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        // Deliberately retain without consuming so the lifecycle's own output
        // buffer, rather than the transport buffer, is the resource under test.
        let events = await lifecycle.events()
        try await lifecycle.prepare()
        try await lifecycle.activate(
            room: try makeNativeRoom(name: "NATIVE-OUTPUT-OVERFLOW")
        )

        for _ in 0..<300 {
            await transport.emit(.routeClosed(
                routeID: ClipLiveShareRouteID.random().rawValue,
                reason: "fixture"
            ))
            await Task.yield()
        }

        #expect(await eventuallyNativeRendezvous {
            await lifecycle.snapshot().phase == .idle
        })
        var iterator = events.makeAsyncIterator()
        var sawOverflow = false
        for _ in 0..<256 {
            if case .unavailable(.eventBufferOverflow) = await iterator.next() {
                sawOverflow = true
                break
            }
        }
        #expect(sawOverflow)
        #expect(await transport.snapshot().teardownFlags == [false])
    }

    @Test("unexpected transport event-stream end is surfaced and fails closed")
    func transportEventStreamEndFailsClosed() async throws {
        let identity = makeNativeDeviceIdentity()
        let transport = NativeRendezvousHostTransportSpy()
        let lifecycle = makeLifecycle(identity: identity, transport: transport)
        let eventRecorder = NativeRendezvousLifecycleEventRecorder()
        let events = await lifecycle.events()
        let eventTask = Task {
            for await event in events { await eventRecorder.append(event) }
        }
        try await lifecycle.prepare()
        try await lifecycle.activate(
            room: try makeNativeRoom(name: "NATIVE-EVENT-END")
        )

        await transport.finishEvents()

        #expect(await eventuallyNativeRendezvous {
            let phase = await lifecycle.snapshot().phase
            let unavailable = await eventRecorder.contains(
                .unavailable(.eventStreamEnded)
            )
            return phase == .idle && unavailable
        })
        #expect(await transport.snapshot().teardownFlags == [false])
        eventTask.cancel()
    }

    @Test("saved friend proof is encrypted, pinned, approved, and admitted")
    func savedFriendAdmission() async throws {
        let hostIdentity = makeNativeDeviceIdentity()
        let viewerSigner = NativeDeviceIdentitySigner()
        let viewerEphemeral = ClipLiveShareViewerIdentity()
        let transport = NativeRendezvousHostTransportSpy()
        let lifecycle = makeLifecycle(
            identity: hostIdentity,
            transport: transport
        )
        let events = await lifecycle.events()
        let eventRecorder = NativeRendezvousLifecycleEventRecorder()
        let eventTask = Task {
            for await event in events { await eventRecorder.append(event) }
        }
        let room = try makeNativeRoom(name: "NATIVE-FRIEND")
        let routeID = ClipLiveShareRouteID.random()
        try await lifecycle.prepare()
        try await lifecycle.activate(room: room)
        try await lifecycle.trustViewerIdentity(viewerSigner.publicKey)

        await transport.emit(.routeOpened(
            routeID: routeID.rawValue,
            descriptor: nil
        ))
        let hello = try ClipLiveShareMessageCodec.encodeOuter(
            .viewerHello(try ClipLiveShareViewerHello(
                viewerKey: viewerEphemeral.publicKey
            ))
        )
        await transport.emit(.relay(
            routeID: routeID.rawValue,
            payload: hello,
            sequence: 1
        ))
        #expect(await eventuallyNativeRendezvous {
            await transport.snapshot().sentPayloads.count >= 1
        })

        let challengePayload = try #require(
            await transport.snapshot().sentPayloads.first?.payload
        )
        guard case let .relay(challengeEnvelope) =
            try ClipLiveShareMessageCodec.decodeOuter(challengePayload)
        else {
            Issue.record("Host did not send an encrypted challenge")
            eventTask.cancel()
            return
        }
        var viewerChannel = try ClipLiveShareEncryptedChannel(
            viewer: viewerEphemeral,
            roomPublicKey: room.identity.publicKey,
            room: room.room,
            routeID: routeID
        )
        let challenge = try ClipLiveShareNativeV2MessageCodec.decode(
            ClipLiveShareNativeViewerChallenge.self,
            from: viewerChannel.openOpaquePayload(challengeEnvelope)
        )
        #expect(challenge.routeID == routeID)
        #expect(challenge.viewerEphemeralPublicKey == viewerEphemeral.publicKey)
        let proof = try ClipLiveShareSignedNativeViewerProof(
            signing: challenge,
            with: viewerSigner
        )
        let sealedProof = try viewerChannel.sealOpaquePayload(
            ClipLiveShareNativeV2MessageCodec.encode(proof)
        )
        let routedProof = try ClipLiveShareRelayEnvelope(
            routeID: routeID,
            sequence: sealedProof.sequence,
            nonce: sealedProof.nonce,
            ciphertext: sealedProof.ciphertext
        )
        await transport.emit(.relay(
            routeID: routeID.rawValue,
            payload: try ClipLiveShareMessageCodec.encodeOuter(
                .relay(routedProof)
            ),
            sequence: 2
        ))
        #expect(await eventuallyNativeRendezvous {
            await eventRecorder.events.contains(
                .approvalRequested(
                    routeID: routeID,
                    viewerIdentity: viewerSigner.publicKey
                )
            )
        })

        await lifecycle.resolveApproval(routeID: routeID, allowed: true)

        #expect(await eventuallyNativeRendezvous {
            await eventRecorder.events.contains {
                guard case let .viewerAdmitted(eventRoute, _, identity) = $0
                else { return false }
                return eventRoute == routeID && identity == viewerSigner.publicKey
            }
        })
        #expect(await eventuallyNativeRendezvous {
            await transport.snapshot().sentPayloads.count >= 2
        })
        let resultPayload = try #require(
            await transport.snapshot().sentPayloads.last?.payload
        )
        guard case let .relay(resultEnvelope) =
            try ClipLiveShareMessageCodec.decodeOuter(resultPayload),
              case let .authResult(result) = try viewerChannel.open(resultEnvelope)
        else {
            Issue.record("Host did not send the encrypted admission result")
            eventTask.cancel()
            return
        }
        #expect(result.allowed)
        #expect(result.sessionID == challenge.sessionID)
        eventTask.cancel()
        await lifecycle.tearDown()
    }

    private func makeLifecycle(
        identity: NativeDeviceIdentity,
        transport: NativeRendezvousHostTransportSpy,
        nowProvider: (@Sendable () -> Date)? = nil,
        refreshSleeper: any ClipLiveShareReconnectSleeper =
            ContinuousClipLiveShareReconnectSleeper(),
        refreshInterval: Duration? = nil,
        refreshRetryDelays: [Duration] =
            LiveShareNativeRendezvousLifecycle.descriptorRefreshRetryDelays
    ) -> LiveShareNativeRendezvousLifecycle {
        let fixedNow = now
        return LiveShareNativeRendezvousLifecycle(
            serverEndpoint: .localDevelopment,
            identityProvider: { identity },
            transport: transport,
            now: nowProvider ?? { fixedNow },
            refreshSleeper: refreshSleeper,
            refreshInterval: refreshInterval,
            refreshRetryDelays: refreshRetryDelays
        )
    }
}

@Suite("Native friend host commit")
struct LiveShareNativeFriendCommitTests {
    private let now = Date(timeIntervalSince1970: 1_800_100_000)

    @Test("host persists only after a valid acknowledgement and duplicates are safe")
    @MainActor
    func acknowledgementCommitsExactlyOnce() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.lifecycle.tearDown() } }
        let recorder = NativeFriendCommitRecorder()
        let controller = LiveShareNativeFriendCommitController(
            commit: { try recorder.commit($0) }
        )
        try controller.stage(
            request: fixture.request,
            acceptance: fixture.acceptance,
            sessionDescriptor: fixture.descriptor,
            encodedResponse: fixture.encodedAcceptance,
            viewerID: "viewer"
        )

        #expect(recorder.records.isEmpty)
        let acknowledgement = try ClipLiveShareNativeFriendAcceptanceAcknowledgement(
            acknowledging: fixture.acceptance,
            for: fixture.request,
            acknowledgedAt: fixture.timestamp
        )
        let signed = try ClipLiveShareSignedNativeFriendMessage(
            signing: .acceptanceAcknowledged(acknowledgement),
            with: fixture.viewerSigner
        )
        #expect(try await controller.receiveAcknowledgement(
            signed,
            viewerID: "viewer",
            at: fixture.timestamp
        ).admission == .firstSeen)
        #expect(recorder.records.count == 1)
        #expect(recorder.records.first?.identity == fixture.viewerSigner.publicKey)

        #expect(try await controller.receiveAcknowledgement(
            signed,
            viewerID: "viewer",
            at: fixture.timestamp
        ).admission == .duplicate)
        #expect(recorder.records.count == 1)

        let later = try fixture.timestamp.adding(milliseconds: 1)
        let secondStatement = try ClipLiveShareSignedNativeFriendMessage(
            signing: .acceptanceAcknowledged(
                ClipLiveShareNativeFriendAcceptanceAcknowledgement(
                    acknowledging: fixture.acceptance,
                    for: fixture.request,
                    acknowledgedAt: later
                )
            ),
            with: fixture.viewerSigner
        )
        await #expect(throws: ClipLiveShareNativeV2Error.replayed) {
            try await controller.receiveAcknowledgement(
                secondStatement,
                viewerID: "viewer",
                at: later
            )
        }
        #expect(recorder.records.count == 1)
    }

    @Test("host receipt is signed only after durable commit and cached for retries")
    @MainActor
    func durableCommitProducesRetryableReceipt() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.lifecycle.tearDown() } }
        let recorder = NativeFriendCommitRecorder()
        let controller = LiveShareNativeFriendCommitController(
            commit: { try recorder.commit($0) }
        )
        try controller.stage(
            request: fixture.request,
            acceptance: fixture.acceptance,
            sessionDescriptor: fixture.descriptor,
            encodedResponse: fixture.encodedAcceptance,
            viewerID: "viewer"
        )
        let acknowledgement = try ClipLiveShareNativeFriendAcceptanceAcknowledgement(
            acknowledging: fixture.acceptance,
            for: fixture.request,
            acknowledgedAt: fixture.timestamp
        )
        let signedAcknowledgement = try ClipLiveShareSignedNativeFriendMessage(
            signing: .acceptanceAcknowledged(acknowledgement),
            with: fixture.viewerSigner
        )

        let result = try await controller.receiveAcknowledgement(
            signedAcknowledgement,
            viewerID: "viewer",
            at: fixture.timestamp
        )
        #expect(recorder.records.count == 1)
        let encodedReceipt = try await fixture.lifecycle.makeFriendCommitReceipt(
            for: result
        )
        try controller.storeCommitReceipt(
            encodedReceipt,
            acknowledgementDigest: result.acknowledgementDigest,
            viewerID: "viewer"
        )
        #expect(controller.commitReceipt(for: "viewer") == encodedReceipt)

        let signedReceipt = try ClipLiveShareNativeV2MessageCodec.decode(
            ClipLiveShareSignedNativeFriendMessage.self,
            from: encodedReceipt
        )
        try signedReceipt.verifySignature(
            expectedIdentity: fixture.descriptor.hostIdentity
        )
        guard case let .commitReceipt(receipt) = signedReceipt.message else {
            Issue.record("Expected a signed host commit receipt")
            return
        }
        try receipt.validate(
            for: acknowledgement,
            acknowledgementDigest: signedAcknowledgement.digest,
            acceptance: fixture.acceptance,
            request: fixture.request,
            expectedSessionDescriptor: fixture.descriptor,
            at: fixture.timestamp
        )

        let duplicate = try await controller.receiveAcknowledgement(
            signedAcknowledgement,
            viewerID: "viewer",
            at: fixture.timestamp
        )
        #expect(duplicate.admission == .duplicate)
        #expect(controller.commitReceipt(for: "viewer") == encodedReceipt)
        #expect(recorder.records.count == 1)
    }

    @Test("duplicate acknowledgement retries a failed durable host save")
    @MainActor
    func duplicateRetriesFailedDurableCommit() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.lifecycle.tearDown() } }
        let recorder = NativeFriendCommitRecorder(failures: 1)
        let controller = LiveShareNativeFriendCommitController(
            commit: { try recorder.commit($0) }
        )
        try controller.stage(
            request: fixture.request,
            acceptance: fixture.acceptance,
            sessionDescriptor: fixture.descriptor,
            encodedResponse: fixture.encodedAcceptance,
            viewerID: "viewer"
        )
        let acknowledgement = try ClipLiveShareNativeFriendAcceptanceAcknowledgement(
            acknowledging: fixture.acceptance,
            for: fixture.request,
            acknowledgedAt: fixture.timestamp
        )
        let signed = try ClipLiveShareSignedNativeFriendMessage(
            signing: .acceptanceAcknowledged(acknowledgement),
            with: fixture.viewerSigner
        )

        await #expect(throws: NativeFriendPersistenceError.saveFailed) {
            try await controller.receiveAcknowledgement(
                signed,
                viewerID: "viewer",
                at: fixture.timestamp
            )
        }
        #expect(recorder.attempts == 1)
        #expect(recorder.records.isEmpty)

        #expect(try await controller.receiveAcknowledgement(
            signed,
            viewerID: "viewer",
            at: fixture.timestamp
        ).admission == .duplicate)
        #expect(recorder.attempts == 2)
        #expect(recorder.records.count == 1)

        #expect(try await controller.receiveAcknowledgement(
            signed,
            viewerID: "viewer",
            at: fixture.timestamp
        ).admission == .duplicate)
        #expect(recorder.attempts == 2)
        #expect(recorder.records.count == 1)
    }

    @Test("host restart accepts only the exact persisted ACK and resumes receipt creation")
    @MainActor
    func restoredHostCommitReplaysExactAcknowledgement() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.lifecycle.tearDown() } }
        var persistedEntry: NativeFriendHandshakeJournalEntry?
        let firstProcess = LiveShareNativeFriendCommitController(
            commitWithEvidence: { _, entry in
                persistedEntry = entry
            }
        )
        try firstProcess.stage(
            signedRequest: fixture.signedRequest,
            signedAcceptance: fixture.signedAcceptance,
            signedSessionDescriptor: fixture.signedDescriptor,
            encodedResponse: fixture.encodedAcceptance,
            viewerID: "viewer-before-crash"
        )
        let acknowledgement = try ClipLiveShareNativeFriendAcceptanceAcknowledgement(
            acknowledging: fixture.acceptance,
            for: fixture.request,
            acknowledgedAt: fixture.timestamp
        )
        let exactACK = try ClipLiveShareSignedNativeFriendMessage(
            signing: .acceptanceAcknowledged(acknowledgement),
            with: fixture.viewerSigner
        )
        _ = try await firstProcess.receiveAcknowledgement(
            exactACK,
            viewerID: "viewer-before-crash",
            at: fixture.timestamp
        )

        let recoveredEntry = try #require(persistedEntry)
        let restarted = LiveShareNativeFriendCommitController(
            commitWithEvidence: { _, _ in
                Issue.record("Recovered committed evidence must not write the friend twice")
            }
        )
        try restarted.restoreCommittedHandshake(
            recoveredEntry,
            viewerID: "viewer-after-crash"
        )
        let replay = try await restarted.receiveAcknowledgement(
            exactACK,
            viewerID: "viewer-after-crash",
            at: try fixture.timestamp.adding(milliseconds: 120_000)
        )
        #expect(replay.admission == .duplicate)
        let recoveredReceipt = try await fixture.lifecycle.makeFriendCommitReceipt(
            for: replay
        )
        #expect(!recoveredReceipt.isEmpty)

        let resignedACK = try ClipLiveShareSignedNativeFriendMessage(
            signing: .acceptanceAcknowledged(acknowledgement),
            with: fixture.viewerSigner
        )
        if resignedACK != exactACK {
            await #expect(throws: ClipLiveShareNativeV2Error.replayed) {
                try await restarted.receiveAcknowledgement(
                    resignedACK,
                    viewerID: "viewer-after-crash",
                    at: fixture.timestamp
                )
            }
        }
    }

    @Test("wrong and expired acknowledgements never commit")
    @MainActor
    func invalidAcknowledgementsDoNotCommit() async throws {
        let fixture = try await makeFixture()
        defer { Task { await fixture.lifecycle.tearDown() } }
        let recorder = NativeFriendCommitRecorder()
        let controller = LiveShareNativeFriendCommitController(
            commit: { try recorder.commit($0) }
        )
        let acknowledgement = try ClipLiveShareNativeFriendAcceptanceAcknowledgement(
            acknowledging: fixture.acceptance,
            for: fixture.request,
            acknowledgedAt: fixture.timestamp
        )
        let message = ClipLiveShareNativeFriendMessage
            .acceptanceAcknowledged(acknowledgement)
        let attacker = NativeDeviceIdentitySigner()
        let wrongSignature = try attacker.signature(
            for: message.canonicalRepresentation
        )
        let wrong = ClipLiveShareSignedNativeFriendMessage(
            message: message,
            signature: wrongSignature
        )
        try controller.stage(
            request: fixture.request,
            acceptance: fixture.acceptance,
            sessionDescriptor: fixture.descriptor,
            encodedResponse: fixture.encodedAcceptance,
            viewerID: "wrong"
        )
        await #expect(throws: ClipLiveShareNativeV2Error.invalidSignature) {
            try await controller.receiveAcknowledgement(
                wrong,
                viewerID: "wrong",
                at: fixture.timestamp
            )
        }

        let signed = try ClipLiveShareSignedNativeFriendMessage(
            signing: message,
            with: fixture.viewerSigner
        )
        try controller.stage(
            request: fixture.request,
            acceptance: fixture.acceptance,
            sessionDescriptor: fixture.descriptor,
            encodedResponse: fixture.encodedAcceptance,
            viewerID: "expired"
        )
        let afterExpiry = try fixture.request.expiresAt.adding(milliseconds: 1)
        await #expect(throws: ClipLiveShareNativeV2Error.expired) {
            try await controller.receiveAcknowledgement(
                signed,
                viewerID: "expired",
                at: afterExpiry
            )
        }
        #expect(recorder.records.isEmpty)
    }

    private func makeFixture() async throws -> NativeFriendCommitFixture {
        let identity = makeNativeDeviceIdentity()
        let viewerSigner = NativeDeviceIdentitySigner()
        let transport = NativeRendezvousHostTransportSpy()
        let lifecycle = LiveShareNativeRendezvousLifecycle(
            serverEndpoint: .localDevelopment,
            identityProvider: { identity },
            transport: transport,
            now: { now },
            refreshInterval: nil
        )
        try await lifecycle.prepare()
        try await lifecycle.activate(
            room: makeNativeRoom(name: "NATIVE-FRIEND-COMMIT")
        )
        let signedDescriptor = try #require(
            await lifecycle.snapshot().signedDescriptor
        )
        let descriptor = signedDescriptor.descriptor
        let timestamp = try ClipLiveShareNativeTimestamp(date: now)
        let request = try ClipLiveShareNativeFriendRequest(
            requestID: .random(),
            sessionID: descriptor.sessionID,
            sessionDescriptorDigest: descriptor.digest,
            requestedHostFingerprint: descriptor.hostIdentity.fingerprint,
            requesterIdentity: viewerSigner.publicKey,
            requesterEndpoint: .localDevelopment,
            requesterRendezvousID: .random(),
            requesterDeviceName: "Viewer Mac",
            issuedAt: timestamp,
            expiresAt: timestamp.adding(milliseconds: 60_000)
        )
        let signedRequest = try ClipLiveShareSignedNativeFriendMessage(
            signing: .request(request),
            with: viewerSigner
        )
        let encodedAcceptance = try await lifecycle.makeFriendResponse(
            to: request,
            allowed: true,
            accepterDisplayName: "Host Person",
            accepterDeviceName: "Host Mac"
        )
        let signedAcceptance = try ClipLiveShareNativeV2MessageCodec.decode(
            ClipLiveShareSignedNativeFriendMessage.self,
            from: encodedAcceptance
        )
        guard case let .accepted(acceptance) = signedAcceptance.message else {
            throw ClipLiveShareNativeV2Error.contextMismatch
        }
        return NativeFriendCommitFixture(
            lifecycle: lifecycle,
            viewerSigner: viewerSigner,
            signedDescriptor: signedDescriptor,
            descriptor: descriptor,
            request: request,
            signedRequest: signedRequest,
            acceptance: acceptance,
            signedAcceptance: signedAcceptance,
            encodedAcceptance: encodedAcceptance,
            timestamp: timestamp
        )
    }
}

private struct NativeFriendCommitFixture {
    let lifecycle: LiveShareNativeRendezvousLifecycle
    let viewerSigner: NativeDeviceIdentitySigner
    let signedDescriptor: ClipLiveShareSignedNativeSessionDescriptor
    let descriptor: ClipLiveShareNativeSessionDescriptor
    let request: ClipLiveShareNativeFriendRequest
    let signedRequest: ClipLiveShareSignedNativeFriendMessage
    let acceptance: ClipLiveShareNativeFriendAcceptance
    let signedAcceptance: ClipLiveShareSignedNativeFriendMessage
    let encodedAcceptance: Data
    let timestamp: ClipLiveShareNativeTimestamp
}

private struct NativeRendezvousSentPayload: Equatable, Sendable {
    let payload: Data
    let routeID: String
}

private struct NativeRendezvousClosedRoute: Equatable, Sendable {
    let routeID: String
    let reason: String?
}

private struct NativeRendezvousHostTransportSnapshot: Sendable {
    let attachedOwners: [ClipNativeRendezvousOwner]
    let publishedDescriptors: [Data]
    let publishAttempts: Int
    let stopSharingCount: Int
    let sentPayloads: [NativeRendezvousSentPayload]
    let closedRoutes: [NativeRendezvousClosedRoute]
    let teardownFlags: [Bool]
}

private actor NativeRendezvousHostTransportSpy:
    LiveShareNativeRendezvousHostTransporting
{
    private let stream: AsyncStream<ClipNativeRendezvousEvent>
    private let continuation: AsyncStream<ClipNativeRendezvousEvent>.Continuation
    private var attachedOwners: [ClipNativeRendezvousOwner] = []
    private var publishedDescriptors: [Data] = []
    private var publishAttempts = 0
    private var stopSharingCount = 0
    private var sentPayloads: [NativeRendezvousSentPayload] = []
    private var closedRoutes: [NativeRendezvousClosedRoute] = []
    private var teardownFlags: [Bool] = []
    private let maximumSuccessfulPublishes: Int?

    init(maximumSuccessfulPublishes: Int? = nil) {
        self.maximumSuccessfulPublishes = maximumSuccessfulPublishes
        let pair = AsyncStream.makeStream(
            of: ClipNativeRendezvousEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func eventStream() -> AsyncStream<ClipNativeRendezvousEvent> { stream }

    func attach(_ owner: ClipNativeRendezvousOwner) {
        attachedOwners.append(owner)
    }

    func publish(descriptor: Data) throws {
        publishAttempts += 1
        if let maximumSuccessfulPublishes,
           publishedDescriptors.count >= maximumSuccessfulPublishes {
            throw ClipNativeRendezvousError.sendFailed
        }
        publishedDescriptors.append(descriptor)
    }

    func stopSharing() { stopSharingCount += 1 }

    func send(_ payload: Data, to routeID: String) {
        sentPayloads.append(NativeRendezvousSentPayload(
            payload: payload,
            routeID: routeID
        ))
    }

    func closeRoute(_ routeID: String, reason: String?) {
        closedRoutes.append(NativeRendezvousClosedRoute(
            routeID: routeID,
            reason: reason
        ))
    }

    func tearDown(removeRendezvous: Bool) {
        teardownFlags.append(removeRendezvous)
    }

    func emit(_ event: ClipNativeRendezvousEvent) {
        continuation.yield(event)
    }

    func finishEvents() {
        continuation.finish()
    }

    func snapshot() -> NativeRendezvousHostTransportSnapshot {
        NativeRendezvousHostTransportSnapshot(
            attachedOwners: attachedOwners,
            publishedDescriptors: publishedDescriptors,
            publishAttempts: publishAttempts,
            stopSharingCount: stopSharingCount,
            sentPayloads: sentPayloads,
            closedRoutes: closedRoutes,
            teardownFlags: teardownFlags
        )
    }
}

private actor NativeRendezvousLifecycleEventRecorder {
    private(set) var events: [LiveShareNativeRendezvousLifecycleEvent] = []

    func append(_ event: LiveShareNativeRendezvousLifecycleEvent) {
        events.append(event)
    }

    func contains(_ event: LiveShareNativeRendezvousLifecycleEvent) -> Bool {
        events.contains(event)
    }
}

private actor NativePeerHandoffTimeoutRecorder {
    private(set) var routes: [ClipLiveShareRouteID] = []

    func append(_ routeID: ClipLiveShareRouteID) {
        routes.append(routeID)
    }
}

@MainActor
private final class NativeFriendCommitRecorder {
    private(set) var records: [NativeFriendRecord] = []
    private(set) var attempts = 0
    private var remainingFailures: Int

    init(failures: Int = 0) {
        remainingFailures = failures
    }

    func commit(_ record: NativeFriendRecord) throws {
        attempts += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw NativeFriendPersistenceError.saveFailed
        }
        records.append(record)
    }
}

private final class NativeRendezvousTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.withLock { value }
    }

    func advance(by duration: Duration) {
        let components = duration.components
        let interval = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds)
                / 1_000_000_000_000_000_000
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private struct NativeRendezvousAdvancingSleeper:
    ClipLiveShareReconnectSleeper
{
    let clock: NativeRendezvousTestClock

    func sleep(for delay: Duration) async throws {
        try Task.checkCancellation()
        clock.advance(by: delay)
        await Task.yield()
        try Task.checkCancellation()
    }
}

private func makeNativeDeviceIdentity() -> NativeDeviceIdentity {
    NativeDeviceIdentity(
        signer: NativeDeviceIdentitySigner(),
        rendezvousID: .random(),
        ownerToken: .random()
    )
}

private func makeNativeRoom(
    name: String
) throws -> ClipLiveShareRoomConfiguration {
    ClipLiveShareRoomConfiguration(
        endpoint: .localDevelopment,
        capabilities: .v1Default,
        room: try ClipLiveShareRoomName(rawValue: name),
        ownerToken: .random(),
        identity: ClipLiveShareRoomIdentity()
    )
}

private func eventuallyNativeRendezvous(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private func makeCaptureWindow(
    id: UInt32,
    title: String,
    applicationName: String,
    bundleIdentifier: String? = nil
) -> ShareableCaptureWindow {
    ShareableCaptureWindow(
        id: id,
        frame: CGRect(x: 20, y: 40, width: 800, height: 600),
        title: title,
        applicationName: applicationName,
        bundleIdentifier: bundleIdentifier
            ?? "com.example.\(applicationName.lowercased())",
        processID: pid_t(id),
        pixelWidth: 1_600,
        pixelHeight: 1_200
    )
}
