import AppKit

// nokta-snapshot --keyboard-test — the shortcut recorder and everything it drives, through the
// shell's real code (Settings › Shortcuts, AppController, Preferences, NoktaEngine) on the INERT
// core, which keeps the real core's hotkey table and dedup rules and emulates Carbon's bookkeeping
// (core/src/inert.zig: a combination already registered — by another action, or by "another app"
// via nk_inert_set_taken — is refused). Nothing is registered, shown, activated or written: windows
// are never ordered in, preferences are in-memory (ScratchDefaults), keys are NSEvents handed to the
// recorder the way its local monitor would see them.
//
// Each block is a regression for an observed behaviour (docs/TESTING.md, "Klavye"):
//   K1 Escape (also with modifiers) cancels, keeps the shortcut, re-registers each one exactly once
//   K2 Delete / ⌦ clear while recording, on a focused recorder and on a selected row
//   K3 a new shortcut is bound once (the old one is never re-registered in between)
//   K4 a duplicate inside Nokta asks Swap / Cancel; Swap re-binds both without a refused registration
//   K5 no modifier, ⇧ only, ⌘ only and macOS's own shortcuts are refused with a reason; F-keys and ⌥ pass
//   K6 a combination another app holds: the previous shortcut is kept and the row says why;
//      a saved shortcut that fails at launch is reported, never replaced
//   K7 while recording nothing is registered, whatever else re-applies preferences or restarts the core
//   K8 closing the window or removing the recorder while recording restores the shortcuts exactly once
//   K9 Tab / ⇧Tab leave the recorder and the key loop continues from the list (focus is not pulled back)
//   K10 key identity (virtual key code) vs. label (current layout): US vs. Turkish Q
//   K11 presets and saved settings are kept; Restore Defaults asks before replacing custom shortcuts
//   K12 VoiceOver: the recorder's role, label, value, help and custom action

enum KeyboardTests {
    static let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]

    static func run() -> Bool {
        let c = Checks("keyboard-test")
        guard InertCore.available else {
            c.expect(false, "inert core test hooks (nk_inert_counters / nk_inert_set_taken) missing")
            return c.finish()
        }
        ShortcutRecorder.requiresKeyWindow = false // offscreen windows are never key
        SystemShortcuts.override = [shortcut(0x7E, [.control]), shortcut(0x31, [.command])] // Mission Control, Spotlight
        KeyNames.layoutOverride = KeyboardLayout.installed(id: "com.apple.keylayout.US")
        Preferences.systemWritesDisabled = false
        setenv("NOKTA_SNAPSHOT_TRUSTED", "1", 1)
        defer {
            unsetenv("NOKTA_SNAPSHOT_TRUSTED")
            SystemShortcuts.override = nil
        }

        escapeCancels(c)
        deleteClears(c)
        commitBindsOnce(c)
        conflicts(c)
        refusals(c)
        takenByAnotherApp(c)
        captureIsolation(c)
        closeWhileRecording(c)
        tabMovesOn(c)
        layouts(c)
        presetsAndSavedSettings(c)
        voiceOver(c)
        return c.finish()
    }

    static func shortcut(_ key: UInt32, _ flags: NSEvent.ModifierFlags) -> Shortcut {
        Shortcut(keyCode: key, mods: NoktaMods(flags).rawValue)
    }

    // MARK: K1

    static func escapeCancels(_ c: Checks) {
        let f = Fixture("kt.escape")
        let start = f.counters
        c.expect(start.live == 20, "K1 start: 20 shortcuts registered (live \(start.live))")
        let rec = f.beginRecording(.leftHalf)
        c.expect(rec.isRecording && rec.testHasMonitor, "K1 Space on a row starts recording with a local monitor")
        c.expect(f.app.shortcutSuspensionCount == 1, "K1 one suspension while recording")
        c.expect(f.counters.live == 0, "K1 nothing registered while recording (live \(f.counters.live))")
        c.expect(rec.testHandle(f.key(0x35)) == nil, "K1 Escape is consumed")
        c.expect(!rec.isRecording, "K1 Escape ends recording")
        c.expect(f.app.prefs.shortcut(for: .leftHalf) == NoktaAction.leftHalf.defaultShortcut, "K1 Escape keeps the shortcut")
        let d = f.counters - start
        c.expect(d.unregistered == 20 && d.registered == 20, "K1 cancel re-registers each shortcut exactly once (−\(d.unregistered) +\(d.registered))")
        c.expect(f.counters.live == 20 && d.refused == 0, "K1 after cancel: 20 live, none refused")
        c.expect(f.app.shortcutSuspensionCount == 0, "K1 suspension balanced")
        c.expect(Announcements.log.last?.hasPrefix("Cancelled. Left Half is still Control Option Left Arrow") == true,
                 "K1 VoiceOver hears the cancel and the kept shortcut (\(Announcements.log.last ?? "-"))")

        // ⌃⌥⎋ (Escape with modifiers) cancels too; it is never recorded.
        let again = f.counters
        let rec2 = f.beginRecording(.leftHalf)
        c.expect(rec2.testHandle(f.key(0x35, ctrlOpt)) == nil && !rec2.isRecording, "K1 ⌃⌥⎋ cancels")
        c.expect(f.app.prefs.shortcut(for: .leftHalf) == NoktaAction.leftHalf.defaultShortcut, "K1 ⌃⌥⎋ is not recorded")
        c.expect((f.counters - again).registered == 20, "K1 ⌃⌥⎋ cancel re-registers once")
        f.close()
    }

    // MARK: K2

    static func deleteClears(_ c: Checks) {
        let f = Fixture("kt.delete")
        var start = f.counters
        let rec = f.beginRecording(.leftHalf)
        c.expect(rec.testHandle(f.key(0x33)) == nil && !rec.isRecording, "K2 Delete while recording ends it")
        c.expect(f.app.prefs.shortcut(for: .leftHalf) == nil, "K2 Delete clears the shortcut")
        var d = f.counters - start
        c.expect(d.registered == 19 && f.counters.live == 19, "K2 the 19 others re-registered once, the cleared one not (+\(d.registered), live \(f.counters.live))")
        c.expect(Announcements.log.last == "Left Half shortcut cleared.", "K2 clear is announced")

        start = f.counters
        let rec2 = f.beginRecording(.rightHalf)
        c.expect(rec2.testHandle(f.key(0x75)) == nil && f.app.prefs.shortcut(for: .rightHalf) == nil, "K2 ⌦ clears")
        d = f.counters - start
        c.expect(d.registered == 18, "K2 ⌦: others re-registered once (+\(d.registered))")

        // ⌃⌥⌫ is a shortcut (Restore), not a clear.
        let rec3 = f.beginRecording(.topHalf)
        _ = rec3.testHandle(f.key(0x33, ctrlOpt))
        c.expect(f.app.prefs.shortcut(for: .topHalf) != nil, "K2 ⌃⌥⌫ is not a clear")
        f.app.prefs.setShortcut(NoktaAction.topHalf.defaultShortcut, for: .topHalf)
        f.app.prefs.setShortcut(NoktaAction.restore.defaultShortcut, for: .restore)

        // Not recording: Delete on the focused recorder, and on the selected row.
        let top = f.cell(.topHalf).recorder
        f.window.makeFirstResponder(top)
        top.keyDown(with: f.key(0x33))
        c.expect(f.app.prefs.shortcut(for: .topHalf) == nil, "K2 Delete on a focused recorder clears it")
        f.select(.bottomHalf)
        f.table.keyDown(with: f.key(0x33))
        c.expect(f.app.prefs.shortcut(for: .bottomHalf) == nil, "K2 Delete on a selected row clears it")
        c.expect(f.counters.live == 16 && f.app.shortcutSuspensionCount == 0, "K2 16 live after four clears, suspension balanced (live \(f.counters.live))")
        f.close()
    }

    // MARK: K3

    static func commitBindsOnce(_ c: Checks) {
        let f = Fixture("kt.commit")
        let start = f.counters
        let x = shortcut(0x07, ctrlOpt)
        let rec = f.beginRecording(.leftHalf)
        c.expect(rec.testHandle(f.key(0x07, ctrlOpt)) == nil && !rec.isRecording, "K3 ⌃⌥X is recorded")
        c.expect(f.app.prefs.shortcut(for: .leftHalf) == x, "K3 ⌃⌥X saved")
        let d = f.counters - start
        c.expect(d.registered == 20 && d.unregistered == 20, "K3 every shortcut registered once after recording (+\(d.registered) −\(d.unregistered))")
        c.expect(f.app.engine.boundShortcut(for: .leftHalf) == x && f.app.hotkeyResults[.leftHalf] == .ok, "K3 the core holds ⌃⌥X for Left Half")
        c.expect(Announcements.log.last == "Left Half shortcut set to Control Option X.", "K3 success announced after registering (\(Announcements.log.last ?? "-"))")
        c.expect(f.cell(.leftHalf).recorder.shortcut == x, "K3 the row shows the new shortcut")
        f.close()
    }

    // MARK: K4

    static func conflicts(_ c: Checks) {
        let f = Fixture("kt.conflict")
        let left = NoktaAction.leftHalf.defaultShortcut, right = NoktaAction.rightHalf.defaultShortcut
        let rec = f.beginRecording(.leftHalf)
        _ = rec.testHandle(f.key(0x7C, ctrlOpt)) // Right Half's ⌃⌥→
        let cell = f.cell(.leftHalf)
        c.expect(!rec.isRecording, "K4 a duplicate ends recording")
        c.expect(f.app.prefs.shortcut(for: .leftHalf) == left, "K4 the duplicate is not saved")
        c.expect(cell.noteLabel.stringValue == "Used by “Right Half”." && !cell.swapButton.isHidden && !cell.cancelButton.isHidden,
                 "K4 the row offers Swap / Cancel (\(cell.noteLabel.stringValue))")
        c.expect(f.window.firstResponder === cell.swapButton, "K4 focus moves to Swap")
        c.expect(f.counters.live == 20 && f.app.shortcutSuspensionCount == 0, "K4 shortcuts back (live \(f.counters.live))")
        let before = f.counters
        cell.swapButton.performClick(nil)
        c.expect(f.app.prefs.shortcut(for: .leftHalf) == right && f.app.prefs.shortcut(for: .rightHalf) == left, "K4 Swap exchanges the two")
        let d = f.counters - before
        c.expect(d.refused == 0 && f.app.engine.stats().hotkeys_failed == 0, "K4 Swap never asks for a combination still held (refused \(d.refused))")
        c.expect(f.app.hotkeyResults[.leftHalf] == .ok && f.app.hotkeyResults[.rightHalf] == .ok && f.counters.live == 20, "K4 both registered after Swap")
        c.expect(f.window.firstResponder === f.table, "K4 focus back on the list after Swap")

        // Cancel keeps both.
        let rec2 = f.beginRecording(.topHalf)
        _ = rec2.testHandle(f.key(0x7D, ctrlOpt)) // Bottom Half's ⌃⌥↓
        f.cell(.topHalf).cancelButton.performClick(nil)
        c.expect(f.app.prefs.shortcut(for: .topHalf) == NoktaAction.topHalf.defaultShortcut &&
                 f.app.prefs.shortcut(for: .bottomHalf) == NoktaAction.bottomHalf.defaultShortcut, "K4 Cancel keeps both")
        c.expect(f.cell(.topHalf).noteLabel.isHidden || f.cell(.topHalf).swapButton.isHidden, "K4 Cancel removes the prompt")
        f.close()
    }

    // MARK: K5

    static func refusals(_ c: Checks) {
        let f = Fixture("kt.refuse")
        let rec = f.beginRecording(.leftHalf)
        let cases: [(UInt16, NSEvent.ModifierFlags, String, String)] = [
            (0x00, [], "Add ⌃ or ⌥.", "A alone"),
            (0x00, [.shift], "Add ⌃ or ⌥.", "⇧A"),
            (0x24, [], "Add ⌃ or ⌥.", "Return alone"),
            (0x00, [.command], "Apps use ⌘ shortcuts. Add ⌃ or ⌥.", "⌘A"),
            (0x01, [.command, .shift], "Apps use ⌘ shortcuts. Add ⌃ or ⌥.", "⇧⌘S"),
            (0x7E, [.control], "macOS uses this shortcut.", "⌃↑ (Mission Control)"),
        ]
        for (key, flags, message, name) in cases {
            c.expect(rec.testHandle(f.key(key, flags)) == nil, "K5 \(name) is consumed")
            c.expect(rec.isRecording, "K5 \(name) keeps listening")
            c.expect(f.cell(.leftHalf).noteLabel.stringValue == message, "K5 \(name) says “\(message)” (got “\(f.cell(.leftHalf).noteLabel.stringValue)”)")
            c.expect(f.app.prefs.shortcut(for: .leftHalf) == NoktaAction.leftHalf.defaultShortcut, "K5 \(name) is not saved")
            c.expect(f.counters.live == 0, "K5 \(name): still nothing registered while listening")
        }
        c.expect(Announcements.log.last == "Control Up Arrow: macOS uses this shortcut.", "K5 the reason is announced (\(Announcements.log.last ?? "-"))")
        // The real lookup (read only): Carbon bits map to Nokta's, fn / caps lock do not count, and
        // this Mac reports its enabled system shortcuts (⌘⇥ is one on every Mac).
        c.expect(SystemShortcuts.modifiers(fromCarbon: 0x0900) == [.command, .option] &&
                 SystemShortcuts.modifiers(fromCarbon: 0x21000) == [.control] &&
                 SystemShortcuts.modifiers(fromCarbon: 0x0300) == [.command, .shift], "K5 Carbon modifier bits")
        let live = SystemShortcuts.symbolicHotKeys()
        c.expect(live.contains(shortcut(0x30, [.command])), "K5 CopySymbolicHotKeys is read (\(live.count) enabled; ⌘⇥ among them)")
        // F5 alone and ⌥A (option only) are allowed; ⌥ only carries its macOS 15.0–15.1 note.
        _ = rec.testHandle(f.key(0x60))
        c.expect(!rec.isRecording && f.app.prefs.shortcut(for: .leftHalf) == shortcut(0x60, []), "K5 F5 alone is accepted")
        let rec2 = f.beginRecording(.leftHalf)
        c.expect(f.cell(.leftHalf).noteLabel.isHidden || f.cell(.leftHalf).noteLabel.stringValue.isEmpty, "K5 a new recording clears the old reason")
        _ = rec2.testHandle(f.key(0x00, [.option]))
        c.expect(f.app.prefs.shortcut(for: .leftHalf) == shortcut(0x00, [.option]), "K5 ⌥A is accepted")
        c.expect(f.cell(.leftHalf).noteLabel.stringValue == "Option-only fails on macOS 15.0–15.1.", "K5 ⌥ only shows its note")
        c.expect(f.app.shortcutSuspensionCount == 0 && f.counters.live == 20, "K5 balanced, 20 live")
        f.close()
    }

    // MARK: K6

    static func takenByAnotherApp(_ c: Checks) {
        let x = shortcut(0x07, ctrlOpt)
        InertCore.setTaken(x, true)
        defer { InertCore.setTaken(x, false) }
        let f = Fixture("kt.taken")
        let start = f.counters
        let rec = f.beginRecording(.leftHalf)
        _ = rec.testHandle(f.key(0x07, ctrlOpt))
        c.expect(f.app.prefs.shortcut(for: .leftHalf) == NoktaAction.leftHalf.defaultShortcut, "K6 a refused registration keeps the previous shortcut")
        c.expect(f.app.hotkeyResults[.leftHalf] == .ok && f.app.engine.boundShortcut(for: .leftHalf) == NoktaAction.leftHalf.defaultShortcut,
                 "K6 the previous shortcut is registered again")
        c.expect(f.cell(.leftHalf).noteLabel.stringValue == "⌃⌥X is in use by another app. Kept ⌃⌥←.", "K6 the row says why (\(f.cell(.leftHalf).noteLabel.stringValue))")
        c.expect(Announcements.log.last == "Control Option X is in use by another app. Kept Control Option Left Arrow.", "K6 announced (\(Announcements.log.last ?? "-"))")
        let d = f.counters - start
        c.expect(d.refused == 1 && f.counters.live == 20 && f.app.engine.stats().hotkeys_failed == 0, "K6 one refusal, 20 live after (refused \(d.refused), live \(f.counters.live))")
        f.close()

        // Saved before (another app took it since): reported, never silently replaced.
        let saved = Fixture("kt.taken-saved") { $0.setShortcut(x, for: .leftHalf) }
        c.expect(saved.app.prefs.shortcut(for: .leftHalf) == x, "K6 a saved shortcut that fails at launch stays saved")
        c.expect(saved.app.hotkeyResults[.leftHalf] == .hotkey, "K6 its failure is known")
        saved.pane.refresh()
        settle()
        c.expect(saved.cell(.leftHalf).noteLabel.stringValue == "Taken by macOS or another app.", "K6 its row says so (\(saved.cell(.leftHalf).noteLabel.stringValue))")
        saved.close()
    }

    // MARK: K7

    static func captureIsolation(_ c: Checks) {
        let f = Fixture("kt.capture")
        f.app.voiceOverOverride = false
        let rec = f.beginRecording(.leftHalf)
        f.app.prefs.cycleSizes.toggle()                 // any preference change re-applies everything
        c.expect(f.counters.live == 0, "K7 a preference change while recording binds nothing (live \(f.counters.live))")
        f.app.voiceOverOverride = true
        f.app.applyPreferencesToEngine()                // the VoiceOver observer's path
        c.expect(f.counters.live == 0, "K7 VoiceOver changing while recording binds nothing")
        f.app.voiceOverOverride = false
        f.app.checkHealth()                             // wake, menu open, permission broadcast
        f.app.startEngine(bindShortcuts: true)          // permission regained, Resume
        c.expect(f.counters.live == 0 && f.app.engine.stats().started, "K7 a core restart while recording binds nothing (live \(f.counters.live))")
        f.app.setPaused(true)
        f.app.setPaused(false)
        c.expect(f.counters.live == 0, "K7 Pause / Resume while recording binds nothing")
        c.expect(rec.isRecording, "K7 recording survives all of it")
        let before = f.counters
        _ = rec.testHandle(f.key(0x35))
        c.expect((f.counters - before).registered == 20 && f.counters.live == 20, "K7 Escape then binds each shortcut once (+\((f.counters - before).registered))")
        c.expect(f.app.shortcutSuspensionCount == 0, "K7 balanced")
        f.app.prefs.cycleSizes.toggle()
        f.close()
    }

    // MARK: K8

    static func closeWhileRecording(_ c: Checks) {
        let f = Fixture("kt.close")
        let start = f.counters
        let rec = f.beginRecording(.leftHalf)
        f.window.close()
        c.expect(!rec.isRecording && f.app.shortcutSuspensionCount == 0, "K8 closing Settings ends recording")
        settle()
        let d = f.counters - start
        c.expect(d.registered == 20 && d.unregistered == 20 && f.counters.live == 20, "K8 closing restores each shortcut exactly once (+\(d.registered) −\(d.unregistered), live \(f.counters.live))")
        c.expect(f.app.prefs.shortcut(for: .leftHalf) == NoktaAction.leftHalf.defaultShortcut, "K8 closing keeps the shortcut")

        let g = Fixture("kt.remove")
        let start2 = g.counters
        let rec2 = g.beginRecording(.rightHalf)
        rec2.removeFromSuperview()
        c.expect(!rec2.isRecording && g.app.shortcutSuspensionCount == 0, "K8 a recorder leaving its window ends recording")
        c.expect((g.counters - start2).registered == 20, "K8 … and restores each shortcut once")
        // A window that is not key: recording does not start (it could never hear a key).
        ShortcutRecorder.requiresKeyWindow = true
        let rec3 = g.cell(.topHalf).recorder
        rec3.beginRecording()
        c.expect(!rec3.isRecording && g.app.shortcutSuspensionCount == 0 && g.counters.live == 20, "K8 no recording (and no suspension) outside the key window")
        ShortcutRecorder.requiresKeyWindow = false
        g.close()
    }

    // MARK: K9

    static func tabMovesOn(_ c: Checks) {
        let f = Fixture("kt.tab")
        // Which controls join the key loop depends on this Mac's Full Keyboard Access setting; an
        // editable text field always does. It follows (and precedes) the list, so the loop has a
        // stop that is not the list and a focus pulled back to the list shows.
        let field = NSTextField(string: "")
        f.pane.view.addSubview(field)
        f.table.nextKeyView = field
        field.nextKeyView = f.table
        let next = f.table.nextValidKeyView, previous = f.table.previousValidKeyView
        c.expect(next === field && previous === field, "K9 setup: the field follows and precedes the list")
        /// A text field's focus is its field editor's.
        func focused(_ view: NSView) -> Bool {
            let responder = f.window.firstResponder
            return responder === view || ((responder as? NSTextView)?.delegate as AnyObject?) === view
        }
        func focusName() -> String {
            let responder = f.window.firstResponder
            if focused(field) { return "the field" }
            return responder.map { "\(type(of: $0))" } ?? "nothing"
        }
        let rec = f.beginRecording(.leftHalf)
        c.expect(rec.testHandle(f.key(0x30)) == nil, "K9 Tab is consumed by the recorder")
        settle() // the recorder's end schedules its focus fix-up for the next turn
        c.expect(!rec.isRecording && f.app.shortcutSuspensionCount == 0, "K9 Tab ends recording")
        c.expect(f.app.prefs.shortcut(for: .leftHalf) == NoktaAction.leftHalf.defaultShortcut, "K9 Tab keeps the shortcut")
        c.expect(focused(field), "K9 Tab continues the key loop after the list and stays there (focus: \(focusName()))")

        let rec2 = f.beginRecording(.rightHalf)
        c.expect(rec2.testHandle(f.key(0x30, [.shift])) == nil && !rec2.isRecording, "K9 ⇧Tab ends recording (was refused as “⇧ only” before)")
        settle()
        c.expect(focused(field), "K9 ⇧Tab goes back from the list (focus: \(focusName()))")
        c.expect(f.app.prefs.shortcut(for: .rightHalf) == NoktaAction.rightHalf.defaultShortcut, "K9 ⇧Tab keeps the shortcut")

        // Escape leaves the focus on the list's row (a keyboard user started there).
        let rec4 = f.beginRecording(.bottomHalf)
        _ = rec4.testHandle(f.key(0x35))
        settle()
        c.expect(f.window.firstResponder === f.table, "K9 Escape returns the focus to the list (focus: \(focusName()))")

        // A recorder focused by a click (outside the key loop) passes Tab on too.
        let rec3 = f.cell(.topHalf).recorder
        f.window.makeFirstResponder(rec3)
        rec3.keyDown(with: f.key(0x30))
        c.expect(focused(field), "K9 Tab from a clicked recorder continues after the list (focus: \(focusName()))")
        _ = (next, previous)
        c.expect(f.counters.live == 20 && f.app.shortcutSuspensionCount == 0, "K9 balanced")
        f.close()
    }

    // MARK: K10

    static func layouts(_ c: Checks) {
        let us = KeyboardLayout.installed(id: "com.apple.keylayout.US")
        let tr = KeyboardLayout.installed(id: "com.apple.keylayout.Turkish-QWERTY-PC")
        c.expect(us != nil && tr != nil, "K10 US and Turkish Q layouts readable")
        guard let us, let tr else { return }
        let labels: [(UInt32, String, String)] = [
            (0x22, "I", "I"), (0x27, "'", "İ"), (0x21, "[", "Ğ"), (0x1E, "]", "Ü"), (0x29, ";", "Ş"),
            (0x2B, ",", "Ö"), (0x2F, ".", "Ç"), (0x7B, "←", "←"), (0x60, "F5", "F5"), (0x41, "Num .", "Num ,"),
        ]
        for (code, usLabel, trLabel) in labels {
            c.expect(KeyNames.name(for: code, layout: us) == usLabel, "K10 key 0x\(String(code, radix: 16)) on US reads \(usLabel) (got \(KeyNames.name(for: code, layout: us)))")
            c.expect(KeyNames.name(for: code, layout: tr) == trLabel, "K10 key 0x\(String(code, radix: 16)) on Turkish Q reads \(trLabel) (got \(KeyNames.name(for: code, layout: tr)))")
        }
        c.expect(KeyNames.keyEquivalent(for: 0x21, layout: tr) == "ğ" && KeyNames.keyEquivalent(for: 0x27, layout: tr) == "i" &&
                 KeyNames.keyEquivalent(for: 0x22, layout: tr) == "ı", "K10 menu key equivalents follow the layout")
        c.expect(KeyNames.name(for: 0x21, layout: nil) == "[", "K10 no layout data: ANSI labels")
        let de = KeyboardLayout.installed(id: "com.apple.keylayout.German")
        c.expect(de.map { KeyNames.name(for: 0x1B, layout: $0) } == "ß", "K10 German ß stays one key (got \(de.map { KeyNames.name(for: 0x1B, layout: $0) } ?? "-"))")

        // Recording on Turkish Q stores the key POSITION; the label follows the layout.
        KeyNames.layoutOverride = tr
        defer { KeyNames.layoutOverride = us }
        let f = Fixture("kt.layout")
        let rec = f.beginRecording(.leftHalf)
        _ = rec.testHandle(f.key(0x21, [.control, .shift, .command]))
        let stored = f.app.prefs.shortcut(for: .leftHalf)
        c.expect(stored == shortcut(0x21, [.control, .shift, .command]), "K10 the stored identity is the key code (0x21)")
        c.expect(stored?.displayString == "⌃⇧⌘Ğ", "K10 Turkish Q shows ⌃⇧⌘Ğ (got \(stored?.displayString ?? "-"))")
        c.expect(stored.map(ShortcutSpeech.spoken) == "Control Shift Command Ğ", "K10 spoken on Turkish Q")
        KeyNames.layoutOverride = us
        c.expect(stored?.displayString == "⌃⇧⌘[" && stored.map(ShortcutSpeech.spoken) == "Control Shift Command Left Bracket",
                 "K10 the same stored shortcut reads ⌃⇧⌘[ on US")
        let reloaded = Preferences(defaults: f.defaults).shortcut(for: .leftHalf)
        c.expect(reloaded == stored, "K10 the stored shortcut does not depend on the layout")

        // The status menu names the same key as Settings.
        f.app.prefs.applyShortcutSet(.alternate)
        let menu = StatusMenuController(app: f.app, installStatusItem: false)
        for (layout, expected) in [(tr, "ü"), (us, "]")] {
            KeyNames.layoutOverride = layout
            menu.rebuild()
            let item = menu.menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.tag == Int(NoktaAction.nextDisplay.rawValue) }
            c.expect(item?.keyEquivalent == expected && item?.allowsAutomaticKeyEquivalentLocalization == false,
                     "K10 menu Next Display on \(layout.id) shows \(expected) (got \(item?.keyEquivalent ?? "-"))")
        }
        f.close()
    }

    // MARK: K11

    static func presetsAndSavedSettings(_ c: Checks) {
        let f = Fixture("kt.presets")
        let before = f.counters
        f.app.prefs.applyShortcutSet(.alternate)
        c.expect(f.app.prefs.currentShortcutSet == .alternate && f.counters.live == 20, "K11 Alternate set applied and registered")
        // A permutation inside Nokta (a swap), then a set that undoes it: never a refused registration.
        let up = NoktaAction.topHalf.defaultShortcut, left = NoktaAction.leftHalf.defaultShortcut
        f.app.prefs.applyShortcutSet(.classic)
        f.app.prefs.setShortcuts([(.leftHalf, up), (.topHalf, left)])
        f.app.prefs.applyShortcutSet(.classic)
        let d = f.counters - before
        c.expect(d.refused == 0 && f.app.engine.stats().hotkeys_failed == 0 && f.counters.live == 20, "K11 set changes and permutations bind in two passes (refused \(d.refused))")

        // Saved custom shortcuts survive a relaunch and are what gets bound.
        let x = shortcut(0x07, ctrlOpt)
        f.app.prefs.setShortcut(x, for: .leftHalf)
        let relaunch = AppController(defaults: f.defaults, bench: .none)
        relaunch.startEngine(bindShortcuts: true)
        c.expect(relaunch.prefs.shortcut(for: .leftHalf) == x && relaunch.engine.boundShortcut(for: .leftHalf) == x, "K11 a relaunch binds the saved custom shortcut")
        relaunch.engine.stop()

        // Restore Defaults asks before replacing custom shortcuts; Cancel keeps them.
        f.pane.testAlertResponse = .alertSecondButtonReturn
        f.button("Restore Defaults")?.performClick(nil)
        c.expect(f.pane.testAlertTitles.last == "Restore the default shortcuts?" && f.app.prefs.shortcut(for: .leftHalf) == x,
                 "K11 Restore Defaults asks first; Cancel keeps custom shortcuts")
        f.pane.testAlertResponse = .alertFirstButtonReturn
        f.button("Restore Defaults")?.performClick(nil)
        c.expect(f.app.prefs.shortcut(for: .leftHalf) == left && !f.app.prefs.shortcutsCustomized, "K11 Restore puts the defaults back")
        // A set is not custom: back to the defaults without a question.
        f.app.prefs.applyShortcutSet(.alternate)
        let asked = f.pane.testAlertTitles.count
        f.button("Restore Defaults")?.performClick(nil)
        c.expect(f.pane.testAlertTitles.count == asked && f.app.prefs.currentShortcutSet == .classic, "K11 from the Alternate set, no question")

        // VoiceOver's Alternate default only replaces untouched defaults (DESIGN §11).
        let fresh = Preferences(defaults: ScratchDefaults(suiteName: "kt.vo")!)
        c.expect(OnboardingWindowController.wantsVoiceOverSet(voiceOver: true, prefs: fresh), "K11 untouched defaults + VoiceOver → Alternate")
        c.expect(!OnboardingWindowController.wantsVoiceOverSet(voiceOver: false, prefs: fresh), "K11 no VoiceOver → no change")
        fresh.applyShortcutSet(.classic)
        c.expect(!OnboardingWindowController.wantsVoiceOverSet(voiceOver: true, prefs: fresh), "K11 a Classic set the user chose is never replaced")
        f.close()
    }

    // MARK: K12

    static func voiceOver(_ c: Checks) {
        let f = Fixture("kt.vo-recorder")
        let rec = f.cell(.leftHalf).recorder
        c.expect(rec.accessibilityRole() == .button && rec.accessibilityLabel() == "Left Half shortcut", "K12 role button, label names the action")
        c.expect(rec.accessibilityValue() as? String == "Control Option Left Arrow", "K12 value speaks the shortcut")
        c.expect(rec.accessibilityHelp()?.contains("Escape cancels") == true && rec.accessibilityHelp()?.contains("Tab moves on") == true, "K12 help names the keys")
        c.expect(rec.accessibilityCustomActions()?.map(\.name) == ["Clear shortcut"], "K12 Clear is a custom action")
        let recording = f.beginRecording(.leftHalf)
        c.expect(recording.accessibilityValue() as? String == "Recording", "K12 value while recording")
        _ = recording.testHandle(f.key(0x35))
        c.expect(f.cell(.leftHalf).clearButton.accessibilityLabel() == "Clear Left Half shortcut", "K12 the × button is labelled")
        f.close()
    }
}

/// One Settings › Shortcuts on a fresh AppController with in-memory preferences, the core started
/// (inert, "trusted" through NOKTA_SNAPSHOT_TRUSTED) and the window built but never shown.
final class Fixture {
    let defaults: ScratchDefaults
    let app: AppController
    let settings: SettingsWindowController
    let pane: ShortcutsPane
    let table: ShortcutTableView
    var window: NSWindow { settings.window! }

    init(_ name: String, setup: (Preferences) -> Void = { _ in }) {
        defaults = ScratchDefaults(suiteName: name)!
        app = AppController(defaults: defaults, bench: .none)
        setup(app.prefs)
        app.observeSystem()
        app.startEngine(bindShortcuts: true)
        settings = app.testAttachSettings(tab: .shortcuts)
        pane = settings.pane(.shortcuts) as! ShortcutsPane
        _ = pane.view
        pane.viewWillAppear()
        table = Fixture.first(ShortcutTableView.self, in: pane.view)!
        settings.window?.contentView?.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
    }

    static func first<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let match = view as? V { return match }
        for sub in view.subviews { if let match = first(type, in: sub) { return match } }
        return nil
    }

    func button(_ title: String) -> NSButton? {
        func find(_ view: NSView) -> NSButton? {
            if let b = view as? NSButton, b.title == title { return b }
            for sub in view.subviews { if let b = find(sub) { return b } }
            return nil
        }
        return find(pane.view)
    }

    var counters: InertCore.Counters { InertCore.counters(app.engine) }

    static let rows: [NoktaAction?] = NoktaAction.Group.allCases.flatMap { group in
        [nil] + NoktaAction.allCases.filter { $0.group == group }.map { Optional($0) }
    }

    func row(_ action: NoktaAction) -> Int { Fixture.rows.firstIndex(of: action)! }

    func cell(_ action: NoktaAction) -> ShortcutCellView {
        let index = row(action)
        table.scrollRowToVisible(index)
        table.layoutSubtreeIfNeeded()
        return table.view(atColumn: 0, row: index, makeIfNecessary: true) as! ShortcutCellView
    }

    func select(_ action: NoktaAction) {
        _ = cell(action)
        table.selectRowIndexes(IndexSet(integer: row(action)), byExtendingSelection: false)
        window.makeFirstResponder(table)
    }

    /// Space on the selected row, as a user of the keyboard starts recording.
    func beginRecording(_ action: NoktaAction) -> ShortcutRecorder {
        select(action)
        table.keyDown(with: key(0x31))
        return cell(action).recorder
    }

    func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)!
    }

    /// Ends the fixture like the app would: the window closes, the core stops.
    func close() {
        if window.isVisible || window.contentViewController != nil { window.close() }
        settle()
        app.engine.stop()
    }
}
