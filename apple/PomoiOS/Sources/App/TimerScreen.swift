import PomoKit
import PomoUI
import SwiftUI

/// The Timer: phase line at the top margin, the serif countdown about a third of the way down, the rule, the label,
/// one primary action and four quiet text buttons.
struct TimerScreen: View {
    var timer: TimerViewModel
    var sync: SyncCoordinator
    @Environment(\.pomoTheme) private var theme
    @FocusState private var labelFocused: Bool

    private var tint: Color { theme.phaseTint(timer.countdown) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch timer.connection {
                case .connecting: ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                case let .offline(message): offline(message)
                case .online: content
                }
            }
            .padding(.horizontal, Tokens.Spacing.phoneMargin)
            .padding(.top, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.paper.ignoresSafeArea())
        .onChange(of: timer.phaseName) { _, name in
            AccessibilityNotification.Announcement(name == "Completed" ? "Block completed" : name).post()
        }
    }

    // MARK: Timer

    @ViewBuilder private var content: some View {
        PhaseLine(
            glyph: timer.glyph, title: timer.phaseName, detail: timer.phaseDetail,
            byline: timer.sourceTag.map { String($0.prefix(1).uppercased() + $0.dropFirst()) }, tint: tint,
            titleIdentifier: "timer.phase", bylineIdentifier: "timer.source"
        )

        // Puts the numerals about a third of the way down the screen.
        Color.clear.frame(height: 0).containerRelativeFrame(.vertical) { length, _ in length * 0.14 }

        CountdownNumerals(
            countdownText, style: .phone, color: timer.countdown.status == .paused ? theme.inkMuted : theme.ink,
            spokenLabel: timer.accessibilityTime, identifier: "timer.countdown")

        ProgressRule(countdown: timer.countdown, tint: tint, height: Tokens.Rule.heightPhone)
            .padding(.top, Tokens.Spacing.m)

        labelField
            .padding(.top, Tokens.Spacing.xl)

        if timer.countdown.status == .idle {
            Picker("Next block", selection: Binding(get: { timer.effectiveKind }, set: { timer.kindOverride = $0 })) {
                ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.top, Tokens.Spacing.l)
            if let last = timer.lastBlockSummary {
                Text(last).pomoFont(.secondary).foregroundStyle(theme.inkMuted)
                    .padding(.top, Tokens.Spacing.s)
            }
        }

        controls
            .padding(.top, Tokens.Spacing.l)

        if let error = timer.lastError {
            Text(error).pomoFont(.secondary).foregroundStyle(theme.danger)
                .padding(.top, Tokens.Spacing.m)
        }
        footer
            .padding(.top, Tokens.Spacing.xl)
    }

    /// Live: the remaining time. Idle: the length the next block will have.
    private var countdownText: String {
        timer.isLive ? timer.display : Countdown.format(remainingMs: timer.settings.plannedMs(for: timer.effectiveKind))
    }

    private var labelField: some View {
        TextField("What are you working on?", text: Bindable(timer).labelDraft)
            .focused($labelFocused)
            .submitLabel(.done)
            .onSubmit { Task { await timer.commitLabel() } }
            .onChange(of: labelFocused) { _, focused in if !focused { Task { await timer.commitLabel() } } }
            .pomoFont(.body)
            .underlineField()
            .frame(minHeight: 44)
            .accessibilityLabel("Label")
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        VStack(spacing: Tokens.Spacing.m) {
            switch timer.countdown.status {
            case .idle:
                primary(
                    "Start \(timer.effectiveKind.title.lowercased()) · \(timer.settings.minutes(for: timer.effectiveKind)) min",
                    timer.effectiveKind == .focus ? .focus : .ink
                ) {
                    labelFocused = false
                    await timer.start()
                }
            case .running:
                primary(timer.isFinishedLocally ? "Finishing…" : "Pause", .ink) { await timer.pause() }
                    .disabled(timer.isFinishedLocally)
            case .paused:
                primary("Resume", .ink) { await timer.resume() }
            }
            if timer.isLive {
                HStack(spacing: 0) {
                    quiet("+5 min") { await timer.extend(minutes: 5) }
                    quiet("Skip") { await timer.skip() }
                    quiet("Reset", muted: true) { await timer.reset() }
                    quiet("Stop", muted: true) { await timer.stop() }
                }
            }
        }
    }

    private func primary(_ title: String, _ tone: PomoPrimaryButtonStyle.Tone, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Text(title) }
            .buttonStyle(PomoPrimaryButtonStyle(tone: tone, height: 52))
    }

    private func quiet(_ title: String, muted: Bool = false, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Text(title) }
            .buttonStyle(PomoSecondaryButtonStyle(muted: muted, minHeight: 44))
    }

    // MARK: States and footer

    private func offline(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            PhaseLine(glyph: .offline, title: "Offline", tint: theme.danger)
            Text("The timer is not available").pomoFont(.body, weight: .semibold)
            Text(message).pomoFont(.secondary).foregroundStyle(theme.inkMuted)
            primary("Retry", .ink) { timer.retry() }
        }
        .padding(.top, Tokens.Spacing.xxl)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Hairline().padding(.bottom, Tokens.Spacing.s)
            // One line when it fits; at the largest Dynamic Type sizes the completed count drops to its own line.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                    todayTotal
                    completedCount(prefix: "· ").fixedSize()
                }
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    todayTotal
                    completedCount(prefix: "")
                }
            }
            .accessibilityElement(children: .combine)
            Text(syncLine)
                .pomoFont(.secondary)
                .foregroundStyle(sync.lastError == nil ? theme.inkMuted : theme.danger)
        }
    }

    private var todayTotal: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Text("Today").pomoFont(.secondary).foregroundStyle(theme.inkMuted)
            Text(formatDuration(ms: timer.today.focusMs)).pomoFont(.numeral).foregroundStyle(theme.ink)
        }
        .fixedSize()
    }

    private func completedCount(prefix: String) -> some View {
        Text("\(prefix)\(timer.today.completedFocus) completed").pomoFont(.secondary).foregroundStyle(theme.inkMuted)
    }

    private var syncLine: String {
        if sync.isSyncing { return "Syncing…" }
        if let e = sync.lastError { return "Sync problem: \(e)" }
        guard let ms = sync.lastSyncMs else { return "Not synced yet" }
        return "Synced \(Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .omitted, time: .shortened))"
    }
}
