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
    public let devices: DevicesViewModel
    public private(set) var shortcuts: ShortcutsModel!
    private var hotKeys: CarbonHotKeys?

    public init(launcher: DaemonLauncher = DaemonLauncher(), defaults: UserDefaults = .standard) {
        self.launcher = launcher
        let settings = PomoSettings(defaults: defaults)
        self.settings = settings
        let connector: @Sendable () async throws -> any PomoAPI = { try await launcher.connect() }
        timer = TimerViewModel(settings: settings, connector: connector)
        stats = StatsViewModel(connector: connector)
        devices = DevicesViewModel(connector: { try await launcher.connect() })
        timer.onWillStart = { [notifier] in notifier.requestAuthorizationIfNeeded() }
        timer.onBlockEnd = { [notifier] notice in
            notifier.blockEnded(notice)
            AccessibilityNotification.Announcement("\(notice.kind.title) finished").post()
        }
        let hotKeys = CarbonHotKeys { [weak timer] action in
            guard let timer else { return }
            switch action {
            case .toggle: Task { await timer.togglePause() }
            case .skip: Task { await timer.skip() }
            }
        }
        self.hotKeys = hotKeys
        shortcuts = ShortcutsModel(store: ShortcutStore(defaults: defaults), registrar: hotKeys)
        applyDockPolicy()
        timer.connect()
    }

    /// The Dock icon is off by default: the app runs as an accessory (menu bar only).
    public func applyDockPolicy() {
        NSApp?.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }
}
