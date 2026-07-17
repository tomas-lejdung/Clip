import ClipCore
import Combine
import Foundation
import OSLog

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var index: RecordingHistoryIndex
    @Published private(set) var operation: HistoryOperation?
    @Published private(set) var statusMessage: String?
    @Published var renameDraft: HistoryRenameDraft?
    @Published var alert: HistoryAlert?

    private let actions: HistoryActions
    private var operationTask: Task<Void, Never>?

    init(index: RecordingHistoryIndex, actions: HistoryActions) {
        self.index = index
        self.actions = actions
    }

    deinit {
        operationTask?.cancel()
    }

    var items: [RecordingHistoryItem] { index.items }
    var isEmpty: Bool { items.isEmpty }
    var isBusy: Bool { operation != nil }

    var storageSummary: String {
        let count = items.count
        let recordingLabel = count == 1 ? "recording" : "recordings"
        return "\(count) \(recordingLabel) · \(HistoryFormatting.bytes(index.totalManagedByteCount))"
    }

    func isBusy(_ recordingID: RecordingID) -> Bool {
        operation?.involves(recordingID) ?? false
    }

    func refresh() {
        guard begin(.refreshing) else { return }
        let refresh = actions.refresh
        operationTask = Task { [weak self] in
            do {
                let refreshedIndex = try await refresh()
                guard !Task.isCancelled else { return }
                self?.install(refreshedIndex)
                self?.complete(status: nil)
            } catch is CancellationError {
                self?.complete(status: nil)
            } catch {
                self?.fail(title: "Couldn’t Refresh History", error: error)
            }
        }
    }

    func preview(_ item: RecordingHistoryItem) {
        guard begin(.previewing(item.id)) else { return }
        let preview = actions.preview
        operationTask = Task { [weak self] in
            do {
                try await preview(item)
                guard !Task.isCancelled else { return }
                self?.complete(status: nil)
            } catch is CancellationError {
                self?.complete(status: nil)
            } catch {
                self?.fail(title: "Couldn’t Open Preview", error: error)
            }
        }
    }

    func copy(_ item: RecordingHistoryItem) {
        guard begin(.copying(item.id)) else { return }
        let copy = actions.copy
        operationTask = Task { [weak self] in
            do {
                let outcome = try await copy(item)
                guard !Task.isCancelled else { return }
                if let refreshedIndex = outcome.refreshedIndex {
                    self?.install(refreshedIndex)
                }
                self?.complete(
                    status: Self.shareStatus(
                        success: ShareCompletionFormatting.copiedStatus(
                            byteCount: outcome.outputByteCount
                        ),
                        warning: outcome.postShareWarning
                    )
                )
            } catch is CancellationError {
                self?.complete(status: nil)
            } catch {
                self?.fail(title: "Couldn’t Copy Video", error: error)
            }
        }
    }

    func saveAs(_ item: RecordingHistoryItem) {
        guard begin(.saving(item.id)) else { return }
        let save = actions.save
        operationTask = Task { [weak self] in
            do {
                let outcome = try await save(item)
                guard !Task.isCancelled else { return }
                if let outcome {
                    // Only the repository-returned index controls retention after Save As.
                    if let refreshedIndex = outcome.refreshedIndex {
                        self?.install(refreshedIndex)
                    }
                    self?.complete(
                        status: Self.shareStatus(
                            success: "Saved \(item.filename.fileName)",
                            warning: outcome.postShareWarning
                        )
                    )
                } else {
                    self?.complete(status: nil)
                }
            } catch is CancellationError {
                self?.complete(status: nil)
            } catch {
                self?.fail(title: "Couldn’t Save Video", error: error)
            }
        }
    }

    private static func shareStatus(
        success: String,
        warning: String?
    ) -> String {
        guard let warning else { return success }
        return "\(success) — \(warning)"
    }

    func reveal(_ item: RecordingHistoryItem) {
        guard begin(.revealing(item.id)) else { return }
        let reveal = actions.reveal
        operationTask = Task { [weak self] in
            do {
                try await reveal(item)
                guard !Task.isCancelled else { return }
                self?.complete(status: nil)
            } catch is CancellationError {
                self?.complete(status: nil)
            } catch {
                self?.fail(title: "Couldn’t Reveal Recording", error: error)
            }
        }
    }

    func beginRename(_ item: RecordingHistoryItem) {
        guard !isBusy else { return }
        renameDraft = HistoryRenameDraft(id: item.id, currentFilename: item.filename)
    }

    func cancelRename() {
        renameDraft = nil
    }

    func rename(_ id: RecordingID, to filename: RecordingFilename) {
        renameDraft = nil
        guard begin(.renaming(id)) else { return }
        let rename = actions.rename
        operationTask = Task { [weak self] in
            do {
                let updatedIndex = try await rename(id, filename)
                guard !Task.isCancelled else { return }
                self?.install(updatedIndex)
                self?.complete(status: "Renamed to \(filename.fileName)")
            } catch is CancellationError {
                self?.complete(status: nil)
            } catch {
                self?.fail(title: "Couldn’t Rename Recording", error: error)
            }
        }
    }

    func requestDelete(_ item: RecordingHistoryItem) {
        guard !isBusy else { return }
        alert = .confirmDelete(id: item.id, filename: item.filename.fileName)
    }

    func confirmDelete(_ id: RecordingID) {
        alert = nil
        guard begin(.deleting(id)) else { return }
        let delete = actions.delete
        operationTask = Task { [weak self] in
            do {
                let updatedIndex = try await delete(id)
                guard !Task.isCancelled else { return }
                self?.install(updatedIndex)
                self?.complete(status: "Recording deleted")
            } catch is CancellationError {
                self?.complete(status: nil)
            } catch {
                self?.fail(title: "Couldn’t Delete Recording", error: error)
            }
        }
    }

    func requestClearAll() {
        guard !isBusy, !isEmpty else { return }
        alert = .confirmClear(id: UUID(), recordingCount: items.count)
    }

    func confirmClearAll() {
        alert = nil
        guard begin(.clearing) else { return }
        let clear = actions.clear
        operationTask = Task { [weak self] in
            do {
                let updatedIndex = try await clear()
                guard !Task.isCancelled else { return }
                self?.install(updatedIndex)
                self?.complete(status: "History cleared")
            } catch is CancellationError {
                self?.complete(status: nil)
            } catch {
                self?.fail(title: "Couldn’t Clear History", error: error)
            }
        }
    }

    func dismissAlert() {
        alert = nil
    }

    private func begin(_ requestedOperation: HistoryOperation) -> Bool {
        guard !isBusy else { return false }
        operation = requestedOperation
        statusMessage = nil
        return true
    }

    private func install(_ updatedIndex: RecordingHistoryIndex) {
        index = updatedIndex
        if let renameDraft, updatedIndex.item(id: renameDraft.id) == nil {
            self.renameDraft = nil
        }
    }

    private func complete(status: String?) {
        operation = nil
        operationTask = nil
        statusMessage = status
    }

    private func fail(title: String, error: any Error) {
        operation = nil
        operationTask = nil
        let details = UserFacingErrorPresentation.details(for: error)
        ClipLog.storage.error(
            "History operation failed (\(title, privacy: .public)): \(details.technicalDescription, privacy: .private)"
        )
        alert = .error(id: UUID(), title: title, message: details.message)
    }
}
