#!/usr/bin/env bash
# release.sh — the downloadable Snapline: universal, Developer ID–signed, notarized and stapled
# app inside a signed, notarized and stapled DMG, plus its SHA-256. Output: dist/
#
#   SNAPLINE_NOTARY_PROFILE=<keychain profile> scripts/release.sh
#
# Needs (once): a "Developer ID Application" identity in the login keychain, and notary
# credentials stored with `xcrun notarytool store-credentials <profile>`.
# Environment
#   SNAPLINE_DEVELOPER_ID     identity SHA-1 or name (default: the first "Developer ID Application")
#   SNAPLINE_NOTARY_PROFILE   notarytool keychain profile (required)
#   SNAPLINE_ALLOW_DIRTY=1    build from a tree with uncommitted changes (never for a published release)
#
# Network: Apple's timestamp server (codesign --timestamp) and notary service (the app and the DMG
# are uploaded for notarization). Nothing else. Fails closed: any step that does not verify stops it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

PROFILE="${SNAPLINE_NOTARY_PROFILE:-}"
[ -n "$PROFILE" ] || die "set SNAPLINE_NOTARY_PROFILE (xcrun notarytool store-credentials <profile>)"
VERSION="$(grep -E 'const[[:space:]]+version_string' core/src/root.zig | grep -Eo '"[^"]+"' | head -1 | tr -d '"')"
[ -n "$VERSION" ] || die "version_string not found in core/src/root.zig"
if [ "${SNAPLINE_ALLOW_DIRTY:-0}" != "1" ] && [ -n "$(git status --porcelain)" ]; then
    die "uncommitted changes: commit first (the build number comes from git)"
fi

IDENTITY="${SNAPLINE_DEVELOPER_ID:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ {print $2; exit}')"
fi
[ -n "$IDENTITY" ] || die "no Developer ID Application identity in the keychain"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

OUT=dist
APP="$OUT/build/Snapline.app"
DMG="$OUT/Snapline.dmg"
STAGE="$OUT/dmg-root"
mkdir -p "$OUT"
rm -rf "$OUT/build" "$STAGE" "$DMG" "$DMG.sha256" "$OUT/Snapline.zip"

log "build $VERSION: universal, Developer ID, secure timestamp"
NOKTA_UNIVERSAL=1 NOKTA_SIGN_IDENTITY="$IDENTITY" NOKTA_KEYCHAIN="$KEYCHAIN" NOKTA_KEYCHAIN_PASS="" \
    NOKTA_SIGN_TIMESTAMP=1 NOKTA_BUILD_DIR="$OUT/build" bash scripts/build-app.sh

log "verify the app signature"
codesign --verify --deep --strict --verbose=2 "$APP"
INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
grep -q '^Authority=Developer ID Application' <<<"$INFO" || die "the app is not signed with a Developer ID"
grep -q 'flags=.*runtime' <<<"$INFO" || die "hardened runtime missing"
grep -q '^Timestamp=' <<<"$INFO" || die "no secure timestamp (notarization would fail)"
[ "$(lipo -archs "$APP/Contents/MacOS/Snapline")" = "x86_64 arm64" ] || die "not a universal binary"

log "notarize the app (uploads to Apple)"
ditto -c -k --keepParent "$APP" "$OUT/Snapline.zip"
xcrun notarytool submit "$OUT/Snapline.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$OUT/Snapline.zip"

log "DMG: Snapline.app + Applications"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Snapline.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Snapline" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

log "notarize the DMG (uploads to Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

log "Gatekeeper"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

shasum -a 256 "$DMG" | sed "s|$OUT/||" > "$DMG.sha256"
echo
log "result: $DMG ($(du -h "$DMG" | awk '{print $1}'))"
printf '  version:  %s\n' "$VERSION"
printf '  sha256:   %s\n' "$(awk '{print $1}' "$DMG.sha256")"
printf '  app:      %s (signed, notarized, stapled; universal)\n' "$APP"
