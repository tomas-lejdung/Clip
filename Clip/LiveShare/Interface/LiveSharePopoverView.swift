import AppKit
import SwiftUI

private enum LiveSharePopoverRoute: Equatable {
    case overview
    case streamSettings
    case viewers
    case statistics
    case advancedCodec(LiveShareVideoCodec)
}

@MainActor
struct LiveSharePopoverView: View {
    static let contentWidth: CGFloat = 380
    static let contentSize = CGSize(width: contentWidth, height: 620)
    private static let streamSettingsControlWidth: CGFloat = 190

    @ObservedObject var model: LiveSharePresentationModel
    private let maximumHeight: CGFloat
    private let onContentHeightChange: (CGFloat) -> Void
    @State private var route: LiveSharePopoverRoute = .overview
    @State private var showsInviteEntry = false
    @State private var inviteEntry = ""

    init(
        model: LiveSharePresentationModel,
        initiallyExpandsStatistics: Bool = false,
        maximumHeight: CGFloat = 10_000,
        onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.model = model
        self.maximumHeight = maximumHeight
        self.onContentHeightChange = onContentHeightChange
        _route = State(
            initialValue:
                initiallyExpandsStatistics
                    && model.snapshot.sessionStage == .active
                ? .statistics
                : .overview
        )
    }

    var body: some View {
        popoverPane
            .accessibilityIdentifier("clip.liveShare.popover")
            .onAppear {
                normalizeRoute()
            }
            .onChange(of: model.snapshot.sessionStage) { _, _ in
                normalizeRoute()
            }
            .onChange(of: model.snapshot.phase) { _, _ in
                normalizeRoute()
            }
            .onChange(of: model.snapshot.settings.canChangeMode) { _, _ in
                normalizeRoute()
            }
    }

    private var popoverPane: some View {
        // Keep the three route slots type-erased. Swift 6.3 currently crashes
        // its type checker when this large routed view resolves the shell's
        // overloaded custom-icon and symbol-icon generic initializers directly.
        ClipPopoverPane<AnyView, AnyView, AnyView>(
            width: Self.contentWidth,
            maximumHeight: maximumHeight,
            onContentHeightChange: onContentHeightChange,
            icon: routeIcon,
            iconTint: headerTint,
            title: routeTitle,
            subtitle: model.snapshot.phase.statusText,
            subtitleAccessibilityIdentifier: "clip.liveShare.status",
            subtitleTint: model.snapshot.phase.isFailure ? .red : .secondary,
            backTitle: route == .overview ? nil : String(localized: "Live Share"),
            onBack: route == .overview ? nil : { navigateBack() },
            accessibilityIdentifier: paneAccessibilityIdentifier
        ) {
            AnyView(headerTrailing)
        } content: {
            AnyView(paneContent)
        } footer: {
            AnyView(sessionActions)
        }
    }

    private var paneContent: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            if let warning = model.snapshot.capturePressureWarning {
                capturePressureBanner(warning)
            }
            routeContent
        }
    }

    private var paneAccessibilityIdentifier: String {
        if case .advancedCodec = route {
            return "clip.liveShare.codec.advanced"
        }
        return "clip.liveShare.popover"
    }

    @ViewBuilder
    private var routeContent: some View {
        switch route {
        case .overview:
            VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
                shareLinkSection
                if model.snapshot.sessionStage == .active {
                    sourcesSection
                    quickAudioSection
                    navigationSection
                } else {
                    preparationSection
                }
            }
        case .streamSettings:
            streamSettingsSection
        case .viewers:
            viewersSection
        case .statistics:
            statisticsSection
        case let .advancedCodec(codec):
            inlineAdvancedSettings(for: codec)
        }
    }

    private func inlineAdvancedSettings(for codec: LiveShareVideoCodec) -> some View {
        LiveShareAdvancedCodecSettingsEditor(
            codec: codec,
            current: model.snapshot.settings.advancedVideoSettings.settings(for: codec),
            presentationStyle: .inline,
            onApply: { advanced in
                model.setAdvancedVideoSettings(advanced, for: codec)
                route = .streamSettings
            },
            onCancel: {
                route = .streamSettings
            }
        )
        .id(codec)
    }

    @ViewBuilder
    private var headerTrailing: some View {
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

    private var routeTitle: String {
        switch route {
        case .overview:
            String(localized: "Live Share")
        case .streamSettings:
            String(localized: "Stream Settings")
        case .viewers:
            String(localized: "Viewers")
        case .statistics:
            String(localized: "Statistics")
        case let .advancedCodec(codec):
            String(localized: "Advanced \(codec.displayName)")
        }
    }

    private var routeIcon: String {
        switch route {
        case .overview:
            "rectangle.inset.filled.and.person.filled"
        case .streamSettings, .advancedCodec:
            "slider.horizontal.3"
        case .viewers:
            "person.2"
        case .statistics:
            "chart.xyaxis.line"
        }
    }

    private func navigateBack() {
        switch route {
        case .advancedCodec:
            route = .streamSettings
        default:
            route = .overview
        }
    }

    private func normalizeRoute() {
        if model.snapshot.phase.isFailure
            || model.snapshot.phase == .stopping
            || model.snapshot.sessionStage != .active {
            route = .overview
            return
        }

        if case .advancedCodec = route,
           !model.snapshot.settings.canChangeMode {
            route = .streamSettings
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
        VStack(alignment: .leading, spacing: ClipPopoverDesign.sectionSpacing) {
            ClipPopoverSection(String(localized: "Invite")) {
                if let room = model.snapshot.room {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Text(room.roomCode)
                                .font(.subheadline.weight(.semibold).monospaced())
                                .lineLimit(1)
                                .textSelection(.enabled)

                            Spacer(minLength: 8)

                            ClipPopoverButton(
                                model.copiedItem == .link
                                    ? String(localized: "Copied")
                                    : String(localized: "Copy Invite"),
                                systemImage: model.copiedItem == .link
                                    ? "checkmark"
                                    : "doc.on.doc",
                                prominence: .secondary,
                                size: .standard,
                                isEnabled: room.isAvailable,
                                accessibilityIdentifier: "clip.liveShare.copyLink",
                                action: model.copyLink
                            )
                        }
                        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                        .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)

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
                            .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                            .padding(.bottom, 4)
                            .accessibilityIdentifier("clip.liveShare.signalingUnavailable")
                        }

                        ClipPopoverRowDivider()
                        ClipPopoverToggleRow(
                            String(localized: "Access Word"),
                            systemImage: "lock",
                            isEnabled: model.snapshot.canChangeAccessCode,
                            accessibilityIdentifier: "clip.liveShare.accessCode.toggle",
                            isOn: Binding(
                                get: { model.snapshot.accessCodeEnabled },
                                set: { model.setAccessCodeEnabled($0) }
                            )
                        )

                        if model.snapshot.accessCodeEnabled {
                            HStack(spacing: 8) {
                                Text(model.snapshot.accessCode ?? String(localized: "Creating…"))
                                    .font(.body.monospaced().weight(.medium))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                Spacer()
                                ClipPopoverButton(
                                    model.copiedItem == .accessCode
                                        ? String(localized: "Copied")
                                        : String(localized: "Copy"),
                                    systemImage: model.copiedItem == .accessCode
                                        ? "checkmark"
                                        : "doc.on.doc",
                                    isEnabled: model.snapshot.accessCode?.isEmpty == false,
                                    accessibilityIdentifier: "clip.liveShare.accessCode.copy",
                                    action: model.copyAccessCode
                                )
                                ClipPopoverButton(
                                    String(localized: "Replace"),
                                    systemImage: "arrow.clockwise",
                                    isEnabled: model.snapshot.canChangeAccessCode,
                                    accessibilityIdentifier: "clip.liveShare.accessCode.replace",
                                    action: model.replaceAccessCode
                                )
                            }
                            .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                            .padding(.bottom, ClipPopoverDesign.rowVerticalPadding)

                            Text("A separate one-word confirmation verified by this Mac; the server never receives it.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                                .padding(.bottom, 4)
                        }
                        if let error = model.snapshot.accessCodeError {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                                .padding(.bottom, 4)
                        }
                    }
                } else if model.snapshot.phase.isFailure {
                    Label(
                        model.snapshot.phase.statusText,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(ClipPopoverDesign.rowHorizontalPadding)
                } else if model.snapshot.phase == .inactive {
                    Label("No share room is active.", systemImage: "link.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(ClipPopoverDesign.rowHorizontalPadding)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for the share link…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(ClipPopoverDesign.rowHorizontalPadding)
                }
            }

            if model.snapshot.sessionStage == .preparing,
               model.snapshot.room != nil {
                ClipPopoverButton(
                    String(localized: "New Room"),
                    systemImage: "arrow.clockwise",
                    prominence: .secondary,
                    size: .standard,
                    isEnabled: model.snapshot.canReplaceRoom,
                    accessibilityIdentifier: "clip.liveShare.newRoom",
                    action: model.replaceRoom
                )
            }
        }
    }

    private var preparationSection: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            ClipPopoverSection(
                String(localized: "Join a Share")
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste an invite from another Clip user to view their share.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if showsInviteEntry {
                        TextField("Paste a complete Clip invite", text: $inviteEntry)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("clip.liveShare.joinInvite.field")
                        HStack {
                            ClipPopoverButton(
                                String(localized: "Cancel"),
                                prominence: .secondary,
                                size: .standard
                            ) {
                                inviteEntry = ""
                                showsInviteEntry = false
                            }
                            Spacer()
                            ClipPopoverButton(
                                String(localized: "Join"),
                                systemImage: "rectangle.portrait.and.arrow.right",
                                prominence: .primary,
                                size: .standard,
                                isEnabled: !inviteEntry.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty,
                                accessibilityIdentifier: "clip.liveShare.joinInvite.submit"
                            ) {
                                model.joinInvite(inviteEntry)
                            }
                        }
                    } else {
                        ClipPopoverButton(
                            String(localized: "Join an Invite"),
                            systemImage: "rectangle.portrait.and.arrow.right",
                            prominence: .secondary,
                            size: .standard,
                            fillsWidth: true,
                            accessibilityIdentifier: "clip.liveShare.joinInvite"
                        ) {
                            showsInviteEntry = true
                        }
                    }
                }
                .padding(ClipPopoverDesign.rowHorizontalPadding)
            }

            ClipPopoverSection(
                model.snapshot.friends.isEmpty
                    ? String(localized: "Friends")
                    : String(localized: "Friends · \(model.snapshot.friends.count)")
            ) {
                if model.snapshot.friends.isEmpty {
                    Text("Friends you add will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(ClipPopoverDesign.rowHorizontalPadding)
                } else {
                    VStack(spacing: 0) {
                        ForEach(
                            Array(model.snapshot.friends.enumerated()),
                            id: \.element.id
                        ) { index, friend in
                            Button {
                                model.joinFriend(friend.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(
                                            friend.presence == .live
                                                ? .green
                                                : .secondary.opacity(0.45)
                                        )
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
                                        .foregroundStyle(
                                            friend.presence == .live
                                                ? .green
                                                : .secondary
                                        )
                                }
                                .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                                .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!friend.presence.canJoin)
                            .modifier(
                                ClipPopoverHoverEffect(
                                    isInteractive: friend.presence.canJoin
                                )
                            )
                            .accessibilityIdentifier("clip.liveShare.friend.\(friend.id)")

                            if index < model.snapshot.friends.count - 1 {
                                ClipPopoverRowDivider(leadingInset: 28)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("clip.liveShare.preparation")
    }

    private var sourcesSection: some View {
        ClipPopoverSection(
            String(
                localized: "Sources · \(min(4, model.snapshot.sources.count)) of 4 windows"
            )
        ) {
            VStack(spacing: 0) {
                ClipPopoverToggleRow(
                    String(localized: "Fullscreen"),
                    subtitle: fullscreenSubtitle,
                    systemImage: "rectangle.inset.filled",
                    isEnabled: model.snapshot.fullscreen.isEnabled,
                    accessibilityIdentifier: "clip.liveShare.fullscreen",
                    isOn: Binding(
                        get: { model.snapshot.fullscreen.isOn },
                        set: { model.setFullscreenEnabled($0) }
                    )
                )

                if !model.snapshot.sources.isEmpty {
                    ClipPopoverRowDivider()
                    ForEach(
                        Array(model.snapshot.sources.enumerated()),
                        id: \.element.id
                    ) { index, source in
                        LiveShareSourceRow(
                            source: source,
                            isReadOnly: model.snapshot.settings.autoShareFocusedWindows,
                            stop: { model.stopSource(source.id) }
                        )
                        if index < model.snapshot.sources.count - 1 {
                            ClipPopoverRowDivider()
                        }
                    }
                }

                ClipPopoverRowDivider()

                HStack(spacing: 8) {
                    Menu {
                        ForEach(
                            Array(
                                Set(
                                    model.snapshot.availableWindows.map(
                                        \.applicationName
                                    )
                                )
                            ).sorted(),
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
                        Label(
                            String(localized: "Add Window"),
                            systemImage: "plus.rectangle.on.rectangle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.visible)
                    .buttonStyle(
                        ClipPopoverButtonStyle(
                            prominence: .secondary,
                            size: .standard,
                            fillsWidth: true
                        )
                    )
                    .disabled(!model.snapshot.canAddWindow)
                    .accessibilityIdentifier("clip.liveShare.addWindow")

                    ClipPopoverButton(
                        String(localized: "Share Focused"),
                        systemImage: "scope",
                        prominence: .secondary,
                        size: .standard,
                        fillsWidth: true,
                        isEnabled: model.snapshot.canShareFocusedWindow
                            && !model.snapshot.settings.autoShareFocusedWindows,
                        accessibilityIdentifier: "clip.liveShare.shareFocusedWindow",
                        action: model.shareFocusedWindow
                    )
                }
                .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)

                if let description = model.snapshot.focusedWindowDescription {
                    Text("Focused: \(description)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                        .padding(.bottom, ClipPopoverDesign.rowVerticalPadding)
                }
            }
        }
    }

    private var fullscreenSubtitle: String {
        if let detail = model.snapshot.fullscreen.detail {
            return "\(model.snapshot.fullscreen.displayName) · \(detail)"
        }
        return model.snapshot.fullscreen.displayName
    }

    private var quickAudioSection: some View {
        ClipPopoverSection {
            VStack(spacing: 0) {
                ClipPopoverToggleRow(
                    String(localized: "System Audio"),
                    subtitle: String(
                        localized: "Shares app audio, or system audio in Fullscreen."
                    ),
                    systemImage: "speaker.wave.2",
                    isEnabled: model.snapshot.settings.canChangeSystemAudio,
                    accessibilityIdentifier: "clip.liveShare.systemAudio",
                    isOn: Binding(
                        get: { model.snapshot.settings.systemAudioEnabled },
                        set: { model.setSystemAudioEnabled($0) }
                    )
                )

                if model.snapshot.fullscreen.isOn,
                   model.snapshot.settings.systemAudioEnabled {
                    ClipPopoverRowDivider()
                    audioExclusionMenu
                }
            }
        }
    }

    private var navigationSection: some View {
        ClipPopoverSection {
            VStack(spacing: 0) {
                ClipPopoverNavigationRow(
                    String(localized: "Stream Settings"),
                    subtitle: streamSettingsSummary,
                    systemImage: "slider.horizontal.3",
                    accessibilityIdentifier: "clip.liveShare.navigation.streamSettings"
                ) {
                    route = .streamSettings
                }

                ClipPopoverRowDivider()

                ClipPopoverNavigationRow(
                    String(localized: "Viewers"),
                    subtitle: String(
                        localized: "\(model.snapshot.connectedViewerCount) connected"
                    ),
                    systemImage: "person.2",
                    accessibilityIdentifier: "clip.liveShare.navigation.viewers"
                ) {
                    route = .viewers
                }

                ClipPopoverRowDivider()

                ClipPopoverNavigationRow(
                    String(localized: "Statistics"),
                    subtitle: statisticsSummary,
                    systemImage: "chart.xyaxis.line",
                    accessibilityIdentifier: "clip.liveShare.navigation.statistics"
                ) {
                    route = .statistics
                }
            }
        }
    }

    private var streamSettingsSummary: String {
        let settings = model.snapshot.settings
        return [
            settings.codec.name,
            settings.mode.title,
            settings.frameRate.title,
            settings.quality.bitrateText,
            settings.colorMode.title,
        ].joined(separator: " · ")
    }

    private var statisticsSummary: String {
        let streamCount = model.snapshot.statistics.streams.count
        let streamLabel = streamCount == 1
            ? String(localized: "1 stream")
            : String(localized: "\(streamCount) streams")
        return "\(streamLabel) · \(LiveShareDurationFormatting.string(model.snapshot.statistics.uptime))"
    }

    private var streamSettingsSection: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            ClipPopoverSection(String(localized: "Video")) {
                VStack(spacing: 0) {
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
                        .pickerStyle(.menu)
                        .frame(
                            width: Self.streamSettingsControlWidth,
                            alignment: .trailing
                        )
                        .disabled(!model.snapshot.settings.canChangeQuality)
                        .accessibilityIdentifier("clip.liveShare.quality")
                    }

                    ClipPopoverRowDivider(leadingInset: 12)

                    LiveShareSettingRow(title: String(localized: "Frame Rate")) {
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
                                    .disabled(
                                        !model.snapshot.settings.availableFrameRates
                                            .contains(frameRate)
                                    )
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(
                            width: Self.streamSettingsControlWidth,
                            alignment: .trailing
                        )
                        .disabled(!model.snapshot.settings.canChangeFrameRate)
                        .accessibilityIdentifier("clip.liveShare.frameRate")
                    }

                    ClipPopoverRowDivider(leadingInset: 12)

                    LiveShareSettingRow(
                        title: String(localized: "Codec"),
                        detail: model.snapshot.settings.codec.detail
                    ) {
                        HStack(spacing: 6) {
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
                            .frame(width: 128, alignment: .trailing)
                            .disabled(!model.snapshot.settings.canChangeCodec)
                            .accessibilityIdentifier("clip.liveShare.codec")

                            Button {
                                route = .advancedCodec(
                                    model.snapshot.settings.codec.codec
                                )
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .accessibilityLabel(
                                        "Advanced \(model.snapshot.settings.codec.codec.displayName) Settings"
                                    )
                            }
                            .buttonStyle(.borderless)
                            .disabled(!model.snapshot.settings.canChangeMode)
                            .accessibilityIdentifier("clip.liveShare.codec.advanced")
                            .id(model.snapshot.settings.codec.codec)
                        }
                    }

                    ClipPopoverRowDivider(leadingInset: 12)

                    LiveShareSettingRow(
                        title: String(localized: "Color"),
                        detail: model.snapshot.settings.colorMode.detail(
                            for: model.snapshot.settings.codec.codec
                        )
                    ) {
                        Picker(
                            String(localized: "Color"),
                            selection: Binding(
                                get: { model.snapshot.settings.colorMode },
                                set: { model.setColorMode($0) }
                            )
                        ) {
                            ForEach(LiveShareColorMode.allCases) { colorMode in
                                Text(colorMode.title).tag(colorMode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(
                            width: Self.streamSettingsControlWidth,
                            alignment: .trailing
                        )
                        .disabled(!model.snapshot.settings.canChangeColorMode)
                        .accessibilityIdentifier("clip.liveShare.colorMode")
                    }

                    ClipPopoverRowDivider(leadingInset: 12)

                    LiveShareSettingRow(title: String(localized: "Mode")) {
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
                        .frame(
                            width: Self.streamSettingsControlWidth,
                            alignment: .trailing
                        )
                        .disabled(!model.snapshot.settings.canChangeMode)
                        .accessibilityIdentifier("clip.liveShare.mode")
                    }
                }
            }

            ClipPopoverSection(
                String(localized: "Behavior")
            ) {
                VStack(spacing: 0) {
                    ClipPopoverToggleRow(
                        String(localized: "Match Cursor to Frame Rate"),
                        subtitle: String(
                            localized: "20 Hz by default; follows 30 or 60 FPS when enabled."
                        ),
                        systemImage: "cursorarrow.motionlines",
                        isEnabled: model.snapshot.settings.canChangeCursorUpdateRate,
                        accessibilityIdentifier:
                            "clip.liveShare.cursorUpdatesMatchFrameRate",
                        isOn: Binding(
                            get: {
                                model.snapshot.settings
                                    .cursorUpdatesMatchFrameRate
                            },
                            set: { model.setCursorUpdatesMatchFrameRate($0) }
                        )
                    )

                    ClipPopoverRowDivider()

                    ClipPopoverToggleRow(
                        String(localized: "Prioritize Focused Window"),
                        systemImage: "scope",
                        isEnabled:
                            model.snapshot.settings
                                .canChangePrioritizeFocusedWindow,
                        accessibilityIdentifier:
                            "clip.liveShare.prioritizeFocusedWindow",
                        isOn: Binding(
                            get: {
                                model.snapshot.settings.prioritizeFocusedWindow
                            },
                            set: { model.setPrioritizeFocusedWindow($0) }
                        )
                    )

                    ClipPopoverRowDivider()

                    ClipPopoverToggleRow(
                        String(localized: "Auto-share Focused Windows"),
                        subtitle: String(
                            localized: "Shares only the currently focused window."
                        ),
                        systemImage: "rectangle.on.rectangle.badge.person.crop",
                        isEnabled:
                            model.snapshot.settings.canChangeAutoShare
                                && !model.snapshot.fullscreen.isOn,
                        accessibilityIdentifier: "clip.liveShare.autoShare",
                        isOn: Binding(
                            get: {
                                model.snapshot.settings.autoShareFocusedWindows
                            },
                            set: { model.setAutoShareEnabled($0) }
                        )
                    )
                }
            }
        }
    }

    private var audioExclusionMenu: some View {
        ClipPopoverMenuRow(
            String(localized: "Exclude App Audio"),
            value: model.snapshot.settings.audioExclusionSummary,
            isEnabled:
                model.snapshot.settings.canChangeAudioExclusions
                && (
                    !model.snapshot.settings.audioExclusionApplications.isEmpty
                        || !model.snapshot.settings.excludedAudioApplicationIDs.isEmpty
                ),
            accessibilityIdentifier: "clip.liveShare.audioExclusions"
        ) {
            if sortedAudioExclusionApplications.isEmpty {
                Text("No other apps are running")
            } else {
                Section("Exclude Audio") {
                    ForEach(sortedAudioExclusionApplications) { application in
                        Toggle(
                            application.name,
                            isOn: audioExclusionBinding(for: application.id)
                        )
                    }
                }
            }

            if !model.snapshot.settings.excludedAudioApplicationIDs.isEmpty {
                Divider()
                Button("Include Audio from All Apps") {
                    model.setExcludedAudioApplicationIDs([])
                }
            }
        }
        .help("Apps remain visible; only their audio is removed.")
    }

    private var sortedAudioExclusionApplications: [LiveShareAudioApplicationViewSnapshot] {
        model.snapshot.settings.audioExclusionApplications.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return nameOrder == .orderedAscending
        }
    }

    private func audioExclusionBinding(for applicationID: String) -> Binding<Bool> {
        Binding(
            get: {
                model.snapshot.settings.excludedAudioApplicationIDs.contains(applicationID)
            },
            set: { isExcluded in
                var excludedIDs = model.snapshot.settings.excludedAudioApplicationIDs
                if isExcluded {
                    excludedIDs.insert(applicationID)
                } else {
                    excludedIDs.remove(applicationID)
                }
                model.setExcludedAudioApplicationIDs(excludedIDs)
            }
        )
    }

    private var viewersSection: some View {
        ClipPopoverSection(
            String(
                localized: "Viewers · \(model.snapshot.connectedViewerCount) connected"
            )
        ) {
            if model.snapshot.viewers.isEmpty {
                Text("No viewers connected yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(ClipPopoverDesign.rowHorizontalPadding)
            } else {
                VStack(spacing: 0) {
                    ForEach(
                        Array(model.snapshot.viewers.enumerated()),
                        id: \.element.id
                    ) { index, viewer in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(
                                    viewer.connection.isConnected
                                        ? .green
                                        : .secondary.opacity(0.5)
                                )
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(viewer.displayName)
                                    .font(
                                        viewer.displayName == viewer.id
                                            ? .caption.monospaced()
                                            : .subheadline.weight(.medium)
                                    )
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(viewer.connection.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let duration = viewer.connectedDuration {
                                Text(LiveShareDurationFormatting.string(duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                        .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
                        .accessibilityElement(children: .combine)

                        if index < model.snapshot.viewers.count - 1 {
                            ClipPopoverRowDivider(leadingInset: 28)
                        }
                    }
                }
            }
        }
    }

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            ClipPopoverSection(
                String(localized: "Session")
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        "Uptime \(LiveShareDurationFormatting.string(model.snapshot.statistics.uptime))"
                    )
                    .font(.subheadline.monospacedDigit())

                    if model.snapshot.statistics.h264SubmissionBackpressureDrops > 0 {
                        Text(verbatim:
                            "H.264 freshness drops: "
                            + String(
                                model.snapshot.statistics
                                    .h264SubmissionBackpressureDrops
                            )
                            + " (latest interval)"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(ClipPopoverDesign.rowHorizontalPadding)
            }

            if model.snapshot.statistics.streams.isEmpty {
                ClipPopoverSection(
                    String(localized: "Streams")
                ) {
                    Text("Statistics appear after a source starts sending.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(ClipPopoverDesign.rowHorizontalPadding)
                }
            } else {
                ClipPopoverSection(
                    String(
                        localized: "Streams · \(model.snapshot.statistics.streams.count)"
                    )
                ) {
                    VStack(spacing: 0) {
                        ForEach(
                            Array(model.snapshot.statistics.streams.enumerated()),
                            id: \.element.id
                        ) { index, stream in
                        LiveShareStreamStatisticsRow(stream: stream)
                            if index < model.snapshot.statistics.streams.count - 1 {
                                ClipPopoverRowDivider(leadingInset: 12)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("clip.liveShare.statistics")
    }

    @ViewBuilder
    private var sessionActions: some View {
        if model.snapshot.phase.isFailure {
            HStack(spacing: 8) {
                ClipPopoverButton(
                    String(localized: "Retry"),
                    systemImage: "arrow.clockwise",
                    prominence: .primary,
                    size: .bottom,
                    fillsWidth: true,
                    accessibilityIdentifier: "clip.liveShare.retry",
                    action: model.retry
                )

                Button(role: .destructive) {
                    model.stopSession()
                } label: {
                    Text("Stop Session")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    ClipPopoverButtonStyle(
                        prominence: .destructive,
                        size: .bottom,
                        fillsWidth: true
                    )
                )
                .disabled(!model.snapshot.canStopSession)
                .accessibilityIdentifier("clip.liveShare.stopSession")
            }
        } else if model.snapshot.sessionStage == .preparing {
            HStack(spacing: 8) {
                Button(role: .cancel) {
                    model.stopSession()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(
                    ClipPopoverButtonStyle(
                        prominence: .secondary,
                        size: .bottom
                    )
                )

                ClipPopoverButton(
                    String(localized: "Start Sharing"),
                    systemImage: "play.fill",
                    prominence: .primary,
                    size: .bottom,
                    fillsWidth: true,
                    isEnabled: model.snapshot.canStartSharing,
                    accessibilityIdentifier: "clip.liveShare.start",
                    action: model.startSharing
                )
            }
        } else {
            HStack(spacing: 8) {
                if model.snapshot.hasActiveMedia {
                    ClipPopoverButton(
                        String(localized: "Stop All"),
                        systemImage: "stop.circle",
                        prominence: .secondary,
                        size: .bottom,
                        accessibilityIdentifier: "clip.liveShare.stopAll",
                        action: model.stopAllMedia
                    )
                }

                Button(role: .destructive) {
                    model.stopSession()
                } label: {
                    Label(String(localized: "Stop Screen Share"), systemImage: "xmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    ClipPopoverButtonStyle(
                        prominence: .destructive,
                        size: .bottom,
                        fillsWidth: true
                    )
                )
                .disabled(!model.snapshot.canStopSession)
                .accessibilityIdentifier("clip.liveShare.stopSession")
            }
        }
    }

    private var headerTint: Color {
        if model.snapshot.phase.isFailure { return .orange }
        return model.snapshot.phase.showsLiveIndicator ? .red : .blue
    }

}

/// Opens the reusable codec editor from a normal window such as Settings. The
/// transient menu-bar popover embeds the editor inline instead of nesting a
/// second popover.
struct LiveShareAdvancedCodecSettingsButton: View {
    let codec: LiveShareVideoCodec
    let current: LiveShareCodecAdvancedSettings
    var isEnabled = true
    let onApply: (LiveShareVideoCodec, LiveShareCodecAdvancedSettings) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Advanced…", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .accessibilityIdentifier("clip.liveShare.codec.advanced")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            LiveShareAdvancedCodecSettingsEditor(
                codec: codec,
                current: current,
                onApply: { advanced in
                    onApply(codec, advanced)
                    isPresented = false
                },
                onCancel: { isPresented = false }
            )
        }
    }
}

private enum LiveShareAdvancedCodecSettingsPresentationStyle {
    case popover
    case inline
}

private struct LiveShareAdvancedCodecSettingsEditor: View {
    let codec: LiveShareVideoCodec
    let current: LiveShareCodecAdvancedSettings
    let presentationStyle: LiveShareAdvancedCodecSettingsPresentationStyle
    let onApply: (LiveShareCodecAdvancedSettings) -> Void
    let onCancel: () -> Void

    @State private var draft: LiveShareCodecAdvancedSettings

    init(
        codec: LiveShareVideoCodec,
        current: LiveShareCodecAdvancedSettings,
        presentationStyle: LiveShareAdvancedCodecSettingsPresentationStyle = .popover,
        onApply: @escaping (LiveShareCodecAdvancedSettings) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.codec = codec
        self.current = current
        self.presentationStyle = presentationStyle
        self.onApply = onApply
        self.onCancel = onCancel
        _draft = State(initialValue: current.normalized(for: codec))
    }

    @ViewBuilder
    var body: some View {
        switch presentationStyle {
        case .inline:
            inlineBody
        case .popover:
            popoverBody
        }
    }

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            ClipPopoverSection(
                String(localized: "Encoder Controls")
            ) {
                settingsControls
                    .padding(ClipPopoverDesign.rowHorizontalPadding)
            }

            ClipPopoverSection {
                VStack(alignment: .leading, spacing: 10) {
                    explanation
                    editorActions
                }
                .padding(ClipPopoverDesign.rowHorizontalPadding)
            }
        }
        .accessibilityIdentifier("clip.liveShare.codec.advanced.editor")
        .onChange(of: current) { _, updated in
            draft = updated.normalized(for: codec)
        }
    }

    private var popoverBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Advanced \(codec.displayName)")
                        .font(.headline)
                    Text("Applied changes affect the current stream immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    settingsControls
                    explanation
                }
                .padding(14)
            }

            Divider()

            editorActions
            .padding(12)
            .background(.bar)
        }
        .frame(width: 370, height: codec == .h264 ? 565 : 425)
        .accessibilityIdentifier("clip.liveShare.codec.advanced.editor")
        .onChange(of: current) { _, updated in
            draft = updated.normalized(for: codec)
        }
    }

    private var settingsControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            optionalMinimumBitrate
            degradationPreference
            temporalLayers
            resolutionScale
            if codec == .h264 {
                optionalMaximumQuantizer
                h264Quality
                h264KeyFrameInterval
            }
        }
    }

    private var explanation: some View {
        Text(codec == .h264
             ? "Auto uses Clip and WebRTC defaults. Lower maximum QP preserves more detail but can increase frame drops or latency when bandwidth is constrained."
             : "Auto uses WebRTC's codec defaults. Sender controls still apply without replacing the built-in encoder.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var editorActions: some View {
        HStack {
            Button("Reset") {
                draft = .default
            }
            .buttonStyle(
                ClipPopoverButtonStyle(
                    prominence: .secondary,
                    size: .standard
                )
            )
            .disabled(draft == .default)
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(
                    ClipPopoverButtonStyle(
                        prominence: .secondary,
                        size: .standard
                    )
                )
                .accessibilityIdentifier("clip.liveShare.codec.advanced.cancel")
            Button("Apply") {
                onApply(draft.normalized(for: codec))
            }
            .buttonStyle(
                ClipPopoverButtonStyle(
                    prominence: .primary,
                    size: .standard
                )
            )
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("clip.liveShare.codec.advanced.apply")
        }
    }

    private var optionalMaximumQuantizer: some View {
        advancedControl("Maximum QP") {
            HStack {
                Toggle(
                    "Custom",
                    isOn: optionalToggle(
                        get: { draft.maximumQuantizer },
                        set: { draft.maximumQuantizer = $0 },
                        defaultValue: suggestedMaximumQuantizer
                    )
                )
                .toggleStyle(.switch)
                Spacer()
                if draft.maximumQuantizer != nil {
                    Stepper(
                        value: optionalInt(
                            get: { draft.maximumQuantizer },
                            set: { draft.maximumQuantizer = $0 },
                            defaultValue: suggestedMaximumQuantizer
                        ),
                        in: LiveShareCodecAdvancedSettings.h264MaximumQuantizerRange
                    ) {
                        Text("\(draft.maximumQuantizer ?? suggestedMaximumQuantizer)")
                            .monospacedDigit()
                    }
                } else {
                    Text("Auto").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var optionalMinimumBitrate: some View {
        advancedControl("Requested Bitrate Floor") {
            HStack {
                Toggle(
                    "Custom",
                    isOn: optionalToggle(
                        get: { draft.minimumBitratePercent },
                        set: { draft.minimumBitratePercent = $0 },
                        defaultValue: 25
                    )
                )
                .toggleStyle(.switch)
                Spacer()
                if draft.minimumBitratePercent != nil {
                    Stepper(
                        value: optionalInt(
                            get: { draft.minimumBitratePercent },
                            set: { draft.minimumBitratePercent = $0 },
                            defaultValue: 25
                        ),
                        in: LiveShareCodecAdvancedSettings.minimumBitratePercentRange,
                        step: 5
                    ) {
                        Text("\(draft.minimumBitratePercent ?? 25)%")
                            .monospacedDigit()
                    }
                } else {
                    Text("Auto").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var degradationPreference: some View {
        advancedControl("Congestion Behavior") {
            Picker("Congestion Behavior", selection: $draft.degradationPreference) {
                ForEach(LiveShareDegradationPreference.allCases) { preference in
                    Text(preference.advancedTitle).tag(preference)
                }
            }
            .labelsHidden()
        }
    }

    private var temporalLayers: some View {
        advancedControl("Temporal Layers") {
            Picker(
                "Temporal Layers",
                selection: Binding(
                    get: { draft.temporalLayerCount },
                    set: { draft.temporalLayerCount = $0 }
                )
            ) {
                Text("Auto").tag(nil as Int?)
                ForEach(LiveShareCodecAdvancedSettings.temporalLayerCountRange, id: \.self) {
                    Text("L1T\($0)").tag(Optional($0))
                }
            }
            .labelsHidden()
        }
    }

    private var resolutionScale: some View {
        advancedControl("Resolution Scale") {
            Picker(
                "Resolution Scale",
                selection: Binding(
                    get: { draft.scaleResolutionDownBy },
                    set: { draft.scaleResolutionDownBy = $0 }
                )
            ) {
                Text("Auto · Native").tag(nil as Double?)
                Text("Native · 1×").tag(Optional(1.0))
                Text("80% · 1.25×").tag(Optional(1.25))
                Text("67% · 1.5×").tag(Optional(1.5))
                Text("50% · 2×").tag(Optional(2.0))
            }
            .labelsHidden()
        }
    }

    private var h264Quality: some View {
        advancedControl("VideoToolbox Quality") {
            HStack {
                Toggle(
                    "Custom",
                    isOn: optionalToggle(
                        get: { draft.h264QualityPercent },
                        set: { draft.h264QualityPercent = $0 },
                        defaultValue: 98
                    )
                )
                .toggleStyle(.switch)
                Spacer()
                if draft.h264QualityPercent != nil {
                    Stepper(
                        value: optionalInt(
                            get: { draft.h264QualityPercent },
                            set: { draft.h264QualityPercent = $0 },
                            defaultValue: 98
                        ),
                        in: LiveShareCodecAdvancedSettings.h264QualityPercentRange
                    ) {
                        Text("\(draft.h264QualityPercent ?? 98)%")
                            .monospacedDigit()
                    }
                } else {
                    Text("Auto · 98%").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var h264KeyFrameInterval: some View {
        advancedControl("Keyframe Interval") {
            HStack {
                Toggle(
                    "Custom",
                    isOn: optionalToggle(
                        get: { draft.h264KeyFrameIntervalSeconds },
                        set: { draft.h264KeyFrameIntervalSeconds = $0 },
                        defaultValue: 2
                    )
                )
                .toggleStyle(.switch)
                Spacer()
                if draft.h264KeyFrameIntervalSeconds != nil {
                    Stepper(
                        value: optionalInt(
                            get: { draft.h264KeyFrameIntervalSeconds },
                            set: { draft.h264KeyFrameIntervalSeconds = $0 },
                            defaultValue: 2
                        ),
                        in: LiveShareCodecAdvancedSettings.h264KeyFrameIntervalSecondsRange
                    ) {
                        Text("\(draft.h264KeyFrameIntervalSeconds ?? 2) s")
                            .monospacedDigit()
                    }
                } else {
                    Text("Auto · 2 s").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func advancedControl<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content()
        }
    }

    private var suggestedMaximumQuantizer: Int {
        38
    }

    private func optionalToggle(
        get: @escaping () -> Int?,
        set: @escaping (Int?) -> Void,
        defaultValue: Int
    ) -> Binding<Bool> {
        Binding(
            get: { get() != nil },
            set: { enabled in set(enabled ? (get() ?? defaultValue) : nil) }
        )
    }

    private func optionalInt(
        get: @escaping () -> Int?,
        set: @escaping (Int?) -> Void,
        defaultValue: Int
    ) -> Binding<Int> {
        Binding(
            get: { get() ?? defaultValue },
            set: { set($0) }
        )
    }
}

private extension LiveShareDegradationPreference {
    var advancedTitle: String {
        switch self {
        case .automatic: String(localized: "Auto · Follow Mode")
        case .preserveResolution: String(localized: "Preserve Resolution")
        case .balanced: String(localized: "Balanced")
        case .preserveFrameRate: String(localized: "Preserve Frame Rate")
        case .disabled: String(localized: "Disable Adaptation")
        }
    }
}

private struct LiveShareSettingRow<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 10)
                content
            }

            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
        .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
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
            Text(verbatim: sourceGeometrySummary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(verbatim: pipelineGeometrySummary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(verbatim: encoderSummary)
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
        .padding(ClipPopoverDesign.rowHorizontalPadding)
        .accessibilityElement(children: .combine)
    }

    private var sourceGeometrySummary: String {
        var values: [String] = []
        if let width = stream.sourcePointWidth,
           let height = stream.sourcePointHeight {
            values.append("Source \(width) × \(height) pt")
        }
        values.append(
            "\(stream.sourcePixelWidth) × \(stream.sourcePixelHeight) px"
        )
        return values.joined(separator: " · ")
    }

    private var pipelineGeometrySummary: String {
        var capture = "Capture \(stream.captureWidth) × \(stream.captureHeight)"
        if let pixelFormat = stream.capturePixelFormat {
            capture += " \(pixelFormat)"
        }
        var values = [
            capture,
            "Manifest \(stream.width) × \(stream.height)",
        ]
        if stream.hasMixedEncodedFrameDimensions {
            values.append("Encoded mixed")
        } else if let width = stream.encodedFrameWidth,
                  let height = stream.encodedFrameHeight {
            values.append("Encoded \(width) × \(height)")
        } else {
            values.append("Encoded unavailable")
        }
        return values.joined(separator: " · ")
    }

    private var encoderSummary: String {
        var values = [
            "\(stream.deliveredFramesPerSecond.formatted(.number.precision(.fractionLength(0...1)))) FPS",
        ]
        if let codec = stream.codec {
            values.append(codec)
        }
        if let quantizer = stream.averageQuantizer {
            values.append(
                "QP \(quantizer.formatted(.number.precision(.fractionLength(0...1))))"
            )
        }
        if stream.qualityLimitationResolutionChanges > 0 {
            values.append(
                "\(stream.qualityLimitationResolutionChanges) resolution changes"
            )
        }
        return values.joined(separator: " · ")
    }

    private var bitrateSummary: String {
        var values = [
            "\(LiveShareFormatting.bitrate(stream.bitsPerSecond)) actual",
        ]
        if let target = stream.targetBitsPerSecond {
            values.append("\(LiveShareFormatting.bitrate(target)) target")
        }
        if let floor = stream.configuredBitrateFloor {
            values.append("\(LiveShareFormatting.bitrate(floor)) min")
        } else {
            values.append("automatic min")
        }
        if stream.configuredBitrateCeiling > 0 {
            values.append(
                "\(LiveShareFormatting.bitrate(stream.configuredBitrateCeiling)) max"
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
