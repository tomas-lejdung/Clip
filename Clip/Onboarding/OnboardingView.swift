import ClipCore
import SwiftUI

@MainActor
final class OnboardingStore {
    static let defaultCompletionKey = "onboarding.completed.v1"

    private let defaults: UserDefaults
    private let completionKey: String

    init(
        defaults: UserDefaults = .standard,
        completionKey: String = OnboardingStore.defaultCompletionKey
    ) {
        self.defaults = defaults
        self.completionKey = completionKey
    }

    var isCompleted: Bool {
        defaults.bool(forKey: completionKey)
    }

    func markCompleted() {
        defaults.set(true, forKey: completionKey)
    }

    func reset() {
        defaults.removeObject(forKey: completionKey)
    }
}

enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    case welcome
    case screenRecording
    case optionalAudio
    case preferences
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    static let pageCount = OnboardingStep.allCases.count

    @Published private(set) var step: OnboardingStep
    @Published private(set) var screenPermission: PermissionState
    @Published private(set) var isRequestingPermission = false

    private let currentScreenPermission: @MainActor () -> PermissionState
    private let requestScreenPermission: @MainActor () async -> PermissionState
    private let configureShortcutsAction: @MainActor () -> Void
    private let completion: @MainActor () -> Void
    private var hasCompleted = false

    init(
        initialStep: OnboardingStep = .welcome,
        currentScreenPermission: @escaping @MainActor () -> PermissionState,
        requestScreenPermission: @escaping @MainActor () async -> PermissionState,
        configureShortcuts: @escaping @MainActor () -> Void = {},
        completion: @escaping @MainActor () -> Void
    ) {
        step = initialStep
        self.currentScreenPermission = currentScreenPermission
        self.requestScreenPermission = requestScreenPermission
        configureShortcutsAction = configureShortcuts
        self.completion = completion
        screenPermission = currentScreenPermission()
    }

    convenience init(
        store: OnboardingStore,
        initialStep: OnboardingStep = .welcome,
        currentScreenPermission: @escaping @MainActor () -> PermissionState,
        requestScreenPermission: @escaping @MainActor () async -> PermissionState,
        configureShortcuts: @escaping @MainActor () -> Void = {},
        completion: @escaping @MainActor () -> Void
    ) {
        self.init(
            initialStep: initialStep,
            currentScreenPermission: currentScreenPermission,
            requestScreenPermission: requestScreenPermission,
            configureShortcuts: configureShortcuts,
            completion: {
                store.markCompleted()
                completion()
            }
        )
    }

    var page: Int { step.rawValue }
    var isFirstPage: Bool { step == .welcome }
    var isLastPage: Bool { step == .preferences }

    func moveBack() {
        guard let precedingStep = OnboardingStep(rawValue: page - 1) else { return }
        step = precedingStep
    }

    func moveForward() {
        guard !isLastPage else {
            guard !hasCompleted else { return }
            hasCompleted = true
            completion()
            return
        }
        guard let followingStep = OnboardingStep(rawValue: page + 1) else { return }
        step = followingStep
        refreshScreenPermission()
    }

    func refreshScreenPermission() {
        screenPermission = currentScreenPermission()
    }

    func requestScreenAccess() async {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        screenPermission = await requestScreenPermission()
        isRequestingPermission = false
    }

    func configureShortcuts() {
        configureShortcutsAction()
    }
}

struct OnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel
    @ObservedObject private var settings: AppSettingsModel

    init(
        viewModel: @autoclosure @escaping () -> OnboardingViewModel,
        settings: AppSettingsModel
    ) {
        _viewModel = StateObject(wrappedValue: viewModel())
        self.settings = settings
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch viewModel.step {
                case .welcome: welcomePage
                case .screenRecording: screenPermissionPage
                case .optionalAudio: audioPage
                case .preferences: preferencesPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(36)

            Divider()

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<OnboardingViewModel.pageCount, id: \.self) { page in
                        Circle()
                            .fill(page == viewModel.page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                if !viewModel.isFirstPage {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            viewModel.moveBack()
                        }
                    }
                    .accessibilityIdentifier("clip.onboarding.back")
                }

                Button(viewModel.isLastPage ? "Start Using Clip" : "Continue") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.moveForward()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("clip.onboarding.continue")
            }
            .padding(20)
        }
        .frame(width: 610, height: 440)
        .accessibilityIdentifier("clip.onboarding")
    }

    private var welcomePage: some View {
        onboardingPage(
            symbol: "record.circle",
            title: "Quick screen recordings",
            message: "Select an area, record a short demonstration, trim it, then drag or copy a compact MP4 in seconds. Everything stays on this Mac."
        ) {
            Label("Select, record, trim, drag or copy", systemImage: "sparkles")
                .font(.headline)
        }
        .accessibilityIdentifier("clip.onboarding.welcome")
    }

    private var screenPermissionPage: some View {
        onboardingPage(
            symbol: "rectangle.dashed.badge.record",
            title: "Allow screen recording",
            message: "macOS requires Screen & System Audio Recording access before Clip can record the area or display you choose. Clip excludes its own windows and keeps recordings local."
        ) {
            VStack(spacing: 10) {
                Label(screenPermissionTitle, systemImage: screenPermissionSymbol)
                    .foregroundStyle(screenPermissionTint)
                    .accessibilityIdentifier("clip.onboarding.screenRecording.status")

                if viewModel.screenPermission != .granted {
                    Button("Request Screen Recording Access") {
                        Task { @MainActor in
                            await viewModel.requestScreenAccess()
                        }
                    }
                    .disabled(viewModel.isRequestingPermission)
                    .accessibilityIdentifier("clip.onboarding.requestScreenRecording")

                    Text("You can continue now and grant access when you make the first recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("clip.onboarding.screenRecording")
    }

    private var audioPage: some View {
        onboardingPage(
            symbol: "waveform",
            title: "Audio is optional",
            message: "Record without audio, with the current default microphone, with system audio, or with both. Audio starts Off and its permissions are requested only when you enable it."
        ) {
            HStack(spacing: 20) {
                Label("Microphone: Off", systemImage: "mic.slash")
                Label("System Audio: Off", systemImage: "speaker.slash")
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("clip.onboarding.optionalAudio")
    }

    private var preferencesPage: some View {
        onboardingPage(
            symbol: "command",
            title: "Ready when you are",
            message: "Clip lives in the menu bar. Use the global Capture shortcut from any app, or click the Clip icon to choose an area, Last Area, or a full display."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Launch Clip at login", isOn: launchAtLoginBinding)
                Toggle("Show Clip in the Dock", isOn: showInDockBinding)
                LabeledContent("Capture shortcut") {
                    Text(settings.settings.shortcuts.capture.onboardingDisplayName)
                        .fontDesign(.monospaced)
                }
                Button("Customize Shortcuts in Settings…") {
                    viewModel.configureShortcuts()
                }
                .accessibilityIdentifier("clip.onboarding.configureShortcuts")
            }
            .frame(width: 330)
        }
        .accessibilityIdentifier("clip.onboarding.preferences")
    }

    private func onboardingPage<Content: View>(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 58, weight: .medium))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(title)
                .font(.largeTitle.bold())

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            content()
                .padding(.top, 4)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        settingsBinding(\.launchAtLogin)
    }

    private var showInDockBinding: Binding<Bool> {
        settingsBinding(\.showInDock)
    }

    private func settingsBinding<Value: Sendable>(
        _ keyPath: WritableKeyPath<ClipSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings.settings[keyPath: keyPath] },
            set: { value in
                Task { @MainActor in
                    await settings.update { $0[keyPath: keyPath] = value }
                }
            }
        )
    }

    private var screenPermissionTitle: String {
        switch viewModel.screenPermission {
        case .granted: String(localized: "Screen Recording allowed")
        case .notDetermined: String(localized: "Screen Recording not requested")
        case .denied: String(localized: "Screen Recording denied")
        case .restricted: String(localized: "Screen Recording restricted")
        }
    }

    private var screenPermissionSymbol: String {
        viewModel.screenPermission == .granted
            ? "checkmark.circle.fill"
            : "exclamationmark.circle"
    }

    private var screenPermissionTint: Color {
        viewModel.screenPermission == .granted ? .green : .secondary
    }
}

private extension ClipCore.KeyboardShortcut {
    var onboardingDisplayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + key.uppercased()
    }
}
