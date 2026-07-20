@preconcurrency import ScreenCaptureKit
import AudioToolbox
import CoreMedia
import Foundation

/// Owns one audio-only ScreenCaptureKit stream for Live Share. A single stream
/// produces a mixed track for all selected applications and prevents two
/// shared windows from the same application from duplicating its audio.
public final class ScreenCaptureAudioSession: NSObject, @unchecked Sendable {
    public typealias SampleConsumer = @Sendable (BorrowedCaptureAudioSample) -> Void
    public typealias EventConsumer = @Sendable (CaptureAudioSessionEvent) -> Void

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let sampleConsumer: SampleConsumer
    private let eventConsumer: EventConsumer
    private var stream: SCStream?
    private var request: CaptureAudioSessionRequest?
    private var pendingUpdateID: UUID?
    private var reportedFormatFailure = false

    public init(
        queueLabel: String = "com.tomaslejdung.clip.capture.system-audio",
        sampleConsumer: @escaping SampleConsumer,
        eventConsumer: @escaping EventConsumer = { _ in }
    ) {
        queue = DispatchQueue(label: queueLabel, qos: .userInteractive)
        self.sampleConsumer = sampleConsumer
        self.eventConsumer = eventConsumer
        super.init()
    }

    public var isRunning: Bool {
        lock.withLock { stream != nil }
    }

    public func start(_ request: CaptureAudioSessionRequest) async throws {
        guard lock.withLock({ self.stream == nil }) else {
            throw CaptureAudioSessionError.alreadyRunning
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let filter = try Self.makeFilter(for: request.scope, content: content)
        let configuration = Self.makeConfiguration(for: request.configuration)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        let reserved = lock.withLock { () -> Bool in
            guard self.stream == nil else { return false }
            self.stream = stream
            self.request = request
            pendingUpdateID = nil
            reportedFormatFailure = false
            return true
        }
        guard reserved else {
            throw CaptureAudioSessionError.alreadyRunning
        }

        do {
            try await stream.startCapture()
            eventConsumer(.started(request.identifier))
        } catch {
            lock.withLock {
                if self.stream === stream {
                    self.stream = nil
                    self.request = nil
                    pendingUpdateID = nil
                }
            }
            throw error
        }
    }

    public func update(_ request: CaptureAudioSessionRequest) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let filter = try Self.makeFilter(for: request.scope, content: content)
        let configuration = Self.makeConfiguration(for: request.configuration)
        let updateID = UUID()
        let active = lock.withLock { () -> SCStream? in
            guard let stream else { return nil }
            pendingUpdateID = updateID
            return stream
        }
        guard let active else {
            throw CaptureAudioSessionError.notRunning
        }

        do {
            try await active.updateContentFilter(filter)
            try await active.updateConfiguration(configuration)
            let committed = lock.withLock { () -> Bool in
                guard stream === active, pendingUpdateID == updateID else {
                    return false
                }
                self.request = request
                pendingUpdateID = nil
                reportedFormatFailure = false
                return true
            }
            guard committed else {
                throw CaptureAudioSessionError.notRunning
            }
            eventConsumer(.updated(request.identifier))
        } catch {
            lock.withLock {
                if pendingUpdateID == updateID {
                    pendingUpdateID = nil
                }
            }
            throw error
        }
    }

    public func stop() async throws {
        let active = lock.withLock { () -> (SCStream, UUID)? in
            guard let stream, let request else { return nil }
            self.stream = nil
            self.request = nil
            pendingUpdateID = nil
            reportedFormatFailure = false
            return (stream, request.identifier)
        }
        guard let active else {
            throw CaptureAudioSessionError.notRunning
        }
        try await active.0.stopCapture()
        eventConsumer(.stopped(active.1))
    }

    static func makeConfiguration(
        for audio: CaptureAudioConfiguration
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = audio.excludesCurrentProcessAudio
        configuration.sampleRate = CaptureAudioConfiguration.sampleRate
        configuration.channelCount = CaptureAudioConfiguration.channelCount
        return configuration
    }

    private static func makeFilter(
        for scope: CaptureAudioScope,
        content: SCShareableContent
    ) throws -> SCContentFilter {
        guard let display = content.displays.first(where: {
            $0.displayID == scope.displayID
        }) else {
            throw CaptureAudioSessionError.displayUnavailable(scope.displayID)
        }

        switch scope {
        case let .system(_, excludedBundleIdentifier):
            let excludedApplications = excludedBundleIdentifier.map { identifier in
                content.applications.filter { $0.bundleIdentifier == identifier }
            } ?? []
            return SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )

        case let .applications(_, bundleIdentifiers):
            guard !bundleIdentifiers.isEmpty else {
                throw CaptureAudioSessionError.noApplicationsRequested
            }
            let applications = content.applications.filter {
                bundleIdentifiers.contains($0.bundleIdentifier)
            }
            let availableIdentifiers = Set(applications.map(\.bundleIdentifier))
            let missing = bundleIdentifiers.subtracting(availableIdentifiers).sorted()
            guard missing.isEmpty else {
                throw CaptureAudioSessionError.applicationsUnavailable(missing)
            }
            return SCContentFilter(
                display: display,
                including: applications,
                exceptingWindows: []
            )
        }
    }

    static func validatedFormat(
        for sampleBuffer: CMSampleBuffer
    ) -> Result<Void, CaptureAudioSessionError> {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                  description
              )?.pointee else {
            return .failure(.invalidAudioFormat(
                expectedSampleRate: CaptureAudioConfiguration.sampleRate,
                expectedChannelCount: CaptureAudioConfiguration.channelCount,
                actualSampleRate: 0,
                actualChannelCount: 0
            ))
        }
        let actualSampleRate = Int(basicDescription.mSampleRate.rounded())
        let actualChannelCount = Int(basicDescription.mChannelsPerFrame)
        guard actualSampleRate == CaptureAudioConfiguration.sampleRate,
              actualChannelCount == CaptureAudioConfiguration.channelCount else {
            return .failure(.invalidAudioFormat(
                expectedSampleRate: CaptureAudioConfiguration.sampleRate,
                expectedChannelCount: CaptureAudioConfiguration.channelCount,
                actualSampleRate: actualSampleRate,
                actualChannelCount: actualChannelCount
            ))
        }
        return .success(())
    }
}

extension ScreenCaptureAudioSession: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              lock.withLock({ self.stream === stream }) else {
            return
        }
        switch Self.validatedFormat(for: sampleBuffer) {
        case .success:
            sampleConsumer(BorrowedCaptureAudioSample(sampleBuffer: sampleBuffer))

        case let .failure(error):
            let identifier = lock.withLock { () -> UUID? in
                guard self.stream === stream, !reportedFormatFailure else { return nil }
                reportedFormatFailure = true
                return request?.identifier
            }
            if let identifier {
                eventConsumer(.failed(identifier, error))
            }
        }
    }
}

extension ScreenCaptureAudioSession: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let identifier = lock.withLock { () -> UUID? in
            guard self.stream === stream else { return nil }
            let identifier = request?.identifier
            self.stream = nil
            request = nil
            pendingUpdateID = nil
            reportedFormatFailure = false
            return identifier
        }
        eventConsumer(.failed(
            identifier,
            .streamStopped(error.localizedDescription)
        ))
    }
}
