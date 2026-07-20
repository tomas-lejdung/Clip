@preconcurrency import ScreenCaptureKit
import AudioToolbox
import CoreMedia
import Testing
@testable import ClipCapture

@Suite("Live Share system-audio capture")
struct CaptureAudioTests {
    @Test("audio capture is fixed at 48 kHz stereo and excludes Clip by default")
    func streamConfiguration() {
        let value = CaptureAudioConfiguration()
        let configuration = ScreenCaptureAudioSession.makeConfiguration(for: value)

        #expect(CaptureAudioConfiguration.sampleRate == 48_000)
        #expect(CaptureAudioConfiguration.channelCount == 2)
        #expect(configuration.capturesAudio)
        #expect(configuration.excludesCurrentProcessAudio)
        #expect(configuration.sampleRate == 48_000)
        #expect(configuration.channelCount == 2)
    }

    @Test("the current-process exclusion remains explicitly configurable")
    func currentProcessAudio() {
        let configuration = ScreenCaptureAudioSession.makeConfiguration(
            for: CaptureAudioConfiguration(excludesCurrentProcessAudio: false)
        )
        #expect(!configuration.excludesCurrentProcessAudio)
    }

    @Test("application scopes deduplicate and trim bundle identifiers")
    func normalizedApplications() {
        let request = CaptureAudioSessionRequest(scope: .applications(
            displayID: 42,
            bundleIdentifiers: [
                "com.example.browser",
                " com.example.browser ",
                "com.example.player",
                "  ",
            ]
        ))
        #expect(request.scope == .applications(
            displayID: 42,
            bundleIdentifiers: ["com.example.browser", "com.example.player"]
        ))
    }

    @Test("empty system exclusions are normalized away")
    func normalizedExclusion() {
        let request = CaptureAudioSessionRequest(scope: .system(
            displayID: 7,
            excludedBundleIdentifier: " \n "
        ))
        #expect(request.scope == .system(
            displayID: 7,
            excludedBundleIdentifier: nil
        ))
    }

    @Test("scope exposes the display used by ScreenCaptureKit")
    func displayIdentity() {
        #expect(CaptureAudioScope.system(
            displayID: 11,
            excludedBundleIdentifier: nil
        ).displayID == 11)
        #expect(CaptureAudioScope.applications(
            displayID: 12,
            bundleIdentifiers: ["com.example.app"]
        ).displayID == 12)
    }

    @Test("48 kHz stereo LPCM samples satisfy the delivery contract")
    func validAudioFormat() throws {
        let sample = try makeAudioSample(sampleRate: 48_000, channelCount: 2)
        switch ScreenCaptureAudioSession.validatedFormat(for: sample) {
        case .success:
            break
        case let .failure(error):
            Issue.record("Expected the configured audio format, got \(error)")
        }
    }

    @Test("unexpected audio formats are rejected before WebRTC delivery")
    func invalidAudioFormat() throws {
        let sample = try makeAudioSample(sampleRate: 44_100, channelCount: 1)
        switch ScreenCaptureAudioSession.validatedFormat(for: sample) {
        case .success:
            Issue.record("Expected the sample to be rejected")
        case let .failure(error):
            #expect(error == .invalidAudioFormat(
                expectedSampleRate: 48_000,
                expectedChannelCount: 2,
                actualSampleRate: 44_100,
                actualChannelCount: 1
            ))
        }
    }

    private func makeAudioSample(
        sampleRate: Double,
        channelCount: UInt32
    ) throws -> CMSampleBuffer {
        let frameCount = 16
        let bytesPerFrame = channelCount * UInt32(MemoryLayout<Float>.size)
        let byteCount = frameCount * Int(bytesPerFrame)
        var blockBuffer: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr)
        guard let blockBuffer else { throw AudioFixtureError.cannotCreateBlockBuffer }

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr)
        guard let formatDescription else { throw AudioFixtureError.cannotCreateFormat }

        var sampleBuffer: CMSampleBuffer?
        #expect(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr)
        guard let sampleBuffer else { throw AudioFixtureError.cannotCreateSample }
        return sampleBuffer
    }
}

private enum AudioFixtureError: Error {
    case cannotCreateBlockBuffer
    case cannotCreateFormat
    case cannotCreateSample
}
