import Foundation

@MainActor
struct NativeViewerPresentationActions {
    var submitAccessCode: (String) -> Void
    var setSystemAudioEnabled: (Bool) -> Void
    var setVolume: (Double) -> Void
    var setScaleMode: (NativeViewerScaleMode) -> Void
    var setSourceVisible: (String, Bool) -> Void
    var showAll: () -> Void
    var requestFriendship: () -> Void
    var retry: () -> Void
    var leave: () -> Void

    init(
        submitAccessCode: @escaping (String) -> Void = { _ in },
        setSystemAudioEnabled: @escaping (Bool) -> Void = { _ in },
        setVolume: @escaping (Double) -> Void = { _ in },
        setScaleMode: @escaping (NativeViewerScaleMode) -> Void = { _ in },
        setSourceVisible: @escaping (String, Bool) -> Void = { _, _ in },
        showAll: @escaping () -> Void = {},
        requestFriendship: @escaping () -> Void = {},
        retry: @escaping () -> Void = {},
        leave: @escaping () -> Void = {}
    ) {
        self.submitAccessCode = submitAccessCode
        self.setSystemAudioEnabled = setSystemAudioEnabled
        self.setVolume = setVolume
        self.setScaleMode = setScaleMode
        self.setSourceVisible = setSourceVisible
        self.showAll = showAll
        self.requestFriendship = requestFriendship
        self.retry = retry
        self.leave = leave
    }
}

@MainActor
final class NativeViewerPresentationModel: ObservableObject {
    @Published private(set) var snapshot: NativeViewerViewSnapshot

    private let actions: NativeViewerPresentationActions

    init(
        snapshot: NativeViewerViewSnapshot = .init(),
        actions: NativeViewerPresentationActions
    ) {
        self.snapshot = snapshot
        self.actions = actions
    }

    func update(_ snapshot: NativeViewerViewSnapshot) {
        self.snapshot = snapshot
    }

    func submitAccessCode(_ value: String) {
        guard snapshot.phase == .waitingForAccessCode else { return }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        actions.submitAccessCode(normalized)
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        guard snapshot.systemAudioAvailable else { return }
        actions.setSystemAudioEnabled(enabled)
    }

    func setVolume(_ value: Double) {
        guard snapshot.systemAudioAvailable else { return }
        actions.setVolume(min(max(value, 0), 1))
    }

    func setScaleMode(_ mode: NativeViewerScaleMode) {
        actions.setScaleMode(mode)
    }

    func setSourceVisible(_ id: String, _ visible: Bool) {
        guard snapshot.sources.contains(where: { $0.id == id }) else { return }
        actions.setSourceVisible(id, visible)
    }

    func showAll() {
        guard snapshot.visibleSourceCount < snapshot.sources.count else { return }
        actions.showAll()
    }

    func requestFriendship() {
        guard snapshot.friendship == .available else { return }
        actions.requestFriendship()
    }

    func retry() {
        guard snapshot.phase.isTerminal else { return }
        actions.retry()
    }

    func leave() {
        actions.leave()
    }
}
