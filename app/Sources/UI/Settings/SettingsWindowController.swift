import AppKit

/// Settings window (DESIGN §8): NSWindow + NSTabViewController(.toolbar), 560 pt wide, height
/// per tab. Tabs load lazily (NSTabViewController loads a child view on first selection); the
/// controller is released by AppController when the window closes.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: String, CaseIterable {
        case general, shortcuts, dragging, about

        var title: String {
            switch self {
            case .general: return "General"
            case .shortcuts: return "Shortcuts"
            case .dragging: return "Dragging"
            case .about: return "About"
            }
        }

        /// DESIGN §8 symbols, with a system fallback when a symbol is missing.
        var image: NSImage? {
            let names: [String]
            switch self {
            case .general: names = ["gearshape"]
            case .shortcuts: names = ["keyboard"]
            case .dragging: names = ["macwindow.on.rectangle", "rectangle.split.2x1"]
            case .about: names = ["info.circle"]
            }
            for name in names {
                if let image = NSImage(systemSymbolName: name, accessibilityDescription: title) { return image }
            }
            return NSImage(named: NSImage.preferencesGeneralName)
        }
    }

    private unowned let app: AppController
    private let prefs: Preferences
    private let tabs = SettingsTabViewController()
    private var panes: [Tab: SettingsPaneController] = [:]
    private var accessibilityObserver: NSObjectProtocol?

    /// `prefs`: the app's own unless an offscreen tool hands in a scratch instance.
    init(app: AppController, prefs: Preferences? = nil) {
        self.app = app
        self.prefs = prefs ?? app.prefs
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsForm.windowWidth, height: 400),
                                    styleMask: [.titled, .closable, .miniaturizable],
                                    backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        super.init(window: window)
        window.delegate = self

        tabs.tabStyle = .toolbar
        tabs.transitionOptions = Theme.Motion.reduceMotion ? [] : [.crossfade, .allowUserInteraction]
        for tab in Tab.allCases {
            let pane = Self.makePane(tab, app: app, prefs: self.prefs)
            panes[tab] = pane
            let item = NSTabViewItem(viewController: pane)
            item.label = tab.title
            item.image = tab.image
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        window.onKeyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        window.contentViewController = tabs
        // Custom-drawn controls read Increase Contrast in draw(_:); redraw them when it changes.
        // Tab changes cross-fade unless Reduce Motion is on.
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: .noktaAccessibilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tabs.transitionOptions = Theme.Motion.reduceMotion ? [] : [.crossfade, .allowUserInteraction]
            guard let root = self?.window?.contentView else { return }
            Self.redraw(root)
        }
    }

    deinit {
        if let accessibilityObserver { NotificationCenter.default.removeObserver(accessibilityObserver) }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }

    required init?(coder: NSCoder) { nil }

    static func makePane(_ tab: Tab, app: AppController, prefs: Preferences) -> SettingsPaneController {
        switch tab {
        case .general: return GeneralPane(app: app, prefs: prefs)
        case .shortcuts: return ShortcutsPane(app: app, prefs: prefs)
        case .dragging: return DraggingPane(app: app, prefs: prefs)
        case .about: return AboutPane(app: app, prefs: prefs)
        }
    }

    /// Shows the window on `tab`; a window that was closed opens on General. `activate: false`
    /// (`--bench-session` only) orders it in without making it key, so nobody's focus moves.
    func show(tab: Tab?, activate: Bool = true) {
        guard let window else { return }
        if let target = tab ?? (window.isVisible ? nil : .general), let index = Tab.allCases.firstIndex(of: target) {
            tabs.selectedTabViewItemIndex = index
        }
        if !window.isVisible {
            tabs.fitWindow(animate: false)
            window.center()
        }
        guard activate else { window.orderFrontRegardless(); return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    #if NOKTA_SNAPSHOT
    /// Tests: selects (and loads) a tab without showing the window.
    func select(tab: Tab) {
        guard let index = Tab.allCases.firstIndex(of: tab) else { return }
        tabs.transitionOptions = []
        tabs.selectedTabViewItemIndex = index
    }

    func pane(_ tab: Tab) -> SettingsPaneController? { panes[tab] }
    #endif

    private var refreshPending = false

    /// Preferences or hotkey results changed: every loaded tab re-reads its state. Coalesced to one
    /// pass per run-loop turn — re-binding all shortcuts reports one hotkey result each.
    func refresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            for pane in self.panes.values where pane.isViewLoaded { pane.refresh() }
        }
    }

    func noteSnap(_ event: NoktaEvent) {
        for pane in panes.values where pane.isViewLoaded { pane.noteSnap(event) }
    }

    /// ⌘1…⌘4 select tabs (DESIGN §8). ⌘W and ⌘, come from the main/status menus.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let chars = event.charactersIgnoringModifiers,
              let digit = Int(chars), (1...Tab.allCases.count).contains(digit) else { return false }
        tabs.selectedTabViewItemIndex = digit - 1
        return true
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // End any recording first so global shortcuts are bound again.
        window?.makeFirstResponder(nil)
        // Next run-loop turn (DESIGN §10: policy switch after the window is gone); the block keeps
        // this controller alive until AppController drops it.
        DispatchQueue.main.async { [self] in
            // AppKit keeps the closed window alive (KVO and toolbar bookkeeping of the toolbar-style
            // tab view), and with it every pane and view (≈ 4 MB of the ≈ 35–48 MB that stays after closing Settings; the rest is AppKit).
            // Detach them so they are freed with this controller (DESIGN §17.9).
            window?.toolbar = nil
            window?.contentViewController = nil
            app.windowClosed(self)
        }
    }
}

/// Window with a key-equivalent hook (tab shortcuts) that runs before the views see the event.
final class SettingsWindow: NSWindow {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Resizes the window to the selected tab's preferred size, keeping the top edge in place and
/// never growing past the screen (the tab then scrolls).
final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animate: true)
        if let title = tabViewItem?.label { view.window?.title = title }
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if viewController === tabViewItems[safe: selectedTabViewItemIndex]?.viewController {
            fitWindow(animate: true)
        }
    }

    func fitWindow(animate: Bool) {
        guard let window = view.window,
              let pane = tabViewItems[safe: selectedTabViewItemIndex]?.viewController else { return }
        _ = pane.view // load
        var size = pane.preferredContentSize
        guard size.height > 0 else { return }
        var target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        if let screen = window.screen ?? NSScreen.main, target.height > screen.visibleFrame.height {
            let chrome = target.height - size.height
            size.height = screen.visibleFrame.height - chrome
            target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        }
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animate && window.isVisible && !Theme.Motion.reduceMotion)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
