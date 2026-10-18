import PomoKit
import PomoUI
import SwiftUI

struct TimerScreen: View {
    var timer: TimerViewModel
    var sync: SyncCoordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize = Tokens.TypeSize.countdown
    @FocusState private var labelFocused: Bool

    private var theme: Theme { Theme(scheme) }
    private var accent: Color { theme.accent(for: timer.countdown.kind ?? timer.effectiveKind) }

    var body: some View {
        ScrollView {
            VStack(spacing: Tokens.Spacing.xl) {
                switch timer.connection {
                case .connecting: ProgressView().padding(.top, 80)
                case let .offline(message): offline(message)
                case .online: content
                }
            }
            .padding(Tokens.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.bg)
        .onChange(of: timer.phaseName) { _, name in
            AccessibilityNotification.Announcement(name == "Completed" ? "Block completed" : name).post()
        }
    }

    // MARK: Timer

    @ViewBuilder private var content: some View {
        VStack(spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: timer.glyph.symbol).accessibilityHidden(true)
                Text(timer.phaseName).font(.system(size: Tokens.TypeSize.body, weight: .semibold))
                if let detail = timer.phaseDetail {
                    Text("· \(detail)").foregroundStyle(theme.textMuted)
                }
            }
            .foregroundStyle(accent)
            if let tag = timer.sourceTag {
                Text(tag.capitalizedFirst)
                    .font(.system(size: Tokens.TypeSize.caption))
                    .padding(.horizontal, Tokens.Spacing.s).padding(.vertical, Tokens.Spacing.xs)
                    .background(theme.surface, in: Capsule())
                    .foregroundStyle(theme.textMuted)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: timer.phaseName)

        ZStack {
            ProgressRing(progress: timer.progress, tint: accent, track: theme.hairline)
            Text(timer.display)
                .font(.system(size: countdownSize, weight: .light).monospacedDigit())
                .foregroundStyle(theme.text.opacity(timer.countdown.status == .paused ? 0.55 : 1))
                .minimumScaleFactor(0.5)
                .accessibilityLabel(timer.accessibilityTime)
        }
        .frame(width: 260, height: 260)

        labelField

        if timer.countdown.status == .idle {
            Picker("Next block", selection: Binding(get: { timer.effectiveKind }, set: { timer.kindOverride = $0 })) {
                ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if let last = timer.lastBlockSummary {
                Text(last).font(.system(size: Tokens.TypeSize.secondary)).foregroundStyle(theme.textMuted)
            }
        }

        controls

        if let error = timer.lastError {
            Text(error).font(.system(size: Tokens.TypeSize.secondary)).foregroundStyle(theme.danger)
        }
        footer
    }

    private var labelField: some View {
        TextField("What are you working on?", text: Bindable(timer).labelDraft)
            .focused($labelFocused)
            .submitLabel(.done)
            .onSubmit { Task { await timer.commitLabel() } }
            .onChange(of: labelFocused) { _, focused in if !focused { Task { await timer.commitLabel() } } }
            .padding(Tokens.Spacing.m)
            .frame(minHeight: 44)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(theme.hairline))
            .accessibilityLabel("Label")
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        VStack(spacing: Tokens.Spacing.m) {
            switch timer.countdown.status {
            case .idle:
                button("Start \(timer.effectiveKind.title.lowercased()) · \(timer.settings.minutes(for: timer.effectiveKind)) min", .primary(accent)) {
                    labelFocused = false
                    await timer.start()
                }
            case .running:
                button(timer.isFinishedLocally ? "Finishing…" : "Pause", .primary(accent)) { await timer.pause() }
                    .disabled(timer.isFinishedLocally)
            case .paused:
                button("Resume", .primary(accent)) { await timer.resume() }
            }
            if timer.isLive {
                HStack(spacing: Tokens.Spacing.m) {
                    button("+5 min", .secondary) { await timer.extend(minutes: 5) }
                    button("Skip", .secondary) { await timer.skip() }
                }
                HStack(spacing: Tokens.Spacing.m) {
                    button("Reset", .destructive) { await timer.reset() }
                    button("Stop", .destructive) { await timer.stop() }
                }
            }
        }
    }

    private func button(_ title: String, _ kind: PomoButtonStyle.Kind, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Text(title) }
            .buttonStyle(PomoButtonStyle(kind: kind, theme: theme))
    }

    // MARK: States and footer

    private func offline(_ message: String) -> some View {
        VStack(spacing: Tokens.Spacing.m) {
            Image(systemName: "exclamationmark.circle").font(.largeTitle).foregroundStyle(theme.danger)
            Text("The timer is not available").font(.headline)
            Text(message).font(.system(size: Tokens.TypeSize.secondary)).foregroundStyle(theme.textMuted)
            button("Retry", .secondary) { timer.retry() }
        }
        .padding(.top, 60)
    }

    private var footer: some View {
        VStack(spacing: Tokens.Spacing.xs) {
            Text("Today \(formatDuration(ms: timer.today.focusMs)) · \(timer.today.completedFocus) completed")
                .font(.system(size: Tokens.TypeSize.secondary))
                .foregroundStyle(theme.textMuted)
            Text(syncLine)
                .font(.system(size: Tokens.TypeSize.caption))
                .foregroundStyle(sync.lastError == nil ? theme.textMuted : theme.danger)
        }
        .padding(.top, Tokens.Spacing.s)
    }

    private var syncLine: String {
        if sync.isSyncing { return "Syncing…" }
        if let e = sync.lastError { return "Sync problem: \(e)" }
        guard let ms = sync.lastSyncMs else { return "Not synced yet" }
        return "Synced \(Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .omitted, time: .shortened))"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
