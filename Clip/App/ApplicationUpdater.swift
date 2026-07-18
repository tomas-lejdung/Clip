import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

/// The narrow update surface used by Clip's own UI. Keeping Sparkle behind this
/// protocol prevents deterministic launch fixtures and hosted tests from
/// starting network activity or presenting updater windows.
@MainActor
protocol ApplicationUpdateServicing: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

#if canImport(Sparkle)
@MainActor
final class SparkleApplicationUpdater: ApplicationUpdateServicing {
    private let controller: SPUStandardUpdaterController

    init(startingUpdater: Bool = true) {
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
#else
/// Keeps the repository's direct `swiftc` source audit available without
/// turning that audit into a second application packaging path. Production
/// Xcode builds link Sparkle through the pinned package product.
@MainActor
final class SparkleApplicationUpdater: ApplicationUpdateServicing {
    init(startingUpdater: Bool = true) {
        _ = startingUpdater
    }

    let canCheckForUpdates = false

    func checkForUpdates() {}
}
#endif
