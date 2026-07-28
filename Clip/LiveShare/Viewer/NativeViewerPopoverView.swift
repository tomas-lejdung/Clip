import AppKit
import SwiftUI

struct NativeViewerPopoverView: View {
    static let contentWidth = ClipPopoverDesign.width
    static let contentSize = NSSize(width: contentWidth, height: 590)

    @ObservedObject var model: NativeViewerPresentationModel
    @State private var accessCode = ""
    private let maximumHeight: CGFloat
    private let onContentHeightChange: (CGFloat) -> Void

    init(
        model: NativeViewerPresentationModel,
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
            icon: "rectangle.on.rectangle.angled",
            iconTint: model.snapshot.phase.isLive ? .green : .secondary,
            title: model.snapshot.ownerName.isEmpty
                ? String(localized: "Live Share Viewer")
                : model.snapshot.ownerName,
            subtitle: headerSubtitle,
            accessibilityIdentifier: "clip.nativeViewer.status"
        ) {
            if let device = model.snapshot.ownerDeviceName, !device.isEmpty {
                Text(device)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } content: {
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
                audioSection
                friendshipSection
                statisticsSection
            }
            if model.snapshot.phase.isTerminal {
                terminalSection
            }
        } footer: {
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
        }
    }

    private var headerSubtitle: String {
        guard model.snapshot.phase.isLive else {
            return model.snapshot.phase.title
        }
        return "\(model.snapshot.phase.title) · \(model.snapshot.route.title)"
    }

    private var accessCodeSection: some View {
        ClipPopoverSection(
            String(localized: "Access Code"),
            systemImage: "lock.fill",
            contentInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        ) {
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
        ClipPopoverSection(
            String(localized: "Shared Windows"),
            systemImage: "rectangle.on.rectangle"
        ) {
            HStack(spacing: 10) {
                if model.snapshot.visibleSourceCount < model.snapshot.sources.count {
                    Button("Show All") { model.showAll() }
                        .buttonStyle(.plain)
                        .font(.caption)
                }
                Button {
                    model.bringAllToFront()
                } label: {
                    Label("Bring All to Front", systemImage: "square.3.layers.3d.top.filled")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .accessibilityIdentifier("clip.nativeViewer.bringAllToFront")
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(model.snapshot.sources) { source in
                    if source.id != model.snapshot.sources.first?.id { Divider() }
                    VStack(alignment: .leading, spacing: 7) {
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
                            Spacer(minLength: 4)
                            Toggle("", isOn: Binding(
                                get: { source.isVisible },
                                set: { model.setSourceVisible(source.id, $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }

                        HStack(spacing: 6) {
                            sourceScaleModeMenu(source)
                            Spacer(minLength: 4)
                            sourceActionButton(
                                title: String(localized: "Bring to Front"),
                                systemImage: "macwindow.on.rectangle",
                                identifier: "clip.nativeViewer.source.bringToFront.\(source.id)"
                            ) {
                                model.bringSourceToFront(source.id)
                            }
                            sourceActionButton(
                                title: source.isFullScreen
                                    ? String(localized: "Exit Full Screen")
                                    : String(localized: "Enter Full Screen"),
                                systemImage: source.isFullScreen
                                    ? "arrow.down.right.and.arrow.up.left"
                                    : "arrow.up.left.and.arrow.down.right",
                                identifier: "clip.nativeViewer.source.fullScreen.\(source.id)"
                            ) {
                                model.toggleSourceFullScreen(source.id)
                            }
                            .disabled(!source.isVisible || !source.isConnected)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
        .accessibilityIdentifier("clip.nativeViewer.sources")
    }

    private func sourceScaleModeMenu(
        _ source: NativeViewerSourceViewSnapshot
    ) -> some View {
        Menu {
            Button {
                model.setSourceScaleMode(source.id, .follow)
            } label: {
                modeMenuLabel("Follow Host", isSelected: source.scaleMode == .follow)
            }
            Button {
                model.setSourceScaleMode(source.id, .native)
            } label: {
                modeMenuLabel("Native", isSelected: source.scaleMode == .native)
            }
            Button {
                model.setSourceScaleMode(source.id, .fit)
            } label: {
                modeMenuLabel("Fit", isSelected: source.scaleMode == .fit)
            }
        } label: {
            Label(scaleModeTitle(source.scaleMode), systemImage: "aspectratio")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Window sizing")
        .accessibilityValue(scaleModeTitle(source.scaleMode))
        .accessibilityIdentifier("clip.nativeViewer.source.scaleMode.\(source.id)")
    }

    private func sourceActionButton(
        title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }

    private func modeMenuLabel(
        _ title: LocalizedStringKey,
        isSelected: Bool
    ) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func scaleModeTitle(_ mode: NativeViewerScaleMode) -> String {
        switch mode {
        case .follow: String(localized: "Follow")
        case .native: String(localized: "Native")
        case .fit: String(localized: "Fit")
        }
    }

    private func waitingForSourceSection(_ message: String) -> some View {
        ClipPopoverSection(
            String(localized: "Shared Windows"),
            systemImage: "rectangle.on.rectangle",
            contentInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        ) {
            Label(message, systemImage: "rectangle.badge.clock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        }
        .accessibilityIdentifier("clip.nativeViewer.waitingForSource")
    }

    @ViewBuilder
    private var audioSection: some View {
        if model.snapshot.systemAudioAvailable {
            ClipPopoverSection(
                String(localized: "Audio"),
                systemImage: "speaker.wave.2.fill",
                contentInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            ) {
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
        if model.snapshot.friendship != .unavailable {
            ClipPopoverSection(
                String(localized: "Friend"),
                systemImage: "person.crop.circle.badge.plus",
                contentInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
            ) {
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
        }
    }

    private var statisticsSection: some View {
        ClipPopoverSection(
            String(localized: "Connection"),
            systemImage: "network",
            contentInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        ) {
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
        ClipPopoverSection(
            contentInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        ) {
            Text(model.snapshot.phase.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
