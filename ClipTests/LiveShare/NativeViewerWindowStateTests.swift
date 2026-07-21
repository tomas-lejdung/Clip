import CoreGraphics
import Foundation
import Testing
@testable import Clip

@Suite("Native viewer window state")
struct NativeViewerWindowStateTests {
    @Test("Manual sources create independent windows")
    func manualSourcesCreateIndependentWindows() {
        var registry = NativeViewerWindowRegistry(sessionID: "session")
        let changes = registry.reconcile([
            source(instance: "one", stream: "video0", revision: 1),
            source(instance: "two", stream: "video1", revision: 1),
        ])

        #expect(changes.count == 2)
        #expect(registry.windows.count == 2)
    }

    @Test("Auto-share reuses one stable native window")
    func automaticSourceReusesWindow() {
        var registry = NativeViewerWindowRegistry(sessionID: "session")
        let first = source(
            instance: "arc-1",
            stream: "video0",
            revision: 1,
            mode: .followsFocusedWindow
        )
        let second = source(
            instance: "messages-2",
            stream: "video0",
            revision: 2,
            mode: .followsFocusedWindow
        )

        #expect(registry.reconcile([first]).count == 1)
        let changes = registry.reconcile([second])
        #expect(changes == [.update(.init(
            id: .automatic(sessionID: "session"),
            source: second,
            isVisible: true
        ))])
        #expect(registry.windows.count == 1)
    }

    @Test("Closing hides a live source and Show All restores it")
    func hiddenWindowsRemainReopenable() {
        var registry = NativeViewerWindowRegistry(sessionID: "session")
        _ = registry.reconcile([source(instance: "one", stream: "video0", revision: 1)])
        let id = NativeViewerWindowID.manual(sourceInstanceID: "one")

        #expect(registry.setVisible(false, for: id) == .visibility(id, isVisible: false))
        #expect(registry.visibleWindowCount == 0)
        #expect(registry.showAll() == [.visibility(id, isVisible: true)])
        #expect(registry.visibleWindowCount == 1)
    }

    @Test("A hidden source stays hidden across remote metadata updates")
    func metadataDoesNotOverrideLocalVisibility() {
        var registry = NativeViewerWindowRegistry(sessionID: "session")
        _ = registry.reconcile([source(instance: "one", stream: "video0", revision: 1)])
        let id = NativeViewerWindowID.manual(sourceInstanceID: "one")
        _ = registry.setVisible(false, for: id)

        let updated = source(instance: "one", stream: "video0", revision: 2, title: "Renamed")
        #expect(registry.reconcile([updated]) == [.update(.init(
            id: id,
            source: updated,
            isVisible: false
        ))])
        #expect(registry.windows[id]?.isVisible == false)
    }

    @Test("Removing a source closes its window")
    func removalClosesWindow() {
        var registry = NativeViewerWindowRegistry(sessionID: "session")
        _ = registry.reconcile([source(instance: "one", stream: "video0", revision: 1)])
        let id = NativeViewerWindowID.manual(sourceInstanceID: "one")

        #expect(registry.reconcile([]) == [.remove(id)])
        #expect(registry.windows.isEmpty)
    }

    @Test("Authoritative reconciliation restores connection after ICE recovery")
    func reconnectionRestoresConnectedPresentation() {
        var registry = NativeViewerWindowRegistry(sessionID: "session")
        let connected = source(instance: "one", stream: "video0", revision: 1)
        _ = registry.reconcile([connected])
        let id = NativeViewerWindowID.manual(sourceInstanceID: "one")
        _ = registry.setVisible(false, for: id)
        let disconnected = NativeViewerSourceSnapshot(
            sourceInstanceID: connected.sourceInstanceID,
            streamID: connected.streamID,
            applicationName: connected.applicationName,
            windowName: connected.windowName,
            pixelSize: connected.pixelSize,
            isFocused: connected.isFocused,
            isConnected: false,
            stateRevision: connected.stateRevision,
            mode: connected.mode
        )
        _ = registry.reconcile([disconnected])

        #expect(registry.windows[id]?.source.isConnected == false)
        #expect(registry.reconcile([connected]) == [.update(.init(
            id: id,
            source: connected,
            isVisible: false
        ))])
        #expect(registry.windows[id]?.source.isConnected == true)
        #expect(registry.windows[id]?.isVisible == false)
    }

    @Test("Cursor follows focus and clears the previously focused source")
    func cursorClearsAcrossTwoSourceFocusChange() {
        let firstFocused = source(
            instance: "one",
            stream: "video0",
            revision: 1,
            focused: true
        )
        let secondIdle = source(
            instance: "two",
            stream: "video1",
            revision: 1,
            focused: false
        )
        #expect(!NativeViewerCursorFocusPolicy.shouldClearCursor(
            streamID: "video0",
            authoritativeSources: [firstFocused, secondIdle]
        ))
        #expect(NativeViewerCursorFocusPolicy.shouldClearCursor(
            streamID: "video1",
            authoritativeSources: [firstFocused, secondIdle]
        ))

        let firstIdle = source(
            instance: "one",
            stream: "video0",
            revision: 2,
            focused: false
        )
        let secondFocused = source(
            instance: "two",
            stream: "video1",
            revision: 2,
            focused: true
        )
        #expect(NativeViewerCursorFocusPolicy.shouldClearCursor(
            streamID: "video0",
            authoritativeSources: [firstIdle, secondFocused]
        ))
        #expect(!NativeViewerCursorFocusPolicy.shouldClearCursor(
            streamID: "video1",
            authoritativeSources: [firstIdle, secondFocused]
        ))
        #expect(NativeViewerCursorFocusPolicy.shouldClearCursor(
            streamID: "video1",
            authoritativeSources: [firstIdle, secondIdle]
        ))
    }

    @Test("Stale duplicate auto-source state cannot replace a newer revision")
    func latestAutomaticRevisionWins() {
        var registry = NativeViewerWindowRegistry(sessionID: "session")
        let newer = source(
            instance: "new",
            stream: "video0",
            revision: 8,
            mode: .followsFocusedWindow
        )
        let stale = source(
            instance: "stale",
            stream: "video0",
            revision: 7,
            mode: .followsFocusedWindow
        )
        _ = registry.reconcile([newer, stale])

        #expect(registry.windows[.automatic(sessionID: "session")]?.source == newer)
    }

    @Test("Friend color is stable and focus only brightens it")
    func stableIdentityColor() {
        let identity = Data("alex-device-public-key".utf8)
        let first = NativeViewerIdentityColor.stable(for: identity)
        let second = NativeViewerIdentityColor.stable(for: identity)
        let focused = first.focused(true)

        #expect(first == second)
        #expect(focused.hue == first.hue)
        #expect(focused.saturation >= first.saturation)
        #expect(focused.brightness >= first.brightness)
    }

    private func source(
        instance: String,
        stream: String,
        revision: UInt64,
        title: String = "Document",
        mode: NativeViewerSourceMode = .manual,
        focused: Bool = false
    ) -> NativeViewerSourceSnapshot {
        NativeViewerSourceSnapshot(
            sourceInstanceID: instance,
            streamID: stream,
            applicationName: "Fixture",
            windowName: title,
            pixelSize: CGSize(width: 1_280, height: 720),
            isFocused: focused,
            isConnected: true,
            stateRevision: revision,
            mode: mode
        )
    }
}
