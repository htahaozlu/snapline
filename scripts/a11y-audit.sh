#!/usr/bin/env bash
# a11y-audit.sh — VoiceOver readiness on the real system: opens every onboarding screen and Settings
# tab with `Nokta --bench-preview` (no shortcuts, no drag snapping, no window moved, throwaway
# preferences) and reads its accessibility tree with tools/a11y/axaudit (attribute reads only).
# Fails when an actionable element has no spoken name. Needs build/Snapline.app (scripts/build-app.sh)
# and a terminal that may use Accessibility. Each surface is shown for about two seconds.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT=tools/a11y/.build
mkdir -p "$OUT"
swiftc -O tools/a11y/axaudit.swift -o "$OUT/axaudit" || exit 1
EXE="${NOKTA_APP:-build/Snapline.app}/Contents/MacOS/Snapline"
[ -x "$EXE" ] || { echo "error: $EXE missing (run scripts/build-app.sh)" >&2; exit 1; }

# The audit must be able to fail: a process with no window (this script's own `sleep`) has nothing
# to inspect, and that has to read as a failure, never as "0 unnamed elements = pass" (a guard on
# axaudit itself). A run that could see nothing at all (no AX trust) fails below on `total`.
sleep 5 &
probe=$!
if "$OUT/axaudit" "$probe" >/dev/null 2>&1; then
    kill "$probe" 2>/dev/null
    echo "error: axaudit passed a process without windows; refusing to report a result" >&2
    exit 1
fi
kill "$probe" 2>/dev/null; wait "$probe" 2>/dev/null

fail=0
total=0
for s in onboarding-1 onboarding-2-waiting onboarding-2 onboarding-3 settings-general settings-shortcuts settings-dragging settings-about; do
    "$EXE" --bench-preview "$s" >/dev/null 2>&1 &
    pid=$!
    sleep 1.8
    printf '%-22s ' "$s"
    line="$("$OUT/axaudit" "$pid")" || fail=1
    printf '%s\n' "$line"
    n="$(printf '%s\n' "$line" | sed -n 's/^checked \([0-9]*\) actionable.*/\1/p')"
    total=$((total + ${n:-0}))
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
done
echo "a11y audit: $total actionable elements inspected on 8 surfaces"
[ $fail -eq 0 ] && [ "$total" -gt 0 ] && echo "a11y audit: PASS" || { echo "a11y audit: FAIL"; fail=1; }
exit $fail
