import AppKit
import ClipLiveShare
import Testing

@testable import Clip

@Suite("Native viewer collaboration overlay")
@MainActor
struct NativeViewerCollaborationOverlayTests {
    @Test("pointer cadence sends immediately then retains only the latest burst sample")
    func pointerCadenceIsLatestWins() throws {
        let first = try ClipLiveShareNativeV3NormalizedPoint(x: 0.1, y: 0.2)
        let middle = try ClipLiveShareNativeV3NormalizedPoint(x: 0.4, y: 0.5)
        let latest = try ClipLiveShareNativeV3NormalizedPoint(x: 0.8, y: 0.9)
        var emitted: [ClipLiveShareNativeV3NormalizedPoint?] = []
        let coalescer = NativeViewerCollaborationPointerCoalescer(
            interval: .seconds(60),
            emit: { emitted.append($0) }
        )

        coalescer.submit(first)
        coalescer.submit(middle)
        coalescer.submit(latest)
        #expect(emitted == [first])

        coalescer.cadenceDidElapse()
        #expect(emitted == [first, latest])
        #expect(
            NativeViewerCollaborationPointerCoalescer.maximumUpdatesPerSecond
                == 60
        )
        coalescer.cancel()
    }

    @Test("pointer activity lease sends one hide after movement stops")
    func pointerInactivitySendsOneHide() throws {
        let first = try ClipLiveShareNativeV3NormalizedPoint(x: 0.2, y: 0.3)
        let latest = try ClipLiveShareNativeV3NormalizedPoint(x: 0.7, y: 0.8)
        var emitted: [ClipLiveShareNativeV3NormalizedPoint?] = []
        let coalescer = NativeViewerCollaborationPointerCoalescer(
            interval: .seconds(60),
            inactivityInterval: .seconds(60),
            emit: { emitted.append($0) }
        )

        coalescer.submit(first)
        coalescer.submit(latest)
        coalescer.cadenceDidElapse()
        #expect(emitted == [first, latest])

        coalescer.inactivityDidElapse()
        coalescer.inactivityDidElapse()
        #expect(emitted == [first, latest, nil])

        // The exact same coordinate can reveal the pointer again after the
        // inactivity hide; the hidden state is not duplicate-suppressed.
        coalescer.submit(latest)
        coalescer.cadenceDidElapse()
        #expect(emitted == [first, latest, nil, latest])
        #expect(
            NativeViewerCollaborationPointerCoalescer.inactivityInterval
                == .seconds(2)
        )
        coalescer.cancel()
    }

#if DEBUG
    @Test("pointer diagnostics classify causes with deterministic monotonic timing")
    func pointerDiagnosticsClassifyCausesAndTiming() throws {
        let point = try ClipLiveShareNativeV3NormalizedPoint(x: 0.2, y: 0.3)
        var nowNanoseconds: UInt64 = 1_000_000_000
        var diagnostics: [NativeViewerCollaborationPointerDiagnosticEvent] = []
        let coalescer = NativeViewerCollaborationPointerCoalescer(
            interval: .seconds(60),
            inactivityInterval: .seconds(60),
            diagnosticNowNanoseconds: { nowNanoseconds },
            diagnosticSink: { diagnostics.append($0) },
            emit: { _ in }
        )

        coalescer.submit(point, reason: .movement)

        nowNanoseconds += 25_000_000
        coalescer.submit(nil, reason: .invalidOrOutside)
        coalescer.cadenceDidElapse()

        nowNanoseconds += 10_000_000
        coalescer.submit(point, reason: .movement)
        coalescer.cadenceDidElapse()

        nowNanoseconds += 15_000_000
        coalescer.submit(nil, reason: .mouseExited)
        coalescer.cadenceDidElapse()

        nowNanoseconds += 10_000_000
        coalescer.submit(point, reason: .movement)
        coalescer.cadenceDidElapse()

        nowNanoseconds += 20_000_000
        coalescer.submit(nil, reason: .modeDisabled)
        coalescer.cadenceDidElapse()

        nowNanoseconds += 10_000_000
        coalescer.submit(point, reason: .movement)
        coalescer.cadenceDidElapse()

        nowNanoseconds += 2_000_000_000
        coalescer.inactivityDidElapse()

        #expect(diagnostics.map(\.sequence) == Array(1...8))
        #expect(
            diagnostics.map(\.reason) == [
                .movement,
                .invalidOrOutside,
                .movement,
                .mouseExited,
                .movement,
                .modeDisabled,
                .movement,
                .inactivity,
            ]
        )
        #expect(
            diagnostics.map(\.elapsedSincePreviousMilliseconds) == [
                nil, 25, 10, 15, 10, 20, 10, 2_000,
            ]
        )
        #expect(
            diagnostics.map(\.idleSinceMovementMilliseconds) == [
                0, 25, 0, 15, 0, 20, 0, 2_000,
            ]
        )
        coalescer.cancel()
    }
#endif

    @Test("overlay labels each pointer source transition")
    func overlayLabelsPointerSourceTransitions() throws {
        let view = NativeViewerCollaborationOverlayView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 100)
        )
        view.contentFrame = CGRect(x: 20, y: 20, width: 160, height: 60)
        var reasons: [NativeViewerCollaborationPointerUpdateReason] = []
        var visibility: [Bool] = []
        view.onPointerChanged = { position, reason in
            visibility.append(position != nil)
            reasons.append(reason)
        }

        view.interactionMode = .pointer
        view.publishPointer(atViewLocation: CGPoint(x: 50, y: 50))
        view.publishPointer(atViewLocation: CGPoint(x: 5, y: 5))
        view.publishPointer(atViewLocation: CGPoint(x: 50, y: 50))
        let exitEvent = try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        view.mouseExited(with: exitEvent)
        view.interactionMode = .disabled

        #expect(
            reasons == [
                .movement,
                .invalidOrOutside,
                .movement,
                .mouseExited,
                .modeDisabled,
            ]
        )
        #expect(visibility == [true, false, true, false, false])
    }

    @Test("unchanged pointer mode retains one tracking area across refreshes")
    func unchangedPointerModeRetainsTrackingArea() throws {
        let view = NativeViewerCollaborationOverlayView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 100)
        )
        view.contentFrame = CGRect(x: 20, y: 20, width: 160, height: 60)
        view.interactionMode = .pointer
        view.updateTrackingAreas()
        let initial = try #require(
            view.trackingAreas.first { $0.owner === view }
        )

        // Remote source snapshots reapply the same interaction mode. They
        // must not replace AppKit's tracking area and synthesize exits.
        for _ in 0..<120 {
            view.interactionMode = .pointer
            view.updateTrackingAreas()
        }

        let retained = try #require(
            view.trackingAreas.first { $0.owner === view }
        )
        #expect(retained === initial)
        #expect(view.trackingAreas.filter { $0.owner === view }.count == 1)
    }

    @Test("synthetic exit inside source is ignored but a real exit hides once")
    func syntheticExitInsideSourceIsIgnored() {
        let view = NativeViewerCollaborationOverlayView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 100)
        )
        view.contentFrame = CGRect(x: 20, y: 20, width: 160, height: 60)
        var reasons: [NativeViewerCollaborationPointerUpdateReason] = []
        view.onPointerChanged = { _, reason in reasons.append(reason) }
        view.interactionMode = .pointer

        view.publishPointer(atViewLocation: CGPoint(x: 50, y: 50))
        view.handleMouseExit(atViewLocation: CGPoint(x: 50, y: 50))
        #expect(reasons == [.movement])

        view.handleMouseExit(atViewLocation: CGPoint(x: 5, y: 5))
        view.handleMouseExit(atViewLocation: CGPoint(x: 5, y: 5))
        #expect(reasons == [.movement, .mouseExited])
    }

    @Test("verified source-relative overlay repaints without placement work")
    func publisherSnapshotBurstUsesVerifiedSourceRelativePlacement() throws {
        let sourceID = "source-relative"
        let sourceWindowNumber = 7_321
        let panelFrame = CGRect(x: 50, y: 60, width: 640, height: 360)
        var snapshotProviderCalls = 0
        var relativeOrderCalls = 0
        var verificationCalls = 0
        let coordinator = LiveShareCollaborationSourceOverlayCoordinator(
            windowSnapshotProvider: { _ in
                snapshotProviderCalls += 1
                return nil
            },
            relativeOrderAction: { panel, _ in
                relativeOrderCalls += 1
                panel.orderFrontRegardless()
            },
            relativeOrderVerifier: { _, _ in
                verificationCalls += 1
                return true
            }
        )
        defer { coordinator.tearDown() }

        let initialSnapshot = try collaborationSnapshot(pointerX: 0.1)
        coordinator.update(
            sourceID: sourceID,
            sourceFrame: panelFrame,
            target: .window(
                windowNumber: sourceWindowNumber,
                windowLevel: NSWindow.Level.normal.rawValue
            ),
            snapshot: initialSnapshot,
            isVisible: true
        )

        #expect(
            coordinator.presentationMode(sourceID: sourceID)
                == .sourceRelative
        )
        #expect(!coordinator.hasVisibilityMask(sourceID: sourceID))
        #expect(coordinator.renderedSnapshot(sourceID: sourceID) == initialSnapshot)
        #expect(
            coordinator.renderedContentFrame(sourceID: sourceID)
                == CGRect(origin: .zero, size: panelFrame.size)
        )
        #expect(coordinator.renderedAnnotationLayerCount(sourceID: sourceID) == 3)
        #expect(coordinator.orderingCount(sourceID: sourceID) == 1)
        #expect(coordinator.relativeOrderingCount(sourceID: sourceID) == 0)
        #expect(coordinator.maskedFallbackCount(sourceID: sourceID) == 0)
        #expect(snapshotProviderCalls == 0)
        #expect(relativeOrderCalls == 0)
        #expect(verificationCalls == 1)

        // Pointer traffic can arrive at 60 Hz. Repainting 120 snapshots must
        // not query WindowServer, reorder the panel, or re-verify adjacency.
        var latestSnapshot = initialSnapshot
        for frameIndex in 1...120 {
            latestSnapshot = try collaborationSnapshot(
                pointerX: Double(frameIndex) / 121
            )
            coordinator.updateSnapshot(
                sourceID: sourceID,
                snapshot: latestSnapshot,
                isVisible: true
            )
        }

        #expect(coordinator.renderedSnapshot(sourceID: sourceID) == latestSnapshot)
        #expect(coordinator.renderedAnnotationLayerCount(sourceID: sourceID) == 3)
        #expect(coordinator.orderingCount(sourceID: sourceID) == 1)
        #expect(coordinator.relativeOrderingCount(sourceID: sourceID) == 0)
        #expect(coordinator.maskedFallbackCount(sourceID: sourceID) == 0)
        #expect(snapshotProviderCalls == 0)
        #expect(relativeOrderCalls == 0)
        #expect(verificationCalls == 1)

        coordinator.updateSnapshot(
            sourceID: sourceID,
            snapshot: latestSnapshot,
            isVisible: false
        )
        coordinator.updateSnapshot(
            sourceID: sourceID,
            snapshot: latestSnapshot,
            isVisible: true
        )
        #expect(coordinator.orderingCount(sourceID: sourceID) == 1)
        #expect(snapshotProviderCalls == 0)
        #expect(relativeOrderCalls == 0)
        #expect(verificationCalls == 1)
    }

    @Test("failed relative ordering uses a conservative visibility mask")
    func publisherUnverifiedPlacementUsesMaskedFallback() throws {
        let sourceID = "masked-fallback"
        let sourceWindowNumber = 7_321
        let sourceQuartzFrame = CGRect(
            x: 100,
            y: 200,
            width: 640,
            height: 360
        )
        let sourceWindow = LiveShareCollaborationOcclusionWindowSnapshot(
            windowNumber: sourceWindowNumber,
            frame: sourceQuartzFrame,
            alpha: 1,
            isOnScreen: true
        )
        var snapshotProviderCalls = 0
        var relativeOrderCalls = 0
        var verificationCalls = 0
        let coordinator = LiveShareCollaborationSourceOverlayCoordinator(
            windowSnapshotProvider: { _ in
                snapshotProviderCalls += 1
                return [
                    .init(
                        windowNumber: 8_100,
                        frame: CGRect(
                            x: 420,
                            y: 200,
                            width: 320,
                            height: 360
                        ),
                        alpha: 1,
                        isOnScreen: true
                    ),
                    sourceWindow,
                ]
            },
            relativeOrderAction: { panel, _ in
                relativeOrderCalls += 1
                panel.orderFrontRegardless()
            },
            relativeOrderVerifier: { _, _ in
                verificationCalls += 1
                return false
            }
        )
        defer { coordinator.tearDown() }
        let snapshot = try collaborationSnapshot(pointerX: 0.25)

        coordinator.update(
            sourceID: sourceID,
            sourceFrame: CGRect(x: 50, y: 60, width: 640, height: 360),
            target: .window(
                windowNumber: sourceWindowNumber,
                windowLevel: NSWindow.Level.normal.rawValue
            ),
            snapshot: snapshot,
            isVisible: true
        )

        #expect(
            coordinator.presentationMode(sourceID: sourceID)
                == .maskedFallback
        )
        #expect(coordinator.isVisible(sourceID: sourceID))
        #expect(coordinator.hasVisibilityMask(sourceID: sourceID))
        #expect(
            coordinator.visibilityMaskBounds(sourceID: sourceID)
                == CGRect(x: 0, y: 0, width: 320, height: 360)
        )
        #expect(coordinator.renderedSnapshot(sourceID: sourceID) == snapshot)
        #expect(coordinator.renderedAnnotationLayerCount(sourceID: sourceID) == 3)
        #expect(coordinator.orderingCount(sourceID: sourceID) == 1)
        #expect(coordinator.relativeOrderingCount(sourceID: sourceID) == 1)
        #expect(coordinator.maskedFallbackCount(sourceID: sourceID) == 1)
        #expect(snapshotProviderCalls == 1)
        #expect(relativeOrderCalls == 1)
        #expect(verificationCalls == 2)

        let repaint = try collaborationSnapshot(pointerX: 0.75)
        coordinator.updateSnapshot(
            sourceID: sourceID,
            snapshot: repaint,
            isVisible: true
        )
        #expect(coordinator.renderedSnapshot(sourceID: sourceID) == repaint)
        #expect(coordinator.renderedAnnotationLayerCount(sourceID: sourceID) == 3)
        #expect(coordinator.hasVisibilityMask(sourceID: sourceID))
        #expect(snapshotProviderCalls == 1)
        #expect(relativeOrderCalls == 1)
        #expect(verificationCalls == 2)
    }

    @Test("unverifiable fallback hides annotations rather than leaking them")
    func publisherUnverifiablePlacementFailsClosed() throws {
        let sourceID = "hidden-fallback"
        var snapshotProviderCalls = 0
        var relativeOrderCalls = 0
        var verificationCalls = 0
        let coordinator = LiveShareCollaborationSourceOverlayCoordinator(
            windowSnapshotProvider: { _ in
                snapshotProviderCalls += 1
                return nil
            },
            relativeOrderAction: { panel, _ in
                relativeOrderCalls += 1
                panel.orderFrontRegardless()
            },
            relativeOrderVerifier: { _, _ in
                verificationCalls += 1
                return false
            }
        )
        defer { coordinator.tearDown() }
        let snapshot = try collaborationSnapshot(pointerX: 0.4)

        coordinator.update(
            sourceID: sourceID,
            sourceFrame: CGRect(x: 50, y: 60, width: 640, height: 360),
            target: .window(
                windowNumber: 7_321,
                windowLevel: NSWindow.Level.normal.rawValue
            ),
            snapshot: snapshot,
            isVisible: true
        )

        #expect(coordinator.presentationMode(sourceID: sourceID) == .hidden)
        #expect(!coordinator.isVisible(sourceID: sourceID))
        #expect(coordinator.hasVisibilityMask(sourceID: sourceID))
        #expect(coordinator.renderedSnapshot(sourceID: sourceID) == snapshot)
        #expect(coordinator.renderedAnnotationLayerCount(sourceID: sourceID) == 3)
        #expect(coordinator.orderingCount(sourceID: sourceID) == 1)
        #expect(coordinator.relativeOrderingCount(sourceID: sourceID) == 1)
        #expect(coordinator.maskedFallbackCount(sourceID: sourceID) == 0)
        #expect(snapshotProviderCalls == 1)
        #expect(relativeOrderCalls == 1)
        #expect(verificationCalls == 2)

        coordinator.updateSnapshot(
            sourceID: sourceID,
            snapshot: try collaborationSnapshot(pointerX: 0.8),
            isVisible: true
        )
        #expect(!coordinator.isVisible(sourceID: sourceID))
        #expect(snapshotProviderCalls == 1)
        #expect(relativeOrderCalls == 1)
        #expect(verificationCalls == 2)
    }

    @Test("masked fallback lets higher WindowServer levels occlude naturally")
    func publisherFallbackIgnoresSurfacesAboveItsPanelLevel() throws {
        let sourceID = "high-level-fallback"
        let sourceWindowNumber = 7_321
        let sourceFrame = CGRect(x: 100, y: 200, width: 640, height: 360)
        let coordinator = LiveShareCollaborationSourceOverlayCoordinator(
            windowSnapshotProvider: { _ in
                [
                    .init(
                        windowNumber: 8_100,
                        frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
                        alpha: 1,
                        isOnScreen: true,
                        windowLayer: 25
                    ),
                    .init(
                        windowNumber: sourceWindowNumber,
                        frame: sourceFrame,
                        alpha: 1,
                        isOnScreen: true,
                        windowLayer: 0
                    ),
                ]
            },
            relativeOrderAction: { panel, _ in
                panel.orderFrontRegardless()
            },
            relativeOrderVerifier: { _, _ in false }
        )
        defer { coordinator.tearDown() }

        coordinator.update(
            sourceID: sourceID,
            sourceFrame: sourceFrame,
            target: .window(
                windowNumber: sourceWindowNumber,
                windowLevel: NSWindow.Level.normal.rawValue
            ),
            snapshot: try collaborationSnapshot(pointerX: 0.75),
            isVisible: true
        )

        #expect(
            coordinator.presentationMode(sourceID: sourceID)
                == .maskedFallback
        )
        #expect(coordinator.isVisible(sourceID: sourceID))
        #expect(
            coordinator.visibilityMaskBounds(sourceID: sourceID)
                == CGRect(origin: .zero, size: sourceFrame.size)
        )
    }

    @Test("window annotations request source-relative capture-excluded placement")
    func publisherWindowOverlayOrderingPolicy() {
        let snapshot = LiveShareCollaborationSourceWindowSnapshot(
            frame: CGRect(x: 100, y: 200, width: 600, height: 400),
            windowNumber: 7_321,
            windowLevel: NSWindow.Level.normal.rawValue,
            isOnScreen: true
        )
        let target = LiveShareCollaborationSourceOverlayTarget.visibleWindow(
            snapshot
        )

        #expect(target?.panelLevel == .normal)
        #expect(target?.relativeWindowNumber == 7_321)
        #expect(target?.collectionBehavior.contains(.moveToActiveSpace) == true)
        #expect(
            target?.collectionBehavior.contains(.canJoinAllApplications)
                == true
        )
        #expect(target?.collectionBehavior.contains(.fullScreenAuxiliary) == true)
        #expect(target?.collectionBehavior.contains(.transient) == true)
        #expect(target?.collectionBehavior.contains(.stationary) == false)
        #expect(target?.collectionBehavior.contains(.canJoinAllSpaces) == false)

        #expect(
            LiveShareCollaborationSourceOverlayTarget.visibleWindow(nil) == nil
        )
        #expect(
            LiveShareCollaborationSourceOverlayTarget.visibleWindow(
                .init(
                    frame: snapshot.frame,
                    windowNumber: snapshot.windowNumber,
                    windowLevel: snapshot.windowLevel,
                    isOnScreen: false
                )
            ) == nil
        )
    }

    @Test("window metadata resolves directly from the ScreenCaptureKit ID")
    func publisherWindowMetadataUsesCaptureWindowID() throws {
        let frame = CGRect(x: 120, y: 80, width: 900, height: 600)
        let snapshot = try #require(
            LiveShareCollaborationSourceWindowSnapshot.resolve(
                windowNumber: 91_337,
                information: [
                    kCGWindowBounds as String: frame.dictionaryRepresentation,
                    kCGWindowLayer as String: NSNumber(value: 3),
                    kCGWindowIsOnscreen as String: NSNumber(value: true),
                ]
            )
        )

        #expect(snapshot.frame == frame)
        #expect(snapshot.windowNumber == 91_337)
        #expect(snapshot.windowLevel == 3)
        #expect(snapshot.isOnScreen)
    }

    @Test("fullscreen annotations retain unmasked display-level placement")
    func publisherFullscreenOverlayOrderingPolicy() throws {
        let target = LiveShareCollaborationSourceOverlayTarget.fullscreen

        #expect(target.panelLevel == .floating)
        #expect(target.relativeWindowNumber == nil)
        #expect(target.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(target.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!target.collectionBehavior.contains(.moveToActiveSpace))

        var snapshotProviderCalls = 0
        var relativeOrderCalls = 0
        var verificationCalls = 0
        let coordinator = LiveShareCollaborationSourceOverlayCoordinator(
            windowSnapshotProvider: { _ in
                snapshotProviderCalls += 1
                return nil
            },
            relativeOrderAction: { _, _ in
                relativeOrderCalls += 1
            },
            relativeOrderVerifier: { _, _ in
                verificationCalls += 1
                return false
            }
        )
        defer { coordinator.tearDown() }
        let snapshot = try collaborationSnapshot(pointerX: 0.5)
        coordinator.update(
            sourceID: "fullscreen-source",
            sourceFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            target: target,
            snapshot: snapshot,
            isVisible: true
        )
        #expect(coordinator.isVisible(sourceID: "fullscreen-source"))
        #expect(!coordinator.hasVisibilityMask(sourceID: "fullscreen-source"))
        #expect(
            coordinator.presentationMode(sourceID: "fullscreen-source")
                == .fullscreen
        )
        #expect(
            coordinator.renderedSnapshot(sourceID: "fullscreen-source")
                == snapshot
        )
        #expect(
            coordinator.renderedAnnotationLayerCount(
                sourceID: "fullscreen-source"
            ) == 3
        )
        #expect(coordinator.orderingCount(sourceID: "fullscreen-source") == 1)
        #expect(
            coordinator.relativeOrderingCount(sourceID: "fullscreen-source")
                == 0
        )
        #expect(
            coordinator.maskedFallbackCount(sourceID: "fullscreen-source")
                == 0
        )
        #expect(snapshotProviderCalls == 0)
        #expect(relativeOrderCalls == 0)
        #expect(verificationCalls == 0)
    }

    @Test("geometry maps normalized source coordinates through letterboxing")
    func geometryMapping() throws {
        let content = CGRect(x: 100, y: 50, width: 800, height: 400)
        let normalized = try #require(
            NativeViewerCollaborationGeometry.normalizedPoint(
                for: CGPoint(x: 300, y: 350),
                contentFrame: content
            )
        )
        #expect(abs(normalized.x - 0.25) < 0.000_001)
        #expect(abs(normalized.y - 0.25) < 0.000_001)
        #expect(
            NativeViewerCollaborationGeometry.point(
                for: normalized,
                contentFrame: content
            ) == CGPoint(x: 300, y: 350)
        )
        #expect(
            NativeViewerCollaborationGeometry.normalizedPoint(
                for: CGPoint(x: 99, y: 350),
                contentFrame: content
            ) == nil
        )
    }

    @Test("disabled overlay does not intercept viewer-window input")
    func disabledHitTesting() {
        let view = NativeViewerCollaborationOverlayView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 100)
        )
        #expect(view.hitTest(CGPoint(x: 50, y: 50)) == nil)
        view.interactionMode = .pointer
        #expect(view.hitTest(CGPoint(x: 50, y: 50)) === view)
        view.interactionMode = .disabled
        #expect(view.hitTest(CGPoint(x: 50, y: 50)) == nil)
    }

    @Test("overlay renders participant state inside the decoded content rect")
    func rendersParticipantState() throws {
        let participant = try ClipLiveShareNativeV3ParticipantID(
            bytes: Data(
                repeating: 3,
                count: ClipLiveShareNativeV3.participantIDByteCount
            )
        )
        let color = try ClipLiveShareNativeV3CollaborationColor(
            red: 90,
            green: 130,
            blue: 240
        )
        let point = try ClipLiveShareNativeV3NormalizedPoint(x: 0.5, y: 0.5)
        let view = NativeViewerCollaborationOverlayView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        view.contentFrame = CGRect(x: 20, y: 50, width: 360, height: 200)
        view.update(
            NativeViewerCollaborationOverlaySnapshot(
                pointers: [
                    NativeViewerCollaborationPointer(
                        participantID: participant,
                        participantName: "Anna",
                        color: color,
                        position: point
                    )
                ],
                pings: [
                    NativeViewerCollaborationPing(
                        id: UUID(),
                        participantID: participant,
                        color: color,
                        position: point
                    )
                ],
                strokes: [
                    NativeViewerCollaborationStroke(
                        participantID: participant,
                        strokeID: .init(),
                        color: color,
                        points: [
                            try .init(x: 0, y: 0),
                            try .init(x: 1, y: 1),
                        ]
                    )
                ]
            )
        )
        #expect((view.layer?.sublayers?.count ?? 0) >= 3)
    }

    @Test("focused sharing control stays capture-excluded and interactive")
    func focusedControlHitTestingAndTearDown() throws {
        let controller = MeshFocusedWindowControlCoordinator(actions: .init())
        controller.show(
            snapshot: MeshParticipantFocusedWindowControlSnapshot(
                sourceID: "window-42",
                sourceInstanceID: .random(),
                applicationName: "Notes",
                windowTitle: "Planning",
                appKitFrame: CGRect(
                    x: 100,
                    y: 100,
                    width: 800,
                    height: 600
                ),
                state: .live
            ),
            visibleScreenFrame: CGRect(
                x: 0,
                y: 0,
                width: 1_440,
                height: 900
            )
        )

        #expect(controller.isVisible)
        #expect(controller.panel.sharingType == .none)
        #expect(!controller.panel.ignoresMouseEvents)
        #expect(
            controller.contentHitTest(
                at: CGPoint(
                    x: MeshParticipantOverlayGeometry.focusedControlSize.width
                        / 2,
                    y: MeshParticipantOverlayGeometry.focusedControlSize.height
                        / 2
                )
            ) != nil
        )

        controller.tearDown()
        #expect(!controller.isVisible)
        #expect(controller.panel.contentView == nil)
    }

    @Test("local status HUD normalizes slots and tears down its hit surface")
    func localStatusHUDHitTestingAndTearDown() {
        let snapshot = MeshLocalStatusHUDSnapshot(
            sourceStatuses: [.starting, .live],
            participantCount: 0,
            fullscreen: .init(isOn: false, displayName: "Main")
        )
        #expect(snapshot.sourceStatuses.count == 4)
        #expect(snapshot.sourceStatuses[0] == .starting)
        #expect(snapshot.sourceStatuses[1] == .live)
        #expect(snapshot.sourceStatuses[2] == nil)
        #expect(snapshot.participantCount == 1)
        #expect(snapshot.hasActiveMedia)

        let controller = MeshLocalStatusHUDCoordinator(actions: .init())
        controller.show(
            snapshot: snapshot,
            visibleScreenFrame: CGRect(
                x: 0,
                y: 0,
                width: 1_440,
                height: 900
            )
        )

        #expect(controller.isVisible)
        #expect(controller.panel.sharingType == .none)
        #expect(!controller.panel.ignoresMouseEvents)
        #expect(
            controller.contentHitTest(
                at: CGPoint(
                    x: MeshParticipantOverlayGeometry.statusHUDSize.width / 2,
                    y: MeshParticipantOverlayGeometry.statusHUDSize.height / 2
                )
            ) != nil
        )

        controller.tearDown()
        #expect(!controller.isVisible)
        #expect(controller.panel.contentView == nil)
    }

    @Test("local status HUD stays hidden over a fullscreen native viewer")
    func localStatusHUDHidesForFullScreenViewer() {
        let suppressing = MeshLocalStatusHUDVisibilityPolicy.WindowState(
            isFullScreenNativeViewer: true,
            isVisible: true,
            isOnActiveSpace: true,
            isOnTargetScreen: true
        )
        #expect(
            MeshLocalStatusHUDVisibilityPolicy.shouldPresent(
                windowStates: []
            )
        )
        #expect(
            !MeshLocalStatusHUDVisibilityPolicy.shouldPresent(
                windowStates: [suppressing]
            )
        )
        #expect(
            MeshLocalStatusHUDVisibilityPolicy.shouldPresent(
                windowStates: [
                    .init(
                        isFullScreenNativeViewer: true,
                        isVisible: false,
                        isOnActiveSpace: true,
                        isOnTargetScreen: true
                    ),
                    .init(
                        isFullScreenNativeViewer: true,
                        isVisible: true,
                        isOnActiveSpace: false,
                        isOnTargetScreen: true
                    ),
                    .init(
                        isFullScreenNativeViewer: true,
                        isVisible: true,
                        isOnActiveSpace: true,
                        isOnTargetScreen: false
                    ),
                ]
            )
        )
    }

    @Test("mesh overlay geometry stays inside the active screen")
    func meshOverlayGeometry() {
        let focused = MeshParticipantOverlayGeometry.focusedControlFrame(
            targetWindowFrame: CGRect(
                x: -1_900,
                y: -40,
                width: 220,
                height: 160
            ),
            visibleScreenFrame: CGRect(
                x: -1_920,
                y: 0,
                width: 1_920,
                height: 1_057
            ),
            side: .left
        )
        #expect(focused.origin == CGPoint(x: -1_884, y: 0))
        #expect(
            CGRect(x: -1_920, y: 0, width: 1_920, height: 1_057)
                .contains(focused)
        )

        let status = MeshParticipantOverlayGeometry.statusHUDFrame(
            visibleScreenFrame: CGRect(
                x: 1_440,
                y: 23,
                width: 2_560,
                height: 1_417
            )
        )
        #expect(status == CGRect(x: 3_798, y: 1_362, width: 190, height: 66))
    }

    private func collaborationSnapshot(
        pointerX: Double
    ) throws -> NativeViewerCollaborationOverlaySnapshot {
        let participant = try ClipLiveShareNativeV3ParticipantID(
            bytes: Data(
                repeating: 4,
                count: ClipLiveShareNativeV3.participantIDByteCount
            )
        )
        let color = try ClipLiveShareNativeV3CollaborationColor(
            red: 80,
            green: 140,
            blue: 220
        )
        return NativeViewerCollaborationOverlaySnapshot(
            pointers: [
                .init(
                    participantID: participant,
                    participantName: "Viewer",
                    color: color,
                    position: try .init(x: pointerX, y: 0.75)
                )
            ],
            pings: [
                .init(
                    id: UUID(),
                    participantID: participant,
                    color: color,
                    position: try .init(x: 0.5, y: 0.5)
                )
            ],
            strokes: [
                .init(
                    participantID: participant,
                    strokeID: .init(),
                    color: color,
                    points: [
                        try .init(x: 0.1, y: 0.1),
                        try .init(x: 0.9, y: 0.9),
                    ]
                )
            ]
        )
    }
}
