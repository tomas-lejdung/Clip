import ClipLiveShare
import Foundation
@testable import ClipLiveShareWebRTC

enum ClipLiveShareWebRTCTestFixtures {
    static func streamDescriptor(
        mediaTrackID: String,
        streamID: String = "test-stream-0",
        active: Bool = true,
        focused: Bool = true,
        windowName: String = "Fixture",
        appName: String = "Clip tests",
        width: Int = 1_280,
        height: Int = 720,
        order: Int = 0
    ) -> ClipLiveShareStreamDescriptor {
        try! ClipLiveShareStreamDescriptor(
            id: ClipLiveShareStreamID(rawValue: streamID),
            mediaTrackID: ClipLiveShareMediaTrackID(rawValue: mediaTrackID),
            active: active,
            focused: focused,
            appName: appName,
            windowName: windowName,
            width: width,
            height: height,
            order: order
        )
    }

    static func streamDescriptor(
        for slot: WebRTCStreamSlotSnapshot,
        active: Bool = true,
        focused: Bool = true,
        windowName: String = "Fixture",
        appName: String = "Clip tests",
        width: Int = 1_280,
        height: Int = 720
    ) -> ClipLiveShareStreamDescriptor {
        streamDescriptor(
            mediaTrackID: slot.trackID,
            streamID: slot.streamID,
            active: active,
            focused: focused,
            windowName: windowName,
            appName: appName,
            width: width,
            height: height,
            order: slot.index
        )
    }
}
