import AppKit

/// Visibility gate for moving surfaces (docs/DESIGN.md §5.2 rule 6). A scene may animate only while
/// all of these hold: the owner wants it (`isActive`: page shown, demo requested), the window is
/// visible, not occluded, not miniaturized and not closing, the app is not hidden, the displays are
/// awake and Reduce Motion is off.
///
/// Event driven, never polled: window occlusion / miniaturize / close, app hide / unhide, workspace
/// screens sleep / wake and `AccessibilityEnv` changes re-evaluate the gate. `onChange` fires only
/// when `isOpen` flips; on close the owner removes its animations and shows the rest pose, on open
/// looping scenes restart from zero (rule 6).
///
///     let gate = MotionGate()
///     gate.onChange = { [weak self] open in open ? self?.play() : self?.stopAtRest() }
///     gate.attach(to: view.window)   // viewDidMoveToWindow
///     gate.isActive = true           // the page appeared
final class MotionGate {
    /// The owner's own condition (page visible, scene wanted). Off by default.
    var isActive = false { didSet { update() } }
    /// Called on the main thread when `isOpen` changes.
    var onChange: ((Bool) -> Void)?

    private(set) var isOpen = false
    /// Reduce Motion on: scenes show their `explainT` pose instead of playing.
    var reduceMotion: Bool { AccessibilityEnv.shared.reduceMotion }

    private weak var window: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var miniaturizing = false
    private var closing = false
    private var screensAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0

    init(window: NSWindow? = nil) {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            appObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.update() })
        }
        appObservers.append(nc.addObserver(forName: .noktaAccessibilityChanged, object: nil, queue: .main) { [weak self] _ in
            self?.update()
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true
            self?.update()
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = false
            self?.update()
        })
        attach(to: window)
    }

    deinit {
        (windowObservers + appObservers).forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Follows `window` (nil detaches). Call from `viewDidMoveToWindow`.
    func attach(to window: NSWindow?) {
        guard window !== self.window || windowObservers.isEmpty else { update(); return }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        self.window = window
        miniaturizing = false
        closing = false
        if let window {
            let nc = NotificationCenter.default
            func on(_ name: Notification.Name, _ body: @escaping (MotionGate) -> Void) {
                windowObservers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    body(self)
                    self.update()
                })
            }
            on(NSWindow.didChangeOcclusionStateNotification) { gate in
                if gate.window?.isVisible == true { gate.closing = false } // shown again after a close
            }
            on(NSWindow.willMiniaturizeNotification) { $0.miniaturizing = true }
            on(NSWindow.didMiniaturizeNotification) { $0.miniaturizing = true }
            on(NSWindow.didDeminiaturizeNotification) { $0.miniaturizing = false }
            on(NSWindow.willCloseNotification) { $0.closing = true }
        }
        update()
    }

    /// Re-evaluates now (e.g. after the owner ordered its window in).
    func update() {
        let open = isActive && !reduceMotion && conditionsMet
        guard open != isOpen else { return }
        isOpen = open
        onChange?(open)
    }

    /// Everything except `isActive` and Reduce Motion.
    var conditionsMet: Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible) && isOnScreenIgnoringOcclusion
    }

    /// Visible, not miniaturized or closing, app not hidden, displays awake — but possibly covered by
    /// another window. The onboarding permission fallback uses this: while the user is in System
    /// Settings, onboarding is usually fully covered and must still notice the grant (DESIGN §11).
    var isOnScreenIgnoringOcclusion: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && !miniaturizing && !closing
            && !(NSApp?.isHidden ?? false) && !screensAsleep
    }
}
