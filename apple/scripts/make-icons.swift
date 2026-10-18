#!/usr/bin/env swift
// Draws the Pomo app icon (paper ground, a vermilion disc, an ink rule beneath it) with CoreGraphics and writes:
//   apple/PomoiOS/Sources/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png   (full bleed, no alpha)
//   apple/PomoMac/Resources/AppIcon.icns                                          (rounded square, via iconutil)
// Colours are the light tokens of spec/tokens.json. Run from anywhere:  swift apple/scripts/make-icons.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func hex(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: srgb, components: [r / 255, g / 255, b / 255, 1])!
}
let paper = hex(0xF5, 0xF0, 0xE6)
let focus = hex(0xD6, 0x3A, 0x22)
let ink = hex(0x1B, 0x16, 0x13)

/// Draws on a 1024-unit canvas scaled to `pixels`. `mac` insets a rounded square on transparent ground.
func render(pixels: Int, mac: Bool) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    if mac {
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.setFillColor(paper)
        ctx.fillPath()
    } else {
        ctx.setFillColor(paper)
        ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }

    // Mark: disc 400 across, 64 gap, rule 560 x 36 with square ends; centred as a group.
    let scale: CGFloat = mac ? 0.8 : 1
    func mapped(_ r: CGRect) -> CGRect {
        CGRect(x: 512 + (r.minX - 512) * scale, y: 512 + (r.minY - 512) * scale, width: r.width * scale, height: r.height * scale)
    }
    let rule = mapped(CGRect(x: 232, y: 262, width: 560, height: 36))
    let disc = mapped(CGRect(x: 312, y: 362, width: 400, height: 400))
    ctx.setFillColor(ink)
    ctx.fill(rule)
    ctx.setFillColor(focus)
    ctx.fillEllipse(in: disc)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icons", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "icons", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot finalize \(url.path)"])
    }
}

let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default

// iOS
let ios = apple.appendingPathComponent("PomoiOS/Sources/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
try writePNG(render(pixels: 1024, mac: false), to: ios)
print("wrote", ios.path)

// macOS: iconset -> icns
let resources = apple.appendingPathComponent("PomoMac/Resources")
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
let tmp = fm.temporaryDirectory.appendingPathComponent("pomo-icons-\(UUID().uuidString)")
let iconset = tmp.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }
for base in [16, 32, 128, 256, 512] {
    try writePNG(render(pixels: base, mac: true), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(render(pixels: base * 2, mac: true), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let icns = resources.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote", icns.path)
