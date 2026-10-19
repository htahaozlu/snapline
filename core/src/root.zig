//! libnokta C ABI (core/include/nokta.h). Pure helpers and the platform-backed core
//! (`nk_core`: engine + Accessibility window system + Carbon hotkeys + event tap +
//! AXObserver + display watch) are exported from here.
//!
//! The platform exports reference CoreFoundation / ApplicationServices / Carbon symbols,
//! so they are only emitted outside `zig build test` (the unit-test binary links libc
//! only); they are compile-checked by the library build and link-checked by a C program.
//!
//! Threading: every entry point must be called on the main thread (see nokta.h). The
//! event callback must not call nk_core_destroy().

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const t = @import("types.zig");

pub const types = t;
pub const geometry = @import("geometry.zig");
pub const layout = @import("layout.zig");
pub const zones = @import("zones.zig");
pub const rules = @import("rules.zig");
pub const engine = @import("engine.zig");
pub const window_system = @import("window_system.zig");
pub const platform = struct {
    pub const cf = @import("platform/cf.zig");
    pub const ax = @import("platform/ax.zig");
    pub const cg = @import("platform/cg.zig");
    pub const carbon = @import("platform/carbon.zig");
    pub const dispatch = @import("platform/dispatch.zig");
    pub const ax_window_system = @import("platform/ax_window_system.zig");
    pub const hotkeys = @import("platform/hotkeys.zig");
    pub const event_tap = @import("platform/event_tap.zig");
    pub const observer = @import("platform/observer.zig");
    pub const display_watch = @import("platform/display_watch.zig");
};
comptime {
    _ = @import("abi.zig");
}

const version_string: [:0]const u8 = "0.3.0";

// ---- pure exports -------------------------------------------------------

export fn nk_abi_version() u32 {
    return t.abi_version;
}

export fn nk_version_string() [*:0]const u8 {
    return version_string.ptr;
}

export fn nk_config_default(out: ?*t.Config) void {
    if (out) |o| o.* = .{};
}

export fn nk_action_id(action: u32) ?[*:0]const u8 {
    const a = t.Action.fromInt(action) orelse return null;
    return a.id().ptr;
}

export fn nk_action_from_id(id: ?[*:0]const u8) u32 {
    const s = id orelse return 0;
    return @intFromEnum(t.Action.fromId(std.mem.span(s)));
}

export fn nk_zone_id(zone: u32) ?[*:0]const u8 {
    const z = t.Zone.fromInt(zone) orelse return null;
    return z.id().ptr;
}

export fn nk_default_hotkey(action: u32, key_code: ?*u32, mods: ?*u32) void {
    const hk = if (t.Action.fromInt(action)) |a| t.defaultHotkey(a) else t.Hotkey{};
    if (key_code) |k| k.* = hk.key;
    if (mods) |m| m.* = hk.mods;
}

export fn nk_default_zone_action(zone: u32, alternate: bool) u32 {
    const z = t.Zone.fromInt(zone) orelse return 0;
    return @intFromEnum(t.defaultZoneAction(z, alternate));
}

export fn nk_layout_frame(action: u32, window: t.Rect, usable: t.Rect, config: ?*const t.Config, out: ?*t.Rect) bool {
    const o = out orelse return false;
    const a = t.Action.fromInt(action) orelse return false;
    const raw = if (config) |c| c.* else t.Config{};
    const cfg = raw.sanitized() orelse return false;
    const r = layout.frameFor(a, window, usable, 0, layout.optionsFromConfig(cfg)) orelse return false;
    o.* = r;
    return true;
}

// ---- platform-backed core -------------------------------------------------

const Engine = engine.Engine;
const AxWindowSystem = platform.ax_window_system.AxWindowSystem;
const Hotkeys = platform.hotkeys.Hotkeys;
const EventTap = platform.event_tap.EventTap;
const Observer = platform.observer.Observer;
const DisplayWatch = platform.display_watch.DisplayWatch;
const ax = platform.ax;
const nowNs = platform.dispatch.nowNs;

pub const EventFn = *const fn (userdata: ?*anyopaque, event: *const t.Event) callconv(.c) void;

/// Highest accepted Carbon virtual key code (kVK_* values are < 0x80).
const max_key_code: u32 = 0xFF;

/// `nk_core`. Heap-allocated (c_allocator) so `engine`, `ws` and the platform parts have
/// stable addresses for the vtable ctx and the C callbacks' user-data pointers.
pub const Core = struct {
    engine: Engine,
    ws: AxWindowSystem,
    hotkeys: Hotkeys,
    tap: EventTap,
    observer: Observer,
    display_watch: DisplayWatch,
    cb: ?EventFn,
    userdata: ?*anyopaque,
    config: t.Config,
    /// action → shortcut; unbound (key_none) until the shell binds it.
    hotkey_table: [t.Action.count]t.Hotkey,
    started: bool,
    /// Hotkeys are unregistered while the frontmost app is excluded: Carbon hotkeys are
    /// global and would otherwise swallow the excluded app's own shortcuts.
    hotkeys_suspended: bool = false,

    /// Re-evaluates the exclusion suspension after frontmost/rules/start changes. Suspending
    /// is silent; resuming reports every bound shortcut (NK_EVENT_HOTKEY_STATE), because
    /// another app may have taken a combination while ours was released.
    fn updateExclusionSuspension(self: *Core) void {
        const want = self.started and self.engine.isExcludedPid(self.engine.frontmostPid());
        if (want == self.hotkeys_suspended) return;
        self.hotkeys_suspended = want;
        var i: u32 = 1;
        while (i < t.Action.count) : (i += 1) {
            const a: t.Action = @enumFromInt(i);
            if (want) {
                _ = self.hotkeys.register(a, .{}); // unregister
            } else if (self.hotkey_table[i].key != t.key_none) {
                _ = self.registerHotkey(a);
            }
        }
    }

    fn emit(self: *Core, ev: t.Event) void {
        if (self.cb) |f| f(self.userdata, &ev);
    }

    fn sinkEmit(ctx: ?*anyopaque, ev: *const t.Event) void {
        const self: *Core = @ptrCast(@alignCast(ctx orelse return));
        if (self.cb) |f| f(self.userdata, ev);
    }

    /// Registers the table entry for `a` and reports the outcome (NK_EVENT_HOTKEY_STATE).
    fn registerHotkey(self: *Core, a: t.Action) t.Result {
        const r = self.hotkeys.register(a, self.hotkey_table[@intFromEnum(a)]);
        self.emit(.{ .kind = @intFromEnum(t.EventKind.hotkey_state), .action = @intFromEnum(a), .code = @intFromEnum(r) });
        return r;
    }

    /// Event tap + AXObserver for the frontmost app (drag-to-snap inputs).
    fn startDrag(self: *Core) t.Result {
        const ok = self.tap.start();
        const pid = self.engine.frontmostPid();
        if (pid > 0) self.observer.observe(pid);
        return if (ok) .ok else .event_tap;
    }

    fn stopDrag(self: *Core) void {
        self.tap.stop();
        self.observer.stop();
    }
};

fn coreCreate(config: ?*const t.Config, cb: ?EventFn, userdata: ?*anyopaque) callconv(.c) ?*Core {
    const raw = if (config) |c| c.* else t.Config{};
    const cfg = raw.sanitized() orelse return null;
    const core = std.heap.c_allocator.create(Core) catch return null;
    const ws = AxWindowSystem.init() catch {
        std.heap.c_allocator.destroy(core);
        return null;
    };
    core.* = .{
        .engine = undefined,
        .ws = ws,
        .hotkeys = .{ .engine = &core.engine },
        .tap = .{ .engine = &core.engine },
        .observer = Observer.init(&core.engine),
        .display_watch = .{ .engine = &core.engine },
        .cb = cb,
        .userdata = userdata,
        .config = cfg,
        .hotkey_table = @splat(.{}),
        .started = false,
    };
    core.engine = Engine.init(core.ws.windowSystem(), .{ .ctx = core, .emitFn = Core.sinkEmit }, cfg);
    return core;
}

fn coreDestroy(core: ?*Core) callconv(.c) void {
    const c = core orelse return;
    coreStop(c);
    c.engine.deinit(); // releases retained windows through c.ws
    c.ws.deinit(); // cancels pending deferred calls
    std.heap.c_allocator.destroy(c);
}

/// Requires Accessibility trust. Hotkeys + display watch always; the event tap (and the
/// AXObserver) only when config.drag_snap. If the tap cannot be created the core still
/// starts (hotkeys work, stats.started = true, event_tap_active = false) and
/// NK_ERR_EVENT_TAP is returned; calling start again retries only the tap.
fn coreStart(core: ?*Core) callconv(.c) t.Result {
    const c = core orelse return .invalid;
    if (c.started) {
        // Re-arm drag input: a tap that is missing OR was created but is disabled (permission
        // toggled, system disabled it across sleep) is rebuilt from scratch.
        if (c.config.drag_snap and (!c.tap.created() or !c.tap.isActive())) {
            c.stopDrag();
            return c.startDrag();
        }
        return .ok;
    }
    if (!ax.isTrusted()) return .not_trusted;
    if (c.hotkeys.install() != .ok) return .hotkey;
    c.started = true;
    _ = c.display_watch.start();
    // Refresh and pre-warm the display cache: the first HIToolbox call costs ~80 ms
    // (measured), which would otherwise land on the first hotkey.
    c.engine.displaysChanged();
    _ = c.engine.displays();
    var i: u32 = 1;
    while (i < t.Action.count) : (i += 1) {
        if (c.hotkey_table[i].key != t.key_none) _ = c.registerHotkey(@enumFromInt(i));
    }
    c.updateExclusionSuspension();
    if (c.config.drag_snap) return c.startDrag();
    return .ok;
}

fn coreStop(core: ?*Core) callconv(.c) void {
    const c = core orelse return;
    if (!c.started) return;
    c.engine.cancelDrag();
    c.stopDrag();
    c.hotkeys.uninstall();
    c.hotkeys_suspended = false;
    c.display_watch.stop();
    c.started = false;
}

fn coreSetConfig(core: ?*Core, config: ?*const t.Config) callconv(.c) t.Result {
    const c = core orelse return .invalid;
    const in = config orelse return .invalid;
    const cfg = in.sanitized() orelse return .invalid;
    c.config = cfg;
    c.engine.setConfig(cfg);
    if (!c.started) return .ok;
    if (cfg.drag_snap) {
        if (!c.tap.created()) return c.startDrag();
    } else c.stopDrag();
    return .ok;
}

fn coreBindHotkey(core: ?*Core, action: u32, key_code: u32, mods: u32) callconv(.c) t.Result {
    const c = core orelse return .invalid;
    const a = t.Action.fromInt(action) orelse return .invalid;
    if (a == .none) return .invalid;
    if (key_code != t.key_none and key_code > max_key_code) return .invalid;
    if (mods & ~t.Mods.all != 0) return .invalid;
    const entry: t.Hotkey = if (key_code == t.key_none) .{} else .{ .key = key_code, .mods = mods };
    const old = c.hotkey_table[action];
    c.hotkey_table[action] = entry;
    if (!c.started) return .ok;
    // Suspended for an excluded frontmost app: registered when it is resumed.
    if (c.hotkeys_suspended) return .ok;
    // Unchanged and live: no unregister/register churn (preference changes rebind all).
    if (old.key == entry.key and old.mods == entry.mods and
        (entry.key == t.key_none or c.hotkeys.refs[action] != null)) return .ok;
    return c.registerHotkey(a);
}

fn coreSetZoneAction(core: ?*Core, zone: u32, alternate: bool, action: u32) callconv(.c) t.Result {
    const c = core orelse return .invalid;
    const z = t.Zone.fromInt(zone) orelse return .invalid;
    if (z == .none) return .invalid;
    const a = t.Action.fromInt(action) orelse return .invalid;
    c.engine.setZoneAction(z, alternate, a);
    return .ok;
}

fn coreSetExcluded(core: ?*Core, bundle_ids: ?[*]const ?[*:0]const u8, count: u32) callconv(.c) t.Result {
    const c = core orelse return .invalid;
    if (count == 0) {
        const r = c.engine.setExcluded(&.{});
        c.updateExclusionSuspension();
        return r;
    }
    if (count > rules.max_rules) return .invalid;
    const list = bundle_ids orelse return .invalid;
    const ids = std.heap.c_allocator.alloc([]const u8, count) catch return .no_memory;
    defer std.heap.c_allocator.free(ids);
    for (ids, 0..) |*slot, i| slot.* = std.mem.span(list[i] orelse return .invalid);
    const r = c.engine.setExcluded(ids); // the engine copies the strings
    c.updateExclusionSuspension();
    return r;
}

fn coreAppActivated(core: ?*Core, pid: i32, bundle_id: ?[*:0]const u8) callconv(.c) void {
    const c = core orelse return;
    const bid: ?[]const u8 = if (bundle_id) |b| std.mem.span(b) else null;
    c.engine.appActivated(pid, bid);
    c.updateExclusionSuspension();
    if (c.started and c.config.drag_snap) c.observer.observe(pid);
}

fn coreDisplaysChanged(core: ?*Core) callconv(.c) void {
    const c = core orelse return;
    c.engine.displaysChanged();
}

fn coreSetDisplayUsable(core: ?*Core, display_id: u32, usable: ?*const t.Rect) callconv(.c) t.Result {
    const c = core orelse return .invalid;
    if (usable) |u| {
        if (u.isEmpty() or display_id == 0) return .invalid;
        c.ws.setUsableOverride(display_id, u.*);
    } else c.ws.setUsableOverride(display_id, null);
    c.engine.displaysChanged();
    return .ok;
}

fn corePerform(core: ?*Core, action: u32) callconv(.c) t.Result {
    const t0 = nowNs();
    const c = core orelse return .invalid;
    const a = t.Action.fromInt(action) orelse return .invalid;
    if (a == .none) return .invalid;
    if (!c.started) return .not_started;
    if (!ax.isTrusted()) return .not_trusted;
    return c.engine.perform(a, 0, .menu, t0);
}

fn corePerformPid(core: ?*Core, pid: i32, action: u32) callconv(.c) t.Result {
    const t0 = nowNs();
    const c = core orelse return .invalid;
    const a = t.Action.fromInt(action) orelse return .invalid;
    if (a == .none or pid <= 0) return .invalid;
    if (!ax.isTrusted()) return .not_trusted;
    return c.engine.perform(a, pid, .menu, t0);
}

fn coreStats(core: ?*const Core, out: ?*t.Stats) callconv(.c) void {
    const o = out orelse return;
    o.* = .{};
    const c = core orelse return;
    // fillStats is const and does not refresh a dirty display cache: refresh it first.
    // The core is heap-allocated and mutable; `const` is only the C signature.
    _ = @constCast(c).engine.displays();
    c.engine.fillStats(o);
    o.hotkeys_bound = c.hotkeys.boundCount();
    o.hotkeys_failed = c.hotkeys.failedCount();
    o.observed_pid = c.observer.pid;
    o.event_tap_active = c.tap.isActive();
    o.started = c.started;
}

fn axIsTrusted(prompt: bool) callconv(.c) bool {
    if (!prompt) return ax.isTrusted();
    return ax.isTrustedPrompt();
}

fn usableFrameAt(core: ?*Core, p: t.Point, out: ?*t.Rect) callconv(.c) bool {
    const c = core orelse return false;
    const o = out orelse return false;
    const ds = c.engine.displays();
    const i = geometry.displayIndexForPoint(p, ds) orelse return false;
    o.* = ds[i].usable;
    return true;
}

comptime {
    // `-Dinert=true` (UI snapshot tool only): the same ABI with no system access.
    if (!builtin.is_test and build_options.inert) _ = @import("inert.zig");
    if (!builtin.is_test and !build_options.inert) {
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
}

test "nk_layout_frame matches layout.frameFor" {
    var c: t.Config = undefined;
    nk_config_default(&c);
    c.gap_outer = 24;
    c.gap_inner = 24;
    const usable: t.Rect = .{ .x = 0, .y = 25, .w = 1920, .h = 1055 };
    const window: t.Rect = .{ .x = 100, .y = 100, .w = 800, .h = 600 };
    var r: t.Rect = undefined;
    try std.testing.expect(nk_layout_frame(@intFromEnum(t.Action.maximize), window, usable, &c, &r));
    try std.testing.expectEqual(@as(f64, 24), r.x);
    try std.testing.expectEqual(@as(f64, 49), r.y);
    try std.testing.expect(nk_layout_frame(@intFromEnum(t.Action.center), window, usable, &c, &r));
    try std.testing.expectEqual(@as(f64, 800), r.w);
    try std.testing.expect(!nk_layout_frame(@intFromEnum(t.Action.restore), window, usable, &c, &r));
    try std.testing.expect(!nk_layout_frame(99, window, usable, &c, &r));
}

test "pure exports" {
    var c: t.Config = undefined;
    nk_config_default(&c);
    try std.testing.expectEqual(t.abi_version, c.abi_version);
    try std.testing.expectEqualStrings("left-half", std.mem.span(nk_action_id(1).?));
    try std.testing.expectEqual(@as(u32, 15), nk_action_from_id("maximize"));
    try std.testing.expect(nk_action_id(99) == null);
    var k: u32 = 0;
    var m: u32 = 0;
    nk_default_hotkey(@intFromEnum(t.Action.maximize), &k, &m);
    try std.testing.expectEqual(@as(u32, 0x24), k);
}

test "platform pure helpers" {
    // Pulls in the platform files' own tests (pure helpers only; no framework symbols).
    _ = platform.cf;
    _ = platform.cg;
    _ = platform.carbon;
    _ = platform.ax_window_system;
    _ = platform.hotkeys;
    try std.testing.expectEqual(@as(u32, 0x4E4B5441), platform.hotkeys.signature);
    // left mouse down (1) / up (2) / dragged (6); no keyboard-class flagsChanged (12).
    try std.testing.expectEqual(@as(u64, 0x46), platform.event_tap.mask);
}
