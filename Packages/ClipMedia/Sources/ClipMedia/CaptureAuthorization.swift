@preconcurrency import AVFoundation
import CoreGraphics

public enum CaptureAuthorizationStatus: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case requiresApproval
}

public enum CaptureAuthorization {
    /// Querying this status does not display the macOS privacy prompt.
    public static var screenRecordingStatus: CaptureAuthorizationStatus {
        CGPreflightScreenCaptureAccess() ? .authorized : .requiresApproval
    }

    public static var microphoneStatus: CaptureAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            .authorized
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .denied
        }
    }

    /// Intentionally separate from the status query so the app only opens the
    /// Screen Recording consent flow after a direct user action.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Intentionally called only when microphone capture is first enabled.
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
