import AppKit
import CoreText
import NoktaCore

/// Settings › About (DESIGN §8). Every number is measured when the tab appears, on ⌘R and on every
/// snap event — no timer. n = 0 shows "—", an unreadable value "Unreadable".
final class AboutPane: SettingsPaneController {
    /// One measurement: process numbers, the core's snap statistics, the Accessibility state.
    struct Reading {
        var sample: IntegrityProbe.Sample
        var stats: nk_stats
        var trusted: Bool
    }

    private func currentReading() -> Reading {
        Reading(sample: IntegrityProbe.sample(), stats: app.engine.stats(), trusted: app.isTrusted)
    }

    #if NOKTA_SNAPSHOT
    /// What a measurement reads. Offscreen tools show fixed numbers.
    lazy var reading: () -> Reading = { [unowned self] in self.currentReading() }
    #else
    private func reading() -> Reading { currentReading() }
    #endif

    private let meter = LineMeter()
    private let wordmark = AboutWordmark()
    private var contentStack: NSStackView!
    private var disclosureRow: NSStackView!
    private var memoryValue: NSTextField!
    private var overTarget: NSTextField!
    private var snapValue: NSTextField!
    private var networkValue: NSTextField!
    private var disclosure: NSButton!
    private var details: NSView!
    private var snapTimes: NSTextField!
    private var sinceLaunch: NSTextField!
    private var accessValue: NSTextField!
    private var entitlementsList: NSTextField!
    private var signatureValue: NSTextField!

    private static let labelWidth: CGFloat = 112

    convenience init(app: AppController, prefs: Preferences) { self.init(app: app, prefs: prefs, title: "About") }

    /// Whether the Details rows are shown (collapsed until the user opens them).
    var showsDetails: Bool {
        get { disclosure.state == .on }
        set {
            disclosure.state = newValue ? .on : .off
            details.isHidden = !newValue
            spaceDisclosure()
            updatePreferredSize()
        }
    }

    override func makeContent() -> NSView {
        let width = SettingsForm.contentWidth

        // nokta.                                    0.2.0 · arm64
        let version = UIText.label("\(IntegrityProbe.shortVersion) · \(IntegrityProbe.architecture)",
                                   font: Typography.callout, color: .secondaryLabelColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [wordmark, spacer, version])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: width).isActive = true

        // Memory · Last snap · Network
        let measured = NSGridView(numberOfColumns: 3, rows: 0)
        measured.columnSpacing = Theme.Space.s3
        measured.rowSpacing = Theme.Space.s3
        measured.column(at: 0).width = Self.labelWidth
        // Wide enough for "Unreadable", the longest thing a value can say.
        let probe = valueField()
        probe.stringValue = "Unreadable"
        measured.column(at: 1).width = max(72, ceil(probe.cell?.cellSize.width ?? 0))
        measured.column(at: 1).xPlacement = .trailing
        memoryValue = valueField()
        overTarget = UIText.label("over \(IntegrityProbe.memoryBudget / 1_048_576) MB target", font: Typography.callout, color: .labelColor)
        let meterStack = NSStackView(views: [meter, overTarget])
        meterStack.orientation = .horizontal
        meterStack.spacing = Theme.Space.s2
        addMeasured(measured, "Memory", memoryValue, accessory: meterStack,
                    tooltip: "Footprint while this window is open. The target is for idle.")
        meter.toolTip = memoryValue.toolTip
        snapValue = valueField()
        let snapTip = "From key press or drop to the last window call. Screen refresh not included."
        addMeasured(measured, "Last snap", snapValue, tooltip: snapTip)
        networkValue = valueField()
        addMeasured(measured, "Network", networkValue)

        let measuredNow = UIText.label("Measured now.", font: Typography.caption, color: .secondaryLabelColor)
        measuredNow.alignment = .right
        measuredNow.translatesAutoresizingMaskIntoConstraints = false
        measuredNow.widthAnchor.constraint(equalToConstant: width).isActive = true

        // ▸ Details
        disclosure = NSButton()
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggleDetails(_:))
        disclosure.setAccessibilityLabel("Details")
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            disclosure.widthAnchor.constraint(equalToConstant: 24),
            disclosure.heightAnchor.constraint(equalToConstant: 24),
        ])
        let detailsTitle = UIText.label("Details", font: .systemFont(ofSize: Typography.body.pointSize, weight: .semibold))
        detailsTitle.setAccessibilityElement(false)
        detailsTitle.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clickDetailsTitle(_:))))
        detailsTitle.heightAnchor.constraint(greaterThanOrEqualToConstant: UIControls.minimumTarget).isActive = true
        disclosureRow = NSStackView(views: [disclosure, detailsTitle])
        disclosureRow.orientation = .horizontal
        disclosureRow.spacing = Theme.Space.s1

        details = makeDetails(width: width)
        details.isHidden = true

        // Copy Report · Refresh
        let copyReport = UIControls.button("Copy Report", target: self, action: #selector(copyReport(_:)))
        let refresh = UIControls.button("Refresh", target: self, action: #selector(refreshPressed(_:)))
        refresh.keyEquivalent = "r"
        refresh.keyEquivalentModifierMask = .command
        refresh.toolTip = "Measure again (⌘R)"
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [copyReport, buttonSpacer, refresh])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: width).isActive = true

        let stack = NSStackView(views: [header, measured, measuredNow, disclosureRow, details, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.s3
        stack.setCustomSpacing(Theme.Space.s6, after: header)
        stack.setCustomSpacing(Theme.Space.s2, after: measured)
        stack.setCustomSpacing(Theme.Space.s4, after: measuredNow)
        stack.setCustomSpacing(Theme.Space.s5, after: details)
        contentStack = stack
        spaceDisclosure()
        return stack
    }

    /// 4 pt between the disclosure and its rows; 20 pt before the buttons when they are hidden.
    private func spaceDisclosure() {
        contentStack.setCustomSpacing(details.isHidden ? Theme.Space.s5 : Theme.Space.s1, after: disclosureRow)
    }

    /// A value, `digits` Semibold (DESIGN §4.3: About values).
    private static let valueFont = Typography.font(.digits(semibold: true))

    private func valueField() -> NSTextField {
        UIText.label("", font: Self.valueFont)
    }

    private func addMeasured(_ grid: NSGridView, _ title: String, _ value: NSTextField, accessory: NSView? = nil, tooltip: String? = nil) {
        let label = UIText.label(title)
        value.setAccessibilityTitleUIElement(label)
        if let tooltip { label.toolTip = tooltip; value.toolTip = tooltip }
        let row = grid.addRow(with: [label, value, accessory ?? NSGridCell.emptyContentView])
        row.yPlacement = .center
    }

    /// The Details rows (hidden until the disclosure opens): label left, value right of it.
    private func makeDetails(width: CGFloat) -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = Theme.Space.s3
        grid.rowSpacing = Theme.Space.s2
        grid.column(at: 0).width = Self.labelWidth
        grid.column(at: 1).width = width - Self.labelWidth - Theme.Space.s3
        grid.column(at: 1).xPlacement = .leading

        func add(_ title: String, _ value: NSView, topAligned: Bool = false) {
            let label = UIText.label(title, color: .secondaryLabelColor)
            if let field = value as? NSTextField { field.setAccessibilityTitleUIElement(label) }
            let row = grid.addRow(with: [label, value])
            row.yPlacement = topAligned ? .top : .center
        }

        snapTimes = UIText.label("")
        add("Snap times", snapTimes)
        sinceLaunch = UIText.label("")
        add("Since launch", sinceLaunch)
        accessValue = UIText.label("")
        add("Accessibility", accessValue)
        entitlementsList = UIText.wrapping("", font: Typography.mono, width: grid.column(at: 1).width)
        add("Entitlements", entitlementsList, topAligned: true)
        signatureValue = UIText.label("")
        add("Signature", signatureValue)

        let telemetry = NSStackView(views: [
            UIText.label("None"),
            UIText.label("Updates", color: .secondaryLabelColor),
            UIText.label("Manual"),
        ])
        telemetry.orientation = .horizontal
        telemetry.spacing = Theme.Space.s2
        telemetry.setCustomSpacing(Theme.Space.s6, after: telemetry.arrangedSubviews[0])
        let telemetryLabel = UIText.label("Telemetry", color: .secondaryLabelColor)
        grid.addRow(with: [telemetryLabel, telemetry]).yPlacement = .center

        let lsof = UIText.label(IntegrityProbe.lsofCommand, font: Typography.mono)
        lsof.isSelectable = true
        let copy = UIControls.button("Copy", target: self, action: #selector(copyCommand(_:)))
        copy.setAccessibilityLabel("Copy command")
        let check = NSStackView(views: [lsof, copy])
        check.orientation = .horizontal
        check.alignment = .centerY
        check.spacing = Theme.Space.s2
        grid.addRow(with: [UIText.label("Check", color: .secondaryLabelColor), check]).yPlacement = .center
        return grid
    }

    // MARK: measuring

    override func viewWillAppear() {
        super.viewWillAppear()
        measure()
    }

    /// Preferences and hotkey results change nothing here; measuring happens when the tab is on
    /// screen (also the first time it loads: `viewWillAppear`).
    override func refresh() {
        guard isViewLoaded else { return }
        if view.window != nil { measure() }
        updatePreferredSize()
    }

    override func noteSnap(_ event: NoktaEvent) {
        guard isViewLoaded, view.window?.isVisible == true else { return }
        measure()
    }

    private func measure() {
        let r = reading()
        let s = r.sample, stats = r.stats

        memoryValue.stringValue = s.footprint == nil ? "Unreadable" : Measure.megabytes(s.footprint)
        meter.value = s.footprint
        overTarget.isHidden = !meter.isOverBudget
        wordmark.periodIsRed = !meter.isOverBudget // one red at a time: the meter's R5 takes it

        let snaps = stats.snaps
        snapValue.stringValue = snaps == 0 ? "—" : Measure.milliseconds(stats.last_latency_ns)
        networkValue.stringValue = s.ipSockets.map { Measure.sockets($0) } ?? "Unreadable"

        if snaps == 0 {
            snapTimes.stringValue = "—"
        } else {
            let count = snaps > 128 ? "last 128 of \(snaps) snaps" : "\(snaps) snaps"
            snapTimes.stringValue = "median \(Measure.milliseconds(stats.p50_latency_ns)) · p95 \(Measure.milliseconds(stats.p95_latency_ns)) · \(count)"
        }
        let threads = s.threads.map { "\($0) threads" } ?? "— threads"
        sinceLaunch.stringValue = "CPU \(Measure.cpu(s.cpuSeconds)) · \(threads)"
        accessValue.stringValue = r.trusted ? "Allowed" : "Not allowed"
        let sig = IntegrityProbe.signature
        entitlementsList.stringValue = sig.entitlements.isEmpty ? "None" : sig.entitlements.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
        signatureValue.stringValue = sig.summary
    }

    // MARK: actions

    @objc private func toggleDetails(_ sender: NSButton) {
        showsDetails = sender.state == .on
    }

    @objc private func clickDetailsTitle(_ sender: Any?) {
        showsDetails = !showsDetails
    }

    @objc private func refreshPressed(_ sender: Any?) {
        measure()
        announce("Measured again.")
    }

    @objc private func copyCommand(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(IntegrityProbe.lsofCommand, forType: .string)
        announce("Command copied.")
    }

    @objc private func copyReport(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(IntegrityProbe.report(app: app), forType: .string)
        announce("Report copied.")
    }
}

/// `snapline.` — the word in SF Pro Display Bold 28 (tracking −0.6) and, drawn apart from it, the
/// period as its own red layer (R6, the brand). The period takes the size and place of the font's
/// own full stop. Read as the product name.
private final class AboutWordmark: NSView {
    private static let word = Product.wordmark
    private let font = Typography.wordmark(size: 28)
    private let period = CALayer()
    /// Red (R6); ink while another red element (R5) is on the surface.
    var periodIsRed = true { didSet { if periodIsRed != oldValue { applyColor() } } }
    /// The font's full stop in glyph space, and the pen position after the word.
    private let stop: CGRect
    private let wordWidth: CGFloat
    private let stopAdvance: CGFloat

    override init(frame frameRect: NSRect) {
        let ct = font as CTFont
        var characters: [UniChar] = [0x2E]
        var glyph: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(ct, &characters, &glyph, 1)
        var box = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(ct, .horizontal, glyph, &box, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, glyph, &advance, 1)
        stop = box
        stopAdvance = advance.width
        wordWidth = NSAttributedString(string: Self.word, attributes: Typography.attributes(.wordmark(size: 28))).size().width
        super.init(frame: frameRect)
        wantsLayer = true
        period.cornerRadius = box.width / 2
        period.bounds = CGRect(origin: .zero, size: box.size)
        period.anchorPoint = .zero
        layer?.addSublayer(period)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Product.name)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    private var baseline: CGFloat { ceil(-font.descender) + 1 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(wordWidth + stopAdvance), height: Typography.lineHeight(.wordmark(size: 28)))
    }

    override var firstBaselineOffsetFromTop: CGFloat { intrinsicContentSize.height - baseline }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        period.contentsScale = scale
        period.position = CGPoint(x: Theme.Line.snap(wordWidth + stop.minX, scale: scale),
                                  y: Theme.Line.snap(baseline + stop.minY, scale: scale))
        CATransaction.commit()
        applyColor()
    }

    /// No implicit fade: a colour change is immediate.
    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            period.backgroundColor = (periodIsRed ? Theme.Color.red : Theme.Color.ink).cgColor
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes = Typography.attributes(.wordmark(size: 28), color: Theme.Color.ink)
        (Self.word as NSString).draw(at: NSPoint(x: 0, y: baseline + font.descender), withAttributes: attributes)
    }
}
