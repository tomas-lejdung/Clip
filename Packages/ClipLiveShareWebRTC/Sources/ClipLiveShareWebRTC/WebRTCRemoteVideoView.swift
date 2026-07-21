import AppKit
import ClipLiveShare
@preconcurrency import WebRTC

/// A production AppKit render surface for one remote Clip stream.
///
/// The native WebRTC track stays private to this package. The view renders it
/// through Metal, preserves its aspect ratio with black letterboxing, and
/// reports decoded pixel geometry on the main actor. `unbind()` permits reuse;
/// `teardown()` is terminal and deterministically detaches the renderer.
@MainActor
public final class WebRTCRemoteVideoView: NSView, RTCVideoViewDelegate {
    public private(set) var decodedPixelSize: CGSize = .zero
    public private(set) var boundStreamID: ClipLiveShareStreamID?
    public private(set) var boundMediaTrackID: ClipLiveShareMediaTrackID?

    /// Called only when the decoded pixel dimensions actually change.
    public var onDecodedPixelSizeChange: ((CGSize) -> Void)?

    private let videoView: RTCMTLNSVideoView
    private var boundTrack: WebRTCRemoteVideoTrackHandle?
    private var isTornDown = false

    public override init(frame frameRect: NSRect) {
        videoView = RTCMTLNSVideoView(frame: .zero)
        super.init(frame: frameRect)
        installVideoView()
    }

    public required init?(coder: NSCoder) {
        videoView = RTCMTLNSVideoView(frame: .zero)
        super.init(coder: coder)
        installVideoView()
    }

    deinit {
        boundTrack?.removeRenderer(videoView)
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        layoutVideoView()
    }

    /// Reuses this surface for a current remote logical stream.
    public func bind(to stream: WebRTCRemoteVideoStream) {
        guard !isTornDown else { return }
        if boundTrack !== stream.track {
            boundTrack?.removeRenderer(videoView)
            boundTrack = stream.track
            guard stream.track.addRenderer(videoView) else {
                boundTrack = nil
                boundStreamID = nil
                boundMediaTrackID = nil
                updateDecodedPixelSize(.zero)
                return
            }
            updateDecodedPixelSize(.zero)
        }
        boundStreamID = stream.id
        boundMediaTrackID = stream.mediaTrackID
    }

    /// Detaches the native renderer while keeping the view reusable.
    public func unbind() {
        boundTrack?.removeRenderer(videoView)
        boundTrack = nil
        boundStreamID = nil
        boundMediaTrackID = nil
        updateDecodedPixelSize(.zero)
    }

    /// Permanently detaches the renderer and releases callbacks. Safe to call
    /// repeatedly during window/controller teardown.
    public func teardown() {
        guard !isTornDown else { return }
        unbind()
        isTornDown = true
        onDecodedPixelSizeChange = nil
        videoView.delegate = nil
        videoView.removeFromSuperview()
    }

    public nonisolated func videoView(
        _ videoView: any RTCVideoRenderer,
        didChangeVideoSize size: CGSize
    ) {
        let normalized = CGSize(
            width: max(0, size.width.rounded()),
            height: max(0, size.height.rounded())
        )
        Task { @MainActor [weak self] in
            self?.updateDecodedPixelSize(normalized)
        }
    }

    private func installVideoView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoView.delegate = self
        addSubview(videoView)
        layoutVideoView()
    }

    private func updateDecodedPixelSize(_ size: CGSize) {
        guard size != decodedPixelSize else { return }
        decodedPixelSize = size
        needsLayout = true
        layoutSubtreeIfNeeded()
        onDecodedPixelSizeChange?(size)
    }

    private func layoutVideoView() {
        guard bounds.width > 0, bounds.height > 0 else {
            videoView.frame = .zero
            return
        }
        guard decodedPixelSize.width > 0, decodedPixelSize.height > 0 else {
            videoView.frame = bounds
            return
        }
        let scale = min(
            bounds.width / decodedPixelSize.width,
            bounds.height / decodedPixelSize.height
        )
        let size = CGSize(
            width: decodedPixelSize.width * scale,
            height: decodedPixelSize.height * scale
        )
        videoView.frame = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
    }
}
