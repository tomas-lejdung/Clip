import Combine
import Foundation
import OSLog

@MainActor
final class RecordingPresentationModel: ObservableObject {
    static let cancellationConfirmationThreshold: TimeInterval = 3

    @Published private(set) var snapshot: RecordingPresentationSnapshot
    @Published private(set) var isPerformingAction = false
    @Published private(set) var isCancelConfirmationPresented = false
    @Published private(set) var actionErrorMessage: String?

    private let actions: RecordingPresentationActions
    private let clock: RecordingPresentationClock
    private var snapshotAnchorTime: TimeInterval
    private var actionTask: Task<Void, Never>?
    private var actionIdentifier: UUID?

    init(
        snapshot: RecordingPresentationSnapshot,
        actions: RecordingPresentationActions,
        clock: RecordingPresentationClock = .live
    ) {
        self.snapshot = snapshot
        self.actions = actions
        self.clock = clock
        snapshotAnchorTime = clock.now()
    }

    var canPauseOrResume: Bool {
        !isPerformingAction
            && snapshot.phase != .finishing
            && snapshot.hasReceivedFirstFrame
    }

    var canFinish: Bool {
        !isPerformingAction
            && snapshot.phase != .finishing
            && snapshot.hasReceivedFirstFrame
    }

    var canCancel: Bool {
        !isPerformingAction && snapshot.phase != .finishing
    }

    var pauseResumeTitle: String {
        snapshot.phase == .paused
            ? String(localized: "Resume")
            : String(localized: "Pause")
    }

    var pauseResumeSystemImage: String {
        snapshot.phase == .paused ? "play.fill" : "pause.fill"
    }

    func update(_ snapshot: RecordingPresentationSnapshot) {
        self.snapshot = snapshot
        snapshotAnchorTime = clock.now()
        if snapshot.phase == .finishing {
            isCancelConfirmationPresented = false
        }
    }

    func activeElapsedSeconds(at monotonicTime: TimeInterval? = nil) -> TimeInterval {
        let base = snapshot.activeElapsedSeconds
        guard snapshot.phase == .recording, snapshot.hasReceivedFirstFrame else { return base }
        let now = monotonicTime ?? clock.now()
        return base + max(0, now - snapshotAnchorTime)
    }

    func elapsedText(at monotonicTime: TimeInterval? = nil) -> String {
        RecordingDurationFormatter.string(
            seconds: activeElapsedSeconds(at: monotonicTime)
        )
    }

    func togglePauseResume() {
        guard canPauseOrResume else { return }
        perform(snapshot.phase == .paused ? actions.resume : actions.pause)
    }

    func requestFinish() {
        guard canFinish else { return }
        perform(actions.finish)
    }

    func requestCancel() {
        guard canCancel else { return }

        if activeElapsedSeconds() > Self.cancellationConfirmationThreshold {
            isCancelConfirmationPresented = true
        } else {
            perform(actions.cancel)
        }
    }

    func confirmCancel() {
        guard isCancelConfirmationPresented, canCancel else { return }
        isCancelConfirmationPresented = false
        perform(actions.cancel)
    }

    func dismissCancelConfirmation() {
        isCancelConfirmationPresented = false
    }

    func dismissActionError() {
        actionErrorMessage = nil
    }

    func cancelPendingAction() {
        actionIdentifier = nil
        actionTask?.cancel()
        actionTask = nil
        isPerformingAction = false
    }

    private func perform(
        _ action: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        guard actionTask == nil else { return }
        isPerformingAction = true
        actionErrorMessage = nil
        let actionIdentifier = UUID()
        self.actionIdentifier = actionIdentifier

        actionTask = Task { @MainActor [weak self] in
            do {
                try await action()
            } catch is CancellationError {
                // App shutdown and model replacement are not user-facing errors.
            } catch {
                let details = UserFacingErrorPresentation.details(for: error)
                ClipLog.capture.error(
                    "Recording control action failed: \(details.technicalDescription, privacy: .private)"
                )
                self?.actionErrorMessage = details.message
            }

            guard self?.actionIdentifier == actionIdentifier else { return }
            self?.isPerformingAction = false
            self?.actionTask = nil
            self?.actionIdentifier = nil
        }
    }

    static func demo(
        _ snapshot: RecordingPresentationSnapshot = .demoRecording
    ) -> RecordingPresentationModel {
        RecordingPresentationModel(
            snapshot: snapshot,
            actions: .noOp,
            clock: .fixed(1_000)
        )
    }
}
