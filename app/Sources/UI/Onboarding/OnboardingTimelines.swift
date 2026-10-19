import AppKit
import QuartzCore

/// Onboarding motion on top of the `pose(at t)` contract (docs/DESIGN.md §5.2, §11): the page
/// transition (Storyboard D), the access-granted moment (Storyboard E), the composition helpers the
/// scenes use to embed the overlay's own timelines, and the demo player. Scenes A–C live in
/// `Scenes/`. Every timeline here is pure; the controller plays it, `tools/snapshot` draws it.
enum OnboardingTimelines {
    private static func s(_ v: Double) -> PoseValue { .scalar(v) }

    // MARK: D — page transition (320 ms)

    /// Layer names of a page transition; the controller maps them to the two pages and scenes.
    enum PageID {
        static let oldPage: LayerID = "d.oldPage", newPage: LayerID = "d.newPage"
        static let oldScene: LayerID = "d.oldScene", newScene: LayerID = "d.newScene"
        /// A red dot on the incoming page (the wordmark's R6, the waiting R4).
        static func newRed(_ i: Int) -> LayerID { "d.newRed\(i)" }
    }

    /// Old text and stage content leave (0–160, `in`), the new ones enter (80–320, `out`): the text
    /// column moves 24 pt, the scene grows from .98; the stage frame itself never moves. The next
    /// progress segment turns ink (0–240, glide). Back mirrors the direction. Reduce Motion: 150 ms
    /// linear cross-fades, the progress jumps. The incoming page's red dots (`reds` of them) wait
    /// until the old page is gone, so the surface never shows two reds (DESIGN §4.2).
    static func page(forward: Bool, progress: [LayerID: (from: CGColor, to: CGColor)], reds: Int = 0, reduceMotion rm: Bool) -> Timeline {
        typealias ID = PageID
        var base = Pose()
        for i in 0..<reds { base[ID.newRed(i), "opacity"] = s(1) }
        base[ID.oldPage, "opacity"] = s(0)
        base[ID.newPage, "opacity"] = s(1)
        base[ID.oldScene, "opacity"] = s(0)
        base[ID.newScene, "opacity"] = s(1)
        base[ID.newScene, "transform.scale"] = s(1)
        base[ID.oldPage, "transform.translation.x"] = s(0)
        base[ID.newPage, "transform.translation.x"] = s(0)
        for (id, c) in progress { base[id, "backgroundColor"] = .color(c.to) }
        if rm {
            let d = Theme.Motion.reduced.upperBound
            return Timeline(name: "onb.page", duration: d, explainT: d / 2, base: base, tracks: [
                Track(ID.oldPage, "opacity", [Key(0, s(1), .linear), Key(d, s(0))]),
                Track(ID.newPage, "opacity", [Key(0, s(0), .linear), Key(d, s(1))]),
                Track(ID.oldScene, "opacity", [Key(0, s(1), .linear), Key(d, s(0))]),
                Track(ID.newScene, "opacity", [Key(0, s(0), .linear), Key(d, s(1))]),
            ] + (0..<reds).map { Track(ID.newRed($0), "opacity", [Key(0, s(0), .step), Key(d, s(1))]) })
        }
        let shift = forward ? 24.0 : -24.0
        var tracks = [
            Track(ID.oldPage, "opacity", [Key(0, s(1), .in_), Key(160, s(0))]),
            Track(ID.oldPage, "transform.translation.x", [Key(0, s(0), .in_), Key(160, s(-shift))]),
            Track(ID.oldScene, "opacity", [Key(0, s(1), .in_), Key(160, s(0))]),
            Track(ID.newPage, "opacity", [Key(80, s(0), .out), Key(320, s(1))]),
            Track(ID.newPage, "transform.translation.x", [Key(80, s(shift), .out), Key(320, s(0))]),
            Track(ID.newScene, "opacity", [Key(80, s(0), .out), Key(320, s(1))]),
            Track(ID.newScene, "transform.scale", [Key(80, s(0.98), .out), Key(320, s(1))]),
        ] + (0..<reds).map { Track(ID.newRed($0), "opacity", [Key(0, s(0), .step), Key(160, s(0), .out), Key(320, s(1))]) }
        for (id, c) in progress.sorted(by: { $0.key < $1.key }) where c.from != c.to {
            tracks.append(Track(id, "backgroundColor", [Key(0, .color(c.from), .glide), Key(240, .color(c.to))]))
        }
        return Timeline(name: "onb.page", duration: Theme.Motion.page, explainT: 160, base: base, tracks: tracks)
    }

    // MARK: E — access granted (special moment 2)

    /// Layer names of the access-granted moment on the Access page and the onboarding overlay.
    enum GrantID {
        static let title: LayerID = "e.title", titleGranted: LayerID = "e.titleGranted"
        static let body: LayerID = "e.body", bodyGranted: LayerID = "e.bodyGranted"
        static let status: LayerID = "e.status", statusDot: LayerID = "e.statusDot", help: LayerID = "e.help"
        /// The title's own period (on the page, so it moves with the page afterwards).
        static let period: LayerID = "e.period"
        /// The R4 dot while it flies (overlay, window coordinates).
        static let flight: LayerID = "e.flight"
    }

    /// The waiting R4 dot flies from the status row into the title's period slot and the title
    /// becomes `Access granted.`: title 0–120 (old out 0–60, new in 60–120), status row and `Not
    /// working?` fade 0–160, flight 120–480 (arc, glide, Ø 8 → 4.4), landing 480–580 (1.15 → 1,
    /// land), body 160–320 (old out 160–240, new in 240–320: one text at a time, never two over each
    /// other), and 1800–2100 the period turns from red to ink (linear): the red does not stay. The
    /// arc's control mirrors the start across the slot, 0.9 × `titleSize` above the higher end: the
    /// dot rises past the title's end and comes back into the slot from the right, never across the
    /// title's glyphs. Reduce Motion: 150 ms cross-fades, the period fades in at its slot, ink.
    /// `dot` and `slot` are overlay coordinates; the flight dot is Ø 8 and the slot's period Ø 4.4.
    static func grant(from dot: CGPoint, to slot: CGPoint, titleSize: CGFloat, red: CGColor, ink: CGColor, reduceMotion rm: Bool) -> Timeline {
        typealias ID = GrantID
        var base = Pose()
        for id in [ID.title, ID.body, ID.status, ID.help, ID.statusDot, ID.flight] { base[id, "opacity"] = s(0) }
        for id in [ID.titleGranted, ID.bodyGranted, ID.period] { base[id, "opacity"] = s(1) }
        base[ID.period, "backgroundColor"] = .color(ink)
        base[ID.flight, "position"] = .point(slot)
        base[ID.flight, "transform.scale"] = s(1)
        if rm {
            let d = Theme.Motion.reduced.upperBound
            func fade(_ id: LayerID, _ a: Double, _ b: Double) -> Track { Track(id, "opacity", [Key(0, s(a), .linear), Key(d, s(b))]) }
            return Timeline(name: "onb.grant", duration: d, base: base, tracks: [
                fade(ID.title, 1, 0), fade(ID.titleGranted, 0, 1), fade(ID.body, 1, 0), fade(ID.bodyGranted, 0, 1),
                fade(ID.status, 1, 0), fade(ID.help, 1, 0), fade(ID.period, 0, 1),
            ])
        }
        let landed = 4.4 / 8, arrival = landed * 1.15
        let control = CGPoint(x: 2 * slot.x - dot.x, y: min(dot.y, slot.y) - 0.9 * titleSize)
        return Timeline(name: "onb.grant", duration: 2100, base: base, tracks: [
            Track(ID.title, "opacity", [Key(0, s(1), .in_), Key(60, s(0))]),
            Track(ID.titleGranted, "opacity", [Key(60, s(0), .out), Key(120, s(1))]),
            Track(ID.status, "opacity", [Key(0, s(1), .in_), Key(160, s(0))]),
            Track(ID.help, "opacity", [Key(0, s(1), .in_), Key(160, s(0))]),
            Track(ID.body, "opacity", [Key(160, s(1), .in_), Key(240, s(0))]),
            Track(ID.bodyGranted, "opacity", [Key(240, s(0), .out), Key(320, s(1))]),
            // The page's dot hands over to the flight dot at t = 0 (same place) and back at 580.
            Track(ID.flight, "opacity", [Key(0, s(1), .step), Key(580, s(0))]),
            Track.arc(ID.flight, "position", from: dot, to: slot, control: control, t0: 120, t1: 480, ease: .glide),
            Track(ID.flight, "transform.scale", [Key(120, s(1), .glide), Key(480, s(arrival), .land), Key(580, s(landed))]),
            Track(ID.period, "opacity", [Key(0, s(0), .step), Key(580, s(1))]),
            Track(ID.period, "backgroundColor", [Key(1800, .color(red), .linear), Key(2100, .color(ink))]),
        ])
    }
}

// MARK: - composition

extension Pose {
    /// The same values under `prefix + layer`.
    func prefixed(_ prefix: String) -> Pose {
        var p = Pose()
        for (key, value) in values { p.values[PoseKey(prefix + key.layer, key.keyPath)] = value }
        return p
    }
}

extension Timeline {
    /// The same timeline on layers named `prefix + layer` (an overlay timeline inside a scene).
    func prefixed(_ prefix: String) -> Timeline {
        Timeline(name: name, duration: duration, restT: restT, explainT: explainT, base: base.prefixed(prefix),
                 tracks: tracks.map { Track(prefix + $0.layer, $0.keyPath, $0.keys) })
    }

    /// The same timeline starting `d` ms later (every value holds its first key until then).
    func delayed(by d: Double) -> Timeline {
        Timeline(name: name, duration: duration + d, restT: restT + d, explainT: explainT + d, base: base,
                 tracks: tracks.map { t in Track(t.layer, t.keyPath, t.keys.map { Key($0.t + d, $0.value, $0.ease) }) })
    }

    /// Parts played one after another on one clock: `start` holds until a part sets a key, each
    /// part's tracks run shifted by its offset, and a value holds (step) from the end of one part to
    /// the start of the next — so an O5 flash that rests hidden is hidden between two flashes. Parts
    /// that set the same key must not overlap in time. Keys that never change land in `base`.
    static func sequence(name: String, duration: Double, restT: Double, explainT: Double,
                         start: Pose, parts: [(at: Double, timeline: Timeline)]) -> Timeline {
        let ordered = parts.sorted { $0.at < $1.at }
        var all = start.keys
        for part in ordered { all.formUnion(part.timeline.keys) }
        var base = Pose()
        var tracks: [Track] = []
        for key in all.sorted(by: { ($0.layer, $0.keyPath) < ($1.layer, $1.keyPath) }) {
            var keys: [Key] = []
            func append(_ k: Key) {
                if let last = keys.last, last.t == k.t { keys[keys.count - 1] = k } else { keys.append(k) }
            }
            func holdLast() {
                if let last = keys.last { keys[keys.count - 1] = Key(last.t, last.value, .step) }
            }
            guard let first = start.values[key]
                ?? ordered.first(where: { $0.timeline.keys.contains(key) })?.timeline.pose(at: 0).values[key] else { continue }
            append(Key(0, first, .step))
            for (at, t) in ordered {
                if let track = t.tracks.first(where: { $0.layer == key.layer && $0.keyPath == key.keyPath }), let k0 = track.keys.first {
                    if k0.t > 0 { append(Key(at, k0.value, .linear)) }
                    for k in track.keys { append(Key(at + k.t, k.value, k.ease)) }
                    holdLast()
                } else if let v = t.base.values[key] {
                    append(Key(at, v, .step))
                }
            }
            if keys.allSatisfy({ $0.value == first }) {
                base.values[key] = first
            } else {
                tracks.append(Track(key.layer, key.keyPath, keys))
            }
        }
        return Timeline(name: name, duration: duration, restT: restT, explainT: explainT, base: base, tracks: tracks)
    }
}

// MARK: - playback

/// `PoseApplier.play` for the onboarding demos: the same rest-pose-then-animations transaction
/// (DESIGN §5.2 rules 2–4), plus the demo frame rate of §5.1 (30…60 Hz, preferring 60, never
/// 120 on ProMotion) on every animation and group.
enum StagePlayer {
    static func play(_ timelines: [Timeline], on layers: [LayerID: CALayer], loops: Int = 1, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let completion { CATransaction.setCompletionBlock(completion) }
        for t in timelines { PoseApplier.set(t.restPose, on: layers) }
        let now = layers.values.first.map { $0.convertTime(CACurrentMediaTime(), from: nil) } ?? CACurrentMediaTime()
        for t in timelines {
            for item in t.animations(begin: now, loops: min(max(loops, 1), Theme.Motion.maxLoops)) {
                limitFrameRate(item.animation)
                layers[item.layer]?.add(item.animation, forKey: item.key)
            }
        }
        CATransaction.commit()
    }

    private static func limitFrameRate(_ a: CAAnimation) {
        a.preferredFrameRateRange = Theme.Motion.demoFrameRate
        (a as? CAAnimationGroup)?.animations?.forEach(limitFrameRate)
    }

    /// Removes every animation from `layers` (the gate closed, the page changed).
    static func stop(_ layers: [LayerID: CALayer]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers.values { layer.removeAllAnimations() }
        CATransaction.commit()
    }
}
