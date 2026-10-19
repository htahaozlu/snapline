import ApplicationServices
import Foundation

// Read-only VoiceOver-view audit of ONE process (Nokta in --bench-preview, see scripts/a11y-audit.sh):
// walks its AX tree the way VoiceOver does and lists every actionable element without a spoken
// name. Only reads attributes; never sets one, never performs an action. Exit 1 if any is unnamed.

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: axaudit <pid>"); exit(2)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1.0)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }

let actionable: Set<String> = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXSlider",
                               "AXRadioButton", "AXRadioGroup", "AXIncrementor", "AXDisclosureTriangle",
                               "AXTextField", "AXLink", "AXImage", "AXTable", "AXSwitch", "AXToggle"]
var total = 0, unnamed: [String] = []

func name(_ e: AXUIElement) -> String {
    for a in ["AXTitle", "AXDescription", "AXLabel", "AXValueDescription"] {
        let s = str(e, a).trimmingCharacters(in: .whitespaces); if !s.isEmpty { return s }
    }
    if let t = attr(e, "AXTitleUIElement") {
        let s = str(t as! AXUIElement, "AXValue"); if !s.isEmpty { return "titled-by: " + s }
    }
    return ""
}

func walk(_ e: AXUIElement, depth: Int, path: String) {
    guard depth < 30 else { return }
    let role = str(e, "AXRole")
    let sub = str(e, "AXSubrole")
    // Window buttons are spoken from their subrole ("close button"); scroll bars are system parts.
    let systemNamed: Set<String> = ["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton", "AXScrollBar"]
    if actionable.contains(role), !systemNamed.contains(sub) {
        total += 1
        let n = name(e)
        let value = (attr(e, "AXValue")).map { "\($0)" } ?? ""
        if n.isEmpty {
            var context = ""
            if let parent = attr(e, "AXParent") {
                let sibs = (attr(parent as! AXUIElement, "AXChildren") as? [AXUIElement]) ?? []
                context = sibs.map { str($0, "AXValue") + str($0, "AXTitle") + str($0, "AXDescription") }.filter { !$0.isEmpty }.joined(separator: " | ")
            }
            unnamed.append("\(path) > \(role)\(sub.isEmpty ? "" : "/" + sub) value=\(value.prefix(30)) [\(context.prefix(60))]")
        }
        else if CommandLine.arguments.contains("-v") { print("  ok \(role): \(n)") }
    }
    if role == "AXScrollBar" { return }
    for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(c, depth: depth + 1, path: path + "/" + role) }
}

for w in (attr(app, "AXWindows") as? [AXUIElement]) ?? [] {
    walk(w, depth: 0, path: "window(\(str(w, "AXTitle")))")
}
print("checked \(total) actionable elements, \(unnamed.count) without a spoken name")
for u in unnamed { print("  UNNAMED \(u)") }
// Zero elements means the window never appeared: that is a failure, not a pass.
if total == 0 { print("  no actionable elements found (window missing?)") }
exit(unnamed.isEmpty && total > 0 ? 0 : 1)
