import AppKit
import QuartzCore

/// Scene C — the practice keyboard (docs/DESIGN.md §11; design-v2-opus.md §3.6 Storyboard C). The
/// keys of the user's own shortcuts (⌃ ⌥ + arrow for the Classic set) press, and the mini window
/// settles in one step with the O5 flash at scene scale: ← left half, → right half, ↩ maximize,
/// ⌫ back where it was.
///
/// Guide: the next step to practise, a 2400 ms loop at most 3 times — keys down at 600, the window
/// lands at 700 and holds, the seam puts it back; restT 0 (keys up, the window where it is),
/// explainT 750 (keys held, the window on its target). Mirror: each real snap of the four actions
/// plays its own segment once (400 ms) from where the window is, so the scene shows what the user
/// actually did, including the size a repeated half cycles to. Held: while the user holds
/// modifiers, their keycaps sit pressed (a static pose, no motion).
final class KeysScene: StageScene {
    enum ID {
        static let flash = "c.fl."
        static func cap(_ i: Int) -> LayerID { "c.cap\(i)" }
        static func wash(_ i: Int) -> LayerID { "c.wash\(i)" }
        static func arrow(_ k: Int) -> LayerID { "c.arrow\(k)" }
    }

    static let screenRect = CGRect(x: 24, y: 27, width: 232, height: 146)
    /// Where windows tile inside the mini screen.
    static let inner = CGRect(x: 26, y: 29, width: 228, height: 142)
    static let restRect = CGRect(x: 80, y: 62, width: 120, height: 76)
    static let actions: [NoktaAction] = [.leftHalf, .rightHalf, .maximize, .restore]
    static let guide = 2400.0, guideLead = 600.0, mirror = 400.0
    /// The keys' centre (storyboard: three 48 pt keys at x 296 / 352 / 408, y 76).
    static let keysCenter = CGPoint(x: 376, y: 100)

    private let screen = CALayer()
    private var window: MiniWindow!
    /// O5 at scene scale: r 6, 3 pt line, R1 Ø 6.
    let flash = FrameLayerTree(style: .miniature(0.5, period: true))

    private struct Keycap { let container, depth, cap, wash: CALayer; let glyphs: [CATextLayer] }
    private var keys: [Keycap] = []
    private(set) var modifiers: NoktaMods = [.control, .option]
    private(set) var actionKeys = ["←", "→", "↩", "⌫"]
    /// Where the demo window is in the model pose (guide loops and mirror segments start from it).
    private(set) var windowRect = KeysScene.restRect

    /// Mirror mode (set by the owner): VoiceOver hears that the scene shows the user's own snap.
    var mirroring = false
    override var accessibilityValue: String? { mirroring ? "Showing your last shortcut" : nil }

    override var accessibilityLabel: String {
        var names: [String] = []
        if modifiers.contains(.control) { names.append("Control") }
        if modifiers.contains(.option) { names.append("Option") }
        if modifiers.contains(.shift) { names.append("Shift") }
        if modifiers.contains(.command) { names.append("Command") }
        return "Animation: \((names + ["arrow keys"]).joined(separator: " ")) move a window."
    }

    /// The modifier of each modifier keycap, left to right (the action key comes after them).
    private var capModifiers: [NoktaMods] { [NoktaMods.control, .option, .shift, .command].filter { modifiers.contains($0) } }

    override init() {
        super.init()
        add(screen, frame: Self.screenRect)
        screen.cornerRadius = 8
        screen.cornerCurve = .continuous
        screen.borderWidth = Theme.Line.miniature
        window = MiniWindow(in: self, prefix: "c.", frame: Self.restRect)
        flash.root.isGeometryFlipped = false // nested in the scene's flipped root
        root.addSublayer(flash.root)
        register(flash.layers, prefix: ID.flash)
        buildKeys()
    }

    /// Keys for the user's shortcuts: one per modifier plus the action key with one glyph per
    /// demo action. Rebuilt only when they change.
    func configure(modifiers m: NoktaMods, actionKeys glyphs: [String]) {
        guard m != modifiers || glyphs != actionKeys else { return }
        modifiers = m.isEmpty ? [.control, .option] : m
        actionKeys = glyphs
        for k in keys { remove(k.container) }
        buildKeys()
        if let palette { apply(palette) }
    }

    private func buildKeys() {
        let mods = modifiers.symbols.map(String.init)
        let n = mods.count + 1
        let size: CGFloat = n <= 3 ? 48 : (n == 4 ? 42 : 36)
        let gap: CGFloat = n <= 3 ? 8 : 6
        let radius = (9 * size / 48).rounded()
        let width = CGFloat(n) * size + CGFloat(n - 1) * gap
        let lineHeight = Typography.lineHeight(.keycap(size: 18))
        keys = (0..<n).map { i in
            let x = Self.keysCenter.x - width / 2 + CGFloat(i) * (size + gap)
            let container = add(CALayer(), frame: CGRect(x: x, y: Self.keysCenter.y - size / 2, width: size, height: size + 2))
            let depth = add(CALayer(), frame: CGRect(x: 0, y: 2, width: size, height: size), in: container)
            let cap = add(CALayer(), ID.cap(i), frame: CGRect(x: 0, y: 0, width: size, height: size), in: container)
            let wash = add(CALayer(), ID.wash(i), frame: cap.bounds, in: cap)
            for l in [depth, cap, wash] { l.cornerRadius = radius; l.cornerCurve = .continuous }
            cap.borderWidth = 1
            wash.opacity = 0
            let strings = i < mods.count ? [mods[i]] : actionKeys
            let glyphs = strings.enumerated().map { k, s in
                text(s, i < mods.count ? nil : ID.arrow(k), role: .keycap(size: 18),
                     origin: CGPoint(x: 0, y: ((size - lineHeight) / 2).rounded()), width: size, alignment: .center, in: cap)
            }
            return Keycap(container: container, depth: depth, cap: cap, wash: wash, glyphs: glyphs)
        }
        if let action = keys.last { for (k, g) in action.glyphs.enumerated() { g.opacity = k == 0 ? 1 : 0 } }
    }

    override func setScale(_ s: CGFloat) {
        super.setScale(s)
        flash.setSurface(size: StageScene.size, scale: s)
    }

    override func apply(_ p: StagePalette) {
        super.apply(p)
        screen.borderColor = p.ink3
        window.apply(p)
        for k in keys {
            k.depth.backgroundColor = p.ink3
            k.cap.backgroundColor = p.paper
            k.cap.borderColor = p.ink3
            k.wash.backgroundColor = p.inkPressed
            for g in k.glyphs { g.foregroundColor = p.ink }
        }
        if flash.size != StageScene.size { flash.setSurface(size: StageScene.size, scale: scale) }
        flash.apply(p.overlay)
    }

    // MARK: geometry

    /// Where `action` puts the demo window (the share of the mini screen it really takes,
    /// including the size a repeated half cycles to); Restore puts it back.
    static func target(_ action: NoktaAction, cycle: UInt32 = 0) -> CGRect {
        guard let f = Glyphs.unitFraction(action, cycle: cycle) else { return restRect }
        let r = inner
        return CGRect(x: r.minX + f.minX * r.width, y: r.minY + f.minY * r.height, width: f.width * r.width, height: f.height * r.height)
    }

    // MARK: timelines

    private static func s(_ v: Double) -> PoseValue { .scalar(v) }

    private var hidden: Pose {
        var p = Pose()
        p[ID.flash + FrameLayerTree.ID.shape, "opacity"] = Self.s(0)
        p[ID.flash + FrameLayerTree.ID.period, "opacity"] = Self.s(0)
        return p
    }

    /// Only the glyph of action `k` shows on the action key.
    private func glyphs(_ k: Int) -> Pose {
        var p = Pose()
        for j in Self.actions.indices { p[ID.arrow(j), "opacity"] = Self.s(j == k ? 1 : 0) }
        return p
    }

    /// One segment from `at`: the action key shows its glyph (step), the keys go down (0–100, out),
    /// the window settles at 100 (step) with the O5 flash on it (period 100–200, land; fade
    /// 160–340), the keys come up (300–400, out). `press` false (a drag or menu snap in mirror
    /// mode): no key moves — the scene does not claim a shortcut the user did not press.
    private func segment(_ k: Int, from: CGRect, to: CGRect, press: Bool, at: Double) -> [(at: Double, timeline: Timeline)] {
        var tracks = window.step(from: from, to: to, at: 100)
        if press {
            for i in keys.indices {
                tracks.append(Track(ID.cap(i), "transform.translation.y", [Key(0, Self.s(0), .out), Key(100, Self.s(2)), Key(300, Self.s(2), .out), Key(400, Self.s(0))]))
                tracks.append(Track(ID.wash(i), "opacity", [Key(0, Self.s(0), .out), Key(100, Self.s(1)), Key(300, Self.s(1), .out), Key(400, Self.s(0))]))
            }
        }
        let side = AnchorSide(action: Self.actions[k], portrait: false)
        return [
            (at, Timeline(name: "c.segment", duration: Self.mirror, base: glyphs(k), tracks: tracks)),
            (at + 100, OverlayTimelines.flash(flash, rect: to, start: side, reduceMotion: false).prefixed(ID.flash)),
        ]
    }

    /// Practice: `action`'s segment from where the window is now, on a loop — the step to try
    /// next. pose(0) == pose(2400): the seam puts the window back. nil for actions the scene has
    /// no segment for.
    func guideTimeline(_ action: NoktaAction) -> Timeline? {
        guard let k = Self.actions.firstIndex(of: action) else { return nil }
        let start = hidden.merging(window.pose(windowRect)).merging(glyphs(k))
        let parts = segment(k, from: windowRect, to: Self.target(action), press: true, at: Self.guideLead)
        func loop(_ parts: [(at: Double, timeline: Timeline)]) -> Timeline {
            Timeline.sequence(name: "onb.keys.guide", duration: Self.guide, restT: 0, explainT: Self.guideLead + 150,
                              start: start, parts: parts)
        }
        let first = loop(parts).pose(at: 0)
        return loop(parts + [(Self.guide, Timeline(name: "c.seam", duration: 0, base: first))])
    }

    /// Keys up and the window where it is: the scene between steps.
    func restingPose(_ action: NoktaAction?) -> Pose {
        let k = action.flatMap { Self.actions.firstIndex(of: $0) } ?? 0
        return hidden.merging(window.pose(windowRect)).merging(glyphs(k)).merging(heldPose([]))
    }

    /// The user's held modifiers on the keycaps: a cap whose modifier is down sits pressed.
    func heldPose(_ held: NoktaMods) -> Pose {
        var p = Pose()
        for (i, m) in capModifiers.enumerated() {
            let down = held.contains(m)
            p[ID.cap(i), "transform.translation.y"] = Self.s(down ? 2 : 0)
            p[ID.wash(i), "opacity"] = Self.s(down ? 1 : 0)
        }
        let action = keys.count - 1
        if action >= 0 {
            p[ID.cap(action), "transform.translation.y"] = Self.s(0)
            p[ID.wash(action), "opacity"] = Self.s(0)
        }
        return p
    }

    /// Mirror mode: `action`'s segment once, from where the window is now; nil for actions the
    /// scene has no segment for.
    func mirrorTimeline(_ action: NoktaAction, cycle: UInt32, press: Bool) -> Timeline? {
        guard let k = Self.actions.firstIndex(of: action) else { return nil }
        let to = Self.target(action, cycle: cycle)
        return Timeline.sequence(name: "onb.keys.mirror", duration: Self.mirror, restT: Self.mirror, explainT: Self.mirror,
                                 start: hidden.merging(window.pose(windowRect)), parts: segment(k, from: windowRect, to: to, press: press, at: 0))
    }

    /// Records where the window rests after a mirror `timeline`.
    func settled(after timeline: Timeline) {
        if case .point(let o)? = timeline.restPose[window.windowID, "position"],
           case .rect(let b)? = timeline.restPose[window.windowID, "bounds"] {
            windowRect = CGRect(origin: o, size: b.size)
        }
    }
}
