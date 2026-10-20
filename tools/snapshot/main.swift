import AppKit
import ImageIO

// nokta-snapshot — renders Nokta's UI to PNG files without showing anything on screen.
//
//   scripts/snapshot.sh [out-dir]          (default: tools/snapshot/out)
//   nokta-snapshot --self-test             motion contract checks only (SelfTest.swift)
//
// Built from the shell's sources (app/Sources minus App/main.swift, with -D NOKTA_SNAPSHOT) and
// linked against the INERT core (`zig build -Dinert=true`, libnokta-inert.a): the core exports
// the real C ABI but makes no Accessibility, hotkey, event-tap or display call, so nothing here
// can touch a window, a shortcut or a permission. On top of that this tool:
//   * never orders a window, panel or status item in (windows are built and drawn offscreen;
//     overlay surfaces are headless),
//   * never runs the app's launch path (AppController is not the delegate, never calls
//     NSApp.run() or activates the process; scenes start the inert core where they need a state),
//   * gives every component that takes a `UserDefaults` an in-memory `ScratchDefaults`
//     (ScratchDefaults.swift), the AppController below included: no defaults domain on disk is
//     read for a render or ever written.
// Output: <out>/<scene>-<light|dark>.png, overlay storyboards (overlay-<id>-t<ms>-<mode>.png and a
// GIF per timeline, OverlayFrames.swift), the real overlay controller's sequences
// (overlay-seq-<id>-t<ms>-<mode>.png), menu bar icons (menuicon-<state>-<1x|2x>-<mode>.png) and
// menu.txt (status menu structure). GIFs are for review only; nothing here enters the app.
// A failed check (self-test, overlay sequence, bench menu) exits non-zero.

/// Defined by App/main.swift in the app (startup trace); unused here.
let processStartTicks = mach_absolute_time()

let arguments = CommandLine.arguments

let application = NSApplication.shared
_ = application.setActivationPolicy(.prohibited) // never in the Dock, can never become active
SnapOverlayController.headless = true
// Renders never depend on this Mac's accessibility settings (Reduce Motion, Increase Contrast …).
AccessibilityEnv.shared.override = AccessibilityEnv.Snapshot()

// Shortcut labels come from a fixed layout (US), not this Mac's: renders and checks are the same anywhere.
KeyNames.layoutOverride = KeyboardLayout.installed(id: "com.apple.keylayout.US")

if arguments.contains("--self-test") {
    exit(SelfTest.run() ? 0 : 1)
}
// Behaviour suites (KeyboardTests.swift, RecoveryTests.swift, PracticeTests.swift): inert core, nothing shown or written.
if arguments.contains("--keyboard-test") {
    exit(KeyboardTests.run() ? 0 : 1)
}
if arguments.contains("--recovery-test") {
    exit(RecoveryTests.run() ? 0 : 1)
}
if arguments.contains("--practice-test") {
    exit(PracticeTests.run() ? 0 : 1)
}

let outDir = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "tools/snapshot/out", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: rendering

/// Draws `view` (and every CALayer below it) into a bitmap at `scale`.
func render(_ view: NSView, appearance: NSAppearance, scale: CGFloat = 2, background: NSColor? = .windowBackgroundColor) -> CGImage? {
    view.appearance = appearance
    view.layoutSubtreeIfNeeded()
    let size = view.bounds.size
    guard size.width > 0, size.height > 0 else { return nil }
    let w = Int(size.width * scale), h = Int(size.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    var image: CGImage?
    appearance.performAsCurrentDrawingAppearance {
        if let background {
            ctx.setFillColor(background.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        if view.wantsLayer, let layer = view.layer {
            view.displayIfNeeded()
            displayRecursively(layer)
            layer.render(in: ctx)
        } else if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let cg = rep.cgImage { ctx.draw(cg, in: CGRect(origin: .zero, size: size)) }
        }
        image = ctx.makeImage()
    }
    return image
}

func displayRecursively(_ layer: CALayer) {
    layer.layoutIfNeeded()
    layer.displayIfNeeded()
    layer.sublayers?.forEach(displayRecursively)
}

/// Draws a bare layer tree (overlay) over a neutral desktop stand-in.
func render(layer: CALayer, size: CGSize, appearance: NSAppearance, scale: CGFloat = 1, backdrop: (CGContext, CGSize) -> Void) -> CGImage? {
    let w = Int(size.width * scale), h = Int(size.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    var image: CGImage?
    appearance.performAsCurrentDrawingAppearance {
        backdrop(ctx, size)
        displayRecursively(layer)
        layer.render(in: ctx)
        image = ctx.makeImage()
    }
    return image
}

func write(_ image: CGImage?, _ name: String) {
    guard let image else { print("skip \(name): nothing rendered"); return }
    let url = outDir.appendingPathComponent(name + ".png")
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
    print("wrote \(url.lastPathComponent) \(image.width)×\(image.height)")
}

/// Writes an animated GIF (loops forever) from equally spaced frames.
func writeGIF(_ frames: [CGImage], frameDelay: Double, _ name: String) {
    guard !frames.isEmpty else { print("skip \(name).gif: no frames"); return }
    let url = outDir.appendingPathComponent(name + ".gif") as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "com.compuserve.gif" as CFString, frames.count, nil) else { return }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
                                                 kCGImagePropertyGIFDelayTime: frameDelay]] as CFDictionary
    for frame in frames { CGImageDestinationAddImage(dest, frame, props) }
    if CGImageDestinationFinalize(dest) { print("wrote \(name).gif (\(frames.count) frames)") }
}

/// A plain desktop stand-in: soft gradient + two app windows, so overlay shapes read in context.
func desktopBackdrop(dark: Bool) -> (CGContext, CGSize) -> Void {
    return { ctx, size in
        let top = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.86, alpha: 1)
        let bottom = dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.74, alpha: 1)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [bottom.cgColor, top.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        let windowFill = dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.98, alpha: 1)
        for r in [CGRect(x: size.width * 0.38, y: size.height * 0.22, width: size.width * 0.36, height: size.height * 0.5),
                  CGRect(x: size.width * 0.12, y: size.height * 0.3, width: size.width * 0.3, height: size.height * 0.42)] {
            ctx.setFillColor(windowFill.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.fillPath()
        }
    }
}

// MARK: scenes

/// Checks that failed while rendering (printed as they happen; the tool then exits 1).
var renderFailures: [String] = []

func renderFailure(_ what: String) {
    print("error: " + what)
    renderFailures.append(what)
}

let appearances: [(String, NSAppearance)] = [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)]
let controller = AppController(defaults: ScratchDefaults(suiteName: "nokta.snapshot.scratch.app")!)

snapshotSettings()
snapshotOnboarding(trusted: false)
snapshotOnboarding(trusted: true)
OverlayFrames.renderAll()
OverlayFrames.renderSequences()
OverlayFrames.renderMenuIcons()
OverlayFrames.renderGlyphs()
dumpMenu()

if !renderFailures.isEmpty {
    print("snapshot: FAIL (\(renderFailures.count) checks)")
    exit(1)
}
