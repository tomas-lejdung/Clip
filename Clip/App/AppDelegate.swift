import AppKit
import OSLog

enum HostedUnitTestDetection {
    /// App-hosted XCTest bundles launch the real Clip executable before injecting
    /// the test bundle. Suppress the production coordinator in that process so a
    /// permission-free unit-test run cannot create status items, show onboarding,
    /// register system integrations, or open the user's persisted state.
    static func shouldSuppressNormalAppStartup(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard !arguments.contains(AppLaunchConfiguration.uiTestingArgument) else {
            return false
        }

        let hostedTestEnvironmentKeys = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCInjectBundleInto",
        ]
        return hostedTestEnvironmentKeys.contains { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

enum ApplicationTerminationReply: Equatable, Sendable {
    case terminateNow
    case terminateLater
}

@MainActor
protocol ApplicationTerminationHandling: AnyObject {
    /// Hides and releases app-owned UI synchronously. This operation must be
    /// idempotent because it runs both when Quit begins and immediately before
    /// AppKit receives the final termination reply.
    func closeForTermination()

    /// Performs best-effort recording finalization and persistence after the UI
    /// has already disappeared.
    func prepareForTermination() async
}

/// Owns AppKit's `terminateLater` reply contract. Cleanup gets a short grace
/// period, but an uncooperative media or filesystem operation can never leave a
/// visible, unresponsive Clip process behind indefinitely.
@MainActor
final class ApplicationTerminationCoordinator {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let defaultTimeout: Duration = .seconds(8)

    private enum Phase: Equatable {
        case idle
        case preparing
        case replied
    }

    private enum Completion: Equatable, Sendable {
        case cleanupFinished
        case timedOut
    }

    private let timeout: Duration
    private let sleep: Sleep
    private var phase = Phase.idle
    private var task: Task<Void, Never>?

    init(
        timeout: Duration = ApplicationTerminationCoordinator.defaultTimeout,
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.timeout = timeout
        self.sleep = sleep
    }

    func requestTermination(
        handler: any ApplicationTerminationHandling,
        reply: @escaping @MainActor () -> Void
    ) -> ApplicationTerminationReply {
        switch phase {
        case .idle:
            phase = .preparing
            handler.closeForTermination()
            let timeout = timeout
            let sleep = sleep
            task = Task { @MainActor [weak self] in
                let completion = await Self.firstCompletion(
                    handler: handler,
                    timeout: timeout,
                    sleep: sleep
                )
                guard let self, !Task.isCancelled, self.claimReply() else { return }
                if completion == .timedOut {
                    ClipLog.lifecycle.error(
                        "Termination cleanup exceeded its grace period; relying on durable recovery state"
                    )
                }
                handler.closeForTermination()
                self.task = nil
                reply()
            }
            return .terminateLater

        case .preparing:
            return .terminateLater

        case .replied:
            handler.closeForTermination()
            return .terminateNow
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .replied
    }

    private func claimReply() -> Bool {
        guard phase == .preparing else { return false }
        phase = .replied
        return true
    }

    private static func firstCompletion(
        handler: any ApplicationTerminationHandling,
        timeout: Duration,
        sleep: @escaping Sleep
    ) async -> Completion {
        let channel = AsyncStream<Completion>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let cleanupTask = Task { @MainActor in
            await handler.prepareForTermination()
            guard !Task.isCancelled else { return }
            channel.continuation.yield(.cleanupFinished)
        }
        let timeoutTask = Task {
            do {
                try await sleep(timeout)
            } catch {
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            channel.continuation.yield(.timedOut)
        }

        var iterator = channel.stream.makeAsyncIterator()
        let completion = await iterator.next() ?? .timedOut
        channel.continuation.finish()
        cleanupTask.cancel()
        timeoutTask.cancel()
        return completion
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchConfiguration = AppLaunchConfiguration.current()
    private let unattendedCaptureSmokeLaunch = UnattendedCaptureSmokeLaunch.resolve(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )
    private var coordinator: ApplicationCoordinator?
    private var deterministicUIScenarioCoordinator: DeterministicUIScenarioCoordinator?
    private var unattendedCaptureSmokeCoordinator: UnattendedCaptureSmokeCoordinator?
    private let terminationCoordinator = ApplicationTerminationCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !HostedUnitTestDetection.shouldSuppressNormalAppStartup() else {
            ClipLog.lifecycle.info("Production application startup suppressed for hosted unit tests")
            return
        }

        switch unattendedCaptureSmokeLaunch {
        case .none:
            break
        case .invalid:
            finishUnattendedCaptureSmoke(UnattendedCaptureSmokeReport(
                protocolVersion: 3,
                status: "failed",
                scope: "none; launch guard rejected the request",
                requestedDurationSeconds: 0,
                requestedFramesPerSecond: 0,
                pauseDurationSeconds: 0,
                screenPermissionWasPreauthorized: false,
                previewFrameWasGenerated: false,
                copyWasByteIdentical: false,
                copyPasteboardResolvedFileURL: false,
                copiedFileWasDecodedAndEvaluated: false,
                outputWasDeleted: true,
                preservedOutputPath: nil,
                metrics: nil,
                failure: "The unattended capture smoke flags or environment guard were invalid."
            ))
            return
        case let .run(request):
            let coordinator = UnattendedCaptureSmokeCoordinator(
                request: request,
                completion: { [weak self] report in
                    self?.finishUnattendedCaptureSmoke(report)
                }
            )
            unattendedCaptureSmokeCoordinator = coordinator
            coordinator.start()
            return
        }

        NSApp.setActivationPolicy(.accessory)

        do {
            if launchConfiguration.launchesDeterministicUIScenario {
                let coordinator = try DeterministicUIScenarioCoordinator(
                    launchConfiguration: launchConfiguration
                )
                deterministicUIScenarioCoordinator = coordinator
                coordinator.start()
                ClipLog.lifecycle.info("Deterministic UI scenario started")
                return
            }

            let dependencies = try AppDependencies.live(
                launchConfiguration: launchConfiguration
            )
            let coordinator = ApplicationCoordinator(dependencies: dependencies)
            self.coordinator = coordinator
            coordinator.start()
            ClipLog.lifecycle.info("Clip application started")
        } catch {
            presentStartupFailure(error)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let unattendedCaptureSmokeCoordinator {
            unattendedCaptureSmokeCoordinator.stop()
            self.unattendedCaptureSmokeCoordinator = nil
            return .terminateNow
        }
        if let deterministicUIScenarioCoordinator {
            deterministicUIScenarioCoordinator.stop()
            self.deterministicUIScenarioCoordinator = nil
            return .terminateNow
        }
        guard let coordinator else { return .terminateNow }
        let reply = terminationCoordinator.requestTermination(
            handler: coordinator,
            reply: {
                sender.reply(toApplicationShouldTerminate: true)
            }
        )
        switch reply {
        case .terminateNow:
            return .terminateNow
        case .terminateLater:
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationCoordinator.cancel()
        unattendedCaptureSmokeCoordinator?.stop()
        unattendedCaptureSmokeCoordinator = nil
        deterministicUIScenarioCoordinator?.stop()
        deterministicUIScenarioCoordinator = nil
        coordinator?.closeForTermination()
        ClipLog.lifecycle.info("Clip application stopped")
    }

    private func finishUnattendedCaptureSmoke(_ report: UnattendedCaptureSmokeReport) {
        do {
            FileHandle.standardOutput.write(try report.encoded())
            try? FileHandle.standardOutput.synchronize()
        } catch {
            let message = "Clip controlled-capture smoke could not encode its report: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        unattendedCaptureSmokeCoordinator = nil
        NSApp.terminate(nil)
    }

    private func presentStartupFailure(_ error: any Error) {
        let details = UserFacingErrorPresentation.details(for: error)
        ClipLog.lifecycle.error(
            "Application startup failed: \(details.technicalDescription, privacy: .private)"
        )
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Clip could not start")
        alert.informativeText = details.message
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.runModal()
        NSApp.terminate(nil)
    }
}
