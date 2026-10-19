import AppKit
import NoktaCore

/// Window actions. Raw values mirror `nk_action` in nokta.h.
enum NoktaAction: UInt32, CaseIterable, Identifiable {
    case leftHalf = 1, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird
    case firstTwoThirds, centerTwoThirds, lastTwoThirds
    case maximize, almostMaximize, center, restore
    case nextDisplay, prevDisplay

    /// Stable persistence id from the core ("left-half", ...).
    var id: String { String(cString: nk_action_id(nk_action(rawValue: rawValue))) }

    init?(id: String) {
        let raw = id.withCString { nk_action_from_id($0) }
        guard raw.rawValue != 0 else { return nil }
        self.init(rawValue: raw.rawValue)
    }

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .firstThird: return "First Third"
        case .centerThird: return "Middle Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .centerTwoThirds: return "Middle Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .center: return "Center"
        case .restore: return "Restore"
        case .nextDisplay: return "Next Display"
        case .prevDisplay: return "Previous Display"
        }
    }

    /// Menu/settings grouping.
    enum Group: String, CaseIterable { case halves, quarters, thirds, size, display }
    var group: Group {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return .halves
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .quarters
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds: return .thirds
        case .maximize, .almostMaximize, .center, .restore: return .size
        case .nextDisplay, .prevDisplay: return .display
        }
    }

    var defaultShortcut: Shortcut? {
        var key: UInt32 = 0, mods: UInt32 = 0
        nk_default_hotkey(nk_action(rawValue: rawValue), &key, &mods)
        return key == UInt32(NK_KEY_NONE) ? nil : Shortcut(keyCode: key, mods: mods)
    }
}

/// Drag zones. Raw values mirror `nk_zone`.
enum NoktaZone: UInt32, CaseIterable {
    case left = 1, right, top, topLeft, topRight, bottomLeft, bottomRight
    case bottomLeftSegment, bottomCenterSegment, bottomRightSegment

    var id: String { String(cString: nk_zone_id(nk_zone(rawValue: rawValue))) }

    func defaultAction(alternate: Bool) -> NoktaAction? {
        NoktaAction(rawValue: nk_default_zone_action(nk_zone(rawValue: rawValue), alternate).rawValue)
    }
}

/// Modifier bits shared with the core (NK_MOD_*).
struct NoktaMods: OptionSet, Codable, Hashable {
    let rawValue: UInt32
    static let shift = NoktaMods(rawValue: UInt32(NK_MOD_SHIFT))
    static let control = NoktaMods(rawValue: UInt32(NK_MOD_CONTROL))
    static let option = NoktaMods(rawValue: UInt32(NK_MOD_OPTION))
    static let command = NoktaMods(rawValue: UInt32(NK_MOD_COMMAND))

    init(rawValue: UInt32) { self.rawValue = rawValue }

    init(_ flags: NSEvent.ModifierFlags) {
        var m: NoktaMods = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }

    /// ⌃⌥⇧⌘ in Apple's canonical order.
    var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A global shortcut: Carbon virtual key code + Nokta modifier mask.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var mods: UInt32

    var modifiers: NoktaMods { NoktaMods(rawValue: mods) }

    /// F1 … F20 (kVK_F1 …).
    static let functionKeys: Set<UInt32> = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
                                            0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]

    /// A shortcut needs a modifier unless it is a function key (or ⇧ + function key).
    var isAllowedBySystem: Bool {
        let m = modifiers
        if m.isEmpty || m == [.shift] { return Self.functionKeys.contains(keyCode) }
        return true
    }

    /// macOS 15.0–15.1 refused global hotkeys whose only modifiers are ⌥ or ⌥⇧ (relaxed in
    /// 15.2). Recorders warn instead of rejecting; the real outcome is the registration result.
    var optionOnlyWarning: Bool {
        let m = modifiers
        return m == [.option] || m == [.option, .shift]
    }

    /// Human readable, e.g. "⌃⌥←".
    var displayString: String { modifiers.symbols + KeyNames.name(for: keyCode) }

    /// For NSMenuItem.keyEquivalent / keyEquivalentModifierMask (display only).
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return (KeyNames.keyEquivalent(for: keyCode), flags)
    }
}

enum NoktaResult: Int32 {
    case ok = 0, notTrusted, noWindow, ax, excluded, invalid, notMovable, noMemory, eventTap, hotkey, notStarted

    init(_ r: nk_result) { self = NoktaResult(rawValue: Int32(bitPattern: r.rawValue)) ?? .invalid }

    var message: String {
        switch self {
        case .ok: return "OK"
        case .notTrusted: return "Accessibility permission is missing."
        case .noWindow: return "No window to move."
        case .ax: return "The app did not respond to the move."
        case .excluded: return "This app is excluded."
        case .invalid: return "Nothing to do."
        case .notMovable: return "This window cannot be moved."
        case .noMemory: return "Out of memory."
        case .eventTap: return "Drag snapping could not start."
        case .hotkey: return "Shortcut is already used by another app."
        case .notStarted: return "\(Product.name) is not running."
        }
    }
}

/// Events from the core, already converted. `rect` stays in CG global coordinates
/// (top-left origin); use `Screens.appKitRect(fromCG:)` for AppKit windows.
struct NoktaEvent {
    enum Kind: UInt32 { case previewShow = 1, previewHide, snapped, failed, hotkeyState }
    enum Source: UInt32 { case keyboard = 1, drag, menu }

    let kind: Kind
    let action: NoktaAction?
    let zone: NoktaZone?
    let source: Source?
    let result: NoktaResult
    let displayID: CGDirectDisplayID
    let cycle: UInt32
    let rect: CGRect
    let latencyNs: UInt64
    /// The window came out LARGER than the requested frame (minimum size) and was re-aligned
    /// to the edge the tile hugs; `rect` is the actual frame.
    let frameDiffers: Bool
    /// The window refused the size change (fixed-size window): it was only moved and keeps its
    /// size; `rect` is the actual frame.
    let sizeRefused: Bool
    /// `previewHide` only: the drag ended over a zone and the drop will be applied (a `snapped`
    /// or `failed` event follows). false = the preview was cancelled.
    let drop: Bool
}

enum Screens {
    /// CG global (top-left origin) → AppKit global (bottom-left origin of the primary screen).
    static func appKitRect(fromCG r: CGRect) -> CGRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Usable frame per display as AppKit enforces it, in CG global coordinates: the
    /// visibleFrame with its top edge moved down 1 pt. Measured on this project's machines:
    /// windows are pushed to menu-bar bottom + 1 (y 31 on a 30 pt menu bar, y 1113 on a
    /// notched 32 pt built-in); targeting higher makes some apps shrink the window.
    static func coreUsableFrames() -> [(CGDirectDisplayID, CGRect)] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { return nil }
            var r = appKitRect(fromCG: screen.visibleFrame) // the flip is its own inverse
            let hasMenuBarGap = screen.visibleFrame.maxY < screen.frame.maxY
            if hasMenuBarGap { r.origin.y += 1; r.size.height -= 1 }
            return (id, r)
        }
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}

/// Thin Swift owner of the `nk_core` handle. Main thread only.
final class NoktaEngine {
    private(set) var core: OpaquePointer?
    /// Called on the main thread for every core event.
    var onEvent: ((NoktaEvent) -> Void)?

    init(config: nk_config) {
        var cfg = config
        core = nk_core_create(&cfg, { userdata, raw in
            guard let userdata, let raw else { return }
            let engine = Unmanaged<NoktaEngine>.fromOpaque(userdata).takeUnretainedValue()
            engine.dispatch(raw.pointee)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        if let core { nk_core_destroy(core) }
    }

    static var defaultConfig: nk_config {
        var c = nk_config()
        nk_config_default(&c)
        return c
    }

    static func isTrusted(prompt: Bool = false) -> Bool { nk_ax_is_trusted(prompt) }

    static var version: String { String(cString: nk_version_string()) }

    @discardableResult
    func start() -> NoktaResult {
        guard let core else { return .noMemory }
        return NoktaResult(nk_core_start(core))
    }

    func stop() {
        if let core { nk_core_stop(core) }
    }

    @discardableResult
    func apply(config: nk_config) -> NoktaResult {
        guard let core else { return .noMemory }
        var c = config
        return NoktaResult(nk_core_set_config(core, &c))
    }

    /// What the core's hotkey table holds per action, indexed by raw value − 1 (mirrors every
    /// `bind`; the core keeps its table across stop/start, and so does this).
    private var boundTable = [Shortcut?](repeating: nil, count: NoktaAction.allCases.count)

    func boundShortcut(for action: NoktaAction) -> Shortcut? { boundTable[Int(action.rawValue) - 1] }

    @discardableResult
    func bind(_ action: NoktaAction, to shortcut: Shortcut?) -> NoktaResult {
        guard let core else { return .noMemory }
        let key = shortcut?.keyCode ?? UInt32(NK_KEY_NONE)
        boundTable[Int(action.rawValue) - 1] = shortcut
        return NoktaResult(nk_core_bind_hotkey(core, nk_action(rawValue: action.rawValue), key, shortcut?.mods ?? 0))
    }

    /// Binds every action (`table`: one shortcut per action, in `NoktaAction.allCases` order) in two
    /// passes: first every action whose shortcut changes lets go of its old one, then every action
    /// takes its new one. Bound one by one in action order, a swap or a set change would ask Carbon
    /// for a combination another action of Nokta still holds (that registration fails) a moment
    /// before that action moves on. Unchanged live bindings are not touched (the core skips them);
    /// a binding that failed before is tried again. Returns the outcomes in the same order.
    @discardableResult
    func bind(all table: [Shortcut?]) -> [NoktaResult] {
        let actions = NoktaAction.allCases
        for (action, wanted) in zip(actions, table) {
            let bound = boundShortcut(for: action)
            if bound != nil, bound != wanted { bind(action, to: nil) }
        }
        return zip(actions, table).map { bind($0, to: $1) }
    }

    @discardableResult
    func setZone(_ zone: NoktaZone, alternate: Bool, action: NoktaAction?) -> NoktaResult {
        guard let core else { return .noMemory }
        return NoktaResult(nk_core_set_zone_action(core, nk_zone(rawValue: zone.rawValue), alternate, nk_action(rawValue: action?.rawValue ?? 0)))
    }

    @discardableResult
    func setExcluded(_ bundleIDs: [String]) -> NoktaResult {
        guard let core else { return .noMemory }
        let cStrings = bundleIDs.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        return ptrs.withUnsafeMutableBufferPointer { buf in
            NoktaResult(nk_core_set_excluded(core, buf.baseAddress, UInt32(buf.count)))
        }
    }

    func appActivated(pid: pid_t, bundleID: String?) {
        guard let core else { return }
        if let bundleID {
            bundleID.withCString { nk_core_app_activated(core, pid, $0) }
        } else {
            nk_core_app_activated(core, pid, nil)
        }
    }

    func displaysChanged() {
        if let core { nk_core_displays_changed(core) }
    }

    /// Replaces every display usable-frame override with the current AppKit geometry.
    func pushScreenGeometry() {
        guard let core else { return }
        nk_core_set_display_usable(core, 0, nil)
        for (id, r) in Screens.coreUsableFrames() {
            var rect = nk_rect(x: r.minX, y: r.minY, w: r.width, h: r.height)
            nk_core_set_display_usable(core, id, &rect)
        }
    }

    @discardableResult
    func perform(_ action: NoktaAction) -> NoktaResult {
        guard let core else { return .noMemory }
        return NoktaResult(nk_core_perform(core, nk_action(rawValue: action.rawValue)))
    }

    /// Applies `action` to the focused window of `pid` without touching the core's frontmost
    /// app or its AX observer (menu actions: the target is the app that was frontmost before the
    /// menu opened). The exclusion list still applies (the core remembers the pid's bundle id).
    @discardableResult
    func perform(_ action: NoktaAction, pid: pid_t) -> NoktaResult {
        guard let core else { return .noMemory }
        return NoktaResult(nk_core_perform_pid(core, pid, nk_action(rawValue: action.rawValue)))
    }

    func stats() -> nk_stats {
        var s = nk_stats()
        if let core { nk_core_stats(core, &s) }
        return s
    }

    private func dispatch(_ e: nk_event) {
        guard let kind = NoktaEvent.Kind(rawValue: e.kind) else { return }
        let event = NoktaEvent(
            kind: kind,
            action: NoktaAction(rawValue: e.action),
            zone: NoktaZone(rawValue: e.zone),
            source: NoktaEvent.Source(rawValue: e.source),
            result: NoktaResult(rawValue: e.code) ?? .invalid,
            displayID: e.display_id,
            cycle: e.cycle,
            rect: CGRect(x: e.rect.x, y: e.rect.y, width: e.rect.w, height: e.rect.h),
            latencyNs: e.latency_ns,
            frameDiffers: (e.flags & UInt32(NK_EVENT_FLAG_FRAME_DIFFERS)) != 0,
            sizeRefused: (e.flags & UInt32(NK_EVENT_FLAG_SIZE_REFUSED)) != 0,
            drop: (e.flags & UInt32(NK_EVENT_FLAG_DROP)) != 0)
        onEvent?(event)
    }
}
