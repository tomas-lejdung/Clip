import AppKit
import SwiftUI

@MainActor
struct LiveSharePopoverView: View {
    static let contentSize = CGSize(width: 380, height: 620)

    @ObservedObject var model: LiveSharePresentationModel
    @State private var statisticsExpanded: Bool
    @State private var showsInviteEntry = false
    @State private var inviteEntry = ""

    init(
        model: LiveSharePresentationModel,
        initiallyExpandsStatistics: Bool = false
    ) {
        self.model = model
        _statisticsExpanded = State(initialValue: initiallyExpandsStatistics)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    if let warning = model.snapshot.capturePressureWarning {
                        capturePressureBanner(warning)
                    }
                    shareLinkSection
                    if model.snapshot.sessionStage == .active {
                        Divider()
                        sourcesSection
                        Divider()
                        streamSettingsSection
                        Divider()
                        viewersSection
                        statisticsSection
                    } else {
                        Divider()
                        preparationSection
                    }
                }
                .padding(14)
            }

            Divider()
            sessionActions
                .padding(12)
                .background(.bar)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.liveShare.popover")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(headerTint.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(headerTint)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Live Share")
                    .font(.headline)
                HStack(spacing: 5) {
                    if model.snapshot.phase.showsLiveIndicator {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    Text(model.snapshot.phase.statusText)
                        .font(.caption)
                        .foregroundStyle(model.snapshot.phase.isFailure ? .red : .secondary)
                        .lineLimit(2)
                }
                .accessibilityIdentifier("clip.liveShare.status")
            }

            Spacer(minLength: 8)

            if model.snapshot.sessionStage == .active {
                Label(
                    "\(model.snapshot.connectedViewerCount)",
                    systemImage: "person.2.fill"
                )
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(String(localized: "Connected viewers"))
                .accessibilityLabel(
                    String(localized: "\(model.snapshot.connectedViewerCount) connected viewers")
                )
                .accessibilityIdentifier("clip.liveShare.viewerCount")
            }
        }
    }

    private func capturePressureBanner(
        _ warning: LiveShareCapturePressureWarningSnapshot
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.title)
                    .font(.caption.weight(.semibold))
                Text(warning.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clip.liveShare.capturePressureWarning")
    }

    @ViewBuilder
    private var shareLinkSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader(String(localized: "Invite"), systemImage: "link")

            if let room = model.snapshot.room {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(room.roomCode)
                            .font(.subheadline.weight(.semibold).monospaced())
                            .textSelection(.enabled)
                        Spacer(minLength: 6)
                        Button {
                            model.replaceRoom()
                        } label: {
                            Label(
                                String(localized: "New Room"),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .controlSize(.small)
                        .disabled(!model.snapshot.canReplaceRoom)
                        .accessibilityIdentifier("clip.liveShare.newRoom")
                    }

                    HStack(spacing: 8) {
                        Text(room.viewerURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 6)
                        Button {
                            model.copyLink()
                        } label: {
                            Label(
                                model.copiedItem == .link
                                    ? String(localized: "Copied")
                                    : String(localized: "Copy Invite"),
                                systemImage: model.copiedItem == .link
                                    ? "checkmark"
                                    : "doc.on.doc"
                            )
                        }
                        .controlSize(.small)
                        .disabled(!room.isAvailable)
                        .accessibilityIdentifier("clip.liveShare.copyLink")
                    }

                    if !room.isAvailable {
                        Label(
                            String(
                                localized: "Share link temporarily unavailable. Existing viewers stay connected."
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("clip.liveShare.signalingUnavailable")
                    }

                    Toggle(
                        String(localized: "Access Code"),
                        isOn: Binding(
                            get: { model.snapshot.accessCodeEnabled },
                            set: { model.setAccessCodeEnabled($0) }
                        )
                    )
                    .disabled(!model.snapshot.canChangeAccessCode)
                    .accessibilityIdentifier("clip.liveShare.accessCode.toggle")

                    if model.snapshot.accessCodeEnabled {
                        HStack(spacing: 8) {
                            Text(model.snapshot.accessCode ?? String(localized: "Creating…"))
                                .font(.body.monospaced().weight(.medium))
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                model.copyAccessCode()
                            } label: {
                                Label(
                                    model.copiedItem == .accessCode
                                        ? String(localized: "Copied")
                                        : String(localized: "Copy"),
                                    systemImage: model.copiedItem == .accessCode
                                        ? "checkmark"
                                        : "doc.on.doc"
                                )
                            }
                            .controlSize(.small)
                            .disabled(model.snapshot.accessCode?.isEmpty != false)
                            .accessibilityIdentifier("clip.liveShare.accessCode.copy")
                            Button {
                                model.replaceAccessCode()
                            } label: {
                                Label(String(localized: "Replace"), systemImage: "arrow.clockwise")
                            }
                            .controlSize(.small)
                            .disabled(!model.snapshot.canChangeAccessCode)
                            .accessibilityIdentifier("clip.liveShare.accessCode.replace")
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))

                        Text("Verified by this Mac; the server never receives the code.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = model.snapshot.accessCodeError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for the share link…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var preparationSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader(String(localized: "Before You Share"), systemImage: "checklist")
            Label(
                String(localized: "Nothing is being captured yet."),
                systemImage: "eye.slash"
            )
            .font(.subheadline)
            Text(
                "Set an optional guest access code, copy the complete invite, then start when you are ready. Friends who are currently sharing will also appear here."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if showsInviteEntry {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Paste a complete Clip invite", text: $inviteEntry)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("clip.liveShare.joinInvite.field")
                    HStack {
                        Button("Cancel") {
                            inviteEntry = ""
                            showsInviteEntry = false
                        }
                        Spacer()
                        Button("Join") {
                            model.joinInvite(inviteEntry)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(inviteEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("clip.liveShare.joinInvite.submit")
                    }
                }
                .padding(.top, 3)
            } else {
                Button {
                    showsInviteEntry = true
                } label: {
                    Label(String(localized: "Join an Invite"), systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("clip.liveShare.joinInvite")
            }

            Divider()
            HStack {
                sectionHeader(String(localized: "Friends"), systemImage: "person.2")
                Spacer()
                if !model.snapshot.friends.isEmpty {
                    Text("\(model.snapshot.friends.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if model.snapshot.friends.isEmpty {
                Text("Friends you add after a native session will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshot.friends) { friend in
                    Button {
                        model.joinFriend(friend.id)
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(friend.presence == .live ? .green : .secondary.opacity(0.45))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(friend.displayName)
                                    .font(.subheadline.weight(.medium))
                                HStack(spacing: 5) {
                                    Text(friend.deviceName)
                                    if friend.isFinishingSetup {
                                        Text("Finishing setup")
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(friend.presence.title)
                                .font(.caption)
                                .foregroundStyle(friend.presence == .live ? .green : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!friend.presence.canJoin)
                    .accessibilityIdentifier("clip.liveShare.friend.\(friend.id)")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityIdentifier("clip.liveShare.preparation")
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionHeader(String(localized: "Sources"), systemImage: "macwindow.on.rectangle")
                Spacer()
                Text("\(min(4, model.snapshot.sources.count)) of 4 windows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 0) {
                Toggle(
                    isOn: Binding(
                        get: { model.snapshot.fullscreen.isOn },
                        set: { model.setFullscreenEnabled($0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 1) {
                        Label(String(localized: "Fullscreen"), systemImage: "rectangle.inset.filled")
                            .font(.subheadline.weight(.medium))
                        Text(model.snapshot.fullscreen.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!model.snapshot.fullscreen.isEnabled)
                .padding(9)
                .accessibilityIdentifier("clip.liveShare.fullscreen")

                if let detail = model.snapshot.fullscreen.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.bottom, 8)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))

            if !model.snapshot.sources.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.snapshot.sources.enumerated()), id: \.element.id) { index, source in
                        LiveShareSourceRow(
                            source: source,
                            isReadOnly: model.snapshot.settings.autoShareFocusedWindows,
                            stop: { model.stopSource(source.id) }
                        )
                        if index < model.snapshot.sources.count - 1 {
                            Divider().padding(.leading, 37)
                        }
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            }

            Menu {
                ForEach(
                    Array(Set(model.snapshot.availableWindows.map(\.applicationName))).sorted(),
                    id: \.self
                ) { applicationName in
                    Section(applicationName) {
                        ForEach(model.snapshot.availableWindows.filter {
                            $0.applicationName == applicationName
                        }) { window in
                            Button {
                                model.shareWindow(window.id)
                            } label: {
                                Text(window.windowTitle)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Label(
                        String(localized: "Add Window"),
                        systemImage: "plus.rectangle.on.rectangle"
                    )
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .disabled(!model.snapshot.canAddWindow)
            .accessibilityIdentifier("clip.liveShare.addWindow")

            Button {
                model.shareFocusedWindow()
            } label: {
                HStack {
                    Label(String(localized: "Share Focused Window"), systemImage: "plus.rectangle.on.rectangle")
                    Spacer()
                    if let description = model.snapshot.focusedWindowDescription {
                        Text(description)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(
                !model.snapshot.canShareFocusedWindow
                    || model.snapshot.settings.autoShareFocusedWindows
            )
            .accessibilityIdentifier("clip.liveShare.shareFocusedWindow")
        }
    }

    private var streamSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "Stream Settings"), systemImage: "slider.horizontal.3")

            Toggle(
                isOn: Binding(
                    get: { model.snapshot.settings.systemAudioEnabled },
                    set: { model.setSystemAudioEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("System Audio")
                    Text("Shares app audio, or system audio in Fullscreen.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!model.snapshot.settings.canChangeSystemAudio)
            .accessibilityIdentifier("clip.liveShare.systemAudio")

            LiveShareSettingRow(title: String(localized: "Quality")) {
                Picker(
                    String(localized: "Quality"),
                    selection: Binding(
                        get: { model.snapshot.settings.quality },
                        set: { model.setQuality($0) }
                    )
                ) {
                    ForEach(LiveShareQualityPreset.allCases) { quality in
                        Text("\(quality.title) · \(quality.bitrateText)")
                            .tag(quality)
                    }
                }
                .labelsHidden()
                .frame(width: 165)
                .disabled(!model.snapshot.settings.canChangeQuality)
                .accessibilityIdentifier("clip.liveShare.quality")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Frame Rate")
                    .font(.subheadline)
                Picker(
                    String(localized: "Frame Rate"),
                    selection: Binding(
                        get: { model.snapshot.settings.frameRate },
                        set: { model.setFrameRate($0) }
                    )
                ) {
                    ForEach(LiveShareFrameRate.allCases) { frameRate in
                        Text("\(frameRate.rawValue)")
                            .tag(frameRate)
                            .disabled(!model.snapshot.settings.availableFrameRates.contains(frameRate))
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(!model.snapshot.settings.canChangeFrameRate)
                .accessibilityIdentifier("clip.liveShare.frameRate")
            }

            LiveShareSettingRow(title: String(localized: "Codec")) {
                VStack(alignment: .trailing, spacing: 1) {
                    Picker(
                        String(localized: "Codec"),
                        selection: Binding(
                            get: { model.snapshot.settings.codec.codec },
                            set: { model.setCodec($0) }
                        )
                    ) {
                        ForEach(LiveShareVideoCodec.allCases) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 165, alignment: .trailing)
                    .disabled(!model.snapshot.settings.canChangeCodec)
                    .accessibilityIdentifier("clip.liveShare.codec")

                    Text(model.snapshot.settings.codec.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(
                String(localized: "Prioritize Focused Window"),
                isOn: Binding(
                    get: { model.snapshot.settings.prioritizeFocusedWindow },
                    set: { model.setPrioritizeFocusedWindow($0) }
                )
            )
            .disabled(!model.snapshot.settings.canChangePrioritizeFocusedWindow)
            .accessibilityIdentifier("clip.liveShare.prioritizeFocusedWindow")

            VStack(alignment: .leading, spacing: 5) {
                Text("Mode")
                    .font(.subheadline)
                Picker(
                    String(localized: "Mode"),
                    selection: Binding(
                        get: { model.snapshot.settings.mode },
                        set: { model.setMode($0) }
                    )
                ) {
                    ForEach(LiveShareEncodingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(!model.snapshot.settings.canChangeMode)
                .accessibilityIdentifier("clip.liveShare.mode")
            }

            Toggle(
                isOn: Binding(
                    get: { model.snapshot.settings.autoShareFocusedWindows },
                    set: { model.setAutoShareEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-share Focused Windows")
                    Text("Shares only the currently focused window.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(
                !model.snapshot.settings.canChangeAutoShare
                    || model.snapshot.fullscreen.isOn
            )
            .accessibilityIdentifier("clip.liveShare.autoShare")
        }
    }

    private var viewersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader(String(localized: "Viewers"), systemImage: "person.2")
                Spacer()
                Text("\(model.snapshot.connectedViewerCount) connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.snapshot.viewers.isEmpty {
                Text("No viewers connected yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshot.viewers) { viewer in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(viewer.connection.isConnected ? .green : .secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(viewer.id)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(viewer.connection.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let duration = viewer.connectedDuration {
                            Text(LiveShareDurationFormatting.string(duration))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var statisticsSection: some View {
        DisclosureGroup(isExpanded: $statisticsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Uptime \(LiveShareDurationFormatting.string(model.snapshot.statistics.uptime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.snapshot.statistics.h264SubmissionBackpressureDrops > 0 {
                    Text(verbatim:
                        "H.264 freshness drops: "
                        + String(model.snapshot.statistics.h264SubmissionBackpressureDrops)
                        + " (latest interval)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if model.snapshot.statistics.streams.isEmpty {
                    Text("Statistics appear after a source starts sending.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot.statistics.streams) { stream in
                        LiveShareStreamStatisticsRow(stream: stream)
                    }
                }
            }
            .padding(.top, 7)
        } label: {
            Label(String(localized: "Statistics"), systemImage: "chart.xyaxis.line")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityIdentifier("clip.liveShare.statistics")
    }

    @ViewBuilder
    private var sessionActions: some View {
        if model.snapshot.phase.isFailure {
            HStack(spacing: 8) {
                Button {
                    model.retry()
                } label: {
                    Label(String(localized: "Retry"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("clip.liveShare.retry")

                Button(role: .destructive) {
                    model.stopSession()
                } label: {
                    Text("Stop Session")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.snapshot.canStopSession)
                .accessibilityIdentifier("clip.liveShare.stopSession")
            }
        } else if model.snapshot.sessionStage == .preparing {
            HStack(spacing: 8) {
                Button(role: .cancel) {
                    model.stopSession()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    model.startSharing()
                } label: {
                    Label(String(localized: "Start Sharing"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.snapshot.canStartSharing)
                .accessibilityIdentifier("clip.liveShare.start")
            }
        } else {
            HStack(spacing: 8) {
                if model.snapshot.hasActiveMedia {
                    Button {
                        model.stopAllMedia()
                    } label: {
                        Label(String(localized: "Stop All"), systemImage: "stop.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("clip.liveShare.stopAll")
                }

                Button(role: .destructive) {
                    model.stopSession()
                } label: {
                    Label(String(localized: "Stop Screen Share"), systemImage: "xmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!model.snapshot.canStopSession)
                .accessibilityIdentifier("clip.liveShare.stopSession")
            }
        }
    }

    private var headerTint: Color {
        if model.snapshot.phase.isFailure { return .orange }
        return model.snapshot.phase.showsLiveIndicator ? .red : .blue
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
    }
}

private struct LiveShareSettingRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.subheadline)
            Spacer()
            content
        }
    }
}

private struct LiveShareSourceRow: View {
    let source: LiveShareSourceViewSnapshot
    let isReadOnly: Bool
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            LiveShareApplicationIcon(path: source.applicationPath)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(source.applicationName)
                        .font(.subheadline.weight(.medium))
                    if source.isFocused {
                        Image(systemName: "scope")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .accessibilityLabel(String(localized: "Focused"))
                    }
                }
                Text(source.windowTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(source.status.title)
                    .font(.caption2)
                    .foregroundStyle(source.status == .failed ? .red : .secondary)
            }

            Spacer(minLength: 6)

            if !isReadOnly {
                Button(role: .destructive, action: stop) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!source.canStop || source.status == .stopping)
                .help(String(localized: "Stop sharing this window"))
                .accessibilityLabel(String(localized: "Stop sharing \(source.windowTitle)"))
            }
        }
        .padding(9)
        .accessibilityElement(children: .contain)
    }
}

private struct LiveShareApplicationIcon: View {
    let path: String?

    var body: some View {
        Group {
            if let path, !path.isEmpty {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
            } else {
                Image(systemName: "macwindow")
                    .resizable()
                    .scaledToFit()
                    .padding(3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

private struct LiveShareStreamStatisticsRow: View {
    let stream: LiveShareStreamStatisticsViewSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(stream.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if stream.isFocused {
                    Text("Focused")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Spacer()
            }
            Text(
                "\(stream.width) × \(stream.height) · "
                    + "\(stream.deliveredFramesPerSecond.formatted(.number.precision(.fractionLength(0...1)))) FPS"
                    + (stream.codec.map { " · \($0)" } ?? "")
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            Text(verbatim: bitrateSummary)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            if let latencySummary {
                Text(verbatim: latencySummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if stream.captureBackpressureDrops > 0 || stream.encoderDroppedFrames > 0 {
                Text(verbatim: dropSummary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if let limitationSummary {
                Text(verbatim: limitationSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }

    private var bitrateSummary: String {
        var values = [
            "\(LiveShareFormatting.bitrate(stream.bitsPerSecond)) actual",
        ]
        if let target = stream.targetBitsPerSecond {
            values.append("\(LiveShareFormatting.bitrate(target)) target")
        }
        if stream.configuredBitrateCeiling > 0 {
            values.append(
                "\(LiveShareFormatting.bitrate(stream.configuredBitrateCeiling)) ceiling"
            )
        }
        values.append("\(LiveShareFormatting.bytes(stream.bytesSent)) sent")
        return values.joined(separator: " · ")
    }

    private var latencySummary: String? {
        var values: [String] = []
        if let milliseconds = stream.averageEncodeTimeMilliseconds {
            values.append("Encode \(LiveShareFormatting.milliseconds(milliseconds))")
        }
        if let milliseconds = stream.averagePacketSendDelayMilliseconds {
            values.append("Send queue \(LiveShareFormatting.milliseconds(milliseconds))")
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var dropSummary: String {
        var values: [String] = []
        if stream.captureBackpressureDrops > 0 {
            values.append("\(stream.captureBackpressureDrops) capture drops")
        }
        if stream.encoderDroppedFrames > 0 {
            values.append("\(stream.encoderDroppedFrames) WebRTC drops")
        }
        return values.joined(separator: " · ")
    }

    private var limitationSummary: String? {
        let reasons = stream.qualityLimitationReasons.filter {
            !$0.isEmpty && $0.caseInsensitiveCompare("none") != .orderedSame
        }
        guard !reasons.isEmpty else { return nil }
        return "WebRTC limited by " + reasons.joined(separator: ", ")
    }
}

private enum LiveShareFormatting {
    static func bitrate(_ bitsPerSecond: Int) -> String {
        guard bitsPerSecond >= 1_000_000 else {
            return "\(max(0, bitsPerSecond) / 1_000) kbps"
        }
        let megabits = Double(bitsPerSecond) / 1_000_000
        return "\(megabits.formatted(.number.precision(.fractionLength(0...1)))) Mbps"
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    static func milliseconds(_ value: Double) -> String {
        let digits = value < 10 ? 1 : 0
        return value.formatted(
            .number.precision(.fractionLength(digits))
        ) + " ms"
    }
}
