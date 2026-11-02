import ClipCore
import SwiftUI

struct PreviewView: View {
    @StateObject private var viewModel: PreviewViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                filenameAndProcessing
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
            PreviewPlayerSurface(player: viewModel.isExpandedPreviewPresented ? nil : viewModel.player)

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
                .disabled(viewModel.isBusy)

                Button(action: viewModel.showExpandedPreview) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .help("Open larger preview")
                .accessibilityLabel("Open larger preview")
                .accessibilityIdentifier("clip.preview.expand")
                .disabled(viewModel.isBusy)

                Spacer()

                if viewModel.canShare {
                    Label("Drag video to share", systemImage: "arrow.up.forward.app")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(14)
        }
        .overlay {
            if let state = viewModel.processingState, state.phase != .ready {
                processingOverlay(state)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.processingState?.phase)
        .contentShape(Rectangle())
        .help("Drag this video into a compatible app")
        .accessibilityIdentifier("clip.preview.video")

        if viewModel.canShare {
            surface.onDrag {
                viewModel.dragItem?.makeItemProvider() ?? NSItemProvider()
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
                isEditingTrim: viewModel.isEditingTrim,
                onScrub: { time in viewModel.seek(to: time) },
                onChangeTrimStart: { time in viewModel.updateTrimStart(time) },
                onChangeTrimEnd: { time in viewModel.updateTrimEnd(time) }
            )

            HStack(spacing: 12) {
                if viewModel.isEditingTrim {
                    Button("Save Trim", action: viewModel.saveTrim)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!viewModel.canSaveTrim)
                        .accessibilityIdentifier("clip.preview.saveTrim")

                    Button("Cancel", action: viewModel.cancelTrimEditing)
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("clip.preview.cancelTrim")

                    Button("Reset Trim", action: viewModel.resetTrim)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("clip.preview.resetTrim")
                } else {
                    Button("Trim", systemImage: "crop", action: viewModel.beginTrimEditing)
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canEditTrim)
                        .accessibilityIdentifier("clip.preview.trim")
                }

                Spacer()

                Text(viewModel.outputSizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("clip.preview.estimated-output-size")
            }
        }
        .disabled(viewModel.isBusy)
    }

    private var filenameAndProcessing: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Filename")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "clip-YYYYMMDD-HHmmss",
                        text: Binding(
                            get: { viewModel.filenameText },
                            set: { value in viewModel.updateFilename(value) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("clip.preview.filename")
                    .disabled(viewModel.isBusy)
                }
            }

            if let state = viewModel.processingState { processingControls(state) }

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
                    .disabled(viewModel.isBusy)

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

    private func processingControls(_ state: PreviewProcessingState) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Resolution").font(.caption).foregroundStyle(.secondary)
                Picker("Resolution", selection: Binding(
                    get: { state.options.scale },
                    set: { viewModel.selectResolution($0) }
                )) {
                    ForEach(RecordingResolutionScale.allCases, id: \.self) { scale in
                        Text(viewModel.resolutionTitle(scale)).tag(scale)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("clip.preview.resolution")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("CRF").font(.caption).foregroundStyle(.secondary)
                Picker("CRF", selection: Binding(
                    get: { state.options.crf },
                    set: { viewModel.selectCRF($0) }
                )) {
                    ForEach(viewModel.availableCRFValues, id: \.self) { value in
                        Text(String(value)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("clip.preview.crf")
            }
            .help("Lower values keep more detail and create larger files.")

            Spacer(minLength: 0)
        }
        .disabled(!viewModel.canEditProcessing)
    }

    private func processingOverlay(_ state: PreviewProcessingState) -> some View {
        ZStack {
            Color.black.opacity(0.28)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .frame(width: 48, height: 48)
                    Image(systemName: state.phase == .failed ? "exclamationmark.triangle" : "film.stack")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.primary)
                }
                Text(state.phase.title).font(.headline)
                if state.phase == .failed {
                    Text(state.message ?? "Your recording could not be processed. Try again or close the preview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again", action: viewModel.retryProcessing)
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canEditProcessing)
                        .accessibilityIdentifier("clip.preview.retryProcessing")
                } else if let progress = state.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .accessibilityLabel(state.phase.title)
                        .accessibilityValue("\(Int(progress * 100)) percent")
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(24)
            .frame(width: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.16), radius: 24, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("clip.preview.processing")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Retake", systemImage: "arrow.counterclockwise", action: { viewModel.retake() })
                .accessibilityIdentifier("clip.preview.retake")
                .disabled(viewModel.isBusy || viewModel.isEditingTrim)

            Button("Delete", systemImage: "trash", role: .destructive) {
                viewModel.requestDelete()
            }
            .accessibilityIdentifier("clip.preview.delete")
            .disabled(viewModel.isBusy)

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
                .disabled(!viewModel.canShare)

            Button("Copy", systemImage: "doc.on.doc", action: { viewModel.copy() })
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("clip.preview.copy")
                .disabled(!viewModel.canShare)

            Button("Done", action: { viewModel.done() })
                .keyboardShortcut(viewModel.isEditingTrim ? nil : .defaultAction)
                .accessibilityIdentifier("clip.preview.done")
                .disabled(!viewModel.canClose)
        }
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
