import AppKit
import Observation
import PomoUI
import SwiftUI

@MainActor
public final class AppEnvironment {
    public let settings: PomoSettings
    public let launcher: DaemonLauncher
    public let notifier = Notifier()
    public let timer: TimerViewModel
    public let stats: StatsViewModel

    public init(launcher: DaemonLauncher = DaemonLauncher(), defaults: UserDefaults = .standard) {
        self.launcher = launcher
        let settings = PomoSettings(defaults: defaults)
        self.settings = settings
        let connector: @Sendable () async throws -> any PomoAPI = { try await launcher.connect() }
        timer = TimerViewModel(settings: settings, connector: connector)
        stats = StatsViewModel(connector: connector)
        timer.onWillStart = { [notifier] in notifier.requestAuthorizationIfNeeded() }
        timer.onBlockEnd = { [notifier] notice in
            notifier.blockEnded(notice)
            AccessibilityNotification.Announcement("\(notice.kind.title) finished").post()
        }
        applyDockPolicy()
        timer.connect()
    }

    /// The Dock icon is off by default: the app runs as an accessory (menu bar only).
    public func applyDockPolicy() {
        NSApp?.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }
}
