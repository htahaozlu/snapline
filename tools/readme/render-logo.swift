import AppKit

// README logo:  swift tools/readme/render-logo.swift   (from the repository root)
//
// Writes docs/images/logo-light.png and docs/images/logo-dark.png at 2x: the app icon
// (app/Resources/AppIcon.icns) beside the `snapline.` wordmark as the app draws it (system font,
// bold, tight tracking) with its period as a separate red dot in the font's full-stop slot
// (x = text end + 0.12 × size, y = baseline − 0.1 × size, Ø 0.2 × size; OnboardingPages.swift).
// Transparent background, so it sits on GitHub's light and dark themes.

let root = FileManager.default.currentDirectoryPath
let icon = NSImage(contentsOfFile: root + "/app/Resources/AppIcon.icns")
let red = NSColor(srgbRed: 1.0, green: 0.267, blue: 0.22, alpha: 1)   // #FF4438, the icon's period

func render(ink: NSColor, to path: String) {
    let iconSide: CGFloat = 168, spacing: CGFloat = 34, fontSize: CGFloat = 104
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .kern: -2.4]
    let word = NSAttributedString(string: "snapline", attributes: attrs)
    let textWidth = word.size().width - 2.4 // no tracking after the last letter
    let dot = 0.2 * fontSize
    let size = NSSize(width: ceil(iconSide + spacing + textWidth + 0.12 * fontSize + dot / 2 + 4), height: 200)
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    icon?.draw(in: NSRect(x: 0, y: (size.height - iconSide) / 2, width: iconSide, height: iconSide))

    let origin = NSPoint(x: iconSide + spacing, y: (size.height - word.size().height) / 2 + 6)
    word.draw(at: origin)

    // The period's centre sits in the font's full-stop slot after the word.
    let baseline = origin.y - font.descender
    let center = NSPoint(x: origin.x + textWidth + 0.12 * fontSize, y: baseline + 0.1 * fontSize)
    red.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)).fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path.replacingOccurrences(of: root + "/", with: ""))")
}

render(ink: NSColor(srgbRed: 0.067, green: 0.067, blue: 0.075, alpha: 1), to: root + "/docs/images/logo-light.png")
render(ink: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.953, alpha: 1), to: root + "/docs/images/logo-dark.png")
