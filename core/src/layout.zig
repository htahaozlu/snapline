//! Pure layout engine: action + usable area → target frame. No platform calls.
//!
//! Tiling actions are defined as fractions of the unit square, then mapped onto the usable
//! area inset by the outer gap. Edges that lie inside the area (not on its border) are
//! inset by half the inner gap, so two neighbouring tiles end up exactly `inner` apart.

const std = @import("std");
const t = @import("types.zig");
const geo = @import("geometry.zig");
const Rect = t.Rect;
const Action = t.Action;

pub const Gaps = struct {
    outer: f64 = 0,
    inner: f64 = 0,
};

pub const Options = struct {
    gaps: Gaps = .{},
    cycle_sizes: bool = true,
    almost_maximize: f64 = 0.9,
};

pub fn optionsFromConfig(c: t.Config) Options {
    return .{
        .gaps = .{ .outer = c.gap_outer, .inner = c.gap_inner },
        .cycle_sizes = c.cycle_sizes,
        .almost_maximize = c.almost_maximize,
    };
}

/// Unit-square fraction. `tile == false` means the frame is free-floating (no inner gaps).
pub const Fraction = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    tile: bool = true,
};

/// Width/height fractions visited when a half action is repeated.
pub const half_cycle = [_]f64{ 1.0 / 2.0, 2.0 / 3.0, 1.0 / 3.0 };

/// How many distinct sizes `a` cycles through when repeated on the same window.
pub fn cycleLength(a: Action, cycle_sizes: bool) u32 {
    if (!cycle_sizes) return 1;
    return switch (a) {
        .left_half, .right_half, .top_half, .bottom_half => half_cycle.len,
        else => 1,
    };
}

/// True for actions that compute a frame from the area alone (or the window size, for
/// `center`). Restore and display moves are handled by the engine.
pub fn isFrameAction(a: Action) bool {
    return switch (a) {
        .none, .restore, .next_display, .prev_display => false,
        else => true,
    };
}

/// Fraction for a tiling action. `portrait` flips thirds/two-thirds to rows.
pub fn fraction(a: Action, cycle: u32, portrait: bool, almost: f64) ?Fraction {
    const s = half_cycle[cycle % half_cycle.len];
    const third = 1.0 / 3.0;
    const two = 2.0 / 3.0;
    return switch (a) {
        .left_half => .{ .x = 0, .y = 0, .w = s, .h = 1 },
        .right_half => .{ .x = 1 - s, .y = 0, .w = s, .h = 1 },
        .top_half => .{ .x = 0, .y = 0, .w = 1, .h = s },
        .bottom_half => .{ .x = 0, .y = 1 - s, .w = 1, .h = s },
        .top_left => .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .top_right => .{ .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .bottom_left => .{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 },
        .bottom_right => .{ .x = 0.5, .y = 0.5, .w = 0.5, .h = 0.5 },
        .first_third => band(0, third, portrait),
        .center_third => band(third, third, portrait),
        .last_third => band(two, third, portrait),
        .first_two_thirds => band(0, two, portrait),
        .center_two_thirds => band(1.0 / 6.0, two, portrait),
        .last_two_thirds => band(third, two, portrait),
        .maximize => .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .almost_maximize => blk: {
            const r = std.math.clamp(almost, 0.5, 1.0);
            break :blk .{ .x = (1 - r) / 2, .y = (1 - r) / 2, .w = r, .h = r, .tile = false };
        },
        .none, .center, .restore, .next_display, .prev_display => null,
    };
}

fn band(start: f64, len: f64, portrait: bool) Fraction {
    if (portrait) return .{ .x = 0, .y = start, .w = 1, .h = len };
    return .{ .x = start, .y = 0, .w = len, .h = 1 };
}

/// Maps a fraction onto `usable`, applying gaps, and rounds edges to whole points.
pub fn frameFromFraction(f: Fraction, usable: Rect, gaps: Gaps) Rect {
    const inner_area = geo.inset(usable, @max(gaps.outer, 0));
    var x0 = inner_area.x + f.x * inner_area.w;
    var x1 = inner_area.x + (f.x + f.w) * inner_area.w;
    var y0 = inner_area.y + f.y * inner_area.h;
    var y1 = inner_area.y + (f.y + f.h) * inner_area.h;
    if (f.tile and gaps.inner > 0) {
        const half = gaps.inner / 2;
        if (f.x > geo.eps) x0 += half;
        if (f.x + f.w < 1 - geo.eps) x1 -= half;
        if (f.y > geo.eps) y0 += half;
        if (f.y + f.h < 1 - geo.eps) y1 -= half;
    }
    if (x1 - x0 < 1) x1 = x0 + 1;
    if (y1 - y0 < 1) y1 = y0 + 1;
    return geo.integral(.{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 });
}

/// Target frame for frame actions. `window` is the current frame (used by `center`).
/// Returns null for actions handled elsewhere (restore, display moves, none).
pub fn frameFor(a: Action, window: Rect, usable: Rect, cycle: u32, opts: Options) ?Rect {
    if (usable.isEmpty()) return null;
    if (a == .center) {
        const bounds = geo.inset(usable, @max(opts.gaps.outer, 0));
        return geo.integral(geo.centered(window.w, window.h, bounds));
    }
    const portrait = usable.h > usable.w;
    const f = fraction(a, cycle, portrait, opts.almost_maximize) orelse return null;
    return frameFromFraction(f, usable, opts.gaps);
}

/// Next cycle index: if the same action is repeated while the window still sits at the
/// frame produced last time, advance; otherwise start over.
pub fn nextCycle(a: Action, last_action: Action, last_cycle: u32, still_at_last_target: bool, cycle_sizes: bool) u32 {
    const len = cycleLength(a, cycle_sizes);
    if (len <= 1) return 0;
    if (a == last_action and still_at_last_target) return (last_cycle + 1) % len;
    return 0;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const screen = Rect{ .x = 0, .y = 25, .w = 1200, .h = 775 };
const win = Rect{ .x = 100, .y = 100, .w = 400, .h = 300 };

fn ff(a: Action) Rect {
    return frameFor(a, win, screen, 0, .{}).?;
}

test "halves and quarters tile the screen" {
    try testing.expectEqual(Rect{ .x = 0, .y = 25, .w = 600, .h = 775 }, ff(.left_half));
    try testing.expectEqual(Rect{ .x = 600, .y = 25, .w = 600, .h = 775 }, ff(.right_half));
    const tl = ff(.top_left);
    const br = ff(.bottom_right);
    try testing.expectEqual(screen.maxX(), br.maxX());
    try testing.expectEqual(screen.maxY(), br.maxY());
    try testing.expectEqual(tl.maxX(), br.minX());
    try testing.expectEqual(ff(.top_half).maxY(), ff(.bottom_half).minY());
}

test "thirds are contiguous and cover the width" {
    const a = ff(.first_third);
    const b = ff(.center_third);
    const c = ff(.last_third);
    try testing.expectEqual(screen.minX(), a.minX());
    try testing.expectEqual(a.maxX(), b.minX());
    try testing.expectEqual(b.maxX(), c.minX());
    try testing.expectEqual(screen.maxX(), c.maxX());
    try testing.expectEqual(@as(f64, 800), ff(.first_two_thirds).w);
    try testing.expectEqual(@as(f64, 200), ff(.center_two_thirds).minX());
    try testing.expectEqual(screen.maxX(), ff(.last_two_thirds).maxX());
}

test "portrait thirds become rows" {
    const tall = Rect{ .x = 0, .y = 0, .w = 900, .h = 1600 };
    const r = frameFor(.first_third, win, tall, 0, .{}).?;
    try testing.expectEqual(@as(f64, 900), r.w);
    try testing.expect(@abs(r.h - 533) <= 1);
}

test "gaps: outer border and inner seam" {
    const o = Options{ .gaps = .{ .outer = 10, .inner = 8 } };
    const l = frameFor(.left_half, win, screen, 0, o).?;
    const r = frameFor(.right_half, win, screen, 0, o).?;
    try testing.expectEqual(@as(f64, 10), l.minX());
    try testing.expectEqual(screen.minY() + 10, l.minY());
    try testing.expectEqual(screen.maxX() - 10, r.maxX());
    try testing.expectEqual(@as(f64, 8), r.minX() - l.maxX());
    const m = frameFor(.maximize, win, screen, 0, o).?;
    try testing.expectEqual(geo.inset(screen, 10), m);
}

test "almost maximize is centered and ignores inner gap" {
    const o = Options{ .gaps = .{ .inner = 20 }, .almost_maximize = 0.8 };
    const r = frameFor(.almost_maximize, win, screen, 0, o).?;
    try testing.expectEqual(@as(f64, 960), r.w);
    try testing.expectEqual(@as(f64, 120), r.minX());
    try testing.expect(@abs(r.midY() - screen.midY()) <= 1);
}

test "center keeps size and clamps oversize windows" {
    const r = ff(.center);
    try testing.expectEqual(win.w, r.w);
    try testing.expectEqual(win.h, r.h);
    try testing.expect(@abs(r.midX() - screen.midX()) <= 1);
    const huge = frameFor(.center, .{ .x = 0, .y = 0, .w = 5000, .h = 5000 }, screen, 0, .{}).?;
    try testing.expectEqual(screen, huge);
}

test "half cycling 1/2 → 2/3 → 1/3 → 1/2" {
    try testing.expectEqual(@as(u32, 1), nextCycle(.left_half, .left_half, 0, true, true));
    try testing.expectEqual(@as(u32, 2), nextCycle(.left_half, .left_half, 1, true, true));
    try testing.expectEqual(@as(u32, 0), nextCycle(.left_half, .left_half, 2, true, true));
    try testing.expectEqual(@as(u32, 0), nextCycle(.left_half, .left_half, 0, false, true));
    try testing.expectEqual(@as(u32, 0), nextCycle(.left_half, .right_half, 0, true, true));
    try testing.expectEqual(@as(u32, 0), nextCycle(.left_half, .left_half, 0, true, false));
    try testing.expectEqual(@as(u32, 0), nextCycle(.maximize, .maximize, 0, true, true));
    const w1 = frameFor(.left_half, win, screen, 1, .{}).?;
    try testing.expectEqual(@as(f64, 800), w1.w);
    const w2 = frameFor(.right_half, win, screen, 2, .{}).?;
    try testing.expectEqual(@as(f64, 400), w2.w);
    try testing.expectEqual(screen.maxX(), w2.maxX());
}

test "non-frame actions return null" {
    try testing.expect(frameFor(.restore, win, screen, 0, .{}) == null);
    try testing.expect(frameFor(.next_display, win, screen, 0, .{}) == null);
    try testing.expect(frameFor(.none, win, screen, 0, .{}) == null);
    try testing.expect(frameFor(.left_half, win, .{}, 0, .{}) == null);
}

test "every frame action stays inside the usable area" {
    const o = Options{ .gaps = .{ .outer = 6, .inner = 6 } };
    var i: u32 = 1;
    while (i < Action.count) : (i += 1) {
        const a = Action.fromInt(i).?;
        var c: u32 = 0;
        while (c < 3) : (c += 1) {
            const r = frameFor(a, win, screen, c, o) orelse continue;
            try testing.expect(r.minX() >= screen.minX() and r.maxX() <= screen.maxX());
            try testing.expect(r.minY() >= screen.minY() and r.maxY() <= screen.maxY());
            try testing.expect(!r.isEmpty());
        }
    }
}
