import AppKit

/// Spoken and chip forms of a shortcut ("Control Option Left Arrow", ["⌃", "⌥", "←"]).
enum ShortcutSpeech {
    static func spoken(_ s: Shortcut) -> String {
        let m = modifiers(s.modifiers)
        return m.isEmpty ? keyName(s.keyCode) : m + " " + keyName(s.keyCode)
    }

    /// "Control Option" for ⌃⌥.
    static func modifiers(_ m: NoktaMods) -> String {
        var parts: [String] = []
        if m.contains(.control) { parts.append("Control") }
        if m.contains(.option) { parts.append("Option") }
        if m.contains(.shift) { parts.append("Shift") }
        if m.contains(.command) { parts.append("Command") }
        return parts.joined(separator: " ")
    }

    static func spoken(_ s: Shortcut?) -> String { s.map { spoken($0) } ?? "None" }

    /// Named keys by key code; character keys by what they type on the current layout (the same
    /// label the chips show), punctuation spelled out because VoiceOver may skip it.
    static func keyName(_ code: UInt32) -> String {
        switch code {
        case 0x7B: return "Left Arrow"
        case 0x7C: return "Right Arrow"
        case 0x7D: return "Down Arrow"
        case 0x7E: return "Up Arrow"
        case 0x24: return "Return"
        case 0x4C: return "Enter"
        case 0x30: return "Tab"
        case 0x31: return "Space"
        case 0x33: return "Delete"
        case 0x35: return "Escape"
        case 0x75: return "Forward Delete"
        case 0x73: return "Home"
        case 0x77: return "End"
        case 0x74: return "Page Up"
        case 0x79: return "Page Down"
        case 0x47: return "Clear"
        default:
            guard let c = KeyNames.character(for: code) else { return KeyNames.name(for: code) }
            let spoken = punctuation[c] ?? c
            return KeyNames.isKeypad(code) ? "Keypad " + spoken : spoken
        }
    }

    private static let punctuation: [String: String] = [
        "[": "Left Bracket", "]": "Right Bracket", "-": "Minus", "=": "Equals", ";": "Semicolon",
        "'": "Quote", "\"": "Double Quote", ",": "Comma", ".": "Period", "/": "Slash", "\\": "Backslash",
        "`": "Grave Accent", "<": "Less Than", ">": "Greater Than", "*": "Asterisk", "+": "Plus",
        "§": "Section", "´": "Acute Accent", "^": "Caret", "#": "Number Sign",
    ]

    static func chips(_ s: Shortcut) -> [String] {
        s.modifiers.symbols.map(String.init) + [KeyNames.name(for: s.keyCode)]
    }
}

/// Keycap chips (DESIGN §4.3 keycap: SF 12 medium, r.s 6). Shared by the recorder and onboarding.
enum Keycaps {
    static let height: CGFloat = 18
    static let gap: CGFloat = 3

    private static func attributes(alpha: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: Typography.keycap, .foregroundColor: Theme.Color.ink.withAlphaComponent(alpha)]
    }

    private static func chipWidth(_ chip: String) -> CGFloat {
        max(height, ceil((chip as NSString).size(withAttributes: attributes(alpha: 1)).width) + 8)
    }

    static func width(_ chips: [String]) -> CGFloat {
        chips.map(chipWidth).reduce(0, +) + gap * CGFloat(max(0, chips.count - 1))
    }

    /// Draws left to right from `x`; works in flipped and unflipped views.
    static func draw(_ chips: [String], x: CGFloat, centerY: CGFloat, alpha: CGFloat = 1) {
        let attrs = attributes(alpha: alpha)
        var cursor = x
        for chip in chips {
            let textSize = (chip as NSString).size(withAttributes: attrs)
            let width = chipWidth(chip)
            let rect = NSRect(x: cursor, y: centerY - height / 2, width: width, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
            Theme.Color.hairline.setFill()
            path.fill()
            (chip as NSString).draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                                    withAttributes: attrs)
            cursor += width + gap
        }
    }
}

/// Read-only keycap chips for a shortcut ("⌃ ⌥ ←"), spoken as words.
final class KeycapsView: NSView {
    var shortcut: Shortcut? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    private var chips: [String] { shortcut.map(ShortcutSpeech.chips) ?? [] }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(Keycaps.width(chips), Keycaps.height), height: Keycaps.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if shortcut == nil {
            let attrs: [NSAttributedString.Key: Any] = [.font: Typography.callout, .foregroundColor: NSColor.secondaryLabelColor]
            ("—" as NSString).draw(at: NSPoint(x: 0, y: (bounds.height - 15) / 2), withAttributes: attrs)
            return
        }
        Keycaps.draw(chips, x: 0, centerY: bounds.midY)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { shortcut.map { ShortcutSpeech.spoken($0) } ?? "Not set" }
}

/// Shortcut recorder (DESIGN §8): 150 × 24 pill with keycap chips; the row's own button clears it.
/// Recording uses a LOCAL NSEvent monitor (never a global one: it only hears keys typed into Nokta's
/// own key window, never activates anything) and asks the owner, through `onBegin`/`onEnd`, to
/// suspend Nokta's global shortcuts so Carbon doesn't eat the keystroke and no shortcut acts
/// meanwhile. While it listens: Escape (with any modifiers) cancels and keeps the old shortcut,
/// Delete / ⌦ clears, Tab / ⇧Tab leave and move the focus on; anything `ShortcutPolicy` refuses
/// is explained and listening goes on. The recorder never writes preferences: `onCommit` hands the
/// result to the owner — before `onEnd`, so the owner saves it while shortcuts are still suspended
/// and they are bound once, with the new one — which may still refuse it (conflict prompt).
final class ShortcutRecorder: NSControl {
    var actionTitle = "" { didSet { needsDisplay = true } }
    var shortcut: Shortcut? {
        didSet {
            needsDisplay = true
            // Only a real change is announced; table refreshes re-assign the same value often.
            if shortcut != oldValue { NSAccessibility.post(element: self, notification: .valueChanged) }
        }
    }
    /// Inside a table the row (not the recorder) is the Tab stop; the table forwards Space/Return.
    var participatesInKeyViewLoop = true
    /// The view Tab / ⇧Tab move on from (the table, for a recorder inside one); nil = the recorder.
    weak var keyLoopAnchor: NSView?

    #if NOKTA_SNAPSHOT
    /// Offscreen tests: their windows are never key.
    static var requiresKeyWindow = true
    #else
    private static let requiresKeyWindow = true
    #endif

    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    /// A new shortcut, or nil for "cleared".
    var onCommit: ((Shortcut?) -> Void)?
    /// Inline validation text for the owner to show under the row (nil = clear it).
    var onMessage: ((String?) -> Void)?

    private(set) var isRecording = false
    /// macOS's own shortcuts, read once when listening starts (not per key).
    private var reserved: [Shortcut] = []
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var liveModifiers: NoktaMods = []
    private var enabledState = true

    static let size = NSSize(width: 150, height: 24)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    convenience init() { self.init(frame: NSRect(origin: .zero, size: Self.size)) }
    required init?(coder: NSCoder) { nil }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    override var intrinsicContentSize: NSSize { Self.size }
    override var isFlipped: Bool { true }

    override var isEnabled: Bool {
        get { enabledState }
        set {
            enabledState = newValue
            if !newValue { cancelRecording() }
            needsDisplay = true
        }
    }

    // MARK: focus

    override var acceptsFirstResponder: Bool { enabledState }
    override var canBecomeKeyView: Bool { enabledState && participatesInKeyViewLoop }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { pill(bounds).fill() }

    override func becomeFirstResponder() -> Bool {
        scrollToVisible(bounds)
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        needsDisplay = true
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: input

    override func mouseDown(with event: NSEvent) {
        guard enabledState else { return }
        window?.makeFirstResponder(self)
        if isRecording { cancelRecording() } else { beginRecording() }
    }

    override func keyDown(with event: NSEvent) {
        guard enabledState, !isRecording else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Focused by a click or after recording, a row's recorder is outside the key loop: Tab and
        // ⇧Tab continue from its anchor instead of getting lost.
        if event.keyCode == 0x30, mods.subtracting(.shift).isEmpty, keyLoopAnchor != nil {
            return moveFocus(backward: mods.contains(.shift))
        }
        guard mods.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 0x31, 0x24, 0x4C: beginRecording()            // Space, Return, Enter
        case 0x33, 0x75: if shortcut != nil { commit(nil) } // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }

    func beginRecording() {
        guard enabledState, !isRecording else { return }
        // Keys only reach the local monitor in Nokta's key window. Listening anywhere else would
        // just leave every shortcut suspended (and nothing would end it).
        guard !Self.requiresKeyWindow || window?.isKeyWindow == true else { return }
        isRecording = true
        reserved = SystemShortcuts.reserved()
        liveModifiers = []
        onMessage?(nil)
        onBegin?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleWhileRecording(event)
        }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.cancelRecording()
            }
        }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
        announce("Recording. Type the new shortcut, or press Escape to cancel.", high: true)
    }

    func cancelRecording() {
        guard isRecording else { return }
        endRecording()
        onMessage?(nil)
    }

    private func endRecording() {
        isRecording = false
        liveModifiers = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
        onEnd?()
    }

    /// The owner first (shortcuts are still suspended while it saves), then the end of listening.
    private func commit(_ value: Shortcut?) {
        onCommit?(value)
        if isRecording { endRecording() }
    }

    /// Tab / ⇧Tab while listening: the key loop continues from the anchor (the table for a row's
    /// recorder), as if the recorder had not been listening.
    private func moveFocus(backward: Bool) {
        guard let window else { return }
        let anchor = keyLoopAnchor ?? self
        if backward { window.selectKeyView(preceding: anchor) } else { window.selectKeyView(following: anchor) }
    }

    private func handleWhileRecording(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        switch event.type {
        case .flagsChanged:
            liveModifiers = NoktaMods(event.modifierFlags)
            needsDisplay = true
            return event
        case .leftMouseDown, .rightMouseDown:
            let inside = event.window === window && bounds.contains(convert(event.locationInWindow, from: nil))
            if !inside { cancelRecording() }
            return event
        case .keyDown:
            let mods = NoktaMods(event.modifierFlags)
            let key = UInt32(event.keyCode)
            if key == 0x35 {                                            // Escape, with any modifiers
                cancelRecording()
                announce("Cancelled. \(actionTitle) is still \(ShortcutSpeech.spoken(shortcut)).")
                return nil
            }
            if (key == 0x33 || key == 0x75) && mods.isEmpty {           // Delete / Forward Delete clear
                commit(nil)
                return nil
            }
            if key == 0x30 && mods.subtracting(.shift).isEmpty {        // Tab / ⇧Tab: leave, focus moves on
                cancelRecording()
                moveFocus(backward: mods.contains(.shift))
                return nil
            }
            let candidate = Shortcut(keyCode: key, mods: mods.rawValue)
            if let problem = ShortcutPolicy.problem(with: candidate, reserved: reserved) {
                onMessage?(problem.message)
                announce("\(ShortcutSpeech.spoken(candidate)): \(problem.message)", high: true)
                return nil
            }
            commit(candidate)
            return nil
        default:
            return event
        }
    }

    #if NOKTA_SNAPSHOT
    /// Tests: an event as the local monitor would see it while listening (returns what it passes on).
    func testHandle(_ event: NSEvent) -> NSEvent? { handleWhileRecording(event) }
    var testHasMonitor: Bool { monitor != nil }
    #endif

    // MARK: drawing

    private func pill(_ rect: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = enabledState ? 1 : 0.5
        let shape = pill(bounds.insetBy(dx: 0.5, dy: 0.5))
        Theme.Color.paperRaised.withAlphaComponent(alpha).setFill()
        shape.fill()
        let highContrast = AccessibilityEnv.shared.increaseContrast
        let border = isRecording || highContrast ? Theme.Color.ink : Theme.Color.hairline
        border.withAlphaComponent(border.alphaComponent * alpha).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        if isRecording {
            // R2: fixed red dot, Ø 6 pt — "listening".
            let dot = NSRect(x: 10, y: bounds.midY - 3, width: 6, height: 6)
            Theme.Color.red.setFill()
            NSBezierPath(ovalIn: dot).fill()
            if liveModifiers.isEmpty {
                drawText("Type shortcut…", x: 22, color: .secondaryLabelColor)
            } else {
                drawChips(liveModifiers.symbols.map(String.init) + ["…"], x: 22, alpha: alpha)
            }
            return
        }

        guard let shortcut else {
            drawText("Record Shortcut", x: nil, color: NSColor.secondaryLabelColor.withAlphaComponent(alpha))
            return
        }
        drawChips(ShortcutSpeech.chips(shortcut), x: 8, alpha: alpha)
    }

    private func drawText(_ text: String, x: CGFloat?, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Typography.callout, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: x ?? (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func drawChips(_ chips: [String], x: CGFloat, alpha: CGFloat) {
        Keycaps.draw(chips, x: x, centerY: bounds.midY, alpha: alpha)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "\(actionTitle) shortcut" }
    override func accessibilityValue() -> Any? { isRecording ? "Recording" : ShortcutSpeech.spoken(shortcut) }
    override func accessibilityHelp() -> String? { "Press Space to record. Escape cancels, Delete clears, Tab moves on." }
    override func isAccessibilityEnabled() -> Bool { enabledState }
    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        beginRecording()
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard shortcut != nil, enabledState else { return nil }
        return [NSAccessibilityCustomAction(name: "Clear shortcut") { [weak self] in
            self?.commit(nil)
            return true
        }]
    }
}
