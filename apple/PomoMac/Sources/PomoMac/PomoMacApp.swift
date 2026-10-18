import PomoMacKit
import SwiftUI

@main
struct PomoMacApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(env: env)
        } label: {
            MenuBarLabel(model: env.timer)
        }
        .menuBarExtraStyle(.window)

        Window("Pomo Statistics", id: "stats") {
            StatsView(stats: env.stats, timer: env.timer)
        }
        .windowResizability(.contentMinSize)

        Window("Pomo Settings", id: "settings") {
            SettingsView(env: env)
        }
        .windowResizability(.contentSize)
    }
}
