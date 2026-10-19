import AppKit

/// Which side of the target the line grows from (docs/DESIGN.md §9 "Giriş noktası E"): the touched
/// edge, the corner of a corner zone, the bottom for the bottom segments; `center` / `none` for
/// frames that appear whole (flash, Restore, display moves).
enum AnchorSide: CaseIterable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight, center, none

    /// Drag zones carry their edge.
    init(zone: NoktaZone) {
        switch zone {
        case .left: self = .left
        case .right: self = .right
        case .top: self = .top
        case .topLeft: self = .topLeft
        case .topRight: self = .topRight
        case .bottomLeft: self = .bottomLeft
        case .bottomRight: self = .bottomRight
        case .bottomLeftSegment, .bottomCenterSegment, .bottomRightSegment: self = .bottom
        }
    }

    /// Keyboard/menu snaps: the edge in the action's direction (portrait: thirds are rows).
    init(action: NoktaAction?, portrait: Bool) {
        guard let action else { self = .none; return }
        switch action {
        case .leftHalf: self = .left
        case .rightHalf: self = .right
        case .topHalf: self = .top
        case .bottomHalf: self = .bottom
        case .topLeft: self = .topLeft
        case .topRight: self = .topRight
        case .bottomLeft: self = .bottomLeft
        case .bottomRight: self = .bottomRight
        case .firstThird, .firstTwoThirds: self = portrait ? .top : .left
        case .lastThird, .lastTwoThirds: self = portrait ? .bottom : .right
        case .centerThird, .centerTwoThirds, .center: self = .center
        case .maximize, .almostMaximize: self = .top
        case .restore, .nextDisplay, .prevDisplay: self = .none
        }
    }

    /// The side a unit-square fraction (x, y from top-left) hugs, for miniature previews.
    init(fraction f: CGRect) {
        let left = f.minX < 0.01, right = f.maxX > 0.99, top = f.minY < 0.01, bottom = f.maxY > 0.99
        switch (left, right, top, bottom) {
        case (true, true, true, true): self = .top
        case (true, false, true, false): self = .topLeft
        case (false, true, true, false): self = .topRight
        case (true, false, false, true): self = .bottomLeft
        case (false, true, false, true): self = .bottomRight
        case (true, false, _, _): self = .left
        case (false, true, _, _): self = .right
        case (_, _, true, false): self = .top
        case (_, _, false, true): self = .bottom
        default: self = .center
        }
    }
}

/// Pure frame geometry shared by the overlay and every miniature (ZoneMap, onboarding scenes), so
/// a preview never draws differently from the overlay. Rects are in the surface's flipped
/// (top-left origin) space, in points.
///
/// **Path contract (§9).** `path(rect:radius:start:)` always has the same ten elements —
/// move · (line · arc) × 4 · close — clockwise on screen. Each arc is one cubic quarter circle,
/// which is what `CGPath.addArc` emits for 90°, but written out so a zero radius still yields the
/// curve element. The path begins half the perimeter away from the entry point E: the middle of
/// the opposite edge, or, for corner zones, where the opposite corner's arc ends. The close is the
/// rest of the first edge (zero length for corners). By point symmetry E lies at 0.5, so the entry
/// `strokeStart` 0.5 → 0, `strokeEnd` 0.5 → 1 grows the line from E in both directions and closes it
/// on the far side. Every `AnchorSide`, in landscape and portrait, gives the same element list, so
/// Core Animation can interpolate `path` between any two frames.
enum FrameGeometry {
    /// Control-point factor of a cubic quarter circle.
    static let kappa: CGFloat = 0.552_284_749_8

    /// Corner radius that fits `rect`.
    static func radius(_ r: CGFloat, fitting rect: CGRect) -> CGFloat {
        max(0, min(r, rect.width / 2, rect.height / 2))
    }

    /// `rect` with every edge on the device pixel grid.
    static func snap(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let x0 = Theme.Line.snap(rect.minX, scale: scale), y0 = Theme.Line.snap(rect.minY, scale: scale)
        let x1 = Theme.Line.snap(rect.maxX, scale: scale), y1 = Theme.Line.snap(rect.maxY, scale: scale)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Edge `i` clockwise from the top (0 top → right, 1 right ↓, 2 bottom ←, 3 left ↑):
    /// its start A and end B; corner arc `i` runs from B(i) to A(i + 1).
    private static func edges(_ r: CGRect, _ rad: CGFloat) -> [(a: CGPoint, b: CGPoint, corner: CGPoint)] {
        [
            (CGPoint(x: r.minX + rad, y: r.minY), CGPoint(x: r.maxX - rad, y: r.minY), CGPoint(x: r.maxX, y: r.minY)),
            (CGPoint(x: r.maxX, y: r.minY + rad), CGPoint(x: r.maxX, y: r.maxY - rad), CGPoint(x: r.maxX, y: r.maxY)),
            (CGPoint(x: r.maxX - rad, y: r.maxY), CGPoint(x: r.minX + rad, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)),
            (CGPoint(x: r.minX, y: r.maxY - rad), CGPoint(x: r.minX, y: r.minY + rad), CGPoint(x: r.minX, y: r.minY)),
        ]
    }

    /// Where the path starts for an entry side: (edge index, 0 = edge start, 0.5 = edge middle).
    static func start(for side: AnchorSide) -> (edge: Int, at: CGFloat) {
        switch side {
        case .left: return (1, 0.5)          // E middle of the left edge → start middle of the right
        case .right: return (3, 0.5)
        case .top: return (2, 0.5)
        case .bottom: return (0, 0.5)
        case .topLeft: return (2, 0)         // E just past the top-left arc → start past the bottom-right
        case .topRight: return (3, 0)
        case .bottomRight: return (0, 0)
        case .bottomLeft: return (1, 0)
        case .center, .none: return (0, 0)
        }
    }

    private static func point(_ e: (a: CGPoint, b: CGPoint, corner: CGPoint), _ f: CGFloat) -> CGPoint {
        CGPoint(x: e.a.x + (e.b.x - e.a.x) * f, y: e.a.y + (e.b.y - e.a.y) * f)
    }

    /// The path contract (see the type comment). `radius` is clamped to the rect.
    static func path(rect: CGRect, radius: CGFloat, start side: AnchorSide) -> CGPath {
        let rad = Self.radius(radius, fitting: rect)
        let es = edges(rect, rad)
        let (first, at) = start(for: side)
        let p = CGMutablePath()
        p.move(to: point(es[first], at))
        for k in 0..<4 {
            let i = (first + k) % 4, next = es[(i + 1) % 4]
            let e = es[i]
            p.addLine(to: e.b)
            p.addCurve(to: next.a,
                       control1: CGPoint(x: e.b.x + (e.corner.x - e.b.x) * kappa, y: e.b.y + (e.corner.y - e.b.y) * kappa),
                       control2: CGPoint(x: next.a.x + (e.corner.x - next.a.x) * kappa, y: next.a.y + (e.corner.y - next.a.y) * kappa))
        }
        p.closeSubpath()
        return p
    }

    /// E: the point the line grows from (half the perimeter from the path's start).
    static func entryPoint(rect: CGRect, radius: CGFloat, side: AnchorSide) -> CGPoint {
        let es = edges(rect, Self.radius(radius, fitting: rect))
        let (first, at) = start(for: side)
        return point(es[(first + 2) % 4], at)
    }

    /// The period (R1): the inner bottom-trailing corner, (maxX − inset, maxY − inset) in LTR; the
    /// centre when the short side is under `minSide`.
    static func periodCenter(rect: CGRect, inset: CGFloat = 14, minSide: CGFloat = 64,
                             rightToLeft: Bool = NSApp?.userInterfaceLayoutDirection == .rightToLeft) -> CGPoint {
        if min(rect.width, rect.height) < minSide { return CGPoint(x: rect.midX, y: rect.midY) }
        return CGPoint(x: rightToLeft ? rect.minX + inset : rect.maxX - inset, y: rect.maxY - inset)
    }

    /// Converts a CG-global rect (top-left origin of the primary display) into `screen`'s flipped
    /// local space.
    static func localRect(fromCG r: CGRect, screen: NSScreen) -> CGRect {
        let ak = Screens.appKitRect(fromCG: r)
        let sf = screen.frame
        return CGRect(x: ak.minX - sf.minX, y: sf.maxY - ak.maxY, width: ak.width, height: ak.height)
    }

    /// `screen.visibleFrame` in the screen's flipped local space (below the menu bar and notch).
    static func visibleLocalRect(_ screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame, sf = screen.frame
        return CGRect(x: vf.minX - sf.minX, y: sf.maxY - vf.maxY, width: vf.width, height: vf.height)
    }

    /// `size` centred on `center`, kept `inset` inside `bounds`, origin on the pixel grid.
    static func place(_ size: CGSize, center: CGPoint, within bounds: CGRect, inset: CGFloat, scale: CGFloat) -> CGRect {
        let lo = CGPoint(x: bounds.minX + inset + size.width / 2, y: bounds.minY + inset + size.height / 2)
        let hi = CGPoint(x: bounds.maxX - inset - size.width / 2, y: bounds.maxY - inset - size.height / 2)
        let c = CGPoint(x: hi.x >= lo.x ? min(max(center.x, lo.x), hi.x) : bounds.midX,
                        y: hi.y >= lo.y ? min(max(center.y, lo.y), hi.y) : bounds.midY)
        return CGRect(x: Theme.Line.snap(c.x - size.width / 2, scale: scale), y: Theme.Line.snap(c.y - size.height / 2, scale: scale),
                      width: size.width, height: size.height)
    }
}
