import ClipCapture
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import WebRTC

/// Thin zero-copy bridge from ScreenCaptureKit's CVPixelBuffer to libwebrtc.
/// The underlying pixel buffer is retained by RTCCVPixelBuffer for the encoder;
/// no intermediate BGRA allocation or CPU colorspace conversion is performed.
public final class WebRTCFrameSource: RTCVideoCapturer, @unchecked Sendable {
    private let lock = NSLock()
    private var lastPresentationTimestampNanoseconds: Int64 = .min
    private var lastOutputTimestampNanoseconds: Int64 = .min
    private var latestPixelBuffer: CVPixelBuffer?

    public init(source: RTCVideoSource) {
        super.init(delegate: source)
    }

    @discardableResult
    public func send(_ frame: BorrowedCaptureVideoFrame) -> CaptureFrameDisposition {
        let presentationTimestamp = Self.nanoseconds(frame.presentationTime)
        return lock.withLock {
            guard presentationTimestamp > lastPresentationTimestampNanoseconds else {
                return .droppedBackpressure
            }
            lastPresentationTimestampNanoseconds = presentationTimestamp
            latestPixelBuffer = frame.pixelBuffer
            let timestamp = nextOutputTimestamp()
            lastOutputTimestampNanoseconds = timestamp
            emit(pixelBuffer: frame.pixelBuffer, timestampNanoseconds: timestamp)
            return .accepted
        }
    }

    /// Re-emits the single bounded latest frame with a fresh timestamp. Native
    /// WebRTC sources do not retain frames sent before a peer connects, while
    /// ScreenCaptureKit may stay idle indefinitely for an unchanged window.
    @discardableResult
    public func replayLatestFrame() -> Bool {
        lock.withLock {
            guard let latestPixelBuffer else { return false }
            let timestamp = nextOutputTimestamp()
            lastOutputTimestampNanoseconds = timestamp
            emit(pixelBuffer: latestPixelBuffer, timestampNanoseconds: timestamp)
            return true
        }
    }

    public func clearLatestFrame() {
        lock.withLock {
            latestPixelBuffer = nil
            lastPresentationTimestampNanoseconds = .min
            lastOutputTimestampNanoseconds = .min
        }
    }

    private func emit(
        pixelBuffer: CVPixelBuffer,
        timestampNanoseconds: Int64
    ) {
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let rtcFrame = RTCVideoFrame(
            buffer: rtcBuffer,
            rotation: ._0,
            timeStampNs: timestampNanoseconds
        )
        delegate?.capturer(self, didCapture: rtcFrame)
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

    /// WebRTC capture timestamps describe when a frame enters its real-time
    /// pipeline. Keep that clock independent from ScreenCaptureKit's PTS so a
    /// freshly replayed idle frame cannot make later natural PTS values stale.
    private func nextOutputTimestamp() -> Int64 {
        let now = Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        guard lastOutputTimestampNanoseconds < .max else { return .max }
        return max(now, lastOutputTimestampNanoseconds + 1)
    }
}
