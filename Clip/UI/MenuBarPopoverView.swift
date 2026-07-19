import AppKit
import ClipCore
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

@MainActor
final class MenuBarPopoverModel: ObservableObject {
    static let recentRecordingLimit = 3

    @Published private(set) var displays: [MenuBarDisplayRow]
    @Published private(set) var preparedDisplayID: CGDirectDisplayID?
    @Published private(set) var microphone: MenuBarAudioState
    @Published private(set) var systemAudio: MenuBarAudioState
    @Published private(set) var recentRecordings: [MenuBarRecentRecordingRow]
    @Published private(set) var isLastAreaAvailable: Bool
    @Published private(set) var isFullscreenAvailable: Bool

    init(
        displays: [MenuBarDisplayRow] = [],
        preparedDisplayID: CGDirectDisplayID? = nil,
        microphone: MenuBarAudioState = .init(),
        systemAudio: MenuBarAudioState = .init(),
        recentRecordings: [MenuBarRecentRecordingRow] = [],
        isLastAreaAvailable: Bool = false,
        isFullscreenAvailable: Bool = false
    ) {
        self.displays = displays
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.recentRecordings = Array(recentRecordings.prefix(Self.recentRecordingLimit))
        self.isLastAreaAvailable = isLastAreaAvailable
        self.isFullscreenAvailable = isFullscreenAvailable
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

    func replaceRecentRecordings(_ recordings: [MenuBarRecentRecordingRow]) {
        recentRecordings = Array(recordings.prefix(Self.recentRecordingLimit))
    }
}

@MainActor
struct MenuBarActions {
    let captureArea: () -> Void
    let lastArea: () -> Void
    let fullscreen: () -> Void
    let captureApplication: () -> Void
    let prepareDisplay: (CGDirectDisplayID) -> Void
    let recordPreparedDisplay: (CGDirectDisplayID) -> Void
    let setMicrophoneEnabled: (Bool) -> Void
    let setSystemAudioEnabled: (Bool) -> Void
    let openRecentRecording: (RecordingID) -> Void
    let openHistory: () -> Void
    let openSettings: () -> Void
    let checkForUpdates: () -> Void
    let quit: () -> Void

    init(
        captureArea: @escaping () -> Void,
        lastArea: @escaping () -> Void,
        fullscreen: @escaping () -> Void,
        captureApplication: @escaping () -> Void = {},
        prepareDisplay: @escaping (CGDirectDisplayID) -> Void = { _ in },
        recordPreparedDisplay: @escaping (CGDirectDisplayID) -> Void = { _ in },
        setMicrophoneEnabled: @escaping (Bool) -> Void = { _ in },
        setSystemAudioEnabled: @escaping (Bool) -> Void = { _ in },
        openRecentRecording: @escaping (RecordingID) -> Void = { _ in },
        openHistory: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void = {},
        quit: @escaping () -> Void
    ) {
        self.captureArea = captureArea
        self.lastArea = lastArea
        self.fullscreen = fullscreen
        self.captureApplication = captureApplication
        self.prepareDisplay = prepareDisplay
        self.recordPreparedDisplay = recordPreparedDisplay
        self.setMicrophoneEnabled = setMicrophoneEnabled
        self.setSystemAudioEnabled = setSystemAudioEnabled
        self.openRecentRecording = openRecentRecording
        self.openHistory = openHistory
        self.openSettings = openSettings
        self.checkForUpdates = checkForUpdates
        self.quit = quit
    }
}

struct MenuBarPopoverView: View {
    @StateObject private var model: MenuBarPopoverModel
    let actions: MenuBarActions

    init(model: MenuBarPopoverModel, actions: MenuBarActions) {
        _model = StateObject(wrappedValue: model)
        self.actions = actions
    }

    /// Compatibility initializer for the coordinator while it adopts the live model.
    init(actions: MenuBarActions) {
        _model = StateObject(
            wrappedValue: MenuBarPopoverModel(
                isLastAreaAvailable: true,
                isFullscreenAvailable: true
            )
        )
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            captureTargets

            if let preparedDisplay = model.preparedDisplay {
                preparedTarget(preparedDisplay)
            }

            Divider()
            audioControls

            if !model.recentRecordings.isEmpty {
                Divider()
                recentRecordings
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.menuBarPopover")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "record.circle")
                .font(.title2)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Clip")
                    .font(.headline)
                Text(model.preparedDisplay == nil ? "Ready to record" : "Capture target prepared")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let version = MenuBarApplicationVersion.currentDisplayString {
                Text(verbatim: version)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .accessibilityLabel(
                        Text(verbatim: "Version \(version.dropFirst())")
                    )
                    .accessibilityIdentifier("clip.menu.version")
            }
        }
    }

    private var captureTargets: some View {
        VStack(spacing: 2) {
            menuButton(
                "Capture Area…",
                systemImage: "viewfinder",
                identifier: "clip.menu.captureArea",
                action: actions.captureArea
            )

            if model.isLastAreaAvailable {
                menuButton(
                    "Last Area",
                    systemImage: "rectangle.dashed",
                    identifier: "clip.menu.lastArea",
                    action: actions.lastArea
                )
            }

            menuButton(
                "Capture App…",
                systemImage: "app.badge.checkmark",
                identifier: "clip.menu.captureApplication",
                action: actions.captureApplication
            )

            if model.isFullscreenAvailable {
                menuButton(
                    "Fullscreen",
                    systemImage: "macwindow",
                    identifier: "clip.menu.fullscreen",
                    action: actions.fullscreen
                )
            }

            ForEach(model.displays) { display in
                Button {
                    model.prepareDisplay(id: display.id)
                    actions.prepareDisplay(display.id)
                } label: {
                    HStack {
                        Image(systemName: model.preparedDisplayID == display.id
                              ? "checkmark.circle.fill"
                              : "display")
                            .frame(width: 18)
                        Text(display.name)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(display.resolution)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 5)
                .modifier(MenuRowHoverEffect())
                .accessibilityLabel("\(display.name), \(display.resolution)")
                .accessibilityIdentifier("clip.menu.display.\(display.id)")
            }
        }
    }

    private func preparedTarget(_ display: MenuBarDisplayRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(display.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(display.resolution)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                actions.recordPreparedDisplay(display.id)
            } label: {
                Label("Record", systemImage: "record.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .modifier(MenuProminentControlHoverEffect())
            .accessibilityIdentifier("clip.menu.recordPrepared")
        }
        .padding(10)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private var audioControls: some View {
        VStack(spacing: 8) {
            audioToggle(
                title: "Microphone",
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
            audioToggle(
                title: "System Audio",
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
        }
    }

    private var recentRecordings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Recordings")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(model.recentRecordings) { recording in
                Button {
                    actions.openRecentRecording(recording.id)
                } label: {
                    HStack {
                        Image(systemName: "play.rectangle")
                            .frame(width: 18)
                        Text(recording.filename)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(recording.formattedByteCount)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .modifier(MenuRowHoverEffect())
                .accessibilityLabel("Open \(recording.filename), \(recording.formattedByteCount)")
                .accessibilityIdentifier("clip.menu.recent.\(recording.id.description)")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 1) {
            menuButton(
                "History",
                systemImage: "clock.arrow.circlepath",
                identifier: "clip.menu.history",
                action: actions.openHistory
            )
            menuButton(
                "Settings",
                systemImage: "gearshape",
                identifier: "clip.menu.settings",
                action: actions.openSettings
            )
            menuButton(
                "Check for Updates…",
                systemImage: "arrow.triangle.2.circlepath",
                identifier: "clip.menu.checkForUpdates",
                action: actions.checkForUpdates
            )
            menuButton(
                "Quit Clip",
                systemImage: "power",
                identifier: "clip.menu.quit",
                action: actions.quit
            )
        }
    }

    private func menuButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 5)
        .modifier(MenuRowHoverEffect())
        .accessibilityIdentifier(identifier)
    }

    private func audioToggle(
        title: LocalizedStringKey,
        systemImage: String,
        state: MenuBarAudioState,
        identifier: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(state.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!state.isAvailable)
        .modifier(MenuRowHoverEffect(isInteractive: state.isAvailable))
        .help(state.detail ?? state.status)
        .accessibilityIdentifier(identifier)
    }
}

private struct MenuRowHoverEffect: ViewModifier {
    let isInteractive: Bool
    @State private var isHovered = false

    init(isInteractive: Bool = true) {
        self.isInteractive = isInteractive
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered && isInteractive ? Color.primary.opacity(0.09) : .clear)
            }
            .contentShape(Rectangle())
            .modifier(MenuPointingHandCursorEffect(isEnabled: isInteractive))
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

/// Keeps the prominent prepared-target action consistent with the menu rows.
/// Its native button style already changes on hover; the explicit highlight
/// remains visible across accent colors and appearance modes.
private struct MenuProminentControlHoverEffect: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.14 : 0))
                    .allowsHitTesting(false)
            }
            .modifier(MenuPointingHandCursorEffect())
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

/// Uses AppKit's balanced cursor-rectangle lifecycle instead of mutating the
/// process-global cursor stack from SwiftUI hover callbacks.
private struct MenuPointingHandCursorEffect: ViewModifier {
    let isEnabled: Bool

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    func body(content: Content) -> some View {
        content.overlay {
            MenuPointingHandCursorRegion(isEnabled: isEnabled)
                .accessibilityHidden(true)
        }
    }
}

private struct MenuPointingHandCursorRegion: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> MenuPointingHandCursorView {
        let view = MenuPointingHandCursorView(frame: .zero)
        view.isEnabled = isEnabled
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: MenuPointingHandCursorView, context: Context) {
        nsView.isEnabled = isEnabled
    }
}

final class MenuPointingHandCursorView: NSView {
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    var registeredCursor: NSCursor? {
        isEnabled ? .pointingHand : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let registeredCursor, !bounds.isEmpty else { return }
        addCursorRect(bounds, cursor: registeredCursor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = frame.size != newSize
        super.setFrameSize(newSize)
        if sizeChanged {
            window?.invalidateCursorRects(for: self)
        }
    }

    /// The transparent cursor surface must never intercept the control below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
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
