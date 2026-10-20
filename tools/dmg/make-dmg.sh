#!/usr/bin/env bash
# make-dmg.sh — build the Snapline installer DMG (styled Finder window) and verify it.
#
#   tools/dmg/make-dmg.sh <path/to/Snapline.app> <out.dmg>
#
# Renders the background (tools/dmg/render-background.swift), builds the image with dmgbuild
# (tools/dmg/settings.py) from a hash-pinned venv, then mounts it read-only and checks the
# contents. Does not sign or notarize: scripts/release.sh does that on the result.
# Network: PyPI, first run only (pip install --require-hashes -r tools/dmg/requirements.txt).
# Environment: SNAPLINE_DMG_VENV  venv location (default: <repo>/dist/.dmgbuild-venv, gitignored)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

[ $# -eq 2 ] || die "usage: make-dmg.sh <Snapline.app> <out.dmg>"
[ -d "$1" ] || die "no such app bundle: $1"
APP="$(cd "$1" && pwd)"
case "$2" in *.dmg) ;; *) die "output must end in .dmg: $2" ;; esac
mkdir -p "$(dirname "$2")"
OUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || die "$APP has no AppIcon.icns"

VENV="${SNAPLINE_DMG_VENV:-$ROOT/dist/.dmgbuild-venv}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/snapline-dmg.XXXXXX")"
MNT="$WORK/mnt"
mkdir -p "$MNT"
cleanup() {
    if [ -d "$MNT" ] && mount | grep -q " on $MNT "; then hdiutil detach "$MNT" -quiet -force || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# Venv: reinstalled whenever the pinned requirements change (stamp = their SHA-256).
REQ="$HERE/requirements.txt"
STAMP="$(shasum -a 256 "$REQ" | awk '{print $1}')"
if [ ! -x "$VENV/bin/dmgbuild" ] || [ "$(cat "$VENV/.requirements.sha256" 2>/dev/null || true)" != "$STAMP" ]; then
    log "dmgbuild venv: $VENV (hash-pinned install)"
    python3 -m venv "$VENV"
    "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check --require-hashes -r "$REQ"
    printf '%s\n' "$STAMP" > "$VENV/.requirements.sha256"
fi

log "render the background"
swift "$HERE/render-background.swift" "$WORK/art" >/dev/null
[ -s "$WORK/art/background.png" ] && [ -s "$WORK/art/background@2x.png" ] || die "background not rendered"

log "dmgbuild -> $OUT"
rm -f "$OUT"
"$VENV/bin/dmgbuild" -s "$HERE/settings.py" -D "app=$APP" -D "background=$WORK/art/background.png" \
    "Snapline" "$OUT"
[ -s "$OUT" ] || die "dmgbuild produced no image"

log "verify the image"
hdiutil verify -quiet "$OUT" || die "hdiutil verify failed"
hdiutil attach -nobrowse -readonly -noautoopen -noverify -mountpoint "$MNT" "$OUT" >/dev/null \
    || die "cannot mount $OUT"
[ -d "$MNT/Snapline.app" ]                 || die "Snapline.app missing from the image"
[ -L "$MNT/Applications" ]                 || die "Applications is not a symlink"
[ "$(readlink "$MNT/Applications")" = "/Applications" ] || die "Applications points to the wrong place"
[ -s "$MNT/.DS_Store" ]                    || die ".DS_Store (window layout) missing"
ls "$MNT"/.background/* >/dev/null 2>&1 || ls "$MNT"/.background.* >/dev/null 2>&1 || die "hidden background missing"
[ -f "$MNT/.VolumeIcon.icns" ]             || die "volume icon missing"
[ -f "$MNT/Snapline.app/Contents/MacOS/Snapline" ] || die "app executable missing"
# The copy inside must still be the signed (and, for a release, stapled) app.
codesign --verify --deep --strict "$MNT/Snapline.app" || die "the app inside the image fails codesign --verify"
hdiutil detach "$MNT" -quiet
log "ok: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
