@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

public struct CaptureDisplay: Identifiable, Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let frame: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        id: CGDirectDisplayID,
        frame: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.frame = frame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public protocol ScreenCaptureDiscovering: Sendable {
    func displays() async throws -> [CaptureDisplay]
}

public struct ScreenCaptureDiscovery: ScreenCaptureDiscovering {
    public init() {}

    public func displays() async throws -> [CaptureDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return content.displays.map {
            CaptureDisplay(
                id: $0.displayID,
                frame: $0.frame,
                pixelWidth: $0.width,
                pixelHeight: $0.height
            )
        }
    }
}

/// A visible, app-owned window in ScreenCaptureKit's global point coordinate
/// system. Discovery preserves the framework's front-to-back ordering so the
/// selection UI can choose the application under a click deterministically.
public struct CaptureApplicationWindow: Equatable, Sendable {
    public let windowID: CGWindowID
    public let frame: CGRect
    public let bundleIdentifier: String
    public let applicationName: String
    public let processID: pid_t

    public init(
        windowID: CGWindowID,
        frame: CGRect,
        bundleIdentifier: String,
        applicationName: String,
        processID: pid_t
    ) {
        self.windowID = windowID
        self.frame = frame
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.processID = processID
    }
}

public protocol CaptureApplicationDiscovering: Sendable {
    func visibleApplicationWindows(
        excludingBundleIdentifier: String?
    ) async throws -> [CaptureApplicationWindow]
}

public struct CaptureApplicationDiscovery: CaptureApplicationDiscovering {
    public init() {}

    public func visibleApplicationWindows(
        excludingBundleIdentifier: String? = nil
    ) async throws -> [CaptureApplicationWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let frontToBackWindowOrder: [CGWindowID: Int] = {
            guard let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[CFString: Any]] else {
                return [:]
            }
            return Dictionary(
                uniqueKeysWithValues: windowInfo.enumerated().compactMap { index, entry in
                    guard let number = entry[kCGWindowNumber] as? NSNumber else { return nil }
                    return (CGWindowID(number.uint32Value), index)
                }
            )
        }()

        return content.windows.compactMap { window in
            guard
                window.isOnScreen,
                window.windowLayer == 0,
                window.frame.width >= 2,
                window.frame.height >= 2,
                let application = window.owningApplication,
                application.bundleIdentifier != excludingBundleIdentifier
            else {
                return nil
            }
            return CaptureApplicationWindow(
                windowID: window.windowID,
                frame: window.frame,
                bundleIdentifier: application.bundleIdentifier,
                applicationName: application.applicationName,
                processID: application.processID
            )
        }
        .sorted { lhs, rhs in
            let lhsOrder = frontToBackWindowOrder[lhs.windowID] ?? Int.max
            let rhsOrder = frontToBackWindowOrder[rhs.windowID] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.windowID < rhs.windowID
        }
    }
}
