//! Engine behaviour tests against mock.zig. Owned by the engine work package.
//!
//! Every test ends with `fx.finish()`, which deinits the engine and asserts that every
//! handle the engine retained was released exactly once (mock live() == 0, no over-release).

const std = @import("std");
const testing = std.testing;
const t = @import("types.zig");
const layout = @import("layout.zig");
const geo = @import("geometry.zig");
const engine_mod = @import("engine.zig");
const mock_mod = @import("mock.zig");

const Engine = engine_mod.Engine;
const Mock = mock_mod.Mock;
const Recorder = mock_mod.Recorder;
const WindowId = mock_mod.WindowId;
const Rect = t.Rect;
const Point = t.Point;
const Kind = t.EventKind;
const Mods = t.Mods;

const ms: u64 = 1_000_000;

fn disp(id: u32, x: f64, y: f64, w: f64, h: f64) t.Display {
    return .{ .id = id, .bounds = .{ .x = x, .y = y, .w = w, .h = h }, .usable = .{ .x = x, .y = y + 25, .w = w, .h = h - 25 } };
}

/// usable (0, 25, 1440, 875)
const main_d = disp(1, 0, 0, 1440, 900);
/// usable (1440, 25, 1920, 1055), right of main
const side_d = disp(2, 1440, 0, 1920, 1080);
const one_display = [_]t.Display{main_d};
const two_displays = [_]t.Display{ main_d, side_d };

const free_frame = Rect{ .x = 100, .y = 100, .w = 400, .h = 300 };
const app_pid: i32 = 42;
const app_bundle = "com.test.app";
/// A point on the title bar of `free_frame`.
const grab = Point{ .x = 300, .y = 110 };
const left_edge = Point{ .x = 2, .y = 450 };
const center_pt = Point{ .x = 700, .y = 450 };

const Fx = struct {
    mock: Mock,
    rec: Recorder,
    eng: Engine,
    eng_live: bool = false,
    cursor: Point = .{},

    fn setup(fx: *Fx, ds: []const t.Display) !void {
        fx.* = .{ .mock = Mock.init(testing.allocator), .rec = Recorder.init(testing.allocator), .eng = undefined };
        try fx.mock.setDisplays(ds);
        fx.eng = Engine.init(fx.mock.windowSystem(), fx.rec.sink(), .{});
        fx.eng_live = true;
    }

    fn deinit(fx: *Fx) void {
        if (fx.eng_live) fx.eng.deinit();
        fx.rec.deinit();
        fx.mock.deinit();
    }

    /// Tears the engine down and checks the retain/release balance.
    fn finish(fx: *Fx) !void {
        fx.eng.deinit();
        fx.eng_live = false;
        try testing.expectEqual(@as(usize, 0), fx.mock.live());
        try testing.expectEqual(@as(u64, 0), fx.mock.bad_releases);
        try testing.expect(!fx.mock.oom and !fx.rec.oom);
    }

    fn addApp(fx: *Fx, pid: i32, bundle: ?[]const u8, frame: Rect) !WindowId {
        const id = try fx.mock.addWindow(.{ .pid = pid, .frame = frame });
        try fx.mock.setFocused(pid, id);
        fx.eng.appActivated(pid, bundle);
        return id;
    }

    fn perform(fx: *Fx, a: t.Action) t.Result {
        return fx.eng.perform(a, 0, .keyboard, fx.mock.now);
    }

    fn performPid(fx: *Fx, a: t.Action, pid: i32) t.Result {
        return fx.eng.perform(a, pid, .menu, fx.mock.now);
    }

    fn setConfig(fx: *Fx, c: t.Config) void {
        fx.eng.setConfig(c.sanitized().?);
    }

    fn expected(fx: *Fx, a: t.Action, window: Rect, usable: Rect, cycle: u32) Rect {
        return layout.frameFor(a, window, usable, cycle, layout.optionsFromConfig(fx.eng.config)).?;
    }

    fn stats(fx: *Fx) t.Stats {
        var s = t.Stats{};
        fx.eng.fillStats(&s);
        return s;
    }

    // ---- drag simulation ----

    fn press(fx: *Fx, p: Point) void {
        fx.cursor = p;
        fx.eng.mouseDown(p, fx.mock.now);
    }

    /// Cursor moves to `p`; `follow` (if set) is moved along by the window server.
    fn dragTo(fx: *Fx, follow: ?WindowId, p: Point) void {
        if (follow) |id| fx.mock.moveWindowBy(id, p.x - fx.cursor.x, p.y - fx.cursor.y);
        fx.cursor = p;
        fx.eng.mouseDragged(p, fx.mock.now);
    }

    fn observerMoved(fx: *Fx, id: WindowId) void {
        const w = fx.mock.borrow(id) orelse return; // oom is checked in finish()
        fx.eng.windowMoved(w);
        fx.mock.unborrow(w);
    }

    fn up(fx: *Fx) void {
        fx.eng.mouseUp(fx.cursor, fx.mock.now);
    }

    /// AXObserver attached to the window's app (frontmost): press on `at`, move 5 pt (past
    /// the drag threshold; the hit-test fallback is skipped), AXObserver reports the move, the
    /// size-stability check 30 ms later begins the drag.
    fn observerDrag(fx: *Fx, id: WindowId, at: Point) void {
        // Clicking a window activates its app; the observer follows the frontmost app.
        fx.eng.frontmost = fx.mock.window(id).pid;
        fx.eng.observed_pid = fx.eng.frontmost;
        fx.press(at);
        fx.dragTo(id, .{ .x = at.x + 5, .y = at.y });
        fx.observerMoved(id);
        fx.confirmDrag();
    }

    /// Lets the deferred drag confirmation run (30 ms later), nothing else.
    fn confirmDrag(fx: *Fx) void {
        fx.mock.advance(30 * ms);
        _ = fx.mock.runDeferredOf(Engine.confirm_callback);
    }
};

fn expectEvent(ev: t.Event, kind: Kind, action: t.Action) !void {
    try testing.expectEqual(@backingInt(kind), ev.kind);
    try testing.expectEqual(@backingInt(action), ev.action);
}

// ---------------------------------------------------------------------------
// perform

fn checkAllFrameActions(fx: *Fx, id: WindowId) !u64 {
    var n: u64 = 0;
    var i: u32 = 1;
    while (i < t.Action.count) : (i += 1) {
        const a = t.Action.fromInt(i).?;
        if (!layout.isFrameAction(a)) continue;
        fx.mock.setWindowFrame(id, free_frame);
        fx.rec.clear();
        try testing.expectEqual(t.Result.ok, fx.perform(a));
        const want = fx.expected(a, free_frame, main_d.usable, 0);
        try testing.expectEqual(want, fx.mock.lastSetFrame().?.rect);
        try testing.expectEqual(want, fx.mock.frameOf(id));
        try testing.expectEqual(@as(usize, 1), fx.rec.events.items.len);
        const ev = fx.rec.last().?;
        try expectEvent(ev, .snapped, a);
        try testing.expectEqual(want, ev.rect);
        try testing.expectEqual(@as(u32, 0), ev.cycle);
        try testing.expectEqual(main_d.id, ev.display_id);
        try testing.expectEqual(@backingInt(t.Source.keyboard), ev.source);
        n += 1;
    }
    return n;
}

test "perform: every frame action applies layout.frameFor on the window's display" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    var n = try checkAllFrameActions(&fx, id);
    try testing.expectEqual(@as(u64, 17), n);

    // Config (gaps, almost-maximize fraction) reaches the layout.
    var c = t.Config{};
    c.gap_outer = 10;
    c.gap_inner = 8;
    c.almost_maximize = 0.8;
    fx.setConfig(c);
    n += try checkAllFrameActions(&fx, id);
    try testing.expectEqual(@as(f64, 10), fx.expected(.left_half, free_frame, main_d.usable, 0).x);

    const s = fx.stats();
    try testing.expectEqual(n, s.snaps);
    try testing.expectEqual(@as(u64, 0), s.failures);
    try fx.finish();
}

test "perform: half cycling 1/2 → 2/3 → 1/3 → 1/2 with tolerance" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    const widths = [_]f64{ 720, 960, 480, 720 };
    const cycles = [_]u32{ 0, 1, 2, 0 };
    for (widths, cycles) |w, c| {
        try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
        try testing.expectEqual(w, fx.mock.frameOf(id).w);
        try testing.expectEqual(@as(f64, 0), fx.mock.frameOf(id).x);
        try testing.expectEqual(c, fx.rec.last().?.cycle);
    }
    // Memory is keyed by same(), not by handle identity: one entry for the window.
    try testing.expectEqual(@as(usize, 1), fx.mock.live());

    // The app trims sizes by 5 pt (terminal grid): still "at last target" (tol 28.8 pt).
    fx.mock.size_slop = 5;
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    try testing.expectEqual(@as(u32, 1), fx.rec.last().?.cycle);
    // Size increments are not a failure: no flag (no MIN SIZE label), rect = actual frame.
    try testing.expectEqual(@as(u32, 0), fx.rec.last().?.flags);
    try testing.expectEqual(fx.mock.frameOf(id), fx.rec.last().?.rect);
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    try testing.expectEqual(@as(u32, 2), fx.rec.last().?.cycle);
    fx.mock.size_slop = 0;

    // The user moved the window away: cycle starts over.
    fx.mock.moveWindowBy(id, 100, 0);
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    try testing.expectEqual(@as(u32, 0), fx.rec.last().?.cycle);

    // A different action starts at 0 too.
    try testing.expectEqual(t.Result.ok, fx.perform(.right_half));
    try testing.expectEqual(@as(u32, 0), fx.rec.last().?.cycle);
    try testing.expectEqual(Rect{ .x = 720, .y = 25, .w = 720, .h = 875 }, fx.mock.frameOf(id));

    // cycle_sizes off: always 1/2.
    var c = t.Config{};
    c.cycle_sizes = false;
    fx.setConfig(c);
    for (0..3) |_| {
        try testing.expectEqual(t.Result.ok, fx.perform(.right_half));
        try testing.expectEqual(@as(u32, 0), fx.rec.last().?.cycle);
        try testing.expectEqual(@as(f64, 720), fx.mock.frameOf(id).w);
    }
    try fx.finish();
}

test "perform: restore keeps the original pre-snap frame across a chain" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    // No memory yet.
    try testing.expectEqual(t.Result.invalid, fx.perform(.restore));
    try expectEvent(fx.rec.last().?, .failed, .restore);
    try testing.expectEqual(@as(i32, @backingInt(t.Result.invalid)), fx.rec.last().?.code);

    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    try testing.expectEqual(t.Result.ok, fx.perform(.right_half));
    try testing.expectEqual(t.Result.ok, fx.perform(.maximize));
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(free_frame, fx.mock.frameOf(id));
    const ev = fx.rec.last().?;
    try expectEvent(ev, .snapped, .restore);
    try testing.expectEqual(free_frame, ev.rect);
    try testing.expectEqual(main_d.id, ev.display_id);

    // Entry cleared after restore.
    try testing.expectEqual(t.Result.invalid, fx.perform(.restore));
    try testing.expectEqual(@as(usize, 0), fx.mock.live());

    // The chain breaks when the user moves the window in between.
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    const moved = Rect{ .x = 300, .y = 200, .w = 500, .h = 400 };
    fx.mock.setWindowFrame(id, moved);
    try testing.expectEqual(t.Result.ok, fx.perform(.maximize));
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(moved, fx.mock.frameOf(id));
    try testing.expectEqual(@as(u64, 0), fx.stats().failures);
    try fx.finish();
}

test "perform: next/prev display re-applies the last action with the same cycle" {
    var fx: Fx = undefined;
    try fx.setup(&two_displays);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half)); // cycle 1: 2/3
    try testing.expectEqual(@as(f64, 960), fx.mock.frameOf(id).w);

    try testing.expectEqual(t.Result.ok, fx.perform(.next_display));
    const want = fx.expected(.left_half, free_frame, side_d.usable, 1);
    try testing.expectEqual(want, fx.mock.frameOf(id));
    try testing.expectEqual(Rect{ .x = 1440, .y = 25, .w = 1280, .h = 1055 }, want);
    var ev = fx.rec.last().?;
    try expectEvent(ev, .snapped, .next_display);
    try testing.expectEqual(@as(u32, 1), ev.cycle);
    try testing.expectEqual(side_d.id, ev.display_id);

    // Memory still says left_half/cycle 1, so the next press continues the cycle there.
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    try testing.expectEqual(@as(u32, 2), fx.rec.last().?.cycle);
    try testing.expectEqual(@as(f64, 640), fx.mock.frameOf(id).w);
    try testing.expectEqual(side_d.id, fx.rec.last().?.display_id);

    // prev_display (wraps with two displays) brings it back with cycle 2.
    try testing.expectEqual(t.Result.ok, fx.perform(.prev_display));
    try testing.expectEqual(fx.expected(.left_half, free_frame, main_d.usable, 2), fx.mock.frameOf(id));
    ev = fx.rec.last().?;
    try expectEvent(ev, .snapped, .prev_display);
    try testing.expectEqual(main_d.id, ev.display_id);

    // Restore still goes back to the frame before the very first snap.
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(free_frame, fx.mock.frameOf(id));
    try fx.finish();
}

test "perform: display move of a free window uses mapBetween and is restorable" {
    var fx: Fx = undefined;
    try fx.setup(&two_displays);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    try testing.expectEqual(t.Result.ok, fx.perform(.next_display));
    const want = geo.mapBetween(free_frame, main_d.usable, side_d.usable);
    try testing.expectEqual(want, fx.mock.frameOf(id));
    try testing.expectEqual(side_d.id, fx.rec.last().?.display_id);
    try testing.expectEqual(@as(u32, 0), fx.rec.last().?.cycle);

    // next again wraps back to main (still mapBetween: the last action is not a frame action).
    try testing.expectEqual(t.Result.ok, fx.perform(.next_display));
    try testing.expectEqual(geo.mapBetween(want, side_d.usable, main_d.usable), fx.mock.frameOf(id));
    try testing.expectEqual(main_d.id, fx.rec.last().?.display_id);

    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(free_frame, fx.mock.frameOf(id));
    try fx.finish();
}

test "perform: display move on a single display fails with invalid" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    _ = try fx.addApp(app_pid, app_bundle, free_frame);

    for ([_]t.Action{ .next_display, .prev_display }) |a| {
        try testing.expectEqual(t.Result.invalid, fx.perform(a));
        const ev = fx.rec.last().?;
        try expectEvent(ev, .failed, a);
        try testing.expectEqual(@as(i32, @backingInt(t.Result.invalid)), ev.code);
    }
    try testing.expectEqual(@as(usize, 0), fx.mock.setFrameCount());
    try testing.expectEqual(@as(u64, 0), fx.stats().failures);
    try fx.finish();
}

test "perform: excluded apps are skipped before any window lookup" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    _ = try fx.addApp(app_pid, "com.Example.App", free_frame);
    try testing.expectEqual(t.Result.ok, fx.eng.setExcluded(&.{"com.example.app"}));

    try testing.expectEqual(t.Result.excluded, fx.perform(.maximize));
    const ev = fx.rec.last().?;
    try expectEvent(ev, .failed, .maximize);
    try testing.expectEqual(@as(i32, @backingInt(t.Result.excluded)), ev.code);
    try testing.expectEqual(@backingInt(t.Source.keyboard), ev.source);
    try testing.expectEqual(t.Result.excluded, fx.performPid(.maximize, app_pid));
    try testing.expectEqual(@as(u32, 0), fx.mock.focused_calls);
    try testing.expectEqual(@as(usize, 0), fx.mock.setFrameCount());

    // Another frontmost app is not affected.
    _ = try fx.addApp(43, "com.other", free_frame);
    try testing.expectEqual(t.Result.ok, fx.perform(.maximize));

    // A rejected list keeps the previous one.
    const many: [65][]const u8 = @splat("x.y");
    try testing.expectEqual(t.Result.invalid, fx.eng.setExcluded(&many));
    try testing.expectEqual(t.Result.excluded, fx.performPid(.maximize, app_pid));

    try testing.expectEqual(t.Result.ok, fx.eng.setExcluded(&.{}));
    try testing.expectEqual(t.Result.ok, fx.performPid(.maximize, app_pid));
    try fx.finish();
}

test "perform: no_window, ax and invalid action" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();

    // No frontmost app known.
    try testing.expectEqual(t.Result.no_window, fx.perform(.maximize));
    try testing.expectEqual(@as(i32, @backingInt(t.Result.no_window)), fx.rec.last().?.code);
    // App without windows.
    fx.eng.appActivated(7, "com.empty");
    try testing.expectEqual(@as(i32, 7), fx.eng.frontmostPid());
    try testing.expectEqual(t.Result.no_window, fx.perform(.maximize));
    try testing.expectEqual(t.Result.no_window, fx.performPid(.maximize, 999));

    _ = try fx.addApp(app_pid, app_bundle, free_frame);
    try testing.expectEqual(t.Result.invalid, fx.perform(.none));
    fx.mock.frame_fails = true;
    try testing.expectEqual(t.Result.ax, fx.perform(.maximize));
    try expectEvent(fx.rec.last().?, .failed, .maximize);
    try testing.expectEqual(@as(i32, @backingInt(t.Result.ax)), fx.rec.last().?.code);
    try testing.expectEqual(@as(usize, 0), fx.mock.live()); // focused window released
    try testing.expectEqual(@as(u64, 0), fx.stats().snaps);
    try fx.finish();
}

test "perform: setFrame failure counts, reports and records nothing" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    fx.mock.failSetFrame(.not_movable, 1);
    try testing.expectEqual(t.Result.not_movable, fx.perform(.left_half));
    const ev = fx.rec.last().?;
    try expectEvent(ev, .failed, .left_half);
    try testing.expectEqual(@as(i32, @backingInt(t.Result.not_movable)), ev.code);
    var s = fx.stats();
    try testing.expectEqual(@as(u64, 1), s.failures);
    try testing.expectEqual(@as(u64, 0), s.snaps);
    try testing.expectEqual(@as(usize, 0), fx.mock.live());
    try testing.expectEqual(t.Result.invalid, fx.perform(.restore));

    // The failed attempt left no memory: this is the first snap (cycle 0), restorable.
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    try testing.expectEqual(@as(u32, 0), fx.rec.last().?.cycle);
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(free_frame, fx.mock.frameOf(id));
    s = fx.stats();
    try testing.expectEqual(@as(u64, 1), s.failures);
    try testing.expectEqual(@as(u64, 2), s.snaps);
    try fx.finish();
}

// ---------------------------------------------------------------------------
// stats, displays, bundle cache

test "stats: latency ring with p50/p95/max, other fields untouched" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    _ = try fx.addApp(app_pid, app_bundle, free_frame);

    var empty = t.Stats{};
    fx.eng.fillStats(&empty);
    try testing.expectEqual(@as(u64, 0), empty.p50_latency_ns);

    // Simulated AX round trip: latency = nowNs() after setFrame - t0.
    fx.mock.set_frame_cost_ns = 2 * ms;
    try testing.expectEqual(t.Result.ok, fx.perform(.maximize));
    try testing.expectEqual(2 * ms, fx.rec.last().?.latency_ns);
    fx.mock.set_frame_cost_ns = 0;

    var i: u64 = 1;
    while (i <= 100) : (i += 1) {
        try testing.expectEqual(t.Result.ok, fx.eng.perform(.maximize, 0, .keyboard, fx.mock.now - i * 1000));
    }
    var s = t.Stats{ .hotkeys_bound = 7, .observed_pid = 99, .started = true };
    fx.eng.fillStats(&s);
    // 101 samples: 2 ms, 1..100 µs.
    try testing.expectEqual(@as(u64, 100_000), s.last_latency_ns);
    try testing.expectEqual(@as(u64, 51_000), s.p50_latency_ns);
    try testing.expectEqual(@as(u64, 96_000), s.p95_latency_ns);
    try testing.expectEqual(2 * ms, s.max_latency_ns);
    try testing.expectEqual(@as(u64, 101), s.snaps);
    try testing.expectEqual(@as(u32, 1), s.displays);
    try testing.expectEqual(@as(u32, 7), s.hotkeys_bound);
    try testing.expectEqual(@as(i32, 99), s.observed_pid);
    try testing.expect(s.started);
    try testing.expect(!s.event_tap_active);

    // Overflow the ring: only the newest 128 samples (73..200 µs) count.
    while (i <= 200) : (i += 1) {
        try testing.expectEqual(t.Result.ok, fx.eng.perform(.maximize, 0, .keyboard, fx.mock.now - i * 1000));
    }
    s = fx.stats();
    try testing.expectEqual(@as(u64, 136_000), s.p50_latency_ns);
    try testing.expectEqual(@as(u64, 194_000), s.p95_latency_ns);
    try testing.expectEqual(@as(u64, 200_000), s.max_latency_ns);
    try testing.expectEqual(@as(u64, 201), s.snaps);
    try fx.finish();
}

test "displays: cached until displaysChanged" {
    var fx: Fx = undefined;
    try fx.setup(&two_displays);
    defer fx.deinit();
    _ = try fx.addApp(app_pid, app_bundle, free_frame);

    try testing.expectEqual(@as(u32, 0), fx.stats().displays); // never fetched yet
    try testing.expectEqual(@as(usize, 2), fx.eng.displays().len);
    try testing.expectEqual(@as(usize, 2), fx.eng.displays().len);
    try testing.expectEqual(t.Result.ok, fx.perform(.maximize));
    try testing.expectEqual(@as(u32, 1), fx.mock.displays_calls);

    try fx.mock.setDisplays(&one_display);
    try testing.expectEqual(@as(usize, 2), fx.eng.displays().len); // still cached
    fx.eng.displaysChanged();
    try testing.expectEqual(@as(u32, 1), fx.mock.displays_calls); // lazily
    try testing.expectEqual(@as(usize, 1), fx.eng.displays().len);
    try testing.expectEqual(@as(u32, 2), fx.mock.displays_calls);
    try testing.expectEqual(@as(u32, 1), fx.stats().displays);
    try testing.expectEqual(t.Result.invalid, fx.perform(.next_display));
    try fx.finish();
}

test "displays: none at all → invalid" {
    var fx: Fx = undefined;
    try fx.setup(&.{});
    defer fx.deinit();
    _ = try fx.addApp(app_pid, app_bundle, free_frame);
    try testing.expectEqual(t.Result.invalid, fx.perform(.maximize));
    try fx.finish();
}

test "appActivated: pid→bundle cache evicts the least recently activated pid" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    try testing.expectEqual(t.Result.ok, fx.eng.setExcluded(&.{"app.0"}));
    _ = try fx.addApp(1000, "app.0", free_frame);
    try testing.expectEqual(t.Result.excluded, fx.performPid(.maximize, 1000));

    var buf: [32]u8 = undefined;
    var pid: i32 = 1001;
    while (pid <= 1031) : (pid += 1) {
        fx.eng.appActivated(pid, try std.fmt.bufPrint(&buf, "app.{d}", .{pid}));
    }
    // 32 distinct pids cached: 1000 still there.
    try testing.expectEqual(t.Result.excluded, fx.performPid(.maximize, 1000));
    fx.eng.appActivated(1032, "app.1032");
    try testing.expectEqual(@as(i32, 1032), fx.eng.frontmostPid());
    // Evicted → bundle unknown → not excluded.
    try testing.expectEqual(t.Result.ok, fx.performPid(.maximize, 1000));

    // Re-activation refreshes the entry.
    fx.eng.appActivated(1000, "APP.0");
    try testing.expectEqual(t.Result.excluded, fx.perform(.maximize));
    // Re-activation with no bundle id forgets it.
    fx.eng.appActivated(1000, null);
    try testing.expectEqual(t.Result.ok, fx.perform(.maximize));

    // Over-long ids are stored as unknown (no rule can match them).
    const long: [300]u8 = @splat('x');
    fx.eng.appActivated(2000, &long);
    try testing.expectEqual(t.Result.no_window, fx.perform(.maximize));

    fx.eng.appActivated(0, null);
    try testing.expectEqual(@as(i32, 0), fx.eng.frontmostPid());
    try fx.finish();
}

// ---------------------------------------------------------------------------
// drag pipeline

test "drag: observer path previews, defers the apply and records the pre-snap frame" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    fx.observerDrag(id, grab);
    try testing.expectEqual(@as(u32, 1), fx.mock.info_calls);
    try testing.expectEqual(@as(u32, 0), fx.mock.window_at_calls);
    try testing.expectEqual(@as(usize, 0), fx.rec.events.items.len);

    fx.dragTo(id, left_edge);
    try testing.expectEqual(@as(usize, 1), fx.rec.count(.preview_show));
    const pv = fx.rec.last().?;
    try expectEvent(pv, .preview_show, .left_half);
    try testing.expectEqual(@backingInt(t.Zone.left), pv.zone);
    try testing.expectEqual(Rect{ .x = 0, .y = 25, .w = 720, .h = 875 }, pv.rect);
    try testing.expectEqual(main_d.id, pv.display_id);
    try testing.expectEqual(@backingInt(t.Source.drag), pv.source);

    fx.dragTo(id, .{ .x = 3, .y = 500 });
    try testing.expectEqual(@as(usize, 1), fx.rec.count(.preview_show));

    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.rec.count(.preview_hide));
    try testing.expectEqual(@as(usize, 0), fx.rec.count(.snapped));
    try testing.expectEqual(@as(usize, 0), fx.mock.setFrameCount()); // not applied inline
    try testing.expectEqual(@as(usize, 1), fx.mock.pendingDeferred());

    fx.mock.advance(2 * ms);
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    try testing.expectEqual(pv.rect, fx.mock.lastSetFrame().?.rect);
    try testing.expectEqual(pv.rect, fx.mock.frameOf(id));
    const ev = fx.rec.last().?;
    try expectEvent(ev, .snapped, .left_half);
    try testing.expectEqual(@backingInt(t.Zone.left), ev.zone);
    try testing.expectEqual(@backingInt(t.Source.drag), ev.source);
    try testing.expectEqual(main_d.id, ev.display_id);
    try testing.expectEqual(2 * ms, ev.latency_ns);
    try testing.expectEqual(@as(u64, 1), fx.stats().snaps);
    try testing.expectEqual(@as(u32, 1), fx.mock.info_calls);
    try testing.expectEqual(@as(usize, 1), fx.mock.live()); // memory entry only

    // pre_snap = frame at mouseDown (cursor delta removed).
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(free_frame, fx.mock.frameOf(id));
    try fx.finish();
}

test "drag: fallback path when the observer stays silent" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    fx.press(grab);
    fx.dragTo(null, .{ .x = 303, .y = 110 }); // ≤ 4 pt: nothing yet
    try testing.expectEqual(@as(u32, 0), fx.mock.window_at_calls);
    fx.dragTo(null, .{ .x = 310, .y = 110 }); // > 4 pt: candidate, the app lags behind
    try testing.expectEqual(@as(u32, 1), fx.mock.window_at_calls);
    try testing.expectEqual(@as(u32, 1), fx.mock.frame_calls); // frame0

    fx.mock.advance(29 * ms);
    fx.dragTo(null, .{ .x = 312, .y = 110 });
    try testing.expectEqual(@as(u32, 1), fx.mock.frame_calls); // < 30 ms: no poll
    fx.mock.advance(1 * ms);
    fx.dragTo(null, .{ .x = 313, .y = 110 });
    try testing.expectEqual(@as(u32, 2), fx.mock.frame_calls); // not moved yet
    try testing.expectEqual(@as(u32, 0), fx.mock.info_calls);

    fx.mock.moveWindowBy(id, 13, 0); // app catches up
    fx.mock.advance(30 * ms);
    fx.dragTo(id, .{ .x = 314, .y = 110 });
    try testing.expectEqual(@as(u32, 1), fx.mock.info_calls); // drag began

    fx.dragTo(id, left_edge);
    try testing.expectEqual(@as(usize, 1), fx.rec.count(.preview_show));
    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    try expectEvent(fx.rec.last().?, .snapped, .left_half);
    try testing.expectEqual(@as(u32, 1), fx.mock.window_at_calls);

    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(free_frame, fx.mock.frameOf(id));
    try fx.finish();
}

test "drag: fallback gives up after 10 checks; the observer path stays open" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    fx.press(grab);
    fx.dragTo(null, .{ .x = 310, .y = 110 });
    for (0..15) |k| {
        fx.mock.advance(40 * ms);
        fx.dragTo(null, .{ .x = 311 + @as(f64, @floatFromInt(k)), .y = 110 });
    }
    try testing.expectEqual(@as(u32, 11), fx.mock.frame_calls); // frame0 + 10 checks
    try testing.expectEqual(@as(u32, 1), fx.mock.window_at_calls);
    try testing.expectEqual(@as(u32, 0), fx.mock.info_calls);
    try testing.expectEqual(@as(usize, 0), fx.mock.live()); // candidate released

    fx.observerMoved(id);
    fx.confirmDrag();
    try testing.expectEqual(@as(u32, 1), fx.mock.info_calls);
    fx.up();
    try testing.expectEqual(@as(usize, 0), fx.mock.pendingDeferred());
    try fx.finish();
}

test "drag: observer event replaces a fallback candidate" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    fx.press(grab);
    fx.dragTo(id, .{ .x = 310, .y = 110 });
    try testing.expectEqual(@as(u32, 1), fx.mock.window_at_calls);
    fx.observerMoved(id);
    fx.confirmDrag();
    try testing.expectEqual(@as(u32, 1), fx.mock.info_calls);
    try testing.expectEqual(@as(usize, 1), fx.mock.live()); // only the drag's own retain
    fx.dragTo(id, left_edge);
    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(free_frame, fx.mock.frameOf(id));
    try fx.finish();
}

test "drag: echoes of our own setFrame (< 150 ms) do not start a drag" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    var c = t.Config{};
    c.snap_back = false;
    fx.setConfig(c);
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    fx.eng.observed_pid = app_pid;
    fx.press(.{ .x = 300, .y = 35 });
    fx.dragTo(id, .{ .x = 306, .y = 35 });
    fx.mock.advance(100 * ms);
    fx.observerMoved(id);
    fx.mock.advance(49 * ms);
    fx.observerMoved(id);
    try testing.expectEqual(@as(u32, 0), fx.mock.info_calls);
    fx.mock.advance(1 * ms);
    fx.observerMoved(id);
    fx.confirmDrag();
    try testing.expectEqual(@as(u32, 1), fx.mock.info_calls);
    fx.up();
    try fx.finish();
}

test "drag: fallback movement inside the echo window re-bases frame0" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    var c = t.Config{};
    c.snap_back = false;
    fx.setConfig(c);
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    _ = try fx.addApp(77, "com.other", .{ .x = 900, .y = 500, .w = 300, .h = 200 });

    fx.press(grab);
    fx.dragTo(null, .{ .x = 310, .y = 110 }); // candidate on `id`
    try testing.expectEqual(t.Result.ok, fx.performPid(.maximize, 77)); // our setFrame at T
    fx.mock.moveWindowBy(id, 10, 0);
    fx.mock.advance(30 * ms);
    fx.dragTo(null, .{ .x = 311, .y = 110 });
    try testing.expectEqual(@as(u32, 0), fx.mock.info_calls); // suppressed
    fx.mock.advance(130 * ms);
    fx.dragTo(null, .{ .x = 312, .y = 110 });
    try testing.expectEqual(@as(u32, 0), fx.mock.info_calls); // no movement since re-base
    fx.mock.moveWindowBy(id, 2, 0);
    fx.mock.advance(30 * ms);
    fx.dragTo(null, .{ .x = 313, .y = 110 });
    try testing.expectEqual(@as(u32, 1), fx.mock.info_calls);
    fx.up();
    try fx.finish();
}

test "drag: snap-back restores the pre-snap size keeping the relative cursor x" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    try testing.expectEqual(t.Result.ok, fx.perform(.left_half)); // (0,25,720,875)
    fx.mock.advance(200 * ms);
    fx.rec.clear();
    fx.observerDrag(id, .{ .x = 180, .y = 35 }); // rel x 0.25
    const before = Rect{ .x = 5, .y = 25, .w = 720, .h = 875 };
    try testing.expectEqual(@as(usize, 2), fx.mock.setFrameCount());
    const r = fx.mock.lastSetFrame().?.rect;
    try testing.expectEqual(free_frame.w, r.w);
    try testing.expectEqual(free_frame.h, r.h);
    try testing.expectEqual(before.y, r.y);
    const rel_before = (fx.cursor.x - before.x) / before.w;
    const rel_after = (fx.cursor.x - r.x) / r.w;
    try testing.expectApproxEqAbs(rel_before, rel_after, 1.0 / r.w);
    try testing.expectEqual(Rect{ .x = 85, .y = 25, .w = 400, .h = 300 }, r);
    try testing.expectEqual(@as(usize, 0), fx.rec.events.items.len); // no event for the resize
    try testing.expectEqual(@as(u64, 1), fx.stats().snaps);

    // Dropped without a zone: pre_snap was cleared.
    fx.mock.advance(200 * ms);
    fx.dragTo(id, center_pt);
    fx.up();
    try testing.expectEqual(@as(usize, 0), fx.mock.pendingDeferred());
    try testing.expectEqual(t.Result.invalid, fx.perform(.restore));
    try fx.finish();
}

test "drag: snap-back then drop into a zone keeps the original pre-snap frame" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    fx.mock.advance(200 * ms);
    fx.observerDrag(id, .{ .x = 360, .y = 35 });
    try testing.expectEqual(@as(usize, 2), fx.mock.setFrameCount());
    fx.dragTo(id, .{ .x = 1438, .y = 450 });
    try expectEvent(fx.rec.last().?, .preview_show, .right_half);
    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    try testing.expectEqual(Rect{ .x = 720, .y = 25, .w = 720, .h = 875 }, fx.mock.frameOf(id));
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(free_frame, fx.mock.frameOf(id));
    try fx.finish();
}

test "drag: no snap-back when disabled or when the snapped size was changed" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    // User resized the snapped window.
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    fx.mock.setWindowFrame(id, .{ .x = 0, .y = 25, .w = 600, .h = 875 });
    fx.mock.advance(200 * ms);
    fx.observerDrag(id, .{ .x = 300, .y = 35 });
    try testing.expectEqual(@as(usize, 1), fx.mock.setFrameCount());
    fx.up();

    // snap_back off.
    var c = t.Config{};
    c.snap_back = false;
    fx.setConfig(c);
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    fx.mock.advance(200 * ms);
    fx.observerDrag(id, .{ .x = 300, .y = 35 });
    try testing.expectEqual(@as(usize, 2), fx.mock.setFrameCount());
    fx.up();
    try testing.expectEqual(t.Result.ok, fx.perform(.restore)); // memory intact
    try fx.finish();
}

test "drag: preview events only on zone/action/display changes" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    fx.observerDrag(id, grab);
    fx.dragTo(id, left_edge);
    fx.dragTo(id, .{ .x = 2, .y = 460 });
    try testing.expectEqual(@as(usize, 1), fx.rec.count(.preview_show));
    fx.dragTo(id, .{ .x = 720, .y = 2 });
    try expectEvent(fx.rec.last().?, .preview_show, .maximize);
    try testing.expectEqual(@backingInt(t.Zone.top), fx.rec.last().?.zone);
    fx.dragTo(id, .{ .x = 730, .y = 1 });
    try testing.expectEqual(@as(usize, 2), fx.rec.count(.preview_show));
    fx.dragTo(id, left_edge);
    try testing.expectEqual(@as(usize, 3), fx.rec.count(.preview_show));
    try testing.expectEqual(@as(usize, 0), fx.rec.count(.preview_hide));
    fx.dragTo(id, center_pt);
    fx.dragTo(id, .{ .x = 710, .y = 450 });
    try testing.expectEqual(@as(usize, 1), fx.rec.count(.preview_hide));
    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.rec.count(.preview_hide));
    try testing.expectEqual(@as(usize, 0), fx.mock.pendingDeferred());
    try testing.expectEqual(@as(usize, 0), fx.mock.setFrameCount());
    try testing.expectEqual(@as(usize, 0), fx.rec.count(.snapped));
    try fx.finish();
}

test "drag: thirds modifier selects the alternate map only when fully held" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    fx.observerDrag(id, grab);
    fx.dragTo(id, left_edge);
    try expectEvent(fx.rec.last().?, .preview_show, .left_half);
    fx.eng.flagsChanged(Mods.shift); // default thirds modifier is ⇧ (⌥ collides with macOS 15+ tiling)
    try expectEvent(fx.rec.last().?, .preview_show, .first_third);
    try testing.expectEqual(Rect{ .x = 0, .y = 25, .w = 480, .h = 875 }, fx.rec.last().?.rect);
    fx.eng.flagsChanged(Mods.shift | Mods.option); // superset still alternate
    try testing.expectEqual(@as(usize, 2), fx.rec.count(.preview_show));
    fx.eng.flagsChanged(0);
    try expectEvent(fx.rec.last().?, .preview_show, .left_half);

    var c = t.Config{};
    c.thirds_modifier = Mods.option | Mods.command;
    fx.setConfig(c);
    fx.eng.flagsChanged(Mods.option); // partial: primary
    try testing.expectEqual(@as(usize, 3), fx.rec.count(.preview_show));
    fx.eng.flagsChanged(Mods.option | Mods.command);
    try expectEvent(fx.rec.last().?, .preview_show, .first_third);
    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    try expectEvent(fx.rec.last().?, .snapped, .first_third);
    try testing.expectEqual(Rect{ .x = 0, .y = 25, .w = 480, .h = 875 }, fx.mock.frameOf(id));

    // Modifier already held when the drag starts; thirds_modifier == 0 never alternates.
    fx.mock.advance(200 * ms);
    fx.observerDrag(id, .{ .x = 200, .y = 35 });
    fx.dragTo(id, .{ .x = 1438, .y = 450 });
    try expectEvent(fx.rec.last().?, .preview_show, .last_third);
    c.thirds_modifier = 0;
    fx.setConfig(c);
    fx.eng.flagsChanged(Mods.all);
    try expectEvent(fx.rec.last().?, .preview_show, .right_half);
    fx.up();
    _ = fx.mock.runDeferred();
    try fx.finish();
}

test "drag: zone on another display; center keeps the drag-start size" {
    var fx: Fx = undefined;
    try fx.setup(&two_displays);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    fx.eng.setZoneAction(.top, false, .center);

    fx.observerDrag(id, grab);
    fx.dragTo(id, .{ .x = 2400, .y = 2 });
    const pv = fx.rec.last().?;
    try expectEvent(pv, .preview_show, .center);
    try testing.expectEqual(@backingInt(t.Zone.top), pv.zone);
    try testing.expectEqual(side_d.id, pv.display_id);
    const want = fx.expected(.center, free_frame, side_d.usable, 0);
    try testing.expectEqual(want, pv.rect);
    try testing.expectEqual(free_frame.w, want.w);

    // The shared edge between the displays is not a zone.
    fx.dragTo(id, .{ .x = 1439, .y = 450 });
    try testing.expectEqual(@as(usize, 1), fx.rec.count(.preview_hide));
    fx.dragTo(id, .{ .x = 2400, .y = 2 });
    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    const ev = fx.rec.last().?;
    try expectEvent(ev, .snapped, .center);
    try testing.expectEqual(side_d.id, ev.display_id);
    try testing.expectEqual(want, fx.mock.frameOf(id));

    // A zone mapped to none (or a non-frame action) is disabled.
    fx.eng.setZoneAction(.top, false, .none);
    fx.eng.setZoneAction(.left, false, .restore);
    fx.mock.advance(200 * ms);
    fx.rec.clear();
    fx.observerDrag(id, .{ .x = 2400, .y = 400 });
    fx.dragTo(id, .{ .x = 2400, .y = 2 });
    fx.dragTo(id, left_edge);
    try testing.expectEqual(@as(usize, 0), fx.rec.events.items.len);
    fx.up();
    try fx.finish();
}

test "drag: release outside any zone does not snap" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    fx.observerDrag(id, grab);
    fx.dragTo(id, center_pt);
    fx.up();
    try testing.expectEqual(@as(usize, 0), fx.rec.events.items.len);
    try testing.expectEqual(@as(usize, 0), fx.mock.pendingDeferred());
    try testing.expectEqual(@as(usize, 0), fx.mock.setFrameCount());
    try testing.expectEqual(@as(usize, 0), fx.mock.live());

    // Press without any movement, and stray events while idle.
    fx.press(grab);
    fx.up();
    fx.observerMoved(id);
    fx.dragTo(id, left_edge);
    try testing.expectEqual(@as(usize, 0), fx.rec.events.items.len);
    try testing.expectEqual(@as(u32, 1), fx.mock.info_calls);
    try fx.finish();
}

test "drag: non-standard, immovable and excluded windows are ignored" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const sheet = try fx.mock.addWindow(.{ .pid = 10, .frame = free_frame, .standard = false });
    const fixed = try fx.mock.addWindow(.{ .pid = 11, .frame = free_frame, .movable = false });
    const excl = try fx.addApp(12, "com.excluded", free_frame);
    try testing.expectEqual(t.Result.ok, fx.eng.setExcluded(&.{"com.excluded"}));

    var calls: u32 = 0;
    for ([_]WindowId{ sheet, fixed, excl }) |id| {
        fx.observerDrag(id, grab);
        calls += 1;
        try testing.expectEqual(calls, fx.mock.info_calls); // info once
        fx.dragTo(id, left_edge);
        fx.observerMoved(id); // further notifications are ignored too
        try testing.expectEqual(calls, fx.mock.info_calls);
        fx.up();
        try testing.expectEqual(@as(usize, 0), fx.mock.live());
    }
    try testing.expectEqual(@as(usize, 0), fx.rec.events.items.len);
    try testing.expectEqual(@as(usize, 0), fx.mock.pendingDeferred());
    try fx.finish();
}

test "drag: setFrame failure on drop reports failed(drag)" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    fx.observerDrag(id, grab);
    fx.dragTo(id, left_edge);
    fx.up();
    fx.mock.failSetFrame(.ax, 1);
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    const ev = fx.rec.last().?;
    try expectEvent(ev, .failed, .left_half);
    try testing.expectEqual(@as(i32, @backingInt(t.Result.ax)), ev.code);
    try testing.expectEqual(@backingInt(t.Source.drag), ev.source);
    try testing.expectEqual(@backingInt(t.Zone.left), ev.zone);
    const s = fx.stats();
    try testing.expectEqual(@as(u64, 1), s.failures);
    try testing.expectEqual(@as(u64, 0), s.snaps);
    try testing.expectEqual(@as(usize, 0), fx.mock.live());
    try testing.expectEqual(t.Result.invalid, fx.perform(.restore));
    try fx.finish();
}

test "drag: disabling drag_snap cancels; a press without mouseUp resets" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    // Missed mouseUp: the next press hides the preview and drops the drag.
    fx.observerDrag(id, grab);
    fx.dragTo(id, left_edge);
    fx.press(grab);
    try testing.expectEqual(@as(usize, 1), fx.rec.count(.preview_hide));
    try testing.expectEqual(@as(usize, 0), fx.mock.live());
    fx.up();
    try testing.expectEqual(@as(usize, 0), fx.mock.pendingDeferred());

    fx.mock.setWindowFrame(id, free_frame); // grab must hit the window again
    fx.observerDrag(id, grab);
    fx.dragTo(id, left_edge);
    var c = t.Config{};
    c.drag_snap = false;
    fx.setConfig(c);
    try testing.expectEqual(@as(usize, 2), fx.rec.count(.preview_hide));
    fx.up();
    try testing.expectEqual(@as(usize, 0), fx.mock.pendingDeferred());

    const info_before = fx.mock.info_calls;
    fx.observerDrag(id, grab);
    try testing.expectEqual(info_before, fx.mock.info_calls);
    fx.up();
    try fx.finish();
}

test "drag: a second drop before the deferred call runs applies only the newest" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);

    fx.observerDrag(id, grab);
    fx.dragTo(id, left_edge);
    fx.up();
    fx.mock.setWindowFrame(id, .{ .x = 800, .y = 440, .w = 400, .h = 300 });
    fx.observerDrag(id, .{ .x = 1000, .y = 450 });
    fx.dragTo(id, .{ .x = 1438, .y = 450 });
    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.mock.pendingDeferred());
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    try testing.expectEqual(@as(usize, 1), fx.mock.setFrameCount());
    try expectEvent(fx.rec.last().?, .snapped, .right_half);
    try fx.finish();
}

// ---------------------------------------------------------------------------
// memory / lifetime

test "memory: 32-entry LRU evicts (and releases) the least recently used window" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();

    var pid: i32 = 100;
    while (pid < 132) : (pid += 1) {
        _ = try fx.addApp(pid, null, free_frame);
        try testing.expectEqual(t.Result.ok, fx.performPid(.left_half, pid));
    }
    try testing.expectEqual(@as(usize, 32), fx.mock.live());
    // Touch the oldest entry so pid 101 becomes the LRU one.
    try testing.expectEqual(t.Result.ok, fx.performPid(.right_half, 100));
    _ = try fx.addApp(132, null, free_frame);
    try testing.expectEqual(t.Result.ok, fx.performPid(.left_half, 132));
    try testing.expectEqual(@as(usize, 32), fx.mock.live()); // evicted handle was released

    try testing.expectEqual(t.Result.invalid, fx.performPid(.restore, 101));
    try testing.expectEqual(t.Result.ok, fx.performPid(.restore, 100));
    try testing.expectEqual(t.Result.ok, fx.performPid(.restore, 132));
    try testing.expectEqual(@as(usize, 30), fx.mock.live());
    try fx.finish();
}

test "lifetime: deinit releases memory, drag and pending handles" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const a = try fx.addApp(app_pid, app_bundle, free_frame);
    const b = try fx.addApp(43, "com.other", .{ .x = 800, .y = 400, .w = 300, .h = 200 });

    try testing.expectEqual(t.Result.ok, fx.performPid(.left_half, app_pid)); // memory: a
    fx.mock.advance(200 * ms);
    fx.observerDrag(b, .{ .x = 900, .y = 410 });
    fx.dragTo(b, .{ .x = 1438, .y = 450 });
    fx.up(); // pending apply holds b
    fx.mock.advance(200 * ms);
    fx.observerDrag(a, .{ .x = 300, .y = 35 }); // dragging a (snap-back drops a's memory)
    try testing.expect(fx.mock.live() >= 2);
    try testing.expect(fx.mock.retains > 0);

    const set_frames = fx.mock.setFrameCount();
    try fx.finish();
    // A deferred call that still fires after deinit is a no-op.
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    try testing.expectEqual(set_frames, fx.mock.setFrameCount());
    try testing.expectEqual(@as(usize, 0), fx.mock.live());
}


test "min-size window is re-aligned to the tile's far edge and flagged" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    fx.mock.window(id).min_w = 900; // wider than a half (720 pt) of the 1440 pt test display
    try testing.expectEqual(t.Result.ok, fx.eng.perform(.right_half, app_pid, .keyboard, fx.mock.now));
    const f = fx.mock.frameOf(id);
    const usable = one_display[0].usable;
    try testing.expectEqual(@as(f64, 900), f.w);
    try testing.expectEqual(usable.maxX(), f.maxX()); // hugs the right edge, not overflowing it
    const ev = fx.rec.lastOf(.snapped).?;
    try testing.expect(ev.flags & t.event_flag_frame_differs != 0);
    try testing.expect(ev.flags & t.event_flag_size_refused == 0);
    try testing.expectEqual(f, ev.rect);
    // Re-aligned with one position write (SPEC), not a second full setFrame.
    try testing.expectEqual(@as(usize, 1), fx.mock.setFrameCount());
    try testing.expectEqual(@as(u32, 1), fx.mock.set_position_calls);
    try fx.finish();
}

test "alignToTarget per axis" {
    const usable = Rect{ .x = 0, .y = 0, .w = 1200, .h = 800 };
    const big = Rect{ .x = 0, .y = 0, .w = 700, .h = 800 };
    const left = engine_mod.alignToTarget(big, .{ .x = 0, .y = 0, .w = 600, .h = 800 }, usable);
    try testing.expectEqual(@as(f64, 0), left.x);
    const right = engine_mod.alignToTarget(big, .{ .x = 600, .y = 0, .w = 600, .h = 800 }, usable);
    try testing.expectEqual(@as(f64, 500), right.x);
    const mid = engine_mod.alignToTarget(.{ .x = 0, .y = 0, .w = 500, .h = 800 }, .{ .x = 400, .y = 0, .w = 400, .h = 800 }, usable);
    try testing.expectEqual(@as(f64, 350), mid.x);
}

fn observerResized(fx: *Fx, id: WindowId) void {
    const w = fx.mock.borrow(id) orelse return;
    fx.eng.windowResized(w);
    fx.mock.unborrow(w);
}

test "drag: a real resize of the dragged window cancels the drag" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    fx.observerDrag(id, grab);
    fx.dragTo(id, left_edge);
    try expectEvent(fx.rec.last().?, .preview_show, .left_half);
    fx.mock.advance(500 * std.time.ns_per_ms); // well past the echo window
    var f = fx.mock.frameOf(id);
    f.w += 40; // left-edge resize grew the window
    fx.mock.setWindowFrame(id, f);
    observerResized(&fx, id);
    try testing.expectEqual(@as(usize, 1), fx.rec.count(.preview_hide));
    fx.up();
    try testing.expectEqual(@as(usize, 0), fx.mock.runDeferred());
    try fx.finish();
}

test "drag: a late echo of the size we set does not cancel the drag" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    fx.observerDrag(id, grab);
    fx.dragTo(id, left_edge);
    fx.mock.advance(500 * std.time.ns_per_ms);
    observerResized(&fx, id); // same size as at drag start
    try testing.expectEqual(@as(usize, 0), fx.rec.count(.preview_hide));
    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    try expectEvent(fx.rec.lastOf(.snapped).?, .snapped, .left_half);
    try fx.finish();
}

// ---------------------------------------------------------------------------
// review round 2

test "applied frame: fixed-size window is moved, aligned, flagged size_refused" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    fx.mock.window(id).resizable = false;
    try testing.expectEqual(t.Result.ok, fx.perform(.right_half));
    const f = fx.mock.frameOf(id);
    try testing.expectEqual(free_frame.w, f.w); // keeps its size
    try testing.expectEqual(main_d.usable.maxX(), f.maxX()); // hugs the right half's far edge
    const ev = fx.rec.lastOf(.snapped).?;
    try testing.expect(ev.flags & t.event_flag_size_refused != 0);
    try testing.expect(ev.flags & t.event_flag_frame_differs == 0);
    try testing.expectEqual(f, ev.rect);
    try fx.finish();
}

test "applied frame: a stale read-back (async app) trusts the target; cycling and restore work" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    _ = try fx.addApp(app_pid, app_bundle, free_frame);
    fx.mock.stale_reads = 1; // the read right after every setFrame still sees the old frame
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    var ev = fx.rec.lastOf(.snapped).?;
    try testing.expectEqual(@as(u32, 0), ev.flags);
    try testing.expectEqual(Rect{ .x = 0, .y = 25, .w = 720, .h = 875 }, ev.rect);
    try testing.expectEqual(@as(u32, 0), fx.mock.set_position_calls); // nothing written back
    try testing.expectEqual(@as(usize, 1), fx.mock.setFrameCount());
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    ev = fx.rec.lastOf(.snapped).?;
    try testing.expectEqual(@as(u32, 1), ev.cycle); // 2/3: the chain advanced
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(free_frame, fx.mock.lastSetFrame().?.rect);
    try fx.finish();
}

test "perform: focus lookup failures keep their reason (permission, unresponsive app)" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    _ = try fx.addApp(app_pid, app_bundle, free_frame);
    fx.mock.focus_error = .not_trusted;
    try testing.expectEqual(t.Result.not_trusted, fx.perform(.left_half));
    try testing.expectEqual(@as(i32, @backingInt(t.Result.not_trusted)), fx.rec.last().?.code);
    fx.mock.focus_error = .ax;
    try testing.expectEqual(t.Result.ax, fx.perform(.left_half));
    fx.mock.focus_error = null;
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    try fx.finish();
}

test "displays: an empty list is not cached" {
    var fx: Fx = undefined;
    try fx.setup(&.{});
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    try testing.expectEqual(t.Result.invalid, fx.perform(.maximize));
    try fx.mock.setDisplays(&one_display); // displays came back without a reconfiguration callback
    try testing.expectEqual(t.Result.ok, fx.perform(.maximize));
    try testing.expectEqual(main_d.usable, fx.mock.frameOf(id));
    try fx.finish();
}

test "drag: a click, jitter or zoom (no cursor travel) never starts a drag or snap-back" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half)); // snapped: snap-back armed
    fx.mock.advance(500 * ms);
    fx.eng.observed_pid = app_pid;
    const frames = fx.mock.setFrameCount();

    fx.press(.{ .x = 300, .y = 35 });
    fx.dragTo(id, .{ .x = 301, .y = 35 }); // 1 pt jitter moves the window
    fx.observerMoved(id);
    fx.mock.window(id).frame = .{ .x = 0, .y = 25, .w = 1440, .h = 875 }; // title-bar double-click zoom
    fx.observerMoved(id);
    fx.up();
    try testing.expectEqual(frames, fx.mock.setFrameCount()); // no snap-back resize
    try testing.expectEqual(@as(u32, 0), fx.mock.info_calls);
    try testing.expectEqual(@as(usize, 0), fx.rec.count(.preview_show));
    try testing.expectEqual(t.Result.ok, fx.perform(.restore)); // memory survived
    try fx.finish();
}

test "drag: an observer hint becomes a drag once the cursor passes the threshold" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    fx.eng.observed_pid = app_pid;
    fx.press(grab);
    fx.dragTo(id, .{ .x = grab.x + 2, .y = grab.y });
    fx.observerMoved(id); // hint only
    try testing.expectEqual(@as(u32, 0), fx.mock.info_calls);
    fx.dragTo(id, .{ .x = grab.x + 8, .y = grab.y }); // no further notification needed
    try testing.expectEqual(@as(u32, 0), fx.mock.info_calls); // size check pending
    fx.confirmDrag();
    try testing.expectEqual(@as(u32, 1), fx.mock.info_calls);
    try testing.expectEqual(@as(u32, 0), fx.mock.window_at_calls);
    fx.dragTo(id, left_edge);
    try expectEvent(fx.rec.last().?, .preview_show, .left_half);
    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    try fx.finish();
}

test "drag: notifications for windows not under the cursor are not this gesture" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    // A sheet/panel of the same app elsewhere on screen.
    const other = try fx.mock.addWindow(.{ .pid = app_pid, .frame = .{ .x = 800, .y = 500, .w = 300, .h = 200 } });
    fx.mock.raise(id);
    fx.eng.observed_pid = app_pid;
    fx.press(grab);
    fx.dragTo(id, .{ .x = grab.x + 6, .y = grab.y });
    observerResized(&fx, other); // another window resizing does not cancel the press
    fx.observerMoved(other); // nor does its move start a drag
    try testing.expectEqual(@as(u32, 0), fx.mock.info_calls);
    fx.observerMoved(id);
    fx.confirmDrag();
    try testing.expectEqual(@as(u32, 1), fx.mock.info_calls);
    fx.dragTo(id, left_edge);
    try expectEvent(fx.rec.last().?, .preview_show, .left_half);
    fx.up();
    _ = fx.mock.runDeferred();
    try fx.finish();
}

test "drag: a left-edge resize of a snapped window never snaps back (size keeps changing)" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    try testing.expectEqual(t.Result.ok, fx.perform(.right_half));
    fx.mock.advance(500 * ms);
    fx.eng.observed_pid = app_pid;
    const frames = fx.mock.setFrameCount();
    const f = fx.mock.frameOf(id); // (720, 25, 720, 875)
    // The origin follows the cursor, the width shrinks — notification by notification.
    fx.press(.{ .x = f.x + 1, .y = 400 });
    fx.mock.setWindowFrame(id, .{ .x = f.x + 10, .y = f.y, .w = f.w - 10, .h = f.h });
    fx.dragTo(null, .{ .x = f.x + 11, .y = 400 });
    fx.observerMoved(id);
    fx.mock.setWindowFrame(id, .{ .x = f.x + 30, .y = f.y, .w = f.w - 30, .h = f.h });
    fx.confirmDrag(); // size changed since the Moved: a resize
    fx.dragTo(null, .{ .x = 2, .y = 400 }); // even at the screen edge: no zone
    try testing.expectEqual(frames, fx.mock.setFrameCount());
    try testing.expectEqual(@as(usize, 0), fx.rec.count(.preview_show));
    fx.up();
    try testing.expectEqual(@as(usize, 0), fx.mock.runDeferred());
    try fx.finish();
}

test "drag: a Resized notification during the size check makes it a resize" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    try testing.expectEqual(t.Result.ok, fx.perform(.right_half));
    fx.mock.advance(500 * ms);
    fx.eng.observed_pid = app_pid;
    const frames = fx.mock.setFrameCount();
    const f = fx.mock.frameOf(id);
    fx.press(.{ .x = f.x + 1, .y = 400 });
    fx.mock.setWindowFrame(id, .{ .x = f.x + 10, .y = f.y, .w = f.w - 10, .h = f.h });
    fx.dragTo(null, .{ .x = f.x + 11, .y = 400 });
    fx.observerMoved(id);
    observerResized(&fx, id); // the same frame change, reported second
    fx.confirmDrag();
    fx.dragTo(null, .{ .x = 2, .y = 400 });
    try testing.expectEqual(frames, fx.mock.setFrameCount());
    try testing.expectEqual(@as(usize, 0), fx.rec.count(.preview_show));
    fx.up();
    try fx.finish();
}

test "drag: a window held by the menu bar can be dragged up into the top zone" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    var c = t.Config{};
    c.snap_back = false;
    fx.setConfig(c);
    const id = try fx.addApp(app_pid, app_bundle, .{ .x = 0, .y = 25, .w = 720, .h = 875 });
    fx.eng.observed_pid = app_pid;
    fx.press(.{ .x = 300, .y = 37 }); // title bar, 12 pt below the window top
    fx.mock.moveWindowBy(id, 1, 0); // only the x follows: the menu bar stops the window
    fx.dragTo(null, .{ .x = 301, .y = 28 });
    fx.observerMoved(id);
    fx.confirmDrag();
    fx.dragTo(null, .{ .x = 301, .y = 2 });
    try expectEvent(fx.rec.last().?, .preview_show, .maximize);
    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    try testing.expectEqual(main_d.usable, fx.mock.frameOf(id));
    // The press-time frame was not estimated lower by the cursor's upward travel.
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(Rect{ .x = 0, .y = 25, .w = 720, .h = 875 }, fx.mock.frameOf(id));
    try fx.finish();
}

test "drag: ⌘-dragging a background window uses the fallback even with the observer" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const bg = try fx.addApp(77, "com.background", free_frame);
    _ = try fx.addApp(app_pid, app_bundle, .{ .x = 800, .y = 500, .w = 300, .h = 200 });
    fx.eng.observed_pid = app_pid; // frontmost app observed
    fx.eng.flagsChanged(Mods.command);
    fx.press(grab);
    fx.dragTo(null, .{ .x = grab.x + 10, .y = grab.y });
    try testing.expectEqual(@as(u32, 1), fx.mock.window_at_calls);
    fx.mock.moveWindowBy(bg, 12, 0);
    fx.mock.advance(30 * ms);
    fx.dragTo(null, .{ .x = grab.x + 12, .y = grab.y });
    fx.dragTo(bg, left_edge);
    try expectEvent(fx.rec.last().?, .preview_show, .left_half);
    fx.up();
    _ = fx.mock.runDeferred();
    try fx.finish();
}

test "applied frame: a min-size window that stays put is not a stale read (restore chain kept)" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const start = Rect{ .x = 100, .y = 100, .w = 1000, .h = 600 };
    const id = try fx.addApp(app_pid, app_bundle, start);
    fx.mock.window(id).min_w = 900;
    // 1/2 (900: min) → 2/3 → 1/3 (900: min) → 1/2: the 4th press asks only to shrink at the
    // same x and the window stays as it was → minimum size, not a stale read.
    for (0..4) |_| try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    const ev = fx.rec.lastOf(.snapped).?;
    try testing.expect(ev.flags & t.event_flag_frame_differs != 0);
    try testing.expectEqual(fx.mock.frameOf(id), ev.rect);
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(start, fx.mock.frameOf(id));
    try fx.finish();
}

test "applied frame: a drop after snap-back with a stale read-back trusts the zone" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    fx.mock.advance(500 * ms);
    fx.observerDrag(id, .{ .x = 180, .y = 35 }); // snap-back to 400×300
    fx.dragTo(id, .{ .x = 1439, .y = 450 });
    fx.up();
    fx.mock.stale_reads = 1;
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    const ev = fx.rec.lastOf(.snapped).?;
    try testing.expectEqual(@as(u32, 0), ev.flags);
    try testing.expectEqual(Rect{ .x = 720, .y = 25, .w = 720, .h = 875 }, ev.rect);
    try testing.expectEqual(@as(u32, 0), fx.mock.set_position_calls);
    try fx.finish();
}

test "drag: no hit-test fallback while the observer covers the frontmost app" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    fx.eng.observed_pid = app_pid;
    fx.press(.{ .x = 300, .y = 200 }); // text selection inside the window
    fx.dragTo(null, .{ .x = 340, .y = 220 });
    fx.dragTo(null, .{ .x = 400, .y = 260 });
    fx.up();
    try testing.expectEqual(@as(u32, 0), fx.mock.window_at_calls);
    try testing.expectEqual(@as(u32, 0), fx.mock.frame_calls);
    _ = id;
    try fx.finish();
}

test "drag: preview_hide carries the drop flag only when the drop will be applied" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    fx.observerDrag(id, grab);
    fx.dragTo(id, left_edge);
    fx.dragTo(id, center_pt); // left every zone: cancel
    try testing.expectEqual(@as(u32, 0), fx.rec.lastOf(.preview_hide).?.flags);
    fx.dragTo(id, left_edge);
    fx.up();
    try testing.expectEqual(t.event_flag_drop, fx.rec.lastOf(.preview_hide).?.flags);
    _ = fx.mock.runDeferred();
    try fx.finish();
}

test "drag: snap-back off — dragging a snapped window keeps the original pre-snap frame" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    var c = t.Config{};
    c.snap_back = false;
    fx.setConfig(c);
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    fx.mock.advance(500 * ms);
    fx.observerDrag(id, .{ .x = 300, .y = 35 });
    fx.dragTo(id, .{ .x = 1439, .y = 450 });
    try expectEvent(fx.rec.last().?, .preview_show, .right_half);
    fx.up();
    try testing.expectEqual(@as(usize, 1), fx.mock.runDeferred());
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(free_frame, fx.mock.frameOf(id));
    try fx.finish();
}

test "drag: snap-back on the observer path waits for real cursor travel" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
    fx.mock.advance(500 * ms);
    fx.eng.observed_pid = app_pid;
    fx.press(.{ .x = 180, .y = 35 });
    fx.dragTo(id, .{ .x = 182, .y = 35 });
    fx.observerMoved(id);
    try testing.expectEqual(@as(usize, 1), fx.mock.setFrameCount()); // not yet
    fx.dragTo(id, .{ .x = 190, .y = 35 });
    fx.confirmDrag();
    try testing.expectEqual(@as(usize, 2), fx.mock.setFrameCount()); // snap-back now
    try testing.expectEqual(free_frame.w, fx.mock.frameOf(id).w);
    fx.up();
    try fx.finish();
}

test "applied frame: async app, size-only cycle steps still advance (requested frame remembered)" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    const id = try fx.addApp(app_pid, app_bundle, free_frame);
    fx.mock.stale_reads = 1;
    const widths = [_]f64{ 720, 960, 480 };
    for (widths, 0..) |w, i| {
        try testing.expectEqual(t.Result.ok, fx.perform(.left_half));
        try testing.expectEqual(@as(u32, @intCast(i)), fx.rec.lastOf(.snapped).?.cycle);
        try testing.expectEqual(w, fx.mock.frameOf(id).w);
    }
    try testing.expectEqual(t.Result.ok, fx.perform(.restore));
    try testing.expectEqual(free_frame, fx.mock.frameOf(id));
    try fx.finish();
}

test "drag: a press that activates another app re-arms the fallback" {
    var fx: Fx = undefined;
    try fx.setup(&one_display);
    defer fx.deinit();
    _ = try fx.addApp(app_pid, app_bundle, .{ .x = 800, .y = 500, .w = 300, .h = 200 });
    const bg = try fx.mock.addWindow(.{ .pid = 77, .frame = free_frame });
    fx.eng.observed_pid = app_pid; // observer on the old frontmost app
    fx.press(grab);
    fx.dragTo(null, .{ .x = grab.x + 10, .y = grab.y }); // skipped: observer covers frontmost
    try testing.expectEqual(@as(u32, 0), fx.mock.window_at_calls);
    fx.eng.appActivated(77, "com.clicked"); // the click activated the other app …
    fx.eng.observed_pid = 0; // … and the observer could not attach to it
    fx.dragTo(null, .{ .x = grab.x + 12, .y = grab.y });
    try testing.expectEqual(@as(u32, 1), fx.mock.window_at_calls);
    fx.mock.moveWindowBy(bg, 12, 0);
    fx.mock.advance(30 * ms);
    fx.dragTo(bg, .{ .x = grab.x + 14, .y = grab.y });
    try testing.expectEqual(@as(u32, 1), fx.mock.info_calls); // drag began
    fx.up();
    try fx.finish();
}
