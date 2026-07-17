import AppKit
@preconcurrency import AVFoundation
import ClipMedia
import CoreGraphics
import Foundation

enum PasteboardServiceError: LocalizedError, Equatable {
    case fileUnavailable
    case unsupportedFileType
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .fileUnavailable:
            String(localized: "The exported video file is unavailable.")
        case .unsupportedFileType:
            String(localized: "Only an MP4 video can be copied.")
        case .writeFailed:
            String(localized: "Clip could not place the video file on the clipboard.")
        }
    }
}

@MainActor
final class LivePasteboardService: PasteboardServicing {
    private let pasteboard: NSPasteboard
    private let fileManager: FileManager

    init(
        pasteboard: NSPasteboard = .general,
        fileManager: FileManager = .default
    ) {
        self.pasteboard = pasteboard
        self.fileManager = fileManager
    }

    func placeFile(at url: URL) throws {
        guard url.isFileURL,
              fileManager.isReadableFile(atPath: url.path) else {
            throw PasteboardServiceError.fileUnavailable
        }
        guard url.pathExtension.caseInsensitiveCompare("mp4") == .orderedSame else {
            throw PasteboardServiceError.unsupportedFileType
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else {
            throw PasteboardServiceError.writeFailed
        }
    }
}

@MainActor
final class LiveAudioService: AudioServicing {
    private(set) var defaultInputName: String?

    init() {
        defaultInputName = AVCaptureDevice.default(for: .audio)?.localizedName
    }

    func refreshDevices() async {
        defaultInputName = AVCaptureDevice.default(for: .audio)?.localizedName
    }
}

@MainActor
final class LivePermissionService: PermissionServicing {
    private enum Key {
        static let requestedScreenRecording = "permission.requested.screenRecording"
    }

    private let defaults: UserDefaults
    private let screenRecordingStatus: @MainActor () -> CaptureAuthorizationStatus
    private let requestScreenRecording: @MainActor () -> Bool

    init(
        defaults: UserDefaults = .standard,
        screenRecordingStatus: @escaping @MainActor () -> CaptureAuthorizationStatus = {
            CaptureAuthorization.screenRecordingStatus
        },
        requestScreenRecording: @escaping @MainActor () -> Bool = {
            CaptureAuthorization.requestScreenRecording()
        }
    ) {
        self.defaults = defaults
        self.screenRecordingStatus = screenRecordingStatus
        self.requestScreenRecording = requestScreenRecording
    }

    func currentStatus(for permission: ClipPermission) -> PermissionState {
        switch permission {
        case .screenRecording, .systemAudio:
            ScreenRecordingPermissionPolicy.currentState(
                authorizationStatus: screenRecordingStatus(),
                hasRequestedAccess: defaults.bool(forKey: Key.requestedScreenRecording)
            )

        case .microphone:
            Self.permissionState(from: CaptureAuthorization.microphoneStatus)
        }
    }

    func request(_ permission: ClipPermission) async -> PermissionState {
        switch permission {
        case .screenRecording, .systemAudio:
            defaults.set(true, forKey: Key.requestedScreenRecording)
            return requestScreenRecording() ? .granted : .denied

        case .microphone:
            return await CaptureAuthorization.requestMicrophone() ? .granted : .denied
        }
    }

    private static func permissionState(
        from status: CaptureAuthorizationStatus
    ) -> PermissionState {
        switch status {
        case .authorized:
            .granted
        case .notDetermined, .requiresApproval:
            .notDetermined
        case .denied:
            .denied
        case .restricted:
            .restricted
        }
    }
}

struct ExplicitScreenRecordingPermissionPlan: Equatable, Sendable {
    let canProceed: Bool
    let shouldShowExplanation: Bool
    let shouldRequestAccess: Bool
}

enum ScreenRecordingPermissionPolicy {
    static func currentState(
        authorizationStatus: CaptureAuthorizationStatus,
        hasRequestedAccess: Bool
    ) -> PermissionState {
        switch authorizationStatus {
        case .authorized:
            .granted
        case .requiresApproval:
            hasRequestedAccess ? .denied : .notDetermined
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .restricted:
            .restricted
        }
    }

    /// A persisted request marker identifies user intent, not the currently
    /// running code signature. An ad-hoc rebuild can therefore report denied
    /// while this exact binary has never asked TCC for access. Every explicit
    /// capture action gets one request attempt in that state; CoreGraphics
    /// remains authoritative about whether capture may proceed.
    static func explicitCapturePlan(
        for state: PermissionState
    ) -> ExplicitScreenRecordingPermissionPlan {
        switch state {
        case .granted:
            ExplicitScreenRecordingPermissionPlan(
                canProceed: true,
                shouldShowExplanation: false,
                shouldRequestAccess: false
            )
        case .notDetermined:
            ExplicitScreenRecordingPermissionPlan(
                canProceed: false,
                shouldShowExplanation: true,
                shouldRequestAccess: true
            )
        case .denied:
            ExplicitScreenRecordingPermissionPlan(
                canProceed: false,
                shouldShowExplanation: false,
                shouldRequestAccess: true
            )
        case .restricted:
            ExplicitScreenRecordingPermissionPlan(
                canProceed: false,
                shouldShowExplanation: false,
                shouldRequestAccess: false
            )
        }
    }
}

@MainActor
final class LiveDisplayService: DisplayServicing {
    struct AppKitDisplaySnapshot: Equatable, Sendable {
        let id: CGDirectDisplayID
        let name: String
        let frame: CGRect
    }

    typealias AppKitDisplayProvider = @MainActor () -> [AppKitDisplaySnapshot]
    typealias StableIdentifierProvider = @MainActor (CGDirectDisplayID) -> String

    private let discovery: any ScreenCaptureDiscovering
    private let appKitDisplays: AppKitDisplayProvider
    private let stableIdentifier: StableIdentifierProvider

    init(
        discovery: any ScreenCaptureDiscovering = ScreenCaptureDiscovery(),
        appKitDisplays: @escaping AppKitDisplayProvider = {
            NSScreen.screens.compactMap { screen in
                guard let id = screen.displayID else { return nil }
                return AppKitDisplaySnapshot(
                    id: id,
                    name: screen.localizedName,
                    frame: screen.frame
                )
            }
        },
        stableIdentifier: @escaping StableIdentifierProvider = {
            LiveDisplayService.stableIdentifier(for: $0)
        }
    ) {
        self.discovery = discovery
        self.appKitDisplays = appKitDisplays
        self.stableIdentifier = stableIdentifier
    }

    func availableDisplays() async throws -> [ClipDisplay] {
        let captureDisplays = try await discovery.displays()
        let screensByID = Dictionary(
            appKitDisplays().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return captureDisplays.map { display in
            let screen = screensByID[display.id]
            let resolvedFrame = screen?.frame ?? display.frame
            let pointWidth = max(resolvedFrame.width, 1)
            return ClipDisplay(
                id: display.id,
                stableIdentifier: stableIdentifier(display.id),
                name: screen?.name ?? String(localized: "Display"),
                frame: resolvedFrame,
                scaleFactor: CGFloat(max(display.pixelWidth, 1)) / pointWidth
            )
        }
    }

    private static func stableIdentifier(for displayID: CGDirectDisplayID) -> String {
        guard let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return "display-\(displayID)"
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}
