//! CoreGraphics: hand-written extern declarations + helpers.
//! Values verified against MacOSX.sdk CGEventTypes.h, CGEvent.h, CGDirectDisplay.h,
//! CGDisplayConfiguration.h and IOKit IOLLEvent.h (NX_* values).

const cf = @import("cf.zig");
const t = @import("../types.zig");

pub const Point = extern struct { x: f64, y: f64 };
pub const Size = extern struct { width: f64, height: f64 };
pub const Rect = extern struct { origin: Point, size: Size };

pub const DisplayID = u32;
pub const Error = i32;
pub const success: Error = 0;

pub const Event = opaque {};
pub const EventRef = *Event;
pub const EventTapProxy = ?*opaque {};
pub const EventMask = u64;
pub const EventFlags = u64;

/// CGEventTapLocation
pub const tap_location = struct {
    pub const hid: u32 = 0;
    pub const session: u32 = 1;
    pub const annotated_session: u32 = 2;
};
/// CGEventTapPlacement
pub const head_insert: u32 = 0;
/// CGEventTapOptions
pub const tap_option_default: u32 = 0;
pub const tap_option_listen_only: u32 = 1;

/// CGEventType (= NX_* event numbers)
pub const event_type = struct {
    pub const left_mouse_down: u32 = 1;
    pub const left_mouse_up: u32 = 2;
    pub const left_mouse_dragged: u32 = 6;
    pub const flags_changed: u32 = 12;
    pub const tap_disabled_by_timeout: u32 = 0xFFFFFFFE;
    pub const tap_disabled_by_user_input: u32 = 0xFFFFFFFF;
};

/// CGEventFlags (= NX_*MASK)
pub const flag = struct {
    pub const alpha_shift: u64 = 0x00010000;
    pub const shift: u64 = 0x00020000;
    pub const control: u64 = 0x00040000;
    pub const alternate: u64 = 0x00080000;
    pub const command: u64 = 0x00100000;
};

/// CGDisplayChangeSummaryFlags
pub const display_begin_configuration_flag: u32 = 1 << 0;

pub inline fn maskBit(ty: u32) EventMask {
    return @as(EventMask, 1) << @intCast(ty);
}

pub const EventTapCallBack = *const fn (proxy: EventTapProxy, ty: u32, event: ?EventRef, user_info: ?*anyopaque) callconv(.c) ?EventRef;
pub const DisplayReconfigurationCallBack = *const fn (display: DisplayID, flags: u32, user_info: ?*anyopaque) callconv(.c) void;

pub extern fn CGMainDisplayID() DisplayID;
pub extern fn CGGetActiveDisplayList(max_displays: u32, active_displays: [*]DisplayID, display_count: *u32) Error;
pub extern fn CGDisplayBounds(display: DisplayID) Rect;
/// Primary display of the mirror set `display` belongs to (0 = not a mirror).
pub extern fn CGDisplayMirrorsDisplay(display: DisplayID) DisplayID;
pub extern fn CGGetDisplaysWithPoint(point: Point, max_displays: u32, displays: ?[*]DisplayID, matching_display_count: *u32) Error;

pub extern fn CGEventTapCreate(tap: u32, place: u32, options: u32, events_of_interest: EventMask, callback: EventTapCallBack, user_info: ?*anyopaque) ?cf.MachPortRef;
pub extern fn CGEventTapEnable(tap: cf.MachPortRef, enable: bool) void;
pub extern fn CGEventTapIsEnabled(tap: cf.MachPortRef) bool;
pub extern fn CGEventGetLocation(event: ?EventRef) Point;
pub extern fn CGEventGetFlags(event: ?EventRef) EventFlags;

pub extern fn CGDisplayRegisterReconfigurationCallback(callback: DisplayReconfigurationCallBack, user_info: ?*anyopaque) Error;
pub extern fn CGDisplayRemoveReconfigurationCallback(callback: DisplayReconfigurationCallBack, user_info: ?*anyopaque) Error;

// ---- helpers ------------------------------------------------------------

pub fn toRect(r: Rect) t.Rect {
    return .{ .x = r.origin.x, .y = r.origin.y, .w = r.size.width, .h = r.size.height };
}

pub fn fromRect(r: t.Rect) Rect {
    return .{ .origin = .{ .x = r.x, .y = r.y }, .size = .{ .width = r.w, .height = r.h } };
}

/// Display containing a global point (0 if none).
pub fn displayAt(p: Point) DisplayID {
    var id: [1]DisplayID = .{0};
    var n: u32 = 0;
    if (CGGetDisplaysWithPoint(p, 1, &id, &n) != success or n == 0) return 0;
    return id[0];
}

/// CGEventFlags → Nokta modifier mask (types.Mods).
pub fn modsFromFlags(f: EventFlags) u32 {
    var m: u32 = 0;
    if (f & flag.shift != 0) m |= t.Mods.shift;
    if (f & flag.control != 0) m |= t.Mods.control;
    if (f & flag.alternate != 0) m |= t.Mods.option;
    if (f & flag.command != 0) m |= t.Mods.command;
    return m;
}

test "cg flags to nokta mods" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0), modsFromFlags(flag.alpha_shift));
    try std.testing.expectEqual(t.Mods.shift | t.Mods.command, modsFromFlags(flag.shift | flag.command | 0x100));
    try std.testing.expectEqual(t.Mods.all, modsFromFlags(flag.shift | flag.control | flag.alternate | flag.command));
    try std.testing.expectEqual(@as(EventMask, 0x1046), maskBit(event_type.left_mouse_down) | maskBit(event_type.left_mouse_up) |
        maskBit(event_type.left_mouse_dragged) | maskBit(event_type.flags_changed));
}

test "cg rect layout matches nk_rect" {
    const std = @import("std");
    try std.testing.expectEqual(@sizeOf(t.Rect), @sizeOf(Rect));
    const r = t.Rect{ .x = 1, .y = 2, .w = 3, .h = 4 };
    try std.testing.expectEqual(r, toRect(fromRect(r)));
}
