import AppKit
import ClipLiveShare
@preconcurrency import WebRTC

enum WebRTCRemoteVideoGeometry {
    /// Aspect-fits decoded pixels into an AppKit point-space container without
    /// introducing a fractional near-native stretch.
    ///
    /// Screen encoders can crop an odd source edge (for example 2,311 pixels to
    /// 2,310 for 4:2:0). The remaining dimension still supplies an exact 1x/2x
    /// scale. Working in destination backing pixels preserves that scale and
    /// leaves the cropped edge as a tiny gutter instead of linearly resampling
    /// every source pixel to fill the pre-crop logical bounds.
    static func contentFrame(
        decodedPixelSize: CGSize,
        in bounds: CGRect,
        backingScale: CGFloat
    ) -> CGRect {
        guard isValid(decodedPixelSize),
              isValid(bounds.size),
              backingScale.isFinite,
              backingScale > 0 else {
            return bounds
        }

        // Align the available edges before choosing a scale. Native AppKit
        // frames may contain half-points on Retina, which are whole backing
        // pixels and must not be rounded away in point space.
        let minimumX = (bounds.minX * backingScale).rounded()
        let minimumY = (bounds.minY * backingScale).rounded()
        let maximumX = (bounds.maxX * backingScale).rounded()
        let maximumY = (bounds.maxY * backingScale).rounded()
        let availableWidth = max(1, maximumX - minimumX)
        let availableHeight = max(1, maximumY - minimumY)

        let rawScale = min(
            availableWidth / decodedPixelSize.width,
            availableHeight / decodedPixelSize.height
        )
        let scale = nativeScaleIfWithinOneSourcePixel(
            rawScale,
            decodedPixelSize: decodedPixelSize,
            availableSize: CGSize(width: availableWidth, height: availableHeight)
        )
        let renderedWidth = max(1, (decodedPixelSize.width * scale).rounded())
        let renderedHeight = max(1, (decodedPixelSize.height * scale).rounded())
        let originX = minimumX + floor((availableWidth - renderedWidth) / 2)
        let originY = minimumY + floor((availableHeight - renderedHeight) / 2)

        return CGRect(
            x: originX / backingScale,
            y: originY / backingScale,
            width: renderedWidth / backingScale,
            height: renderedHeight / backingScale
        )
    }

    private static func nativeScaleIfWithinOneSourcePixel(
        _ rawScale: CGFloat,
        decodedPixelSize: CGSize,
        availableSize: CGSize
    ) -> CGFloat {
        guard rawScale >= 1 else { return rawScale }
        let integralScale = rawScale.rounded()
        guard integralScale >= 1 else { return rawScale }
        let horizontalRemainder = availableSize.width
            - decodedPixelSize.width * integralScale
        let verticalRemainder = availableSize.height
            - decodedPixelSize.height * integralScale
        // An encoder may remove one odd source-pixel edge. At an integral
        // destination scale that becomes `integralScale` backing pixels.
        // Preserve the exact scale and center the tiny gutter/overflow rather
        // than fractionally resampling every decoded pixel.
        let tolerance = integralScale
        guard horizontalRemainder >= -tolerance,
              verticalRemainder >= -tolerance,
              min(
                  abs(horizontalRemainder),
                  abs(verticalRemainder)
              ) <= tolerance else {
            return rawScale
        }
        return integralScale
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
    }
}

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

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
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
        videoView.frame = WebRTCRemoteVideoGeometry.contentFrame(
            decodedPixelSize: decodedPixelSize,
            in: bounds,
            backingScale: effectiveBackingScale
        )
    }

    private var effectiveBackingScale: CGFloat {
        if let scale = window?.backingScaleFactor,
           scale.isFinite,
           scale > 0 {
            return scale
        }
        if let scale = layer?.contentsScale,
           scale.isFinite,
           scale > 0 {
            return scale
        }
        return 1
    }
}
