import AppKit
import QuartzCore

/// First-run onboarding and the Accessibility permission flow (docs/DESIGN.md §11, §14). 560 × 472
/// on paper: a persistent 480 × 200 stage whose scene changes while its frame never moves, the
/// text column below it, progress segments bottom left, buttons bottom right. Three screens —
/// Welcome (Scene A), Access (Scene B, then the access-granted moment E), Try (Scene C, a
/// practice) — joined by the page transition D. Return = primary, ⌘[ = Back, Esc/⌘W = Later;
/// clicking the stage (or Space on it with Full Keyboard Access) replays its scene.
///
/// Practice (screen 3): Scene C guides the next step (its keys press, the window lands, on a loop);
/// a local key monitor, only while that screen is up, shows the modifiers the user holds on the
/// stage's keycaps and on the practice line, and reads every key press that reaches the window —
/// Snapline's own shortcuts never do (Carbon takes them), so what arrives is a near miss to explain.
/// Any key stops the guide; after 6 s without one it plays again for the step that is next.
///
/// Motion follows the `pose(at t)` contract (§5.2): every scene and transition is a `Timeline`
/// played on the render server, and nothing moves unless the `MotionGate` is open (window
/// visible, not occluded or miniaturized, app not hidden, displays awake, Reduce Motion off). When
/// it closes everything stops at its rest pose (Reduce Motion: the explain pose); when it opens
/// loops start over and Scene A plays only if it never ran to its end.
///
/// The only timer in the app lives here: the 1 Hz permission fallback, tolerance 0.5, only while
/// screen 2 is seen (the gate's conditions: visible, not occluded or miniaturized, app not hidden,
/// displays awake — Reduce Motion or not).
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private unowned let app: AppController

    private let content = OnboardingContentView(frame: .zero)
    private let stage = StageView(frame: OnboardingMetrics.stage)
    /// Above everything: the periods that fly from the stage into the text (window coordinates).
    private let overlay = LayerView(frame: .zero)
    private let progress = ProgressSegments(frame: .zero)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let laterButton = NSButton(title: "Later", target: nil, action: nil)
    private let primaryButton = NSButton(title: "Continue", target: nil, action: nil)

    private var welcome: WelcomePage!
    private var access: AccessPage!
    private var tryPage: TryPage!
    private var pages: [OnboardingPage] = []
    private let drag = DragScene()
    private let permission = AccessScene()
    private let keys = KeysScene()
    private var scenes: [StageScene] { [drag, permission, keys] }
    /// Scene A's period on its way into the wordmark, and E's R4 dot on its way into the title.
    private let flightPeriod = StageDot.make(diameter: 8)
    private let flightDot = StageDot.make(diameter: 8)
    private var palette: StagePalette?

    private var currentIndex = 0
    private var trusted = false
    private var didPrompt = false
    private var appliedVoiceOverSet = false
    private var appliedFamiliarSet = false
    private var trustTimer: Timer?
    private var permissionObservers: [NSObjectProtocol] = []
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var voiceOverObservation: NSKeyValueObservation?
    #if NOKTA_SNAPSHOT
    /// Offscreen renders: lay out VoiceOver's extra row without VoiceOver.
    var voiceOverOverride: Bool? { didSet { voiceOverChanged() } }
    #endif

    // MARK: motion state

    private let gate = MotionGate()
    /// Bumped by every play and stop; a completion whose token is stale does nothing.
    private var motionToken = 0
    private var transitionToken = 0
    /// A page transition runs (320 ms; Reduce Motion 150 ms): input is ignored meanwhile.
    private var transitioning = false
    private var transitionFrom = 0
    /// A scene or the access-granted moment is playing.
    private var playing = false
    /// Scene A ran to its end once (it plays again only on a replay).
    private var dragPlayed = false
    /// Access arrived while screen 2 was not visible: E plays when it is.
    private var grantPending = false
    private var grantPlaying = false
    /// Screen 3 has been current: from then on real snaps move Scene C's window too.
    private var tryShown = false
    /// Scene C plays the guide for the next step.
    private var guidePlaying = false
    /// The last snap Scene C showed (its key stays on the action keycap once all four are done).
    private var lastMirrored: NoktaAction?

    // MARK: practice state (screen 3)

    private var practiceMonitor: Any?
    /// The user pressed something: the guide waits, the stage shows their keys.
    private var practicePaused = false
    private var idleResume: DispatchWorkItem?
    /// The modifiers held now (only while screen 3 is up).
    private var held: NoktaMods = []
    /// A press's outcome since the modifiers went down: it stays on the line over "⌃⌥ held".
    private var resultSinceHold = false
    /// What the last press did, until the idle timeout.
    private var lastResult: PracticeStatus?
    /// Known window managers that run now (they answer keys too).
    private var runningManagers: [String] = []
    #if NOKTA_SNAPSHOT
    /// Offscreen tools: which apps count as installed / running (never this Mac's).
    var installedOverride: (String) -> Bool = { _ in false }
    var runningOverride: [String] = [] { didSet { runningManagers = runningOverride; refreshPracticeLine() } }
    #endif

    init(app: AppController) {
        self.app = app
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        stopWatchingPermission()
        if let practiceMonitor { NSEvent.removeMonitor(practiceMonitor) }
        idleResume?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: window

    #if NOKTA_SNAPSHOT
    private var voiceOverOn: Bool { voiceOverOverride ?? NSWorkspace.shared.isVoiceOverEnabled }
    private var otherManagersRunning: [String] { runningOverride }
    private func isInstalled(_ bundleID: String) -> Bool { installedOverride(bundleID) }
    #else
    private var voiceOverOn: Bool { NSWorkspace.shared.isVoiceOverEnabled }
    private var otherManagersRunning: [String] {
        Preferences.runningWindowManagers(among: NSWorkspace.shared.runningApplications.map(\.bundleIdentifier))
    }
    private func isInstalled(_ bundleID: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    #endif

    /// Builds the window without showing it (also used by offscreen renders).
    func prepareWindow() {
        guard window == nil else { return }
        let size = NSSize(width: OnboardingMetrics.width, height: OnboardingMetrics.height)
        let window = OnboardingWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable, .fullSizeContentView],
                                      backing: .buffered, defer: true)
        window.title = "Welcome to \(Product.name)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        window.backgroundColor = Theme.Color.paper
        window.autorecalculatesKeyViewLoop = true
        window.onCancel = { [weak self] in self?.later(nil) }
        window.delegate = self
        self.window = window

        content.frame = NSRect(origin: .zero, size: size)
        window.contentView = content
        trusted = app.isTrusted
        runningManagers = otherManagersRunning
        buildContent()
        applyPalette()
        go(to: 0, animated: false)

        gate.onChange = { [weak self] _ in self?.motionChanged() }
        gate.attach(to: window)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkTrust()
        })
        observers.append(center.addObserver(forName: .noktaDidSnap, object: app, queue: .main) { [weak self] note in
            if let event = note.userInfo?["event"] as? NoktaEvent { self?.noteSnap(event) }
        })
        observers.append(center.addObserver(forName: .noktaPreferencesChanged, object: app.prefs, queue: .main) { [weak self] _ in
            self?.preferencesChanged()
        })
        // Same keys, new labels (the chips and Scene C's keycaps name keys of the current layout).
        observers.append(center.addObserver(forName: .noktaKeyboardLayoutChanged, object: nil, queue: .main) { [weak self] _ in
            self?.preferencesChanged()
        })
        observers.append(center.addObserver(forName: .noktaAccessibilityChanged, object: nil, queue: .main) { [weak self] _ in
            self?.accessibilityChanged()
        })
        // The permission fallback follows what the gate sees even while Reduce Motion keeps the
        // gate shut (its `onChange` never fires then): re-read once the gate's own observers ran.
        func followsVisibility(_ nc: NotificationCenter, _ name: Notification.Name, _ object: AnyObject?) -> NSObjectProtocol {
            nc.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.updateTrustTimerSoon() }
        }
        observers.append(followsVisibility(center, NSWindow.didChangeOcclusionStateNotification, window))
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(followsVisibility(center, name, nil))
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(followsVisibility(NSWorkspace.shared.notificationCenter, name, nil))
        }
        // Tiles, Spectacle… start or quit: the practice line says whether they compete for keys.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let now = self.otherManagersRunning
                guard now != self.runningManagers else { return }
                self.runningManagers = now
                self.refreshPracticeLine()
            })
        }
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            DispatchQueue.main.async { self?.voiceOverChanged() }
        }
    }

    /// Set by "Allow Accessibility…" in the menu: the next `show()` starts on the permission
    /// screen even if setup was never finished. Consumed by `show()`.
    static var opensAtPermission = false
    /// Set by Settings › Shortcuts › Practice: the next `show()` goes to the practice screen
    /// (when access is there). Consumed by `show()`.
    static var opensAtPractice = false

    func show() {
        let fresh = window == nil
        prepareWindow()
        guard let window else { return }
        let wantsPermission = Self.opensAtPermission, wantsPractice = Self.opensAtPractice
        Self.opensAtPermission = false
        Self.opensAtPractice = false
        if window.isMiniaturized {
            // Back from the Dock where it was, on its page.
            window.deminiaturize(nil)
        } else if fresh || !window.isVisible {
            go(to: wantsPractice && app.isTrusted ? 2 : startPage(wantsPermission: wantsPermission), animated: false)
            window.center()
        }
        if wantsPermission, !app.isTrusted, currentIndex != 1 { go(to: 1, animated: true) }
        if wantsPractice, app.isTrusted, currentIndex != 2 { go(to: 2, animated: true) }
        gate.isActive = true
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        gate.update()
        pageDidAppear()
    }

    /// The page a closed window opens on: Welcome the first time; straight to the permission screen
    /// when access is missing and the user has been here before (or came from "Allow Accessibility…");
    /// straight to the practice when access is there and the user has not practised yet.
    func startPage(wantsPermission: Bool) -> Int {
        let returning = app.prefs.onboardingDone || app.prefs.onboardingSeen || wantsPermission
        guard returning else { return 0 }
        if !app.isTrusted { return 1 }
        return app.prefs.practiceSeen ? 0 : 2
    }

    private func buildContent() {
        let pageFrame = self.pageFrame
        welcome = WelcomePage(frame: pageFrame)
        access = AccessPage(frame: pageFrame)
        tryPage = TryPage(frame: pageFrame, target: self, login: #selector(toggleLogin(_:)), setAction: #selector(changeSet(_:)))
        pages = [welcome, access, tryPage]
        // Open at login: ON by default (visible) only on first setup; when onboarding is reopened
        // (permission recovery, Finish Setup) it shows the real state and is written only if the
        // user flips it — Nokta never changes the login item on its own.
        tryPage.loginSwitch.state = (!app.prefs.onboardingDone || app.prefs.launchAtLogin) ? .on : .off

        content.addSubview(stage)
        stage.onReplay = { [weak self] in self?.replay() }
        stage.onAppearanceChange = { [weak self] in self?.applyPalette() }
        content.addSubview(progress)

        backButton.target = self
        backButton.action = #selector(back(_:))
        backButton.keyEquivalent = "["
        backButton.keyEquivalentModifierMask = .command
        backButton.toolTip = "Back (⌘[)"
        laterButton.target = self
        laterButton.action = #selector(later(_:))
        laterButton.toolTip = "Later (Esc)"
        primaryButton.target = self
        primaryButton.action = #selector(primary(_:))
        primaryButton.keyEquivalent = "\r"
        for b in [backButton, laterButton, primaryButton] {
            b.bezelStyle = .rounded
            content.addSubview(b)
        }

        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay)
        for dot in [flightPeriod, flightDot] {
            dot.opacity = 0
            overlay.root.addSublayer(dot)
        }
        layoutChrome()
    }

    private var pageFrame: CGRect {
        CGRect(x: OnboardingMetrics.columnX, y: OnboardingMetrics.pageTop,
               width: OnboardingMetrics.columnWidth, height: OnboardingMetrics.pageHeight)
    }

    /// Bottom bar: progress at the left, buttons right-aligned (Back · Later · primary).
    private func layoutChrome() {
        let mid = OnboardingMetrics.height - OnboardingMetrics.barHeight / 2
        let size = progress.intrinsicContentSize
        progress.frame = CGRect(x: OnboardingMetrics.columnX, y: mid - 6, width: size.width, height: 12)
        var x = OnboardingMetrics.columnX + OnboardingMetrics.columnWidth
        for b in [primaryButton, laterButton, backButton] where !b.isHidden {
            b.sizeToFit()
            let w = max(ceil(b.frame.width), 76), h = ceil(b.frame.height)
            x -= w
            b.frame = CGRect(x: x, y: (mid - h / 2).rounded(), width: w, height: h)
            x -= Theme.Space.s3
        }
        if !transitioning { for p in pages { p.frame = pageFrame } }
    }

    /// VoiceOver pauses ⌃⌥ shortcuts: the practice line says so.
    private func voiceOverChanged() {
        guard window != nil else { return }
        updateCurrentPage()
    }

    // MARK: navigation

    func go(to index: Int, animated: Bool) {
        guard pages.indices.contains(index), !transitioning else { return }
        let from = currentIndex
        if from == 0, from != index, playing { dragPlayed = true } // seen, and the user moved on
        stopMotion() // the page changes: the old scene stops at rest (§5.2 rule 6)
        grantPending = false
        if from == 2, index != 2 { stopPractice() }
        currentIndex = index
        if index == 2 { tryShown = true }
        stage.scene = scenes[index]
        updateCurrentPage()
        updateButtons()
        if animated, from != index, gate.conditionsMet, pages[from].superview != nil {
            transition(from: from, to: index)
            return
        }
        for (i, p) in pages.enumerated() where i != index { p.removeFromSuperview() }
        for (i, s) in scenes.enumerated() where i != index { s.root.removeFromSuperlayer() }
        install(page: pages[index])
        install(scene: scenes[index])
        progress.current = index
        showStatic()
        if window?.isVisible == true { pageDidAppear() }
    }

    private func install(page: OnboardingPage) {
        guard page.superview == nil else { return }
        page.frame = pageFrame
        content.addSubview(page, positioned: .below, relativeTo: overlay)
    }

    private func install(scene: StageScene) {
        guard scene.root.superlayer == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.root.opacity = 1
        scene.root.setValue(1, forKeyPath: "transform.scale")
        stage.content.addSublayer(scene.root)
        CATransaction.commit()
    }

    /// Both pages and scenes in place for Storyboard D; returns its timeline and layers.
    private func beginTransition(from: Int, to: Int, reduceMotion rm: Bool) -> (Timeline, [LayerID: CALayer]) {
        typealias ID = OnboardingTimelines.PageID
        let old = pages[from], new = pages[to]
        install(page: new)
        install(scene: scenes[to])
        let entry = entryPose(to)
        scenes[to].show(entry)
        var colors: [LayerID: (from: CGColor, to: CGColor)] = [:]
        for i in 0..<ProgressSegments.count {
            if let a = progress.color(i, current: from), let b = progress.color(i, current: to) { colors[ProgressSegments.id(i)] = (a, b) }
        }
        progress.current = to
        var layers = progress.layers
        layers[ID.oldPage] = old.layer
        layers[ID.newPage] = new.layer
        layers[ID.oldScene] = scenes[from].root
        layers[ID.newScene] = scenes[to].root
        // The incoming page's red dot waits for the old page to leave (one red at a time).
        var reds: [CALayer] = []
        if to == 0 {
            StagePlayer.stop(dragExtras)
            PoseApplier.apply(entry, to: dragExtras)
            if entry[OnboardingLayer.wordmarkPeriod, "opacity"] == .scalar(1) { reds.append(welcome.period) }
        } else if to == 1, access.state == .waiting {
            reds.append(access.statusDot)
        }
        for (i, red) in reds.enumerated() { layers[ID.newRed(i)] = red }
        return (OnboardingTimelines.page(forward: to > from, progress: colors, reds: reds.count, reduceMotion: rm), layers)
    }

    private func transition(from: Int, to: Int) {
        let (timeline, layers) = beginTransition(from: from, to: to, reduceMotion: gate.reduceMotion)
        // The views keep their alpha in AppKit too, so a later layer refresh cannot undo the pose.
        pages[from].alphaValue = 0
        pages[to].alphaValue = 1
        transitioning = true
        transitionFrom = from
        transitionToken += 1
        let token = transitionToken
        StagePlayer.play([timeline], on: layers) { [weak self] in
            guard let self, self.transitionToken == token else { return }
            self.endTransition()
        }
    }

    /// The transition is over (or cut short): the old page and scene leave, the new screen starts.
    private func endTransition() {
        guard transitioning else { return }
        transitionToken += 1
        transitioning = false
        cleanUpTransition(from: transitionFrom)
        if window?.isVisible == true { pageDidAppear() } else { showStatic() }
    }

    private func cleanUpTransition(from: Int) {
        let old = pages[from], oldScene = scenes[from]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [old.layer, pages[currentIndex].layer, oldScene.root, scenes[currentIndex].root].compactMap({ $0 })
            + progress.segments + ([welcome.period, access.statusDot] as [CALayer]) {
            l.removeAllAnimations()
        }
        old.removeFromSuperview()
        old.alphaValue = 1
        old.layer?.setValue(0, forKeyPath: "transform.translation.x")
        pages[currentIndex].alphaValue = 1
        pages[currentIndex].layer?.setValue(0, forKeyPath: "transform.translation.x")
        oldScene.root.removeFromSuperlayer()
        CATransaction.commit()
        restorePageState()
    }

    /// After a transition or storyboard the model keeps whatever value its pose set on the pages'
    /// red dots (D holds the incoming one back, E flies R4): each page's own state is written again,
    /// changed or not — screen 2's waiting R4 dot or granted period, and the wordmark's period.
    private func restorePageState() {
        guard !pages.isEmpty else { return }
        showAccessState(force: true)
        PoseApplier.apply(dragStill, to: [OnboardingLayer.wordmarkPeriod: welcome.period])
    }

    /// Screen 2's waiting or granted state (left alone while E plays). `force`: written even if
    /// the state is unchanged.
    private func showAccessState(force: Bool) {
        guard !grantPlaying else { return }
        let want: AccessPage.State = trusted && !grantPending ? .granted : .waiting
        if force || access.state != want { want == .granted ? access.showGranted() : access.showWaiting() }
    }

    private func updateButtons() {
        backButton.isHidden = currentIndex == 0
        laterButton.isHidden = !(currentIndex == 1 && !trusted)
        switch currentIndex {
        case 0: primaryButton.title = "Continue"
        case 1: primaryButton.title = trusted ? "Continue" : "Open System Settings"
        default: primaryButton.title = "Done"
        }
        primaryButton.keyEquivalent = "\r"
        layoutChrome()
    }

    /// Re-reads the state the pages show.
    private func updateCurrentPage() {
        guard !pages.isEmpty else { return }
        showAccessState(force: false)
        tryPage.update(prefs: app.prefs)
        refreshPracticeLine()
        let shortcuts = KeysScene.actions.map { app.prefs.shortcut(for: $0) ?? $0.defaultShortcut }
        keys.configure(modifiers: shortcuts.first??.modifiers ?? [.control, .option],
                       actionKeys: shortcuts.map { s in s.map { KeyNames.name(for: $0.keyCode) } ?? "" })
    }

    private func preferencesChanged() {
        let before = (keys.modifiers, keys.actionKeys)
        updateCurrentPage()
        // New shortcuts mean new keys in Scene C: start its demo over with them.
        guard (keys.modifiers, keys.actionKeys) != before, currentIndex == 2, !transitioning else { return }
        if gate.isOpen, !practicePaused { playGuide() } else { showStatic() }
    }

    /// The page is on screen: start what belongs to it, move VoiceOver to its title.
    private func pageDidAppear() {
        if currentIndex == 1 { startWatchingPermission() } else { stopWatchingPermission() }
        if currentIndex == 2 {
            applyVoiceOverDefaultIfNeeded()
            applyFamiliarSetIfNeeded()
            startPractice()
        }
        if currentIndex != 1 { checkTrust() }
        if let title = pages[currentIndex].titleField { OnboardingSpeech.focus(title) }
        window?.makeFirstResponder(primaryButton)
        if gate.isOpen { resumeMotion() } else if !playing { showStatic() }
    }

    /// DESIGN §11/§10.2: with VoiceOver on, screen 3 starts on the Alternate set (only if the
    /// user still has the untouched Classic defaults: a Classic set the user chose, or any recorded
    /// shortcut, is a decision this never overrides).
    private func applyVoiceOverDefaultIfNeeded() {
        guard !appliedVoiceOverSet, Self.wantsVoiceOverSet(voiceOver: voiceOverOn, prefs: app.prefs) else { return }
        appliedVoiceOverSet = true
        app.prefs.applyShortcutSet(.alternate)
        OnboardingSpeech.announce("Alternate shortcuts selected, because VoiceOver is on.")
    }

    static func wantsVoiceOverSet(voiceOver: Bool, prefs: Preferences) -> Bool {
        voiceOver && !prefs.shortcutsCustomized && prefs.currentShortcutSet == .classic
    }

    /// Screen 3 starts on the set of a window manager the user already knows (Tiles or Spectacle
    /// installed: Option-Command), on the same terms as VoiceOver's: untouched Classic defaults
    /// only, and never over VoiceOver's Alternate. The line says so; the set control is right there.
    private func applyFamiliarSetIfNeeded() {
        guard !appliedFamiliarSet else { return }
        appliedFamiliarSet = true
        guard let familiar = Self.familiarSet(voiceOver: voiceOverOn, prefs: app.prefs, installed: isInstalled) else { return }
        app.prefs.applyShortcutSet(familiar.set)
        lastResult = .familiar(familiar.name, familiar.set, tryPage.target)
        refreshPracticeLine()
        OnboardingSpeech.announce(tryPage.spokenLine)
    }

    static func familiarSet(voiceOver: Bool, prefs: Preferences, installed: (String) -> Bool) -> (name: String, set: Preferences.ShortcutSet)? {
        guard !voiceOver, !prefs.shortcutsCustomized, prefs.currentShortcutSet == .classic else { return nil }
        return Preferences.familiarApp(installed: installed)
    }

    // MARK: motion

    private var dragExtras: [LayerID: CALayer] {
        [OnboardingLayer.flightPeriod: flightPeriod, OnboardingLayer.wordmarkPeriod: welcome.period]
    }

    private func dragTimeline(replay: Bool = false) -> Timeline {
        drag.timeline(stageOrigin: stage.frame.origin, slot: welcome.slotInSuperview, replay: replay)
    }

    private var grantLayers: [LayerID: CALayer] {
        var layers = access.grantLayers
        layers[OnboardingTimelines.GrantID.flight] = flightDot
        return layers
    }

    private func grantTimeline(reduceMotion rm: Bool) -> Timeline {
        let p = palette ?? StagePalette.resolve(appearance: content.effectiveAppearance)
        return OnboardingTimelines.grant(from: access.statusDotInSuperview, to: access.slotInSuperview, titleSize: access.titleSize,
                                         red: p.red, ink: p.ink, reduceMotion: rm)
    }

    /// The gate opened or closed.
    private func motionChanged() {
        if gate.isOpen {
            updateTrustTimer() // a grant it finds plays E instead of B
            resumeMotion()
        } else {
            endTransition()
            stopMotion()
            updateTrustTimer()
        }
    }

    /// What the current screen plays when it may move.
    private func resumeMotion() {
        guard gate.isOpen, !transitioning, !playing, window != nil else { return }
        switch currentIndex {
        case 0: if !dragPlayed { playDrag(replay: false) }
        case 1:
            if grantPending {
                grantPending = false
                playGrant(reduceMotion: false)
            } else if !trusted {
                playAccess()
            }
        default: if !practicePaused { playGuide() }
        }
    }

    /// Every animation off; the current screen at its static pose.
    private func stopMotion() {
        motionToken += 1
        playing = false
        guidePlaying = false
        if grantPlaying {
            grantPlaying = false
            StagePlayer.stop(grantLayers)
            if trusted { access.showGranted() }
        }
        showStatic()
    }

    /// The pose a screen shows while nothing plays: rest, or with Reduce Motion the explain pose.
    private func showStatic() {
        guard palette != nil, !pages.isEmpty else { return }
        let rm = gate.reduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in [flightPeriod, flightDot] {
            dot.removeAllAnimations()
            dot.opacity = 0
        }
        CATransaction.commit()
        switch currentIndex {
        case 0:
            let pose = dragStill
            drag.show(pose)
            StagePlayer.stop(dragExtras)
            PoseApplier.apply(pose, to: dragExtras)
        case 1:
            permission.show(trusted && !grantPending ? AccessScene.granted.restPose : AccessScene.waiting.restPose)
        default:
            if !practicePaused, let target = tryPage.target, let guide = keys.guideTimeline(target) {
                keys.show(rm ? guide.pose(at: guide.explainT) : guide.restPose)
            } else {
                keys.show(keys.restingPose(tryPage.target ?? lastMirrored).merging(keys.heldPose(heldChord)))
            }
        }
    }

    /// Scene A while nothing plays: Reduce Motion's picture; the end once it has played; before
    /// that its first frame, which it starts from as soon as the screen is seen (so the window is
    /// never shown settled, then put back).
    private var dragStill: Pose {
        if gate.reduceMotion { return drag.reducedPose(stageOrigin: stage.frame.origin, slot: welcome.slotInSuperview) }
        let t = dragTimeline()
        return dragPlayed ? t.restPose : t.pose(at: 0)
    }

    /// The pose a scene enters with during Storyboard D: its first frame if it will play next.
    private func entryPose(_ index: Int) -> Pose {
        let willPlay = gate.conditionsMet && !gate.reduceMotion
        switch index {
        case 0:
            return dragStill
        case 1:
            if trusted { return AccessScene.granted.restPose }
            return willPlay ? AccessScene.waiting.pose(at: 0) : AccessScene.waiting.restPose
        default:
            guard !practicePaused, let target = tryPage.target, let guide = keys.guideTimeline(target) else {
                return keys.restingPose(tryPage.target ?? lastMirrored)
            }
            return willPlay ? guide.pose(at: 0) : guide.pose(at: gate.reduceMotion ? guide.explainT : guide.restT)
        }
    }

    /// Starts `timelines` after stopping whatever played; `done` runs only if nothing replaced it.
    private func play(_ timelines: [Timeline], on layers: [LayerID: CALayer], loops: Int = 1, done: (() -> Void)? = nil) {
        motionToken += 1
        let token = motionToken
        StagePlayer.stop(layers)
        playing = true
        guidePlaying = false
        StagePlayer.play(timelines, on: layers, loops: loops) { [weak self] in
            guard let self, self.motionToken == token else { return }
            self.playing = false
            done?()
        }
    }

    private func playDrag(replay: Bool) {
        for l in drag.allLayers { l.removeAllAnimations() }
        play([dragTimeline(replay: replay)], on: drag.layers.merging(dragExtras) { $1 }) { [weak self] in self?.dragPlayed = true }
    }

    private func playAccess() {
        for l in permission.allLayers { l.removeAllAnimations() }
        if trusted {
            play([AccessScene.granted], on: permission.layers)
        } else {
            play([AccessScene.waiting], on: permission.layers, loops: Theme.Motion.maxLoops)
        }
    }

    /// Scene C guides the next step (nothing left to try: the window rests where the user put it).
    private func playGuide() {
        guard let target = tryPage.target, let guide = keys.guideTimeline(target) else {
            stopMotion()
            return
        }
        for l in keys.allLayers { l.removeAllAnimations() }
        play([guide], on: keys.layers, loops: Theme.Motion.maxLoops)
        guidePlaying = true
    }

    /// Storyboard E (Reduce Motion: its cross-fade variant). Scene B jumps to the switch-on pose.
    private func playGrant(reduceMotion rm: Bool) {
        permission.show(AccessScene.granted.restPose)
        access.prepareGrant()
        let timeline = grantTimeline(reduceMotion: rm)
        for (id, view) in access.grantViews { view.alphaValue = CGFloat(timeline.restPose[id, "opacity"]?.scalarValue ?? 1) }
        grantPlaying = true
        play([timeline], on: grantLayers) { [weak self] in
            guard let self else { return }
            self.grantPlaying = false
            self.access.showGranted()
        }
        OnboardingSpeech.focus(access.titleGranted)
    }

    /// A click on the stage, Space on it, or VoiceOver's Replay.
    private func replay() {
        guard !transitioning, gate.isOpen else { return } // hidden or Reduce Motion: the picture stays
        switch currentIndex {
        case 0:
            // From the landed state the wordmark's period leaves first; mid-flight A starts over.
            let shown = (welcome.period.presentation() ?? welcome.period).opacity > 0.5
            playDrag(replay: shown)
        case 1: if !grantPlaying { playAccess() }
        default:
            // The guide again, now, for the step that is next.
            idleResume?.cancel()
            idleResume = nil
            practicePaused = false
            lastResult = nil
            refreshPracticeLine()
            playGuide()
        }
    }

    private func accessibilityChanged() {
        gate.update()
        applyPalette()
        if grantPending, gate.reduceMotion { grantPending = false; updateCurrentPage() }
        if !gate.isOpen, !transitioning { stopMotion() }
    }

    private func applyPalette() {
        guard let window else { return }
        let p = StagePalette.resolve(appearance: content.effectiveAppearance)
        palette = p
        let scale = window.backingScaleFactor
        for s in scenes {
            s.setScale(scale)
            s.apply(p)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in [flightPeriod, flightDot] {
            dot.contentsScale = scale
            StageDot.apply(p, to: dot)
        }
        CATransaction.commit()
        stage.apply(p)
        progress.apply(p)
        pages.forEach { $0.apply(p) }
    }

    // MARK: permission (screen 2)

    private func startWatchingPermission() {
        checkTrust() // (1) on appearance
        guard !trusted else { return }
        if permissionObservers.isEmpty {
            // (2) the system broadcast when the Accessibility list changes (P) is watched app-wide
            // (AppController): it runs checkHealth() 250 ms after the broadcast, then posts this.
            permissionObservers.append(NotificationCenter.default.addObserver(
                forName: .noktaPermissionChecked, object: app, queue: .main) { [weak self] _ in
                self?.checkTrust()
            })
        }
        // (3) didBecomeActive is observed for the whole window lifetime (prepareWindow).
        updateTrustTimer(checked: true)
    }

    /// (4) fallback: 1 Hz only while this screen is seen — the gate's conditions, whatever Reduce
    /// Motion says. Hidden, occluded, miniaturized or with the displays asleep it stops ((2) and (3)
    /// still catch the grant); seen again, it starts over with a check (`checked`: just made).
    private func updateTrustTimer(checked: Bool = false) {
        // Covered still counts: the user is usually in System Settings, on top of this window (OV2V-1).
        guard window != nil, currentIndex == 1, !trusted, gate.isActive, gate.isOnScreenIgnoringOcclusion else {
            trustTimer?.invalidate()
            trustTimer = nil
            return
        }
        guard trustTimer == nil else { return }
        if !checked {
            checkTrust()
            guard !trusted, trustTimer == nil else { return }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkTrust() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    /// `updateTrustTimer` after the current notification's other observers (the gate's) ran.
    private func updateTrustTimerSoon() {
        DispatchQueue.main.async { [weak self] in self?.updateTrustTimer() }
    }

    private func stopWatchingPermission() {
        trustTimer?.invalidate()
        trustTimer = nil
        permissionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        permissionObservers.removeAll()
    }

    private func checkTrust() {
        guard window != nil else { return }
        let now = app.isTrusted
        guard now != trusted else { return }
        trusted = now
        if now {
            stopWatchingPermission()
            app.checkHealth() // starts the core unless the app-wide watcher already did
            OnboardingSpeech.announce("Access granted.", high: true)
            grantArrived()
            if window?.isVisible == true {
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        } else {
            grantPending = false
            if grantPlaying { stopMotion() }
            if currentIndex == 1, window?.isVisible == true { startWatchingPermission() }
        }
        updateCurrentPage()
        updateButtons()
        guard currentIndex == 1, !transitioning, !grantPlaying else { return }
        if trusted, !grantPending { OnboardingSpeech.focus(access.titleGranted) }
        if gate.isOpen, !trusted { playAccess() } else if !grantPending { stopMotion() }
    }

    /// Special moment 2 on screen 2: now if the screen is seen, later if it is not.
    private func grantArrived() {
        guard currentIndex == 1, !transitioning else { return } // elsewhere: the static granted state
        if gate.isOpen {
            playGrant(reduceMotion: false)
        } else if gate.conditionsMet {
            playGrant(reduceMotion: true) // visible with Reduce Motion: cross-fades only
        } else if !gate.reduceMotion {
            grantPending = true
        }
    }

    // MARK: practice (screen 3)

    /// Seconds without a key before the guide plays again and the line goes back to the step.
    static let practiceIdle: TimeInterval = 6

    private var practiceContext: PracticeCoach.Context {
        let prefs = app.prefs, app = self.app
        return PracticeCoach.Context(shortcut: { prefs.shortcut(for: $0) }, target: tryPage.target,
                                     voiceOverPaused: app.voiceOverSuspended, result: { app.hotkeyResults[$0] },
                                     runningManagers: runningManagers)
    }

    /// The modifiers held that make a chord (⇧ alone is typing, not a shortcut).
    private var heldChord: NoktaMods { held.intersection([.control, .option, .command]).isEmpty ? [] : held }

    /// The practice line: the held keys while no press has answered them, else the last press's
    /// outcome, else the step (or what stands in its way).
    func refreshPracticeLine() {
        guard tryPage != nil else { return }
        if trusted, !heldChord.isEmpty, !resultSinceHold {
            tryPage.show(.holding(heldChord, tryPage.target))
        } else if trusted, let lastResult {
            tryPage.show(lastResult)
        } else { // access gone: locked, whatever was said before
            tryPage.show(PracticeCoach.idle(trusted: trusted, target: tryPage.target, practiceContext))
        }
    }

    private func startPractice() {
        guard practiceMonitor == nil else { return }
        practiceMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            if let self, event.window === self.window { self.practiceKey(event) }
            return event // only read: every key keeps working
        }
    }

    private func stopPractice() {
        if let practiceMonitor { NSEvent.removeMonitor(practiceMonitor) }
        practiceMonitor = nil
        idleResume?.cancel()
        idleResume = nil
        held = []
        practicePaused = false
        lastResult = nil
        refreshPracticeLine()
    }

    private func practiceKey(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged: practiceFlags(NoktaMods(event.modifierFlags))
        case .keyDown where !event.isARepeat:
            practicePress(Shortcut(keyCode: UInt32(event.keyCode), mods: NoktaMods(event.modifierFlags).rawValue))
        default: break
        }
    }

    private var practising: Bool { currentIndex == 2 && !transitioning && trusted }

    /// Modifiers went down or up.
    private func practiceFlags(_ mods: NoktaMods) {
        guard practising, mods != held else { return }
        let chordBefore = heldChord
        held = mods
        if chordBefore.isEmpty, !heldChord.isEmpty { resultSinceHold = false }
        interacted()
    }

    /// A key press reached this window (so it was no Snapline shortcut that Snapline got).
    private func practicePress(_ pressed: Shortcut) {
        guard practising, let verdict = PracticeCoach.evaluate(pressed, practiceContext) else { return }
        note(verdict)
    }

    /// A press's outcome: on the line until the next one, or the idle timeout; VoiceOver hears it.
    private func note(_ status: PracticeStatus) {
        lastResult = status
        resultSinceHold = true
        interacted()
        OnboardingSpeech.announce(tryPage.spokenLine)
    }

    /// The user pressed something: the guide stops where the window is, the keycaps show the held
    /// modifiers, and the idle clock starts over.
    private func interacted() {
        practicePaused = true
        if guidePlaying {
            stopMotion() // also shows the static pose: the window where it is, the held keys
        } else {
            showHeldKeys()
        }
        refreshPracticeLine()
        idleResume?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.practiceIdleElapsed() }
        idleResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.practiceIdle, execute: work)
    }

    /// The held modifiers on the keycaps. Model values only: a mirror segment that plays keeps
    /// playing and ends on them.
    private func showHeldKeys() {
        guard currentIndex == 2 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        PoseApplier.set(keys.heldPose(heldChord), on: keys.layers)
        CATransaction.commit()
    }

    private func practiceIdleElapsed() {
        idleResume = nil
        guard currentIndex == 2, practicePaused else { return }
        if !heldChord.isEmpty { // still holding keys: wait for them
            interacted()
            return
        }
        practicePaused = false
        lastResult = nil
        refreshPracticeLine()
        if gate.isOpen, !transitioning { playGuide() } else if !playing { showStatic() }
    }

    /// Hotkey registrations changed (another app took or freed one): the line may say so.
    func practiceStateChanged() { refreshPracticeLine() }

    /// Called for every snapped and failed event (via the .noktaDidSnap broadcast). A snap ticks
    /// its chip from any screen. On screen 3 it is a practice step: the line says it worked and
    /// names the next one, and Scene C plays the user's own snap (the keys press only if it came
    /// from the keyboard). A failed shortcut there says why nothing moved; Restore with nothing to
    /// put back still counts — the shortcut reached Snapline.
    func noteSnap(_ event: NoktaEvent) {
        guard let action = event.action, tryPage != nil else { return }
        let onTry = currentIndex == 2 && !transitioning
        let practised = TryPage.tryActions.contains { $0.0 == action }
        if event.kind == .failed {
            guard onTry, practised, event.source == .keyboard else { return }
            if action == .restore, event.result == .invalid {
                _ = tryPage.markTried(.restore)
                tryPage.update(prefs: app.prefs)
                note(.nothingToRestore)
            } else {
                note(.failed(action, event.result))
            }
            return
        }
        guard event.kind == .snapped else { return }
        _ = tryPage.markTried(action)
        tryPage.update(prefs: app.prefs)
        guard tryShown, practised else { return }
        let press = event.source == .keyboard
        let mirror = keys.mirrorTimeline(action, cycle: event.cycle, press: press)
        if onTry { note(.worked(action, keyboard: press, next: tryPage.target)) }
        guard let mirror else { return }
        keys.settled(after: mirror)
        keys.mirroring = true
        lastMirrored = action
        NSAccessibility.post(element: stage, notification: .valueChanged)
        guard onTry else { return }
        if gate.isOpen {
            for l in keys.allLayers { l.removeAllAnimations() }
            play([mirror], on: keys.layers) { [weak self] in self?.showHeldKeys() }
        } else {
            keys.show(mirror.restPose.merging(keys.heldPose(heldChord))) // Reduce Motion or not visible: at once
        }
    }

    #if NOKTA_SNAPSHOT
    /// Offscreen tests: the practice as the key monitor would drive it.
    func testPracticeFlags(_ mods: NoktaMods) { practiceFlags(mods) }
    func testPracticePress(_ s: Shortcut) { practicePress(s) }
    func testPracticeIdle() { idleResume?.cancel(); practiceIdleElapsed() }
    var practiceStatus: PracticeStatus { tryPage.status }
    var practiceLine: String { tryPage.spokenLine }
    var practiceIsPaused: Bool { practicePaused }
    var practiceMonitorInstalled: Bool { practiceMonitor != nil }
    var practiceTarget: NoktaAction? { tryPage.target }
    var heldModifiers: NoktaMods { held }
    var tryScreen: TryPage { tryPage }
    /// What `show()` would start with once on screen 3.
    func testAppear() { pageDidAppear() }
    #endif

    // MARK: actions

    @objc private func primary(_ sender: Any?) {
        guard !transitioning else { return } // a double click must not skip into System Settings
        if let e = NSApp.currentEvent, e.type == .keyDown, e.isARepeat { return } // held Return
        switch currentIndex {
        case 0: go(to: 1, animated: true)
        case 1:
            if trusted { go(to: 2, animated: true) } else { openSystemSettings(sender) }
        default: done()
        }
    }

    @objc private func back(_ sender: Any?) {
        guard currentIndex > 0, !transitioning else { return }
        go(to: currentIndex - 1, animated: true)
    }

    @objc private func later(_ sender: Any?) {
        guard !transitioning else { return }
        window?.performClose(sender)
    }

    /// The user asked for it: prompt once (adds Nokta to the list), then open the pane.
    @objc private func openSystemSettings(_ sender: Any?) {
        if !didPrompt {
            didPrompt = true
            app.requestAccessibilityPrompt()
        }
        app.openAccessibilitySettings()
    }

    @objc private func changeSet(_ sender: NSSegmentedControl) {
        let sets = Preferences.ShortcutSet.allCases
        guard sets.indices.contains(sender.selectedSegment) else { return }
        app.prefs.applyShortcutSet(sets[sender.selectedSegment])
        lastResult = nil // the old set's hint no longer applies
        refreshPracticeLine()
    }

    /// Set when the user flips the login switch (applied on Done).
    private var loginTouched = false

    @objc private func toggleLogin(_ sender: NSSwitch) { loginTouched = true }

    private func done() {
        let wantsLogin = tryPage.loginSwitch.state == .on
        let firstSetup = !app.prefs.onboardingDone
        if (firstSetup || loginTouched) && wantsLogin != app.prefs.launchAtLogin {
            app.prefs.launchAtLogin = wantsLogin
        }
        app.prefs.onboardingDone = true
        window?.close()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopWatchingPermission()
        stopPractice()
        gate.isActive = false
        app.prefs.onboardingSeen = true // the next launch does not open it again unless access is missing
        if tryShown { app.prefs.practiceSeen = true }
        DispatchQueue.main.async { [self] in
            // Same as Settings: drop the content so the scenes' views and layers are freed even if
            // AppKit keeps the closed window object a while (DESIGN §17.9).
            window?.contentView = nil
            app.windowClosed(self)
        }
    }

    func windowDidMiniaturize(_ notification: Notification) { updateTrustTimer() }
    func windowDidDeminiaturize(_ notification: Notification) {
        pageDidAppear()
        updateTrustTimerSoon() // the gate may still count the window as miniaturizing
    }

    // MARK: offscreen renders (tools/snapshot)

    #if NOKTA_SNAPSHOT
    /// Storyboards of DESIGN §11 for `tools/snapshot` (built with `-D NOKTA_SNAPSHOT`; none of
    /// this ships in Nokta.app), which draws them with `pose(at:)`: nothing here adds an animation.
    enum Storyboard { case drag, access, keys, grant, page(from: Int, to: Int) }

    /// Screen 2, for the tool's state checks.
    var accessPage: AccessPage { access }

    private var activeStoryboard: (timeline: Timeline, layers: [LayerID: CALayer], views: [LayerID: NSView], end: () -> Void)?

    /// Re-resolves colours after the caller changed the window's appearance.
    func refreshAppearance() {
        applyPalette()
        showStatic()
    }

    /// Screen `index` (0–2) as it shows when nothing moves.
    func showScreen(_ index: Int) { go(to: index, animated: false) }

    /// Sets up `s` and returns its timeline (`reduceMotion`: the Reduce Motion variant; draw it at
    /// its `explainT`).
    @discardableResult
    func beginStoryboard(_ s: Storyboard, reduceMotion rm: Bool = false) -> Timeline {
        endStoryboard()
        typealias PageID = OnboardingTimelines.PageID
        switch s {
        case .drag:
            go(to: 0, animated: false)
            let t = rm ? Timeline(name: "onb.drag.rm", duration: 0, base: drag.reducedPose(stageOrigin: stage.frame.origin, slot: welcome.slotInSuperview))
                       : dragTimeline()
            activeStoryboard = (t, drag.layers.merging(dragExtras) { $1 }, [:], {})
        case .access:
            go(to: 1, animated: false)
            access.showWaiting()
            activeStoryboard = (AccessScene.waiting, permission.layers, [:], {})
        case .keys:
            go(to: 2, animated: false)
            activeStoryboard = (keys.guideTimeline(tryPage.target ?? .leftHalf)!, keys.layers, [:], {})
        case .grant:
            go(to: 1, animated: false)
            access.showWaiting()
            permission.show(AccessScene.granted.restPose)
            access.prepareGrant()
            activeStoryboard = (grantTimeline(reduceMotion: rm), grantLayers, access.grantViews, {})
        case let .page(from, to):
            go(to: from, animated: false)
            if from == 0 { // leaving screen 1 after Scene A has played
                let rest = dragTimeline().restPose
                drag.show(rest)
                PoseApplier.apply(rest, to: dragExtras)
            }
            let (t, layers) = beginTransition(from: from, to: to, reduceMotion: rm)
            currentIndex = to
            activeStoryboard = (t, layers, [PageID.oldPage: pages[from], PageID.newPage: pages[to]], { [weak self] in
                self?.cleanUpTransition(from: from)
                self?.updateCurrentPage()
                self?.updateButtons()
            })
            updateCurrentPage()
            updateButtons()
        }
        return activeStoryboard!.timeline
    }

    /// Draws the begun storyboard at `t` ms.
    func showStoryboard(at t: Double) {
        guard let s = activeStoryboard else { return }
        let pose = s.timeline.pose(at: t)
        for (id, view) in s.views { view.alphaValue = CGFloat(pose[id, "opacity"]?.scalarValue ?? 1) }
        PoseApplier.apply(pose, to: s.layers)
    }

    /// Leaves the storyboard: its layers at their rest (the model keeps the pose drawn last), then
    /// every page at its own state whether or not that changed, then the screen's static pose.
    func endStoryboard() {
        guard let s = activeStoryboard else { return }
        activeStoryboard = nil
        let rest = s.timeline.restPose
        for (id, view) in s.views { view.alphaValue = CGFloat(rest[id, "opacity"]?.scalarValue ?? 1) }
        PoseApplier.apply(rest, to: s.layers)
        s.end()
        restorePageState()
        showStatic()
    }
    #endif
}

/// Esc anywhere in the window = Later.
final class OnboardingWindow: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
