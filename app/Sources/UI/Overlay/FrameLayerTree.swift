import AppKit
import QuartzCore

/// The frame layer tree (docs/DESIGN.md §9): eight layers, no bitmaps (the plate text is a glyph path).
///
///     root (flipped, surface-sized, hidden at rest; `reset()` leaves shape, period and plate transparent)
///      ├─ shape            container; cancel, commit and flash fade it
///      │   ├─ scrim  CALayer       ov.scrim fill, cornerRadius r.overlay, cornerCurve .continuous
///      │   ├─ halo   CAShapeLayer  the line's path, lineWidth line.w + 2, stroke ov.halo
///      │   └─ line   CAShapeLayer  the target's path (FrameGeometry contract), lineWidth line.w
///      ├─ period    CALayer       Ø 8 red (R1), round; Differentiate Without Color: 1.5 pt ink ring
///      └─ plate     CALayer       plate.fill pill (Increase Contrast: 1 pt paper edge)
///          └─ text  CAShapeLayer  SF Semibold 15 glyph outlines (GlyphPath), plate.text fill
///
/// Only small layers carry content: the scrim is a filled CALayer, and the two shape layers are
/// sized to the target (plus a 4 pt margin for the stroke), never to the screen. Timelines move
/// only `strokeStart/End`, `path`, `bounds`, `position`, `opacity`, `lineWidth` and `transform`.
///
/// **Reuse at a smaller scale (`FrameStyle`).** The same tree draws the drag overlay
/// (`FrameStyle.overlay`) and every miniature — the ZoneMap result zone and the onboarding scenes
/// (`FrameStyle.miniature(scale, period:)`): `scale` multiplies the overlay's corner radius, period
/// inset and small-side rule (the period stays Ø 6–8, lines stay whole pixels), and `.paper`
/// colours apply (`ink.wash` fill, 1.5 pt ink line, no halo). Timelines for both come from
/// `OverlayTimelines`, so a miniature moves exactly like the overlay. Typical use:
///
///     let tree = FrameLayerTree(style: .miniature(0.25, period: true))
///     tree.setSurface(size: bounds.size, scale: window.backingScaleFactor)
///     tree.apply(OverlayPalette.resolve(appearance: effectiveAppearance, surface: .paper))
///     let frame = tree.frame(rect: target, start: AnchorSide(fraction: f))
///     tree.play([OverlayTimelines.entry(tree, frame, reduceMotion: rm)])
struct FrameStyle: Equatable {
    /// Geometry relative to the overlay (1 = overlay).
    var scale: CGFloat
    var surface: OverlayPalette.Surface
    /// Whether the period (R1) may appear. Settings miniatures show no red (§4.2).
    var showsPeriod: Bool

    static let overlay = FrameStyle(scale: 1, surface: .screen, showsPeriod: true)

    static func miniature(_ scale: CGFloat, period: Bool = false) -> FrameStyle {
        FrameStyle(scale: min(max(scale, 0.05), 1), surface: .paper, showsPeriod: period)
    }

    private var isOverlay: Bool { surface == .screen && scale >= 1 }

    /// r.overlay, scaled (≥ 2 pt).
    var cornerRadius: CGFloat {
        isOverlay ? Theme.Radius.overlay : max(2, (Theme.Radius.overlay * scale * 2).rounded() / 2)
    }

    /// Ø 8 on the overlay, Ø 6–7 in scenes (§4.2 R1).
    var periodDiameter: CGFloat {
        isOverlay ? 8 : min(8, max(6, (8 * scale * 2).rounded() / 2))
    }

    /// Distance of the period's centre from the bottom-trailing corner (14 pt on the overlay).
    var periodInset: CGFloat {
        isOverlay ? 14 : max(periodDiameter / 2 + 4, (14 * scale).rounded())
    }

    /// Below this short side the period sits in the centre (64 pt on the overlay).
    var periodMinSide: CGFloat { isOverlay ? 64 : 64 * scale }

    /// Plate metrics (§9 O7): 32 pt high, 14 pt side padding, 8 pt from the visible edges.
    var plateHeight: CGFloat { 32 }
    var platePadding: CGFloat { 14 }
    var plateInset: CGFloat { 8 }
}

/// Disables implicit actions on standalone layers (every change is explicit, DESIGN §5.2).
final class NoImplicitActions: NSObject, CALayerDelegate {
    static let shared = NoImplicitActions()
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

final class FrameLayerTree {
    /// Layer names used by timelines.
    enum ID {
        static let root: LayerID = "root", shape: LayerID = "shape", scrim: LayerID = "scrim"
        static let halo: LayerID = "halo", line: LayerID = "line", period: LayerID = "period"
        static let plate: LayerID = "plate", text: LayerID = "text"
    }

    /// One placed frame: the target rect on the pixel grid, the side the line grows from (the path
    /// starts opposite it) and the line width in device-rounded points.
    struct Frame: Equatable {
        var rect: CGRect
        var start: AnchorSide
        var lineWidth: CGFloat
    }

    let root = CALayer()
    let shape = CALayer()
    let scrim = CALayer()
    let halo = CAShapeLayer()
    let line = CAShapeLayer()
    let period = CALayer()
    let plate = CALayer()
    let text = CAShapeLayer()

    /// Name → layer, for `PoseApplier`.
    let layers: [LayerID: CALayer]
    var allLayers: [CALayer] { [root, shape, scrim, halo, line, period, plate, text] }

    var style: FrameStyle { didSet { if let palette { apply(palette) } } }
    private(set) var size: CGSize = .zero
    private(set) var scale: CGFloat = 2
    private(set) var palette: OverlayPalette?
    /// Last frame shown; a zone change keeps its `start` so `path` interpolates (§9 O2).
    var current: Frame?

    /// Room around the target inside the shape layers' bounds (commit width + halo).
    static let strokeMargin: CGFloat = 4

    init(style: FrameStyle = .overlay) {
        self.style = style
        layers = [ID.root: root, ID.shape: shape, ID.scrim: scrim, ID.halo: halo, ID.line: line,
                  ID.period: period, ID.plate: plate, ID.text: text]
        for l in allLayers { l.delegate = NoImplicitActions.shared }
        root.isGeometryFlipped = true
        for l in [root, shape, scrim, halo, line, plate, text] { l.anchorPoint = .zero }
        scrim.cornerCurve = .continuous
        for s in [halo, line] {
            s.fillColor = nil
            s.lineCap = .butt
            s.lineJoin = .round
        }
        plate.cornerCurve = .circular
        text.lineWidth = 0
        text.strokeColor = nil
        root.addSublayer(shape)
        shape.addSublayer(scrim)
        shape.addSublayer(halo)
        shape.addSublayer(line)
        root.addSublayer(period)
        root.addSublayer(plate)
        plate.addSublayer(text)
        reset()
    }

    // MARK: surface & colours

    func setSurface(size: CGSize, scale: CGFloat) {
        self.size = size
        self.scale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in allLayers { l.contentsScale = scale }
        root.position = .zero
        root.bounds = CGRect(origin: .zero, size: size)
        shape.position = .zero
        shape.bounds = root.bounds
        CATransaction.commit()
        if let palette { apply(palette) }
    }

    /// Device width of a line in points.
    func device(_ w: CGFloat) -> CGFloat { Theme.Line.device(w, scale: scale) }
    var haloWidth: CGFloat { device(palette?.haloWidth ?? Theme.Line.halo) }
    var periodRingWidth: CGFloat { palette?.periodRing == nil ? 0 : device(Theme.Line.periodRing) }
    var periodDiameter: CGFloat { style.periodDiameter + 2 * periodRingWidth }

    /// Line widths for this surface: preview, commit/flash (grown by whole pixels), blocked.
    var lineWidths: (preview: CGFloat, commit: CGFloat, blocked: CGFloat) {
        let p = palette
        let base = device(p?.lineWidth ?? Theme.Line.overlay(highContrast: false))
        let commit = Theme.Line.grown(base, to: p?.commitLineWidth ?? Theme.Line.commit(highContrast: false), scale: scale)
        return (base, commit, device(p?.blockedLineWidth ?? Theme.Line.blocked(highContrast: false)))
    }

    /// Static colours and sizes (no animation). Re-places the current frame (widths may change
    /// with Increase Contrast).
    func apply(_ p: OverlayPalette) {
        palette = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.backgroundColor = p.scrim
        line.strokeColor = p.line
        halo.strokeColor = p.halo
        halo.isHidden = p.halo == nil
        let d = periodDiameter
        period.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        period.cornerRadius = d / 2
        period.backgroundColor = p.period
        period.borderColor = p.periodRing
        period.borderWidth = periodRingWidth
        period.isHidden = !style.showsPeriod
        plate.backgroundColor = p.plateFill
        plate.borderColor = p.plateEdge
        plate.borderWidth = p.plateEdge == nil ? 0 : 1
        text.fillColor = p.plateText
        if let f = current { PoseApplier.set(framePose(f), on: layers) } // halo width follows the ring/scale
        CATransaction.commit()
    }

    // MARK: geometry → pose

    /// A frame for `rect` (snapped to this surface's pixels). `lineWidth` defaults to the preview line.
    func frame(rect: CGRect, start: AnchorSide, lineWidth: CGFloat? = nil) -> Frame {
        Frame(rect: FrameGeometry.snap(rect, scale: scale), start: start, lineWidth: lineWidth ?? lineWidths.preview)
    }

    /// Geometry of a frame: scrim rect and radius, the stroke layers' bounds and path, line and halo
    /// widths, the period's centre. The path is inset by half the line so the line's outer edge is
    /// the target's edge; the halo extends `haloWidth` beyond it on both sides.
    func framePose(_ f: Frame) -> Pose {
        var p = Pose()
        let r = f.rect
        let rad = FrameGeometry.radius(style.cornerRadius, fitting: r)
        p[ID.scrim, "position"] = .point(r.origin)
        p[ID.scrim, "bounds"] = .rect(CGRect(origin: .zero, size: r.size))
        p[ID.scrim, "cornerRadius"] = .scalar(Double(rad))
        let m = Self.strokeMargin, w = f.lineWidth
        let local = CGRect(x: m + w / 2, y: m + w / 2, width: max(0, r.width - w), height: max(0, r.height - w))
        let path = FrameGeometry.path(rect: local, radius: max(0, rad - w / 2), start: f.start)
        for id in [ID.halo, ID.line] {
            p[id, "position"] = .point(CGPoint(x: r.minX - m, y: r.minY - m))
            p[id, "bounds"] = .rect(CGRect(x: 0, y: 0, width: r.width + 2 * m, height: r.height + 2 * m))
            p[id, "path"] = .path(path)
        }
        p[ID.line, "lineWidth"] = .scalar(Double(w))
        p[ID.halo, "lineWidth"] = .scalar(Double(w + 2 * haloWidth))
        let c = FrameGeometry.periodCenter(rect: r, inset: style.periodInset, minSide: style.periodMinSide)
        let d = periodDiameter
        p[ID.period, "position"] = .point(CGPoint(x: Theme.Line.snap(c.x - d / 2, scale: scale) + d / 2,
                                                  y: Theme.Line.snap(c.y - d / 2, scale: scale) + d / 2))
        return p
    }

    /// E for a frame (where the line starts growing), in surface coordinates.
    func entryPoint(_ f: Frame) -> CGPoint {
        let rad = FrameGeometry.radius(style.cornerRadius, fitting: f.rect)
        return FrameGeometry.entryPoint(rect: f.rect.insetBy(dx: f.lineWidth / 2, dy: f.lineWidth / 2),
                                        radius: max(0, rad - f.lineWidth / 2), side: f.start)
    }

    // MARK: label plate

    /// Lays the plate out around `text`, centred on `center` and kept `plateInset` inside `bounds`
    /// (the screen's visible frame: never in the notch band). Sets the string; returns the plate's
    /// geometry as a pose (its opacity belongs to the O7 timeline).
    @discardableResult
    func setLabel(_ string: String, center: CGPoint, within bounds: CGRect) -> Pose {
        let maxText = max(0, bounds.width - 2 * style.plateInset - 2 * style.platePadding)
        let glyphs = GlyphPath.line(string, font: Typography.plate, maxWidth: maxText)
        let tw = min(glyphs.width, maxText)
        let size = CGSize(width: tw + 2 * style.platePadding, height: style.plateHeight)
        let frame = FrameGeometry.place(size, center: center, within: bounds, inset: style.plateInset, scale: scale)
        let lineHeight = glyphs.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.path = glyphs.path
        plate.cornerRadius = Theme.Radius.pill(height: size.height)
        plate.isHidden = false
        CATransaction.commit()
        var p = Pose()
        p[ID.plate, "position"] = .point(frame.origin)
        p[ID.plate, "bounds"] = .rect(CGRect(origin: .zero, size: size))
        p[ID.text, "position"] = .point(CGPoint(x: style.platePadding, y: Theme.Line.snap((size.height - lineHeight) / 2, scale: scale)))
        p[ID.text, "bounds"] = .rect(CGRect(x: 0, y: 0, width: tw, height: lineHeight))
        return p
    }

    /// Drops the plate's text path and hides it.
    func clearLabel() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.removeAllAnimations()
        text.removeAllAnimations()
        text.path = nil
        plate.isHidden = true
        CATransaction.commit()
    }

    // MARK: playback

    /// Rest poses, then animations, in one CATransaction (DESIGN §5.2 rules 2–3).
    func play(_ timelines: [Timeline], loops: Int = 1, delay: Double = 0, completion: (() -> Void)? = nil) {
        PoseApplier.play(timelines, on: layers, loops: loops, delay: delay, completion: completion)
    }

    #if NOKTA_SNAPSHOT
    /// Draws one moment of a timeline without animating (snapshots, Reduce Motion `explainT`).
    func show(_ timeline: Timeline, at t: Double) {
        PoseApplier.apply(timeline.pose(at: t), to: layers)
    }
    #endif

    func presentationPose(like template: Pose) -> Pose {
        PoseApplier.presentationPose(like: template, in: layers)
    }

    /// No animation anywhere and nothing visible (call after orderOut): the frame is transparent
    /// and has no line, so a later transition that only shows the plate (O7, O6 without a known
    /// frame) can never reveal the last frame. Every timeline that shows the frame sets its own
    /// geometry and opacities.
    func reset() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in allLayers { l.removeAllAnimations() }
        shape.opacity = 0
        scrim.opacity = 0
        for s in [halo, line] { s.path = nil; s.strokeStart = 0; s.strokeEnd = 1 }
        period.opacity = 0
        period.setValue(1, forKeyPath: "transform.scale")
        plate.opacity = 0
        plate.setValue(0, forKeyPath: "transform.translation.x")
        text.opacity = 1
        CATransaction.commit()
    }

    #if NOKTA_SNAPSHOT
    /// True when no layer has a running animation (DESIGN §17.3).
    var isIdle: Bool { allLayers.allSatisfy { ($0.animationKeys() ?? []).isEmpty } }
    #endif
}
