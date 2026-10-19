import AppKit
import QuartzCore

/// The persistent onboarding stage (docs/DESIGN.md §11): 480 × 200, r 12, `paper.raised` with a
/// hairline edge (Increase Contrast: 1 pt ink). It never moves; only the scene inside it changes.
/// Scenes attach their root layers to `content` (clipped to the rounded rect); the edge is drawn
/// above them.
///
/// For VoiceOver the stage is one image with the scene's label and a `Replay` action (AXPress does
/// the same). A click — or Space while it has focus with Full Keyboard Access — replays the scene;
/// it is a Tab stop only with Full Keyboard Access. Layers only, no `draw(_:)`.
final class StageView: NSView {
    let content = CALayer()
    private let edge = CALayer()

    var onReplay: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    /// The scene shown (its label and value are the stage's).
    weak var scene: StageScene? {
        didSet { NSAccessibility.post(element: self, notification: .titleChanged) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for l in [content, edge] {
            l.delegate = NoImplicitActions.shared
            l.cornerRadius = Theme.Radius.stage
            l.cornerCurve = .continuous
            layer?.addSublayer(l)
        }
        content.masksToBounds = true
        edge.borderWidth = 1
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        edge.frame = bounds
        CATransaction.commit()
    }

    func apply(_ p: StagePalette) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.backgroundColor = p.paperRaised
        edge.borderColor = p.raisedEdge
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onAppearanceChange?()
    }

    // MARK: input

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onReplay?() }

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onReplay?()
        } else {
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.stage, yRadius: Theme.Radius.stage).fill()
    }

    // MARK: accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { scene?.accessibilityLabel }
    override func accessibilityValue() -> Any? { scene?.accessibilityValue }
    override func accessibilityHelp() -> String? { "Press to replay." }
    override func accessibilityPerformPress() -> Bool {
        onReplay?()
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Replay") { [weak self] in
            self?.onReplay?()
            return true
        }]
    }
}
