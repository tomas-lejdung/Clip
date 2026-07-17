import CoreGraphics
import Foundation

/// A display snapshot used while Capture Mode is visible.
///
/// `frameInGlobalPoints` uses the AppKit global coordinate system. Selection
/// rectangles use display-local points with a bottom-left origin so all pointer
/// geometry remains independent of the display's global placement.
struct CaptureSelectionDisplay: Equatable, Identifiable, Sendable {
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    let frameInGlobalPoints: CGRect
    let pixelSize: CGSize
    let scaleFactor: CGFloat
    let isMain: Bool

    var localBounds: CGRect {
        CGRect(origin: .zero, size: frameInGlobalPoints.size)
    }
}

/// The persistence representation for Last Area. Values are fractions of a
/// display's local point bounds and use a bottom-left origin.
struct NormalizedCaptureRectangle: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(rect: CGRect, in bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else {
            self.init(x: 0, y: 0, width: 1, height: 1)
            return
        }

        let clipped = rect.standardized.intersection(bounds)
        self.init(
            x: (clipped.minX - bounds.minX) / bounds.width,
            y: (clipped.minY - bounds.minY) / bounds.height,
            width: clipped.width / bounds.width,
            height: clipped.height / bounds.height
        )
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func denormalized(in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let safeX = x.isFinite ? x : 0
        let safeY = y.isFinite ? y : 0
        let safeWidth = width.isFinite ? width : 1
        let safeHeight = height.isFinite ? height : 1

        return CGRect(
            x: bounds.minX + CGFloat(safeX) * bounds.width,
            y: bounds.minY + CGFloat(safeY) * bounds.height,
            width: CGFloat(safeWidth) * bounds.width,
            height: CGFloat(safeHeight) * bounds.height
        )
    }
}

struct StoredCaptureArea: Codable, Equatable, Sendable {
    let displayIdentifier: String
    let rectangle: NormalizedCaptureRectangle
}

struct SelectedCaptureArea: Equatable, Sendable {
    let display: CaptureSelectionDisplay
    let rectangleInDisplayPoints: CGRect
    let normalizedRectangle: NormalizedCaptureRectangle
    let outputPixelSize: CGSize

    /// ScreenCaptureKit display-relative coordinates use a top-left origin.
    /// Keeping this conversion on the result avoids leaking AppKit coordinate
    /// assumptions into the recording engine.
    var sourceRectangleInDisplayPoints: CGRect {
        CGRect(
            x: rectangleInDisplayPoints.minX,
            y: display.localBounds.height - rectangleInDisplayPoints.maxY,
            width: rectangleInDisplayPoints.width,
            height: rectangleInDisplayPoints.height
        )
    }
}

enum CaptureSelectionResult: Equatable, Sendable {
    case area(SelectedCaptureArea)
    case fullscreen(CaptureSelectionDisplay)
}

enum CaptureSelectionPresentationMode: Equatable, Sendable {
    case area
    case fullscreen
}

enum CaptureSelectionHandle: CaseIterable, Equatable, Sendable {
    case bottomLeft
    case bottom
    case bottomRight
    case right
    case topRight
    case top
    case topLeft
    case left

    /// -1 means the minimum edge, 0 means centered, and 1 means the maximum edge.
    var horizontalDirection: CGFloat {
        switch self {
        case .bottomLeft, .topLeft, .left: -1
        case .bottomRight, .topRight, .right: 1
        case .bottom, .top: 0
        }
    }

    /// -1 means the minimum edge, 0 means centered, and 1 means the maximum edge.
    var verticalDirection: CGFloat {
        switch self {
        case .bottomLeft, .bottom, .bottomRight: -1
        case .topLeft, .top, .topRight: 1
        case .left, .right: 0
        }
    }

    func center(in rectangle: CGRect) -> CGPoint {
        CGPoint(
            x: horizontalDirection < 0
                ? rectangle.minX
                : horizontalDirection > 0 ? rectangle.maxX : rectangle.midX,
            y: verticalDirection < 0
                ? rectangle.minY
                : verticalDirection > 0 ? rectangle.maxY : rectangle.midY
        )
    }
}

enum CaptureSelectionFocus: Equatable, Sendable {
    case region
    case handle(CaptureSelectionHandle)
    case recordButton
    case cancelButton

    static let orderedItems: [CaptureSelectionFocus] = [
        .region,
        .handle(.bottomLeft),
        .handle(.bottom),
        .handle(.bottomRight),
        .handle(.right),
        .handle(.topRight),
        .handle(.top),
        .handle(.topLeft),
        .handle(.left),
        .recordButton,
        .cancelButton,
    ]

    func advanced(reverse: Bool) -> CaptureSelectionFocus {
        guard let index = Self.orderedItems.firstIndex(of: self) else {
            return .region
        }

        let offset = reverse ? -1 : 1
        let next = (index + offset + Self.orderedItems.count) % Self.orderedItems.count
        return Self.orderedItems[next]
    }
}

struct CaptureSelectionConfiguration: Equatable, Sendable {
    var minimumAreaSize = CGSize(width: 96, height: 64)
    var dimmingOpacity: CGFloat = 0.56
    var handleSize: CGFloat = 10
    var toolbarPadding: CGFloat = 12
    var microphoneStatus = "Microphone: Off"
    var systemAudioStatus = "System Audio: Off"
}

