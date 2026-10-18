import AppKit
import Carbon.HIToolbox
import Testing
@testable import PomoMacKit

@MainActor
final class FakeRegistrar: HotKeyRegistering {
    var registered: [ShortcutAction: KeyCombo] = [:]
    var rejects: Set<KeyCombo> = []
    var calls = 0

    func register(_ action: ShortcutAction, combo: KeyCombo) throws {
        calls += 1
        registered[action] = nil  // like Carbon wrapper: re-registering drops the old key first
        if rejects.contains(combo) { throw HotKeyError.inUse }
        registered[action] = combo
    }
    func unregister(_ action: ShortcutAction) { registered[action] = nil }
}

private func freshDefaults() -> UserDefaults {
    let name = "pomo-shortcuts-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func combo(_ key: Int, _ mods: Int = Int(cmdKey | optionKey)) -> KeyCombo {
    KeyCombo(keyCode: UInt32(key), modifiers: UInt32(mods))
}

@Suite struct KeyComboTests {
    @Test func defaultsAreCtrlOptCmdPAndS() {
        #expect(ShortcutAction.toggle.defaultCombo.display == "⌃⌥⌘P")
        #expect(ShortcutAction.skip.defaultCombo.display == "⌃⌥⌘S")
    }

    @Test func serializationRoundTripsAndRejectsGarbage() {
        let c = combo(kVK_ANSI_K, cmdKey | shiftKey)
        #expect(KeyCombo(serialized: c.serialized) == c)
        #expect(KeyCombo(serialized: "") == nil)
        #expect(KeyCombo(serialized: "35") == nil)
        #expect(KeyCombo(serialized: "x:1") == nil)
        #expect(KeyCombo(serialized: "35:0") == nil)  // no modifier
        #expect(KeyCombo(serialized: "9999:256") == nil)  // unknown key
    }

    @Test func modifiersNeedControlOptionOrCommand() {
        #expect(!combo(kVK_ANSI_A, shiftKey).isValidGlobal)
        #expect(!combo(kVK_ANSI_A, 0).isValidGlobal)
        #expect(combo(kVK_ANSI_A, controlKey).isValidGlobal)
        #expect(combo(kVK_F5, optionKey | shiftKey).isValidGlobal)
    }

    @Test func carbonModifiersMapping() {
        let m = KeyCombo.carbonModifiers([.command, .shift, .capsLock, .function])
        #expect(m == UInt32(cmdKey | shiftKey))
        #expect(KeyCombo.carbonModifiers([.control, .option, .command]) == KeyCombo.ctrlOptCmd)
    }

    @Test func displayOrderIsControlOptionShiftCommand() {
        #expect(combo(kVK_Space, cmdKey | shiftKey | controlKey | optionKey).display == "⌃⌥⇧⌘Space")
    }
}

@MainActor @Suite struct ShortcutsModelTests {
    @Test func registersDefaultsAtStartup() {
        let r = FakeRegistrar()
        let m = ShortcutsModel(store: ShortcutStore(defaults: freshDefaults()), registrar: r)
        #expect(r.registered[.toggle] == ShortcutAction.toggle.defaultCombo)
        #expect(r.registered[.skip] == ShortcutAction.skip.defaultCombo)
        #expect(m.errors.isEmpty)
    }

    @Test func changeIsPersistedAndRestoredNextLaunch() {
        let d = freshDefaults()
        let r = FakeRegistrar()
        let m = ShortcutsModel(store: ShortcutStore(defaults: d), registrar: r)
        let c = combo(kVK_ANSI_J)
        m.set(c, for: .toggle)
        #expect(r.registered[.toggle] == c && m.combos[.toggle] == c)
        let r2 = FakeRegistrar()
        _ = ShortcutsModel(store: ShortcutStore(defaults: d), registrar: r2)
        #expect(r2.registered[.toggle] == c)
    }

    @Test func clearingPersistsAsNoShortcut() {
        let d = freshDefaults()
        let m = ShortcutsModel(store: ShortcutStore(defaults: d), registrar: FakeRegistrar())
        m.set(nil, for: .skip)
        let r2 = FakeRegistrar()
        let m2 = ShortcutsModel(store: ShortcutStore(defaults: d), registrar: r2)
        #expect(r2.registered[.skip] == nil && m2.combos[.skip] == nil && r2.registered[.toggle] != nil)
    }

    @Test func registrationFailureKeepsPreviousBindingAndShowsError() {
        let r = FakeRegistrar()
        let m = ShortcutsModel(store: ShortcutStore(defaults: freshDefaults()), registrar: r)
        let taken = combo(kVK_Space, cmdKey)
        r.rejects = [taken]
        m.set(taken, for: .toggle)
        #expect(m.errors[.toggle]?.contains("Already used") == true)
        #expect(m.combos[.toggle] == ShortcutAction.toggle.defaultCombo)
        #expect(r.registered[.toggle] == ShortcutAction.toggle.defaultCombo)
        m.set(combo(kVK_ANSI_J), for: .toggle)
        #expect(m.errors[.toggle] == nil)
    }

    @Test func failedStartupRegistrationIsReportedNotPersistedAway() {
        let r = FakeRegistrar()
        r.rejects = [ShortcutAction.skip.defaultCombo]
        let d = freshDefaults()
        let m = ShortcutsModel(store: ShortcutStore(defaults: d), registrar: r)
        #expect(m.errors[.skip] != nil && m.errors[.toggle] == nil)
        #expect(ShortcutStore(defaults: d).combo(for: .skip) == ShortcutAction.skip.defaultCombo)
    }

    @Test func twoActionsCannotShareACombo() {
        let r = FakeRegistrar()
        let m = ShortcutsModel(store: ShortcutStore(defaults: freshDefaults()), registrar: r)
        let before = r.calls
        m.set(ShortcutAction.toggle.defaultCombo, for: .skip)
        #expect(m.errors[.skip]?.contains("Start / pause") == true)
        #expect(m.combos[.skip] == ShortcutAction.skip.defaultCombo && r.calls == before)
    }

    @Test func invalidComboIsRejectedWithoutRegistering() {
        let r = FakeRegistrar()
        let m = ShortcutsModel(store: ShortcutStore(defaults: freshDefaults()), registrar: r)
        let before = r.calls
        m.set(combo(kVK_ANSI_A, shiftKey), for: .toggle)
        #expect(m.errors[.toggle] != nil && r.calls == before)
    }

    @Test func resetRestoresDefault() {
        let r = FakeRegistrar()
        let m = ShortcutsModel(store: ShortcutStore(defaults: freshDefaults()), registrar: r)
        m.set(combo(kVK_ANSI_J), for: .toggle)
        m.reset(.toggle)
        #expect(m.combos[.toggle] == ShortcutAction.toggle.defaultCombo && r.registered[.toggle] == ShortcutAction.toggle.defaultCombo)
    }
}
