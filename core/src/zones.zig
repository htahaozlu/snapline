//! Pure drag-to-snap zone hit testing. The cursor position is tested against the *full*
//! display bounds (the menu bar strip counts as the top edge); the resulting action is
//! later laid out on the display's usable area.

const std = @import("std");
const t = @import("types.zig");
const geo = @import("geometry.zig");
const Point = t.Point;
const Display = t.Display;
const Zone = t.Zone;
const Action = t.Action;

pub const ZoneMap = struct {
    primary: [Zone.count]Action,
    alternate: [Zone.count]Action,

    pub fn defaults() ZoneMap {
        var m: ZoneMap = undefined;
        for (0..Zone.count) |i| {
            const z: Zone = @enumFromInt(@as(u32, @intCast(i)));
            m.primary[i] = t.defaultZoneAction(z, false);
            m.alternate[i] = t.defaultZoneAction(z, true);
        }
        return m;
    }

    pub fn get(m: *const ZoneMap, z: Zone, alternate: bool) Action {
        const i = @intFromEnum(z);
        return if (alternate) m.alternate[i] else m.primary[i];
    }

    pub fn set(m: *ZoneMap, z: Zone, alternate: bool, a: Action) void {
        const i = @intFromEnum(z);
        if (alternate) m.alternate[i] = a else m.primary[i] = a;
    }
};

pub const Params = struct {
    edge: f64 = 5,
    corner: f64 = 32,
    shared_edge_zones: bool = false,

    pub fn fromConfig(c: t.Config) Params {
        return .{ .edge = c.zone_edge, .corner = c.zone_corner, .shared_edge_zones = c.shared_edge_zones };
    }
};

pub const Hit = struct {
    zone: Zone,
    display_index: usize,
};

/// Returns the zone under `p`, or null when the cursor is not in any active zone.
pub fn hitTest(p: Point, displays: []const Display, params: Params) ?Hit {
    const idx = geo.displayIndexForPoint(p, displays) orelse return null;
    const b = displays[idx].bounds;
    // An edge is "shared" only where another display continues it at the cursor's position:
    // the cursor passes to the neighbour there, but stops at the rest of the edge (a laptop
    // below a wider external display leaves most of the external's bottom edge a wall).
    const sh = params.shared_edge_zones;
    const shared = geo.Edges{
        .left = !sh and across(displays, b.minX() - probe, p.y),
        .right = !sh and across(displays, b.maxX() + probe, p.y),
        .top = !sh and across(displays, p.x, b.minY() - probe),
        .bottom = !sh and across(displays, p.x, b.maxY() + probe),
    };

    const dl = p.x - b.minX();
    const dr = b.maxX() - p.x; // cursor x maxes out at maxX-1, so dr ≥ 1 at the edge
    const dt = p.y - b.minY();
    const db = b.maxY() - p.y;
    const e = params.edge;
    const c = @max(params.corner, e);

    // The cursor reaches minX/minY exactly but stops at maxX-1/maxY-1, so the near bands
    // use `<` and the far bands `<=`: every band is exactly `e` points wide.
    const at_left = !shared.left and dl < e;
    const at_right = !shared.right and dr <= e;
    const at_top = !shared.top and dt < e;
    const at_bottom = !shared.bottom and db <= e;

    const zone: Zone = blk: {
        if ((at_left and dt <= c) or (at_top and dl <= c)) break :blk .top_left;
        if ((at_right and dt <= c) or (at_top and dr <= c)) break :blk .top_right;
        if ((at_left and db <= c) or (at_bottom and dl <= c)) break :blk .bottom_left;
        if ((at_right and db <= c) or (at_bottom and dr <= c)) break :blk .bottom_right;
        if (at_left) break :blk .left;
        if (at_right) break :blk .right;
        if (at_top) break :blk .top;
        if (at_bottom) {
            const rel = (p.x - b.minX()) / b.w;
            if (rel < 1.0 / 3.0) break :blk .bottom_left_seg;
            if (rel < 2.0 / 3.0) break :blk .bottom_center_seg;
            break :blk .bottom_right_seg;
        }
        return null;
    };
    return .{ .zone = zone, .display_index = idx };
}

/// Half a point beyond an edge: inside a neighbour that starts or ends exactly at it.
const probe = 0.5;

fn across(displays: []const Display, x: f64, y: f64) bool {
    return geo.displayIndexForPoint(.{ .x = x, .y = y }, displays) != null;
}

/// On portrait displays thirds become rows (layout.band), so the bottom-edge segments
/// would send a window to the TOP row. There every bottom segment means the bottom row.
pub fn orient(action: Action, zone: Zone, portrait: bool) Action {
    if (!portrait) return action;
    switch (zone) {
        .bottom_left_seg, .bottom_center_seg, .bottom_right_seg => {},
        else => return action,
    }
    return switch (action) {
        .first_third, .center_third, .last_third => .last_third,
        .first_two_thirds, .center_two_thirds, .last_two_thirds => .last_two_thirds,
        else => action,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn disp(id: u32, x: f64, y: f64, w: f64, h: f64) Display {
    return .{ .id = id, .bounds = .{ .x = x, .y = y, .w = w, .h = h }, .usable = .{ .x = x, .y = y + 25, .w = w, .h = h - 25 } };
}

const one = [_]Display{disp(1, 0, 0, 1000, 800)};

fn zoneAt(x: f64, y: f64) Zone {
    return if (hitTest(.{ .x = x, .y = y }, &one, .{})) |h| h.zone else .none;
}

test "edges and corners" {
    try testing.expectEqual(Zone.left, zoneAt(0, 400));
    try testing.expectEqual(Zone.right, zoneAt(999, 400));
    try testing.expectEqual(Zone.top, zoneAt(500, 0));
    try testing.expectEqual(Zone.top_left, zoneAt(0, 10));
    try testing.expectEqual(Zone.top_left, zoneAt(30, 0));
    try testing.expectEqual(Zone.top_right, zoneAt(999, 0));
    try testing.expectEqual(Zone.bottom_left, zoneAt(0, 799));
    try testing.expectEqual(Zone.bottom_right, zoneAt(990, 799));
    try testing.expectEqual(Zone.none, zoneAt(500, 400));
}

test "bottom edge is split into thirds" {
    try testing.expectEqual(Zone.bottom_left_seg, zoneAt(200, 799));
    try testing.expectEqual(Zone.bottom_center_seg, zoneAt(500, 799));
    try testing.expectEqual(Zone.bottom_right_seg, zoneAt(800, 799));
}

test "a partly shared edge keeps its zones where nothing continues it" {
    // External 1920×1080 at the origin, laptop 1512×982 centered below it.
    const ds = [_]Display{ disp(1, 0, 0, 1920, 1080), disp(2, 204, 1080, 1512, 982) };
    const at = struct {
        fn z(d: []const Display, x: f64, y: f64) Zone {
            return if (hitTest(.{ .x = x, .y = y }, d, .{})) |h| h.zone else .none;
        }
    }.z;
    // External bottom edge: a wall left of the laptop, shared above it.
    try testing.expectEqual(Zone.bottom_left_seg, at(&ds, 100, 1079));
    try testing.expectEqual(Zone.none, at(&ds, 900, 1079));
    try testing.expectEqual(Zone.bottom_right_seg, at(&ds, 1800, 1079));
    // Laptop top edge lies entirely under the external display: shared everywhere.
    try testing.expectEqual(Zone.none, at(&ds, 900, 1080));
    // The setting turns the shared stretch on as well.
    try testing.expectEqual(Zone.bottom_center_seg, if (hitTest(.{ .x = 900, .y = 1079 }, &ds, .{ .shared_edge_zones = true })) |h| h.zone else .none);
}

test "shared edges are inactive by default" {
    const two = [_]Display{ disp(1, 0, 0, 1000, 800), disp(2, 1000, 0, 1000, 800) };
    try testing.expect(hitTest(.{ .x = 999, .y = 400 }, &two, .{}) == null);
    try testing.expect(hitTest(.{ .x = 1000, .y = 400 }, &two, .{}) == null);
    // corners remain reachable through the active top edge
    const h = hitTest(.{ .x = 990, .y = 0 }, &two, .{}).?;
    try testing.expectEqual(Zone.top_right, h.zone);
    try testing.expectEqual(@as(usize, 0), h.display_index);
    // opt-in
    const h2 = hitTest(.{ .x = 999, .y = 400 }, &two, .{ .shared_edge_zones = true }).?;
    try testing.expectEqual(Zone.right, h2.zone);
    // far edge of the second display still works
    try testing.expectEqual(Zone.right, hitTest(.{ .x = 1999, .y = 400 }, &two, .{}).?.zone);
}

test "bands are exactly edge points wide on every side" {
    const p = Params{ .edge = 3, .corner = 8 };
    try testing.expect(hitTest(.{ .x = 2, .y = 400 }, &one, p) != null);
    try testing.expect(hitTest(.{ .x = 3, .y = 400 }, &one, p) == null);
    try testing.expect(hitTest(.{ .x = 997, .y = 400 }, &one, p) != null); // dr = 3
    try testing.expect(hitTest(.{ .x = 996, .y = 400 }, &one, p) == null);
}

test "portrait bottom segments mean the bottom row" {
    try testing.expectEqual(Action.last_third, orient(.first_third, .bottom_left_seg, true));
    try testing.expectEqual(Action.last_two_thirds, orient(.center_two_thirds, .bottom_center_seg, true));
    try testing.expectEqual(Action.first_third, orient(.first_third, .bottom_left_seg, false));
    try testing.expectEqual(Action.first_third, orient(.first_third, .left, true));
}

test "outside all displays" {
    try testing.expect(hitTest(.{ .x = -5, .y = 10 }, &one, .{}) == null);
}

test "zone map defaults and overrides" {
    var m = ZoneMap.defaults();
    try testing.expectEqual(Action.left_half, m.get(.left, false));
    try testing.expectEqual(Action.first_third, m.get(.left, true));
    try testing.expectEqual(Action.maximize, m.get(.top, false));
    m.set(.top, false, .none);
    try testing.expectEqual(Action.none, m.get(.top, false));
}
