//! latency.zig — hotkey-path latency and placement accuracy of libnokta against Nokta's OWN test
//! window (tools/bench/target/Target.swift). Built by tools/bench/build.sh, run by scripts/bench.sh.
//!
//! SAFETY MODEL (the terminal this runs in has Accessibility trust, a wrong call would move the
//! user's real windows):
//!   * the only function that can change a window is nk_core_perform_pid(core, pid, ...), and it is
//!     reached only after `resolveTarget` has proven, via read-only AX queries, that `pid`
//!       - runs the executable `nokta-bench-target`            (proc_pidpath),
//!       - owns exactly ONE window,
//!       - whose AXTitle (and AXFocusedWindow title, if any) is `NOKTA-BENCH-<nonce>`.
//!     The proof is repeated before EVERY action; any failure aborts the run without acting.
//!   * nk_core_perform (frontmost app) is never referenced. This file contains no AX setters.
//!   * the core is created but never started: no hotkeys, no event tap.
//!   * `--hung K` (recovery): after the proof, the target process (our own child, re-proven to be
//!     `nokta-bench-target`) is suspended with SIGSTOP, K actions are timed against it — a stopped
//!     app cannot answer AX, so nothing can move — and it is ALWAYS resumed with SIGCONT before the
//!     tool returns. The proof is then repeated and one normal action must succeed again.
//!
//! Usage:  latency --pid <pid> [--nonce <n>] [--n 300] [--warmup 10] [--tolerance 2] [--verify-only] [--hung K]
//! stdout: one JSON document; progress/diagnostics on stderr.
//! Exit:   0 ok, 2 refused (target verification failed), 3 Accessibility not trusted,
//!         4 core refused to act (e.g. NK_ERR_NOT_TRUSTED), 1 usage/other.

const std = @import("std");

// ---------------------------------------------------------------------------------------------
// libnokta C ABI — mirrors core/include/nokta.h (checked by size asserts + nk_abi_version()).
// ---------------------------------------------------------------------------------------------
const NkRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
const NkPoint = extern struct { x: f64, y: f64 };
const NkConfig = extern struct {
    abi_version: u32,
    gap_outer: f64,
    gap_inner: f64,
    zone_edge: f64,
    zone_corner: f64,
    almost_maximize: f64,
    thirds_modifier: u32,
    drag_snap: bool,
    snap_back: bool,
    cycle_sizes: bool,
    shared_edge_zones: bool,
};
const NkStats = extern struct {
    snaps: u64,
    failures: u64,
    last_latency_ns: u64,
    p50_latency_ns: u64,
    p95_latency_ns: u64,
    max_latency_ns: u64,
    hotkeys_bound: u32,
    hotkeys_failed: u32,
    displays: u32,
    observed_pid: i32,
    event_tap_active: bool,
    started: bool,
};
comptime {
    std.debug.assert(@sizeOf(NkRect) == 32 and @sizeOf(NkPoint) == 16);
    std.debug.assert(@sizeOf(NkConfig) == 56 and @sizeOf(NkStats) == 72);
}
const NK_ABI_VERSION: u32 = 1;

// nk_action values used here (nokta.h)
const A_LEFT_HALF: u32 = 1;
const A_RIGHT_HALF: u32 = 2;
const A_TOP_LEFT: u32 = 5;
const A_BOTTOM_RIGHT: u32 = 8;
const A_FIRST_THIRD: u32 = 9;
const A_LAST_TWO_THIRDS: u32 = 14;
const A_MAXIMIZE: u32 = 15;
const A_CENTER: u32 = 17;

extern fn nk_abi_version() u32;
extern fn nk_config_default(out: *NkConfig) void;
extern fn nk_core_create(config: *const NkConfig, cb: ?*const anyopaque, userdata: ?*anyopaque) ?*anyopaque;
extern fn nk_core_destroy(core: *anyopaque) void;
extern fn nk_core_perform_pid(core: *anyopaque, pid: i32, action: u32) i32;
extern fn nk_core_stats(core: *const anyopaque, out: *NkStats) void;
extern fn nk_usable_frame_at(core: *anyopaque, p: NkPoint, out: *NkRect) bool;
extern fn nk_action_id(action: u32) ?[*:0]const u8;

// ---------------------------------------------------------------------------------------------
// System: libc, mach time, libproc, CoreFoundation, Accessibility (READ-ONLY use).
// ---------------------------------------------------------------------------------------------
const MachTimebase = extern struct { numer: u32, denom: u32 };
extern fn mach_absolute_time() u64;
extern fn mach_timebase_info(info: *MachTimebase) c_int;
extern fn usleep(us: u32) c_int;
extern fn kill(pid: c_int, sig: c_int) c_int;
const SIGSTOP: c_int = 17; // macOS <sys/signal.h>
const SIGCONT: c_int = 19;
extern fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern fn getpid() c_int;
extern fn proc_pidpath(pid: c_int, buffer: [*]u8, size: u32) c_int;

const CFRef = *anyopaque;
extern fn CFRelease(o: CFRef) void;
extern fn CFStringCreateWithCString(alloc: ?*anyopaque, cstr: [*:0]const u8, encoding: u32) ?CFRef;
extern fn CFStringGetCString(s: CFRef, buf: [*]u8, size: isize, encoding: u32) bool;
extern fn CFGetTypeID(o: CFRef) usize;
extern fn CFStringGetTypeID() usize;
extern fn CFArrayGetTypeID() usize;
extern fn CFArrayGetCount(a: CFRef) isize;
extern fn CFArrayGetValueAtIndex(a: CFRef, i: isize) ?CFRef;
const kCFStringEncodingUTF8: u32 = 0x08000100;

extern fn AXIsProcessTrusted() bool;
extern fn AXUIElementCreateApplication(pid: c_int) ?CFRef;
extern fn AXUIElementCopyAttributeValue(el: CFRef, attr: CFRef, value: *?CFRef) i32;
extern fn AXUIElementSetMessagingTimeout(el: CFRef, seconds: f32) i32;
extern fn AXValueGetValue(v: CFRef, kind: u32, out: *anyopaque) bool;
const kAXValueCGPoint: u32 = 1;
const kAXValueCGSize: u32 = 2;

var attr_windows: CFRef = undefined;
var attr_focused: CFRef = undefined;
var attr_title: CFRef = undefined;
var attr_position: CFRef = undefined;
var attr_size: CFRef = undefined;

fn mkstr(s: [*:0]const u8) CFRef {
    return CFStringCreateWithCString(null, s, kCFStringEncodingUTF8).?;
}

// ---------------------------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------------------------
fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn eprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeAll(2, s);
}

fn jsonEscape(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

// ---------------------------------------------------------------------------------------------
// Target verification (read-only AX)
// ---------------------------------------------------------------------------------------------
const title_prefix = "NOKTA-BENCH-";
const target_exe = "nokta-bench-target";

const Verdict = enum {
    ok,
    ax_not_trusted,
    bad_pid,
    exe_mismatch,
    no_app_element,
    no_windows,
    window_count,
    title_unreadable,
    title_mismatch,
    focused_title_mismatch,

    fn text(v: Verdict) []const u8 {
        return switch (v) {
            .ok => "ok",
            .ax_not_trusted => "this process is not trusted for Accessibility",
            .bad_pid => "pid is not a valid target (<= 0 or this process)",
            .exe_mismatch => "pid does not run nokta-bench-target",
            .no_app_element => "AXUIElementCreateApplication failed",
            .no_windows => "AX reports no windows for this pid",
            .window_count => "pid owns more than one window",
            .title_unreadable => "window AXTitle unreadable",
            .title_mismatch => "window AXTitle is not NOKTA-BENCH-<nonce>",
            .focused_title_mismatch => "focused window AXTitle is not NOKTA-BENCH-<nonce>",
        };
    }
};

const Resolved = struct {
    verdict: Verdict,
    app: ?CFRef = null,
    windows: ?CFRef = null,
    win: ?CFRef = null, // borrowed from `windows`
    title: [160]u8 = undefined,
    title_len: usize = 0,

    fn observedTitle(r: *const Resolved) []const u8 {
        return r.title[0..r.title_len];
    }

    fn release(r: *Resolved) void {
        if (r.windows) |w| CFRelease(w);
        if (r.app) |a| CFRelease(a);
        r.windows = null;
        r.app = null;
        r.win = null;
    }
};

fn copyAttr(el: CFRef, attr: CFRef) ?CFRef {
    var out: ?CFRef = null;
    if (AXUIElementCopyAttributeValue(el, attr, &out) != 0) return null;
    return out;
}

fn readTitle(win: CFRef, buf: []u8) ?usize {
    const v = copyAttr(win, attr_title) orelse return null;
    defer CFRelease(v);
    if (CFGetTypeID(v) != CFStringGetTypeID()) return null;
    var tmp: [160]u8 = undefined;
    if (!CFStringGetCString(v, &tmp, tmp.len, kCFStringEncodingUTF8)) return null;
    const s = std.mem.sliceTo(&tmp, 0);
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

fn titleOk(title: []const u8, nonce: ?[]const u8) bool {
    if (!std.mem.startsWith(u8, title, title_prefix)) return false;
    if (nonce) |n| {
        return title.len == title_prefix.len + n.len and std.mem.eql(u8, title[title_prefix.len..], n);
    }
    return true;
}

fn exeOk(pid: i32) bool {
    var path: [1024]u8 = undefined;
    const n = proc_pidpath(pid, &path, path.len);
    if (n <= 0) return false;
    const p = path[0..@intCast(n)];
    return std.mem.eql(u8, std.fs.path.basename(p), target_exe);
}

/// Proves that `pid` is our own test window app. Order matters for the demo/diagnostics: the AX
/// title check comes before the executable-path check, so a wrong pid is rejected by the title.
fn resolveTarget(pid: i32, nonce: ?[]const u8) Resolved {
    var r: Resolved = .{ .verdict = .ok };
    if (pid <= 0 or pid == getpid()) {
        r.verdict = .bad_pid;
        return r;
    }
    if (!AXIsProcessTrusted()) {
        r.verdict = .ax_not_trusted;
        return r;
    }
    const app = AXUIElementCreateApplication(pid) orelse {
        r.verdict = .no_app_element;
        return r;
    };
    r.app = app;
    _ = AXUIElementSetMessagingTimeout(app, 2.0);

    const windows = copyAttr(app, attr_windows) orelse {
        r.verdict = .no_windows;
        r.release();
        return r;
    };
    r.windows = windows;
    if (CFGetTypeID(windows) != CFArrayGetTypeID() or CFArrayGetCount(windows) == 0) {
        r.verdict = .no_windows;
        r.release();
        return r;
    }
    if (CFArrayGetCount(windows) != 1) {
        r.verdict = .window_count;
        r.release();
        return r;
    }
    const win = CFArrayGetValueAtIndex(windows, 0).?;
    r.win = win;
    r.title_len = readTitle(win, &r.title) orelse {
        r.verdict = .title_unreadable;
        r.release();
        return r;
    };
    if (!titleOk(r.observedTitle(), nonce)) {
        r.verdict = .title_mismatch;
        r.release();
        return r;
    }
    // If the app reports a focused window it must be that same kind of window.
    if (copyAttr(app, attr_focused)) |fw| {
        defer CFRelease(fw);
        var fb: [160]u8 = undefined;
        const fl = readTitle(fw, &fb) orelse 0;
        if (fl == 0 or !titleOk(fb[0..fl], nonce)) {
            r.verdict = .focused_title_mismatch;
            r.release();
            return r;
        }
    }
    if (!exeOk(pid)) {
        r.verdict = .exe_mismatch;
        r.release();
        return r;
    }
    return r;
}

fn readFrame(win: CFRef) ?NkRect {
    var pos: NkPoint = undefined;
    var size: NkPoint = undefined; // CGSize has the same layout (two f64)
    const pv = copyAttr(win, attr_position) orelse return null;
    defer CFRelease(pv);
    const sv = copyAttr(win, attr_size) orelse return null;
    defer CFRelease(sv);
    if (!AXValueGetValue(pv, kAXValueCGPoint, &pos)) return null;
    if (!AXValueGetValue(sv, kAXValueCGSize, &size)) return null;
    return .{ .x = pos.x, .y = pos.y, .w = size.x, .h = size.y };
}

// ---------------------------------------------------------------------------------------------
// Expected placement (gaps are 0 in this harness, cycle_sizes off, so layout.zig reduces to
// plain fractions of the usable frame; centre keeps the current size)
// ---------------------------------------------------------------------------------------------
const sequence = [_]u32{ A_LEFT_HALF, A_RIGHT_HALF, A_MAXIMIZE, A_TOP_LEFT, A_BOTTOM_RIGHT, A_CENTER, A_FIRST_THIRD, A_LAST_TWO_THIRDS };

fn expectedFrame(action: u32, vf: NkRect, before: NkRect) NkRect {
    const portrait = vf.h > vf.w;
    const hw = vf.w / 2;
    const hh = vf.h / 2;
    return switch (action) {
        A_LEFT_HALF => .{ .x = vf.x, .y = vf.y, .w = hw, .h = vf.h },
        A_RIGHT_HALF => .{ .x = vf.x + hw, .y = vf.y, .w = hw, .h = vf.h },
        A_MAXIMIZE => vf,
        A_TOP_LEFT => .{ .x = vf.x, .y = vf.y, .w = hw, .h = hh },
        A_BOTTOM_RIGHT => .{ .x = vf.x + hw, .y = vf.y + hh, .w = hw, .h = hh },
        A_CENTER => .{
            .x = vf.x + (vf.w - before.w) / 2,
            .y = vf.y + (vf.h - before.h) / 2,
            .w = before.w,
            .h = before.h,
        },
        A_FIRST_THIRD => if (portrait)
            NkRect{ .x = vf.x, .y = vf.y, .w = vf.w, .h = vf.h / 3 }
        else
            NkRect{ .x = vf.x, .y = vf.y, .w = vf.w / 3, .h = vf.h },
        A_LAST_TWO_THIRDS => if (portrait)
            NkRect{ .x = vf.x, .y = vf.y + vf.h / 3, .w = vf.w, .h = vf.h * 2 / 3 }
        else
            NkRect{ .x = vf.x + vf.w / 3, .y = vf.y, .w = vf.w * 2 / 3, .h = vf.h },
        else => before,
    };
}

fn within(a: NkRect, b: NkRect, tol: f64) bool {
    return @abs(a.x - b.x) <= tol and @abs(a.y - b.y) <= tol and @abs(a.w - b.w) <= tol and @abs(a.h - b.h) <= tol;
}

// ---------------------------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------------------------
fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const rank: usize = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(sorted.len))));
    const idx = if (rank == 0) 0 else rank - 1;
    return sorted[@min(idx, sorted.len - 1)];
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1.0e6;
}

const MAX_SAMPLES = 8192;
var lat_ns: [MAX_SAMPLES]u64 = undefined; // measured latency, in run order
var lat_action: [MAX_SAMPLES]u8 = undefined; // index into `sequence`
var lat_ok: [MAX_SAMPLES]bool = undefined; // placement within tolerance
var lat_checked: [MAX_SAMPLES]bool = undefined;
var sorted_buf: [MAX_SAMPLES]u64 = undefined;
var json_buf: [128 * 1024]u8 = undefined;

const Mismatch = struct { action: u32 = 0, exp: NkRect = undefined, got: NkRect = undefined };

// ---------------------------------------------------------------------------------------------

const Args = struct {
    pid: i32 = 0,
    nonce: ?[]const u8 = null,
    n: usize = 300,
    warmup: usize = 10,
    tolerance: f64 = 2.0,
    verify_only: bool = false,
    /// > 0: recovery run against a suspended target instead of the latency loop.
    hung: usize = 0,
};

fn parseArgs(argv: []const [*:0]const u8) ?Args {
    var a: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const k = std.mem.span(argv[i]);
        if (std.mem.eql(u8, k, "--verify-only")) {
            a.verify_only = true;
            continue;
        }
        if (i + 1 >= argv.len) return null;
        const v = std.mem.span(argv[i + 1]);
        i += 1;
        if (std.mem.eql(u8, k, "--pid")) {
            a.pid = std.fmt.parseInt(i32, v, 10) catch return null;
        } else if (std.mem.eql(u8, k, "--nonce")) {
            a.nonce = v;
        } else if (std.mem.eql(u8, k, "--n")) {
            a.n = std.fmt.parseInt(usize, v, 10) catch return null;
        } else if (std.mem.eql(u8, k, "--warmup")) {
            a.warmup = std.fmt.parseInt(usize, v, 10) catch return null;
        } else if (std.mem.eql(u8, k, "--tolerance")) {
            a.tolerance = std.fmt.parseFloat(f64, v) catch return null;
        } else if (std.mem.eql(u8, k, "--hung")) {
            a.hung = std.fmt.parseInt(usize, v, 10) catch return null;
            if (a.hung > 64) return null;
        } else return null;
    }
    if (a.pid == 0 or a.n == 0 or a.n + a.warmup > MAX_SAMPLES) return null;
    return a;
}

fn refuse(pid: i32, v: Verdict, title: []const u8) u8 {
    eprint("REFUSED pid {d}: {s}", .{ pid, v.text() });
    if (title.len > 0) eprint(" (observed title \"{s}\")", .{title});
    eprint(". No window was touched.\n", .{});
    var w: std.Io.Writer = .fixed(&json_buf);
    emitRefusal(&w, pid, v, title) catch {};
    writeAll(1, w.buffered());
    return if (v == .ax_not_trusted) 3 else 2;
}

fn emitRefusal(w: *std.Io.Writer, pid: i32, v: Verdict, title: []const u8) !void {
    try w.print("{{\"tool\":\"latency\",\"status\":\"refused\",\"pid\":{d},\"verdict\":\"{s}\",\"reason\":", .{ pid, @tagName(v) });
    try jsonEscape(w, v.text());
    try w.writeAll(",\"observed_title\":");
    try jsonEscape(w, title);
    try w.writeAll("}\n");
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = parseArgs(init.args.vector) orelse {
        eprint("usage: latency --pid <pid> [--nonce <n>] [--n 300] [--warmup 10] [--tolerance 2] [--verify-only] [--hung K]\n", .{});
        return 1;
    };

    attr_windows = mkstr("AXWindows");
    attr_focused = mkstr("AXFocusedWindow");
    attr_title = mkstr("AXTitle");
    attr_position = mkstr("AXPosition");
    attr_size = mkstr("AXSize");

    // ---- 1. prove the target ------------------------------------------------------------------
    {
        var r = resolveTarget(args.pid, args.nonce);
        defer r.release();
        if (r.verdict != .ok) return refuse(args.pid, r.verdict, r.observedTitle());
        eprint("target verified: pid {d}, window \"{s}\"\n", .{ args.pid, r.observedTitle() });
        if (args.verify_only) {
            var w: std.Io.Writer = .fixed(&json_buf);
            w.print("{{\"tool\":\"latency\",\"status\":\"verified\",\"pid\":{d},\"title\":", .{args.pid}) catch {};
            jsonEscape(&w, r.observedTitle()) catch {};
            if (readFrame(r.win.?)) |f| {
                w.print(",\"frame\":[{d:.1},{d:.1},{d:.1},{d:.1}]", .{ f.x, f.y, f.w, f.h }) catch {};
            }
            w.writeAll("}\n") catch {};
            writeAll(1, w.buffered());
            return 0;
        }
    }

    // ---- 2. core --------------------------------------------------------------------------------
    if (nk_abi_version() != NK_ABI_VERSION) {
        eprint("libnokta ABI version {d} != {d}\n", .{ nk_abi_version(), NK_ABI_VERSION });
        return 1;
    }
    var cfg: NkConfig = undefined;
    nk_config_default(&cfg);
    cfg.gap_outer = 0;
    cfg.gap_inner = 0;
    cfg.cycle_sizes = false;
    cfg.drag_snap = false; // never started anyway; belt and braces
    const core = nk_core_create(&cfg, null, null) orelse {
        eprint("nk_core_create failed\n", .{});
        return 1;
    };
    defer nk_core_destroy(core);

    var tb: MachTimebase = undefined;
    _ = mach_timebase_info(&tb);
    const numer: u64 = tb.numer;
    const denom: u64 = tb.denom;

    if (args.hung > 0) return runHung(core, args, numer, denom);

    // ---- 3. measurement loop -------------------------------------------------------------------
    const total = args.warmup + args.n;
    var measured: usize = 0;
    var err_counts: [16]u32 = @splat(0); // by nk_result code (clamped)
    var settled_retries: u32 = 0;
    var unchecked: u32 = 0;
    var first_mismatches: [5]Mismatch = @splat(.{});
    var n_mismatch: usize = 0;
    var consecutive_errors: u32 = 0;

    var i: usize = 0;
    while (i < total) : (i += 1) {
        const ai = i % sequence.len;
        const action = sequence[ai];

        // Re-prove the target immediately before acting. This is the last gate before the setter.
        var r = resolveTarget(args.pid, args.nonce);
        if (r.verdict != .ok) {
            const rc = refuse(args.pid, r.verdict, r.observedTitle());
            r.release();
            return rc;
        }
        const win = r.win.?;
        const before = readFrame(win);

        var vf: NkRect = undefined;
        var have_vf = false;
        if (before) |b| {
            have_vf = nk_usable_frame_at(core, .{ .x = b.x + b.w / 2, .y = b.y + b.h / 2 }, &vf);
        }

        const t0 = mach_absolute_time();
        const res = nk_core_perform_pid(core, args.pid, action);
        const t1 = mach_absolute_time();
        const ns = (t1 - t0) * numer / denom;

        if (res != 0) {
            const code: usize = @intCast(@min(@max(res, 0), 15));
            err_counts[code] += 1;
            consecutive_errors += 1;
            r.release();
            if (i < args.warmup and consecutive_errors >= args.warmup) {
                eprint("nk_core_perform_pid keeps failing with code {d}; aborting\n", .{res});
                var w: std.Io.Writer = .fixed(&json_buf);
                w.print("{{\"tool\":\"latency\",\"status\":\"perform_failed\",\"pid\":{d},\"code\":{d}}}\n", .{ args.pid, res }) catch {};
                writeAll(1, w.buffered());
                return 4;
            }
            continue;
        }
        consecutive_errors = 0;

        // Placement check — outside the timed region.
        var ok = false;
        var checked = false;
        if (have_vf and before != null) {
            checked = true;
            const exp = expectedFrame(action, vf, before.?);
            var got = readFrame(win) orelse NkRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
            ok = within(got, exp, args.tolerance);
            if (!ok) {
                _ = usleep(30_000); // let the window server / app settle, then look again
                got = readFrame(win) orelse got;
                ok = within(got, exp, args.tolerance);
                if (ok) settled_retries += 1;
            }
            if (!ok and i >= args.warmup and n_mismatch < first_mismatches.len) {
                first_mismatches[n_mismatch] = .{ .action = action, .exp = exp, .got = got };
                n_mismatch += 1;
            }
        }
        r.release();

        if (i >= args.warmup) {
            lat_ns[measured] = ns;
            lat_action[measured] = @intCast(ai);
            lat_ok[measured] = ok;
            lat_checked[measured] = checked;
            if (!checked) unchecked += 1;
            measured += 1;
        }
        _ = usleep(2_000);
    }

    // ---- 4. report ---------------------------------------------------------------------------------
    var stats: NkStats = undefined;
    nk_core_stats(core, &stats);

    const nm = measured;
    @memcpy(sorted_buf[0..nm], lat_ns[0..nm]);
    std.mem.sort(u64, sorted_buf[0..nm], {}, std.sort.asc(u64));
    var sum: u128 = 0;
    for (sorted_buf[0..nm]) |v| sum += v;

    var checked_n: usize = 0;
    var ok_n: usize = 0;
    for (0..nm) |k| {
        if (lat_checked[k]) {
            checked_n += 1;
            if (lat_ok[k]) ok_n += 1;
        }
    }

    var w: std.Io.Writer = .fixed(&json_buf);
    report(&w, args, nm, sorted_buf[0..nm], sum, checked_n, ok_n, unchecked, settled_retries, &err_counts, first_mismatches[0..n_mismatch], &stats) catch {
        eprint("internal error: report buffer too small\n", .{});
        return 1;
    };
    writeAll(1, w.buffered());
    eprint("done: {d} samples, p50 {d:.3} ms, p95 {d:.3} ms, accuracy {d}/{d}\n", .{ nm, ms(percentile(sorted_buf[0..nm], 0.5)), ms(percentile(sorted_buf[0..nm], 0.95)), ok_n, checked_n });
    return 0;
}

/// Recovery run: how long a shortcut blocks on an app that does not answer, and whether the
/// next action works once it answers again. The target was proven in step 1.
fn runHung(core: *anyopaque, args: Args, numer: u64, denom: u64) u8 {
    var hung_ns: [64]u64 = undefined;
    var hung_codes: [16]u32 = @splat(0);
    {
        // Re-prove right before suspending: never stop a process that is not our target.
        var r = resolveTarget(args.pid, args.nonce);
        defer r.release();
        if (r.verdict != .ok) return refuse(args.pid, r.verdict, r.observedTitle());
    }
    if (kill(args.pid, SIGSTOP) != 0) {
        eprint("could not suspend pid {d}\n", .{args.pid});
        return 1;
    }
    var resumed = false;
    defer if (!resumed) {
        _ = kill(args.pid, SIGCONT);
    };
    _ = usleep(50_000);
    for (0..args.hung) |k| {
        const t0 = mach_absolute_time();
        const res = nk_core_perform_pid(core, args.pid, sequence[k % sequence.len]);
        hung_ns[k] = (mach_absolute_time() - t0) * numer / denom;
        hung_codes[@intCast(@min(@max(res, 0), 15))] += 1;
    }
    _ = kill(args.pid, SIGCONT);
    resumed = true;

    // Wait until the app answers AX again (bounded), re-prove it, then act once.
    const t_resume = mach_absolute_time();
    var responsive_ns: u64 = 0;
    var proven = false;
    var attempt: usize = 0;
    while (attempt < 60) : (attempt += 1) {
        var r = resolveTarget(args.pid, args.nonce);
        const ok = r.verdict == .ok;
        r.release();
        if (ok) {
            proven = true;
            responsive_ns = (mach_absolute_time() - t_resume) * numer / denom;
            break;
        }
        _ = usleep(50_000);
    }
    var after_ns: u64 = 0;
    var after_res: i32 = -1;
    if (proven) {
        const t0 = mach_absolute_time();
        after_res = nk_core_perform_pid(core, args.pid, A_LEFT_HALF);
        after_ns = (mach_absolute_time() - t0) * numer / denom;
    }

    const n = args.hung;
    @memcpy(sorted_buf[0..n], hung_ns[0..n]);
    std.mem.sort(u64, sorted_buf[0..n], {}, std.sort.asc(u64));
    var w: std.Io.Writer = .fixed(&json_buf);
    reportHung(&w, args.pid, sorted_buf[0..n], &hung_codes, proven, responsive_ns, after_res, after_ns) catch {
        eprint("internal error: report buffer too small\n", .{});
        return 1;
    };
    writeAll(1, w.buffered());
    eprint("hung: {d} actions, max {d:.1} ms; recovered: {s} (first action {d:.2} ms)\n", .{ n, ms(sorted_buf[n - 1]), if (after_res == 0) "yes" else "no", ms(after_ns) });
    return 0;
}

fn reportHung(w: *std.Io.Writer, pid: i32, sorted: []const u64, codes: *const [16]u32, proven: bool, responsive_ns: u64, after_res: i32, after_ns: u64) !void {
    try w.print("{{\"tool\":\"latency\",\"status\":\"ok\",\"mode\":\"hung\",\"pid\":{d},\"hung\":{{\"n\":{d},\"p50_ms\":{d:.2},\"max_ms\":{d:.2},\"results\":{{", .{
        pid, sorted.len, ms(percentile(sorted, 0.5)), ms(if (sorted.len > 0) sorted[sorted.len - 1] else 0),
    });
    var first = true;
    for (codes, 0..) |c, code| {
        if (c == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{d}\":{d}", .{ code, c });
    }
    try w.print("}}}},\"recovery\":{{\"responsive\":{},\"responsive_ms\":{d:.1},\"first_action_result\":{d},\"first_action_ms\":{d:.3}}}}}\n", .{
        proven, ms(responsive_ns), after_res, ms(after_ns),
    });
}

fn report(
    w: *std.Io.Writer,
    args: Args,
    nm: usize,
    sorted: []const u64,
    sum: u128,
    checked_n: usize,
    ok_n: usize,
    unchecked: u32,
    settled: u32,
    err_counts: *const [16]u32,
    mism: []const Mismatch,
    stats: *const NkStats,
) !void {
    const mean_ns: f64 = if (nm == 0) 0 else @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(nm));
    try w.print("{{\"tool\":\"latency\",\"status\":\"ok\",\"pid\":{d},\"samples\":{d},\"warmup\":{d},\"tolerance_pt\":{d:.1},", .{ args.pid, nm, args.warmup, args.tolerance });
    try w.print("\"latency_ms\":{{\"min\":{d:.4},\"mean\":{d:.4},\"p50\":{d:.4},\"p95\":{d:.4},\"p99\":{d:.4},\"max\":{d:.4}}},", .{
        ms(if (nm > 0) sorted[0] else 0),
        mean_ns / 1.0e6,
        ms(percentile(sorted, 0.50)),
        ms(percentile(sorted, 0.95)),
        ms(percentile(sorted, 0.99)),
        ms(if (nm > 0) sorted[nm - 1] else 0),
    });
    const rate: f64 = if (checked_n == 0) 0 else @as(f64, @floatFromInt(ok_n)) / @as(f64, @floatFromInt(checked_n));
    try w.print("\"accuracy\":{{\"checked\":{d},\"ok\":{d},\"rate\":{d:.4},\"unchecked\":{d},\"needed_settle_retry\":{d},\"first_mismatches\":[", .{ checked_n, ok_n, rate, unchecked, settled });
    for (mism, 0..) |m, k| {
        if (k > 0) try w.writeByte(',');
        const id = nk_action_id(m.action);
        try w.writeAll("{\"action\":");
        try jsonEscape(w, if (id) |p| std.mem.span(p) else "?");
        try w.print(",\"expected\":[{d:.1},{d:.1},{d:.1},{d:.1}],\"got\":[{d:.1},{d:.1},{d:.1},{d:.1}]}}", .{ m.exp.x, m.exp.y, m.exp.w, m.exp.h, m.got.x, m.got.y, m.got.w, m.got.h });
    }
    try w.writeAll("]},\"perform_errors\":{");
    var first = true;
    for (err_counts, 0..) |c, code| {
        if (c == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{d}\":{d}", .{ code, c });
    }
    try w.writeAll("},\"per_action\":[");
    var tmp: [MAX_SAMPLES]u64 = undefined;
    for (sequence, 0..) |act, ai| {
        var cnt: usize = 0;
        var okc: usize = 0;
        var chk: usize = 0;
        for (0..nm) |k| {
            if (lat_action[k] != ai) continue;
            tmp[cnt] = lat_ns[k];
            cnt += 1;
            if (lat_checked[k]) {
                chk += 1;
                if (lat_ok[k]) okc += 1;
            }
        }
        std.mem.sort(u64, tmp[0..cnt], {}, std.sort.asc(u64));
        if (ai > 0) try w.writeByte(',');
        const id = nk_action_id(act);
        try w.writeAll("{\"action\":");
        try jsonEscape(w, if (id) |p| std.mem.span(p) else "?");
        try w.print(",\"n\":{d},\"p50_ms\":{d:.4},\"p95_ms\":{d:.4},\"max_ms\":{d:.4},\"checked\":{d},\"ok\":{d}}}", .{
            cnt,
            ms(percentile(tmp[0..cnt], 0.5)),
            ms(percentile(tmp[0..cnt], 0.95)),
            ms(if (cnt > 0) tmp[cnt - 1] else 0),
            chk,
            okc,
        });
    }
    try w.print("],\"core_stats\":{{\"snaps\":{d},\"failures\":{d},\"p50_ms\":{d:.4},\"p95_ms\":{d:.4},\"max_ms\":{d:.4}}}}}\n", .{
        stats.snaps,
        stats.failures,
        ms(stats.p50_latency_ns),
        ms(stats.p95_latency_ns),
        ms(stats.max_latency_ns),
    });
}
