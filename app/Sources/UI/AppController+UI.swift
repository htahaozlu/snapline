import AppKit
import ServiceManagement

extension Notification.Name {
    /// Posted (object: AppController, userInfo["event"]: NoktaEvent) for every snapped event,
    /// from StatusMenuController.noteSnap — the one UI hook AppController calls on every snap.
    /// Onboarding uses it for the check marks on its shortcut chips and for the key demo's mirror mode.
    static let noktaDidSnap = Notification.Name("NoktaDidSnap")
}

/// Main-thread-only UI state that the AppController extension needs to keep.
private enum ShellUIState {
    static var shortcutSuspensions = 0
    #if NOKTA_SNAPSHOT
    static var systemRequests: [String] = []
    #endif
}

/// UI conveniences on top of AppController. Engine decisions (start, pause, health) stay in
/// AppController.swift; these helpers only route UI intents.
extension AppController {
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let desktopDockSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!

    // MARK: shortcut recording

    /// While a ShortcutRecorder listens, every Nokta hotkey is unbound so the keystroke reaches
    /// the recorder's local monitor instead of Carbon, and no shortcut can act meanwhile (DESIGN §8).
    /// Calls nest; the last `suspendShortcuts(false)` binds the preferences as they are THEN, once
    /// (a shortcut recorded meanwhile is already saved, so the old one is never bound in between),
    /// and refreshes `hotkeyResults` with the outcome. A no-op in a bench mode, where nothing is
    /// ever bound (recording in Settings must not bind real hotkeys).
    func suspendShortcuts(_ suspend: Bool) {
        guard bench == .none else { return }
        if suspend {
            ShellUIState.shortcutSuspensions += 1
            guard ShellUIState.shortcutSuspensions == 1 else { return }
            for action in NoktaAction.allCases { engine.bind(action, to: nil) }
        } else {
            guard ShellUIState.shortcutSuspensions > 0 else { return }
            ShellUIState.shortcutSuspensions -= 1
            guard ShellUIState.shortcutSuspensions == 0 else { return }
            applyPreferencesToEngine()
        }
    }

    var shortcutsSuspended: Bool { ShellUIState.shortcutSuspensions > 0 }

    #if NOKTA_SNAPSHOT
    /// Tests: open suspensions (0 when every recorder has ended).
    var shortcutSuspensionCount: Int { ShellUIState.shortcutSuspensions }
    #endif

    // MARK: menu actions

    /// Applies `action` to the focused window of `target` (the app that was frontmost before
    /// the menu opened). While the target is still frontmost (or unknown) the core acts on its
    /// frontmost app; if focus moved meanwhile the action goes to the target's pid directly, so
    /// the core's frontmost state and AX observer are left alone. A bench mode never moves a
    /// window (SPEC §7): `.notStarted`, the core is not asked.
    @discardableResult
    func perform(_ action: NoktaAction, on target: NSRunningApplication?) -> NoktaResult {
        guard bench == .none else { return .notStarted }
        let front = NSWorkspace.shared.frontmostApplication
        guard let target, !target.isTerminated, target.processIdentifier != front?.processIdentifier else {
            return engine.perform(action)
        }
        return engine.perform(action, pid: target.processIdentifier)
    }

    // MARK: permission

    /// Shows the system Accessibility prompt (adds Nokta to the list). Only from a button.
    @discardableResult
    func requestAccessibilityPrompt() -> Bool {
        // Bench and preview modes never show the system prompt (it would add an entry to the list).
        guard bench == .none else {
            BenchMode.note("blocked accessibility-prompt")
            return isTrusted
        }
        #if NOKTA_SNAPSHOT
        ShellUIState.systemRequests.append("accessibility-prompt")
        return isTrusted
        #else
        return NoktaEngine.isTrusted(prompt: true)
        #endif
    }

    /// Opens Privacy & Security › Accessibility. Only from a button; not in a bench or preview
    /// mode, where the click is reported instead (a preview must not drive System Settings).
    func openAccessibilitySettings() {
        openSystemSettings(Self.accessibilitySettingsURL, name: "accessibility-settings")
    }

    func openDesktopDockSettings() {
        openSystemSettings(Self.desktopDockSettingsURL, name: "desktop-dock-settings")
    }

    /// General › "Open Login Items…".
    func openLoginItemsSettings() {
        guard bench == .none else { BenchMode.note("blocked login-items-settings"); return }
        #if NOKTA_SNAPSHOT
        ShellUIState.systemRequests.append("login-items-settings")
        #else
        SMAppService.openSystemSettingsLoginItems()
        #endif
    }

    private func openSystemSettings(_ url: URL, name: String) {
        guard bench == .none else { BenchMode.note("blocked \(name)"); return }
        #if NOKTA_SNAPSHOT
        ShellUIState.systemRequests.append(name)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    #if NOKTA_SNAPSHOT
    /// Tests: every system request a live app would have made (prompt, System Settings panes). The
    /// offscreen tools never make one; this shows which a button WOULD have made.
    static var systemRequests: [String] {
        get { ShellUIState.systemRequests }
        set { ShellUIState.systemRequests = newValue }
    }
    #endif

    /// Accessibility trust as the UI should show it (one AXIsProcessTrusted call). `--bench-preview`
    /// can show a fixed state instead (the not-yet-allowed permission screen).
    var isTrusted: Bool { (bench.isPreview ? trustOverride : nil) ?? NoktaEngine.isTrusted() }
}
