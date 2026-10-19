//! Pure rectangle and display math. No platform calls, no allocation.

const std = @import("std");
const t = @import("types.zig");
const Rect = t.Rect;
const Point = t.Point;
const Display = t.Display;

pub const eps: f64 = 1e-6;

pub fn intersection(a: Rect, b: Rect) Rect {
    const x0 = @max(a.minX(), b.minX());
    const y0 = @max(a.minY(), b.minY());
    const x1 = @min(a.maxX(), b.maxX());
    const y1 = @min(a.maxY(), b.maxY());
    if (x1 <= x0 or y1 <= y0) return .{ .x = x0, .y = y0, .w = 0, .h = 0 };
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

pub fn area(r: Rect) f64 {
    if (r.isEmpty()) return 0;
    return r.w * r.h;
}

/// Half-open containment: [minX, maxX) × [minY, maxY).
pub fn contains(r: Rect, p: Point) bool {
    return p.x >= r.minX() and p.x < r.maxX() and p.y >= r.minY() and p.y < r.maxY();
}

pub fn inset(r: Rect, d: f64) Rect {
    if (r.w <= 2 * d or r.h <= 2 * d) return r;
    return .{ .x = r.x + d, .y = r.y + d, .w = r.w - 2 * d, .h = r.h - 2 * d };
}

/// True if every edge of `a` is within `tol` points of the matching edge of `b`.
pub fn approxEqual(a: Rect, b: Rect, tol: f64) bool {
    return @abs(a.minX() - b.minX()) <= tol and @abs(a.minY() - b.minY()) <= tol and
        @abs(a.maxX() - b.maxX()) <= tol and @abs(a.maxY() - b.maxY()) <= tol;
}

/// Rounds edges (not origin+size separately) to whole points so adjacent tiles share edges.
pub fn integral(r: Rect) Rect {
    const x0 = @round(r.minX());
    const y0 = @round(r.minY());
    const x1 = @round(r.maxX());
    const y1 = @round(r.maxY());
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 1), .h = @max(y1 - y0, 1) };
}

/// Shrinks `r` to fit into `bounds` and moves it fully inside.
pub fn clampInto(r: Rect, bounds: Rect) Rect {
    var o = r;
    o.w = @min(o.w, bounds.w);
    o.h = @min(o.h, bounds.h);
    if (o.x < bounds.minX()) o.x = bounds.minX();
    if (o.y < bounds.minY()) o.y = bounds.minY();
    if (o.maxX() > bounds.maxX()) o.x = bounds.maxX() - o.w;
    if (o.maxY() > bounds.maxY()) o.y = bounds.maxY() - o.h;
    return o;
}

/// Centers a rect of `size` (clamped) inside `bounds`.
pub fn centered(size_w: f64, size_h: f64, bounds: Rect) Rect {
    const w = @min(size_w, bounds.w);
    const h = @min(size_h, bounds.h);
    return .{ .x = bounds.x + (bounds.w - w) / 2, .y = bounds.y + (bounds.h - h) / 2, .w = w, .h = h };
}

fn centerDistanceSq(a: Rect, p: Point) f64 {
    // Distance from p to the nearest point of a.
    const cx = std.math.clamp(p.x, a.minX(), a.maxX());
    const cy = std.math.clamp(p.y, a.minY(), a.maxY());
    const dx = p.x - cx;
    const dy = p.y - cy;
    return dx * dx + dy * dy;
}

pub fn displayIndexForPoint(p: Point, displays: []const Display) ?usize {
    for (displays, 0..) |d, i| {
        if (contains(d.bounds, p)) return i;
    }
    return null;
}

/// Display with the largest overlap with `r`; if none overlaps, the nearest to r's center.
pub fn displayIndexForRect(r: Rect, displays: []const Display) ?usize {
    if (displays.len == 0) return null;
    var best: usize = 0;
    var best_area: f64 = -1;
    for (displays, 0..) |d, i| {
        const a = area(intersection(r, d.bounds));
        if (a > best_area) {
            best_area = a;
            best = i;
        }
    }
    if (best_area > 0) return best;
    const c = Point{ .x = r.midX(), .y = r.midY() };
    var best_d: f64 = std.math.inf(f64);
    for (displays, 0..) |d, i| {
        const dist = centerDistanceSq(d.bounds, c);
        if (dist < best_d) {
            best_d = dist;
            best = i;
        }
    }
    return best;
}

pub const Direction = enum { next, prev };

/// Next/previous display in reading order (left→right by x, then top→bottom by y), wrapping.
pub fn adjacentDisplay(current: usize, displays: []const Display, dir: Direction) usize {
    const n = displays.len;
    if (n <= 1 or current >= n) return current;
    var order: [t.max_displays]usize = undefined;
    const m = @min(n, t.max_displays);
    for (0..m) |i| order[i] = i;
    // insertion sort, n ≤ 16
    var i: usize = 1;
    while (i < m) : (i += 1) {
        const key = order[i];
        var j = i;
        while (j > 0 and lessDisplay(displays[key], displays[order[j - 1]])) : (j -= 1) {
            order[j] = order[j - 1];
        }
        order[j] = key;
    }
    var pos: usize = 0;
    for (order[0..m], 0..) |idx, k| {
        if (idx == current) pos = k;
    }
    const next_pos = switch (dir) {
        .next => (pos + 1) % m,
        .prev => (pos + m - 1) % m,
    };
    return order[next_pos];
}

fn lessDisplay(a: Display, b: Display) bool {
    if (a.bounds.x != b.bounds.x) return a.bounds.x < b.bounds.x;
    return a.bounds.y < b.bounds.y;
}

/// Maps `r` from one usable area to another, preserving relative position and proportional size.
pub fn mapBetween(r: Rect, from: Rect, to: Rect) Rect {
    if (from.isEmpty() or to.isEmpty()) return clampInto(r, to);
    const sx = to.w / from.w;
    const sy = to.h / from.h;
    const mapped = Rect{
        .x = to.x + (r.x - from.x) * sx,
        .y = to.y + (r.y - from.y) * sy,
        .w = r.w * sx,
        .h = r.h * sy,
    };
    return integral(clampInto(mapped, to));
}

pub const Edges = struct {
    left: bool = false,
    right: bool = false,
    top: bool = false,
    bottom: bool = false,
};

/// Which edges of displays[i] touch another display (overlapping along the edge).
pub fn sharedEdges(i: usize, displays: []const Display) Edges {
    var e = Edges{};
    const a = displays[i].bounds;
    for (displays, 0..) |d, j| {
        if (j == i) continue;
        const b = d.bounds;
        const v_overlap = @min(a.maxY(), b.maxY()) - @max(a.minY(), b.minY()) > eps;
        const h_overlap = @min(a.maxX(), b.maxX()) - @max(a.minX(), b.minX()) > eps;
        if (v_overlap and @abs(b.maxX() - a.minX()) < 1) e.left = true;
        if (v_overlap and @abs(b.minX() - a.maxX()) < 1) e.right = true;
        if (h_overlap and @abs(b.maxY() - a.minY()) < 1) e.top = true;
        if (h_overlap and @abs(b.minY() - a.maxY()) < 1) e.bottom = true;
    }
    return e;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn disp(id: u32, x: f64, y: f64, w: f64, h: f64) Display {
    return .{ .id = id, .bounds = .{ .x = x, .y = y, .w = w, .h = h }, .usable = .{ .x = x, .y = y + 25, .w = w, .h = h - 25 } };
}

test "intersection and area" {
    const a = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const b = Rect{ .x = 50, .y = 50, .w = 100, .h = 100 };
    try testing.expectEqual(@as(f64, 2500), area(intersection(a, b)));
    try testing.expectEqual(@as(f64, 0), area(intersection(a, .{ .x = 200, .y = 0, .w = 10, .h = 10 })));
}

test "contains is half-open" {
    const r = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try testing.expect(contains(r, .{ .x = 0, .y = 0 }));
    try testing.expect(!contains(r, .{ .x = 10, .y = 5 }));
}

test "clampInto shrinks and moves" {
    const b = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const r = clampInto(.{ .x = 90, .y = -20, .w = 50, .h = 200 }, b);
    try testing.expectEqual(Rect{ .x = 50, .y = 0, .w = 50, .h = 100 }, r);
}

test "integral keeps shared edges" {
    const a = integral(.{ .x = 0, .y = 0, .w = 333.333, .h = 10 });
    const b = integral(.{ .x = 333.333, .y = 0, .w = 333.333, .h = 10 });
    try testing.expectEqual(a.maxX(), b.minX());
}

test "display for rect and point" {
    const ds = [_]Display{ disp(1, 0, 0, 1000, 800), disp(2, 1000, 0, 800, 600) };
    try testing.expectEqual(@as(?usize, 1), displayIndexForPoint(.{ .x = 1500, .y = 10 }, &ds));
    try testing.expectEqual(@as(?usize, null), displayIndexForPoint(.{ .x = 5000, .y = 10 }, &ds));
    try testing.expectEqual(@as(?usize, 1), displayIndexForRect(.{ .x = 900, .y = 0, .w = 400, .h = 100 }, &ds));
    // off-screen rect → nearest
    try testing.expectEqual(@as(?usize, 1), displayIndexForRect(.{ .x = 3000, .y = 0, .w = 10, .h = 10 }, &ds));
}

test "adjacent display order wraps" {
    // deliberately unsorted input
    const ds = [_]Display{ disp(1, 1000, 0, 800, 600), disp(2, -1200, 0, 1200, 900), disp(3, 0, 0, 1000, 800) };
    try testing.expectEqual(@as(usize, 0), adjacentDisplay(2, &ds, .next));
    try testing.expectEqual(@as(usize, 1), adjacentDisplay(0, &ds, .next));
    try testing.expectEqual(@as(usize, 0), adjacentDisplay(1, &ds, .prev));
    const one = [_]Display{disp(1, 0, 0, 10, 10)};
    try testing.expectEqual(@as(usize, 0), adjacentDisplay(0, &one, .next));
}

test "mapBetween keeps proportions" {
    const from = Rect{ .x = 0, .y = 0, .w = 1000, .h = 1000 };
    const to = Rect{ .x = 1000, .y = 0, .w = 2000, .h = 500 };
    const r = mapBetween(.{ .x = 0, .y = 0, .w = 500, .h = 1000 }, from, to);
    try testing.expectEqual(Rect{ .x = 1000, .y = 0, .w = 1000, .h = 500 }, r);
}

test "shared edges" {
    const ds = [_]Display{ disp(1, 0, 0, 1000, 800), disp(2, 1000, 100, 800, 600), disp(3, 0, -600, 1000, 600) };
    const e0 = sharedEdges(0, &ds);
    try testing.expect(e0.right and e0.top and !e0.left and !e0.bottom);
    const e1 = sharedEdges(1, &ds);
    try testing.expect(e1.left and !e1.right);
}
