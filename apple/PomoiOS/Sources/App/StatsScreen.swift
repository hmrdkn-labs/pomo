import PomoUI
import SwiftUI

struct StatsScreen: View {
    var stats: StatsViewModel
    var timer: TimerViewModel
    @Environment(\.pomoTheme) private var theme

    var body: some View {
        ScrollView {
            StatsContent(stats: stats)
                .padding(.horizontal, Tokens.Spacing.phoneMargin)
                .padding(.vertical, Tokens.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.paper.ignoresSafeArea())
        .refreshable { await stats.load() }
        .task { await stats.load() }
        .onChange(of: timer.today) { _, _ in Task { await stats.load() } }
        .onChange(of: timer.resyncCount) { _, _ in Task { await stats.load() } }
    }
}
