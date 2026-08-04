#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class RTCPeerConnectionFactory;

/// A full-duplex 48 kHz stereo PCM device presented to libwebrtc. Captured
/// ScreenCaptureKit audio is the recording source, while remote WebRTC audio
/// is mixed by libwebrtc and rendered through the current macOS default output
/// device. The bridge exists because WebRTC M150 ships the injectable audio
/// device implementation in its macOS binary but omits RTCAudioDevice.h from
/// that xcframework slice.
@interface ClipLiveShareWebRTCSystemAudioDevice : NSObject

/// Converts a linear-PCM Core Media sample to interleaved signed 16-bit PCM
/// and queues it for libwebrtc when its sender is running. Valid pre-viewer
/// samples are intentionally discarded but still return YES. NO is reserved
/// for malformed or unsupported audio.
- (BOOL)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;

/// Enables or disables delivery. Disabling immediately drops queued samples.
- (void)setInputEnabled:(BOOL)enabled;

/// Drops any audio waiting to be delivered.
- (void)clearQueuedAudio;

@property(nonatomic, readonly) BOOL inputEnabled;
@property(nonatomic, readonly, getter=isRecording) BOOL recording;
@property(nonatomic, readonly) NSUInteger queuedFrameCount;
@property(nonatomic, readonly) uint64_t acceptedFrameCount;
@property(nonatomic, readonly) uint64_t droppedFrameCount;
/// Captured frames that could not be delivered because the input queue ran
/// dry after playout had started. Initial prebuffering silence is excluded.
@property(nonatomic, readonly) uint64_t underflowFrameCount;
/// Calls made into WebRTC's synchronous recording delivery block.
@property(nonatomic, readonly) uint64_t deliveryCallbackCount;
/// Stereo PCM frames accepted by WebRTC's recording delivery block.
@property(nonatomic, readonly) uint64_t deliveredFrameCount;
/// Recording delivery calls rejected by WebRTC or its render callback.
@property(nonatomic, readonly) uint64_t deliveryErrorCount;
/// Calls from the macOS default-output AudioUnit into WebRTC's playout mixer.
@property(nonatomic, readonly) uint64_t playoutCallbackCount;
/// Stereo PCM frames successfully requested from WebRTC's playout mixer.
@property(nonatomic, readonly) uint64_t renderedPlayoutFrameCount;
/// Successfully rendered frames containing at least one non-zero sample.
@property(nonatomic, readonly) uint64_t nonSilentPlayoutFrameCount;
/// Output initialization, lifecycle, or mixer callback failures.
@property(nonatomic, readonly) uint64_t playoutErrorCount;

@end

/// Creates a peer factory with the custom system-audio input device. Video
/// factories are intentionally untyped here because the macOS WebRTC module
/// cannot import the forward-declared RTCAudioDevice protocol into Swift.
FOUNDATION_EXPORT RTCPeerConnectionFactory *
ClipLiveShareWebRTCCreatePeerConnectionFactory(
    id _Nullable encoderFactory,
    id _Nullable decoderFactory,
    ClipLiveShareWebRTCSystemAudioDevice *audioDevice
);

NS_ASSUME_NONNULL_END
