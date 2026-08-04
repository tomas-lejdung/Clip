import ClipLiveShare
import Foundation
@preconcurrency import WebRTC

/// A logical Clip stream paired with its private native WebRTC receive track.
/// App targets render this through `WebRTCRemoteVideoView` and never need to
/// import the WebRTC framework themselves.
public struct WebRTCRemoteVideoStream: Identifiable, @unchecked Sendable {
    public let descriptor: ClipLiveShareStreamDescriptor
    let track: WebRTCRemoteVideoTrackHandle

    public var id: ClipLiveShareStreamID { descriptor.id }
    public var mediaTrackID: ClipLiveShareMediaTrackID { descriptor.mediaTrackID }

    init(
        descriptor: ClipLiveShareStreamDescriptor,
        track: WebRTCRemoteVideoTrackHandle
    ) {
        self.descriptor = descriptor
        self.track = track
    }
}

final class WebRTCRemoteVideoTrackHandle: @unchecked Sendable {
    let id: String

    private let lock = NSLock()
    private let track: RTCVideoTrack
    private var isActive = true
    private var renderers: [ObjectIdentifier: any RTCVideoRenderer] = [:]

    init(track: RTCVideoTrack) {
        id = track.trackId
        self.track = track
        track.isEnabled = true
    }

    @discardableResult
    func addRenderer(_ renderer: any RTCVideoRenderer) -> Bool {
        lock.withLock {
            guard isActive else { return false }
            let key = ObjectIdentifier(renderer)
            guard renderers.updateValue(renderer, forKey: key) == nil else {
                return true
            }
            track.add(renderer)
            return true
        }
    }

    func removeRenderer(_ renderer: any RTCVideoRenderer) {
        lock.withLock {
            let key = ObjectIdentifier(renderer)
            guard renderers.removeValue(forKey: key) != nil else { return }
            track.remove(renderer)
        }
    }

    func invalidate() {
        lock.withLock {
            guard isActive else { return }
            isActive = false
            for renderer in renderers.values {
                track.remove(renderer)
            }
            renderers.removeAll(keepingCapacity: false)
            track.isEnabled = false
        }
    }
}
