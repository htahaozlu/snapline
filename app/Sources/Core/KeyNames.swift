import AppKit
import Carbon

extension Notification.Name {
    /// Posted (object: nil) after the keyboard layout changed: shortcut labels may read differently.
    static let noktaKeyboardLayoutChanged = Notification.Name("NoktaKeyboardLayoutChanged")
}

/// Key code → label. A shortcut's identity is its virtual key code: a key POSITION, the same on every
/// keyboard layout. That is what Carbon registers and what preferences store, so a shortcut keeps
/// working when the layout changes. Only its LABEL follows the layout in use: the key left of
/// Return reads "'" on US and "İ" on Turkish Q, kVK_ANSI_LeftBracket reads "[" on US and "Ğ" on
/// Turkish Q, while the stored shortcut is the same key code. Named keys (arrows, Return, F-keys …)
/// have fixed symbols; everything else comes from the current layout (UCKeyTranslate, unshifted, no
/// dead keys), with the ANSI table as the fallback.
enum KeyNames {
    /// Named keys: symbol and NSMenuItem key equivalent ("" = none).
    private static let specialKeys: [UInt32: (label: String, equivalent: String)] = [
        0x24: ("↩", "\r"), 0x30: ("⇥", "\t"), 0x31: ("Space", " "), 0x33: ("⌫", "\u{8}"),
        0x35: ("⎋", "\u{1b}"), 0x75: ("⌦", "\u{7f}"), 0x73: ("↖", ""), 0x77: ("↘", ""),
        0x74: ("⇞", ""), 0x79: ("⇟", ""), 0x72: ("Help", "\u{F746}"),
        0x7B: ("←", "\u{F702}"), 0x7C: ("→", "\u{F703}"), 0x7D: ("↓", "\u{F701}"), 0x7E: ("↑", "\u{F700}"),
        0x7A: ("F1", "\u{F704}"), 0x78: ("F2", "\u{F705}"), 0x63: ("F3", "\u{F706}"), 0x76: ("F4", "\u{F707}"),
        0x60: ("F5", "\u{F708}"), 0x61: ("F6", "\u{F709}"), 0x62: ("F7", "\u{F70A}"), 0x64: ("F8", "\u{F70B}"),
        0x65: ("F9", "\u{F70C}"), 0x6D: ("F10", "\u{F70D}"), 0x67: ("F11", "\u{F70E}"), 0x6F: ("F12", "\u{F70F}"),
        0x69: ("F13", "\u{F710}"), 0x6B: ("F14", "\u{F711}"), 0x71: ("F15", "\u{F712}"), 0x6A: ("F16", "\u{F713}"),
        0x40: ("F17", "\u{F714}"), 0x4F: ("F18", "\u{F715}"), 0x50: ("F19", "\u{F716}"), 0x5A: ("F20", "\u{F717}"),
        0x4C: ("⌤", ""), 0x47: ("⌧", ""),
    ]

    private static func special(_ keyCode: UInt32) -> (label: String, equivalent: String)? { specialKeys[keyCode] }

    private static let ansi: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6",
        0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0", 0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]",
        0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x2A: "\\", 0x32: "`", 0x0A: "§",
        0x41: ".", 0x43: "*", 0x45: "+", 0x4B: "/", 0x4E: "-", 0x51: "=",
        0x52: "0", 0x53: "1", 0x54: "2", 0x55: "3", 0x56: "4", 0x57: "5", 0x58: "6", 0x59: "7", 0x5B: "8", 0x5C: "9",
    ]

    private static func ansiCharacter(_ keyCode: UInt32) -> String? { ansi[keyCode] }

    /// Numeric keypad keys share their characters with main-block keys: their labels say so.
    private static let keypad: Set<UInt32> = [0x41, 0x43, 0x45, 0x4B, 0x4E, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]

    static func isKeypad(_ keyCode: UInt32) -> Bool { keypad.contains(keyCode) }

    /// The character the key types on `layout` (or ANSI), upper-cased the way that layout's
    /// language does it (Turkish: i → İ, ı → I). nil for named keys and unknown key codes.
    static func character(for keyCode: UInt32, layout: KeyboardLayout? = KeyNames.layout) -> String? {
        guard special(keyCode) == nil else { return nil }
        if let layout, let c = layout.character(for: keyCode) {
            let upper = c.uppercased(with: layout.locale)
            return upper.count == 1 ? upper : c // German ß stays ß (its upper case "SS" is two keys' worth)
        }
        return ansiCharacter(keyCode)
    }

    static func name(for keyCode: UInt32, layout: KeyboardLayout? = KeyNames.layout) -> String {
        if let s = special(keyCode) { return s.label }
        guard let c = character(for: keyCode, layout: layout) else { return String(format: "0x%02X", keyCode) }
        return isKeypad(keyCode) ? "Num " + c : c
    }

    /// For NSMenuItem.keyEquivalent (display only, with automatic key equivalent localization off):
    /// the lower-case character of the current layout, so the menu names the same key as Settings.
    static func keyEquivalent(for keyCode: UInt32, layout: KeyboardLayout? = KeyNames.layout) -> String {
        if let s = special(keyCode) { return s.equivalent }
        guard !isKeypad(keyCode) else { return "" }
        if let layout, let c = layout.character(for: keyCode) { return c.lowercased(with: layout.locale) }
        return (ansiCharacter(keyCode) ?? "").lowercased()
    }

    // MARK: current layout

    /// Labels for offscreen renders and tests: a fixed layout instead of the user's.
    #if NOKTA_SNAPSHOT
    static var layoutOverride: KeyboardLayout?
    #endif

    /// nil inside = no layout data (labels fall back to ANSI); nil outside = not looked up yet.
    private static var cached: KeyboardLayout??
    private static var watcher: LayoutWatcher?

    /// The keyboard layout labels come from. Looked up once (about 20 µs) and kept until the system
    /// reports a new input source; nothing polls.
    static var layout: KeyboardLayout? {
        #if NOKTA_SNAPSHOT
        if let layoutOverride { return layoutOverride }
        #endif
        if let cached { return cached }
        let current = KeyboardLayout.current()
        cached = .some(current)
        if watcher == nil { watcher = LayoutWatcher() }
        return current
    }

    fileprivate static func layoutChanged() {
        cached = nil
        NotificationCenter.default.post(name: .noktaKeyboardLayoutChanged, object: nil)
    }
}

/// Watches the system's input-source broadcast (event driven; delivered while Nokta is inactive,
/// which it almost always is).
private final class LayoutWatcher: NSObject {
    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    @objc private func changed(_ note: Notification) {
        DispatchQueue.main.async { KeyNames.layoutChanged() }
    }
}

/// One keyboard layout's character table ('uchr' data, read with UCKeyTranslate). Read only.
struct KeyboardLayout {
    let id: String
    /// The layout's first language: how its letters are upper-cased.
    let locale: Locale
    private let data: Data

    init?(source: TISInputSource) {
        func property(_ key: CFString) -> AnyObject? {
            TISGetInputSourceProperty(source, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
        }
        guard let data = property(kTISPropertyUnicodeKeyLayoutData) as? Data, !data.isEmpty else { return nil }
        self.data = data
        id = property(kTISPropertyInputSourceID) as? String ?? ""
        locale = Locale(identifier: (property(kTISPropertyInputSourceLanguages) as? [String])?.first ?? "en")
    }

    /// The layout in use for typing (an input method's own layout when one is active).
    static func current() -> KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return KeyboardLayout(source: source)
    }

    #if NOKTA_SNAPSHOT
    /// An installed layout by id (enabled or not), e.g. "com.apple.keylayout.US". Offscreen tools only.
    static func installed(id: String) -> KeyboardLayout? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return nil }
        return KeyboardLayout(source: source)
    }
    #endif

    /// The character `keyCode` types without modifiers; nil for keys that type nothing printable.
    func character(for keyCode: UInt32) -> String? {
        guard keyCode <= 0x7F else { return nil }
        let text: String? = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(base, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
        guard let text, let scalar = text.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), !CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
        return text
    }
}
