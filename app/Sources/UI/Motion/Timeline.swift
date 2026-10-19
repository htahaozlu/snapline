import Foundation
import QuartzCore

/// The `pose(at t)` contract (docs/DESIGN.md §5.2; type sketch in the v2 design notes
/// §Hareket). Every moving surface describes its motion as a pure `Timeline`; `pose(at:)` and
/// `animations(begin:loops:)` come from the same keys, so what `tools/snapshot` draws for a given t
/// is what the render server shows at t. Foundation + QuartzCore only (no AppKit), so the snapshot
/// self-test can exercise it.
///
/// Times are milliseconds from the start of the timeline. Layers are named (`LayerID`); the owner
/// maps names to its CALayers (`PoseApplier`).
///
/// Rules this file enforces (§5.2):
///   1. one source — a track becomes one `CAKeyframeAnimation` (`values`, `keyTimes` = t / duration,
///      one timing function per segment, `.discrete` when every moving segment is `step`);
///   2. no per-frame main-thread work: animations are added once, inside one CATransaction;
///   3. the model stays at the rest pose (`restT`); animations are `isRemovedOnCompletion` and never
///      `fillMode .forwards`;
///   4. loops are finite: a repeated `CAAnimationGroup` plus one tail group (0 → `restT`);
///   5. interruptions are new timelines made with `move(from:to:)` from presentation values.

typealias LayerID = String

// MARK: - easing (§5.1)

/// Cubic Bézier curves identical to `CAMediaTimingFunction(controlPoints:)`.
enum Ease: Equatable {
    case linear, out, in_, glide, land, hand, step

    /// (x1, y1, x2, y2); nil for `linear` and `step`.
    var controlPoints: (Double, Double, Double, Double)? {
        switch self {
        case .linear, .step: return nil
        case .out: return (0, 0, 0.2, 1)
        case .in_: return (0.4, 0, 1, 1)
        case .glide: return (0.2, 0, 0, 1)
        case .land: return (0.34, 1.32, 0.64, 1)
        case .hand: return (0.42, 0, 0.58, 1)
        }
    }

    /// Eased progress for linear progress `x` in 0…1 (`land` overshoots, peak 1.034). `step` holds 0
    /// until the segment ends.
    func y(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        switch self {
        case .linear: return x
        case .step: return x >= 1 ? 1 : 0
        default:
            guard let (x1, y1, x2, y2) = controlPoints else { return x }
            if x == 0 || x == 1 { return x }
            return Self.bezier(Self.solve(x, x1, x2), y1, y2)
        }
    }

    /// The same curve for Core Animation (`step` segments use `.discrete` or a held key instead).
    var timingFunction: CAMediaTimingFunction {
        guard let (x1, y1, x2, y2) = controlPoints else { return CAMediaTimingFunction(name: .linear) }
        return CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }

    /// One coordinate of the Bézier with P0 = 0, P3 = 1.
    static func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private static func derivative(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }

    /// Curve parameter t with x(t) = x: Newton (8 iterations, ε 1e-6), bisection as fallback.
    /// x(t) is monotonic for every curve here (x1, x2 in 0…1).
    static func solve(_ x: Double, _ x1: Double, _ x2: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let err = bezier(t, x1, x2) - x
            if abs(err) < 1e-6 { return t }
            let d = derivative(t, x1, x2)
            if abs(d) < 1e-6 { break }
            let next = t - err / d
            if next < 0 || next > 1 { break }
            t = next
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<64 {
            let v = bezier(t, x1, x2)
            if abs(v - x) < 1e-7 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return t
    }
}

// MARK: - values

/// One animatable value. `caValue` is what `setValue(_:forKeyPath:)` and keyframe `values` take.
enum PoseValue: Equatable {
    case scalar(Double)
    case point(CGPoint)
    case size(CGSize)
    case rect(CGRect)
    case color(CGColor)
    /// Interpolated element by element, like Core Animation does: both ends must have the same
    /// element structure (DESIGN §9 path contract), otherwise the value steps at the end.
    case path(CGPath)

    var caValue: Any {
        switch self {
        case .scalar(let v): return NSNumber(value: v)
        case .point(let p): return NSValue(point: p)
        case .size(let s): return NSValue(size: s)
        case .rect(let r): return NSValue(rect: r)
        case .color(let c): return c
        case .path(let p): return p
        }
    }

    /// Reads a value back from KVC (`presentation()` values), typed like `template`.
    static func from(_ any: Any?, like template: PoseValue) -> PoseValue? {
        guard let any else { return nil }
        switch template {
        case .scalar: return (any as? NSNumber).map { .scalar($0.doubleValue) }
        case .point: return (any as? NSValue).map { .point($0.pointValue) }
        case .size: return (any as? NSValue).map { .size($0.sizeValue) }
        case .rect: return (any as? NSValue).map { .rect($0.rectValue) }
        case .color:
            guard CFGetTypeID(any as CFTypeRef) == CGColor.typeID else { return nil }
            return .color(any as! CGColor) // type checked above
        case .path:
            guard CFGetTypeID(any as CFTypeRef) == CGPath.typeID else { return nil }
            return .path(any as! CGPath) // type checked above
        }
    }

    var scalarValue: Double? { if case .scalar(let v) = self { return v }; return nil }

    /// Linear interpolation a → b at fraction f (f may leave 0…1 for overshooting curves).
    static func lerp(_ a: PoseValue, _ b: PoseValue, _ f: Double) -> PoseValue {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(f) }
        switch (a, b) {
        case let (.scalar(x), .scalar(y)): return .scalar(x + (y - x) * f)
        case let (.point(p), .point(q)): return .point(CGPoint(x: mix(p.x, q.x), y: mix(p.y, q.y)))
        case let (.size(p), .size(q)): return .size(CGSize(width: mix(p.width, q.width), height: mix(p.height, q.height)))
        case let (.rect(p), .rect(q)):
            return .rect(CGRect(x: mix(p.minX, q.minX), y: mix(p.minY, q.minY),
                                width: mix(p.width, q.width), height: mix(p.height, q.height)))
        case let (.color(p), .color(q)):
            guard let pc = p.components, let qc = q.components, pc.count == qc.count, p.colorSpace?.name == q.colorSpace?.name,
                  let space = p.colorSpace else { return f < 1 ? a : b }
            let comps = zip(pc, qc).map { mix($0, $1) }
            return CGColor(colorSpace: space, components: comps).map { .color($0) } ?? (f < 1 ? a : b)
        case let (.path(p), .path(q)):
            return PathElements.lerp(p, q, f).map { .path($0) } ?? (f < 1 ? a : b)
        default:
            return f < 1 ? a : b
        }
    }
}

/// CGPath as a flat element list, for the same element-wise interpolation Core Animation uses.
enum PathElements {
    struct Element: Equatable {
        var type: CGPathElementType
        var points: [CGPoint]
    }

    static func elements(_ path: CGPath) -> [Element] {
        var out: [Element] = []
        path.applyWithBlock { e in
            let el = e.pointee
            let n: Int
            switch el.type {
            case .moveToPoint, .addLineToPoint: n = 1
            case .addQuadCurveToPoint: n = 2
            case .addCurveToPoint: n = 3
            case .closeSubpath: n = 0
            @unknown default: n = 0
            }
            out.append(Element(type: el.type, points: (0..<n).map { el.points[$0] }))
        }
        return out
    }

    static func path(_ elements: [Element]) -> CGPath {
        let p = CGMutablePath()
        for e in elements {
            switch e.type {
            case .moveToPoint: p.move(to: e.points[0])
            case .addLineToPoint: p.addLine(to: e.points[0])
            case .addQuadCurveToPoint: p.addQuadCurve(to: e.points[1], control: e.points[0])
            case .addCurveToPoint: p.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
            case .closeSubpath: p.closeSubpath()
            @unknown default: break
            }
        }
        return p
    }

    /// Element-wise interpolation; nil when the structures differ.
    static func lerp(_ a: CGPath, _ b: CGPath, _ f: Double) -> CGPath? {
        let ea = elements(a), eb = elements(b)
        guard ea.count == eb.count, zip(ea, eb).allSatisfy({ $0.type == $1.type }) else { return nil }
        let k = CGFloat(f)
        return path(zip(ea, eb).map { x, y in
            Element(type: x.type, points: zip(x.points, y.points).map { p, q in
                CGPoint(x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k)
            })
        })
    }

    #if NOKTA_SNAPSHOT
    /// "4 lines + 4 arcs" signature of a path (types only), for the self-test.
    static func signature(_ path: CGPath) -> [CGPathElementType] { elements(path).map(\.type) }
    #endif
}

// MARK: - pose

struct PoseKey: Hashable {
    let layer: LayerID
    let keyPath: String
    init(_ layer: LayerID, _ keyPath: String) { self.layer = layer; self.keyPath = keyPath }
}

/// A complete or partial picture: value per (layer, key path).
struct Pose: Equatable {
    var values: [PoseKey: PoseValue] = [:]

    subscript(layer: LayerID, keyPath: String) -> PoseValue? {
        get { values[PoseKey(layer, keyPath)] }
        set { values[PoseKey(layer, keyPath)] = newValue }
    }

    /// `other` wins where both have a key.
    func merging(_ other: Pose) -> Pose {
        var p = self
        p.values.merge(other.values) { _, new in new }
        return p
    }

    var keys: Set<PoseKey> { Set(values.keys) }
}

// MARK: - timeline

/// One key: `value` at `t` (ms); `ease` shapes the segment towards the next key.
struct Key: Equatable {
    let t: Double
    let value: PoseValue
    let ease: Ease
    init(_ t: Double, _ value: PoseValue, _ ease: Ease = .linear) {
        self.t = t; self.value = value; self.ease = ease
    }
}

struct Track: Equatable {
    let layer: LayerID
    let keyPath: String
    /// Sorted by `t`.
    let keys: [Key]

    init(_ layer: LayerID, _ keyPath: String, _ keys: [Key]) {
        self.layer = layer
        self.keyPath = keyPath
        self.keys = keys.sorted { $0.t < $1.t }
    }

    /// Holds the first value before the first key and the last value after the last key.
    func value(at t: Double) -> PoseValue {
        guard let first = keys.first, let last = keys.last else { return .scalar(0) }
        if t <= first.t { return first.value }
        if t >= last.t { return last.value }
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            guard t >= a.t, t < b.t else { continue }
            let span = b.t - a.t
            guard span > 0 else { return b.value }
            return PoseValue.lerp(a.value, b.value, a.ease.y((t - a.t) / span))
        }
        return last.value
    }

    /// Arc motion as a 12-sample polyline (DESIGN §5.2 rule 1): samples are evenly spaced in time,
    /// their positions follow `ease` along a quadratic Bézier from `from` to `to` with `control`, and
    /// both `pose(at:)` and Core Animation interpolate linearly between them.
    static func arc(_ layer: LayerID, _ keyPath: String, from: CGPoint, to: CGPoint, control: CGPoint,
                    t0: Double, t1: Double, ease: Ease, samples: Int = 12) -> Track {
        let n = max(2, samples)
        let keys = (0..<n).map { i -> Key in
            let u = Double(i) / Double(n - 1)
            let s = CGFloat(ease.y(u)), r = 1 - s
            let p = CGPoint(x: r * r * from.x + 2 * r * s * control.x + s * s * to.x,
                            y: r * r * from.y + 2 * r * s * control.y + s * s * to.y)
            return Key(t0 + (t1 - t0) * u, .point(p), .linear)
        }
        return Track(layer, keyPath, keys)
    }
}

/// A pure description of one transition or scene.
struct Timeline {
    /// "ov.entry", "ov.move", … (Phase B: "onb.drag", "onb.access", …).
    let name: String
    /// ms.
    let duration: Double
    /// Pose the model is left in (applied before playing; the animations end there).
    let restT: Double
    /// Reduce Motion / static picture: a pose that reads on its own.
    let explainT: Double
    /// Values that do not move (geometry, start values); `tracks` override them.
    var base: Pose
    var tracks: [Track]

    init(name: String, duration: Double, restT: Double? = nil, explainT: Double? = nil, base: Pose = Pose(), tracks: [Track] = []) {
        self.name = name
        self.duration = duration
        self.restT = restT ?? duration
        self.explainT = explainT ?? (restT ?? duration)
        self.base = base
        self.tracks = tracks
    }

    /// Pure: the same t always gives the same pose.
    func pose(at t: Double) -> Pose {
        var p = base
        for track in tracks { p[track.layer, track.keyPath] = track.value(at: t) }
        return p
    }

    var restPose: Pose { pose(at: restT) }

    /// Every (layer, key path) this timeline sets.
    var keys: Set<PoseKey> { base.keys.union(tracks.map { PoseKey($0.layer, $0.keyPath) }) }

    // MARK: Core Animation

    struct Keyframes {
        var keyTimes: [Double]
        var values: [PoseValue]
        var eases: [Ease]
        var discrete: Bool
    }

    /// Keys of a track padded to 0…duration. Moving `step` segments become `.discrete` when every
    /// moving segment steps; in a mixed track a step segment is a held key plus a zero-length jump.
    func keyframes(for track: Track) -> Keyframes {
        var keys = track.keys
        guard let first = keys.first, let last = keys.last else {
            return Keyframes(keyTimes: [], values: [], eases: [], discrete: false)
        }
        if first.t > 0 { keys.insert(Key(0, first.value, .linear), at: 0) }
        if last.t < duration { keys.append(Key(duration, last.value, .linear)) }
        let moving = (0..<(keys.count - 1)).filter { keys[$0].value != keys[$0 + 1].value }
        let allStep = !moving.isEmpty && moving.allSatisfy { keys[$0].ease == .step }
        let d = max(duration, 1e-9)
        if allStep {
            return Keyframes(keyTimes: keys.map { min(max($0.t / d, 0), 1) }, values: keys.map(\.value),
                             eases: (0..<(keys.count - 1)).map { _ in .linear }, discrete: true)
        }
        var times: [Double] = [], values: [PoseValue] = [], eases: [Ease] = []
        for (i, k) in keys.enumerated() {
            times.append(k.t); values.append(k.value)
            guard i < keys.count - 1 else { break }
            let next = keys[i + 1]
            if k.ease == .step && k.value != next.value {
                times.append(next.t); values.append(k.value) // hold …
                eases.append(.linear)
                eases.append(.linear)                        // … then jump in zero time
            } else {
                eases.append(k.ease)
            }
        }
        return Keyframes(keyTimes: times.map { min(max($0 / d, 0), 1) }, values: values, eases: eases, discrete: false)
    }

    /// One keyframe animation spanning the whole timeline (beginTime 0, i.e. relative).
    func keyframeAnimation(for track: Track) -> CAKeyframeAnimation {
        let k = keyframes(for: track)
        let a = CAKeyframeAnimation(keyPath: track.keyPath)
        a.values = k.values.map(\.caValue)
        a.keyTimes = k.keyTimes.map { NSNumber(value: $0) }
        a.timingFunctions = k.eases.map(\.timingFunction)
        a.calculationMode = k.discrete ? .discrete : .linear
        a.duration = duration / 1000
        a.isRemovedOnCompletion = true
        return a
    }

    struct LayerAnimation {
        let layer: LayerID
        let key: String
        let animation: CAAnimation
    }

    /// Animation key on the layer: a newer timeline moving the same key path replaces the older one.
    static func animationKey(_ keyPath: String) -> String { "nokta." + keyPath }

    /// Animations to add (all inside one CATransaction). `begin` is in the layers' time space
    /// (`layer.convertTime(CACurrentMediaTime(), from: nil)` + delay). `loops > 1` repeats every
    /// layer's tracks as one group `loops` times, then plays a tail group 0 → `restT`; never
    /// infinite. No tail when `restT` is 0 or the full duration: the last loop already ends on
    /// the rest pose, and a 0 → duration tail would be one loop more. Tracks whose keys never
    /// change are skipped (the rest pose already holds them).
    func animations(begin: CFTimeInterval, loops: Int = 1) -> [LayerAnimation] {
        let moving = tracks.filter { t in t.keys.contains { $0.value != t.keys.first?.value } }
        guard loops > 1 else {
            return moving.map { track in
                let a = keyframeAnimation(for: track)
                a.beginTime = begin
                a.fillMode = .backwards // before `begin` show the first key, not the rest pose
                return LayerAnimation(layer: track.layer, key: Self.animationKey(track.keyPath), animation: a)
            }
        }
        var out: [LayerAnimation] = []
        let byLayer = Dictionary(grouping: moving, by: \.layer)
        for layer in byLayer.keys.sorted() {
            let children = byLayer[layer] ?? []
            let loop = CAAnimationGroup()
            loop.animations = children.map { keyframeAnimation(for: $0) }
            loop.duration = duration / 1000
            loop.repeatCount = Float(loops)
            loop.beginTime = begin
            loop.fillMode = .backwards
            loop.isRemovedOnCompletion = true
            out.append(LayerAnimation(layer: layer, key: "nokta.loop", animation: loop))
            if restT > 0 && restT < duration {
                let tail = CAAnimationGroup()
                tail.animations = children.map { keyframeAnimation(for: $0) }
                tail.duration = restT / 1000
                tail.beginTime = begin + Double(loops) * duration / 1000
                tail.isRemovedOnCompletion = true // no fill: the loop group covers the time before
                out.append(LayerAnimation(layer: layer, key: "nokta.tail", animation: tail))
            }
        }
        return out
    }

    // MARK: interruption

    /// From the current (presentation) values to `to` in `duration` ms. Keys only in `to` start
    /// at their target value; keys already equal produce no track.
    static func move(name: String, from: Pose, to: Pose, duration: Double, ease: Ease) -> Timeline {
        var tracks: [Track] = []
        for (key, target) in to.values.sorted(by: { ($0.key.layer, $0.key.keyPath) < ($1.key.layer, $1.key.keyPath) }) {
            guard let start = from.values[key], start != target else { continue }
            tracks.append(Track(key.layer, key.keyPath, [Key(0, start, ease), Key(duration, target)]))
        }
        return Timeline(name: name, duration: duration, base: to, tracks: tracks)
    }
}

// MARK: - applying

/// Sets poses on named layers and adds timelines; every call is one CATransaction with implicit
/// actions disabled.
enum PoseApplier {
    static func apply(_ pose: Pose, to layers: [LayerID: CALayer]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        set(pose, on: layers)
        CATransaction.commit()
    }

    /// Without a transaction of its own (callers are inside one).
    static func set(_ pose: Pose, on layers: [LayerID: CALayer]) {
        for (key, value) in pose.values {
            layers[key.layer]?.setValue(value.caValue, forKeyPath: key.keyPath)
        }
    }

    /// The values currently on screen for the keys of `template` (presentation layer, else model).
    static func presentationPose(like template: Pose, in layers: [LayerID: CALayer]) -> Pose {
        var p = Pose()
        for (key, value) in template.values {
            guard let layer = layers[key.layer] else { continue }
            let source = layer.presentation() ?? layer
            if let v = PoseValue.from(source.value(forKeyPath: key.keyPath), like: value) { p.values[key] = v }
        }
        return p
    }

    /// Rest poses of all `timelines`, then their animations, in one transaction. `completion`
    /// runs once every animation added here has finished.
    static func play(_ timelines: [Timeline], on layers: [LayerID: CALayer], loops: Int = 1, delay: Double = 0,
                     completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let completion { CATransaction.setCompletionBlock(completion) }
        for t in timelines { set(t.restPose, on: layers) }
        // Layers of one tree share a time space; any of them converts "now".
        let now = layers.values.first.map { $0.convertTime(CACurrentMediaTime(), from: nil) } ?? CACurrentMediaTime()
        for t in timelines {
            for item in t.animations(begin: now + delay / 1000, loops: loops) {
                layers[item.layer]?.add(item.animation, forKey: item.key)
            }
        }
        CATransaction.commit()
    }

    /// Removes the animations of `keys` (e.g. an entry interrupted by a zone change).
    static func removeAnimations(_ keys: [PoseKey], from layers: [LayerID: CALayer]) {
        for key in keys { layers[key.layer]?.removeAnimation(forKey: Timeline.animationKey(key.keyPath)) }
    }
}
