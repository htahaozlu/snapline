import AppKit
import QuartzCore

// Overlay storyboards (docs/DESIGN.md §9 O1–O7), the real overlay controller's sequences, the
// menu bar icon (§7.1) and the action glyphs (§12), drawn offscreen. Nothing here animates: a
// storyboard frame is `apply(pose(at: t))` on a reset `FrameLayerTree`, a sequence frame is the
// controller's model with its attached animations evaluated at t; then `CALayer.render(in:)`
// (DESIGN §5.2 rule 8). Called from main.swift (and SelfTest for the sequence checks).

enum OverlayFrames {
    /// A 1440 × 900 stand-in screen with a 25 pt menu bar; Nokta's default 8 pt gaps.
    static let screen = CGSize(width: 1440, height: 900)
    static let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
    static let gap: CGFloat = 8
    static var leftHalf: CGRect { CGRect(x: gap, y: visible.minY + gap, width: visible.width / 2 - gap * 1.5, height: visible.height - 2 * gap) }
    static var leftTwoThirds: CGRect { CGRect(x: gap, y: visible.minY + gap, width: visible.width * 2 / 3 - gap * 1.5, height: visible.height - 2 * gap) }
    static var topLeft: CGRect { CGRect(x: gap, y: visible.minY + gap, width: visible.width / 2 - gap * 1.5, height: visible.height / 2 - gap * 1.5) }
    /// One of the stand-in desktop's windows (y-down copy of `desktopBackdrop`'s second window).
    static var window: CGRect {
        CGRect(x: screen.width * 0.12, y: screen.height - screen.height * 0.3 - screen.height * 0.42,
               width: screen.width * 0.3, height: screen.height * 0.42).integral
    }

    struct Scene {
        let id: String
        /// Storyboard moments (ms) rendered as PNG.
        let times: [Double]
        /// Timelines composed in order (later keys win); they all start at t = 0.
        let timelines: [Timeline]
        var duration: Double { timelines.map(\.duration).max() ?? 0 }
    }

    /// A timeline that only holds a pose (the state an interruption starts from).
    static func still(_ pose: Pose) -> Timeline { Timeline(name: "still", duration: 0, base: pose) }

    static func scenes(_ tree: FrameLayerTree, reduceMotion rm: Bool = false) -> [Scene] {
        let left = tree.frame(rect: leftHalf, start: .left)
        let previewRest = OverlayTimelines.entry(tree, left, reduceMotion: rm).restPose
        let quarter = tree.frame(rect: topLeft, start: left.start) // O2 keeps the path's start
        tree.clearLabel()
        let ratio = tree.setLabel("Left ⅔", center: CGPoint(x: leftTwoThirds.midX, y: leftTwoThirds.midY), within: visible)
        let ratioLabel = OverlayTimelines.label(plate: ratio, blocked: false)
        let cantMove = tree.setLabel("Can't move", center: CGPoint(x: window.midX, y: window.midY), within: visible)
        return [
            Scene(id: "o1", times: [0, 20, 60, 100, 140, 180], timelines: [OverlayTimelines.entry(tree, left, reduceMotion: rm)]),
            Scene(id: "o2", times: [0, 35, 70, 105, 140], timelines: [
                still(previewRest),
                OverlayTimelines.move(tree, to: quarter, from: OverlayTimelines.geometryKeys(tree, left), reduceMotion: rm),
            ]),
            Scene(id: "o4", times: [0, 40, 80, 100, 140, 200, 260], timelines: [
                still(previewRest),
                OverlayTimelines.commit(tree, left, scrimFrom: nil, reduceMotion: rm),
            ]),
            Scene(id: "o5", times: [0, 50, 100, 150, 200, 240], timelines: [
                OverlayTimelines.flash(tree, rect: leftTwoThirds, start: .left, reduceMotion: rm),
            ]),
            Scene(id: "o6", times: [0, 45, 90, 135, 180, 300, 1200, 2250], timelines: [
                OverlayTimelines.label(plate: cantMove, blocked: true),
                OverlayTimelines.blocked(tree, frame: window, reduceMotion: rm),
            ]),
            Scene(id: "o7", times: [0, 45, 90, 400, 790, 870, 950], timelines: [ratioLabel]),
        ]
    }

    /// Puts the tree in the scene's pose at `t` (plate text set for the scenes that show one).
    /// The scene starts from the tree's own hidden state (`reset()`), not from a pose made up
    /// here: whatever reset leaves shows in the render, the way the controller would show it.
    static func pose(_ scene: Scene, at t: Double, tree: FrameLayerTree) {
        tree.reset()
        tree.root.isHidden = false
        switch scene.id {
        case "o6": tree.setLabel("Can't move", center: CGPoint(x: window.midX, y: window.midY), within: visible)
        case "o7": tree.setLabel("Left ⅔", center: CGPoint(x: leftTwoThirds.midX, y: leftTwoThirds.midY), within: visible)
        default: tree.clearLabel()
        }
        let p = scene.timelines.reduce(Pose()) { $0.merging($1.pose(at: t)) }
        PoseApplier.apply(p, to: tree.layers)
    }

    static func makeTree(appearance: NSAppearance, scale: CGFloat, env: AccessibilityEnv.Snapshot = .init()) -> FrameLayerTree {
        let tree = FrameLayerTree(style: .overlay)
        tree.setSurface(size: screen, scale: scale)
        tree.apply(OverlayPalette.resolve(appearance: appearance, env: env))
        // On screen the root's flip is relative to the panel's (unflipped) host layer; give it one
        // here too, so `render(in:)` draws it the way the panel shows it.
        let host = CALayer()
        host.delegate = NoImplicitActions.shared
        host.anchorPoint = .zero
        host.bounds = CGRect(origin: .zero, size: screen)
        host.addSublayer(tree.root)
        return tree
    }

    /// The layer to render: the root's host.
    static func host(_ tree: FrameLayerTree) -> CALayer { tree.root.superlayer ?? tree.root }

    /// Storyboard PNGs + a ~30 fps GIF per scene, light and dark.
    static func renderAll() {
        for (mode, appearance) in appearances {
            let tree = makeTree(appearance: appearance, scale: 1)
            let backdrop = desktopBackdrop(dark: mode == "dark")
            for scene in scenes(tree) {
                for t in scene.times {
                    pose(scene, at: t, tree: tree)
                    write(render(layer: host(tree), size: screen, appearance: appearance, scale: 1, backdrop: backdrop),
                          String(format: "overlay-%@-t%04d-%@", scene.id, Int(t.rounded()), mode))
                }
                // GIF: 30 fps through the timeline plus 10 frames of rest, half size.
                let step = 1000.0 / 30
                var frames: [CGImage] = []
                var t = 0.0
                while t <= scene.duration + step * 10 {
                    pose(scene, at: min(t, scene.duration), tree: tree)
                    if let img = render(layer: host(tree), size: screen, appearance: appearance, scale: 0.5, backdrop: backdrop) { frames.append(img) }
                    t += step
                }
                writeGIF(frames, frameDelay: 1.0 / 30, "overlay-\(scene.id)-\(mode)")
            }
            // Reduce Motion: the static explain pose of each scene.
            for scene in scenes(tree, reduceMotion: true) where ["o1", "o4", "o5"].contains(scene.id) {
                let explain = scene.timelines.last?.explainT ?? 0
                pose(scene, at: explain, tree: tree)
                write(render(layer: host(tree), size: screen, appearance: appearance, scale: 1, backdrop: backdrop),
                      "overlay-\(scene.id)-rm-\(mode)")
            }
            renderZooms(appearance: appearance, mode: mode, backdrop: backdrop)
        }
    }

    /// Pixel checks: the committed frame's bottom-right corner (line, halo, period) and the plate,
    /// at 1x and 2x, magnified with nearest-neighbour sampling to the same size.
    static func renderZooms(appearance: NSAppearance, mode: String, backdrop: @escaping (CGContext, CGSize) -> Void) {
        // Increase Contrast + Differentiate Without Color + Reduce Transparency together.
        var a11y = AccessibilityEnv.Snapshot()
        a11y.increaseContrast = true
        a11y.differentiateWithoutColor = true
        a11y.reduceTransparency = true
        for (env, suffix) in [(AccessibilityEnv.Snapshot(), ""), (a11y, "-a11y")] {
            for scale: CGFloat in [1, 2] {
                renderZooms(appearance: appearance, mode: mode, scale: scale, env: env, suffix: suffix, backdrop: backdrop)
            }
        }
    }

    static func renderZooms(appearance: NSAppearance, mode: String, scale: CGFloat, env: AccessibilityEnv.Snapshot, suffix: String,
                            backdrop: @escaping (CGContext, CGSize) -> Void) {
        let tree = makeTree(appearance: appearance, scale: scale, env: env)
        let all = scenes(tree)
        let s = "\(Int(scale))x" + suffix
        if let commit = all.first(where: { $0.id == "o4" }) {
            pose(commit, at: 100, tree: tree) // period landed, fade just starting
            let crop = CGRect(x: leftHalf.maxX - 56, y: leftHalf.maxY - 44, width: 72, height: 56)
            write(zoom(renderCrop(host(tree), crop: crop, appearance: appearance, scale: scale, backdrop: backdrop), by: Int(8 / scale)),
                  "overlay-zoom-commit-corner-\(s)-\(mode)")
        }
        if let entry = all.first(where: { $0.id == "o1" }) {
            pose(entry, at: 180, tree: tree)
            let crop = CGRect(x: leftHalf.minX - 8, y: leftHalf.minY - 8, width: 72, height: 56)
            write(zoom(renderCrop(host(tree), crop: crop, appearance: appearance, scale: scale, backdrop: backdrop), by: Int(8 / scale)),
                  "overlay-zoom-preview-corner-\(s)-\(mode)")
        }
        if let label = all.first(where: { $0.id == "o7" }) {
            pose(label, at: 400, tree: tree)
            let f = tree.plate.frame
            let crop = f.insetBy(dx: -8, dy: -8).integral
            write(zoom(renderCrop(host(tree), crop: crop, appearance: appearance, scale: scale, backdrop: backdrop), by: Int(4 / scale)),
                  "overlay-zoom-plate-\(s)-\(mode)")
        }
    }

    /// Renders the `crop` part (tree coordinates, y down) of a flipped root at `scale`.
    static func renderCrop(_ layer: CALayer, crop: CGRect, appearance: NSAppearance, scale: CGFloat,
                           backdrop: (CGContext, CGSize) -> Void) -> CGImage? {
        let w = Int((crop.width * scale).rounded()), h = Int((crop.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // The root is geometry-flipped: tree y maps to context y = height − y.
        ctx.translateBy(x: -crop.minX, y: -(screen.height - crop.maxY))
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            backdrop(ctx, screen)
            displayRecursively(layer)
            layer.render(in: ctx)
            image = ctx.makeImage()
        }
        return image
    }

    /// Nearest-neighbour enlargement (keeps pixels visible).
    static func zoom(_ image: CGImage?, by k: Int) -> CGImage? {
        guard let image, k > 1,
              let ctx = CGContext(data: nil, width: image.width * k, height: image.height * k, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width * k, height: image.height * k))
        return ctx.makeImage()
    }

    // MARK: real controller sequences

    /// One core event, routed to the overlay and the HUD the way `AppController.handle` routes it,
    /// or `end`: what is running finishes the way Core Animation finishes it (the animations are
    /// removed, then the transitions' completion blocks run: `OverlaySurface.finish`).
    enum Step {
        /// previewShow from a drag.
        case enter(NoktaZone, NoktaAction, Target)
        /// previewHide; `committed` is the core's drop flag.
        case drop(committed: Bool)
        case snapped(NoktaAction, cycle: UInt32, source: NoktaEvent.Source, Target)
        /// A blocked snap whose window frame is unknown (the event's rect is empty).
        case failed(NoktaResult)
        case end
    }

    /// Targets inside the screen's visible frame, 8 pt gaps (CG global).
    enum Target {
        case leftHalf, leftTwoThirds

        func rect(in v: CGRect) -> CGRect {
            let w = self == .leftHalf ? v.width / 2 : v.width * 2 / 3
            return CGRect(x: v.minX + gap, y: v.minY + gap, width: w - gap * 1.5, height: v.height - 2 * gap).integral
        }
    }

    struct Sequence {
        let id: String
        var flashAfterSnap = true
        let steps: [Step]
        /// Moments drawn, ms after the last step started.
        let times: [Double]
    }

    /// The paths that once let a stale frame show under a plate-only label (OV2-1), the normal
    /// flash + label and a drop during the entry (OV2-5).
    static let sequences: [Sequence] = [
        // ⌃⌥← snaps Safari, then ⌃⌥← with no window: the plate alone, no frame.
        Sequence(id: "flash-noframe", steps: [.snapped(.leftHalf, cycle: 0, source: .keyboard, .leftHalf), .end, .failed(.noWindow)],
                 times: [90, 400, 1200]),
        // Flash after snap off: a drag snap, then a cycle press: the plate alone, no frame.
        Sequence(id: "commit-cycle", flashAfterSnap: false,
                 steps: [.enter(.left, .leftHalf, .leftHalf), .end, .drop(committed: true), .snapped(.leftHalf, cycle: 0, source: .drag, .leftHalf),
                         .end, .snapped(.leftHalf, cycle: 1, source: .keyboard, .leftTwoThirds)],
                 times: [90, 400]),
        // One cycle press with Flash after snap on: the plate rides over the flash.
        Sequence(id: "flash-label", steps: [.snapped(.leftHalf, cycle: 1, source: .keyboard, .leftTwoThirds)], times: [50, 150, 400]),
        // Dropped 0 ms into the entry: the line is complete, the period lands on it.
        Sequence(id: "commit-entry", steps: [.enter(.left, .leftHalf, .leftHalf), .drop(committed: true)], times: [0, 60, 140]),
    ]

    struct Run {
        let surface: OverlaySurface
        /// Layer time at which the last step started.
        let start: CFTimeInterval
        /// Keeps the controller (surfaces) and the HUD alive while the run is inspected.
        let owners: [AnyObject]
    }

    /// The screen the run uses: the one a label without a rect lands on (under the cursor).
    static var sequenceScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Runs `seq` on a fresh `SnapOverlayController` (headless surfaces, in-memory defaults) and a
    /// real `HUDController`. nil without a screen.
    static func run(_ seq: Sequence, appearance: NSAppearance, extraEnd: Bool = false) -> Run? {
        guard let screen = sequenceScreen, let defaults = ScratchDefaults(suiteName: "nokta.snapshot.scratch.overlay") else { return nil }
        defaults.set(seq.flashAfterSnap, forKey: SnapOverlayController.DefaultsKey.flashOnKeyboardSnap)
        let overlay = SnapOverlayController(defaults: defaults)
        overlay.appearanceOverride = appearance
        let hud = HUDController(prefs: Preferences(defaults: defaults), overlay: overlay)
        let display = screen.displayID
        let visible = Screens.appKitRect(fromCG: screen.visibleFrame) // CG global: the flip is its own inverse
        let surface = overlay.surface(for: screen)
        func event(_ kind: NoktaEvent.Kind, _ action: NoktaAction?, zone: NoktaZone? = nil, source: NoktaEvent.Source?,
                   result: NoktaResult = .ok, cycle: UInt32 = 0, rect: CGRect = .zero, drop: Bool = false) -> NoktaEvent {
            NoktaEvent(kind: kind, action: action, zone: zone, source: source, result: result, displayID: display, cycle: cycle,
                       rect: rect, latencyNs: 0, frameDiffers: false, sizeRefused: false, drop: drop)
        }
        var start = surface.tree.root.convertTime(CACurrentMediaTime(), from: nil)
        for step in seq.steps + (extraEnd ? [Step.end] : []) {
            if case .end = step {} else { start = surface.tree.root.convertTime(CACurrentMediaTime(), from: nil) }
            switch step {
            case let .enter(zone, action, target):
                overlay.showPreview(event(.previewShow, action, zone: zone, source: .drag, rect: target.rect(in: visible)))
            case let .drop(committed):
                overlay.hidePreview(committed: committed)
            case let .snapped(action, cycle, source, target):
                let e = event(.snapped, action, source: source, cycle: cycle, rect: target.rect(in: visible))
                if e.source != .drag { overlay.flash(e) } // AppController.handle(.snapped)
                hud.show(e)
            case let .failed(result):
                hud.show(event(.failed, .leftHalf, source: .keyboard, result: result))
            case .end:
                let tree = surface.tree
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for l in tree.allLayers { l.removeAllAnimations() }
                CATransaction.commit()
                if surface.state == .leaving { surface.finish(shapeGeneration: surface.generation) }
                if surface.plateVisible { surface.finish(plateGeneration: surface.plateGeneration) }
            }
        }
        return Run(surface: surface, start: start, owners: [overlay, hud])
    }

    /// A Core Animation value (`values`, model) as a `PoseValue`; nil for nil and unknown types.
    static func poseValue(_ any: Any?) -> PoseValue? {
        guard let any else { return nil }
        let cf = any as CFTypeRef
        if CFGetTypeID(cf) == CGPath.typeID { return PoseValue.from(any, like: .path(CGMutablePath())) }
        if CFGetTypeID(cf) == CGColor.typeID { return PoseValue.from(any, like: .color(CGColor(gray: 0, alpha: 0))) }
        if let n = any as? NSNumber { return .scalar(n.doubleValue) }
        guard let v = any as? NSValue else { return nil }
        let type = String(cString: v.objCType)
        if type.hasPrefix("{CGPoint") { return .point(v.pointValue) }
        if type.hasPrefix("{CGSize") { return .size(v.sizeValue) }
        if type.hasPrefix("{CGRect") { return .rect(v.rectValue) }
        return nil
    }

    /// `x` through a CA timing function (its control points; the linear function is linear).
    static func eased(_ f: CAMediaTimingFunction, _ x: Double) -> Double {
        var c1 = [Float](repeating: 0, count: 2), c2 = [Float](repeating: 0, count: 2)
        f.getControlPoint(at: 1, values: &c1)
        f.getControlPoint(at: 2, values: &c2)
        if x <= 0 || x >= 1 { return min(max(x, 0), 1) }
        return Ease.bezier(Ease.solve(x, Double(c1[0]), Double(c2[0])), Double(c1[1]), Double(c2[1]))
    }

    /// A keyframe animation's value at `time` (layer time) the way Core Animation evaluates it:
    /// keyTimes, one timing function per segment, linear or discrete; the first key before it
    /// begins (`fillMode .backwards`); nil once it has ended (removed on completion) or for an
    /// animation that is not a keyframe animation.
    static func value(of a: CAAnimation, at time: CFTimeInterval) -> PoseValue? {
        guard let k = a as? CAKeyframeAnimation, let raw = k.values, !raw.isEmpty, k.duration > 0 else { return nil }
        let local = time - k.beginTime
        if local >= k.duration { return nil }
        if local < 0 && k.fillMode != .backwards && k.fillMode != .both { return nil }
        let values = raw.compactMap(poseValue)
        let times = (k.keyTimes ?? []).map(\.doubleValue)
        guard values.count == raw.count, times.count == values.count else { return nil }
        let u = min(max(local / k.duration, 0), 1)
        if k.calculationMode == .discrete {
            var v = values[0]
            for (i, kt) in times.enumerated() where kt <= u { v = values[i] }
            return v
        }
        if u <= times[0] { return values[0] }
        let fns = k.timingFunctions ?? []
        for i in 0..<(values.count - 1) where u >= times[i] && u < times[i + 1] {
            let f = (u - times[i]) / (times[i + 1] - times[i])
            return PoseValue.lerp(values[i], values[i + 1], i < fns.count ? eased(fns[i], f) : f)
        }
        return values[values.count - 1]
    }

    /// What the render server shows at `time` for `layer.keyPath`: its animation, else the model.
    static func screenValue(_ tree: FrameLayerTree, _ id: LayerID, _ keyPath: String, at time: CFTimeInterval) -> PoseValue? {
        guard let layer = tree.layers[id] else { return nil }
        for key in layer.animationKeys() ?? [] {
            guard let a = layer.animation(forKey: key) as? CAPropertyAnimation, a.keyPath == keyPath else { continue }
            if let v = value(of: a, at: time) { return v }
        }
        return poseValue(layer.value(forKeyPath: keyPath))
    }

    /// Opacity on screen at `time` (0 when unreadable).
    static func screenOpacity(_ tree: FrameLayerTree, _ id: LayerID, at time: CFTimeInterval) -> Double {
        screenValue(tree, id, "opacity", at: time)?.scalarValue ?? 0
    }

    /// Whether the frame (scrim or line) can be seen at `time`.
    static func frameVisible(_ tree: FrameLayerTree, at time: CFTimeInterval) -> Bool {
        guard !tree.root.isHidden, screenOpacity(tree, "shape", at: time) > 0.01 else { return false }
        let scrim = screenOpacity(tree, "scrim", at: time) > 0.01 && tree.scrim.bounds.width > 0
        return scrim || screenValue(tree, "line", "path", at: time) != nil
    }

    /// Draws the tree as the render server would show it at `time`: every attached animation's
    /// value is written to the model for the render, then the model is restored.
    static func drawScreen(_ tree: FrameLayerTree, at time: CFTimeInterval, _ draw: () -> CGImage?) -> CGImage? {
        var saved: [(CALayer, String, Any?)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in tree.allLayers {
            for key in layer.animationKeys() ?? [] {
                guard let a = layer.animation(forKey: key) as? CAPropertyAnimation, let keyPath = a.keyPath,
                      let v = value(of: a, at: time) else { continue }
                saved.append((layer, keyPath, layer.value(forKeyPath: keyPath)))
                layer.setValue(v.caValue, forKeyPath: keyPath)
            }
        }
        CATransaction.commit()
        let image = draw()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, keyPath, value) in saved.reversed() { layer.setValue(value, forKeyPath: keyPath) }
        CATransaction.commit()
        return image
    }

    /// One line per run for the log: the model a later plate-only label would reveal.
    static func describe(_ tree: FrameLayerTree, at time: CFTimeInterval) -> String {
        func f(_ v: Double) -> String { String(format: "%.2f", v) }
        return "root \(tree.root.isHidden ? "hidden" : "shown") · shape \(f(screenOpacity(tree, "shape", at: time)))"
            + " · scrim \(f(screenOpacity(tree, "scrim", at: time))) · line \(tree.line.path == nil ? "none" : "path")"
            + " · plate \(f(screenOpacity(tree, "plate", at: time))) · frame \(frameVisible(tree, at: time) ? "VISIBLE" : "hidden")"
    }

    /// overlay-seq-<id>-t<ms>-<light|dark>.png: each sequence, light and dark, at its moments.
    static func renderSequences() {
        for (mode, appearance) in appearances {
            let backdrop = desktopBackdrop(dark: mode == "dark")
            for seq in sequences {
                guard let run = run(seq, appearance: appearance) else { print("skip overlay-seq-\(seq.id): no screen"); continue }
                let tree = run.surface.tree
                let host = CALayer()
                host.delegate = NoImplicitActions.shared
                host.anchorPoint = .zero
                host.bounds = CGRect(origin: .zero, size: tree.size)
                host.addSublayer(tree.root) // headless: the panel's host view does not exist
                for t in seq.times {
                    let time = run.start + t / 1000
                    let name = String(format: "overlay-seq-%@-t%04d-%@", seq.id, Int(t.rounded()), mode)
                    write(drawScreen(tree, at: time) {
                        render(layer: host, size: tree.size, appearance: appearance, scale: 1, backdrop: backdrop)
                    }, name)
                    if mode == "light" { print("  \(name): " + describe(tree, at: time)) }
                }
                tree.root.removeFromSuperlayer()
                withExtendedLifetime(run.owners) {}
            }
        }
    }

    // MARK: menu bar icon and action glyphs

    /// Template drawing → tinted bitmap of `size` pt at `scale`.
    static func tintedGlyph(size: CGSize, scale: CGFloat, tint: CGColor, draw: (CGContext) -> Void) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // y-down user space in points, like the NSImage(flipped: true) handlers.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(ctx)
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(tint)
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    /// Menu-bar-like strip with the icon where a status item draws it.
    static func menuIcon(_ state: Glyphs.StatusIconState, scale: CGFloat, dark: Bool, highContrast: Bool = false) -> CGImage? {
        let strip = CGSize(width: 48, height: 24)
        let w = Int(strip.width * scale), h = Int(strip.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(dark ? CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1) : CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let tint = dark ? CGColor(gray: 1, alpha: 0.95) : CGColor(gray: 0, alpha: 0.85)
        let icon = tintedGlyph(size: CGSize(width: 18, height: 18), scale: scale, tint: tint) { c in
            Glyphs.drawStatusIcon(state, in: c, onePixel: scale < 1.5, highContrast: highContrast)
        }
        if let icon { ctx.draw(icon, in: CGRect(x: 15 * scale, y: 3 * scale, width: 18 * scale, height: 18 * scale)) }
        return ctx.makeImage()
    }

    static func stateName(_ s: Glyphs.StatusIconState) -> String {
        switch s { case .active: return "active"; case .paused: return "paused"; case .needsPermission: return "needs-permission" }
    }

    /// menuicon-<state>-<1x|2x>-<light|dark>.png, plus an enlarged review sheet (incl. Increase Contrast).
    static func renderMenuIcons() {
        var sheet: [[CGImage]] = []
        for highContrast in [false, true] {
            for dark in [false, true] {
                var row: [CGImage] = []
                for state in Glyphs.StatusIconState.allCases {
                    for scale: CGFloat in [1, 2] {
                        guard let img = menuIcon(state, scale: scale, dark: dark, highContrast: highContrast) else { continue }
                        if !highContrast { write(img, "menuicon-\(stateName(state))-\(Int(scale))x-\(dark ? "dark" : "light")") }
                        if let z = zoom(img, by: scale == 1 ? 8 : 4) { row.append(z) }
                    }
                }
                sheet.append(row)
            }
        }
        write(contactSheet(sheet, gap: 8), "menuicon-sheet")
    }

    /// Every action glyph at 1x and 2x, enlarged, light and dark (review sheet).
    static func renderGlyphs() {
        var rows: [[CGImage]] = []
        for dark in [false, true] {
            for scale: CGFloat in [1, 2] {
                var row: [CGImage] = []
                for action in NoktaAction.allCases {
                    guard let fill = FrameGlyphs.fill(action) else { continue }
                    let tint = dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
                    let w = Int(20 * scale), h = Int(16 * scale)
                    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                    ctx.setFillColor(dark ? CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1) : CGColor(gray: 1, alpha: 1))
                    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    if let g = tintedGlyph(size: FrameGlyphs.size, scale: scale, tint: tint, draw: { FrameGlyphs.draw(fill: fill, in: $0) }) {
                        ctx.draw(g, in: CGRect(x: 2 * scale, y: 2 * scale, width: 16 * scale, height: 12 * scale))
                    }
                    if let img = ctx.makeImage(), let z = zoom(img, by: scale == 1 ? 6 : 3) { row.append(z) }
                }
                rows.append(row)
            }
        }
        write(contactSheet(rows, gap: 6), "glyphs-actions-sheet")
    }

    /// Rows of equally sized images on a neutral ground.
    static func contactSheet(_ rows: [[CGImage]], gap: Int) -> CGImage? {
        let cw = rows.flatMap { $0 }.map(\.width).max() ?? 0, ch = rows.flatMap { $0 }.map(\.height).max() ?? 0
        let cols = rows.map(\.count).max() ?? 0
        let w = cols * (cw + gap) + gap, h = rows.count * (ch + gap) + gap
        guard w > gap, h > gap, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.52, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (r, row) in rows.enumerated() {
            for (c, img) in row.enumerated() {
                ctx.draw(img, in: CGRect(x: gap + c * (cw + gap), y: h - (r + 1) * (ch + gap), width: img.width, height: img.height))
            }
        }
        return ctx.makeImage()
    }
}
