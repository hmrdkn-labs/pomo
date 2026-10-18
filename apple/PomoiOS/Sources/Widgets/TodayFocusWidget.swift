import PomoLive
import PomoUI
import SwiftUI
import WidgetKit

struct TodayEntry: TimelineEntry {
    var date: Date
    var snapshot: TodaySnapshot

    var focusMs: Int64 { snapshot.focusMs(at: nowMs) }
    var completed: Int { snapshot.completedFocus(at: nowMs) }
    var running: Bool { snapshot.isRunning(at: nowMs) }
    private var nowMs: Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, snapshot: TodaySnapshot(
            dayStartMs: 0, dayEndMs: .max, focusMs: 100 * 60_000, completedFocus: 4, updatedMs: 0, runningUntilMs: .max))
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : TodayEntry(date: .now, snapshot: SnapshotStore().load()))
    }

    /// One entry now, one when the running block ends (the dot goes out) and one at the start of the next day
    /// (which reads zero until the app writes again).
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let snapshot = SnapshotStore().load()
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var dates = [now]
        if let until = snapshot.runningUntilMs, until > nowMs {
            dates.append(Date(timeIntervalSince1970: Double(until) / 1000))
        }
        if let next = snapshot.nextDayStart(after: nowMs) { dates.append(next) }
        completion(Timeline(entries: dates.sorted().map { TodayEntry(date: $0, snapshot: snapshot) }, policy: .atEnd))
    }
}

struct TodayFocusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.hamardikan.pomo.today", provider: TodayProvider()) { entry in
            TodayFocusView(entry: entry)
        }
        .configurationDisplayName("Today's focus")
        .description("Focus time so far today.")
        .supportedFamilies([.systemSmall])
    }
}

struct TodayFocusView: View {
    var entry: TodayEntry
    @Environment(\.pomoTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.s) {
                Text("Focus today").pomoFont(.phase).foregroundStyle(theme.inkMuted)
                Spacer(minLength: 0)
                if entry.running {
                    Circle().fill(theme.focus).frame(width: 8, height: 8).accessibilityLabel("Timer running")
                }
            }
            Spacer(minLength: 0)
            Text(entry.focusMs == 0 ? "0 min" : formatDuration(ms: entry.focusMs))
                .font(.system(size: 34, design: .serif).italic().monospacedDigit())
                .foregroundStyle(theme.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(entry.completed == 1 ? "1 block done" : "\(entry.completed) blocks done")
                .pomoFont(.secondary)
                .foregroundStyle(theme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(theme.paper, for: .widget)
        .accessibilityElement(children: .combine)
    }
}
