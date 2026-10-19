import AppKit
import NoktaCore

/// Names and the assignment menu shared by ZoneMap and the Dragging popups.
enum ZoneInfo {
    /// VoiceOver label (DESIGN §15: "Left edge").
    static func spokenName(_ zone: NoktaZone) -> String {
        switch zone {
        case .left: return "Left edge"
        case .right: return "Right edge"
        case .top: return "Top edge"
        case .topLeft: return "Top left corner"
        case .topRight: return "Top right corner"
        case .bottomLeft: return "Bottom left corner"
        case .bottomRight: return "Bottom right corner"
        case .bottomLeftSegment: return "Bottom edge, left third"
        case .bottomCenterSegment: return "Bottom edge, middle third"
        case .bottomRightSegment: return "Bottom edge, right third"
        }
    }

    /// Short visible name: the title of the popup row under the map.
    static func shortName(_ zone: NoktaZone) -> String {
        switch zone {
        case .left: return "Left edge"
        case .right: return "Right edge"
        case .top: return "Top edge"
        case .topLeft: return "Top left corner"
        case .topRight: return "Top right corner"
        case .bottomLeft: return "Bottom left corner"
        case .bottomRight: return "Bottom right corner"
        case .bottomLeftSegment: return "Bottom edge, left"
        case .bottomCenterSegment: return "Bottom edge, middle"
        case .bottomRightSegment: return "Bottom edge, right"
        }
    }

    /// Assignable actions, grouped as DESIGN §8 lists them.
    static let menuSections: [(String?, [NoktaAction])] = [
        ("Halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ("Quarters", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("Thirds", [.firstThird, .centerThird, .lastThird]),
        ("Two Thirds", [.firstTwoThirds, .centerTwoThirds, .lastTwoThirds]),
        (nil, [.maximize, .almostMaximize, .center]),
    ]

    private static var glyphCache: [UInt32: NSImage] = [:]

    /// The action glyph with 5 pt of room on its right, so a menu or pop-up title does not touch it.
    private static func menuGlyph(_ action: NoktaAction) -> NSImage? {
        if let cached = glyphCache[action.rawValue] { return cached }
        guard let glyph = FrameGlyphs.action(action) else { return nil }
        let size = NSSize(width: glyph.size.width + 5, height: glyph.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            glyph.draw(in: NSRect(origin: .zero, size: glyph.size))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = glyph.accessibilityDescription
        glyphCache[action.rawValue] = image
        return image
    }

    /// Menu items carry `representedObject` = action raw value, or 0 for None.
    static func makeMenu(selected: NoktaAction?, target: AnyObject?, action selector: Selector?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, actions) in menuSections {
            if let title {
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            } else {
                menu.addItem(.separator())
            }
            for a in actions {
                let item = NSMenuItem(title: a.title, action: selector, keyEquivalent: "")
                item.target = target
                item.representedObject = NSNumber(value: a.rawValue)
                item.image = menuGlyph(a)
                item.state = a == selected ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let none = NSMenuItem(title: "None", action: selector, keyEquivalent: "")
        none.target = target
        none.representedObject = NSNumber(value: 0)
        none.state = selected == nil ? .on : .off
        menu.addItem(none)
        return menu
    }

    static func action(from item: NSMenuItem) -> NoktaAction?? {
        guard let raw = (item.representedObject as? NSNumber)?.uint32Value else { return .none }
        return .some(NoktaAction(rawValue: raw))
    }
}

/// ZoneMap v2 (DESIGN §8): a 384 × 240 pt outline of a screen. Every drag zone is a handle on it —
/// an L at each corner, a bar on the left, right and top edges, three bars along the bottom — and
/// the selected handle's result is drawn inside the screen with the overlay's own frame style
/// (`FrameMiniatureView`: 140 ms glide when the selection changes, instant under Reduce Motion).
/// No grid, no text, no red.
///
/// The result comes from the core (`nk_layout_frame`) for a representative window on the main
/// display's usable rect with the current gaps and Almost Maximize, scaled into the mini screen.
/// Center keeps a window's own size, so it has no exact result: a dashed box stands in for it.
///
/// One Tab stop; arrow keys walk the handles clockwise; Space or Return opens the selected handle's
/// menu, as does a click. Each handle is an NSAccessibilityElement (role popUpButton) inside the
/// group "Drag zones".
final class ZoneMap: NSControl {
    static let size = NSSize(width: 384, height: 240)
    /// A 16:10 display, for when no screen is known.
    static let fallbackUsable = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// Primary-map action for a zone (read on every draw/reload).
    var actionProvider: (NoktaZone) -> NoktaAction? = { _ in nil }
    /// What the result is computed from: the main display's usable rect and the current settings.
    var usable = ZoneMap.fallbackUsable
    var config = NoktaEngine.defaultConfig
    var onAssign: ((NoktaZone, NoktaAction?) -> Void)?
    var onSelect: ((NoktaZone) -> Void)?

    private(set) var selectedZone: NoktaZone = .left
    private var hoverZone: NoktaZone? { didSet { if hoverZone != oldValue { needsDisplay = true } } }
    private let preview = FrameMiniatureView(scale: 0.25)
    private var elements: [NoktaZone: ZoneElement] = [:]
    private var enabledState = true
    private var menuZone: NoktaZone?
    private var shownFraction: CGRect?
    /// Center: the dashed stand-in (unit fraction of the desktop), drawn instead of the result frame.
    private var symbolicBox: CGRect?
    private var postedValues: [NoktaZone: String] = [:]

    // MARK: geometry (flipped: y grows downwards)

    /// The screen outline (stroke centred on it), the handles sitting on it.
    private static let screen = NSRect(x: 8, y: 8, width: 368, height: 224)
    private static let screenRadius: CGFloat = 10
    /// The part of the screen that holds the result frame.
    private static let desktop = screen.insetBy(dx: 10, dy: 10)
    private static let outlineWidth: CGFloat = 1.5
    private static let handleWidth: CGFloat = 3
    private static let selectedWidth: CGFloat = 4
    private static let cornerArm: CGFloat = 22
    private static let sideLength: CGFloat = 56    // left and right bars
    private static let topLength: CGFloat = 112
    private static let segmentLength: CGFloat = 72 // bottom bars, centred on 1/6, 3/6, 5/6 of the width

    /// Clockwise from the top left; arrow keys follow it.
    private static let ring: [NoktaZone] = [
        .topLeft, .top, .topRight, .right, .bottomRight,
        .bottomRightSegment, .bottomCenterSegment, .bottomLeftSegment, .bottomLeft, .left,
    ]

    private static func segmentCenterX(_ zone: NoktaZone) -> CGFloat {
        let index: CGFloat = zone == .bottomLeftSegment ? 1 : zone == .bottomCenterSegment ? 3 : 5
        return screen.minX + screen.width * index / 6
    }

    /// Touch area of a handle: corners 44 × 44, side bars 32 × 96, top and bottom bars 120 × 32
    /// (each covers its drawn bar; the 72 pt bottom bars would meet the corner arms at 80 pt).
    static func hitRect(for zone: NoktaZone) -> NSRect {
        let w = size.width, h = size.height
        switch zone {
        case .topLeft: return NSRect(x: 0, y: 0, width: 44, height: 44)
        case .topRight: return NSRect(x: w - 44, y: 0, width: 44, height: 44)
        case .bottomLeft: return NSRect(x: 0, y: h - 44, width: 44, height: 44)
        case .bottomRight: return NSRect(x: w - 44, y: h - 44, width: 44, height: 44)
        case .left: return NSRect(x: 0, y: screen.midY - 48, width: 32, height: 96)
        case .right: return NSRect(x: w - 32, y: screen.midY - 48, width: 32, height: 96)
        case .top: return NSRect(x: screen.midX - 60, y: 0, width: 120, height: 32)
        case .bottomLeftSegment, .bottomCenterSegment, .bottomRightSegment:
            return NSRect(x: segmentCenterX(zone) - 60, y: h - 32, width: 120, height: 32)
        }
    }

    /// The stroked line of a handle. Straight runs sit on whole device pixels for `width`.
    private static func handlePath(_ zone: NoktaZone, width: CGFloat, scale: CGFloat) -> CGPath {
        func fit(_ v: CGFloat) -> CGFloat { Theme.Line.snap(v - width / 2, scale: scale) + width / 2 }
        let l = fit(screen.minX), r = fit(screen.maxX), t = fit(screen.minY), b = fit(screen.maxY)
        let arm = cornerArm, rad = screenRadius
        let p = CGMutablePath()
        switch zone {
        case .topLeft:
            p.move(to: CGPoint(x: l + arm, y: t))
            p.addArc(tangent1End: CGPoint(x: l, y: t), tangent2End: CGPoint(x: l, y: t + arm), radius: rad)
            p.addLine(to: CGPoint(x: l, y: t + arm))
        case .topRight:
            p.move(to: CGPoint(x: r - arm, y: t))
            p.addArc(tangent1End: CGPoint(x: r, y: t), tangent2End: CGPoint(x: r, y: t + arm), radius: rad)
            p.addLine(to: CGPoint(x: r, y: t + arm))
        case .bottomRight:
            p.move(to: CGPoint(x: r, y: b - arm))
            p.addArc(tangent1End: CGPoint(x: r, y: b), tangent2End: CGPoint(x: r - arm, y: b), radius: rad)
            p.addLine(to: CGPoint(x: r - arm, y: b))
        case .bottomLeft:
            p.move(to: CGPoint(x: l + arm, y: b))
            p.addArc(tangent1End: CGPoint(x: l, y: b), tangent2End: CGPoint(x: l, y: b - arm), radius: rad)
            p.addLine(to: CGPoint(x: l, y: b - arm))
        case .left, .right:
            let x = zone == .left ? l : r
            p.move(to: CGPoint(x: x, y: screen.midY - sideLength / 2))
            p.addLine(to: CGPoint(x: x, y: screen.midY + sideLength / 2))
        case .top:
            p.move(to: CGPoint(x: screen.midX - topLength / 2, y: t))
            p.addLine(to: CGPoint(x: screen.midX + topLength / 2, y: t))
        case .bottomLeftSegment, .bottomCenterSegment, .bottomRightSegment:
            let cx = segmentCenterX(zone)
            p.move(to: CGPoint(x: cx - segmentLength / 2, y: b))
            p.addLine(to: CGPoint(x: cx + segmentLength / 2, y: b))
        }
        return p
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: Self.size))
        preview.frame = Self.desktop
        preview.setAccessibilityElement(false)
        addSubview(preview)
        for zone in NoktaZone.allCases {
            elements[zone] = ZoneElement(zone: zone, map: self)
        }
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

    /// "Drag to snap" off: every handle at half strength and no result frame.
    override var isEnabled: Bool {
        get { enabledState }
        set {
            guard newValue != enabledState else { return }
            enabledState = newValue
            alphaValue = newValue ? 1 : 0.5
            if !newValue { hoverZone = nil }
            reload()
        }
    }

    func select(_ zone: NoktaZone, notify: Bool = true) {
        guard zone != selectedZone else { return }
        selectedZone = zone
        reload()
        noteFocusRingMaskChanged()
        if notify { onSelect?(zone) }
        if window?.firstResponder === self, let e = elements[zone] {
            NSAccessibility.post(element: e, notification: .focusedUIElementChanged)
        }
    }

    /// Re-reads assignments; updates the result frame and the accessibility values.
    func reload() {
        needsDisplay = true
        let action = enabledState ? actionProvider(selectedZone) : nil
        let result = resultFraction(of: action) ?? .zero
        symbolicBox = action == .center ? result : nil
        let fraction = action == .center ? .zero : result
        if fraction != shownFraction {
            shownFraction = fraction
            preview.show(fraction: fraction, animated: !Theme.Motion.reduceMotion && window != nil)
        }
        // VoiceOver hears only the zones whose action actually changed.
        for (zone, e) in elements {
            let value = actionProvider(zone)?.title ?? "None"
            if postedValues.updateValue(value, forKey: zone) != value { NSAccessibility.post(element: e, notification: .valueChanged) }
        }
    }

    /// Where `action` puts a window, as a unit-square fraction of the usable rect (x, y from the
    /// top left), by the core's own layout: a window 60 % × 60 % in the middle, the current gaps
    /// and Almost Maximize. nil: no frame (None, Restore, display moves).
    private func resultFraction(of action: NoktaAction?) -> CGRect? {
        guard let action, usable.width > 0, usable.height > 0 else { return nil }
        let window = usable.insetBy(dx: usable.width * 0.2, dy: usable.height * 0.2)
        func rect(_ r: CGRect) -> nk_rect { nk_rect(x: r.minX, y: r.minY, w: r.width, h: r.height) }
        var settings = config
        var frame = nk_rect()
        guard nk_layout_frame(nk_action(rawValue: action.rawValue), rect(window), rect(usable), &settings, &frame) else { return nil }
        return CGRect(x: (frame.x - usable.minX) / usable.width, y: (frame.y - usable.minY) / usable.height,
                      width: frame.w / usable.width, height: frame.h / usable.height)
    }

    // MARK: keyboard & mouse

    override var acceptsFirstResponder: Bool { enabledState }
    override var canBecomeKeyView: Bool { enabledState }
    override var focusRingMaskBounds: NSRect { Self.hitRect(for: selectedZone) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: Self.hitRect(for: selectedZone), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        if let e = elements[selectedZone] { NSAccessibility.post(element: e, notification: .focusedUIElementChanged) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    private enum Direction { case left, right, up, down }

    private static func direction(from a: CGPoint, to b: CGPoint) -> Direction {
        let dx = b.x - a.x, dy = b.y - a.y
        if abs(dx) >= abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .down : .up
    }

    private static func center(of zone: NoktaZone) -> CGPoint {
        let box = handlePath(zone, width: handleWidth, scale: 2).boundingBoxOfPath
        return CGPoint(x: box.midX, y: box.midY)
    }

    /// The arrow that points along the ring toward a neighbour goes there; any other arrow still
    /// moves: → and ↓ clockwise, ← and ↑ back.
    private func neighbor(of zone: NoktaZone, _ d: Direction) -> NoktaZone {
        let ring = Self.ring
        let i = ring.firstIndex(of: zone) ?? 0
        let next = ring[(i + 1) % ring.count], previous = ring[(i + ring.count - 1) % ring.count]
        let here = Self.center(of: zone)
        if Self.direction(from: here, to: Self.center(of: next)) == d { return next }
        if Self.direction(from: here, to: Self.center(of: previous)) == d { return previous }
        return d == .right || d == .down ? next : previous
    }

    override func keyDown(with event: NSEvent) {
        guard enabledState else { return super.keyDown(with: event) }
        let direction: Direction?
        switch event.keyCode {
        case 0x7B: direction = .left
        case 0x7C: direction = .right
        case 0x7E: direction = .up
        case 0x7D: direction = .down
        case 0x31, 0x24, 0x4C:
            openMenu(for: selectedZone)
            return
        default: direction = nil
        }
        if let direction {
            select(neighbor(of: selectedZone, direction))
            return
        }
        super.keyDown(with: event)
    }

    /// The handle under `point`: among the touch areas that contain it, the nearest to the line.
    private func zone(at point: NSPoint) -> NoktaZone? {
        func distance(_ zone: NoktaZone) -> CGFloat {
            let box = Self.handlePath(zone, width: Self.handleWidth, scale: 2).boundingBoxOfPath
            let dx = max(box.minX - point.x, 0, point.x - box.maxX)
            let dy = max(box.minY - point.y, 0, point.y - box.maxY)
            return hypot(dx, dy)
        }
        return Self.ring.filter { Self.hitRect(for: $0).contains(point) }.min { distance($0) < distance($1) }
    }

    override func mouseDown(with event: NSEvent) {
        guard enabledState else { return }
        guard let zone = zone(at: convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        select(zone)
        openMenu(for: zone)
    }

    override func mouseMoved(with event: NSEvent) {
        hoverZone = enabledState ? zone(at: convert(event.locationInWindow, from: nil)) : nil
    }

    override func mouseExited(with event: NSEvent) { hoverZone = nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    func openMenu(for zone: NoktaZone) {
        guard enabledState else { return }
        menuZone = zone
        let menu = ZoneInfo.makeMenu(selected: actionProvider(zone), target: self, action: #selector(menuChose(_:)))
        let r = Self.hitRect(for: zone)
        let selectedItem = menu.items.first { $0.state == .on }
        menu.popUp(positioning: selectedItem, at: NSPoint(x: r.minX + Theme.Space.s1, y: r.maxY - Theme.Space.s1), in: self)
    }

    @objc private func menuChose(_ item: NSMenuItem) {
        guard let zone = menuZone, let choice = ZoneInfo.action(from: item) else { return }
        onAssign?(zone, choice)
        reload()
        announce("\(ZoneInfo.spokenName(zone)): \(choice?.title ?? "None")")
    }

    // MARK: drawing

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let highContrast = AccessibilityEnv.shared.increaseContrast
        let passive = highContrast ? Theme.Color.ink2 : Theme.Color.ink3
        let scale = backingScale

        // The screen: raised ground and its outline (Increase Contrast: a 1 pt ink edge).
        let outline = CGPath(roundedRect: Self.screen, cornerWidth: Self.screenRadius, cornerHeight: Self.screenRadius, transform: nil)
        ctx.setFillColor(Theme.Color.paperRaised.cgColor)
        ctx.addPath(outline)
        ctx.fillPath()
        ctx.setStrokeColor((highContrast ? Theme.Color.ink : passive).cgColor)
        ctx.setLineWidth(highContrast ? 1 : Self.outlineWidth)
        ctx.addPath(outline)
        ctx.strokePath()

        // Center: no exact result, so a dashed box (the layer tree's frame is hidden meanwhile).
        if let box = symbolicBox, !box.isEmpty {
            let d = Self.desktop
            let r = CGRect(x: d.minX + box.minX * d.width, y: d.minY + box.minY * d.height,
                           width: box.width * d.width, height: box.height * d.height)
            let width = Theme.Line.miniature
            let radius = FrameStyle.miniature(0.25).cornerRadius
            ctx.saveGState()
            ctx.setStrokeColor((highContrast ? Theme.Color.ink : Theme.Color.ink2).cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.butt)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: width / 2, dy: width / 2), cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Handles: the selected one last, so its thicker line lies on top.
        for zone in Self.ring where zone != selectedZone { stroke(zone, selected: false, passive: passive, scale: scale, in: ctx) }
        stroke(selectedZone, selected: true, passive: passive, scale: scale, in: ctx)
    }

    private func stroke(_ zone: NoktaZone, selected: Bool, passive: NSColor, scale: CGFloat, in ctx: CGContext) {
        let width = selected ? Self.selectedWidth : Self.handleWidth
        let color: NSColor
        if selected {
            color = Theme.Color.ink
        } else if zone == hoverZone {
            color = AccessibilityEnv.shared.increaseContrast ? Theme.Color.ink : Theme.Color.ink2
        } else {
            color = passive
        }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        if actionProvider(zone) == nil {
            ctx.setLineCap(.butt)
            ctx.setLineDash(phase: 0, lengths: [3, 3]) // None: a dashed line
        } else {
            ctx.setLineCap(.round)
        }
        ctx.addPath(Self.handlePath(zone, width: width, scale: scale))
        ctx.strokePath()
        ctx.restoreGState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Drag zones" }
    override func accessibilityHelp() -> String? { "Arrow keys move between zones. Space opens the menu." }
    override func accessibilityChildren() -> [Any]? {
        Self.ring.compactMap { elements[$0] }
    }
    override var accessibilityFocusedUIElement: Any? { elements[selectedZone] }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let window else { return self }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return zone(at: local).flatMap { elements[$0] } ?? self
    }

    fileprivate func screenFrame(for zone: NoktaZone) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(Self.hitRect(for: zone), to: nil))
    }
}

/// One drag zone as seen by VoiceOver: popUpButton "Left edge", value "Left Half".
private final class ZoneElement: NSAccessibilityElement {
    let zone: NoktaZone
    weak var map: ZoneMap?

    init(zone: NoktaZone, map: ZoneMap) {
        self.zone = zone
        self.map = map
        super.init()
        setAccessibilityParent(map)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityLabel() -> String? { ZoneInfo.spokenName(zone) }
    override func accessibilityValue() -> Any? { map?.actionProvider(zone)?.title ?? "None" }
    override func accessibilityHelp() -> String? { "Choose what dropping a window here does." }
    override func accessibilityFrame() -> NSRect { map?.screenFrame(for: zone) ?? .zero }
    override func isAccessibilityEnabled() -> Bool { map?.isEnabled ?? false }
    override func isAccessibilityFocused() -> Bool {
        guard let map else { return false }
        return map.selectedZone == zone && map.window?.firstResponder === map
    }
    override func setAccessibilityFocused(_ focused: Bool) {
        guard focused, let map else { return }
        map.window?.makeFirstResponder(map)
        map.select(zone)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let map else { return false }
        map.select(zone)
        map.openMenu(for: zone)
        return true
    }
    override func accessibilityPerformShowMenu() -> Bool { accessibilityPerformPress() }
}
