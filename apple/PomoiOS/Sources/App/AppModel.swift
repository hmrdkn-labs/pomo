import Foundation
import Observation
import PomoKit
import PomoLive
import PomoUI
import SwiftUI
import UIKit
import UserNotifications
import WidgetKit

/// Everything that exists once the Core is open.
@MainActor
final class Services {
    let engine: PomoEngine
    let timer: TimerViewModel
    let stats: StatsViewModel
    let devices: DevicesViewModel
    let sync: SyncCoordinator

    init(engine: PomoEngine, settings: PomoSettings) {
        let api = engine.api
        self.engine = engine
        self.timer = TimerViewModel(settings: settings, connector: { api })
        self.stats = StatsViewModel(connector: { api })
        self.devices = DevicesViewModel(connector: { api })
        self.sync = SyncCoordinator(runner: api)
    }
}

/// Owns the in-process Core and keeps the alerts in step with it: one `reconcile` after every state change
/// (a local Command, an event synced from another Device, a block ending, the app returning to the
/// foreground) updates the pending notification, the Live Activity and the widget snapshot.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable { case starting, ready, failed(String) }

    private(set) var phase: Phase = .starting
    private(set) var services: Services?
    let settings = PomoSettings()

    @ObservationIgnored private let notifications = NotificationCoordinator(scheduler: SystemNotificationScheduler())
    @ObservationIgnored private let liveActivity = LiveActivityController()
    @ObservationIgnored private let snapshots = SnapshotWriter()
    @ObservationIgnored private let notificationDelegate = ForegroundNotificationDelegate()
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var started = false

    func start() async {
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().delegate = notificationDelegate
        do {
            let engine = try await PomoEngine.open(
                directory: try Self.dataDirectory(), deviceName: UIDevice.current.name, network: .n0
            )
            let services = Services(engine: engine, settings: settings)
            services.timer.onWillStart = { Task { await SystemNotificationScheduler.requestAuthorization() } }
            services.timer.onBlockEnd = { _ in UINotificationFeedbackGenerator().notificationOccurred(.success) }
            self.services = services
            phase = .ready
            services.timer.connect()
            let api = engine.api
            watcher = Task { [weak self] in
                // `opened` first, then every event stored here (local or synced) and every block end.
                do { for try await _ in api.stream() { await self?.reconcile() } } catch {}
            }
            // The scene may already be active: `scenePhaseChanged` ran before the Core was open.
            if UIApplication.shared.applicationState == .active { activated() }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: activated()
        case .background: services?.sync.backgrounded()
        case .inactive: break
        @unknown default: break
        }
    }

    private func activated() {
        guard let services else { return }
        services.sync.foregrounded()
        Task {
            // A block may have ended, or events may have synced, while the app was suspended.
            try? await services.timer.refresh(services.engine.api)
            await reconcile()
        }
    }

    func reconcile() async {
        guard let api = services?.engine.api, let s = try? await api.status() else { return }
        await notifications.update(timer: s.timer, nowMs: s.nowMs)
        await liveActivity.update(timer: s.timer, nowMs: s.nowMs)
        snapshots.write(status: s)
    }

    /// `Application Support/Pomo`, kept out of backups: restoring a copy of the device key onto a second
    /// phone would give two Devices the same identity.
    static func dataDirectory() throws -> URL {
        var url = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "Pomo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }
}
