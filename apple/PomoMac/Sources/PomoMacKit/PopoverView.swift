import AppKit
import PomoUI
import SwiftUI

/// The menu bar popover: phase line, serif countdown, rule, label, one primary action, a row of quiet actions,
/// and today's total. Width 300, padding 20.
public struct PopoverView: View {
    var env: AppEnvironment
    @Environment(\.pomoTheme) private var theme
    @Environment(\.openWindow) private var openWindow

    public init(env: AppEnvironment) { self.env = env }

    private var model: TimerViewModel { env.timer }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            switch model.connection {
            case .online: timerBody
            case .connecting: connecting
            case let .offline(message): offline(message)
            }
            footer
        }
        .padding(Tokens.Spacing.popoverPadding)
        .frame(width: 300)
        .background(theme.paperRaised)
        .foregroundStyle(theme.ink)
    }

    // MARK: Timer

    private var phaseTint: Color { theme.phaseTint(model.countdown) }

    private var timerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            PhaseLine(
                glyph: model.glyph,
                title: model.phaseName,
                detail: model.phaseDetail,
                byline: model.sourceByline,
                tint: phaseTint,
                bylineIdentifier: "popover.source"
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(phaseAccessibility)

            CountdownNumerals(
                countdownText, style: .popover, color: countdownColor,
                spokenLabel: model.isLive ? model.accessibilityTime : "\(model.settings.minutes(for: model.effectiveKind)) minutes",
                identifier: "popover.countdown"
            )
            .padding(.top, Tokens.Spacing.xs)

            ProgressRule(countdown: model.countdown, tint: phaseTint, height: Tokens.Rule.heightPopover)
                .padding(.top, Tokens.Spacing.m)

            TextField("What are you working on?", text: Binding(get: { model.labelDraft }, set: { model.labelDraft = $0 }))
                .pomoFont(.body)
                .underlineField()
                .onSubmit { Task { await model.commitLabel() } }
                .accessibilityLabel("Label")
                .padding(.top, Tokens.Spacing.l)

            controls
                .padding(.top, Tokens.Spacing.l)

            if let e = model.lastError {
                Text(e).pomoFont(.secondary).foregroundStyle(theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Tokens.Spacing.s)
            }
        }
    }

    private var countdownText: String {
        model.isLive ? model.display : Countdown.format(remainingMs: model.settings.plannedMs(for: model.effectiveKind))
    }

    private var countdownColor: Color {
        model.countdown.status == .paused ? theme.inkMuted : theme.ink
    }

    private var phaseAccessibility: String {
        guard model.isLive else { return "Ready, \(model.effectiveKind.title)" }
        let base = "\(model.phaseName), \(model.accessibilityTime)"
        return model.sourceTag.map { "\(base), \($0)" } ?? base
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: Tokens.Spacing.m) {
            if model.isLive {
                let paused = model.countdown.status == .paused
                Button {
                    Task { await model.togglePause() }
                } label: {
                    Text(paused ? "Resume" : "Pause")
                }
                .buttonStyle(PomoPrimaryButtonStyle(tone: .ink, height: 44))
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(paused ? "Resume" : "Pause")

                HStack(spacing: 0) {
                    quietButton("hourglass.badge.plus", "+5", "Add 5 minutes") { await model.extend() }
                    quietButton("forward.end", "Skip", "Skip") { await model.skip() }
                    quietButton("arrow.counterclockwise", "Reset", "Reset", muted: true) { await model.reset() }
                    quietButton("stop", "Stop", "Stop", muted: true) { await model.stop() }
                }
            } else {
                Picker("Block kind", selection: Binding(get: { model.effectiveKind }, set: { model.kindOverride = $0 })) {
                    ForEach(Kind.allCases, id: \.self) { Text(Self.pickerTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel("Block kind")

                Button {
                    Task { await model.start() }
                } label: {
                    Text("Start \(model.effectiveKind.title.lowercased()) · \(model.settings.minutes(for: model.effectiveKind)) min")
                }
                .buttonStyle(PomoPrimaryButtonStyle(tone: model.effectiveKind == .focus ? .focus : .ink, height: 44))
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Start \(model.effectiveKind.title)")
            }
        }
    }

    static func pickerTitle(_ kind: Kind) -> String {
        switch kind {
        case .focus: "Focus"
        case .shortBreak: "Short"
        case .longBreak: "Long"
        }
    }

    private func quietButton(_ symbol: String, _ title: String, _ label: String, muted: Bool = false, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: symbol).imageScale(.small)
                Text(title)
            }
        }
        .buttonStyle(PomoSecondaryButtonStyle(muted: muted))
        .accessibilityLabel(label)
        .help(label)
    }

    // MARK: Connection states

    private var connecting: some View {
        VStack(spacing: Tokens.Spacing.m) {
            ProgressView().controlSize(.small)
            Text("Connecting to the Pomo daemon…").pomoFont(.secondary).foregroundStyle(theme.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private func offline(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            PhaseLine(glyph: .offline, title: "Offline", tint: theme.danger)
            Text("The Pomo daemon is not running")
                .pomoFont(.body, weight: .semibold)
            Text(message)
                .pomoFont(.secondary).foregroundStyle(theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.retry() } label: { Text("Retry") }
                .buttonStyle(PomoPrimaryButtonStyle(tone: .ink, height: 44))
                .accessibilityLabel("Retry connecting to the daemon")
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Hairline()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                        Text("Today").pomoFont(.secondary).foregroundStyle(theme.inkMuted)
                        Text(model.isOnline ? formatDuration(ms: model.today.focusMs) : "—")
                            .pomoFont(.numeral).foregroundStyle(theme.ink)
                    }
                    if model.isOnline, let last = model.lastBlockSummary {
                        Text(last).pomoFont(.secondary).foregroundStyle(theme.inkMuted)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer()
                HStack(spacing: Tokens.Spacing.xs) {
                    footerButton("chart.bar", "Statistics") { open("stats") }
                    footerButton("gearshape", "Settings") { open("settings") }
                    footerButton("power", "Quit Pomo") { NSApplication.shared.terminate(nil) }
                }
            }
        }
    }

    private func footerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(theme.ink).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
