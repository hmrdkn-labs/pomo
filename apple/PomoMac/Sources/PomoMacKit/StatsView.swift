import PomoUI
import SwiftUI

public struct StatsView: View {
    var stats: StatsViewModel
    var timer: TimerViewModel
    @Environment(\.pomoTheme) private var theme

    public init(stats: StatsViewModel, timer: TimerViewModel) { self.stats = stats; self.timer = timer }

    public var body: some View {
        ScrollView {
            StatsContent(stats: stats)
                .padding(Tokens.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 520)
        .background(theme.paper)
        .foregroundStyle(theme.ink)
        .task { await stats.load() }
        .onChange(of: timer.today) { _, _ in Task { await stats.load() } }
        .onChange(of: timer.resyncCount) { _, _ in Task { await stats.load() } }
        .toolbar {
            ToolbarItem { Button { Task { await stats.load() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh").accessibilityLabel("Refresh statistics") }
        }
    }
}
