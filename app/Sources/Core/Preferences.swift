import AppKit
import NoktaCore
import ServiceManagement

extension Notification.Name {
    /// Posted (object: Preferences) after any persisted value changes.
    static let noktaPreferencesChanged = Notification.Name("NoktaPreferencesChanged")
}

/// Persisted user settings (UserDefaults). The single source of truth for the shell;
/// `apply(to:)` pushes everything into the core.
final class Preferences {
    /// Set in bench and preview modes: preference changes stay in their own (throwaway) domain and
    /// never reach system state such as the login item.
    static var systemWritesDisabled = false

    enum HUDMode: String, CaseIterable { case off, whenNeeded, always }

    private enum Key {
        static let gapOuter = "gapOuter", gapInner = "gapInner"
        static let zoneEdge = "zoneEdge", zoneCorner = "zoneCorner"
        static let almostMaximize = "almostMaximize", thirdsModifier = "thirdsModifier"
        static let dragSnap = "dragSnap", snapBack = "snapBack", cycleSizes = "cycleSizes"
        static let sharedEdgeZones = "sharedEdgeZones"
        static let shortcuts = "shortcuts.v1", zoneActions = "zoneActions.v1", zoneActionsAlt = "zoneActionsAlt.v1"
        static let excluded = "excludedBundleIDs"
        static let sound = "soundEnabled", haptics = "hapticsEnabled", hud = "hudMode"
        static let onboardingDone = "onboardingDone.v1", onboardingSeen = "onboardingSeen.v1", practiceSeen = "practiceSeen.v1"
        static let keepClassicWithVoiceOver = "keepClassicWithVoiceOver"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = NoktaEngine.defaultConfig
        defaults.register(defaults: [
            Key.gapOuter: d.gap_outer, Key.gapInner: d.gap_inner,
            Key.zoneEdge: d.zone_edge, Key.zoneCorner: d.zone_corner,
            Key.almostMaximize: d.almost_maximize, Key.thirdsModifier: Int(d.thirds_modifier),
            Key.dragSnap: d.drag_snap, Key.snapBack: d.snap_back, Key.cycleSizes: d.cycle_sizes,
            Key.sharedEdgeZones: d.shared_edge_zones,
            Key.sound: false, Key.haptics: true, Key.hud: HUDMode.whenNeeded.rawValue,
            Key.onboardingDone: false,
        ])
    }

    private func changed() {
        NotificationCenter.default.post(name: .noktaPreferencesChanged, object: self)
    }

    // MARK: geometry & behaviour

    var gapOuter: Double {
        get { defaults.double(forKey: Key.gapOuter) }
        set { defaults.set(newValue, forKey: Key.gapOuter); changed() }
    }
    var gapInner: Double {
        get { defaults.double(forKey: Key.gapInner) }
        set { defaults.set(newValue, forKey: Key.gapInner); changed() }
    }
    var zoneEdge: Double {
        get { defaults.double(forKey: Key.zoneEdge) }
        set { defaults.set(newValue, forKey: Key.zoneEdge); changed() }
    }
    var zoneCorner: Double {
        get { defaults.double(forKey: Key.zoneCorner) }
        set { defaults.set(newValue, forKey: Key.zoneCorner); changed() }
    }
    var almostMaximize: Double {
        get { defaults.double(forKey: Key.almostMaximize) }
        set { defaults.set(newValue, forKey: Key.almostMaximize); changed() }
    }
    var thirdsModifier: NoktaMods {
        get { NoktaMods(rawValue: UInt32(truncatingIfNeeded: defaults.integer(forKey: Key.thirdsModifier))) }
        set { defaults.set(Int(newValue.rawValue), forKey: Key.thirdsModifier); changed() }
    }
    var dragSnap: Bool {
        get { defaults.bool(forKey: Key.dragSnap) }
        set { defaults.set(newValue, forKey: Key.dragSnap); changed() }
    }
    var snapBack: Bool {
        get { defaults.bool(forKey: Key.snapBack) }
        set { defaults.set(newValue, forKey: Key.snapBack); changed() }
    }
    var cycleSizes: Bool {
        get { defaults.bool(forKey: Key.cycleSizes) }
        set { defaults.set(newValue, forKey: Key.cycleSizes); changed() }
    }
    var sharedEdgeZones: Bool {
        get { defaults.bool(forKey: Key.sharedEdgeZones) }
        set { defaults.set(newValue, forKey: Key.sharedEdgeZones); changed() }
    }

    // MARK: shortcuts (action id → Shortcut; missing key = default, explicit null = none)

    /// Decoded `shortcuts.v1` table (nil = not loaded). `shortcut(for:)` runs dozens of times per
    /// menu build and Settings refresh, so the JSON is decoded once. Every writer of
    /// `Key.shortcuts` (setShortcut, applyShortcutSet, resetShortcuts, resetAllSettings) must call
    /// `invalidateShortcutCache()`.
    private var shortcutTableCache: [String: Shortcut?]?

    func invalidateShortcutCache() { shortcutTableCache = nil }

    private func loadShortcutTable() -> [String: Shortcut?] {
        if let cached = shortcutTableCache { return cached }
        var table: [String: Shortcut?] = [:]
        if let data = defaults.data(forKey: Key.shortcuts),
           let decoded = try? JSONDecoder().decode([String: Shortcut?].self, from: data) {
            table = decoded
        }
        shortcutTableCache = table
        return table
    }

    func shortcut(for action: NoktaAction) -> Shortcut? {
        let table = loadShortcutTable()
        if let entry = table[action.id] { return entry }
        return action.defaultShortcut
    }

    func setShortcut(_ shortcut: Shortcut?, for action: NoktaAction) {
        setShortcuts([(action, shortcut)])
    }

    /// Several shortcuts at once (a swap): one write, one change notification, so the engine
    /// re-binds them together.
    func setShortcuts(_ changes: [(NoktaAction, Shortcut?)]) {
        var table = loadShortcutTable()
        for (action, shortcut) in changes { table[action.id] = .some(shortcut) }
        if let data = try? JSONEncoder().encode(table) { defaults.set(data, forKey: Key.shortcuts) }
        invalidateShortcutCache()
        changed()
    }

    /// True once any shortcut was recorded, cleared, swapped or a set applied; false while every
    /// shortcut is the untouched default. A deliberate choice is never replaced on the user's behalf.
    var shortcutsCustomized: Bool { defaults.object(forKey: Key.shortcuts) != nil }

    enum ShortcutSet: String, CaseIterable {
        /// ⌃⌥ + key (community-standard layout).
        case classic
        /// ⌥⌘ + key: the layout Spectacle made common and Tiles keeps (halves on the arrows,
        /// quarters on U I J K, ⌥⌘F maximize, ⌥⌘C center), for people who already type it.
        case optionCommand
        /// ⌃⇧⌘ + key: never uses ⌃⌥ together (VoiceOver's VO keys).
        case alternate

        var title: String {
            switch self {
            case .classic: return "Classic"
            case .optionCommand: return "Option-Command"
            case .alternate: return "Alternate"
            }
        }
        /// The set's main modifiers, as its picker shows them.
        var symbols: String {
            switch self {
            case .classic: return "⌃⌥"
            case .optionCommand: return "⌥⌘"
            case .alternate: return "⌃⇧⌘"
            }
        }
        var label: String { "\(title) \(symbols)" }
        /// The set in words (the pickers' tooltips).
        var help: String {
            switch self {
            case .classic: return "Classic: Control-Option + key"
            case .optionCommand: return "Option-Command + key, as in Spectacle and Tiles"
            case .alternate: return "Alternate: Control-Shift-Command + key, clear of VoiceOver"
            }
        }
    }

    /// Default shortcut of `action` within a set. Alternate never combines ⌃ and ⌥ (VoiceOver's
    /// VO keys, including VO+⌘ commands): tiling uses ⌃⇧⌘ + the Classic key, displays ⌃⇧⌘ [ / ],
    /// almost maximize ⌃⇧⌘M. Option-Command: ⌥⌘ + the Classic key for halves and quarters,
    /// ⌥⌘F maximize, ⌥⌘C center, ⌥⌘Y restore, ⇧⌥⌘↩ almost maximize, ⇧⌥⌘ D/F/G thirds (⌥⌘D is
    /// the Dock's), ⌃⌘ ←/↑/→ two thirds; displays stay ⌃⌥⌘ ←/→.
    static func preset(_ set: ShortcutSet, for action: NoktaAction) -> Shortcut? {
        guard let s = action.defaultShortcut else { return nil }
        switch set {
        case .classic:
            return s
        case .alternate:
            let hyper = NoktaMods([.control, .shift, .command]).rawValue
            switch action {
            case .nextDisplay: return Shortcut(keyCode: 0x1E, mods: hyper)   // ]
            case .prevDisplay: return Shortcut(keyCode: 0x21, mods: hyper)   // [
            case .almostMaximize: return Shortcut(keyCode: 0x2E, mods: hyper) // M
            default: return Shortcut(keyCode: s.keyCode, mods: hyper)
            }
        case .optionCommand:
            let oc = NoktaMods([.option, .command]).rawValue
            let soc = NoktaMods([.shift, .option, .command]).rawValue
            let cc = NoktaMods([.control, .command]).rawValue
            switch action {
            case .firstThird, .centerThird, .lastThird: return Shortcut(keyCode: s.keyCode, mods: soc) // D F G
            case .firstTwoThirds: return Shortcut(keyCode: 0x7B, mods: cc)  // ←
            case .centerTwoThirds: return Shortcut(keyCode: 0x7E, mods: cc) // ↑
            case .lastTwoThirds: return Shortcut(keyCode: 0x7C, mods: cc)   // →
            case .maximize: return Shortcut(keyCode: 0x03, mods: oc)        // F
            case .almostMaximize: return Shortcut(keyCode: 0x24, mods: soc) // ↩
            case .restore: return Shortcut(keyCode: 0x10, mods: oc)         // Y
            case .nextDisplay, .prevDisplay: return s
            default: return Shortcut(keyCode: s.keyCode, mods: oc)          // arrows, U I J K, C
            }
        }
    }

    /// Window managers whose default keys match a set: if one is installed and the user never
    /// touched the shortcuts, onboarding starts on that set (bundle id → name and set).
    static let familiarApps: [(bundleID: String, name: String, set: ShortcutSet)] = [
        ("com.sempliva.Tiles", "Tiles", .optionCommand),
        ("com.divisiblebyzero.Spectacle", "Spectacle", .optionCommand),
    ]

    /// Window managers that hold global shortcuts of their own while they run (bundle id → name).
    static let otherWindowManagers: [(bundleID: String, name: String)] = familiarApps.map { ($0.bundleID, $0.name) } + [
        ("com.knollsoft.Rectangle", "Rectangle"),
        ("com.crowdcafe.windowmagnet", "Magnet"),
        ("com.manytricks.Moom", "Moom"),
    ]

    /// The first installed app of `familiarApps` (nil: none).
    static func familiarApp(installed: (String) -> Bool) -> (name: String, set: ShortcutSet)? {
        familiarApps.first { installed($0.bundleID) }.map { ($0.name, $0.set) }
    }

    /// Names of the apps of `otherWindowManagers` among `running` (bundle ids).
    static func runningWindowManagers(among running: [String?]) -> [String] {
        otherWindowManagers.filter { m in running.contains(m.bundleID) }.map(\.name)
    }

    /// Replaces every shortcut with the given set.
    func applyShortcutSet(_ set: ShortcutSet) {
        var table: [String: Shortcut?] = [:]
        for action in NoktaAction.allCases { table[action.id] = .some(Preferences.preset(set, for: action)) }
        if let data = try? JSONEncoder().encode(table) { defaults.set(data, forKey: Key.shortcuts) }
        invalidateShortcutCache()
        changed()
    }

    /// The set the current table matches, if any (nil = custom).
    var currentShortcutSet: ShortcutSet? {
        ShortcutSet.allCases.first { set in
            NoktaAction.allCases.allSatisfy { shortcut(for: $0) == Preferences.preset(set, for: $0) }
        }
    }

    func resetShortcuts() {
        defaults.removeObject(forKey: Key.shortcuts)
        invalidateShortcutCache()
        changed()
    }

    // MARK: zone map (zone id → action id; "none" disables)

    func zoneAction(_ zone: NoktaZone, alternate: Bool) -> NoktaAction? {
        let key = alternate ? Key.zoneActionsAlt : Key.zoneActions
        if let table = defaults.dictionary(forKey: key) as? [String: String], let id = table[zone.id] {
            return NoktaAction(id: id)
        }
        return zone.defaultAction(alternate: alternate)
    }

    func setZoneAction(_ action: NoktaAction?, for zone: NoktaZone, alternate: Bool) {
        let key = alternate ? Key.zoneActionsAlt : Key.zoneActions
        var table = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        table[zone.id] = action?.id ?? "none"
        defaults.set(table, forKey: key)
        changed()
    }

    func resetZones() {
        defaults.removeObject(forKey: Key.zoneActions)
        defaults.removeObject(forKey: Key.zoneActionsAlt)
        changed()
    }

    // MARK: rules

    var excludedBundleIDs: [String] {
        get { defaults.stringArray(forKey: Key.excluded) ?? [] }
        set { defaults.set(newValue, forKey: Key.excluded); changed() }
    }

    // MARK: feedback & UI

    var soundEnabled: Bool {
        get { defaults.bool(forKey: Key.sound) }
        set { defaults.set(newValue, forKey: Key.sound); changed() }
    }
    var hapticsEnabled: Bool {
        get { defaults.bool(forKey: Key.haptics) }
        set { defaults.set(newValue, forKey: Key.haptics); changed() }
    }
    var hudMode: HUDMode {
        get { HUDMode(rawValue: defaults.string(forKey: Key.hud) ?? "") ?? .whenNeeded }
        set { defaults.set(newValue.rawValue, forKey: Key.hud); changed() }
    }
    /// Opt-out of the VoiceOver protection (users whose VO key is Caps Lock).
    var keepClassicWithVoiceOver: Bool {
        get { defaults.bool(forKey: Key.keepClassicWithVoiceOver) }
        set { defaults.set(newValue, forKey: Key.keepClassicWithVoiceOver); changed() }
    }
    var onboardingDone: Bool {
        get { defaults.bool(forKey: Key.onboardingDone) }
        set { defaults.set(newValue, forKey: Key.onboardingDone); changed() }
    }
    /// Onboarding was closed at least once (Done, Later, Esc or ⌘W). Written once, no notification:
    /// it only decides whether the next launch opens onboarding by itself.
    var onboardingSeen: Bool {
        get { defaults.bool(forKey: Key.onboardingSeen) }
        set { if newValue != onboardingSeen { defaults.set(newValue, forKey: Key.onboardingSeen) } }
    }
    /// The practice screen (onboarding's Try page) was closed at least once. People who finished
    /// setup before it existed see it once more, on its own. Written once, no notification.
    var practiceSeen: Bool {
        get { defaults.bool(forKey: Key.practiceSeen) }
        set { if newValue != practiceSeen { defaults.set(newValue, forKey: Key.practiceSeen) } }
    }

    /// Login item state lives in ServiceManagement, not UserDefaults. Only toggled by the
    /// user from Settings/Onboarding.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            // Bench and preview modes never touch the system's login items (DV-1).
            guard !Preferences.systemWritesDisabled else { changed(); return }
            #if NOKTA_SNAPSHOT
            // The offscreen tools never reach ServiceManagement either: they record the request.
            Preferences.loginItemRequests.append(newValue)
            #else
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("\(Product.name): login item change failed: \(error.localizedDescription)")
            }
            #endif
            changed()
        }
    }

    #if NOKTA_SNAPSHOT
    /// Tests: login item changes a live app would have made.
    static var loginItemRequests: [Bool] = []
    #endif

    // MARK: core bridge

    var coreConfig: nk_config {
        var c = NoktaEngine.defaultConfig
        c.gap_outer = gapOuter
        c.gap_inner = gapInner
        c.zone_edge = zoneEdge
        c.zone_corner = zoneCorner
        c.almost_maximize = almostMaximize
        c.thirds_modifier = thirdsModifier.rawValue
        c.drag_snap = dragSnap
        c.snap_back = snapBack
        c.cycle_sizes = cycleSizes
        c.shared_edge_zones = sharedEdgeZones
        return c
    }

    /// Pushes every setting into the core. Returns per-action hotkey results.
    /// `suspendControlOption`: VoiceOver protection — shortcuts holding both ⌃ and ⌥ (the VO
    /// keys) are left unregistered and reported as `.notStarted`.
    @discardableResult
    /// `bindShortcuts: false` (a ShortcutRecorder is listening) leaves every hotkey unbound and
    /// returns no results; the recorder's end re-binds them.
    func apply(to engine: NoktaEngine, suspendControlOption: Bool = false,
               bindShortcuts: Bool = true) -> [NoktaAction: NoktaResult] {
        engine.apply(config: coreConfig)
        for zone in NoktaZone.allCases {
            engine.setZone(zone, alternate: false, action: zoneAction(zone, alternate: false))
            engine.setZone(zone, alternate: true, action: zoneAction(zone, alternate: true))
        }
        // The core keeps at most 64 rules (core/src/rules.zig); Settings enforces the same cap.
        if engine.setExcluded(Array(excludedBundleIDs.prefix(64))) != .ok {
            NSLog("\(Product.name): exclusion list rejected by the core (ids longer than 255 bytes?)")
        }
        guard bindShortcuts else {
            for action in NoktaAction.allCases { engine.bind(action, to: nil) }
            return [:]
        }
        let actions = NoktaAction.allCases
        let wanted = actions.map(shortcut(for:))
        // VoiceOver protection: ⌃⌥ shortcuts stay unbound and report `.notStarted`.
        let paused = wanted.map { s in suspendControlOption && s?.modifiers.isSuperset(of: [.control, .option]) == true }
        let outcomes = engine.bind(all: zip(wanted, paused).map { $1 ? nil : $0 })
        var results: [NoktaAction: NoktaResult] = [:]
        for (i, action) in actions.enumerated() { results[action] = paused[i] ? .notStarted : outcomes[i] }
        return results
    }
}
