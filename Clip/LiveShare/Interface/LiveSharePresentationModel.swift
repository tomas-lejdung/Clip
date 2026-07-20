import Foundation

enum LiveShareCopiedItem: Equatable, Sendable {
    case link
    case roomCode
    case accessCode
}

@MainActor
struct LiveSharePresentationActions {
    var copyText: (String) -> Void
    var setAccessCodeEnabled: (Bool) -> Void
    var replaceAccessCode: () -> Void
    var shareFocusedWindow: () -> Void
    var shareWindow: (String) -> Void
    var stopSource: (String) -> Void
    var setFullscreenEnabled: (Bool) -> Void
    var setQuality: (LiveShareQualityPreset) -> Void
    var setFrameRate: (LiveShareFrameRate) -> Void
    var setCodec: (LiveShareVideoCodec) -> Void
    var setPrioritizeFocusedWindow: (Bool) -> Void
    var setMode: (LiveShareEncodingMode) -> Void
    var setAutoShareEnabled: (Bool) -> Void
    var stopAllMedia: () -> Void
    var retry: () -> Void
    var stopSession: () -> Void

    init(
        copyText: @escaping (String) -> Void = { _ in },
        setAccessCodeEnabled: @escaping (Bool) -> Void = { _ in },
        replaceAccessCode: @escaping () -> Void = {},
        shareFocusedWindow: @escaping () -> Void = {},
        shareWindow: @escaping (String) -> Void = { _ in },
        stopSource: @escaping (String) -> Void = { _ in },
        setFullscreenEnabled: @escaping (Bool) -> Void = { _ in },
        setQuality: @escaping (LiveShareQualityPreset) -> Void = { _ in },
        setFrameRate: @escaping (LiveShareFrameRate) -> Void = { _ in },
        setCodec: @escaping (LiveShareVideoCodec) -> Void = { _ in },
        setPrioritizeFocusedWindow: @escaping (Bool) -> Void = { _ in },
        setMode: @escaping (LiveShareEncodingMode) -> Void = { _ in },
        setAutoShareEnabled: @escaping (Bool) -> Void = { _ in },
        stopAllMedia: @escaping () -> Void = {},
        retry: @escaping () -> Void = {},
        stopSession: @escaping () -> Void = {}
    ) {
        self.copyText = copyText
        self.setAccessCodeEnabled = setAccessCodeEnabled
        self.replaceAccessCode = replaceAccessCode
        self.shareFocusedWindow = shareFocusedWindow
        self.shareWindow = shareWindow
        self.stopSource = stopSource
        self.setFullscreenEnabled = setFullscreenEnabled
        self.setQuality = setQuality
        self.setFrameRate = setFrameRate
        self.setCodec = setCodec
        self.setPrioritizeFocusedWindow = setPrioritizeFocusedWindow
        self.setMode = setMode
        self.setAutoShareEnabled = setAutoShareEnabled
        self.stopAllMedia = stopAllMedia
        self.retry = retry
        self.stopSession = stopSession
    }

    static let noOp = Self()
}

@MainActor
final class LiveSharePresentationModel: ObservableObject {
    @Published private(set) var snapshot: LiveShareViewSnapshot
    @Published private(set) var copiedItem: LiveShareCopiedItem?

    private let actions: LiveSharePresentationActions
    private let copiedFeedbackDuration: Duration
    private var clearCopiedTask: Task<Void, Never>?

    init(
        snapshot: LiveShareViewSnapshot,
        actions: LiveSharePresentationActions,
        copiedFeedbackDuration: Duration = .seconds(1.5)
    ) {
        self.snapshot = snapshot
        self.actions = actions
        self.copiedFeedbackDuration = copiedFeedbackDuration
    }

    func update(_ snapshot: LiveShareViewSnapshot) {
        self.snapshot = snapshot
    }

    func copyLink() {
        guard let value = snapshot.room?.viewerURL.absoluteString else { return }
        actions.copyText(value)
        showCopied(.link)
    }

    func copyRoomCode() {
        guard let value = snapshot.room?.roomCode, !value.isEmpty else { return }
        actions.copyText(value)
        showCopied(.roomCode)
    }

    func copyAccessCode() {
        guard snapshot.accessCodeEnabled,
              let accessCode = snapshot.accessCode,
              !accessCode.isEmpty else { return }
        actions.copyText(accessCode)
        showCopied(.accessCode)
    }

    func setAccessCodeEnabled(_ enabled: Bool) {
        guard snapshot.canChangeAccessCode else { return }
        actions.setAccessCodeEnabled(enabled)
    }

    func replaceAccessCode() {
        guard snapshot.canChangeAccessCode, snapshot.accessCodeEnabled else { return }
        actions.replaceAccessCode()
    }

    func shareFocusedWindow() {
        guard snapshot.canShareFocusedWindow,
              !snapshot.settings.autoShareFocusedWindows else { return }
        actions.shareFocusedWindow()
    }

    func shareWindow(_ id: String) {
        guard snapshot.canAddWindow,
              !snapshot.settings.autoShareFocusedWindows,
              snapshot.availableWindows.contains(where: { $0.id == id }) else { return }
        actions.shareWindow(id)
    }

    func stopSource(_ id: String) {
        guard !snapshot.settings.autoShareFocusedWindows,
              snapshot.sources.contains(where: { $0.id == id && $0.canStop }) else { return }
        actions.stopSource(id)
    }

    func setFullscreenEnabled(_ enabled: Bool) {
        guard snapshot.fullscreen.isEnabled else { return }
        actions.setFullscreenEnabled(enabled)
    }

    func setQuality(_ quality: LiveShareQualityPreset) {
        guard snapshot.settings.canChangeQuality else { return }
        actions.setQuality(quality)
    }

    func setFrameRate(_ frameRate: LiveShareFrameRate) {
        guard snapshot.settings.canChangeFrameRate,
              snapshot.settings.availableFrameRates.contains(frameRate) else { return }
        actions.setFrameRate(frameRate)
    }

    func setCodec(_ codec: LiveShareVideoCodec) {
        guard snapshot.settings.canChangeCodec else { return }
        actions.setCodec(codec)
    }

    func setPrioritizeFocusedWindow(_ enabled: Bool) {
        guard snapshot.settings.canChangePrioritizeFocusedWindow else { return }
        actions.setPrioritizeFocusedWindow(enabled)
    }

    func setMode(_ mode: LiveShareEncodingMode) {
        guard snapshot.settings.canChangeMode else { return }
        actions.setMode(mode)
    }

    func setAutoShareEnabled(_ enabled: Bool) {
        guard snapshot.settings.canChangeAutoShare,
              !snapshot.fullscreen.isOn else { return }
        actions.setAutoShareEnabled(enabled)
    }

    func stopAllMedia() {
        guard snapshot.hasActiveMedia else { return }
        actions.stopAllMedia()
    }

    func retry() {
        guard snapshot.phase.isFailure else { return }
        actions.retry()
    }

    func stopSession() {
        guard snapshot.canStopSession else { return }
        actions.stopSession()
    }

    private func showCopied(_ item: LiveShareCopiedItem) {
        clearCopiedTask?.cancel()
        copiedItem = item
        let duration = copiedFeedbackDuration
        clearCopiedTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            self?.copiedItem = nil
            self?.clearCopiedTask = nil
        }
    }
}
