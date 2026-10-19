import AppKit

/// Snap labels (docs/DESIGN.md §10.1): General › Snap labels = Never | When needed (default) |
/// Always. Drawn inside the overlay panel as the label plate (O7) — no separate HUD window. API:
/// `init(prefs:overlay:)`, `show(_:)`.
///
/// "When needed" = the cases where the frame alone does not tell the story: a size cycle
/// (`Left ⅔`), a display move (`Display 2`), a size notice (`Can't get smaller`, `Can't resize`)
/// and every blocked snap (`No window` …). One line each. VoiceOver hears a full sentence for
/// every event, even with Never (`HUDText.spoken`).
final class HUDController {
    private let prefs: Preferences
    private unowned let overlay: SnapOverlayController

    init(prefs: Preferences, overlay: SnapOverlayController) {
        self.prefs = prefs
        self.overlay = overlay
    }

    func show(_ event: NoktaEvent) {
        guard event.kind == .snapped || event.kind == .failed else { return }
        let mode = prefs.hudMode
        var label = HUDText.label(for: event, mode: mode, displayNumber: HUDText.displayNumber(event.displayID))
        // Nokta's own fixed-size windows (onboarding "try it") keep their size by design:
        // a "Can't get smaller" / "Can't resize" plate there would read as a failure.
        if event.kind == .snapped, event.frameDiffers || event.sizeRefused, NSApp.isActive { label = nil }
        if let label, mode != .off {
            let blocked = event.kind == .failed
            overlay.showLabel(label, rectCG: event.rect.isEmpty ? nil : event.rect, displayID: event.displayID, blocked: blocked)
        } else if event.kind == .snapped {
            // Next input interrupts a long blocked label.
            overlay.dismissLabel()
        }
        if AccessibilityEnv.shared.voiceOverEnabled {
            let app = NSWorkspace.shared.frontmostApplication?.localizedName
            if let spoken = HUDText.spoken(for: event, appName: app, displayNumber: HUDText.displayNumber(event.displayID)) {
                AccessibilityEnv.announce(spoken)
            }
        }
    }
}

/// Label and announcement texts (pure; DESIGN §10.1 table). Sentence case, real fractions,
/// `Middle` for the centre thirds (so they never read like the `Center` action).
enum HUDText {
    /// Plate text for an event, or nil when this mode shows nothing.
    static func label(for e: NoktaEvent, mode: Preferences.HUDMode, displayNumber: Int?) -> String? {
        if mode == .off { return nil }
        if e.kind == .failed { return blockedTitle(e.result) }
        guard e.kind == .snapped, let action = e.action else { return nil }
        // A fixed-size window that is also larger than the tile is explained by "can't resize".
        if e.sizeRefused { return "Can't resize" }
        if e.frameDiffers { return "Can't get smaller" }
        if action == .nextDisplay || action == .prevDisplay { return "Display \(displayNumber ?? 1)" }
        switch mode {
        case .off: return nil
        case .whenNeeded: return e.cycle > 0 ? actionTitle(action, cycle: e.cycle) : nil
        case .always: return actionTitle(action, cycle: e.cycle)
        }
    }

    /// `Left ½` … with the size the cycle actually applied (½ → ⅔ → ⅓).
    static func actionTitle(_ a: NoktaAction, cycle: UInt32 = 0) -> String? {
        let size = ["½", "⅔", "⅓"][Int(cycle) % 3]
        switch a {
        case .leftHalf: return "Left \(size)"
        case .rightHalf: return "Right \(size)"
        case .topHalf: return "Top \(size)"
        case .bottomHalf: return "Bottom \(size)"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .firstThird: return "First ⅓"
        case .centerThird: return "Middle ⅓"
        case .lastThird: return "Last ⅓"
        case .firstTwoThirds: return "First ⅔"
        case .centerTwoThirds: return "Middle ⅔"
        case .lastTwoThirds: return "Last ⅔"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .center: return "Center"
        case .restore: return "Restored"
        case .nextDisplay, .prevDisplay: return nil
        }
    }

    /// Blocked labels. `.invalid` (nothing to restore, single display) shows nothing.
    static func blockedTitle(_ r: NoktaResult) -> String? {
        switch r {
        case .noWindow: return "No window"
        case .notMovable: return "Can't move"
        case .excluded: return "Ignored app"
        case .notTrusted: return "Needs Accessibility"
        case .ax: return "App didn't respond"
        default: return nil
        }
    }

    /// Full VoiceOver sentence for a blocked snap.
    static func failureReason(_ r: NoktaResult) -> String? {
        switch r {
        case .noWindow: return "There's no window to move."
        case .notMovable: return "This window can't be moved."
        case .excluded: return "This app is on your Ignore list."
        case .notTrusted: return "\(Product.name) needs Accessibility access."
        case .ax: return "The app didn't respond to the move."
        default: return nil
        }
    }

    /// 1-based display number in the core's order (x, then y), counted over active displays only:
    /// a display that mirrors another, or one that is off (closed lid), has no number. nil if unknown.
    static func displayNumber(_ id: CGDirectDisplayID) -> Int? {
        guard id != 0 else { return nil }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        let active = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        let sorted = active.sorted {
            let a = CGDisplayBounds($0), b = CGDisplayBounds($1)
            return a.minX != b.minX ? a.minX < b.minX : a.minY < b.minY
        }
        return sorted.firstIndex(of: id).map { $0 + 1 }
    }

    /// VoiceOver suffix for the size notices (empty when the window took the requested size).
    private static func sizeNote(_ e: NoktaEvent) -> String {
        if e.sizeRefused { return ". The window can't be resized." }
        if e.frameDiffers { return ". The window has a minimum size." }
        return ""
    }

    /// VoiceOver sentence ("Moved Safari to left half").
    static func spoken(for e: NoktaEvent, appName: String?, displayNumber: Int?) -> String? {
        let app = appName ?? "the window"
        if e.kind == .failed {
            return failureReason(e.result) ?? e.result.message
        }
        guard e.kind == .snapped, let a = e.action else { return nil }
        var target: String
        switch a {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf:
            let side = a.title.replacingOccurrences(of: " Half", with: "").lowercased()
            target = side + " " + ["half", "two thirds", "third"][Int(e.cycle) % 3]
        case .nextDisplay, .prevDisplay:
            target = "display \(displayNumber ?? 1)"
        case .restore:
            return "Restored \(app)" + sizeNote(e)
        case .center:
            target = "the center"
        case .maximize:
            return "Maximized \(app)" + sizeNote(e)
        case .almostMaximize:
            return "Almost maximized \(app)" + sizeNote(e)
        default:
            target = a.title.lowercased()
        }
        return "Moved \(app) to \(target)" + sizeNote(e)
    }
}
