#!/usr/bin/env bash
# bench.sh — Nokta benchmark harness. Results: tools/bench/out/{static,startup,latency,idle,idle-used}.json,
#            results.json and summary.md (PASS/FAIL table against the work-package targets).
#
#   scripts/bench.sh                  everything
#   NOKTA_BENCH_SKIP=idle,latency scripts/bench.sh      skip stages (static,startup,latency,recovery,idle,idle-used)
#
# Environment
#   NOKTA_BENCH_N              latency samples                (default 300)
#   NOKTA_BENCH_WARMUP         latency warm-up actions        (default 10)
#   NOKTA_BENCH_STARTUP_RUNS   startup launches               (default 20)
#   NOKTA_BENCH_IDLE_WARMUP    idle / idle-used settle time, seconds      (default 10)
#   NOKTA_BENCH_IDLE_SECONDS   idle / idle-used sampling window, seconds  (default 60)
#   NOKTA_BENCH_SKIP_BUILD=1   do not rebuild the helpers (tools/bench/.build)
#   NOKTA_BENCH_MENU=1         also measure the cost of opening the menu once (Nokta opens it itself)
#   NOKTA_BENCH_SESSION=1      also run the use session (--bench-session, ~7 min): fresh idle, menu,
#                              Settings open/close ×NOKTA_BENCH_SETTINGS_CYCLES (20), shortcut workload,
#                              NOKTA_BENCH_AFTER_USE (300) s idle after use; shows Nokta's own menu and
#                              Settings window (never activated, throwaway preferences)
#   NOKTA_EXTRA_LINK           passed to the helper build (test hook only)
#
# SAFETY — what this script does to the machine:
#   * the ONLY window ever moved is the one opened by tools/bench/.build/nokta-bench-target
#     (title NOKTA-BENCH-<random nonce>, accessory app, never activated) and the latency tool
#     re-verifies that title through AX before every single action;
#   * Nokta is only ever started with --bench-startup / --bench-idle / --bench-used (no global shortcuts,
#     no drag snapping, no event tap / AX observer, no window moved); --bench-used additionally shows one
#     click-through flash + label plate on a small rect in a corner of the main screen for about a second
#     (Nokta's own overlay panel, from a synthetic event) so idle memory can be measured after use;
#   * session (opt-in): Nokta --bench-session opens and closes its own status menu once and its own
#     Settings window 20 times (ordered in without activating Nokta: the frontmost app keeps focus;
#     throwaway preferences; no shortcut bound, no window of another app touched) and shows 60
#     flashes + labels in a corner of the main screen; vmmap reads its memory map between phases;
#   * recovery: that same test window app is suspended (SIGSTOP) for ~3 s while Nokta's core is
#     timed against it, then resumed (SIGCONT) — always, also on early exit;
#   * the user's Tiles process is sampled with ps/top only, never signalled;
#   * the only processes killed are the target window app and the idle / idle-used Nokta instances this
#     run started.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT=tools/bench/out
BUILD=tools/bench/.build
APP=build/Snapline.app
PY=(python3 -I tools/bench/bench.py)
SKIP=",${NOKTA_BENCH_SKIP:-},"
skip() { case "$SKIP" in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

mkdir -p "$OUT"

# ---- prerequisites ---------------------------------------------------------------------------
if [ ! -x "$APP/Contents/MacOS/Snapline" ]; then
    log "build/Snapline.app missing — building it first"
    bash scripts/build-app.sh || { echo "error: app build failed" >&2; exit 1; }
fi
if [ "${NOKTA_BENCH_SKIP_BUILD:-0}" != "1" ] || [ ! -x "$BUILD/latency" ] || [ ! -x "$BUILD/nokta-bench-target" ]; then
    log "building benchmark helpers"
    bash tools/bench/build.sh || { echo "error: helper build failed" >&2; exit 1; }
fi

# ---- 1. static comparison (file reads only) ----------------------------------------------------
if ! skip static; then
    log "static comparison"
    "${PY[@]}" static --nokta "$APP" --out "$OUT/static.json"
fi

# ---- 2. startup (first launch after the build is the cold one, so this runs early) -----------------
if ! skip startup; then
    log "startup: ${NOKTA_BENCH_STARTUP_RUNS:-20} direct launches of --bench-startup"
    "${PY[@]}" startup --app "$APP" --runs "${NOKTA_BENCH_STARTUP_RUNS:-20}" --out "$OUT/startup.json"
fi

# ---- 3. latency against our own test window --------------------------------------------------------
TARGET_PID=""
cleanup() {
    # Only the target window app this script started itself.
    # SIGCONT first: the recovery stage suspends it, and a stopped process ignores SIGTERM.
    if [ -n "$TARGET_PID" ] && kill -0 "$TARGET_PID" 2>/dev/null; then
        kill -CONT "$TARGET_PID" 2>/dev/null; kill "$TARGET_PID" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

if ! skip latency; then
    NONCE="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
    log "latency: starting test window NOKTA-BENCH-$NONCE"
    TLOG="$OUT/.target.log"; : > "$TLOG"
    "$BUILD/nokta-bench-target" --seconds 180 --nonce "$NONCE" > "$TLOG" 2>&1 &
    TARGET_PID=$!
    for _ in $(seq 1 50); do
        grep -q '^TARGET_READY ' "$TLOG" 2>/dev/null && break
        sleep 0.2
    done
    READY_PID="$(awk '/^TARGET_READY /{print $2; exit}' "$TLOG")"
    if [ -z "$READY_PID" ] || [ "$READY_PID" != "$TARGET_PID" ]; then
        echo "error: test window did not come up (TARGET_READY '$READY_PID' vs pid $TARGET_PID)" >&2
        printf '{"tool":"latency","status":"target-failed"}\n' > "$OUT/latency.json"
    else
        sleep 0.5   # let the window finish ordering front
        "$BUILD/latency" --pid "$TARGET_PID" --nonce "$NONCE" \
            --n "${NOKTA_BENCH_N:-300}" --warmup "${NOKTA_BENCH_WARMUP:-10}" > "$OUT/latency.json"
        rc=$?
        [ $rc -eq 0 ] || echo "latency exited with code $rc (see $OUT/latency.json)" >&2
        if ! skip recovery; then
            # Recovery: the same test window app, suspended (SIGSTOP) while 5 actions are timed,
            # then resumed; one action must succeed again. Only our own target is ever signalled.
            log "recovery: 5 actions against the suspended test window, then one after resume"
            "$BUILD/latency" --pid "$TARGET_PID" --nonce "$NONCE" --hung 5 > "$OUT/recovery.json"
            rc=$?
            [ $rc -eq 0 ] || echo "recovery exited with code $rc (see $OUT/recovery.json)" >&2
        fi
    fi
    cleanup; TARGET_PID=""
fi

# ---- 4. idle (+ passive Tiles sample) --------------------------------------------------------------------
if ! skip idle; then
    log "idle: ${NOKTA_BENCH_IDLE_WARMUP:-10}s settle + ${NOKTA_BENCH_IDLE_SECONDS:-60}s sampling"
    "${PY[@]}" idle --app "$APP" --warmup "${NOKTA_BENCH_IDLE_WARMUP:-10}" \
        --duration "${NOKTA_BENCH_IDLE_SECONDS:-60}" --interval 5 --out "$OUT/idle.json"
fi

# ---- 5. idle after use (O1 + O4 + O5 + O7 drawn first: panel, layers and plate text resident) ------------
if ! skip idle-used; then
    log "idle-used: ${NOKTA_BENCH_IDLE_WARMUP:-10}s settle + ${NOKTA_BENCH_IDLE_SECONDS:-60}s sampling (--bench-used)"
    "${PY[@]}" idle --mode used --app "$APP" --warmup "${NOKTA_BENCH_IDLE_WARMUP:-10}" \
        --duration "${NOKTA_BENCH_IDLE_SECONDS:-60}" --interval 5 --out "$OUT/idle-used.json"
fi

# ---- 5b. menu cost (opt-in, needs the user: NOKTA_BENCH_MENU=1) ------------------------------------------
if [ "${NOKTA_BENCH_MENU:-0}" = "1" ] && ! skip menu; then
    log "menu: footprint before and after Nokta opens its own menu once (--bench-menu; every item but Quit disabled)"
    "${PY[@]}" menu --app "$APP" --out "$OUT/menu.json"
fi

# ---- 5c. use session (opt-in: NOKTA_BENCH_SESSION=1; ~7 min, shows Nokta's menu and Settings) ----------------
if [ "${NOKTA_BENCH_SESSION:-0}" = "1" ] && ! skip session; then
    log "session: fresh idle, menu, Settings ×${NOKTA_BENCH_SETTINGS_CYCLES:-20}, shortcut workload, ${NOKTA_BENCH_AFTER_USE:-300} s idle after use"
    "${PY[@]}" session --app "$APP" --cycles "${NOKTA_BENCH_SETTINGS_CYCLES:-20}" \
        --after-use "${NOKTA_BENCH_AFTER_USE:-300}" --out "$OUT/session.json"
fi

# ---- 6. report --------------------------------------------------------------------------------------------
log "report"
"${PY[@]}" report --dir "$OUT"
