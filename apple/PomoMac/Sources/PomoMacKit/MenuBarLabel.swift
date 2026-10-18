import PomoUI
import SwiftUI

/// Phase glyph plus `mm:ss` in the menu bar. Idle shows only the glyph; paused dims.
public struct MenuBarLabel: View {
    var model: TimerViewModel
    @Environment(\.colorScheme) private var scheme

    public init(model: TimerViewModel) { self.model = model }

    public var body: some View {
        let theme = Theme(scheme)
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: model.glyph.symbol)
                .foregroundStyle(model.glyph == .breakTime ? theme.breakAccent : .primary)
            if !model.menuTitle.isEmpty {
                Text(model.menuTitle).monospacedDigit()
            }
        }
        .opacity(model.glyph == .paused ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onChange(of: model.countdown.status) { old, new in
            guard model.isOnline else { return }
            if new == .paused { AccessibilityNotification.Announcement("Paused, \(model.accessibilityTime)").post() }
            if new == .running, old == .paused { AccessibilityNotification.Announcement("Resumed").post() }
        }
    }

    private var accessibilityText: String {
        switch model.connection {
        case .offline: return "Pomo, daemon offline"
        case .connecting: return "Pomo, connecting"
        case .online:
            guard model.isLive else { return "Pomo, idle" }
            return "Pomo, \(model.phaseName), \(model.accessibilityTime)"
        }
    }
}
