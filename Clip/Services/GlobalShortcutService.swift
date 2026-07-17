import Carbon.HIToolbox
import ClipCore
import Combine
import Foundation

struct GlobalHotKeyRegistration: Equatable {
    let action: GlobalShortcutAction
    let identifier: UInt32
    let keyCode: UInt32
    let modifiers: UInt32
    let shortcut: KeyboardShortcut
}

enum GlobalShortcutServiceError: Error, Equatable, LocalizedError {
    case duplicateAssignments([GlobalShortcutAction])
    case unsupportedKey(String)
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(
        action: GlobalShortcutAction,
        shortcut: KeyboardShortcut,
        status: OSStatus
    )

    var errorDescription: String? {
        switch self {
        case let .duplicateAssignments(actions):
            let names = actions.map(\.displayName).joined(separator: ", ")
            return String(
                localized: "The same global shortcut is assigned to \(names). Choose a different shortcut for each action."
            )
        case let .unsupportedKey(key):
            return String(
                localized: "The key “\(key)” cannot be used as a global shortcut. Use a letter, number, Space, or a standard punctuation key."
            )
        case .eventHandlerInstallationFailed:
            return String(
                localized: "Clip could not start its global shortcut handler. Restart Clip and try again."
            )
        case let .registrationFailed(action, shortcut, _):
            return String(
                localized: "\(action.displayName) could not use \(shortcut.displayName). That shortcut may already be used by macOS or another app. Choose another shortcut in Clip Settings."
            )
        }
    }
}

@MainActor
protocol GlobalHotKeyRegistering: AnyObject {
    func replace(
        registrations: [GlobalHotKeyRegistration],
        handler: @escaping @MainActor (GlobalShortcutAction) -> Void
    ) throws
    func unregisterAll()
}

@MainActor
final class GlobalShortcutService: ObservableObject, ShortcutServicing {
    @Published private(set) var registrationError: String?

    private let registrar: any GlobalHotKeyRegistering
    private var registeredConfiguration: ShortcutConfiguration?
    private var actionHandler: (@MainActor (GlobalShortcutAction) -> Void)?

    init(registrar: any GlobalHotKeyRegistering = CarbonGlobalHotKeyRegistrar()) {
        self.registrar = registrar
    }

    func registerShortcuts(
        _ configuration: ShortcutConfiguration,
        handler: @escaping @MainActor (GlobalShortcutAction) -> Void
    ) throws {
        actionHandler = handler

        if configuration == registeredConfiguration {
            registrationError = nil
            return
        }

        do {
            let registrations = try Self.registrations(for: configuration)
            try registrar.replace(
                registrations: registrations,
                handler: { [weak self] action in
                    self?.actionHandler?(action)
                }
            )
            registeredConfiguration = configuration
            registrationError = nil
        } catch {
            registrationError = error.localizedDescription
            throw error
        }
    }

    func unregisterShortcuts() {
        registrar.unregisterAll()
        registeredConfiguration = nil
        actionHandler = nil
        registrationError = nil
    }

    private static func registrations(
        for configuration: ShortcutConfiguration
    ) throws -> [GlobalHotKeyRegistration] {
        if let conflict = configuration.conflicts.first {
            throw GlobalShortcutServiceError.duplicateAssignments(
                conflict.actions.sorted { $0.rawValue < $1.rawValue }
            )
        }

        return try GlobalShortcutAction.allCases.enumerated().map { index, action in
            let shortcut = configuration[action]
            return GlobalHotKeyRegistration(
                action: action,
                identifier: UInt32(index + 1),
                keyCode: try ShortcutKeyCodeResolver.keyCode(for: shortcut.key),
                modifiers: Self.carbonModifiers(for: shortcut.modifiers),
                shortcut: shortcut
            )
        }
    }

    private static func carbonModifiers(for modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}

enum ShortcutKeyCodeResolver {
    private static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A),
        "b": UInt32(kVK_ANSI_B),
        "c": UInt32(kVK_ANSI_C),
        "d": UInt32(kVK_ANSI_D),
        "e": UInt32(kVK_ANSI_E),
        "f": UInt32(kVK_ANSI_F),
        "g": UInt32(kVK_ANSI_G),
        "h": UInt32(kVK_ANSI_H),
        "i": UInt32(kVK_ANSI_I),
        "j": UInt32(kVK_ANSI_J),
        "k": UInt32(kVK_ANSI_K),
        "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M),
        "n": UInt32(kVK_ANSI_N),
        "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P),
        "q": UInt32(kVK_ANSI_Q),
        "r": UInt32(kVK_ANSI_R),
        "s": UInt32(kVK_ANSI_S),
        "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U),
        "v": UInt32(kVK_ANSI_V),
        "w": UInt32(kVK_ANSI_W),
        "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y),
        "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0),
        "1": UInt32(kVK_ANSI_1),
        "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4),
        "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6),
        "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9),
        " ": UInt32(kVK_Space),
        "-": UInt32(kVK_ANSI_Minus),
        "=": UInt32(kVK_ANSI_Equal),
        "[": UInt32(kVK_ANSI_LeftBracket),
        "]": UInt32(kVK_ANSI_RightBracket),
        "\\": UInt32(kVK_ANSI_Backslash),
        ";": UInt32(kVK_ANSI_Semicolon),
        "'": UInt32(kVK_ANSI_Quote),
        ",": UInt32(kVK_ANSI_Comma),
        ".": UInt32(kVK_ANSI_Period),
        "/": UInt32(kVK_ANSI_Slash),
        "`": UInt32(kVK_ANSI_Grave),
    ]

    static func keyCode(for key: String) throws -> UInt32 {
        guard let keyCode = keyCodes[key.lowercased()] else {
            throw GlobalShortcutServiceError.unsupportedKey(key)
        }
        return keyCode
    }

    static func isSupported(_ key: String) -> Bool {
        keyCodes[key.lowercased()] != nil
    }
}

@MainActor
private final class CarbonGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    private static let signature: OSType = 0x434C4950 // "CLIP"

    private var eventHandlerReference: EventHandlerRef?
    private var hotKeyReferences: [EventHotKeyRef] = []
    private var registrations: [GlobalHotKeyRegistration] = []
    private var handler: (@MainActor (GlobalShortcutAction) -> Void)?

    func replace(
        registrations newRegistrations: [GlobalHotKeyRegistration],
        handler newHandler: @escaping @MainActor (GlobalShortcutAction) -> Void
    ) throws {
        try installEventHandlerIfNeeded()

        let previousRegistrations = registrations
        let previousHandler = handler
        unregisterHotKeys()
        handler = newHandler

        do {
            try register(newRegistrations)
            registrations = newRegistrations
        } catch {
            unregisterHotKeys()
            handler = previousHandler
            registrations = []
            if !previousRegistrations.isEmpty {
                do {
                    try register(previousRegistrations)
                    registrations = previousRegistrations
                } catch {
                    // The original failure is more useful to the user. A later settings
                    // change will attempt a complete registration again.
                    unregisterHotKeys()
                }
            }
            throw error
        }
    }

    func unregisterAll() {
        unregisterHotKeys()
        registrations = []
        handler = nil
    }

    fileprivate func receive(identifier: UInt32) {
        guard let action = registrations.first(where: { $0.identifier == identifier })?.action else {
            return
        }
        handler?(action)
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandlerReference == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonGlobalHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerReference
        )
        guard status == noErr else {
            throw GlobalShortcutServiceError.eventHandlerInstallationFailed(status)
        }
    }

    private func register(_ registrations: [GlobalHotKeyRegistration]) throws {
        for registration in registrations {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(
                signature: Self.signature,
                id: registration.identifier
            )
            let status = RegisterEventHotKey(
                registration.keyCode,
                registration.modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            guard status == noErr, let reference else {
                throw GlobalShortcutServiceError.registrationFailed(
                    action: registration.action,
                    shortcut: registration.shortcut,
                    status: status
                )
            }
            hotKeyReferences.append(reference)
        }
    }

    private func unregisterHotKeys() {
        for reference in hotKeyReferences {
            UnregisterEventHotKey(reference)
        }
        hotKeyReferences.removeAll()
    }
}

private func carbonGlobalHotKeyHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID(signature: 0, id: 0)
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }

    let registrar = Unmanaged<CarbonGlobalHotKeyRegistrar>
        .fromOpaque(userData)
        .takeUnretainedValue()
    MainActor.assumeIsolated {
        registrar.receive(identifier: identifier.id)
    }
    return noErr
}

private extension GlobalShortcutAction {
    var displayName: String {
        switch self {
        case .capture: String(localized: "Capture")
        case .finish: String(localized: "Finish")
        case .pauseOrResume: String(localized: "Pause or Resume")
        }
    }
}

private extension KeyboardShortcut {
    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + (key == " " ? String(localized: "Space") : key.uppercased())
    }
}
