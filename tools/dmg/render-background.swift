import AppKit

// DMG window background:  swift tools/dmg/render-background.swift <outdir>
//
// Writes <outdir>/background.png (660x400, 72 dpi) and <outdir>/background@2x.png (1320x800, 144 dpi).
// Deterministic: flat colours, system font, no randomness, no dates.
//
// Brand: "a thin line draws the exact target, a red period marks where the window landed."
// The drag hint is that line, from the app's slot toward Applications, ending in the red period.
// Colours and type are the README art's (docs/images/hero-light.svg, tools/readme/render-logo.swift).
//
// Layout in Finder points, top-left origin (must match tools/dmg/settings.py):
//   app icon centre (180, 210), Applications centre (480, 210), icon size 128;
//   Finder draws the file names at about y 282-300 under each icon.
//
// Dark Mode: Finder draws file names white over a custom background and black in Light Mode, and the
// background cannot react. So the names sit on a mid-tone shelf (a pill under each icon) that holds
// >= 3.4:1 against white and >= 6:1 against black, while the rest of the ground stays warm paper.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift render-background.swift <outdir>\n".utf8))
    exit(2)
}
let outDir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let paper = srgb(0xF7F7F5), ink = srgb(0x111113), inkSecondary = srgb(0x6B6B70)
let red = srgb(0xFF4438), shelf = srgb(0x8A8A86), slotWash = srgb(0xEDEDE9)

let width: CGFloat = 660, height: CGFloat = 400
let appCentre = CGPoint(x: 180, y: 210), folderCentre = CGPoint(x: 480, y: 210), iconSide: CGFloat = 128

func render(scale: Int, to path: String) throws {
    let s = CGFloat(scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * s), pixelsHigh: Int(height * s),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.fileWriteUnknown) }
    rep.size = NSSize(width: width, height: height)   // 2x -> 144 dpi, so Finder/tiffutil treat it as @2x
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    gc.imageInterpolation = .high
    gc.shouldAntialias = true

    // Top-left origin, y down, like Finder.
    let flip = NSAffineTransform()
    flip.scaleX(by: s, yBy: -s)
    flip.translateX(by: 0, yBy: -height)
    flip.concat()

    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // A soft slot under each icon: the place the eye (and the drag) starts and ends.
    for c in [appCentre, folderCentre] {
        slotWash.setFill()
        NSBezierPath(roundedRect: NSRect(x: c.x - 80, y: c.y - 84, width: 160, height: 186),
                     xRadius: 24, yRadius: 24).fill()
    }

    // The line: ~2 pt, round caps, from the app's slot toward Applications ...
    let lineY = appCentre.y, x0: CGFloat = 278, x1: CGFloat = 364
    let line = NSBezierPath()
    line.move(to: NSPoint(x: x0, y: lineY))
    line.line(to: NSPoint(x: x1, y: lineY))
    line.lineWidth = 2
    line.lineCapStyle = .round
    ink.setStroke()
    line.stroke()
    // ... and the red period where the window lands (diameter 12, ink-line end + gap).
    let dot: CGFloat = 12
    red.setFill()
    NSBezierPath(ovalIn: NSRect(x: x1 + 12, y: lineY - dot / 2, width: dot, height: dot)).fill()

    // Label shelves: the strip Finder writes the file names on.
    for c in [appCentre, folderCentre] {
        shelf.setFill()
        NSBezierPath(roundedRect: NSRect(x: c.x - 60, y: 278, width: 120, height: 26), xRadius: 13, yRadius: 13).fill()
    }

    // Text is drawn through a flipped-aware context.
    func draw(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, kern: CGFloat,
              centredAt cx: CGFloat, top: CGFloat) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern,
        ]
        let text = NSAttributedString(string: string, attributes: attrs)
        let sz = text.size()
        NSGraphicsContext.saveGraphicsState()
        let un = NSAffineTransform()   // undo the flip locally: AppKit text is upright in y-up space
        un.translateX(by: 0, yBy: height)
        un.scaleX(by: 1, yBy: -1)
        un.concat()
        text.draw(at: NSPoint(x: cx - (sz.width - kern) / 2, y: height - top - sz.height))
        NSGraphicsContext.restoreGraphicsState()
        return sz
    }

    _ = draw("Drag Snapline to Applications", size: 15, weight: .medium, color: inkSecondary, kern: 0.1,
             centredAt: width / 2, top: 338)

    // `snapline.` wordmark, top centre; the period is a separate red dot in the full-stop slot.
    let fs: CGFloat = 20, kern: CGFloat = -0.5
    let wordSize = NSAttributedString(string: "snapline", attributes: [
        .font: NSFont.systemFont(ofSize: fs, weight: .bold), .kern: kern]).size()
    let dotD = 0.2 * fs, gap = 0.12 * fs
    let total = wordSize.width - kern + gap + dotD / 2
    let left = (width - total) / 2
    let top: CGFloat = 36
    _ = draw("snapline", size: fs, weight: .bold, color: ink, kern: kern, centredAt: left + (wordSize.width - kern) / 2, top: top)
    let font = NSFont.systemFont(ofSize: fs, weight: .bold)
    let baseline = top + font.ascender            // y-down baseline of the text line
    red.setFill()
    NSBezierPath(ovalIn: NSRect(x: left + wordSize.width - kern + gap - dotD / 2, y: baseline - 0.1 * fs - dotD / 2,
                                width: dotD, height: dotD)).fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}

try render(scale: 1, to: outDir + "/background.png")
try render(scale: 2, to: outDir + "/background@2x.png")
