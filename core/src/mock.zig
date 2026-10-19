//! In-memory WindowSystem for engine tests. Owned by the engine work package.
//!
//! - Windows live in a z-ordered list (index 0 = front-most) and are addressed by id.
//! - Every focusedWindow/windowAt call hands out a *fresh* handle object (refcount 1),
//!   like AXUIElementRefs: two handles for the same window are `same` but not pointer-equal.
//!   Handles are never freed before `deinit`, so over-releases are counted
//!   (`bad_releases`) instead of crashing, and `live()` reports outstanding retains.
//! - Controllable clock (`now`, `advance`), deferred-call queue (`runDeferred`), setFrame
//!   call log, failure injection and call counters.
//! - `Recorder` is a Sink that stores every event.
//!
//! Test-only: allocates from the given allocator (std.testing.allocator in tests).

const std = @import("std");
const t = @import("types.zig");
const wsm = @import("window_system.zig");

const Window = wsm.Window;
const Allocator = std.mem.Allocator;

pub const WindowId = u32;

pub const MockWindow = struct {
    id: WindowId = 0,
    pid: i32,
    frame: t.Rect,
    standard: bool = true,
    movable: bool = true,
    resizable: bool = true,
    alive: bool = true,
    /// Minimum size the app enforces (0 = none), like AppKit contentMinSize.
    min_w: f64 = 0,
    min_h: f64 = 0,
};

const Handle = struct {
    id: WindowId,
    refs: i32,
};

const Focus = struct {
    pid: i32,
    id: WindowId,
};

pub const SetFrameCall = struct {
    id: WindowId,
    rect: t.Rect,
};

const Deferred = struct {
    due: u64,
    f: wsm.DeferredFn,
    arg: *anyopaque,
};

pub const Mock = struct {
    gpa: Allocator,
    /// z-order: index 0 is the front-most window.
    windows: std.ArrayList(MockWindow) = .empty,
    focus: std.ArrayList(Focus) = .empty,
    display_list: std.ArrayList(t.Display) = .empty,
    handles: std.ArrayList(*Handle) = .empty,
    deferred: std.ArrayList(Deferred) = .empty,
    set_frame_calls: std.ArrayList(SetFrameCall) = .empty,
    set_position_calls: u32 = 0,

    now: u64 = 1_000_000_000,
    next_id: WindowId = 1,

    // ---- failure injection / app behaviour ----
    /// The next `set_frame_fail_count` setFrame calls return `set_frame_fail` (no change).
    set_frame_fail: t.Result = .ok,
    set_frame_fail_count: u32 = 0,
    /// frame() returns null while set.
    frame_fails: bool = false,
    /// Clock advance per setFrame call (simulated AX round trip).
    set_frame_cost_ns: u64 = 0,
    /// The app shrinks every applied size by this many points (e.g. a terminal's cell grid).
    size_slop: f64 = 0,
    /// focusedWindow() fails with this reason while set (e.g. .not_trusted, .ax).
    focus_error: ?t.Result = null,
    /// The next `stale_reads` frame() calls after a setFrame return the frame from before
    /// that setFrame (an app that applies AX changes asynchronously).
    stale_reads: u32 = 0,
    stale_frame: ?t.Rect = null,
    stale_left: u32 = 0,

    // ---- counters ----
    /// A vtable call hit an allocator failure (handle, log or deferred entry lost).
    oom: bool = false,
    retains: u64 = 0,
    releases: u64 = 0,
    bad_releases: u64 = 0,
    displays_calls: u32 = 0,
    frame_calls: u32 = 0,
    info_calls: u32 = 0,
    window_at_calls: u32 = 0,
    focused_calls: u32 = 0,

    pub fn init(gpa: Allocator) Mock {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Mock) void {
        for (self.handles.items) |h| self.gpa.destroy(h);
        self.handles.deinit(self.gpa);
        self.windows.deinit(self.gpa);
        self.focus.deinit(self.gpa);
        self.display_list.deinit(self.gpa);
        self.deferred.deinit(self.gpa);
        self.set_frame_calls.deinit(self.gpa);
    }

    pub fn windowSystem(self: *Mock) wsm.WindowSystem {
        return .{ .ctx = self, .vtable = &vtable };
    }

    // ---- scene setup ----------------------------------------------------------

    pub fn setDisplays(self: *Mock, ds: []const t.Display) !void {
        self.display_list.clearRetainingCapacity();
        try self.display_list.appendSlice(self.gpa, ds);
    }

    /// Adds a window in front of all others and returns its id.
    pub fn addWindow(self: *Mock, w: MockWindow) !WindowId {
        var nw = w;
        nw.id = self.next_id;
        self.next_id += 1;
        try self.windows.insert(self.gpa, 0, nw);
        return nw.id;
    }

    pub fn setFocused(self: *Mock, pid: i32, id: WindowId) !void {
        for (self.focus.items) |*f| {
            if (f.pid == pid) {
                f.id = id;
                return;
            }
        }
        try self.focus.append(self.gpa, .{ .pid = pid, .id = id });
    }

    /// Moves a window to the front of the z-order.
    pub fn raise(self: *Mock, id: WindowId) void {
        const i = self.indexOf(id) orelse return;
        const w = self.windows.orderedRemove(i);
        self.windows.insertAssumeCapacity(0, w);
    }

    pub fn window(self: *Mock, id: WindowId) *MockWindow {
        return &self.windows.items[self.indexOf(id).?];
    }

    pub fn frameOf(self: *Mock, id: WindowId) t.Rect {
        return self.window(id).frame;
    }

    /// User-side frame change (not logged as a setFrame call).
    pub fn setWindowFrame(self: *Mock, id: WindowId, r: t.Rect) void {
        self.window(id).frame = r;
    }

    pub fn moveWindowBy(self: *Mock, id: WindowId, dx: f64, dy: f64) void {
        const w = self.window(id);
        w.frame.x += dx;
        w.frame.y += dy;
    }

    pub fn failSetFrame(self: *Mock, code: t.Result, count: u32) void {
        self.set_frame_fail = code;
        self.set_frame_fail_count = count;
    }

    // ---- clock / run loop -----------------------------------------------------

    pub fn advance(self: *Mock, ns: u64) void {
        self.now += ns;
    }

    pub fn pendingDeferred(self: *const Mock) usize {
        return self.deferred.items.len;
    }

    /// Runs every queued call that is due (FIFO, including ones queued while running).
    pub fn runDeferred(self: *Mock) usize {
        var ran: usize = 0;
        while (true) {
            var idx: ?usize = null;
            for (self.deferred.items, 0..) |d, i| {
                if (d.due <= self.now) {
                    idx = i;
                    break;
                }
            }
            const i = idx orelse break;
            const d = self.deferred.orderedRemove(i);
            d.f(d.arg);
            ran += 1;
        }
        return ran;
    }

    /// Runs only the due queued calls of `f` (e.g. the engine's drag confirmation), leaving
    /// everything else (a pending drop apply) queued.
    pub fn runDeferredOf(self: *Mock, f: wsm.DeferredFn) usize {
        var ran: usize = 0;
        var i: usize = 0;
        while (i < self.deferred.items.len) {
            const d = self.deferred.items[i];
            if (d.f == f and d.due <= self.now) {
                _ = self.deferred.orderedRemove(i);
                d.f(d.arg);
                ran += 1;
                i = 0;
                continue;
            }
            i += 1;
        }
        return ran;
    }

    // ---- handles ----------------------------------------------------------------

    /// A handle the "system" lends to a callback (e.g. an AXObserver notification).
    /// Give it back with `unborrow` after the callback returns.
    pub fn borrow(self: *Mock, id: WindowId) ?Window {
        return self.newHandle(id);
    }

    pub fn unborrow(self: *Mock, w: Window) void {
        release(self, w);
    }

    /// Handles with outstanding retains.
    pub fn live(self: *const Mock) usize {
        var n: usize = 0;
        for (self.handles.items) |h| {
            if (h.refs > 0) n += 1;
        }
        return n;
    }

    pub fn idOf(w: Window) WindowId {
        return handleOf(w).id;
    }

    pub fn setFrameCount(self: *const Mock) usize {
        return self.set_frame_calls.items.len;
    }

    pub fn lastSetFrame(self: *const Mock) ?SetFrameCall {
        const items = self.set_frame_calls.items;
        if (items.len == 0) return null;
        return items[items.len - 1];
    }

    /// null (and `oom` set) if the allocator fails.
    fn newHandle(self: *Mock, id: WindowId) ?Window {
        const h = self.gpa.create(Handle) catch return self.outOfMemory();
        self.handles.append(self.gpa, h) catch {
            self.gpa.destroy(h);
            return self.outOfMemory();
        };
        h.* = .{ .id = id, .refs = 1 };
        return @ptrCast(h);
    }

    fn outOfMemory(self: *Mock) ?Window {
        self.oom = true;
        return null;
    }

    fn handleOf(w: Window) *Handle {
        return @ptrCast(@alignCast(w));
    }

    fn indexOf(self: *const Mock, id: WindowId) ?usize {
        for (self.windows.items, 0..) |w, i| {
            if (w.id == id) return i;
        }
        return null;
    }

    fn liveWindow(self: *Mock, w: Window) ?*MockWindow {
        const i = self.indexOf(handleOf(w).id) orelse return null;
        const mw = &self.windows.items[i];
        return if (mw.alive) mw else null;
    }

    // ---- vtable -------------------------------------------------------------------

    const vtable = wsm.WindowSystem.VTable{
        .focusedWindow = focusedWindow,
        .windowAt = windowAt,
        .frame = frame,
        .setFrame = setFrame,
        .setPosition = setPosition,
        .info = info,
        .windowPid = windowPid,
        .same = same,
        .retain = retain,
        .release = release,
        .displays = displays,
        .nowNs = nowNs,
        .deferCall = deferCall,
    };

    fn cast(ctx: *anyopaque) *Mock {
        return @ptrCast(@alignCast(ctx));
    }

    fn focusedWindow(ctx: *anyopaque, pid: i32, why: *t.Result) ?Window {
        const self = cast(ctx);
        self.focused_calls += 1;
        why.* = .no_window;
        if (self.focus_error) |e| {
            why.* = e;
            return null;
        }
        for (self.focus.items) |f| {
            if (f.pid != pid) continue;
            const i = self.indexOf(f.id) orelse break;
            if (self.windows.items[i].alive) return self.newHandle(f.id);
        }
        for (self.windows.items) |w| {
            if (w.pid == pid and w.alive) return self.newHandle(w.id);
        }
        return null;
    }

    fn windowAt(ctx: *anyopaque, p: t.Point) ?Window {
        const self = cast(ctx);
        self.window_at_calls += 1;
        for (self.windows.items) |w| {
            if (!w.alive) continue;
            const r = w.frame;
            if (p.x >= r.minX() and p.x < r.maxX() and p.y >= r.minY() and p.y < r.maxY())
                return self.newHandle(w.id);
        }
        return null;
    }

    fn frame(ctx: *anyopaque, w: Window) ?t.Rect {
        const self = cast(ctx);
        self.frame_calls += 1;
        if (self.frame_fails) return null;
        const mw = self.liveWindow(w) orelse return null;
        if (self.stale_left > 0) {
            if (self.stale_frame) |f| {
                self.stale_left -= 1;
                return f;
            }
        }
        return mw.frame;
    }

    fn setFrame(ctx: *anyopaque, w: Window, r: t.Rect) wsm.SetResult {
        const self = cast(ctx);
        const id = handleOf(w).id;
        self.set_frame_calls.append(self.gpa, .{ .id = id, .rect = r }) catch {
            self.oom = true;
        };
        self.now += self.set_frame_cost_ns;
        if (self.set_frame_fail_count > 0) {
            self.set_frame_fail_count -= 1;
            return .{ .rc = self.set_frame_fail };
        }
        const mw = self.liveWindow(w) orelse return .{ .rc = .ax };
        if (!mw.movable) return .{ .rc = .not_movable };
        if (self.stale_reads > 0) {
            self.stale_frame = mw.frame;
            self.stale_left = self.stale_reads;
        }
        if (!mw.resizable) {
            mw.frame.x = r.x;
            mw.frame.y = r.y;
            return .{ .rc = .ok, .size_refused = true };
        }
        mw.frame = .{ .x = r.x, .y = r.y, .w = @max(r.w - self.size_slop, mw.min_w, 1), .h = @max(r.h - self.size_slop, mw.min_h, 1) };
        return .{ .rc = .ok };
    }

    fn setPosition(ctx: *anyopaque, w: Window, p: t.Point) t.Result {
        const self = cast(ctx);
        self.set_position_calls += 1;
        self.now += self.set_frame_cost_ns;
        const mw = self.liveWindow(w) orelse return .ax;
        if (!mw.movable) return .not_movable;
        mw.frame.x = p.x;
        mw.frame.y = p.y;
        return .ok;
    }

    fn info(ctx: *anyopaque, w: Window) ?wsm.WindowInfo {
        const self = cast(ctx);
        self.info_calls += 1;
        const mw = self.liveWindow(w) orelse return null;
        return .{ .pid = mw.pid, .standard = mw.standard, .movable = mw.movable, .resizable = mw.resizable };
    }

    fn windowPid(ctx: *anyopaque, w: Window) i32 {
        const self = cast(ctx);
        const i = self.indexOf(handleOf(w).id) orelse return 0;
        return self.windows.items[i].pid;
    }

    fn same(ctx: *anyopaque, a: Window, b: Window) bool {
        _ = ctx;
        return handleOf(a).id == handleOf(b).id;
    }

    fn retain(ctx: *anyopaque, w: Window) void {
        const self = cast(ctx);
        const h = handleOf(w);
        self.retains += 1;
        if (h.refs <= 0) {
            self.bad_releases += 1; // resurrecting a dead handle is just as wrong
            return;
        }
        h.refs += 1;
    }

    fn release(ctx: *anyopaque, w: Window) void {
        const self = cast(ctx);
        const h = handleOf(w);
        self.releases += 1;
        if (h.refs <= 0) {
            self.bad_releases += 1;
            return;
        }
        h.refs -= 1;
    }

    fn displays(ctx: *anyopaque, out: []t.Display) usize {
        const self = cast(ctx);
        self.displays_calls += 1;
        const n = @min(out.len, self.display_list.items.len);
        @memcpy(out[0..n], self.display_list.items[0..n]);
        return n;
    }

    fn nowNs(ctx: *anyopaque) u64 {
        return cast(ctx).now;
    }

    fn deferCall(ctx: *anyopaque, delay_ns: u64, f: wsm.DeferredFn, arg: *anyopaque) void {
        const self = cast(ctx);
        self.deferred.append(self.gpa, .{ .due = self.now + delay_ns, .f = f, .arg = arg }) catch {
            self.oom = true;
        };
    }
};

/// Sink that records every event.
pub const Recorder = struct {
    gpa: Allocator,
    events: std.ArrayList(t.Event) = .empty,
    /// An event could not be stored (allocator failure).
    oom: bool = false,

    pub fn init(gpa: Allocator) Recorder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Recorder) void {
        self.events.deinit(self.gpa);
    }

    pub fn sink(self: *Recorder) wsm.Sink {
        return .{ .ctx = self, .emitFn = emit };
    }

    fn emit(ctx: ?*anyopaque, ev: *const t.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.events.append(self.gpa, ev.*) catch {
            self.oom = true;
        };
    }

    pub fn clear(self: *Recorder) void {
        self.events.clearRetainingCapacity();
    }

    pub fn count(self: *const Recorder, kind: t.EventKind) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (e.kind == @backingInt(kind)) n += 1;
        }
        return n;
    }

    pub fn last(self: *const Recorder) ?t.Event {
        const items = self.events.items;
        if (items.len == 0) return null;
        return items[items.len - 1];
    }

    pub fn lastOf(self: *const Recorder, kind: t.EventKind) ?t.Event {
        var i = self.events.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.events.items[i];
            if (e.kind == @backingInt(kind)) return e;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "mock: handles, z-order hit test, same()" {
    var m = Mock.init(testing.allocator);
    defer m.deinit();
    const ws = m.windowSystem();
    const a = try m.addWindow(.{ .pid = 1, .frame = .{ .x = 0, .y = 0, .w = 100, .h = 100 } });
    const b = try m.addWindow(.{ .pid = 2, .frame = .{ .x = 50, .y = 50, .w = 100, .h = 100 } });
    const top = ws.windowAt(.{ .x = 60, .y = 60 }).?;
    try testing.expectEqual(b, Mock.idOf(top));
    m.raise(a);
    const top2 = ws.windowAt(.{ .x = 60, .y = 60 }).?;
    try testing.expectEqual(a, Mock.idOf(top2));
    var why: t.Result = .ok;
    const fa = ws.focusedWindow(1, &why).?;
    try testing.expect(fa != top2);
    try testing.expect(ws.same(fa, top2));
    try testing.expect(!ws.same(fa, top));
    try testing.expectEqual(@as(usize, 3), m.live());
    ws.retain(fa);
    ws.release(fa);
    ws.release(fa);
    ws.release(top);
    ws.release(top2);
    try testing.expectEqual(@as(usize, 0), m.live());
    ws.release(top);
    try testing.expectEqual(@as(u64, 1), m.bad_releases);
    try testing.expect(ws.windowAt(.{ .x = 500, .y = 500 }) == null);
}

test "mock: clock, deferred queue, setFrame log and failures" {
    var m = Mock.init(testing.allocator);
    defer m.deinit();
    const ws = m.windowSystem();
    const id = try m.addWindow(.{ .pid = 1, .frame = .{ .x = 0, .y = 0, .w = 100, .h = 100 } });
    const w = m.borrow(id).?;
    defer m.unborrow(w);
    try testing.expectEqual(t.Result.ok, ws.setFrame(w, .{ .x = 1, .y = 2, .w = 3, .h = 4 }).rc);
    try testing.expectEqual(t.Rect{ .x = 1, .y = 2, .w = 3, .h = 4 }, ws.frame(w).?);
    m.failSetFrame(.ax, 1);
    try testing.expectEqual(t.Result.ax, ws.setFrame(w, .{ .x = 9, .y = 9, .w = 9, .h = 9 }).rc);
    try testing.expectEqual(@as(f64, 1), m.frameOf(id).x);
    try testing.expectEqual(@as(usize, 2), m.setFrameCount());

    const Counter = struct {
        n: u32 = 0,
        fn bump(arg: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(arg));
            c.n += 1;
        }
    };
    var c = Counter{};
    ws.deferCall(0, Counter.bump, &c);
    ws.deferCall(10, Counter.bump, &c);
    try testing.expectEqual(@as(usize, 1), m.runDeferred());
    try testing.expectEqual(@as(u32, 1), c.n);
    m.advance(10);
    try testing.expectEqual(@as(usize, 1), m.runDeferred());
    try testing.expectEqual(@as(u32, 2), c.n);
    try testing.expectEqual(@as(usize, 0), m.pendingDeferred());
}
