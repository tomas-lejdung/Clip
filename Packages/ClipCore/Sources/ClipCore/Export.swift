import Foundation

public enum ExportPreset: String, CaseIterable, Codable, Hashable, Sendable {
    case compact
    case crisp
    case smallest
}

/// User-facing H.264 quality values use whole numbers so Settings never needs
/// to expose VideoToolbox's fractional representation.
public struct ExportQualitySettings: Codable, Equatable, Hashable, Sendable {
    public static let validRange = 1...100
    public static let defaults = Self(crisp: 98, compact: 90, smallest: 70)

    public var crisp: Int
    public var compact: Int
    public var smallest: Int

    public init(crisp: Int, compact: Int, smallest: Int) {
        self.crisp = crisp
        self.compact = compact
        self.smallest = smallest
    }

    public func quality(for preset: ExportPreset) -> Int {
        switch preset {
        case .crisp:
            crisp
        case .compact:
            compact
        case .smallest:
            smallest
        }
    }

    /// VideoToolbox represents quality on a zero-through-one scale.
    public func normalizedQuality(for preset: ExportPreset) -> Double {
        Double(quality(for: preset)) / 100
    }
}

public struct ExportConfiguration: Codable, Equatable, Hashable, Sendable {
    public var preset: ExportPreset

    public init(preset: ExportPreset) {
        self.preset = preset
    }

    public static let compact = Self(preset: .compact)
    public static let crisp = Self(preset: .crisp)
    public static let smallest = Self(preset: .smallest)
}
