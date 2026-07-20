import ClipCapture
import ClipLiveShare
import ClipLiveShareWebRTC
import CoreGraphics
import Foundation
import Testing
@testable import Clip

@Suite("Live Share coordinator policy")
struct LiveShareCoordinatorPolicyTests {
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

    @Test("H.264 aspect-fits 5K and 6K while VP8 stays native")
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

    @Test("manual sharing never evicts a fifth window while auto-share may")
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
        #expect(ledger.receiveRemoteICE(remote, for: "viewer-1") == nil)
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
        #expect(ledger.receiveRemoteICE(remote, for: "viewer-1") == nil)
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
        for candidate in candidates {
            #expect(ledger.receiveRemoteICE(candidate, for: "viewer-1") == nil)
        }
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
        #expect(ledger.receiveRemoteICE(candidates[0], for: "unknown") == nil)

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
}

private func makeCaptureWindow(
    id: UInt32,
    title: String,
    applicationName: String
) -> ShareableCaptureWindow {
    ShareableCaptureWindow(
        id: id,
        frame: CGRect(x: 20, y: 40, width: 800, height: 600),
        title: title,
        applicationName: applicationName,
        bundleIdentifier: "com.example.\(applicationName.lowercased())",
        processID: pid_t(id),
        pixelWidth: 1_600,
        pixelHeight: 1_200
    )
}
