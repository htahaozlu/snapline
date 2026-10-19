import AppKit

/// Shell-only settings that Settings exposes but `Preferences.swift` does not declare yet.
/// They live in the same UserDefaults (`defaults`) and post the same change notification, so
/// AppController picks them up through `.noktaPreferencesChanged` like every other setting.
///
/// Proposed for Preferences proper (key · type · default):
///   showIconInMenuBar   · Bool   · true
///   flashOnKeyboardSnap · Bool   · true      (read by the overlay's keyboard flash, DESIGN §9 O5)
/// Keys of removed settings (the v1 preview style, first light and "shortcuts in menu": DESIGN §7.1,
/// §8, §9) are no longer read; Reset removes them with every other persisted key.
/// Edge sensitivity is not a key: it is derived from zoneEdge/zoneCorner (3/5/10 · 20/32/48 pt).
extension Preferences {
    enum UIKey {
        static let showIconInMenuBar = "showIconInMenuBar"
        static let flashOnKeyboardSnap = "flashOnKeyboardSnap"
    }

    /// DESIGN §8: Tight | Normal | Wide → edge band 3/5/10 pt, corner length 20/32/48 pt.
    enum EdgeSensitivity: CaseIterable {
        case tight, normal, wide
        var edge: Double {
            switch self { case .tight: return 3; case .normal: return 5; case .wide: return 10 }
        }
        var corner: Double {
            switch self { case .tight: return 20; case .normal: return 32; case .wide: return 48 }
        }
        var title: String {
            switch self { case .tight: return "Tight"; case .normal: return "Normal"; case .wide: return "Wide" }
        }
        /// Tooltip: the sizes this preset sets.
        var detail: String { "Edge \(Int(edge)) pt · corner \(Int(corner)) pt" }
    }

    private func uiBool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    private func uiSet(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .noktaPreferencesChanged, object: self)
    }

    var showIconInMenuBar: Bool {
        get { uiBool(UIKey.showIconInMenuBar, default: true) }
        set { uiSet(newValue, forKey: UIKey.showIconInMenuBar) }
    }

    var flashOnKeyboardSnap: Bool {
        get { uiBool(UIKey.flashOnKeyboardSnap, default: true) }
        set { uiSet(newValue, forKey: UIKey.flashOnKeyboardSnap) }
    }

    /// The preset the current zone sizes belong to. An exact match wins; otherwise the preset
    /// whose edge band is nearest (within 1.5 pt), so sizes stored by an older build still read
    /// sensibly. nil for anything further away.
    var edgeSensitivity: EdgeSensitivity? {
        get {
            if let exact = EdgeSensitivity.allCases.first(where: { abs($0.edge - zoneEdge) < 0.5 && abs($0.corner - zoneCorner) < 0.5 }) {
                return exact
            }
            let nearest = EdgeSensitivity.allCases.min { abs($0.edge - zoneEdge) < abs($1.edge - zoneEdge) }
            guard let nearest, abs(nearest.edge - zoneEdge) <= 1.5 else { return nil }
            return nearest
        }
        set {
            guard let newValue else { return }
            zoneEdge = newValue.edge
            zoneCorner = newValue.corner
        }
    }

    /// "Reset All Settings…": removes every value persisted in `domain` (the app's own
    /// preferences domain, which also holds the keys of removed settings) so the registered
    /// defaults apply again. Onboarding progress and the login item (ServiceManagement state,
    /// not a preference) are kept.
    func resetAllSettings(domain: String? = Bundle.main.bundleIdentifier) {
        let keepOnboarding = onboardingDone, keepSeen = onboardingSeen
        if let domain, let persisted = defaults.persistentDomain(forName: domain) {
            for key in persisted.keys { defaults.removeObject(forKey: key) }
        }
        invalidateShortcutCache() // the shortcut table was among the removed keys
        onboardingSeen = keepSeen
        onboardingDone = keepOnboarding // posts .noktaPreferencesChanged once
    }

    /// Case-insensitive, like the core's exclusion matching.
    func isExcluded(_ bundleID: String) -> Bool {
        excludedBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// The core keeps at most 64 rules of at most 255 bytes each (core/src/rules.zig).
    static let maxExcluded = 64
    static func isValidBundleID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 255 }

    var canAddExcluded: Bool { excludedBundleIDs.count < Self.maxExcluded }

    func setExcluded(_ excluded: Bool, bundleID: String) {
        var list = excludedBundleIDs.filter { $0.caseInsensitiveCompare(bundleID) != .orderedSame }
        if excluded {
            guard Self.isValidBundleID(bundleID), list.count < Self.maxExcluded else { return }
            list.append(bundleID)
        }
        excludedBundleIDs = list
    }

    /// Adds several bundle ids with a single change notification; stops at the 64-rule cap.
    /// Returns how many ids were not added because of the cap.
    @discardableResult
    func addExcluded(_ bundleIDs: [String]) -> Int {
        var list = excludedBundleIDs
        var skipped = 0
        for id in bundleIDs where Self.isValidBundleID(id) && !list.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) {
            if list.count >= Self.maxExcluded { skipped += 1; continue }
            list.append(id)
        }
        if list != excludedBundleIDs { excludedBundleIDs = list }
        return skipped
    }
}
