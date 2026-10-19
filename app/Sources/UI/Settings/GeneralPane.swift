import AppKit
import ServiceManagement

/// Settings › General (DESIGN §8): start-up and menu bar, feedback, the ignore list, Reset All.
final class GeneralPane: SettingsPaneController {
    private var loginSwitch: NSSwitch!
    private var loginApprovalRow: NSGridRow!
    private var iconSwitch: NSSwitch!
    private var iconHelpRow: NSGridRow!
    private var soundSwitch: NSSwitch!
    private var hapticsSwitch: NSSwitch!
    private var labelsControl: NSSegmentedControl!
    private var ignoredApps: IgnoredAppsList!
    private let labelModes: [Preferences.HUDMode] = [.off, .whenNeeded, .always]
    private var keyObserver: NSObjectProtocol?

    /// The login item's state as last read. `SMAppService.status` is an XPC round trip, so it is
    /// read when the tab appears, when the window becomes key again (the user may have approved
    /// Nokta in System Settings) and after the toggle; `refresh()` only shows what was read.
    private var login: SMAppService.Status?

    #if NOKTA_SNAPSHOT
    /// Offscreen tools show every state.
    var loginStatus: () -> SMAppService.Status = { SMAppService.mainApp.status } { didSet { login = nil } }
    #else
    private func loginStatus() -> SMAppService.Status { SMAppService.mainApp.status }
    #endif

    convenience init(app: AppController, prefs: Preferences) { self.init(app: app, prefs: prefs, title: "General") }

    override func makeContent() -> NSView {
        let form = SettingsForm()

        loginSwitch = UIControls.toggle("Open at login", target: self, action: #selector(toggleLogin(_:)))
        form.row("Open at login", control: loginSwitch)
        let openLoginItems = UIControls.button("Open Login Items…", target: self, action: #selector(openLoginItems(_:)))
        let approval = NSStackView(views: [
            UIText.label("Needs approval.", font: Typography.callout, color: .secondaryLabelColor),
            openLoginItems,
        ])
        approval.orientation = .horizontal
        approval.spacing = Theme.Space.s2
        loginApprovalRow = form.wide(approval, padding: Theme.Space.s1)

        iconSwitch = UIControls.toggle("Show in menu bar", target: self, action: #selector(toggleIcon(_:)))
        form.row("Show in menu bar", control: iconSwitch)
        iconHelpRow = form.help("Open \(Product.name) again to return here.").0

        form.group()
        let soundHelp = "A short tick at alert volume."
        soundSwitch = UIControls.toggle("Sound", help: soundHelp, target: self, action: #selector(toggleSound(_:)))
        form.row("Sound", control: soundSwitch, tooltip: soundHelp)
        let hapticsHelp = "Force Touch trackpads only."
        hapticsSwitch = UIControls.toggle("Haptics", help: hapticsHelp, target: self, action: #selector(toggleHaptics(_:)))
        form.row("Haptics", control: hapticsSwitch, tooltip: hapticsHelp)
        labelsControl = UIControls.segmented(["Never", "When needed", "Always"], title: "Snap labels",
                                             target: self, action: #selector(changeLabels(_:)))
        let neededHelp = "Size changes, display moves and problems."
        labelsControl.setToolTip(neededHelp, forSegment: 1)
        labelsControl.setAccessibilityHelp("When needed: \(neededHelp)")
        form.row("Snap labels", control: labelsControl)

        form.group()
        let ignoredHelp = IgnoredAppsList.help
        let ignoredTitle = UIText.label("Ignored apps", font: .systemFont(ofSize: Typography.body.pointSize, weight: .semibold))
        ignoredTitle.toolTip = ignoredHelp
        ignoredTitle.setAccessibilityElement(false) // the list below is labelled "Ignored apps"
        form.wide(ignoredTitle)
        ignoredApps = IgnoredAppsList(prefs: prefs)
        ignoredApps.toolTip = ignoredHelp
        form.wide(ignoredApps, padding: Theme.Space.s2)

        form.separator()
        form.wide(UIControls.button("Reset All Settings…", target: self, action: #selector(resetAll(_:))))
        return form.finish()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rereadLogin()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        // Filtered by identity: `view.window` can still be nil here, and a nil object would observe
        // every window in the app.
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                             object: nil, queue: nil) { [weak self] note in
            guard let self, let window = self.view.window, note.object as? NSWindow === window else { return }
            self.rereadLogin()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    private func rereadLogin() {
        login = loginStatus()
        refresh()
    }

    override func refresh() {
        guard isViewLoaded else { return }
        let status = login ?? loginStatus()
        login = status
        loginSwitch.state = status == .enabled || status == .requiresApproval ? .on : .off
        loginApprovalRow.setHidden(status != .requiresApproval)
        iconSwitch.state = prefs.showIconInMenuBar ? .on : .off
        iconHelpRow.setHidden(prefs.showIconInMenuBar)
        soundSwitch.state = prefs.soundEnabled ? .on : .off
        hapticsSwitch.state = prefs.hapticsEnabled ? .on : .off
        labelsControl.selectedSegment = labelModes.firstIndex(of: prefs.hudMode) ?? 1
        ignoredApps.refresh()
        updatePreferredSize()
    }

    // MARK: actions

    @objc private func toggleLogin(_ sender: NSSwitch) {
        prefs.launchAtLogin = sender.state == .on
        rereadLogin()
    }

    @objc private func openLoginItems(_ sender: Any?) {
        app.openLoginItemsSettings()
    }

    @objc private func toggleIcon(_ sender: NSSwitch) { prefs.showIconInMenuBar = sender.state == .on }
    @objc private func toggleSound(_ sender: NSSwitch) {
        prefs.soundEnabled = sender.state == .on
        if sender.state == .on { app.feedback?.preview() } // DESIGN §6: `ready` once on enable
    }
    @objc private func toggleHaptics(_ sender: NSSwitch) { prefs.hapticsEnabled = sender.state == .on }

    @objc private func changeLabels(_ sender: NSSegmentedControl) {
        guard labelModes.indices.contains(sender.selectedSegment) else { return }
        prefs.hudMode = labelModes[sender.selectedSegment]
    }

    @objc private func resetAll(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Open at login stays as it is."
        let reset = alert.addButton(withTitle: "Reset")
        reset.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.prefs.resetAllSettings()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: apply) } else { apply(alert.runModal()) }
    }
}
