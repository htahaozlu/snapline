import Foundation

/// Why a recorded combination cannot become a Nokta shortcut. The recorder shows the message and
/// keeps listening; nothing is saved and the previous shortcut stays bound.
enum ShortcutProblem: Equatable {
    /// No modifier, or only ⇧, on a key that is not a function key: it would take the key from typing.
    case needsModifier
    /// Only ⌘ (or ⇧⌘): apps use these for their own commands (⌘C, ⇧⌘S, ⌘←); a global hotkey would
    /// take them from every app.
    case commandOnly
    /// macOS itself uses it: an enabled shortcut in System Settings › Keyboard › Keyboard Shortcuts
    /// (Mission Control, Spotlight, screenshots, input sources …) or a fixed system key.
    case reservedBySystem

    var message: String {
        switch self {
        case .needsModifier: return "Add ⌃ or ⌥."
        case .commandOnly: return "Apps use ⌘ shortcuts. Add ⌃ or ⌥."
        case .reservedBySystem: return "macOS uses this shortcut."
        }
    }
}

enum ShortcutPolicy {
    /// nil = usable. `reserved`: the system's shortcuts (`SystemShortcuts.reserved()`), read by
    /// the caller once per check burst.
    static func problem(with s: Shortcut, reserved: [Shortcut]) -> ShortcutProblem? {
        guard s.isAllowedBySystem else { return .needsModifier }
        let m = s.modifiers
        if (m == [.command] || m == [.command, .shift]), !Shortcut.functionKeys.contains(s.keyCode) { return .commandOnly }
        if reserved.contains(s) { return .reservedBySystem }
        return nil
    }
}

/// Shortcuts macOS keeps for itself. Read only: nothing here registers, changes or observes a key.
enum SystemShortcuts {
    /// Keys the system handles before any app and that System Settings does not list:
    /// ⌘⇥ / ⇧⌘⇥ (app switcher), ⌥⌘⎋ (Force Quit), ⌃⌘Q (Lock Screen), ⌥⇧⌘Q (Log Out at once).
    static let fixed: [Shortcut] = {
        let cmd = NoktaMods.command, shift = NoktaMods.shift, opt = NoktaMods.option, ctrl = NoktaMods.control
        return [
            Shortcut(keyCode: 0x30, mods: cmd.rawValue),
            Shortcut(keyCode: 0x30, mods: cmd.union(shift).rawValue),
            Shortcut(keyCode: 0x35, mods: cmd.union(opt).rawValue),
            Shortcut(keyCode: 0x0C, mods: cmd.union(ctrl).rawValue),
            Shortcut(keyCode: 0x0C, mods: cmd.union(opt).union(shift).rawValue),
        ]
    }()

    #if NOKTA_SNAPSHOT
    /// Tests: a fixed list instead of this Mac's settings.
    static var override: [Shortcut]?
    #endif

    /// The fixed keys plus every ENABLED symbolic hot key of this user (CopySymbolicHotKeys).
    static func reserved() -> [Shortcut] {
        #if NOKTA_SNAPSHOT
        if let override { return override }
        #endif
        return fixed + symbolicHotKeys()
    }

    private typealias CopySymbolicHotKeysFn = @convention(c) (UnsafeMutablePointer<Unmanaged<CFArray>?>) -> OSStatus

    /// HIToolbox's CopySymbolicHotKeys: documented Carbon API, still exported, no longer declared in
    /// the SDK headers. Resolved with dlsym (like HIWindowGetAvailablePositioningBounds in the core),
    /// so a macOS without it only loses this check (empty list), never the launch.
    private static let copySymbolicHotKeys: CopySymbolicHotKeysFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CopySymbolicHotKeys") else { return nil }
        return unsafeBitCast(sym, to: CopySymbolicHotKeysFn.self)
    }()

    static func symbolicHotKeys() -> [Shortcut] {
        guard let copy = copySymbolicHotKeys else { return [] }
        var out: Unmanaged<CFArray>?
        guard copy(&out) == 0, let entries = out?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var result: [Shortcut] = []
        for entry in entries {
            guard (entry["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true,
                  let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value, code <= 0x7F,
                  let carbon = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { continue }
            result.append(Shortcut(keyCode: code, mods: modifiers(fromCarbon: carbon).rawValue))
        }
        return result
    }

    /// Carbon modifier bits (Events.h: cmdKey, shiftKey, optionKey, controlKey) → Nokta's; other
    /// bits (fn on arrows and F-keys, caps lock) do not change which shortcut it is.
    static func modifiers(fromCarbon carbon: UInt32) -> NoktaMods {
        var m: NoktaMods = []
        if carbon & 0x0100 != 0 { m.insert(.command) }
        if carbon & 0x0200 != 0 { m.insert(.shift) }
        if carbon & 0x0800 != 0 { m.insert(.option) }
        if carbon & 0x1000 != 0 { m.insert(.control) }
        return m
    }
}
