import AppKit
import QuartzCore

/// Drag-snap preview, keyboard-snap flash and the label plate (docs/DESIGN.md §9). API:
/// `showPreview`, `hidePreview(committed:)`, `flash`, `showLabel`, `dismissLabel`,
/// `screensChanged`, `surface(for:)`, `headless`, `appearanceOverride`.
/// Event rects are CG global; they are converted with `Screens.appKitRect(fromCG:)`.
///
/// One lazily created, reused borderless panel per screen; nothing runs while hidden (every
/// transition ends with orderOut + removeAllAnimations). Each transition is one `OverlayTimelines`
/// timeline added in one CATransaction; layer work happens only when the zone identity changes —
/// the core already sends one event per change.
final class SnapOverlayController {
    /// UserDefaults keys this controller reads (the shell's Settings writes them).
    enum DefaultsKey {
        /// Bool, default true — Shortcuts › Flash after snap.
        static let flashOnKeyboardSnap = "flashOnKeyboardSnap"
    }

    /// Offscreen tools set this: surfaces never create or order windows.
    static var headless = false

    let defaults: UserDefaults
    private var surfaces: [CGDirectDisplayID: OverlaySurface] = [:]
    private weak var previewSurface: OverlaySurface?
    private var lastAnnouncement: CFTimeInterval = 0
    private var lastAnnouncedTitle: String?
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .noktaAccessibilityChanged, object: nil, queue: .main) { [weak self] _ in
            self?.invalidateColors()
        })
        if let app = NSApp {
            appearanceObservation = app.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.invalidateColors() }
            }
        }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    var flashOnKeyboardSnap: Bool {
        defaults.object(forKey: DefaultsKey.flashOnKeyboardSnap) as? Bool ?? true
    }

    /// The appearance overlay colours resolve against (tests override it).
    var appearanceOverride: NSAppearance? { didSet { invalidateColors() } }
    var appearance: NSAppearance {
        appearanceOverride ?? NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!
    }

    private func invalidateColors() {
        for s in surfaces.values { s.paletteDirty = true }
    }

    private var reduceMotion: Bool { AccessibilityEnv.shared.reduceMotion }

    // MARK: surfaces

    func surface(for displayID: CGDirectDisplayID, rectCG: CGRect? = nil) -> OverlaySurface? {
        let screen = Screens.screen(for: displayID)
            ?? rectCG.flatMap { r in NSScreen.screens.first { $0.cgFrame.contains(CGPoint(x: r.midX, y: r.midY)) } }
            ?? NSScreen.main
        guard let screen else { return nil }
        return surface(for: screen)
    }

    func surface(for screen: NSScreen) -> OverlaySurface {
        let id = screen.displayID
        if let s = surfaces[id], s.matches(screen) { return s }
        surfaces[id]?.tearDown()
        let s = OverlaySurface(screen: screen, headless: Self.headless)
        surfaces[id] = s
        return s
    }

    /// Prepares a surface for a transition: colours, then the panel. The panel is ordered in
    /// *before* the transition's transaction, so its animations are added to a tree that already
    /// has a render context (the root stays hidden until that transaction reveals it).
    private func prepare(_ s: OverlaySurface) {
        s.refreshPalette(appearance: appearance)
        s.show()
    }

    /// Hides every surface except `keep` immediately (only the cursor's screen shows a preview).
    private func hideOthers(_ keep: OverlaySurface?) {
        for s in surfaces.values where s !== keep && s.isVisible { s.hideNow() }
    }

    // MARK: drag preview (O1, O2)

    func showPreview(_ event: NoktaEvent) {
        guard let s = surface(for: event.displayID, rectCG: event.rect) else { return }
        let local = FrameGeometry.localRect(fromCG: event.rect, screen: s.screen)
        let side = event.zone.map(AnchorSide.init(zone:)) ?? AnchorSide(action: event.action, portrait: s.isPortrait)
        let rm = reduceMotion
        hideOthers(s)
        prepare(s)
        let tree = s.tree

        if s.state == .preview, previewSurface === s, let current = tree.current {
            // O2 zone change: keep the path's start so it interpolates; cut an entry still drawing.
            s.nextGeneration()
            let next = tree.frame(rect: local, start: current.start)
            let from = tree.presentationPose(like: OverlayTimelines.geometryKeys(tree, current))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            PoseApplier.removeAnimations(Self.entryStrokeKeys, from: tree.layers)
            tree.play([OverlayTimelines.move(tree, to: next, from: from, reduceMotion: rm)])
            CATransaction.commit()
            tree.current = next
            s.changeCount += 1
        } else {
            // O1 entry.
            s.nextGeneration()
            s.state = .preview
            let f = tree.frame(rect: local, start: side)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tree.reset()
            tree.root.isHidden = false
            tree.play([OverlayTimelines.entry(tree, f, reduceMotion: rm)])
            CATransaction.commit()
            tree.current = f
        }
        previewSurface = s
        announceZone(event.action)
    }

    /// O1's line drawing (`strokeStart/End` on line and halo): cut when a zone change or a drop
    /// arrives mid-entry, so the line on screen is the complete line the model already holds.
    private static let entryStrokeKeys = [FrameLayerTree.ID.line, FrameLayerTree.ID.halo].flatMap {
        [PoseKey($0, "strokeStart"), PoseKey($0, "strokeEnd")]
    }

    /// Drag ended. O4 commit when `committed` (the core's `NK_EVENT_FLAG_DROP`: the drag ended over a
    /// zone and the drop is applied right after this event), else O3 cancel (the cursor left every
    /// zone, a modifier changed, the tap was disabled or the core stopped). The core listens to the
    /// mouse only; there is no keyboard cancel. A commit during the entry cuts the line drawing
    /// first (as O2 does): the period lands on a complete line. A cancel fades the line as it is.
    func hidePreview(committed: Bool) {
        guard let s = previewSurface, s.state == .preview else { return }
        previewSurface = nil
        let rm = reduceMotion
        let gen = s.nextGeneration()
        s.state = .leaving
        let tree = s.tree
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let timeline: Timeline
        if committed, let f = tree.current {
            let scrim = (tree.scrim.presentation() ?? tree.scrim).opacity
            PoseApplier.removeAnimations(Self.entryStrokeKeys, from: tree.layers)
            timeline = OverlayTimelines.commit(tree, f, scrimFrom: Double(scrim), reduceMotion: rm)
        } else {
            var shape = Pose()
            shape[FrameLayerTree.ID.shape, "opacity"] = .scalar(1)
            timeline = OverlayTimelines.cancel(from: tree.presentationPose(like: shape), reduceMotion: rm)
        }
        tree.play([timeline]) { [weak s] in s?.finish(shapeGeneration: gen) }
        CATransaction.commit()
    }

    // MARK: keyboard flash (O5)

    /// The *actual* frame (the event's rect already holds it when `frameDiffers`) flashes with the
    /// period; a new flash interrupts the previous one. A live drag owns the surface.
    func flash(_ event: NoktaEvent) {
        guard event.kind == .snapped, flashOnKeyboardSnap, !event.rect.isEmpty,
              let s = surface(for: event.displayID, rectCG: event.rect) else { return }
        if s.state == .preview { return }
        let local = FrameGeometry.localRect(fromCG: event.rect, screen: s.screen)
        hideOthers(s)
        prepare(s)
        let gen = s.nextGeneration()
        s.state = .leaving
        let tree = s.tree
        let t = OverlayTimelines.flash(tree, rect: local, start: AnchorSide(action: event.action, portrait: s.isPortrait),
                                       reduceMotion: reduceMotion)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [tree.shape, tree.scrim, tree.halo, tree.line, tree.period] { l.removeAllAnimations() }
        tree.root.isHidden = false
        tree.play([t]) { [weak s] in s?.finish(shapeGeneration: gen) }
        CATransaction.commit()
        tree.current = nil
    }

    // MARK: label plate (O6, O7; used by HUDController)

    /// Shows the label plate: centred on `rectCG` (CG global) when given, else on the screen under
    /// the cursor, inside the visible frame (never in the notch band). `blocked` adds O6 (the shake,
    /// and the window's frame as a 1.5 pt line when known) and the long hold (2000 ms).
    func showLabel(_ text: String, rectCG: CGRect?, displayID: CGDirectDisplayID, blocked: Bool) {
        let s: OverlaySurface?
        if let r = rectCG, !r.isEmpty {
            s = surface(for: displayID, rectCG: r)
        } else {
            let mouse = NSEvent.mouseLocation
            s = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main).map { surface(for: $0) }
        }
        guard let s else { return }
        if s.state == .preview, !blocked { return } // never cover a live drag preview
        hideOthers(s)
        prepare(s)
        let rm = reduceMotion
        let tree = s.tree
        let local = rectCG.flatMap { $0.isEmpty ? nil : FrameGeometry.localRect(fromCG: $0, screen: s.screen) }
        let visible = s.visibleLocalRect
        let center = local.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: visible.midX, y: visible.midY)
        let plateGen = s.nextPlateGeneration()
        var shapeGen: Int?
        s.plateVisible = true
        // No transition owns the frame: the plate shows alone, the frame stays invisible.
        let frameIdle = s.state == .hidden

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tree.root.isHidden = false
        for l in [tree.plate, tree.text] { l.removeAllAnimations() }
        let platePose = tree.setLabel(text, center: center, within: visible)
        var timelines = [OverlayTimelines.label(plate: platePose, blocked: blocked, hidesFrame: frameIdle)]
        if blocked {
            // The frame that could not be set, unless a drag preview is on screen.
            let frame = s.state == .preview ? nil : local
            if frame != nil {
                shapeGen = s.nextGeneration()
                for l in [tree.shape, tree.scrim, tree.halo, tree.line, tree.period] { l.removeAllAnimations() }
                s.state = .leaving
                tree.current = nil
            }
            timelines.append(OverlayTimelines.blocked(tree, frame: frame, reduceMotion: rm))
        }
        tree.play(timelines) { [weak s] in
            if let shapeGen { s?.finish(shapeGeneration: shapeGen) }
            s?.finish(plateGeneration: plateGen)
        }
        CATransaction.commit()
    }

    /// Hides any label at once (the next input interrupts a long blocked label).
    func dismissLabel() {
        for s in surfaces.values where s.plateVisible {
            s.nextPlateGeneration()
            s.tree.clearLabel()
            s.plateVisible = false
            s.orderOutIfIdle()
        }
    }

    // MARK: screens

    /// Screen configuration changed: panels are rebuilt lazily on next use.
    func screensChanged() {
        for s in surfaces.values { s.tearDown() }
        surfaces.removeAll()
        previewSurface = nil
    }

    // MARK: VoiceOver

    /// Zone-change announcement while VoiceOver runs, at most one per 300 ms (§9 O1).
    private func announceZone(_ action: NoktaAction?) {
        guard let action, AccessibilityEnv.shared.voiceOverEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastAnnouncement >= 0.3 || lastAnnouncedTitle == nil else { return }
        lastAnnouncement = now
        lastAnnouncedTitle = action.title
        AccessibilityEnv.announce(action.title)
    }
}

/// One screen's panel + layer tree.
final class OverlaySurface {
    enum State { case hidden, preview, leaving }

    let screen: NSScreen
    let tree = FrameLayerTree(style: .overlay)
    private(set) var panel: NSPanel?
    private let headless: Bool
    var state: State = .hidden
    var plateVisible = false
    var paletteDirty = true
    private(set) var generation = 0
    private(set) var plateGeneration = 0
    /// Zone changes since creation (one CATransaction each; DESIGN §17.4 counter).
    var changeCount = 0
    private let frame: CGRect
    private let scale: CGFloat

    init(screen: NSScreen, headless: Bool) {
        self.screen = screen
        self.headless = headless
        frame = screen.frame
        scale = screen.backingScaleFactor
        tree.setSurface(size: screen.frame.size, scale: screen.backingScaleFactor)
        tree.root.isHidden = true
    }

    var isPortrait: Bool { screen.visibleFrame.height > screen.visibleFrame.width }
    var isVisible: Bool { state != .hidden || plateVisible }
    /// Below the menu bar and the notch, in the tree's coordinates.
    var visibleLocalRect: CGRect { FrameGeometry.visibleLocalRect(screen) }

    func matches(_ s: NSScreen) -> Bool { s.frame == frame && s.backingScaleFactor == scale }

    @discardableResult
    func nextGeneration() -> Int { generation += 1; return generation }
    @discardableResult
    func nextPlateGeneration() -> Int { plateGeneration += 1; return plateGeneration }

    func refreshPalette(appearance: NSAppearance) {
        guard paletteDirty || tree.palette == nil else { return }
        paletteDirty = false
        tree.apply(OverlayPalette.resolve(appearance: appearance))
    }

    private func makePanel() -> NSPanel {
        let p = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.worksWhenModal = true
        p.isReleasedWhenClosed = false
        p.isExcludedFromWindowsMenu = true
        p.setAccessibilityElement(false)
        let host = NSView(frame: CGRect(origin: .zero, size: frame.size))
        host.wantsLayer = true
        host.layerContentsRedrawPolicy = .never
        host.setAccessibilityElement(false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tree.root.isHidden = true // revealed by the first transition's transaction
        CATransaction.commit()
        host.layer?.addSublayer(tree.root)
        p.contentView = host
        p.setFrame(frame, display: false)
        return p
    }

    /// Orders the panel in (creating it on first use). Callers do this before adding animations.
    func show() {
        guard !headless else { return }
        if panel == nil { panel = makePanel() }
        if panel?.isVisible == false { panel?.orderFrontRegardless() }
    }

    func finish(shapeGeneration gen: Int) {
        guard gen == generation, state == .leaving else { return }
        state = .hidden
        orderOutIfIdle()
    }

    func finish(plateGeneration gen: Int) {
        guard gen == plateGeneration else { return }
        plateVisible = false
        tree.clearLabel()
        orderOutIfIdle()
    }

    /// Hidden state: panel ordered out, no animations, root hidden (ordering in later never shows
    /// the last frame), the plate's text dropped (DESIGN §16 hidden-state memory).
    func orderOutIfIdle() {
        guard state == .hidden, !plateVisible else { return }
        panel?.orderOut(nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tree.reset()
        tree.clearLabel()
        tree.root.isHidden = true
        tree.current = nil
        CATransaction.commit()
        paletteDirty = true
    }

    /// Immediate hide (another screen took over).
    func hideNow() {
        nextGeneration()
        nextPlateGeneration()
        state = .hidden
        plateVisible = false
        orderOutIfIdle()
    }

    func tearDown() {
        hideNow()
        panel?.contentView = nil
        panel?.close()
        panel = nil
        tree.root.removeFromSuperlayer()
    }
}

/// Never key, never main (DESIGN §9).
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    /// The screen's frame in CG global coordinates (top-left origin).
    var cgFrame: CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
