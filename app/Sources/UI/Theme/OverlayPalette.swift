import AppKit

/// Resolved frame colours and widths (docs/DESIGN.md §4.1 `ov.*` / `plate.*`, §4.4, §15) for one
/// appearance and accessibility state: scrim · line · halo · period · plate. CGColors are created
/// only inside `performAsCurrentDrawingAppearance`.
///
/// The scrim colour is stored opaque and its alpha travels as the scrim layer's opacity, so the O4
/// commit peak (α .40) is an opacity animation. Two surfaces share the tree: `.screen` (the overlay
/// over any desktop: halo on) and `.paper` (miniatures on Nokta's own paper: `ink.wash` fill,
/// 1.5 pt ink line, no halo).
struct OverlayPalette: Equatable {
    enum Surface { case screen, paper }

    var variant: Theme.Variant
    var surface: Surface
    var reduceTransparency: Bool
    var differentiateWithoutColor: Bool

    // scrim
    var scrim: CGColor
    var scrimAlpha: CGFloat
    /// O4 commit peak.
    var scrimPeakAlpha: CGFloat
    // line (widths in points, before rounding to device pixels)
    var line: CGColor
    var lineWidth: CGFloat
    var commitLineWidth: CGFloat
    var blockedLineWidth: CGFloat
    // halo: 1 pt on each side of the line; nil on paper
    var halo: CGColor?
    var haloWidth: CGFloat
    // period (R1) and its Differentiate Without Color ring
    var period: CGColor
    var periodRing: CGColor?
    // plate (inverse colours; Increase Contrast adds a 1 pt paper edge)
    var plateFill: CGColor
    var plateText: CGColor
    var plateEdge: CGColor?

    var highContrast: Bool { variant.isHighContrast }

    static func resolve(appearance: NSAppearance, env: AccessibilityEnv.Snapshot = AccessibilityEnv.shared.snapshot,
                        surface: Surface = .screen) -> OverlayPalette {
        // IC comes from the appearance (bestMatch) or the system flag; both select IC tokens.
        var v = Theme.variant(for: appearance)
        if env.increaseContrast && !v.isHighContrast { v = v.isDark ? .icDark : .icLight }
        let effective = NSAppearance(named: Theme.appearanceNames[v.rawValue]) ?? appearance
        var result: OverlayPalette!
        effective.performAsCurrentDrawingAppearance {
            result = make(variant: v, env: env, surface: surface)
        }
        return result
    }

    /// Must run inside `performAsCurrentDrawingAppearance`.
    private static func make(variant v: Theme.Variant, env: AccessibilityEnv.Snapshot, surface: Surface) -> OverlayPalette {
        let ic = v.isHighContrast
        let rt = env.reduceTransparency
        func cg(_ c: NSColor) -> CGColor { c.usingColorSpace(.sRGB)?.cgColor ?? c.cgColor }
        func token(_ t: Theme.Color.Token) -> NSColor { Theme.Color.value(t, v, reduceTransparency: rt) }
        let ink = Theme.Color.inkValue(v)

        let scrim: NSColor, line: NSColor
        let halo: CGColor?
        let widths: (CGFloat, CGFloat, CGFloat)
        switch surface {
        case .screen:
            scrim = token(.ovScrim)
            line = token(.ovLine)
            halo = cg(token(.ovHalo))
            widths = (Theme.Line.overlay(highContrast: ic), Theme.Line.commit(highContrast: ic), Theme.Line.blocked(highContrast: ic))
        case .paper:
            scrim = token(.inkWash)
            line = ink
            halo = nil
            widths = (Theme.Line.miniature, Theme.Line.miniatureCommit, Theme.Line.miniature)
        }
        let alpha = scrim.alphaComponent
        return OverlayPalette(
            variant: v, surface: surface, reduceTransparency: rt, differentiateWithoutColor: env.differentiateWithoutColor,
            scrim: cg(scrim.withAlphaComponent(1)),
            scrimAlpha: alpha,
            scrimPeakAlpha: surface == .screen ? max(alpha, 0.40) : min(1, alpha * 1.5),
            line: cg(line),
            lineWidth: widths.0, commitLineWidth: widths.1, blockedLineWidth: widths.2,
            halo: halo, haloWidth: Theme.Line.halo,
            period: cg(token(.red)),
            periodRing: env.differentiateWithoutColor ? cg(ink) : nil,
            plateFill: cg(token(.plateFill)),
            plateText: cg(token(.plateText)),
            plateEdge: ic ? cg(token(.plateEdge)) : nil)
    }
}
