import Foundation
import PomoUI

/// Today's focus total, written by the app and read by the home screen widget (which runs in another
/// process and cannot open the store).
public struct TodaySnapshot: Codable, Equatable, Sendable {
    public var dayStartMs: Int64
    public var dayEndMs: Int64
    public var focusMs: Int64
    public var completedFocus: Int
    public var updatedMs: Int64

    public init(dayStartMs: Int64, dayEndMs: Int64, focusMs: Int64, completedFocus: Int, updatedMs: Int64) {
        self.dayStartMs = dayStartMs; self.dayEndMs = dayEndMs; self.focusMs = focusMs
        self.completedFocus = completedFocus; self.updatedMs = updatedMs
    }

    public static let empty = TodaySnapshot(dayStartMs: 0, dayEndMs: 0, focusMs: 0, completedFocus: 0, updatedMs: 0)

    /// From a status response; the day is the calendar day of `status.nowMs` in `tzOffsetMin`.
    public init(status: Status, tzOffsetMin: Int) {
        let start = StatsRange.dayStart(nowMs: status.nowMs, tzOffsetMin: tzOffsetMin)
        self.init(
            dayStartMs: start, dayEndMs: start + StatsRange.dayMs, focusMs: status.today.focusMs,
            completedFocus: status.today.completedFocus, updatedMs: status.nowMs
        )
    }

    /// The total to show at `nowMs`: zero once the stored day is over (the app has not run since).
    public func focusMs(at nowMs: Int64) -> Int64 {
        nowMs >= dayStartMs && nowMs < dayEndMs ? focusMs : 0
    }

    public func completedFocus(at nowMs: Int64) -> Int {
        nowMs >= dayStartMs && nowMs < dayEndMs ? completedFocus : 0
    }

    /// When the widget should next refresh by itself: the start of the next day, if the snapshot has one.
    public func nextDayStart(after nowMs: Int64) -> Date? {
        dayEndMs > nowMs ? Date(timeIntervalSince1970: Double(dayEndMs) / 1000) : nil
    }
}

/// The App Group suite shared by the app and its extensions.
public struct SnapshotStore: Sendable {
    public static let appGroup = "group.dev.hamardikan.pomo"
    private static let key = "today-snapshot"

    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults? = UserDefaults(suiteName: SnapshotStore.appGroup)) {
        self.defaults = defaults ?? .standard
    }

    public func load() -> TodaySnapshot {
        guard let data = defaults.data(forKey: Self.key),
              let s = try? JSONDecoder().decode(TodaySnapshot.self, from: data)
        else { return .empty }
        return s
    }

    public func save(_ snapshot: TodaySnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Self.key) }
    }
}
