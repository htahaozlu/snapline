import AppKit

/// Process-relative start marker for the startup benchmark's phase trace.
let processStartTicks = mach_absolute_time()

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
