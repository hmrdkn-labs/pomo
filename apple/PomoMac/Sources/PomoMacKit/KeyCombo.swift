import AppKit
import Carbon.HIToolbox

/// A key plus modifiers in Carbon terms (virtual key code, `cmdKey`/`optionKey`/`controlKey`/`shiftKey` mask).
public struct KeyCombo: Equatable, Hashable, Codable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    public static let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)

    public static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// A global hot key needs ctrl, option or command, otherwise it would swallow ordinary typing.
    public var isValidGlobal: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 && KeyCombo.keyNames[keyCode] != nil
    }

    /// `⌃⌥⌘P`
    public var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (KeyCombo.keyNames[keyCode] ?? "key \(keyCode)")
    }

    /// Stable text form for `UserDefaults`: `"<keyCode>:<modifiers>"`.
    public var serialized: String { "\(keyCode):\(modifiers)" }

    public init?(serialized: String) {
        let parts = serialized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let k = UInt32(parts[0]), let m = UInt32(parts[1]) else { return nil }
        let combo = KeyCombo(keyCode: k, modifiers: m)
        guard combo.isValidGlobal else { return nil }
        self = combo
    }

    /// US-layout key names for the virtual key codes a recorder accepts.
    static let keyNames: [UInt32: String] = {
        var t: [UInt32: String] = [:]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Comma, ","),
            (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"), (kVK_ANSI_Grave, "`"),
            (kVK_Space, "Space"), (kVK_Return, "↩"), (kVK_Tab, "⇥"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"),
            (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
        ]
        for (code, name) in letters { t[UInt32(code)] = name }
        return t
    }()
}

public enum ShortcutAction: String, CaseIterable, Sendable, Identifiable {
    case toggle, skip

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toggle: "Start / pause"
        case .skip: "Skip block"
        }
    }

    public var defaultCombo: KeyCombo {
        switch self {
        case .toggle: KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: KeyCombo.ctrlOptCmd)
        case .skip: KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: KeyCombo.ctrlOptCmd)
        }
    }

    var defaultsKey: String { "shortcut.\(rawValue)" }
}

/// Shortcut bindings in `UserDefaults`. A stored empty string means "no shortcut".
public struct ShortcutStore {
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func combo(for action: ShortcutAction) -> KeyCombo? {
        guard let raw = defaults.string(forKey: action.defaultsKey) else { return action.defaultCombo }
        return KeyCombo(serialized: raw)
    }

    public func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        defaults.set(combo?.serialized ?? "", forKey: action.defaultsKey)
    }

    public func reset(_ action: ShortcutAction) { defaults.removeObject(forKey: action.defaultsKey) }
}
