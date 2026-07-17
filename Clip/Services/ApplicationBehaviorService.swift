import AppKit
import ClipCore
import ServiceManagement

enum LaunchAtLoginRegistrationStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
}

enum ApplicationBehaviorError: LocalizedError, Equatable, Sendable {
    case activationPolicyRejected(showInDock: Bool)

    var errorDescription: String? {
        switch self {
        case let .activationPolicyRejected(showInDock):
            showInDock
                ? String(localized: "Clip could not show its Dock icon. Try again.")
                : String(localized: "Clip could not hide its Dock icon. Try again.")
        }
    }
}

@MainActor
final class ApplicationBehaviorService {
    typealias ActivationPolicySetter = @MainActor (NSApplication.ActivationPolicy) -> Bool
    typealias LaunchStatusProvider = @MainActor () -> LaunchAtLoginRegistrationStatus
    typealias LaunchRegistrationAction = @MainActor () throws -> Void

    private let setActivationPolicy: ActivationPolicySetter
    private let launchAtLoginStatus: LaunchStatusProvider
    private let registerLaunchAtLogin: LaunchRegistrationAction
    private let unregisterLaunchAtLogin: LaunchRegistrationAction
    private var lastAppliedLaunchAtLogin: Bool?
    private var lastAppliedShowInDock: Bool?

    init(
        setActivationPolicy: @escaping ActivationPolicySetter = { policy in
            // AppDelegate establishes `.accessory` before the settings model
            // publishes its initial value. AppKit can return `false` when
            // asked to reapply the already-active policy; that is a successful
            // no-op, not a settings failure.
            NSApp.activationPolicy() == policy || NSApp.setActivationPolicy(policy)
        },
        launchAtLoginStatus: @escaping LaunchStatusProvider = {
            switch SMAppService.mainApp.status {
            case .enabled:
                .enabled
            case .requiresApproval:
                .requiresApproval
            default:
                .disabled
            }
        },
        registerLaunchAtLogin: @escaping LaunchRegistrationAction = {
            try SMAppService.mainApp.register()
        },
        unregisterLaunchAtLogin: @escaping LaunchRegistrationAction = {
            try SMAppService.mainApp.unregister()
        }
    ) {
        self.setActivationPolicy = setActivationPolicy
        self.launchAtLoginStatus = launchAtLoginStatus
        self.registerLaunchAtLogin = registerLaunchAtLogin
        self.unregisterLaunchAtLogin = unregisterLaunchAtLogin
    }

    func apply(_ settings: ClipSettings) throws {
        if lastAppliedShowInDock != settings.showInDock {
            guard setActivationPolicy(settings.showInDock ? .regular : .accessory) else {
                throw ApplicationBehaviorError.activationPolicyRejected(
                    showInDock: settings.showInDock
                )
            }
            lastAppliedShowInDock = settings.showInDock
        }

        if lastAppliedLaunchAtLogin != settings.launchAtLogin {
            try setLaunchAtLogin(settings.launchAtLogin)
            lastAppliedLaunchAtLogin = settings.launchAtLogin
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            guard launchAtLoginStatus() != .enabled else { return }
            try registerLaunchAtLogin()
        } else {
            guard [.enabled, .requiresApproval].contains(launchAtLoginStatus()) else { return }
            try unregisterLaunchAtLogin()
        }
    }
}
