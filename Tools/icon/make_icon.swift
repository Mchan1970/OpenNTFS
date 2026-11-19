// OpenNTFS app icon generator: an original drawing (no SF Symbols, no
// third-party artwork), rendered offline with CoreGraphics.
//   swift Tools/icon/make_icon.swift <out.png> [pixels]   (default 1024)
// Layout follows the macOS icon grid: an 824x824 rounded-square body centred
// in a 1024x1024 canvas (100 px margin), with a soft drop shadow.
// Motif: "NTFS" lettering above a generic external drive. Deliberately not a
// replica of any Apple hardware (HIG / trademark guidance).
// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: make_icon.swift <out.png> [pixels]\n".data(using: .utf8)!)
    exit(64)
}
let outPath = args[1]
let px = args.count >= 3 ? Int(args[2]) ?? 1024 : 1024
let s = CGFloat(px) / 1024.0            // design units are 1024-based

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("cannot create context")
}
ctx.scaleBy(x: s, y: s)
// Flip so that y grows downward (easier to reason about in design units).
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
}
func roundRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// ---- body: rounded square with a blue vertical gradient and drop shadow
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = roundRect(body, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.30))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x2F6FE0)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x4FA3FF), rgb(0x2C6BE0), rgb(0x1B4FB8)]),
                       start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// subtle top sheen
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0.0)]),
                       start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 470), options: [])
ctx.restoreGState()

// ---- "NTFS" lettering (upper half), drawn as round-capped strokes so no
// font is embedded (system fonts are not licensed for app icon artwork).
func letters() {
    let w: CGFloat = 40                     // stroke width
    let top: CGFloat = 262, bot: CGFloat = 438   // cap height 176
    let gap: CGFloat = 66, lw: CGFloat = 96      // gap > stroke width, so letters never touch
    let total = 4 * lw + 3 * gap
    var x = (1024 - total) / 2
    let p = CGMutablePath()
    // N
    p.move(to: CGPoint(x: x, y: bot)); p.addLine(to: CGPoint(x: x, y: top))
    p.addLine(to: CGPoint(x: x + lw, y: bot)); p.addLine(to: CGPoint(x: x + lw, y: top))
    x += lw + gap
    // T
    p.move(to: CGPoint(x: x, y: top)); p.addLine(to: CGPoint(x: x + lw, y: top))
    p.move(to: CGPoint(x: x + lw / 2, y: top)); p.addLine(to: CGPoint(x: x + lw / 2, y: bot))
    x += lw + gap
    // F
    p.move(to: CGPoint(x: x + lw, y: top)); p.addLine(to: CGPoint(x: x, y: top))
    p.addLine(to: CGPoint(x: x, y: bot))
    p.move(to: CGPoint(x: x, y: (top + bot) / 2)); p.addLine(to: CGPoint(x: x + lw * 0.8, y: (top + bot) / 2))
    x += lw + gap
    // S: two stacked half-loops joined by a diagonal-free spine
    let r = (bot - top) / 4                  // radius of each bowl
    let cx = x + lw / 2
    p.move(to: CGPoint(x: x + lw, y: top))
    p.addLine(to: CGPoint(x: cx, y: top))
    p.addArc(center: CGPoint(x: cx, y: top + r), radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
    p.addArc(center: CGPoint(x: cx, y: bot - r), radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
    p.addLine(to: CGPoint(x: x, y: bot))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 10, color: rgb(0x0A2A6B, 0.35))
    ctx.addPath(p)
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(w)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}
letters()

// ---- external drive (lower half)
let drive = CGRect(x: 220, y: 540, width: 584, height: 250)
let drivePath = roundRect(drive, 56)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 26, color: rgb(0x061B4A, 0.45))
ctx.addPath(drivePath); ctx.setFillColor(rgb(0xE9EDF3)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(drivePath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFBFCFE), rgb(0xE3E8F0), rgb(0xC9D1DD)]),
                       start: CGPoint(x: 512, y: 540), end: CGPoint(x: 512, y: 790), options: [])
// front face divider: the lower band reads as the drive's front edge
ctx.setFillColor(rgb(0xB7C1D0)); ctx.fill(CGRect(x: 220, y: 700, width: 584, height: 4))
ctx.drawLinearGradient(gradient([rgb(0xD5DCE6), rgb(0xBCC6D4)]),
                       start: CGPoint(x: 512, y: 704), end: CGPoint(x: 512, y: 790), options: [])
ctx.restoreGState()
// outline
ctx.addPath(drivePath); ctx.setStrokeColor(rgb(0x8E9BAE, 0.55)); ctx.setLineWidth(3); ctx.strokePath()
// activity LED (green) with a glow
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: rgb(0x34E27A, 0.9))
ctx.addEllipse(in: CGRect(x: 704, y: 731, width: 34, height: 34)); ctx.setFillColor(rgb(0x2FD26E)); ctx.fillPath()
ctx.restoreGState()
// vent slots on the front band
ctx.setFillColor(rgb(0x98A4B6))
for i in 0..<5 {
    let x = 290 + CGFloat(i) * 46
    ctx.addPath(roundRect(CGRect(x: x, y: 737, width: 26, height: 22), 6)); ctx.fillPath()
}

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    fatalError("cannot create image destination for \(outPath)")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(outPath)") }
print("wrote \(outPath) (\(px)x\(px))")
