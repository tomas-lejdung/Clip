import ClipCore
import Foundation

typealias HistoryRefreshAction = @MainActor @Sendable () async throws -> RecordingHistoryIndex
typealias HistoryItemAction = @MainActor @Sendable (RecordingHistoryItem) async throws -> Void
typealias HistoryCopyAction = @MainActor @Sendable (RecordingHistoryItem) async throws -> HistoryShareOutcome
typealias HistorySaveAction = @MainActor @Sendable (RecordingHistoryItem) async throws -> HistoryShareOutcome?
typealias HistoryRenameAction = @MainActor @Sendable (
    RecordingID,
    RecordingFilename
) async throws -> RecordingHistoryIndex
typealias HistoryDeleteAction = @MainActor @Sendable (RecordingID) async throws -> RecordingHistoryIndex
typealias HistoryClearAction = @MainActor @Sendable () async throws -> RecordingHistoryIndex

/// Copy and Save As finish outside the managed-history transaction. Once that
/// external operation succeeds, a later repository error is a warning rather
/// than a failed share. A nil index leaves the current UI snapshot untouched.
struct HistoryShareOutcome: Sendable {
    let refreshedIndex: RecordingHistoryIndex?
    /// Byte count of the exact exported MP4 placed on the pasteboard or saved.
    /// Nil only when filesystem metadata could not be read after sharing.
    let outputByteCount: Int64?
    let postShareWarning: String?

    init(
        refreshedIndex: RecordingHistoryIndex?,
        outputByteCount: Int64? = nil,
        postShareWarning: String? = nil
    ) {
        self.refreshedIndex = refreshedIndex
        self.outputByteCount = outputByteCount
        self.postShareWarning = postShareWarning
    }
}

/// Integration boundary between History and the repository/file coordinators.
///
/// Mutating and export actions return the repository's authoritative index.
/// In particular, `save` owns any post-export retention decision; the History
/// UI never removes a managed recording merely because Save As succeeded.
struct HistoryActions: Sendable {
    let refresh: HistoryRefreshAction
    let preview: HistoryItemAction
    let copy: HistoryCopyAction
    let save: HistorySaveAction
    let reveal: HistoryItemAction
    let rename: HistoryRenameAction
    let delete: HistoryDeleteAction
    let clear: HistoryClearAction

    init(
        refresh: @escaping HistoryRefreshAction,
        preview: @escaping HistoryItemAction,
        copy: @escaping HistoryCopyAction,
        save: @escaping HistorySaveAction,
        reveal: @escaping HistoryItemAction,
        rename: @escaping HistoryRenameAction,
        delete: @escaping HistoryDeleteAction,
        clear: @escaping HistoryClearAction
    ) {
        self.refresh = refresh
        self.preview = preview
        self.copy = copy
        self.save = save
        self.reveal = reveal
        self.rename = rename
        self.delete = delete
        self.clear = clear
    }
}

enum HistoryOperation: Equatable, Sendable {
    case refreshing
    case previewing(RecordingID)
    case copying(RecordingID)
    case saving(RecordingID)
    case revealing(RecordingID)
    case renaming(RecordingID)
    case deleting(RecordingID)
    case clearing

    var title: String {
        switch self {
        case .refreshing:
            "Refreshing…"
        case .previewing:
            "Opening Preview…"
        case .copying:
            "Preparing Copy…"
        case .saving:
            "Saving…"
        case .revealing:
            "Opening Finder…"
        case .renaming:
            "Renaming…"
        case .deleting:
            "Deleting…"
        case .clearing:
            "Clearing History…"
        }
    }

    func involves(_ recordingID: RecordingID) -> Bool {
        switch self {
        case let .previewing(id), let .copying(id), let .saving(id),
             let .revealing(id), let .renaming(id), let .deleting(id):
            id == recordingID
        case .refreshing, .clearing:
            false
        }
    }
}

struct HistoryRenameDraft: Identifiable, Equatable, Sendable {
    let id: RecordingID
    let currentFilename: RecordingFilename
}

enum HistoryAlert: Identifiable, Sendable {
    case error(id: UUID, title: String, message: String)
    case confirmDelete(id: RecordingID, filename: String)
    case confirmClear(id: UUID, recordingCount: Int)

    var id: String {
        switch self {
        case let .error(id, _, _):
            "error-\(id.uuidString)"
        case let .confirmDelete(id, _):
            "delete-\(id.description)"
        case let .confirmClear(id, _):
            "clear-\(id.uuidString)"
        }
    }
}

enum HistoryFormatting {
    static func duration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func bytes(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    static func audio(
        _ configuration: AudioConfiguration,
        exportPreference: ExportAudioPreference = .keepAudio
    ) -> String {
        if exportPreference == .removeAudio,
           configuration.microphoneEnabled || configuration.systemAudioEnabled {
            return "Audio removed"
        }
        return switch (configuration.microphoneEnabled, configuration.systemAudioEnabled) {
        case (false, false):
            "No audio"
        case (true, false):
            "Microphone"
        case (false, true):
            "System audio"
        case (true, true):
            "Microphone + system audio"
        }
    }
}

enum HistoryDemoData {
    private enum DemoDataError: Error {
        case invalidRecordingID(String)
    }

    static func index() -> RecordingHistoryIndex {
        do {
            let displayID = try DisplayID("demo-main-display")
            let baseDate = Date(timeIntervalSince1970: 1_784_270_538)
            let items = try [
                makeItem(
                    id: "A2C47771-A127-4873-8FD7-F47553283C80",
                    createdAt: baseDate.addingTimeInterval(2 * 60 * 60),
                    filename: "clip-20260717-104218.mp4",
                    relativePath: "Recordings/clip-20260717-104218.mp4",
                    bytes: 3_800_000,
                    duration: 24,
                    pixelSize: PixelSize(width: 1_440, height: 900),
                    frameRate: .thirty,
                    audio: .none,
                    target: .region(
                        CaptureSelection(
                            displayID: displayID,
                            normalizedRect: try NormalizedRect(
                                x: 0.1,
                                y: 0.12,
                                width: 0.65,
                                height: 0.7
                            )
                        )
                    ),
                    preset: .compact
                ),
                makeItem(
                    id: "B07D5DF4-CE93-4E76-A64C-6F7F8241789C",
                    createdAt: baseDate.addingTimeInterval(60 * 60),
                    filename: "dashboard-filters.mp4",
                    relativePath: "Recordings/dashboard-filters.mp4",
                    bytes: 7_100_000,
                    duration: 42,
                    pixelSize: PixelSize(width: 2_560, height: 1_440),
                    frameRate: .sixty,
                    audio: .microphoneOnly,
                    target: .fullscreen(displayID),
                    preset: .crisp
                ),
                makeItem(
                    id: "D8E04743-C590-4EC7-B5D3-986F0FA4F5E4",
                    createdAt: baseDate,
                    filename: "mobile-navigation.mp4",
                    relativePath: "Recordings/mobile-navigation.mp4",
                    bytes: 2_400_000,
                    duration: 17,
                    pixelSize: PixelSize(width: 1_080, height: 1_920),
                    frameRate: .thirty,
                    audio: .systemAudioOnly,
                    target: .fullscreen(displayID),
                    preset: .smallest
                ),
            ]
            return try RecordingHistoryIndex(items: items)
        } catch {
            preconditionFailure("Invalid deterministic History demo state: \(error)")
        }
    }

    private static func makeItem(
        id: String,
        createdAt: Date,
        filename: String,
        relativePath: String,
        bytes: Int64,
        duration: TimeInterval,
        pixelSize: PixelSize,
        frameRate: CaptureFrameRate,
        audio: AudioConfiguration,
        target: CaptureTarget,
        preset: ExportPreset
    ) throws -> RecordingHistoryItem {
        guard let uuid = UUID(uuidString: id) else {
            throw DemoDataError.invalidRecordingID(id)
        }
        return try RecordingHistoryItem(
            id: RecordingID(uuid),
            createdAt: createdAt,
            filename: RecordingFilename(validating: filename),
            managedMaster: ManagedRecordingFile(relativePath: relativePath),
            managedByteCount: bytes,
            recordingDuration: duration,
            pixelSize: pixelSize,
            frameRate: frameRate,
            audioConfiguration: audio,
            captureTarget: target,
            trimRange: TrimRange.full(recordingDuration: duration),
            exportConfiguration: ExportConfiguration(preset: preset)
        )
    }
}

@MainActor
private final class HistoryDemoStore {
    private(set) var index: RecordingHistoryIndex
    private let updateDate = Date(timeIntervalSince1970: 1_800_000_000)

    init(index: RecordingHistoryIndex) {
        self.index = index
    }

    func actions() -> HistoryActions {
        HistoryActions(
            refresh: { [self] in index },
            preview: { _ in },
            copy: { [self] item in
                var updatedItem = item
                try updatedItem.registerSuccessfulExport(at: updateDate)
                index.upsert(updatedItem)
                return HistoryShareOutcome(refreshedIndex: index)
            },
            save: { [self] item in
                var updatedItem = item
                try updatedItem.registerSuccessfulExport(at: updateDate)
                index.upsert(updatedItem)
                return HistoryShareOutcome(refreshedIndex: index)
            },
            reveal: { _ in },
            rename: { [self] id, filename in
                guard var item = index.item(id: id) else { return index }
                try item.rename(to: filename.fileName, at: updateDate)
                index.upsert(item)
                return index
            },
            delete: { [self] id in
                index.remove(id: id)
                return index
            },
            clear: { [self] in
                index = try RecordingHistoryIndex()
                return index
            }
        )
    }
}

extension HistoryActions {
    @MainActor
    static func demo(for index: RecordingHistoryIndex) -> Self {
        HistoryDemoStore(index: index).actions()
    }
}
