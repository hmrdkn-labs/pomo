import Foundation

/// A Timer observed at a known instant. Display values derive from absolute time, never from tick counts.
public struct Countdown: Equatable, Sendable {
    public var status: TimerStatus
    public var kind: Kind?
    public var plannedMs: Int64
    /// Absolute end time (ms since epoch) while running.
    public var endsMs: Int64?
    /// Frozen remaining time while paused, full planned time otherwise.
    public var frozenRemainingMs: Int64

    public static let idle = Countdown(status: .idle, kind: nil, plannedMs: 0, endsMs: nil, frozenRemainingMs: 0)

    public init(status: TimerStatus, kind: Kind?, plannedMs: Int64, endsMs: Int64?, frozenRemainingMs: Int64) {
        self.status = status; self.kind = kind; self.plannedMs = plannedMs
        self.endsMs = endsMs; self.frozenRemainingMs = frozenRemainingMs
    }

    /// Builds a countdown from a status response; `nowMs` is the server's `now_ms` for that response.
    public init(timer: TimerState, nowMs: Int64) {
        let remaining = max(0, timer.remainingMs ?? 0)
        self.status = timer.status
        self.kind = timer.block?.kind
        self.plannedMs = timer.block?.plannedMs ?? 0
        self.frozenRemainingMs = remaining
        self.endsMs = timer.status == .running ? nowMs + remaining : nil
        if timer.status == .idle { self = .idle }
    }

    public func remainingMs(at nowMs: Int64) -> Int64 {
        switch status {
        case .idle: 0
        case .paused: frozenRemainingMs
        case .running: max(0, (endsMs ?? nowMs) - nowMs)
        }
    }

    /// 1...0 fraction of the block that is left: 1 at the start, 0 at the end, 0 when idle. The rule is drawn from it.
    public func remainingFraction(at nowMs: Int64) -> Double {
        guard status != .idle, plannedMs > 0 else { return 0 }
        return min(1, max(0, Double(remainingMs(at: nowMs)) / Double(plannedMs)))
    }

    /// `mm:ss`, rounded up so `00:00` only shows at the end. Minutes grow past 99 for long blocks.
    public func display(at nowMs: Int64) -> String {
        Self.format(remainingMs: remainingMs(at: nowMs))
    }

    public static func format(remainingMs: Int64) -> String {
        let secs = (max(0, remainingMs) + 999) / 1000
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    /// Milliseconds until the displayed second next changes; nil when nothing ticks.
    public func msUntilNextTick(at nowMs: Int64) -> Int64? {
        guard status == .running else { return nil }
        let r = remainingMs(at: nowMs)
        if r <= 0 { return nil }
        let m = r % 1000
        return m == 0 ? 1000 : m
    }
}

public func formatDuration(ms: Int64) -> String {
    let mins = Int((ms + 30_000) / 60_000)
    if mins < 60 { return "\(mins) min" }
    return mins % 60 == 0 ? "\(mins / 60) h" : "\(mins / 60) h \(mins % 60) min"
}

/// "started by assistant" style tag for blocks not issued by a person.
public func sourceTag(_ source: String) -> String? {
    guard source.hasPrefix("agent:") else { return nil }
    let name = String(source.dropFirst("agent:".count))
    return name.isEmpty ? "started by agent" : "started by \(name)"
}

/// The same tag as a byline: "by claude".
public func sourceByline(_ source: String) -> String? {
    sourceTag(source).map { String($0.dropFirst("started ".count)) }
}

public func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
