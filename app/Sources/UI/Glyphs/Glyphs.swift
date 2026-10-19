import AppKit

/// Template glyphs drawn in code (docs/DESIGN.md §7.1, §12). No assets: every image is an
/// `NSImage(size:flipped:drawingHandler:)`, black + alpha, `isTemplate = true`, cached; the
/// handler runs per backing scale, so 1x and 2x each get their own pixel-aligned geometry.
/// Ink only — the menu bar icon is never red and never animates.
enum Glyphs {
    enum StatusIconState: Hashable, CaseIterable { case active, paused, needsPermission }

    private static var statusCache: [StatusIconState: NSImage] = [:]
    private static var statusCacheContrast = false

    /// 18 × 18 pt status item image (`▮▯.`): a window frame with the period outside it, its bottom
    /// on the frame's bottom edge. States differ by shape, not only alpha:
    ///   Active — frame + left half filled + filled period ·
    ///   Paused — frame only + ring period ·
    ///   Needs permission — frame + a slash with 1 pt clear on both sides, no period.
    /// Increase Contrast: 2 pt lines. Cached; the item changes its image only when the state does.
    static func statusIcon(_ state: StatusIconState) -> NSImage {
        let ic = AccessibilityEnv.shared.increaseContrast
        if ic != statusCacheContrast { statusCache.removeAll(); statusCacheContrast = ic }
        if let img = statusCache[state] { return img }
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawStatusIcon(state, in: ctx, onePixel: deviceScale(ctx) < 1.5, highContrast: ic)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = Product.name
        statusCache[state] = img
        return img
    }

    /// Status icon geometry (pt, y down) for one backing scale (§7.1; design-v2-opus.md §3.1).
    struct StatusGeometry {
        var frame: CGRect          // stroked path
        var radius: CGFloat
        var line: CGFloat
        var fillMaxX: CGFloat      // Active fill: frame.minX … fillMaxX
        var periodCenter: CGPoint  // Ø 3
        var slash: (CGPoint, CGPoint)

        /// 2x: frame (0.75, 4.75, 12, 8.5), r 2.25, 1.5 pt → outer box 0…13.5 × 4…14 on whole pixels.
        /// 1x: 1 px lines on pixel centres → outer box 0…13 × 4…14. IC (both): 2 pt on whole points.
        /// The period's bottom sits on the frame's outer bottom (y 14) with ≥ 1 pt clear between.
        static func make(onePixel: Bool, highContrast: Bool) -> StatusGeometry {
            if highContrast {
                return StatusGeometry(frame: CGRect(x: 1, y: 5, width: 12, height: 8), radius: 2, line: 2, fillMaxX: 7,
                                      periodCenter: CGPoint(x: 16.5, y: 12.5),
                                      slash: (CGPoint(x: 1.5, y: 16), CGPoint(x: 14, y: 2)))
            }
            if onePixel {
                return StatusGeometry(frame: CGRect(x: 0.5, y: 4.5, width: 12, height: 9), radius: 2.5, line: 1, fillMaxX: 7,
                                      periodCenter: CGPoint(x: 15.5, y: 12.5),
                                      slash: (CGPoint(x: 1.5, y: 16), CGPoint(x: 14, y: 2)))
            }
            return StatusGeometry(frame: CGRect(x: 0.75, y: 4.75, width: 12, height: 8.5), radius: 2.25, line: 1.5, fillMaxX: 7,
                                  periodCenter: CGPoint(x: 16, y: 12.5),
                                  slash: (CGPoint(x: 1.5, y: 16), CGPoint(x: 14, y: 2)))
        }
    }

    /// Draws one state into `ctx` (18 × 18 pt user space, y down), black + alpha.
    static func drawStatusIcon(_ state: StatusIconState, in ctx: CGContext, onePixel: Bool, highContrast: Bool) {
        let g = StatusGeometry.make(onePixel: onePixel, highContrast: highContrast)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        let frame = CGPath(roundedRect: g.frame, cornerWidth: g.radius, cornerHeight: g.radius, transform: nil)
        ctx.setLineWidth(g.line)
        ctx.addPath(frame)
        ctx.strokePath()
        switch state {
        case .active:
            ctx.saveGState()
            ctx.addPath(frame)
            ctx.clip()
            ctx.fill(CGRect(x: g.frame.minX - 1, y: g.frame.minY - 1, width: g.fillMaxX - g.frame.minX + 1, height: g.frame.height + 2))
            ctx.restoreGState()
            ctx.fillEllipse(in: CGRect(x: g.periodCenter.x - 1.5, y: g.periodCenter.y - 1.5, width: 3, height: 3))
        case .paused:
            // Ring: Ø 3 outside, 1 pt line (Increase Contrast too — 2 pt would close the ring).
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: g.periodCenter.x - 1, y: g.periodCenter.y - 1, width: 2, height: 2))
        case .needsPermission:
            ctx.setLineCap(.butt)
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(g.line + 2)
            ctx.move(to: g.slash.0)
            ctx.addLine(to: g.slash.1)
            ctx.strokePath()
            ctx.setBlendMode(.normal)
            ctx.setLineWidth(g.line)
            ctx.move(to: g.slash.0)
            ctx.addLine(to: g.slash.1)
            ctx.strokePath()
        }
    }

    /// Spoken `accessibilityValue` of the status item per state (§7.1).
    static func spokenValue(_ state: StatusIconState) -> String {
        switch state {
        case .active: return "On"
        case .paused: return "Paused"
        case .needsPermission: return "Needs Accessibility access"
        }
    }

    /// Unit-square fraction of a tiling action (x, y from top-left), mirroring
    /// `layout.fraction` in core/src/layout.zig. nil for center, restore and display moves.
    static func unitFraction(_ action: NoktaAction, cycle: UInt32 = 0, portrait: Bool = false, almost: Double = 0.9) -> CGRect? {
        let halfCycle: [Double] = [1.0 / 2.0, 2.0 / 3.0, 1.0 / 3.0]
        let s = halfCycle[Int(cycle) % halfCycle.count]
        let third = 1.0 / 3.0, two = 2.0 / 3.0
        func band(_ start: Double, _ len: Double) -> CGRect {
            portrait ? CGRect(x: 0, y: start, width: 1, height: len) : CGRect(x: start, y: 0, width: len, height: 1)
        }
        switch action {
        case .leftHalf: return CGRect(x: 0, y: 0, width: s, height: 1)
        case .rightHalf: return CGRect(x: 1 - s, y: 0, width: s, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: s)
        case .bottomHalf: return CGRect(x: 0, y: 1 - s, width: 1, height: s)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .firstThird: return band(0, third)
        case .centerThird: return band(third, third)
        case .lastThird: return band(two, third)
        case .firstTwoThirds: return band(0, two)
        case .centerTwoThirds: return band(1.0 / 6.0, two)
        case .lastTwoThirds: return band(third, two)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .almostMaximize:
            let r = min(max(almost, 0.5), 1.0)
            return CGRect(x: (1 - r) / 2, y: (1 - r) / 2, width: r, height: r)
        case .center, .restore, .nextDisplay, .prevDisplay: return nil
        }
    }

    static func deviceScale(_ ctx: CGContext) -> CGFloat {
        let t = ctx.userSpaceToDeviceSpaceTransform
        return max(abs(t.a), abs(t.b))
    }
}

/// Action glyphs for the menu, the Shortcuts table and the Dragging popups (§12): a 16 × 12 pt
/// template frame (0.5, 0.5, 15, 11), r 2, 1 pt, filled over the action's share of the inner
/// area (2, 2, 12, 8). Center (5, 3.5, 6, 5); Almost Maximize (3, 3, 10, 6); Maximize full.
/// Restore and the display moves have no glyph.
enum FrameGlyphs {
    static let size = NSSize(width: 16, height: 12)
    static let inner = CGRect(x: 2, y: 2, width: 12, height: 8)
    private static var cache: [UInt32: NSImage] = [:]

    /// Fill rect (pt, y down) for `action`, nil when it has no glyph.
    static func fill(_ action: NoktaAction) -> CGRect? {
        switch action {
        case .center: return CGRect(x: 5, y: 3.5, width: 6, height: 5)
        case .almostMaximize: return CGRect(x: 3, y: 3, width: 10, height: 6)
        case .restore, .nextDisplay, .prevDisplay: return nil
        default:
            guard let f = Glyphs.unitFraction(action) else { return nil }
            return CGRect(x: inner.minX + f.minX * inner.width, y: inner.minY + f.minY * inner.height,
                          width: f.width * inner.width, height: f.height * inner.height)
        }
    }

    static func action(_ action: NoktaAction) -> NSImage? {
        if let img = cache[action.rawValue] { return img }
        guard let fill = fill(action) else { return nil }
        let img = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(fill: fill, in: ctx)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = action.title
        cache[action.rawValue] = img
        return img
    }

    /// Draws a glyph into `ctx` (16 × 12 pt user space, y down). The fill's edges snap to the
    /// device pixels (1x: Center's 3.5 … 8.5 becomes 4 … 9), so 1x stays on whole pixels.
    static func draw(fill: CGRect, in ctx: CGContext) {
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: 15, height: 11), cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.strokePath()
        ctx.fill(FrameGeometry.snap(fill, scale: Glyphs.deviceScale(ctx)))
    }
}
