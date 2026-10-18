import PomoUI
import ServiceManagement
import SwiftUI

public struct SettingsView: View {
    var env: AppEnvironment
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @Environment(\.colorScheme) private var scheme

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        @Bindable var s = env.settings
        Form {
            Section("Durations") {
                Stepper("Focus: \(s.focusMinutes) min", value: $s.focusMinutes, in: 1...180)
                Stepper("Short break: \(s.shortBreakMinutes) min", value: $s.shortBreakMinutes, in: 1...60)
                Stepper("Long break: \(s.longBreakMinutes) min", value: $s.longBreakMinutes, in: 1...120)
                Stepper("Long break every \(s.longBreakEvery) focus blocks", value: $s.longBreakEvery, in: 1...12)
                Text("Applied when you start a block from this app.").font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(Theme(scheme).danger) }
                Toggle("Show Dock icon", isOn: $s.showDockIcon)
                    .onChange(of: s.showDockIcon) { _, _ in env.applyDockPolicy() }
            }
            Section("Daemon") {
                LabeledContent("Data folder", value: env.launcher.home.path)
                Text("Quitting Pomo leaves the daemon running.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { openAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change login item: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
