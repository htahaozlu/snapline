//! Compile-time ABI layout checks: must match core/test/abi_check.c (and so nokta.h).
const std = @import("std");
const t = @import("types.zig");

pub const expected = struct {
    pub const config_size = 56;
    pub const event_size = 72;
    pub const stats_size = 72;
    pub const rect_size = 32;
};

comptime {
    std.debug.assert(@sizeOf(t.Rect) == expected.rect_size);
    std.debug.assert(@sizeOf(t.Config) == expected.config_size);
    std.debug.assert(@offsetOf(t.Config, "gap_outer") == 8);
    std.debug.assert(@offsetOf(t.Config, "thirds_modifier") == 48);
    std.debug.assert(@offsetOf(t.Config, "drag_snap") == 52);
    std.debug.assert(@offsetOf(t.Config, "shared_edge_zones") == 55);
    std.debug.assert(@sizeOf(t.Event) == expected.event_size);
    std.debug.assert(@offsetOf(t.Event, "code") == 16);
    std.debug.assert(@offsetOf(t.Event, "rect") == 32);
    std.debug.assert(@offsetOf(t.Event, "latency_ns") == 64);
    std.debug.assert(@sizeOf(t.Stats) == expected.stats_size);
    std.debug.assert(@offsetOf(t.Stats, "hotkeys_bound") == 48);
    std.debug.assert(@offsetOf(t.Stats, "observed_pid") == 60);
    std.debug.assert(@offsetOf(t.Stats, "event_tap_active") == 64);
    std.debug.assert(@offsetOf(t.Stats, "started") == 65);

    // Enum and flag values (the same table is asserted against nokta.h in abi_check.c).
    std.debug.assert(@intFromEnum(t.Action.none) == 0);
    std.debug.assert(@intFromEnum(t.Action.left_half) == 1);
    std.debug.assert(@intFromEnum(t.Action.right_half) == 2);
    std.debug.assert(@intFromEnum(t.Action.top_half) == 3);
    std.debug.assert(@intFromEnum(t.Action.bottom_half) == 4);
    std.debug.assert(@intFromEnum(t.Action.top_left) == 5);
    std.debug.assert(@intFromEnum(t.Action.top_right) == 6);
    std.debug.assert(@intFromEnum(t.Action.bottom_left) == 7);
    std.debug.assert(@intFromEnum(t.Action.bottom_right) == 8);
    std.debug.assert(@intFromEnum(t.Action.first_third) == 9);
    std.debug.assert(@intFromEnum(t.Action.center_third) == 10);
    std.debug.assert(@intFromEnum(t.Action.last_third) == 11);
    std.debug.assert(@intFromEnum(t.Action.first_two_thirds) == 12);
    std.debug.assert(@intFromEnum(t.Action.center_two_thirds) == 13);
    std.debug.assert(@intFromEnum(t.Action.last_two_thirds) == 14);
    std.debug.assert(@intFromEnum(t.Action.maximize) == 15);
    std.debug.assert(@intFromEnum(t.Action.almost_maximize) == 16);
    std.debug.assert(@intFromEnum(t.Action.center) == 17);
    std.debug.assert(@intFromEnum(t.Action.restore) == 18);
    std.debug.assert(@intFromEnum(t.Action.next_display) == 19);
    std.debug.assert(@intFromEnum(t.Action.prev_display) == 20);
    std.debug.assert(@intFromEnum(t.Zone.none) == 0);
    std.debug.assert(@intFromEnum(t.Zone.left) == 1);
    std.debug.assert(@intFromEnum(t.Zone.right) == 2);
    std.debug.assert(@intFromEnum(t.Zone.top) == 3);
    std.debug.assert(@intFromEnum(t.Zone.top_left) == 4);
    std.debug.assert(@intFromEnum(t.Zone.top_right) == 5);
    std.debug.assert(@intFromEnum(t.Zone.bottom_left) == 6);
    std.debug.assert(@intFromEnum(t.Zone.bottom_right) == 7);
    std.debug.assert(@intFromEnum(t.Zone.bottom_left_seg) == 8);
    std.debug.assert(@intFromEnum(t.Zone.bottom_center_seg) == 9);
    std.debug.assert(@intFromEnum(t.Zone.bottom_right_seg) == 10);
    std.debug.assert(@intFromEnum(t.Result.ok) == 0);
    std.debug.assert(@intFromEnum(t.Result.not_trusted) == 1);
    std.debug.assert(@intFromEnum(t.Result.no_window) == 2);
    std.debug.assert(@intFromEnum(t.Result.ax) == 3);
    std.debug.assert(@intFromEnum(t.Result.excluded) == 4);
    std.debug.assert(@intFromEnum(t.Result.invalid) == 5);
    std.debug.assert(@intFromEnum(t.Result.not_movable) == 6);
    std.debug.assert(@intFromEnum(t.Result.no_memory) == 7);
    std.debug.assert(@intFromEnum(t.Result.event_tap) == 8);
    std.debug.assert(@intFromEnum(t.Result.hotkey) == 9);
    std.debug.assert(@intFromEnum(t.Result.not_started) == 10);
    std.debug.assert(@intFromEnum(t.EventKind.preview_show) == 1);
    std.debug.assert(@intFromEnum(t.EventKind.preview_hide) == 2);
    std.debug.assert(@intFromEnum(t.EventKind.snapped) == 3);
    std.debug.assert(@intFromEnum(t.EventKind.failed) == 4);
    std.debug.assert(@intFromEnum(t.EventKind.hotkey_state) == 5);
    std.debug.assert(@intFromEnum(t.Source.keyboard) == 1);
    std.debug.assert(@intFromEnum(t.Source.drag) == 2);
    std.debug.assert(@intFromEnum(t.Source.menu) == 3);
    std.debug.assert(t.Mods.shift == 1);
    std.debug.assert(t.Mods.control == 2);
    std.debug.assert(t.Mods.option == 4);
    std.debug.assert(t.Mods.command == 8);
    std.debug.assert(t.key_none == 0xFFFF);
    std.debug.assert(t.event_flag_frame_differs == 1);
    std.debug.assert(t.event_flag_size_refused == 2);
    std.debug.assert(t.event_flag_drop == 4);
}

test "abi layout" {}
