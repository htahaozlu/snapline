//! Abstract window system the engine talks to. Implemented by platform/ax.zig (real
//! Accessibility API) and mock.zig (tests). Everything runs on the main thread.
//!
//! Ownership: every `Window` returned by `focusedWindow` / `windowAt` is +1 retained; the
//! caller must `release` it. Handles passed *into* engine callbacks (e.g. AXObserver
//! notifications) are borrowed; the engine must `retain` them if it keeps them.

const t = @import("types.zig");
const Rect = t.Rect;
const Point = t.Point;
const Display = t.Display;

/// Opaque window handle (an AXUIElementRef on macOS).
pub const Window = *anyopaque;

pub const WindowInfo = struct {
    pid: i32,
    /// AXStandardWindow (not a sheet, dialog, popover, floating panel or fullscreen window).
    standard: bool,
    movable: bool,
    resizable: bool,
};

pub const DeferredFn = *const fn (arg: *anyopaque) void;

/// Outcome of `setFrame`. A window that moved but refused the size change (fixed-size
/// window) reports `rc = .ok` with `size_refused = true`.
pub const SetResult = struct {
    rc: t.Result,
    size_refused: bool = false,
};

pub const WindowSystem = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Focused window of `pid` (falls back to its main window, then first window). On null,
        /// `why` says why: .no_window, .not_trusted (Accessibility revoked) or .ax (the app
        /// did not answer in time).
        focusedWindow: *const fn (ctx: *anyopaque, pid: i32, why: *t.Result) ?Window,
        /// Top-level window under a global point.
        windowAt: *const fn (ctx: *anyopaque, p: Point) ?Window,
        /// Current frame (one round trip). null if the window is gone or AX failed.
        frame: *const fn (ctx: *anyopaque, w: Window) ?Rect,
        /// Applies a frame. Implementations choose the AX call order (position/size) and
        /// handle AXEnhancedUserInterface. Must not read the frame back (latency).
        setFrame: *const fn (ctx: *anyopaque, w: Window, r: Rect) SetResult,
        /// One position write (re-aligning a window whose size is already final).
        setPosition: *const fn (ctx: *anyopaque, w: Window, p: Point) t.Result,
        /// Role/subrole/settable checks. Several round trips: never call on the hotkey path.
        info: *const fn (ctx: *anyopaque, w: Window) ?WindowInfo,
        windowPid: *const fn (ctx: *anyopaque, w: Window) i32,
        same: *const fn (ctx: *anyopaque, a: Window, b: Window) bool,
        retain: *const fn (ctx: *anyopaque, w: Window) void,
        release: *const fn (ctx: *anyopaque, w: Window) void,
        /// Fills `out` with active displays; returns the count. May be slow (~0.2 ms per
        /// display) — the engine caches the result until `Engine.displaysChanged`.
        displays: *const fn (ctx: *anyopaque, out: []Display) usize,
        /// Monotonic nanoseconds.
        nowNs: *const fn (ctx: *anyopaque) u64,
        /// Runs `f(arg)` on the main thread after `delay_ns` (0 = next run-loop turn).
        deferCall: *const fn (ctx: *anyopaque, delay_ns: u64, f: DeferredFn, arg: *anyopaque) void,
    };

    pub inline fn focusedWindow(s: WindowSystem, pid: i32, why: *t.Result) ?Window {
        return s.vtable.focusedWindow(s.ctx, pid, why);
    }
    pub inline fn windowAt(s: WindowSystem, p: Point) ?Window {
        return s.vtable.windowAt(s.ctx, p);
    }
    pub inline fn frame(s: WindowSystem, w: Window) ?Rect {
        return s.vtable.frame(s.ctx, w);
    }
    pub inline fn setFrame(s: WindowSystem, w: Window, r: Rect) SetResult {
        return s.vtable.setFrame(s.ctx, w, r);
    }
    pub inline fn setPosition(s: WindowSystem, w: Window, p: Point) t.Result {
        return s.vtable.setPosition(s.ctx, w, p);
    }
    pub inline fn info(s: WindowSystem, w: Window) ?WindowInfo {
        return s.vtable.info(s.ctx, w);
    }
    pub inline fn windowPid(s: WindowSystem, w: Window) i32 {
        return s.vtable.windowPid(s.ctx, w);
    }
    pub inline fn same(s: WindowSystem, a: Window, b: Window) bool {
        return s.vtable.same(s.ctx, a, b);
    }
    pub inline fn retain(s: WindowSystem, w: Window) void {
        s.vtable.retain(s.ctx, w);
    }
    pub inline fn release(s: WindowSystem, w: Window) void {
        s.vtable.release(s.ctx, w);
    }
    pub inline fn displays(s: WindowSystem, out: []Display) usize {
        return s.vtable.displays(s.ctx, out);
    }
    pub inline fn nowNs(s: WindowSystem) u64 {
        return s.vtable.nowNs(s.ctx);
    }
    pub inline fn deferCall(s: WindowSystem, delay_ns: u64, f: DeferredFn, arg: *anyopaque) void {
        s.vtable.deferCall(s.ctx, delay_ns, f, arg);
    }
};

/// Where the engine sends events (the C callback in production, a recorder in tests).
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    emitFn: ?*const fn (ctx: ?*anyopaque, ev: *const t.Event) void = null,

    pub fn emit(s: Sink, ev: t.Event) void {
        if (s.emitFn) |f| f(s.ctx, &ev);
    }
};
