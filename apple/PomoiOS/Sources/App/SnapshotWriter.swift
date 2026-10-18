import Foundation
import PomoLive
import PomoUI
import WidgetKit

/// Writes today's focus total and whether a block runs for the home screen widget, and reloads its timelines
/// when either changed.
@MainActor
final class SnapshotWriter {
    private let store: SnapshotStore
    private let reload: () -> Void
    private let tzOffsetMin: () -> Int
    private var last: TodaySnapshot?

    init(
        store: SnapshotStore = SnapshotStore(),
        tzOffsetMin: @escaping () -> Int = { TimeZone.current.secondsFromGMT() / 60 },
        reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.store = store; self.tzOffsetMin = tzOffsetMin; self.reload = reload
    }

    func write(status: Status) {
        let snapshot = TodaySnapshot(status: status, tzOffsetMin: tzOffsetMin())
        guard !snapshot.sameTotals(as: last ?? store.load()) else { return }
        store.save(snapshot)
        last = snapshot
        reload()
    }
}

extension TodaySnapshot {
    /// Equal but for `updatedMs` and the millisecond jitter of re-deriving a running block's end time.
    func sameTotals(as other: TodaySnapshot) -> Bool {
        let sameRun: Bool
        switch (runningUntilMs, other.runningUntilMs) {
        case (nil, nil): sameRun = true
        case let (a?, b?): sameRun = abs(a - b) < 1000
        default: sameRun = false
        }
        return dayStartMs == other.dayStartMs && dayEndMs == other.dayEndMs && focusMs == other.focusMs
            && completedFocus == other.completedFocus && sameRun
    }
}
