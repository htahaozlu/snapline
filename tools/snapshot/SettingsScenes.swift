import AppKit
import NoktaCore

// Settings scenes — owned by the Settings surface; called from main.swift. Offscreen only: never order a
// window in, never activate the app (see main.swift).

// ScratchDefaults (in-memory defaults) lives in ScratchDefaults.swift, shared by every scene.

private func firstSubview<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
    if let match = view as? V { return match }
    for sub in view.subviews { if let match = firstSubview(type, in: sub) { return match } }
    return nil
}

/// Fresh preferences in a scratch store, then `setup`.
private func scratchPreferences(_ setup: (Preferences) -> Void = { _ in }) -> Preferences {
    let prefs = Preferences(defaults: ScratchDefaults(suiteName: "nokta.snapshot.scratch")!)
    setup(prefs)
    return prefs
}

/// Fixed numbers for About (what a quiet Nokta would read).
private func measuredReading(footprint: UInt64? = 12_373_196, snaps: UInt64 = 37, trusted: Bool = true,
                             sockets: Int? = 0, threads: Int? = 3) -> AboutPane.Reading {
    var stats = nk_stats()
    stats.snaps = snaps
    stats.last_latency_ns = 600_000
    stats.p50_latency_ns = 500_000
    stats.p95_latency_ns = 1_300_000
    let sample = IntegrityProbe.Sample(footprint: footprint, resident: footprint.map { $0 + 6_000_000 }, ipSockets: sockets,
                                       threads: threads, cpuSeconds: 0.41, uptime: 3_600)
    return AboutPane.Reading(sample: sample, stats: stats, trusted: trusted)
}

/// Controls smaller than 24 × 24 pt (DESIGN §15), found by walking a laid-out pane. A control counts
/// when it is on screen (not hidden, not a label) and clickable.
private var smallTargets: [String] = []

private func auditTargets(in root: NSView, scene: String) {
    func visit(_ view: NSView) {
        let isControl = (view as? NSControl).map { !($0 is NSTextField || $0 is NSImageView || $0 is NSScroller) && $0.isEnabled } ?? false
        // A label that takes clicks counts too (an image view's own recognizers do not).
        let clickable = isControl || (!(view is NSImageView) && !view.gestureRecognizers.isEmpty)
        if clickable, !view.isHiddenOrHasHiddenAncestor {
            let size = view.bounds.size
            if size.width < 24 || size.height < 24 {
                let title = (view as? NSButton).map { $0.title.isEmpty ? $0.accessibilityLabel() ?? "" : $0.title }
                    ?? (view as? NSTextField)?.stringValue ?? ""
                let line = "\(type(of: view)) \"\(title)\" \(size.width) × \(size.height) in \(scene)"
                if !smallTargets.contains(line) { smallTargets.append(line) }
            }
        }
        view.subviews.forEach(visit)
    }
    visit(root)
}

private func textFields(in view: NSView) -> [NSTextField] {
    var fields = (view as? NSTextField).map { [$0] } ?? []
    for sub in view.subviews { fields += textFields(in: sub) }
    return fields
}

/// Behaviour that needs no pixels. A failure stops the run, like the motion self-test.
///   FV2-10 / OV2-13  General reads the login item on appear, on key and after the toggle only
///   OV2-7            the top handle's touch area covers its 112 pt bar (every handle ≥ 24 pt)
///   OV2-14           the memory line judges "over" on the printed value; its maximum covers its value
private func checkSettingsBehaviour() {
    var failures: [String] = []
    var count = 0
    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        count += 1
        if !ok { failures.append(what()) }
    }
    func pane<P: SettingsPaneController>(_ type: P.Type, _ tab: SettingsWindowController.Tab) -> (P, NSWindow)? {
        let settings = SettingsWindowController(app: controller, prefs: scratchPreferences())
        guard let window = settings.window, let tabs = window.contentViewController as? NSTabViewController,
              let index = SettingsWindowController.Tab.allCases.firstIndex(of: tab),
              let pane = tabs.tabViewItems[index].viewController as? P else { return nil }
        tabs.transitionOptions = []
        tabs.selectedTabViewItemIndex = index
        _ = pane.view
        retainedSettings.append(settings)
        return (pane, window)
    }

    // FV2-10 / OV2-13: ServiceManagement is read when the tab appears, when the window becomes key
    // again and after the toggle — not on every refresh.
    if let (general, window) = pane(GeneralPane.self, .general) {
        var reads = 0
        general.loginStatus = { reads += 1; return .enabled }
        for _ in 0..<5 { general.refresh() }
        expect(reads == 1, "General read the login item \(reads) times in 5 refreshes (expected 1)")
        general.viewWillAppear()
        expect(reads == 2, "viewWillAppear did not re-read the login item (\(reads) reads)")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        expect(reads == 3, "the window becoming key did not re-read the login item (\(reads) reads)")
        general.refresh()
        expect(reads == 3, "refresh() re-read the login item (\(reads) reads)")
        general.viewDidDisappear()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        expect(reads == 3, "a hidden General tab still re-reads the login item (\(reads) reads)")
        // OV2-13: the list's explanation reaches VoiceOver.
        let table = firstSubview(NSTableView.self, in: general.view)
        expect(table?.accessibilityHelp() == IgnoredAppsList.help, "the ignored apps list has no accessibility help")
    } else {
        expect(false, "General pane not found")
    }

    // OV2-7: every handle's touch area is a real target and the top one covers its bar.
    let top = ZoneMap.hitRect(for: .top)
    expect(top.width >= 112 && top.height >= 32, "top handle touch area is \(top.width) × \(top.height), needs ≥ 112 × 32")
    for zone in NoktaZone.allCases {
        let r = ZoneMap.hitRect(for: zone)
        expect(r.width >= 24 && r.height >= 24, "\(zone) touch area is \(r.width) × \(r.height)")
    }

    // OV2-14: 12.02 MiB prints as 12.0 MB and is not over the 12 MB target; 12.11 prints 12.1 and is.
    let meter = LineMeter()
    meter.value = 12_600_000
    expect(Measure.megabytes(12_600_000) == "12.0 MB" && !meter.isOverBudget
           && meter.accessibilityValueDescription()?.contains("over") == false,
           "12.0 MB must not be over the target (\(meter.accessibilityValueDescription() ?? "nil"))")
    meter.value = 12_700_000
    expect(Measure.megabytes(12_700_000) == "12.1 MB" && meter.isOverBudget
           && meter.accessibilityValueDescription()?.contains("over the target") == true,
           "12.1 MB must be over the target (\(meter.accessibilityValueDescription() ?? "nil"))")
    let samples: [UInt64] = [0, 12 * 1_048_576, 16 * 1_048_576, 20 * 1_048_576]
    for bytes in samples {
        meter.value = bytes
        let value = (meter.accessibilityValue() as? NSNumber)?.doubleValue ?? -1
        let maximum = (meter.accessibilityMaxValue() as? NSNumber)?.doubleValue ?? -1
        expect(maximum >= value, "memory line maximum \(maximum) is below its value \(value)")
    }
    expect(meter.accessibilityValueDescription()?.contains("of 12 megabyte target") == true, "meter value does not name the target")

    // OV2-14: an unreadable thread count reads "— threads".
    if let (about, _) = pane(AboutPane.self, .about) {
        about.reading = { measuredReading(footprint: nil, sockets: nil, threads: nil) }
        about.refresh()
        about.viewWillAppear()
        about.view.layoutSubtreeIfNeeded()
        let fields = textFields(in: about.view)
        let text = fields.map(\.stringValue)
        let unreadable = fields.filter { $0.stringValue == "Unreadable" }
        func needed(_ field: NSTextField) -> CGFloat { field.cell?.cellSize.width ?? .infinity }
        expect(unreadable.count == 2 && unreadable.allSatisfy { $0.bounds.width + 0.5 >= needed($0) },
               "\"Unreadable\" is cut off: \(unreadable.map { "\($0.bounds.width) of \(needed($0))" })")
        expect(text.contains("CPU 0.41 s · — threads"), "unreadable thread count text: \(text.filter { $0.hasPrefix("CPU") })")
        expect(!text.contains { $0.contains("threads Unreadable") }, "\"threads Unreadable\" is back")
    } else {
        expect(false, "About pane not found")
    }

    if failures.isEmpty {
        print("settings checks: OK (\(count) checks)")
    } else {
        print("settings checks FAILED:\n  " + failures.joined(separator: "\n  "))
        exit(1)
    }
}

/// Keeps the window controllers of the checks alive (panes hold their app/window unowned).
private var retainedSettings: [SettingsWindowController] = []

/// A MacBook-sized main display, so renders do not depend on the Mac that makes them.
private let displayUsable = CGRect(x: 0, y: 38, width: 1512, height: 944)

/// One Settings tab in both appearances: settings-<name>-<light|dark>.png. `configure` runs after
/// the pane has loaded (state the pane reads from closures or exposes), then the pane refreshes.
private func renderSettingsTab(_ tab: SettingsWindowController.Tab, name: String, prefs: Preferences = scratchPreferences(),
                               configure: (SettingsPaneController) -> Void = { _ in }) {
    let settings = SettingsWindowController(app: controller, prefs: prefs)
    guard let window = settings.window, let tabs = window.contentViewController as? NSTabViewController,
          let index = SettingsWindowController.Tab.allCases.firstIndex(of: tab),
          let pane = tabs.tabViewItems[index].viewController as? SettingsPaneController else { return }
    tabs.transitionOptions = [] // offscreen: switch synchronously
    tabs.selectedTabViewItemIndex = index
    let view = pane.view
    (pane as? DraggingPane)?.usableOverride = displayUsable
    configure(pane)
    pane.refresh()
    let size = pane.preferredContentSize.height > 0 ? pane.preferredContentSize : view.fittingSize
    view.setFrameSize(NSSize(width: SettingsForm.windowWidth, height: max(size.height, 200)))
    for (mode, appearance) in appearances {
        window.appearance = appearance
        view.layoutSubtreeIfNeeded()
        write(render(view, appearance: appearance), "settings-\(name)-\(mode)")
    }
    auditTargets(in: view, scene: name)
}

/// Every Settings tab in both appearances, plus the states DESIGN §8 describes:
///   about with Details open · dragging with a corner handle selected and with Alternate key = None ·
///   general with two ignored apps.
/// Extra renders for review: conditional rows and the over-target memory line.
func snapshotSettings() {
    checkSettingsBehaviour()

    // The four tabs.
    renderSettingsTab(.general, name: "general")
    renderSettingsTab(.shortcuts, name: "shortcuts")
    renderSettingsTab(.dragging, name: "dragging") { pane in
        (pane as? DraggingPane)?.systemState = { (.off, false, .off) }
    }
    renderSettingsTab(.about, name: "about") { pane in
        (pane as? AboutPane)?.reading = { measuredReading() }
    }

    // About: Details open; memory over the 12 MB target.
    renderSettingsTab(.about, name: "about-details") { pane in
        guard let about = pane as? AboutPane else { return }
        about.reading = { measuredReading() }
        about.showsDetails = true
    }
    renderSettingsTab(.about, name: "about-over") { pane in
        (pane as? AboutPane)?.reading = { measuredReading(footprint: 14_680_064, snaps: 0) }
    }
    // 12.02 MiB prints as 12.0 MB: not over the target, no red, no "over" text.
    renderSettingsTab(.about, name: "about-edge") { pane in
        (pane as? AboutPane)?.reading = { measuredReading(footprint: 12_600_000) }
    }
    // Nothing readable: Unreadable, and "— threads" instead of a broken phrase.
    renderSettingsTab(.about, name: "about-unreadable") { pane in
        guard let about = pane as? AboutPane else { return }
        about.reading = { measuredReading(footprint: nil, sockets: nil, threads: nil) }
        about.showsDetails = true
    }
    renderSettingsTab(.about, name: "about-denied") { pane in
        guard let about = pane as? AboutPane else { return }
        about.reading = { measuredReading(trusted: false) }
        about.showsDetails = true
    }

    // Dragging: a corner handle selected; Alternate key = None.
    renderSettingsTab(.dragging, name: "dragging-corner") { pane in
        guard let dragging = pane as? DraggingPane else { return }
        dragging.systemState = { (.off, false, .off) }
        dragging.select(zone: .bottomLeft)
    }
    renderSettingsTab(.dragging, name: "dragging-noalt", prefs: scratchPreferences { $0.thirdsModifier = [] }) { pane in
        guard let dragging = pane as? DraggingPane else { return }
        dragging.systemState = { (.off, false, .off) }
        dragging.select(zone: .top)
    }
    renderSettingsTab(.dragging, name: "dragging-card", prefs: scratchPreferences { $0.thirdsModifier = .option }) { pane in
        guard let dragging = pane as? DraggingPane else { return }
        dragging.systemState = { (.on, true, .on) }
        dragging.select(zone: .bottomCenterSegment)
    }
    // ⌥ is the alternate key and macOS's ⌥ tiling is unknown: the cautious "may" note.
    renderSettingsTab(.dragging, name: "dragging-optunknown", prefs: scratchPreferences { $0.thirdsModifier = .option }) { pane in
        guard let dragging = pane as? DraggingPane else { return }
        dragging.systemState = { (.unknown, false, .unknown) }
        dragging.select(zone: .bottomLeftSegment)
    }
    renderSettingsTab(.dragging, name: "dragging-none", prefs: scratchPreferences {
        $0.setZoneAction(nil, for: .right, alternate: false)
        $0.setZoneAction(nil, for: .bottomCenterSegment, alternate: false)
    }) { pane in
        guard let dragging = pane as? DraggingPane else { return }
        dragging.systemState = { (.off, false, .off) }
        dragging.select(zone: .right)
    }
    renderSettingsTab(.dragging, name: "dragging-off", prefs: scratchPreferences { $0.dragSnap = false }) { pane in
        (pane as? DraggingPane)?.systemState = { (.off, false, .off) }
    }

    // Dragging: the result frame is the core's (nk_layout_frame) — gaps and margin applied, Almost
    // Maximize at its size, Center as a dashed stand-in, thirds as rows on a portrait display.
    renderSettingsTab(.dragging, name: "dragging-gap", prefs: scratchPreferences { $0.gapInner = 24; $0.gapOuter = 24 }) { pane in
        guard let dragging = pane as? DraggingPane else { return }
        dragging.systemState = { (.off, false, .off) }
        dragging.select(zone: .top)
    }
    renderSettingsTab(.dragging, name: "dragging-almost", prefs: scratchPreferences {
        $0.almostMaximize = 0.8
        $0.setZoneAction(.almostMaximize, for: .top, alternate: false)
    }) { pane in
        guard let dragging = pane as? DraggingPane else { return }
        dragging.systemState = { (.off, false, .off) }
        dragging.select(zone: .top)
    }
    renderSettingsTab(.dragging, name: "dragging-center", prefs: scratchPreferences {
        $0.setZoneAction(.center, for: .right, alternate: false)
    }) { pane in
        guard let dragging = pane as? DraggingPane else { return }
        dragging.systemState = { (.off, false, .off) }
        dragging.select(zone: .right)
    }
    renderSettingsTab(.dragging, name: "dragging-portrait") { pane in
        guard let dragging = pane as? DraggingPane else { return }
        dragging.systemState = { (.off, false, .off) }
        dragging.usableOverride = CGRect(x: 0, y: 38, width: 1080, height: 1882)
        dragging.select(zone: .bottomLeftSegment)
    }

    // General: two ignored apps; login item awaiting approval and the menu bar icon hidden.
    renderSettingsTab(.general, name: "general-apps",
                      prefs: scratchPreferences { $0.excludedBundleIDs = ["com.apple.Safari", "com.apple.finder"] })
    renderSettingsTab(.general, name: "general-states", prefs: scratchPreferences { $0.showIconInMenuBar = false }) { pane in
        (pane as? GeneralPane)?.loginStatus = { .requiresApproval }
    }

    // Increase Contrast (the tokens' IC variants and the custom views' IC strokes).
    let normal = AccessibilityEnv.shared.override
    AccessibilityEnv.shared.override = AccessibilityEnv.Snapshot(increaseContrast: true)
    renderSettingsTab(.dragging, name: "dragging-ic") { pane in
        guard let dragging = pane as? DraggingPane else { return }
        dragging.systemState = { (.off, false, .off) }
        dragging.select(zone: .topRight)
    }
    renderSettingsTab(.about, name: "about-ic") { pane in
        (pane as? AboutPane)?.reading = { measuredReading(footprint: 14_680_064) }
    }
    renderSettingsTab(.general, name: "general-ic", prefs: scratchPreferences { $0.excludedBundleIDs = ["com.apple.Safari"] })
    AccessibilityEnv.shared.override = normal

    // Shortcuts: the recorder notes under a row (conflict, validation, option-only warning).
    let reduced = AccessibilityEnv.shared.override
    AccessibilityEnv.shared.override = AccessibilityEnv.Snapshot(reduceMotion: true) // row heights change at once
    renderSettingsTab(.shortcuts, name: "shortcuts-notes", prefs: scratchPreferences {
        $0.setShortcut(Shortcut(keyCode: 0x00, mods: NoktaMods.option.rawValue), for: .topHalf)
    }) { pane in
        guard let shortcuts = pane as? ShortcutsPane, let table = firstSubview(ShortcutTableView.self, in: shortcuts.view) else { return }
        shortcuts.view.layoutSubtreeIfNeeded()
        func cell(_ row: Int) -> ShortcutCellView? { table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ShortcutCellView }
        cell(1)?.recorder.onCommit?(shortcuts.prefs.shortcut(for: .rightHalf)) // Left Half ← Right Half's keys
        cell(4)?.recorder.onMessage?("Add ⌃, ⌥ or ⌘.")                       // Bottom Half
    }
    AccessibilityEnv.shared.override = reduced

    // Shortcuts: VoiceOver on (the "Keep ⌃⌥ with VoiceOver" row, with its paused note).
    renderSettingsTab(.shortcuts, name: "shortcuts-voiceover") { pane in
        (pane as? ShortcutsPane)?.voiceOverEnabled = { true }
    }

    // DESIGN §15: no clickable control below 24 × 24 pt (FV2-6).
    if smallTargets.isEmpty {
        print("hit targets: every Settings control is at least 24 × 24 pt")
    } else {
        print("hit targets below 24 × 24 pt:\n  " + smallTargets.joined(separator: "\n  "))
        exit(1)
    }
}
