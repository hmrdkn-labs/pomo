import PomoUI
import SwiftUI

struct RootView: View {
    var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        Group {
            switch model.phase {
            case .starting:
                ProgressView("Opening…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Pomo could not start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .ready:
                if let services = model.services {
                    tabs(services)
                }
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .foregroundStyle(theme.text)
        .tint(theme.focus)
    }

    private func tabs(_ services: Services) -> some View {
        TabView {
            TimerScreen(timer: services.timer, sync: services.sync)
                .tabItem { Label("Timer", systemImage: "timer") }
            StatsScreen(stats: services.stats, timer: services.timer)
                .tabItem { Label("Stats", systemImage: "chart.bar") }
            DevicesScreen(devices: services.devices, sync: services.sync)
                .tabItem { Label("Devices", systemImage: "iphone.and.arrow.forward") }
            SettingsScreen(settings: model.settings, devices: services.devices)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// A capsule or rounded button in the design tokens' shapes, 44 pt tall at least.
struct PomoButtonStyle: ButtonStyle {
    enum Kind { case primary(Color), secondary, destructive }
    var kind: Kind
    var theme: Theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color
        let ink: Color
        switch kind {
        case let .primary(accent): fill = accent; ink = theme.scheme == .dark ? theme.bg : .white
        case .secondary: fill = theme.surface; ink = theme.text
        case .destructive: fill = theme.surface; ink = theme.danger
        }
        return configuration.label
            .font(.system(size: Tokens.TypeSize.body, weight: .semibold))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, Tokens.Spacing.m)
            .background(fill, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(theme.hairline))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}
