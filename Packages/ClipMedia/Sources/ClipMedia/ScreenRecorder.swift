@preconcurrency import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

public struct ScreenRecordingRequest: Sendable {
    public var sessionIdentifier: UUID
    public var displayID: CGDirectDisplayID
    public var sourceRect: CGRect?
    public var excludedBundleIdentifier: String?
    /// When set, ScreenCaptureKit includes only this application's windows on
    /// the selected display. It takes precedence over `excludedBundleIdentifier`.
    public var includedApplicationBundleIdentifier: String?
    /// When set, capture is limited to this exact ScreenCaptureKit window.
    /// This is used by the guarded smoke lane so another Clip window (or a
    /// second Clip process) can never enter its synthetic recording.
    public var includedWindowID: CGWindowID?
    /// System-audio capture normally excludes Clip so interface sounds or
    /// preview playback cannot leak into a user's recording. The guarded,
    /// synthetic real-capture smoke lane opts out so an app-owned test tone can
    /// exercise ScreenCaptureKit audio delivery without opening another app.
    public var excludesCurrentProcessAudio: Bool
    public var outputURL: URL
    public var configuration: RecordingConfiguration

    public init(
        sessionIdentifier: UUID = UUID(),
        displayID: CGDirectDisplayID,
        sourceRect: CGRect? = nil,
        excludedBundleIdentifier: String? = nil,
        includedApplicationBundleIdentifier: String? = nil,
        includedWindowID: CGWindowID? = nil,
        excludesCurrentProcessAudio: Bool = true,
        outputURL: URL,
        configuration: RecordingConfiguration
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.excludedBundleIdentifier = excludedBundleIdentifier
        self.includedApplicationBundleIdentifier = includedApplicationBundleIdentifier
        self.includedWindowID = includedWindowID
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.outputURL = outputURL
        self.configuration = configuration
    }
}

/// Builds the exact ScreenCaptureKit stream plan without starting a stream.
/// Keeping this deterministic makes the Retina/native-pixel fidelity contract
/// testable without Screen Recording permission.
enum ScreenStreamConfigurationFactory {
    static func make(for request: ScreenRecordingRequest) -> SCStreamConfiguration {
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = request.configuration.width
        streamConfiguration.height = request.configuration.height
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(request.configuration.framesPerSecond)
        )
        streamConfiguration.queueDepth = 5
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA

        // `automatic` can choose the nominal one-point-per-pixel backing for
        // window/application filters and then upscale it to width/height. That
        // permanently softens interface text before any export preset runs.
        // Best asks WindowServer for the native backing resolution instead.
        streamConfiguration.captureResolution = .best
        streamConfiguration.scalesToFit = false
        streamConfiguration.preservesAspectRatio = true

        streamConfiguration.showsCursor = request.configuration.showsCursor
        streamConfiguration.showMouseClicks = request.configuration.showsClickHighlights
        streamConfiguration.capturesAudio = request.configuration.audioMode.capturesSystemAudio
        streamConfiguration.excludesCurrentProcessAudio = request.excludesCurrentProcessAudio
        streamConfiguration.captureMicrophone = request.configuration.audioMode.capturesMicrophone
        streamConfiguration.sampleRate = 48_000
        streamConfiguration.channelCount = 2
        if let sourceRect = request.sourceRect {
            streamConfiguration.sourceRect = sourceRect
        }
        return streamConfiguration
    }
}

enum ScreenRecordingFilterSelection: Equatable, Sendable {
    case display(excludedBundleIdentifier: String?)
    case application(bundleIdentifier: String)
    case window(CGWindowID)
}

enum ScreenRecordingTargetAvailability: Equatable, Sendable {
    case available
    case displayUnavailable
    case applicationUnavailable(String)
    case windowUnavailable(CGWindowID)
}

extension ScreenRecordingRequest {
    var filterSelection: ScreenRecordingFilterSelection {
        if let includedWindowID {
            return .window(includedWindowID)
        }
        if let includedApplicationBundleIdentifier {
            return .application(bundleIdentifier: includedApplicationBundleIdentifier)
        }
        return .display(excludedBundleIdentifier: excludedBundleIdentifier)
    }

    /// Resolves a persisted/live capture request against one shareable-content
    /// snapshot. Keeping this ID-only decision separate from ScreenCaptureKit
    /// objects lets display removal be exercised without capture permission.
    func targetAvailability(
        displayIDs: Set<CGDirectDisplayID>,
        applicationBundleIdentifiers: Set<String>,
        windowIDs: Set<CGWindowID> = []
    ) -> ScreenRecordingTargetAvailability {
        guard displayIDs.contains(displayID) else {
            return .displayUnavailable
        }
        if let includedWindowID {
            guard windowIDs.contains(includedWindowID) else {
                return .windowUnavailable(includedWindowID)
            }
        } else if let includedApplicationBundleIdentifier,
                  !applicationBundleIdentifiers.contains(includedApplicationBundleIdentifier) {
            return .applicationUnavailable(includedApplicationBundleIdentifier)
        }
        return .available
    }
}

public enum ScreenRecorderError: Error, Sendable {
    case alreadyRecording
    case notRecording
    case displayUnavailable
    case applicationUnavailable(String)
    case windowUnavailable(CGWindowID)
    case noVideoFrames
    case streamStopped(String)
    case streamStoppedWithRecoverableOutput(String, URL)
}

public enum ScreenRecorderEvent: Sendable {
    case firstVideoSample(sessionIdentifier: UUID, presentationTime: CMTime)
    case audioSourceUnavailable(
        sessionIdentifier: UUID,
        source: CapturedAudioSource,
        message: String
    )
    case failure(sessionIdentifier: UUID, message: String)
}

enum ScreenRecorderLifecyclePhase: Equatable, Sendable {
    case idle
    case starting(UUID)
    case recording(UUID)
    case stopping(UUID)

    var sessionIdentifier: UUID? {
        switch self {
        case .idle:
            nil
        case let .starting(identifier),
             let .recording(identifier),
             let .stopping(identifier):
            identifier
        }
    }
}

/// A small value-state gate kept separate from ScreenCaptureKit so lifecycle
/// isolation can be tested without Screen Recording permission.
struct ScreenRecorderLifecycle: Sendable {
    private(set) var phase: ScreenRecorderLifecyclePhase = .idle

    mutating func reserveStart(sessionIdentifier: UUID) -> Bool {
        guard phase == .idle else { return false }
        phase = .starting(sessionIdentifier)
        return true
    }

    mutating func completeStart(sessionIdentifier: UUID) -> Bool {
        guard phase == .starting(sessionIdentifier) else { return false }
        phase = .recording(sessionIdentifier)
        return true
    }

    mutating func abandonStart(sessionIdentifier: UUID) -> Bool {
        guard phase == .starting(sessionIdentifier) else { return false }
        phase = .idle
        return true
    }

    mutating func beginStop(sessionIdentifier: UUID) -> Bool {
        guard phase == .recording(sessionIdentifier) else { return false }
        phase = .stopping(sessionIdentifier)
        return true
    }

    mutating func completeStop(sessionIdentifier: UUID) -> Bool {
        guard phase == .stopping(sessionIdentifier) else { return false }
        phase = .idle
        return true
    }

    func acceptsSamples(sessionIdentifier: UUID) -> Bool {
        phase == .starting(sessionIdentifier) || phase == .recording(sessionIdentifier)
    }
}

enum ScreenRecorderTerminationDisposition: Equatable, Sendable {
    case discardNoVideo
    case finalize
    case finalizeRecoverableOutput(message: String)
}

/// Captures the two facts that determine how a stopped ScreenCaptureKit stream
/// is handled. A display can disappear at any point: an empty output is
/// discarded, while an output with video is finalized and surfaced as
/// recoverable material.
struct ScreenRecorderTerminationState: Equatable, Sendable {
    private(set) var hasReceivedVideoSample = false
    private(set) var streamFailureMessage: String?

    @discardableResult
    mutating func recordVideoSample() -> Bool {
        let isFirst = !hasReceivedVideoSample
        hasReceivedVideoSample = true
        return isFirst
    }

    mutating func recordStreamFailure(message: String) {
        guard streamFailureMessage == nil else { return }
        streamFailureMessage = message
    }

    var terminationDisposition: ScreenRecorderTerminationDisposition {
        guard hasReceivedVideoSample else { return .discardNoVideo }
        guard let streamFailureMessage else { return .finalize }
        return .finalizeRecoverableOutput(message: streamFailureMessage)
    }
}

enum ScreenRecorderSampleFailureDisposition: Equatable, Sendable {
    case fatal
    case audioSourceBecameUnavailable(CapturedAudioSource)
    case ignoreAlreadyUnavailableAudio(CapturedAudioSource)
}

/// ScreenCaptureKit uses valid CMSampleBuffers for stream lifecycle and idle
/// notifications as well as actual frames. Only a complete frame with an image
/// buffer is legal input for the video writer. Audio buffers do not carry this
/// attachment and are intentionally evaluated elsewhere.
enum ScreenVideoSampleEligibility {
    static func accepts(
        isValid: Bool,
        hasImageBuffer: Bool,
        frameStatusRawValue: Int?
    ) -> Bool {
        isValid
            && hasImageBuffer
            && frameStatusRawValue == SCFrameStatus.complete.rawValue
    }

    static func accepts(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        let status = attachments?.first?[.status] as? NSNumber
        return accepts(
            isValid: sampleBuffer.isValid,
            hasImageBuffer: CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
            frameStatusRawValue: status?.intValue
        )
    }
}

enum ScreenVideoSampleDimensionError: Error, Equatable, LocalizedError, Sendable {
    case mismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )

    var errorDescription: String? {
        switch self {
        case let .mismatch(expectedWidth, expectedHeight, actualWidth, actualHeight):
            String(
                localized: "Screen capture delivered a \(actualWidth) × \(actualHeight) pixel frame, but this recording requires exactly \(expectedWidth) × \(expectedHeight) pixels. Recording stopped to avoid rescaling the captured image."
            )
        }
    }
}

/// ScreenCaptureKit and AVAssetWriter must agree on one exact native-pixel
/// geometry. Rejecting a mismatch before append prevents AVFoundation from
/// silently scaling a frame to the writer's configured dimensions.
enum ScreenVideoSampleDimensionValidator {
    static func validate(
        _ pixelBuffer: CVPixelBuffer,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws {
        try validate(
            actualWidth: CVPixelBufferGetWidth(pixelBuffer),
            actualHeight: CVPixelBufferGetHeight(pixelBuffer),
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight
        )
    }

    static func validate(
        actualWidth: Int,
        actualHeight: Int,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws {
        guard actualWidth == expectedWidth, actualHeight == expectedHeight else {
            throw ScreenVideoSampleDimensionError.mismatch(
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
    }
}

/// Keeps an optional audio callback failure from escalating into a whole-stream
/// failure. A later video append failure is still fatal, which preserves the
/// distinction between a dead audio source and a globally failed writer.
struct ScreenRecorderSampleFailureGate: Sendable {
    private(set) var unavailableAudioSources: Set<CapturedAudioSource> = []

    func accepts(_ kind: CapturedSampleKind) -> Bool {
        guard let source = kind.audioSource else { return true }
        return !unavailableAudioSources.contains(source)
    }

    mutating func handleAppendFailure(
        for kind: CapturedSampleKind
    ) -> ScreenRecorderSampleFailureDisposition {
        guard let source = kind.audioSource else { return .fatal }
        guard unavailableAudioSources.insert(source).inserted else {
            return .ignoreAlreadyUnavailableAudio(source)
        }
        return .audioSourceBecameUnavailable(source)
    }
}

struct ScreenRecorderAudioRegistrationFailure: Equatable, Sendable {
    let source: CapturedAudioSource
    let message: String
}

/// Audio outputs are optional. Registration failure for a missing microphone
/// or system-audio route must not prevent video (or the other audio source)
/// from starting.
enum ScreenRecorderAudioOutputRegistration {
    static func register(
        sources: [CapturedAudioSource],
        using registration: (CapturedAudioSource) throws -> Void
    ) -> [ScreenRecorderAudioRegistrationFailure] {
        sources.compactMap { source in
            do {
                try registration(source)
                return nil
            } catch {
                return ScreenRecorderAudioRegistrationFailure(
                    source: source,
                    message: error.localizedDescription
                )
            }
        }
    }
}

private struct ScreenRecorderStopSnapshot {
    let sessionIdentifier: UUID
    let stream: SCStream
    let writer: AssetWriterSession
    let terminationState: ScreenRecorderTerminationState
}

public final class ScreenRecorder: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private let videoQueue = DispatchQueue(label: "com.tomaslejdung.clip.capture.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.tomaslejdung.clip.capture.audio", qos: .userInitiated)
    private let microphoneQueue = DispatchQueue(label: "com.tomaslejdung.clip.capture.microphone", qos: .userInitiated)

    private var stream: SCStream?
    private var writer: AssetWriterSession?
    private var request: ScreenRecordingRequest?
    private var terminationState = ScreenRecorderTerminationState()
    private var lifecycle = ScreenRecorderLifecycle()
    private var sampleFailureGate = ScreenRecorderSampleFailureGate()
    private let eventHandler: @Sendable (ScreenRecorderEvent) -> Void

    public init(
        eventHandler: @escaping @Sendable (ScreenRecorderEvent) -> Void = { _ in }
    ) {
        self.eventHandler = eventHandler
        super.init()
    }

    public var isRecording: Bool {
        lock.withLock { lifecycle.phase != .idle }
    }

    public func start(_ request: ScreenRecordingRequest) async throws {
        guard reserveStart(sessionIdentifier: request.sessionIdentifier) else {
            throw ScreenRecorderError.alreadyRecording
        }

        var createdWriter: AssetWriterSession?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            switch request.targetAvailability(
                displayIDs: Set(content.displays.map(\.displayID)),
                applicationBundleIdentifiers: Set(
                    content.applications.map(\.bundleIdentifier)
                ),
                windowIDs: Set(content.windows.map(\.windowID))
            ) {
            case .available:
                break
            case .displayUnavailable:
                throw ScreenRecorderError.displayUnavailable
            case let .applicationUnavailable(bundleIdentifier):
                throw ScreenRecorderError.applicationUnavailable(bundleIdentifier)
            case let .windowUnavailable(windowID):
                throw ScreenRecorderError.windowUnavailable(windowID)
            }
            guard let display = matchingDisplay(request.displayID, in: content.displays) else {
                throw ScreenRecorderError.displayUnavailable
            }

            let filter: SCContentFilter
            switch request.filterSelection {
            case let .display(excludedBundleIdentifier):
                let excludedApplications = excludedBundleIdentifier.map { bundleIdentifier in
                    content.applications.filter { $0.bundleIdentifier == bundleIdentifier }
                } ?? []
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: excludedApplications,
                    exceptingWindows: []
                )

            case let .application(bundleIdentifier):
                let applications = content.applications.filter {
                    $0.bundleIdentifier == bundleIdentifier
                }
                guard !applications.isEmpty else {
                    throw ScreenRecorderError.applicationUnavailable(bundleIdentifier)
                }
                filter = SCContentFilter(
                    display: display,
                    including: applications,
                    exceptingWindows: []
                )

            case let .window(windowID):
                guard let window = content.windows.first(where: {
                    $0.windowID == windowID
                }) else {
                    throw ScreenRecorderError.windowUnavailable(windowID)
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
            }

            let streamConfiguration = ScreenStreamConfigurationFactory.make(for: request)

            let writer = try AssetWriterSession(
                outputURL: request.outputURL,
                configuration: request.configuration
            )
            createdWriter = writer
            try writer.start()

            let stream = SCStream(
                filter: filter,
                configuration: streamConfiguration,
                delegate: self
            )
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            var requestedAudioSources: [CapturedAudioSource] = []
            if request.configuration.audioMode.capturesSystemAudio {
                requestedAudioSources.append(.systemAudio)
            }
            if request.configuration.audioMode.capturesMicrophone {
                requestedAudioSources.append(.microphone)
            }
            let audioRegistrationFailures = ScreenRecorderAudioOutputRegistration.register(
                sources: requestedAudioSources
            ) { source in
                switch source {
                case .systemAudio:
                    try stream.addStreamOutput(
                        self,
                        type: .audio,
                        sampleHandlerQueue: self.audioQueue
                    )
                case .microphone:
                    try stream.addStreamOutput(
                        self,
                        type: .microphone,
                        sampleHandlerQueue: self.microphoneQueue
                    )
                }
            }
            for failure in audioRegistrationFailures {
                _ = writer.disableAudioSource(failure.source)
            }

            lock.withLock {
                self.request = request
                self.writer = writer
                self.stream = stream
                self.terminationState = ScreenRecorderTerminationState()
                var failureGate = ScreenRecorderSampleFailureGate()
                for failure in audioRegistrationFailures {
                    _ = failureGate.handleAppendFailure(
                        for: failure.source == .systemAudio ? .systemAudio : .microphone
                    )
                }
                self.sampleFailureGate = failureGate
            }

            try await stream.startCapture()
            let didCompleteStart = lock.withLock {
                lifecycle.completeStart(sessionIdentifier: request.sessionIdentifier)
            }
            guard didCompleteStart else {
                throw ScreenRecorderError.notRecording
            }
            for failure in audioRegistrationFailures {
                eventHandler(
                    .audioSourceUnavailable(
                        sessionIdentifier: request.sessionIdentifier,
                        source: failure.source,
                        message: failure.message
                    )
                )
            }
        } catch {
            let shouldCleanUp = lock.withLock { () -> Bool in
                guard lifecycle.abandonStart(
                    sessionIdentifier: request.sessionIdentifier
                ) else {
                    return false
                }
                stream = nil
                writer = nil
                self.request = nil
                terminationState = ScreenRecorderTerminationState()
                sampleFailureGate = ScreenRecorderSampleFailureGate()
                return true
            }
            if shouldCleanUp {
                createdWriter?.cancelAndRemoveOutput()
            }
            throw error
        }
    }

    public func pause() throws {
        guard let writer = lock.withLock({ () -> AssetWriterSession? in
            guard let identifier = request?.sessionIdentifier,
                  lifecycle.acceptsSamples(sessionIdentifier: identifier) else {
                return nil
            }
            return self.writer
        }) else {
            throw ScreenRecorderError.notRecording
        }
        try writer.pause(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    public func resume() throws {
        guard let writer = lock.withLock({ () -> AssetWriterSession? in
            guard let identifier = request?.sessionIdentifier,
                  lifecycle.acceptsSamples(sessionIdentifier: identifier) else {
                return nil
            }
            return self.writer
        }) else {
            throw ScreenRecorderError.notRecording
        }
        try writer.resume(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    public func finish() async throws -> URL {
        let snapshot: ScreenRecorderStopSnapshot? = lock.withLock {
            guard let identifier = request?.sessionIdentifier,
                  let stream,
                  let writer,
                  lifecycle.beginStop(sessionIdentifier: identifier) else {
                return nil
            }
            let capturedState = ScreenRecorderStopSnapshot(
                sessionIdentifier: identifier,
                stream: stream,
                writer: writer,
                terminationState: self.terminationState
            )
            self.stream = nil
            self.writer = nil
            request = nil
            terminationState = ScreenRecorderTerminationState()
            sampleFailureGate = ScreenRecorderSampleFailureGate()
            return capturedState
        }
        guard let snapshot else {
            throw ScreenRecorderError.notRecording
        }
        defer {
            lock.withLock {
                _ = lifecycle.completeStop(
                    sessionIdentifier: snapshot.sessionIdentifier
                )
            }
        }
        var finalState = snapshot.terminationState
        do {
            try await snapshot.stream.stopCapture()
        } catch {
            finalState.recordStreamFailure(message: error.localizedDescription)
        }

        switch finalState.terminationDisposition {
        case .discardNoVideo:
            snapshot.writer.cancelAndRemoveOutput()
            throw ScreenRecorderError.noVideoFrames

        case .finalize:
            return try await snapshot.writer.finish()

        case let .finalizeRecoverableOutput(message):
            let outputURL = try await snapshot.writer.finish()
            throw ScreenRecorderError.streamStoppedWithRecoverableOutput(
                message,
                outputURL
            )
        }
    }

    public func cancel() async throws {
        let values = lock.withLock { () -> (UUID, SCStream, AssetWriterSession)? in
            guard let identifier = request?.sessionIdentifier,
                  let stream,
                  let writer,
                  lifecycle.beginStop(sessionIdentifier: identifier) else {
                return nil
            }
            let values = (identifier, stream, writer)
            self.stream = nil
            self.writer = nil
            request = nil
            terminationState = ScreenRecorderTerminationState()
            sampleFailureGate = ScreenRecorderSampleFailureGate()
            return values
        }
        guard let values else {
            throw ScreenRecorderError.notRecording
        }
        defer {
            lock.withLock {
                _ = lifecycle.completeStop(sessionIdentifier: values.0)
            }
        }
        var stopCaptureError: Error?
        do {
            try await values.1.stopCapture()
        } catch {
            stopCaptureError = error
        }
        values.2.cancelAndRemoveOutput()
        if let stopCaptureError {
            throw stopCaptureError
        }
    }

    private func reserveStart(sessionIdentifier: UUID) -> Bool {
        lock.withLock {
            lifecycle.reserveStart(sessionIdentifier: sessionIdentifier)
        }
    }

    private func matchingDisplay(
        _ displayID: CGDirectDisplayID,
        in displays: [SCDisplay]
    ) -> SCDisplay? {
        for display in displays where display.displayID == displayID {
            return display
        }
        return nil
    }
}

extension ScreenRecorder: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        if outputType == .screen,
           !ScreenVideoSampleEligibility.accepts(sampleBuffer) {
            return
        }
        let kind: CapturedSampleKind
        switch outputType {
        case .screen:
            kind = .video
        case .audio:
            kind = .systemAudio
        case .microphone:
            kind = .microphone
        @unknown default:
            return
        }
        let active = lock.withLock { () -> (AssetWriterSession, UUID, Int, Int)? in
            guard self.stream === stream,
                  let writer,
                  let request,
                  lifecycle.acceptsSamples(
                      sessionIdentifier: request.sessionIdentifier
                  ),
                  sampleFailureGate.accepts(kind) else {
                return nil
            }
            return (
                writer,
                request.sessionIdentifier,
                request.configuration.width,
                request.configuration.height
            )
        }
        guard let (writer, sessionIdentifier, expectedWidth, expectedHeight) = active else {
            return
        }
        do {
            if kind == .video,
               let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                try ScreenVideoSampleDimensionValidator.validate(
                    pixelBuffer,
                    expectedWidth: expectedWidth,
                    expectedHeight: expectedHeight
                )
            }
            let appendOutcome = try writer.appendClassified(sampleBuffer, kind: kind)
            let didAppend: Bool
            switch appendOutcome {
            case .appended:
                didAppend = true
            case let .intentionallyDropped(reason):
                guard reason.isExpected(for: kind) else {
                    throw AssetWriterSessionError.appendFailed(
                        "A complete screen frame was rejected unexpectedly."
                    )
                }
                didAppend = false
            }
            if didAppend, kind == .video {
                let isFirstVideoSample = lock.withLock { () -> Bool in
                    guard self.stream === stream,
                          request?.sessionIdentifier == sessionIdentifier,
                          lifecycle.acceptsSamples(
                            sessionIdentifier: sessionIdentifier
                          ) else {
                        return false
                    }
                    return terminationState.recordVideoSample()
                }
                if isFirstVideoSample {
                    eventHandler(
                        .firstVideoSample(
                            sessionIdentifier: sessionIdentifier,
                            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        )
                    )
                }
            }
        } catch {
            let disposition = lock.withLock { () -> ScreenRecorderSampleFailureDisposition? in
                guard self.stream === stream,
                      request?.sessionIdentifier == sessionIdentifier,
                      lifecycle.acceptsSamples(
                        sessionIdentifier: sessionIdentifier
                      ) else {
                    return nil
                }
                let disposition = sampleFailureGate.handleAppendFailure(for: kind)
                if disposition == .fatal {
                    terminationState.recordStreamFailure(
                        message: error.localizedDescription
                    )
                }
                return disposition
            }
            guard let disposition else { return }
            switch disposition {
            case .fatal:
                eventHandler(.failure(
                    sessionIdentifier: sessionIdentifier,
                    message: error.localizedDescription
                ))

            case let .audioSourceBecameUnavailable(source):
                _ = writer.disableAudioSource(source)
                eventHandler(.audioSourceUnavailable(
                    sessionIdentifier: sessionIdentifier,
                    source: source,
                    message: error.localizedDescription
                ))

            case .ignoreAlreadyUnavailableAudio:
                return
            }
        }
    }
}

extension ScreenRecorder: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let sessionIdentifier = lock.withLock { () -> UUID? in
            guard self.stream === stream,
                  let sessionIdentifier = request?.sessionIdentifier,
                  lifecycle.acceptsSamples(
                    sessionIdentifier: sessionIdentifier
                  ) else {
                return nil
            }
            terminationState.recordStreamFailure(message: error.localizedDescription)
            return sessionIdentifier
        }
        guard let sessionIdentifier else { return }
        eventHandler(
            .failure(
                sessionIdentifier: sessionIdentifier,
                message: error.localizedDescription
            )
        )
    }
}
