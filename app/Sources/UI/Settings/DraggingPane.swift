import AppKit

/// Read-only detection of macOS's own window tiling and Stage Manager (DESIGN §8). Nokta never
/// writes Apple's settings.
enum SystemWindowing {
    enum State { case on, off, unknown }

    private static var domain: UserDefaults? { UserDefaults(suiteName: "com.apple.WindowManager") }

    /// Edge-drag tiling (macOS 15+). Missing keys on macOS 15+ = Apple's default (on), but
    /// unconfirmed → `.unknown`.
    static var tiling: State {
        guard #available(macOS 15, *) else { return .off }
        guard let d = domain else { return .unknown }
        let keys = ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag"]
        let values = keys.compactMap { d.object(forKey: $0) as? Bool }
        if values.isEmpty { return .unknown }
        return values.contains(true) ? .on : .off
    }

    /// "Hold ⌥ while dragging to tile" (macOS 15+).
    static var optionAccelerator: State {
        guard #available(macOS 15, *) else { return .off }
        guard let value = domain?.object(forKey: "EnableTilingOptionAccelerator") as? Bool else { return .unknown }
        return value ? .on : .off
    }

    static var stageManager: Bool {
        domain?.bool(forKey: "GloballyEnabled") ?? false
    }
}

/// Settings › Dragging (DESIGN §8).
final class DraggingPane: SettingsPaneController {
    private var dragSwitch: NSSwitch!
    private var zoneMap: ZoneMap!
    private var primaryRow: NSGridRow!
    private var primaryPopup: NSPopUpButton!
    private var alternateRow: NSGridRow!
    private var alternatePopup: NSPopUpButton!
    private var modifierControl: NSSegmentedControl!
    private var modifierHelpRow: NSGridRow!
    private var modifierHelp: NSTextField!
    private var sensitivityControl: NSSegmentedControl!
    private var snapBackSwitch: NSSwitch!
    private var sharedEdgesSwitch: NSSwitch!
    private var gapSlider: NSSlider!
    private var gapValue: NSTextField!
    private var marginSlider: NSSlider!
    private var marginValue: NSTextField!
    private var cardRow: NSGridRow!
    private var card: SystemWindowingCard!
    private var dragDependent: [NSControl] = []
    private var screenObserver: NSObjectProtocol?

    private let modifiers: [(NoktaMods, String, String)] = [
        ([], "None", "No alternate map"),
        (.shift, "⇧", "Shift"),
        (.control, "⌃", "Control"),
        (.option, "⌥", "Option"),
        (.command, "⌘", "Command"),
    ]
    private let sensitivities = Preferences.EdgeSensitivity.allCases

    /// macOS edge tiling, Stage Manager and the ⌥ accelerator as read from Apple's preferences
    /// (read only).
    typealias SystemState = (tiling: SystemWindowing.State, stageManager: Bool, optionAccelerator: SystemWindowing.State)

    #if NOKTA_SNAPSHOT
    /// Offscreen tools show every card state, and the same display on every machine.
    var systemState: () -> SystemState = {
        (SystemWindowing.tiling, SystemWindowing.stageManager, SystemWindowing.optionAccelerator)
    }
    var usableOverride: CGRect?
    #else
    private func systemState() -> SystemState {
        (SystemWindowing.tiling, SystemWindowing.stageManager, SystemWindowing.optionAccelerator)
    }
    #endif

    /// The main display's usable rect, as the core snaps into it (the ZoneMap result is laid out on it).
    private var mainUsable: CGRect {
        #if NOKTA_SNAPSHOT
        if let usableOverride { return usableOverride }
        #endif
        return Screens.coreUsableFrames().first?.1 ?? ZoneMap.fallbackUsable
    }

    convenience init(app: AppController, prefs: Preferences) { self.init(app: app, prefs: prefs, title: "Dragging") }

    override func makeContent() -> NSView {
        let form = SettingsForm()

        dragSwitch = UIControls.toggle("Drag to snap", target: self, action: #selector(toggleDrag(_:)))
        form.row("Drag to snap", control: dragSwitch)

        zoneMap = ZoneMap()
        zoneMap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            zoneMap.widthAnchor.constraint(equalToConstant: ZoneMap.size.width),
            zoneMap.heightAnchor.constraint(equalToConstant: ZoneMap.size.height),
        ])
        zoneMap.actionProvider = { [weak self] zone in self?.prefs.zoneAction(zone, alternate: false) }
        zoneMap.onAssign = { [weak self] zone, action in self?.prefs.setZoneAction(action, for: zone, alternate: false) }
        zoneMap.onSelect = { [weak self] _ in self?.updateSelection() }
        form.wide(zoneMap, xPlacement: .center, padding: Theme.Space.s3)

        // The row titles follow the selected handle (`updateSelection`).
        primaryPopup = zonePopup(action: #selector(choosePrimary(_:)))
        primaryRow = form.row("", control: primaryPopup)
        alternatePopup = zonePopup(action: #selector(chooseAlternate(_:)))
        alternateRow = form.row("", control: alternatePopup)
        alternateRow.topPadding = Theme.Space.s2

        modifierControl = UIControls.segmented(modifiers.map(\.1), title: "Alternate key",
                                               target: self, action: #selector(changeModifier(_:)))
        for (i, m) in modifiers.enumerated() { modifierControl.setToolTip(m.2, forSegment: i) }
        form.row("Alternate key", control: modifierControl)
        (modifierHelpRow, modifierHelp) = form.help("macOS also tiles while ⌥ is held.")

        sensitivityControl = UIControls.segmented(sensitivities.map(\.title), title: "Sensitivity",
                                                  target: self, action: #selector(changeSensitivity(_:)))
        for (i, s) in sensitivities.enumerated() { sensitivityControl.setToolTip(s.detail, forSegment: i) }
        form.row("Sensitivity", control: sensitivityControl)

        snapBackSwitch = UIControls.toggle("Restore size on drag out", target: self, action: #selector(toggleSnapBack(_:)))
        form.row("Restore size on drag out", control: snapBackSwitch)
        sharedEdgesSwitch = UIControls.toggle("Snap where displays meet", target: self, action: #selector(toggleSharedEdges(_:)))
        form.row("Snap where displays meet", control: sharedEdgesSwitch)

        form.group()
        (gapSlider, gapValue) = UISlider.make(title: "Gap", min: 0, max: 24, ticks: 7, target: self, action: #selector(slide(_:)))
        form.row("Gap", control: UISlider.stack(gapSlider, gapValue))
        (marginSlider, marginValue) = UISlider.make(title: "Margin", min: 0, max: 24, ticks: 7, target: self, action: #selector(slide(_:)))
        form.row("Margin", control: UISlider.stack(marginSlider, marginValue))

        card = SystemWindowingCard(width: SettingsForm.contentWidth)
        card.button.target = self
        card.button.action = #selector(openDesktopDock(_:))
        form.group()
        cardRow = form.wide(card, xPlacement: .fill)

        dragDependent = [zoneMap, primaryPopup, alternatePopup, modifierControl, sensitivityControl,
                         snapBackSwitch, sharedEdgesSwitch]
        // A display plugged in, turned or resized changes what the map's result is laid out on.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.refresh() }
        return form.finish()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Pop-up for one drag map; fixed width so the row does not jump with the chosen action.
    private func zonePopup(action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = action
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 208).isActive = true
        return popup
    }

    private func title(of row: NSGridRow) -> NSTextField? {
        row.cell(at: 0).contentView as? NSTextField
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh() // re-read macOS tiling / Stage Manager each time the tab shows
    }

    override func refresh() {
        guard isViewLoaded else { return }
        dragSwitch.state = prefs.dragSnap ? .on : .off
        for control in dragDependent { control.isEnabled = prefs.dragSnap }

        zoneMap.config = prefs.coreConfig
        zoneMap.usable = mainUsable
        zoneMap.reload()
        updateSelection()

        let mods = prefs.thirdsModifier
        modifierControl.selectedSegment = modifiers.firstIndex { $0.0 == mods } ?? -1
        let system = systemState()
        // Shown when ⌥ is the alternate key and macOS's own ⌥ tiling is on — or unknown (cautious: "may").
        modifierHelpRow.setHidden(!(mods == .option && system.optionAccelerator != .off))
        modifierHelp.stringValue = system.optionAccelerator == .on
            ? "macOS also tiles while ⌥ is held." : "macOS may also tile while ⌥ is held."

        let sensitivity = prefs.edgeSensitivity
        sensitivityControl.selectedSegment = sensitivity.flatMap { sensitivities.firstIndex(of: $0) } ?? -1
        sensitivityControl.setAccessibilityHelp("Edge \(Int(prefs.zoneEdge.rounded())) pt · corner \(Int(prefs.zoneCorner.rounded())) pt")
        snapBackSwitch.state = prefs.snapBack ? .on : .off
        sharedEdgesSwitch.state = prefs.sharedEdgeZones ? .on : .off

        UISlider.set(gapSlider, gapValue, value: prefs.gapInner, unit: "pt", spokenUnit: "points")
        UISlider.set(marginSlider, marginValue, value: prefs.gapOuter, unit: "pt", spokenUnit: "points")

        let lines = SystemWindowingCard.lines(tiling: system.tiling, stageManager: system.stageManager)
        card.setLines(lines)
        cardRow.setHidden(lines.isEmpty)
        updatePreferredSize()
    }

    #if NOKTA_SNAPSHOT
    /// Selects `zone` on the map (and in the popups below it).
    func select(zone: NoktaZone) {
        loadViewIfNeeded()
        zoneMap.select(zone)
    }
    #endif

    /// The popup rows follow the selected handle: `Left edge` for the primary map, `With ⇧` for the
    /// alternate one (hidden while the alternate key is None).
    private func updateSelection() {
        let zone = zoneMap.selectedZone
        let mods = prefs.thirdsModifier

        title(of: primaryRow)?.stringValue = ZoneInfo.shortName(zone)
        fill(primaryPopup, selected: prefs.zoneAction(zone, alternate: false))
        primaryPopup.setAccessibilityLabel(ZoneInfo.spokenName(zone))
        title(of: primaryRow)?.textColor = primaryPopup.isEnabled ? .labelColor : .disabledControlTextColor

        alternateRow.setHidden(mods.isEmpty)
        title(of: alternateRow)?.stringValue = mods.isEmpty ? "" : "With \(mods.symbols)"
        fill(alternatePopup, selected: prefs.zoneAction(zone, alternate: true))
        let spokenMods = modifiers.first { $0.0 == mods }?.2 ?? "the alternate key"
        alternatePopup.setAccessibilityLabel("\(ZoneInfo.spokenName(zone)) while holding \(spokenMods)")
        title(of: alternateRow)?.textColor = alternatePopup.isEnabled ? .labelColor : .disabledControlTextColor
        updatePreferredSize()
    }

    private func fill(_ popup: NSPopUpButton, selected: NoktaAction?) {
        let menu = ZoneInfo.makeMenu(selected: selected, target: nil, action: nil)
        for item in menu.items { item.state = .off }
        popup.menu = menu
        let raw = selected?.rawValue ?? 0
        if let item = menu.items.first(where: { ($0.representedObject as? NSNumber)?.uint32Value == raw }) {
            popup.select(item)
        }
    }

    // MARK: actions

    @objc private func toggleDrag(_ sender: NSSwitch) { prefs.dragSnap = sender.state == .on }

    @objc private func choosePrimary(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, let action = ZoneInfo.action(from: item) else { return }
        prefs.setZoneAction(action, for: zoneMap.selectedZone, alternate: false)
    }

    @objc private func chooseAlternate(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, let action = ZoneInfo.action(from: item) else { return }
        prefs.setZoneAction(action, for: zoneMap.selectedZone, alternate: true)
    }

    @objc private func changeModifier(_ sender: NSSegmentedControl) {
        guard modifiers.indices.contains(sender.selectedSegment) else { return }
        prefs.thirdsModifier = modifiers[sender.selectedSegment].0
    }

    @objc private func changeSensitivity(_ sender: NSSegmentedControl) {
        guard sensitivities.indices.contains(sender.selectedSegment) else { return }
        let chosen = sensitivities[sender.selectedSegment]
        guard prefs.edgeSensitivity != chosen else { return } // already in effect: leave the exact sizes alone
        prefs.edgeSensitivity = chosen
    }

    @objc private func toggleSnapBack(_ sender: NSSwitch) { prefs.snapBack = sender.state == .on }
    @objc private func toggleSharedEdges(_ sender: NSSwitch) { prefs.sharedEdgeZones = sender.state == .on }

    /// Writes only when the stepped value changes (each write re-applies the core config).
    @objc private func slide(_ sender: NSSlider) {
        let value = sender.doubleValue.rounded()
        switch sender {
        case gapSlider:
            guard prefs.gapInner != value else { return }
            prefs.gapInner = value
            stepHaptic()
        case marginSlider:
            guard prefs.gapOuter != value else { return }
            prefs.gapOuter = value
            stepHaptic()
        default: return
        }
        refresh()
    }

    /// DESIGN §6: every 4 pt step of the Gap and Margin sliders → .levelChange (if haptics are on).
    private func stepHaptic() {
        guard prefs.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    @objc private func openDesktopDock(_ sender: Any?) { app.openDesktopDockSettings() }
}

/// "ⓘ macOS tiling is also on. [Open Desktop & Dock…]" card (shown only when detected).
final class SystemWindowingCard: PanelView {
    let button = NSButton(title: "Open Desktop & Dock…", target: nil, action: nil)
    private let icon = NSImageView()
    private let text: NSTextField

    static func lines(tiling: SystemWindowing.State, stageManager: Bool) -> [String] {
        var lines: [String] = []
        switch tiling {
        case .on: lines.append("macOS tiling is also on.")
        case .unknown: lines.append("macOS may also tile windows.")
        case .off: break
        }
        if stageManager { lines.append("Stage Manager may take dropped windows.") }
        return lines
    }

    init(width: CGFloat) {
        button.bezelStyle = .rounded
        let pad = Theme.Space.s3
        let textWidth = width - 2 * pad - 20 - Theme.Space.s2 - Theme.Space.s2 - ceil(button.fittingSize.width)
        text = UIText.wrapping("", font: Typography.callout, color: .labelColor, width: textWidth)
        super.init(frame: .zero)
        fill = Theme.Color.paperRaised
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIControls.symbol("info.circle", label: "Note")
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        for v in [icon, text, button] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Space.s2),
            text.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            text.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -Theme.Space.s2),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("macOS window features")
    }
    required init?(coder: NSCoder) { nil }

    func setLines(_ lines: [String]) {
        text.stringValue = lines.joined(separator: "\n")
    }
}
