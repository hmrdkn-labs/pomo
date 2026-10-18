import AppKit
import PomoUI
import Testing
@testable import PomoMacKit

@MainActor
@Suite struct MenuBarGlyphTests {
    /// The colour of the most opaque pixel of `image` drawn under the light or dark appearance, 0...255.
    private func solid(of image: NSImage, dark: Bool) throws -> (r: Int, g: Int, b: Int, a: Int) {
        let px = 40
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        }
        NSGraphicsContext.restoreGraphicsState()
        var best: NSColor?
        for y in 0..<px {
            for x in 0..<px {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.alphaComponent > (best?.alphaComponent ?? 0) { best = c }
            }
        }
        var channels = [CGFloat](repeating: 0, count: 4)
        try #require(best).getComponents(&channels)
        return (Int((channels[0] * 255).rounded()), Int((channels[1] * 255).rounded()),
                Int((channels[2] * 255).rounded()), Int((channels[3] * 255).rounded()))
    }

    private func token(_ name: String, dark: Bool) throws -> (r: Int, g: Int, b: Int) {
        let hex = try #require(Tokens.colors[name].map { dark ? $0.dark : $0.light })
        let c = try #require(Tokens.rgba(hex: hex))
        return (Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    @Test func idleAndPausedAreTemplateImagesSoTheSystemTintsThem() {
        for glyph in [Glyph.idle, .paused, .offline] {
            #expect(MenuBarGlyph.image(for: glyph).isTemplate, "\(glyph)")
        }
    }

    @Test(arguments: [false, true]) func focusAndBreakKeepTheirTokenColourInBothAppearances(dark: Bool) throws {
        for (glyph, name) in [(Glyph.focus, "focus"), (.breakTime, "break")] {
            let image = MenuBarGlyph.image(for: glyph)
            #expect(!image.isTemplate, "a template image would be flattened to the menu bar's colour")
            let want = try token(name, dark: dark)
            let got = try solid(of: image, dark: dark)
            #expect(got.a > 250, "\(name) draws solid pixels")
            #expect(abs(got.r - want.r) <= 6 && abs(got.g - want.g) <= 6 && abs(got.b - want.b) <= 6,
                    "\(name) \(dark ? "dark" : "light"): got \(got), want \(want)")
        }
    }
}
