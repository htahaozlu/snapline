import AppKit

// Onboarding scenes — owned by the Onboarding surface; called from main.swift. Offscreen only: never order a
// window in, never activate the app (see main.swift). Nothing here animates: every frame is a storyboard's
// `pose(at: t)` applied by OnboardingWindowController.showStoryboard(at:), then drawn (DESIGN §5.2 rule 8).
//
// Output (per appearance):
//   onboarding-<1..3>[-granted]-<mode>.png           each screen at rest, without and with access
//   onboarding-<1..3>[-granted]-a11y-<mode>.png      the same with Increase Contrast + Differentiate Without Color
//   onboarding-3-practice-<state>-<mode>.png         screen 3 while practising (held, habit, tried, done)
//   onboarding-<A|B|C|E>-t<ms>-<mode>.png            storyboard frames (design-v2-opus.md §3.6 tables)
//   onboarding-D-<1to2|2to3>-t<ms>-<mode>.png        page transition frames
//   onboarding-<A|B|C|D|E>-rm-<mode>.png             the Reduce Motion pose
//   onboarding-<A|B|C|D|E>-<mode>.gif                ~30 fps, for review only (D: 1→2, then 2→3)

private typealias Storyboard = OnboardingWindowController.Storyboard

/// Storyboard frame times (ms) from the tables of design-v2-opus.md §3.6.
private let storyboardTimes: [(id: String, storyboard: Storyboard, times: [Double])] = [
    ("A", .drag, [0, 300, 450, 850, 930, 1200, 1500, 1580, 1660, 1750, 1900, 1940, 1980, 2040, 2160, 2200, 2400, 2600, 2700]),
    ("B", .access, [0, 150, 450, 750, 830, 930, 1030, 1500, 2400, 2600, 2700, 2850, 3000, 3200]),
    ("C", .keys, [0, 300, 600, 650, 700, 750, 800, 860, 900, 1000, 1500, 2400]),
    ("E", .grant, [0, 60, 120, 160, 240, 300, 400, 480, 530, 580, 1800, 1950, 2100]),
]
private let pageTimes: [Double] = [0, 40, 80, 120, 160, 200, 240, 280, 320]

/// Draws `view` with `cacheDisplay`: the window is never shown, so its layer tree is never
/// assembled for `CALayer.render(in:)`; AppKit's cached display draws the views and their layers.
private func renderCached(_ view: NSView, appearance: NSAppearance, scale: CGFloat) -> CGImage? {
    view.appearance = appearance
    view.layoutSubtreeIfNeeded()
    let size = view.bounds.size
    guard size.width > 0, size.height > 0,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size
    appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
    return rep.cgImage
}

/// The onboarding timelines against the motion contract (DESIGN §5.2 rules 1–4, 7, 9 — the checks
/// SelfTest makes for the overlay): loop seams, finite repeats with a tail, one CA keyframe track
/// per track with matching counts, rising key times, opacities within 0…1, rest and explain poses
/// inside the timeline. Then E's flight against the real title, and every storyboard's end against
/// the pages' own state. Exits non-zero on a failure, before anything onboarding is drawn.
private func checkOnboardingTimelines() {
    var failures: [String] = [], checks = 0
    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        checks += 1
        if !ok { failures.append(what()) }
    }
    let drag = DragScene(), keys = KeysScene()
    let ink = CGColor(gray: 0, alpha: 1), red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    var timelines: [(Timeline, looping: Bool)] = [
        (AccessScene.waiting, true), (AccessScene.granted, false),
        (drag.timeline(stageOrigin: CGPoint(x: 40, y: 40), slot: CGPoint(x: 150, y: 290)), false),
        (drag.timeline(stageOrigin: CGPoint(x: 40, y: 40), slot: CGPoint(x: 150, y: 290), replay: true), false),
    ]
    keys.configure(Shortcut(keyCode: 0x7B, mods: NoktaMods([.control, .option]).rawValue), title: "Left Half", done: false)
    if let guide = keys.guideTimeline { timelines.append((guide, true)) }
    timelines.append((keys.arriveTimeline, false))
    for rm in [false, true] {
        let progress = [ProgressSegments.id(1): (from: red, to: ink)]
        timelines.append((OnboardingTimelines.page(forward: true, progress: progress, reds: 1, reduceMotion: rm), false))
        timelines.append((OnboardingTimelines.page(forward: false, progress: progress, reduceMotion: rm), false))
        timelines.append((OnboardingTimelines.grant(from: CGPoint(x: 44, y: 348), to: CGPoint(x: 200, y: 280), titleSize: 22,
                                                    red: red, ink: ink, reduceMotion: rm), false))
    }
    for (t, looping) in timelines {
        let n = t.name
        expect((0...t.duration).contains(t.restT) && (0...t.duration).contains(t.explainT), "\(n): restT / explainT inside")
        for (key, value) in t.base.values where key.keyPath == "opacity" {
            expect((0...1).contains(value.scalarValue ?? -1), "\(n): base \(key.layer).opacity in 0…1")
        }
        for track in t.tracks {
            let id = "\(n) \(track.layer).\(track.keyPath)"
            let k = t.keyframes(for: track)
            expect(k.keyTimes.count == k.values.count && k.eases.count == k.values.count - 1, "\(id): keyframe counts")
            expect(zip(k.keyTimes, k.keyTimes.dropFirst()).allSatisfy { $0 <= $1 } && k.keyTimes.first == 0 && k.keyTimes.last == 1,
                   "\(id): key times rise over 0…1")
            expect(track.keys.allSatisfy { (0...t.duration + 1e-9).contains($0.t) }, "\(id): keys inside the timeline")
            if track.keyPath == "opacity" {
                expect(track.keys.allSatisfy { (0...1).contains($0.value.scalarValue ?? -1) }, "\(id): opacity in 0…1")
            }
        }
        for loops in [1, Theme.Motion.maxLoops] {
            for item in t.animations(begin: 0, loops: loops) {
                expect(item.animation.repeatCount.isFinite && item.animation.repeatCount <= Float(Theme.Motion.maxLoops)
                       && item.animation.isRemovedOnCompletion && item.animation.fillMode != .forwards, "\(n): finite, removed on completion")
            }
        }
        if looping {
            expect(t.pose(at: 0) == t.pose(at: t.duration), "\(n): loop seam pose(0) == pose(duration)")
            let anims = t.animations(begin: 0, loops: Theme.Motion.maxLoops)
            if t.restT > 0 {
                expect(anims.contains { $0.key == "nokta.tail" }, "\(n): a tail to restT after the loops")
            } else {
                // Rest on the seam (Scene C's guide): the loops end on it, no tail is needed or made.
                expect(t.restPose == t.pose(at: t.duration) && !anims.contains { $0.key == "nokta.tail" }, "\(n): rest on the seam, no tail")
            }
        }
    }
    let a = timelines[2].0 // Scene A
    expect(a.pose(at: 0)[OnboardingLayer.wordmarkPeriod, "opacity"] == .scalar(0)
           && a.restPose[OnboardingLayer.wordmarkPeriod, "opacity"] == .scalar(1)
           && a.restPose[OnboardingLayer.flightPeriod, "opacity"] == .scalar(0), "A: the wordmark gets its period only when it lands")
    expect(AccessScene.waiting.restPose == AccessScene.waiting.pose(at: 1500), "B: rest = explain = 1500")

    // E on the real Access page (OV2-10): while level with the title's line the flight dot is right
    // of the text's end, so it never crosses the title's glyphs; title and body show one text at a time.
    typealias GrantID = OnboardingTimelines.GrantID
    let page = AccessPage(frame: CGRect(x: OnboardingMetrics.columnX, y: OnboardingMetrics.pageTop, width: OnboardingMetrics.columnWidth,
                                        height: OnboardingMetrics.pageHeight))
    let e = OnboardingTimelines.grant(from: page.statusDotInSuperview, to: page.slotInSuperview, titleSize: page.titleSize,
                                      red: red, ink: ink, reduceMotion: false)
    let line = page.titleGranted.frame.offsetBy(dx: page.frame.minX, dy: page.frame.minY)
    let textEnd = page.frame.minX + OnboardingText.textEnd(page.titleGranted, role: .title).x
    for t in stride(from: 0.0, through: e.duration, by: 5) {
        let pose = e.pose(at: t)
        func shown(_ id: LayerID) -> Bool { (pose[id, "opacity"]?.scalarValue ?? 0) > 0 }
        if shown(GrantID.flight), case .point(let p)? = pose[GrantID.flight, "position"] {
            let r = 4 * CGFloat(pose[GrantID.flight, "transform.scale"]?.scalarValue ?? 1)
            let level = p.y + r > line.minY && p.y - r < line.maxY
            expect(!level || p.x > textEnd || p.x + r < line.minX, "E t=\(Int(t)): the flight dot crosses the title")
        }
        expect(!(shown(GrantID.title) && shown(GrantID.titleGranted)), "E t=\(Int(t)): two titles over each other")
        expect(!(shown(GrantID.body) && shown(GrantID.bodyGranted)), "E t=\(Int(t)): two bodies over each other")
    }

    // After every storyboard, whatever pose was drawn last, the pages are back at their own state
    // (FV2-2): screen 2, waiting, shows its R4 dot.
    let probe = OnboardingWindowController(app: controller)
    probe.prepareWindow()
    probe.voiceOverOverride = false
    let storyboards: [(String, Storyboard)] = [("A", .drag), ("B", .access), ("C", .keys), ("E", .grant),
                                               ("D 1→2", .page(from: 0, to: 1)), ("D 2→3", .page(from: 1, to: 2))]
    for rm in [false, true] {
        for (id, s) in storyboards {
            let timeline = probe.beginStoryboard(s, reduceMotion: rm)
            for t in [0, timeline.explainT, timeline.duration / 2, timeline.duration] {
                probe.beginStoryboard(s, reduceMotion: rm)
                probe.showStoryboard(at: t)
                probe.endStoryboard()
                probe.showScreen(1)
                let access = probe.accessPage
                expect(access.state == .waiting && access.statusDot.opacity == 1 && !access.status.isHidden
                       && access.status.alphaValue == 1 && access.status.layer?.opacity ?? 1 == 1,
                       "\(id)\(rm ? " (Reduce Motion)" : "") drawn at \(Int(t)) ms: screen 2 then lacks its waiting R4 dot "
                       + "(\(access.state), dot \(access.statusDot.opacity), row hidden \(access.status.isHidden) α \(access.status.alphaValue))")
            }
        }
    }
    probe.window?.close()

    if failures.isEmpty {
        print("onboarding timelines: OK (\(checks) checks)")
    } else {
        print("onboarding timelines: FAIL (\(failures.count) of \(checks) checks)")
        for f in failures.prefix(40) { print("  ✗ " + f) }
        exit(1)
    }
}

/// Every onboarding screen, storyboard, GIF and Reduce Motion pose for one permission state.
func snapshotOnboarding(trusted: Bool) {
    setenv("NOKTA_SNAPSHOT_TRUSTED", trusted ? "1" : "0", 1)
    if !trusted { checkOnboardingTimelines() }
    let onboarding = OnboardingWindowController(app: controller)
    onboarding.prepareWindow()
    onboarding.voiceOverOverride = false // renders never depend on this Mac's VoiceOver
    guard let window = onboarding.window, let content = window.contentView else { return }
    let suffix = trusted ? "-granted" : ""
    var gifs: [String: [CGImage]] = [:]

    for (mode, appearance) in appearances {
        window.appearance = appearance
        onboarding.refreshAppearance()
        func shot(scale: CGFloat = 2) -> CGImage? { renderCached(content, appearance: appearance, scale: scale) }
        func screens(_ tag: String) {
            for index in 0..<3 {
                onboarding.showScreen(index)
                // Screen 1 waits at Scene A's first frame until A has played; draw its rest.
                if index == 0 { onboarding.showStoryboard(at: onboarding.beginStoryboard(.drag).restT) }
                write(shot(), "onboarding-\(index + 1)\(suffix)\(tag)-\(mode)")
                onboarding.endStoryboard()
            }
        }
        screens("")

        var a11y = AccessibilityEnv.Snapshot()
        a11y.increaseContrast = true
        a11y.differentiateWithoutColor = true
        AccessibilityEnv.shared.override = a11y
        onboarding.refreshAppearance()
        screens("-a11y")
        AccessibilityEnv.shared.override = AccessibilityEnv.Snapshot()
        onboarding.refreshAppearance()

        /// Frames at `times`, ~30 fps GIF frames, then the Reduce Motion pose.
        func storyboard(_ id: String, _ s: Storyboard, times: [Double], name: (Double) -> String) -> [CGImage] {
            let timeline = onboarding.beginStoryboard(s)
            for t in times {
                onboarding.showStoryboard(at: t)
                write(shot(), name(t))
            }
            var frames: [CGImage] = []
            let step = 1000.0 / 30
            var t = 0.0
            while t <= timeline.duration + step * 10 {
                onboarding.showStoryboard(at: min(t, timeline.duration))
                if let img = shot(scale: 1) { frames.append(img) }
                t += step
            }
            onboarding.endStoryboard()
            return frames
        }
        func reduced(_ id: String, _ s: Storyboard) {
            let timeline = onboarding.beginStoryboard(s, reduceMotion: true)
            onboarding.showStoryboard(at: timeline.explainT)
            write(shot(), "onboarding-\(id)-rm-\(mode)")
            onboarding.endStoryboard()
        }

        for (id, s, times) in storyboardTimes where (id == "E") == trusted {
            gifs["\(id)-\(mode)"] = storyboard(id, s, times: times) { String(format: "onboarding-%@-t%04d-%@", id, Int($0.rounded()), mode) }
            reduced(id, s)
        }
        if !trusted {
            var frames: [CGImage] = []
            for (from, to) in [(0, 1), (1, 2)] {
                frames += storyboard("D", .page(from: from, to: to), times: pageTimes) {
                    String(format: "onboarding-D-%dto%d-t%04d-%@", from + 1, to + 1, Int($0.rounded()), mode)
                }
            }
            gifs["D-\(mode)"] = frames
            reduced("D", .page(from: 0, to: 1))
        }
    }
    if trusted {
        // The practice on screen 3 (synthetic keys and events; the inert core moved nothing): ⌃⌥
        // held; ⌥⌘← from another set's habit; Left and Right done (Scene C shows ⌃⌥↩); all four
        // done (All set.).
        onboarding.showScreen(2)
        func snap(_ action: NoktaAction, cycle: UInt32 = 0) {
            onboarding.noteSnap(NoktaEvent(kind: .snapped, action: action, zone: nil, source: .keyboard, result: .ok,
                                           displayID: CGMainDisplayID(), cycle: cycle, rect: .zero, latencyNs: 0,
                                           frameDiffers: false, sizeRefused: false, drop: false))
        }
        let states: [(String, () -> Void)] = [
            ("held", { onboarding.testPracticeFlags([.control, .option]) }),
            ("habit", {
                onboarding.testPracticeFlags([])
                onboarding.testPracticePress(Shortcut(keyCode: 0x7B, mods: NoktaMods([.option, .command]).rawValue))
            }),
            ("tried", { snap(.leftHalf); snap(.rightHalf); snap(.rightHalf, cycle: 1) }),
            ("done", { snap(.maximize); snap(.restore) }),
        ]
        for (name, act) in states {
            act()
            for (mode, appearance) in appearances {
                window.appearance = appearance
                onboarding.refreshAppearance()
                write(renderCached(content, appearance: appearance, scale: 2), "onboarding-3-practice-\(name)-\(mode)")
            }
        }
    }
    for (name, frames) in gifs.sorted(by: { $0.key < $1.key }) {
        writeGIF(frames, frameDelay: 1.0 / 30, "onboarding-\(name)")
    }
    window.close()
}
