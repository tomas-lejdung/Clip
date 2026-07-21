import AppKit
import SwiftUI

struct NativeViewerPopoverView: View {
    static let contentSize = NSSize(width: 360, height: 590)

    @ObservedObject var model: NativeViewerPresentationModel
    @State private var accessCode = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.snapshot.phase == .waitingForAccessCode {
                        accessCodeSection
                    }
                    if !model.snapshot.sources.isEmpty {
                        sourcesSection
                    }
                    if let waitingMessage = model.snapshot.waitingForSourceMessage {
                        waitingForSourceSection(waitingMessage)
                    }
                    if model.snapshot.phase.isLive {
                        displaySection
                        audioSection
                        friendshipSection
                        statisticsSection
                    }
                    if model.snapshot.phase.isTerminal {
                        terminalSection
                    }
                }
                .padding(14)
            }
            Divider()
            HStack(spacing: 10) {
                if model.snapshot.phase.isTerminal {
                    Button("Try Again") { model.retry() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button("Leave") { model.leave() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("clip.nativeViewer.leave")
            }
            .padding(12)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(model.snapshot.phase.isLive ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.snapshot.ownerName.isEmpty ? "Live Share Viewer" : model.snapshot.ownerName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(model.snapshot.phase.title)
                    if model.snapshot.phase.isLive {
                        Text("·")
                        Text(model.snapshot.route.title)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let device = model.snapshot.ownerDeviceName, !device.isEmpty {
                Text(device)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.nativeViewer.status")
    }

    private var accessCodeSection: some View {
        GroupBox("Access Code") {
            VStack(alignment: .leading, spacing: 10) {
                Text("This share requires the code provided by the host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Access code", text: $accessCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submitAccessCode(accessCode) }
                Button("Join Share") { model.submitAccessCode(accessCode) }
                    .buttonStyle(.borderedProminent)
                    .disabled(accessCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourcesSection: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(model.snapshot.sources) { source in
                    if source.id != model.snapshot.sources.first?.id { Divider() }
                    Toggle(isOn: Binding(
                        get: { source.isVisible },
                        set: { model.setSourceVisible(source.id, $0) }
                    )) {
                        HStack(spacing: 8) {
                            Image(systemName: source.isFocused ? "rectangle.inset.filled" : "rectangle")
                                .foregroundStyle(source.isConnected ? .primary : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                if !source.detail.isEmpty {
                                    Text(source.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.vertical, 8)
                }
            }
        } label: {
            HStack {
                Text("Shared Windows")
                Spacer()
                if model.snapshot.visibleSourceCount < model.snapshot.sources.count {
                    Button("Show All") { model.showAll() }
                        .buttonStyle(.plain)
                        .font(.caption)
                }
            }
        }
        .accessibilityIdentifier("clip.nativeViewer.sources")
    }

    private func waitingForSourceSection(_ message: String) -> some View {
        GroupBox("Shared Windows") {
            Label(message, systemImage: "rectangle.badge.clock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
        .accessibilityIdentifier("clip.nativeViewer.waitingForSource")
    }

    private var displaySection: some View {
        GroupBox("Display") {
            Picker("Size", selection: Binding(
                get: { model.snapshot.scaleMode },
                set: { model.setScaleMode($0) }
            )) {
                Text("Auto").tag(NativeViewerScaleMode.automatic)
                Text("Actual").tag(NativeViewerScaleMode.actualPixels)
                Text("Fit").tag(NativeViewerScaleMode.fit)
            }
            .pickerStyle(.segmented)
        }
        .accessibilityIdentifier("clip.nativeViewer.display")
    }

    @ViewBuilder
    private var audioSection: some View {
        if model.snapshot.systemAudioAvailable {
            GroupBox("Audio") {
                VStack(spacing: 10) {
                    Toggle("Play shared audio", isOn: Binding(
                        get: { model.snapshot.systemAudioEnabled },
                        set: { model.setSystemAudioEnabled($0) }
                    ))
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: Binding(
                            get: { model.snapshot.volume },
                            set: { model.setVolume($0) }
                        ), in: 0...1)
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    .disabled(!model.snapshot.systemAudioEnabled)
                }
            }
            .accessibilityIdentifier("clip.nativeViewer.audio")
        }
    }

    @ViewBuilder
    private var friendshipSection: some View {
        switch model.snapshot.friendship {
        case .available:
            Button("Add as Friend") { model.requestFriendship() }
                .buttonStyle(.bordered)
        case .pending:
            Label("Friend request sent", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .friends:
            Label("Friends", systemImage: "person.crop.circle.badge.checkmark")
                .font(.caption)
                .foregroundStyle(.green)
        case .declined:
            Text("Friend request declined")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unavailable:
            EmptyView()
        }
    }

    private var statisticsSection: some View {
        GroupBox("Connection") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    Text("Video")
                    Text(statisticsVideoText)
                }
                GridRow {
                    Text("Rate")
                    Text(statisticsRateText)
                }
                GridRow {
                    Text("Lost")
                    Text("\(model.snapshot.statistics.packetsLost) packets")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("clip.nativeViewer.statistics")
    }

    private var terminalSection: some View {
        Text(model.snapshot.phase.title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statisticsVideoText: String {
        let codec = model.snapshot.statistics.codec ?? String(localized: "Unknown")
        let fps = model.snapshot.statistics.framesPerSecond.formatted(
            .number.precision(.fractionLength(0...1))
        )
        return "\(codec) · \(fps) FPS"
    }

    private var statisticsRateText: String {
        let bits = Double(model.snapshot.statistics.bitsPerSecond)
        if bits >= 1_000_000 {
            return "\((bits / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
        }
        return "\(Int(bits / 1_000)) kbps"
    }
}
