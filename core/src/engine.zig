//! Engine: the platform-independent state machine. Owns per-window memory (pre-snap
//! frame, last action, size cycle), the drag pipeline and latency statistics. Talks to
//! the OS only through `WindowSystem` and reports through `Sink`.
//!
//! No heap allocation: every table has a fixed capacity.
//!
//! Address stability: `init` returns the engine by value and keeps no self-pointers, so
//! it may be moved freely *before use*. `mouseUp` hands `self` to `WindowSystem.deferCall`,
//! so the engine must not be moved or freed while a deferred apply is queued (from a
//! mouseUp that showed a preview until the next run-loop turn). In production the engine
//! lives inside the heap-allocated nk_core and never moves. `deinit` drops a queued apply,
//! so a callback that still fires afterwards (engine memory still valid) is a no-op.
//!
//! Behaviour contract (see docs/SPEC.md §Engine):
//!
//! perform(action, pid, source, t0):
//!   1. pid == 0 → frontmost pid from appActivated(); none → failed(no_window).
//!   2. frontmost/pid bundle excluded → failed(excluded).
//!   3. w = focusedWindow(pid) else failed(why: no_window | not_trusted | ax);
//!      cur = frame(w) else failed(ax).
//!   4. displays (cached); di = displayIndexForRect(cur).
//!   5. restore      → memory.pre_snap else failed(invalid); entry cleared after apply.
//!      next/prev    → adjacentDisplay; if the window still sits at its last target and the
//!                     last action is a frame action, re-apply that action (same cycle) on
//!                     the new display, else geometry.mapBetween(); single display → failed(invalid).
//!      frame action → cycle = layout.nextCycle(...) using "still at last target" =
//!                     approxEqual(cur, entry.last_target, tol) with tol = max(16, 2% of usable.w);
//!                     target = layout.frameFor(...).
//!   6. setFrame(w, target); failure → stats.failures++, failed(code).
//!   7. memory.record: pre_snap keeps the ORIGINAL pre-snap frame across a chain of snaps
//!      (if the window was still at its last target), otherwise pre_snap = cur.
//!   8. latency = nowNs() - t0 (taken right after the last setter) → ring buffer (128); then
//!      one frame read-back (appliedFrame): equal to the pre-set frame → stale read of an app
//!      that applies AX changes asynchronously, trust the target; larger than the tile →
//!      minimum size: one position write hugs the tile's edge, flags |= frame_differs; size
//!      refused → same alignment, flags |= size_refused; slightly smaller (size increments) →
//!      actual frame, no flag. Memory stores the resulting rect → snapped event. Always
//!      release `w`.
//!
//! Drag pipeline (fed by the listen-only event tap + AXObserver):
//!   mouseDown(p,t)   → state = pressed{p_down, t}.
//!   windowMoved(w)   → (borrowed handle) if pressed/candidate, no programmatic setFrame
//!                      < 150 ms ago (our own echoes) and w's frame contains the pressed point
//!                      or the cursor (the app's other windows, sheets and panels are not
//!                      this gesture) → observer candidate{w, frame0}. Once the cursor has
//!                      moved > 4 pt (a click, title-bar double-click or jitter never does),
//!                      a check runs 30 ms later: a Resized notification meanwhile, or a size
//!                      that changed since frame0, is a left/top-edge resize → ignored; else
//!                      begin drag. Begin drag: info(w) once; non-standard or excluded →
//!                      ignored state. drag_start_frame = frame(w) shifted back by the cursor
//!                      delta.
//!                      If snap_back and memory says w was snapped and its size still equals
//!                      the last target size → setFrame to pre_snap size, keeping the cursor at
//!                      the same relative x inside the window; pre_snap cleared.
//!   mouseDragged(p,t)→ pressed and no observer event yet and |p - p_down| > 4 → fallback
//!                      (skipped while an AXObserver is attached to the frontmost app and ⌘
//!                      is not held — its notifications cover window drags, and a hit-test
//!                      would cost the app AX work on every text selection): windowAt(p_down)
//!                      → candidate{w, frame0}; then at most every 30 ms (max 10 checks)
//!                      compare frame(w) with frame0; moved with the same size → begin drag.
//!                      dragging → zones.hitTest(p) → map (alternate if the
//!                      thirds modifier is fully held) → preview frame on that display's
//!                      usable area; emit preview_show only when (zone, action, display)
//!                      changes, preview_hide when leaving all zones.
//!   flagsChanged(m)  → store; while dragging re-evaluate the last point.
//!   mouseUp(p,t)     → dragging with an active preview → preview_hide (flags |= drop), then
//!                      deferCall(0) apply: one frame read (appliedFrame's reference),
//!                      setFrame, appliedFrame, memory.record(pre_snap =
//!                      drag_start_frame, or the remembered pre_snap when the drag started
//!                      from the window's last snapped frame), snapped event (source drag,
//!                      latency from mouseUp). Every other preview_hide is a cancel (no
//!                      flag). Always back to idle and release retained handles.
//!
//! Memory: fixed 32-entry LRU of retained windows; lookups via WindowSystem.same.
//!
//! Implementation notes (interpretations of the contract):
//!   - stats.failures counts failed frame changes only (setFrame errors, including the
//!     snap-back resize and the deferred drag apply); no_window/excluded/invalid do not count.
//!   - No displays at all → failed(invalid); an empty list is not cached (asked again next use).
//!   - Display moves without a re-applicable frame action are remembered as the move itself
//!     (last_action = next/prev_display), so `restore` undoes them.
//!   - Snap-back drops the whole memory entry and uses the pre-snap frame as the drag start
//!     frame (it is the window's real size from then on; `center` and the next restore use it).
//!   - Fallback "moved" = origin changed by ≥ 1 pt with the size unchanged (edge resizes are
//!     not drags). An echo-suppressed fallback movement re-bases frame0.
//!   - Zones mapped to a non-frame action (none/restore/display moves) act as disabled.
//!   - The pid→bundle cache evicts the least recently activated pid; ids longer than
//!     rules.max_id_len are stored as unknown (no rule can match them).

const std = @import("std");
const t = @import("types.zig");
const geo = @import("geometry.zig");
const layout = @import("layout.zig");
const zones = @import("zones.zig");
const rules = @import("rules.zig");
const ws_mod = @import("window_system.zig");

pub const WindowSystem = ws_mod.WindowSystem;
pub const Window = ws_mod.Window;
pub const Sink = ws_mod.Sink;

pub const latency_samples = 128;
pub const memory_capacity = 32;

const bundle_cache_capacity = 32;
const max_bundle_len = rules.max_id_len;

const echo_window_ns: u64 = 150 * 1_000_000;
const drag_threshold: f64 = 4;
const fallback_interval_ns: u64 = 30 * 1_000_000;
const fallback_max_checks: u32 = 10;
/// The cursor may sit just outside a window's frame while grabbing it (resize handles).
const grab_slop: f64 = 8;
/// An observer-reported move becomes a drag only if the window's size is unchanged this long
/// after it (a left/top-edge resize also moves the origin, and its Resized notification
/// arrives within this window).
const confirm_delay_ns: u64 = 30 * 1_000_000;

/// Per-window memory slot. `w == null` marks a free slot; otherwise `w` is retained.
const MemEntry = struct {
    w: ?Window = null,
    pre_snap: t.Rect = .{},
    /// The frame the snap ended with (read back) …
    last_target: t.Rect = .{},
    /// … and the frame it asked for: an app that applies AX changes asynchronously may have
    /// reported the old size, then applied this one (either counts as "still at last target").
    last_requested: t.Rect = .{},
    last_action: t.Action = .none,
    last_cycle: u32 = 0,
    stamp: u64 = 0,

    /// The window still sits where the last snap put it (or asked to put it).
    fn holds(e: MemEntry, r: t.Rect, tol: f64) bool {
        return geo.approxEqual(r, e.last_target, tol) or geo.approxEqual(r, e.last_requested, tol);
    }
};

/// pid → bundle id slot. `pid == 0` marks a free slot.
const BundleEntry = struct {
    pid: i32 = 0,
    has_id: bool = false,
    len: u16 = 0,
    id: [max_bundle_len]u8 = undefined,
    stamp: u64 = 0,
};

const DragPhase = enum { idle, pressed, candidate, dragging, ignored };

const Preview = struct {
    zone: t.Zone,
    action: t.Action,
    display_id: u32,
    rect: t.Rect,
};

const Drag = struct {
    phase: DragPhase = .idle,
    p_down: t.Point = .{},
    t_down: u64 = 0,
    last_p: t.Point = .{},
    /// Retained in `candidate` and `dragging`, null otherwise.
    w: ?Window = null,
    /// Candidate bookkeeping: the window's frame when it became the candidate and the cursor
    /// at that moment (the press-time frame is estimated from these two).
    frame0: t.Rect = .{},
    p0: t.Point = .{},
    last_check_ns: u64 = 0,
    checks: u32 = 0,
    /// windowAt() fallback already attempted (or skipped) for this press.
    fallback_done: bool = false,
    /// The cursor has been more than `drag_threshold` away from p_down (sticky).
    past_threshold: bool = false,
    /// The candidate was reported by the observer (a window of this press really moved).
    hinted: bool = false,
    /// A deferred size-stability check is queued, due at `confirm_due` (nowNs).
    confirm_pending: bool = false,
    confirm_due: u64 = 0,
    /// Frame of the window when the drag began (cursor delta removed).
    start_frame: t.Rect = .{},
    preview: ?Preview = null,
};

/// Drag drop waiting for its deferred apply. `w` is retained.
const PendingApply = struct {
    w: Window,
    rect: t.Rect,
    action: t.Action,
    zone: t.Zone,
    display_id: u32,
    pre_snap: t.Rect,
    t_up: u64,
};

const Plan = struct {
    target: t.Rect,
    display: usize,
    cycle: u32,
    /// Action stored in memory (the re-applied frame action for display moves).
    remembered: t.Action = .none,
    forget: bool = false,
};

pub const Engine = struct {
    ws: WindowSystem,
    sink: Sink,
    config: t.Config,
    zone_map: zones.ZoneMap,
    rules: rules.Rules,

    // ---- private state ----------------------------------------------------
    display_cache: [t.max_displays]t.Display = undefined,
    display_count: usize = 0,
    displays_dirty: bool = true,

    frontmost: i32 = 0,
    bundles: [bundle_cache_capacity]BundleEntry = @splat(.{}),
    bundle_clock: u64 = 0,

    memory: [memory_capacity]MemEntry = @splat(.{}),
    memory_clock: u64 = 0,

    latencies: [latency_samples]u64 = @splat(0),
    latency_head: usize = 0,
    latency_count: usize = 0,
    last_latency_ns: u64 = 0,
    snaps: u64 = 0,
    failures: u64 = 0,

    /// nowNs() right after our most recent setFrame (echo suppression).
    last_set_frame_ns: ?u64 = null,
    mods: u32 = 0,
    /// pid the platform AXObserver is attached to (0 = none); set by the observer.
    observed_pid: i32 = 0,
    drag: Drag = .{},
    pending: ?PendingApply = null,

    pub fn init(ws: WindowSystem, sink: Sink, config: t.Config) Engine {
        return .{
            .ws = ws,
            .sink = sink,
            .config = config,
            .zone_map = zones.ZoneMap.defaults(),
            .rules = .{},
        };
    }

    /// Releases every retained window handle.
    pub fn deinit(self: *Engine) void {
        if (self.pending) |pa| self.ws.release(pa.w);
        self.pending = null;
        self.resetDrag(false);
        for (0..memory_capacity) |i| self.forget(i);
    }

    /// `config` must already be sanitized (Config.sanitized()).
    pub fn setConfig(self: *Engine, config: t.Config) void {
        self.config = config;
        if (!config.drag_snap) self.resetDrag(true);
    }

    pub fn setZoneAction(self: *Engine, zone: t.Zone, alternate: bool, action: t.Action) void {
        self.zone_map.set(zone, alternate, action);
    }

    pub fn setExcluded(self: *Engine, bundle_ids: []const []const u8) t.Result {
        self.rules.set(bundle_ids) catch return .invalid;
        return .ok;
    }

    /// Frontmost app changed. bundle_id is copied (pid→bundle cache of 32 entries).
    pub fn appActivated(self: *Engine, pid: i32, bundle_id: ?[]const u8) void {
        if (pid <= 0) {
            self.frontmost = 0;
            return;
        }
        self.frontmost = pid;
        // The press activated another app: let the fallback reconsider (the observer may not
        // attach to the new app; the frontmost/observed check runs on the next drag event).
        if (self.drag.phase == .pressed and self.drag.w == null) self.drag.fallback_done = false;

        var slot: usize = 0;
        var found = false;
        for (self.bundles, 0..) |e, i| {
            if (e.pid == pid) {
                slot = i;
                found = true;
                break;
            }
        }
        if (!found) {
            // Free slot, else the least recently activated pid.
            var oldest: u64 = std.math.maxInt(u64);
            for (self.bundles, 0..) |e, i| {
                if (e.pid == 0) {
                    slot = i;
                    break;
                }
                if (e.stamp < oldest) {
                    oldest = e.stamp;
                    slot = i;
                }
            }
        }

        self.bundle_clock += 1;
        const e = &self.bundles[slot];
        e.pid = pid;
        e.stamp = self.bundle_clock;
        e.has_id = false;
        e.len = 0;
        if (bundle_id) |id| {
            if (id.len > 0 and id.len <= max_bundle_len) {
                @memcpy(e.id[0..id.len], id);
                e.len = @intCast(id.len);
                e.has_id = true;
            }
        }
    }

    pub fn frontmostPid(self: *const Engine) i32 {
        return self.frontmost;
    }

    /// Invalidates the cached display list (refetched lazily on next use).
    pub fn displaysChanged(self: *Engine) void {
        self.displays_dirty = true;
    }

    /// Cached displays (refreshes if dirty).
    pub fn displays(self: *Engine) []const t.Display {
        if (self.displays_dirty) {
            const n = self.ws.displays(self.display_cache[0..]);
            self.display_count = @min(n, t.max_displays);
            // Zero displays is a transient state (sleep, reconfiguration): ask again next time.
            self.displays_dirty = self.display_count == 0;
        }
        return self.display_cache[0..self.display_count];
    }

    /// Applies `action` to the focused window of `pid` (0 = frontmost). `t0_ns` is the
    /// trigger timestamp from WindowSystem.nowNs().
    pub fn perform(self: *Engine, action: t.Action, pid: i32, source: t.Source, t0_ns: u64) t.Result {
        if (action == .none) return self.fail(action, .none, source, .invalid, 0, .{});

        const target_pid = if (pid == 0) self.frontmost else pid;
        if (target_pid <= 0) return self.fail(action, .none, source, .no_window, 0, .{});
        if (self.rules.isExcluded(self.bundleFor(target_pid)))
            return self.fail(action, .none, source, .excluded, 0, .{});

        var why: t.Result = .no_window;
        const w = self.ws.focusedWindow(target_pid, &why) orelse
            return self.fail(action, .none, source, why, 0, .{});
        defer self.ws.release(w);

        const cur = self.ws.frame(w) orelse return self.fail(action, .none, source, .ax, 0, .{});
        const ds = self.displays();
        const di = geo.displayIndexForRect(cur, ds) orelse
            return self.fail(action, .none, source, .invalid, 0, cur);

        const mem_idx = self.findMemory(w);
        const entry: ?*const MemEntry = if (mem_idx) |i| &self.memory[i] else null;
        const still = if (entry) |e| e.holds(cur, tolerance(ds[di].usable)) else false;
        const opts = layout.optionsFromConfig(self.config);

        const plan: Plan = switch (action) {
            .none => unreachable,
            .restore => blk: {
                const e = entry orelse return self.fail(action, .none, source, .invalid, ds[di].id, cur);
                const ri = geo.displayIndexForRect(e.pre_snap, ds) orelse di;
                // The display it came from may be gone or rearranged: keep the size, but
                // never restore a window to a spot that is mostly off every screen.
                const visible = geo.area(geo.intersection(e.pre_snap, ds[ri].bounds));
                const target = if (visible >= 0.5 * geo.area(e.pre_snap)) e.pre_snap else geo.integral(geo.clampInto(e.pre_snap, ds[ri].usable));
                break :blk .{ .target = target, .display = ri, .cycle = 0, .forget = true };
            },
            .next_display, .prev_display => blk: {
                if (ds.len <= 1) return self.fail(action, .none, source, .invalid, ds[di].id, cur);
                const dir: geo.Direction = if (action == .next_display) .next else .prev;
                const ni = geo.adjacentDisplay(di, ds, dir);
                if (entry) |e| {
                    if (still and layout.isFrameAction(e.last_action)) {
                        if (layout.frameFor(e.last_action, cur, ds[ni].usable, e.last_cycle, opts)) |r| {
                            break :blk .{ .target = r, .display = ni, .cycle = e.last_cycle, .remembered = e.last_action };
                        }
                    }
                }
                const r = geo.mapBetween(cur, ds[di].usable, ds[ni].usable);
                break :blk .{ .target = r, .display = ni, .cycle = 0, .remembered = action };
            },
            else => blk: {
                const last_action: t.Action = if (entry) |e| e.last_action else .none;
                const last_cycle: u32 = if (entry) |e| e.last_cycle else 0;
                const cycle = layout.nextCycle(action, last_action, last_cycle, still, self.config.cycle_sizes);
                const r = layout.frameFor(action, cur, ds[di].usable, cycle, opts) orelse
                    return self.fail(action, .none, source, .invalid, ds[di].id, cur);
                break :blk .{ .target = r, .display = di, .cycle = cycle, .remembered = action };
            },
        };

        const display_id = ds[plan.display].id;
        const set = self.ws.setFrame(w, plan.target);
        const now = self.ws.nowNs();
        self.last_set_frame_ns = now;
        if (set.rc != .ok) {
            self.failures += 1;
            return self.fail(action, .none, source, set.rc, display_id, plan.target);
        }

        // Latency ends when the last setter returned; the read-back below is only for honest
        // feedback (min-size windows) and is not part of the metric.
        const latency = now -| t0_ns;
        const usable = ds[plan.display].usable;
        const applied = self.appliedFrame(w, plan.target, usable, cur, 2, set.size_refused);

        if (plan.forget) {
            if (mem_idx) |i| self.forget(i);
        } else {
            const pre = if (entry) |e| (if (still) e.pre_snap else cur) else cur;
            self.remember(mem_idx, w, pre, applied.rect, plan.target, plan.remembered, plan.cycle);
        }

        self.recordLatency(latency);
        self.snaps += 1;
        self.sink.emit(.{
            .kind = @backingInt(t.EventKind.snapped),
            .action = @backingInt(action),
            .source = @backingInt(source),
            .display_id = display_id,
            .cycle = plan.cycle,
            .flags = applied.flags,
            .rect = applied.rect,
            .latency_ns = latency,
        });
        return .ok;
    }

    pub fn mouseDown(self: *Engine, p: t.Point, t_ns: u64) void {
        // A press while a drag is still tracked means we missed its mouseUp.
        self.resetDrag(true);
        if (!self.config.drag_snap) return;
        self.drag = .{ .phase = .pressed, .p_down = p, .t_down = t_ns, .last_p = p };
    }

    pub fn mouseDragged(self: *Engine, p: t.Point, t_ns: u64) void {
        switch (self.drag.phase) {
            .idle, .ignored => {},
            .pressed => {
                self.drag.last_p = p;
                if (self.drag.fallback_done) return;
                if (!self.pastThreshold()) return;
                self.drag.fallback_done = true;
                // The observer reports moves of the frontmost app's windows; the hit-test
                // fallback would cost that app AX work on every text selection or scroll.
                // ⌘-dragging a background window does not activate its app: fall back then.
                if (self.observed_pid > 0 and self.observed_pid == self.frontmost and
                    self.mods & t.Mods.command == 0) return;
                const w = self.ws.windowAt(self.drag.p_down) orelse return;
                const f0 = self.ws.frame(w) orelse {
                    self.ws.release(w);
                    return;
                };
                self.watch(w, f0, t_ns);
            },
            .candidate => {
                self.drag.last_p = p;
                // An observer-made candidate waits until the cursor has really moved.
                if (!self.pastThreshold()) return;
                if (self.drag.hinted) {
                    // A window of this press moved: confirm by size stability (works also
                    // when the window cannot follow the cursor, e.g. against the menu bar).
                    self.scheduleConfirm();
                    return;
                }
                if (t_ns -| self.drag.last_check_ns < fallback_interval_ns) return;
                self.drag.last_check_ns = t_ns;
                self.drag.checks += 1;
                const w = self.drag.w.?;
                if (self.ws.frame(w)) |f| {
                    if (movedOnly(f, self.drag.frame0)) {
                        if (!self.echoSuppressed()) {
                            self.drag.w = null;
                            self.beginDrag(w, f);
                            return;
                        }
                        // Our own setFrame moved it: compare against the new position.
                        self.drag.frame0 = f;
                        self.drag.p0 = p;
                    }
                    if (self.drag.checks < fallback_max_checks) return;
                }
                // Gone or never moved: stop polling; the observer path stays open.
                self.ws.release(w);
                self.drag.w = null;
                self.drag.phase = .pressed;
            },
            .dragging => {
                self.drag.last_p = p;
                self.evaluate(p);
            },
        }
    }

    pub fn mouseUp(self: *Engine, p: t.Point, t_ns: u64) void {
        self.drag.last_p = p;
        if (self.drag.phase == .dragging) {
            if (self.drag.preview) |pv| {
                self.drag.preview = null;
                self.emitHide(true);
                const w = self.drag.w.?;
                self.drag.w = null;
                self.schedule(.{
                    .w = w,
                    .rect = pv.rect,
                    .action = pv.action,
                    .zone = pv.zone,
                    .display_id = pv.display_id,
                    .pre_snap = self.drag.start_frame,
                    .t_up = t_ns,
                });
            }
        }
        self.resetDrag(true);
    }

    /// `mods` is a Nokta mask (types.Mods).
    pub fn flagsChanged(self: *Engine, mods: u32) void {
        self.mods = mods;
        if (self.drag.phase == .dragging) self.evaluate(self.drag.last_p);
    }

    /// AXObserver kAXWindowMovedNotification for a window of the observed app (borrowed).
    /// Notifications cover every window of the app, so only the window under the cursor is
    /// this gesture; and only a cursor that moved > 4 pt makes it a drag (a click, a
    /// title-bar double-click that zooms, a 1 pt jitter or a late echo of our own move
    /// must never trigger snap-back).
    pub fn windowMoved(self: *Engine, w: Window) void {
        switch (self.drag.phase) {
            .pressed, .candidate => {},
            .idle, .dragging, .ignored => return,
        }
        if (self.echoSuppressed()) return;
        if (self.drag.w) |cw| {
            if (!self.ws.same(cw, w)) return;
        } else {
            const f = self.ws.frame(w) orelse return;
            // The pressed point (or the cursor) lies on the window: not a sheet, panel or
            // another window of the app moving at the same time.
            if (!containsWithSlop(f, self.drag.p_down, grab_slop) and
                !containsWithSlop(f, self.drag.last_p, grab_slop)) return;
            self.ws.retain(w);
            self.watch(w, f, 0);
            self.drag.fallback_done = true;
        }
        self.drag.hinted = true;
        if (self.pastThreshold()) self.scheduleConfirm();
    }

    /// AXObserver kAXWindowResizedNotification (borrowed). A left/top edge resize also moves
    /// the origin (→ windowMoved); a resize of the window under the cursor is therefore not
    /// a drag. Our own resizes (snap-back, applies) are filtered by the echo window.
    pub fn windowResized(self: *Engine, w: Window) void {
        if (self.echoSuppressed()) return;
        switch (self.drag.phase) {
            .pressed, .candidate => {
                // Another window of the app (a sheet, an animating panel) is not this gesture.
                if (self.drag.w) |cw| {
                    if (!self.ws.same(cw, w)) return;
                } else {
                    const f = self.ws.frame(w) orelse return;
                    if (!containsWithSlop(f, self.drag.last_p, grab_slop)) return;
                }
                // Moved has not made it a drag yet: the gesture is a resize; stay out of it.
                self.resetDrag(true);
                self.drag.phase = .ignored;
            },
            .dragging => {
                const dw = self.drag.w orelse return;
                if (!self.ws.same(dw, w)) return;
                // A slow app can deliver the echo of our own snap-back resize after the echo
                // window: if the size is still the one we set, it is not a user resize.
                if (self.ws.frame(w)) |f| {
                    const s = self.drag.start_frame;
                    if (@abs(f.w - s.w) <= 2 and @abs(f.h - s.h) <= 2) return;
                }
                self.resetDrag(true);
                self.drag.phase = .ignored;
            },
            .idle, .ignored => {},
        }
    }

    /// Drops a half-tracked drag (event tap disabled, core stopped): hides the preview and
    /// releases handles. A deferred apply that was already scheduled still runs.
    pub fn cancelDrag(self: *Engine) void {
        self.resetDrag(true);
    }

    /// True when `pid`'s bundle is on the exclusion list (pid→bundle cache).
    pub fn isExcludedPid(self: *const Engine, pid: i32) bool {
        return self.rules.isExcluded(self.bundleFor(pid));
    }

    /// Fills the engine-owned fields of `out` (snaps, failures, latencies, displays).
    pub fn fillStats(self: *const Engine, out: *t.Stats) void {
        out.snaps = self.snaps;
        out.failures = self.failures;
        out.last_latency_ns = self.last_latency_ns;
        out.displays = @intCast(self.display_count);
        const n = self.latency_count;
        if (n == 0) {
            out.p50_latency_ns = 0;
            out.p95_latency_ns = 0;
            out.max_latency_ns = 0;
            return;
        }
        var buf: [latency_samples]u64 = undefined;
        @memcpy(buf[0..n], self.latencies[0..n]);
        std.mem.sort(u64, buf[0..n], {}, std.sort.asc(u64));
        out.p50_latency_ns = buf[nearestRank(n, 50)];
        out.p95_latency_ns = buf[nearestRank(n, 95)];
        out.max_latency_ns = buf[n - 1];
    }

    // ---- private --------------------------------------------------------------

    fn fail(self: *Engine, action: t.Action, zone: t.Zone, source: t.Source, code: t.Result, display_id: u32, rect: t.Rect) t.Result {
        self.sink.emit(.{
            .kind = @backingInt(t.EventKind.failed),
            .action = @backingInt(action),
            .zone = @backingInt(zone),
            .source = @backingInt(source),
            .code = @backingInt(code),
            .display_id = display_id,
            .rect = rect,
        });
        return code;
    }

    fn bundleFor(self: *const Engine, pid: i32) ?[]const u8 {
        if (pid <= 0) return null;
        for (&self.bundles) |*e| {
            if (e.pid == pid) return if (e.has_id) e.id[0..e.len] else null;
        }
        return null;
    }

    fn recordLatency(self: *Engine, ns: u64) void {
        self.latencies[self.latency_head] = ns;
        self.latency_head = (self.latency_head + 1) % latency_samples;
        if (self.latency_count < latency_samples) self.latency_count += 1;
        self.last_latency_ns = ns;
    }

    fn echoSuppressed(self: *Engine) bool {
        const last = self.last_set_frame_ns orelse return false;
        return self.ws.nowNs() -| last < echo_window_ns;
    }

    // ---- memory ---------------------------------------------------------------

    fn findMemory(self: *Engine, w: Window) ?usize {
        for (self.memory, 0..) |e, i| {
            if (e.w) |mw| {
                if (self.ws.same(mw, w)) return i;
            }
        }
        return null;
    }

    /// Updates slot `idx` (an existing entry for `w`) or takes a free/LRU slot, retaining `w`.
    fn remember(self: *Engine, idx: ?usize, w: Window, pre_snap: t.Rect, target: t.Rect, requested: t.Rect, action: t.Action, cycle: u32) void {
        const slot = idx orelse blk: {
            var s: usize = 0;
            var oldest: u64 = std.math.maxInt(u64);
            for (self.memory, 0..) |e, i| {
                if (e.w == null) {
                    s = i;
                    break;
                }
                if (e.stamp < oldest) {
                    oldest = e.stamp;
                    s = i;
                }
            }
            self.forget(s);
            self.ws.retain(w);
            self.memory[s].w = w;
            break :blk s;
        };
        self.memory_clock += 1;
        const e = &self.memory[slot];
        e.pre_snap = pre_snap;
        e.last_target = target;
        e.last_requested = requested;
        e.last_action = action;
        e.last_cycle = cycle;
        e.stamp = self.memory_clock;
    }

    fn forget(self: *Engine, idx: usize) void {
        if (self.memory[idx].w) |w| self.ws.release(w);
        self.memory[idx] = .{};
    }

    // ---- drag -----------------------------------------------------------------

    /// Takes ownership of the retained `w`.
    /// `w` is retained (owned by the drag from here on); `fr` is its current frame.
    fn beginDrag(self: *Engine, w: Window, fr: t.Rect) void {
        const cursor = self.drag.last_p;
        var start = self.pressFrame(fr);
        start.w = fr.w;
        start.h = fr.h;

        const info = self.ws.info(w) orelse return self.ignoreDrag(w);
        if (!info.standard or !info.movable) return self.ignoreDrag(w);
        if (self.rules.isExcluded(self.bundleFor(info.pid))) return self.ignoreDrag(w);

        self.drag.phase = .dragging;
        self.drag.w = w;
        self.drag.preview = null;

        if (self.config.snap_back) snap_back: {
            const mi = self.findMemory(w) orelse break :snap_back;
            const e = self.memory[mi];
            const ds = self.displays();
            const tol = if (geo.displayIndexForRect(fr, ds)) |di| tolerance(ds[di].usable) else 16;
            const at_target = @abs(fr.w - e.last_target.w) <= tol and @abs(fr.h - e.last_target.h) <= tol;
            const at_request = @abs(fr.w - e.last_requested.w) <= tol and @abs(fr.h - e.last_requested.h) <= tol;
            if (!at_target and !at_request) break :snap_back;
            const pre = e.pre_snap;
            const rel = if (fr.w > 0) std.math.clamp((cursor.x - fr.x) / fr.w, 0, 1) else 0.5;
            const r = t.Rect{ .x = @round(cursor.x - rel * pre.w), .y = fr.y, .w = pre.w, .h = pre.h };
            const rc = self.ws.setFrame(w, r).rc;
            self.last_set_frame_ns = self.ws.nowNs();
            if (rc != .ok) {
                self.failures += 1;
                break :snap_back;
            }
            start = pre;
            self.forget(mi);
        }

        self.drag.start_frame = start;
        self.evaluate(cursor);
    }

    /// Candidate: `w` (retained) is checked for movement against `f0` on later drags; the
    /// first check runs once `check_from_ns` + the fallback interval has passed.
    fn watch(self: *Engine, w: Window, f0: t.Rect, check_from_ns: u64) void {
        self.drag.phase = .candidate;
        self.drag.w = w;
        self.drag.frame0 = f0;
        self.drag.p0 = self.drag.last_p;
        self.drag.last_check_ns = check_from_ns;
        self.drag.checks = 0;
    }

    /// The cursor has moved more than `drag_threshold` from the press (sticky per press).
    fn pastThreshold(self: *Engine) bool {
        if (self.drag.past_threshold) return true;
        const dx = self.drag.last_p.x - self.drag.p_down.x;
        const dy = self.drag.last_p.y - self.drag.p_down.y;
        self.drag.past_threshold = dx * dx + dy * dy > drag_threshold * drag_threshold;
        return self.drag.past_threshold;
    }

    /// Estimated frame at the press, per axis: an axis on which the window moved since the
    /// candidate sample follows the cursor → current frame minus the whole cursor travel (an
    /// app that lagged has caught up); an axis that did not move since → the sample minus the
    /// travel up to it. The menu bar stops a title bar: a window held at the top while the
    /// cursor went up did not follow upward.
    fn pressFrame(self: *Engine, fr: t.Rect) t.Rect {
        const f0 = self.drag.frame0;
        const pd = self.drag.p_down;
        const c = self.drag.last_p;
        const p0 = self.drag.p0;
        var r = fr;
        r.x = if (@abs(fr.x - f0.x) >= 1) fr.x - (c.x - pd.x) else f0.x - (p0.x - pd.x);
        r.y = if (@abs(fr.y - f0.y) >= 1) fr.y - (c.y - pd.y) else f0.y - (p0.y - pd.y);
        if (c.y < pd.y) {
            const ds = self.displays();
            if (geo.displayIndexForPoint(pd, ds)) |di| {
                const top = ds[di].usable.minY() + 2;
                if (fr.y <= top) r.y = if (f0.y <= top) f0.y else f0.y - (p0.y - pd.y);
            }
        }
        return r;
    }

    /// The deferred drag confirmation (tests run it selectively).
    pub const confirm_callback: ws_mod.DeferredFn = confirmDeferred;

    fn scheduleConfirm(self: *Engine) void {
        if (self.drag.confirm_pending) return;
        self.drag.confirm_pending = true;
        self.drag.confirm_due = self.ws.nowNs() + confirm_delay_ns;
        self.ws.deferCall(confirm_delay_ns, confirmDeferred, @ptrCast(self));
    }

    /// Observer candidate, `confirm_delay_ns` after the cursor passed the threshold: a Resized
    /// notification in the meantime has already made the press `.ignored`; a size that still
    /// changed means a left/top-edge resize; otherwise the window is being dragged.
    fn confirmDeferred(arg: *anyopaque) void {
        const self: *Engine = @ptrCast(@alignCast(arg));
        if (!self.drag.confirm_pending or self.ws.nowNs() < self.drag.confirm_due) return; // older press
        self.drag.confirm_pending = false;
        if (self.drag.phase != .candidate) return;
        const w = self.drag.w orelse return;
        const f = self.ws.frame(w) orelse return;
        self.drag.w = null;
        if (@abs(f.w - self.drag.frame0.w) >= 1 or @abs(f.h - self.drag.frame0.h) >= 1) return self.ignoreDrag(w);
        self.beginDrag(w, f);
    }

    fn ignoreDrag(self: *Engine, w: Window) void {
        self.ws.release(w);
        self.drag.w = null;
        self.drag.preview = null;
        self.drag.phase = .ignored;
    }

    fn alternateHeld(self: *const Engine) bool {
        const m = self.config.thirds_modifier;
        return m != 0 and (self.mods & m) == m;
    }

    fn previewAt(self: *Engine, p: t.Point) ?Preview {
        const ds = self.displays();
        const hit = zones.hitTest(p, ds, zones.Params.fromConfig(self.config)) orelse return null;
        const d = ds[hit.display_index];
        const action = zones.orient(self.zone_map.get(hit.zone, self.alternateHeld()), hit.zone, d.usable.h > d.usable.w);
        if (!layout.isFrameAction(action)) return null;
        const r = layout.frameFor(action, self.drag.start_frame, d.usable, 0, layout.optionsFromConfig(self.config)) orelse return null;
        return .{ .zone = hit.zone, .action = action, .display_id = d.id, .rect = r };
    }

    fn evaluate(self: *Engine, p: t.Point) void {
        if (self.previewAt(p)) |n| {
            if (self.drag.preview) |cur| {
                if (cur.zone == n.zone and cur.action == n.action and cur.display_id == n.display_id) return;
            }
            self.drag.preview = n;
            self.sink.emit(.{
                .kind = @backingInt(t.EventKind.preview_show),
                .action = @backingInt(n.action),
                .zone = @backingInt(n.zone),
                .source = @backingInt(t.Source.drag),
                .display_id = n.display_id,
                .rect = n.rect,
            });
        } else if (self.drag.preview != null) {
            self.drag.preview = null;
            self.emitHide(false);
        }
    }

    /// `drop`: the drag ended over this preview and the drop will be applied.
    fn emitHide(self: *Engine, drop: bool) void {
        self.sink.emit(.{
            .kind = @backingInt(t.EventKind.preview_hide),
            .source = @backingInt(t.Source.drag),
            .flags = if (drop) t.event_flag_drop else 0,
        });
    }

    /// Back to idle, releasing the tracked handle. Emits preview_hide (cancel) if one is showing.
    fn resetDrag(self: *Engine, emit_hide: bool) void {
        if (emit_hide and self.drag.preview != null) self.emitHide(false);
        if (self.drag.w) |w| self.ws.release(w);
        self.drag = .{};
    }

    fn schedule(self: *Engine, pa: PendingApply) void {
        if (self.pending) |old| {
            // A deferred call is already queued; it will apply the newest drop.
            self.ws.release(old.w);
            self.pending = pa;
            return;
        }
        self.pending = pa;
        self.ws.deferCall(0, applyDeferred, @ptrCast(self));
    }

    fn applyDeferred(arg: *anyopaque) void {
        const self: *Engine = @ptrCast(@alignCast(arg));
        const pa = self.pending orelse return;
        self.pending = null;
        defer self.ws.release(pa.w);

        // Where the window really is (after snap-back, against the menu bar, lagging behind
        // the cursor): the reference for telling a stale read-back from a refused change.
        const before = self.ws.frame(pa.w) orelse pa.pre_snap;
        const set = self.ws.setFrame(pa.w, pa.rect);
        const now = self.ws.nowNs();
        self.last_set_frame_ns = now;
        if (set.rc != .ok) {
            self.failures += 1;
            _ = self.fail(pa.action, pa.zone, .drag, set.rc, pa.display_id, pa.rect);
            return;
        }
        const latency = now -| pa.t_up;
        const usable = if (self.displayById(pa.display_id)) |d| d.usable else pa.rect;
        const applied = self.appliedFrame(pa.w, pa.rect, usable, before, 2, set.size_refused);
        // Dragged out of its last snapped frame (snap-back off): keep the chain's original
        // pre-snap frame, like a keyboard snap of a window that is still at its last target.
        const mi = self.findMemory(pa.w);
        var pre = pa.pre_snap;
        if (mi) |i| {
            const e = self.memory[i];
            if (e.holds(pa.pre_snap, tolerance(usable))) pre = e.pre_snap;
        }
        self.remember(mi, pa.w, pre, applied.rect, pa.rect, pa.action, 0);
        self.recordLatency(latency);
        self.snaps += 1;
        self.sink.emit(.{
            .kind = @backingInt(t.EventKind.snapped),
            .action = @backingInt(pa.action),
            .zone = @backingInt(pa.zone),
            .source = @backingInt(t.Source.drag),
            .display_id = pa.display_id,
            .cycle = 0,
            .flags = applied.flags,
            .rect = applied.rect,
            .latency_ns = latency,
        });
    }

    const Applied = struct { rect: t.Rect, flags: u32 };

    /// One position+size read after a successful set (`before` = the frame before the
    /// setters, `before_tol` its precision):
    ///   - equal to the target → done;
    ///   - equal to `before` although the target asked for a different position → a stale
    ///     read from an app that applies AX changes asynchronously (a minimum size never
    ///     blocks a move): trust the target (writing anything back would undo the snap, and
    ///     memory must hold the target so cycling and restore keep working). Unchanged when
    ///     only the size was asked to change = the window refused to shrink (min size);
    ///   - larger than the tile (minimum size) or size refused (fixed size) → re-aligned to
    ///     the edge the tile hugs (right half → right edge, center third → centered) with one
    ///     position write, as every mature competitor does (COMPETITOR-DEEP.md), and flagged;
    ///   - otherwise (a few points smaller: size increments such as a terminal's cell grid)
    ///     → the actual frame, no flag: nothing went wrong.
    fn appliedFrame(self: *Engine, w: Window, target: t.Rect, usable: t.Rect, before: t.Rect, before_tol: f64, size_refused: bool) Applied {
        const refused_flag: u32 = if (size_refused) t.event_flag_size_refused else 0;
        const actual = self.ws.frame(w) orelse return .{ .rect = target, .flags = refused_flag };
        if (geo.approxEqual(actual, target, 2)) return .{ .rect = target, .flags = 0 };
        const moved_requested = @abs(target.x - before.x) > 2 or @abs(target.y - before.y) > 2;
        if (!size_refused and moved_requested and geo.approxEqual(actual, before, before_tol))
            return .{ .rect = target, .flags = 0 };
        const overflow = actual.w > target.w + 2 or actual.h > target.h + 2;
        if (!overflow and !size_refused) return .{ .rect = actual, .flags = 0 };
        var result = actual;
        const aligned = alignToTarget(actual, target, usable);
        if (!geo.approxEqual(aligned, actual, 1)) {
            if (self.ws.setPosition(w, .{ .x = aligned.x, .y = aligned.y }) == .ok) {
                result = self.ws.frame(w) orelse aligned;
                self.last_set_frame_ns = self.ws.nowNs();
            }
        }
        return .{ .rect = result, .flags = if (size_refused) t.event_flag_size_refused else t.event_flag_frame_differs };
    }

    fn displayById(self: *Engine, id: u32) ?t.Display {
        for (self.displays()) |d| {
            if (d.id == id) return d;
        }
        return null;
    }
};

/// Keeps `actual`'s size and places it on the side of `target` that faces the usable area's
/// edge the tile belongs to (left/right/centered per axis), then clamps into `usable`.
pub fn alignToTarget(actual: t.Rect, target: t.Rect, usable: t.Rect) t.Rect {
    var r = actual;
    r.x = alignAxis(actual.w, target.minX(), target.maxX(), target.midX(), usable.midX());
    r.y = alignAxis(actual.h, target.minY(), target.maxY(), target.midY(), usable.midY());
    return geo.integral(geo.clampInto(r, usable));
}

fn alignAxis(size: f64, lo: f64, hi: f64, mid: f64, usable_mid: f64) f64 {
    if (mid > usable_mid + 1) return hi - size; // tile on the far side: hug its far edge
    if (mid < usable_mid - 1) return lo; // near side: hug its near edge
    return mid - size / 2; // centered tile
}

fn tolerance(usable: t.Rect) f64 {
    return @max(16.0, 0.02 * usable.w);
}

/// `p` lies inside `r` grown by `slop` on every side.
fn containsWithSlop(r: t.Rect, p: t.Point, slop: f64) bool {
    return p.x >= r.minX() - slop and p.x <= r.maxX() + slop and p.y >= r.minY() - slop and p.y <= r.maxY() + slop;
}

/// Origin changed by at least a point while the size stayed (a move, not an edge resize).
fn movedOnly(now: t.Rect, before: t.Rect) bool {
    const same_size = @abs(now.w - before.w) < 1 and @abs(now.h - before.h) < 1;
    const origin_moved = @abs(now.x - before.x) >= 1 or @abs(now.y - before.y) >= 1;
    return same_size and origin_moved;
}

/// Nearest-rank percentile index into a sorted slice of length n > 0.
fn nearestRank(n: usize, pct: usize) usize {
    const r = (n * pct + 99) / 100;
    return if (r == 0) 0 else r - 1;
}
