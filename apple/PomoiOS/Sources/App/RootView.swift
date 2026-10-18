import PomoUI
import SwiftUI

struct RootView: View {
    var model: AppModel
    @Environment(\.pomoTheme) private var theme

    var body: some View {
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
        .background(theme.paper.ignoresSafeArea())
        .foregroundStyle(theme.ink)
        .tint(theme.ink)
    }

    /// The tab bar tint is `ink`, and `focus` only while a focus block runs. Screen content keeps `ink`.
    private func tabs(_ services: Services) -> some View {
        let countdown = services.timer.countdown
        let focusRunning = countdown.status == .running && countdown.kind == .focus
        return TabView {
            TimerScreen(timer: services.timer, sync: services.sync)
                .screenChrome()
                .tabItem { Label("Timer", systemImage: "timer") }
            StatsScreen(stats: services.stats, timer: services.timer)
                .screenChrome()
                .tabItem { Label("Stats", systemImage: "chart.bar") }
            DevicesScreen(devices: services.devices, sync: services.sync)
                .screenChrome()
                .tabItem { Label("Devices", systemImage: "iphone.and.arrow.forward") }
            SettingsScreen(settings: model.settings, devices: services.devices)
                .screenChrome()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(focusRunning ? theme.focus : theme.ink)
    }
}

private struct ScreenChrome: ViewModifier {
    @Environment(\.pomoTheme) private var theme

    func body(content: Content) -> some View {
        content
            .tint(theme.ink)
            .toolbarBackground(theme.paper, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
    }
}

extension View {
    /// Content tint `ink` and a flat `paper` tab bar.
    func screenChrome() -> some View { modifier(ScreenChrome()) }
}
