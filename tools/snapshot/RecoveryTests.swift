import AppKit

// nokta-snapshot --recovery-test — first use, permission recovery and re-binding, through the
// shell's real AppController on the inert core (see KeyboardTests.swift for the ground rules).
// Accessibility trust is the inert core's NOKTA_SNAPSHOT_TRUSTED (set and unset here); no real
// permission, login item or System Settings pane is read, changed or opened: the offscreen build
// records what a live app WOULD have requested (Preferences.loginItemRequests,
// AppController.systemRequests), so a guard that blocks is told apart from a path never taken.
//
//   R1 launch arguments fail closed (a malformed preview is still a preview, never a live launch)
//   R2 preview / bench modes never request a login item, the Accessibility prompt or a System
//      Settings pane — not even from onboarding's Done; a normal launch would (the seams see it)
//   R3 revoke → the core stops and every shortcut is unregistered; re-grant → each is registered
//      exactly once; repeated health checks change nothing
//   R4 wake, session switch and display changes do not re-register (no duplicates, none lost)
//   R5 Pause / Resume unbind and re-bind once
//   R6 onboarding opens by itself on first launch and when access is missing, not again for a
//      returning user who closed it; denied access leaves a usable app with one clear next step

enum RecoveryTests {
    static func run() -> Bool {
        let c = Checks("recovery-test")
        guard InertCore.available else {
            c.expect(false, "inert core test hooks missing")
            return c.finish()
        }
        KeyNames.layoutOverride = KeyboardLayout.installed(id: "com.apple.keylayout.US")
        launchArguments(c)
        previewWritesNothing(c)
        revokeAndRegrant(c)
        systemEvents(c)
        pauseResume(c)
        onboardingAtLaunch(c)
        unsetenv("NOKTA_SNAPSHOT_TRUSTED")
        return c.finish()
    }

    // MARK: R1

    static func launchArguments(_ c: Checks) {
        let cases: [([String], BenchMode)] = [
            (["Nokta"], .none),
            (["Nokta", "--bench-preview"], .preview("")),
            (["Nokta", "--bench-preview", "--close-after", "3"], .preview("")),
            (["Nokta", "--bench-preview", "settings-shortcuts"], .preview("settings-shortcuts")),
            (["Nokta", "--bench-idle", "--bench-preview", "settings-general"], .idle),
            (["Nokta", "--bench-session"], .session),
            (["Nokta", "-NSDocumentRevisionsDebugMode", "YES"], .none),
        ]
        for (args, expected) in cases {
            let mode = BenchMode.parse(args)
            c.expect(mode == expected, "R1 \(args.dropFirst().joined(separator: " ")) → \(expected) (got \(mode))")
        }
        c.expect(BenchMode.preview("").showsWindows && BenchMode.session.showsWindows && !BenchMode.idle.showsWindows, "R1 only preview and session may show windows")
    }

    // MARK: R2

    static func previewWritesNothing(_ c: Checks) {
        Preferences.loginItemRequests = []
        AppController.systemRequests = []
        setenv("NOKTA_SNAPSHOT_TRUSTED", "0", 1)
        let given = ScratchDefaults(suiteName: "rt.preview")!
        let preview = AppController(defaults: given, bench: .preview("onboarding-2-waiting"))
        c.expect(Preferences.systemWritesDisabled, "R2 a preview disables system writes")
        c.expect(preview.prefs.defaults !== given, "R2 a preview never uses the user's preferences")
        preview.prefs.launchAtLogin = true
        preview.requestAccessibilityPrompt()
        preview.openAccessibilitySettings()
        preview.openLoginItemsSettings()
        preview.openDesktopDockSettings()
        // Onboarding's Done on a first setup would turn the login item on (switch on by default).
        let onboarding = OnboardingWindowController(app: preview)
        onboarding.prepareWindow()
        onboarding.showScreen(1)
        onboarding.perform(Selector(("primary:")), with: nil) // "Open System Settings" while waiting
        onboarding.showScreen(2)
        onboarding.perform(Selector(("primary:")), with: nil) // Done
        settle()
        c.expect(Preferences.loginItemRequests.isEmpty, "R2 preview: no login item request (\(Preferences.loginItemRequests))")
        c.expect(AppController.systemRequests.isEmpty, "R2 preview: no prompt and no System Settings pane (\(AppController.systemRequests))")
        setenv("NOKTA_SNAPSHOT_TRUSTED", "1", 1)
        preview.startEngine(bindShortcuts: true) // a preview's launch path
        preview.suspendShortcuts(true)
        preview.suspendShortcuts(false)          // a recorder ending in a previewed Settings
        c.expect(preview.engine.stats().hotkeys_bound == 0 && InertCore.counters(preview.engine).binds == 0, "R2 preview binds no shortcut")
        preview.engine.stop()
        setenv("NOKTA_SNAPSHOT_TRUSTED", "0", 1)

        // The same clicks in a normal launch reach the (recording) seams: the guard is what blocked them.
        Preferences.systemWritesDisabled = false
        let normal = AppController(defaults: ScratchDefaults(suiteName: "rt.normal")!, bench: .none)
        let normalOnboarding = OnboardingWindowController(app: normal)
        normalOnboarding.prepareWindow()
        normalOnboarding.showScreen(1)
        normalOnboarding.perform(Selector(("primary:")), with: nil)
        normalOnboarding.showScreen(2)
        normalOnboarding.perform(Selector(("primary:")), with: nil)
        settle()
        c.expect(AppController.systemRequests == ["accessibility-prompt", "accessibility-settings"], "R2 normal: prompt once, then the pane (\(AppController.systemRequests))")
        c.expect(Preferences.loginItemRequests == [true], "R2 normal first setup: Done asks for the login item once (\(Preferences.loginItemRequests))")
        c.expect(normal.prefs.onboardingDone && normal.prefs.onboardingSeen, "R2 Done marks onboarding done and seen")
        Preferences.loginItemRequests = []
        AppController.systemRequests = []
    }

    // MARK: R3

    static func revokeAndRegrant(_ c: Checks) {
        Preferences.systemWritesDisabled = false
        setenv("NOKTA_SNAPSHOT_TRUSTED", "1", 1)
        let app = AppController(defaults: ScratchDefaults(suiteName: "rt.permission")!, bench: .none)
        app.observeSystem()
        app.startEngine(bindShortcuts: true)
        var k = InertCore.counters(app.engine)
        c.expect(k.live == 20 && app.isRunning, "R3 trusted launch: core running, 20 shortcuts")

        setenv("NOKTA_SNAPSHOT_TRUSTED", "0", 1) // revoked in System Settings
        app.checkHealth()
        k = InertCore.counters(app.engine)
        c.expect(!app.engine.stats().started && app.engineResult == .notTrusted, "R3 revoke stops the core")
        c.expect(k.live == 0 && k.unregistered == 20, "R3 revoke unregisters every shortcut once (live \(k.live), −\(k.unregistered))")
        let menu = StatusMenuController(app: app, installStatusItem: false)
        menu.rebuild()
        let enabled = menu.menu.items.filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title)
        c.expect(menu.menu.items.first?.title == "Allow Accessibility…", "R3 the menu leads with Allow Accessibility…")
        c.expect(enabled.contains("Settings…") && enabled.contains("Quit Snapline") && !enabled.contains("Left Half"),
                 "R3 without access the app stays usable (Settings, Quit) and snap items are off (\(enabled))")
        c.expect(menu.state == .needsPermission, "R3 the icon shows the missing permission")
        app.checkHealth()
        app.checkHealth()
        c.expect(InertCore.counters(app.engine) == k, "R3 repeated checks while revoked change nothing")

        setenv("NOKTA_SNAPSHOT_TRUSTED", "1", 1) // granted again
        app.checkHealth()
        let after = InertCore.counters(app.engine)
        c.expect(app.isRunning && after.live == 20, "R3 re-grant restarts the core (live \(after.live))")
        c.expect(after.registered - k.registered == 20 && after.unregistered == k.unregistered, "R3 re-grant registers each shortcut exactly once (+\(after.registered - k.registered))")
        app.checkHealth()
        app.checkHealth()
        c.expect(InertCore.counters(app.engine) == after, "R3 repeated checks while trusted change nothing")
        app.engine.stop()
    }

    // MARK: R4

    static func systemEvents(_ c: Checks) {
        setenv("NOKTA_SNAPSHOT_TRUSTED", "1", 1)
        let app = AppController(defaults: ScratchDefaults(suiteName: "rt.events")!, bench: .none)
        app.observeSystem()
        app.startEngine(bindShortcuts: true)
        let before = InertCore.counters(app.engine)
        let ws = NSWorkspace.shared.notificationCenter
        for _ in 0..<3 {
            ws.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
            ws.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: NSWorkspace.shared)
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        }
        settle()
        let after = InertCore.counters(app.engine)
        c.expect(after.registered == before.registered && after.unregistered == before.unregistered,
                 "R4 wake / session / display changes do not re-register (+\(after.registered - before.registered) −\(after.unregistered - before.unregistered))")
        c.expect(after.live == 20 && app.isRunning, "R4 nothing lost (live \(after.live))")
        // A core that stopped meanwhile (e.g. permission flicker at wake) is restarted once.
        app.engine.stop()
        ws.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        settle()
        let restarted = InertCore.counters(app.engine)
        c.expect(restarted.live == 20 && restarted.registered - after.registered == 20, "R4 wake restarts a stopped core once (+\(restarted.registered - after.registered))")
        app.engine.stop()
    }

    // MARK: R5

    static func pauseResume(_ c: Checks) {
        setenv("NOKTA_SNAPSHOT_TRUSTED", "1", 1)
        let app = AppController(defaults: ScratchDefaults(suiteName: "rt.pause")!, bench: .none)
        app.startEngine(bindShortcuts: true)
        let start = InertCore.counters(app.engine)
        app.setPaused(true)
        c.expect(InertCore.counters(app.engine).live == 0, "R5 Pause releases every shortcut")
        app.checkHealth()
        c.expect(InertCore.counters(app.engine).live == 0, "R5 a health check while paused does not re-bind")
        app.setPaused(false)
        let k = InertCore.counters(app.engine) - start
        c.expect(k.registered == 20 && k.unregistered == 20 && InertCore.counters(app.engine).live == 20, "R5 Resume binds each shortcut once")
        app.engine.stop()
    }

    // MARK: R6

    static func onboardingAtLaunch(_ c: Checks) {
        let prefs = Preferences(defaults: ScratchDefaults(suiteName: "rt.onboarding")!)
        c.expect(AppController.showsOnboardingAtLaunch(trusted: true, prefs: prefs), "R6 first launch shows onboarding")
        c.expect(AppController.showsOnboardingAtLaunch(trusted: false, prefs: prefs), "R6 first launch without access shows onboarding")
        prefs.onboardingSeen = true // closed with Later / Esc / ⌘W
        c.expect(AppController.showsOnboardingAtLaunch(trusted: true, prefs: prefs), "R6 closed before practising: once more, on the practice")
        prefs.practiceSeen = true
        c.expect(!AppController.showsOnboardingAtLaunch(trusted: true, prefs: prefs), "R6 a returning user with access is not shown onboarding again")
        c.expect(AppController.showsOnboardingAtLaunch(trusted: false, prefs: prefs), "R6 a returning user without access gets the permission screen")
        prefs.onboardingDone = true
        c.expect(!AppController.showsOnboardingAtLaunch(trusted: true, prefs: prefs), "R6 done + access: no onboarding")

        // A returning user lands on the permission screen, not on Welcome; Esc (Later) marks it seen.
        setenv("NOKTA_SNAPSHOT_TRUSTED", "0", 1)
        Preferences.systemWritesDisabled = false
        let app = AppController(defaults: ScratchDefaults(suiteName: "rt.onboarding-window")!, bench: .none)
        c.expect(!app.prefs.onboardingSeen, "R6 setup: not seen yet")
        let onboarding = OnboardingWindowController(app: app)
        onboarding.prepareWindow()
        onboarding.window?.cancelOperation(nil) // Esc = Later
        settle()
        c.expect(app.prefs.onboardingSeen && !app.prefs.onboardingDone, "R6 Esc (Later) marks setup seen, not done")
        let reopened = OnboardingWindowController(app: app)
        let page = reopened.startPage(wantsPermission: false)
        c.expect(page == 1, "R6 reopened without access → permission screen (page \(page + 1))")
        let firstApp = AppController(defaults: ScratchDefaults(suiteName: "rt.first")!, bench: .none)
        let first = OnboardingWindowController(app: firstApp)
        c.expect(first.startPage(wantsPermission: false) == 0, "R6 the very first time → Welcome")
        withExtendedLifetime(firstApp) {}
        // Resetting all settings keeps onboarding progress.
        app.prefs.onboardingDone = true
        app.prefs.resetAllSettings(domain: "rt")
        app.prefs.practiceSeen = true
        app.prefs.resetAllSettings(domain: "rt")
        c.expect(app.prefs.onboardingDone && app.prefs.onboardingSeen && app.prefs.practiceSeen, "R6 Reset All keeps onboarding done, seen and practised")
    }
}
