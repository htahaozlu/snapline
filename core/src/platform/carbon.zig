//! Carbon (HIToolbox): hot keys, the application event target and the undeclared
//! HIWindowGetAvailablePositioningBounds. Values verified against MacOSX.sdk
//! CarbonEvents.h, CarbonEventsCore.h, Events.h and HIGeometry.h.

const cf = @import("cf.zig");
const cg = @import("cg.zig");
const t = @import("../types.zig");

pub const OSStatus = i32;
pub const no_err: OSStatus = 0;
pub const event_not_handled_err: OSStatus = -9874;
pub const event_hot_key_exists_err: OSStatus = -9878;
pub const event_hot_key_invalid_err: OSStatus = -9879;

pub const EventTarget = opaque {};
pub const EventTargetRef = *EventTarget;
pub const EventHandler = opaque {};
pub const EventHandlerRef = *EventHandler;
pub const EventHandlerCall = opaque {};
pub const EventHandlerCallRef = *EventHandlerCall;
pub const EventObj = opaque {};
pub const EventRef = *EventObj;
pub const EventHotKey = opaque {};
pub const EventHotKeyRef = *EventHotKey;

pub const EventTypeSpec = extern struct {
    event_class: u32,
    event_kind: u32,
};

pub const EventHotKeyID = extern struct {
    signature: u32,
    id: u32,
};

/// EventHandlerUPP (a plain function pointer on Mach-O).
pub const EventHandlerProc = *const fn (call: EventHandlerCallRef, event: EventRef, user_data: ?*anyopaque) callconv(.c) OSStatus;

pub const event_class_keyboard: u32 = cf.fourcc("keyb");
pub const event_hot_key_pressed: u32 = 5;
pub const event_param_direct_object: u32 = cf.fourcc("----");
pub const type_event_hot_key_id: u32 = cf.fourcc("hkid");
pub const hot_key_no_options: u32 = 0;

/// Events.h modifier bits for RegisterEventHotKey.
pub const cmd_key: u32 = 1 << 8;
pub const shift_key: u32 = 1 << 9;
pub const option_key: u32 = 1 << 11;
pub const control_key: u32 = 1 << 12;

/// HICoordinateSpace
pub const hi_coord_space_72dpi_global: u32 = 1;

pub extern fn GetApplicationEventTarget() EventTargetRef;
pub extern fn InstallEventHandler(target: EventTargetRef, handler: EventHandlerProc, num_types: usize, list: [*]const EventTypeSpec, user_data: ?*anyopaque, out_ref: ?*?EventHandlerRef) OSStatus;
pub extern fn RemoveEventHandler(handler: EventHandlerRef) OSStatus;
pub extern fn RegisterEventHotKey(key_code: u32, modifiers: u32, id: EventHotKeyID, target: EventTargetRef, options: u32, out_ref: *?EventHotKeyRef) OSStatus;
pub extern fn UnregisterEventHotKey(hot_key: EventHotKeyRef) OSStatus;
pub extern fn GetEventParameter(event: EventRef, name: u32, desired_type: u32, actual_type: ?*u32, buffer_size: usize, actual_size: ?*usize, out_data: ?*anyopaque) OSStatus;

/// HIWindowGetAvailablePositioningBounds: exported by HIToolbox but not declared in modern
/// SDK headers (menu bar and Dock excluded; ~136 µs per call). Only a fallback — the shell
/// supplies AppKit's usable frames — and resolved with dlsym, not linked, so a macOS that
/// drops the export cannot stop Nokta from launching (then CGDisplayBounds is used).
const HIBoundsFn = *const fn (display: cg.DisplayID, space: u32, out_rect: *cg.Rect) callconv(.c) OSStatus;
var hi_bounds_fn: ?HIBoundsFn = null;
var hi_resolved = false;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
/// RTLD_DEFAULT on Darwin is ((void *)-2).
const rtld_default: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// null when the function is unavailable; else its OSStatus.
pub fn availablePositioningBounds(display: cg.DisplayID, out_rect: *cg.Rect) ?OSStatus {
    if (!hi_resolved) {
        hi_resolved = true;
        if (dlsym(rtld_default, "HIWindowGetAvailablePositioningBounds")) |sym| hi_bounds_fn = @ptrCast(@alignCast(sym));
    }
    const f = hi_bounds_fn orelse return null;
    return f(display, hi_coord_space_72dpi_global, out_rect);
}

/// Nokta modifier mask → Carbon modifier bits.
pub fn modsToCarbon(m: u32) u32 {
    var c: u32 = 0;
    if (m & t.Mods.command != 0) c |= cmd_key;
    if (m & t.Mods.shift != 0) c |= shift_key;
    if (m & t.Mods.option != 0) c |= option_key;
    if (m & t.Mods.control != 0) c |= control_key;
    return c;
}

test "nokta mods to carbon" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0x100), modsToCarbon(t.Mods.command));
    try std.testing.expectEqual(@as(u32, 0x200), modsToCarbon(t.Mods.shift));
    try std.testing.expectEqual(@as(u32, 0x800), modsToCarbon(t.Mods.option));
    try std.testing.expectEqual(@as(u32, 0x1000), modsToCarbon(t.Mods.control));
    try std.testing.expectEqual(@as(u32, 0x1800), modsToCarbon(t.Mods.control | t.Mods.option));
    try std.testing.expectEqual(@as(u32, 0x1B00), modsToCarbon(t.Mods.all));
}
