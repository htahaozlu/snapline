#!/usr/bin/env bash
# snapshot.sh — render Nokta's UI (settings tabs, onboarding screens, overlay storyboards + GIFs,
#               menu bar icons, status menu) to PNG without showing anything on screen.
#               Output: tools/snapshot/out (or $1). Runs the motion self-test first
#               (tools/snapshot/SelfTest.swift, DESIGN §5.2 rule 9); a failure stops the script.
#
# Safety: the tool is linked against the INERT core (`zig build -Dinert=true`, core/src/inert.zig,
# installed as libnokta-inert.a), which exports the real C ABI but performs no Accessibility,
# hotkey, event-tap or display call. The tool never orders a window or status item in and never
# runs the app's launch path (tools/snapshot/main.swift). It is not signed and needs no permission.
#
# The shell is compiled with -D NOKTA_SNAPSHOT: code only this tool needs (self-test helpers,
# offscreen hooks) is behind `#if NOKTA_SNAPSHOT` and does not ship in Snapline.app.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${1:-tools/snapshot/out}"
WORK=tools/snapshot/.build
DEPLOY=14.0
mkdir -p "$WORK" "$OUT"

printf '\033[1m==>\033[0m inert core\n'
zig build -Dinert=true --prefix "$WORK/core"
[ -f "$WORK/core/lib/libnokta-inert.a" ] || { echo "error: zig build -Dinert=true did not produce libnokta-inert.a" >&2; exit 1; }

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find app/Sources -name '*.swift' ! -path 'app/Sources/App/main.swift' | LC_ALL=C sort)
while IFS= read -r f; do SOURCES+=("$f"); done < <(find tools/snapshot -maxdepth 1 -name '*.swift' | LC_ALL=C sort)

printf '\033[1m==>\033[0m swiftc nokta-snapshot (%d files)\n' "${#SOURCES[@]}"
swiftc -Onone -swift-version 5 -module-name Nokta -D NOKTA_SNAPSHOT \
    -target "$(uname -m)-apple-macos$DEPLOY" \
    -I "$WORK/core/include" -L "$WORK/core/lib" -lnokta-inert \
    -framework AppKit -framework ApplicationServices -framework Carbon -framework CoreFoundation \
    -framework CoreGraphics -framework ImageIO -framework QuartzCore -framework ServiceManagement \
    -o "$WORK/nokta-snapshot" "${SOURCES[@]}"

# The binary must not contain a real platform symbol: the inert core references none of them.
if nm -u "$WORK/nokta-snapshot" | grep -E '_(AXUIElement|AXObserver|CGEventTap|RegisterEventHotKey|CGEventPost)' >/dev/null; then
    echo "error: nokta-snapshot links a live platform API; refusing to run" >&2
    nm -u "$WORK/nokta-snapshot" | grep -E '_(AXUIElement|AXObserver|CGEventTap|RegisterEventHotKey|CGEventPost)' >&2
    exit 1
fi
# … and it must carry the inert core's marker (core/src/inert.zig): the core it links is the inert one.
# (nm's output is read in full first: `nm | grep -q` can fail under pipefail when grep exits early.)
SYMS="$(nm "$WORK/nokta-snapshot")"
if ! grep -q ' T _nk_inert_core$' <<<"$SYMS"; then
    echo "error: nokta-snapshot is not linked against the inert core (no _nk_inert_core); refusing to run" >&2
    exit 1
fi

printf '\033[1m==>\033[0m self-test (motion contract)\n'
"$WORK/nokta-snapshot" --self-test

# Behaviour regressions on the inert core (docs/TESTING.md): the shortcut recorder and keyboard
# (Escape, Delete, Tab, window close, duplicates, refused modifiers, registration failure, layouts),
# then first use and permission recovery (preview writes nothing, revoke/re-grant, wake, display).
printf '\033[1m==>\033[0m keyboard-test (recorder, shortcuts, layouts)\n'
"$WORK/nokta-snapshot" --keyboard-test
printf '\033[1m==>\033[0m recovery-test (first use, permission, re-binding)\n'
"$WORK/nokta-snapshot" --recovery-test

printf '\033[1m==>\033[0m render → %s\n' "$OUT"
"$WORK/nokta-snapshot" "$OUT" "$ROOT"
