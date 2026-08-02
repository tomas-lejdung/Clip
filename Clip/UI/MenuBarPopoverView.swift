import AppKit
import ClipCore
import ClipLiveShare
import CoreGraphics
import Foundation
import SwiftUI

enum MenuBarApplicationVersion {
    static var currentDisplayString: String? {
        displayString(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static func displayString(infoDictionary: [String: Any]) -> String? {
        guard let rawVersion = infoDictionary["CFBundleShortVersionString"] as? String else {
            return nil
        }
        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return nil }
        return "v\(version)"
    }
}

struct MenuBarDisplayRow: Equatable, Identifiable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int

    init(
        id: CGDirectDisplayID,
        name: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.name = name
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
    }

    init(display: ClipDisplay) {
        self.init(
            id: display.id,
            name: display.name,
            pixelWidth: Int((display.frame.width * display.scaleFactor).rounded()),
            pixelHeight: Int((display.frame.height * display.scaleFactor).rounded())
        )
    }

    var resolution: String {
        "\(pixelWidth) × \(pixelHeight)"
    }
}

struct MenuBarRecentRecordingRow: Equatable, Identifiable, Sendable {
    let id: RecordingID
    let filename: String
    let byteCount: Int64

    init(id: RecordingID, filename: String, byteCount: Int64) {
        self.id = id
        self.filename = filename
        self.byteCount = max(0, byteCount)
    }

    init(item: RecordingHistoryItem) {
        self.init(
            id: item.id,
            filename: item.filename.stem,
            byteCount: item.managedByteCount
        )
    }

    var formattedByteCount: String {
        MenuBarFormatting.byteCount(byteCount)
    }
}

struct MenuBarAudioState: Equatable, Sendable {
    var isEnabled: Bool
    var isAvailable: Bool
    var detail: String?

    init(
        isEnabled: Bool = false,
        isAvailable: Bool = true,
        detail: String? = nil
    ) {
        self.isEnabled = isEnabled && isAvailable
        self.isAvailable = isAvailable
        self.detail = detail
    }

    var status: String {
        guard isAvailable else { return String(localized: "Unavailable") }
        return isEnabled ? String(localized: "On") : String(localized: "Off")
    }
}

struct MenuBarLiveShareFriendRow: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let deviceName: String
    let isOnline: Bool
    let issue: String?

    init(
        id: String,
        displayName: String,
        deviceName: String,
        isOnline: Bool,
        issue: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.deviceName = deviceName
        self.isOnline = isOnline
        self.issue = issue
    }

    var status: String {
        isOnline
            ? String(localized: "Room Available")
            : String(localized: "No Room")
    }
}

enum MenuBarServerRoomInviteEntry {
    static func parse(_ value: String) -> ClipLiveShareServerRoomV4Invite? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed) else {
            return nil
        }
        return try? ClipLiveShareServerRoomV4Invite(url: url)
    }
}

enum MenuBarServerRoomAccessWord {
    static let maximumUTF8ByteCount = 256

    /// Matches the v4 admission policy's canonical access-word form without
    /// coupling the menu to the proof implementation itself.
    static func normalize(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).uppercased()
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumUTF8ByteCount else {
            return nil
        }
        return normalized
    }
}

struct MenuBarServerRoomJoinRequest: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let invite: ClipLiveShareServerRoomV4Invite
    let accessWord: String?
    /// Saved-friend presence joins always ask the room creator to confirm the
    /// admission, independent of the room's general approval preference.
    let requiresCreatorApproval: Bool

    init(
        invite: ClipLiveShareServerRoomV4Invite,
        accessWord: String?,
        requiresCreatorApproval: Bool = false
    ) {
        self.invite = invite
        self.accessWord = accessWord.flatMap(
            MenuBarServerRoomAccessWord.normalize
        )
        self.requiresCreatorApproval = requiresCreatorApproval
    }

    var description: String {
        "MenuBarServerRoomJoinRequest("
            + "invite: <redacted>, "
            + "accessWord: \(accessWord == nil ? "<none>" : "<redacted>"), "
            + "requiresCreatorApproval: \(requiresCreatorApproval))"
    }

    var debugDescription: String { description }
}

enum MenuBarLiveShareConnectionStatus: Equatable, Sendable {
    case idle
    case creating
    case joining(roomName: String)
    case accessWordRequired(
        roomName: String,
        invite: ClipLiveShareServerRoomV4Invite,
        requiresCreatorApproval: Bool
    )
    case awaitingApproval(roomName: String)

    enum PaneContent: Equatable {
        case entry
        case connection
        case accessWord
    }

    var paneContent: PaneContent {
        switch self {
        case .idle:
            .entry
        case .accessWordRequired:
            .accessWord
        case .creating, .joining, .awaitingApproval:
            .connection
        }
    }

    var title: String {
        switch self {
        case .idle:
            ""
        case .creating:
            String(localized: "Creating Room…")
        case .joining:
            String(localized: "Joining…")
        case .accessWordRequired:
            String(localized: "Access Word Required")
        case .awaitingApproval:
            String(localized: "Waiting for Approval")
        }
    }

    var detail: String {
        switch self {
        case .idle:
            ""
        case .creating:
            String(localized: "Preparing a secure room invitation.")
        case let .joining(roomName):
            String(localized: "Connecting securely to \(roomName).")
        case let .accessWordRequired(roomName, _, _):
            String(
                localized:
                    "Enter the Access Word for \(roomName) to continue."
            )
        case let .awaitingApproval(roomName):
            String(
                localized:
                    "The room creator of \(roomName) must allow you before you can join."
            )
        }
    }

    var accessWordInvite: ClipLiveShareServerRoomV4Invite? {
        guard case let .accessWordRequired(_, invite, _) = self else {
            return nil
        }
        return invite
    }

    var accessWordRequiresCreatorApproval: Bool {
        guard case let .accessWordRequired(
            _, _, requiresCreatorApproval
        ) = self else {
            return false
        }
        return requiresCreatorApproval
    }
}

enum MenuBarFriendPresencePolicy {
    static func rows(
        from snapshot: MeshFriendPresenceControllerSnapshot
    ) -> [MenuBarLiveShareFriendRow] {
        snapshot.friends.map { friend in
            .init(
                id: friend.id,
                displayName: friend.displayName,
                deviceName: friend.deviceName,
                isOnline: friend.availability == .online,
                issue: friend.issue
            )
        }
    }

    /// Only an unexpired, identity-verified presence record is joinable.
    /// Saved-friend discovery never downgrades to an old or user-pasted URL.
    static func verifiedJoinRequest(
        friendID: String,
        snapshot: MeshFriendPresenceControllerSnapshot
    ) -> MenuBarServerRoomJoinRequest? {
        guard let friend = snapshot.friends.first(where: {
            $0.id == friendID
        }), friend.availability == .online,
        let invite = friend.verifiedInvite else {
            return nil
        }
        return .init(
            invite: invite,
            accessWord: nil,
            requiresCreatorApproval: true
        )
    }
}

@MainActor
final class MenuBarPopoverModel: ObservableObject {
    static let recentRecordingLimit = 3

    @Published private(set) var displays: [MenuBarDisplayRow]
    @Published private(set) var preparedDisplayID: CGDirectDisplayID?
    @Published private(set) var microphone: MenuBarAudioState
    @Published private(set) var systemAudio: MenuBarAudioState
    @Published private(set) var showClickHighlights: Bool
    @Published private(set) var recentRecordings: [MenuBarRecentRecordingRow]
    @Published private(set) var isLastAreaAvailable: Bool
    @Published private(set) var isFullscreenAvailable: Bool
    @Published private(set) var liveShareConnectionStatus:
        MenuBarLiveShareConnectionStatus
    @Published private(set) var liveShareFriends:
        [MenuBarLiveShareFriendRow]

    init(
        displays: [MenuBarDisplayRow] = [],
        preparedDisplayID: CGDirectDisplayID? = nil,
        microphone: MenuBarAudioState = .init(),
        systemAudio: MenuBarAudioState = .init(),
        showClickHighlights: Bool = false,
        recentRecordings: [MenuBarRecentRecordingRow] = [],
        isLastAreaAvailable: Bool = false,
        isFullscreenAvailable: Bool = false,
        liveShareFriends: [MenuBarLiveShareFriendRow] = [],
        liveShareConnectionStatus:
            MenuBarLiveShareConnectionStatus = .idle
    ) {
        self.displays = displays
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.showClickHighlights = showClickHighlights
        self.recentRecordings = Array(recentRecordings.prefix(Self.recentRecordingLimit))
        self.isLastAreaAvailable = isLastAreaAvailable
        self.isFullscreenAvailable = isFullscreenAvailable
        self.liveShareFriends = liveShareFriends
        self.liveShareConnectionStatus = liveShareConnectionStatus
        self.preparedDisplayID = displays.contains(where: { $0.id == preparedDisplayID })
            ? preparedDisplayID
            : nil
    }

    var preparedDisplay: MenuBarDisplayRow? {
        displays.first { $0.id == preparedDisplayID }
    }

    func replaceDisplays(_ displays: [MenuBarDisplayRow]) {
        self.displays = displays
        isFullscreenAvailable = !displays.isEmpty
        if !displays.contains(where: { $0.id == preparedDisplayID }) {
            preparedDisplayID = nil
        }
    }

    func prepareDisplay(id: CGDirectDisplayID?) {
        preparedDisplayID = displays.contains(where: { $0.id == id }) ? id : nil
    }

    func setLastAreaAvailable(_ isAvailable: Bool) {
        isLastAreaAvailable = isAvailable
    }

    func setMicrophone(_ state: MenuBarAudioState) {
        microphone = state
    }

    func setSystemAudio(_ state: MenuBarAudioState) {
        systemAudio = state
    }

    func setMicrophoneEnabled(_ isEnabled: Bool) {
        microphone.isEnabled = isEnabled && microphone.isAvailable
    }

    func setSystemAudioEnabled(_ isEnabled: Bool) {
        systemAudio.isEnabled = isEnabled && systemAudio.isAvailable
    }

    func setClickHighlightsEnabled(_ isEnabled: Bool) {
        showClickHighlights = isEnabled
    }

    func replaceRecentRecordings(_ recordings: [MenuBarRecentRecordingRow]) {
        recentRecordings = Array(recordings.prefix(Self.recentRecordingLimit))
    }

    func setLiveShareConnectionStatus(
        _ status: MenuBarLiveShareConnectionStatus
    ) {
        liveShareConnectionStatus = status
    }

    func replaceLiveShareFriends(
        _ friends: [MenuBarLiveShareFriendRow]
    ) {
        liveShareFriends = friends.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            let order = $0.displayName.localizedCaseInsensitiveCompare(
                $1.displayName
            )
            return order == .orderedSame
                ? $0.id < $1.id
                : order == .orderedAscending
        }
    }
}

@MainActor
struct MenuBarActions {
    let createLiveShareRoom: () -> Void
    let joinLiveShareInvite: (MenuBarServerRoomJoinRequest) -> Void
    let joinLiveShareFriend: (String) -> Void
    let removeLiveShareFriend: (String) -> Void
    let captureArea: () -> Void
    let lastArea: () -> Void
    let fullscreen: () -> Void
    let captureApplication: () -> Void
    let prepareDisplay: (CGDirectDisplayID) -> Void
    let recordPreparedDisplay: (CGDirectDisplayID) -> Void
    let setMicrophoneEnabled: (Bool) -> Void
    let setSystemAudioEnabled: (Bool) -> Void
    let setClickHighlightsEnabled: (Bool) -> Void
    let openRecentRecording: (RecordingID) -> Void
    let openHistory: () -> Void
    let openSettings: () -> Void
    let checkForUpdates: () -> Void
    let quit: () -> Void

    init(
        createLiveShareRoom: @escaping () -> Void = {},
        joinLiveShareInvite: @escaping (
            MenuBarServerRoomJoinRequest
        ) -> Void = { _ in },
        joinLiveShareFriend: @escaping (String) -> Void = { _ in },
        removeLiveShareFriend: @escaping (String) -> Void = { _ in },
        captureArea: @escaping () -> Void,
        lastArea: @escaping () -> Void,
        fullscreen: @escaping () -> Void,
        captureApplication: @escaping () -> Void = {},
        prepareDisplay: @escaping (CGDirectDisplayID) -> Void = { _ in },
        recordPreparedDisplay: @escaping (CGDirectDisplayID) -> Void = { _ in },
        setMicrophoneEnabled: @escaping (Bool) -> Void = { _ in },
        setSystemAudioEnabled: @escaping (Bool) -> Void = { _ in },
        setClickHighlightsEnabled: @escaping (Bool) -> Void = { _ in },
        openRecentRecording: @escaping (RecordingID) -> Void = { _ in },
        openHistory: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void = {},
        quit: @escaping () -> Void
    ) {
        self.createLiveShareRoom = createLiveShareRoom
        self.joinLiveShareInvite = joinLiveShareInvite
        self.joinLiveShareFriend = joinLiveShareFriend
        self.removeLiveShareFriend = removeLiveShareFriend
        self.captureArea = captureArea
        self.lastArea = lastArea
        self.fullscreen = fullscreen
        self.captureApplication = captureApplication
        self.prepareDisplay = prepareDisplay
        self.recordPreparedDisplay = recordPreparedDisplay
        self.setMicrophoneEnabled = setMicrophoneEnabled
        self.setSystemAudioEnabled = setSystemAudioEnabled
        self.setClickHighlightsEnabled = setClickHighlightsEnabled
        self.openRecentRecording = openRecentRecording
        self.openHistory = openHistory
        self.openSettings = openSettings
        self.checkForUpdates = checkForUpdates
        self.quit = quit
    }
}

enum MenuBarPopoverRoute: Equatable {
    case main
    case liveShare
}

struct MenuBarPopoverView: View {
    static let contentWidth = ClipPopoverDesign.width
    /// Fallback used only if synchronous SwiftUI fitting-size measurement is
    /// unavailable.
    static let contentSize = CGSize(width: contentWidth, height: 980)

    @StateObject private var model: MenuBarPopoverModel
    @State private var serverRoomInviteEntry = ""
    @State private var serverRoomAccessWord = ""
    @State private var route: MenuBarPopoverRoute = .main
    let actions: MenuBarActions
    private let maximumHeight: CGFloat
    private let onContentHeightChange: (CGFloat) -> Void

    init(
        model: MenuBarPopoverModel,
        actions: MenuBarActions,
        initialRoute: MenuBarPopoverRoute = .main,
        maximumHeight: CGFloat = 10_000,
        onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: model)
        _route = State(initialValue: initialRoute)
        self.actions = actions
        self.maximumHeight = maximumHeight
        self.onContentHeightChange = onContentHeightChange
    }

    @ViewBuilder
    var body: some View {
        switch route {
        case .main:
            mainPane
        case .liveShare:
            liveSharePane
        }
    }

    private var mainPane: some View {
        ClipPopoverPane(
            maximumHeight: maximumHeight,
            onContentHeightChange: onContentHeightChange,
            icon: "record.circle",
            title: String(localized: "Clip"),
            subtitle: model.preparedDisplay == nil
                ? String(localized: "Ready to record")
                : String(localized: "Capture target prepared"),
            accessibilityIdentifier: "clip.menuBarPopover",
            headerTrailing: {
                version
            },
            content: {
                captureSection
                if let preparedDisplay = model.preparedDisplay {
                    preparedTargetSection(preparedDisplay)
                }
                quickSettingsSection
                if !model.recentRecordings.isEmpty {
                    recentRecordingsSection
                }
                applicationSection
            }
        )
    }

    private var liveSharePane: some View {
        ClipPopoverPane(
            maximumHeight: maximumHeight,
            onContentHeightChange: onContentHeightChange,
            icon: "dot.radiowaves.left.and.right",
            title: String(localized: "Live Share"),
            subtitle: String(localized: "Create or join a room"),
            backTitle: String(localized: "Clip"),
            onBack: { route = .main },
            accessibilityIdentifier: "clip.menuBarPopover.liveShare",
            headerTrailing: {
                version
            },
            content: {
                liveShareSection
            }
        )
    }

    @ViewBuilder
    private var version: some View {
        if let version = MenuBarApplicationVersion.currentDisplayString {
            Text(verbatim: version)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
                .accessibilityLabel(
                    Text(verbatim: "Version \(version.dropFirst())")
                )
                .accessibilityIdentifier("clip.menu.version")
        }
    }

    private var captureSection: some View {
        ClipPopoverSection(String(localized: "Capture")) {
            VStack(spacing: 0) {
                actionRow(
                    String(localized: "Capture Area"),
                    systemImage: "viewfinder",
                    identifier: "clip.menu.captureArea",
                    action: actions.captureArea
                )

                if model.isLastAreaAvailable {
                    ClipPopoverRowDivider()
                    actionRow(
                        String(localized: "Last Area"),
                        systemImage: "rectangle.dashed",
                        identifier: "clip.menu.lastArea",
                        action: actions.lastArea
                    )
                }

                ClipPopoverRowDivider()
                actionRow(
                    String(localized: "Capture App…"),
                    systemImage: "app.badge.checkmark",
                    identifier: "clip.menu.captureApplication",
                    action: actions.captureApplication
                )

                if model.isFullscreenAvailable {
                    ClipPopoverRowDivider()
                    actionRow(
                        String(localized: "Fullscreen"),
                        systemImage: "macwindow",
                        identifier: "clip.menu.fullscreen",
                        action: actions.fullscreen
                    )
                }

                ForEach(model.displays) { display in
                    ClipPopoverRowDivider()
                    ClipPopoverActionRow(
                        display.name,
                        systemImage: model.preparedDisplayID == display.id
                            ? "checkmark.circle.fill"
                            : "display",
                        accessibilityIdentifier: "clip.menu.display.\(display.id)",
                        action: {
                            model.prepareDisplay(id: display.id)
                            actions.prepareDisplay(display.id)
                        }
                    ) {
                        Text(display.resolution)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("\(display.name), \(display.resolution)")
                }

                ClipPopoverRowDivider()
                actionRow(
                    String(localized: "Live Share"),
                    systemImage: "dot.radiowaves.left.and.right",
                    identifier: "clip.menu.liveShare"
                ) {
                    route = .liveShare
                }
            }
        }
    }

    @ViewBuilder
    private var liveShareSection: some View {
        switch model.liveShareConnectionStatus.paneContent {
        case .entry:
            liveShareEntrySection
        case .connection:
            liveShareConnectionSection
        case .accessWord:
            liveShareAccessWordSection
        }
    }

    @ViewBuilder
    private var liveShareEntrySection: some View {
        ClipPopoverSection(String(localized: "Room")) {
            VStack(spacing: 0) {
                actionRow(
                    String(localized: "Create Room"),
                    systemImage: "person.2.badge.plus",
                    identifier: "clip.menu.liveShare.createRoom",
                    action: actions.createLiveShareRoom
                )

                ClipPopoverRowDivider()

                VStack(alignment: .leading, spacing: 7) {
                    Text(String(localized: "Join Invite"))
                        .font(.subheadline.weight(.medium))

                    HStack(spacing: 8) {
                        TextField(
                            String(localized: "Paste a Clip room invite"),
                            text: $serverRoomInviteEntry
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1)
                        .accessibilityIdentifier(
                            "clip.menu.liveShare.invite"
                        )
                        .onSubmit(joinLiveShareInvite)

                        ClipPopoverButton(
                            String(localized: "Join"),
                            systemImage: "arrow.right",
                            prominence: .primary,
                            isEnabled: parsedServerRoomInvite != nil,
                            accessibilityIdentifier:
                                "clip.menu.liveShare.join",
                            action: joinLiveShareInvite
                        )
                    }

                    SecureField(
                        String(localized: "Access Word (optional)"),
                        text: $serverRoomAccessWord
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                    .accessibilityIdentifier(
                        "clip.menu.liveShare.accessWord"
                    )
                    .onSubmit(joinLiveShareInvite)

                    Text(inviteEntryGuidance)
                        .font(.caption2)
                        .foregroundStyle(
                            serverRoomInviteEntry.isEmpty
                                || parsedServerRoomInvite != nil
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(.red)
                        )
                        .accessibilityIdentifier(
                            "clip.menu.liveShare.inviteStatus"
                        )
                }
                .padding(
                    .horizontal,
                    ClipPopoverDesign.rowHorizontalPadding
                )
                .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
            }
        }

        ClipPopoverSection(
            model.liveShareFriends.isEmpty
                ? String(localized: "Friends")
                : String(
                    localized:
                        "Friends · \(model.liveShareFriends.count)"
                )
        ) {
            if model.liveShareFriends.isEmpty {
                Text(
                    String(
                        localized:
                            "Friends you add from a room will appear here."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(
                    .horizontal,
                    ClipPopoverDesign.rowHorizontalPadding
                )
                .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
            } else {
                VStack(spacing: 0) {
                    ForEach(
                        Array(model.liveShareFriends.enumerated()),
                        id: \.element.id
                    ) { index, friend in
                        Button {
                            if friend.isOnline {
                                actions.joinLiveShareFriend(friend.id)
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(
                                        friend.isOnline
                                            ? Color.green
                                            : Color.secondary.opacity(0.45)
                                    )
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.displayName)
                                        .font(.subheadline.weight(.medium))
                                    Text(friend.deviceName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(friend.status)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(
                                        friend.isOnline
                                            ? Color.green
                                            : Color.secondary
                                    )
                            }
                            .padding(
                                .horizontal,
                                ClipPopoverDesign.rowHorizontalPadding
                            )
                            .padding(
                                .vertical,
                                ClipPopoverDesign.rowVerticalPadding
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .modifier(
                            ClipPopoverHoverEffect(
                                isInteractive: friend.isOnline
                            )
                        )
                        .help(friend.issue ?? friend.status)
                        .accessibilityIdentifier(
                            "clip.menu.liveShare.friend.\(friend.id)"
                        )
                        .contextMenu {
                            Button(
                                String(localized: "Remove Friend"),
                                role: .destructive
                            ) {
                                actions.removeLiveShareFriend(friend.id)
                            }
                        }

                        if index < model.liveShareFriends.count - 1 {
                            ClipPopoverRowDivider(leadingInset: 28)
                        }
                    }
                }
            }
        }
    }

    private var liveShareConnectionSection: some View {
        ClipPopoverSection(String(localized: "Room")) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.liveShareConnectionStatus.title)
                        .font(.subheadline.weight(.semibold))
                    Text(model.liveShareConnectionStatus.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
            .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                "clip.menu.liveShare.connectionStatus"
            )
        }
    }

    private var liveShareAccessWordSection: some View {
        ClipPopoverSection(String(localized: "Room")) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.liveShareConnectionStatus.title)
                        .font(.subheadline.weight(.semibold))
                    Text(model.liveShareConnectionStatus.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    SecureField(
                        String(localized: "Access Word"),
                        text: $serverRoomAccessWord
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                    .accessibilityIdentifier(
                        "clip.menu.liveShare.requiredAccessWord"
                    )
                    .onSubmit(submitRequiredAccessWord)

                    ClipPopoverButton(
                        String(localized: "Continue"),
                        systemImage: "arrow.right",
                        prominence: .primary,
                        isEnabled: canSubmitRequiredAccessWord,
                        accessibilityIdentifier:
                            "clip.menu.liveShare.submitAccessWord",
                        action: submitRequiredAccessWord
                    )
                }
            }
            .padding(.horizontal, ClipPopoverDesign.rowHorizontalPadding)
            .padding(.vertical, ClipPopoverDesign.rowVerticalPadding)
        }
    }

    private var canSubmitRequiredAccessWord: Bool {
        model.liveShareConnectionStatus.accessWordInvite != nil
            && MenuBarServerRoomAccessWord.normalize(
                serverRoomAccessWord
            ) != nil
    }

    private func submitRequiredAccessWord() {
        guard canSubmitRequiredAccessWord,
              let invite =
                model.liveShareConnectionStatus.accessWordInvite
        else { return }
        actions.joinLiveShareInvite(
            MenuBarServerRoomJoinRequest(
                invite: invite,
                accessWord: serverRoomAccessWord,
                requiresCreatorApproval:
                    model.liveShareConnectionStatus
                        .accessWordRequiresCreatorApproval
            )
        )
    }

    private var parsedServerRoomInvite: ClipLiveShareServerRoomV4Invite? {
        MenuBarServerRoomInviteEntry.parse(serverRoomInviteEntry)
    }

    private var inviteEntryGuidance: String {
        if serverRoomInviteEntry.isEmpty {
            return String(
                localized:
                    "Paste the complete invite from another Clip participant."
            )
        }
        return parsedServerRoomInvite == nil
            ? String(localized: "This is not a valid native Clip room invite.")
            : String(localized: "Ready to join this room.")
    }

    private func joinLiveShareInvite() {
        guard let invite = parsedServerRoomInvite else { return }
        actions.joinLiveShareInvite(
            MenuBarServerRoomJoinRequest(
                invite: invite,
                accessWord: serverRoomAccessWord
            )
        )
    }

    private func preparedTargetSection(_ display: MenuBarDisplayRow) -> some View {
        ClipPopoverSection(String(localized: "Prepared Target")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(display.resolution)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ClipPopoverButton(
                    String(localized: "Record"),
                    systemImage: "record.circle.fill",
                    prominence: .primary,
                    accessibilityIdentifier: "clip.menu.recordPrepared"
                ) {
                    actions.recordPreparedDisplay(display.id)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var quickSettingsSection: some View {
        ClipPopoverSection(String(localized: "Quick Settings")) {
            VStack(spacing: 0) {
                quickToggle(
                    title: String(localized: "Microphone"),
                    systemImage: "mic",
                    state: model.microphone,
                    identifier: "clip.menu.microphone",
                    isOn: Binding(
                        get: { model.microphone.isEnabled },
                        set: { enabled in
                            model.setMicrophoneEnabled(enabled)
                            actions.setMicrophoneEnabled(enabled)
                        }
                    )
                )
                ClipPopoverRowDivider()
                quickToggle(
                    title: String(localized: "System Audio"),
                    systemImage: "speaker.wave.2",
                    state: model.systemAudio,
                    identifier: "clip.menu.systemAudio",
                    isOn: Binding(
                        get: { model.systemAudio.isEnabled },
                        set: { enabled in
                            model.setSystemAudioEnabled(enabled)
                            actions.setSystemAudioEnabled(enabled)
                        }
                    )
                )
                ClipPopoverRowDivider()
                ClipPopoverToggleRow(
                    String(localized: "Click Highlights"),
                    systemImage: "cursorarrow.click",
                    status: model.showClickHighlights
                        ? String(localized: "On")
                        : String(localized: "Off"),
                    accessibilityIdentifier: "clip.menu.clickHighlights",
                    isOn: Binding(
                        get: { model.showClickHighlights },
                        set: { enabled in
                            model.setClickHighlightsEnabled(enabled)
                            actions.setClickHighlightsEnabled(enabled)
                        }
                    )
                )
                .help(
                    model.showClickHighlights
                        ? String(localized: "On")
                        : String(localized: "Off")
                )
            }
        }
    }

    private var recentRecordingsSection: some View {
        ClipPopoverSection(String(localized: "Recent Recordings")) {
            VStack(spacing: 0) {
                ForEach(Array(model.recentRecordings.enumerated()), id: \.element.id) {
                    index,
                    recording in
                    if index > 0 {
                        ClipPopoverRowDivider()
                    }
                    ClipPopoverActionRow(
                        recording.filename,
                        systemImage: "play.rectangle",
                        accessibilityIdentifier:
                            "clip.menu.recent.\(recording.id.description)",
                        action: {
                            actions.openRecentRecording(recording.id)
                        }
                    ) {
                        Text(recording.formattedByteCount)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(
                        "Open \(recording.filename), \(recording.formattedByteCount)"
                    )
                }
            }
        }
    }

    private var applicationSection: some View {
        ClipPopoverSection(String(localized: "Application")) {
            VStack(spacing: 0) {
                ClipPopoverNavigationRow(
                    String(localized: "History"),
                    systemImage: "clock.arrow.circlepath",
                    accessibilityIdentifier: "clip.menu.history",
                    action: actions.openHistory
                )
                ClipPopoverRowDivider()
                ClipPopoverNavigationRow(
                    String(localized: "Settings"),
                    systemImage: "gearshape",
                    accessibilityIdentifier: "clip.menu.settings",
                    action: actions.openSettings
                )
                ClipPopoverRowDivider()
                actionRow(
                    String(localized: "Check for Updates…"),
                    systemImage: "arrow.triangle.2.circlepath",
                    identifier: "clip.menu.checkForUpdates",
                    action: actions.checkForUpdates
                )
                ClipPopoverRowDivider()
                actionRow(
                    String(localized: "Quit Clip"),
                    systemImage: "power",
                    identifier: "clip.menu.quit",
                    action: actions.quit
                )
            }
        }
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        ClipPopoverActionRow(
            title,
            systemImage: systemImage,
            accessibilityIdentifier: identifier,
            action: action
        )
    }

    private func quickToggle(
        title: String,
        systemImage: String,
        state: MenuBarAudioState,
        identifier: String,
        isOn: Binding<Bool>
    ) -> some View {
        ClipPopoverToggleRow(
            title,
            systemImage: systemImage,
            status: state.status,
            isEnabled: state.isAvailable,
            accessibilityIdentifier: identifier,
            isOn: isOn
        )
        .help(state.detail ?? state.status)
    }
}

enum MenuBarFormatting {
    static func byteCount(_ byteCount: Int64) -> String {
        let bytes = max(0, byteCount)
        let units: [(threshold: Int64, divisor: Double, suffix: String)] = [
            (1_000_000_000, 1_000_000_000, "GB"),
            (1_000_000, 1_000_000, "MB"),
            (1_000, 1_000, "KB"),
        ]

        guard let unit = units.first(where: { bytes >= $0.threshold }) else {
            return "\(bytes) B"
        }
        let value = Double(bytes) / unit.divisor
        let formatted = value >= 10
            ? String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
            : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
                .replacingOccurrences(of: ".0", with: "")
        return "\(formatted) \(unit.suffix)"
    }
}

private struct MenuBarPopoverViewPreview: PreviewProvider {
    static var previews: some View {
        let first = MenuBarDisplayRow(
            id: 1,
            name: "Studio Display",
            pixelWidth: 5_120,
            pixelHeight: 2_880
        )
        return MenuBarPopoverView(
            model: MenuBarPopoverModel(
                displays: [
                    first,
                    MenuBarDisplayRow(
                        id: 2,
                        name: "External Display",
                        pixelWidth: 2_560,
                        pixelHeight: 1_440
                    ),
                ],
                preparedDisplayID: first.id,
                microphone: .init(detail: "MacBook Pro Microphone"),
                systemAudio: .init(),
                recentRecordings: [
                    .init(
                        id: RecordingID(UUID(uuidString: "A2C47771-A127-4873-8FD7-F47553283C80")!),
                        filename: "clip-20260717-104218",
                        byteCount: 3_800_000
                    )
                ],
                isLastAreaAvailable: true,
                isFullscreenAvailable: true
            ),
            actions: MenuBarActions(
                captureArea: {},
                lastArea: {},
                fullscreen: {},
                openHistory: {},
                openSettings: {},
                quit: {}
            )
        )
    }
}
