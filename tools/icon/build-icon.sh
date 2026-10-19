#!/usr/bin/env bash
# build-icon.sh — regenerates app/Resources/AppIcon.icns and the reference tools/icon/AppIcon.svg
# (DESIGN §12; the SVG never enters the bundle).
# CoreGraphics + iconutil only; no network, no assets. Run from anywhere:  tools/icon/build-icon.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nokta-icon.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
swiftc -O -target "$(uname -m)-apple-macos14.0" "$ROOT/tools/icon/render-icon.swift" -o "$TMP/render-icon"
"$TMP/render-icon" "$TMP"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$ROOT/app/Resources/AppIcon.icns"
cp "$TMP/AppIcon.svg" "$ROOT/tools/icon/AppIcon.svg"
ls -l "$ROOT/app/Resources/AppIcon.icns" "$ROOT/tools/icon/AppIcon.svg"
