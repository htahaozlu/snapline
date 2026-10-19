import AppKit

/// Label factories. Everything is an NSTextField so VoiceOver reads it.
enum UIText {
    static func label(_ text: String, font: NSFont = Typography.body, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// Multi-line text; `width` is the wrapping width (needed for a correct fitting height).
    static func wrapping(_ text: String, font: NSFont = Typography.body, color: NSColor = .labelColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.preferredMaxLayoutWidth = width
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    static func callout(_ text: String, width: CGFloat) -> NSTextField {
        wrapping(text, font: Typography.callout, color: .secondaryLabelColor, width: width)
    }

    /// Live reading ("8 pt", `digits`) with an explicit spoken value.
    static func digitsValue(_ text: String, font: NSFont = Typography.digits, spoken: String) -> NSTextField {
        let field = label(text, font: font)
        field.setAccessibilityValueDescription(spoken)
        return field
    }
}

/// Control factories with the accessibility label wired to the visible row title.
enum UIControls {
    /// DESIGN §15: nothing clickable is smaller than 24 × 24 pt (regular controls; no `.small`).
    static let minimumTarget: CGFloat = 24

    static func toggle(_ title: String, help: String? = nil, target: AnyObject?, action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.target = target
        s.action = action
        s.controlSize = .regular
        s.setAccessibilityLabel(title)
        if let help { s.setAccessibilityHelp(help) }
        return s
    }

    static func segmented(_ labels: [String], title: String, target: AnyObject?, action: Selector) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: target, action: action)
        c.segmentStyle = .rounded
        c.setAccessibilityLabel(title)
        return c
    }

    static func button(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        return b
    }

    static func symbol(_ name: String, label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)
    }
}

/// Slider with a live `digits` readout ("90 %", "8 pt"); the slider carries the spoken value.
enum UISlider {
    static func make(title: String, min: Double, max: Double, ticks: Int,
                     target: AnyObject?, action: Selector) -> (slider: NSSlider, readout: NSTextField) {
        let slider = NSSlider(value: min, minValue: min, maxValue: max, target: target, action: action)
        slider.numberOfTickMarks = ticks
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.setAccessibilityLabel(title)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        slider.heightAnchor.constraint(greaterThanOrEqualToConstant: UIControls.minimumTarget).isActive = true
        let readout = UIText.digitsValue("0", spoken: "0")
        readout.alignment = .right
        readout.setAccessibilityElement(false)
        readout.translatesAutoresizingMaskIntoConstraints = false
        readout.widthAnchor.constraint(equalToConstant: 48).isActive = true
        return (slider, readout)
    }

    static func stack(_ slider: NSSlider, _ readout: NSTextField) -> NSStackView {
        let stack = NSStackView(views: [slider, readout])
        stack.orientation = .horizontal
        stack.spacing = Theme.Space.s2
        return stack
    }

    static func set(_ slider: NSSlider, _ readout: NSTextField, value: Double, unit: String, spokenUnit: String) {
        slider.doubleValue = value
        let v = Int(value.rounded())
        readout.stringValue = "\(v) \(unit)"
        slider.setAccessibilityValueDescription("\(v) \(spokenUnit)")
    }
}

/// Settings form on a two-column NSGridView (DESIGN §8): the row title on the left, its control on
/// the right. No group headers: groups are 20 pt (s5) apart, rows inside a group 12 pt (s3), and a
/// help line (callout, one line) sits 4 pt (s1) under its row.
final class SettingsForm {
    static let windowWidth: CGFloat = 560
    static let contentWidth: CGFloat = windowWidth - 2 * Theme.Space.s5

    let grid: NSGridView
    private var startsGroup = false
    private var rowCount = 0
    private var trailingViews: [NSView] = []

    init() {
        grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = Theme.Space.s3
        grid.rowSpacing = 0
        grid.yPlacement = .center
    }

    /// The next row starts a new group, 20 pt below the previous one.
    func group() {
        startsGroup = true
    }

    private func topPadding(isHelp: Bool) -> CGFloat {
        if rowCount == 0 { return 0 }
        if isHelp { return Theme.Space.s1 }
        return startsGroup ? Theme.Space.s5 : Theme.Space.s3
    }

    @discardableResult
    private func add(_ views: [NSView], merged: Bool, isHelp: Bool = false, padding: CGFloat? = nil) -> NSGridRow {
        let top = padding ?? topPadding(isHelp: isHelp)
        let row = grid.addRow(with: views)
        row.topPadding = top
        if merged { row.mergeCells(in: NSRange(location: 0, length: 2)) }
        startsGroup = false
        rowCount += 1
        return row
    }

    /// Title + trailing control (switch, segmented control, popup, slider stack…). `tooltip` goes on
    /// the title and the control alike.
    @discardableResult
    func row(_ title: String, control: NSView, tooltip: String? = nil) -> NSGridRow {
        let titleLabel = UIText.label(title)
        // The control itself carries the spoken label (and help); VoiceOver would otherwise read the
        // row title twice.
        titleLabel.setAccessibilityElement(false)
        if let tooltip {
            titleLabel.toolTip = tooltip
            control.toolTip = tooltip
        }
        trailingViews.append(control)
        let row = add([titleLabel, control], merged: false)
        grid.cell(for: titleLabel)?.xPlacement = .leading
        grid.cell(for: control)?.xPlacement = .trailing
        return row
    }

    /// Secondary help line under the previous row (one line, callout).
    @discardableResult
    func help(_ text: String) -> (NSGridRow, NSTextField) {
        let field = UIText.callout(text, width: Self.contentWidth)
        let row = add([field, NSGridCell.emptyContentView], merged: true, isHelp: true)
        return (row, field)
    }

    /// A view spanning both columns (tables, cards, the zone map, buttons).
    @discardableResult
    func wide(_ view: NSView, xPlacement: NSGridCell.Placement = .leading, padding: CGFloat? = nil) -> NSGridRow {
        let row = add([view, NSGridCell.emptyContentView], merged: true, padding: padding)
        grid.cell(for: view)?.xPlacement = xPlacement
        return row
    }

    @discardableResult
    func separator() -> NSGridRow {
        let line = NSBox()
        line.boxType = .separator
        return wide(line, xPlacement: .fill, padding: startsGroup ? Theme.Space.s5 : Theme.Space.s3)
    }

    /// Fixes the column widths: the controls column is as wide as its widest control.
    func finish() -> NSGridView {
        let controlsWidth = ceil(trailingViews.map { $0.fittingSize.width }.max() ?? 0)
        grid.column(at: 1).width = controlsWidth
        grid.column(at: 0).width = Self.contentWidth - Theme.Space.s3 - controlsWidth
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        return grid
    }
}

/// Top-left anchored document view for pane scroll views.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Rounded panel (r.m) with a hairline border; Increase Contrast makes the border ink.
class PanelView: NSView {
    var fill: NSColor = Theme.Color.paperRaised { didSet { needsDisplay = true } }
    var radius: CGFloat = Theme.Radius.medium

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        let highContrast = AccessibilityEnv.shared.increaseContrast
        (highContrast ? Theme.Color.ink : Theme.Color.hairline).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Settings tabs share this: frame-based root (any size the tab view gives it) holding a scroll
/// view, so a tab taller than the screen scrolls instead of being cut off. Content is top-anchored
/// with s5 (20 pt) insets. `preferredContentSize` is the content's fitting size.
class SettingsPaneController: NSViewController {
    unowned let app: AppController
    /// The app's preferences; offscreen tools hand in a scratch instance.
    let prefs: Preferences
    private(set) var documentView = FlippedView()
    private var contentView: NSView?

    init(app: AppController, prefs: Preferences, title: String) {
        self.app = app
        self.prefs = prefs
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { nil }

    /// Subclasses build their content (fixed width `SettingsForm.contentWidth`).
    func makeContent() -> NSView { NSView() }
    func refresh() {}
    func noteSnap(_ event: NoktaEvent) {}

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: SettingsForm.windowWidth, height: 400))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = documentView

        let content = makeContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(content)
        let inset = Theme.Space.s5
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: inset),
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: inset),
            content.widthAnchor.constraint(equalToConstant: SettingsForm.contentWidth),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -inset),
        ])
        contentView = content
        view = scroll
        refresh()
        updatePreferredSize()
    }

    /// Call after content changes height (rows shown/hidden); the tab controller resizes the window.
    func updatePreferredSize() {
        guard let contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let height = ceil(contentView.fittingSize.height) + 2 * Theme.Space.s5
        let size = NSSize(width: SettingsForm.windowWidth, height: height)
        if preferredContentSize != size { preferredContentSize = size }
    }

    var window: NSWindow? { view.window }
}

#if NOKTA_SNAPSHOT
/// Tests: every announcement made, in order.
enum Announcements {
    static var log: [String] = []
}
#endif

extension NSResponder {
    /// VoiceOver announcement from any view (DESIGN §15).
    func announce(_ text: String, high: Bool = false) {
        #if NOKTA_SNAPSHOT
        Announcements.log.append(text)
        #endif
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: (high ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
        ])
    }
}

/// Grid rows hidden/shown together (help lines, conditional rows).
extension NSGridRow {
    func setHidden(_ hidden: Bool) {
        if isHidden != hidden { isHidden = hidden }
    }
}
