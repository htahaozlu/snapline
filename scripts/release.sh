#!/usr/bin/env bash
# release.sh — the downloadable Snapline: universal, Developer ID–signed, notarized and stapled
# app inside a signed, notarized and stapled DMG, plus its SHA-256. Output: dist/
#
#   SNAPLINE_NOTARY_PROFILE=<keychain profile> scripts/release.sh
#   SNAPLINE_NOTARY_KEY=AuthKey_XXXX.p8 SNAPLINE_NOTARY_KEY_ID=XXXX SNAPLINE_NOTARY_ISSUER=<uuid> scripts/release.sh
#
# Needs: a "Developer ID Application" identity in the login keychain, and notary credentials:
# a profile stored with `xcrun notarytool store-credentials <profile>`, or an App Store Connect API
# key (.p8 file, key ID, issuer ID) passed straight to notarytool (nothing is stored).
# Environment
#   SNAPLINE_DEVELOPER_ID     identity SHA-1 or name (default: the first "Developer ID Application")
#   SNAPLINE_NOTARY_PROFILE   notarytool keychain profile, or
#   SNAPLINE_NOTARY_KEY / SNAPLINE_NOTARY_KEY_ID / SNAPLINE_NOTARY_ISSUER   an API key
#   SNAPLINE_ALLOW_DIRTY=1    build from a tree with uncommitted changes (never for a published release)
#
# Network: Apple's timestamp server (codesign --timestamp) and notary service (the app and the DMG
# are uploaded for notarization), and PyPI on the first run only: tools/dmg/make-dmg.sh installs
# dmgbuild into dist/.dmgbuild-venv from hash-pinned requirements (pip --require-hashes).
# Nothing else. Fails closed: any step that does not verify stops it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [ -n "${SNAPLINE_NOTARY_PROFILE:-}" ]; then
    NOTARY=(--keychain-profile "$SNAPLINE_NOTARY_PROFILE")
elif [ -n "${SNAPLINE_NOTARY_KEY:-}" ] && [ -n "${SNAPLINE_NOTARY_KEY_ID:-}" ] && [ -n "${SNAPLINE_NOTARY_ISSUER:-}" ]; then
    [ -r "$SNAPLINE_NOTARY_KEY" ] || die "cannot read $SNAPLINE_NOTARY_KEY"
    NOTARY=(--key "$SNAPLINE_NOTARY_KEY" --key-id "$SNAPLINE_NOTARY_KEY_ID" --issuer "$SNAPLINE_NOTARY_ISSUER")
else
    die "notary credentials: set SNAPLINE_NOTARY_PROFILE, or SNAPLINE_NOTARY_KEY + _KEY_ID + _ISSUER"
fi
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
mkdir -p "$OUT"
rm -rf "$OUT/build" "$DMG" "$DMG.sha256" "$OUT/Snapline.zip"

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
xcrun notarytool submit "$OUT/Snapline.zip" "${NOTARY[@]}" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$OUT/Snapline.zip"

log "DMG: styled installer window (tools/dmg)"
bash tools/dmg/make-dmg.sh "$APP" "$DMG"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

log "notarize the DMG (uploads to Apple)"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
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
