import AppKit

/// What the practice line of screen 3 says: the step to try, the keys the user holds, and what a
/// press did — or why it did nothing.
enum PracticeStatus {
    /// No Accessibility yet: shortcuts are not bound.
    case locked
    /// Press the step's shortcut.
    case next(NoktaAction)
    /// Modifiers are down (the step's action, if any, tells which ones it needs).
    case holding(NoktaMods, NoktaAction?)
    /// A shortcut (or a drag, `keyboard` false) snapped the window; then the next step, if any.
    case worked(NoktaAction, keyboard: Bool, next: NoktaAction?)
    /// Restore arrived with nothing to put back.
    case nothingToRestore
    /// The shortcut arrived but the window did not move.
    case failed(NoktaAction, NoktaResult)
    /// The step's key without its modifiers.
    case needsModifiers(NoktaAction)
    /// A shortcut of another set.
    case otherSet(Shortcut, NoktaAction, Preferences.ShortcutSet)
    /// A combination that is no Snapline shortcut.
    case notSnapline(Shortcut, NoktaAction?)
    /// One of Snapline's own shortcuts reached this window: Snapline did not get it.
    case notReceived(Shortcut)
    /// VoiceOver runs and ⌃⌥ shortcuts are paused for it.
    case voiceOverPaused
    /// Another app (named, if a known one runs) holds the step's shortcut.
    case taken(NoktaAction, by: String?)
    /// Another window manager runs and answers keys too.
    case otherManager(String)
    /// The set was picked because the user knows it from another app.
    case familiar(String, Preferences.ShortcutSet, NoktaAction?)
    /// Every step done.
    case done

    /// One run of the line: keys are drawn as keys, the rest as text. `spoken` replaces `text`
    /// for VoiceOver.
    struct Run {
        let text: String
        let keys: Bool
        let spoken: String?
    }

    private static func t(_ s: String) -> Run { Run(text: s, keys: false, spoken: nil) }
    private static func k(_ s: Shortcut?) -> Run {
        Run(text: s?.displayString ?? "—", keys: true, spoken: s.map { ShortcutSpeech.spoken($0) } ?? "no shortcut")
    }
    private static func k(_ m: NoktaMods) -> Run { Run(text: m.symbols, keys: true, spoken: ShortcutSpeech.modifiers(m)) }
    private static func key(_ code: UInt32) -> Run { Run(text: KeyNames.name(for: code), keys: true, spoken: ShortcutSpeech.keyName(code)) }

    /// What the step does, after "Press ⌃⌥←".
    static func phrase(_ a: NoktaAction) -> String {
        switch a {
        case .leftHalf: return "to move this window left"
        case .rightHalf: return "to move it right"
        case .maximize: return "to fill the screen"
        case .restore: return "to put it back"
        default: return "for \(a.title)"
        }
    }

    /// The line, in runs. `shortcut` reads the current shortcuts.
    func runs(_ shortcut: (NoktaAction) -> Shortcut?) -> [Run] {
        typealias S = PracticeStatus
        func press(_ a: NoktaAction, _ lead: String = "Press ") -> [Run] {
            guard let s = shortcut(a) else { return [S.t("\(a.title) has no shortcut. Choose a set below.")] }
            return [S.t(lead), S.k(s), S.t(" \(S.phrase(a)).")]
        }
        switch self {
        case .locked:
            return [S.t("Shortcuts start after you allow access. \(Product.name) stays in the menu bar")]
        case .next(let a):
            return press(a)
        case let .holding(m, a):
            guard let a, let s = shortcut(a) else { return [S.k(m), S.t(" held.")] }
            if m == s.modifiers { return [S.k(m), S.t(" held. Now press "), S.key(s.keyCode), S.t(".")] }
            if s.modifiers.isSuperset(of: m) { return [S.k(m), S.t(" held. Add "), S.k(s.modifiers.subtracting(m)), S.t(".")] }
            return [S.k(m), S.t(" held. This set uses "), S.k(s.modifiers), S.t(".")]
        case let .worked(a, keyboard, next):
            guard let next else { return PracticeStatus.done.runs(shortcut) }
            let head = keyboard ? [S.t("✓ "), S.k(shortcut(a)), S.t(". ")] : [S.t("✓ \(a.title). ")]
            return head + press(next, "Next, press ")
        case .nothingToRestore:
            return [S.t("✓ "), S.k(shortcut(.restore)), S.t(" works. There was nothing to put back yet.")]
        case let .failed(a, r):
            return [S.k(shortcut(a)), S.t(" reached \(Product.name), but: \(r.message)")]
        case .needsModifiers(let a):
            guard let s = shortcut(a) else { return press(a) }
            return [S.t("Hold "), S.k(s.modifiers), S.t(" while you press "), S.key(s.keyCode), S.t(".")]
        case let .otherSet(p, a, set):
            return [S.k(p), S.t(" is \(a.title) in \(set.title). Choose it below.")]
        case let .notSnapline(p, a):
            guard let a, let s = shortcut(a) else { return [S.k(p), S.t(" is not a \(Product.name) shortcut.")] }
            return [S.k(p), S.t(" is not a \(Product.name) shortcut. Try "), S.k(s), S.t(".")]
        case .notReceived(let p):
            return [S.k(p), S.t(" reached this window, not \(Product.name): another app has it.")]
        case .voiceOverPaused:
            return [S.t("VoiceOver uses "), S.k([.control, .option]), S.t(", so these are paused. Choose Alternate below.")]
        case let .taken(a, by):
            return [S.k(shortcut(a)), S.t(" belongs to \(by ?? "another app"). Quit it, or choose another set.")]
        case .otherManager(let name):
            return [S.t("\(name) is running and answers keys too. Quit \(name) to practise.")]
        case let .familiar(name, set, a):
            guard let a else { return [S.t("\(set.title) keys, as in \(name).")] }
            return [S.t("\(set.title) keys, as in \(name). ")] + press(a)
        case .done:
            return [S.t("All four work. \(Product.name) stays in the menu bar")]
        }
    }

    /// The line ends on "menu bar": the menu bar icon follows it, as the sentence's period.
    var endsWithMenuBar: Bool {
        switch self {
        case .locked, .done: return true
        case .worked(_, _, let next): return next == nil
        default: return false
        }
    }

    var isLocked: Bool {
        if case .locked = self { return true }
        return false
    }
}

/// Reads the keys the user presses on the practice screen. Snapline's own shortcuts never arrive
/// there as key presses (Carbon takes them first and Snapline acts), so whatever does arrive says
/// something: a shortcut of another set, a combination Snapline does not know, or one of Snapline's
/// own that went to the window instead — then Snapline did not get it.
enum PracticeCoach {
    struct Context {
        var shortcut: (NoktaAction) -> Shortcut?
        /// The step to try (nil: all done).
        var target: NoktaAction?
        /// ⌃⌥ shortcuts are unbound while VoiceOver runs.
        var voiceOverPaused: Bool
        /// The last registration outcome per action.
        var result: (NoktaAction) -> NoktaResult?
        /// Known window managers that run now.
        var runningManagers: [String]
    }

    /// The verdict on a key press that reached the window; nil when it is no attempt at a
    /// shortcut (typing, Tab, Return, ⌘ commands such as ⌘W).
    static func evaluate(_ pressed: Shortcut, _ c: Context) -> PracticeStatus? {
        let m = pressed.modifiers
        let chord: NoktaMods = [.control, .option, .command]
        if m.isDisjoint(with: chord) {
            if let t = c.target, let s = c.shortcut(t), s.keyCode == pressed.keyCode { return .needsModifiers(t) }
            return nil
        }
        if m.isSubset(of: [.command, .shift]) { return nil } // app commands; never a Snapline shortcut
        if let own = NoktaAction.allCases.first(where: { c.shortcut($0) == pressed }) {
            if c.voiceOverPaused, m.isSuperset(of: [.control, .option]) { return .voiceOverPaused }
            if c.result(own) == .hotkey { return .taken(own, by: c.runningManagers.first) }
            return .notReceived(pressed)
        }
        for set in Preferences.ShortcutSet.allCases {
            if let a = NoktaAction.allCases.first(where: { Preferences.preset(set, for: $0) == pressed }) {
                return .otherSet(pressed, a, set)
            }
        }
        return .notSnapline(pressed, c.target)
    }

    /// The line while nothing was pressed lately: access first, then a step's shortcut another app
    /// holds, then another window manager that runs, then the step.
    static func idle(trusted: Bool, target: NoktaAction?, _ c: Context) -> PracticeStatus {
        guard trusted else { return .locked }
        guard let target else { return .done }
        if c.result(target) == .hotkey { return .taken(target, by: c.runningManagers.first) }
        if c.voiceOverPaused, c.shortcut(target)?.modifiers.isSuperset(of: [.control, .option]) == true { return .voiceOverPaused }
        if let other = c.runningManagers.first { return .otherManager(other) }
        return .next(target)
    }
}
