import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

public enum CaptureTarget: Equatable, Sendable {
    case display(
        id: CGDirectDisplayID,
        excludedBundleIdentifier: String?
    )
    case application(
        displayID: CGDirectDisplayID,
        bundleIdentifier: String
    )
    case window(id: CGWindowID)

    public var displayID: CGDirectDisplayID? {
        switch self {
        case let .display(id, _), let .application(id, _):
            id
        case .window:
            nil
        }
    }
}

public struct CaptureVideoConfiguration: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var showsCursor: Bool
    public var showsClickHighlights: Bool
    public var sourceRect: CGRect?

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int = 30,
        showsCursor: Bool = true,
        showsClickHighlights: Bool = false,
        sourceRect: CGRect? = nil
    ) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.framesPerSecond = max(1, framesPerSecond)
        self.showsCursor = showsCursor
        self.showsClickHighlights = showsClickHighlights
        self.sourceRect = sourceRect
    }
}

public struct CaptureSessionRequest: Equatable, Sendable {
    public var identifier: UUID
    public var target: CaptureTarget
    public var video: CaptureVideoConfiguration

    public init(
        identifier: UUID = UUID(),
        target: CaptureTarget,
        video: CaptureVideoConfiguration
    ) {
        self.identifier = identifier
        self.target = target
        self.video = video
    }
}

/// A borrowed ScreenCaptureKit frame. The sample buffer remains valid for the
/// duration of the synchronous consumer callback. Consumers that retain it
/// must do so explicitly and provide their own bounded backpressure policy.
public struct BorrowedCaptureVideoFrame: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let width: Int
    public let height: Int

    public init(
        sampleBuffer: CMSampleBuffer,
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime
    ) {
        self.sampleBuffer = sampleBuffer
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
    }
}

public enum CaptureFrameDisposition: Equatable, Sendable {
    case accepted
    case droppedBackpressure
}

public struct CaptureDeliveryStatistics: Equatable, Sendable {
    public var deliveredFrames: UInt64
    public var backpressureDrops: UInt64

    public init(deliveredFrames: UInt64 = 0, backpressureDrops: UInt64 = 0) {
        self.deliveredFrames = deliveredFrames
        self.backpressureDrops = backpressureDrops
    }
}

public enum CaptureSessionError: Error, Equatable, LocalizedError, Sendable {
    case alreadyRunning
    case notRunning
    case displayUnavailable(CGDirectDisplayID)
    case applicationUnavailable(String)
    case windowUnavailable(CGWindowID)
    case invalidFrameDimensions(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case streamStopped(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Capture is already running."
        case .notRunning:
            "Capture is not running."
        case let .displayUnavailable(id):
            "Display \(id) is no longer available."
        case let .applicationUnavailable(bundleIdentifier):
            "Application \(bundleIdentifier) is no longer available."
        case let .windowUnavailable(id):
            "Window \(id) is no longer available."
        case let .invalidFrameDimensions(expectedWidth, expectedHeight, actualWidth, actualHeight):
            "Capture delivered \(actualWidth) × \(actualHeight), expected \(expectedWidth) × \(expectedHeight)."
        case let .streamStopped(message):
            message
        }
    }
}
