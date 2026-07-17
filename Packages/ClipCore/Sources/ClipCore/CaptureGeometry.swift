import Foundation

public enum CaptureGeometryError: Error, Equatable, Sendable {
    case emptyDisplayIdentifier
    case invalidPixelSize(width: Int, height: Int)
    case invalidPixelRect(x: Int, y: Int, width: Int, height: Int)
    case nonFiniteNormalizedRect
    case nonPositiveNormalizedSize(width: Double, height: Double)
    case normalizedRectOutsideDisplay
    case displayMismatch(expected: DisplayID, actual: DisplayID)
}

public struct DisplayID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CaptureGeometryError.emptyDisplayIdentifier
        }
        self.rawValue = normalized
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Display identifier must not be empty."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PixelSize: Codable, Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw CaptureGeometryError.invalidPixelSize(width: width, height: height)
        }
        self.width = width
        self.height = height
    }

    private enum CodingKeys: CodingKey {
        case width
        case height
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        do {
            try self.init(width: width, height: height)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .width,
                in: container,
                debugDescription: "Pixel dimensions must be positive."
            )
        }
    }
}

/// A display-local pixel rectangle using a top-left origin.
public struct PixelRect: Codable, Equatable, Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) throws {
        guard x >= 0, y >= 0, width > 0, height > 0 else {
            throw CaptureGeometryError.invalidPixelRect(
                x: x,
                y: y,
                width: width,
                height: height
            )
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    private enum CodingKeys: CodingKey {
        case x
        case y
        case width
        case height
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Int.self, forKey: .x)
        let y = try container.decode(Int.self, forKey: .y)
        let width = try container.decode(Int.self, forKey: .width)
        let height = try container.decode(Int.self, forKey: .height)
        do {
            try self.init(x: x, y: y, width: width, height: height)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .width,
                in: container,
                debugDescription: "Pixel rectangle must have a positive size and non-negative origin."
            )
        }
    }
}

/// A display-local rectangle with a top-left origin, constrained to the unit square.
public struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard [x, y, width, height].allSatisfy(\.isFinite) else {
            throw CaptureGeometryError.nonFiniteNormalizedRect
        }
        guard width > 0, height > 0 else {
            throw CaptureGeometryError.nonPositiveNormalizedSize(width: width, height: height)
        }
        guard x >= 0, y >= 0, x + width <= 1, y + height <= 1 else {
            throw CaptureGeometryError.normalizedRectOutsideDisplay
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private init(uncheckedX x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Preserves the requested size where possible and translates the rectangle inside one display.
    public static func clamped(
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) throws -> Self {
        guard [x, y, width, height].allSatisfy(\.isFinite) else {
            throw CaptureGeometryError.nonFiniteNormalizedRect
        }
        guard width > 0, height > 0 else {
            throw CaptureGeometryError.nonPositiveNormalizedSize(width: width, height: height)
        }

        let clampedWidth = min(width, 1)
        let clampedHeight = min(height, 1)
        let clampedX = min(max(x, 0), 1 - clampedWidth)
        let clampedY = min(max(y, 0), 1 - clampedHeight)
        return Self(
            uncheckedX: clampedX,
            y: clampedY,
            width: clampedWidth,
            height: clampedHeight
        )
    }

    public func translated(byX deltaX: Double, y deltaY: Double) throws -> Self {
        try Self.clamped(
            x: x + deltaX,
            y: y + deltaY,
            width: width,
            height: height
        )
    }

    /// Resizes from the current top-left corner and constrains the result to the same display.
    public func resized(width requestedWidth: Double, height requestedHeight: Double) throws -> Self {
        guard [requestedWidth, requestedHeight].allSatisfy(\.isFinite) else {
            throw CaptureGeometryError.nonFiniteNormalizedRect
        }
        guard requestedWidth > 0, requestedHeight > 0 else {
            throw CaptureGeometryError.nonPositiveNormalizedSize(
                width: requestedWidth,
                height: requestedHeight
            )
        }
        return Self(
            uncheckedX: x,
            y: y,
            width: min(requestedWidth, 1 - x),
            height: min(requestedHeight, 1 - y)
        )
    }

    public func pixelRect(in displaySize: PixelSize) -> PixelRect {
        let minimumX = max(0, min(displaySize.width - 1, Int(floor(x * Double(displaySize.width)))))
        let minimumY = max(0, min(displaySize.height - 1, Int(floor(y * Double(displaySize.height)))))
        let maximumX = max(
            minimumX + 1,
            min(displaySize.width, Int(ceil((x + width) * Double(displaySize.width))))
        )
        let maximumY = max(
            minimumY + 1,
            min(displaySize.height, Int(ceil((y + height) * Double(displaySize.height))))
        )
        return try! PixelRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private enum CodingKeys: CodingKey {
        case x
        case y
        case width
        case height
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        let width = try container.decode(Double.self, forKey: .width)
        let height = try container.decode(Double.self, forKey: .height)
        do {
            try self.init(x: x, y: y, width: width, height: height)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .x,
                in: container,
                debugDescription: "Normalized rectangle must be finite, positive, and inside one display."
            )
        }
    }
}

public struct DisplayDescriptor: Codable, Equatable, Hashable, Sendable {
    public let id: DisplayID
    public let name: String
    public let pixelSize: PixelSize
    public let isMain: Bool

    public init(id: DisplayID, name: String, pixelSize: PixelSize, isMain: Bool) {
        self.id = id
        self.name = name
        self.pixelSize = pixelSize
        self.isMain = isMain
    }
}

public struct CaptureSelection: Codable, Equatable, Hashable, Sendable {
    public let displayID: DisplayID
    public let normalizedRect: NormalizedRect

    public init(displayID: DisplayID, normalizedRect: NormalizedRect) {
        self.displayID = displayID
        self.normalizedRect = normalizedRect
    }

    public func pixelRect(on display: DisplayDescriptor) throws -> PixelRect {
        guard display.id == displayID else {
            throw CaptureGeometryError.displayMismatch(expected: displayID, actual: display.id)
        }
        return normalizedRect.pixelRect(in: display.pixelSize)
    }
}

public enum ApplicationCaptureTargetError: Error, Equatable, Sendable {
    case emptyBundleIdentifier
    case emptyApplicationName
}

/// A durable identity for an application capture.
///
/// The display identity is stable across reconnects and the bundle identifier
/// is stable across launches, so History can resolve a Retake without retaining
/// an ephemeral process or window identifier. The name is persisted only for
/// user-facing descriptions when the application is no longer running.
public struct ApplicationCaptureTarget: Codable, Equatable, Hashable, Sendable {
    public let displayID: DisplayID
    public let bundleIdentifier: String
    public let applicationName: String

    public init(
        displayID: DisplayID,
        bundleIdentifier: String,
        applicationName: String
    ) throws {
        let normalizedBundleIdentifier = bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedBundleIdentifier.isEmpty else {
            throw ApplicationCaptureTargetError.emptyBundleIdentifier
        }
        let normalizedApplicationName = applicationName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedApplicationName.isEmpty else {
            throw ApplicationCaptureTargetError.emptyApplicationName
        }
        self.displayID = displayID
        self.bundleIdentifier = normalizedBundleIdentifier
        self.applicationName = normalizedApplicationName
    }

    private enum CodingKeys: CodingKey {
        case displayID
        case bundleIdentifier
        case applicationName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                displayID: container.decode(DisplayID.self, forKey: .displayID),
                bundleIdentifier: container.decode(String.self, forKey: .bundleIdentifier),
                applicationName: container.decode(String.self, forKey: .applicationName)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid application capture target: \(error)"
                )
            )
        }
    }
}

public enum CaptureTarget: Codable, Equatable, Hashable, Sendable {
    case region(CaptureSelection)
    case fullscreen(DisplayID)
    case application(ApplicationCaptureTarget)

    public var displayID: DisplayID {
        switch self {
        case let .region(selection): selection.displayID
        case let .fullscreen(displayID): displayID
        case let .application(application): application.displayID
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case selection
        case displayID
        case application
    }

    private enum Kind: String, Codable {
        case region
        case fullscreen
        case application
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .region:
            self = .region(try container.decode(CaptureSelection.self, forKey: .selection))
        case .fullscreen:
            self = .fullscreen(try container.decode(DisplayID.self, forKey: .displayID))
        case .application:
            self = .application(
                try container.decode(ApplicationCaptureTarget.self, forKey: .application)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .region(selection):
            try container.encode(Kind.region, forKey: .kind)
            try container.encode(selection, forKey: .selection)
        case let .fullscreen(displayID):
            try container.encode(Kind.fullscreen, forKey: .kind)
            try container.encode(displayID, forKey: .displayID)
        case let .application(application):
            try container.encode(Kind.application, forKey: .kind)
            try container.encode(application, forKey: .application)
        }
    }
}

public enum LastAreaResolutionKind: String, Codable, Hashable, Sendable {
    case originalDisplay
    case fallbackToMainDisplay
    case fallbackToFirstAvailableDisplay
}

public struct LastAreaResolution: Codable, Equatable, Hashable, Sendable {
    public let selection: CaptureSelection
    public let display: DisplayDescriptor
    public let kind: LastAreaResolutionKind

    public init(
        selection: CaptureSelection,
        display: DisplayDescriptor,
        kind: LastAreaResolutionKind
    ) {
        self.selection = selection
        self.display = display
        self.kind = kind
    }

    public var didFallback: Bool { kind != .originalDisplay }
    public var pixelRect: PixelRect { selection.normalizedRect.pixelRect(in: display.pixelSize) }
}

public enum LastAreaResolver {
    public static func resolve(
        _ storedSelection: CaptureSelection,
        among displays: [DisplayDescriptor]
    ) -> LastAreaResolution? {
        if let originalDisplay = displays.first(where: { $0.id == storedSelection.displayID }) {
            return LastAreaResolution(
                selection: storedSelection,
                display: originalDisplay,
                kind: .originalDisplay
            )
        }

        if let mainDisplay = displays.first(where: \.isMain) {
            return fallback(
                storedSelection,
                to: mainDisplay,
                kind: .fallbackToMainDisplay
            )
        }

        guard let firstDisplay = displays.first else { return nil }
        return fallback(
            storedSelection,
            to: firstDisplay,
            kind: .fallbackToFirstAvailableDisplay
        )
    }

    private static func fallback(
        _ selection: CaptureSelection,
        to display: DisplayDescriptor,
        kind: LastAreaResolutionKind
    ) -> LastAreaResolution {
        LastAreaResolution(
            selection: CaptureSelection(
                displayID: display.id,
                normalizedRect: selection.normalizedRect
            ),
            display: display,
            kind: kind
        )
    }
}
