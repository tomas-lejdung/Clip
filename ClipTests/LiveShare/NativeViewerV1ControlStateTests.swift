import ClipLiveShare
import Testing
@testable import Clip

struct NativeViewerV1ControlStateTests {
    @Test
    func fullAndIncrementalStateProducesStableWindows() throws {
        let sessionID = try ClipLiveShareSessionID(rawValue: "viewer-session")
        let streamID = try ClipLiveShareStreamID(rawValue: "video0")
        let trackID = try ClipLiveShareMediaTrackID(rawValue: "track0")
        let descriptor = try ClipLiveShareStreamDescriptor(
            id: streamID,
            mediaTrackID: trackID,
            active: true,
            focused: false,
            appName: "Keynote",
            windowName: "Deck",
            width: 1920,
            height: 1080,
            order: 0,
            sourcePointWidth: 960,
            sourcePointHeight: 540
        )
        var state = NativeViewerV1ControlState(sessionID: sessionID)

        #expect(try state.apply(.manifest(.init(
            sessionID: sessionID,
            streams: [descriptor]
        ))) == .sourcesChanged)
        #expect(state.sourceSnapshots.first?.sourceInstanceID == "v1:video0")
        #expect(state.sourceSnapshots.first?.sourcePointSize == .init(width: 960, height: 540))

        #expect(try state.apply(.geometry(.init(
            sessionID: sessionID,
            streamID: streamID,
            width: 2560,
            height: 1440
        ))) == .sourcesChanged)
        #expect(state.sourceSnapshots.first?.pixelSize.width == 2560)
        #expect(state.sourceSnapshots.first?.sourcePointSize == .init(width: 960, height: 540))

        #expect(try state.apply(.focus(.init(
            sessionID: sessionID,
            streamID: streamID
        ))) == .sourcesChanged)
        #expect(state.sourceSnapshots.first?.isFocused == true)
    }

    @Test
    func unknownIncrementalAndCrossSessionMessagesCannotCreateState() throws {
        let sessionID = try ClipLiveShareSessionID(rawValue: "viewer-session")
        let otherSessionID = try ClipLiveShareSessionID(rawValue: "other-session")
        let streamID = try ClipLiveShareStreamID(rawValue: "video0")
        var state = NativeViewerV1ControlState(sessionID: sessionID)

        #expect(try state.apply(.streamState(.init(
            sessionID: sessionID,
            streamID: streamID,
            active: true
        ))) == .ignored)
        #expect(state.sourceSnapshots.isEmpty)

        #expect(throws: (any Error).self) {
            try state.apply(.sharingState(.init(
                sessionID: otherSessionID,
                sharing: true
            )))
        }
    }

    @Test
    func cursorUsesNormalizedCoordinatesAndHidesOutOfView() throws {
        let sessionID = try ClipLiveShareSessionID(rawValue: "viewer-session")
        let streamID = try ClipLiveShareStreamID(rawValue: "video0")
        let trackID = try ClipLiveShareMediaTrackID(rawValue: "track0")
        var state = NativeViewerV1ControlState(sessionID: sessionID)
        _ = try state.apply(.manifest(.init(
            sessionID: sessionID,
            streams: [try .init(
                id: streamID,
                mediaTrackID: trackID,
                active: true,
                focused: true,
                appName: "Arc",
                windowName: "Docs",
                width: 800,
                height: 600,
                order: 0
            )]
        )))

        let effect = try state.apply(.cursor(.init(
            sessionID: sessionID,
            streamID: streamID,
            x: 25,
            y: 75,
            inView: true
        )))
        #expect(effect == .cursorChanged(.init(
            streamID: "video0",
            normalizedX: 0.25,
            normalizedY: 0.75
        )))
    }

    @Test("Cursor follows authoritative focus and rejects delayed packets")
    func cursorFollowsFocusAndRejectsDelayedPackets() throws {
        let sessionID = try ClipLiveShareSessionID(rawValue: "viewer-session")
        let firstID = try ClipLiveShareStreamID(rawValue: "video0")
        let secondID = try ClipLiveShareStreamID(rawValue: "video1")
        var state = NativeViewerV1ControlState(sessionID: sessionID)
        _ = try state.apply(.manifest(.init(
            sessionID: sessionID,
            streams: [
                try .init(
                    id: firstID,
                    mediaTrackID: .init(rawValue: "track0"),
                    active: true,
                    focused: true,
                    appName: "Arc",
                    windowName: "Docs",
                    width: 800,
                    height: 600,
                    order: 0
                ),
                try .init(
                    id: secondID,
                    mediaTrackID: .init(rawValue: "track1"),
                    active: true,
                    focused: false,
                    appName: "Messages",
                    windowName: "Chat",
                    width: 900,
                    height: 700,
                    order: 1
                ),
            ]
        )))

        #expect(try state.apply(.cursor(.init(
            sessionID: sessionID,
            streamID: firstID,
            x: 10,
            y: 20,
            inView: true
        ))) == .cursorChanged(.init(
            streamID: "video0",
            normalizedX: 0.1,
            normalizedY: 0.2
        )))
        #expect(state.cursors[firstID] != nil)

        #expect(try state.apply(.focus(.init(
            sessionID: sessionID,
            streamID: secondID
        ))) == .sourcesChanged)
        #expect(state.cursors.isEmpty)

        // This sample was queued before the focus change. It must not restore
        // the cursor on the old source or affect the new focused source.
        #expect(try state.apply(.cursor(.init(
            sessionID: sessionID,
            streamID: firstID,
            x: 30,
            y: 40,
            inView: true
        ))) == .ignored)
        #expect(state.cursors.isEmpty)

        #expect(try state.apply(.cursor(.init(
            sessionID: sessionID,
            streamID: secondID,
            x: 50,
            y: 60,
            inView: true
        ))) == .cursorChanged(.init(
            streamID: "video1",
            normalizedX: 0.5,
            normalizedY: 0.6
        )))
        #expect(state.cursors[firstID] == nil)
        #expect(state.cursors[secondID] != nil)
    }
}
