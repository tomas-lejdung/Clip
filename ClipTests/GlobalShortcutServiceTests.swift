import Carbon.HIToolbox
import ClipCore
import XCTest
@testable import Clip

@MainActor
final class GlobalShortcutServiceTests: XCTestCase {
    func testDefaultsRegisterEveryActionAndDispatchByAction() throws {
        let registrar = ShortcutRegistrarSpy()
        let service = GlobalShortcutService(registrar: registrar)
        var received: [GlobalShortcutAction] = []

        try service.registerShortcuts(.defaults) { action in
            received.append(action)
        }

        XCTAssertEqual(registrar.replaceCallCount, 1)
        XCTAssertEqual(registrar.registrations.map(\.action), GlobalShortcutAction.allCases)
        XCTAssertEqual(registrar.registrations.map(\.identifier), [1, 2, 3])
        XCTAssertEqual(
            registrar.registrations.first(where: { $0.action == .capture })?.keyCode,
            UInt32(kVK_ANSI_R)
        )
        XCTAssertTrue(
            registrar.registrations.allSatisfy {
                $0.modifiers == UInt32(cmdKey | optionKey)
            }
        )

        registrar.fire(.pauseOrResume)
        XCTAssertEqual(received, [.pauseOrResume])
        XCTAssertNil(service.registrationError)
    }

    func testDuplicateUpdateIsRejectedWithoutReplacingWorkingRegistrations() throws {
        let registrar = ShortcutRegistrarSpy()
        let service = GlobalShortcutService(registrar: registrar)
        try service.registerShortcuts(.defaults) { _ in }

        var conflicting = ShortcutConfiguration.defaults
        conflicting.finish = conflicting.capture

        XCTAssertThrowsError(
            try service.registerShortcuts(conflicting) { _ in }
        ) { error in
            guard case let GlobalShortcutServiceError.duplicateAssignments(actions) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(Set(actions), [.capture, .finish])
        }

        XCTAssertEqual(registrar.replaceCallCount, 1)
        XCTAssertEqual(
            registrar.registrations.map(\.shortcut),
            GlobalShortcutAction.allCases.map { ShortcutConfiguration.defaults[$0] }
        )
        XCTAssertNotNil(service.registrationError)
    }

    func testUnsupportedKeyHasActionableValidationError() throws {
        let registrar = ShortcutRegistrarSpy()
        let service = GlobalShortcutService(registrar: registrar)
        var configuration = ShortcutConfiguration.defaults
        configuration.capture = try ClipCore.KeyboardShortcut(
            key: "é",
            modifiers: [.command, .option]
        )

        XCTAssertThrowsError(
            try service.registerShortcuts(configuration) { _ in }
        ) { error in
            XCTAssertEqual(error as? GlobalShortcutServiceError, .unsupportedKey("é"))
        }
        XCTAssertEqual(registrar.replaceCallCount, 0)
        XCTAssertTrue(service.registrationError?.contains("cannot be used") == true)
    }

    func testSystemRegistrationFailurePublishesActionableMessageWithoutRawStatus() throws {
        let registrar = ShortcutRegistrarSpy()
        let service = GlobalShortcutService(registrar: registrar)
        let shortcut = ShortcutConfiguration.defaults.finish
        registrar.nextError = GlobalShortcutServiceError.registrationFailed(
            action: .finish,
            shortcut: shortcut,
            status: -9878
        )

        XCTAssertThrowsError(
            try service.registerShortcuts(.defaults) { _ in }
        )
        let message = try XCTUnwrap(service.registrationError)
        XCTAssertTrue(message.contains("another app"))
        XCTAssertTrue(message.contains("Choose another shortcut"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("error"))
    }

    func testHandlerInstallationFailurePublishesRecoveryWithoutRawStatus() throws {
        let registrar = ShortcutRegistrarSpy()
        let service = GlobalShortcutService(registrar: registrar)
        registrar.nextError = GlobalShortcutServiceError.eventHandlerInstallationFailed(-9879)

        XCTAssertThrowsError(
            try service.registerShortcuts(.defaults) { _ in }
        )
        let message = try XCTUnwrap(service.registrationError)
        XCTAssertTrue(message.contains("Restart Clip"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("error"))
        XCTAssertFalse(message.contains("9879"))
    }

    func testSameConfigurationUpdatesHandlerWithoutReregistering() throws {
        let registrar = ShortcutRegistrarSpy()
        let service = GlobalShortcutService(registrar: registrar)
        var firstHandlerCount = 0
        var secondHandlerCount = 0

        try service.registerShortcuts(.defaults) { _ in
            firstHandlerCount += 1
        }
        try service.registerShortcuts(.defaults) { _ in
            secondHandlerCount += 1
        }
        registrar.fire(.capture)

        XCTAssertEqual(registrar.replaceCallCount, 1)
        XCTAssertEqual(firstHandlerCount, 0)
        XCTAssertEqual(secondHandlerCount, 1)
    }

    func testUnregisterClearsRegistrarAndPublishedError() throws {
        let registrar = ShortcutRegistrarSpy()
        let service = GlobalShortcutService(registrar: registrar)
        try service.registerShortcuts(.defaults) { _ in }

        service.unregisterShortcuts()

        XCTAssertEqual(registrar.unregisterCallCount, 1)
        XCTAssertTrue(registrar.registrations.isEmpty)
        XCTAssertNil(service.registrationError)
    }
}

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
    func testQuitClosesOwnedUIImmediatelyAndRepliesExactlyOnce() async {
        let handler = TerminationHandlerSpy()
        let replies = TerminationReplySpy()
        let replyExpectation = expectation(description: "termination reply")
        replies.onReply = { replyExpectation.fulfill() }
        let coordinator = ApplicationTerminationCoordinator(timeout: .seconds(60))

        let first = coordinator.requestTermination(
            handler: handler,
            reply: { replies.recordReply() }
        )
        let duplicate = coordinator.requestTermination(
            handler: handler,
            reply: { replies.recordReply() }
        )

        XCTAssertEqual(first, .terminateLater)
        XCTAssertEqual(duplicate, .terminateLater)
        XCTAssertEqual(handler.closeCount, 1)
        XCTAssertFalse(handler.isPopoverOpen)
        XCTAssertEqual(handler.openWindowCount, 0)
        XCTAssertFalse(handler.hasStatusItem)

        await fulfillment(of: [replyExpectation], timeout: 1)
        XCTAssertEqual(handler.prepareCount, 1)
        XCTAssertEqual(handler.closeCount, 2)
        XCTAssertEqual(replies.count, 1)

        let afterReply = coordinator.requestTermination(
            handler: handler,
            reply: { replies.recordReply() }
        )
        XCTAssertEqual(afterReply, .terminateNow)
        XCTAssertEqual(replies.count, 1)
    }

    func testQuitTimeoutRepliesWhileCleanupIsUnresponsive() async {
        let cleanupGate = TerminationGate()
        let timeoutGate = TerminationGate()
        let handler = TerminationHandlerSpy {
            await cleanupGate.wait()
        }
        let replies = TerminationReplySpy()
        let replyExpectation = expectation(description: "timeout termination reply")
        replies.onReply = { replyExpectation.fulfill() }
        let coordinator = ApplicationTerminationCoordinator(
            timeout: .seconds(8),
            sleep: { _ in await timeoutGate.wait() }
        )

        XCTAssertEqual(
            coordinator.requestTermination(
                handler: handler,
                reply: { replies.recordReply() }
            ),
            .terminateLater
        )
        XCTAssertEqual(
            coordinator.requestTermination(
                handler: handler,
                reply: { replies.recordReply() }
            ),
            .terminateLater
        )
        await cleanupGate.waitForPendingWaiter()
        await timeoutGate.waitForPendingWaiter()
        await timeoutGate.resumeNext()

        await fulfillment(of: [replyExpectation], timeout: 1)
        XCTAssertEqual(handler.closeCount, 2)
        XCTAssertFalse(handler.isPopoverOpen)
        XCTAssertEqual(handler.openWindowCount, 0)
        XCTAssertFalse(handler.hasStatusItem)
        XCTAssertEqual(replies.count, 1)

        // Let the deliberately non-cooperative cleanup return after the reply;
        // it must not produce a second AppKit termination reply.
        await cleanupGate.resumeNext()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(replies.count, 1)
    }

    func testVisiblePreviewDoesNotBlockNewCaptureSelection() {
        XCTAssertTrue(
            CaptureSelectionPresentationPolicy.permitsSelection(
                recordingPhase: .idle,
                hasVisiblePreview: true
            )
        )
        XCTAssertTrue(
            CaptureSelectionPresentationPolicy.permitsSelection(
                recordingPhase: .preview,
                hasVisiblePreview: true
            )
        )
        for phase in [
            RecordingPhase.selecting,
            .countdown,
            .recording,
            .paused,
            .finishing,
        ] {
            XCTAssertFalse(
                CaptureSelectionPresentationPolicy.permitsSelection(
                    recordingPhase: phase,
                    hasVisiblePreview: true
                )
            )
        }
    }

    func testQuitLetsCaptureServiceDecideWhetherAnInFlightFirstFrameIsPlayable() {
        XCTAssertEqual(
            RecordingTerminationPolicy.plan(
                recordingPhase: .recording,
                hasObservedVideoFrame: false
            ),
            .finalize(markFrameForServiceAuthoritativeAttempt: true)
        )
        XCTAssertEqual(
            RecordingTerminationPolicy.plan(
                recordingPhase: .recording,
                hasObservedVideoFrame: true
            ),
            .finalize(markFrameForServiceAuthoritativeAttempt: false)
        )
        XCTAssertEqual(
            RecordingTerminationPolicy.plan(
                recordingPhase: .paused,
                hasObservedVideoFrame: true
            ),
            .finalize(markFrameForServiceAuthoritativeAttempt: false)
        )
        for phase in [RecordingPhase.selecting, .countdown] {
            XCTAssertEqual(
                RecordingTerminationPolicy.plan(
                    recordingPhase: phase,
                    hasObservedVideoFrame: false
                ),
                .cancelSelectionOrCountdown
            )
        }
        for phase in [RecordingPhase.idle, .finishing, .preview, .canceled, .failed] {
            XCTAssertEqual(
                RecordingTerminationPolicy.plan(
                    recordingPhase: phase,
                    hasObservedVideoFrame: false
                ),
                .noAction
            )
        }
    }

    func testPreviewPresentationFailureCannotReclassifyAnImportedRecordingAsFailed() {
        XCTAssertEqual(
            RecordingCompletionPolicy.failureDisposition(
                recordingWasImported: false
            ),
            .recordingFailed
        )
        XCTAssertEqual(
            RecordingCompletionPolicy.failureDisposition(
                recordingWasImported: true
            ),
            .recordingSavedPreviewDeferred
        )
    }
}

@MainActor
private final class ShortcutRegistrarSpy: GlobalHotKeyRegistering {
    var replaceCallCount = 0
    var unregisterCallCount = 0
    var registrations: [GlobalHotKeyRegistration] = []
    var nextError: (any Error)?

    private var handler: (@MainActor (GlobalShortcutAction) -> Void)?

    func replace(
        registrations: [GlobalHotKeyRegistration],
        handler: @escaping @MainActor (GlobalShortcutAction) -> Void
    ) throws {
        replaceCallCount += 1
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        self.registrations = registrations
        self.handler = handler
    }

    func unregisterAll() {
        unregisterCallCount += 1
        registrations = []
        handler = nil
    }

    func fire(_ action: GlobalShortcutAction) {
        handler?(action)
    }
}

@MainActor
private final class TerminationHandlerSpy: ApplicationTerminationHandling {
    private let prepareOperation: @MainActor () async -> Void

    private(set) var closeCount = 0
    private(set) var prepareCount = 0
    private(set) var isPopoverOpen = true
    private(set) var openWindowCount = 4
    private(set) var hasStatusItem = true

    init(prepareOperation: @escaping @MainActor () async -> Void = {}) {
        self.prepareOperation = prepareOperation
    }

    func closeForTermination() {
        closeCount += 1
        isPopoverOpen = false
        openWindowCount = 0
        hasStatusItem = false
    }

    func prepareForTermination() async {
        prepareCount += 1
        await prepareOperation()
    }
}

@MainActor
private final class TerminationReplySpy {
    private(set) var count = 0
    var onReply: @MainActor () -> Void = {}

    func recordReply() {
        count += 1
        onReply()
    }
}

private actor TerminationGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForPendingWaiter() async {
        while continuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeNext() {
        continuations.removeFirst().resume()
    }
}
