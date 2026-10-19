import AppKit
import QuartzCore

/// Onboarding progress (docs/DESIGN.md §11): three 20 × 3 pt segments, r 1.5, 6 pt apart; done
/// and current `ink`, next `ink.3` — never red. One VoiceOver element: "Step 2 of 3". The colour
/// change belongs to the page transition (Storyboard D), so the segments are named layers.
final class ProgressSegments: NSView {
    static let count = 3
    static let segment = CGSize(width: 20, height: 3)
    static let gap: CGFloat = 6
    static func id(_ i: Int) -> LayerID { "progress.\(i)" }

    private let host = CALayer()
    private(set) var segments: [CALayer] = []
    private var palette: StagePalette?

    /// The step shown; set without animation (the transition animates the colours).
    var current = 0 {
        didSet {
            guard current != oldValue else { return }
            applyColors()
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        host.delegate = NoImplicitActions.shared
        host.isGeometryFlipped = true
        layer?.addSublayer(host)
        for i in 0..<Self.count {
            let s = CALayer()
            s.delegate = NoImplicitActions.shared
            s.anchorPoint = .zero
            s.bounds = CGRect(origin: .zero, size: Self.segment)
            s.position = CGPoint(x: CGFloat(i) * (Self.segment.width + Self.gap), y: 0)
            s.cornerRadius = Self.segment.height / 2
            host.addSublayer(s)
            segments.append(s)
        }
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(Self.count) * Self.segment.width + CGFloat(Self.count - 1) * Self.gap, height: Self.segment.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = CGRect(x: 0, y: ((bounds.height - Self.segment.height) / 2).rounded(), width: bounds.width, height: Self.segment.height)
        CATransaction.commit()
    }

    func apply(_ p: StagePalette) {
        palette = p
        applyColors()
    }

    /// Done and current steps are ink, the rest ink.3.
    func color(_ i: Int, current c: Int) -> CGColor? {
        guard let palette else { return nil }
        return i <= c ? palette.ink : palette.ink3
    }

    var layers: [LayerID: CALayer] {
        Dictionary(uniqueKeysWithValues: segments.enumerated().map { (Self.id($0.offset), $0.element) })
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, s) in segments.enumerated() { s.backgroundColor = color(i, current: current) }
        CATransaction.commit()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { "Step \(current + 1) of \(Self.count)" }
}
