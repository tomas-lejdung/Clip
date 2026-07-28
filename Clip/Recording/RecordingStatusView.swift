import SwiftUI

@MainActor
struct RecordingStatusView: View {
    static let contentWidth = ClipPopoverDesign.width
    /// Fallback used only if synchronous SwiftUI fitting-size measurement is
    /// unavailable.
    static let contentSize = CGSize(width: contentWidth, height: 360)

    @ObservedObject var model: RecordingPresentationModel
    private let maximumHeight: CGFloat
    private let onContentHeightChange: (CGFloat) -> Void

    init(
        model: RecordingPresentationModel,
        maximumHeight: CGFloat = 10_000,
        onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.model = model
        self.maximumHeight = maximumHeight
        self.onContentHeightChange = onContentHeightChange
    }

    var body: some View {
        ClipPopoverPane(
            maximumHeight: maximumHeight,
            onContentHeightChange: onContentHeightChange,
            title: stateTitle,
            titleAccessibilityIdentifier: "clip.recording.phase",
            subtitle: stateSubtitle,
            accessibilityIdentifier: "clip.recording.status",
            headerIcon: {
                RecordingStateIndicator(phase: model.snapshot.phase)
            },
            headerTrailing: {
                recordingProgress
            },
            content: {
                audioSection
                if let notice = model.snapshot.notice {
                    noticeSection(notice)
                }
                if let error = model.actionErrorMessage {
                    actionErrorSection(error)
                }
            },
            footer: {
                controls
            }
        )
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
    }

    private var recordingProgress: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(model.elapsedText())
                    .font(.system(.headline, design: .monospaced, weight: .semibold))
                    .contentTransition(.numericText())
                    .accessibilityLabel(
                        String(
                            localized: "Elapsed time: \(model.elapsedText())"
                        )
                    )
                    .accessibilityIdentifier("clip.recording.elapsed")
            }

            if model.isPerformingAction || model.snapshot.phase == .finishing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Working"))
            }
        }
    }

    private var audioSection: some View {
        ClipPopoverSection(
            String(localized: "Audio")
        ) {
            VStack(spacing: 0) {
                RecordingAudioRow(
                    title: String(localized: "Microphone"),
                    systemImage: "mic.fill",
                    state: model.snapshot.microphone
                )
                ClipPopoverRowDivider()
                RecordingAudioRow(
                    title: String(localized: "System Audio"),
                    systemImage: "speaker.wave.2.fill",
                    state: model.snapshot.systemAudio
                )
            }
        }
    }

    private func noticeSection(_ notice: String) -> some View {
        ClipPopoverSection {
            Label(notice, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionErrorSection(_ error: String) -> some View {
        ClipPopoverSection {
            HStack(alignment: .top, spacing: 8) {
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
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08))
        }
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                ClipPopoverButton(
                    model.pauseResumeTitle,
                    systemImage: model.pauseResumeSystemImage,
                    fillsWidth: true,
                    isEnabled: model.canPauseOrResume,
                    accessibilityIdentifier: "clip.recording.pauseResume",
                    action: model.togglePauseResume
                )

                ClipPopoverButton(
                    String(localized: "Finish"),
                    systemImage: "stop.fill",
                    prominence: .primary,
                    fillsWidth: true,
                    isEnabled: model.canFinish,
                    accessibilityIdentifier: "clip.recording.finish",
                    action: model.requestFinish
                )
            }

            Button(role: .destructive) {
                model.requestCancel()
            } label: {
                Label(String(localized: "Cancel Recording"), systemImage: "trash")
            }
            .buttonStyle(
                ClipPopoverButtonStyle(
                    prominence: .destructive,
                    fillsWidth: true
                )
            )
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

    private var stateSubtitle: String {
        switch model.snapshot.phase {
        case .recording:
            String(localized: "Capturing your screen")
        case .paused:
            String(localized: "Capture is paused")
        case .finishing:
            String(localized: "Preparing your preview…")
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
        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
        .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
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
