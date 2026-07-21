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
            order: 0
        )
        var state = NativeViewerV1ControlState(sessionID: sessionID)

        #expect(try state.apply(.manifest(.init(
            sessionID: sessionID,
            streams: [descriptor]
        ))) == .sourcesChanged)
        #expect(state.sourceSnapshots.first?.sourceInstanceID == "v1:video0")

        #expect(try state.apply(.geometry(.init(
            sessionID: sessionID,
            streamID: streamID,
            width: 2560,
            height: 1440
        ))) == .sourcesChanged)
        #expect(state.sourceSnapshots.first?.pixelSize.width == 2560)

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
}
