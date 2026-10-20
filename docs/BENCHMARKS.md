# Benchmarks

Measured, not estimated. Regenerate with `scripts/bench.sh` (also `zig build bench`); raw data lands
in `tools/bench/out/results.json` and `summary.md`. This page is a curated copy of the runs below plus
reference baselines measured the same way.

**Machine:** Apple M3, 8 cores, 16 GB, macOS 26.5 (25F71). v2 runs: MacBook Pro lid closed, one external
BenQ EW3270U (3840 × 2160). The v0.1 runs used the built-in notched 1512 × 982 display + a 1920 × 1080
external.
**Build:** `build/Snapline.app` 0.2.0 (build 5.1 = 5 commits + uncommitted v2 changes), arm64, ReleaseSmall
core + `-Osize -wmo` shell, signed with the local development identity, hardened runtime, no entitlements.
v2 = the redesign (docs/DESIGN.md v2) after a design review round.

## Results vs targets (v2)

| Target | Metric (definition) | v2 result | Verdict |
|---|---|---|---|
| Idle CPU ~0 % | `top` %CPU mean, 12 samples × 5 s after 10 s settle, `--bench-idle` (UI + core, no shortcuts, no drag tap) | **0.00 %**, idle wakeups 0 | PASS |
| Memory, idle | `phys_footprint`: `top` MEM median / `vmmap --summary` | **11.0 MB** (top) · 11.4–11.7 MB (vmmap) | PASS (≤ 12 MB) |
| Memory, after use | same, `--bench-used`: O1 entry + O4 commit + O5 flash + O7 label drawn, then idle | **12.0 MB** (top, rounds to whole MB) · **11.9–12.3 MB** (vmmap, median 12.2 over 7 runs) | **FAIL, by up to 0.3 MB** (≤ 12 MB) — note 3 |
| Binary < 3 MB (SPEC) | `Contents/MacOS/Snapline`, arm64 | **822 kB** (821,728 B) | PASS; DESIGN §16 v2 budget ≤ 850 kB PASS |
| Bundle (DESIGN §16) | every file in Snapline.app | **926 kB** (925,786 B: binary + 100 kB icon + plist + signature) | PASS (≤ 950 kB) |
| Shortcut → move p95 < 16 ms | trigger → last AX setter returned, 300 actions on Nokta's own `NOKTA-BENCH-<nonce>` window | **p50 0.53 · p95 1.26 · p99 3.89 · max 4.36 ms**, 300/300 placed (±2 pt), core `nk_stats` p95 0.70 ms — v2 build, screen unlocked (v0.1: p95 1.29 ms) | PASS |
| Unresponsive app (extra) | the test window app suspended with SIGSTOP, 5 actions timed, then resumed | every action returns in **≤ 505 ms** (AX timeout 0.5 s, result `ax`); after SIGCONT the app answers AX in 15 ms and the next action succeeds in 65.8 ms | PASS (≤ 1000 ms, never hangs) |
| Cold start < 150 ms | spawn → `NOKTA_READY` (didFinishLaunching done + core started), 20 direct launches | warm **p50 86.2 · p95 94.2 ms**; first launch after a fresh build 485 ms | PASS warm / FAIL first-after-build (note 2) |
| RSS < 15 MB | `ps -o rss` median, idle | 64.8 MB | not achievable with AppKit — see baselines |

v0.1 → v2: bundle 1.27 MB → 926 kB (Doto font removed), after-use memory 13.0–13.4 MB → 11.9–12.3 MB
(vector overlay, glyph-path label), idle 11.7–12.0 MB → 11.4–11.7 MB (vmmap), binary 667 kB → 822 kB
(onboarding scenes, motion engine, new Settings views).

## 2026-10-20 — 0.4.0 size check (practice screen, Option-Command set)

Only size was re-measured; the runtime numbers below are from the 0.3.0 candidate, and the change
adds no timer, observer or work outside onboarding's screen 3 (a local key monitor lives only while
that screen is up; one workspace observer re-binds a shortcut another app held when an app quits).

| Item | 0.3.0 | 0.4.0 |
|---|---|---|
| Binary, arm64, `-Osize -wmo`, strip -x | 842,112 B | 875,520 B with the new screen → **842,096 B** with `-Xfrontend -disable-reflection-metadata` (≤ 850 kB PASS) |
| `__TEXT` | 39 × 16 KB pages | 41 → **39** pages (`__swift5_reflstr`/`fieldmd`/`assocty`/`builtin` gone, `typeref` 6.4 → 3.2 kB) |
| Bundle (du) | 946 kB | **936 kB** (≤ 950 kB PASS) |

Nothing in `app/Sources` prints a value through reflection (every interpolation is a String, a
number or a rawValue/title/id; no Mirror, no dump), so dropping the tables changes no output. The
snapshot tool keeps them (its file names print enum cases).

## 2026-10-19 — keyboard / recovery candidate (uncommitted on b93cdd2)

Apple M3, 8 cores, 16 GB, macOS 26.5 (25F71), lid closed + BenQ EW3270U 3840 × 2160 (main). Release
build `build/Snapline.app` (dev identity, hardened runtime, `a8b5d909…` Contents/MacOS/Snapline, 842,112 B;
the bench instances found Accessibility granted: engine result 0). Same-run A/B: HEAD b93cdd2 vs this
candidate, both ad-hoc (`NOKTA_ALLOW_UNSIGNED_BUILD=1` / no identity), same harness, back to back.
Raw: `tools/bench/out/*.json`, `session.json`. Machine state matters: the same footprint read 12 MB in a
run one hour earlier and 14–15 MB here, for HEAD and candidate alike — compare within a run only.

| Workload | Samples | CPU mean / p95 | Idle wakeups | Footprint (top MEM / vmmap) | RSS p50 |
|---|---|---|---|---|---|
| Fresh idle (`--bench-idle`, 10 s settle) | 12 × 5 s | 0.03 % / 0.1 % | 0 per 5 s | 15.0 MB | 54.7 MB |
| After one flash + label (`--bench-used`) | 12 × 5 s | 0.00 % / 0.00 % | 2 per 5 s | 15.0 MB | 55.1 MB |
| Session: fresh (30 s) | 24 × 1 s | 0.00 % / 0.00 % | 0 /s | 15.0 MB · vmmap 15.0 | 57.3 MB |
| Session: status menu open 5 s, closed | 7 × 1 s | 0.21 % / 0.8 % | 1.1 /s | 23–24 MB · vmmap 23.7 → 32.5 | 80.2 MB |
| Session: Settings open/close ×20 (1 s each, all 4 tabs) | 17 × 1 s | 12.0 % / 27.4 % | 18.4 /s | 51–115 MB while open · vmmap after 61.3 | 115 MB |
| Session: shortcut workload (60 flash + label, 2/s) | 29 × 1 s | 0.69 % / 1.2 % | 32.9 /s | 59–61 MB | 103 MB |
| Session: idle 5 min after use | 267 × 1 s | 0.01 % / 0.00 % | 35.8 /s (p95 38) | 59 MB flat (1st half 59.0, 2nd half 59.0) · vmmap 58.8 | 78.5 MB |

| Other | Result |
|---|---|
| Startup (20 direct `--bench-startup`) | first 91.1 ms; warm p50 82.1 / p95 138.0 ms |
| A/B startup, ad-hoc | HEAD first 81.4, p50 64.3 / p95 73.3 ms · candidate first 533.2 (first launch after a fresh build), p50 69.2 / p95 83.8 ms |
| A/B idle / after one flash, ad-hoc | HEAD 14.0 / 15.0 MB, 0.00 % CPU · candidate 14.0 / 15.0 MB, 0.00 % CPU |
| Action latency (core path, own window, 300) | p50 1.38 · p95 10.41 · p99 15.96 · max 20.19 ms, 300/300 placed; an earlier run the same day: p95 3.12 ms. The core is unchanged by this candidate. A first attempt was refused by the tool (AX listed no window for the verified target; nothing touched) and re-run. |
| Unresponsive app | 5 actions ≤ 505.2 ms; recovered, first action 54.9 ms |
| Size | binary 842,112 B (≤ 850 kB budget: a first cut was 858,528 B and was brought back under it); bundle 946 kB (≤ 950 kB) |

Findings:
1. **Settings leaves idle wakeups behind (pre-existing, not app-owned).** After Settings has been shown,
   Nokta's main thread is idle but RenderBox / IOGPU cache-pruning dispatch timers (`RB::SurfacePool::
   collect`, `RB::Device::prune_caches`; `sample`) keep waking the process: ~1–3 /s after one Settings
   window (HEAD the same: 2–3 /s), ~36 /s after 20, flat for the whole 5 min, CPU 0.01 %. `heap` shows the
   closed Settings controllers, panes and windows freed (no Nokta class left); 44 `IOGPUMetalResourcePool`
   remain. Target "no app-owned periodic idle polling": met; "after-use footprint ≤ 35 MiB" (engineering
   hypothesis): **missed** (59 MB after 20 Settings cycles; 32.5 MB after menu only). No helper process was
   added to hide it.
2. Memory does not grow during 5 min idle after use (59.0 → 59.0 MB); Settings ×20 plateaued (vmmap 61.3
   right after, 58.8 at the end).
3. `--bench-menu`'s close never fired when started from a main-queue block (macOS 26 menu tracking runs
   inside the click and the queue is not drained again): the menu stayed open. Fixed (run-loop performs).

## Baselines (same machine, same method)

| Process | Footprint | RSS | Note |
|---|---|---|---|
| Empty C process (`sleep`) | 0.9 MB | 1.3 MB | floor of any process |
| Empty AppKit app (no window) | 7.0 MB | 31.9 MB | `NSApplication.run`, nothing else |
| AppKit + one status item (template icon) | **10 MB** | 39.6 MB | the floor of *any* menu bar app |
| **Nokta v2** (idle, full UI + core) | **11.4–11.7 MB** | 64.8 MB | ~1.5 MB above the menu-bar-app floor |
| **Nokta v2** after entry + commit + flash + label | 11.9–12.3 MB | 68.7 MB | panel, layers, first-use code (note 3) |
| Nokta v0.1 idle / after use | 11.7–12.0 / 13.0–13.4 MB | 67.4 / 70.0 MB | before the redesign |
| Tiles 1.3.2 (user's running copy, v0.1 run) | 28 MB | 14.8 MB | sampled passively with `ps`/`top`; old process, pages compressed |

RSS counts resident shared dyld-cache pages (AppKit, Swift runtime, CoreText); it rises with every
framework touched and falls as the system compresses an old process. `phys_footprint` — what Activity
Monitor shows as "Memory" — is the comparable number. ~7 MB of Nokta's idle footprint are ColorSync
transform tables AppKit creates when the template status icon is first composited (also present in the
status-item-only baseline).

## Static comparison (release bundles, never launched)

| App | Bundle | Main binary (arm64) | Linked libraries | Bundled frameworks |
|---|---|---|---|---|
| **Nokta 0.2.0** | **926 kB** | 822 kB | 31 | — |
| Tiles 1.3.2 | 9.26 MB | 235 kB | 13 | LamaKit, ShortcutRecorder, Sparkle |
| Rectangle 2.0.3 | 10.16 MB | 1,748 kB | 33 | Sparkle |
| Swish 1.13.3 | 10.88 MB | 1,521 kB | 38 | Paddle, Sparkle |
| Moom 4.6 | 13.88 MB | 982 kB | 17 | Sparkle |
| Rectangle Pro 3.94 | 21.36 MB | 3,213 kB | 44 | Paddle, Sparkle |
| Amethyst 0.24.3 | 21.81 MB | 7,794 kB | 40 | Sparkle, libswift_Concurrency |
| Loop 1.4.2 | 30.19 MB | 4,301 kB | 45 | — |

Nokta's binary is larger than Tiles' because it statically contains the whole core (engine, AX layer,
hotkeys, layout) and the shell; it ships no frameworks, no fonts and no images except the app icon, so
the bundle is 10× smaller than the smallest competitor bundle.

## Notes — what was not measured, and why

1. **Latency needs an unlocked screen.** While the screen is locked macOS answers AX title queries with
   the application element, so the harness' title check refuses to touch anything (`title_mismatch`); the
   first v2 run (~10:20 +03) was refused that way. The latency and recovery rows above are from the v2
   build with the screen unlocked (~11:00 +03). This is the time until the last AX setter returned, not
   until the target app redrew (note 6). The core also reports its own p50/p95 live in
   Settings › About › Details.
2. **First launch after a build** (485 ms) includes the system's first-time verification of a newly
   signed binary; subsequent launches are 84–94 ms. Not tuned further.
3. **Memory after use misses 12 MB by up to 0.3 MB** (vmmap 11.9–12.3, median 12.2; `top` rounds it to 12.0 and passes it).
   Breakdown (`footprint`/`heap`, idle vs used): live heap +0.23 MB (Swift metadata and ObjC method caches
   of the first overlay use, the overlay panel and its layers) and +0.4 MB of malloc pages that stay dirty
   after the first use until the system is under memory pressure. The v0.1 culprit is gone: the label
   plate used to be a CATextLayer, rasterised inside Nokta, which left six more 352 KB ColorSync transform
   tables and its backing store resident (+2.1 MB); the plate text is now a glyph-path CAShapeLayer filled
   by the render server (DESIGN §9/§13). The event tap and AX observer are not part of any bench mode.
4. **Memory after opening UI (measured on the device, vmmap).** These are the numbers a user sees after
   first use, and they are larger than the idle budget:

   | Surface | while open | after it closes |
   |---|---|---|
   | Status menu, opened once (`--bench-menu`: Nokta opens and closes it itself) | — | 11.8 → **19.6 MB**, stays |
   | Settings › General / About | 34 / 36 MB | 33 / 35 MB |
   | Settings › Shortcuts / Dragging | 52 / 50 MB | 48 / 45 MB |
   | Onboarding (permission screen) | 24 MB | 24 MB |

   What stays is mostly AppKit's process-lifetime state on macOS 26: the SwiftUI-based internals of the
   standard controls, ColorSync transform tables (21 → 42 × 352 KB), fonts and dirty malloc pages. Our own
   leak — the closed Settings window kept its tab view controller, every pane and view alive — is fixed by
   detaching the content on close (−4 MB). Removing the menu's items after it closes changed nothing.
   The real fix is architectural: run Settings and onboarding in a separate short-lived process, so the
   resident menu-bar agent stays at its idle footprint (planned). Reproduce the menu row with `build/Snapline.app/Contents/MacOS/Snapline --bench-menu` and `vmmap --summary` before and after its `NOKTA_BENCH_EVENT menu-close` line.
5. **Competitors at runtime.** Running Rectangle, Moom, Loop, … would register global shortcuts and
   observe input on the user's live desktop, which the project's safety rules forbid. Only Tiles was
   observed, passively, because the user already runs it.
6. **End-to-end "visible on screen" latency** (includes the target app's own redraw) and Chrome
   Speedometer A/B impact of AX observation — need interactive testing.
7. **Interaction during runs.** Bench modes write `NOKTA_BENCH_EVENT menu-open|menu-close|reopen|quit` to
   stderr; `bench.py` keeps them per stage (`*.events.log`) and `summary.md` warns when a stage's numbers
   include user interaction.
