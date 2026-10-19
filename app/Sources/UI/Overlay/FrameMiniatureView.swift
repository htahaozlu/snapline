import AppKit
import QuartzCore

/// A frame drawn at scene scale on Nokta's own paper surfaces (docs/DESIGN.md §8 ZoneMap result
/// zone, §11 scenes). It hosts a `FrameLayerTree(style: .miniature(…))` and moves with the overlay's
/// own timelines (`OverlayTimelines`), so a preview never draws or moves differently from the real
/// overlay. Layers only, no `draw(_:)`.
///
///   * `show(fraction:animated:)` — the target as a unit-square fraction of the view (x, y from the
///     top left); later changes glide like O2 (140 ms, Reduce Motion: instant).
///   * `playEntry()` — O1 at this scale, once, only while a `MotionGate` is open; with the gate
///     closed or Reduce Motion on the rest pose is shown instead (O1's rest = its `explainT`).
final class FrameMiniatureView: NSView {
    let tree: FrameLayerTree
    /// Offscreen tools: fixed appearance / scale instead of the window's.
    var appearanceOverride: NSAppearance? { didSet { applyColors() } }
    var scaleOverride: CGFloat? { didSet { needsLayout = true } }

    private(set) var fraction: CGRect?
    private let gate = MotionGate()
    private var entryPending = false
    /// Surface the tree was last laid out for; layout passes that keep it leave a running
    /// transition alone.
    private var laidOut: (size: CGSize, scale: CGFloat)?

    /// `scale`: geometry relative to the overlay (ZoneMap ≈ 0.25); `period`: may show R1.
    init(frame: NSRect = .zero, scale: CGFloat = 0.25, period: Bool = false) {
        tree = FrameLayerTree(style: .miniature(scale, period: period))
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false) // decorative; the owner's text carries the meaning
        layer?.addSublayer(tree.root)
        tree.root.isHidden = true
        gate.onChange = { [weak self] open in self?.gateChanged(open) }
    }

    required init?(coder: NSCoder) { nil }

    private var effectiveScale: CGFloat { scaleOverride ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        gate.attach(to: window)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let surface = (size: bounds.size, scale: effectiveScale)
        if let laidOut, laidOut.size == surface.size, laidOut.scale == surface.scale { return }
        laidOut = surface
        tree.setSurface(size: surface.size, scale: surface.scale)
        applyColors()
        place(animated: false)
    }

    private func applyColors() {
        tree.apply(OverlayPalette.resolve(appearance: appearanceOverride ?? effectiveAppearance, surface: .paper))
    }

    private func rect(for f: CGRect) -> CGRect {
        CGRect(x: f.minX * bounds.width, y: f.minY * bounds.height, width: f.width * bounds.width, height: f.height * bounds.height)
    }

    /// Shows the target (unit-square fraction); `.zero` or nil clears it.
    func show(fraction f: CGRect?, animated: Bool) {
        let previous = fraction
        fraction = (f?.isEmpty ?? true) ? nil : f
        guard previous != nil || fraction != nil else { return }
        place(animated: animated && previous != nil && window != nil)
    }

    func clear() { show(fraction: nil, animated: false) }

    private func place(animated: Bool) {
        guard bounds.width > 0, tree.palette != nil else { return }
        guard let f = fraction else {
            tree.root.isHidden = true
            tree.current = nil
            return
        }
        let start = tree.current?.start ?? AnchorSide(fraction: f)
        let next = tree.frame(rect: rect(for: f), start: start)
        let rest = OverlayTimelines.entry(tree, next, reduceMotion: false).restPose
        if animated, let current = tree.current, !AccessibilityEnv.shared.reduceMotion {
            let from = tree.presentationPose(like: OverlayTimelines.geometryKeys(tree, current))
            tree.play([OverlayTimelines.move(tree, to: next, from: from, reduceMotion: false)])
        } else {
            tree.reset()
            PoseApplier.apply(rest, to: tree.layers)
        }
        tree.current = next
        tree.root.isHidden = false
    }

    // MARK: entry demo

    /// Plays O1 once at this scale (onboarding). Waits for the gate; never loops.
    func playEntry() {
        entryPending = true
        gate.isActive = true
        if gate.isOpen { gateChanged(true) }
    }

    private func gateChanged(_ open: Bool) {
        guard let current = tree.current else { return }
        let entry = OverlayTimelines.entry(tree, current, reduceMotion: false)
        if open, entryPending {
            entryPending = false
            tree.play([entry]) { [weak self] in self?.gate.isActive = false }
        } else if !open {
            // Closed (hidden, occluded, miniaturized, Reduce Motion): no animation, rest pose.
            tree.reset()
            PoseApplier.apply(entry.restPose, to: tree.layers)
        }
    }
}
