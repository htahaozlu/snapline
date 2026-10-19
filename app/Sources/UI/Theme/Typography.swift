import AppKit

/// Type roles (docs/DESIGN.md §4.3). System fonts only — SF Pro (Text/Display are picked by the
/// system from the point size), SF Mono and SF Symbols; no kerning, real fractions (`½ ⅓ ⅔ ¼`)
/// and real arrows. `lineHeight(_:)` gives each role's fixed line, `attributes(_:color:)` a
/// ready attribute set.
enum Typography {
    enum Role: Hashable {
        /// `nokta` + a separately drawn period: SF Pro Display Bold, tracking −0.6. 40/44 in
        /// onboarding, 28/32 in About.
        case wordmark(size: CGFloat)
        /// Onboarding titles, 22/28 Semibold.
        case title
        /// Everything, 13/16.
        case body
        /// One-line help, 12/15 (secondary colour).
        case callout
        /// `Measured now.`, scene text, 11/14.
        case caption
        /// Live numbers and slider readings, 13/16 monospaced digits (About values Semibold).
        case digits(semibold: Bool)
        /// About › Details (lsof, entitlements), 11/14.
        case mono
        /// Key caps: 12 (chips), 18 (scene keys), Medium.
        case keycap(size: CGFloat)
        /// Label plate, 15/20 Semibold.
        case plate
    }

    static func font(_ role: Role) -> NSFont {
        switch role {
        case .wordmark(let size): return .systemFont(ofSize: size, weight: .bold)
        case .title: return .systemFont(ofSize: 22, weight: .semibold)
        case .body: return .systemFont(ofSize: 13)
        case .callout: return .systemFont(ofSize: 12)
        case .caption: return .systemFont(ofSize: 11)
        case .digits(let semibold): return .monospacedDigitSystemFont(ofSize: 13, weight: semibold ? .semibold : .regular)
        case .mono: return .monospacedSystemFont(ofSize: 11, weight: .regular)
        case .keycap(let size): return .systemFont(ofSize: size, weight: .medium)
        case .plate: return .systemFont(ofSize: 15, weight: .semibold)
        }
    }

    /// Fixed line height of a role.
    static func lineHeight(_ role: Role) -> CGFloat {
        switch role {
        case .wordmark(let size): return size >= 40 ? 44 : (size <= 28 ? 32 : (size + 4).rounded())
        case .title: return 28
        case .body, .digits: return 16
        case .callout: return 15
        case .caption, .mono: return 14
        case .keycap(let size): return (size * 1.25).rounded()
        case .plate: return 20
        }
    }

    /// Tracking (points between glyphs): only the wordmark has any (−0.6).
    static func tracking(_ role: Role) -> CGFloat {
        if case .wordmark = role { return -0.6 }
        return 0
    }

    /// Font, fixed line height, tracking and colour for one run.
    static func attributes(_ role: Role, color: NSColor = .labelColor, alignment: NSTextAlignment = .natural) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight(role)
        p.maximumLineHeight = lineHeight(role)
        p.alignment = alignment
        var a: [NSAttributedString.Key: Any] = [.font: font(role), .foregroundColor: color, .paragraphStyle: p]
        if tracking(role) != 0 { a[.kern] = tracking(role) }
        return a
    }

    // Shorthands for the roles above.
    static var title: NSFont { font(.title) }
    static var body: NSFont { font(.body) }
    static var callout: NSFont { font(.callout) }
    static var caption: NSFont { font(.caption) }
    static var digits: NSFont { font(.digits(semibold: false)) }
    static var mono: NSFont { font(.mono) }
    static var keycap: NSFont { font(.keycap(size: 12)) }
    static var plate: NSFont { font(.plate) }
    static func wordmark(size: CGFloat) -> NSFont { font(.wordmark(size: size)) }

    // System styles the v1 Settings layout still uses (group and row labels, the menu's
    // metric line); Phase B's layouts replace them with the roles above.
    static var title2: NSFont { .systemFont(ofSize: 17, weight: .semibold) }
    static var headline: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
}
