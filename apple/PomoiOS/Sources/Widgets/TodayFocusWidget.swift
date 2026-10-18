import PomoLive
import PomoUI
import SwiftUI
import WidgetKit

struct TodayEntry: TimelineEntry {
    var date: Date
    var snapshot: TodaySnapshot

    var focusMs: Int64 { snapshot.focusMs(at: nowMs) }
    var completed: Int { snapshot.completedFocus(at: nowMs) }
    private var nowMs: Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, snapshot: TodaySnapshot(
            dayStartMs: 0, dayEndMs: .max, focusMs: 100 * 60_000, completedFocus: 4, updatedMs: 0))
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : TodayEntry(date: .now, snapshot: SnapshotStore().load()))
    }

    /// One entry now and one at the start of the next day (which reads zero until the app writes again).
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let snapshot = SnapshotStore().load()
        let now = Date()
        var entries = [TodayEntry(date: now, snapshot: snapshot)]
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        if let next = snapshot.nextDayStart(after: nowMs) {
            entries.append(TodayEntry(date: next, snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Label("Focus today", systemImage: "circle.fill")
                .font(.system(size: Tokens.TypeSize.secondary, weight: .semibold))
                .foregroundStyle(theme.focus)
            Spacer(minLength: 0)
            Text(entry.focusMs == 0 ? "0 min" : formatDuration(ms: entry.focusMs))
                .font(.system(size: 28, weight: .semibold).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(entry.completed == 1 ? "1 block done" : "\(entry.completed) blocks done")
                .font(.system(size: Tokens.TypeSize.secondary))
                .foregroundStyle(theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(theme.text)
        .containerBackground(theme.bg, for: .widget)
        .accessibilityElement(children: .combine)
    }
}
