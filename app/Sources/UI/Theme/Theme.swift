import AppKit

/// Design tokens v2 (docs/DESIGN.md §4–5): colour (§4.1), line, spacing and radius (§4.4) and
/// motion (§5.1). Typography roles live in `Typography.swift` (§4.3). System fonts only — the app
/// bundles no font.
///
/// Standard windows use the system semantic colours; the tokens below are only for custom
/// surfaces (overlay, Stage, ZoneMap, LineMeter, plate, menu glyphs). Values resolve per
/// appearance with `bestMatch` (light / dark / Increase Contrast light / dark); the overlay tokens
/// also have Reduce Transparency values (`OverlayPalette`).
enum Theme {
    // MARK: appearance variants

    /// Light / Dark / Increase Contrast Light / Increase Contrast Dark.
    enum Variant: Int { case light, dark, icLight, icDark
        var isDark: Bool { self == .dark || self == .icDark }
        var isHighContrast: Bool { self == .icLight || self == .icDark }
    }

    static let appearanceNames: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]

    /// IC comes from `bestMatch` (the system's high-contrast appearances) or, as a fallback,
    /// the cached Increase Contrast flag — `NSAppearance(named:)` cannot create IC variants.
    static func variant(for appearance: NSAppearance) -> Variant {
        let v: Variant
        switch appearance.bestMatch(from: appearanceNames) {
        case .darkAqua?: v = .dark
        case .accessibilityHighContrastAqua?: v = .icLight
        case .accessibilityHighContrastDarkAqua?: v = .icDark
        default: v = .light
        }
        if !v.isHighContrast && AccessibilityEnv.shared.increaseContrast { return v.isDark ? .icDark : .icLight }
        return v
    }

    /// Variant of the drawing appearance currently in effect (inside a dynamic provider or
    /// `performAsCurrentDrawingAppearance`).
    static var currentVariant: Variant { variant(for: NSAppearance.currentDrawing()) }

    // MARK: colour (§4.1)

    enum Color {
        /// Every token by name; `value(_:_:reduceTransparency:)` gives its per-variant value.
        enum Token: String, CaseIterable {
            case ink, ink2 = "ink.2", ink3 = "ink.3", inkWash = "ink.wash"
            case paper, paperRaised = "paper.raised", hairline, red
            case ovScrim = "ov.scrim", ovLine = "ov.line", ovHalo = "ov.halo"
            case plateFill = "plate.fill", plateText = "plate.text", plateEdge = "plate.edge"
        }

        static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: a)
        }

        /// Raw ink per variant (no alpha).
        static func inkValue(_ v: Variant) -> NSColor {
            switch v {
            case .light: return hex(0x111113)
            case .dark: return hex(0xF5F5F3)
            case .icLight: return hex(0x000000)
            case .icDark: return hex(0xFFFFFF)
            }
        }

        /// Raw paper per variant (the onboarding ground; also the halo's tone).
        static func paperValue(_ v: Variant) -> NSColor {
            switch v {
            case .light: return hex(0xF7F7F5)
            case .dark: return hex(0x0B0B0C)
            case .icLight: return hex(0xFFFFFF)
            case .icDark: return hex(0x000000)
            }
        }

        /// One alpha per variant: light, dark, IC light, IC dark.
        static func alpha(_ v: Variant, _ l: CGFloat, _ d: CGFloat, _ icl: CGFloat, _ icd: CGFloat) -> CGFloat {
            switch v { case .light: return l; case .dark: return d; case .icLight: return icl; case .icDark: return icd }
        }

        /// Static (non-dynamic) value of a token in one variant. `reduceTransparency` matters only
        /// for `ov.scrim` (α .80) and `ov.halo` (α .95).
        static func value(_ t: Token, _ v: Variant, reduceTransparency rt: Bool = false) -> NSColor {
            let ink = inkValue(v)
            switch t {
            case .ink: return ink
            case .ink2: return ink.withAlphaComponent(alpha(v, 0.62, 0.62, 0.80, 0.80))
            case .ink3: return ink.withAlphaComponent(alpha(v, 0.28, 0.30, 0.55, 0.60))
            case .inkWash: return ink.withAlphaComponent(alpha(v, 0.06, 0.08, 0.12, 0.14))
            case .paper: return paperValue(v)
            case .paperRaised: return v.isDark ? hex(0x161618) : hex(0xFFFFFF)
            case .hairline: return ink.withAlphaComponent(alpha(v, 0.12, 0.14, 0.45, 0.45))
            case .red:
                switch v { case .light: return hex(0xE0301E); case .dark: return hex(0xFF4438)
                case .icLight: return hex(0xB8200F); case .icDark: return hex(0xFF6A5C) }
            case .ovScrim:
                let base = v.isDark ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                return base.withAlphaComponent(rt ? 0.80 : alpha(v, 0.28, 0.32, 0.45, 0.45))
            case .ovLine: return ink.withAlphaComponent(v.isHighContrast ? 1 : 0.92)
            case .ovHalo: return paperValue(v).withAlphaComponent(rt ? 0.95 : (v.isHighContrast ? 0.90 : 0.55))
            case .plateFill: return ink
            case .plateText: return value(.paperRaised, v)
            case .plateEdge: return paperValue(v) // drawn only in Increase Contrast (1 pt, α 1)
            }
        }

        private static func dynamic(_ t: Token) -> NSColor {
            NSColor(name: NSColor.Name("nokta." + t.rawValue)) { appearance in value(t, Theme.variant(for: appearance)) }
        }

        /// Line, fill and custom text.
        static let ink = dynamic(.ink)
        /// Secondary line and text.
        static let ink2 = dynamic(.ink2)
        /// Passive line (ZoneMap, scene frames).
        static let ink3 = dynamic(.ink3)
        /// Fills inside scenes, pressed keys.
        static let inkWash = dynamic(.inkWash)
        /// Onboarding ground.
        static let paper = dynamic(.paper)
        /// Stage and cards; in Increase Contrast it also needs a 1 pt ink edge (`raisedEdgeWidth`).
        static let paperRaised = dynamic(.paperRaised)
        /// Stage edge.
        static let hairline = dynamic(.hairline)
        /// Only for the closed R1–R6 list of DESIGN §4.2 (at most one red element per surface).
        static let red = dynamic(.red)
        /// Label plate, inverse colours (the plate's IC edge is `plateEdge`, 1 pt).
        static let plateFill = dynamic(.plateFill)
        static let plateText = dynamic(.plateText)
        static let plateEdge = dynamic(.plateEdge)
    }

    /// Edge width that `paper.raised` surfaces need in the current appearance (IC: 1 pt ink).
    static func raisedEdgeWidth(for appearance: NSAppearance) -> CGFloat {
        variant(for: appearance).isHighContrast ? 1 : 0
    }

    // MARK: line (§4.4)

    /// Line rules. Widths are rounded up to whole device pixels (`device`), so `line.w` is 2 px at
    /// 1x and 3 px at 1.5x; path corners sit on half pixels where the width is odd, and every
    /// layer's `contentsScale` is its screen's scale. No shadows anywhere.
    enum Line {
        /// `ov.line` (`line.w`): 2 pt, Increase Contrast 3 pt.
        static func overlay(highContrast: Bool) -> CGFloat { highContrast ? 3 : 2 }
        /// O4 commit and O5 flash: 3 pt, Increase Contrast 4 pt.
        static func commit(highContrast: Bool) -> CGFloat { highContrast ? 4 : 3 }
        /// O6 blocked frame: 1.5 pt, Increase Contrast 2 pt.
        static func blocked(highContrast: Bool) -> CGFloat { highContrast ? 2 : 1.5 }
        /// `ov.halo`: 1 pt on each side of the line.
        static let halo: CGFloat = 1
        /// Differentiate Without Color: ink ring around the period.
        static let periodRing: CGFloat = 1.5
        /// Frames drawn at scene scale on paper (ZoneMap, onboarding): 1.5 pt, commit 3 pt.
        static let miniature: CGFloat = 1.5
        static let miniatureCommit: CGFloat = 3

        /// `ceil(w · scale) / scale`.
        static func device(_ w: CGFloat, scale: CGFloat) -> CGFloat {
            guard scale > 0 else { return w }
            return (w * scale - 1e-6).rounded(.up) / scale
        }

        /// A width grown from `base` towards `target` by whole pixels on each side, so a line that
        /// thickens around a fixed path stays on the pixel grid (3 pt at 1x becomes 4 px).
        static func grown(_ base: CGFloat, to target: CGFloat, scale: CGFloat) -> CGFloat {
            base + 2 * device(max(0, target - base) / 2, scale: scale)
        }

        /// Snaps a coordinate to the device pixel grid.
        static func snap(_ v: CGFloat, scale: CGFloat) -> CGFloat {
            guard scale > 0 else { return v }
            return (v * scale).rounded() / scale
        }
    }

    // MARK: spacing, radius (§4.4)

    enum Space {
        static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
        static let s5: CGFloat = 20, s6: CGFloat = 24, s8: CGFloat = 32, s10: CGFloat = 40, s16: CGFloat = 64
    }

    enum Radius {
        /// `r.s`, `r.m`, `r.stage`.
        static let small: CGFloat = 6, medium: CGFloat = 10, stage: CGFloat = 12
        /// `r.overlay`: 12 pt on macOS 14–15, 16 pt on macOS 26+ (window corners grew; P).
        static let overlay: CGFloat = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? 16 : 12
        static func pill(height: CGFloat) -> CGFloat { height / 2 }
    }

    // MARK: motion (§5.1)

    /// Curves are `Ease` (Motion/Timeline.swift): `.out` entries, fade-in, press · `.in_` exits,
    /// cancel · `.glide` position changes, flight · `.land` period stamp, landing (overshoots, peak
    /// 1.034) · `.hand` scene cursor and hand · `.step` the window settles in one step, glyph swaps
    /// · `.linear` Reduce Motion cross-fades, colour. Durations are milliseconds (timelines use ms).
    enum Motion {
        static let fade: Double = 90          // dur.fade
        static let draw: Double = 160         // dur.draw (the line draws itself)
        static let drawDelay: Double = 20     // O1: the line starts 20 ms after the scrim
        static let move: Double = 140         // dur.move
        static let cancel: Double = 120       // dur.cancel
        static let commit: Double = 260       // dur.commit
        static let flash: Double = 240        // dur.flash
        static let stamp: Double = 100        // dur.stamp (period)
        static let shake: Double = 180        // dur.shake
        static let labelIn: Double = 90       // dur.label: in / hold / hold when blocked / out
        static let labelHold: Double = 700
        static let labelHoldBlocked: Double = 2000
        static let labelOut: Double = 160
        static let page: Double = 320         // dur.page
        static let flight: ClosedRange<Double> = 360...400
        /// dur.rm: Reduce Motion cross-fades, always linear.
        static let reduced: ClosedRange<Double> = 100...150
        /// Scene demos: 30…60 Hz, preferring 60 (no 120 Hz on ProMotion).
        static let demoFrameRate = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        /// A demo never plays more than 3 times (then its tail to `restT`).
        static let maxLoops = 3

        /// Cached; refreshed by `AccessibilityEnv` from the workspace notification (no polling).
        static var reduceMotion: Bool { AccessibilityEnv.shared.reduceMotion }
    }
}
