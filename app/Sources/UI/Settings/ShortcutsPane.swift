import AppKit

/// Settings › Shortcuts (DESIGN §8): grouped table of recorders, shortcut set, cycle, flash and
/// Almost Maximize, the VoiceOver protection, Restore Defaults. Registration failures come from
/// `app.hotkeyResults`.
final class ShortcutsPane: SettingsPaneController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case group(NoktaAction.Group)
        case action(NoktaAction)
    }

    /// Transient per-row notes (validation text, in-app conflict prompt).
    private enum Note {
        case message(String)
        case conflict(Shortcut, NoktaAction)
    }

    private let rows: [Row] = NoktaAction.Group.allCases.flatMap { group in
        [Row.group(group)] + NoktaAction.allCases.filter { $0.group == group }.map(Row.action)
    }
    private var notes: [NoktaAction: Note] = [:]
    private var recordingAction: NoktaAction?
    private var refreshWhenRecordingEnds = false
    private var returnFocusToTable = false
    /// A newly saved shortcut whose registration outcome is still to be read (right away, or when
    /// the recorder's suspension ends and the shortcuts are bound again).
    private var pendingCheck: (action: NoktaAction, shortcut: Shortcut, previous: Shortcut?)?
    /// macOS's own shortcuts, read when the pane appears and after each recording (not per row).
    private var systemReserved: [Shortcut] = []

    private var table: ShortcutTableView!
    private var setControl: NSSegmentedControl!
    private var cycleSwitch: NSSwitch!
    private var flashSwitch: NSSwitch!
    private var almostSlider: NSSlider!
    private var almostValue: NSTextField!
    private var keepClassicSwitch: NSSwitch!
    private var voiceOverRow: NSGridRow!
    private var voiceOverHelpRow: NSGridRow!
    private var voiceOverHelp: NSTextField!
    private let sets: [Preferences.ShortcutSet] = [.classic, .alternate]
    private static let rowHeight: CGFloat = 28

    #if NOKTA_SNAPSHOT
    /// Offscreen tools show the conditional VoiceOver row.
    var voiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    #else
    private func voiceOverEnabled() -> Bool { NSWorkspace.shared.isVoiceOverEnabled }
    #endif

    /// Balance fuse: a pane torn down mid-recording must not leave every hotkey unbound.
    deinit {
        if recordingAction != nil { app.suspendShortcuts(false) }
    }

    convenience init(app: AppController, prefs: Preferences) { self.init(app: app, prefs: prefs, title: "Shortcuts") }

    override func makeContent() -> NSView {
        let form = SettingsForm()

        table = ShortcutTableView()
        table.headerView = nil
        table.style = .inset
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAutomaticRowHeights = false
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.floatsGroupRows = false
        table.setAccessibilityLabel("Shortcuts")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.onKey = { [weak self] key in self?.handleTableKey(key) ?? false }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: Theme.Space.s1, right: 0)
        let box = PanelView()
        box.fill = Theme.Color.paperRaised
        box.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: SettingsForm.contentWidth),
            box.heightAnchor.constraint(equalToConstant: 300),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
        ])
        form.wide(box)

        setControl = UIControls.segmented(["Classic ⌃⌥", "Alternate ⌃⇧⌘"], title: "Shortcut set",
                                          target: self, action: #selector(changeSet(_:)))
        setControl.setToolTip("Control-Option + key", forSegment: 0)
        setControl.setToolTip("Control-Shift-Command + key", forSegment: 1)
        form.group()
        form.row("Shortcut set", control: setControl)
        form.help("Alternate avoids the VoiceOver keys.")

        cycleSwitch = UIControls.toggle("Repeat to cycle ½ ⅔ ⅓", target: self, action: #selector(toggleCycle(_:)))
        form.row("Repeat to cycle ½ ⅔ ⅓", control: cycleSwitch)
        flashSwitch = UIControls.toggle("Flash after snap", target: self, action: #selector(toggleFlash(_:)))
        form.row("Flash after snap", control: flashSwitch)
        (almostSlider, almostValue) = UISlider.make(title: "Almost Maximize", min: 50, max: 100, ticks: 11,
                                                    target: self, action: #selector(slide(_:)))
        form.row("Almost Maximize", control: UISlider.stack(almostSlider, almostValue))

        // Visible while VoiceOver runs (so a VoiceOver user always finds it) or while the switch is on.
        let keepHelp = "For Caps Lock as VO key."
        keepClassicSwitch = UIControls.toggle("Keep ⌃⌥ with VoiceOver", help: keepHelp, target: self, action: #selector(toggleKeepClassic(_:)))
        voiceOverRow = form.row("Keep ⌃⌥ with VoiceOver", control: keepClassicSwitch)
        (voiceOverHelpRow, voiceOverHelp) = form.help(keepHelp)

        form.separator()
        form.wide(UIControls.button("Restore Defaults", target: self, action: #selector(restoreDefaults(_:))))
        return form.finish()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        table.reloadData()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        systemReserved = SystemShortcuts.reserved()
        refresh() // VoiceOver may have changed while another tab was showing
    }

    override func refresh() {
        guard isViewLoaded else { return }
        cycleSwitch.state = prefs.cycleSizes ? .on : .off
        setControl.selectedSegment = prefs.currentShortcutSet.flatMap { sets.firstIndex(of: $0) } ?? -1
        flashSwitch.state = prefs.flashOnKeyboardSnap ? .on : .off
        UISlider.set(almostSlider, almostValue, value: (prefs.almostMaximize * 100).rounded(), unit: "%", spokenUnit: "percent")
        keepClassicSwitch.state = prefs.keepClassicWithVoiceOver ? .on : .off
        let voiceOver = voiceOverEnabled()
        let anyControlOption = NoktaAction.allCases.contains {
            prefs.shortcut(for: $0)?.modifiers.isSuperset(of: [.control, .option]) == true
        }
        let paused = voiceOver && !prefs.keepClassicWithVoiceOver && anyControlOption
        voiceOverRow.setHidden(!(voiceOver || prefs.keepClassicWithVoiceOver))
        voiceOverHelpRow.setHidden(voiceOverRow.isHidden)
        voiceOverHelp.stringValue = paused ? "⌃⌥ shortcuts paused." : "For Caps Lock as VO key."
        refreshRows()
        updatePreferredSize()
    }

    /// Re-reads every visible row in place. Deferred while a recorder listens: the suspension
    /// itself produces a burst of hotkey-state refreshes that must not disturb the recorder.
    private func refreshRows() {
        guard let table else { return }
        if recordingAction != nil {
            refreshWhenRecordingEnds = true
            return
        }
        for index in 0..<rows.count {
            guard case .action(let action) = rows[index],
                  let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ShortcutCellView else { continue }
            configure(cell, for: action)
        }
        noteHeights(IndexSet(integersIn: 0..<rows.count))
    }

    /// Row heights change when a note appears; the system animates that, Reduce Motion does not.
    private func noteHeights(_ indexes: IndexSet) {
        NSAnimationContext.runAnimationGroup { context in
            if Theme.Motion.reduceMotion {
                context.duration = 0
                context.allowsImplicitAnimation = false
            }
            table.noteHeightOfRows(withIndexesChanged: indexes)
        }
    }

    // MARK: notes

    private func noteText(for action: NoktaAction) -> (String, conflict: Bool)? {
        switch notes[action] {
        case .message(let text): return (text, false)
        case .conflict(_, let other): return ("Used by “\(other.title)”.", true)
        case nil: break
        }
        let saved = prefs.shortcut(for: action)
        if saved?.optionOnlyWarning == true {
            return ("Option-only fails on macOS 15.0–15.1.", false)
        }
        if let saved, systemReserved.contains(saved) {
            return ("macOS uses this shortcut.", false)
        }
        if app.hotkeyResults[action] == .hotkey {
            return ("Taken by macOS or another app.", false)
        }
        return nil
    }

    private func row(of action: NoktaAction) -> Int? {
        rows.firstIndex { if case .action(let a) = $0 { return a == action } else { return false } }
    }

    private func updateRow(_ action: NoktaAction) {
        guard let index = row(of: action) else { return }
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ShortcutCellView {
            configure(cell, for: action)
        }
        noteHeights(IndexSet(integer: index))
    }

    // MARK: recording flow

    private func recordingBegan(_ action: NoktaAction) {
        if case .conflict = notes[action] { notes[action] = nil; updateRow(action) }
        recordingAction = action
        app.suspendShortcuts(true)
    }

    private func recordingEnded(_ action: NoktaAction) {
        recordingAction = nil
        app.suspendShortcuts(false) // binds every shortcut once, a just-recorded one included
        systemReserved = SystemShortcuts.reserved()
        if refreshWhenRecordingEnds {
            refreshWhenRecordingEnds = false
            refreshRows()
        } else if let index = row(of: action),
                  let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ShortcutCellView {
            // The recorder shows the saved shortcut again at once. No height change here: this can
            // run while the table recycles the row (its recorder leaving the window).
            configure(cell, for: action)
        }
        checkRegistration()
        if returnFocusToTable {
            returnFocusToTable = false
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.table.window else { return }
                if case .conflict = self.notes[action] { return } // focus is on Swap
                // Tab / ⇧Tab already moved on: the focus stays where the key loop put it.
                guard window.firstResponder is ShortcutRecorder else { return }
                window.makeFirstResponder(self.table)
            }
        }
    }

    private func commit(_ shortcut: Shortcut?, for action: NoktaAction) {
        let previous = prefs.shortcut(for: action)
        if let shortcut, previous != shortcut,
           let other = NoktaAction.allCases.first(where: { $0 != action && prefs.shortcut(for: $0) == shortcut }) {
            notes[action] = .conflict(shortcut, other)
            updateRow(action)
            announce("\(ShortcutSpeech.spoken(shortcut)) is already used by \(other.title). Swap or Cancel.", high: true)
            if let index = row(of: action), let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ShortcutCellView {
                table.window?.makeFirstResponder(cell.swapButton)
            }
            return
        }
        notes[action] = nil
        guard previous != shortcut else {
            updateRow(action)
            announce("\(action.title) is still \(ShortcutSpeech.spoken(shortcut)).")
            return
        }
        prefs.setShortcut(shortcut, for: action) // AppController re-binds (unless a recorder still suspends) and refreshes
        updateRow(action)
        guard let shortcut else {
            announce("\(action.title) shortcut cleared.")
            return
        }
        pendingCheck = (action, shortcut, previous)
        if recordingAction == nil { checkRegistration() } // else once recordingEnded re-binds
    }

    /// Reads how the registration of a just-saved shortcut went. If Carbon refused it (another app
    /// holds the combination), the previous shortcut — which may still work — is put back and the
    /// row says so: a failed recording never costs the user a working shortcut.
    private func checkRegistration() {
        guard let check = pendingCheck else { return }
        pendingCheck = nil
        let (action, shortcut, previous) = check
        guard prefs.shortcut(for: action) == shortcut else { return } // changed again meanwhile
        guard app.hotkeyResults[action] == .hotkey else {
            announce("\(action.title) shortcut set to \(ShortcutSpeech.spoken(shortcut)).")
            return
        }
        prefs.setShortcut(previous, for: action)
        let kept = previous.map { "Kept \($0.displayString)." } ?? "Left empty."
        notes[action] = .message("\(shortcut.displayString) is in use by another app. \(kept)")
        updateRow(action)
        let spokenKept = previous.map { "Kept \(ShortcutSpeech.spoken($0))." } ?? "Left empty."
        announce("\(ShortcutSpeech.spoken(shortcut)) is in use by another app. \(spokenKept)", high: true)
    }

    private func setMessage(_ text: String?, for action: NoktaAction) {
        if let text {
            notes[action] = .message(text)
        } else if case .message = notes[action] {
            notes[action] = nil
        } else {
            return
        }
        updateRow(action)
    }

    private func swap(_ action: NoktaAction) {
        guard case .conflict(let shortcut, let other) = notes[action] else { return }
        let previous = prefs.shortcut(for: action)
        notes[action] = nil
        // One change, bound in two passes (NoktaEngine.bind(_:)): neither action ever asks Carbon
        // for a combination the other still holds.
        prefs.setShortcuts([(action, shortcut), (other, previous)])
        updateRow(action)
        if let index = row(of: other) { noteHeights(IndexSet(integer: index)) }
        announce("Swapped. \(action.title) is \(ShortcutSpeech.spoken(shortcut)), \(other.title) is \(ShortcutSpeech.spoken(previous)).")
        focusRow(action)
    }

    private func cancelConflict(_ action: NoktaAction) {
        notes[action] = nil
        updateRow(action)
        focusRow(action)
    }

    private func focusRow(_ action: NoktaAction) {
        guard let index = row(of: action) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.window?.makeFirstResponder(table)
    }

    /// Space/Return record, Delete clears the selected row (table is the Tab stop).
    private func handleTableKey(_ key: ShortcutTableView.Key) -> Bool {
        let index = table.selectedRow
        guard index >= 0, case .action(let action) = rows[index],
              let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ShortcutCellView else { return false }
        switch key {
        case .record:
            returnFocusToTable = true
            table.window?.makeFirstResponder(cell.recorder)
            cell.recorder.beginRecording()
        case .clear:
            if prefs.shortcut(for: action) != nil { commit(nil, for: action) }
        }
        return true
    }

    // MARK: actions

    @objc private func toggleCycle(_ sender: NSSwitch) { prefs.cycleSizes = sender.state == .on }
    @objc private func toggleFlash(_ sender: NSSwitch) { prefs.flashOnKeyboardSnap = sender.state == .on }
    @objc private func toggleKeepClassic(_ sender: NSSwitch) { prefs.keepClassicWithVoiceOver = sender.state == .on }

    /// Writes only when the stepped value changes (each write re-applies the core config).
    @objc private func slide(_ sender: NSSlider) {
        let value = sender.doubleValue.rounded()
        guard abs(prefs.almostMaximize * 100 - value) >= 1 else { return }
        prefs.almostMaximize = value / 100
        refresh()
    }

    @objc private func changeSet(_ sender: NSSegmentedControl) {
        guard sets.indices.contains(sender.selectedSegment) else { return }
        let set = sets[sender.selectedSegment]
        guard prefs.currentShortcutSet == nil else {
            prefs.applyShortcutSet(set)
            return
        }
        // Custom shortcuts would be lost: ask first.
        let alert = NSAlert()
        alert.messageText = "Use the \(set == .classic ? "Classic" : "Alternate") set?"
        alert.informativeText = "This replaces your custom shortcuts."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        present(alert) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.prefs.applyShortcutSet(set) }
            self.refresh()
        }
    }

    /// Custom shortcuts are replaced only after the user says so (a set's own shortcuts are not
    /// custom: choosing the set again brings them back).
    @objc private func restoreDefaults(_ sender: Any?) {
        guard prefs.currentShortcutSet == nil else { resetShortcuts(); return }
        let alert = NSAlert()
        alert.messageText = "Restore the default shortcuts?"
        alert.informativeText = "This replaces your custom shortcuts."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        present(alert) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.resetShortcuts() }
        }
    }

    private func resetShortcuts() {
        notes.removeAll()
        prefs.resetShortcuts()
        refreshRows()
        announce("Default shortcuts restored.")
    }

    #if NOKTA_SNAPSHOT
    /// Tests: answers every confirmation at once instead of showing it (and records its title).
    var testAlertResponse: NSApplication.ModalResponse?
    private(set) var testAlertTitles: [String] = []
    #endif

    private func present(_ alert: NSAlert, done: @escaping (NSApplication.ModalResponse) -> Void) {
        #if NOKTA_SNAPSHOT
        if let response = testAlertResponse {
            testAlertTitles.append(alert.messageText)
            done(response)
            return
        }
        #endif
        if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .action = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .group: return 24
        case .action(let action):
            guard let note = noteText(for: action) else { return Self.rowHeight }
            return Self.rowHeight + (note.conflict ? 28 : 20)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let group):
            let id = NSUserInterfaceItemIdentifier("group")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? GroupCellView ?? GroupCellView(identifier: id)
            cell.label.stringValue = group.title
            return cell
        case .action(let action):
            let id = NSUserInterfaceItemIdentifier("action")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ShortcutCellView ?? ShortcutCellView(identifier: id)
            configure(cell, for: action)
            return cell
        }
    }

    private func configure(_ cell: ShortcutCellView, for action: NoktaAction) {
        cell.action = action
        cell.glyph.image = FrameGlyphs.action(action)
        // No glyph (Restore, display moves): hide the empty image view, or VoiceOver reads "image".
        cell.glyph.isHidden = cell.glyph.image == nil
        cell.name.stringValue = action.title
        let recorder = cell.recorder
        recorder.actionTitle = action.title
        recorder.participatesInKeyViewLoop = false
        recorder.keyLoopAnchor = table
        if !recorder.isRecording { recorder.shortcut = prefs.shortcut(for: action) }
        recorder.onBegin = { [weak self] in self?.recordingBegan(action) }
        recorder.onEnd = { [weak self] in self?.recordingEnded(action) }
        recorder.onCommit = { [weak self] s in self?.commit(s, for: action) }
        recorder.onMessage = { [weak self] text in self?.setMessage(text, for: action) }
        cell.onSwap = { [weak self] in self?.swap(action) }
        cell.onCancel = { [weak self] in self?.cancelConflict(action) }
        cell.onClear = { [weak self] in self?.commit(nil, for: action) }
        cell.setClearable(prefs.shortcut(for: action) != nil && !recorder.isRecording, title: action.title)
        cell.setNote(noteText(for: action))
    }
}

private extension NoktaAction.Group {
    var title: String {
        switch self {
        case .halves: return "HALVES"
        case .quarters: return "QUARTERS"
        case .thirds: return "THIRDS"
        case .size: return "SIZE"
        case .display: return "DISPLAY"
        }
    }
}

/// Table that forwards Space/Return/Delete on the selected row.
final class ShortcutTableView: NSTableView {
    enum Key { case record, clear }
    var onKey: ((Key) -> Bool)?

    /// Tabbing into the list lands on the first shortcut row instead of an empty selection.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, selectedRow < 0, NSApp.currentEvent?.type == .keyDown {
            for row in 0..<numberOfRows where delegate?.tableView?(self, shouldSelectRow: row) ?? true {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                scrollRowToVisible(row)
                break
            }
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.isEmpty {
            switch event.keyCode {
            case 0x31, 0x24, 0x4C: if onKey?(.record) == true { return }
            case 0x33, 0x75: if onKey?(.clear) == true { return }
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

private final class GroupCellView: NSTableCellView {
    let label = UIText.label("", font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.s1),
        ])
    }
    required init?(coder: NSCoder) { nil }
}

final class ShortcutCellView: NSTableCellView {
    var action: NoktaAction?
    let glyph = NSImageView()
    let name = UIText.label("")
    let recorder = ShortcutRecorder()
    let clearButton = NSButton()
    let noteLabel = UIText.label("", font: Typography.callout, color: .secondaryLabelColor)
    let swapButton = NSButton(title: "Swap", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let noteStack = NSStackView()
    var onSwap: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClear: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        textField = name
        glyph.imageScaling = .scaleNone
        glyph.setAccessibilityElement(false)
        for b in [swapButton, cancelButton] {
            b.bezelStyle = .rounded // regular size: the hit target is 24 pt (DESIGN §15)
            b.target = self
        }
        swapButton.action = #selector(swapPressed)
        cancelButton.action = #selector(cancelPressed)
        // The × beside the recorder; Delete clears from the keyboard, so it stays out of the key loop.
        clearButton.image = UIControls.symbol("xmark.circle.fill", label: "Clear shortcut")
            ?? NSImage(named: NSImage.stopProgressFreestandingTemplateName)
        clearButton.imagePosition = .imageOnly
        clearButton.isBordered = false
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.refusesFirstResponder = true
        clearButton.target = self
        clearButton.action = #selector(clearPressed)
        noteLabel.lineBreakMode = .byTruncatingTail
        noteStack.orientation = .horizontal
        noteStack.spacing = Theme.Space.s2
        noteStack.addArrangedSubview(noteLabel)
        noteStack.addArrangedSubview(swapButton)
        noteStack.addArrangedSubview(cancelButton)

        for v in [glyph, name, recorder, clearButton, noteStack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let line: CGFloat = 14 // centre of the 28 pt row
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s2),
            glyph.centerYAnchor.constraint(equalTo: topAnchor, constant: line),
            glyph.widthAnchor.constraint(equalToConstant: FrameGlyphs.size.width),
            glyph.heightAnchor.constraint(equalToConstant: FrameGlyphs.size.height),
            name.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: Theme.Space.s2),
            name.centerYAnchor.constraint(equalTo: topAnchor, constant: line),
            name.trailingAnchor.constraint(lessThanOrEqualTo: recorder.leadingAnchor, constant: -Theme.Space.s2),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.s1),
            clearButton.centerYAnchor.constraint(equalTo: topAnchor, constant: line),
            clearButton.widthAnchor.constraint(equalToConstant: 24),
            clearButton.heightAnchor.constraint(equalToConstant: 24),
            recorder.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -Theme.Space.s1),
            recorder.centerYAnchor.constraint(equalTo: topAnchor, constant: line),
            recorder.widthAnchor.constraint(equalToConstant: ShortcutRecorder.size.width),
            recorder.heightAnchor.constraint(equalToConstant: ShortcutRecorder.size.height),
            noteStack.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            noteStack.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            noteStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Space.s1),
        ])
    }
    required init?(coder: NSCoder) { nil }

    /// `title`: the action's name, for the × button's spoken label.
    func setClearable(_ clearable: Bool, title: String) {
        clearButton.isHidden = !clearable
        clearButton.setAccessibilityLabel("Clear \(title) shortcut")
        clearButton.toolTip = "Clear"
    }

    func setNote(_ note: (String, conflict: Bool)?) {
        noteStack.isHidden = note == nil
        noteLabel.stringValue = note?.0 ?? ""
        swapButton.isHidden = note?.conflict != true
        cancelButton.isHidden = note?.conflict != true
        noteLabel.setAccessibilityLabel(note?.0)
    }

    @objc private func swapPressed() { onSwap?() }
    @objc private func cancelPressed() { onCancel?() }
    @objc private func clearPressed() { onClear?() }
}
