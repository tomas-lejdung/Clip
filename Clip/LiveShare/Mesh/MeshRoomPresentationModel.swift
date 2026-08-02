import Foundation

@MainActor
struct MeshRoomPresentationActions {
    var copyText: (String) -> Void
    var setAccessWordEnabled: (Bool) -> Void
    var setAskBeforeJoining: (Bool) -> Void
    var replaceAccessWord: () -> Void
    var changeInvite: () -> Void
    var approveAdmission: (String) -> Void
    var denyAdmission: (String) -> Void
    var removeParticipant: (String) -> Void
    var addFriend: (String) -> Void
    var allowFriendRequest: (String) -> Void
    var denyFriendRequest: (String) -> Void
    var retryFriendship: (String) -> Void
    var shareFocusedWindow: () -> Void
    var shareWindow: (String) -> Void
    var stopLocalSource: (String) -> Void
    var setFullscreenEnabled: (Bool) -> Void
    var setQuality: (LiveShareQualityPreset) -> Void
    var setFrameRate: (LiveShareFrameRate) -> Void
    var setCodec: (LiveShareVideoCodec) -> Void
    var setColorMode: (LiveShareColorMode) -> Void
    var setSystemAudioEnabled: (Bool) -> Void
    var setExcludedAudioApplicationIDs: (Set<String>) -> Void
    var setCursorUpdatesMatchFrameRate: (Bool) -> Void
    var setPrioritizeFocusedWindow: (Bool) -> Void
    var setMode: (LiveShareEncodingMode) -> Void
    var setAdvancedVideoSettings: (
        LiveShareVideoCodec,
        LiveShareCodecAdvancedSettings
    ) -> Void
    var setAutoShareEnabled: (Bool) -> Void
    var stopLocalMedia: () -> Void
    var setParticipantAudioEnabled: (String, Bool) -> Void
    var setParticipantVolume: (String, Double) -> Void
    var setRemoteSourceScaleMode: (
        MeshRoomSourceKey,
        NativeViewerScaleMode
    ) -> Void
    var setRemoteSourceVisible: (MeshRoomSourceKey, Bool) -> Void
    var toggleRemoteSourceFullScreen: (MeshRoomSourceKey) -> Void
    var bringRemoteSourceToFront: (MeshRoomSourceKey) -> Void
    var bringParticipantToFront: (String) -> Void
    var bringAllRemoteWindowsToFront: () -> Void
    var setLocalPointerVisible: (Bool) -> Void
    var setLocalPingModeEnabled: (Bool) -> Void
    var setLocalInkEnabled: (Bool) -> Void
    var clearAnnotations: () -> Void
    var retry: () -> Void
    var leaveRoom: () -> Void
    var endRoomForEveryone: () -> Void

    init(
        copyText: @escaping (String) -> Void = { _ in },
        setAccessWordEnabled: @escaping (Bool) -> Void = { _ in },
        setAskBeforeJoining: @escaping (Bool) -> Void = { _ in },
        replaceAccessWord: @escaping () -> Void = {},
        changeInvite: @escaping () -> Void = {},
        approveAdmission: @escaping (String) -> Void = { _ in },
        denyAdmission: @escaping (String) -> Void = { _ in },
        removeParticipant: @escaping (String) -> Void = { _ in },
        addFriend: @escaping (String) -> Void = { _ in },
        allowFriendRequest: @escaping (String) -> Void = { _ in },
        denyFriendRequest: @escaping (String) -> Void = { _ in },
        retryFriendship: @escaping (String) -> Void = { _ in },
        shareFocusedWindow: @escaping () -> Void = {},
        shareWindow: @escaping (String) -> Void = { _ in },
        stopLocalSource: @escaping (String) -> Void = { _ in },
        setFullscreenEnabled: @escaping (Bool) -> Void = { _ in },
        setQuality: @escaping (LiveShareQualityPreset) -> Void = { _ in },
        setFrameRate: @escaping (LiveShareFrameRate) -> Void = { _ in },
        setCodec: @escaping (LiveShareVideoCodec) -> Void = { _ in },
        setColorMode: @escaping (LiveShareColorMode) -> Void = { _ in },
        setSystemAudioEnabled: @escaping (Bool) -> Void = { _ in },
        setExcludedAudioApplicationIDs: @escaping (Set<String>) -> Void = {
            _ in
        },
        setCursorUpdatesMatchFrameRate: @escaping (Bool) -> Void = { _ in },
        setPrioritizeFocusedWindow: @escaping (Bool) -> Void = { _ in },
        setMode: @escaping (LiveShareEncodingMode) -> Void = { _ in },
        setAdvancedVideoSettings: @escaping (
            LiveShareVideoCodec,
            LiveShareCodecAdvancedSettings
        ) -> Void = { _, _ in },
        setAutoShareEnabled: @escaping (Bool) -> Void = { _ in },
        stopLocalMedia: @escaping () -> Void = {},
        setParticipantAudioEnabled: @escaping (String, Bool) -> Void = {
            _, _ in
        },
        setParticipantVolume: @escaping (String, Double) -> Void = { _, _ in },
        setRemoteSourceScaleMode: @escaping (
            MeshRoomSourceKey,
            NativeViewerScaleMode
        ) -> Void = { _, _ in },
        setRemoteSourceVisible: @escaping (MeshRoomSourceKey, Bool) -> Void = {
            _, _ in
        },
        toggleRemoteSourceFullScreen: @escaping (MeshRoomSourceKey) -> Void = {
            _ in
        },
        bringRemoteSourceToFront: @escaping (MeshRoomSourceKey) -> Void = {
            _ in
        },
        bringParticipantToFront: @escaping (String) -> Void = { _ in },
        bringAllRemoteWindowsToFront: @escaping () -> Void = {},
        setLocalPointerVisible: @escaping (Bool) -> Void = { _ in },
        setLocalPingModeEnabled: @escaping (Bool) -> Void = { _ in },
        setLocalInkEnabled: @escaping (Bool) -> Void = { _ in },
        clearAnnotations: @escaping () -> Void = {},
        retry: @escaping () -> Void = {},
        leaveRoom: @escaping () -> Void = {},
        endRoomForEveryone: @escaping () -> Void = {}
    ) {
        self.copyText = copyText
        self.setAccessWordEnabled = setAccessWordEnabled
        self.setAskBeforeJoining = setAskBeforeJoining
        self.replaceAccessWord = replaceAccessWord
        self.changeInvite = changeInvite
        self.approveAdmission = approveAdmission
        self.denyAdmission = denyAdmission
        self.removeParticipant = removeParticipant
        self.addFriend = addFriend
        self.allowFriendRequest = allowFriendRequest
        self.denyFriendRequest = denyFriendRequest
        self.retryFriendship = retryFriendship
        self.shareFocusedWindow = shareFocusedWindow
        self.shareWindow = shareWindow
        self.stopLocalSource = stopLocalSource
        self.setFullscreenEnabled = setFullscreenEnabled
        self.setQuality = setQuality
        self.setFrameRate = setFrameRate
        self.setCodec = setCodec
        self.setColorMode = setColorMode
        self.setSystemAudioEnabled = setSystemAudioEnabled
        self.setExcludedAudioApplicationIDs =
            setExcludedAudioApplicationIDs
        self.setCursorUpdatesMatchFrameRate = setCursorUpdatesMatchFrameRate
        self.setPrioritizeFocusedWindow = setPrioritizeFocusedWindow
        self.setMode = setMode
        self.setAdvancedVideoSettings = setAdvancedVideoSettings
        self.setAutoShareEnabled = setAutoShareEnabled
        self.stopLocalMedia = stopLocalMedia
        self.setParticipantAudioEnabled = setParticipantAudioEnabled
        self.setParticipantVolume = setParticipantVolume
        self.setRemoteSourceScaleMode = setRemoteSourceScaleMode
        self.setRemoteSourceVisible = setRemoteSourceVisible
        self.toggleRemoteSourceFullScreen = toggleRemoteSourceFullScreen
        self.bringRemoteSourceToFront = bringRemoteSourceToFront
        self.bringParticipantToFront = bringParticipantToFront
        self.bringAllRemoteWindowsToFront = bringAllRemoteWindowsToFront
        self.setLocalPointerVisible = setLocalPointerVisible
        self.setLocalPingModeEnabled = setLocalPingModeEnabled
        self.setLocalInkEnabled = setLocalInkEnabled
        self.clearAnnotations = clearAnnotations
        self.retry = retry
        self.leaveRoom = leaveRoom
        self.endRoomForEveryone = endRoomForEveryone
    }

    static let noOp = Self()
}

@MainActor
final class MeshRoomPresentationModel: ObservableObject {
    @Published private(set) var snapshot: MeshRoomViewSnapshot
    @Published private(set) var copiedInvite = false
    @Published private(set) var isInviteChangeConfirmationPresented = false

    private let actions: MeshRoomPresentationActions
    private let copiedFeedbackDuration: Duration
    private var clearCopiedTask: Task<Void, Never>?

    init(
        snapshot: MeshRoomViewSnapshot,
        actions: MeshRoomPresentationActions,
        copiedFeedbackDuration: Duration = .seconds(1.5)
    ) {
        self.snapshot = snapshot
        self.actions = actions
        self.copiedFeedbackDuration = copiedFeedbackDuration
    }

    func update(_ snapshot: MeshRoomViewSnapshot) {
        self.snapshot = snapshot
        if !canManageRoom {
            isInviteChangeConfirmationPresented = false
        }
    }

    func copyInvite() {
        guard snapshot.isLocalCreator,
              let invite = snapshot.invite,
              invite.isAvailable else { return }
        actions.copyText(invite.url.absoluteString)
        showCopiedInvite()
    }

    func setAccessWordEnabled(_ enabled: Bool) {
        guard canManageRoom, snapshot.canChangeAccessWord else { return }
        actions.setAccessWordEnabled(enabled)
    }

    func setAskBeforeJoining(_ enabled: Bool) {
        guard canManageRoom,
              snapshot.canChangeAskBeforeJoining else { return }
        actions.setAskBeforeJoining(enabled)
    }

    func replaceAccessWord() {
        guard canManageRoom,
              snapshot.canChangeAccessWord,
              snapshot.accessWordEnabled else { return }
        actions.replaceAccessWord()
    }

    func copyAccessWord() {
        guard canManageRoom,
              snapshot.canChangeAccessWord,
              snapshot.accessWordEnabled,
              let accessWord = snapshot.accessWord,
              !accessWord.isEmpty else { return }
        actions.copyText(accessWord)
    }

    func requestInviteChangeConfirmation() {
        guard canManageRoom else { return }
        isInviteChangeConfirmationPresented = true
    }

    func cancelInviteChange() {
        isInviteChangeConfirmationPresented = false
    }

    func confirmInviteChange() {
        guard isInviteChangeConfirmationPresented, canManageRoom else {
            isInviteChangeConfirmationPresented = false
            return
        }
        isInviteChangeConfirmationPresented = false
        actions.changeInvite()
    }

    func approveAdmission(_ participantID: String) {
        guard canManageRoom,
              snapshot.pendingAdmissions.contains(where: {
                  $0.id == participantID
              }) else { return }
        actions.approveAdmission(participantID)
    }

    func denyAdmission(_ participantID: String) {
        guard canManageRoom,
              snapshot.pendingAdmissions.contains(where: {
                  $0.id == participantID
              }) else { return }
        actions.denyAdmission(participantID)
    }

    func removeParticipant(_ participantID: String) {
        guard canManageRoom,
              snapshot.remoteParticipants.contains(where: {
                  $0.id == participantID
              }) else { return }
        actions.removeParticipant(participantID)
    }

    func addFriend(_ participantID: String) {
        guard canChangeFriendships,
              let participant = participant(participantID),
              participant.clientKind.supportsFriendship,
              participant.route.isConnected,
              participant.friendshipState == .available else { return }
        actions.addFriend(participantID)
    }

    func allowFriendRequest(_ requestID: String) {
        guard canChangeFriendships,
              snapshot.pendingFriendRequests.contains(where: {
                  $0.id == requestID
              }) else { return }
        actions.allowFriendRequest(requestID)
    }

    func denyFriendRequest(_ requestID: String) {
        guard canChangeFriendships,
              snapshot.pendingFriendRequests.contains(where: {
                  $0.id == requestID
              }) else { return }
        actions.denyFriendRequest(requestID)
    }

    func retryFriendship(_ participantID: String) {
        guard canChangeFriendships,
              let participant = participant(participantID),
              participant.route.isConnected else { return }
        switch participant.friendshipState {
        case .requestPending, .failed:
            actions.retryFriendship(participantID)
        case .available, .incomingRequest, .trusted:
            return
        }
    }

    func shareFocusedWindow() {
        guard canChangeLocalMedia,
              snapshot.canShareFocusedWindow,
              !snapshot.settings.autoShareFocusedWindows else { return }
        actions.shareFocusedWindow()
    }

    func shareWindow(_ id: String) {
        guard canChangeLocalMedia,
              snapshot.canAddWindow,
              !snapshot.settings.autoShareFocusedWindows,
              snapshot.availableWindows.contains(where: {
                  $0.id == id
              }) else { return }
        actions.shareWindow(id)
    }

    func stopLocalSource(_ id: String) {
        guard canChangeLocalMedia,
              !snapshot.settings.autoShareFocusedWindows,
              snapshot.localSources.contains(where: {
                  $0.id == id && $0.canStop
              }) else { return }
        actions.stopLocalSource(id)
    }

    func setFullscreenEnabled(_ enabled: Bool) {
        guard canChangeLocalMedia, snapshot.fullscreen.isEnabled else { return }
        actions.setFullscreenEnabled(enabled)
    }

    func setQuality(_ quality: LiveShareQualityPreset) {
        guard canChangeLocalMedia,
              snapshot.settings.canChangeQuality else { return }
        actions.setQuality(quality)
    }

    func setFrameRate(_ frameRate: LiveShareFrameRate) {
        guard canChangeLocalMedia,
              snapshot.settings.canChangeFrameRate,
              snapshot.settings.availableFrameRates.contains(frameRate) else {
            return
        }
        actions.setFrameRate(frameRate)
    }

    func setCodec(_ codec: LiveShareVideoCodec) {
        guard canChangeLocalMedia,
              snapshot.settings.canChangeCodec else { return }
        actions.setCodec(codec)
    }

    func setColorMode(_ colorMode: LiveShareColorMode) {
        guard canChangeLocalMedia,
              snapshot.settings.canChangeColorMode else { return }
        actions.setColorMode(colorMode)
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        guard canChangeLocalMedia,
              snapshot.settings.canChangeSystemAudio else { return }
        actions.setSystemAudioEnabled(enabled)
    }

    func setExcludedAudioApplicationIDs(_ identifiers: Set<String>) {
        guard canChangeLocalMedia,
              snapshot.settings.canChangeAudioExclusions else { return }
        let availableIdentifiers = Set(
            snapshot.settings.audioExclusionApplications.map(\.id)
        )
        actions.setExcludedAudioApplicationIDs(
            identifiers.intersection(availableIdentifiers)
        )
    }

    func setCursorUpdatesMatchFrameRate(_ enabled: Bool) {
        guard canChangeLocalMedia,
              snapshot.settings.canChangeCursorUpdateRate else { return }
        actions.setCursorUpdatesMatchFrameRate(enabled)
    }

    func setPrioritizeFocusedWindow(_ enabled: Bool) {
        guard canChangeLocalMedia,
              snapshot.settings.canChangePrioritizeFocusedWindow else {
            return
        }
        actions.setPrioritizeFocusedWindow(enabled)
    }

    func setMode(_ mode: LiveShareEncodingMode) {
        guard canChangeLocalMedia,
              snapshot.settings.canChangeMode else { return }
        actions.setMode(mode)
    }

    func setAdvancedVideoSettings(
        _ settings: LiveShareCodecAdvancedSettings,
        for codec: LiveShareVideoCodec
    ) {
        guard canChangeLocalMedia,
              snapshot.settings.canChangeMode else { return }
        actions.setAdvancedVideoSettings(
            codec,
            settings.normalized(for: codec)
        )
    }

    func setAutoShareEnabled(_ enabled: Bool) {
        guard canChangeLocalMedia,
              snapshot.settings.canChangeAutoShare,
              !snapshot.fullscreen.isOn else { return }
        actions.setAutoShareEnabled(enabled)
    }

    func stopLocalMedia() {
        guard canChangeLocalMedia, snapshot.hasLocalMedia else { return }
        actions.stopLocalMedia()
    }

    func setParticipantAudioEnabled(
        _ participantID: String,
        _ enabled: Bool
    ) {
        guard let participant = participant(participantID),
              participant.systemAudioAvailable else { return }
        actions.setParticipantAudioEnabled(participantID, enabled)
    }

    func setParticipantVolume(_ participantID: String, _ volume: Double) {
        guard let participant = participant(participantID),
              participant.systemAudioAvailable else { return }
        actions.setParticipantVolume(
            participantID,
            min(max(volume, 0), 1)
        )
    }

    func setRemoteSourceScaleMode(
        _ key: MeshRoomSourceKey,
        _ mode: NativeViewerScaleMode
    ) {
        guard remoteSource(key) != nil else { return }
        actions.setRemoteSourceScaleMode(key, mode)
    }

    func setRemoteSourceVisible(
        _ key: MeshRoomSourceKey,
        _ visible: Bool
    ) {
        guard remoteSource(key) != nil else { return }
        actions.setRemoteSourceVisible(key, visible)
    }

    func toggleRemoteSourceFullScreen(_ key: MeshRoomSourceKey) {
        guard let source = remoteSource(key),
              source.isConnected,
              source.isVisible else { return }
        actions.toggleRemoteSourceFullScreen(key)
    }

    func bringRemoteSourceToFront(_ key: MeshRoomSourceKey) {
        guard remoteSource(key) != nil else { return }
        actions.bringRemoteSourceToFront(key)
    }

    func bringParticipantToFront(_ participantID: String) {
        guard let participant = participant(participantID),
              !participant.sources.isEmpty else { return }
        actions.bringParticipantToFront(participantID)
    }

    func bringAllRemoteWindowsToFront() {
        guard snapshot.remoteParticipants.contains(where: {
            !$0.sources.isEmpty
        }) else { return }
        actions.bringAllRemoteWindowsToFront()
    }

    func setLocalPointerVisible(_ enabled: Bool) {
        guard snapshot.phase.isConnected else { return }
        actions.setLocalPointerVisible(enabled)
    }

    func setLocalPingModeEnabled(_ enabled: Bool) {
        guard snapshot.phase.isConnected else { return }
        actions.setLocalPingModeEnabled(enabled)
    }

    func setLocalInkEnabled(_ enabled: Bool) {
        guard snapshot.phase.isConnected else { return }
        actions.setLocalInkEnabled(enabled)
    }

    func clearAnnotations() {
        guard snapshot.phase.isConnected,
              snapshot.collaboration.canClearAnnotations else { return }
        actions.clearAnnotations()
    }

    func retry() {
        guard snapshot.phase.isTerminal else { return }
        actions.retry()
    }

    func leaveRoom() {
        guard snapshot.canLeaveRoom, !snapshot.phase.isTerminal else { return }
        actions.leaveRoom()
    }

    func endRoomForEveryone() {
        guard snapshot.isLocalCreator,
              snapshot.canEndRoom,
              !snapshot.phase.isTerminal else { return }
        actions.endRoomForEveryone()
    }

    private var canManageRoom: Bool {
        snapshot.isLocalCreator
            && snapshot.creatorParticipantID != nil
            && snapshot.phase.isConnected
    }

    private var canChangeLocalMedia: Bool {
        snapshot.phase.allowsMediaChanges
    }

    /// A reconnecting room retains its last verified roster so windows can
    /// remain visible, but it has no reliable participant channel on which to
    /// begin or retry a friendship handshake. Treat only the live phase as an
    /// actionable friendship state.
    private var canChangeFriendships: Bool {
        snapshot.phase.allowsMediaChanges
    }

    private func participant(
        _ participantID: String
    ) -> MeshRoomRemoteParticipantSnapshot? {
        snapshot.remoteParticipants.first { $0.id == participantID }
    }

    private func remoteSource(
        _ key: MeshRoomSourceKey
    ) -> MeshRoomRemoteSourceSnapshot? {
        participant(key.participantID)?.sources.first {
            $0.id == key.sourceID
        }
    }

    private func showCopiedInvite() {
        clearCopiedTask?.cancel()
        copiedInvite = true
        let duration = copiedFeedbackDuration
        clearCopiedTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            self?.copiedInvite = false
            self?.clearCopiedTask = nil
        }
    }
}
