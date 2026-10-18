import Foundation
import PomoUI

/// What the Lock Screen and Dynamic Island show for the live block. It carries absolute times, so the
/// system draws the countdown (`Text(timerInterval:)`) without the app running.
public struct LiveActivityContent: Codable, Hashable, Sendable {
    public var blockId: String
    public var kind: Kind
    public var label: String?
    public var paused: Bool
    /// Running: when the block started counting, `endsMs - plannedMs`, so the rule over `startMs...endsMs`
    /// shows the right length after pauses and extensions. Paused: the same, as if resumed now.
    public var startMs: Int64
    /// Running: absolute end time. Paused: the end time if resumed now.
    public var endsMs: Int64
    public var plannedMs: Int64
    /// Paused: the frozen remaining time. Running: the remaining time when this content was made.
    public var remainingMs: Int64

    public init(
        blockId: String, kind: Kind, label: String?, paused: Bool, startMs: Int64, endsMs: Int64,
        plannedMs: Int64, remainingMs: Int64
    ) {
        self.blockId = blockId; self.kind = kind; self.label = label; self.paused = paused
        self.startMs = startMs; self.endsMs = endsMs; self.plannedMs = plannedMs; self.remainingMs = remainingMs
    }

    public var startDate: Date { Date(timeIntervalSince1970: Double(startMs) / 1000) }
    public var endDate: Date { Date(timeIntervalSince1970: Double(endsMs) / 1000) }

    /// `startDate...endDate` for the system-drawn rule (`ProgressView(timerInterval:)`); never empty or reversed.
    public var interval: ClosedRange<Date> { startDate...max(startDate, endDate) }

    public var phaseName: String { paused ? "Paused" : kind.title }

    /// Frozen `mm:ss` for the paused state.
    public var frozenDisplay: String { Countdown.format(remainingMs: remainingMs) }

    /// 1...0 fraction of the block that is left, as of `nowMs`: the length of the rule (full at the start).
    public func remainingFraction(at nowMs: Int64) -> Double {
        guard plannedMs > 0 else { return 0 }
        let remaining = paused ? remainingMs : max(0, endsMs - nowMs)
        return min(1, max(0, Double(remaining) / Double(plannedMs)))
    }

    /// When the system should treat the activity as out of date: the block's end.
    public var staleDate: Date? { paused ? nil : endDate }

    /// Same Timer state, allowing for the jitter of rederiving the end time from `remaining_ms`.
    func isEquivalent(to other: LiveActivityContent) -> Bool {
        blockId == other.blockId && kind == other.kind && label == other.label && paused == other.paused
            && plannedMs == other.plannedMs
            && (paused ? remainingMs == other.remainingMs : abs(endsMs - other.endsMs) < 1000)
    }
}

public enum LiveActivityAction: Equatable, Sendable {
    case none
    case start(LiveActivityContent)
    case update(LiveActivityContent)
    case end
}

public enum LiveActivityPlanner {
    /// The content for a live (running or paused, not yet finished) block; nil otherwise.
    public static func content(timer: TimerState, nowMs: Int64) -> LiveActivityContent? {
        guard timer.status != .idle, let block = timer.block, let remaining = timer.remainingMs else { return nil }
        let paused = timer.status == .paused
        if !paused && remaining <= 0 { return nil }
        let ends = nowMs + remaining
        return LiveActivityContent(
            blockId: block.id, kind: block.kind, label: block.label?.isEmpty == true ? nil : block.label,
            paused: paused, startMs: ends - block.plannedMs, endsMs: ends, plannedMs: block.plannedMs,
            remainingMs: remaining
        )
    }

    /// What to do with the Live Activity so that it shows `timer`. `current` is the content on screen, nil
    /// when there is no activity.
    public static func plan(timer: TimerState, nowMs: Int64, current: LiveActivityContent?) -> LiveActivityAction {
        guard let wanted = content(timer: timer, nowMs: nowMs) else { return current == nil ? .none : .end }
        guard let current else { return .start(wanted) }
        return current.isEquivalent(to: wanted) ? .none : .update(wanted)
    }
}
