import AppKit
import PomoUI
import SwiftUI

/// Phase glyph plus `mm:ss` in the menu bar. Focus and break glyphs are coloured; idle is a template image so the
/// system tints it for the menu bar. Idle shows only the glyph; paused dims the digits.
public struct MenuBarLabel: View {
    var model: TimerViewModel

    public init(model: TimerViewModel) { self.model = model }

    public var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(nsImage: MenuBarGlyph.image(for: model.glyph))
            if !model.menuTitle.isEmpty {
                Text(model.menuTitle)
                    .monospacedDigit()
                    .opacity(model.glyph == .paused ? 0.5 : 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onChange(of: model.countdown.status) { old, new in
            guard model.isOnline else { return }
            if new == .paused { AccessibilityNotification.Announcement("Paused, \(model.accessibilityTime)").post() }
            if new == .running, old == .paused { AccessibilityNotification.Announcement("Resumed").post() }
        }
    }

    private var accessibilityText: String {
        switch model.connection {
        case .offline: return "Pomo, daemon offline"
        case .connecting: return "Pomo, connecting"
        case .online:
            guard model.isLive else { return "Pomo, idle" }
            return "Pomo, \(model.phaseName), \(model.accessibilityTime)"
        }
    }
}

/// The menu bar glyph as an image. Focus and break are drawn in their token colours for whatever appearance the
/// menu bar currently has (a drawing handler re-runs on appearance change); every other glyph is a template image.
public enum MenuBarGlyph {
    public static func image(for glyph: Glyph) -> NSImage {
        let tint: String? = switch glyph {
        case .focus: "focus"
        case .breakTime: "break"
        case .idle, .paused, .offline: nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { return NSImage() }
        guard let tint else {
            symbol.isTemplate = true
            return symbol
        }
        let size = symbol.size
        let image = NSImage(size: size, flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color = NSColor(Tokens.color(tint, isDark ? .dark : .light))
            guard let coloured = symbol.withSymbolConfiguration(config.applying(.init(paletteColors: [color]))) else { return false }
            coloured.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }
}
