@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

public struct ShareableCaptureDisplay: Identifiable, Equatable, Sendable {
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

public struct ShareableCaptureWindow: Identifiable, Equatable, Sendable {
    public let id: CGWindowID
    public let frame: CGRect
    public let title: String
    public let applicationName: String
    public let bundleIdentifier: String
    public let processID: pid_t
    public let capturePointWidth: Int
    public let capturePointHeight: Int
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        id: CGWindowID,
        frame: CGRect,
        title: String,
        applicationName: String,
        bundleIdentifier: String,
        processID: pid_t,
        capturePointWidth: Int? = nil,
        capturePointHeight: Int? = nil,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.frame = frame
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.capturePointWidth = max(
            1,
            capturePointWidth ?? Int(frame.width.rounded())
        )
        self.capturePointHeight = max(
            1,
            capturePointHeight ?? Int(frame.height.rounded())
        )
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
    }
}

public struct ShareableCaptureContent: Equatable, Sendable {
    public let displays: [ShareableCaptureDisplay]
    /// Front-to-back order when macOS supplies a global window list entry.
    public let windows: [ShareableCaptureWindow]

    public init(
        displays: [ShareableCaptureDisplay],
        windows: [ShareableCaptureWindow]
    ) {
        self.displays = displays
        self.windows = windows
    }
}

public protocol CaptureContentDiscovering: Sendable {
    func shareableContent(
        excludingBundleIdentifier: String?
    ) async throws -> ShareableCaptureContent
}

public struct ScreenCaptureContentDiscovery: CaptureContentDiscovering {
    public init() {}

    public func shareableContent(
        excludingBundleIdentifier: String? = nil
    ) async throws -> ShareableCaptureContent {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let ordering = Self.frontToBackWindowOrder()
        let displays = content.displays.map {
            ShareableCaptureDisplay(
                id: $0.displayID,
                frame: $0.frame,
                pixelWidth: $0.width,
                pixelHeight: $0.height
            )
        }
        let windows = content.windows.compactMap { window -> ShareableCaptureWindow? in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 2,
                  window.frame.height >= 2,
                  let application = window.owningApplication,
                  application.bundleIdentifier != excludingBundleIdentifier else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(max(1, filter.pointPixelScale))
            let capturePointWidth = Int(filter.contentRect.width.rounded())
            let capturePointHeight = Int(filter.contentRect.height.rounded())
            let pixelWidth = Int((filter.contentRect.width * scale).rounded())
            let pixelHeight = Int((filter.contentRect.height * scale).rounded())
            return ShareableCaptureWindow(
                id: window.windowID,
                frame: window.frame,
                title: window.title ?? "",
                applicationName: application.applicationName,
                bundleIdentifier: application.bundleIdentifier,
                processID: application.processID,
                capturePointWidth: capturePointWidth,
                capturePointHeight: capturePointHeight,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }
        .sorted { lhs, rhs in
            let lhsOrder = ordering[lhs.id] ?? Int.max
            let rhsOrder = ordering[rhs.id] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.id < rhs.id
        }
        return ShareableCaptureContent(displays: displays, windows: windows)
    }

    private static func frontToBackWindowOrder() -> [CGWindowID: Int] {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: entries.enumerated().compactMap { index, entry in
                guard let number = entry[kCGWindowNumber] as? NSNumber else { return nil }
                return (CGWindowID(number.uint32Value), index)
            }
        )
    }
}

/// Identifies user-facing application windows without requiring Accessibility
/// access. ScreenCaptureKit exposes no role/subrole relationship for sheets or
/// popovers, but those transient layer-zero surfaces are normally untitled.
/// Keeping this predicate shared prevents Live Share's focused resolver and
/// manual window list from disagreeing about what can be selected.
public enum ShareableApplicationWindowEligibility {
    public static func isEligible(
        _ window: ShareableCaptureWindow,
        minimumPointSize: CGSize = .zero
    ) -> Bool {
        !window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && window.frame.width >= minimumPointSize.width
            && window.frame.height >= minimumPointSize.height
    }
}

public enum FocusedWindowSelection {
    public static func eligibleWindow(
        frontmostProcessID: pid_t?,
        orderedWindows: [ShareableCaptureWindow],
        minimumPointSize: CGSize = .zero
    ) -> ShareableCaptureWindow? {
        guard let frontmostProcessID else { return nil }
        return orderedWindows.first {
            $0.processID == frontmostProcessID
                && ShareableApplicationWindowEligibility.isEligible(
                    $0,
                    minimumPointSize: minimumPointSize
                )
        }
    }
}
