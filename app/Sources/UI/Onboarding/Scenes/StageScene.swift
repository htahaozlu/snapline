import AppKit
import QuartzCore

/// Resolved colours for the onboarding's own layers — stage, scenes, progress, periods (docs/
/// DESIGN.md §4.1, §15). Static CGColors for one appearance and accessibility state; re-resolved
/// when either changes. `appearance` and `env` also resolve the miniature frames' `OverlayPalette`.
struct StagePalette {
    var appearance: NSAppearance
    var env: AccessibilityEnv.Snapshot
    var highContrast: Bool
    var ink, ink2, ink3, inkWash, paper, paperRaised, hairline, red: CGColor
    /// Pressed key fill (`ink.wash` × 2) and the highlighted list row (ink α .04, IC .10).
    var inkPressed, inkHighlight: CGColor
    /// Edge of `paper.raised` surfaces: hairline, Increase Contrast 1 pt ink (§4.1).
    var raisedEdge: CGColor
    /// Differentiate Without Color: red dots get a 1 pt ink ring (§15).
    var ringWidth: CGFloat { env.differentiateWithoutColor ? 1 : 0 }

    static func resolve(appearance: NSAppearance, env: AccessibilityEnv.Snapshot = AccessibilityEnv.shared.snapshot) -> StagePalette {
        var v = Theme.variant(for: appearance)
        if env.increaseContrast && !v.isHighContrast { v = v.isDark ? .icDark : .icLight }
        func cg(_ t: Theme.Color.Token) -> CGColor { Theme.Color.value(t, v).cgColor }
        let ink = Theme.Color.inkValue(v)
        let wash = Theme.Color.value(.inkWash, v).alphaComponent
        return StagePalette(
            appearance: appearance, env: env, highContrast: v.isHighContrast,
            ink: cg(.ink), ink2: cg(.ink2), ink3: cg(.ink3), inkWash: cg(.inkWash), paper: cg(.paper),
            paperRaised: cg(.paperRaised), hairline: cg(.hairline), red: cg(.red),
            inkPressed: ink.withAlphaComponent(wash * 2).cgColor,
            inkHighlight: ink.withAlphaComponent(v.isHighContrast ? 0.10 : 0.04).cgColor,
            raisedEdge: v.isHighContrast ? cg(.ink) : cg(.hairline))
    }

    /// The miniature frames' colours (`.paper` surface) for this appearance.
    var overlay: OverlayPalette { OverlayPalette.resolve(appearance: appearance, env: env, surface: .paper) }
}

/// A stage scene (DESIGN §11): named layers under one stage-sized root whose geometry is flipped,
/// so every coordinate is the storyboard's (points from the stage's top left). The root is what a
/// page transition fades and scales (Storyboard D); everything inside moves only through the
/// scene's timelines. No `draw(_:)`, no bitmaps except the few text layers.
class StageScene {
    static let size = CGSize(width: 480, height: 200)

    let root = CALayer()
    private(set) var layers: [LayerID: CALayer] = [:]
    private(set) var palette: StagePalette?
    private(set) var scale: CGFloat = 2

    /// VoiceOver: the stage is an image with this label (design-v2-opus.md §Erişilebilirlik).
    var accessibilityLabel: String { "" }
    /// VoiceOver value (Scene C in mirror mode).
    var accessibilityValue: String? { nil }

    init() {
        root.delegate = NoImplicitActions.shared
        root.isGeometryFlipped = true
        root.bounds = CGRect(origin: .zero, size: Self.size)
        root.position = CGPoint(x: Self.size.width / 2, y: Self.size.height / 2) // scales about the centre (D)
    }

    /// Adds `layer` to `parent` (default: the root) at `frame` (parent coordinates, anchor top
    /// left unless `anchor` is given) and names it `id` for timelines.
    @discardableResult
    func add<L: CALayer>(_ layer: L, _ id: LayerID? = nil, frame: CGRect, in parent: CALayer? = nil, anchor: CGPoint = .zero) -> L {
        layer.delegate = NoImplicitActions.shared
        layer.anchorPoint = anchor
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.minX + anchor.x * frame.width, y: frame.minY + anchor.y * frame.height)
        layer.contentsScale = scale
        (parent ?? root).addSublayer(layer)
        if let id { layers[id] = layer }
        return layer
    }

    /// Names layers created elsewhere (a `FrameLayerTree`'s) under `prefix`.
    func register(_ named: [LayerID: CALayer], prefix: String) {
        for (id, layer) in named { layers[prefix + id] = layer }
    }

    /// Takes `layer` and its sublayers out of the scene (and their names out of `layers`).
    func remove(_ layer: CALayer) {
        var gone: Set<ObjectIdentifier> = []
        func walk(_ l: CALayer) { gone.insert(ObjectIdentifier(l)); l.sublayers?.forEach(walk) }
        walk(layer)
        layers = layers.filter { !gone.contains(ObjectIdentifier($0.value)) }
        layer.removeFromSuperlayer()
    }

    /// A text layer (caption or keycap role) whose top-left is `origin`.
    func text(_ string: String, _ id: LayerID? = nil, role: Typography.Role, origin: CGPoint, width: CGFloat,
              alignment: CATextLayerAlignmentMode = .left, in parent: CALayer? = nil) -> CATextLayer {
        let t = CATextLayer()
        let font = Typography.font(role)
        t.string = string
        t.font = font
        t.fontSize = font.pointSize
        t.alignmentMode = alignment
        t.isWrapped = false
        t.truncationMode = .end
        return add(t, id, frame: CGRect(x: origin.x, y: origin.y, width: width, height: Typography.lineHeight(role)), in: parent)
    }

    /// Every layer of the scene, root included.
    var allLayers: [CALayer] {
        var out: [CALayer] = []
        func walk(_ l: CALayer) { out.append(l); l.sublayers?.forEach(walk) }
        walk(root)
        return out
    }

    func setScale(_ s: CGFloat) {
        guard s != scale else { return }
        scale = s
        for l in allLayers { l.contentsScale = s }
    }

    /// Static colours; subclasses colour their layers and call super.
    func apply(_ p: StagePalette) { palette = p }

    /// No animation anywhere in the scene, `pose` on its layers.
    func show(_ pose: Pose) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in allLayers { l.removeAllAnimations() }
        PoseApplier.set(pose, on: layers)
        CATransaction.commit()
    }
}

/// Layers outside the stage that scene timelines also move: the period that flies from the stage
/// into the text (Scene A) and the wordmark's own period, which takes over when it lands.
enum OnboardingLayer {
    static let wordmarkPeriod: LayerID = "p1.period"
    static let flightPeriod: LayerID = "top.period"
}

// MARK: - shared pieces

/// The demo window of scenes A and C: `ink.wash` fill, 1.5 pt `ink.2` edge, r 6, and a 1 pt title
/// line 16 pt below its top (ink at α .3; .62 while held).
struct MiniWindow {
    static let radius: CGFloat = 6
    static let barY: CGFloat = 16
    static let barRest = 0.3, barHeld = 0.62

    let window: CALayer
    let bar: CALayer
    let windowID: LayerID, barID: LayerID

    init(in scene: StageScene, prefix: String, frame: CGRect, parent: CALayer? = nil) {
        windowID = prefix + "win"
        barID = prefix + "bar"
        window = scene.add(CALayer(), windowID, frame: frame, in: parent)
        window.cornerRadius = Self.radius
        window.cornerCurve = .continuous
        window.borderWidth = Theme.Line.miniature
        bar = scene.add(CALayer(), barID, frame: CGRect(x: 0, y: Self.barY, width: frame.width, height: 1), in: window)
        bar.opacity = Float(Self.barRest)
    }

    func apply(_ p: StagePalette) {
        window.backgroundColor = p.inkWash
        window.borderColor = p.ink2
        bar.backgroundColor = p.ink
    }

    /// The window at `rect` (origin and size) and its title line across it.
    func pose(_ rect: CGRect) -> Pose {
        var p = Pose()
        p[windowID, "position"] = .point(rect.origin)
        p[windowID, "bounds"] = .rect(CGRect(origin: .zero, size: rect.size))
        p[barID, "bounds"] = .rect(CGRect(x: 0, y: 0, width: rect.width, height: 1))
        return p
    }

    /// Tracks that put the window at `to` in one step at `t` (DESIGN: a window settles in one step).
    func step(from: CGRect, to: CGRect, at t: Double) -> [Track] {
        [
            Track(windowID, "position", [Key(0, .point(from.origin), .step), Key(t, .point(to.origin))]),
            Track(windowID, "bounds", [Key(0, .rect(CGRect(origin: .zero, size: from.size)), .step), Key(t, .rect(CGRect(origin: .zero, size: to.size)))]),
            Track(barID, "bounds", [Key(0, .rect(CGRect(x: 0, y: 0, width: from.width, height: 1)), .step), Key(t, .rect(CGRect(x: 0, y: 0, width: to.width, height: 1)))]),
        ]
    }
}

/// Nokta's own arrow (DESIGN §11, design-v2-opus.md §3.6): 12 × 18, tip at (0, 0), `ink` fill with a
/// 1 pt `paper.raised` outline. Not the system cursor. Anchored at the tip, so a press scales
/// around the point it presses.
enum StageCursor {
    static let size = CGSize(width: 12, height: 18)

    static var path: CGPath {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 15), CGPoint(x: 4, y: 11.5), CGPoint(x: 7, y: 18),
                             CGPoint(x: 9.5, y: 17), CGPoint(x: 6.5, y: 10.5), CGPoint(x: 11.5, y: 10.5)])
        p.closeSubpath()
        return p
    }

    static func make(in scene: StageScene, _ id: LayerID, tip: CGPoint) -> CAShapeLayer {
        let c = scene.add(CAShapeLayer(), id, frame: CGRect(origin: tip, size: size))
        c.path = path
        c.lineWidth = 1
        c.lineJoin = .round
        return c
    }

    static func apply(_ p: StagePalette, to c: CAShapeLayer) {
        c.fillColor = p.ink
        c.strokeColor = p.paperRaised
    }
}

/// A round dot layer (the R1/R4/R6 periods): `diameter`, centred on its position.
enum StageDot {
    static func make(diameter d: CGFloat) -> CALayer {
        let dot = CALayer()
        dot.delegate = NoImplicitActions.shared
        dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        dot.cornerRadius = d / 2
        return dot
    }

    /// Red with the Differentiate Without Color ring (or ink without one, `red: false`).
    static func apply(_ p: StagePalette, to dot: CALayer, red: Bool = true) {
        dot.backgroundColor = red ? p.red : p.ink
        dot.borderColor = p.ink
        dot.borderWidth = red ? p.ringWidth : 0
    }
}
