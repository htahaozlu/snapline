//! Inert platform exports for the UI snapshot tool (tools/snapshot, `scripts/snapshot.sh`).
//!
//! Same C ABI as the real core (nokta.h), but nothing here touches the system: no
//! Accessibility call, no Carbon hotkey, no event tap, no AXObserver, no display query, no
//! window is ever read or moved. The shell's UI can therefore be built and rendered to PNG
//! from a terminal that holds Accessibility permission without any effect on the desktop.
//! Selected with `zig build -Dinert=true`, which names the library libnokta-inert.a and makes
//! the app, bench and integrity steps fail; it also exports `nk_inert_core`, a marker that
//! `scripts/build-app.sh` refuses to find in the core it links. `zig build test` compiles and
//! tests this file (core/src/tests.zig).
//!
//! `nk_ax_is_trusted` reports the environment variable NOKTA_SNAPSHOT_TRUSTED=1 (default
//! false) so both permission states can be rendered; `prompt` is ignored.

const std = @import("std");
const t = @import("types.zig");

const EventFn = *const fn (userdata: ?*anyopaque, event: *const t.Event) callconv(.c) void;

/// Hotkey bookkeeping is emulated so the shell's tests can see what a live app would register:
/// the same table and dedup rules as `nk_core_bind_hotkey` in root.zig, and Carbon's refusal of a
/// combination that is already registered (by another action of this process, or — via
/// `nk_inert_set_taken` — by "another app"). Nothing is registered for real.
const Inert = struct {
    config: t.Config,
    cb: ?EventFn = null,
    userdata: ?*anyopaque = null,
    started: bool = false,
    /// action → shortcut, kept across stop/start like the real core's table.
    table: [t.Action.count]t.Hotkey = @splat(.{}),
    /// Emulated live Carbon registrations.
    live: [t.Action.count]bool = @splat(false),
    failed: [t.Action.count]bool = @splat(false),
    counters: Counters = .{},
};

/// For the shell's tests (`nk_inert_counters`). `registered` − `unregistered` is the number of live
/// registrations; their deltas around an operation show how often each shortcut was (re)registered.
pub const Counters = extern struct {
    binds: u32 = 0,
    registered: u32 = 0,
    unregistered: u32 = 0,
    refused: u32 = 0,
};

/// Combinations "another app" holds (tests): registering them fails like eventHotKeyExistsErr.
var taken: [16]t.Hotkey = @splat(.{});

fn isTaken(hk: t.Hotkey) bool {
    for (taken) |h| {
        if (h.key != t.key_none and h.key == hk.key and h.mods == hk.mods) return true;
    }
    return false;
}

/// Test hook (not in nokta.h): marks `key_code`+`mods` as held by another app, or frees it.
fn setTaken(key_code: u32, mods: u32, on: bool) callconv(.c) bool {
    const hk: t.Hotkey = .{ .key = key_code, .mods = mods };
    for (&taken) |*h| {
        if (h.key == hk.key and h.mods == hk.mods) {
            if (!on) h.* = .{};
            return true;
        }
    }
    if (!on) return true;
    for (&taken) |*h| {
        if (h.key == t.key_none) {
            h.* = hk;
            return true;
        }
    }
    return false;
}

fn counters(core: ?*const Inert, out: ?*Counters) callconv(.c) void {
    const o = out orelse return;
    o.* = if (core) |c| c.counters else .{};
}

fn emit(c: *Inert, ev: t.Event) void {
    if (c.cb) |f| f(c.userdata, &ev);
}

fn unregister(c: *Inert, i: usize) void {
    if (!c.live[i]) return;
    c.live[i] = false;
    c.counters.unregistered += 1;
}

/// Hotkeys.register + Core.registerHotkey of the real core: unregister, try, report.
fn registerAndReport(c: *Inert, i: usize) t.Result {
    unregister(c, i);
    c.failed[i] = false;
    const hk = c.table[i];
    var r: t.Result = .ok;
    if (hk.key != t.key_none) {
        var clash = isTaken(hk);
        for (0..t.Action.count) |j| {
            if (j != i and c.live[j] and c.table[j].key == hk.key and c.table[j].mods == hk.mods) clash = true;
        }
        if (clash) {
            c.failed[i] = true;
            c.counters.refused += 1;
            r = .hotkey;
        } else {
            c.live[i] = true;
            c.counters.registered += 1;
        }
    }
    emit(c, .{ .kind = @intFromEnum(t.EventKind.hotkey_state), .action = @intCast(i), .code = @intFromEnum(r) });
    return r;
}

fn coreCreate(config: ?*const t.Config, cb: ?EventFn, userdata: ?*anyopaque) callconv(.c) ?*Inert {
    const raw = if (config) |c| c.* else t.Config{};
    const cfg = raw.sanitized() orelse return null;
    const core = std.heap.c_allocator.create(Inert) catch return null;
    core.* = .{ .config = cfg, .cb = cb, .userdata = userdata };
    return core;
}

fn coreDestroy(core: ?*Inert) callconv(.c) void {
    if (core) |c| std.heap.c_allocator.destroy(c);
}

fn coreStart(core: ?*Inert) callconv(.c) t.Result {
    const c = core orelse return .invalid;
    if (c.started) return .ok;
    c.started = true;
    for (1..t.Action.count) |i| {
        if (c.table[i].key != t.key_none) _ = registerAndReport(c, i);
    }
    return .ok;
}

fn coreStop(core: ?*Inert) callconv(.c) void {
    const c = core orelse return;
    if (!c.started) return;
    for (0..t.Action.count) |i| unregister(c, i);
    c.failed = @splat(false);
    c.started = false;
}

fn coreSetConfig(core: ?*Inert, config: ?*const t.Config) callconv(.c) t.Result {
    const c = core orelse return .invalid;
    const raw = config orelse return .invalid;
    c.config = raw.sanitized() orelse return .invalid;
    return .ok;
}

/// Same validation, table and dedup rules as root.zig's coreBindHotkey.
fn coreBindHotkey(core: ?*Inert, action: u32, key_code: u32, mods: u32) callconv(.c) t.Result {
    const c = core orelse return .invalid;
    const a = t.Action.fromInt(action) orelse return .invalid;
    if (a == .none) return .invalid;
    if (key_code != t.key_none and key_code > 0xFF) return .invalid;
    if (mods & ~t.Mods.all != 0) return .invalid;
    c.counters.binds += 1;
    const entry: t.Hotkey = if (key_code == t.key_none) .{} else .{ .key = key_code, .mods = mods };
    const old = c.table[action];
    c.table[action] = entry;
    if (!c.started) return .ok;
    if (old.key == entry.key and old.mods == entry.mods and (entry.key == t.key_none or c.live[action])) return .ok;
    return registerAndReport(c, action);
}

fn coreSetZoneAction(core: ?*Inert, zone: u32, alternate: bool, action: u32) callconv(.c) t.Result {
    _ = zone;
    _ = alternate;
    _ = action;
    return if (core == null) .invalid else .ok;
}

fn coreSetExcluded(core: ?*Inert, bundle_ids: ?[*]const ?[*:0]const u8, count: u32) callconv(.c) t.Result {
    _ = bundle_ids;
    _ = count;
    return if (core == null) .invalid else .ok;
}

fn coreAppActivated(core: ?*Inert, pid: i32, bundle_id: ?[*:0]const u8) callconv(.c) void {
    _ = core;
    _ = pid;
    _ = bundle_id;
}

fn coreDisplaysChanged(core: ?*Inert) callconv(.c) void {
    _ = core;
}

fn coreSetDisplayUsable(core: ?*Inert, display_id: u32, usable: ?*const t.Rect) callconv(.c) t.Result {
    _ = display_id;
    _ = usable;
    return if (core == null) .invalid else .ok;
}

/// Never acts: there is no window system behind the inert core.
fn corePerform(core: ?*Inert, action: u32) callconv(.c) t.Result {
    _ = core;
    _ = action;
    return .no_window;
}

fn corePerformPid(core: ?*Inert, pid: i32, action: u32) callconv(.c) t.Result {
    _ = core;
    _ = pid;
    _ = action;
    return .no_window;
}

fn coreStats(core: ?*const Inert, out: ?*t.Stats) callconv(.c) void {
    const o = out orelse return;
    o.* = .{};
    const c = core orelse return;
    o.started = c.started;
    for (c.live) |l| o.hotkeys_bound += @intFromBool(l);
    for (c.failed) |f| o.hotkeys_failed += @intFromBool(f);
}

fn axIsTrusted(prompt: bool) callconv(.c) bool {
    _ = prompt;
    const v = std.c.getenv("NOKTA_SNAPSHOT_TRUSTED") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "1");
}

fn usableFrameAt(core: ?*Inert, p: t.Point, out: ?*t.Rect) callconv(.c) bool {
    _ = core;
    _ = p;
    _ = out;
    return false;
}

/// Marker only this library exports (not in nokta.h): a link of the app against it is refused.
fn inertMarker() callconv(.c) bool {
    return true;
}

comptime {
    @export(&inertMarker, .{ .name = "nk_inert_core" });
    @export(&setTaken, .{ .name = "nk_inert_set_taken" });
    @export(&counters, .{ .name = "nk_inert_counters" });
    @export(&coreCreate, .{ .name = "nk_core_create" });
    @export(&coreDestroy, .{ .name = "nk_core_destroy" });
    @export(&coreStart, .{ .name = "nk_core_start" });
    @export(&coreStop, .{ .name = "nk_core_stop" });
    @export(&coreSetConfig, .{ .name = "nk_core_set_config" });
    @export(&coreBindHotkey, .{ .name = "nk_core_bind_hotkey" });
    @export(&coreSetZoneAction, .{ .name = "nk_core_set_zone_action" });
    @export(&coreSetExcluded, .{ .name = "nk_core_set_excluded" });
    @export(&coreAppActivated, .{ .name = "nk_core_app_activated" });
    @export(&coreDisplaysChanged, .{ .name = "nk_core_displays_changed" });
    @export(&coreSetDisplayUsable, .{ .name = "nk_core_set_display_usable" });
    @export(&corePerform, .{ .name = "nk_core_perform" });
    @export(&corePerformPid, .{ .name = "nk_core_perform_pid" });
    @export(&coreStats, .{ .name = "nk_core_stats" });
    @export(&axIsTrusted, .{ .name = "nk_ax_is_trusted" });
    @export(&usableFrameAt, .{ .name = "nk_usable_frame_at" });
}

const testing = std.testing;

test "inert core keeps the ABI and never acts" {
    var cfg = t.Config{};
    const core = coreCreate(&cfg, null, null) orelse return error.TestUnexpectedResult;
    defer coreDestroy(core);
    try testing.expectEqual(t.Result.ok, coreStart(core));
    try testing.expectEqual(t.Result.ok, coreSetConfig(core, &cfg));
    try testing.expectEqual(t.Result.ok, coreBindHotkey(core, 1, 0x7B, 0));
    try testing.expectEqual(t.Result.ok, coreSetZoneAction(core, 1, false, 1));
    try testing.expectEqual(t.Result.ok, coreSetExcluded(core, null, 0));
    try testing.expectEqual(t.Result.ok, coreSetDisplayUsable(core, 1, null));
    coreAppActivated(core, 1, null);
    coreDisplaysChanged(core);
    var s: t.Stats = .{};
    coreStats(core, &s);
    try testing.expect(s.started);
    try testing.expectEqual(@as(u32, 1), s.hotkeys_bound); // emulated, never registered
    // No window system behind it: nothing is read or moved.
    try testing.expectEqual(t.Result.no_window, corePerform(core, 1));
    try testing.expectEqual(t.Result.no_window, corePerformPid(core, 1, 1));
    var r: t.Rect = .{};
    try testing.expect(!usableFrameAt(core, .{}, &r));
    // `prompt` never reaches the system: the answer is the environment's either way.
    try testing.expectEqual(axIsTrusted(false), axIsTrusted(true));
    coreStop(core);
    coreStats(core, &s);
    try testing.expect(!s.started);
    try testing.expectEqual(t.Result.invalid, coreStart(null));
    try testing.expect(inertMarker());
}

const Recorder = struct {
    events: [64]t.Event = undefined,
    n: usize = 0,
    fn cb(userdata: ?*anyopaque, ev: *const t.Event) callconv(.c) void {
        const self: *Recorder = @ptrCast(@alignCast(userdata.?));
        if (self.n < self.events.len) self.events[self.n] = ev.*;
        self.n += 1;
    }
};

test "inert hotkey emulation: table across stop/start, dedup, Carbon-style refusals" {
    var cfg = t.Config{};
    var rec: Recorder = .{};
    const core = coreCreate(&cfg, Recorder.cb, &rec) orelse return error.TestUnexpectedResult;
    defer coreDestroy(core);
    const ctrl_opt = t.Mods.control | t.Mods.option;
    // Not started: the table is kept, nothing registers, no event.
    try testing.expectEqual(t.Result.ok, coreBindHotkey(core, 1, 0x7B, ctrl_opt));
    try testing.expectEqual(t.Result.ok, coreBindHotkey(core, 2, 0x7C, ctrl_opt));
    try testing.expectEqual(@as(usize, 0), rec.n);
    try testing.expectEqual(t.Result.ok, coreStart(core));
    var k: Counters = .{};
    counters(core, &k);
    try testing.expectEqual(@as(u32, 2), k.registered);
    try testing.expectEqual(@as(usize, 2), rec.n); // one HOTKEY_STATE per registration
    // Unchanged and live: no churn, no event.
    try testing.expectEqual(t.Result.ok, coreBindHotkey(core, 1, 0x7B, ctrl_opt));
    counters(core, &k);
    try testing.expectEqual(@as(u32, 2), k.registered);
    try testing.expectEqual(@as(usize, 2), rec.n);
    // Another action asking for a live combination is refused (Carbon: eventHotKeyExistsErr).
    try testing.expectEqual(t.Result.hotkey, coreBindHotkey(core, 3, 0x7B, ctrl_opt));
    try testing.expectEqual(@as(i32, @intFromEnum(t.Result.hotkey)), rec.events[2].code);
    // "Another app" holds one.
    try testing.expect(setTaken(0x20, ctrl_opt, true));
    try testing.expectEqual(t.Result.hotkey, coreBindHotkey(core, 4, 0x20, ctrl_opt));
    try testing.expect(setTaken(0x20, ctrl_opt, false));
    var s: t.Stats = .{};
    coreStats(core, &s);
    try testing.expectEqual(@as(u32, 2), s.hotkeys_bound);
    try testing.expectEqual(@as(u32, 2), s.hotkeys_failed);
    // Stop unregisters everything once; start registers the table again (the failures retry).
    coreStop(core);
    counters(core, &k);
    try testing.expectEqual(k.registered, k.unregistered);
    try testing.expectEqual(t.Result.ok, coreStart(core));
    coreStats(core, &s);
    try testing.expectEqual(@as(u32, 3), s.hotkeys_bound); // 1, 2 and 4 (no longer taken)
    try testing.expectEqual(@as(u32, 1), s.hotkeys_failed); // 3 still clashes with 1
    counters(core, &k);
    try testing.expectEqual(k.registered - k.unregistered, s.hotkeys_bound);
    try testing.expectEqual(t.Result.invalid, coreBindHotkey(core, 0, 0x7B, 0));
    try testing.expectEqual(t.Result.invalid, coreBindHotkey(core, 1, 0x100, 0));
}
