import SwiftUI

@MainActor
struct RecordingStatusView: View {
    @ObservedObject var model: RecordingPresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(spacing: 7) {
                RecordingAudioRow(
                    title: String(localized: "Microphone"),
                    systemImage: "mic.fill",
                    state: model.snapshot.microphone
                )
                RecordingAudioRow(
                    title: String(localized: "System Audio"),
                    systemImage: "speaker.wave.2.fill",
                    state: model.snapshot.systemAudio
                )
            }

            if let notice = model.snapshot.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.actionErrorMessage {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        model.dismissActionError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Dismiss error"))
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }

            controls
        }
        .padding(14)
        .frame(width: 310)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.12))
        }
        .alert(
            String(localized: "Discard this recording?"),
            isPresented: cancelConfirmationBinding
        ) {
            Button(String(localized: "Keep Recording"), role: .cancel) {
                model.dismissCancelConfirmation()
            }
            Button(String(localized: "Discard Recording"), role: .destructive) {
                model.confirmCancel()
            }
        } message: {
            Text(String(localized: "The captured video will be permanently discarded."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.recording.status")
    }

    private var header: some View {
        HStack(spacing: 10) {
            RecordingStateIndicator(phase: model.snapshot.phase)

            VStack(alignment: .leading, spacing: 2) {
                Text(stateTitle)
                    .font(.headline)
                    .accessibilityIdentifier("clip.recording.phase")

                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text(model.elapsedText())
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .contentTransition(.numericText())
                        .accessibilityLabel(
                            String(
                                localized: "Elapsed time: \(model.elapsedText())"
                            )
                        )
                        .accessibilityIdentifier("clip.recording.elapsed")
                }
            }

            Spacer()

            if model.isPerformingAction || model.snapshot.phase == .finishing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Working"))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.togglePauseResume()
                } label: {
                    Label(model.pauseResumeTitle, systemImage: model.pauseResumeSystemImage)
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.canPauseOrResume)
                .accessibilityIdentifier("clip.recording.pauseResume")

                Button {
                    model.requestFinish()
                } label: {
                    Label(String(localized: "Finish"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canFinish)
                .accessibilityIdentifier("clip.recording.finish")
            }

            Button(role: .destructive) {
                model.requestCancel()
            } label: {
                Label(String(localized: "Cancel Recording"), systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canCancel)
            .accessibilityIdentifier("clip.recording.cancel")
        }
    }

    private var stateTitle: String {
        switch model.snapshot.phase {
        case .recording:
            String(localized: "Recording")
        case .paused:
            String(localized: "Paused")
        case .finishing:
            String(localized: "Finishing…")
        }
    }

    private var cancelConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.isCancelConfirmationPresented },
            set: { isPresented in
                if !isPresented {
                    model.dismissCancelConfirmation()
                }
            }
        )
    }
}

private struct RecordingStateIndicator: View {
    let phase: RecordingPresentationPhase
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch phase {
            case .recording:
                Circle()
                    .stroke(.red.opacity(0.55), lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.65 : 0.85)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(
                        .easeOut(duration: 1).repeatForever(autoreverses: false),
                        value: pulse
                    )

                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)

            case .paused:
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.orange, in: Circle())

            case .finishing:
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.secondary, in: Circle())
            }
        }
        .frame(width: 22, height: 22)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}

private struct RecordingAudioRow: View {
    let title: String
    let systemImage: String
    let state: RecordingAudioSourceState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline)

            Spacer(minLength: 8)

            Text(state.statusText)
                .font(.caption)
                .foregroundStyle(stateTextColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch state {
        case .off: .secondary
        case .active: .green
        case .unavailable: .orange
        }
    }

    private var stateTextColor: Color {
        switch state {
        case .unavailable: .orange
        case .off, .active: .secondary
        }
    }
}
