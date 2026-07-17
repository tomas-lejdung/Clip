import Foundation

public enum ExportPreset: String, CaseIterable, Codable, Hashable, Sendable {
    case compact
    case crisp
    case smallest
}

public enum SmallestSizeTargetError: Error, Equatable, Sendable {
    case customTargetOutOfRange(Int)
}

public enum SmallestSizeTarget: Codable, Hashable, Sendable {
    public static let customRange = 1...500

    case tenMegabytes
    case twentyFiveMegabytes
    case custom(megabytes: Int)

    public init(customMegabytes: Int) throws {
        guard Self.customRange.contains(customMegabytes) else {
            throw SmallestSizeTargetError.customTargetOutOfRange(customMegabytes)
        }
        self = .custom(megabytes: customMegabytes)
    }

    public var megabytes: Int {
        switch self {
        case .tenMegabytes:
            10
        case .twentyFiveMegabytes:
            25
        case let .custom(megabytes):
            megabytes
        }
    }

    /// Decimal megabytes are used because upload limits are normally expressed in MB, not MiB.
    public var targetByteCount: Int64 {
        Int64(megabytes) * 1_000_000
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case megabytes
    }

    private enum Kind: String, Codable {
        case tenMegabytes
        case twentyFiveMegabytes
        case custom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .tenMegabytes:
            self = .tenMegabytes
        case .twentyFiveMegabytes:
            self = .twentyFiveMegabytes
        case .custom:
            let megabytes = try container.decode(Int.self, forKey: .megabytes)
            do {
                try self.init(customMegabytes: megabytes)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .megabytes,
                    in: container,
                    debugDescription: "Custom target must be between 1 MB and 500 MB."
                )
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tenMegabytes:
            try container.encode(Kind.tenMegabytes, forKey: .kind)
        case .twentyFiveMegabytes:
            try container.encode(Kind.twentyFiveMegabytes, forKey: .kind)
        case let .custom(megabytes):
            guard Self.customRange.contains(megabytes) else {
                throw EncodingError.invalidValue(
                    megabytes,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Custom target must be between 1 MB and 500 MB."
                    )
                )
            }
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(megabytes, forKey: .megabytes)
        }
    }
}

public struct ExportConfiguration: Codable, Equatable, Hashable, Sendable {
    public var preset: ExportPreset
    public var smallestSizeTarget: SmallestSizeTarget

    public init(
        preset: ExportPreset,
        smallestSizeTarget: SmallestSizeTarget = .twentyFiveMegabytes
    ) {
        self.preset = preset
        self.smallestSizeTarget = smallestSizeTarget
    }

    public static let compact = Self(preset: .compact)
    public static let crisp = Self(preset: .crisp)
    public static let smallest10MB = Self(
        preset: .smallest,
        smallestSizeTarget: .tenMegabytes
    )
    public static let smallest25MB = Self(
        preset: .smallest,
        smallestSizeTarget: .twentyFiveMegabytes
    )
}
