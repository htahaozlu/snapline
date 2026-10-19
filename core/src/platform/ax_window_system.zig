//! Real `window_system.WindowSystem` backed by the macOS Accessibility API.
//! Main thread only. Window handles are AXUIElementRefs (+1 when returned).

const std = @import("std");
const t = @import("../types.zig");
const geometry = @import("../geometry.zig");
const wsys = @import("../window_system.zig");
const cf = @import("cf.zig");
const ax = @import("ax.zig");
const cg = @import("cg.zig");
const carbon = @import("carbon.zig");
const dispatch = @import("dispatch.zig");

const Window = wsys.Window;

/// Global AX messaging timeout (set on the system-wide element = process default).
pub const messaging_timeout_s: f32 = 0.5;
/// How long a frame() result may be reused by setFrame() to pick the call order.
const frame_cache_ns: u64 = 500 * std.time.ns_per_ms;
/// Parent steps tried by windowAt() after the hit element itself.
const max_parent_steps = 8;

pub const AxWindowSystem = struct {
    system_wide: ax.ElementRef,
    /// Deferred calls not yet run; cancelled (detached, not freed) in deinit.
    deferred: DeferQueue = .{},
    /// Last frame read/applied, keyed by a retained handle (pointer identity is exact
    /// while we hold the reference). Only used to choose the setFrame call order.
    cache_w: ?Window = null,
    cache_frame: t.Rect = .{},
    cache_ns: u64 = 0,
    /// Usable frames supplied by the shell (NSScreen.visibleFrame, CG coordinates). Preferred
    /// over HIWindowGetAvailablePositioningBounds, which applies the main display's menu-bar
    /// height to every display and is 2 pt off on notched built-in displays (measured).
    overrides: [t.max_displays]Override = undefined,
    override_count: usize = 0,

    const Override = struct { id: cg.DisplayID, usable: t.Rect };

    /// `usable == null` removes the override for `id`; `id == 0` with null clears all.
    pub fn setUsableOverride(self: *AxWindowSystem, id: cg.DisplayID, usable: ?t.Rect) void {
        if (id == 0 and usable == null) {
            self.override_count = 0;
            return;
        }
        var i: usize = 0;
        while (i < self.override_count) : (i += 1) {
            if (self.overrides[i].id != id) continue;
            if (usable) |u| {
                self.overrides[i].usable = u;
            } else {
                self.overrides[i] = self.overrides[self.override_count - 1];
                self.override_count -= 1;
            }
            return;
        }
        const u = usable orelse return;
        if (self.override_count == self.overrides.len) return;
        self.overrides[self.override_count] = .{ .id = id, .usable = u };
        self.override_count += 1;
    }

    fn usableFor(self: *const AxWindowSystem, id: cg.DisplayID, bounds: t.Rect) t.Rect {
        for (self.overrides[0..self.override_count]) |o| {
            if (o.id != id) continue;
            // Accept only a sane override: non-empty and inside the display bounds.
            const clipped = geometry.intersection(o.usable, bounds);
            if (!clipped.isEmpty() and geometry.approxEqual(clipped, o.usable, 0.5)) return o.usable;
        }
        return usableFrame(id, bounds);
    }

    pub const Error = error{OutOfMemory};

    pub fn init() Error!AxWindowSystem {
        if (!ax.loadStrings()) return error.OutOfMemory;
        const sw = ax.AXUIElementCreateSystemWide() orelse return error.OutOfMemory;
        _ = ax.AXUIElementSetMessagingTimeout(sw, messaging_timeout_s);
        return .{ .system_wide = sw };
    }

    /// Must run after Engine.deinit (the engine releases its windows through us) and
    /// before the owning memory is freed: detaches every queued deferred call.
    pub fn deinit(self: *AxWindowSystem) void {
        self.deferred.cancelAll();
        self.forget();
        cf.release(self.system_wide);
    }

    pub fn windowSystem(self: *AxWindowSystem) wsys.WindowSystem {
        return .{ .ctx = self, .vtable = &vtable };
    }

    // ---- frame cache --------------------------------------------------------

    fn remember(self: *AxWindowSystem, w: Window, r: t.Rect) void {
        if (self.cache_w) |old| {
            if (old != w) {
                cf.retain(w);
                cf.release(old);
            }
        } else cf.retain(w);
        self.cache_w = w;
        self.cache_frame = r;
        self.cache_ns = dispatch.nowNs();
    }

    fn forget(self: *AxWindowSystem) void {
        if (self.cache_w) |old| cf.release(old);
        self.cache_w = null;
    }

    fn cached(self: *const AxWindowSystem, w: Window) ?t.Rect {
        const cw = self.cache_w orelse return null;
        if (cw != w) return null;
        if (dispatch.nowNs() -% self.cache_ns > frame_cache_ns) return null;
        return self.cache_frame;
    }

    // ---- operations (also usable directly, e.g. by the smoke harness) --------

    /// `why` (on null): .not_trusted when Accessibility was revoked, .ax when the app did not
    /// answer within the messaging timeout, else .no_window.
    pub fn focusedWindow(self: *AxWindowSystem, pid: i32, why: *t.Result) ?Window {
        _ = self;
        why.* = .no_window;
        if (pid <= 0) return null;
        const app = ax.AXUIElementCreateApplication(pid) orelse return null;
        defer cf.release(app);
        // A hung app times out once (messaging timeout); don't pay it again per fallback.
        var e: ax.Error = ax.err.success;
        if (ax.copyAttrErr(app, ax.str.focused_window, &e)) |v| {
            if (ax.isElement(v)) return win(ax.asElement(v));
            cf.CFRelease(v);
        }
        if (focusFailure(e)) |r| {
            why.* = r;
            return null;
        }
        if (ax.copyAttrErr(app, ax.str.main_window, &e)) |v| {
            if (ax.isElement(v)) return win(ax.asElement(v));
            cf.CFRelease(v);
        }
        if (focusFailure(e)) |r| {
            why.* = r;
            return null;
        }
        const v = ax.copyAttr(app, ax.str.windows) orelse return null;
        defer cf.CFRelease(v);
        if (!cf.isType(v, cf.CFArrayGetTypeID())) return null;
        const first = cf.arrayAt(@ptrCast(v), 0) orelse return null;
        if (!ax.isElement(first)) return null;
        _ = cf.CFRetain(first);
        return win(ax.asElement(first));
    }

    pub fn windowAt(self: *AxWindowSystem, p: t.Point) ?Window {
        if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) return null;
        var hit: ?ax.ElementRef = null;
        const e = ax.AXUIElementCopyElementAtPosition(self.system_wide, @floatCast(p.x), @floatCast(p.y), &hit);
        if (e != ax.err.success) {
            if (hit) |h| cf.release(h);
            return null;
        }
        var cur = hit orelse return null;
        var step: u32 = 0;
        while (step <= max_parent_steps) : (step += 1) {
            // One round trip per element: [AXRole, AXWindow, AXParent].
            const vals = ax.copyMany(cur, ax.str.list_hit) orelse break;
            if (ax.stringEquals(cf.arrayAt(vals, 0), ax.str.window)) {
                cf.release(vals);
                return win(cur);
            }
            var next: ?ax.ElementRef = null;
            if (cf.arrayAt(vals, 1)) |wv| {
                if (ax.isElement(wv) and cf.CFEqual(wv, cur) == 0) next = ax.asElement(wv);
            }
            if (next == null) {
                if (cf.arrayAt(vals, 2)) |pv| {
                    if (ax.isElement(pv)) next = ax.asElement(pv);
                }
            }
            if (next) |n| cf.retain(n);
            cf.release(vals);
            cf.release(cur);
            cur = next orelse return null;
        }
        cf.release(cur);
        return null;
    }

    /// Frame without touching the cache (one round trip).
    pub fn readFrame(self: *AxWindowSystem, w: Window) ?t.Rect {
        _ = self;
        const vals = ax.copyMany(el(w), ax.str.list_frame) orelse return null;
        defer cf.release(vals);
        const p = ax.pointValue(cf.arrayAt(vals, 0)) orelse return null;
        const s = ax.sizeValue(cf.arrayAt(vals, 1)) orelse return null;
        return .{ .x = p.x, .y = p.y, .w = s.width, .h = s.height };
    }

    pub fn frame(self: *AxWindowSystem, w: Window) ?t.Rect {
        const r = self.readFrame(w) orelse return null;
        self.remember(w, r);
        return r;
    }

    /// Order of AX calls chosen by `setFrame` (exposed for the smoke harness).
    pub const Order = enum { position_size, size_position_size };

    pub fn orderFor(self: *AxWindowSystem, w: Window, r: t.Rect) Order {
        const cur = self.cached(w) orelse self.readFrame(w) orelse return .size_position_size;
        const a = cg.displayAt(.{ .x = cur.midX(), .y = cur.midY() });
        const b = cg.displayAt(.{ .x = r.midX(), .y = r.midY() });
        return if (a != 0 and a == b) .position_size else .size_position_size;
    }

    pub fn setFrame(self: *AxWindowSystem, w: Window, r: t.Rect) wsys.SetResult {
        if (!validRect(r)) return .{ .rc = .invalid };
        return self.setFrameOrdered(w, r, self.orderFor(w, r));
    }

    /// A refused size (not settable / unsupported) after a successful move is reported as
    /// `size_refused`, not as an error: the window moved, it just keeps its size.
    pub fn setFrameOrdered(self: *AxWindowSystem, w: Window, r: t.Rect, order: Order) wsys.SetResult {
        if (!validRect(r)) return .{ .rc = .invalid };
        const e = el(w);

        // Once per operation (all AX calls below), never per call/frame.
        var eui = EnhancedUi.begin(ax.pid(e));
        defer eui.end();

        const pos = cg.Point{ .x = r.x, .y = r.y };
        const size = cg.Size{ .width = r.w, .height = r.h };
        const res: wsys.SetResult = switch (order) {
            .position_size => blk: {
                const rp = classify(ax.setPoint(e, ax.str.position, pos), e, ax.str.position);
                if (rp != .ok) break :blk .{ .rc = rp };
                break :blk sizeOutcome(classify(ax.setSize(e, ax.str.size, size), e, ax.str.size));
            },
            .size_position_size => blk: {
                // Size first so the window fits the destination display, then move, then
                // size again (the old display may have clamped the first resize).
                const rs = classify(ax.setSize(e, ax.str.size, size), e, ax.str.size);
                if (rs != .ok and rs != .not_movable) break :blk .{ .rc = rs };
                const rp = classify(ax.setPoint(e, ax.str.position, pos), e, ax.str.position);
                if (rp != .ok) break :blk .{ .rc = rp };
                if (rs == .not_movable) break :blk .{ .rc = .ok, .size_refused = true };
                break :blk sizeOutcome(classify(ax.setSize(e, ax.str.size, size), e, ax.str.size));
            },
        };
        if (res.rc == .ok and !res.size_refused) self.remember(w, r) else self.forget();
        return res;
    }

    /// One position write; AXEnhancedUserInterface is left alone (a pure move is not animated).
    pub fn setPosition(self: *AxWindowSystem, w: Window, p: t.Point) t.Result {
        if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) return .invalid;
        const e = el(w);
        const rc = classify(ax.setPoint(e, ax.str.position, .{ .x = p.x, .y = p.y }), e, ax.str.position);
        if (rc == .ok) {
            if (self.cached(w)) |f| self.remember(w, .{ .x = p.x, .y = p.y, .w = f.w, .h = f.h });
        } else self.forget();
        return rc;
    }

    pub fn info(self: *AxWindowSystem, w: Window) ?wsys.WindowInfo {
        _ = self;
        const e = el(w);
        const vals = ax.copyMany(e, ax.str.list_info) orelse return null;
        defer cf.release(vals);
        const is_window = ax.stringEquals(cf.arrayAt(vals, 0), ax.str.window);
        const is_standard = ax.stringEquals(cf.arrayAt(vals, 1), ax.str.standard_window_subrole);
        const full_screen = if (cf.arrayAt(vals, 2)) |v| cf.boolValue(v) orelse false else false;
        return .{
            .pid = ax.pid(e),
            .standard = is_window and is_standard and !full_screen,
            .movable = ax.isSettable(e, ax.str.position) orelse false,
            .resizable = ax.isSettable(e, ax.str.size) orelse false,
        };
    }

    pub fn displays(self: *AxWindowSystem, out: []t.Display) usize {
        var ids: [t.max_displays]cg.DisplayID = undefined;
        const cap: u32 = @intCast(@min(out.len, ids.len));
        if (cap == 0) return 0;
        var n: u32 = 0;
        if (cg.CGGetActiveDisplayList(cap, &ids, &n) != cg.success) return 0;
        var count: usize = 0;
        for (ids[0..@min(n, cap)]) |id| {
            // Secondary members of a mirror set duplicate the primary's bounds.
            if (cg.CGDisplayMirrorsDisplay(id) != 0) continue;
            const bounds = cg.toRect(cg.CGDisplayBounds(id));
            if (bounds.isEmpty()) continue;
            out[count] = .{ .id = id, .bounds = bounds, .usable = self.usableFor(id, bounds) };
            count += 1;
        }
        return count;
    }

    pub fn deferCall(self: *AxWindowSystem, delay_ns: u64, f: wsys.DeferredFn, arg: *anyopaque) void {
        _ = self.deferred.add(delay_ns, f, arg);
    }
};

/// AXEnhancedUserInterface policy, isolated here so v0.2 can refine it (e.g. skip the
/// restore for Chromium-based apps, where re-enabling is expensive). When on, many apps
/// animate or defer AX frame changes. v0.1: if the app has it on, clear it once for the
/// whole setFrame operation and restore it afterwards (accessibility correctness).
const EnhancedUi = struct {
    app: ?ax.ElementRef = null,
    restore: bool = false,

    fn begin(pid: i32) EnhancedUi {
        if (pid <= 0) return .{};
        const app = ax.AXUIElementCreateApplication(pid) orelse return .{};
        var s = EnhancedUi{ .app = app };
        if (ax.boolAttr(app, ax.str.enhanced_ui) orelse false)
            s.restore = ax.setBoolAttr(app, ax.str.enhanced_ui, false) == ax.err.success;
        return s;
    }

    fn end(self: *EnhancedUi) void {
        const app = self.app orelse return;
        if (self.restore) _ = ax.setBoolAttr(app, ax.str.enhanced_ui, true);
        cf.release(app);
        self.* = .{};
    }
};

/// WindowSystem.deferCall with destroy-safe lifetime.
///
/// Every call is a small heap trampoline (`Thunk`) owned by libdispatch until it runs. The
/// queue only links the pending trampolines. `cancelAll` (AxWindowSystem.deinit, i.e.
/// nk_core_destroy) detaches them: a detached trampoline still fires later, but it frees
/// only itself and never touches the queue or calls `f` — so the engine pointer `arg`
/// (which lives inside the freed nk_core) is never dereferenced. No reference to the
/// owner survives in a detached trampoline, so the core can be freed immediately.
pub const DeferQueue = struct {
    pending: ?*Thunk = null,
    count: u32 = 0,
    gpa: std.mem.Allocator = std.heap.c_allocator,
    schedule: *const fn (delay_ns: u64, ctx: ?*anyopaque, work: dispatch.Function) void = dispatch.onMain,

    /// false on OOM: the call is dropped (never run re-entrantly).
    pub fn add(self: *DeferQueue, delay_ns: u64, f: wsys.DeferredFn, arg: *anyopaque) bool {
        const th = self.gpa.create(Thunk) catch return false;
        th.* = .{ .owner = self, .gpa = self.gpa, .next = self.pending, .f = f, .arg = arg };
        if (self.pending) |p| p.prev = th;
        self.pending = th;
        self.count += 1;
        self.schedule(delay_ns, th, Thunk.run);
        return true;
    }

    pub fn cancelAll(self: *DeferQueue) void {
        var it = self.pending;
        while (it) |th| {
            it = th.next;
            th.owner = null;
            th.prev = null;
            th.next = null;
        }
        self.pending = null;
        self.count = 0;
    }
};

const Thunk = struct {
    owner: ?*DeferQueue,
    gpa: std.mem.Allocator,
    prev: ?*Thunk = null,
    next: ?*Thunk = null,
    f: wsys.DeferredFn,
    arg: *anyopaque,

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const th: *Thunk = @ptrCast(@alignCast(ctx orelse return));
        const owner = th.owner;
        if (owner) |q| {
            if (th.prev) |p| p.next = th.next else q.pending = th.next;
            if (th.next) |n| n.prev = th.prev;
            q.count -= 1;
        }
        const f = th.f;
        const arg = th.arg;
        th.gpa.destroy(th); // before f: f may queue new calls or (against the rules) destroy
        if (owner != null) f(arg);
    }
};

// ---- helpers ----------------------------------------------------------------

inline fn el(w: Window) ax.ElementRef {
    return @ptrCast(w);
}

inline fn win(e: ax.ElementRef) Window {
    return @ptrCast(e);
}

fn validRect(r: t.Rect) bool {
    return std.math.isFinite(r.x) and std.math.isFinite(r.y) and std.math.isFinite(r.w) and
        std.math.isFinite(r.h) and r.w >= 1 and r.h >= 1;
}

/// AX error of a frame setter → Result. Unsupported / not-settable → not_movable.
fn classify(e: ax.Error, element: ax.ElementRef, attr: cf.StringRef) t.Result {
    return switch (e) {
        ax.err.success => .ok,
        ax.err.attribute_unsupported => .not_movable,
        ax.err.api_disabled => .not_trusted,
        ax.err.illegal_argument, ax.err.failure, ax.err.not_implemented => if (ax.isSettable(element, attr) == false) .not_movable else .ax,
        else => .ax, // cannot_complete (timeout / app busy), invalid_ui_element (window gone)
    };
}

/// A window that moved but refuses resizing (fixed-size panel) counts as applied.
fn sizeOutcome(r: t.Result) wsys.SetResult {
    return if (r == .not_movable) .{ .rc = .ok, .size_refused = true } else .{ .rc = r };
}

/// Focus lookup errors that end the search (no point asking for the main window next).
fn focusFailure(e: ax.Error) ?t.Result {
    return switch (e) {
        ax.err.api_disabled => .not_trusted,
        ax.err.cannot_complete => .ax,
        else => null,
    };
}

fn usableFrame(id: cg.DisplayID, bounds: t.Rect) t.Rect {
    var r: cg.Rect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    const st = carbon.availablePositioningBounds(id, &r) orelse return bounds;
    if (st != carbon.no_err) return bounds;
    const u = cg.toRect(r);
    if (u.isEmpty() or !within(u, bounds)) return bounds;
    return u;
}

fn within(inner: t.Rect, outer: t.Rect) bool {
    const tol = 0.5;
    return inner.minX() >= outer.minX() - tol and inner.minY() >= outer.minY() - tol and
        inner.maxX() <= outer.maxX() + tol and inner.maxY() <= outer.maxY() + tol;
}

// ---- vtable -------------------------------------------------------------------

inline fn me(ctx: *anyopaque) *AxWindowSystem {
    return @ptrCast(@alignCast(ctx));
}

fn vFocusedWindow(ctx: *anyopaque, pid: i32, why: *t.Result) ?Window {
    return me(ctx).focusedWindow(pid, why);
}
fn vWindowAt(ctx: *anyopaque, p: t.Point) ?Window {
    return me(ctx).windowAt(p);
}
fn vFrame(ctx: *anyopaque, w: Window) ?t.Rect {
    return me(ctx).frame(w);
}
fn vSetFrame(ctx: *anyopaque, w: Window, r: t.Rect) wsys.SetResult {
    return me(ctx).setFrame(w, r);
}
fn vSetPosition(ctx: *anyopaque, w: Window, p: t.Point) t.Result {
    return me(ctx).setPosition(w, p);
}
fn vInfo(ctx: *anyopaque, w: Window) ?wsys.WindowInfo {
    return me(ctx).info(w);
}
fn vWindowPid(ctx: *anyopaque, w: Window) i32 {
    _ = ctx;
    return ax.pid(el(w));
}
fn vSame(ctx: *anyopaque, a: Window, b: Window) bool {
    _ = ctx;
    return a == b or cf.CFEqual(a, b) != 0;
}
fn vRetain(ctx: *anyopaque, w: Window) void {
    _ = ctx;
    cf.retain(w);
}
fn vRelease(ctx: *anyopaque, w: Window) void {
    _ = ctx;
    cf.release(w);
}
fn vDisplays(ctx: *anyopaque, out: []t.Display) usize {
    return me(ctx).displays(out);
}
fn vNowNs(ctx: *anyopaque) u64 {
    _ = ctx;
    return dispatch.nowNs();
}
fn vDeferCall(ctx: *anyopaque, delay_ns: u64, f: wsys.DeferredFn, arg: *anyopaque) void {
    me(ctx).deferCall(delay_ns, f, arg);
}

const vtable = wsys.WindowSystem.VTable{
    .focusedWindow = vFocusedWindow,
    .windowAt = vWindowAt,
    .frame = vFrame,
    .setFrame = vSetFrame,
    .setPosition = vSetPosition,
    .info = vInfo,
    .windowPid = vWindowPid,
    .same = vSame,
    .retain = vRetain,
    .release = vRelease,
    .displays = vDisplays,
    .nowNs = vNowNs,
    .deferCall = vDeferCall,
};

test "deferred calls: run in order, dropped after cancelAll (nk_core_destroy), no leaks" {
    const Fake = struct {
        var ctxs: [4]?*anyopaque = @splat(null);
        var works: [4]?dispatch.Function = @splat(null);
        var delays: [4]u64 = @splat(0);
        var n: usize = 0;
        fn schedule(delay_ns: u64, ctx: ?*anyopaque, work: dispatch.Function) void {
            ctxs[n] = ctx;
            works[n] = work;
            delays[n] = delay_ns;
            n += 1;
        }
        fn fire(i: usize) void {
            works[i].?(ctxs[i]);
        }
    };
    const Hit = struct {
        fn f(arg: *anyopaque) void {
            const p: *u32 = @ptrCast(@alignCast(arg));
            p.* += 1;
        }
    };
    var hits: u32 = 0;
    // The queue lives in heap memory like the real one (inside nk_core).
    const q = try std.testing.allocator.create(DeferQueue);
    q.* = .{ .gpa = std.testing.allocator, .schedule = Fake.schedule };
    try std.testing.expect(q.add(0, Hit.f, &hits));
    try std.testing.expect(q.add(5_000_000, Hit.f, &hits));
    try std.testing.expect(q.add(0, Hit.f, &hits));
    try std.testing.expectEqual(@as(u32, 3), q.count);
    try std.testing.expectEqual(@as(u64, 5_000_000), Fake.delays[1]);

    Fake.fire(0); // normal delivery while the core is alive
    try std.testing.expectEqual(@as(u32, 1), hits);
    try std.testing.expectEqual(@as(u32, 2), q.count);

    q.cancelAll(); // what nk_core_destroy does (via AxWindowSystem.deinit)
    try std.testing.expectEqual(@as(u32, 0), q.count);
    q.* = undefined; // poison, then free: a detached trampoline must not touch it
    std.testing.allocator.destroy(q);

    Fake.fire(2);
    Fake.fire(1);
    try std.testing.expectEqual(@as(u32, 1), hits); // engine never called after destroy
    // std.testing.allocator fails the test if any trampoline leaked.
}

test "within / validRect" {
    try std.testing.expect(within(.{ .x = 0, .y = 31, .w = 1920, .h = 1049 }, .{ .x = 0, .y = 0, .w = 1920, .h = 1080 }));
    try std.testing.expect(!within(.{ .x = -10, .y = 0, .w = 100, .h = 100 }, .{ .x = 0, .y = 0, .w = 1920, .h = 1080 }));
    try std.testing.expect(validRect(.{ .x = 0, .y = 0, .w = 10, .h = 10 }));
    try std.testing.expect(!validRect(.{ .x = 0, .y = 0, .w = 0, .h = 10 }));
    try std.testing.expect(!validRect(.{ .x = std.math.nan(f64), .y = 0, .w = 10, .h = 10 }));
}
