import PomoUI
import SwiftUI

struct SettingsScreen: View {
    var settings: PomoSettings
    var devices: DevicesViewModel
    @Environment(\.pomoTheme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Focus: \(settings.focusMinutes) min", value: Bindable(settings).focusMinutes, in: 1...180)
                    Stepper("Short break: \(settings.shortBreakMinutes) min", value: Bindable(settings).shortBreakMinutes, in: 1...60)
                    Stepper("Long break: \(settings.longBreakMinutes) min", value: Bindable(settings).longBreakMinutes, in: 1...90)
                    Stepper("Long break every \(settings.longBreakEvery) focus blocks", value: Bindable(settings).longBreakEvery, in: 1...12)
                } header: {
                    Text("Durations")
                } footer: {
                    Text("Used when this iPhone starts a block. Blocks started on another device keep that device's length.")
                }
                .listRowBackground(theme.paperRaised)
                Section("About") {
                    LabeledContent("Device", value: devices.ownName)
                    LabeledContent("Data", value: "On this iPhone and your paired devices only")
                }
                .listRowBackground(theme.paperRaised)
            }
            .scrollContentBackground(.hidden)
            .background(theme.paper)
            .navigationTitle("Settings")
            .task { await devices.load() }
        }
    }
}
