import ClipCore
import SwiftUI

struct HistoryView: View {
    @StateObject private var viewModel: HistoryViewModel
    @State private var selectedTab: HistoryTab

    init(
        viewModel: @autoclosure @escaping () -> HistoryViewModel,
        initialTab: HistoryTab = .recordings
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                Tab("Recordings", systemImage: "film.stack", value: HistoryTab.recordings) {
                    recordingsPane
                }
                Tab("Exports", systemImage: "square.and.arrow.up", value: HistoryTab.exports) {
                    exportsPane
                }
            }
            .tabViewStyle(.tabBarOnly)

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

    private var recordingsPane: some View {
        VStack(spacing: 0) {
            recordingsHeader
            Divider()
            if viewModel.isEmpty {
                recordingsEmptyState
            } else {
                recordingList
            }
        }
        .accessibilityIdentifier(HistoryTab.recordings.accessibilityIdentifier)
    }

    private var exportsPane: some View {
        VStack(spacing: 0) {
            exportsHeader
            Divider()
            if viewModel.exportsAreEmpty {
                exportsEmptyState
            } else {
                exportList
            }
        }
        .accessibilityIdentifier(HistoryTab.exports.accessibilityIdentifier)
    }

    private var recordingsHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent Recordings")
                    .font(.title2.weight(.semibold))
                Text(viewModel.recordingStorageSummary)
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
                .accessibilityIdentifier("clip.history.recordings.refresh")

            Button("Clear All…", systemImage: "trash", action: viewModel.requestClearAll)
                .disabled(viewModel.isEmpty)
                .accessibilityIdentifier("clip.history.recordings.clearAll")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .disabled(viewModel.isBusy)
    }

    private var exportsHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Managed Exports")
                    .font(.title2.weight(.semibold))
                Text(viewModel.exportStorageSummary)
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
                .help("Refresh Exports")
                .accessibilityIdentifier("clip.history.exports.refresh")

            Button(
                "Delete All…",
                systemImage: "trash",
                role: .destructive,
                action: viewModel.requestPurgeExports
            )
            .disabled(viewModel.exportsAreEmpty)
            .accessibilityIdentifier("clip.history.exports.deleteAll")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .disabled(viewModel.isBusy)
    }

    private var recordingsEmptyState: some View {
        ContentUnavailableView {
            Label("No Recordings", systemImage: "film.stack")
        } description: {
            Text("Finished recordings will appear here until the configured cleanup date.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("clip.history.recordings.empty")
    }

    private var exportsEmptyState: some View {
        ContentUnavailableView {
            Label("No Exports", systemImage: "square.and.arrow.up")
        } description: {
            Text("Files created by Copy or drag will appear here while Clip keeps them available.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("clip.history.exports.empty")
    }

    private var recordingList: some View {
        List(viewModel.items) { item in
            RecordingHistoryRow(
                item: item,
                exports: viewModel.linkedExports(for: item.id),
                isBusy: viewModel.isBusy(item.id),
                preview: { viewModel.preview(item) },
                copy: { viewModel.copy(item) },
                save: { viewModel.saveAs(item) },
                reveal: { viewModel.reveal(item) },
                rename: { viewModel.beginRename(item) },
                delete: { viewModel.requestDelete(item) },
                revealExport: { viewModel.reveal($0) },
                deleteExport: { viewModel.requestDelete($0) }
            )
            .disabled(viewModel.isBusy)
            .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        }
        .listStyle(.inset)
        .accessibilityIdentifier("clip.history.recordings.list")
    }

    private var exportList: some View {
        List(viewModel.exports) { export in
            ManagedExportRow(
                export: export,
                sourceFilename: viewModel.sourceRecording(for: export)?.filename.fileName,
                isBusy: viewModel.isBusy(export.id),
                reveal: { viewModel.reveal(export) },
                delete: { viewModel.requestDelete(export) }
            )
            .disabled(viewModel.isBusy)
            .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        }
        .listStyle(.inset)
        .accessibilityIdentifier("clip.history.exports.list")
    }

    private var footer: some View {
        HStack {
            if let status = viewModel.statusMessage {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    selectedTab == .recordings
                        ? "Recordings are stored locally on this Mac."
                        : "Clip-managed exports are removed automatically after seven days."
                )
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
                message: Text(
                    "\(filename) and its Clip-managed recording will be permanently deleted. "
                        + "Existing exports are kept."
                ),
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
                        + " Existing exports are kept."
                ),
                primaryButton: .destructive(Text("Clear All"), action: viewModel.confirmClearAll),
                secondaryButton: .cancel(viewModel.dismissAlert)
            )

        case let .confirmDeleteExport(id, filename):
            Alert(
                title: Text("Delete Export?"),
                message: Text("\(filename) will be permanently deleted."),
                primaryButton: .destructive(Text("Delete")) {
                    viewModel.confirmDeleteExport(id)
                },
                secondaryButton: .cancel(viewModel.dismissAlert)
            )

        case let .confirmPurgeExports(_, exportCount):
            Alert(
                title: Text("Delete All Exports?"),
                message: Text(
                    "This permanently deletes \(exportCount) Clip-managed "
                        + (exportCount == 1 ? "export." : "exports.")
                        + " Recordings are kept."
                ),
                primaryButton: .destructive(
                    Text("Delete All"),
                    action: viewModel.confirmPurgeExports
                ),
                secondaryButton: .cancel(viewModel.dismissAlert)
            )
        }
    }
}

private struct RecordingHistoryRow: View {
    let item: RecordingHistoryItem
    let exports: [ManagedExportRecord]
    let isBusy: Bool
    let preview: () -> Void
    let copy: () -> Void
    let save: () -> Void
    let reveal: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    let revealExport: (ManagedExportRecord) -> Void
    let deleteExport: (ManagedExportRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename.fileName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(HistoryFormatting.bytes(item.managedByteCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 74, height: 24)
                } else {
                    actionControls
                }
            }

            Text(metadata)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if !exports.isEmpty {
                exportChips
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
        .accessibilityIdentifier(accessibilityBase)
    }

    private var actionControls: some View {
        ControlGroup {
            Button(action: preview) {
                Image(systemName: "play.fill")
            }
            .accessibilityLabel("Preview")
            .help("Preview")
            .accessibilityIdentifier("\(accessibilityBase).preview")

            Button(action: copy) {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Copy")
            .help("Copy")
            .accessibilityIdentifier("\(accessibilityBase).copy")

            Menu {
                Button("Save As…", systemImage: "square.and.arrow.down", action: save)
                Button("Rename…", systemImage: "pencil", action: rename)
                Button("Reveal in Finder", systemImage: "folder", action: reveal)
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("More Actions")
            .help("More Actions")
            .accessibilityIdentifier("\(accessibilityBase).more")
        }
        .controlSize(.small)
        .fixedSize()
    }

    private var exportChips: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 175, maximum: 245), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(exports) { export in
                Button {
                    revealExport(export)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(export.filename.fileName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(exportDetails(for: export))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal \(export.filename.fileName) (\(exportDetails(for: export))) in Finder")
                .accessibilityLabel(
                    "Reveal \(export.filename.fileName), \(exportDetails(for: export)), in Finder"
                )
                .accessibilityIdentifier(
                    "\(accessibilityBase).export.\(HistoryAccessibility.identifier(for: export.id))"
                )
                .contextMenu {
                    Button("Reveal in Finder", systemImage: "folder") {
                        revealExport(export)
                    }
                    Button("Delete Export…", systemImage: "trash", role: .destructive) {
                        deleteExport(export)
                    }
                }
            }
        }
    }

    private var accessibilityBase: String {
        "clip.history.recording.\(item.id.description)"
    }

    private func exportDetails(for export: ManagedExportRecord) -> String {
        "\(HistoryFormatting.preset(export.preset)) \(export.qualityPercent)"
            + " · \(HistoryFormatting.bytes(export.byteCount))"
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

private struct ManagedExportRow: View {
    let export: ManagedExportRecord
    let sourceFilename: String?
    let isBusy: Bool
    let reveal: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text(export.filename.fileName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let sourceFilename {
                    Text("From \(sourceFilename)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Label("Source deleted", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(accessibilityBase).sourceDeleted")
                }

                Text(exportMetadata)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            Text(HistoryFormatting.bytes(export.byteCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 62)
            } else {
                ControlGroup {
                    Button(action: reveal) {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Reveal in Finder")
                    .help("Reveal in Finder")
                    .accessibilityIdentifier("\(accessibilityBase).reveal")

                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete Export")
                    .help("Delete Export…")
                    .accessibilityIdentifier("\(accessibilityBase).delete")
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: reveal)
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder", action: reveal)
            Button("Delete Export…", systemImage: "trash", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityBase)
    }

    private var accessibilityBase: String {
        "clip.history.export.\(HistoryAccessibility.identifier(for: export.id))"
    }

    private var exportMetadata: String {
        "\(HistoryFormatting.preset(export.preset)) \(export.qualityPercent)"
            + "  ·  \(export.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private enum HistoryAccessibility {
    static func identifier(for id: ManagedExportID) -> String {
        id.rawValue.replacingOccurrences(of: "/", with: ".")
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
        let exports = HistoryDemoData.exports()
        HistoryView(
            viewModel: HistoryViewModel(
                index: index,
                exportInventory: exports,
                actions: .demo(for: index, exports: exports)
            )
        )
    }
}
