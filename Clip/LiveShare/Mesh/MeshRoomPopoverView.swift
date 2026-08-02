import Foundation
import SwiftUI

enum MeshRoomPopoverRoute: Equatable {
    case overview
    case sharedWindows
    case streamSettings
    case diagnostics
    case collaboration
    case roomAccess
}

enum MeshRoomPopoverNavigationPolicy {
    static func routeAfterAdmissionUpdate(
        currentRoute: MeshRoomPopoverRoute,
        previousAdmissionIDs: [String],
        currentAdmissionIDs: [String]
    ) -> MeshRoomPopoverRoute {
        let previous = Set(previousAdmissionIDs)
        let hasNewRequest = currentAdmissionIDs.contains {
            !previous.contains($0)
        }
        return hasNewRequest ? .overview : currentRoute
    }
}

@MainActor
struct MeshRoomPopoverView: View {
    static let contentWidth = ClipPopoverDesign.width
    static let contentSize = CGSize(width: contentWidth, height: 620)
    private static let settingsControlWidth: CGFloat = 190

    @ObservedObject var model: MeshRoomPresentationModel
    private let maximumHeight: CGFloat
    private let onContentHeightChange: (CGFloat) -> Void
    @State private var route: MeshRoomPopoverRoute = .overview

    init(
        model: MeshRoomPresentationModel,
        maximumHeight: CGFloat = 10_000,
        onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.model = model
        self.maximumHeight = maximumHeight
        self.onContentHeightChange = onContentHeightChange
    }

    var body: some View {
        ClipPopoverPane<AnyView, AnyView, AnyView>(
            width: Self.contentWidth,
            maximumHeight: maximumHeight,
            onContentHeightChange: onContentHeightChange,
            icon: routeIcon,
            iconTint: headerTint,
            title: routeTitle,
            subtitle: headerSubtitle,
            subtitleTint: subtitleTint,
            backTitle: route == .overview ? nil : String(localized: "Live Share"),
            onBack: route == .overview ? nil : { route = .overview },
            accessibilityIdentifier: "clip.meshRoom.popover"
        ) {
            AnyView(headerTrailing)
        } content: {
            AnyView(routeContent)
        } footer: {
            AnyView(footer)
        }
        .onChange(of: model.snapshot.phase) { _, phase in
            if phase.isTerminal {
                route = .overview
            }
        }
        .onChange(
            of: model.snapshot.pendingAdmissions.map(\.id)
        ) { previous, current in
            route = MeshRoomPopoverNavigationPolicy
                .routeAfterAdmissionUpdate(
                    currentRoute: route,
                    previousAdmissionIDs: previous,
                    currentAdmissionIDs: current
                )
        }
        .onChange(
            of: model.snapshot.pendingFriendRequests.map(\.id)
        ) { previous, current in
            route = MeshRoomPopoverNavigationPolicy
                .routeAfterAdmissionUpdate(
                    currentRoute: route,
                    previousAdmissionIDs: previous,
                    currentAdmissionIDs: current
                )
        }
        .confirmationDialog(
            String(localized: "Change this invite?"),
            isPresented: Binding(
                get: {
                    model.isInviteChangeConfirmationPresented
                },
                set: { presented in
                    if !presented {
                        model.cancelInviteChange()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "Change Invite"),
                role: .destructive,
                action: model.confirmInviteChange
            )
            Button(
                String(localized: "Cancel"),
                role: .cancel,
                action: model.cancelInviteChange
            )
        } message: {
            Text(
                String(
                    localized:
                        "The current link will stop working. Everyone already in the room stays connected."
                )
            )
        }
    }

    private var routeTitle: String {
        switch route {
        case .overview:
            String(localized: "Live Share")
        case .sharedWindows:
            String(localized: "Shared With You")
        case .streamSettings:
            String(localized: "Stream Settings")
        case .diagnostics:
            String(localized: "Diagnostics")
        case .collaboration:
            String(localized: "Collaboration")
        case .roomAccess:
            String(localized: "Room & Access")
        }
    }

    private var routeIcon: String {
        switch route {
        case .overview:
            "rectangle.inset.filled.and.person.filled"
        case .sharedWindows:
            "square.3.layers.3d.top.filled"
        case .streamSettings:
            "slider.horizontal.3"
        case .diagnostics:
            "waveform.path.ecg.rectangle"
        case .collaboration:
            "pencil.and.scribble"
        case .roomAccess:
            "person.2.badge.gearshape"
        }
    }

    private var headerSubtitle: String {
        switch route {
        case .overview:
            "\(model.snapshot.roomName) · \(model.snapshot.phase.title)"
        case .sharedWindows:
            sharedWindowsSummary
        default:
            model.snapshot.roomName
        }
    }

    private var headerTint: Color {
        switch model.snapshot.phase {
        case .live:
            .red
        case .reconnecting:
            .orange
        case .failed:
            .orange
        case .connecting, .ending, .ended:
            .secondary
        }
    }

    private var subtitleTint: Color {
        switch model.snapshot.phase {
        case .failed:
            .orange
        default:
            .secondary
        }
    }

    private var headerTrailing: some View {
        Label(
            "\(model.snapshot.participantCount)",
            systemImage: "person.2.fill"
        )
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.secondary)
        .help(String(localized: "Participants"))
        .accessibilityLabel(
            String(
                localized:
                    "\(model.snapshot.participantCount) room participants"
            )
        )
        .accessibilityIdentifier("clip.meshRoom.participantCount")
    }

    @ViewBuilder
    private var routeContent: some View {
        switch route {
        case .overview:
            overview
        case .sharedWindows:
            sharedWindows
        case .streamSettings:
            streamSettings
        case .diagnostics:
            diagnostics
        case .collaboration:
            collaboration
        case .roomAccess:
            roomAccess
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            roomStatusBanner
            joinRequests
            friendRequests
            roomSummary
            localShareSection

            navigation
            terminalMessage
        }
    }

    @ViewBuilder
    private var roomStatusBanner: some View {
        if let notice = model.snapshot.statusNotice {
            MeshRoomNoticeView(
                title: notice.title,
                message: notice.message,
                systemImage: noticeSystemImage(notice.severity),
                tint: noticeTint(notice.severity)
            )
        }

        if case let .failed(message) = model.snapshot.phase {
            MeshRoomNoticeView(
                title: String(localized: "Live Share failed"),
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
    }

    private func noticeSystemImage(
        _ severity: MeshRoomStatusNoticeSeverity
    ) -> String {
        switch severity {
        case .information:
            "info.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }

    private func noticeTint(
        _ severity: MeshRoomStatusNoticeSeverity
    ) -> Color {
        switch severity {
        case .information:
            .blue
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    private var roomSummary: some View {
        ClipPopoverSection(String(localized: "Room")) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.snapshot.roomName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(roomCreatorSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if model.snapshot.isLocalCreator,
                       model.snapshot.invite != nil {
                        ClipPopoverButton(
                            model.copiedInvite
                                ? String(localized: "Copied")
                                : String(localized: "Copy Invite"),
                            systemImage: model.copiedInvite
                                ? "checkmark"
                                : "doc.on.doc",
                            isEnabled:
                                model.snapshot.invite?.isAvailable == true,
                            accessibilityIdentifier:
                                "clip.meshRoom.copyInvite",
                            action: model.copyInvite
                        )
                    }
                }
                .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)

                ClipPopoverRowDivider(leadingInset: 12)

                ClipPopoverNavigationRow(
                    String(localized: "Room & Access"),
                    subtitle: roomAccessSummary,
                    systemImage: "person.2.badge.gearshape",
                    accessibilityIdentifier:
                        "clip.meshRoom.navigation.roomAccess"
                ) {
                    route = .roomAccess
                }

                ClipPopoverRowDivider(leadingInset: 12)

                ClipPopoverNavigationRow(
                    String(localized: "Shared With You"),
                    subtitle: sharedWindowsSummary,
                    systemImage: "square.3.layers.3d.top.filled",
                    accessibilityIdentifier:
                        "clip.meshRoom.navigation.sharedWindows"
                ) {
                    route = .sharedWindows
                }
            }
        }
    }

    private var sharedWindowsSummary: String {
        let windows = model.snapshot.remoteSharedSourceCount
        let people = model.snapshot.sharingRemoteParticipantCount
        switch (windows, people) {
        case (0, _):
            return String(localized: "No shared windows")
        case (1, 1):
            return String(localized: "1 window from 1 person")
        case (1, let people):
            return String(localized: "1 window from \(people) people")
        case (let windows, 1):
            return String(localized: "\(windows) windows from 1 person")
        case (let windows, let people):
            return String(
                localized: "\(windows) windows from \(people) people"
            )
        }
    }

    private var sharedWindows: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            let sharingParticipants = model.snapshot.remoteParticipants.filter {
                !$0.sources.isEmpty || $0.systemAudioAvailable
            }

            if sharingParticipants.isEmpty {
                ClipPopoverSection {
                    MeshRoomEmptyCardMessage(
                        String(
                            localized:
                                "Shared windows will appear here when another participant starts sharing."
                        )
                    )
                }
            } else {
                if sharingParticipants.contains(where: { !$0.sources.isEmpty }) {
                    ClipPopoverButton(
                        String(localized: "Bring All Shared Windows to Front"),
                        systemImage: "square.3.layers.3d.top.filled",
                        fillsWidth: true,
                        accessibilityIdentifier:
                            "clip.meshRoom.bringAllRemoteWindows",
                        action: model.bringAllRemoteWindowsToFront
                    )
                }

                ForEach(sharingParticipants) { participant in
                    remoteParticipantSection(participant)
                }
            }
        }
        .accessibilityIdentifier("clip.meshRoom.sharedWindows")
    }

    private var roomCreatorSummary: String {
        if model.snapshot.isLocalCreator {
            return String(localized: "You manage this room")
        }
        if let creator = model.snapshot.creatorDisplayName {
            return String(localized: "Managed by \(creator)")
        }
        return String(localized: "Room creator unavailable")
    }

    private var roomAccessSummary: String {
        if !model.snapshot.pendingAdmissions.isEmpty {
            return String(
                localized:
                    "\(model.snapshot.pendingAdmissions.count) waiting for approval"
            )
        }
        if !model.snapshot.pendingFriendRequests.isEmpty {
            return String(
                localized:
                    "\(model.snapshot.pendingFriendRequests.count) friend requests"
            )
        }
        return model.snapshot.isLocalCreator
            ? String(localized: "Invite, approvals, and participants")
            : String(localized: "Participants and room creator")
    }

    private var localShareSection: some View {
        ClipPopoverSection(
            String(
                localized:
                    "Your Share · \(model.snapshot.localSources.count) windows"
            )
        ) {
            VStack(spacing: 0) {
                ClipPopoverToggleRow(
                    String(localized: "Fullscreen"),
                    subtitle: fullscreenSubtitle,
                    systemImage: "rectangle.inset.filled",
                    isEnabled:
                        model.snapshot.phase.allowsMediaChanges
                            && model.snapshot.fullscreen.isEnabled,
                    accessibilityIdentifier: "clip.meshRoom.fullscreen",
                    isOn: Binding(
                        get: { model.snapshot.fullscreen.isOn },
                        set: { model.setFullscreenEnabled($0) }
                    )
                )

                ForEach(model.snapshot.localSources) { source in
                    ClipPopoverRowDivider()
                    MeshRoomSourceRow(
                        title: source.title,
                        detail: source.detail,
                        systemImage: source.isFocused
                            ? "rectangle.inset.filled"
                            : "rectangle"
                    ) {
                        Button(role: .destructive) {
                            model.stopLocalSource(source.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!source.canStop)
                        .help(String(localized: "Stop sharing"))
                        .accessibilityLabel(String(localized: "Stop sharing"))
                        .accessibilityIdentifier(
                            "clip.meshRoom.localSource.stop.\(source.id)"
                        )
                    }
                }

                ClipPopoverRowDivider()

                HStack(spacing: 8) {
                    Menu {
                        ForEach(groupedAvailableApplications, id: \.name) {
                            application in
                            Section(application.name) {
                                ForEach(application.windows) { window in
                                    Button(window.windowTitle) {
                                        model.shareWindow(window.id)
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
                            size: .standard,
                            fillsWidth: true
                        )
                    )
                    .disabled(
                        !model.snapshot.phase.allowsMediaChanges
                            || !model.snapshot.canAddWindow
                    )
                    .accessibilityIdentifier("clip.meshRoom.addWindow")

                    ClipPopoverButton(
                        String(localized: "Share Focused"),
                        systemImage: "scope",
                        fillsWidth: true,
                        isEnabled:
                            model.snapshot.phase.allowsMediaChanges
                                && model.snapshot.canShareFocusedWindow
                                && !model.snapshot.settings
                                    .autoShareFocusedWindows,
                        accessibilityIdentifier:
                            "clip.meshRoom.shareFocusedWindow",
                        action: model.shareFocusedWindow
                    )
                }
                .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)

                if let focusedWindowDescription =
                    model.snapshot.focusedWindowDescription {
                    Text("Focused: \(focusedWindowDescription)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                        .padding(.bottom, ClipPopoverDesign.rowVerticalPadding)
                }

                ClipPopoverRowDivider()

                localAudioControls
            }
        }
    }

    private var fullscreenSubtitle: String {
        if let detail = model.snapshot.fullscreen.detail {
            return "\(model.snapshot.fullscreen.displayName) · \(detail)"
        }
        return model.snapshot.fullscreen.displayName
    }

    private var localAudioControls: some View {
        VStack(spacing: 0) {
            ClipPopoverToggleRow(
                String(localized: "Share System Audio"),
                subtitle: String(
                    localized:
                        "Each participant controls your audio independently."
                ),
                systemImage: "speaker.wave.2",
                isEnabled:
                    model.snapshot.phase.allowsMediaChanges
                        && model.snapshot.settings.canChangeSystemAudio,
                accessibilityIdentifier: "clip.meshRoom.systemAudio",
                isOn: Binding(
                    get: {
                        model.snapshot.settings.systemAudioEnabled
                    },
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

    private var audioExclusionMenu: some View {
        ClipPopoverMenuRow(
            String(localized: "Exclude App Audio"),
            value: model.snapshot.settings.audioExclusionSummary,
            isEnabled:
                model.snapshot.settings.canChangeAudioExclusions
                    && (
                        !model.snapshot.settings
                            .audioExclusionApplications.isEmpty
                            || !model.snapshot.settings
                                .excludedAudioApplicationIDs.isEmpty
                    ),
            accessibilityIdentifier: "clip.meshRoom.audioExclusions"
        ) {
            if model.snapshot.settings.audioExclusionApplications.isEmpty {
                Text("No other apps are running")
            } else {
                Section("Exclude Audio") {
                    ForEach(sortedAudioApplications) { application in
                        Toggle(
                            application.name,
                            isOn: audioExclusionBinding(application.id)
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
    }

    private var sortedAudioApplications:
        [LiveShareAudioApplicationViewSnapshot]
    {
        model.snapshot.settings.audioExclusionApplications.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    private func audioExclusionBinding(_ applicationID: String) -> Binding<Bool> {
        Binding(
            get: {
                model.snapshot.settings.excludedAudioApplicationIDs.contains(
                    applicationID
                )
            },
            set: { excluded in
                var identifiers =
                    model.snapshot.settings.excludedAudioApplicationIDs
                if excluded {
                    identifiers.insert(applicationID)
                } else {
                    identifiers.remove(applicationID)
                }
                model.setExcludedAudioApplicationIDs(identifiers)
            }
        )
    }

    private func remoteParticipantSection(
        _ participant: MeshRoomRemoteParticipantSnapshot
    ) -> some View {
        ClipPopoverSection(
            remoteParticipantTitle(participant)
        ) {
            if !participant.sources.isEmpty {
                Button {
                    model.bringParticipantToFront(participant.id)
                } label: {
                    Label(
                        String(localized: "Bring to Front"),
                        systemImage: "square.3.layers.3d.top.filled"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .modifier(ClipPopoverHoverEffect())
                .help(String(localized: "Bring shared windows to front"))
                .accessibilityIdentifier(
                    "clip.meshRoom.participant.bringToFront.\(participant.id)"
                )
            }
        } content: {
            VStack(spacing: 0) {
                if participant.sources.isEmpty {
                    Text(
                        String(
                            localized:
                                "\(participant.displayName) is not sharing any windows."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                    .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
                } else {
                    ForEach(
                        Array(participant.sources.enumerated()),
                        id: \.element.id
                    ) { index, source in
                        remoteSourceRow(
                            source,
                            participant: participant
                        )
                        if index < participant.sources.count - 1 {
                            ClipPopoverRowDivider()
                        }
                    }
                }

                if participant.systemAudioAvailable {
                    if !participant.sources.isEmpty {
                        ClipPopoverRowDivider()
                    }
                    participantAudio(participant)
                }
            }
        }
    }

    private func remoteParticipantTitle(
        _ participant: MeshRoomRemoteParticipantSnapshot
    ) -> String {
        var values = [participant.displayName]
        if participant.id == model.snapshot.creatorParticipantID {
            values.append(String(localized: "Creator"))
        }
        values.append(participant.route.title)
        return values.joined(separator: " · ")
    }

    private func remoteSourceRow(
        _ source: MeshRoomRemoteSourceSnapshot,
        participant: MeshRoomRemoteParticipantSnapshot
    ) -> some View {
        let key = MeshRoomSourceKey(
            participantID: participant.id,
            sourceID: source.id
        )
        return MeshRoomSourceRow(
            title: source.title,
            detail: source.detail,
            systemImage: source.isFocused
                ? "rectangle.inset.filled"
                : "rectangle"
        ) {
            Toggle(
                String(localized: "Visible"),
                isOn: Binding(
                    get: { source.isVisible },
                    set: { model.setRemoteSourceVisible(key, $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        } controls: {
            HStack(spacing: 6) {
                remoteScaleMenu(source, key: key)
                Spacer(minLength: 4)
                sourceIconButton(
                    title: String(localized: "Bring to Front"),
                    systemImage: "macwindow.on.rectangle",
                    identifier:
                        "clip.meshRoom.remoteSource.bringToFront."
                            + "\(key.participantID).\(key.sourceID)"
                ) {
                    model.bringRemoteSourceToFront(key)
                }
                sourceIconButton(
                    title: source.isFullScreen
                        ? String(localized: "Exit Full Screen")
                        : String(localized: "Enter Full Screen"),
                    systemImage: source.isFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    identifier:
                        "clip.meshRoom.remoteSource.fullscreen."
                            + "\(key.participantID).\(key.sourceID)"
                ) {
                    model.toggleRemoteSourceFullScreen(key)
                }
                .disabled(!source.isVisible || !source.isConnected)
            }
        }
    }

    private func remoteScaleMenu(
        _ source: MeshRoomRemoteSourceSnapshot,
        key: MeshRoomSourceKey
    ) -> some View {
        Menu {
            ForEach(NativeViewerScaleMode.allCases, id: \.self) { mode in
                Button {
                    model.setRemoteSourceScaleMode(key, mode)
                } label: {
                    HStack {
                        Text(scaleModeTitle(mode))
                        if source.scaleMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label(
                scaleModeTitle(source.scaleMode),
                systemImage: "aspectratio"
            )
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(String(localized: "Window sizing"))
        .accessibilityIdentifier(
            "clip.meshRoom.remoteSource.scaleMode."
                + "\(key.participantID).\(key.sourceID)"
        )
    }

    private func scaleModeTitle(_ mode: NativeViewerScaleMode) -> String {
        switch mode {
        case .follow:
            String(localized: "Follow")
        case .native:
            String(localized: "Native")
        case .fit:
            String(localized: "Fit")
        }
    }

    private func sourceIconButton(
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

    private func participantAudio(
        _ participant: MeshRoomRemoteParticipantSnapshot
    ) -> some View {
        VStack(spacing: 8) {
            ClipPopoverToggleRow(
                String(localized: "Play \(participant.displayName)’s Audio"),
                systemImage: "speaker.wave.2",
                accessibilityIdentifier:
                    "clip.meshRoom.participant.audio.\(participant.id)",
                isOn: Binding(
                    get: { participant.systemAudioEnabled },
                    set: {
                        model.setParticipantAudioEnabled(
                            participant.id,
                            $0
                        )
                    }
                )
            )
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { participant.volume },
                        set: {
                            model.setParticipantVolume(
                                participant.id,
                                $0
                            )
                        }
                    ),
                    in: 0...1
                )
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
            .disabled(!participant.systemAudioEnabled)
            .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
            .padding(.bottom, ClipPopoverDesign.rowVerticalPadding)
            .accessibilityIdentifier(
                "clip.meshRoom.participant.volume.\(participant.id)"
            )
        }
    }

    private var navigation: some View {
        ClipPopoverSection {
            VStack(spacing: 0) {
                ClipPopoverNavigationRow(
                    String(localized: "Stream Settings"),
                    subtitle: streamSettingsSummary,
                    systemImage: "slider.horizontal.3",
                    accessibilityIdentifier:
                        "clip.meshRoom.navigation.streamSettings"
                ) {
                    route = .streamSettings
                }
                ClipPopoverRowDivider()
                ClipPopoverNavigationRow(
                    String(localized: "Diagnostics"),
                    subtitle: diagnosticsSummary,
                    systemImage: "waveform.path.ecg.rectangle",
                    accessibilityIdentifier:
                        "clip.meshRoom.navigation.diagnostics"
                ) {
                    route = .diagnostics
                }
                ClipPopoverRowDivider()
                ClipPopoverNavigationRow(
                    String(localized: "Collaboration"),
                    subtitle: model.snapshot.collaboration.summary,
                    systemImage: "pencil.and.scribble",
                    accessibilityIdentifier:
                        "clip.meshRoom.navigation.collaboration"
                ) {
                    route = .collaboration
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
        ].joined(separator: " · ")
    }

    private var diagnosticsSummary: String {
        let linkCount = model.snapshot.peerDiagnostics.count
        let sourceCount =
            model.snapshot.outgoingDiagnostics.count
                + model.snapshot.remoteParticipants.reduce(0) {
                    $0 + $1.diagnostics.count
                }
        return String(
            localized: "\(linkCount) links · \(sourceCount) media streams"
        )
    }

    @ViewBuilder
    private var terminalMessage: some View {
        if model.snapshot.phase.isTerminal {
            ClipPopoverSection {
                Text(model.snapshot.phase.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ClipPopoverDesign.rowHorizontalPadding)
            }
        }
    }

    private var streamSettings: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            ClipPopoverSection(String(localized: "Video")) {
                VStack(spacing: 0) {
                    MeshRoomSettingRow(
                        title: String(localized: "Quality")
                    ) {
                        Picker(
                            String(localized: "Quality"),
                            selection: Binding(
                                get: { model.snapshot.settings.quality },
                                set: { model.setQuality($0) }
                            )
                        ) {
                            ForEach(LiveShareQualityPreset.allCases) {
                                preset in
                                Text(
                                    "\(preset.title) · \(preset.bitrateText)"
                                )
                                .tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(
                            width: Self.settingsControlWidth,
                            alignment: .trailing
                        )
                        .disabled(
                            !model.snapshot.settings.canChangeQuality
                        )
                    }

                    ClipPopoverRowDivider(leadingInset: 12)

                    MeshRoomSettingRow(
                        title: String(localized: "Frame Rate")
                    ) {
                        Picker(
                            String(localized: "Frame Rate"),
                            selection: Binding(
                                get: { model.snapshot.settings.frameRate },
                                set: { model.setFrameRate($0) }
                            )
                        ) {
                            ForEach(
                                model.snapshot.settings.availableFrameRates
                                    .sorted {
                                        $0.rawValue < $1.rawValue
                                    }
                            ) { rate in
                                Text("\(rate.rawValue)")
                                    .tag(rate)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(
                            width: Self.settingsControlWidth,
                            alignment: .trailing
                        )
                        .disabled(
                            !model.snapshot.settings.canChangeFrameRate
                        )
                    }

                    ClipPopoverRowDivider(leadingInset: 12)

                    MeshRoomSettingRow(
                        title: String(localized: "Codec"),
                        detail: model.snapshot.settings.codec.detail
                    ) {
                        HStack(spacing: 6) {
                            Picker(
                                String(localized: "Codec"),
                                selection: Binding(
                                    get: {
                                        model.snapshot.settings.codec.codec
                                    },
                                    set: { model.setCodec($0) }
                                )
                            ) {
                                ForEach(LiveShareVideoCodec.allCases) {
                                    codec in
                                    Text(codec.displayName).tag(codec)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 105, alignment: .trailing)
                            .disabled(
                                !model.snapshot.settings.canChangeCodec
                            )

                            LiveShareAdvancedCodecSettingsButton(
                                codec:
                                    model.snapshot.settings.codec.codec,
                                current:
                                    model.snapshot.settings
                                        .advancedVideoSettings.settings(
                                            for: model.snapshot.settings
                                                .codec.codec
                                        ),
                                isEnabled:
                                    model.snapshot.settings.canChangeMode
                            ) { codec, settings in
                                model.setAdvancedVideoSettings(
                                    settings,
                                    for: codec
                                )
                            }
                            .labelStyle(.iconOnly)
                        }
                        .frame(
                            width: Self.settingsControlWidth,
                            alignment: .trailing
                        )
                    }

                    ClipPopoverRowDivider(leadingInset: 12)

                    MeshRoomSettingRow(
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
                            ForEach(LiveShareColorMode.allCases) { color in
                                Text(color.title).tag(color)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(
                            width: Self.settingsControlWidth,
                            alignment: .trailing
                        )
                        .disabled(
                            !model.snapshot.settings.canChangeColorMode
                        )
                    }

                    ClipPopoverRowDivider(leadingInset: 12)

                    MeshRoomSettingRow(
                        title: String(localized: "Mode")
                    ) {
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
                            width: Self.settingsControlWidth,
                            alignment: .trailing
                        )
                        .disabled(
                            !model.snapshot.settings.canChangeMode
                        )
                    }
                }
            }

            ClipPopoverSection(String(localized: "Behavior")) {
                VStack(spacing: 0) {
                    ClipPopoverToggleRow(
                        String(localized: "Match Cursor to Frame Rate"),
                        systemImage: "cursorarrow.motionlines",
                        isEnabled:
                            model.snapshot.settings
                                .canChangeCursorUpdateRate,
                        isOn: Binding(
                            get: {
                                model.snapshot.settings
                                    .cursorUpdatesMatchFrameRate
                            },
                            set: {
                                model.setCursorUpdatesMatchFrameRate($0)
                            }
                        )
                    )
                    ClipPopoverRowDivider()
                    ClipPopoverToggleRow(
                        String(localized: "Prioritize Focused Window"),
                        systemImage: "scope",
                        isEnabled:
                            model.snapshot.settings
                                .canChangePrioritizeFocusedWindow,
                        isOn: Binding(
                            get: {
                                model.snapshot.settings
                                    .prioritizeFocusedWindow
                            },
                            set: {
                                model.setPrioritizeFocusedWindow($0)
                            }
                        )
                    )
                    ClipPopoverRowDivider()
                    ClipPopoverToggleRow(
                        String(localized: "Auto-share Focused Windows"),
                        systemImage:
                            "rectangle.on.rectangle.badge.person.crop",
                        isEnabled:
                            model.snapshot.settings.canChangeAutoShare
                                && !model.snapshot.fullscreen.isOn,
                        isOn: Binding(
                            get: {
                                model.snapshot.settings
                                    .autoShareFocusedWindows
                            },
                            set: { model.setAutoShareEnabled($0) }
                        )
                    )
                }
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            ClipPopoverSection(String(localized: "Connections")) {
                if model.snapshot.peerDiagnostics.isEmpty {
                    MeshRoomEmptyCardMessage(
                        String(localized: "Waiting for peer connections…")
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(
                            Array(
                                model.snapshot.peerDiagnostics.enumerated()
                            ),
                            id: \.element.id
                        ) { index, peer in
                            MeshRoomPeerDiagnosticsRow(peer: peer)
                            if index
                                < model.snapshot.peerDiagnostics.count - 1 {
                                ClipPopoverRowDivider(leadingInset: 28)
                            }
                        }
                    }
                }
            }

            ClipPopoverSection(String(localized: "Your Publishing")) {
                diagnosticsRows(
                    model.snapshot.outgoingDiagnostics,
                    emptyMessage: String(
                        localized:
                            "Statistics appear after you start sharing."
                    )
                )
            }

            ForEach(model.snapshot.remoteParticipants) { participant in
                ClipPopoverSection(
                    String(localized: "From \(participant.displayName)")
                ) {
                    diagnosticsRows(
                        participant.diagnostics,
                        emptyMessage: String(
                            localized:
                                "No incoming media statistics available."
                        )
                    )
                }
            }
        }
        .accessibilityIdentifier("clip.meshRoom.diagnostics")
    }

    private func diagnosticsRows(
        _ rows: [MeshRoomMediaDiagnosticsSnapshot],
        emptyMessage: String
    ) -> some View {
        Group {
            if rows.isEmpty {
                MeshRoomEmptyCardMessage(emptyMessage)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) {
                        index, diagnostics in
                        MeshRoomMediaDiagnosticsRow(
                            diagnostics: diagnostics
                        )
                        if index < rows.count - 1 {
                            ClipPopoverRowDivider(leadingInset: 12)
                        }
                    }
                }
            }
        }
    }

    private var collaboration: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            ClipPopoverSection(String(localized: "Your Tools")) {
                VStack(spacing: 0) {
                    ClipPopoverToggleRow(
                        String(localized: "Reveal My Pointer"),
                        subtitle: String(
                            localized:
                                "Show a named pointer over the source you are viewing."
                        ),
                        systemImage: "cursorarrow.rays",
                        isOn: Binding(
                            get: {
                                model.snapshot.collaboration
                                    .isLocalPointerVisible
                            },
                            set: { model.setLocalPointerVisible($0) }
                        )
                    )
                    ClipPopoverRowDivider()
                    ClipPopoverToggleRow(
                        String(localized: "Ping Mode"),
                        subtitle: String(
                            localized:
                                "Click a shared source to briefly highlight a point."
                        ),
                        systemImage: "scope",
                        isOn: Binding(
                            get: {
                                model.snapshot.collaboration
                                    .isLocalPingModeEnabled
                            },
                            set: { model.setLocalPingModeEnabled($0) }
                        )
                    )
                    ClipPopoverRowDivider()
                    ClipPopoverToggleRow(
                        String(localized: "Draw"),
                        subtitle: String(
                            localized:
                                "Draw bounded vector ink over a shared source."
                        ),
                        systemImage: "pencil.tip.crop.circle",
                        isOn: Binding(
                            get: {
                                model.snapshot.collaboration
                                    .isLocalInkEnabled
                            },
                            set: { model.setLocalInkEnabled($0) }
                        )
                    )
                }
            }

            ClipPopoverSection(String(localized: "Annotations")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            String(
                                localized:
                                    "\(model.snapshot.collaboration.annotationStrokeCount) strokes"
                            )
                        )
                        .font(.subheadline.weight(.medium))
                        Text(
                            String(
                                localized:
                                    "\(model.snapshot.collaboration.activePointerCount) active pointers"
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ClipPopoverButton(
                        String(localized: "Clear All"),
                        systemImage: "eraser",
                        isEnabled:
                            model.snapshot.collaboration
                                .canClearAnnotations,
                        accessibilityIdentifier:
                            "clip.meshRoom.collaboration.clear",
                        action: model.clearAnnotations
                    )
                }
                .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
            }
        }
    }

    private var roomAccess: some View {
        VStack(alignment: .leading, spacing: ClipPopoverDesign.paneSpacing) {
            ClipPopoverSection(String(localized: "Room Creator")) {
                HStack(spacing: 10) {
                    Image(systemName: "crown.fill")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            model.snapshot.creatorDisplayName
                                ?? String(localized: "Room creator unavailable")
                        )
                        .font(.subheadline.weight(.medium))
                        Text(creatorDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
            }

            if model.snapshot.isLocalCreator {
                creatorAccess
            }

            participantsManagement
        }
    }

    private var creatorDetail: String {
        model.snapshot.isLocalCreator
            ? String(localized: "You manage admission and membership")
            : String(localized: "Manages admission and membership")
    }

    @ViewBuilder
    private var creatorAccess: some View {
        ClipPopoverSection(String(localized: "Invite & Access")) {
            VStack(spacing: 0) {
                if let invite = model.snapshot.invite {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invite.codeLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(invite.roomCode)
                                .font(
                                    .subheadline.monospaced().weight(.medium)
                                )
                            Text(invite.reuseDetail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(
                            "clip.meshRoom.inviteCode"
                        )
                        Spacer()
                        ClipPopoverButton(
                            model.copiedInvite
                                ? String(localized: "Copied")
                                : String(localized: "Copy Invite"),
                            systemImage: model.copiedInvite
                                ? "checkmark"
                                : "doc.on.doc",
                            isEnabled: invite.isAvailable,
                            accessibilityIdentifier:
                                "clip.meshRoom.roomAccess.copyInvite",
                            action: model.copyInvite
                        )
                        ClipPopoverButton(
                            String(localized: "Change"),
                            systemImage: "arrow.triangle.2.circlepath",
                            isEnabled:
                                model.snapshot.canChangeAccessWord,
                            accessibilityIdentifier:
                                "clip.meshRoom.changeInvite",
                            action: model.requestInviteChangeConfirmation
                        )
                    }
                    .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                    .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
                    ClipPopoverRowDivider(leadingInset: 12)
                }

                ClipPopoverToggleRow(
                    String(localized: "Access Word"),
                    systemImage: "lock",
                    isEnabled: model.snapshot.canChangeAccessWord,
                    isOn: Binding(
                        get: { model.snapshot.accessWordEnabled },
                        set: { model.setAccessWordEnabled($0) }
                    )
                )

                if model.snapshot.accessWordEnabled {
                    ClipPopoverRowDivider(leadingInset: 12)
                    HStack {
                        Text(
                            model.snapshot.accessWord
                                ?? String(localized: "Creating…")
                        )
                        .font(.subheadline.monospaced().weight(.medium))
                        Spacer()
                        ClipPopoverButton(
                            String(localized: "Copy"),
                            systemImage: "doc.on.doc",
                            isEnabled:
                                model.snapshot.canChangeAccessWord
                                && model.snapshot.accessWord != nil,
                            action: model.copyAccessWord
                        )
                        ClipPopoverButton(
                            String(localized: "Replace"),
                            systemImage: "arrow.clockwise",
                            isEnabled: model.snapshot.canChangeAccessWord,
                            action: model.replaceAccessWord
                        )
                    }
                    .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
                    .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
                }

                ClipPopoverRowDivider(leadingInset: 12)
                ClipPopoverToggleRow(
                    String(localized: "Ask Before Joining"),
                    subtitle: String(
                        localized:
                            "Require Allow or Deny after an invite has been verified."
                    ),
                    systemImage: "person.crop.circle.badge.questionmark",
                    isEnabled:
                        model.snapshot.canChangeAskBeforeJoining,
                    accessibilityIdentifier:
                        "clip.meshRoom.askBeforeJoining",
                    isOn: Binding(
                        get: { model.snapshot.askBeforeJoining },
                        set: { model.setAskBeforeJoining($0) }
                    )
                )
            }
        }
    }

    @ViewBuilder
    private var joinRequests: some View {
        if model.snapshot.isLocalCreator,
           !model.snapshot.pendingAdmissions.isEmpty {
            let count = model.snapshot.pendingAdmissions.count
            ClipPopoverSection(
                count == 1
                    ? String(localized: "Join Request")
                    : String(localized: "Join Requests")
            ) {
                Label(
                    String(localized: "\(count) waiting"),
                    systemImage: "bell.badge.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityIdentifier(
                    "clip.meshRoom.joinRequests.count"
                )
            } content: {
                VStack(spacing: 0) {
                    ForEach(
                        Array(model.snapshot.pendingAdmissions.enumerated()),
                        id: \.element.id
                    ) { index, admission in
                        HStack(spacing: 10) {
                            Image(
                                systemName:
                                    "person.crop.circle.badge.questionmark"
                            )
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                            .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(admission.displayName)
                                    .font(.subheadline.weight(.medium))
                                if let deviceName = admission.deviceName {
                                    Text(deviceName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            ClipPopoverButton(
                                String(localized: "Deny"),
                                prominence: .secondary,
                                accessibilityIdentifier:
                                    "clip.meshRoom.joinRequest.deny.\(admission.id)"
                            ) {
                                model.denyAdmission(admission.id)
                            }
                            ClipPopoverButton(
                                String(localized: "Allow"),
                                prominence: .primary,
                                accessibilityIdentifier:
                                    "clip.meshRoom.joinRequest.allow.\(admission.id)"
                            ) {
                                model.approveAdmission(admission.id)
                            }
                        }
                        .padding(
                            .horizontal,
                            ClipPopoverDesign.rowHorizontalPadding
                        )
                        .padding(
                            .vertical,
                            ClipPopoverDesign.rowVerticalPadding
                        )
                        if index
                            < model.snapshot.pendingAdmissions.count - 1 {
                            ClipPopoverRowDivider(leadingInset: 12)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var friendRequests: some View {
        if !model.snapshot.pendingFriendRequests.isEmpty {
            let count = model.snapshot.pendingFriendRequests.count
            ClipPopoverSection(
                count == 1
                    ? String(localized: "Friend Request")
                    : String(localized: "Friend Requests")
            ) {
                Label(
                    String(localized: "\(count) waiting"),
                    systemImage: "person.crop.circle.badge.plus"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .accessibilityIdentifier(
                    "clip.meshRoom.friendRequests.count"
                )
            } content: {
                VStack(spacing: 0) {
                    ForEach(
                        Array(
                            model.snapshot.pendingFriendRequests.enumerated()
                        ),
                        id: \.element.id
                    ) { index, request in
                        HStack(spacing: 10) {
                            Image(
                                systemName:
                                    "person.crop.circle.badge.plus"
                            )
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                            .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.displayName)
                                    .font(.subheadline.weight(.medium))
                                Text(
                                    request.deviceName
                                        ?? String(
                                            localized:
                                                "Wants to add you as a friend"
                                        )
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ClipPopoverButton(
                                String(localized: "Deny"),
                                prominence: .secondary,
                                accessibilityIdentifier:
                                    "clip.meshRoom.friendRequest.deny.\(request.id)"
                            ) {
                                model.denyFriendRequest(request.id)
                            }
                            ClipPopoverButton(
                                String(localized: "Allow"),
                                prominence: .primary,
                                accessibilityIdentifier:
                                    "clip.meshRoom.friendRequest.allow.\(request.id)"
                            ) {
                                model.allowFriendRequest(request.id)
                            }
                        }
                        .padding(
                            .horizontal,
                            ClipPopoverDesign.rowHorizontalPadding
                        )
                        .padding(
                            .vertical,
                            ClipPopoverDesign.rowVerticalPadding
                        )
                        if index
                            < model.snapshot.pendingFriendRequests.count - 1 {
                            ClipPopoverRowDivider(leadingInset: 12)
                        }
                    }
                }
            }
        }
    }

    private var participantsManagement: some View {
        ClipPopoverSection(
            String(
                localized:
                    "Participants · \(model.snapshot.participantCount)"
            )
        ) {
            VStack(spacing: 0) {
                participantManagementRow(
                    id: model.snapshot.localParticipant.id,
                    name: model.snapshot.localParticipant.displayName,
                    detail: model.snapshot.localParticipant.deviceName,
                    isLocal: true,
                    isCreator:
                        model.snapshot.localParticipant.id
                            == model.snapshot.creatorParticipantID,
                    friendshipState: nil
                )

                ForEach(model.snapshot.remoteParticipants) { participant in
                    ClipPopoverRowDivider(leadingInset: 28)
                    participantManagementRow(
                        id: participant.id,
                        name: participant.displayName,
                        detail: participant.deviceName
                            ?? participant.route.title,
                        isLocal: false,
                        isCreator:
                            participant.id
                                == model.snapshot.creatorParticipantID,
                        friendshipState: participant.friendshipState
                    )
                }
            }
        }
    }

    private func participantManagementRow(
        id: String,
        name: String,
        detail: String?,
        isLocal: Bool,
        isCreator: Bool,
        friendshipState: MeshRoomFriendshipState?
    ) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(isLocal ? Color.accentColor : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                    if isLocal {
                        Text(String(localized: "You"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if isCreator {
                        Text(String(localized: "Creator"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isLocal {
                HStack(spacing: 8) {
                    friendshipControl(
                        participantID: id,
                        state: friendshipState ?? .available
                    )
                    if model.snapshot.isLocalCreator {
                        Button(role: .destructive) {
                            model.removeParticipant(id)
                        } label: {
                            Image(
                                systemName:
                                    "person.crop.circle.badge.minus"
                            )
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Remove from room"))
                        .accessibilityLabel(
                            String(localized: "Remove from room")
                        )
                        .accessibilityIdentifier(
                            "clip.meshRoom.participant.remove.\(id)"
                        )
                    }
                }
            }
        }
        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
        .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
    }

    @ViewBuilder
    private func friendshipControl(
        participantID: String,
        state: MeshRoomFriendshipState
    ) -> some View {
        switch state {
        case .available:
            ClipPopoverButton(
                String(localized: "Add Friend"),
                systemImage: "person.badge.plus",
                prominence: .secondary,
                accessibilityIdentifier:
                    "clip.meshRoom.participant.addFriend.\(participantID)"
            ) {
                model.addFriend(participantID)
            }
        case .incomingRequest:
            Label(
                String(localized: "Needs Reply"),
                systemImage: "person.crop.circle.badge.questionmark"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.blue)
        case .requestPending:
            Label(
                String(localized: "Request Sent"),
                systemImage: "clock"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        case .trusted:
            Label(
                String(localized: "Friend"),
                systemImage: "person.crop.circle.badge.checkmark"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
        case .failed:
            ClipPopoverButton(
                String(localized: "Retry"),
                systemImage: "arrow.clockwise",
                prominence: .secondary,
                accessibilityIdentifier:
                    "clip.meshRoom.participant.retryFriend.\(participantID)"
            ) {
                model.retryFriendship(participantID)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.snapshot.phase.isTerminal {
            ClipPopoverButton(
                String(localized: "Try Again"),
                systemImage: "arrow.clockwise",
                prominence: .primary,
                size: .bottom,
                fillsWidth: true,
                accessibilityIdentifier: "clip.meshRoom.retry",
                action: model.retry
            )
        } else {
            VStack(spacing: 8) {
                if model.snapshot.hasLocalMedia {
                    ClipPopoverButton(
                        String(localized: "Stop Sharing"),
                        systemImage: "stop.circle",
                        size: .bottom,
                        fillsWidth: true,
                        accessibilityIdentifier:
                            "clip.meshRoom.stopLocalMedia",
                        action: model.stopLocalMedia
                    )
                }

                HStack(spacing: 8) {
                    ClipPopoverButton(
                        String(localized: "Leave Room"),
                        systemImage:
                            "rectangle.portrait.and.arrow.right",
                        size: .bottom,
                        fillsWidth: true,
                        isEnabled: model.snapshot.canLeaveRoom,
                        accessibilityIdentifier: "clip.meshRoom.leave",
                        action: model.leaveRoom
                    )

                    if model.snapshot.isLocalCreator {
                        Button(role: .destructive) {
                            model.endRoomForEveryone()
                        } label: {
                            Label(
                                String(localized: "End for Everyone"),
                                systemImage: "xmark.circle.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(
                            ClipPopoverButtonStyle(
                                prominence: .destructive,
                                size: .bottom,
                                fillsWidth: true
                            )
                        )
                        .disabled(!model.snapshot.canEndRoom)
                        .accessibilityIdentifier("clip.meshRoom.end")
                    }
                }
            }
        }
    }

    private var groupedAvailableApplications:
        [(name: String, windows: [LiveShareAvailableWindowViewSnapshot])]
    {
        Dictionary(
            grouping: model.snapshot.availableWindows,
            by: \.applicationName
        )
        .map { (name: $0.key, windows: $0.value) }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }
}

private struct MeshRoomSourceRow<Trailing: View, Controls: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    private let trailing: Trailing
    private let controls: Controls

    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder controls: () -> Controls
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.trailing = trailing()
        self.controls = controls()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                trailing
            }
            controls
        }
        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
        .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MeshRoomSourceRow where Controls == EmptyView {
    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: title,
            detail: detail,
            systemImage: systemImage,
            trailing: trailing,
            controls: { EmptyView() }
        )
    }
}

private struct MeshRoomSettingRow<Content: View>: View {
    let title: String
    let detail: String?
    private let content: Content

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            content
        }
        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
        .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
        .frame(maxWidth: .infinity)
    }
}

private struct MeshRoomMediaDiagnosticsRow: View {
    let diagnostics: MeshRoomMediaDiagnosticsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(diagnostics.sourceName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(codecAndResolution)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                metric(
                    String(localized: "FPS"),
                    diagnostics.framesPerSecond.formatted(
                        .number.precision(.fractionLength(0...1))
                    )
                )
                metric(
                    String(localized: "Rate"),
                    formatBitrate(diagnostics.bitsPerSecond)
                )
                metric(
                    String(localized: "Drops"),
                    "\(diagnostics.droppedFrames)"
                )
                if diagnostics.queuePressureDrops > 0 {
                    metric(
                        String(localized: "Queue"),
                        "\(diagnostics.queuePressureDrops)"
                    )
                } else if let reason = diagnostics.queuePressureReason {
                    metric(
                        String(localized: "Pressure"),
                        reason.capitalized
                    )
                }
                if let latency =
                    diagnostics.processingLatencyMilliseconds {
                    metric(
                        diagnostics.direction == .outgoing
                            ? String(localized: "Encode")
                            : String(localized: "Buffer"),
                        "\(Int(latency.rounded())) ms"
                    )
                }
            }
        }
        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
        .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
    }

    private var codecAndResolution: String {
        let codec = diagnostics.codec ?? String(localized: "Unknown")
        guard diagnostics.width > 0, diagnostics.height > 0 else {
            return codec
        }
        return "\(codec) · \(diagnostics.width)×\(diagnostics.height)"
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MeshRoomPeerDiagnosticsRow: View {
    let peer: MeshRoomPeerDiagnosticsSnapshot

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(peer.route.isConnected ? .green : .orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.subheadline.weight(.medium))
                Text(peerConnectionDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let roundTrip = peer.roundTripMilliseconds {
                    Text("\(Int(roundTrip.rounded())) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let available = peer.availableOutgoingBitrateBps {
                    Text(
                        String(
                            localized:
                                "\(formatBitrate(Int(min(available, Double(Int.max))))) available"
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Text(
                String(localized: "\(peer.packetsLost) lost")
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(peer.packetsLost > 0 ? .orange : .secondary)
        }
        .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
        .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
    }

    private var peerConnectionDetail: String {
        let sent = formatByteCount(peer.bytesSent)
        let received = formatByteCount(peer.bytesReceived)
        return "\(peer.route.title) · ↑ \(sent) · ↓ \(received)"
    }
}

private struct MeshRoomNoticeView: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct MeshRoomEmptyCardMessage: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
            .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
    }
}

private func formatBitrate(_ bitsPerSecond: Int) -> String {
    if bitsPerSecond >= 1_000_000 {
        let megabits = Double(bitsPerSecond) / 1_000_000
        return "\(megabits.formatted(.number.precision(.fractionLength(0...1)))) Mbps"
    }
    return "\(bitsPerSecond / 1_000) kbps"
}

private func formatByteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(
        fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
        countStyle: .file
    )
}

/// Reusable entry point for editing codec-specific sender controls. This is
/// native-v3 participant UI shared by the room popover and Settings.
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
                onApply: { value in
                    onApply(codec, value)
                    isPresented = false
                },
                onCancel: { isPresented = false }
            )
        }
    }
}

private struct LiveShareAdvancedCodecSettingsEditor: View {
    let codec: LiveShareVideoCodec
    let current: LiveShareCodecAdvancedSettings
    let onApply: (LiveShareCodecAdvancedSettings) -> Void
    let onCancel: () -> Void

    @State private var draft: LiveShareCodecAdvancedSettings

    init(
        codec: LiveShareVideoCodec,
        current: LiveShareCodecAdvancedSettings,
        onApply: @escaping (LiveShareCodecAdvancedSettings) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.codec = codec
        self.current = current
        self.onApply = onApply
        self.onCancel = onCancel
        _draft = State(initialValue: current.normalized(for: codec))
    }

    var body: some View {
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
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }

            Divider()

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
                    .accessibilityIdentifier(
                        "clip.liveShare.codec.advanced.cancel"
                    )
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
                .accessibilityIdentifier(
                    "clip.liveShare.codec.advanced.apply"
                )
            }
            .padding(12)
        }
        .frame(width: 370, height: codec == .h264 ? 565 : 425)
        .accessibilityIdentifier("clip.liveShare.codec.advanced.editor")
        .onChange(of: current) { _, value in
            draft = value.normalized(for: codec)
        }
    }

    private var settingsControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            optionalIntegerControl(
                title: "Requested Bitrate Floor",
                value: $draft.minimumBitratePercent,
                defaultValue: 25,
                range:
                    LiveShareCodecAdvancedSettings.minimumBitratePercentRange,
                step: 5,
                suffix: "%"
            )
            advancedControl("Congestion Behavior") {
                Picker(
                    "Congestion Behavior",
                    selection: $draft.degradationPreference
                ) {
                    ForEach(
                        LiveShareDegradationPreference.allCases
                    ) { preference in
                        Text(preference.advancedTitle).tag(preference)
                    }
                }
                .labelsHidden()
            }
            advancedControl("Temporal Layers") {
                Picker("Temporal Layers", selection: $draft.temporalLayerCount) {
                    Text("Auto").tag(nil as Int?)
                    ForEach(
                        LiveShareCodecAdvancedSettings.temporalLayerCountRange,
                        id: \.self
                    ) {
                        Text("L1T\($0)").tag(Optional($0))
                    }
                }
                .labelsHidden()
            }
            advancedControl("Resolution Scale") {
                Picker(
                    "Resolution Scale",
                    selection: $draft.scaleResolutionDownBy
                ) {
                    Text("Auto · Native").tag(nil as Double?)
                    Text("Native · 1×").tag(Optional(1.0))
                    Text("80% · 1.25×").tag(Optional(1.25))
                    Text("67% · 1.5×").tag(Optional(1.5))
                    Text("50% · 2×").tag(Optional(2.0))
                }
                .labelsHidden()
            }
            if codec == .h264 {
                optionalIntegerControl(
                    title: "Maximum QP",
                    value: $draft.maximumQuantizer,
                    defaultValue: 38,
                    range:
                        LiveShareCodecAdvancedSettings
                        .h264MaximumQuantizerRange
                )
                optionalIntegerControl(
                    title: "VideoToolbox Quality",
                    value: $draft.h264QualityPercent,
                    defaultValue: 98,
                    range:
                        LiveShareCodecAdvancedSettings
                        .h264QualityPercentRange,
                    suffix: "%"
                )
                optionalIntegerControl(
                    title: "Keyframe Interval",
                    value: $draft.h264KeyFrameIntervalSeconds,
                    defaultValue: 2,
                    range:
                        LiveShareCodecAdvancedSettings
                        .h264KeyFrameIntervalSecondsRange,
                    suffix: " s"
                )
            }
        }
    }

    private var explanation: String {
        if codec == .h264 {
            return String(
                localized:
                    "Auto uses Clip and WebRTC defaults. Lower maximum QP preserves more detail but can increase frame drops or latency when bandwidth is constrained."
            )
        }
        return String(
            localized:
                "Auto uses WebRTC's codec defaults. Sender controls still apply without replacing the built-in encoder."
        )
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

    private func optionalIntegerControl(
        title: LocalizedStringKey,
        value: Binding<Int?>,
        defaultValue: Int,
        range: ClosedRange<Int>,
        step: Int = 1,
        suffix: String = ""
    ) -> some View {
        advancedControl(title) {
            HStack {
                Toggle(
                    "Custom",
                    isOn: Binding(
                        get: { value.wrappedValue != nil },
                        set: { enabled in
                            value.wrappedValue =
                                enabled
                                ? (value.wrappedValue ?? defaultValue)
                                : nil
                        }
                    )
                )
                .toggleStyle(.switch)
                Spacer()
                if value.wrappedValue != nil {
                    Stepper(
                        value: Binding(
                            get: { value.wrappedValue ?? defaultValue },
                            set: { value.wrappedValue = $0 }
                        ),
                        in: range,
                        step: step
                    ) {
                        Text(
                            "\(value.wrappedValue ?? defaultValue)\(suffix)"
                        )
                        .monospacedDigit()
                    }
                } else {
                    Text("Auto")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension LiveShareDegradationPreference {
    var advancedTitle: String {
        switch self {
        case .automatic:
            String(localized: "Auto · Follow Mode")
        case .preserveResolution:
            String(localized: "Preserve Resolution")
        case .balanced:
            String(localized: "Balanced")
        case .preserveFrameRate:
            String(localized: "Preserve Frame Rate")
        case .disabled:
            String(localized: "Disable Adaptation")
        }
    }
}
