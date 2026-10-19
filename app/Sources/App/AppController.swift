import AppKit

extension Notification.Name {
    /// Posted (object: AppController) after the app-wide permission watcher ran `checkHealth()`.
    /// Onboarding refreshes its permission screen from it, so only one component listens to the
    /// system's Accessibility broadcast.
    static let noktaPermissionChecked = Notification.Name("NoktaPermissionChecked")
}

/// Launch modes used by the benchmark harness (`scripts/bench.sh`). In every mode Nokta
/// registers NO global shortcuts, creates no event tap or AX observer (drag snapping off) and
/// never moves a window; the status item is built but forced to Paused, and its menu keeps only
/// Quit enabled. The engine entry points (`perform`, `setPaused`, `startEngine`,
/// shortcut binding) refuse to act in a bench mode whatever calls them.
enum BenchMode: Equatable {
    case none
    /// Print `NOKTA_READY <mach_absolute_time>` once launched and the core started, then quit.
    case startup
    /// Run headless (core started, no shortcuts, no drag snapping) until terminated, for RSS/CPU sampling.
    case idle
    /// Like `idle`, but after launch the overlay is exercised once (drag entry O1, drop O4, a
    /// keyboard-style flash O5 and a label plate O7 on a small rect in a corner of the main
    /// screen, synthetic events, core not involved) so the panel, its layers and the plate's text
    /// exist: idle memory AFTER use.
    case used
    /// Like `idle`, but 6 s after launch Nokta opens its own status menu once and closes it
    /// 1.5 s later (in bench modes every item but Quit is disabled, so nothing in it can act), so
    /// the harness can measure what a first menu open leaves resident.
    case menu
    /// `--bench-preview <surface>`: one onboarding screen (`onboarding-1`…`-3`, `onboarding-2-waiting`
    /// for the not-yet-allowed state, `onboarding-2-grant` for access arriving 5 s later) or Settings tab (`settings-general` …) on the real screen, for
    /// device checks of rendering and of the cost of its animations. Same guarantees as every bench
    /// mode (no shortcuts, no drag snapping, no window moved); preferences live in a throwaway
    /// domain, and the window number is reported (`NOKTA_BENCH_EVENT window <n>`) for capture.
    case preview(String)
    /// A scripted use session in one process, for the resource report (`tools/bench/bench.py
    /// session`): fresh idle, the status menu opened and closed, Settings opened and closed 20
    /// times, a shortcut workload (the keyboard path's visible part: flash + label, from synthetic
    /// snapped events; the core moves nothing), then idle until terminated. Every phase boundary is
    /// reported (`NOKTA_BENCH_EVENT phase <name>`). Same guarantees as every bench mode: no
    /// shortcut is bound, no window of another app is touched, preferences are a throwaway domain,
    /// Settings is shown without activating Nokta (the user's focus stays where it is).
    case session

    var isPreview: Bool { if case .preview = self { return true } else { return false } }
    /// Modes that may show Settings or onboarding (with throwaway preferences).
    var showsWindows: Bool { isPreview || self == .session }

    static var current: BenchMode { parse(ProcessInfo.processInfo.arguments) }

    static func parse(_ args: [String]) -> BenchMode {
        if args.contains("--bench-startup") { return .startup }
        if args.contains("--bench-idle") { return .idle }
        if args.contains("--bench-used") { return .used }
        if args.contains("--bench-menu") { return .menu }
        if args.contains("--bench-session") { return .session }
        // Fails closed: a missing or flag-shaped surface is still a bench mode (shows nothing),
        // never a normal launch.
        if let i = args.firstIndex(of: "--bench-preview") {
            let surface = i + 1 < args.count ? args[i + 1] : ""
            return .preview(surface.hasPrefix("-") ? "" : surface)
        }
        return .none
    }

    /// The throwaway preferences domain of `--bench-preview` (Settings and onboarding write to it
    /// when clicked; the user's own preferences are never read or written).
    static let previewDefaults: UserDefaults = {
        #if NOKTA_SNAPSHOT
        return ScratchDefaults(suiteName: "nokta.snapshot.preview")! // the offscreen tools write no domain
        #else
        let name = Product.bundleID + ".bench-preview"
        // Never falls back to the real domain; starts empty each run.
        let d = UserDefaults(suiteName: name) ?? UserDefaults(suiteName: Product.bundleID + ".bench-preview.fallback")!
        d.removePersistentDomain(forName: name)
        return d
        #endif
    }()

    /// Defaults the overlay reads in `used`: a throwaway domain (nothing is ever written to it),
    /// so the exercise neither depends on nor touches the user's preferences.
    static let usedDefaults = UserDefaults(suiteName: Product.bundleID + ".bench-used") ?? .standard

    /// Bench modes only: reports a user interaction (e.g. the menu was opened) on stderr, so the
    /// harness can tell an idle sample from one that includes interaction.
    static func note(_ what: String) {
        FileHandle.standardError.write(Data("NOKTA_BENCH_EVENT \(what) \(mach_absolute_time())\n".utf8))
    }
}

/// Owns the engine and every UI controller; routes core events to UI and feedback.
final class AppController: NSObject, NSApplicationDelegate {
    let prefs: Preferences
    /// Its events always come back here (hotkey outcomes included), whoever starts it.
    private(set) lazy var engine: NoktaEngine = {
        let engine = NoktaEngine(config: prefs.coreConfig)
        engine.onEvent = { [weak self] in self?.handle($0) }
        return engine
    }()
    let bench: BenchMode

    private(set) var statusMenu: StatusMenuController?
    private(set) var overlay: SnapOverlayController?
    private(set) var feedback: Feedback?
    private(set) var hud: HUDController?
    private var settings: SettingsWindowController?
    private var onboarding: OnboardingWindowController?

    /// Outcome of the last hotkey registration per action (shown in Settings → Shortcuts).
    private(set) var hotkeyResults: [NoktaAction: NoktaResult] = [:]
    private(set) var engineResult: NoktaResult = .notStarted
    /// Last snapped event.
    private(set) var lastSnap: NoktaEvent?

    private var observers: [NSObjectProtocol] = []
    private var voiceOverObservation: NSKeyValueObservation?

    /// Fixed VoiceOver state instead of the system's (offscreen render tools).
    var voiceOverOverride: Bool?
    /// `--bench-preview` only: the permission state the UI shows.
    var trustOverride: Bool?

    /// VoiceOver protection (DESIGN §8): while VO runs, ⌃⌥ shortcuts are not registered.
    var voiceOverSuspended: Bool {
        (voiceOverOverride ?? NSWorkspace.shared.isVoiceOverEnabled) && !prefs.keepClassicWithVoiceOver
    }
    private var applyingPreferences = false

    var isRunning: Bool { engineResult == .ok || engineResult == .eventTap }

    // MARK: lifecycle

    private var launchTicks: UInt64 = 0

    /// `defaults`: where the preferences live. The app uses the standard domain; the offscreen UI
    /// tools pass a throwaway suite. `bench`: the launch arguments' mode; the offscreen tools pass
    /// one to check a bench-mode menu (arguments cannot be passed to them).
    init(defaults: UserDefaults = .standard, bench: BenchMode = .current) {
        if bench != .none { Preferences.systemWritesDisabled = true }
        prefs = Preferences(defaults: bench.showsWindows ? BenchMode.previewDefaults : defaults)
        self.bench = bench
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchTicks = mach_absolute_time()
        NSApp.setActivationPolicy(.accessory)

        // Same path in every mode: menu, overlay, feedback and the status item are built so
        // the startup benchmark measures the real launch. Bench modes then skip what could
        // affect the user's desktop: no shortcuts, no drag snapping, no windows.
        MainMenu.install()
        overlay = SnapOverlayController(defaults: bench == .used ? BenchMode.usedDefaults : .standard)
        feedback = Feedback(prefs: prefs)
        if let overlay { hud = HUDController(prefs: prefs, overlay: overlay) }
        statusMenu = StatusMenuController(app: self)

        if bench != .none {
            startEngine(bindShortcuts: false)
            if bench == .startup { reportReadyAndQuit() }
            if bench == .used { exerciseUIOnceForBench() }
            if bench == .menu {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    self?.statusMenu?.openOnceForBench(closeAfter: 1.5)
                }
            }
            if case .preview(let surface) = bench { showPreview(surface) }
            if bench == .session { runSessionForBench() }
            return
        }

        observeSystem()
        let trusted = NoktaEngine.isTrusted()
        if trusted {
            startEngine(bindShortcuts: true)
        }
        if Self.showsOnboardingAtLaunch(trusted: trusted, prefs: prefs) {
            showOnboarding()
        }
    }

    /// Onboarding opens by itself on a first launch, and whenever Accessibility is missing (Nokta
    /// cannot work then; a returning user lands on the permission screen, not on Welcome). A user
    /// who closed it once while access was there is not shown it again at every launch: the menu
    /// keeps "Finish Setup…" for them.
    static func showsOnboardingAtLaunch(trusted: Bool, prefs: Preferences) -> Bool {
        !trusted || (!prefs.onboardingDone && !prefs.onboardingSeen)
    }

    private func reportReadyAndQuit() {
        let ready = mach_absolute_time()
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ms = { (a: UInt64, b: UInt64) in Double(b - a) * Double(tb.numer) / Double(tb.denom) / 1e6 }
        let trace = String(format: "NOKTA_TRACE main→didFinish %.1f ms, didFinish→ready %.1f ms\n",
                           ms(processStartTicks, launchTicks), ms(launchTicks, ready))
        FileHandle.standardError.write(Data(trace.utf8))
        print("NOKTA_READY \(ready) result=\(engineResult.rawValue)")
        fflush(stdout)
        NSApp.terminate(nil)
    }

    /// `--bench-used`: the overlay's drag entry (O1) and drop (O4), then a keyboard-style flash (O5)
    /// with its label plate (O7), on a small rect in the bottom left corner of the main screen,
    /// from synthetic events. Only the overlay/HUD text code runs (the core is not asked to do
    /// anything and no window is touched); it creates the panel, its layers and the plate's text,
    /// which then stay resident like after real use. Starts 300 ms after launch, once the status
    /// item has settled; each step starts after the previous transition ended (≤ 260 ms).
    private func exerciseUIOnceForBench() {
        // User-like events at fixed times after launch (not an animation: each transition
        // is one timeline on the render server).
        func at(_ ms: Int, _ body: @escaping (AppController, SnapOverlayController) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                if let self, let overlay = self.overlay { body(self, overlay) }
            }
        }
        at(300) { $1.showPreview(Self.benchEvent(.previewShow, action: .bottomLeft, zone: .bottomLeft, source: .drag)) } // O1
        at(600) { $1.hidePreview(committed: true) }                                                                       // O4
        at(1000) { app, _ in app.flashForBench(.leftHalf) }                                                               // O5 + O7
    }

    /// A synthetic core event on a small rect in the bottom left corner of the main screen.
    private static func benchEvent(_ kind: NoktaEvent.Kind, action: NoktaAction, zone: NoktaZone?,
                                   source: NoktaEvent.Source) -> NoktaEvent {
        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let rect = CGRect(x: bounds.minX + 40, y: bounds.maxY - 40 - 120, width: 200, height: 120)
        return NoktaEvent(kind: kind, action: action, zone: zone, source: source, result: .ok, displayID: display,
                          cycle: 1, rect: rect, latencyNs: 0, frameDiffers: false, sizeRefused: false, drop: false)
    }

    /// What a keyboard snap shows (flash O5, label plate O7), from a synthetic event.
    private func flashForBench(_ action: NoktaAction) {
        guard let overlay else { return }
        let event = Self.benchEvent(.snapped, action: action, zone: nil, source: .keyboard)
        overlay.flash(event)
        if let label = HUDText.label(for: event, mode: .whenNeeded, displayNumber: nil) {
            overlay.showLabel(label, rectCG: event.rect, displayID: event.displayID, blocked: false)
        }
    }

    /// `--bench-session` (see BenchMode.session). Times are seconds after launch; the harness
    /// samples between the reported phase boundaries. Arguments (each clamped, fails closed):
    /// `--fresh <s>` (default 30), `--settings-cycles <n>` (20), `--uses <n>` (60).
    private func runSessionForBench() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count, let v = Double(args[i + 1]), v.isFinite else { return fallback }
            return min(max(v, range.lowerBound), range.upperBound)
        }
        let fresh = value("--fresh", 30, 1...600)
        let cycles = Int(value("--settings-cycles", 20, 1...100))
        let uses = Int(value("--uses", 60, 1...1000))
        var t = fresh
        func at(_ seconds: Double, _ body: @escaping (AppController) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in if let self { body(self) } }
        }
        // Every phase mark is followed by `quiet` seconds before the phase acts, so the harness's
        // boundary reading (vmmap) sees the previous phase only.
        let quiet = 1.5
        BenchMode.note("phase fresh")
        // Menu: open, stay open 5 s, close (menuWillOpen/menuDidClose report the edges).
        at(t) { _ in BenchMode.note("phase menu") }
        at(t + quiet) { $0.statusMenu?.openOnceForBench(closeAfter: 5) }
        t += quiet + 8
        // Settings: open, 1 s on screen, close (⌘W path), 1 s closed; `cycles` times.
        at(t) { _ in BenchMode.note("phase settings") }
        for i in 0..<cycles {
            let start = t + quiet + Double(i) * 2
            at(start) { $0.showSettingsForBench(tab: SettingsWindowController.Tab.allCases[i % SettingsWindowController.Tab.allCases.count]) }
            at(start + 1) { $0.settings?.window?.performClose(nil) }
        }
        t += quiet + Double(cycles) * 2 + 1
        // Shortcut workload: what a keyboard snap shows (flash O5 + label O7) on a small rect in a
        // corner of the main screen, 2 per second. The core is not asked to move anything.
        at(t) { _ in BenchMode.note("phase shortcuts") }
        let used: [NoktaAction] = [.leftHalf, .rightHalf, .maximize, .restore]
        for i in 0..<uses {
            at(t + quiet + Double(i) * 0.5) { $0.flashForBench(used[i % used.count]) }
        }
        t += quiet + Double(uses) * 0.5 + 2
        at(t) { _ in BenchMode.note("phase after-use") }
    }

    /// Settings for `--bench-session`: ordered in without activating Nokta or showing a Dock icon.
    private func showSettingsForBench(tab: SettingsWindowController.Tab) {
        if settings == nil { settings = SettingsWindowController(app: self) }
        settings?.show(tab: tab, activate: false)
        BenchMode.note("settings-open")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The harness stops bench instances with SIGTERM, which does not come through here:
        // a terminate in a long-running bench mode was the user's (menu Quit).
        if bench == .idle || bench == .used { BenchMode.note("quit") }
        DistributedNotificationCenter.default().removeObserver(self)
        engine.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-launching from Finder opens Settings (the menu bar icon may be hidden).
        if bench != .none { BenchMode.note("reopen") }
        showSettings()
        return false
    }

    // MARK: engine

    /// Called at launch (if trusted) and by onboarding once Accessibility is granted. In a bench
    /// mode it never binds shortcuts and keeps drag snapping off, whatever `bindShortcuts` says.
    /// Re-entrancy guard: starting the core emits HOTKEY_STATE events synchronously, and UI
    /// handlers for those may call checkHealth() → startEngine() again.
    private var startingEngine = false

    func startEngine(bindShortcuts: Bool) {
        guard !paused, !startingEngine else { return }
        startingEngine = true
        defer { startingEngine = false }
        engine.stop()
        engine.pushScreenGeometry()
        if bindShortcuts && bench == .none {
            applyPreferencesToEngine()
        } else {
            // Bench modes must never act on the user's windows: no shortcuts (not bound) and no
            // drag snapping (no event tap / observer), so nothing can move a real window.
            var config = prefs.coreConfig
            if bench != .none { config.drag_snap = false }
            engine.apply(config: config)
        }
        engineResult = engine.start()
        if let app = NSWorkspace.shared.frontmostApplication {
            engine.appActivated(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        }
        statusMenu?.refresh()
    }

    /// Self-healing. Callers: wake and fast-user-switch (`observeSystem`), menu open
    /// (`StatusMenuController.menuNeedsUpdate`), the system's Accessibility-list broadcast
    /// (`accessibilityListChanged`, 250 ms coalesced), a `.failed` event with `.notTrusted`
    /// (`handle`, one run-loop turn later) and onboarding when its own check sees the grant.
    /// Restarts the core when Accessibility comes back, stops it when it is revoked, and
    /// re-creates a disabled event tap. Cheap (one AXIsProcessTrusted + one stats read).
    func checkHealth() {
        guard bench == .none, !startingEngine else { return }
        let trusted = NoktaEngine.isTrusted()
        if !trusted {
            if engineResult != .notTrusted {
                engine.stop()
                engineResult = .notTrusted
                statusMenu?.refresh()
                settings?.refresh()
            }
            return
        }
        if paused {
            // The core stays stopped, but a revoke seen while paused must not outlive the grant:
            // the menu and Settings stop asking for access (Resume starts the core).
            if engineResult == .notTrusted {
                engineResult = .notStarted
                statusMenu?.refresh()
                settings?.refresh()
            }
            return
        }
        let stats = engine.stats()
        if !stats.started {
            startEngine(bindShortcuts: true)
            settings?.refresh()
        } else if prefs.dragSnap && !stats.event_tap_active {
            // Already running: nk_core_start only re-creates the missing tap.
            engineResult = engine.start()
            statusMenu?.refresh()
            settings?.refresh()
        }
    }

    // MARK: permission watcher

    /// Pending coalesced `checkHealth()` and when it is due.
    private var healthCheckWork: DispatchWorkItem?
    private var healthCheckDue = DispatchTime.now()

    /// Runs `checkHealth()` asynchronously (never inside a core callback), then tells onboarding.
    /// Requests that arrive while one is pending are folded into it; a later deadline replaces
    /// an earlier one, so the 250 ms settle of the system broadcast is never cut short.
    private func scheduleHealthCheck(after delay: DispatchTimeInterval) {
        let due = DispatchTime.now() + delay
        if healthCheckWork != nil, healthCheckDue >= due { return }
        healthCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.healthCheckWork = nil
            self.checkHealth()
            NotificationCenter.default.post(name: .noktaPermissionChecked, object: self)
        }
        healthCheckWork = work
        healthCheckDue = due
        DispatchQueue.main.asyncAfter(deadline: due, execute: work)
    }

    /// The system broadcasts `com.apple.accessibility.api` when the Accessibility list changes.
    /// Event driven, no timer, for the app's whole lifetime: revoking or granting the permission
    /// while Nokta runs shows up in the icon and menu within about a second. The TCC database is
    /// written a moment after the broadcast, hence the 250 ms settle (P: device-verify).
    @objc private func accessibilityListChanged(_ note: Notification) {
        scheduleHealthCheck(after: .milliseconds(250))
    }

    /// Menu "Pause": unregisters everything; "Resume" re-binds. Not in a bench mode (its menu
    /// item is disabled there; Resume would bind the shortcuts and the drag tap).
    private(set) var paused = false
    func setPaused(_ value: Bool) {
        guard bench == .none else { return }
        paused = value
        if value {
            engine.stop()
            engineResult = .notStarted
        } else if NoktaEngine.isTrusted() {
            startEngine(bindShortcuts: true)
        }
        statusMenu?.refresh()
    }

    /// While a shortcut recorder listens, hotkeys stay unbound (and the last results stand).
    /// Never in a bench mode: it binds the shortcuts and may enable drag snapping.
    func applyPreferencesToEngine() {
        guard bench == .none else { return }
        let results = prefs.apply(to: engine, suspendControlOption: voiceOverSuspended,
                                  bindShortcuts: !shortcutsSuspended)
        if !shortcutsSuspended { hotkeyResults = results }
    }

    private func applyPreferences() {
        guard !applyingPreferences else { return }
        applyingPreferences = true
        defer { applyingPreferences = false }
        applyPreferencesToEngine()
        statusMenu?.refresh()
        settings?.refresh()
    }

    private func handle(_ event: NoktaEvent) {
        switch event.kind {
        case .previewShow:
            overlay?.showPreview(event)
            feedback?.zoneEntered(event)
        case .previewHide:
            overlay?.hidePreview(committed: event.drop)
        case .snapped:
            lastSnap = event
            if event.source != .drag { overlay?.flash(event) }
            feedback?.snapped(event)
            hud?.show(event)
            statusMenu?.noteSnap(event)
            settings?.noteSnap(event)
        case .failed:
            feedback?.failed(event)
            hud?.show(event)
            // The permission vanished under a running core: heal outside its callback.
            if event.result == .notTrusted { scheduleHealthCheck(after: .milliseconds(0)) }
        case .hotkeyState:
            if let action = event.action { hotkeyResults[action] = event.result }
            settings?.refresh()
        }
    }

    /// Event-driven system observers (no timer). The offscreen tests call it too; nothing here
    /// shows anything.
    func observeSystem() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.engine.appActivated(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        })
        // Sleep/wake and fast user switching are where competitors silently lose hotkeys
        // and taps: re-check and re-arm.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.engine.displaysChanged()
                self?.checkHealth()
            })
        }
        // `.deliverImmediately`: an accessory app is rarely active, and the default behaviour
        // holds distributed notifications back while the app is inactive.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(accessibilityListChanged(_:)),
            name: Notification.Name("com.apple.accessibility.api"), object: nil,
            suspensionBehavior: .deliverImmediately)
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyPreferences() }
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.pushScreenGeometry()
            self?.overlay?.screensChanged()
        })
        observers.append(nc.addObserver(forName: .noktaPreferencesChanged, object: prefs, queue: .main) { [weak self] _ in
            self?.applyPreferences()
        })
        // Another keyboard layout: the same shortcuts (key positions), new labels.
        observers.append(nc.addObserver(forName: .noktaKeyboardLayoutChanged, object: nil, queue: .main) { [weak self] _ in
            self?.settings?.refresh()
        })
    }

    // MARK: windows

    func showSettings(tab: SettingsWindowController.Tab? = nil) {
        // Bench modes open no windows (SPEC §7) and must not touch the user's preferences; only
        // `--bench-preview` shows one, with its own throwaway preferences.
        guard bench == .none || bench.isPreview else { return }
        if settings == nil { settings = SettingsWindowController(app: self) }
        setDockVisible(true)
        settings?.show(tab: tab)
    }

    func showOnboarding() {
        guard bench == .none || bench.isPreview else { return }
        if onboarding == nil { onboarding = OnboardingWindowController(app: self) }
        setDockVisible(true)
        onboarding?.show()
    }

    /// `--bench-preview`: shows the requested surface and reports its window number.
    private func showPreview(_ surface: String) {
        let window: NSWindow?
        if surface.hasPrefix("onboarding-") {
            trustOverride = !surface.hasSuffix("-waiting") && !surface.hasSuffix("-grant")
            if surface.hasSuffix("-grant") {
                // Access "arrives" 5 s later, as if switched on in System Settings: the permission
                // screen must notice it (even while covered) and come to the front (DESIGN §11).
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.trustOverride = true
                    BenchMode.note("granted")
                }
            }
            let screen = Int(surface.dropFirst("onboarding-".count).prefix(1)) ?? 1
            showOnboarding()
            onboarding?.go(to: max(0, min(2, screen - 1)), animated: false)
            window = onboarding?.window
        } else if surface.hasPrefix("settings-"), let tab = SettingsWindowController.Tab(rawValue: String(surface.dropFirst("settings-".count))) {
            showSettings(tab: tab)
            window = settings?.window
        } else {
            BenchMode.note("preview-unknown \(surface)")
            return
        }
        if let window { BenchMode.note("window \(window.windowNumber)") }
        // `--close-after <s>`: closes the surface like ⌘W would, to measure what stays resident.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--close-after"), i + 1 < args.count, let s = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak window] in
                window?.performClose(nil)
                BenchMode.note("closed")
            }
        }
    }

    /// Called by Settings/Onboarding when their window closes.
    func windowClosed(_ controller: AnyObject) {
        if controller === onboarding { onboarding = nil }
        if controller === settings { settings = nil }
        if settings == nil && onboarding == nil { setDockVisible(false) }
    }

    /// Settings/Onboarding show a Dock icon so the user can ⌘-Tab back from System Settings.
    private func setDockVisible(_ visible: Bool) {
        #if NOKTA_SNAPSHOT
        return // the offscreen tools are never in the Dock and never activate
        #else
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible { NSApp.activate(ignoringOtherApps: true) }
        #endif
    }

    #if NOKTA_SNAPSHOT
    /// Tests: Settings built on `tab` as `showSettings` would, without showing a window.
    func testAttachSettings(tab: SettingsWindowController.Tab) -> SettingsWindowController {
        let controller = settings ?? SettingsWindowController(app: self)
        settings = controller
        controller.select(tab: tab)
        return controller
    }
    #endif
}
