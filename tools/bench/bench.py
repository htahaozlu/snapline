#!/usr/bin/env python3
"""Nokta benchmark helpers (stdlib only; always run as `python3 -I tools/bench/bench.py ...`).

Sub-commands (driven by scripts/bench.sh, which also runs the Zig latency tool):

  static   file-size / linkage comparison of Nokta, Tiles and ~/re/competitors apps (reads files only)
  startup  N direct launches of `Nokta --bench-startup`, ready-time from NOKTA_READY mach timestamps
  idle     `Nokta --bench-idle` for RSS / CPU / idle-wakeup sampling; the user's Tiles process is
           sampled PASSIVELY (ps/top only, never signalled)
           `idle --mode used` runs `Nokta --bench-used` instead: the same, measured AFTER one flash +
           label plate was drawn (overlay panel, frame layers and the plate's glyph path exist). Still no event tap / AX
           observer (the bench modes never create them), so that part of the footprint is not included.
  session  one `Nokta --bench-session` process: fresh idle, menu open/close, Settings open/close
           N times, a shortcut workload (flash + label), then idle after use (default 300 s);
           1 Hz top/ps samples per phase + vmmap at each phase boundary (opt-in in bench.sh)
  report   merge out/*.json -> results.json + summary.md with PASS/FAIL against the targets

Safety: this script spawns exactly two kinds of processes: the Nokta binary with --bench-startup /
--bench-idle / --bench-used (never normal mode: no global shortcuts, no drag snapping, no window is ever
moved) and read-only tools (ps, top, otool, lipo, pgrep, sw_vers, sysctl). --bench-used additionally
shows one click-through flash and label plate on a small rect in a corner of the main screen for about
a second (Nokta's own overlay panel, from a synthetic event; it touches no window and posts no input).
--bench-session shows Nokta's own status menu, Settings window (throwaway preferences, never activated)
and flashes the same way; vmmap reads its memory map at phase boundaries.
The only process it ever signals is the Nokta bench child it started itself.
"""
import argparse
import ctypes
import glob
import json
import os
import plistlib
import re
import signal
import statistics
import subprocess
import sys
import threading
import time

ENV = dict(os.environ, LC_ALL="C", LANG="C")  # '.' decimal separator in ps/top output

# ---------------------------------------------------------------------------------------------
# targets (the work package's pass criteria)
# ---------------------------------------------------------------------------------------------
TARGETS = {
    "idle_cpu_pct": 0.1,        # mean %CPU over the idle window, "~0%"
    "rss_mb": 15.0,             # median RSS (informational: an empty AppKit process is ~32 MB, SPEC §8)
    "footprint_mb": 12.0,       # median phys_footprint — the gating memory metric (SPEC §5)
    "binary_bytes": 3 * 1024 * 1024,
    "design_binary_bytes": 850 * 1000,  # DESIGN §16 v2 budget (SPEC's hard limit is binary_bytes above)
    "bundle_bytes": 950 * 1000,  # DESIGN §16 v2 budget for the whole Snapline.app (decimal KB, as `du -A`/Finder show)
    "latency_p95_ms": 16.0,
    "startup_ms": 150.0,
    "accuracy_rate": 0.99,      # extra: share of actions landing within tolerance
    "hung_max_ms": 1000.0,      # extra: an action on an app that does not answer returns within 2x the AX timeout (0.5 s)
}


def run(cmd, **kw):
    return subprocess.run(cmd, env=ENV, capture_output=True, text=True, **kw)


def pct(sorted_vals, p):
    """Nearest-rank percentile of an ascending list."""
    if not sorted_vals:
        return None
    k = max(0, min(len(sorted_vals) - 1, int(-(-p * len(sorted_vals) // 1)) - 1))
    return sorted_vals[k]


def summarize(vals):
    if not vals:
        return {"n": 0}
    s = sorted(vals)
    return {
        "n": len(s),
        "min": s[0],
        "mean": statistics.fmean(s),
        "p50": pct(s, 0.50),
        "p95": pct(s, 0.95),
        "max": s[-1],
    }


def write_json(path, obj):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------------------------------------
# static comparison
# ---------------------------------------------------------------------------------------------
def dir_bytes(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            p = os.path.join(root, name)
            try:
                if not os.path.islink(p):
                    total += os.path.getsize(p)
            except OSError:
                pass
    return total


def exe_of(app):
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            name = plistlib.load(f).get("CFBundleExecutable")
        if name:
            return os.path.join(app, "Contents", "MacOS", name)
    except Exception:
        pass
    macos = os.path.join(app, "Contents", "MacOS")
    try:
        names = sorted(os.listdir(macos))
        return os.path.join(macos, names[0]) if names else None
    except OSError:
        return None


def arm64_slice_bytes(exe):
    """Size of the arm64 slice (or of the whole file if thin / not fat)."""
    info = run(["lipo", "-detailed_info", exe]).stdout
    m = re.search(r"architecture arm64\b.*?size (\d+)", info, re.S)
    if m:
        return int(m.group(1))
    return os.path.getsize(exe)


def linked_libs(exe):
    for args in (["otool", "-arch", "arm64", "-L", exe], ["otool", "-L", exe]):
        r = run(args)
        if r.returncode == 0 and r.stdout.strip():
            lines = [l.strip() for l in r.stdout.splitlines()[1:] if l.strip()]
            return [l.split(" (")[0] for l in lines]
    return []


def measure_app(app):
    exe = exe_of(app)
    out = {"app": app, "name": os.path.basename(app), "app_bytes": dir_bytes(app)}
    if exe and os.path.exists(exe):
        libs = linked_libs(exe)
        out.update(
            exe=exe,
            exe_bytes=os.path.getsize(exe),
            exe_arm64_bytes=arm64_slice_bytes(exe),
            archs=run(["lipo", "-archs", exe]).stdout.strip(),
            linked_libraries=len(libs),
            linked_frameworks=sum(1 for l in libs if ".framework/" in l),
            non_system_libraries=[l for l in libs if not l.startswith(("/System/", "/usr/lib/"))],
        )
    fw = os.path.join(app, "Contents", "Frameworks")
    out["bundled_frameworks"] = sorted(os.listdir(fw)) if os.path.isdir(fw) else []
    return out


def cmd_static(a):
    apps = [("nokta", a.nokta)]
    apps.append(("tiles", "/Applications/Tiles.app"))
    seen = set()
    for pat in ("~/re/competitors/*/app/*.app", "~/re/competitors/*/*.app"):
        for p in sorted(glob.glob(os.path.expanduser(pat))):
            if p not in seen:
                seen.add(p)
                apps.append((os.path.basename(p)[:-4].lower().replace(" ", "-"), p))
    res = {}
    for key, path in apps:
        if os.path.isdir(path):
            res[key] = measure_app(path)
        elif key in ("nokta", "tiles"):
            res[key] = {"app": path, "missing": True}
    write_json(a.out, res)
    print(f"static: {len([r for r in res.values() if not r.get('missing')])} apps measured -> {a.out}")


# ---------------------------------------------------------------------------------------------
# startup
# ---------------------------------------------------------------------------------------------
class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_libc = ctypes.CDLL(None)
_libc.mach_absolute_time.restype = ctypes.c_uint64
_tb = _Timebase()
_libc.mach_timebase_info(ctypes.byref(_tb))


def ticks_to_ms(t):
    return t * _tb.numer / _tb.denom / 1e6


def cmd_startup(a):
    exe = os.path.join(a.app, "Contents", "MacOS", "Snapline")
    if not os.access(exe, os.X_OK):
        write_json(a.out, {"status": "missing", "exe": exe})
        print(f"startup: {exe} not found", file=sys.stderr)
        return 1
    ready, total, results = [], [], []
    for i in range(a.runs):
        t0 = _libc.mach_absolute_time()
        # Direct exec of the bench mode — never `open`, never the normal (hotkey-registering) mode.
        p = subprocess.Popen([exe, "--bench-startup"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=ENV, text=True)
        killer = threading.Timer(15.0, lambda: p.poll() is None and p.kill())
        killer.start()
        line = ""
        try:
            for line in p.stdout:
                if line.startswith("NOKTA_READY"):
                    break
            else:
                line = ""
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
        finally:
            killer.cancel()
            if p.poll() is None:
                p.kill()
            p.wait()
        t_exit = _libc.mach_absolute_time()
        m = re.match(r"NOKTA_READY (\d+)(?: result=(-?\d+))?", line)
        if not m:
            print(f"startup run {i}: no NOKTA_READY line", file=sys.stderr)
            continue
        ready.append(ticks_to_ms(int(m.group(1)) - t0))
        total.append(ticks_to_ms(t_exit - t0))
        results.append(int(m.group(2)) if m.group(2) is not None else None)
    out = {"status": "ok" if ready else "no-data", "runs": a.runs, "valid_runs": len(ready),
           "ready_ms_all": [round(x, 3) for x in ready],
           "engine_result_codes": sorted({r for r in results if r is not None})}
    if ready:
        out["first_ms"] = ready[0]            # first launch after the build: cold caches / first AMFI check
        out["warm_ms"] = summarize(ready[1:])  # launches 2..N
        out["total_to_exit_ms"] = summarize(total[1:])
    write_json(a.out, out)
    if ready:
        w = out["warm_ms"]
        print(f"startup: first {ready[0]:.1f} ms, warm p50 {w.get('p50', 0):.1f} / p95 {w.get('p95', 0):.1f} ms ({len(ready)}/{a.runs} valid)")
    return 0 if ready else 1


# ---------------------------------------------------------------------------------------------
# idle sampling
# ---------------------------------------------------------------------------------------------
def mem_to_mb(s):
    s = s.rstrip("+-")
    m = re.match(r"([\d.]+)([BKMGT]?)", s)
    if not m:
        return None
    v = float(m.group(1))
    return v * {"B": 1 / 1048576, "K": 1 / 1024, "M": 1.0, "G": 1024.0, "T": 1048576.0, "": 1 / 1048576}[m.group(2)]


def parse_top(text, skip_first=True):
    rows = []
    for m in re.finditer(r"^\s*(\d+)\s+([\d.]+)\s+(\S+)\s+(\d+)\s*$", text, re.M):
        rows.append({"cpu": float(m.group(2)), "footprint_mb": mem_to_mb(m.group(3)), "idle_wakeups": int(m.group(4))})
    return rows[1:] if skip_first else rows  # first top sample is an average since process start


def ps_sample(pid):
    r = run(["ps", "-o", "rss=,%cpu=", "-p", str(pid)])
    f = r.stdout.split()
    if len(f) < 2:
        return None
    return {"rss_mb": int(f[0]) / 1024.0, "cpu": float(f[1])}


def sample_process(label, pid, duration, interval):
    """ps every `interval` s while one `top` runs over the same window (passive, read-only)."""
    n = max(1, int(duration // interval))
    top = subprocess.Popen(["top", "-l", str(n + 1), "-s", str(int(interval)), "-pid", str(pid),
                            "-stats", "pid,cpu,mem,idlew"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           env=ENV, text=True)
    return {"label": label, "pid": pid, "top": top, "ps": [], "n": n}


def finish_sampling(sp):
    out, _ = sp["top"].communicate(timeout=60)
    top_rows = parse_top(out)
    ps_rows = [r for r in sp["ps"] if r]
    res = {"pid": sp["pid"], "samples_ps": len(ps_rows), "samples_top": len(top_rows)}
    if ps_rows:
        res["rss_mb"] = summarize([r["rss_mb"] for r in ps_rows])
        res["ps_cpu_pct"] = summarize([r["cpu"] for r in ps_rows])
    if top_rows:
        res["cpu_pct"] = summarize([r["cpu"] for r in top_rows])
        res["footprint_mb"] = summarize([r["footprint_mb"] for r in top_rows if r["footprint_mb"] is not None])
        res["idle_wakeups_per_interval"] = summarize([r["idle_wakeups"] for r in top_rows])
    return res


def read_bench_events(path):
    """Counts NOKTA_BENCH_EVENT lines (user interaction during a bench run) by kind."""
    counts = {}
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "NOKTA_BENCH_EVENT":
                    counts[parts[1]] = counts.get(parts[1], 0) + 1
    except OSError:
        pass
    return counts


USED_MIN_WARMUP_S = 3.0  # --bench-used draws its flash 0.3 s after launch; the plate is gone ~1.2 s later


def cmd_idle(a):
    exe = os.path.join(a.app, "Contents", "MacOS", "Snapline")
    if not os.access(exe, os.X_OK):
        write_json(a.out, {"status": "missing", "exe": exe, "mode": a.mode})
        return 1
    flag = "--bench-used" if a.mode == "used" else "--bench-idle"
    # Sampling must start after the one-off UI exercise has finished and hidden again.
    warmup = max(a.warmup, USED_MIN_WARMUP_S) if a.mode == "used" else a.warmup
    # stderr carries NOKTA_BENCH_EVENT lines (menu opened, reopen, quit): user interaction
    # during the run, reported next to the numbers it inflates.
    events_path = os.path.splitext(a.out)[0] + ".events.log"
    events_file = open(events_path, "wb")
    child = subprocess.Popen([exe, flag], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=events_file, env=ENV)
    result = {"status": "ok", "mode": a.mode, "warmup_s": warmup, "duration_s": a.duration, "interval_s": a.interval}
    try:
        time.sleep(warmup)
        if child.poll() is not None:
            events_file.close()
            write_json(a.out, {"status": "exited-early", "mode": a.mode, "returncode": child.returncode,
                               "interactions": read_bench_events(events_path)})
            print(f"idle: Nokta {flag} exited early", file=sys.stderr)
            return 1
        procs = [sample_process("nokta", child.pid, a.duration, a.interval)]
        # Passive observation of the user's own Tiles (never signalled, never touched); once, in the
        # plain idle stage.
        tiles = run(["pgrep", "-x", "Tiles"]).stdout.split() if a.mode == "idle" else []
        if tiles:
            procs.append(sample_process("tiles", int(tiles[0]), a.duration, a.interval))
        for _ in range(procs[0]["n"]):
            time.sleep(a.interval)
            for sp in procs:
                sp["ps"].append(ps_sample(sp["pid"]))
        for sp in procs:
            result[sp["label"]] = finish_sampling(sp)
        if not tiles and a.mode == "idle":
            result["tiles"] = {"status": "not-running"}
    finally:
        # The only signal this script ever sends: to the child it started itself.
        if child.poll() is None:
            os.kill(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.kill(child.pid, signal.SIGKILL)
                child.wait()
        events_file.close()
    result["interactions"] = read_bench_events(events_path)
    write_json(a.out, result)
    n = result.get("nokta", {})
    print(f"idle[{a.mode}]: nokta rss p50 {n.get('rss_mb', {}).get('p50', 0):.1f} MB, "
          f"footprint p50 {n.get('footprint_mb', {}).get('p50', 0):.1f} MB, cpu mean {n.get('cpu_pct', {}).get('mean', 0):.2f} %")
    return 0


def vmmap_footprint_mb(pid):
    """Physical footprint from `vmmap --summary` (0.1 MB resolution; top rounds to whole MB)."""
    out = run(["vmmap", "--summary", str(pid)]).stdout
    m = re.search(r"^Physical footprint:\s+([\d.]+)([KMG])", out, re.M)
    if not m:
        return None
    return float(m.group(1)) * {"K": 1 / 1024, "M": 1, "G": 1024}[m.group(2)]


def cmd_menu(a):
    """Memory cost of opening the status menu once. Needs the user: they open Nokta's menu bar item
    and close it again while this waits. In bench modes every menu action is disabled, so nothing
    the user clicks there acts on a window."""
    exe = os.path.join(a.app, "Contents", "MacOS", "Snapline")
    events_path = os.path.splitext(a.out)[0] + ".events.log"
    events_file = open(events_path, "wb")
    child = subprocess.Popen([exe, "--bench-menu"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=events_file, env=ENV)
    result = {"status": "ok", "timeout_s": a.timeout}
    try:
        time.sleep(a.warmup)
        result["before_mb"] = vmmap_footprint_mb(child.pid)
        print("menu: Nokta opens and closes its own menu once (--bench-menu)", file=sys.stderr, flush=True)
        deadline = time.time() + a.timeout
        closed = False
        while time.time() < deadline and child.poll() is None:
            time.sleep(0.5)
            if read_bench_events(events_path).get("menu-close"):
                closed = True
                break
        result["opened"] = bool(read_bench_events(events_path).get("menu-open"))
        result["closed"] = closed
        if closed:
            time.sleep(3)
            result["after_mb"] = vmmap_footprint_mb(child.pid)
            time.sleep(a.settle)
            result["after_settle_mb"] = vmmap_footprint_mb(child.pid)
            result["settle_s"] = a.settle
        else:
            result["status"] = "no-interaction"
    finally:
        if child.poll() is None:
            os.kill(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.kill(child.pid, signal.SIGKILL)
                child.wait()
        events_file.close()
    result["interactions"] = read_bench_events(events_path)
    write_json(a.out, result)
    if result.get("after_mb") is not None:
        print(f"menu: footprint {result['before_mb']:.1f} -> {result['after_mb']:.1f} MB "
              f"({result['after_settle_mb']:.1f} MB {a.settle:.0f} s later)")
    else:
        print("menu: no menu open/close seen; not measured", file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------------------------
# use session (--bench-session)
# ---------------------------------------------------------------------------------------------
SESSION_PHASES = ("fresh", "menu", "settings", "shortcuts", "after-use")


def cmd_session(a):
    """One `Nokta --bench-session` process through its phases (AppController.runSessionForBench):
    fresh idle, status menu open/close, Settings open/close N times, a shortcut workload (flash +
    label from synthetic snapped events; the core moves nothing), then `--after-use` seconds idle.

    Sampling: one `top -l` at 1 Hz (CPU %, physical footprint, idle wakeups; each row stamped with
    mach time when read) plus `ps` RSS at the same rate; `vmmap --summary` physical footprint at
    every phase boundary (the end of the previous phase) and at the end. Phases come from the app's
    own `NOKTA_BENCH_EVENT phase <name> <mach ticks>` lines on stderr. The first 5 s after launch
    are not counted (launch work). Shows Settings and the menu on screen without activating Nokta;
    preferences are a throwaway domain; nothing is registered or moved."""
    exe = os.path.join(a.app, "Contents", "MacOS", "Snapline")
    if not os.access(exe, os.X_OK):
        write_json(a.out, {"status": "missing", "exe": exe})
        return 1
    events_path = os.path.splitext(a.out)[0] + ".events.log"
    events_file = open(events_path, "wb")
    args = [exe, "--bench-session", "--fresh", str(a.fresh), "--settings-cycles", str(a.cycles), "--uses", str(a.uses)]
    t_launch = _libc.mach_absolute_time()
    child = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=events_file, env=ENV)
    samples, boundaries = [], []
    lock = threading.Lock()
    pid_s = str(child.pid)

    def read_top(proc):
        for line in proc.stdout:
            f = line.split()
            if len(f) == 4 and f[0] == pid_s:
                try:
                    row = {"t": _libc.mach_absolute_time(), "cpu": float(f[1]), "footprint_mb": mem_to_mb(f[2]),
                           "idle_wakeups": int(f[3])}
                except ValueError:
                    continue
                ps = ps_sample(child.pid)
                row["rss_mb"] = ps["rss_mb"] if ps else None
                with lock:
                    samples.append(row)

    def phase_events():
        out = []
        try:
            with open(events_path, "r", errors="replace") as fh:
                for line in fh:
                    p = line.split()
                    if len(p) >= 4 and p[0] == "NOKTA_BENCH_EVENT" and p[1] == "phase":
                        out.append((p[2], int(p[3])))
        except (OSError, ValueError):
            pass
        return out

    # Mirrors AppController.runSessionForBench (each phase mark is followed by 1.5 s of quiet).
    expected = a.fresh + 9.5 + (1.5 + a.cycles * 2 + 1) + (1.5 + a.uses * 0.5 + 2)
    top = subprocess.Popen(["top", "-l", str(int(expected + a.after_use + 15)), "-s", "1", "-pid", pid_s,
                            "-stats", "pid,cpu,mem,idlew"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=ENV, text=True)
    reader = threading.Thread(target=read_top, args=(top,), daemon=True)
    reader.start()
    result = {"status": "ok", "fresh_s": a.fresh, "settings_cycles": a.cycles, "uses": a.uses, "after_use_s": a.after_use}
    try:
        seen = set()
        deadline = time.time() + expected + a.after_use + 60
        after_use_start = None
        while time.time() < deadline and child.poll() is None:
            time.sleep(0.1)
            for name, ticks in phase_events():
                if name in seen:
                    continue
                seen.add(name)
                # The boundary closes the previous phase: its footprint, precisely.
                boundaries.append({"phase": name, "t": ticks, "vmmap_mb_at_start": vmmap_footprint_mb(child.pid)})
                if name == "after-use":
                    after_use_start = time.time()
            if after_use_start is not None and time.time() - after_use_start >= a.after_use:
                break
        result["vmmap_mb_end"] = vmmap_footprint_mb(child.pid) if child.poll() is None else None
        if child.poll() is not None:
            result["status"] = "exited-early"
            result["returncode"] = child.returncode
    finally:
        if child.poll() is None:
            os.kill(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.kill(child.pid, signal.SIGKILL)
                child.wait()
        if top.poll() is None:
            top.terminate()
        reader.join(timeout=5)
        events_file.close()
    t_end = _libc.mach_absolute_time()
    starts = {b["phase"]: b["t"] for b in boundaries}
    order = [p for p in SESSION_PHASES if p in starts]
    with lock:
        rows = list(samples)
    rows = [r for r in rows if ticks_to_ms(r["t"] - t_launch) >= 5000]  # launch work is not idle
    phases = {}
    # A top row covers the second BEFORE it was read: rows less than 1 s after a mark still
    # describe the previous phase and are not counted (the app keeps 1.5 s of quiet after a mark).
    one_s = int(1e9 * _tb.denom / _tb.numer)
    for i, name in enumerate(order):
        lo = starts[name] + one_s
        hi = starts[order[i + 1]] if i + 1 < len(order) else t_end
        sel = [r for r in rows if lo <= r["t"] < hi]
        foot = [r["footprint_mb"] for r in sel if r["footprint_mb"] is not None]
        ph = {"duration_s": round(ticks_to_ms(hi - lo) / 1000, 1), "samples": len(sel)}
        if sel:
            ph["cpu_pct"] = summarize([r["cpu"] for r in sel])
            ph["idle_wakeups_per_s"] = summarize([r["idle_wakeups"] for r in sel])
            ph["footprint_mb_top"] = summarize(foot)
            ph["footprint_mb_first_last"] = [foot[0], foot[-1]] if foot else None
            ph["rss_mb"] = summarize([r["rss_mb"] for r in sel if r["rss_mb"] is not None])
        b = next((x for x in boundaries if x["phase"] == name), None)
        ph["vmmap_mb_at_start"] = b and b["vmmap_mb_at_start"]
        nxt = next((x for x in boundaries if order.index(x["phase"]) == i + 1), None) if i + 1 < len(order) else None
        ph["vmmap_mb_at_end"] = nxt["vmmap_mb_at_start"] if nxt else result.get("vmmap_mb_end")
        phases[name] = ph
    # The after-use window split in halves: steady memory has no upward trend.
    au = [r for r in rows if "after-use" in starts and r["t"] >= starts["after-use"]]
    if len(au) >= 20:
        half = len(au) // 2
        f1 = [r["footprint_mb"] for r in au[:half] if r["footprint_mb"] is not None]
        f2 = [r["footprint_mb"] for r in au[half:] if r["footprint_mb"] is not None]
        result["after_use_trend_mb"] = {"first_half_mean": statistics.fmean(f1) if f1 else None,
                                        "second_half_mean": statistics.fmean(f2) if f2 else None}
    result["phases"] = phases
    result["phase_order"] = order
    result["interactions"] = read_bench_events(events_path)
    result["samples_total"] = len(rows)
    write_json(a.out, result)
    for name in order:
        ph = phases[name]
        cpu, w, fp = ph.get("cpu_pct", {}), ph.get("idle_wakeups_per_s", {}), ph.get("footprint_mb_top", {})
        print(f"session[{name}]: n={ph['samples']} cpu mean {fmt(cpu.get('mean'))} p95 {fmt(cpu.get('p95'))} %, "
              f"wakeups/s mean {fmt(w.get('mean'))}, footprint {fmt(fp.get('min'), 1)}–{fmt(fp.get('max'), 1)} MB (top), "
              f"vmmap end {fmt(ph.get('vmmap_mb_at_end'), 1)} MB")
    return 0 if result["status"] == "ok" and len(order) == len(SESSION_PHASES) else 1


# ---------------------------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------------------------
def machine_info():
    def sh(*c):
        try:
            return run(list(c)).stdout.strip()
        except OSError:
            return ""
    return {
        "model": sh("sysctl", "-n", "machdep.cpu.brand_string"),
        "macos": sh("sw_vers", "-productVersion"),
        "build": sh("sw_vers", "-buildVersion"),
        "cores": sh("sysctl", "-n", "hw.ncpu"),
        "load_avg": sh("sysctl", "-n", "vm.loadavg"),
        "date_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def row(name, value, target_txt, ok, note=""):
    if value is None:
        return {"metric": name, "value": "not measured", "target": target_txt, "verdict": "N/A", "note": note}
    return {"metric": name, "value": value, "target": target_txt, "verdict": "PASS" if ok else "FAIL", "note": note}


def fmt(x, d=2):
    return "-" if x is None else f"{x:.{d}f}"


def mb(b):
    return f"{b / 1048576:.2f} MB" if b >= 1048576 else f"{b / 1024:.1f} KB"


def cmd_report(a):
    d = a.dir
    static = read_json(os.path.join(d, "static.json")) or {}
    startup = read_json(os.path.join(d, "startup.json")) or {}
    idle = read_json(os.path.join(d, "idle.json")) or {}
    idle_used = read_json(os.path.join(d, "idle-used.json")) or {}
    lat = read_json(os.path.join(d, "latency.json")) or {}
    rec = read_json(os.path.join(d, "recovery.json")) or {}

    rows = []
    n_idle = idle.get("nokta") or {}
    cpu_mean = (n_idle.get("cpu_pct") or {}).get("mean")
    rows.append(row("Idle CPU (mean, top)", f"{cpu_mean:.2f} %" if cpu_mean is not None else None, "~0 % (<= 0.10 %)",
                    cpu_mean is not None and cpu_mean <= TARGETS["idle_cpu_pct"]))
    rss = (n_idle.get("rss_mb") or {}).get("p50")
    rows.append(row("RSS (median, ps) (extra)", f"{rss:.1f} MB" if rss is not None else None, "< 15 MB (AppKit floor ~32 MB)",
                    rss is not None and rss < TARGETS["rss_mb"],
                    f"footprint {fmt((n_idle.get('footprint_mb') or {}).get('p50'), 1)} MB, idle wakeups/5s {fmt((n_idle.get('idle_wakeups_per_interval') or {}).get('mean'), 1)}"))
    fp = (n_idle.get("footprint_mb") or {}).get("p50")
    rows.append(row("Physical footprint (median, top)", f"{fp:.1f} MB" if fp is not None else None, "<= 12 MB",
                    fp is not None and fp <= TARGETS["footprint_mb"],
                    "top MEM; RSS of an AppKit process includes shared dyld-cache pages, the footprint does not"))
    n_used = idle_used.get("nokta") or {}
    fp_used = (n_used.get("footprint_mb") or {}).get("p50")
    rows.append(row("Physical footprint after use (median)", f"{fp_used:.1f} MB" if fp_used is not None else None, "<= 12 MB",
                    fp_used is not None and fp_used <= TARGETS["footprint_mb"],
                    f"top MEM after entry + commit + flash + label (panel and layers resident); idle was {fmt(fp, 1)} MB; "
                    f"no event tap / AX observer in bench modes; CPU mean {fmt((n_used.get('cpu_pct') or {}).get('mean'))} %"))
    nk = static.get("nokta") or {}
    eb = nk.get("exe_arm64_bytes")
    rows.append(row("Binary size (arm64 slice)", mb(eb) if eb else None, "< 3 MB", eb is not None and eb < TARGETS["binary_bytes"],
                    f"app bundle {mb(nk['app_bytes'])}" if nk.get("app_bytes") else ""))
    rows.append(row("Binary size (DESIGN §16)", f"{eb / 1000:.0f} kB" if eb else None, "<= 850 kB",
                    eb is not None and eb <= TARGETS["design_binary_bytes"], "arm64 slice of Contents/MacOS/Snapline"))
    ab = nk.get("app_bytes")
    rows.append(row("App bundle size (DESIGN §16)", f"{ab / 1000:.0f} kB" if ab else None, "<= 950 kB",
                    ab is not None and ab <= TARGETS["bundle_bytes"], "every file in Snapline.app (binary, icon, plist, signature)"))
    lm = lat.get("latency_ms") if lat.get("status") == "ok" else None
    rows.append(row("Action latency p95", f"{lm['p95']:.2f} ms" if lm else None, "< 16 ms", bool(lm) and lm["p95"] < TARGETS["latency_p95_ms"],
                    (f"p50 {lm['p50']:.2f} / p99 {lm['p99']:.2f} / max {lm['max']:.2f} ms; core nk_stats p95 {lat['core_stats']['p95_ms']:.2f} ms" if lm else
                     f"latency run: {lat.get('status', 'missing')} {lat.get('verdict', '')}".strip())))
    first = startup.get("first_ms")
    warm = (startup.get("warm_ms") or {}).get("p95")
    rows.append(row("Startup, first run after build (extra)", f"{first:.1f} ms" if first is not None else None, "< 150 ms",
                    first is not None and first < TARGETS["startup_ms"]))
    rows.append(row("Startup, warm p95", f"{warm:.1f} ms" if warm is not None else None, "< 150 ms",
                    warm is not None and warm < TARGETS["startup_ms"],
                    f"warm p50 {fmt((startup.get('warm_ms') or {}).get('p50'), 1)} ms over {startup.get('valid_runs', 0)} launches"))
    acc = (lat.get("accuracy") or {}) if lat.get("status") == "ok" else {}
    rate = acc.get("rate") if acc.get("checked") else None
    rows.append(row("Placement accuracy (extra)", f"{rate * 100:.1f} % ({acc.get('ok')}/{acc.get('checked')})" if rate is not None else None,
                    ">= 99 % within +-2 pt", rate is not None and rate >= TARGETS["accuracy_rate"]))
    hung = rec.get("hung") or {}
    hmax = hung.get("max_ms")
    codes = ", ".join(f"code {k} x{v}" for k, v in sorted((hung.get("results") or {}).items()))
    rows.append(row("Unresponsive app: action returns within (extra)", f"{hmax:.0f} ms (max of {hung.get('n')})" if hmax is not None else None,
                    "<= 1000 ms, never hangs", hmax is not None and hmax <= TARGETS["hung_max_ms"],
                    f"test window app suspended with SIGSTOP; p50 {fmt(hung.get('p50_ms'), 0)} ms; {codes}"))
    r2 = rec.get("recovery") or {}
    recovered = r2.get("first_action_result") == 0
    rows.append(row("Recovery after the app answers again (extra)",
                    (f"first action OK in {r2.get('first_action_ms'):.2f} ms" if recovered else "first action failed") if r2 else None,
                    "next action succeeds", recovered,
                    f"app answered AX {fmt(r2.get('responsive_ms'), 0)} ms after SIGCONT" if r2 else ""))

    menu = read_json(os.path.join(d, "menu.json")) or {}
    if menu.get("after_mb") is not None:
        rows.append(row("Footprint after opening the menu once (extra)", f"{menu['after_mb']:.1f} MB",
                        "<= 12 MB", menu["after_mb"] <= TARGETS["footprint_mb"],
                        f"before {menu['before_mb']:.1f} MB; {menu.get('settle_s', 0):.0f} s later {menu['after_settle_mb']:.1f} MB (vmmap)"))
    verdicts = [r["verdict"] for r in rows if not r["metric"].endswith("(extra)")]
    overall = "FAIL" if "FAIL" in verdicts else ("INCOMPLETE" if "N/A" in verdicts else "PASS")

    results = {"overall": overall, "targets": TARGETS, "machine": machine_info(), "rows": rows,
               "static": static, "startup": startup, "idle": idle, "idle_used": idle_used, "latency": lat, "recovery": rec}
    write_json(os.path.join(d, "results.json"), results)

    md = ["# Nokta benchmark summary", "",
          f"Overall: **{overall}**  ", f"{results['machine']['model']}, macOS {results['machine']['macos']} ({results['machine']['build']}), "
          f"{results['machine']['cores']} cores, load average {results['machine']['load_avg']}, {results['machine']['date_utc']}", "",
          "| Metric | Value | Target | Verdict | Note |", "|---|---|---|---|---|"]
    for r in rows:
        md.append(f"| {r['metric']} | {r['value']} | {r['target']} | **{r['verdict']}** | {r['note']} |")

    for label, stage in (("idle", idle), ("idle-used", idle_used)):
        inter = stage.get("interactions") or {}
        if inter:
            what = ", ".join(f"{k} x{v}" for k, v in sorted(inter.items()))
            md += ["", f"**Warning:** user interaction during the {label} stage ({what}); its CPU and memory numbers "
                   "include that interaction. Re-run without touching the Nokta menu bar item."]

    md += ["", "## Notes", "",
           "- Latency: `nk_core_perform_pid` wall time (mach_absolute_time) against Nokta's own `NOKTA-BENCH-<nonce>` window, "
           "gaps 0 and size cycling off; placement is re-read through AX after each action (outside the timed region).",
           "- Startup: spawn -> `NOKTA_READY` timestamp of `Nokta --bench-startup` (same mach clock). The first launch after a build "
           "pays page-in and the first code-signature validation.",
           "- Idle: `ps` RSS and `top` CPU / physical footprint / idle wakeups, 5 s interval, "
           f"{idle.get('duration_s', '?')} s after a {idle.get('warmup_s', '?')} s settle. A busy machine inflates CPU and wakeups.",
           "- Idle after use: the same sampling on `Nokta --bench-used`, which first draws one keyboard-style flash and one label plate "
           "on a small rect in a corner of the main screen (synthetic events: O1 entry, O4 commit, O5 flash, O7 label; the overlay panel and its layers get created, then hidden). "
           "Bench modes never create the event tap or the AX observer, so their memory is not part of either footprint number."]

    t_idle = idle.get("tiles") or {}
    if t_idle.get("pid"):
        md += ["", "## Tiles (passive sample of the user's running process)", "",
               "| | Nokta | Tiles |", "|---|---|---|"]
        def g(o, *path):
            for p in path:
                o = (o or {}).get(p)
            return o
        for label, path, d_ in (("RSS median (MB)", ("rss_mb", "p50"), 1), ("Footprint median (MB)", ("footprint_mb", "p50"), 1),
                                ("CPU mean (%)", ("cpu_pct", "mean"), 2), ("Idle wakeups / interval (mean)", ("idle_wakeups_per_interval", "mean"), 1)):
            md.append(f"| {label} | {fmt(g(n_idle, *path), d_)} | {fmt(g(t_idle, *path), d_)} |")
    elif t_idle:
        md += ["", "Tiles was not running during the idle window; no passive sample."]

    md += ["", "## Static comparison", "",
           "| App | Binary (arm64) | Bundle | Linked libs | Linked frameworks | Bundled frameworks |", "|---|---|---|---|---|---|"]
    for key, v in sorted(static.items(), key=lambda kv: (kv[0] != "nokta", kv[0] != "tiles", kv[0])):
        if v.get("missing"):
            md.append(f"| {key} | not found | | | | |")
            continue
        md.append(f"| {key} | {mb(v['exe_arm64_bytes']) if 'exe_arm64_bytes' in v else '-'} | {mb(v['app_bytes'])} | "
                  f"{v.get('linked_libraries', '-')} | {v.get('linked_frameworks', '-')} | {len(v.get('bundled_frameworks', []))} |")
    with open(os.path.join(d, "summary.md"), "w") as f:
        f.write("\n".join(md) + "\n")
    print("\n".join(md[:4 + len(rows) + 4]))
    print(f"\nreport: {d}/results.json, {d}/summary.md")
    return 0 if overall != "FAIL" else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("static"); s.add_argument("--nokta", default="build/Snapline.app"); s.add_argument("--out", required=True); s.set_defaults(fn=cmd_static)
    s = sub.add_parser("startup"); s.add_argument("--app", default="build/Snapline.app"); s.add_argument("--runs", type=int, default=20); s.add_argument("--out", required=True); s.set_defaults(fn=cmd_startup)
    s = sub.add_parser("idle"); s.add_argument("--app", default="build/Snapline.app"); s.add_argument("--warmup", type=float, default=10)
    s.add_argument("--mode", choices=("idle", "used"), default="idle", help="idle: --bench-idle; used: --bench-used (idle after one flash + label)")
    s.add_argument("--duration", type=float, default=60); s.add_argument("--interval", type=float, default=5); s.add_argument("--out", required=True); s.set_defaults(fn=cmd_idle)
    s = sub.add_parser("menu"); s.add_argument("--app", default="build/Snapline.app"); s.add_argument("--warmup", type=float, default=4)  # --bench-menu opens at 6 s
    s.add_argument("--timeout", type=float, default=45); s.add_argument("--settle", type=float, default=20); s.add_argument("--out", required=True); s.set_defaults(fn=cmd_menu)
    s = sub.add_parser("session"); s.add_argument("--app", default="build/Snapline.app"); s.add_argument("--fresh", type=float, default=30)
    s.add_argument("--cycles", type=int, default=20, help="Settings open/close cycles"); s.add_argument("--uses", type=int, default=60, help="shortcut-style flashes")
    s.add_argument("--after-use", type=float, default=300, help="idle seconds measured after the use"); s.add_argument("--out", required=True); s.set_defaults(fn=cmd_session)
    s = sub.add_parser("report"); s.add_argument("--dir", required=True); s.set_defaults(fn=cmd_report)
    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    main()
