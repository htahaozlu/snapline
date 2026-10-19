import AppKit
import QuartzCore

/// Onboarding layout (docs/DESIGN.md §11; design-v2-opus.md §3.6), in points from the window's top
/// left: the stage at (40, 40, 480, 200); the text column 480 wide at x 40, its title at y 264;
/// the bottom bar 64 high. VoiceOver adds one row on screen 3 (the shortcut set), so the window is
/// one row taller while VoiceOver runs.
enum OnboardingMetrics {
    static let width: CGFloat = 560
    static let baseHeight: CGFloat = 440
    static let voiceOverRow: CGFloat = 32
    static let stage = CGRect(origin: CGPoint(x: 40, y: 40), size: StageScene.size)
    static let columnX: CGFloat = 40
    static let columnWidth: CGFloat = 480
    /// Top of the text column; titles sit 8 pt lower (y 264).
    static let pageTop: CGFloat = 256
    static let barHeight: CGFloat = 64

    static func height(voiceOver: Bool) -> CGFloat { baseHeight + (voiceOver ? voiceOverRow : 0) }
    static func pageHeight(voiceOver: Bool) -> CGFloat { height(voiceOver: voiceOver) - barHeight - pageTop }
}

/// The window's content: paper ground (a layer colour, no drawing), flipped like the layout.
final class OnboardingContentView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        layer?.backgroundColor = Theme.Color.value(.paper, Theme.variant(for: effectiveAppearance)).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A leaf view that only hosts layers: `root` is flipped and view-sized, so its sublayers use the
/// view's top-left coordinates. Never hit, never an accessibility element (its owner speaks).
final class LayerView: NSView {
    let root = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        root.delegate = NoImplicitActions.shared
        root.isGeometryFlipped = true
        layer?.addSublayer(root)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A dot of `diameter` centred in the view.
    func addDot(diameter: CGFloat) -> CALayer {
        let dot = StageDot.make(diameter: diameter)
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        root.addSublayer(dot)
        return dot
    }
}

/// Text in the onboarding's type roles (DESIGN §4.3), as labels VoiceOver reads.
enum OnboardingText {
    static func label(_ text: String, role: Typography.Role, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: attributed(text, role: role, color: color))
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func attributed(_ text: String, role: Typography.Role, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: Typography.attributes(role, color: color))
    }

    static func set(_ field: NSTextField, _ text: String, role: Typography.Role, color: NSColor) {
        field.attributedStringValue = attributed(text, role: role, color: color)
    }

    /// Width of `text` in `role`.
    static func width(_ text: String, role: Typography.Role) -> CGFloat {
        attributed(text, role: role, color: .labelColor).size().width
    }

    /// A label's text starts this far in (its line fragment padding).
    static let textInset: CGFloat = 2

    /// Where `field`'s text ends and its baseline is, in the field's superview.
    static func textEnd(_ field: NSTextField, role: Typography.Role) -> (x: CGFloat, baseline: CGFloat) {
        let x = field.frame.minX + (field.cell?.titleRect(forBounds: field.bounds).minX ?? 0) + textInset
        return (x + width(field.stringValue, role: role), field.frame.minY + field.firstBaselineOffsetFromTop)
    }

    /// Where a sentence's period goes after `field`'s text, in the field's superview: x = text end +
    /// 0.12 × font size, y = baseline − 0.1 × font size (design-v2-opus.md §3.6 "Nokta yuvası");
    /// the period is Ø 0.2 × font size.
    static func periodSlot(after field: NSTextField, role: Typography.Role) -> CGPoint {
        let size = Typography.font(role).pointSize
        let end = textEnd(field, role: role)
        return CGPoint(x: end.x + 0.12 * size, y: end.baseline - 0.1 * size)
    }

    /// `field` at `origin`, as wide as its text (at most `maxWidth`), one line high.
    static func place(_ field: NSTextField, at origin: CGPoint, role: Typography.Role, maxWidth: CGFloat = OnboardingMetrics.columnWidth) {
        let w = min(maxWidth, ceil(field.cell?.cellSize.width ?? field.intrinsicContentSize.width))
        field.frame = CGRect(x: origin.x, y: origin.y, width: w, height: Typography.lineHeight(role))
    }
}

/// VoiceOver announcement (DESIGN §15); `high` interrupts.
enum OnboardingSpeech {
    static func announce(_ text: String, high: Bool = false) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: (high ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
        ])
    }

    /// Moves VoiceOver to `element` (a page's title).
    static func focus(_ element: Any) {
        NSAccessibility.post(element: element, notification: .layoutChanged, userInfo: [.uiElements: [element]])
    }
}

// MARK: - pages

/// One screen's text column: 480 wide, top at y 256, laid out by frame (the window has one size).
/// `titleField` gets VoiceOver focus when the page appears.
class OnboardingPage: NSView {
    override var isFlipped: Bool { true }
    var titleField: NSTextField? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    func apply(_ p: StagePalette) {}
}

/// Screen 1 — Welcome: the `snapline.` wordmark, whose period arrives from the stage (special moment
/// 1), and one sentence.
final class WelcomePage: OnboardingPage {
    static let wordmarkRole = Typography.Role.wordmark(size: 40)

    let wordmark = OnboardingText.label(Product.wordmark, role: wordmarkRole, color: Theme.Color.ink)
    private let body = OnboardingText.label("Drag a window to an edge, or press a shortcut.", role: .body, color: .secondaryLabelColor)
    /// The wordmark's period (R6), Ø 8 = 0.2 × 40.
    private let periodView = LayerView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    private(set) var period: CALayer!

    override var titleField: NSTextField? { wordmark }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wordmark.setAccessibilityLabel(Product.name)
        for v in [wordmark, body, periodView] { addSubview(v) }
        OnboardingText.place(wordmark, at: CGPoint(x: 0, y: 8), role: Self.wordmarkRole)
        OnboardingText.place(body, at: CGPoint(x: 0, y: 60), role: .body)
        let slot = OnboardingText.periodSlot(after: wordmark, role: Self.wordmarkRole)
        periodView.frame = CGRect(x: slot.x - 6, y: slot.y - 6, width: 12, height: 12)
        periodView.layoutSubtreeIfNeeded()
        period = periodView.addDot(diameter: 8)
    }
    required init?(coder: NSCoder) { nil }

    /// Centre of the period's slot, in this page's superview.
    var slotInSuperview: CGPoint { CGPoint(x: frame.minX + periodView.frame.midX, y: frame.minY + periodView.frame.midY) }

    override func apply(_ p: StagePalette) { StageDot.apply(p, to: period) }
}

/// Screen 2 — Access. Waiting: `Allow Accessibility`, the reason, ● `Waiting…` (R4) and `Not
/// working?`. Granted: `Access granted.` — the R4 dot became the title's period — and `Nokta can
/// move windows now.` Both states are built once; Storyboard E cross-fades between them.
final class AccessPage: OnboardingPage {
    private static let titleRole = Typography.Role.title
    static let fix = "Remove \(Product.name) with −, then add it again."

    let title = OnboardingText.label("Allow Accessibility", role: titleRole, color: Theme.Color.ink)
    let titleGranted = OnboardingText.label("Access granted", role: titleRole, color: Theme.Color.ink)
    let body = OnboardingText.label("\(Product.name) needs it to move windows. Nothing leaves your Mac.", role: .body, color: .secondaryLabelColor)
    let bodyGranted = OnboardingText.label("\(Product.name) can move windows now.", role: .body, color: .secondaryLabelColor)
    /// ● `Waiting…`: one VoiceOver element.
    let status = NSView()
    private let statusDotView = LayerView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    private(set) var statusDot: CALayer!
    private let waiting = OnboardingText.label("Waiting…", role: .body, color: .secondaryLabelColor)
    let help = NSButton(title: "Not working?", target: nil, action: nil)
    /// The title's period once access is granted: Ø 4.4 = 0.2 × 22.
    private let periodView = LayerView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    private(set) var period: CALayer!
    private var popover: NSPopover?
    private var palette: StagePalette?
    /// `crossing`: both states are up for Storyboard E.
    enum State { case waiting, granted, crossing }
    private(set) var state = State.waiting

    override var titleField: NSTextField? { state == .waiting ? title : titleGranted }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleGranted.setAccessibilityLabel("Access granted.")
        for f in [title, titleGranted] { OnboardingText.place(f, at: CGPoint(x: 0, y: 8), role: Self.titleRole) }
        for f in [body, bodyGranted] { OnboardingText.place(f, at: CGPoint(x: 0, y: 48), role: .body) }

        status.frame = CGRect(x: 0, y: 80, width: 200, height: 24)
        statusDotView.frame = CGRect(x: -2, y: 6, width: 12, height: 12)
        statusDotView.layoutSubtreeIfNeeded()
        statusDot = statusDotView.addDot(diameter: 8)
        OnboardingText.place(waiting, at: CGPoint(x: 16, y: 4), role: .body)
        waiting.setAccessibilityElement(false)
        status.addSubview(statusDotView)
        status.addSubview(waiting)
        status.setAccessibilityElement(true)
        status.setAccessibilityRole(.staticText)
        status.setAccessibilityLabel("Waiting for Accessibility access")

        help.isBordered = false
        help.font = Typography.body
        help.contentTintColor = .secondaryLabelColor
        help.target = self
        help.action = #selector(showFix(_:))
        help.setAccessibilityHelp("Shows a fix")
        help.sizeToFit()
        let hw = ceil(help.frame.width) + 8
        help.frame = CGRect(x: OnboardingMetrics.columnWidth - hw + 4, y: 80, width: hw, height: 24)

        let slot = OnboardingText.periodSlot(after: titleGranted, role: Self.titleRole)
        periodView.frame = CGRect(x: slot.x - 4, y: slot.y - 4, width: 8, height: 8)
        periodView.layoutSubtreeIfNeeded()
        period = periodView.addDot(diameter: 4.4)
        for v in [title, titleGranted, body, bodyGranted, status, help, periodView] { addSubview(v) }
        showWaiting()
    }
    required init?(coder: NSCoder) { nil }

    /// Overlay-coordinate helpers (this page's superview): the R4 dot and the title's slot.
    var statusDotInSuperview: CGPoint {
        CGPoint(x: frame.minX + status.frame.minX + statusDotView.frame.midX, y: frame.minY + status.frame.minY + statusDotView.frame.midY)
    }
    var slotInSuperview: CGPoint { CGPoint(x: frame.minX + periodView.frame.midX, y: frame.minY + periodView.frame.midY) }
    /// The titles' font size (Storyboard E's arc keeps clear of them).
    var titleSize: CGFloat { Typography.font(Self.titleRole).pointSize }

    /// Layers Storyboard E moves, and the views whose alpha must follow them.
    var grantViews: [LayerID: NSView] {
        typealias ID = OnboardingTimelines.GrantID
        return [ID.title: title, ID.titleGranted: titleGranted, ID.body: body, ID.bodyGranted: bodyGranted,
                ID.status: status, ID.help: help]
    }
    var grantLayers: [LayerID: CALayer] {
        var out = grantViews.compactMapValues { $0.layer }
        out[OnboardingTimelines.GrantID.statusDot] = statusDot
        out[OnboardingTimelines.GrantID.period] = period
        return out
    }

    override func apply(_ p: StagePalette) {
        palette = p
        StageDot.apply(p, to: statusDot)
        StageDot.apply(p, to: period, red: false)
    }

    /// Static waiting state.
    func showWaiting() {
        state = .waiting
        set(granted: false)
    }

    /// Static granted state: `Access granted.` with an ink period.
    func showGranted() {
        state = .granted
        set(granted: true)
    }

    /// Both states visible to the layers (E cross-fades them); VoiceOver and clicks already see the
    /// granted one.
    func prepareGrant() {
        state = .crossing
        for v in [title, titleGranted, body, bodyGranted, status, help, periodView] as [NSView] { v.isHidden = false }
        for v in [title, body, status, help] as [NSView] { v.setAccessibilityElement(false) }
        help.isEnabled = false
        popover?.close()
    }

    private func set(granted g: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (v, on) in [(title, !g), (body, !g), (status, !g), (help, !g), (titleGranted, g), (bodyGranted, g), (periodView, g)] as [(NSView, Bool)] {
            v.isHidden = !on
            v.alphaValue = 1
            v.layer?.opacity = 1
        }
        for v in [title, body, help] as [NSView] { v.setAccessibilityElement(!g) }
        status.setAccessibilityElement(!g)
        titleGranted.setAccessibilityElement(g)
        bodyGranted.setAccessibilityElement(g)
        help.isEnabled = !g
        statusDot.opacity = 1
        period.opacity = 1
        if let palette { StageDot.apply(palette, to: period, red: false) }
        CATransaction.commit()
        if g { popover?.close() }
    }

    @objc private func showFix(_ sender: NSButton) {
        let text = OnboardingText.label(Self.fix, role: .body, color: .labelColor)
        let pad: CGFloat = 12
        let size = CGSize(width: ceil(text.intrinsicContentSize.width), height: Typography.lineHeight(.body))
        text.frame = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: size.width + 2 * pad, height: size.height + 2 * pad))
        container.addSubview(text)
        let vc = NSViewController()
        vc.view = container
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        popover = p
        OnboardingSpeech.announce(Self.fix)
    }
}

/// Screen 3 — Try: four shortcut chips (✓ once tried), the line about this window and the menu bar
/// with the real menu bar icon inline, `Open at login`, and — only with VoiceOver on — the
/// shortcut set selector.
final class TryPage: OnboardingPage {
    static let tryActions: [(NoktaAction, String)] = [(.leftHalf, "Left"), (.rightHalf, "Right"), (.maximize, "Maximize"), (.restore, "Restore")]
    static let chipGap: CGFloat = 12

    private let title = OnboardingText.label("Try a shortcut", role: .title, color: Theme.Color.ink)
    private(set) var chips: [ShortcutChip] = []
    private let body = OnboardingText.label("", role: .body, color: .secondaryLabelColor)
    private let icon = NSImageView()
    private let loginLabel = OnboardingText.label("Open at login", role: .body, color: .labelColor)
    let loginSwitch = NSSwitch()
    private let setLabel = OnboardingText.label("Alternate shortcuts, for VoiceOver.", role: .body, color: .labelColor)
    let setControl: NSSegmentedControl
    private(set) var tried: Set<NoktaAction> = []

    override var titleField: NSTextField? { title }

    init(frame frameRect: NSRect, target: AnyObject, login: Selector, setAction: Selector) {
        setControl = NSSegmentedControl(labels: ["Classic ⌃⌥", "Alternate ⌃⇧⌘"], trackingMode: .selectOne, target: target, action: setAction)
        super.init(frame: frameRect)
        OnboardingText.place(title, at: CGPoint(x: 0, y: 8), role: .title)
        chips = Self.tryActions.map { ShortcutChip(action: $0.0, name: $0.1) }
        icon.image = Glyphs.statusIcon(.active)
        icon.imageScaling = .scaleNone
        icon.contentTintColor = Theme.Color.ink
        icon.setAccessibilityLabel("\(Product.name) menu bar icon")
        loginSwitch.target = target
        loginSwitch.action = login
        loginSwitch.setAccessibilityLabel("Open at login")
        loginLabel.setAccessibilityElement(false)
        setControl.segmentStyle = .rounded
        setControl.setAccessibilityLabel("Shortcut set")
        setLabel.setAccessibilityElement(false)
        for v in [title, body, icon, loginLabel, loginSwitch, setLabel, setControl] as [NSView] + chips { addSubview(v) }
        layoutRows()
    }
    required init?(coder: NSCoder) { nil }

    private func layoutRows() {
        // Chips 12 pt apart; closer (≥ 6) if the shortcuts are long, and without the ✓ room if they
        // still do not fit the column.
        let column = OnboardingMetrics.columnWidth, gaps = CGFloat(chips.count - 1)
        for chip in chips { chip.reservesCheck = true }
        if chips.map(\.intrinsicContentSize.width).reduce(0, +) + 6 * gaps > column {
            for chip in chips { chip.reservesCheck = false }
        }
        let total = chips.map(\.intrinsicContentSize.width).reduce(0, +)
        let gap = max(6, min(Self.chipGap, ((column - total) / gaps).rounded(.down)))
        var x: CGFloat = 0
        for chip in chips {
            chip.frame = CGRect(x: x, y: 44, width: chip.intrinsicContentSize.width, height: ShortcutChip.height)
            x += chip.frame.width + gap
        }
        OnboardingText.place(body, at: CGPoint(x: 0, y: 74), role: .body, maxWidth: OnboardingMetrics.columnWidth - 22)
        // A word space after the text; the icon's frame sits on the baseline, so its outside dot
        // reads as the sentence's period.
        let end = OnboardingText.textEnd(body, role: .body)
        icon.frame = CGRect(x: (end.x + 4).rounded(), y: (end.baseline - 14).rounded(), width: 18, height: 18)
        let switchSize = loginSwitch.fittingSize
        OnboardingText.place(loginLabel, at: CGPoint(x: 0, y: 99), role: .body)
        loginSwitch.frame = CGRect(x: loginLabel.frame.maxX + 12, y: 96 + ((22 - switchSize.height) / 2).rounded(),
                                   width: switchSize.width, height: switchSize.height)
        OnboardingText.place(setLabel, at: CGPoint(x: 0, y: 131), role: .body)
        let segment = setControl.fittingSize
        setControl.frame = CGRect(x: setLabel.frame.maxX + 12, y: 128 + ((22 - segment.height) / 2).rounded(), width: segment.width, height: segment.height)
    }

    /// Current shortcuts, permission and VoiceOver state.
    func update(prefs: Preferences, canTry: Bool, voiceOver: Bool) {
        for chip in chips {
            chip.shortcut = prefs.shortcut(for: chip.action)
            chip.tried = tried.contains(chip.action)
        }
        let first = canTry ? "This window moves." : "Shortcuts start after you allow access."
        OnboardingText.set(body, "\(first) \(Product.name) stays in the menu bar", role: .body, color: .secondaryLabelColor)
        body.setAccessibilityLabel("\(first) \(Product.name) stays in the menu bar.")
        setLabel.isHidden = !voiceOver
        setControl.isHidden = !voiceOver
        let sets: [Preferences.ShortcutSet] = [.classic, .alternate]
        setControl.selectedSegment = prefs.currentShortcutSet.flatMap { sets.firstIndex(of: $0) } ?? -1
        layoutRows()
    }

    /// True if this snap newly ticks a chip.
    func markTried(_ action: NoktaAction) -> Bool {
        guard Self.tryActions.contains(where: { $0.0 == action }), !tried.contains(action) else { return false }
        tried.insert(action)
        return true
    }
}

/// One shortcut chip of screen 3: `⌃⌥← Left`, and ✓ once tried. Sized for the ✓ from the start
/// (`reservesCheck`), so a tick never moves the row; the content stays centred. Spoken "Control
/// Option Left Arrow, Left Half", value "tried".
final class ShortcutChip: NSView {
    static let height: CGFloat = 24
    static let padding: CGFloat = 8
    static let gap: CGFloat = 5
    private static let keysRole = Typography.Role.keycap(size: 12)
    private static let check = "✓"

    let action: NoktaAction
    let name: String
    var shortcut: Shortcut? {
        didSet {
            guard shortcut != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var tried = false {
        didSet {
            guard tried != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
    var reservesCheck = true { didSet { if reservesCheck != oldValue { invalidateIntrinsicContentSize() } } }

    init(action: NoktaAction, name: String) {
        self.action = action
        self.name = name
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private var keys: String { shortcut?.displayString ?? "—" }
    private var keysAttributes: [NSAttributedString.Key: Any] { [.font: Typography.font(Self.keysRole), .foregroundColor: Theme.Color.ink] }
    private var nameAttributes: [NSAttributedString.Key: Any] { [.font: Typography.font(.body), .foregroundColor: NSColor.labelColor] }
    private var checkAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Theme.Color.ink]
    }

    private func width(_ s: String, _ a: [NSAttributedString.Key: Any]) -> CGFloat { ceil((s as NSString).size(withAttributes: a).width) }
    private var contentWidth: CGFloat { width(keys, keysAttributes) + Self.gap + width(name, nameAttributes) }
    private var checkWidth: CGFloat { Self.gap + width(Self.check, checkAttributes) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: contentWidth + (reservesCheck || tried ? checkWidth : 0) + 2 * Self.padding, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let v = Theme.variant(for: effectiveAppearance)
        let wash = Theme.Color.value(.inkWash, v)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
        (tried ? wash.withAlphaComponent(wash.alphaComponent * 2) : wash).setFill() // tried: pressed-key wash
        shape.fill()
        if v.isHighContrast {
            Theme.Color.ink.setStroke()
            shape.stroke()
        }
        var x = ((bounds.width - contentWidth - (tried ? checkWidth : 0)) / 2).rounded()
        func put(_ s: String, _ a: [NSAttributedString.Key: Any]) {
            let size = (s as NSString).size(withAttributes: a)
            (s as NSString).draw(at: NSPoint(x: x, y: ((bounds.height - size.height) / 2).rounded()), withAttributes: a)
            x += ceil(size.width) + Self.gap
        }
        put(keys, keysAttributes)
        put(name, nameAttributes)
        if tried { put(Self.check, checkAttributes) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "\(ShortcutSpeech.spoken(shortcut)), \(action.title)" }
    override func accessibilityValue() -> Any? { tried ? "tried" : nil }
}
