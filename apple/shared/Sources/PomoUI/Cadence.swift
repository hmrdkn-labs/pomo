/// Suggests the next block kind using this device's `long_break_every` setting (spec/events.md, Cycle).
public enum Cadence {
    /// `recent` is newest first. After a completed focus block, a long break is due once `every` completed
    /// focus blocks have run since the most recent long break; otherwise a short break. After anything
    /// else the Daemon's suggestion (`fallback`) stands.
    public static func nextKind(recent: [Block], every: Int, fallback: Kind) -> Kind {
        guard let first = recent.first, first.kind == .focus, first.outcome == "completed" else { return fallback }
        var n = 0
        for b in recent {
            if b.kind == .longBreak { break }
            if b.kind == .focus && b.outcome == "completed" { n += 1 }
        }
        return n >= max(1, every) ? .longBreak : .shortBreak
    }
}
