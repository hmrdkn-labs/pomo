import ActivityKit
import PomoLive
import PomoUI
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island presentation of the running block. Running countdowns are drawn by the system
/// from absolute dates (`Text(timerInterval:)`, `ProgressView(timerInterval:)`), so they tick without the app.
struct BlockLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PomoActivityAttributes.self) { context in
            LockScreenView(content: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            let c = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(c.phaseName, systemImage: glyph(c)).font(.headline).foregroundStyle(accent(c))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(content: c, isStale: context.isStale).font(.title2.monospacedDigit()).frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    if let label = c.label { Text(label).lineLimit(1) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CountdownBar(content: c).tint(accent(c))
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
    c.paused ? "pause.fill" : (c.kind.isBreak ? "cup.and.saucer.fill" : "circle.fill")
}

private func accent(_ c: LiveActivityContent, scheme: ColorScheme = .dark) -> Color {
    Theme(scheme).accent(for: c.kind)
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

private struct CountdownBar: View {
    var content: LiveActivityContent

    var body: some View {
        if content.paused {
            ProgressView(value: content.progress(at: 0))
        } else {
            ProgressView(timerInterval: content.interval, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
        }
    }
}

private struct LockScreenView: View {
    var content: LiveActivityContent
    var isStale: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        let tint = theme.accent(for: content.kind)
        HStack(spacing: Tokens.Spacing.l) {
            ZStack {
                if content.paused {
                    ProgressView(value: content.progress(at: 0))
                        .progressViewStyle(.circular)
                } else {
                    ProgressView(timerInterval: content.interval, countsDown: false) { EmptyView() } currentValueLabel: {
                        Image(systemName: glyph(content)).foregroundStyle(tint)
                    }
                    .progressViewStyle(.circular)
                }
            }
            .tint(tint)
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(content.phaseName).font(.system(size: Tokens.TypeSize.secondary, weight: .semibold)).foregroundStyle(tint)
                CountdownText(content: content, isStale: isStale)
                    .font(.system(size: 34, weight: .light).monospacedDigit())
                if let label = content.label {
                    Text(label).font(.system(size: Tokens.TypeSize.secondary)).foregroundStyle(theme.textMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Spacing.l)
        .foregroundStyle(theme.text)
        .activityBackgroundTint(theme.bg)
        .activitySystemActionForegroundColor(theme.text)
    }
}
