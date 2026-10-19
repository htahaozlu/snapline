#!/usr/bin/env bash
# tools/bench/build.sh — compile the benchmark helpers into tools/bench/.build/
#
#   nokta-bench-target   Swift/AppKit test window (the only window the harness may move)
#   latency              Zig: links zig-out/lib/libnokta.a + system frameworks
#
# Run from anywhere; requires zig-out/lib/libnokta.a (zig build) for `latency`.
#
# Environment
#   NOKTA_EXTRA_LINK     extra args for the latency link (e.g. an object that provides nk_core_*
#                        while the core is not merged yet — test hook, never set in the default path)
#   NOKTA_BENCH_OPT      Zig optimize mode for latency (default ReleaseSafe: keeps overflow/bounds
#                        checks, the measured path is the C-ABI call, not this harness)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
OUT=tools/bench/.build
mkdir -p "$OUT"

LIB=zig-out/lib/libnokta.a
[ -f "$LIB" ] || { echo "error: $LIB missing — run 'zig build' first" >&2; exit 1; }

echo "==> swiftc nokta-bench-target"
swiftc -O -target arm64-apple-macos14.0 -framework AppKit \
    tools/bench/target/Target.swift -o "$OUT/nokta-bench-target"

echo "==> zig build-exe latency"
SDK="$(xcrun --show-sdk-path)"
# shellcheck disable=SC2086
zig build-exe tools/bench/latency.zig \
    -O "${NOKTA_BENCH_OPT:-ReleaseSafe}" \
    -target aarch64-macos.14.0 \
    -lc \
    "$LIB" \
    ${NOKTA_EXTRA_LINK:-} \
    -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib" \
    -framework ApplicationServices -framework CoreFoundation -framework CoreGraphics -framework Carbon \
    --cache-dir .zig-cache --global-cache-dir "${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}" \
    -femit-bin="$OUT/latency"
rm -f "$OUT/latency.o"
echo "built: $OUT/nokta-bench-target $OUT/latency"
