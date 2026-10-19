import AppKit
import QuartzCore

/// Scene A — drag to snap (docs/DESIGN.md §11; design-v2-opus.md §3.6 Storyboard A). Our cursor
/// drags a window by its title line to the left edge of a mini screen; the frame line draws itself
/// from that edge (O1 at scene scale), the window settles in one step, the line thickens (O4) and
/// the red period stamps at the window's inner bottom-right corner. Then the period flies into the
/// slot of the `nokta.` wordmark (special moment 1): the wordmark has no period until it lands.
///
/// Once, 2700 ms (the first 300 ms are still); restT 2700, explainT 1750 (the window held at the
/// edge, the frame complete). The flying period and the wordmark's own period are not stage layers
/// (`OnboardingLayer`): the flight crosses from the stage into the text, so the timeline names them.
final class DragScene: StageScene {
    enum ID {
        static let cursor: LayerID = "a.cursor", screen: LayerID = "a.screen", preview = "a.pv."
    }

    // Storyboard geometry (stage points).
    static let screenRect = CGRect(x: 90, y: 12, width: 300, height: 176)
    static let windowStart = CGRect(x: 226, y: 52, width: 128, height: 84)
    static let target = CGRect(x: 92, y: 14, width: 148, height: 172)
    static let stamp = CGPoint(x: 230, y: 176)
    static let duration = 2700.0, explainT = 1750.0
    /// Replay: the wordmark's period leaves first (120 ms, in), then F0.
    static let replayLead = 120.0
    /// The stamp is Ø 7 on the slot's Ø 8 period (0.2 × the 40 pt wordmark).
    static let stampScale = 7.0 / 8

    private let mask = CALayer()
    private let screen = CALayer()
    private var window: MiniWindow!
    private var cursor: CAShapeLayer!
    /// O1 + O4 at scene scale (r 6 like the window, 1.5 → 3 pt line, `.paper` colours, no period:
    /// the period that stamps is the one that flies).
    let preview = FrameLayerTree(style: .miniature(0.5, period: false))

    override var accessibilityLabel: String { "Animation: a window is dragged to the left edge and fills the left half." }

    override init() {
        super.init()
        // The window is clipped by the mini screen it crosses; the screen's edge is drawn over it,
        // the overlay's frame over both, our cursor on top.
        let r = Self.screenRect
        add(mask, frame: r)
        mask.bounds.origin = r.origin // children keep stage coordinates
        mask.masksToBounds = true
        mask.cornerRadius = 8
        mask.cornerCurve = .continuous
        window = MiniWindow(in: self, prefix: "a.", frame: Self.windowStart, parent: mask)
        add(screen, ID.screen, frame: r)
        screen.cornerRadius = 8
        screen.cornerCurve = .continuous
        screen.borderWidth = Theme.Line.miniature
        preview.root.isGeometryFlipped = false // nested in the scene's flipped root
        root.addSublayer(preview.root)
        register(preview.layers, prefix: ID.preview)
        cursor = StageCursor.make(in: self, ID.cursor, tip: CGPoint(x: 330, y: 150))
    }

    override func setScale(_ s: CGFloat) {
        super.setScale(s)
        preview.setSurface(size: StageScene.size, scale: s)
    }

    override func apply(_ p: StagePalette) {
        super.apply(p)
        screen.borderColor = p.ink3
        window.apply(p)
        StageCursor.apply(p, to: cursor)
        if preview.size != StageScene.size { preview.setSurface(size: StageScene.size, scale: scale) }
        preview.apply(p.overlay)
    }

    // MARK: timeline

    /// The whole scene. `stageOrigin` and `slot` (the wordmark period's centre) are overlay
    /// coordinates. `replay`: 120 ms of the wordmark's period leaving first.
    func timeline(stageOrigin o: CGPoint, slot: CGPoint, replay: Bool = false) -> Timeline {
        typealias L = OnboardingLayer
        func s(_ v: Double) -> PoseValue { .scalar(v) }
        func pt(_ x: CGFloat, _ y: CGFloat) -> PoseValue { .point(CGPoint(x: x, y: y)) }
        let f = preview.frame(rect: Self.target, start: .left)
        let alpha = Double(preview.palette?.scrimAlpha ?? 0)
        let held = CGRect(origin: CGPoint(x: 54, y: 96), size: Self.windowStart.size)

        var drag = window.step(from: held, to: Self.target, at: 1900)
        drag[0] = Track(window.windowID, "position", [ // follows the cursor (origin = tip − (44, 8)), then settles
            Key(0, .point(Self.windowStart.origin)), Key(930, .point(Self.windowStart.origin), .hand),
            Key(1200, pt(156, 62), .hand), Key(1500, .point(held.origin), .step), Key(1900, .point(Self.target.origin)),
        ])
        let scene = Timeline(name: "a.scene", duration: Self.duration, tracks: drag + [
            Track(window.barID, "opacity", [Key(850, s(MiniWindow.barRest), .out), Key(930, s(MiniWindow.barHeld)),
                                            Key(1900, s(MiniWindow.barHeld), .out), Key(1980, s(MiniWindow.barRest))]),
            Track(ID.cursor, "opacity", [Key(300, s(0), .out), Key(450, s(1)), Key(2000, s(1), .out), Key(2160, s(0))]),
            Track(ID.cursor, "position", [
                Key(450, pt(330, 150), .hand), Key(850, pt(270, 60)),                          // F2 to the title line
                Key(930, pt(270, 60), .hand), Key(1200, pt(200, 70), .hand), Key(1500, pt(98, 104)), // F4 drag
                Key(2000, pt(98, 104), .out), Key(2160, pt(108, 110)),                        // F9 moves off
            ]),
            Track(ID.cursor, "transform.scale", [Key(850, s(1), .out), Key(930, s(0.88)), Key(1900, s(0.88), .out), Key(1980, s(1))]),
        ])
        var hidden = Pose()
        hidden[ID.preview + FrameLayerTree.ID.shape, "opacity"] = s(0)
        hidden[ID.preview + FrameLayerTree.ID.period, "opacity"] = s(0)
        var t = Timeline.sequence(name: "onb.drag", duration: Self.duration, restT: Self.duration, explainT: Self.explainT,
                                  start: hidden, parts: [
                                      (0, scene),
                                      (1500, OverlayTimelines.entry(preview, f, reduceMotion: false).prefixed(ID.preview)),      // F5–F6
                                      (1900, OverlayTimelines.commit(preview, f, scrimFrom: alpha, reduceMotion: false).prefixed(ID.preview)), // F7–F9
                                  ])
        // F8 stamp at the inner corner, F10 flight into the wordmark's slot, F11 landing.
        let from = CGPoint(x: o.x + Self.stamp.x, y: o.y + Self.stamp.y)
        let control = CGPoint(x: (from.x + slot.x) / 2, y: (from.y + slot.y) / 2 - 48)
        t.tracks += [
            Track(L.flightPeriod, "opacity", [Key(0, s(0), .step), Key(1940, s(1), .step), Key(Self.duration, s(0))]),
            Track(L.flightPeriod, "transform.scale", [Key(1940, s(0), .land), Key(2040, s(Self.stampScale)),
                                                      Key(2200, s(Self.stampScale), .glide), Key(2600, s(1.12), .land), Key(2700, s(1))]),
            Track.arc(L.flightPeriod, "position", from: from, to: slot, control: control, t0: 2200, t1: 2600, ease: .glide),
        ]
        if replay {
            t = t.delayed(by: Self.replayLead)
            t.tracks.append(Track(L.wordmarkPeriod, "opacity", [Key(0, s(1), .in_), Key(Self.replayLead, s(0), .step),
                                                                Key(Self.replayLead + Self.duration, s(1))]))
        } else {
            t.tracks.append(Track(L.wordmarkPeriod, "opacity", [Key(0, s(0), .step), Key(Self.duration, s(1))]))
        }
        return t
    }

    /// Reduce Motion: the explain pose (window held at the edge, frame complete) and the wordmark
    /// with its period in place (§11).
    func reducedPose(stageOrigin o: CGPoint, slot: CGPoint) -> Pose {
        var p = timeline(stageOrigin: o, slot: slot).pose(at: Self.explainT)
        p[OnboardingLayer.wordmarkPeriod, "opacity"] = .scalar(1)
        p[OnboardingLayer.flightPeriod, "opacity"] = .scalar(0)
        return p
    }
}
