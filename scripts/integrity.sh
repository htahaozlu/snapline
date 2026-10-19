#!/usr/bin/env bash
# integrity.sh — verify the built Snapline.app against the product promises and write the report.
#
#   scripts/integrity.sh [--app build/Snapline.app] [--draft-only]
#
# Collects evidence (REA CLI rea-agents@6.5.0: inspect-macho / inspect-signature / inspect-plist,
# plus otool, nm, codesign), runs tools/integrity/analyze.py (python3 -I) against
# tools/integrity/policy.json and writes
#     tools/integrity/out/INTEGRITY.md   (+ integrity.json, raw/ evidence)   always
#     docs/INTEGRITY.md                  unless --draft-only
# Exit 1 on any violation: entitlements present, hardened runtime missing, network surface
# (sockets, CFNetwork, URLSession, Network.framework), private frameworks / SkyLight symbols,
# updater frameworks (Sparkle), bundled libraries, URL / feed keys in Info.plist.
#
# Environment
#   NOKTA_REA_VERSION   REA CLI version for npx           (default 6.5.0)
#   NOKTA_REQUIRE_REA=1 treat an unavailable REA CLI as a violation (default: warning; the native
#                       tools decide every check either way)
#
# Network note: `npx -y rea-agents@<version>` downloads the (pinned) CLI from the npm registry the
# first time. That is the only network use of the whole build tooling and never touches the app.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="build/Snapline.app"
PUBLISH=1
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift ;;
        --draft-only) PUBLISH=0 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

REA_VERSION="${NOKTA_REA_VERSION:-6.5.0}"
EXE="$APP/Contents/MacOS/Snapline"
OUT=tools/integrity/out
RAW="$OUT/raw"

[ -x "$EXE" ] || { echo "error: $EXE not found — run 'zig build app' (scripts/build-app.sh) first" >&2; exit 1; }

rm -rf "$RAW"; mkdir -p "$RAW"

run_timeout() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$s" "$@"; }

ARCHS="$(lipo -archs "$EXE" 2>/dev/null || echo arm64)"
for arch in $ARCHS; do
    otool -arch "$arch" -L "$EXE" > "$RAW/otool-libs.$arch.txt" 2>&1
    otool -arch "$arch" -l "$EXE" > "$RAW/otool-load.$arch.txt" 2>&1
    nm -arch "$arch" -u -m "$EXE" > "$RAW/nm-u.$arch.txt" 2>&1
done

codesign --verify --strict --deep --verbose=2 "$APP" > "$RAW/codesign-verify.txt" 2>&1
VERIFY_RC=$?
codesign -dv --verbose=4 "$APP" > "$RAW/codesign-dv.txt" 2>&1
codesign -d -r- "$APP" > "$RAW/codesign-dr.txt" 2>&1
codesign -d --entitlements :- "$APP" > "$RAW/entitlements.txt" 2>/dev/null

# REA CLI, one call per tool; failures are recorded, not fatal.
rea() { # name, subcommand, path
    local name=$1 sub=$2 path=$3
    if run_timeout 180 npx -y "rea-agents@$REA_VERSION" "$sub" "$path" --format json > "$RAW/rea-$name.json" 2> "$RAW/rea-$name.err"; then
        echo "rea-$name: ok"
    else
        echo "rea-$name: FAILED (see $RAW/rea-$name.err)" >&2
        : > "$RAW/rea-$name.json"
    fi
}
rea macho inspect-macho "$EXE"
rea signature inspect-signature "$APP"
rea plist inspect-plist "$APP"

{
    echo "app=$APP"
    echo "exe=$EXE"
    echo "archs=$ARCHS"
    echo "generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "rea_version=$REA_VERSION"
    echo "require_rea=${NOKTA_REQUIRE_REA:-0}"
    echo "codesign_verify_rc=$VERIFY_RC"
} > "$RAW/meta.txt"

python3 -I tools/integrity/analyze.py \
    --raw "$RAW" --app "$APP" --policy tools/integrity/policy.json \
    --out "$OUT/INTEGRITY.md" --json "$OUT/integrity.json"
RC=$?

if [ "$PUBLISH" = "1" ]; then
    mkdir -p docs
    cp "$OUT/INTEGRITY.md" docs/INTEGRITY.md
    echo "wrote docs/INTEGRITY.md"
else
    echo "draft only: $OUT/INTEGRITY.md"
fi
exit $RC
