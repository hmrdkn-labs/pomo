import Foundation
import PomoUI

/// The local notification that tells the user a block has ended. At most one is pending, always for the
/// running block, at its absolute end time.
public struct BlockEndNotification: Equatable, Sendable {
    /// One identifier for every block, so scheduling again replaces the pending request.
    public static let identifier = "pomo.block-end"

    public var blockId: String
    public var kind: Kind
    public var fireAtMs: Int64
    public var title: String
    public var body: String

    public init(blockId: String, kind: Kind, fireAtMs: Int64, title: String, body: String) {
        self.blockId = blockId; self.kind = kind; self.fireAtMs = fireAtMs; self.title = title; self.body = body
    }

    public var fireDate: Date { Date(timeIntervalSince1970: Double(fireAtMs) / 1000) }
}

public enum NotificationAction: Equatable, Sendable {
    /// The pending notification already matches the Timer.
    case keep
    case schedule(BlockEndNotification)
    case cancel
}

public enum NotificationPlanner {
    /// Pending requests whose fire time differs by less than this are the same (the end time is rederived
    /// from `remaining_ms` on every status read).
    static let toleranceMs: Int64 = 1000

    /// What to do with the pending notification so that it matches `timer`, observed at `nowMs`. Only a
    /// running block that has not reached its end gets a notification: pause, skip, stop, completion
    /// (seen on this or another Device) and an idle Timer cancel it; extend and reset move it.
    public static func plan(timer: TimerState, nowMs: Int64, scheduled: BlockEndNotification?) -> NotificationAction {
        guard timer.status == .running, let block = timer.block, let remaining = timer.remainingMs, remaining > 0 else {
            return .cancel
        }
        let wanted = BlockEndNotification(
            blockId: block.id, kind: block.kind, fireAtMs: nowMs + remaining,
            title: title(for: block.kind), body: body(for: block)
        )
        if let s = scheduled, s.blockId == wanted.blockId, s.title == wanted.title, s.body == wanted.body,
           abs(s.fireAtMs - wanted.fireAtMs) < toleranceMs
        {
            return .keep
        }
        return .schedule(wanted)
    }

    static func title(for kind: Kind) -> String {
        switch kind {
        case .focus: "Focus complete"
        case .shortBreak: "Break over"
        case .longBreak: "Long break over"
        }
    }

    static func body(for block: Block) -> String {
        switch block.kind {
        case .focus:
            if let label = block.label, !label.isEmpty { return "\(label) is done. Time for a break." }
            return "Time for a break."
        case .shortBreak, .longBreak:
            return "Ready for the next focus block."
        }
    }
}

/// The system side of scheduling (`UNUserNotificationCenter` in the app, a fake in tests).
public protocol NotificationScheduling: Sendable {
    /// Replaces any pending block-end notification.
    func schedule(_ notification: BlockEndNotification) async
    func cancel() async
}

/// Keeps the pending notification in step with the Timer. Call `update` after every state change,
/// whether it came from a local Command or from Sync.
public actor NotificationCoordinator {
    private let scheduler: any NotificationScheduling
    private var scheduled: BlockEndNotification?
    private var cancelled = false

    public init(scheduler: any NotificationScheduling) { self.scheduler = scheduler }

    public func update(timer: TimerState, nowMs: Int64) async {
        switch NotificationPlanner.plan(timer: timer, nowMs: nowMs, scheduled: scheduled) {
        case .keep:
            return
        case let .schedule(n):
            scheduled = n
            cancelled = false
            await scheduler.schedule(n)
        case .cancel:
            // The first cancel also clears a request left by a previous launch.
            guard scheduled != nil || !cancelled else { return }
            scheduled = nil
            cancelled = true
            await scheduler.cancel()
        }
    }
}
