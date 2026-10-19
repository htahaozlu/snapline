// render-icon.swift — draws the Nokta app icon with CoreGraphics (docs/DESIGN.md §12).
//
//   swiftc -O tools/icon/render-icon.swift -o /tmp/render-icon && /tmp/render-icon <out-dir>
//
// Writes <out-dir>/AppIcon.iconset/icon_*.png (16…1024, @1x/@2x, each rendered from the vector
// description at its exact pixel size), <out-dir>/AppIcon.svg and <out-dir>/AppIcon-preview.png
// (the 1024 master on a checkerboard-free neutral). `tools/icon/build-icon.sh` runs this and
// `iconutil`. Pure function of the constants below: no assets, no randomness.
//
// Concept (DESIGN v2 §12, "the line shows, the period ends"): the mark `▮▯.` — a window frame
// whose left half is filled (a window snapped left) and a red period OUTSIDE the frame, its bottom
// on the frame's outer bottom edge. Dark flat body, no gradient, no shadow.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Spec (1024 canvas)

enum Spec {
    static let canvas: CGFloat = 1024
    static let body: CGFloat = 824                       // macOS icon grid: 100 pt margin
    static let bodyColor: UInt32 = 0x111113
    static let ink: UInt32 = 0xF5F5F3
    static let period: UInt32 = 0xFF4438
    static let innerLineAlpha: CGFloat = 0.08            // #FFF
    /// Window frame: outer bounds, outer corner radius, stroke (drawn inside the bounds).
    static let frame = CGRect(x: 203, y: 322, width: 520, height: 380)
    static let frameRadius: CGFloat = 56
    static let frameStroke: CGFloat = 28
    /// Left half filled: x 203…463.
    static let fillMaxX: CGFloat = 463
    /// Period: Ø 76, centre (783, 664) — its bottom (702) is the frame's outer bottom.
    static let periodCenter = CGPoint(x: 783, y: 664)
    static let periodDiameter: CGFloat = 76
    /// Corner of the body (see `bodyPoints`): r ≈ 185 → 824 × 0.2245.
    static let cornerExtent: CGFloat = 283
    static let cornerExponent: CGFloat = 3.26
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The frame's stroke path: the outer bounds inset by half the stroke, so the stroke's outer edge
/// is `Spec.frame` with radius `Spec.frameRadius`.
func framePath(stroke: CGFloat) -> CGPath {
    let r = Spec.frame.insetBy(dx: stroke / 2, dy: stroke / 2)
    let rad = max(0, Spec.frameRadius - stroke / 2)
    return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

func outerFramePath() -> CGPath {
    CGPath(roundedRect: Spec.frame, cornerWidth: Spec.frameRadius, cornerHeight: Spec.frameRadius, transform: nil)
}

/// Body outline: straight sides and continuous-curvature (superellipse) corners — the macOS 11+
/// icon silhouette. Each corner is a superellipse quadrant of extent `cornerExtent` along both
/// edges (≈ 1.53 × r, the classic smooth-corner constant, for r = 185) with exponent
/// `cornerExponent`; the exponent is chosen so the corner cuts the diagonal as deep as a circular
/// r = 185 corner would (76.6 pt), but with zero curvature where it meets the straight side.
func bodyPoints(inset: CGFloat = 0, stepsPerCorner: Int = 90) -> [CGPoint] {
    let half = Spec.body / 2 - inset
    let a = Spec.cornerExtent
    let n = Spec.cornerExponent
    let cx = Spec.canvas / 2, cy = Spec.canvas / 2
    // (corner sign x, sign y, t from, t to) clockwise from the top-right corner (y down).
    let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (1, -1, .pi / 2, 0), (1, 1, 0, .pi / 2), (-1, 1, .pi / 2, 0), (-1, -1, 0, .pi / 2),
    ]
    var out: [CGPoint] = []
    for (sx, sy, t0, t1) in corners {
        let ccx = cx + sx * (half - a), ccy = cy + sy * (half - a)
        for i in 0...stepsPerCorner {
            let t = t0 + (t1 - t0) * CGFloat(i) / CGFloat(stepsPerCorner)
            out.append(CGPoint(x: ccx + sx * a * pow(cos(t), 2 / n), y: ccy + sy * a * pow(sin(t), 2 / n)))
        }
    }
    return out
}

// MARK: - Raster

/// Optical-size tweak: below 64 px the 28-unit stroke would fall under one pixel and the period
/// under two, so both keep a minimum pixel size (stroke ≥ 1.1 px, period ≥ 1.8 px). Larger sizes
/// use the spec values unchanged.
func optical(pixels: Int) -> (stroke: CGFloat, period: CGFloat) {
    let unit = Spec.canvas / CGFloat(pixels)                // canvas units per pixel
    return (max(Spec.frameStroke, 1.1 * unit), max(Spec.periodDiameter, 1.8 * unit))
}

func render(pixels: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    // Canvas units, y down.
    let k = CGFloat(pixels) / Spec.canvas
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: k, y: -k)

    let path = CGMutablePath()
    let pts = bodyPoints()
    path.addLines(between: pts)
    path.closeSubpath()
    ctx.setFillColor(color(Spec.bodyColor))
    ctx.addPath(path)
    ctx.fillPath()

    if pixels >= 128 {
        // Thin inner line (#FFF α .08), 2 canvas units wide, inset by 1.
        let inner = CGMutablePath()
        inner.addLines(between: bodyPoints(inset: 1))
        inner.closeSubpath()
        ctx.setStrokeColor(color(0xFFFFFF, Spec.innerLineAlpha))
        ctx.setLineWidth(2)
        ctx.addPath(inner)
        ctx.strokePath()
    }

    let opt = optical(pixels: pixels)
    // Left half: filled inside the frame's outer outline.
    ctx.saveGState()
    ctx.addPath(outerFramePath())
    ctx.clip()
    ctx.setFillColor(color(Spec.ink))
    ctx.fill(CGRect(x: Spec.frame.minX, y: Spec.frame.minY, width: Spec.fillMaxX - Spec.frame.minX, height: Spec.frame.height))
    ctx.restoreGState()
    // The frame line.
    ctx.setStrokeColor(color(Spec.ink))
    ctx.setLineWidth(opt.stroke)
    ctx.addPath(framePath(stroke: opt.stroke))
    ctx.strokePath()
    // The period, outside the frame; its bottom stays on the frame's outer bottom.
    let d = opt.period
    let c = CGPoint(x: Spec.periodCenter.x, y: Spec.frame.maxY - d / 2)
    ctx.setFillColor(color(Spec.period))
    ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot finalize \(url.path)") }
}

// MARK: - SVG (reference, same constants)

func svg() -> String {
    func f(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
    func path(_ pts: [CGPoint]) -> String {
        "M" + pts.map { "\(f($0.x)) \(f($0.y))" }.joined(separator: " L") + " Z"
    }
    func hexString(_ v: UInt32) -> String { String(format: "#%06X", v) }
    var out = ""
    out += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\n"
    out += "  <title>Snapline</title>\n"
    out += "  <!-- Generated by tools/icon/render-icon.swift — reference only; the .icns is rendered by CoreGraphics. -->\n"
    out += "  <path d=\"\(path(bodyPoints(stepsPerCorner: 45)))\" fill=\"\(hexString(Spec.bodyColor))\"/>\n"
    out += "  <path d=\"\(path(bodyPoints(inset: 1, stepsPerCorner: 45)))\" fill=\"none\" stroke=\"#FFFFFF\" stroke-opacity=\"\(Spec.innerLineAlpha)\" stroke-width=\"2\"/>\n"
    let fr = Spec.frame, inset = Spec.frameStroke / 2
    out += "  <clipPath id=\"frame\"><rect x=\"\(f(fr.minX))\" y=\"\(f(fr.minY))\" width=\"\(f(fr.width))\" height=\"\(f(fr.height))\" rx=\"\(f(Spec.frameRadius))\"/></clipPath>\n"
    out += "  <rect x=\"\(f(fr.minX))\" y=\"\(f(fr.minY))\" width=\"\(f(Spec.fillMaxX - fr.minX))\" height=\"\(f(fr.height))\" fill=\"\(hexString(Spec.ink))\" clip-path=\"url(#frame)\"/>\n"
    out += "  <rect x=\"\(f(fr.minX + inset))\" y=\"\(f(fr.minY + inset))\" width=\"\(f(fr.width - 2 * inset))\" height=\"\(f(fr.height - 2 * inset))\" rx=\"\(f(Spec.frameRadius - inset))\" fill=\"none\" stroke=\"\(hexString(Spec.ink))\" stroke-width=\"\(f(Spec.frameStroke))\"/>\n"
    out += "  <circle cx=\"\(f(Spec.periodCenter.x))\" cy=\"\(f(Spec.periodCenter.y))\" r=\"\(f(Spec.periodDiameter / 2))\" fill=\"\(hexString(Spec.period))\"/>\n"
    out += "</svg>\n"
    return out
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: render-icon <out-dir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (point size, scale) → file name, exact pixel size.
let entries: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (pt, scale) in entries {
    let px = pt * scale
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    writePNG(render(pixels: px), to: iconset.appendingPathComponent(name))
    print("wrote \(name) (\(px) px)")
}
try svg().write(to: outDir.appendingPathComponent("AppIcon.svg"), atomically: true, encoding: .utf8)
writePNG(render(pixels: 1024), to: outDir.appendingPathComponent("AppIcon-preview.png"))
print("wrote AppIcon.svg, AppIcon-preview.png")
