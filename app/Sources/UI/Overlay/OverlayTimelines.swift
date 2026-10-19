import AppKit

/// O1–O7 of docs/DESIGN.md §9 as pure `Timeline`s over a `FrameLayerTree`'s layer names. The
/// controller plays them; `tools/snapshot` draws any moment of them with `pose(at:)`; miniatures
/// (ZoneMap, onboarding scenes) use the same functions on a `.miniature` tree.
///
/// "Root fades" in the §9 table is realised on `shape` and `period` together: the plate is a
/// sibling, so an O7 label that follows a commit or flash outlives it (the layer tree's "cancel,
/// commit and flash fade the shape").
enum OverlayTimelines {
    private typealias ID = FrameLayerTree.ID
    private typealias M = Theme.Motion

    private static func s(_ v: CGFloat) -> PoseValue { .scalar(Double(v)) }
    private static func s(_ v: Double) -> PoseValue { .scalar(v) }

    /// The full, still line: both strokes complete.
    private static func fullStroke(_ p: inout Pose) {
        for id in [ID.halo, ID.line] {
            p[id, "strokeStart"] = s(0.0)
            p[id, "strokeEnd"] = s(1.0)
        }
    }

    // MARK: O1 entry

    /// Entering a zone: the scrim fades in (90 ms, out) while the line draws itself from E in both
    /// directions (`strokeStart` 0.5 → 0, `strokeEnd` 0.5 → 1, 160 ms out after 20 ms) and closes on
    /// the far side. Reduce Motion: the whole shape fades in, 100 ms linear, line complete.
    static func entry(_ tree: FrameLayerTree, _ f: FrameLayerTree.Frame, reduceMotion rm: Bool) -> Timeline {
        let alpha = Double(tree.palette?.scrimAlpha ?? 0.28)
        var base = tree.framePose(f)
        fullStroke(&base)
        base[ID.shape, "opacity"] = s(1.0)
        base[ID.scrim, "opacity"] = s(alpha)
        base[ID.period, "opacity"] = s(0.0)
        if rm {
            return Timeline(name: "ov.entry", duration: 100, base: base, tracks: [
                Track(ID.shape, "opacity", [Key(0, s(0.0), .linear), Key(100, s(1.0))]),
            ])
        }
        let t0 = M.drawDelay, t1 = M.drawDelay + M.draw
        var tracks = [Track(ID.scrim, "opacity", [Key(0, s(0.0), .out), Key(M.fade, s(alpha))])]
        for id in [ID.halo, ID.line] {
            tracks.append(Track(id, "strokeStart", [Key(t0, s(0.5), .out), Key(t1, s(0.0))]))
            tracks.append(Track(id, "strokeEnd", [Key(t0, s(0.5), .out), Key(t1, s(1.0))]))
        }
        return Timeline(name: "ov.entry", duration: t1, base: base, tracks: tracks)
    }

    // MARK: O2 zone change

    /// Keys a zone change moves (geometry only).
    static func geometryKeys(_ tree: FrameLayerTree, _ f: FrameLayerTree.Frame) -> Pose {
        var p = tree.framePose(f)
        p[ID.line, "lineWidth"] = nil
        p[ID.halo, "lineWidth"] = nil
        return p
    }

    /// The zone changed: path, scrim bounds/position (and the stroke layers' frames) glide 140 ms
    /// from what is on screen. `f` keeps the current frame's `start`, so the path interpolates
    /// element by element. The line is complete at rest (an entry still drawing is cut by the
    /// caller) and the opacities are O1's rest (an entry's fade-in keeps running). Reduce
    /// Motion: instant.
    static func move(_ tree: FrameLayerTree, to f: FrameLayerTree.Frame, from presentation: Pose, reduceMotion rm: Bool) -> Timeline {
        let target = geometryKeys(tree, f)
        var t = rm ? Timeline(name: "ov.move", duration: 0, base: target)
                   : Timeline.move(name: "ov.move", from: presentation, to: target, duration: M.move, ease: .glide)
        fullStroke(&t.base)
        t.base[ID.shape, "opacity"] = s(1.0)
        t.base[ID.scrim, "opacity"] = s(Double(tree.palette?.scrimAlpha ?? 0.28))
        t.base[ID.period, "opacity"] = s(0.0)
        return t
    }

    // MARK: O3 cancel

    /// Dropped outside every zone: the shape fades from where it is, 120 ms `in` (RM 100 linear).
    static func cancel(from presentation: Pose, reduceMotion rm: Bool) -> Timeline {
        var to = Pose()
        to[ID.shape, "opacity"] = s(0.0)
        return Timeline.move(name: "ov.cancel", from: presentation, to: to,
                             duration: rm ? M.reduced.lowerBound : M.cancel, ease: rm ? .linear : .in_)
    }

    // MARK: O4 commit

    /// The drop lands: the line thickens to the commit width and the scrim peaks at α .40
    /// (0–80 ms, out); the period stamps 0 → 1 (40–140 ms, land); shape and period fade
    /// (100–260 ms, out). Reduce Motion: the period appears unscaled and everything fades in
    /// 120 ms, linear. `scrimFrom`: the scrim's opacity on screen (an entry may still be fading in).
    static func commit(_ tree: FrameLayerTree, _ f: FrameLayerTree.Frame, scrimFrom: Double?, reduceMotion rm: Bool) -> Timeline {
        let alpha = Double(tree.palette?.scrimAlpha ?? 0.28)
        let peak = Double(tree.palette?.scrimPeakAlpha ?? 0.40)
        let widths = tree.lineWidths, hw = tree.haloWidth
        var base = tree.framePose(f)
        fullStroke(&base)
        base[ID.shape, "opacity"] = s(0.0)
        base[ID.period, "opacity"] = s(0.0)
        base[ID.period, "transform.scale"] = s(1.0)
        if rm {
            base[ID.scrim, "opacity"] = s(scrimFrom ?? alpha)
            return Timeline(name: "ov.commit", duration: 120, explainT: 0, base: base, tracks: [
                Track(ID.shape, "opacity", [Key(0, s(1.0), .linear), Key(120, s(0.0))]),
                Track(ID.period, "opacity", [Key(0, s(1.0), .linear), Key(120, s(0.0))]),
            ])
        }
        base[ID.scrim, "opacity"] = s(peak)
        base[ID.line, "lineWidth"] = s(widths.commit)
        base[ID.halo, "lineWidth"] = s(widths.commit + 2 * hw)
        return Timeline(name: "ov.commit", duration: M.commit, explainT: 140, base: base, tracks: [
            Track(ID.line, "lineWidth", [Key(0, s(f.lineWidth), .out), Key(80, s(widths.commit))]),
            Track(ID.halo, "lineWidth", [Key(0, s(f.lineWidth + 2 * hw), .out), Key(80, s(widths.commit + 2 * hw))]),
            Track(ID.scrim, "opacity", [Key(0, s(scrimFrom ?? alpha), .out), Key(80, s(peak))]),
            Track(ID.period, "transform.scale", [Key(40, s(0.0), .land), Key(40 + M.stamp, s(1.0))]),
            Track(ID.period, "opacity", [Key(0, s(1.0), .linear), Key(100, s(1.0), .out), Key(M.commit, s(0.0))]),
            Track(ID.shape, "opacity", [Key(100, s(1.0), .out), Key(M.commit, s(0.0))]),
        ])
    }

    // MARK: O5 flash

    /// Keyboard/menu snap with "Flash after snap": the frame the core read back, unfilled, the
    /// line at the commit width and complete; the period stamps (0–100 ms, land); shape and period
    /// fade 60–240 ms (out). Reduce Motion: period unscaled, fade 160 ms linear.
    static func flash(_ tree: FrameLayerTree, rect: CGRect, start: AnchorSide, reduceMotion rm: Bool) -> Timeline {
        let f = tree.frame(rect: rect, start: start, lineWidth: tree.lineWidths.commit)
        var base = tree.framePose(f)
        fullStroke(&base)
        base[ID.scrim, "opacity"] = s(0.0)
        base[ID.shape, "opacity"] = s(0.0)
        base[ID.period, "opacity"] = s(0.0)
        base[ID.period, "transform.scale"] = s(1.0)
        if rm {
            return Timeline(name: "ov.flash", duration: 160, explainT: 0, base: base, tracks: [
                Track(ID.shape, "opacity", [Key(0, s(1.0), .linear), Key(160, s(0.0))]),
                Track(ID.period, "opacity", [Key(0, s(1.0), .linear), Key(160, s(0.0))]),
            ])
        }
        return Timeline(name: "ov.flash", duration: M.flash, explainT: M.stamp, base: base, tracks: [
            Track(ID.period, "transform.scale", [Key(0, s(0.0), .land), Key(M.stamp, s(1.0))]),
            Track(ID.period, "opacity", [Key(60, s(1.0), .out), Key(M.flash, s(0.0))]),
            Track(ID.shape, "opacity", [Key(60, s(1.0), .out), Key(M.flash, s(0.0))]),
        ])
    }

    // MARK: O6 blocked

    /// `failed`: the plate shakes x ±4 pt, three half-oscillations of a sine in 180 ms; when the
    /// window's frame is known it shows as a 1.5 pt unfilled line (no period: nothing landed),
    /// fading after the shake. Reduce Motion: two opacity pulses of the plate's text (60/60 ms).
    static func blocked(_ tree: FrameLayerTree, frame rect: CGRect?, reduceMotion rm: Bool) -> Timeline {
        var base = Pose()
        var tracks: [Track] = []
        var duration = rm ? 4 * 60.0 : M.shake
        if let rect {
            let f = tree.frame(rect: rect, start: .none, lineWidth: tree.lineWidths.blocked)
            base = tree.framePose(f)
            fullStroke(&base)
            base[ID.scrim, "opacity"] = s(0.0)
            base[ID.period, "opacity"] = s(0.0)
            base[ID.shape, "opacity"] = s(0.0)
            let fadeEnd = M.shake + (rm ? M.reduced.upperBound : 240)
            tracks.append(Track(ID.shape, "opacity", [Key(0, s(1.0), .linear), Key(M.shake, s(1.0), rm ? .linear : .out), Key(fadeEnd, s(0.0))]))
            duration = max(duration, fadeEnd)
        }
        base[ID.plate, "transform.translation.x"] = s(0.0)
        base[ID.text, "opacity"] = s(1.0)
        if rm {
            tracks.append(Track(ID.text, "opacity", [0, 60, 120, 180, 240].enumerated().map { i, t in
                Key(Double(t), s(i % 2 == 0 ? 1.0 : 0.35), .linear)
            }))
        } else {
            let steps = 18
            tracks.append(Track(ID.plate, "transform.translation.x", (0...steps).map { i in
                Key(M.shake * Double(i) / Double(steps), s(4 * sin(3 * Double.pi * Double(i) / Double(steps))), .linear)
            }))
        }
        return Timeline(name: "ov.blocked", duration: duration, explainT: 0, base: base, tracks: tracks)
    }

    // MARK: O7 label

    /// The frame's layers invisible: what `FrameLayerTree.reset()` leaves.
    static var frameHidden: Pose {
        var p = Pose()
        p[ID.shape, "opacity"] = s(0.0)
        p[ID.scrim, "opacity"] = s(0.0)
        p[ID.period, "opacity"] = s(0.0)
        return p
    }

    /// The plate fades in 0–90 ms (out), holds 700 ms (blocked: 2000), fades in 160 ms (`in`).
    /// Reduce Motion: the same (it is opacity only). `plate` is `FrameLayerTree.setLabel`'s pose.
    /// The label leaves the frame to whatever owns it (a flash or commit it follows, a live
    /// preview); `hidesFrame` (no transition owns the frame) also holds it invisible.
    static func label(plate: Pose, blocked: Bool, hidesFrame: Bool = false) -> Timeline {
        let hold = blocked ? M.labelHoldBlocked : M.labelHold
        let end = M.labelIn + hold + M.labelOut
        var base = hidesFrame ? frameHidden.merging(plate) : plate
        base[ID.plate, "opacity"] = s(0.0)
        base[ID.text, "opacity"] = s(1.0)
        return Timeline(name: "ov.label", duration: end, explainT: M.labelIn, base: base, tracks: [
            Track(ID.plate, "opacity", [Key(0, s(0.0), .out), Key(M.labelIn, s(1.0), .linear),
                                        Key(M.labelIn + hold, s(1.0), .in_), Key(end, s(0.0))]),
        ])
    }

    #if NOKTA_SNAPSHOT
    /// Every overlay timeline for one frame, for the self-test (landscape and portrait sides).
    static func all(_ tree: FrameLayerTree, rect: CGRect, start: AnchorSide, reduceMotion rm: Bool) -> [Timeline] {
        let f = tree.frame(rect: rect, start: start)
        let preview = entry(tree, f, reduceMotion: rm)
        let moved = tree.frame(rect: rect.insetBy(dx: rect.width / 4, dy: 0), start: start)
        let plate = tree.setLabel("Left ⅔", center: CGPoint(x: rect.midX, y: rect.midY), within: CGRect(origin: .zero, size: tree.size))
        return [
            preview,
            move(tree, to: moved, from: geometryKeys(tree, f), reduceMotion: rm),
            cancel(from: preview.restPose, reduceMotion: rm),
            commit(tree, f, scrimFrom: nil, reduceMotion: rm),
            flash(tree, rect: rect, start: start, reduceMotion: rm),
            blocked(tree, frame: rect, reduceMotion: rm),
            blocked(tree, frame: nil, reduceMotion: rm),
            label(plate: plate, blocked: false),
            label(plate: plate, blocked: true, hidesFrame: true),
        ]
    }
    #endif
}
