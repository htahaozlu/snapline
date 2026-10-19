#!/usr/bin/env bash
# check-stubs.sh — fail (exit 1) while any "not implemented" stub marker is left in the sources.
#
#   scripts/check-stubs.sh [dir ...]      default dirs: core/src app/Sources
#
# Flagged (case variants spelled out in the patterns):
#   1. @panic(...)      whose message contains "not implemented" / "unimplemented"
#   2. fatalError(...)  whose message contains "not implemented" / "unimplemented" / "stub" / "todo"
#   3. the marker word  STUB  (upper case, whole word) anywhere, e.g. "//! STUB — ..."
# Not flagged but listed as information: other fatalError( calls (genuine invariants are fine,
# the standard `init(coder:)` boilerplate says "has not been implemented" and is ignored).
#
# Release gate: run it before tagging a build.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ $# -gt 0 ]; then DIRS=("$@"); else DIRS=(core/src app/Sources); fi

INCLUDES=(--include='*.zig' --include='*.swift' --include='*.c' --include='*.h' --include='*.m')
FOUND=0
TMP="$(mktemp -t nokta-stubs)"
trap 'rm -f "$TMP"' EXIT

scan() { # label, extended-regex
    local label=$1 re=$2 n
    grep -rnE "${INCLUDES[@]}" -e "$re" "${DIRS[@]}" 2>/dev/null \
        | grep -viE 'has not been implemented' > "$TMP" || true
    n=$(wc -l < "$TMP" | tr -d ' ')
    if [ "$n" -gt 0 ]; then
        printf '\n%s (%s)\n' "$label" "$n"
        sed 's/^/  /' "$TMP"
        FOUND=$((FOUND + n))
    fi
}

scan '@panic "not implemented"'      '@panic\(.*([Nn]ot|[Uu]n)[ -]?implemented'
scan 'fatalError "not implemented/stub/todo"' 'fatalError\(.*([Nn]ot implemented|[Uu]nimplemented|[Ss]tub|STUB|[Tt]odo|TODO)'
scan 'STUB marker'                   '(^|[^A-Za-z0-9_])STUB([^A-Za-z0-9_]|$)'

# Informational: bare fatalError( calls (not counted).
INFO="$(grep -rnE "${INCLUDES[@]}" -e 'fatalError\(' "${DIRS[@]}" 2>/dev/null \
    | grep -viE 'has not been implemented|not implemented|unimplemented|stub|todo' || true)"
if [ -n "$INFO" ]; then
    printf '\ninfo: other fatalError( calls (not counted as stubs):\n'
    printf '%s\n' "$INFO" | sed 's/^/  /'
fi

echo
if [ "$FOUND" -gt 0 ]; then
    echo "check-stubs: FAIL — $FOUND stub marker(s) found in: ${DIRS[*]}"
    exit 1
fi
echo "check-stubs: OK — no stub markers in: ${DIRS[*]}"
