import AppKit

extension Notification.Name {
    /// Posted (object: AccessibilityEnv) after Reduce Motion / Reduce Transparency / Increase
    /// Contrast / Differentiate Without Color changed.
    static let noktaAccessibilityChanged = Notification.Name("NoktaAccessibilityChanged")
}

/// Cached accessibility display options (DESIGN §5, §15). Read once, then refreshed only by
/// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` — never polled.
final class AccessibilityEnv {
    static let shared = AccessibilityEnv()

    struct Snapshot: Equatable {
        var reduceMotion = false
        var reduceTransparency = false
        var increaseContrast = false
        var differentiateWithoutColor = false
    }

    private(set) var current: Snapshot
    /// Fixed values instead of the system's (offscreen render tools, previews).
    var override: Snapshot? {
        didSet { if override != oldValue { NotificationCenter.default.post(name: .noktaAccessibilityChanged, object: self) } }
    }
    private var observer: NSObjectProtocol?

    var snapshot: Snapshot { override ?? current }
    var reduceMotion: Bool { snapshot.reduceMotion }
    var reduceTransparency: Bool { snapshot.reduceTransparency }
    var increaseContrast: Bool { snapshot.increaseContrast }
    var differentiateWithoutColor: Bool { snapshot.differentiateWithoutColor }
    /// Live (KVO-compliant) property; reading it is cheap.
    var voiceOverEnabled: Bool { NSWorkspace.shared.isVoiceOverEnabled }

    private init() {
        current = AccessibilityEnv.read()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    private static func read() -> Snapshot {
        let ws = NSWorkspace.shared
        return Snapshot(reduceMotion: ws.accessibilityDisplayShouldReduceMotion,
                        reduceTransparency: ws.accessibilityDisplayShouldReduceTransparency,
                        increaseContrast: ws.accessibilityDisplayShouldIncreaseContrast,
                        differentiateWithoutColor: ws.accessibilityDisplayShouldDifferentiateWithoutColor)
    }

    private func refresh() {
        let next = AccessibilityEnv.read()
        guard next != current else { return }
        current = next
        NotificationCenter.default.post(name: .noktaAccessibilityChanged, object: self)
    }

    /// VoiceOver announcement (`announcementRequested`). No-op when VoiceOver is off.
    static func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
