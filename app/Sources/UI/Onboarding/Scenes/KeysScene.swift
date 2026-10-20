import AppKit
import QuartzCore

/// Scene C — the practice keys (docs/DESIGN.md §11). Only the shortcut to press next: its keys as
/// large keycaps, centred, with the step's name under them. The window that moves is the real one
/// (onboarding's own), so the scene shows no window of its own.
///
/// Guide: a 2400 ms loop at most 3 times — the keys go down at 600 and come up by 1000; restT 0
/// (keys up, on the seam), explainT 750 (keys down). Held: while the user holds modifiers, their
/// keycaps sit pressed (a static pose, no motion). Arrive: a new step's keys fade in (240 ms).
/// Done: no keys, `All set` with the red period.
final class KeysScene: StageScene {
    enum ID {
        static let group: LayerID = "c.group"
        static func cap(_ i: Int) -> LayerID { "c.cap\(i)" }
        static func wash(_ i: Int) -> LayerID { "c.wash\(i)" }
    }

    static let guide = 2400.0, guideLead = 600.0, arrive = 240.0
    private static let titleRole = Typography.Role.plate
    private static let doneRole = Typography.Role.title

    private struct Keycap { let depth, cap, wash: CALayer; let glyph: CATextLayer }
    private var group: CALayer?
    private var caps: [Keycap] = []
    private var caption: CATextLayer?
    private var period: CALayer?
    /// The shortcut shown (nil: none — the step has no shortcut, or all are done).
    private(set) var shortcut: Shortcut?
    private(set) var title = ""
    private(set) var done = false

    override var accessibilityLabel: String {
        guard let shortcut else { return title }
        return "Keys to press: \(ShortcutSpeech.spoken(shortcut)), \(title)"
    }

    override init() {
        super.init()
        configure(nil, title: "", done: false, force: true)
    }

    /// Shows `s` under `title`, or with `done` the closing `All set.`. Rebuilt only on a change;
    /// true if it changed.
    @discardableResult
    func configure(_ s: Shortcut?, title t: String, done d: Bool, force: Bool = false) -> Bool {
        guard force || s != shortcut || t != title || d != done else { return false }
        shortcut = s
        title = t
        done = d
        if let group { remove(group) }
        build()
        if let palette { apply(palette) }
        return true
    }

    /// The modifier of each modifier keycap, left to right (the key itself comes after them).
    private var capModifiers: [NoktaMods] {
        guard let shortcut else { return [] }
        return [NoktaMods.control, .option, .shift, .command].filter { shortcut.modifiers.contains($0) }
    }

    private func build() {
        let g = add(CALayer(), ID.group, frame: CGRect(origin: .zero, size: Self.size))
        group = g
        caps = []
        caption = nil
        period = nil
        if done {
            let role = Self.doneRole
            let w = ceil(OnboardingText.width(title, role: role))
            let y = ((Self.size.height - Typography.lineHeight(role)) / 2).rounded()
            let x = ((Self.size.width - w) / 2).rounded()
            caption = text(title, role: role, origin: CGPoint(x: x, y: y), width: w + 4, in: g)
            // The sentence's period, red, Ø 0.2 × the font size, on the baseline (as screen 2's).
            let font = Typography.font(role)
            let dot = StageDot.make(diameter: 0.2 * font.pointSize)
            let baseline = y + (Typography.lineHeight(role) + font.ascender + font.descender) / 2
            dot.position = CGPoint(x: x + w + 0.12 * font.pointSize + dot.bounds.width / 2, y: baseline - 0.1 * font.pointSize)
            dot.contentsScale = scale
            g.addSublayer(dot)
            period = dot
            return
        }
        let glyphs = capModifiers.map { $0.symbols } + (shortcut.map { [KeyNames.name(for: $0.keyCode)] } ?? [])
        let n = glyphs.count
        let size: CGFloat = n <= 3 ? 64 : (n == 4 ? 56 : 48)
        let gap: CGFloat = 12
        let width = CGFloat(n) * size + CGFloat(max(n - 1, 0)) * gap
        let top: CGFloat = 44
        let lineHeight = Typography.lineHeight(.keycap(size: 24))
        for (i, glyph) in glyphs.enumerated() {
            let x = (Self.size.width - width) / 2 + CGFloat(i) * (size + gap)
            let container = add(CALayer(), frame: CGRect(x: x, y: top, width: size, height: size + 3), in: g)
            let depth = add(CALayer(), frame: CGRect(x: 0, y: 3, width: size, height: size), in: container)
            let cap = add(CALayer(), ID.cap(i), frame: CGRect(x: 0, y: 0, width: size, height: size), in: container)
            let wash = add(CALayer(), ID.wash(i), frame: cap.bounds, in: cap)
            for l in [depth, cap, wash] { l.cornerRadius = (11 * size / 64).rounded(); l.cornerCurve = .continuous }
            cap.borderWidth = 1
            wash.opacity = 0
            let label = text(glyph, role: .keycap(size: 24), origin: CGPoint(x: 0, y: ((size - lineHeight) / 2).rounded()),
                             width: size, alignment: .center, in: cap)
            caps.append(Keycap(depth: depth, cap: cap, wash: wash, glyph: label))
        }
        let role = Self.titleRole
        let captionTop = n == 0 ? ((Self.size.height - Typography.lineHeight(role)) / 2).rounded() : top + size + 22
        caption = text(title, role: role, origin: CGPoint(x: 0, y: captionTop), width: Self.size.width, alignment: .center, in: g)
    }

    override func apply(_ p: StagePalette) {
        super.apply(p)
        for k in caps {
            k.depth.backgroundColor = p.ink3
            k.cap.backgroundColor = p.paper
            k.cap.borderColor = p.ink3
            k.wash.backgroundColor = p.inkPressed
            k.glyph.foregroundColor = p.ink
        }
        caption?.foregroundColor = done ? p.ink : p.ink2
        if let period { StageDot.apply(p, to: period) }
    }

    // MARK: timelines

    private static func s(_ v: Double) -> PoseValue { .scalar(v) }

    /// Keys up, the group shown.
    var restPose: Pose {
        var p = heldPose([])
        p[ID.group, "opacity"] = Self.s(1)
        p[ID.group, "transform.scale"] = Self.s(1)
        return p
    }

    /// The user's held modifiers on the keycaps: a cap whose modifier is down sits pressed; the key
    /// itself stays up (Snapline acts on it, it never reaches this scene).
    func heldPose(_ held: NoktaMods) -> Pose {
        var p = Pose()
        let mods = capModifiers
        for i in caps.indices {
            let down = i < mods.count && held.contains(mods[i])
            p[ID.cap(i), "transform.translation.y"] = Self.s(down ? 3 : 0)
            p[ID.wash(i), "opacity"] = Self.s(down ? 1 : 0)
        }
        return p
    }

    /// The keys press together on a loop; pose(0) == pose(2400). nil when there are no keys.
    var guideTimeline: Timeline? {
        guard !caps.isEmpty else { return nil }
        let a = Self.guideLead
        func press(_ down: Double) -> [Key] {
            [Key(0, Self.s(0)), Key(a, Self.s(0), .out), Key(a + 100, Self.s(down)), Key(a + 300, Self.s(down), .out),
             Key(a + 400, Self.s(0)), Key(Self.guide, Self.s(0))]
        }
        var tracks: [Track] = []
        for i in caps.indices {
            tracks.append(Track(ID.cap(i), "transform.translation.y", press(3)))
            tracks.append(Track(ID.wash(i), "opacity", press(1)))
        }
        var base = Pose()
        base[ID.group, "opacity"] = Self.s(1)
        base[ID.group, "transform.scale"] = Self.s(1)
        return Timeline(name: "onb.keys.guide", duration: Self.guide, restT: 0, explainT: a + 150, base: base, tracks: tracks)
    }

    /// A new step arrives: its keys fade and settle in.
    var arriveTimeline: Timeline {
        let tracks = [
            Track(ID.group, "opacity", [Key(0, Self.s(0), .out), Key(Self.arrive, Self.s(1))]),
            Track(ID.group, "transform.scale", [Key(0, Self.s(0.96), .out), Key(Self.arrive, Self.s(1))]),
        ]
        return Timeline(name: "onb.keys.arrive", duration: Self.arrive, restT: Self.arrive, explainT: Self.arrive,
                        base: heldPose([]), tracks: tracks)
    }
}
