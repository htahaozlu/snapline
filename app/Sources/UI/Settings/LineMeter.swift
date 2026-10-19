import AppKit

/// LineMeter (DESIGN §8): the memory line in Settings › About. A 120 × 12 pt track (2 pt, `ink.3`),
/// the value as an `ink` line from the left, a tick at the 12 MB target. What passes the tick is
/// drawn in red (R5, "attention"), and the row says `over 12 MB target` in words next to it.
/// The track spans 0 … 16 MB; a larger value fills it to the end. "Over" is judged on the value as
/// the row prints it (one decimal), so the row never says `12.0 MB` and `over 12 MB target`.
/// Static drawing, redrawn only when the value changes.
final class LineMeter: NSView {
    static let size = NSSize(width: 120, height: 12)
    /// What the full track stands for.
    static let range: UInt64 = 16 * 1024 * 1024

    var value: UInt64? { didSet { if value != oldValue { needsDisplay = true; NSAccessibility.post(element: self, notification: .valueChanged) } } }
    var budget: UInt64 = IntegrityProbe.memoryBudget

    override var intrinsicContentSize: NSSize { Self.size }

    var isOverBudget: Bool {
        guard let value else { return false }
        return Measure.printedMegabytes(value) > Measure.printedMegabytes(budget)
    }

    private func x(_ bytes: UInt64) -> CGFloat {
        bounds.width * CGFloat(min(bytes, Self.range)) / CGFloat(Self.range)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let highContrast = AccessibilityEnv.shared.increaseContrast
        let y = bounds.midY
        let tick = x(budget)

        func line(from a: CGFloat, to b: CGFloat, width: CGFloat, color: NSColor) {
            guard b > a else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.butt)
            ctx.move(to: CGPoint(x: a, y: y))
            ctx.addLine(to: CGPoint(x: b, y: y))
            ctx.strokePath()
        }

        line(from: 0, to: bounds.width, width: 2, color: highContrast ? Theme.Color.ink2 : Theme.Color.ink3)
        if let value {
            line(from: 0, to: min(x(value), tick), width: 4, color: Theme.Color.ink)
            if isOverBudget { line(from: tick, to: x(value), width: 4, color: Theme.Color.red) } // R5
        }
        ctx.setFillColor(Theme.Color.ink.cgColor)
        ctx.fill(CGRect(x: tick - 1, y: 0, width: 2, height: bounds.height)) // the 12 MB target
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }
    override func accessibilityLabel() -> String? { "Memory" }
    override func accessibilityValue() -> Any? {
        guard let value else { return NSNumber(value: 0) }
        return NSNumber(value: Double(value) / 1_048_576)
    }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    /// The full track (16 MB), or the value when it is larger: the value never exceeds the maximum.
    override func accessibilityMaxValue() -> Any? {
        NSNumber(value: Double(max(Self.range, value ?? 0)) / 1_048_576)
    }
    override func accessibilityValueDescription() -> String? {
        let base = "\(Measure.spokenMegabytes(value)) of \(budget / 1_048_576) megabyte target"
        return isOverBudget ? base + ", over the target" : base
    }
}
