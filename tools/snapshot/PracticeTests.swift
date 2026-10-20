import AppKit

// nokta-snapshot --practice-test — the Option-Command set and onboarding's practice screen, through
// the shell's real AppController and OnboardingWindowController on the inert core (see
// KeyboardTests.swift for the ground rules). No window is shown. Key presses are fed to the
// practice the way its local key monitor would; snaps arrive as the events the core would send.
//
//   P1 the Option-Command set: Tiles' keys, 20 distinct shortcuts the policy accepts, ⌥⌘D left to
//      the Dock, all registered; Settings and onboarding offer three sets
//   P2 a window manager the user knows (Tiles, Spectacle installed) starts screen 3 on its set — only
//      over untouched defaults, never over VoiceOver's Alternate; the key monitor runs only there
//   P3 the coach: what a key press that reached the window means (and which presses mean nothing)
//   P4 the practice: the step, held keys, a snap ticks it and names the next one, the line goes back
//      to the step after the idle time, Restore with nothing to put back counts, a failure says why,
//      all four → done; VoiceOver hears spelled keys
//   P5 another set's habit: the hint, then the set control switches and the step follows; one of
//      Snapline's own shortcuts reaching the window means Snapline did not get it
//   P6 a shortcut another app holds: the line names it (and a running Tiles); when an app quits,
//      Snapline binds that one again — only that one
//   P7 the stage: held modifiers press their keycaps; the guide keeps its loop seam and poses
//   P8 launch: people who set up before the practice existed see it once, on its own screen

enum PracticeTests {
    static let tiles: (String) -> Bool = { $0 == "com.sempliva.Tiles" }

    static func run() -> Bool {
        let c = Checks("practice-test")
        guard InertCore.available else {
            c.expect(false, "inert core test hooks missing")
            return c.finish()
        }
        SystemShortcuts.override = [s(0x7E, [.control]), s(0x31, [.command])] // Mission Control, Spotlight
        KeyNames.layoutOverride = KeyboardLayout.installed(id: "com.apple.keylayout.US")
        Preferences.systemWritesDisabled = false
        setenv("NOKTA_SNAPSHOT_TRUSTED", "1", 1)
        defer {
            unsetenv("NOKTA_SNAPSHOT_TRUSTED")
            SystemShortcuts.override = nil
        }
        optionCommandSet(c)
        familiarSet(c)
        coach(c)
        practiceFlow(c)
        habitOfAnotherSet(c)
        takenByAnotherApp(c)
        stage(c)
        launch(c)
        return c.finish()
    }

    static func s(_ key: UInt32, _ mods: NoktaMods) -> Shortcut { Shortcut(keyCode: key, mods: mods.rawValue) }

    /// Screen 3 of a fresh onboarding on `f`'s app, as `show()` would leave it.
    static func practice(_ f: Fixture, installed: @escaping (String) -> Bool = { _ in false }, voiceOver: Bool = false) -> OnboardingWindowController {
        let o = f.app.testAttachOnboarding()
        o.voiceOverOverride = voiceOver
        o.installedOverride = installed
        o.showScreen(2)
        o.testAppear()
        return o
    }

    static func event(_ kind: NoktaEvent.Kind, _ action: NoktaAction, source: NoktaEvent.Source = .keyboard,
                      result: NoktaResult = .ok) -> NoktaEvent {
        NoktaEvent(kind: kind, action: action, zone: nil, source: source, result: result, displayID: CGMainDisplayID(), cycle: 0,
                   rect: .zero, latencyNs: 0, frameDiffers: false, sizeRefused: false, drop: false)
    }

    static func close(_ f: Fixture, _ o: OnboardingWindowController) {
        o.window?.close()
        f.close()
    }

    static func segmented(_ title: String, in view: NSView) -> NSSegmentedControl? {
        if let s = view as? NSSegmentedControl, s.accessibilityLabel() == title { return s }
        for sub in view.subviews { if let s = segmented(title, in: sub) { return s } }
        return nil
    }

    static func choose(_ control: NSSegmentedControl, _ index: Int) {
        control.selectedSegment = index
        _ = control.sendAction(control.action, to: control.target)
    }

    // MARK: P1

    static func optionCommandSet(_ c: Checks) {
        let oc: NoktaMods = [.option, .command]
        let table = NoktaAction.allCases.map { Preferences.preset(.optionCommand, for: $0) }
        let all = table.compactMap { $0 }
        c.expect(all.count == 20 && all.allSatisfy { a in all.filter { $0 == a }.count == 1 }, "P1 20 distinct shortcuts")
        let tiles: [(NoktaAction, Shortcut)] = [
            (.leftHalf, s(0x7B, oc)), (.rightHalf, s(0x7C, oc)), (.topHalf, s(0x7E, oc)), (.bottomHalf, s(0x7D, oc)),
            (.topLeft, s(0x20, oc)), (.topRight, s(0x22, oc)), (.bottomLeft, s(0x26, oc)), (.bottomRight, s(0x28, oc)),
            (.maximize, s(0x03, oc)), (.center, s(0x08, oc)), (.restore, s(0x10, oc)),
            (.firstTwoThirds, s(0x7B, [.control, .command])), (.centerTwoThirds, s(0x7E, [.control, .command])),
            (.lastTwoThirds, s(0x7C, [.control, .command])),
            (.nextDisplay, s(0x7C, [.control, .option, .command])), (.prevDisplay, s(0x7B, [.control, .option, .command])),
        ]
        for (action, expected) in tiles {
            let got = Preferences.preset(.optionCommand, for: action)
            c.expect(got == expected, "P1 \(action.title) is \(expected.displayString) (got \(got?.displayString ?? "none"))")
        }
        let dock = s(0x02, oc)
        c.expect(!all.contains(dock), "P1 ⌥⌘D stays the Dock's")
        let reserved = SystemShortcuts.fixed + [dock]
        for (action, shortcut) in zip(NoktaAction.allCases, all) {
            c.expect(ShortcutPolicy.problem(with: shortcut, reserved: reserved) == nil, "P1 \(action.title) \(shortcut.displayString) passes the policy")
        }
        for set in Preferences.ShortcutSet.allCases {
            let prefs = Preferences(defaults: ScratchDefaults(suiteName: "pt.set-\(set.rawValue)")!)
            prefs.applyShortcutSet(set)
            c.expect(prefs.currentShortcutSet == set, "P1 the \(set.title) set is recognised")
        }

        let f = Fixture("pt.sets")
        let before = f.counters
        f.app.prefs.applyShortcutSet(.optionCommand)
        settle() // Settings refreshes on the next turn of the run loop
        let d = f.counters - before
        c.expect(f.app.prefs.currentShortcutSet == .optionCommand && f.counters.live == 20 && d.refused == 0,
                 "P1 applied: 20 live, none refused (live \(f.counters.live), refused \(d.refused))")
        guard let control = segmented("Shortcut set", in: f.pane.view) else {
            c.expect(false, "P1 Settings has a shortcut set control")
            f.close()
            return
        }
        let labels = (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
        c.expect(labels == ["⌃⌥", "⌥⌘", "⌃⇧⌘"] && control.selectedSegment == 1, "P1 Settings: three sets by their keys, ⌥⌘ selected (\(labels))")
        c.expect(control.toolTip(forSegment: 1) == "Option-Command + key, as in Spectacle and Tiles", "P1 the name is in the tooltip")
        choose(control, 0)
        c.expect(f.app.prefs.currentShortcutSet == .classic && f.counters.live == 20, "P1 Settings switches back to Classic")
        let o = practice(f)
        let onboarding = o.tryScreen.setControl
        c.expect(onboarding.segmentCount == 3 && onboarding.selectedSegment == 0, "P1 onboarding offers the three sets")
        choose(onboarding, 1)
        c.expect(f.app.prefs.currentShortcutSet == .optionCommand, "P1 onboarding switches to Option-Command")
        c.expect(o.tryScreen.setControl.frame.maxX <= OnboardingMetrics.columnWidth, "P1 the set control fits the column")
        close(f, o)
    }

    // MARK: P2

    static func familiarSet(_ c: Checks) {
        let found = Preferences.familiarApp(installed: tiles)
        c.expect(found?.name == "Tiles" && found?.set == .optionCommand, "P2 Tiles → Option-Command")
        c.expect(Preferences.familiarApp(installed: { $0 == "com.divisiblebyzero.Spectacle" })?.name == "Spectacle", "P2 Spectacle → Option-Command")
        c.expect(Preferences.familiarApp(installed: { _ in false }) == nil, "P2 none installed → nothing")
        let fresh = Preferences(defaults: ScratchDefaults(suiteName: "pt.familiar")!)
        c.expect(OnboardingWindowController.familiarSet(voiceOver: false, prefs: fresh, installed: tiles)?.set == .optionCommand, "P2 untouched defaults → Option-Command")
        c.expect(OnboardingWindowController.familiarSet(voiceOver: true, prefs: fresh, installed: tiles) == nil, "P2 VoiceOver → no change here")
        fresh.applyShortcutSet(.classic)
        c.expect(OnboardingWindowController.familiarSet(voiceOver: false, prefs: fresh, installed: tiles) == nil, "P2 a Classic set the user chose is kept")

        let f = Fixture("pt.familiar-window")
        let o = practice(f, installed: tiles)
        c.expect(f.app.prefs.currentShortcutSet == .optionCommand && f.counters.live == 20, "P2 Tiles installed: screen 3 starts on Option-Command, registered")
        c.expect(o.practiceLine == "Option-Command keys, as in Tiles. Press Option Command Left Arrow to move this window left.",
                 "P2 the line says why and gives the first step (\(o.practiceLine))")
        c.expect(o.tryScreen.setControl.selectedSegment == 1, "P2 the set control shows it")
        c.expect(o.practiceMonitorInstalled, "P2 the key monitor runs while screen 3 is up")
        o.showScreen(1)
        c.expect(!o.practiceMonitorInstalled, "P2 …and stops when it is not")
        close(f, o)

        let g = Fixture("pt.familiar-voiceover")
        let v = practice(g, installed: tiles, voiceOver: true)
        c.expect(g.app.prefs.currentShortcutSet == .alternate, "P2 with VoiceOver, Alternate wins over the familiar set")
        close(g, v)
    }

    // MARK: P3

    static func coach(_ c: Checks) {
        let prefs = Preferences(defaults: ScratchDefaults(suiteName: "pt.coach")!)
        func context(_ target: NoktaAction? = .leftHalf, voiceOver: Bool = false, taken: NoktaAction? = nil, running: [String] = []) -> PracticeCoach.Context {
            PracticeCoach.Context(shortcut: { prefs.shortcut(for: $0) }, target: target, voiceOverPaused: voiceOver,
                                  result: { $0 == taken ? .hotkey : .ok }, runningManagers: running)
        }
        func verdict(_ pressed: Shortcut, _ ctx: PracticeCoach.Context = context()) -> String {
            PracticeCoach.evaluate(pressed, ctx).map(kind) ?? "nothing"
        }
        let co: NoktaMods = [.control, .option]
        c.expect(verdict(s(0x7B, [.option, .command])) == "otherSet optionCommand leftHalf", "P3 ⌥⌘← → Left Half of Option-Command")
        c.expect(verdict(s(0x7B, [.control, .shift, .command])) == "otherSet alternate leftHalf", "P3 ⌃⇧⌘← → Left Half of Alternate")
        c.expect(verdict(s(0x08, [.option, .command])) == "otherSet optionCommand center", "P3 ⌥⌘C → Center of Option-Command")
        c.expect(verdict(s(0x0D, [.command])) == "nothing" && verdict(s(0x21, [.shift, .command])) == "nothing", "P3 ⌘W, ⇧⌘[ are app commands")
        c.expect(verdict(s(0x00, [])) == "nothing" && verdict(s(0x30, [])) == "nothing" && verdict(s(0x24, [])) == "nothing", "P3 typing, Tab, Return mean nothing")
        c.expect(verdict(s(0x7B, [])) == "needsModifiers leftHalf", "P3 ← alone while ⌃⌥← is the step → hold the modifiers")
        c.expect(verdict(s(0x7B, []), context(.rightHalf)) == "nothing", "P3 ← alone while → is the step → nothing")
        c.expect(verdict(s(0x28, [.control])) == "notSnapline", "P3 ⌃K → no Snapline shortcut")
        c.expect(verdict(s(0x7B, co)) == "notReceived", "P3 ⌃⌥← reaching the window → Snapline did not get it")
        c.expect(verdict(s(0x7B, co), context(voiceOver: true)) == "voiceOverPaused", "P3 …while VoiceOver pauses ⌃⌥ → that")
        c.expect(verdict(s(0x7B, co), context(taken: .leftHalf, running: ["Tiles"])) == "taken leftHalf Tiles", "P3 …taken by a running Tiles → that")
        c.expect(kind(PracticeCoach.idle(trusted: false, target: .leftHalf, context())) == "locked", "P3 idle without access → locked")
        c.expect(kind(PracticeCoach.idle(trusted: true, target: nil, context())) == "done", "P3 idle, all done → done")
        c.expect(kind(PracticeCoach.idle(trusted: true, target: .leftHalf, context(taken: .leftHalf))) == "taken leftHalf -", "P3 idle, step taken → taken")
        c.expect(kind(PracticeCoach.idle(trusted: true, target: .leftHalf, context(running: ["Rectangle"]))) == "otherManager Rectangle", "P3 idle, Rectangle runs → quit it")
        c.expect(kind(PracticeCoach.idle(trusted: true, target: .leftHalf, context())) == "next leftHalf", "P3 idle → the step")
    }

    /// A status in words, for comparisons.
    static func kind(_ status: PracticeStatus) -> String {
        switch status {
        case .locked: return "locked"
        case .next(let a): return "next \(a)"
        case .holding: return "holding"
        case .worked(let a, _, _): return "worked \(a)"
        case .nothingToRestore: return "nothingToRestore"
        case .failed(let a, _): return "failed \(a)"
        case .needsModifiers(let a): return "needsModifiers \(a)"
        case let .otherSet(_, a, set): return "otherSet \(set.rawValue) \(a)"
        case .notSnapline: return "notSnapline"
        case .notReceived: return "notReceived"
        case .voiceOverPaused: return "voiceOverPaused"
        case let .taken(a, by): return "taken \(a) \(by ?? "-")"
        case .otherManager(let name): return "otherManager \(name)"
        case .familiar: return "familiar"
        case .done: return "done"
        }
    }

    // MARK: P4

    static func practiceFlow(_ c: Checks) {
        let f = Fixture("pt.flow")
        let o = practice(f)
        let chips = o.tryScreen.chips
        c.expect(o.practiceLine == "Press Control Option Left Arrow to move this window left.", "P4 the first step (\(o.practiceLine))")
        c.expect(chips[0].isTarget && chips[0].accessibilityValue() as? String == "next" && !chips[1].isTarget, "P4 its chip is outlined, spoken \"next\"")
        c.expect(o.tryScreen.line.accessibilityLabel() == o.practiceLine, "P4 VoiceOver reads the line with spelled keys")
        c.expect(!o.practiceIsPaused, "P4 nothing pressed: the guide may play")

        o.testPracticeFlags([.control])
        c.expect(o.practiceLine == "Control held. Add Option." && o.practiceIsPaused, "P4 ⌃ down: the line asks for ⌥, the guide waits (\(o.practiceLine))")
        o.testPracticeFlags([.control, .option])
        c.expect(o.practiceLine == "Control Option held. Now press Left Arrow.", "P4 ⌃⌥ down: now the key (\(o.practiceLine))")
        o.testPracticeFlags([.option, .command])
        c.expect(o.practiceLine == "Option Command held. This set uses Control Option.", "P4 ⌥⌘ down: this set uses ⌃⌥ (\(o.practiceLine))")
        o.testPracticeFlags([.control, .option])

        o.noteSnap(event(.snapped, .leftHalf))
        c.expect(chips[0].tried && !chips[0].isTarget && chips[1].isTarget && o.practiceTarget == .rightHalf, "P4 a snap ticks the step, the next one is outlined")
        c.expect(o.practiceLine == "✓ Control Option Left Arrow. Next, press Control Option Right Arrow to move it right.",
                 "P4 the line names the next step (\(o.practiceLine))")
        o.testPracticeFlags([])
        c.expect(o.practiceLine.hasPrefix("✓ Control Option Left Arrow."), "P4 letting go keeps the outcome on the line")
        o.testPracticeIdle()
        c.expect(!o.practiceIsPaused && o.practiceLine == "Press Control Option Right Arrow to move it right.", "P4 after the idle time: the step again, the guide plays")

        o.noteSnap(event(.snapped, .rightHalf, source: .drag))
        c.expect(o.practiceLine == "✓ Right Half. Next, press Control Option Return to fill the screen.", "P4 a drag counts, without claiming keys (\(o.practiceLine))")
        o.noteSnap(event(.failed, .restore, result: .invalid))
        c.expect(chips[3].tried && o.practiceLine == "✓ Control Option Delete works. There was nothing to put back yet.",
                 "P4 Restore with nothing to put back reached Snapline: it counts (\(o.practiceLine))")
        o.noteSnap(event(.failed, .maximize, result: .notMovable))
        c.expect(!chips[2].tried && o.practiceLine == "Control Option Return reached Snapline, but: This window cannot be moved.",
                 "P4 a failure says why and does not tick (\(o.practiceLine))")
        o.noteSnap(event(.failed, .maximize, source: .drag, result: .notMovable))
        c.expect(o.practiceLine.hasPrefix("Control Option Return reached"), "P4 a failed drag is not a practice step")
        o.noteSnap(event(.snapped, .maximize))
        c.expect(o.practiceTarget == nil && chips.allSatisfy(\.tried) && !chips.contains(where: \.isTarget), "P4 all four tried")
        c.expect(o.practiceLine == "All four work. Snapline stays in the menu bar.", "P4 done (\(o.practiceLine))")
        o.testPracticeIdle()
        c.expect(o.practiceLine == "All four work. Snapline stays in the menu bar.", "P4 done stays after the idle time")

        // Leaving screen 3 drops the held keys and the paused state; access missing → locked.
        o.testPracticeFlags([.control])
        o.showScreen(1)
        c.expect(!o.practiceIsPaused && o.heldModifiers.isEmpty, "P4 leaving screen 3 lets go of the practice")
        close(f, o)

        setenv("NOKTA_SNAPSHOT_TRUSTED", "0", 1)
        let g = Fixture("pt.flow-locked")
        let l = practice(g)
        c.expect(kind(l.practiceStatus) == "locked" && !l.tryScreen.chips.contains(where: \.isTarget), "P4 no access: locked, no step outlined")
        l.testPracticeFlags([.control, .option])
        c.expect(!l.practiceIsPaused && kind(l.practiceStatus) == "locked", "P4 no access: keys change nothing")
        close(g, l)
        setenv("NOKTA_SNAPSHOT_TRUSTED", "1", 1)
    }

    // MARK: P5

    static func habitOfAnotherSet(_ c: Checks) {
        let f = Fixture("pt.habit")
        let o = practice(f)
        let oc: NoktaMods = [.option, .command]
        o.testPracticePress(s(0x7B, oc))
        c.expect(o.practiceLine == "Option Command Left Arrow is Left Half in Option-Command. Choose it below." && o.practiceIsPaused,
                 "P5 ⌥⌘←: the hint names the set (\(o.practiceLine))")
        choose(o.tryScreen.setControl, 1)
        c.expect(f.app.prefs.currentShortcutSet == .optionCommand && f.counters.live == 20, "P5 one click: Option-Command, registered")
        c.expect(o.practiceLine == "Press Option Command Left Arrow to move this window left." && o.tryScreen.chips[0].shortcut == s(0x7B, oc),
                 "P5 the step and the chips follow the set (\(o.practiceLine))")
        o.testPracticePress(s(0x7B, oc))
        c.expect(o.practiceLine == "Option Command Left Arrow reached this window, not Snapline: another app has it.",
                 "P5 an own shortcut reaching the window: Snapline did not get it (\(o.practiceLine))")
        let line = o.practiceLine
        for pressed in [s(0x0D, [.command]), s(0x30, []), s(0x31, []), s(0x24, [])] { o.testPracticePress(pressed) }
        c.expect(o.practiceLine == line, "P5 ⌘W, Tab, Space and Return leave the line alone")
        close(f, o)
    }

    // MARK: P6

    static func takenByAnotherApp(_ c: Checks) {
        let left = NoktaAction.leftHalf.defaultShortcut!
        InertCore.setTaken(left, true)
        defer { InertCore.setTaken(left, false) }
        let f = Fixture("pt.taken")
        c.expect(f.app.hotkeyResults[.leftHalf] == .hotkey && f.counters.live == 19, "P6 setup: another app holds ⌃⌥←")
        let o = practice(f)
        c.expect(o.practiceLine == "Control Option Left Arrow belongs to another app. Quit it, or choose another set.", "P6 the line says so (\(o.practiceLine))")
        o.runningOverride = ["Tiles"]
        c.expect(o.practiceLine == "Control Option Left Arrow belongs to Tiles. Quit it, or choose another set.", "P6 …and names a running Tiles (\(o.practiceLine))")

        // Tiles quits: its keys are free, Snapline binds the one that failed — only that one.
        InertCore.setTaken(left, false)
        o.runningOverride = []
        let before = f.counters
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: NSWorkspace.shared)
        settle()
        let d = f.counters - before
        c.expect(f.app.hotkeyResults[.leftHalf] == .ok && f.counters.live == 20 && d.registered == 1 && d.unregistered == 0,
                 "P6 an app quit: ⌃⌥← is bound again, nothing else (registered \(d.registered), unregistered \(d.unregistered))")
        c.expect(o.practiceLine == "Press Control Option Left Arrow to move this window left.", "P6 the line is the step again (\(o.practiceLine))")
        let after = f.counters
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: NSWorkspace.shared)
        settle()
        c.expect(f.counters == after, "P6 with nothing taken, an app quitting changes nothing")
        o.runningOverride = ["Rectangle"]
        c.expect(o.practiceLine == "Rectangle is running and answers keys too. Quit Rectangle to practise.", "P6 another window manager running: quit it first")
        close(f, o)
    }

    // MARK: P7

    static func stage(_ c: Checks) {
        let k = KeysScene()
        let down = PoseValue.scalar(2), up = PoseValue.scalar(0)
        let ctrl = k.heldPose([.control])
        c.expect(ctrl["c.cap0", "transform.translation.y"] == down && ctrl["c.wash0", "opacity"] == .scalar(1)
                 && ctrl["c.cap1", "transform.translation.y"] == up && ctrl["c.cap2", "transform.translation.y"] == up,
                 "P7 ⌃ held: the ⌃ keycap is down, ⌥ and the arrow are up")
        let habit = k.heldPose([.option, .command])
        c.expect(habit["c.cap0", "transform.translation.y"] == up && habit["c.cap1", "transform.translation.y"] == down,
                 "P7 ⌥⌘ held on a ⌃⌥ set: only ⌥ shows down")
        k.configure(modifiers: [.option, .command], actionKeys: ["←", "→", "F", "Y"])
        let both = k.heldPose([.option, .command])
        c.expect(both["c.cap0", "transform.translation.y"] == down && both["c.cap1", "transform.translation.y"] == down, "P7 ⌥⌘ set: both caps down")
        for action in KeysScene.actions {
            guard let t = k.guideTimeline(action) else { c.expect(false, "P7 \(action.title) has a guide"); continue }
            c.expect(t.pose(at: 0) == t.pose(at: t.duration), "P7 \(action.title) guide: loop seam")
            c.expect(t.pose(at: t.restT)["c.cap0", "transform.translation.y"] == up && t.pose(at: t.explainT)["c.cap0", "transform.translation.y"] == down,
                     "P7 \(action.title) guide: keys up at rest, down in the explain pose")
        }
        c.expect(k.guideTimeline(.center) == nil, "P7 no guide for an action the scene does not show")
    }

    // MARK: P8

    static func launch(_ c: Checks) {
        let prefs = Preferences(defaults: ScratchDefaults(suiteName: "pt.launch")!)
        prefs.onboardingDone = true
        prefs.onboardingSeen = true
        c.expect(AppController.showsOnboardingAtLaunch(trusted: true, prefs: prefs), "P8 set up before the practice existed → shown once")
        prefs.practiceSeen = true
        c.expect(!AppController.showsOnboardingAtLaunch(trusted: true, prefs: prefs), "P8 practised → not again")

        let f = Fixture("pt.launch-window") { $0.onboardingDone = true; $0.onboardingSeen = true }
        let first = OnboardingWindowController(app: f.app)
        c.expect(first.startPage(wantsPermission: false) == 2, "P8 it opens straight on the practice")
        first.prepareWindow()
        first.showScreen(0)
        first.window?.cancelOperation(nil) // Later on Welcome
        settle()
        c.expect(!f.app.prefs.practiceSeen, "P8 closed before the practice: it comes back")
        let second = OnboardingWindowController(app: f.app)
        second.prepareWindow()
        second.showScreen(2)
        second.window?.cancelOperation(nil)
        settle()
        c.expect(f.app.prefs.practiceSeen && OnboardingWindowController(app: f.app).startPage(wantsPermission: false) == 0,
                 "P8 closed on the practice: seen; a later Finish Setup starts on Welcome")
        f.app.prefs.resetAllSettings(domain: "pt")
        c.expect(f.app.prefs.practiceSeen, "P8 Reset All keeps it")
        c.expect(f.button("Practice…") != nil, "P8 Settings › Shortcuts offers Practice…")
        withExtendedLifetime([first, second]) {}
        f.close()
    }
}
