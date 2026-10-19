import AppKit
import QuartzCore

// SelfTest — the motion contract checks of docs/DESIGN.md §5.2 rule 9, run by scripts/snapshot.sh
// before anything is rendered (`nokta-snapshot --self-test`; a failure exits non-zero):
//   * Ease.y equals the Core Animation control-point curve at known samples (± 1e-4),
//   * pose(0) and pose(duration) of every Timeline equal the expected key values,
//   * looping demos have pose(0) == pose(duration) and finite repeat groups plus a tail
//     (none when restT is 0 or the full duration: no extra loop),
//   * animations(...): keyTimes.count == values.count, timingFunctions.count == segments,
//     keyTimes rising within 0…1, and the keyframes sample to the same values as pose(at:),
//   * every opacity stays within 0…1,
//   * the overlay path has the same elements for every AnchorSide, landscape and portrait,
//   * FrameLayerTree.reset() leaves the frame invisible and every timeline that places a frame
//     sets its own opacities; a plate-only label never raises the frame,
//   * the real SnapOverlayController's sequences (OverlayFrames.sequences, headless surfaces)
//     never show a stale frame under a plate, a drop mid-entry lands on a complete line, and
//     every transition ends with no animation and the root hidden (§17.3).
// No window: animations are only added to layer trees that are never on screen.

enum SelfTest {
    private static var failures: [String] = []
    private static var checks = 0

    private static func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        checks += 1
        if !ok { failures.append(what()) }
    }

    private static func close(_ a: PoseValue?, _ b: PoseValue?, _ eps: Double = 1e-6) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        switch (a, b) {
        case let (.scalar(x), .scalar(y)): return abs(x - y) <= eps
        case let (.point(p), .point(q)): return abs(p.x - q.x) <= eps && abs(p.y - q.y) <= eps
        case let (.size(p), .size(q)): return abs(p.width - q.width) <= eps && abs(p.height - q.height) <= eps
        case let (.rect(p), .rect(q)):
            return abs(p.minX - q.minX) <= eps && abs(p.minY - q.minY) <= eps && abs(p.width - q.width) <= eps && abs(p.height - q.height) <= eps
        case let (.path(p), .path(q)):
            let ep = PathElements.elements(p), eq = PathElements.elements(q)
            guard ep.count == eq.count else { return false }
            return zip(ep, eq).allSatisfy { x, y in
                x.type == y.type && zip(x.points, y.points).allSatisfy { abs($0.x - $1.x) <= eps && abs($0.y - $1.y) <= eps }
            }
        default: return a == b
        }
    }

    // MARK: Ease

    /// Independent reference: the parametric curve sampled densely, x → y by linear interpolation.
    private static func reference(_ e: Ease, _ x: Double) -> Double {
        guard let (x1, y1, x2, y2) = e.controlPoints else { return e.y(x) }
        let n = 200_000
        var prevX = 0.0, prevY = 0.0
        for i in 1...n {
            let t = Double(i) / Double(n)
            let bx = Ease.bezier(t, x1, x2), by = Ease.bezier(t, y1, y2)
            if bx >= x {
                let f = bx - prevX > 0 ? (x - prevX) / (bx - prevX) : 0
                return prevY + (by - prevY) * f
            }
            prevX = bx; prevY = by
        }
        return 1
    }

    private static func testEase() {
        for e in [Ease.out, .in_, .glide, .land, .hand] {
            guard let cp = e.controlPoints else { continue }
            // The CA function carries exactly these control points.
            var p1 = [Float](repeating: 0, count: 2), p2 = [Float](repeating: 0, count: 2)
            e.timingFunction.getControlPoint(at: 1, values: &p1)
            e.timingFunction.getControlPoint(at: 2, values: &p2)
            expect(abs(Double(p1[0]) - cp.0) < 1e-6 && abs(Double(p1[1]) - cp.1) < 1e-6
                   && abs(Double(p2[0]) - cp.2) < 1e-6 && abs(Double(p2[1]) - cp.3) < 1e-6, "\(e): CA control points")
            for i in 0...40 {
                let x = Double(i) / 40
                let y = e.y(x), r = reference(e, x)
                expect(abs(y - r) <= 1e-4, "\(e).y(\(x)) = \(y), reference \(r)")
            }
            expect(e.y(0) == 0 && e.y(1) == 1, "\(e): ends")
        }
        expect(abs(Ease.hand.y(0.5) - 0.5) < 1e-9, "hand is symmetric: y(0.5) = 0.5")
        let peak = (0...1000).map { Ease.land.y(Double($0) / 1000) }.max() ?? 0
        // DESIGN §5.1 calls it "≈ 6 %"; the binding control points (.34, 1.32, .64, 1) peak at 1.034.
        expect(peak > 1.03 && peak < 1.04, "land overshoots (max \(peak))")
        expect(Ease.step.y(0.999) == 0 && Ease.step.y(1) == 1, "step holds until the end")
        expect(Ease.linear.y(0.37) == 0.37, "linear")
    }

    // MARK: keyframes

    /// Samples CA keyframes the way Core Animation evaluates them (keyTimes, per-segment
    /// timing functions, linear or discrete calculation).
    private static func sample(_ k: Timeline.Keyframes, _ u: Double) -> PoseValue {
        if k.discrete {
            var v = k.values[0]
            for (i, kt) in k.keyTimes.enumerated() where kt <= u { v = k.values[i] }
            return v
        }
        if u <= k.keyTimes[0] { return k.values[0] }
        for i in 0..<(k.values.count - 1) {
            let a = k.keyTimes[i], b = k.keyTimes[i + 1]
            guard u >= a, u < b else { continue }
            return PoseValue.lerp(k.values[i], k.values[i + 1], k.eases[i].y((u - a) / (b - a)))
        }
        return k.values[k.values.count - 1]
    }

    private static func isOpacity(_ keyPath: String) -> Bool { keyPath == "opacity" }

    /// Generic checks for one timeline.
    private static func testTimeline(_ t: Timeline, looping: Bool = false) {
        let n = t.name
        expect(t.restT >= 0 && t.restT <= t.duration + 1e-9, "\(n): restT inside the timeline")
        expect(t.explainT >= 0 && t.explainT <= t.duration + 1e-9, "\(n): explainT inside the timeline")
        expect(t.pose(at: t.restT) == t.restPose, "\(n): restPose")
        for (key, value) in t.base.values where isOpacity(key.keyPath) {
            expect((0...1).contains(value.scalarValue ?? -1), "\(n): base \(key.layer).opacity in 0…1")
        }
        for track in t.tracks {
            let id = "\(n) \(track.layer).\(track.keyPath)"
            guard let first = track.keys.first, let last = track.keys.last else { expect(false, "\(id): empty track"); continue }
            expect(close(t.pose(at: 0)[track.layer, track.keyPath], first.value), "\(id): pose(0) = first key")
            expect(close(t.pose(at: t.duration)[track.layer, track.keyPath], last.value), "\(id): pose(duration) = last key")
            expect(zip(track.keys, track.keys.dropFirst()).allSatisfy { $0.t <= $1.t }, "\(id): keys sorted")
            expect(track.keys.allSatisfy { $0.t >= 0 && $0.t <= t.duration + 1e-9 }, "\(id): keys inside the timeline")
            if isOpacity(track.keyPath) {
                expect(track.keys.allSatisfy { (0...1).contains($0.value.scalarValue ?? -1) }, "\(id): opacity in 0…1")
            }
            let k = t.keyframes(for: track)
            expect(k.keyTimes.count == k.values.count, "\(id): keyTimes \(k.keyTimes.count) ≠ values \(k.values.count)")
            expect(k.eases.count == k.values.count - 1, "\(id): timing functions \(k.eases.count) ≠ segments \(k.values.count - 1)")
            expect(zip(k.keyTimes, k.keyTimes.dropFirst()).allSatisfy { $0 <= $1 }, "\(id): keyTimes rising")
            expect(k.keyTimes.first == 0 && k.keyTimes.last == 1, "\(id): keyTimes span 0…1")
            let ca = t.keyframeAnimation(for: track)
            expect(ca.keyTimes?.count == ca.values?.count && ca.timingFunctions?.count == (ca.values?.count ?? 0) - 1,
                   "\(id): CAKeyframeAnimation counts")
            expect(ca.isRemovedOnCompletion && ca.fillMode != .forwards && ca.fillMode != .both, "\(id): no hanging fill")
            // One source: the CA keyframes sample to pose(at:).
            for i in 0...200 {
                let ms = t.duration * Double(i) / 200
                let a = sample(k, t.duration > 0 ? ms / t.duration : 0), b = track.value(at: ms)
                if !close(a, b, 1e-4) { expect(false, "\(id): keyframes ≠ pose at \(ms) ms"); break }
            }
        }
        for loops in [1, 3] {
            for item in t.animations(begin: 0, loops: loops) {
                let rc = item.animation.repeatCount
                expect(rc.isFinite && rc <= Float(Theme.Motion.maxLoops), "\(n): finite repeatCount")
                expect(item.animation.isRemovedOnCompletion && item.animation.fillMode != .forwards, "\(n): removed on completion")
            }
        }
        if looping {
            expect(t.pose(at: 0) == t.pose(at: t.duration), "\(n): loop seam pose(0) == pose(duration)")
            let anims = t.animations(begin: 0, loops: 3)
            expect(anims.contains { $0.key == "nokta.loop" && $0.animation.repeatCount == 3 }, "\(n): loop group × 3")
            if t.restT > 0 && t.restT < t.duration {
                expect(anims.contains { $0.key == "nokta.tail" && abs($0.animation.beginTime - 3 * t.duration / 1000) < 1e-9
                                        && abs($0.animation.duration - t.restT / 1000) < 1e-9 },
                       "\(n): tail group 0 → restT after 3 loops")
            } else {
                // The last loop already ends on the rest pose; a 0 → duration tail would be a 4th loop.
                expect(!anims.contains { $0.key == "nokta.tail" }, "\(n): no tail when restT is 0 or the full duration")
            }
            expect(anims.allSatisfy { $0.key != "nokta.tail" || $0.animation.duration < t.duration / 1000 },
                   "\(n): the tail is shorter than one loop")
        }
    }

    // MARK: overlay

    private static func testOverlay() {
        let tree = FrameLayerTree(style: .overlay)
        tree.setSurface(size: CGSize(width: 1440, height: 900), scale: 2)
        tree.apply(OverlayPalette.resolve(appearance: NSAppearance(named: .aqua)!, env: .init()))
        let landscape = CGRect(x: 8, y: 33, width: 708, height: 859)
        let portrait = CGRect(x: 8, y: 33, width: 708, height: 285)
        var signature: [CGPathElementType]?
        for side in AnchorSide.allCases {
            for rect in [landscape, portrait] {
                for radius: CGFloat in [12, 0] {
                    let path = FrameGeometry.path(rect: rect, radius: radius, start: side)
                    let sig = PathElements.signature(path)
                    if signature == nil { signature = sig }
                    expect(sig == signature, "path elements differ for \(side) \(rect.size) r \(radius)")
                    expect(sig.count == 10 && sig.filter { $0 == .addLineToPoint }.count == 4
                           && sig.filter { $0 == .addCurveToPoint }.count == 4, "path: 4 lines + 4 arcs + close (\(side))")
                    // E lies half the perimeter from the start: the two are point-symmetric.
                    let e = FrameGeometry.entryPoint(rect: rect, radius: radius, side: side)
                    let s = PathElements.elements(path)[0].points[0]
                    expect(abs(e.x + s.x - 2 * rect.midX) < 1e-9 && abs(e.y + s.y - 2 * rect.midY) < 1e-9, "E opposite the start (\(side))")
                }
            }
        }
        for portraitScreen in [false, true] {
            for action in NoktaAction.allCases {
                _ = AnchorSide(action: action, portrait: portraitScreen) // every action maps to a side
            }
        }
        // Every overlay timeline, both motion settings, both orientations.
        for rm in [false, true] {
            for (rect, side) in [(landscape, AnchorSide.left), (portrait, .top), (landscape, .topLeft), (landscape, .bottom)] {
                for t in OverlayTimelines.all(tree, rect: rect, start: side, reduceMotion: rm) { testTimeline(t) }
            }
        }
        // Expected key values (§9 table).
        let f = tree.frame(rect: landscape, start: .left)
        let alpha = Double(tree.palette!.scrimAlpha)
        let entry = OverlayTimelines.entry(tree, f, reduceMotion: false)
        let p0 = entry.pose(at: 0), p1 = entry.pose(at: entry.duration)
        expect(p0["scrim", "opacity"] == .scalar(0) && p1["scrim", "opacity"] == .scalar(alpha), "O1 scrim 0 → α")
        expect(p0["line", "strokeStart"] == .scalar(0.5) && p0["line", "strokeEnd"] == .scalar(0.5), "O1 line starts at E (0.5)")
        expect(p1["line", "strokeStart"] == .scalar(0) && p1["line", "strokeEnd"] == .scalar(1), "O1 line closes")
        expect(entry.duration == 180, "O1 180 ms (20 + 160)")
        let entryRM = OverlayTimelines.entry(tree, f, reduceMotion: true)
        expect(entryRM.pose(at: 0)["shape", "opacity"] == .scalar(0) && entryRM.pose(at: 100)["shape", "opacity"] == .scalar(1)
               && entryRM.pose(at: 0)["line", "strokeEnd"] == .scalar(1), "O1 RM: fade, line complete")
        let commit = OverlayTimelines.commit(tree, f, scrimFrom: nil, reduceMotion: false)
        let c0 = commit.pose(at: 0), c1 = commit.pose(at: commit.duration), c140 = commit.pose(at: 140)
        expect(c0["line", "lineWidth"] == .scalar(Double(f.lineWidth)) && c1["line", "lineWidth"] == .scalar(Double(tree.lineWidths.commit)),
               "O4 line thickens")
        expect(c0["period", "transform.scale"] == .scalar(0) && c140["period", "transform.scale"] == .scalar(1), "O4 period 0 → 1 by 140 ms")
        expect(c1["shape", "opacity"] == .scalar(0) && c1["period", "opacity"] == .scalar(0) && commit.duration == 260, "O4 fades by 260 ms")
        expect(c140["scrim", "opacity"] == .scalar(Double(tree.palette!.scrimPeakAlpha)), "O4 scrim peak")
        let flash = OverlayTimelines.flash(tree, rect: landscape, start: .left, reduceMotion: false)
        let fl0 = flash.pose(at: 0), fl1 = flash.pose(at: flash.duration)
        expect(fl0["scrim", "opacity"] == .scalar(0) && fl0["shape", "opacity"] == .scalar(1) && fl0["period", "transform.scale"] == .scalar(0),
               "O5 unfilled, period from 0")
        expect(fl1["shape", "opacity"] == .scalar(0) && fl1["period", "opacity"] == .scalar(0) && flash.duration == 240, "O5 gone at 240 ms")
        let blocked = OverlayTimelines.blocked(tree, frame: landscape, reduceMotion: false)
        let b0 = blocked.pose(at: 0), b180 = blocked.pose(at: 180)
        expect(close(b0["plate", "transform.translation.x"], .scalar(0)) && close(b180["plate", "transform.translation.x"], .scalar(0), 1e-9),
               "O6 shake starts and ends at 0")
        expect(blocked.tracks.first { $0.keyPath == "transform.translation.x" }?.keys.map { abs($0.value.scalarValue ?? 0) }.max() ?? 0 <= 4 + 1e-9,
               "O6 shake ±4 pt")
        expect(b0["period", "opacity"] == .scalar(0) && b0["scrim", "opacity"] == .scalar(0), "O6: no period, no fill")
        let plate = tree.setLabel("Left ⅔", center: CGPoint(x: 360, y: 450), within: CGRect(x: 0, y: 25, width: 1440, height: 875))
        for blockedLabel in [false, true] {
            let label = OverlayTimelines.label(plate: plate, blocked: blockedLabel)
            let hold = blockedLabel ? 2000.0 : 700.0
            expect(label.pose(at: 0)["plate", "opacity"] == .scalar(0) && label.pose(at: 90)["plate", "opacity"] == .scalar(1)
                   && label.pose(at: 90 + hold)["plate", "opacity"] == .scalar(1) && label.pose(at: label.duration)["plate", "opacity"] == .scalar(0)
                   && label.duration == 90 + hold + 160, "O7 0 → 1 (90) · hold \(hold) · → 0 (160)")
        }
        // O2 from presentation: starts where the old frame is, ends on the new one.
        let g = tree.frame(rect: landscape.insetBy(dx: 100, dy: 0), start: f.start)
        let from = OverlayTimelines.geometryKeys(tree, f)
        let move = OverlayTimelines.move(tree, to: g, from: from, reduceMotion: false)
        expect(close(move.pose(at: 0)["line", "path"], from["line", "path"]) && close(move.pose(at: 140)["line", "path"], tree.framePose(g)["line", "path"]),
               "O2 path from presentation to target")
        expect(move.duration == 140 && move.tracks.allSatisfy { $0.keys.first?.ease == .glide }, "O2 140 ms glide")
        // Line widths sit on whole pixels at 1x, 1.5x and 2x.
        for scale: CGFloat in [1, 1.5, 2] {
            let t = FrameLayerTree(style: .overlay)
            t.setSurface(size: CGSize(width: 800, height: 600), scale: scale)
            for ic in [false, true] {
                var env = AccessibilityEnv.Snapshot()
                env.increaseContrast = ic
                t.apply(OverlayPalette.resolve(appearance: NSAppearance(named: .aqua)!, env: env))
                let w = t.lineWidths
                for (name, v) in [("line", w.preview), ("commit", w.commit), ("blocked", w.blocked), ("halo", t.haloWidth)] {
                    let px = v * scale
                    expect(abs(px - px.rounded()) < 1e-6, "\(name) width \(v) pt is \(px) px at \(scale)x")
                }
                expect(abs(((w.commit - w.preview) / 2 * scale) - ((w.commit - w.preview) / 2 * scale).rounded()) < 1e-6,
                       "commit grows by whole pixels at \(scale)x")
            }
        }
    }

    // MARK: frame leaks (OV2-1, OV2-5)

    /// The hidden state and the timelines' own opacities: nothing a transition does not set
    /// itself can show the last frame.
    private static func testHiddenFrame() {
        let tree = FrameLayerTree(style: .overlay)
        tree.setSurface(size: CGSize(width: 1440, height: 900), scale: 2)
        tree.apply(OverlayPalette.resolve(appearance: NSAppearance(named: .darkAqua)!, env: .init()))
        let rect = CGRect(x: 8, y: 33, width: 708, height: 859)
        PoseApplier.apply(OverlayTimelines.flash(tree, rect: rect, start: .left, reduceMotion: false).pose(at: 100), to: tree.layers)
        tree.reset()
        expect(tree.shape.opacity == 0 && tree.scrim.opacity == 0 && tree.period.opacity == 0 && tree.plate.opacity == 0,
               "reset(): shape, scrim, period and plate transparent")
        expect(tree.line.path == nil && tree.halo.path == nil, "reset(): no line or halo path left")
        expect(tree.isIdle, "reset(): no animation")
        for rm in [false, true] {
            for t in OverlayTimelines.all(tree, rect: rect, start: .left, reduceMotion: rm) {
                let keys = t.keys
                if keys.contains(PoseKey("line", "path")) {
                    expect(keys.contains(PoseKey("shape", "opacity")) && keys.contains(PoseKey("scrim", "opacity"))
                           && keys.contains(PoseKey("period", "opacity")), "\(t.name): places a frame and sets its opacities")
                } else {
                    // Plate-only (O6 without a frame, O7) or cancel: never raises the frame.
                    for ms in stride(from: 0.0, through: t.duration, by: 10) {
                        let p = t.pose(at: ms)
                        let up = ["scrim", "period"].contains { (p[$0, "opacity"]?.scalarValue ?? 0) > 0 }
                            || (t.name != "ov.cancel" && (p["shape", "opacity"]?.scalarValue ?? 0) > 0)
                        if up { expect(false, "\(t.name): raises the frame at \(ms) ms without placing it"); break }
                    }
                }
            }
        }
        let plate = tree.setLabel("No window", center: CGPoint(x: 720, y: 450), within: CGRect(x: 0, y: 25, width: 1440, height: 875))
        let alone = OverlayTimelines.label(plate: plate, blocked: true, hidesFrame: true).restPose
        expect(alone["shape", "opacity"] == .scalar(0) && alone["scrim", "opacity"] == .scalar(0),
               "O7 with no transition owning the frame holds it invisible")
        expect(OverlayTimelines.label(plate: plate, blocked: false).keys.allSatisfy { $0.layer == "plate" || $0.layer == "text" },
               "O7 over a flash or commit leaves the frame to it")
    }

    /// The real controller (OverlayFrames.sequences): what the render server would show.
    private static func testSequences() {
        guard OverlayFrames.sequenceScreen != nil else { print("self-test: controller sequences skipped (no screen)"); return }
        let aqua = NSAppearance(named: .aqua)!
        for seq in OverlayFrames.sequences {
            guard let run = OverlayFrames.run(seq, appearance: aqua) else { continue }
            let tree = run.surface.tree
            func at(_ ms: Double) -> CFTimeInterval { run.start + ms / 1000 }
            let name = "seq \(seq.id)"
            switch seq.id {
            case "flash-noframe", "commit-cycle":
                for ms in [0.0, 90, 400, 700] {
                    expect(!OverlayFrames.frameVisible(tree, at: at(ms)), "\(name): no frame under the plate at \(ms) ms (\(OverlayFrames.describe(tree, at: at(ms))))")
                }
                expect(OverlayFrames.screenOpacity(tree, "plate", at: at(400)) == 1 && !tree.root.isHidden, "\(name): the plate shows")
            case "flash-label":
                expect(OverlayFrames.frameVisible(tree, at: at(100)) && OverlayFrames.screenOpacity(tree, "plate", at: at(100)) == 1,
                       "\(name): flash and plate together at 100 ms")
                expect(!OverlayFrames.frameVisible(tree, at: at(400)), "\(name): flash gone by 400 ms, plate stays")
            case "commit-entry":
                expect(tree.line.animation(forKey: Timeline.animationKey("strokeEnd")) == nil
                       && tree.halo.animation(forKey: Timeline.animationKey("strokeStart")) == nil,
                       "\(name): the entry's line drawing is cut by the drop")
                for ms in [0.0, 40, 140] {
                    let s0 = OverlayFrames.screenValue(tree, "line", "strokeStart", at: at(ms))?.scalarValue
                    let s1 = OverlayFrames.screenValue(tree, "line", "strokeEnd", at: at(ms))?.scalarValue
                    expect(s0 == 0 && s1 == 1, "\(name): complete line at \(ms) ms (\(s0 ?? -1) … \(s1 ?? -1))")
                }
            default: break
            }
            // Every sequence, run to its end: no animation, root hidden, nothing left (§17.3).
            if let done = OverlayFrames.run(seq, appearance: aqua, extraEnd: true) {
                let t = done.surface.tree
                expect(t.isIdle && t.root.isHidden && t.shape.opacity == 0 && t.line.path == nil && t.text.path == nil
                       && done.surface.state == .hidden && !done.surface.plateVisible, "\(name): ends hidden and idle")
            }
            withExtendedLifetime(run.owners) {}
        }
    }

    /// A looping demo (Phase B scenes loop ≤ 3 times + tail): exercises the loop/tail path.
    private static func testLoop() {
        let t = Timeline(name: "test.loop", duration: 3200, restT: 1500, explainT: 1500, tracks: [
            Track("knob", "position", [Key(0, .point(.zero), .hand), Key(830, .point(.zero), .out), Key(1030, .point(CGPoint(x: 12, y: 0))),
                                       Key(2700, .point(CGPoint(x: 12, y: 0)), .hand), Key(3000, .point(.zero))]),
            Track("track", "opacity", [Key(0, .scalar(0), .out), Key(1030, .scalar(1)), Key(2700, .scalar(1), .hand), Key(3000, .scalar(0))]),
            Track("arrow", "opacity", [Key(0, .scalar(1), .step), Key(1000, .scalar(0), .step), Key(2000, .scalar(1)), Key(3200, .scalar(1))]),
        ])
        testTimeline(t, looping: true)
        // FV2-8: a loop that rests at its end (restT == duration) or start (restT == 0) has no
        // tail: three loops are exactly three loops.
        let seam = Track("dot", "opacity", [Key(0, .scalar(1), .hand), Key(200, .scalar(0.35), .hand), Key(400, .scalar(1))])
        for restT in [400.0, 0] {
            let rest = Timeline(name: "test.loop.rest\(Int(restT))", duration: 400, restT: restT, explainT: 200, tracks: [seam])
            testTimeline(rest, looping: true)
            let anims = rest.animations(begin: 0, loops: 3)
            expect(anims.count == 1 && anims[0].key == "nokta.loop" && anims[0].animation.repeatCount == 3
                   && abs(anims[0].animation.duration - 0.4) < 1e-9, "\(rest.name): one group, 3 × 400 ms, nothing after")
        }
        let mixed = Timeline(name: "test.mixed", duration: 400, tracks: [
            Track("win", "position", [Key(0, .point(.zero), .step), Key(100, .point(CGPoint(x: 40, y: 0)), .out), Key(300, .point(CGPoint(x: 80, y: 0)))]),
        ])
        testTimeline(mixed)
        let arc = Timeline(name: "test.arc", duration: 400, tracks: [
            Track.arc("dot", "position", from: CGPoint(x: 230, y: 176), to: CGPoint(x: 400, y: 300),
                      control: CGPoint(x: 315, y: 190), t0: 0, t1: 400, ease: .glide),
        ])
        expect(arc.tracks[0].keys.count == 12, "arc: 12 samples")
        testTimeline(arc)
    }

    /// Runs every check; prints a summary. True when all passed.
    static func run() -> Bool {
        failures = []
        checks = 0
        testEase()
        testLoop()
        testOverlay()
        testHiddenFrame()
        testSequences()
        if failures.isEmpty {
            print("self-test: OK (\(checks) checks)")
            return true
        }
        print("self-test: FAIL (\(failures.count) of \(checks) checks)")
        for f in failures.prefix(40) { print("  ✗ " + f) }
        return false
    }
}
