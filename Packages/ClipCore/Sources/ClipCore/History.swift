import Foundation

public struct RecordingID: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum HistoryMetadataError: Error, Equatable, Sendable {
    case invalidManagedRelativePath(String)
    case managedFileMustBeMP4(String)
    case invalidDuration(TimeInterval)
    case invalidTrimRange(start: TimeInterval, end: TimeInterval)
    case trimExceedsRecordingDuration(end: TimeInterval, duration: TimeInterval)
    case negativeByteCount(Int64)
    case updatePredatesCreation
    case duplicateRecordingID(RecordingID)
    case invalidSchemaVersion(Int)
}

public struct ManagedRecordingFile: Codable, Equatable, Hashable, Sendable {
    public let relativePath: String

    public init(relativePath: String) throws {
        let normalized = relativePath.precomposedStringWithCanonicalMapping
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard
            !normalized.isEmpty,
            !normalized.hasPrefix("/"),
            !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw HistoryMetadataError.invalidManagedRelativePath(relativePath)
        }
        guard normalized.lowercased().hasSuffix(".mp4") else {
            throw HistoryMetadataError.managedFileMustBeMP4(relativePath)
        }
        self.relativePath = normalized
    }

    public func resolved(inside rootDirectory: URL) -> URL {
        relativePath.split(separator: "/").reduce(rootDirectory) { partialURL, component in
            partialURL.appending(path: String(component))
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let path = try container.decode(String.self)
        do {
            try self.init(relativePath: path)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid managed recording path: \(error)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(relativePath)
    }
}

public struct TrimRange: Codable, Equatable, Hashable, Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(startTime: TimeInterval, endTime: TimeInterval) throws {
        guard
            startTime.isFinite,
            endTime.isFinite,
            startTime >= 0,
            endTime > startTime
        else {
            throw HistoryMetadataError.invalidTrimRange(start: startTime, end: endTime)
        }
        self.startTime = startTime
        self.endTime = endTime
    }

    public static func full(recordingDuration: TimeInterval) throws -> Self {
        guard recordingDuration.isFinite, recordingDuration > 0 else {
            throw HistoryMetadataError.invalidDuration(recordingDuration)
        }
        return try Self(startTime: 0, endTime: recordingDuration)
    }

    public var duration: TimeInterval { endTime - startTime }

    public func validate(recordingDuration: TimeInterval) throws {
        guard recordingDuration.isFinite, recordingDuration > 0 else {
            throw HistoryMetadataError.invalidDuration(recordingDuration)
        }
        guard endTime <= recordingDuration else {
            throw HistoryMetadataError.trimExceedsRecordingDuration(
                end: endTime,
                duration: recordingDuration
            )
        }
    }

    private enum CodingKeys: CodingKey {
        case startTime
        case endTime
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        let endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        do {
            try self.init(startTime: startTime, endTime: endTime)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .startTime,
                in: container,
                debugDescription: "Trim range must be finite, non-negative, and non-empty."
            )
        }
    }
}

/// The intrinsic media properties of a finalized recording file.
///
/// History keeps edit state separately from these properties. Replacing a
/// managed master therefore rebases its edit state onto the replacement's
/// inspected media properties instead of retaining a trim range that belonged
/// to the previous file.
public struct RecordingMediaMetadata: Codable, Equatable, Hashable, Sendable {
    public let duration: TimeInterval
    public let pixelSize: PixelSize
    public let frameRate: CaptureFrameRate

    public init(
        duration: TimeInterval,
        pixelSize: PixelSize,
        frameRate: CaptureFrameRate
    ) throws {
        guard duration.isFinite, duration > 0 else {
            throw HistoryMetadataError.invalidDuration(duration)
        }
        self.duration = duration
        self.pixelSize = pixelSize
        self.frameRate = frameRate
    }

    private enum CodingKeys: CodingKey {
        case duration
        case pixelSize
        case frameRate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                duration: container.decode(TimeInterval.self, forKey: .duration),
                pixelSize: container.decode(PixelSize.self, forKey: .pixelSize),
                frameRate: container.decode(CaptureFrameRate.self, forKey: .frameRate)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid recording media metadata: \(error)"
                )
            )
        }
    }
}

public enum ExportAudioPreference: String, Codable, CaseIterable, Equatable, Sendable {
    case keepAudio
    case removeAudio

    public var includesAudio: Bool {
        self == .keepAudio
    }
}

public struct RecordingHistoryItem: Codable, Equatable, Sendable, Identifiable {
    public let id: RecordingID
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var filename: RecordingFilename
    public private(set) var managedMaster: ManagedRecordingFile
    public private(set) var managedByteCount: Int64
    public private(set) var recordingDuration: TimeInterval
    public private(set) var pixelSize: PixelSize
    public private(set) var frameRate: CaptureFrameRate
    public let audioConfiguration: AudioConfiguration
    public let captureTarget: CaptureTarget
    /// Exact capture inputs for Retake. Older history files decode this as nil
    /// and retain the legacy current-settings fallback.
    public let captureSessionSnapshot: CaptureSessionSnapshot?
    public private(set) var trimRange: TrimRange
    public private(set) var exportConfiguration: ExportConfiguration
    public private(set) var exportAudioPreference: ExportAudioPreference
    public private(set) var lastExportedAt: Date?

    public init(
        id: RecordingID,
        createdAt: Date,
        updatedAt: Date? = nil,
        filename: RecordingFilename,
        managedMaster: ManagedRecordingFile,
        managedByteCount: Int64,
        recordingDuration: TimeInterval,
        pixelSize: PixelSize,
        frameRate: CaptureFrameRate,
        audioConfiguration: AudioConfiguration,
        captureTarget: CaptureTarget,
        captureSessionSnapshot: CaptureSessionSnapshot? = nil,
        trimRange: TrimRange,
        exportConfiguration: ExportConfiguration,
        exportAudioPreference: ExportAudioPreference = .keepAudio,
        lastExportedAt: Date? = nil
    ) throws {
        guard recordingDuration.isFinite, recordingDuration > 0 else {
            throw HistoryMetadataError.invalidDuration(recordingDuration)
        }
        try trimRange.validate(recordingDuration: recordingDuration)
        guard managedByteCount >= 0 else {
            throw HistoryMetadataError.negativeByteCount(managedByteCount)
        }
        let resolvedUpdatedAt = updatedAt ?? createdAt
        guard resolvedUpdatedAt >= createdAt, lastExportedAt.map({ $0 >= createdAt }) ?? true else {
            throw HistoryMetadataError.updatePredatesCreation
        }

        self.id = id
        self.createdAt = createdAt
        self.updatedAt = resolvedUpdatedAt
        self.filename = filename
        self.managedMaster = managedMaster
        self.managedByteCount = managedByteCount
        self.recordingDuration = recordingDuration
        self.pixelSize = pixelSize
        self.frameRate = frameRate
        self.audioConfiguration = audioConfiguration
        self.captureTarget = captureTarget
        self.captureSessionSnapshot = captureSessionSnapshot
        self.trimRange = trimRange
        self.exportConfiguration = exportConfiguration
        self.exportAudioPreference = exportAudioPreference
        self.lastExportedAt = lastExportedAt
    }

    public mutating func rename(to userInput: String, at date: Date) throws {
        try validateUpdateDate(date)
        filename = try filename.renamed(to: userInput)
        updatedAt = date
    }

    public mutating func setTrimRange(_ trimRange: TrimRange, at date: Date) throws {
        try validateUpdateDate(date)
        try trimRange.validate(recordingDuration: recordingDuration)
        self.trimRange = trimRange
        updatedAt = date
    }

    public mutating func setExportConfiguration(
        _ exportConfiguration: ExportConfiguration,
        at date: Date
    ) throws {
        try validateUpdateDate(date)
        self.exportConfiguration = exportConfiguration
        updatedAt = date
    }

    public mutating func setExportAudioPreference(
        _ preference: ExportAudioPreference,
        at date: Date
    ) throws {
        try validateUpdateDate(date)
        exportAudioPreference = preference
        updatedAt = date
    }

    public mutating func registerSuccessfulExport(at date: Date) throws {
        try validateUpdateDate(date)
        lastExportedAt = date
        updatedAt = date
    }

    public mutating func replaceManagedMaster(
        with managedMaster: ManagedRecordingFile,
        byteCount: Int64,
        mediaMetadata: RecordingMediaMetadata,
        at date: Date
    ) throws {
        try validateUpdateDate(date)
        guard byteCount >= 0 else {
            throw HistoryMetadataError.negativeByteCount(byteCount)
        }
        let fullTrimRange = try TrimRange.full(recordingDuration: mediaMetadata.duration)
        self.managedMaster = managedMaster
        managedByteCount = byteCount
        recordingDuration = mediaMetadata.duration
        pixelSize = mediaMetadata.pixelSize
        frameRate = mediaMetadata.frameRate
        trimRange = fullTrimRange
        updatedAt = date
        lastExportedAt = date
    }

    private func validateUpdateDate(_ date: Date) throws {
        guard date >= createdAt else {
            throw HistoryMetadataError.updatePredatesCreation
        }
    }

    private enum CodingKeys: CodingKey {
        case id
        case createdAt
        case updatedAt
        case filename
        case managedMaster
        case managedByteCount
        case recordingDuration
        case pixelSize
        case frameRate
        case audioConfiguration
        case captureTarget
        case captureSessionSnapshot
        case trimRange
        case exportConfiguration
        case exportAudioPreference
        case lastExportedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(RecordingID.self, forKey: .id),
                createdAt: container.decode(Date.self, forKey: .createdAt),
                updatedAt: container.decode(Date.self, forKey: .updatedAt),
                filename: container.decode(RecordingFilename.self, forKey: .filename),
                managedMaster: container.decode(ManagedRecordingFile.self, forKey: .managedMaster),
                managedByteCount: container.decode(Int64.self, forKey: .managedByteCount),
                recordingDuration: container.decode(TimeInterval.self, forKey: .recordingDuration),
                pixelSize: container.decode(PixelSize.self, forKey: .pixelSize),
                frameRate: container.decode(CaptureFrameRate.self, forKey: .frameRate),
                audioConfiguration: container.decode(AudioConfiguration.self, forKey: .audioConfiguration),
                captureTarget: container.decode(CaptureTarget.self, forKey: .captureTarget),
                captureSessionSnapshot: container.decodeIfPresent(
                    CaptureSessionSnapshot.self,
                    forKey: .captureSessionSnapshot
                ),
                trimRange: container.decode(TrimRange.self, forKey: .trimRange),
                exportConfiguration: container.decode(ExportConfiguration.self, forKey: .exportConfiguration),
                exportAudioPreference: container.decodeIfPresent(
                    ExportAudioPreference.self,
                    forKey: .exportAudioPreference
                ) ?? .keepAudio,
                lastExportedAt: container.decodeIfPresent(Date.self, forKey: .lastExportedAt)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid recording history item: \(error)"
                )
            )
        }
    }
}

public enum HistoryRetentionPolicy: String, CaseIterable, Codable, Hashable, Sendable {
    case oneDay
    case sevenDays
    case thirtyDays
    case indefinitely
    case doNotRetainAfterExport

    public var retentionInterval: TimeInterval? {
        switch self {
        case .oneDay:
            24 * 60 * 60
        case .sevenDays:
            7 * 24 * 60 * 60
        case .thirtyDays:
            30 * 24 * 60 * 60
        case .indefinitely, .doNotRetainAfterExport:
            nil
        }
    }

    public func shouldExpire(createdAt: Date, now: Date) -> Bool {
        guard let retentionInterval else { return false }
        return now.timeIntervalSince(createdAt) >= retentionInterval
    }

    public var removesAfterSuccessfulExport: Bool {
        self == .doNotRetainAfterExport
    }

    public func postExportDisposition(keepOriginalAfterExport: Bool) -> HistoryPostExportDisposition {
        if removesAfterSuccessfulExport {
            return .removeHistoryItem
        }
        return keepOriginalAfterExport ? .keepOriginal : .replaceOriginalWithExport
    }
}

public enum HistoryPostExportDisposition: String, Codable, Equatable, Hashable, Sendable {
    case keepOriginal
    case replaceOriginalWithExport
    case removeHistoryItem
}

public struct HistoryCleanupPlan: Codable, Equatable, Sendable {
    public let recordingIDs: [RecordingID]
    public let reclaimableByteCount: Int64

    public init(recordingIDs: [RecordingID], reclaimableByteCount: Int64) {
        self.recordingIDs = recordingIDs
        self.reclaimableByteCount = reclaimableByteCount
    }
}

public enum HistoryCleanupPlanner {
    public static func plan(
        items: [RecordingHistoryItem],
        policy: HistoryRetentionPolicy,
        now: Date
    ) -> HistoryCleanupPlan {
        let expired = items.filter { policy.shouldExpire(createdAt: $0.createdAt, now: now) }
        return HistoryCleanupPlan(
            recordingIDs: expired.map(\.id),
            reclaimableByteCount: saturatingByteCount(of: expired)
        )
    }

    private static func saturatingByteCount(of items: [RecordingHistoryItem]) -> Int64 {
        items.reduce(into: Int64.zero) { result, item in
            let (sum, overflow) = result.addingReportingOverflow(item.managedByteCount)
            result = overflow ? .max : sum
        }
    }
}

public struct RecordingHistoryIndex: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public private(set) var items: [RecordingHistoryItem]

    public init(
        schemaVersion: Int = RecordingHistoryIndex.currentSchemaVersion,
        items: [RecordingHistoryItem] = []
    ) throws {
        guard schemaVersion > 0 else {
            throw HistoryMetadataError.invalidSchemaVersion(schemaVersion)
        }
        var seen = Set<RecordingID>()
        for item in items where !seen.insert(item.id).inserted {
            throw HistoryMetadataError.duplicateRecordingID(item.id)
        }
        self.schemaVersion = schemaVersion
        self.items = Self.sorted(items)
    }

    public var totalManagedByteCount: Int64 {
        items.reduce(into: Int64.zero) { result, item in
            let (sum, overflow) = result.addingReportingOverflow(item.managedByteCount)
            result = overflow ? .max : sum
        }
    }

    public func item(id: RecordingID) -> RecordingHistoryItem? {
        items.first(where: { $0.id == id })
    }

    public mutating func upsert(_ item: RecordingHistoryItem) {
        items.removeAll(where: { $0.id == item.id })
        items.append(item)
        items = Self.sorted(items)
    }

    @discardableResult
    public mutating func remove(id: RecordingID) -> RecordingHistoryItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func applyCleanupPlan(_ plan: HistoryCleanupPlan) {
        let ids = Set(plan.recordingIDs)
        items.removeAll(where: { ids.contains($0.id) })
    }

    private static func sorted(_ items: [RecordingHistoryItem]) -> [RecordingHistoryItem] {
        items.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.description < rhs.id.description
        }
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion
        case items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let items = try container.decode([RecordingHistoryItem].self, forKey: .items)
        do {
            try self.init(schemaVersion: schemaVersion, items: items)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid recording history index: \(error)"
                )
            )
        }
    }
}
