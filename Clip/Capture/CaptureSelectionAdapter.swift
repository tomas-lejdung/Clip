import ClipCore
import Foundation

enum CaptureSelectionAdapterError: Error, Sendable {
    case invalidDisplayBounds
    case invalidPixelSize
    case invalidSourceRectangle
}

enum CaptureSelectionAdapter {
    static func preparedTarget(
        from result: CaptureSelectionResult
    ) throws -> PreparedCaptureTarget {
        switch result {
        case let .area(area):
            return try preparedRegionTarget(
                sourceRectangle: area.sourceRectangleInDisplayPoints,
                display: area.display
            )

        case let .fullscreen(display):
            guard display.pixelSize.width.isFinite,
                  display.pixelSize.height.isFinite,
                  display.pixelSize.width <= CGFloat(Int.max - 1),
                  display.pixelSize.height <= CGFloat(Int.max - 1) else {
                throw CaptureSelectionAdapterError.invalidPixelSize
            }
            let nominalWidth = Int(display.pixelSize.width.rounded())
            let nominalHeight = Int(display.pixelSize.height.rounded())
            guard nominalWidth >= 2, nominalHeight >= 2 else {
                throw CaptureSelectionAdapterError.invalidPixelSize
            }
            let outputWidth = nominalWidth.isMultiple(of: 2)
                ? nominalWidth
                : nominalWidth - 1
            let outputHeight = nominalHeight.isMultiple(of: 2)
                ? nominalHeight
                : nominalHeight - 1
            let displayID = try DisplayID(display.id)
            return PreparedCaptureTarget(
                domainTarget: .fullscreen(displayID),
                displayID: display.displayID,
                sourceRect: nil,
                outputWidth: outputWidth,
                outputHeight: outputHeight
            )
        }
    }

    /// Reconstructs a durable region on the display's current geometry, then
    /// applies the same physical-pixel alignment used by a fresh Area capture.
    /// This matters when Retake follows a display resolution or scale change.
    static func preparedTarget(
        from selection: ClipCore.CaptureSelection,
        on display: CaptureSelectionDisplay
    ) throws -> PreparedCaptureTarget {
        let bounds = display.localBounds
        guard bounds.width > 0, bounds.height > 0 else {
            throw CaptureSelectionAdapterError.invalidDisplayBounds
        }
        let normalized = selection.normalizedRect
        return try preparedRegionTarget(
            sourceRectangle: CGRect(
                x: bounds.minX + CGFloat(normalized.x) * bounds.width,
                y: bounds.minY + CGFloat(normalized.y) * bounds.height,
                width: CGFloat(normalized.width) * bounds.width,
                height: CGFloat(normalized.height) * bounds.height
            ),
            display: display
        )
    }

    static func preparedTarget(
        from application: SelectedCaptureApplication
    ) throws -> PreparedCaptureTarget {
        let bounds = application.display.localBounds
        guard bounds.width > 0, bounds.height > 0 else {
            throw CaptureSelectionAdapterError.invalidDisplayBounds
        }
        guard let pixelGeometry = CaptureSelectionGeometry.pixelAligned(
            application.sourceRectangleInDisplayPoints,
            in: bounds,
            scaleFactor: application.display.scaleFactor
        ) else {
            throw CaptureSelectionAdapterError.invalidSourceRectangle
        }
        let displayID = try DisplayID(application.display.id)
        let target = try ApplicationCaptureTarget(
            displayID: displayID,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.applicationName
        )
        return PreparedCaptureTarget(
            domainTarget: .application(target),
            displayID: application.display.displayID,
            sourceRect: pixelGeometry.sourceRectangle,
            outputWidth: pixelGeometry.pixelWidth,
            outputHeight: pixelGeometry.pixelHeight,
            includedApplicationBundleIdentifier: target.bundleIdentifier
        )
    }

    private static func preparedRegionTarget(
        sourceRectangle: CGRect,
        display: CaptureSelectionDisplay
    ) throws -> PreparedCaptureTarget {
        let bounds = display.localBounds
        guard bounds.width > 0, bounds.height > 0 else {
            throw CaptureSelectionAdapterError.invalidDisplayBounds
        }
        guard let pixelGeometry = CaptureSelectionGeometry.pixelAligned(
            sourceRectangle,
            in: bounds,
            scaleFactor: display.scaleFactor
        ) else {
            throw CaptureSelectionAdapterError.invalidSourceRectangle
        }
        let sourceRect = pixelGeometry.sourceRectangle
        let displayID = try DisplayID(display.id)
        let normalizedRect = try NormalizedRect(
            x: Double(sourceRect.minX / bounds.width),
            y: Double(sourceRect.minY / bounds.height),
            width: Double(sourceRect.width / bounds.width),
            height: Double(sourceRect.height / bounds.height)
        )
        return PreparedCaptureTarget(
            domainTarget: .region(
                CaptureSelection(
                    displayID: displayID,
                    normalizedRect: normalizedRect
                )
            ),
            displayID: display.displayID,
            sourceRect: sourceRect,
            outputWidth: pixelGeometry.pixelWidth,
            outputHeight: pixelGeometry.pixelHeight
        )
    }
}

@MainActor
final class LastAreaStore {
    private static let key = "capture.lastArea"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> StoredCaptureArea? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(StoredCaptureArea.self, from: data)
    }

    func save(_ area: SelectedCaptureArea) throws {
        let stored = StoredCaptureArea(
            displayIdentifier: area.display.id,
            rectangle: area.normalizedRectangle
        )
        defaults.set(try JSONEncoder().encode(stored), forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
