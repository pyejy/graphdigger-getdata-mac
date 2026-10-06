// Renders the app icon — a flowing white capture curve with a crosshair on a
// blue↔cyan gradient tile — and writes AppIcon.iconset.
//
//     swift scripts/make_icon.swift <output-dir>
//
// The icon is code, not an asset, so anyone who wants to nudge it edits a few
// numbers instead of opening a design file they do not have. `iconutil` packs
// the icns afterwards. Everything is drawn natively at each size — resampling
// one 1024 master is what makes small sizes go muddy.
//
// The reference SVG is authored on a 256² canvas in y-down coordinates; the
// bitmap context we get from NSGraphicsContext(bitmapImageRep:) is y-up, so we
// flip it once at the start and afterwards draw in SVG coordinates.
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

func render(_ px: CGFloat) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("could not allocate the icon bitmap") }
    rep.size = NSSize(width: px, height: px)

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not open a graphics context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // The bitmap context is y-up (bottom-left origin); flip once so everything
    // below can draw in SVG's y-down, top-left coordinates.
    cg.translateBy(x: 0, y: px)
    cg.scaleBy(x: 1, y: -1)
    let u: (CGFloat, CGFloat) -> CGPoint = { CGPoint(x: $0 * px / 256,
                                                     y: $1 * px / 256) }

    // The rounded tile, 256² with rx=58.
    let tile = NSRect(x: 0, y: 0, width: px, height: px)
    NSBezierPath(roundedRect: tile, xRadius: 58 * px / 256,
                                yRadius: 58 * px / 256).addClip()

    // Gradient: indigo (#4F46E5) bottom-left, blue (#3B82F6) mid, cyan
    // (#06B6D4) top-right. CG gradients ignore the current transform, but their
    // start/end points are in the *bitmap's* own y-up space, so the SVG's
    // "bottom-left" (y-down 256) is (0,0) here and "top-right" is (px, px).
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let grad = CGGradient(colorsSpace: space,
                             colors: [rgb(0x4F, 0x46, 0xE5).cgColor,
                                      rgb(0x3B, 0x82, 0xF6).cgColor,
                                      rgb(0x06, 0xB6, 0xD4).cgColor] as CFArray,
                             locations: [0.0, 0.5, 1.0]) {
        cg.drawLinearGradient(grad,
                              start: CGPoint(x: 0, y: px),
                              end: CGPoint(x: px, y: 0),
                              options: [])
    }

    // The faint 1px grid, three 32-unit-spaced lines each way.
    NSColor.white.withAlphaComponent(0.07).setStroke()
    cg.setLineWidth(max(1.0, px / 256))
    let gridSegs: [(CGPoint, CGPoint)] = [
        (u(40, 40), u(40, 216)), (u(72, 40), u(72, 216)),
        (u(104, 40), u(104, 216)), (u(136, 40), u(136, 216)),
        (u(168, 40), u(168, 216)), (u(200, 40), u(200, 216)),
        (u(40, 40), u(216, 40)), (u(40, 72), u(216, 72)),
        (u(40, 104), u(216, 104)), (u(40, 136), u(216, 136)),
        (u(40, 168), u(216, 168)), (u(40, 200), u(216, 200)),
    ]
    for (a, b) in gridSegs {
        cg.move(to: a)
        cg.addLine(to: b)
    }
    cg.strokePath()

    // The axis: two independent strokes from the same corner — the SVG's
    // `M 68 196 V 64 M 68 196 H 196` is two subpaths, not one polyline, so the
    // vertical must not connect straight to the horizontal's far end.
    NSColor.white.withAlphaComponent(0.35).setStroke()
    cg.setLineCap(.round)
    cg.setLineWidth(8 * px / 256)
    cg.move(to: u(68, 196))
    cg.addLine(to: u(68, 64))
    cg.move(to: u(68, 196))
    cg.addLine(to: u(196, 196))
    cg.strokePath()

    // The curve: two cubic beziers through (156, 124), the crosshair's own
    // centre. The SVG's glow filter is a Gaussian blur merged under the stroke,
    // which is what NSShadow with a zero offset draws — a wide translucent
    // second stroke is not the same thing and reads as a haze.
    let curve = NSBezierPath()
    curve.move(to: u(80, 184))
    curve.curve(to: u(156, 124), controlPoint1: u(115, 184),
                controlPoint2: u(135, 145))
    curve.curve(to: u(192, 84), controlPoint1: u(177, 103),
                controlPoint2: u(185, 95))
    curve.lineCapStyle = .round
    curve.lineWidth = 7 * px / 256
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.white
    glow.shadowBlurRadius = max(4 * px / 256, 1.0) * 2.2
    glow.shadowOffset = .zero
    glow.set()
    NSColor.white.withAlphaComponent(0.95).setStroke()
    curve.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The capture point: a translucent halo, a solid centre dot, and four
    // L-shaped corner ticks around it — the SVG's crop-tick frame.
    let cx = u(156, 124)
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx.x - 20 * px / 256,
                                y: cx.y - 20 * px / 256,
                                width: 40 * px / 256, height: 40 * px / 256))
        .fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: cx.x - 10 * px / 256,
                                y: cx.y - 10 * px / 256,
                                width: 20 * px / 256, height: 20 * px / 256))
        .fill()
    NSColor.white.withAlphaComponent(0.95).setStroke()
    cg.setLineWidth(3 * px / 256)
    let ticks: [(CGPoint, CGPoint)] = [
        (u(124, 108), u(124, 92)), (u(124, 92), u(140, 92)),
        (u(172, 92), u(188, 92)), (u(188, 92), u(188, 108)),
        (u(124, 140), u(124, 156)), (u(124, 156), u(140, 156)),
        (u(172, 156), u(188, 156)), (u(188, 156), u(188, 140)),
    ]
    for (a, b) in ticks {
        cg.move(to: a)
        cg.addLine(to: b)
    }
    cg.strokePath()

    cg.resetClip()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(path)")
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : ".build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes { write(render(px), to: "\(outDir)/\(name)") }

// A contact sheet: 16/32/64/128 at native size on a light and a dark field, so
// size survival and the dark Dock are both judged before anything is picked.
let sheetW: CGFloat = 520, sheetH: CGFloat = 230
let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
sheet.lockFocus()
let fields: [(NSColor, String)] = [
    (NSColor(srgbRed: 0.878, green: 0.886, blue: 0.902, alpha: 1), "浅色桌面"),
    (NSColor(srgbRed: 0.129, green: 0.133, blue: 0.145, alpha: 1), "深色 Dock"),
]
for (row, field) in fields.enumerated() {
    field.0.setFill()
    NSRect(x: 0, y: CGFloat(row) * 115, width: sheetW, height: 115).fill()
    var x: CGFloat = 16
    for px in [16.0, 32.0, 64.0, 128.0] {
        render(px).draw(in: NSRect(x: x, y: CGFloat(row) * 115 + 12,
                                   width: px, height: px))
        x += px + 18
    }
    let label = NSAttributedString(string: field.1, attributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: row == 1 ? NSColor.white : NSColor.secondaryLabelColor,
    ])
    label.draw(at: NSPoint(x: sheetW - 90, y: CGFloat(row) * 115 + 12))
}
sheet.unlockFocus()
if let tiff = sheet.tiffRepresentation,
   let bmp = NSBitmapImageRep(data: tiff),
   let png = bmp.representation(using: .png, properties: [:]) {
    let parent = (outDir as NSString).deletingLastPathComponent
    try? png.write(to: URL(fileURLWithPath: "\(parent)/icon-preview.png"))
}

print(outDir)