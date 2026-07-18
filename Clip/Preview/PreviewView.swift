import ClipCore
import SwiftUI

struct PreviewView: View {
    @StateObject private var viewModel: PreviewViewModel

    init(viewModel: @autoclosure @escaping () -> PreviewViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            draggableVideo
                .aspectRatio(viewModel.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)

            VStack(spacing: 14) {
                playbackAndTimeline
                filenameAndPreset
                actionBar

                if let statusMessage = viewModel.statusMessage {
                    HStack(spacing: 8) {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .lineLimit(2)
                        if viewModel.lastSharedFileURL != nil {
                            Button("Reveal in Finder", action: viewModel.revealLastSharedFile)
                                .buttonStyle(.link)
                                .accessibilityIdentifier("clip.preview.reveal")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
                }
            }
            .padding(18)
            .background(.regularMaterial)
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 520, idealHeight: 650)
        .task {
            await viewModel.monitorPlayback()
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"), action: viewModel.dismissAlert)
            )
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: $viewModel.isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Recording", role: .destructive) {
                viewModel.confirmDelete()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelDelete()
            }
        } message: {
            Text("This removes the managed recording from Clip History. Files previously saved or shared are not deleted.")
        }
        .accessibilityIdentifier("clip.preview")
    }

    @ViewBuilder
    private var draggableVideo: some View {
        let surface = ZStack(alignment: .bottomLeading) {
            PreviewPlayerSurface(player: viewModel.player)

            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            HStack(spacing: 10) {
                Button(action: { viewModel.togglePlayback() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .help(viewModel.isPlaying ? "Pause" : "Play")

                Spacer()

                Label("Drag video to share", systemImage: "arrow.up.forward.app")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(14)
        }
        .contentShape(Rectangle())
        .help("Drag this video into a compatible app")
        .accessibilityIdentifier("clip.preview.video")

        if let dragItem = viewModel.dragItem {
            surface.onDrag {
                dragItem.makeItemProvider()
            } preview: {
                Label(viewModel.filenameText, systemImage: "film")
                    .lineLimit(1)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            surface
        }
    }

    private var playbackAndTimeline: some View {
        VStack(spacing: 8) {
            PreviewTimelineView(
                duration: viewModel.duration,
                trimStart: viewModel.trimStart,
                trimEnd: viewModel.trimEnd,
                currentTime: viewModel.currentTime,
                onScrub: { time in viewModel.seek(to: time) },
                onChangeTrimStart: { time in viewModel.updateTrimStart(time) },
                onChangeTrimEnd: { time in viewModel.updateTrimEnd(time) }
            )

            HStack {
                Button(action: { viewModel.togglePlayback() }) {
                    Label(viewModel.isPlaying ? "Pause" : "Play",
                          systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)

                Button("Reset Trim", action: { viewModel.resetTrim() })
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(viewModel.outputSizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("clip.preview.estimated-output-size")
            }
        }
    }

    private var filenameAndPreset: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Filename")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "clip-YYYYMMDD-HHmmss.mp4",
                        text: Binding(
                            get: { viewModel.filenameText },
                            set: { value in viewModel.updateFilename(value) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("clip.preview.filename")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(
                        "Quality",
                        selection: Binding(
                            get: { viewModel.selectedPreset },
                            set: { value in viewModel.selectPreset(value) }
                        )
                    ) {
                        ForEach(ExportPreset.previewOrder, id: \.self) { preset in
                            Text(preset.previewTitle).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .accessibilityIdentifier("clip.preview.preset")
                }
            }

            if viewModel.hasRecordedAudio {
                HStack(spacing: 10) {
                    Toggle(
                        "Remove audio",
                        isOn: Binding(
                            get: { viewModel.isAudioRemoved },
                            set: { viewModel.setAudioRemoved($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("clip.preview.removeAudio")

                    if viewModel.isAudioRemoved {
                        Text("Playback is muted and shared files contain no audio.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Recorded audio is included in playback and shared files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }

            if let filenameError = viewModel.filenameErrorMessage {
                Text(filenameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Retake", systemImage: "arrow.counterclockwise", action: { viewModel.retake() })
                .accessibilityIdentifier("clip.preview.retake")

            Button("Delete", systemImage: "trash", role: .destructive) {
                viewModel.requestDelete()
            }
            .accessibilityIdentifier("clip.preview.delete")

            Spacer()

            if let operation = viewModel.operation {
                ProgressView()
                    .controlSize(.small)
                Text(operation.progressTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Save As…", systemImage: "square.and.arrow.down", action: { viewModel.saveAs() })
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .accessibilityIdentifier("clip.preview.saveAs")

            Button("Copy", systemImage: "doc.on.doc", action: { viewModel.copy() })
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("clip.preview.copy")

            Button("Done", action: { viewModel.done() })
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("clip.preview.done")
        }
        .disabled(viewModel.isBusy)
    }
}

@MainActor
private struct PreviewViewDemo: PreviewProvider {
    static var previews: some View {
        PreviewView(
            viewModel: PreviewViewModel(
                recording: .demo(),
                actions: .demo
            )
        )
    }
}
