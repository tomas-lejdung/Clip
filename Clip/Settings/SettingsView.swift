import AppKit
import Carbon.HIToolbox
import ClipCore
import OSLog
import SwiftUI

enum SettingsTab: String, CaseIterable, Hashable, Sendable {
    case general
    case recording
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
        }
    ) {
        self.chooseDefaultSaveDirectory = chooseDefaultSaveDirectory
        self.openSystemSettings = openSystemSettings
        self.revealHistoryDirectory = revealHistoryDirectory
    }

    static let inert = SettingsExternalActions(
        chooseDefaultSaveDirectory: { _ in nil },
        openSystemSettings: { _ in },
        revealHistoryDirectory: { _ in }
    )
}

struct SettingsView: View {
    static let contentSize = CGSize(width: 570, height: 470)

    @ObservedObject var model: AppSettingsModel
    @ObservedObject var shortcuts: GlobalShortcutService
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
    @State private var selectedTab: SettingsTab
    @FocusState private var isFilenameTemplateFocused: Bool

    init(
        model: AppSettingsModel,
        shortcuts: GlobalShortcutService,
        permissions: any PermissionServicing,
        audio: any AudioServicing,
        historyDirectory: URL,
        storageActions: SettingsStorageActions? = nil,
        externalActions: SettingsExternalActions = SettingsExternalActions(),
        initialTab: SettingsTab = .initial
    ) {
        _model = ObservedObject(wrappedValue: model)
        _shortcuts = ObservedObject(wrappedValue: shortcuts)
        self.permissions = permissions
        self.audio = audio
        self.historyDirectory = historyDirectory
        self.storageActions = storageActions
        self.externalActions = externalActions
        _filenameTemplateText = State(
            initialValue: model.settings.defaultFilenameTemplate.format
        )
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            general
                .accessibilityIdentifier(SettingsTab.general.accessibilityIdentifier)
                .tag(SettingsTab.general)
                .tabItem { Label("General", systemImage: "gearshape") }
            recording
                .accessibilityIdentifier(SettingsTab.recording.accessibilityIdentifier)
                .tag(SettingsTab.recording)
                .tabItem { Label("Recording", systemImage: "record.circle") }
            export
                .accessibilityIdentifier(SettingsTab.export.accessibilityIdentifier)
                .tag(SettingsTab.export)
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            storage
                .accessibilityIdentifier(SettingsTab.storage.accessibilityIdentifier)
                .tag(SettingsTab.storage)
                .tabItem { Label("Storage", systemImage: "externaldrive") }
            permissionSettings
                .accessibilityIdentifier(SettingsTab.permissions.accessibilityIdentifier)
                .tag(SettingsTab.permissions)
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
        }
        .padding(20)
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .task {
            await refreshStorageUsage()
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
            Toggle("Record system audio", isOn: systemAudioBinding)
            Toggle("Record microphone", isOn: microphoneBinding)
            LabeledContent("Current microphone") {
                Text(audio.defaultInputName ?? String(localized: "Unavailable"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var export: some View {
        Form {
            Picker("Default preset", selection: exportPresetBinding) {
                Text("Crisp").tag(ExportPreset.crisp)
                Text("Compact").tag(ExportPreset.compact)
                Text("Smallest").tag(ExportPreset.smallest)
            }

            Section("Video quality") {
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
                Text("Each preset uses its own H.264 quality value from 1 through 100. File size varies with the recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset Quality Defaults") {
                    Task { @MainActor in
                        await model.update { $0.exportQualities = .defaults }
                    }
                }
                .accessibilityIdentifier("clip.settings.export.quality.reset")
            }
            Section("File names") {
                LabeledContent("Default filename format") {
                    HStack(spacing: 8) {
                        TextField(
                            "clip-YYYYMMDD-HHmmss.mp4",
                            text: $filenameTemplateText
                        )
                        .frame(width: 245)
                        .focused($isFilenameTemplateFocused)
                        .accessibilityIdentifier("clip.settings.filename-template")
                        .onSubmit {
                            applyFilenameTemplate()
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
                Text("Tokens: YYYY year, MM month, DD day, HH hour, mm minute, and ss second. They are case-sensitive; .mp4 is added automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            filenameTemplateText = template.format
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
            Text("Clip does not request Accessibility access.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("An ad-hoc rebuilt app may need privacy approval again if macOS treats it as a new code identity.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        return LabeledContent(title) {
            HStack(spacing: 8) {
                TextField("Quality", value: binding, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .accessibilityIdentifier(accessibilityIdentifier)
                Stepper("", value: binding, in: ExportQualitySettings.validRange)
                    .labelsHidden()
            }
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
                    localized: "Enter a filename format, such as clip-YYYYMMDD-HHmmss.mp4."
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
        filenameTemplateText = template.format
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
