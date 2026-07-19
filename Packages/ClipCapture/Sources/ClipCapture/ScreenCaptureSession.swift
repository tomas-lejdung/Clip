@preconcurrency import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

public final class ScreenCaptureSession: NSObject, @unchecked Sendable {
    public typealias FrameConsumer = @Sendable (BorrowedCaptureVideoFrame) -> CaptureFrameDisposition
    public typealias EventConsumer = @Sendable (CaptureSessionEvent) -> Void

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let frameConsumer: FrameConsumer
    private let eventConsumer: EventConsumer
    private var stream: SCStream?
    private var request: CaptureSessionRequest?
    private var pendingUpdate: (id: UUID, request: CaptureSessionRequest)?
    private var backpressure = CaptureBackpressureCounter()

    public init(
        queueLabel: String = "com.tomaslejdung.clip.capture.raw-video",
        frameConsumer: @escaping FrameConsumer,
        eventConsumer: @escaping EventConsumer = { _ in }
    ) {
        queue = DispatchQueue(label: queueLabel, qos: .userInteractive)
        self.frameConsumer = frameConsumer
        self.eventConsumer = eventConsumer
        super.init()
    }

    public var isRunning: Bool {
        lock.withLock { stream != nil }
    }

    public var statistics: CaptureDeliveryStatistics {
        lock.withLock { backpressure.statistics }
    }

    public func start(_ request: CaptureSessionRequest) async throws {
        guard lock.withLock({ self.stream == nil }) else {
            throw CaptureSessionError.alreadyRunning
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let filter = try Self.makeFilter(for: request.target, content: content)
        let configuration = Self.makeConfiguration(for: request.video)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        let reserved = lock.withLock { () -> Bool in
            guard self.stream == nil else { return false }
            self.stream = stream
            self.request = request
            pendingUpdate = nil
            backpressure = CaptureBackpressureCounter()
            return true
        }
        guard reserved else {
            throw CaptureSessionError.alreadyRunning
        }

        do {
            try await stream.startCapture()
            eventConsumer(.started(request.identifier))
        } catch {
            lock.withLock {
                if self.stream === stream {
                    self.stream = nil
                    self.request = nil
                    self.pendingUpdate = nil
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
            pendingUpdate = nil
            return (stream, request.identifier)
        }
        guard let active else { throw CaptureSessionError.notRunning }
        try await active.0.stopCapture()
        eventConsumer(.stopped(active.1, statistics))
    }

    public func update(
        target: CaptureTarget,
        video: CaptureVideoConfiguration
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let filter = try Self.makeFilter(for: target, content: content)
        let configuration = Self.makeConfiguration(for: video)
        let updateID = UUID()
        let active = lock.withLock { () -> (SCStream, CaptureSessionRequest)? in
            guard let stream, var request else { return nil }
            request.target = target
            request.video = video
            pendingUpdate = (updateID, request)
            return (stream, request)
        }
        guard let active else { throw CaptureSessionError.notRunning }
        do {
            try await active.0.updateContentFilter(filter)
            try await active.0.updateConfiguration(configuration)
            let committed = lock.withLock { () -> Bool in
                guard stream === active.0,
                      pendingUpdate?.id == updateID else { return false }
                request = active.1
                pendingUpdate = nil
                return true
            }
            guard committed else { throw CaptureSessionError.notRunning }
            eventConsumer(.updated(active.1.identifier))
        } catch {
            lock.withLock {
                if pendingUpdate?.id == updateID {
                    pendingUpdate = nil
                }
            }
            throw error
        }
    }

    private static func makeConfiguration(
        for video: CaptureVideoConfiguration
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = video.width
        configuration.height = video.height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(video.framesPerSecond)
        )
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = video.showsCursor
        configuration.showMouseClicks = video.showsClickHighlights
        if let sourceRect = video.sourceRect {
            configuration.sourceRect = sourceRect
        }
        return configuration
    }

    private static func makeFilter(
        for target: CaptureTarget,
        content: SCShareableContent
    ) throws -> SCContentFilter {
        switch target {
        case let .display(id, excludedBundleIdentifier):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureSessionError.displayUnavailable(id)
            }
            let excluded = excludedBundleIdentifier.map { identifier in
                content.applications.filter { $0.bundleIdentifier == identifier }
            } ?? []
            return SCContentFilter(
                display: display,
                excludingApplications: excluded,
                exceptingWindows: []
            )

        case let .application(displayID, bundleIdentifier):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureSessionError.displayUnavailable(displayID)
            }
            let applications = content.applications.filter {
                $0.bundleIdentifier == bundleIdentifier
            }
            guard !applications.isEmpty else {
                throw CaptureSessionError.applicationUnavailable(bundleIdentifier)
            }
            return SCContentFilter(
                display: display,
                including: applications,
                exceptingWindows: []
            )

        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureSessionError.windowUnavailable(id)
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }
}

public enum CaptureSessionEvent: Equatable, Sendable {
    case started(UUID)
    case updated(UUID)
    case stopped(UUID, CaptureDeliveryStatistics)
    case failed(UUID?, CaptureSessionError)
}

extension ScreenCaptureSession: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              Self.isCompleteVideoSample(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let active = lock.withLock { () -> (
            request: CaptureSessionRequest,
            pendingVideo: CaptureVideoConfiguration?
        )? in
            guard self.stream === stream else { return nil }
            guard let request else { return nil }
            return (request, pendingUpdate?.request.video)
        }
        guard let active else { return }

        do {
            try CaptureFrameDimensionValidator.validate(
                pixelBuffer,
                expectedWidth: active.request.video.width,
                expectedHeight: active.request.video.height,
                alternateExpectedWidth: active.pendingVideo?.width,
                alternateExpectedHeight: active.pendingVideo?.height
            )
            let disposition = frameConsumer(BorrowedCaptureVideoFrame(
                sampleBuffer: sampleBuffer,
                pixelBuffer: pixelBuffer,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            ))
            lock.withLock {
                guard self.stream === stream else { return }
                backpressure.record(disposition)
            }
        } catch let error as CaptureSessionError {
            eventConsumer(.failed(active.request.identifier, error))
        } catch {
            eventConsumer(.failed(
                active.request.identifier,
                .streamStopped(error.localizedDescription)
            ))
        }
    }

    private static func isCompleteVideoSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard sampleBuffer.isValid,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            return false
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        let status = attachments?.first?[.status] as? NSNumber
        return status?.intValue == SCFrameStatus.complete.rawValue
    }
}

extension ScreenCaptureSession: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let identifier = lock.withLock { () -> UUID? in
            guard self.stream === stream else { return nil }
            let identifier = request?.identifier
            self.stream = nil
            request = nil
            pendingUpdate = nil
            return identifier
        }
        eventConsumer(.failed(
            identifier,
            .streamStopped(error.localizedDescription)
        ))
    }
}
