import AppKit
import PomoUI
import SwiftUI

/// Click, press a combination, done. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    var action: ShortcutAction
    var model: ShortcutsModel
    @State private var recording = false
    @State private var monitor: Any?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .trailing, spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.s) {
                Button(action: toggle) {
                    Text(label)
                        .frame(minWidth: 96)
                        .foregroundStyle(recording ? theme.focus : theme.text)
                }
                .accessibilityLabel("\(action.title) shortcut")
                .accessibilityValue(model.combos[action]?.display ?? "none")
                .accessibilityHint(recording ? "Press the new key combination" : "Activate to record a new shortcut")
                if model.combos[action] != action.defaultCombo {
                    Button { model.reset(action) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).help("Restore \(action.defaultCombo.display)")
                        .accessibilityLabel("Restore default shortcut")
                }
            }
            if let e = model.errors[action] {
                Text(e).font(.caption).foregroundStyle(theme.danger).multilineTextAlignment(.trailing)
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return "Press shortcut…" }
        return model.combos[action]?.display ?? "None"
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53:  // esc
                stop()
            case 51, 117:  // delete, forward delete
                model.set(nil, for: action)
                stop()
            default:
                let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: KeyCombo.carbonModifiers(event.modifierFlags))
                model.set(combo, for: action)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
