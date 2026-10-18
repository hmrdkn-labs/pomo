import Charts
import PomoUI
import SwiftUI

public struct StatsView: View {
    var stats: StatsViewModel
    var timer: TimerViewModel
    @Environment(\.colorScheme) private var scheme

    public init(stats: StatsViewModel, timer: TimerViewModel) { self.stats = stats; self.timer = timer }

    private var theme: Theme { Theme(scheme) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                HStack(spacing: Tokens.Spacing.m) {
                    card("Today", formatDuration(ms: stats.todayFocusMs))
                    card("This week", formatDuration(ms: stats.weekFocusMs))
                    card("Streak", stats.streakDays == 1 ? "1 day" : "\(stats.streakDays) days")
                }
                if let e = stats.error {
                    Text(e).foregroundStyle(theme.danger).font(.system(size: Tokens.TypeSize.secondary))
                }
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    Text("Focus by day").font(.system(size: Tokens.TypeSize.body, weight: .semibold))
                    Chart(stats.days) { d in
                        BarMark(x: .value("Day", d.date, unit: .day), y: .value("Hours", Double(d.focusMs) / 3_600_000))
                            .foregroundStyle(theme.focus)
                            .cornerRadius(4)
                            .accessibilityLabel(d.date.formatted(.dateTime.weekday(.wide)))
                            .accessibilityValue(formatDuration(ms: d.focusMs))
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let h = v.as(Double.self) { Text("\(h, specifier: "%g") h") } } } }
                    .frame(height: 160)
                }
                .padding(Tokens.Spacing.l)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))

                ranking("Labels", stats.labels, emptyKey: "No label")
                ranking("Projects", stats.projects, emptyKey: "No project")
            }
            .padding(Tokens.Spacing.xl)
        }
        .frame(minWidth: 460, minHeight: 520)
        .background(theme.bg)
        .foregroundStyle(theme.text)
        .task { await stats.load() }
        .onChange(of: timer.today) { _, _ in Task { await stats.load() } }
        .toolbar {
            ToolbarItem { Button { Task { await stats.load() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh").accessibilityLabel("Refresh statistics") }
        }
    }

    private func card(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(title).font(.system(size: Tokens.TypeSize.secondary)).foregroundStyle(theme.textMuted)
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Spacing.m)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func ranking(_ title: String, _ groups: [StatGroup], emptyKey: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("\(title) this week").font(.system(size: Tokens.TypeSize.body, weight: .semibold))
            if groups.isEmpty {
                Text("Nothing yet").font(.system(size: Tokens.TypeSize.secondary)).foregroundStyle(theme.textMuted)
            }
            let maxMs = Double(groups.first?.focusMs ?? 1)
            ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                HStack(spacing: Tokens.Spacing.m) {
                    Text("\(i + 1)").frame(width: 18, alignment: .trailing).foregroundStyle(theme.textMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.key.isEmpty ? emptyKey : g.key).lineLimit(1)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2).fill(theme.focus)
                                .frame(width: max(2, geo.size.width * Double(g.focusMs) / maxMs), height: 4)
                        }.frame(height: 4)
                    }
                    Text(formatDuration(ms: g.focusMs)).font(.system(size: Tokens.TypeSize.secondary).monospacedDigit()).foregroundStyle(theme.textMuted)
                }
                .font(.system(size: Tokens.TypeSize.secondary))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }
}
