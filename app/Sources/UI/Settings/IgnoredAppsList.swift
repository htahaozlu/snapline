import AppKit
import UniformTypeIdentifiers

/// The ignore list in Settings › General (DESIGN §8): ignored apps stored by bundle id, three rows
/// visible, an empty state, `.app` bundles accepted by drop, [+ ▾] [−] below. Ignored apps get no
/// shortcuts and no drag snapping; the core keeps at most `Preferences.maxExcluded` of them.
final class IgnoredAppsList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct Entry {
        let bundleID: String
        let name: String
        let icon: NSImage
        let installed: Bool
    }

    private let prefs: Preferences
    private var entries: [Entry] = []
    private var loadedIDs: [String]?
    private var table: IgnoredAppsTableView!
    private var emptyState: NSTextField!
    private var addButton: NSButton!
    private var removeButton: NSButton!

    static let rowHeight: CGFloat = 28
    static let visibleRows = 3
    /// What an ignored app means; the tooltip and VoiceOver's help for the list.
    static let help = "No shortcuts or drag snapping in these apps."

    init(prefs: Preferences) {
        self.prefs = prefs
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { nil }

    private func build() {
        table = IgnoredAppsTableView()
        table.headerView = nil
        table.style = .inset
        table.rowSizeStyle = .custom
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.backgroundColor = .clear
        table.setAccessibilityLabel("Ignored apps")
        table.setAccessibilityHelp(Self.help)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.onDelete = { [weak self] in self?.removeSelected(nil) }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let drop = IgnoredAppsDropView()
        drop.onDrop = { [weak self] ids in
            guard let self else { return }
            if self.prefs.addExcluded(ids) > 0 { self.showCapNote() }
        }
        emptyState = UIText.label("Drop apps here.", font: Typography.callout, color: .secondaryLabelColor)
        emptyState.alignment = .center
        for v in [scroll, emptyState!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            drop.addSubview(v)
        }
        drop.translatesAutoresizingMaskIntoConstraints = false
        let listHeight = Self.rowHeight * CGFloat(Self.visibleRows) + 2
        NSLayoutConstraint.activate([
            drop.widthAnchor.constraint(equalToConstant: SettingsForm.contentWidth),
            drop.heightAnchor.constraint(equalToConstant: listHeight),
            scroll.topAnchor.constraint(equalTo: drop.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: drop.bottomAnchor, constant: -1),
            scroll.leadingAnchor.constraint(equalTo: drop.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: drop.trailingAnchor, constant: -1),
            emptyState.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
        ])

        addButton = makeButton(image: Self.addMenuImage(), label: "Add app to ignore", width: 40, action: #selector(showAddMenu(_:)))
        addButton.setAccessibilityHelp("Choose a running app, or pick one from Applications.")
        removeButton = makeButton(image: UIControls.symbol("minus", label: "Remove selected apps")
                                    ?? NSImage(named: NSImage.removeTemplateName) ?? NSImage(),
                                  label: "Remove selected apps", width: 24, action: #selector(removeSelected(_:)))
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = Theme.Space.s1

        let stack = NSStackView(views: [drop, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// [+ ▾]: a plus with a down chevron, one template image (the button opens a menu).
    private static func addMenuImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let plus = UIControls.symbol("plus", label: "Add")?.withSymbolConfiguration(config)
        let chevron = UIControls.symbol("chevron.down", label: "")?.withSymbolConfiguration(config)
        guard let plus, let chevron else { return NSImage(named: NSImage.addTemplateName) ?? NSImage() }
        let gap: CGFloat = 3
        let size = NSSize(width: plus.size.width + gap + chevron.size.width, height: max(plus.size.height, chevron.size.height))
        let image = NSImage(size: size, flipped: false) { _ in
            plus.draw(in: NSRect(x: 0, y: (size.height - plus.size.height) / 2, width: plus.size.width, height: plus.size.height))
            chevron.draw(in: NSRect(x: plus.size.width + gap, y: (size.height - chevron.size.height) / 2,
                                    width: chevron.size.width, height: chevron.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    private func makeButton(image: NSImage, label: String, width: CGFloat, action: Selector) -> NSButton {
        let b = NSButton(image: image, target: self, action: action)
        b.bezelStyle = .smallSquare
        b.setAccessibilityLabel(label)
        b.toolTip = label
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: width),
            b.heightAnchor.constraint(equalToConstant: 24),
        ])
        return b
    }

    func refresh() {
        // Looking apps up (names, icons) is the costly part: only when the list changed.
        guard prefs.excludedBundleIDs != loadedIDs else { return }
        loadedIDs = prefs.excludedBundleIDs
        let selected = Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].bundleID : nil })
        entries = prefs.excludedBundleIDs.map(Self.entry(for:))
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        table.reloadData()
        let keep = IndexSet(entries.indices.filter { selected.contains(entries[$0].bundleID) })
        table.selectRowIndexes(keep, byExtendingSelection: false)
        emptyState.isHidden = !entries.isEmpty
        updateRemoveButton()
    }

    private static func entry(for bundleID: String) -> Entry {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: bundleID) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            let icon = ws.icon(forFile: url.path)
            icon.size = NSSize(width: 20, height: 20)
            return Entry(bundleID: bundleID, name: name, icon: icon, installed: true)
        }
        let icon = ws.icon(for: .application)
        icon.size = NSSize(width: 20, height: 20)
        return Entry(bundleID: bundleID, name: bundleID, icon: icon, installed: false)
    }

    private func updateRemoveButton() {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    // MARK: adding & removing

    @objc private func showAddMenu(_ sender: NSButton) {
        guard prefs.canAddExcluded else { showCapNote(); return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let prefs = prefs
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .filter { app in app.bundleIdentifier.map { !prefs.isExcluded($0) } ?? false }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
        if running.isEmpty {
            let none = NSMenuItem(title: "No other apps running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            menu.addItem(NSMenuItem.sectionHeader(title: "Running Apps"))
            for runningApp in running {
                let item = NSMenuItem(title: runningApp.localizedName ?? runningApp.bundleIdentifier ?? "App",
                                      action: #selector(addRunning(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = runningApp.bundleIdentifier
                if let icon = runningApp.icon?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let choose = NSMenuItem(title: "Choose App…", action: #selector(chooseApp(_:)), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func addRunning(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        if prefs.addExcluded([id]) > 0 { showCapNote(); return }
        announce("\(item.title) added. \(Product.name) ignores it now.")
    }

    /// 64-app cap reached (core limit): say so instead of silently ignoring apps.
    private func showCapNote() {
        let alert = NSAlert()
        alert.messageText = "64 apps maximum"
        alert.informativeText = "Remove one to add another."
        if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    @objc private func chooseApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Ignore"
        panel.message = "Choose apps to ignore."
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            if self.prefs.addExcluded(ids) > 0 { self.showCapNote() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    @objc private func removeSelected(_ sender: Any?) {
        let ids = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].bundleID : nil }
        guard !ids.isEmpty else { return }
        prefs.excludedBundleIDs = prefs.excludedBundleIDs.filter { id in
            !ids.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
        }
        announce(ids.count == 1 ? "Removed." : "Removed \(ids.count) apps.")
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateRemoveButton() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ignoredApp")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? IgnoredAppCellView ?? IgnoredAppCellView(identifier: id)
        let e = entries[row]
        cell.imageView?.image = e.icon
        cell.textField?.stringValue = e.name
        cell.notInstalled.isHidden = e.installed
        cell.toolTip = e.bundleID
        cell.setAccessibilityLabel(e.installed ? "\(e.name), ignored" : "\(e.name), not installed, ignored")
        return cell
    }
}

private final class IgnoredAppCellView: NSTableCellView {
    let notInstalled = UIText.label("Not installed", font: Typography.callout, color: .secondaryLabelColor)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        let name = UIText.label("")
        imageView = icon
        textField = name
        notInstalled.alignment = .right
        notInstalled.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [icon, name, notInstalled] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s1),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Space.s2),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            notInstalled.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: Theme.Space.s3),
            notInstalled.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.s2),
            notInstalled.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
}

/// Delete / Forward Delete remove the selection.
private final class IgnoredAppsTableView: NSTableView {
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x33 || event.keyCode == 0x75 { onDelete?(); return }
        super.keyDown(with: event)
    }
}

/// Bordered list area that accepts dropped .app bundles anywhere (also over the empty state).
private final class IgnoredAppsDropView: PanelView {
    var onDrop: (([String]) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fill = Theme.Color.paperRaised
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { nil }

    private func bundleIDs(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension == "app" }.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !bundleIDs(sender).isEmpty
        highlighted = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let ids = bundleIDs(sender)
        guard !ids.isEmpty else { return false }
        onDrop?(ids)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlighted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: radius, yRadius: radius)
        path.lineWidth = 2
        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.stroke()
    }
}
