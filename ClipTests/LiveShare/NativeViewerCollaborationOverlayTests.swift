import AppKit
import ClipLiveShare
import Testing

@testable import Clip

@Suite("Native viewer collaboration overlay")
@MainActor
struct NativeViewerCollaborationOverlayTests {
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
}
