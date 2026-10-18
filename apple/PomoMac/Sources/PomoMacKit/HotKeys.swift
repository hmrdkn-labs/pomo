import Carbon.HIToolbox
import Foundation
import Observation

public enum HotKeyError: Error, Equatable, LocalizedError {
    /// Another app (or the system) already owns this combination.
    case inUse
    case failed(Int32)

    public var errorDescription: String? {
        switch self {
        case .inUse: "Already used by the system or another app."
        case let .failed(s): "Could not register the shortcut (error \(s))."
        }
    }
}

/// Registers one system-wide hot key per action.
@MainActor
public protocol HotKeyRegistering: AnyObject {
    func register(_ action: ShortcutAction, combo: KeyCombo) throws
    func unregister(_ action: ShortcutAction)
}

/// Carbon `RegisterEventHotKey`; needs no Accessibility permission and no sandbox exemption.
@MainActor
public final class CarbonHotKeys: HotKeyRegistering {
    private var refs: [ShortcutAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private let onPress: @MainActor (ShortcutAction) -> Void
    private static let signature: OSType = 0x504F4D4F  // 'POMO'
    private static let actions = ShortcutAction.allCases

    public init(onPress: @escaping @MainActor (ShortcutAction) -> Void) {
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let box = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == CarbonHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let this = Unmanaged<CarbonHotKeys>.fromOpaque(userData).takeUnretainedValue()
            let index = Int(id.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard index < CarbonHotKeys.actions.count else { return }
                    this.onPress(CarbonHotKeys.actions[index])
                }
            }
            return noErr
        }, 1, &spec, box, &handlerRef)
    }

    public func register(_ action: ShortcutAction, combo: KeyCombo) throws {
        unregister(action)
        let index = Self.actions.firstIndex(of: action)!
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        switch status {
        case noErr: refs[action] = ref
        case OSStatus(eventHotKeyExistsErr): throw HotKeyError.inUse
        default: throw HotKeyError.failed(status)
        }
    }

    public func unregister(_ action: ShortcutAction) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
    }
}

/// The bindings the user sees in Settings: current combo and registration problem per action.
@MainActor @Observable
public final class ShortcutsModel {
    public private(set) var combos: [ShortcutAction: KeyCombo] = [:]
    public private(set) var errors: [ShortcutAction: String] = [:]

    @ObservationIgnored private let store: ShortcutStore
    @ObservationIgnored private let registrar: HotKeyRegistering

    /// Registers every stored binding. Failures are kept per action and shown inline.
    public init(store: ShortcutStore = ShortcutStore(), registrar: HotKeyRegistering) {
        self.store = store; self.registrar = registrar
        for action in ShortcutAction.allCases {
            guard let combo = store.combo(for: action) else { continue }
            combos[action] = combo
            if let other = conflictingAction(for: combo, excluding: action) {
                errors[action] = "Same as \(other.title)."
                continue
            }
            do { try registrar.register(action, combo: combo) } catch { errors[action] = error.localizedDescription }
        }
    }

    private func conflictingAction(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && combos[$0] == combo && errors[$0] == nil }
    }

    /// Binds `combo` (or clears with `nil`). On failure the previous binding stays and the error is shown.
    public func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        guard let combo else {
            registrar.unregister(action)
            combos[action] = nil
            errors[action] = nil
            store.set(nil, for: action)
            return
        }
        guard combo.isValidGlobal else {
            errors[action] = "Use at least one of ⌃ ⌥ ⌘ with a letter, number or F-key."
            return
        }
        if let other = conflictingAction(for: combo, excluding: action) {
            errors[action] = "\(combo.display) is already used for \(other.title)."
            return
        }
        if combos[action] == combo, errors[action] == nil { return }
        let previous = combos[action]
        let previousWorked = errors[action] == nil
        do {
            try registrar.register(action, combo: combo)
            combos[action] = combo
            errors[action] = nil
            store.set(combo, for: action)
        } catch {
            errors[action] = "\(combo.display): \(error.localizedDescription)"
            // `register` unregisters first; put the old binding back.
            if let previous, previousWorked { try? registrar.register(action, combo: previous) }
        }
    }

    public func reset(_ action: ShortcutAction) {
        store.reset(action)
        set(action.defaultCombo, for: action)
    }
}
