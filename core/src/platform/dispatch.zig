//! libdispatch main-queue scheduling + mach monotonic clock (libSystem).
//! Hand-written externs; dispatch_get_main_queue() is a header macro for &_dispatch_main_q.

const std = @import("std");

pub const QueueS = opaque {};
pub const Queue = *QueueS;
pub const Time = u64;
pub const time_now: Time = 0;
pub const Function = *const fn (context: ?*anyopaque) callconv(.c) void;

extern var _dispatch_main_q: QueueS;
pub extern fn dispatch_async_f(queue: Queue, context: ?*anyopaque, work: Function) void;
pub extern fn dispatch_after_f(when: Time, queue: Queue, context: ?*anyopaque, work: Function) void;
pub extern fn dispatch_time(when: Time, delta_ns: i64) Time;

pub extern fn pthread_main_np() c_int;

pub inline fn mainQueue() Queue {
    return &_dispatch_main_q;
}

/// Schedules `work(context)` on the main queue after `delay_ns` (0 = next turn).
pub fn onMain(delay_ns: u64, context: ?*anyopaque, work: Function) void {
    if (delay_ns == 0) {
        dispatch_async_f(mainQueue(), context, work);
    } else {
        const d: i64 = @intCast(@min(delay_ns, @as(u64, std.math.maxInt(i64))));
        dispatch_after_f(dispatch_time(time_now, d), mainQueue(), context, work);
    }
}

pub fn isMainThread() bool {
    return pthread_main_np() != 0;
}

// ---- monotonic clock ------------------------------------------------------

var timebase: std.c.mach_timebase_info_data = .{ .numer = 0, .denom = 0 };

/// Monotonic nanoseconds (mach_absolute_time scaled by mach_timebase_info).
pub fn nowNs() u64 {
    if (timebase.denom == 0) {
        var tb: std.c.mach_timebase_info_data = .{ .numer = 1, .denom = 1 };
        if (std.c.mach_timebase_info(&tb) != 0 or tb.denom == 0) tb = .{ .numer = 1, .denom = 1 };
        timebase = tb;
    }
    const ticks = std.c.mach_absolute_time();
    if (timebase.numer == timebase.denom) return ticks;
    return @intCast(@as(u128, ticks) * timebase.numer / timebase.denom);
}
