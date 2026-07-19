import ClipCapture
import CoreMedia
import Foundation
@preconcurrency import WebRTC

/// Thin zero-copy bridge from ScreenCaptureKit's CVPixelBuffer to libwebrtc.
/// The underlying pixel buffer is retained by RTCCVPixelBuffer for the encoder;
/// no intermediate BGRA allocation or CPU colorspace conversion is performed.
public final class WebRTCFrameSource: RTCVideoCapturer, @unchecked Sendable {
    private let lock = NSLock()
    private var lastTimestampNanoseconds: Int64 = .min

    public init(source: RTCVideoSource) {
        super.init(delegate: source)
    }

    @discardableResult
    public func send(_ frame: BorrowedCaptureVideoFrame) -> CaptureFrameDisposition {
        let timestamp = Self.nanoseconds(frame.presentationTime)
        let isNewer = lock.withLock { () -> Bool in
            guard timestamp > lastTimestampNanoseconds else { return false }
            lastTimestampNanoseconds = timestamp
            return true
        }
        guard isNewer else { return .droppedBackpressure }

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: frame.pixelBuffer)
        let rtcFrame = RTCVideoFrame(
            buffer: rtcBuffer,
            rotation: ._0,
            timeStampNs: timestamp
        )
        delegate?.capturer(self, didCapture: rtcFrame)
        return .accepted
    }

    private static func nanoseconds(_ time: CMTime) -> Int64 {
        guard time.isValid, !time.isIndefinite else { return 0 }
        let converted = CMTimeConvertScale(
            time,
            timescale: 1_000_000_000,
            method: .default
        )
        return converted.value
    }
}
