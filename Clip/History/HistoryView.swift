import ClipCore
import SwiftUI

struct HistoryView: View {
    @StateObject private var viewModel: HistoryViewModel

    init(viewModel: @autoclosure @escaping () -> HistoryViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if viewModel.isEmpty {
                emptyState
            } else {
                recordingList
            }

            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 440, idealHeight: 560)
        .sheet(item: $viewModel.renameDraft) { draft in
            HistoryRenameSheet(
                draft: draft,
                onCancel: viewModel.cancelRename,
                onRename: { filename in
                    viewModel.rename(draft.id, to: filename)
                }
            )
        }
        .alert(item: $viewModel.alert) { alert in
            alertView(for: alert)
        }
        .accessibilityIdentifier("clip.history")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent Recordings")
                    .font(.title2.weight(.semibold))
                Text(viewModel.storageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let operation = viewModel.operation {
                ProgressView()
                    .controlSize(.small)
                Text(operation.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Refresh", systemImage: "arrow.clockwise", action: viewModel.refresh)
                .labelStyle(.iconOnly)
                .help("Refresh History")
                .accessibilityIdentifier("clip.history.refresh")

            Button("Clear All…", systemImage: "trash", action: viewModel.requestClearAll)
                .disabled(viewModel.isEmpty)
                .accessibilityIdentifier("clip.history.clearAll")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .disabled(viewModel.isBusy)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Recordings", systemImage: "film.stack")
        } description: {
            Text("Finished recordings will appear here until the configured cleanup date.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("clip.history.empty")
    }

    private var recordingList: some View {
        List(viewModel.items) { item in
            HistoryRow(
                item: item,
                isBusy: viewModel.isBusy(item.id),
                preview: { viewModel.preview(item) },
                copy: { viewModel.copy(item) },
                save: { viewModel.saveAs(item) },
                reveal: { viewModel.reveal(item) },
                rename: { viewModel.beginRename(item) },
                delete: { viewModel.requestDelete(item) }
            )
            .disabled(viewModel.isBusy)
            .listRowInsets(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
        }
        .listStyle(.inset)
        .accessibilityIdentifier("clip.history.list")
    }

    private var footer: some View {
        HStack {
            if let status = viewModel.statusMessage {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Recordings are stored locally on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func alertView(for alert: HistoryAlert) -> Alert {
        switch alert {
        case let .error(_, title, message):
            Alert(
                title: Text(title),
                message: Text(message),
                dismissButton: .default(Text("OK"), action: viewModel.dismissAlert)
            )

        case let .confirmDelete(id, filename):
            Alert(
                title: Text("Delete Recording?"),
                message: Text("\(filename) and its Clip-managed file will be permanently deleted."),
                primaryButton: .destructive(Text("Delete")) {
                    viewModel.confirmDelete(id)
                },
                secondaryButton: .cancel(viewModel.dismissAlert)
            )

        case let .confirmClear(_, recordingCount):
            Alert(
                title: Text("Clear All History?"),
                message: Text(
                    "This permanently deletes \(recordingCount) Clip-managed "
                        + (recordingCount == 1 ? "recording." : "recordings.")
                ),
                primaryButton: .destructive(Text("Clear All"), action: viewModel.confirmClearAll),
                secondaryButton: .cancel(viewModel.dismissAlert)
            )
        }
    }
}

private struct HistoryRow: View {
    let item: RecordingHistoryItem
    let isBusy: Bool
    let preview: () -> Void
    let copy: () -> Void
    let save: () -> Void
    let reveal: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary)
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 72, height: 46)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename.fileName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            Text(HistoryFormatting.bytes(item.managedByteCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 84)
            } else {
                actionButtons
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: preview)
        .contextMenu {
            Button("Preview", systemImage: "play.rectangle", action: preview)
            Button("Copy", systemImage: "doc.on.doc", action: copy)
            Button("Save As…", systemImage: "square.and.arrow.down", action: save)
            Button("Reveal in Finder", systemImage: "folder", action: reveal)
            Divider()
            Button("Rename…", systemImage: "pencil", action: rename)
            Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.history.row.\(item.id.description)")
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button("Preview", systemImage: "play.rectangle", action: preview)
                .help("Preview")
                .accessibilityIdentifier("clip.history.row.preview")
            Button("Copy", systemImage: "doc.on.doc", action: copy)
                .help("Copy")
                .accessibilityIdentifier("clip.history.row.copy")
            Button("Save As…", systemImage: "square.and.arrow.down", action: save)
                .help("Save As…")
                .accessibilityIdentifier("clip.history.row.saveAs")
            Menu {
                Button("Rename…", systemImage: "pencil", action: rename)
                    .accessibilityIdentifier("clip.history.row.rename")
                Button("Reveal in Finder", systemImage: "folder", action: reveal)
                    .accessibilityIdentifier("clip.history.row.reveal")
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
                    .accessibilityIdentifier("clip.history.row.delete")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .help("More Actions")
            .accessibilityIdentifier("clip.history.row.more")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(width: 116)
    }

    private var metadata: String {
        [
            HistoryFormatting.duration(item.trimRange.duration),
            "\(item.pixelSize.width) × \(item.pixelSize.height)",
            "\(item.frameRate.framesPerSecond) FPS",
            HistoryFormatting.audio(
                item.audioConfiguration,
                exportPreference: item.exportAudioPreference
            ),
        ]
        .joined(separator: "  ·  ")
    }
}

private struct HistoryRenameSheet: View {
    let draft: HistoryRenameDraft
    let onCancel: () -> Void
    let onRename: (RecordingFilename) -> Void

    @State private var filenameText: String
    @FocusState private var filenameFieldFocused: Bool

    init(
        draft: HistoryRenameDraft,
        onCancel: @escaping () -> Void,
        onRename: @escaping (RecordingFilename) -> Void
    ) {
        self.draft = draft
        self.onCancel = onCancel
        self.onRename = onRename
        _filenameText = State(initialValue: draft.currentFilename.fileName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Recording")
                .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                TextField("Filename", text: $filenameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($filenameFieldFocused)
                    .accessibilityIdentifier("clip.history.rename.filename")

                if validatedFilename == nil {
                    Text("Enter a valid MP4 filename without folders or control characters.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("clip.history.rename.cancel")
                Button("Rename") {
                    guard let validatedFilename else { return }
                    onRename(validatedFilename)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(validatedFilename == nil)
                .accessibilityIdentifier("clip.history.rename.commit")
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear {
            filenameFieldFocused = true
        }
    }

    private var validatedFilename: RecordingFilename? {
        try? RecordingFilename(validating: filenameText)
    }
}

@MainActor
private struct HistoryViewDemo: PreviewProvider {
    static var previews: some View {
        let index = HistoryDemoData.index()
        HistoryView(
            viewModel: HistoryViewModel(
                index: index,
                actions: .demo(for: index)
            )
        )
    }
}
