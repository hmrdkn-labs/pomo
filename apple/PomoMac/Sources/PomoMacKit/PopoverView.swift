import AppKit
import PomoUI
import SwiftUI

struct PomoButtonStyle: ButtonStyle {
    enum Kind { case primary(Color), secondary, destructive }
    var kind: Kind
    var theme: Theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let (fg, bg): (Color, Color) = switch kind {
        case let .primary(tint): (theme.scheme == .dark ? Color.black : Color.white, tint)
        case .secondary: (theme.text, theme.surface)
        case .destructive: (theme.danger, theme.surface)
        }
        configuration.label
            .font(.system(size: Tokens.TypeSize.body, weight: .medium))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(bg.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(theme.hairline))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
    }
}

public struct PopoverView: View {
    var env: AppEnvironment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(env: AppEnvironment) { self.env = env }

    private var model: TimerViewModel { env.timer }
    private var theme: Theme { Theme(scheme) }

    public var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            switch model.connection {
            case .online: timerBody
            case .connecting: connecting
            case let .offline(message): offline(message)
            }
            footer
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 280)
        .background(theme.bg)
        .foregroundStyle(theme.text)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.glyph)
    }

    // MARK: Timer

    private var accent: Color { theme.accent(for: model.countdown.kind ?? model.effectiveKind) }

    private var timerBody: some View {
        VStack(spacing: Tokens.Spacing.m) {
            ZStack {
                ProgressRing(progress: model.progress, tint: accent, track: theme.hairline)
                VStack(spacing: Tokens.Spacing.xs) {
                    Text(model.isLive ? model.display : Countdown.format(remainingMs: model.settings.plannedMs(for: model.effectiveKind)))
                        .font(.system(size: Tokens.TypeSize.countdown, weight: .light).monospacedDigit())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .opacity(model.countdown.status == .paused ? 0.55 : 1)
                    HStack(spacing: Tokens.Spacing.xs) {
                        Image(systemName: model.glyph.symbol).imageScale(.small).foregroundStyle(accent)
                        Text(model.isLive ? model.phaseName : model.effectiveKind.title)
                        if let d = model.phaseDetail { Text("· \(d)") }
                    }
                    .font(.system(size: Tokens.TypeSize.secondary))
                    .foregroundStyle(theme.textMuted)
                }
                .padding(.horizontal, Tokens.Spacing.xl)
            }
            .frame(width: 208, height: 208)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.isLive ? "\(model.phaseName), \(model.accessibilityTime)" : "Ready, \(model.effectiveKind.title)")

            if let tag = model.sourceTag {
                Label(tag.prefix(1).uppercased() + tag.dropFirst(), systemImage: "sparkles")
                    .font(.system(size: Tokens.TypeSize.caption))
                    .foregroundStyle(theme.textMuted)
                    .padding(.horizontal, Tokens.Spacing.s).padding(.vertical, Tokens.Spacing.xs)
                    .background(theme.surface, in: Capsule())
                    .overlay(Capsule().stroke(theme.hairline))
                    .accessibilityLabel("Source: \(tag)")
            }

            TextField("What are you working on?", text: Binding(get: { model.labelDraft }, set: { model.labelDraft = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: Tokens.TypeSize.body))
                .padding(.horizontal, Tokens.Spacing.m).frame(height: 32)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(theme.hairline))
                .onSubmit { Task { await model.commitLabel() } }
                .accessibilityLabel("Label")

            controls

            if let e = model.lastError {
                Text(e).font(.system(size: Tokens.TypeSize.caption)).foregroundStyle(theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if model.isLive {
            Button {
                Task { await model.togglePause() }
            } label: {
                Label(model.countdown.status == .paused ? "Resume" : "Pause",
                      systemImage: model.countdown.status == .paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(PomoButtonStyle(kind: .primary(accent), theme: theme))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(model.countdown.status == .paused ? "Resume" : "Pause")

            HStack(spacing: Tokens.Spacing.s) {
                iconButton("plus", "+5", "Add 5 minutes") { await model.extend() }
                iconButton("forward.end.fill", nil, "Skip") { await model.skip() }
                iconButton("arrow.counterclockwise", nil, "Reset", destructive: true) { await model.reset() }
                iconButton("stop.fill", nil, "Stop", destructive: true) { await model.stop() }
            }
        } else {
            Picker("Block kind", selection: Binding(get: { model.effectiveKind }, set: { model.kindOverride = $0 })) {
                ForEach(Kind.allCases, id: \.self) { Text($0.title == "Short break" ? "Short" : $0 == .longBreak ? "Long" : "Focus").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel("Block kind")

            Button {
                Task { await model.start() }
            } label: {
                Label("Start \(model.effectiveKind.title.lowercased()) · \(model.settings.minutes(for: model.effectiveKind)) min", systemImage: "play.fill")
            }
            .buttonStyle(PomoButtonStyle(kind: .primary(accent), theme: theme))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Start \(model.effectiveKind.title)")
        }
    }

    private func iconButton(_ symbol: String, _ text: String?, _ label: String, destructive: Bool = false, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: symbol)
                if let text { Text(text).font(.system(size: Tokens.TypeSize.secondary, weight: .medium)) }
            }
        }
        .buttonStyle(PomoButtonStyle(kind: destructive ? .destructive : .secondary, theme: theme))
        .accessibilityLabel(label)
        .help(label)
    }

    // MARK: Connection states

    private var connecting: some View {
        VStack(spacing: Tokens.Spacing.m) {
            ProgressView().controlSize(.small)
            Text("Connecting to the Pomo daemon…").font(.system(size: Tokens.TypeSize.secondary)).foregroundStyle(theme.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private func offline(_ message: String) -> some View {
        VStack(spacing: Tokens.Spacing.m) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 32)).foregroundStyle(theme.danger)
            Text("Daemon offline").font(.system(size: Tokens.TypeSize.body, weight: .semibold))
            Text(message)
                .font(.system(size: Tokens.TypeSize.secondary)).foregroundStyle(theme.textMuted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button { model.retry() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .buttonStyle(PomoButtonStyle(kind: .primary(theme.focus), theme: theme))
                .accessibilityLabel("Retry connecting to the daemon")
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: Tokens.Spacing.s) {
            Rectangle().fill(theme.hairline).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isOnline ? "Today \(formatDuration(ms: model.today.focusMs))" : "Today —")
                        .font(.system(size: Tokens.TypeSize.secondary, weight: .medium))
                    if model.isOnline, let last = model.lastBlockSummary {
                        Text(last).font(.system(size: Tokens.TypeSize.caption)).foregroundStyle(theme.textMuted)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer()
                footerButton("chart.bar", "Statistics") { open("stats") }
                footerButton("gearshape", "Settings") { open("settings") }
                footerButton("power", "Quit Pomo") { NSApplication.shared.terminate(nil) }
            }
            .foregroundStyle(theme.textMuted)
        }
    }

    private func footerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .help(label)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
