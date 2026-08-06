import ClipCapture
import CoreMedia
import CoreVideo
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import ClipLiveShareWebRTC

extension NativeMediaResourceTests {
  @Suite("Retained WebRTC frame source")
  struct WebRTCFrameSourceRetainedFrameTests {
    @Test("retained replay requires matching geometry and is cleared safely")
    func geometryAndCleanupSafety() throws {
      let sslLease = try WebRTCSSLRuntimeLease()
      let factory = RTCPeerConnectionFactory(
        encoderFactory: RTCDefaultVideoEncoderFactory(),
        decoderFactory: RTCDefaultVideoDecoderFactory()
      )
      let rtcSource = factory.videoSource(forScreenCast: true)
      let track = factory.videoTrack(
        with: rtcSource,
        trackId: "retained-frame-test"
      )
      let renderer = RetainedFrameTimestampRenderer()
      track.add(renderer)
      defer {
        track.remove(renderer)
        withExtendedLifetime(sslLease) {}
      }

      let source = WebRTCFrameSource(source: rtcSource)
      let frame = try makeRetainedFrameFixture(width: 64, height: 48)
      #expect(source.send(frame) == .accepted)
      let firstTimestamp = try #require(renderer.timestamps.last)

      #expect(!source.replayLatestFrameIfIdle(
        forAtLeast: .max,
        expectedWidth: 64,
        expectedHeight: 48
      ))
      #expect(renderer.timestamps.count == 1)

      #expect(source.replayLatestFrame(
        expectedWidth: 64,
        expectedHeight: 48
      ))
      let replayTimestamp = try #require(renderer.timestamps.last)
      #expect(renderer.timestamps.count == 2)
      #expect(replayTimestamp > firstTimestamp)

      #expect(!source.replayLatestFrame(
        expectedWidth: 32,
        expectedHeight: 48
      ))
      #expect(renderer.timestamps.count == 2)

      source.clearLatestFrame()
      #expect(!source.replayLatestFrame(
        expectedWidth: 64,
        expectedHeight: 48
      ))
      #expect(renderer.timestamps.count == 2)
    }
  }
}

private final class RetainedFrameTimestampRenderer:
  NSObject,
  RTCVideoRenderer,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storedTimestamps: [Int64] = []

  var timestamps: [Int64] {
    lock.withLock { storedTimestamps }
  }

  func setSize(_ size: CGSize) {}

  func renderFrame(_ frame: RTCVideoFrame?) {
    guard let frame else { return }
    lock.withLock { storedTimestamps.append(frame.timeStampNs) }
  }
}

private enum RetainedFrameFixtureError: Error {
  case pixelBufferCreationFailed
  case formatDescriptionCreationFailed
  case sampleBufferCreationFailed
}

func makeRetainedFrameFixture(
  width: Int,
  height: Int
) throws -> BorrowedCaptureVideoFrame {
  var pixelBuffer: CVPixelBuffer?
  guard CVPixelBufferCreate(
    kCFAllocatorDefault,
    width,
    height,
    kCVPixelFormatType_32BGRA,
    nil,
    &pixelBuffer
  ) == kCVReturnSuccess, let pixelBuffer else {
    throw RetainedFrameFixtureError.pixelBufferCreationFailed
  }

  var formatDescription: CMVideoFormatDescription?
  guard CMVideoFormatDescriptionCreateForImageBuffer(
    allocator: kCFAllocatorDefault,
    imageBuffer: pixelBuffer,
    formatDescriptionOut: &formatDescription
  ) == noErr, let formatDescription else {
    throw RetainedFrameFixtureError.formatDescriptionCreationFailed
  }

  let presentationTime = CMTime(value: 1, timescale: 30)
  var timing = CMSampleTimingInfo(
    duration: CMTime(value: 1, timescale: 30),
    presentationTimeStamp: presentationTime,
    decodeTimeStamp: .invalid
  )
  var sampleBuffer: CMSampleBuffer?
  guard CMSampleBufferCreateReadyWithImageBuffer(
    allocator: kCFAllocatorDefault,
    imageBuffer: pixelBuffer,
    formatDescription: formatDescription,
    sampleTiming: &timing,
    sampleBufferOut: &sampleBuffer
  ) == noErr, let sampleBuffer else {
    throw RetainedFrameFixtureError.sampleBufferCreationFailed
  }

  return BorrowedCaptureVideoFrame(
    sampleBuffer: sampleBuffer,
    pixelBuffer: pixelBuffer,
    presentationTime: presentationTime
  )
}
