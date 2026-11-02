import Foundation

/// Output sizes are percentages of the captured backing pixels, including
/// Retina detail. They never refer to the display's logical point dimensions.
public enum RecordingResolutionScale: Int, CaseIterable, Codable, Hashable, Sendable {
    case native = 100
    case threeQuarter = 75
    case half = 50
    case quarter = 25

    public var percent: Int { rawValue }

    public func pixelSize(from native: PixelSize) throws -> PixelSize {
        func even(_ value: Int) -> Int {
            max(2, Int((Double(value) * Double(rawValue) / 100).rounded(.down)) / 2 * 2)
        }
        return try PixelSize(width: even(native.width), height: even(native.height))
    }
}

public enum RecordingProcessingOptionsError: Error, LocalizedError, Equatable, Sendable {
    case invalidCRF
    case invalidCaptureBitrate

    public var errorDescription: String? {
        switch self {
        case .invalidCRF: "Choose a CRF from 1 to 51."
        case .invalidCaptureBitrate: "Choose a recording bitrate from 1 to 100 Mbps."
        }
    }
}

/// Remembered recording and processing choices, not export presets. Capture bitrate applies
/// to the next recording; resolution and CRF can reprocess a retained original.
public struct RecordingProcessingOptions: Codable, Equatable, Hashable, Sendable {
    public static let defaults = Self()
    public static let crfRange = 1...51
    public static let captureBitrateRange = 1...100
    public var scale: RecordingResolutionScale
    public var crf: Int
    public var captureBitrateMbps: Int

    public init(scale: RecordingResolutionScale = .native, crf: Int = 24, captureBitrateMbps: Int = 10) {
        self.scale = scale
        self.crf = crf
        self.captureBitrateMbps = captureBitrateMbps
    }

    public var isValid: Bool { Self.crfRange.contains(crf) && Self.captureBitrateRange.contains(captureBitrateMbps) }
    public var targetAverageBitRate: Int { captureBitrateMbps * 1_000_000 }

    public func validate() throws {
        guard Self.crfRange.contains(crf) else { throw RecordingProcessingOptionsError.invalidCRF }
        guard Self.captureBitrateRange.contains(captureBitrateMbps) else { throw RecordingProcessingOptionsError.invalidCaptureBitrate }
    }

    private enum CodingKeys: String, CodingKey { case scale, crf, captureBitrateMbps }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scale: try values.decode(RecordingResolutionScale.self, forKey: .scale),
                  crf: try values.decode(Int.self, forKey: .crf),
                  captureBitrateMbps: try values.decode(Int.self, forKey: .captureBitrateMbps))
        do { try validate() }
        catch { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.localizedDescription)) }
    }
}

/// Provenance of the untrimmed H.264 Source. Missing on older History entries;
/// old Apple quality numbers are deliberately never interpreted as x264 CRF.
public struct RecordingProcessingMetadata: Codable, Equatable, Hashable, Sendable {
    public let recipeVersion: Int
    public let options: RecordingProcessingOptions
    public let capturedPixelSize: PixelSize

    public init(options: RecordingProcessingOptions, capturedPixelSize: PixelSize, recipeVersion: Int = 1) {
        self.recipeVersion = recipeVersion
        self.options = options
        self.capturedPixelSize = capturedPixelSize
    }
}
