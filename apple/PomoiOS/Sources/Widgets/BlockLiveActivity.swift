import ActivityKit
import PomoLive
import PomoUI
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island presentation of the running block. `ink` ground in both appearances, the serif
/// countdown, a 3 pt rule. Running countdowns and the rule are drawn by the system from absolute dates
/// (`Text(timerInterval:)`, `ProgressView(timerInterval:)`), so they tick without the app.
struct BlockLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PomoActivityAttributes.self) { context in
            LockScreenView(content: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            let c = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseTitle(content: c)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityBody(content: c, isStale: context.isStale)
                }
            } compactLeading: {
                Image(systemName: glyph(c)).foregroundStyle(accent(c))
            } compactTrailing: {
                CountdownText(content: c, isStale: context.isStale).monospacedDigit().frame(width: 48)
            } minimal: {
                Image(systemName: glyph(c)).foregroundStyle(accent(c))
            }
            .keylineTint(accent(c))
        }
    }
}

private func glyph(_ c: LiveActivityContent) -> String {
    c.paused ? Glyph.paused.symbol : (c.kind.isBreak ? Glyph.breakTime.symbol : Glyph.focus.symbol)
}

/// Rule and glyph colour on the `ink` ground: `focus` or `break`, `ink-muted` while paused.
private func accent(_ c: LiveActivityContent) -> Color {
    c.paused ? ActivityPalette.muted : ActivityPalette.accent(for: c.kind)
}

/// `mm:ss` from the system while running, the frozen value while paused, and "Done" once stale.
private struct CountdownText: View {
    var content: LiveActivityContent
    var isStale: Bool

    var body: some View {
        if content.paused {
            Text(content.frozenDisplay)
        } else if isStale || content.endDate <= .now {
            Text("Done")
        } else {
            Text(timerInterval: Date.now...content.endDate, pauseTime: nil, countsDown: true, showsHours: false)
        }
    }
}

private struct PhaseTitle: View {
    var content: LiveActivityContent

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: glyph(content)).imageScale(.small).foregroundStyle(accent(content)).accessibilityHidden(true)
            Text(content.phaseName).pomoFont(.phase).foregroundStyle(ActivityPalette.text)
        }
    }
}

/// The 3 pt rule: full at the start and shortening from the right. Running, the system animates it from the
/// absolute interval; paused, it is frozen at the remaining fraction.
private struct LiveRule: View {
    var content: LiveActivityContent

    var body: some View {
        Group {
            if content.paused {
                RuleBar(
                    fraction: content.remainingFraction(at: 0), tint: accent(content),
                    track: Tokens.color("hairline", .dark), height: Tokens.Rule.heightPopover)
            } else {
                ProgressView(timerInterval: content.interval, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
                    .tint(accent(content))
                    .frame(height: Tokens.Rule.heightPopover)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ActivityBody: View {
    var content: LiveActivityContent
    var isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            CountdownText(content: content, isStale: isStale)
                .font(.system(size: Tokens.TypeSize.countdownActivity, weight: .light, design: .serif).monospacedDigit())
                .foregroundStyle(ActivityPalette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            LiveRule(content: content)
            if let label = content.label {
                Text(label).pomoFont(.secondary).foregroundStyle(ActivityPalette.muted).lineLimit(1)
            }
        }
    }
}

private struct LockScreenView: View {
    var content: LiveActivityContent
    var isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            PhaseTitle(content: content)
            ActivityBody(content: content, isStale: isStale)
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .activityBackgroundTint(ActivityPalette.ground)
        .activitySystemActionForegroundColor(ActivityPalette.text)
    }
}
