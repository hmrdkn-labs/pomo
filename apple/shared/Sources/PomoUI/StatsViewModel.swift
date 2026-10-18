import Foundation
import Observation

public enum StatsRange {
    public static let dayMs: Int64 = 86_400_000

    /// Start (UTC ms) of the calendar day containing `nowMs` for a fixed UTC offset, as the Daemon computes it.
    public static func dayStart(nowMs: Int64, tzOffsetMin: Int) -> Int64 {
        let off = Int64(tzOffsetMin) * 60_000
        let local = nowMs + off
        let floored = local >= 0 ? local / dayMs * dayMs : -((-local + dayMs - 1) / dayMs) * dayMs
        return floored - off
    }

    /// The last `days` calendar days ending with today: `[from, to)`.
    public static func lastDays(_ days: Int, nowMs: Int64, tzOffsetMin: Int) -> (from: Int64, to: Int64) {
        let today = dayStart(nowMs: nowMs, tzOffsetMin: tzOffsetMin)
        return (today - Int64(days - 1) * dayMs, today + dayMs)
    }

    /// `yyyy-MM-dd` key of the local day starting at `dayStartMs`.
    public static func dayKey(dayStartMs: Int64, tzOffsetMin: Int) -> String {
        let local = Date(timeIntervalSince1970: Double(dayStartMs + Int64(tzOffsetMin) * 60_000) / 1000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day], from: local)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

public struct DayBar: Equatable, Sendable, Identifiable {
    public var key: String
    public var date: Date
    public var focusMs: Int64
    public var id: String { key }
}

@MainActor @Observable
public final class StatsViewModel {
    public private(set) var days: [DayBar] = []
    public private(set) var weekFocusMs: Int64 = 0
    public private(set) var todayFocusMs: Int64 = 0
    public private(set) var streakDays = 0
    public private(set) var labels: [StatGroup] = []
    public private(set) var projects: [StatGroup] = []
    public private(set) var error: String?
    public private(set) var isLoading = false

    private let connector: @Sendable () async throws -> any PomoAPI
    private let clock: @Sendable () -> Int64
    private let tzOffsetMin: @Sendable () -> Int

    public init(
        connector: @escaping @Sendable () async throws -> any PomoAPI,
        clock: @escaping @Sendable () -> Int64 = { PomoUI.nowMs() },
        tzOffsetMin: @escaping @Sendable () -> Int = { TimeZone.current.secondsFromGMT() / 60 }
    ) {
        self.connector = connector; self.clock = clock; self.tzOffsetMin = tzOffsetMin
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let api = try await connector()
            let now = clock()
            let tz = tzOffsetMin()
            let (from, to) = StatsRange.lastDays(7, nowMs: now, tzOffsetMin: tz)
            async let byDay = api.stats(fromMs: from, toMs: to, tzOffsetMin: tz, groupBy: .day)
            async let byLabel = api.stats(fromMs: from, toMs: to, tzOffsetMin: tz, groupBy: .label)
            async let byProject = api.stats(fromMs: from, toMs: to, tzOffsetMin: tz, groupBy: .project)
            let (d, l, p) = try await (byDay, byLabel, byProject)
            apply(day: d, label: l, project: p, from: from, tz: tz)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply(day: Stats, label: Stats, project: Stats, from: Int64, tz: Int) {
        let byKey = Dictionary(day.groups.map { ($0.key, $0.focusMs) }, uniquingKeysWith: +)
        days = (0..<7).map { i in
            let start = from + Int64(i) * StatsRange.dayMs
            let key = StatsRange.dayKey(dayStartMs: start, tzOffsetMin: tz)
            return DayBar(key: key, date: Date(timeIntervalSince1970: Double(start) / 1000), focusMs: byKey[key] ?? 0)
        }
        weekFocusMs = day.focusMs
        todayFocusMs = days.last?.focusMs ?? 0
        streakDays = day.streakDays
        labels = label.groups.filter { $0.focusMs > 0 }.sorted { $0.focusMs > $1.focusMs }
        projects = project.groups.filter { $0.focusMs > 0 }.sorted { $0.focusMs > $1.focusMs }
    }
}
