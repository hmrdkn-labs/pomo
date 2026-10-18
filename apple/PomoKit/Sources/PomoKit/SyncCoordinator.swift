import Foundation
import Observation
import PomoUI

/// What the coordinator needs from the Core.
public protocol SyncRunning: Sendable {
    /// Syncs with every paired Device now.
    func syncNow() async throws -> [PeerSync]
    /// Syncs with paired Devices that have no open session (periodic rounds).
    func syncIdle() async throws -> [PeerSync]
    func setLive(_ live: Bool)
}

/// Runs Sync when the app opens or returns to the foreground, then every 60 s while it stays there, and
/// on demand. While foregrounded the node is live, so peers keep sessions open and forward new events.
/// iOS suspends the app in the background: there the node stops being live and nothing runs.
@MainActor @Observable
public final class SyncCoordinator {
    public private(set) var isSyncing = false
    public private(set) var lastSyncMs: Int64?
    public private(set) var lastResults: [PeerSync] = []
    public private(set) var lastError: String?
    public private(set) var isForeground = false

    public static let interval: Duration = .seconds(60)

    @ObservationIgnored private let runner: any SyncRunning
    @ObservationIgnored private let clock: @Sendable () -> Int64
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var loop: Task<Void, Never>?

    public init(
        runner: any SyncRunning,
        interval: Duration = SyncCoordinator.interval,
        clock: @escaping @Sendable () -> Int64 = { PomoUI.nowMs() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.runner = runner; self.interval = interval; self.clock = clock; self.sleep = sleep
    }

    /// The app became active: go live, sync now and keep syncing every `interval`.
    public func foregrounded() {
        guard !isForeground else { return }
        isForeground = true
        runner.setLive(true)
        loop = Task { [weak self] in
            await self?.round(explicit: true)
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.sleep(self.interval) } catch { return }
                await self.round(explicit: false)
            }
        }
    }

    /// The app left the foreground: stop the rounds and stop being live.
    public func backgrounded() {
        guard isForeground else { return }
        isForeground = false
        loop?.cancel()
        loop = nil
        runner.setLive(false)
    }

    /// The "Sync now" button. Does nothing while a round is running.
    public func syncNow() async {
        await round(explicit: true)
    }

    private func round(explicit: Bool) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let results = try await (explicit ? runner.syncNow() : runner.syncIdle())
            lastResults = results
            lastError = results.isEmpty ? nil : results.compactMap(\.error).first
            lastSyncMs = clock()
        } catch is CancellationError {
        } catch {
            lastError = error.localizedDescription
        }
    }
}
