import CoreGraphics
import CoreMedia
import Foundation

/// Selects which applications contribute to a single mixed system-audio
/// stream. ScreenCaptureKit filters audio at application granularity, so
/// several shared windows belonging to the same application intentionally
/// appear only once in `bundleIdentifiers`.
public enum CaptureAudioScope: Equatable, Sendable {
    case system(
        displayID: CGDirectDisplayID,
        excludedBundleIdentifier: String?
    )
    case applications(
        displayID: CGDirectDisplayID,
        bundleIdentifiers: Set<String>
    )

    public var displayID: CGDirectDisplayID {
        switch self {
        case let .system(displayID, _), let .applications(displayID, _):
            displayID
        }
    }

    var normalized: Self {
        switch self {
        case let .system(displayID, excludedBundleIdentifier):
            let identifier = excludedBundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .system(
                displayID: displayID,
                excludedBundleIdentifier: identifier?.isEmpty == false ? identifier : nil
            )

        case let .applications(displayID, bundleIdentifiers):
            return .applications(
                displayID: displayID,
                bundleIdentifiers: Set(bundleIdentifiers.compactMap { identifier in
                    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                })
            )
        }
    }
}
/// Live Share always feeds WebRTC the native ScreenCaptureKit mix at 48 kHz,
/// stereo. Keeping this contract fixed avoids format churn when the selected
/// windows change.
public struct CaptureAudioConfiguration: Equatable, Sendable {
    public static let sampleRate = 48_000
    public static let channelCount = 2

    public var excludesCurrentProcessAudio: Bool

    public init(excludesCurrentProcessAudio: Bool = true) {
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
    }
}

public struct CaptureAudioSessionRequest: Equatable, Sendable {
    public let identifier: UUID
    public let scope: CaptureAudioScope
    public let configuration: CaptureAudioConfiguration

    public init(
        identifier: UUID = UUID(),
        scope: CaptureAudioScope,
        configuration: CaptureAudioConfiguration = .init()
    ) {
        self.identifier = identifier
        self.scope = scope.normalized
        self.configuration = configuration
    }
}

/// A borrowed LPCM sample from ScreenCaptureKit. It is valid for the duration
/// of the synchronous consumer callback. A consumer that crosses a queue or
/// actor boundary must retain or copy the sample buffer first.
public struct BorrowedCaptureAudioSample: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public let presentationTime: CMTime

    public init(sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
        presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }
}

public enum CaptureAudioSessionEvent: Equatable, Sendable {
    case started(UUID)
    case updated(UUID)
    case stopped(UUID)
    case failed(UUID?, CaptureAudioSessionError)
}

public enum CaptureAudioSessionError: Error, Equatable, LocalizedError, Sendable {
    case alreadyRunning
    case notRunning
    case displayUnavailable(CGDirectDisplayID)
    case noApplicationsRequested
    case applicationsUnavailable([String])
    case invalidAudioFormat(
        expectedSampleRate: Int,
        expectedChannelCount: Int,
        actualSampleRate: Int,
        actualChannelCount: Int
    )
    case streamStopped(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "System-audio capture is already running."
        case .notRunning:
            "System-audio capture is not running."
        case let .displayUnavailable(displayID):
            "Display \(displayID) is no longer available for system-audio capture."
        case .noApplicationsRequested:
            "No shared applications are available for system-audio capture."
        case let .applicationsUnavailable(bundleIdentifiers):
            "These shared applications are no longer available: \(bundleIdentifiers.joined(separator: ", "))."
        case let .invalidAudioFormat(expectedRate, expectedChannels, actualRate, actualChannels):
            "System audio arrived as \(actualRate) Hz / \(actualChannels) channels; expected \(expectedRate) Hz / \(expectedChannels) channels."
        case let .streamStopped(message):
            message
        }
    }
}
