//! Shared value types. Layouts mirror core/include/nokta.h exactly (extern structs/enums)
//! so they cross the C ABI without conversion.

const std = @import("std");

pub const abi_version: u32 = 1;

/// CoreGraphics global coordinates: origin top-left of the primary display, y down, points.
pub const Rect = extern struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    pub fn minX(r: Rect) f64 {
        return r.x;
    }
    pub fn maxX(r: Rect) f64 {
        return r.x + r.w;
    }
    pub fn minY(r: Rect) f64 {
        return r.y;
    }
    pub fn maxY(r: Rect) f64 {
        return r.y + r.h;
    }
    pub fn midX(r: Rect) f64 {
        return r.x + r.w / 2;
    }
    pub fn midY(r: Rect) f64 {
        return r.y + r.h / 2;
    }
    pub fn isEmpty(r: Rect) bool {
        return !(r.w > 0 and r.h > 0);
    }
};

pub const Point = extern struct {
    x: f64 = 0,
    y: f64 = 0,
};

pub const Action = enum(u32) {
    none = 0,
    left_half = 1,
    right_half = 2,
    top_half = 3,
    bottom_half = 4,
    top_left = 5,
    top_right = 6,
    bottom_left = 7,
    bottom_right = 8,
    first_third = 9,
    center_third = 10,
    last_third = 11,
    first_two_thirds = 12,
    center_two_thirds = 13,
    last_two_thirds = 14,
    maximize = 15,
    almost_maximize = 16,
    center = 17,
    restore = 18,
    next_display = 19,
    prev_display = 20,

    pub const count: u32 = 21;

    pub fn fromInt(v: u32) ?Action {
        if (v >= count) return null;
        return @enumFromInt(v);
    }

    /// Stable persistence identifier.
    pub fn id(a: Action) [:0]const u8 {
        return switch (a) {
            .none => "none",
            .left_half => "left-half",
            .right_half => "right-half",
            .top_half => "top-half",
            .bottom_half => "bottom-half",
            .top_left => "top-left",
            .top_right => "top-right",
            .bottom_left => "bottom-left",
            .bottom_right => "bottom-right",
            .first_third => "first-third",
            .center_third => "center-third",
            .last_third => "last-third",
            .first_two_thirds => "first-two-thirds",
            .center_two_thirds => "center-two-thirds",
            .last_two_thirds => "last-two-thirds",
            .maximize => "maximize",
            .almost_maximize => "almost-maximize",
            .center => "center",
            .restore => "restore",
            .next_display => "next-display",
            .prev_display => "prev-display",
        };
    }

    pub fn fromId(s: []const u8) Action {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const a: Action = @enumFromInt(i);
            if (std.mem.eql(u8, s, a.id())) return a;
        }
        return .none;
    }
};

pub const Zone = enum(u32) {
    none = 0,
    left = 1,
    right = 2,
    top = 3,
    top_left = 4,
    top_right = 5,
    bottom_left = 6,
    bottom_right = 7,
    bottom_left_seg = 8,
    bottom_center_seg = 9,
    bottom_right_seg = 10,

    pub const count: u32 = 11;

    pub fn fromInt(v: u32) ?Zone {
        if (v >= count) return null;
        return @enumFromInt(v);
    }

    pub fn id(z: Zone) [:0]const u8 {
        return switch (z) {
            .none => "none",
            .left => "left",
            .right => "right",
            .top => "top",
            .top_left => "top-left",
            .top_right => "top-right",
            .bottom_left => "bottom-left",
            .bottom_right => "bottom-right",
            .bottom_left_seg => "bottom-left-segment",
            .bottom_center_seg => "bottom-center-segment",
            .bottom_right_seg => "bottom-right-segment",
        };
    }
};

/// Nokta modifier bits (NK_MOD_*).
pub const Mods = struct {
    pub const shift: u32 = 1 << 0;
    pub const control: u32 = 1 << 1;
    pub const option: u32 = 1 << 2;
    pub const command: u32 = 1 << 3;
    pub const all: u32 = shift | control | option | command;
};

pub const key_none: u32 = 0xFFFF;

pub const Result = enum(i32) {
    ok = 0,
    not_trusted = 1,
    no_window = 2,
    ax = 3,
    excluded = 4,
    invalid = 5,
    not_movable = 6,
    no_memory = 7,
    event_tap = 8,
    hotkey = 9,
    not_started = 10,
};

pub const Config = extern struct {
    abi_version: u32 = abi_version,
    gap_outer: f64 = 0,
    gap_inner: f64 = 0,
    zone_edge: f64 = 5, // "Normal" preset (Tight 3/20, Normal 5/32, Wide 10/48)
    zone_corner: f64 = 32,
    almost_maximize: f64 = 0.9,
    thirds_modifier: u32 = Mods.shift,
    drag_snap: bool = true,
    snap_back: bool = true,
    cycle_sizes: bool = true,
    shared_edge_zones: bool = false,

    /// Clamps every field into its valid range. Returns null on ABI mismatch.
    pub fn sanitized(c: Config) ?Config {
        if (c.abi_version != abi_version) return null;
        var o = c;
        o.gap_outer = clampF(o.gap_outer, 0, 64);
        o.gap_inner = clampF(o.gap_inner, 0, 64);
        o.zone_edge = clampF(o.zone_edge, 1, 40);
        o.zone_corner = clampF(o.zone_corner, 8, 200);
        o.almost_maximize = clampF(o.almost_maximize, 0.5, 1.0);
        o.thirds_modifier &= Mods.all;
        return o;
    }
};

fn clampF(v: f64, lo: f64, hi: f64) f64 {
    if (std.math.isNan(v)) return lo;
    return @min(@max(v, lo), hi);
}

pub const EventKind = enum(u32) {
    preview_show = 1,
    preview_hide = 2,
    snapped = 3,
    failed = 4,
    hotkey_state = 5,
};

pub const Source = enum(u32) {
    keyboard = 1,
    drag = 2,
    menu = 3,
};

/// Event.flags bit: the window ended up > 2 pt away from the requested frame (rect = actual).
pub const event_flag_frame_differs: u32 = 1 << 0;
pub const event_flag_size_refused: u32 = 1 << 1;
pub const event_flag_drop: u32 = 1 << 2;

pub const Event = extern struct {
    kind: u32,
    action: u32 = 0,
    zone: u32 = 0,
    source: u32 = 0,
    code: i32 = 0,
    display_id: u32 = 0,
    cycle: u32 = 0,
    flags: u32 = 0,
    rect: Rect = .{},
    latency_ns: u64 = 0,
};

pub const Stats = extern struct {
    snaps: u64 = 0,
    failures: u64 = 0,
    last_latency_ns: u64 = 0,
    p50_latency_ns: u64 = 0,
    p95_latency_ns: u64 = 0,
    max_latency_ns: u64 = 0,
    hotkeys_bound: u32 = 0,
    hotkeys_failed: u32 = 0,
    displays: u32 = 0,
    observed_pid: i32 = 0,
    event_tap_active: bool = false,
    started: bool = false,
};

/// One physical display. `bounds` is the full CG frame, `usable` excludes menu bar and Dock.
pub const Display = struct {
    id: u32,
    bounds: Rect,
    usable: Rect,
};

pub const max_displays = 16;

pub const Hotkey = struct {
    key: u32 = key_none,
    mods: u32 = 0,
};

// Carbon virtual key codes used by the default shortcut set.
const kc = struct {
    const c: u32 = 0x08;
    const d: u32 = 0x02;
    const e: u32 = 0x0E;
    const f: u32 = 0x03;
    const g: u32 = 0x05;
    const r: u32 = 0x0F;
    const t: u32 = 0x11;
    const u: u32 = 0x20;
    const i: u32 = 0x22;
    const j: u32 = 0x26;
    const k: u32 = 0x28;
    const ret: u32 = 0x24;
    const delete: u32 = 0x33;
    const left: u32 = 0x7B;
    const right: u32 = 0x7C;
    const down: u32 = 0x7D;
    const up: u32 = 0x7E;
};

/// Default shortcuts: ⌃⌥ + key (display moves add ⌘, almost-maximize adds ⇧).
pub fn defaultHotkey(a: Action) Hotkey {
    const co = Mods.control | Mods.option;
    return switch (a) {
        .none => .{},
        .left_half => .{ .key = kc.left, .mods = co },
        .right_half => .{ .key = kc.right, .mods = co },
        .top_half => .{ .key = kc.up, .mods = co },
        .bottom_half => .{ .key = kc.down, .mods = co },
        .top_left => .{ .key = kc.u, .mods = co },
        .top_right => .{ .key = kc.i, .mods = co },
        .bottom_left => .{ .key = kc.j, .mods = co },
        .bottom_right => .{ .key = kc.k, .mods = co },
        .first_third => .{ .key = kc.d, .mods = co },
        .center_third => .{ .key = kc.f, .mods = co },
        .last_third => .{ .key = kc.g, .mods = co },
        .first_two_thirds => .{ .key = kc.e, .mods = co },
        .center_two_thirds => .{ .key = kc.r, .mods = co },
        .last_two_thirds => .{ .key = kc.t, .mods = co },
        .maximize => .{ .key = kc.ret, .mods = co },
        .almost_maximize => .{ .key = kc.ret, .mods = co | Mods.shift },
        .center => .{ .key = kc.c, .mods = co },
        .restore => .{ .key = kc.delete, .mods = co },
        .next_display => .{ .key = kc.right, .mods = co | Mods.command },
        .prev_display => .{ .key = kc.left, .mods = co | Mods.command },
    };
}

/// Default drag zone map. `alternate` is used while Config.thirds_modifier is held.
pub fn defaultZoneAction(z: Zone, alternate: bool) Action {
    return switch (z) {
        .none => .none,
        .left => if (alternate) .first_third else .left_half,
        .right => if (alternate) .last_third else .right_half,
        .top => if (alternate) .top_half else .maximize,
        .top_left => .top_left,
        .top_right => .top_right,
        .bottom_left => .bottom_left,
        .bottom_right => .bottom_right,
        .bottom_left_seg => if (alternate) .first_two_thirds else .first_third,
        .bottom_center_seg => if (alternate) .center_two_thirds else .center_third,
        .bottom_right_seg => if (alternate) .last_two_thirds else .last_third,
    };
}

test "action ids round-trip" {
    var i: u32 = 0;
    while (i < Action.count) : (i += 1) {
        const a = Action.fromInt(i).?;
        try std.testing.expectEqual(a, Action.fromId(a.id()));
    }
    try std.testing.expectEqual(Action.none, Action.fromId("bogus"));
    try std.testing.expect(Action.fromInt(Action.count) == null);
}

test "default hotkeys are unique" {
    var i: u32 = 1;
    while (i < Action.count) : (i += 1) {
        const a = defaultHotkey(Action.fromInt(i).?);
        try std.testing.expect(a.key != key_none);
        var j: u32 = i + 1;
        while (j < Action.count) : (j += 1) {
            const b = defaultHotkey(Action.fromInt(j).?);
            try std.testing.expect(!(a.key == b.key and a.mods == b.mods));
        }
    }
}

test "config sanitize" {
    var c = Config{};
    c.gap_outer = -5;
    c.zone_edge = 1000;
    c.almost_maximize = std.math.nan(f64);
    const s = c.sanitized().?;
    try std.testing.expectEqual(@as(f64, 0), s.gap_outer);
    try std.testing.expectEqual(@as(f64, 40), s.zone_edge);
    try std.testing.expectEqual(@as(f64, 0.5), s.almost_maximize);
    c.abi_version = 99;
    try std.testing.expect(c.sanitized() == null);
}
