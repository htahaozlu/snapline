import AppKit

// Status menu scenes — owned by the status menu surface; called from main.swift. Offscreen only: never order a
// window in, never activate the app, never install a status item (see main.swift).

/// One menu state, set up through the inert core (`NOKTA_SNAPSHOT_TRUSTED` is its Accessibility answer),
/// a throwaway defaults suite (registered values only: nothing is ever written) and the VoiceOver override.
private struct MenuState {
    var name: String
    var trusted = true
    var onboardingDone = true
    var started = true
    var paused = false
    var voiceOver = false
    /// Also drawn as menu-<name>-<light|dark>.png; every state is listed in menu.txt.
    var mock = true
    /// A bench launch mode (`--bench-idle`): the AppController is built with it and started the
    /// way `applicationDidFinishLaunching` starts a bench instance.
    var bench = BenchMode.none
    /// While paused, Accessibility is revoked (a health check sees it) and granted again.
    var regranted = false
}

private let menuStates = [
    MenuState(name: "healthy"),
    MenuState(name: "needs-permission", trusted: false),
    MenuState(name: "paused", paused: true),
    MenuState(name: "voiceover", voiceOver: true),
    MenuState(name: "finish-setup", onboardingDone: false, mock: false),
    MenuState(name: "stopped", started: false, mock: false),
    MenuState(name: "paused-regranted", paused: true, mock: false, regranted: true),
    MenuState(name: "bench", bench: .idle),
]

/// The status menu in every state as text (menu.txt) and as a mock panel with the menu bar icon above it
/// (menu-<state>-<light|dark>.png). The drag-snapping-unavailable state needs a failing event tap, which the
/// inert core cannot produce.
func dumpMenu() {
    // In memory only (ScratchDefaults): the menu states never touch a defaults domain on disk.
    guard let defaults = ScratchDefaults(suiteName: "nokta.snapshot.scratch.menu") else { return }
    let trustedBefore = getenv("NOKTA_SNAPSHOT_TRUSTED").map { String(cString: $0) }
    defer {
        if let trustedBefore { setenv("NOKTA_SNAPSHOT_TRUSTED", trustedBefore, 1) } else { unsetenv("NOKTA_SNAPSHOT_TRUSTED") }
    }

    var sections: [String] = []
    for state in menuStates {
        let app = menuApp(state, defaults: defaults)
        // The menu holds its controller unowned.
        withExtendedLifetime(app) {
            let status = StatusMenuController(app: app, installStatusItem: false)
            // Finder is always running; read-only, so the "Ignore" row has a name to show.
            status.targetApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            status.rebuild()
            sections.append("## \(state.name)\n" + menuLines(status.menu, depth: 0).joined(separator: "\n"))
            if state.bench != .none { checkBenchSafety(app, menu: status.menu) }
            if state.regranted, app.engineResult == .notTrusted || status.menu.items.contains(where: { $0.title == "Allow Accessibility…" }) {
                renderFailure("menu-paused-regranted: a stale “not trusted” outlived the grant (\(app.engineResult))")
            }
            guard state.mock else { return }
            for (mode, appearance) in appearances {
                write(MenuMock.render(status.menu, icon: status.state, appearance: appearance, dark: mode == "dark"),
                      "menu-\(state.name)-\(mode)")
            }
        }
    }
    let text = sections.joined(separator: "\n\n") + "\n"
    try? text.write(to: outDir.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
    print("wrote menu.txt (\(menuStates.count) states)")
}

private func menuApp(_ state: MenuState, defaults: UserDefaults) -> AppController {
    setenv("NOKTA_SNAPSHOT_TRUSTED", state.trusted ? "1" : "0", 1)
    let app = AppController(defaults: defaults, bench: state.bench)
    // Registered, not set: the registration domain is memory only (Preferences.Key.onboardingDone).
    defaults.register(defaults: ["onboardingDone.v1": state.onboardingDone])
    app.voiceOverOverride = state.voiceOver
    if state.bench != .none {
        app.startEngine(bindShortcuts: false) // applicationDidFinishLaunching, bench modes
    } else if !state.trusted {
        app.checkHealth()
    } else if state.started {
        app.startEngine(bindShortcuts: true)
        if state.paused { app.setPaused(true) }
        if state.regranted {
            setenv("NOKTA_SNAPSHOT_TRUSTED", "0", 1)
            app.checkHealth() // revoked while paused: .notTrusted
            setenv("NOKTA_SNAPSHOT_TRUSTED", "1", 1)
            app.checkHealth() // granted again, still paused
        }
    }
    return app
}

/// Bench modes never move a window or bind a shortcut, whatever the user clicks (SPEC §7, OV2-2):
/// every menu item but Quit is disabled, and the entry points behind them refuse
/// to act (checked through the inert core, which counts every bind call).
private func checkBenchSafety(_ app: AppController, menu: NSMenu) {
    func items(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
    let open = items(menu).filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title)
    var failures: [String] = []
    if open != ["Quit Snapline"] { failures.append("enabled items \(open)") }
    app.setPaused(true)
    if app.paused { failures.append("Pause acted") }
    app.startEngine(bindShortcuts: true)
    app.suspendShortcuts(true)
    app.suspendShortcuts(false) // a recorder ending in Settings › Shortcuts
    let binds = InertCore.counters(app.engine).binds
    if !InertCore.available || binds != 0 || app.engine.stats().hotkeys_bound != 0 { failures.append("\(binds) shortcut binds reached the core") }
    for action in NoktaAction.allCases where app.perform(action, on: nil) != .notStarted {
        failures.append("\(action.title) reached the core")
    }
    if failures.isEmpty {
        print("menu-bench: only Quit enabled; perform, Pause, start and shortcut binding refuse to act")
    } else {
        renderFailure("menu-bench: " + failures.joined(separator: "; "))
    }
}

/// "⌃⌥←" for an item's key equivalent, "" for none.
private func shortcutText(_ item: NSMenuItem) -> String {
    guard !item.keyEquivalent.isEmpty else { return "" }
    let m = item.keyEquivalentModifierMask
    let mods = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") +
               (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
    let keys = ["\r": "↩", "\u{8}": "⌫", "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", " ": "Space"]
    return mods + (keys[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
}

private func menuLines(_ menu: NSMenu, depth: Int) -> [String] {
    var lines: [String] = []
    for item in menu.items {
        let pad = String(repeating: "  ", count: depth)
        if item.isSeparatorItem { lines.append(pad + "────"); continue }
        let key = shortcutText(item)
        var line = pad + item.title
        if !key.isEmpty { line += "   [\(key)]" }
        if !item.isEnabled { line += "   (disabled)" }
        // The red dot is the only non-template image; glyphs carry the action name, the blank spacer none.
        if let image = item.image {
            if !image.isTemplate { line += "   (red dot)" } else if image.accessibilityDescription != nil { line += "   (glyph)" }
        }
        if let tip = item.toolTip { line += "   (tooltip: \(tip))" }
        lines.append(line)
        if let sub = item.submenu { lines += menuLines(sub, depth: depth + 1) }
    }
    return lines
}

/// A menu-like panel drawn from the real items: glyph column, title, shortcut, separators, submenu
/// chevrons, on a desktop stand-in with the menu bar icon above it. Review aid only; AppKit draws
/// the real menu.
private enum MenuMock {
    static let scale: CGFloat = 2
    static let rowHeight: CGFloat = 22, separatorHeight: CGFloat = 9, inset: CGFloat = 5
    static let glyphX: CGFloat = 14, titleX: CGFloat = 36, trailing: CGFloat = 14, keyGap: CGFloat = 28
    static let barHeight: CGFloat = 24, margin: CGFloat = 8, radius: CGFloat = 10

    static func render(_ menu: NSMenu, icon: Glyphs.StatusIconState, appearance: NSAppearance, dark: Bool) -> CGImage? {
        let font = NSFont.menuFont(ofSize: 0)
        let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        func textWidth(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }

        var panelWidth: CGFloat = 220
        var panelHeight = 2 * inset
        for item in menu.items {
            panelHeight += item.isSeparatorItem ? separatorHeight : rowHeight
            guard !item.isSeparatorItem else { continue }
            let trailingWidth = item.submenu != nil ? (chevron?.size.width ?? 8) : textWidth(shortcutText(item))
            panelWidth = max(panelWidth, titleX + textWidth(item.title) + (trailingWidth > 0 ? keyGap + trailingWidth : 0) + trailing)
        }
        let size = CGSize(width: panelWidth + 2 * margin, height: barHeight + 2 + panelHeight + margin)
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            desktopBackdrop(dark: dark)(ctx, size)

            // Menu bar strip with the status icon where a status item draws it.
            ctx.setFillColor(dark ? CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1) : CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))
            ctx.fill(CGRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight))
            if let strip = OverlayFrames.menuIcon(icon, scale: scale, dark: dark) {
                ctx.draw(strip, in: CGRect(x: 0, y: size.height - barHeight, width: 48, height: barHeight))
            }

            // Panel.
            let panel = CGRect(x: margin, y: size.height - barHeight - 2 - panelHeight, width: panelWidth, height: panelHeight)
            let path = CGPath(roundedRect: panel.insetBy(dx: 0.25, dy: 0.25), cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(dark ? CGColor(gray: 0.18, alpha: 1) : CGColor(gray: 0.97, alpha: 1))
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.14) : CGColor(gray: 0, alpha: 0.14))
            ctx.setLineWidth(0.5)
            ctx.strokePath()

            var top = panel.maxY - inset
            for item in menu.items {
                if item.isSeparatorItem {
                    let y = top - separatorHeight / 2
                    ctx.setFillColor(dark ? CGColor(gray: 1, alpha: 0.14) : CGColor(gray: 0, alpha: 0.14))
                    ctx.fill(CGRect(x: panel.minX + 10, y: y - 0.25, width: panel.width - 20, height: 0.5))
                    top -= separatorHeight
                    continue
                }
                let row = CGRect(x: panel.minX, y: top - rowHeight, width: panel.width, height: rowHeight)
                top -= rowHeight
                let ink: NSColor = item.isEnabled ? .labelColor : .tertiaryLabelColor
                if let glyph = item.image {
                    let box = CGRect(x: row.minX + glyphX, y: row.midY - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height)
                    if glyph.isTemplate {
                        if let tinted = tinted(glyph, color: ink) { ctx.draw(tinted, in: box) }
                    } else {
                        glyph.draw(in: box)
                    }
                }
                func draw(_ text: String, x: CGFloat, color: NSColor, rightAligned: Bool = false) {
                    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                    let extent = (text as NSString).size(withAttributes: attributes)
                    let origin = CGPoint(x: rightAligned ? x - extent.width : x, y: row.midY - extent.height / 2)
                    (text as NSString).draw(at: origin, withAttributes: attributes)
                }
                draw(item.title, x: row.minX + titleX, color: ink)
                if item.submenu != nil, let chevron, let tinted = tinted(chevron, color: .secondaryLabelColor) {
                    ctx.draw(tinted, in: CGRect(x: row.maxX - trailing - chevron.size.width, y: row.midY - chevron.size.height / 2,
                                                width: chevron.size.width, height: chevron.size.height))
                } else {
                    draw(shortcutText(item), x: row.maxX - trailing, color: item.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor,
                         rightAligned: true)
                }
            }
            image = ctx.makeImage()
        }
        return image
    }

    /// A template image drawn in `color`, at the mock's scale.
    static func tinted(_ image: NSImage, color: NSColor) -> CGImage? {
        let w = Int(ceil(image.size.width * scale)), h = Int(ceil(image.size.height * scale))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }
}
