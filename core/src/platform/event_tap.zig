//! Listen-only session event tap for drag-to-snap: left mouse down/dragged/up only (no
//! mouseMoved → zero idle cost; no keyboard-class events such as flagsChanged, which could
//! require Input Monitoring — modifiers are read from each mouse event's flags instead).
//! Events are never modified.

const t = @import("../types.zig");
const Engine = @import("../engine.zig").Engine;
const cf = @import("cf.zig");
const cg = @import("cg.zig");
const dispatch = @import("dispatch.zig");

pub const mask: cg.EventMask = cg.maskBit(cg.event_type.left_mouse_down) |
    cg.maskBit(cg.event_type.left_mouse_up) |
    cg.maskBit(cg.event_type.left_mouse_dragged);

pub const EventTap = struct {
    engine: *Engine,
    port: ?cf.MachPortRef = null,
    source: ?cf.RunLoopSourceRef = null,
    /// Last Nokta modifier mask forwarded to the engine.
    last_mods: u32 = 0,

    /// Creates the tap and adds it to the main run loop (common modes). false if
    /// CGEventTapCreate fails (no Accessibility / Input Monitoring permission).
    pub fn start(self: *EventTap) bool {
        if (self.port != null) return true;
        const port = cg.CGEventTapCreate(
            cg.tap_location.session,
            cg.head_insert,
            cg.tap_option_listen_only,
            mask,
            callback,
            self,
        ) orelse return false;
        const src = cf.CFMachPortCreateRunLoopSource(null, port, 0) orelse {
            cf.CFMachPortInvalidate(port);
            cf.release(port);
            return false;
        };
        cf.CFRunLoopAddSource(cf.CFRunLoopGetMain(), src, cf.kCFRunLoopCommonModes);
        cg.CGEventTapEnable(port, true);
        self.port = port;
        self.source = src;
        self.last_mods = 0;
        return true;
    }

    /// Removes the tap. Idempotent.
    pub fn stop(self: *EventTap) void {
        if (self.port) |p| cg.CGEventTapEnable(p, false);
        if (self.source) |s| {
            cf.CFRunLoopRemoveSource(cf.CFRunLoopGetMain(), s, cf.kCFRunLoopCommonModes);
            cf.release(s);
        }
        if (self.port) |p| {
            cf.CFMachPortInvalidate(p);
            cf.release(p);
        }
        self.port = null;
        self.source = null;
    }

    pub fn created(self: *const EventTap) bool {
        return self.port != null;
    }

    pub fn isActive(self: *const EventTap) bool {
        const p = self.port orelse return false;
        return cg.CGEventTapIsEnabled(p);
    }
};

fn callback(proxy: cg.EventTapProxy, ty: u32, event: ?cg.EventRef, user_info: ?*anyopaque) callconv(.c) ?cg.EventRef {
    _ = proxy;
    const self: *EventTap = @ptrCast(@alignCast(user_info orelse return event));
    switch (ty) {
        cg.event_type.tap_disabled_by_timeout, cg.event_type.tap_disabled_by_user_input => {
            // Events were lost while disabled (possibly the mouse-up): drop any half drag.
            self.engine.cancelDrag();
            if (self.port) |p| cg.CGEventTapEnable(p, true);
            return event;
        },
        else => {},
    }
    const ev = event orelse return event;
    // Clock: nowNs() at callback entry — the same mach clock as WindowSystem.nowNs(), which
    // the engine subtracts from (drag latency = nowNs() - t_up). CGEventGetTimestamp is
    // not used: its unit (documented "ns since startup", mach ticks on some hardware)
    // would need a conversion we cannot verify without running a tap. Cost: the tap's
    // own delivery delay is not part of the measured latency.
    const now = dispatch.nowNs();
    const mods = cg.modsFromFlags(cg.CGEventGetFlags(ev));
    if (ty == cg.event_type.flags_changed) {
        self.last_mods = mods;
        self.engine.flagsChanged(mods);
        return event;
    }
    // Modifiers held before the tap existed (or changed without a flagsChanged event).
    if (mods != self.last_mods) {
        self.last_mods = mods;
        self.engine.flagsChanged(mods);
    }
    const loc = cg.CGEventGetLocation(ev); // global, top-left origin
    const p = t.Point{ .x = loc.x, .y = loc.y };
    switch (ty) {
        cg.event_type.left_mouse_down => self.engine.mouseDown(p, now),
        cg.event_type.left_mouse_dragged => self.engine.mouseDragged(p, now),
        cg.event_type.left_mouse_up => self.engine.mouseUp(p, now),
        else => {},
    }
    return event;
}
