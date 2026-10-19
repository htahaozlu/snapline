//! One AXObserver for the frontmost application: kAXWindowMoved/ResizedNotification registered
//! on the application element (covers all of its windows). Never observes our own pid.

const std = @import("std");
const Engine = @import("../engine.zig").Engine;
const cf = @import("cf.zig");
const ax = @import("ax.zig");

/// Messaging timeout for registering the notifications (the process default is 0.5 s).
const register_timeout_s: f32 = 0.25;

pub const Observer = struct {
    engine: *Engine,
    own_pid: i32,
    observer: ?ax.ObserverRef = null,
    app: ?ax.ElementRef = null,
    /// Currently observed pid (0 = none).
    pid: i32 = 0,

    pub fn init(engine: *Engine) Observer {
        return .{ .engine = engine, .own_pid = std.c.getpid() };
    }

    /// Replaces the observed application. pid <= 0 or our own pid → observe nothing.
    /// If the app is not ready for AX yet (AddNotification fails) nothing is observed;
    /// the engine then falls back to windowAt() polling during drags.
    pub fn observe(self: *Observer, pid: i32) void {
        if (pid == self.pid and self.observer != null) return;
        self.stop();
        if (pid <= 0 or pid == self.own_pid) return;
        var obs: ?ax.ObserverRef = null;
        if (ax.AXObserverCreate(pid, callback, &obs) != ax.err.success) {
            if (obs) |o| cf.release(o);
            return;
        }
        const o = obs orelse return;
        const app = ax.AXUIElementCreateApplication(pid) orelse {
            cf.release(o);
            return;
        };
        // Registration is a round trip to the app on every activation: a hung app must not
        // block the main thread for the full messaging timeout, twice.
        _ = ax.AXUIElementSetMessagingTimeout(app, register_timeout_s);
        if (ax.AXObserverAddNotification(o, app, ax.str.window_moved, self) != ax.err.success) {
            cf.release(app);
            cf.release(o);
            return;
        }
        // Resizes from the left/top edge also move the origin; the engine uses this to tell
        // them apart from drags. Optional: without it only the drag path is affected.
        _ = ax.AXObserverAddNotification(o, app, ax.str.window_resized, self);
        cf.CFRunLoopAddSource(cf.CFRunLoopGetMain(), ax.AXObserverGetRunLoopSource(o), cf.kCFRunLoopCommonModes);
        self.observer = o;
        self.app = app;
        self.pid = pid;
        self.engine.observed_pid = pid;
    }

    /// Removes the notification and the run-loop source. Idempotent.
    pub fn stop(self: *Observer) void {
        if (self.observer) |o| {
            if (self.app) |a| {
                _ = ax.AXObserverRemoveNotification(o, a, ax.str.window_moved);
                _ = ax.AXObserverRemoveNotification(o, a, ax.str.window_resized);
            }
            cf.CFRunLoopRemoveSource(cf.CFRunLoopGetMain(), ax.AXObserverGetRunLoopSource(o), cf.kCFRunLoopCommonModes);
            cf.release(o);
        }
        if (self.app) |a| cf.release(a);
        self.observer = null;
        self.app = null;
        self.pid = 0;
        self.engine.observed_pid = 0;
    }
};

fn callback(observer: ax.ObserverRef, element: ax.ElementRef, notification: cf.StringRef, refcon: ?*anyopaque) callconv(.c) void {
    const self: *Observer = @ptrCast(@alignCast(refcon orelse return));
    const current = self.observer orelse return;
    if (current != observer) return; // stale delivery from a replaced observer
    if (ax.stringEquals(notification, ax.str.window_resized)) {
        self.engine.windowResized(@ptrCast(element)); // borrowed handle
    } else {
        self.engine.windowMoved(@ptrCast(element)); // borrowed handle
    }
}
