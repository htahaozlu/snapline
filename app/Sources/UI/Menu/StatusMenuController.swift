import AppKit

/// Menu bar status item + menu (DESIGN §7). The icon already shows the state, so the menu names it
/// only when something needs attention. It is rebuilt in `menuNeedsUpdate` (one health check, no
/// measurement, no timer). Snap items act on the app that was frontmost before the menu opened,
/// after the menu has closed.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private unowned let app: AppController
    private var statusItem: NSStatusItem?
    let menu = NSMenu()
    private var iconState: Glyphs.StatusIconState?
    /// Frontmost app captured when the menu was about to open (offscreen tools set it directly).
    var targetApp: NSRunningApplication?
    private var menuIsOpen = false
    private var pendingAction: NoktaAction?
    /// Last `showIconInMenuBar` written to the item; the item is touched only when it changes.
    private var appliedVisibility: Bool?
    private var accessibilityObserver: NSObjectProtocol?

    /// What the status slot says, in priority order (DESIGN §7.2).
    private enum Attention {
        case allowAccessibility, finishSetup, voiceOver, dragUnavailable, stopped
    }

    convenience init(app: AppController) {
        self.init(app: app, installStatusItem: true)
    }

    /// `installStatusItem: false` builds the menu only (offscreen checks; no menu bar item).
    init(app: AppController, installStatusItem: Bool) {
        self.app = app
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        if installStatusItem {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.menu = menu
            if let button = item.button {
                button.imagePosition = .imageOnly
                button.setAccessibilityTitle(Product.name)
                button.setAccessibilityHelp("Opens the \(Product.name) menu")
            }
            statusItem = item
        }
        // Increase Contrast changes the line width baked into the icon images.
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: .noktaAccessibilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.iconState = nil
            self?.refresh()
        }
        refresh()
    }

    deinit {
        if let accessibilityObserver { NotificationCenter.default.removeObserver(accessibilityObserver) }
    }

    // MARK: state

    var state: Glyphs.StatusIconState {
        // Bench modes: the item exists (the launch and memory are measured as shipped) but
        // shortcuts and drag snapping are off, so it must not claim "Active" (and `rebuild`
        // disables every action).
        if app.bench != .none { return .paused }
        if !app.isTrusted || app.engineResult == .notTrusted { return .needsPermission }
        if app.paused || !app.isRunning { return .paused }
        return .active
    }

    /// `--bench-menu`: opens the menu once, as a click would, and closes it after `seconds`. Every
    /// item but Quit is disabled in bench modes, so nothing typed or clicked meanwhile can act.
    func openOnceForBench(closeAfter seconds: TimeInterval) {
        guard app.bench == .menu || app.bench == .session, statusItem?.button != nil else { return }
        // Callers are main-queue blocks. The menu's tracking loop runs inside the click, and while a
        // main-queue block is still running the queue is never drained again — a block-based close
        // would never come and the menu would stay open (seen on macOS 26). So the click and the
        // close are run-loop performs (common modes include the menu's tracking mode).
        perform(#selector(clickForBench), with: nil, afterDelay: 0, inModes: [.common])
        perform(#selector(closeForBench), with: nil, afterDelay: seconds, inModes: [.common])
    }

    @objc private func clickForBench() { statusItem?.button?.performClick(nil) }
    @objc private func closeForBench() { menu.cancelTracking() }

    /// Engine state, permission, preferences or shortcuts changed. The image is replaced only
    /// when the state changed; nothing here animates.
    func refresh() {
        guard let statusItem else { return }
        let visible = app.prefs.showIconInMenuBar
        if visible != appliedVisibility {
            appliedVisibility = visible
            if statusItem.isVisible != visible { statusItem.isVisible = visible }
        }
        let state = self.state
        if state != iconState, let button = statusItem.button {
            iconState = state
            button.image = Glyphs.statusIcon(state)
            button.setAccessibilityValue(Glyphs.spokenValue(state))
        }
    }

    /// Every snapped event. Fans it out to UI that AppController does not call directly
    /// (onboarding check marks).
    func noteSnap(_ event: NoktaEvent) {
        NotificationCenter.default.post(name: .noktaDidSnap, object: app, userInfo: ["event": event])
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        app.checkHealth()
        targetApp = NSWorkspace.shared.frontmostApplication
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        if app.bench != .none { BenchMode.note("menu-open") }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if app.bench != .none { BenchMode.note("menu-close") }
        guard let action = pendingAction else { return }
        pendingAction = nil
        runAfterMenuTracking { [weak self] in self?.perform(action) }
    }

    /// Default run-loop mode only: never while the menu is still tracking.
    private func runAfterMenuTracking(_ block: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.default], block: block)
    }

    // MARK: building

    func rebuild() {
        menu.removeAllItems()
        let needsAccess = !app.isTrusted || app.engineResult == .notTrusted
        // Bench modes (SPEC §7): the menu is built as shipped, but nothing in it may move a
        // window, bind a shortcut, open a window or change a preference. Only Quit stays enabled;
        // the status slot (it describes the harness's instance, not Nokta's state) is left out.
        let live = app.bench == .none
        let usable = live && !needsAccess && app.isRunning && !app.paused

        if live, let attention = attention(needsAccess: needsAccess) {
            menu.addItem(attentionItem(attention))
            menu.addItem(.separator())
        }

        for action in [NoktaAction.leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize, .almostMaximize, .center, .restore] {
            menu.addItem(actionItem(action, title: action.title, enabled: usable))
        }
        menu.addItem(submenu("Quarters", [
            (.topLeft, "Top Left"), (.topRight, "Top Right"), (.bottomLeft, "Bottom Left"), (.bottomRight, "Bottom Right"),
        ], enabled: usable))
        menu.addItem(submenu("Thirds", [
            (.firstThird, "First"), (.centerThird, "Middle"), (.lastThird, "Last"),
            (.firstTwoThirds, "First Two"), (.centerTwoThirds, "Middle Two"), (.lastTwoThirds, "Last Two"),
        ], enabled: usable))
        menu.addItem(submenu("Display", [(.nextDisplay, "Next"), (.prevDisplay, "Previous")], enabled: usable))

        menu.addItem(.separator())
        let pause = makeItem(app.paused ? "Resume" : "Pause", #selector(togglePause(_:)))
        pause.isEnabled = live && (!needsAccess || app.paused)
        menu.addItem(pause)
        if let ignore = ignoreItem() {
            ignore.isEnabled = ignore.isEnabled && live
            menu.addItem(ignore)
        }

        menu.addItem(.separator())
        let settingsItem = makeItem("Settings…", #selector(openSettings(_:)), key: ",")
        // Bench modes open no windows (SPEC §7): Settings could change the user's real preferences.
        settingsItem.isEnabled = live
        menu.addItem(settingsItem)
        let quit = makeItem("Quit \(Product.name)", #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private var classicShortcutsInUse: Bool {
        NoktaAction.allCases.contains { app.prefs.shortcut(for: $0)?.modifiers.isSuperset(of: [.control, .option]) == true }
    }

    /// The one thing worth interrupting the menu for, or nil when everything is fine.
    private func attention(needsAccess: Bool) -> Attention? {
        if needsAccess { return .allowAccessibility }
        if !app.prefs.onboardingDone { return .finishSetup }
        if app.voiceOverSuspended && classicShortcutsInUse { return .voiceOver }
        if app.engineResult == .eventTap { return .dragUnavailable }
        if !app.isRunning && !app.paused { return .stopped }
        return nil
    }

    private func attentionItem(_ attention: Attention) -> NSMenuItem {
        switch attention {
        case .allowAccessibility:
            let item = makeItem("Allow Accessibility…", #selector(allowAccess(_:)))
            item.image = Self.attentionDot()
            return item
        case .finishSetup:
            return makeItem("Finish Setup…", #selector(finishSetup(_:)))
        case .voiceOver:
            return makeItem("Shortcuts paused for VoiceOver…", #selector(openShortcuts(_:)))
        case .dragUnavailable:
            let item = makeItem("Drag snapping unavailable", #selector(openAbout(_:)))
            item.toolTip = NoktaResult.eventTap.message
            return item
        case .stopped:
            return makeItem("\(Product.name) stopped…", #selector(openAbout(_:)))
        }
    }

    /// A plain item that calls back into this controller. Every row carries an image (blank when
    /// it has no glyph), so titles share one column.
    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = Self.glyphSpacer
        return item
    }

    private func actionItem(_ action: NoktaAction, title: String, enabled: Bool) -> NSMenuItem {
        let item = makeItem(title, #selector(performAction(_:)))
        item.tag = Int(action.rawValue)
        item.image = FrameGlyphs.action(action) ?? Self.glyphSpacer
        item.isEnabled = enabled
        // Display only: the real registration is Carbon (DESIGN §7). Unassigned → no glyph.
        if let s = app.prefs.shortcut(for: action) {
            let (key, mods) = s.menuKeyEquivalent
            // The character already comes from the current layout (KeyNames): AppKit must not
            // re-map it as if it were a US key, or the menu would name a different key than Settings.
            item.allowsAutomaticKeyEquivalentLocalization = false
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
        }
        return item
    }

    private func submenu(_ title: String, _ actions: [(NoktaAction, String)], enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = Self.glyphSpacer
        item.isEnabled = enabled
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        for (action, name) in actions { sub.addItem(actionItem(action, title: name, enabled: enabled)) }
        item.submenu = sub
        return item
    }

    private func ignoreItem() -> NSMenuItem? {
        guard let target = targetApp, let id = target.bundleIdentifier,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let name = target.localizedName ?? id
        let ignored = app.prefs.isExcluded(id)
        if !ignored && !app.prefs.canAddExcluded {
            // 64-rule cap (core limit): say so instead of an item that does nothing.
            let full = NSMenuItem(title: "Ignore list full", action: nil, keyEquivalent: "")
            full.image = Self.glyphSpacer
            full.isEnabled = false
            return full
        }
        let item = makeItem(ignored ? "Stop Ignoring “\(name)”" : "Ignore “\(name)”", #selector(toggleIgnore(_:)))
        item.representedObject = id
        return item
    }

    /// Blank 16 × 12 template: keeps titles in the glyph rows' column.
    private static let glyphSpacer: NSImage = {
        let image = NSImage(size: FrameGlyphs.size)
        image.isTemplate = true
        return image
    }()

    /// R3: the Ø 8 red dot of `Allow Accessibility…`, centred in the glyph column. The menu's only
    /// red; the title beside it carries the meaning.
    private static func attentionDot() -> NSImage {
        let image = NSImage(size: FrameGlyphs.size, flipped: false) { rect in
            Theme.Color.red.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8)).fill()
            return true
        }
        image.accessibilityDescription = "Needs attention"
        return image
    }

    // MARK: actions

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let action = NoktaAction(rawValue: UInt32(sender.tag)) else { return }
        if menuIsOpen {
            pendingAction = action // run in menuDidClose, once tracking ends
        } else {
            runAfterMenuTracking { [weak self] in self?.perform(action) }
        }
    }

    private func perform(_ action: NoktaAction) {
        app.perform(action, on: targetApp)
        targetApp = nil
    }

    @objc private func allowAccess(_ sender: Any?) {
        OnboardingWindowController.opensAtPermission = true
        app.showOnboarding()
    }
    @objc private func openAbout(_ sender: Any?) { app.showSettings(tab: .about) }
    @objc private func openShortcuts(_ sender: Any?) { app.showSettings(tab: .shortcuts) }
    @objc private func openSettings(_ sender: Any?) { app.showSettings() }
    @objc private func finishSetup(_ sender: Any?) { app.showOnboarding() }
    @objc private func togglePause(_ sender: Any?) { app.setPaused(!app.paused) }

    @objc private func toggleIgnore(_ sender: NSMenuItem) {
        guard app.bench == .none, let id = sender.representedObject as? String else { return }
        app.prefs.setExcluded(!app.prefs.isExcluded(id), bundleID: id)
    }
}
