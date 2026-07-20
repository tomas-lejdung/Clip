#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class RTCPeerConnectionFactory;

/// A bounded 48 kHz stereo PCM source presented to libwebrtc as its recording
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
