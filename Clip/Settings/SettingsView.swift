import AppKit
import Carbon.HIToolbox
import ClipCore
import ClipLiveShare
import OSLog
import SwiftUI

enum SettingsTab: String, CaseIterable, Hashable, Sendable {
    case general
    case recording
    case liveShare
    case export
    case storage
    case permissions

    static let initial: SettingsTab = .general

    var accessibilityIdentifier: String {
        "clip.settings.\(rawValue)"
    }
}

struct SettingsStorageSnapshot: Equatable, Sendable {
    let recordingCount: Int
    let indexedMasterByteCount: Int64
    let directoryMP4ByteCount: Int64
    let cleanupCandidateByteCount: Int64
    let untrackedMP4ByteCount: Int64

    init(
        recordingCount: Int,
        indexedMasterByteCount: Int64,
        directoryMP4ByteCount: Int64,
        cleanupCandidateByteCount: Int64,
        untrackedMP4ByteCount: Int64
    ) {
        self.recordingCount = recordingCount
        self.indexedMasterByteCount = indexedMasterByteCount
        self.directoryMP4ByteCount = directoryMP4ByteCount
        self.cleanupCandidateByteCount = cleanupCandidateByteCount
        self.untrackedMP4ByteCount = untrackedMP4ByteCount
    }

    init(_ usage: ManagedHistoryStorageUsage) {
        self.init(
            recordingCount: usage.itemCount,
            indexedMasterByteCount: usage.indexedMasterByteCount,
            directoryMP4ByteCount: usage.actualManagedMP4ByteCount,
            cleanupCandidateByteCount: usage.recognizedOrphanByteCount,
            untrackedMP4ByteCount: usage.untrackedMP4ByteCount
        )
    }
}

struct SettingsStorageActions: Sendable {
    let loadUsage: @MainActor @Sendable () async throws -> SettingsStorageSnapshot
    /// Clears Clip-owned history and returns a fresh snapshot. Implementations must not delete
    /// external Save As files or unknown MP4 files found in the managed-history directory.
    let clearHistory: @MainActor @Sendable () async throws -> SettingsStorageSnapshot
    let revealHistory: (@MainActor @Sendable () -> Void)?

    init(
        loadUsage: @escaping @MainActor @Sendable () async throws -> SettingsStorageSnapshot,
        clearHistory: @escaping @MainActor @Sendable () async throws -> SettingsStorageSnapshot,
        revealHistory: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.loadUsage = loadUsage
        self.clearHistory = clearHistory
        self.revealHistory = revealHistory
    }
}

/// Injects the few Settings actions that normally cross into AppKit/system UI. Deterministic
/// UI scenarios pass inert actions, so merely exercising their controls cannot open a panel,
/// Finder, or System Settings.
struct SettingsExternalActions: Sendable {
    let chooseDefaultSaveDirectory: @MainActor @Sendable (URL) async -> URL?
    let openSystemSettings: @MainActor @Sendable (URL) -> Void
    let revealHistoryDirectory: @MainActor @Sendable (URL) -> Void
    let testLiveShareServer: @MainActor @Sendable (ClipLiveShareServerEndpoint) async throws -> Void

    init(
        chooseDefaultSaveDirectory: @escaping @MainActor @Sendable (URL) async -> URL? = {
            initialDirectory in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.resolvesAliases = true
            panel.directoryURL = initialDirectory
            panel.prompt = String(localized: "Choose")
            panel.message = String(
                localized: "Choose the folder Clip shows first when you use Save As."
            )
            guard await panel.begin() == .OK else { return nil }
            return panel.url
        },
        openSystemSettings: @escaping @MainActor @Sendable (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        },
        revealHistoryDirectory: @escaping @MainActor @Sendable (URL) -> Void = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        },
        testLiveShareServer: @escaping @MainActor @Sendable (
            ClipLiveShareServerEndpoint
        ) async throws -> Void = { endpoint in
            try await LiveShareServerConnectionProbe.live.test(endpoint)
        }
    ) {
        self.chooseDefaultSaveDirectory = chooseDefaultSaveDirectory
        self.openSystemSettings = openSystemSettings
        self.revealHistoryDirectory = revealHistoryDirectory
        self.testLiveShareServer = testLiveShareServer
    }

    static let inert = SettingsExternalActions(
        chooseDefaultSaveDirectory: { _ in nil },
        openSystemSettings: { _ in },
        revealHistoryDirectory: { _ in },
        testLiveShareServer: { _ in }
    )
}

private enum LiveShareServerTestStatus: Equatable {
    case idle
    case testing
    case reachable
    case failed(String)
}

enum SettingsNativeFriendStatus: Equatable, Sendable {
    case offline
    case preparing
    case live
    case blocked

    var title: String {
        switch self {
        case .offline: String(localized: "Offline")
        case .preparing: String(localized: "Getting ready")
        case .live: String(localized: "Live")
        case .blocked: String(localized: "Blocked")
        }
    }

    var systemImage: String {
        switch self {
        case .offline: "circle"
        case .preparing: "clock"
        case .live: "circle.fill"
        case .blocked: "hand.raised.fill"
        }
    }
}

struct SettingsNativeFriendRowSnapshot: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let deviceName: String
    let fingerprint: String
    let status: SettingsNativeFriendStatus

    var isBlocked: Bool { status == .blocked }
}

enum SettingsAccessibilityIdentifier {
    static let nativeIdentityFingerprint =
        "clip.settings.liveShare.identity.fingerprint"
    static let nativeIdentityReset = "clip.settings.liveShare.identity.reset"
    static let nativeIdentityResetConfirm =
        "clip.settings.liveShare.identity.reset.confirm"
    static let nativeFriendsEmpty = "clip.settings.liveShare.friends.empty"

    static func nativeFriend(_ id: String, element: String) -> String {
        "clip.settings.liveShare.friend.\(id).\(element)"
    }
}

struct SettingsView: View {
    // Six native navigation tabs need enough title-bar room to remain visible.
    // Below this width macOS moves them into its "more toolbar items" menu.
    static let contentSize = CGSize(width: 760, height: 520)

    static func filenameTemplateEditorText(
        for template: RecordingFilenameTemplate
    ) -> String {
        String(template.format.dropLast(".mp4".count))
    }

    static func formattedFingerprint(
        _ fingerprint: ClipLiveShareIdentityFingerprint
    ) -> String {
        var chunks: [String] = []
        var chunk = ""
        for character in fingerprint.rawValue {
            chunk.append(character)
            if chunk.count == 4 {
                chunks.append(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks.joined(separator: " ")
    }

    @MainActor
    static func nativeFriendRows(
        for model: NativeFriendModel
    ) -> [SettingsNativeFriendRowSnapshot] {
        let presenceByID = Dictionary(
            uniqueKeysWithValues: model.presentationSnapshots.map {
                ($0.id, $0.presence)
            }
        )
        return model.book.records
            .filter { $0.trustState != .pendingCommit }
            .map { record in
                let status: SettingsNativeFriendStatus
                if record.trustState == .blocked {
                    status = .blocked
                } else {
                    status = switch presenceByID[record.id] ?? .offline {
                    case .offline: .offline
                    case .preparing: .preparing
                    case .live: .live
                    }
                }
                return SettingsNativeFriendRowSnapshot(
                    id: record.id,
                    displayName: record.displayName,
                    deviceName: record.deviceName,
                    fingerprint: formattedFingerprint(record.identity.fingerprint),
                    status: status
                )
            }
    }

    @MainActor
    @discardableResult
    static func resetNativeIdentity(
        repository: NativeDeviceIdentityRepository,
        friends: NativeFriendModel
    ) async throws -> ClipLiveShareIdentityFingerprint {
        // Persistently remove every trust edge before rotating the Keychain
        // identity. If this write fails, reset aborts with the old identity and
        // friend book intact instead of reporting a partial success.
        try await friends.clearAllDurably()
        let replacement = try await repository.reset()
        return replacement.fingerprint
    }

    @ObservedObject var model: AppSettingsModel
    @ObservedObject var liveSharePreferences: LiveSharePreferencesModel
    @ObservedObject var nativeFriends: NativeFriendModel
    @ObservedObject var shortcuts: GlobalShortcutService
    let liveShareIdentity: NativeDeviceIdentityRepository
    let permissions: any PermissionServicing
    let audio: any AudioServicing
    let historyDirectory: URL
    let storageActions: SettingsStorageActions?
    let externalActions: SettingsExternalActions

    @State private var storageUsage: SettingsStorageSnapshot?
    @State private var storageError: String?
    @State private var isStorageOperationInProgress = false
    @State private var isConfirmingHistoryClear = false
    @State private var isChoosingSaveDirectory = false
    @State private var saveDirectorySelectionError: String?
    @State private var filenameTemplateText: String
    @State private var liveShareServerAddressText: String
    @State private var liveShareServerValidationError: String?
    @State private var liveShareServerTestStatus = LiveShareServerTestStatus.idle
    @State private var liveShareServerTestID: UUID?
    @State private var nativeIdentityFingerprint: ClipLiveShareIdentityFingerprint?
    @State private var nativeIdentityError: String?
    @State private var isResettingNativeIdentity = false
    @State private var isConfirmingNativeIdentityReset = false
    @State private var selectedTab: SettingsTab
    @FocusState private var isFilenameTemplateFocused: Bool
    @FocusState private var isLiveShareServerAddressFocused: Bool

    init(
        model: AppSettingsModel,
        liveSharePreferences: LiveSharePreferencesModel,
        nativeFriends: NativeFriendModel,
        liveShareIdentity: NativeDeviceIdentityRepository,
        shortcuts: GlobalShortcutService,
        permissions: any PermissionServicing,
        audio: any AudioServicing,
        historyDirectory: URL,
        storageActions: SettingsStorageActions? = nil,
        externalActions: SettingsExternalActions = SettingsExternalActions(),
        initialTab: SettingsTab = .initial
    ) {
        _model = ObservedObject(wrappedValue: model)
        _liveSharePreferences = ObservedObject(wrappedValue: liveSharePreferences)
        _nativeFriends = ObservedObject(wrappedValue: nativeFriends)
        self.liveShareIdentity = liveShareIdentity
        _shortcuts = ObservedObject(wrappedValue: shortcuts)
        self.permissions = permissions
        self.audio = audio
        self.historyDirectory = historyDirectory
        self.storageActions = storageActions
        self.externalActions = externalActions
        _filenameTemplateText = State(
            initialValue: Self.filenameTemplateEditorText(
                for: model.settings.defaultFilenameTemplate
            )
        )
        _liveShareServerAddressText = State(
            initialValue: liveSharePreferences.serverEndpoint.description
        )
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                general
                    .accessibilityIdentifier(SettingsTab.general.accessibilityIdentifier)
            }
            Tab("Recording", systemImage: "record.circle", value: SettingsTab.recording) {
                recording
                    .accessibilityIdentifier(SettingsTab.recording.accessibilityIdentifier)
            }
            Tab(
                "Live Share",
                systemImage: "dot.radiowaves.left.and.right",
                value: SettingsTab.liveShare
            ) {
                liveShare
                    .accessibilityIdentifier(SettingsTab.liveShare.accessibilityIdentifier)
            }
            Tab("Export", systemImage: "square.and.arrow.up", value: SettingsTab.export) {
                export
                    .accessibilityIdentifier(SettingsTab.export.accessibilityIdentifier)
            }
            Tab("Storage", systemImage: "externaldrive", value: SettingsTab.storage) {
                storage
                    .accessibilityIdentifier(SettingsTab.storage.accessibilityIdentifier)
            }
            Tab("Permissions", systemImage: "hand.raised", value: SettingsTab.permissions) {
                permissionSettings
                    .accessibilityIdentifier(SettingsTab.permissions.accessibilityIdentifier)
            }
        }
        .tabViewStyle(.tabBarOnly)
        .scenePadding()
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .task {
            await refreshStorageUsage()
        }
        .task {
            await loadNativeIdentity()
        }
        .confirmationDialog(
            "Clear Recording History?",
            isPresented: $isConfirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear Recording History", role: .destructive) {
                clearRecordingHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes Clip-managed recordings. Files created with Save As are never removed.")
        }
        .confirmationDialog(
            "Reset Live Share Identity?",
            isPresented: $isConfirmingNativeIdentityReset,
            titleVisibility: .visible
        ) {
            Button("Reset Identity", role: .destructive) {
                resetNativeIdentity()
            }
            .accessibilityIdentifier(
                SettingsAccessibilityIdentifier.nativeIdentityResetConfirm
            )
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device will receive a new fingerprint and all local Friends will be removed. Existing Friends will no longer recognize it.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.settings")
    }

    private var general: some View {
        Form {
            Toggle("Launch Clip at login", isOn: setting(\.launchAtLogin))
                .accessibilityIdentifier("clip.settings.general.launchAtLogin")
            Toggle("Show Clip in the Dock", isOn: setting(\.showInDock))
                .accessibilityIdentifier("clip.settings.general.showInDock")
            Picker("Default capture mode", selection: setting(\.defaultCaptureMode)) {
                Text("Capture Area").tag(CaptureMode.captureArea)
                Text("Last Area").tag(CaptureMode.lastArea)
                Text("Capture App").tag(CaptureMode.captureApplication)
                Text("Fullscreen").tag(CaptureMode.fullscreen)
            }
            .accessibilityIdentifier("clip.settings.general.defaultCaptureMode")
            Toggle("Remember the last area", isOn: setting(\.rememberLastArea))
                .accessibilityIdentifier("clip.settings.general.rememberLastArea")

            Section("Global shortcuts") {
                shortcutRow("Capture", action: .capture)
                shortcutRow("Finish", action: .finish)
                shortcutRow("Pause or Resume", action: .pauseOrResume)
                if !model.settings.shortcuts.conflicts.isEmpty {
                    Label("Two actions use the same shortcut.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let registrationError = shortcuts.registrationError {
                    Label(registrationError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Restore Default Shortcuts") {
                    Task {
                        await model.update { $0.shortcuts = .defaults }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var recording: some View {
        Form {
            Picker("Frame rate", selection: setting(\.frameRate)) {
                Text("30 FPS").tag(CaptureFrameRate.thirty)
                Text("60 FPS").tag(CaptureFrameRate.sixty)
            }
            Picker("Silent countdown", selection: setting(\.countdown)) {
                Text("Off").tag(CountdownDuration.off)
                Text("1 second").tag(CountdownDuration.oneSecond)
                Text("3 seconds").tag(CountdownDuration.threeSeconds)
                Text("5 seconds").tag(CountdownDuration.fiveSeconds)
            }
            Toggle("Show cursor", isOn: setting(\.showCursor))
            Toggle("Show click highlights", isOn: setting(\.showClickHighlights))
                .accessibilityIdentifier("clip.settings.recording.clickHighlights")
            Toggle("Record system audio", isOn: systemAudioBinding)
            Toggle("Record microphone", isOn: microphoneBinding)
            LabeledContent("Current microphone") {
                Text(audio.defaultInputName ?? String(localized: "Unavailable"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var liveShare: some View {
        Form {
            Section {
                LabeledContent("Server address") {
                    HStack(spacing: 8) {
                        TextField(
                            "Server address",
                            text: $liveShareServerAddressText,
                            prompt: Text("https://example.com")
                        )
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 250, idealWidth: 290, maxWidth: 320)
                            .focused($isLiveShareServerAddressFocused)
                            .accessibilityIdentifier("clip.settings.liveShare.server.address")
                            .onSubmit {
                                applyLiveShareServerAddress()
                            }
                            .onChange(of: liveShareServerAddressText) { _, _ in
                                validateLiveShareServerDraft()
                                liveShareServerTestID = nil
                                liveShareServerTestStatus = .idle
                            }
                        Button("Apply") {
                            applyLiveShareServerAddress()
                        }
                        .disabled(
                            liveShareServerCandidate == nil
                                || liveShareServerCandidate
                                    == liveSharePreferences.serverEndpoint
                        )
                        .accessibilityIdentifier("clip.settings.liveShare.server.apply")
                    }
                }

                if let liveShareServerValidationError {
                    Label(liveShareServerValidationError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("clip.settings.liveShare.server.validation")
                }

                HStack {
                    Button {
                        testLiveShareServer()
                    } label: {
                        if liveShareServerTestStatus == .testing {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Testing…")
                            }
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(
                        liveShareServerCandidate == nil
                            || liveShareServerTestStatus == .testing
                    )
                    .accessibilityIdentifier("clip.settings.liveShare.server.test")

                    Spacer()

                    Button("Reset Server Address") {
                        resetLiveShareServerAddress()
                    }
                    .disabled(
                        liveSharePreferences.serverEndpoint == .official
                            && liveShareServerAddressText
                                == ClipLiveShareServerEndpoint.official.description
                    )
                    .accessibilityIdentifier("clip.settings.liveShare.server.reset")
                }

                switch liveShareServerTestStatus {
                case .idle, .testing:
                    EmptyView()
                case .reachable:
                    Label("Server is reachable.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("clip.settings.liveShare.server.status")
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("clip.settings.liveShare.server.status")
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Clip discovers the viewer, encrypted signaling, and ICE configuration from this server root. Changes apply to the next Live Share session.")
            }

            Section {
                LabeledContent("Fingerprint") {
                    if let nativeIdentityFingerprint {
                        Text(Self.formattedFingerprint(nativeIdentityFingerprint))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .help(nativeIdentityFingerprint.rawValue)
                            .accessibilityLabel("This device fingerprint")
                            .accessibilityValue(nativeIdentityFingerprint.rawValue)
                            .accessibilityIdentifier(
                                SettingsAccessibilityIdentifier
                                    .nativeIdentityFingerprint
                            )
                    } else if nativeIdentityError == nil {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Loading this device fingerprint")
                    } else {
                        Text("Unavailable")
                            .foregroundStyle(.secondary)
                    }
                }

                if let nativeIdentityError {
                    Label(nativeIdentityError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(
                            "clip.settings.liveShare.identity.error"
                        )
                }

                HStack {
                    Spacer()
                    if isResettingNativeIdentity {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Resetting Live Share identity")
                    }
                    Button("Reset Identity…", role: .destructive) {
                        isConfirmingNativeIdentityReset = true
                    }
                    .disabled(
                        nativeIdentityFingerprint == nil
                            || isResettingNativeIdentity
                    )
                    .accessibilityIdentifier(
                        SettingsAccessibilityIdentifier.nativeIdentityReset
                    )
                }
            } header: {
                Text("This Device")
            } footer: {
                Text("Friends use this fingerprint to verify this Mac. Reset it only if you want this device to become a new identity.")
            }

            Section {
                let rows = Self.nativeFriendRows(for: nativeFriends)
                if rows.isEmpty {
                    Text("No Friends yet. Add one from the Live Share popover.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            SettingsAccessibilityIdentifier.nativeFriendsEmpty
                        )
                } else {
                    ForEach(rows) { row in
                        SettingsNativeFriendRow(
                            snapshot: row,
                            onRename: { name in
                                nativeFriends.rename(id: row.id, to: name)
                            },
                            onSetBlocked: { blocked in
                                nativeFriends.setBlocked(blocked, id: row.id)
                            },
                            onRemove: {
                                nativeFriends.remove(id: row.id)
                            }
                        )
                    }
                }

                if let error = nativeFriends.lastPersistenceError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(
                            "clip.settings.liveShare.friends.error"
                        )
                }
            } header: {
                Text("Friends")
            } footer: {
                Text("Names are local to this Mac. Blocking keeps the Friend saved but prevents trusted connections; removing deletes the local record.")
            }

            Section("Default stream") {
                Picker(
                    "Codec",
                    selection: liveShareSetting(\.videoCodec)
                ) {
                    ForEach(LiveShareVideoCodec.allCases) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }
                .accessibilityIdentifier("clip.settings.liveShare.codec")

                Picker(
                    "Quality",
                    selection: liveShareSetting(\.quality)
                ) {
                    ForEach(LiveShareQualityPreset.allCases) { quality in
                        Text(liveShareQualityLabel(quality)).tag(quality)
                    }
                }
                .accessibilityIdentifier("clip.settings.liveShare.quality")

                Picker(
                    "Frame rate",
                    selection: liveShareSetting(\.frameRate)
                ) {
                    ForEach(LiveShareFrameRate.allCases) { frameRate in
                        Text("\(frameRate.rawValue) FPS").tag(frameRate)
                    }
                }
                .accessibilityIdentifier("clip.settings.liveShare.frameRate")

                Toggle(
                    "Match cursor updates to frame rate",
                    isOn: liveShareSetting(\.cursorUpdatesMatchFrameRate)
                )
                .accessibilityIdentifier("clip.settings.liveShare.cursorUpdatesMatchFrameRate")

                Picker(
                    "Mode",
                    selection: liveShareSetting(\.encodingMode)
                ) {
                    Text("Performance").tag(LiveShareEncodingMode.performance)
                    Text("Quality").tag(LiveShareEncodingMode.quality)
                }
                .accessibilityIdentifier("clip.settings.liveShare.mode")

                Toggle(
                    "Share system audio",
                    isOn: liveShareSetting(\.systemAudioEnabled)
                )
                .accessibilityIdentifier("clip.settings.liveShare.systemAudio")
            }

            Section {
                Toggle(
                    "Require an access code",
                    isOn: liveShareSetting(\.accessCodeEnabled)
                )
                .accessibilityIdentifier("clip.settings.liveShare.accessCode")
                Toggle(
                    "Prioritize focused window",
                    isOn: liveShareSetting(\.prioritizeFocusedWindow)
                )
                .accessibilityIdentifier("clip.settings.liveShare.prioritizeFocused")
                Toggle(
                    "Auto-share focused windows",
                    isOn: liveShareSetting(\.autoShareFocusedWindows)
                )
                .accessibilityIdentifier("clip.settings.liveShare.autoShare")
            } header: {
                Text("Sharing behavior")
            } footer: {
                Text("These are defaults for new sessions. Controls in the Live Share popover can still change the active session.")
            }

            if let error = liveSharePreferences.lastPersistenceError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Restore All Live Share Defaults") {
                liveSharePreferences.restoreSessionDefaults()
            }
            .disabled(liveSharePreferences.settings == .default)
            .accessibilityIdentifier("clip.settings.liveShare.defaults.reset")
        }
        .formStyle(.grouped)
        .onChange(of: liveSharePreferences.serverEndpoint) { _, endpoint in
            guard !isLiveShareServerAddressFocused else { return }
            liveShareServerAddressText = endpoint.description
            liveShareServerValidationError = nil
            liveShareServerTestID = nil
            liveShareServerTestStatus = .idle
        }
    }

    private var export: some View {
        Form {
            Picker("Default preset", selection: exportPresetBinding) {
                Text("Crisp").tag(ExportPreset.crisp)
                Text("Compact").tag(ExportPreset.compact)
                Text("Smallest").tag(ExportPreset.smallest)
            }

            Section {
                exportQualityRow(
                    "Crisp",
                    preset: .crisp,
                    accessibilityIdentifier: "clip.settings.export.quality.crisp"
                )
                exportQualityRow(
                    "Compact",
                    preset: .compact,
                    accessibilityIdentifier: "clip.settings.export.quality.compact"
                )
                exportQualityRow(
                    "Smallest",
                    preset: .smallest,
                    accessibilityIdentifier: "clip.settings.export.quality.smallest"
                )
                Button("Reset Quality Defaults") {
                    Task { @MainActor in
                        await model.update { $0.exportQualities = .defaults }
                    }
                }
                .accessibilityIdentifier("clip.settings.export.quality.reset")
            } header: {
                Text("Video quality")
            } footer: {
                Text("Each preset uses its own H.264 quality value from 1 through 100. File size varies with the recording.")
            }
            Section {
                LabeledContent("Default filename format") {
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            TextField("", text: $filenameTemplateText)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 190, idealWidth: 220, maxWidth: 245)
                                .focused($isFilenameTemplateFocused)
                                .accessibilityLabel("Default filename format")
                                .accessibilityHint("The .mp4 extension is added automatically")
                                .accessibilityIdentifier("clip.settings.filename-template")
                                .onSubmit {
                                    applyFilenameTemplate()
                                }
                            Text(verbatim: ".mp4")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("clip.settings.filename-extension")
                        }
                        Button("Apply") {
                            applyFilenameTemplate()
                        }
                        .disabled(
                            validatedFilenameTemplate == nil
                                || validatedFilenameTemplate
                                    == model.settings.defaultFilenameTemplate
                        )
                    }
                }
                if let filenameTemplateValidationMessage {
                    Label(filenameTemplateValidationMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let example = validatedFilenameTemplate?.filename(
                    at: Date(),
                    timeZone: .current
                ) {
                    Text("Example: \(example.fileName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("File names")
            } footer: {
                Text("Tokens: YYYY year, MM month, DD day, HH hour, mm minute, and ss second. They are case-sensitive; .mp4 is added automatically.")
            }
            Toggle(
                "Close Preview after explicit Copy",
                isOn: setting(\.automaticallyClosePreviewAfterCopy)
            )
            Toggle("Keep original recording after export", isOn: setting(\.keepOriginalAfterExport))
            LabeledContent("Default Save As folder") {
                HStack {
                    Text(model.settings.defaultSaveDirectory.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") {
                        chooseDefaultSaveDirectory()
                    }
                    .disabled(isChoosingSaveDirectory)
                }
            }
            if let directoryError = saveDirectorySelectionError
                ?? model.defaultSaveDirectoryAccessError {
                Label(directoryError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Dragging, Copy, and Save As always use the edited filename and current trim.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: model.settings.defaultFilenameTemplate) { _, template in
            guard !isFilenameTemplateFocused else { return }
            filenameTemplateText = Self.filenameTemplateEditorText(for: template)
        }
    }

    private var storage: some View {
        Form {
            Picker("Keep recordings", selection: setting(\.historyRetention)) {
                Text("1 day").tag(HistoryRetentionPolicy.oneDay)
                Text("7 days").tag(HistoryRetentionPolicy.sevenDays)
                Text("30 days").tag(HistoryRetentionPolicy.thirtyDays)
                Text("Indefinitely").tag(HistoryRetentionPolicy.indefinitely)
                Text("Remove after export or share")
                    .tag(HistoryRetentionPolicy.doNotRetainAfterExport)
            }
            LabeledContent("Managed history") {
                HStack {
                    Text(historyDirectory.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Reveal") {
                        revealHistoryDirectory()
                    }
                }
            }
            if let storageUsage {
                LabeledContent("Current usage") {
                    Text(byteCount(storageUsage.directoryMP4ByteCount))
                }
                LabeledContent("History recordings") {
                    Text(storageUsage.recordingCount, format: .number)
                }
                if storageUsage.cleanupCandidateByteCount > 0 {
                    LabeledContent("Cleanup candidates") {
                        Text(byteCount(storageUsage.cleanupCandidateByteCount))
                    }
                }
                if storageUsage.untrackedMP4ByteCount > 0 {
                    Text("The folder also contains \(byteCount(storageUsage.untrackedMP4ByteCount)) of unknown MP4 files. Clip will not delete them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if isStorageOperationInProgress {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Calculating storage usage…")
                        .foregroundStyle(.secondary)
                }
            } else if storageActions == nil {
                Text("Storage usage and cleanup are unavailable until history services finish starting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let storageError {
                Label(storageError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Refresh Usage") {
                    Task { @MainActor in
                        await refreshStorageUsage()
                    }
                }
                .disabled(storageActions == nil || isStorageOperationInProgress)
                .accessibilityIdentifier("clip.settings.storage.refresh")
                Spacer()
                Button("Clear Recording History…", role: .destructive) {
                    isConfirmingHistoryClear = true
                }
                .disabled(
                    storageActions == nil
                        || isStorageOperationInProgress
                        || (storageUsage?.recordingCount ?? 0) == 0
                )
                .accessibilityIdentifier("clip.settings.storage.clear")
            }
            Text("Clip never removes files you create with Save As.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var permissionSettings: some View {
        Form {
            permissionRow(
                "Screen & System Audio Recording",
                permission: .screenRecording,
                settingsAnchor: "Privacy_ScreenCapture"
            )
            permissionRow(
                "Microphone",
                permission: .microphone,
                settingsAnchor: "Privacy_Microphone"
            )
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(
        _ title: LocalizedStringKey,
        action: GlobalShortcutAction
    ) -> some View {
        LabeledContent(title) {
            GlobalShortcutRecorder(shortcut: shortcutBinding(for: action))
                .frame(width: 125)
                .help("Click, then type the new shortcut. Press Escape to cancel.")
        }
    }

    private func shortcutBinding(
        for action: GlobalShortcutAction
    ) -> Binding<ClipCore.KeyboardShortcut> {
        Binding(
            get: { model.settings.shortcuts[action] },
            set: { shortcut in
                Task { @MainActor in
                    await model.update { $0.shortcuts[action] = shortcut }
                }
            }
        )
    }

    private func permissionRow(
        _ title: LocalizedStringKey,
        permission: ClipPermission,
        settingsAnchor: String
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Text(permissions.currentStatus(for: permission).displayName)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    guard let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)"
                    ) else { return }
                    externalActions.openSystemSettings(url)
                }
                .accessibilityIdentifier("clip.settings.permission.\(permission.accessibilityName)")
            }
        }
    }

    private func setting<Value: Sendable>(
        _ keyPath: WritableKeyPath<ClipSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                Task { @MainActor in
                    await model.update { $0[keyPath: keyPath] = newValue }
                }
            }
        )
    }

    private func liveShareSetting<Value: Sendable>(
        _ keyPath: WritableKeyPath<LiveShareSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { liveSharePreferences.settings[keyPath: keyPath] },
            set: { newValue in
                liveSharePreferences.updateSettings {
                    $0[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private var liveShareServerCandidate: ClipLiveShareServerEndpoint? {
        try? ClipLiveShareServerEndpoint(userInput: liveShareServerAddressText)
    }

    private func validateLiveShareServerDraft() {
        do {
            _ = try ClipLiveShareServerEndpoint(userInput: liveShareServerAddressText)
            liveShareServerValidationError = nil
        } catch let error as LocalizedError {
            liveShareServerValidationError = error.errorDescription
        } catch {
            liveShareServerValidationError = String(
                localized: "Enter a valid Live Share server address."
            )
        }
    }

    private func applyLiveShareServerAddress() {
        do {
            let endpoint = try ClipLiveShareServerEndpoint(
                userInput: liveShareServerAddressText
            )
            isLiveShareServerAddressFocused = false
            liveShareServerAddressText = endpoint.description
            liveShareServerValidationError = nil
            liveShareServerTestID = nil
            liveShareServerTestStatus = .idle
            liveSharePreferences.setServerEndpoint(endpoint)
        } catch {
            validateLiveShareServerDraft()
            NSSound.beep()
        }
    }

    private func testLiveShareServer() {
        guard liveShareServerTestStatus != .testing else { return }
        do {
            let endpoint = try ClipLiveShareServerEndpoint(
                userInput: liveShareServerAddressText
            )
            liveShareServerValidationError = nil
            let testID = UUID()
            liveShareServerTestID = testID
            liveShareServerTestStatus = .testing
            Task { @MainActor in
                do {
                    try await externalActions.testLiveShareServer(endpoint)
                    guard liveShareServerTestID == testID else { return }
                    liveShareServerTestStatus = .reachable
                } catch is CancellationError {
                    guard liveShareServerTestID == testID else { return }
                    liveShareServerTestStatus = .idle
                } catch {
                    guard liveShareServerTestID == testID else { return }
                    liveShareServerTestStatus = .failed(
                        reportSettingsError(
                            error,
                            operation: "Test Live Share server"
                        )
                    )
                }
            }
        } catch {
            validateLiveShareServerDraft()
            NSSound.beep()
        }
    }

    private func resetLiveShareServerAddress() {
        isLiveShareServerAddressFocused = false
        liveShareServerAddressText = ClipLiveShareServerEndpoint.official.description
        liveShareServerValidationError = nil
        liveShareServerTestID = nil
        liveShareServerTestStatus = .idle
        liveSharePreferences.resetServerEndpoint()
    }

    private func loadNativeIdentity() async {
        guard nativeIdentityFingerprint == nil,
              !isResettingNativeIdentity else { return }
        do {
            nativeIdentityFingerprint = try await liveShareIdentity
                .loadOrCreate()
                .fingerprint
            nativeIdentityError = nil
        } catch is CancellationError {
            return
        } catch {
            nativeIdentityError = reportSettingsError(
                error,
                operation: "Load Live Share identity"
            )
        }
    }

    private func resetNativeIdentity() {
        guard !isResettingNativeIdentity else { return }
        isResettingNativeIdentity = true
        nativeIdentityError = nil
        Task { @MainActor in
            defer { isResettingNativeIdentity = false }
            do {
                nativeIdentityFingerprint = try await Self.resetNativeIdentity(
                    repository: liveShareIdentity,
                    friends: nativeFriends
                )
            } catch is CancellationError {
                return
            } catch {
                nativeIdentityError = reportSettingsError(
                    error,
                    operation: "Reset Live Share identity"
                )
            }
        }
    }

    private func liveShareQualityLabel(
        _ quality: LiveShareQualityPreset
    ) -> String {
        let megabits = Double(quality.maximumBitrateBitsPerSecond) / 1_000_000
        let fractionLength = megabits.rounded() == megabits ? 0 : 1
        let bitrate = megabits.formatted(
            .number.precision(.fractionLength(fractionLength))
        )
        return "\(quality.name) · \(bitrate) Mbps"
    }

    private var microphoneBinding: Binding<Bool> {
        audioBinding(
            permission: .microphone,
            get: { $0.audio.microphoneEnabled },
            set: { $0.audio.microphoneEnabled = $1 }
        )
    }

    private var systemAudioBinding: Binding<Bool> {
        audioBinding(
            permission: .systemAudio,
            get: { $0.audio.systemAudioEnabled },
            set: { $0.audio.systemAudioEnabled = $1 }
        )
    }

    private func audioBinding(
        permission: ClipPermission,
        get: @escaping (ClipSettings) -> Bool,
        set: @escaping (inout ClipSettings, Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { get(model.settings) },
            set: { enabled in
                Task { @MainActor in
                    if enabled,
                       permissions.currentStatus(for: permission) != .granted,
                       await permissions.request(permission) != .granted {
                        return
                    }
                    await model.update { set(&$0, enabled) }
                }
            }
        )
    }

    private var exportPresetBinding: Binding<ExportPreset> {
        Binding(
            get: { model.settings.exportConfiguration.preset },
            set: { preset in
                Task { @MainActor in
                    await model.update { $0.exportConfiguration.preset = preset }
                }
            }
        )
    }

    private func exportQualityBinding(for preset: ExportPreset) -> Binding<Int> {
        Binding(
            get: { model.settings.exportQualities.quality(for: preset) },
            set: { requestedQuality in
                let quality = requestedQuality.clamped(to: ExportQualitySettings.validRange)
                Task { @MainActor in
                    await model.update { settings in
                        switch preset {
                        case .crisp:
                            settings.exportQualities.crisp = quality
                        case .compact:
                            settings.exportQualities.compact = quality
                        case .smallest:
                            settings.exportQualities.smallest = quality
                        }
                    }
                }
            }
        )
    }

    private func exportQualityRow(
        _ title: LocalizedStringKey,
        preset: ExportPreset,
        accessibilityIdentifier: String
    ) -> some View {
        let binding = exportQualityBinding(for: preset)
        return LabeledContent {
            HStack(spacing: 8) {
                TextField("", value: binding, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .accessibilityLabel(Text(title))
                    .accessibilityIdentifier(accessibilityIdentifier)
                Stepper("", value: binding, in: ExportQualitySettings.validRange)
                    .labelsHidden()
            }
        } label: {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var validatedFilenameTemplate: RecordingFilenameTemplate? {
        try? RecordingFilenameTemplate(validating: filenameTemplateText)
    }

    private var filenameTemplateValidationMessage: String? {
        do {
            _ = try RecordingFilenameTemplate(validating: filenameTemplateText)
            return nil
        } catch let error as RecordingFilenameError {
            switch error {
            case .empty:
                return String(
                    localized: "Enter a filename format, such as clip-YYYYMMDD-HHmmss."
                )
            case .reservedName:
                return String(localized: "The filename format cannot be “.” or “..”.")
            case .containsPathSeparator:
                return String(localized: "The filename format cannot contain / or : characters.")
            case .containsControlCharacter:
                return String(localized: "The filename format cannot contain line breaks or control characters.")
            case .trailingPeriod:
                return String(localized: "The filename format cannot end with a period before .mp4.")
            case .tooLong:
                return String(
                    localized: "The filename format is too long. Use no more than 240 UTF-8 bytes before .mp4."
                )
            }
        } catch {
            return String(localized: "Enter a valid filename format.")
        }
    }

    private func applyFilenameTemplate() {
        guard let template = validatedFilenameTemplate else {
            NSSound.beep()
            return
        }
        filenameTemplateText = Self.filenameTemplateEditorText(for: template)
        Task { @MainActor in
            await model.update { $0.defaultFilenameTemplate = template }
        }
    }

    private func chooseDefaultSaveDirectory() {
        guard !isChoosingSaveDirectory else { return }
        isChoosingSaveDirectory = true
        saveDirectorySelectionError = nil

        Task { @MainActor in
            defer { isChoosingSaveDirectory = false }
            guard let directoryURL = await externalActions.chooseDefaultSaveDirectory(
                model.settings.defaultSaveDirectory
            ) else { return }
            do {
                try await model.setDefaultSaveDirectory(directoryURL)
            } catch {
                saveDirectorySelectionError = reportSettingsError(
                    error,
                    operation: "Choose default Save As folder"
                )
            }
        }
    }

    private func revealHistoryDirectory() {
        if let revealHistory = storageActions?.revealHistory {
            revealHistory()
        } else {
            externalActions.revealHistoryDirectory(historyDirectory)
        }
    }

    private func refreshStorageUsage() async {
        guard let storageActions, !isStorageOperationInProgress else { return }
        isStorageOperationInProgress = true
        defer { isStorageOperationInProgress = false }
        do {
            storageUsage = try await storageActions.loadUsage()
            storageError = nil
        } catch is CancellationError {
            return
        } catch {
            storageError = reportSettingsError(
                error,
                operation: "Load storage usage"
            )
        }
    }

    private func clearRecordingHistory() {
        guard let storageActions, !isStorageOperationInProgress else { return }
        isStorageOperationInProgress = true
        storageError = nil
        Task { @MainActor in
            defer { isStorageOperationInProgress = false }
            do {
                storageUsage = try await storageActions.clearHistory()
            } catch is CancellationError {
                return
            } catch {
                storageError = reportSettingsError(
                    error,
                    operation: "Clear recording history"
                )
            }
        }
    }

    private func reportSettingsError(
        _ error: any Error,
        operation: String
    ) -> String {
        let details = UserFacingErrorPresentation.details(for: error)
        ClipLog.storage.error(
            "Settings operation failed (\(operation, privacy: .public)): \(details.technicalDescription, privacy: .private)"
        )
        return details.message
    }

    private func byteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, byteCount),
            countStyle: .file
        )
    }
}

private struct SettingsNativeFriendRow: View {
    let snapshot: SettingsNativeFriendRowSnapshot
    let onRename: (String) -> Void
    let onSetBlocked: (Bool) -> Void
    let onRemove: () -> Void

    @State private var localName: String
    @FocusState private var isEditingName: Bool

    init(
        snapshot: SettingsNativeFriendRowSnapshot,
        onRename: @escaping (String) -> Void,
        onSetBlocked: @escaping (Bool) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.onRename = onRename
        self.onSetBlocked = onSetBlocked
        self.onRemove = onRemove
        _localName = State(initialValue: snapshot.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("Local name", text: $localName)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)
                    .focused($isEditingName)
                    .onSubmit {
                        commitName()
                    }
                    .accessibilityIdentifier(
                        SettingsAccessibilityIdentifier.nativeFriend(
                            snapshot.id,
                            element: "name"
                        )
                    )
                Spacer()
                status
            }

            LabeledContent("Device") {
                Text(snapshot.deviceName)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        SettingsAccessibilityIdentifier.nativeFriend(
                            snapshot.id,
                            element: "device"
                        )
                    )
            }

            LabeledContent("Fingerprint") {
                Text(snapshot.fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(snapshot.fingerprint)
                    .accessibilityIdentifier(
                        SettingsAccessibilityIdentifier.nativeFriend(
                            snapshot.id,
                            element: "fingerprint"
                        )
                    )
            }

            HStack(spacing: 8) {
                Spacer()
                Button(snapshot.isBlocked ? "Unblock" : "Block") {
                    onSetBlocked(!snapshot.isBlocked)
                }
                .accessibilityIdentifier(
                    SettingsAccessibilityIdentifier.nativeFriend(
                        snapshot.id,
                        element: "block"
                    )
                )
                Button("Remove", role: .destructive) {
                    onRemove()
                }
                .accessibilityIdentifier(
                    SettingsAccessibilityIdentifier.nativeFriend(
                        snapshot.id,
                        element: "remove"
                    )
                )
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            SettingsAccessibilityIdentifier.nativeFriend(
                snapshot.id,
                element: "row"
            )
        )
        .onChange(of: isEditingName) { wasEditing, isEditing in
            if wasEditing, !isEditing {
                commitName()
            }
        }
        .onChange(of: snapshot.displayName) { _, displayName in
            guard !isEditingName else { return }
            localName = displayName
        }
    }

    @ViewBuilder
    private var status: some View {
        Label(snapshot.status.title, systemImage: snapshot.status.systemImage)
            .font(.caption)
            .foregroundStyle(statusColor)
            .accessibilityIdentifier(
                SettingsAccessibilityIdentifier.nativeFriend(
                    snapshot.id,
                    element: "status"
                )
            )
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .live: .green
        case .blocked: .orange
        case .preparing: .blue
        case .offline: .secondary
        }
    }

    private func commitName() {
        let trimmed = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            localName = snapshot.displayName
            return
        }
        let normalized = String(trimmed.prefix(128))
        localName = normalized
        guard normalized != snapshot.displayName else { return }
        onRename(normalized)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension PermissionState {
    var displayName: String {
        switch self {
        case .notDetermined: String(localized: "Not requested")
        case .granted: String(localized: "Allowed")
        case .denied: String(localized: "Denied")
        case .restricted: String(localized: "Restricted")
        }
    }
}

private extension ClipPermission {
    var accessibilityName: String {
        switch self {
        case .screenRecording: "screen-recording"
        case .microphone: "microphone"
        case .systemAudio: "system-audio"
        }
    }
}

private extension ClipCore.KeyboardShortcut {
    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + (key == " " ? String(localized: "Space") : key.uppercased())
    }
}

private struct GlobalShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: ClipCore.KeyboardShortcut

    func makeNSView(context: Context) -> GlobalShortcutRecorderButton {
        let button = GlobalShortcutRecorderButton()
        button.shortcut = shortcut
        button.onCommit = { shortcut in
            self.shortcut = shortcut
        }
        return button
    }

    func updateNSView(_ button: GlobalShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onCommit = { shortcut in
            self.shortcut = shortcut
        }
    }
}

@MainActor
private final class GlobalShortcutRecorderButton: NSButton {
    var shortcut = ShortcutConfiguration.defaults.capture {
        didSet { updateTitle() }
    }
    var onCommit: ((ClipCore.KeyboardShortcut) -> Void)?

    private var isRecordingShortcut = false

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel(String(localized: "Record global shortcut"))
        updateTitle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }
        _ = record(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecordingShortcut else {
            return super.performKeyEquivalent(with: event)
        }
        return record(event)
    }

    override func resignFirstResponder() -> Bool {
        isRecordingShortcut = false
        updateTitle()
        return super.resignFirstResponder()
    }

    @objc
    private func beginRecording() {
        isRecordingShortcut = true
        title = String(localized: "Type Shortcut")
        window?.makeFirstResponder(self)
    }

    private func record(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            isRecordingShortcut = false
            updateTitle()
            window?.makeFirstResponder(nil)
            return true
        }

        let modifiers = shortcutModifiers(from: event.modifierFlags)
        guard !modifiers.isEmpty,
              let characters = event.charactersIgnoringModifiers?.lowercased(),
              characters.count == 1,
              ShortcutKeyCodeResolver.isSupported(characters),
              let recordedShortcut = try? ClipCore.KeyboardShortcut(
                  key: characters,
                  modifiers: modifiers
              ) else {
            NSSound.beep()
            title = String(localized: "Try Another Shortcut")
            return true
        }

        shortcut = recordedShortcut
        onCommit?(recordedShortcut)
        isRecordingShortcut = false
        updateTitle()
        window?.makeFirstResponder(nil)
        return true
    }

    private func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    private func updateTitle() {
        guard !isRecordingShortcut else { return }
        title = shortcut.displayName
        setAccessibilityValue(shortcut.displayName)
    }
}
