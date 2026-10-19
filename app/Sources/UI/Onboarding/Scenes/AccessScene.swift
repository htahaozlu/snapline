import AppKit
import QuartzCore

/// Scene B — the permission switch (docs/DESIGN.md §11; design-v2-opus.md §3.6 Storyboard B). An
/// abstract `Privacy & Security › Accessibility` list: two placeholder rows and a highlighted Nokta
/// row whose switch our cursor turns on. Drawn from our own shapes — no Apple screenshot, glyph or
/// control; the switch is a picture, not a control.
///
/// Waiting: a 3200 ms loop, at most 3 times plus the tail to restT, only while the screen waits for
/// access; restT = explainT = 1500 (switch on, cursor on it). Granted: the switch stays on and the
/// cursor leaves (`granted`, 2600 ms, rest = the static granted picture).
final class AccessScene: StageScene {
    enum ID {
        static let cursor: LayerID = "b.cursor", knob: LayerID = "b.knob", fill: LayerID = "b.fill"
    }

    static let panelRect = CGRect(x: 90, y: 18, width: 300, height: 164)
    static let rowYs: [CGFloat] = [54, 94, 134]
    static let rowHeight: CGFloat = 40
    static let track = CGRect(x: 340, y: 106, width: 28, height: 16)
    static let knobOff = CGPoint(x: 348, y: 114), knobOn = CGPoint(x: 360, y: 114)
    static let cursorStart = CGPoint(x: 372, y: 176), cursorOnSwitch = CGPoint(x: 354, y: 114)
    static let loop = 3200.0, explainT = 1500.0, grantedDuration = 2600.0

    private let panel = CALayer()
    private let separator = CALayer()
    private var placeholders: [CALayer] = []
    private let highlight = CALayer()
    private var header: CATextLayer!
    private var name: CATextLayer!
    private let mark = CALayer()
    private let markFrame = CAShapeLayer(), markFill = CAShapeLayer(), markDot = CAShapeLayer()
    private let trackLayer = CALayer(), fill = CALayer(), knob = CALayer()
    private var cursor: CAShapeLayer!

    override var accessibilityLabel: String { "Animation: the \(Product.name) switch turns on in Privacy & Security, Accessibility." }

    override init() {
        super.init()
        let pr = Self.panelRect
        add(panel, frame: pr)
        panel.cornerRadius = Theme.Radius.medium
        panel.cornerCurve = .continuous
        panel.borderWidth = 1
        header = text("Privacy & Security › Accessibility", role: .caption, origin: CGPoint(x: 104, y: 26), width: pr.width - 28)
        add(separator, frame: CGRect(x: pr.minX, y: 46, width: pr.width, height: 1))
        add(highlight, frame: CGRect(x: pr.minX + 1, y: Self.rowYs[1], width: pr.width - 2, height: Self.rowHeight))
        for y in [Self.rowYs[0], Self.rowYs[2]] {
            let icon = add(CALayer(), frame: CGRect(x: 104, y: y + 10, width: 20, height: 20))
            icon.cornerRadius = 5
            let bar = add(CALayer(), frame: CGRect(x: 134, y: y + 17, width: 80, height: 6))
            bar.cornerRadius = 3
            placeholders += [icon, bar]
        }
        // Nokta's row: the mark (`▮▯.`, the menu bar icon's geometry, ink — the screen's red is R4)
        // and the name.
        add(mark, frame: CGRect(x: 104, y: 105, width: 18, height: 18))
        let g = Glyphs.StatusGeometry.make(onePixel: false, highContrast: false)
        for l in [markFrame, markFill, markDot] { add(l, frame: CGRect(x: 0, y: 0, width: 18, height: 18), in: mark) }
        markFrame.path = CGPath(roundedRect: g.frame, cornerWidth: g.radius, cornerHeight: g.radius, transform: nil)
        markFrame.lineWidth = g.line
        markFrame.fillColor = nil
        markFill.path = markFrame.path // filled, then cut at the half like the menu bar icon
        let half = CALayer()
        half.frame = CGRect(x: 0, y: 0, width: g.fillMaxX, height: 18)
        half.backgroundColor = CGColor(gray: 0, alpha: 1)
        markFill.mask = half
        markDot.path = CGPath(ellipseIn: CGRect(x: g.periodCenter.x - 1.5, y: g.periodCenter.y - 1.5, width: 3, height: 3), transform: nil)
        name = text(Product.name, role: .caption, origin: CGPoint(x: 130, y: 107), width: 120)
        // The switch picture: track 28 × 16 r 8 with a 1 pt edge; filled ink when on; knob Ø 12.
        add(trackLayer, frame: Self.track)
        trackLayer.cornerRadius = 8
        trackLayer.borderWidth = 1
        add(fill, ID.fill, frame: Self.track)
        fill.cornerRadius = 8
        add(knob, ID.knob, frame: CGRect(x: Self.knobOff.x - 6, y: Self.knobOff.y - 6, width: 12, height: 12), anchor: CGPoint(x: 0.5, y: 0.5))
        knob.cornerRadius = 6
        knob.borderWidth = 1
        cursor = StageCursor.make(in: self, ID.cursor, tip: Self.cursorStart)
    }

    override func apply(_ p: StagePalette) {
        super.apply(p)
        panel.backgroundColor = p.paper
        panel.borderColor = p.raisedEdge
        separator.backgroundColor = p.hairline
        header.foregroundColor = p.ink2
        highlight.backgroundColor = p.inkHighlight
        for l in placeholders { l.backgroundColor = p.inkWash }
        markFrame.strokeColor = p.ink
        markFill.fillColor = p.ink
        markDot.fillColor = p.ink
        name.foregroundColor = p.ink
        trackLayer.borderColor = p.ink3
        fill.backgroundColor = p.ink
        knob.backgroundColor = p.paperRaised
        knob.borderColor = p.ink3
        StageCursor.apply(p, to: cursor)
    }

    // MARK: timelines

    private static func s(_ v: Double) -> PoseValue { .scalar(v) }

    /// The waiting loop: F1 cursor appears · F2 moves to the switch · F3 press · F4 the switch turns
    /// on (knob +12, fill) · F5 holds (explainT) · F6 cursor leaves · F7 the switch turns off · F8.
    /// pose(0) == pose(3200), so three loops join without a seam.
    static var waiting: Timeline {
        Timeline(name: "onb.access", duration: loop, restT: explainT, explainT: explainT, tracks: [
            Track(ID.cursor, "opacity", [Key(0, s(0), .out), Key(150, s(1)), Key(2400, s(1), .out), Key(2600, s(0))]),
            Track(ID.cursor, "position", [Key(150, .point(cursorStart), .hand), Key(750, .point(cursorOnSwitch)),
                                          Key(2600, .point(cursorOnSwitch), .step), Key(loop, .point(cursorStart))]),
            Track(ID.cursor, "transform.scale", [Key(750, s(1), .out), Key(830, s(0.88), .out), Key(910, s(1))]),
            Track(ID.knob, "position", [Key(830, .point(knobOff), .out), Key(1030, .point(knobOn)),
                                        Key(2700, .point(knobOn), .hand), Key(3000, .point(knobOff))]),
            Track(ID.fill, "opacity", [Key(830, s(0), .out), Key(1030, s(1)), Key(2700, s(1), .hand), Key(3000, s(0))]),
        ])
    }

    /// Access granted: F0–F6 once, the switch stays on. Its rest pose is the static granted picture.
    static var granted: Timeline {
        Timeline(name: "onb.access.granted", duration: grantedDuration, explainT: grantedDuration, tracks: [
            Track(ID.cursor, "opacity", [Key(0, s(0), .out), Key(150, s(1)), Key(2400, s(1), .out), Key(2600, s(0))]),
            Track(ID.cursor, "position", [Key(150, .point(cursorStart), .hand), Key(750, .point(cursorOnSwitch))]),
            Track(ID.cursor, "transform.scale", [Key(750, s(1), .out), Key(830, s(0.88), .out), Key(910, s(1))]),
            Track(ID.knob, "position", [Key(830, .point(knobOff), .out), Key(1030, .point(knobOn))]),
            Track(ID.fill, "opacity", [Key(830, s(0), .out), Key(1030, s(1))]),
        ])
    }
}
