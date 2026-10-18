import SwiftUI

/// Statistics in the paper-and-ink style, shared by the Mac window and the iPhone tab: three figures in a row,
/// bars per day (today in `focus`), and plain ranked lists. No card backgrounds.
public struct StatsContent: View {
    var stats: StatsViewModel
    @Environment(\.pomoTheme) private var theme

    /// Stat figures are the numeral face, larger than the 15 pt `numeral` role so they read as the interface.
    static let figureSize: CGFloat = 30

    public init(stats: StatsViewModel) { self.stats = stats }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                figure("Today", formatDuration(ms: stats.todayFocusMs))
                figure("This week", formatDuration(ms: stats.weekFocusMs))
                figure("Streak", stats.streakDays == 1 ? "1 day" : "\(stats.streakDays) days")
            }
            if let e = stats.error {
                Text(e).pomoFont(.secondary).foregroundStyle(theme.danger)
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                heading("Focus by day")
                bars
            }
            ranking("Labels this week", stats.labels, emptyKey: "No label")
            ranking("Projects this week", stats.projects, emptyKey: "No project")
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).pomoFont(.phase).foregroundStyle(theme.inkMuted).accessibilityAddTraits(.isHeader)
    }

    private func figure(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(value)
                .font(.system(size: Self.figureSize, design: .serif).italic().monospacedDigit())
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption).pomoFont(.secondary).foregroundStyle(theme.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let barArea: CGFloat = 120

    private var bars: some View {
        let top = max(stats.days.map(\.focusMs).max() ?? 0, 3_600_000)
        return VStack(spacing: Tokens.Spacing.xs) {
            HStack(alignment: .bottom, spacing: Tokens.Spacing.s) {
                ForEach(Array(stats.days.enumerated()), id: \.element.id) { i, d in
                    let isToday = i == stats.days.count - 1
                    Rectangle()
                        .fill(isToday ? theme.focus : theme.ink)
                        .frame(height: d.focusMs == 0 ? 0 : max(2, Self.barArea * Double(d.focusMs) / Double(top)))
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.barArea, alignment: .bottom)
                        .accessibilityElement()
                        .accessibilityLabel(d.date.formatted(.dateTime.weekday(.wide)))
                        .accessibilityValue(formatDuration(ms: d.focusMs))
                }
            }
            Hairline()
            HStack(spacing: Tokens.Spacing.s) {
                ForEach(Array(stats.days.enumerated()), id: \.element.id) { i, d in
                    Text(d.date.formatted(.dateTime.weekday(.narrow)))
                        .pomoFont(.secondary, weight: i == stats.days.count - 1 ? .semibold : .regular)
                        .foregroundStyle(i == stats.days.count - 1 ? theme.ink : theme.inkMuted)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder private func ranking(_ title: String, _ groups: [StatGroup], emptyKey: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            heading(title)
            if groups.isEmpty {
                Text("Nothing yet").pomoFont(.secondary).foregroundStyle(theme.inkMuted)
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                if i > 0 { Hairline() }
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.m) {
                    Text(g.key.isEmpty ? emptyKey : g.key)
                        .pomoFont(.body)
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: Tokens.Spacing.s)
                    Text(formatDuration(ms: g.focusMs))
                        .pomoFont(.numeral)
                        .foregroundStyle(theme.ink)
                }
                .padding(.vertical, Tokens.Spacing.xs)
            }
        }
    }
}
