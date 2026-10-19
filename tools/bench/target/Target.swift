// Target.swift — the ONLY window the benchmark harness is allowed to move.
//
// One ordinary titled window named "NOKTA-BENCH-<nonce>". The app is an .accessory process
// (no Dock icon, no menu bar) and the window is ordered front WITHOUT activating the app, so the
// user's focus is never stolen. Prints "TARGET_READY <pid>" on stdout once the window is on
// screen and quits by itself after --seconds (default 60).
//
//   nokta-bench-target [--seconds N] [--nonce S]
//
// Built by tools/bench/build.sh:  swiftc -O Target.swift -o tools/bench/.build/nokta-bench-target

import AppKit

var seconds = 60.0
var nonce = ""
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--seconds": if let v = it.next(), let d = Double(v), d > 0 { seconds = d }
        case "--nonce": if let v = it.next() { nonce = v }
        default: break
        }
    }
}
if nonce.isEmpty { nonce = String(UInt32.random(in: 0...UInt32.max), radix: 16) }

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let win = NSWindow(
            contentRect: NSRect(x: 120, y: 160, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        win.title = "NOKTA-BENCH-\(nonce)"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 120, height: 80)

        let label = NSTextField(labelWithString: "Nokta benchmark target\nthis window is moved by tools/bench/latency")
        label.alignment = .center
        label.maximumNumberOfLines = 0
        win.contentView = label

        // Visible, but the app is never activated: no focus change for the user.
        win.orderFrontRegardless()
        window = win

        print("TARGET_READY \(getpid())")
        fflush(stdout)

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
