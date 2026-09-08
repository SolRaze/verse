// Regenerates the app icon. Not part of any target — run it by hand:
//
//   swiftc Tools/makeicon.swift -o /tmp/makeicon && /tmp/makeicon vinyl \
//     Assets/Assets.xcassets/AppIcon.appiconset/icon1024.png
//
// Monotone by rule: no gradients anywhere in this project, which is also why the CD style is
// unused — a CD without its iridescent sheen is just a disc.
import AppKit

_ = NSApplication.shared          // AppKit needs an app instance before NSImage/drawing works

let style = CommandLine.arguments[1]        // "vinyl" | "cd" | "yandhi" | "yeezus"
let path = CommandLine.arguments[2]
let size = 1024.0

// "yandhi" — alternate icon after Reference/icon2.jpg (light MiniDisc): pale plate, pastel
//   rainbow at that cover's angles, purple tape, silver hub. Posterised like the default.
// "yeezus" — the default posterised drawing with the stops colour-corrected closer to
//   Reference/icon.jpg. Same dark plate, same hard bands — a smooth-gradient version was
//   drawn once and rejected (2026-07-19): posterised IS the icon's look.
let yandhi = style == "yandhi"
let yeezus = style == "yeezus"

// Explicit opaque bitmap: lockFocus() honours the Retina backing scale (silently yielding 2048
// with alpha) and traps with no window context. 3 samples at 32bpp maps to alphaNoneSkipLast —
// CoreGraphics can't back a 24bpp context, and this still encodes PNG with no alpha.
guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { fatalError("no bitmap") }
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let plate = NSColor(calibratedWhite: yandhi ? 0.92 : 0.11, alpha: 1)
let ink = NSColor.white
let c = NSPoint(x: size / 2, y: size / 2)

func circle(_ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

/// How strongly the sheen shows at `ang`, peaking at `around` and falling to 0 by `width`.
/// Wraps across 0/360.
func sheen(_ ang: Double, around: Double, width: Double = 62) -> Double {
    var d = abs(ang - around).truncatingRemainder(dividingBy: 360)
    if d > 180 { d = 360 - d }
    let t = d / width
    return t >= 1 ? 0 : 1 - t * t
}

plate.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
ink.setFill()
circle(360).fill()

if style == "vinyl" {
    // Grooves: plate-coloured rings cut into the disc. Bold and widely spaced on purpose —
    // finer than this mushes into grey at 60pt on the home screen.
    var r: CGFloat = 170
    while r <= 330 {
        let g = circle(r)
        g.lineWidth = 7
        NSColor(calibratedWhite: 0.11, alpha: 0.6).setStroke()
        g.stroke()
        r += 40
    }
    plate.setFill()
    circle(112).fill()      // centre label
    ink.setFill()
    circle(16).fill()       // spindle hole
} else {
    // Iridescent sheen — the project's ONE sanctioned gradient, icon only. The no-gradient rule
    // governs UI chrome (.tint(.white), no colored chrome); nothing in the app draws like this.
    // A CD without its sheen is an anonymous disc, which is why the flat version was rejected.
    //
    // Conic sweep built from wedges by hand: CGGradient does axial and radial only, so there is
    // no conic primitive to reach for. Held below full saturation so it still reads as a disc
    // rather than a pinwheel. FLAT=1 renders the ridge-less monotone disc instead.
    if ProcessInfo.processInfo.environment["FLAT"] == nil {
        // Sheen matched to reference.jpg: the disc is DARK, near-black through the top and
        // bottom, with vivid iridescence blazing through the left and right sectors. A pale
        // silver disc with pastel arcs is the opposite of how a lit CD actually photographs.
        NSGraphicsContext.saveGraphicsState()
        circle(360).addClip()

        // Colour stops sampled off Reference/icon.jpg, at the REFERENCE'S OWN angles
        // (0° = 3 o'clock, counter-clockwise, matching the drawing's coordinate space):
        // dark top and right (the tape sits on the dark sector), dark-green -> green -> pale
        // silver sweeping the upper-left, pink -> cream through the lower-left, warm yellow at
        // the bottom, orange -> magenta -> violet climbing the lower-right. Nearest-stop pick,
        // no interpolation — the posterised hard-edged bands stay; dark radial divisions still
        // cut through so it doesn't collapse into a pie chart.
        let dark: [(ang: Double, h: CGFloat, s: CGFloat, b: CGFloat)] = [
            (10, 0, 0, 0.12),               // right: unlit, under the tape
            (50, 0.20, 0.50, 0.25),         // upper-right: dark olive-bronze
            (90, 0, 0, 0.12),               // top: unlit
            (130, 0.33, 0.70, 0.35),        // dark green
            (155, 0.35, 0.65, 0.62),        // green
            (175, 0.42, 0.18, 0.88),        // pale silver-teal (the lit left edge)
            (195, 0.85, 0.15, 0.85),        // pale lavender
            (220, 0.93, 0.30, 0.80),        // pink
            (250, 0.13, 0.35, 0.90),        // cream
            (270, 0.12, 0.50, 0.85),        // bottom: warm yellow
            (290, 0.08, 0.55, 0.60),        // orange-tan
            (310, 0.88, 0.60, 0.55),        // magenta
            (330, 0.78, 0.65, 0.40),        // violet
            (350, 0.83, 0.60, 0.22),        // dark maroon-violet fading into the tape
        ]
        // Reference/icon2.jpg: bright pastel rainbow on a silver disc.
        let pale: [(ang: Double, h: CGFloat, s: CGFloat, b: CGFloat)] = [
            (10, 0.90, 0.25, 0.85),         // right, under the tape: pale pink
            (50, 0.35, 0.30, 0.80),         // pastel green
            (90, 0.14, 0.45, 0.95),         // top: bright yellow
            (120, 0.08, 0.55, 0.90),        // orange
            (145, 0.95, 0.45, 0.85),        // pink
            (175, 0.45, 0.50, 0.75),        // teal
            (200, 0, 0, 0.45),              // the dark grey band on the left
            (225, 0.90, 0.40, 0.70),        // mauve
            (255, 0.98, 0.60, 0.80),        // red-pink
            (275, 0.60, 0.45, 0.75),        // blue
            (305, 0.40, 0.50, 0.80),        // green-cyan
            (330, 0.55, 0.45, 0.80),        // blue
            (350, 0.85, 0.35, 0.80),        // pink-violet fading into the tape
        ]
        // Yeezus: the same bands, a few values pulled closer to the photo — oliver greens,
        // brighter lit left edge, salmon instead of pink, pinker magenta.
        let refined: [(ang: Double, h: CGFloat, s: CGFloat, b: CGFloat)] = [
            (10, 0, 0, 0.12),
            (50, 0.17, 0.50, 0.28),         // bronze-olive
            (90, 0, 0, 0.12),
            (130, 0.30, 0.60, 0.35),        // olive-green
            (155, 0.33, 0.60, 0.58),
            (175, 0.42, 0.15, 0.92),        // brighter silver edge
            (195, 0.85, 0.15, 0.85),
            (220, 0.96, 0.40, 0.80),        // salmon
            (250, 0.12, 0.40, 0.90),
            (270, 0.12, 0.55, 0.85),
            (290, 0.08, 0.55, 0.55),
            (310, 0.91, 0.55, 0.58),        // pinker magenta
            (330, 0.78, 0.65, 0.40),
            (350, 0.86, 0.60, 0.22),
        ]
        // Pastel remap (2026-07-21 user request, YEEZUS ONLY): coloured stops soften toward
        // yandhi's palette — saturation down, brightness up — while unlit (s == 0) sectors and
        // the spokes stay dark. Classic keeps the original dark stops (pastelising both made
        // Verse and Yeezus identical — reverted same day).
        func pastel(_ stops: [(ang: Double, h: CGFloat, s: CGFloat, b: CGFloat)])
            -> [(ang: Double, h: CGFloat, s: CGFloat, b: CGFloat)] {
            stops.map { $0.s == 0 ? $0 : ($0.ang, $0.h, $0.s * 0.6, min(1, max($0.b, 0.45) + 0.30)) }
        }
        let stops = yandhi ? pale : yeezus ? pastel(refined) : dark
        func nearestStop(_ ang: Double) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
            var best = stops[0], bestD = 999.0
            for s in stops {
                var d = abs(ang - s.ang).truncatingRemainder(dividingBy: 360)
                if d > 180 { d = 360 - d }
                if d < bestD { bestD = d; best = s }
            }
            return (best.h, best.s, best.b)
        }

        // Thin unlit spokes, HARD-edged — a smooth falloff here reads as airbrush and breaks
        // the posterised look. Inside a spoke the wedge drops straight to the dark floor.
        let divisions = [30.0, 90, 150, 210, 270, 330]
        func inSpoke(_ ang: Double) -> Bool {
            divisions.contains { d in
                var dd = abs(ang - d).truncatingRemainder(dividingBy: 360)
                if dd > 180 { dd = 360 - dd }
                return dd < 5
            }
        }

        let steps = 1440
        for i in 0..<steps {
            let ang = Double(i) / Double(steps) * 360
            let stop = nearestStop(ang)
            let wedge = NSBezierPath()
            wedge.move(to: c)
            // +0.5° overlap: exactly abutting wedges leave hairline seams of the layer beneath.
            wedge.appendArc(withCenter: c, radius: 360,
                            startAngle: ang, endAngle: ang + 360 / Double(steps) + 0.5)
            wedge.close()
            let spoke = inSpoke(ang)
            NSColor(calibratedHue: stop.h, saturation: spoke ? 0 : stop.s,
                    brightness: spoke ? (yandhi ? 0.62 : 0.12) : stop.b, alpha: 1).setFill()
            wedge.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // Square sticker-hole, centred on the disc's right rim. Plate-coloured, so it reads as a
    // square punched clean through the disc — app icons can't carry real alpha. The half that
    // falls beyond the rim is plate-on-plate and invisible, leaving a bite out of the edge.
    // Tuning knobs — this is a drawing, and the numbers only settle by looking at it.
    // SQ = square size. SQX = distance of its centre from the disc's centre; at 360 it straddles
    // the rim (chosen), below ~300 it sits inside the disc, and it must clear the centre hole
    // (r=150) or the two merge into a keyhole.
    // Proportions measured off reference.jpg rather than guessed. There the disc is 379px across
    // and the red is 167 x 203 — i.e. 0.44 of the disc wide, 0.54 tall, and TALLER THAN WIDE,
    // not square. Since the right edge here is pinned to the icon edge (1.42r from centre, vs
    // 1.22r in the reference), the left edge sits at 1.42 - 0.88 = 0.54r to keep the reference's
    // total width — 0.34r (the reference's left edge) made the tape read square.
    let env = ProcessInfo.processInfo.environment
    let height = CGFloat(env["SQH"].flatMap(Double.init) ?? 0.54) * 720
    let left = c.x + CGFloat(env["SQL"].flatMap(Double.init) ?? 0.54) * 360
    // Stretched to the icon's right edge, so it bleeds off rather than floating.
    let right = CGFloat(env["SQR"].flatMap(Double.init) ?? Double(size))
    let sq = NSRect(x: left, y: c.y - height / 2, width: right - left, height: height)

    // Solid red tape, per reference.jpg. Not plate-coloured: that would be a hole punched
    // through the disc, which is what made the icon read as a "C". Only the two LEFT corners
    // round — the right pair bleeds off the icon edge, so rounding them would show as a notch.
    let cr = CGFloat(env["SQC"].flatMap(Double.init) ?? 34)
    let tape = NSBezierPath()
    tape.move(to: NSPoint(x: sq.maxX, y: sq.minY))
    tape.line(to: NSPoint(x: sq.minX + cr, y: sq.minY))
    tape.appendArc(withCenter: NSPoint(x: sq.minX + cr, y: sq.minY + cr), radius: cr,
                   startAngle: 270, endAngle: 180, clockwise: true)
    tape.line(to: NSPoint(x: sq.minX, y: sq.maxY - cr))
    tape.appendArc(withCenter: NSPoint(x: sq.minX + cr, y: sq.maxY - cr), radius: cr,
                   startAngle: 180, endAngle: 90, clockwise: true)
    tape.line(to: NSPoint(x: sq.maxX, y: sq.maxY))
    tape.close()
    (yandhi ? NSColor(calibratedHue: 0.82, saturation: 0.55, brightness: 0.62, alpha: 1)
            : NSColor(calibratedRed: 0.94, green: 0.14, blue: 0.11, alpha: 1)).setFill()
    tape.fill()

    // Centre hub matches the sheen's unlit tone, not the plate — a plate-coloured bore reads
    // as another hole, this reads as the disc's own centre. Light icons: silver hub.
    let hub = NSColor(calibratedWhite: yandhi ? 0.70 : 0.12, alpha: 1)
    hub.setFill()
    circle(150).fill()
    ink.setFill()
    circle(118).fill()
    hub.setFill()
    circle(86).fill()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try png.write(to: URL(fileURLWithPath: path))
print("wrote \(path)")
