#import "ClipLiveShareWebRTCAudioBridge.h"

#import <AudioToolbox/AudioToolbox.h>
#import <WebRTC/RTCPeerConnectionFactory.h>
#import <WebRTC/RTCVideoDecoderFactory.h>
#import <WebRTC/RTCVideoEncoderFactory.h>

#import <math.h>
#import <stdlib.h>
#import <string.h>

typedef OSStatus (^ClipRTCAudioDeviceGetPlayoutDataBlock)(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    AudioBufferList *outputData
);

typedef OSStatus (^ClipRTCAudioDeviceRenderRecordedDataBlock)(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    AudioBufferList *inputData,
    void * _Nullable renderContext
);

typedef OSStatus (^ClipRTCAudioDeviceDeliverRecordedDataBlock)(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    const AudioBufferList * _Nullable inputData,
    void * _Nullable renderContext,
    ClipRTCAudioDeviceRenderRecordedDataBlock _Nullable renderBlock
);

// These declarations are byte-for-byte compatible with RTCAudioDevice.h from
// the iOS and Catalyst slices in the same pinned WebRTC M150 xcframework. The
// macOS binary contains ObjCAudioDeviceModule and the factory selector, but its
// public header bundle accidentally leaves this protocol as a forward
// declaration. Completing it locally exposes only the supported ObjC ABI.
@protocol RTCAudioDeviceDelegate <NSObject>
@property(readonly, nonnull) ClipRTCAudioDeviceDeliverRecordedDataBlock
    deliverRecordedData;
@property(readonly) double preferredInputSampleRate;
@property(readonly) NSTimeInterval preferredInputIOBufferDuration;
@property(readonly) double preferredOutputSampleRate;
@property(readonly) NSTimeInterval preferredOutputIOBufferDuration;
@property(readonly, nonnull) ClipRTCAudioDeviceGetPlayoutDataBlock getPlayoutData;
- (void)notifyAudioInputParametersChange;
- (void)notifyAudioOutputParametersChange;
- (void)notifyAudioInputInterrupted;
- (void)notifyAudioOutputInterrupted;
- (void)dispatchAsync:(dispatch_block_t)block;
- (void)dispatchSync:(dispatch_block_t)block;
@end

@protocol RTCAudioDevice <NSObject>
@property(readonly) double deviceInputSampleRate;
@property(readonly) NSTimeInterval inputIOBufferDuration;
@property(readonly) NSInteger inputNumberOfChannels;
@property(readonly) NSTimeInterval inputLatency;
@property(readonly) double deviceOutputSampleRate;
@property(readonly) NSTimeInterval outputIOBufferDuration;
@property(readonly) NSInteger outputNumberOfChannels;
@property(readonly) NSTimeInterval outputLatency;
@property(readonly) BOOL isInitialized;
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate;
- (BOOL)terminateDevice;
@property(readonly) BOOL isPlayoutInitialized;
- (BOOL)initializePlayout;
@property(readonly) BOOL isPlaying;
- (BOOL)startPlayout;
- (BOOL)stopPlayout;
@property(readonly) BOOL isRecordingInitialized;
- (BOOL)initializeRecording;
@property(readonly) BOOL isRecording;
- (BOOL)startRecording;
- (BOOL)stopRecording;
@end

#define ClipAudioSampleRate 48000.0
enum {
    ClipAudioChannelCount = 2,
    ClipAudioFramesPerChunk = 480,
    // ScreenCaptureKit commonly batches roughly 512 ms (24,576 frames) of
    // system audio. One second absorbs two ordinary callbacks while remaining
    // bounded; only sustained delivery overload discards the oldest frames.
    ClipAudioRingCapacityFrames = 48000,
};

@interface ClipLiveShareWebRTCSystemAudioDevice () <RTCAudioDevice> {
    NSLock *_lock;
    id<RTCAudioDeviceDelegate> _delegate;
    int16_t *_ring;
    NSUInteger _ringReadFrame;
    NSUInteger _ringFrameCount;
    uint64_t _acceptedFrameCount;
    uint64_t _droppedFrameCount;
    BOOL _inputEnabled;
    BOOL _initialized;
    BOOL _playoutInitialized;
    BOOL _playing;
    BOOL _recordingInitialized;
    BOOL _recording;
    NSThread *_recordingThread;
    dispatch_semaphore_t _recordingWakeup;
    dispatch_semaphore_t _recordingFinished;
}
@end

@implementation ClipLiveShareWebRTCSystemAudioDevice

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _ring = calloc(
            ClipAudioRingCapacityFrames * ClipAudioChannelCount,
            sizeof(int16_t)
        );
        if (_ring == NULL) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self stopRecording];
    free(_ring);
}

- (double)deviceInputSampleRate { return ClipAudioSampleRate; }
- (NSTimeInterval)inputIOBufferDuration {
    return (NSTimeInterval)ClipAudioFramesPerChunk / ClipAudioSampleRate;
}
- (NSInteger)inputNumberOfChannels { return ClipAudioChannelCount; }
- (NSTimeInterval)inputLatency { return 0; }
- (double)deviceOutputSampleRate { return ClipAudioSampleRate; }
- (NSTimeInterval)outputIOBufferDuration {
    return (NSTimeInterval)ClipAudioFramesPerChunk / ClipAudioSampleRate;
}
- (NSInteger)outputNumberOfChannels { return ClipAudioChannelCount; }
- (NSTimeInterval)outputLatency { return 0; }

- (BOOL)isInitialized {
    [_lock lock];
    BOOL value = _initialized;
    [_lock unlock];
    return value;
}

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    [_lock lock];
    _delegate = delegate;
    _initialized = YES;
    [_lock unlock];
    return YES;
}

- (BOOL)terminateDevice {
    [self stopRecording];
    [_lock lock];
    _delegate = nil;
    _initialized = NO;
    _playoutInitialized = NO;
    _playing = NO;
    _recordingInitialized = NO;
    [self clearQueuedAudioLocked];
    [_lock unlock];
    return YES;
}

- (BOOL)isPlayoutInitialized {
    [_lock lock];
    BOOL value = _playoutInitialized;
    [_lock unlock];
    return value;
}

- (BOOL)initializePlayout {
    [_lock lock];
    _playoutInitialized = YES;
    [_lock unlock];
    return YES;
}

- (BOOL)isPlaying {
    [_lock lock];
    BOOL value = _playing;
    [_lock unlock];
    return value;
}

- (BOOL)startPlayout {
    [_lock lock];
    _playoutInitialized = YES;
    _playing = YES;
    [_lock unlock];
    return YES;
}

- (BOOL)stopPlayout {
    [_lock lock];
    _playing = NO;
    [_lock unlock];
    return YES;
}

- (BOOL)isRecordingInitialized {
    [_lock lock];
    BOOL value = _recordingInitialized;
    [_lock unlock];
    return value;
}

- (BOOL)initializeRecording {
    [_lock lock];
    _recordingInitialized = YES;
    [_lock unlock];
    return YES;
}

- (BOOL)isRecording {
    [_lock lock];
    BOOL value = _recording;
    [_lock unlock];
    return value;
}

- (BOOL)startRecording {
    [_lock lock];
    if (_recording) {
        [_lock unlock];
        return YES;
    }
    if (!_initialized || _delegate == nil) {
        [_lock unlock];
        return NO;
    }
    _recordingInitialized = YES;
    _recording = YES;
    // A host may enable capture before its first viewer negotiates an audio
    // sender. Never replay that pre-viewer backlog into the eventual session.
    [self clearQueuedAudioLocked];
    _recordingWakeup = dispatch_semaphore_create(0);
    _recordingFinished = dispatch_semaphore_create(0);
    _recordingThread = [[NSThread alloc] initWithTarget:self
                                               selector:@selector(recordingThreadMain)
                                                 object:nil];
    _recordingThread.name = @"Clip WebRTC system audio";
    NSThread *thread = _recordingThread;
    [_lock unlock];
    [thread start];
    return YES;
}

- (BOOL)stopRecording {
    [_lock lock];
    if (!_recording) {
        [_lock unlock];
        return YES;
    }
    _recording = NO;
    dispatch_semaphore_t wakeup = _recordingWakeup;
    dispatch_semaphore_t finished = _recordingFinished;
    [_lock unlock];
    dispatch_semaphore_signal(wakeup);
    dispatch_semaphore_wait(
        finished,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))
    );
    [_lock lock];
    _recordingThread = nil;
    _recordingWakeup = nil;
    _recordingFinished = nil;
    [self clearQueuedAudioLocked];
    [_lock unlock];
    return YES;
}

- (void)recordingThreadMain {
    @autoreleasepool {
        int64_t intervalNanoseconds = (int64_t)(NSEC_PER_SEC
            * ClipAudioFramesPerChunk / ClipAudioSampleRate);
        dispatch_time_t deadline = dispatch_time(
            DISPATCH_TIME_NOW,
            intervalNanoseconds
        );
        int64_t sampleTime = 0;
        while (YES) {
            [_lock lock];
            BOOL shouldContinue = _recording;
            dispatch_semaphore_t wakeup = _recordingWakeup;
            [_lock unlock];
            if (!shouldContinue) {
                break;
            }
            dispatch_semaphore_wait(wakeup, deadline);
            deadline = dispatch_time(deadline, intervalNanoseconds);

            int16_t samples[ClipAudioFramesPerChunk * ClipAudioChannelCount];
            memset(samples, 0, sizeof(samples));
            id<RTCAudioDeviceDelegate> delegate = nil;
            [_lock lock];
            shouldContinue = _recording;
            delegate = _delegate;
            if (shouldContinue && _inputEnabled) {
                [self popFramesLocked:samples frameCount:ClipAudioFramesPerChunk];
            }
            [_lock unlock];
            if (!shouldContinue) {
                break;
            }

            AudioBufferList audioBuffers;
            audioBuffers.mNumberBuffers = 1;
            audioBuffers.mBuffers[0].mNumberChannels = ClipAudioChannelCount;
            audioBuffers.mBuffers[0].mDataByteSize = sizeof(samples);
            audioBuffers.mBuffers[0].mData = samples;
            AudioUnitRenderActionFlags flags = 0;
            AudioTimeStamp timestamp = {0};
            timestamp.mFlags = kAudioTimeStampSampleTimeValid;
            timestamp.mSampleTime = (Float64)sampleTime;
            sampleTime += ClipAudioFramesPerChunk;
            ClipRTCAudioDeviceDeliverRecordedDataBlock deliver =
                delegate.deliverRecordedData;
            if (deliver != nil) {
                deliver(
                    &flags,
                    &timestamp,
                    0,
                    (UInt32)ClipAudioFramesPerChunk,
                    &audioBuffers,
                    NULL,
                    nil
                );
            }
        }
        [_lock lock];
        dispatch_semaphore_t finished = _recordingFinished;
        [_lock unlock];
        if (finished != nil) {
            dispatch_semaphore_signal(finished);
        }
    }
}

- (void)setInputEnabled:(BOOL)enabled {
    [_lock lock];
    _inputEnabled = enabled;
    if (!enabled) {
        [self clearQueuedAudioLocked];
    }
    [_lock unlock];
}

- (BOOL)inputEnabled {
    [_lock lock];
    BOOL value = _inputEnabled;
    [_lock unlock];
    return value;
}

- (void)clearQueuedAudio {
    [_lock lock];
    [self clearQueuedAudioLocked];
    [_lock unlock];
}

- (NSUInteger)queuedFrameCount {
    [_lock lock];
    NSUInteger value = _ringFrameCount;
    [_lock unlock];
    return value;
}

- (uint64_t)acceptedFrameCount {
    [_lock lock];
    uint64_t value = _acceptedFrameCount;
    [_lock unlock];
    return value;
}

- (uint64_t)droppedFrameCount {
    [_lock lock];
    uint64_t value = _droppedFrameCount;
    [_lock unlock];
    return value;
}

- (BOOL)enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (sampleBuffer == NULL || !CMSampleBufferIsValid(sampleBuffer)) {
        return NO;
    }
    CMAudioFormatDescriptionRef format =
        CMSampleBufferGetFormatDescription(sampleBuffer);
    const AudioStreamBasicDescription *asbd = format == NULL
        ? NULL
        : CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (asbd == NULL
        || asbd->mFormatID != kAudioFormatLinearPCM
        || fabs(asbd->mSampleRate - ClipAudioSampleRate) > 0.5
        || asbd->mChannelsPerFrame < 1
        || asbd->mChannelsPerFrame > 2
        || (asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0) {
        return NO;
    }

    CMItemCount frameCountValue = CMSampleBufferGetNumSamples(sampleBuffer);
    if (frameCountValue <= 0 || frameCountValue > NSIntegerMax) {
        return NO;
    }
    NSUInteger frameCount = (NSUInteger)frameCountValue;
    BOOL nonInterleaved =
        (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 expectedBufferCount = nonInterleaved
        ? asbd->mChannelsPerFrame
        : 1;
    size_t listSize = offsetof(AudioBufferList, mBuffers)
        + sizeof(AudioBuffer) * expectedBufferCount;
    AudioBufferList *bufferList = calloc(1, listSize);
    if (bufferList == NULL) {
        return NO;
    }
    CMBlockBufferRef retainedBlock = NULL;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        NULL,
        bufferList,
        listSize,
        kCFAllocatorDefault,
        kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        &retainedBlock
    );
    if (status != noErr || bufferList->mNumberBuffers < expectedBufferCount) {
        if (retainedBlock != NULL) {
            CFRelease(retainedBlock);
        }
        free(bufferList);
        return NO;
    }

    int16_t *converted = calloc(
        frameCount * ClipAudioChannelCount,
        sizeof(int16_t)
    );
    if (converted == NULL) {
        if (retainedBlock != NULL) {
            CFRelease(retainedBlock);
        }
        free(bufferList);
        return NO;
    }
    BOOL convertedSuccessfully = [self convertBufferList:bufferList
                                                    asbd:asbd
                                              frameCount:frameCount
                                                  output:converted];
    if (convertedSuccessfully) {
        [_lock lock];
        if (_inputEnabled && _recording) {
            [self pushFramesLocked:converted frameCount:frameCount];
            _acceptedFrameCount += frameCount;
        } else {
            _droppedFrameCount += frameCount;
        }
        [_lock unlock];
    }

    free(converted);
    if (retainedBlock != NULL) {
        CFRelease(retainedBlock);
    }
    free(bufferList);
    // A valid callback that arrives before the first viewer is deliberately
    // dropped rather than retained, but it is still a supported sample. The
    // caller uses NO to detect format/transport failures, not ordinary idle
    // periods with no active native sender.
    return convertedSuccessfully;
}

- (BOOL)convertBufferList:(const AudioBufferList *)bufferList
                     asbd:(const AudioStreamBasicDescription *)asbd
               frameCount:(NSUInteger)frameCount
                   output:(int16_t *)output {
    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL isSigned = (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    BOOL nonInterleaved =
        (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 sourceChannels = asbd->mChannelsPerFrame;
    UInt32 bytesPerSample = asbd->mBitsPerChannel / 8;
    if ((!isFloat && !isSigned)
        || !((isFloat && (bytesPerSample == 4 || bytesPerSample == 8))
             || (isSigned && (bytesPerSample == 2 || bytesPerSample == 4)))) {
        return NO;
    }

    for (NSUInteger frame = 0; frame < frameCount; ++frame) {
        for (NSUInteger outputChannel = 0;
             outputChannel < ClipAudioChannelCount;
             ++outputChannel) {
            NSUInteger sourceChannel = MIN(
                outputChannel,
                (NSUInteger)sourceChannels - 1
            );
            const AudioBuffer *audioBuffer = nonInterleaved
                ? &bufferList->mBuffers[sourceChannel]
                : &bufferList->mBuffers[0];
            if (audioBuffer->mData == NULL) {
                return NO;
            }
            UInt32 stride = nonInterleaved
                ? MAX(asbd->mBytesPerFrame, bytesPerSample)
                : asbd->mBytesPerFrame;
            NSUInteger byteOffset = frame * stride
                + (nonInterleaved ? 0 : sourceChannel * bytesPerSample);
            if (byteOffset + bytesPerSample > audioBuffer->mDataByteSize) {
                return NO;
            }
            const uint8_t *address =
                (const uint8_t *)audioBuffer->mData + byteOffset;
            int16_t value = 0;
            if (isFloat && bytesPerSample == 4) {
                float sample = *(const float *)address;
                sample = fmaxf(-1.0f, fminf(1.0f, sample));
                value = (int16_t)lrintf(sample * 32767.0f);
            } else if (isFloat && bytesPerSample == 8) {
                double sample = *(const double *)address;
                sample = fmax(-1.0, fmin(1.0, sample));
                value = (int16_t)lrint(sample * 32767.0);
            } else if (bytesPerSample == 2) {
                value = *(const int16_t *)address;
            } else {
                value = (int16_t)(*(const int32_t *)address >> 16);
            }
            output[frame * ClipAudioChannelCount + outputChannel] = value;
        }
    }
    return YES;
}

- (void)pushFramesLocked:(const int16_t *)frames
               frameCount:(NSUInteger)frameCount {
    if (frameCount >= ClipAudioRingCapacityFrames) {
        NSUInteger skipped = frameCount - ClipAudioRingCapacityFrames;
        frames += skipped * ClipAudioChannelCount;
        _droppedFrameCount += skipped + _ringFrameCount;
        _ringReadFrame = 0;
        _ringFrameCount = 0;
        frameCount = ClipAudioRingCapacityFrames;
    } else if (_ringFrameCount + frameCount > ClipAudioRingCapacityFrames) {
        NSUInteger overflow = _ringFrameCount + frameCount
            - ClipAudioRingCapacityFrames;
        _ringReadFrame = (_ringReadFrame + overflow)
            % ClipAudioRingCapacityFrames;
        _ringFrameCount -= overflow;
        _droppedFrameCount += overflow;
    }
    NSUInteger writeFrame = (_ringReadFrame + _ringFrameCount)
        % ClipAudioRingCapacityFrames;
    NSUInteger firstFrames = MIN(
        frameCount,
        ClipAudioRingCapacityFrames - writeFrame
    );
    memcpy(
        _ring + writeFrame * ClipAudioChannelCount,
        frames,
        firstFrames * ClipAudioChannelCount * sizeof(int16_t)
    );
    NSUInteger remaining = frameCount - firstFrames;
    if (remaining > 0) {
        memcpy(
            _ring,
            frames + firstFrames * ClipAudioChannelCount,
            remaining * ClipAudioChannelCount * sizeof(int16_t)
        );
    }
    _ringFrameCount += frameCount;
}

- (void)popFramesLocked:(int16_t *)output
              frameCount:(NSUInteger)frameCount {
    NSUInteger framesToRead = MIN(frameCount, _ringFrameCount);
    NSUInteger firstFrames = MIN(
        framesToRead,
        ClipAudioRingCapacityFrames - _ringReadFrame
    );
    memcpy(
        output,
        _ring + _ringReadFrame * ClipAudioChannelCount,
        firstFrames * ClipAudioChannelCount * sizeof(int16_t)
    );
    NSUInteger remaining = framesToRead - firstFrames;
    if (remaining > 0) {
        memcpy(
            output + firstFrames * ClipAudioChannelCount,
            _ring,
            remaining * ClipAudioChannelCount * sizeof(int16_t)
        );
    }
    _ringReadFrame = (_ringReadFrame + framesToRead)
        % ClipAudioRingCapacityFrames;
    _ringFrameCount -= framesToRead;
}

- (void)clearQueuedAudioLocked {
    _ringReadFrame = 0;
    _ringFrameCount = 0;
}

@end

RTCPeerConnectionFactory *ClipLiveShareWebRTCCreatePeerConnectionFactory(
    id encoderFactory,
    id decoderFactory,
    ClipLiveShareWebRTCSystemAudioDevice *audioDevice
) {
    return [[RTCPeerConnectionFactory alloc]
        initWithEncoderFactory:(id<RTCVideoEncoderFactory>)encoderFactory
                decoderFactory:(id<RTCVideoDecoderFactory>)decoderFactory
                   audioDevice:(id<RTCAudioDevice>)audioDevice];
}
